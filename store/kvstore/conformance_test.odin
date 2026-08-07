package kvstore

// The LMDB backend's instantiation of the shared conformance suite
// (the executable match interface contract) — same five checks the
// in-memory backend runs, over a database file. No harness
// modifications: a Backend adapter and thin @(test) wrappers only.

import "core:testing"

import "rdf:rdf"
import "../../conformance"
import store ".."

@(private = "file")
Lmdb_Backend :: struct {
	s: ^Store,
}

// The suite runs over an ephemeral store: this is the check that
// open_ephemeral is a constructor and not a change to the match
// contract (STORE-T-0033). Nothing below distinguishes the two
// constructors, which is the point.
@(private = "file")
lmdb_backend_init :: proc(m: ^Lmdb_Backend) -> conformance.Backend {
	m.s = scratch_store()
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
		find_term = proc(ctx: rawptr, term: rdf.Term) -> (store.Term_ID, bool) {
			id, found, err := find_term((^Lmdb_Backend)(ctx).s, term)
			assert(err == nil)
			return id, found
		},
		find_graph = proc(ctx: rawptr, g: rdf.Graph_Label) -> (store.Term_ID, bool) {
			id, found, err := find_graph_label((^Lmdb_Backend)(ctx).s, g)
			assert(err == nil)
			return id, found
		},
		dict_size = proc(ctx: rawptr) -> int {
			// The per-kind counters are the persisted dictionary size.
			total := 0
			for next in (^Lmdb_Backend)(ctx).s.next {
				total += int(next)
			}
			return total
		},

		// Transactions. The handle the suite holds is a heap Txn, freed
		// by whichever of commit/abort ends it — the same ownership the
		// iterator pointers already have.
		txn_begin = proc(ctx: rawptr, mode: store.Txn_Mode) -> (rawptr, bool) {
			tx, err := txn_begin((^Lmdb_Backend)(ctx).s, mode)
			if err != nil {
				// A refusal is a legitimate answer here, so the error is
				// reported rather than asserted away.
				return nil, false
			}
			handle := new(Txn)
			handle^ = tx
			return handle, true
		},
		txn_commit = proc(txn: rawptr) -> bool {
			handle := (^Txn)(txn)
			err := txn_commit(handle)
			free(handle)
			return err == nil
		},
		txn_abort = proc(txn: rawptr) {
			handle := (^Txn)(txn)
			txn_abort(handle)
			free(handle)
		},
		insert_txn = proc(txn: rawptr, q: store.Encoded_Quad) -> bool {
			added, err := insert_txn((^Txn)(txn), q)
			assert(err == nil)
			return added
		},
		count_txn = proc(txn: rawptr) -> int {
			n, err := count_txn((^Txn)(txn))
			assert(err == nil)
			return n
		},
		match_begin_txn = proc(txn: rawptr, pattern: store.Match_Pattern) -> rawptr {
			it := new(Match_Iterator)
			iter, err := match_txn((^Txn)(txn), pattern)
			assert(err == nil)
			it^ = iter
			return it
		},
		intern_term_txn = proc(txn: rawptr, term: rdf.Term) -> store.Term_ID {
			id, err := intern_term_txn((^Txn)(txn), term)
			assert(err == nil)
			return id
		},
		encode_quad_txn = proc(txn: rawptr, q: rdf.Quad) -> store.Encoded_Quad {
			encoded, err := encode_quad_txn((^Txn)(txn), q)
			assert(err == nil)
			return encoded
		},
		find_term_txn = proc(txn: rawptr, term: rdf.Term) -> (store.Term_ID, bool) {
			id, found, err := find_term_txn((^Txn)(txn), term)
			assert(err == nil)
			return id, found
		},
	}
}

@(private = "file")
lmdb_backend_destroy :: proc(m: ^Lmdb_Backend) {
	close(m.s)
}

@(test)
test_lmdb_all_16_patterns :: proc(t: ^testing.T) {
	m: Lmdb_Backend
	b := lmdb_backend_init(&m)
	defer lmdb_backend_destroy(&m)
	conformance.check_all_16_patterns(t, &b)
}

@(test)
test_lmdb_set_semantics :: proc(t: ^testing.T) {
	m: Lmdb_Backend
	b := lmdb_backend_init(&m)
	defer lmdb_backend_destroy(&m)
	conformance.check_set_semantics(t, &b)
}

@(test)
test_lmdb_empty_dataset :: proc(t: ^testing.T) {
	m: Lmdb_Backend
	b := lmdb_backend_init(&m)
	defer lmdb_backend_destroy(&m)
	conformance.check_empty_dataset(t, &b)
}

@(test)
test_lmdb_no_match_and_exhaustion :: proc(t: ^testing.T) {
	m: Lmdb_Backend
	b := lmdb_backend_init(&m)
	defer lmdb_backend_destroy(&m)
	conformance.check_no_match_and_exhaustion(t, &b)
}

@(test)
test_lmdb_default_vs_named_graphs :: proc(t: ^testing.T) {
	m: Lmdb_Backend
	b := lmdb_backend_init(&m)
	defer lmdb_backend_destroy(&m)
	conformance.check_default_vs_named_graphs(t, &b)
}

@(test)
test_lmdb_find_term :: proc(t: ^testing.T) {
	m: Lmdb_Backend
	b := lmdb_backend_init(&m)
	defer lmdb_backend_destroy(&m)
	conformance.check_find_term(t, &b)
}

// The transaction body (STORE-A-0007 point 5, STORE-T-0039). Same
// shape as the checks above: a fresh backend per check, no branch, no
// skip.

@(test)
test_lmdb_txn_read_your_own_writes :: proc(t: ^testing.T) {
	m: Lmdb_Backend
	b := lmdb_backend_init(&m)
	defer lmdb_backend_destroy(&m)
	conformance.check_txn_read_your_own_writes(t, &b)
}

@(test)
test_lmdb_txn_writes_invisible_until_commit :: proc(t: ^testing.T) {
	m: Lmdb_Backend
	b := lmdb_backend_init(&m)
	defer lmdb_backend_destroy(&m)
	conformance.check_txn_writes_invisible_until_commit(t, &b)
}

@(test)
test_lmdb_txn_snapshot_unchanged_across_commit :: proc(t: ^testing.T) {
	m: Lmdb_Backend
	b := lmdb_backend_init(&m)
	defer lmdb_backend_destroy(&m)
	conformance.check_txn_snapshot_unchanged_across_commit(t, &b)
}

@(test)
test_lmdb_txn_abort_leaves_nothing :: proc(t: ^testing.T) {
	m: Lmdb_Backend
	b := lmdb_backend_init(&m)
	defer lmdb_backend_destroy(&m)
	conformance.check_txn_abort_leaves_nothing(t, &b)
}

@(test)
test_lmdb_txn_single_writer :: proc(t: ^testing.T) {
	m: Lmdb_Backend
	b := lmdb_backend_init(&m)
	defer lmdb_backend_destroy(&m)
	conformance.check_txn_single_writer(t, &b)
}

@(test)
test_lmdb_txn_iterator_lifetime :: proc(t: ^testing.T) {
	m: Lmdb_Backend
	b := lmdb_backend_init(&m)
	defer lmdb_backend_destroy(&m)
	conformance.check_txn_iterator_lifetime(t, &b)
}

@(test)
test_lmdb_txn_autocommit :: proc(t: ^testing.T) {
	m: Lmdb_Backend
	b := lmdb_backend_init(&m)
	defer lmdb_backend_destroy(&m)
	conformance.check_txn_autocommit(t, &b)
}

@(test)
test_lmdb_validate_before_commit :: proc(t: ^testing.T) {
	m: Lmdb_Backend
	b := lmdb_backend_init(&m)
	defer lmdb_backend_destroy(&m)
	conformance.check_validate_before_commit(t, &b)
}

// White-box checks beyond the shared suite: exact index-key bytes and
// prefix-boundary behavior at the end of a bound range.

@(test)
test_lmdb_index_key_bytes :: proc(t: ^testing.T) {
	m: Lmdb_Backend
	b := lmdb_backend_init(&m)
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
	b := lmdb_backend_init(&m)
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
