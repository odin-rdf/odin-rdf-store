---
id: triple-parts-a-triple-term-s
level: task
title: "triple_parts: a triple term's component IDs, without materializing it"
short_code: "STORE-T-0020"
created_at: 2026-08-05T22:36:45.860963+00:00
updated_at: 2026-08-05T22:36:45.860963+00:00
parent: 
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/backlog"
  - "#feature"


exit_criteria_met: false
initiative_id: NULL
---

# triple_parts: a triple term's component IDs, without materializing it

## Objective **[REQUIRED]**

Add the reverse of `intern_triple_ids`: given a Term_ID of kind `.Triple`,
return the three component **IDs**, without building an `rdf.Triple`.

**Evidence.** SPARQL 1.2 lets a triple term appear in a pattern —
`<<( ?s ?p ?o )>> ?q ?z`, and the whole `eval-triple-terms` suite is built on
it (odin-rdf-sparql SPARQL-T-0018). A triple term written out in full is
resolved once at plan time through `find_term`, which both dictionaries
already answer component-wise; that direction is served. A triple term with a
variable in it is not one ID, so the store matches whatever triple term sits
in that position and the engine has to **take it apart again** and unify the
components — once per candidate quad, on the match hot path.

The dictionary knows the answer outright. memstore keeps
`triples: [dynamic][3]Term_ID` — the component IDs it interned the term
from — and the engine reads them straight out through a per-backend adapter
(`sparql.Triple_Reader`), so on memstore a triple-term pattern streams with
**zero** allocations, pinned by an allocation guard in the SPARQL engine's
test suite.

kvstore has the same bytes — `triple_canonical` writes exactly the three IDs
big-endian, and `id2term` stores them — but exposes no way to read them. So
its adapter calls `lookup_term`, which recursively materializes the entire
term (every nested triple, every literal's datatype IRI, every string), and
then calls `find_term` three times to get back the IDs it just threw away.
Four round trips and a full materialization, per candidate quad, for three
integers the store had in hand.

## Backlog Item Details **[CONDITIONAL: Backlog Item]**

### Type
- [x] Feature - New functionality or enhancement

### Priority
- [x] P3 - Low (when time permits)

Small, self-contained, and only affects queries that use SPARQL 1.2 triple
terms with variables inside them. Listed because it is the clearest
"the store already knows this" item in the whole evidence log — and because
it is an afternoon.

### Business Justification **[CONDITIONAL: Feature]**
- **User Value**: SPARQL 1.2 triple-term patterns cost the same on the persistent backend as on the in-memory one, instead of a materialize-and-re-find per candidate quad.
- **Business Value**: Removes the one place where the two backends have materially different asymptotics for the same query, which is the property the dual-backend conformance discipline exists to protect.
- **Effort Estimate**: S. memstore: return `d.triples[id_counter(id)]`. kvstore: read the three big-endian IDs out of the `id2term` value, which `triple_canonical` already wrote in that exact layout.

## Acceptance Criteria **[REQUIRED]**

- [ ] `triple_parts(d, id) -> (parts: [3]Term_ID, ok: bool)` in both backends (name per family convention). `ok` is false for an ID that is not of kind `.Triple`; an ID of that kind the dictionary does not hold is a caller error, so assert rather than answer.
- [ ] Allocates nothing on either backend — this is on a match hot path, and the in-memory backend already achieves it.
- [ ] A read: no assignment, no write transaction, correct against a read-only environment open — the `find_term` posture from STORE-T-0014. A `_txn` variant on kvstore, matching `find_term_txn`.
- [ ] Round-trip pinned in the conformance suite: `intern_triple_ids(d, parts)` then `triple_parts(d, id)` returns `parts`, including for a nested triple term (a component that is itself of kind `.Triple`). Both backends, both Term_ID widths.

## Implementation Notes **[CONDITIONAL: Technical Task]**

### Technical Approach

- memstore (`store/memstore/dictionary.odin`): `d.triples` is already indexed
  by `store.id_counter`; this is a bounds check and a read.
- kvstore (`store/kvstore/dictionary.odin`): `id2term_get` returns the
  canonical bytes, and for `.Triple` those bytes are the three IDs in
  big-endian — the same layout `triple_canonical` writes and
  `lookup_term_txn` already walks. Reading them without recursing is strictly
  less work than what `lookup_term_txn` does today.

### Dependencies

None. Consumer: odin-rdf-sparql (`sparql.Triple_Reader` and its two adapters,
`sparql/memstore/eval.odin` and `sparql/kvstore/eval.odin`, which document
this gap in their comments).

### Risk Considerations

None. Additive, no persistent-format change — the bytes already exist and are
already parsed by `lookup_term`, just at a coarser granularity.

## Status Updates **[REQUIRED]**

- **2026-08-05 — Created from odin-rdf-sparql SPARQL-T-0019**, the evaluation initiative's evidence consolidation. Awaiting pickup in an odin-rdf-store session.
- **2026-08-07 — memstore retired (STORE-A-0006, STORE-I-0003); one acceptance criterion is
  now unmeetable as written.** "Allocates nothing on either backend — this is on a match hot
  path, and the in-memory backend already achieves it" has no second backend and no existing
  proof. The zero-allocation requirement stands on its own merits and is achievable — reading
  three big-endian IDs out of the `id2term` value, which `triple_canonical` already wrote in
  that layout, needs no allocation — but it must now be *demonstrated* rather than inherited.
  The User Value framing ("cost the same on the persistent backend as on the in-memory one")
  goes with it: the comparison no longer exists, and the value is simply that a triple-term
  pattern streams instead of materializing per candidate quad.
