---
id: the-loaders-txn-forms-a-document
level: task
title: "The loaders' _txn forms: a document into a caller's transaction"
short_code: "STORE-T-0038"
created_at: 2026-08-07T22:15:10+00:00
updated_at: 2026-08-07T23:37:34.097272+00:00
parent: STORE-I-0004
blocked_by: [STORE-T-0036]
archived: false

tags:
  - "#task"
  - "#phase/completed"


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

- [x] Sign-off recorded before any code: **in**, 2026-08-07, on the driving consumer's need —
      `odin-rdf-app`'s candidate arrives as a serialized document, and without these the
      validate-before-commit path re-implements the loader at the call site to get the
      transaction it needs.
- [x] All four loaders gain a `_txn` form taking `^Txn` and doing **no transaction management
      of its own**: no commit, no abort.
- [x] **The atomicity story changes and must be documented, not inherited.** A bare `load_*` is
      atomic per document because it owns the transaction and aborts it on a parse error. A
      `load_*_txn` **cannot be** — the transaction is the caller's, and a parse error leaves
      whatever statements parsed before it already written into that transaction. The doc
      comment must say so plainly: **a parse error leaves the transaction dirty, and it is the
      caller's job to abort.** That is the correct division and the opposite of the bare
      loaders' documented divergence, so it is exactly the thing a reader will get wrong. Said
      in the package doc comment, on `load_triples_txn` in full and by reference on the other
      three, and in `store/interface.odin` for the benefit of a second backend copying the
      shape. **And `added` reports what was written rather than 0** — see the status update.
- [x] **The four bare loaders survive unchanged**, including atomic-per-document, and are
      reimplemented over the `_txn` forms — begin, load, commit or abort on the parse error.
- [x] **Blank-node scoping stays per *load*, not per transaction.** Two `load_*_txn` calls in
      one transaction must still mint distinct blank nodes for `_:b0`; the `Load_Scope` already
      does this and it must not quietly change. Tested with two loads of the same document in
      one transaction: the quad count doubles.
- [x] Loading into a write transaction and then reading through the same transaction sees the
      loaded quads (`match_txn` + `count_txn`), and aborting leaves none — the validate-before-
      commit shape, at document granularity.
- [x] `make test` green at both `Term_ID` widths (52 → 56 in `store/kvstore`); `make check`
      clean; `make bench` unchanged, which matters here because the loaders are its subject.

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

- **2026-08-07 — Signed off as in scope, and implemented. All seven criteria met.
  `make test` green at both widths, `store/kvstore` 52 → 56; `make check` clean;
  `make bench` unchanged (N-Triples 319 kstmt/s against 316–342 across the initiative's
  runs), which is the number that matters here because the loaders are what it measures.**

  **One decision the criteria did not anticipate: what `added` returns on a parse error.**
  The bare loader returns 0, and truthfully — it aborted, so nothing was added. A `_txn`
  loader returning 0 would be a lie: the statements before the error *are* in the caller's
  transaction. It returns `scope.added`, the number actually written. That makes the return
  value carry the same warning the doc comment does, and the test asserts the exact count
  (2 of 3 statements) rather than merely that it is non-zero — a test for "not atomic" that
  only checked the happy path would be the one the Risk Considerations warned about.

  **The split was smaller than filed, because STORE-T-0036 had already done half of it.**
  That task converted `load_begin` to return a `Txn` and the whole `scope_*` family to take
  `^Txn`, so the seam was already in the right place. `load_begin` is gone, replaced by
  `load_scope_make`: the transaction now belongs to whoever is calling, and one scope is
  created per `_txn` call, which is exactly what keeps blank-node scoping per load rather
  than per transaction. The bare loaders are four lines each — begin, call, commit or return
  the parse error and let the deferred abort run.

  **The blank-node test is the one worth keeping.** Two loads of one blank-node-dense
  document in a *single* transaction must double the quad count, because each load mints
  fresh blanks — the same property that makes reloading a shapes graph accumulate duplicate
  shapes (STORE-I-0003 Detailed Design point 2). Sharing a transaction is a new way for that
  to be got wrong, so it is asserted alongside the converse: ground statements still dedupe
  across two loads in one transaction, so set semantics is untouched.

  **`store/interface.odin` gained a short note** even though loaders are outside the match
  contract. A second backend copying the `_txn` shape would meet the same inversion, and the
  interface is where it would look.