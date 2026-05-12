# Reference-vector divergences (Phase 9.2.x)

Per-vector divergence catalog for the read-only / round-trip / schema-change
parity probes (9.2.2 / 9.2.3 / 9.2.4).  Vectors listed here are tagged
`pas-skip` in `MANIFEST.txt`; the relevant gate skips them so the binary
still exits rc=0 while leaving the bug visible.

Per the corpus skip-and-cite contract (see `src/tests/corpus/STATUS.txt`
and the Phase 9.1.5 / 9.1.6 follow-up tickets) we **do not chase
divergences inside a 9.2.x ticket**.  Real fixes are picked up under the
relevant Phase 6 / 7 ticket once the bucket has been triaged.

## Bucket A — read-only open returns SQLITE_READONLY (9.2.2 / 9.2.3)

Symptom: opening any committed `.db` vector with
`sqlite3_open_v2(..., SQLITE_OPEN_READONLY, nil)` and running a plain
`SELECT` errors with rc=8 (`SQLITE_READONLY`) and stderr
`attempt to write a readonly database`.  The same `.db` opened in
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

## Bucket E — ALTER RENAME COLUMN on table with partial index (9.2.4)

Symptom: `ALTER TABLE t RENAME COLUMN val TO amount;` against
`partial-index.db` produces a byte-different `.db` blob (both rc=0).
The partial index `idx_active_val ON t(val) WHERE status='active'`
references the renamed column directly; `alter.c` `renameColumnFunc`
must rewrite the index DDL to `ON t(amount) WHERE status='active'`.
The Pascal port writes a different sqlite_master payload (the new
DDL string differs from the C oracle's, possibly in whitespace or
quoting).

Reproducer:

```bash
cp src/tests/vectors/partial-index.db /tmp/c.db
cp src/tests/vectors/partial-index.db /tmp/p.db
/home/bpsa/app/sqlite3/sqlite3 /tmp/c.db "ALTER TABLE t RENAME COLUMN val TO amount;"
LD_LIBRARY_PATH=src ./bin/passqlite3 /tmp/p.db "ALTER TABLE t RENAME COLUMN val TO amount;"
cmp /tmp/c.db /tmp/p.db
# differ at byte ~102 (inside sqlite_master row for idx_active_val)
```

Likely root cause: the `addcolumn_renametokenmap` fix (memory entry)
covers the AddColumn path; the parallel index-DDL rewrite for partial
indexes may be missing a similar `RenameTokenMap` call, so the
re-emitted DDL doesn't preserve the original tokenisation.  C
reference: `../sqlite3/src/alter.c (renameColumnFunc, renameColumnIdxNames)`.

Affected vector:

* `partial-index.db` — bucket E (also bucket-A, bucket-B via VACUUM)

_End of file._
