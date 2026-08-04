package store

import "core:testing"
import rdf "../../odin-rdf-parser/rdf"

@(private = "file")
EX :: "http://example.org/"

@(test)
test_load_triples_with_rdf_star :: proc(t: ^testing.T) {
	d: Dictionary
	dictionary_init(&d)
	defer dictionary_destroy(&d)
	ds: Dataset
	dataset_init(&ds)
	defer dataset_destroy(&ds)

	src := `
		<http://example.org/alice> <http://example.org/knows> <http://example.org/bob> .
		_:b0 <http://example.org/says> "hello" .
		_:b0 <http://example.org/knows> _:b1 .
		<http://example.org/r> <http://example.org/reifies> <<( <http://example.org/s> <http://example.org/p> "o" )>> .
	`

	added, err := load_triples(&d, &ds, transmute([]u8)src)
	testing.expect_value(t, err.message, "")
	testing.expect_value(t, added, 4)
	testing.expect_value(t, count(&ds), 4)

	// _:b0 in two statements is one term: both quads share a subject.
	says := intern_term(&d, rdf.IRI(EX + "says"))
	knows := intern_term(&d, rdf.IRI(EX + "knows"))
	it := match(&ds, Match_Pattern{WILDCARD, says, WILDCARD, WILDCARD})
	q1, ok1 := match_next(&it)
	testing.expect_value(t, ok1, true)
	match_destroy(&it)
	blank_subject := q1[QUAD_S]
	testing.expect_value(t, id_kind(blank_subject), Term_Kind.Blank_Node)

	it2 := match(&ds, Match_Pattern{blank_subject, knows, WILDCARD, WILDCARD})
	q2, ok2 := match_next(&it2)
	testing.expect_value(t, ok2, true)
	testing.expect_value(t, id_kind(q2[QUAD_O]), Term_Kind.Blank_Node)
	testing.expect(t, q2[QUAD_O] != blank_subject) // _:b1 is its own term
	match_destroy(&it2)

	// The triple term decoded from storage equals the parsed structure.
	reifies := intern_term(&d, rdf.IRI(EX + "reifies"))
	it3 := match(&ds, Match_Pattern{WILDCARD, reifies, WILDCARD, WILDCARD})
	q3, ok3 := match_next(&it3)
	testing.expect_value(t, ok3, true)
	match_destroy(&it3)
	expected := rdf.Triple {
		subject   = rdf.IRI(EX + "s"),
		predicate = rdf.IRI(EX + "p"),
		object    = rdf.literal("o"),
	}
	testing.expect(t, rdf.equal(lookup_term(&d, q3[QUAD_O]), rdf.Term(&expected)))
}

@(test)
test_load_turtle_prefixes_and_anon :: proc(t: ^testing.T) {
	d: Dictionary
	dictionary_init(&d)
	defer dictionary_destroy(&d)
	ds: Dataset
	dataset_init(&ds)
	defer dataset_destroy(&ds)

	src := `
		@prefix ex: <http://example.org/> .
		ex:alice ex:knows ex:bob ,
						  ex:carol ;
	         			  ex:age 42 .
	    [ ex:label "anon" ] ex:knows ex:alice .
	`

	added, err := load_turtle(&d, &ds, transmute([]u8)src)
	testing.expect_value(t, err.message, "")
	testing.expect_value(t, added, 5)

	// Prefixed names expanded: ex:alice matches as a full IRI.
	alice := intern_term(&d, rdf.IRI(EX + "alice"))
	knows := intern_term(&d, rdf.IRI(EX + "knows"))
	from_alice := match(&ds, Match_Pattern{alice, knows, WILDCARD, WILDCARD})
	defer match_destroy(&from_alice)
	n := 0
	for _ in match_next(&from_alice) {
		n += 1
	}
	testing.expect_value(t, n, 2)

	// The numeric shorthand parsed as an xsd:integer literal.
	age := intern_term(&d, rdf.IRI(EX + "age"))
	it := match(&ds, Match_Pattern{alice, age, WILDCARD, WILDCARD})
	defer match_destroy(&it)
	q, ok := match_next(&it)
	testing.expect_value(t, ok, true)
	forty_two := rdf.literal_typed("42", rdf.IRI("http://www.w3.org/2001/XMLSchema#integer"))
	testing.expect(t, rdf.equal(lookup_term(&d, q[QUAD_O]), rdf.Term(forty_two)))
}

@(test)
test_load_quads_and_trig_graphs :: proc(t: ^testing.T) {
	d: Dictionary
	dictionary_init(&d)
	defer dictionary_destroy(&d)
	ds: Dataset
	dataset_init(&ds)
	defer dataset_destroy(&ds)

	nq := `
		<http://example.org/s> <http://example.org/p> "chat"@fr <http://example.org/g1> .
		_:b0 <http://example.org/p> "x" _:g .
		<http://example.org/s> <http://example.org/p> "plain" .
	`
	added, err := load_quads(&d, &ds, transmute([]u8)nq)
	testing.expect_value(t, err.message, "")
	testing.expect_value(t, added, 3)

	trig := `
		@prefix ex: <http://example.org/> .
		ex:g1 { ex:s ex:p ex:o1 . }
		{ ex:s ex:p "in default" . }
		GRAPH _:g2 { _:b ex:p ex:o2 . }
	`
	added2, err2 := load_trig(&d, &ds, transmute([]u8)trig)
	testing.expect_value(t, err2.message, "")
	testing.expect_value(t, added2, 3)

	// Default graph holds one quad from each load.
	in_default := match(&ds, Match_Pattern{WILDCARD, WILDCARD, WILDCARD, DEFAULT_GRAPH})
	defer match_destroy(&in_default)
	n := 0
	for _ in match_next(&in_default) {
		n += 1
	}
	testing.expect_value(t, n, 2)

	// The named graph ex:g1 holds one quad from each load.
	g1 := intern_graph_label(&d, rdf.IRI(EX + "g1"))
	in_g1 := match(&ds, Match_Pattern{WILDCARD, WILDCARD, WILDCARD, g1})
	defer match_destroy(&in_g1)
	n = 0
	for _ in match_next(&in_g1) {
		n += 1
	}
	testing.expect_value(t, n, 2)

	// Blank graph labels were scoped per load: two distinct blank
	// graphs exist, and the language tag survived the round trip.
	blanks := 0
	all := match(&ds, MATCH_ALL)
	defer match_destroy(&all)
	for q in match_next(&all) {
		if q[QUAD_G] != DEFAULT_GRAPH && id_kind(q[QUAD_G]) == .Blank_Node {
			blanks += 1
		}
	}
	testing.expect_value(t, blanks, 2)

	p := intern_term(&d, rdf.IRI(EX + "p"))
	chat := intern_term(&d, rdf.literal("chat", "fr"))
	tagged := match(&ds, Match_Pattern{WILDCARD, p, chat, WILDCARD})
	defer match_destroy(&tagged)
	_, ok := match_next(&tagged)
	testing.expect_value(t, ok, true)
}

@(test)
test_blank_scoping_across_loads :: proc(t: ^testing.T) {
	d: Dictionary
	dictionary_init(&d)
	defer dictionary_destroy(&d)
	ds: Dataset
	dataset_init(&ds)
	defer dataset_destroy(&ds)

	with_blanks := `_:b0 <http://example.org/p> "x" .`
	without := `<http://example.org/s> <http://example.org/p> "x" .`

	a1, _ := load_triples(&d, &ds, transmute([]u8)with_blanks)
	a2, _ := load_triples(&d, &ds, transmute([]u8)with_blanks)
	testing.expect_value(t, a1, 1)
	// Same label, different load: a distinct blank node, so a distinct
	// quad.
	testing.expect_value(t, a2, 1)
	testing.expect_value(t, count(&ds), 2)

	b1, _ := load_triples(&d, &ds, transmute([]u8)without)
	b2, _ := load_triples(&d, &ds, transmute([]u8)without)
	testing.expect_value(t, b1, 1)
	// No blanks: the second load is an exact duplicate and adds
	// nothing.
	testing.expect_value(t, b2, 0)
	testing.expect_value(t, count(&ds), 3)
}

@(test)
test_load_survives_source_buffer_reuse :: proc(t: ^testing.T) {
	// The RDF-A-0001 proof: load from a buffer (escaped tokens force
	// copy-on-write paths, unescaped ones are borrowed slices),
	// overwrite the buffer, and verify the stored data is intact. A
	// retained borrow would surface here as corrupted term content.
	d: Dictionary
	dictionary_init(&d)
	defer dictionary_destroy(&d)
	ds: Dataset
	dataset_init(&ds)
	defer dataset_destroy(&ds)

	src := `
		<http://example.org/café> <http://example.org/note> "h\"i\né" .
		<http://example.org/plain> <http://example.org/note> "borrowed" .
	`
	buffer := make([]u8, len(src))
	defer delete(buffer)
	copy(buffer, src)

	added, err := load_triples(&d, &ds, buffer)
	testing.expect_value(t, err.message, "")
	testing.expect_value(t, added, 2)

	for &b in buffer {
		b = 'Z'
	}

	expected := [?]rdf.Quad {
		{
			triple = rdf.Triple {
				subject   = rdf.IRI(EX + "café"),
				predicate = rdf.IRI(EX + "note"),
				object    = rdf.literal("h\"i\né"),
			},
		},
		{
			triple = rdf.Triple {
				subject   = rdf.IRI(EX + "plain"),
				predicate = rdf.IRI(EX + "note"),
				object    = rdf.literal("borrowed"),
			},
		},
	}
	all := match(&ds, MATCH_ALL)
	defer match_destroy(&all)
	found := 0
	for q in match_next(&all) {
		decoded := decode_quad(&d, q)
		for exp in expected {
			if rdf.equal(decoded, exp) {
				found += 1
			}
		}
	}
	testing.expect_value(t, found, 2)
}

@(test)
test_load_error_reports_position :: proc(t: ^testing.T) {
	d: Dictionary
	dictionary_init(&d)
	defer dictionary_destroy(&d)
	ds: Dataset
	dataset_init(&ds)
	defer dataset_destroy(&ds)

	src := `<http://example.org/a> <http://example.org/p> "ok" .
<http://example.org/a> <http://example.org/p> "missing dot"`
	added, err := load_triples(&d, &ds, transmute([]u8)src)

	testing.expect(t, err.message != "")
	testing.expect_value(t, err.line, 2)
	testing.expect(t, err.column >= 1)
	// The statement before the error was inserted and remains
	// (append-only: no rollback), and the count reports it.
	testing.expect_value(t, added, 1)
	testing.expect_value(t, count(&ds), 1)
}
