// Bulk-load throughput and on-disk size benchmarks over the parser's
// deterministic generated corpora. Run with:
//
//	odin run bench -o:speed
//
// Reports statements/second (wall clock over the full load: parse +
// intern + index insertion + commit) and on-disk bytes/statement.
//
// Until 2026-08-07 this file measured the in-memory backend and reported
// *live* bytes/statement from a tracking allocator, which guarded the
// zero-copy discipline: a silent extra copy per statement showed up
// there. That metric has no analogue on kvstore — LMDB holds the
// dictionary and indexes in mapped pages rather than in Odin-allocated
// memory, so a tracking allocator sees almost nothing regardless. The
// disk high-water mark in bench_lmdb_load is the surviving size signal,
// and it is a coarser one: it prices pages, not copies. Recorded in
// STORE-T-0029 rather than quietly dropped, along with the historical
// figures, which are not comparable to anything measured here.
package main

import "core:fmt"

import "rdf:bench/corpus"
import store "../store"
import kvstore "../store/kvstore"

STATEMENTS :: 200_000

main :: proc() {
	fmt.printfln("Term_ID width: %d bits", store.TERM_ID_BITS)

	src_nt := corpus.generate_triples(STATEMENTS, false)
	defer delete(src_nt)
	src_nt_escaped := corpus.generate_triples(STATEMENTS, true)
	defer delete(src_nt_escaped)
	src_nq := corpus.generate_quads(STATEMENTS, false)
	defer delete(src_nq)
	src_ttl := corpus.generate_turtle(STATEMENTS)
	defer delete(src_ttl)
	src_trig := corpus.generate_trig(STATEMENTS)
	defer delete(src_trig)

	// The format sweep, durable — what a caller gets by default.
	bench_lmdb_load("N-Triples load", src_nt, load_nt, false)
	bench_lmdb_load("N-Triples (escaped)", src_nt_escaped, load_nt, false)
	bench_lmdb_load("N-Quads load", src_nq, load_nq, false)
	bench_lmdb_load("Turtle load", src_ttl, load_ttl, false)
	bench_lmdb_load("TriG load", src_trig, load_trig, false)

	// The fsync delta, on the all-distinct (dictionary-heavy) and the
	// deduplicating (probe-heavy) corpora. Paired with their durable runs
	// above rather than measured alone: the number that matters is the
	// difference.
	bench_lmdb_load("N-Triples (no_sync)", src_nt, load_nt, true)
	bench_lmdb_load("Turtle (no_sync)", src_ttl, load_ttl, true)

	bench_match_scans(src_nt)
}

Load_Proc :: proc(s: ^kvstore.Store, source: []byte) -> int

load_nt :: proc(s: ^kvstore.Store, source: []byte) -> int {
	added, parse_err, err := kvstore.load_triples(s, source)
	assert(err == nil && parse_err.message == "")
	return added
}

load_nq :: proc(s: ^kvstore.Store, source: []byte) -> int {
	added, parse_err, err := kvstore.load_quads(s, source)
	assert(err == nil && parse_err.message == "")
	return added
}

load_ttl :: proc(s: ^kvstore.Store, source: []byte) -> int {
	added, parse_err, err := kvstore.load_turtle(s, source)
	assert(err == nil && parse_err.message == "")
	return added
}

load_trig :: proc(s: ^kvstore.Store, source: []byte) -> int {
	added, parse_err, err := kvstore.load_trig(s, source)
	assert(err == nil && parse_err.message == "")
	return added
}
