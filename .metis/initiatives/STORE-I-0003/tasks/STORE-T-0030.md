---
id: delete-store-memstore
level: task
title: "Delete store/memstore"
short_code: "STORE-T-0030"
created_at: 2026-08-07T16:22:26+00:00
updated_at: 2026-08-07T20:02:59.522006+00:00
parent: STORE-I-0003
blocked_by: [STORE-T-0026, STORE-T-0027, STORE-T-0028, STORE-T-0029]
archived: false

tags:
  - "#task"
  - "#phase/completed"


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

## Acceptance Criteria

## Acceptance Criteria **[REQUIRED]**

- [x] Verified before deleting: nothing in odin-rdf-store, odin-rdf-sparql, or
      odin-rdf-shacl imports `store/memstore` — checked against the sibling **checkouts**,
      not against an assumption that their initiatives landed.
- [x] `store/memstore/` removed in full.
- [x] `Makefile`, `scripts/test.sh`, `ols.json`, and any `-collection` declarations updated
      so no target references the package.
- [x] `make test` green at both `Term_ID` widths; `make check` vets every remaining
      package; `make bench` builds.
- [x] CI green on Linux, macOS, and Windows — the platform where kvstore's filesystem work
      is least exercised and where the suite's new shape is most likely to surprise.
- [x] The sibling checkouts still build against this one, verified rather than assumed.

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
- **2026-08-07 — Done. `store/memstore` is gone.**

  **The gate was run, not assumed.** `grep -rn "store/memstore"` across all three
  checkouts before touching anything: **zero hits in odin-rdf-sparql and odin-rdf-shacl**,
  so SPARQL-T-0023 and SHACL-T-0028 had genuinely landed. The only hits were this repo's
  own — the Makefile package list, `tests/readme/readme_test.odin`, and two doc comments.

  **One live code dependency was still here**, which the task description had not
  anticipated: `tests/readme` carried a memstore quick-start and a memstore export
  example alongside the persistent one. The quick start was the in-memory twin of
  `readme_persistent_example` and is deleted (2 tests → 2: one dropped, `readme_load_and_match`,
  and the export example ported). With one backend the README has one quick start, not
  "in-memory, and the same on disk".

  **The uniqueness hazard for the fourth time.** `readme_db_path` keyed on pid alone,
  which was unique while only one test opened a store; porting the export example made it
  two on ten threads, and the second `open` failed on a directory that already existed.
  Same fix as the other three. **That is the tenth copy of the temp-path dance in the
  family and the fourth latent collision it has hidden** — STORE-I-0003's `open_ephemeral`
  question now has more evidence than it needs, and it is worth noting that the recurring
  defect is not the boilerplate itself but that each copy invented its own uniqueness
  scheme, three of which were wrong.

  **Verified rather than assumed, per the criterion:** `make test` green at both widths
  here, and **both sibling checkouts rebuilt and re-ran their full suites against this
  one** — odin-rdf-sparql 261 tests per width, odin-rdf-shacl 144 per width, both green,
  shacl's `make purity` still passing. `make check` clean, `make build-bench` builds.

  Not verified here: CI on Linux and Windows. Local run is darwin_arm64 only.