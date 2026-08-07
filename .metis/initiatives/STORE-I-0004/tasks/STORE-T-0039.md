---
id: conformance-transaction-assertions
level: task
title: "Conformance: transaction assertions as one uniform body, and validate-before-commit demonstrated"
short_code: "STORE-T-0039"
created_at: 2026-08-07T22:15:16+00:00
updated_at: 2026-08-07T23:48:16.218422+00:00
parent: STORE-I-0004
blocked_by: [STORE-T-0035, STORE-T-0036, STORE-T-0037]
archived: false

tags:
  - "#task"
  - "#phase/completed"


exit_criteria_met: false
initiative_id: STORE-I-0004
---

# Conformance: transaction assertions as one uniform body, and validate-before-commit demonstrated

## Parent Initiative

[[STORE-I-0004]]

## Objective **[REQUIRED]**

Make the transaction model executable. The `conformance` package is the executable form of the
match interface contract; a contract clause with no assertion is a comment.

**The shape of this task is its point.** The `conformance.Backend` adapter grows the
transactional procedure pointers **and nothing else**: no capability field, no tier selection,
no skip list. A backend either passes these assertions or does not implement the interface.
That is what STORE-A-0002 point 3 always claimed the suite was, and what it would stop being
the moment the contract carried a capability the suite had to branch on. The archived
STORE-A-0005 would have made the suite conditional forever; STORE-I-0003 removed the reason.

## Acceptance Criteria **[REQUIRED]**

- [x] `conformance.Backend` grows transactional procedure pointers — begin, commit, abort, and
      the `_txn` operations the checks need. **No capability field. No tier. No skip.**
- [x] The seven checks of STORE-A-0007 point 5, each its own named check procedure in the
      shared suite, each run against kvstore at **both `Term_ID` widths**. Two are narrower
      than the list below and the status update says why — the iterator one, and the
      single-writer one:
  - read-your-own-writes inside a write transaction;
  - invisibility of those writes to a reader outside it, until commit;
  - a read transaction unchanged across a concurrent commit;
  - abort leaving no quad behind;
  - a second write transaction refused;
  - an iterator invalidated by a write through its own transaction;
  - autocommit behaving as the one-operation transaction it is now defined to be.
- [x] **Validate-before-commit demonstrated as a test, not described.** Build a candidate
      inside a write transaction, read the dataset it *would* produce through that same
      transaction, and commit or abort on the answer — including the case that matters: a
      constraint that must see **pre-existing** data, which is precisely what the
      isolated-candidate workaround gets wrong by passing vacuously. The store cannot run SHACL,
      so the "validator" here is a match-based predicate over the transaction; what is being
      demonstrated is that the *reads see the right dataset*, which is the whole of the P0 gap.
      **This is the criterion the initiative's P0 stands or falls on.**
- [x] **The negative that must stay absent**: no assertion covers whether a term interned
      inside an aborted transaction remains interned. Atomicity is defined over quads, not over
      the dictionary, and the suite must not accidentally grow a check that promises otherwise.
      Recorded as a comment in the suite so a later reader does not add one as an oversight.
- [x] The existing sixteen-pattern, set-semantics, empty-dataset, graph and `find_term` checks
      are untouched and still pass — the transactional body is added beside them, not woven
      through them.
- [x] `make test` green at both `Term_ID` widths (56 → 64 in `store/kvstore`); `make check`
      clean. **CI unverified** — nothing in this initiative has been pushed; the repo is four
      commits ahead of `origin/main`. Carried to STORE-T-0040, which has the same criterion.

## Implementation Notes **[CONDITIONAL: Technical Task]**

### Technical Approach

`conformance/` holds the harness; `store/kvstore/conformance_test.odin` holds the adapter and
the `@(test)` wrappers. The adapter is already a struct of procedure pointers over a `ctx:
rawptr`, so growing it is additive. Note the adapter now runs over an **ephemeral** store
(STORE-T-0033), which is convenient here: a test that aborts a transaction leaves nothing
behind in a store that itself leaves nothing behind.

The "reader outside the write transaction" and "read transaction unchanged across a concurrent
commit" checks need two live transactions on one store at once. Both are legal — LMDB's single
writer restriction is on *writers* — and `NOTLS` means neither is pinned to a thread. No
threads are needed: two handles in one test procedure is enough, and is more deterministic.

### Dependencies

Blocked by STORE-T-0035 (the contract it asserts), STORE-T-0036 (the `_txn` set) and
STORE-T-0037 (`match_txn`, without which the iterator and snapshot checks cannot be written).
Not blocked by STORE-T-0038.

### Risk Considerations

The temptation is to write the assertions against what kvstore does rather than against what
`interface.odin` says — which is why this task is blocked on the contract rather than
sequenced beside it. If a check is easier to write by reaching past the `Backend` adapter into
kvstore, that is a signal the adapter is missing a pointer, not a licence.

The single-writer-refusal check asserts a behaviour LMDB does not hand over (STORE-A-0007
chose refusal over blocking), so it is the one check whose failure would most likely mean the
*implementation* drifted rather than the storage.

## Status Updates **[REQUIRED]**

- **2026-08-07 — Implemented. Six criteria met, one met narrower than written, one carried.
  `make test` green at both widths, `store/kvstore` 56 → 64; `make check` clean.**

  **The P0 check has teeth, and that was verified rather than assumed.** `check_validate_before_commit`
  uses a *uniqueness* constraint — no two resources may share an email — because that is
  exactly the shape the isolated-candidate workaround gets wrong: a candidate holding one
  email is unique within itself no matter what, so a validator that can only see the candidate
  approves a duplicate. Pre-existing committed data gives alice the address; candidate 1 takes
  a free address and commits; candidate 2 takes alice's and is aborted, and it is invalid
  *only* because the validator can see alice's quad through the same transaction that holds
  the candidate.

  To confirm the check would actually catch a regression, `holders` was temporarily mutated to
  read through its own fresh transaction — the pre-transaction world. The result is the
  documented failure mode, exactly: the validator counts 1 instead of 2, **approves the
  duplicate**, and the conflicting quad ends up committed in the store. Four assertions fire.
  The mutation was reverted; it is recorded here because "this test would fail if the property
  broke" is otherwise a claim rather than a finding.

  **Two checks are narrower than STORE-A-0007 point 5's list, both deliberately.**

  *The iterator one.* Point 5 says "an iterator invalidated by a write through its own
  transaction". The contract **forbids** that combination rather than defining it, so a check
  that read a stale iterator would promise whatever the implementation happened to do — the
  trap STORE-T-0037 already declined. `check_txn_iterator_lifetime` asserts the parts that
  *are* defined and that a consumer actually needs: iterating before the write, and re-opening
  after it to see the write. It also asserts that destroying one iterator does not end the
  transaction its siblings read through, which is the borrowing property from T-0037 promoted
  into the shared suite where it belongs.

  *The single-writer one.* The refusal of a second `txn_begin(.Write)` is asserted, as is a
  reader opening beside a writer and the claim being released on abort. **The autocommit
  corollary is not, and cannot be through this adapter**: bare `insert` is a write transaction
  and is refused the same way — the more important half, since that is where a consumer
  holding a transaction would otherwise deadlock — but the adapter's write procedures report
  no error, only whether the quad was new. Widening every write pointer for one check is worse
  than the gap. The assertion lives in `store/kvstore/txn_test.odin`, where the error is in
  hand, and both the check's doc comment and the adapter's say so.

  **One bug in a check, caught by reading the contract rather than by the compiler.** The
  first draft of `check_txn_single_writer` encoded a quad inside the transaction it then
  aborted, and reused those `Term_ID`s in the next transaction — which is precisely what
  "provisional IDs, discard them on abort" forbids. The check would have been asserting
  something the contract calls invalid, and it would have passed, because LMDB's dictionary
  happens to survive. Encoding moved into the surviving transaction.

  **The negative is a comment at the top of the file, not an absence.** Nothing asserts
  whether a term interned inside an aborted transaction stays interned, and the file says why
  in the place a reader tempted to "fill the gap" would be looking.

  `check_validate_before_commit`'s last assertion is careful about the same freedom: it looks
  up `erin` and, *if* the dictionary remembers her, asserts only that no quad of hers survives.
  It does not require that she be forgotten, and it does not require that she be remembered.