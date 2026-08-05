---
id: reserve-the-sentinel-counters
level: task
title: "Reserve the Sentinel counters above UNBOUND for consumer-local term names"
short_code: "STORE-T-0021"
created_at: 2026-08-05T22:37:27.756257+00:00
updated_at: 2026-08-05T22:37:27.756257+00:00
parent: 
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/backlog"
  - "#feature"


exit_criteria_met: false
initiative_id: NULL
---

# Reserve the Sentinel counters above UNBOUND for consumer-local term names

## Objective **[REQUIRED]**

State in `store/term_id.odin` that Sentinel counters **from 3 upward belong
to the consumer**, and that the store will never assign one — so that a
future store sentinel cannot land on an ID a consumer is already using.

**Evidence, and the honest framing: this is a request to bless something,
not to build something.**

odin-rdf-sparql evaluates over Term_IDs, so a solution row is a
`[]Term_ID`. A value the query *computes* — `BIND(?a + ?b AS ?c)`,
`CONCAT(…)`, `TRIPLE(?s, ?p, ?o)`, a VALUES cell naming a term the data does
not contain, a path endpoint the store has never seen — has no ID, because
the store has never seen it. Interning one would make a query a **write**,
which is the exact thing `find_term` (STORE-T-0014) exists to prevent.

So the engine names such terms itself, in the space it could prove the store
would never use: the Sentinel kind, whose counters 0, 1, and 2 are
DEFAULT_GRAPH, WILDCARD, and UNBOUND, and whose counters from 3 up are
unassigned. A synthetic ID is an index into the query's own table of computed
terms, resolved before the store is ever asked
(`SYNTHETIC_FIRST` in `sparql/expr_eval.odin`).

It works, it is safe today, and it is the right design — a query-local term
needs a query-local name. Two things make it worth an upstream line:

1. **It is squatting.** `term_id.odin` documents counters 0–2 and says
   "values above Sentinel are reserved for future kinds" about the *kind*
   tag, but says nothing about the counters. A future store sentinel at
   counter 3 would silently collide with every computed term in every SPARQL
   query. Nothing would fail loudly; a query would just start matching the
   wrong thing.
2. **The consumer had to invent it.** That an engine reaches for an unused
   corner of the ID space because the store has no notion of a query-local
   term is, in itself, the finding — recorded as such in
   `sparql/expr_eval.odin`. The reservation is the cheap answer. The
   expensive answer, if the store ever wants one, is a first-class
   session/scratch term space; nothing needs it yet.

## Backlog Item Details **[CONDITIONAL: Backlog Item]**

### Type
- [x] Feature - New functionality or enhancement

### Priority
- [x] P2 - Medium (nice to have)

Nothing is broken. It is a one-line guarantee that prevents a silent,
extremely unpleasant future collision — and it is a prerequisite for
STORE-T-0017, which wants a new store sentinel and needs to know which
counters it may take.

### Business Justification **[CONDITIONAL: Feature]**
- **User Value**: Consumers can name query-local terms without reading the store's source to find out which IDs are safe.
- **Business Value**: Makes an existing informal dependency explicit before a second consumer (odin-rdf-shacl) copies it, and before the store adds a fourth sentinel of its own.
- **Effort Estimate**: XS — documentation plus a named constant and a test.

## Acceptance Criteria **[REQUIRED]**

- [ ] `store/term_id.odin` documents the Sentinel counter space: 0–2 are the store's (DEFAULT_GRAPH, WILDCARD, UNBOUND); a named boundary constant — `SENTINEL_CONSUMER_FIRST` or similar — marks where the consumer's range begins; the store never assigns at or above it.
- [ ] The store's own future sentinels come from *below* the boundary, which means deciding now how many the store reserves for itself. STORE-T-0017's named-graph wildcard is the first claimant and should take the next store-side counter.
- [ ] `term_id_test.odin` pins the boundary the way it already pins the three sentinels: distinctness, kind, and that a dictionary never assigns one.
- [ ] `store/interface.odin`'s contract mentions it where it already explains that UNBOUND belongs to the layer above the store — same paragraph, same reason.

## Implementation Notes **[CONDITIONAL: Technical Task]**

### Technical Approach

Purely a declaration. The dictionary already never assigns Sentinel-kind IDs
(it assigns IRI, Blank_Node, Literal, and Triple kinds only), so the
guarantee is already true; this makes it *promised*.

Worth stating alongside: a consumer's synthetic ID must never reach a match
pattern. odin-rdf-sparql asserts exactly that on the way in
(`assert(store.id_kind(id) != .Sentinel, …)` in `ground_ref`), and the store
could say so in the contract rather than leaving each consumer to invent the
rule.

### Dependencies

STORE-T-0017 (named-graph wildcard) wants a new store-side sentinel and
should be decided together with this, so the two do not pick the same
counter.

Consumer: odin-rdf-sparql (`SYNTHETIC_FIRST` in `sparql/expr_eval.odin`,
`computed_id` in `sparql/exec.odin`).

### Risk Considerations

The only real decision is how many counters the store keeps for itself. Too
few and this comes back; too many and the consumer's range starts at an
awkward number. Three or four store-side slots beyond the current three is
almost certainly plenty — the store has added three sentinels in its
lifetime.

## Status Updates **[REQUIRED]**

- **2026-08-05 — Created from odin-rdf-sparql SPARQL-T-0019**, the evaluation initiative's evidence consolidation. Awaiting pickup in an odin-rdf-store session.
