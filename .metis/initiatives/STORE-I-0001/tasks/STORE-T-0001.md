---
id: term-id-encoding-module-with-dual
level: task
title: "Term_ID encoding module with dual-width CI"
short_code: "STORE-T-0001"
created_at: 2026-08-04T17:43:38.289164+00:00
updated_at: 2026-08-04T20:00:49.763199+00:00
parent: STORE-I-0001
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/completed"


exit_criteria_met: false
initiative_id: STORE-I-0001
---

# Term_ID encoding module with dual-width CI

## Parent Initiative **[CONDITIONAL: Assigned Task]**

[[STORE-I-0001]]

## Objective **[REQUIRED]**

Create the store's foundational package with the `Term_ID` type exactly as decided in STORE-A-0001: build-time-selectable width, 3-bit kind tag in the high bits, dense per-kind counters — plus the encoded-quad type and the CI arrangement that keeps both widths green. This is the first code in the repository, so it also establishes package and test layout.

## Acceptance Criteria

## Acceptance Criteria **[REQUIRED]**

- [x] `TERM_ID_BITS :: #config(RDF_STORE_TERM_ID_BITS, 64)` selects `Term_ID :: distinct u64` (default) or `distinct u32`; width literals appear nowhere outside the `when` block.
- [x] 3-bit kind tag with values for IRI, blank node, literal, and triple term, plus reserved values including the default-graph sentinel; helpers (`make_id`, `id_kind`, `id_counter` — final names per package conventions) with all shifts, masks, and per-kind capacities derived from `size_of(Term_ID)`.
- [x] The default-graph sentinel is a constant from reserved tag space, consuming no kind's counter space.
- [x] Encoded-quad type (`[4]Term_ID`: s, p, o, g) with a positional numeric comparison procedure — the shared ordering both backends must agree on per STORE-A-0001 point 7.
- [x] Counter-overflow behavior defined and tested (matters for the 32-bit build's ~2^29 per-kind cap).
- [x] Unit tests cover tag encode/extract round-trips, the sentinel, capacity edges, and quad comparison ordering — green at both widths.
- [x] CI workflow (or a checked-in script until CI exists) builds and runs tests at both widths.

## Implementation Notes **[CONDITIONAL: Technical Task]**

### Technical Approach
Mirror odin-rdf-parser's package conventions (package layout, doc-comment style, test file naming). Big-endian serialization of IDs is deliberately NOT part of this task — it is the LMDB backend's key-codec concern (STORE-A-0001 point 6); this task only guarantees the logical encoding it will serialize.

### Dependencies
None (first task). Governed by STORE-A-0001.

### Risk Considerations
Getting a helper's mask arithmetic subtly wrong at one width only — mitigated by running every test at both widths from day one.

## Status Updates **[REQUIRED]**

- **2026-08-04 — Completed.** `store/term_id.odin`: `#config` width switch (64 default / 32 opt-in, `#panic` otherwise), `Term_Kind` with 3-bit tag (four real kinds + Sentinel tag for reserved IDs), all masks/capacities derived from `size_of(Term_ID)`, `make_id`/`id_kind`/`id_counter`, `DEFAULT_GRAPH` and `WILDCARD` sentinels, `Encoded_Quad :: [4]Term_ID` with `encoded_quad_compare`. `store/term_id_test.odin`: 5 tests (round-trip, width constants, sentinels, kind clustering, quad ordering). `scripts/test.sh` runs the suite at both widths — green at both. Notes: WILDCARD (Sentinel counter 1) added here since it belongs with the encoding; STORE-T-0003's pattern type consumes it. Counter overflow is an assert in `make_id`, documented as last-line defense — the dictionary checks capacity before assigning.