package kvstore

// The LMDB backend's instantiation of the shared conformance suite
// (the executable match interface contract) — same five checks the
// in-memory backend runs, over a database file. No harness
// modifications: a Backend adapter and thin @(test) wrappers only.

import "core:testing"

import rdf "../../../odin-rdf-parser/rdf"
import "../../conformance"
import store ".."

@(private = "file")
Lmdb_Backend :: struct {
	path: string,
	s:    ^Store,
}

@(private = "file")
lmdb_backend_init :: proc(m: ^Lmdb_Backend, name: string) -> conformance.Backend {
	m.path = test_db_path(name)
	s, err := open(m.path)
	assert(err == nil, "test store must open")
	m.s = s
	return conformance.Backend {
		ctx = m,
		insert = proc(ctx: rawptr, q: store.Encoded_Quad) -> bool {
			added, err := insert((^Lmdb_Backend)(ctx).s, q)
			assert(err == nil)
			return added
		},
		count = proc(ctx: rawptr) -> int {
			n, err := count((^Lmdb_Backend)(ctx).s)
			assert(err == nil)
			return n
		},
		match_begin = proc(ctx: rawptr, pattern: store.Match_Pattern) -> rawptr {
			it := new(Match_Iterator)
			iter, err := match((^Lmdb_Backend)(ctx).s, pattern)
			assert(err == nil)
			it^ = iter
			return it
		},
		match_next = proc(it: rawptr) -> (store.Encoded_Quad, bool) {
			return match_next((^Match_Iterator)(it))
		},
		match_destroy = proc(it: rawptr) {
			typed := (^Match_Iterator)(it)
			match_destroy(typed)
			free(typed)
		},
		intern_term = proc(ctx: rawptr, term: rdf.Term) -> store.Term_ID {
			id, err := intern_term((^Lmdb_Backend)(ctx).s, term)
			assert(err == nil)
			return id
		},
		encode_quad = proc(ctx: rawptr, q: rdf.Quad) -> store.Encoded_Quad {
			encoded, err := encode_quad((^Lmdb_Backend)(ctx).s, q)
			assert(err == nil)
			return encoded
		},
		intern_graph = proc(ctx: rawptr, g: rdf.Graph_Label) -> store.Term_ID {
			id, err := intern_graph_label((^Lmdb_Backend)(ctx).s, g)
			assert(err == nil)
			return id
		},
	}
}

@(private = "file")
lmdb_backend_destroy :: proc(m: ^Lmdb_Backend) {
	close(m.s)
	remove_test_db(m.path)
}

@(test)
test_lmdb_all_16_patterns :: proc(t: ^testing.T) {
	m: Lmdb_Backend
	b := lmdb_backend_init(&m, "conf-16")
	defer lmdb_backend_destroy(&m)
	conformance.check_all_16_patterns(t, &b)
}

@(test)
test_lmdb_set_semantics :: proc(t: ^testing.T) {
	m: Lmdb_Backend
	b := lmdb_backend_init(&m, "conf-set")
	defer lmdb_backend_destroy(&m)
	conformance.check_set_semantics(t, &b)
}

@(test)
test_lmdb_empty_dataset :: proc(t: ^testing.T) {
	m: Lmdb_Backend
	b := lmdb_backend_init(&m, "conf-empty")
	defer lmdb_backend_destroy(&m)
	conformance.check_empty_dataset(t, &b)
}

@(test)
test_lmdb_no_match_and_exhaustion :: proc(t: ^testing.T) {
	m: Lmdb_Backend
	b := lmdb_backend_init(&m, "conf-nomatch")
	defer lmdb_backend_destroy(&m)
	conformance.check_no_match_and_exhaustion(t, &b)
}

@(test)
test_lmdb_default_vs_named_graphs :: proc(t: ^testing.T) {
	m: Lmdb_Backend
	b := lmdb_backend_init(&m, "conf-graphs")
	defer lmdb_backend_destroy(&m)
	conformance.check_default_vs_named_graphs(t, &b)
}

// White-box checks beyond the shared suite: exact index-key bytes and
// prefix-boundary behavior at the end of a bound range.

@(test)
test_lmdb_index_key_bytes :: proc(t: ^testing.T) {
	m: Lmdb_Backend
	b := lmdb_backend_init(&m, "idx-bytes")
	defer lmdb_backend_destroy(&m)
	_ = b

	q := store.Encoded_Quad {
		store.make_id(.IRI, 1),
		store.make_id(.IRI, 2),
		store.make_id(.Literal, 3),
		store.DEFAULT_GRAPH,
	}
	added, err := insert(m.s, q)
	testing.expect(t, err == nil)
	testing.expect_value(t, added, true)

	// gspo key = g, s, p, o — each big-endian.
	expected: [QUAD_KEY_SIZE]u8
	put_id_be(expected[0 * ID_SIZE:][:ID_SIZE], store.DEFAULT_GRAPH)
	put_id_be(expected[1 * ID_SIZE:][:ID_SIZE], q[store.QUAD_S])
	put_id_be(expected[2 * ID_SIZE:][:ID_SIZE], q[store.QUAD_P])
	put_id_be(expected[3 * ID_SIZE:][:ID_SIZE], q[store.QUAD_O])

	it, merr := match(m.s, store.MATCH_ALL)
	testing.expect(t, merr == nil)
	defer match_destroy(&it)
	got, ok := match_next(&it)
	testing.expect_value(t, ok, true)
	testing.expect_value(t, got, q)

	// And the raw key round-trips through the codec.
	key_buf: [QUAD_KEY_SIZE]u8
	encode_quad_key(key_buf[:], q, PERM_GSPO)
	testing.expect_value(t, key_buf, expected)
	testing.expect_value(t, decode_quad_key(key_buf[:], PERM_GSPO), q)
}

@(test)
test_lmdb_prefix_boundary :: proc(t: ^testing.T) {
	// The last key of a bound range: quads in adjacent graphs must not
	// bleed into each other's range scans, including for the highest
	// graph present.
	m: Lmdb_Backend
	b := lmdb_backend_init(&m, "idx-boundary")
	defer lmdb_backend_destroy(&m)
	_ = b

	s0 := store.make_id(.IRI, 0)
	p := store.make_id(.IRI, 1)
	o := store.make_id(.Literal, 0)
	g_low := store.make_id(.IRI, 2)
	g_high := store.make_id(.Blank_Node, 0) // higher kind tag: sorts after every IRI graph

	in_low := store.Encoded_Quad{s0, p, o, g_low}
	in_high := store.Encoded_Quad{s0, p, o, g_high}
	for q in ([?]store.Encoded_Quad{in_low, in_high}) {
		_, err := insert(m.s, q)
		testing.expect(t, err == nil)
	}

	scan :: proc(t: ^testing.T, s: ^Store, pattern: store.Match_Pattern) -> [dynamic]store.Encoded_Quad {
		result := make([dynamic]store.Encoded_Quad)
		it, err := match(s, pattern)
		testing.expect(t, err == nil)
		defer match_destroy(&it)
		for q in match_next(&it) {
			append(&result, q)
		}
		return result
	}

	low_only := scan(t, m.s, store.Match_Pattern{store.WILDCARD, store.WILDCARD, store.WILDCARD, g_low})
	defer delete(low_only)
	testing.expect_value(t, len(low_only), 1)
	testing.expect_value(t, low_only[0], in_low)

	// The range at the very end of the index terminates cleanly.
	high_only := scan(t, m.s, store.Match_Pattern{store.WILDCARD, store.WILDCARD, store.WILDCARD, g_high})
	defer delete(high_only)
	testing.expect_value(t, len(high_only), 1)
	testing.expect_value(t, high_only[0], in_high)

	// A bound graph with no quads at all yields nothing (range is
	// empty but positioned mid-index).
	g_absent := store.make_id(.IRI, 3)
	none := scan(t, m.s, store.Match_Pattern{store.WILDCARD, store.WILDCARD, store.WILDCARD, g_absent})
	defer delete(none)
	testing.expect_value(t, len(none), 0)
}
