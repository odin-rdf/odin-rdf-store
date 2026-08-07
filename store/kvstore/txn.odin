// Transactions: one handle, two modes (STORE-A-0007).
//
// A read transaction *is* a snapshot. There is no separate Snapshot
// type and no snapshot vocabulary anywhere in this package, because
// LMDB's read transaction is literally the thing a snapshot is, and
// exposing it twice would invent a distinction the storage does not
// have.
//
// This file publishes the handle and its lifecycle. The operations
// that take one arrive with the rest of the initiative (STORE-I-0004);
// until then the bare procedures remain what they have always been,
// and are now *defined* as autocommit — a transaction of the
// appropriate mode, one operation, closed.
package kvstore

import lmdb "../../vendor/lmdb"
import store ".."

// Txn is an open transaction on a Store, and it carries its dataset:
// every transactional procedure takes ^Txn alone, never (s, txn).
//
// It is a caller-held value, exactly as Match_Iterator is, with the
// same hazard: **copying it yields two handles to one transaction**,
// of which the second commit or abort is a use-after-free. Pass it by
// pointer. Committing or aborting zeroes the handle, so a second
// commit or abort of the *same* handle is a no-op rather than a double
// free — but nothing can save a copy.
//
// The fields are this package's business. They are visible because
// Odin structs have no per-field visibility, not because they are
// interface; the property STORE-A-0007 asks for is that a consumer
// never has to *name* an LMDB type, and Match_Iterator sets the same
// precedent.
Txn :: struct {
	s:    ^Store,
	txn:  ^lmdb.Txn,
	mode: store.Txn_Mode,
}

// txn_begin opens a transaction on the store.
//
// **A .Read transaction is a snapshot**: reads through it see one
// dataset for its whole life, and a concurrent commit does not disturb
// it. **Its cost is that it pins pages** — a long-held snapshot makes a
// concurrent writer grow the file, because the pages the reader can
// still see cannot be reused. Holding one for the life of a query is
// fine; holding one for the life of a request handler is a
// storage-sizing decision.
//
// **A .Write transaction is atomic and reads its own writes**, and it
// **holds the environment's writer lock for its lifetime**, serializing
// every other writer against that environment. A validator deciding
// whether a write may join the dataset holds one across the whole
// decision by construction, so these are long by design.
//
// **At most one write transaction may be open on a Store, and a second
// is refused with .Write_Txn_Open rather than blocked.** Within one
// handle a second one can only be a mistake, and LMDB's writer lock
// would otherwise self-deadlock a single-threaded consumer — a deadlock
// is the worst available diagnostic for what the store already knows is
// a programming error. The refusal covers the autocommit procedures
// too: bare insert and the loaders each open a write transaction, so
// they are refused the same way while one is open, rather than
// deadlocking on it.
//
// **Across processes nothing changes.** LMDB's lock serializes writers
// between processes and blocking is correct there; that is the
// concurrency the deployment shape actually uses, and it is untouched.
//
// Transactions do not nest: this takes a ^Store and there is no form
// that takes a ^Txn.
//
// No allocator parameter, for the reason match has none: a Txn owns no
// memory.
txn_begin :: proc(s: ^Store, mode: store.Txn_Mode) -> (t: Txn, err: Error) {
	t.s = s
	t.mode = mode
	switch mode {
	case .Read:
		check(lmdb.txn_begin(s.env, nil, lmdb.RDONLY, &t.txn)) or_return
	case .Write:
		t.txn = write_txn_begin(s) or_return
	}
	return t, nil
}

// txn_commit ends the transaction, making every quad it wrote visible.
// On a .Read transaction this is legal and equivalent to txn_abort, so
// a consumer that does not branch on mode is not wrong.
//
// The handle is spent either way: a failed commit is an abort, because
// LMDB ends the transaction itself before returning the error. Term_IDs
// assigned by interning inside a transaction that did not commit must
// be discarded.
txn_commit :: proc(t: ^Txn) -> (err: Error) {
	if t == nil || t.txn == nil {
		return nil
	}
	if t.mode == .Write {
		err = write_txn_commit(t.s, t.txn)
	} else {
		err = check(lmdb.txn_commit(t.txn))
	}
	t^ = {}
	return err
}

// txn_abort ends the transaction, discarding every quad it wrote. No
// intermediate state was ever observable from outside it, so this
// retracts nothing anyone saw — it is not removal, and there is still
// no way to retract a committed quad.
//
// Term_IDs assigned by interning inside the transaction must be
// discarded. Whether the *terms* remain interned is deliberately
// unspecified: atomicity is defined over quads, not over the
// dictionary. A term interned but never used by a committed quad is
// invisible through the quad contract — find_term may report it, and
// matching it yields nothing, which is the correct answer either way.
txn_abort :: proc(t: ^Txn) {
	if t == nil || t.txn == nil {
		return
	}
	if t.mode == .Write {
		write_txn_abort(t.s, t.txn)
	} else {
		lmdb.txn_abort(t.txn)
	}
	t^ = {}
}

// The environment's one write transaction, claimed and released in one
// place so that every path that opens one — txn_begin(.Write), bare
// insert, the four loaders — refuses a second identically and repairs
// the same invariant on abort.
//
// The invariant is that Store.next, the in-memory mirror of the
// per-kind ID counters, equals what is persisted. Interning advances
// the mirror immediately but writes the counters into meta inside the
// transaction, so an abort rolls the persisted side back and leaves the
// mirror ahead. Nothing observable depends on it today — the reverse
// lookup is a key lookup, not an array index, so the effect is an
// unused gap in the ID space — but an invariant with no observable
// consequence is one nobody notices breaking, and STORE-T-0021 would
// depend on it.

@(private)
write_txn_begin :: proc(s: ^Store) -> (txn: ^lmdb.Txn, err: Error) {
	if s.write_open {
		return nil, .Write_Txn_Open
	}
	check(lmdb.txn_begin(s.env, nil, 0, &txn)) or_return
	s.write_next = s.next
	s.write_open = true
	return txn, nil
}

// write_txn_commit commits and releases the claim. A failed commit is
// an abort — LMDB has already ended the transaction — so the counter
// mirror is rolled back with it.
@(private)
write_txn_commit :: proc(s: ^Store, txn: ^lmdb.Txn) -> Error {
	rc := lmdb.txn_commit(txn)
	if rc != lmdb.SUCCESS {
		s.next = s.write_next
	}
	s.write_open = false
	return check(rc)
}

@(private)
write_txn_abort :: proc(s: ^Store, txn: ^lmdb.Txn) {
	lmdb.txn_abort(txn)
	s.next = s.write_next
	s.write_open = false
}
