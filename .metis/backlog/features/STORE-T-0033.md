---
id: open-ephemeral-one-supported
level: task
title: "open_ephemeral: one supported scratch store"
short_code: "STORE-T-0033"
created_at: 2026-08-07T21:20:00+00:00
updated_at: 2026-08-07T22:28:43.169892+00:00
parent: 
blocked_by: []
archived: false

tags:
  - "#task"
  - "#feature"
  - "#phase/completed"


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

## Acceptance Criteria

## Acceptance Criteria **[REQUIRED]**

- [x] `kvstore.open_ephemeral(opts := EPHEMERAL_OPTIONS, allocator := context.allocator) ->
      (^Store, Error)` — a store with no path the caller has to name, clean up, or make
      unique. **The default differs from the one written here, deliberately**: defaulting to
      `DEFAULT_OPTIONS` would put the 1 GiB map back at every call site, which is exactly what
      the next criterion forbids. `EPHEMERAL_OPTIONS` is a named constant rather than an
      override buried inside the procedure, so the difference is readable at the call site and
      the `opts` parameter does not lie about what it does.
- [x] **A map size appropriate to a scratch store**, not the 1 GiB production default.
      **16 MiB, measured rather than picked.** Every RDF document vendored in all three
      sibling suites was loaded into a store and its high-water mark recorded: the largest
      single document is odin-rdf-shacl's `shacl-shacl-data-shapes.ttl` at **288 KiB** (415
      quads), and an entire suite tree loaded into *one* store — the upper bound if a harness
      ever shares a scratch store across a whole suite instead of opening one per test — is
      odin-rdf-sparql's W3C tree at **2.03 MiB** (3,977 quads). 16 MiB is ~8x that aggregate
      and ~56x the largest single document. A test loads 5,000 quads through it, above any
      one repo's whole corpus, so a suite that outgrows the default is told so directly
      instead of failing with `MDB_MAP_FULL` somewhere unrelated.
- [x] `NOSUBDIR | NOLOCK | NOSYNC` over a unique temp file, with the path **unlinked
      immediately after `env_open` returns** on POSIX. Read out of the vendored source rather
      than assumed: `mdb_fname_init` uses the path verbatim with no suffix under
      `NOSUBDIR|NOLOCK`, so there is one file and no lock file; `mdb_env_open` opens every
      descriptor it will ever open by name — including the synchronous meta descriptor it
      takes when `WRITEMAP` is absent — before it returns, so unlinking after it costs the
      store nothing; `mdb_env_read_header` treats a zero-length file as a fresh environment,
      which is what lets the name be reserved by creating it; and `mdb_txn_renew0` takes the
      `me_txns == NULL` branch under `NOLOCK`, so read transactions work with no reader table.
- [x] **Windows behaviour stated rather than papered over**: no unlink-while-open, so it falls
      back to delete-on-close and leaks one file on abnormal termination. Said in the doc
      comment, the README and the CHANGELOG. It is why `Store` gained `scratch_path`, which is
      empty on every other platform — and the test asserts both arms.
- [x] The uniqueness scheme is correct **once**, under concurrency, and tested for it.
      **There is no scheme.** `ephemeral_reserve` wins a name by *creating* the file
      (`os.create_temp_file`: `O_CREAT|O_EXCL`, retried on a lost race), so uniqueness is the
      filesystem's rather than something two callers can compute identically — which is the
      shape all four recorded collisions had. Tested with 8 threads × 32 reservations: 256
      distinct names, each an existing file.
- [x] Conformance unaffected: this is a constructor, not a change to the match contract.
      Demonstrated rather than asserted — `conformance_test.odin` now instantiates the whole
      shared suite over an ephemeral store, and nothing in the `Backend` adapter distinguishes
      the two constructors.
- [x] The twelve existing copies are migrated, or a named subset is, with the rest justified.
      **This repo's three are gone; the nine in the siblings are theirs to take** — see the
      status update for both halves. `grep get_env` across `store/`, `bench/`, `tests/` and
      `conformance/` now returns nothing.

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

- **2026-08-07 — Implemented. All seven acceptance criteria met; `make test` green at both
  `Term_ID` widths and `make check` clean. 40 → 44 tests (store 5, store/kvstore 33 → 37,
  tests/readme 2), the +4 being this item's own.**

  **The 16 MiB was measured, and the measurement is the part worth keeping.** The Risk
  Considerations asked for a number sized against the largest suite fixture with its origin
  stated rather than a round one, so a throwaway harness loaded every `.ttl`/`.nt`/`.nq`/
  `.trig` vendored in all three sibling repos into a store and read back `data.mdb`'s length.
  Largest single document: **288 KiB** high-water mark. Whole suite tree into one store —
  which nothing does today, but is the upper bound if a harness ever reuses a scratch store
  per suite instead of per test: **2.03 MiB** (odin-rdf-sparql's W3C tree). 16 MiB is ~8x
  that and ~56x the document. The projected Windows arithmetic: the same ~483 opens per width
  that materialize ~483 GiB at the 1 GiB default materialize ~7.5 GiB at 16 MiB, a 64x
  reduction in bytes zero-filled, and it is bytes zero-filled that the >20 min job was
  spending its time on.

  **The uniqueness question turned out not to need answering.** The item's framing — "the
  uniqueness scheme is correct once" — assumes a scheme. There is no scheme:
  `ephemeral_reserve` calls `os.create_temp_file`, which loops on `O_CREAT|O_EXCL` until it
  wins a name, so uniqueness is the filesystem's. That also disposes of the shape all four
  recorded collisions had, which was never bad luck with a random suffix but two callers
  computing the same name from the same pid. `mdb_env_read_header` returning `ENOENT` on a
  zero-length file is what makes reserve-by-creation legal: LMDB reopens the empty file we
  created and initializes it as a fresh environment.

  **A judgement call against the item's own text**, flagged because it is a deviation: the
  signature here is `open_ephemeral(opts := EPHEMERAL_OPTIONS, ...)`, not
  `opts := DEFAULT_OPTIONS` as written. The two criteria are in tension as filed — the first
  names `DEFAULT_OPTIONS`, the second says the scratch map "belongs in this procedure rather
  than at twelve call sites" — and defaulting to `DEFAULT_OPTIONS` would restore the 1 GiB
  map at every call site that does not pass options, which is every one of them. Silently
  overriding `map_size` inside the procedure was the other way to resolve it and is worse: the
  `opts` parameter would then lie. A named `EPHEMERAL_OPTIONS` puts the difference where a
  reader of the call site can see it.

  **What is not in the doc comment but is in the code**: `opts.read_only` is ignored, because
  a read-only store nobody can ever write to is empty forever; and `Store` gained
  `scratch_path`, which is non-empty only on Windows and is the whole of what `close` has left
  to do there.

  **The four new tests, and one that is weaker than it looks.**
  `test_ephemeral_store_leaves_nothing_behind` asserts the Windows arm properly — the file
  exists while the store is open and is gone after `close` — but the POSIX arm asserts only
  `scratch_path == ""`, not that the inode is actually unlinked. Scanning the OS temp
  directory was the obvious stronger check and was rejected: the runner executes this
  package's tests on ten threads sharing that directory, so a scan there answers a question
  about the whole suite and would be flaky. `scratch_path == ""` is exact for what `close`
  will do and indirect about what `open_ephemeral` already did; the unlink itself rests on the
  `mdb_env_open` reading above. Recorded rather than papered over.

  **Migration: three of three here, nine still in the siblings.** `store/kvstore` (the
  conformance suite, the dictionary, load and round-trip tests) and `tests/readme`'s export
  example now take `open_ephemeral` and name nothing. The tests that keep a real path are the
  ones whose *subject* is a path — reopen, read-only reopen, rewriting a meta value behind the
  store's back — plus `tests/readme`'s persistent example, which mirrors the README's literal
  path, plus `bench/`, which stats `data.mdb` for bytes/statement and must measure a store
  configured the way a deployment configures one. Those four kept paths no longer hand-roll
  the dance either: they take `os.make_directory_temp`, which is the same
  win-the-name-by-creating-it move one level up. `grep get_env` across the repo's source now
  returns nothing.

  The nine copies in odin-rdf-sparql and odin-rdf-shacl are untouched, and deliberately: those
  repos own their own sequencing, as STORE-I-0003 established with STORE-T-0026 and
  STORE-T-0027. They are also where the Windows CI minutes actually are — sparql's harness
  opens one store per evaluation entry. **Recommend a proposal task per sibling**, filed the
  same way, once this lands and is tagged. Not created here, because filing in a sibling repo
  is raised first.

  Also updated: `README.md` gains a short section on the constructor (compile-verified by the
  readme test, as everything there is), `CHANGELOG.md` gains an Unreleased entry, and
  `store/interface.odin`'s note on why lifecycle is outside the procedure-set convention now
  names both constructors.