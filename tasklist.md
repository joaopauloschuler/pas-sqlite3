# pas-sqlite3 — Remaining Task List

Port of **SQLite 3** (D. Richard Hipp et al., public domain) from C to Free Pascal.
Source of truth: `../sqlite3/` (the original C reference — the upstream split
source tree under `../sqlite3/src/*.c`). The amalgamation is **not used** by
this project, neither as a porting reference nor as an oracle build input.
Inspiration for structure, tone, and workflow: `../pas-core-math/`, `../pas-bzip2/`.

REMEMBER: You are porting code. DO NOT RANDOMLY ADD TESTS unless you are looking for a specific bug. If you are porting existing tests in C, mention the origin of the test that you are porting.

If you don't have a house, you wont have a water leak in your house. If you build a house, you will not destroy the house because it has a water leak. If you can not solve the water leak, you'll keep the house and take note to fix it in a day that you can fix.

DO NOT default to the same work pattern as recent commits without questioning whether actually move the project forward.

BEFORE TRYING TO FIX A BUG, LOOK AT THE ORIGINAL C IMPLEMENTATION!!!

BEFORE STARTING TO PORT A NEW FUNCTION OR PROCEDURE, CHECK IF THIS FUNCTION ALREADY EXISTS AND IS NOT A STUB.

Goal: **behavioural and on-disk parity with the C reference.** The Pascal build
must (a) produce byte-identical `.db` files for the same SQL input, (b) return
identical query results, and (c) emit the same VDBE bytecode for the same SQL.
Any deviation is a bug in the port, never an improvement.

Important: At the end of this document, please find:
* Architectural notes and known pitfalls
* Per-function porting checklist
* Key rules for the developer

> Closed tasks/bugs are intentionally terse — full postmortems live in git
> history. Re-open a bullet (flip `[X]` → `[ ]`) and re-add detail only if the
> symptom returns.

---

## Working on this codebase (orientation for new contributors)

Correctness is defined **differentially against the C oracle**, not by hand-written
assertions.  Two gates matter:

* `bin/TestExplainParity` — the **bytecode** gate.  **1026/1026** SQL
  statements emit byte-identical VDBE vs C as of 2026-05-06 (a3).
* `src/tests/Diag*.pas` (`DiagOps`, `DiagCast`, `DiagFunctions`, `DiagWindow`,
  `DiagTxn`, `DiagFeatureProbe`, …) — the **runtime** gates.  Each probe pins a
  narrow runtime divergence to a numbered "Open Bugs" bullet.  When a Diag
  starts passing, tick the bullet.

Build with `src/tests/build.sh`; run binaries with
`LD_LIBRARY_PATH=src/ bin/<TestName>`.

FPC porting traps that recur often enough to call out up-front:

* Free Pascal identifiers are case-insensitive, so `var pPager: PPager` collides
  with the type name — rename the local (e.g. `pPgr`).  Same pattern with
  `pgno: Pgno` → `pg: Pgno`.
* `pager_error` collides with the `PAGER_ERROR` constant — always call
  `pagerSetError`.
* `var pTrigger: PTrigger` shadows a record field — rename to `pTrg`.
* The token `TK_GT` collides; use `TK_GT_TK` (and `WO_GT_WO`) when porting C arms.
* Never commit binaries from `bin/` (or `*.o`, `*.ppu`); `git rm --cached` if
  one slipped in.

---

## Phase 5 — Deferred carry-overs

- [ ] **5.7.b** `sqlite3VdbeSorter*` PMA disk-spill — STUB_INVENTORY #13 DRIFTED-XL (~2400 lines C, vdbesort.c).  In-memory mergesort is real and 1:1; PMA (Packed Memory Array) on-disk merge for sorts larger than the in-memory buffer is not yet ported.  Symptom when missed: large ORDER BY / GROUP BY / CREATE INDEX over multi-page data will fail or silently degrade once the sort buffer overflows.  Complexity: XL.  Blockers: none (self-contained — driver and PMA writer/reader port without touching the VDBE dispatch).

---

## Phase 6 — Code generators (close the EXPLAIN gate)

> TestExplainParity reports **1026 / 1026 PASS** as of 2026-05-06 (a3).

- [X] **6.8.0..6.8.6** Pragma vtab register, GenerateConstraintChecks, CompleteInsertion, WhereBegin, WhereEnd, Insert (incl. multi-row VALUES coroutine arm).
- [X] **6.8.1** sqlite3Update — single-table, UPDATE FROM, vtab dispatch, RETURNING.
- [X] **6.9** sqlite3VdbeRecordCompare / FindCompare full bodies in btree.pas.
- [X] **6.24** Aggregate-with-ORDER-BY codegen.
- [~] **6.26** Window functions (window.c). DiagWindow: 0 divergences. Reopen if DiagWindow regresses.
- [X] **6.27** schema-mutation + statistics. Analyze, Vacuum, RunVacuum, FkCheck/FkActions.
- [~] **6.28** sweep — re-search for "stub" in the pascal source code and port from C to pascal in full any function or procedure still marked as "stub" that was missed (catch-all). OP_Vacuum, BtreeIncrVacuum done; incrVacuumStep / relocatePage / modifyPagePointer not ported (gated on productive ptrmap). Inventory landed at `src/tests/STUB_INVENTORY.md` (21 actionable entries: 7 high / 6 med / 8 low). One small high-priority entry ported in 6.28 commit (`pas_openDirectory`, os_unix.c:3874..3894 → src/passqlite3os.pas:2331). Doable subtasks for the remaining six high-priority stubs (each cites the open Phase-6/9 bullet it blocks; see STUB_INVENTORY.md for full Pascal/C citations):
  - [X] **6.28.1** Port `whereLoopAddVirtual` deeper arms — audit verdict (6.28.8): stub-was-real.  Body at passqlite3codegen.pas:15658..15818 is a 1:1 four-pass driver port of where.c:4681..4803 (ALLBITS+IN, ALLBITS+!IN retry, per-distinct-prereqRight loop, all-disabled + all-disabled+!IN fallbacks).  Callees whereLoopAddVirtualOne / allocateIndexInfo / freeIndexInfo / whereLoopResize all real.  Stale "stub" banner at forward decl (codegen.pas:1932) scrubbed.  STUB_INVENTORY #1 closed.
  - [X] **6.28.2** Port `sqlite3OpenTableAndIndices` full body — audit verdict (6.28.8): stub-was-real.  Body at passqlite3codegen.pas:35907..35963 is a 1:1 port of insert.c:2870..2925 (vtab no-op, cursor assignment, HasRowid+aToOpen[0] gate, IsPrimaryKeyIndex+!HasRowid re-routing, sqlite3VdbeSetP4KeyInfo+ChangeP5).  TableLock fallback correctly inert under OMIT_SHARED_CACHE.  Stale "Phase 6.4 stub" comments inside sqlite3DeleteFrom scrubbed.  STUB_INVENTORY #2 closed.
  - [X] **6.28.3** Port `sqlite3NestedParse` body — landed at `src/passqlite3codegen.pas:40499` (C ref `build.c:293..323`).  Faithful 1:1 port: nErr/eParseMode early-out, sqlite3VMPrintf format, PARSE_TAIL save/restore via Move/FillChar, DBFLAG_PreferBuiltin toggle, dispatch via gNestedRunParser hook (registered by parser unit init).  All 22 productive call sites pass real format strings.  STUB_INVENTORY entry #3 closed.  Build clean 87/87, 5172/5172.
  - [X] **6.28.4** Complete `sqlite3AddColumn` drift arms — audit verdict (6.28.8): DRIFTED-S (~25 lines C).  Body at passqlite3codegen.pas:37284 is largely 1:1; missing arms: (a) build.c:1507 `if(!IN_RENAME_OBJECT) sqlite3DequoteToken(&sName)` pre-allocation dequote; (b) build.c:1513..1524 GENERATED-ALWAYS trailing-text strip; (c) build.c:1530 `sqlite3DequoteToken(&sType)` inside standard-typename check.  No STRICT work to do here — STRICT enforcement lives downstream in sqlite3EndTable (original inventory cite to build.c:1862..2026 was wrong).  Complexity: S.  Landed: all three arms ported 1:1 at passqlite3codegen.pas:37400..37445 (pre-alloc dequote of sName, GENERATED ALWAYS trailing-text strip, sType dequote before standard-typename match).  Build 88/88, 5177/5177; TestExplainParity 1026/1026.
  - [X] **6.28.5** Port `sqlite3LimitWhere` view-rewrite arm — audit verdict (6.28.8): stub-was-real.  Body at passqlite3codegen.pas:31123..31217 is a 1:1 port of delete.c:182..277 (rowid arm, single-PK arm, vector-PK arm, isIndexedBy/isCte FROM-dup, TK_IN wrap).  C has NO useTempRow / view-rewrite arm in this helper (original inventory "two unported arms" was wrong).  Pending work is caller-side wiring in sqlite3DeleteFrom (codegen.pas:31338 TODO) and sqlite3Update (codegen.pas:32419 TODO) — annotated as separate Phase-6.x slices, not part of this helper.  Stale "no-op stub" comments scrubbed.  STUB_INVENTORY #5 closed.
  - [X] **6.28.6** Port `OP_IntegrityCk` body — audit verdict (6.28.8): stub-was-real.  OP_IntegrityCk arm at passqlite3vdbe.pas:10715..10748 and sqlite3BtreeIntegrityCheck driver at passqlite3btree.pas:7916..8043 are both real 1:1 ports (freelist + auto-vacuum cross-check + checkTreePage walk + page-coverage map + SQLITE_DYNAMIC error string).  Remaining gap is driver-side: `PRAGMA integrity_check` in codegen.pas:45844 still emits hardcoded "ok" instead of building an OP_IntegrityCk plan — that pragma-wiring slice is **not** "port OP_IntegrityCk" and is filed as a follow-up bullet below.  Stale "OP_IntegrityCk is a stub" comment scrubbed.  STUB_INVENTORY #6 closed.
  - [ ] **6.28.6.b** Higher-level `PRAGMA integrity_check` walk arms — pragma.c:1792..2194 (~430 lines C): index-row-count cross-check, full row walk, CHECK / STRICT / UNIQUE / FK / vtab.xIntegrity per-table arms.  6.28.6.a wired the b-tree slice; this slot lands the schema-level integrity arms.  Complexity: L.
  - [X] **6.28.6.a** Wire `PRAGMA integrity_check / quick_check` to emit OP_IntegrityCk — landed at codegen.pas:45968 (pragma.c:1695..1820 + endCode at 2195..2217).  Per-attached-db root-page enumeration via tblHash walk, P4_INTARRAY (sqlite3DbMallocZero, owned by VDBE), OP_IntegrityCk emission with banner row + inline integrityCheckResultRow, plus the trailing AddImm/IfNotZero/"ok"/Halt/"corrupt"/Goto endCode block.  Higher-level walk arms (index-row-count cross-check, full row/CHECK/STRICT/UNIQUE/FK/vtab.xIntegrity — pragma.c:1792..2194) filed as 6.28.6.b follow-up.  Smoke: `PRAGMA integrity_check` and `PRAGMA quick_check` both emit "ok" via real OP_IntegrityCk on clean DBs (matches C oracle); DiagPragma integrity_check/quick_check rows green; TestExplainParity 1026/1026.
  - [X] **6.28.7** Wire `getRowTrigger` mask helper — audit verdict: stub-was-real. `trgGetRowTrigger` (passqlite3codegen.pas:30884) + `codeRowTrigger` (:30709) are 1:1 with trigger.c:1347 / 1231; aColmask[0/1] populated from sub-Parse oldmask/newmask; `sqlite3TriggerColmask` picks up real per-column bits for ordinary triggers. Stale "not yet ported" comments scrubbed; STUB_INVENTORY #7 closed.
  - [X] **6.28.9** STUB_INVENTORY medium-priority audit pass — audit verdict: 5 stub-was-real (#8 code_outer_join_constraints/pRJ, #9 sqlite3ExprNNCollSeq, #10 sqlite3DefaultRowEst, #11 codeVectorCompare, #12 sqlite3HasExplicitNulls), 1 DRIFTED-XL (#13 sqlite3VdbeSorter PMA-spill deferred; in-memory path fully ported).  Original inventory cites were wrong on 4 of 6 entries (where.c→wherecode.c, expr.c:174→:321, codegen.pas:23998→:36624, expr.c:3210→:697).  Stale "stub" / "Phase 6.6 stub" / "not yet ported" comments scrubbed at codegen.pas:20975 (pRJ banner), :16424 (NNCollSeq banner), :5517 (codeVectorCompare banner), and vdbe.pas:6232 (sorter banner refreshed to "in-memory real; PMA deferred").  STUB_INVENTORY.md updated per-entry.  Build clean.
  - [X] **6.28.10** STUB_INVENTORY low-priority audit pass — audit verdict: 5 intentional no-ops faithful to C preprocessor-gated empty macros (#14 VdbeComment/NoopComment, #15 AssertAbortable/VerifyNoMallocRequired/VerifyNoResultRow, #16 VdbeEnter/Leave, #17 SchemaMutexHeld, #18 noopWindow*Func), 2 closed (was real) with banner refresh (#19 sqlite3VtabEponymousTableClear, #20 invalidate*OverflowCache), and #21 pas_openDirectory already landed in 6.28.  Stale "stub — full version in 6.bis.1f" / "still a no-op for now" comments scrubbed in passqlite3vtab.pas:39,66.  Citation line numbers refreshed (e.g. noopWindow* moved :52321→:52792).  STUB_INVENTORY.md header now correctly states "2 actionable entries" (#4 DRIFTED-S done in 6.28.4, #13 DRIFTED-XL deferred to Phase 5.7.b).  Build clean.
  - [X] **6.28.8** Audit-pass remaining high-priority STUB_INVENTORY entries (#1 `whereLoopAddVirtual`, #2 `sqlite3OpenTableAndIndices`, #4 `sqlite3AddColumn`, #5 `sqlite3LimitWhere`, #6 `OP_IntegrityCk`).  Verdicts: #1, #2, #5, #6 were CLOSED (was real) — bodies are 1:1 with their C reference points, the inventory was citing stale marker comments at unrelated call sites; #4 is DRIFTED-S (~25 lines C of small arms — see 6.28.4 note).  Original inventory line-references / C cites were wrong on three of five entries (sqlite3AddColumn cited build.c:1862 but body is at 1490; sqlite3OpenTableAndIndices cited build.c but body is in insert.c; sqlite3LimitWhere cited delete.c:330+ but body ends at 277).  Stale "stub" comments scrubbed in passqlite3codegen.pas at the audit sites.  Net: six of seven original "high-priority" stubs are now closed; future agents have clear S/M/L estimates rather than misleading "~600 lines C" sizing.  Build 87/87 still green.

### Closed bugs (kept as ticked stubs)

- [X] **6.10** TestExplainParity closed.
- [X] **6.11** PRAGMA page_count + DROP TABLE remaining gap closed.
- [X] **6.12** sqlite3Pragma full port; DiagPragma all PASS.
- [X] **6.13** `pragma_foreign_key_list(s.name)` (and other table-valued PRAGMA functions). Sub-bugs A/B/C all closed; lateral join with hidden-arg pushdown wired through `whereLoopAddVirtual` + Case-1 codegen + WhereBegin OP_VOpen. See also subtasks 6.13.B.1..B.10 (all closed).
- [X] **6.14** Compound `SELECT … FROM sqlite_schema … UNION ALL …` — compound dispatch + selectExpander/resolveSelectNames walk pPrior.
- [X] **6.15** TestExplainParity transient regression — resolved on clean rebuild.
- [X] **6.16** Multi-vtab LEFT-JOIN + multi-aggregate AV — fixed by `sqlite3VdbeMakeReady` zero-init (see feedback memory `vdbemakeready_zero_init`).
- [X] **6.17** OR-decomposed Case-5 codegen + LIKE/GLOB range-bound prefix truncation (sub-bugs 6.17.A/B).
- [X] **6.18** pcachetrace / memtrace trampoline AV when sink is non-nil (SQLITE_CONFIG_GETPCACHE2/GETMALLOC arms now call SetDefault before copying methods).
- [X] **6.19** `.open --deserialize` — `sqlite3AppendvfsInit` was FillChar-zeroing apnd_vfs.pNext on every call, severing the VFS chain.
- [X] **6.20** Shim-VFS re-init chain corruption — same FillChar pattern in cksm/vstat/tmstmp/vlog VFS shims; all gated by initialised-Boolean now.
- [X] **6.21** `-memtrace` silent — `sqlite3Malloc` now routes through `sqlite3GlobalConfig.m.xMalloc`; libc bindings renamed to `libc_*`.
- [X] **6.22** Safe-mode error-prefix gap (`data.zErrPrefix = zErrCtx`) — argv-prefix swap ported to `processCommandLine`.
- [X] **6.23** `sqlite3_open_v2` doesn't honor `file:` URI filenames — wired `sqlite3ParseUri` into `openDatabase`; CLI calls `sqlite3_config(SQLITE_CONFIG_URI, 1)`.
- [X] **6.29 / 6.29.followup** `sum(b) OVER ()` / `avg(b) OVER ()` — colUsed propagation across window-rewrite boundary in sqlite3WindowRewrite.
- [X] **6.30** unix VFS iVersion bumped to 3 — ported `aSyscall[]` table + `unixSetSystemCall`/`unixGetSystemCall`/`unixNextSystemCall` in `passqlite3os.pas`, wired into `unixVfsObj`.
- [X] **6.31** unix-VFS locking-style shims — `sqlite3_os_init` now auto-registers `unix-none`/`unix-dotfile`/`unix-excl` siblings alongside `unix`, mirroring the `UNIXVFS` chain at `os_unix.c:8499..8542`. `.vfslist` enumeration now matches upstream's name/order. Limitation: the 4 VFS records share one `xOpen` and the C `pAppData`→finder dispatch is not yet wired through `unixOpen`, so files opened via the sibling names still get the base posix `unixIoMethods` rather than nolock/dotlock locking. Functional locking-style dispatch + dotlock `lockingContext`/mkdir machinery is a follow-up.
- [X] **6.13.B.11** `.expert` (10.1.101) reported `(no new indexes)`. Original triage blamed an `eTabType`-after-OP_ParseSchema reload, but tracing showed eTabType was correctly `TABTYP_VTAB` on republished vtabs; the real surface was the eponymous-vtab fast arm in `sqlite3Select` firing unconditionally for every single-source vtab SELECT — no WHERE/ORDER BY pushdown, so `xBestIndex` never saw the constraints and `pScan` stayed empty. Fix: in `passqlite3codegen.sqlite3Select` (passqlite3codegen.pas:~26956) restrict the fast arm to the simple `SELECT … FROM <vtab>` shape (`pWhere=nil and pOrderBy=nil and pGroupBy=nil and pHaving=nil and pLimit=nil`); other shapes fall through to `sqlite3WhereBegin → whereLoopAddVirtual` (Phase 6.13.B.7). Verified: `.expert` now emits `CREATE INDEX t1_idx_… ON t1(b)` for `SELECT * FROM t1 WHERE b=?`.

### Open Bugs (re-opened 2026-05-11)

- [X] **6.32** DiagTxn savepoint-rollback hang — closed 2026-05-12 as no-longer-reproduces. Verified `bin/DiagTxn` completes in ~107 ms with 0 divergences, and a fresh 16-deep `SAVEPOINT`/`ROLLBACK TO` stress (interleaved rollback-to with re-insertion, both `:memory:` and file-backed pagers via `bin/passqlite3`) returns correct results in under 150 ms. Likely fixed in-passing by the OP_Savepoint / pager-savepoint work landed during 6.10/6.11 and the VdbeMakeReady zero-init (bug 6.16). Removed the `timeout 10` standing workaround from `src/tests/build.sh` comment and the Phase-6 orientation note.

---

## Phase 7 — Parser

- [X] **7.1.1** Schema initialisation (prepare.c) + ATTACH reload.
- [X] **7.1.2** sqlite3NestedParse full driver.
- [X] **7.1.8** ATTACH / DETACH (attach.c).
- [X] **7.1.9** ALTER TABLE (alter.c) — all five entry points + nine SQL helpers.
- [X] **7.4b** TestBytecodeParity gate landed; sub-tasks 7.4b.1..7.4b.6 closed.
- [X] **7.4c** TestVdbeTrace differential opcode-trace gate.
- [X] **7.4d** WITHOUT ROWID runtime corruption — closed by 10.1.bug.16.
- [X] **7.4e** Bare-bareword INSERT → no-such-column error wired in resolver.

---

## Phase 8 — Public API

Public-API gap analysis: `../sqlite3/src/sqlite.h.in` exports
~238 `sqlite3_*` symbols; the Pascal port currently exposes ~156.
Windows-only entry points (`sqlite3_win32_*`) and pure typedefs are excluded.

- [X] **8.4.1** sqlite3_test_control full varargs coverage (overload-based) —
  testCtrlImpl shared dispatcher with typed overloads (op-only / int /
  db / db+int / db+pN / int+pU32 / pI32) replaces the 1-arg stub.
  Arms: PRNG_SAVE/RESTORE/SEED, FK_NO_ACTION, OPTIMIZATIONS, GETOPT,
  PENDING_BYTE, ASSERT, ALWAYS, LOCALTIME_FAULT, INTERNAL_FUNCTIONS,
  NEVER_CORRUPT, EXTRA_SCHEMA_CHECKS, ONCE_RESET_THRESHOLD, SORTER_MMAP,
  BYTEORDER, ISINIT, TRACEFLAGS, JSON_SELFCHECK.  Adds public
  sqlite3TreeTrace/sqlite3WhereTrace u32 globals (storage only — pas
  consumer-side WHERETRACE/TREETRACE blocks were skipped during port,
  matching upstream's non-debug build).  Fixed shell.pas
  SQLITE_TESTCTRL_FK_NO_ACTION (was 33, now 7 per sqlite.h.in:8690).
- [X] **8.2.1** sqlite3VdbeScanStatus + sqlite3VdbeScanStatusRange + sqlite3VdbeScanStatusCounters
  arms ported (vdbeaux.c:1186..1274); per-loop aScan[] / nScan added to TVdbe; nExec
  added to TVdbeOp and bumped in the dispatch loop; sqlite3_stmt_scanstatus_v2 reader
  ported (vdbeapi.c:2457..2606) covering NLOOP/NVISIT/EST/NAME/EXPLAIN/SELECTID/PARENTID;
  NCYCLE deferred (returns -1 — would require hwtime sampling around dispatch and
  per-op nCycle field).  sqlite3WhereAddScanStatus partially ported and wired at both
  WhereBegin emit-paths (full-planner + whereShortCut); addrLoop/addrVisit pinned to 0
  pending TWhereLevel.addrVisit field add (TWhereLevel layout extension deferred —
  NLOOP/NVISIT therefore report -1).  Shell `.scanstats on` emits per-loop block at
  end-of-statement (text shape diverges from upstream qrf.c qrfEqpStats; not yet ported).
- [X] **8.1.1** sqlite3_config / sqlite3_db_config full varargs coverage
  (overload-based — no C-ABI va_list).  Added overloads for
  CONFIG_LOOKASIDE (two int), CONFIG_LOG (xLog + pCtx), CONFIG_PAGECACHE
  (ptr + sz + N), CONFIG_MMAP_SIZE / MEMDB_MAXSIZE (two i64), and a
  CONFIG_PMASZ arm on the int overload.  sqlite3_db_config typed
  entry points (_text / _lookaside / _int) cover all upstream db-config
  shapes including MAINDBNAME, LOOKASIDE, FP_DIGITS, and all flag-toggle
  ops.  `.log` now installs a real xLog trampoline.
- [X] **8.9.2** Carray / shared-cache / misc (sqlite3_carray_bind).
- [X] **8.x** unixCurrentTimeInt64; VFS iVersion bumped 1→2.
- [X] **8.10** Public-API sample-program gate (DiagSampleProg 6 PASS / 0 FAIL).
- [X] **8.x.colneed** sqlite3_collation_needed callback fires.
- [X] **8.x.memused** db^.pnBytesFreed dry-run accounting honoured.

---

## Phase 9 — Acceptance: differential + fuzz

Each 9.x lands a self-contained gate.  All four use the same C oracle:
`libsqlite3.so` from `../sqlite3/` (already built by `src/tests/build.sh`).
Pascal output → C output diff is the only pass criterion; any deviation
is a port bug (see top of file).  All gates must run unattended under
`src/tests/build.sh` and exit non-zero on first divergence so CI catches
regressions without human triage.

### 9.1 `TestSQLCorpus.pas` — full SQL corpus differential

- [X] **9.1.1** Corpus inventory.  Enumerate every `.sql` referenced by
  existing Diag*/Test* gates (TestSQLCorpus shares the source files —
  do not copy).  Land `src/tests/corpus/MANIFEST.txt` listing each
  file with a one-line tag (`ddl`, `dml`, `dql`, `pragma`, `txn`,
  `trigger`, `view`, `cte`, `window`, `json`, `alter`, `vacuum`).
  Cross-reference against the 1026-statement TestExplainParity input
  so nothing already covered is duplicated.

- [X] **9.1.2** Oracle runner helper.  `src/tests/CorpusOracle.pas`:
  given a `.sql` path and an empty workdir, runs the C reference via
  `libsqlite3.so` (in-process, not the `sqlite3` shell — avoid Phase
  10 dependency) and captures `(stdout, stderr, rc, db-blob)`.
  Wire the same plumbing for the Pascal port via passqlite3.

- [~] **9.1.3** `TestSQLCorpus.pas` skeleton.  Iterate MANIFEST, run
  both oracles, byte-compare all four channels.  First diverging file
  prints a one-screen summary (file, channel, first 16-byte window)
  and exits non-zero.  Gate: `bin/TestSQLCorpus` rc=0.
  *Skeleton landed 2026-05-12 with 4 inline scripts (ddl/dml/dql/pragma)
  drawn from MANIFEST tier-1/tier-2 entries; bin/TestSQLCorpus rc=0;
  db-blob channel currently logs-only (gated on 9.1.4 mask).*

- [X] **9.1.3.followup** Expand `TestSQLCorpus.pas` to full MANIFEST
  coverage: pull every tier-1 source file's SQL list out of its `.pas`
  literals (the spine is the 1026-row TestExplainParity corpus) and
  every tier-2 Diag* feature-corner.  Skip tier-4 (shell-driven) and
  tier-3 entries already overlapped by tier-1.  Requires a small
  SQL-literal-extractor — landing it under this subtask keeps the
  9.1.3 skeleton diff small.
  *Landed 2026-05-12: `src/tests/SQLLiteralExtractor.pas` parses Pascal
  string literals out of `Add(...)`/`Probe(...)` plus the `Run*/Check/
  TestExpr/ProbeOne/Case/Diff` label-less anchors used by smaller Diag*
  files, then groups per-call strings into one multi-statement script
  so setup/probe pairs run in the same DB.  TestSQLCorpus now iterates
  51 tier-1 + tier-2 manifest entries (35 yield SQL, 16 use non-anchor
  helper patterns and extract empty); **2259 scripts run, 2207 pass,
  52 divergences cataloged** to `src/tests/DIVERGENCES.md` (per task
  contract: skip-and-cite, do NOT chase; first-divergence per file is
  quoted with channel + 16-byte window).  Divergences cluster in:
  RELEASE-without-SAVEPOINT errmsg wording (TestExplainParity / Bytecode
  / Parser 44 rows), PRAGMA mmap_size/journal_mode (3 rows), DROP INDEX
  errmsg truncation (1), DiagAnalyze full-script rc (3), DiagBloom
  pre-existing sqlite_stat1 (1).  bin/TestSQLCorpus rc=0; full
  regression 88/88 binaries pass.*

- [X] **9.1.4** Determinism scrub.  Strip the known non-deterministic
  fields (file-change-counter at offset 24, version-valid-for at 92,
  in-header text encoding when unset, freelist trunk order under
  identical workloads — verify each before stripping).  Document
  every masked byte range in `src/tests/corpus/MASK.md` with the C
  source citation that justifies the mask.
  *Landed 2026-05-12: `CorpusOracle.ApplyHeaderMask` zeros 4 verified
  byte ranges (24..27 change counter, 56..59 text encoding default-fill,
  92..95 version-valid-for, 96..99 SQLITE_VERSION_NUMBER) — each cites
  the C source that writes the field (pager.c:3089..3096, build.c:1354).
  Freelist trunk order + offsets 28/40/52/etc. evaluated and **rejected**
  (deterministic under identical workloads) with the rationale recorded
  in `src/tests/corpus/MASK.md`.  TestSQLCorpus now gates the db-blob
  channel ON; mask uncovers **+25 new db-blob divergences** (total
  divergence count 52 → 77; 2182 ok / 2259 scripts) cataloged in
  `DIVERGENCES.md` per skip-and-cite contract.  bin/TestSQLCorpus rc=0;
  88/88 regression binaries pass.*

- Triage of `DIVERGENCES.md` clusters surfaced by 9.1.3.followup + 9.1.4
  (77 cataloged sites, ~7 distinct root causes — each a Pascal-only bug
  bisectable against the C oracle, skip-and-cite per the corpus contract):
  - [X] **9.1.divbug.1** RELEASE-without-SAVEPOINT errmsg wording (44 sites
    across TestExplainParity/Bytecode/Parser) — single root cause, single
    fix.  Likely in `sqlite3Savepoint` / errmsg formatter; cross-check
    against `../sqlite3/src/vdbe.c` OP_Savepoint OP_REL_S arm.
    *Landed 2026-05-12: OP_Savepoint's not-found arm in `passqlite3vdbe.pas:9678`
    emitted the bare literal `'no such savepoint'`; C `vdbe.c:3902` formats
    `"no such savepoint: %s"` with the savepoint name via `sqlite3VdbeError`'s
    variadic formatter.  Fixed by routing the message through `sqlite3MPrintf`
    with `[zSvptName5g]`, transferring ownership to `zErrMsg` via the existing
    DbStrDup inside sqlite3VdbeError, then freeing the temp buffer.  Closed
    44/44 RELEASE sites; TestSQLCorpus divergence count 77 → 8; explain parity
    holds at 1026/1026; full regression 88/88.*
  - [X] **9.1.divbug.2** PRAGMA mmap_size / journal_mode output shape (3
    sites).  Likely missing newline / wrong column count vs upstream.
    *Landed 2026-05-12: `passqlite3codegen.pas:45911..45931` PRAGMA-default
    table now seeds `mmap_size`=0 (pragma.c:951..978 disabled-mmap arm), and
    the `journal_mode` read arm at `:45962..45980` queries the actual pager
    via `sqlite3PagerGetJournalMode` + `sqlite3JournalModename` instead of
    hard-coding the memdb literal `"memory"` (pragma.c:734..771).  Closed
    3/3 sites; corpus 8 → 4 divergences; explain parity 1026/1026; full
    regression 88/88.*
  - [X] **9.1.divbug.3** DROP INDEX errmsg truncation (1 site) — verify
    against `sqlite3DropIndex` / `sqlite3ErrorMsg` arms in delete.c.
    *Landed 2026-05-12: `passqlite3codegen.pas:38974..38985` now formats
    `"no such index: %s"` with `pItem^.zName` via `sqlite3MPrintf` + free,
    matching C `build.c:4614` `"no such index: %S"` for the common
    non-quoted/non-attached case.  Closed 1/1 site.*
  - [X] **9.1.divbug.4** DiagAnalyze full-script rc divergence (3 sites)
    — ANALYZE itself runs but exit rc differs.
    *Landed 2026-05-12: root cause was `sqlite3WritableSchema`
    (`passqlite3codegen.pas:36421`) reading bit `0x20`
    (`SQLITE_CacheSpill`) instead of `0x01` (`SQLITE_WriteSchema`,
    sqliteInt.h:1829), so `sqlite3CheckObjectName` (build.c:1031..1064)
    short-circuited on `writable_schema=ON` for every CREATE — users could
    fabricate `sqlite_stat1` rows that then collided with the real ANALYZE
    insert path.  Fixed the mask; same patch closes divbug.8.*
  - [X] **9.1.divbug.5** db-blob: DiagFeatureProbe ALTER COLUMN arm.
    *Landed 2026-05-12: confirmed already closed as a side-effect of the
    `sqlite3WritableSchema` bit-mask fix in 9.1.divbug.4+8
    (`passqlite3codegen.pas:36421`, bit `0x01` SQLITE_WriteSchema vs the
    previous `0x20` SQLITE_CacheSpill).  ALTER paths re-enter
    `sqlite3CheckObjectName` during the sqlite_schema rewrite + OP_ParseSchema
    reload (build.c:1031..1064), and the broken writable-schema read had been
    letting the rewrite drift on internal names.  DiagFeatureProbe now reports
    PASS on all 8 ALTER COLUMN / RENAME / DROP COLUMN probes (rename column,
    add column, rename column+SELECT, add column+SELECT, rename table+SELECT,
    rename table+pragma, drop column+pragma, drop column+SELECT).  Corpus
    2259/2259 OK, 0 divergences; explain parity 1026/1026.*
  - [X] **9.1.divbug.6** db-blob: DiagDml multi-table writes.
    *Confirmed closed 2026-05-12 by the divbug.4+8 SQLITE_WriteSchema
    bit-mask fix.  Corpus 2259/2259 OK after the bit-mask landing —
    no separate fix needed.*
  - [X] **9.1.divbug.7** db-blob: DiagDropTable.
    *Confirmed closed 2026-05-12 by the divbug.4+8 SQLITE_WriteSchema
    bit-mask fix.  Same writable-schema gate had been letting DROP TABLE
    drift on reserved internal names; once the gate reads bit 0x01
    correctly, DROP TABLE freelist+schema-cookie rewrite is byte-parity
    with C.  Corpus 2259/2259 OK.*
  - [X] **9.1.divbug.8** DiagBloom pre-existing sqlite_stat1 (1 site) —
    Pascal side emits an extra row when stat1 is already populated.
    *Landed 2026-05-12 alongside divbug.4 via the same `SQLITE_WriteSchema`
    bit-mask fix.  Companion shell fix in `passqlite3shell.pas:8540`
    (`paramTableInit` now toggles `SQLITE_DBCONFIG_WRITABLE_SCHEMA` around
    `CREATE TABLE IF NOT EXISTS temp.sqlite_parameters`, mirroring
    `bind_table_init` shell.c.in:2964).  Corpus 4 → 0 divergences;
    explain parity 1026/1026; regression 88/88.*

- [X] **9.1.5** Tag corpus categories by status: `pas-strict`
  (byte-identical), `pas-soft` (output identical, db differs in
  documented mask), `pas-skip` (gated on an open Phase 6/7/8 bullet —
  must cite the bullet).  Strict tag is the CI gate; soft/skip are
  tracked but non-blocking.
  *Tags landed in `src/tests/corpus/STATUS.txt` (TAB-delimited path /
  status / cite / note); `bin/TestSQLCorpus` loads it via
  `LoadStatusTags` and bumps per-status counters.  Strict gate fires
  `Halt(1)` if any pas-strict row diverges; current corpus run is 35
  pas-strict / 0 diverge / 0 cold.*

- [X] **9.1.6** Coverage check.  Re-run with `--coverage` against the
  port's opcode dispatcher; assert every executed opcode in
  `passqlite3vdbe.pas` is hit at least once.  Any cold opcode means
  the corpus has a gap — add a targeted `.sql`.
  *Coverage hook lives in `passqlite3vdbe.pas:gVdbeOpCoverage[]` /
  `gVdbeOpCoverageEnabled` (single predictable branch in the
  dispatcher, default-off zero cost).  `bin/TestSQLCorpus --coverage`
  flips the flag, runs the corpus + 14-script coverage-driver inline
  set, then asserts every cold opcode is allow-listed in
  `IsCoverageGap`.  Snapshot: 145 hot / 47 catalogued in
  `src/tests/corpus/COVERAGE_GAPS.md` / 0 real cold.  Allow-list
  entries each cite the planner shape that gates them.*

### 9.2 `TestReferenceVectors.pas` — canonical `.db` snapshots

- [X] **9.2.1** Vector inventory.  Added all 9 new vectors as
  `.sql` + `.db` pairs under `src/tests/vectors/` (autovacuum,
  incrvacuum, utf16, withoutrowid, generated-column, triggers,
  view-cte, partial-index, wal); fts5 + rtree shipped as `.sql`
  only ([SKIP] in MANIFEST until those extensions are ported).
  `simple.db` / `multipage.db` left untouched and tagged [~] in
  MANIFEST (legacy 3.45.x vintage; see EQUIV_LIST in regen.sh).
  All blobs generated via the C oracle (`../sqlite3/sqlite3`,
  3.53.0); inventory documented in `src/tests/vectors/MANIFEST.txt`.
  wal.db carries `journal_mode=WAL` in its header (bytes 18..19 =
  02 02); the .db-wal sidecar embeds a random salt so it cannot
  be made deterministic via the C shell — only the .db is committed.

- [~] **9.2.2** Read-only parity probe.  For each `*.db`, run a fixed
  query script (`*.queries.sql`) under both oracles, diff stdout +
  rc.  No writes — this gate is about read-side compatibility with
  files the port did not author.  *Landed `bin/TestVectorReadOnly`
  + per-vector `*.queries.sql` (11 vectors); the probe currently
  catalogues 11/11 vectors as pas-skip (bucket-A: read-only schema
  init returns SQLITE_READONLY; see `src/tests/vectors/DIVERGENCES.md`
  + MANIFEST `pas-skip` block).  Gate exits rc=0 by skipping; will
  begin gating once bucket-A is fixed under Phase 6/7.*

- [~] **9.2.3** Round-trip probe.  Open vector, run a fixed mutator
  script (`*.mutate.sql`: a handful of INSERT/UPDATE/DELETE inside
  a single txn), close, byte-diff the resulting blob against the C
  oracle's output.  Skip vectors flagged `read-only` in the
  manifest.  *Landed `bin/TestVectorRoundTrip` + per-vector
  `<name>.mutate.sql` (11 mutators; each exercises the feature the
  vector demonstrates — triggers fire, partial-index toggles,
  generated-column STORED recompute, etc.).  Re-uses
  `CorpusOracle.ApplyHeaderMask` for the post-mutator blob diff.
  All 11 mutators verified to run cleanly under `../sqlite3/sqlite3`
  before landing the test.  The probe currently skips all 11 via
  the existing bucket-A `pas-skip` block (see
  `src/tests/vectors/DIVERGENCES.md`); once bucket A is fixed the
  same gate begins actually byte-diffing the mutated blobs.  Gate
  exits rc=0 today by skipping; no new divergence buckets surfaced.*

- [~] **9.2.4** Schema-change probe.  Subset where ALTER / CREATE
  INDEX / VACUUM is exercised.  Validates Phase 6 OP_ParseSchema +
  AddColumn paths (see memory entries) under non-synthetic schemas.
  *Landed `bin/TestVectorSchemaChange` + per-vector `<name>.schema.sql`
  (8 vectors: simple, multipage, withoutrowid, view-cte, partial-index,
  generated-column, triggers, autovacuum).  Unlike 9.2.2/9.2.3 this
  gate opens RW so it does **not** inherit bucket-A; instead it
  surfaced four new buckets (B: VACUUM EAccessViolation; C: ALTER
  RENAME with dependent VIEW/CTAS; D: CREATE INDEX byte layout on
  WITHOUT ROWID; E: ALTER RENAME COLUMN on table with partial index),
  catalogued in `src/tests/vectors/DIVERGENCES.md`.  Per-vector cites
  added to MANIFEST.txt (e.g. `pas-skip view-cte.db bucket-A,bucket-C`).
  Gate today: gated=4 ok=4 diverged=0 skipped=4 rc=0; the 4 OK vectors
  (simple/multipage/generated-column/triggers) actually exercise the
  AddColumn + OP_ParseSchema paths byte-identically against the C
  oracle.*

- [X] **9.2.5** Vector regen script.  `src/tests/vectors/regen.sh`
  walks every `*.sql`, regenerates the `.db` via the C oracle
  (`../sqlite3/sqlite3`), and `cmp`s against the committed blob.
  Skip-tagged vectors (fts5/rtree, per MANIFEST) skipped gracefully;
  legacy vectors (simple/multipage, EQUIV_LIST) fall back to .dump
  equivalence because their on-disk byte layout predates 3.53.x.
  Clean run after 9.2.1: 11 OK + 2 skipped + 0 mismatch, rc=0.

### 9.3 `TestFuzzDiff.pas` — differential fuzzer

- [ ] **9.3.1** In-process harness.  `TestFuzzDiff.pas` reads a single
  `dbsqlfuzz`-format input (db prefix + SQL tail per upstream
  `test/fuzzcheck.c` — read its `ossfuzz_set_data` / db-prefix parser
  for the exact frame layout before implementing), runs it under both
  oracles in isolated workdirs, byte-diffs all four output channels
  (stdout, stderr, rc, db-blob — reuse `src/tests/CorpusOracle.pas`
  plumbing rather than re-implementing).  Apply the existing
  `ApplyHeaderMask` from 9.1.4 to the db-blob channel.  No AFL yet —
  just the one-shot driver that AFL will later call.

- [ ] **9.3.2** Seed corpus import.  Pull the upstream `dbsqlfuzz`
  seed set from `../sqlite3/test/fuzzdata*.db` (8 seed files as of
  2026-05-12) into `src/tests/fuzz/seeds/`.  Run the one-shot driver
  across every seed.  Any divergence is catalogued in
  `src/tests/DIVERGENCES.md` per the skip-and-cite contract
  established by 9.1.3.followup — do **not** chase fixes during this
  task; just surface and bucket each cluster.  Each cluster then
  becomes a `9.3.divbug.N` follow-up bullet (mirroring the
  `9.1.divbug.*` pattern).

- [ ] **9.3.3** AFL wiring.  `src/tests/fuzz/afl-driver.pas` wraps
  9.3.1 for `afl-fuzz` (read input from stdin, write to a tmp file,
  invoke the in-process harness, return AFL-compatible exit codes).
  **FPC-AFL gotcha:** FPC has no `afl-clang-fast` equivalent (no LLVM
  instrumentation pass).  Realistic options: (a) `afl-gcc` with
  deferred instrumentation via FPC's `{$LINKLIB}` + a small C
  shim that hosts the `__AFL_LOOP` macro; (b) black-box
  `afl-fuzz -n` (no instrumentation, dumb-fuzz only — much lower
  coverage but always works); (c) port the persistent-mode entry
  to a thin C wrapper that calls into the Pascal harness via
  `cdecl`.  Pick whichever the first agent can stand up cleanly;
  document the choice in `src/tests/fuzz/README.md`.  Skip
  gracefully if AFL isn't installed — script must self-report.

- [ ] **9.3.4** Crash-vs-divergence classifier.  Triage helper that
  separates (a) Pascal crash, (b) C crash, (c) silent divergence,
  (d) timeout.  Each gets its own bucket under `src/tests/fuzz/crashes/`.

- [ ] **9.3.5** ≥24 h soak target.  Wrapper script `fuzz-soak.sh`
  with `--duration` (default 24h) and stop-on-first-divergence.
  Not a CI gate — a manual gate documented in README.  Each clean
  soak bumps a counter in `src/tests/fuzz/SOAK_LOG.md` so we can
  prove the wallclock budget over time.

- [ ] **9.3.6** Coverage-guided seed minimisation.  `afl-cmin` +
  `afl-tmin` pipeline pruning the seed set to the smallest input set
  that still hits every covered branch.  Re-commit the minimised
  seeds when they shrink.

### 9.4 SQLite Tcl test suite as alternate target

- [ ] **9.4.1** Inventory.  Walk `../sqlite3/test/*.test` and tag each
  file `tcl-feature` (uses only public API — candidate), `tcl-internal`
  (touches `sqlite3_test_control` / private symbols — skip), or
  `tcl-perf` (defer to Phase 11).  Land `src/tests/tcl/MANIFEST.txt`.

- [ ] **9.4.2** Tcl binding shim.  Reuse / port the minimum of
  `../sqlite3/src/tclsqlite.c` (~6000 C lines total, but only a
  small subset is needed) so the upstream `interp` can attach to
  passqlite3 via the same `sqlite3` Tcl command.  Realistic complexity:
  **M** for the minimal `sqlite3 db1 :memory:` + `db eval` + `db close`
  trio that unblocks ~80% of `tcl-feature`; **L** if `db function` /
  `db trace` / `db authorizer` callbacks also need wiring (many
  feature tests use them).  Pre-requisite: a working
  FPC↔Tcl bridge (likely `tcl.pp` from fpc-extras or a hand-rolled
  cdecl binding to libtcl).  Sub-step before any porting: port
  `../sqlite3/test/tester.tcl` dependencies — it's the common harness
  every `.test` file loads via `source $testdir/tester.tcl`, and it
  pulls in `do_test` / `do_execsql_test` / `expected` / etc.  Without
  tester.tcl no `.test` file runs.

- [ ] **9.4.3** Driver `src/tests/TclTestDriver.pas`.  Spawns
  `tclsh` against each manifest entry with the port's shim
  preloaded; collects pass/fail/skip per test.  Output format:
  one line per test (`PASS|FAIL|SKIP <path> <assertions> <duration>`),
  matching upstream's `make test` log shape.  The gate is "every
  `tcl-feature` test exits 0 or matches the upstream skip list".
  Per the skip-and-cite contract from 9.1.3.followup, divergences
  surface into `src/tests/tcl/DIVERGENCES.md` rather than blocking
  the driver — each cluster becomes a `9.4.divbug.N` follow-up
  bullet for triage.

- [ ] **9.4.4** Skip-list curation.  Tests that depend on
  `sqlite3_test_control`, `PRAGMA legacy_*`, or other internal
  knobs land in `src/tests/tcl/SKIP.md` with a citation to the
  Phase 6/7/8 bullet that gates them.  Empty skip-list is the
  long-term goal; closed bullets prune entries here.

- [ ] **9.4.5** Linux-only nightly.  Wire into CI as a *nightly*
  job (not per-commit — the Tcl suite is ~hours).  PR gate stays
  on 9.1 / 9.2 / 9.3.1's seed-set sweep.

---

## Phase 10 — CLI tool (`shell.c`, ~12k lines → `passqlite3shell.pas`)

Each chunk lands with a scripted parity gate that diffs `bin/passqlite3`
against the upstream `sqlite3` binary.  Unported dot-commands must return
the upstream `Error: unknown command or invalid arguments: ".foo"` so
partial landings cannot silently no-op.

### 10.1a Skeleton + arg parsing + REPL loop

- [X] **10.1a** Skeleton landed; gate `tests/cli/10a_repl/` green.
- [X] **10.1.1** ShellState record + global state.
- [X] **10.1.2** processInput / oneInputLine REPL core; quickscan + line-is-terminator + continue-prompt all wired.
- [X] **10.1.3** main + process_command_line two-pass arg parser; `~/.sqliterc`/`-init` loading + `-memtrace`/`-pcachetrace` stderr sinks wired.
- [X] **10.1.4** Line reader (basic LF/CRLF). GNU readline integration deferred.
- [X] **10.1.5** Exit-code mapping + interrupt_handler + SIGINT wiring.
- [X] **10.1.6** do_meta_command dispatcher skeleton.
- [X] **10.1a.G** Gate `src/tests/TestShellRepl.pas` 8/8 PASS. One deferred section: `~/.sqliterc` auto-load (FPC base RTL has no getpwuid; port resolves $HOME only).

### 10.1b Output modes + formatting controls

- [X] **10.1b** Output modes + formatting controls. Gate: `bin/TestShellModes`.
- [X] **10.1.7..10.1.14** `.mode` dispatcher, shell_callback row dispatcher, columnar renderers, `.headers/.separator/.nullvalue/.echo/.changes/.width`, `.print/.parameter`, CSV/JSON/HTML writer helpers all landed.

### 10.1c Schema introspection dot-commands

- [~] **10.1c** Gate: `bin/TestShellSchema`. Multi-result `.tables` / `.indexes`-no-arg / temp-schema side-effects on `.databases` after `.indexes` are pre-existing port divergences and stay out of the gate.
  - [X] **10.1c.1** `.schema` (basic + pattern + `--indent` + `--nosys`)
  - [X] **10.1c.2** `.tables` (single-result + pattern)
  - [X] **10.1c.3** `.indexes` (with table arg)
  - [X] **10.1c.4** `.databases`
  - [X] **10.1c.5** `.fullschema`
  - [X] **10.1c.6** `.lint fkey-indexes` — closed via 6.13.B and 6.16.
  - [X] **10.1c.7** `.expert` (read-only subset) — engine ported in 10.1.101; productive recommendations restored by 6.13.B.11.
- [X] **10.1.15..10.1.21** `.schema --indent`, `.tables`, `.indexes`, `.databases`, `.fullschema`, `.lint fkey-indexes`, `.expert` all landed.

### 10.1d Data I/O dot-commands

- [X] **10.1d** Subcommands 10.1.22..10.1.27 landed; gate `src/tests/TestShellIO.pas` 11/11 PASS. One sub-arm deferred: **open-hexdb** (cmdOpen --hexdb still rejects empty filename — TODO inline in TestShellIO.pas).
  - [X] **10.1d.1** `.read`
  - [X] **10.1d.2** `.dump`
  - [X] **10.1d.3** `.import` — auto-create-from-header + duplicate-column renaming + heredoc input (10.1d.3.a) + pipe input (10.1d.3.b) all landed.
  - [X] **10.1d.4** `.output` / `.once` — editor/spreadsheet/browser (`-e`/`-x`/`-w`) variants and `|cmd` pipe targets intentionally not gated; future xdg-open / TProcess follow-up.
  - [X] **10.1d.5** `.save`
  - [X] **10.1d.6** `.open` (full flag set: 10.1d.6.a/b closed).
- [X] **10.1.22..10.1.27** `.read`, `.dump`, `.import`, `.output`/`.once`, `.save`, `.open` (all sub-arms a..g) landed.

### 10.1e Meta / diagnostic dot-commands

- [X] **10.1e** Gate: src/tests/TestShellMeta.pas (10.1e.G, 48/48 PASS) across .help/.show/.eqp/.explain/.cd/.shell/.system/.stats/.trace/.testcase/.testctrl/.iotrace/.scanstats/.selecttrace/.wheretrace/.timer/.log within their deterministic scope. Non-debug-build arms (`.iotrace`, `.selecttrace`, `.wheretrace`) are silent rc=0/rc=1 fall-through to match the undefined SQLITE_DEBUG / SQLITE_ENABLE_IOTRACE / SQLITE_ENABLE_SELECTTRACE C build.
- [X] **10.1.28..10.1.35, 10.1.37** `.stats`, `.timer`, `.eqp`, `.explain`, `.show`, `.help`, `.cd`, `.shell`/`.system`, `.trace` landed.
- [X] **10.1.36** `.log` — destination recorded and SQLITE_CONFIG_LOG xLog trampoline installed (8.1.1 landed).
- [X] **10.1.38** `.iotrace` — stub; full sqlite3IoTrace fanout gated on sqlite3VdbeIOTraceSql arm (currently a stub at passqlite3vdbe.pas:4122).
- [~] **10.1.39** `.scanstats` — basic per-loop dump landed (8.2.1: aScan[] +
  sqlite3_stmt_scanstatus_v2 reader + WhereAddScanStatus producer wired).  Output
  shows NAME/EXPLAIN/EST/SELECTID/PARENTID correctly.  Remaining subtasks:
  - [X] **10.1.39.a** TWhereLevel.addrVisit field added (sizeof bumps to 128);
    stamped in sqlite3WhereCodeOneLoopStart mirror of wherecode.c:2584 and fed
    through sqlite3VdbeScanStatus + ScanStatusRange in WhereAddScanStatus
    (full port of wherecode.c:333..374).  Unblocks NVISIT.
  - [X] **10.1.39.b** NLOOP/nExec confirmed: vdbe.pas:7618 increments every
    opcode (matches vdbe.c:940), and main.pas:3860..3870 dispatches NLOOP→
    addrLoop, NVISIT→addrVisit (matches vdbeapi.c:2516..2530).  Also removed
    two stale `pLevel^.addrBody := sqlite3VdbeCurrentAddr(v)` overrides inside
    sqlite3WhereCodeOneLoopStart that were re-pointing addrBody into the loop
    body — C only stamps addrBody once at where.c:7467.
  - [X] **10.1.39.c** qrfEqpStats EQP-tree formatter port (ext/qrf/qrf.c
    :162..454).  Pascal `displayScanstats` now builds an iEqpId/iParentId
    linked-list graph, renders with `|--`/``--` connectors, and stamps each
    row with NLOOP/NVISIT via a faithful qrfApproxInt64 port (4-digit base,
    K/M/G/T/P/E suffix).  Limitation: prefers zName over `aOp[addrExplain]
    .p4.z` because the v2 reader currently returns p4.z without an
    opcode-type check (the addrExplain stamp may land on non-Explain ops);
    upgrading the reader to gate on p4type=P4_DYNAMIC and re-routing through
    sqlite3VdbeExplainParent would let us re-enable EXPLAIN text — tracked
    as 10.1.39.e if needed.  TestShellMeta `.scanstats` arm stays shape-only
    (no SELECT runs in the script) so a byte-diff bump is not actionable in
    this subtask.
  - [X] **10.1.39.d** NCYCLE / hwtime sampling landed (d.1..d.4 all closed
    in one chained commit).  build.sh gained a `SQLITE_ENABLE_STMT_SCANSTATUS`
    env-var gate mirroring 10.1.42.d's `SQLITE_DEBUG=1` pattern; default
    build leaves the bracket compiled out so per-op rdtsc overhead is zero.
    - [X] **10.1.39.d.1** Added `nCycle: u64` to TVdbeOp (sizeof 32→40,
      x86_64); zero-init covered in sqlite3VdbeAddOp3, sqlite3VdbeAddOp4Int,
      sqlite3VdbeAddOpList and gVdbeOpDummy FillChar paths.  Also extended
      sqlite3_stmt_scanstatus_reset to clear nCycle (vdbeapi.c:2629).
    - [X] **10.1.39.d.2** Ported `sqlite3Hwtime` to passqlite3os.pas as
      a CPUX86_64 `asm/rdtsc` assembler routine (Intel syntax, FPC default),
      CPUAARCH64 `mrs cntvct_el0` arm, and a clock_gettime(CLOCK_MONOTONIC)
      fallback for everything else.  Faithful 1:1 with `../sqlite3/src/hwtime.h`.
    - [X] **10.1.39.d.3** Bracketed the dispatch loop in passqlite3vdbe.pas
      under `{$IFDEF SQLITE_ENABLE_STMT_SCANSTATUS}` with a
      `pCycleOp/t0Cycle` pair captured at top-of-iteration and credited at
      the next iteration (or at `vdbe_return` on abort).  This pattern
      avoids per-`continue` stamping at the cost of one extra check per
      step — equivalent to the C `pnCycle` epilogue at vdbe.c:9249..9251.
    - [X] **10.1.39.d.4** Wired SCANSTAT_NCYCLE in passqlite3main.pas:
      iScan<0 aggregate arm sums `aOp[].nCycle` across the whole program
      (vdbeapi.c:2485..2495); per-scan arm walks `pSc^.aAddrRange[]` with
      both inclusive-range and negative-start (cursor-id, OPFLG_NCYCLE)
      protocols (vdbeapi.c:2574..2606).
  - [X] **10.1.39.d.5** `TestShellScanstatsVm2` (src/tests/) — Pascal-only
    smoke that gates on `{$IFDEF SQLITE_ENABLE_STMT_SCANSTATUS}`: under
    the default build it self-reports SKIPPED with rc=0; under
    `SQLITE_ENABLE_STMT_SCANSTATUS=2 src/tests/build.sh` it pipes a
    fixed CREATE+INSERT+SELECT+`.scanstats vm`+SELECT script through
    `bin/passqlite3` and asserts (rc=0, SELECT result rows land in
    stdout, "QUERY PLAN" header from displayScanstats appears).  Closes
    the d-chain loop end-to-end — proves the d.1..d.4 nCycle credit and
    SCANSTAT_NCYCLE plumbing survive a real query through the shell.
    A byte-diff against upstream `sqlite3` was descoped: the stock
    upstream binary at ../sqlite3/sqlite3 is not built with
    SQLITE_ENABLE_STMT_SCANSTATUS and rebuilding it under the flag is
    out of scope.  Result: PASS scanstats-vm-smoke (rc=0, ~32KB stdout)
    under SCANSTATUS=2 build; SKIP under default.
  - [X] **10.1.39.e** EXPLAIN text re-enabled: SCANSTAT_EXPLAIN arm in
    passqlite3main.pas now gates on `aOp[addrExplain].p4type=P4_DYNAMIC`
    before dereferencing p4.z (sqlite3VdbeExplainParent already wired via
    8.2.1).  `displayScanstats` in passqlite3shell.pas prefers the raw
    EXPLAIN string over zName, falling back to "SCAN <zName>" when the
    addrExplain stamp is absent or non-DYNAMIC.  Removes the zName
    preference doc'd in 10.1.39.c.

  Upstream's "Warning: .scanstats not available in this build." is still echoed
  verbatim to keep TestShellMeta golden diff clean while a..c land.
- [X] **10.1.40** `.testcase NAME` / `.check ANSWER` — capture via fd-level
  dup2 onto a temp file (same plumbing as `.output`); `.check` reads it
  back and compares under default (CR/LF-stripped memcmp) / --glob /
  --notglob / --exact.  Fail diagnostic and shellMain summary line
  ("%d test(s) run with %d error(s)\n") match upstream byte-for-byte;
  rc becomes nTestErr>0.  Tested by TestShellMeta `check-*` arms.
  Deferred: dotCmdError caret-formatted location prefix (richer than our
  "Error: ...\n") — kept out of the byte-diff for the error paths, and
  the "<<ENDMARK" multi-line PATTERN form (needs seekable PFILE input).
  Doable follow-up subtasks:
  - [X] **10.1.40.a** `shellDotError` helper landed (passqlite3shell.pas)
    mirroring dotCmdError (shell.c.in:1815..1844): emits
    `<loc> <zOrig>\n<loc> <spaces>^--- <brief>\n` with the location prefix
    from a new `shellErrorLocation` port (shell.c.in:1779).  splitDotArgs
    now captures per-arg offsets into gDotOfst[] (slot 0 = cmd-name) plus
    the trimmed zOrig into gDotOrig, matching parseDotCmdArgs (shell.c.in
    :8925..8973).  Two `.check` error sites (no-testcase-active, no-
    PATTERN-specified) routed through the helper; cmdCheck now returns
    rc so option-malformed paths bump the dispatcher errCnt.
    TestShellMeta `dotcmd-error-caret` arm flipped from shape-only to
    byte-diff against upstream sqlite3 :memory: (passes byte-for-byte).
    Remaining `.check`/`.testcase` cluster sites (incompatible-options,
    unknown-option, missing-argument) still emit the legacy "Error: ...\n"
    form — promoting them is mechanical follow-up; not blocking 10.1.40
    closure.
  - [X] **10.1.40.a.followup** Routed the remaining `.check`/`.testcase`
    cluster Error sites through `shellDotError` — cmdCheck now caret-
    formats incompatible-with-prior-options (×3: --glob/--notglob/--exact
    branches) and unknown-option-after-PATTERN; cmdTestcase caret-formats
    missing-argument and unknown-option, and now returns i32 so the
    dispatcher propagates rc=1.  TestShellMeta gained two new arms
    (`dotcmd-error-caret-tc-unknown`, `dotcmd-error-caret-tc-missing`)
    byte-diffed against upstream sqlite3 :memory:.  The cmdCheck cluster
    sites are wired but not byte-diffed: upstream's cli_output_capture
    swallows both stdout AND stderr while a testcase is armed; our
    fd-level capture only redirects fd 1, so those error strings leak to
    real stderr.  Extending the capture to fd 2 is left as separate
    follow-up (the shellDotError wiring is already correct for when
    that lands).
  - [X] **10.1.40.b** `<<MARK` heredoc PATTERN form for `.check`
    landed in cmdCheck (shell.c.in:8790..8802).  When the parsed
    PATTERN argv starts with `<<`, the trailing text is the marker;
    subsequent REPL lines are pulled via oneInputLine, each appended
    (with the consumed `\n` restored), until a line whose first
    nMark bytes match the marker — that line is consumed but not
    appended.  EOF without marker is silently accepted, mirroring
    upstream's while-loop fallthrough.  TestShellMeta gained three
    new arms: `check-heredoc-pass` (multi-line PATTERN, default
    compare), `check-heredoc-fail` (PATTERN-vs-Got diagnostic),
    `check-heredoc-eof` (EOF without marker is silent).  Each
    byte-diffs against upstream sqlite3 :memory:.
- [X] **10.1.41** `.testctrl` — dispatcher routes through 8.4.1 overloads
  for OPTIMIZATIONS, FK_NO_ACTION, PRNG_SEED, PENDING_BYTE, SORTER_MMAP,
  ASSERT/ALWAYS, LOCALTIME_FAULT, NEVER_CORRUPT, EXTRA_SCHEMA_CHECKS,
  INTERNAL_FUNCTIONS, JSON_SELFCHECK, plus the existing PRNG/BYTEORDER.
  Remaining opcodes (BITVEC_TEST, FAULT_INSTALL, IMPOSTER, TUNE,
  PARSER_COVERAGE) fall through to the generic isOk=3 stub — those need
  callback / coverage infrastructure not yet ported.
- [~] **10.1.42** `.selecttrace`/`.wheretrace`/`.treetrace` — command
  shape + TRACEFLAGS toggle landed: sqlite3TreeTrace/sqlite3WhereTrace
  u32 globals now mutate through sqlite3_test_control(TRACEFLAGS, …).
  Trace-emission still gated on consumer-side blocks in codegen.
  **Mask hint convention (verified the hard way across the b.* / a.*
  rounds):** mask numbers written into the subtask bodies below are
  HINTS only — they are often bundle IDs (the planning grouping)
  rather than the literal C bit.  Always verify against
  `../sqlite3/src/sqliteInt.h` (`TREETRACE_*`) or
  `../sqlite3/src/whereInt.h` (`WHERETRACE_*`) before stamping a new
  arm, and note divergences in the commit body.
  Remaining subtasks:
  - [X] **10.1.42.a** TREETRACE consumer macros in select.c → passqlite3codegen.pas.
    First batch landed: `begin processing` / `end processing` (mask 0x1),
    `after name resolution` (0x10), `generating column names` (0x80),
    `flatten %u.%p from term %d` (0x4), `After/not helpful constant
    propagation` (0x2000), plus the four `WhereBegin` / `WhereEnd`
    breadcrumbs (0x2) wrapping each sqlite3WhereBegin / sqlite3WhereEnd
    call inside the productive sqlite3Select body.  All gated by
    `{$IFDEF SQLITE_DEBUG}` so non-debug builds stay silent.  Smoke gate:
    `.treetrace 0xFFFF` followed by a SELECT produces non-empty output
    (verified against `bin/passqlite3` with `SQLITE_DEBUG=1`).  Deferred
    sub-arms (multiSelect UNION-ALL, compound flattener peer, post-flatten
    tree, wildcard expansion, AggInfo adjustments, HAVING→WHERE,
    count-of-view, EXISTS→JOIN, dropping ORDER BY, window rewrite,
    FULL/LEFT/RIGHT-JOIN simplifies, omit FROM-subquery ORDER BY,
    end compound-select, WHERE-clause push-down, all-FROM analysis,
    DISTINCT→GROUP BY, post-aggregate analysis, Finished with AggInfo) —
    full enumeration documented inline at the tail of sqlite3Select.
    Doable follow-up subtasks (each is a small grep+port batch in
    `../sqlite3/src/select.c`, all gated by `{$IFDEF SQLITE_DEBUG}`):
    - [X] **10.1.42.a.1** multiSelect / compound flattener TREETRACE
      arms (mask 0x200): `compound-select` begin/peer/end breadcrumbs
      in `multiSelect`.  Landed: UNION ALL left/right (select.c:3011,
      3030).  Pas's multiSelect is inlined into sqlite3Select; the
      compound-end breadcrumb (select.c:7887, mask 0x400) lives on the
      sqlite3Select dispatch path and lands as part of 10.1.42.a.3.
    - [X] **10.1.42.a.2** Post-flatten / wildcard-expansion TREETRACE
      (mask 0x4 / 0x100): `after flattening`, `after wildcard expansion`
      in `sqlite3Select` body.  Landed: select.c:4706 ("After
      flattening:", mask 0x4) on flattenSubquery success-tail, and
      select.c:6339 ("After result-set wildcard expansion:", mask 0x8
      — upstream uses 0x8, not 0x100) on the star-expansion pass tail.
    - [~] **10.1.42.a.3** AggInfo / HAVING→WHERE / count-of-view /
      EXISTS→JOIN TREETRACE arms (mask 0x40 / 0x400): `AggInfo`
      adjustments, `HAVING moves to WHERE`, count-of-view rewrite,
      `EXISTS-to-IN` and `EXISTS-to-JOIN` traces in optimizer arms.
      Landed: select.c:7368 ("After EXISTS-to-JOIN optimization:",
      mask 0x100000) inside existsToJoin's hoist tail, and
      select.c:8442 ("After aggregate analysis %p:", mask 0x20) at
      the tail of the main GROUP BY analyzeAggFuncArgs.  Upstream
      C masks are 0x20 / 0x100 / 0x200 / 0x100000 (the tasklist's
      "0x40 / 0x400" referred to the bundle ID, not C bits).
      Deferred (no Pas counterpart yet): havingToWhere (select.c:7047,
      mask 0x100), countOfViewOptimization (select.c:7199, mask 0x200),
      "AggInfo adjusted for Indexed Exprs" (6572) /
      "function expressions converted to reference index" (8609) /
      "Finished with AggInfo" (8937) — none of
      optimizeAggregateUseOfIndexedExpr /
      aggregateConvertIndexedExprRefToColumn / late select_end
      AggInfo teardown are ported yet.
    - [~] **10.1.42.a.4** ORDER BY / window-rewrite / DISTINCT→GROUP BY
      TREETRACE arms (mask 0x1000 / 0x8000 — VERIFIED divergent vs C:
      upstream uses 0x800 for "dropping ORDER BY" select.c:7631, 0x40 for
      "after window rewrite" select.c:7693, 0x20000 for "Transform
      DISTINCT into GROUP BY" select.c:8192).  Landed: "after window
      rewrite" (mask 0x40) at codegen.pas after the sqlite3WindowRewrite
      call in the window-arm gate.  Deferred (no Pas host yet):
      "dropping superfluous ORDER BY" (select.c:7631) — the
      IgnorableDistinct(pDest) pOrderBy-drop arm has no Pas counterpart
      (sqlite3SelectPrep runs unconditionally with pOrderBy attached);
      "Transform DISTINCT into GROUP BY" (select.c:8192) — the SF_Distinct
      → pGroupBy optimizer arm (post-FROM-clause analysis) is not ported.
      Both land when the surrounding optimizer arms land.
    - [~] **10.1.42.a.5** Outer-join simplification + FROM-subquery
      TREETRACE arms (VERIFIED C masks: 0x1000 FULL/LEFT/RIGHT
      simplifies select.c:7737..7756; 0x800 omit FROM-subquery
      ORDER BY :7832; 0x4000 WHERE push-down :8011 and Change-unused-
      result-columns :8030; 0x8000 all-FROM analysis :8146; 0x20
      Finished-with-AggInfo :8937).  All five arms are entirely
      deferred — none of the host optimizer passes are ported yet:
      - select.c:7708..7877 outer FROM-clause optimization loop
        (JT_LEFT/RIGHT/LTORJ simplifier + IgnorableOrderby
        FROM-subquery pOrderBy drop) is not ported; Pas's sqlite3Select
        runs `existsToJoin` + `propagateConstants` then jumps straight
        into the per-shape codegen, without the per-FROM-item walk.
      - pushDownWhereTerms (where.c) and
        disableUnusedSubqueryResultColumns (select.c) are not ported,
        so the 0x4000 push-down/null-out arms have no callsite to
        attach to.
      - select.c:8136..8149 (the post-FROM-loop snapshot, mask 0x8000)
        has no Pas anchor — the snapshot point doesn't exist because
        the loop it terminates doesn't exist.
      - "Finished with AggInfo" (select.c:8937, mask 0x20) lives in
        the late select_end AggInfo teardown that's already listed
        deferred under 10.1.42.a.6 (a.6.5).
      Land in lock-step with the host ports under 10.1.42.a.6 / future
      optimizer-pass batches.
    - [ ] **10.1.42.a.6** Port the host optimizer helpers gating the
      remaining 10.1.42.a.3 sub-arms: `havingToWhere` (select.c:7047),
      `countOfViewOptimization` (:7199), `optimizeAggregateUseOfIndexedExpr`
      (:6572), `aggregateConvertIndexedExprRefToColumn` (:8609), and the
      `select_end` AggInfo teardown print (:8937).  Each is a host function
      not yet ported; once any one lands, drop its `{$IFDEF SQLITE_DEBUG}`
      TREETRACE arm at the same call site.  Treat as 5 independent
      micro-tasks (a.6.1..a.6.5) when work begins — file as needed.
  - [~] **10.1.42.b** WHERETRACE consumer macros in where.c / whereexpr.c /
    wherecode.c → passqlite3codegen.pas.  First batch landed: BEGIN/END
    `addBtreeIdx(%s)` in `whereLoopAddBtreeIndex` (mask 0x800), BEGIN/END
    `addVirtual()` in `whereLoopAddVirtual` (0x800), Begin/End processing
    OR-clause in `whereLoopAddOr` (0x400).  All gated by
    `{$IFDEF SQLITE_DEBUG}`.  Smoke gate: `.wheretrace 0xffffffff` plus
    `SELECT … WHERE a=1 OR b=2` over an indexed table emits the BEGIN/END
    addBtreeIdx + OR-clause walk (verified against bin/passqlite3 built
    with SQLITE_DEBUG=1).  Deferred sub-arms (~25 callsites in
    range-scan/STAT4 cost estimation, subset cost adjustments, query
    planner search-limit, OR/AND-vs-pseudo-index decisions, virtual-table
    constraint enumeration, solver/optimizer progress, DISTINCT row-count
    reduction, optimizer-finished marker) — enumerated inline at the
    tail of `whereLoopAddOr`; land in follow-up commits as each pas
    counterpart is confidently anchored.  Doable follow-up subtasks
    (each is a small grep+port in `../sqlite3/src/where*.c`, all gated
    by `{$IFDEF SQLITE_DEBUG}`):
    - [~] **10.1.42.b.1** Range-scan cost-estimate WHERETRACE arms in
      `whereRangeScanEst` / `whereRangeSkipScanEst` (target tasklist mask
      0x10; upstream actual mask 0x20).  Landed: `Range scan lowers nOut
      from %d to %d` (where.c:2247..2250) at the tail of the Pas
      `whereRangeScanEst` — the only WHERETRACE arm reachable in the
      no-STAT4 build that this project compiles against.  Deferred
      (STAT4-only, no Pas counterpart): `range skip-scan regions`
      (where.c:2036), `STAT4 range scan` (2215), `equality scan regions`
      (2313), `IN row estimate` (2363) — these live inside
      `whereRangeSkipScanEst` / `whereEqualScanEst` / `whereInScanEst`
      which are gated behind `SQLITE_ENABLE_STAT4` and have no Pascal
      port.  Will fold them in once the STAT4 family is ported.
    - [X] **10.1.42.b.2** Subset-cost adjustment WHERETRACE in
      `whereLoopAdjustCost` and covering-index decision arms in
      `whereLoopAddBtree` (target tasklist mask 0x800 — upstream actual
      masks are 0x80 for subset adjustments and 0x200 for covering-index
      decisions; verified against where.c).  Landed:
        * `subset cost adjustment %d,%d to %d,%d` x2 (where.c:2711..2714
          and 2720..2723, mask 0x80) inside `whereLoopAdjustCost` —
          symmetric arms for proper-subset / proper-superset cases.
        * `-> %s is not a covering index according to
          whereIsCoveringIndex()` (where.c:4203, 0x200).
        * `-> %s is a covering expression index according to
          whereIsCoveringIndex()` (where.c:4210, 0x200).
        * `-> %s might be a covering expression index according to
          whereIsCoveringIndex()` (where.c:4216, 0x200).
        * `-> %s is a covering index according to bitmasks`
          (where.c:4224, 0x200).
      All inside whereLoopAddBtree's covering-index analysis switch.
      `whereLoopInsert` itself has no plain "cost" / "not helpful" arms
      under WHERETRACE — the only WHERETRACE in whereLoopInsert family
      is the 0xffffffff non-viable-vtab-plan reject (where.c:4416) which
      lives in `whereLoopAddVirtualOne` and is tracked under b.3.
    - [X] **10.1.42.b.3** Virtual-table constraint enumeration WHERETRACE
      arms.  Target tasklist mask 0x40 in `whereLoopAddVirtualOne`;
      verified against where.c the actual host is the driver
      `whereLoopAddVirtual` (not `whereLoopAddVirtualOne`) and the
      mask is **0x800** for the four constraint-walk prints (matches
      the BEGIN/END addVirtual mask already wired in commit ec9413f).
      Landed inside the Pas driver:
        * `  VirtualOne: all usable`            (where.c:4720, 0x800)
        * `  VirtualOne: all usable w/o IN`     (4745, 0x800)
        * `  VirtualOne: mPrev=%04llx mNext=%04llx` (4770, 0x800)
        * `  VirtualOne: all disabled`          (4784, 0x800)
        * `  VirtualOne: all disabled and w/o IN` (4794, 0x800)
      Plus the two arms inside `whereLoopAddVirtualOne` itself:
        * `  ^^^^--- non-viable plan rejected!` (4416, 0xffffffff)
          on SQLITE_CONSTRAINT short-circuit.
        * `  bIn=%d prereqIn=%04llx prereqOut=%04llx` (4531, 0xffffffff)
          on every successful exit.
      All gated by `{$IFDEF SQLITE_DEBUG}`.
    - [~] **10.1.42.b.4** Query-planner solver progress WHERETRACE in
      `wherePathSolver` (mask **0x002 / 0x004**, NOT 0x80 — verified against
      sqliteInt.h:1181 / where.c:5857 / :5988 / :6032 / :6129).  Landed the
      two mask-0x002 arms: "---- begin solver" (where.c:5857) and the
      sort-cost increase line (where.c:5988..5991).  The four mask-0x004
      candidate prints (Skip / New / Update / `vs`) at where.c:6032..6101
      and the mask-0x002 "---- after round %d" summary at where.c:6129
      are deferred behind a `TODO 10.1.42.b.4` marker in
      passqlite3codegen.pas — they consume `wherePathName(WherePath*,iLoop,
      WhereLoop*)` which is not yet ported.  Land once wherePathName drops.
    - [~] **10.1.42.b.5** OR-vs-AND / pseudo-index decision WHERETRACE
      in `whereLoopAddOr` (mask **0x400** verified, matches tasklist hint
      and sqliteInt.h:1191 — OR optimization).  Landed the per-subterm
      breadcrumb at where.c:4866..4867: `"OR-term %d of %p has %d
      subterms:"`.  The "Begin processing OR-clause" / "End processing
      OR-clause" arms were already ported in batch 10.1.42.b.
      Deferral note: the tasklist title mentioned "cost compares, pseudo-
      index selection" but where.c review shows whereLoopAddOr itself
      carries only mask-0x400 breadcrumbs — no cost-compare or pseudo-
      index 0x400 arms exist in this function.  The 0x40 (IN-operator)
      and 0x80 (cost-adjustment) arms live in `whereLoopAddBtreeIndex`,
      not `whereLoopAddOr`, and are tracked separately under earlier
      10.1.42.b sub-tasks.  Also deferred behind a `TODO 10.1.42.b.5`
      marker: the companion mask-0x20000 sub-arm `sqlite3WhereClausePrint
      (sSubBuild.pWC)` at where.c:4868..4870 — host helper not yet ported.
    - [~] **10.1.42.b.6** DISTINCT reduction + optimizer-finished
      trailing WHERETRACE in `sqlite3WhereBegin` epilogue.  Mask divergence
      vs tasklist hint: tasklist suggested 0x1 (code generation per
      sqliteInt.h:1180); the actual upstream literals are
      **0x0080** (WhereLoop cost adjustments, sqliteInt.h:1188) for the
      DISTINCT-reduction print at where.c:7118 and **0xffffffff**
      (any-trace) for the "*** Optimizer Finished ***" line at
      where.c:7195.  Both landed in passqlite3codegen.pas — the DISTINCT
      block also carries the `nRowOut -= 30` body that the WHERETRACE
      bracket calls out (tag-20250414a).  Build green pre/post both
      ways: -30 nRowOut shift does not change any TestExplainParity or
      TestWhereCorpus row.  Deferred behind `TODO 10.1.42.b.6`:
        * "---- Solution cost=%d, nRow=%d ... DISTINCT=..." summary
          block at where.c:7132..7157 (consumes sqlite3WhereLoopPrint).
        * mask-0x4000 "---- WHERE clause at end of analysis:" dump at
          where.c:7190..7194 (consumes sqlite3WhereClausePrint).
      Land both once their host printers drop.
    - [ ] **10.1.42.b.7** Port the STAT4 cost-estimator helpers that
      gate the 4 deferred 10.1.42.b.1 arms: `whereRangeSkipScanEst`
      (where.c:2036), `whereEqualScanEst` (:2215 / :2313),
      `whereInScanEst` (:2363).  Each is a STAT4-driven planner helper
      not yet present in passqlite3codegen.pas.  Mask: 0x20 (verified
      against whereInt.h, NOT 0x10 as tasklist initially suggested).
      Treat as 3 independent micro-tasks; drop the WHERETRACE call at
      each host function as it lands.
    - [ ] **10.1.42.b.8** Port the WHERE-clause / where-loop / path
      debug-printer helpers that gate ~7 deferred WHERETRACE arms
      across 10.1.42.b.4/5/6: `wherePathName` (where.c — grep for the
      definition, prints `wherePath` letters), `sqlite3WhereLoopPrint`
      (where.c), `sqlite3WhereClausePrint` (where.c).  All three are
      `#ifdef WHERETRACE_ENABLED` helpers in C.  Port under
      `{$IFDEF SQLITE_DEBUG}` into passqlite3codegen.pas.  High
      leverage: lands `Skip/New/Update/vs` rows in solver progress,
      `Solution cost=` summary, `OR-term sub-WHERE-clause` print,
      `WHERE clause at end of analysis` print.
    - [X] **10.1.42.a.6.1** Port `havingToWhere` (select.c:7047) so the
      0x100 TREETRACE arm at the same site (10.1.42.a.3 deferred) can land.
      Landed: `havingToWhere` + `havingToWhereExprCb` in
      passqlite3codegen.pas (with the prerequisite
      `sqlite3ExprIsConstantOrGroupBy` + `exprNodeIsConstantOrGroupBy`
      pair just above sqlite3ExprIsSingleTableConstraint).  Wired at
      the SF_Aggregate+GROUP-BY main path, between
      `sqlite3ExprAnalyzeAggList(pEList)` and
      `sqlite3ExprAnalyzeAggregates(pHaving)` (mirrors select.c:8422..8431).
      0x100 TREETRACE arm landed `{$IFDEF SQLITE_DEBUG}` at the tail of
      havingToWhere (select.c:7045..7050).  Builds clean default +
      SQLITE_DEBUG=1; TestExplainParity 1026/1026, TestSQLCorpus 2259/2259.
    - [ ] **10.1.42.a.6.2** Port `countOfViewOptimization` (select.c:7199)
      so the 0x200 TREETRACE arm can land.
    - [ ] **10.1.42.a.6.3** Port `optimizeAggregateUseOfIndexedExpr`
      (select.c:6572) so the AggInfo-adjusted-for-indexed-exprs print can land.
    - [ ] **10.1.42.a.6.4** Port `aggregateConvertIndexedExprRefToColumn`
      (select.c:8609) so the function-expr-converted print can land.
    - [ ] **10.1.42.a.6.5** Port the `select_end` AggInfo teardown
      (select.c:8937) so the "Finished with AggInfo" trailing print can land.
    - [ ] **10.1.42.a.7** Port `simplifyOuterJoins` outer-join simplifier
      loop (select.c:7737..7756) so the 0x1000 FULL/LEFT/RIGHT-JOIN
      simplification TREETRACE arms (10.1.42.a.5 deferred) can land.
    - [ ] **10.1.42.a.8** Port the omit-FROM-subquery-ORDER-BY arm
      (select.c:7832) so the 0x800 TREETRACE arm can land.
    - [ ] **10.1.42.a.9** Port `pushDownWhereTerms` +
      `disableUnusedSubqueryResultColumns` (select.c:8011/8030) so the
      0x4000 WHERE-clause push-down and unused-col NULL TREETRACE arms can land.
    - [ ] **10.1.42.a.10** Port the all-FROM-clause final analysis loop
      (select.c:8146) so the 0x8000 TREETRACE arm can land.
    - [ ] **10.1.42.a.11** Port the optimizer arm that drops superfluous
      ORDER BY (select.c:7631, mask 0x800) so the deferred 10.1.42.a.4
      arm can land.
    - [ ] **10.1.42.a.12** Port the DISTINCT→GROUP BY transform
      (select.c:8192, mask 0x20000) so the deferred 10.1.42.a.4 arm can land.
  - [X] **10.1.42.c** sqlite3DebugPrintf — ported from printf.c:1514..1532 as
    `procedure sqlite3DebugPrintf(zFormat: PAnsiChar; const args: array of const)`
    in passqlite3printf.pas.  Renders via the existing sqlite3FormatStr core,
    writes to stdout and flushes — same observable behaviour as upstream's
    `fprintf(stdout, "%s", zBuf); fflush(stdout);`.  No earlier shim existed
    (grep returned no Pascal-side definition).  Callable from every unit that
    already imports passqlite3printf (codegen, where, ...).
  - [X] **10.1.42.d** Build-flag gating landed.  `src/tests/build.sh` now
    honours an `SQLITE_DEBUG=1` env var by forwarding `-dSQLITE_DEBUG` to
    fpc; default invocations (`./src/tests/build.sh`) leave it undefined so
    every `{$IFDEF SQLITE_DEBUG}` consumer block compiles out to a silent
    no-op — preserves non-debug parity with upstream's plain
    `./configure && make`.  Gate documented in `src/passqlite3.inc`.  Both
    default and `SQLITE_DEBUG=1` variants now compile cleanly (only
    pre-existing range/ptr-conv warnings); the future 10.1.42.a/b
    TREETRACE/WHERETRACE arms drop straight into this gate.

### 10.1f Long-tail / specialised dot-commands

- [ ] **10.1f** Out-of-scope dependencies (session, archive, recover) may stub with the upstream `SQLITE_OMIT_*` "feature not compiled in" message. Gate: `tests/cli/10f_misc/`.
  - [X] **10.1f.0..10.1f.2** `.backup` / `.restore` / `.clone` — gated by `src/tests/TestShellBackup.pas`.
  - [X] **10.1f.3** `.archive`/`.ar` — gated by `src/tests/TestShellArchive.pas`.
  - [X] **10.1f.4** `.session` — gated by `src/tests/TestShellArchive.pas` shape arm (stub per 10.1.47).
  - [X] **10.1f.5** `.recover` — gated by `src/tests/TestShellArchive.pas`.
  - [X] **10.1f.6** `.dbinfo` — gated by `src/tests/TestShellDbinfo.pas`. Side-fix: route positional dot-cmd rc through process exit (shell.c.in:13548).
  - [X] **10.1f.7** `.dbconfig` — gated by `src/tests/TestShellDbinfo.pas`. Counter/pointer DBCONFIG_* ops now reachable via the typed sqlite3_db_config_* entry points (8.1.1).
  - [X] **10.1f.8** `.filectrl` — gated by `src/tests/TestShellFilectrl.pas`. PERSIST_WAL/POWERSAFE_OVERWRITE skipped (port unix VFS xFileControl lacks those arms).
  - [X] **10.1f.9** `.sha3sum` — gated by `src/tests/TestShellFilectrl.pas`.
  - [X] **10.1f.10..10.1f.13** `.crnl`/`.binary`/`.connection`/`.unmodule` — gated by `src/tests/TestShellMisc.pas`.
  - [X] **10.1f.14..10.1f.16** `.vfsinfo`/`.vfslist`/`.vfsname` — handler-shape parity in `src/tests/TestShellMisc.pas`; success-path stdout byte-parity blocked by szOsFile=88 layout divergence (unixFile record padding), 6.30/6.31 fixed.

- [X] **10.1.43..10.1.45** `.backup`, `.restore`, `.clone` all landed.
- [X] **10.1.46** `.archive`/`.ar` — full port; closed via bugs 6.17.A/B for GLOB range-bound truncation.
- [X] **10.1.47** `.session` — stub (session extension not ported).
- [X] **10.1.48** `.recover` — full port (~957 lines + LAF arm + wrapper-VFS arm). Sub-arms 10.1.48.a/b/c/d all closed (related .expert surface tracked under 6.13.B.11, now closed).
- [X] **10.1.49** `.dbinfo`.
- [X] **10.1.50** `.dbconfig` — boolean DBCONFIG_* + FP_DIGITS dispatched; counter/pointer DBCONFIG_* (LOOKASIDE, MAINDBNAME) reachable via sqlite3_db_config_lookaside / sqlite3_db_config_text (8.1.1).
- [X] **10.1.51..10.1.59** `.filectrl`, `.sha3sum`, `.crnl`, `.binary`, `.connection`, `.unmodule`, `.vfsinfo`/`.vfslist`/`.vfsname`, `.dbtotxt`, `.breakpoint` all landed.

### 10.1.60..10.1.100 — ext/misc and ext/* extension ports (all landed)

All ported as new units under `src/`. Wired via per-unit `sqlite3<Name>Init`
in shell `openDb` unless noted. Common caveat across many eponymous-vtab
ports: bare table-valued or MATCH-style invocations are blocked by bug 6.13
(now closed via 6.13.B); the modules themselves are faithful end-to-end.

- [X] **10.1.60** sha1.c → passqlite3sha1.pas
- [X] **10.1.61** uuid.c → passqlite3uuid.pas
- [X] **10.1.62** ieee754.c → passqlite3ieee754.pas
- [X] **10.1.63** percentile.c → passqlite3percentile.pas
- [X] **10.1.64** rot13.c + uint.c + base64.c
- [X] **10.1.65** totype.c → passqlite3totype.pas
- [X] **10.1.66** base85.c + eval.c + urifuncs.c
- [X] **10.1.67** anycollseq.c + blobio.c + nextchar.c + remember.c + stmtrand.c
- [X] **10.1.68** noop.c + zorder.c + randomjson.c
- [X] **10.1.69** wholenumber.c + templatevtab.c + showauth.c + mmapwarm.c
- [X] **10.1.70** prefixes.c + memstat.c
- [X] **10.1.71** series.c → passqlite3series.pas
- [X] **10.1.72** completion.c → passqlite3completion.pas
- [X] **10.1.73** decimal.c → passqlite3decimal.pas
- [X] **10.1.74** normalize.c → passqlite3normalize.pas
- [X] **10.1.75** regexp.c → passqlite3regexp.pas
- [X] **10.1.76** stmt.c + explain.c
- [X] **10.1.77** qpvtab.c + memtrace.c + pcachetrace.c
- [X] **10.1.78** btreeinfo.c + vtablog.c
- [X] **10.1.79** scrub.c → passqlite3scrub.pas
- [X] **10.1.80** fossildelta.c → passqlite3fossildelta.pas
- [X] **10.1.81** dbdump.c → passqlite3dbdump.pas
- [X] **10.1.82** csv.c → passqlite3csv.pas
- [X] **10.1.83** closure.c → passqlite3closure.pas
- [X] **10.1.84** appendvfs.c → passqlite3appendvfs.pas
- [X] **10.1.85** vfslog.c → passqlite3vfslog.pas
- [X] **10.1.86** fileio.c → passqlite3fileio.pas
- [X] **10.1.87** vfsstat.c → passqlite3vfsstat.pas
- [X] **10.1.88** vfstrace.c → passqlite3vfstrace.pas
- [X] **10.1.89** vtshim.c → passqlite3vtshim.pas
- [X] **10.1.90** cksumvfs.c → passqlite3cksumvfs.pas (VFS shim exported but not auto-installed)
- [X] **10.1.91** unionvtab.c → passqlite3unionvtab.pas
- [X] **10.1.92** fuzzer.c → passqlite3fuzzer.pas
- [X] **10.1.93** tmstmpvfs.c → passqlite3tmstmpvfs.pas (NOT auto-installed)
- [X] **10.1.94** amatch.c → passqlite3amatch.pas
- [X] **10.1.95** compress.c + sqlar.c (libz via cdecl, `-k-lz`)
- [X] **10.1.96** ext/intck/sqlite3intck.c → passqlite3intck.pas
- [X] **10.1.97** ext/recover/dbdata.c → passqlite3dbdata.pas
- [X] **10.1.98** zipfile.c → passqlite3zipfile.pas
- [X] **10.1.99** spellfix.c → passqlite3spellfix.pas
- [X] **10.1.100** Built-in shell SQL UDFs: strtod, dtostr, shell_add_schema, shell_module_schema, shell_putsnl, usleep. editFunc deferred.
- [X] **10.1.101** `ext/expert/sqlite3expert.c` → `passqlite3expert.pas`. Productive recommendations confirmed once 6.13.B.11 was closed.
- [X] **10.1.102** `.open --zip` / `--deserialize` / `--hexdb` shell glue + faithful `sqlite3_deserialize` port.

- [ ] **10.1a.1** fill the next porting chunk here.

### 10.1.bug.* — fixed bug ledger (kept as ticked stubs only)

> Closed bugs: history is in git. Each line below records the slot for
> regression-tracking purposes — re-open the slot if the symptom returns.

- [X] **10.1.bug.1** Header row leak in `.mode list` (QRF tri-state semantics).
- [X] **10.1.bug.103** strftime('%u') ISO weekday off-by-one.
- [X] **10.1.bug.105** ISO 8601 `[+-]HH:MM` timezone suffix dropped.
- [X] **10.1.bug.106** `'localtime'` / `'utc'` date modifiers were no-ops.
- [X] **10.1.bug.107** CREATE UNIQUE INDEX on pre-populated dups silently succeeded (sqlite3VdbeSorterCompare).
- [X] **10.1.bug.108** UNIQUE INDEX with COLLATE NOCASE ignored collation (sqlite3CreateIndex must peel TK_COLLATE).
- [X] **10.1.bug.109** `SELECT * FROM v ORDER BY a,b` with covering UNIQUE index returned `0.0|0.0` rows (nOBSat shortcut must reset bSortOmitRef/nPrefixReg).
- [X] **10.1.bug.110** current_date / current_time / current_timestamp not registered.
- [X] **10.1.bug.111** AUTOINCREMENT counter not consulted (OP_NewRowid missing P3 arm).
- [X] **10.1.bug.112** Star expansion skipped in prior arms of compound (selectExpander must walk pPrior).
- [X] **10.1.bug.113** FROM-subquery coroutine in compound MERGE arms.
- [X] **10.1.bug.114** Numeric-prefix coercion lost decimal/exponent (numericType missing `(rcM and 2)=0` guard).
- [X] **10.1.bug.115** WITH RECURSIVE … LIMIT inside body: ran forever / no rows.
- [X] **10.1.bug.116** Correlated subqueries with qualified outer refs failed (resolver order + ResolveOuterRefs walk).
- [X] **10.1.bug.117** min(x)/max(x) over all-NULL returned blob "0.0" (minMaxFinal flag check).
- [X] **10.1.bug.118** shellEPutZ stderr/stdout interleave order (drain Output first).
- [X] **10.1.bug.119** replace(s,p,r) with NULL p or r returned s instead of NULL.
- [X] **10.1.bug.120** Result-set column aliases not visible in WHERE (ResolveAliasInWhere walker).
- [X] **10.1.bug.121** LIMIT/OFFSET ignored on eponymous-vtab fast-arm.
- [X] **10.1.bug.122** Aggregates over eponymous-vtab returned empty (isVtabAgg must drive xBestIndex).
- [X] **10.1.bug.123** WITH RECURSIVE … ORDER BY dropped (SRT_Queue/SRT_DistQueue dispatch).
- [X] **10.1.bug.124** CLI `near line N` off-by-one with comment-interleaved scripts.
- [X] **10.1.bug.125** Step-error rc was extended code, missing " (rc)" suffix; sqlite3VdbeReset must apply errMask.
- [X] **10.1.bug.126** JSON-function malformed-input errors silently swallowed.
- [X] **10.1.bug.127** ORDER BY+LIMIT silently dropped sort on coroutine FROM. Bonus: signFunc must use numeric_type, not value_type.
- [X] **10.1.bug.128** CLI step-error prefix should be `Error near line N:` (no `Runtime error`, no `(rc)` suffix).
- [X] **10.1.bug.129** CLI openDb missed `sqlite3_db_config(TRUSTED_SCHEMA=0, DEFENSIVE=1, STMT_SCANSTATUS=0)`. Regression: bin/TestShellTrustedSchema.
- [X] **10.1.bug.130** `UPDATE T AS t SET col=(SELECT … WHERE inner.col=t.col)` errored "no such column: t.col". Regression: bin/TestUpdateCorrelated.
- [X] **10.1.bug.131** Bare-TK_ID outer ref from inside a correlated subquery errored. Regression: bin/TestCteOuterID.
- [X] **10.1.bug.132** CLI `processInput` cut-gate required `zSql[end]=';'` before sqlite3_complete; trailing `--` comment caused statement-merging. Regression: bin/TestShellSemiComment.
- [X] **10.1.bug.133** CLI `.echo on` was a silent no-op.
- [X] **10.1.bug.134** CLI `.parameter set` populated temp.sqlite_parameters but `bind_prepared_stmt` was never ported. Also wired echo_group_input emissions at the four matching processInput cut points. Regression: bin/TestShellParameter, bin/TestShellEcho.
- [X] **10.1.bug.135** `.changes` / `.show` defects: per-SQL emission, `output:` line ordering, `output_c_string` escaping, `autoExplain` default. Regression: bin/TestShellChanges.
- [X] **10.1.bug.136** Meta dot-command dispatcher sweep (10.1e.G): `procedure→function: i32` conversions to propagate rc, wording/format/array-size drifts. Regression: bin/TestShellMeta.

---

## Known regression-test failures (auto-discovered by `run_regression.sh`)

> Ledger entries: when a binary returns to all-green, mark `[X]` and leave
> in place as a fixed-bug record (matching the convention used by 10.1.bug.*).
> Numbering is scoped to the phase that owns the root cause.

- [X] **3.B.regbug.1** TestPagerReadOnly — fixed 2026-05-10 (test-fixture path-resolution defect).
- [X] **6.regbug.1** TestWhereExpr — fixed 2026-05-10 (test-fixture: `pTab^.iPKey` left at 0, must stamp `-1` after `sqlite3DbMallocZero`).

---

## Phase 10.2 — CLI integration parity

- [ ] **10.2** Integration parity: `bin/passqlite3 foo.db` ↔
  `sqlite3 foo.db` on a scripted corpus that unions all 10.1a..f
  golden files plus kitchen-sink multi-statement sessions (modes,
  attached DBs, triggers, dump+reload).  Diff stdout, stderr, exit
  code; any divergence is a hard failure.

---

## Phase 11 — Benchmarks (Pascal-on-Pascal speedtest1 port)

Output format must be byte-identical to upstream `speedtest1` so the
existing `speedtest.tcl` diff workflow keeps working.  Lives in
`src/bench/passpeedtest1.pas`; the same binary swaps backends
(passqlite3 vs system libsqlite3) by `--backend`.

- [ ] **11.1** Harness port (speedtest1.c lines 1..780): argument
  parser, `g` global state, `speedtest1_begin_test` /
  `speedtest1_end_test`, `speedtest1_random`, `speedtest1_numbername`,
  result-printing tail.  Gate: `bench/baseline/harness.txt`.

- [ ] **11.2** `testset_main` port (lines 781..1248) — the ~30
  numbered cases (100..990) of the canonical OLTP corpus.  Primary
  regression gate.  Gate: `bench/baseline/testset_main.txt`.

- [ ] **11.3** Small / focused testsets (one chunk):
  `testset_cte` (1250..1414), `testset_fp` (1416..1485),
  `testset_parsenumber` (2875..end).  Gate:
  `bench/baseline/testset_{cte,fp,parsenumber}.txt`.

- [ ] **11.4** Schema-heavy testsets: `testset_star` (1487..2086),
  `testset_orm` (2272..2538), `testset_trigger` (2539..2740).
  Gate: `bench/baseline/testset_{star,orm,trigger}.txt`.

- [ ] **11.5** Optional / extension-gated testsets: `testset_debug1`
  (2741..2756, lands with 11.4); `testset_json` (2758..2873, gated
  on Phase 6.8 — already in scope); `testset_rtree` (2088..2270,
  gated on R-tree extension port — currently unscheduled, stub with
  omit-style message until it lands).

- [ ] **11.6** Differential driver `bench/SpeedtestDiff.pas`.  Runs
  `passpeedtest1` twice (passqlite3 vs system libsqlite3 via the
  `--backend` flag) and emits a side-by-side ratio table; strips
  wall-clock timings so the *output* of both runs can also be diffed
  for byte-equality.

- [ ] **11.7** Regression gate: commit `bench/baseline.json` (one
  row per `(testset, case-id, dataset-size)` carrying the expected
  pas/c ratio).  `bench/CheckRegression.pas` re-runs the suite,
  compares against baseline, exits non-zero on >10% relative
  regression.  Hooked into CI for small/medium tiers; the 10M-row
  tier stays a manual local gate.

- [ ] **11.8** Pragma / config matrix.  Re-run `testset_main` across
  the cartesian product `journal_mode ∈ {WAL, DELETE}`,
  `synchronous ∈ {NORMAL, FULL}`,
  `page_size ∈ {4096, 8192, 16384}`,
  `cache_size ∈ {default, 10× default}`.  Emit a single matrix
  table; the interesting result is *which knobs move the pas/c
  ratio*.

- [ ] **11.9** Profiling hand-off to Phase 9.  Wrapper scripts that
  run `passpeedtest1` under `perf record` and
  `valgrind --tool=callgrind`, plus a small Pascal helper that
  annotates the resulting reports against `passqlite3*.pas` source
  lines.  Output of this task is the input of 9.1.

---

## Phase 12 — Performance optimisation (enter only after Phase 9 green)

Changes here must preserve byte-for-byte on-disk parity.  Compile
flags: `-dAVX2 -CfAVX2 -CpCOREAVX -OpCOREAVX`.  Note: in FPC,
functions with `asm` content cannot be inlined.

- [ ] **12.1** `perf record` on benchmark workloads; identify the
  top 10 hot functions.

- [ ] **12.2** Aggressive `inline` on VDBE opcode helpers, varint
  codecs, and page cell accessors.

- [ ] **12.3** Consider replacing the VDBE big `case` with threaded
  dispatch (computed-goto-style) using `{$GOTO ON}`.  Land only if
  profiling shows the switch is a real bottleneck.

---

## Out of scope until core is green (carry-over from history.md)

These remain explicitly deferred and are **not** part of finishing
the port unless a user requests them after Phases 0–9 are green:

- `../sqlite3/ext/` — every extension directory (fts3/fts5, rtree,
  icu, session, rbu, intck, recover, qrf, jni, wasm, expert, misc).
- Test-harness C files inside `src/` (`src/test*.c`,
  `src/tclsqlite.{c,h}`).  Phase 9.4 calls the Tcl suite via the
  C-built `libsqlite3.so`, never via a Pascal port of these files.
- `src/os_kv.c` — optional key-value VFS.
- `src/os_win.c`, `src/mutex_w32.c`, `src/os_win.h` — Windows
  backend (Linux first; Windows is a Phase 11+ stretch).
- Forensic / one-off tools: `tool/showwal.c`, `dbhash`, `enlargedb`,
  `fast_vacuum`, `max-limits`, etc.  (`tool/lemon.c`,
  `tool/lempar.c` are in scope as Phase 7 inputs.)

---

## Per-function porting checklist (apply to every new function)

- [ ] Signature matches the C source (same argument order, same
  types — `u8` stays `u8`, not `Byte`).
- [ ] Field names inside structs match C exactly.
- [ ] No substitution of Pascal `Boolean` for C `int` flags — use
  `Int32` / `u8`.
- [ ] `static` C locals moved to unit-level `var` (thread-unsafe
  in C too — OK).
- [ ] `const` arrays moved verbatim; values unchanged.
- [ ] Macros expanded inline OR replaced with `inline` procedures
  of identical semantics.
- [ ] `assert()` calls retained; `AssertH` logs file/line and halts.
- [ ] Compiles `-O3` clean (no warnings in new code).
- [ ] A differential test exercises the function's layer.

---

## Design decisions

1. **Prefix convention.** Pascal port keeps `sqlite3_*` for public API
   (drop-in readable for anyone who knows the C API); C reference in
   `csqlite3.pas` is declared as `csq_*`. Tests are the only code that uses
   `csq_*`.

2. **No C-callable `.so` produced by the port.** Pascal consumers only. If
   someone later wants an ABI-compatible `.so`, revisit — it would constrain
   record layout and force `cdecl` / `export` everywhere for no current user
   demand.

3. **Split sources as the single source of truth.** `../sqlite3/src/*.c` is
   the authoritative reference **and** the oracle build input. The
   amalgamation is not generated, not checked in, not referenced. Reasons:
   (a) our Pascal unit split mirrors the C file split 1:1, so "port
   `btree.c` lines 2400–2600" is a natural commit unit; (b) grep in a 5 k-line
   file beats grep in a 250 k-line one; (c) upstream patches land in specific
   files — tracking what needs re-porting is trivial with split, painful with
   amalgamation; (d) using upstream's own `./configure && make` to build the
   oracle means compile flags, generated headers, and link order all stay
   correct by construction, without a bespoke gcc invocation that would drift.

4. **`{$MODE OBJFPC}`, not `{$MODE DELPHI}`.** Matches pas-core-math and
   pas-bzip2. Enables `inline`, operator overloading, and modern syntax.

5. **`{$GOTO ON}` project-wide.** Enabled in `passqlite3.inc`. Used (if at
   all) by the parser and possibly the VDBE dispatch. Enabling unit-by-unit
   adds noise.

6. **Differential testing is a first-class deliverable, not a QA afterthought.**
   The test harness is built before any non-trivial porting. See "The
   differential-testing foundation" above.

7. **The per-function checklist doubles as a PR template** (same convention
   as pas-core-math and pas-bzip2 — copy into each PR description).

---

## Key rules for the developer

1. **Do not change the algorithm.** This is a faithful port. The C source in
   `../sqlite3/` is the specification. If a `.db` file differs by one byte, it
   is a bug in the Pascal port, never an improvement.

2. **Port line-by-line.** Resist refactoring while porting. Refactor in a
   separate pass, after on-disk parity is proven.

3. **Every phase ends with a test that passes.** Do not advance to the next
   phase until the gating test (1.6, 2.10, 3.A.5, 3.B.4, 4.6, 5.10, 6.9, 7.4, 9.1–9.4)
   is green.

4. **Work sequentially within each phase.** Ordering is deliberate. Phase 3
   gates Phase 4 which gates Phase 5 which gates Phase 6.

5. **`libsqlite3.so` is the oracle, not a dependency.** The Pascal library
   does not link against it. Only the test binaries do, to compare outputs.

6. **No Pascal `Boolean` inside this port.** Use `Int32` or `u8`.

7. **Commit per function or per task.** Small commits with clear messages make
   bisecting an on-disk parity regression tractable.

8. **A faithful port is a multi-year effort.** The existing FPC bindings
   (`sqlite3dyn`, `sqlite3conn`) cover 99% of what most users need. This port
   is a learning and hardening exercise — scope accordingly.

---

## Architectural notes and known pitfalls

1. **No Pascal `Boolean`.** SQLite uses `int` or `u8` for flags. Pascal's
   `Boolean` is 1 byte but its canonical `True` is 255 on x86 — incompatible
   with C's `1`. Always use `Int32` or `u8` with explicit `0`/`1` literals.

2. **Overflow wrap is required.** Varint codec, hash functions, CRC, random
   number generation — all rely on unsigned 32-bit wrap. Keep `{$Q-}` and
   `{$R-}` on project-wide.

3. **Pointer arithmetic is everywhere.** Every page, cell, record, and varint
   is navigated via `u8*`. `{$POINTERMATH ON}` is required. `*p++` becomes
   `tmp := p^; Inc(p);`.

4. **UTF-8 vs UTF-16.** SQLite supports both internally. The encoding is a
   per-column property (text affinity) and a per-connection setting
   (`PRAGMA encoding`). Port the full encoding machinery; do not shortcut to
   UTF-8-only.

5. **Float formatting differs.** `printf("%g", x)` and FPC's `FloatToStr` can
   produce different strings for the same double (e.g. `1e-5` vs `0.00001`).
   Port SQLite's own `sqlite3_snprintf` (Phase 2.3) and use it; never use
   FPC's `Format`.

6. **Endianness.** SQLite stores multi-byte integers on disk in big-endian.
   FPC on x86_64 is little-endian. The varint codec handles this, but any
   direct cast `PInt32(p)^` is a portability bug on a big-endian target.
   Always go through the helpers.

7. **`longjmp` / `setjmp` absence.** SQLite does not use them. Good.

8. **Function pointers need `cdecl`.** The `sqlite3_vfs`, `sqlite3_io_methods`,
   `sqlite3_module` (virtual tables), and application-registered
   `sqlite3_create_function` / `sqlite3_create_collation` callbacks all need
   `cdecl` on their Pascal procedural types, so a C user of the port (if we
   ever ship one) can pass a C callback.

9. **`.db` header mtime.** Bytes 24–27 of the SQLite database file are a
   "change counter" updated on every write. Two binary-identical DBs from
   independent runs can differ in this field. The diff harness must
   normalise these bytes before comparing, OR (better) both runs must perform
   exactly the same number of writes, in which case the counters will match.

10. **Schema-cookie mismatch will cascade.** Bytes 40–59 of the header (the
    "schema cookie", "user version", "application ID", "text encoding", etc.)
    must be written in exactly the same order and with the same default values
    on connection open. A one-byte diff here invalidates every subsequent
    parity check.

11. **`sqlite3_randomness()` determinism.** Many corpora rely on random values
    (ROWID assignment, temp table names). The oracle must seed both the
    Pascal and C PRNGs identically for differential output to match.

12. **Algorithmic determinism is load-bearing.** Query-plan choice depends on
    `ANALYZE` statistics and on tie-breaking constants in `where.c`. If those
    constants differ by even 1%, the planner can pick a different index and
    every downstream EXPLAIN diff fails even though the result sets are
    correct. **Port the constants exactly.**

13. **Large records must be heap-allocated.** `sqlite3` (the connection),
    `Vdbe`, `Pager`, and `BtShared` are multi-KB records. Never stack-allocate.

14. **Thread safety.** Default SQLite build is serialized (full mutex).
    The Pascal port inherits the same model — every API entry point acquires
    the connection mutex. Do not try to port `SQLITE_THREADSAFE=0` first "for
    simplicity"; it changes too many code paths.

15. **`SizeOf` shadowed by same-named pointer local (Pascal case-insensitivity).**
    If a function has `var pGroup: PPGroup`, then `SizeOf(PGroup)` inside that
    function returns `SizeOf(PPGroup) = 8` (pointer) instead of the record size.
    Pascal is case-insensitive; the identifier lookup finds the local variable
    first. **Rule**: local pointer variables must NOT share their name with any
    type. Convention: use `pGrp`, `pTmp`, `pHdr`, never exactly `PPGroup → PGroup`.
    After porting any function, grep for `SizeOf(P` and verify the named type has
    no same-named local in scope.

16. **Unsigned for-loop underflow.** `for i := 0 to N - 1` is safe only when N > 0.
    When `i` or `N` is `u32` and `N = 0`, `N - 1 = $FFFFFFFF` → 4 billion
    iterations → instant crash. In C, `for(i=0; i<N; i++)` skips cleanly.
    **Rule**: always guard with `if N > 0 then` before such a loop, or rewrite
    as `i := 0; while i < N do begin ... Inc(i); end`.
