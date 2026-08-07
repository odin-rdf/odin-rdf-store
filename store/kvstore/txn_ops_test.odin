package kvstore

// The _txn procedure set (STORE-T-0036) and match_txn (STORE-T-0037).
//
// The uniform assertions — read-your-own-writes, invisibility outside,
// a snapshot unchanged across a commit — belong to the shared
// conformance suite and land there in STORE-T-0039. What is here is
// what is specific to this backend's shape: that the bare forms really
// are the _txn forms plus a transaction, that a borrowed transaction
// outlives its iterators, and that the one bare form whose result
// outlives the call still cleans up after itself.

import "core:testing"

import "rdf:rdf"
import store ".."

@(private = "file")
EX :: "http://example.org/"

@(private = "file")
drain :: proc(it: ^Match_Iterator) -> int {
	n := 0
	for _ in match_next(it) {
		n += 1
	}
	return n
}

// Read-your-own-writes, on every read form that has one. This is the
// property the whole initiative exists for: a reader inside the
// transaction sees the write, and the same read outside it does not.
@(test)
test_txn_reads_see_own_writes :: proc(t: ^testing.T) {
	s := scratch_store()
	defer close(s)

	tx, err := txn_begin(s, .Write)
	testing.expect(t, err == nil)

	q := rdf.Quad {
		triple = {rdf.IRI(EX + "alice"), rdf.IRI(EX + "knows"), rdf.IRI(EX + "bob")},
	}
	encoded, eerr := encode_quad_txn(&tx, q)
	testing.expect(t, eerr == nil)
	added, ierr := insert_txn(&tx, encoded)
	testing.expect(t, ierr == nil)
	testing.expect_value(t, added, true)

	n, cerr := count_txn(&tx)
	testing.expect(t, cerr == nil)
	testing.expect_value(t, n, 1)

	id, found, ferr := find_term_txn(&tx, rdf.IRI(EX + "knows"))
	testing.expect(t, ferr == nil)
	testing.expect(t, found)
	testing.expect_value(t, id, encoded[store.QUAD_P])

	term, lerr := lookup_term_txn(&tx, id, context.temp_allocator)
	testing.expect(t, lerr == nil)
	testing.expect(t, rdf.equal(term, rdf.Term(rdf.IRI(EX + "knows"))))

	it, merr := match_txn(&tx, store.MATCH_ALL)
	testing.expect(t, merr == nil)
	testing.expect_value(t, drain(&it), 1)
	match_destroy(&it)

	round, derr := decode_quad_txn(&tx, encoded, context.temp_allocator)
	testing.expect(t, derr == nil)
	testing.expect(t, rdf.equal(round.subject, rdf.Term(rdf.IRI(EX + "alice"))))
	free_all(context.temp_allocator)

	// Nothing of the above is visible outside the transaction. The
	// autocommit reads cannot be used for this while a write
	// transaction is open on the same handle — count and find_term open
	// read transactions, which is legal — so they are the check.
	outside_n, ocerr := count(s)
	testing.expect(t, ocerr == nil)
	testing.expect_value(t, outside_n, 0)
	_, outside_found, oferr := find_term(s, rdf.IRI(EX + "knows"))
	testing.expect(t, oferr == nil)
	testing.expect_value(t, outside_found, false)

	testing.expect(t, txn_commit(&tx) == nil)

	after, aerr := count(s)
	testing.expect(t, aerr == nil)
	testing.expect_value(t, after, 1)
}

// A snapshot is a read transaction: what it sees does not change under
// it. This is STORE-T-0019's acceptance criterion, in one test.
@(test)
test_read_txn_is_a_snapshot :: proc(t: ^testing.T) {
	s := scratch_store()
	defer close(s)

	first := rdf.Quad{triple = {rdf.IRI(EX + "a"), rdf.IRI(EX + "p"), rdf.IRI(EX + "o")}}
	e1, eerr := encode_quad(s, first)
	testing.expect(t, eerr == nil)
	_, ierr := insert(s, e1)
	testing.expect(t, ierr == nil)

	snapshot, terr := txn_begin(s, .Read)
	testing.expect(t, terr == nil)
	defer txn_abort(&snapshot)

	// A whole autocommit write lands while the snapshot is open.
	second := rdf.Quad{triple = {rdf.IRI(EX + "b"), rdf.IRI(EX + "p"), rdf.IRI(EX + "o")}}
	e2, eerr2 := encode_quad(s, second)
	testing.expect(t, eerr2 == nil)
	_, ierr2 := insert(s, e2)
	testing.expect(t, ierr2 == nil)

	n, cerr := count_txn(&snapshot)
	testing.expect(t, cerr == nil)
	testing.expect_value(t, n, 1)

	it, merr := match_txn(&snapshot, store.MATCH_ALL)
	testing.expect(t, merr == nil)
	testing.expect_value(t, drain(&it), 1)
	match_destroy(&it)

	// The term the later write interned is not in the snapshot's
	// dictionary either, so a query resolving its constants against one
	// snapshot cannot half-see the write.
	_, found, ferr := find_term_txn(&snapshot, rdf.IRI(EX + "b"))
	testing.expect(t, ferr == nil)
	testing.expect_value(t, found, false)

	// Outside it, both are there.
	outside, oerr := count(s)
	testing.expect(t, oerr == nil)
	testing.expect_value(t, outside, 2)
}

// The borrowing half of match_txn, which is the whole of T-0037's
// design: destroying one iterator must not close the transaction its
// siblings are reading through.
@(test)
test_match_txn_borrows_the_transaction :: proc(t: ^testing.T) {
	s := scratch_store()
	defer close(s)

	src := `<http://example.org/a> <http://example.org/p> "x" .
<http://example.org/b> <http://example.org/p> "y" .`
	added, perr, lerr := load_triples(s, transmute([]u8)src)
	testing.expect(t, lerr == nil)
	testing.expect_value(t, perr.message, "")
	testing.expect_value(t, added, 2)

	tx, terr := txn_begin(s, .Read)
	testing.expect(t, terr == nil)
	defer txn_abort(&tx)

	first, e1 := match_txn(&tx, store.MATCH_ALL)
	testing.expect(t, e1 == nil)
	second, e2 := match_txn(&tx, store.MATCH_ALL)
	testing.expect(t, e2 == nil)

	// Destroying one leaves the other, and the transaction, usable.
	match_destroy(&first)
	testing.expect_value(t, drain(&second), 2)
	match_destroy(&second)

	n, cerr := count_txn(&tx)
	testing.expect(t, cerr == nil)
	testing.expect_value(t, n, 2)

	third, e3 := match_txn(&tx, store.MATCH_ALL)
	testing.expect(t, e3 == nil)
	testing.expect_value(t, drain(&third), 2)
	match_destroy(&third)
}

// Bare match still owns the transaction it opened — the one autocommit
// form whose result outlives the call, so match_destroy is what closes
// it rather than the return.
@(test)
test_bare_match_still_owns_its_transaction :: proc(t: ^testing.T) {
	s := scratch_store()
	defer close(s)

	src := `<http://example.org/a> <http://example.org/p> "x" .`
	_, _, lerr := load_triples(s, transmute([]u8)src)
	testing.expect(t, lerr == nil)

	it, merr := match(s, store.MATCH_ALL)
	testing.expect(t, merr == nil)
	testing.expect(t, it.owned.txn != nil, "bare match's iterator holds a transaction of its own")
	testing.expect_value(t, drain(&it), 1)
	match_destroy(&it)

	// An iterator from match_txn holds none, which is the difference.
	tx, terr := txn_begin(s, .Read)
	testing.expect(t, terr == nil)
	defer txn_abort(&tx)
	borrowed, berr := match_txn(&tx, store.MATCH_ALL)
	testing.expect(t, berr == nil)
	testing.expect(t, borrowed.owned.txn == nil, "match_txn's iterator borrows")
	match_destroy(&borrowed)

	// A read transaction is not a writer, so many bare matches may be
	// open at once and the environment is not serialized by them.
	a, _ := match(s, store.MATCH_ALL)
	b, _ := match(s, store.MATCH_ALL)
	testing.expect_value(t, drain(&a), 1)
	testing.expect_value(t, drain(&b), 1)
	match_destroy(&a)
	match_destroy(&b)
}

// The bare forms are the _txn forms plus a transaction, so they must
// still mean exactly what they meant. The rest of this package's suite
// is the real check; this asserts the seam directly.
@(test)
test_bare_forms_are_autocommit :: proc(t: ^testing.T) {
	s := scratch_store()
	defer close(s)

	q := rdf.Quad{triple = {rdf.IRI(EX + "a"), rdf.IRI(EX + "p"), rdf.IRI(EX + "o")}}
	encoded, eerr := encode_quad(s, q)
	testing.expect(t, eerr == nil)

	// encode_quad committed, so the terms are visible to an independent
	// reader — the whole content of "autocommit".
	id, found, ferr := find_term(s, rdf.IRI(EX + "p"))
	testing.expect(t, ferr == nil)
	testing.expect(t, found)
	testing.expect_value(t, id, encoded[store.QUAD_P])

	added, ierr := insert(s, encoded)
	testing.expect(t, ierr == nil)
	testing.expect_value(t, added, true)
	again, ierr2 := insert(s, encoded)
	testing.expect(t, ierr2 == nil)
	testing.expect_value(t, again, false)

	n, cerr := count(s)
	testing.expect(t, cerr == nil)
	testing.expect_value(t, n, 1)

	g, gerr := lookup_graph_label(s, store.DEFAULT_GRAPH)
	testing.expect(t, gerr == nil)
	testing.expect(t, g == nil)

	label := rdf.Graph_Label(rdf.IRI(EX + "g"))
	gid, gierr := intern_graph_label(s, label)
	testing.expect(t, gierr == nil)
	fid, gfound, gferr := find_graph_label(s, label)
	testing.expect(t, gferr == nil)
	testing.expect(t, gfound)
	testing.expect_value(t, fid, gid)
}

// A write form on a read transaction fails cleanly rather than
// corrupting anything — the price of checking the mode at runtime.
@(test)
test_write_forms_refuse_a_read_transaction :: proc(t: ^testing.T) {
	s := scratch_store()
	defer close(s)

	tx, err := txn_begin(s, .Read)
	testing.expect(t, err == nil)
	defer txn_abort(&tx)

	_, ierr := intern_term_txn(&tx, rdf.IRI(EX + "a"))
	testing.expect(t, ierr != nil)

	q := rdf.Quad{triple = {rdf.IRI(EX + "a"), rdf.IRI(EX + "p"), rdf.IRI(EX + "o")}}
	_, eerr := encode_quad_txn(&tx, q)
	testing.expect(t, eerr != nil)

	// And the read forms on the same transaction still work, so the
	// failure did not poison it.
	n, cerr := count_txn(&tx)
	testing.expect(t, cerr == nil)
	testing.expect_value(t, n, 0)
}

// The loaders' _txn forms (STORE-T-0038). What matters is the contract
// inversion: a bare loader is atomic per document, and a _txn one
// cannot be, because the transaction belongs to the caller.

@(test)
test_load_txn_is_visible_inside_and_gone_on_abort :: proc(t: ^testing.T) {
	s := scratch_store()
	defer close(s)

	tx, err := txn_begin(s, .Write)
	testing.expect(t, err == nil)

	ttl := `@prefix ex: <http://example.org/> .
ex:alice ex:knows ex:bob ; ex:name "Alice"@en .`
	added, perr, lerr := load_turtle_txn(&tx, transmute([]u8)ttl)
	testing.expect(t, lerr == nil)
	testing.expect_value(t, perr.message, "")
	testing.expect_value(t, added, 2)

	// The candidate is readable through the transaction that built it —
	// validate-before-commit, at document granularity.
	n, cerr := count_txn(&tx)
	testing.expect(t, cerr == nil)
	testing.expect_value(t, n, 2)
	it, merr := match_txn(&tx, store.MATCH_ALL)
	testing.expect(t, merr == nil)
	testing.expect_value(t, drain(&it), 2)
	match_destroy(&it)

	// And invisible outside it until the decision is taken.
	outside, oerr := count(s)
	testing.expect(t, oerr == nil)
	testing.expect_value(t, outside, 0)

	txn_abort(&tx)
	after, aerr := count(s)
	testing.expect(t, aerr == nil)
	testing.expect_value(t, after, 0)
}

// The inversion, asserted rather than only documented: a parse error
// leaves the caller's transaction dirty, and added says how dirty.
// The bare loader on the same document persists nothing.
@(test)
test_load_txn_leaves_the_transaction_dirty_on_a_parse_error :: proc(t: ^testing.T) {
	s := scratch_store()
	defer close(s)

	src := `<http://example.org/a> <http://example.org/p> "ok" .
<http://example.org/b> <http://example.org/p> "ok too" .
<http://example.org/c> <http://example.org/p> "missing dot"`

	tx, err := txn_begin(s, .Write)
	testing.expect(t, err == nil)

	added, perr, lerr := load_triples_txn(&tx, transmute([]u8)src)
	testing.expect(t, lerr == nil)
	testing.expect(t, perr.message != "", "the document must fail to parse")
	testing.expect_value(t, perr.line, 3)
	// Not 0: the statements before the error are in the transaction, and
	// added reports what was written rather than what survived.
	testing.expect_value(t, added, 2)

	n, cerr := count_txn(&tx)
	testing.expect(t, cerr == nil)
	testing.expect_value(t, n, 2)

	// Aborting is the caller's job, and it is the caller's job that
	// makes the outcome match the bare loader's.
	txn_abort(&tx)
	after, aerr := count(s)
	testing.expect(t, aerr == nil)
	testing.expect_value(t, after, 0)

	// The bare form on the same document is atomic per document, so it
	// needs no such care.
	bare_added, bare_perr, bare_err := load_triples(s, transmute([]u8)src)
	testing.expect(t, bare_err == nil)
	testing.expect(t, bare_perr.message != "")
	testing.expect_value(t, bare_added, 0)
	bare_n, bcerr := count(s)
	testing.expect(t, bcerr == nil)
	testing.expect_value(t, bare_n, 0)
}

// Blank-node scoping is per load, not per transaction. Two loads of one
// blank-node-dense document in a single transaction must double the
// quad count, exactly as two separate loads do — this is the property
// STORE-I-0003 found the shapes-graph trap in, and it must not quietly
// change now that two loads can share a transaction.
@(test)
test_load_txn_scopes_blanks_per_load_not_per_transaction :: proc(t: ^testing.T) {
	s := scratch_store()
	defer close(s)

	src := `_:b0 <http://example.org/p> "x" .
_:b0 <http://example.org/q> _:b1 .`

	tx, err := txn_begin(s, .Write)
	testing.expect(t, err == nil)

	first, perr1, lerr1 := load_triples_txn(&tx, transmute([]u8)src)
	testing.expect(t, lerr1 == nil)
	testing.expect_value(t, perr1.message, "")
	testing.expect_value(t, first, 2)

	second, perr2, lerr2 := load_triples_txn(&tx, transmute([]u8)src)
	testing.expect(t, lerr2 == nil)
	testing.expect_value(t, perr2.message, "")
	// Fresh blanks in the second load, so nothing dedupes.
	testing.expect_value(t, second, 2)

	n, cerr := count_txn(&tx)
	testing.expect(t, cerr == nil)
	testing.expect_value(t, n, 4)

	testing.expect(t, txn_commit(&tx) == nil)

	// Ground statements, by contrast, dedupe across loads in one
	// transaction — set semantics is unaffected by the scoping.
	ground := `<http://example.org/a> <http://example.org/p> "x" .`
	tx2, err2 := txn_begin(s, .Write)
	testing.expect(t, err2 == nil)
	defer txn_abort(&tx2)
	g1, _, _ := load_triples_txn(&tx2, transmute([]u8)ground)
	g2, _, _ := load_triples_txn(&tx2, transmute([]u8)ground)
	testing.expect_value(t, g1, 1)
	testing.expect_value(t, g2, 0)
}

// All four formats reach their _txn form, and a graph label threads
// through the two that take one.
@(test)
test_load_txn_all_four_formats :: proc(t: ^testing.T) {
	s := scratch_store()
	defer close(s)

	tx, err := txn_begin(s, .Write)
	testing.expect(t, err == nil)
	defer txn_abort(&tx)

	nt := `<http://example.org/alice> <http://example.org/knows> <http://example.org/bob> .`
	a1, p1, e1 := load_triples_txn(&tx, transmute([]u8)nt, rdf.IRI(EX + "g"))
	testing.expect(t, e1 == nil)
	testing.expect_value(t, p1.message, "")
	testing.expect_value(t, a1, 1)

	ttl := `@prefix ex: <http://example.org/> .
ex:alice ex:age 42 .`
	a2, p2, e2 := load_turtle_txn(&tx, transmute([]u8)ttl, "", rdf.IRI(EX + "g"))
	testing.expect(t, e2 == nil)
	testing.expect_value(t, p2.message, "")
	testing.expect_value(t, a2, 1)

	nq := `<http://example.org/s> <http://example.org/p> "chat"@fr <http://example.org/g1> .`
	a3, p3, e3 := load_quads_txn(&tx, transmute([]u8)nq)
	testing.expect(t, e3 == nil)
	testing.expect_value(t, p3.message, "")
	testing.expect_value(t, a3, 1)

	trig := `@prefix ex: <http://example.org/> .
ex:g2 { ex:s2 ex:p ex:o . }`
	a4, p4, e4 := load_trig_txn(&tx, transmute([]u8)trig)
	testing.expect(t, e4 == nil)
	testing.expect_value(t, p4.message, "")
	testing.expect_value(t, a4, 1)

	n, cerr := count_txn(&tx)
	testing.expect(t, cerr == nil)
	testing.expect_value(t, n, 4)

	// The graph parameter landed: the two triple loads went to ex:g.
	gid, found, ferr := find_graph_label_txn(&tx, rdf.Graph_Label(rdf.IRI(EX + "g")))
	testing.expect(t, ferr == nil)
	testing.expect(t, found)
	named, merr := match_txn(&tx, store.Match_Pattern{store.WILDCARD, store.WILDCARD, store.WILDCARD, gid})
	testing.expect(t, merr == nil)
	testing.expect_value(t, drain(&named), 2)
	match_destroy(&named)
}
