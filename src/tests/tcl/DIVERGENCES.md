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
