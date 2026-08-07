// Package conformance is the executable form of the match interface
// contract (STORE-A-0002): a backend-agnostic suite covering all 16
// bound/wildcard match patterns, set semantics, and the dataset/graph
// edge cases. Passing it verbatim is the definition of implementing
// the interface.
//
// A backend adopts the suite by filling a Backend adapter — procedure
// pointers over an opaque context — and declaring one thin @(test)
// wrapper per check_* procedure, each on a fresh backend instance (see
// store/kvstore/conformance_test.odin for the only instantiation there
// is). The indirection is confined to test code; the public backend
// APIs stay convention-based per STORE-A-0002.
//
// With one backend the suite is a regression suite rather than the
// portability proof it was while memstore existed (STORE-A-0006). The
// adapter is retained unchanged for exactly that reason: it is what a
// second backend would fill.
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
	find_term:     proc(ctx: rawptr, term: rdf.Term) -> (store.Term_ID, bool),
	find_graph:    proc(ctx: rawptr, g: rdf.Graph_Label) -> (store.Term_ID, bool),
	// dict_size reports how many terms the dictionary has assigned IDs
	// to, across all kinds — the observable check_find_term watches to
	// prove a failed find assigned nothing.
	dict_size:     proc(ctx: rawptr) -> int,

	// Transactions (STORE-A-0007), asserted by transactions.odin.
	//
	// The handle is opaque exactly as match_begin's iterator is: the
	// suite never names a backend's transaction type, and the adapter
	// owns whatever it hands back until commit or abort ends it.
	//
	// **This is the whole of the growth: procedure pointers and nothing
	// else.** No capability field, no tier, no skip list. A backend
	// either passes the transaction checks or does not implement the
	// interface — which is what STORE-A-0002 point 3 always claimed the
	// suite was, and what it would stop being the moment the contract
	// carried something the suite had to branch on.
	//
	// txn_begin reports ok=false when the backend refuses, which the
	// single-writer check needs and which deliberately says nothing
	// about *why*: an error taxonomy is a backend's own business.
	txn_begin:       proc(ctx: rawptr, mode: store.Txn_Mode) -> (txn: rawptr, ok: bool),
	txn_commit:      proc(txn: rawptr) -> bool,
	txn_abort:       proc(txn: rawptr),
	insert_txn:      proc(txn: rawptr, q: store.Encoded_Quad) -> bool,
	count_txn:       proc(txn: rawptr) -> int,
	// Yields the same opaque iterator match_next and match_destroy take.
	match_begin_txn: proc(txn: rawptr, pattern: store.Match_Pattern) -> rawptr,
	intern_term_txn: proc(txn: rawptr, term: rdf.Term) -> store.Term_ID,
	encode_quad_txn: proc(txn: rawptr, q: rdf.Quad) -> store.Encoded_Quad,
	find_term_txn:   proc(txn: rawptr, term: rdf.Term) -> (store.Term_ID, bool),
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

// check_find_term verifies the non-interning term lookup: terms the
// dictionary knows resolve to the IDs interning gave them, terms it
// does not know report not-found, and a not-found answer assigns
// nothing. The last part is the point of the procedure — the query path
// resolves ground terms against the store and must not grow it.
check_find_term :: proc(t: ^testing.T, b: ^Backend) {
	quads := fixture_quads(b)
	defer delete(quads)

	statement := rdf.Triple {
		subject   = rdf.IRI("http://example.org/alice"),
		predicate = rdf.IRI("http://example.org/knows"),
		object    = rdf.IRI("http://example.org/bob"),
	}
	present := [?]rdf.Term {
		rdf.IRI("http://example.org/alice"),
		rdf.Blank_Node("b0"),
		rdf.literal("chat", "fr"),
		rdf.literal_typed("42", rdf.IRI("http://www.w3.org/2001/XMLSchema#integer")),
		&statement, // an RDF-star triple term, matched by its components
	}
	for term in present {
		id, found := b.find_term(b.ctx, term)
		testing.expect(t, found, "find_term missed an interned term")
		testing.expect_value(t, id, b.intern_term(b.ctx, term))
	}

	// Components all known, combination not: a triple term is present
	// only as itself.
	unknown_combination := rdf.Triple {
		subject   = rdf.IRI("http://example.org/bob"),
		predicate = rdf.IRI("http://example.org/knows"),
		object    = rdf.IRI("http://example.org/alice"),
	}
	unknown_component := rdf.Triple {
		subject   = rdf.IRI("http://example.org/alice"),
		predicate = rdf.IRI("http://example.org/knows"),
		object    = rdf.IRI("http://example.org/nobody"),
	}
	absent := [?]rdf.Term {
		rdf.IRI("http://example.org/nobody"),
		rdf.Blank_Node("b-absent"),
		rdf.literal("chat", "de"), // known lexical form, unknown language tag
		rdf.literal_typed("42", rdf.IRI("http://example.org/unknown-datatype")),
		&unknown_combination,
		&unknown_component,
	}

	size := b.dict_size(b.ctx)
	// Twice: the second pass would find what the first had assigned.
	for _ in 0 ..< 2 {
		for term in absent {
			_, found := b.find_term(b.ctx, term)
			testing.expect(t, !found, "find_term claimed a term the dictionary never saw")
		}
	}
	testing.expect_value(t, b.dict_size(b.ctx), size)

	// The graph-position counterpart, mirroring intern_graph_label: a
	// nil label is always found as DEFAULT_GRAPH.
	dg, dg_found := b.find_graph(b.ctx, nil)
	testing.expect(t, dg_found, "the default graph is always present")
	testing.expect_value(t, dg, store.DEFAULT_GRAPH)

	labels := [?]rdf.Graph_Label{rdf.IRI("http://example.org/g1"), rdf.Blank_Node("gb")}
	for label in labels {
		id, found := b.find_graph(b.ctx, label)
		testing.expect(t, found, "find_graph_label missed an interned label")
		testing.expect_value(t, id, b.intern_graph(b.ctx, label))
	}

	_, unknown_graph := b.find_graph(b.ctx, rdf.IRI("http://example.org/g-absent"))
	testing.expect(t, !unknown_graph, "find_graph_label claimed an absent label")
	testing.expect_value(t, b.dict_size(b.ctx), size)
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
