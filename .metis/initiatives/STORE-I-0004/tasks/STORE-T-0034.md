---
id: the-txn-handle-two-modes-single
level: task
title: "The Txn handle: two modes, single-writer refusal, and counter restore-on-abort"
short_code: "STORE-T-0034"
created_at: 2026-08-07T22:14:44.587704+00:00
updated_at: 2026-08-07T22:14:44.587704+00:00
parent: STORE-I-0004
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/todo"


exit_criteria_met: false
initiative_id: STORE-I-0004
---

# The Txn handle: two modes, single-writer refusal, and counter restore-on-abort

## Parent Initiative

[[STORE-I-0004]]

## Objective **[REQUIRED]**

Publish the handle. Everything else in this initiative takes a `^Txn`, so nothing else can
start until this exists.

```odin
Txn_Mode :: enum { Read, Write }

txn_begin  (s: ^Store, mode: Txn_Mode, allocator := context.allocator) -> (Txn, Error)
txn_commit (t: ^Txn) -> Error   // on a Read txn: legal, equivalent to txn_abort
txn_abort  (t: ^Txn)
```

`Txn` is **opaque and named by the convention, never `^lmdb.Txn`** — exposing LMDB's type
would put it into every consumer's source and defeat the interface's separation from its
backend even now that there is only one backend. It is a **caller-held value**, exactly as
`Match_Iterator` is, and it **carries its dataset**: every transactional procedure takes
`^Txn` alone, not `(s, txn)`. The existing private `(s, txn, …)` internals stay internal.

Two behaviours come with the handle rather than after it, because both are about the handle's
own lifecycle: refusing a second write transaction, and keeping the in-memory counter mirror
equal to the persisted one across an abort.

## Acceptance Criteria **[REQUIRED]**

- [ ] `Txn`, `Txn_Mode`, `txn_begin`, `txn_commit`, `txn_abort` published from `store/kvstore`,
      with contract-level doc comments. `txn_commit` on a `.Read` transaction is **legal and
      equivalent to `txn_abort`**, so a consumer that does not branch on mode is not wrong.
- [ ] `Txn` holds `^Store`, the LMDB transaction, the mode, and the `next` snapshot — and
      **`^lmdb.Txn` appears nowhere in a public signature or a public field**.
- [ ] **The copy hazard is documented in the words `Match_Iterator` already uses.** Copying a
      `Txn` yields two handles to one transaction, of which the second commit or abort is a
      use-after-free. Documented, not guarded — the iterator sets the precedent.
- [ ] **A second `txn_begin(.Write)` on one `Store` returns an error rather than blocking.**
      LMDB's writer lock would otherwise self-deadlock a single-threaded consumer, and a
      deadlock is the worst diagnostic available for what is a programming error. A new
      `Store_Error` variant, not an overloaded `Db_Error`, so a consumer can tell a programming
      error from an environment failure.
- [ ] **Across processes, nothing changes**: LMDB's lock serializes writers and blocking is
      correct there — that is the concurrency the deployment shape actually uses. Stated in the
      doc comment so the refusal is not read as a change to it.
- [ ] **`Store.next` is snapshotted at `txn_begin` and restored on `txn_abort`**, with a test.
      The persisted counters in `meta` are written inside the same LMDB transaction and are
      rolled back by it; the in-memory mirror is not, and with aborts published that stops
      being reachable only through a loader hitting a parse error.
- [ ] Transactions do not nest: `txn_begin` takes a `^Store`, and there is no form that takes a
      `^Txn`. Forbidden by construction rather than checked.
- [ ] `make test` green at both `Term_ID` widths; `make check` clean.

## Implementation Notes **[CONDITIONAL: Technical Task]**

### Technical Approach

`txn_begin` is `lmdb.txn_begin(s.env, nil, mode == .Read ? lmdb.RDONLY : 0, &raw)` plus
bookkeeping. `Store` gains a flag for "a write transaction is open"; `txn_commit` and
`txn_abort` clear it. The `next` snapshot is a `[4]u64` copy — the array is four words, so
this is not worth being clever about.

Note that `open_databases` already runs exactly this pattern by hand (begin, do work, commit,
abort-on-defer) and is a good shape to read before writing the public one.

### Dependencies

Blocks STORE-T-0035, T-0036, T-0037, T-0038, T-0039. Depends on nothing.

### Risk Considerations

The `next` restore has **no observable effect today** through the quad contract — the reverse
lookup is a key lookup, not an array index, so a drifted counter is an unused gap in the ID
space rather than a wrong answer. That is exactly why it needs its own test written now: an
invariant with no observable consequence is one nobody notices breaking, and STORE-T-0021
(sentinel reservation) is the item that would eventually depend on it.

The `.Read` / `.Write` distinction is checked at runtime rather than in the type. Attempting
`insert_txn` on a read transaction must fail cleanly with LMDB's own error rather than
corrupt anything — worth an explicit test rather than an assumption.

## Status Updates **[REQUIRED]**

*To be added during implementation*
