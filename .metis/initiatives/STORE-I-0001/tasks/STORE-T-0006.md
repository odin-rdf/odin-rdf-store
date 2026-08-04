---
id: round-trip-test-bulk-load
level: task
title: "Round-trip test, bulk-load benchmark, and API documentation polish"
short_code: "STORE-T-0006"
created_at: 2026-08-04T17:43:54.755189+00:00
updated_at: 2026-08-04T20:20:24.820681+00:00
parent: STORE-I-0001
blocked_by: [STORE-T-0004, STORE-T-0005]
archived: false

tags:
  - "#task"
  - "#phase/completed"


exit_criteria_met: false
initiative_id: STORE-I-0001
---

# Round-trip test, bulk-load benchmark, and API documentation polish

## Parent Initiative **[CONDITIONAL: Assigned Task]**

[[STORE-I-0001]]

## Objective **[REQUIRED]**

Close out the initiative: prove data preservation end-to-end with a round-trip test, establish the bulk-load benchmark that guards throughput and copy-discipline regressions, and bring the public API documentation to odin-rdf-parser's contract-level standard. Ends with the initiative's exit criteria verified.

## Acceptance Criteria

## Acceptance Criteria **[REQUIRED]**

- [x] Round-trip smoke test for all four formats: load fixture → export through the parser's emitters → reload → same quad set modulo blank-node relabeling (greedy-bijection comparator in `store/roundtrip_test.odin`; export helpers are test-local, polished export API remains out of scope).
- [x] `bench/main.odin` measuring bulk-load throughput (statements/second, including index construction) and live bytes/statement via a tracking allocator, over the parser's deterministic corpora; baselines recorded in the initiative's Status Updates.
- [x] Public API documentation at the parser's contract-level standard: package doc with component overview and lifetime rules, the match-interface contract on `dataset.odin`, dictionary lifetime/allocator/no-GC rules, append-only posture with `remove`'s logical-visibility future contract.
- [x] Full test suite — 30 tests (unit + conformance + integration + round-trip) — green at both Term_ID widths.
- [x] STORE-I-0001's exit criteria all verified and checked off; benchmark baseline and the insert-strategy change recorded in its Status Updates.
- [x] `.metis/code-index.md` regenerated — hand-written module map, since the tree-sitter indexer has no Odin support (noted in the file).

## Implementation Notes **[CONDITIONAL: Technical Task]**

### Technical Approach
Round-trip comparison needs blank-node-isomorphism-lite: per-load scoping (STORE-T-0005) guarantees relabeling, so compare via a canonical mapping built during matching rather than raw label equality. Keep it simple — full graph isomorphism is overkill for fixtures designed to avoid pathological blank-node structures.

### Dependencies
STORE-T-0004 (indexed backing — benchmarks against the real structure) and STORE-T-0005 (ingestion). This is the final task.

### Risk Considerations
Benchmark noise making regressions ambiguous — record the measurement environment alongside baselines. Round-trip via emitters may surface parser-emitter asymmetries; if one appears, file it against odin-rdf-parser rather than working around it silently.

## Status Updates **[REQUIRED]**

- **2026-08-04 — Completed.** `store/roundtrip_test.odin`: 4 round-trip tests (NT, NQ, Turtle, TriG) with a greedy-bijection blank-relabeling comparator (fails loudly on ambiguous fixtures rather than guessing). `bench/main.odin`: throughput + live-memory harness over the parser's corpus generators. **The benchmark caught a real problem**: per-insert sorted-array injection was O(n) per index → ~19k stmt/s on 200k distinct quads. Per STORE-T-0004's recorded plan (insert strategy decided on benchmark evidence), the dataset switched to hash-set membership + pending buffer + lazy sort/merge on first match — conformance suite passed unchanged, throughput now ~600k stmt/s including index construction (30×). Baselines recorded in the initiative. API docs polished (package overview + lifetime rules in `term_id.odin`). Code index hand-written (no Odin tree-sitter support). Final suite: 30 tests green at 64-bit and 32-bit widths.