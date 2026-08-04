package conformance

// Round-trip smoke tests for the memstore backend: load a fixture →
// export through the parser's emitters → reload → the two datasets
// hold the same quad set, equal modulo blank-node relabeling (per-load
// scoping renames blank labels by design). The emit helpers live in
// test code only — a polished export API is out of scope (STORE-I-0001
// non-goal).

import "core:strings"
import "core:testing"

import rdf "../../odin-rdf-parser/rdf"
import quads_fmt "../../odin-rdf-parser/rdf/quads"
import trig_fmt "../../odin-rdf-parser/rdf/trig"
import triples_fmt "../../odin-rdf-parser/rdf/triples"
import turtle_fmt "../../odin-rdf-parser/rdf/turtle"
import "../store"
import memstore "../store/memstore"

@(private = "file")
decode_all :: proc(d: ^memstore.Dictionary, ds: ^memstore.Dataset) -> [dynamic]rdf.Quad {
	result := make([dynamic]rdf.Quad)
	it := memstore.match(ds, store.MATCH_ALL)
	defer memstore.match_destroy(&it)
	for q in memstore.match_next(&it) {
		append(&result, memstore.decode_quad(d, q))
	}
	return result
}

@(private = "file")
Reload :: proc(d: ^memstore.Dictionary, ds: ^memstore.Dataset, source: string)

@(private = "file")
check_roundtrip :: proc(
	t: ^testing.T,
	fixture: string,
	load: Reload,
	export: proc(d: ^memstore.Dictionary, ds: ^memstore.Dataset) -> string,
	reload: Reload,
) {
	da: memstore.Dictionary
	memstore.dictionary_init(&da)
	defer memstore.dictionary_destroy(&da)
	dsa: memstore.Dataset
	memstore.dataset_init(&dsa)
	defer memstore.dataset_destroy(&dsa)
	load(&da, &dsa, fixture)

	exported := export(&da, &dsa)
	defer delete(exported)

	db: memstore.Dictionary
	memstore.dictionary_init(&db)
	defer memstore.dictionary_destroy(&db)
	dsb: memstore.Dataset
	memstore.dataset_init(&dsb)
	defer memstore.dataset_destroy(&dsb)
	reload(&db, &dsb, exported)

	qa := decode_all(&da, &dsa)
	defer delete(qa)
	qb := decode_all(&db, &dsb)
	defer delete(qb)
	testing.expect_value(t, len(qb), len(qa))
	testing.expect(t, quads_equal_mod_blanks(t, qa[:], qb[:]))
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
nt_load :: proc(d: ^memstore.Dictionary, ds: ^memstore.Dataset, source: string) {
	_, err := memstore.load_triples(d, ds, transmute([]u8)source)
	assert(err.message == "", "fixture must parse")
}

@(private = "file")
nq_load :: proc(d: ^memstore.Dictionary, ds: ^memstore.Dataset, source: string) {
	_, err := memstore.load_quads(d, ds, transmute([]u8)source)
	assert(err.message == "", "fixture must parse")
}

@(private = "file")
ttl_load :: proc(d: ^memstore.Dictionary, ds: ^memstore.Dataset, source: string) {
	_, err := memstore.load_turtle(d, ds, transmute([]u8)source)
	assert(err.message == "", "fixture must parse")
}

@(private = "file")
trig_load :: proc(d: ^memstore.Dictionary, ds: ^memstore.Dataset, source: string) {
	_, err := memstore.load_trig(d, ds, transmute([]u8)source)
	assert(err.message == "", "fixture must parse")
}

@(test)
test_roundtrip_ntriples :: proc(t: ^testing.T) {
	export :: proc(d: ^memstore.Dictionary, ds: ^memstore.Dataset) -> string {
		sb := strings.builder_make()
		w := strings.to_writer(&sb)
		it := memstore.match(ds, store.MATCH_ALL)
		defer memstore.match_destroy(&it)
		for q in memstore.match_next(&it) {
			decoded := memstore.decode_quad(d, q)
			assert(triples_fmt.emit(w, decoded.triple) == nil)
		}
		return strings.to_string(sb)
	}
	check_roundtrip(t, TRIPLE_FIXTURE, nt_load, export, nt_load)
}

@(test)
test_roundtrip_nquads :: proc(t: ^testing.T) {
	export :: proc(d: ^memstore.Dictionary, ds: ^memstore.Dataset) -> string {
		sb := strings.builder_make()
		w := strings.to_writer(&sb)
		it := memstore.match(ds, store.MATCH_ALL)
		defer memstore.match_destroy(&it)
		for q in memstore.match_next(&it) {
			assert(quads_fmt.emit(w, memstore.decode_quad(d, q)) == nil)
		}
		return strings.to_string(sb)
	}
	check_roundtrip(t, QUAD_FIXTURE, nq_load, export, nq_load)
}

@(test)
test_roundtrip_turtle :: proc(t: ^testing.T) {
	export :: proc(d: ^memstore.Dictionary, ds: ^memstore.Dataset) -> string {
		sb := strings.builder_make()
		w := strings.to_writer(&sb)
		e: turtle_fmt.Emitter
		assert(turtle_fmt.emitter_init(&e, w) == nil)
		defer turtle_fmt.emitter_destroy(&e)
		it := memstore.match(ds, store.MATCH_ALL)
		defer memstore.match_destroy(&it)
		for q in memstore.match_next(&it) {
			assert(turtle_fmt.emit(&e, memstore.decode_quad(d, q).triple) == nil)
		}
		assert(turtle_fmt.emitter_finish(&e) == nil)
		return strings.to_string(sb)
	}
	check_roundtrip(t, TRIPLE_FIXTURE, nt_load, export, ttl_load)
}

@(test)
test_roundtrip_trig :: proc(t: ^testing.T) {
	export :: proc(d: ^memstore.Dictionary, ds: ^memstore.Dataset) -> string {
		sb := strings.builder_make()
		w := strings.to_writer(&sb)
		e: trig_fmt.Emitter
		assert(trig_fmt.emitter_init(&e, w) == nil)
		defer trig_fmt.emitter_destroy(&e)
		it := memstore.match(ds, store.MATCH_ALL)
		defer memstore.match_destroy(&it)
		for q in memstore.match_next(&it) {
			assert(trig_fmt.emit(&e, memstore.decode_quad(d, q)) == nil)
		}
		assert(trig_fmt.emitter_finish(&e) == nil)
		return strings.to_string(sb)
	}
	check_roundtrip(t, QUAD_FIXTURE, nq_load, export, trig_load)
}
