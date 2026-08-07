---
id: proposal-to-odin-rdf-sparql-retire
level: task
title: "Proposal to odin-rdf-sparql: retire the memstore instantiation"
short_code: "STORE-T-0026"
created_at: 2026-08-07T16:22:22.000000+00:00
updated_at: 2026-08-07T16:22:22.000000+00:00
parent: STORE-I-0003
blocked_by: ["STORE-T-0025"]
archived: false

tags:
  - "#task"
  - "#phase/todo"


exit_criteria_met: false
initiative_id: STORE-I-0003
---

# Proposal to odin-rdf-sparql: retire the memstore instantiation

## Parent Initiative **[CONDITIONAL: Assigned Task]**

[[STORE-I-0003]]

## Objective **[REQUIRED]**

Raise the removal in odin-rdf-sparql, with the evidence, and let that repo decide and
sequence its own work. **This task delivers a proposal, not a port.** The port is an
initiative in odin-rdf-sparql's own `.metis`, created in a session in that checkout,
under that repo's short-code sequence.

That division is deliberate. Sibling repos are independently usable and own their own
decisions; a task in *this* repo's `.metis` cannot carry work that happens in theirs
without splitting the record across two visions. The family's own precedent is the reverse
direction: STORE-T-0019 exists because odin-rdf-sparql filed evidence upstream rather than
working around the gap. This is that pattern, downstream.

## Acceptance Criteria **[REQUIRED]**

- [ ] An initiative (or backlog item, at that repo's discretion) exists in
      odin-rdf-sparql's `.metis`, carrying: the decided single-backend ADR from
      STORE-T-0025 as the motivating decision, the measured footprint, and the sequencing
      constraint.
- [ ] The scope is stated accurately: `sparql/memstore` is **299 lines of code and 2,415
      lines of tests** across `eval.odin` plus five test files (`blocking_test`,
      `eval_test`, `forms_test`, `path_test`, `triple_terms_test`). The tests port; the
      code is deleted.
- [ ] The proposal states what does **not** change: the backend-independent core /
      thin-instantiation split stays (`sparql/kvstore` is its surviving instance), and no
      assertion is rewritten during the port — only backend setup and teardown.
- [ ] The sequencing constraint is explicit: odin-rdf-sparql must land its port **before**
      STORE-T-0030 deletes `store/memstore`, because the `store:` collection resolves to
      this checkout and the deletion breaks their build the instant it happens.
- [ ] Recorded in the proposal: **odin-rdf-sparql has no `bench/`**, so unlike
      odin-rdf-shacl there is no benchmark port on this side and no baseline to retire.
- [ ] Test-count parity before and after, at both `Term_ID` widths, is an exit criterion
      of *their* initiative — named here so it is not lost in the handoff.

## Implementation Notes **[CONDITIONAL: Technical Task]**

### Technical Approach

The port target already exists and is proven: `sparql/kvstore/eval.odin` is the same file
against the persistent backend, and the W3C evaluation harness
(`tests/w3c/harness/eval_runner.odin`, `dataset.odin`) already runs both backends. The
mechanical shape is store construction in test setup — and the temp-path boilerplate that
already exists in `store/kvstore/kvstore_test.odin` and `shacl/kvstore/link_test.odin`
will want a home rather than a third copy (see STORE-I-0003 Detailed Design point 3 on
`open_ephemeral`, which is optional and decided on exactly this evidence).

The 483 evaluation tests across 35 suite directories run through the harness rather than
per-test setup, so the harness change is likely one place, not 483.

### Dependencies

Blocked by STORE-T-0025 (the stance must be decided before it is proposed as decided).
Blocks STORE-T-0030 (deletion). Parallel with STORE-T-0027.

### Risk Considerations

The handoff is where this can quietly stall: a proposal filed in another repo's backlog is
not a commitment to do it, and STORE-T-0030 cannot proceed until it lands. Recommend
agreeing the sequencing explicitly at proposal time rather than discovering the block later.

## Status Updates **[REQUIRED]**

- **2026-08-07 — Created in STORE-I-0003's decomposition.**
