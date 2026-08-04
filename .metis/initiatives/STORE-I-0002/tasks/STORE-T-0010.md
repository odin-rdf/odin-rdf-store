---
id: index-dbs-and-cursor-backed-match
level: task
title: "Index DBs and cursor-backed match; conformance suite green over LMDB"
short_code: "STORE-T-0010"
created_at: 2026-08-04T21:11:34.577301+00:00
updated_at: 2026-08-04T21:11:34.577301+00:00
parent: STORE-I-0002
blocked_by: ["STORE-T-0008", "STORE-T-0009"]
archived: false

tags:
  - "#task"
  - "#phase/todo"


exit_criteria_met: false
initiative_id: STORE-I-0002
---

# Index DBs and cursor-backed match; conformance suite green over LMDB

## Parent Initiative **[CONDITIONAL: Assigned Task]**

[[STORE-I-0002]]

## Objective **[REQUIRED]**

Implement the three index DBs and cursor-backed match, completing the LMDB backend's implementation of the match interface — and prove it by running the shared conformance harness verbatim. This is the initiative's headline milestone: the same suite that defines the in-memory backend green over a database file.

## Acceptance Criteria **[REQUIRED]**

- [ ] Big-endian composite key codec for `gspo`/`gpos`/`gosp` per STORE-A-0003 §5 (4×ID keys in permutation order, empty values), with at least one exact-bytes test pinning the layout.
- [ ] `insert` performs the whole update in one write txn: `NOOVERWRITE` put on `gspo` decides set membership (KEYEXIST → false, nothing else written); the other two indexes updated only on a fresh quad; sentinel/WILDCARD asserts as in the in-memory backend.
- [ ] `count` reads `ms_entries` from `stat` on `gspo` — O(1), consistent with insert results.
- [ ] `match` reuses the longest-bound-prefix dispatch: a read txn + cursor owned by the iterator, positioned with `SET_RANGE` on the big-endian bound prefix; iteration ends when the key leaves the prefix; residual positions filtered; wildcard-graph patterns full-scan `gspo` (the documented trade-off).
- [ ] `match_next` yields encoded quads decoded from cursor key bytes with no per-result allocation; exhausted iterators stay exhausted; `match_destroy` closes cursor and txn (leak-checked by tests where observable).
- [ ] All internal read paths are txn-parametric (initiative decision 3); public procs are thin txn-owning wrappers.
- [ ] The STORE-T-0008 conformance harness instantiated for the LMDB backend passes completely at both Term_ID widths — no harness modifications permitted.

## Implementation Notes **[CONDITIONAL: Technical Task]**

### Technical Approach
The dispatch logic (longest leading run of bound positions) is identical to the in-memory backend's `match`; only the range mechanics differ (SET_RANGE + prefix check instead of binary search on arrays). Iterator struct holds `^Txn`, `^Cursor`, the pattern, and the prefix length. Read txns use `RDONLY`; with NOTLS set at env open, iterator handles can move between threads if a caller ever needs it (no API commitment yet).

### Dependencies
STORE-T-0008 (harness) and STORE-T-0009 (dictionary — the harness fixtures intern through it). Governed by STORE-A-0003 §5 and STORE-A-0002.

### Risk Considerations
Cursor/txn leaks on early iterator abandonment — the contract requires `match_destroy`, and the harness's exhaustion tests plus LMDB's reader-table (`max_readers`) will surface leaks quickly in tests that loop. Off-by-one at prefix boundaries (last key of a range) deserves targeted tests beyond the harness's coverage.

## Status Updates **[REQUIRED]**

*To be added during implementation*