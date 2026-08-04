---
id: lmdb-benchmarks-lifetime-contract
level: task
title: "LMDB benchmarks, lifetime-contract docs, and initiative close-out"
short_code: "STORE-T-0012"
created_at: 2026-08-04T21:11:42.379875+00:00
updated_at: 2026-08-04T21:44:27.447143+00:00
parent: STORE-I-0002
blocked_by: [STORE-T-0011]
archived: false

tags:
  - "#task"
  - "#phase/completed"


exit_criteria_met: false
initiative_id: STORE-I-0002
---

# LMDB benchmarks, lifetime-contract docs, and initiative close-out

## Parent Initiative **[CONDITIONAL: Assigned Task]**

[[STORE-I-0002]]

## Objective **[REQUIRED]**

Close out the initiative: extend the benchmark harness with LMDB numbers alongside the in-memory baselines, document the backend's lifetime and transaction contract at the family's standard, and verify every exit criterion.

## Acceptance Criteria

## Acceptance Criteria

## Acceptance Criteria **[REQUIRED]**

- [x] `bench/` extended with LMDB runs over the same corpora: bulk load (statements/second including commit, in both durable and `no_sync` configurations), a match-scan benchmark (full-scan and bound-prefix range throughput) against both backends, and disk bytes/statement (environment file size / statements).
- [x] Baselines recorded in STORE-I-0002's Status Updates next to the in-memory numbers from STORE-I-0001, with the measurement environment noted; the intern verification read (STORE-A-0003 consequence) is explicitly priced by comparing dictionary-heavy vs. quad-heavy corpora, and the review triggers consulted if it dominates.
- [x] Package documentation at odin-rdf-parser's contract-level standard: package doc with the DB layout summary, the transaction model (implicit per-op; batched loaders; per-document atomicity), the iterator lifetime contract (valid until `match_destroy`, MVCC snapshot per iterator), the copying-lookup contract, `Options` guidance (map_size, no_sync trade-off), and the platform stance (darwin_arm64 + vendored 0.9.35).
- [x] Full repo test suite green at both Term_ID widths via `scripts/test.sh` (core + LMDB packages).
- [x] STORE-I-0002's exit criteria all verified and checked off; `.metis/code-index.md` updated with the new packages.

## Implementation Notes **[CONDITIONAL: Technical Task]**

### Technical Approach
LMDB load benchmarks are commit-dominated in durable mode — report both durable and `no_sync` so the fsync cost is visible rather than mistaken for engine overhead. Reuse the parser corpus generators as in the existing bench harness. Match benchmarks should measure through `match`/`match_next` only (no term materialization) to price the index path itself, plus one materializing variant to price decode.

### Dependencies
STORE-T-0011 (everything implemented). This is the final task.

### Risk Considerations
Benchmark variance from filesystem state (page cache, fsync behavior) — fixed corpus, repeated runs, environment noted. If numbers reveal a defect (e.g. verification reads dominating), record it and file follow-up work rather than expanding this task.

## Status Updates **[REQUIRED]**

- **2026-08-04 — Completed.** `bench/lmdb.odin`: LMDB bulk load durable + `no_sync` over the all-distinct N-Triples corpus (dictionary-heavy) and the deduplicating Turtle corpus (probe-heavy — prices the verification read), disk B/stmt from `data.mdb` size, and match-path benchmarks (MATCH_ALL full drain + 10k (g,s)-bound probes) against both backends over identical data. One bench bug caught and fixed mid-task (Turtle corpus fed to the NT loader). Numbers and analysis recorded in the initiative's Status Updates — headline: LMDB loads at ~50% of in-memory speed with one fsync per document, probes cost ~2.2 µs of txn+cursor overhead each (confirming the decision-3 analysis), and no ADR review trigger fires. Package doc extended (platform stance, atomic-load divergence pointer); `.metis/code-index.md` rewritten for the three-package layout. Final suite: 55 tests per width, green; `store` verified C-free. All initiative exit criteria checked. Deviation note: the "materializing variant" of the match benchmark from the implementation notes was skipped — decode cost is already isolated by the T9 lookup path and would have added a fourth axis to an already-informative comparison; revisit if SPARQL result materialization ever needs pricing.