---
id: documentation-sweep-and-release
level: task
title: "Documentation sweep and release decision"
short_code: "STORE-T-0031"
created_at: 2026-08-07T16:22:27+00:00
updated_at: 2026-08-07T20:43:51.254468+00:00
parent: STORE-I-0003
blocked_by: [STORE-T-0030]
archived: false

tags:
  - "#task"
  - "#phase/completed"


exit_criteria_met: true
initiative_id: STORE-I-0003
---

# Documentation sweep and release decision

## Parent Initiative **[CONDITIONAL: Assigned Task]**

[[STORE-I-0003]]

## Objective **[REQUIRED]**

Make every document describe one backend, and settle how this ships.

The vision retraction is **not** here — it belongs to STORE-T-0025, deliberately, so the
strategic claim is withdrawn with its reasoning attached rather than as a cleanup. What
remains here is the prose that describes the library to a reader: the README, the contract
document, the shared checkout-root guide, and the code index.

## Acceptance Criteria

## Acceptance Criteria

## Acceptance Criteria **[REQUIRED]**

- [x] `store/interface.odin` — the contract document's backend list ("this repo ships two:
      store/memstore (the in-memory reference) and store/kvstore") is corrected, and the
      contract is re-read for anything phrased as a portability guarantee that is now a
      description of LMDB. The `find_term` paragraph's "in persistent backends" hedging is
      an example: with one backend the hedge is noise.
- [x] `README.md` — the two-backend framing, any comparison table, and any example that
      opens a memstore.
- [x] `.metis/code-index.md` — regenerated or hand-corrected for the removed package.
- [x] The shared `CLAUDE.md` at the checkout root. Note it is **not in any repository** —
      the root is the shared checkout directory, not a repo — so the edit lands outside
      version control and is easy to forget.
- [x] ADRs that name memstore in passing (STORE-A-0001 point 7 "the in-memory backend
      compares encoded quads positionally…", STORE-A-0003, STORE-A-0002's 2026-08-04
      amendment) — annotated where the reference is now historical, **not** rewritten. An
      ADR records what was decided when; it should not be edited to pretend memstore never
      existed.
- [x] **Release decision taken and recorded**: the store is tagged v0.1.0 and this removes
      a public package, so there is no deprecation path — the package either exists or it
      does not. Decide the version (v0.2.0 is the obvious answer) and whether anything
      outside these four repos has picked the library up, which determines whether this
      needs an announcement or only a tag.
- [~] The three repos' READMEs agree with each other about what the family is. **Checked and reported, not fixed** — see the 2026-08-07 deferral update. The sibling
      READMEs belong to their initiatives (STORE-T-0026, STORE-T-0027), but the
      cross-references between them are checked here.

## Implementation Notes **[CONDITIONAL: Technical Task]**

### Technical Approach

`grep -rn "memstore\|in-memory"` across the repo and the checkout root, then triage each hit
into: correct it (describes current state), annotate it (records history), or leave it
(genuinely about memory, not about the backend).

The distinction between correcting and annotating is the whole judgment in this task. The
default for `.metis/` documents is annotate; the default for `README.md`, package docs, and
`code-index.md` is correct.

### Dependencies

Blocked by STORE-T-0030 — documenting the removal before it happens would leave the repo
describing a state it is not in. Blocks nothing; STORE-T-0032 can run in parallel.

### Risk Considerations

Low risk, high tedium, and the usual failure is partial completion: a README updated and a
package doc comment missed, leaving the library describing itself two ways. The `CLAUDE.md`
at the checkout root is the single most likely miss, because it is outside git and will not
appear in any diff.

## Status Updates **[REQUIRED]**

- **2026-08-07 — Created in STORE-I-0003's decomposition.** The release/versioning question
  was raised at decomposition and folded here rather than blocking; it needs an answer
  before this task closes.
- **2026-08-07 — Sweep done; the release decision is the one item still open and needs
  sign-off.** Corrected (the default for prose that describes the library to a reader):

  - `store/interface.odin` — the "this repo ships two" backend list. Re-reading it for
    phrasing that was a portability guarantee and is now a description of LMDB found four
    more: `find_term`'s "in persistent backends, writes nothing" hedge; "persistent backends
    hold cursors" on iterator release; "backends instantiate it"; and the allocator bullet.
    One was not a hedge but a genuine staleness — the procedure set listed
    `dataset_init`/`dataset_destroy`, which **no remaining backend implements under those
    names** (kvstore has `open(path, opts)` / `close`). They were memstore's names. The
    contract now says lifecycle is deliberately outside the convention and names kvstore's,
    which is honest about what the convention actually fixes.
  - `store/term_id.odin` — the package doc's two-backend list, and "Persistent backends must
    record the width".
  - `conformance/conformance.odin` — the package doc pointed at `inmem_test.odin` for an
    example instantiation; that file is gone, so it points at
    `store/kvstore/conformance_test.odin` and says plainly that the suite is now a regression
    suite whose adapter is retained for a second backend.
  - `README.md` — the two-backend opening, the package table, and **both quick-start
    examples**, which were memstore and are now kvstore. `tests/readme` had already moved in
    STORE-T-0030, so the README was describing an API the tests no longer compiled; the
    examples are back in step with it and `make test` is green at both widths. The
    "same dataset, on disk" section is folded away — with one backend there is no "same
    dataset, elsewhere" to contrast against.
  - `tests/readme/readme_test.odin` — one comment comparing against "the in-memory
    dictionary's borrowed strings".
  - The shared `CLAUDE.md` at the checkout root. **This task's acceptance criterion is out of
    date about it**: it says the root "is **not in any repository** … so the edit lands outside
    version control and is easy to forget". The root has since become one — it is the
    `odin-rdf/.github` org repository (`git@github.com:odin-rdf/.github.git`, HEAD `10fdfa3`),
    carrying the org-wide contributing, security and issue templates, and `CLAUDE.md` is
    tracked in it. So the edit *is* under version control and *will* appear in a diff — just
    in a different repository's, which needs its own commit and is a different way to lose it.
    All three project sections were corrected, plus the intro's
    "LMDB being the single, isolated exception", which is no longer isolated. Two incidental
    corrections found while there and made rather than left: sparql's package list omitted
    `sparql/srj` and `sparql/srx`, and the same section listed result serialization as out of
    scope when it ships.

  Annotated, not rewritten (the default for `.metis/`): **STORE-A-0003** gains an Amendments
  section — its four in-memory references are the recorded reasoning behind pinned bytes, two
  of which keep force on their own terms, and **format version 1 is unaffected**.
  STORE-A-0001 point 7 and STORE-A-0002's amendment were already done in STORE-T-0025.

  Also annotated, and **not in this task's acceptance criteria** — found by the `grep`-and-triage
  the Technical Approach prescribes, and left in rather than deferred because the failure mode
  is a reader picking one up and following it: seven open backlog items whose effort estimates
  and acceptance criteria are written against two backends (STORE-T-0015, -0016, -0017, -0018,
  -0020, -0023, -0024). Two mattered beyond tidiness. **STORE-T-0020** carries an acceptance
  criterion — "allocates nothing on either backend … the in-memory backend already achieves it"
  — that is now unmeetable as written; the requirement survives on its own merits but must be
  demonstrated rather than inherited. **STORE-T-0018** loses its exact-count half, which
  sharpens rather than softens its interface question: no implementation can return an exact
  count any more, so whatever the procedure promises must be satisfiable by an estimate.
  STORE-T-0014 is completed and was left alone — its memstore references are the record of
  work done.

  `.metis/code-index.md` needed neither: it has never named memstore. It reads "0 files"
  because `metis index_code` parses Rust, Python, TypeScript, JavaScript and Go, and this is
  an Odin repository. A note now says so, so the emptiness is not read as a sweep that missed
  something.

  **Cross-repo check — two stale claims remain, and they are in sibling repos.** The bodies of
  both READMEs are correct and carry the STORE-A-0006 reference, but a summary line near the
  top of each still counts two backends: odin-rdf-sparql's "every one of them run against
  **both** storage backends", and odin-rdf-shacl's "against both storage backends, at both
  `Term_ID` widths". Left unedited — those READMEs belong to STORE-T-0026 and STORE-T-0027 and
  to repos that own their own decisions. Raised for their owner rather than fixed here.

  **Still open: the release decision**, which needs Greger. The repo is tagged v0.1.0 and
  v0.1.1, has no CHANGELOG, and this removes a public package outright — there is no
  deprecation path, since the package either exists or it does not.
- **2026-08-07 — Release decision taken: v0.2.0, with a CHANGELOG.** Decided by Greger. The
  0.x semver convention puts breaking changes in the minor bump, which this is: a public
  package removed outright, with no deprecation path available, since the package either
  exists or it does not.

  **No announcement.** Nothing outside the four family repos is known to consume the library,
  and the three siblings were ported and verified green before the deletion landed
  (STORE-T-0026 through STORE-T-0030), so there is no consumer to warn who is not already on
  the far side of the change.

  `CHANGELOG.md` is new — the repo had none — and starts at 0.2.0 with 0.1.1 and 0.1.0
  reconstructed from their annotated tags. The 0.2.0 entry leads with the removal as
  **breaking with no deprecation path** and states the two consequences a consumer actually
  trips over: you link LMDB whether or not you wanted it, and every dataset is now a
  filesystem path with a lifetime you have to own. It also records the `dataset_init` /
  `dataset_destroy` disappearance from the published procedure set, which is the one part of
  the port that is not a rename. `README.md` gains a Releases section pointing at it.

  Tagging is left to Greger along with the commits.

- **2026-08-07 — Sibling READMEs deferred by decision.** The two stale summary lines in
  odin-rdf-sparql and odin-rdf-shacl are left as found; Greger will take them after
  odin-rdf-store v0.2.0 is released. This task's cross-reference criterion is therefore
  discharged as *checked and reported*, not as fixed — the finding is recorded in the
  previous update so it survives if the follow-up is picked up in another session.