package kvstore

// open_ephemeral's own tests (STORE-T-0033). The match contract itself
// is not re-tested here — conformance_test.odin already runs the whole
// shared suite over an ephemeral store, which is the check that this
// is a constructor and not a change to the interface. What is left is
// the three properties only this constructor has: it leaves nothing
// behind, its names never collide, and its map is big enough for the
// fixtures the family actually loads.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:thread"

import "rdf:rdf"
import store ".."

@(test)
test_ephemeral_store_works_like_an_opened_one :: proc(t: ^testing.T) {
	s := scratch_store()
	defer close(s)

	ttl := `@prefix ex: <http://example.org/> .
ex:alice ex:knows ex:bob ; ex:name "Alice"@en .`
	added, perr, err := load_turtle(s, transmute([]u8)ttl)
	testing.expect(t, err == nil)
	testing.expect_value(t, perr.message, "")
	testing.expect_value(t, added, 2)

	n, cerr := count(s)
	testing.expect(t, cerr == nil)
	testing.expect_value(t, n, 2)

	knows, found, ferr := find_term(s, rdf.IRI("http://example.org/knows"))
	testing.expect(t, ferr == nil)
	testing.expect(t, found)

	it, merr := match(s, store.Match_Pattern{store.WILDCARD, knows, store.WILDCARD, store.WILDCARD})
	testing.expect(t, merr == nil)
	defer match_destroy(&it)
	matched := 0
	for _ in match_next(&it) {
		matched += 1
	}
	testing.expect_value(t, matched, 1)
}

// The store is unreachable through the filesystem for its whole life
// on POSIX, and gone by the time close returns everywhere.
//
// The POSIX arm asserts scratch_path rather than scanning the OS temp
// directory, and the reason is not squeamishness: the temp directory
// is shared with every other test in this binary, which the runner
// executes concurrently, so a scan there answers a question about the
// whole suite instead of about this store. scratch_path is the whole
// of what close has left to do — empty means the unlink already
// happened, since open_ephemeral either unlinks or records the path
// and never neither.
@(test)
test_ephemeral_store_leaves_nothing_behind :: proc(t: ^testing.T) {
	s, err := open_ephemeral()
	testing.expect(t, err == nil)

	when ODIN_OS == .Windows {
		testing.expect(t, s.scratch_path != "", "Windows cannot unlink an open file, so close must delete it")
		_, stat_err := os.stat(s.scratch_path, context.temp_allocator)
		testing.expect(t, stat_err == nil, "the backing file exists while the store is open")

		kept := strings.clone(s.scratch_path)
		defer delete(kept)
		close(s)

		_, gone_err := os.stat(kept, context.temp_allocator)
		testing.expect(t, gone_err != nil, "close deletes the backing file")
	} else {
		testing.expect_value(t, s.scratch_path, "")
		close(s)
	}
}

// The defect the four recorded collisions share is not the temp-path
// boilerplate but that each copy invented its own uniqueness scheme,
// and the schemes keyed on values two concurrent callers compute
// identically. There is no scheme here to get wrong — the name is won
// with O_CREAT|O_EXCL and a lost race retries — so this asserts the
// property the schemes failed: many callers at once, no two names the
// same.

@(private = "file")
RESERVE_THREADS :: 8
@(private = "file")
RESERVES_PER_THREAD :: 32

@(private = "file")
Reserver :: struct {
	paths:  [RESERVES_PER_THREAD]string,
	failed: bool,
}

// The worker allocates on the process heap rather than on the
// inherited context: the test runner's per-test allocator tracks
// allocations for leak reporting and is not the thing to hand to eight
// threads at once. Everything it takes is released by the test.
@(private = "file")
reserve_worker :: proc(w: ^Reserver) {
	for i in 0 ..< RESERVES_PER_THREAD {
		path, err := ephemeral_reserve(runtime.heap_allocator())
		if err != nil {
			w.failed = true
			return
		}
		w.paths[i] = path
	}
}

@(test)
test_ephemeral_names_never_collide :: proc(t: ^testing.T) {
	workers: [RESERVE_THREADS]Reserver
	threads: [RESERVE_THREADS]^thread.Thread
	for i in 0 ..< RESERVE_THREADS {
		threads[i] = thread.create_and_start_with_poly_data(&workers[i], reserve_worker)
	}
	for th in threads {
		thread.join(th)
		thread.destroy(th)
	}

	// Paths are freed after every comparison, not during: a map keyed
	// on freed strings compares against freed memory.
	seen := make(map[string]bool)
	defer {
		for path in seen {
			delete(path, runtime.heap_allocator())
		}
		delete(seen)
	}

	for &w in workers {
		testing.expect(t, !w.failed, "every reservation must succeed")
		for path in w.paths {
			if !testing.expect(t, path != "", "a reservation returned no path") {
				continue
			}
			testing.expect(t, path not_in seen, "two reservations returned the same path")
			// A reservation is a file, not just a name — that is what
			// makes it a reservation and not a guess.
			_, stat_err := os.stat(path, context.temp_allocator)
			testing.expect(t, stat_err == nil, "a reserved path must exist")
			os.remove(path)
			seen[path] = true
		}
	}
	testing.expect_value(t, len(seen), RESERVE_THREADS * RESERVES_PER_THREAD)
}

// EPHEMERAL_OPTIONS.map_size is the number that pays for this
// procedure, so it gets a guard rather than a comment alone. 5,000
// quads is above the whole vendored corpus of any one sibling repo
// loaded into a single store (odin-rdf-sparql's W3C tree is 3,977),
// and roughly twelve times the largest single document in the family.
// If this ever fails with MDB_MAP_FULL the default is too small for
// what the suites grew into, which is exactly the thing worth being
// told.
@(test)
test_ephemeral_map_holds_a_suite_sized_load :: proc(t: ^testing.T) {
	QUADS :: 5_000

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	for i in 0 ..< QUADS {
		fmt.sbprintf(
			&b,
			"<http://example.org/s%d> <http://example.org/p%d> \"object %d, padded so the dictionary is not trivially small\" .\n",
			i,
			i % 64,
			i,
		)
	}

	s := scratch_store()
	defer close(s)

	added, perr, err := load_triples(s, transmute([]u8)strings.to_string(b))
	testing.expect(t, err == nil, "a suite-sized load must not exhaust the ephemeral map")
	testing.expect_value(t, perr.message, "")
	testing.expect_value(t, added, QUADS)

	n, cerr := count(s)
	testing.expect(t, cerr == nil)
	testing.expect_value(t, n, QUADS)
}

// Many whole stores, open at once (2026-08-08).
//
// `test_ephemeral_names_never_collide` above reserves names concurrently
// and passes everywhere, including Windows — which is exactly why it did
// not catch this. Reservation is only the first half of open_ephemeral;
// the second half is an LMDB environment, and on Windows an environment
// materializes its whole map_size on disk the moment it opens. What a
// consumer's suite actually does is hold a dozen of those open at once,
// and odin-rdf-shacl's Windows job began failing intermittently with a
// reservation error under precisely that load, on two of ~58 opens, a
// different test each run.
//
// So this asserts the workload rather than the primitive: STORE_THREADS
// stores per thread, opened, used, and held until the batch is done. A
// failure here reports what the OS said, which is the whole reason
// ephemeral_reserve stopped classifying its errors.
@(private = "file")
STORE_THREADS :: 8

@(private = "file")
STORES_PER_THREAD :: 8

@(private = "file")
Opener :: struct {
	stores: [STORES_PER_THREAD]^Store,
	err:    Error,
	at:     int,
}

@(private = "file")
open_worker :: proc(w: ^Opener) {
	context.allocator = runtime.heap_allocator()
	for i in 0 ..< STORES_PER_THREAD {
		s, err := open_ephemeral()
		if err != nil {
			w.err = err
			w.at = i
			return
		}
		w.stores[i] = s
		// Write something, so the environment is not merely opened: a
		// map that is materialized but never touched is not the thing
		// the consumers do.
		ttl := `<http://example.org/s> <http://example.org/p> <http://example.org/o> .`
		if _, _, load_err := load_triples(s, transmute([]u8)ttl); load_err != nil {
			w.err = load_err
			w.at = i
			return
		}
	}
}

@(test)
test_many_ephemeral_stores_open_at_once :: proc(t: ^testing.T) {
	workers: [STORE_THREADS]Opener
	threads: [STORE_THREADS]^thread.Thread
	for i in 0 ..< STORE_THREADS {
		threads[i] = thread.create_and_start_with_poly_data(&workers[i], open_worker)
	}
	for th in threads {
		thread.join(th)
		thread.destroy(th)
	}

	opened := 0
	for &w in workers {
		testing.expectf(t, w.err == nil, "opening store %d of this thread's batch failed: %v", w.at, w.err)
		for s in w.stores {
			if s == nil {
				continue
			}
			opened += 1
			n, cerr := count(s)
			testing.expect(t, cerr == nil)
			testing.expect_value(t, n, 1)
			close(s, runtime.heap_allocator())
		}
	}
	testing.expect_value(t, opened, STORE_THREADS * STORES_PER_THREAD)
}
