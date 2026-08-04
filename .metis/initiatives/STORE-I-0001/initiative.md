---
id: term-dictionary-and-in-memory
level: initiative
title: "Term dictionary and in-memory dataset with match interface"
short_code: "STORE-I-0001"
created_at: 2026-08-04T17:03:31.127517+00:00
updated_at: 2026-08-04T17:43:16.511068+00:00
parent: STORE-V-0001
blocked_by: []
archived: false

tags:
  - "#initiative"
  - "#phase/decompose"


exit_criteria_met: false
estimated_complexity: L
initiative_id: term-dictionary-and-in-memory
---

# Term dictionary and in-memory dataset with match interface Initiative

## Context **[REQUIRED]**

This is the first initiative of the odin-rdf-store vision (STORE-V-0001): build the storage core on which everything else stands — a term dictionary, an in-memory quad dataset, and the **match interface** that downstream engines (odin-rdf-sparql, odin-rdf-shacl) will program against.

Foundation this builds on (all in `../odin-rdf-parser`):

- **Data model** (`rdf` package): `rdf.Term :: union { IRI, Blank_Node, Literal, ^Triple }`, `rdf.Triple`, `rdf.Quad` (triple + `Graph_Label`, where a nil `Graph_Label` denotes the default graph). RDF 1.2 including RDF-star triple terms and directional language-tagged strings.
- **Lifetime contract** (ADR RDF-A-0001): parsers yield borrowed slices valid only until the next `parser_next` call. A store ingesting statements must promote terms to its own owned representation per statement — exactly what the term dictionary does. The parser's `Intern_Table` (`rdf/intern.odin`) is the string-level precedent; the store's dictionary goes further by assigning small fixed-size IDs.
- **Equality and hashing** (`rdf/equal.odin`, `rdf/hash.odin`): term equality semantics the dictionary must agree with.

Sequencing rationale (settled in the odin-rdf-parser sessions, 2026-08-04): a SPARQL engine's core loop is joins over `match(s, p, o, g)` with wildcards. That operation is this initiative's deliverable. Getting the term-ID encoding and match contract right here determines whether the later LMDB backend and the SPARQL engine can build on it without redesign.

## Goals & Non-Goals **[REQUIRED]**

**Goals:**
- A **term dictionary**: interning of all term kinds (IRIs, blank nodes, literals, RDF-star triple terms) to stable fixed-size term IDs, with bidirectional ID↔term lookup. Comparing and joining terms means comparing small IDs, not strings.
- A **dataset container**: quads over term IDs, one default graph plus named graphs, correct set semantics (duplicate insert is a no-op), insert/count. Append-only in v1 — `remove` is deferred; see Detailed Design decision 5.
- **Permutation indexes** supporting every wildcard pattern of `match(s, p, o, g)` with streaming iterators.
- The **match interface** as a formal contract, deliberately minimal in v1: match + insert + count. Defined so the in-memory backend is one implementation of it, not the interface itself — the later LMDB backend must be able to slot in behind it.
- **Ingestion from odin-rdf-parser**: pull statements from any of the four parsers and intern them into the dataset, honoring the per-statement validity contract of RDF-A-0001. This is both a feature and the proof of the parser's clone/intern contract in real use.
- A **store test suite** covering set semantics, all 16 match patterns, dataset/graph edge cases (default vs. named graphs, blank node identity, RDF-star terms, literal equality including language tags and direction).

**Non-Goals:**
- LMDB or any persistent backend (later initiative; this initiative only keeps the interface implementable over it).
- Planner support: ordered iteration, cardinality estimates, ID-order guarantees. Added when odin-rdf-sparql demonstrates the need (vision principle: interface grows on evidence).
- Export/serialization through the parser's emitters (natural follow-up initiative; round-trip testing here may use emitters informally, but a polished export API is out of scope).
- SPARQL, SHACL, inference, transactions, concurrency guarantees beyond single-threaded use.
- Term normalization or validation (e.g. IRI normalization, literal value-space canonicalization) — the dictionary interns lexical forms as given, matching the parser's behavior.

## Architecture **[CONDITIONAL: Technically Complex Initiative]**

### Overview

Three layers, each depending only on the one below:

```
match interface (contract: match/insert/count over Term_ID quads)
        ▲ implemented by
in-memory dataset (permutation indexes over encoded quads)
        ▲ encodes via
term dictionary (Term ⇄ Term_ID, owned storage)
        ▲ ingests from
odin-rdf-parser (rdf.Term / rdf.Quad, borrowed per statement)
```

- **Term dictionary**: maps `rdf.Term` → `Term_ID` (interning; clones borrowed strings into dictionary-owned storage on first sight) and `Term_ID` → `rdf.Term` (lookup returns terms whose strings are views into dictionary storage — borrowed from the dictionary, valid for its lifetime). RDF-star triple terms intern recursively: a triple term's ID is derived from the IDs of its three components.
- **Encoded quad**: `[4]Term_ID` — subject, predicate, object, graph, with a reserved ID for the default graph. All index structures operate on these fixed-size tuples only.
- **Permutation indexes**: enough orderings that every match pattern (each of s/p/o/g bound or wildcard, 16 combinations) is answered by a range/scan over one index without post-filtering on the primary bound positions.
- **Match interface**: the procedures/types downstream engines consume. Match results stream: an iterator yielding encoded quads (IDs), with decoding to `rdf.Term` an explicit separate step — engines join on IDs and only materialize terms for final results.

### Boundary with odin-rdf-parser

Ingestion is a pull loop: `parser_next` → intern the four positions into the dictionary → insert the encoded quad → next statement. Nothing borrowed from the parser survives the loop iteration, satisfying RDF-A-0001. The dictionary replaces (not wraps) the parser's `Intern_Table` for store use, since it must also assign IDs.

## Detailed Design **[REQUIRED]**

Design decisions settled with the human 2026-08-04. Decisions 1 and 4 are recorded in full in STORE-A-0001 (Term_ID encoding) and STORE-A-0002 (match interface shape).

1. **Term_ID representation** — **DECIDED**: fixed-width integer with kind tag in the high bits (IRI / blank node / literal / triple term) and a dense per-kind counter in the remaining bits. Width is a build-time choice via `TERM_ID_BITS :: #config(RDF_STORE_TERM_ID_BITS, 64)` selecting `Term_ID :: distinct u64` (default) or `distinct u32`. Guardrails: (a) all tag shifts, masks, per-kind capacity, and the reserved default-graph sentinel are derived from `size_of(Term_ID)` — no hardcoded widths; (b) CI builds and runs the test suite at both widths; (c) the LMDB format records ID width in its metadata and refuses to open a mismatched database. LMDB key rule: IDs are serialized **big-endian** in composite keys so memcmp order equals numeric order; tag-high-bits then yields kind-clustered key ranges per index position (e.g. "objects that are literals" is one contiguous range). Recorded caveat: ID order is first-seen insertion order within a kind, never lexicographic term order — ORDER BY always decodes through the dictionary; order-preserving dictionaries were ruled out. The in-memory backend compares encoded quads positionally by numeric ID so both backends agree on iteration order. → STORE-A-0001.
2. **Index set** — **DECIDED**: three graph-first permutations, GSPO/GPOS/GOSP, covering all 16 match patterns; wildcard-graph patterns with bound terms scan across graphs. Reversible behind the interface — graph-last permutations (SPOG/POSG/OSPG, the Oxigraph-style six) can be added later if wildcard-graph profiling demands. Document which index answers which pattern.
3. **Index data structure** — **DECIDED** (by default, hidden behind the interface): sorted dynamic arrays with binary search — simple, cache-friendly, bulk-load- and append-friendly. Fits the append-only decision (5); revisitable without interface change.
4. **Match interface shape in Odin** — **DECIDED**: documented procedure-set convention that each backend package implements, enforced by a shared conformance test suite — the odin-rdf-parser arrangement (four parsers, one API shape), zero runtime overhead. No struct-of-procedure-pointers in v1; a vtable-style adapter can be layered on later if a consumer needs runtime backend polymorphism. → STORE-A-0002.
5. **Removal semantics** — **DECIDED**: append-only v1; no `remove`. Rationale: a planned future variant is an append-only store with time-travel support, where removal is never physical — it is a tombstone/validity-interval append. The interface ADR therefore defines `remove` (when it arrives) as a **logical visibility** operation ("absent from subsequent matches"), satisfiable by physical deletion (in-memory) or tombstone append (time-travel variant) alike. The vision's "insert/remove/count" wording for the dataset is deferred with this rationale. Dictionary does not GC: monotonic growth until destroy — also a prerequisite for time travel (terms must never vanish).
6. **Blank node handling on ingest** — **DECIDED**: per-load blank-node mapping at the ingestion layer, so equal labels from separate documents become distinct dictionary entries. An opt-in shared-scope mode waits for a use case.
7. **Allocator story** — **DECIDED**: follow odin-rdf-parser's idiom — every `*_init` takes `allocator := context.allocator`; iterators allocate nothing or take an explicit allocator.

## Testing Strategy **[CONDITIONAL: Separate Testing Initiative]**

Test-suite driven per the vision — the suite is a deliverable, not an afterthought:

- **Dictionary unit tests**: intern-twice-same-ID for every term kind, ID→term round-trip, literal edge cases (language tags, direction, datatypes), recursive RDF-star triple terms, agreement with `rdf.equal` semantics.
- **Dataset/match conformance suite**: written against the match interface, not the in-memory implementation, so the LMDB backend can run the identical suite later. Covers all 16 match patterns, set semantics, default vs. named graphs, empty-dataset and no-match cases, iterator behavior under exhaustion.
- **Ingestion integration tests**: load fixtures in all four formats through odin-rdf-parser, verify counts and matches; adversarial fixtures reusing the parser's escape/RDF-star corner cases to prove the per-statement clone discipline (no dangling borrows — the kind of bug RDF-A-0001 warns the type system won't catch).
- **Round-trip smoke test**: load → export via parser emitters → reload → datasets match (informal use of emitters; polished export API is a later initiative).
- **Bulk-load benchmark**: a `bench/` harness tracking statements/second and bytes/statement on a large fixture, guarding against silent copy regressions (same discipline as the parser's benchmarks).

## Alternatives Considered **[REQUIRED]**

- **Store `rdf.Term` values directly (no term dictionary)** — reuse the parser's `Intern_Table` and index quads of terms. Simpler to start, but joins and index comparisons become string comparisons, indexes bloat with pointer-heavy variants, and the LMDB backend would need an ID encoding anyway — forcing a redesign of exactly the interface this initiative exists to stabilize. Rejected; the vision explicitly names ID-based matching.
- **Single hash-set of quads with per-pattern filtering** — one `map` keyed by encoded quad; answer matches by scanning. Trivially correct and a candidate first milestone internally, but wildcard matches degrade to full scans, which the match interface would then normalize as acceptable performance. Rejected as the deliverable; acceptable as a scaffolding step while the conformance suite is built.
- **Full Hexastore (all six triple permutations × graph variants)** — maximal index coverage, but doubles-to-triples memory and bulk-load cost for patterns v1 consumers don't issue yet. Rejected for v1; the index set is chosen to cover the 16 patterns adequately, and the design allows adding permutations later without interface change.
- **Defining the match interface after building the SPARQL engine** — would guarantee a perfect fit but inverts the dependency order settled in the parser sessions (2026-08-04): the storage abstraction lives low, engines depend downward (Jena DatasetGraph / RDF4J SAIL / Oxigraph arrangement). Mitigation instead: keep v1 minimal (match+insert+count) and budget for one interface revision when SPARQL lands.

## Implementation Plan **[REQUIRED]**

Direction (task decomposition happens at the decompose phase, with human sign-off):

1. **Design-phase outputs first**: settle the numbered decisions in Detailed Design; write the two ADRs (Term_ID encoding; match-interface shape in Odin).
2. **Term dictionary** — types, intern/lookup, owned storage, unit tests. No dataset yet; independently testable.
3. **Dataset with naive backing + conformance suite** — encoded-quad container with set semantics over a simple structure; write the full 16-pattern conformance suite against the interface while the backing is trivially correct.
4. **Permutation indexes** — replace the naive backing with the chosen index layout; conformance suite must pass unchanged (that's the proof the interface abstracted correctly).
5. **Parser ingestion** — bulk-load loop over all four formats, blank-node scoping, integration tests, benchmark harness.
6. **Polish** — API documentation to odin-rdf-parser's contract-level standard; round-trip smoke test; close out against exit criteria.

Milestone ordering note: steps 2–3 can proceed in parallel with the ADRs for step 1 only where decisions don't bind them (the Term_ID encoding binds step 2; the interface shape binds step 3).

## Status Updates

- **2026-08-04 — Decomposed into 6 tasks**: STORE-T-0001 (Term_ID encoding + dual-width CI) → STORE-T-0002 (term dictionary) → STORE-T-0003 (match contract, naive dataset, conformance suite) → then STORE-T-0004 (permutation indexes) and STORE-T-0005 (parser bulk ingestion) in parallel → STORE-T-0006 (round-trip, benchmark, docs, close-out). Dependencies recorded in each task's `blocked_by` frontmatter. Awaiting human review before activation.

## Exit Criteria **[REQUIRED]**

- [ ] Term dictionary interns all term kinds (including recursive RDF-star triple terms) to stable IDs with bidirectional lookup, verified by unit tests.
- [ ] In-memory dataset enforces set semantics with default + named graphs; insert/count behave per the RDF data model (append-only v1 per decision 5; remove's future contract defined as logical visibility in the interface ADR).
- [ ] Test suite passes at both Term_ID widths (64-bit default and 32-bit `#config` build).
- [ ] All 16 `match(s, p, o, g)` wildcard patterns are answered via permutation indexes with streaming iterators, verified by a conformance suite written against the match interface (not the implementation).
- [ ] Match interface v1 (match + insert + count) is documented as the contract downstream engines consume, with the two supporting ADRs (Term_ID encoding, interface shape) decided.
- [ ] Documents in all four odin-rdf-parser formats bulk-load through the pull loop honoring RDF-A-0001's per-statement validity contract, with a benchmark harness in place.
- [ ] Public API documented at odin-rdf-parser's contract-level standard; store test suite green.