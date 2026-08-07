---
id: proposal-to-odin-rdf-shacl-retire
level: task
title: "Proposal to odin-rdf-shacl: retire the memstore instantiation, rehome compile_turtle, settle purity"
short_code: "STORE-T-0027"
created_at: 2026-08-07T16:22:23.000000+00:00
updated_at: 2026-08-07T16:22:23.000000+00:00
parent: STORE-I-0003
blocked_by: ["STORE-T-0025"]
archived: false

tags:
  - "#task"
  - "#phase/todo"


exit_criteria_met: false
initiative_id: STORE-I-0003
---

# Proposal to odin-rdf-shacl: retire the memstore instantiation, rehome compile_turtle, settle purity

## Parent Initiative **[CONDITIONAL: Assigned Task]**

[[STORE-I-0003]]

## Objective **[REQUIRED]**

Raise the removal in odin-rdf-shacl with the evidence, and hand over the three decisions
that are theirs to make. **This task delivers a proposal, not a port** — the work is an
initiative in odin-rdf-shacl's own `.metis`, as for STORE-T-0026.

This is the larger of the two proposals and the only one carrying decisions beyond a
mechanical port. odin-rdf-shacl is where every non-test dependant of memstore in the family
lives.

## Acceptance Criteria **[REQUIRED]**

- [ ] An initiative exists in odin-rdf-shacl's `.metis` carrying the decided ADR from
      STORE-T-0025, the footprint (**528 lines of code, 3,540 lines of tests**), and the
      sequencing constraint against STORE-T-0030.
- [ ] **`compile_turtle` is re-signed to take the caller's store**, per STORE-I-0003
      Detailed Design point 2:
      `compile_turtle(s, st: ^kvstore.Store, source, graph: rdf.Graph_Label = nil, base, allocator)`.
      The proposal must carry *why*: today's version silently owns a database, which was
      tolerable when the database was a hash map; and its own doc comment's stated reason
      for living in an instantiation package ("keeps LMDB out of the link of every consumer
      that only wants an in-memory store") dies with memstore.
- [ ] **The compile-once contract and its reason are in the proposal**, because the
      failure is silent. `load_turtle` applies per-load blank-node scoping
      (`fresh_blank_txn`), and shapes graphs are blank-node dense, so reloading the same
      shapes into the same named graph does **not** dedupe — repeated loads accumulate a
      second copy of every blank-node-rooted shape and a later compile sees duplicated
      shapes. Contract: load at startup, keep the `Shapes` value (it outlives the store by
      design, SHACL-A-0001), never recompile per request. Relaxes when STORE-T-0023
      (`remove`) lands.
- [ ] **The `purity` target's fate is decided**, not left broken. Three options, theirs to
      pick: delete it; retarget it at the `shacl` core package alone (still catches a stray
      `kvstore` import, still meaningful as internal hygiene, but no longer protects a
      consumer); or retire it with an amendment. Recommend the second **plus** amending
      SHACL-A-0001 decision 1, whose recorded justification is exactly the property that
      evaporates.
- [ ] **The benchmark port is scoped honestly as a changed measurement, not a port.**
      `bench/consumers.odin` uses memstore *deliberately* — its own comment: "memstore only,
      deliberately. The question is what *this engine* allocates, and on kvstore every
      figure would carry LMDB's page handling and term [decoding]." That reason is real:
      memstore's `lookup_term` borrows from dictionary storage and allocates nothing, while
      kvstore's copies every string into the caller's allocator. Decision taken in
      STORE-I-0003: **port it, accept that the figures now include term materialization,
      and say so** — arguably the more honest number, since every real consumer pays it.
      The historical figures are not comparable and must be marked as such rather than left
      looking like a regression.
- [ ] Recorded as lost, not silently dropped: `bench/main.odin`'s cross-backend
      comparisons — the timing comparison between the two instantiations, and the invariant
      it asserts that "the read count is identical on memstore and kvstore."
- [ ] Test-count parity before and after at both widths is an exit criterion of their
      initiative. Note that shacl's kvstore-side count goes from **14 to ~85**, so this
      port is also a coverage expansion on a path that has been much thinner.

## Implementation Notes **[CONDITIONAL: Technical Task]**

### Technical Approach

`shacl/kvstore` already has every piece the port needs, including the pattern that replaces
`compile_turtle`'s private store — from `Session`'s own doc: "A caller whose shapes and data
live in different graphs of one store uses two Sessions over the same store, which is a
struct rather than a handle and costs nothing." The shapes-in-a-named-graph shape was
already designed on that side; this proposal only makes it the only shape.

Files: `shacl/memstore/{memstore,compile,eval,validate,report}.odin` delete;
`{compile,eval,link,target,validate}_test.odin` port; `bench/{consumers,access,config,instrument,main}.odin`
and `tests/{purity,readme,guards}/`, `tests/w3c/harness/runner.odin` all reference memstore
and need triage.

### Dependencies

Blocked by STORE-T-0025. Blocks STORE-T-0030. Parallel with STORE-T-0026.

### Risk Considerations

Three decisions in one handoff is where scope gets dropped. The one most likely to be
skipped is the compile-once contract, because it is a doc comment rather than code and the
failure it prevents is silent and slow. The one most likely to be contested is
`compile_turtle`'s signature — a caller with a shapes file and no database now needs a
store, which is the right boundary but a real ergonomic change.

## Status Updates **[REQUIRED]**

- **2026-08-07 — Created in STORE-I-0003's decomposition.**
