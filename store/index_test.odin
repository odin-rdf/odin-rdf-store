package store

// White-box checks of the permutation-index internals — deliberately
// separate from the implementation-agnostic conformance suite in
// dataset_test.odin.

import "core:testing"
import rdf "../../odin-rdf-parser/rdf"

@(test)
test_indexes_stay_consistent :: proc(t: ^testing.T) {
	d: Dictionary
	dictionary_init(&d)
	defer dictionary_destroy(&d)
	ds: Dataset
	dataset_init(&ds)
	defer dataset_destroy(&ds)

	// A grid of quads inserted in scrambled order, with duplicates.
	subjects := [?]string{"s0", "s1", "s2"}
	graphs := [?]rdf.Graph_Label{nil, rdf.IRI("http://example.org/g")}
	quads := make([dynamic]Encoded_Quad)
	defer delete(quads)
	for s, si in subjects {
		for g in graphs {
			q := rdf.Quad {
				triple = rdf.Triple {
					subject   = rdf.IRI(s),
					predicate = rdf.IRI("http://example.org/p"),
					object    = rdf.literal(subjects[(si + 1) % len(subjects)]),
				},
				graph = g,
			}
			append(&quads, encode_quad(&d, q))
		}
	}
	order := [?]int{5, 0, 3, 1, 4, 2, 3, 0, 5} // scrambled, with repeats
	for i in order {
		insert(&ds, quads[i])
	}
	flush(&ds) // white-box: force pending quads into the index arrays

	// All three indexes hold the same number of quads (the dataset
	// size) ...
	testing.expect_value(t, len(ds.gspo), count(&ds))
	testing.expect_value(t, len(ds.gpos), count(&ds))
	testing.expect_value(t, len(ds.gosp), count(&ds))
	testing.expect_value(t, count(&ds), len(quads))

	// ... each strictly sorted under its own permutation (strict:
	// sorted and duplicate-free) ...
	check_sorted :: proc(t: ^testing.T, quads: []Encoded_Quad, perm: [4]int) {
		for i in 1 ..< len(quads) {
			testing.expect(t, permuted_compare(quads[i-1], quads[i], perm) < 0)
		}
	}
	check_sorted(t, ds.gspo[:], PERM_GSPO)
	check_sorted(t, ds.gpos[:], PERM_GPOS)
	check_sorted(t, ds.gosp[:], PERM_GOSP)

	// ... and over the same quad set.
	seen := make(map[Encoded_Quad]struct {})
	defer delete(seen)
	for q in ds.gspo {
		seen[q] = {}
	}
	for q in ds.gpos {
		_, ok := seen[q]
		testing.expect(t, ok)
	}
	for q in ds.gosp {
		_, ok := seen[q]
		testing.expect(t, ok)
	}
}
