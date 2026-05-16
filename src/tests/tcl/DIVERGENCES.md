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
## 9.4.divbug.2 — Truncated SQL error messages drop the function name — FIXED
## 9.4.divbug.3 — Schema introspection result columns reordered / missing — FIXED
## 9.4.divbug.4 — auto-index name collision yields `out of memory` — FIXED
## 9.4.divbug.5 — UTF-16 numcast (`numcast-utf16*`) returns empty string — FIXED
## 9.4.divbug.7 — `insert.test` wedges past `insert-1.3` — FIXED (9.4.divbug.7)
## 9.4.divbug.8 — `index.test` segfaults at `index-3.3` — FIXED
## 9.4.divbug.9 — `lastinsert.test` segfaults at `lastinsert-1.1w` — FIXED
## 9.4.divbug.10 — `boundary1.test` empty results — FIXED
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
## 9.4.divbug.12 — `update.test` segfaults at `update-17.10` — FIXED
## 9.4.divbug.13 — Result-set row ORDER for inequality scans is unstable — FIXED
## 9.4.divbug.14 — SQL error messages still drop the object name — FIXED
## 9.4.divbug.15 — `no such function` not raised at prepare time — FIXED
## 9.4.divbug.16 — `affinity3.test` segfaults — FIXED
## 9.4.divbug.17 — nested aggregate produces row-wise instead of folded result, then segfaults — FIXED
## 9.4.divbug.18 — WITHOUT ROWID virtual-table xUpdate codegen mis-handles DELETE (no-op) and UPDATE (segfault) — FIXED
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

### 9.4.6.q follow-up — test1.c command subset ported

Ported `sqlite3_connection_pointer`, `sqlite3_db_config`,
`atomic_batch_write`, `load_static_extension` (test1.c) into
`testmodules/TestModuleTest1.pas`, plus the `real2hex` SQL scalar
(test_func.c) and `faultsim_save_and_close` / `faultsim_restore` /
`faultsim_restore_and_reopen` aliases in `tester_min.tcl`.  Of the 7
non-engine FAILs above:

- **atof2.test** — now **PASS** (0/4 errors); `load_static_extension
  ieee754` wires the already-ported `passqlite3ieee754` unit.
- **atomic.test** — now **PASS** (0/0; skips gracefully — VFS reports
  no batch-atomic support); `atomic_batch_write` ported.
- **aggfault.test** — `faultsim_save_and_close` unblocked; now fails
  only on `do_faultsim_test` (full malloc-fault machinery, 9.4.2.g.13).
- **aggerror.test** — `sqlite3_connection_pointer` unblocked; still
  blocked on unported `sqlite3_create_aggregate` (separate test1.c
  command, out of 9.4.6.q scope) + divbug.14.
- **atof1.test** — `real2hex` exists and is reachable via
  `load_static_extension real2hex`, but atof1.test invokes it directly
  expecting `autoinstall_test_functions` (task 9.4.6.l.4); still
  blocked on that.

`hex2real` does not exist in upstream C — only `real2hex` is real;
the tasklist mention of `hex2real` was spurious.

### 9.4.6.l.5 follow-up — `register_async_vtab` investigated → drop the bullet

Investigated whether `register_async_vtab` (from `test_async.c`) can be
ported. Findings:

- `test_async.c` / any `test_async*` file does **not** exist anywhere
  under `../sqlite3/` — checked `src/`, `test/`, `ext/`. The only
  `*async*` file is `ext/wasm/api/sqlite3-opfs-async-proxy.c-pp.js`
  (unrelated OPFS WASM proxy).
- Grepping the entire `../sqlite3/` tree for `register_async_vtab`,
  `register_async`, `test_async`, `asyncvfs` → **zero hits**.
- No `.test` file calls `register_async_vtab`. The three test files
  containing the substring `async` (`lock2.test`, `trans.test`,
  `walblock.test`) only use the Tcl-core `flush_async_queue` event-loop
  command / a prose comment — nothing to do with the async VFS vtab.
- `src/tests/tcl/MANIFEST.txt` has no `async` reference; no tcl-feature
  test we run is gated on `register_async_vtab`.

Conclusion: the upstream async VFS (`test_async.c`) was removed from
SQLite long ago (asynchronous I/O was deprecated). There is no source
to port and nothing references the symbol. **Recommendation: drop the
9.4.6.l.5 bullet from tasklist.md** — it is dead weight, not a porting
gap. If a future SQLite version ever reintroduces it, the bullet can be
re-added once `test_async.c` is present in `../sqlite3/src/`.

## 9.4.divbug.19 — table-qualified `rowid` alias not resolved

Affects: 2 tests (`../sqlite3/test/boundary3.test`,
`../sqlite3/test/autoindex5.test`).
Symptom: a qualified rowid reference such as `t1.rowid` / `sp.rowid`
in a multi-table query raises `no such column: t1.rowid`.  An
unqualified `rowid` in the same position resolves fine, and
`boundary1`/`boundary2` (single-table, unqualified rowid) pass.
boundary3 fails ~1896/1819 sub-tests this way; autoindex5 errors at
`autoindex5-1.1` (`no such column: sp.rowid`) and then SIGSEGVs
further in (a downstream nil-deref once the schema is half-built).
Likely cause: the resolver's `TK_DOT` (`zTab.zCol`) arm in
`lookupName` does not port the `sqlite3IsRowid(zCol)` rowid-alias
branch (resolve.c ~243) for the *qualified* case — it only special-
cases the bare-identifier path.  A `Tab.rowid` term therefore falls
through to the ordinary column lookup, which fails.
Surfaced by: 9.4.4.d sweep.

## 9.4.divbug.20 — BETWEEN-on-indexed-column planner picks `nosort` / drops rows

Affects: 1 test (`../sqlite3/test/between.test`, 13/22 sub-tests).
Symptom: `between-1.x` EXPLAIN-style assertions expect `sort t1 i1w`
(index scan that still needs a sort) but our build returns
`nosort t1 *` — it claims the scan satisfied the ORDER BY when it did
not.  Worse, `between-3.2` returns `[]` where upstream returns
`[4 4 {} {}]` — i.e. the BETWEEN range scan also drops matching rows.
Likely cause: the WHERE planner mis-handles a `BETWEEN` constraint
lowered onto an indexed column — it both over-claims `nOBSat` (the
divbug.13 family, but for the BETWEEN→two-term rewrite path) and the
range-pair bounds appear to exclude valid rows.  Two related symptoms
under one BETWEEN-codegen root.
Surfaced by: 9.4.4.d sweep.

## 9.4.divbug.21 — cross-connection EXCLUSIVE lock not detected

Affects: 1 test (`../sqlite3/test/busy.test`).
Symptom: with `db2` holding `BEGIN EXCLUSIVE` on `test.db`, a
`BEGIN IMMEDIATE` on a second connection `db` is expected to fail
`1 {database is locked}` (after the busy-handler is invoked with
`{0 1 2 3}`); our build returns `0 {}` — the second connection
acquires the write lock anyway and the busy-handler never fires.
Likely cause: the file-locking layer (pager / unix-VFS lock byte
range, or `btreeBeginTrans` write-lock acquisition) does not honour
another process's EXCLUSIVE lock, so `SQLITE_BUSY` is never returned
and `sqlite3_busy_handler` is never reached.  Note `db busy` itself
is correctly wired (`DbBusyArm` / `sqlite3_busy_handler`) — the gap
is in lock detection, not the Tcl shim.
Surfaced by: 9.4.4.d sweep.

## 9.4.divbug.22 — large row payload / 64KB page_size overflow handling segfaults

Affects: 2 tests (`../sqlite3/test/bigrow.test`,
`../sqlite3/test/btree01.test`).
Symptom: `bigrow-1.2` (`INSERT` of a single ~65519-byte string
column) SIGSEGVs; `btree01-1.1` (`PRAGMA page_size=65536` then
`INSERT … zeroblob(6500)` ×30 + `UPDATE … zeroblob(64000)`) also
SIGSEGVs.  Both exercise payloads that span overflow pages and/or a
maximal 64 KiB page size.
Likely cause: an overflow-page chain bug in the b-tree layer —
either `accessPayload` / `fillInCell` mis-sizes the overflow chain at
the 64 KiB page-size boundary, or a `u16` cell-size field overflows
when `page_size == 65536` (the only power-of-two page size that does
not fit a `u16`).  Needs Phase 7/8 b-tree follow-up.
Surfaced by: 9.4.4.d sweep.

## 9.4.divbug.23 — co-routine materialisation of correlated subquery not chosen (EXPLAIN QUERY PLAN drift)

Affects: 1 test (`../sqlite3/test/autoindex3.test`, `autoindex3-310`).
Symptom: upstream's EQP for the query is a `CO-ROUTINE children`
with a `SETUP`/`SEARCH t2 USING INDEX x1` body; our build emits a
flat `SEARCH t2 … |--SCAN children `--SEARCH t2 …` plan — the
correlated subquery is re-scanned inline instead of being
materialised once into a co-routine.
Likely cause: the planner's co-routine / materialise decision for a
correlated FROM-subquery (`sqlite3Select` `SRT_Coroutine` selection,
select.c ~6500) is not ported / not triggered for this shape.  This
is a plan-shape divergence; the query still returns correct rows, so
the impact is limited to EQP-asserting tests.
Surfaced by: 9.4.4.d sweep.

## 9.4.divbug.24 — AUTOINCREMENT / `sqlite_sequence` double-create — FIXED

Affects: 1 test (`../sqlite3/test/aggnested.test`, `aggnested-3.x`).
Symptom (original): `aggnested-3.0`/`3.1` error `table sqlite_sequence
already exists`; `aggnested-3.2`/`3.3` return row-wise instead of
folded results (`[0 1 0 1 0 1]` vs `[1 0]`); `aggnested-3.11` SIGSEGVs.
Root cause of the double-CREATE: Pascal `sqlite3CreateTable` did NOT
port the C `strcmp(p->zName,"sqlite_sequence")==0 → pSchema->pSeqTab=p`
arm (build.c:2967..2972).  The init.busy reparse of `sqlite_sequence`
itself never pinned `pSchema^.pSeqTab`, so when the user's NEXT
AUTOINCREMENT CREATE TABLE checked the early guard
`pSchema^.pSeqTab = nil` (build.c:2925 equivalent) it tried to
re-CREATE the shadow.  Fix: port build.c:2968..2970 verbatim into
codegen.pas:40916+ — pin pSeqTab whenever the table being added under
init.busy IS named `sqlite_sequence`.
Status after fix: aggnested-3.0 / 3.1 now return correct rows
(`{2 1}` / `{1 1}`).  Residual aggregate-mis-fold + segfault tracked
as **9.4.divbug.24.b** — independent of sqlite_sequence (3.2 has no
AUTOINCREMENT at all; reproduces folded-row count = group count
instead of folded result; 3.11 still SIGSEGVs).
Surfaced by: 9.4.4.d sweep (deferred from divbug.17).

## 9.4.divbug.24.b — aggregate sub-query in correlated GROUP BY mis-folds + segfault

Affects: `../sqlite3/test/aggnested.test` `aggnested-3.1` (after .24
fix, returns 4 rows `{1 1 1 1}` instead of `{1 1}`), `aggnested-3.2`
(returns `{0 1 0 1 0 1}` instead of folded `{1 0}`), `aggnested-3.3`,
`aggnested-3.11` (still SIGSEGV).  No AUTOINCREMENT in 3.2/3.3 — pure
aggregate-sub-query-in-correlated-GROUP-BY mis-fold.  Likely root:
the scalar sub-select `(SELECT … FROM t2)` in the outer SELECT list is
emitted per inner row instead of per GROUP — the GROUP BY fold of the
inner query is being bypassed for outer rows that carry a sub-query
expression.  Independent of divbug.24; tracked separately.

## Run summary (9.4.4.d sweep)

Broadened the sweep to the **first 100 tcl-feature tests** in
MANIFEST.txt order, run under `bin/TclTestDriver --limit 100` (engine
+ tcl lib rebuilt fresh; both clean — engine regression 99/1, the 1
being the pre-existing arg-less `TestFuzzDiff`).

PASS / FAIL / SKIP / CRASH = **72 / 28 / 0 / 0** (100 total, 21.6 s).
The driver counts a crashed/non-zero-exit run as FAIL; 3 of the 28
FAILs are in-process SIGSEGVs (bigrow, btree01, autoindex5) — broken
out as CRASH below.

Delta on the first-50 subset vs 9.4.4.c's **41 / 9 / 0**:
now **43 / 7 / 0** — `atof2` and `atomic` flipped FAIL→PASS (the
9.4.6.q `load_static_extension` / `atomic_batch_write` landings); the
other 7 first-50 FAILs are unchanged buckets.

The 28 FAILs (7 in first-50, 21 in 51-100):

| Test               | Verdict | Bucket / cause                                  |
|--------------------|---------|-------------------------------------------------|
| affinity3.test     | FAIL    | divbug.16 fixed; residual CTAS unsupported      |
| aggerror.test      | FAIL    | `sqlite3_create_aggregate` unported + divbug.14 |
| aggfault.test      | FAIL    | `do_faultsim_test` (full malloc-fault) unported |
| aggnested.test     | CRASH   | new **divbug.24** (sqlite_sequence + segfault)  |
| aggorderby.test    | FAIL    | divbug.14 + non-aggregate ORDER BY not raised   |
| all.test           | FAIL    | sources `permutations.test` (absent)            |
| atof1.test         | FAIL    | `autoinstall_test_functions` harness gap        |
| autoindex3.test    | FAIL    | new **divbug.23** (EQP co-routine drift)        |
| autoindex5.test    | CRASH   | new **divbug.19** (`sp.rowid`) + segfault       |
| avtrans.test       | FAIL    | `wal_set/check_journal_mode` unported           |
| backup.test        | FAIL    | `do_not_use_codec` unported                     |
| backup2.test       | FAIL    | `do_not_use_codec` unported                     |
| backup4.test       | FAIL    | `do_not_use_codec` unported                     |
| backup5.test       | FAIL    | `sqlite3_prepare_v2`/`sqlite3_backup` unported  |
| backup_ioerr.test  | FAIL    | `randstr` SQL func + `sqlite_pending_byte`      |
| badutf.test        | FAIL    | `sqlite3_exec` (test1.c) unported               |
| badutf2.test       | FAIL    | `sqlite3_exec`/`sqlite3_prepare_v2` unported    |
| between.test       | FAIL    | new **divbug.20** (BETWEEN planner / dropped)   |
| bigrow.test        | CRASH   | new **divbug.22** (large payload segfault)      |
| bind.test          | FAIL    | `sqlite3_prepare` (test1.c) unported            |
| bind2.test         | FAIL    | `sqlite3_prepare` (test1.c) unported            |
| bindxfer.test      | FAIL    | `sqlite3_prepare`/`sqlite3_transfer_bindings`   |
| boundary3.test     | FAIL    | new **divbug.19** (`t1.rowid` not resolved)     |
| btree01.test       | CRASH   | new **divbug.22** (64KB page_size segfault)     |
| btree02.test       | FAIL    | `eval` SQL extension (`db enable_load_extension`)|
| busy.test          | FAIL    | new **divbug.21** (cross-conn EXCLUSIVE lock)   |
| cacheflush.test    | FAIL    | `test_set_config_pagecache` unported            |
| capi2.test         | FAIL    | `sqlite3_prepare` (test1.c stmt API) unported   |

New engine divergences assigned: **divbug.19** (qualified rowid
alias), **.20** (BETWEEN planner), **.21** (cross-connection lock),
**.22** (large payload / 64KB page segfault), **.23** (EQP co-routine
drift), **.24** (sqlite_sequence double-create + segfault).

The remaining 15 FAILs are unported test-only Tcl commands / SQL
functions or a missing harness file (`permutations.test`) — port-side
follow-ups, not engine bugs.  The dominant cluster is the **test1.c
prepared-statement C-API subset** (`sqlite3_prepare`,
`sqlite3_prepare_v2`, `sqlite3_exec`, `sqlite3_backup`,
`sqlite3_errmsg`, `sqlite3_transfer_bindings`) — porting that one
group would unblock bind/bind2/bindxfer/capi2/badutf/badutf2/backup5
(7 tests).  Other harness gaps: `do_not_use_codec`,
`wal_set/check_journal_mode`, `randstr` SQL func, `eval` SQL
extension, `test_set_config_pagecache`, `sqlite3_create_aggregate`,
`autoinstall_test_functions`, `do_faultsim_test`.

## Run summary (9.4.4.e sweep)

Broadened the sweep to the **first 250 tcl-feature tests** in MANIFEST.txt
order, run under `bin/TclTestDriver --limit 250` (engine + tcl lib rebuilt
fresh).

PASS / FAIL / SKIP = **147 / 103 / 0** (250 total, 137.9 s).  Two of the
103 FAILs are 30s-timeouts (`btree01.test`, `changes.test`) — driver
counts them as FAIL.

Delta vs 9.4.4.d (first-100 subset): 72→75 PASS — a 3-test improvement
on tests previously in the window, attributable to the divbug.19/20/21/22/23/24/24.b/25/26/27 fix landings between 9.4.4.d and 9.4.4.e.
The 28 FAILs from the first-100 slice have **all** moved to a status of
either FIXED (improved PASS count) or unchanged divbug pas-soft.

Of the **79 new FAILs in the [101..250] slice** (= 103 minus the 25
first-100 FAILs that still fail minus 1 already-tracked timeout), the
breakdown by root cause is:

| Cluster                                          | Count |
|--------------------------------------------------|-------|
| **Harness gap — test1.c C-API command unported** | ~28   |
|  (sqlite3_step, sqlite3_prepare16, sqlite3_open, |       |
|   sqlite3_finalize, sqlite3_next_stmt,           |       |
|   sqlite3_data_count, sqlite3_column_*, …)       |       |
| **Harness gap — test-util / test_func / testvfs**| ~22   |
|  (database_may_be_corrupt, do_select_tests,      |       |
|   execsql2, hexio_read/write, file_control_*,    |       |
|   testvfs, sqlite3_register_cksumvfs, randstr,   |       |
|   do_adp_test, drop_all_tables, sqlite_pending_  |       |
|   byte, sqlite3_table_column_metadata,           |       |
|   sqlite3_soft_heap_limit, faultsim_test_result, |       |
|   load_static_extension fileio/decimal, …)       |       |
| **9.4.divbug.28..40** (new engine clusters)      | ~13   |
| **Already-tracked .19..27 residue**              | ~6    |
| **CTAS unsupported (engine, divbug.39)**         | ~3    |

The 16 `corrupt*.test` files all bounce off a single harness gap
(`database_may_be_corrupt` — a setter that toggles
`SQLITE_TESTCTRL_NEVER_CORRUPT`).  Porting that one shim would
unblock the whole `corrupt*` family for triage.

Newly assigned engine divbug clusters:

## 9.4.divbug.28 — EXPLAIN QUERY PLAN multi-table segfault — FIXED

Fixed by gating the NRE per-row continuation path in DbEvalNextCmd
(PasTclSqlite.pas:1111..1120) — the Tcl_NRAddCallback +
Tcl_NREvalObj loop was the root cause, not the engine.  Once the
script body for the first row returned, Tcl's NRE trampoline
jumped to a stale function-pointer (rip landed in the stack page
0x7fffffffXXXX), crashing every multi-row `db eval $sql { ... }`
that the upstream `query_plan_graph` helper depends on.  Per the
follow-up note at PasTclSqlite.pas:4269..4274, the per-row body
was always meant to evaluate on the !DbUseNre() recursive
Tcl_EvalObjEx path until the NRE continuation machinery is fully
audited; the broken NRE branch was hot only because 9.4.2.x.1.d
also wrote the inline NRE arm.  Forcing the recursive arm restores
upstream's pre-NRE behaviour (tclsqlite.c:1992).  Archive.
Surviving divergence in the same 4 tests is the ORDER BY EQP
detail text — Pas always emits "USE TEMP B-TREE FOR ORDER BY"
where C emits "FOR LAST [N] TERMS OF ORDER BY" when nOBSat>0
(select.c:1705..1709 vs codegen.pas:31665); tracked separately
as 9.4.divbug.41 below.

## 9.4.divbug.41 — EQP "TEMP B-TREE FOR ORDER BY" omits LAST-N-TERMS

Affects: residual sub-tests of eqp2.test, cost.test, fordelete.test,
delete2.test (post-9.4.divbug.28).
Symptom: Pas emits `USE TEMP B-TREE FOR ORDER BY` where C emits
`USE TEMP B-TREE FOR LAST TERM OF ORDER BY` (or
`FOR LAST <n> TERMS OF ORDER BY` when nOBSat>0).
Cause: codegen.pas:31663..31667 hard-codes the literal `'ORDER BY'`
without consulting pSort->nOBSat / nKey.  Port the C arm from
select.c:1704..1710.  Surfaced 9.4.divbug.28 archive.

## 9.4.divbug.29 — TEXT-affinity column stores hex literal `0x...` as INTEGER

Affects: 1 test (`collate1.test`, all sub-tests of section 1).
Symptom: `INSERT INTO t(c TEXT) VALUES('0x119')` is stored as INTEGER
281 instead of TEXT `'0x119'`.  SELECT then returns `45 281` (decimal
ints) where upstream returns the TEXT strings `0x2D 0x119`.
Likely cause: Pascal `applyAffinity` / `sqlite3VdbeMemNumerify` invokes
the hex-string parser on a TEXT-affinity column where C's
`applyAffinity` for `SQLITE_AFF_TEXT` should never numerify.  Check
`applyAffinity` text arm — it may be falling through to the BLOB->TEXT
case instead of returning.  C reference: vdbeaux.c `applyAffinity`
~vdbe.c:209.
Surfaced by: 9.4.4.e sweep.

## 9.4.divbug.30 — ORDER BY with non-default collation mis-orders

Affects: 3 tests (`collate2.test`, `collate9.test`, `collate8.test`).
Symptom: `SELECT … ORDER BY x COLLATE NOCASE` returns rows in a
case-segregated order (`AB Ab aB ab BA …`) instead of upstream's
case-folded order (`ab aB Ab AB ba …`).  collate9-1.6/4.5 also report
`sort` where EQP should say `nosort` (index-uses-collation gate fails),
and collate8-1.15 fails resolution of an alias column under a custom
collation.  Probably the `xCmp` callback registered for NOCASE in the
TCL bridge differs from upstream's, OR sqlite3 picks the wrong index
when an ORDER BY collation is different from the index's intrinsic.
Likely cause: `sqlite3FindCollSeq` / collating-sequence pinning at
ORDER-BY-resolve.  C reference: callback.c `sqlite3FindCollSeq`,
where.c `wherePathSatisfiesOrderBy`.
Surfaced by: 9.4.4.e sweep.

## 9.4.divbug.31 — Spurious `database disk image is malformed` for non-corrupt errors

Affects: 2 tests (`collate3.test`, `count.test`).  Symptom:
`SELECT … COLLATE caseless` where `caseless` is not registered should
raise `no such collation sequence: caseless`; our build raises
`database disk image is malformed` instead.  Similarly `count-1.2.4/5`
hit the same generic message where upstream raises a specific schema
error.
Likely cause: when the prepare-time error path raises a missing-
collation diagnostic, our `sqlite3ErrorWithMsg` arm maps SQLITE_ERROR
through `SQLITE_CORRUPT` somewhere upstream of `setErrorMsg`.  Check
`sqlite3LocateCollSeq` / `sqlite3CheckCollSeq` return-path.
Surfaced by: 9.4.4.e sweep.

## 9.4.divbug.32 — readonly DB write returns `unknown error`

Affects: 1 test (`delete.test`, delete-8.x; same shape may show in
backup/io tests once their harness lands).
Symptom: a `DELETE` against an attached read-only DB returns
`unknown error` instead of `attempt to write a readonly database`.
Likely cause: a SQLITE_READONLY result code reaches the Tcl bridge
without the corresponding error-message lookup table being primed
(or a missing `sqlite3ErrStr` entry / extended-rc demotion).
C reference: main.c `sqlite3ErrStr`, btreeBeginTrans RO arm.
Surfaced by: 9.4.4.e sweep.

## 9.4.divbug.33 — `count(DISTINCT …)` wrong result

Affects: 1 test (`distinctagg.test`, distinctagg-3.x).
Symptom: `SELECT count(DISTINCT …)` returns 1 where upstream returns 0
(empty set should yield 0).  Likely an init-vs-update ordering bug in
the DISTINCT-aggregate accumulator (the seed row is counted before the
NULL gate fires).  C reference: func.c `countStep` distinct path,
select.c `updateAccumulator` DISTINCT loop.
Surfaced by: 9.4.4.e sweep.

## 9.4.divbug.34 — `PRAGMA page_size` default mismatch

Affects: 2 tests (`createtab.test` createtab-0.2 expects 4096, got 8192;
`format4.test` format4-1.1 expects 2048, got 8192).
Symptom: a fresh DB's `PRAGMA page_size` reports the build-time default
(8192) regardless of the size the test set via `PRAGMA page_size=…` or
the format-version-implied default.  Likely the
`SQLITE_DEFAULT_PAGE_SIZE` build constant in Pascal does not honour
the per-test `PRAGMA page_size=N` before the first write that
materialises the header.  C reference: pragma.c PragTyp_PAGE_SIZE
write arm, pager.c `sqlite3PagerSetPagesize`.
Surfaced by: 9.4.4.e sweep.

## 9.4.divbug.35 — Float-to-text precision artifacts (`-1.1099999999999999`)

Affects: 2 tests (`fpconv1.test` fpconv1-1.2/1.3; `default.test`
default-3.3 — `9.22337203685478e+18` got `9.223372036854776e+18`).
Symptom: float-to-string conversion of `-1.11` yields
`-1.1099999999999999` instead of `-1.11`; large doubles get one extra
digit of mantissa.  Likely the Pascal `printf` `%!.15g` / `%.17g`
shortest-round-trip path uses `FloatToStrF(ffGeneral,15,…)` which
doesn't implement Grisu/Dragon4.  C reference: util.c
`sqlite3_str_appendf` `%g` arm, printf.c `etFLOAT`.
Surfaced by: 9.4.4.e sweep.

## 9.4.divbug.36 — `PRAGMA journal_mode=off` silently ignored

Affects: 1 test (`changes.test`, changes-1.1.0).
Symptom: `PRAGMA journal_mode=off` returns `delete` (the prior mode)
instead of `off`; subsequent ops still use the rollback journal.
Likely a missing arm in `pragma.c PragTyp_JOURNAL_MODE` write path —
the parser accepts `off` but Pascal's mode-string table doesn't
include it, so the assignment no-ops.  C reference: pragma.c
azModeName[] (~PAGER_JOURNALMODE_OFF).
Surfaced by: 9.4.4.e sweep.

## 9.4.divbug.37 — WAL `wal_hook` callback count = 0

Affects: 1 test (`e_walhook.test`, e_walhook-1.3+).
Symptom: after `db wal_hook { … }` is set and the connection commits a
WAL transaction, the hook fires but the test-counted invocation count
stays at 0.  Possibly the hook is invoked from a non-WAL path, or the
WAL frame-count argument arrives 0 (the test checks
`expr {$nFrame > 0}`).  C reference: wal.c
`sqlite3WalCallback` / pager.c walCommit invocation point.
Surfaced by: 9.4.4.e sweep.

## 9.4.divbug.38 — FK ON-clause syntax error not raised + row mis-pick

Affects: 1 test (`e_fkey.test`, e_fkey-2.1 / 3.1).
Symptom: e_fkey-3.1 expects `near "ON": syntax error` for malformed
`REFERENCES` but our parser accepts it; e_fkey-2.1 returns `world`
where upstream returns `hello` (FK-cascade target row picked wrong).
Two related symptoms under one FK-codegen root cluster.
C reference: parse.y refargs grammar; fkey.c
`sqlite3FkActionTrigger`.
Surfaced by: 9.4.4.e sweep.

## 9.4.divbug.39 — `CREATE TABLE AS SELECT` unsupported

Affects: 3 tests (`errofst1.test` errofst1-1.1; `delete.test`
delete-7.6; `distinct2.test` distinct2-100; plus older affinity3
residue).
Symptom: parser/codegen returns `CREATE TABLE AS SELECT not yet
supported in this build`.  Engine has the AST shape but the SRT_*
sink + table-creation post-step never wired.  C reference: build.c
`sqlite3EndTable` `pSelect` arm + select.c `SRT_Table`.
Surfaced by: 9.4.4.e sweep (already known but had no dedicated bucket).

## 9.4.divbug.40 — `DEFAULT` literal type + error-msg column-name drop

Affects: 1 test (`default.test`, default-1.3, default-3.1).
Symptom: default-1.3 expected
`default value of column [y] is not constant` but our build prints
`default value of column is not constant` (the `%s` column name is
dropped — sibling of divbug.14 but in DEFAULT clause).  default-3.1
returns column-affinity types in a different order (`xyz text 321
integer 432 text` vs upstream's `xyz text 321 text 432 integer`).
Likely cause: two related codegen issues in DEFAULT-clause checker
and AS-affinity propagation when the DEFAULT carries an expression.
C reference: build.c `sqlite3AddDefaultValue`, ` sqlite3AffinityType`.
Surfaced by: 9.4.4.e sweep.

