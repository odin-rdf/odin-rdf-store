# odin-rdf-store

[![CI](https://github.com/odin-rdf/odin-rdf-store/actions/workflows/ci.yml/badge.svg)](https://github.com/odin-rdf/odin-rdf-store/actions/workflows/ci.yml)

RDF quad storage for Odin: a dataset of quads over a term dictionary,
with **one match interface** and `kvstore`, persistent over LMDB,
behind it. It passes the conformance suite that is the executable form
of that interface, at both `Term_ID` widths.

This is the second layer of the family stack —
[odin-rdf-parser](https://github.com/odin-rdf/odin-rdf-parser) (formats
and data model) → this library →
[odin-rdf-sparql](https://github.com/odin-rdf/odin-rdf-sparql) (query)
and [odin-rdf-shacl](https://github.com/odin-rdf/odin-rdf-shacl)
(validation). It is deliberately low-level: it supplies storage,
indexing, and matching. Query planning, inference, and validation are
consumers, not features.

## Packages

| Package         | Description                                                                                           |
| --------------- | ----------------------------------------------------------------------------------------------------- |
| `store`         | The shared vocabulary: `Term_ID` encoding, `Encoded_Quad`, `Match_Pattern`, and the interface contract |
| `store/kvstore` | The backend over LMDB: dictionary, three permutation indexes, bulk loaders, durable on disk            |
| `conformance`   | The executable form of the contract — a backend-agnostic suite that `kvstore` instantiates             |

`store` contains no storage itself. An in-memory backend came first and
was the reference the interface was defined against; it was retired on
2026-08-07 ([ADR STORE-A-0006](.metis/adrs/STORE-A-0006.md)) because no
consumer outside the test suites ever asked for one, and because the
transaction model the query and validation layers need came out shaped
by accommodating it. Two consequences are worth stating plainly rather
than leaving to be discovered: **every consumer of this library links
LMDB**, and **every dataset is a filesystem path** — LMDB has no
anonymous or in-memory mode. The `store` / `store/kvstore` split and the
`conformance` adapter are kept so a second backend can be added on
evidence.

## The match interface

A backend is a package implementing this procedure set over its own
dataset type (the full contract is in
[`store/interface.odin`](store/interface.odin), decided in ADR
STORE-A-0002):

```odin
insert(ds, quad) -> bool         // add a quad; false if already present
count(ds) -> int                 // number of quads
match(ds, pattern) -> iterator   // stream quads matching a pattern
match_next(&it) -> (quad, ok)    // yield the next match
match_destroy(&it)               // release iterator resources
```

plus the term dictionary its IDs come from: `intern_term` (assign on
first sight), `find_term` (lookup only, never assigns), `lookup_term`
(the reverse direction), and the same three for the graph position.
Opening and closing a dataset is deliberately outside the set — it is
where a backend's own nature shows, and `kvstore`'s is `open(path,
opts)` / `close`. `kvstore`'s operations can fail against its
environment, so its fallible procedures return an `Error`. The names,
semantics, and iteration contract are what the convention fixes; the
lifecycle is not.

The contract in brief:

- **Set semantics.** Re-inserting an existing quad is a no-op returning
  `false`.
- **Patterns.** A `Match_Pattern` binds each of subject, predicate,
  object, and graph to a `Term_ID` or leaves it `WILDCARD`. A quad
  matches iff every bound position is equal. `DEFAULT_GRAPH` in the
  graph position selects exactly the default graph; `WILDCARD` there
  spans default and named graphs alike.
- **Streaming.** `match` yields one quad per `match_next` and never
  materializes a result set. Iterators are valid until the dataset is
  mutated or destroyed, and must be released with `match_destroy`.
- **Ordering.** v1 guarantees nothing about the order matches arrive
  in. Expected to be revised once the SPARQL planner has evidence.
- **No `remove` in v1.** The store is append-only.

## Quick start

### Open a store, load a document, match

```odin
import store "store"
import kvstore "store/kvstore"
import "rdf:rdf"

s, open_err := kvstore.open("/var/lib/mystore")
defer kvstore.close(s)

added, parse_err, load_err := kvstore.load_turtle(s, source) // source: []byte
// added == 3, parse_err.message == ""

// find_term resolves a query's ground term without assigning an ID:
// asking about a term the store has never seen leaves the dictionary
// untouched and reports found=false, which callers short-circuit to
// an empty result.
knows, found, find_err := kvstore.find_term(s, rdf.IRI("http://example.org/knows"))

it, match_err := kvstore.match(s, store.Match_Pattern{store.WILDCARD, knows, store.WILDCARD, store.WILDCARD})
defer kvstore.match_destroy(&it)
for {
    q, ok := kvstore.match_next(&it)
    if !ok {
        break
    }
    // A lookup copies the term into the caller's allocator, so it
    // outlives the store and is the caller's to free.
    subject, lookup_err := kvstore.lookup_term(s, q[store.QUAD_S])
    defer rdf.destroy(subject)
    // ex:alice and ex:bob, in no guaranteed order
}
```

The store is a directory LMDB owns, and quads and the dictionary survive
process restarts with stable `Term_ID`s. `insert` commits its own write
transaction; `match` opens a read transaction owned by the iterator and
released by `match_destroy`, so matched quads are views of that MVCC
snapshot for as long as the iterator lives.

The four loaders — `load_triples`, `load_turtle`, `load_quads`,
`load_trig` — cover the parser's four formats. Each interns every
statement's terms and inserts the encoded quad one statement at a time,
so nothing borrowed from a parser statement outlives its loop iteration,
and each wraps one document in one write transaction, so a load is
atomic per document: a syntax error at the last statement leaves the
store as it was. Blank node labels are document-scoped: loading two
documents that both say `_:b0` yields two distinct terms.

### A store that dies with the process

`open_ephemeral` is the same store with a different storage lifetime:
no path to name, make unique, or clean up.

```odin
s, open_err := kvstore.open_ephemeral()
defer kvstore.close(s)
// ... identical from here: load_turtle, match, find_term, lookup_term
```

The database is one file with no lock file, and on POSIX it is unlinked
as soon as it is open: invisible in the filesystem for the store's whole
life, and reclaimed by the kernel on close *or on crash*. Windows has no
unlink-while-open, so the file survives until `close` deletes it and an
abnormal termination leaks exactly one file.

Its default map is 16 MiB rather than `DEFAULT_OPTIONS`' 1 GiB, which is
not only tidiness: on Windows LMDB has no sparse-file handling, so every
open materializes `map_size` on disk in full. A harness that opens a
store per test wants this constructor. Pass a larger `Options.map_size`
for a scratch load bigger than the 16 MiB default expects.

`NOLOCK` makes an ephemeral store exclusively the opening process's —
correct, since no other process can find the file, and unsafe if the
handle is passed to a child.

### Export

There is no export API in v1 — getting data back out is match + decode
+ emit, through the parser's emitters:

```odin
it, match_err := kvstore.match(s, store.MATCH_ALL)
defer kvstore.match_destroy(&it)
for {
    q, ok := kvstore.match_next(&it)
    if !ok {
        break
    }
    decoded, decode_err := kvstore.decode_quad(s, q, context.temp_allocator)
    quads_fmt.emit(w, decoded) // w: io.Writer
}
free_all(context.temp_allocator)
```

## Term IDs

A `Term_ID` is a fixed-width unsigned integer whose top 3 bits carry the
term kind and whose remaining bits carry a dense per-kind counter
assigned in first-seen order (ADR STORE-A-0001). Two consequences the
layers above depend on: a term's kind is readable from the ID alone
without touching the dictionary, and joins and dedup are integer
comparisons rather than string comparisons.

Three sentinel IDs are never assigned to a term: `DEFAULT_GRAPH` (the
default graph, in the graph position), `WILDCARD` (any term, in a
pattern), and `UNBOUND` — which belongs to the layer above and is valid
in neither a stored quad nor a pattern, reserved here so no future
sentinel takes it out from under a consumer.

The width is a build-time choice:

```sh
odin build . -define:RDF_STORE_TERM_ID_BITS=32
```

selects a 32-bit ID space (16-byte encoded quads, ~2^29 terms per kind);
the default is 64. A persistent database records the width it was
written with and refuses to open under the other one — widths never mix
silently.

## Conformance and testing

```sh
make test    # the full suite at both Term_ID widths
make check   # vet every package at the default width
make bench   # throughput benchmarks, release flags
```

The parser is a sibling checkout rather than a vendored copy, reached
through a collection (`-collection:rdf=../odin-rdf-parser`, declared in
the `Makefile` and `ols.json`), so the two repositories must sit side by
side on disk.

The [`conformance`](conformance) package is the executable form of the
match contract: all 16 bound/wildcard pattern combinations, set
semantics, and the dataset/graph edge cases — default vs. named graphs,
blank-node identity, RDF-star triple terms. A backend adopts it by
filling in a small adapter and declaring one test wrapper per check; the
indirection stays in test code, so the public APIs remain
convention-based. **Passing it verbatim is the definition of
implementing the interface**, and `kvstore` does, at both widths. With
one backend it is a regression suite rather than the portability proof
it was while there were two; the adapter is kept unchanged so a second
backend can restore that. `tests/readme` compiles the examples above.

## Releases

Version history and breaking changes are in [CHANGELOG.md](CHANGELOG.md). Note that
**0.2.0 removed `store/memstore`**, the in-memory backend, with no deprecation path — see
that entry before upgrading from 0.1.x.

## License

MIT — see [LICENSE](LICENSE).
