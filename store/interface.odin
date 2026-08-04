package store

// Match interface contract (STORE-A-0002), v1.
//
// A dataset backend is a package implementing this procedure set over
// its own dataset type — this repo ships two: store/memstore (the
// in-memory reference) and store/kvstore (persistent, LMDB):
//
//	dataset_init(ds, allocator)      prepare an empty dataset
//	dataset_destroy(ds)              free everything the dataset owns
//	insert(ds, quad) -> bool         add a quad; false if already present
//	count(ds) -> int                 number of quads in the dataset
//	match(ds, pattern) -> iterator   stream quads matching a pattern
//	match_next(&it) -> (quad, ok)    yield the next match; ok=false when done
//	match_destroy(&it)               release iterator resources
//
// Backends whose operations can fail against an environment (kvstore)
// also return an Error from the fallible procedures; init/destroy may
// take backend-specific parameters (a path, options). The names,
// semantics, and iteration contract are what the convention fixes.
//
// Semantics every backend must satisfy (the conformance package is
// the executable form of this contract; backends instantiate it as
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
//     when done with an iterator (persistent backends hold cursors).
//     An iterator is valid only until its dataset is mutated or
//     destroyed.
//   - Ordering: v1 guarantees nothing about the order matches are
//     yielded in. Expected to be revised when the SPARQL planner
//     arrives (STORE-A-0002 review triggers).
//   - Stored quads must not contain WILDCARD, and the graph position
//     must be an IRI ID, a blank-node ID, or DEFAULT_GRAPH. Term-kind
//     validity per the RDF grammars (e.g. no literal subjects) is the
//     producer's concern, mirroring rdf.Triple's posture.
//   - remove does not exist in v1 (append-only; STORE-I-0001 decision
//     5). When added it will be specified as logical visibility: after
//     remove returns, the quad is absent from subsequent matches and
//     counts — with no promise of physical erasure, so tombstone-based
//     backends conform.
//   - Allocators: dataset_init takes the allocator all dataset memory
//     comes from (where meaningful for the backend).

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
