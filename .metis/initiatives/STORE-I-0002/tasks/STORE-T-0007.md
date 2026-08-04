---
id: vendor-lmdb-binding-environment
level: task
title: "Vendor LMDB binding; environment, meta schema, and options skeleton"
short_code: "STORE-T-0007"
created_at: 2026-08-04T21:11:22.477241+00:00
updated_at: 2026-08-04T21:11:22.477241+00:00
parent: STORE-I-0002
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/todo"


exit_criteria_met: false
initiative_id: STORE-I-0002
---

# Vendor LMDB binding; environment, meta schema, and options skeleton

## Parent Initiative **[CONDITIONAL: Assigned Task]**

[[STORE-I-0002]]

## Objective **[REQUIRED]**

Vendor the LMDB binding into this repo and stand up the `store_lmdb` package skeleton: environment lifecycle, the six named DBs, the `meta` schema with format/width enforcement per STORE-A-0003, and the Options struct. After this task the persistent store opens, initializes, reopens, and rejects mismatched databases — with no data operations yet.

## Acceptance Criteria **[REQUIRED]**

- [ ] `vendor/lmdb/` contains `lmdb.odin` + `liblmdb_darwin_arm64.a` copied from odin-vengine, with a provenance note recording the source, that the linked library is LMDB 0.9.35, and the development-branch-only symbols that must never be called (STORE-I-0002 context).
- [ ] `store_lmdb/` package builds on darwin_arm64 and imports `vendor/lmdb` and the core `store` package (for `Term_ID`/`Encoded_Quad`); the core `store` package itself remains free of C dependencies (verified: `odin build store` needs no linker input).
- [ ] `Options` struct: `map_size` (default 1 GiB), `max_readers`, `no_sync`, `read_only`; `store_init`/`store_destroy` (final names per package conventions) follow the production idioms: create the directory when needed, `env_create` → `set_maxdbs`/`set_mapsize`/`set_maxreaders` → `env_open` with `NOTLS` (+`NOSYNC`/`RDONLY` per options).
- [ ] All six named DBs (`meta`, `id2term`, `term2id`, `gspo`, `gpos`, `gosp`) opened/created in one setup transaction; on a fresh environment, `meta` is initialized per STORE-A-0003 §1 (`format`=1, `term_id_bits`=running width, four counters=0), all values 8-byte big-endian.
- [ ] Reopen validates `format` and `term_id_bits`; an unknown format or a width differing from the running build aborts the open with a distinct, specific error — pinned by tests that corrupt/rewrite the meta values directly through the binding to simulate both mismatches.
- [ ] Error mapping: a `check(rc)`-style helper wrapping raw LMDB return codes into the package's error union, preserving the code for `strerror` rendering.
- [ ] `scripts/test.sh` runs the `store_lmdb` tests at both Term_ID widths alongside the core suite; open/init/reopen/reject tests green at both.

## Implementation Notes **[CONDITIONAL: Technical Task]**

### Technical Approach
Test databases go in per-test temp directories, removed on teardown. Meta values use the format's big-endian rule (format rule zero) — note this deliberately differs from odin-vengine's little-endian meta values; the idiom is borrowed, not the bytes. Only 0.9 API symbols are called anywhere in the package.

### Dependencies
None within the initiative (first task; parallel with STORE-T-0008). Governed by STORE-A-0003 §1 and STORE-I-0002 decisions 1 and 7.

### Risk Considerations
The width-mismatch test cannot run two build widths in one binary — simulate by rewriting the `term_id_bits` meta value in place and re-opening. Static lib/link flags are the likeliest platform friction; keep all foreign-import configuration in one file.

## Status Updates **[REQUIRED]**

*To be added during implementation*