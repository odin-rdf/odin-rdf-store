---
id: lmdb-backed-persistent-dataset
level: initiative
title: "LMDB-backed persistent dataset behind the match interface"
short_code: "STORE-I-0002"
created_at: 2026-08-04T20:32:36.970667+00:00
updated_at: 2026-08-04T22:01:50.387612+00:00
parent: STORE-V-0001
blocked_by: []
archived: false

tags:
  - "#initiative"
  - "#phase/completed"


exit_criteria_met: false
estimated_complexity: L
initiative_id: lmdb-backed-persistent-dataset
---

# LMDB-backed persistent dataset behind the match interface Initiative

## Context **[REQUIRED]**

Second initiative of the odin-rdf-store vision (STORE-V-0001): a persistent implementation of the match interface over LMDB, slotting in behind the exact contract STORE-I-0001 established. The in-memory backend proved the interface; this initiative proves the "multiple backends of one interface" promise and the zero-copy read discipline the whole library family was designed around (parser ADR RDF-A-0001).

What this builds on:

- **The contract** (STORE-A-0002, executable form: the conformance suite in `store/dataset_test.odin`): a documented procedure set — `dataset_init/destroy`, `insert`, `count`, `match`/`match_next`/`match_destroy` — that a new backend implements verbatim. `match_destroy` being contractual was designed for exactly this backend's cursors.
- **The key encoding** (STORE-A-0001): Term_IDs serialize **big-endian** in composite index keys so memcmp order equals numeric ID order (no custom comparator); kind tags in high bits give kind-clustered ranges. The database records its Term_ID width and refuses to open under a build of the other width — width mismatch must be a loud open-time error.
- **An existing Odin LMDB binding**: `/Users/greger/workspace/odin/odin-vengine/vendor/lmdb` (`lmdb.odin` + `liblmdb_darwin_arm64.a`), used in production by odin-vengine (`src/graph/graph.odin` — regular production code that happens to use LMDB, useful as evidence the binding works and for usage idioms, not as a design template). **Critical caveat documented there: the binding's header was generated from LMDB's `mdb.master` development branch (the perpetually-unreleased "1.0" line — no stable 1.0 has ever shipped; 0.9.x is the only released series), while the linked library is the released 0.9.35. The development-branch-only entry points (`env_incr_dump`, `cursor_is_db`, `txn_prepare`, `env_rollback`, `env_set_encrypt`, `env_set_checksum`, modload) have no symbol and must not be called — the backend targets the 0.9 API surface exclusively, which is everything it needs (env/txn/dbi/get/put/cursor).**
- **Vision constraint**: the LMDB backend is an isolated, optional package (it requires C bindings) that nothing else depends on — the core `store` package stays dependency-free.

## Goals & Non-Goals **[REQUIRED]**

**Goals:**
- A **persistent dataset + dictionary** in one LMDB environment: quads and the term dictionary durably stored, reopened across process runs with all IDs stable.
- The **match interface implemented over LMDB**: same procedure set, same semantics; the STORE-I-0001 conformance suite passes against it verbatim (all 16 patterns, set semantics, graph edge cases).
- **Zero-copy reads**: match iterators walk LMDB cursors over the index DBs, yielding quads straight from mapped pages with no per-result copying — valid until `match_destroy` per decision 3. (Standalone dictionary lookups copy into a caller allocator by design; borrowed zero-copy lookups arrive with the future snapshot API.) This realizes the discipline RDF-A-0001 was designed for.
- **Key layout per STORE-A-0001**: big-endian composite keys, GSPO/GPOS/GOSP index DBs (mirroring the in-memory index set), metadata DB recording format version and Term_ID width with loud mismatch rejection.
- **Bulk load from all four parser formats** into the persistent store, reusing the ingestion semantics of STORE-I-0001 (per-load blank-node scoping, per-statement validity).
- **Transaction-aware lifetime contract**: the backend's documentation states precisely how iterator and term validity map onto LMDB read transactions — the one place the contract's wording legitimately differs from the in-memory backend.
- **Benchmark extension**: the `bench/` harness grows LMDB bulk-load and match numbers alongside the in-memory baselines.

**Non-Goals:**
- Time-travel / versioned store (a future variant; this is the plain current-state backend — but `remove`'s logical-visibility contract and the append-friendly layout keep that door open).
- `remove` (still append-only v1, matching the in-memory backend; revisited for both backends together).
- Multi-process concurrency guarantees beyond what LMDB gives for free (single writer, MVCC readers); no cross-process coordination features, no reader-check tooling.
- Planner support (ordered iteration, cardinality estimates) — still deferred to SPARQL evidence, though LMDB's sorted DBs make it nearly free when it comes.
- Writing or maintaining the LMDB binding itself; upstreaming binding fixes to odin-vengine is out of scope (issues get reported, not fixed here).
- Compaction, backup tooling, encryption (0.9 has none of the 1.0 features anyway).

## Architecture **[CONDITIONAL: Technically Complex Initiative]**

### Overview

A new isolated package (working name `store_lmdb/`) implementing the STORE-A-0002 procedure set over one LMDB environment holding named DBs:

```
meta       format version, Term_ID width, per-kind counters
id2term    key: BE Term_ID            → value: serialized term
term2id    key: serialized term key   → value: BE Term_ID
gspo       key: BE [g,s,p,o] (4×ID)   → value: empty
gpos       key: BE [g,p,o,s]          → value: empty
gosp       key: BE [g,o,s,p]          → value: empty
```

- **Dictionary**: term→ID via `term2id` point lookups; ID→term via `id2term`; per-kind counters persisted in `meta` (single-writer makes an in-memory mirror safe, per the graph.odin idiom). Term serialization needs a canonical byte form per kind (literal = lexical + datatype + language + direction, length-prefixed; triple term = three component IDs).
- **Match**: the same longest-bound-prefix dispatch as the in-memory backend, but a range scan is an LMDB cursor positioned with SET_RANGE on the big-endian prefix; `Match_Iterator` owns the cursor (and possibly the read txn), released in `match_destroy`.
- **Insert/bulk load**: batched inside write transactions (LMDB's single-writer model makes per-quad transactions prohibitively slow; the loader wraps a whole document in one txn).
- **Reopen**: `meta` format/width check on open, counters reloaded — the graph.odin open-databases idiom.

### Boundary with the core package

The core `store` package keeps zero C dependencies. The conformance suite and the loader's per-statement/blank-scoping semantics are the shared assets; how they are shared (moved to a common location vs. ported) is a design-phase decision.

## Detailed Design **[REQUIRED]**

Decisions settled with the human 2026-08-04. The persistent format (decisions 4 and 6, plus the meta schema) is recorded in full in STORE-A-0003, which notably supersedes the earlier full-content `term2id` key sketch with hashed 17-byte keys (LMDB's 511-byte key limit makes full-content keys unsound — see the ADR's context).

1. **Binding acquisition** — **DECIDED**: vendor a copy of `odin-vengine/vendor/lmdb` (`lmdb.odin` + `liblmdb_darwin_arm64.a`) into this repo's `vendor/lmdb/`; self-contained and version-pinned. darwin_arm64 is the only supported platform in v1; the known future path for others is linking a system liblmdb (all released liblmdb is 0.9.x, and the backend restricts itself to the 0.9 API surface — development-branch-only symbols are never called). — **SUPERSEDED 2026-08-06 by STORE-A-0004**: the LMDB C sources are now vendored and an archive is built and suite-verified per platform in CI (macOS arm64/x86_64, Linux x86_64/arm64, Windows x86_64), so `system:lmdb` is a fallback for unsupported platforms rather than the plan for most of them. The decision above stands as the record of what was settled on 2026-08-04.
2. **Transaction model** — **DECIDED**: implicit + batched loaders. `insert` opens and commits its own write txn and `match` opens a read txn owned by the iterator, so the shared contract and conformance suite hold verbatim with no new API. The `load_*` procedures internally wrap each document in one write transaction (LMDB commits are fsync-bound; per-statement txns would be orders of magnitude slower). Public `begin/commit` batch procs are deferred until a caller outside the loaders needs them.
3. **Read-transaction lifetime for zero-copy** — **DECIDED**: iterator-owned read txns — everything yielded by a `match` is valid until its `match_destroy`, which is the existing contract's wording applied to MVCC; `match_destroy` closes cursor and txn. Standalone dictionary reads (`lookup_term`/`decode_quad` equivalents) copy into a caller-supplied allocator instead of returning page views, avoiding the use-after-invalidate trap. An explicit snapshot API (consistent multi-operation reads, borrowed lookups) is deferred until SPARQL demonstrates the need — expected to arrive with the planner-support interface revision. **SPARQL mapping analysis (2026-08-04)**: a nested-loop BGP evaluation issues one `match` per join probe plus one lookup per materialized term, so per-operation txns would mean 10³–10⁴ read txns per average query — modest overhead (LMDB read txns are µs-cheap, and `txn_reset`/`txn_renew` can recycle them internally), but crucially **no single consistent snapshot**: probes could observe different database states if a writer commits mid-query. One query = one read txn is the required end state. Implementation consequence adopted now: all read paths are written as txn-taking private procedures; the public per-operation procs are thin open/close wrappers. The future snapshot API then lands as an additive layer (which also unlocks borrowed zero-copy lookups for the snapshot's lifetime), not a refactor.
4. **Term serialization format** — **DECIDED in outline, format ADR pins the bytes**: canonical byte encoding for `term2id` keys and `id2term` values; deterministic, prefix-unambiguous (length-prefixed fields), versioned via `meta` format. Working sketch (discussed 2026-08-04): `id2term` value carries no kind byte (kind is in the key's tag bits); literal values store the datatype as its Term_ID with layout `[datatype ID][direction: 1B][lang len: 1B][lang][lexical to end]`; triple-term values are the three component IDs. Considered and deferred: `MDB_INTEGERKEY` on `id2term` (native-order u64 keys, integer comparator) — sort order stays numeric so kind clustering survives, but the expected gain is marginal (dictionary lookups are off the match hot path; comparator cost is dwarfed by page traversal) and it would split the file format into two key conventions where uniform big-endian is one rule. Revisit on benchmark evidence via a format-version bump; note that the related `MDB_DUPFIXED`/`MDB_INTEGERDUP` + `GET_MULTIPLE` combination is the higher-leverage variant if decision 6 ever moves the index DBs to DUPSORT.
5. **Conformance suite sharing** — **DECIDED**: extract the suite into a shared test-harness package driven through a small proc-pointer adapter that each backend's test files supply (vtable indirection is acceptable in test code — the STORE-A-0002 hot-path objection doesn't apply). One source of truth; includes refactoring STORE-I-0001's `dataset_test.odin` to instantiate the harness for the in-memory backend. The loader's blank-scoping/per-statement semantics are shared the same way if extraction proves clean, otherwise duplicated knowingly.
6. **Index DB layout** — **DECIDED**: three DBs with full 4-ID big-endian keys and empty values, mirroring the in-memory index set. DUPSORT (key = prefix, dup = remainder, with `MDB_DUPFIXED`/`GET_MULTIPLE` page-batched reads) is the recorded optimization path, invisible behind the interface, revisited on benchmark evidence.
7. **Durability options** — **DECIDED**: an `Options` struct exposing `map_size` (default 1 GiB — sparse map, reserves address space not disk), `max_readers`, `no_sync`, `read_only`, mirroring the binding's env knobs; defaults chosen for development convenience, documented for production tuning.

## Testing Strategy **[CONDITIONAL: Separate Testing Initiative]**

- **The conformance suite, verbatim** — the headline test: the same 16-pattern suite + contract edge cases running against the LMDB backend (per decision 5's sharing mechanism). Passing it is the definition of done for the interface implementation.
- **Persistence tests** — write, close, reopen, verify: IDs stable, counts identical, matches identical; width/format mismatch rejected loudly at open.
- **Zero-copy validity tests** — terms and quads read from one iterator remain valid until `match_destroy`, per the transaction-lifetime contract chosen in design.
- **Ingestion integration** — the four-format load tests against the LMDB backend, including cross-load blank scoping on a reopened database.
- **Round-trip** — load → close → reopen → export → reload, same quad set modulo blank relabeling (reusing the greedy-bijection comparator).
- **Benchmarks** — bulk load (statements/second, one txn per document) and match scans vs. the in-memory baselines recorded in STORE-I-0001; disk bytes/statement.

## Alternatives Considered **[REQUIRED]**

- **Custom LMDB comparator instead of big-endian keys** (`set_compare`) — rejected in STORE-A-0001 already: must be re-registered on every open, slows every comparison, and native-endian keys would corrupt silently if a comparator registration is missed. Big-endian serialization confines the concern to the key codec.
- **Single quads DB + in-memory indexes rebuilt on open** — simpler on-disk format, but open time becomes O(dataset) and memory reverts to in-memory scale, defeating persistence. Rejected.
- **Six index DBs (add SPOG/POSG/OSPG)** — same trade-off as in-memory decision 2; start with three graph-first DBs, add graph-last ones later if wildcard-graph profiling demands. Deferred, not rejected.
- **Writing a fresh minimal binding** — the vendored binding exists, is production-exercised, and covers everything needed; writing a new one adds risk for no capability. Rejected; the 0.9-symbols-only caveat is documented instead.
- **Waiting for SPARQL before building persistence** — the vision sequences the LMDB backend as the proof that the interface abstracts over storage; SPARQL work can proceed against the in-memory backend in parallel. Rejected.

## Implementation Plan **[REQUIRED]**

Direction (decomposition happens at the decompose phase, with human sign-off):

1. **Design-phase outputs**: settle the numbered decisions; one ADR for the persistent format (DB layout, term serialization, meta keys, width/format handling).
2. **Environment + meta skeleton**: open/close/reopen with format & width checks, Options struct, error mapping (`check(rc)` idiom).
3. **Persistent dictionary**: term serialization, term2id/id2term, counters; unit tests incl. reopen stability.
4. **Index DBs + match**: big-endian key codec, cursor-backed iterators, dispatch; conformance suite green (the headline milestone).
5. **Bulk load + persistence tests**: batched-txn loader for the four formats, reopen/round-trip tests.
6. **Benchmarks + docs close-out**: bench extension, lifetime-contract documentation, exit-criteria verification.

## Status Updates

- **2026-08-06 — Decision 1 superseded by STORE-A-0004.** The platform stance settled here (darwin_arm64 only, `system:lmdb` as the future path elsewhere) has been reversed now that the family has CI on three operating systems. The LMDB C sources are vendored at `LMDB_0.9.35` (commit `69087ce`) and an archive is built per platform by `.github/workflows/build-lmdb.yml`, each job installing its archive and running the full suite at both `Term_ID` widths on its own platform before publishing: macOS arm64/x86_64, Linux x86_64/arm64, Windows x86_64. The store's and odin-rdf-sparql's CI matrices now cover Linux, macOS, and Windows. Two latent portability bugs surfaced on the first cross-platform run, neither in LMDB: the test helpers concatenated onto `$TMPDIR` assuming the trailing slash only macOS supplies (yielding a path at the filesystem root on Linux), and Windows required `/MT` because Odin links the static CRT. The LMDB version is unchanged; `LMDB_1.0.0` was tagged upstream 2026-06-30 and is recorded as a review trigger on the new ADR, since its on-disk format differs from the one STORE-A-0003 pins.
- **2026-08-04 — All 6 tasks completed.** The LMDB backend exists: `vendor/lmdb/` (pinned binding + provenance note), `store_lmdb/` (env/meta with loud format+width rejection, persistent dictionary with hashed+verified term2id, cursor-backed match over three index DBs, atomic batched loaders), and `conformance/` (the contract extracted into a shared harness — restructured as its own package because Odin's import rules forbid the original thin-wrapper-in-store plan; coverage inventory unchanged, recorded in T8). **The shared conformance suite passes verbatim over a database file at both Term_ID widths** — "multiple backends of one interface" is now demonstrated, not asserted. Full suite: 55 tests per width (21 store + 9 conformance + 25 store_lmdb), all green.
- **Benchmark baselines (2026-08-04, Apple Silicon macOS, `odin run bench -o:speed`, 200k statements):** LMDB bulk load 64-bit — N-Triples 313 kstmt/s @ 310 B/stmt disk (no_sync 322 — nearly identical because one document = one txn = one fsync; the durable/no_sync gap will appear with many small documents); Turtle (probe-heavy, prices the ADR's verification read) 297 kstmt/s. 32-bit: 346 kstmt/s @ 216 B/stmt disk. Match path (no materialization): LMDB full scan 94–103 Mquad/s vs in-memory 807–989 Mquad/s; (g,s)-bound probes 444–448 kprobe/s including a read txn + cursor open per probe (~2.2 µs each — matches the decision-3 SPARQL analysis) vs 3.2–3.4 Mprobe/s in-memory. Verdict: verification reads and cursor overhead are visible but far from dominating; no ADR review trigger fires. In-memory load baselines unchanged from STORE-I-0001.
- **2026-08-04 — Design complete, decomposed into 6 tasks.** All seven design decisions settled with the human; persistent format pinned in STORE-A-0003 (decided). Tasks: STORE-T-0007 (vendor binding + env/meta skeleton) ∥ STORE-T-0008 (shared conformance harness extraction) → STORE-T-0009 (persistent dictionary; after T7) → STORE-T-0010 (index DBs + cursor match, conformance green — the headline milestone; after T8+T9) → STORE-T-0011 (batched bulk load + persistence tests) → STORE-T-0012 (benchmarks, docs, close-out). Dependencies recorded in each task's `blocked_by` frontmatter. Awaiting human review before activation.

## Exit Criteria **[REQUIRED]**

- [x] The STORE-I-0001 conformance suite passes against the LMDB backend (all 16 patterns, set semantics, graph/term edge cases) at both Term_ID widths.
- [x] A database written, closed, and reopened yields identical counts, matches, and stable Term_IDs; opening under the other Term_ID width or an unknown format version fails loudly at open time.
- [x] Match iterators stream via LMDB cursors with zero-copy values, with the transaction-lifetime contract documented and tested; `match_destroy` releases cursor/txn resources.
- [x] All four parser formats bulk-load into the persistent store with batched write transactions and per-load blank-node scoping, verified on a reopened database.
- [x] The persistent format ADR is decided (DB layout, term serialization, meta schema, width/format rules).
- [x] Benchmarks record LMDB bulk-load and match numbers alongside the in-memory baselines; the core `store` package still builds with no C dependencies (verified: `odin check store -no-entry-point` links nothing).