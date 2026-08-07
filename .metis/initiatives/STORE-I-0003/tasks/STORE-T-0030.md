---
id: delete-store-memstore
level: task
title: "Delete store/memstore"
short_code: "STORE-T-0030"
created_at: 2026-08-07T16:22:26.000000+00:00
updated_at: 2026-08-07T16:22:26.000000+00:00
parent: STORE-I-0003
blocked_by: ["STORE-T-0026", "STORE-T-0027", "STORE-T-0028", "STORE-T-0029"]
archived: false

tags:
  - "#task"
  - "#phase/todo"


exit_criteria_met: false
initiative_id: STORE-I-0003
---

# Delete store/memstore

## Parent Initiative **[CONDITIONAL: Assigned Task]**

[[STORE-I-0003]]

## Objective **[REQUIRED]**

Remove the package. This is the smallest task in the initiative and the only irreversible
one, and it is gated on all four ports because the `store:` collection resolves to *this*
checkout: the moment `store/memstore` disappears, any sibling still importing it stops
building.

832 lines of code and 601 lines of tests, in `store/memstore/{memstore,dictionary,dataset,index,load}.odin`
and their `_test` siblings.

## Acceptance Criteria **[REQUIRED]**

- [ ] Verified before deleting: nothing in odin-rdf-store, odin-rdf-sparql, or
      odin-rdf-shacl imports `store/memstore` — checked against the sibling **checkouts**,
      not against an assumption that their initiatives landed.
- [ ] `store/memstore/` removed in full.
- [ ] `Makefile`, `scripts/test.sh`, `ols.json`, and any `-collection` declarations updated
      so no target references the package.
- [ ] `make test` green at both `Term_ID` widths; `make check` vets every remaining
      package; `make bench` builds.
- [ ] CI green on Linux, macOS, and Windows — the platform where kvstore's filesystem work
      is least exercised and where the suite's new shape is most likely to surprise.
- [ ] The sibling checkouts still build against this one, verified rather than assumed.

## Implementation Notes **[CONDITIONAL: Technical Task]**

### Technical Approach

`grep -rl "store/memstore\|store:store/memstore"` across all three checkouts is the gate.
Run it, confirm empty, then delete in one commit so the repo never sits in a half-removed
state.

Keep `store/` (the vocabulary core), `store/kvstore/`, and `conformance/` — the ADR from
STORE-T-0025 commits to retaining the `Backend` adapter so a future backend can be added
without archaeology.

### Dependencies

Blocked by all four ports: STORE-T-0026 and STORE-T-0027 (sibling repos, and the ones this
initiative does not control), STORE-T-0028 (this repo's suite), STORE-T-0029 (bench).
Blocks STORE-T-0031 and STORE-T-0032.

### Risk Considerations

The two sibling blockers are proposals, not commitments — this task can be ready for weeks
while waiting on repos that have their own priorities. That is a scheduling risk to surface
early rather than a technical one.

Irreversibility is nominal: it is a git revert away until released. The genuinely
irreversible moment is the release decision in STORE-T-0031.

## Status Updates **[REQUIRED]**

- **2026-08-07 — Created in STORE-I-0003's decomposition.**
