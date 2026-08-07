---
id: rewrite-the-transaction-adr
level: task
title: "Rewrite the transaction ADR against a single-backend contract"
short_code: "STORE-T-0032"
created_at: 2026-08-07T16:22:28+00:00
updated_at: 2026-08-07T20:43:55.683599+00:00
parent: STORE-I-0003
blocked_by: [STORE-T-0030]
archived: false

tags:
  - "#task"
  - "#phase/completed"


exit_criteria_met: true
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

## Acceptance Criteria

## Acceptance Criteria

## Acceptance Criteria **[REQUIRED]**

- [x] A new ADR (new short code) records the transaction model against one backend, and
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
- [x] **Nothing from the archived points 5 and 6 reappears**: no `SNAPSHOT_ISOLATION`
      declaration, no capability-conditional conformance tier, no journal, no generation
      counter, no `.Stale_Txn`, no retained-index copy-on-write.
- [x] The costs the archived ADR recorded as *backend* detail are restated as **interface**
      detail, per STORE-T-0025's stance: an open read transaction pins pages against a
      concurrent writer; an open write transaction holds the environment writer lock, and
      the validate-before-commit consumer holds one across an entire SHACL validation by
      construction.
- [x] The conformance suite's transaction assertions are specified as a single uniform
      body — the thing STORE-A-0002 point 3 always claimed the suite was.
- [x] STORE-T-0019 and STORE-T-0022 updated: unblocked, with the model they now assume.
- [x] The archived STORE-A-0005 is referenced as superseded-in-substance, so the reasoning
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
- **2026-08-07 — Written as STORE-A-0007, "Transactions and snapshots: one handle, two
  modes".** Every finding the archived STORE-A-0005's opening note enumerated is carried
  forward: the one `Txn` handle with a `.Read`/`.Write` mode of which a read transaction *is*
  the snapshot; the `_txn` procedure set with the handle carrying its own dataset and
  autocommit defined as a one-operation transaction, including why the suffix lands on the
  primary API; the guarantees, now stated flat rather than as a universal core; kvstore's
  publication work — the opaque `Txn` over `^lmdb.Txn`, `match_txn` borrowing rather than
  owning its transaction, and the `Store.next` restore-on-abort invariant repair; and the
  scope guard. Nothing from points 5 and 6 reappears: no `SNAPSHOT_ISOLATION`, no conditional
  tier, no journal, no generation counter, no `.Stale_Txn`, no retained-index copy-on-write —
  the only mentions of those names are in the passages that record them as dead. The two costs
  are restated as **interface** detail per STORE-T-0025's stance, and the conformance
  assertions are specified as one uniform body with a concrete check list. STORE-T-0019 and
  STORE-T-0022 are unblocked with the model they now assume, and the archived ADR points
  forward.

  **One decision the archived document did not have to make**, surfaced by writing this
  against one backend: opening a second write transaction on one handle. A-0005 left it
  per-backend (kvstore deadlocks on LMDB's writer lock, memstore reported `.Txn_Conflict`).
  With one backend that is no longer a difference to describe but a behaviour to choose, and
  A-0007 chooses to refuse it with an error — a self-deadlock is the worst diagnostic
  available for what can only be a programming error. Cross-process blocking is untouched and
  correct.

- **2026-08-07 — The length signal fired, and the investigation changes the premise slightly
  rather than confirming it.** The task predicted roughly half the archived ADR's length and
  said a miss was worth examining. Measured on the ADR proper (excluding A-0005's archival
  note): **4,017 words → 3,200, about 80%**, after cutting the genuine redundancy of
  explaining the archived document in three separate places.

  The premise holds where it matters and the estimate that framed it does not. Every
  *mechanism* memstore forced is gone, verified absent. But the archival note's claim that
  "more than half this text is about a backend that will not exist" was an overestimate:
  measured, the wholesale-deleted blocks — the declared-capability block in point 3, all of
  points 5 and 6, and Context's "memstore is where the decision lives" — come to 866 words,
  and with the memstore-attributable Rationale bullets, two Alternatives rows, the
  Consequences bullets and two Review triggers it reaches roughly 1,500 of 4,017, near 37%.

  The remainder of the gap is real and runs the other way: **the single-backend stance
  transfers cost from the backend to the contract.** Three passages had to grow, all three
  because of STORE-A-0006 rather than in spite of it — page pinning and the writer lock move
  from notes about kvstore to specified consequences of the interface, with no portable subset
  left to hide behind; snapshot isolation moves from a branch each backend could declare its
  own way into a guarantee binding on any future backend, which takes more care to state than
  a branch does; and the second-write-transaction question above became a decision instead of
  a description. The initiative's justification — that memstore was the source of the
  transaction model's complexity — stands. What does not stand is the arithmetic that
  complexity removed would show up as text removed one for one.