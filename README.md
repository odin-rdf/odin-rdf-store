# odin-rdf-store

RDF quad storage for Odin: a dataset of quads over a term dictionary,
with **one match interface** and two backends behind it — `memstore`
in memory and `kvstore` persistent over LMDB. Both pass the same
conformance suite verbatim, at both `Term_ID` widths.

This is the second layer of the family stack —
[odin-rdf-parser](https://github.com/odin-rdf/odin-rdf-parser) (formats
and data model) → this library →
[odin-rdf-sparql](https://github.com/odin-rdf/odin-rdf-sparql) (query)
and [odin-rdf-shacl](https://github.com/odin-rdf/odin-rdf-shacl)
(validation). It is deliberately low-level: it supplies storage,
indexing, and matching. Query planning, inference, and validation are
consumers, not features.

## Packages

| Package          | Description                                                                                          |
| ---------------- | ---------------------------------------------------------------------------------------------------- |
| `store`          | The shared vocabulary: `Term_ID` encoding, `Encoded_Quad`, `Match_Pattern`, and the interface contract |
| `store/memstore` | In-memory reference backend: dictionary, three permutation indexes, bulk loaders. No dependencies      |
| `store/kvstore`  | Persistent backend over LMDB: same procedure set and semantics, durable on disk                        |
| `conformance`    | The executable form of the contract — a backend-agnostic suite both backends instantiate               |

`store` contains no storage itself. The backends are peers of one
interface, bound at compile time by which package you import: a program
that only wants an in-memory dataset never links LMDB.

## The match interface

A backend is a package implementing this procedure set over its own
dataset type (the full contract is in
[`store/interface.odin`](store/interface.odin), decided in ADR
STORE-A-0002):

```odin
dataset_init(ds, allocator)      // prepare an empty dataset
dataset_destroy(ds)              // free everything the dataset owns
insert(ds, quad) -> bool         // add a quad; false if already present
count(ds) -> int                 // number of quads
match(ds, pattern) -> iterator   // stream quads matching a pattern
match_next(&it) -> (quad, ok)    // yield the next match
match_destroy(&it)               // release iterator resources
```

plus the term dictionary its IDs come from: `intern_term` (assign on
first sight), `find_term` (lookup only, never assigns), `lookup_term`
(the reverse direction), and the same three for the graph position.
Backends that can fail against an environment — `kvstore` — also return
an `Error` from the fallible procedures, and their init/destroy take
what persistence requires (a path, options). The names, semantics, and
iteration contract are what the convention fixes.

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

### Load a document and match

```odin
import store "store"
import memstore "store/memstore"
import "rdf:rdf"

d: memstore.Dictionary
memstore.dictionary_init(&d)
defer memstore.dictionary_destroy(&d)

ds: memstore.Dataset
memstore.dataset_init(&ds)
defer memstore.dataset_destroy(&ds)

added, err := memstore.load_turtle(&d, &ds, source) // source: []byte
// added == 3, err.message == ""

// find_term resolves a query's ground term without assigning an ID:
// asking about a term the store has never seen leaves the dictionary
// untouched and reports found=false, which callers short-circuit to
// an empty result.
knows, found := memstore.find_term(&d, rdf.IRI("http://example.org/knows"))

it := memstore.match(&ds, store.Match_Pattern{store.WILDCARD, knows, store.WILDCARD, store.WILDCARD})
defer memstore.match_destroy(&it)
for {
    q, ok := memstore.match_next(&it)
    if !ok {
        break
    }
    subject := memstore.lookup_term(&d, q[store.QUAD_S]).(rdf.IRI)
    // ex:alice and ex:bob, in no guaranteed order
}
```

The four loaders — `load_triples`, `load_turtle`, `load_quads`,
`load_trig` — cover the parser's four formats. Each interns every
statement's terms and inserts the encoded quad one statement at a time,
so nothing borrowed from a parser statement outlives its loop iteration.
Blank node labels are document-scoped: loading two documents that both
say `_:b0` yields two distinct terms.

### Export

There is no export API in v1 — getting data back out is match + decode
+ emit, through the parser's emitters:

```odin
it := memstore.match(&ds, store.MATCH_ALL)
defer memstore.match_destroy(&it)
for {
    q, ok := memstore.match_next(&it)
    if !ok {
        break
    }
    quads_fmt.emit(w, memstore.decode_quad(&d, q)) // w: io.Writer
}
```

### The same dataset, on disk

`kvstore` is the identical procedure set with an `Error` return and a
path:

```odin
import kvstore "store/kvstore"

s, open_err := kvstore.open("/var/lib/mystore")
defer kvstore.close(s)

added, parse_err, load_err := kvstore.load_turtle(s, source)

knows, found, find_err := kvstore.find_term(s, rdf.IRI("http://example.org/knows"))
it, match_err := kvstore.match(s, store.Match_Pattern{store.WILDCARD, knows, store.WILDCARD, store.WILDCARD})
defer kvstore.match_destroy(&it)
for {
    q, ok := kvstore.match_next(&it)
    if !ok {
        break
    }
    // A persistent lookup copies into the caller's allocator, so the
    // term outlives the store and is the caller's to free.
    subject, lookup_err := kvstore.lookup_term(s, q[store.QUAD_S])
    defer rdf.destroy(subject)
}
```

Quads and the dictionary survive process restarts with stable
`Term_ID`s. `insert` commits its own write transaction; `match` opens a
read transaction owned by the iterator and released by `match_destroy`,
so matched quads are views of that MVCC snapshot. Each `load_*` wraps
one document in one write transaction, making a persistent load atomic
per document — a deliberate divergence from the in-memory loaders,
which keep what they inserted before a syntax error.

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
implementing the interface**, and both backends do, at both widths.
`tests/readme` compiles the examples above.

## License

MIT — see [LICENSE](LICENSE).
