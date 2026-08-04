package store

// Round-trip smoke test: load a fixture → export through the parser's
// emitters → reload → the two datasets hold the same quad set, equal
// modulo blank-node relabeling (per-load scoping renames blank labels
// by design). The emit helpers live in test code only — a polished
// export API is out of scope for STORE-I-0001.

import "core:strings"
import "core:testing"
import rdf "../../odin-rdf-parser/rdf"
import quads_fmt "../../odin-rdf-parser/rdf/quads"
import trig_fmt "../../odin-rdf-parser/rdf/trig"
import triples_fmt "../../odin-rdf-parser/rdf/triples"
import turtle_fmt "../../odin-rdf-parser/rdf/turtle"

@(private = "file")
decode_all :: proc(d: ^Dictionary, ds: ^Dataset) -> [dynamic]rdf.Quad {
	result := make([dynamic]rdf.Quad)
	it := match(ds, MATCH_ALL)
	defer match_destroy(&it)
	for q in match_next(&it) {
		append(&result, decode_quad(d, q))
	}
	return result
}

// blank_label extracts the label when the term is a blank node.
@(private = "file")
blank_label :: proc(term: rdf.Term) -> (string, bool) {
	if b, ok := term.(rdf.Blank_Node); ok {
		return string(b), true
	}
	return "", false
}

// quads_equal_mod_blanks checks set equality under some bijection of
// blank-node labels, built greedily: each round commits the a-quads
// with exactly one compatible b-quad under the mapping so far. Zero
// candidates fail the test; fixtures must be unambiguous enough that
// every round makes progress (blank nodes distinguishable by ground
// context; no blanks inside triple terms).
@(private = "file")
quads_equal_mod_blanks :: proc(t: ^testing.T, a, b: []rdf.Quad) -> bool {
	if len(a) != len(b) {
		return false
	}
	mapping := make(map[string]string) // a-label -> b-label
	defer delete(mapping)
	reverse := make(map[string]string)
	defer delete(reverse)
	matched_a := make([]bool, len(a))
	defer delete(matched_a)
	matched_b := make([]bool, len(b))
	defer delete(matched_b)

	term_compatible :: proc(x, y: rdf.Term, mapping: ^map[string]string, reverse: ^map[string]string) -> bool {
		xl, x_blank := blank_label(x)
		yl, y_blank := blank_label(y)
		if x_blank != y_blank {
			return false
		}
		if !x_blank {
			return rdf.equal(x, y)
		}
		if mapped, ok := mapping[xl]; ok {
			return mapped == yl
		}
		if _, taken := reverse[yl]; taken {
			return false
		}
		return true // both free: binding would be consistent
	}

	quad_compatible :: proc(x, y: rdf.Quad, mapping: ^map[string]string, reverse: ^map[string]string) -> bool {
		graph_term :: proc(g: rdf.Graph_Label) -> rdf.Term {
			switch v in g {
			case rdf.IRI:
				return v
			case rdf.Blank_Node:
				return v
			}
			return nil
		}
		if (x.graph == nil) != (y.graph == nil) {
			return false
		}
		if x.graph != nil &&
		   !term_compatible(graph_term(x.graph), graph_term(y.graph), mapping, reverse) {
			return false
		}
		return term_compatible(x.subject, y.subject, mapping, reverse) &&
			term_compatible(x.predicate, y.predicate, mapping, reverse) &&
			term_compatible(x.object, y.object, mapping, reverse)
	}

	bind :: proc(x, y: rdf.Term, mapping: ^map[string]string, reverse: ^map[string]string) {
		if xl, ok := blank_label(x); ok {
			yl, _ := blank_label(y)
			if _, bound := mapping[xl]; !bound {
				mapping[xl] = yl
				reverse[yl] = xl
			}
		}
	}

	remaining := len(a)
	for remaining > 0 {
		progressed := false
		for i in 0 ..< len(a) {
			if matched_a[i] {
				continue
			}
			candidate := -1
			candidates := 0
			for j in 0 ..< len(b) {
				if matched_b[j] {
					continue
				}
				if quad_compatible(a[i], b[j], &mapping, &reverse) {
					candidate = j
					candidates += 1
				}
			}
			if candidates == 0 {
				return false
			}
			if candidates > 1 {
				continue // ambiguous this round; retry after more bindings
			}
			j := candidate
			bind(a[i].subject, b[j].subject, &mapping, &reverse)
			bind(a[i].predicate, b[j].predicate, &mapping, &reverse)
			bind(a[i].object, b[j].object, &mapping, &reverse)
			if ga, ok := a[i].graph.(rdf.Blank_Node); ok {
				if gb, ok2 := b[j].graph.(rdf.Blank_Node); ok2 {
					bind(rdf.Term(ga), rdf.Term(gb), &mapping, &reverse)
				}
			}
			matched_a[i] = true
			matched_b[j] = true
			remaining -= 1
			progressed = true
		}
		if !progressed {
			testing.expect(t, false, "fixture too ambiguous for greedy blank matching")
			return false
		}
	}
	return true
}

@(private = "file")
Reload :: proc(d: ^Dictionary, ds: ^Dataset, source: string)

@(private = "file")
check_roundtrip :: proc(t: ^testing.T, fixture: string, load: Reload, export: proc(d: ^Dictionary, ds: ^Dataset) -> string, reload: Reload) {
	da: Dictionary
	dictionary_init(&da)
	defer dictionary_destroy(&da)
	dsa: Dataset
	dataset_init(&dsa)
	defer dataset_destroy(&dsa)
	load(&da, &dsa, fixture)

	exported := export(&da, &dsa)
	defer delete(exported)

	db: Dictionary
	dictionary_init(&db)
	defer dictionary_destroy(&db)
	dsb: Dataset
	dataset_init(&dsb)
	defer dataset_destroy(&dsb)
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
nt_load :: proc(d: ^Dictionary, ds: ^Dataset, source: string) {
	_, err := load_triples(d, ds, transmute([]u8)source)
	assert(err.message == "", "fixture must parse")
}

@(private = "file")
nq_load :: proc(d: ^Dictionary, ds: ^Dataset, source: string) {
	_, err := load_quads(d, ds, transmute([]u8)source)
	assert(err.message == "", "fixture must parse")
}

@(private = "file")
ttl_load :: proc(d: ^Dictionary, ds: ^Dataset, source: string) {
	_, err := load_turtle(d, ds, transmute([]u8)source)
	assert(err.message == "", "fixture must parse")
}

@(private = "file")
trig_load :: proc(d: ^Dictionary, ds: ^Dataset, source: string) {
	_, err := load_trig(d, ds, transmute([]u8)source)
	assert(err.message == "", "fixture must parse")
}

@(test)
test_roundtrip_ntriples :: proc(t: ^testing.T) {
	export :: proc(d: ^Dictionary, ds: ^Dataset) -> string {
		sb := strings.builder_make()
		w := strings.to_writer(&sb)
		it := match(ds, MATCH_ALL)
		defer match_destroy(&it)
		for q in match_next(&it) {
			decoded := decode_quad(d, q)
			assert(triples_fmt.emit(w, decoded.triple) == nil)
		}
		return strings.to_string(sb)
	}
	check_roundtrip(t, TRIPLE_FIXTURE, nt_load, export, nt_load)
}

@(test)
test_roundtrip_nquads :: proc(t: ^testing.T) {
	export :: proc(d: ^Dictionary, ds: ^Dataset) -> string {
		sb := strings.builder_make()
		w := strings.to_writer(&sb)
		it := match(ds, MATCH_ALL)
		defer match_destroy(&it)
		for q in match_next(&it) {
			assert(quads_fmt.emit(w, decode_quad(d, q)) == nil)
		}
		return strings.to_string(sb)
	}
	check_roundtrip(t, QUAD_FIXTURE, nq_load, export, nq_load)
}

@(test)
test_roundtrip_turtle :: proc(t: ^testing.T) {
	export :: proc(d: ^Dictionary, ds: ^Dataset) -> string {
		sb := strings.builder_make()
		w := strings.to_writer(&sb)
		e: turtle_fmt.Emitter
		assert(turtle_fmt.emitter_init(&e, w) == nil)
		defer turtle_fmt.emitter_destroy(&e)
		it := match(ds, MATCH_ALL)
		defer match_destroy(&it)
		for q in match_next(&it) {
			assert(turtle_fmt.emit(&e, decode_quad(d, q).triple) == nil)
		}
		assert(turtle_fmt.emitter_finish(&e) == nil)
		return strings.to_string(sb)
	}
	check_roundtrip(t, TRIPLE_FIXTURE, nt_load, export, ttl_load)
}

@(test)
test_roundtrip_trig :: proc(t: ^testing.T) {
	export :: proc(d: ^Dictionary, ds: ^Dataset) -> string {
		sb := strings.builder_make()
		w := strings.to_writer(&sb)
		e: trig_fmt.Emitter
		assert(trig_fmt.emitter_init(&e, w) == nil)
		defer trig_fmt.emitter_destroy(&e)
		it := match(ds, MATCH_ALL)
		defer match_destroy(&it)
		for q in match_next(&it) {
			assert(trig_fmt.emit(&e, decode_quad(d, q)) == nil)
		}
		assert(trig_fmt.emitter_finish(&e) == nil)
		return strings.to_string(sb)
	}
	check_roundtrip(t, QUAD_FIXTURE, nq_load, export, trig_load)
}
