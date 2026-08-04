# Vendored LMDB binding

- `liblmdb_darwin_arm64.a` is **LMDB 0.9.35**. On other platforms the
  binding falls back to `system:lmdb` (any released liblmdb is 0.9.x),
  but darwin_arm64 is the only platform odin-rdf-store tests (STORE-I-0002
  decision 1).
- `lmdb.odin` was generated from LMDB's `mdb.master` development branch —
  the perpetually unreleased "1.0" line. The development-branch-only entry
  points (`env_incr_dump*`, `env_incr_load*`, `cursor_is_db`, `txn_prepare`,
  `env_rollback`, `env_set_encrypt`, `env_set_checksum`, modload) have **no
  symbol in the linked 0.9 library and must not be called**. The store
  restricts itself to the 0.9 API surface: env/txn/dbi/get/put/cursor.
