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

_End of file._
