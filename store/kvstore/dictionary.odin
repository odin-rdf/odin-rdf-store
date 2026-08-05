package kvstore

import "base:runtime"
import "core:encoding/endian"
import "core:hash/xxhash"
import "core:strings"

import "rdf:rdf"
import lmdb "../../vendor/lmdb"
import store ".."

// The persistent dictionary: rdf.Term ⇄ Term_ID over the id2term and
// term2id DBs, per STORE-A-0003 §§2–4.
//
//   - id2term: key = big-endian Term_ID, value = the term's canonical
//     bytes (§2 — no kind byte; the kind is the key's tag bits).
//   - term2id: key = [kind: 1B][XXH3-128(canonical bytes, seed 0): 16B],
//     value = big-endian Term_ID. Every key hit is verified against
//     id2term content; a true collision between distinct terms is
//     detected and rejected (Hash_Collision), never silently chained.
//
// Public lookups copy into a caller-supplied allocator (STORE-I-0002
// decision 3): returned terms own nothing of the mapped pages and stay
// valid after the internal read transaction ends. Callers typically
// pass an arena and free it wholesale — a decoded term is a small tree
// (strings, and nodes for RDF-star triple terms), not a single block.

// ID_SIZE is the width of one big-endian Term_ID in keys and values.
@(private)
ID_SIZE :: size_of(store.Term_ID)

// TERM2ID_KEY_SIZE is 1 kind byte + the 128-bit content hash.
@(private)
TERM2ID_KEY_SIZE :: 1 + 16

@(private)
put_id_be :: proc(buf: []u8, id: store.Term_ID) {
	when store.TERM_ID_BITS == 32 {
		endian.put_u32(buf, .Big, u32(id))
	} else {
		endian.put_u64(buf, .Big, u64(id))
	}
}

@(private)
get_id_be :: proc(bytes: []u8) -> store.Term_ID {
	when store.TERM_ID_BITS == 32 {
		v, _ := endian.get_u32(bytes, .Big)
		return store.Term_ID(v)
	} else {
		v, _ := endian.get_u64(bytes, .Big)
		return store.Term_ID(v)
	}
}

// term2id_key builds the fixed 17-byte key for canonical term bytes.
@(private)
term2id_key :: proc(buf: []u8, kind: store.Term_Kind, canonical: []u8) {
	buf[0] = u8(kind)
	hash := xxhash.XXH3_128_default(canonical)
	for i in 0 ..< 16 {
		buf[1 + i] = u8(hash >> uint((15 - i) * 8))
	}
}

// intern_term interns a term in its own write transaction; see
// intern_term_txn for the transactional form the loaders use.
intern_term :: proc(s: ^Store, term: rdf.Term) -> (id: store.Term_ID, err: Error) {
	txn: ^lmdb.Txn
	check(lmdb.txn_begin(s.env, nil, 0, &txn)) or_return
	committed := false
	defer if !committed {
		lmdb.txn_abort(txn)
	}
	id = intern_term_txn(s, txn, term) or_return
	check(lmdb.txn_commit(txn)) or_return
	committed = true
	return id, nil
}

// intern_term_txn interns a term (recursively for RDF-star triple
// terms) inside a caller-owned write transaction, assigning a fresh
// dense ID on first sight. Nothing borrowed from the caller's term
// survives: canonical bytes are written into LMDB pages.
intern_term_txn :: proc(s: ^Store, txn: ^lmdb.Txn, term: rdf.Term) -> (id: store.Term_ID, err: Error) {
	switch v in term {
	case rdf.IRI:
		return intern_canonical(s, txn, .IRI, transmute([]u8)string(v))

	case rdf.Blank_Node:
		return intern_canonical(s, txn, .Blank_Node, transmute([]u8)string(v))

	case rdf.Literal:
		if len(v.language) > 255 {
			return 0, .Language_Too_Long
		}
		dt := intern_canonical(s, txn, .IRI, transmute([]u8)string(v.datatype)) or_return
		return intern_canonical(s, txn, .Literal, literal_canonical(dt, v))

	case ^rdf.Triple:
		assert(v != nil, "intern_term_txn: nil triple term")
		components: [3]store.Term_ID
		components[0] = intern_term_txn(s, txn, v.subject) or_return
		components[1] = intern_term_txn(s, txn, v.predicate) or_return
		components[2] = intern_term_txn(s, txn, v.object) or_return
		return intern_triple_ids_txn(s, txn, components)
	}
	panic("intern_term_txn: nil term")
}

// literal_canonical builds a literal's canonical bytes (STORE-A-0003
// §2) given its already-resolved datatype ID: [datatype ID][direction]
// [language length][language][lexical form]. The buffer is scratch for
// hashing and storing, so it comes from the temp allocator; callers on
// both the intern and the find path must have checked the language
// length fits the format's one-byte field.
@(private)
literal_canonical :: proc(dt: store.Term_ID, v: rdf.Literal) -> []u8 {
	canonical := make([dynamic]u8, 0, ID_SIZE + 2 + len(v.language) + len(v.lexical), context.temp_allocator)
	resize(&canonical, ID_SIZE)
	put_id_be(canonical[:ID_SIZE], dt)
	append(&canonical, u8(v.direction))
	append(&canonical, u8(len(v.language)))
	append(&canonical, v.language)
	append(&canonical, v.lexical)
	return canonical[:]
}

// triple_canonical writes a triple term's canonical bytes — its three
// component IDs, big-endian — into a 3*ID_SIZE buffer.
@(private)
triple_canonical :: proc(buf: []u8, components: [3]store.Term_ID) {
	for c, i in components {
		put_id_be(buf[i * ID_SIZE:][:ID_SIZE], c)
	}
}

// intern_triple_ids_txn interns the RDF-star triple term whose
// components are the given already-interned IDs — the entry point for
// callers that map components themselves (the loaders' blank-node
// scoping).
@(private)
intern_triple_ids_txn :: proc(
	s: ^Store,
	txn: ^lmdb.Txn,
	components: [3]store.Term_ID,
) -> (
	id: store.Term_ID,
	err: Error,
) {
	canonical: [3 * ID_SIZE]u8
	triple_canonical(canonical[:], components)
	return intern_canonical(s, txn, .Triple, canonical[:])
}

// probe_canonical is the verified term2id lookup of STORE-A-0003 §4:
// hash the canonical bytes, then confirm any hit against the id2term
// content behind the candidate ID, so a true collision between distinct
// terms is detected rather than silently answered with the wrong ID.
// Read-only — the lookup half shared by intern_canonical and find_term.
@(private)
probe_canonical :: proc(
	s: ^Store,
	txn: ^lmdb.Txn,
	kind: store.Term_Kind,
	canonical: []u8,
) -> (
	id: store.Term_ID,
	found: bool,
	err: Error,
) {
	key_buf: [TERM2ID_KEY_SIZE]u8
	term2id_key(key_buf[:], kind, canonical)
	key := val_of(key_buf[:])

	data: lmdb.Val
	rc := lmdb.get(txn, s.dbi[.Term2id], &key, &data)
	if rc == lmdb.NOTFOUND {
		return 0, false, nil
	}
	check(rc) or_return

	candidate := get_id_be(val_bytes(data))
	stored := id2term_get(s, txn, candidate) or_return
	if string(stored) != string(canonical) {
		// Distinct content behind the same 128-bit key: the
		// detected-and-rejected path (format v2 would chain here).
		return 0, false, .Hash_Collision
	}
	return candidate, true, nil
}

// intern_canonical interns pre-built canonical bytes: the verified
// term2id probe, then fresh-ID assignment with the per-kind counter
// persisted in the same transaction.
@(private)
intern_canonical :: proc(
	s: ^Store,
	txn: ^lmdb.Txn,
	kind: store.Term_Kind,
	canonical: []u8,
) -> (
	id: store.Term_ID,
	err: Error,
) {
	existing, found := probe_canonical(s, txn, kind, canonical) or_return
	if found {
		return existing, nil
	}

	counter := s.next[u8(kind)]
	assert(counter <= store.MAX_COUNTER, "dictionary: per-kind term capacity exhausted")
	id = store.make_id(kind, counter)

	id_buf: [ID_SIZE]u8
	put_id_be(id_buf[:], id)
	id_key := val_of(id_buf[:])
	content := val_of(canonical)
	check(lmdb.put(txn, s.dbi[.Id2term], &id_key, &content, 0)) or_return

	key_buf: [TERM2ID_KEY_SIZE]u8
	term2id_key(key_buf[:], kind, canonical)
	key := val_of(key_buf[:])
	id_val := val_of(id_buf[:])
	check(lmdb.put(txn, s.dbi[.Term2id], &key, &id_val, 0)) or_return

	s.next[u8(kind)] = counter + 1
	counter_keys := meta_counter_keys
	meta_put(s, txn, counter_keys[u8(kind)], counter + 1) or_return
	return id, nil
}

// find_term returns the ID a term already has, or found=false if the
// store has never seen it. Unlike intern_term it assigns nothing and
// writes nothing: it runs in a read transaction, so it is the query
// path's entry point — resolving a query constant that happens to be
// absent must neither grow the dictionary nor require a writable
// environment. Works against a store opened read-only.
find_term :: proc(s: ^Store, term: rdf.Term) -> (id: store.Term_ID, found: bool, err: Error) {
	txn: ^lmdb.Txn
	check(lmdb.txn_begin(s.env, nil, lmdb.RDONLY, &txn)) or_return
	defer lmdb.txn_abort(txn)
	return find_term_txn(s, txn, term)
}

// find_term_txn is find_term inside a caller-owned transaction (read or
// write), mirroring intern_term_txn minus every assignment.
find_term_txn :: proc(
	s: ^Store,
	txn: ^lmdb.Txn,
	term: rdf.Term,
) -> (
	id: store.Term_ID,
	found: bool,
	err: Error,
) {
	switch v in term {
	case rdf.IRI:
		return probe_canonical(s, txn, .IRI, transmute([]u8)string(v))

	case rdf.Blank_Node:
		return probe_canonical(s, txn, .Blank_Node, transmute([]u8)string(v))

	case rdf.Literal:
		if len(v.language) > 255 {
			// Too long for the format's language field, so no stored
			// literal can carry it. On the read path that is simply
			// absent, not the error interning would raise.
			return 0, false, nil
		}
		dt, dt_found := probe_canonical(s, txn, .IRI, transmute([]u8)string(v.datatype)) or_return
		if !dt_found {
			return 0, false, nil
		}
		return probe_canonical(s, txn, .Literal, literal_canonical(dt, v))

	case ^rdf.Triple:
		// Component-wise: a triple term whose parts are not all present
		// cannot itself be present.
		assert(v != nil, "find_term_txn: nil triple term")
		components: [3]store.Term_ID
		for part, i in ([3]rdf.Term{v.subject, v.predicate, v.object}) {
			component, component_found := find_term_txn(s, txn, part) or_return
			if !component_found {
				return 0, false, nil
			}
			components[i] = component
		}
		canonical: [3 * ID_SIZE]u8
		triple_canonical(canonical[:], components)
		return probe_canonical(s, txn, .Triple, canonical[:])
	}
	panic("find_term_txn: nil term")
}

// id2term_get reads a term's canonical bytes; the slice is a view into
// the mapped page, valid only within txn.
@(private)
id2term_get :: proc(s: ^Store, txn: ^lmdb.Txn, id: store.Term_ID) -> (canonical: []u8, err: Error) {
	id_buf: [ID_SIZE]u8
	put_id_be(id_buf[:], id)
	key := val_of(id_buf[:])
	data: lmdb.Val
	check(lmdb.get(txn, s.dbi[.Id2term], &key, &data)) or_return
	return val_bytes(data), nil
}

// intern_graph_label returns the ID for a quad's graph position: the
// interned label, or DEFAULT_GRAPH for a nil label.
intern_graph_label :: proc(s: ^Store, g: rdf.Graph_Label) -> (id: store.Term_ID, err: Error) {
	switch v in g {
	case rdf.IRI:
		return intern_term(s, v)
	case rdf.Blank_Node:
		return intern_term(s, v)
	}
	return store.DEFAULT_GRAPH, nil
}

@(private)
intern_graph_label_txn :: proc(s: ^Store, txn: ^lmdb.Txn, g: rdf.Graph_Label) -> (id: store.Term_ID, err: Error) {
	switch v in g {
	case rdf.IRI:
		return intern_term_txn(s, txn, v)
	case rdf.Blank_Node:
		return intern_term_txn(s, txn, v)
	}
	return store.DEFAULT_GRAPH, nil
}

// find_graph_label is find_term for the graph position: a nil label is
// always found, as DEFAULT_GRAPH.
find_graph_label :: proc(s: ^Store, g: rdf.Graph_Label) -> (id: store.Term_ID, found: bool, err: Error) {
	switch v in g {
	case rdf.IRI:
		return find_term(s, v)
	case rdf.Blank_Node:
		return find_term(s, v)
	}
	return store.DEFAULT_GRAPH, true, nil
}

// fresh_blank interns a brand-new blank node distinct from every
// existing term, under a generated label ("b0", "b1", ...) skipping
// any label already taken — the loaders' per-load scoping hook.
@(private)
fresh_blank_txn :: proc(s: ^Store, txn: ^lmdb.Txn) -> (id: store.Term_ID, err: Error) {
	n := s.next[u8(store.Term_Kind.Blank_Node)]
	label_buf: [24]u8
	for {
		label := format_blank_label(label_buf[:], n)
		canonical := transmute([]u8)label

		key_buf: [TERM2ID_KEY_SIZE]u8
		term2id_key(key_buf[:], .Blank_Node, canonical)
		key := val_of(key_buf[:])
		data: lmdb.Val
		rc := lmdb.get(txn, s.dbi[.Term2id], &key, &data)
		if rc == lmdb.NOTFOUND {
			return intern_canonical(s, txn, .Blank_Node, canonical)
		}
		check(rc) or_return
		n += 1
	}
}

@(private)
format_blank_label :: proc(buf: []u8, n: u64) -> string {
	buf[0] = 'b'
	if n == 0 {
		buf[1] = '0'
		return string(buf[:2])
	}
	digits: [20]u8
	count := 0
	for v := n; v > 0; v /= 10 {
		digits[count] = '0' + u8(v % 10)
		count += 1
	}
	for i in 0 ..< count {
		buf[1 + i] = digits[count - 1 - i]
	}
	return string(buf[:1 + count])
}

// lookup_term materializes the term an ID was assigned to, copying
// every string into the given allocator: the result owns nothing of
// the store and stays valid after the store closes.
lookup_term :: proc(s: ^Store, id: store.Term_ID, allocator := context.allocator) -> (term: rdf.Term, err: Error) {
	txn: ^lmdb.Txn
	check(lmdb.txn_begin(s.env, nil, lmdb.RDONLY, &txn)) or_return
	defer lmdb.txn_abort(txn)
	return lookup_term_txn(s, txn, id, allocator)
}

@(private)
lookup_term_txn :: proc(
	s: ^Store,
	txn: ^lmdb.Txn,
	id: store.Term_ID,
	allocator: runtime.Allocator,
) -> (
	term: rdf.Term,
	err: Error,
) {
	canonical := id2term_get(s, txn, id) or_return
	#partial switch store.id_kind(id) {
	case .IRI:
		return rdf.IRI(strings.clone(string(canonical), allocator)), nil
	case .Blank_Node:
		return rdf.Blank_Node(strings.clone(string(canonical), allocator)), nil
	case .Literal:
		dt := get_id_be(canonical[:ID_SIZE])
		dt_bytes := id2term_get(s, txn, dt) or_return
		direction := rdf.Direction(canonical[ID_SIZE])
		lang_len := int(canonical[ID_SIZE + 1])
		lang := string(canonical[ID_SIZE + 2:][:lang_len])
		lexical := string(canonical[ID_SIZE + 2 + lang_len:])
		return rdf.Literal {
				lexical = strings.clone(lexical, allocator),
				datatype = rdf.IRI(strings.clone(string(dt_bytes), allocator)),
				language = strings.clone(lang, allocator),
				direction = direction,
			},
			nil
	case .Triple:
		node := new(rdf.Triple, allocator)
		node.subject = lookup_term_txn(s, txn, get_id_be(canonical[0 * ID_SIZE:][:ID_SIZE]), allocator) or_return
		node.predicate = lookup_term_txn(s, txn, get_id_be(canonical[1 * ID_SIZE:][:ID_SIZE]), allocator) or_return
		node.object = lookup_term_txn(s, txn, get_id_be(canonical[2 * ID_SIZE:][:ID_SIZE]), allocator) or_return
		return node, nil
	}
	panic("lookup_term: not a term ID")
}

// lookup_graph_label is lookup_term for the graph position:
// DEFAULT_GRAPH maps back to the nil label.
lookup_graph_label :: proc(s: ^Store, id: store.Term_ID, allocator := context.allocator) -> (g: rdf.Graph_Label, err: Error) {
	if id == store.DEFAULT_GRAPH {
		return nil, nil
	}
	term := lookup_term(s, id, allocator) or_return
	#partial switch v in term {
	case rdf.IRI:
		return v, nil
	case rdf.Blank_Node:
		return v, nil
	}
	panic("lookup_graph_label: not a graph label ID")
}

// encode_quad interns all four positions of a quad in one write
// transaction.
encode_quad :: proc(s: ^Store, q: rdf.Quad) -> (encoded: store.Encoded_Quad, err: Error) {
	txn: ^lmdb.Txn
	check(lmdb.txn_begin(s.env, nil, 0, &txn)) or_return
	committed := false
	defer if !committed {
		lmdb.txn_abort(txn)
	}
	encoded = encode_quad_txn(s, txn, q) or_return
	check(lmdb.txn_commit(txn)) or_return
	committed = true
	return encoded, nil
}

@(private)
encode_quad_txn :: proc(s: ^Store, txn: ^lmdb.Txn, q: rdf.Quad) -> (encoded: store.Encoded_Quad, err: Error) {
	encoded[store.QUAD_S] = intern_term_txn(s, txn, q.subject) or_return
	encoded[store.QUAD_P] = intern_term_txn(s, txn, q.predicate) or_return
	encoded[store.QUAD_O] = intern_term_txn(s, txn, q.object) or_return
	encoded[store.QUAD_G] = intern_graph_label_txn(s, txn, q.graph) or_return
	return encoded, nil
}

// decode_quad materializes an encoded quad; see lookup_term for the
// ownership contract.
decode_quad :: proc(s: ^Store, q: store.Encoded_Quad, allocator := context.allocator) -> (decoded: rdf.Quad, err: Error) {
	txn: ^lmdb.Txn
	check(lmdb.txn_begin(s.env, nil, lmdb.RDONLY, &txn)) or_return
	defer lmdb.txn_abort(txn)

	decoded.subject = lookup_term_txn(s, txn, q[store.QUAD_S], allocator) or_return
	decoded.predicate = lookup_term_txn(s, txn, q[store.QUAD_P], allocator) or_return
	decoded.object = lookup_term_txn(s, txn, q[store.QUAD_O], allocator) or_return
	if q[store.QUAD_G] == store.DEFAULT_GRAPH {
		decoded.graph = nil
	} else {
		term := lookup_term_txn(s, txn, q[store.QUAD_G], allocator) or_return
		#partial switch v in term {
		case rdf.IRI:
			decoded.graph = v
		case rdf.Blank_Node:
			decoded.graph = v
		}
	}
	return decoded, nil
}
