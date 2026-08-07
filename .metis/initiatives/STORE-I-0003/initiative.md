---
id: retire-memstore-one-backend-one
level: initiative
title: "Retire memstore: one backend, one contract"
short_code: "STORE-I-0003"
created_at: 2026-08-07T15:52:00+00:00
updated_at: 2026-08-07T16:31:07.324506+00:00
parent: STORE-V-0001
blocked_by: []
archived: false

tags:
  - "#initiative"
  - "#phase/active"


exit_criteria_met: false
estimated_complexity: M
initiative_id: retire-memstore-one-backend-one
---

# Retire memstore: one backend, one contract Initiative

## Context **[REQUIRED]**

**This initiative must precede the transaction work (STORE-T-0019, STORE-T-0022). That
sequencing is the reason it exists now rather than later** — and it is already load-bearing:
STORE-A-0005, the transaction ADR drafted just before this initiative, was **archived
undecided** on 2026-08-07 rather than amended, because more than half of it addressed a
backend that will not exist. Its surviving findings are listed in a note at the top of the
archived document and carry into the rewrite.

odin-rdf-store ships two backends of one match interface: `store/memstore` (in-memory
reference) and `store/kvstore` (LMDB). memstore came first, and STORE-I-0001's framing
made it the reference implementation the interface was defined against. It was an
architectural proposal, not a consumer request — no application and no developer has
asked for an ephemeral RDF store out loud, and in the year since, its only consumers have
been test suites.

**What forces the question now.** STORE-A-0005 (archived) designed the transaction and snapshot
model, and the design is dominated by memstore. LMDB gives kvstore snapshot isolation,
atomicity, and read-your-own-writes for free; memstore has no versioning, so the contract
had to grow machinery that exists *only* to accommodate it:

- a declared `SNAPSHOT_ISOLATION` capability constant, so the two backends can differ
  honestly;
- a capability-conditional tier in the conformance suite, which stops being a single
  uniform body of assertions;
- a write journal in memstore to make abort meaningful;
- a generation counter and a `.Stale_Txn` error, plus an entire designed-but-deferred
  upgrade path (retained-index copy-on-write) for the isolation memstore cannot offer.

Every one of those is spent on a backend with no consumer. Building them and then
deleting them is the worst available order, which is why this comes first.

**The performance argument for keeping memstore does not hold**, measured rather than
assumed:

```
shacl/memstore     71 tests    10.3 ms    0.145 ms/test
shacl/kvstore      14 tests   124.5 ms    8.9   ms/test     61× per test
tests/w3c/harness  23 tests     1.84 s    (98 entries × both backends)
```

61× per test is a large ratio around a small absolute number. Porting shacl's 71 memstore
tests to kvstore costs roughly 0.6 s. That is not a reason to maintain a second
implementation of the interface.

**What the family's own principle says.** The vision's first principle is that the
interface "grows only on evidence from real consumers." Applied symmetrically, absence of
evidence is grounds for shrinking. STORE-T-0019 and STORE-T-0022 both independently
identified memstore as the hard question and both warned against letting the weaker
backend's cost shape the contract. Removing it answers that warning at the root instead
of negotiating around it.

**What removal actually decides, and must be recorded as deciding.** With one backend,
the match interface's contract *is* LMDB's semantics — including the costs STORE-A-0005
documents as backend detail (an open read transaction pins pages; an open write
transaction holds the environment writer lock). The vision's claim that one suite passing
against two backends is "what makes 'multiple backends of one interface' a demonstration
rather than a claim" no longer holds; the suite becomes a regression suite rather than a
portability proof. That is an acceptable trade if the family accepts LMDB as its only
backend — but it should be stated in an ADR, not discovered later.

**Two consumers of ephemeral storage that are not the test suite** were found while
scoping this, and the plan below answers both rather than assuming them away:

1. **`shacl_memstore.compile_turtle`** — its own doc comment calls it "the convenience
   path most callers want — a shapes graph in a Turtle file, parsed into a memstore and
   compiled." `shacl/kvstore`'s `compile` takes a `^Session` over an already-open store,
   so there is no kvstore equivalent. LMDB has no anonymous/in-memory mode: without a
   replacement, that one call becomes make-a-temp-directory, open, load, compile, close,
   unlink. A shapes graph is small, ephemeral and per-process — exactly the shape
   memstore served.
2. **odin-rdf-shacl's `purity` target** — `make check` builds a memstore-only binary and
   asserts it carries no `mdb_` symbols. Its stated purpose (SHACL-A-0001 decision 1) is
   that "a consumer that only ever wants an in-memory store" must not link LMDB. With no
   in-memory store, the property has no beneficiary. The core/instantiation split is
   still good structure and still lets a future backend in, but its decisive recorded
   justification evaporates, and that is a change to a sibling repo's ADR.

**Measured footprint.** The intuition inverts once counted:

| | code | tests |
|---|---|---|
| `odin-rdf-store/store/memstore` | 832 | 601 |
| `odin-rdf-shacl/shacl/memstore` | 528 | 3,540 |
| `odin-rdf-sparql/sparql/memstore` | 299 | 2,415 |
| **total** | **1,659** | **6,556** |

Deleting the implementations is cheap. **Porting 6,556 lines of tests across 10 test
files in two sibling repos is the initiative.** The assertions themselves are expected to
survive unchanged — what changes is backend setup and teardown — but shacl's kvstore-side
test count goes from 14 to ~85, so the port is also a coverage expansion on a path that
has been thinner than the memstore one.

## Goals & Non-Goals **[REQUIRED]**

**Goals:**
- **Remove `store/memstore`** and its conformance instantiation from odin-rdf-store.
- **Keep the shapes-from-a-Turtle-file path**, by making the caller's store explicit
  rather than by giving shacl a cheaper store to own privately (Detailed Design point 2).
- **Port, don't drop, the tests.** Every assertion currently running against memstore in
  all three repos runs against kvstore afterwards. Suite counts may consolidate; coverage
  must not shrink.
- **An ADR recording the single-backend stance** and what it does to STORE-A-0002, the
  vision, and STORE-I-0001's reference-implementation framing.
- **Coordinated proposals** to odin-rdf-sparql and odin-rdf-shacl — those repos do their
  own removals; this initiative supplies the evidence and the sequencing, and does not
  edit them.
- **A clear path for the transaction ADR's rewrite** on the far side: with the declared
  capability, the conditional conformance tier, the memstore journal, the generation
  counter, and the retained-index upgrade path all gone, what remains is one transaction
  model with snapshot isolation unconditionally. The findings worth keeping are enumerated
  in the archived STORE-A-0005's opening note.

**Non-Goals:**
- Implementing transactions. That is the next initiative; this one only clears its path.
- Replacing memstore with a different in-memory backend, or a `Dataset_Interface` vtable
  to make future backend swaps cheaper (STORE-A-0002 point 4 stands: add it when a
  consumer needs it).
- Removing the backend-independent core / thin-instantiation split in odin-rdf-sparql and
  odin-rdf-shacl. That structure survives; only the memstore instantiation goes.
- Deleting the `conformance` package or its `Backend` adapter. A single-backend suite is
  still the executable contract, and the adapter is what a future backend would fill.
- `remove` (STORE-T-0023) and `insert_all` (STORE-T-0024).

## Architecture **[CONDITIONAL: Technically Complex Initiative]**

The dependency direction makes the order non-negotiable. Sibling repos resolve
`store:` to this checkout, so deleting `store/memstore` breaks odin-rdf-sparql and
odin-rdf-shacl the instant it happens. Everything additive lands first; the deletion is
last.

```
 1. store: ADR (single-backend stance)        additive, breaks nothing
        ↓
 2. sparql: port + delete   ┐ parallel, in their own repos,
 3. shacl:  port + delete   ┘ raised as proposals
        ↓ (nothing imports store/memstore any more)
 4. store: port own suite, delete store/memstore
 5. all:   documentation sweep
    ( kvstore.open_ephemeral — optional, decided during 2/3 on the
      duplication they actually produce; blocks nothing )
```

**Nothing needs to land before the ports.** The first draft of this plan put an ephemeral
kvstore ahead of them as the substitution that keeps removal from being a regression.
Sketching `compile_turtle` (Detailed Design point 2) removed that dependency: the right
answer there is that shacl takes a store the caller opened, not that shacl gets a cheaper
way to open one itself. What remains of the ephemeral-store idea is a boilerplate
convenience, and it is better decided on evidence from the ports than assumed by the plan.

## Detailed Design **[REQUIRED]**

Recommendations for the design phase, not settled decisions — each needs sign-off.

1. **Single-backend stance, recorded as an ADR.** The new ADR supersedes the
   *demonstration* claim rather than STORE-A-0002 itself: the convention (procedure sets,
   no vtable) is unchanged and still correct, but "one shared conformance suite runs
   verbatim against both backends" stops being true, and the interface's semantics become
   LMDB's semantics by definition. Recommend stating explicitly that a second backend
   remains welcome and that the `conformance.Backend` adapter is retained precisely so
   one can be added without archaeology.
2. **`compile_turtle`: the caller owns the storage, not shacl.** This is the item that
   needed the most sketching, and the answer moves it *away* from ephemeral stores rather
   than onto one.

   Today's signature builds a private memstore, loads into it, compiles, and destroys it
   before returning:

   ```odin
   // shacl/memstore — today
   compile_turtle :: proc(s: ^shacl.Shapes, source: []byte, base := "",
                          allocator := context.allocator)
                    -> (err: shacl.Error, load_err: store.Load_Error)
   ```

   Its doc comment gives the reason it lives in an instantiation package: "the core names
   no backend and imports none, which is what keeps LMDB out of the link of every consumer
   that only wants an in-memory store (SHACL-A-0001)." **That rationale dies with
   memstore** — the same way the `purity` target's does. What remains is a procedure that
   silently owns a database, which is a worse thing for a validation library to do than
   it was when the database was a hash map.

   Meanwhile `shacl/kvstore` already documents the replacement, on `Session`: "A caller
   whose shapes and data live in different graphs of one store uses two Sessions over the
   same store, which is a struct rather than a handle and costs nothing." Shapes in a
   named graph is the shape that side was already designed for. Recommended:

   ```odin
   // shacl/kvstore — proposed
   compile_turtle :: proc(s: ^shacl.Shapes, st: ^kvstore.Store, source: []byte,
                          graph: rdf.Graph_Label = nil, base := "",
                          allocator := context.allocator)
                    -> (err: shacl.Error, load_err: store.Load_Error, db_err: kvstore.Error)
   ```

   It loads the document into `graph` of a store the caller opened, binds a Session to
   that graph, and compiles. shacl gains no storage lifetime, names no temp directory, and
   makes no decision the caller should be making. The ownership property that
   SHACL-A-0001 turns on is unaffected: the model still owns every term it holds, so the
   caller may close the store immediately afterwards.

   **The wrinkle, which must be documented loudly rather than discovered.** The obvious
   worry is that shapes now permanently pollute the caller's store, since there is no
   `remove` (STORE-T-0023). The obvious answer — "reload the same shapes into the same
   named graph; set semantics makes it a no-op" — **is wrong.** `load_turtle` applies
   per-load blank-node scoping (`fresh_blank_txn`), and a shapes graph is blank-node
   dense (`sh:property [ sh:path ex:p ; sh:minCount 1 ]`). Every load mints fresh blank
   nodes, so the quads differ, so nothing dedupes: repeated loads accumulate a *second
   copy of every blank-node-rooted shape*, and a later compile from that graph sees
   duplicated shapes. Unbounded growth and wrong answers, not just waste.

   So the contract is **compile once, validate many** — load shapes at startup, keep the
   `Shapes` value (it outlives the store by design), never recompile per request. That is
   the sane pattern anyway, and it is what `odin-rdf-app` wants. It must be stated in the
   procedure's doc comment with the reason, because the failure is silent. When
   STORE-T-0023 lands, dropping and reloading a shapes graph becomes expressible and the
   restriction relaxes.

3. **Ephemeral kvstore: demoted to optional, and decided on its own merits.** With
   point 2, nothing in shacl needs it — which is the right outcome, because it means the
   ephemeral-store question is no longer being forced by a consumer that shouldn't have
   been asking.

   What remains is a boilerplate argument, and it is a real one: the OS-temp-directory
   dance (`TMPDIR` → `TEMP` → `TMP` → `/tmp`, trailing-separator trim, pid suffix) is
   **already duplicated verbatim** in `store/kvstore/kvstore_test.odin` and
   `shacl/kvstore/link_test.odin`, comments and all. The port would spread it across ~85
   shacl tests and the sparql evaluation harness. That boilerplate is not introduced by
   this initiative; the question is only whether it stays copy-pasted in test code or
   becomes one supported procedure.

   If it is adopted, recommend it not be a directory that lingers:

   ```odin
   // store/kvstore — proposed, optional
   open_ephemeral :: proc(opts := DEFAULT_OPTIONS, allocator := context.allocator)
                     -> (s: ^Store, err: Error)
   ```

   Implemented as `NOSUBDIR | NOLOCK | NOSYNC` over a unique temp file, with the path
   **unlinked immediately after `env_open` returns** on POSIX: the inode stays alive while
   LMDB holds the descriptor, is invisible in the filesystem namespace, and is reclaimed
   by the kernel on close *or on crash*. No cleanup path, no stale directories, nothing
   for a later run to trip over — which is the substance of the objection to "a procedure
   that touches the temp dir". `NOLOCK` is legitimate here because an ephemeral store is
   exclusively the opening process's. Windows has no unlink-while-open; it falls back to
   delete-on-close and leaks one file on abnormal termination, which should be stated
   rather than papered over.

   Recommend deciding this **after** the ports are underway, on the evidence of how much
   duplication they actually produce, rather than building it speculatively first.
4. **The `purity` target's fate.** Three options, for odin-rdf-shacl to choose: delete it
   with memstore; retarget it at the `shacl` core package alone (still catches a stray
   `kvstore` import in the core, still meaningful as internal hygiene, but no longer
   protects a consumer); or retire it and amend SHACL-A-0001 decision 1 to record that
   its justification changed. Recommend the second plus the amendment — the check is
   cheap and the split it guards is what a future backend would use.
5. **Test port strategy.** Recommend mechanical setup/teardown substitution with
   assertions untouched, one file at a time, each verified green before the next, at both
   `Term_ID` widths. Explicitly *not* recommended: consolidating or rewriting assertions
   during the port — a coverage change hidden inside a mechanical change is the main risk
   here.
6. **Suite runtime budget.** Recommend recording before/after wall-clock per repo in the
   status updates. If a suite crosses a threshold that makes the inner development loop
   painful, per-test store reuse (one ephemeral store per test file rather than per test)
   is the first remedy, not reinstating memstore.
7. **The transaction ADR is written fresh, not revised.** STORE-A-0005 was archived
   undecided on 2026-08-07 for this reason: the capability device is more than half its
   text, and an ADR whose central mechanism is deleted reads worse amended than replaced.
   The rewrite takes a new short code and carries forward the findings enumerated in the
   archived document's opening note — the handle and its two modes, the `_txn` procedure
   set with autocommit defined beneath it, the universal guarantees (now simply *the*
   guarantees), kvstore's publication work including `Store.next` restore-on-abort, and
   the scope guard. **Two proposed edits to STORE-A-0002 are outstanding and only one
   will land**: the capability-tier amendment drafted inside the archived ADR is dead,
   and this initiative's own ADR (point 1) must handle A-0002's demonstration claim
   instead. They must not be applied together.

## Testing Strategy **[CONDITIONAL: Separate Testing Initiative]**

The suite is the deliverable being moved, so its integrity is the initiative's main
correctness question.

- **Test-count parity, per repo, recorded.** Before and after counts for every suite that
  had a memstore instantiation. A drop is a defect unless it is a named, justified
  consolidation.
- **Both `Term_ID` widths**, as always — the ports must run at both, and kvstore is the
  width-sensitive backend (its meta records the width and refuses a mismatch).
- **The conformance suite keeps its `Backend` adapter** and runs against kvstore alone.
  Its per-backend instantiation file for memstore goes; the checks do not.
- **CI on three operating systems** is where the port's cost actually lands: kvstore
  tests do filesystem work, and Windows is the least-exercised platform. Recommend
  watching CI wall-clock there specifically.
- **The W3C harnesses** (shacl 98 entries, sparql 483 evaluation tests across 35 suite
  directories) currently run against both backends. After the port they run against
  kvstore at both widths — the entry counts must be identical.

## Alternatives Considered **[REQUIRED]**

- **Keep memstore and build the capability device (STORE-A-0005 as drafted, now archived).** The status
  quo plus transactions. Honest and already designed, but it spends the family's next
  significant piece of interface complexity on a backend no consumer has asked for, and
  makes the conformance suite conditional forever. Rejected as the more expensive path to
  a worse contract — though it remains the fallback if a real ephemeral consumer surfaces
  during design.
- **Keep memstore, frozen, without transaction support.** Superficially attractive: no
  journal, no capability constant. But a backend that cannot implement the interface is
  not a backend of the interface, and the conformance suite would have to grow an
  "implements transactions" tier anyway — the same conditional machinery under a different
  name, plus a permanently second-class package. Rejected.
- **Give shacl an ephemeral store to own privately** — keep `compile_turtle`'s signature
  and swap memstore for `kvstore.open_ephemeral` underneath. This was the first draft's
  recommendation. Rejected on sketching it: it preserves the part of `compile_turtle` that
  is actually wrong — a validation library silently owning a database — and it forces the
  ephemeral-store question to be answered by the consumer least entitled to ask it. The
  caller already has a store open for the data graph; making it explicit costs one
  parameter.
- **Replace memstore with an in-memory LMDB (tmpfs / `WRITEMAP` + `NOSYNC`).** Gets
  ephemerality without a second implementation and without temp-directory management on
  Linux. Rejected: tmpfs is not portable to macOS or Windows. The portable version of the
  same intent is `NOSUBDIR` plus unlink-after-open (Detailed Design point 3), which gets
  an invisible, crash-reclaimed file on every POSIX platform.
- **A flat scratch container inside shacl** — ~150 lines filling the five match adapters
  with linear scans over a small shapes graph, no indexes, no conformance obligation.
  Tempting because a shapes file is a few hundred triples and the compiler is the only
  reader. Rejected: it is memstore under another name, it is a third instantiation of the
  engine to keep parallel, and its one real benefit — no LMDB in the link — is already
  gone once kvstore is the only backend.
- **Defer the whole question until after the transaction initiative.** Rejected: this is
  precisely the order that guarantees building and then deleting the capability device,
  the journal, and the generation counter.

## Implementation Plan **[REQUIRED]**

Direction; task decomposition happens at the decompose phase with sign-off.

1. **ADR: the single-backend stance** — what it does to STORE-A-0002's demonstration
   claim, to the vision's "multiple backends of one interface" and its in-memory-backend
   success criterion, and to STORE-I-0001's reference-implementation framing. Decided
   before any code moves.
2. **Proposal to odin-rdf-sparql** — port `sparql/memstore`'s 2,415 test lines onto
   kvstore, delete the package (299 lines), keep the core/instantiation split. Their repo,
   their sequencing.
3. **Proposal to odin-rdf-shacl** — port 3,540 test lines, delete the package (528
   lines), re-sign `compile_turtle` to take the caller's store and scratch graph
   (Detailed Design point 2, including the compile-once contract and the blank-node
   reason for it), and settle the `purity` target and the SHACL-A-0001 decision-1
   amendment.
4. **Remove `store/memstore`** — port `conformance/memstore_test.odin` and
   `conformance/roundtrip_memstore_test.odin`, move the bench harness onto kvstore, delete
   the package. Only after 2 and 3 have landed in the sibling checkouts.
5. **Documentation sweep** — `.metis/vision.md`, `README.md` in all three repos, the
   shared `CLAUDE.md`, `store/interface.odin`'s backend list, and the ADRs that name
   memstore in passing.
6. **Write the transaction ADR fresh** (STORE-A-0005 archived undecided; see Detailed
   Design point 7) and re-open the transaction work against a single-backend contract.

Steps 2 and 3 are parallel and are the long pole; nothing blocks them.
`kvstore.open_ephemeral` (Detailed Design point 3) is optional, decided during 2 and 3 on
the duplication they actually produce, and sequenced wherever it is convenient.

## Status Updates

- **2026-08-07 — Created.** Proposed in an odin-rdf-app session where STORE-T-0019 and
  STORE-T-0022 originated: with transactions entering the interface, implementing MVCC-ish
  semantics in memstore to satisfy test suites alone is the wrong trade. Scoping for this
  document confirmed the measured footprint (1,659 code / 6,556 test lines), and found the
  two non-test dependants named in Context — `compile_turtle` and shacl's `purity` target —
  which the plan answers rather than assumes away. Awaiting review before the design phase.
- **2026-08-07 — `compile_turtle` sketched properly, and the plan changed because of it.**
  The first draft answered it with `kvstore.open_ephemeral`, which was the wrong shape: it
  preserved a validation library silently owning a database and let a consumer that
  shouldn't have been asking force the ephemeral-store question. The answer is that the
  caller supplies the store and the scratch graph — a pattern `shacl/kvstore`'s `Session`
  doc already describes. Sketching it also surfaced a silent-failure trap: per-load
  blank-node scoping means reloading a shapes graph does *not* dedupe, so repeated loads
  accumulate duplicate shapes; the compile-once contract and its reason must be in the doc
  comment. `open_ephemeral` is demoted to an optional boilerplate convenience, blocking
  nothing, and the ports now have no prerequisite.
- **2026-08-07 — Decomposed into 8 tasks**, after two decisions taken at the design gate:
  **port both benchmarks** rather than delete either, and **the sibling work is a proposal
  task per repo** rather than tasks under this initiative, since those repos own their own
  decisions and short-code sequences.

  STORE-T-0025 (ADR + vision retraction) → then STORE-T-0026 (sparql proposal),
  STORE-T-0027 (shacl proposal), STORE-T-0028 (own suite), STORE-T-0029 (bench) in
  parallel → STORE-T-0030 (delete) → STORE-T-0031 (docs + release) and STORE-T-0032
  (transaction ADR rewrite) in parallel. Dependencies recorded in each task's `blocked_by`
  frontmatter.

  Scoping the tasks surfaced a **third non-test dependant** beyond `compile_turtle` and
  `purity`: the benchmarks, and they are the awkward ones. `shacl/bench/consumers.odin`
  uses memstore *deliberately* — memstore's `lookup_term` borrows and allocates nothing
  while kvstore's copies into the caller's allocator, so on kvstore every allocation figure
  carries term materialization. `store/bench/lmdb.odin` measures "match-scan throughput
  compared against the in-memory backend", a comparison that is removed rather than ported.
  Decision: port both, accept the changed question, and explicitly annotate STORE-I-0001's
  recorded baselines as measured against a backend that no longer exists.

  Also found: `conformance/roundtrip_memstore_test.odin` (179 lines) has **no kvstore
  counterpart** and is the executable form of a vision success criterion, so it must be
  ported rather than deleted alongside `conformance/memstore_test.odin`, which is genuinely
  redundant. Both are STORE-T-0028.

  Awaiting review before activation.

## Exit Criteria **[REQUIRED]**

- [ ] An ADR records the single-backend stance and settles what it does to STORE-A-0002,
      to the vision's "multiple backends of one interface" claim and in-memory-backend
      success criterion, and to STORE-I-0001's reference-implementation framing.
- [ ] `store/memstore` is gone, and nothing in odin-rdf-store, odin-rdf-sparql, or
      odin-rdf-shacl imports it.
- [ ] Test counts per repo are equal to or greater than before the port, at both
      `Term_ID` widths, on all three CI platforms — recorded before and after, with any
      reduction named and justified.
- [ ] The shapes-from-a-Turtle-file path survives on `shacl/kvstore` over a
      caller-supplied store, with the compile-once contract and its blank-node reason in
      the doc comment — or its removal is a recorded decision with the reason.
- [ ] odin-rdf-shacl's `purity` target is retargeted, retired, or deleted — decided, not
      left broken, with SHACL-A-0001 amended if its justification changed.
- [ ] Documentation across all three repos and the shared `CLAUDE.md` describes one
      backend.
- [ ] A replacement transaction ADR is written against a single-backend contract, carrying
      forward the archived STORE-A-0005's surviving findings, and the transaction work can
      be decomposed without a capability device.
- [ ] Exactly one of the two outstanding edits to STORE-A-0002 has been applied — this
      initiative's demonstration-claim change — and the archived ADR's capability-tier
      amendment has not.- **2026-08-07 — All eight tasks completed; the initiative stays active. Two exit criteria
  are open, and neither can be closed by writing a document.**

  STORE-T-0031 and STORE-T-0032 completed, which finishes the decomposition: T-0025 (ADR +
  vision retraction), T-0026 / T-0027 (sibling proposals, filed and since completed in those
  repos as SPARQL-T-0023 and SHACL-T-0028), T-0028 (own suite), T-0029 (benchmarks), T-0030
  (deletion), T-0031 (docs + release), T-0032 (the transaction ADR, written as STORE-A-0007).

  **Exit criterion 3 — "test counts … at both `Term_ID` widths, on all three CI platforms" —
  is unverified, and the reason is that none of this work has been pushed.** All three repos
  are ahead of `origin/main` with the entire retirement sequence sitting locally: 8 commits
  here, 3 in odin-rdf-sparql, 5 in odin-rdf-shacl. The most recent CI run in each repo
  predates every one of them — odin-rdf-store's newest is `f896b7b` (2026-08-06), before
  T-0028 and T-0030 existed. So the ports are green on **local darwin_arm64 only**, which
  STORE-T-0028's status update already said in as many words.

  This is the risk the Testing Strategy named specifically: "CI on three operating systems is
  where the port's cost actually lands: kvstore tests do filesystem work, and Windows is the
  least-exercised platform." Every ported test now touches the filesystem where its memstore
  predecessor did not, and the temp-path dance differs on Windows. Pushing is the verification
  step, and it has not happened.

  **Exit criterion 6 — "documentation across all three repos and the shared `CLAUDE.md`
  describes one backend" — is open by decision, not by oversight.** The store repo and the
  checkout-root `CLAUDE.md` are done. Two summary lines near the top of the sibling READMEs
  still count two backends (odin-rdf-sparql's "run against **both** storage backends",
  odin-rdf-shacl's "against both storage backends"); both bodies are already correct and cite
  STORE-A-0006. Greger deferred these to after odin-rdf-store v0.2.0 ships.

  **To close:** push all three repos and confirm CI green on Linux, macOS and Windows at both
  widths with the recorded counts (store 64 → 58, the −6 named and justified in T-0028); tag
  v0.2.0; then take the two sibling README lines. The remaining six exit criteria are met.
- **2026-08-07 — Pushed; CI green on all three platforms. Exit criterion 3 is met for this
  repo.** Run `31217331487` (`282b18e`): ubuntu-latest, windows-latest and macos-latest all
  success, vet plus tests at both `Term_ID` widths. This is the first CI this repo has seen
  since `f896b7b` on 2026-08-06, so it covers the whole retirement sequence at once --
  STORE-T-0025 and T-0028 through T-0032. Windows, the platform the Testing Strategy singled
  out because kvstore tests do filesystem work, passed in 57s.

  **Final counts, per width: store 5, store/kvstore 33, tests/readme 2 = 40**, identical on
  all three platforms. The arithmetic across the initiative, since the raw total fell and the
  criterion asks for a justification of any reduction:

  | | store | memstore | kvstore | conformance | readme | total |
  |---|---:|---:|---:|---:|---:|---:|
  | before | 5 | 17 | 29 | 10 | 3 | **64** |
  | after T-0028 | 5 | 17 | 33 | 0 | 3 | **58** |
  | after T-0030 | 5 | — | 33 | 0 | 2 | **40** |

  Every unit of the 64 → 40 drop is memstore's own tests leaving with memstore: the redundant
  conformance instantiation (−6, the 4 round-trip tests moved into kvstore intact rather than
  being deleted), the memstore package's own 17, and the memstore quick start in
  `tests/readme` (−1). **No assertion was rewritten and no kvstore coverage was lost** —
  kvstore went 29 → 33. Coverage against the surviving backend is strictly greater than
  before, which is what the criterion was protecting.

  Criterion 3 is met **for odin-rdf-store only**. It reads "per repo", and odin-rdf-sparql
  (3 commits) and odin-rdf-shacl (5 commits) are still unpushed, so their ports remain
  verified on local darwin_arm64 alone. Criterion 6 is unchanged and still deferred.
