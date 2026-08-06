---
id: 001-platform-support-vendored-lmdb
level: adr
title: "Platform support: vendored LMDB archives built from vendored sources"
number: 1
short_code: "STORE-A-0004"
created_at: 2026-08-06T11:27:55.153602+00:00
updated_at: 2026-08-06T11:27:55.153602+00:00
decision_date: 2026-08-06
decision_maker: gregerolsson
parent: 
archived: false

tags:
  - "#adr"
  - "#phase/decided"


exit_criteria_met: false
initiative_id: NULL
---

# ADR-4: Platform support: vendored LMDB archives built from vendored sources

## Context **[REQUIRED]**

STORE-I-0002 decision 1 ("Binding acquisition") settled the persistent backend's platform stance at inception: vendor `lmdb.odin` plus `liblmdb_darwin_arm64.a` copied from odin-vengine, with **darwin_arm64 as the only supported platform in v1** and "the known future path for others is linking a system liblmdb". That was the right call for a backend being written on one machine with no CI, but three things have changed since:

- **CI exists, across three operating systems.** The family now runs GitHub Actions on Linux, macOS, and Windows. The store and odin-rdf-sparql were pinned to `macos-latest` purely because that was the one platform with an archive — CI was shaped around the constraint rather than testing against it.
- **The `system:lmdb` fallback was never exercised.** It was a hypothesis, not a tested path. It also contradicts the reason the archive was vendored in the first place: that a build should depend on nothing outside the repo. A fallback that requires the user to install a system library is a different product from one that does not.
- **The single archive was unverifiable.** `vendor/lmdb/` held an 85KB binary with no recorded provenance beyond "copied from odin-vengine" — no upstream commit, no build recipe, no way for a reviewer or a future maintainer to confirm what was in it or reproduce it. It also shipped without LMDB's LICENSE and COPYRIGHT, which downstream projects vendoring this repo redistribute along with the binary.

The forcing question was Windows support: many Odin developers work there, and both the store and the query engine were unavailable to them.

The constraint underneath all of this is that **LMDB publishes no prebuilt binaries** — it never has, for any platform. Upstream ships source only. liblmdb is four files (`mdb.c`, `midl.c`, `lmdb.h`, `midl.h`), about 10k lines with no dependencies, which is precisely why no binaries exist: every consumer compiles it.

## Decision **[REQUIRED]**

**Vendor the LMDB C sources, build an archive per platform from them in CI, and commit the archives.** `system:lmdb` remains only as a fallback for platforms with no archive.

1. `vendor/lmdb/upstream/` holds `mdb.c`, `midl.c`, `lmdb.h`, `midl.h`, `LICENSE`, `COPYRIGHT`, and `CHANGES`, copied verbatim from `LMDB_0.9.35`, commit `69087ced3cb6082f7dcfb4fc2dcaa3b68a7e2e8c`, path `libraries/liblmdb`. The version stays 0.9.35 — see Review Triggers.

2. `.github/workflows/build-lmdb.yml` builds one archive per platform, manually triggered. Each job **installs its archive and runs the full store suite at both `Term_ID` widths on its own platform** before uploading. A published archive has been proven, not merely compiled.

   | Platform | Archive | Runner |
   | --- | --- | --- |
   | macOS arm64 | `liblmdb_darwin_arm64.a` | `macos-latest` |
   | macOS x86_64 | `liblmdb_darwin_amd64.a` | `macos-15-intel` |
   | Linux x86_64 | `liblmdb_linux_amd64.a` | `ubuntu-latest` |
   | Linux arm64 | `liblmdb_linux_arm64.a` | `ubuntu-24.04-arm` |
   | Windows x86_64 | `lmdb_windows_amd64.lib` | `windows-latest` |

3. Artifacts are downloaded and committed **by hand**. Binaries entering the tree are a deliberate act, not a side effect of a workflow run.

4. Build flags are upstream's own (`-pthread -O2`) minus `-g`. `NDEBUG` is deliberately not set — LMDB ships with its assertions live, and this build should differ from what upstream's Makefile produces in nothing but debug info. Windows uses `/MT`, not `/MD`.

5. Archives are built deterministically, so an unchanged rebuild is byte-identical and git records no new blob: `ZERO_AR_DATE=1` for Apple's `ar` (which has no `-D`), `rcsD` for GNU's.

6. The CI matrices of this repo and odin-rdf-sparql run `[ubuntu-latest, macos-latest, windows-latest]`.

This supersedes STORE-I-0002 decision 1. That initiative is completed and stays as written — it records what was decided then, correctly.

## Alternatives Analysis **[CONDITIONAL: Complex Decision]**

| Option | Pros | Cons | Risk Level | Implementation Cost |
|--------|------|------|------------|-------------------|
| Keep darwin_arm64 + `system:lmdb` elsewhere | No new binaries in the tree; smallest diff | Windows and Linux users must install a system library; the fallback stays untested; contradicts the self-contained-build rationale for vendoring at all | Medium — an untested path is a latent bug surface | None |
| Git submodule of LMDB | Exact provenance for free; a pinned upstream SHA nobody can quietly edit; trivial version bumps | `git clone` does not fetch submodules, so every consumer and every CI checkout needs an extra step — and consumers here check this repo out as a *sibling* of odin-rdf-sparql and odin-rdf-shacl, so the friction propagates to all of them. Contradicts the family's "clone side by side and run make test" story | Low technically, high ergonomically | Low |
| Vendor C sources, build per platform in CI (**chosen**) | Archives become reproducible artifacts, not trusted blobs; LICENSE/COPYRIGHT travel with the source for downstream redistribution; no fetch step for anyone; every platform is a tested path | ~1.1MB in `vendor/lmdb`, carried by every downstream project regardless of target; archives must be rebuilt to add a platform or change version | Low | Moderate — one workflow, one round trip to find the platform quirks |
| Build LMDB at consumer build time | No binaries committed at all | Requires a C toolchain for every user of the store, and Odin cannot compile C itself — the Makefile would have to shell out to `cc`, which Windows users are least likely to have configured | Medium | Moderate |

## Rationale **[REQUIRED]**

Vendoring the source is what makes the binaries defensible. The previous arrangement asked every reader to trust an opaque archive; with `upstream/` present, anyone can diff against the recorded commit and rebuild. It also fixes a licensing gap that existed regardless of platform count — projects that vendor odin-rdf-store redistribute LMDB, and needed its LICENSE and COPYRIGHT to do so.

The submodule alternative gives better provenance still, but at a cost this family cannot absorb: the projects reach each other by relative path and the documented workflow is "clone them side by side and run `make test`". Adding a step that `git clone` does not perform by default, to a repo that two sibling projects check out, buys verification that a recorded commit SHA already provides.

Building in CI rather than locally means each archive is produced on the platform it targets, by a toolchain nobody had to install, and is verified by the suite on that same platform in the same job. The verification step is the part that matters: it is what turns "the archive links" into "the backend works here", and it is what caught both platform bugs on the first run.

## Consequences **[REQUIRED]**

### Positive
- Windows and Linux, on both x86_64 and arm64, are supported and tested rather than hypothetical. The store and odin-rdf-sparql run their full suites on three operating systems.
- Every supported platform links a vendored archive. There is no untested fallback left in the supported set.
- The archives are reproducible from in-repo source at a recorded upstream commit, and LMDB's license travels with them.
- Two real portability bugs surfaced immediately, neither in LMDB: the test helpers concatenated onto `$TMPDIR` assuming the trailing slash only macOS provides (producing a path at the filesystem root on Linux), and Windows needed `/MT` because Odin links the static CRT. Both had been latent for as long as the suite ran on one platform.

### Negative
- `vendor/lmdb` grows to ~1.1MB (five archives plus sources), carried by every project that vendors this repo regardless of which platform it targets. Only one archive is ever linked, and none at all unless the consumer imports `store/kvstore`.
- Adding a platform or changing the LMDB version means re-running the workflow and committing new binaries — a deliberate manual step by design.
- Committed binaries cannot be reviewed by reading the diff. The mitigation is that they are reproducible from `upstream/` and deterministic, so a reviewer can rebuild and compare hashes.

### Neutral
- `system:lmdb` survives as the fallback for any platform without an archive, now genuinely a fallback rather than the plan for most platforms.
- The binding/library version mismatch is unchanged: `lmdb.odin` was generated from `mdb.master` while the archives are 0.9.35. The store's 17 entry points are all 0.9 API. See Review Triggers.

## Review Schedule **[CONDITIONAL: Temporary Decision]**

### Review Triggers
- **`LMDB_1.0.0` was tagged upstream on 2026-06-30.** Adopting it would resolve the long-standing mismatch between the `mdb.master`-generated binding and the linked 0.9 library, making the development-branch-only entry points real. It is a major version whose on-disk format differs from the 0.9 format STORE-A-0003 pins at version 1, so it is a migration decision — existing databases — not a rebuild. Revisit when the 1.0 line has a track record, or when something the store needs exists only there.
- **A platform outside the five above is requested.** The workflow generalizes; the question is only whether the platform can be verified in CI. A platform nobody can run the suite on should stay on the `system:lmdb` fallback rather than gain an unverified archive.
- **A GitHub runner label disappears.** `macos-13` was removed from the runner images mid-2026 and queued indefinitely rather than failing, which is how it was found. Runner labels are external dependencies of this decision.
- **LMDB publishes a 0.9.36 or later patch release.** Rebuild from the new tag; the recipe does not change.
