---
id: permutation-indexes-gspo-gpos-gosp
level: task
title: "Permutation indexes: GSPO/GPOS/GOSP behind the match interface"
short_code: "STORE-T-0004"
created_at: 2026-08-04T17:43:48.304286+00:00
updated_at: 2026-08-04T17:43:48.304286+00:00
parent: STORE-I-0001
blocked_by: ["STORE-T-0003"]
archived: false

tags:
  - "#task"
  - "#phase/todo"


exit_criteria_met: false
initiative_id: STORE-I-0001
---

# Permutation indexes: GSPO/GPOS/GOSP behind the match interface

## Parent Initiative **[CONDITIONAL: Assigned Task]**

[[STORE-I-0001]]

## Objective **[REQUIRED]**

Replace the naive dataset backing with the real index layout decided in the initiative (decision 2): three graph-first sorted-array permutation indexes — GSPO, GPOS, GOSP. The conformance suite from STORE-T-0003 passing unchanged is the proof that the interface abstracted correctly.

## Acceptance Criteria **[REQUIRED]**

- [ ] Three sorted dynamic-array indexes over encoded quads in GSPO, GPOS, and GOSP orderings, using the shared positional numeric comparison from STORE-T-0001; `insert` maintains all three with set semantics (duplicate detection before insertion).
- [ ] A documented pattern→index dispatch table: for each of the 16 match patterns, which index serves it and how (point lookup, prefix range scan, or cross-graph scan).
- [ ] Wildcard-graph patterns with bound s/p/o are answered by scanning across graphs, documented as the accepted v1 trade-off (initiative decision 2; graph-last permutations are the future remedy).
- [ ] Match iterators stream directly from index ranges; binary search finds range boundaries; iterators allocate nothing (or take an explicit allocator, per the contract).
- [ ] `count` is O(1) via maintained size.
- [ ] The STORE-T-0003 conformance suite passes unchanged against the indexed implementation, at both Term_ID widths.
- [ ] The naive implementation is either removed or retained explicitly as a differential-testing reference — decided and documented, not left ambiguous.

## Implementation Notes **[CONDITIONAL: Technical Task]**

### Technical Approach
Sorted arrays per initiative decision 3 (append-friendly, cache-friendly, no remove path needed in append-only v1). Insert strategy matters for bulk-load throughput — consider buffered append + sort/dedupe on query (or an explicit finalize) versus insert-in-place; coordinate the choice with STORE-T-0006's benchmark so it is measured, not guessed. The structure is invisible behind the interface, so it can change on benchmark evidence.

### Dependencies
STORE-T-0003 (contract + conformance suite define "done" here).

### Risk Considerations
Subtle disagreements between the three indexes (a quad present in two of three after a bug) — consider a debug-mode cross-index consistency check. Duplicate detection cost on insert is the naive O(log n) triple-probe; acceptable for v1, benchmark will tell.

## Status Updates **[REQUIRED]**

*To be added during implementation*