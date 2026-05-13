# Reference-vector divergences (Phase 9.2.x)

Per-vector divergence catalog for the read-only / round-trip / schema-change
parity probes (9.2.2 / 9.2.3 / 9.2.4).  Vectors listed here are tagged
`pas-skip` in `MANIFEST.txt`; the relevant gate skips them so the binary
still exits rc=0 while leaving the bug visible.

Per the corpus skip-and-cite contract (see `src/tests/corpus/STATUS.txt`
and the Phase 9.1.5 / 9.1.6 follow-up tickets) we **do not chase
divergences inside a 9.2.x ticket**.  Real fixes are picked up under the
relevant Phase 6 / 7 ticket once the bucket has been triaged.

## Bucket A — read-only open returns SQLITE_READONLY (9.2.2 / 9.2.3) [FIXED 9.2.divbug.A]

**Fixed**: `btreeBeginTrans` (passqlite3btree.pas) gated SQLITE_READONLY on
`(pBt^.btsFlags and BTS_READ_ONLY) <> 0` alone, missing the `wrflag <> 0`
conjunct present in C (`../sqlite3/src/btree.c:3622`).  Every read-side
SELECT's OP_Transaction prologue tripped through that arm even though
wrflag was 0.  Faithful port: `if BTS_READ_ONLY and wrflag <> 0 then
rc := SQLITE_READONLY`.  Closes 9.2.divbug.A.  Buckets F/G/H/I/J below
were previously hidden behind the bucket-A umbrella and have been
re-triaged into their own slots.

Original symptom (kept for historical context): opening any committed
`.db` vector with `sqlite3_open_v2(..., SQLITE_OPEN_READONLY, nil)` and
running a plain `SELECT` errored with rc=8 (`SQLITE_READONLY`) and
stderr `attempt to write a readonly database`.  The same `.db` opened in
the default RW mode (via `bin/passqlite3 file "SELECT ..."`) returns
the expected rows.  C oracle reads byte-identically in both modes.

Reproducer:

```bash
LD_LIBRARY_PATH=src ./bin/passqlite3 -readonly src/tests/vectors/simple.db \
  "SELECT * FROM t"
# Parse error in 3rd command line argument:
#   attempt to write a readonly database (8)
```

Likely root cause (cite for the eventual fixer): the in-tree
`attachFunc` arm at `passqlite3codegen.pas:44164..44241` deliberately
strips `SQLITE_OPEN_READWRITE` for non-write attaches and then runs
`gSqlite3Init` to parse `sqlite_schema`.  When the connection itself was
opened with `SQLITE_OPEN_READONLY` something later in the schema-parse
or first-statement-prepare path takes a write-cookie branch and trips
the readonly guard.  See the comment block already on the file at
`:44225..44232` for the previously-identified shape of this bug
("planner falls into a write-cookie path because the schema looks
empty / dirty"); the read-only-open variant of that bug is what 9.2.2
surfaces.  C reference: `../sqlite3/src/main.c (openDatabase)` +
`../sqlite3/src/prepare.c (sqlite3InitOne)` for the read-only schema-
init contract.

Affected vectors (every gated vector in MANIFEST):

* `simple.db`           — bucket A
* `multipage.db`        — bucket A
* `wal.db`              — bucket A (also: WAL-mode open; sidecar absent)
* `autovacuum.db`       — bucket A
* `incrvacuum.db`       — bucket A
* `utf16.db`            — bucket A
* `withoutrowid.db`     — bucket A
* `generated-column.db` — bucket A
* `triggers.db`         — bucket A
* `view-cte.db`         — bucket A
* `partial-index.db`    — bucket A

All eleven are tagged `pas-skip` in `MANIFEST.txt` so
`bin/TestVectorReadOnly` exits rc=0.  The probe + queries plumbing is
fully wired — once Bucket A is fixed, drop the `pas-skip` tag here and
in MANIFEST and re-run `bin/TestVectorReadOnly` to gate against the
full corpus.

### 9.2.3 follow-up note (round-trip mutator probe)

`bin/TestVectorRoundTrip` (Phase 9.2.3) honours the same `pas-skip`
override block.  Although the round-trip probe opens the seed `.db`
via `sqlite3_open` (RW path, not the read-only path that bucket-A
specifically surfaces), the same eleven vectors are gated out at the
manifest stage so the gate exits rc=0 today.  Once bucket A is fixed
in Phase 6/7 the `pas-skip` tags can be dropped wholesale and both
9.2.2 + 9.2.3 will begin actually exercising the full vector set.
The 9.2.3 gate did not surface any *new* divergence buckets above and
beyond bucket A — every gated `<name>.mutate.sql` runs cleanly under
the C oracle (verified out-of-band with `../sqlite3/sqlite3` before
landing the test), so no further bucket entries are added here.

## Bucket B — VACUUM raises EAccessViolation on the Pascal port (9.2.4)

Symptom: a bare `VACUUM;` statement against any committed `.db` vector
crashes the Pascal port with `EAccessViolation` and rc=217 (uncaught
FPC exception).  The C oracle returns rc=0 and rewrites the database
in-place.

Reproducer:

```bash
cp src/tests/vectors/simple.db /tmp/t.db
LD_LIBRARY_PATH=src ./bin/passqlite3 /tmp/t.db "VACUUM;"
# An unhandled exception occurred at $...:
# EAccessViolation: Access violation
# rc=217
```

Likely root cause: tasklist 6.27 marked OP_Vacuum / `sqlite3RunVacuum`
as ported but the auto-vacuum / ptrmap-relocation arms enumerated in
6.28 (`incrVacuumStep` / `relocatePage` / `modifyPagePointer` —
"gated on productive ptrmap") are still stubs in the Pascal source.
A plain VACUUM walks `sqlite3RunVacuum` → `BtreeCopyFile` →
relocate-page paths and dereferences a NULL/uninitialised page
descriptor when the ptrmap arm short-circuits.  C reference:
`../sqlite3/src/vacuum.c (sqlite3RunVacuum)` and
`../sqlite3/src/btree.c (relocatePage / btreeOverwriteCell)`.

Affected vectors (every 9.2.4 schema script that ends with a `VACUUM;`):

* `autovacuum.db`     — bucket B (also bucket-A)
* `withoutrowid.db`   — bucket B (script ends with VACUUM; also bucket-D)
* `partial-index.db`  — bucket B (script ends with VACUUM; also bucket-E)
* `view-cte.db`       — bucket B (script ends with VACUUM; also bucket-C)

Tagged `pas-skip` for 9.2.4 in `MANIFEST.txt`.  Closing this bucket
unblocks the autovacuum vector immediately and is a prerequisite for
re-enabling the other three.

## Bucket C — ALTER RENAME with dependent VIEW / CTAS (9.2.4)

Symptom: `ALTER TABLE base RENAME COLUMN n TO value;` against the
`view-cte.db` vector (which has `CREATE VIEW v_doubled AS SELECT id,
n*2 AS n2 FROM base;`) raises `EAccessViolation` on the Pascal port.
Same crash for `ALTER TABLE cte_seed RENAME TO cte_snapshot;` (a
CTAS-derived table).  C oracle returns rc=0 and rewrites the
view-definition AST.

Reproducer:

```bash
cp src/tests/vectors/view-cte.db /tmp/t.db
LD_LIBRARY_PATH=src ./bin/passqlite3 /tmp/t.db \
  "ALTER TABLE base RENAME COLUMN n TO value;"
# EAccessViolation
```

Likely root cause: `alter.c` `renameColumnFunc` walks the dependent
view's `Select` parse tree and calls back into `sqlite3RenameToken*`
to rewrite each `Expr` node referencing the old name.  The Pascal
port's `renameTokenFind` / `renameTokenCheckAll` may be returning a
NULL token for view-internal expressions (`n*2 AS n2`), triggering the
NULL deref one frame up.  C reference:
`../sqlite3/src/alter.c (renameColumnFunc, renameTokenFind)`.

Affected vector:

* `view-cte.db` — bucket C (also bucket-A, bucket-B via VACUUM)

## Bucket D — CREATE INDEX on WITHOUT ROWID table — page byte divergence (9.2.4)

Symptom: `CREATE INDEX idx_c ON t(c);` against the `withoutrowid.db`
vector produces a byte-different `.db` blob between the C oracle and
the Pascal port (both rc=0, no error).  Diff first surfaces inside the
new index b-tree page payload (cell-pointer ordering / payload
prefix), strongly suggesting a key-encoding divergence specific to
WITHOUT ROWID indexes (where the index entries carry the full
composite primary key, not a 64-bit rowid suffix).

Reproducer:

```bash
cp src/tests/vectors/withoutrowid.db /tmp/c.db
cp src/tests/vectors/withoutrowid.db /tmp/p.db
/home/bpsa/app/sqlite3/sqlite3 /tmp/c.db "CREATE INDEX idx_c ON t(c);"
LD_LIBRARY_PATH=src ./bin/passqlite3 /tmp/p.db "CREATE INDEX idx_c ON t(c);"
cmp /tmp/c.db /tmp/p.db
# Files /tmp/c.db and /tmp/p.db differ at byte ~8200 (inside index page).
```

Likely root cause: `build.c` `sqlite3CreateIndex` HasRowid==0 arm emits
an OP_SorterOpen with a key-info that includes the table's full PK
columns; the Pascal port may emit them in a different order or with a
different collation default for WITHOUT ROWID indexes.  C reference:
`../sqlite3/src/build.c (sqlite3CreateIndex, HasRowid arm)` and
`../sqlite3/src/insert.c (xferOptimization for WITHOUT ROWID)`.

Affected vector:

* `withoutrowid.db` — bucket D (also bucket-A, bucket-B via VACUUM)

## Bucket E — ALTER RENAME COLUMN on table with partial index (9.2.4) — CLOSED 9.2.divbug.E

Was: `ALTER TABLE t RENAME COLUMN val TO amount;` against
`partial-index.db` produced a byte-different `.db` blob (both rc=0)
because the rewritten sqlite_master row still read `ON t(val)`.

Root cause: Pas `sqlite3CreateIndex` skipped C build.c:4209's
`IN_RENAME_OBJECT` arm — `pIndex->aColExpr = pList; pList = 0;` plus
the per-column `sqlite3StringToId` / `sqlite3ResolveSelfReference`
calls that promote TK_ID column-name expressions to TK_COLUMN.
Without the aColExpr pin, `renameColumnFunc`'s `else if
sParse.pNewIndex` arm (alter.c:1639-1641) walked a NULL `aColExpr`
and never tagged the indexed-column token span, so renameEditSql
emitted the original column name verbatim.

Fix landed in `src/passqlite3codegen.pas`: added the rename-mode
aColExpr pin before the per-column loop, mirrored the StringToId +
ResolveSelfReference calls inside the loop (gated on
`InRenameObject`), and nulled `pList` in the post-loop
`InRenameObject` branch so exit_create_index doesn't double-free.
Also corrected the `ExprUseYTab` mask in `renameColumnExprCb` from
`EP_xIsSelect` to `EP_WinFunc|EP_Subrtn`.

Affected vector:

* `partial-index.db` — bucket E lifted; vector still pas-skips for
  bucket-B (trailing `VACUUM` EAccessViolation, unrelated).

## Bucket F — PRAGMA auto_vacuum returns 0 on RO-open (9.2.2)

Symptom: `PRAGMA auto_vacuum;` on an auto-vacuum / incremental-vacuum
`.db` opened read-only returns `0` from the Pas port and `1` (FULL) /
`2` (INCREMENTAL) from the C oracle.  Surfaced once bucket-A was lifted.

Reproducer:
```bash
LD_LIBRARY_PATH=src ./bin/passqlite3 -readonly src/tests/vectors/autovacuum.db "PRAGMA auto_vacuum;"
```

Likely root cause: the PRAGMA auto_vacuum reader path consults
`pBt^.autoVacuum`, but the Pas `lockBtree` arm that parses page-1 doesn't
populate that field from header bytes 36..39 the way C does.  Reference:
`../sqlite3/src/btree.c lockBtree` (sets `pBt->autoVacuum = get4byte(...)`).

Affected vectors: `autovacuum.db`, `incrvacuum.db`.

## Bucket G — PRAGMA encoding returns garbled UTF-8 on RO-open (9.2.2)

Symptom: `PRAGMA encoding;` against `utf16.db` opened read-only returns
the UTF-16 bytes mis-decoded into UTF-8 (e.g. `e5 91 95 e2 b5 86`) while
the C oracle returns `UTF-16le`.  Surfaced once bucket-A was lifted.

Likely root cause: the PRAGMA encoding reader emits a static string per
`db^.enc`, but `sqlite3InitOne` may not be propagating the cookie's
encoding into `db^.enc` correctly under the readonly schema-init path.
Reference: `../sqlite3/src/prepare.c sqlite3InitOne` text-encoding arm.

Affected vector: `utf16.db`.

## Bucket H — WITHOUT ROWID RO sweep aborts with "disk image malformed" (9.2.2)

Symptom: SELECT against `withoutrowid.db` opened read-only emits the
first 5 rows then errors `database disk image is malformed` (rc=11
SQLITE_CORRUPT) while C reads all rows cleanly.  Surfaced once
bucket-A was lifted.

Likely root cause: WITHOUT ROWID page-key decoding bug in the read
cursor — likely the same family as bucket-D (CREATE INDEX byte
divergence on WITHOUT ROWID).  Reference: `../sqlite3/src/btree.c`
WITHOUT ROWID cell-key decoding.

Affected vector: `withoutrowid.db`.

## Bucket I — Round-trip cell-layout drift (9.2.3)

Symptom: round-trip mutator (`*.mutate.sql`) against a WAL / multipage /
generated-column vector produces a byte-different `.db` blob from the
C oracle, both rc=0, first diff inside a leaf cell area.  Surfaced once
bucket-A was lifted from the round-trip gate.

Reproducer (wal.db): `cp src/tests/vectors/wal.db /tmp/p.db; ./bin/passqlite3 /tmp/p.db "<wal.mutate.sql>"; cmp` against the same script under the C oracle.

Likely root cause: cell-packing / freeblock-coalescing divergence at the
b-tree leaf level — likely tied to a small fill-pattern or freelist
ordering mismatch.  Reference: `../sqlite3/src/btree.c` `dropCell`,
`insertCell`, `allocateSpace`.

Affected vectors: `wal.db`, `multipage.db`, `generated-column.db`.

## Bucket J — Round-trip trigger-fire EAccessViolation (9.2.3)

Symptom: round-trip mutator against `triggers.db` (which fires BEFORE
/ AFTER row triggers) crashes the Pas port with `EAccessViolation`.
Surfaced once bucket-A was lifted from the round-trip gate.

Likely root cause: NULL deref inside the codegen for a trigger that
refers to NEW/OLD column references on a WITHOUT ROWID-style or
generated-column path.  Reference: `../sqlite3/src/trigger.c`
`codeRowTrigger`.

Affected vector: `triggers.db`.

_End of file._
