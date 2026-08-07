---
id: rewrite-the-transaction-adr
level: task
title: "Rewrite the transaction ADR against a single-backend contract"
short_code: "STORE-T-0032"
created_at: 2026-08-07T16:22:28.000000+00:00
updated_at: 2026-08-07T16:22:28.000000+00:00
parent: STORE-I-0003
blocked_by: ["STORE-T-0030"]
archived: false

tags:
  - "#task"
  - "#phase/todo"


exit_criteria_met: false
initiative_id: STORE-I-0003
---

# Rewrite the transaction ADR against a single-backend contract

## Parent Initiative **[CONDITIONAL: Assigned Task]**

[[STORE-I-0003]]

## Objective **[REQUIRED]**

Write the transaction and snapshot ADR that STORE-A-0005 was going to be, now that the
backend it was contorted around is gone. This is the task that makes the initiative's whole
argument true: the removal was justified on the claim that it simplifies the transaction
model, and this is where that claim is either demonstrated or exposed.

It is the bridge out of this initiative. It is *not* the transaction implementation —
STORE-T-0019 and STORE-T-0022 re-open as their own work once this is decided.

## Acceptance Criteria **[REQUIRED]**

- [ ] A new ADR (new short code) records the transaction model against one backend, and
      **carries forward the findings enumerated in the archived STORE-A-0005's opening
      note**:
      - one `Txn` handle with a `.Read`/`.Write` mode, of which a read-only transaction
        *is* the snapshot — which settles STORE-T-0022's "one handle or two concepts, with
        the reason" criterion;
      - the `_txn` procedure set, the handle carrying its own dataset, and autocommit
        defined as a one-operation transaction so no existing consumer breaks — including
        why the suffix lands on the primary API rather than the convenience one;
      - the guarantees, which stop being a "universal core" and simply become the contract:
        read-your-own-writes, atomicity over quads (not over the dictionary), provisional
        `Term_ID`s discarded on abort, single writer, no nesting, iterator invalidation on
        write;
      - kvstore's publication work: the opaque `Txn` over `^lmdb.Txn` (never exposed), the
        `match_txn` iterator that borrows rather than owns its transaction, and the
        `Store.next` restore-on-abort invariant repair;
      - the scope guard: no multi-writer conflict detection, no isolation levels beyond
        LMDB's, `remove` and `insert_all` out.
- [ ] **Nothing from the archived points 5 and 6 reappears**: no `SNAPSHOT_ISOLATION`
      declaration, no capability-conditional conformance tier, no journal, no generation
      counter, no `.Stale_Txn`, no retained-index copy-on-write.
- [ ] The costs the archived ADR recorded as *backend* detail are restated as **interface**
      detail, per STORE-T-0025's stance: an open read transaction pins pages against a
      concurrent writer; an open write transaction holds the environment writer lock, and
      the validate-before-commit consumer holds one across an entire SHACL validation by
      construction.
- [ ] The conformance suite's transaction assertions are specified as a single uniform
      body — the thing STORE-A-0002 point 3 always claimed the suite was.
- [ ] STORE-T-0019 and STORE-T-0022 updated: unblocked, with the model they now assume.
- [ ] The archived STORE-A-0005 is referenced as superseded-in-substance, so the reasoning
      that produced the surviving findings stays reachable.

## Implementation Notes **[CONDITIONAL: Technical Task]**

### Technical Approach

Read the archived `.metis/archived/adrs/STORE-A-0005.md` opening note first — it was written
at archival time specifically to make this rewrite a carry-forward rather than a
re-derivation, and it enumerates both what to keep and what to leave.

The expected shape is roughly half the archived ADR's length. If it is not substantially
shorter, that is a signal worth investigating: the initiative's central justification was
that memstore was the source of the complexity.

### Dependencies

Blocked by STORE-T-0030 (write it against the code as it is, not as it will be). Parallel
with STORE-T-0031. Unblocks STORE-T-0019 and STORE-T-0022, which re-open as the next
initiative.

### Risk Considerations

The failure mode is writing this from memory rather than from the archived document and
losing a finding that cost real analysis — particularly the two that are easy to forget
because they are small: `match` is the one read path with genuine design in it (its iterator
owns the transaction it opened), and `Store.next` is not rolled back on abort while the
persisted counters are.

The opposite failure is treating the archived ADR as a draft to edit down. It is archived
undecided; the rewrite should be able to stand on its own without the reader knowing it
existed.

## Status Updates **[REQUIRED]**

- **2026-08-07 — Created in STORE-I-0003's decomposition.**
