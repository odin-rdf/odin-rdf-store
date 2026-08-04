---
id: vendor-lmdb-binding-environment
level: task
title: "Vendor LMDB binding; environment, meta schema, and options skeleton"
short_code: "STORE-T-0007"
created_at: 2026-08-04T21:11:22.477241+00:00
updated_at: 2026-08-04T21:28:19.389589+00:00
parent: STORE-I-0002
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/completed"


exit_criteria_met: false
initiative_id: STORE-I-0002
---

# Vendor LMDB binding; environment, meta schema, and options skeleton

## Parent Initiative **[CONDITIONAL: Assigned Task]**

[[STORE-I-0002]]

## Objective **[REQUIRED]**

Vendor the LMDB binding into this repo and stand up the `store_lmdb` package skeleton: environment lifecycle, the six named DBs, the `meta` schema with format/width enforcement per STORE-A-0003, and the Options struct. After this task the persistent store opens, initializes, reopens, and rejects mismatched databases — with no data operations yet.

## Acceptance Criteria

## Acceptance Criteria

## Acceptance Criteria **[REQUIRED]**

- [x] `vendor/lmdb/` contains `lmdb.odin` + `liblmdb_darwin_arm64.a` copied from odin-vengine, with a provenance note recording the source, that the linked library is LMDB 0.9.35, and the development-branch-only symbols that must never be called (STORE-I-0002 context).
- [x] `store_lmdb/` package builds on darwin_arm64 and imports `vendor/lmdb` and the core `store` package (for `Term_ID`/`Encoded_Quad`); the core `store` package itself remains free of C dependencies (verified: `odin build store` needs no linker input).
- [x] `Options` struct: `map_size` (default 1 GiB), `max_readers`, `no_sync`, `read_only`; `store_init`/`store_destroy` (final names per package conventions) follow the production idioms: create the directory when needed, `env_create` → `set_maxdbs`/`set_mapsize`/`set_maxreaders` → `env_open` with `NOTLS` (+`NOSYNC`/`RDONLY` per options).
- [x] All six named DBs (`meta`, `id2term`, `term2id`, `gspo`, `gpos`, `gosp`) opened/created in one setup transaction; on a fresh environment, `meta` is initialized per STORE-A-0003 §1 (`format`=1, `term_id_bits`=running width, four counters=0), all values 8-byte big-endian.
- [x] Reopen validates `format` and `term_id_bits`; an unknown format or a width differing from the running build aborts the open with a distinct, specific error — pinned by tests that corrupt/rewrite the meta values directly through the binding to simulate both mismatches.
- [x] Error mapping: a `check(rc)`-style helper wrapping raw LMDB return codes into the package's error union, preserving the code for `strerror` rendering.
- [x] `scripts/test.sh` runs the `store_lmdb` tests at both Term_ID widths alongside the core suite; open/init/reopen/reject tests green at both.

## Implementation Notes **[CONDITIONAL: Technical Task]**

### Technical Approach
Test databases go in per-test temp directories, removed on teardown. Meta values use the format's big-endian rule (format rule zero) — note this deliberately differs from odin-vengine's little-endian meta values; the idiom is borrowed, not the bytes. Only 0.9 API symbols are called anywhere in the package.

### Dependencies
None within the initiative (first task; parallel with STORE-T-0008). Governed by STORE-A-0003 §1 and STORE-I-0002 decisions 1 and 7.

### Risk Considerations
The width-mismatch test cannot run two build widths in one binary — simulate by rewriting the `term_id_bits` meta value in place and re-opening. Static lib/link flags are the likeliest platform friction; keep all foreign-import configuration in one file.

## Status Updates **[REQUIRED]**

- **2026-08-04 — Completed.** `vendor/lmdb/` vendored with `README.md` provenance note (source, 0.9.35, forbidden dev-branch symbols); the binding's own `when` block already handles darwin_arm64 static lib vs `system:lmdb` fallback. `store_lmdb/store_lmdb.odin`: package doc (format summary, transaction model, 0.9-only note), `Db` enum + names, `Error :: union{Db_Error, Store_Error}` with `check(rc)` and `error_string`, `Options`/`DEFAULT_OPTIONS`, `open`/`close` (final naming: `open`/`close`, documented as the backend's dataset_init/destroy equivalents; on error the returned pointer is invalid — the family's graph.odin convention, documented), `open_databases` with fresh-init vs validate paths, big-endian `meta_get`/`meta_put`, `val_of`/`val_bytes` helpers. Tests: init, reopen (+read-only), unknown-format rejection, width-mismatch rejection — both simulated by rewriting meta values through the binding. Full suite 30+30+4+4 green via extended `scripts/test.sh`. Learned: Odin deferred cleanup can't nil a named result after `or_return`, so the API documents "invalid on error" rather than promising nil (matches graph.odin).