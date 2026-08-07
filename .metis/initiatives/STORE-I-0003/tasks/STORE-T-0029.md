---
id: port-bench-to-kvstore-and-retire
level: task
title: "Port bench/ to kvstore and retire the memstore baselines"
short_code: "STORE-T-0029"
created_at: 2026-08-07T16:22:25+00:00
updated_at: 2026-08-07T16:49:22.605425+00:00
parent: STORE-I-0003
blocked_by: [STORE-T-0025]
archived: false

tags:
  - "#task"
  - "#phase/completed"


exit_criteria_met: false
initiative_id: STORE-I-0003
---

# Port bench/ to kvstore and retire the memstore baselines

## Parent Initiative **[CONDITIONAL: Assigned Task]**

[[STORE-I-0003]]

## Objective **[REQUIRED]**

Move the benchmark harness onto kvstore, and — the part that is easy to skip — **retire the
recorded baselines it invalidates**, explicitly, rather than leaving numbers in the record
that a future reader will compare against and misread as a catastrophic regression.

`bench/main.odin` is memstore-only: it imports `store/memstore` and its four `Load_Proc`
implementations take `^memstore.Dictionary, ^memstore.Dataset`. Its output is the source of
STORE-I-0001's recorded baselines — N-Triples 584 kstmt/s, N-Quads 607, Turtle 1188, TriG
1063, with bytes/statement at both widths. Those measure in-memory interning and index
construction. The same harness over LMDB measures database ingest with page writes and, in
the durable configuration, fsync. **The numbers are not comparable and there is no port
that makes them so.**

`bench/lmdb.odin` already exists and already benchmarks kvstore, so the LMDB path is not new
work — but its own doc says it reports "match-scan throughput compared against the in-memory
backend over the same data." That comparison is the thing being removed, not ported.

## Acceptance Criteria

## Acceptance Criteria **[REQUIRED]**

- [x] `bench/main.odin` drives kvstore; the four format loaders take a `^kvstore.Store`.
      Bulk-load throughput and bytes/statement are still reported.
- [x] `bench/lmdb.odin`'s memstore comparison is removed, and what it measured is recorded
      as removed — the durable/no_sync split and the disk bytes/statement figures survive
      on their own merits.
- [x] **STORE-I-0001's benchmark-baseline status update is annotated in place**, dated,
      marking those figures as measured against a backend that no longer exists and
      therefore not comparable to anything measured afterwards. Do not delete them: they
      are the record of why the pending-buffer/lazy-merge design was adopted (the O(n²)
      finding), which is still true history.
- [x] Fresh kvstore baselines recorded, at both `Term_ID` widths, with the configuration
      stated (durable vs `no_sync`, map size, platform) — because unlike the memstore
      figures these are sensitive to configuration and a bare number would be misleading.
- [x] `make bench` builds and runs clean with release flags.
- [x] Any remaining reference to a "bulk load benchmark guarding against silent copy
      regressions" (STORE-I-0001's Testing Strategy) is checked: the guard's meaning changes
      when the allocations being guarded are LMDB's pages rather than the dictionary's
      clones.

## Implementation Notes **[CONDITIONAL: Technical Task]**

### Technical Approach

Most of the mechanism exists — `bench/lmdb.odin` already opens stores, handles temp paths,
and runs both durable and `no_sync` configurations. The work in `main.odin` is swapping the
loader signatures and threading a `^Store`; the loaders themselves (`load_triples`,
`load_quads`, `load_turtle`, `load_trig`) have kvstore equivalents with the same names and
nearly the same shapes, differing in the added `Error` return.

The baseline retirement is a documentation edit in
`.metis/initiatives/STORE-I-0001/initiative.md`, in the Status Updates section.

### Dependencies

Blocked by STORE-T-0025. Blocks STORE-T-0030. Independent of the sibling proposals and of
STORE-T-0028; can run in parallel with both.

### Risk Considerations

The temptation is to port the harness and stop, leaving the old baselines sitting in
STORE-I-0001 looking authoritative. A reader who then runs `make bench` sees roughly an
order of magnitude less throughput and reasonably concludes something broke. The annotation
is the deliverable that prevents that, and it is the one with no compiler to enforce it.

Note also that this task removes the family's only in-memory throughput figures entirely.
If a future consumer asks "how fast is this without a database", there will be no answer on
record — which is a consequence of the initiative, not of this task, but this is where it
becomes concrete.

## Status Updates **[REQUIRED]**

- **2026-08-07 — Created in STORE-I-0003's decomposition.** Decision taken at
  decomposition: port both benchmarks rather than delete either.
- **2026-08-07 — Done. `make bench` clean at both widths, `odin check bench -vet
  -strict-style` clean.**

  **The port turned out to be a merge, not a translation.** `main.odin`'s `bench_load` and
  `lmdb.odin`'s `bench_lmdb_load` would have become the same procedure — open a store, time
  a load, report — so `main.odin` now holds `main()`, the corpora, and the four format
  loaders, while `lmdb.odin` holds the measurement primitives. The format sweep gained
  N-Quads and TriG, which the LMDB path never covered.

  **The live-bytes metric did not survive, and that is a real reduction.** It measured
  dictionary strings, maps, membership set and three index arrays through a tracking
  allocator, and it was the thing that guarded the zero-copy discipline — a silent extra
  copy per statement showed up there. LMDB holds all of that in mapped pages, so a tracking
  allocator sees essentially nothing regardless of how many copies are made. On-disk
  bytes/statement replaces it and prices pages, not copies. Recorded in three places rather
  than dropped: the new `bench/main.odin` doc comment, the retirement block in STORE-I-0001,
  and STORE-I-0001's Testing Strategy line, which described a guard that no longer exists.

  **A second memstore dependency was in `bench_match_scans`** and was not in this task's
  original scope: it minted the probe subject from memstore's dictionary and reused that
  integer as a kvstore pattern, which worked only because both backends assigned the same ID
  to the same term (STORE-A-0001 point 7, annotated historical in STORE-T-0025). The probe
  subject is now read out of the store being measured, which is what it should always have
  done.

  **Fresh baselines recorded at both widths** in STORE-I-0001, with platform, durability
  mode and map size stated. Two observations worth having on record:
  - **The `no_sync` delta is negligible** (319 → 331 kstmt/s on N-Triples): the loaders wrap
    a whole document in one write transaction (STORE-I-0002 decision 2), so a load costs one
    fsync regardless of statement count. The durable/no_sync pair the old benchmark framed as
    a meaningful trade-off is, at document granularity, almost no trade-off at all.
  - **The 32-bit build's disk footprint is ~30% smaller** (216 vs 310 B/stmt on N-Triples) —
    four IDs per index key, at half the width, three indexes, showing up directly in pages.

  Throughput is roughly half the retired in-memory figures (319 vs 584 kstmt/s on N-Triples),
  which is expected and is exactly why the old numbers had to be marked incomparable rather
  than left standing.