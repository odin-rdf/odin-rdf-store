---
id: 001-lmdb-persistent-format-db-layout
level: adr
title: "LMDB persistent format: DB layout, term serialization, and meta schema"
number: 1
short_code: "STORE-A-0003"
created_at: 2026-08-04T21:04:35.601107+00:00
updated_at: 2026-08-04T21:10:59.552142+00:00
decision_date: 
decision_maker: 
parent: 
archived: false

tags:
  - "#adr"
  - "#phase/decided"


exit_criteria_met: false
initiative_id: NULL
---

# ADR-1: LMDB persistent format: DB layout, term serialization, and meta schema

## Context **[REQUIRED]**

The LMDB backend (STORE-I-0002) persists the term dictionary and the quad indexes in one LMDB environment. Everything written to disk is format: once databases exist, byte layouts can only change through explicit, versioned migration. This ADR pins those bytes. It builds on two prior decisions: STORE-A-0001 (Term_IDs: kind tag in high bits + dense per-kind counter; big-endian in keys so memcmp order equals numeric order; width recorded and mismatches rejected) and STORE-A-0002 (the match interface the layout must serve).

Constraints that shaped the format:

- **LMDB's default maximum key size is 511 bytes.** IRIs and literal lexical forms routinely exceed it in real data, so the term→ID mapping cannot key on full term content. This forces a hashed key for `term2id` — and the hash becomes persistent format, so it must be a pinned, stable algorithm the format owns. The parser's `rdf.hash` was considered and rejected for two reasons that stand independently of its "do not persist" doc rule (a boundary this project family set itself and could lift): (1) **width** — it is 64-bit, and for a persisted dedup key the birthday bound makes some collision ~0.7% likely at 500M distinct terms, so the v1 collision-reject path would be reachable at design-target scale; a 128-bit function is required regardless; (2) **ownership** — a storage format depending on another repo's in-memory utility staying byte-identical forever couples the parser's internals to on-disk data it has never heard of; formats must own their bytes in their own repo. (Note the two-algorithm "overhead" is nil at runtime: no code path computes both hashes — the in-memory backend uses Odin's built-in map hasher, the LMDB backend uses XXH3 — and XXH3 is the faster function per byte besides.)
- **No custom comparators** (STORE-A-0001): all ordering must be correct under memcmp, hence big-endian integers in keys.
- **The linked library is LMDB 0.9.35** (STORE-I-0002 context): only 0.9 API features are available — no development-branch checksums or encryption; integrity is the format's own concern (format/width fields, verified lookups).
- The index layout mirrors the in-memory backend's three graph-first permutations (STORE-I-0001 decision 2), and per STORE-I-0002 decision 6 uses plain keys, not DUPSORT.

## Decision **[REQUIRED]**

One LMDB environment with six named DBs. **Format rule zero: every integer stored anywhere in this format — keys, values, meta — is big-endian.** One rule, no per-DB exceptions (`MDB_INTEGERKEY` considered and deferred; see STORE-I-0002 decision 4).

### 1. `meta` — format identity and counters

String keys, 8-byte big-endian u64 values:

| Key | Value |
|---|---|
| `format` | format version; this ADR defines version **1** |
| `term_id_bits` | 32 or 64 — the Term_ID width the database was created with |
| `next_iri`, `next_blank`, `next_literal`, `next_triple` | per-kind next counter (dense ID assignment continues across reopens) |

Open-time rules: an empty environment is initialized with the current format and the running build's width. A `format` value this code does not know, or a `term_id_bits` differing from the running build's `TERM_ID_BITS`, aborts the open with a loud, specific error. No silent fallback, no auto-migration in v1.

### 2. Canonical term bytes

One serialization per term kind, used both as the `id2term` value and as the input to the `term2id` key hash. No kind byte inside (kind travels alongside — in the ID's tag bits or as an explicit prefix byte):

| Kind | Layout |
|---|---|
| IRI | raw IRI bytes (UTF-8, as interned) |
| Blank node | raw label bytes (generated, per-load-scoped labels — see STORE-I-0001) |
| Literal | `[datatype Term_ID: BE][direction: 1B][lang length: 1B][lang bytes][lexical bytes to end]` |
| Triple term | `[subject ID: BE][predicate ID: BE][object ID: BE]` |

Notes: a literal's datatype is stored as the Term_ID of its (always separately interned) datatype IRI — one copy of `xsd:string` per database, ever. The lexical form goes last so it needs no length prefix; the layout is prefix-unambiguous because every variable-length field before it is length-prefixed. Direction uses the parser's enum values (0=None, 1=LTR, 2=RTL). Language tags longer than 255 bytes are rejected at intern time (BCP 47 tags are far shorter in practice). Triple-term components are IDs, so a triple term's bytes are fixed-size and its content lives in its components' own entries.

### 3. `id2term` — ID → term

Key: the Term_ID, big-endian (8B at 64-bit width, 4B at 32-bit). Value: the canonical term bytes. Kind-clustered by construction (tag bits are the key's high bits). Sentinel-tagged IDs (`DEFAULT_GRAPH`, `WILDCARD`) are never entries.

### 4. `term2id` — term → ID

Key: `[kind: 1B][XXH3-128 of canonical term bytes: 16B]` — 17 bytes, fixed, immune to the 511-byte limit. Value: the Term_ID, big-endian. The hash algorithm is **XXH3-128 (`core:hash/xxhash`, seed 0)**, pinned by format version 1; changing it is a format bump.

Collision discipline — correctness must not rest on "128 bits is enough":
- **Lookup** (intern of a possibly-known term): on key hit, read `id2term` for the found ID and byte-compare the canonical bytes. Mismatch means hash collision → treated as not-found, proceed to insert.
- **Insert**: on `MDB_KEYEXIST`-style key hit with mismatching content (a true collision between distinct terms), the operation **fails with a distinct error**. Probability is ~2⁻⁶⁴ per pair; version 1 chooses detected-and-rejected over silent chaining. If it ever fires in practice, version 2 introduces DUPSORT chaining on this DB.

### 5. `gspo`, `gpos`, `gosp` — the quad indexes

Key: the four Term_IDs in the permutation's order, big-endian, concatenated — 32 bytes (64-bit width) or 16 (32-bit). Value: empty. `DEFAULT_GRAPH` appears as an ordinary graph-position value (sentinel tag sorts above all real kinds — default-graph quads cluster at the end of each index; position is irrelevant to correctness). Set semantics fall out of `put` with `NOOVERWRITE` on `gspo` (KEYEXIST = duplicate → not inserted, other two DBs untouched); range scans position a cursor with `SET_RANGE` on the bound big-endian prefix, exactly the in-memory dispatch translated to cursors.

### 6. What is deliberately not in version 1

No per-record format stamps (the single `meta` format covers the file), no checksums (0.9 has none; a corrupt-value error surfaces as a decode failure), no compression, no DUPSORT layouts, no `MDB_INTEGERKEY` (both recorded as benchmark-gated optimizations in STORE-I-0002 decision 4/6 — each is a format bump).

## Alternatives Analysis **[CONDITIONAL: Complex Decision]**

| Option | Pros | Cons | Risk Level | Implementation Cost |
|--------|------|------|------------|-------------------|
| Hashed 17B term2id keys + verified lookups (chosen) | Fixed small keys; immune to 511B limit; collision-safe by verification | One extra id2term read per intern probe; hash pinned forever | Low | Medium |
| Full canonical bytes as term2id keys | No hash, no verification read | Breaks at 511B keys — real IRIs/literals exceed it; raising LMDB's limit requires page-size games | High | Low |
| Inline-short / hash-long hybrid keys | Saves verification read for short terms | Two key forms in one DB; boundary is format; complexity for a probe-time micro-saving | Medium | Medium |
| Reuse parser `rdf.hash` (FNV-1a 64) | No new dependency | Explicitly documented non-persistable; 64-bit collision rate meaningful at scale | High | Low |
| Hash-as-ID (Oxigraph-style 128-bit IDs, no counters) | term2id disappears entirely | Abandons dense IDs — array-indexed reverse lookup and the STORE-A-0001 encoding with it; already rejected there | High | High |
| Little-endian integers in meta/values, BE only in keys | Native-order convenience | Two integer conventions in one file; the single-rule format is worth more than a bswap | Low | Low |

## Rationale **[REQUIRED]**

- **The 511-byte key limit is the forcing function**: any full-content key design is one long IRI away from a runtime failure, which is not a property a storage format may have. Hashing is therefore not an optimization but a requirement; making verification part of the lookup discipline removes the only downside that matters (silent collision).
- **XXH3-128 over alternatives**: available in Odin core (`core:hash/xxhash`), stable published algorithm, 128-bit width makes true collisions astronomically rare while verification makes even those harmless to reads. The parser's hash was designed for in-memory tables and reserves the right to change — exactly what a persisted format cannot tolerate.
- **Datatype-as-ID in literal bytes** deduplicates the most repetitive strings in RDF (datatype IRIs) and makes literal entries fixed-overhead + lexical. The cost — literal canonical bytes are database-relative (they embed this database's datatype IDs) — is irrelevant because canonical bytes never leave the database they were written in.
- **One endianness rule** (everything big-endian) trades a few no-op byte swaps on little-endian hosts for a format with no per-DB special cases — the same reasoning that rejected `set_compare` in STORE-A-0001.
- **Counters in `meta`, mirrored in memory** (the production idiom from odin-vengine's graph store): LMDB's single-writer rule makes the mirror safe, and persisting them keeps dense ID assignment stable across reopens — the property the whole dictionary design rests on.

## Consequences **[REQUIRED]**

### Positive
- Every DB's key is small and fixed-size; no term length can break the store.
- Reopen is O(meta): counters and identity checks only, no index rebuilding.
- memcmp-ordered keys preserve every property the in-memory backend established: kind clustering, prefix range scans, identical iteration order.
- Format identity (version + width) is checked before any data is touched; the failure mode for a mismatched build is a clear error, not corruption.

### Negative
- Every intern probe of an existing term costs one extra `id2term` read (verification). Bulk-load benchmarks will price this; a probe-cache is a non-format optimization if needed.
- XXH3-128 and every layout above are frozen into format version 1; improvements require explicit migration machinery that v1 does not include (a mismatched format simply refuses to open).
- A true 128-bit collision rejects an insert. Documented, detectable, and astronomically unlikely — but nonzero.

### Neutral
- The database file is not portable across Term_ID widths (by design, loudly enforced) — and LMDB files were never portable across endianness/page layouts anyway.
- Blank labels stored are the loader's generated per-scope labels, not source-document labels (consistent with STORE-I-0001's scoping decision).
- `DEFAULT_GRAPH` sorting after named graphs in the indexes is an artifact of the sentinel tag value; no code may rely on it beyond "contiguous range".

## Amendments

- **2026-08-07 — the in-memory backend this ADR compares against is retired (STORE-A-0006, STORE-I-0003); nothing in the format changes.** Four passages read as descriptions of a live peer and are now history: the Context note that "no code path computes both hashes — the in-memory backend uses Odin's built-in map hasher, the LMDB backend uses XXH3"; the Context line that "the index layout mirrors the in-memory backend's three graph-first permutations"; the Rationale that the parser's hash "was designed for in-memory tables"; and the Consequence that memcmp-ordered keys "preserve every property the in-memory backend established: kind clustering, prefix range scans, identical iteration order". They are left as written, because each records *why* a byte layout is the way it is, and that reasoning was true when the bytes were pinned. Two of them keep force on their own terms regardless: XXH3-128 is required by the 511-byte key limit and the ownership argument, neither of which mentions a second backend; and kind clustering and prefix range scans are properties of the big-endian key rule, so only the cross-backend *agreement* on iteration order is moot — see the matching annotation on STORE-A-0001 point 7. **Format version 1 is unaffected: no key, value, or meta byte changes, and no migration is implied.**

## Review Schedule **[CONDITIONAL: Temporary Decision]**

### Review Triggers
- Bulk-load or query benchmarks attribute measurable cost to intern verification reads or index key size — reopens the DUPSORT/`MDB_INTEGERKEY`/hybrid-key options as format version 2 candidates.
- A collision rejection is ever observed in practice — triggers DUPSORT chaining on `term2id` in format version 2.
- The time-travel variant initiative begins — its append/versioning needs may extend the layout (new DBs or value payloads) under a format bump.
- SPARQL's snapshot API lands — no format impact expected, but the review confirms iterator/cursor assumptions still hold.