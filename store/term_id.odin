// Package store provides the odin-rdf-store storage core: a term
// dictionary interning RDF terms to fixed-size IDs, an in-memory quad
// dataset behind the match interface downstream engines consume, and
// bulk ingestion from the odin-rdf-parser formats.
//
// The pieces and how they stack:
//
//   - Dictionary (dictionary.odin) interns rdf.Term values to Term_IDs
//     and looks them back up; encode_quad/decode_quad translate whole
//     quads. Interning clones borrowed strings, so parser output can be
//     interned statement by statement (ADR RDF-A-0001).
//   - Dataset (dataset.odin) stores encoded quads with set semantics —
//     one default graph plus named graphs — and answers
//     match(s, p, o, g) patterns with per-position wildcards through
//     streaming iterators. The procedure set and its semantics are the
//     match interface contract (ADR STORE-A-0002) that later backends
//     (LMDB) implement identically; see the contract comment in
//     dataset.odin. The dataset is append-only in v1: remove is
//     specified (logical visibility) but not yet provided.
//   - load_triples/load_quads/load_turtle/load_trig (load.odin) bulk-
//     load documents via the parsers' pull loops, giving each load its
//     own blank-node scope.
//
// Lifetime rules: terms returned by lookup_term/decode_quad borrow
// their strings from dictionary storage and stay valid until
// dictionary_destroy — no other operation invalidates them. Iterators
// are valid until their dataset is mutated or destroyed. Every *_init
// takes `allocator := context.allocator` and owns what it allocates
// until the matching *_destroy.
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
