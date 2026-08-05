package memstore

import store ".."

import "core:strings"
import "core:testing"
import "rdf:rdf"

@(test)
test_intern_twice_same_id :: proc(t: ^testing.T) {
	d: Dictionary
	dictionary_init(&d)
	defer dictionary_destroy(&d)

	iri := intern_term(&d, rdf.IRI("http://example.org/a"))
	testing.expect_value(t, store.id_kind(iri), store.Term_Kind.IRI)
	testing.expect_value(t, intern_term(&d, rdf.IRI("http://example.org/a")), iri)

	blank := intern_term(&d, rdf.Blank_Node("b0"))
	testing.expect_value(t, store.id_kind(blank), store.Term_Kind.Blank_Node)
	testing.expect_value(t, intern_term(&d, rdf.Blank_Node("b0")), blank)

	lit := intern_term(&d, rdf.literal("hello"))
	testing.expect_value(t, store.id_kind(lit), store.Term_Kind.Literal)
	testing.expect_value(t, intern_term(&d, rdf.literal("hello")), lit)

	tr := rdf.Triple {
		subject   = rdf.Blank_Node("b0"),
		predicate = rdf.RDF_TYPE,
		object    = rdf.literal("hello"),
	}
	triple_id := intern_term(&d, &tr)
	testing.expect_value(t, store.id_kind(triple_id), store.Term_Kind.Triple)
	tr2 := tr // same structure, distinct pointer
	testing.expect_value(t, intern_term(&d, &tr2), triple_id)
}

@(test)
test_dense_counters_per_kind :: proc(t: ^testing.T) {
	d: Dictionary
	dictionary_init(&d)
	defer dictionary_destroy(&d)

	a := intern_term(&d, rdf.IRI("http://example.org/a"))
	b := intern_term(&d, rdf.IRI("http://example.org/b"))
	l := intern_term(&d, rdf.literal("x"))
	c := intern_term(&d, rdf.IRI("http://example.org/c"))

	testing.expect_value(t, store.id_counter(a), u64(0))
	testing.expect_value(t, store.id_counter(b), u64(1))
	testing.expect_value(t, store.id_counter(c), u64(2))
	// Kinds count independently: the literal did not consume an IRI
	// counter.
	testing.expect_value(t, store.id_counter(l), u64(0))
}

@(test)
test_content_based_across_buffers :: proc(t: ^testing.T) {
	// The same content in two different backing buffers must intern to
	// one ID — this pins that map probing is content-based, the
	// property the whole term->ID design rests on.
	d: Dictionary
	dictionary_init(&d)
	defer dictionary_destroy(&d)

	copy_a := strings.clone("http://example.org/x")
	defer delete(copy_a)
	copy_b := strings.clone("http://example.org/x")
	defer delete(copy_b)
	testing.expect(t, raw_data(copy_a) != raw_data(copy_b))

	testing.expect_value(
		t,
		intern_term(&d, rdf.IRI(copy_a)),
		intern_term(&d, rdf.IRI(copy_b)),
	)
}

@(test)
test_blank_node_vs_iri_identity :: proc(t: ^testing.T) {
	d: Dictionary
	dictionary_init(&d)
	defer dictionary_destroy(&d)

	as_iri := intern_term(&d, rdf.IRI("n"))
	as_blank := intern_term(&d, rdf.Blank_Node("n"))
	testing.expect(t, as_iri != as_blank)
}

@(test)
test_literal_distinctions :: proc(t: ^testing.T) {
	d: Dictionary
	dictionary_init(&d)
	defer dictionary_destroy(&d)

	plain := intern_term(&d, rdf.literal("chat"))
	tagged_en := intern_term(&d, rdf.literal("chat", "en"))
	tagged_fr := intern_term(&d, rdf.literal("chat", "fr"))
	directed := intern_term(&d, rdf.literal("chat", "fr", rdf.Direction.LTR))
	typed := intern_term(&d, rdf.literal_typed("chat", rdf.IRI("http://example.org/dt")))

	ids := [?]store.Term_ID{plain, tagged_en, tagged_fr, directed, typed}
	for x, i in ids {
		for y in ids[i + 1:] {
			testing.expect(t, x != y)
		}
	}

	// Equal literals re-intern to the same ID.
	testing.expect_value(t, intern_term(&d, rdf.literal("chat", "fr")), tagged_fr)
	testing.expect_value(
		t,
		intern_term(&d, rdf.literal("chat", "fr", rdf.Direction.LTR)),
		directed,
	)
}

@(test)
test_lookup_round_trip :: proc(t: ^testing.T) {
	d: Dictionary
	dictionary_init(&d)
	defer dictionary_destroy(&d)

	inner := rdf.Triple {
		subject   = rdf.IRI("http://example.org/s"),
		predicate = rdf.IRI("http://example.org/p"),
		object    = rdf.literal("שלום", "he", rdf.Direction.RTL),
	}
	outer := rdf.Triple {
		subject   = rdf.Blank_Node("b1"),
		predicate = rdf.RDF_TYPE,
		object    = &inner, // nested triple term
	}
	terms := [?]rdf.Term {
		rdf.IRI("http://example.org/s"),
		rdf.Blank_Node("b1"),
		rdf.literal("42", "en"),
		&outer,
	}
	for term in terms {
		id := intern_term(&d, term)
		testing.expect(t, rdf.equal(lookup_term(&d, id), term))
	}
}

@(test)
test_graph_labels :: proc(t: ^testing.T) {
	d: Dictionary
	dictionary_init(&d)
	defer dictionary_destroy(&d)

	testing.expect_value(t, intern_graph_label(&d, nil), store.DEFAULT_GRAPH)
	testing.expect(t, lookup_graph_label(&d, store.DEFAULT_GRAPH) == nil)

	g := intern_graph_label(&d, rdf.IRI("http://example.org/g"))
	testing.expect_value(t, store.id_kind(g), store.Term_Kind.IRI)
	testing.expect(
		t,
		rdf.equal(lookup_graph_label(&d, g), rdf.Graph_Label(rdf.IRI("http://example.org/g"))),
	)

	// A graph label and a term with the same content share one ID.
	testing.expect_value(t, intern_term(&d, rdf.IRI("http://example.org/g")), g)
}

@(test)
test_encode_decode_quad :: proc(t: ^testing.T) {
	d: Dictionary
	dictionary_init(&d)
	defer dictionary_destroy(&d)

	q := rdf.Quad {
		triple = rdf.Triple {
			subject   = rdf.Blank_Node("s"),
			predicate = rdf.IRI("http://example.org/p"),
			object    = rdf.literal("chat", "fr"),
		},
		graph = rdf.IRI("http://example.org/g"),
	}
	encoded := encode_quad(&d, q)
	testing.expect(t, rdf.equal(decode_quad(&d, encoded), q))
	testing.expect_value(t, encode_quad(&d, q), encoded)

	// Same triple in the default graph is a different encoded quad.
	q_default := q
	q_default.graph = nil
	encoded_default := encode_quad(&d, q_default)
	testing.expect(t, encoded != encoded_default)
	testing.expect_value(t, encoded_default[store.QUAD_G], store.DEFAULT_GRAPH)
	testing.expect(t, rdf.equal(decode_quad(&d, encoded_default), q_default))
}

@(test)
test_interned_terms_survive_source_buffer :: proc(t: ^testing.T) {
	// RDF-A-0001 discipline: after interning, nothing references the
	// caller's buffer. Overwrite the source and verify the dictionary
	// still holds the original content.
	d: Dictionary
	dictionary_init(&d)
	defer dictionary_destroy(&d)

	buffer := make([]u8, 20)
	defer delete(buffer)
	copy(buffer, "http://example.org/a")

	id := intern_term(&d, rdf.IRI(string(buffer)))
	for &b in buffer {
		b = 'X'
	}
	testing.expect(t, rdf.equal(lookup_term(&d, id), rdf.Term(rdf.IRI("http://example.org/a"))))
}
