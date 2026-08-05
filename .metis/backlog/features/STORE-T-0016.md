---
id: dataset-introspection-the-named
level: task
title: "Dataset introspection: the named-graph list, and the terms a graph holds"
short_code: "STORE-T-0016"
created_at: 2026-08-05T22:33:22.062758+00:00
updated_at: 2026-08-05T22:33:22.062758+00:00
parent: 
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/backlog"
  - "#feature"


exit_criteria_met: false
initiative_id: NULL
---

# Dataset introspection: the named-graph list, and the terms a graph holds

## Objective **[REQUIRED]**

Two read-only questions a query engine asks constantly and the match
interface cannot answer:

- **Which named graphs does this dataset have?**
- **Which terms does this graph mention?** — the subjects and objects of its
  quads, each once: RDF's *nodes* of a graph.

Both are answerable today only by scanning every quad and rebuilding a set
the store already has.

**Evidence — two operators in odin-rdf-sparql, each scanning the whole
dataset for one of them:**

1. **`Plan_Graph_Scan`** (`sparql/plan.odin`, SPARQL-T-0013). `GRAPH ?g { P }`
   normally needs no operator of its own: the graph position of every triple
   pattern in P becomes ?g's slot, and matching binds it. But when P matches
   no triples at all — `GRAPH ?g {}`, or a GRAPH whose body is only a VALUES
   block — there is nothing to carry the binding, and the clause still ranges
   over the named graphs. The engine scans everything and keeps the distinct
   graph IDs. Pinned by the DAWG's `graph-empty`.
2. **`path_collect_nodes`** (`sparql/exec.odin`, SPARQL-T-0016). §18.4's
   zero-length path binds each node of the active graph to itself, so
   `?X :p* ?Y` with both endpoints free has to enumerate nodes(G) —
   including literal objects, since a literal is a node of the graph. The
   engine reads every quad of the graph to do it.

The two hit the same gap from opposite sides: `match` can stream quads but
cannot be asked what the dataset *contains*. Both are correct today, and
both cost a full scan for something the indexes already know.

## Backlog Item Details **[CONDITIONAL: Backlog Item]**

### Type
- [x] Feature - New functionality or enhancement

### Priority
- [x] P1 - High (important for user experience)

The named-graph list is the more clearly useful of the two: a query engine
wants it constantly, and nothing else can produce it.

### Business Justification **[CONDITIONAL: Feature]**
- **User Value**: `GRAPH ?g { … }` over a large dataset stops costing a full scan to learn a list the store keeps anyway; a both-endpoints-free property path stops rebuilding the node set per query.
- **Business Value**: Removes the two remaining places where an operator's cost is the size of the *dataset* rather than the size of its answer.
- **Effort Estimate**: S for the graph list (memstore: the top level of a graph-first permutation index; kvstore: a cursor skipping from one graph prefix to the next). M for graph nodes, the harder half — a set the size of the graph's terms, which no backend materializes today.

## Acceptance Criteria **[REQUIRED]**

- [ ] `graphs(ds)` yields each named graph's Term_ID once (iterator or slice, per family convention). The default graph is not one of them — it has no name, the same distinction STORE-T-0017's named-graph wildcard turns on.
- [ ] `nodes(ds, graph)` yields each distinct subject and object of the graph once. Objects included: a literal is a node.
- [ ] Both are reads: no assignment, no write transaction, correct against a read-only environment open — the `find_term` posture STORE-T-0014 established.
- [ ] Conformance suite covers both over a dataset with several named graphs, a graph whose terms appear nowhere else, and the empty dataset. Both backends, both Term_ID widths.
- [ ] `store/interface.odin`'s contract states what "named graph" means here, and whether an answer is a snapshot or a live view (see STORE-T-0019).

## Implementation Notes **[CONDITIONAL: Technical Task]**

### Technical Approach

The graph list is nearly free in both backends: memstore's indexes are keyed
graph-first (GSPO/GPOS/GOSP), so the distinct graph IDs are the top level of
one of them; kvstore's keys are graph-prefixed for the same reason, so an
LMDB cursor can skip from one graph prefix to the next rather than reading
every key.

Graph nodes are the harder half and may not deserve the same shape. An
honest `nodes` either materializes a set per call — which is what the
consumer does today, so no worse — or is maintained on insert, which costs
write throughput and memory the vision may not want to spend. Worth deciding
separately: if only the graph list ships, one consumer is served and the
other keeps its scan.

### Dependencies

None. Consumer: odin-rdf-sparql (`Plan_Graph_Scan`, `path_collect_nodes`).
Related: STORE-T-0017 (named-graph wildcard) comes out of the same GRAPH
semantics and is worth considering alongside it.

### Risk Considerations

`nodes` invites a maintained index whose cost falls on writes. The consumer's
need is per-query enumeration, not membership, so an answer computed on
demand is acceptable and much cheaper to promise.

## Status Updates **[REQUIRED]**

- **2026-08-05 — Created from odin-rdf-sparql SPARQL-T-0019**, the evaluation initiative's evidence consolidation. Awaiting pickup in an odin-rdf-store session.
