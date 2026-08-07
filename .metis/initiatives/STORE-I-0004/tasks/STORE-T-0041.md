---
id: proposals-to-shacl-and-sparql-bind
level: task
title: "Proposals to odin-rdf-shacl and odin-rdf-sparql: bind reads to a transaction"
short_code: "STORE-T-0041"
created_at: 2026-08-07T22:15:28.000000+00:00
updated_at: 2026-08-07T22:15:28.000000+00:00
parent: STORE-I-0004
blocked_by: ["STORE-T-0037"]
archived: false

tags:
  - "#task"
  - "#phase/todo"


exit_criteria_met: false
initiative_id: STORE-I-0004
---

# Proposals to odin-rdf-shacl and odin-rdf-sparql: bind reads to a transaction

## Parent Initiative

[[STORE-I-0004]]

## Objective **[REQUIRED]**

File the evidence upstream-to-downstream, the way STORE-T-0026 and STORE-T-0027 did for the
memstore retirement. **Those repos own their own decisions and short-code sequences**; this
task supplies the argument and the call sites and does not edit them.

The two proposals are not the same argument, and that is why the task writes both rather than
one:

- **odin-rdf-shacl — this is what actually closes the P0.** The store's handle makes
  validate-before-commit *possible*; it does not make it *reachable*. `odin-rdf-app` validates
  a candidate with SHACL, and shacl reads the data graph through the match interface alone via
  its `Access` adapters, which today bind to a bare store. Until they can bind to a `^Txn`, a
  validator still cannot see the write it is deciding about — the store has fixed its half and
  the gap is still open at the application. SHACL-A-0001's ownership property is unaffected:
  the shapes model owns every term it holds and outlives the store it compiled from, so binding
  the *data* side to a transaction changes nothing about the shapes side.
- **odin-rdf-sparql — the correctness-under-concurrency one, with no urgency.** STORE-T-0019's
  original evidence: a query reads the store in five distinct places and nothing makes those
  five an answer about one dataset. The fix is one line of lifetime — take a read transaction at
  `query_init`, release it at `query_destroy`, which is **exactly the lifetime a `Query`
  already has**. Nothing is wrong today because the suites are single-threaded; it becomes
  wrong the day anything writes concurrently.

## Acceptance Criteria **[REQUIRED]**

- [ ] A backlog item filed in **odin-rdf-shacl**'s `.metis/` proposing that the `Access`
      adapters bind to a `^Txn` rather than a bare store, carrying: the validate-before-commit
      evidence from STORE-T-0022, the published handle's shape, the named call sites, and the
      **cost stated as contract** — a write transaction held across an entire validation
      serializes every other writer against that environment for its lifetime, by construction.
- [ ] A backlog item filed in **odin-rdf-sparql**'s `.metis/` proposing a read transaction
      taken at `query_init` and released at `query_destroy`, carrying STORE-T-0019's five-read
      evidence, the `NOW()` precedent the item itself cites (a query's answer is a snapshot
      rather than a smear, at the clock instead of at the data), and the page-pinning cost.
- [ ] Both proposals state explicitly that they are **additive on those sides too** — the bare
      procedures survive, so an adapter that does not take a transaction keeps working.
- [ ] Both name the store version that publishes the handle, so the pin is unambiguous.
- [ ] **Neither implementation is an exit criterion of STORE-I-0004.** This task is complete
      when the proposals are filed; the sibling work is theirs to sequence.
- [ ] **Raised with Greger before filing.** Filing in a sibling repo is the intended channel
      for a cross-repo proposal, and it is still raised first.

## Implementation Notes **[CONDITIONAL: Technical Task]**

### Technical Approach

Read the call sites before writing either proposal — a proposal that names files and
procedures is the one that gets picked up, and both siblings' upstream reports (SHACL-T-0028,
SPARQL-T-0023) set that standard when they reported the temp-path duplication.

For shacl: the `Access` adapters in `shacl/kvstore`, and `Session`, which is a struct rather
than a handle and costs nothing to hold — the natural place a transaction would live.
For sparql: `sparql/plan.odin` (term binding), `sparql/exec.odin` (matching), the
materialization sites at the answer boundary and inside expression evaluation, and the
triple-term decomposition path.

### Dependencies

Blocked by STORE-T-0037 — `match_txn` is the procedure both proposals are actually asking to
be given, so the proposals should describe it as it shipped rather than as designed. Blocks
nothing here.

### Risk Considerations

The risk is proposing a change that reads well and costs those repos a redesign. Both are
believed to be small — sparql's is the lifetime a `Query` already has, shacl's is a field on a
struct it already threads — but "believed to be small" from the upstream side is exactly the
claim STORE-I-0003 was careful not to make on the siblings' behalf. State the estimate as an
estimate.

## Status Updates **[REQUIRED]**

*To be added during implementation*
