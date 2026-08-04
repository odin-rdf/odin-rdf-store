---
id: round-trip-test-bulk-load
level: task
title: "Round-trip test, bulk-load benchmark, and API documentation polish"
short_code: "STORE-T-0006"
created_at: 2026-08-04T17:43:54.755189+00:00
updated_at: 2026-08-04T17:43:54.755189+00:00
parent: STORE-I-0001
blocked_by: ["STORE-T-0004", "STORE-T-0005"]
archived: false

tags:
  - "#task"
  - "#phase/todo"


exit_criteria_met: false
initiative_id: STORE-I-0001
---

# Round-trip test, bulk-load benchmark, and API documentation polish

## Parent Initiative **[CONDITIONAL: Assigned Task]**

[[STORE-I-0001]]

## Objective **[REQUIRED]**

Close out the initiative: prove data preservation end-to-end with a round-trip test, establish the bulk-load benchmark that guards throughput and copy-discipline regressions, and bring the public API documentation to odin-rdf-parser's contract-level standard. Ends with the initiative's exit criteria verified.

## Acceptance Criteria **[REQUIRED]**

- [ ] Round-trip smoke test for all four formats: load fixture → export through the parser's emitters → reload → the two datasets contain the same quad set (equality modulo blank-node relabeling). Any export helper written for this lives in test code — a polished export API remains out of scope (initiative non-goal).
- [ ] `bench/` harness measuring bulk-load throughput (statements/second) and memory (bytes/statement) on a large fixture, following the parser's benchmark conventions; baseline numbers recorded in the initiative document.
- [ ] Public API documentation at the parser's contract-level standard: package doc, the finalized match-interface contract, dictionary lifetime rules (terms borrowed from dictionary storage), allocator obligations, and the append-only v1 posture with `remove`'s future logical-visibility contract noted.
- [ ] Full test suite (unit + conformance + integration + round-trip) green at both Term_ID widths.
- [ ] STORE-I-0001's exit criteria all verified and checked off; benchmark baseline and any deviations recorded in its Status Updates.
- [ ] `.metis/code-index.md` regenerated so the next session starts with an accurate map.

## Implementation Notes **[CONDITIONAL: Technical Task]**

### Technical Approach
Round-trip comparison needs blank-node-isomorphism-lite: per-load scoping (STORE-T-0005) guarantees relabeling, so compare via a canonical mapping built during matching rather than raw label equality. Keep it simple — full graph isomorphism is overkill for fixtures designed to avoid pathological blank-node structures.

### Dependencies
STORE-T-0004 (indexed backing — benchmarks against the real structure) and STORE-T-0005 (ingestion). This is the final task.

### Risk Considerations
Benchmark noise making regressions ambiguous — record the measurement environment alongside baselines. Round-trip via emitters may surface parser-emitter asymmetries; if one appears, file it against odin-rdf-parser rather than working around it silently.

## Status Updates **[REQUIRED]**

*To be added during implementation*