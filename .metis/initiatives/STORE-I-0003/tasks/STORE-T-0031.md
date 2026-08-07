---
id: documentation-sweep-and-release
level: task
title: "Documentation sweep and release decision"
short_code: "STORE-T-0031"
created_at: 2026-08-07T16:22:27.000000+00:00
updated_at: 2026-08-07T16:22:27.000000+00:00
parent: STORE-I-0003
blocked_by: ["STORE-T-0030"]
archived: false

tags:
  - "#task"
  - "#phase/todo"


exit_criteria_met: false
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

## Acceptance Criteria **[REQUIRED]**

- [ ] `store/interface.odin` — the contract document's backend list ("this repo ships two:
      store/memstore (the in-memory reference) and store/kvstore") is corrected, and the
      contract is re-read for anything phrased as a portability guarantee that is now a
      description of LMDB. The `find_term` paragraph's "in persistent backends" hedging is
      an example: with one backend the hedge is noise.
- [ ] `README.md` — the two-backend framing, any comparison table, and any example that
      opens a memstore.
- [ ] `.metis/code-index.md` — regenerated or hand-corrected for the removed package.
- [ ] The shared `CLAUDE.md` at the checkout root. Note it is **not in any repository** —
      the root is the shared checkout directory, not a repo — so the edit lands outside
      version control and is easy to forget.
- [ ] ADRs that name memstore in passing (STORE-A-0001 point 7 "the in-memory backend
      compares encoded quads positionally…", STORE-A-0003, STORE-A-0002's 2026-08-04
      amendment) — annotated where the reference is now historical, **not** rewritten. An
      ADR records what was decided when; it should not be edited to pretend memstore never
      existed.
- [ ] **Release decision taken and recorded**: the store is tagged v0.1.0 and this removes
      a public package, so there is no deprecation path — the package either exists or it
      does not. Decide the version (v0.2.0 is the obvious answer) and whether anything
      outside these four repos has picked the library up, which determines whether this
      needs an announcement or only a tag.
- [ ] The three repos' READMEs agree with each other about what the family is. The sibling
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
