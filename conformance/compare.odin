package conformance

import "core:testing"

import rdf "../../odin-rdf-parser/rdf"

// blank_label extracts the label when the term is a blank node.
@(private)
blank_label :: proc(term: rdf.Term) -> (string, bool) {
	if b, ok := term.(rdf.Blank_Node); ok {
		return string(b), true
	}
	return "", false
}

// quads_equal_mod_blanks checks set equality under some bijection of
// blank-node labels, built greedily: each round commits the a-quads
// with exactly one compatible b-quad under the mapping so far. Zero
// candidates fail the check; fixtures must be unambiguous enough that
// every round makes progress (blank nodes distinguishable by ground
// context; no blanks inside triple terms). Used by the round-trip
// tests of every backend.
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
