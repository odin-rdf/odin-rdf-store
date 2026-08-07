---
id: open-ephemeral-one-supported-scratch
level: task
title: "open_ephemeral: one supported scratch store"
short_code: "STORE-T-0033"
created_at: 2026-08-07T21:20:00.000000+00:00
updated_at: 2026-08-07T21:20:00.000000+00:00
parent: 
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/backlog"
  - "#feature"


exit_criteria_met: false
initiative_id: NULL
---

# open_ephemeral: one supported scratch store

## Objective **[REQUIRED]**

Give the family one supported way to open a store that does not outlive the process, instead
of twelve copies of a temp-directory dance that each invented their own uniqueness scheme.

This was scoped inside STORE-I-0003 (Detailed Design point 3) and **deliberately deferred,
to be decided on the evidence the ports produced rather than assumed by the plan**. The ports
have landed and the evidence is in. It is filed here so the question outlives the initiative
that raised it — closing STORE-I-0003 would otherwise archive both the question and its
evidence in the same document.

## Evidence **[REQUIRED]**

Three independent strands, two of which arrived after the deferral was taken.

**1. The duplication the deferral was waiting on — measured, and it grew sixfold.**

At scoping, STORE-I-0003 counted the OS-temp-directory dance (`TMPDIR` → `TEMP` → `TMP` →
`/tmp`, trailing-separator trim, pid suffix) as "already duplicated verbatim" in exactly two
files. After the ports it is in **twelve**:

```
odin-rdf-store    bench/lmdb.odin, tests/readme/readme_test.odin,
                  store/kvstore/kvstore_test.odin
odin-rdf-sparql   sparql/kvstore/scratch_test.odin, tests/w3c/harness/eval_runner.odin,
                  tests/readme/readme_test.odin, tests/guards/guards_test.odin
odin-rdf-shacl    bench/instrument.odin, tests/w3c/harness/runner.odin,
                  tests/readme/readme.odin, tests/guards/guards.odin,
                  shacl/kvstore/link_test.odin
```

**Both siblings reported this upstream unprompted**, which is what STORE-T-0026 and
STORE-T-0027 asked them to do: odin-rdf-shacl's SHACL-T-0028 — "that is five copies of the
temp-path dance in this repo alone and nine across the family — the evidence STORE-I-0003's
`open_ephemeral` was explicitly waiting on"; odin-rdf-sparql's SPARQL-T-0023 recorded the
same and flagged it as "reporting it upstream".

**2. It is not cosmetic — it has caused four bugs.** STORE-T-0030 found the fourth while
porting `tests/readme`: `readme_db_path` keyed on pid alone, which was unique while one test
opened a store and collided the moment a second did, on ten threads. Its commit states the
finding precisely: *"The recurring defect is not the boilerplate but that each copy invented
its own uniqueness scheme, three of which were wrong."* Copy-paste of a correct helper would
be tolerable; twelve independent attempts at a concurrency-safe unique path is a defect
generator.

**3. New, and the strongest: it is costing Windows CI minutes per run.** Measured on the
2026-08-07 runs that verified the memstore retirement, "Test at both `Term_ID` widths":

| repo | tests/width | ubuntu | macos | windows |
|---|---:|---:|---:|---:|
| odin-rdf-store | 40 | 8s | 9s | 20s |
| odin-rdf-shacl | 144 | 17s | 11s | **211s** |
| odin-rdf-sparql | 261 | 28s | 33s | **>20 min** |

The cost tracks **store opens**, not test count, and the mechanism is confirmed in the
vendored LMDB source rather than inferred. `DEFAULT_OPTIONS.map_size` is 1 GiB.
`kvstore.open` calls `env_set_mapsize` then `env_open` **without** `MDB_WRITEMAP`, which
takes this branch of `mdb_env_map`:

```c
/* Windows won't create mappings for zero length files.
 * and won't map more than the file size.
 * Just set the maxsize right now. */
if (!(flags & MDB_WRITEMAP) && (SetFilePointer(env->me_fd, sizelo, &sizehi, 0) ...
    || !SetEndOfFile(env->me_fd) ...
```

`grep -c SPARSE vendor/lmdb/upstream/mdb.c` is **0** — LMDB never marks the file sparse on
Windows, so NTFS allocates and zero-fills the full extent. **Every open materializes a real
1 GiB file** that the test never writes to. On Linux and macOS the same call reserves address
space over a sparse file and costs nothing, which is why the platform gap looks like general
Windows slowness and is not.

This predates the memstore retirement in principle, but the retirement is what made it bite:
every test that used to run against an in-memory hash map now opens an LMDB environment. The
`Options.map_size` doc comment claimed the map is sparse without qualification, which was
true on the two platforms anyone develops on; it has been corrected.

## Acceptance Criteria **[REQUIRED]**

- [ ] `kvstore.open_ephemeral(opts := DEFAULT_OPTIONS, allocator := context.allocator) ->
      (^Store, Error)` — a store with no path the caller has to name, clean up, or make
      unique.
- [ ] **A map size appropriate to a scratch store**, not the 1 GiB production default. This
      is the acceptance criterion that pays for the item on its own: it is what removes the
      Windows CI cost, and it belongs in this procedure rather than at twelve call sites.
- [ ] `NOSUBDIR | NOLOCK | NOSYNC` over a unique temp file, with the path **unlinked
      immediately after `env_open` returns** on POSIX: the inode stays alive while LMDB holds
      the descriptor, is invisible in the filesystem namespace, and is reclaimed by the kernel
      on close *or on crash*. No cleanup path and no stale directories — which is the
      substance of the objection to "a procedure that touches the temp dir". `NOLOCK` is
      legitimate because an ephemeral store is exclusively the opening process's.
- [ ] **Windows behaviour stated rather than papered over**: no unlink-while-open, so it falls
      back to delete-on-close and leaks one file on abnormal termination.
- [ ] The uniqueness scheme is correct **once**, under concurrency, and tested for it — the
      defect the four collisions share.
- [ ] Conformance unaffected: this is a constructor, not a change to the match contract.
- [ ] The twelve existing copies are migrated, or a named subset is, with the rest justified.
      Benchmarks may legitimately want a real path and a real map size.

## Implementation Notes **[CONDITIONAL: Technical Task]**

### Risk Considerations

`NOLOCK` is safe for the stated use and unsafe if the handle escapes the process; the doc
comment must say so. The map-size default for an ephemeral store is a judgement call — too
small turns a passing suite into `MDB_MAP_FULL` on a large fixture, and the W3C harnesses are
the fixtures most likely to find that edge. Recommend sizing it against the largest existing
suite fixture and stating the number's origin, rather than picking a round one.

### Dependencies

None. Additive, and blocks nothing.

## Status Updates **[REQUIRED]**

- **2026-08-07 — Filed out of STORE-I-0003, which deferred it on purpose and then produced
  the evidence.** The initiative demoted this from a prerequisite to "optional, decided during
  the ports on the duplication they actually produce". That was the right call and it worked:
  the ports produced six times the duplication scoping had measured, both siblings reported it
  upstream without being chased, and CI then supplied a third argument nobody anticipated. It
  is filed as a standalone backlog item rather than left in the initiative so that closing
  STORE-I-0003 does not archive the question together with the evidence for it.
