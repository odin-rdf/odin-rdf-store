// Package store is the shared vocabulary of the odin-rdf-store family:
// the Term_ID encoding, the encoded-quad and match-pattern types, and
// the match interface contract (interface.odin) that every backend
// implements. It contains no storage itself — the backends live in the
// subdirectory packages, as peers of one interface:
//
//   - store/memstore — the in-memory reference backend: dictionary,
//     permutation-indexed dataset, bulk loaders. No dependencies.
//   - store/kvstore  — the persistent backend over LMDB: the same
//     procedure set and semantics, durable on disk (ADR STORE-A-0003).
//
// The conformance package is the executable form of the contract; both
// backends instantiate it, and a new backend proves itself by doing
// the same. Downstream engines (odin-rdf-sparql, odin-rdf-shacl)
// import this package for the vocabulary plus whichever backend the
// caller picks.
//
// Term_ID encoding (ADR STORE-A-0001): a Term_ID is a fixed-width
// unsigned integer whose top TAG_BITS bits carry the term kind and
// whose remaining bits carry a dense per-kind counter assigned in
// first-seen order. Kind is therefore readable from the ID alone, and
// IDs of the same kind are numerically contiguous. The width is a
// build-time choice:
//
//	odin build . -define:RDF_STORE_TERM_ID_BITS=32
//
// selects a 32-bit ID space (16-byte encoded quads, ~2^29 terms per
// kind); the default is 64. Persistent backends must record the width
// they were written with and refuse to open under the other width.
package store

// TERM_ID_BITS is the build-time Term_ID width in bits: 32 or 64.
TERM_ID_BITS :: #config(RDF_STORE_TERM_ID_BITS, 64)

when TERM_ID_BITS == 32 {
	Term_ID :: distinct u32
} else when TERM_ID_BITS == 64 {
	Term_ID :: distinct u64
} else {
	#panic("RDF_STORE_TERM_ID_BITS must be 32 or 64")
}

// Term_Kind is the tag stored in a Term_ID's high bits. The four real
// kinds mirror the variants of rdf.Term. The Sentinel tag carries
// reserved IDs (DEFAULT_GRAPH, WILDCARD) that the dictionary never
// assigns to a term; tag values above Sentinel are reserved for future
// kinds.
Term_Kind :: enum u8 {
	IRI        = 0,
	Blank_Node = 1,
	Literal    = 2,
	Triple     = 3,
	Sentinel   = 4,
}

TAG_BITS :: 3

// COUNTER_BITS and the values below are derived from the ID width;
// nothing outside the `when` block above mentions a concrete width.
COUNTER_BITS :: 8*size_of(Term_ID) - TAG_BITS
COUNTER_MASK :: (Term_ID(1) << COUNTER_BITS) - 1

// MAX_COUNTER is the largest counter a Term_ID can carry; per-kind
// capacity is MAX_COUNTER + 1.
MAX_COUNTER :: u64(COUNTER_MASK)

// DEFAULT_GRAPH is the reserved ID standing, in the graph position of
// an Encoded_Quad, for the dataset's default graph (a nil
// rdf.Graph_Label).
DEFAULT_GRAPH :: Term_ID(Term_Kind.Sentinel) << COUNTER_BITS | 0

// WILDCARD is the reserved ID standing, in a match pattern, for "any
// term in this position". It never appears inside a stored quad.
WILDCARD :: Term_ID(Term_Kind.Sentinel) << COUNTER_BITS | 1

// make_id builds the ID of the counter-th term of a kind. Counters
// beyond MAX_COUNTER cannot be represented; callers that assign
// counters (the dictionary) must check capacity first — this assert is
// the last line of defense, not an error path.
make_id :: proc(kind: Term_Kind, counter: u64) -> Term_ID {
	assert(counter <= MAX_COUNTER, "Term_ID counter overflow")
	return Term_ID(kind) << COUNTER_BITS | Term_ID(counter)
}

// id_kind extracts the kind tag of an ID.
id_kind :: proc(id: Term_ID) -> Term_Kind {
	return Term_Kind(id >> COUNTER_BITS)
}

// id_counter extracts the dense per-kind counter of an ID — the index
// into the dictionary's per-kind entry array.
id_counter :: proc(id: Term_ID) -> u64 {
	return u64(id & COUNTER_MASK)
}

// Encoded_Quad is a quad over term IDs, indexed by QUAD_S/P/O/G. The
// graph position holds DEFAULT_GRAPH for default-graph quads. All
// dataset index structures operate on these fixed-size tuples only.
Encoded_Quad :: [4]Term_ID

QUAD_S :: 0
QUAD_P :: 1
QUAD_O :: 2
QUAD_G :: 3

// encoded_quad_compare orders quads positionally (s, p, o, g) by
// numeric ID: -1, 0, or +1. This is the shared canonical ordering of
// STORE-A-0001 — for any position permutation, numeric ID order equals
// memcmp order over big-endian-serialized keys, so every backend that
// compares positions numerically agrees on iteration order.
encoded_quad_compare :: proc(a, b: Encoded_Quad) -> int {
	for i in 0 ..< 4 {
		if a[i] < b[i] {return -1}
		if a[i] > b[i] {return +1}
	}
	return 0
}
