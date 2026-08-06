// The README quick-start examples, compiled and asserted here so the
// documentation cannot drift from the real API. Each test is the
// README's code verbatim, apart from the database path in the
// persistent example (a temp directory here, a literal there) and the
// assertions standing in for the comments that describe the output.
package readme

import "core:fmt"
import "core:io"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"

import "rdf:rdf"
import quads_fmt "rdf:rdf/quads"

import store "../../store"
import kvstore "../../store/kvstore"
import memstore "../../store/memstore"

@(private = "file")
EX :: "http://example.org/"

@(private = "file")
README_SOURCE :: `
@prefix ex: <http://example.org/> .

ex:alice ex:knows ex:bob ;
    ex:name "Alice"@en .
ex:bob ex:knows ex:carol .
`

// The in-memory quick start: load a document, then ask who knows whom.
@(test)
readme_load_and_match :: proc(t: ^testing.T) {
	d: memstore.Dictionary
	memstore.dictionary_init(&d)
	defer memstore.dictionary_destroy(&d)

	ds: memstore.Dataset
	memstore.dataset_init(&ds)
	defer memstore.dataset_destroy(&ds)

	added, err := memstore.load_turtle(&d, &ds, transmute([]byte)string(README_SOURCE))
	testing.expect_value(t, err.message, "")
	testing.expect_value(t, added, 3)
	testing.expect_value(t, memstore.count(&ds), 3)

	// find_term resolves a query's ground term without assigning an ID:
	// asking about a term the store has never seen leaves the dictionary
	// untouched and reports found=false, which callers short-circuit to
	// an empty result.
	knows, found := memstore.find_term(&d, rdf.IRI(EX + "knows"))
	testing.expect(t, found)

	subjects: [dynamic]string
	defer delete(subjects)

	it := memstore.match(&ds, store.Match_Pattern{store.WILDCARD, knows, store.WILDCARD, store.WILDCARD})
	defer memstore.match_destroy(&it)
	for {
		q, ok := memstore.match_next(&it)
		if !ok {
			break
		}
		subject := memstore.lookup_term(&d, q[store.QUAD_S]).(rdf.IRI)
		append(&subjects, string(subject))
	}

	// v1 promises nothing about match order, so a caller that cares
	// sorts (STORE-A-0002).
	slice.sort(subjects[:])
	testing.expect_value(t, len(subjects), 2)
	testing.expect_value(t, subjects[0], EX + "alice")
	testing.expect_value(t, subjects[1], EX + "bob")
}

// Export is match + decode + emit: there is no export API in v1.
@(test)
readme_export_example :: proc(t: ^testing.T) {
	d: memstore.Dictionary
	memstore.dictionary_init(&d)
	defer memstore.dictionary_destroy(&d)

	ds: memstore.Dataset
	memstore.dataset_init(&ds)
	defer memstore.dataset_destroy(&ds)

	_, load_err := memstore.load_turtle(&d, &ds, transmute([]byte)string(README_SOURCE))
	testing.expect_value(t, load_err.message, "")

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	w := strings.to_writer(&b)

	it := memstore.match(&ds, store.MATCH_ALL)
	defer memstore.match_destroy(&it)
	for {
		q, ok := memstore.match_next(&it)
		if !ok {
			break
		}
		testing.expect_value(t, quads_fmt.emit(w, memstore.decode_quad(&d, q)), io.Error.None)
	}

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

@(private = "file")
readme_db_path :: proc() -> string {
	tmp := os.get_env("TMPDIR", context.temp_allocator)
	if tmp == "" {
		tmp = "/tmp"
	}
	return fmt.aprintf("%sodin-rdf-store-readme-%d", tmp, os.get_pid())
}

@(private = "file")
remove_readme_db :: proc(path: string) {
	os.remove(fmt.tprintf("%s/data.mdb", path))
	os.remove(fmt.tprintf("%s/lock.mdb", path))
	os.remove(path)
	delete(path)
}
