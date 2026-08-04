---
id: batched-bulk-load-and-persistence
level: task
title: "Batched bulk load and persistence tests for the LMDB backend"
short_code: "STORE-T-0011"
created_at: 2026-08-04T21:11:38.240815+00:00
updated_at: 2026-08-04T21:11:38.240815+00:00
parent: STORE-I-0002
blocked_by: ["STORE-T-0010"]
archived: false

tags:
  - "#task"
  - "#phase/todo"


exit_criteria_met: false
initiative_id: STORE-I-0002
---

# Batched bulk load and persistence tests for the LMDB backend

## Parent Initiative **[CONDITIONAL: Assigned Task]**

[[STORE-I-0002]]

## Objective **[REQUIRED]**

Bulk-load all four parser formats into the persistent store — one write transaction per document (initiative decision 2) — and prove persistence end to end: blank scoping across loads and reopens, adversarial borrow discipline, and the close/reopen round-trip.

## Acceptance Criteria **[REQUIRED]**

- [ ] `load_triples`/`load_quads`/`load_turtle`/`load_trig` for the LMDB backend, driving the parsers' pull loops with per-load blank-node scoping (via the STORE-T-0009 `fresh_blank`), each document inside a single write transaction.
- [ ] Error semantics documented and tested: a parse error aborts the transaction, so an LMDB load is **atomic per document** — nothing persists from a failed load. This is a deliberate, documented divergence from the in-memory loader's keep-partial behavior (loaders are package conveniences, not part of the shared contract; the txn makes better semantics free).
- [ ] Blank scoping holds across sessions: the same blank-labeled document loaded before and after a close/reopen produces distinct blank nodes (persisted counters — no label reuse), while ground documents dedupe across reopens.
- [ ] Adversarial fixtures (escapes, non-ASCII IRIs, prefixed names, RDF-star) loaded from a buffer that is overwritten after the load; a reopened database still yields the original content — the persistent form of the RDF-A-0001 proof.
- [ ] Round-trip: load → close → reopen → export through the parser emitters → reload into a fresh store → same quad set modulo blank relabeling (greedy-bijection comparator, shared from STORE-T-0008's extraction or reused by copy per its recorded decision).
- [ ] Counts and spot matches verified through the match interface on the reopened database; all tests green at both Term_ID widths.

## Implementation Notes **[CONDITIONAL: Technical Task]**

### Technical Approach
The load loop's scoping/statement logic mirrors `store/load.odin`; share what STORE-T-0008 extracted cleanly, otherwise duplicate knowingly with a comment tying the two. Loads reuse the txn-parametric internals: intern and insert against the load's write txn — one txn, per decision 2, also making the per-document atomicity natural.

### Dependencies
STORE-T-0010 (complete match interface over LMDB). `../odin-rdf-parser` format packages.

### Risk Considerations
Large documents in one txn grow the dirty-page set; fine at test scale, and `map_size` covers headroom — the benchmark task will show whether chunked commits are ever needed (they would change the atomicity story and need a documented decision).

## Status Updates **[REQUIRED]**

*To be added during implementation*