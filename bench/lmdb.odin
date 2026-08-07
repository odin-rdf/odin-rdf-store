// The LMDB measurement primitives: one bulk load into a fresh database
// with its disk high-water mark, and the match path on its own.
//
// bench_match_scans measured both backends over the same corpus until
// 2026-08-07. That comparison is removed rather than ported (STORE-T-0029,
// STORE-A-0006) — there is no second backend to compare against. Two
// things went with it: the in-memory full-scan and probe figures, and the
// property that made the comparison cheap to write, namely that a
// Term_ID minted by one backend was the same integer in the other
// (STORE-A-0001 point 7, now historical). The probe subject is therefore
// read out of the store being measured, which is what it should have been
// doing anyway.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

import store "../store"
import kvstore "../store/kvstore"

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

// bench_lmdb_load times one document into a fresh database and reports
// the page high-water mark it left behind. no_sync trades the per-commit
// fsync for speed; the pair is the point, not either number alone.
bench_lmdb_load :: proc(label: string, src: string, load: Load_Proc, no_sync: bool) {
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

// bench_match_scans measures the match path itself — no term
// materialization: a full MATCH_ALL drain, and repeated (g,s)-bound
// probes, each of which opens its own read transaction and cursor.
bench_match_scans :: proc(src: string) {
	PROBES :: 10_000

	path := bench_db_path("match")
	defer remove_bench_db(path)
	opts := kvstore.DEFAULT_OPTIONS
	opts.no_sync = true
	s, err := kvstore.open(path, opts)
	assert(err == nil)
	defer kvstore.close(s)
	_, parse_err, load_err := kvstore.load_triples(s, transmute([]u8)src)
	assert(load_err == nil && parse_err.message == "")

	// Read the probe subject out of the store being measured. This used
	// to come from the in-memory backend's dictionary and be reused here
	// unchanged, which worked only because both backends assigned the
	// same integer to the same term.
	probe_subject: store.Term_ID
	{
		it, merr := kvstore.match(s, store.MATCH_ALL)
		assert(merr == nil)
		q, ok := kvstore.match_next(&it)
		assert(ok)
		probe_subject = q[store.QUAD_S]
		kvstore.match_destroy(&it)
	}

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
