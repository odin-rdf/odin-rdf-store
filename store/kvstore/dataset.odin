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
// an Error. Iterators own their read transaction — everything a match
// yields is a view of one MVCC snapshot, valid until match_destroy.

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

// insert adds a quad in its own write transaction, returning whether
// it was newly added (false: already present, nothing written).
insert :: proc(s: ^Store, q: store.Encoded_Quad) -> (added: bool, err: Error) {
	txn: ^lmdb.Txn
	check(lmdb.txn_begin(s.env, nil, 0, &txn)) or_return
	committed := false
	defer if !committed {
		lmdb.txn_abort(txn)
	}
	added = insert_txn(s, txn, q) or_return
	check(lmdb.txn_commit(txn)) or_return
	committed = true
	return added, nil
}

// insert_txn is insert inside a caller-owned write transaction (the
// loaders' batching hook). The NOOVERWRITE put on gspo decides set
// membership; the other two indexes are only written for a fresh quad.
@(private)
insert_txn :: proc(s: ^Store, txn: ^lmdb.Txn, q: store.Encoded_Quad) -> (added: bool, err: Error) {
	for id in q {
		assert(id != store.WILDCARD, "insert: WILDCARD in stored quad")
	}

	key_buf: [QUAD_KEY_SIZE]u8
	encode_quad_key(key_buf[:], q, PERM_GSPO)
	key := val_of(key_buf[:])
	empty := lmdb.Val{}
	rc := lmdb.put(txn, s.dbi[.Gspo], &key, &empty, lmdb.NOOVERWRITE)
	if rc == lmdb.KEYEXIST {
		return false, nil
	}
	check(rc) or_return

	encode_quad_key(key_buf[:], q, PERM_GPOS)
	key = val_of(key_buf[:])
	check(lmdb.put(txn, s.dbi[.Gpos], &key, &empty, 0)) or_return
	encode_quad_key(key_buf[:], q, PERM_GOSP)
	key = val_of(key_buf[:])
	check(lmdb.put(txn, s.dbi[.Gosp], &key, &empty, 0)) or_return
	return true, nil
}

// count returns the number of quads in the dataset — O(1) via gspo's
// entry count.
count :: proc(s: ^Store) -> (n: int, err: Error) {
	txn: ^lmdb.Txn
	check(lmdb.txn_begin(s.env, nil, lmdb.RDONLY, &txn)) or_return
	defer lmdb.txn_abort(txn)

	stat: lmdb.Stat
	check(lmdb.stat(txn, s.dbi[.Gspo], &stat)) or_return
	return int(stat.ms_entries), nil
}

// Match_Iterator streams the quads satisfying a pattern; it owns a
// read transaction and a cursor, both released by match_destroy.
Match_Iterator :: struct {
	txn:        ^lmdb.Txn,
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

// match returns an iterator over the quads matching a pattern, served
// by the index with the longest run of bound leading positions —
// wildcard-graph patterns full-scan gspo with filtering, the accepted
// three-index trade-off (STORE-I-0002 decision 6). The iterator reads
// one MVCC snapshot, valid until match_destroy; on error the iterator
// is invalid and needs no destroy.
match :: proc(s: ^Store, pattern: store.Match_Pattern) -> (it: Match_Iterator, err: Error) {
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

	check(lmdb.txn_begin(s.env, nil, lmdb.RDONLY, &it.txn)) or_return
	rc := lmdb.cursor_open(it.txn, s.dbi[dbis[best]], &it.cursor)
	if rc != lmdb.SUCCESS {
		lmdb.txn_abort(it.txn)
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

// match_destroy closes the iterator's cursor and read transaction;
// required by the contract, and actually load-bearing in this backend.
match_destroy :: proc(it: ^Match_Iterator) {
	if it.cursor != nil {
		lmdb.cursor_close(it.cursor)
	}
	if it.txn != nil {
		lmdb.txn_abort(it.txn)
	}
	it^ = {}
}
