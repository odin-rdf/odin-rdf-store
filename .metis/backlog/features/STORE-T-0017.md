---
id: a-named-graph-wildcard-for-the
level: task
title: "A named-graph wildcard for the graph position of a match pattern"
short_code: "STORE-T-0017"
created_at: 2026-08-05T22:34:34.135246+00:00
updated_at: 2026-08-05T22:34:34.135246+00:00
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

# A named-graph wildcard for the graph position of a match pattern

## Objective **[REQUIRED]**

Let a match pattern say **"any named graph"** in the graph position, as
distinct from today's `WILDCARD`, which spans the default graph too.

**Evidence.** SPARQL's `GRAPH ?g { … }` ranges over the *named* graphs of the
dataset. The default graph is not one of them: it has no name, so there is
nothing for ?g to bind to. The match interface cannot express that
distinction — its graph position takes a bound ID, or `WILDCARD`, which means
"default and named alike". So odin-rdf-sparql over-fetches and filters: it
matches with `WILDCARD` and then drops every quad whose graph came back
`DEFAULT_GRAPH`, in `unify_quad` (`sparql/exec.odin`, SPARQL-T-0013).

It is correct and it is one comparison per quad, so the cost is not the
point. The point is that this is the interface being unable to say what the
query means, and the engine paying for the difference in fetched quads: a
`GRAPH ?g { ?s ?p ?o }` over a dataset whose default graph is the large one
reads all of it to answer with none of it.

## Backlog Item Details **[CONDITIONAL: Backlog Item]**

### Type
- [x] Feature - New functionality or enhancement

### Priority
- [x] P2 - Medium (nice to have)

Correct today, and the over-fetch only bites when the default graph is large
relative to the named ones. Lower than STORE-T-0015 and STORE-T-0016 for that
reason — but it is the smallest of the three by some distance.

### Business Justification **[CONDITIONAL: Feature]**
- **User Value**: `GRAPH ?g { … }` reads the named graphs and not the default one, which is what the query asked for.
- **Business Value**: Closes the last place where the SPARQL engine has to post-filter what it matched, so "the pattern the engine builds" and "the pattern the query means" finally coincide.
- **Effort Estimate**: S. One reserved Sentinel ID and one branch in each backend's graph-position handling; memstore's and kvstore's indexes are both graph-first, so "every graph except DEFAULT_GRAPH" is a range skip rather than a filter.

## Acceptance Criteria **[REQUIRED]**

- [ ] A reserved sentinel — `NAMED_GRAPHS` or similar, at the next free Sentinel counter — valid **only** in the graph position of a `Match_Pattern`, never in a stored quad, never in the other three positions. Documented in `store/term_id.odin` alongside DEFAULT_GRAPH, WILDCARD, and UNBOUND, and in `store/interface.odin`'s pattern semantics.
- [ ] Both backends match it as "every graph whose ID is not DEFAULT_GRAPH", by skipping rather than filtering where the index layout allows.
- [ ] `pattern_matches` in `store/interface.odin` handles it, so the shared predicate stays the definition of matching.
- [ ] Conformance suite: a dataset with quads in the default graph and in two named graphs, matched with each of DEFAULT_GRAPH / WILDCARD / the new sentinel, asserting the three answers differ as specified. Both backends, both widths.

## Implementation Notes **[CONDITIONAL: Technical Task]**

### Technical Approach

The Sentinel kind has counters 0 (DEFAULT_GRAPH), 1 (WILDCARD), and 2
(UNBOUND) taken; counter 3 and up are unassigned — but see STORE-T-0021,
which asks for the range above UNBOUND to be reserved for consumers. Whichever
way that goes, this sentinel should be allocated from the store's own end of
the space and the two decisions made together.

Both backends key their indexes graph-first, so the natural implementation is
"seek past the DEFAULT_GRAPH prefix and iterate the rest" rather than a
per-quad test.

### Dependencies

Coordinate with STORE-T-0021 (Sentinel range reservation) on which counter
this takes. Consumer: odin-rdf-sparql (`unify_quad`, `probe_pattern`).
Related: STORE-T-0016, the other half of the GRAPH story.

### Risk Considerations

A third graph-position sentinel is a third case every backend must get right,
and `pattern_matches` is the shared definition that keeps them honest — the
conformance suite has to cover the new case for all 16 pattern shapes, not
only the graph-varying ones.

## Status Updates **[REQUIRED]**

- **2026-08-05 — Created from odin-rdf-sparql SPARQL-T-0019**, the evaluation initiative's evidence consolidation. Awaiting pickup in an odin-rdf-store session.
- **2026-08-07 — memstore retired (STORE-A-0006, STORE-I-0003).** The Effort Estimate holds
  at S for the reason it gave, minus one backend: kvstore's indexes are graph-first, so
  "every graph except DEFAULT_GRAPH" is still a range skip rather than a filter. Only the
  "memstore's and kvstore's" phrasing is stale.
