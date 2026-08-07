---
id: 001-term-id-encoding-kind-tagged-dense
level: adr
title: "Term_ID encoding: kind-tagged dense IDs with build-time width"
number: 1
short_code: "STORE-A-0001"
created_at: 2026-08-04T17:28:47.138640+00:00
updated_at: 2026-08-04T17:42:07.011196+00:00
decision_date: 
decision_maker: 
parent: 
archived: false

tags:
  - "#adr"
  - "#phase/decided"


exit_criteria_met: false
initiative_id: NULL
---

# ADR-1: Term_ID encoding: kind-tagged dense IDs with build-time width

## Context **[REQUIRED]**

The term dictionary (STORE-I-0001) interns every RDF term to a fixed-size `Term_ID`; encoded quads (`[4]Term_ID`) are what every index stores and every match/join compares. The encoding must be settled before the dictionary is built because two consumers inherit it and make it expensive to change:

- **The LMDB backend** (later initiative) persists concatenated Term_IDs as index keys. LMDB compares keys with memcmp (a custom comparator via `mdb_set_compare` exists but is discouraged: it must be re-registered on every environment open and slows every comparison), so the byte layout of an ID inside a key determines iteration order in perpetuity.
- **odin-rdf-sparql** joins on IDs and benefits from any structure the ID itself carries (e.g. term kind), because every property it can read without a dictionary lookup is a dictionary lookup avoided in a hot loop.

Requirements gathered in the initiative's design discussion (2026-08-04):

- Bidirectional ID↔term lookup; reverse lookup should be array-indexed, which wants dense IDs.
- Matchers and future SPARQL evaluation want to distinguish term kind (IRI / blank node / literal / RDF-star triple term) without consulting the dictionary — literals cannot be subjects, graph labels cannot be literals, ORDER BY groups by kind.
- A reserved sentinel for the default graph in the graph position.
- The human raised two constraints: (1) the encoding must behave correctly under LMDB's lexicographic key ordering; (2) both a 64-bit and a 32-bit ID space should be buildable, selected at compile time via Odin's `when`/`#config` mechanism.

## Decision **[REQUIRED]**

`Term_ID` is a **kind-tagged dense integer with build-time-selectable width**:

1. **Width via build config**: `TERM_ID_BITS :: #config(RDF_STORE_TERM_ID_BITS, 64)`; `when TERM_ID_BITS == 32 { Term_ID :: distinct u32 } else { Term_ID :: distinct u64 }`. 64-bit is the default; 32-bit is an opt-in for memory-constrained in-memory use (16-byte encoded quads instead of 32).
2. **Kind tag in the high bits**: the top bits encode the term kind — IRI, blank node, literal, RDF-star triple term — plus reserved values (default-graph sentinel; room for future kinds). Tag width is fixed at 3 bits at both ID widths.
3. **Dense per-kind counter in the remaining bits**: IDs are assigned sequentially within each kind in first-seen order, so `counter(id)` indexes directly into a per-kind array for ID→term lookup. At 32 bits this leaves ~2^29 (~537M) terms per kind; at 64 bits, effectively unbounded.
4. **No hardcoded widths**: tag shift, counter mask, per-kind capacity, and sentinels are all derived from `size_of(Term_ID)`. Code never mentions 32 or 64 outside the `when` block.
5. **Both widths tested**: CI builds and runs the full test suite at both widths (exit criterion on STORE-I-0001).
6. **LMDB key rule**: when IDs enter LMDB keys they are serialized **big-endian**, so memcmp order equals numeric ID order. No custom comparator. The LMDB metadata records the ID width the database was written with and refuses to open under a build of the other width — a width mismatch must be a loud open-time error, never silent corruption.
7. **In-memory ordering matches**: the in-memory backend compares encoded quads positionally by numeric ID, so both backends produce identical iteration order if ordered iteration ever enters the planner contract. *(Historical as of 2026-08-07: memstore is retired — STORE-A-0006. kvstore's numeric-ID iteration order stands on its own, falling out of the big-endian key rule in point 6, so this point's consequence for STORE-T-0015 is unaffected; only the cross-backend agreement it asserted is moot.)*
8. **Triple terms intern recursively**: an RDF-star triple term's components are interned first; the triple term's own ID is a dense ID of kind "triple term" whose dictionary entry holds the three component IDs.

## Alternatives Analysis **[CONDITIONAL: Complex Decision]**

| Option | Pros | Cons | Risk Level | Implementation Cost |
|--------|------|------|------------|-------------------|
| Kind-tagged dense ID, build-time width (chosen) | Kind checks without dictionary lookups; array-indexed reverse lookup; kind-clustered LMDB ranges; width fits workload | Tag/mask arithmetic; two build configs to test; LMDB width-compat handling | Low | Medium |
| Plain dense u64, no tag | Simplest arithmetic; maximal counter space | Every kind check is a dictionary lookup; no kind-clustered ranges | Low | Low |
| Fixed u32 with tag | Smallest quads (16 B) always | Hard cap ~537M terms/kind baked into persisted LMDB data — the one thing declared expensive to change | Medium | Low |
| Hashed IDs (e.g. 128-bit content hash, Oxigraph-style) | ID computable without dictionary round-trip; stable across stores | No dense reverse index; larger quads; collision handling; overkill absent distributed use | Medium | Medium |
| Order-preserving dictionary (ID order = term order) | ORDER BY without decoding | Interning becomes insert-in-order (global renumbering or B-tree IDs); massive complexity | High | High |

## Rationale **[REQUIRED]**

- **Tag bits are nearly free and structurally useful**: 3 bits sacrifice little counter space, and under big-endian memcmp they make each LMDB index position kind-clustered — e.g. "all quads whose object is a literal" is one contiguous range scan rather than a filtered scan. The same check in memory is a mask test instead of a dictionary lookup.
- **Dense beats hashed here**: reverse lookup is a hot path for materializing SPARQL results; an array index beats a hash probe, and nothing in the vision needs IDs stable across independent stores.
- **Build-time width, not runtime**: a runtime width would poison every struct layout and index with branches; Odin's `#config`/`when` gives two clean monomorphic builds. The derived-constants rule plus dual-width CI keeps the second width from rotting; the LMDB width check keeps the two builds from corrupting each other's files.
- **Big-endian serialization** is the standard resolution of "integer keys under memcmp" and confines byte-order concern to the LMDB backend's key codec — the logical ID stays a plain integer everywhere else.
- **Order-preserving dictionaries ruled out** knowingly: ID order is first-seen insertion order within kind and carries no term ordering. ORDER BY always decodes through the dictionary. Every mainstream store (Jena TDB, RDF4J, Oxigraph) accepts this trade.

## Consequences **[REQUIRED]**

### Positive
- Joins, dedup, and index comparisons are integer comparisons at every layer.
- Kind of any term readable from the ID alone; kind-clustered ranges in LMDB indexes.
- ID→term lookup is an array index; term→ID is one hash probe at intern time.
- 32-bit build halves index memory for datasets that fit its per-kind caps.

### Negative
- Two build configurations must be continuously tested (CI cost).
- LMDB databases are width-specific; deployments must pick a width and stay with it (mitigated by the loud open-time check).
- 3 tag bits cap the 32-bit build at ~537M terms per kind — acceptable for its intended in-memory use, and the 64-bit default has no practical cap.

### Neutral
- ID order is insertion order within kind; no semantic ordering. ORDER BY and any future range-over-values feature must decode through the dictionary.
- The default-graph sentinel and other reserved IDs come out of the tag space, not any kind's counter space.
- The tag layout (3 bits, which kind gets which value) becomes part of the persisted LMDB format from its first release.