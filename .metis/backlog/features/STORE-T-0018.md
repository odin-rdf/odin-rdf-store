---
id: cardinality-estimates-for-a-match
level: task
title: "Cardinality estimates for a match pattern, for the planner seam"
short_code: "STORE-T-0018"
created_at: 2026-08-05T22:35:15.736213+00:00
updated_at: 2026-08-05T22:35:15.736213+00:00
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

# Cardinality estimates for a match pattern, for the planner seam

## Objective **[REQUIRED]**

Let a consumer ask **roughly how many quads a pattern will match**, without
matching them.

STORE-A-0002 names this as an expected interface revision. This is the
request, with the seam that is waiting for it already built.

**Evidence.** odin-rdf-sparql evaluates a basic graph pattern as a chain of
index probes: for each pattern in join order, substitute what the row already
binds and match. The order of that chain is the whole of its planning policy,
and it lives in one procedure — `join_order` in `sparql/plan.odin` — which
today returns the identity permutation: the patterns in the order the query
wrote them.

That is a deliberate placeholder, and it is documented as one. Nothing above
it assumes the identity permutation; the procedure takes the BGP and returns
a permutation, and a cost-based ordering drops in without touching an
operator. What it needs is a number: for
`{ ?s :type :Person . ?s :name "Alice" }`, is the first pattern a thousand
quads and the second one, or the other way round? Getting that backwards
turns a two-probe join into a full scan of the wrong side, and the engine has
no way to tell — a plan today is as good as the order the user typed.

The engine deliberately did *not* guess: guessing selectivity from pattern
shape alone (bound-position counts, a predicate heuristic) is a well-known
way to be confidently wrong, and the vision's answer is that the store is
where the counts live.

## Backlog Item Details **[CONDITIONAL: Backlog Item]**

### Type
- [x] Feature - New functionality or enhancement

### Priority
- [x] P2 - Medium (nice to have)

Correctness does not depend on it — every suite is green with the naive
order. It is the difference between a query engine and a fast one, on
datasets larger than the suites.

### Business Justification **[CONDITIONAL: Feature]**
- **User Value**: A join order chosen from the data rather than from the query text. On real datasets this is routinely the difference between milliseconds and minutes.
- **Business Value**: Activates a seam the SPARQL engine already built and left empty; the alternative (heuristics in the engine) would be both worse and duplicated in every consumer.
- **Effort Estimate**: M. An exact count for a fully bound pattern is a lookup; for a pattern with unbound positions it is a range size, which memstore can compute from its sorted indexes and kvstore can approximate from LMDB page counts or from per-position counters maintained on insert.

## Acceptance Criteria **[REQUIRED]**

- [ ] `estimate(ds, pattern) -> int` (name and exactness per family convention): approximately how many quads the pattern matches. The contract states what "approximately" is allowed to mean — the useful promise is a *relative* one, that estimates of two patterns over the same dataset order the same way their true counts do, rather than an absolute accuracy bound.
- [ ] Cheap enough to call once per triple pattern at query setup: no scan, no allocation proportional to the answer. A consumer that has to pay a scan to plan a scan will not call it.
- [ ] A read: no assignment, no write transaction, correct against a read-only environment — the `find_term` posture from STORE-T-0014.
- [ ] Conformance suite pins the *ordering* property rather than exact values: over a dataset with a deliberately skewed predicate distribution, the estimates rank the 16 pattern shapes the way the true counts do.
- [ ] `store/interface.odin` documents it, including the "estimates may be wrong, plans must still be correct" rule — nothing about a plan's correctness may depend on the number.

## Implementation Notes **[CONDITIONAL: Technical Task]**

### Technical Approach

The cheap and honest version is a range size over the permutation index that
best serves the pattern: memstore can binary-search its sorted index for the
bounds of the matching prefix and subtract; kvstore has the same shape over
LMDB keys, and `mdb_cursor_count`/page statistics if a coarser answer is
acceptable.

Per-position counters maintained on insert (how many quads have predicate P)
are the other classic answer and are cheaper to read, at the cost of write
throughput and of being stale after deletes when those exist.

### Dependencies

None. Consumer: odin-rdf-sparql (`join_order` in `sparql/plan.odin`, which is
the single procedure that would consume it).
Related: STORE-T-0015 — an ordered iterator gives the planner a *second*
strategy (merge joins) to choose between; estimates without alternatives to
choose between are half a planner.

### Risk Considerations

The temptation is to promise accuracy. Promise ranking instead: a consumer
uses this to order patterns, and an estimate that is wrong by a factor but
right in its ordering costs nothing.

## Status Updates **[REQUIRED]**

- **2026-08-05 — Created from odin-rdf-sparql SPARQL-T-0019**, the evaluation initiative's evidence consolidation. Awaiting pickup in an odin-rdf-store session.
- **2026-08-07 — memstore retired (STORE-A-0006, STORE-I-0003), and this item loses its
  easy half.** The estimate paired an exact answer from memstore's sorted indexes with an
  approximation from LMDB page counts or per-position counters. Only the approximation
  remains, which makes the interface question sharper rather than softer: with one backend
  there is no longer an implementation that could return an exact count, so whatever this
  procedure promises must be satisfiable by an estimate. Worth settling before the planner
  binds to it.
