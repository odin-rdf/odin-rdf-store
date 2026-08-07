---
id: the-txn-handle-two-modes-single
level: task
title: "The Txn handle: two modes, single-writer refusal, and counter restore-on-abort"
short_code: "STORE-T-0034"
created_at: 2026-08-07T22:14:44.587704+00:00
updated_at: 2026-08-07T23:16:56.422194+00:00
parent: STORE-I-0004
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/completed"


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

- [x] `Txn`, `Txn_Mode`, `txn_begin`, `txn_commit`, `txn_abort` published from `store/kvstore`,
      with contract-level doc comments. `txn_commit` on a `.Read` transaction is **legal and
      equivalent to `txn_abort`** — verified in LMDB's source, where `_mdb_txn_commit` on an
      `MDB_TXN_RDONLY` transaction goes straight to `done` and ends it — so a consumer that does
      not branch on mode is not wrong.
- [x] `Txn` holds `^Store`, the LMDB transaction and the mode. **Two amendments here**, both in
      the status update: the `next` snapshot moved to the `Store`, and "`^lmdb.Txn` appears
      nowhere in a **public field**" is dropped as unachievable and, on inspection, not what
      STORE-A-0007 asks for. Odin has no per-field visibility, and `Store.env` / `Store.dbi` /
      `Match_Iterator.txn` already expose LMDB types the same way. The property the ADR names —
      *"whose exposure would put LMDB's types into every consumer's source"* — is about the type
      a consumer has to **name**, and that holds: `txn_begin` returns `Txn`, so no consumer
      writes `lmdb` anywhere.
- [x] **The copy hazard is documented in the words `Match_Iterator` already uses.** Documented,
      not guarded. Commit and abort additionally zero the handle, so a second commit or abort of
      the *same* handle is a no-op rather than a double free — `match_destroy`'s `it^ = {}`
      precedent — but nothing saves a copy, and the doc comment says so.
- [x] **A second `txn_begin(.Write)` on one `Store` returns `.Write_Txn_Open` rather than
      blocking**, a `Store_Error` rather than an overloaded `Db_Error`. **And it covers more
      than a second `txn_begin`** — see the status update: bare `insert` and all four loaders
      open write transactions of their own and would have deadlocked against a held `Txn`, so
      the refusal would have had a hole exactly where a confused consumer falls in.
- [x] **Across processes, nothing changes**: LMDB's lock serializes writers between processes
      and blocking is correct there. Stated in `txn_begin`'s doc comment so the refusal is not
      read as a change to it.
- [x] **`next` is snapshotted when a write transaction begins and restored when it aborts**,
      with tests — for `txn_abort`, for a *failed commit* (which LMDB has already turned into an
      abort before returning), and for the loader-parse-error path that was the one place the
      drift was reachable before. A fourth test asserts a committed transaction **keeps** what it
      interned, which is the half a too-eager restore would break. All four also assert the
      mirror equals the counters read back out of `meta`, which is the invariant rather than a
      proxy for it.
- [x] Transactions do not nest: `txn_begin` takes a `^Store` and there is no form that takes a
      `^Txn`. Forbidden by construction rather than checked.
- [x] `make test` green at both `Term_ID` widths (37 → 46 in `store/kvstore`); `make check`
      clean; `make bench` unchanged within run-to-run noise.

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

- **2026-08-07 — Implemented. All eight acceptance criteria met, two of them amended.
  `make test` green at both `Term_ID` widths, `make check` clean, `make bench` unchanged.
  `store/kvstore` 37 → 46 tests.**

  **The finding: the refusal would have had a hole, and it was in the obvious place.** The
  criterion as written guards a second `txn_begin(.Write)`. But bare `insert` and all four
  loaders open write transactions of their own — that is what autocommit *is* — so a consumer
  holding a `Txn` and then calling `insert` would have opened a second LMDB write transaction
  on the same environment and **self-deadlocked**, which is precisely the outcome the refusal
  exists to prevent, arrived at by the route a confused consumer is most likely to take.

  So the claim is not a field on `Txn`. Every path that opens a write transaction now goes
  through one private trio — `write_txn_begin` / `write_txn_commit` / `write_txn_abort` — and
  `txn_begin(.Write)`, `insert` and `load_begin` all call it. A held `Txn` therefore makes
  `insert` and the loaders return `.Write_Txn_Open` rather than hang, which is asserted.
  `open_databases` is the one write transaction that stays outside the trio, and does not need
  it: it runs inside `open` before the `Store` has been handed to anyone.

  **Amendment 1: the `next` snapshot lives on the `Store`, not on the `Txn`.** STORE-A-0007
  point 4 says "`Txn` snapshots `next` at begin and restores it on abort", and this task
  repeated it. Routing the autocommit paths through the same claim made that impossible and
  better at once: `insert` and the loaders have no `Txn` to hang a snapshot on, and **the
  loader-abort path is the one place the ADR itself says the drift is reachable today**. Fixing
  it only for `Txn` aborts would have left the invariant not an invariant. Because at most one
  write transaction is open at a time, one saved copy on the `Store` is exactly the right number
  — `write_next`, taken in `write_txn_begin` and restored in `write_txn_abort`. `Txn` is smaller
  for it: `^Store`, the LMDB transaction, and the mode.

  A case the ADR does not mention and the code now handles: **a failed commit is an abort.**
  `_mdb_txn_commit` calls `_mdb_txn_abort` on its failure path before returning the error, so
  the persisted counters roll back and the mirror has to as well. `write_txn_commit` restores on
  a non-`SUCCESS` return, and the handle is spent either way.

  **Amendment 2: `txn_begin` has no allocator parameter**, where STORE-A-0007 wrote
  `txn_begin(s, mode, allocator := context.allocator)`. A `Txn` owns no memory, and the
  precedent for a caller-held value that owns none is `match`, which takes no allocator either —
  while `open`, `close` and `lookup_term`, which all genuinely allocate, do. An unused parameter
  now cannot be removed later without breaking callers; adding one later with a default breaks
  nobody. Flagged rather than taken silently, since it is an ADR signature.

  **Also amendment 2's smaller sibling**: "`^lmdb.Txn` appears nowhere in a public field" was
  my wording, not the ADR's, and it is unachievable — Odin has no per-field visibility — and
  inconsistent with `Store.env`, `Store.dbi` and `Match_Iterator.txn`, which have exposed LMDB
  types since STORE-I-0002. What the ADR actually asks for is that LMDB's types not land "in
  every consumer's source", and that holds: a consumer names `kvstore.Txn` and never `lmdb`
  anything. The doc comment says which of the two properties the struct has and why.

  **What the tests reach through, and why it is temporary.** The `_txn` operations are not
  published yet — that is STORE-T-0036 and T-0037 — so `txn_test.odin` calls the private
  `insert_txn(s, txn, q)` and `intern_term_txn(s, txn, term)` through the handle's fields. Ugly
  on purpose and noted in the file: once those take a `^Txn`, the tests become `insert_txn(&t, q)`
  and stop looking through it.

  **One test asserts the invariant rather than a proxy for it.** The counter-mirror tests read
  the per-kind counters back out of `meta` through a fresh read transaction and compare, rather
  than trusting `Store.next` against itself. The point of the invariant is that the two agree,
  so a test that only inspects one of them would pass against the bug.