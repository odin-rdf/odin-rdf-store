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
// / open_ephemeral(opts) / close over an LMDB environment — two
// constructors differing only in whether the storage outlives the
// process, and identical in everything above. kvstore's operations can also fail
// against that environment, so its fallible procedures return an Error.
// What the convention fixes is the names, the semantics, and the
// iteration contract — not the lifecycle.
//
// Transactions are *not* an exception to that. Opening a store is a
// backend's own nature — a path, a socket, a heap — but what a read
// sees, and when a write becomes visible to it, is the contract itself.
// So the transaction model below is in the set, and the constructors
// that produce a dataset stay out of it.
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
// Transactions and snapshots (STORE-A-0007). Every backend publishes an
// opaque transaction handle — named Txn by the convention, never the
// storage library's own type — and three procedures over it:
//
//	txn_begin(ds, mode) -> Txn      open a transaction; mode is Txn_Mode
//	txn_commit(&t) -> Error         end it, making its writes visible
//	txn_abort(&t)                   end it, discarding them
//
// and a _txn form of every operation above, taking the handle alone:
// insert_txn, count_txn, match_txn, find_term_txn, lookup_term_txn,
// intern_term_txn, the graph-label trio, and the quad codec. **The
// handle carries its dataset**, so a consumer threads one thing rather
// than a pair, and it is a caller-held value with the same lifetime
// discipline an iterator has.
//
// **A read transaction IS a snapshot.** There is no separate snapshot
// concept, no second handle, and nothing in this interface says
// "snapshot": a stable view of the dataset is what a read transaction
// already is, and naming it twice would invent a distinction the
// storage does not have.
//
// The guarantees. Nothing here is conditional, and no backend declares
// its way out of any of it — passing the conformance suite is what
// implementing this interface means:
//
//   - Read-your-own-writes: a read through an open transaction observes
//     that transaction's own uncommitted writes.
//   - Snapshot isolation: a read transaction is a stable view.
//     Concurrent commits do not disturb it, and a reader outside an
//     open write transaction sees the pre-commit dataset. No consumer
//     ever receives a stale or smeared answer — one assembled from two
//     different datasets.
//   - Atomicity over quads: after commit, every quad the transaction
//     wrote is visible; after abort, none is; no intermediate state is
//     observable from outside it. Abort is not removal — it retracts
//     writes nobody ever saw, so the append-only stance (STORE-I-0001
//     decision 5) is intact and remove is still the thing that would
//     change it.
//   - Provisional Term_IDs: an ID assigned by interning inside a
//     transaction is valid only if that transaction commits, and a
//     consumer must discard it on abort. **Whether the term itself
//     stays interned is deliberately unspecified** — atomicity is
//     defined over quads, not over the dictionary. A term interned but
//     never used by a committed quad is invisible through the quad
//     contract: find_term may report it, and matching it yields
//     nothing, which is the correct answer either way. That keeps the
//     dictionary monotonic and keeps abort from having to unwind it.
//   - Single writer, no nesting: at most one write transaction may be
//     open on a dataset handle at a time, and transactions do not nest.
//     A second one is **refused with an error rather than blocked**,
//     because within one handle it can only be a programming error and
//     a deadlock is the worst available diagnostic for one. Between
//     *processes* a backend may serialize writers by blocking, and
//     kvstore does — that is the concurrency the deployment shape
//     actually uses, and this rule does not touch it.
//   - Iterator invalidation: an iterator opened on a transaction is
//     valid until match_destroy, a **write through that same
//     transaction**, or that transaction's commit or abort — whichever
//     comes first. Writing through a transaction invalidates every
//     iterator open on it. This extends the rule below rather than
//     replacing it, and it **forbids the combination rather than
//     defining it**: what a surviving iterator would yield across a
//     write is not specified, so the cheapest correct implementation
//     stays available.
//
// **The bare procedures are autocommit**, and that is now a definition
// rather than a description of how they happen to work: insert, count,
// match, find_term, lookup_term, intern_term and the rest each open a
// transaction of the appropriate mode, perform the one operation, and
// close it. A consumer that never opens a transaction therefore gets
// every guarantee above, one operation at a time — which is exactly
// what it got before, unchanged in name, signature and meaning. What
// such a consumer does *not* get is any relationship between two
// operations: two matches are two snapshots, and a validator run
// between a write and its commit cannot see the write, because there is
// no "between".
//
// Two costs are part of this contract rather than backend detail. With
// one shipped backend the interface's semantics are that backend's
// semantics by definition (STORE-A-0006), so there is no portable
// subset to hide them behind:
//
//   - An open read transaction pins storage. A long-held snapshot makes
//     a concurrent writer consume more space, because what the reader
//     can still see cannot be reused. Holding a snapshot for the life of
//     a query is fine; holding one for the life of a request handler is
//     a storage-sizing decision.
//   - An open write transaction serializes every other writer against
//     that dataset for its lifetime. The consumer this model exists for
//     — validate a candidate against the dataset it would produce, then
//     commit or abort — holds one across the whole validation *by
//     construction*, since read-your-own-writes is the point. Those
//     transactions are long by design. Validating under a read
//     transaction instead is not equivalent; it is precisely the window
//     the model closes.
//
// The bulk loaders are outside this contract — they are a backend's own
// convenience over its parser, not part of the procedure set — but
// kvstore gives them `_txn` forms on the same principle, with one
// inversion worth knowing about if a second backend copies the shape:
// a bare loader is atomic per document because it owns its transaction,
// and a `_txn` loader **cannot be**, because ending the caller's
// transaction is not its to do. See store/kvstore/load.odin.
//
// The _txn suffix marks what is really the primary API, which is
// backwards, and it stays. The alternative is giving the transactional
// forms the plain names, which renames every procedure the query and
// validation engines already call. Additive and ugly beats elegant and
// breaking.
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
//     the read transaction it reads through. An iterator is valid only
//     until its dataset is mutated or destroyed; see the transaction
//     model above for the rest of the rule, which adds a write through
//     the iterator's own transaction and that transaction's end. An
//     iterator from bare match owns the transaction it opened and
//     releases it at match_destroy; one from match_txn borrows the
//     caller's and leaves it alone.
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

// Txn_Mode is what a transaction may do. It lives here rather than in
// each backend because it carries no backend content at all — the same
// two words would otherwise be declared identically in every one of
// them, the way Load_Error would be. The transaction *handle* stays
// per-backend, since it holds that backend's state.
//
// The distinction is a value, not a type: a write attempted on a .Read
// transaction is a runtime error rather than a compile error. A type
// per mode would catch it earlier at the price of two lifetimes and two
// sets of read procedures, which is the shape STORE-A-0007 rejected.
Txn_Mode :: enum {
	// A stable view of the dataset: the snapshot.
	Read,
	// A view that can be written and that reads its own writes. At most
	// one is open on a dataset at a time.
	Write,
}

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
