---
id: port-the-stores-own-suite-off
level: task
title: "Port the store's own suite off memstore: conformance and round-trip"
short_code: "STORE-T-0028"
created_at: 2026-08-07T16:22:24.000000+00:00
updated_at: 2026-08-07T16:22:24.000000+00:00
parent: STORE-I-0003
blocked_by: ["STORE-T-0025"]
archived: false

tags:
  - "#task"
  - "#phase/todo"


exit_criteria_met: false
initiative_id: STORE-I-0003
---

# Port the store's own suite off memstore: conformance and round-trip

## Parent Initiative **[CONDITIONAL: Assigned Task]**

[[STORE-I-0003]]

## Objective **[REQUIRED]**

Move this repo's own memstore-bound tests onto kvstore, so that deleting the package
(STORE-T-0030) removes an implementation and not a body of coverage.

Two files, and they are not the same job:

- `conformance/memstore_test.odin` (118 lines) — the memstore instantiation of the shared
  suite. kvstore already has its own instantiation at
  `store/kvstore/conformance_test.odin`, so this one is genuinely redundant and is
  **deleted, not ported**. Worth confirming check-by-check first: the two instantiations
  live in different packages and could have drifted.
- `conformance/roundtrip_memstore_test.odin` (179 lines) — **has no kvstore counterpart.**
  This is the vision's round-trip success criterion ("load → match/export → compare
  preserves data semantics for all four formats") in executable form. It must be **ported**,
  and if it is dropped instead, a vision-level criterion silently stops being tested.

## Acceptance Criteria **[REQUIRED]**

- [ ] The memstore and kvstore conformance instantiations are compared check-by-check, and
      any check present only in the memstore one is carried over to kvstore's before the
      file is deleted. A drop found here is a defect, not a consolidation.
- [ ] `conformance/roundtrip_memstore_test.odin` runs against kvstore, covering all four
      formats as it does today, at both `Term_ID` widths.
- [ ] `conformance/memstore_test.odin` deleted; `conformance/{conformance,compare}.odin`
      and the `Backend` adapter retained unchanged — a single-backend suite is still the
      executable contract, and the adapter is what a future backend would fill.
- [ ] Test counts recorded before and after, at both widths. Consolidating two
      instantiations into one legitimately reduces the count; every reduction is named.
- [ ] The asymmetry is resolved or recorded: memstore's instantiation lives in
      `conformance/` while kvstore's lives in `store/kvstore/`. After this task the
      `conformance/` package holds a harness with no instantiation in it at all. Decide
      whether that is fine or whether the round-trip test should move next to kvstore's.
- [ ] `scripts/test.sh` / `make test` cover the changed layout; full suite green at both
      widths on all three CI platforms.

## Implementation Notes **[CONDITIONAL: Technical Task]**

### Technical Approach

The port is store construction, not assertion rewriting: `dictionary_init` + `dataset_init`
becomes `kvstore.open` against a temp path, and `dictionary_destroy` + `dataset_destroy`
becomes `close` plus directory removal. `store/kvstore/kvstore_test.odin` already has the
`temp_path` / `remove_test_db` helpers this needs.

Do the comparison of the two conformance instantiations *before* touching anything. The
whole point of STORE-A-0002's suite was that both backends run it verbatim; if that has
held, the deletion is safe and provable in one reading.

### Dependencies

Blocked by STORE-T-0025. Blocks STORE-T-0030. Independent of the sibling proposals — this
is entirely in-repo and can run in parallel with them.

### Risk Considerations

This is the task where coverage loss is most likely and least visible, because one of the
two files looks redundant and the other looks like more of the same. The round-trip test is
the one to watch: it is the only executable form of a vision success criterion, it has no
kvstore twin to fall back on, and its per-format loop is the kind of thing that gets quietly
narrowed during a port.

## Status Updates **[REQUIRED]**

- **2026-08-07 — Created in STORE-I-0003's decomposition.**
