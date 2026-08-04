package kvstore

import "core:hash/xxhash"
import "core:mem"
import "core:strings"
import "core:testing"

import rdf "../../../odin-rdf-parser/rdf"
import lmdb "../../vendor/lmdb"
import store ".."

// with_store opens a fresh store in a temp directory; shared by this
// package's test files.
@(private)
with_store :: proc(name: string) -> (path: string, s: ^Store) {
	path = test_db_path(name)
	opened, err := open(path)
	assert(err == nil, "test store must open")
	return path, opened
}

@(test)
test_dict_intern_twice_same_id :: proc(t: ^testing.T) {
	path, s := with_store("dict-twice")
	defer remove_test_db(path)
	defer close(s)

	iri, err := intern_term(s, rdf.IRI("http://example.org/a"))
	testing.expect(t, err == nil)
	testing.expect_value(t, store.id_kind(iri), store.Term_Kind.IRI)
	again, _ := intern_term(s, rdf.IRI("http://example.org/a"))
	testing.expect_value(t, again, iri)

	// Content-based across buffers: an equal string in different
	// backing storage interns to the same ID.
	cloned := strings.clone("http://example.org/a")
	defer delete(cloned)
	from_clone, _ := intern_term(s, rdf.IRI(cloned))
	testing.expect_value(t, from_clone, iri)

	blank, _ := intern_term(s, rdf.Blank_Node("a"))
	testing.expect(t, blank != iri) // same spelling, different kind

	lit, _ := intern_term(s, rdf.literal("chat", "fr"))
	lit2, _ := intern_term(s, rdf.literal("chat", "fr"))
	testing.expect_value(t, lit2, lit)
}

@(test)
test_dict_literal_distinctions_and_round_trip :: proc(t: ^testing.T) {
	path, s := with_store("dict-lit")
	defer remove_test_db(path)
	defer close(s)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	allocator := mem.dynamic_arena_allocator(&arena)

	inner := rdf.Triple {
		subject   = rdf.IRI("http://example.org/s"),
		predicate = rdf.IRI("http://example.org/p"),
		object    = rdf.literal("שלום", "he", rdf.Direction.RTL),
	}
	outer := rdf.Triple {
		subject   = rdf.Blank_Node("b1"),
		predicate = rdf.RDF_TYPE,
		object    = &inner, // nested RDF-star triple term
	}
	terms := [?]rdf.Term {
		rdf.IRI("http://example.org/s"),
		rdf.Blank_Node("b1"),
		rdf.literal("chat"),
		rdf.literal("chat", "en"),
		rdf.literal("chat", "fr"),
		rdf.literal("chat", "fr", rdf.Direction.LTR),
		rdf.literal_typed("chat", rdf.IRI("http://example.org/dt")),
		&outer,
	}

	ids := make([dynamic]store.Term_ID, 0, len(terms))
	defer delete(ids)
	for term in terms {
		id, err := intern_term(s, term)
		testing.expect(t, err == nil)
		// Distinct from every previously interned term.
		for prev in ids {
			testing.expect(t, id != prev)
		}
		append(&ids, id)

		decoded, derr := lookup_term(s, id, allocator)
		testing.expect(t, derr == nil)
		testing.expect(t, rdf.equal(decoded, term))
	}
}

@(test)
test_dict_lookup_outlives_store :: proc(t: ^testing.T) {
	// The copying-lookup contract: a decoded term owns nothing of the
	// store and survives its close.
	path, s := with_store("dict-outlive")
	defer remove_test_db(path)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	allocator := mem.dynamic_arena_allocator(&arena)

	id, _ := intern_term(s, rdf.literal("survivor", "en"))
	decoded, err := lookup_term(s, id, allocator)
	testing.expect(t, err == nil)
	close(s)

	testing.expect(t, rdf.equal(decoded, rdf.Term(rdf.literal("survivor", "en"))))
}

@(test)
test_dict_reopen_stability :: proc(t: ^testing.T) {
	path := test_db_path("dict-reopen")
	defer remove_test_db(path)

	s, err := open(path)
	testing.expect(t, err == nil)
	a, _ := intern_term(s, rdf.IRI("http://example.org/a"))
	b, _ := intern_term(s, rdf.literal("x"))
	close(s)

	s2, err2 := open(path)
	testing.expect(t, err2 == nil)
	defer close(s2)

	// Same terms, same IDs across the reopen ...
	a2, _ := intern_term(s2, rdf.IRI("http://example.org/a"))
	b2, _ := intern_term(s2, rdf.literal("x"))
	testing.expect_value(t, a2, a)
	testing.expect_value(t, b2, b)

	// ... and a new term continues the counter, never reusing one.
	// IRI counters so far: 0 = ex:a, 1 = xsd:string (interned as the
	// literal's datatype), so the next fresh IRI is 2.
	c, _ := intern_term(s2, rdf.IRI("http://example.org/c"))
	testing.expect_value(t, c, store.make_id(.IRI, 2))
}

@(test)
test_dict_exact_bytes :: proc(t: ^testing.T) {
	// Pins STORE-A-0003 §§2-4 literally: exact id2term and term2id
	// bytes for known terms, not just behavioral round-trips.
	path, s := with_store("dict-bytes")
	defer remove_test_db(path)
	defer close(s)

	iri_id, _ := intern_term(s, rdf.IRI("http://example.org/a")) // first intern: IRI counter 0
	testing.expect_value(t, iri_id, store.make_id(.IRI, 0))
	lit_id, _ := intern_term(s, rdf.literal("chat", "fr"))
	testing.expect_value(t, store.id_counter(lit_id), u64(0))

	txn: ^lmdb.Txn
	testing.expect_value(t, lmdb.txn_begin(s.env, nil, lmdb.RDONLY, &txn), i32(lmdb.SUCCESS))
	defer lmdb.txn_abort(txn)

	// id2term: key = big-endian ID, value = raw IRI bytes.
	key_buf: [ID_SIZE]u8 // ID 0: all zero bytes
	key := val_of(key_buf[:])
	data: lmdb.Val
	testing.expect_value(t, lmdb.get(txn, s.dbi[.Id2term], &key, &data), i32(lmdb.SUCCESS))
	testing.expect_value(t, string(val_bytes(data)), "http://example.org/a")

	// The literal's canonical bytes: datatype ID (rdf:langString was
	// interned as the second IRI, counter 1), direction 0, lang length
	// 2, "fr", then the lexical form.
	lit_key_buf: [ID_SIZE]u8
	put_id_be(lit_key_buf[:], lit_id)
	lit_key := val_of(lit_key_buf[:])
	testing.expect_value(t, lmdb.get(txn, s.dbi[.Id2term], &lit_key, &data), i32(lmdb.SUCCESS))
	got := val_bytes(data)

	expected := make([dynamic]u8, ID_SIZE)
	defer delete(expected)
	put_id_be(expected[:ID_SIZE], store.make_id(.IRI, 1))
	append(&expected, 0, 2)
	append(&expected, "fr")
	append(&expected, "chat")
	testing.expect_value(t, string(got), string(expected[:]))

	// term2id: key = kind byte + big-endian XXH3-128 of the canonical
	// bytes; value = the big-endian ID.
	t2i_buf: [TERM2ID_KEY_SIZE]u8
	t2i_buf[0] = u8(store.Term_Kind.IRI)
	hash := xxhash.XXH3_128_default(transmute([]u8)string("http://example.org/a"))
	for i in 0 ..< 16 {
		t2i_buf[1 + i] = u8(hash >> uint((15 - i) * 8))
	}
	t2i_key := val_of(t2i_buf[:])
	testing.expect_value(t, lmdb.get(txn, s.dbi[.Term2id], &t2i_key, &data), i32(lmdb.SUCCESS))
	testing.expect_value(t, get_id_be(val_bytes(data)), iri_id)
}

@(test)
test_dict_hash_collision_rejected :: proc(t: ^testing.T) {
	// Plants a colliding term2id entry directly: the key for content B
	// mapped to the ID of content A. Interning B then hits the key,
	// fails verification against id2term, and must reject.
	path, s := with_store("dict-collision")
	defer remove_test_db(path)
	defer close(s)

	a_id, _ := intern_term(s, rdf.IRI("collision-a"))

	txn: ^lmdb.Txn
	testing.expect_value(t, lmdb.txn_begin(s.env, nil, 0, &txn), i32(lmdb.SUCCESS))
	key_buf: [TERM2ID_KEY_SIZE]u8
	term2id_key(key_buf[:], .IRI, transmute([]u8)string("collision-b"))
	key := val_of(key_buf[:])
	id_buf: [ID_SIZE]u8
	put_id_be(id_buf[:], a_id)
	data := val_of(id_buf[:])
	testing.expect_value(t, lmdb.put(txn, s.dbi[.Term2id], &key, &data, 0), i32(lmdb.SUCCESS))
	testing.expect_value(t, lmdb.txn_commit(txn), i32(lmdb.SUCCESS))

	_, err := intern_term(s, rdf.IRI("collision-b"))
	testing.expect_value(t, err, Error(Store_Error.Hash_Collision))
}

@(test)
test_dict_language_too_long :: proc(t: ^testing.T) {
	path, s := with_store("dict-lang")
	defer remove_test_db(path)
	defer close(s)

	long := strings.repeat("x", 256)
	defer delete(long)
	bad := rdf.Literal {
		lexical  = "v",
		datatype = rdf.RDF_LANG_STRING,
		language = long,
	}
	_, err := intern_term(s, bad)
	testing.expect_value(t, err, Error(Store_Error.Language_Too_Long))
}

@(test)
test_dict_graph_labels_and_quads :: proc(t: ^testing.T) {
	path, s := with_store("dict-graphs")
	defer remove_test_db(path)
	defer close(s)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	allocator := mem.dynamic_arena_allocator(&arena)

	dg, err := intern_graph_label(s, nil)
	testing.expect(t, err == nil)
	testing.expect_value(t, dg, store.DEFAULT_GRAPH)
	back, _ := lookup_graph_label(s, store.DEFAULT_GRAPH, allocator)
	testing.expect(t, back == nil)

	q := rdf.Quad {
		triple = rdf.Triple {
			subject   = rdf.Blank_Node("s"),
			predicate = rdf.IRI("http://example.org/p"),
			object    = rdf.literal("chat", "fr"),
		},
		graph = rdf.IRI("http://example.org/g"),
	}
	encoded, eerr := encode_quad(s, q)
	testing.expect(t, eerr == nil)
	decoded, derr := decode_quad(s, encoded, allocator)
	testing.expect(t, derr == nil)
	testing.expect(t, rdf.equal(decoded, q))

	q_default := q
	q_default.graph = nil
	encoded_default, _ := encode_quad(s, q_default)
	testing.expect_value(t, encoded_default[store.QUAD_G], store.DEFAULT_GRAPH)
	decoded_default, _ := decode_quad(s, encoded_default, allocator)
	testing.expect(t, rdf.equal(decoded_default, q_default))
}

@(test)
test_dict_fresh_blank :: proc(t: ^testing.T) {
	path, s := with_store("dict-fresh")
	defer remove_test_db(path)
	defer close(s)

	// Take the "b0" label first, so fresh_blank must skip it.
	taken, _ := intern_term(s, rdf.Blank_Node("b0"))

	txn: ^lmdb.Txn
	testing.expect_value(t, lmdb.txn_begin(s.env, nil, 0, &txn), i32(lmdb.SUCCESS))
	f1, err1 := fresh_blank_txn(s, txn)
	testing.expect(t, err1 == nil)
	f2, err2 := fresh_blank_txn(s, txn)
	testing.expect(t, err2 == nil)
	testing.expect_value(t, lmdb.txn_commit(txn), i32(lmdb.SUCCESS))

	testing.expect(t, f1 != taken)
	testing.expect(t, f2 != taken)
	testing.expect(t, f1 != f2)
}
