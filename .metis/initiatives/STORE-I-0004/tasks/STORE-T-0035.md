---
id: the-transaction-model-in-store
level: task
title: "The transaction model in store/interface.odin: guarantees, and the two costs as contract"
short_code: "STORE-T-0035"
created_at: 2026-08-07T22:14:52.000000+00:00
updated_at: 2026-08-07T22:14:52.000000+00:00
parent: STORE-I-0004
blocked_by: ["STORE-T-0034"]
archived: false

tags:
  - "#task"
  - "#phase/todo"


exit_criteria_met: false
initiative_id: STORE-I-0004
---

# The transaction model in store/interface.odin: guarantees, and the two costs as contract

## Parent Initiative

[[STORE-I-0004]]

## Objective **[REQUIRED]**

Write the contract, in the package that *is* the contract. `store/interface.odin` currently
documents the match interface's procedure-set convention and says lifecycle is deliberately
outside it. The transaction model is not lifecycle — it is semantics, and it belongs there.

This is the task that turns a kvstore feature into an interface. It comes **before** the
conformance suite (STORE-T-0039) on purpose: the suite should assert the contract, not
describe the implementation.

STORE-A-0007 point 3 has the text nearly written. This is transcription with judgement, not
authorship.

## Acceptance Criteria **[REQUIRED]**

- [ ] **The guarantees, stated flat with nothing conditional** — no capability constant, no
      tier, no "backends may differ":
  - **Read-your-own-writes** — a read through an open transaction observes that transaction's
    own uncommitted writes.
  - **Snapshot isolation** — a read transaction is a stable view; concurrent commits do not
    disturb it, and a reader outside an open write transaction sees the pre-commit dataset.
  - **Atomicity over quads** — after commit every quad the transaction wrote is visible; after
    abort none is.
  - **Single writer, no nesting** — at most one write transaction per `Store`; a second is
    refused rather than blocked; transactions do not nest.
- [ ] **Provisional `Term_ID`s**, with the deliberate gap named as deliberate: IDs assigned by
      interning inside a transaction are valid only if it commits, and on abort the consumer
      discards them. **Whether the *term* stays interned after an abort is unspecified** —
      atomicity is defined over quads, not over the dictionary. A term interned but never used
      by a committed quad is invisible through the quad contract: `find_term` may report it and
      matching it yields nothing, which is the right answer either way. This keeps
      STORE-I-0001 decision 5's monotonic dictionary intact.
- [ ] **Iterator invalidation, extending today's rule rather than replacing it.** An iterator
      is valid until `match_destroy`, a **write through that same transaction**, or that
      transaction's commit/abort — whichever comes first. Writing through a transaction
      invalidates every iterator open on it. The combination is **forbidden explicitly rather
      than defined**, which keeps the cheapest correct implementation available and avoids
      specifying LMDB's cursor-fixup behaviour as contract for a combination no consumer has
      asked for.
- [ ] **What a consumer that never opens a transaction may assume**, stated positively. The
      bare procedures are **defined as autocommit** — a transaction of the appropriate mode,
      one operation, closed — rather than merely implemented that way. Nothing written against
      today's API stops compiling or changes meaning.
- [ ] **The two costs, in the interface and not in a kvstore note.** STORE-A-0006 made the
      match interface's semantics LMDB's semantics by definition, and this is the first place
      that bites:
  - An **open read transaction pins pages**, so a long-held snapshot makes a concurrent writer
    grow the file. A consumer holding a snapshot for the life of a query is fine; one holding
    it for the life of a request handler is making a storage-sizing decision.
  - An **open write transaction holds the environment's writer lock** and serializes every
    other writer against that environment for its lifetime. **The validate-before-commit
    consumer holds one across an entire SHACL validation by construction** — read-your-own-writes
    is the whole point — so those transactions are long by design. Across ~200 processes per
    machine this serializes *within* an environment, not between them.
- [ ] **The `_txn` suffix is explained once, plainly**: it marks what becomes the primary API
      because the alternative renames every procedure odin-rdf-sparql and odin-rdf-shacl
      already call. Additive and ugly beats elegant and breaking.
- [ ] The existing note on why lifecycle sits outside the procedure-set convention is
      reconciled with a transaction model that is *inside* it — the distinction being that
      opening a *store* is a backend's own nature, while what a read sees is the contract.
- [ ] `make check` clean.

## Implementation Notes **[CONDITIONAL: Technical Task]**

### Technical Approach

Prose in `store/interface.odin`. No code beyond whatever vocabulary the `store` package needs
to name the model (`Txn_Mode` may belong here rather than in kvstore — worth deciding rather
than defaulting, since it is the one piece of the model that is backend-independent).

### Dependencies

Blocked by STORE-T-0034 — the handle's shape must be real before the contract describes it.
Blocks STORE-T-0039, which asserts what this states.

### Risk Considerations

The failure mode here is writing a description of kvstore instead of a contract. The test is
whether a second backend could be held to every sentence. STORE-A-0007 accepted a higher bar
for a hypothetical backend in exchange for an unconditional contract for the real one — that
trade is already taken, and the text should read as if it were always true rather than as if
LMDB happens to do it.

STORE-A-0002 needs **no amendment**: a whole transaction model extends the procedure set
without disturbing the convention, exactly as its Consequences anticipated ("the expected
interface revision … will extend the procedure set; the conformance suite grows with it"). Do
not amend it. Its one 2026-08-07 amendment came from STORE-A-0006, and the archived
STORE-A-0005's capability-tier amendment is void.

## Status Updates **[REQUIRED]**

*To be added during implementation*
