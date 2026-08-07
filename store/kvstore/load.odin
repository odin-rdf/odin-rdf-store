package kvstore

import "base:runtime"
import "core:strings"

import "rdf:rdf"
import quads_fmt "rdf:rdf/quads"
import trig_fmt "rdf:rdf/trig"
import triples_fmt "rdf:rdf/triples"
import turtle_fmt "rdf:rdf/turtle"
import store ".."

// Bulk ingestion into the persistent store, mirroring the semantics of
// the in-memory loaders (store/load.odin): a pull loop interning each
// statement's terms with per-load blank-node scoping, nothing borrowed
// from a statement surviving the iteration (RDF-A-0001).
//
// Two forms of each loader, and **they differ in exactly one thing that
// a reader will get backwards if it is not said plainly**:
//
//   - load_* opens its own write transaction, so a load is **atomic per
//     document** (STORE-I-0002 decision 2): on a parse or storage error
//     the transaction aborts and NOTHING persists — a deliberate
//     divergence from the in-memory loader, which kept already-inserted
//     statements.
//   - load_*_txn loads through the **caller's** transaction and does no
//     transaction management at all. It therefore **cannot** be atomic
//     per document: on a parse error the statements that parsed before
//     it are already written into that transaction, and **aborting is
//     the caller's job**. added reports what was written rather than 0,
//     because that is what is true.
//
// That is the correct division — a procedure handed someone else's
// transaction has no business ending it — but it is the exact opposite
// of what the bare form promises, so read the form you are calling.
//
// Blank-node scoping is per **load**, not per transaction: two
// load_*_txn calls in one transaction mint distinct blank nodes for the
// same `_:b0`, exactly as two separate loads do.
//
// Results separate the two failure worlds: parse_err reports the
// document's syntax error with the parser's position (message "" on
// success), err reports environment failures. Check err first.

// load_triples ingests an N-Triples document into a graph of the
// store (default graph unless a target graph label is given). Returns
// the number of quads newly added — duplicates don't count.
//
// Atomic per document, in its own write transaction: a parse error
// persists nothing. Fails with .Write_Txn_Open if the caller already
// holds a write transaction — that caller wants load_triples_txn.
load_triples :: proc(
	s: ^Store,
	source: []byte,
	graph: rdf.Graph_Label = nil,
	allocator := context.allocator,
) -> (
	added: int,
	parse_err: store.Load_Error,
	err: Error,
) {
	tx := txn_begin(s, .Write) or_return
	// txn_commit zeroes the handle, so this aborts only if the commit
	// below was not reached — including on the parse-error return.
	defer txn_abort(&tx)

	added, parse_err = load_triples_txn(&tx, source, graph, allocator) or_return
	if parse_err.message != "" {
		return 0, parse_err, nil
	}
	txn_commit(&tx) or_return
	return added, {}, nil
}

// load_triples_txn is load_triples through the caller's write
// transaction, doing no transaction management of its own.
//
// **Not atomic per document.** A parse error leaves every statement
// that parsed before it written into the caller's transaction, and
// added reports how many. **Aborting is the caller's job** — which is
// exactly what a consumer building a candidate for validation wants,
// since it has to decide about the whole transaction anyway.
//
// Blank-node scoping is per call: two of these in one transaction give
// the same `_:b0` two distinct blank nodes.
load_triples_txn :: proc(
	t: ^Txn,
	source: []byte,
	graph: rdf.Graph_Label = nil,
	allocator := context.allocator,
) -> (
	added: int,
	parse_err: store.Load_Error,
	err: Error,
) {
	p: triples_fmt.Parser
	triples_fmt.parser_init(&p, source, allocator)
	defer triples_fmt.parser_destroy(&p)

	scope := load_scope_make(allocator)
	defer load_scope_destroy(&scope)

	target := intern_graph_label_txn(t, graph) or_return
	for statement in triples_fmt.parser_next(&p) {
		scope_insert_triple(t, &scope, statement, target) or_return
	}
	if p.err.kind != .None {
		return scope.added,
			load_parse_error(triples_fmt.error_message(p.err.kind), p.err.line, p.err.column),
			nil
	}
	return scope.added, {}, nil
}

// load_turtle ingests a Turtle document; see load_triples. base
// resolves relative IRIs, as for the underlying parser.
load_turtle :: proc(
	s: ^Store,
	source: []byte,
	base := "",
	graph: rdf.Graph_Label = nil,
	allocator := context.allocator,
) -> (
	added: int,
	parse_err: store.Load_Error,
	err: Error,
) {
	tx := txn_begin(s, .Write) or_return
	defer txn_abort(&tx)

	added, parse_err = load_turtle_txn(&tx, source, base, graph, allocator) or_return
	if parse_err.message != "" {
		return 0, parse_err, nil
	}
	txn_commit(&tx) or_return
	return added, {}, nil
}

// load_turtle_txn is load_turtle through the caller's write
// transaction; see load_triples_txn for what that changes.
load_turtle_txn :: proc(
	t: ^Txn,
	source: []byte,
	base := "",
	graph: rdf.Graph_Label = nil,
	allocator := context.allocator,
) -> (
	added: int,
	parse_err: store.Load_Error,
	err: Error,
) {
	p: turtle_fmt.Parser
	turtle_fmt.parser_init(&p, source, base, allocator)
	defer turtle_fmt.parser_destroy(&p)

	scope := load_scope_make(allocator)
	defer load_scope_destroy(&scope)

	target := intern_graph_label_txn(t, graph) or_return
	for statement in turtle_fmt.parser_next(&p) {
		scope_insert_triple(t, &scope, statement, target) or_return
	}
	if p.err.kind != .None {
		return scope.added,
			load_parse_error(turtle_fmt.error_message(p.err.kind), p.err.line, p.err.column),
			nil
	}
	return scope.added, {}, nil
}

// load_quads ingests an N-Quads document; each statement lands in the
// graph it names (default graph when unnamed).
load_quads :: proc(
	s: ^Store,
	source: []byte,
	allocator := context.allocator,
) -> (
	added: int,
	parse_err: store.Load_Error,
	err: Error,
) {
	tx := txn_begin(s, .Write) or_return
	defer txn_abort(&tx)

	added, parse_err = load_quads_txn(&tx, source, allocator) or_return
	if parse_err.message != "" {
		return 0, parse_err, nil
	}
	txn_commit(&tx) or_return
	return added, {}, nil
}

// load_quads_txn is load_quads through the caller's write transaction;
// see load_triples_txn for what that changes.
load_quads_txn :: proc(
	t: ^Txn,
	source: []byte,
	allocator := context.allocator,
) -> (
	added: int,
	parse_err: store.Load_Error,
	err: Error,
) {
	p: quads_fmt.Parser
	quads_fmt.parser_init(&p, source, allocator)
	defer quads_fmt.parser_destroy(&p)

	scope := load_scope_make(allocator)
	defer load_scope_destroy(&scope)

	for q in quads_fmt.parser_next(&p) {
		scope_insert_quad(t, &scope, q) or_return
	}
	if p.err.kind != .None {
		return scope.added,
			load_parse_error(quads_fmt.error_message(p.err.kind), p.err.line, p.err.column),
			nil
	}
	return scope.added, {}, nil
}

// load_trig ingests a TriG document; see load_quads. base resolves
// relative IRIs, as for the underlying parser.
load_trig :: proc(
	s: ^Store,
	source: []byte,
	base := "",
	allocator := context.allocator,
) -> (
	added: int,
	parse_err: store.Load_Error,
	err: Error,
) {
	tx := txn_begin(s, .Write) or_return
	defer txn_abort(&tx)

	added, parse_err = load_trig_txn(&tx, source, base, allocator) or_return
	if parse_err.message != "" {
		return 0, parse_err, nil
	}
	txn_commit(&tx) or_return
	return added, {}, nil
}

// load_trig_txn is load_trig through the caller's write transaction;
// see load_triples_txn for what that changes.
load_trig_txn :: proc(
	t: ^Txn,
	source: []byte,
	base := "",
	allocator := context.allocator,
) -> (
	added: int,
	parse_err: store.Load_Error,
	err: Error,
) {
	p: trig_fmt.Parser
	trig_fmt.parser_init(&p, source, base, allocator)
	defer trig_fmt.parser_destroy(&p)

	scope := load_scope_make(allocator)
	defer load_scope_destroy(&scope)

	for q in trig_fmt.parser_next(&p) {
		scope_insert_quad(t, &scope, q) or_return
	}
	if p.err.kind != .None {
		return scope.added,
			load_parse_error(trig_fmt.error_message(p.err.kind), p.err.line, p.err.column),
			nil
	}
	return scope.added, {}, nil
}

@(private)
load_parse_error :: proc(message: string, line, column: int) -> store.Load_Error {
	return store.Load_Error{message = message, line = line, column = column}
}

// Load_Scope is one load's blank-node scope: original label (cloned,
// scope-owned) -> the fresh blank node it maps to in this load.
@(private)
Load_Scope :: struct {
	allocator: runtime.Allocator,
	blanks:    map[string]store.Term_ID,
	added:     int,
}

// load_scope_make opens one load's blank-node scope. One per _txn
// call, which is what keeps scoping per load rather than per
// transaction.
@(private)
load_scope_make :: proc(allocator: runtime.Allocator) -> (scope: Load_Scope) {
	scope.allocator = allocator
	scope.blanks = make(map[string]store.Term_ID, 8, allocator)
	return scope
}

@(private)
load_scope_destroy :: proc(scope: ^Load_Scope) {
	for label in scope.blanks {
		delete(label, scope.allocator)
	}
	delete(scope.blanks)
	scope^ = {}
}

@(private)
scope_blank :: proc(t: ^Txn, scope: ^Load_Scope, label: string) -> (id: store.Term_ID, err: Error) {
	if existing, ok := scope.blanks[label]; ok {
		return existing, nil
	}
	id = fresh_blank_txn(t) or_return
	// The label is borrowed from the current parser statement; clone it
	// for the scope map, which outlives the statement.
	scope.blanks[strings.clone(label, scope.allocator)] = id
	return id, nil
}

// scope_term interns a term with this load's blank-node mapping
// applied, recursing into RDF-star triple terms so blank nodes inside
// them are scoped too.
@(private)
scope_term :: proc(t: ^Txn, scope: ^Load_Scope, term: rdf.Term) -> (id: store.Term_ID, err: Error) {
	switch v in term {
	case rdf.IRI, rdf.Literal:
		return intern_term_txn(t, term)
	case rdf.Blank_Node:
		return scope_blank(t, scope, string(v))
	case ^rdf.Triple:
		assert(v != nil, "scope_term: nil triple term")
		components: [3]store.Term_ID
		components[0] = scope_term(t, scope, v.subject) or_return
		components[1] = scope_term(t, scope, v.predicate) or_return
		components[2] = scope_term(t, scope, v.object) or_return
		return intern_triple_ids_txn(t, components)
	}
	panic("scope_term: nil term")
}

@(private)
scope_insert_triple :: proc(
	tx: ^Txn,
	scope: ^Load_Scope,
	t: rdf.Triple,
	target: store.Term_ID,
) -> (
	err: Error,
) {
	q: store.Encoded_Quad
	q[store.QUAD_S] = scope_term(tx, scope, t.subject) or_return
	q[store.QUAD_P] = scope_term(tx, scope, t.predicate) or_return
	q[store.QUAD_O] = scope_term(tx, scope, t.object) or_return
	q[store.QUAD_G] = target
	added := insert_txn(tx, q) or_return
	if added {
		scope.added += 1
	}
	return nil
}

@(private)
scope_insert_quad :: proc(t: ^Txn, scope: ^Load_Scope, q: rdf.Quad) -> (err: Error) {
	graph: store.Term_ID
	switch v in q.graph {
	case rdf.IRI:
		graph = intern_term_txn(t, v) or_return
	case rdf.Blank_Node:
		graph = scope_blank(t, scope, string(v)) or_return
	case:
		graph = store.DEFAULT_GRAPH
	}

	encoded: store.Encoded_Quad
	encoded[store.QUAD_S] = scope_term(t, scope, q.subject) or_return
	encoded[store.QUAD_P] = scope_term(t, scope, q.predicate) or_return
	encoded[store.QUAD_O] = scope_term(t, scope, q.object) or_return
	encoded[store.QUAD_G] = graph
	added := insert_txn(t, encoded) or_return
	if added {
		scope.added += 1
	}
	return nil
}
