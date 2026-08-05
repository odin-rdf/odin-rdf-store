---
id: find-term-non-interning-term
level: task
title: "find_term: non-interning term lookup, plus UNBOUND sentinel reservation"
short_code: "STORE-T-0014"
created_at: 2026-08-05T15:13:48.581611+00:00
updated_at: 2026-08-05T15:24:18.098870+00:00
parent: 
blocked_by: []
archived: false

tags:
  - "#task"
  - "#feature"
  - "#phase/completed"


exit_criteria_met: false
initiative_id: NULL
---

# find_term: non-interning term lookup, plus UNBOUND sentinel reservation

## Objective **[REQUIRED]**

Give downstream engines a **read-only term → ID lookup** in both backends, and **reserve a third Sentinel ID for UNBOUND**. This is the first evidence-backed interface request from odin-rdf-sparql (SPARQL-I-0002 design phase, 2026-08-05) — the class of proposal STORE-A-0002's review triggers anticipated.

**Evidence.** The SPARQL engine resolves a query's ground terms to Term_IDs once at query setup ("term-binding bridge"); a term absent from the store short-circuits to empty results. Today the only term → ID path is `intern_term`, which *assigns* a fresh ID when the term is absent. For memstore that merely pollutes the dictionary with one entry per unseen query constant; for kvstore it means **every query performs a write transaction** — dictionaries grow per query, and queries against a read-only LMDB environment fail outright. Queries must not write.

Separately, the engine needs a row-level "unbound variable" sentinel. ID 0 is a valid term ID (IRI kind, counter 0), so the engine defines UNBOUND at Sentinel counter 2 — the next free slot after DEFAULT_GRAPH (counter 0) and WILDCARD (counter 1). The store should reserve it so no future sentinel collides.

## Backlog Item Details **[CONDITIONAL: Backlog Item]**

### Type
- [x] Feature - New functionality or enhancement

### Priority
- [x] P1 - High (important for user experience)

Blocks odin-rdf-sparql SPARQL-I-0002's dual-backend suite discipline: evaluation tasks start against memstore immediately, but kvstore runs need `find_term` before the first evaluation suite is enabled against it.

### Business Justification **[CONDITIONAL: Feature]**
- **User Value**: Downstream engines (odin-rdf-sparql now, odin-rdf-shacl later) can resolve query constants without mutating the store — required for read-only deployments.
- **Business Value**: Unblocks the SPARQL evaluation initiative's both-backends exit criterion.
- **Effort Estimate**: S — additive, no format or contract changes. memstore: the existing dictionary map probed without insert. kvstore: a read-transaction get against term2id (the codec already exists; `intern_term`'s lookup half without the assign half).

## Acceptance Criteria

## Acceptance Criteria **[REQUIRED]**

- [x] `find_term(d, term) -> (Term_ID, bool)` (name per family convention) in **both** backends: returns the existing ID or `false`, never assigns, never writes. kvstore's variant works inside a read transaction and against a read-only environment open.
- [x] Graph-label counterpart consistent with the `intern_graph_label` / `lookup_graph_label` pairing (DEFAULT_GRAPH for nil labels).
- [x] `UNBOUND :: Term_ID(Term_Kind.Sentinel) << COUNTER_BITS | 2` reserved in `store/term_id.odin`, documented alongside DEFAULT_GRAPH and WILDCARD: never assigned by dictionaries, never valid inside stored quads or match patterns.
- [x] Conformance suite extended: find-existing, find-absent (no assignment observable afterwards — dictionary size/counters unchanged), and both backends instantiate the new checks.
- [x] Contract comment in `interface.odin` updated; dual-width (64/32) tests green.

## Implementation Notes **[CONDITIONAL: Technical Task]**

### Technical Approach
- memstore (`store/memstore/dictionary.odin`): `intern_term` already computes the lookup before assigning — extract/probe the same map without the insert path. Mirror for triple terms (component-wise find; any missing component ⇒ not found).
- kvstore (`store/kvstore/dictionary.odin`): `intern_term_txn`'s canonical-encode + term2id get, minus the assign/put branch; expose a non-txn wrapper that opens a read txn, per the existing `lookup_term`/`lookup_term_txn` pairing.
- UNBOUND is a one-line constant plus documentation; the dictionary already never assigns Sentinel-kind IDs.

### Dependencies
None on store side. Consumer: odin-rdf-sparql SPARQL-I-0002 (its kvstore suite runs are blocked on this task).

### Risk Considerations
None significant — additive API, no persistent-format change (STORE-A-0003 untouched). Care that the kvstore find path allocates nothing it doesn't free (canonical-encode scratch) under the family's allocation guards.

## Status Updates **[REQUIRED]**

- **2026-08-05 — Created from SPARQL-I-0002 design-phase audit** (odin-rdf-sparql). Awaiting pickup in an odin-rdf-store session.
- **2026-08-05 — Implemented; all acceptance criteria met, `make check` and `make test` green at both Term_ID widths.**

  **Shipped.**
  - `store/term_id.odin`: `UNBOUND` at Sentinel counter 2, documented as belonging to the layer *above* the store — unlike DEFAULT_GRAPH and WILDCARD it is valid in neither a stored quad nor a pattern. `Term_Kind`'s comment now names all three sentinels. Pinned in `term_id_test.odin`: kind, counter, mutual distinctness, and distinctness from ID 0 (the reason it must exist).
  - `store/memstore/dictionary.odin`: `find_term` (map probe, no insert; triple terms component-wise) and `find_graph_label` (nil ⇒ DEFAULT_GRAPH, always found).
  - `store/kvstore/dictionary.odin`: factored the verified term2id probe out of `intern_canonical` into `probe_canonical` — so find and intern cannot drift on collision handling — plus `literal_canonical` / `triple_canonical` so both paths encode canonical bytes through one code path. `find_term` (own read txn), `find_term_txn` (caller's txn, read or write), `find_graph_label`.
  - `store/interface.odin`: the contract comment now states the dictionary procedure set alongside the dataset one, and why find_term exists (reading must not be a write).
  - `conformance/conformance.odin`: `check_find_term`, plus three Backend adapter fields (`find_term`, `find_graph`, `dict_size`). Both backends instantiate it (`test_memstore_find_term`, `test_lmdb_find_term`).

  **Decisions.**
  1. *No-assignment is observed two ways*: `dict_size` (memstore entry arrays / kvstore per-kind counters, unchanged across the absent probes) **and** probing the absent set twice — the second pass would find whatever the first had assigned. `dict_size` is a test-only adapter field, so no new public API leaked in to support the test.
  2. *A too-long language tag is not-found on the read path*, where interning raises `Language_Too_Long`. No literal the format can store carries a 256-byte tag, so the honest answer to "is this present?" is no. Pinned by `test_dict_find_term_long_language`.
  3. *Absent coverage is per-kind and adversarial*: unknown IRI/blank/literal, a literal whose **datatype IRI** is unknown (the case where interning would have written the datatype before failing to find the literal), a triple term with an unknown component, and a triple term whose components are all known in a combination that is not.
  4. `find_graph_label_txn` was written and then dropped — no in-package caller, and `find_term_txn` is already public for consumers that hold a transaction.

  **Read-only environments** — the acceptance criterion that mattered most for the consumer — are covered by `test_dict_find_term_read_only_environment`: populate, close, reopen with `Options.read_only`, then resolve present terms, a graph label, and an absent term, asserting the per-kind counters are untouched.

  **Not done, deliberately:** no `find_quad`/pattern-level resolution helper. odin-rdf-sparql's term-binding bridge composes `find_term` per position and short-circuits on the first miss; guessing its shape here would be speculative.