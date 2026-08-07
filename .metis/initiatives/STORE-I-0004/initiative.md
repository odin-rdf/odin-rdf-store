---
id: transactions-and-snapshots-publish
level: initiative
title: "Transactions and snapshots: publish the handle"
short_code: "STORE-I-0004"
created_at: 2026-08-07T22:12:31.838098+00:00
updated_at: 2026-08-07T22:29:18.597489+00:00
parent: STORE-V-0001
blocked_by: []
archived: false

tags:
  - "#initiative"
  - "#phase/active"


exit_criteria_met: false
estimated_complexity: M
initiative_id: transactions-and-snapshots-publish
---

# Transactions and snapshots: publish the handle Initiative

## Context **[REQUIRED]**

**This initiative has its hard question already answered.** Two backlog items arrived from
two different consumers describing two halves of one missing concept, were designed jointly,
and both recommended in writing that they be *promoted to an initiative rather than worked as
standalone items*. STORE-A-0007 took the design decision on 2026-08-07. What is left is
publication, a contract, and a suite — not a design.

The two items are this initiative's inputs, not its tasks. They are written at initiative
scale and are cited here rather than restated:

- **STORE-T-0019 — snapshot reads.** From odin-rdf-sparql's evaluation initiative. A query
  reads the store in five distinct places — term binding, matching, materialization,
  triple-term decomposition, dataset introspection — and today each is an independent read.
  Nothing makes a query's answer an answer *about one dataset*; under a concurrent writer it
  is a smear assembled from two. P2 today because the suites are single-threaded, P0 the day
  anything writes concurrently, which the vision's deployment shape makes a question of when.
- **STORE-T-0022 — write transactions.** From `odin-rdf-app`, the family's first
  application-shaped consumer, working a create-resource request end to end. **P0, and the
  one item on the backlog that is a correctness gap rather than an ergonomics gap.**
  **Validate-before-commit is inexpressible.** `match` opens its own read transaction, so a
  validator deciding whether a write may join the dataset cannot observe the write it is
  deciding about. The three orderings the current primitives admit are each wrong in a
  different way: validate-then-commit leaves a window that cannot be closed in application
  code across ~200 processes per machine; commit-then-validate is irreversible while there is
  no `remove`; and validating an isolated candidate graph passes vacuously every constraint
  that must read existing data — a validator that cannot fail is worse than one that is
  absent.

**The design is decided, and it is worth reading STORE-A-0007 first — it is written to stand
alone.** Its shape, in one paragraph: one opaque `Txn` handle with a `.Read`/`.Write` mode,
of which **a read transaction *is* the snapshot** — no separate `Snapshot` type, no snapshot
vocabulary anywhere in the interface, because LMDB's read transaction is literally the thing
STORE-T-0019 asks for and exposing it twice would invent a distinction the storage does not
have. `Txn` carries its dataset, so every transactional procedure takes `^Txn` alone. Every
operation gains a `_txn` form; every existing bare form survives unchanged in name, signature
and semantics, and is **defined as autocommit** — which is already literally how kvstore
implements them. The guarantees are stated flat with nothing conditional:
read-your-own-writes, snapshot isolation, atomicity over quads (not over the dictionary),
provisional `Term_ID`s discarded on abort, single writer with no nesting, and iterator
invalidation on a write through the same transaction.

**Most of the machinery exists and is unpublished.** `insert_txn`, `intern_term_txn`,
`find_term_txn`, `lookup_term_txn`, `encode_quad_txn` and the `load_begin` / `scope_*` family
are all `@(private)`, and every public loader already runs exactly one LMDB write transaction
across a whole document, aborting it on a parse error. The capability is built and tested;
what is missing is a contract for it and a way to say it. **The one read path with no `_txn`
sibling is `match`, because its iterator owns the read transaction it opened** — that is the
piece with actual design left in it.

**Why this is an M and not an L.** STORE-I-0003 is why. The predecessor to STORE-A-0007 was
STORE-A-0005, archived undecided, and more than half of it was a capability device that
existed only to let two backends differ honestly: a declared `SNAPSHOT_ISOLATION` constant, a
capability-conditional tier in the conformance suite, a write journal, a generation counter, a
`.Stale_Txn` error, and a costed upgrade path to copy-on-write. With one backend all of that
is gone — not simplified, deleted — and the contract states a guarantee where it used to
declare a capability. Retiring memstore first was the sequencing that made this initiative
small, and that is the concrete payoff STORE-I-0003 was claiming.

**What the vision says about this.** STORE-I-0001 recorded "concurrency guarantees beyond
single-threaded use" as a non-goal. This narrows it rather than reverses it: the guarantee
published here is the one LMDB already provides across processes, which is exactly the shape
the deployment has — ~200 processes per machine, each embedding a store. Multi-writer
coordination remains a non-goal.

## Goals & Non-Goals **[REQUIRED]**

**Goals:**

- **Publish the `Txn` handle** with the two modes, its lifecycle, and the single-writer
  refusal — an opaque type named by the convention, never `^lmdb.Txn`.
- **Close the P0 gap: make validate-before-commit expressible.** Build a candidate inside a
  write transaction, run a validator or a query through *that same transaction*, commit or
  abort on the answer.
- **Make a query an answer about one dataset**: a read transaction taken once and held for a
  consumer-chosen lifetime, with every read of that consumer going through it.
- **State the contract in `store/interface.odin`** — the guarantees flat, provisional IDs,
  iterator invalidation, and the two costs (page pinning, writer-lock serialization) as
  *interface* rather than as backend notes.
- **Break nothing.** Every bare procedure keeps its name, signature and semantics, and gains
  a definition it did not have: a one-operation transaction.
- **Grow the conformance suite as one uniform body** — transactional assertions with no
  capability field, no tier, no skip, at both `Term_ID` widths.

**Non-Goals:**

- **`remove` (STORE-T-0023) and `insert_all` (STORE-T-0024).** STORE-A-0007's scope guard puts
  both explicitly out of scope, and both get *simpler* once this handle exists — `insert_all`
  is nearly a loop inside a transaction, and "replace this resource's description" becomes a
  remove and an insert in one transaction. They stay in the backlog.
- **Multi-writer conflict detection, retry, or isolation levels beyond LMDB's single-writer
  model.** This is about **one writer's** atomicity and visibility. The scope guard is
  inherited verbatim from STORE-T-0022 and is the risk that item named specifically.
- **Nested transactions.** Forbidden by STORE-A-0007, not deferred with a shape.
- **`mdb_txn_reset` / `mdb_txn_renew`.** LMDB supports cheap snapshot renewal and
  STORE-A-0007 deliberately does not expose it; it is a review trigger there, not work here.
- **The planner-support backlog** — STORE-T-0015 (ordered iteration), T-0016 (introspection),
  T-0017 (named-graph wildcard), T-0018 (cardinality), T-0020 (`triple_parts`), T-0021
  (sentinel reservation). They were filed as evidence from odin-rdf-sparql's evaluation
  engine, which is complete and passes 483 tests without them, and their real consumer is a
  query planner that does not exist. Building them now would repeat the mistake STORE-I-0003
  just undid. *(T-0016 is the one this initiative touches at all, and only in the sense that
  whatever it eventually adds gains a `_txn` form like everything else.)*
- **Changing odin-rdf-sparql or odin-rdf-shacl.** Their read sites and `Access` adapters would
  bind to a transaction rather than to a bare store; STORE-A-0007 says those are changes in
  *those* repos, "to be raised there as proposals once this handle exists — not made here."
  One task files the proposals; neither implementation is an exit criterion.
- **Term identity (SPARQL-T-0021: language-tag case, IRI normalization).** Filed in
  odin-rdf-sparql, but it is a **store dictionary decision** and has to be settled upstream or
  the same document loaded twice yields different terms. It is recorded here so it is not lost
  and is explicitly not taken here: it is orthogonal to transactions and would drag the
  dictionary's canonical form into an initiative about visibility.

## Architecture **[CONDITIONAL: Technically Complex Initiative]**

### Overview

Two seams, and only one of them has design left in it.

```
  store/interface.odin        the contract: guarantees, provisional IDs,
        │                     iterator invalidation, the two costs
        │
  store/kvstore               Txn { ^Store, ^lmdb.Txn, mode, saved next }
        │                     txn_begin / txn_commit / txn_abort
        │                     ├─ *_txn forms          ← publication: the private
        │                     │                          (s, txn, …) internals re-signed
        │                     ├─ match_txn            ← the only real design: the
        │                     │                          iterator borrows, it does not own
        │                     └─ bare forms           ← unchanged, now *defined* as
        │                                                one-operation transactions
        │
  conformance                 Backend grows transactional procedure pointers.
                              No capability field. No tier. No skip.
```

`Txn` is a **caller-held value**, exactly as `Match_Iterator` is today — `txn_begin` returns
one, and every transactional procedure takes `^Txn`. It carries `^Store`, so the existing
private `(s, txn, …)` internals stay internal and consumers thread one thing.

Dependency direction inside the initiative: the handle exists before anything can take it, and
the contract wants to be written before the suite that asserts it, so the suite tests the
contract rather than the implementation. Everything else is parallel.

## Detailed Design **[REQUIRED]**

Recommendations for the design phase, not settled decisions. STORE-A-0007 settles the model;
these are the things decomposition surfaced that it does not cover.

1. **The `Txn` value and the copy hazard.** `Txn` holds `^Store`, `^lmdb.Txn`, the mode, and
   the `next` snapshot. Copying it yields two handles to one transaction, of which the second
   commit or abort is a use-after-free — the same hazard `Match_Iterator` already carries and
   documents. Recommend saying so in the doc comment in the same words the iterator uses,
   rather than inventing a guard.

2. **`Store.next` restore-on-abort.** STORE-A-0007 point 4 requires it: the in-memory mirror of
   the per-kind ID counters is advanced by interning but is not rolled back on abort, while the
   persisted counters in `meta` *are*, because they are written inside the same LMDB
   transaction. Today this is reachable only through a loader aborting on a parse error and is
   benign — the reverse lookup is a key lookup, not an array index, so the effect is a gap in
   the ID space. With aborts published it becomes ordinary. `Txn` snapshots `next` at begin and
   restores it on abort.

3. **Refusing a second write transaction.** This is the one place the ADR chooses a behaviour
   LMDB does not hand over: within one handle a second `txn_begin(.Write)` can only be a
   mistake, and LMDB's writer lock would self-deadlock a single-threaded consumer. `Store`
   needs a flag; the error variant is new. Recommend a distinct `Store_Error` rather than
   overloading a `Db_Error`, so a consumer can tell a programming error from an environment
   failure. **Across processes nothing changes** — LMDB's lock serializes writers and blocking
   is correct there.

4. **`match_txn` and the borrowing iterator.** `Match_Iterator` owns the read transaction it
   opened and `match_destroy` closes it. `match_txn` must borrow: `match_destroy` closes the
   cursor and leaves the transaction alone. Recommend one iterator type with an `owns_txn`
   flag rather than two types — the alternative puts a second iterator type into every
   consumer's source for a one-bit difference. The invalidation rule that goes with it is
   STORE-A-0007 point 3's: valid until `match_destroy`, a **write through that same
   transaction**, or that transaction's commit/abort, whichever is first.

5. **The loaders — the one scoping question this decomposition raises, and it wants sign-off.**
   STORE-A-0007 §2 says "every operation gains a `_txn` form" and §6 lists what the decision
   does *not* settle; the loaders appear in neither list. They matter to the driving consumer:
   `odin-rdf-app`'s candidate arrives as a serialized document, so without `load_turtle_txn`
   and friends the validate-before-commit path has to parse the document itself and insert
   quad by quad, re-implementing `load_*` at the call site to get the transaction it needs.
   The machinery is already there — `load_begin` returns a transaction and a scope, and the
   public loaders are thin wrappers over it. **Recommend including them**, as their own task so
   the decision can be reversed cleanly. Note the blank-node scoping stays per *load*, not per
   transaction: two loads in one transaction must still mint distinct blanks for `_:b0`, which
   is what the `Load_Scope` already does and what must not quietly change.

6. **Autocommit, stated as a definition rather than left as an implementation.** The bare forms
   are reimplemented in terms of the `_txn` forms so there is exactly one implementation of
   each operation, and their doc comments say "opens a transaction of the appropriate mode,
   does the one operation, closes it." Recommend checking that this does not cost anything
   measurable on the load benchmark — a per-operation transaction is what happens today, but
   the indirection is new.

7. **The two costs belong in `store/interface.odin`, not in a kvstore note.** STORE-A-0006 made
   the match interface's semantics LMDB's semantics by definition; these are the first place
   that bites. An open read transaction pins pages, so a long snapshot makes a concurrent
   writer grow the file. An open write transaction holds the environment's writer lock, and
   **the validate-before-commit consumer holds one across an entire SHACL validation by
   construction** — read-your-own-writes is the whole point — so those transactions are long
   by design. A consumer that discovers page pinning from a growing file is discovering it in
   production.

8. **The `_txn` suffix is admitted to be backwards, and stays.** It marks what becomes the
   primary API, because the alternative renames every procedure odin-rdf-sparql and
   odin-rdf-shacl already call, which both input items explicitly forbid. Additive and ugly
   beats elegant and breaking. Recommend the doc comments say this once, plainly, rather than
   leaving a reader to wonder.

9. **When to archive the inputs — done, and the timing was the point.** STORE-T-0019 and
   STORE-T-0022 are archived as **superseded by this initiative, after decomposition rather
   than at promotion**: their acceptance criteria are the raw material for the Exit Criteria
   below, and archiving first would have buried them mid-transcription. Each carries a final
   status update saying where every one of its criteria went, including the two that **died
   rather than moved** — both were memstore's, and STORE-I-0003 deleted the question rather
   than answering it. Their evidence is not restated in this document; it is cited, and it is
   still readable in the archive.

## Testing Strategy **[CONDITIONAL: Separate Testing Initiative]**

The conformance suite is the deliverable that makes this a contract rather than a feature, so
its shape is the initiative's main correctness question.

- **One uniform body, no branch.** The `conformance.Backend` adapter grows the transactional
  procedure pointers and nothing else: no capability field, no tier selection, no skips. A
  backend either passes these assertions or does not implement the interface. This is what
  STORE-A-0002 point 3 always claimed the suite was, and what it stops being the moment a
  contract carries a capability the suite has to branch on.
- **The concrete checks**, from STORE-A-0007 point 5: read-your-own-writes inside a write
  transaction; invisibility of those writes to a reader outside it; a read transaction
  unchanged across a concurrent commit; abort leaving no quad behind; a second write
  transaction refused; an iterator invalidated by a write through its own transaction; and
  autocommit behaving as the one-operation transaction it is now defined to be.
- **Both `Term_ID` widths**, as always.
- **A test that is not a conformance assertion**: `Store.next` restored on abort. It is an
  invariant repair with no observable effect through the quad contract, so it belongs in
  kvstore's own tests rather than in the shared suite — and it is exactly the sort of thing
  that is only ever caught by the test written when the invariant was introduced.
- **The negative that is easy to forget**: a term interned inside an aborted transaction may or
  may not remain interned, **by design**. No conformance assertion covers it, and the suite
  must not accidentally grow one — atomicity is defined over quads, not over the dictionary.
- **CI on three platforms.** Nothing here is filesystem-shaped the way STORE-I-0003's ports
  were, but the writer-lock behaviour and `NOTLS` interact with the platform, and Windows is
  the least-exercised.

## Alternatives Considered **[REQUIRED]**

The model's alternatives were weighed and rejected in STORE-A-0007's own table — two concepts
(`Snapshot` plus `Txn`), an ambient transaction on the `Store` handle, and shipping the two
items separately. They are not re-argued here. What this document chose is *how to sequence
the publication*:

- **One task for the whole `_txn` surface**, handle and procedures and `match` together.
  Rejected: `match_txn` is the only piece with design in it, and burying it inside a bulk
  re-signing task is how the borrowing question gets answered by whatever compiles.
- **Write the conformance assertions first, against a contract that does not exist yet.**
  Tempting — the assertions are all in STORE-A-0007 point 5 already. Rejected: the suite needs
  the `Backend` adapter to grow first, and an adapter shaped before the handle is shaped is an
  adapter shaped twice.
- **Ship without the loaders' `_txn` forms** and let the driving consumer parse and insert
  itself. Rejected as the default, but recorded as the reversible option: it is Detailed Design
  point 5's own task precisely so it can be dropped without disturbing anything else.
- **Take `remove` (STORE-T-0023) in the same initiative**, since it composes with transactions
  and gets simpler because of them. Rejected: that is the argument for doing it *next*, not for
  doing it *here*. It changes the append-only stance STORE-I-0001 decision 5 recorded, which is
  a decision of its own and not a rider on this one.
- **Defer the sibling proposals** until a consumer complains. Rejected: the evidence for both
  is already written down, and the `Access`-adapter argument is what makes the P0 gap actually
  close for `odin-rdf-app`. Filing them costs one task.

## Implementation Plan **[REQUIRED]**

Direction; task decomposition happens at the decompose phase with sign-off.

1. **The `Txn` handle** — the opaque type, the two modes, `txn_begin` / `txn_commit` /
   `txn_abort`, the single-writer refusal, and `Store.next` restore-on-abort. Nothing can take
   a transaction until this exists.
2. **The contract in `store/interface.odin`** — written once the handle's shape is real and
   before the suite asserts it.
3. **The `_txn` procedure set**, with the bare forms reimplemented as autocommit over it.
4. **`match_txn`** — the borrowing iterator, in its own task.
5. **The loaders' `_txn` forms** — pending Detailed Design point 5's sign-off.
6. **The conformance suite's transaction assertions**, after 3 and 4.
7. **Documentation, CHANGELOG, the vision's Current State, and the release decision.**
   (Archiving STORE-T-0019 and STORE-T-0022 is *not* here — it happened at decomposition, per
   Detailed Design point 9.)
8. **Proposals to odin-rdf-shacl and odin-rdf-sparql** — filed in those repos, implemented
   there, not an exit criterion here.

Steps 3 and 4 are parallel after 1; 2 is parallel with both.

## Exit Criteria **[REQUIRED]**

Absorbed from STORE-T-0019's and STORE-T-0022's acceptance criteria, with the two memstore
criteria dropped as dead and STORE-A-0007's own additions folded in.

- [ ] **A transaction handle in the backend convention**: begin one from a dataset, insert
      through it, read through it (`match`, `count`, `find_term`, `lookup_term`, `intern_term`,
      the graph-label trio, the quad codec — and whatever STORE-T-0016 eventually adds), then
      commit or abort. Opaque, named by the convention, never `^lmdb.Txn`.
- [ ] **A read transaction is the snapshot**, with no separate snapshot type and no snapshot
      vocabulary anywhere in the interface. Reads through one transaction see one dataset.
- [ ] **Read-your-own-writes**: a read issued through an open write transaction observes that
      transaction's own uncommitted writes.
- [ ] **Atomicity over quads**: after commit every quad the transaction wrote is visible; after
      abort none is; no intermediate state is observable from outside. Atomicity over the
      *dictionary* is explicitly not claimed, and no assertion covers it.
- [ ] **Snapshot isolation**: a read transaction is unchanged across a concurrent commit, and a
      reader outside an open write transaction sees the pre-commit dataset.
- [ ] **Provisional `Term_ID`s**: IDs assigned by interning inside a transaction are valid only
      if it commits, documented as the consumer's to discard on abort.
- [ ] **Single writer, no nesting**: a second write transaction on one handle is **refused with
      an error rather than left to deadlock**, and transactions do not nest.
- [ ] **The iterator interaction is specified rather than left to fall out** — an iterator is
      valid until `match_destroy`, a write through its own transaction, or that transaction's
      commit/abort, whichever is first. `match_txn`'s iterator borrows; bare `match`'s still
      owns.
- [ ] **`Store.next` is snapshotted at begin and restored on abort**, so the in-memory counter
      mirror cannot drift from the persisted one, with a test.
- [ ] **`store/interface.odin` states the read and write models**, including what a consumer
      that never opens a transaction may assume — and today's per-operation `match`, `insert`
      and lookups **remain valid, unchanged in name, signature and semantics**, now *defined*
      as one-operation transactions rather than merely implemented that way.
- [ ] **The two costs are stated as contract**: an open read transaction pins pages and makes a
      concurrent writer grow the file; an open write transaction holds the environment's writer
      lock, and the validate-before-commit pattern holds one across an entire validation by
      construction.
- [ ] **Conformance suite, one uniform body, both `Term_ID` widths**: the seven checks of
      STORE-A-0007 point 5, with the `Backend` adapter grown by transactional procedure
      pointers and by nothing else — no capability field, no tier, no skip.
- [ ] **Validate-before-commit is demonstrably expressible** — a test that builds a candidate
      inside a write transaction, reads the dataset it would produce through that same
      transaction, and commits or aborts on the answer. This is the P0 gap; it closes with a
      demonstration or it does not close.
- [x] **STORE-T-0019 and STORE-T-0022 are archived as superseded by this initiative**, after
      decomposition rather than before, with the supersession recorded in each — including
      where every acceptance criterion went and which two died with memstore rather than
      moving. *(Met 2026-08-07, at decomposition.)*
- [ ] CI green on Linux, macOS and Windows at both widths, and a release decision taken.

## Status Updates

- **2026-08-07 — Created, promoting STORE-T-0019 and STORE-T-0022 as both items recommended in
  writing.** They are cited as inputs and their acceptance criteria are absorbed into the Exit
  Criteria above; they are archived as superseded *after* decomposition, not before.

  The initiative starts with its hard question answered — STORE-A-0007 decided one `Txn` with
  `.Read`/`.Write`, a read transaction as the snapshot, the `_txn` procedure set with the bare
  procedures defined as autocommit, and the guarantees stated flat with nothing conditional.
  The driver is `odin-rdf-app`: validate-before-commit is currently inexpressible, which is the
  only P0 on the backlog.

  **Scoping surfaced one question STORE-A-0007 does not answer either way: the loaders.** §2
  says every operation gains a `_txn` form and §6 lists what the decision leaves open; `load_*`
  is in neither list. It matters, because the driving consumer's candidate arrives as a
  serialized document — without `load_turtle_txn` the validate-before-commit path has to
  re-implement the loader at the call site to get the transaction it needs. Recommended for
  inclusion, as its own task so it can be dropped cleanly. Detailed Design point 5.

  Also recorded here so it is not lost: **SPARQL-T-0021 (term identity — language-tag case, IRI
  normalization) is filed in odin-rdf-sparql but is a store dictionary decision**, and has to
  be decided upstream or the same document loaded twice yields different terms. Explicitly not
  taken here — it is orthogonal to visibility and would drag the dictionary's canonical form
  into this.

  Awaiting review before the design phase.

- **2026-08-07 — Decomposed into 8 tasks.** Dependencies are recorded in each task's
  `blocked_by` frontmatter:

  ```
  T-0034  the Txn handle                        ← blocks everything
     ├─ T-0035  the contract in interface.odin  ┐
     ├─ T-0036  the _txn procedure set          ├ parallel
     └─ T-0037  match_txn (borrowing iterator)  ┘
            ├─ T-0038  the loaders' _txn forms      (from T-0036; pending sign-off)
            ├─ T-0039  conformance assertions       (from T-0035, T-0036, T-0037)
            │     └─ T-0040  docs, vision, release decision
            └─ T-0041  sibling proposals            (from T-0037)
  ```

  **Three decisions taken while scoping the tasks.**

  **1. `match_txn` gets its own task rather than riding along with the `_txn` set.** It is the
  only read path with design left in it — its iterator owns the transaction it opened, and
  borrowing instead is the change. Bundled into a bulk re-signing task, that question gets
  answered by whatever compiles.

  **2. The contract (T-0035) is sequenced *before* the conformance suite (T-0039), not beside
  it.** The suite should assert what `interface.odin` says, not describe what kvstore does. It
  is blocked on the handle (T-0034) rather than written first, because a contract describing a
  shape that does not exist yet is a contract written twice.

  **3. The loaders (T-0038) are a separate, droppable task.** See Detailed Design point 5.
  Scoping them surfaced something the Context did not have: a `load_*_txn` **cannot be atomic
  per document**, because the transaction is the caller's — a parse error leaves statements
  already written and it is the caller's job to abort. That is the exact opposite of the bare
  loaders' documented divergence, so it is the thing a reader will get wrong, and it is the
  strongest argument for the task existing at all rather than the loaders being quietly folded
  into T-0036.

  Two things worth flagging out of the task bodies, because they are where the initiative's
  claim actually rests:

  - **T-0039 carries the criterion the P0 stands or falls on** — validate-before-commit
    demonstrated as a *test*, including a constraint that must read **pre-existing** data,
    which is precisely what the isolated-candidate workaround gets wrong by passing vacuously.
    The store cannot run SHACL, so the validator there is a match-based predicate; what is
    being demonstrated is that the reads see the right dataset, which is the whole of the gap.
  - **T-0041 is what actually closes the gap for the driving consumer, and it is not an exit
    criterion.** The handle makes validate-before-commit *possible*; it does not make it
    *reachable*, because odin-rdf-shacl's `Access` adapters still bind to a bare store. That
    work is odin-rdf-shacl's to sequence, so this initiative files the proposal and stops
    there — STORE-A-0007's "not made here" — but the initiative should not be read as having
    delivered validate-before-commit end to end.

  Awaiting review before activation.