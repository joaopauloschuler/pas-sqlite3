# DIVERGENCES.md — engine divergences surfaced by the 9.4 tcl-feature sweep

Bootstrapped under task **9.4.4.a**.  Each bucket clusters one symptom
across multiple `.test` files; counts reflect tests where the bucket
fires at least once.  Buckets are not root-caused here — that work
belongs to Phase 6 / 7 / 8 follow-ups.  Format:

    ## 9.4.divbug.N — <one-line symptom>
    Affects: <count> tests (<paths>).
    Symptom: ...
    Likely cause: ...

## 9.4.divbug.1 — `select1.test` segfaults inside libpassqlite3tcl.so

Affects: 1 test (`../sqlite3/test/select1.test`).
Symptom: tclsh exits with SIGSEGV after running ~120 sub-tests.  Last
asserted name before crash is `select1-4.4` which exercises
`SELECT f1 FROM test1 ORDER BY min(f1)` (a use of an aggregate at a
non-aggregate context, expected to raise "misuse of aggregate: min()").
Run-time before segfault: ~1–8 s depending on warm-up.
Likely cause: error-message construction path in aggregate-misuse
diagnostic walks freed memory (or formats a NULL `Expr.u.zToken`).
Note that **9.4.divbug.2** — truncated diagnostic text — also fires on
the same code path (`select1-2.20`), suggesting both symptoms are two
faces of the same bug.

## 9.4.divbug.2 — Truncated SQL error messages drop the function name

Affects: 2+ tests (`../sqlite3/test/select1.test`,
`../sqlite3/test/insert.test`, likely more).
Symptom: upstream emits e.g.
`misuse of aggregate function min()` / `table test1 has 3 columns but 2
values were supplied`; our build emits the prefix-only forms
`misuse of aggregate function` / `table has wrong number of values for
INSERT`.  The name / count tail is dropped.
Likely cause: the `sqlite3ErrorMsg` / `errorOut` ports in
passqlite3parse / passqlite3resolve don't pass the `%s` / `%d`
format arguments through `sqlite3VMPrintf`; the format string is being
emitted verbatim instead of formatted.

## 9.4.divbug.3 — Schema introspection result columns reordered / missing

Affects: 1 test (`../sqlite3/test/index.test`, sub-test `index-1.1c` /
`index-1.1d`).
Symptom: upstream `SELECT name, sql, tbl_name, type FROM sqlite_master`
returns `{index1 {CREATE INDEX ...} test1 index}`; our build returns
`{index1 test1}` — i.e. the `sql` and `type` columns come back as
empty strings or the result set is column-shifted.
Likely cause: writes into `sqlite_schema` from `CREATE INDEX` codegen
in passqlite3build are missing the `sql` / `type` field assignments,
or one of the column inserts is targeting the wrong register.

## 9.4.divbug.4 — `OP_VerifyFormat` / aggregate setup yields `out of memory`

Affects: 1 test (`../sqlite3/test/update.test`, sub-test `update-10.1`).
Symptom: `do_test update-10.1` reports `error: out of memory` instead
of running.  No actual allocation pressure (heap idle).
Likely cause: error-code path in update.test setup misroutes
`SQLITE_ERROR` (or similar) to `SQLITE_NOMEM`, surfacing the
generic "out of memory" string via `sqlite3_errmsg`.

## 9.4.divbug.5 — UTF-16 numcast (`numcast-utf16*`) returns empty string

Affects: 1 test (`../sqlite3/test/numcast.test`, sub-tests
`numcast-utf16le.*` and `numcast-utf16be.*`).
Symptom: cast-to-NUMERIC / cast-to-INTEGER on a UTF-16 source column
returns `{}` (empty) where upstream returns the parsed `12345.0` /
`12345` etc.  Note that `numcast-utf8.*` also fail but with a different
fingerprint — they return `{}` because their setup uses `db_save`
(unported) or `db eval` against an attached non-existent encoding;
the UTF-16 bucket is the engine-level divergence.
Likely cause: `sqlite3VdbeMemNumerify` / the `OP_Affinity` arm doesn't
ChangeEncoding the source to UTF-8 before parsing — pas-sqlite3 reads
the raw UTF-16 byte stream as if it were UTF-8 and bails at the first
zero-byte.  Related to feedback note
`feedback_result_text_change_encoding.md` but on the input side.

## 9.4.divbug.7 — `insert.test` wedges past `insert-1.3`

Affects: 1 test (`../sqlite3/test/insert.test`).
Symptom: tclsh consumes the source script through `insert-1.2` (PASS)
and then hangs.  9.4.4.b driver kills the process after the 60s
ceiling; 9.4.4.a recorded a SIGSEGV at the same boundary.  The
transition from crash → hang suggests the segfaulting cleanup path
got partially fixed (probably by 9.4.divbug.6) and now exposes an
infinite loop one frame deeper.
Likely cause: INSERT codegen / VDBE row-step on the multi-VALUES /
"big" INSERT exercised by `insert-1.3` enters a loop in
`sqlite3VdbeExec` (or `sqlite3BtreeInsert`) when row count crosses
the page-split boundary.
Surfaced by: 9.4.4.b re-sweep.

## 9.4.divbug.8 — `index.test` segfaults at `index-3.3`

Affects: 1 test (`../sqlite3/test/index.test`).
Symptom: after passing `index-3.1`, `3.2.1..3` the process SIGSEGVs
during `index-3.3`, which exercises CREATE INDEX with an explicit
DESC column on a table that has a previously-created index of the
same name.  Stderr last line: `index-3.3...` (no Ok / no diff).
Likely cause: index-conflict diagnostic path frees an Index struct
before reading its name; possibly the same root as divbug.3 (schema
write path) but on the *error* arm.
Surfaced by: 9.4.4.b re-sweep (was masked by divbug.3 hard-stop in
9.4.4.a).

## 9.4.divbug.9 — `lastinsert.test` segfaults at `lastinsert-1.1w`

Affects: 1 test (`../sqlite3/test/lastinsert.test`).
Symptom: `lastinsert-1.1` (32-bit rowid) PASSes, then `lastinsert-1.1w`
(the "wide" 64-bit rowid variant) crashes.  No diff is printed —
the SIGSEGV happens inside `db last_insert_rowid` evaluation or the
preceding INSERT.
Likely cause: 64-bit rowid path overflows in
`sqlite3_last_insert_rowid` wiring; or the `db last_insert_rowid`
sub-command shim in PasTclSqlite.pas mis-marshals an `Int64` as
`Integer`.
Surfaced by: 9.4.4.b re-sweep (was masked in 9.4.4.a by
`catchsql` absence — the test couldn't reach this line).

## 9.4.divbug.10 — `boundary1.test` `>=` range scan returns empty

Affects: 1 test (`../sqlite3/test/boundary1.test`).
Symptom: 1481 / 1511 sub-tests fail with the same fingerprint —
`SELECT a FROM t1 WHERE a >= <small-int> ORDER BY a` returns `{}`
where upstream returns the full 64-element sequence.  The `<`,
`<=`, and `=` siblings all PASS; only `>=` and (sometimes) `>` fail.
Likely cause: WhereCode mis-encodes the `>=` operand against an
integer-PK column when the lower bound equals the table minimum —
possibly an off-by-one in `OP_SeekGE` / `OP_IdxGE` setup, or an
inverted `bRev` flag dropping every result.
Surfaced by: 9.4.4.b re-sweep (was guard-skipped in 9.4.4.a by
missing `working_64bit_int`).

## Run summary (9.4.4.a sweep)

10 tests swept via `bin/TclTestDriver` after the
`source */tester.tcl -> tester_min.tcl` monkey-patch landed in
`src/tests/TclTestDriver.pas:BuildScript`:

| Test                          | Driver verdict | nT/nErr (direct) | Notes                       |
|-------------------------------|----------------|-------------------|-----------------------------|
| select1.test                  | FAIL           | crash @ ~120/?    | divbug.1 segfault           |
| insert.test                   | FAIL           | 8/24              | divbug.2 + missing helpers  |
| update.test                   | FAIL           | 15/109            | divbug.2/4 + missing helpers|
| delete.test                   | FAIL           | 1/10              | mostly missing helpers      |
| index.test                    | FAIL           | 5/9               | divbug.3                    |
| boundary1.test                | FAIL           | 0/0  (guard skip) | missing working_64bit_int   |
| cast.test                     | FAIL           | 0/0  (guard skip) | missing helpers             |
| lastinsert.test               | FAIL           | 5/5               | all `catchsql`-bound        |
| numcast.test                  | FAIL           | 50/51             | divbug.5                    |
| reindex.test                  | FAIL           | 0/0  (guard skip) | missing helpers             |

PASS / FAIL / SKIP under TclTestDriver = **0 / 10 / 0**.

The PASS=0 result is expected at this triage step: every test is gated
either on an unported helper (see `SKIP.md`) or on at least one of the
divbug buckets above.  Real PASS lines will arrive once `tester_min.tcl`
grows `ifcapable` + `catchsql` + `integrity_check` + `finish_test` (a
single follow-up landing).  That landing belongs to 9.4.4.b or 9.4.2.g.1
— not in scope here.

## Run summary (9.4.4.b sweep)

Re-ran the same 10 tests after `tester_min.tcl` grew `ifcapable`,
`catchsql`/`do_catchsql_test`, `integrity_check`, `finish_test`,
`forcedelete`/`delete_file`, `working_64bit_int`, `presql`,
`omit_test`, and the do_test match-mode prefixes
(`do_realnum_test`, etc.).  Engine-side, 9.4.divbug.6 (doubled
error in DbEvalArm) also landed.  Sweep ran outside TclTestDriver
(driver has a known polling race that under-reports duration —
filed separately; for 9.4.4.b we used direct `tclsh + tester_min`
invocations with a 60s `timeout`).

| Test                          | 9.4.4.a              | 9.4.4.b              | Δ / divbug                       |
|-------------------------------|----------------------|----------------------|----------------------------------|
| select1.test                  | FAIL (divbug.1)      | CRASH @ select1-4.4  | divbug.1 still fires             |
| insert.test                   | FAIL 8/24            | TIMEOUT (60s, hang)  | new **divbug.7**                 |
| update.test                   | FAIL 15/109          | FAIL 34/128          | helpers landed; divbug.2/4 +     |
|                               |                      |                      | needs `reset_db`                 |
| delete.test                   | FAIL 1/10            | FAIL 1/23            | helpers landed; needs `db one`   |
| index.test                    | FAIL 5/9 (divbug.3)  | CRASH @ index-3.3    | new **divbug.8** on top of .3    |
| boundary1.test                | FAIL guard-skip      | FAIL 1481/1511       | new **divbug.10**                |
| cast.test                     | FAIL guard-skip      | **PASS** (vacuous)   | `ifcapable !cast` runs body      |
| lastinsert.test               | FAIL 5/5             | CRASH @ 1.1w         | new **divbug.9**                 |
| numcast.test                  | FAIL 50/51           | FAIL 50/51           | divbug.5 unchanged               |
| reindex.test                  | FAIL guard-skip      | **PASS** (vacuous)   | `ifcapable !reindex` runs body   |

PASS / FAIL / CRASH/TIMEOUT under 9.4.4.b = **2 / 5 / 3** (cast +
reindex are vacuous PASSes — see SKIP.md note).  Compared to
9.4.4.a's 0/10/0, the helper landings unblock four tests to
actually exercise sub-tests (delete / update / boundary1 /
lastinsert), which in turn exposes four new engine divergences
(divbug.7..10).  The two unchanged FAIL buckets (numcast,
delete-ish remaining) remain on divbug.5 and missing `db one`.

