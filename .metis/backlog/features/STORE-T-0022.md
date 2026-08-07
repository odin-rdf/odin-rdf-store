---
id: write-transactions-atomic-multi
level: task
title: "Write transactions: atomic multi-quad writes, and reading your own writes"
short_code: "STORE-T-0022"
created_at: 2026-08-07T15:11:19.646429+00:00
updated_at: 2026-08-07T15:11:19.646429+00:00
parent: 
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/backlog"
  - "#feature"


exit_criteria_met: false
initiative_id: NULL
---

# Write transactions: atomic multi-quad writes, and reading your own writes

## Objective **[REQUIRED]**

Give a consumer a handle that means **"these writes land together, and while I
hold it my reads include them"**. Two capabilities, one concept:

1. **Atomicity** — several quads become visible together or not at all.
2. **Read-your-own-writes** — a read issued through an open transaction
   observes that transaction's uncommitted writes.

**Evidence — validate-before-commit cannot be expressed.**

The pattern is the same in every application that accepts data from outside
itself: receive a description of a resource, decide whether it may join the
dataset by *examining the dataset it would produce*, and keep it only if the
answer is yes. The decision procedure is usually SHACL (odin-rdf-shacl reads
the data graph through the match interface alone) or a query, and both read
through this contract. Today neither can see the write it is deciding about:

- **`match` opens its own read transaction.** Every kvstore read path does —
  `match`, `find_term`, `lookup_term`. So a validator run between a write and
  its commit reads the dataset as though the write had not happened. There is
  no ordering of the existing primitives that produces "validate the candidate
  dataset".
- **Validate-then-commit has a window.** Two writers that validate against a
  dataset lacking each other's write can both conform and both commit,
  producing a dataset that satisfies neither's constraints. Within one process
  a consumer can serialize this with its own lock at no throughput cost, since
  LMDB admits one writer anyway. Across processes it cannot — and the vision's
  deployment shape is ~200 processes per machine, each embedding a store.
- **Commit-then-validate cannot be undone.** There is no `remove`
  (STORE-T-0023), so a write that turns out to be invalid is permanent.
- **The isolated-candidate workaround is wrong, not merely slow.** Building the
  candidate in a second (in-memory) dataset and validating *that* is the only
  option the current interface admits. It gives the right answer only for
  constraints that read nothing outside the candidate. Anything that must see
  existing data — a class hierarchy already in the store, a reference to an
  existing resource, uniqueness across the dataset — reads an empty world and
  passes vacuously. A validator that cannot fail is worse than one that is
  absent.

**Relationship to STORE-T-0019 (snapshot reads).** That item is this one's read
half: *one query, one consistent view*. This is the write half. They are very
probably **one handle** — a transaction that reads consistently and writes
atomically, of which a read-only transaction is exactly a snapshot — and they
should be designed together. Landing them separately risks two overlapping
concepts in one interface, each shaped by whichever consumer arrived first.
Both also share the same hard question, which is memstore.

**Much of kvstore already exists, unpublished.** `insert_txn`, `load_begin`,
`load_scope_destroy`, `scope_term`, `scope_blank`, and `scope_insert_triple`
are all `@(private)`, and every public loader (`load_triples`, `load_turtle`,
`load_quads`, `load_trig`) already runs exactly one transaction across a whole
document, aborting it on a parse error. The capability is built, tested, and
reachable only by handing the store a serialized document. What is missing is a
contract for it and a way to say it.

## Backlog Item Details **[CONDITIONAL: Backlog Item]**

### Type
- [x] Feature - New functionality or enhancement

### Priority
- [x] P0 - Critical (blocks a class of consumer)

The one item on this list that is a *correctness* gap rather than an
ergonomics gap. Every other write-path limitation has a workaround that is
merely ugly; this one's workaround is a validator that silently approves.

### Business Justification **[CONDITIONAL: Feature]**
- **User Value**: An application can decide whether to keep a write by looking at what the write would produce, and can write several quads as one unit. Those are the two things any editing application needs and neither is expressible today.
- **Business Value**: Opens the store to the whole class of consumers that accept data from outside themselves — services, interactive shells, editors — which is the majority of what the family is for. Getting the concept into the interface before consumers build around per-operation autocommit is far cheaper than after.
- **Effort Estimate**: S–M for kvstore (the machinery exists behind `@(private)`; the work is threading a caller-supplied transaction through the read paths and publishing it). M–L for memstore, which has no versioning and needs a journal to make abort meaningful. L for the contract, which is the real work and is shared with STORE-T-0019.

## Acceptance Criteria **[REQUIRED]**

- [ ] A transaction handle in the backend convention: begin one from a dataset, insert through it, read through it (`match`, `find_term`, `lookup_term`, and whatever STORE-T-0016 adds), then commit or abort.
- [ ] **Read-your-own-writes**: a read issued through an open transaction observes that transaction's own uncommitted writes.
- [ ] **Atomicity**: after commit, every write of the transaction is visible; after abort, none is. No intermediate state is observable from outside.
- [ ] `store/interface.odin` states the write model, including what a consumer that never opens a transaction may assume. Today's per-operation autocommit `insert` must remain valid and unchanged — this adds a way to say more, it does not retract the existing one.
- [ ] **Designed jointly with STORE-T-0019**, and the outcome recorded: one handle with a read-only mode, or two distinct concepts, with the reason. Not left to fall out of whichever is implemented first.
- [ ] memstore's guarantee decided and documented even where it is weaker than kvstore's. A stated limitation beats an implied guarantee — the position STORE-T-0019 already takes.
- [ ] Conformance suite, both backends, both `Term_ID` widths: abort leaves nothing; commit leaves everything; reads inside see the transaction's writes; reads outside do not until commit.
- [ ] The interaction with match iterators is specified. Today an iterator is valid only until its dataset is mutated; the contract must say what an iterator opened inside a transaction observes when that transaction writes, or forbid the combination explicitly.

## Implementation Notes **[CONDITIONAL: Technical Task]**

### Technical Approach

**kvstore** is mostly publication. LMDB is MVCC and a write transaction
already gives all three properties for free; `find_term_txn`, `lookup_term_txn`,
`intern_term_txn`, and `encode_quad_txn` already exist as the `_txn` siblings
of the public procedures, proving the threading pattern out. `match` is the
one read path with no `_txn` form, because its iterator owns the transaction it
opened — that is the piece with actual design in it.

The published handle must not be `^lmdb.Txn`. Exposing it would put LMDB's type
into every consumer's source and defeat the backend-independence the whole
interface exists for — the same property `make check`'s `purity` target
protects in odin-rdf-shacl. An opaque per-backend `Txn` type, named by the
convention rather than by LMDB, is the shape.

**memstore** is where the decision lives, and it is the same decision
STORE-T-0019 names. There is no versioning, so abort must be made meaningful:
a write journal that can be rolled back, copy-on-write over the permutation
indexes, or a documented weaker guarantee. Note that a journal is
substantially easier for writes than copy-on-write is for snapshots, so the
two halves may not have the same answer — which is itself worth recording.

### Dependencies

Should be designed with **STORE-T-0019** (snapshot reads) and lands naturally
before **STORE-T-0023** (`remove`), which composes with it: "replace this
resource's description" is a remove and an insert in one transaction.

Consumers: `odin-rdf-app`, for the validate-before-commit path; odin-rdf-shacl,
whose `Access` adapters would bind to a transaction rather than to a bare
dataset, which is a change on that side and should be raised there once the
handle exists.

### Risk Considerations

The two backends may not afford the same guarantee at an acceptable cost, and
the contract must not pretend they do — the risk STORE-T-0019 already records.
A conformance suite that asserts transaction semantics uniformly would force
memstore into an implementation it may not want; that is a decision to make
deliberately rather than back into.

A second risk is scope creep into a general concurrency story. This item is
about *one writer's* atomicity and visibility. Multi-writer conflict detection,
retry, and isolation levels beyond what LMDB's single-writer model gives are
not part of it and should not be designed here.

## Status Updates **[REQUIRED]**

- **2026-08-07 — Created from a consumer design review.** The first application-shaped consumer of the family (`odin-rdf-app`) worked through a create-resource request end to end and found validate-before-commit inexpressible. Awaiting pickup in an odin-rdf-store session.
- **2026-08-07 — Designed jointly with STORE-T-0019 as STORE-A-0005** (since archived
  undecided; see the following update). One handle,
  two modes; the "designed jointly, outcome recorded" criterion is discharged there. The
  guarantee split is a universal core (atomicity, read-your-own-writes, provisional IDs,
  single writer, iterator invalidation) plus one declared capability
  (`SNAPSHOT_ISOLATION`), so the conformance suite branches instead of forcing memstore
  into copy-on-write — and asserts both branches positively rather than skipping one.
  memstore's write half is a journal and a full guarantee; its read half detects rather
  than isolates. Recommended for promotion to an initiative together with STORE-T-0019.
- **2026-08-07 — Blocked behind STORE-I-0003 (retire memstore); STORE-A-0005 archived
  undecided.** With memstore gone, this item's P0 capability is very nearly publication
  work: LMDB already gives atomicity and read-your-own-writes, `insert_txn` and the
  `_txn` read siblings already exist behind `@(private)`, and the guarantee split that
  dominated the archived ADR disappears. The design that survives — one handle with a
  `.Read`/`.Write` mode, the `_txn` procedure set with autocommit defined beneath it,
  provisional Term_IDs, iterator invalidation on write, and `match` as the one read path
  needing real design because its iterator owns its transaction — carries into the
  rewrite. The **validate-before-commit** evidence that motivated this item is unaffected
  by the removal and remains the reason it is P0. Re-open jointly with STORE-T-0019 once
  the removal lands.
- **2026-08-07 — Unblocked. The model is decided in STORE-A-0007.** One `Txn` handle with a
  `.Read`/`.Write` mode, carrying its own dataset; the `_txn` procedure set with the existing
  bare procedures defined as autocommit, so nothing that compiles today stops compiling. The
  guarantees are stated flat, with no universal-core/declared-capability split: read-your-own-writes,
  snapshot isolation, atomicity over quads (not over the dictionary), provisional `Term_ID`s
  discarded on abort, single writer, no nesting, and iterator invalidation on a write through
  the same transaction. Two things the archived design left per-backend are now decided: a
  second write transaction on one handle is **refused with an error** rather than left to
  deadlock on LMDB's writer lock, and `Store.next` is snapshotted at begin and restored on
  abort so the in-memory counter mirror cannot drift from the persisted one. Validate-before-commit
  — the evidence that made this P0 — is expressible as designed: build the candidate inside a
  write transaction, validate through that same transaction, commit or abort on the answer.
  Its price is stated in the contract rather than discovered: that write transaction is held
  across an entire SHACL validation by construction, and it serializes every other writer
  against that environment for its lifetime. Ready to decompose jointly with STORE-T-0019.
