# Vendored LMDB binding

## Source

`upstream/` holds the four files that make up liblmdb — `mdb.c`, `midl.c`,
`lmdb.h`, `midl.h` — plus `LICENSE`, `COPYRIGHT`, and `CHANGES`, copied
verbatim from:

| | |
| --- | --- |
| Repository | https://github.com/LMDB/lmdb |
| Tag | `LMDB_0.9.35` |
| Commit | `69087ced3cb6082f7dcfb4fc2dcaa3b68a7e2e8c` |
| Path | `libraries/liblmdb` |

LMDB publishes no prebuilt binaries — it never has, for any platform — so
the archives here are built from these sources. Vendoring the sources makes
each archive a reproducible artifact rather than a trusted blob: anyone can
diff `upstream/` against that commit and rebuild.

`LICENSE` and `COPYRIGHT` travel with the source because projects that
vendor odin-rdf-store redistribute LMDB along with it.

## Archives

Built by `.github/workflows/build-lmdb.yml`, one job per platform. Each job
installs its archive and runs the full store suite at both `Term_ID` widths
before uploading, so a published archive has been proven on its platform,
not merely compiled.

| Platform | Archive | Runner |
| --- | --- | --- |
| macOS arm64 | `liblmdb_darwin_arm64.a` | `macos-latest` |
| macOS x86_64 | `liblmdb_darwin_amd64.a` | `macos-15-intel` |
| Linux x86_64 | `liblmdb_linux_amd64.a` | `ubuntu-latest` |
| Linux arm64 | `liblmdb_linux_arm64.a` | `ubuntu-24.04-arm` |
| Windows x86_64 | `lmdb_windows_amd64.lib` | `windows-latest` |

Any platform without an archive still falls back to `system:lmdb`.

Build flags are upstream's own (`-pthread -O2`) minus `-g`: no debug info
keeps the archives small and their bytes stable. `NDEBUG` is deliberately
**not** set — LMDB ships with its assertions live, and this build should
differ from what upstream's Makefile produces in nothing but debug info.

Two platform details worth keeping:

- **Windows requires `/MT`, not `/MD`.** Odin links the static CRT, so an
  LMDB built against the dynamic one references the `__imp_`-prefixed import
  thunks (`__imp_strerror`, `__imp_realloc`, `__imp__aligned_malloc`) that
  the static CRT does not define, and the link fails with LNK2019.
- **Archives are built deterministically**, so an unchanged rebuild is
  byte-identical and git records no new blob. Apple's `ar` has no `-D` and
  uses `ZERO_AR_DATE=1` instead; GNU `ar` uses `rcsD`.

## Binding

`lmdb.odin` was generated from LMDB's `mdb.master` development branch — the
"1.0" line — while the archives here are 0.9.35. The development-branch-only
entry points (`env_incr_dump*`, `env_incr_load*`, `cursor_is_db`,
`txn_prepare`, `env_rollback`, `env_set_encrypt`, `env_set_checksum`,
modload) have **no symbol in the linked 0.9 library and must not be
called**. The store restricts itself to the 0.9 API surface —
env/txn/dbi/get/put/cursor, 17 entry points in total.

`LMDB_1.0.0` was tagged upstream on 2026-06-30, which would resolve that
mismatch. It is a major version whose on-disk format differs from the 0.9
format ADR STORE-A-0003 pins at version 1, so adopting it is a migration
decision rather than a rebuild.

The archive is named by a path relative to this directory: Odin resolves a
`foreign import` that is not `system:` against the package directory, and an
absolute path is appended to it rather than replacing it. Naming a directory
with `-L` cannot work either — Homebrew symlinks `liblmdb.a` and
`liblmdb.dylib` side by side, and the linker takes the dylib when both match
`-llmdb`.
