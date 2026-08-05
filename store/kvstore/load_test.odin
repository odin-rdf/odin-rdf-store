package kvstore

import "core:mem"
import "core:strings"
import "core:testing"

import "rdf:rdf"
import quads_fmt "rdf:rdf/quads"
import "../../conformance"
import store ".."

@(private = "file")
EX :: "http://example.org/"

@(private = "file")
decode_all :: proc(t: ^testing.T, s: ^Store, allocator: mem.Allocator) -> [dynamic]rdf.Quad {
	result := make([dynamic]rdf.Quad)
	it, merr := match(s, store.MATCH_ALL)
	testing.expect(t, merr == nil)
	defer match_destroy(&it)
	for q in match_next(&it) {
		decoded, derr := decode_quad(s, q, allocator)
		testing.expect(t, derr == nil)
		append(&result, decoded)
	}
	return result
}

@(test)
test_load_four_formats :: proc(t: ^testing.T) {
	path, s := with_store("load-formats")
	defer remove_test_db(path)
	defer close(s)

	nt := `<http://example.org/alice> <http://example.org/knows> <http://example.org/bob> .
_:b0 <http://example.org/says> "hello" .`
	added, perr, err := load_triples(s, transmute([]u8)nt)
	testing.expect(t, err == nil)
	testing.expect_value(t, perr.message, "")
	testing.expect_value(t, added, 2)

	ttl := `@prefix ex: <http://example.org/> .
ex:alice ex:knows ex:carol ; ex:age 42 .`
	added2, perr2, err2 := load_turtle(s, transmute([]u8)ttl)
	testing.expect(t, err2 == nil)
	testing.expect_value(t, perr2.message, "")
	testing.expect_value(t, added2, 2)

	nq := `<http://example.org/s> <http://example.org/p> "chat"@fr <http://example.org/g1> .`
	added3, perr3, err3 := load_quads(s, transmute([]u8)nq)
	testing.expect(t, err3 == nil)
	testing.expect_value(t, perr3.message, "")
	testing.expect_value(t, added3, 1)

	trig := `@prefix ex: <http://example.org/> .
ex:g1 { ex:s2 ex:p ex:o . }
GRAPH _:g { _:b ex:p "x" . }`
	added4, perr4, err4 := load_trig(s, transmute([]u8)trig)
	testing.expect(t, err4 == nil)
	testing.expect_value(t, perr4.message, "")
	testing.expect_value(t, added4, 2)

	n, cerr := count(s)
	testing.expect(t, cerr == nil)
	testing.expect_value(t, n, 7)

	// Spot matches through the interface: prefixed names expanded, the
	// target graphs honored.
	alice, _ := intern_term(s, rdf.IRI(EX + "alice"))
	knows, _ := intern_term(s, rdf.IRI(EX + "knows"))
	it, merr := match(s, store.Match_Pattern{alice, knows, store.WILDCARD, store.WILDCARD})
	testing.expect(t, merr == nil)
	defer match_destroy(&it)
	from_alice := 0
	for _ in match_next(&it) {
		from_alice += 1
	}
	testing.expect_value(t, from_alice, 2) // bob (NT) + carol (Turtle)

	g1, _ := intern_graph_label(s, rdf.IRI(EX + "g1"))
	it2, merr2 := match(s, store.Match_Pattern{store.WILDCARD, store.WILDCARD, store.WILDCARD, g1})
	testing.expect(t, merr2 == nil)
	defer match_destroy(&it2)
	in_g1 := 0
	for _ in match_next(&it2) {
		in_g1 += 1
	}
	testing.expect_value(t, in_g1, 2) // one from N-Quads, one from TriG
}

@(test)
test_load_atomic_per_document :: proc(t: ^testing.T) {
	// A parse error aborts the whole document's transaction: nothing
	// persists — the documented divergence from the in-memory loader's
	// keep-partial behavior.
	path, s := with_store("load-atomic")
	defer remove_test_db(path)
	defer close(s)

	src := `<http://example.org/a> <http://example.org/p> "ok" .
<http://example.org/a> <http://example.org/p> "missing dot"`
	added, perr, err := load_triples(s, transmute([]u8)src)
	testing.expect(t, err == nil)
	testing.expect(t, perr.message != "")
	testing.expect_value(t, perr.line, 2)
	testing.expect(t, perr.column >= 1)
	testing.expect_value(t, added, 0)

	n, _ := count(s)
	testing.expect_value(t, n, 0)
}

@(test)
test_load_blank_scoping_across_reopen :: proc(t: ^testing.T) {
	path := test_db_path("load-scope")
	defer remove_test_db(path)

	with_blanks := `_:b0 <http://example.org/p> "x" .`
	ground := `<http://example.org/s> <http://example.org/p> "x" .`

	s, err := open(path)
	testing.expect(t, err == nil)
	a1, _, _ := load_triples(s, transmute([]u8)with_blanks)
	g1, _, _ := load_triples(s, transmute([]u8)ground)
	testing.expect_value(t, a1, 1)
	testing.expect_value(t, g1, 1)
	close(s)

	s2, err2 := open(path)
	testing.expect(t, err2 == nil)
	defer close(s2)

	// Same blank label after a reopen: still a distinct node (persisted
	// counters — no label reuse), so a distinct quad ...
	a2, _, _ := load_triples(s2, transmute([]u8)with_blanks)
	testing.expect_value(t, a2, 1)
	// ... while the ground document is an exact duplicate.
	g2, _, _ := load_triples(s2, transmute([]u8)ground)
	testing.expect_value(t, g2, 0)

	n, _ := count(s2)
	testing.expect_value(t, n, 3)
}

@(test)
test_load_survives_buffer_reuse_and_reopen :: proc(t: ^testing.T) {
	// The persistent form of the RDF-A-0001 proof: load adversarial
	// content (escapes, non-ASCII) from a buffer, overwrite the buffer,
	// close and reopen the database — the content must be intact.
	path := test_db_path("load-borrow")
	defer remove_test_db(path)

	src := `<http://example.org/café> <http://example.org/note> "h\"i\né" .
<http://example.org/plain> <http://example.org/note> "borrowed" .`
	buffer := make([]u8, len(src))
	defer delete(buffer)
	copy(buffer, src)

	s, err := open(path)
	testing.expect(t, err == nil)
	added, perr, lerr := load_triples(s, buffer)
	testing.expect(t, lerr == nil)
	testing.expect_value(t, perr.message, "")
	testing.expect_value(t, added, 2)
	for &b in buffer {
		b = 'Z'
	}
	close(s)

	s2, err2 := open(path)
	testing.expect(t, err2 == nil)
	defer close(s2)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	allocator := mem.dynamic_arena_allocator(&arena)

	expected := [?]rdf.Quad {
		{triple = {rdf.IRI(EX + "café"), rdf.IRI(EX + "note"), rdf.literal("h\"i\né")}},
		{triple = {rdf.IRI(EX + "plain"), rdf.IRI(EX + "note"), rdf.literal("borrowed")}},
	}
	decoded := decode_all(t, s2, allocator)
	defer delete(decoded)
	found := 0
	for q in decoded {
		for exp in expected {
			if rdf.equal(q, exp) {
				found += 1
			}
		}
	}
	testing.expect_value(t, found, 2)
}

@(test)
test_load_roundtrip_with_reopen :: proc(t: ^testing.T) {
	// load → close → reopen → export via the parser emitters → reload
	// into a fresh store → same quad set modulo blank relabeling.
	path := test_db_path("load-rt-a")
	defer remove_test_db(path)
	path_b := test_db_path("load-rt-b")
	defer remove_test_db(path_b)

	fixture := `<http://example.org/alice> <http://example.org/knows> <http://example.org/bob> .
_:x <http://example.org/says> "h\"i\n" <http://example.org/g1> .
_:x <http://example.org/knows> _:y <http://example.org/g1> .
_:y <http://example.org/name> "Yéti"@fr _:g .`

	s, err := open(path)
	testing.expect(t, err == nil)
	added, perr, lerr := load_quads(s, transmute([]u8)fixture)
	testing.expect(t, lerr == nil)
	testing.expect_value(t, perr.message, "")
	testing.expect_value(t, added, 4)
	close(s)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	allocator := mem.dynamic_arena_allocator(&arena)

	s2, err2 := open(path)
	testing.expect(t, err2 == nil)
	original := decode_all(t, s2, allocator)
	defer delete(original)

	sb := strings.builder_make()
	defer strings.builder_destroy(&sb)
	w := strings.to_writer(&sb)
	for q in original {
		testing.expect(t, quads_fmt.emit(w, q) == nil)
	}
	close(s2)

	sb_bytes := transmute([]u8)strings.to_string(sb)
	fresh, err3 := open(path_b)
	testing.expect(t, err3 == nil)
	defer close(fresh)
	reloaded_count, perr2, lerr2 := load_quads(fresh, sb_bytes)
	testing.expect(t, lerr2 == nil)
	testing.expect_value(t, perr2.message, "")
	testing.expect_value(t, reloaded_count, 4)

	reloaded := decode_all(t, fresh, allocator)
	defer delete(reloaded)
	testing.expect(t, conformance.quads_equal_mod_blanks(t, original[:], reloaded[:]))
}
