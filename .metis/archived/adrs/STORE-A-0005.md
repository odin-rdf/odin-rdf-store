---
id: 001-transactions-and-snapshots-one
level: adr
title: "Transactions and snapshots: one handle, two modes, a declared isolation capability"
number: 1
short_code: "STORE-A-0005"
created_at: 2026-08-07T15:27:45.103212+00:00
updated_at: 2026-08-07T15:27:45.103212+00:00
decision_date: 
decision_maker: 
parent: 
archived: true

tags:
  - "#adr"
  - "#phase/draft"


exit_criteria_met: false
initiative_id: NULL
---

# ADR-5: Transactions and snapshots: one handle, two modes, a declared isolation capability

> **2026-08-07 — ARCHIVED, never decided. To be rewritten after STORE-I-0003 (retire
> memstore) lands.**
>
> This ADR's central mechanism — a declared `SNAPSHOT_ISOLATION` capability with a
> capability-conditional conformance tier — exists solely to let two backends with
> different affordances share one contract. STORE-I-0003 retires memstore, which removes
> the reason for that machinery entirely rather than simplifying it. More than half this
> text is about a backend that will not exist, so it is archived rather than amended.
>
> **Read it for these, which survive the removal unchanged and should carry into the
> rewrite** (the transaction model itself was never the contested part):
>
> - **Point 1** — one `Txn` handle with a `.Read`/`.Write` mode, of which a read-only
>   transaction *is* the snapshot. This settles STORE-T-0022's "one handle or two
>   concepts, with the reason" criterion, and the reason is unaffected by memstore.
> - **Point 2** — the `_txn` procedure set, the handle carrying its own dataset, and
>   autocommit defined as a one-operation transaction so no existing consumer breaks.
>   Includes why the suffix lands on the primary API rather than the convenience one.
> - **Point 3's universal core** — read-your-own-writes, atomicity over quads (not over
>   the dictionary), provisional Term_IDs discarded on abort, single writer, no nesting,
>   and iterator invalidation on write. In a single-backend world this stops being a
>   "core" and simply becomes the contract.
> - **Point 4** — kvstore's publication work: the opaque `Txn` over `^lmdb.Txn`, the
>   `match_txn` iterator that borrows rather than owns its transaction, the
>   `Store.next` restore-on-abort invariant repair, and the long-reader / writer-lock
>   costs that must be documented rather than hidden.
> - **Point 7** — the scope guard: no multi-writer conflict detection, no isolation
>   levels beyond LMDB's, no `remove`, no `insert_all`, nesting forbidden.
>
> **Do not carry forward**: points 5 and 6 in full (memstore's journal, generation
> counter, `.Stale_Txn`, the retained-index upgrade path, and the conditional conformance
> tier), and point 3's `SNAPSHOT_ISOLATION` declaration.
>
> **Also dead: the STORE-A-0002 amendment proposed below.** It qualifies that ADR's
> point 3 for a conformance suite that branches on declared capabilities. With one
> backend there are no branches, so that amendment is never applied. STORE-A-0002 still
> needs changing — but by STORE-I-0003's single-backend ADR, and about its
> *demonstration* claim (one suite, two backends, verbatim), which is the larger change.

## Context **[REQUIRED]**

Two backlog items arrived from two different consumers and describe two halves of
the same missing concept:

- **STORE-T-0019 (snapshot reads)**, from odin-rdf-sparql's evaluation initiative:
  a query reads the store in five distinct places, each an independent read, so
  nothing makes a query's answer an answer *about one dataset*. Under a concurrent
  writer the result is a smear — a solution assembled from two datasets.
- **STORE-T-0022 (write transactions)**, from the first application-shaped consumer
  (`odin-rdf-app`) working a create-resource request end to end: **validate-before-commit
  is inexpressible**. `match` opens its own read transaction, so a validator deciding
  whether a write may join the dataset cannot observe the write it is deciding about.
  Validate-then-commit leaves a window that cannot be closed in application code across
  the vision's ~200 processes per machine; commit-then-validate is irreversible while
  there is no `remove`; and validating an isolated candidate graph silently passes every
  constraint that must read existing data — a validator that cannot fail.

The second item states the hypothesis this ADR exists to settle: they are *very probably
one handle*, of which a read-only transaction is exactly a snapshot. Landing them
separately would put two overlapping concepts in one interface, each shaped by whichever
consumer arrived first.

**What the code already looks like.** kvstore has most of the write half built and
unpublished: `insert_txn`, `intern_term_txn`, `find_term_txn`, `lookup_term_txn`,
`encode_quad_txn`, and the `load_begin` / `scope_*` family are all `@(private)`, and
every public loader already runs exactly one LMDB write transaction across a whole
document, aborting it on a parse error. LMDB is MVCC: a read transaction *is* a snapshot,
a write transaction gives atomicity and read-your-own-writes, and only one writer runs at
a time. The capability is built and tested; what is missing is a contract for it and a way
to say it. The one read path with no `_txn` sibling is `match`, because its iterator owns
the read transaction it opened — that is the piece with actual design in it.

**memstore is where the decision lives.** It has three sorted permutation arrays, a
membership hash set, a pending buffer flushed lazily on the next `match`, and a
monotonically growing dictionary. No versioning of any kind. An honest abort needs a
journal; an honest snapshot needs copy-on-write or a generation counter that fails
loudly. Both items record the same risk in the same words: **the two backends may not
afford the same guarantee at an acceptable cost, and the contract must not pretend they
do.** A conformance suite that asserts transaction semantics uniformly would force
memstore into an implementation it may not want — a decision to make deliberately rather
than back into.

Both items also anticipate that the two halves may not have the same answer in memstore,
since a journal is substantially easier for writes than copy-on-write is for snapshots.
That turns out to be exactly what happens, and recording it is part of this decision.

Scope guard, taken from STORE-T-0022: this is about **one writer's** atomicity and
visibility. Multi-writer conflict detection, retry, and isolation levels beyond what
LMDB's single-writer model gives are not designed here.

## Decision **[REQUIRED]**

### 1. One handle, two modes. A read-only transaction *is* a snapshot.

Each backend publishes an opaque `Txn` type — named by the convention, never
`^lmdb.Txn`, whose exposure would put LMDB's types into every consumer's source and
defeat the backend independence the interface exists for. There is no separate
`Snapshot` type and no separate snapshot vocabulary. STORE-T-0019 is settled as a
*mode*, not as a concept:

```odin
Txn_Mode :: enum { Read, Write }

txn_begin  (ds, mode: Txn_Mode, allocator := context.allocator) -> (Txn, Error)
txn_commit (t: ^Txn) -> Error   // on a Read txn: legal, equivalent to txn_abort
txn_abort  (t: ^Txn)
```

`Txn` is a caller-held value, exactly as `Match_Iterator` is today, and it **carries its
dataset**: every transactional procedure takes `^Txn` alone, not `(ds, txn)`. The
existing private `(s, txn, …)` internals in kvstore stay internal. A consumer threads one
handle, which is what odin-rdf-shacl's `Access` adapters and an odin-rdf-sparql `Query`
want to hold.

### 2. Every operation gains a `_txn` form; every existing form survives unchanged.

```odin
insert_txn     (t: ^Txn, q: Encoded_Quad)      -> (added: bool, err: Error)
count_txn      (t: ^Txn)                       -> (n: int, err: Error)
match_txn      (t: ^Txn, pattern)              -> (it: Match_Iterator, err: Error)
find_term_txn  (t: ^Txn, term)                 -> (id: Term_ID, found: bool, err: Error)
lookup_term_txn(t: ^Txn, id, allocator)        -> (term: rdf.Term, err: Error)
intern_term_txn(t: ^Txn, term)                 -> (id: Term_ID, err: Error)
```

— and the same for `encode_quad_txn` / `decode_quad_txn`, the three graph-label
procedures, and whatever STORE-T-0016 adds. The bare forms (`insert`, `count`, `match`,
`find_term`, `lookup_term`, …) remain, unchanged in name, signature, and semantics, and
are **defined as autocommit**: open a transaction of the appropriate mode, do the one
operation, close it. That is already literally how kvstore implements them. Nothing an
existing consumer wrote stops compiling or changes meaning; this adds a way to say more.

The `_txn` suffix on what will become the primary API is admitted to be backwards
naming. It is chosen because the alternative — giving the transactional forms the plain
names — renames every procedure odin-rdf-sparql and odin-rdf-shacl already call, which
both backlog items explicitly forbid. Additive and ugly beats elegant and breaking.

### 3. Guarantees split into a universal core and one declared capability.

**Universal — every backend, asserted uniformly by the conformance suite:**

- **Read-your-own-writes.** A read through an open transaction observes that
  transaction's own uncommitted writes.
- **Atomicity over quads.** After commit, every quad written by the transaction is
  visible; after abort, none is.
- **No observable intermediate state** (see the capability below for how each backend
  discharges this).
- **Provisional IDs.** `Term_ID`s assigned by interning inside a transaction are valid
  only if it commits. On abort a consumer must discard them. Whether the *term* remains
  interned after an abort is backend-specific and deliberately unspecified: atomicity is
  defined over quads, not over the dictionary. A term interned but never used by a
  committed quad is invisible through the quad contract — `find_term` may report it,
  and matching it yields nothing, which is the correct answer either way.
- **Single writer, no nesting.** At most one write transaction may be open on a dataset
  at a time, and transactions do not nest. Opening a second is a programming error, not
  a queue: kvstore would block on LMDB's writer lock (self-deadlock in one thread),
  memstore reports `.Txn_Conflict`. Forbidding it makes consumer code portable.
- **Iterator invalidation.** An iterator opened on a transaction is valid until
  `match_destroy`, a **write through that same transaction**, or that transaction's
  commit/abort — whichever comes first. Writing through a transaction invalidates every
  iterator open on it. This extends, rather than replaces, today's rule that an iterator
  is valid only until its dataset is mutated. It is the conservative reading LMDB's
  cursor-fixup behaviour permits and memstore's slice-into-a-reallocated-array requires,
  and it answers STORE-T-0022's last acceptance criterion by forbidding the combination
  explicitly rather than defining it.

**Declared — a per-backend compile-time constant:**

```odin
SNAPSHOT_ISOLATION :: true   // kvstore
SNAPSHOT_ISOLATION :: false  // memstore, v1
```

- **`true`** — a read transaction is a stable view: concurrent commits do not disturb it,
  and a reader outside an open write transaction sees the pre-commit dataset.
- **`false`** — the backend does not isolate; it **detects**. Any mutation of the dataset
  invalidates every other open transaction, and a read through an invalidated
  transaction fails with `.Stale_Txn`. While a write transaction is open, every other
  access to that dataset — autocommit reads, autocommit inserts, other transactions —
  is refused the same way.

Under either value, no consumer ever receives a stale or smeared answer. The difference
is whether it receives the right answer or a loud refusal, and that difference is
readable in the source rather than implied.

### 4. kvstore: publication, plus one correctness detail.

The LMDB backend gets all three universal properties and `SNAPSHOT_ISOLATION :: true`
free. The work is publishing an opaque `Txn` wrapping `^lmdb.Txn`, threading it through
the read paths, and giving `match` a `_txn` form whose iterator **borrows** the
transaction instead of owning one — `match_destroy` then closes the cursor and leaves the
transaction alone. Bare `match` keeps owning its own, unchanged.

One detail is not free: `Store.next`, the in-memory mirror of the per-kind ID counters,
is advanced by interning but is not rolled back when a transaction aborts, while the
persisted counters in `meta` *are* (they are written inside the same LMDB transaction).
Today this is reachable only through a loader aborting on a parse error, and it is
benign — kvstore's reverse lookup is a key lookup, not an array index, so the effect is
an unused gap in the ID space. With aborts published it becomes ordinary, so `Txn`
snapshots `next` at begin and restores it on abort, keeping the mirror equal to what is
persisted. That invariant is worth holding for STORE-T-0021 (sentinel reservation) even
though nothing observable depends on it today.

**Costs to document in the contract, not to hide:** an open read transaction pins pages,
so a long snapshot makes a concurrent writer grow the file; and an open write transaction
holds the environment's writer lock, so it serializes every other writer against that
environment for its lifetime. The validate-before-commit consumer holds a write
transaction across an entire SHACL validation *by construction* — read-your-own-writes is
the whole point — so write transactions in that pattern are long, and that is the price
LMDB charges anyone. Validating under a read transaction instead is not equivalent; it is
precisely the window STORE-T-0022 describes.

### 5. memstore: a real write half, a detecting read half. The two halves differ, deliberately.

- **Writes — a journal, and a real guarantee.** A write transaction records the quads
  its `insert_txn` calls reported as newly added. Commit is a no-op (the writes are
  already in the live structures); abort walks the journal and removes each quad from
  the membership set, from the pending buffer if it is still there, and otherwise from
  the three sorted index arrays by binary search. The cost is `O(k log n + k·n)` for `k`
  rolled-back quads, on the exceptional path, for transactions that are candidate
  resource descriptions — tens of quads, not millions. memstore therefore offers full
  atomicity and read-your-own-writes.
- **Reads — a generation counter, failing loudly.** The dataset carries a generation
  bumped by every mutation. A transaction records the generation it saw; a write
  transaction's own writes bump it and the transaction adopts the new value, so a writer
  never stales itself. Every other open transaction becomes stale at that instant and
  every read through it returns `.Stale_Txn`. `SNAPSHOT_ISOLATION :: false`.
- **The dictionary does not roll back.** Per point 3, atomicity is over quads. This keeps
  the journal to one array and leaves STORE-I-0001 decision 5's monotonic dictionary
  ("a prerequisite for time travel — terms must never vanish") intact.
- memstore gains an `Error` type it does not have today (`.Stale_Txn`, `.Txn_Conflict`).
  It appears only on the `_txn` procedures; the bare procedures keep their error-free
  signatures.

**The upgrade path is designed and costed, not hand-waved.** memstore *can* have real
snapshots cheaply, because the store is append-only and `merge_into` already allocates a
fresh index array and frees the old one on every flush. Retaining the old arrays instead
of freeing them while a transaction is open, and flushing at `txn_begin`, gives a
transaction three stable slices that are exactly the dataset as of its opening —
copy-on-write at whole-index granularity, using the allocation pattern that is already
there. It is not chosen for v1 because of what it would actually buy. memstore has no
locking anywhere: `insert` racing `match` across threads is undefined behaviour with or
without snapshots, so retained-index snapshots do not make memstore concurrency-safe.
What they buy is that a *single-threaded* consumer's interleaving mistake silently works
instead of being reported — and detection is the better trade for a backend whose whole
point is speed, per the reasoning STORE-T-0019 already sketched. The declared capability
is what makes deferring it safe: flipping `SNAPSHOT_ISOLATION` to `true` later is a
strengthening the contract and the suite already have a branch for, requiring no
consumer change and no contract revision.

### 6. The conformance suite gains a capability-conditional tier, and skips nothing.

The universal core (point 3) runs against every backend. The isolation behaviour is
branched on the declared constant, and **both branches are positive assertions**:

- `SNAPSHOT_ISOLATION == true` — open a read transaction, commit a write through the
  dataset, assert the transaction's reads are unchanged; assert a reader outside an open
  write transaction does not see its writes.
- `SNAPSHOT_ISOLATION == false` — the same interleavings, asserting `.Stale_Txn`.

memstore's weaker guarantee is therefore *tested*, not skipped. A backend that declares
`true` and then smears fails the suite; a backend that declares `false` and then quietly
serves stale data fails it too. Both backends, both `Term_ID` widths, as always. The
`conformance.Backend` adapter grows the transactional procedure pointers and one
`snapshot_isolation: bool` field.

### 7. What this decision does not settle.

`remove` (STORE-T-0023) and `insert_all` (STORE-T-0024) are out of scope and get simpler
once this handle exists. Ordered iteration (STORE-T-0015) and cardinality estimates
(STORE-T-0018) are untouched. Multi-writer conflict detection, retry, and isolation
levels beyond LMDB's single-writer model are not designed here. Nested transactions are
forbidden rather than deferred-with-a-shape.

## Alternatives Analysis **[CONDITIONAL: Complex Decision]**

| Option | Pros | Cons | Risk Level | Implementation Cost |
|--------|------|------|------------|-------------------|
| One `Txn`, `.Read`/`.Write` mode, declared isolation capability (chosen) | One concept, one lifetime, one set of read procedures; a snapshot is a read txn by construction; honest per-backend guarantees are readable at compile time; memstore can strengthen later without a contract change | Mode is checked at runtime, not in the type; `_txn` suffix on what becomes the primary API | Low | M (kvstore S, memstore M, contract L) |
| Two concepts: `Snapshot` (read) and `Txn` (write) | Type-level guarantee that a snapshot cannot write; each type documents intent | Two lifetimes and two sets of read procedures, or a union/wrapper to unify them — precisely the "two overlapping concepts in one interface" STORE-T-0022 warns against; the write handle needs snapshot semantics anyway, so the read type would be a strict subset | Medium | L |
| Ambient transaction on the dataset handle (`begin`/`commit` change dataset state; reads take no extra parameter) | Cheapest for consumers by far — odin-rdf-sparql and odin-rdf-shacl compile unchanged | Hidden global state; cannot express two simultaneous read views; a nested consumer (SHACL running inside an application's write transaction) silently joins whatever is ambient with no way to tell | High | S |
| Uniform semantics: memstore does copy-on-write to match kvstore | One guarantee, one suite, nothing conditional | Pays real memory and complexity for isolation that does not make memstore thread-safe anyway; the contract would be shaped by the weaker backend's cost rather than by evidence — the outcome both items name as the thing to avoid backing into | Medium | L |
| Uniform semantics downward: kvstore also only detects | Symmetric contract, trivially uniform suite | Discards MVCC the persistent backend already has, for symmetry's sake; the P0 consumer needs the real guarantee | High | S |
| Ship STORE-T-0019 and STORE-T-0022 separately | Each lands sooner | The concrete risk both items name: two handles for one concept, each shaped by whichever consumer arrived first, with a merge later that breaks both | High | M now, H later |

## Rationale **[REQUIRED]**

- **The hypothesis in STORE-T-0022 is correct, and the code says so.** LMDB's read
  transaction is literally the snapshot STORE-T-0019 asks for, and kvstore already opens
  one per read. There is no second mechanism to build — only a decision about whether to
  expose it once or twice. Exposing it twice would create a distinction the persistent
  backend does not have.
- **A declared capability is the only honest way to keep one contract over two backends.**
  Both items independently identified "the contract must not pretend both backends offer
  the same guarantee" as the governing risk. Silence about a difference is the failure
  mode; a compile-time constant with both branches tested is the smallest thing that
  makes the difference visible to a consumer and enforceable by the suite. It is
  introduced here for isolation and is available to later optional capabilities
  (ordering, estimates) without this ADR speculating about them.
- **Detection beats a weak promise, and beats an expensive one.** A memstore consumer
  that interleaves a write with an open transaction has made a mistake; failing loudly at
  the read is strictly better than the silent smear possible today, and better than
  paying copy-on-write to make the mistake work in a backend that still cannot be shared
  across threads. Because the strengthening is designed and costed (point 5), choosing
  detection now is a deferral rather than a dead end.
- **The two memstore halves genuinely differ, which is the point.** A write journal is a
  bounded array and a rollback loop; snapshot isolation is a change to how every index
  array is owned. Both items predicted the asymmetry and asked for it to be recorded
  rather than smoothed over. Recording it is what lets memstore ship full atomicity —
  the P0 half — without waiting on the read half.
- **Atomicity over quads, not over the dictionary,** is what makes memstore's journal one
  array instead of a per-kind unwind of five maps and five arrays. It costs nothing
  observable: an orphaned term matches no quad, and STORE-I-0001 decision 5 already
  commits the dictionary to monotonic growth for the time-travel variant's sake.
- **Forbidding the iterator-plus-write combination** rather than defining it keeps the
  cheapest correct implementation available in both backends and matches the posture the
  interface already takes toward iterator validity. Defining it would mean specifying
  LMDB's cursor-fixup behaviour as contract, for a combination no consumer has asked for.
- **Both existing items' acceptance criteria are discharged by one design**, including
  the one that asks for exactly this: "designed jointly with STORE-T-0019, and the
  outcome recorded — one handle with a read-only mode, or two distinct concepts, with the
  reason."

## What happens to STORE-A-0002 **[REQUIRED]**

**Amended, not superseded.** STORE-A-0002's decision — the match interface is a
documented procedure-set convention enforced by a shared conformance suite, with no
vtable — is untouched and is again validated: a whole transaction model extends the
procedure set without disturbing the convention, exactly as that ADR's Consequences
anticipated ("the expected interface revision … will extend the procedure set; the
conformance suite grows with it").

One point does change, and it is the point that ADR did not anticipate. **Point 3** says
the shared suite is *the* enforcement mechanism and "passing it is the definition of
implementing the interface", with the suite implicitly uniform. That is no longer true
in full: the suite now has a universal core plus a tier selected by a backend's declared
capability. The definition becomes **"passing the universal core, plus the branch your
declared capabilities select"** — a backend cannot escape a tier by declaring less, it
only selects which assertions apply, and every declaration is asserted positively.

The following amendment is proposed for STORE-A-0002's Amendments section, **to be
applied when this ADR is decided** — a decided ADR should not be edited on the strength
of a draft one:

> **2026-08-07**: STORE-A-0005 (transactions and snapshots) adds a capability-conditional
> tier to the conformance suite: backends declare `SNAPSHOT_ISOLATION`, and the suite
> asserts a different — but equally positive — set of properties per declaration. This
> qualifies point 3: passing the suite means passing the universal core plus the branch a
> backend's declared capabilities select. The convention itself, and points 1, 2, 4, 5,
> and 6, are unchanged.

Also unchanged, and stated explicitly so the boundaries are not left to inference:

- **The append-only stance (STORE-I-0001 decision 5) survives.** Abort is not removal:
  it retracts writes that were never visible to anyone. There is still no way to retract
  a committed quad, and STORE-T-0023 remains the item that changes that. One consequence
  is worth flagging forward: a future append-only time-travelling backend, where
  everything appended is visible forever, would need to stage a transaction's writes
  before making them visible — the logical-visibility framing of point 5 of STORE-A-0002
  keeps that conforming, but it is real work for that backend rather than free.
- **The no-ordering stance is untouched.** This ADR adds nothing to and takes nothing
  from what iteration order guarantees; that remains STORE-T-0015's subject.
- **`remove`'s specified-but-unimplemented contract is untouched**, and composes with
  this one as STORE-T-0023 expects ("replace this resource's description" is a remove and
  an insert in one transaction).

## Consequences **[REQUIRED]**

### Positive
- Validate-before-commit becomes expressible: build the candidate inside a write
  transaction, run SHACL or a query through that same transaction, commit or abort on the
  answer. The P0 correctness gap closes for both backends.
- A query becomes an answer about one dataset: odin-rdf-sparql takes a read transaction
  at `query_init` and releases it at `query_destroy` — exactly the lifetime a `Query`
  already has.
- One concept, one lifetime, one vocabulary. Nothing in the interface says "snapshot".
- Every existing consumer keeps compiling and keeps its current semantics; autocommit is
  now *defined* (a one-operation transaction) rather than merely how it happens to work.
- kvstore's already-built, already-tested transactional machinery stops being reachable
  only by handing the store a serialized document.
- A consumer can read a backend's guarantee at compile time instead of inferring it.

### Negative
- memstore consumers get a weaker read guarantee than kvstore consumers, and portable
  code must handle `.Stale_Txn` from a backend where kvstore never produces it. This is
  the cost of not pretending; it is mitigated by the strengthening path in point 5.
- memstore acquires an error type and a mutation-generation check on transactional reads —
  a small cost on a backend that exists for speed. It falls only on the `_txn` paths.
- The `_txn` suffix marks the primary API for the sake of not renaming the convenience
  one. Every future read operation must be added twice.
- A long-lived kvstore write transaction serializes every writer against that environment,
  and the target consumer's pattern makes those transactions long by construction.
- The conformance suite is no longer a single uniform body of assertions, which is a
  standing invitation to let backends drift by declaring less. Mitigation: capabilities
  are compile-time constants in the backend package, both branches assert positively, and
  a new capability is an ADR-level addition, not a per-backend convenience.

### Neutral
- Terms interned inside an aborted transaction may or may not remain interned, by design;
  no conformance assertion covers it.
- kvstore's `Store.next` mirror gains snapshot/restore around abort — an invariant repair
  with no observable effect today.
- odin-rdf-shacl's `Access` adapters and odin-rdf-sparql's read sites would bind to a
  transaction rather than to a bare dataset. Those are changes in *those* repos, to be
  raised there as proposals once this handle exists — not made here.
- The vision's "concurrency guarantees beyond single-threaded use" non-goal
  (STORE-I-0001) is narrowed rather than reversed: kvstore's guarantee is the one LMDB
  already provides across processes; memstore gains no concurrency guarantee at all.

## Review Schedule **[CONDITIONAL: Temporary Decision]**

### Review Triggers
- A memstore consumer hits `.Stale_Txn` in correct-looking single-threaded code, or asks
  for isolation it can pay for — triggers adopting the retained-index snapshots of point
  5 and flipping `SNAPSHOT_ISOLATION`, which the contract and suite already accommodate.
- A consumer needs two simultaneous read views of one dataset, or a transaction that
  outlives a single call stack — triggers reviewing the caller-held-value handle shape.
- STORE-T-0023 (`remove`) lands and its iterator-invalidation question interacts with
  point 3's invalidation rule.
- A second declared capability is proposed (ordering, cardinality estimates) — triggers
  reviewing whether the capability-constant device generalizes or whether the suite's
  conditional tier is becoming a matrix.
- Multi-writer coordination is requested, or a consumer wants a write transaction across
  processes that is not LMDB's — explicitly out of scope here, so it reopens the scope
  guard rather than this decision.