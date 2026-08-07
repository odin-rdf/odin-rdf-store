---
id: insert-all-an-atomic-multi-quad
level: task
title: "insert_all: an atomic multi-quad write from memory"
short_code: "STORE-T-0024"
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

# insert_all: an atomic multi-quad write from memory

## Objective **[REQUIRED]**

Let a consumer insert quads **it built in memory** as one unit.

**Evidence — every batching path requires a serialized document.** The public
write surface of kvstore is:

| Procedure | Takes | Atomic |
| --- | --- | --- |
| `insert` | one `Encoded_Quad` | one quad, one transaction |
| `load_triples` | `source: []byte` | whole document |
| `load_turtle` | `source: []byte` | whole document |
| `load_quads` | `source: []byte` | whole document |
| `load_trig` | `source: []byte` | whole document |

Every batching path runs a parser. The primitives underneath them —
`load_begin`, `scope_term`, `scope_blank`, `scope_insert_triple`,
`insert_txn` — are all `@(private)`.

So a consumer holding quads it constructed itself, from a form submission, a
CLI's arguments, a transformation of query results, or any other source that is
not a file, has two options:

1. **N calls to `insert`**, each opening and committing its own transaction.
   Not atomic with each other, and N commits where one would do.
2. **Serialize its own data to Turtle and hand it back to the parser.** This is
   the only atomic option available, and it is absurd: the consumer writes out
   terms it is already holding so that the store can parse them back into the
   terms it started with.

A consumer choosing option 2 for correctness is the evidence. Nobody would
choose it otherwise.

**Relationship to STORE-T-0022 (write transactions).** A write transaction
subsumes this — given one, `insert_all` is a loop between a begin and a commit.
This item exists separately because it is a small fraction of the work,
unblocks the common case on its own, and needs none of T-0022's hard decisions
about memstore versioning or read-your-own-writes. **If T-0022 lands first,
this reduces to publishing the convenience form over it and should still be
done**, because "insert these quads" is the operation consumers actually reach
for and it should not require managing a handle.

## Backlog Item Details **[CONDITIONAL: Backlog Item]**

### Type
- [x] Feature - New functionality or enhancement

### Priority
- [x] P1 - High (important for user experience)

The cheapest item on the list by a wide margin, and the one whose absence is
hardest to justify to a reader of the API: the code exists, is tested through
the loaders, and is one visibility keyword away from being usable.

### Business Justification **[CONDITIONAL: Feature]**
- **User Value**: A resource made of a dozen quads is written once, atomically, without a round trip through a serializer and a parser.
- **Business Value**: Removes the most obviously indefensible gap in the write surface. Cheap enough to land independently of the transaction work and useful immediately.
- **Effort Estimate**: S. The batching sequence exists and is exercised by four loaders; this publishes it with a slice source instead of a parser source.

## Acceptance Criteria **[REQUIRED]**

- [ ] `insert_all` in the backend convention: a slice of quads inserted in one unit, returning the number newly added, mirroring `insert`'s `added` and the loaders' `added: int`.
- [ ] Both backends implement it. memstore has no transactions, so there it is a loop — but the *signature* belongs to the convention, and a consumer must not have to write two code paths.
- [ ] **The term-level question decided**: whether it takes `[]store.Encoded_Quad` (already interned, no dictionary work), `[]rdf.Quad` (interned as part of the call), or both. The second is what a consumer holding parsed or constructed terms actually has; the first is what a consumer moving data between datasets has. Record the choice rather than picking the easy one.
- [ ] **Blank-node scoping stated.** `scope_blank` exists because a document's blank labels must map to fresh IDs consistently within one load and not collide across loads. An in-memory batch has the same question. Either `insert_all` carries a scope, or the contract says blank nodes in an `rdf.Quad` batch are pre-resolved and the consumer owns the mapping.
- [ ] Conformance suite, both backends, both `Term_ID` widths: the batch is visible after the call; duplicates within the batch and against existing data are counted as `insert` counts them; and on kvstore, a batch that fails partway leaves nothing (or the contract says otherwise, deliberately).
- [ ] `store/interface.odin` lists it alongside `insert` in the procedure set.

## Implementation Notes **[CONDITIONAL: Technical Task]**

### Technical Approach

kvstore: `load_begin`, loop `scope_insert_triple` (or `insert_txn` for the
already-encoded form), commit — the exact sequence `load_triples` runs, with the
parser loop replaced by a slice loop. The abort-on-error path is already
written and should be reused rather than re-derived.

memstore: a loop over `insert`, plus a single `flush` at the end rather than
per quad if the staging structure makes that meaningful.

The interesting decision is the failure contract. kvstore can offer
all-or-nothing because it has a transaction; memstore cannot without the
journal that STORE-T-0022 would build. Options are to promise the weaker thing
uniformly ("stops at the first error, partial effects possible, the return
value says how far it got"), or to promise all-or-nothing and let memstore's
implementation catch up with T-0022. The first is honest and available now; the
second is better and arrives later. Worth choosing explicitly, and worth
choosing the same way the rest of the write side eventually does.

### Dependencies

None. Subsumed by **STORE-T-0022** if that lands first, in which case this
becomes a convenience wrapper — still worth having.

Consumer: `odin-rdf-app`, whose request handlers construct quads in memory and
have no file to load.

### Risk Considerations

Small, but one worth naming: publishing a batching entry point invites
consumers to pass very large slices, where the loaders' streaming behaviour
made the working set bounded by the parser rather than by the document. A
slice is already materialized by definition, so the consumer has paid that cost
before calling — but the contract should not imply that arbitrarily large
batches are free, particularly on kvstore where one transaction holds pages for
its whole life.

## Status Updates **[REQUIRED]**

- **2026-08-07 — Created from a consumer design review.** The first application-shaped consumer of the family (`odin-rdf-app`) found that writing a handful of quads atomically required serializing them to Turtle so the store would parse them back. Awaiting pickup in an odin-rdf-store session.
