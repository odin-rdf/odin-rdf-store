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

Provide the Odin RDF family with its queryable storage layer: an RDF quad store that sits between odin-rdf-parser (parsing/serialization) and the future query and validation engines (odin-rdf-sparql, odin-rdf-shacl). This project defines the graph/dataset **match interface** those engines consume and ships its implementation, LMDB-backed. *(Historically two: an in-memory reference implementation came first and was retired 2026-08-07 — STORE-A-0006.)*

Sequencing rationale (settled in the odin-rdf-parser sessions, 2026-08-04): a SPARQL engine's core loop is joins over `match(subject, predicate, object, graph)` with wildcards — that operation is this library's API. The storage abstraction lives low and engines depend downward on it (the Jena DatasetGraph / RDF4J SAIL / Oxigraph arrangement), so SHACL can later stand on the same interface without dragging in a query engine.

## Product/Solution Overview

odin-rdf-store is a library (not an application) targeting Odin developers who build RDF-based systems. It offers:

- **A dataset/graph container** holding quads: one default graph plus named graphs, with set semantics per the RDF data model.
- **A match interface**: indexed lookup of quads where any of subject/predicate/object/graph may be a wildcard, returning streaming iterators. This interface is the contract downstream engines program against.
- **Term storage**: a term dictionary with interning and stable term identifiers, so matching and joins compare small IDs rather than strings.
- **Bulk ingestion and export** via odin-rdf-parser: load any of the four supported formats into a dataset, export a dataset through the emitters.
- **One backend, behind an interface that permits others**: an LMDB-backed persistent implementation, exploiting LMDB's zero-copy read semantics (the discipline odin-rdf-parser's ADR RDF-A-0001 was designed around). The match interface is a documented procedure-set convention (STORE-A-0002), so a second backend remains a package away — but none is shipped and none has been asked for (STORE-A-0006, 2026-08-07).

The library is deliberately low-level: it supplies the storage primitives on which SPARQL evaluation, SHACL validation, and application-level tooling are built. Query languages, inference, and validation logic are out of scope — they are consumers.

## Current State

**Every success criterion is met (2026-08-06).** Both initiatives are complete. STORE-I-0001 delivered the term dictionary, the permutation-indexed in-memory dataset, and the match interface itself (STORE-A-0002); STORE-I-0002 delivered the persistent LMDB backend behind the same procedure set, with its on-disk format pinned in STORE-A-0003. One shared conformance suite — all 16 bound/wildcard pattern combinations, set semantics, default vs. named graphs, blank-node identity, RDF-star terms — passes **verbatim against both backends at both `Term_ID` widths**, which is what makes "multiple backends of one interface" a demonstration rather than a claim.

> **Amendment, 2026-08-07 (STORE-A-0006 / STORE-I-0003): the in-memory backend is retired and this vision no longer claims multiple backends.** memstore was an architectural proposal that no consumer ever asked for, and the transaction model STORE-T-0019 and STORE-T-0022 require came out dominated by accommodating it. The paragraph above stands as the record of what was true on 2026-08-06 — the suite *did* pass verbatim against both backends, and that is what proved the contract abstracted correctly. What is retracted is the ongoing claim: the suite is now a regression suite over one backend rather than a portability proof, and the match interface's contract is LMDB's semantics by definition. The convention (STORE-A-0002) and the conformance `Backend` adapter are retained so a second backend can be added on evidence; the demonstration is what has ended, not the design that permits it.

The interface has been proven by a real consumer: **odin-rdf-sparql** evaluates the full SPARQL algebra against it through the public contract alone, with no private hooks into either backend. It absorbed that use without redesign, and the capabilities it surfaced became seven backlog items rather than workarounds — the one interface revision this vision anticipated, arriving with evidence attached. `find_term` (STORE-T-0014) was the first, implemented in both backends before the engine needed it.

Round-tripping through odin-rdf-parser preserves data semantics for all four formats, and bulk ingestion at scale validated the parser's clone/intern contract in real use — closing the last open criterion in the parser's vision, RDF-V-0001.

Since then: STORE-A-0004 reversed STORE-I-0002's darwin_arm64-only platform stance. The LMDB C sources are vendored at `LMDB_0.9.35` and an archive is built and suite-verified per platform — macOS arm64/x86_64, Linux x86_64/arm64, Windows x86_64 — so every supported platform links a proven archive and `system:lmdb` is a fallback rather than the plan. CI runs on Linux, macOS, and Windows. Tagged **v0.1.0**.

Outstanding work was growth, not debt: seven backlog items covering ordered iteration, cardinality estimates, snapshot reads, dataset introspection, a named-graph wildcard, `triple_parts`, and sentinel reservation. Two of them — dataset introspection and the named-graph wildcard — are the ones **odin-rdf-shacl** is most likely to pull when its target resolution lands.

> **Amendment, 2026-08-08: two of those seven are delivered and both consumers have adopted them, and the tag is now v0.4.0.** STORE-I-0004 shipped transactions and snapshots as v0.3.0 (`STORE-A-0007`): one `Txn` handle with a `.Read`/`.Write` mode, of which **a read transaction *is* the snapshot**, closing STORE-T-0019 and STORE-T-0022 together. What the paragraph above calls "snapshot reads" is therefore done, and so is `find_term`. Five remain: ordered iteration, cardinality estimates, dataset introspection, the named-graph wildcard, `triple_parts`, and sentinel reservation.
>
> **The interface-proven-by-a-consumer claim above now has a second and third instance.** odin-rdf-shacl binds validation to a caller's transaction (`SHACL-T-0029`), which is what makes validate-before-commit expressible: a candidate is built inside a write transaction and validated through that same transaction, rather than in an isolated store where every constraint that must consult existing data passes vacuously. odin-rdf-sparql holds a read transaction for a `Query`'s lifetime (`SPARQL-T-0024`), so a query answers about one dataset rather than about however many its independent reads happened to land on. Both were proposed from here with call sites named (`STORE-T-0041`) and sequenced by the repositories that own them.
>
> Also since: `open_ephemeral` (`STORE-T-0033`, v0.3.0) gave the suites a store with no path to name or clean up, and `STORE-T-0042` fixed the Windows failure that adoption surfaced — released as v0.4.0, which also made `Error` carry `os.Error` rather than classifying what it did not understand.

> **Amendment, 2026-08-07 (STORE-A-0007 / STORE-I-0004): two of those seven are delivered, and one of them was not growth.** Snapshot reads (STORE-T-0019) and write transactions (STORE-T-0022) are shipped as one model — one `Txn` handle with a `.Read`/`.Write` mode, of which a read transaction *is* the snapshot — and both items are archived as superseded. Five backlog items remain, and they are still growth: ordered iteration, cardinality estimates, dataset introspection, a named-graph wildcard, `triple_parts`, and sentinel reservation, plus `remove` (STORE-T-0023) and `insert_all` (STORE-T-0024), which STORE-A-0007 deliberately left out of scope and which both get simpler now.
>
> **STORE-T-0022 was debt, not growth, and the vision did not say so.** It was a P0 correctness gap rather than a capability: **validate-before-commit was inexpressible.** A validator deciding whether a write may join the dataset could not observe the write it was deciding about, and the only workaround the interface admitted — building the candidate in a second dataset and validating that — passes vacuously for every constraint that must consult existing data. That is worth recording as a correction to how this section read, not just as a checkbox: an item filed as a backlog feature was in fact the one thing the library got wrong.
>
> **STORE-I-0001's "concurrency guarantees beyond single-threaded use" non-goal is narrowed, not reversed.** What is now guaranteed is what LMDB already provided across processes — snapshot isolation, atomicity, one writer at a time — which is exactly the shape the deployment has: ~200 processes per machine, each embedding a store. Multi-writer conflict detection, retry, and isolation levels beyond the single-writer model remain out of scope and are explicitly not designed.

## Future State

A complete, well-tested Odin library where:

- The match interface is stable and proven: odin-rdf-sparql evaluates basic graph patterns against it, and it accommodates what a query planner needs (ordered iteration, cardinality estimates) without redesign.
- The LMDB-backed implementation provides persistence behind that interface: correct set semantics, permutation indexes, competitive bulk-load throughput. *(Until 2026-08-07 an in-memory implementation was the reference; STORE-A-0006 retired it.)*
- Loading a document through odin-rdf-parser and exporting it back preserves data semantics, closing the parser vision's downstream-validation criterion.

## Major Features

- **Dataset and graph model**: quad container with default + named graphs, set semantics, insert/remove/count.
- **Term dictionary**: interning of IRIs, blank nodes, and literals (RDF-star triple terms included) to stable IDs; bidirectional ID↔term lookup.
- **Permutation indexes**: index layouts (e.g. SPO/POS/OSP and graph-aware variants) supporting wildcard match patterns with streaming iterators.
- **Match interface**: the minimal contract engines consume — match with per-position wildcards, iteration, counts. Deliberately small in v1: match + insert + count; planner support (ordered iteration, cardinality estimates) added when the SPARQL engine demonstrates the need.
- **Bulk load and export**: ingestion from all four odin-rdf-parser formats using the per-statement clone/intern discipline; export through the emitters.
- **LMDB backend**: the implementation of the interface, persistent, with zero-copy reads. *(An in-memory backend was the original reference implementation and was retired 2026-08-07 — STORE-A-0006.)*

## Success Criteria

- odin-rdf-sparql's basic graph pattern evaluation runs against the match interface without interface changes it cannot absorb.
- An application can decide whether to keep a write by examining the dataset that write would produce, and can write several quads as one unit. *(Added 2026-08-07 with STORE-I-0004: it was the one thing this library could not express, and a success criterion is where that belongs. Met — the conformance suite demonstrates it rather than describing it.)*
- Bulk ingestion via odin-rdf-parser works at scale and validates the parser's clone/intern contract in real use (this closes the open success criterion in the parser's vision RDF-V-0001).
- Round-trip: load → match/export → compare preserves data semantics for all four formats.
- The backend passes a store test suite covering set semantics, all match patterns, and dataset/graph edge cases (default vs. named graphs, blank node identity, RDF-star terms). *(Met 2026-08-06 by both backends then shipped; reworded 2026-08-07 when the in-memory one was retired — STORE-A-0006. The suite and its `Backend` adapter are retained so a future backend meets the same criterion.)*
- The public API is documented and idiomatic Odin, with the same contract-level documentation standard as odin-rdf-parser.

## Principles

- **Interface first, minimal**: the match interface starts as small as possible and grows only on evidence from real consumers — expect one revision when SPARQL evaluation lands, and design for that cheaply rather than speculating now.
- **Primitives over frameworks**: storage primitives only; query planning, inference, and validation belong downstream.
- **Idiomatic Odin**: explicit memory management, allocator awareness, straightforward procedural APIs — matching the conventions established in odin-rdf-parser.
- **Zero-copy discipline**: honor the LMDB-compatible borrowing/lifetime model of ADR RDF-A-0001 (odin-rdf-parser); interned terms and mapped pages over defensive copies.
- **Test-suite driven**: correctness is demonstrated by a systematic store test suite and round-trips against the W3C-conformant parser, not by example programs.

## Constraints

- Written in Odin. LMDB is the single external dependency, vendored as C sources and built per platform (STORE-A-0004). It is no longer optional: with the in-memory backend retired (STORE-A-0006), every consumer of this library links it, and every dataset is a filesystem path — LMDB has no anonymous or in-memory mode. The `store` vocabulary package itself still depends on nothing.
- Depends on odin-rdf-parser for the data model, parsing, and serialization; its types (`rdf.Term`, `rdf.Triple`, `rdf.Quad`) are the interchange vocabulary.
- Scope is limited to storage, indexing, and the match interface. SPARQL, SHACL, reasoners, and network/server layers are out of scope — they build on this library.
- Persistence backends other than LMDB are out of scope for now.