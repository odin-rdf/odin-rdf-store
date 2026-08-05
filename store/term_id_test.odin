package store

import "core:testing"

@(test)
test_id_round_trip :: proc(t: ^testing.T) {
	kinds := [?]Term_Kind{.IRI, .Blank_Node, .Literal, .Triple}
	counters := [?]u64{0, 1, 42, MAX_COUNTER - 1, MAX_COUNTER}
	for kind in kinds {
		for counter in counters {
			id := make_id(kind, counter)
			testing.expect_value(t, id_kind(id), kind)
			testing.expect_value(t, id_counter(id), counter)
		}
	}
}

@(test)
test_width_constants :: proc(t: ^testing.T) {
	testing.expect_value(t, 8*size_of(Term_ID), TERM_ID_BITS)
	testing.expect_value(t, COUNTER_BITS, TERM_ID_BITS - TAG_BITS)
	testing.expect_value(t, MAX_COUNTER, (u64(1) << COUNTER_BITS) - 1)
}

@(test)
test_sentinels :: proc(t: ^testing.T) {
	testing.expect_value(t, id_kind(DEFAULT_GRAPH), Term_Kind.Sentinel)
	testing.expect_value(t, id_counter(DEFAULT_GRAPH), u64(0))
	testing.expect_value(t, id_kind(WILDCARD), Term_Kind.Sentinel)
	testing.expect_value(t, id_counter(WILDCARD), u64(1))
	testing.expect_value(t, id_kind(UNBOUND), Term_Kind.Sentinel)
	testing.expect_value(t, id_counter(UNBOUND), u64(2))

	// The three are mutually distinct, and none of them is ID 0 — the
	// reason UNBOUND has to be reserved here at all, since ID 0 is a
	// perfectly good term (the first IRI).
	sentinels := [?]Term_ID{DEFAULT_GRAPH, WILDCARD, UNBOUND}
	for a, i in sentinels {
		testing.expect(t, a != Term_ID(0))
		for b in sentinels[i + 1:] {
			testing.expect(t, a != b)
		}
	}

	// Sentinels collide with no assignable ID of any real kind.
	for kind in ([?]Term_Kind{.IRI, .Blank_Node, .Literal, .Triple}) {
		for sentinel in sentinels {
			testing.expect(t, id_kind(sentinel) != kind)
		}
	}
}

@(test)
test_kind_clustering :: proc(t: ^testing.T) {
	// The tag lives in the high bits, so IDs cluster by kind: the
	// largest IRI ID sorts below the smallest blank-node ID, and so on
	// up the kind ordering.
	testing.expect(t, make_id(.IRI, MAX_COUNTER) < make_id(.Blank_Node, 0))
	testing.expect(t, make_id(.Blank_Node, MAX_COUNTER) < make_id(.Literal, 0))
	testing.expect(t, make_id(.Literal, MAX_COUNTER) < make_id(.Triple, 0))
	testing.expect(t, make_id(.Triple, MAX_COUNTER) < DEFAULT_GRAPH)

	// Within a kind, IDs order by counter (first-seen insertion order).
	testing.expect(t, make_id(.Literal, 0) < make_id(.Literal, 1))
	testing.expect(t, make_id(.Literal, 1) < make_id(.Literal, MAX_COUNTER))
}

@(test)
test_encoded_quad_compare :: proc(t: ^testing.T) {
	s0 := make_id(.IRI, 0)
	s1 := make_id(.IRI, 1)
	p := make_id(.IRI, 2)
	o := make_id(.Literal, 0)
	g := make_id(.IRI, 3)

	a := Encoded_Quad{s0, p, o, DEFAULT_GRAPH}
	testing.expect_value(t, encoded_quad_compare(a, a), 0)

	// Subject dominates.
	b := Encoded_Quad{s1, p, o, DEFAULT_GRAPH}
	testing.expect_value(t, encoded_quad_compare(a, b), -1)
	testing.expect_value(t, encoded_quad_compare(b, a), +1)

	// Graph is least significant: equal s/p/o falls through to g, and
	// the Sentinel-tagged DEFAULT_GRAPH sorts above any IRI-tagged g.
	c := Encoded_Quad{s0, p, o, g}
	testing.expect_value(t, encoded_quad_compare(a, c), +1)
	testing.expect_value(t, encoded_quad_compare(c, a), -1)

	// Object decides before graph is consulted: c has the smaller
	// object, so c < d even though c's graph sorts above d's.
	d := Encoded_Quad{s0, p, make_id(.Literal, 1), DEFAULT_GRAPH}
	testing.expect_value(t, encoded_quad_compare(c, d), -1)
}
