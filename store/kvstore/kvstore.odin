// Package kvstore is the persistent LMDB backend of the match
// interface: the same procedure set and semantics as the in-memory
// package store (see the contract in store/interface.odin), over one
// LMDB environment on disk. Quads and the term dictionary survive
// process restarts with stable Term_IDs.
//
// On-disk format (ADR STORE-A-0003, format version 1): six named DBs —
// meta (format identity + per-kind counters), id2term/term2id (the
// dictionary), gspo/gpos/gosp (the quad indexes). Every integer in the
// file is big-endian, so memcmp key order equals numeric ID order.
//
// Transactions (STORE-I-0002 decisions 2 and 3): insert commits its
// own write transaction; match opens a read transaction owned by the
// iterator and released by match_destroy — matched quads are views of
// the MVCC snapshot, valid until then. Standalone lookups copy into a
// caller-supplied allocator. The load_* procedures wrap each document
// in one write transaction, making a load atomic per document.
//
// The linked library is LMDB 0.9.35; only 0.9 API entry points are
// used (see vendor/lmdb/README.md). darwin_arm64 is the only platform
// tested in v1 — other platforms fall back to a system liblmdb via the
// binding's foreign-import switch, untested here.
//
// Loaders are atomic per document (a parse error persists nothing) —
// a documented divergence from the in-memory package's keep-partial
// loaders; see load.odin.
package kvstore

import "core:encoding/endian"
import "core:os"
import "core:strings"

import lmdb "../../vendor/lmdb"
import store ".."

// FORMAT_VERSION is the on-disk format this code reads and writes
// (STORE-A-0003). A database recording any other version refuses to
// open.
FORMAT_VERSION :: 1

// Db names the six databases of the environment.
Db :: enum {
	Meta,
	Id2term,
	Term2id,
	Gspo,
	Gpos,
	Gosp,
}

@(private)
db_names :: [Db]cstring {
	.Meta    = "meta",
	.Id2term = "id2term",
	.Term2id = "term2id",
	.Gspo    = "gspo",
	.Gpos    = "gpos",
	.Gosp    = "gosp",
}

@(private)
META_FORMAT :: "format"
@(private)
META_TERM_ID_BITS :: "term_id_bits"

// Meta keys of the per-kind counters, indexed by store.Term_Kind for
// the four real kinds.
@(private)
meta_counter_keys :: [4]string{"next_iri", "next_blank", "next_literal", "next_triple"}

// Error is everything this backend can fail with. A Db_Error preserves
// the raw LMDB return code for strerror rendering.
Error :: union {
	Db_Error,
	Store_Error,
}

// Db_Error is a raw LMDB return code; see error_string.
Db_Error :: distinct i32

Store_Error :: enum {
	// The database's format version is unknown to this code.
	Unsupported_Format,
	// The database was created with the other Term_ID width
	// (STORE-A-0001: widths never mix silently).
	Width_Mismatch,
	// Two distinct terms hashed to the same term2id key — the
	// detected-and-rejected path of STORE-A-0003 §4.
	Hash_Collision,
	// A literal's language tag exceeds the format's 255-byte field.
	Language_Too_Long,
}

// error_string renders a Db_Error via mdb_strerror; the result is
// static storage owned by LMDB.
error_string :: proc(err: Db_Error) -> string {
	return string(lmdb.strerror(i32(err)))
}

@(private)
@(require_results)
check :: proc(rc: i32) -> Error {
	if rc != lmdb.SUCCESS {
		return Db_Error(rc)
	}
	return nil
}

// Options tunes the environment; see LMDB's own documentation for the
// underlying knobs.
Options :: struct {
	// Maximum database size. The map is sparse: this reserves address
	// space, not disk, so reserve generously — growing it later means
	// reopening.
	map_size:    uint,
	max_readers: u32,
	// Trades durability for write speed: a crash may lose recent
	// commits (the database stays consistent).
	no_sync:     bool,
	read_only:   bool,
}

DEFAULT_OPTIONS :: Options {
	map_size    = 1 << 30,
	max_readers = 126,
}

// Store is the persistent dataset + dictionary. One Store owns one
// LMDB environment; LMDB's single-writer rule makes the in-memory
// counter mirror safe.
Store :: struct {
	env:       ^lmdb.Env,
	dbi:       [Db]lmdb.Dbi,
	// Per-kind next counters, mirroring meta; persisted in the same
	// write transaction as the entries they cover.
	next:      [4]u64,
	read_only: bool,
}

// open opens (creating if absent) the store at path, a directory. A
// fresh environment is initialized to FORMAT_VERSION at the running
// build's Term_ID width; an existing one must match both or the open
// fails with Unsupported_Format / Width_Mismatch — never a silent
// fallback. On any error the returned store is invalid and must not
// be used or closed. This is the backend's dataset_init, with the
// extra parameters persistence requires.
open :: proc(path: string, opts := DEFAULT_OPTIONS, allocator := context.allocator) -> (s: ^Store, err: Error) {
	context.allocator = allocator

	if !opts.read_only && !os.exists(path) {
		// LMDB does not create its own directory unless NOSUBDIR is set.
		if os.make_directory(path) != nil {
			return nil, Db_Error(lmdb.NOTFOUND)
		}
	}

	s = new(Store)
	s.read_only = opts.read_only
	defer if err != nil {
		if s.env != nil {
			lmdb.env_close(s.env)
		}
		free(s)
	}

	check(lmdb.env_create(&s.env)) or_return
	check(lmdb.env_set_maxdbs(s.env, lmdb.Dbi(len(Db)))) or_return
	check(lmdb.env_set_mapsize(s.env, lmdb.Size_T(opts.map_size))) or_return
	check(lmdb.env_set_maxreaders(s.env, opts.max_readers)) or_return

	// NOTLS keeps read transactions off thread-local storage so
	// iterator handles are not pinned to the opening thread.
	flags: u32 = lmdb.NOTLS
	if opts.no_sync {
		flags |= lmdb.NOSYNC
	}
	if opts.read_only {
		flags |= lmdb.RDONLY
	}

	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	check(lmdb.env_open(s.env, cpath, flags, 0o664)) or_return

	open_databases(s) or_return
	return s, nil
}

// close releases the environment; every ID, iterator, and borrowed
// value obtained from the store becomes invalid.
close :: proc(s: ^Store, allocator := context.allocator) {
	context.allocator = allocator
	if s == nil {
		return
	}
	if s.env != nil {
		lmdb.env_close(s.env)
	}
	free(s)
}

// open_databases opens the six named DBs and validates or initializes
// the meta identity per STORE-A-0003 §1.
@(private)
open_databases :: proc(s: ^Store) -> (err: Error) {
	txn_flags: u32 = s.read_only ? lmdb.RDONLY : 0
	txn: ^lmdb.Txn
	check(lmdb.txn_begin(s.env, nil, txn_flags, &txn)) or_return
	committed := false
	defer if !committed {
		lmdb.txn_abort(txn)
	}

	names := db_names
	dbi_flags: u32 = s.read_only ? 0 : lmdb.CREATE
	for name, db in names {
		check(lmdb.dbi_open(txn, name, dbi_flags, &s.dbi[db])) or_return
	}

	format, has_format := meta_get(s, txn, META_FORMAT) or_return
	switch {
	case !has_format && !s.read_only:
		meta_put(s, txn, META_FORMAT, FORMAT_VERSION) or_return
		meta_put(s, txn, META_TERM_ID_BITS, store.TERM_ID_BITS) or_return
		for key in meta_counter_keys {
			meta_put(s, txn, key, 0) or_return
		}
		s.next = {}
	case format != FORMAT_VERSION:
		return .Unsupported_Format
	case:
		bits, _ := meta_get(s, txn, META_TERM_ID_BITS) or_return
		if bits != store.TERM_ID_BITS {
			return .Width_Mismatch
		}
		for key, i in meta_counter_keys {
			s.next[i], _ = meta_get(s, txn, key) or_return
		}
	}

	check(lmdb.txn_commit(txn)) or_return
	committed = true
	return nil
}

// Meta values are 8-byte big-endian u64 (format rule zero: every
// integer in the file is big-endian).
@(private)
meta_get :: proc(s: ^Store, txn: ^lmdb.Txn, name: string) -> (value: u64, found: bool, err: Error) {
	key := val_of_string(name)
	data: lmdb.Val
	rc := lmdb.get(txn, s.dbi[.Meta], &key, &data)
	if rc == lmdb.NOTFOUND {
		return 0, false, nil
	}
	check(rc) or_return

	bytes := val_bytes(data)
	if len(bytes) != size_of(u64) {
		return 0, false, .Unsupported_Format
	}
	value, _ = endian.get_u64(bytes, .Big)
	return value, true, nil
}

@(private)
meta_put :: proc(s: ^Store, txn: ^lmdb.Txn, name: string, value: u64) -> Error {
	key := val_of_string(name)
	buf: [size_of(u64)]u8
	endian.put_u64(buf[:], .Big, value)
	data := val_of(buf[:])
	return check(lmdb.put(txn, s.dbi[.Meta], &key, &data, 0))
}

@(private)
val_of :: proc(bytes: []u8) -> lmdb.Val {
	return lmdb.Val{mv_size = lmdb.Size_T(len(bytes)), mv_data = raw_data(bytes)}
}

@(private)
val_of_string :: proc(s: string) -> lmdb.Val {
	return lmdb.Val{mv_size = lmdb.Size_T(len(s)), mv_data = raw_data(s)}
}

@(private)
val_bytes :: proc(v: lmdb.Val) -> []u8 {
	return ([^]u8)(v.mv_data)[:v.mv_size]
}
