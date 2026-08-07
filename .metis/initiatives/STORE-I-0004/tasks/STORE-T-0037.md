---
id: match-txn-an-iterator-that-borrows
level: task
title: "match_txn: an iterator that borrows its transaction instead of owning one"
short_code: "STORE-T-0037"
created_at: 2026-08-07T22:15:04+00:00
updated_at: 2026-08-07T23:29:12.283159+00:00
parent: STORE-I-0004
blocked_by: [STORE-T-0034]
archived: false

tags:
  - "#task"
  - "#phase/completed"


exit_criteria_met: false
initiative_id: STORE-I-0004
---

# match_txn: an iterator that borrows its transaction instead of owning one

## Parent Initiative

[[STORE-I-0004]]

## Objective **[REQUIRED]**

The one read path with real design in it, which is why it is not part of STORE-T-0036.

`match` is the only operation whose result outlives the call: `Match_Iterator` **owns** the
read transaction it opened, and `match_destroy` closes both cursor and transaction. Everything
a match yields is a view of that MVCC snapshot, valid until then. That ownership is exactly
what makes a query five independent reads instead of one — STORE-T-0019's whole complaint.

```odin
match_txn :: proc(t: ^Txn, pattern: store.Match_Pattern) -> (it: Match_Iterator, err: Error)
```

`match_txn`'s iterator **borrows**: `match_destroy` closes the cursor and leaves the
transaction alone. Bare `match` keeps owning its own, unchanged.

## Acceptance Criteria **[REQUIRED]**

- [x] `match_txn(t: ^Txn, pattern)` published, serving the pattern from the same index-selection
      logic as bare `match` — this is a change of transaction ownership, **not** a second
      matching implementation.
- [x] **`match_destroy` is one procedure that does the right thing for both.** One iterator
      type, as recommended — but **not a flag**: the iterator carries an `owned: Txn`, which is
      zero for a borrowed transaction, and ending a zeroed handle is already a no-op. So
      `match_destroy` calls `txn_abort(&it.owned)` unconditionally and there is nothing to
      branch on. See the status update.
- [x] **Bare `match` is unchanged** in name, signature, semantics and ownership, and is
      reimplemented as autocommit over `match_txn` — one matching implementation, as in
      STORE-T-0036. Its iterator still owns the transaction it opened, so `match_destroy` still
      closes it, which is what makes the autocommit form work at all despite the result
      outliving the call.
- [x] **Read-your-own-writes through `match_txn`**: an iterator opened on a write transaction
      after an `insert_txn` yields the inserted quad. This is the criterion that makes
      validate-before-commit possible and is the reason the whole initiative exists.
- [x] **Iterator invalidation documented, and deliberately not asserted.** The criterion as
      written asks for both at once and the two pull apart: the contract *forbids* the
      combination rather than defining it, so there is no observable behaviour a test could
      assert without promising one. It is stated on `match_txn`, on `insert_txn`, and in
      `store/interface.odin`; no test exercises a stale iterator. Recorded as a deliberate
      omission rather than a gap — writing that test is how the forbidden combination
      accidentally becomes specified.
- [x] **A borrowed iterator does not close the caller's transaction**: open two iterators on
      one read transaction, destroy one, and the other still yields. The regression this
      guards is the obvious wrong implementation.
- [x] **The snapshot property, end to end**: open a read transaction, `match_txn` it, insert
      through the bare autocommit `insert` (a different transaction), and the iterator's
      results are unchanged. This is STORE-T-0019's acceptance criterion in one test.
- [x] `make test` green at both `Term_ID` widths; `make check` clean.

## Implementation Notes **[CONDITIONAL: Technical Task]**

### Technical Approach

`Match_Iterator` today holds a cursor and a `^lmdb.Txn`. Add the ownership bit; `match_txn`
sets it false and takes `t.txn`; bare `match` opens one and sets it true. `match_destroy`
branches on it. The index selection, the bound-prefix range and the decode path are untouched.

Note the interaction with `NOTLS`, which the environment already sets: read transactions are
not pinned to the opening thread, so a borrowed transaction crossing an iterator's lifetime
does not introduce a thread affinity that was not already absent.

### Dependencies

Blocked by STORE-T-0034. Parallel with STORE-T-0036. Blocks STORE-T-0039.

### Risk Considerations

**The invalidation rule is the conservative reading of LMDB's cursor-fixup behaviour, taken
deliberately.** LMDB may well keep a cursor usable across a write in the same transaction;
STORE-A-0007 forbids the combination anyway, because defining it would mean specifying LMDB's
fixup semantics as contract for a combination no consumer has asked for. Resist the temptation
to test what actually happens and then promise it.

The second risk is the autocommit `match`: it is the one bare form whose result outlives the
call, so "open a transaction, do the operation, close it" is not literally what it does — it
opens a transaction the *iterator* closes. Worth a doc comment saying so, because it is the one
place the autocommit story is not uniform.

## Status Updates **[REQUIRED]**

- **2026-08-07 — Implemented. Eight criteria: seven met, one met differently and one met by
  deliberately not doing half of it. `make test` green at both widths, `make check` clean.**

  **The ownership bit is not a bit.** The task recommended a flag on `Match_Iterator`. What
  landed is a field `owned: Txn` — the transaction itself when the iterator opened one, and
  zero when it borrowed the caller's. Because T-0034 made `txn_abort` of a zeroed handle a
  no-op, `match_destroy` can call `txn_abort(&it.owned)` unconditionally: there is no flag to
  set, no branch to get backwards, and the two cases differ by whether a field was ever filled
  in. It is also the shape that keeps working if an iterator ever needs to own something else.

  **Bare `match` is the one place the autocommit story is not uniform, and the doc comment now
  says so** rather than leaving a reader to notice. Every other bare form opens a transaction,
  does the operation and closes it before returning; `match` cannot, because its result
  outlives the call. It opens the transaction and hands it to the iterator, which ends it at
  `match_destroy`. The important consequence is stated positively: every quad one iterator
  yields is a view of one snapshot, but a *different* snapshot from the next `match`'s — which
  is exactly what `match_txn` exists to fix, and STORE-T-0019's original complaint.

  **The invalidation criterion was met by doing half of it deliberately.** It asked for the
  rule to be "asserted, not just documented", but the contract *forbids* the write-then-read
  combination rather than defining it, so there is no behaviour to assert that would not also
  promise it. The rule is stated in three places (`match_txn`, `insert_txn`,
  `store/interface.odin`) and no test exercises a stale iterator. The task's own Risk
  Considerations predicted this — "resist the temptation to test what actually happens and then
  promise it" — so it is recorded as the omission being the point.

  **Six tests, of which two are the ones that matter.** `test_match_txn_borrows_the_transaction`
  opens two iterators on one read transaction, destroys one, and drains the other — the
  regression the obvious wrong implementation produces. `test_read_txn_is_a_snapshot` is
  STORE-T-0019's acceptance criterion end to end: hold a read transaction, let a whole
  autocommit write land, and `count_txn`, `match_txn` and `find_term_txn` all still see the
  earlier dataset. The dictionary half of that is worth the extra assertion — a query
  resolving its constants against one snapshot must not half-see a later write's terms.