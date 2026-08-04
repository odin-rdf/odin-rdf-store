---
id: extract-shared-conformance-harness
level: task
title: "Extract shared conformance harness from the in-memory test suite"
short_code: "STORE-T-0008"
created_at: 2026-08-04T21:11:26.272152+00:00
updated_at: 2026-08-04T21:31:30.871178+00:00
parent: STORE-I-0002
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/completed"


exit_criteria_met: false
initiative_id: STORE-I-0002
---

# Extract shared conformance harness from the in-memory test suite

## Parent Initiative **[CONDITIONAL: Assigned Task]**

[[STORE-I-0002]]

## Objective **[REQUIRED]**

Extract the STORE-I-0001 conformance suite into a shared harness that any backend runs verbatim through a small adapter, and re-point the in-memory backend's tests at it. After this task there is exactly one source of truth for what "implements the match interface" means, and STORE-T-0010 can prove the LMDB backend by instantiation rather than by porting tests.

## Acceptance Criteria

## Acceptance Criteria

## Acceptance Criteria **[REQUIRED]**

- [x] A conformance harness package (test-support; naming per package conventions) containing the fixture builder and every contract test currently in `store/dataset_test.odin`: all 16 bound/wildcard masks × probe quads against the brute-force oracle, duplicate-insert no-op, empty dataset, no-match and iterator exhaustion, default-vs-named-vs-blank graphs.
- [x] The harness drives the backend under test through an adapter struct of procedure pointers plus a context pointer (dataset ops: init/destroy/insert/count/match/next/match_destroy; dictionary ops for fixture encoding: intern/encode) — indirection is acceptable here per STORE-I-0002 decision 5; the public backend APIs remain convention-based, untouched.
- [x] `store/dataset_test.odin` becomes a thin instantiation of the harness for the in-memory backend; no assertion or coverage is lost (test-case inventory before/after recorded in the status update), and the full suite stays green at both Term_ID widths.
- [x] The harness has no LMDB or C dependency — the core `store` package and its tests still build with none.
- [x] A doc comment on the harness states how a new backend adopts it (supply adapter, call the run-all proc) — written as the instruction STORE-T-0010 will follow.

## Implementation Notes **[CONDITIONAL: Technical Task]**

### Technical Approach
The greedy-bijection round-trip comparator in `roundtrip_test.odin` is a candidate for the same extraction if it falls out naturally (STORE-T-0011 wants it); do it only if clean, otherwise leave for T11 to reuse by copy and note the decision. The white-box `index_test.odin` stays in the core package — it tests internals, not the contract.

### Dependencies
None (refactors STORE-I-0001 assets; runs in parallel with STORE-T-0007). Governed by STORE-I-0002 decision 5.

### Risk Considerations
Odin test discovery: `@(test)` procs must live in the instantiating package for per-backend runs — structure the harness as plain procs taking `^testing.T`, with each backend declaring its own thin `@(test)` wrappers.

## Status Updates **[REQUIRED]**

- **2026-08-04 — Completed.** New `conformance/` package: `conformance.odin` (Backend adapter — ctx + proc pointers for insert/count/match_begin/match_next/match_destroy/intern_term/encode_quad/intern_graph; fixture builder; five `check_*` procs), `compare.odin` (`quads_equal_mod_blanks` made public — the round-trip comparator extraction proved clean, so T11 gets it for free), `inmem_test.odin` (in-memory Backend adapter + five thin `@(test)` wrappers on fresh instances), `roundtrip_inmem_test.odin` (the four round-trip tests, moved). One structural deviation from the task text, forced by Odin's import rules: the harness imports `store` for the shared types, so the in-memory `@(test)` wrappers cannot live in package `store` (circular import) — `store/dataset_test.odin` and `store/roundtrip_test.odin` were therefore **moved into the conformance package** rather than thinned in place. Coverage inventory: store 30 → 21 tests (−5 conformance, −4 round-trip), conformance +9 — total unchanged, nothing lost. Iterator handles are opaque rawptr (backend allocates/frees in match_begin/match_destroy). Suite green at both widths: 21+9+4 per width. `store/dataset.odin`'s contract comment re-pointed at the conformance package.