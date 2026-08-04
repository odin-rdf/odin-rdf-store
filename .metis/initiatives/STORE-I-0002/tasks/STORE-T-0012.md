---
id: lmdb-benchmarks-lifetime-contract
level: task
title: "LMDB benchmarks, lifetime-contract docs, and initiative close-out"
short_code: "STORE-T-0012"
created_at: 2026-08-04T21:11:42.379875+00:00
updated_at: 2026-08-04T21:11:42.379875+00:00
parent: STORE-I-0002
blocked_by: ["STORE-T-0011"]
archived: false

tags:
  - "#task"
  - "#phase/todo"


exit_criteria_met: false
initiative_id: STORE-I-0002
---

# LMDB benchmarks, lifetime-contract docs, and initiative close-out

## Parent Initiative **[CONDITIONAL: Assigned Task]**

[[STORE-I-0002]]

## Objective **[REQUIRED]**

Close out the initiative: extend the benchmark harness with LMDB numbers alongside the in-memory baselines, document the backend's lifetime and transaction contract at the family's standard, and verify every exit criterion.

## Acceptance Criteria **[REQUIRED]**

- [ ] `bench/` extended with LMDB runs over the same corpora: bulk load (statements/second including commit, in both durable and `no_sync` configurations), a match-scan benchmark (full-scan and bound-prefix range throughput) against both backends, and disk bytes/statement (environment file size / statements).
- [ ] Baselines recorded in STORE-I-0002's Status Updates next to the in-memory numbers from STORE-I-0001, with the measurement environment noted; the intern verification read (STORE-A-0003 consequence) is explicitly priced by comparing dictionary-heavy vs. quad-heavy corpora, and the review triggers consulted if it dominates.
- [ ] Package documentation at odin-rdf-parser's contract-level standard: package doc with the DB layout summary, the transaction model (implicit per-op; batched loaders; per-document atomicity), the iterator lifetime contract (valid until `match_destroy`, MVCC snapshot per iterator), the copying-lookup contract, `Options` guidance (map_size, no_sync trade-off), and the platform stance (darwin_arm64 + vendored 0.9.35).
- [ ] Full repo test suite green at both Term_ID widths via `scripts/test.sh` (core + LMDB packages).
- [ ] STORE-I-0002's exit criteria all verified and checked off; `.metis/code-index.md` updated with the new packages.

## Implementation Notes **[CONDITIONAL: Technical Task]**

### Technical Approach
LMDB load benchmarks are commit-dominated in durable mode — report both durable and `no_sync` so the fsync cost is visible rather than mistaken for engine overhead. Reuse the parser corpus generators as in the existing bench harness. Match benchmarks should measure through `match`/`match_next` only (no term materialization) to price the index path itself, plus one materializing variant to price decode.

### Dependencies
STORE-T-0011 (everything implemented). This is the final task.

### Risk Considerations
Benchmark variance from filesystem state (page cache, fsync behavior) — fixed corpus, repeated runs, environment noted. If numbers reveal a defect (e.g. verification reads dominating), record it and file follow-up work rather than expanding this task.

## Status Updates **[REQUIRED]**

*To be added during implementation*