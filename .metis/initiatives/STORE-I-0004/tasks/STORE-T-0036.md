---
id: the-txn-procedure-set-with-the
level: task
title: "The _txn procedure set, with the bare procedures defined as autocommit"
short_code: "STORE-T-0036"
created_at: 2026-08-07T22:14:58.000000+00:00
updated_at: 2026-08-07T22:14:58.000000+00:00
parent: STORE-I-0004
blocked_by: ["STORE-T-0034"]
archived: false

tags:
  - "#task"
  - "#phase/todo"


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

- [ ] Every operation named above has a `_txn` form taking `^Txn` alone, published, with
      contract-level doc comments.
- [ ] **Every bare form survives unchanged in name, signature and semantics** — `insert`,
      `count`, `find_term`, `lookup_term`, `intern_term`, `encode_quad`, `decode_quad`,
      `intern_graph_label`, `find_graph_label` and the third. Nothing an existing consumer
      wrote stops compiling or changes meaning.
- [ ] **The bare forms are reimplemented as autocommit over the `_txn` forms**: open a
      transaction of the appropriate mode, do the one operation, close it. One implementation
      per operation, not two — the duplication is the thing this criterion exists to prevent.
- [ ] The doc comment on each bare form says it is a one-operation transaction, so the
      relationship is readable at the procedure rather than only in `interface.odin`.
- [ ] **A read `_txn` form called on a `.Write` transaction works** — read-your-own-writes is
      the point, and this is where it becomes true for everything except `match`.
- [ ] **A write `_txn` form called on a `.Read` transaction fails cleanly** rather than
      corrupting anything, with a test.
- [ ] `intern_term_txn` inside a transaction that then aborts leaves `Store.next` where it
      was (the invariant STORE-T-0034 installs) — asserted here, where interning is actually
      published on a transaction.
- [ ] **No measurable regression on the load benchmark.** A per-operation transaction is what
      happens today, but routing the bare forms through the `_txn` forms is new indirection.
      Record before/after in the status update; `make bench` at release flags.
- [ ] `make test` green at both `Term_ID` widths; `make check` clean.

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

*To be added during implementation*
