---
id: 001-match-interface-shape-procedure
level: adr
title: "Match interface shape: procedure-set convention with shared conformance suite"
number: 1
short_code: "STORE-A-0002"
created_at: 2026-08-04T17:28:50.406904+00:00
updated_at: 2026-08-04T17:42:07.623378+00:00
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

# ADR-1: Match interface shape: procedure-set convention with shared conformance suite

## Context **[REQUIRED]**

The odin-rdf-store vision promises "multiple backends of one interface": the match interface that odin-rdf-sparql and odin-rdf-shacl program against, implemented first in memory (STORE-I-0001) and later over LMDB. Odin has no language-level interfaces, traits, or vtables, so "one interface, several implementations" must be a deliberate construction. The choice shapes the signature of every downstream engine, which is why it is recorded as an ADR before any backend code exists.

The contract to express is deliberately minimal in v1 (vision principle: grow on evidence): **match + insert + count**, where match takes a pattern of four positions (subject, predicate, object, graph), each a bound `Term_ID` or a wildcard, and returns a streaming iterator of encoded quads. `remove` is deferred (STORE-I-0001 decision 5, append-only v1) but its future contract must already be shaped so a planned append-only time-travelling variant can conform.

Precedent in the family: odin-rdf-parser exposes four parsers (N-Triples, N-Quads, Turtle, TriG) as four packages implementing one documented API shape — same procedure names, same pull contract, same lifetime rules — with no shared type-level abstraction. Conformance is enforced by documentation and a shared W3C test harness, and it has held across 1045 tests.

## Decision **[REQUIRED]**

The match interface is a **documented procedure-set convention enforced by a shared conformance test suite**, not a type-level abstraction:

1. **Convention**: each backend is a package exposing the same procedure set with the same names, signatures (modulo the backend's own dataset type as the first parameter), and documented contracts — v1: `dataset_init`/`dataset_destroy`, `insert`, `count`, `match` returning an iterator, and iterator `next`/`destroy`. Exact naming is settled in implementation with odin-rdf-parser's conventions as the guide.
2. **One contract document**: the interface's semantics — pattern matching rules, set semantics, iterator validity and exhaustion behavior, allocator obligations, iteration order guarantees (none in v1) — live in one place (the in-memory package's doc comment, referenced by later backends), at the contract-level documentation standard of odin-rdf-parser.
3. **Shared conformance suite as the enforcement mechanism**: the test suite covering all 16 match patterns, set semantics, and graph/term edge cases is written against the convention, structured so a new backend runs the identical suite. Passing it is the definition of implementing the interface.
4. **No procedure-pointer struct in v1**: no `Dataset_Interface` vtable. If a consumer ever needs runtime backend polymorphism ("any store" held dynamically), a vtable-style adapter can be layered over the convention later without changing any backend — the reverse (removing a vtable from hot paths) is not possible.
5. **`remove` is specified now, implemented later**: the contract document defines `remove` as a **logical visibility** operation — after it returns, the quad is absent from subsequent matches and counts — with no promise of physical erasure. Physical deletion (in-memory), and tombstone/validity-interval append (the planned time-travelling variant) are both conforming implementations.
6. **Iterators stream**: match results are yielded one encoded quad at a time; no materialized result collections in the interface. Decoding IDs to `rdf.Term` is a separate dictionary operation, not part of match.

## Alternatives Analysis **[CONDITIONAL: Complex Decision]**

| Option | Pros | Cons | Risk Level | Implementation Cost |
|--------|------|------|------------|-------------------|
| Procedure-set convention + conformance suite (chosen) | Zero runtime overhead; idiomatic Odin; proven in odin-rdf-parser; vtable adapter can be added later | No compiler-checked conformance; consumers bind to a concrete backend type (or go parametric themselves) | Low | Low |
| Struct of procedure pointers (vtable) | True runtime polymorphism; engines take `^Dataset_Interface`; compiler-checked shape | Indirect calls in the hottest loop (match/next); un-idiomatic; context/data pointer plumbing; can't be removed later | Medium | Medium |
| Parametric polymorphism (`$T` generics) | Compile-time checked per instantiation; no indirection | Every consumer procedure becomes generic; error messages at a distance; still convention-defined semantics | Medium | Medium |
| Single concrete type, no abstraction | Simplest possible v1 | LMDB backend would force either an API break or retrofitting one of the above under time pressure | High | Low now, High later |

## Rationale **[REQUIRED]**

- **The hot loop decides**: `match`/`next` is the innermost loop of every future SPARQL join. The convention keeps those calls direct and inlinable; a vtable would put an indirect call inside it forever, purchased for a "hold any store" capability no planned consumer needs — engines know their backend at compile time.
- **The precedent works**: odin-rdf-parser's four-parsers-one-shape arrangement demonstrates that documentation plus a shared test harness holds a convention stable in this codebase family. The conformance suite is a stronger checker than a vtable anyway: a procedure-pointer struct checks signatures, the suite checks semantics.
- **Asymmetric reversibility**: convention → vtable adapter is a small additive wrapper; vtable → convention is a breaking change to every consumer. Choosing the reversible side is consistent with the vision's "interface grows on evidence" principle.
- **Specifying `remove` as logical visibility now** costs one paragraph and keeps two known future backends (LMDB, time-travelling append-only) conforming without contract revision — the alternative (specifying physical deletion) would wall off the time-travel design already on the roadmap.

## Consequences **[REQUIRED]**

### Positive
- Direct, inlinable calls in match/iterate hot paths for every backend.
- A new backend's definition of done is mechanical: run the conformance suite.
- The contract document doubles as the public API documentation downstream engines read.
- LMDB backend and time-travelling variant slot in without interface changes.

### Negative
- Conformance is not compiler-enforced: a backend can drift in signature or semantics and only the suite (or a consumer) catches it. Mitigation: the suite is a deliverable of STORE-I-0001, not an afterthought.
- Consumers that genuinely want runtime backend selection must wait for (or write) the adapter layer.

### Neutral
- odin-rdf-sparql will bind to a concrete backend type in its first iteration; if it later goes parametric or needs the adapter, that is the "one interface revision when SPARQL lands" the vision already budgets.
- The expected interface revision (ordered iteration, cardinality estimates for the planner) will extend the procedure set; the conformance suite grows with it.

## Amendments

- **2026-08-04**: With the second backend implemented, the shared vocabulary (Term_ID encoding, Encoded_Quad, Match_Pattern, the contract document, Load_Error) moved from the in-memory package into a dedicated core package `store`, with the backends as subdirectory packages `store/memstore` and `store/kvstore` — peers of one interface (STORE-T-0013). This supersedes point 2's placement ("the in-memory package's doc comment"): the contract now lives in `store/interface.odin`. The decision itself — procedure-set convention enforced by the shared conformance suite — is unchanged, and was validated by the kvstore backend passing the suite verbatim.

## Review Schedule **[CONDITIONAL: Temporary Decision]**

### Review Triggers
- odin-rdf-sparql's basic graph pattern evaluation lands and demonstrates needs the convention cannot absorb (the vision's budgeted revision point).
- A consumer demonstrates a concrete need for runtime backend polymorphism — triggers designing the vtable adapter, not revisiting the convention.
- The LMDB backend begins and reveals a contract ambiguity the conformance suite did not pin down.