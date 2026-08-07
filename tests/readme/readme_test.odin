// The README quick-start examples, compiled and asserted here so the
// documentation cannot drift from the real API. Each test is the
// README's code verbatim, apart from the database path in the
// persistent example (a temp directory here, a literal there) and the
// assertions standing in for the comments that describe the output.
package readme

import "core:fmt"
import "core:io"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"

import "rdf:rdf"
import quads_fmt "rdf:rdf/quads"

import store "../../store"
import kvstore "../../store/kvstore"

@(private = "file")
EX :: "http://example.org/"

@(private = "file")
README_SOURCE :: `
@prefix ex: <http://example.org/> .

ex:alice ex:knows ex:bob ;
    ex:name "Alice"@en .
ex:bob ex:knows ex:carol .
`

// Export is match + decode + emit: there is no export API in v1.
@(test)
readme_export_example :: proc(t: ^testing.T) {
	path := readme_db_path()
	defer remove_readme_db(path)

	s, open_err := kvstore.open(path)
	testing.expect(t, open_err == nil)
	defer kvstore.close(s)

	_, load_err, db_err := kvstore.load_turtle(s, transmute([]byte)string(README_SOURCE))
	testing.expect_value(t, load_err.message, "")
	testing.expect(t, db_err == nil)

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	w := strings.to_writer(&b)

	it, match_err := kvstore.match(s, store.MATCH_ALL)
	testing.expect(t, match_err == nil)
	defer kvstore.match_destroy(&it)
	for {
		q, ok := kvstore.match_next(&it)
		if !ok {
			break
		}
		decoded, decode_err := kvstore.decode_quad(s, q, context.temp_allocator)
		testing.expect(t, decode_err == nil)
		testing.expect_value(t, quads_fmt.emit(w, decoded), io.Error.None)
	}
	free_all(context.temp_allocator)

	// One N-Quads line per stored quad.
	testing.expect_value(t, strings.count(strings.to_string(b), "\n"), 3)
}

// The same dataset on disk: identical procedure names and semantics,
// plus the Error a persistent backend can return.
@(test)
readme_persistent_example :: proc(t: ^testing.T) {
	path := readme_db_path()
	defer remove_readme_db(path)

	s, open_err := kvstore.open(path)
	testing.expect(t, open_err == nil)
	defer kvstore.close(s)

	added, parse_err, load_err := kvstore.load_turtle(s, transmute([]byte)string(README_SOURCE))
	testing.expect_value(t, parse_err.message, "")
	testing.expect(t, load_err == nil)
	testing.expect_value(t, added, 3)

	knows, found, find_err := kvstore.find_term(s, rdf.IRI(EX + "knows"))
	testing.expect(t, find_err == nil)
	testing.expect(t, found)

	it, match_err := kvstore.match(s, store.Match_Pattern{store.WILDCARD, knows, store.WILDCARD, store.WILDCARD})
	testing.expect(t, match_err == nil)
	defer kvstore.match_destroy(&it)

	matched := 0
	for {
		q, ok := kvstore.match_next(&it)
		if !ok {
			break
		}
		// Unlike the in-memory dictionary's borrowed strings, a
		// persistent lookup copies into the caller's allocator, so the
		// term outlives the store and is the caller's to free.
		subject, lookup_err := kvstore.lookup_term(s, q[store.QUAD_S])
		testing.expect(t, lookup_err == nil)
		defer rdf.destroy(subject)
		testing.expect(t, strings.has_prefix(string(subject.(rdf.IRI)), EX))
		matched += 1
	}
	testing.expect_value(t, matched, 2)
}

// The separator is added here rather than assumed: macOS exports TMPDIR with
// a trailing slash and Linux usually exports nothing, so concatenating onto
// the variable yields a path at the filesystem root on Linux. Windows names
// the variable TEMP or TMP.
// A pid alone stopped being unique when the in-memory example became a
// second persistent one (STORE-T-0030): two tests on ten threads, one path,
// and the second open fails on a directory that already exists.
@(private = "file")
readme_db_counter: u64

@(private = "file")
readme_db_path :: proc() -> string {
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
	n := sync.atomic_add(&readme_db_counter, 1)
	return fmt.aprintf("%s/odin-rdf-store-readme-%d-%d", tmp, os.get_pid(), n)
}

@(private = "file")
remove_readme_db :: proc(path: string) {
	os.remove(fmt.tprintf("%s/data.mdb", path))
	os.remove(fmt.tprintf("%s/lock.mdb", path))
	os.remove(path)
	delete(path)
}
