package memstore

import store ".."

import "base:runtime"
import "core:strings"
import "rdf:rdf"
import quads_fmt "rdf:rdf/quads"
import trig_fmt "rdf:rdf/trig"
import triples_fmt "rdf:rdf/triples"
import turtle_fmt "rdf:rdf/turtle"

// Bulk ingestion from the odin-rdf-parser formats: a pull loop that
// interns each statement's terms and inserts the encoded quad, one
// statement at a time. Nothing borrowed from a parser statement
// survives the loop iteration (RDF-A-0001): all retention goes through
// the dictionary's owned storage.
//
// Blank-node scoping (STORE-I-0001 decision 6): blank node labels are
// document-scoped, so every load maps each distinct label it sees to a
// brand-new blank node (fresh_blank) — loading two documents that both
// say "_:b0" yields two distinct terms, while "_:b0" twice within one
// load yields one. Loaded blank nodes therefore carry generated labels,
// not the document's.
//
// On a syntax error the load stops and reports the parser's position;
// statements already inserted remain (the store is append-only — there
// is no rollback), and the returned count says how many.

// load_triples ingests an N-Triples document into a graph of the
// dataset (default graph unless a target graph label is given).
// Returns the number of quads newly added — duplicates of quads
// already present don't count.
load_triples :: proc(
	d: ^Dictionary,
	ds: ^Dataset,
	source: []byte,
	graph: rdf.Graph_Label = nil,
	allocator := context.allocator,
) -> (
	added: int,
	err: store.Load_Error,
) {
	scope: Load_Scope
	load_scope_init(&scope, d, ds, allocator)
	defer load_scope_destroy(&scope)
	target := intern_graph_label(d, graph)

	p: triples_fmt.Parser
	triples_fmt.parser_init(&p, source, allocator)
	defer triples_fmt.parser_destroy(&p)
	for t in triples_fmt.parser_next(&p) {
		scope_insert_triple(&scope, t, target)
	}
	return scope.added, load_error(p.err.kind != .None, triples_fmt.error_message(p.err.kind), p.err.line, p.err.column)
}

// load_turtle ingests a Turtle document; see load_triples. base
// resolves relative IRIs, as for the underlying parser.
load_turtle :: proc(
	d: ^Dictionary,
	ds: ^Dataset,
	source: []byte,
	base := "",
	graph: rdf.Graph_Label = nil,
	allocator := context.allocator,
) -> (
	added: int,
	err: store.Load_Error,
) {
	scope: Load_Scope
	load_scope_init(&scope, d, ds, allocator)
	defer load_scope_destroy(&scope)
	target := intern_graph_label(d, graph)

	p: turtle_fmt.Parser
	turtle_fmt.parser_init(&p, source, base, allocator)
	defer turtle_fmt.parser_destroy(&p)
	for t in turtle_fmt.parser_next(&p) {
		scope_insert_triple(&scope, t, target)
	}
	return scope.added, load_error(p.err.kind != .None, turtle_fmt.error_message(p.err.kind), p.err.line, p.err.column)
}

// load_quads ingests an N-Quads document; each statement lands in the
// graph it names (default graph when unnamed).
load_quads :: proc(
	d: ^Dictionary,
	ds: ^Dataset,
	source: []byte,
	allocator := context.allocator,
) -> (
	added: int,
	err: store.Load_Error,
) {
	scope: Load_Scope
	load_scope_init(&scope, d, ds, allocator)
	defer load_scope_destroy(&scope)

	p: quads_fmt.Parser
	quads_fmt.parser_init(&p, source, allocator)
	defer quads_fmt.parser_destroy(&p)
	for q in quads_fmt.parser_next(&p) {
		scope_insert_quad(&scope, q)
	}
	return scope.added, load_error(p.err.kind != .None, quads_fmt.error_message(p.err.kind), p.err.line, p.err.column)
}

// load_trig ingests a TriG document; see load_quads. base resolves
// relative IRIs, as for the underlying parser.
load_trig :: proc(
	d: ^Dictionary,
	ds: ^Dataset,
	source: []byte,
	base := "",
	allocator := context.allocator,
) -> (
	added: int,
	err: store.Load_Error,
) {
	scope: Load_Scope
	load_scope_init(&scope, d, ds, allocator)
	defer load_scope_destroy(&scope)

	p: trig_fmt.Parser
	trig_fmt.parser_init(&p, source, base, allocator)
	defer trig_fmt.parser_destroy(&p)
	for q in trig_fmt.parser_next(&p) {
		scope_insert_quad(&scope, q)
	}
	return scope.added, load_error(p.err.kind != .None, trig_fmt.error_message(p.err.kind), p.err.line, p.err.column)
}

@(private)
load_error :: proc(failed: bool, message: string, line, column: int) -> store.Load_Error {
	if !failed {
		return {}
	}
	return store.Load_Error{message = message, line = line, column = column}
}

// Load_Scope is one load's blank-node scope: original label (cloned,
// scope-owned) -> the fresh blank node it maps to in this load.
@(private)
Load_Scope :: struct {
	d:         ^Dictionary,
	ds:        ^Dataset,
	allocator: runtime.Allocator,
	blanks:    map[string]store.Term_ID,
	added:     int,
}

@(private)
load_scope_init :: proc(s: ^Load_Scope, d: ^Dictionary, ds: ^Dataset, allocator: runtime.Allocator) {
	s.d = d
	s.ds = ds
	s.allocator = allocator
	s.blanks = make(map[string]store.Term_ID, 8, allocator)
	s.added = 0
}

@(private)
load_scope_destroy :: proc(s: ^Load_Scope) {
	for label in s.blanks {
		delete(label, s.allocator)
	}
	delete(s.blanks)
	s^ = {}
}

@(private)
scope_blank :: proc(s: ^Load_Scope, label: string) -> store.Term_ID {
	if id, ok := s.blanks[label]; ok {
		return id
	}
	id := fresh_blank(s.d)
	// The label is borrowed from the current parser statement; clone it
	// for the scope map, which outlives the statement.
	s.blanks[strings.clone(label, s.allocator)] = id
	return id
}

// scope_term interns a term with this load's blank-node mapping
// applied, recursing into RDF-star triple terms so blank nodes inside
// them are scoped too.
@(private)
scope_term :: proc(s: ^Load_Scope, term: rdf.Term) -> store.Term_ID {
	switch v in term {
	case rdf.IRI, rdf.Literal:
		return intern_term(s.d, term)
	case rdf.Blank_Node:
		return scope_blank(s, string(v))
	case ^rdf.Triple:
		assert(v != nil, "scope_term: nil triple term")
		return intern_triple_ids(
			s.d,
			[3]store.Term_ID {
				scope_term(s, v.subject),
				scope_term(s, v.predicate),
				scope_term(s, v.object),
			},
		)
	}
	panic("scope_term: nil term")
}

@(private)
scope_insert_triple :: proc(s: ^Load_Scope, t: rdf.Triple, target: store.Term_ID) {
	q := store.Encoded_Quad {
		scope_term(s, t.subject),
		scope_term(s, t.predicate),
		scope_term(s, t.object),
		target,
	}
	if insert(s.ds, q) {
		s.added += 1
	}
}

@(private)
scope_insert_quad :: proc(s: ^Load_Scope, q: rdf.Quad) {
	graph: store.Term_ID
	switch v in q.graph {
	case rdf.IRI:
		graph = intern_term(s.d, v)
	case rdf.Blank_Node:
		graph = scope_blank(s, string(v))
	case:
		graph = store.DEFAULT_GRAPH
	}
	encoded := store.Encoded_Quad {
		scope_term(s, q.subject),
		scope_term(s, q.predicate),
		scope_term(s, q.object),
		graph,
	}
	if insert(s.ds, encoded) {
		s.added += 1
	}
}
