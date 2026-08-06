// LMDB backend benchmarks: bulk load in durable and no_sync
// configurations (the difference is the per-commit fsync), disk
// bytes/statement, and match-scan throughput compared against the
// in-memory backend over the same data.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

import "rdf:bench/corpus"
import store "../store"
import memstore "../store/memstore"
import kvstore "../store/kvstore"

bench_lmdb :: proc() {
	src_nt := corpus.generate_triples(STATEMENTS, false)
	defer delete(src_nt)
	src_ttl := corpus.generate_turtle(STATEMENTS)
	defer delete(src_ttl)

	// All-distinct corpus (dictionary-heavy: fresh terms per statement)
	// vs the deduplicating Turtle corpus (probe-heavy: prices the
	// verification read on every repeated intern).
	bench_lmdb_load("LMDB N-Triples load", src_nt, lmdb_load_nt, false)
	bench_lmdb_load("LMDB N-Triples (no_sync)", src_nt, lmdb_load_nt, true)
	bench_lmdb_load("LMDB Turtle load", src_ttl, lmdb_load_ttl, false)
	bench_lmdb_load("LMDB Turtle (no_sync)", src_ttl, lmdb_load_ttl, true)

	bench_match_scans(src_nt)
}

// The separator is added here rather than assumed: macOS exports TMPDIR with
// a trailing slash and Linux usually exports nothing, so concatenating onto
// the variable yields a path at the filesystem root on Linux. Windows names
// the variable TEMP or TMP.
@(private = "file")
bench_db_path :: proc(name: string) -> string {
	tmp := os.get_env("TMPDIR", context.temp_allocator)
	if tmp == "" {
		tmp = os.get_env("TEMP", context.temp_allocator)
	}
	if tmp == "" {
		tmp = os.get_env("TMP", context.temp_allocator)
	}
	if tmp == "" {
		tmp = "/tmp"
	}
	tmp = strings.trim_right(tmp, `/\`)
	return fmt.aprintf("%s/odin-rdf-store-bench-%s-%d", tmp, name, os.get_pid())
}

@(private = "file")
remove_bench_db :: proc(path: string) {
	os.remove(fmt.tprintf("%s/data.mdb", path))
	os.remove(fmt.tprintf("%s/lock.mdb", path))
	os.remove(path)
	delete(path)
}

@(private = "file")
Lmdb_Load_Proc :: proc(s: ^kvstore.Store, source: []byte) -> int

@(private = "file")
lmdb_load_nt :: proc(s: ^kvstore.Store, source: []byte) -> int {
	added, parse_err, err := kvstore.load_triples(s, source)
	assert(err == nil && parse_err.message == "")
	return added
}

@(private = "file")
lmdb_load_ttl :: proc(s: ^kvstore.Store, source: []byte) -> int {
	added, parse_err, err := kvstore.load_turtle(s, source)
	assert(err == nil && parse_err.message == "")
	return added
}

@(private = "file")
bench_lmdb_load :: proc(label: string, src: string, load: Lmdb_Load_Proc, no_sync: bool) {
	path := bench_db_path(no_sync ? "nosync" : "sync")
	defer remove_bench_db(path)

	opts := kvstore.DEFAULT_OPTIONS
	opts.no_sync = no_sync
	s, err := kvstore.open(path, opts)
	assert(err == nil)

	start := time.tick_now()
	added := load(s, transmute([]u8)src)
	elapsed := time.tick_since(start)

	kvstore.close(s)

	// data.mdb's length is the page high-water mark — the on-disk cost.
	handle, open_err := os.open(fmt.tprintf("%s/data.mdb", path))
	assert(open_err == nil)
	disk, _ := os.file_size(handle)
	os.close(handle)

	seconds := time.duration_seconds(elapsed)
	fmt.printfln(
		"%-26s %v stmts  %.0f kstmt/s  %.1f B/stmt disk  (%v quads stored)",
		label,
		STATEMENTS,
		f64(STATEMENTS) / seconds / 1000.0,
		f64(disk) / f64(STATEMENTS),
		added,
	)
}

// bench_match_scans loads the same corpus into both backends and
// measures the match path itself — no term materialization: a full
// MATCH_ALL drain, and repeated (g,s)-bound probes.
@(private = "file")
bench_match_scans :: proc(src: string) {
	PROBES :: 10_000

	// In-memory backend.
	d: memstore.Dictionary
	memstore.dictionary_init(&d)
	defer memstore.dictionary_destroy(&d)
	ds: memstore.Dataset
	memstore.dataset_init(&ds)
	defer memstore.dataset_destroy(&ds)
	_, mem_err := memstore.load_triples(&d, &ds, transmute([]u8)src)
	assert(mem_err.message == "")

	probe_subject: store.Term_ID
	{
		it := memstore.match(&ds, store.MATCH_ALL)
		q, ok := memstore.match_next(&it)
		assert(ok)
		probe_subject = q[store.QUAD_S]
		memstore.match_destroy(&it)
	}

	{
		start := time.tick_now()
		n := 0
		it := memstore.match(&ds, store.MATCH_ALL)
		for _ in memstore.match_next(&it) {
			n += 1
		}
		memstore.match_destroy(&it)
		elapsed := time.duration_seconds(time.tick_since(start))
		fmt.printfln("in-memory full scan          %v quads  %.1f Mquad/s", n, f64(n) / elapsed / 1e6)

		start = time.tick_now()
		pattern := store.Match_Pattern{probe_subject, store.WILDCARD, store.WILDCARD, store.DEFAULT_GRAPH}
		for _ in 0 ..< PROBES {
			probe := memstore.match(&ds, pattern)
			for _ in memstore.match_next(&probe) {
			}
			memstore.match_destroy(&probe)
		}
		elapsed = time.duration_seconds(time.tick_since(start))
		fmt.printfln("in-memory (g,s) probes       %v probes  %.0f kprobe/s", PROBES, f64(PROBES) / elapsed / 1000.0)
	}

	// LMDB backend over the same corpus.
	path := bench_db_path("match")
	defer remove_bench_db(path)
	opts := kvstore.DEFAULT_OPTIONS
	opts.no_sync = true
	s, err := kvstore.open(path, opts)
	assert(err == nil)
	defer kvstore.close(s)
	_, parse_err, load_err := kvstore.load_triples(s, transmute([]u8)src)
	assert(load_err == nil && parse_err.message == "")

	{
		start := time.tick_now()
		n := 0
		it, merr := kvstore.match(s, store.MATCH_ALL)
		assert(merr == nil)
		for _ in kvstore.match_next(&it) {
			n += 1
		}
		kvstore.match_destroy(&it)
		elapsed := time.duration_seconds(time.tick_since(start))
		fmt.printfln("LMDB full scan               %v quads  %.1f Mquad/s", n, f64(n) / elapsed / 1e6)

		start = time.tick_now()
		pattern := store.Match_Pattern{probe_subject, store.WILDCARD, store.WILDCARD, store.DEFAULT_GRAPH}
		for _ in 0 ..< PROBES {
			probe, perr := kvstore.match(s, pattern)
			assert(perr == nil)
			for _ in kvstore.match_next(&probe) {
			}
			kvstore.match_destroy(&probe)
		}
		elapsed = time.duration_seconds(time.tick_since(start))
		fmt.printfln("LMDB (g,s) probes            %v probes  %.0f kprobe/s (txn+cursor per probe)", PROBES, f64(PROBES) / elapsed / 1000.0)
	}
}
