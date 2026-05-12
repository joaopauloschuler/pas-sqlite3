# MASK.md — Phase 9.1.4 determinism scrub for the corpus db-blob channel

`TestSQLCorpus` byte-compares the on-disk `.db` file produced by the C
reference oracle (`libsqlite3.so`) and the Pascal port after running the
same script through both.  A handful of byte ranges in the 100-byte
SQLite file header are non-deterministic across writers (or across
library versions) by design.  Those ranges are zeroed in both blobs by
`CorpusOracle.ApplyHeaderMask` before the byte-compare.

The canonical 100-byte file header layout lives in
`../sqlite3/src/btreeInt.h:55..82`.  Every entry below cites the C
source location that *justifies* masking the range — masking anything
else silently hides real bugs and is forbidden.

| offset | size | name                  | citation                              | rationale |
|-------:|:----:|-----------------------|---------------------------------------|-----------|
| 24     | 4    | file change counter   | `pager.c:3089-3090` (`pager_write_changecounter`) — `put32bits(((char*)pPg->pData)+24, change_counter)` | Incremented on every write txn; differs whenever the two oracles take different commit paths even though the logical content is identical. |
| 56     | 4    | text encoding         | `build.c:1354` — `sqlite3VdbeAddOp3(v, OP_SetCookie, iDb, BTREE_TEXT_ENCODING, ENC(db))` | Lazily set on first `CREATE TABLE`.  Pre-DDL scripts leave the slot at 0; post-DDL both oracles deterministically write `1` (UTF-8).  Masking is therefore either a no-op (`1` vs `1`) or hides a known transient (`0` vs `0`) — never a real divergence. |
| 92     | 4    | version-valid-for     | `pager.c:3095` — `put32bits(((char*)pPg->pData)+92, change_counter)` | Snapshot of the change counter taken when the SQLite-version field at 96 was last refreshed.  Drifts in lockstep with offset 24 — masked for the same reason. |
| 96     | 4    | `SQLITE_VERSION_NUMBER` | `pager.c:3096` — `put32bits(((char*)pPg->pData)+96, SQLITE_VERSION_NUMBER)` | Stamped from the writing library's `SQLITE_VERSION_NUMBER`.  The Pascal port and `libsqlite3.so` are built from different commits/versions; this field differs by construction. |

## Ranges considered and rejected

The task brief flagged four candidates; two were *rejected* after
checking the C source.  Documenting the rejection here so a later
auditor doesn't quietly extend the mask.

- **Offset 28..31 (in-header page count).** `btree.c:3774-3777` keeps
  this in lockstep with `pBt->nPage` on every transaction commit
  (`incrVacuumStep` / `autoVacuumCommit`).  Both oracles see the same
  page-allocation sequence under identical workloads — deterministic.
  Do not mask.

- **Freelist trunk page order (offsets 32..35 head + on-page chain).**
  Allocations are driven by `allocateBtreePage`
  (`btree.c:6499`/`btree.c:6553`) which walks the trunk list in
  insertion order.  Under identical SQL the two oracles insert into
  freelist in the same order, so the head pointer and the chain order
  are deterministic.  Do not mask.  *If* a future failure-injection
  workload (e.g. partial-rollback differential) actually exposes
  divergence here, add the mask range and cite the failing test.

- **Offsets 18..19 (file-format read/write version).** `btree.c:11504-11510`
  sets these from journal mode — deterministic for both oracles given
  the same PRAGMA journal_mode.  Do not mask.

- **Offsets 40..43 (schema cookie), 44..47 (file format), 48..51
  (default cache size), 52..55 (largest root page), 60..63 (user
  version), 64..67 (incremental vacuum), 68..71 (application id).**
  All set by `OP_SetCookie` paths driven by the SQL itself.  Identical
  scripts → identical values.  Do not mask.

## Update protocol

When extending the mask:

1. Reproduce the divergence on a minimal script first.
2. Locate the C source line that *writes* the byte range with
   non-deterministic content.  Cite file:line + the assignment
   expression in the table above.
3. Add the range to `CorpusOracle.ApplyHeaderMask` with the same
   comment.
4. If the field is sometimes deterministic and sometimes not, prefer
   leaving it unmasked and adding the divergence to `DIVERGENCES.md`
   over masking it — the floor is *false negatives*, not output noise.

_End of file._
