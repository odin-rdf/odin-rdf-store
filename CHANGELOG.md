# Changelog

Notable changes to odin-rdf-store. Versions are [semantic](https://semver.org/) under
the 0.x convention: while the major version is 0, a **minor** bump is where breaking
changes land.

The `.metis/` directory holds the reasoning behind everything here — the vision, the
initiatives, and the ADRs each entry cites.

## Unreleased

### Changed

- **`Error` carries `os.Error`, and `ephemeral_reserve` returns what the OS said.**
  `open_ephemeral`'s reservation used to collapse every failure from
  `os.create_temp_file` into `Store_Error.Temp_Unavailable`, which reported that
  something had gone wrong and nothing about what. odin-rdf-shacl's Windows CI began
  failing intermittently — two of ~58 ephemeral opens, a different test each run — and
  the one fact needed to diagnose it had been discarded here. A classification is worth
  less than the error it classifies.

### Removed

- **`Store_Error.Temp_Unavailable`**, which now has no producer. Its meaning is carried
  by the `os.Error` the reservation returns, in more detail than it could express.

### Added

- `test_many_ephemeral_stores_open_at_once`, asserting the workload rather than the
  primitive. `test_ephemeral_names_never_collide` reserves names concurrently and passes
  everywhere including Windows, which is why it did not catch this: reservation is half
  of `open_ephemeral`, and the other half is an LMDB environment that materializes its
  whole `map_size` on open under Windows. A consumer's suite holds a dozen of those open
  at once, and that is what this test does.

## 0.3.0 — 2026-08-08

### Added

- **Transactions and snapshots** (ADR `STORE-A-0007`, initiative `STORE-I-0004`). One opaque
  `Txn` handle with a `.Read`/`.Write` mode, and **a read transaction *is* the snapshot** —
  there is no separate snapshot type and nothing in the API says "snapshot".

  ```odin
  tx, err := kvstore.txn_begin(s, .Write)   // store.Txn_Mode
  defer kvstore.txn_abort(&tx)              // a no-op after a successful commit
  kvstore.load_turtle_txn(&tx, candidate)
  it, _ := kvstore.match_txn(&tx, pattern)  // sees the load
  kvstore.txn_commit(&tx)
  ```

  Every operation gains a `_txn` form taking the handle alone — `insert_txn`, `count_txn`,
  `match_txn`, `find_term_txn`, `lookup_term_txn`, `intern_term_txn`, the graph-label trio,
  the quad codec, and all four loaders. The handle carries its dataset, so a consumer threads
  one thing.

  **This closes the family's one correctness gap: validate-before-commit was inexpressible.**
  A validator deciding whether a write may join the dataset could not observe the write it was
  deciding about, and the workaround — build the candidate in a second dataset and validate
  *that* — is wrong rather than slow: every constraint that must consult existing data reads an
  empty world and passes vacuously. Now the candidate is built inside a write transaction and
  validated through that same transaction.

  The guarantees are stated flat, with nothing conditional and no capability a backend can
  declare its way out of: read-your-own-writes, snapshot isolation, atomicity over quads (not
  over the dictionary), provisional `Term_ID`s discarded on abort, single writer with no
  nesting, and iterator invalidation on a write through the same transaction. The conformance
  suite asserts all of it as one uniform body — no tier, no skip.

  **Two costs are part of the contract rather than backend detail.** An open read transaction
  pins pages, so a long snapshot makes a concurrent writer grow the file. An open write
  transaction serializes every other writer against that environment for its lifetime, and the
  validate-before-commit pattern holds one across an entire validation by construction.

- `Store_Error.Write_Txn_Open`, for a second write transaction on a handle that already has
  one. **Refused rather than blocked**: within one handle it can only be a programming error,
  and LMDB's writer lock would self-deadlock a single-threaded consumer. The refusal covers the
  autocommit procedures too — bare `insert` and the loaders each open a write transaction, so
  they are refused rather than deadlocking against one you hold. Between *processes* LMDB still
  serializes writers by blocking, which is what the deployment shape uses and is untouched.

- `store.Txn_Mode`, in the `store` vocabulary package rather than per-backend: it carries no
  backend content, so every backend would otherwise declare it identically.

- **`kvstore.open_ephemeral`** — a store with no path the caller has to name, make unique,
  or clean up, and which does not outlive the process (`STORE-T-0033`). Same contract and
  same procedure set as `open`; only the storage's lifetime differs. The database is one
  file with no lock file (`NOSUBDIR | NOLOCK | NOSYNC`), unlinked as soon as it is open on
  POSIX — invisible for the store's whole life and reclaimed by the kernel on close *or on
  crash*. Windows has no unlink-while-open, so the file lives until `close` deletes it and
  an abnormal termination leaks exactly one file.

  Its default `EPHEMERAL_OPTIONS` carries a **16 MiB** map rather than `DEFAULT_OPTIONS`'
  1 GiB, and that is the part that pays for the procedure. LMDB has no sparse-file
  handling on Windows, so every `open` there materializes `map_size` on disk in full; a
  suite that opens a store per test spends CI minutes writing files it never reads. The
  16 MiB is measured, not chosen: the largest single document vendored anywhere in the
  family leaves a 288 KiB high-water mark, and an entire suite tree loaded into one store
  leaves 2.03 MiB.

  This partly answers 0.2.0's "every dataset is a filesystem path" consequence below:
  every dataset still *is* one, but a scratch dataset no longer makes that the caller's
  problem.

- `Store_Error.Temp_Unavailable`, for an `open_ephemeral` that could find no writable
  temporary location.

### Changed

- **`intern_term_txn` and `find_term_txn` take a `^Txn` instead of `(^Store, ^lmdb.Txn)`.**
  These are the only two signatures in this release that change, and they change because they
  were public by omission — `find_term_txn` since `STORE-T-0014` — with LMDB's own type in
  front of consumers, which `STORE-A-0007` exists to prevent. Leaving them would have made that
  permanent. No consumer in the family used either, so the practical reach is nil, but a
  changed public signature is a changed public signature.

- Every **bare** procedure is unchanged in name, signature and semantics, and gains a
  definition it did not have: a one-operation transaction. Nothing written against the previous
  release stops compiling or changes meaning.

## 0.2.0

### Removed

- **`store/memstore`, the in-memory backend.** odin-rdf-store is now a single-backend
  library over LMDB (ADR `STORE-A-0006`, initiative `STORE-I-0003`). memstore was an
  architectural proposal rather than a consumer request: in the year it shipped, its only
  consumers were test suites, and the transaction model the query and validation layers
  need came out dominated by accommodating a backend with no versioning of any kind.

  **This is a breaking change with no deprecation path** — the package either exists or it
  does not. There is no in-memory replacement and none is planned; LMDB has no anonymous
  or in-memory mode. Two consequences for every consumer:

  - **You link LMDB.** It is no longer an optional dependency selected by which backend
    you import.
  - **Every dataset is a filesystem path.** Code that opened an ephemeral dataset needs a
    directory, and a policy for its lifetime.

  Porting is mechanical — the procedure names and semantics are the ones memstore
  implemented — but the lifecycle differs: `dataset_init` / `dataset_destroy` over a
  separate `Dictionary` and `Dataset` become `kvstore.open(path, opts)` / `kvstore.close`
  over one `Store`, and the fallible procedures return an `Error`. The README's quick
  start is the whole shape.

### Changed

- **The conformance suite is a regression suite, not a portability proof.** It still
  defines what implementing the match interface means, and passing it verbatim is still
  that definition — but with one backend it no longer demonstrates that the contract
  abstracts over more than one. The `conformance.Backend` adapter is retained unchanged,
  and the `store` / `store/kvstore` split with it, precisely so a second backend is an
  addition rather than an excavation.
- **The match interface's semantics are LMDB's semantics by definition** (`STORE-A-0006`).
  What used to be documented as backend detail is now contract.
- Documentation across the library corrected to describe one backend: the contract
  document in `store/interface.odin`, the `store` and `conformance` package docs, and the
  README, whose quick-start examples are now kvstore and compile-verified by
  `tests/readme` as before.

### Note on `store/interface.odin`

The published procedure set no longer lists `dataset_init` / `dataset_destroy`. Those were
memstore's names, and no remaining backend implements them; opening and closing a dataset
is now explicitly outside the convention, because it is where a backend's own nature
shows. The names, semantics, and iteration contract are what the convention fixes.

## 0.1.1 — 2026-08-06

### Fixed

- **LMDB archives vendored for all five supported platforms** (`STORE-A-0004`): darwin
  arm64/amd64, linux arm64/amd64, windows amd64. 0.1.0 shipped only darwin arm64, so a
  consumer linking `store/kvstore` could not build on Linux or Windows against that tag.

No public API change and no behaviour change to shipped code: the only source edit under
`store/` was a private temp-path helper in a test file. Packaging, plus the upstream LMDB
sources and the workflow that builds the archives.

## 0.1.0 — 2026-08-06

Initial release. The match interface and two backends behind it: `store/memstore`
(in-memory) and `store/kvstore` (persistent, LMDB). Both passed one shared conformance
suite verbatim, at both `Term_ID` widths.

Key decisions: `STORE-A-0001` (kind-tagged dense `Term_ID`s with build-time width),
`STORE-A-0002` (the match interface as a procedure-set convention, no vtable),
`STORE-A-0003` (the LMDB persistent format).
