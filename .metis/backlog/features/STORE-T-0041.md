---
id: proposals-to-shacl-and-sparql-bind
level: task
title: "Proposals to odin-rdf-shacl and odin-rdf-sparql: bind reads to a transaction"
short_code: "STORE-T-0041"
created_at: 2026-08-07T22:15:28.000000+00:00
updated_at: 2026-08-07T22:15:28.000000+00:00
parent: 
blocked_by: ["STORE-T-0037"]
archived: false

tags:
  - "#task"
  - "#feature"
  - "#phase/backlog"


exit_criteria_met: false
initiative_id: NULL
---

# Proposals to odin-rdf-shacl and odin-rdf-sparql: bind reads to a transaction

## Objective **[REQUIRED]**

File the evidence upstream-to-downstream, the way STORE-T-0026 and STORE-T-0027 did for the
memstore retirement. Scoped inside [[STORE-I-0004]] and moved here unstarted when that
initiative closed — it was never one of its exit criteria, because STORE-A-0007 puts the
sibling changes in those repos rather than this one. **Those repos own their own decisions and short-code sequences**; this
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

## Backlog Item Details **[CONDITIONAL: Backlog Item]**

### Type
- [x] Feature - New functionality or enhancement

### Priority
- [x] P1 - High (important for user experience)

The shacl half is what actually closes odin-rdf-app's P0, so it is higher than the P2 its
sparql half would carry alone. It is not P0 itself because the fix is not this repo's to make
— odin-rdf-store's half shipped in v0.3.0.

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
- [ ] **Neither implementation is an exit criterion of anything here.** This item is complete
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

- **2026-08-08 — Moved to the backlog, unstarted, when STORE-I-0004 closed.** Not a
  demotion and not a deferral by neglect: this task was never an exit criterion of that
  initiative, deliberately, because STORE-A-0007 says the sibling changes are "changes in
  *those* repos, to be raised there as proposals once this handle exists — not made here."
  The handle now exists and is released as v0.3.0, so the proposals are exactly as ready as
  they were; what has changed is only that the initiative around them is finished.

  Rehomed rather than left as a child of a completed initiative, which mirrors STORE-I-0003
  filing `open_ephemeral` as STORE-T-0033 rather than archiving the question together with
  its own evidence. The evidence here is the same shape, and it is worth restating in one
  place so it does not have to be reconstructed from a closed initiative:

  **odin-rdf-shacl is the one that matters, and it is unfinished business rather than an
  enhancement.** odin-rdf-store now makes validate-before-commit *possible*; it does not make
  it *reachable*. `odin-rdf-app` validates a candidate with SHACL, and shacl reads the data
  graph through its `Access` adapters, which bind to a bare store. Until they can bind to a
  `^Txn`, a validator still cannot see the write it is deciding about — the store has fixed
  its half and the P0 gap is still open at the application. Anyone reading STORE-I-0004 as
  having delivered validate-before-commit end to end is reading it wrong, and this item is
  the reason.

  **odin-rdf-sparql's is real but has no urgency.** A read transaction taken at `query_init`
  and released at `query_destroy` — exactly the lifetime a `Query` already has — makes a
  query's answer an answer about one dataset. Nothing is wrong today because the suites are
  single-threaded; it becomes wrong the day anything writes concurrently.

  **Still needs raising before filing**, per the family's convention on touching sibling
  repos. Worth pairing with the other outstanding sibling proposal when it is: nine copies of
  the temp-path dance await `open_ephemeral` (STORE-T-0033), and that is where the Windows CI
  minutes actually are — shacl 211s, sparql >20 min, against this repo's 41s. Two proposals
  per sibling, one conversation.
