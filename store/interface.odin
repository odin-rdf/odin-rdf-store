package store

// Match interface contract (STORE-A-0002), v1.
//
// A dataset backend is a package implementing this procedure set over
// its own dataset type. This repo ships one — store/kvstore, over LMDB —
// so what follows is both the convention and a description of it. The
// convention is kept separate from the backend so a second one can be
// added without renegotiating it (STORE-A-0002, STORE-A-0006):
//
//	insert(ds, quad) -> bool         add a quad; false if already present
//	count(ds) -> int                 number of quads in the dataset
//	match(ds, pattern) -> iterator   stream quads matching a pattern
//	match_next(&it) -> (quad, ok)    yield the next match; ok=false when done
//	match_destroy(&it)               release iterator resources
//
// Opening and closing a dataset is deliberately not in the set: it is
// where a backend's own nature shows, and kvstore's is open(path, opts)
// / close over an LMDB environment. kvstore's operations can also fail
// against that environment, so its fallible procedures return an Error.
// What the convention fixes is the names, the semantics, and the
// iteration contract — not the lifecycle.
//
// Every backend also implements the term dictionary its IDs come from —
// the same convention, over whatever the backend calls its dictionary
// handle:
//
//	intern_term(d, term) -> Term_ID           assign on first sight
//	find_term(d, term) -> (Term_ID, bool)     lookup only; never assigns
//	lookup_term(d, id) -> rdf.Term            the reverse direction
//	intern_graph_label / find_graph_label / lookup_graph_label
//	                                          the same three for the
//	                                          graph position, where a nil
//	                                          label is DEFAULT_GRAPH
//
// find_term is the query path's entry point. An engine resolving a
// query's ground terms to IDs asks about terms the store may never have
// seen, and getting an ID for one of them would be wrong twice over: it
// pollutes the dictionary, and it makes reading a write. So find_term
// assigns nothing and writes nothing — it serves from a read
// transaction and works against a read-only environment. An absent term
// reports found=false, which a caller short-circuits to an empty result.
//
// Semantics every backend must satisfy (the conformance package is
// the executable form of this contract; a backend instantiates it as
// described there):
//
//   - Set semantics: a dataset holds a set of quads. Re-inserting an
//     existing quad is a no-op returning false.
//   - Patterns: a Match_Pattern binds each of subject, predicate,
//     object, and graph to a Term_ID or leaves it WILDCARD. A quad
//     matches iff every bound position equals the quad's ID.
//     DEFAULT_GRAPH in the graph position selects exactly the default
//     graph; WILDCARD there spans default and named graphs alike.
//   - Streaming: match yields one encoded quad per match_next call and
//     never materializes result sets. After the first ok=false, every
//     further call returns ok=false. Callers must call match_destroy
//     when done with an iterator — kvstore's holds an LMDB cursor and
//     the read transaction it was opened in. An iterator is valid only
//     until its dataset is mutated or destroyed.
//   - Ordering: v1 guarantees nothing about the order matches are
//     yielded in. Expected to be revised when the SPARQL planner
//     arrives (STORE-A-0002 review triggers).
//   - UNBOUND belongs to the layer above: unlike DEFAULT_GRAPH and
//     WILDCARD it is valid in neither a stored quad nor a pattern, and
//     no backend ever produces or accepts one.
//   - Stored quads must not contain WILDCARD, and the graph position
//     must be an IRI ID, a blank-node ID, or DEFAULT_GRAPH. Term-kind
//     validity per the RDF grammars (e.g. no literal subjects) is the
//     producer's concern, mirroring rdf.Triple's posture.
//   - remove does not exist in v1 (append-only; STORE-I-0001 decision
//     5). When added it will be specified as logical visibility: after
//     remove returns, the quad is absent from subsequent matches and
//     counts — with no promise of physical erasure, so tombstone-based
//     backends conform.
//   - Allocators: a backend's open procedure takes the allocator its
//     handle and bookkeeping come from, and the procedures that hand a
//     term back — lookup_term, lookup_graph_label, decode_quad — take
//     the allocator that term is built in and leave it to the caller to
//     free. kvstore's quads and dictionary entries themselves live in
//     mapped pages rather than in any allocator.

// Match_Pattern is a quad pattern: per position, a bound Term_ID or
// WILDCARD. Position indices are QUAD_S/P/O/G, as for Encoded_Quad.
Match_Pattern :: distinct [4]Term_ID

// MATCH_ALL matches every quad in the dataset.
MATCH_ALL :: Match_Pattern{WILDCARD, WILDCARD, WILDCARD, WILDCARD}

// pattern_matches reports whether a quad satisfies a pattern: every
// bound (non-WILDCARD) position must equal the quad's ID.
pattern_matches :: proc(p: Match_Pattern, q: Encoded_Quad) -> bool {
	for i in 0 ..< 4 {
		if p[i] != WILDCARD && p[i] != q[i] {
			return false
		}
	}
	return true
}

// Load_Error reports a failed bulk load in any backend's load_*
// procedures. message is "" on success, otherwise a static description
// (the parser's spec-referencing error text) with the 1-based source
// position.
Load_Error :: struct {
	message: string,
	line:    int,
	column:  int,
}
