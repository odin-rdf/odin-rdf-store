---
id: match-txn-an-iterator-that-borrows
level: task
title: "match_txn: an iterator that borrows its transaction instead of owning one"
short_code: "STORE-T-0037"
created_at: 2026-08-07T22:15:04.000000+00:00
updated_at: 2026-08-07T22:15:04.000000+00:00
parent: STORE-I-0004
blocked_by: ["STORE-T-0034"]
archived: false

tags:
  - "#task"
  - "#phase/todo"


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

- [ ] `match_txn(t: ^Txn, pattern)` published, serving the pattern from the same index-selection
      logic as bare `match` — this is a change of transaction ownership, **not** a second
      matching implementation.
- [ ] **`match_destroy` is one procedure that does the right thing for both.** An iterator
      knows whether it owns its transaction and closes it only if it does. Recommend a flag on
      the existing `Match_Iterator` rather than a second iterator type: the alternative puts a
      second type into every consumer's source for a one-bit difference.
- [ ] **Bare `match` is unchanged** in name, signature, semantics and ownership, and is
      reimplemented as autocommit over `match_txn` — one matching implementation, as in
      STORE-T-0036. Its iterator still owns the transaction it opened, so `match_destroy` still
      closes it, which is what makes the autocommit form work at all despite the result
      outliving the call.
- [ ] **Read-your-own-writes through `match_txn`**: an iterator opened on a write transaction
      after an `insert_txn` yields the inserted quad. This is the criterion that makes
      validate-before-commit possible and is the reason the whole initiative exists.
- [ ] **Iterator invalidation asserted, not just documented**: an iterator open on a transaction
      is invalidated by a write through *that same transaction*, and by that transaction's
      commit or abort. The combination is **forbidden explicitly** rather than defined — no
      test asserts what a stale iterator yields, only that the contract forbids using it.
- [ ] **A borrowed iterator does not close the caller's transaction**: open two iterators on
      one read transaction, destroy one, and the other still yields. The regression this
      guards is the obvious wrong implementation.
- [ ] **The snapshot property, end to end**: open a read transaction, `match_txn` it, insert
      through the bare autocommit `insert` (a different transaction), and the iterator's
      results are unchanged. This is STORE-T-0019's acceptance criterion in one test.
- [ ] `make test` green at both `Term_ID` widths; `make check` clean.

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

*To be added during implementation*
