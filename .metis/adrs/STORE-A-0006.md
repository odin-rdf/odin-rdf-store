---
id: 001-one-backend-odin-rdf-store-is
level: adr
title: "One backend: odin-rdf-store is a library over LMDB"
number: 1
short_code: "STORE-A-0006"
created_at: 2026-08-07T16:35:00.000000+00:00
updated_at: 2026-08-07T16:35:00.000000+00:00
decision_date: 
decision_maker: 
parent: 
archived: false

tags:
  - "#adr"
  - "#phase/draft"


exit_criteria_met: false
initiative_id: NULL
---

# ADR-6: One backend: odin-rdf-store is a library over LMDB

## Context **[REQUIRED]**

odin-rdf-store has shipped two backends of one match interface since STORE-I-0001:
`store/memstore` (in-memory) and `store/kvstore` (LMDB). memstore came first, and the
interface was defined *against* it — the contract document lived in its package doc until
STORE-T-0013 moved it to `store/interface.odin`, and the conformance suite was written
before kvstore existed.

memstore was an architectural proposal, not a consumer request. No application and no
developer asked for an ephemeral RDF store; in the time since, its consumers have been
test suites and three artifacts of it being *free* rather than of it being wanted (see
below).

**What forced the question.** STORE-A-0005 designed the transaction and snapshot model
that STORE-T-0019 and STORE-T-0022 both asked for, and the design came out dominated by
memstore. LMDB is MVCC: kvstore gets snapshot isolation, atomicity, and read-your-own-writes
free. memstore has no versioning, so one contract covering both required a declared
`SNAPSHOT_ISOLATION` capability, a capability-conditional tier in the conformance suite, a
write journal to make abort meaningful, a generation counter with a `.Stale_Txn` error, and
a designed-but-deferred copy-on-write upgrade path for isolation memstore could not offer.
More than half the ADR was accommodation for a backend with no consumer, and the conformance
suite — the thing STORE-A-0002 made the enforcement mechanism — would have stopped being a
single uniform body of assertions permanently. That ADR is archived undecided (2026-08-07).

**The three non-test dependants, and what they actually are.** Scoping STORE-I-0003 found
that "only the test suite uses it" was not quite true. All three are in odin-rdf-shacl, and
all three are consequences of memstore being cheap rather than requests for an in-memory
store:

- `shacl_memstore.compile_turtle` — "the convenience path most callers want", a shapes file
  parsed into a private memstore and compiled. Its own doc gives its reason for living in an
  instantiation package: it "keeps LMDB out of the link of every consumer that only wants an
  in-memory store". That reason is circular once memstore is the thing in question.
- The `purity` target — `make check` builds a core-plus-memstore binary and asserts no
  `mdb_` symbols. Its guarded property is that an in-memory-only consumer does not link
  LMDB; with no in-memory backend the property has no beneficiary.
- The benchmarks — `shacl/bench/consumers.odin` measures on memstore *deliberately*, because
  memstore's `lookup_term` borrows from dictionary storage and allocates nothing while
  kvstore's copies into the caller's allocator. `store/bench/lmdb.odin` reports match-scan
  throughput "compared against the in-memory backend". These are the only real losses, and
  what they lose is a *measurement*, not a capability.

**The performance argument does not hold**, measured rather than assumed: `shacl/memstore`
runs 71 tests in 10.3 ms, `shacl/kvstore` 14 tests in 124.5 ms — 61× per test around a small
absolute number. Porting shacl's 71 tests costs roughly 0.6 s.

**Footprint**: 1,659 lines of code across three repos, and 6,556 lines of tests. Deleting
the implementations is cheap; porting the tests is the work.

## Decision **[REQUIRED]**

**odin-rdf-store is a single-backend library over LMDB.** `store/memstore` is removed
(STORE-I-0003).

1. **`store/kvstore` is the implementation of the match interface**; `store/` remains the
   shared vocabulary (Term_ID encoding, `Encoded_Quad`, `Match_Pattern`, the contract
   document, `Load_Error`) rather than being folded into it. The layout STORE-T-0013
   established is unchanged.

2. **The match interface's contract is LMDB's semantics, by definition.** There is no
   second implementation to disagree with it. Consequences that were a backend's price
   become the interface's, and must be documented as such rather than as kvstore trivia:
   - an open read transaction pins pages, so a long reader makes a concurrent writer grow
     the file;
   - an open write transaction holds the environment writer lock, serializing every other
     writer for its lifetime;
   - **there is no ephemeral dataset.** LMDB has no anonymous or in-memory mode; every
     store is a filesystem path. A consumer wanting a dataset that does not outlive the
     process manages a temporary one.
   - the persisted format is width-specific (STORE-A-0001 point 6), so the `Term_ID` width
     is a deployment choice, not only a build choice.

3. **The conformance suite stops being a portability proof and becomes a regression
   suite.** This is the honest reading and it should not be softened: the vision's own
   framing was that one suite passing verbatim against both backends is "what makes
   'multiple backends of one interface' a demonstration rather than a claim". With one
   backend it demonstrates that kvstore still does what it did yesterday — valuable, and
   less than it was.

4. **The suite and its `Backend` adapter are retained in full**, precisely so a second
   backend can be added without archaeology. The adapter is the seam; keeping it is what
   makes point 3 a pause rather than a door closing.

5. **A second backend remains welcome.** STORE-A-0002's procedure-set convention is
   unchanged and is what makes that cheap: a new backend is a package implementing the
   documented procedure set, and the suite is waiting for it. What this decision retires is
   the claim that we have *demonstrated* portability, not the design that permits it.

6. **This is not a statement that in-memory storage is worthless** — only that nothing has
   asked for it here. The evidence bar for adding it back is the same bar the vision sets
   for every other capability: a consumer that wants it, saying so.

## Alternatives Analysis **[CONDITIONAL: Complex Decision]**

| Option | Pros | Cons | Risk Level | Implementation Cost |
|--------|------|------|------------|-------------------|
| One backend over LMDB (chosen) | Removes the transaction model's dominant complexity before it is built; applies the vision's evidence principle symmetrically; one contract with nothing conditional in it | Loses the cross-implementation check on the interface; loses in-memory throughput figures entirely; every consumer links LMDB and every dataset is a filesystem path | Medium | M (the ports, not the deletion) |
| Keep memstore, build the capability device (STORE-A-0005 as drafted) | Honest, already designed, keeps the portability demonstration | Spends the next significant piece of interface complexity on a backend no consumer asked for, and makes the conformance suite conditional permanently | Medium | L |
| Keep memstore, frozen, without transaction support | No journal, no capability constant | A backend that cannot implement the interface is not a backend of it; the suite grows an "implements transactions" tier anyway — the same machinery under another name, plus a permanently second-class package | Medium | M |
| Replace memstore with a flat scratch container inside odin-rdf-shacl | Small (~150 lines), serves the shapes-compile path, no conformance obligation | memstore under another name; a third instantiation to keep parallel; its one real benefit (no LMDB in the link) is already gone once kvstore is the only backend | Medium | S |
| Defer until after the transaction work | Transactions land sooner | Guarantees building the capability device, the journal, and the generation counter and then deleting them — the worst available order | High | L |

## Rationale **[REQUIRED]**

- **The vision's first principle, applied in both directions.** "The interface grows only
  on evidence from real consumers" has an obvious corollary that has never been exercised:
  absence of evidence is grounds for shrinking. memstore is the cleanest available test of
  whether that principle is real or decorative.
- **The forcing function is a decision not yet made, which is the cheapest possible moment.**
  Both STORE-T-0019 and STORE-T-0022 independently identified memstore as their hard
  question, and both warned in the same words against letting the weaker backend's cost
  shape the contract. Removing it answers that warning at the root instead of negotiating
  around it — and does so before the machinery exists, rather than after.
- **What is lost is evidence, not capability.** Nothing a consumer can do today stops
  working. What stops is the mechanism that would catch the interface drifting into
  LMDB-shaped assumptions. That is a real loss and the correct response is to say so
  plainly, not to claim the suite still proves what it proved yesterday. Point 4 keeps the
  seam open; point 5 keeps the design that permits a second implementation.
- **The three dependants are artifacts of cheapness, not requests.** Each exists because an
  in-memory store was free, and each has an answer that is arguably better than what it
  replaces: `compile_turtle` taking the caller's store stops a validation library from
  silently owning a database; the benchmark figures start including term materialization,
  which every real consumer pays.
- **The alternative was permanent.** A capability-conditional conformance suite is not a
  transitional state — it is the shape the suite would keep for as long as two backends with
  different affordances existed, and every future capability (ordering, cardinality
  estimates) would face the same fork.

## What this changes in prior decisions **[REQUIRED]**

- **STORE-A-0002 (match interface shape) — amended, not superseded.** The convention —
  procedure sets enforced by a shared conformance suite, no vtable — is unchanged and
  correct; points 1, 2, 4, 5, and 6 stand as written. What fails is **point 3's premise**,
  not its mechanism: the suite is still the enforcement mechanism and passing it is still
  the definition of implementing the interface, but "a new backend runs the identical suite"
  is now a provision for a hypothetical backend rather than a description of what happens
  on every run. The amendment is applied with this ADR.
- **The archived STORE-A-0005's proposed amendment to STORE-A-0002 is void.** It qualified
  point 3 for a suite that branches on declared capabilities; with one backend there are no
  branches. Two edits to that ADR were outstanding and they were mutually exclusive — only
  this one is applied.
- **STORE-A-0001 point 7** ("the in-memory backend compares encoded quads positionally by
  numeric ID, so both backends produce identical iteration order if ordered iteration ever
  enters the planner contract") becomes historical. kvstore's numeric-ID order stands on its
  own — it falls out of big-endian keys under memcmp, per point 6 — so STORE-T-0015's
  groundwork is unaffected. Annotated, not rewritten.
- **STORE-I-0001** defined the interface against memstore as the reference implementation.
  That is recorded as history: the interface it produced survives its reference, which is
  the outcome that arrangement was for. Its benchmark baselines are annotated as measured
  against a removed backend (STORE-T-0029), not deleted — they are the record of why the
  pending-buffer/lazy-merge design was adopted.
- **STORE-V-0001** — "multiple backends of one interface" retracted from the
  Product/Solution Overview, Major Features, Success Criteria, and Current State, with dates
  rather than by rewriting.

**Family-wide, and not this repo's to fix.** Both sibling visions carry a *success
criterion* that this decision falsifies, and each repo retracts its own:

- odin-rdf-shacl (`vision.md`): "the same shapes validate **in-memory and LMDB-backed** data
  identically", plus the package list naming `shacl/memstore` and the purity target.
- odin-rdf-sparql (`vision.md`): "in-memory and LMDB behave identically apart from
  performance".

STORE-T-0026 and STORE-T-0027 carry these into the sibling proposals. A code port that
leaves a falsified success criterion standing in a published vision is an incomplete port.

## Consequences **[REQUIRED]**

### Positive
- The transaction model (STORE-T-0032) is written once, unconditionally, with nothing in the
  contract that exists to reconcile two backends.
- One contract, one implementation, one set of semantics to document and reason about.
- ~1,659 lines of implementation removed across three repos, and three engines' worth of
  parallel instantiation maintenance halved.
- The family's evidence principle is demonstrated to run in both directions, which makes it
  credible the next time it is invoked to *refuse* something.

### Negative
- **The interface loses its cross-implementation check.** Drift into LMDB-shaped assumptions
  becomes possible and nothing will catch it. Mitigated only by the convention and the
  retained adapter, which are provisions, not detectors.
- **Every consumer links LMDB**, including one that only wants to parse a shapes file. The
  `purity` property that odin-rdf-shacl protected with a build target is gone.
- **No ephemeral dataset exists.** Any consumer wanting a store that does not outlive the
  process manages a temporary filesystem path, including on platforms where that is awkward.
- **In-memory throughput figures leave the record entirely.** "How fast is this without a
  database" will have no answer.
- **Platforms LMDB cannot reach are now platforms this library cannot reach.** wasm is the
  concrete example; it was never supported, but memstore was the only thing that could have
  made it possible.

### Neutral
- The `conformance` package survives with a harness, a comparison helper, and one
  instantiation — a shape that will look odd until a second backend arrives or does not.
- The `Term_ID` dual-width discipline is unaffected; kvstore is the width-sensitive backend
  and always was.
- STORE-A-0002's vtable question (point 4) is untouched: runtime backend polymorphism is
  still added only when a consumer needs it, and there is now even less reason to.

## Review Schedule **[CONDITIONAL: Temporary Decision]**

### Review Triggers
- **A consumer asks for an ephemeral or embedded-without-a-file dataset** — the evidence this
  decision says was never presented. Triggers reconsidering an in-memory backend on its
  merits, with the conformance adapter waiting for it.
- **A target platform LMDB cannot reach becomes desirable** (wasm being the concrete case).
- **A second persistent backend is proposed** — triggers reviewing whether point 3's
  regression-suite framing reverts to a portability proof.
- **The interface is found to have drifted into an LMDB-shaped assumption** that a second
  implementation would have caught. Worth recording if it happens: it is the direct cost of
  this decision, and the only honest way to price it is in hindsight.
