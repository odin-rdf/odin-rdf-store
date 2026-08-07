---
id: documentation-sweep-vision-update
level: task
title: "Documentation sweep, vision update, and the release decision"
short_code: "STORE-T-0040"
created_at: 2026-08-07T22:15:22+00:00
updated_at: 2026-08-07T23:53:51.080782+00:00
parent: STORE-I-0004
blocked_by: [STORE-T-0039]
archived: false

tags:
  - "#task"
  - "#phase/completed"


exit_criteria_met: false
initiative_id: STORE-I-0004
---

# Documentation sweep, vision update, and the release decision

## Parent Initiative

[[STORE-I-0004]]

## Objective **[REQUIRED]**

Close the initiative: describe the transaction model everywhere a reader will look for it,
bring the vision's Current State back in line with what is delivered, and decide the release.

The two input items are already archived — that happened at decomposition, on purpose, so
their acceptance criteria could be transcribed into the Exit Criteria rather than buried
mid-transcription. Nothing is left to do for them here beyond not contradicting them.

## Acceptance Criteria **[REQUIRED]**

- [x] **`README.md`** gains a transactions section: the handle, the two modes, the guarantees,
      and — the part a README is uniquely good at — the **validate-before-commit example**,
      which is the reason the feature exists. It is compile-verified in `tests/readme` like
      everything else there.
- [x] The README's existing claim that `match` "opens a read transaction owned by the iterator
      and released by `match_destroy`" is reconciled with `match_txn`'s borrowing iterator
      rather than left to contradict it.
- [x] **The two costs appear in the README**, not only in `interface.odin`: a long read
      transaction pins pages and grows the file against a concurrent writer; a long write
      transaction serializes every other writer against that environment. A consumer who reads
      only the README should not discover either in production.
- [x] **`CHANGELOG.md`** entry leading on what the release *adds*, and stating the one small
      thing it breaks rather than claiming it breaks nothing. Every *bare* procedure keeps its
      name, signature and semantics. But `intern_term_txn` and `find_term_txn` were already
      public with `^lmdb.Txn` in their signatures — public by omission, `find_term_txn` since
      STORE-T-0014 — and both are re-signed to take `^Txn` (STORE-T-0036). No consumer anywhere
      in the family uses either, so the reach is nil, but a changed public signature is a
      changed public signature and the entry should say so.
- [x] **`store/kvstore`'s package doc comment** is updated: it currently describes the
      transaction behaviour as an implementation note ("insert commits its own write
      transaction; match opens a read transaction owned by the iterator"). That is now the
      autocommit *definition* and there is a published alternative.
- [x] **A release decision, taken and recorded: 0.3.0**, and the convention decides it rather
      than taste. This criterion assumed the release was purely additive; it is not quite.
      `intern_term_txn` and `find_term_txn` change signature (STORE-T-0036), and the CHANGELOG
      header says "while the major version is 0, a **minor** bump is where breaking changes
      land". Two changed public signatures are a breaking change however small their reach, so
      0.3.0 follows from the rule already written down. **Tagging waits for CI**, per
      STORE-I-0003's precedent of tagging the commit CI verified — see the criterion below.
- [x] **`.metis/vision.md` updated.** Its Current State lists "seven backlog items" including
      snapshot reads; two of them are now delivered, and its "Outstanding work is growth, not
      debt" paragraph needs to say so. STORE-I-0001's "concurrency guarantees beyond
      single-threaded use" non-goal is **narrowed, not reversed**, and the vision should record
      which.
- [x] **STORE-T-0019 and STORE-T-0022 need nothing here** — they were archived as superseded at
      decomposition on 2026-08-07, each with a final status update tracing where every
      acceptance criterion went. Listed so a reader of this task does not go looking: the only
      thing to check is that nothing written during implementation contradicts those two
      accounts, and if it does, that the contradiction is recorded in *this* initiative rather
      than by editing an archived item.
- [x] **STORE-A-0007's Review Schedule is checked against what was actually built** and any
      trigger that fired during implementation is recorded there. In particular: whether a
      consumer wanted two simultaneous read views, and whether `mdb_txn_reset`/`renew` came up.
- [x] **STORE-A-0007 point 4's one factual drift is settled** — amend or leave, with the
      reason. It says "`Txn` snapshots `next` at begin and restores it on abort"; STORE-T-0034
      put the snapshot on the `Store` instead, because routing bare `insert` and the loaders
      through the same single-writer claim left them with no `Txn` to hang one on — and the
      loader-abort path is the one place the ADR itself says the drift is reachable. The
      *guarantee* is unchanged and strictly wider; only the mechanism moved. A decided ADR
      being slightly wrong about a mechanism is small, but it should be a decision rather than
      an oversight.
- [ ] CI green on Linux, macOS and Windows at both `Term_ID` widths, with test counts recorded
      before and after. **Open, and it is the one thing here that cannot be done by writing:
      nothing in this initiative has been pushed.** Counts to record when it runs: store 5,
      store/kvstore 44 → 64, tests/readme 2 → 4; total per width **51 → 73**.

## Implementation Notes **[CONDITIONAL: Technical Task]**

### Technical Approach

Documentation and Metis bookkeeping. The one piece with judgement in it is the README example:
validate-before-commit is the initiative's reason for existing, and a README that describes
the handle without showing that pattern has documented the mechanism and hidden the point.

### Dependencies

Blocked by STORE-T-0039. STORE-T-0038 (loaders) may or may not exist by then — if it does, the
README example should use `load_turtle_txn`, which is the shape the driving consumer actually
has; if it was dropped, the example builds its candidate with `insert_txn` and should say why.

### Risk Considerations

The failure mode is a documentation sweep that describes the API and not the trade-off.
STORE-I-0003 left two sibling README lines stale for days because they were summary lines
nobody re-read; grep for "read transaction", "snapshot" and "atomic" across the repo rather
than editing only the files that obviously changed.

## Status Updates **[REQUIRED]**

- **2026-08-07 — Done except the one criterion that needs a push. Nine of ten met;
  `make test` green at both widths (51 → 73 per width), `make check` clean.**

  **The release decision turned out not to be a judgement call.** This task assumed the
  release was purely additive and that a minor bump was arguable. It is not quite additive —
  `intern_term_txn` and `find_term_txn` changed signature — and the CHANGELOG's own header
  already decides what that means: "while the major version is 0, a **minor** bump is where
  breaking changes land." So **0.3.0**, by the rule rather than by taste. Tagging waits for
  CI, following STORE-I-0003's practice of tagging the commit CI actually verified.

  **STORE-A-0007 is amended rather than left**, with a dated block after its Decision. The
  criterion asked about one drift; there were four, and the amendment names all of them: the
  counter snapshot on the `Store` rather than the `Txn` (and *why* it had to move — the
  autocommit paths have no `Txn`, and they are where the deadlock would have been); no
  allocator on `txn_begin`; `Txn_Mode` in the `store` package; and point 2's "every existing
  form survives unchanged" having two exceptions. It also records that point 5's iterator
  check contradicted point 3, and that point 3 wins. The decision itself stands in full — what
  is amended is what the document claims about mechanism.

  **The review triggers were checked and none fired**, but one is worth the sentence: two
  simultaneous read views were *exercised* — the suite opens a reader beside a writer, and
  several iterators on one transaction — and the caller-held-value handle took it without
  strain. No consumer has asked for it, so the trigger stands unfired rather than answered,
  which is a different thing from untested.

  **The vision got a correction, not just a checkbox.** Its Current State called all seven
  backlog items "growth, not debt". STORE-T-0022 was debt: a P0 correctness gap, filed as a
  backlog feature, where the only workaround the interface admitted was a validator that
  passes vacuously. The amendment says so, and a success criterion was added for the thing the
  library could not previously express — which is where it should have been all along.

  **The README grew a Transactions section built around the pattern rather than the API.**
  The risk this task named was "a documentation sweep that describes the API and not the
  trade-off", so the section leads with what autocommit does *not* give you — no relationship
  between two operations, no *between* — then the handle, then validate-before-commit as a
  worked example, then the two costs. Both new examples are compile-verified in `tests/readme`
  (2 → 4 tests), and the validate-before-commit one implements the uniqueness predicate for
  real, so the README's claim that the isolated-candidate workaround passes vacuously is
  backed by code a reader can run.

  Also swept: the loaders paragraph now carries the `_txn` atomicity inversion, the quick
  start's `match` sentence points at the new section instead of contradicting it,
  `store/kvstore`'s package doc describes autocommit as a definition with a published
  alternative, and the Packages note now says what retiring memstore bought — guarantees
  instead of declared capabilities — rather than only what it cost.