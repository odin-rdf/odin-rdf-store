package store

// Conformance suite for the match interface contract (STORE-A-0002).
// The tests exercise the contract only — init/destroy, insert, count,
// match/match_next/match_destroy — never the backing structures, so a
// new backend implementing the procedure set runs this suite verbatim.
// Expected results come from a brute-force filter over the fixture's
// quad list, independent of the dataset implementation under test.

import "core:testing"
import rdf "../../odin-rdf-parser/rdf"

// fixture_quads returns a dataset spanning the contract's edge cases:
// default + IRI-named + blank-named graphs, one triple repeated in two
// graphs, blank-node subjects, language-tagged and typed literals, and
// an RDF-star triple term in object position.
@(private = "file")
fixture_quads :: proc(d: ^Dictionary) -> [dynamic]Encoded_Quad {
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

	encoded := make([dynamic]Encoded_Quad, 0, len(quads))
	for q in quads {
		append(&encoded, encode_quad(d, q))
	}
	return encoded
}

@(private = "file")
collect_matches :: proc(
	t: ^testing.T,
	ds: ^Dataset,
	pattern: Match_Pattern,
) -> map[Encoded_Quad]struct {} {
	results := make(map[Encoded_Quad]struct {})
	it := match(ds, pattern)
	defer match_destroy(&it)
	for q in match_next(&it) {
		_, seen := results[q]
		testing.expect(t, !seen, "iterator yielded a quad twice")
		results[q] = {}
	}
	return results
}

@(test)
test_conformance_all_16_patterns :: proc(t: ^testing.T) {
	d: Dictionary
	dictionary_init(&d)
	defer dictionary_destroy(&d)
	ds: Dataset
	dataset_init(&ds)
	defer dataset_destroy(&ds)

	quads := fixture_quads(&d)
	defer delete(quads)
	for q in quads {
		insert(&ds, q)
	}

	// Every combination of bound/wildcard positions (16 masks), each
	// probed with the positions of several distinct fixture quads —
	// covering default graph, IRI graph, and blank graph binds.
	probes := [?]Encoded_Quad{quads[0], quads[3], quads[5], quads[6]}
	for mask in 0 ..< 16 {
		for probe in probes {
			pattern := MATCH_ALL
			for pos in 0 ..< 4 {
				if mask&(1 << uint(pos)) != 0 {
					pattern[pos] = probe[pos]
				}
			}

			expected := make(map[Encoded_Quad]struct {})
			defer delete(expected)
			for q in quads {
				if pattern_matches(pattern, q) {
					expected[q] = {}
				}
			}

			got := collect_matches(t, &ds, pattern)
			defer delete(got)
			testing.expect_value(t, len(got), len(expected))
			for q in expected {
				_, ok := got[q]
				testing.expect(t, ok, "match result missing an expected quad")
			}
		}
	}
}

@(test)
test_conformance_set_semantics :: proc(t: ^testing.T) {
	d: Dictionary
	dictionary_init(&d)
	defer dictionary_destroy(&d)
	ds: Dataset
	dataset_init(&ds)
	defer dataset_destroy(&ds)

	quads := fixture_quads(&d)
	defer delete(quads)

	for q in quads {
		testing.expect_value(t, insert(&ds, q), true)
	}
	testing.expect_value(t, count(&ds), len(quads))

	// Re-inserting every quad is a no-op.
	for q in quads {
		testing.expect_value(t, insert(&ds, q), false)
	}
	testing.expect_value(t, count(&ds), len(quads))

	all := collect_matches(t, &ds, MATCH_ALL)
	defer delete(all)
	testing.expect_value(t, len(all), len(quads))
}

@(test)
test_conformance_empty_dataset :: proc(t: ^testing.T) {
	d: Dictionary
	dictionary_init(&d)
	defer dictionary_destroy(&d)
	ds: Dataset
	dataset_init(&ds)
	defer dataset_destroy(&ds)

	testing.expect_value(t, count(&ds), 0)

	s := intern_term(&d, rdf.IRI("http://example.org/s"))
	patterns := [?]Match_Pattern {
		MATCH_ALL,
		{s, WILDCARD, WILDCARD, WILDCARD},
		{WILDCARD, WILDCARD, WILDCARD, DEFAULT_GRAPH},
	}
	for pattern in patterns {
		got := collect_matches(t, &ds, pattern)
		defer delete(got)
		testing.expect_value(t, len(got), 0)
	}
}

@(test)
test_conformance_no_match_and_exhaustion :: proc(t: ^testing.T) {
	d: Dictionary
	dictionary_init(&d)
	defer dictionary_destroy(&d)
	ds: Dataset
	dataset_init(&ds)
	defer dataset_destroy(&ds)

	quads := fixture_quads(&d)
	defer delete(quads)
	for q in quads {
		insert(&ds, q)
	}

	// carol appears as an object but never as a subject: interned term,
	// zero matches.
	carol := intern_term(&d, rdf.IRI("http://example.org/carol"))
	it := match(&ds, Match_Pattern{carol, WILDCARD, WILDCARD, WILDCARD})
	defer match_destroy(&it)
	_, ok := match_next(&it)
	testing.expect_value(t, ok, false)

	// Exhausted iterators stay exhausted.
	for _ in 0 ..< 3 {
		_, again := match_next(&it)
		testing.expect_value(t, again, false)
	}
}

@(test)
test_conformance_default_vs_named_graphs :: proc(t: ^testing.T) {
	d: Dictionary
	dictionary_init(&d)
	defer dictionary_destroy(&d)
	ds: Dataset
	dataset_init(&ds)
	defer dataset_destroy(&ds)

	quads := fixture_quads(&d)
	defer delete(quads)
	for q in quads {
		insert(&ds, q)
	}

	// DEFAULT_GRAPH selects exactly the default graph...
	default_only := collect_matches(t, &ds, Match_Pattern{WILDCARD, WILDCARD, WILDCARD, DEFAULT_GRAPH})
	defer delete(default_only)
	testing.expect_value(t, len(default_only), 2)
	for q in default_only {
		testing.expect_value(t, q[QUAD_G], DEFAULT_GRAPH)
	}

	// ...a bound named graph selects exactly that graph...
	g1 := intern_graph_label(&d, rdf.IRI("http://example.org/g1"))
	g1_only := collect_matches(t, &ds, Match_Pattern{WILDCARD, WILDCARD, WILDCARD, g1})
	defer delete(g1_only)
	testing.expect_value(t, len(g1_only), 3)

	// ...and a WILDCARD graph spans all of them.
	all := collect_matches(t, &ds, MATCH_ALL)
	defer delete(all)
	testing.expect_value(t, len(all), len(quads))

	// The same triple lives independently in default and named graph.
	alice := intern_term(&d, rdf.IRI("http://example.org/alice"))
	knows := intern_term(&d, rdf.IRI("http://example.org/knows"))
	bob := intern_term(&d, rdf.IRI("http://example.org/bob"))
	both := collect_matches(t, &ds, Match_Pattern{alice, knows, bob, WILDCARD})
	defer delete(both)
	testing.expect_value(t, len(both), 2)
}
