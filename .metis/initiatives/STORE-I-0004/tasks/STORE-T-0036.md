---
id: the-txn-procedure-set-with-the
level: task
title: "The _txn procedure set, with the bare procedures defined as autocommit"
short_code: "STORE-T-0036"
created_at: 2026-08-07T22:14:58+00:00
updated_at: 2026-08-07T23:29:06.213338+00:00
parent: STORE-I-0004
blocked_by: [STORE-T-0034]
archived: false

tags:
  - "#task"
  - "#phase/completed"


exit_criteria_met: false
initiative_id: STORE-I-0004
---

# The _txn procedure set, with the bare procedures defined as autocommit

## Parent Initiative

[[STORE-I-0004]]

## Objective **[REQUIRED]**

Give every operation except `match` a `_txn` form taking `^Txn`, and reimplement the bare
forms on top of them so there is exactly one implementation of each operation.

This is the bulk of the surface and the least of the design. Most of it exists already behind
`@(private)` in the `(s, txn, …)` shape and needs re-signing to `(^Txn, …)`.

```odin
insert_txn       (t: ^Txn, q: store.Encoded_Quad)  -> (added: bool, err: Error)
count_txn        (t: ^Txn)                         -> (n: int, err: Error)
find_term_txn    (t: ^Txn, term: rdf.Term)         -> (id: store.Term_ID, found: bool, err: Error)
lookup_term_txn  (t: ^Txn, id, allocator)          -> (term: rdf.Term, err: Error)
intern_term_txn  (t: ^Txn, term: rdf.Term)         -> (id: store.Term_ID, err: Error)
encode_quad_txn  (t: ^Txn, q: rdf.Quad)            -> (store.Encoded_Quad, Error)
decode_quad_txn  (t: ^Txn, q, allocator)           -> (rdf.Quad, Error)
// and the three graph-label procedures
```

`match_txn` is deliberately **not** here — it is STORE-T-0037, because its iterator owns the
transaction it opened and that is the one piece with real design in it.

## Acceptance Criteria **[REQUIRED]**

- [x] Every operation named above has a `_txn` form taking `^Txn` alone, published, with
      contract-level doc comments.
- [x] **Every bare form survives unchanged in name, signature and semantics** — `insert`,
      `count`, `find_term`, `lookup_term`, `intern_term`, `encode_quad`, `decode_quad`,
      `intern_graph_label`, `find_graph_label` and the third. Nothing an existing consumer
      wrote stops compiling or changes meaning. **Two procedures that are not bare forms do
      break, and they are the two that already published `^lmdb.Txn`** — see the status update.
- [x] **The bare forms are reimplemented as autocommit over the `_txn` forms**: open a
      transaction of the appropriate mode, do the one operation, close it. One implementation
      per operation, not two — the duplication is the thing this criterion exists to prevent.
- [x] The doc comment on each bare form says it is a one-operation transaction, so the
      relationship is readable at the procedure rather than only in `interface.odin`.
- [x] **A read `_txn` form called on a `.Write` transaction works** — read-your-own-writes is
      the point, and this is where it becomes true for everything except `match`.
- [x] **A write `_txn` form called on a `.Read` transaction fails cleanly** rather than
      corrupting anything, with a test.
- [x] `intern_term_txn` inside a transaction that then aborts leaves `Store.next` where it
      was (the invariant STORE-T-0034 installs) — asserted here, where interning is actually
      published on a transaction.
- [x] **No measurable regression on the load benchmark.** A per-operation transaction is what
      happens today, but routing the bare forms through the `_txn` forms is new indirection.
      Record before/after in the status update; `make bench` at release flags.
- [x] `make test` green at both `Term_ID` widths; `make check` clean.

## Implementation Notes **[CONDITIONAL: Technical Task]**

### Technical Approach

`insert_txn`, `intern_term_txn`, `find_term_txn`, `lookup_term_txn` and `encode_quad_txn`
already exist as `@(private)` procedures taking `(s: ^Store, txn: ^lmdb.Txn, …)`. The change
is mechanical: take `^Txn`, read `t.s` and `t.txn` from it, drop `@(private)`, write the doc
comment. `find_term_txn` (STORE-T-0014) proved the threading pattern out for a single
procedure and is the shape to follow.

The autocommit wrappers are three lines each — begin, call, commit-or-abort — and are worth
writing as a visibly uniform block so a reader can see there is no special case hiding in one
of them.

### Dependencies

Blocked by STORE-T-0034. Parallel with STORE-T-0037 (`match_txn`) and STORE-T-0035 (the
contract). Blocks STORE-T-0039.

### Risk Considerations

The main risk is a silent semantic change in a bare form while re-plumbing it — the criterion
"unchanged in name, signature and semantics" is the one to hold hard, and the existing suite
is the check. A coverage change hidden inside a mechanical change is the failure mode
STORE-I-0003's test-port task named, and it applies verbatim here.

Watch `lookup_term`/`decode_quad`'s allocator parameter through the wrapper: they copy out of
mapped pages into the caller's allocator, and the temporary transaction must outlive the copy.

## Status Updates **[REQUIRED]**

- **2026-08-07 — Implemented. All nine criteria met, one with a stated exception.
  `make test` green at both widths (46 → 52 in `store/kvstore`, with T-0037 landing
  alongside), `make check` clean, `make bench` unchanged within run-to-run noise
  (N-Triples 316 vs 324 kstmt/s across runs; full scan 90–95 Mquad/s).**

  **The finding: "every existing form survives unchanged" has exactly two exceptions, and they
  are the two procedures that already had `^lmdb.Txn` in a *public* signature.**
  `intern_term_txn` and `find_term_txn` were not private — `find_term_txn` shipped that way in
  STORE-T-0014 — so their old signatures published LMDB's type to any consumer, which is
  precisely what STORE-A-0007 forbids. Keeping them unchanged would have made that permanent,
  so both are re-signed to take `^Txn`. **This is a breaking change to two published symbols**
  and belongs in the CHANGELOG (noted for STORE-T-0040), even though its practical reach is
  nil: a grep across odin-rdf-sparql, odin-rdf-shacl, this repo outside `store/kvstore`, and
  every README and CHANGELOG in the family finds no use of either. They were public by
  omission rather than by design.

  **The internals were converted wholesale rather than wrapped.** The alternative was keeping
  the private `(s, txn, …)` helpers and making the published `_txn` forms thin adapters over
  them, which is less churn and leaves two conventions inside one package. Everything —
  `probe_canonical`, `intern_canonical`, `id2term_get`, `fresh_blank_txn`,
  `intern_triple_ids_txn`, and the loaders' `scope_*` family — now takes `^Txn`. That is one
  convention, and it hands STORE-T-0038 a `load_begin` that already returns a `Txn`.

  **A simplification fell out of T-0034's handle-zeroing.** Every write path used to carry a
  `committed := false` flag with a conditional deferred abort. Since `txn_commit` zeroes the
  handle and aborting a zeroed handle is a no-op, `defer txn_abort(&tx)` alone is now correct
  on every path — success, parse error, and failed commit. The flag is gone from all four
  loaders, `insert`, `intern_term`, `intern_graph_label` and `encode_quad`.

  **New beyond the task's list**, because the trio should be complete rather than
  two-thirds-complete: `find_graph_label_txn`, `lookup_graph_label_txn` and `count_txn`.
  `decode_quad_txn` also removed a duplicate: `decode_quad` had an inline switch for the graph
  position that `lookup_graph_label` already implemented, and it now calls
  `lookup_graph_label_txn` instead.

  **The allocator risk the task named did not materialize, but is worth recording as checked.**
  `lookup_term` and `decode_quad` copy out of mapped pages into the caller's allocator, and the
  temporary transaction must outlive the copy. It does: the copy happens inside the `_txn`
  call, and the wrapper's `defer txn_abort` runs after it returns. The returned term owns
  nothing of the store, which the existing `test_dict_lookup_outlives_store` still asserts.

  Two existing tests that reached LMDB directly to get a transaction — the `find_term_txn`
  read-your-own-writes test and the `fresh_blank_txn` test — now use `txn_begin`, which is what
  they always wanted. `txn_test.odin`'s header note about reaching through the handle is
  retired: it no longer does.