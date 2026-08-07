---
id: ordered-match-iteration-a
level: task
title: "Ordered match iteration: a documented order, and range reads over it"
short_code: "STORE-T-0015"
created_at: 2026-08-05T22:32:15.957952+00:00
updated_at: 2026-08-05T22:32:15.957952+00:00
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

# Ordered match iteration: a documented order, and range reads over it

## Objective **[REQUIRED]**

Give `match` a **documented iteration order** — the shared canonical order
STORE-A-0001 already defines and both backends already produce — and, on
top of it, a way to read a *range* of one position rather than all of it.

STORE-A-0002 v1 says ordering is unspecified and names this as an expected
revision ("ordered iteration, cardinality estimates for the planner"). This
is that revision, requested with the evidence the SPARQL evaluation engine
accumulated (odin-rdf-sparql SPARQL-I-0002, tasks T-0015 and T-0018).

**Evidence — four operators pay for the missing guarantee, all measured
against the W3C evaluation suites:**

1. **MIN / MAX over a plain variable** (`sparql/aggregate.odin`). Both are a
   full pass over the group to find the two ends of an order the store could
   have handed over for free. With an ordered iterator, `MIN(?o)` over a
   million solutions is the first quad of a range and one read.
2. **ORDER BY on a stored term** (`sparql/plan.odin`, `Plan_Order`). The sort
   is unavoidably blocking today: it holds every solution because the last
   one may sort first. Ordered by ID, an ORDER BY whose key is a bound
   variable would *stream* — the operator becomes a pass-through.
3. **Top-N** (`ORDER BY … LIMIT 10`) sorts everything. The shortcut needs
   either a bounded heap in the engine or an ordered iterator from the store;
   the second is the one worth having, because it also gives 1 and 2.
4. **Merge joins.** The engine's BGP evaluation is nested index probes with a
   naive as-written join order (the planner seam, `join_order` in
   `sparql/plan.odin`). Two ordered streams on a shared variable could be
   merged instead — the classic alternative — but only if the order is part
   of the contract rather than an accident of the current index layout.

A fifth, smaller: **streaming DISTINCT**. Deduplication currently retains a
key per distinct row (the one place the streaming path allocates, stated in
`exec.odin`); over an ordered stream it is a comparison with the previous
row.

## Backlog Item Details **[CONDITIONAL: Backlog Item]**

### Type
- [x] Feature - New functionality or enhancement

### Priority
- [x] P1 - High (important for user experience)

The single highest-value item in the SPARQL engine's evidence log: it is the
one capability that four separate operators independently asked for.

### Business Justification **[CONDITIONAL: Feature]**
- **User Value**: Aggregates and sorts over large datasets stop costing memory proportional to the answer. `MIN`/`MAX` become O(1) reads; `ORDER BY ?x` on a stored term streams; `ORDER BY … LIMIT n` stops after n.
- **Business Value**: Removes the largest gap between "correct" and "usable at scale" in the query engine, and unlocks the merge-join half of the planner that STORE-T-0017 (cardinality estimates) would otherwise have nothing to choose between.
- **Effort Estimate**: M for the guarantee, M–L for range reads. The *order* is arguably free — STORE-A-0001 fixes one canonical order, memstore's permutation indexes are sorted by it and kvstore's LMDB cursors iterate keys in it — so much of the work is deciding what to promise, pinning it in the conformance suite, and proving both backends already keep it.

## Acceptance Criteria **[REQUIRED]**

- [ ] `store/interface.odin` states the iteration order `match` guarantees, in terms of STORE-A-0001's canonical order and of the pattern's bound positions (a backend picks the permutation that serves the pattern; what a consumer may rely on is the order of the *unbound* positions).
- [ ] The conformance suite pins it: for each of the 16 bound/unbound pattern shapes, the yielded sequence is non-decreasing in the positions the contract names. Both backends instantiate it, at both Term_ID widths.
- [ ] A range read over one position — shape to be decided upstream; the consumer's need is "the first / last quad matching a pattern" and "quads whose position P is in [lo, hi)". The minimum useful subset is `match_first(ds, pattern)`, which alone answers MIN/MAX.
- [ ] STORE-A-0002 amended (or superseded) to record that v1's "no ordering guarantee" is replaced, with the reason and the consumer.

## Implementation Notes **[CONDITIONAL: Technical Task]**

### Technical Approach

The likely finding is that both backends already satisfy the guarantee and
the work is contract plus tests:

- memstore keeps GSPO/GPOS/GOSP permutation indexes and walks them in
  numeric ID order.
- kvstore's cursors walk LMDB keys in `memcmp` order over big-endian
  serialized IDs, which STORE-A-0001 chose *precisely* so that it equals
  numeric ID order.

The decision that needs making is what to promise: the full canonical
quad order, or the weaker and more implementable "non-decreasing in the
unbound positions, in the permutation the backend chose for this pattern".
The consumer needs the second; the first would over-constrain a future
backend.

### Dependencies

None. Consumer: odin-rdf-sparql (`sparql/aggregate.odin`, `sparql/plan.odin`,
`sparql/exec.odin`).

### Risk Considerations

Promising an order constrains every future backend, including the
time-travelling variant the vision anticipates. Mitigate by promising the
weakest order the consumer can use (per-pattern, unbound positions only)
rather than the strongest the current backends happen to produce.

## Status Updates **[REQUIRED]**

- **2026-08-05 — Created from odin-rdf-sparql SPARQL-T-0019**, the evaluation initiative's evidence consolidation. Awaiting pickup in an odin-rdf-store session.
- **2026-08-07 — memstore retired (STORE-A-0006, STORE-I-0003); the two-backend halves of
  this item are void.** The Effort Estimate's claim that the order is "arguably free" rested
  on both backends already keeping it — memstore's sorted permutation indexes *and* LMDB's
  cursor order. Only the LMDB half survives, and it survives intact: iteration order falls
  out of the big-endian key rule (STORE-A-0001 point 6), which is why the estimate's
  conclusion is unchanged even though half its evidence is gone. What is lost is the
  cross-check: agreement between two independent implementations was the reason to believe
  the order was a property of the *contract* rather than of LMDB. Deciding what to promise
  is now a decision about LMDB alone.
