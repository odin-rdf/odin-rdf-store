---
id: permutation-indexes-gspo-gpos-gosp
level: task
title: "Permutation indexes: GSPO/GPOS/GOSP behind the match interface"
short_code: "STORE-T-0004"
created_at: 2026-08-04T17:43:48.304286+00:00
updated_at: 2026-08-04T20:09:21.915181+00:00
parent: STORE-I-0001
blocked_by: [STORE-T-0003]
archived: false

tags:
  - "#task"
  - "#phase/completed"


exit_criteria_met: false
initiative_id: STORE-I-0001
---

# Permutation indexes: GSPO/GPOS/GOSP behind the match interface

## Parent Initiative **[CONDITIONAL: Assigned Task]**

[[STORE-I-0001]]

## Objective **[REQUIRED]**

Replace the naive dataset backing with the real index layout decided in the initiative (decision 2): three graph-first sorted-array permutation indexes — GSPO, GPOS, GOSP. The conformance suite from STORE-T-0003 passing unchanged is the proof that the interface abstracted correctly.

## Acceptance Criteria

## Acceptance Criteria **[REQUIRED]**

- [x] Three sorted dynamic-array indexes over encoded quads in GSPO, GPOS, and GOSP orderings, using positional numeric comparison; `insert` maintains all three with set semantics (duplicate detection via GSPO binary search before insertion).
- [x] A documented pattern→index dispatch table on the `Dataset` doc comment: bound-graph patterns get contiguous range scans (longest-bound-prefix selection covers all 8 combinations), plus the residual-filter column.
- [x] Wildcard-graph patterns are answered by a full GSPO scan with filtering, documented as the accepted v1 trade-off with graph-last permutations named as the future remedy.
- [x] Match iterators stream directly from an index range slice; binary search (`prefix_range`) finds boundaries; iterators allocate nothing.
- [x] `count` is O(1) (`len(gspo)`).
- [x] The STORE-T-0003 conformance suite passes unchanged against the indexed implementation, at both Term_ID widths.
- [x] The naive implementation is removed (decision: the conformance suite already has an independent brute-force oracle, so a differential reference adds little; recorded here, not left ambiguous).

## Implementation Notes **[CONDITIONAL: Technical Task]**

### Technical Approach
Sorted arrays per initiative decision 3 (append-friendly, cache-friendly, no remove path needed in append-only v1). Insert strategy matters for bulk-load throughput — consider buffered append + sort/dedupe on query (or an explicit finalize) versus insert-in-place; coordinate the choice with STORE-T-0006's benchmark so it is measured, not guessed. The structure is invisible behind the interface, so it can change on benchmark evidence.

### Dependencies
STORE-T-0003 (contract + conformance suite define "done" here).

### Risk Considerations
Subtle disagreements between the three indexes (a quad present in two of three after a bug) — consider a debug-mode cross-index consistency check. Duplicate detection cost on insert is the naive O(log n) triple-probe; acceptable for v1, benchmark will tell.

## Status Updates **[REQUIRED]**

- **2026-08-04 — Completed.** `store/dataset.odin` internals replaced: `Dataset` now holds three sorted `[dynamic]Encoded_Quad` indexes (GSPO/GPOS/GOSP as `[4]int` position permutations). `insert` binary-searches GSPO for duplicates then `inject_at`s into all three (O(n) memmove per insert — accepted for v1, revisit on T6 benchmark evidence; buffered-append + finalize is the known alternative). `match` selects the index with the longest leading run of bound positions, `prefix_range` binary-searches the half-open range, and the iterator streams a slice with residual filtering — GSPO full scan when the graph is a wildcard (documented trade-off). Dispatch table lives on the `Dataset` doc comment. Naive backing removed (rationale in acceptance criteria). Added `store/index_test.odin`: white-box cross-index consistency check (equal sizes, strict sortedness under each permutation, same quad set) after scrambled insertion with duplicates — kept separate from the implementation-agnostic conformance suite. Suite: 20 tests green at both widths; conformance tests untouched by this task, as required.