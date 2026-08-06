---
id: odin-rdf-store
level: vision
title: "odin-rdf-store"
short_code: "STORE-V-0001"
created_at: 2026-08-04T16:46:31.177132+00:00
updated_at: 2026-08-06T12:00:00.000000+00:00
archived: false

tags:
  - "#vision"
  - "#phase/published"


exit_criteria_met: true
initiative_id: NULL
---

# odin-rdf-store Vision

## Purpose

Provide the Odin RDF family with its queryable storage layer: an RDF quad store that sits between odin-rdf-parser (parsing/serialization) and the future query and validation engines (odin-rdf-sparql, odin-rdf-shacl). This project defines the graph/dataset **match interface** those engines consume and ships its reference implementations — in-memory first, LMDB-backed later.

Sequencing rationale (settled in the odin-rdf-parser sessions, 2026-08-04): a SPARQL engine's core loop is joins over `match(subject, predicate, object, graph)` with wildcards — that operation is this library's API. The storage abstraction lives low and engines depend downward on it (the Jena DatasetGraph / RDF4J SAIL / Oxigraph arrangement), so SHACL can later stand on the same interface without dragging in a query engine.

## Product/Solution Overview

odin-rdf-store is a library (not an application) targeting Odin developers who build RDF-based systems. It offers:

- **A dataset/graph container** holding quads: one default graph plus named graphs, with set semantics per the RDF data model.
- **A match interface**: indexed lookup of quads where any of subject/predicate/object/graph may be a wildcard, returning streaming iterators. This interface is the contract downstream engines program against.
- **Term storage**: a term dictionary with interning and stable term identifiers, so matching and joins compare small IDs rather than strings.
- **Bulk ingestion and export** via odin-rdf-parser: load any of the four supported formats into a dataset, export a dataset through the emitters.
- **Multiple backends of one interface**: an in-memory reference implementation first; an LMDB-backed persistent implementation later, exploiting LMDB's zero-copy read semantics (the discipline odin-rdf-parser's ADR RDF-A-0001 was designed around).

The library is deliberately low-level: it supplies the storage primitives on which SPARQL evaluation, SHACL validation, and application-level tooling are built. Query languages, inference, and validation logic are out of scope — they are consumers.

## Current State

**Every success criterion is met (2026-08-06).** Both initiatives are complete. STORE-I-0001 delivered the term dictionary, the permutation-indexed in-memory dataset, and the match interface itself (STORE-A-0002); STORE-I-0002 delivered the persistent LMDB backend behind the same procedure set, with its on-disk format pinned in STORE-A-0003. One shared conformance suite — all 16 bound/wildcard pattern combinations, set semantics, default vs. named graphs, blank-node identity, RDF-star terms — passes **verbatim against both backends at both `Term_ID` widths**, which is what makes "multiple backends of one interface" a demonstration rather than a claim.

The interface has been proven by a real consumer: **odin-rdf-sparql** evaluates the full SPARQL algebra against it through the public contract alone, with no private hooks into either backend. It absorbed that use without redesign, and the capabilities it surfaced became seven backlog items rather than workarounds — the one interface revision this vision anticipated, arriving with evidence attached. `find_term` (STORE-T-0014) was the first, implemented in both backends before the engine needed it.

Round-tripping through odin-rdf-parser preserves data semantics for all four formats, and bulk ingestion at scale validated the parser's clone/intern contract in real use — closing the last open criterion in the parser's vision, RDF-V-0001.

Since then: STORE-A-0004 reversed STORE-I-0002's darwin_arm64-only platform stance. The LMDB C sources are vendored at `LMDB_0.9.35` and an archive is built and suite-verified per platform — macOS arm64/x86_64, Linux x86_64/arm64, Windows x86_64 — so every supported platform links a proven archive and `system:lmdb` is a fallback rather than the plan. CI runs on Linux, macOS, and Windows. Tagged **v0.1.0**.

Outstanding work is growth, not debt: seven backlog items covering ordered iteration, cardinality estimates, snapshot reads, dataset introspection, a named-graph wildcard, `triple_parts`, and sentinel reservation. Two of them — dataset introspection and the named-graph wildcard — are the ones **odin-rdf-shacl** is most likely to pull when its target resolution lands.

## Future State

A complete, well-tested Odin library where:

- The match interface is stable and proven: odin-rdf-sparql evaluates basic graph patterns against it, and it accommodates what a query planner needs (ordered iteration, cardinality estimates) without redesign.
- The in-memory implementation is the reference: correct set semantics, permutation indexes, competitive bulk-load throughput.
- An LMDB-backed implementation provides persistence behind the same interface.
- Loading a document through odin-rdf-parser and exporting it back preserves data semantics, closing the parser vision's downstream-validation criterion.

## Major Features

- **Dataset and graph model**: quad container with default + named graphs, set semantics, insert/remove/count.
- **Term dictionary**: interning of IRIs, blank nodes, and literals (RDF-star triple terms included) to stable IDs; bidirectional ID↔term lookup.
- **Permutation indexes**: index layouts (e.g. SPO/POS/OSP and graph-aware variants) supporting wildcard match patterns with streaming iterators.
- **Match interface**: the minimal contract engines consume — match with per-position wildcards, iteration, counts. Deliberately small in v1: match + insert + count; planner support (ordered iteration, cardinality estimates) added when the SPARQL engine demonstrates the need.
- **Bulk load and export**: ingestion from all four odin-rdf-parser formats using the per-statement clone/intern discipline; export through the emitters.
- **In-memory backend**: the reference implementation of the interface.
- **LMDB backend (later phase)**: persistent implementation of the same interface with zero-copy reads.

## Success Criteria

- odin-rdf-sparql's basic graph pattern evaluation runs against the match interface without interface changes it cannot absorb.
- Bulk ingestion via odin-rdf-parser works at scale and validates the parser's clone/intern contract in real use (this closes the open success criterion in the parser's vision RDF-V-0001).
- Round-trip: load → match/export → compare preserves data semantics for all four formats.
- The in-memory backend passes a store test suite covering set semantics, all match patterns, and dataset/graph edge cases (default vs. named graphs, blank node identity, RDF-star terms).
- The public API is documented and idiomatic Odin, with the same contract-level documentation standard as odin-rdf-parser.

## Principles

- **Interface first, minimal**: the match interface starts as small as possible and grows only on evidence from real consumers — expect one revision when SPARQL evaluation lands, and design for that cheaply rather than speculating now.
- **Primitives over frameworks**: storage primitives only; query planning, inference, and validation belong downstream.
- **Idiomatic Odin**: explicit memory management, allocator awareness, straightforward procedural APIs — matching the conventions established in odin-rdf-parser.
- **Zero-copy discipline**: honor the LMDB-compatible borrowing/lifetime model of ADR RDF-A-0001 (odin-rdf-parser); interned terms and mapped pages over defensive copies.
- **Test-suite driven**: correctness is demonstrated by a systematic store test suite and round-trips against the W3C-conformant parser, not by example programs.

## Constraints

- Written in Odin. The core library and the in-memory backend have no external dependencies; the LMDB backend is an isolated, optional package (it requires C bindings) that nothing else depends on.
- Depends on odin-rdf-parser for the data model, parsing, and serialization; its types (`rdf.Term`, `rdf.Triple`, `rdf.Quad`) are the interchange vocabulary.
- Scope is limited to storage, indexing, and the match interface. SPARQL, SHACL, reasoners, and network/server layers are out of scope — they build on this library.
- Persistence backends other than LMDB are out of scope for now.