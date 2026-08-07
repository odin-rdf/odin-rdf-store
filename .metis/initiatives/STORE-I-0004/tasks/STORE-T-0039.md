---
id: conformance-transaction-assertions
level: task
title: "Conformance: transaction assertions as one uniform body, and validate-before-commit demonstrated"
short_code: "STORE-T-0039"
created_at: 2026-08-07T22:15:16.000000+00:00
updated_at: 2026-08-07T22:15:16.000000+00:00
parent: STORE-I-0004
blocked_by: ["STORE-T-0035", "STORE-T-0036", "STORE-T-0037"]
archived: false

tags:
  - "#task"
  - "#phase/todo"


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

- [ ] `conformance.Backend` grows transactional procedure pointers — begin, commit, abort, and
      the `_txn` operations the checks need. **No capability field. No tier. No skip.**
- [ ] The seven checks of STORE-A-0007 point 5, each its own named check procedure in the
      shared suite, each run against kvstore at **both `Term_ID` widths**:
  - read-your-own-writes inside a write transaction;
  - invisibility of those writes to a reader outside it, until commit;
  - a read transaction unchanged across a concurrent commit;
  - abort leaving no quad behind;
  - a second write transaction refused;
  - an iterator invalidated by a write through its own transaction;
  - autocommit behaving as the one-operation transaction it is now defined to be.
- [ ] **Validate-before-commit demonstrated as a test, not described.** Build a candidate
      inside a write transaction, read the dataset it *would* produce through that same
      transaction, and commit or abort on the answer — including the case that matters: a
      constraint that must see **pre-existing** data, which is precisely what the
      isolated-candidate workaround gets wrong by passing vacuously. The store cannot run SHACL,
      so the "validator" here is a match-based predicate over the transaction; what is being
      demonstrated is that the *reads see the right dataset*, which is the whole of the P0 gap.
      **This is the criterion the initiative's P0 stands or falls on.**
- [ ] **The negative that must stay absent**: no assertion covers whether a term interned
      inside an aborted transaction remains interned. Atomicity is defined over quads, not over
      the dictionary, and the suite must not accidentally grow a check that promises otherwise.
      Recorded as a comment in the suite so a later reader does not add one as an oversight.
- [ ] The existing sixteen-pattern, set-semantics, empty-dataset, graph and `find_term` checks
      are untouched and still pass — the transactional body is added beside them, not woven
      through them.
- [ ] `make test` green at both `Term_ID` widths; `make check` clean; CI green on Linux, macOS
      and Windows.

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

*To be added during implementation*
