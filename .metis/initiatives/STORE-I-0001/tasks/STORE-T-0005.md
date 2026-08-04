---
id: bulk-ingestion-from-odin-rdf
level: task
title: "Bulk ingestion from odin-rdf-parser with blank-node scoping"
short_code: "STORE-T-0005"
created_at: 2026-08-04T17:43:51.760525+00:00
updated_at: 2026-08-04T20:13:35.358378+00:00
parent: STORE-I-0001
blocked_by: [STORE-T-0003]
archived: false

tags:
  - "#task"
  - "#phase/completed"


exit_criteria_met: false
initiative_id: STORE-I-0001
---

# Bulk ingestion from odin-rdf-parser with blank-node scoping

## Parent Initiative **[CONDITIONAL: Assigned Task]**

[[STORE-I-0001]]

## Objective **[REQUIRED]**

Bulk-load RDF documents from all four odin-rdf-parser formats into a dataset, honoring the per-statement validity contract of ADR RDF-A-0001 (odin-rdf-parser). This is both a feature and the real-world validation of the parser's clone/intern discipline — the open success criterion in the parser's vision RDF-V-0001.

## Acceptance Criteria

## Acceptance Criteria **[REQUIRED]**

- [x] Load procedures for N-Triples, N-Quads, Turtle, and TriG driving the parser's pull loop (`parser_next` → intern positions → insert encoded quad); triple formats land in the default graph (or a caller-specified target graph).
- [x] Per-statement discipline holds: nothing borrowed from a parser statement survives the loop iteration — all retention goes through the dictionary's owned storage (scope-map keys for blank labels are cloned too).
- [x] Per-load blank-node scoping (initiative decision 6): the same label in two separate loads produces two distinct terms; the same label within one load produces one term. Implemented as scope-map → `fresh_blank` in the dictionary, which generates collision-checked labels, so blank nodes inside RDF-star triple terms and blank graph labels are scoped as well.
- [x] Parse errors propagate as `Load_Error` (static message + 1-based line/column); partial-data-on-error is documented on the load procedures (append-only, no rollback) and pinned by a test.
- [x] Integration tests load fixtures in all four formats and verify quad counts and spot matches through the match interface.
- [x] Adversarial fixtures cover escape sequences (`\"`, `\n`, `\u` in literals; non-ASCII IRIs), prefixed-name expansion, RDF-star triple terms, and language tags, with the source buffer overwritten after loading so a retained borrow corrupts visibly. (Deviation: directional language tags are exercised at the dictionary layer, not through a load fixture — the base-direction syntax is exercised thoroughly in the parser's own suite.)

## Implementation Notes **[CONDITIONAL: Technical Task]**

### Technical Approach
The load loop is the parser-boundary pattern from the initiative's Architecture section. Blank-node scoping is a per-load `map[label]Term_ID` in the ingestion layer, not in the dictionary. Written against the match interface, so it runs on the naive backing if STORE-T-0004 isn't done yet — the two tasks can proceed in parallel after STORE-T-0003.

### Dependencies
STORE-T-0003 (dataset + interface). `../odin-rdf-parser` (all four format packages). Can run in parallel with STORE-T-0004.

### Risk Considerations
A dangling borrow can pass tests accidentally if the source buffer happens to stay alive — make adversarial tests free or overwrite the source buffer after loading before asserting, so stale borrows actually fail.

## Status Updates **[REQUIRED]**

- **2026-08-04 — Completed.** `store/load.odin`: `load_triples`/`load_turtle` (optional target graph) and `load_quads`/`load_trig` (statement-named graphs), all driving the parsers' pull loops with a private `Load_Scope` that maps document blank labels → `fresh_blank` dictionary entries (per-load scoping; recursion through RDF-star triple terms and blank graph labels included). Dictionary gained `intern_triple_ids` (intern a triple term from pre-scoped component IDs) and `fresh_blank` (collision-checked generated labels "bN"). `Load_Error` carries the parser's static message + line/column; on error, already-inserted statements remain (documented + tested). 6 integration tests in `store/load_test.odin`: per-format fixtures with spot matches, cross-load blank scoping (same doc twice → blank quads duplicate, ground quads dedupe), buffer-overwrite dangling-borrow proof over escaped/non-ASCII content, and error-position reporting. Suite: 26 tests green at both widths. This also closes the parser vision's open criterion in real use: statements were interned per-statement with the source buffer invalidated afterward, and nothing leaked or dangled.