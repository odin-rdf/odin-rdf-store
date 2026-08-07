---
id: remove-logical-deletion-specified
level: task
title: "remove: logical deletion, specified as visibility"
short_code: "STORE-T-0023"
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

# remove: logical deletion, specified as visibility

## Objective **[REQUIRED]**

Make the dataset editable. `store/interface.odin` already contains this item's
specification, written at the point where it was deferred:

> `remove` does not exist in v1 (append-only; STORE-I-0001 decision 5). When
> added it will be specified as logical visibility: after remove returns, the
> quad is absent from subsequent matches and counts — with no promise of
> physical erasure, so tombstone-based backends conform.

This is that revision. The deferral was a sequencing decision for a backend
under construction, and v0.1.0 has shipped.

**Evidence — an append-only store is write-once, and most applications are
not.** This is not a performance gap or an ergonomics gap: the operation
cannot be expressed at all, so the consumer cannot approximate it.

1. **Anything that edits.** An interactive shell that loads a graph and lets a
   user change it; a CLI that rewrites or normalizes a file; a service
   handling update and delete. Each has "change this" as its primary verb and
   the interface has no word for it.
2. **Replacing a resource's description**, which is what an update actually
   is: remove every quad about a subject, insert the new ones. With
   STORE-T-0022 (write transactions) the two compose into one atomic
   operation, which is the shape an update needs. Without `remove`, the pair
   is unavailable no matter what transactions exist.
3. **Recovering from a rejected write.** Until STORE-T-0022 lands,
   commit-then-validate is the only ordering available, and it is currently
   irreversible — a write that fails validation stays. `remove` makes that
   ordering merely awkward instead of unusable, so this item has value
   *before* transactions arrive as well as after.

**The alternative was considered and is worse for the general case.**
Append-only datasets can model change with named graphs and a current-version
pointer, and for an audit-shaped application that is a legitimate design. As
the *only* option it forces every consumer into two-step reads and makes every
SHACL validation a graph-scoping problem. The family's stated goal is that
applications use it simply; a store where deletion is a modelling exercise is
not that.

## Backlog Item Details **[CONDITIONAL: Backlog Item]**

### Type
- [x] Feature - New functionality or enhancement

### Priority
- [x] P0 - Critical (blocks a class of consumer)

Half of CRUD. Every editing application is blocked on it, and unlike the other
gaps on this list there is no workaround to be ugly about.

### Business Justification **[CONDITIONAL: Feature]**
- **User Value**: Data can be corrected, replaced, and deleted. Applications stop having to choose between an append-only data model and this store.
- **Business Value**: With STORE-T-0022, completes the write side of the interface — the point at which the store serves editing consumers and not only loading-and-querying ones.
- **Effort Estimate**: S for memstore (delete from three sorted permutation indexes). S–M for kvstore (`mdb_del` across the three index databases; the dictionary deliberately keeps its entries — see below). M for the contract and the conformance suite, chiefly because of the iterator-invalidation question.

## Acceptance Criteria **[REQUIRED]**

- [ ] `remove` in the backend convention, semantics as `interface.odin` already specifies them: after it returns, the quad is absent from subsequent matches and counts, with no promise of physical erasure.
- [ ] Return value says whether anything was removed, mirroring `insert`'s `added: bool`.
- [ ] **The pattern question decided and recorded**: whether `remove` takes a single quad, a `Match_Pattern`, or both. See Technical Approach — the answer is entangled with iterator invalidation and should not be settled by implementing the easy one.
- [ ] **Iterator interaction specified.** Today an iterator is valid only until its dataset is mutated, which makes the obvious "match, then delete what you found" loop undefined behaviour. Either `remove` accepts a pattern so the loop is unnecessary, or the contract states what an in-flight iterator observes across a removal. This must not be left implicit.
- [ ] The term dictionary's behaviour stated: removing the last quad mentioning a term does **not** retract its `Term_ID`. IDs are dense and permanent (STORE-A-0001); reclaiming them would invalidate every ID a consumer holds. Say so, rather than leaving a reader to infer it.
- [ ] Conformance suite, both backends, both `Term_ID` widths: remove-then-match, remove-then-count, removing an absent quad, remove and re-insert, and the set semantics that follow.
- [ ] `STORE-A-0002` amended or superseded to record that v1's append-only stance is replaced, with the reason and the consumer.

## Implementation Notes **[CONDITIONAL: Technical Task]**

### Technical Approach

**The pattern-versus-quad question is the design.** Applications overwhelmingly
want *"delete everything about this subject"* — deleting a resource means
removing every quad with it in the subject position, and the count is not known
in advance. Quad-at-a-time forces the consumer into: match, **materialize the
results into a buffer** (because the iterator dies the moment the dataset is
mutated), then remove each. That is a correct-but-trap-laden dance, and the
trap is exactly the kind that works in testing and fails on a large resource.

A pattern-taking `remove` avoids it entirely and matches how the read side
already thinks. The cost is that it is a bulk operation with an unbounded
working set inside the backend, which for kvstore means a cursor walk deleting
as it goes — natural for LMDB, and precisely the operation the consumer would
otherwise be doing badly on the outside.

**memstore**: deletion from three sorted arrays. Note the existing `flush` /
`merge_into` staging structure — removal has to account for pending inserts not
yet merged, or run after a flush.

**kvstore**: `mdb_del` on gspo, gpos, gosp. The `NOOVERWRITE` put on gspo is
what currently decides set membership; removal must keep that invariant true.

### Dependencies

Composes with **STORE-T-0022** (write transactions) — an update is a remove and
an insert in one unit — but does not depend on it and delivers value alone.

Consumers: `odin-rdf-app` (update and delete endpoints), and any interactive or
file-rewriting CLI.

### Risk Considerations

Removal invalidates the assumption that made several things simple: an
append-only dataset never shrinks, so an iterator's position stays meaningful
and a cached count stays true. The conformance suite should hunt specifically
for places that quietly rely on growth-only, rather than only testing that
removal works.

Tombstone-based backends were explicitly kept conformant by the visibility
wording. Preserve that when writing the tests — asserting physical erasure
anywhere would silently narrow the contract to what these two backends happen
to do.

## Status Updates **[REQUIRED]**

- **2026-08-07 — Created from a consumer design review.** The first application-shaped consumer of the family (`odin-rdf-app`) reached the update and delete half of its write path and found no operation to build them on. The specification was already written in `interface.odin`; this item is to implement it. Awaiting pickup in an odin-rdf-store session.
- **2026-08-07 — memstore retired (STORE-A-0006, STORE-I-0003).** The Effort Estimate's
  S-for-memstore half is void; kvstore's S–M (`mdb_del` across the three index databases,
  dictionary entries deliberately kept) is the whole of it, and so is the M for the contract
  and the conformance suite, still driven by the iterator-invalidation question. The
  Implementation Notes' memstore paragraph — deletion from three sorted arrays, and the
  `flush` / pending-buffer interaction — describes a package that no longer exists and is
  left only as the record of how the design was reasoned about.
