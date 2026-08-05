// Package memstore is the in-memory reference backend of the match
// interface (contract: store/interface.odin): a term dictionary
// interning rdf.Term values to Term_IDs, a permutation-indexed quad
// dataset, and bulk loaders for the four odin-rdf-parser formats.
// Append-only in v1; no external dependencies.
//
// Lifetime rules: terms returned by lookup_term/decode_quad borrow
// their strings from dictionary storage and stay valid until
// dictionary_destroy — no other operation invalidates them. Iterators
// are valid until their dataset is mutated or destroyed. Every *_init
// takes `allocator := context.allocator` and owns what it allocates
// until the matching *_destroy.
package memstore

import store ".."

import "base:runtime"
import "core:strings"
import "rdf:rdf"

// Dictionary interns RDF terms to Term_IDs and looks them back up.
// Interning equal terms (per rdf.equal semantics) returns the same ID;
// IDs are assigned densely per kind in first-seen order, so reverse
// lookup is an array index.
//
// Lifetime contract: interning clones every string into
// dictionary-owned storage, so interning a term borrowed from a parser
// statement is safe (RDF-A-0001). Terms returned by lookup_term borrow
// their strings from dictionary storage and remain valid until
// dictionary_destroy. The dictionary never garbage-collects: entries
// live until destroy.
//
// Exhausting a kind's counter space (store.MAX_COUNTER + 1 terms of one
// kind) is treated like out-of-memory: an assertion failure, not an
// error value. The 64-bit default build cannot reach it in practice.
Dictionary :: struct {
	allocator: runtime.Allocator,

	// Every distinct string is stored once; keys and values are the
	// same owned string (the parser's Intern_Table arrangement).
	owned: map[string]string,

	// Per-kind entries, indexed by store.id_counter. Literal strings and the
	// terms inside triple nodes reference `owned` storage.
	iris:         [dynamic]string,
	blanks:       [dynamic]string,
	literals:     [dynamic]rdf.Literal,
	triples:      [dynamic][3]store.Term_ID, // component IDs: s, p, o
	triple_nodes: [dynamic]^rdf.Triple, // materialized once at intern time

	// Content -> ID. Keys reference dictionary-owned strings; probing
	// with borrowed strings works because Odin maps hash and compare
	// string content, not backing pointers (pinned by a test).
	iri_ids:     map[string]store.Term_ID,
	blank_ids:   map[string]store.Term_ID,
	literal_ids: map[rdf.Literal]store.Term_ID,
	triple_ids:  map[[3]store.Term_ID]store.Term_ID,
}

// dictionary_init prepares a dictionary; all memory comes from the
// given allocator.
dictionary_init :: proc(d: ^Dictionary, allocator := context.allocator) {
	d.allocator = allocator
	d.owned = make(map[string]string, 8, allocator)
	d.iris = make([dynamic]string, 0, 8, allocator)
	d.blanks = make([dynamic]string, 0, 8, allocator)
	d.literals = make([dynamic]rdf.Literal, 0, 8, allocator)
	d.triples = make([dynamic][3]store.Term_ID, 0, 8, allocator)
	d.triple_nodes = make([dynamic]^rdf.Triple, 0, 8, allocator)
	d.iri_ids = make(map[string]store.Term_ID, 8, allocator)
	d.blank_ids = make(map[string]store.Term_ID, 8, allocator)
	d.literal_ids = make(map[rdf.Literal]store.Term_ID, 8, allocator)
	d.triple_ids = make(map[[3]store.Term_ID]store.Term_ID, 8, allocator)
}

// dictionary_destroy frees everything the dictionary owns; every ID
// and every term obtained from it becomes invalid.
dictionary_destroy :: proc(d: ^Dictionary) {
	for _, s in d.owned {
		delete(s, d.allocator)
	}
	delete(d.owned)
	delete(d.iris)
	delete(d.blanks)
	delete(d.literals)
	delete(d.triples)
	for node in d.triple_nodes {
		free(node, d.allocator)
	}
	delete(d.triple_nodes)
	delete(d.iri_ids)
	delete(d.blank_ids)
	delete(d.literal_ids)
	delete(d.triple_ids)
	d^ = {}
}

@(private)
intern_string :: proc(d: ^Dictionary, s: string) -> string {
	if existing, ok := d.owned[s]; ok {
		return existing
	}
	owned := strings.clone(s, d.allocator)
	d.owned[owned] = owned
	return owned
}

@(private)
check_capacity :: proc(entries: int) {
	assert(u64(entries) <= store.MAX_COUNTER, "dictionary: per-kind term capacity exhausted")
}

// intern_term returns the ID of a term, assigning a fresh one on first
// sight. A nil term is not a valid RDF term and asserts.
intern_term :: proc(d: ^Dictionary, term: rdf.Term) -> store.Term_ID {
	switch v in term {
	case rdf.IRI:
		if id, ok := d.iri_ids[string(v)]; ok {
			return id
		}
		check_capacity(len(d.iris))
		id := store.make_id(.IRI, u64(len(d.iris)))
		owned := intern_string(d, string(v))
		append(&d.iris, owned)
		d.iri_ids[owned] = id
		return id

	case rdf.Blank_Node:
		if id, ok := d.blank_ids[string(v)]; ok {
			return id
		}
		check_capacity(len(d.blanks))
		id := store.make_id(.Blank_Node, u64(len(d.blanks)))
		owned := intern_string(d, string(v))
		append(&d.blanks, owned)
		d.blank_ids[owned] = id
		return id

	case rdf.Literal:
		if id, ok := d.literal_ids[v]; ok {
			return id
		}
		check_capacity(len(d.literals))
		id := store.make_id(.Literal, u64(len(d.literals)))
		owned := rdf.Literal {
			lexical   = intern_string(d, v.lexical),
			datatype  = rdf.IRI(intern_string(d, string(v.datatype))),
			language  = intern_string(d, v.language),
			direction = v.direction,
		}
		append(&d.literals, owned)
		d.literal_ids[owned] = id
		return id

	case ^rdf.Triple:
		assert(v != nil, "intern_term: nil triple term")
		return intern_triple_ids(
			d,
			[3]store.Term_ID {
				intern_term(d, v.subject),
				intern_term(d, v.predicate),
				intern_term(d, v.object),
			},
		)
	}
	panic("intern_term: nil term")
}

// intern_triple_ids interns the RDF-star triple term whose components
// are the given already-interned IDs — the entry point for callers
// that map components themselves (e.g. blank-node scoping on ingest).
intern_triple_ids :: proc(d: ^Dictionary, components: [3]store.Term_ID) -> store.Term_ID {
	if id, ok := d.triple_ids[components]; ok {
		return id
	}
	check_capacity(len(d.triples))
	id := store.make_id(.Triple, u64(len(d.triples)))
	node := new(rdf.Triple, d.allocator)
	node^ = rdf.Triple {
		subject   = lookup_term(d, components[0]),
		predicate = lookup_term(d, components[1]),
		object    = lookup_term(d, components[2]),
	}
	append(&d.triples, components)
	append(&d.triple_nodes, node)
	d.triple_ids[components] = id
	return id
}

// fresh_blank interns a brand-new blank node distinct from every
// existing term, under a generated label ("b0", "b1", ...) skipping any
// label already taken. Used by the load procedures to give each load
// its own blank-node scope.
fresh_blank :: proc(d: ^Dictionary) -> store.Term_ID {
	n := len(d.blanks)
	label_buf: [24]u8
	for {
		label := format_blank_label(label_buf[:], n)
		if label not_in d.blank_ids {
			check_capacity(len(d.blanks))
			id := store.make_id(.Blank_Node, u64(len(d.blanks)))
			owned := intern_string(d, label)
			append(&d.blanks, owned)
			d.blank_ids[owned] = id
			return id
		}
		n += 1
	}
}

@(private)
format_blank_label :: proc(buf: []u8, n: int) -> string {
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

// intern_graph_label returns the ID for a quad's graph position: the
// interned label, or store.DEFAULT_GRAPH for a nil label.
intern_graph_label :: proc(d: ^Dictionary, g: rdf.Graph_Label) -> store.Term_ID {
	switch v in g {
	case rdf.IRI:
		return intern_term(d, v)
	case rdf.Blank_Node:
		return intern_term(d, v)
	}
	return store.DEFAULT_GRAPH
}

// lookup_term returns the term an ID was assigned to. The term's
// strings are borrowed from dictionary storage, valid until
// dictionary_destroy. The ID must have been produced by this
// dictionary; sentinel and unknown IDs assert.
lookup_term :: proc(d: ^Dictionary, id: store.Term_ID) -> rdf.Term {
	counter := store.id_counter(id)
	#partial switch store.id_kind(id) {
	case .IRI:
		return rdf.IRI(d.iris[counter])
	case .Blank_Node:
		return rdf.Blank_Node(d.blanks[counter])
	case .Literal:
		return d.literals[counter]
	case .Triple:
		return d.triple_nodes[counter]
	}
	panic("lookup_term: not a term ID")
}

// lookup_graph_label is lookup_term for the graph position:
// store.DEFAULT_GRAPH maps back to the nil label.
lookup_graph_label :: proc(d: ^Dictionary, id: store.Term_ID) -> rdf.Graph_Label {
	if id == store.DEFAULT_GRAPH {
		return nil
	}
	counter := store.id_counter(id)
	#partial switch store.id_kind(id) {
	case .IRI:
		return rdf.IRI(d.iris[counter])
	case .Blank_Node:
		return rdf.Blank_Node(d.blanks[counter])
	}
	panic("lookup_graph_label: not a graph label ID")
}

// encode_quad interns all four positions of a quad.
encode_quad :: proc(d: ^Dictionary, q: rdf.Quad) -> store.Encoded_Quad {
	return store.Encoded_Quad {
		intern_term(d, q.subject),
		intern_term(d, q.predicate),
		intern_term(d, q.object),
		intern_graph_label(d, q.graph),
	}
}

// decode_quad materializes an encoded quad; term strings are borrowed
// from dictionary storage (see lookup_term).
decode_quad :: proc(d: ^Dictionary, q: store.Encoded_Quad) -> rdf.Quad {
	return rdf.Quad {
		triple = rdf.Triple {
			subject   = lookup_term(d, q[store.QUAD_S]),
			predicate = lookup_term(d, q[store.QUAD_P]),
			object    = lookup_term(d, q[store.QUAD_O]),
		},
		graph = lookup_graph_label(d, q[store.QUAD_G]),
	}
}
