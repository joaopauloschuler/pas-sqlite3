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

### 9.2.3 follow-up note (round-trip mutator probe) — RESOLVED 9.2.3.followup

`bin/TestVectorRoundTrip` (Phase 9.2.3) previously inherited the
bucket-A `pas-skip` block wholesale even though bucket-A is an
RO-open bug and round-trip opens RW.  9.2.3.followup teaches the
round-trip parser a cite-aware filter (mirrors
`TestVectorSchemaChange`): pas-skip entries are honoured only when
their cite names a bucket that actually applies to the RT gate.
Buckets A / B (bare VACUUM; no RT mutator uses it) / C / D / E / F /
G / H / K are filtered out; buckets I / J / L / M (RT-relevant) still
skip.  Effect: 3 vectors (`partial-index`, `view-cte`,
`withoutrowid`) that previously pas-skipped now run and pass
byte-identically.  Three new RT-only divergences surfaced and are
bucketed below as bucket-L (auto-vacuum page-count drift on
autovacuum + incrvacuum) and bucket-M (UTF-16 INSERT stores raw
UTF-8 on utf16.db).  Round-trip probe today: gated=8 ok=5
diverged=0 skipped=3 rc=0.

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

## Bucket D — CREATE INDEX on WITHOUT ROWID table — page byte divergence (9.2.4) [FIXED 9.2.divbug.D]

**Fixed**: `sqlite3CreateIndex` (passqlite3codegen.pas) skipped C
build.c:4278..4292's `pPk` arm — the explicit "append the WITHOUT
ROWID table's declared PRIMARY KEY columns as the implicit index-key
suffix" loop.  Only the `pPk==nil` (rowid) tail was wired; in the
WITHOUT ROWID case the PK-suffix `aiColumn[]`, `azColl[]`,
`aSortOrder[]` slots stayed zero-initialised, so every index cell
encoded `(c, a-col-from-table[0], a-col-from-table[0])` instead of
`(c, a, b)`.  Surfaced as a five-byte cell-length drift inside index
page 3 of `withoutrowid.db` at byte 8199.

Faithful port: added the missing `else if pPk <> nil` arm that walks
`pPk^.aiColumn[0..nKeyCol-1]` copying each into `pIndex[i++]`, with
an inline `isDupColumn` (build.c:2274) check that decrements
`nColumn` when a PK column already appears in the user-specified key
prefix.  C reference: `../sqlite3/src/build.c:4278`.

Original symptom (kept for historical context):

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

## Bucket F — PRAGMA auto_vacuum returns 0 on RO-open (9.2.2) [FIXED 9.2.divbug.F]

**Fixed**: `passqlite3codegen.pas` `sqlite3Pragma` stubbed
`auto_vacuum` to a constant `OP_Integer 0` (in the "constant-default
integer pragmas" fallback block) and never consulted the btree layer,
so even though `lockBtree` correctly populated `pBt^.autoVacuum` from
page-1 header bytes 36..39, the pragma codegen ignored that state.
Faithful port: drop `auto_vacuum` from the constant-stub table and
add a proper read arm that runs `sqlite3ReadSchema` then
`sqlite3BtreeGetAutoVacuum(pBt)`, mirroring `pragma.c:801`.  Closes
9.2.divbug.F.  incrvacuum.db now passes `TestVectorReadOnly`;
autovacuum.db still pas-skips on bucket-B (script-trailing VACUUM
EAccessViolation, unrelated).

Affected vectors: `autovacuum.db`, `incrvacuum.db`.

## Bucket G — PRAGMA encoding returns garbled UTF-8 on RO-open (9.2.2) [FIXED 9.2.divbug.G]

**Fixed**: two root causes contributed.  (a)
`passqlite3codegen.pas` `sqlite3Pragma` encoding read arm hard-wired
`sqlite3VdbeLoadString(v, 1, 'UTF-8')` regardless of `db^.enc`.
(b) `passqlite3vdbe.pas` `OP_String8` tagged the literal UTF-8 bytes
with `pOut^.enc := enc` (db's encoding) without ever converting the
bytes, so when `db^.enc = SQLITE_UTF16LE` every string literal carried
mis-tagged bytes and `sqlite3_column_text` returned the raw UTF-8
bytes wearing a UTF-16 label.  Faithful ports: (a) make the encoding
arm read `db^.enc` and emit `UTF-16le` / `UTF-16be` / `UTF-8`; (b)
port the `vdbe.c:1419..1436` conversion arm — when `enc != SQLITE_UTF8`,
`sqlite3VdbeMemSetStr(SQLITE_UTF8) + sqlite3VdbeChangeEncoding(enc)`
then rewrite `pOp^.p4.z` to the converted buffer (`P4_DYNAMIC`).
Closes 9.2.divbug.G.  `PRAGMA encoding` now returns `UTF-16le` on
utf16.db.  The vector still pas-skips because `hex(<utf16-text>)`
returns byte-swapped pairs (now tracked as bucket-K — separate bug
inside `hex()` / `sqlite3_column_text` UTF-16 handling).

Affected vector: `utf16.db`.

## Bucket H — WITHOUT ROWID RO sweep aborts with "disk image malformed" (9.2.2) — CLOSED

Symptom (was): SELECT against `withoutrowid.db` opened read-only emits
the first 5 rows then errors `database disk image is malformed` (rc=11
SQLITE_CORRUPT) while C reads all rows cleanly.  Surfaced once
bucket-A was lifted.

Root cause: the simple-`count(*)` codegen fast path in
`sqlite3Select` (codegen.pas, near OP_Count emission) emitted
`OpenRead iCsr, pTab^.tnum` with no P4 KeyInfo for every table.  For a
WITHOUT ROWID table, `pTab^.tnum` IS the PRIMARY KEY index b-tree
(mxRecord-keyed cells), not an intkey table.  The cursor opened
without P4_KEYINFO walked the page as intkey cells, parsed garbage
offsets, and aborted with SQLITE_CORRUPT.  C `select.c:8793..8814`
forces `pBest := sqlite3PrimaryKeyIndex(pTab)` and attaches
`P4_KEYINFO` for WITHOUT ROWID; the Pas fast path now ports that arm.
Closes 9.2.divbug.H.

Affected vector: `withoutrowid.db` (now byte-identical, 130 bytes).

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

## Bucket J — Round-trip trigger-fire EAccessViolation (9.2.3) — CLOSED

Symptom (historic): round-trip mutator against `triggers.db` crashed
the Pas port with `EAccessViolation` inside `sqlite3VdbeMemRelease`
during sub-vdbe teardown.

Root cause: `sqlite3VdbeClearObject` (passqlite3vdbe.pas) released
`aMem`/`aVar`/`pVList`/`pFree` unconditionally, but trigger sub-vdbes
created by `codeRowTrigger` never transit `VdbeMakeReady` and are
deleted while still in `VDBE_INIT_STATE`.  Those fields therefore held
raw-malloc garbage (`VdbeCreate` only zeroes from `aOp` onwards —
vdbeaux.c:30).  C gates the release on
`eVdbeState != VDBE_INIT_STATE` at vdbeaux.c:3747..3751; the Pas port
now mirrors that gate (9.2.divbug.J).

Affected vector: `triggers.db` — now runs cleanly; remaining db-blob
divergence at byte 8185 is reclassified as bucket-I (cell-layout
drift).

## Bucket L — Auto-vacuum round-trip page-count drift (9.2.3.followup)

Symptom: round-trip mutator against the `autovacuum.db` and
`incrvacuum.db` vectors leaves a byte-different `.db` blob versus the
C oracle, both rc=0.  Neither mutator script contains a bare `VACUUM;`
keyword — the divergence is in the auto-vacuum-at-COMMIT (autovacuum,
FULL) and explicit `PRAGMA incremental_vacuum(1)` (incrvacuum) code
paths.  Surfaced once the bucket-A umbrella was lifted from the
round-trip gate (9.2.3.followup).

Reproducer (after lifting the pas-skip in the round-trip parser):

```
gated=11 ok=8 diverged=3 skipped=0
---- DIVERGENCE ----
  vector  : autovacuum.db
  channel : db-blob (post-mask)
  C  len  : 20480
  Pas len : 24576
  first diff at byte (1-based) : 32
  C  hex window : 05 00 00 00 00 00 00 00 ...
  Pas hex window: 06 00 00 00 06 00 00 00 ...
---- DIVERGENCE ----
  vector  : incrvacuum.db
  channel : stdout (1 byte '\n' missing on Pas side)
  channel : db-blob (post-mask)
  C  len  : 24576
  Pas len : 28672
  first diff at byte (1-based) : 32
  C  hex window : 06 00 00 00 06 00 00 00 01 00 00 00 ...
  Pas hex window: 07 00 00 00 06 00 00 00 02 00 00 00 ...
```

Likely root cause (cross-link to **6.28**): the unported
`incrVacuumStep` / `relocatePage` / `modifyPagePointer` arms — the
same root cause behind bucket-B's bare-VACUUM crash, but here they
silently produce a different (still-internally-consistent) layout
because the auto-vacuum path takes a less aggressive branch.  Page-1
header bytes 32..35 (number of free pages) and 36..39 (freelist trunk
page number) diverge, indicating the freelist coalescing / truncation
arm does not run on the Pas side.  C reference:
`../sqlite3/src/btree.c (autoVacuumCommit, incrVacuumStep, relocatePage)`.

Affected vectors:

* `autovacuum.db`  — bucket-L (also bucket-A umbrella historically, bucket-B for the schema-change probe's trailing VACUUM)
* `incrvacuum.db`  — bucket-L (also bucket-A umbrella historically)

Tagged `pas-skip` with cite `bucket-L` for the round-trip probe in
`MANIFEST.txt`.  Closing 6.28 / `incrVacuumStep` closes this bucket
together with bucket-B.

## Bucket M — UTF-16 round-trip INSERT stores raw UTF-8 bytes (9.2.3.followup)

Symptom: round-trip mutator against `utf16.db` writes `INSERT INTO t
VALUES(5, 'plain');` and similar UTF-8 string literals; the resulting
cell-area bytes on the Pas side carry the raw UTF-8 (`c3 a9` for the
non-ASCII `'café'`) where the C oracle writes the converted UTF-16LE
(`e9 00`).  Both rc=0, blob diverges starting at byte 8126 (inside
the cell-content area of page 2).  Surfaced once the bucket-A umbrella
was lifted from the round-trip gate (9.2.3.followup).

Reproducer:

```
---- DIVERGENCE ----
  vector  : utf16.db
  channel : db-blob (post-mask)
  C  len  : 8192   Pas len : 8192
  first diff at byte (1-based) : 8126
  C  hex window : e9 00 2d 00 78 00 0d 05 03 00 21 70 00 6c 00 61
  Pas hex window: c3 a9 2d 00 78 00 0d 05 03 00 21 70 00 6c 00 61
```

Likely root cause: 9.2.divbug.G ported the `OP_String8` conversion arm
so SELECT and PRAGMA reads emit converted bytes, but the
INSERT / `OP_MakeRecord` write path probably consults a different
arm — `sqlite3VdbeMemSetStr` / `sqlite3VdbeChangeEncoding` invocation
sites need an audit for the UTF-8 → UTF-16 conversion before the
record blob is serialised into the b-tree cell.  C reference:
`../sqlite3/src/vdbemem.c (sqlite3VdbeChangeEncoding)` and
`../sqlite3/src/vdbeaux.c (sqlite3VdbeMakeRecord)`.

Affected vector: `utf16.db` — bucket-M (also bucket-K for the RO
hex(label) byte-swap, unrelated).  Tagged `pas-skip` for the
round-trip probe in `MANIFEST.txt`.

_End of file._
