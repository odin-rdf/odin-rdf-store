# Changelog

Notable changes to odin-rdf-store. Versions are [semantic](https://semver.org/) under
the 0.x convention: while the major version is 0, a **minor** bump is where breaking
changes land.

The `.metis/` directory holds the reasoning behind everything here — the vision, the
initiatives, and the ADRs each entry cites.

## Unreleased

### Added

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
