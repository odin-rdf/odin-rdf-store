---
id: match-interface-contract-naive
level: task
title: "Match interface contract, naive dataset, and 16-pattern conformance suite"
short_code: "STORE-T-0003"
created_at: 2026-08-04T17:43:45.105226+00:00
updated_at: 2026-08-04T17:43:45.105226+00:00
parent: STORE-I-0001
blocked_by: ["STORE-T-0002"]
archived: false

tags:
  - "#task"
  - "#phase/todo"


exit_criteria_met: false
initiative_id: STORE-I-0001
---

# Match interface contract, naive dataset, and 16-pattern conformance suite

## Parent Initiative **[CONDITIONAL: Assigned Task]**

[[STORE-I-0001]]

## Objective **[REQUIRED]**

Make the match interface real: write the v1 contract documentation per STORE-A-0002, implement a deliberately naive in-memory dataset that satisfies it, and build the 16-pattern conformance suite against the contract (not the implementation). The naive backing is scaffolding — its job is to be trivially correct so the suite's own correctness is established before indexes complicate the picture.

## Acceptance Criteria **[REQUIRED]**

- [ ] The contract document (in-package doc comment per STORE-A-0002 point 2) specifies: the v1 procedure set (`dataset_init`/`dataset_destroy`, `insert`, `count`, `match`, iterator `next`/`destroy`), match-pattern semantics (each of s/p/o/g a bound `Term_ID` or wildcard), set semantics, iterator validity and exhaustion behavior, allocator obligations, explicitly no iteration-order guarantee in v1, and `remove`'s future contract as logical visibility.
- [ ] Naive dataset implements the contract: hash-set of encoded quads for set semantics; match by linear scan with per-position filtering; default graph addressed via the sentinel.
- [ ] Match returns a streaming iterator yielding one encoded quad per `next` call — no materialized result collections.
- [ ] Conformance suite covers: all 16 bound/wildcard pattern combinations, duplicate-insert no-op, default vs. named graphs, blank-node graph labels, RDF-star triple terms in subject/object, empty dataset, no-match patterns, and `next` after exhaustion.
- [ ] The suite is parameterized over the backend under test (init/teardown indirection) so STORE-T-0004's indexed implementation — and one day the LMDB backend — runs it unchanged.
- [ ] Suite green against the naive dataset at both Term_ID widths.

## Implementation Notes **[CONDITIONAL: Technical Task]**

### Technical Approach
Sequencing within the task: contract text first, suite second, naive implementation last — the implementation exists to turn the suite green. Fixture quads build IDs through the real dictionary (STORE-T-0002), not hand-rolled constants, so the suite exercises the true encode path.

### Dependencies
STORE-T-0002 (dictionary, for fixtures and the insert path). Governed by STORE-A-0002.

### Risk Considerations
The suite silently encoding naive-implementation quirks (e.g. incidental iteration order) as expectations — guard by asserting only set-level results, never sequence order.

## Status Updates **[REQUIRED]**

*To be added during implementation*