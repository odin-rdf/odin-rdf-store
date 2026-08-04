---
id: bulk-ingestion-from-odin-rdf
level: task
title: "Bulk ingestion from odin-rdf-parser with blank-node scoping"
short_code: "STORE-T-0005"
created_at: 2026-08-04T17:43:51.760525+00:00
updated_at: 2026-08-04T17:43:51.760525+00:00
parent: STORE-I-0001
blocked_by: ["STORE-T-0003"]
archived: false

tags:
  - "#task"
  - "#phase/todo"


exit_criteria_met: false
initiative_id: STORE-I-0001
---

# Bulk ingestion from odin-rdf-parser with blank-node scoping

## Parent Initiative **[CONDITIONAL: Assigned Task]**

[[STORE-I-0001]]

## Objective **[REQUIRED]**

Bulk-load RDF documents from all four odin-rdf-parser formats into a dataset, honoring the per-statement validity contract of ADR RDF-A-0001 (odin-rdf-parser). This is both a feature and the real-world validation of the parser's clone/intern discipline — the open success criterion in the parser's vision RDF-V-0001.

## Acceptance Criteria **[REQUIRED]**

- [ ] Load procedures for N-Triples, N-Quads, Turtle, and TriG driving the parser's pull loop (`parser_next` → intern positions → insert encoded quad); triple formats land in the default graph (or a caller-specified target graph).
- [ ] Per-statement discipline holds: nothing borrowed from a parser statement survives the loop iteration — all retention goes through the dictionary's owned storage.
- [ ] Per-load blank-node scoping (initiative decision 6): the same label in two separate loads produces two distinct terms; the same label within one load produces one term.
- [ ] Parse errors propagate to the caller with the parser's position information; the state of a partially-loaded dataset on error is documented (partial data remains — append-only store, no rollback in v1).
- [ ] Integration tests load fixtures in all four formats and verify quad counts and spot matches through the match interface.
- [ ] Adversarial fixtures reuse the parser's hard cases — escape sequences, prefixed-name expansion, RDF-star triple terms, directional language tags — to prove no dangling borrows (the use-after-invalidate bug class RDF-A-0001 warns the type system won't catch).

## Implementation Notes **[CONDITIONAL: Technical Task]**

### Technical Approach
The load loop is the parser-boundary pattern from the initiative's Architecture section. Blank-node scoping is a per-load `map[label]Term_ID` in the ingestion layer, not in the dictionary. Written against the match interface, so it runs on the naive backing if STORE-T-0004 isn't done yet — the two tasks can proceed in parallel after STORE-T-0003.

### Dependencies
STORE-T-0003 (dataset + interface). `../odin-rdf-parser` (all four format packages). Can run in parallel with STORE-T-0004.

### Risk Considerations
A dangling borrow can pass tests accidentally if the source buffer happens to stay alive — make adversarial tests free or overwrite the source buffer after loading before asserting, so stale borrows actually fail.

## Status Updates **[REQUIRED]**

*To be added during implementation*