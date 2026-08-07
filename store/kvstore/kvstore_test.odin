package kvstore

import "core:encoding/endian"
import "core:fmt"
import "core:os"
import "core:testing"

import lmdb "../../vendor/lmdb"
import store ".."

// scratch_store opens a store no test has to name or clean up. This is
// what a test wants unless it is testing open itself; see
// STORE-T-0033.
@(private)
scratch_store :: proc() -> ^Store {
	s, err := open_ephemeral()
	assert(err == nil, "test store must open")
	return s
}

// test_db_path creates a fresh database directory under the OS temp
// directory and returns it; callers remove it with remove_test_db.
//
// Only the handful of tests that need a path *as their subject* still
// use this — reopening a closed store, opening one read-only, and
// rewriting a meta value behind the store's back all name a database
// twice, which is precisely what an ephemeral store cannot do.
// Everything else takes scratch_store.
//
// The OS temp directory and a name no concurrent caller can compute
// are both core:os's here, not this file's. The hand-rolled version
// (TMPDIR → TEMP → TMP → /tmp, trailing-separator trim, pid suffix)
// went twelve ways across this family and collided four times, always
// on a uniqueness scheme rather than on the boilerplate around it;
// make_directory_temp wins the name with mkdir and retries a lost
// race. name survives only so a leftover directory says which test
// left it.
@(private)
test_db_path :: proc(name: string) -> string {
	path, err := os.make_directory_temp("", fmt.tprintf("odin-rdf-store-test-%s-*", name), context.allocator)
	assert(err == nil, "the OS temp directory must be writable")
	return path
}

@(private)
remove_test_db :: proc(path: string) {
	os.remove(fmt.tprintf("%s/data.mdb", path))
	os.remove(fmt.tprintf("%s/lock.mdb", path))
	os.remove(path)
	delete(path)
}

@(test)
test_open_initializes_meta :: proc(t: ^testing.T) {
	path := test_db_path("init")
	defer remove_test_db(path)

	s, err := open(path)
	testing.expect(t, err == nil)
	defer close(s)

	testing.expect_value(t, s.next, [4]u64{})
	testing.expect_value(t, s.read_only, false)
}

@(test)
test_reopen_succeeds :: proc(t: ^testing.T) {
	path := test_db_path("reopen")
	defer remove_test_db(path)

	s, err := open(path)
	testing.expect(t, err == nil)
	close(s)

	s2, err2 := open(path)
	testing.expect(t, err2 == nil)
	close(s2)

	// Read-only reopen of an existing database also works.
	opts := DEFAULT_OPTIONS
	opts.read_only = true
	s3, err3 := open(path, opts)
	testing.expect(t, err3 == nil)
	close(s3)
}

// rewrite_meta corrupts one meta value in place through the binding —
// the only way to simulate a foreign-format or other-width database
// within a single test binary.
@(private = "file")
rewrite_meta :: proc(t: ^testing.T, path: string, name: string, value: u64) {
	env: ^lmdb.Env
	testing.expect_value(t, lmdb.env_create(&env), i32(lmdb.SUCCESS))
	defer lmdb.env_close(env)
	testing.expect_value(t, lmdb.env_set_maxdbs(env, lmdb.Dbi(len(Db))), i32(lmdb.SUCCESS))
	cpath := fmt.ctprintf("%s", path)
	testing.expect_value(t, lmdb.env_open(env, cpath, lmdb.NOTLS, 0o664), i32(lmdb.SUCCESS))

	txn: ^lmdb.Txn
	testing.expect_value(t, lmdb.txn_begin(env, nil, 0, &txn), i32(lmdb.SUCCESS))
	dbi: lmdb.Dbi
	testing.expect_value(t, lmdb.dbi_open(txn, "meta", 0, &dbi), i32(lmdb.SUCCESS))

	key := val_of_string(name)
	buf: [size_of(u64)]u8
	endian.put_u64(buf[:], .Big, value)
	data := val_of(buf[:])
	testing.expect_value(t, lmdb.put(txn, dbi, &key, &data, 0), i32(lmdb.SUCCESS))
	testing.expect_value(t, lmdb.txn_commit(txn), i32(lmdb.SUCCESS))
}

@(test)
test_open_rejects_unknown_format :: proc(t: ^testing.T) {
	path := test_db_path("badformat")
	defer remove_test_db(path)

	s, err := open(path)
	testing.expect(t, err == nil)
	close(s)

	rewrite_meta(t, path, META_FORMAT, 999)

	// On error the returned store is invalid; only err is meaningful.
	_, err2 := open(path)
	testing.expect_value(t, err2, Error(Store_Error.Unsupported_Format))
}

@(test)
test_open_rejects_width_mismatch :: proc(t: ^testing.T) {
	path := test_db_path("badwidth")
	defer remove_test_db(path)

	s, err := open(path)
	testing.expect(t, err == nil)
	close(s)

	// Pretend the database was created by the build of the other width.
	other := u64(store.TERM_ID_BITS == 64 ? 32 : 64)
	rewrite_meta(t, path, META_TERM_ID_BITS, other)

	_, err2 := open(path)
	testing.expect_value(t, err2, Error(Store_Error.Width_Mismatch))
}
