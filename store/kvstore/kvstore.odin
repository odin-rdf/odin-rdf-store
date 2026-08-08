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
// Transactions (STORE-A-0007, and see txn.odin): one opaque Txn handle
// with a .Read/.Write mode, of which a read transaction *is* the
// snapshot. Every operation has a _txn form taking the handle alone,
// and the bare procedures are *defined* as autocommit over them — a
// transaction of the appropriate mode, one operation, closed. So insert
// commits its own write transaction and match opens a read transaction
// that its iterator owns until match_destroy, exactly as they always
// did (STORE-I-0002 decisions 2 and 3); what is new is that a caller
// can say more than one operation at a time. Standalone lookups copy
// into a caller-supplied allocator.
//
// The load_* procedures wrap each document in one write transaction,
// making a load atomic per document; their _txn forms cannot, since the
// transaction is the caller's. See load.odin.
//
// The linked library is LMDB 0.9.35; only 0.9 API entry points are
// used (see vendor/lmdb/README.md). darwin_arm64 is the only platform
// tested in v1 — other platforms fall back to a system liblmdb via the
// binding's foreign-import switch, untested here.
//
// Loaders are atomic per document (a parse error persists nothing) —
// a documented divergence from the in-memory package's keep-partial
// loaders; see load.odin.
//
// Two constructors, one contract: open takes a path and the data
// survives the process; open_ephemeral takes none and the data does
// not. Everything after the constructor is identical.
package kvstore

import "core:encoding/endian"
import "core:os"
import "core:strings"
import "core:time"

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
	os.Error,
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
	// A write transaction is already open on this Store, and a second
	// would deadlock on LMDB's writer lock. A programming error rather
	// than an environment failure, which is why it is a Store_Error;
	// see txn_begin.
	Write_Txn_Open,
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
	// Maximum database size. Reserve generously — growing it later
	// means reopening.
	//
	// **On Linux and macOS this reserves address space, not disk**: the
	// map is sparse, so a 1 GiB default costs nothing until the data
	// is there. **On Windows it reserves disk, at open.** LMDB has no
	// sparse-file handling on that platform; without MDB_WRITEMAP (which
	// this backend does not set) mdb_env_map calls SetEndOfFile at the
	// full map size before CreateFileMapping, because "Windows won't
	// create mappings for zero length files ... just set the maxsize
	// right now". NTFS then allocates and zero-fills the whole extent,
	// so every open pays for map_size in full.
	//
	// The consequence falls on anything that opens many short-lived
	// stores, which in practice means test suites: at the 1 GiB default
	// a Windows CI job spends minutes materializing files it never
	// writes to, where the same job on Linux spends seconds. A harness
	// that opens a store per test wants open_ephemeral, whose
	// EPHEMERAL_OPTIONS carries a scratch-sized map instead.
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

// EPHEMERAL_OPTIONS is open_ephemeral's default: a scratch-sized map
// and no fsync, neither of which a store that dies with the process
// has any use for.
//
// **16 MiB, and the number has an origin** (STORE-T-0033). Measured
// over every RDF document vendored in the family's three test suites:
// the largest single document leaves a 288 KiB high-water mark
// (SHACL's shacl-shacl-data-shapes.ttl, 415 quads), and loading an
// entire suite tree into one store — the upper bound if a harness ever
// shares one scratch store across a whole suite rather than opening
// one per test — leaves 2.03 MiB (odin-rdf-sparql's W3C tree, 3,977
// quads). 16 MiB is roughly 8x that aggregate and 56x the largest
// single document. Too small would turn a passing suite into
// MDB_MAP_FULL on a large fixture; too large is what made this
// procedure necessary, since on Windows every open materializes
// map_size in full (see Options.map_size). A caller with a bigger
// fixture passes a bigger map rather than growing this default.
//
// no_sync is unconditionally right here rather than a trade: the file
// is unlinked, so there is nothing for a durable commit to be durable
// for.
EPHEMERAL_OPTIONS :: Options {
	map_size    = 16 << 20,
	max_readers = 126,
	no_sync     = true,
}

// Store is the dataset + dictionary. One Store owns one LMDB
// environment; LMDB's single-writer rule makes the in-memory counter
// mirror safe. Whether it survives the process is the constructor's
// business (open / open_ephemeral) and nothing below this line's.
Store :: struct {
	env:       ^lmdb.Env,
	dbi:       [Db]lmdb.Dbi,
	// Per-kind next counters, mirroring meta; persisted in the same
	// write transaction as the entries they cover.
	next:         [4]u64,
	read_only:    bool,
	// The single-writer claim (STORE-A-0007): whether this handle has a
	// write transaction open, and what next was when it began. Every
	// path that opens a write transaction goes through write_txn_begin,
	// so a second one is refused rather than deadlocked and an abort
	// leaves the mirror equal to the persisted counters. See txn.odin.
	write_open:   bool,
	write_next:   [4]u64,
	// The file close must delete. Non-empty only for an ephemeral store
	// on a platform with no unlink-while-open; everywhere else
	// open_ephemeral unlinks before it returns and leaves this empty.
	scratch_path: string,
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

// open_ephemeral opens a store with no path the caller has to name,
// make unique, or clean up, and which does not outlive the process.
// Same store, same contract, same procedure set as open — only the
// storage's lifetime differs. It is the constructor a test suite, a
// scratch load, or a throwaway staging graph wants; anything whose
// data must survive the process wants open.
//
// **There is no cleanup path, by construction.** The database is one
// file (NOSUBDIR) with no lock file (NOLOCK), and on POSIX the path is
// unlinked as soon as env_open returns: the inode stays alive while
// LMDB holds the descriptor, is invisible in the filesystem namespace
// for the store's whole life, and is reclaimed by the kernel on close
// *or on crash*. Nothing is left for a later run to trip over and
// nothing has to be removed by hand.
//
// **Windows is the exception and it is stated rather than papered
// over**: there is no unlink-while-open, so the file survives until
// close deletes it. An abnormal termination leaks exactly one file in
// the temp directory.
//
// NOLOCK is legitimate here because an ephemeral store is exclusively
// the opening process's — no other process can find the file, let
// alone open it. It is *not* safe if the handle escapes the process by
// some other route: LMDB is then doing no inter-process
// synchronization at all. Do not hand an ephemeral store to a child
// process.
//
// opts.read_only is ignored: a read-only store that no one can ever
// write to is empty forever. Everything else is honoured; see
// EPHEMERAL_OPTIONS for why the default map is 16 MiB rather than
// DEFAULT_OPTIONS' 1 GiB.
open_ephemeral :: proc(opts := EPHEMERAL_OPTIONS, allocator := context.allocator) -> (s: ^Store, err: Error) {
	context.allocator = allocator

	path := ephemeral_reserve(allocator) or_return
	keep_path := false
	defer if !keep_path {
		delete(path)
	}

	s = new(Store)
	defer if err != nil {
		if s.env != nil {
			lmdb.env_close(s.env)
		}
		free(s)
		os.remove(path)
	}

	check(lmdb.env_create(&s.env)) or_return
	check(lmdb.env_set_maxdbs(s.env, lmdb.Dbi(len(Db)))) or_return
	check(lmdb.env_set_mapsize(s.env, lmdb.Size_T(opts.map_size))) or_return
	check(lmdb.env_set_maxreaders(s.env, opts.max_readers)) or_return

	// NOTLS as in open. NOSUBDIR makes the path the database file
	// rather than a directory holding one, which is what lets the file
	// be a single unlinkable inode. NOLOCK suppresses the reader table,
	// so there is no second file and no shared-memory segment to clean
	// up either.
	flags: u32 = lmdb.NOTLS | lmdb.NOSUBDIR | lmdb.NOLOCK
	if opts.no_sync {
		flags |= lmdb.NOSYNC
	}

	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	check(lmdb.env_open(s.env, cpath, flags, 0o600)) or_return

	open_databases(s) or_return

	// Every descriptor LMDB opens by name — the data file and, without
	// WRITEMAP, the synchronous meta descriptor — is open by the time
	// env_open returns, so unlinking now costs the store nothing. It
	// happens last so that the error defer above still has a path to
	// remove.
	when ODIN_OS == .Windows {
		s.scratch_path = path
		keep_path = true
	} else {
		os.remove(path)
	}
	return s, nil
}

// ephemeral_reserve wins a unique name in the OS temp directory by
// creating the file, then closes it and hands back the path — LMDB
// reopens it, and an empty file is a fresh environment to LMDB.
//
// Reserving by creation is the point: uniqueness is O_CREAT|O_EXCL's,
// not a naming scheme's. Twelve hand-rolled temp paths across this
// family keyed on pid, or on pid and a test name, and four of them
// collided the moment two tests ran at once on the same pid. There is
// no scheme here to get wrong — a lost race retries against the
// filesystem.
@(private)
ephemeral_reserve :: proc(allocator := context.allocator) -> (path: string, err: Error) {
	// An empty dir means the OS temp directory, resolved by core:os:
	// TMPDIR on POSIX, GetTempPathW on Windows. That is the dance this
	// procedure exists to stop everyone copying.
	// **Reserving is retried, because on Windows it transiently fails.**
	// odin-rdf-shacl's suite opens ~58 ephemeral stores across ten
	// threads and saw one or two per run fail with Permission_Denied —
	// ERROR_ACCESS_DENIED from CREATE_NEW on a fresh random name in the
	// temp directory, a different test each run. That is not a name
	// collision, which Windows reports as ERROR_ALREADY_EXISTS; it is
	// the signature of something else on the machine holding a file
	// briefly, which on a CI runner means a scanner or the indexer.
	//
	// os.create_temp_file retries only on .Exist, so it gives up on the
	// first such failure. Creating a temp file is idempotent and
	// cheap, so this retries anything, with a short pause between
	// attempts: a condition that clears in milliseconds is worth
	// waiting out, and one that does not is reported rather than
	// retried forever.
	//
	// The last error is what comes back, so a genuinely unusable temp
	// directory still says why on the way out.
	last: os.Error
	for attempt in 0 ..< RESERVE_ATTEMPTS {
		f, ferr := os.create_temp_file("", "odin-rdf-store-*.mdb")
		if ferr == nil {
			path = strings.clone(os.name(f), allocator)
			os.close(f)
			return path, nil
		}
		last = ferr
		if attempt < RESERVE_ATTEMPTS - 1 {
			time.sleep(RESERVE_BACKOFF)
		}
	}
	// The OS error verbatim, not a classification of it. This returned
	// .Temp_Unavailable until 2026-08-08, which said that something
	// went wrong and nothing about what: the Windows failure above was
	// undiagnosable from CI output because the one fact that mattered
	// had been thrown away here.
	return "", last
}

// Eight attempts over roughly 35ms. Sized for a transient hold by
// another process, not for a temp directory that is full or read-only —
// those fail eight times quickly and report what they said.
@(private)
RESERVE_ATTEMPTS :: 8

@(private)
RESERVE_BACKOFF :: 5 * time.Millisecond

// close releases the environment; every ID, iterator, and borrowed
// value obtained from the store becomes invalid. An ephemeral store's
// backing file goes with it — already unlinked on POSIX, deleted here
// on Windows.
close :: proc(s: ^Store, allocator := context.allocator) {
	context.allocator = allocator
	if s == nil {
		return
	}
	if s.env != nil {
		lmdb.env_close(s.env)
	}
	if s.scratch_path != "" {
		os.remove(s.scratch_path)
		delete(s.scratch_path)
	}
	free(s)
}

// open_databases opens the six named DBs and validates or initializes
// the meta identity per STORE-A-0003 §1.
//
// This is the one write transaction that does not go through
// write_txn_begin, and it does not need to: it runs inside open before
// the Store has been handed to anyone, so there is no other holder to
// refuse and no interning to roll back.
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
