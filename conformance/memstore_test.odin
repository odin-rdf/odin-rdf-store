package conformance

// The memstore backend's instantiation of the conformance suite: a
// Backend adapter over memstore.Dataset/memstore.Dictionary and one thin
// @(test) wrapper per check_* procedure, each on a fresh instance.

import "core:testing"

import "rdf:rdf"
import "../store"
import memstore "../store/memstore"

@(private = "file")
Memstore_Backend :: struct {
	d:  memstore.Dictionary,
	ds: memstore.Dataset,
}

@(private = "file")
memstore_backend_init :: proc(m: ^Memstore_Backend) -> Backend {
	memstore.dictionary_init(&m.d)
	memstore.dataset_init(&m.ds)
	return Backend {
		ctx = m,
		insert = proc(ctx: rawptr, q: store.Encoded_Quad) -> bool {
			return memstore.insert(&(^Memstore_Backend)(ctx).ds, q)
		},
		count = proc(ctx: rawptr) -> int {
			return memstore.count(&(^Memstore_Backend)(ctx).ds)
		},
		match_begin = proc(ctx: rawptr, pattern: store.Match_Pattern) -> rawptr {
			it := new(memstore.Match_Iterator)
			it^ = memstore.match(&(^Memstore_Backend)(ctx).ds, pattern)
			return it
		},
		match_next = proc(it: rawptr) -> (store.Encoded_Quad, bool) {
			return memstore.match_next((^memstore.Match_Iterator)(it))
		},
		match_destroy = proc(it: rawptr) {
			typed := (^memstore.Match_Iterator)(it)
			memstore.match_destroy(typed)
			free(typed)
		},
		intern_term = proc(ctx: rawptr, term: rdf.Term) -> store.Term_ID {
			return memstore.intern_term(&(^Memstore_Backend)(ctx).d, term)
		},
		encode_quad = proc(ctx: rawptr, q: rdf.Quad) -> store.Encoded_Quad {
			return memstore.encode_quad(&(^Memstore_Backend)(ctx).d, q)
		},
		intern_graph = proc(ctx: rawptr, g: rdf.Graph_Label) -> store.Term_ID {
			return memstore.intern_graph_label(&(^Memstore_Backend)(ctx).d, g)
		},
		find_term = proc(ctx: rawptr, term: rdf.Term) -> (store.Term_ID, bool) {
			return memstore.find_term(&(^Memstore_Backend)(ctx).d, term)
		},
		find_graph = proc(ctx: rawptr, g: rdf.Graph_Label) -> (store.Term_ID, bool) {
			return memstore.find_graph_label(&(^Memstore_Backend)(ctx).d, g)
		},
		dict_size = proc(ctx: rawptr) -> int {
			d := &(^Memstore_Backend)(ctx).d
			return len(d.iris) + len(d.blanks) + len(d.literals) + len(d.triples)
		},
	}
}

@(private = "file")
memstore_backend_destroy :: proc(m: ^Memstore_Backend) {
	memstore.dataset_destroy(&m.ds)
	memstore.dictionary_destroy(&m.d)
}

@(test)
test_memstore_all_16_patterns :: proc(t: ^testing.T) {
	m: Memstore_Backend
	b := memstore_backend_init(&m)
	defer memstore_backend_destroy(&m)
	check_all_16_patterns(t, &b)
}

@(test)
test_memstore_set_semantics :: proc(t: ^testing.T) {
	m: Memstore_Backend
	b := memstore_backend_init(&m)
	defer memstore_backend_destroy(&m)
	check_set_semantics(t, &b)
}

@(test)
test_memstore_empty_dataset :: proc(t: ^testing.T) {
	m: Memstore_Backend
	b := memstore_backend_init(&m)
	defer memstore_backend_destroy(&m)
	check_empty_dataset(t, &b)
}

@(test)
test_memstore_no_match_and_exhaustion :: proc(t: ^testing.T) {
	m: Memstore_Backend
	b := memstore_backend_init(&m)
	defer memstore_backend_destroy(&m)
	check_no_match_and_exhaustion(t, &b)
}

@(test)
test_memstore_default_vs_named_graphs :: proc(t: ^testing.T) {
	m: Memstore_Backend
	b := memstore_backend_init(&m)
	defer memstore_backend_destroy(&m)
	check_default_vs_named_graphs(t, &b)
}

@(test)
test_memstore_find_term :: proc(t: ^testing.T) {
	m: Memstore_Backend
	b := memstore_backend_init(&m)
	defer memstore_backend_destroy(&m)
	check_find_term(t, &b)
}
