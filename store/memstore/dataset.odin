package memstore

import "base:runtime"
import "core:slice"

import store ".."

// Dataset is the in-memory implementation of the match interface (see
// the contract in store/interface.odin): three sorted-array
// permutation indexes over encoded quads (STORE-I-0001 decisions 2
// and 3), each holding every quad in a different position order.
//
// Pattern -> index dispatch. match picks the index with the longest
// leading run of bound positions and range-scans it; positions outside
// that prefix are filtered during iteration. With bound graph, every
// s/p/o combination gets a contiguous range:
//
//	bound positions   index  range prefix   filtered
//	g                 GSPO   g              -
//	g,s               GSPO   g,s            -
//	g,p               GPOS   g,p            -
//	g,o               GOSP   g,o            -
//	g,s,p             GSPO   g,s,p          -
//	g,s,o             GOSP   g,o,s          -
//	g,p,o             GPOS   g,p,o          -
//	g,s,p,o           GSPO   exact point    -
//
// With WILDCARD graph, no index has a usable prefix (all three lead
// with G), so match degrades to a full scan of GSPO with filtering —
// the accepted v1 trade-off of the three-index layout; graph-last
// permutations (SPOG/POSG/OSPG) are the future remedy if profiling
// demands (STORE-I-0001 decision 2).
//
// Insert strategy (chosen on benchmark evidence, see STORE-T-0006):
// membership is a hash set, so insert is O(1) — new quads accumulate
// in a pending buffer and are sorted and merged into the three index
// arrays lazily when the next match runs. Bulk load is therefore
// O(n log n) total instead of O(n²) sorted-insertion.
Dataset :: struct {
	allocator: runtime.Allocator,
	set:       map[store.Encoded_Quad]struct {},
	pending:   [dynamic]store.Encoded_Quad,
	gspo:      [dynamic]store.Encoded_Quad,
	gpos:      [dynamic]store.Encoded_Quad,
	gosp:      [dynamic]store.Encoded_Quad,
}

// Position orders of the three indexes. Comparing all four positions
// makes each ordering total, so binary search needs no tie-breaking.
@(private)
PERM_GSPO :: [4]int{store.QUAD_G, store.QUAD_S, store.QUAD_P, store.QUAD_O}
@(private)
PERM_GPOS :: [4]int{store.QUAD_G, store.QUAD_P, store.QUAD_O, store.QUAD_S}
@(private)
PERM_GOSP :: [4]int{store.QUAD_G, store.QUAD_O, store.QUAD_S, store.QUAD_P}

// dataset_init prepares an empty dataset; all dataset memory comes
// from the given allocator.
dataset_init :: proc(ds: ^Dataset, allocator := context.allocator) {
	ds.allocator = allocator
	ds.set = make(map[store.Encoded_Quad]struct {}, 8, allocator)
	ds.pending = make([dynamic]store.Encoded_Quad, 0, 8, allocator)
	ds.gspo = make([dynamic]store.Encoded_Quad, 0, 8, allocator)
	ds.gpos = make([dynamic]store.Encoded_Quad, 0, 8, allocator)
	ds.gosp = make([dynamic]store.Encoded_Quad, 0, 8, allocator)
}

// dataset_destroy frees everything the dataset owns; live iterators
// become invalid.
dataset_destroy :: proc(ds: ^Dataset) {
	delete(ds.set)
	delete(ds.pending)
	delete(ds.gspo)
	delete(ds.gpos)
	delete(ds.gosp)
	ds^ = {}
}

// permuted_compare orders two quads by the positions in perm.
@(private)
permuted_compare :: proc(a, b: store.Encoded_Quad, perm: [4]int) -> int {
	for pos in perm {
		if a[pos] < b[pos] {return -1}
		if a[pos] > b[pos] {return +1}
	}
	return 0
}

// insert adds a quad, returning whether it was newly added (false: the
// quad was already present, nothing changed). New quads are buffered;
// the indexes absorb them on the next match (see Dataset).
insert :: proc(ds: ^Dataset, q: store.Encoded_Quad) -> bool {
	for id in q {
		assert(id != store.WILDCARD, "insert: WILDCARD in stored quad")
	}
	if q in ds.set {
		return false
	}
	ds.set[q] = {}
	append(&ds.pending, q)
	return true
}

// count returns the number of quads in the dataset.
count :: proc(ds: ^Dataset) -> int {
	return len(ds.set)
}

@(private)
less_gspo :: proc(a, b: store.Encoded_Quad) -> bool {return permuted_compare(a, b, PERM_GSPO) < 0}
@(private)
less_gpos :: proc(a, b: store.Encoded_Quad) -> bool {return permuted_compare(a, b, PERM_GPOS) < 0}
@(private)
less_gosp :: proc(a, b: store.Encoded_Quad) -> bool {return permuted_compare(a, b, PERM_GOSP) < 0}

// flush sorts the pending quads under each permutation and merges them
// into the index arrays: O(k log k + n) for k pending over n indexed.
@(private)
flush :: proc(ds: ^Dataset) {
	if len(ds.pending) == 0 {
		return
	}
	merge_into(&ds.gspo, ds.pending[:], less_gspo, ds.allocator)
	merge_into(&ds.gpos, ds.pending[:], less_gpos, ds.allocator)
	merge_into(&ds.gosp, ds.pending[:], less_gosp, ds.allocator)
	clear(&ds.pending)
}

@(private)
merge_into :: proc(
	index: ^[dynamic]store.Encoded_Quad,
	pending: []store.Encoded_Quad,
	less: proc(a, b: store.Encoded_Quad) -> bool,
	allocator: runtime.Allocator,
) {
	slice.sort_by(pending, less)
	merged := make([dynamic]store.Encoded_Quad, 0, len(index) + len(pending), allocator)
	i, j := 0, 0
	for i < len(index) && j < len(pending) {
		if less(index[i], pending[j]) {
			append(&merged, index[i])
			i += 1
		} else {
			append(&merged, pending[j])
			j += 1
		}
	}
	append(&merged, ..index[i:])
	append(&merged, ..pending[j:])
	delete(index^)
	index^ = merged
}

// prefix_compare orders a quad against the first plen bound positions
// of a pattern, in the index's position order.
@(private)
prefix_compare :: proc(q: store.Encoded_Quad, pattern: store.Match_Pattern, perm: [4]int, plen: int) -> int {
	for i in 0 ..< plen {
		pos := perm[i]
		if q[pos] < pattern[pos] {return -1}
		if q[pos] > pattern[pos] {return +1}
	}
	return 0
}

// prefix_range returns the half-open index range [lo, hi) of quads
// whose first plen permuted positions equal the pattern's.
@(private)
prefix_range :: proc(
	quads: []store.Encoded_Quad,
	pattern: store.Match_Pattern,
	perm: [4]int,
	plen: int,
) -> (
	lo: int,
	hi: int,
) {
	l, h := 0, len(quads)
	for l < h {
		mid := int(uint(l+h) >> 1)
		if prefix_compare(quads[mid], pattern, perm, plen) < 0 {l = mid + 1} else {h = mid}
	}
	lo = l
	l, h = lo, len(quads)
	for l < h {
		mid := int(uint(l+h) >> 1)
		if prefix_compare(quads[mid], pattern, perm, plen) <= 0 {l = mid + 1} else {h = mid}
	}
	hi = l
	return
}

// Match_Iterator streams the quads satisfying a pattern; see match.
Match_Iterator :: struct {
	quads:   []store.Encoded_Quad, // range of the chosen index
	pattern: store.Match_Pattern,
	index:   int,
}

// match returns an iterator over the quads matching a pattern, served
// by the index with the longest bound prefix (see the dispatch table
// on Dataset). The iterator is valid until the dataset is mutated or
// destroyed.
match :: proc(ds: ^Dataset, pattern: store.Match_Pattern) -> Match_Iterator {
	flush(ds)
	perms := [3][4]int{PERM_GSPO, PERM_GPOS, PERM_GOSP}
	arrays := [3][]store.Encoded_Quad{ds.gspo[:], ds.gpos[:], ds.gosp[:]}

	best, best_len := 0, 0
	for perm, i in perms {
		plen := 0
		for pos in perm {
			if pattern[pos] == store.WILDCARD {
				break
			}
			plen += 1
		}
		if plen > best_len {
			best, best_len = i, plen
		}
	}

	lo, hi := prefix_range(arrays[best], pattern, perms[best], best_len)
	return Match_Iterator{quads = arrays[best][lo:hi], pattern = pattern}
}

// match_next yields the next matching quad; ok=false once exhausted
// (and on every call thereafter).
match_next :: proc(it: ^Match_Iterator) -> (q: store.Encoded_Quad, ok: bool) {
	for it.index < len(it.quads) {
		candidate := it.quads[it.index]
		it.index += 1
		if store.pattern_matches(it.pattern, candidate) {
			return candidate, true
		}
	}
	return {}, false
}

// match_destroy releases iterator resources. This backend holds none;
// callers must still call it so code ports unchanged to backends that
// do (kvstore's cursors).
match_destroy :: proc(it: ^Match_Iterator) {
	it^ = {}
}
