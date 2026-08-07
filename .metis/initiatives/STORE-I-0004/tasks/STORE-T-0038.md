---
id: the-loaders-txn-forms-a-document
level: task
title: "The loaders' _txn forms: a document into a caller's transaction"
short_code: "STORE-T-0038"
created_at: 2026-08-07T22:15:10.000000+00:00
updated_at: 2026-08-07T22:15:10.000000+00:00
parent: STORE-I-0004
blocked_by: ["STORE-T-0036"]
archived: false

tags:
  - "#task"
  - "#phase/todo"


exit_criteria_met: false
initiative_id: STORE-I-0004
---

# The loaders' _txn forms: a document into a caller's transaction

## Parent Initiative

[[STORE-I-0004]]

## Objective **[REQUIRED]**

**This task exists to be signed off or dropped, and it is the one scoping question the
decomposition raised.** STORE-A-0007 §2 says every operation gains a `_txn` form and §6 lists
what the decision does not settle; `load_*` appears in neither list. It is a real gap, not a
completeness itch:

**`odin-rdf-app`'s candidate arrives as a serialized document.** Validate-before-commit means
building that candidate inside a write transaction. Without `load_turtle_txn`, the consumer
must parse the document itself and insert quad by quad — re-implementing `load_turtle` at the
call site, including its per-load blank-node scoping, purely to get the transaction it needs.
That is the shape of workaround the family's "consume the interface, don't bypass it"
convention exists to prevent.

```odin
load_triples_txn (t: ^Txn, source: []u8, graph := nil, …) -> (added: int, parse_err, err)
load_turtle_txn  (t: ^Txn, source: []u8, base := "", …)   -> (added: int, parse_err, err)
load_quads_txn   (t: ^Txn, source: []u8, …)               -> (added: int, parse_err, err)
load_trig_txn    (t: ^Txn, source: []u8, base := "", …)   -> (added: int, parse_err, err)
```

The machinery exists: `load_begin` already returns a transaction and a `Load_Scope`, and each
public loader is a thin wrapper over it that commits on success and aborts on a parse error.

## Acceptance Criteria **[REQUIRED]**

- [ ] Sign-off recorded before any code: **in scope or out**, with the reason, in the status
      update. Out is a legitimate answer — the task is filed separately precisely so it can be
      dropped without disturbing anything else.
- [ ] All four loaders gain a `_txn` form taking `^Txn` and doing **no transaction management
      of its own**: no commit, no abort.
- [ ] **The atomicity story changes and must be documented, not inherited.** A bare `load_*` is
      atomic per document because it owns the transaction and aborts it on a parse error. A
      `load_*_txn` **cannot be** — the transaction is the caller's, and a parse error leaves
      whatever statements parsed before it already written into that transaction. The doc
      comment must say so plainly: **a parse error leaves the transaction dirty, and it is the
      caller's job to abort.** That is the correct division and the opposite of the bare
      loaders' documented divergence, so it is exactly the thing a reader will get wrong.
- [ ] **The four bare loaders survive unchanged**, including atomic-per-document, and are
      reimplemented over the `_txn` forms — begin, load, commit or abort on the parse error.
- [ ] **Blank-node scoping stays per *load*, not per transaction.** Two `load_*_txn` calls in
      one transaction must still mint distinct blank nodes for `_:b0`; the `Load_Scope` already
      does this and it must not quietly change. Tested with two loads of the same document in
      one transaction: the quad count doubles.
- [ ] Loading into a write transaction and then reading through the same transaction sees the
      loaded quads (`match_txn` + `count_txn`), and aborting leaves none — the validate-before-
      commit shape, at document granularity.
- [ ] `make test` green at both `Term_ID` widths; `make check` clean.

## Implementation Notes **[CONDITIONAL: Technical Task]**

### Technical Approach

Split each public loader at the seam that already exists. Today: `load_begin` → parse loop →
commit/abort. After: the parse loop becomes `load_*_txn(t, …)` and the public loader becomes
begin + call + commit/abort. The `Load_Scope` is created and destroyed per call, which is what
keeps blank-node scoping per load.

### Dependencies

Blocked by STORE-T-0036 (the `_txn` forms the loop calls). Not a blocker for anything —
STORE-T-0039 and T-0040 do not depend on it, which is what makes dropping it cheap.

### Risk Considerations

The dirty-transaction-on-parse-error contract is the risk. A consumer who reads
"atomic per document" on the bare loader and assumes it carries over gets a partially loaded
candidate committed. Mitigation is the doc comment plus a test that asserts the dirty state
explicitly rather than only asserting the happy path — the test is the thing that says this was
a decision.

A second consideration for sign-off: including the loaders slightly widens the public surface
of a release whose whole argument is that it breaks nothing. It is additive, so the argument
holds — but it is four more procedures to keep in step with every future loader change.

## Status Updates **[REQUIRED]**

*To be added during implementation*
