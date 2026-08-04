// Bulk-load throughput and memory benchmarks over the parser's
// deterministic generated corpora. Run with:
//
//	odin run bench -o:speed
//
// Reports statements/second (wall clock over the full load: parse +
// intern + triple index insertion) and live bytes/statement (dictionary
// + indexes after the load, via a tracking allocator). Guards the
// zero-copy discipline: a silent extra copy per statement shows up in
// bytes/statement.
package main

import "core:fmt"
import "core:mem"
import "core:time"

import corpus "../../odin-rdf-parser/bench/corpus"
import store "../store"
import memstore "../store/memstore"

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

	bench_load("N-Triples load", src_nt, load_nt)
	bench_load("N-Triples load (escaped)", src_nt_escaped, load_nt)
	bench_load("N-Quads load", src_nq, load_nq)
	bench_load("Turtle load", src_ttl, load_ttl)
	bench_load("TriG load", src_trig, load_trig)

	bench_lmdb()
}

Load_Proc :: proc(d: ^memstore.Dictionary, ds: ^memstore.Dataset, source: []byte) -> int

load_nt :: proc(d: ^memstore.Dictionary, ds: ^memstore.Dataset, source: []byte) -> int {
	added, err := memstore.load_triples(d, ds, source)
	assert(err.message == "")
	return added
}

load_nq :: proc(d: ^memstore.Dictionary, ds: ^memstore.Dataset, source: []byte) -> int {
	added, err := memstore.load_quads(d, ds, source)
	assert(err.message == "")
	return added
}

load_ttl :: proc(d: ^memstore.Dictionary, ds: ^memstore.Dataset, source: []byte) -> int {
	added, err := memstore.load_turtle(d, ds, source)
	assert(err.message == "")
	return added
}

load_trig :: proc(d: ^memstore.Dictionary, ds: ^memstore.Dataset, source: []byte) -> int {
	added, err := memstore.load_trig(d, ds, source)
	assert(err.message == "")
	return added
}

bench_load :: proc(label: string, src: string, load: Load_Proc) {
	tracker: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracker, context.allocator)
	defer mem.tracking_allocator_destroy(&tracker)
	allocator := mem.tracking_allocator(&tracker)

	d: memstore.Dictionary
	memstore.dictionary_init(&d, allocator)
	ds: memstore.Dataset
	memstore.dataset_init(&ds, allocator)

	start := time.tick_now()
	added := load(&d, &ds, transmute([]u8)src)
	// First match builds the indexes (lazy flush) — include it in the
	// timing so the number is load + index construction, not just parse
	// + intern.
	it := memstore.match(&ds, store.MATCH_ALL)
	memstore.match_destroy(&it)
	elapsed := time.tick_since(start)

	seconds := time.duration_seconds(elapsed)
	live := tracker.current_memory_allocated

	fmt.printfln(
		"%-26s %v stmts  %.0f kstmt/s  %.1f B/stmt live  (%v quads stored)",
		label,
		STATEMENTS,
		f64(STATEMENTS) / seconds / 1000.0,
		f64(live) / f64(STATEMENTS),
		added,
	)

	memstore.dataset_destroy(&ds)
	memstore.dictionary_destroy(&d)
}
