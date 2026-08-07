package conformance

// The transaction model's executable form (STORE-A-0007, STORE-I-0004).
//
// Seven checks for the seven guarantees, plus the one that is the
// reason the model exists. They are one uniform body with the rest of
// the suite: no capability field, no tier, no skip. A backend either
// passes them or does not implement the interface.
//
// **One thing is deliberately not asserted anywhere below, and it must
// stay that way.** Whether a term interned inside an aborted
// transaction remains interned is *unspecified*: atomicity is defined
// over quads, not over the dictionary. A term interned but never used
// by a committed quad is invisible through the quad contract —
// find_term may report it, and matching it yields nothing, which is the
// right answer either way. A check here that pinned it down would turn
// a deliberate freedom into a requirement, and would force a backend to
// unwind its dictionary on abort for no observable gain. If a later
// reader notices the gap and is tempted to close it: that is the gap.

import "core:strings"
import "core:testing"

import "rdf:rdf"
import "../store"

@(private)
EX :: "http://example.org/"

@(private)
collect_matches_txn :: proc(
	t: ^testing.T,
	b: ^Backend,
	txn: rawptr,
	pattern: store.Match_Pattern,
) -> map[store.Encoded_Quad]struct {} {
	results := make(map[store.Encoded_Quad]struct {})
	it := b.match_begin_txn(txn, pattern)
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

// a_quad builds a distinct ground quad in the default graph, encoded
// through whatever transaction is given so its terms are interned where
// the caller expects.
@(private)
a_quad_txn :: proc(b: ^Backend, txn: rawptr, subject: string) -> store.Encoded_Quad {
	iri := rdf.IRI(strings.concatenate({EX, subject}, context.temp_allocator))
	return b.encode_quad_txn(txn, rdf.Quad{triple = {iri, rdf.IRI(EX + "p"), rdf.IRI(EX + "o")}})
}

// check_txn_read_your_own_writes: a read through an open transaction
// observes that transaction's own uncommitted writes. Without this the
// model buys nothing — every other guarantee is about what other
// readers do *not* see.
check_txn_read_your_own_writes :: proc(t: ^testing.T, b: ^Backend) {
	txn, ok := b.txn_begin(b.ctx, .Write)
	testing.expect(t, ok, "a write transaction must open on an idle dataset")
	defer b.txn_abort(txn)

	q := a_quad_txn(b, txn, "alice")
	testing.expect_value(t, b.insert_txn(txn, q), true)

	testing.expect_value(t, b.count_txn(txn), 1)

	got := collect_matches_txn(t, b, txn, store.MATCH_ALL)
	defer delete(got)
	testing.expect_value(t, len(got), 1)
	_, present := got[q]
	testing.expect(t, present, "a match through the writing transaction must yield its own write")

	// The dictionary half: a term interned inside the transaction is
	// findable through it. A consumer resolving a candidate's constants
	// needs this as much as it needs the quad.
	id, found := b.find_term_txn(txn, rdf.IRI(EX + "alice"))
	testing.expect(t, found, "a term interned in this transaction must be findable through it")
	testing.expect_value(t, id, q[store.QUAD_S])
}

// check_txn_writes_invisible_until_commit: no intermediate state is
// observable from outside the transaction. The reader here is a second
// transaction opened while the write transaction is still open, which
// is the case a consumer actually hits.
check_txn_writes_invisible_until_commit :: proc(t: ^testing.T, b: ^Backend) {
	writer, wok := b.txn_begin(b.ctx, .Write)
	testing.expect(t, wok)

	q := a_quad_txn(b, writer, "alice")
	testing.expect_value(t, b.insert_txn(writer, q), true)

	reader, rok := b.txn_begin(b.ctx, .Read)
	testing.expect(t, rok, "a reader must open while a writer is open")
	testing.expect_value(t, b.count_txn(reader), 0)
	outside := collect_matches_txn(t, b, reader, store.MATCH_ALL)
	testing.expect_value(t, len(outside), 0)
	delete(outside)

	// Autocommit reads are outside too, by definition.
	testing.expect_value(t, b.count(b.ctx), 0)
	b.txn_abort(reader)

	testing.expect(t, b.txn_commit(writer), "commit must succeed")

	// And after the commit, a reader opened fresh sees it.
	after, aok := b.txn_begin(b.ctx, .Read)
	testing.expect(t, aok)
	defer b.txn_abort(after)
	testing.expect_value(t, b.count_txn(after), 1)
	testing.expect_value(t, b.count(b.ctx), 1)
}

// check_txn_snapshot_unchanged_across_commit: a read transaction is a
// stable view. This is the guarantee that makes a query's answer an
// answer about one dataset rather than a smear assembled from two.
check_txn_snapshot_unchanged_across_commit :: proc(t: ^testing.T, b: ^Backend) {
	first := b.encode_quad(b.ctx, rdf.Quad{triple = {rdf.IRI(EX + "a"), rdf.IRI(EX + "p"), rdf.IRI(EX + "o")}})
	testing.expect_value(t, b.insert(b.ctx, first), true)

	snapshot, ok := b.txn_begin(b.ctx, .Read)
	testing.expect(t, ok)
	defer b.txn_abort(snapshot)
	testing.expect_value(t, b.count_txn(snapshot), 1)

	// A whole transaction lands and commits underneath it.
	writer, wok := b.txn_begin(b.ctx, .Write)
	testing.expect(t, wok)
	second := a_quad_txn(b, writer, "b")
	testing.expect_value(t, b.insert_txn(writer, second), true)
	testing.expect(t, b.txn_commit(writer))

	testing.expect_value(t, b.count_txn(snapshot), 1)
	held := collect_matches_txn(t, b, snapshot, store.MATCH_ALL)
	defer delete(held)
	testing.expect_value(t, len(held), 1)
	_, leaked := held[second]
	testing.expect(t, !leaked, "a committed quad must not appear in an older snapshot")

	// The dictionary is part of the view: a query resolving its
	// constants against this snapshot must not half-see the later write.
	_, found := b.find_term_txn(snapshot, rdf.IRI(EX + "b"))
	testing.expect(t, !found, "a term interned after the snapshot began must not be visible in it")

	// Outside the snapshot both are there, so the dataset really did
	// move and the snapshot really is holding still.
	testing.expect_value(t, b.count(b.ctx), 2)
}

// check_txn_abort_leaves_nothing: after abort, none of the
// transaction's quads is visible. Abort is not removal — it retracts
// writes nobody ever saw — so the append-only stance is intact.
check_txn_abort_leaves_nothing :: proc(t: ^testing.T, b: ^Backend) {
	kept := b.encode_quad(b.ctx, rdf.Quad{triple = {rdf.IRI(EX + "kept"), rdf.IRI(EX + "p"), rdf.IRI(EX + "o")}})
	testing.expect_value(t, b.insert(b.ctx, kept), true)

	txn, ok := b.txn_begin(b.ctx, .Write)
	testing.expect(t, ok)
	for subject in ([?]string{"a", "b", "c"}) {
		testing.expect_value(t, b.insert_txn(txn, a_quad_txn(b, txn, subject)), true)
	}
	testing.expect_value(t, b.count_txn(txn), 4)
	b.txn_abort(txn)

	testing.expect_value(t, b.count(b.ctx), 1)
	all := collect_matches_txn2(t, b, store.MATCH_ALL)
	defer delete(all)
	testing.expect_value(t, len(all), 1)
	_, survived := all[kept]
	testing.expect(t, survived, "the committed quad must survive another transaction's abort")
}

// collect_matches_txn2 is collect_matches, spelled through a fresh read
// transaction so the assertion is about committed state rather than
// about whatever an autocommit match happens to see.
@(private)
collect_matches_txn2 :: proc(
	t: ^testing.T,
	b: ^Backend,
	pattern: store.Match_Pattern,
) -> map[store.Encoded_Quad]struct {} {
	txn, ok := b.txn_begin(b.ctx, .Read)
	testing.expect(t, ok)
	defer b.txn_abort(txn)
	return collect_matches_txn(t, b, txn, pattern)
}

// check_txn_single_writer: at most one write transaction on a dataset
// handle, and a second is refused rather than blocked.
//
// This is the one check asserting a behaviour the storage does not
// hand over — a writer lock would block instead — so it is the one
// whose failure most likely means the implementation drifted. A
// deadlock here is itself the failure the check exists to prevent.
//
// **The autocommit corollary is not asserted here, and cannot be.**
// Bare insert is a write transaction, so it is refused the same way
// while one is open — that is where a consumer holding a transaction
// would otherwise deadlock, and it is the more important half. But this
// adapter's write procedures report no error (insert returns only
// whether the quad was new), so a refusal is inexpressible through it.
// Widening every write pointer for one check would be worse than the
// gap; the assertion lives in the backend's own suite instead, where the
// error is in hand — store/kvstore/txn_test.odin.
check_txn_single_writer :: proc(t: ^testing.T, b: ^Backend) {
	first, ok := b.txn_begin(b.ctx, .Write)
	testing.expect(t, ok)

	_, second := b.txn_begin(b.ctx, .Write)
	testing.expect(t, !second, "a second write transaction must be refused, not granted")

	// A reader is not a writer and is not refused: the restriction is
	// on writers only, and a validator reading beside a writer is the
	// normal case.
	reader, rok := b.txn_begin(b.ctx, .Read)
	testing.expect(t, rok, "a read transaction must open while a write transaction is open")
	b.txn_abort(reader)

	b.txn_abort(first)

	// Once released, the next writer is granted. The quad is encoded
	// *here* rather than in the aborted transaction: IDs assigned by
	// interning inside a transaction that did not commit are
	// provisional, and reusing them is what the contract tells a
	// consumer not to do.
	third, tok := b.txn_begin(b.ctx, .Write)
	testing.expect(t, tok, "the claim must be released by abort")
	testing.expect_value(t, b.insert_txn(third, a_quad_txn(b, third, "alice")), true)
	testing.expect(t, b.txn_commit(third))
	testing.expect_value(t, b.count(b.ctx), 1)
}

// check_txn_iterator_lifetime: what an iterator on a transaction is
// good for, and what the escape hatch is.
//
// **The forbidden combination is not exercised, on purpose.** An
// iterator is valid until match_destroy, a write through its own
// transaction, or that transaction's end — and the contract *forbids*
// using one past a write rather than defining what it would yield. A
// check that read a stale iterator would promise whatever the
// implementation happened to do. What is asserted instead is the part
// that is defined, and the part a consumer actually needs: iterating
// before the write is fine, and re-opening after it sees the write.
check_txn_iterator_lifetime :: proc(t: ^testing.T, b: ^Backend) {
	txn, ok := b.txn_begin(b.ctx, .Write)
	testing.expect(t, ok)
	defer b.txn_abort(txn)

	first := a_quad_txn(b, txn, "a")
	testing.expect_value(t, b.insert_txn(txn, first), true)

	// Opened and fully consumed before the next write: defined, and the
	// ordinary read-your-own-writes case.
	before := collect_matches_txn(t, b, txn, store.MATCH_ALL)
	testing.expect_value(t, len(before), 1)
	delete(before)

	second := a_quad_txn(b, txn, "b")
	testing.expect_value(t, b.insert_txn(txn, second), true)

	// Re-opened after the write: the prescribed remedy, and it sees
	// both.
	after := collect_matches_txn(t, b, txn, store.MATCH_ALL)
	defer delete(after)
	testing.expect_value(t, len(after), 2)
	_, has_second := after[second]
	testing.expect(t, has_second, "an iterator opened after a write must see it")

	// Several iterators may be open on one transaction at once, and
	// destroying one must not end the transaction its siblings read
	// through.
	a := b.match_begin_txn(txn, store.MATCH_ALL)
	c := b.match_begin_txn(txn, store.MATCH_ALL)
	b.match_destroy(a)
	n := 0
	for {
		_, more := b.match_next(c)
		if !more {
			break
		}
		n += 1
	}
	b.match_destroy(c)
	testing.expect_value(t, n, 2)
	testing.expect_value(t, b.count_txn(txn), 2)
}

// check_txn_autocommit: the bare procedures are one-operation
// transactions, which is now a definition rather than a description of
// how they happen to work.
//
// The half worth asserting is the negative one: what autocommit does
// *not* give you is any relationship between two operations. Two
// matches are two snapshots.
check_txn_autocommit :: proc(t: ^testing.T, b: ^Backend) {
	first := b.encode_quad(b.ctx, rdf.Quad{triple = {rdf.IRI(EX + "a"), rdf.IRI(EX + "p"), rdf.IRI(EX + "o")}})
	testing.expect_value(t, b.insert(b.ctx, first), true)

	// A bare insert committed: a transaction opened afterwards sees it,
	// which is what "closed it" means from outside.
	txn, ok := b.txn_begin(b.ctx, .Read)
	testing.expect(t, ok)
	testing.expect_value(t, b.count_txn(txn), 1)

	// Two autocommit reads straddling a write disagree, because they are
	// two transactions. A held read transaction straddling the same
	// write does not.
	before_bare := b.count(b.ctx)
	second := b.encode_quad(b.ctx, rdf.Quad{triple = {rdf.IRI(EX + "b"), rdf.IRI(EX + "p"), rdf.IRI(EX + "o")}})
	testing.expect_value(t, b.insert(b.ctx, second), true)
	after_bare := b.count(b.ctx)
	testing.expect_value(t, before_bare, 1)
	testing.expect_value(t, after_bare, 2)
	testing.expect_value(t, b.count_txn(txn), 1)
	b.txn_abort(txn)

	// And a bare insert is still set-semantic: the transaction it opens
	// changes nothing about what the operation means.
	testing.expect_value(t, b.insert(b.ctx, first), false)
	testing.expect_value(t, b.count(b.ctx), 2)
}

// check_validate_before_commit is the reason the model exists, and it
// is asserted rather than described.
//
// The pattern: accept a description of a resource, decide whether it
// may join the dataset by examining *the dataset it would produce*, and
// keep it only if the answer is yes. The store cannot run SHACL, so the
// validator here is a match-based predicate — what is being
// demonstrated is not the validator but that its reads see the right
// dataset.
//
// The constraint is a uniqueness one, chosen because it is exactly the
// shape that the isolated-candidate workaround gets wrong: **no two
// resources may share an email.** A candidate holding one email is
// unique *within itself* no matter what, so a validator that can only
// see the candidate passes it vacuously — approving a duplicate. Only a
// validator that can see the existing dataset *and* the candidate
// together can answer at all, and that is precisely what a write
// transaction with read-your-own-writes provides.
check_validate_before_commit :: proc(t: ^testing.T, b: ^Backend) {
	email := rdf.IRI(EX + "email")
	taken := rdf.literal("a@example.org")
	free := rdf.literal("d@example.org")

	// Pre-existing, committed data: alice already holds the address.
	existing := b.encode_quad(b.ctx, rdf.Quad{triple = {rdf.IRI(EX + "alice"), email, taken}})
	testing.expect_value(t, b.insert(b.ctx, existing), true)

	// unique_in reports how many quads in the transaction's view give
	// this email to anyone. The predicate is "exactly one" — the
	// candidate's own.
	holders :: proc(t: ^testing.T, b: ^Backend, txn: rawptr, email, value: rdf.Term) -> int {
		p, p_found := b.find_term_txn(txn, email)
		v, v_found := b.find_term_txn(txn, value)
		if !p_found || !v_found {
			return 0
		}
		got := collect_matches_txn(t, b, txn, store.Match_Pattern{store.WILDCARD, p, v, store.WILDCARD})
		defer delete(got)
		return len(got)
	}

	// Candidate 1: a free address. Valid, and committed.
	{
		txn, ok := b.txn_begin(b.ctx, .Write)
		testing.expect(t, ok)
		candidate := b.encode_quad_txn(txn, rdf.Quad{triple = {rdf.IRI(EX + "dave"), email, free}})
		testing.expect_value(t, b.insert_txn(txn, candidate), true)

		n := holders(t, b, txn, email, free)
		testing.expect_value(t, n, 1)
		if n == 1 {
			testing.expect(t, b.txn_commit(txn), "a conforming candidate commits")
		} else {
			b.txn_abort(txn)
		}
	}
	testing.expect_value(t, b.count(b.ctx), 2)

	// Candidate 2: the address alice already holds. Invalid — and
	// invalid *only* because the validator can see alice's quad, which
	// is the whole point.
	{
		txn, ok := b.txn_begin(b.ctx, .Write)
		testing.expect(t, ok)
		candidate := b.encode_quad_txn(txn, rdf.Quad{triple = {rdf.IRI(EX + "erin"), email, taken}})
		testing.expect_value(t, b.insert_txn(txn, candidate), true)

		// Two holders: the pre-existing one and the candidate. A
		// validator that could see only the candidate would count 1 and
		// approve — that is the vacuous pass the isolated-candidate
		// workaround produces, and the two numbers differing is the
		// demonstration that pre-existing data was read.
		n := holders(t, b, txn, email, taken)
		testing.expect_value(t, n, 2)

		candidate_only := collect_matches_txn(t, b, txn, store.Match_Pattern{candidate[store.QUAD_S], store.WILDCARD, store.WILDCARD, store.WILDCARD})
		defer delete(candidate_only)
		testing.expect_value(t, len(candidate_only), 1)

		if n == 1 {
			testing.expect(t, b.txn_commit(txn), "unreachable: the candidate conflicts")
		} else {
			b.txn_abort(txn)
		}
	}

	// The rejected candidate left nothing, and the approved one stayed.
	testing.expect_value(t, b.count(b.ctx), 2)
	final := collect_matches_txn2(t, b, store.MATCH_ALL)
	defer delete(final)
	testing.expect_value(t, len(final), 2)

	erin, erin_known := b.find_term(b.ctx, rdf.IRI(EX + "erin"))
	if erin_known {
		// The dictionary may or may not remember a term from an aborted
		// transaction — deliberately unspecified. What is specified is
		// that no quad of it survives.
		rejected := collect_matches_txn2(t, b, store.Match_Pattern{erin, store.WILDCARD, store.WILDCARD, store.WILDCARD})
		defer delete(rejected)
		testing.expect_value(t, len(rejected), 0)
	}
}
