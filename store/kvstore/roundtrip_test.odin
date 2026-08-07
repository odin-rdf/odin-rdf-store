package kvstore

// Round-trip smoke tests: load a fixture → export through the parser's
// emitters → reload → the two datasets hold the same quad set, equal
// modulo blank-node relabeling (per-load scoping renames blank labels by
// design). The emit helpers live in test code only — a polished export
// API is out of scope (STORE-I-0001 non-goal).
//
// This is the executable form of the vision's round-trip success
// criterion: "load → match/export → compare preserves data semantics for
// all four formats."
//
// Ported from conformance/roundtrip_memstore_test.odin when the
// in-memory backend was retired (STORE-A-0006, STORE-T-0028). It lives
// here rather than in `conformance` because it was never part of the
// backend-agnostic suite: it drives a backend's procedures directly
// rather than through the Backend adapter, and it needs this package's
// temp-database helpers. `conformance` is now the harness alone.
//
// One difference from the in-memory original, and it is the reason every
// decode below takes an allocator: memstore's lookup_term borrowed from
// dictionary storage and allocated nothing, while kvstore copies each
// term out of the mapped pages into a caller allocator. The decoded
// quads here come from the temp allocator and are released wholesale.

import "core:strings"
import "core:testing"

import "rdf:rdf"
import quads_fmt "rdf:rdf/quads"
import trig_fmt "rdf:rdf/trig"
import triples_fmt "rdf:rdf/triples"
import turtle_fmt "rdf:rdf/turtle"
import "../../conformance"
import store ".."

@(private = "file")
decode_all :: proc(s: ^Store) -> [dynamic]rdf.Quad {
	result := make([dynamic]rdf.Quad, context.temp_allocator)
	it, err := match(s, store.MATCH_ALL)
	assert(err == nil, "match must open")
	defer match_destroy(&it)
	for q in match_next(&it) {
		decoded, decode_err := decode_quad(s, q, context.temp_allocator)
		assert(decode_err == nil, "decode must succeed")
		append(&result, decoded)
	}
	return result
}

@(private = "file")
Reload :: proc(s: ^Store, source: string)

@(private = "file")
check_roundtrip :: proc(
	t: ^testing.T,
	name: string,
	fixture: string,
	load: Reload,
	export: proc(s: ^Store) -> string,
	reload: Reload,
) {
	defer free_all(context.temp_allocator)

	path_a := test_db_path(strings.concatenate({name, "-a"}, context.temp_allocator))
	defer remove_test_db(path_a)
	sa, err_a := open(path_a)
	assert(err_a == nil, "test store must open")
	defer close(sa)
	load(sa, fixture)

	exported := export(sa)
	defer delete(exported)

	path_b := test_db_path(strings.concatenate({name, "-b"}, context.temp_allocator))
	defer remove_test_db(path_b)
	sb, err_b := open(path_b)
	assert(err_b == nil, "test store must open")
	defer close(sb)
	reload(sb, exported)

	qa := decode_all(sa)
	qb := decode_all(sb)
	testing.expect_value(t, len(qb), len(qa))
	testing.expect(t, conformance.quads_equal_mod_blanks(t, qa[:], qb[:]))
}

// Triple fixture: ground triples, blanks in subject and object, an
// escaped literal, a language tag, and an RDF-star triple term (no
// blanks inside it — see quads_equal_mod_blanks).
@(private = "file")
TRIPLE_FIXTURE :: `<http://example.org/alice> <http://example.org/knows> <http://example.org/bob> .
_:x <http://example.org/says> "h\"i\n" .
_:x <http://example.org/knows> _:y .
_:y <http://example.org/name> "Yéti"@fr .
<http://example.org/r> <http://example.org/reifies> <<( <http://example.org/s> <http://example.org/p> "o" )>> .`

// Quad fixture: the same spread across default, IRI-named, and
// blank-labeled graphs.
@(private = "file")
QUAD_FIXTURE :: `<http://example.org/alice> <http://example.org/knows> <http://example.org/bob> .
_:x <http://example.org/says> "h\"i\n" <http://example.org/g1> .
_:x <http://example.org/knows> _:y <http://example.org/g1> .
_:y <http://example.org/name> "Yéti"@fr _:g .`

@(private = "file")
nt_load :: proc(s: ^Store, source: string) {
	_, parse_err, err := load_triples(s, transmute([]u8)source)
	assert(err == nil, "store must accept the load")
	assert(parse_err.message == "", "fixture must parse")
}

@(private = "file")
nq_load :: proc(s: ^Store, source: string) {
	_, parse_err, err := load_quads(s, transmute([]u8)source)
	assert(err == nil, "store must accept the load")
	assert(parse_err.message == "", "fixture must parse")
}

@(private = "file")
ttl_load :: proc(s: ^Store, source: string) {
	_, parse_err, err := load_turtle(s, transmute([]u8)source)
	assert(err == nil, "store must accept the load")
	assert(parse_err.message == "", "fixture must parse")
}

@(private = "file")
trig_load :: proc(s: ^Store, source: string) {
	_, parse_err, err := load_trig(s, transmute([]u8)source)
	assert(err == nil, "store must accept the load")
	assert(parse_err.message == "", "fixture must parse")
}

@(test)
test_roundtrip_ntriples :: proc(t: ^testing.T) {
	export :: proc(s: ^Store) -> string {
		sb := strings.builder_make()
		w := strings.to_writer(&sb)
		it, err := match(s, store.MATCH_ALL)
		assert(err == nil)
		defer match_destroy(&it)
		for q in match_next(&it) {
			decoded, decode_err := decode_quad(s, q, context.temp_allocator)
			assert(decode_err == nil)
			assert(triples_fmt.emit(w, decoded.triple) == nil)
		}
		return strings.to_string(sb)
	}
	check_roundtrip(t, "rt-nt", TRIPLE_FIXTURE, nt_load, export, nt_load)
}

@(test)
test_roundtrip_nquads :: proc(t: ^testing.T) {
	export :: proc(s: ^Store) -> string {
		sb := strings.builder_make()
		w := strings.to_writer(&sb)
		it, err := match(s, store.MATCH_ALL)
		assert(err == nil)
		defer match_destroy(&it)
		for q in match_next(&it) {
			decoded, decode_err := decode_quad(s, q, context.temp_allocator)
			assert(decode_err == nil)
			assert(quads_fmt.emit(w, decoded) == nil)
		}
		return strings.to_string(sb)
	}
	check_roundtrip(t, "rt-nq", QUAD_FIXTURE, nq_load, export, nq_load)
}

@(test)
test_roundtrip_turtle :: proc(t: ^testing.T) {
	export :: proc(s: ^Store) -> string {
		sb := strings.builder_make()
		w := strings.to_writer(&sb)
		e: turtle_fmt.Emitter
		assert(turtle_fmt.emitter_init(&e, w) == nil)
		defer turtle_fmt.emitter_destroy(&e)
		it, err := match(s, store.MATCH_ALL)
		assert(err == nil)
		defer match_destroy(&it)
		for q in match_next(&it) {
			decoded, decode_err := decode_quad(s, q, context.temp_allocator)
			assert(decode_err == nil)
			assert(turtle_fmt.emit(&e, decoded.triple) == nil)
		}
		assert(turtle_fmt.emitter_finish(&e) == nil)
		return strings.to_string(sb)
	}
	check_roundtrip(t, "rt-ttl", TRIPLE_FIXTURE, nt_load, export, ttl_load)
}

@(test)
test_roundtrip_trig :: proc(t: ^testing.T) {
	export :: proc(s: ^Store) -> string {
		sb := strings.builder_make()
		w := strings.to_writer(&sb)
		e: trig_fmt.Emitter
		assert(trig_fmt.emitter_init(&e, w) == nil)
		defer trig_fmt.emitter_destroy(&e)
		it, err := match(s, store.MATCH_ALL)
		assert(err == nil)
		defer match_destroy(&it)
		for q in match_next(&it) {
			decoded, decode_err := decode_quad(s, q, context.temp_allocator)
			assert(decode_err == nil)
			assert(trig_fmt.emit(&e, decoded) == nil)
		}
		assert(trig_fmt.emitter_finish(&e) == nil)
		return strings.to_string(sb)
	}
	check_roundtrip(t, "rt-trig", QUAD_FIXTURE, nq_load, export, trig_load)
}
