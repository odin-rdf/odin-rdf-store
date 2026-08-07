---
id: adr-the-single-backend-stance-and
level: task
title: "ADR: the single-backend stance, and the vision retraction it forces"
short_code: "STORE-T-0025"
created_at: 2026-08-07T16:22:21.351434+00:00
updated_at: 2026-08-07T16:40:38.570392+00:00
parent: STORE-I-0003
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/completed"


exit_criteria_met: false
initiative_id: STORE-I-0003
---

# ADR: the single-backend stance, and the vision retraction it forces

## Parent Initiative **[CONDITIONAL: Assigned Task]**

[[STORE-I-0003]]

## Objective **[REQUIRED]**

Decide, in writing, that odin-rdf-store is a **single-backend library over LMDB**, and
settle everything that decision invalidates. Nothing else in this initiative may start
until it is decided: every other task is an act of carrying it out.

The substance is not "delete a package" — it is that **the match interface's contract
becomes LMDB's semantics by definition**. There is no second implementation to disagree
with it, so the costs the archived STORE-A-0005 recorded as backend detail (an open read
transaction pins pages against a concurrent writer; an open write transaction holds the
environment writer lock) stop being a backend's price and become the interface's.

This task also carries the **vision retraction**, deliberately rather than deferring it to
the documentation sweep: STORE-V-0001 claims "multiple backends of one interface" in its
Product/Solution Overview, Major Features, Success Criteria, *and* Current State. That is a
strategic claim being withdrawn, and it should be reviewed with its reasoning attached
rather than as a docs cleanup three tasks later.

## Acceptance Criteria

## Acceptance Criteria **[REQUIRED]**

- [x] A new ADR records the single-backend stance: what it decides, why the absence of
      consumer evidence is grounds for shrinking under the vision's own "grows on
      evidence" principle, and what is given up.
- [x] The ADR states plainly that the conformance suite stops being a portability proof
      and becomes a regression suite — the vision's own framing was that one suite passing
      verbatim against two backends is "what makes 'multiple backends of one interface' a
      demonstration rather than a claim."
- [x] **STORE-A-0002 amended for its demonstration claim.** The convention itself
      (procedure sets, no vtable, points 1, 2, 4, 5, 6) is unchanged and still correct;
      point 3's premise is what fails.
- [x] **The archived STORE-A-0005's capability-tier amendment to STORE-A-0002 is NOT
      applied.** Two edits to that ADR are outstanding and they are mutually exclusive —
      with one backend there are no capability branches to qualify point 3 with. Confirm
      explicitly that only this task's amendment landed.
- [x] STORE-I-0001's reference-implementation framing is addressed: the interface was
      defined *against* memstore, and that history should be recorded as history rather
      than silently contradicted.
- [x] STORE-V-0001 edited: Product/Solution Overview, Major Features, Success Criteria
      ("The in-memory backend passes a store test suite…"), and Current State. The vision
      is `#phase/published`, so this is an edit to a published document and needs sign-off.
- [x] The ADR states that a second backend remains welcome, and that `conformance/`'s
      `Backend` adapter is retained precisely so one can be added without archaeology.

## Implementation Notes **[CONDITIONAL: Technical Task]**

### Technical Approach

Write the ADR first, get it decided, then apply the STORE-A-0002 amendment and the vision
edits in the same change so the record moves together.

The honest framing for the ADR's Consequences: this is not a loss of capability, it is a
loss of *evidence*. Nothing a consumer could do stops working. What stops is the mechanism
that would catch the interface drifting into LMDB-shaped assumptions — and the correct
response is to say so, not to claim the suite still proves what it proved yesterday.

### Dependencies

Blocks every other task in the initiative. Depends on nothing.

### Risk Considerations

The vision is published and its Current State section is written as an accomplishment
record ("Every success criterion is met (2026-08-06)"). Editing it to retract a success
criterion is the kind of change that is easy to do badly — either by deleting the history
or by leaving a claim that is no longer true. Recommend amending in place with dates
rather than rewriting, matching how STORE-A-0002's own Amendments section works.

## Status Updates **[REQUIRED]**

- **2026-08-07 — Created in STORE-I-0003's decomposition.**
- **2026-08-07 — Done, pending sign-off on the vision edit.** STORE-A-0006 drafted (`#phase/draft`,
  undecided). Amendments applied: STORE-A-0002 (point 3's *premise* fails, not its mechanism; the
  archived STORE-A-0005's competing amendment explicitly declared void in the same entry),
  STORE-A-0001 point 7 (cross-backend iteration-order agreement annotated historical; kvstore's
  order stands on the big-endian key rule alone, so STORE-T-0015 is unaffected), STORE-I-0001
  (reference-implementation framing recorded as history — the interface outlived its reference,
  which is what that arrangement was for).

  STORE-V-0001 edited in seven places: Purpose, Product/Solution Overview, Current State (dated
  amendment block, leaving the 2026-08-06 accomplishment paragraph standing as record), Future
  State, Major Features, Success Criteria, Constraints. Every edit is dated and annotated rather
  than rewritten; no history was deleted. The Constraints edit is the one carrying new substance —
  LMDB stops being "isolated, optional" and becomes unconditional, and "every dataset is a
  filesystem path" is now a vision-level constraint.

  **Family-wide finding**, made from the checkout root: both sibling visions carry a *success
  criterion* this decision falsifies — odin-rdf-shacl's "the same shapes validate in-memory and
  LMDB-backed data identically" and odin-rdf-sparql's "in-memory and LMDB behave identically apart
  from performance". Named in STORE-A-0006 and to be carried by STORE-T-0026/0027; a code port that
  leaves a falsified criterion standing in a published vision is an incomplete port.