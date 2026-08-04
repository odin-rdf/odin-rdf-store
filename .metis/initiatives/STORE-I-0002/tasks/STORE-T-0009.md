---
id: persistent-dictionary-canonical
level: task
title: "Persistent dictionary: canonical term codec, term2id/id2term, counters"
short_code: "STORE-T-0009"
created_at: 2026-08-04T21:11:30.903221+00:00
updated_at: 2026-08-04T21:11:30.903221+00:00
parent: STORE-I-0002
blocked_by: ["STORE-T-0007"]
archived: false

tags:
  - "#task"
  - "#phase/todo"


exit_criteria_met: false
initiative_id: STORE-I-0002
---

# Persistent dictionary: canonical term codec, term2id/id2term, counters

## Parent Initiative **[CONDITIONAL: Assigned Task]**

[[STORE-I-0002]]

## Objective **[REQUIRED]**

Implement the persistent dictionary per STORE-A-0003 §§2–4: the canonical term byte codec, hashed `term2id` keys with verified lookups, `id2term` entries, and per-kind counters that keep dense ID assignment stable across reopens. After this task, terms intern to stable IDs in a database file and decode back — the LMDB half of what `store/dictionary.odin` does in memory.

## Acceptance Criteria **[REQUIRED]**

- [ ] Canonical term codec encodes/decodes all four kinds exactly per STORE-A-0003 §2: IRI/blank raw bytes; literal `[datatype ID: BE][direction: 1B][lang len: 1B][lang][lexical to end]` with >255-byte language tags rejected at intern time; triple term = three BE component IDs. Round-trip unit tests per kind, including recursive triple terms and literal edge cases (xsd:string vs langString vs dirLangString, same lexical different datatype).
- [ ] `term2id` keys are `[kind: 1B][XXH3-128(canonical bytes, seed 0): 16B]`; every key hit is verified by reading `id2term` and byte-comparing; a mismatch on lookup is treated as not-found and a true collision on insert fails with the ADR's distinct error — the collision path is pinned by a test that plants a colliding entry directly through the binding.
- [ ] Interning assigns dense per-kind counters from the `meta` values (in-memory mirror, persisted in the write txn); intern-twice returns the same ID within a session **and across close/reopen** (reopen-stability test: intern, reopen, intern same terms → identical IDs; new terms continue the counter, no reuse).
- [ ] Blank-node support for load scoping: a `fresh_blank` equivalent generating collision-checked labels against the persistent dictionary.
- [ ] Read paths are txn-parametric private procedures (initiative decision 3's implementation consequence); the public lookup procs open their own txn and copy results into a caller-supplied allocator — documented, with a test proving returned terms outlive the txn.
- [ ] All tests green at both Term_ID widths.

## Implementation Notes **[CONDITIONAL: Technical Task]**

### Technical Approach
Interning a literal interns its datatype IRI first (the canonical bytes need its ID) — same ordering the in-memory dictionary exhibits. Encode into a reusable scratch buffer; the canonical bytes are both the hash input and the `id2term` value, built once per intern. Counters commit in the same write txn as the entries they cover — a crash between the two must be impossible by construction.

### Dependencies
STORE-T-0007 (environment + meta). Governed by STORE-A-0003 §§2–4.

### Risk Considerations
The verification read makes every probe two gets — correct first; STORE-T-0012's benchmark prices it (a probe cache is a recorded non-format optimization). Byte-level format bugs are invisible to same-build round-trips — add at least one test asserting exact expected key/value bytes for known terms, so the ADR's layout is pinned literally, not just behaviorally.

## Status Updates **[REQUIRED]**

*To be added during implementation*