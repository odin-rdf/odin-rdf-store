package kvstore

// The Txn handle's own tests (STORE-T-0034): its lifecycle, the
// single-writer refusal, and the counter-mirror invariant.
//
// The operations that take a ^Txn are not published yet — that is
// STORE-T-0036 and T-0037 — so the tests below reach the private
// (s, txn, …) internals through the handle's fields. That is
// deliberately temporary: once insert_txn takes a ^Txn these become
// insert_txn(&t, q) and stop looking through it.

import "core:testing"

import "rdf:rdf"
import lmdb "../../vendor/lmdb"
import store ".."

@(private = "file")
a_quad :: proc(s: ^Store, n: u64) -> store.Encoded_Quad {
	return store.Encoded_Quad {
		store.make_id(.IRI, n),
		store.make_id(.IRI, 1),
		store.make_id(.Literal, n),
		store.DEFAULT_GRAPH,
	}
}

// persisted_counters reads the per-kind counters back out of meta —
// the side of the invariant that LMDB rolls back for us, and the thing
// Store.next has to keep equal to.
@(private = "file")
persisted_counters :: proc(s: ^Store) -> (counters: [4]u64) {
	txn: ^lmdb.Txn
	assert(lmdb.txn_begin(s.env, nil, lmdb.RDONLY, &txn) == lmdb.SUCCESS)
	defer lmdb.txn_abort(txn)
	for key, i in meta_counter_keys {
		value, _, err := meta_get(s, txn, key)
		assert(err == nil)
		counters[i] = value
	}
	return counters
}

@(test)
test_txn_commit_makes_writes_visible :: proc(t: ^testing.T) {
	s := scratch_store()
	defer close(s)

	tx, err := txn_begin(s, .Write)
	testing.expect(t, err == nil)
	added, ierr := insert_txn(tx.s, tx.txn, a_quad(s, 1))
	testing.expect(t, ierr == nil)
	testing.expect_value(t, added, true)
	testing.expect(t, txn_commit(&tx) == nil)

	n, cerr := count(s)
	testing.expect(t, cerr == nil)
	testing.expect_value(t, n, 1)
}

@(test)
test_txn_abort_leaves_nothing :: proc(t: ^testing.T) {
	s := scratch_store()
	defer close(s)

	tx, err := txn_begin(s, .Write)
	testing.expect(t, err == nil)
	_, ierr := insert_txn(tx.s, tx.txn, a_quad(s, 1))
	testing.expect(t, ierr == nil)
	txn_abort(&tx)

	n, cerr := count(s)
	testing.expect(t, cerr == nil)
	testing.expect_value(t, n, 0)
}

// Committing or aborting zeroes the handle, so a second call is a
// no-op rather than a double free. It does not save a *copy* — that
// hazard is documented, not guarded, exactly as Match_Iterator's is.
@(test)
test_txn_second_end_is_a_no_op :: proc(t: ^testing.T) {
	s := scratch_store()
	defer close(s)

	tx, err := txn_begin(s, .Write)
	testing.expect(t, err == nil)
	testing.expect(t, txn_commit(&tx) == nil)
	testing.expect(t, txn_commit(&tx) == nil)
	txn_abort(&tx)

	tx2, err2 := txn_begin(s, .Read)
	testing.expect(t, err2 == nil)
	txn_abort(&tx2)
	txn_abort(&tx2)
}

// A read transaction may be committed. LMDB ends it exactly as an
// abort would, so a consumer that threads one handle without branching
// on mode is not wrong.
@(test)
test_txn_commit_on_a_read_transaction_is_legal :: proc(t: ^testing.T) {
	s := scratch_store()
	defer close(s)

	tx, err := txn_begin(s, .Read)
	testing.expect(t, err == nil)
	testing.expect_value(t, tx.mode, Txn_Mode.Read)
	testing.expect(t, txn_commit(&tx) == nil)

	// The reader slot is released either way: another one opens.
	tx2, err2 := txn_begin(s, .Read)
	testing.expect(t, err2 == nil)
	txn_abort(&tx2)
}

// The refusal, and the hole it would have had. A second txn_begin is
// the obvious case; bare insert and the loaders each open a write
// transaction of their own, so they are the case that would have
// deadlocked instead of erroring.
@(test)
test_txn_second_writer_is_refused_not_deadlocked :: proc(t: ^testing.T) {
	s := scratch_store()
	defer close(s)

	tx, err := txn_begin(s, .Write)
	testing.expect(t, err == nil)

	_, err2 := txn_begin(s, .Write)
	testing.expect_value(t, err2, Error(Store_Error.Write_Txn_Open))

	_, ierr := insert(s, a_quad(s, 2))
	testing.expect_value(t, ierr, Error(Store_Error.Write_Txn_Open))

	src := `<http://example.org/a> <http://example.org/p> "x" .`
	_, _, lerr := load_triples(s, transmute([]u8)src)
	testing.expect_value(t, lerr, Error(Store_Error.Write_Txn_Open))

	// A reader is not a writer, and is not refused.
	rx, rerr := txn_begin(s, .Read)
	testing.expect(t, rerr == nil)
	txn_abort(&rx)

	// Releasing the claim makes the next writer possible again.
	txn_abort(&tx)
	tx2, err3 := txn_begin(s, .Write)
	testing.expect(t, err3 == nil)
	testing.expect(t, txn_commit(&tx2) == nil)
	added, ierr2 := insert(s, a_quad(s, 2))
	testing.expect(t, ierr2 == nil)
	testing.expect_value(t, added, true)
}

// The invariant with no observable consequence, which is why it gets a
// test written at the moment it is introduced rather than later.
@(test)
test_txn_abort_restores_the_counter_mirror :: proc(t: ^testing.T) {
	s := scratch_store()
	defer close(s)

	// Commit something first, so the counters under test are not zero
	// and a bug cannot pass by coincidence.
	_, err := intern_term(s, rdf.IRI("http://example.org/kept"))
	testing.expect(t, err == nil)
	before := s.next
	testing.expect_value(t, persisted_counters(s), before)

	tx, berr := txn_begin(s, .Write)
	testing.expect(t, berr == nil)
	// Distinct terms, and more than one kind: the mirror is per-kind,
	// so advancing only one counter would not prove the restore covers
	// the array.
	for iri in ([?]string{"http://example.org/g1", "http://example.org/g2", "http://example.org/g3"}) {
		_, ierr := intern_term_txn(tx.s, tx.txn, rdf.IRI(iri))
		testing.expect(t, ierr == nil)
	}
	_, ierr := intern_term_txn(tx.s, tx.txn, rdf.literal("gone", "en"))
	testing.expect(t, ierr == nil)
	testing.expect(t, s.next != before, "interning must advance the mirror, or this test proves nothing")

	txn_abort(&tx)
	testing.expect_value(t, s.next, before)
	testing.expect_value(t, persisted_counters(s), before)
}

// The one path where the drift was reachable before aborts were
// published: a loader hitting a parse error part-way through a
// document it has already interned terms from.
@(test)
test_load_parse_error_restores_the_counter_mirror :: proc(t: ^testing.T) {
	s := scratch_store()
	defer close(s)

	_, err := intern_term(s, rdf.IRI("http://example.org/kept"))
	testing.expect(t, err == nil)
	before := s.next

	src := `<http://example.org/a> <http://example.org/p> "ok" .
<http://example.org/b> <http://example.org/p> "missing dot"`
	added, perr, lerr := load_triples(s, transmute([]u8)src)
	testing.expect(t, lerr == nil)
	testing.expect(t, perr.message != "")
	testing.expect_value(t, added, 0)

	testing.expect_value(t, s.next, before)
	testing.expect_value(t, persisted_counters(s), before)
}

// A committed transaction keeps what it interned, mirror included —
// the other half of the invariant, and the one a too-eager restore
// would break.
@(test)
test_txn_commit_keeps_the_counter_mirror :: proc(t: ^testing.T) {
	s := scratch_store()
	defer close(s)

	before := s.next
	tx, err := txn_begin(s, .Write)
	testing.expect(t, err == nil)
	_, ierr := intern_term_txn(tx.s, tx.txn, rdf.IRI("http://example.org/kept"))
	testing.expect(t, ierr == nil)
	testing.expect(t, txn_commit(&tx) == nil)

	testing.expect(t, s.next != before)
	testing.expect_value(t, persisted_counters(s), s.next)
}

// The mode is checked at runtime, not in the type, so a write on a
// read transaction has to fail cleanly rather than corrupt anything.
@(test)
test_write_on_a_read_transaction_fails_cleanly :: proc(t: ^testing.T) {
	s := scratch_store()
	defer close(s)

	tx, err := txn_begin(s, .Read)
	testing.expect(t, err == nil)
	_, ierr := insert_txn(tx.s, tx.txn, a_quad(s, 1))
	testing.expect(t, ierr != nil)
	txn_abort(&tx)

	// The store is still usable, and the failed write left nothing.
	n, cerr := count(s)
	testing.expect(t, cerr == nil)
	testing.expect_value(t, n, 0)
	added, ierr2 := insert(s, a_quad(s, 1))
	testing.expect(t, ierr2 == nil)
	testing.expect_value(t, added, true)
}
