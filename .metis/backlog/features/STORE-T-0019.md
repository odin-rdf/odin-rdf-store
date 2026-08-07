---
id: snapshot-reads-one-query-one
level: task
title: "Snapshot reads: one query, one consistent view of the dataset"
short_code: "STORE-T-0019"
created_at: 2026-08-05T22:35:58.695768+00:00
updated_at: 2026-08-05T22:35:58.695768+00:00
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

# Snapshot reads: one query, one consistent view of the dataset

## Objective **[REQUIRED]**

Give a consumer a handle that means **"the dataset as it was when I opened
this"**, and let every read of one query go through it.

**Evidence.** A SPARQL query is defined against one dataset, not against a
sequence of them. odin-rdf-sparql reads the store in five distinct places per
query, and today each is an independent read:

1. **Term binding** at setup — `find_term` per ground term in the query
   (`sparql/plan.odin`).
2. **Matching** — one `match` iterator per triple pattern per depth, opened
   and closed as the join chain advances and backtracks (`sparql/exec.odin`).
3. **Materialization** — `lookup_term` per result term, at the answer
   boundary and inside expression evaluation.
4. **Triple-term decomposition** — `lookup_term` plus `find_term` per
   component, for a non-ground triple-term pattern (SPARQL-T-0018; see
   STORE-T-0020).
5. **Dataset introspection**, where it exists at all — the graph scan and the
   path node collection, each a full pass (STORE-T-0016).

Nothing in the engine assumes those five see the same dataset, because
nothing can. The current contract says an iterator is valid only until its
dataset is mutated, which is a rule about *crashing*, not about *answering*:
it does not say what a query means if a writer commits between pattern one
and pattern two. Under concurrency the answer would be a smear — a solution
assembled from two different datasets, which is not an answer to the query at
all.

This has not bitten: the suites are single-threaded, so the engine has never
observed an inconsistent read. It is recorded as an **API-shape** need rather
than a bug, exactly as SPARQL-I-0002's design phase framed it. The engine
already has one instance of the property done right and can point at what it
buys: `NOW()` is fixed once for the whole query (§17.4.5.1), so two calls
cannot disagree — the same "a query's answer is a snapshot rather than a
smear" property, at the clock instead of at the data.

## Backlog Item Details **[CONDITIONAL: Backlog Item]**

### Type
- [x] Feature - New functionality or enhancement

### Priority
- [x] P2 - Medium (nice to have)

Nothing is wrong today because nothing writes concurrently. It becomes P0 the
day a consumer reads while another process writes — which the vision's
"~200 processes per machine" deployment shape makes a question of when.

### Business Justification **[CONDITIONAL: Feature]**
- **User Value**: A query's answer is an answer about one dataset. Long-running reads stop being wrong in the presence of writers.
- **Business Value**: It is the last structural correctness gap between the engine as tested (single-threaded suites) and the engine as deployed. Cheaper to get into the interface before three consumers have built around per-operation reads than after.
- **Effort Estimate**: S for kvstore, M for memstore, L for the contract. LMDB is MVCC: a read transaction *is* a snapshot, and kvstore already opens one per operation — the work is holding one open across a query instead. memstore has no versioning at all, so an honest snapshot there is either copy-on-write indexes or a documented "no writer may run" precondition.

## Acceptance Criteria **[REQUIRED]**

- [ ] A snapshot handle in the backend convention: open one from a dataset, read through it (`match`, `find_term`, `lookup_term`, and whatever STORE-T-0016 adds), close it. Reads through one snapshot see one dataset.
- [ ] `store/interface.odin` states the read model: what a consumer that does *not* take a snapshot may assume, and what a snapshot adds. Today's per-operation reads must remain valid — a consumer that never opens one keeps working.
- [ ] kvstore holds one LMDB read transaction for the snapshot's life, with the long-reader cost documented (a long snapshot pins pages and grows the file against a concurrent writer — a real trade-off the consumer must be told about, not a detail).
- [ ] memstore's answer decided and documented, even if the answer is "the in-memory backend offers a snapshot only in the absence of writers" — a stated limitation beats an implied guarantee.
- [ ] Conformance suite: open a snapshot, insert through the dataset handle, and assert the snapshot's reads are unchanged (skipped or specialized for a backend whose documented answer is the weaker one).

## Implementation Notes **[CONDITIONAL: Technical Task]**

### Technical Approach

kvstore is the easy and the instructive one: `lookup_term`, `find_term`, and
`match` each open their own read transaction today, so the shape already
exists — the change is threading a caller-supplied one, which
`find_term_txn` (STORE-T-0014) proved out for a single procedure.

memstore is where the design decision lives. Copy-on-write over the
permutation indexes buys real snapshots at real cost; a generation counter
that lets a snapshot *detect* invalidation and fail loudly is much cheaper
and may be the better trade for an in-memory backend whose whole point is
speed. Failing loudly is strictly better than the silent smear that is
possible today.

### Dependencies

None. Consumer: odin-rdf-sparql — a `Query` would take a snapshot at
`query_init` and release it at `query_destroy`, which is exactly the lifetime
it already has.

### Risk Considerations

The two backends may not be able to offer the same guarantee at an acceptable
cost, and the contract must not pretend they do. A conformance suite that
asserts snapshot semantics uniformly would force memstore into copy-on-write
to pass — which is a decision to make deliberately, not one to back into.

## Status Updates **[REQUIRED]**

- **2026-08-05 — Created from odin-rdf-sparql SPARQL-T-0019**, the evaluation initiative's evidence consolidation. Awaiting pickup in an odin-rdf-store session.
- **2026-08-07 — Designed jointly with STORE-T-0022 as STORE-A-0005** (since archived
  undecided; see the following update). The
  hypothesis holds: one `Txn` handle with a `.Read`/`.Write` mode, of which a read-only
  transaction is the snapshot this item asks for. No separate snapshot concept enters the
  interface. memstore's answer is the declared one this item allowed for — a generation
  counter that fails loudly (`SNAPSHOT_ISOLATION :: false`), with retained-index
  copy-on-write designed and costed as the upgrade path — while its *write* half is a
  full guarantee, the asymmetry both items predicted. Recommended for promotion to an
  initiative together with STORE-T-0022 rather than worked as a standalone item.
- **2026-08-07 — Blocked behind STORE-I-0003 (retire memstore); STORE-A-0005 archived
  undecided.** memstore is being removed, which does not simplify this item's hard
  question — it deletes it. What remains is LMDB's read transaction, which *is* the
  snapshot this item asks for: no declared capability, no conditional conformance tier,
  no copy-on-write question. The finding that survives and should drive the rewrite is
  the one that matters here — **a snapshot is a read-only transaction, not a separate
  concept.** Re-open jointly with STORE-T-0022 once the removal lands.
