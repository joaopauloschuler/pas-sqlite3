# DIVERGENCES.md — engine divergences surfaced by the 9.4 tcl-feature sweep

Bootstrapped under task **9.4.4.a**.  Each bucket clusters one symptom
across multiple `.test` files; counts reflect tests where the bucket
fires at least once.  Buckets are not root-caused here — that work
belongs to Phase 6 / 7 / 8 follow-ups.  Format:

    ## 9.4.divbug.N — <one-line symptom>
    Affects: <count> tests (<paths>).
    Symptom: ...
    Likely cause: ...

## 9.4.divbug.1 — `select1.test` segfaults inside libpassqlite3tcl.so — FIXED

Affects: 1 test (`../sqlite3/test/select1.test`).
Symptom (was): tclsh exits with SIGSEGV at `select1-4.4`, which
exercises `SELECT f1 FROM test1 ORDER BY min(f1)` (a use of an
aggregate at a non-aggregate context, expected to raise
"misuse of aggregate: min()").
Actual root cause: not a freed-memory diagnostic walk — the crash was
at *run time* inside `minStep` → `sqlite3_aggregate_context`.  In C,
`resolveExprStep` resolves ORDER BY with `NC_AllowAgg` set and rewrites
the aggregate `min` call to a `TK_AGG_FUNCTION` node (resolve.c:1330);
because the query is non-aggregate, no aggregate analysis runs, so the
node's `pAggInfo` stays NULL and codegen's `TK_AGG_FUNCTION` misuse arm
(expr.c:5320) raises `misuse of aggregate: min()`.  The pas minimal
resolver never performed the `TK_FUNCTION`→`TK_AGG_FUNCTION` rewrite
for ORDER BY terms (it only happens for SF_Aggregate queries, gated in
`markAggregateInExprList`), so `min` stayed a plain `TK_FUNCTION` and
codegen emitted a scalar `OP_Function` — calling `minStep` with no
aggregate context → SIGSEGV.
Fix: in `sqlite3ResolveSelectNames`, after `ResolveExprList(pOrderBy)`,
for a non-aggregate SELECT (no GROUP BY, no aggregate in pEList/pHaving)
recurse `pOrderBy` and tag every aggregate-function `TK_FUNCTION` node
as `TK_AGG_FUNCTION` (op2:=0), mirroring resolve.c:1330.  Codegen's
existing misuse arm then fires with the correct message.

## 9.4.divbug.2 — Truncated SQL error messages drop the function name — FIXED

Affects: 2+ tests (`../sqlite3/test/select1.test`,
`../sqlite3/test/insert.test`, likely more).
Symptom: upstream emits e.g.
`misuse of aggregate: min()` / `table test1 has 3 columns but 2
values were supplied`; our build emits the prefix-only forms
`misuse of aggregate function` / `table has wrong number of values for
INSERT`.  The name / count tail is dropped.
Root cause: the codegen TK_AGG_FUNCTION misuse arm
(`passqlite3codegen.pas:6271`) hardcoded the format string with no
`%s` / no args.  The INSERT IDLIST-mismatch arm
(`passqlite3codegen.pas:35750`) used a bespoke literal instead of the
upstream `"%d values for %d columns"` (insert.c:1257), and the
no-IDLIST `nColumn != pTab->nCol-nHidden` count check
(insert.c:1244..1254) wasn't ported at all — the path either fell
through to a later AV (no IDLIST) or hit the bespoke literal (IDLIST).
Fix: route both arms through `sqlite3MPrintf` with the upstream format
strings (`'misuse of aggregate: %s()'` keyed off `pExpr^.u.zToken`,
`'%d values for %d columns'`, and the now-ported
`'table %S has %d columns but %d values were supplied'` using `%S` on
`@SrcListItems(pTabList)[0]`).

## 9.4.divbug.3 — Schema introspection result columns reordered / missing — FIXED

Affects: 1 test (`../sqlite3/test/index.test`, sub-test `index-1.1c` /
`index-1.1d`).
Symptom (was): `index-1.1c` / `index-1.1d` returned `{}` (empty
result) where upstream returns `{index1 {CREATE INDEX ...} test1
index}` / `{index1 test1}`.
Actual root cause: not an engine bug — the CREATE INDEX schema-write
path (`emitSchemaRowInsert`, `passqlite3codegen.pas:39544`) populates
all five `sqlite_master` columns correctly, and a direct on-disk
round-trip (`CREATE INDEX` → `db close` → reopen → `SELECT ... FROM
sqlite_master`) works.  The divergence was in the test harness:
`tester_min.tcl` never opened the `db` handle, and `TclTestDriver`
hardcoded `sqlite3 db :memory:`.  Upstream `tester.tcl:553..556`
opens `db` on an on-disk `./test.db`.  `index-1.1` created the table
+ index in the in-memory db; `index-1.1c` then runs `db close;
sqlite3 db test.db`, reopening a *fresh empty* on-disk file — so the
schema query saw nothing.
Fix: add a `reset_db` proc to `tester_min.tcl` (port of
tester.tcl:550..557 — forcedelete the test.db family, `sqlite3 db
./test.db`), invoke it at shim load time, and remove the driver's
`sqlite3 db :memory:` line.  index-1.1c / 1.1d / 1.2 now PASS.
Remaining index.test failures (index-2.1b/2.2 error-text, index-3.3
crash) are unrelated — see divbug.8.

## 9.4.divbug.4 — auto-index name collision yields `out of memory` — FIXED

Affects (was): 1 test (`../sqlite3/test/update.test`, sub-test
`update-10.1`).
Symptom (was): `do_test update-10.1` reported `error: out of memory`
instead of running.  No actual allocation pressure (heap idle).
Actual root cause: nothing to do with `OP_VerifyFormat` or the
aggregate prologue.  `sqlite3CreateIndex`'s auto-name path
(passqlite3codegen.pas, build.c:4097..4101) hardcoded the implicit
index name as `sqlite_autoindex_<tab>_1` instead of walking
`pTab^.pIndex` and counting.  A `CREATE TABLE` carrying two implicit
UNIQUE indexes (e.g. `b UNIQUE` plus `UNIQUE(c,d)`) therefore minted
two indexes with the identical name `sqlite_autoindex_t1_1`; the
schema-hash collision was reported back as `SQLITE_NOMEM`, surfacing
the generic "out of memory" string via `sqlite3_errmsg`.
Fix (9.4.divbug.4): port the C `for(pLoop=pTab->pIndex,n=1; pLoop;
pLoop=pLoop->pNext,n++){}` count loop so each implicit index gets a
distinct `sqlite_autoindex_<tab>_<n>` name.  `update-10.1` now runs
and returns `1 2 3 4 5 6 2 3 4 4 6 7`.

## 9.4.divbug.5 — UTF-16 numcast (`numcast-utf16*`) returns empty string — FIXED

Affects (was): 1 test (`../sqlite3/test/numcast.test`, sub-tests
`numcast-utf16le.*`, `numcast-utf16be.*`, and `numcast-utf8.*`).
Symptom (was): `CAST($str AS real)` / `CAST($str AS integer)` returned
`{}` for all 50 substituted sub-tests, and `numcast-utf16{le,be}.0`
also reported `utf8` from `PRAGMA encoding` instead of the requested
`utf16le` / `utf16be`.
Actual root cause: two-part bug, both upstream of `sqlite3VdbeMemCast`
(which itself was correct — the slow path in `sqlite3MemRealValueRC`
already decodes UTF-16LE/BE before handing the buffer to
`sqlite3AtoF`):

  1. `DbEvalArm` in `src/tests/tcl/PasTclSqlite.pas` never bound Tcl
     variables to `$NAME` / `:NAME` / `@NAME` placeholders.  Every
     prepared statement parameter therefore stepped as NULL, so
     `CAST(NULL AS real)` produced NULL → Tcl `{}`.
  2. `PRAGMA encoding = '<name>'` in `src/passqlite3codegen.pas` had
     only a *read* arm; the write arm was missing, so the connection
     stayed locked to UTF-8 even after the test ran
     `db eval "PRAGMA encoding='utf16le'"`.
Fix (single commit, 9.4.divbug.5):
  * Port `dbPrepareAndBind`'s minimal `$var` / `:var` / `@var` lookup
    loop (tclsqlite.c:1490..1556) into `DbEvalArm`.  Bind via
    `sqlite3_bind_text(..., SQLITE_TRANSIENT)` — string-only, no
    `pVar->typePtr` type-detection fast paths (SQLite affinity / the
    OP_Cast we are exercising does the run-time coercion).
  * Add the `PragTyp_ENCODING` write arm (pragma.c:2267..2286) to
    `sqlite3Pragma`: gate on `DBFLAG_EncodingFixed`, recognise
    UTF8/UTF-8/UTF-16le/UTF16le/UTF-16be/UTF16be/UTF-16/UTF16, stamp
    `db^.aDb[0].pSchema^.enc`, call `sqlite3SetTextEncoding`.
Result: numcast-{utf8,utf16le,utf16be}.* → 51/51 Ok (was 1/51).

## 9.4.divbug.7 — `insert.test` wedges past `insert-1.3` — FIXED (9.4.divbug.7)

Affects: 1 test (`../sqlite3/test/insert.test`).
Symptom: tclsh consumed the source script through `insert-5.1` (PASS)
and then hung at `insert-5.2` — `INSERT INTO t4 SELECT x+1 FROM t4`.
(9.4.4.b's "past insert-1.3" was just the last PASS the driver
printed before the wedge; the actual hang is at insert-5.2.)
Root cause: `sqlite3Insert`'s generic SELECT-as-source coroutine arm
never ported C's `readsTable` / `useTempTable` logic (insert.c:1158
..1198 / template 4).  For a self-referential `INSERT … SELECT …
FROM <same table>`, the coroutine's read cursor over the table
chased the very rows OP_Insert kept appending → infinite loop.
Fix: ported `readsTable` (scans the VDBE program for an OP_OpenRead
/ OP_VOpen on the destination table or its indices) and the
template-4 path — when `readsTable` (or a row trigger) is true,
drain the coroutine into an ephemeral `srcTab` first, then run the
main insert loop as `OP_Rewind` / `OP_Column srcTab` / `OP_Next` /
`OP_Close`.  insert-5.2 / 5.3 now PASS and the file runs to
completion.  (Pre-existing unrelated FAILs insert-4.3 / 4.6 remain.)
Surfaced by: 9.4.4.b re-sweep.  Fixed by: 9.4.divbug.7.

## 9.4.divbug.8 — `index.test` segfaults at `index-3.3` — FIXED

Affects: 1 test (`../sqlite3/test/index.test`).
Symptom: after passing `index-3.1`, `3.2.1..3` the process SIGSEGVd
during `index-3.3`.  `index-3.3` is actually `DROP TABLE test1`
after 99 indexes were created on `test1` — *not* a name-conflict
path as first hypothesised.  The crash needs enough indexes (~77+)
that `sqlite_master` spans multiple b-tree pages so that the
schema-row DELETE loop triggers a page rebalance.
Root cause: `sqlite3BtreeDelete` (passqlite3btree.pas) ported C's
`bPreserve = (flags & BTREE_SAVEPOSITION)!=0;` as a plain mask:
`bPreserve := flags and BTREE_SAVEPOSITION`.  Since
`BTREE_SAVEPOSITION = $02`, that yields `2`, not the boolean `1`.
On the `saveCursorKey` (will-rebalance) path C keeps `bPreserve == 1`;
the stale `2` made the final `if bPreserve > 1` arm wrongly take the
`CURSOR_SKIPNEXT` branch instead of `moveToRoot` + `CURSOR_REQUIRESEEK`.
After `balance()` merged the leaf away, the cursor was left
`CURSOR_SKIPNEXT` on a now-empty page; the next `OP_Column` fetched
a NULL payload (`payloadSize=0`, `aRow=nil`) and dereferenced it.
Fix: `bPreserve := u8(ord((flags and BTREE_SAVEPOSITION) <> 0));`.
Verified: `DROP TABLE` after 99 indexes now succeeds, all indexes
removed, `PRAGMA integrity_check` = ok; engine regression suite
99/100 (only the pre-existing `TestFuzzDiff` differential fuzzer
still fails, unrelated).
Surfaced by: 9.4.4.b re-sweep (was masked by divbug.3 hard-stop in
9.4.4.a).

## 9.4.divbug.9 — `lastinsert.test` segfaults at `lastinsert-1.1w` — FIXED

Affects: 1 test (`../sqlite3/test/lastinsert.test`).
Symptom (was): `lastinsert-1.1` (32-bit rowid) PASSes, then
`lastinsert-1.1w` crashes.  No diff is printed — SIGSEGV.
Actual root cause: nothing to do with `Int64` marshalling or rowid
overflow — `db last_insert_rowid` already routes through
`Tcl_NewWideIntObj`.  The crash was in the *preceding INSERT*.
`lastinsert-1.1w` runs `CREATE TABLE t1w(k INTEGER PRIMARY KEY)
WITHOUT ROWID`.  Our `sqlite3EndTable` had only a partial WITHOUT
ROWID arm: it folded `TF_WithoutRowid` into `tabFlags` and assumed
`sqlite3PrimaryKeyIndex(pTab)` already returned a real Index object.
That holds for a *non-IPK* PK (the implicit UNIQUE index exists), but
for `k INTEGER PRIMARY KEY` the table is an IPK table — `iPKey >= 0`
and there is **no** index object.  `sqlite3GenerateConstraintChecks`
then hit the WITHOUT-ROWID else-branch and dereferenced the nil
`pPk` at `pPk^.nKeyCol` (codegen.pas:36940).
Fix (9.4.divbug.9): finish the port of `convertToWithoutRowidTable`
(build.c:2354..2507) inside `sqlite3EndTable`:
  * Port the AUTOINCREMENT / `TF_HasPrimaryKey`-missing precondition
    errors (build.c:2722..2730).
  * Step (1): mark every `COLFLAG_PRIMKEY` column NOT NULL, set
    `TF_HasNotNull` (build.c:2363..2374).
  * For `iPKey >= 0`, synthesise the PK index: `sqlite3TokenInit` the
    IPK column name, `sqlite3ExprListAppend` a `TK_ID` expr, clear
    `iPKey`, call `sqlite3CreateIndex(... SQLITE_IDXTYPE_PRIMARYKEY)`
    (build.c:2388..2409).
  * After folding all table columns into the PK index, rebuild
    `colNotIdxed` via the newly-ported `recomputeColumnsNotIndexed`
    (build.c:2295..2328, called at 2506).
Result: lastinsert.test → 6/6 Ok; engine regression 99/100
(only the pre-existing unrelated `TestFuzzDiff`).
Surfaced by: 9.4.4.b re-sweep (was masked in 9.4.4.a by
`catchsql` absence — the test couldn't reach this line).

## 9.4.divbug.10 — `boundary1.test` empty results — FIXED

Affects: 1 test (`../sqlite3/test/boundary1.test`).
Symptom: 1481 / 1511 sub-tests failed returning `{}`.
Root cause: NOT a WhereCode bug.  `boundary1-1.1` populates the
table with 64 `INSERT INTO t1(oid,a,x) VALUES(...)` rows — i.e. it
names the rowid alias `oid` in the IDLIST.  `sqlite3Insert`'s
IDLIST-resolution loop (passqlite3codegen.pas) unconditionally
raised "table has no column with that name" whenever
`sqlite3ColumnIndex` returned `< 0`, never porting C's rowid-alias
branch (insert.c:1097: `if sqlite3IsRowid(name) && !withoutRowid`).
So `boundary1-1.1` failed, the table stayed empty, and every
downstream SELECT — `>=`, `>`, `<`, `<=`, `=` alike — returned `{}`.
Fix: ported the C `ipkColumn` concept.  The IDLIST loop now sets
`ipkColumn` (the IDLIST index) for a declared-IPK column or a
rowid-alias term; rowid-alias terms with no declared IPK are
accepted instead of erroring.  Added the matching rowid-emission
arm (`pTab^.iPKey < 0 and ipkColumn >= 0` → ExprCode the term,
NotNull/NewRowid/MustBeInt) and the coroutine `OP_Copy` arm, and
fed `ipkColumn >= 0` into the `pkChng` / `appendBias` decision
(C insert.c:1570).  WITHOUT ROWID tables still reject rowid aliases.
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

## 9.4.divbug.11 — `multiSelectByMerge: iOrderByCol<=0` assert (compound SELECT ORDER BY) — FIXED

Affects: 1 test (`../sqlite3/test/select1.test`, `select1-6.22`/`6.23`).
Was: select1.test aborted at `select1-6.22` with
`AssertH FAILED: multiSelectByMerge: iOrderByCol<=0`.
Root cause: the Pas resolver had no port of `resolveCompoundOrderBy`
(resolve.c:1589).  The per-select loop in `sqlite3ResolveSelectNames`
ran `sqlite3ResolveOrderGroupBy` against the top-most compound's
ORDER BY using only that select's pEList, so a term resolving by
name against a *different* element of the compound kept
`iOrderByCol=0` and `multiSelectByMerge` asserted.
Fix: add `ResolveCompoundOrderBy` (passqlite3codegen.pas ~9763) — a
port of resolve.c's `resolveCompoundOrderBy` that walks the compound
chain left-most→top-most, matching each ORDER BY term via the
integer / `resolveAsName` / resolve-dup-and-structural-compare arms
and setting `u.x.iOrderByCol`.  The main loop now defers the
top-most compound's ORDER BY (mirrors resolve.c:2040 `isCompound`
guard) and calls `ResolveCompoundOrderBy` from the left-most
iteration (resolve.c:2093).  select1.test now runs past 6.22/6.23
to completion.  Verified via `bin/TclTestDriver` script + full
engine regression (`src/tests/build.sh`, no new failures).

## 9.4.divbug.12 — `update.test` segfaults at `update-17.10` — FIXED

Affects: 1 test (`../sqlite3/test/update.test`).
Symptom: update.test SIGSEGV'd inside `update-17.10`.  The crash was
not in UPDATE at all but in the preceding `CREATE INDEX t1x1 ON t1(1)
WHERE 3` — an index whose key is the constant expression `1`.
Root cause: `sqlite3CreateIndex`'s per-column loop in
`passqlite3codegen.pas` called `sqlite3ColumnIndex(pTab,
pColExpr^.u.zToken)` unconditionally.  For a non-identifier index
expression (here an integer literal, `op=TK_INTEGER`,
`EP_IntValue` set) `u.zToken` is not a valid pointer — it aliases
`u.iValue` — so the lookup dereferenced `0x1` and segfaulted.
build.c:4220..4250 only resolves a column name through
`sqlite3ColumnIndex`; any other expression is an `XN_EXPR` slot.
Fix: gate the zToken lookup on `op in {TK_ID,TK_STRING}` and not
`EP_IntValue`; route everything else to `XN_EXPR`, pin `pList` onto
`pIndex^.aColExpr`, set `bHasExpr`, clear `uniqNotNull`, and null the
local `pList` after the transfer so exit cleanup does not double-free.
Verified: `update-17.10... Ok`; update.test runs to completion.
Remaining update.test failures (3.x/9.x error text = divbug.14/.15,
update-19.10 `idxColIsBeingUpdated rowid` AssertH) are separate,
pre-existing, and unrelated to this segfault.

## 9.4.divbug.13 — Result-set row ORDER for inequality scans is unstable — FIXED

Affects: 1 test (`../sqlite3/test/boundary1.test`, ~888/1511 sub-tests).
Symptom: divbug.10's empty-result symptom is GONE — boundary1's
table now populates and the `>`, `>=`, `<`, `<=` scans return the
*right rows*, but in the *wrong order*.  e.g. `boundary1-2.1.gt.1`
expects `[3 28]`, gets `[28 3]`; `boundary1-2.1.ge.2` expects
`[28 17 3]` (DESC), gets `[17 28 3]`.
Root cause: the Pascal `whereShortCut` (codegen.pas) folds an IPK
*range* scan into the planner shortcut (a stand-in the real C
`whereShortCut` does not have — C only emits WHERE_ONEROW plans).
After picking that plan it ran the same tail as the ONEROW plans,
`pWInfo^.nOBSat := pOrderBy^.nExpr` — claiming the scan satisfied
*any* ORDER BY.  select.c then NOOP'd the SorterOpen and emitted
rows in raw rowid b-tree order.  A range scan visits many rows, so
its traversal order satisfies only `ORDER BY rowid`, never an
arbitrary column.
Fix: restrict the `nOBSat := nExpr` claim in `whereShortCut` to
genuine `WHERE_ONEROW` plans; range plans leave `nOBSat` at its
zeroed default so select.c installs the sorter.  All 1511
boundary1.test sub-tests now pass (0 errors); engine regression
clean; TestExplainParity unchanged (224 pass).
Surfaced by: 9.4.4.b.2 re-sweep.  Fixed by: 9.4.divbug.13.

## 9.4.divbug.14 — SQL error messages still drop the object name — FIXED

Affects: 3+ tests (`../sqlite3/test/insert.test`,
`../sqlite3/test/index.test`, `../sqlite3/test/select1.test`).
Symptom: divbug.2 fixed two specific arms, but a broader family of
error messages still emit the generic prefix-only form.
Fixed (passqlite3codegen.pas) by routing the scattered call sites
through the upstream `%s`/`%S`/`%T` format strings:
  * insert column miss → `table %S has no column named %s`
    (insert.c:1101) — insert-1.4 now passes.
  * unresolved `TK_DOT` in a FROM-less expr (e.g. an INSERT VALUES
    list) → `no such column: zTab.zCol` instead of recursing into
    `pLeft` and reporting just the bare table token — insert-4.3.
  * `table %s may not be indexed`, `there is already a table named
    %s`, `index %s already exists` (build.c:4043/4082/4088) —
    index-5.1 / 6.1 / 6.2 now pass.
  * CREATE TABLE/VIEW collision → `%s %T already exists`
    (build.c:1285).
Remaining: the `misuse of aggregate function min()` /
`misuse of aliased aggregate <name>` spelling (select1-2.20..23)
is a resolve-time nested-aggregate detection gap tracked under
divbug.17 — the codegen site already matches expr.c:5320 exactly;
the fix is to raise at resolve time, not codegen time.

## 9.4.divbug.15 — `no such function` not raised at prepare time — FIXED

Affects: 2 tests (`../sqlite3/test/insert.test` insert-4.6,
`../sqlite3/test/delete.test` delete-4.2).
Symptom: a statement referencing an undefined SQL function
(`SELECT notafunc(...)`) was expected to fail with
`no such function: notafunc`, but the build returned `[0 {}]`
(success, empty result).
Fixed: `flagUnresolvedTKID` (passqlite3codegen.pas) — the walker
that runs over INSERT/VALUES expression trees — now ports the
function-lookup arm of `resolveExprStep` (resolve.c:1129..1276):
a `TK_FUNCTION` whose name `sqlite3FindFunction` cannot resolve
raises `no such function: <name>`, and a name matched only with
`nArg=-2` raises `wrong number of arguments to function <name>()`.
insert-4.6 / delete-4.2 now pass.

## 9.4.divbug.16 — `affinity3.test` segfaults — FIXED

Affects: 1 test (`../sqlite3/test/affinity3.test`).
Symptom: tclsh SIGSEGVd at affinity3-111 (`SELECT ... FROM v1rj`,
a RIGHT JOIN view, with `automatic_index=ON`).  Crash was a nil
cursor deref in `sqlite3VdbeExec` `OP_DeferredSeek` (`pTabCur` =
`v^.apCsr[pOp^.p3]` = nil).

Root cause: `sqlite3WhereBegin`'s cursor-open loop (codegen.pas
~20160) diverged from `where.c:7252..7274`:
1. The `OP_OpenRead` gate only checked `WHERE_IDX_ONLY = 0`; it
   omitted C's `|| (jointype & (JT_LTORJ|JT_RIGHT))` clause, so a
   RIGHT JOIN table scanned index-only never had its *table*
   cursor opened — yet `OP_DeferredSeek` still targeted it.
2. The `addrHalt` selection lacked C's
   `else if( pWInfo->a[ii-1].pRJ )` → use prior level's `addrBrk`.
Both ported faithfully.  affinity3-111..142 now pass; residual
non-crash failures (affinity3-200/210/220/250/260) are separate
unported features (`CREATE TABLE AS SELECT`, JOIN-USING automatic-
index affinity) — not part of this divbug.  Fixed: 9.4.divbug.16.

## 9.4.divbug.17 — nested aggregate produces row-wise instead of folded result, then segfaults — OPEN

Affects: 1 test (`../sqlite3/test/aggnested.test`).
Symptom: `aggnested-1.1` expects `[1x2x3]` (the inner aggregate
folded across rows) but our build returns `[1x1 2x2 3x3]` — the
nested aggregate is evaluated per-row instead of being collapsed by
the outer aggregate context.  The run then SIGSEGVs further in.
Likely cause: the resolver's nested-aggregate handling
(`NC_HasAgg` / `pAggInfo` nesting in resolve.c) is not ported — the
inner `group_concat`/`sum` is bound to the wrong `AggInfo`, and a
later nested-agg row eventually walks a nil context (the segfault).
Sibling area to divbug.1/.11 (aggregate resolution).  Surfaced by:
9.4.4.c sweep.

## Run summary (9.4.4.b.2 sweep)

First fixed a driver regression: the 9.4.7.f per-test tmpdir
isolation cd's tclsh into a throwaway dir, but `ProcessEntry` still
handed `BuildScript` the *relative* manifest path — so every test
SOURCE-ERROR'd in ~11 ms (a spurious 0/10/0).  Fix: `ExpandFileName`
the path to absolute before `BuildScript`.  After that the sweep
runs for real and is reproducible under `bin/TclTestDriver`.

| Test            | 9.4.4.b            | 9.4.4.b.2          | Δ / divbug                         |
|-----------------|--------------------|--------------------|------------------------------------|
| select1.test    | CRASH @ 4.4        | FAIL (assert @6.22)| divbug.1 FIXED; new divbug.11 + .14 |
| insert.test     | TIMEOUT (hang)     | FAIL 3/36          | divbug.7 FIXED; divbug.14/.15 left  |
| update.test     | FAIL 34/128        | CRASH @ 17.10      | helpers/divbug.2/4 OK; new divbug.12|
| delete.test     | FAIL 1/23          | FAIL 2/49          | runs further; divbug.15 + CTAS gap  |
| index.test      | CRASH @ 3.3        | FAIL 11/101        | divbug.3/.8 FIXED; divbug.14 left   |
| boundary1.test  | FAIL 1481/1511     | FAIL 888/1511      | divbug.10 FIXED (empty); new .13    |
| cast.test       | PASS (vacuous)     | **PASS** (vacuous) | unchanged                          |
| lastinsert.test | CRASH @ 1.1w       | **PASS** 6/6       | divbug.9 FIXED                      |
| numcast.test    | FAIL 50/51         | **PASS** 51/51     | divbug.5 FIXED                      |
| reindex.test    | PASS (vacuous)     | **PASS** (vacuous) | unchanged                          |

PASS / FAIL / CRASH under 9.4.4.b.2 = **4 / 5 / 1** (under
`bin/TclTestDriver`; the driver reports `update.test` as FAIL since
the segfault is a nonzero exit — counted as CRASH here).  cast +
reindex remain vacuous PASSes.

Buckets CLOSED by the landed harness+engine fixes: divbug.1, .3,
.5, .7, .8, .9 (and .10's empty-result symptom).  Buckets still
OPEN / newly opened: divbug.2 (sibling .14), .4 (no longer fatal
but error-text still off), .11, .12, .13, .14, .15.


## Run summary (9.4.4.c sweep)

Broadened the sweep to the **first 50 tcl-feature tests** in
MANIFEST.txt order, run under `bin/TclTestDriver` (the relative-path
fix from 9.4.4.b.2 in place).

PASS / FAIL / SKIP = **41 / 9 / 0** (50 total, 6.6 s).

The 9 FAILs break down as:

| Test            | Verdict           | Bucket / cause                          |
|-----------------|-------------------|-----------------------------------------|
| affinity3.test  | CRASH (SIGSEGV)   | new **9.4.divbug.16**                   |
| aggerror.test   | FAIL 6/6          | `sqlite3_connection_pointer` unported + |
|                 |                   | divbug.14 (error text)                  |
| aggfault.test   | FAIL (SOURCE-ERR) | `faultsim_save_and_close` unported      |
| aggnested.test  | CRASH + wrong res | new **9.4.divbug.17**                   |
| aggorderby.test | FAIL 3/29         | divbug.14 + `ORDER BY may not be used   |
|                 |                   | with non-aggregate` not raised (.15 fam)|
| all.test        | FAIL (SOURCE-ERR) | sources `permutations.test` (absent)    |
| atof1.test      | FAIL 39998/40005  | `real2hex`/`hex2real` test SQL funcs    |
|                 |                   | unported                                |
| atof2.test      | FAIL (SOURCE-ERR) | `load_static_extension` unported        |
| atomic.test     | FAIL (SOURCE-ERR) | `atomic_batch_write` unported           |

Only **two** are genuine new engine divergences (divbug.16, .17);
the other seven are unported test-only Tcl commands / SQL functions
or a missing harness file — port-side follow-ups, not engine bugs.
See STATUS.txt for the per-test pas-strict/soft/skip tags seeded
from this run under 9.4.8.b.
