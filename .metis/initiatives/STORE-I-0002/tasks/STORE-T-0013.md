---
id: restructure-packages-store
level: task
title: "Restructure packages: store vocabulary core with memstore and kvstore backends"
short_code: "STORE-T-0013"
created_at: 2026-08-04T21:56:01.442986+00:00
updated_at: 2026-08-04T22:00:36.223016+00:00
parent: STORE-I-0002
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/completed"


exit_criteria_met: false
initiative_id: STORE-I-0002
---

# Restructure packages: store vocabulary core with memstore and kvstore backends

## Parent Initiative **[CONDITIONAL: Assigned Task]**

[[STORE-I-0002]]

## Objective **[REQUIRED]**

Resolve the package-layout confusion the two-backend milestone exposed (user request, 2026-08-04): `store` conflated the shared vocabulary with the in-memory backend, so `store_lmdb` importing `store` read as layering when it is peering. Restructure to the user's proposed shape — `store/` as the vocabulary + contract core, with `store/memstore/` and `store/kvstore/` as backend packages whose names read well in code and conversation.

## Acceptance Criteria

## Acceptance Criteria **[REQUIRED]**

- [x] `store/` contains only the shared vocabulary: `term_id.odin` (encoding, Encoded_Quad, sentinels) and `interface.odin` (the match interface contract doc, `Match_Pattern`/`MATCH_ALL`/`pattern_matches`, `Load_Error`); its package doc describes the family layout.
- [x] `store/memstore/` (package `memstore`) holds the in-memory backend (dictionary, dataset, loaders + their tests), importing the vocabulary as `store ".."`.
- [x] `store/kvstore/` (package `kvstore`, renamed from `store_lmdb`) holds the LMDB backend unchanged in behavior; `vendor/lmdb` and parser import paths adjusted.
- [x] `conformance/` instantiates memstore via `store/memstore`; test names follow the new naming (`test_memstore_*`); `bench/` drives `memstore` and `kvstore`.
- [x] `scripts/test.sh` covers all four packages at both widths; full suite green (55 tests per width) and `odin build bench` clean.
- [x] STORE-A-0002 amended (dated) — the contract document now lives in `store/interface.odin`, superseding "the in-memory package's doc comment"; `.metis/code-index.md` rewritten for the new layout.

## Implementation Notes **[CONDITIONAL: Technical Task]**

### Technical Approach
Mechanical moves plus a symbol-qualification pass: memstore files gained `import store ".."` and `store.`-qualified vocabulary references; kvstore was a package rename + import-depth fix (it already qualified everything). Behavior untouched — no procedure bodies changed.

### Dependencies
Follows STORE-T-0012; requested during initiative review.

### Risk Considerations
Pure-refactor risk is silent behavior change — excluded by the unchanged test inventory passing verbatim (the conformance suite's purpose, working as designed).

## Status Updates **[REQUIRED]**

- **2026-08-05 — Completed.** Layout is now `store/` (vocabulary + contract; new `interface.odin`), `store/memstore/`, `store/kvstore/`, with `conformance/`, `vendor/lmdb/`, `bench/` at root. What `store` exports is exactly the 18-symbol shared vocabulary the kvstore backend was already importing — the restructure makes the package graph tell that story. Suite: 5 (store) + 16 (memstore) + 9 (conformance) + 25 (kvstore) = 55 tests green at both widths; bench builds. STORE-A-0002 amended with the contract's new home; code index rewritten.