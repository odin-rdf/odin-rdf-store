---
id: match-interface-contract-naive
level: task
title: "Match interface contract, naive dataset, and 16-pattern conformance suite"
short_code: "STORE-T-0003"
created_at: 2026-08-04T17:43:45.105226+00:00
updated_at: 2026-08-04T20:07:02.137992+00:00
parent: STORE-I-0001
blocked_by: [STORE-T-0002]
archived: false

tags:
  - "#task"
  - "#phase/completed"


exit_criteria_met: false
initiative_id: STORE-I-0001
---

# Match interface contract, naive dataset, and 16-pattern conformance suite

## Parent Initiative **[CONDITIONAL: Assigned Task]**

[[STORE-I-0001]]

## Objective **[REQUIRED]**

Make the match interface real: write the v1 contract documentation per STORE-A-0002, implement a deliberately naive in-memory dataset that satisfies it, and build the 16-pattern conformance suite against the contract (not the implementation). The naive backing is scaffolding — its job is to be trivially correct so the suite's own correctness is established before indexes complicate the picture.

## Acceptance Criteria

## Acceptance Criteria **[REQUIRED]**

- [x] The contract document (in-package doc comment per STORE-A-0002 point 2) specifies: the v1 procedure set (`dataset_init`/`dataset_destroy`, `insert`, `count`, `match`, iterator `next`/`destroy`), match-pattern semantics (each of s/p/o/g a bound `Term_ID` or wildcard), set semantics, iterator validity and exhaustion behavior, allocator obligations, explicitly no iteration-order guarantee in v1, and `remove`'s future contract as logical visibility.
- [x] Naive dataset implements the contract: hash-set of encoded quads for set semantics; match by linear scan with per-position filtering; default graph addressed via the sentinel.
- [x] Match returns a streaming iterator yielding one encoded quad per `next` call — no materialized result collections.
- [x] Conformance suite covers: all 16 bound/wildcard pattern combinations, duplicate-insert no-op, default vs. named graphs, blank-node graph labels, RDF-star triple terms in object position, empty dataset, no-match patterns, and `next` after exhaustion. (Deviation: the RDF-star fixture uses a triple term in object position only — RDF 1.2 grammars restrict triple terms to objects, so a subject-position fixture would exercise a state no parser can produce; noted rather than fabricated.)
- [x] The suite exercises only the contract procedure set with expectations from a brute-force oracle over the fixture list; STORE-T-0004 swaps `Dataset` internals in place, so the suite runs unchanged. A future out-of-package backend ports by swapping the type behind the same procedure names.
- [x] Suite green against the naive dataset at both Term_ID widths.

## Implementation Notes **[CONDITIONAL: Technical Task]**

### Technical Approach
Sequencing within the task: contract text first, suite second, naive implementation last — the implementation exists to turn the suite green. Fixture quads build IDs through the real dictionary (STORE-T-0002), not hand-rolled constants, so the suite exercises the true encode path.

### Dependencies
STORE-T-0002 (dictionary, for fixtures and the insert path). Governed by STORE-A-0002.

### Risk Considerations
The suite silently encoding naive-implementation quirks (e.g. incidental iteration order) as expectations — guard by asserting only set-level results, never sequence order.

## Status Updates **[REQUIRED]**

- **2026-08-04 — Completed.** `store/dataset.odin`: full contract doc comment (procedure set, pattern semantics with DEFAULT_GRAPH vs WILDCARD graph distinction, set semantics, streaming/exhaustion, iterator validity, no-ordering-guarantee, WILDCARD-not-storable, remove-as-logical-visibility future contract, allocator obligations), `Match_Pattern` + `MATCH_ALL` + `pattern_matches`, naive `Dataset` (hash-set membership + insertion-order array, linear-scan iterator). `match_destroy` is a required call in the contract even though this backend holds nothing — so caller code ports unchanged to cursor-holding backends. `store/dataset_test.odin`: conformance suite — all 16 masks × 4 probe quads (64 combinations) against a brute-force oracle, plus set-semantics, empty-dataset, no-match/exhaustion, and default-vs-named-graph tests; fixture spans default/IRI-named/blank-named graphs, a triple duplicated across two graphs, blank subjects, lang/typed literals, RDF-star triple term in object. Suite: 19 tests green at both widths.