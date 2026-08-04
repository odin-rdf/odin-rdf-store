---
id: term-dictionary-intern-and
level: task
title: "Term dictionary: intern and bidirectional lookup for all term kinds"
short_code: "STORE-T-0002"
created_at: 2026-08-04T17:43:42.174317+00:00
updated_at: 2026-08-04T17:43:42.174317+00:00
parent: STORE-I-0001
blocked_by: ["STORE-T-0001"]
archived: false

tags:
  - "#task"
  - "#phase/todo"


exit_criteria_met: false
initiative_id: STORE-I-0001
---

# Term dictionary: intern and bidirectional lookup for all term kinds

## Parent Initiative **[CONDITIONAL: Assigned Task]**

[[STORE-I-0001]]

## Objective **[REQUIRED]**

Build the term dictionary: interning of `rdf.Term` values (including recursive RDF-star triple terms) to `Term_ID`s with dictionary-owned storage, and array-indexed reverse lookup. After this task, borrowed parser output can be promoted to stable IDs and back — the store's half of the RDF-A-0001 lifetime contract.

## Acceptance Criteria **[REQUIRED]**

- [ ] Interning covers all four term kinds; interning equal terms (per `rdf.equal` semantics, including literal datatype/language/direction) returns the same ID; distinct terms get distinct IDs, assigned densely per kind in first-seen order.
- [ ] Term strings are cloned into dictionary-owned storage on first sight — interning a term borrowed from a parser statement is safe and leaves no reference to the source buffer.
- [ ] RDF-star triple terms intern recursively: components first, then the triple term as a kind-tagged ID whose dictionary entry holds the three component IDs.
- [ ] `Graph_Label` interning: IRI and blank-node labels intern as their kinds; a nil label maps to the default-graph sentinel.
- [ ] Reverse lookup is array-indexed per kind (`counter(id)` → entry) and returns an `rdf.Term` whose strings are borrowed from dictionary storage, valid until dictionary destroy (documented).
- [ ] Allocator idiom per odin-rdf-parser: `init` takes `allocator := context.allocator`; `destroy` frees all owned storage; no GC of unreferenced terms (initiative decision 5).
- [ ] Unit tests: intern-twice-same-ID per kind, ID→term round-trips, literal edge cases (xsd:string vs langString vs dirLangString, same lexical different datatype), recursive triple terms, blank-node vs IRI with equal spelling, agreement with `rdf.equal`/`rdf.hash` — green at both widths.

## Implementation Notes **[CONDITIONAL: Technical Task]**

### Technical Approach
Term→ID via a hash map keyed on term content (reuse `rdf/hash.odin` and `rdf/equal.odin` semantics from the parser); ID→term via one dynamic array per kind. This deliberately replaces (not wraps) the parser's `Intern_Table` for store use — the store needs IDs, not just deduplicated strings.

### Dependencies
STORE-T-0001 (Term_ID encoding). `../odin-rdf-parser` `rdf` package as the term data model.

### Risk Considerations
Literal equality subtleties (language-tag case, direction) drifting from `rdf.equal` — pin with tests that assert dictionary behavior matches `rdf.equal` verdicts on curated term pairs.

## Status Updates **[REQUIRED]**

*To be added during implementation*