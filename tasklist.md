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
  - [ ] **6.28.4** Complete `sqlite3AddColumn` drift arms — audit verdict (6.28.8): DRIFTED-S (~25 lines C).  Body at passqlite3codegen.pas:37284 is largely 1:1; missing arms: (a) build.c:1507 `if(!IN_RENAME_OBJECT) sqlite3DequoteToken(&sName)` pre-allocation dequote; (b) build.c:1513..1524 GENERATED-ALWAYS trailing-text strip; (c) build.c:1530 `sqlite3DequoteToken(&sType)` inside standard-typename check.  No STRICT work to do here — STRICT enforcement lives downstream in sqlite3EndTable (original inventory cite to build.c:1862..2026 was wrong).  Complexity: S.
  - [X] **6.28.5** Port `sqlite3LimitWhere` view-rewrite arm — audit verdict (6.28.8): stub-was-real.  Body at passqlite3codegen.pas:31123..31217 is a 1:1 port of delete.c:182..277 (rowid arm, single-PK arm, vector-PK arm, isIndexedBy/isCte FROM-dup, TK_IN wrap).  C has NO useTempRow / view-rewrite arm in this helper (original inventory "two unported arms" was wrong).  Pending work is caller-side wiring in sqlite3DeleteFrom (codegen.pas:31338 TODO) and sqlite3Update (codegen.pas:32419 TODO) — annotated as separate Phase-6.x slices, not part of this helper.  Stale "no-op stub" comments scrubbed.  STUB_INVENTORY #5 closed.
  - [X] **6.28.6** Port `OP_IntegrityCk` body — audit verdict (6.28.8): stub-was-real.  OP_IntegrityCk arm at passqlite3vdbe.pas:10715..10748 and sqlite3BtreeIntegrityCheck driver at passqlite3btree.pas:7916..8043 are both real 1:1 ports (freelist + auto-vacuum cross-check + checkTreePage walk + page-coverage map + SQLITE_DYNAMIC error string).  Remaining gap is driver-side: `PRAGMA integrity_check` in codegen.pas:45844 still emits hardcoded "ok" instead of building an OP_IntegrityCk plan — that pragma-wiring slice is **not** "port OP_IntegrityCk" and is filed as a follow-up bullet below.  Stale "OP_IntegrityCk is a stub" comment scrubbed.  STUB_INVENTORY #6 closed.
  - [ ] **6.28.6.a** Wire `PRAGMA integrity_check / quick_check` to emit OP_IntegrityCk — codegen.pas:45844 currently emits literal "ok" rather than building the root-page array and OP_IntegrityCk plan (pragma.c:1695 reference).  Complexity: M (~120 lines C — root-page enumeration across all attached schemas, P4_INTARRAY allocation, OP_ResultRow loop on aMem[p1+1]).
  - [X] **6.28.7** Wire `getRowTrigger` mask helper — audit verdict: stub-was-real. `trgGetRowTrigger` (passqlite3codegen.pas:30884) + `codeRowTrigger` (:30709) are 1:1 with trigger.c:1347 / 1231; aColmask[0/1] populated from sub-Parse oldmask/newmask; `sqlite3TriggerColmask` picks up real per-column bits for ordinary triggers. Stale "not yet ported" comments scrubbed; STUB_INVENTORY #7 closed.
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

- [ ] **9.1.2** Oracle runner helper.  `src/tests/CorpusOracle.pas`:
  given a `.sql` path and an empty workdir, runs the C reference via
  `libsqlite3.so` (in-process, not the `sqlite3` shell — avoid Phase
  10 dependency) and captures `(stdout, stderr, rc, db-blob)`.
  Wire the same plumbing for the Pascal port via passqlite3.

- [ ] **9.1.3** `TestSQLCorpus.pas` skeleton.  Iterate MANIFEST, run
  both oracles, byte-compare all four channels.  First diverging file
  prints a one-screen summary (file, channel, first 16-byte window)
  and exits non-zero.  Gate: `bin/TestSQLCorpus` rc=0.

- [ ] **9.1.4** Determinism scrub.  Strip the known non-deterministic
  fields (file-change-counter at offset 24, version-valid-for at 92,
  in-header text encoding when unset, freelist trunk order under
  identical workloads — verify each before stripping).  Document
  every masked byte range in `src/tests/corpus/MASK.md` with the C
  source citation that justifies the mask.

- [ ] **9.1.5** Tag corpus categories by status: `pas-strict`
  (byte-identical), `pas-soft` (output identical, db differs in
  documented mask), `pas-skip` (gated on an open Phase 6/7/8 bullet —
  must cite the bullet).  Strict tag is the CI gate; soft/skip are
  tracked but non-blocking.

- [ ] **9.1.6** Coverage check.  Re-run with `--coverage` against the
  port's opcode dispatcher; assert every executed opcode in
  `passqlite3vdbe.pas` is hit at least once.  Any cold opcode means
  the corpus has a gap — add a targeted `.sql`.

### 9.2 `TestReferenceVectors.pas` — canonical `.db` snapshots

- [ ] **9.2.1** Vector inventory.  `src/tests/vectors/` currently
  holds `simple.db` + `multipage.db`.  Add: `wal.db` (journal_mode
  WAL mid-checkpoint), `autovacuum.db`, `incrvacuum.db`, `fts5.db`,
  `rtree.db` (skip-tagged until extension ports land), `utf16.db`,
  `withoutrowid.db`, `generated-column.db`, `triggers.db`,
  `view-cte.db`, `partial-index.db`.  Each one generated by a
  scripted `.sql` checked in next to it so the blob is reproducible.

- [ ] **9.2.2** Read-only parity probe.  For each `*.db`, run a fixed
  query script (`*.queries.sql`) under both oracles, diff stdout +
  rc.  No writes — this gate is about read-side compatibility with
  files the port did not author.

- [ ] **9.2.3** Round-trip probe.  Open vector, run a fixed mutator
  script (`*.mutate.sql`: a handful of INSERT/UPDATE/DELETE inside
  a single txn), close, byte-diff the resulting blob against the C
  oracle's output.  Skip vectors flagged `read-only` in the
  manifest.

- [ ] **9.2.4** Schema-change probe.  Subset where ALTER / CREATE
  INDEX / VACUUM is exercised.  Validates Phase 6 OP_ParseSchema +
  AddColumn paths (see memory entries) under non-synthetic schemas.

- [ ] **9.2.5** Vector regen script.  `src/tests/vectors/regen.sh`
  rebuilds every `.db` from its companion `.sql` using the C
  reference.  Committed blobs are derived artefacts; running the
  script must produce a byte-identical tree.

### 9.3 `TestFuzzDiff.pas` — differential fuzzer

- [ ] **9.3.1** In-process harness.  `TestFuzzDiff.pas` reads a single
  `dbsqlfuzz`-format input (db prefix + SQL tail per upstream
  `test/fuzzcheck.c`), runs it under both oracles in isolated
  workdirs, byte-diffs all output channels.  No AFL yet — just the
  one-shot driver that AFL will later call.

- [ ] **9.3.2** Seed corpus import.  Pull the upstream `dbsqlfuzz`
  seed set from `../sqlite3/test/fuzzdata*.db` into
  `src/tests/fuzz/seeds/`.  Run the one-shot driver across every
  seed; any divergence under the seed set is a Phase 6/7 bullet
  (file it before continuing).

- [ ] **9.3.3** AFL wiring.  `src/tests/fuzz/afl-driver.pas` wraps
  9.3.1 for `afl-fuzz` (read input from stdin, write to a tmp file,
  invoke the in-process harness, return AFL-compatible exit codes).
  Document the `AFL_LLVM_INSTRUMENT` / persistent-mode build line.
  Skip if AFL isn't installed — script must self-report.

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
  `src/tclsqlite.c` (Phase 8 dependency) needed so the upstream
  `interp` can attach to passqlite3 via the same `sqlite3` Tcl
  command.  Internal helpers (`db_eval_one_with_callback`) port as
  thin wrappers; the public `sqlite3 db1 :memory:` command is
  enough for ~80% of `tcl-feature`.

- [ ] **9.4.3** Driver `src/tests/TclTestDriver.pas`.  Spawns
  `tclsh` against each manifest entry with the port's shim
  preloaded; collects pass/fail/skip per test; the gate is "every
  `tcl-feature` test exits 0 or matches the upstream skip list".

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
  - [ ] **10.1.39.d** NCYCLE / hwtime sampling — deferred until a real consumer
    appears; gated on `SQLITE_ENABLE_STMT_SCANSTATUS=2` equivalent and TVdbeOp
    gaining an `nCycle` field.  Not blocking 10.1.39 closure.  Doable subtasks:
    - [ ] **10.1.39.d.1** Add `nCycle: u64` field to TVdbeOp; verify all
      TVdbeOp allocators / FillChar paths zero-init it (cross-check vdbe.c
      around `pOp->nCycle` references).
    - [ ] **10.1.39.d.2** Port `sqlite3Hwtime()` from `../sqlite3/src/hwtime.h`
      (rdtsc on x86_64; PMCCNTR on aarch64 with fallback to monotonic clock).
      Pascal location: passqlite3os.pas alongside the existing time helpers.
    - [ ] **10.1.39.d.3** Bracket the dispatch loop in passqlite3vdbe.pas:7618
      with `t0:=sqlite3Hwtime(); … pOp^.nCycle += sqlite3Hwtime()-t0;` under
      `{$IFDEF SQLITE_ENABLE_STMT_SCANSTATUS}` (default-off — adds non-zero
      per-op overhead in non-debug builds otherwise).
    - [ ] **10.1.39.d.4** Wire SCANSTAT_NCYCLE reader arm in
      passqlite3main.pas:3860 to sum `aOp[addrLoop..addrLoop+nOp].nCycle`
      (matches vdbeapi.c:2530 NCYCLE arm).
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
    - [ ] **10.1.42.a.4** ORDER BY / window-rewrite / DISTINCT→GROUP BY
      TREETRACE arms (mask 0x1000 / 0x8000): `dropping ORDER BY`,
      `window rewrite`, `DISTINCT->GROUP BY`.
    - [ ] **10.1.42.a.5** Outer-join simplification + FROM-subquery
      TREETRACE arms: FULL/LEFT/RIGHT-JOIN simplifies, omit
      FROM-subquery ORDER BY, WHERE push-down, all-FROM analysis,
      Finished-with-AggInfo trailing print.
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
    - [ ] **10.1.42.b.4** Query-planner solver progress WHERETRACE in
      `wherePathSolver` (mask 0x80): `optimizer search-limit`,
      per-iteration path costs.
    - [ ] **10.1.42.b.5** OR-vs-AND / pseudo-index decision WHERETRACE
      in `whereLoopAddOr` (mask 0x400 deeper arms): cost compares,
      pseudo-index selection.
    - [ ] **10.1.42.b.6** DISTINCT reduction + optimizer-finished
      trailing WHERETRACE in `sqlite3WhereBegin` epilogue (mask 0x1):
      `Optimizer Finished` summary line.
    - [ ] **10.1.42.b.7** Port the STAT4 cost-estimator helpers that
      gate the 4 deferred 10.1.42.b.1 arms: `whereRangeSkipScanEst`
      (where.c:2036), `whereEqualScanEst` (:2215 / :2313),
      `whereInScanEst` (:2363).  Each is a STAT4-driven planner helper
      not yet present in passqlite3codegen.pas.  Mask: 0x20 (verified
      against whereInt.h, NOT 0x10 as tasklist initially suggested).
      Treat as 3 independent micro-tasks; drop the WHERETRACE call at
      each host function as it lands.
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
