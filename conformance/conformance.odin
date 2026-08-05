// Package conformance is the executable form of the match interface
// contract (STORE-A-0002): a backend-agnostic suite covering all 16
// bound/wildcard match patterns, set semantics, and the dataset/graph
// edge cases. Passing it verbatim is the definition of implementing
// the interface.
//
// A backend adopts the suite by filling a Backend adapter — procedure
// pointers over an opaque context — and declaring one thin @(test)
// wrapper per check_* procedure, each on a fresh backend instance
// (see inmem_test.odin for the in-memory instantiation). The
// indirection is confined to test code; the public backend APIs stay
// convention-based per STORE-A-0002.
package conformance

import "core:testing"

import "rdf:rdf"
import "../store"

// Backend adapts one dataset implementation (plus the dictionary it
// encodes through) to the suite. Every procedure receives the adapter's
// opaque ctx; match_begin returns an opaque iterator handle owned by
// the backend until match_destroy.
Backend :: struct {
	ctx:           rawptr,
	insert:        proc(ctx: rawptr, q: store.Encoded_Quad) -> bool,
	count:         proc(ctx: rawptr) -> int,
	match_begin:   proc(ctx: rawptr, pattern: store.Match_Pattern) -> rawptr,
	match_next:    proc(it: rawptr) -> (store.Encoded_Quad, bool),
	match_destroy: proc(it: rawptr),
	intern_term:   proc(ctx: rawptr, term: rdf.Term) -> store.Term_ID,
	encode_quad:   proc(ctx: rawptr, q: rdf.Quad) -> store.Encoded_Quad,
	intern_graph:  proc(ctx: rawptr, g: rdf.Graph_Label) -> store.Term_ID,
}

// fixture_quads encodes a dataset spanning the contract's edge cases:
// default + IRI-named + blank-named graphs, one triple repeated in two
// graphs, blank-node subjects, language-tagged and typed literals, and
// an RDF-star triple term in object position.
fixture_quads :: proc(b: ^Backend) -> [dynamic]store.Encoded_Quad {
	alice := rdf.IRI("http://example.org/alice")
	bob := rdf.IRI("http://example.org/bob")
	carol := rdf.IRI("http://example.org/carol")
	knows := rdf.IRI("http://example.org/knows")
	age := rdf.IRI("http://example.org/age")
	says := rdf.IRI("http://example.org/says")
	source := rdf.IRI("http://example.org/source")
	g1 := rdf.IRI("http://example.org/g1")
	gb := rdf.Blank_Node("gb")

	statement := rdf.Triple{subject = alice, predicate = knows, object = bob}

	quads := [?]rdf.Quad {
		{triple = {alice, knows, bob}, graph = nil},
		{triple = {alice, knows, carol}, graph = nil},
		{triple = {alice, knows, bob}, graph = g1}, // same triple, named graph
		{triple = {bob, knows, carol}, graph = g1},
		{triple = {alice, age, rdf.literal_typed("42", rdf.IRI("http://www.w3.org/2001/XMLSchema#integer"))}, graph = g1},
		{triple = {rdf.Blank_Node("b0"), says, rdf.literal("chat", "fr")}, graph = gb},
		{triple = {bob, source, &statement}, graph = gb},
	}

	encoded := make([dynamic]store.Encoded_Quad, 0, len(quads))
	for q in quads {
		append(&encoded, b.encode_quad(b.ctx, q))
	}
	return encoded
}

@(private)
collect_matches :: proc(
	t: ^testing.T,
	b: ^Backend,
	pattern: store.Match_Pattern,
) -> map[store.Encoded_Quad]struct {} {
	results := make(map[store.Encoded_Quad]struct {})
	it := b.match_begin(b.ctx, pattern)
	defer b.match_destroy(it)
	for {
		q, ok := b.match_next(it)
		if !ok {
			break
		}
		_, seen := results[q]
		testing.expect(t, !seen, "iterator yielded a quad twice")
		results[q] = {}
	}
	return results
}

// check_all_16_patterns exercises every combination of bound/wildcard
// positions, each probed with the positions of several distinct
// fixture quads, against a brute-force oracle over the fixture list.
check_all_16_patterns :: proc(t: ^testing.T, b: ^Backend) {
	quads := fixture_quads(b)
	defer delete(quads)
	for q in quads {
		b.insert(b.ctx, q)
	}

	probes := [?]store.Encoded_Quad{quads[0], quads[3], quads[5], quads[6]}
	for mask in 0 ..< 16 {
		for probe in probes {
			pattern := store.MATCH_ALL
			for pos in 0 ..< 4 {
				if mask&(1 << uint(pos)) != 0 {
					pattern[pos] = probe[pos]
				}
			}

			expected := make(map[store.Encoded_Quad]struct {})
			defer delete(expected)
			for q in quads {
				if store.pattern_matches(pattern, q) {
					expected[q] = {}
				}
			}

			got := collect_matches(t, b, pattern)
			defer delete(got)
			testing.expect_value(t, len(got), len(expected))
			for q in expected {
				_, ok := got[q]
				testing.expect(t, ok, "match result missing an expected quad")
			}
		}
	}
}

// check_set_semantics verifies duplicate inserts are no-ops and count
// tracks the quad set.
check_set_semantics :: proc(t: ^testing.T, b: ^Backend) {
	quads := fixture_quads(b)
	defer delete(quads)

	for q in quads {
		testing.expect_value(t, b.insert(b.ctx, q), true)
	}
	testing.expect_value(t, b.count(b.ctx), len(quads))

	for q in quads {
		testing.expect_value(t, b.insert(b.ctx, q), false)
	}
	testing.expect_value(t, b.count(b.ctx), len(quads))

	all := collect_matches(t, b, store.MATCH_ALL)
	defer delete(all)
	testing.expect_value(t, len(all), len(quads))
}

// check_empty_dataset verifies zero counts and empty matches before
// anything is inserted.
check_empty_dataset :: proc(t: ^testing.T, b: ^Backend) {
	testing.expect_value(t, b.count(b.ctx), 0)

	s := b.intern_term(b.ctx, rdf.IRI("http://example.org/s"))
	patterns := [?]store.Match_Pattern {
		store.MATCH_ALL,
		{s, store.WILDCARD, store.WILDCARD, store.WILDCARD},
		{store.WILDCARD, store.WILDCARD, store.WILDCARD, store.DEFAULT_GRAPH},
	}
	for pattern in patterns {
		got := collect_matches(t, b, pattern)
		defer delete(got)
		testing.expect_value(t, len(got), 0)
	}
}

// check_no_match_and_exhaustion verifies interned-but-absent patterns
// yield nothing and that exhausted iterators stay exhausted.
check_no_match_and_exhaustion :: proc(t: ^testing.T, b: ^Backend) {
	quads := fixture_quads(b)
	defer delete(quads)
	for q in quads {
		b.insert(b.ctx, q)
	}

	// carol appears as an object but never as a subject.
	carol := b.intern_term(b.ctx, rdf.IRI("http://example.org/carol"))
	it := b.match_begin(b.ctx, store.Match_Pattern{carol, store.WILDCARD, store.WILDCARD, store.WILDCARD})
	defer b.match_destroy(it)
	_, ok := b.match_next(it)
	testing.expect_value(t, ok, false)

	for _ in 0 ..< 3 {
		_, again := b.match_next(it)
		testing.expect_value(t, again, false)
	}
}

// check_default_vs_named_graphs verifies the three graph addressing
// modes: DEFAULT_GRAPH exactly, a bound named graph exactly, and
// WILDCARD spanning all graphs — plus the same triple living
// independently in two graphs.
check_default_vs_named_graphs :: proc(t: ^testing.T, b: ^Backend) {
	quads := fixture_quads(b)
	defer delete(quads)
	for q in quads {
		b.insert(b.ctx, q)
	}

	default_only := collect_matches(t, b, store.Match_Pattern{store.WILDCARD, store.WILDCARD, store.WILDCARD, store.DEFAULT_GRAPH})
	defer delete(default_only)
	testing.expect_value(t, len(default_only), 2)
	for q in default_only {
		testing.expect_value(t, q[store.QUAD_G], store.DEFAULT_GRAPH)
	}

	g1 := b.intern_graph(b.ctx, rdf.IRI("http://example.org/g1"))
	g1_only := collect_matches(t, b, store.Match_Pattern{store.WILDCARD, store.WILDCARD, store.WILDCARD, g1})
	defer delete(g1_only)
	testing.expect_value(t, len(g1_only), 3)

	all := collect_matches(t, b, store.MATCH_ALL)
	defer delete(all)
	testing.expect_value(t, len(all), len(quads))

	alice := b.intern_term(b.ctx, rdf.IRI("http://example.org/alice"))
	knows := b.intern_term(b.ctx, rdf.IRI("http://example.org/knows"))
	bob := b.intern_term(b.ctx, rdf.IRI("http://example.org/bob"))
	both := collect_matches(t, b, store.Match_Pattern{alice, knows, bob, store.WILDCARD})
	defer delete(both)
	testing.expect_value(t, len(both), 2)
}
