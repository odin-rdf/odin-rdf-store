---
id: 001-transactions-and-snapshots-one
level: adr
title: "Transactions and snapshots: one handle, two modes"
number: 1
short_code: "STORE-A-0007"
created_at: 2026-08-07T20:35:00+00:00
updated_at: 2026-08-07T21:41:07.102288+00:00
decision_date: 
decision_maker: gregerolsson
parent: 
archived: false

tags:
  - "#adr"
  - "#phase/decided"


exit_criteria_met: false
initiative_id: NULL
---

# ADR-7: Transactions and snapshots: one handle, two modes

## Context **[REQUIRED]**

Two backlog items arrived from two different consumers and describe two halves of the same
missing concept:

- **STORE-T-0019 (snapshot reads)**, from odin-rdf-sparql's evaluation initiative: a query
  reads the store in five distinct places, each an independent read, so nothing makes a
  query's answer an answer *about one dataset*. Under a concurrent writer the result is a
  smear — a solution assembled from two datasets.
- **STORE-T-0022 (write transactions)**, from the first application-shaped consumer
  (`odin-rdf-app`) working a create-resource request end to end: **validate-before-commit is
  inexpressible**. `match` opens its own read transaction, so a validator deciding whether a
  write may join the dataset cannot observe the write it is deciding about. Validate-then-commit
  leaves a window that cannot be closed in application code across the vision's ~200 processes
  per machine; commit-then-validate is irreversible while there is no `remove`; and validating
  an isolated candidate graph silently passes every constraint that must read existing data —
  a validator that cannot fail.

The second item states the hypothesis this ADR exists to settle: they are *very probably one
handle*, of which a read-only transaction is exactly a snapshot. Landing them separately would
put two overlapping concepts in one interface, each shaped by whichever consumer arrived first.

**What the code already looks like.** kvstore has most of the write half built and unpublished:
`insert_txn`, `intern_term_txn`, `find_term_txn`, `lookup_term_txn`, `encode_quad_txn`, and the
`load_begin` / `scope_*` family are all `@(private)`, and every public loader already runs
exactly one LMDB write transaction across a whole document, aborting it on a parse error. LMDB
is MVCC: a read transaction *is* a snapshot, a write transaction gives atomicity and
read-your-own-writes, and only one writer runs at a time. The capability is built and tested;
what is missing is a contract for it and a way to say it. The one read path with no `_txn`
sibling is `match`, because its iterator owns the read transaction it opened — that is the piece
with actual design in it.

**What one backend buys here.** STORE-A-0006 retired memstore, which had no versioning of any
kind. Everything below is therefore stated as a guarantee rather than as a capability a consumer
must check and a suite must branch on — see *Relationship to prior decisions* for what that
replaced.

Scope guard, taken from STORE-T-0022 and unchanged: this is about **one writer's** atomicity and
visibility. Multi-writer conflict detection, retry, and isolation levels beyond what LMDB's
single-writer model gives are not designed here.

## Decision **[REQUIRED]**

### 1. One handle, two modes. A read-only transaction *is* a snapshot.

The backend publishes an opaque `Txn` type — named by the convention, never `^lmdb.Txn`, whose
exposure would put LMDB's types into every consumer's source and defeat the interface's separation
from its backend even now that there is only one. There is no separate `Snapshot` type and no
separate snapshot vocabulary. STORE-T-0019 is settled as a *mode*, not as a concept:

```odin
Txn_Mode :: enum { Read, Write }

txn_begin  (s, mode: Txn_Mode, allocator := context.allocator) -> (Txn, Error)
txn_commit (t: ^Txn) -> Error   // on a Read txn: legal, equivalent to txn_abort
txn_abort  (t: ^Txn)
```

`Txn` is a caller-held value, exactly as `Match_Iterator` is today, and it **carries its
dataset**: every transactional procedure takes `^Txn` alone, not `(s, txn)`. The existing private
`(s, txn, …)` internals stay internal. A consumer threads one handle, which is what
odin-rdf-shacl's `Access` adapters and an odin-rdf-sparql `Query` want to hold.

This discharges STORE-T-0022's "one handle or two concepts, with the reason" criterion. The reason
is that LMDB's read transaction is literally the snapshot STORE-T-0019 asks for; exposing it twice
would create a distinction the storage does not have.

### 2. Every operation gains a `_txn` form; every existing form survives unchanged.

```odin
insert_txn     (t: ^Txn, q: Encoded_Quad)      -> (added: bool, err: Error)
count_txn      (t: ^Txn)                       -> (n: int, err: Error)
match_txn      (t: ^Txn, pattern)              -> (it: Match_Iterator, err: Error)
find_term_txn  (t: ^Txn, term)                 -> (id: Term_ID, found: bool, err: Error)
lookup_term_txn(t: ^Txn, id, allocator)        -> (term: rdf.Term, err: Error)
intern_term_txn(t: ^Txn, term)                 -> (id: Term_ID, err: Error)
```

— and the same for `encode_quad_txn` / `decode_quad_txn`, the three graph-label procedures, and
whatever STORE-T-0016 adds. The bare forms (`insert`, `count`, `match`, `find_term`,
`lookup_term`, …) remain, unchanged in name, signature, and semantics, and are **defined as
autocommit**: open a transaction of the appropriate mode, do the one operation, close it. That is
already literally how kvstore implements them. Nothing an existing consumer wrote stops compiling
or changes meaning; this adds a way to say more.

The `_txn` suffix on what will become the primary API is admitted to be backwards naming. It is
chosen because the alternative — giving the transactional forms the plain names — renames every
procedure odin-rdf-sparql and odin-rdf-shacl already call, which both backlog items explicitly
forbid. Additive and ugly beats elegant and breaking.

### 3. The guarantees.

Not a "universal core" over anything, and nothing conditional. This is the contract:

- **Read-your-own-writes.** A read through an open transaction observes that transaction's own
  uncommitted writes.
- **Snapshot isolation.** A read transaction is a stable view: concurrent commits do not disturb
  it, and a reader outside an open write transaction sees the pre-commit dataset. No consumer ever
  receives a stale or smeared answer.
- **Atomicity over quads.** After commit, every quad written by the transaction is visible; after
  abort, none is.
- **Provisional IDs.** `Term_ID`s assigned by interning inside a transaction are valid only if it
  commits; on abort a consumer must discard them. Whether the *term* remains interned after an
  abort is deliberately unspecified: atomicity is defined over quads, not over the dictionary. A
  term interned but never used by a committed quad is invisible through the quad contract —
  `find_term` may report it, and matching it yields nothing, which is the correct answer either
  way. This also keeps STORE-I-0001 decision 5's monotonic dictionary intact.
- **Single writer, no nesting.** At most one write transaction may be open on a `Store` at a time,
  and transactions do not nest. Opening a second through the same handle returns an error rather
  than blocking: LMDB's writer lock would otherwise self-deadlock a single-threaded consumer, and
  a deadlock is the worst diagnostic available for what is a programming error. Across
  *processes*, LMDB's lock serializes writers and blocking is correct — that is the concurrency
  the deployment shape actually uses, and it is not affected.
- **Iterator invalidation.** An iterator opened on a transaction is valid until `match_destroy`, a
  **write through that same transaction**, or that transaction's commit/abort — whichever comes
  first. Writing through a transaction invalidates every iterator open on it. This extends, rather
  than replaces, today's rule that an iterator is valid only until its dataset is mutated. It is
  the conservative reading LMDB's cursor-fixup behaviour permits, and it answers STORE-T-0022's
  last acceptance criterion by forbidding the combination explicitly rather than defining it.

### 4. kvstore: publication, one correctness detail, and the costs stated as contract.

The work is publishing an opaque `Txn` wrapping `^lmdb.Txn`, threading it through the read paths,
and giving `match` a `_txn` form whose iterator **borrows** the transaction instead of owning one
— `match_destroy` then closes the cursor and leaves the transaction alone. Bare `match` keeps
owning its own, unchanged. Everything in point 3 comes free from LMDB.

One detail is not free: `Store.next`, the in-memory mirror of the per-kind ID counters, is advanced
by interning but is not rolled back when a transaction aborts, while the persisted counters in
`meta` *are* (they are written inside the same LMDB transaction). Today this is reachable only
through a loader aborting on a parse error, and it is benign — the reverse lookup is a key lookup,
not an array index, so the effect is an unused gap in the ID space. With aborts published it
becomes ordinary, so `Txn` snapshots `next` at begin and restores it on abort, keeping the mirror
equal to what is persisted. That invariant is worth holding for STORE-T-0021 (sentinel reservation)
even though nothing observable depends on it today.

**Two costs are part of the interface, not backend detail.** STORE-A-0006 made the match
interface's semantics LMDB's semantics by definition; these are the first place that bites, and
they are specified rather than documented as an implementation note a second backend might escape:

- **An open read transaction pins pages.** A long-held snapshot makes a concurrent writer grow the
  file, because the pages the reader can still see cannot be reused. A consumer that holds a
  snapshot for the life of a query is fine; one that holds it for the life of a request handler is
  making a storage-sizing decision.
- **An open write transaction holds the environment's writer lock** and serializes every other
  writer against that environment for its lifetime. The validate-before-commit consumer holds a
  write transaction across an entire SHACL validation *by construction* — read-your-own-writes is
  the whole point — so write transactions in that pattern are long. Validating under a read
  transaction instead is not equivalent; it is precisely the window STORE-T-0022 describes. Across
  the vision's ~200 processes per machine, each embedding its own store, this serializes within an
  environment and not between them.

### 5. The conformance suite gains transaction assertions as one uniform body.

Every property in point 3 is asserted for every backend, unconditionally — which is what
STORE-A-0002 point 3 always claimed the suite was, and what it stops being the moment a contract
carries a capability the suite has to branch on. The `conformance.Backend` adapter grows the
transactional procedure pointers and nothing else: no capability field, no tier selection, no
skips. A backend either passes these assertions or does not implement the interface.

The concrete checks: read-your-own-writes inside a write transaction; invisibility of those writes
to a reader outside it; a read transaction unchanged across a concurrent commit; abort leaving no
quad behind; a second write transaction refused; an iterator invalidated by a write through its own
transaction; and autocommit behaving as the one-operation transaction it is defined to be. Both
`Term_ID` widths, as always.

### 6. What this decision does not settle.

`remove` (STORE-T-0023) and `insert_all` (STORE-T-0024) are out of scope and get simpler once this
handle exists. Ordered iteration (STORE-T-0015) and cardinality estimates (STORE-T-0018) are
untouched. Multi-writer conflict detection, retry, and isolation levels beyond LMDB's single-writer
model are not designed here. Nested transactions are forbidden rather than deferred-with-a-shape.

## Alternatives Analysis **[CONDITIONAL: Complex Decision]**

| Option | Pros | Cons | Risk Level | Implementation Cost |
|--------|------|------|------------|-------------------|
| One `Txn`, `.Read`/`.Write` mode (chosen) | One concept, one lifetime, one set of read procedures; a snapshot is a read txn by construction; nothing conditional in the contract or the suite | Mode is checked at runtime, not in the type; `_txn` suffix on what becomes the primary API | Low | S–M (kvstore S, contract M) |
| Two concepts: `Snapshot` (read) and `Txn` (write) | Type-level guarantee that a snapshot cannot write; each type documents intent | Two lifetimes and two sets of read procedures, or a union to unify them — precisely the "two overlapping concepts in one interface" STORE-T-0022 warns against; the write handle needs snapshot semantics anyway, so the read type would be a strict subset | Medium | L |
| Ambient transaction on the `Store` handle (`begin`/`commit` change store state; reads take no extra parameter) | Cheapest for consumers by far — odin-rdf-sparql and odin-rdf-shacl compile unchanged | Hidden global state; cannot express two simultaneous read views; a nested consumer (SHACL running inside an application's write transaction) silently joins whatever is ambient with no way to tell | High | S |
| Ship STORE-T-0019 and STORE-T-0022 separately | Each lands sooner | The concrete risk both items name: two handles for one concept, each shaped by whichever consumer arrived first, with a merge later that breaks both | High | M now, H later |

## Rationale **[REQUIRED]**

- **The hypothesis in STORE-T-0022 is correct, and the code says so.** LMDB's read transaction is
  literally the snapshot STORE-T-0019 asks for, and kvstore already opens one per read. There is no
  second mechanism to build — only a decision about whether to expose it once or twice.
- **With one backend the contract states a guarantee instead of declaring a capability.** The
  entire capability device in the archived ADR existed to let two backends differ honestly. Its
  disappearance is the concrete form of STORE-I-0003's central claim, and it is the reason this
  document is roughly half the length of the one it replaces: what is gone is not detail but a
  whole mechanism — a compile-time constant, a suite that branches on it, a journal, a generation
  counter, an error variant, and a costed upgrade path for isolation that is now simply present.
- **Atomicity over quads, not over the dictionary,** costs nothing observable — an orphaned term
  matches no quad — and it keeps abort from having to unwind the dictionary, which is the one place
  where "atomic" would have been expensive rather than free.
- **Forbidding the iterator-plus-write combination** rather than defining it keeps the cheapest
  correct implementation available and matches the posture the interface already takes toward
  iterator validity. Defining it would mean specifying LMDB's cursor-fixup behaviour as contract,
  for a combination no consumer has asked for.
- **Refusing a second write transaction rather than blocking** is the one place this ADR chooses a
  behaviour LMDB does not hand over. Within one handle a second `txn_begin(.Write)` can only be a
  mistake, and letting it deadlock spends a debugging session to report something the store already
  knows.
- **Stating the two costs as contract** follows STORE-A-0006 directly: with one backend there is no
  "portable subset" to hide them behind, and a consumer that discovers page pinning from a growing
  file is discovering it in production.
- **Both existing items' acceptance criteria are discharged by one design**, including the one that
  asks for exactly this: "designed jointly with STORE-T-0019, and the outcome recorded — one handle
  with a read-only mode, or two distinct concepts, with the reason."

## Relationship to prior decisions **[REQUIRED]**

**STORE-A-0005 is superseded in substance.** It was archived undecided rather than amended, so
there is no decision here to supersede formally; this ADR is written to stand on its own without a
reader needing to know it existed. It remains in `.metis/archived/adrs/` because the reasoning that
produced points 1 through 4 above — particularly why one handle rather than two, and why the
`_txn` suffix lands on the primary API — was worked out there and is worth reaching. **Its points 5
and 6 are dead**, along with the `SNAPSHOT_ISOLATION` declaration in its point 3 and the
STORE-A-0002 amendment it drafted.

**STORE-A-0002 is amended by neither this ADR nor the archived one.** The capability-tier amendment
drafted inside STORE-A-0005 is void, and the amendment STORE-A-0002 did receive on 2026-08-07 —
about its demonstration claim — came from STORE-A-0006. This ADR needs no third: a whole
transaction model extends the procedure set without disturbing the convention, exactly as
STORE-A-0002's Consequences anticipated ("the expected interface revision … will extend the
procedure set; the conformance suite grows with it"), and point 3's "passing the suite is the
definition of implementing the interface" is left uniform, which is the state it was written in.

**The append-only stance (STORE-I-0001 decision 5) survives.** Abort is not removal: it retracts
writes that were never visible to anyone. There is still no way to retract a committed quad, and
STORE-T-0023 remains the item that changes that. **The no-ordering stance is untouched** — that
remains STORE-T-0015's subject. **`remove`'s specified-but-unimplemented contract is untouched**
and composes with this one as STORE-T-0023 expects ("replace this resource's description" is a
remove and an insert in one transaction).

## Consequences **[REQUIRED]**

### Positive
- Validate-before-commit becomes expressible: build the candidate inside a write transaction, run
  SHACL or a query through that same transaction, commit or abort on the answer. The P0 correctness
  gap closes.
- A query becomes an answer about one dataset: odin-rdf-sparql takes a read transaction at
  `query_init` and releases it at `query_destroy` — exactly the lifetime a `Query` already has.
- One concept, one lifetime, one vocabulary. Nothing in the interface says "snapshot".
- Every existing consumer keeps compiling and keeps its current semantics; autocommit is now
  *defined* (a one-operation transaction) rather than merely how it happens to work.
- kvstore's already-built, already-tested transactional machinery stops being reachable only by
  handing the store a serialized document.
- The conformance suite stays a single uniform body of assertions, so there is no mechanism by
  which a future backend can conform by declaring less.

### Negative
- The `_txn` suffix marks the primary API for the sake of not renaming the convenience one. Every
  future read operation must be added twice.
- A long-lived write transaction serializes every writer against that environment, and the target
  consumer's pattern makes those transactions long by construction. A long-lived read transaction
  makes a concurrent writer grow the file. Both are now promises rather than notes.
- A second backend must provide snapshot isolation to conform, where the archived design would have
  let it declare its way in. That is the intended trade — STORE-A-0006 accepted a higher bar for a
  hypothetical backend in exchange for an unconditional contract for the real one.

### Neutral
- Terms interned inside an aborted transaction may or may not remain interned, by design; no
  conformance assertion covers it.
- `Store.next` gains snapshot/restore around abort — an invariant repair with no observable effect
  today.
- odin-rdf-shacl's `Access` adapters and odin-rdf-sparql's read sites would bind to a transaction
  rather than to a bare store. Those are changes in *those* repos, to be raised there as proposals
  once this handle exists — not made here.
- The vision's "concurrency guarantees beyond single-threaded use" non-goal (STORE-I-0001) is
  narrowed rather than reversed: the guarantee is the one LMDB already provides across processes,
  which is the shape the deployment actually has.

## Review Schedule **[CONDITIONAL: Temporary Decision]**

### Review Triggers
- A consumer needs two simultaneous read views of one store, or a transaction that outlives a single
  call stack — triggers reviewing the caller-held-value handle shape.
- STORE-T-0023 (`remove`) lands and its iterator-invalidation question interacts with point 3's
  invalidation rule.
- Page pinning from a long read transaction is observed to cost real disk in a deployed process —
  triggers reviewing whether the interface should offer a way to renew a snapshot cheaply, which
  LMDB supports (`mdb_txn_reset` / `mdb_txn_renew`) and this ADR deliberately does not expose.
- A second backend is proposed that cannot provide snapshot isolation — reopens whether the
  guarantee belongs in the contract or in a declared capability, which is the question STORE-A-0005
  answered for a world with two backends.
- Multi-writer coordination is requested, or a consumer wants a write transaction across processes
  that is not LMDB's — explicitly out of scope here, so it reopens the scope guard rather than this
  decision.