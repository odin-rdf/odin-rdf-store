package kvstore

import lmdb "../../vendor/lmdb"
import store ".."

// The three quad indexes (STORE-A-0003 §5): gspo/gpos/gosp hold every
// quad as a concatenated big-endian 4-ID key with an empty value, in
// the same graph-first permutations as the in-memory backend. Set
// semantics fall out of a NOOVERWRITE put on gspo; a match range scan
// is a cursor positioned with SET_RANGE on the bound prefix.
//
// This package implements the match interface procedure set with one
// shape deviation the contract permits per backend: operations that
// can fail against the environment (insert, count, match) also return
// an Error. Everything a match yields is a view of one MVCC snapshot:
// bare match opens that snapshot and the iterator owns it until
// match_destroy, while match_txn reads through the caller's and leaves
// it alone.

@(private)
QUAD_KEY_SIZE :: 4 * ID_SIZE

// Position orders of the three indexes, matching the in-memory
// backend so both agree on iteration order (STORE-A-0001 point 7).
@(private)
PERM_GSPO :: [4]int{store.QUAD_G, store.QUAD_S, store.QUAD_P, store.QUAD_O}
@(private)
PERM_GPOS :: [4]int{store.QUAD_G, store.QUAD_P, store.QUAD_O, store.QUAD_S}
@(private)
PERM_GOSP :: [4]int{store.QUAD_G, store.QUAD_O, store.QUAD_S, store.QUAD_P}

// encode_quad_key writes a quad's index key: its four IDs big-endian,
// in the permutation's position order.
@(private)
encode_quad_key :: proc(buf: []u8, q: store.Encoded_Quad, perm: [4]int) {
	for pos, i in perm {
		put_id_be(buf[i * ID_SIZE:][:ID_SIZE], q[pos])
	}
}

@(private)
decode_quad_key :: proc(bytes: []u8, perm: [4]int) -> (q: store.Encoded_Quad) {
	for pos, i in perm {
		q[pos] = get_id_be(bytes[i * ID_SIZE:][:ID_SIZE])
	}
	return q
}

// insert adds a quad, returning whether it was newly added (false:
// already present, nothing written).
//
// It is **autocommit**: a write transaction of its own, one operation,
// closed — which is a definition now rather than merely how it happens
// to work. It therefore claims the environment's single writer for the
// length of the call, and fails with .Write_Txn_Open if the caller
// already holds a write transaction. A caller that holds one wants
// insert_txn (STORE-I-0004).
insert :: proc(s: ^Store, q: store.Encoded_Quad) -> (added: bool, err: Error) {
	tx := txn_begin(s, .Write) or_return
	defer txn_abort(&tx)
	added = insert_txn(&tx, q) or_return
	txn_commit(&tx) or_return
	return added, nil
}

// insert_txn is insert through the caller's write transaction — the
// form that makes several quads land together, and the one a reader on
// the same transaction sees before it commits. The NOOVERWRITE put on
// gspo decides set membership; the other two indexes are only written
// for a fresh quad.
//
// **A write through a transaction invalidates every iterator open on
// that transaction** (store/interface.odin). Re-open after writing.
insert_txn :: proc(t: ^Txn, q: store.Encoded_Quad) -> (added: bool, err: Error) {
	for id in q {
		assert(id != store.WILDCARD, "insert: WILDCARD in stored quad")
	}
	s := t.s

	key_buf: [QUAD_KEY_SIZE]u8
	encode_quad_key(key_buf[:], q, PERM_GSPO)
	key := val_of(key_buf[:])
	empty := lmdb.Val{}
	rc := lmdb.put(t.txn, s.dbi[.Gspo], &key, &empty, lmdb.NOOVERWRITE)
	if rc == lmdb.KEYEXIST {
		return false, nil
	}
	check(rc) or_return

	encode_quad_key(key_buf[:], q, PERM_GPOS)
	key = val_of(key_buf[:])
	check(lmdb.put(t.txn, s.dbi[.Gpos], &key, &empty, 0)) or_return
	encode_quad_key(key_buf[:], q, PERM_GOSP)
	key = val_of(key_buf[:])
	check(lmdb.put(t.txn, s.dbi[.Gosp], &key, &empty, 0)) or_return
	return true, nil
}

// count returns the number of quads in the dataset — O(1) via gspo's
// entry count. Autocommit: its own read transaction, so two counts are
// two snapshots.
count :: proc(s: ^Store) -> (n: int, err: Error) {
	tx := txn_begin(s, .Read) or_return
	defer txn_abort(&tx)
	return count_txn(&tx)
}

// count_txn is count through the caller's transaction: the number of
// quads that transaction can see, including its own uncommitted
// insertions.
count_txn :: proc(t: ^Txn) -> (n: int, err: Error) {
	stat: lmdb.Stat
	check(lmdb.stat(t.txn, t.s.dbi[.Gspo], &stat)) or_return
	return int(stat.ms_entries), nil
}

// Match_Iterator streams the quads satisfying a pattern over a cursor
// and the transaction that cursor reads through.
//
// owned is the whole of the ownership question: it holds a transaction
// only for an iterator from bare match, which opened one for itself,
// and stays zero for one from match_txn, which borrows the caller's.
// match_destroy ends it either way, and ending a zeroed handle is a
// no-op — so a borrowed transaction is left alone without a flag to
// branch on.
Match_Iterator :: struct {
	txn:        ^lmdb.Txn,
	owned:      Txn,
	cursor:     ^lmdb.Cursor,
	pattern:    store.Match_Pattern,
	perm:       [4]int,
	prefix:     [QUAD_KEY_SIZE]u8,
	prefix_len: int, // bytes of bound key prefix; 0 = full scan
	state:      enum {
		First,
		Iterating,
		Done,
	},
}

// match returns an iterator over the quads matching a pattern.
//
// Autocommit, with the one wrinkle in that story: the operation's
// result outlives the call, so the transaction match opens is closed by
// match_destroy rather than before the return. Every quad the iterator
// yields is therefore a view of one snapshot — but a *different*
// snapshot from the next match's, which is what match_txn exists to
// fix. On error the iterator is invalid and needs no destroy.
match :: proc(s: ^Store, pattern: store.Match_Pattern) -> (it: Match_Iterator, err: Error) {
	tx := txn_begin(s, .Read) or_return
	it, err = match_txn(&tx, pattern)
	if err != nil {
		txn_abort(&tx)
		return it, err
	}
	// Hand the transaction to the iterator, which now ends it.
	it.owned = tx
	return it, nil
}

// match_txn is match through the caller's transaction: the iterator
// borrows it, so match_destroy closes the cursor and leaves the
// transaction alone. This is what makes several reads one answer about
// one dataset, and it is how a reader sees its own transaction's
// uncommitted writes.
//
// Served by the index with the longest run of bound leading positions —
// wildcard-graph patterns full-scan gspo with filtering, the accepted
// three-index trade-off (STORE-I-0002 decision 6).
//
// **The iterator is valid until match_destroy, a write through this
// same transaction, or this transaction's commit or abort — whichever
// comes first.** Writing through a transaction invalidates every
// iterator open on it; the contract forbids the combination rather than
// defining it (store/interface.odin), so re-open after writing. On
// error the iterator is invalid and needs no destroy.
match_txn :: proc(t: ^Txn, pattern: store.Match_Pattern) -> (it: Match_Iterator, err: Error) {
	perms := [3][4]int{PERM_GSPO, PERM_GPOS, PERM_GOSP}
	dbis := [3]Db{.Gspo, .Gpos, .Gosp}

	best, best_len := 0, 0
	for perm, i in perms {
		plen := 0
		for pos in perm {
			if pattern[pos] == store.WILDCARD {
				break
			}
			plen += 1
		}
		if plen > best_len {
			best, best_len = i, plen
		}
	}

	it.pattern = pattern
	it.perm = perms[best]
	it.prefix_len = best_len * ID_SIZE
	for i in 0 ..< best_len {
		put_id_be(it.prefix[i * ID_SIZE:][:ID_SIZE], pattern[it.perm[i]])
	}

	it.txn = t.txn
	rc := lmdb.cursor_open(it.txn, t.s.dbi[dbis[best]], &it.cursor)
	if rc != lmdb.SUCCESS {
		it.txn = nil
		return it, Db_Error(rc)
	}
	it.state = .First
	return it, nil
}

// match_next yields the next matching quad, decoded from the cursor's
// key bytes — no allocation per result. ok=false once the cursor
// leaves the bound prefix or the index ends, and on every call
// thereafter.
match_next :: proc(it: ^Match_Iterator) -> (q: store.Encoded_Quad, ok: bool) {
	if it.state == .Done {
		return {}, false
	}

	key, data: lmdb.Val
	op: lmdb.Cursor_Op
	if it.state == .First {
		it.state = .Iterating
		if it.prefix_len > 0 {
			// SET_RANGE with the shorter prefix key positions at the
			// first full key >= it, i.e. the first key in the range.
			key = val_of(it.prefix[:it.prefix_len])
			op = .SET_RANGE
		} else {
			op = .FIRST
		}
	} else {
		op = .NEXT
	}

	for {
		if lmdb.cursor_get(it.cursor, &key, &data, op) != lmdb.SUCCESS {
			it.state = .Done
			return {}, false
		}
		op = .NEXT

		key_bytes := val_bytes(key)
		if it.prefix_len > 0 &&
		   string(key_bytes[:it.prefix_len]) != string(it.prefix[:it.prefix_len]) {
			// Sorted keys: once past the prefix, nothing later matches.
			it.state = .Done
			return {}, false
		}
		candidate := decode_quad_key(key_bytes, it.perm)
		if store.pattern_matches(it.pattern, candidate) {
			return candidate, true
		}
	}
}

// match_destroy closes the iterator's cursor, and ends its transaction
// if the iterator opened one. Required by the contract, and actually
// load-bearing in this backend.
match_destroy :: proc(it: ^Match_Iterator) {
	if it.cursor != nil {
		lmdb.cursor_close(it.cursor)
	}
	// Zero for a borrowed transaction, and ending a zeroed handle is a
	// no-op — so the caller's transaction survives its iterators.
	txn_abort(&it.owned)
	it^ = {}
}
