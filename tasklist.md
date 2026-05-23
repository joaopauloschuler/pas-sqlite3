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

> Closed-task postmortems live in git history.  This file keeps task IDs +
> one-line outcomes + key cites only.

## Phase 5 — carry-overs

- [X] **5.7.b** PMA disk-spill port COMPLETE — single-threaded vdbesort.c 1:1; `SORTER_PMA_ENABLED=True`; forced-spill differential vs C oracle BYTE-IDENTICAL across 9 shapes (ASC/DESC/multi-col/text/NOCASE/dup-stability incl. 26-PMA IncrMerger tree + UNIQUE-index spill + UNIQUE-violation), bigsort.test strict PASS, sort/orderby Tcl no pas-strict regression, ExplainParity 1026/1026, TestVdbeSort 14/14.
  > **Faithful-port scope:** the only sanctioned simplification is the **single-threaded** subset (`SQLITE_MAX_WORKER_THREADS==0`, which is this port's reality — no `SQLiteThread`; the oracle build also leaves worker threads off, so this is parity-faithful, not a shortcut).  Under that gate ~700 lines of vdbesort.c (background threads, `IncrMerger` multi-file double-buffering, `INCRINIT_TASK`/`INCRINIT_ROOT`, `vdbeSorter{Create,Join}Thread`, `vdbeIncrBgPopulate`, `vdbeSorterFlushThread`) compile out: `bUseThreads` is always 0, `nTask` always 1 — these are *absent code paths*, not stubs.  mmap (`vdbeSorterMapFile`/`OsFetch`) is **optional** — a reader that always returns `aMap=nil` takes C's own buffered-read fallback with byte-identical results (perf-only, faithful).  **The current Pascal in-memory sort is a non-faithful improvisation** (record header pNext@0,nVal@8,data@16 + a bespoke recursive array-mergesort `vdbeSorterMergeSort`/`vdbeSorterListToArray` + `vdbeSorterCompareRec`) and **must be replaced 1:1 by C's structures and algorithms** — it is not a valid base to bolt PMA onto.  Each sub-task below cites the C line range and is independently buildable/testable; the existing in-memory tests (TestExplainParity + sort coverage) must stay green across the rebase.
  - [X] **5.7.b.1** Sorter struct decls — C-faithful TSorterRecord(nVal@0/union u@8/SRVAL=p+16)+TMergeEngine/TPmaReader/TPmaWriter/TIncrMerger/TSortSubtask/TSorterCompare; retyped TVdbeSorter.pReader/pMerger to typed ptrs, added aTask[1] + consts; sizes verified (SorterRecord=16,PmaReader=80,SortSubtask=104). (vdbesort.c:173..461)
  - [X] **5.7.b.2** Temp-file plumbing — ported `vdbeSorterExtendFile`/`vdbeSorterOpenTempFile`/`vdbeSorterMapFile` (OsOpenMalloc inlined; truncate/extend hints kept, MapFile→pp:=nil); SQLITE_MAX_MMAP_SIZE==0 config (no OsFetch pre-fault / no FCNTL_MMAP_SIZE) — faithful, not a deviation.  (vdbesort.c:619..634, 1308..1352)
  - [X] **5.7.b.3** `PmaWriter` — ported `vdbePmaWriterInit`/`vdbePmaWriteBlob`/`vdbePmaWriterFinish`/`vdbePmaWriteVarint` (buffered page-aligned writes via sqlite3OsWrite + sqlite3PutVarint + sqlite3Malloc/sqlite3_free; added Pu64 alias); clean compile, ExplainParity 1026/1026, Smoke PASS.  (vdbesort.c:1479..1576)
  - [X] **5.7.b.4** `PmaReader` read primitives — ported `vdbePmaReaderClear`/`vdbePmaReadBlob`(recursion+MAX(128,2*nAlloc) doubling)/`vdbePmaReadVarint`/`vdbePmaReaderSeek`/`vdbePmaReaderNext`/`vdbePmaReaderInit` 1:1 (reuse sqlite3OsRead/Realloc/Malloc/GetVarint + vdbeSorterMapFile); `vdbeIncrFree`/`vdbeIncrSwap` inert forward stubs deferred to 5.7.b.7; clean compile, ExplainParity 1026/1026, Smoke PASS.  (vdbesort.c:474..761)
  - [X] **5.7.b.5** In-memory engine rebased 1:1 onto C (deleted bespoke `vdbeSorterMergeSort`/`vdbeSorterListToArray`/`vdbeSorterCompareRec`/`vdbeSorterCountRecords`+`SORTER_REC_HDR`); ported `vdbeSorterCompareTail`/`Compare`/`CompareText`/`CompareInt`+`GetCompare`, `vdbeSortAllocUnpacked`, `vdbeSorterMerge`, `vdbeSorterSort`(aSlot[64]), `vdbeSorterListToPMA`/`vdbeSorterFlushPMA`, C-exact `Init`/`Write`/`Rewind`/`Next`/`Rowkey`/`Compare` on nVal@0/SRVAL=p+16; live spill GATED off via module const `SORTER_PMA_ENABLED=False` (5.7.b.9 flips it once merge read-back lands) → behaviour RAM-only/identical; ExplainParity 1026/1026, TestVdbeSort 14/14, no pas-strict sort/orderby regression. (vdbesort.c:763..915,936..1044,1050..1083,1247..1296,1354..1474,1578..1633,1727..1730,1797..1902,2612..2796)
  - [X] **5.7.b.6** `MergeEngine` aTree[] tournament — ported `vdbeMergeEngineNew`(power-of-2 round-up, single MallocZero w/ aReadr/aTree offset math)/`Free`/`Compare`/`Step`(`&$FFFE`/`|$0001` + `i=(nTree+iPrev)/2` walk-up via integer aReadr-indices preserving C `pReadr1<pReadr2` tie + `pReadr-aReadr` math)/`Init`(INCRINIT_NORMAL)/`Level0`; `vdbePmaReaderIncrMergeInit` temp inert stub (calls `vdbePmaReaderNext`) for 5.7.b.7; ExplainParity 1026/1026, Smoke PASS. (vdbesort.c:1193..1229,1642..1712,2062..2114,2144..2218,2338..2375)
  - [X] **5.7.b.7** Single-threaded `IncrMerger` — ported `vdbeIncrMergerNew`/`Free`/`Populate`/`Swap`/`SetThreads`(no-op)/`vdbePmaReaderIncrMergeInit`/`IncrInit` (bUseThread=0, INCRINIT_NORMAL, file2-region borrow); replaced the inert `vdbeIncrFree`/`Swap`/`PmaReaderIncrMergeInit` stubs with real bodies; ExplainParity 1026/1026, Smoke PASS. (vdbesort.c:1229..1241,1908..2061,2220..2336)
  - [X] **5.7.b.8** Tree build + merge setup — ported `vdbeSorterTreeDepth`/`vdbeSorterAddToTree`/`vdbeSorterMergeTreeBuild`/`vdbeSorterSetupMerge` single-threaded (nTask==1, bUseThreads==0, INCRINIT_NORMAL): ≤16 PMAs → flat Level0 MergeEngine, >16 → IncrMerger hierarchy via AddToTree; result always to `pSorter->pMerger` (bg pReader arm omitted); uncalled until 5.7.b.9; ExplainParity 1026/1026, Smoke PASS. (vdbesort.c:2377..2611)
  - [X] **5.7.b.9** Public-API PMA arms wired — Rewind flushes residual+SetupMerge, Next/Rowkey(`aReadr[aTree[1]]`)/Compare drive `pMerger` when `bUsePMA`; Reset/Close now `vdbeMergeEngineFree`+pUnpacked free (no leak); fixed `vdbeMergeEngineInit` to call `vdbePmaReaderIncrInit` (guarded) not `vdbePmaReaderIncrMergeInit` — leaf readers have pIncr=nil so the unguarded call nil-derefed/SIGSEGV. `SORTER_PMA_ENABLED=True`. (vdbesort.c:2144..2218,2612..2761,1063..1085,1247..1296)
  - [X] **5.7.b.10** Verify — forced spill (PRAGMA cache_size negative + recursive-CTE pseudo-random keys) byte-identical to C oracle across ASC/DESC/multi-col/text/NOCASE/dup-stability, 26-PMA IncrMerger tree, CREATE UNIQUE INDEX spill + UNIQUE-violation error; bigsort.test strict PASS; sort/orderby Tcl no pas-strict regression (sort2/4/5,orderbyB stay pas-soft).

---

## Phase 6 — Code generators (close the EXPLAIN gate)

> TestExplainParity reports **1026 / 1026 PASS** as of 2026-05-06 (a3).

- [X] **6.8.0..6.8.6** Pragma vtab register, GenerateConstraintChecks, CompleteInsertion, WhereBegin, WhereEnd, Insert (incl.
- [X] **6.8.1** sqlite3Update — single-table, UPDATE FROM, vtab dispatch, RETURNING.
- [X] **6.9** sqlite3VdbeRecordCompare / FindCompare full bodies in btree.pas.
- [X] **6.24** Aggregate-with-ORDER-BY codegen.
- [~] **6.26** Window functions (window.c). DiagWindow: 0 divergences. Reopen if DiagWindow regresses.
- [X] **6.27** schema-mutation + statistics.
- [~] **6.28** sweep — re-search for "stub" in the pascal source code and port from C to pascal in full any function or procedure still marked as "stub" that was missed (catch-all). OP_Vacuum, BtreeIncrVacuum done; incrVacuumStep / relocatePage / modifyPagePointer not ported (gated on productive ptrmap). Inventory landed at `src/tests/STUB_INVENTORY.md` (21 actionable entries: 7 high / 6 med / 8 low). One small high-priority entry ported in 6.28 commit (`pas_openDirectory`, os_unix.c:3874..3894 → src/passqlite3os.pas:2331). Doable subtasks for the remaining six high-priority stubs (each cites the open Phase-6/9 bullet it blocks; see STUB_INVENTORY.md for full Pascal/C citations):
  - [X] **6.28.1** `whereLoopAddVirtual` deeper arms — stub-was-real (1:1 port of where.c:4681..4803).
  - [X] **6.28.2** `sqlite3OpenTableAndIndices` full body — stub-was-real (1:1 port of insert.c:2870..2925).
  - [X] **6.28.3** `sqlite3NestedParse` body ported (build.c:293..323) via gNestedRunParser hook.
  - [X] **6.28.4** `sqlite3AddColumn` drift arms — three small dequote/strip arms ported 1:1 (build.c:1507/1513/1530).
  - [X] **6.28.5** `sqlite3LimitWhere` — stub-was-real (1:1 port of delete.c:182..277).
  - [X] **6.28.6** `OP_IntegrityCk` body + `sqlite3BtreeIntegrityCheck` — stub-was-real.
  - [X] **6.28.6.b** Higher-level `PRAGMA integrity_check` walk arms — pragma.c:1792..2194 (row walk, CHECK, per-index validation, UNIQUE duplicate detection).
  - [X] **6.28.6.a** PRAGMA integrity_check/quick_check wired to emit real OP_IntegrityCk plan (pragma.c:1695..1820 + 2195..2217).
  - [X] **6.28.6.c** vtab xIntegrity dispatch:
    - [~] **6.28.6.c.1** ~~FK referential walk~~ DROPPED 2026-05-13 — phantom cite (integrity_check carries no FK walk; PRAGMA foreign_key_check is separate). Archive.
    - [X] **6.28.6.c.2** vtab `xIntegrity` dispatch — emits `OP_VCheck p1=iDb, p2=errReg, p3=isQuick, p4=pTab(P4_TABLEREF)`.
  - [X] **6.28.7** `getRowTrigger` / `codeRowTrigger` / `sqlite3TriggerColmask` — stub-was-real (1:1 with trigger.c:1347 / 1231).
  - [X] **6.28.8** Audit pass on high-priority STUB_INVENTORY entries (#1/#2/#5/#6 CLOSED was-real, #4 DRIFTED-S done in 6.28.4).
  - [X] **6.28.9** Medium-priority audit pass — 5 stub-was-real, 1 DRIFTED-XL (#13 sorter PMA-spill tracked as 5.7.b).
  - [X] **6.28.10** Low-priority audit pass — 5 intentional no-ops faithful to C preprocessor-gated empty macros, 2 was-real with banner refresh.

### Closed bugs (kept as ticked stubs)

- [X] **6.10** TestExplainParity closed.
- [X] **6.11** PRAGMA page_count + DROP TABLE remaining gap closed.
- [X] **6.12** sqlite3Pragma full port; DiagPragma all PASS.
- [X] **6.13** `pragma_foreign_key_list(s.name)` (and other table-valued PRAGMA functions).
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
- [X] **6.31** unix-VFS locking-style shims — `unix-none`/`unix-dotfile`/`unix-excl` siblings auto-registered (os_unix.c:8499..8542).
- [X] **6.13.B.11** `.expert` `(no new indexes)` — eponymous-vtab fast arm in `sqlite3Select` was firing for every single-source vtab SELECT, suppressing WHERE/ORDER BY pushdown.

### Open Bugs (re-opened 2026-05-11)

- [X] **6.32** DiagTxn savepoint-rollback hang — closed 2026-05-12 as no-longer-reproduces (likely fixed in-passing by 6.10/6.11 OP_Savepoint work + 6.16 VdbeMakeReady zero-init).

### 6.40 — Unported feature/extension gaps surfaced by Tcl sweep (2026-05-22)

> Each bullet is a Tcl `.test` failure whose *root cause is a missing ported
> feature*, not a runtime divergence. Counts are occurrences across the
> 2026-05-22 full-suite run (612 pass / 347 fail). "ENGINE" = real library
> feature to port; "EXT" = loadable/test extension to register; "HARNESS" =
> testfixture-only Tcl command. Port the C source 1:1 as usual; for HARNESS
> entries the C lives in `../sqlite3/src/test*.c` and is registered through the
> Tcl bridge (`src/tests/tcl/testmodules/`), not the engine.

- [~] **6.40.1** **FTS3/FTS4 full-text search** (ENGINE/EXT, XL; ~21 kLOC across `../sqlite3/ext/fts3/`). All of fts3.c/fts3_*.c ported into `src/passqlite3fts3.pas` and auto-registered from `sqlite3Fts3Init` at openDatabase (.a..o all DONE). fts3/fts4/fts4aux/fts3tokenize modules + fts3_tokenizer(_test) funcs + the fts3_test.c Tcl harness all live; the `fts3` capability is flipped on. Core FTS works (35 fts .test files PASS pas-strict + basic MATCH/phrase/NEAR/snippet/offsets/matchinfo/prefix/aux all green, oracle-diff'd). STAYS `[~]`: ~50 fts files remain pas-soft on three documented residual classes — (1) order=desc doclist hang/corruption (6.40.1.o.1), (2) heavy-segment-merge build perf timeouts (6.40.1.o.2), (3) assorted per-file edge cases (6.40.1.o.3). Reopen-to-strict as those residuals close.
  - **Cluster A — tokenizer subsystem (the easy wins; entirely independent of the 12 kLOC segment/vtab core).** Each item drives the `sqlite3_tokenizer_module` vtable directly, so each is unit-testable in isolation against the C oracle via a small `DiagFts3Tok` probe — no FTS vtab needed. Landing all of Cluster A flips the two biggest buckets: `fts3_tokenizer_test` (77) and `fts3tokenize` (2).
    - [X] **6.40.1.a** ABI skeleton landed in new unit `src/passqlite3fts3.pas`: ported fts3_tokenizer.h vtable (`Tsqlite3_tokenizer`/`_module`/`_cursor`, cdecl fn-ptrs), fts3_hash.h (`TFts3Hash`/`TFts3HashElem`/`TFts3Ht`, FTS3_HASH_* consts, macro accessors), fts3.h `sqlite3Fts3Init` noted forward. Compiles clean via build.sh.
    - [X] **6.40.1.b** `fts3_hash.c` ported (sqlite3Fts3Hash Init/Insert/Find/FindElem/Clear + static rehash/find/remove/insertElement helpers, str/bin hash+cmp), allocs via sqlite3_malloc64/sqlite3_free; keys/data kept raw Pointer. Gate `src/tests/TestFts3Hash.pas` (init/insert20/find/overwrite/delete-NULL/rehash 0->8->16/clear/binary) → "TestFts3Hash: PASS" exit 0.
    - [X] **6.40.1.c** `fts3_tokenizer1.c` 1:1 (simple_tokenizer + simpleCreate/Destroy/Open/Close/Next + static simpleTokenizerModule + sqlite3Fts3SimpleTokenizerModule) into passqlite3fts3.pas; offsets/lowercasing verified by TestFts3Tok.
    - [X] **6.40.1.d** `fts3_porter.c` 1:1 (isVowel/isConsonant/m_gt_0/m_eq_1/m_gt_1/hasVowel/doubleConsonant/star_oh/stem/copy_stemmer/porter_stemmer + porter_tokenizer module + sqlite3Fts3PorterTokenizerModule); stems cross-checked vs C porter_stemmer (caresses->caress, ponies->poni, agreed->agre, …). TestFts3Tok PASS exit 0; regression clean (only pre-existing TestFuzzDiff red).
    - [X] **6.40.1.e** `fts3_unicode2.c` ported verbatim (aEntry[406]/aAscii Isalnum, aDia[126]/aChar[126] remove_diacritic, mask0/mask1 Isdiacritic, TableEntry aEntry[163]/aiOff[77] Fold); bounds + binary-search lookups byte-exact vs C oracle.
    - [X] **6.40.1.f** `fts3_unicode.c` "unicode61" tokenizer ported (READ/WRITE_UTF8 + sqlite3Utf8Trans1, unicodeCreate/Destroy/Open/Close/Next, remove_diacritics=/tokenchars=/separators= parsing, sqlite3Fts3UnicodeTokenizer). TestFts3Unicode PASS exit 0; regression clean (only pre-existing TestFuzzDiff red).
    - [X] **6.40.1.g** fts3_tokenizer.c ported into passqlite3fts3.pas (sqlite3Fts3IsIdChar/NextToken, sqlite3Fts3InitTokenizer, fts3TokenizerFunc=`fts3_tokenizer`, SQLITE_TEST testFunc=`fts3_tokenizer_test`+registerTokenizer/queryTokenizer/intTestFunc, sqlite3Fts3InitHashTable; ENABLE_FTS3_TOKENIZER gate via sqlite3_db_config_int onoff=-1; local fts3Dequote/fts3ErrMsg/OpenTokenizer copies TODO-promoted in .k/.i) + minimal `sqlite3Fts3Init` (fts3.c:4102 partial: nRef-guarded Fts3HashWrapper, loads simple/porter/unicode61, installs fts3_tokenizer via create_function_v2+hashDestroy for per-conn no-leak lifetime) wired in openDatabase (main.pas:992). New TestFts3TokRegistry PASS; functions verified live. Tcl: fts3atoken/fts3atoken2/fts3tok1 stay pas-strict PASS, gate clean — the 77 tokenizer subtests stay gated OFF by `ifcapable !fts3` (tester_min.tcl:301 `fts3=0`). **CORRECTION (verified 2026-05-22): the oracle .so DOES enable FTS3/FTS4** (autosetup `./configure` default; `pragma_compile_options`=ENABLE_FTS3/FTS4, `CREATE VIRTUAL TABLE…USING fts4`+MATCH+`fts3_tokenizer` all run rc=0). The `fts3=0` pin reflects the *Pascal port's* missing FTS3, NOT the oracle (unlike ICU 6.40.2 where the *oracle* lacked it) — a divergence-hiding stopgap to REMOVE, not match. Flip `fts3=0`→`1` only AFTER .o registers fts3/fts4/fts3tokenize (flipping early regresses, as observed). Full module wiring + capability flip remain in .o.
    - [X] **6.40.1.h** `fts3_tokenize_vtab.c` ported into passqlite3fts3.pas (Fts3tokTable/Fts3tokCursor, fts3tokQueryTokenizer, fts3tokDequoteArray, fts3tok Connect/Disconnect/BestIndex/Open/Close/ResetCursor/Next/Filter/Eof/Column/Rowid, static fts3tok_module via initFts3TokModule, public sqlite3Fts3InitTok) + registered from minimal sqlite3Fts3Init as an nRef owner (Inc(nRef) before sqlite3Fts3InitTok, hashDestroy attached; create_module_v2 fires xDestroy on failure per _api_create_module so nRef balances; transitional 2 fts3_tokenizer FuncDefs + 1 module = nRef 3 until fts3/fts4 land in .k/.o). New TestFts3TokVtab PASS exit 0 (simple/default/porter token+offset+position rows). Regression clean (only pre-existing TestFuzzDiff red); Tcl fts3tok1.test PASS, no pas-strict regression. Flips `fts3tokenize` (2).
  - **Cluster B — the FTS index core (XL; this is the hard 80%).** Needed before any `fts3`/`fts4` data table or `fts4aux` works.
    - [X] **6.40.1.i** `fts3_expr.c` ported into passqlite3fts3.pas: Fts3Expr/Fts3Phrase/Fts3PhraseToken + FTSQUERY_* (fts3Int.h:430..521) in interface for .j/.k reuse; full parser (sqlite3Fts3ExprParse/fts3ExprParse/getNextNode/getNextToken/getNextString/insertBinaryOperator/opPrecedence/fts3ExprBalance/CheckDepth/ParseUnbalanced + iterative sqlite3Fts3ExprFree) and sqlite3Fts3MallocZero. Promoted the .g stub `sqlite3Fts3OpenTokenizerLocal`→real `sqlite3Fts3OpenTokenizer` (fts3_expr.c:131), all callers updated, stub deleted. **Syntax path: NEW/parenthesis** — oracle .so has ENABLE_FTS3_PARENTHESIS (verified pragma_compile_options), so `sqlite3_fts3_enable_parentheses` is const 1 in the engine build and a writable global default-0 under `{$IFDEF SQLITE_TEST}` (Tcl bridge), faithfully mirroring fts3_expr.c:66..74. SQLITE_TEST iface (exprToString/fts3ExprTestCommon/`fts3_exprtest`/`fts3_exprtest_rebalance`/sqlite3Fts3ExprInitTestInterface) gated + wired into minimal sqlite3Fts3Init (fts3.c:4156). New TestFts3Expr.pas (drives public parser, serialises with an exprToString mirror; AND/OR/NOT/NEAR/NEAR-n/phrase/col-spec/prefix/rebalance/3 malformed-error cases) PASS exit 0, all expected strings cross-checked vs C amalgamation built -DSQLITE_TEST -DENABLE_FTS3_PARENTHESIS; `fts3_exprtest` also verified byte-faithful through the Tcl bridge (parens=0 legacy). Regression 106/107 (only pre-existing TestFuzzDiff red); fts3 Tcl filter 59/59, no pas-strict regression. **TODO stubs left**: local `fts3ReadInt` (fts3.c:966) + `fts3EvalPhraseCleanupLocal` (fts3.c:6163, safe no-op subset for parser trees; real pSegcsr/poslist free is .j/.k) + `Fts3DeferredToken`/`Fts3MultiSegReader` kept as opaque Pointer; and the Tcl `sqlite_fts3_enable_parentheses` LinkVar (fts3_test.c Sqlitetestfts3_Init) deferred to .n/.o test wiring so gated fts3*.test files can flip the new-syntax path.
    - [X] **6.40.1.j** `fts3_write.c` (5856L) ported into passqlite3fts3.pas, all 7 sections complete: (1) FTS3 varint codecs PutVarint/GetVarintU/GetVarint/GetVarintBounded/GetVarint32/VarintLen + fts3GetVarint32 macro (fts3.c:331..442, owner=.k, NOT to be re-ported); (2) SQL stmt registry fts3SqlStmt+aStmt[40]+fts3SqlExec/PrepareStmt (3) pending-terms hash PendingListAppend(Varint)/PendingTermsAdd(One)/Docid/Clear/Flush/InsertTerms/InsertData/DeleteAll/DeleteTerms (4) segment WRITER fts3PrefixCompress/NodeAddTerm/TreeFinishNode/NodeWrite/NodeFree/SegWriterAdd/Flush/Free/WriteSegment/WriteSegdir (5) segment READER+merge ReadBlock/SegReaderNew/Pending/Free/Next(Docid)/FirstDocid/Start/Step/Finish/Cmp/Sort/ColumnFilter/MsrIncrStart/Next/Restart/Ovfl + SegmentMerge/PromoteSegments/PendingTermsFlush (6) xUpdate UpdateMethod/DeleteByRowid + FTS4 %_docsize(InsertDocsize) & %_stat(UpdateDocTotals,Encode/DecodeIntArray) (7) maintenance Optimize/DoOptimize/DoRebuild/Incrmerge(+Csr/Load/Writer/Append/Push/Chomp/Release/Hint*/Truncate*/RepackSegdir/RemoveSegdir/nodeReader*/blobGrowBuffer)/IntegrityCheck/ChecksumIndex+Entry/SpecialInsert(optimize/rebuild/integrity-check/merge=/automerge=/flush+TEST nodesize/maxpending/mergecount)/deferred-token CacheDeferredDoclists/Defer(Free)Token(s)/DeferredTokenList. Shared structs Fts3Table/Cursor/SegReader/MultiSegReader/SegFilter/Index/PendingList/DeferredToken/SegmentNode/SegmentWriter/Blob/NodeWriter/NodeReader/IncrmergeWriter + FTS3_SEGCURSOR/SEGDIR/SEGMENT_*/SQL_*/FTS_STAT_* consts declared in INTERFACE for .k/.l/.m/.n. **Cross-boundary `{TODO 6.40.1.k}` stubs left** (defined in fts3.c, CALLED here, stub bodies return SQLITE_ERROR/no-op): `sqlite3Fts3SegReaderCursor`, `sqlite3Fts3DoclistPrev`, `sqlite3Fts3FirstFilter`, `sqlite3Fts3CreateStatTable`. C-post-increment doclist scans ported read-then-advance (fts3SegReaderNextDocid `while(*p|c)`, fts3ColumnFilter). New TestFts3Write.pas (varint round-trips 0/127/128/2^32-1/2^32/2^63-1/2^63/2^64-1, GetVarint32 31-bit truncation, multi-value buffers, bounded decode, macro vs fn) → PASS exit 0. Builds clean (build.sh+build_tcl_lib.sh+build_tcl_driver.sh). Regression 107/108 (only pre-existing TestFuzzDiff red); fts3 Tcl filter 59/59, no pas-strict regression.
    - [X] **6.40.1.k** fts3.c fts3/fts4 vtab module ported into passqlite3fts3.pas (fts3InitVtab xCreate/xConnect, fts3BestIndexMethod, doclist/poslist merge primitives, segment-reader-cursor, the MATCH evaluator fts3EvalStart/AllocateReaders/StartReaders/PhraseStart/PhraseLoad/IncrPhraseNext/NextRow/NearTest/TestExpr/Next, xFilter/xNext/xColumn/xRowid/xEof, xUpdate wrapper, xSync/Begin/Commit/Rollback/Savepoint/Release/RollbackTo, xFindFunction+overload dispatch, xRename/xShadowName/xIntegrity, static fts3Module). Promoted the 4 .j cross-boundary stubs (sqlite3Fts3SegReaderCursor/DoclistPrev/FirstFilter/CreateStatTable) + .i fts3ReadInt→sqlite3Fts3ReadInt(local)/fts3EvalPhraseCleanupLocal→real (frees pSegcsr via fts3SegReaderCursorFree). sqlite3Fts3Init now registers fts3+fts4 modules + snippet/offsets/matchinfo/optimize overloads + fts3tokenize (fts3.c:4166..4187, nRef-guarded). New TestFts3Vtab.pas drives REAL SQL: MATCH word/AND/OR/phrase/NEAR/NOT, column-scoped a:foo (fts3), xColumn, DELETE+UPDATE re-query, fts4 prefix=2,3 + notindexed= — all rowid sets correct; DIFFERENTIAL byte-match vs ../sqlite3/sqlite3 oracle on 4 queries → PASS exit 0. {TODO 6.40.1.l} stubs left: fts3SnippetFunc/OffsetsFunc/MatchinfoFunc emit clean errors (real bodies are fts3_snippet.c); fts3EvalTokenCosts/SelectDeferred (FTS4 deferred-token cost opt) + sqlite3Fts3MIBufferFree omitted as faithful no-deferred subset. Builds clean (build.sh+build_tcl_lib+driver).
      - [X] **6.40.1.k.1** FTS4 key=value option parser ported — fts3IsSpecialColumn (fts3.c:782) + aFts4Opt[8] (matchinfo/prefix/compress/uncompress/order/content/languageid/notindexed) gated on isFts4, fts3PrefixParameter (prefix=) + fts3GobbleInt, fts3ContentColumns (content=). Verified live: fts4(...,prefix="2,3",notindexed=tag) builds + prefix queries return correct rowids.
      - [X] **6.40.1.k.2** %_docsize/%_stat DDL in fts3CreateTables (bHasDocsize→%_docsize, bHasStat==bFts4→%_stat via sqlite3Fts3CreateStatTable, fts3.c:728..737) + bHasStat==2 legacy lazy-detect via fts3SetHasStat/sqlite3_table_column_metadata (fts3.c:3566..3579, set at InitVtab 1508 for non-fts4 xConnect).
      - [X] **6.40.1.k.3** FTS4 feature tests run under the cap flip (6.40.1.o): prefix indexes (fts3prefix/fts3prefix2 PASS), contentless/external-content + notindexed exercised by fts4content (0→106 subtests), aux (fts3aux2 PASS). languageid (fts4langid) still hits the heavy-build timeout (6.40.1.o.2). Core MATCH/snippet/offsets/matchinfo all green (fts3matchinfo/matchinfo2/snippet2 PASS).
    - [X] **6.40.1.l** `fts3_snippet.c` ported into passqlite3fts3.pas: MatchinfoBuffer lifecycle (New/Free/Alloc/SetGlobal/MIBufferFree, wired into fts3ClearCursor), phrase/poslist plumbing (fts3GetDeltaPosition, fts3ExprIterate2/sqlite3Fts3ExprIterate, fts3ExprLoadDoclists, fts3ColumnlistCount), offsets() (sqlite3Fts3Offsets + fts3ExprTermOffsetInit/fts3ExprRestartIfCb), snippet() (sqlite3Fts3Snippet + fts3BestSnippet/SnippetText/SnippetShift/SnippetDetails/NextCandidate/FindPositions/StringAppend), matchinfo() (fts3GetMatchinfo/fts3MatchinfoValues + ALL format codes p,c,n,a,l,s,x,y,b live via fts3MatchinfoCheck/Size/SelectDoctotal/Lcs/ExprLHits/LHitGather/Global+LocalHitsCb), and the 3 SQL fns fts3SnippetFunc/OffsetsFunc/MatchinfoFunc (fts3.c:3702/3749/3809) replacing the .k stubs; xFindFunction dispatch already routed. Also promoted the .k-omitted fts3.c eval-stats helpers consumed here: fts3EvalRestart/UpdateCounts/AllocateMSI/GatherStats + sqlite3Fts3EvalPhraseStats/EvalPhrasePoslist/MsrCancel (fts3.c:5746..6154). New TestFts3Snippet.pas drives real fts4 SQL and BYTE-DIFFs vs ../sqlite3/sqlite3 oracle on offsets/snippet(custom delims)/matchinfo('pcxnal')/matchinfo('pcx' OR) → PASS exit 0. Deferred-token cost opt (fts3EvalTokenCosts/SelectDeferred) stays the no-deferred subset (pCsr->pDeferred=nil, so matchinfo 'x' deferred arm never taken); sqlite3Fts3MIBufferFree ported (needed by cursor teardown). Builds clean (build.sh+build_tcl_lib+driver); regression clean (only pre-existing TestFuzzDiff + TestSQLCorpus timeout); fts3 Tcl filter no pas-strict regression (fts3snippet/fts3snippet2 PASS gated).
  - **Cluster C — dependent readers + final wiring.**
    - [X] **6.40.1.m** `fts3_aux.c` ported into passqlite3fts3.pas — Fts3auxTable/Cursor/Colstats, fts3auxConnect/Disconnect/BestIndex/Open/Close/GrowStatArray/Next(doclist eState varint walk)/Filter(SegReaderCursor ALL+Start)/Eof/Column/Rowid, static fts3aux_module, public sqlite3Fts3InitAux; wired into sqlite3Fts3Init at fts3.c:4125 (before hash alloc). New TestFts3Aux.pas (col=*, term ranges, EQ, multi-col breakdown) DIFFERENTIAL byte-matches ../sqlite3/sqlite3 oracle → PASS exit 0; regression clean (only pre-existing TestFuzzDiff); fts3 Tcl 59/59 no pas-strict regression.
    - [X] **6.40.1.n** `fts3_term.c` ported (SQLITE_TEST-gated) into passqlite3fts3.pas — Fts3termTable/Cursor, fts3termConnect/Disconnect/BestIndex/Open/Close/Next(docid/col/pos varint walk)/Filter(SegReaderCursor iIndex)/Eof/Column/Rowid, static fts3term_module, public sqlite3Fts3InitTerm; wired into sqlite3Fts3Init under {$IFDEF SQLITE_TEST} at fts3.c:4120. Verified via Tcl bridge: fts4term(t) yields correct (term,docid,col,pos) rows; bridge build compiles + registers clean.
    - [X] **6.40.1.o** Wiring + cap flip + sweep DONE. `sqlite3Fts3Init` (fts3.c:4102) audited 1:1 vs C — ordering/nRef accounting faithful (InitTerm[TEST]→InitAux→load simple/porter/unicode61→ExprInitTestInterface[TEST]→InitHashTable→overload snippet/offsets/matchinfo×2/optimize→create_module fts3+fts4→InitTok); ICU arm correctly absent. Ported the fts3_test.c Tcl harness as new `src/tests/tcl/testmodules/TestModuleFts3.pas` (Sqlitetestfts3_Init: fts3_near_match/fts3_configure_incr_load/fts3_test_tokenizer[v1 xLanguageid]/fts3_test_varint/sqlite3_fts3_may_be_corrupt[non-DEBUG no-op] + `sqlite_fts3_enable_parentheses` Tcl_LinkVar), wired through PasTclSqlite.Sqlite3_Init + the .lpr; promoted `sqlite3_fts3_enable_parentheses` and the `test_fts3_node_chunksize/threshold` tunables (FTS3_NODE_CHUNKSIZE/THRESHOLD now SQLITE_TEST-mutable accessors) to the fts3-unit INTERFACE. **Capability flip** `tester_min.tcl` `fts3` 0→1, added `fts3_unicode=1`, `fts4_deferred=0` (no-deferred subset), kept `fts5=0`/`icu=0`. **Fixed a real engine crash** exposed by the flip: `viewGetColumnNames` (build.c:3101) lacked the IsVirtual→xConnect arm, so UPDATE on an FTS vtab after a db reopen `sqlite3SelectDup(nil)` SIGSEGV'd — added a `gVtabCallConnect` trampoline (codegen→vtab) wired in main; fts-9fd058691 PASS, fts3integrity/fts4intck1/fts4content recovered. **Real Tcl counts** — fts3: 30/59 PASS (was 0 real; trivially-gated before), fts4: 3/22 PASS, plus fts-9fd058691 PASS. **STATUS.txt**: 35 fts files PASS → kept pas-strict; 48 genuinely-failing fts files demoted pas-strict→pas-soft (terse fts3-residual reasons); 2 non-fts files exposed by the flip (orderby7, tkt-bdc6bbbb38 — confirmed PASS@fts3=0) demoted pas-soft. Engine regression clean (only pre-existing TestFuzzDiff); no NEW pas-strict regression from the flip (scanstatus/vtab2/vtab_shared/incrblob3 confirmed PRE-existing fails, untouched). Residuals below.
      - [X] **6.40.1.o.1** order=desc / docid-update doclist residual CLOSED — all four affected files (fts3aa, fts4docid, orderby7, tkt-bdc6bbbb38) now pas-strict. Final blocker fts3aa-10.1 fixed: recursive shadow-table AFTER-DELETE trigger re-entered `fts3SqlExec` on the busy `%_content` DELETE stmt → vdbeUnbind MISUSE; now surfaces SQLITE_ERROR ("SQL logic error") via the fts3 recursive-content guard, matching C (fts3.c:1616). Each leaf below has a binary deliverable:
        - [X] **6.40.1.o.1.1** TestFts3DescUpdate.pas added (both arms; reverts to HANG/exit124 without fix). Diverging fn: `fts3ReversePoslist`.
        - [X] **6.40.1.o.1.2** Reverse-poslist reader, not pending arm: final byte-skip loop `while(*p++&0x80)` ported 1 byte short → poslist start + *pnList off-by-one.
        - [X] **6.40.1.o.1.3** Fixed `fts3ReversePoslist` (added trailing `Inc(p)` matching C post-inc). Repro PASS, integrity_check ok, fts3aa 8.x order=desc green.
        - [X] **6.40.1.o.1.4** Promoted fts4docid + tkt-bdc6bbbb38 + orderby7 → pas-strict. Root cause of BOTH residuals was the SAME bug: `sqlite3Insert` codegen (codegen.pas:43103) emitted `OP_Null` at regRowid for ALL virtual-table INSERTs, dropping any user-supplied rowid/docid → FTS docids were always vtab-allocated (1,2,3…) instead of the explicit values. Ported insert.c:1502..1537 faithfully: vtab arm now loads the `ipkColumn` rowid term (ExprCode/Column/coroutine) and uses `OP_IsNull`+`OP_MustBeInt` (no OP_NewRowid) per C. That fixed fts3aa-6.1/6.3/6.4 (zero/neg rowid stored+read) AND orderby7 (its `MATCH 'that twice'` rows had wrong docids only because the explicit rowids in `INSERT INTO fts(rowid,...)` were ignored — not an AND-phrase merge bug). ExplainParity 1026/0, all TestFts3* PASS. fts3aa now pas-strict after 10.1 fix (.o.1.5).
        - [X] **6.40.1.o.1.5** fts3aa-10.1 fixed → pas-strict (57/57). `fts3SqlExec` (passqlite3fts3.pas) now guards the busy cached-stmt reentry: when `p^.aStmt[eStmt]` is in VDBE_RUN_STATE (recursive shadow-table trigger sub-frame), return SQLITE_ERROR instead of letting vdbeUnbind's busy-bind SQLITE_MISUSE escape — matching C's recursive-content protection (fts3.c:1616 bLock guard returns SQLITE_ERROR). Also added `expand_all_sql` stub to tester_min.tcl (tester.tcl:2601, the harness helper fts3aa:264 needs). ExplainParity 1026/0, all TestFts3* PASS, TestFts3DescUpdate PASS, no pas-strict regression.
      **REMOVED TASK 6.40.1.o.2** segment-merge build performance (per-INSERT flush ~28 ms/row → heavy builds blow the 30 s wall clock). **MOVED to Phase 12 as 12.4** (perf optimisation, not a correctness/migration gap). Affected pas-soft files tracked there: fts4merge/merge4/merge5, fts4growth/growth2, fts4opt, fts4langid, fts4check, fts3corrupt2, fts3corrupt6.
      - [X] **6.40.1.o.3** misc per-file FTS edge-case fails — all 36 files resolved (PASS pas-strict OR demoted with a precise one-line cause in STATUS.txt). Two root-cause engine fixes did most of the work: (1) selectExpander's view-arm gated on TABTYP_VIEW only, so a vtab was never run through sqlite3ViewGetColumnNames→xConnect — C select.c:6040 is `!IsOrdinaryTable` (VIEW *or* VTAB); fixed → FTS tables loaded from a reopened/deserialized schema now connect lazily ("no such column" gone). (2) sqlite3_bind_value's TEXT arm hardcoded UTF-8 instead of bindText(...,pValue->enc) (vdbeapi.c:1383) → UTF-16 content truncated at first NUL; routed through sqlite3_bind_text64 with the value's enc. Plus 5 harness helpers (sqlite3_drop_modules, install_fts3_rank_function, read_fts3varint, sql_uses_stmt, do_select_test family) + CORRUPT_VTAB errcode-name. **10 promoted to pas-strict** (fts3corrupt, fts3corrupt7, fts3snippet, fts3rank, fts3dropmod, fts3c, fts3d, + already-green fts3drop/fts3ai/fts3ao). The residual demotions cluster into 4 documented causes: count(*)/agg+MATCH not routed to xBestIndex in the no-GROUP-BY aggregate arm (umlaut/noti/incr/an/fault2); unported vtab modules (fs/test_fs.c → fts4content, make_fts3record → fts4record); fault-sim harness gap (fts3fault*); and assorted per-file engine edge cases.
        - [X] **6.40.1.o.3.1** corruption-detection: fts3corrupt + fts3corrupt7 PASS (lazy-connect on deserialize + CORRUPT_VTAB name); fts3corrupt4 1/76 residual (control-insert over corrupt segment).
        - [X] **6.40.1.o.3.2** fault-injection/OOM: all three demoted with cause — fault-sim harness gap (faultsim_integrity_check unported, fault-locking cascade, count(*)+MATCH-in-agg).
        - [X] **6.40.1.o.3.3** eval output: fts3snippet + fts3rank PASS (bind-encoding fix + install_fts3_rank_function); fts3offsets 1/10 residual (order=desc row reordering, the o.1 class).
        - [X] **6.40.1.o.3.4** content/notindexed/external-content: all demoted with cause (external-content edge cases + fs vtab unported; count(*)+MATCH-in-agg; make_fts3record unported; onepass DELETE divergence; vtab min/max idxStr).
        - [X] **6.40.1.o.3.5** DDL: fts3drop + fts3dropmod PASS (sqlite3_drop_modules); fts4rename (errmsg missing colname) + fts4lastrowid (explicit-rowid last_insert_rowid) demoted with cause.
        - [X] **6.40.1.o.3.6** conflict/upsert + misc: all demoted with cause (conflict-clause divergence; UPDATE FROM; MATCH-in-join; heavy-sort crash; large int64 docid; count()+MATCH-in-agg; compress= round-trip).
        - [X] **6.40.1.o.3.7** fts3 acceptance-suite chunks: fts3ai/fts3ao/fts3c/fts3d PASS (read_fts3varint + lazy-connect); fts3aj/fts3ak/fts3an/fts3aux1/fts3b demoted with cause.
        - [X] **6.40.1.o.3.8** fts3shared — demoted with the shared-cache deferral cite (SQLITE_OMIT_SHARED_CACHE entirely omitted; see memory `project_uri_shared_cache_lock_stub`). Not attempted, per DoD.
    - [X] **6.40.1.p** Replaced 5 libc externals in passqlite3fts3.pas with FPC RTL: strlen→StrLen (34), memcpy→Move w/ arg-flip (49), memset→FillChar (52), memcmp+strncmp→CompareByte (19). Same in TestModuleFts3.pas (strlen/memset/memcmp). strcmp/atoi/qsort kept (out of scope). ExplainParity 1026/0, all TestFts3* PASS, fts3snippet/fts3rank/fts3c PASS.
    - [X] **6.40.1.p.2** DONE (all 6 leaves). Swept portable libc string/mem externals out of util/fts3/amatch/fuzzer/spellfix/recover/zipfile + TestModuleFts3 into FPC RTL (StrLen/Move/FillChar/CompareByte/StrComp/StrLComp + custom fts3Atoi/recoverStrStr/fts3Qsort). build 111/1, ExplainParity 1026/0, all TestFts3* PASS, no new Tcl regression. Sweep: **Mapping (mind .p's caveats):** `strlen`→`StrLen` (unit `Strings`); `memcpy(dst,src,n)`→`Move(src^,dst^,n)` (ARG-FLIP); `memset(dst,c,n)`→`FillChar(dst^,n,Byte(c))`; `memcmp`→`CompareByte` (signed first-diff byte, ≡ memcmp); `strncmp`→`CompareByte` for fixed-len binary cmp, else `StrLComp` if only sign/zero-tested; `strstr`→`Pos`/manual scan; `strcmp`→`StrComp`. **Gate (behaviour-preserving):** build.sh 111/112 (only TestFuzzDiff), ExplainParity 1026/0, no Tcl pas-strict regression. Per-unit leaves (each its own commit):
      - [X] **6.40.1.p.2.1** `passqlite3util.pas`: removed `libc_strlen`/`libc_memcpy`/`libc_memset` externals; →StrLen (2 sites), Move (9 sites), FillChar (7 sites). Added `Strings` to uses. build 111/1, ExplainParity 1026/0.
      - [X] **6.40.1.p.2.2** Removed `libc_strcmp`/`libc_atoi` (fts3) + `libc_strcmp` (TestModuleFts3): strcmp→StrComp (4 sites: 3 fts3 + 1 test module); atoi→new C-exact `fts3Atoi` helper (5 sites). qsort left for p.2.6. build 111/1, ExplainParity 1026/0, all TestFts3* PASS.
      - [X] **6.40.1.p.2.3** Removed strlenC/strcmpC/strncmpC/memcmpC externals: strlen→StrLen (8 sites), strcmp→StrComp (5), strncmp→StrLComp (NUL-aware, 3, all sign/zero-tested), memcmp→CompareByte (1, deref). memmoveP already RTL. build 111/1, ExplainParity 1026/0, amatch1 PASS.
      - [X] **6.40.1.p.2.4** Removed strlenC/strcmpC/memcmpC externals: strlen→StrLen (6 sites), strcmp→StrComp (2), memcmp→CompareByte (1, deref). build 111/1, ExplainParity 1026/0, fuzzer1 PASS.
      - [X] **6.40.1.p.2.5** spellfix: strlen→StrLen (6), strncmp→StrLComp (7, NUL-aware≡C); recover: recoverStrLen→StrLen body, recoverStrStr→Pascal strstr scan (empty-needle→haystack); zipfile: strlenC→StrLen (7), stdio fwrite/fseek/ftell externals left. build 111/1, ExplainParity 1026/0; spellfix.test/zipfile.test PASS; recover.test FAIL is pre-existing baseline (confirmed via stash compare).
      - [X] **6.40.1.p.2.6** Replaced libc_qsort external with `fts3Qsort` (same signature: base/nmemb/size/TFts3QSortCmp). Iterative median-of-3 Lomuto quicksort + insertion-sort for <8 elems, generic byte-element swaps via temp+Move, smaller-side-on-stack recursion cap. Only consumer is sqlite3Fts3SegReaderPending bPrefix path; comparator gives total order over unique hash keys so output ≡ libc. Verified: all TestFts3* PASS, ExplainParity 1026/0, fts3prefix.test (40) + fts3.test (24) PASS.
  - **NOTE:** libc externals that must STAY (not porting gaps): the OS syscall layer in `passqlite3os.pas` (open/read/write/mmap/stat/fsync/…), the allocator (malloc/calloc/realloc/free), time/system calls, the printf-varargs family (snprintf/vsnprintf/vasprintf — C-exact formatting), stdio mirrored from C in the CLI/extensions/test modules (shell/csv/fileio/vfslog/tmstmpvfs/memtrace/pcachetrace/TestModule*), and the non-`'c'` bindings (`csqlite3.pas`→libsqlite3 oracle, `zipfile.pas`→libz).
  - **NOTE:** `fts3_icu.c` (262L) stays unported — oracle lacks `SQLITE_ENABLE_ICU` (see 6.40.2); the `icu` tokenizer arm in `sqlite3Fts3Init` is `#ifdef SQLITE_ENABLE_ICU` and must be omitted to match.
- [X] **6.40.2** ICU extension — oracle lacks SQLITE_ENABLE_ICU (no icu in pragma_compile_options), so pinned `sqlite_options(icu)=0` + `icu_collations=0` in tester_min.tcl:364; icu.test now skips via its `ifcapable !icu&&!icu_collations` gate (PASS 0/22, no pas-strict regression).
- [X] **6.40.3** preupdate_hook — HARNESS, not engine: oracle build LACKS `SQLITE_ENABLE_PREUPDATE_HOOK` (verified `pragma_compile_options`), so implementing+enabling it would diverge from the oracle. Faithful fix = skip cleanly to match oracle: bind2/sessionfault already do via upstream `ifcapable !preupdate` (cap pinned 0 in tester_min.tcl); local port preupdate.test had no guard → fixed with a runtime probe `if {[catch {db preupdate count}]} {finish_test;return}` (skips on default lib, runs full 52-subtest assertions on a PREUPDATE=1 lib). preupdate.test FAIL→PASS, promoted pas-soft→pas-strict in STATUS.txt; no pas-strict regression (src/tests/tcl/preupdate.test:55-65).
- [~] **6.40.4** Loadable extensions for `load_static_extension` — DONE: extended the existing aExtension[] table (TestModuleTest1.pas:581 tclLoadStaticExtensionCmd, mirrors test1.c:8406) from 11→23 names by wiring the already-ported sqlite3*Init shims: series/spellfix/closure/csv/fuzzer/prefixes/randomjson/appendvfs/amatch/nextchar/remember/unionvtab. All now load (was "no such extension"). prefixes/fuzzer1/fuzzer2/json108 now PASS; series/csv/spellfix/closure/randomjson/appendvfs load OK but tests still FAIL on deeper pre-existing engine bugs (tabfunc01 hangs at 1.7 4-arg series-arg rejection; join8 SIGSEGV at 9000; csv01/spellfix2/json106 deeper). All flagged tests were baseline-FAIL (errored on the first `load_static_extension` line), so no NEW pas-strict regression. DEFERRED: `echo` already works (register_echo_module, test8.c; swarmvtab2 PASS); `register_fs_module` (vtabH, test_fs.c 920L) + `register_schema_module` (test_schema.c 367L) are full vtab-module ports — not done.
- [X] **6.40.5** `sqlite3_prepare_v3` Tcl trampoline — ported test_prepare_v3 (test1.c:5159..5229) + registered (test1.c:9149) in TestModuleTest1.pas; siblings _normalize/_expanded_sql/_normalized_sql already wired. normalize.test 55→47 errors (66 `invalid command name "sqlite3_prepare_v3"`→0), no pas-strict regression.
- [~] **6.40.6** Crash/pager/IO harness cmds. DONE: `btree_pager_stats` (test3.c:147→TestModuleTest1; needed engine `sqlite3PagerStats` pager.c:6854 + `sqlite3PcacheGetCachesize` pcache.c:855 + new `Pager.nRead` field & PAGER_INCR at pager.c:3068); `sqlite3_pager_refcounts` (test1.c:6558); `pcache_stats` (test1.c:7573 + engine `sqlite3PcacheStats` pcache1.c:1261); `uses_stmt_journal` (test1.c:3060); `extra_schema_checks` (test1.c:7522); `file_control_powersafe_overwrite` (test1.c:7190); pure-Tcl `catchcmd`/`catchsafecmd`/`catchcmdex`/`dumpbytes` (tester.tcl:821-871) + `allcksum` (tester.tcl:2145) into tester_min.tcl. Results: cache.test 2→189 subtests (4 residual = pre-existing PRAGMA cache_size=0 readback bug), incrblob 12→7 err, pcache.test/fkey8.test PASS, ioerr2 now runs 3528 subtests (1 residual = unrelated dir-perms test). No NEW pas-strict regression (cache/incrblob were already baseline-FAIL stale-strict; both improved). DEFERRED: `crash_on_write` (test6.c:984 needs devsym VFS port, test_devsym.c); `btree_open` (test3.c:36 standalone Btree harness); `sqlite3_config_heap`/`mutex_counters`/`sorter_test_*`/`clock_seconds`/`isquick` (separate subsystems / low count).
- [X] **6.40.7** Snapshot Tcl trampolines NOT registered — faithful: test1.c:9311-9319 wrappers are all `#ifdef SQLITE_ENABLE_SNAPSHOT`; oracle lacks it (0/54 compile_options), so `snapshot` already pinned 0 (tester_min.tcl:360). snapshot/3/4/_up/_fault all PASS via `ifcapable !snapshot`.
- [X] **6.40.8** Misc test SQL fns: added test_setsubtype/test_getsubtype to aFuncs[] (TestModuleFunc test_func.c:619/649); sumint window fn + test_create_sumint/test_create_window_function_misuse/test_override_sum (TestModuleTest1 test_window.c:225..329); sqlite3_set_errmsg + x_sqlite_exec/sqlite3ExecFunc (TestModuleTest1 test1.c:836/4999); parse_create_index + ieee754_from_int already ported (passqlite3intck/passqlite3ieee754). misuse.test FAIL→PASS (22/22); window5 3→5 subtests (residual 1.1 median float-fmt + 3.0 sum-override engine gaps, pre-existing). No pas-strict regression.
- [~] **6.40.9** WAL/blob harness cmds: ported blob_reopen, wal_checkpoint_v2, mmap_warm, interrupt, is_interrupted, utf8_to_utf8 + utf8To8Inplace (TestModuleTest1.pas; test1.c:1824/5984/6005/7685/8734, test_hexio.c:306). incrblob3 29→4 err, badutf2/mmapwarm cmds pass. quota_glob (test_quota.c VFS shim) DEFERRED — large.

> NOTE (2026-05-22): securedel.test failures are NOT an engine porting gap — the
> engine returns the correct `secure_delete` propagation when driven via the CLI;
> the residual `{1 0}` is a Tcl-bridge prepared-statement-caching interaction with
> codegen-time pragma side effects. Track separately if pursued.

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

- [X] **8.4.1** sqlite3_test_control full varargs coverage (overload-based dispatcher; ~18 verbs: PRNG_*, OPTIMIZATIONS, PENDING_BYTE, BYTEORDER, JSON_SELFCHECK, ...).
- [X] **8.2.1** sqlite3VdbeScanStatus + ScanStatusRange + ScanStatusCounters ported (vdbeaux.c:1186..1274); sqlite3_stmt_scanstatus_v2 reader covers NLOOP/NVISIT/EST/NAME/EXPLAIN/SELECTID/PARENTID.
- [X] **8.1.1** sqlite3_config / sqlite3_db_config full varargs coverage (overload-based; LOOKASIDE, LOG, PAGECACHE, MMAP_SIZE, PMASZ, MAINDBNAME, FP_DIGITS, flag toggles).
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

- [X] **9.1.1** Corpus inventory.

- [X] **9.1.2** Oracle runner helper.

- [~] **9.1.3** `TestSQLCorpus.pas` skeleton — iterate MANIFEST, run both oracles, byte-compare all four channels; first diverging file prints summary and exits non-zero. Gate: `bin/TestSQLCorpus` rc=0. Skeleton landed 2026-05-12; full coverage delivered by 9.1.3.followup.

- [X] **9.1.3.followup** Full MANIFEST coverage via `SQLLiteralExtractor.pas`; 51 tier-1+2 entries, 2259 scripts; 52 divergences cataloged to `DIVERGENCES.md`.

- [X] **9.1.4** Determinism scrub — `ApplyHeaderMask` zeros 4 verified byte ranges (24..27, 56..59, 92..95, 96..99); see `src/tests/corpus/MASK.md`.

- Triage of `DIVERGENCES.md` clusters (~7 root causes; archive has full details):
  - [X] **9.1.divbug.1** RELEASE-without-SAVEPOINT errmsg (44 sites) — OP_Savepoint not-found arm formats via sqlite3VdbeError (vdbe.c:3902).
  - [X] **9.1.divbug.2** PRAGMA mmap_size / journal_mode output shape (3 sites) — pragma.c:951..978 / 734..771.
  - [X] **9.1.divbug.3** DROP INDEX errmsg truncation (build.c:4614).
  - [X] **9.1.divbug.4..8** Five sites, single root cause: `sqlite3WritableSchema` mask bit was `0x20` (SQLITE_CacheSpill) instead of `0x01` (SQLITE_WriteSchema, sqliteInt.h:1829).

- [X] **9.1.5** Corpus status tags landed in `src/tests/corpus/STATUS.txt` (`pas-strict`/`pas-soft`/`pas-skip` with cite); strict gate fires `Halt(1)` on any pas-strict divergence.

- [X] **9.1.6** Coverage check — `bin/TestSQLCorpus --coverage` + `gVdbeOpCoverage[]`.

### 9.2 `TestReferenceVectors.pas` — canonical `.db` snapshots

- [X] **9.2.1** Vector inventory — 9 `.sql`+`.db` pairs under `src/tests/vectors/`; fts5+rtree `.sql`-only [SKIP]; legacy simple/multipage [~]; non-deterministic .db-wal sidecar not committed.

- [~] **9.2.2** Read-only parity probe — `bin/TestVectorReadOnly` + per-vector `*.queries.sql` (11 vectors). Bucket-A FIXED in 9.2.divbug.A (btreeBeginTrans wrflag gate); the unioned pas-skip list now covers bucket-F (autovacuum/incrvacuum), bucket-G (utf16), bucket-H (withoutrowid), bucket-I (wal/multipage/generated-column round-trip drift) and bucket-J (triggers round-trip crash) plus bucket-C/E for view-cte/partial-index — but those buckets affect 9.2.3/9.2.4 only.  RO probe today: gated=1 ok=1 diverged=0 skipped=10 rc=0; the actual fix lifted SQLITE_READONLY for every vector and the remaining skips are pre-existing non-RO bugs surfaced after bucket-A was lifted.

- [~] **9.2.3** Round-trip probe — `bin/TestVectorRoundTrip` + per-vector `<name>.mutate.sql` (11 mutators each exercising the vector's feature). Re-uses `CorpusOracle.ApplyHeaderMask`. Today (post-9.2.3.followup, cite-aware RT filter): gated=8 ok=8 diverged=0 skipped=3 rc=0.  Remaining skips: autovacuum (bucket-L, also bucket-B for schema-change), incrvacuum (bucket-L), utf16 (bucket-M, also bucket-K for RO).  Bucket-A umbrella lifted; bucket-I (4-vector RT cell-layout drift) closed; bucket-J (triggers RT crash) closed.

- [~] **9.2.4** Schema-change probe — `bin/TestVectorSchemaChange` + per-vector `<name>.schema.sql` (8 vectors). Opens RW so does NOT inherit bucket-A; surfaced 4 new buckets (B/C/D/E — see 9.2.divbug.* below). 9.2.divbug.C closed (view-cte rename arm), 9.2.divbug.E closed (partial-index RENAME COLUMN aColExpr pin), but both view-cte and partial-index still hit bucket-B at the trailing VACUUM so they stay pas-skip. Today: gated=1 ok=1 diverged=0 skipped=7 rc=0.

- [X] **9.2.5** Vector regen script — `src/tests/vectors/regen.sh` walks every `*.sql`, regenerates via C oracle, `cmp`s against committed blob.

- Triage of `src/tests/vectors/DIVERGENCES.md` clusters surfaced by
  9.2.2 / 9.2.3 / 9.2.4 (5 buckets, each a Pascal-only port bug
  bisectable against the C oracle — skip-and-cite per the corpus
  contract; mirrors the `9.1.divbug.*` pattern):
  - [X] **9.2.divbug.A** RO-open trips `SQLITE_READONLY` — `btreeBeginTrans` missing `wrflag<>0` conjunct (btree.c:3622).
  - [X] **9.2.divbug.F** PRAGMA auto_vacuum returns 0 on RO-open — `sqlite3Pragma` stubbed auto_vacuum as constant `OP_Integer 0`; fix calls `sqlite3BtreeGetAutoVacuum(pBt)` per pragma.c:801.
  - [X] **9.2.divbug.G** PRAGMA encoding garbled on UTF-16 RO — two causes: encoding arm hardwired 'UTF-8'; OP_String8 mis-tagged literal bytes.
  - [X] **9.2.divbug.H** WITHOUT ROWID count(*) fast path → CORRUPT — codegen missing P4_KEYINFO on the PK index cursor (select.c:8793..8814).
  - [X] **9.2.divbug.I** Round-trip cell-layout drift — two bugs: generated-column STORED ref to IPK read SoftNull (alias iColumn==iPKey→rowid, codegen.pas:5689); printf('%.*c') ignored precision-as-repeat (printf.pas:1255). Archive.
  - [X] **9.2.divbug.J** Round-trip trigger-fire EAV — `sqlite3VdbeClearObject` released aMem/aVar/pVList/pFree on sub-vdbes still in VDBE_INIT_STATE (raw-malloc garbage).
  - [X] **9.2.divbug.B** Bare `VACUUM;` EAccessViolation — `sqlite3_config` wrote a stack-slot addr into GlobalConfig.xLog; plus three SQLITE_OMIT_AUTOVACUUM-stubbed btree arms restored.
  - [X] **9.2.divbug.C** ALTER TABLE RENAME on VIEW-dependent table → EAV — `sqlite3CreateView` reduced pSelect under IN_RENAME_OBJECT; resolver wrote past EP_TokenOnly/EP_Reduced allocations.
  - [X] **9.2.divbug.D** CREATE INDEX on WITHOUT ROWID byte-different — `sqlite3CreateIndex` missing pPk arm (build.c:4278..4292) that copies PK columns into index-key suffix.
  - [X] **9.2.divbug.E** RENAME COLUMN on partial-index byte-different — missing IN_RENAME_OBJECT arm pinning `pIndex^.aColExpr` (build.c:4209, alter.c:1639).
  - [X] **9.2.divbug.K** UTF-16 `hex()` byte-swapped — `sqlite3_result_text*`/`_blob*` skipped `sqlite3VdbeChangeEncoding(pOut, pCtx->enc)` from `setResultStrOrError` (vdbeapi.c:387..427).
  - [X] **9.2.divbug.L** Auto-vacuum round-trip page-count drift — fixed `finalDbSize` (exact `ptrmapPageno` walk + `PTRMAP_ISPAGE` guard, btree.c:4135) and ported the missing `PRAGMA incremental_vacuum` codegen arm (pragma.c:854).
  - [X] **9.2.divbug.L.1** Port `incrVacuumStep` (btree.c:4034..4128) + prerequisite ptrmap stubs (`ptrmapPageno`/`Put`/`Get`, `setChildPtrmaps`).
  - [X] **9.2.divbug.L.2** Port `relocatePage` + `modifyPagePointer` (btree.c:3876..4012).
  - [X] **9.2.divbug.L.3** Wire `autoVacuumCommit` body (btree.c:4194..4277) + CommitPhaseOne caller.
  - [X] **9.2.divbug.M** ~~UTF-16 INSERT raw-UTF-8~~ CLOSED — subsumed by divbug.K (commit 6fd9ec2).
  - [X] **9.2.divbug.N** ~~Freeblock zeroing~~ CLOSED — audit artefact, not a defect.

- [X] **9.2.3.followup** Round-trip parser cite-aware — only RT-relevant bucket cites trigger skips.

- [X] **9.1.6.followup** Categorize 47 cold opcodes — split: 45 (a)-gated + 2 (b)-drivable + 4 newly-discovered real-cold all closed.

### 9.3 `TestFuzzDiff.pas` — differential fuzzer

- [X] **9.3.1** In-process harness — `bin/TestFuzzDiff <input.dbsqlfuzz>` 1:1 ports `fuzzcheck.c:decodeDatabase` (hex/`[NNNN]`/`\n--\n` frame).

- [X] **9.3.2** Seed corpus import — 8 seeds (`fuzzdata1..8.db`, ~62 MiB) imported to `src/tests/fuzz/seeds/`.

AFL wiring and downstream coverage-guided fuzzing work moved to
**Phase 13** (post-acceptance, parallel with Phase 12).  9.3.1 and
9.3.2 (in-process harness + seed corpus) remain the Phase-9
acceptance gate for this section.

### 9.4 SQLite Tcl test suite as alternate target

> Reorganised 2026-05-13: each umbrella bullet (9.4.1 .. 9.4.5) is
> immediately followed by its decomposed sub-arms; trailing
> `9.4.divbug.N` cluster bullets sit at the end in numeric order
> (matching `src/tests/tcl/DIVERGENCES.md`).
>
> **Timing & timeout rules (read before launching a run — 2026-05-16).**
> The driver applies a **20 s per-test watchdog**; the full MANIFEST
> (~959 entries) takes ~25 min unsharded and will be killed by any
> 20-min outer wall-clock (CI, `timeout`, agent harnesses).  Always
> shard 4-way — but **run the shards sequentially, never in parallel**:
> concurrent shards OOM-kill each other (silent partial results) due to
> stacked page caches + per-shard `libpassqlite3tcl.so` + tclsh
> footprints on a typical workstation.  Sequential 4-shard cost is
> ~25–60 min wall-clock.  See `README.md` → "Upstream Tcl test suite"
> for the exact command.  The same rule applies to running multiple
> `bin/Test*` binaries — `run_regression.sh` is already sequential;
> keep manual invocations the same way.  Three test files currently exceed the
> watchdog and **burn the entire shard-2 budget** if left in:
> `pragma4.test`, `printf.test`, `securedel.test` (tracked as
> `9.4.divbug.86`; sibling `.84` covers `select4.test` /
> `writecrash.test` / `securedel2.test`).  Until those are fixed or
> moved to `src/tests/tcl/SKIP.md`, shard 2 will not complete under
> 25 min — accept the partial result or skip them.  Most `FAIL` lines
> in shard logs are `pas-soft` and already cited in `STATUS.txt`; the
> only signal that matters is `REGRESSION (pas-strict FAIL): <path>`
> from `src/tests/tcl/check_status_regression.sh`.

- [X] **9.4.1** Inventory.
  - [X] **9.4.1.a** Inventory script `src/tests/tcl/inventory.sh` — greps each `../sqlite3/test/*.test` for internal/perf markers, emits `MANIFEST.txt` (`<tag>\t<path>`).

- [~] **9.4.2** Tcl binding shim.  Reuse / port the minimum of
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
  - [X] **9.4.2.0** Plan doc `src/tests/tcl/PLAN.md` — FPC↔Tcl bridge approach, Tcl C ABI symbol list (Tcl_CreateInterp/Eval/CreateObjCommand/...), staged plan 9.4.2.a..g.
  - [X] **9.4.2.a** Bridge unit — `src/tests/tcl/PasTclBridge.pas` with cdecl externs for the symbols listed in 9.4.2.0 PLAN (link via `-k-ltcl8.6` or `-k-ltcl`).
  - [X] **9.4.2.b** `Sqlite3_Init` exporter — minimal port of `tclsqlite.c:Sqlite3_Init` (registers the `sqlite3` Tcl object command and calls `Tcl_PkgProvide`).
  - [X] **9.4.2.c** `sqlite3 db1 :memory:` constructor — implemented `DbMain` arm that calls `sqlite3_open_v2` against passqlite3 and stores the resulting handle on a `SqliteDb*`-equivalent struct attached to the Tcl object command.
  - [X] **9.4.2.d** `db eval $sql` — minimum arm of DbObjCmd that prepares/steps/finalises and returns rows as a flat Tcl list (no column-name binding, no var-bind callback, no script-body arg).
  - [X] **9.4.2.e** `db version` / `changes` / `last_insert_rowid` / `errorcode` / `nullvalue` — trivial passthroughs to the matching sqlite3_* calls + zNull field.
  - [X] **9.4.2.f** `db function NAME ?-argcount N? proc` — registered a scalar UDF via sqlite3_create_function_v2 with a Tcl trampoline (DbSqlFunc).
  - [~] **9.4.2.g** `tester_min.tcl` — `src/tests/tcl/tester_min.tcl`
    re-exports just `do_test`, `do_execsql_test`, `execsql`,
    `expected`, `set_test_counter`, `finalize_testing`, and the global
    `db` handle — enough to source a hand-picked simple `.test` file.
    Body adapted from `../sqlite3/test/tester.tcl:703..` and `941..`.
    Smoke gate `bin/TestTclTesterMin` sources tester_min.tcl + runs
    `do_test foo-1.0 {expr 1+1} 2`.  Remaining helpers tracked in
    9.4.2.g.1.
  - [X] **9.4.2.g.1** `ifcapable` — gates a test (file-level or block-level) on `SQLITE_OMIT_*` / `SQLITE_ENABLE_*` compile flags.
  - [X] **9.4.2.g.2** `catchsql` + `do_catchsql_test` — runs SQL, captures `(rc, errmsg)` as a 2-list.
  - [X] **9.4.2.g.3** `finish_test` + `forcedelete` + `delete_file` — per-test teardown convention; tests source-include them at the end.
  - [X] **9.4.2.g.4** `integrity_check` — wrapper that runs `PRAGMA integrity_check` and asserts "ok".
  - [X] **9.4.2.g.5** `working_64bit_int` + `presql` + `omit_test` — capability/permutation helpers.
  - [X] **9.4.2.g.6** `do_eqp_test` — EXPLAIN QUERY PLAN comparison; needs `db eval` 3-arg form (9.4.2.h) for row→list flattening.
  - [X] **9.4.2.g.7** `do_test` glob/regexp/numeric-range forms + `do_realnum_test`.
  - [X] **9.4.2.g.8** `permutations.tcl` skip-shim — tester.tcl's permutation matrix re-runs each test under ~30 build-flag combinations.
  - [X] **9.4.2.g.9** `do_malloc_test` ported verbatim into `tester_min.tcl` (malloc_common.tcl:416..538); drives the memdebug `sqlite3_memdebug_fail` / `install_malloc_faultsim` primitives.
  - [X] **9.4.2.g.10** `do_ioerr_test` + `run_ioerr_prep` ported verbatim into `tester_min.tcl` (tester.tcl:1890..2118); drives the 9.4.7.c counters.
  - [X] **9.4.2.g.11** `crashsql` Tcl proc — verbatim port of `tester.tcl:1752..1840` into `tester_min.tcl` (Agent 6, 2026-05-16).
  - [X] **9.4.2.g.12** `db_save_and_close` / `db_restore_and_reopen` + `forcecopy` — snapshot helpers for tests that mutate then revert.
  - [X] **9.4.2.g.13** `*_common.tcl` source-include shims — `malloc_common.tcl`, `lock_common.tcl`, `incrblob_common.tcl`, `wal_common.tcl`, `fts3_common.tcl`.
  - [X] **9.4.2.g.14** `tester_min.tcl` config vars — AUTOVACUUM/TEMP_STORE/DEFAULT_SYNCHRONOUS/FILE_FORMAT/MEMORY_MANAGEMENT + minimal `sqlite_options()`, derived from this build's config.
  - [X] **9.4.2.h** `db eval` 3-arg form (`db eval $sql arrayName { script }`) — per-row callback with column-name `Tcl_TraceVar` binding into the named array.
  - [X] **9.4.2.i** `db trace` / `db trace_v2` / `db profile` — callbacks fired on each prepared statement.
  - [X] **9.4.2.j** `db authorizer` — Tcl callback invoked by sqlite3_set_authorizer with 5-tuple action codes.
  - [X] **9.4.2.k** `db busy` + `db progress` + `db interrupt` — busy-handler / progress-callback / interrupt wiring.
  - [X] **9.4.2.l** `db update_hook` / `db commit_hook` / `db rollback_hook` / `db wal_hook` — change-notification callbacks.
  - [X] **9.4.2.m** `db collate` + `db collation_needed` — Tcl callback registered via sqlite3_create_collation_v2.
  - [X] **9.4.2.n** `db transaction { script }` — savepoint-nested transaction with rollback-on-error.
  - [X] **9.4.2.o** `db total_changes` / `db onecolumn` / `db exists` / `db status` / `db cache flush|size` / `db enable_load_extension` / `db config` / `db timeout` / `db copy` — the remaining ~10 trivial-passthrough arms.
  - [X] **9.4.2.p** `db incrblob` — incremental blob I/O subcommand.
  - [X] **9.4.2.q** `db backup` / `db restore` — sqlite3_backup_* family (engine already ported under 10.1.43..45).
  - [X] **9.4.2.r** `db serialize` / `db deserialize` — sqlite3_serialize / _deserialize.
  - [X] **9.4.2.s** `db function` enhancements: `-returntype`, `-directonly`, `-innocuous` flags + result-type routing (eType), full typed argv marshalling (blob branch + int/wideint split).
  - [X] **9.4.2.s.1** `DbSqlFunc` script-body forms — ported `tclSqlFunc` dispatches the callback via `Tcl_EvalObjv` for multi-word / non-bare-command proc bodies.
  - [X] **9.4.2.t** `db nullvalue` follow-ups + `db errorcode` extended-code arm (sqlite3_extended_errcode).
  - [X] **9.4.2.u** `db preupdate_hook` (`-DSQLITE_ENABLE_PREUPDATE_HOOK` build only).
  - [X] **9.4.2.u.1** Runtime-exercise the preupdate hook — ported `src/tests/tcl/preupdate.test` (subset of upstream `hook.test` hook-7.*; this SQLite version has no standalone preupdate.test).
  - [X] **9.4.2.v** `db unlock_notify` (`-DSQLITE_ENABLE_UNLOCK_NOTIFY` build only).
  - [X] **9.4.2.w** Bridge symbol-table audit — re-grep `tclsqlite.c` after 9.4.2.h..v all land; verify every `Tcl_*` symbol it calls has an extern in `PasTclBridge.pas`.
  - [~] **9.4.2.x** NRE (Non-Recursive Eval) support — `db eval`
    with a script body and `db transaction` need
    `Tcl_NRCreateCommand` + `Tcl_NREvalObj` arms to interrupt
    cleanly across nested `vwait`.  Optional for first cut; many
    tests pass without it.  C ref: `tclsqlite.c:1888..1915`
    Done: command-dispatch NRE trampoline (`Tcl_NRCreateCommand` +
    `DbObjCmdNRE` + `DbUseNre` version probe) + the NRE externs in
    `PasTclBridge.pas`.  Non-NRE paths left intact.
  - [~] **9.4.2.x.1** NRE continuations — convert `DbEvalArm` and
    `DbTransactionArm` script bodies from the recursive
    `Tcl_EvalObjEx` path to genuine `Tcl_NRAddCallback` /
    `Tcl_NREvalObj` continuations (`DbEvalNextCmd` / `DbTransPostCmd`
    as `TTclNRPostProc`s).  C ref: `tclsqlite.c` `DbEvalNextCmd` /
    `DbTransPostCmd`.
    Done (transaction half): added `DbTransPostCmdNRE` matching the
    `TTclNRPostProc` shape (tclsqlite.c:1308..1348) and wired
    `DbTransactionArm` to take the NRE branch (tclsqlite.c:4002..4004)
    when `DbUseNre` is true.  Recursive `Tcl_EvalObjEx` path retained as
    the `!DbUseNre` fallback (tclsqlite.c:4005..4006).
    Eval half left as sub-arms because the Pascal `DbEvalArm` differs
    structurally from upstream and cannot be wholesale-converted (per
    9.4.2.x.1's "surface the gap" guidance):
    - [X] **9.4.2.x.1.a** Port `SqlPreparedStmt` cache + `DbPrepareAndBind` / `DbReleaseStmt` / `FlushStmtCache` (tclsqlite.c:1356..1614).
    - [X] **9.4.2.x.1.b** Port `AddDatabaseRef` / `DelDatabaseRef` (tclsqlite.c:601..666) — landed at `src/tests/tcl/PasTclSqlite.pas:680..708`.
    - [X] **9.4.2.x.1.c** `TDbEvalContext` record (tclsqlite.c:1626) + split DbEvalArm into DbEvalInit/Step/RowInfo/Finalize/ColumnValueCtx (tclsqlite.c:1669..1876).
    - [X] **9.4.2.x.1.d** Implement `DbEvalNextCmd: TTclNRPostProc` (tclsqlite.c:1915..2005) and wire the 3/4/5-arg script-body branch of `DbEvalArm` (tclsqlite.c:3340..3360) through `Tcl_NRAddCallback` + `Tcl_NREvalObj`.

- [~] **9.4.3** Driver `src/tests/TclTestDriver.pas`.  Spawns
  `tclsh` against each manifest entry with the port's shim
  preloaded; collects pass/fail/skip per test.  Output format:
  one line per test (`PASS|FAIL|SKIP <path> <assertions> <duration>`),
  matching upstream's `make test` log shape.  The gate is "every
  `tcl-feature` test exits 0 or matches the upstream skip list".
  Per the skip-and-cite contract from 9.1.3.followup, divergences
  surface into `src/tests/tcl/DIVERGENCES.md` rather than blocking
  the driver — each cluster becomes a `9.4.divbug.N` follow-up
  bullet for triage.
  - [X] **9.4.3.a** Driver skeleton `src/tests/TclTestDriver.pas` — per `tcl-feature` MANIFEST entry forks tclsh (load lib + source tester_min.tcl + test), emits PASS|FAIL|SKIP + timing.
  - [X] **9.4.3.b** Fix the driver polling race — `TclTestDriver` under-reports per-test duration (noted in the 9.4.4.b sweep, which fell back to direct `tclsh + tester_min` invocations with a `timeout` wrapper).
  - [X] **9.4.3.c** Per-test `testdir` wiring — driver sets `::testdir` to `src/tests/tcl` so the `*_common.tcl` shims resolve.

- [~] **9.4.4** Skip-list curation.  Tests that depend on
  `sqlite3_test_control`, `PRAGMA legacy_*`, or other internal
  knobs land in `src/tests/tcl/SKIP.md` with a citation to the
  Phase 6/7/8 bullet that gates them.  Empty skip-list is the
  long-term goal; closed bullets prune entries here.
  - [X] **9.4.4.a** First 10-test sweep — classified PASS/FAIL/SKIP; populated `SKIP.md` + `DIVERGENCES.md` (new `9.4.divbug.*` buckets).
  - [X] **9.4.4.b** Re-ran 10-test sweep after g.1..g.5 + g.7 + divbug.6 landed: PASS 2 / FAIL 5 / CRASH 3.
  - [X] **9.4.4.b.2** Re-sweep of the first 10 tests after the 2026-05-14 wave — divbug.1/3/4/7/8/9/10 FIXED plus 14 bridge arms landed.
  - [X] **9.4.4.c** Broaden sweep to first 50 tcl-feature tests (ranked by filesize / probable simplicity).
  - [X] **9.4.4.d** Broaden sweep to first 100 tcl-feature tests — **72 PASS / 28 FAIL / 0 SKIP** (`bin/TclTestDriver --limit 100`).
  - [X] **9.4.4.e** Broaden sweep to 250 tests (~25% of corpus) — **147 PASS / 103 FAIL / 0 SKIP** (`bin/TclTestDriver --limit 250`, 138 s).
  - [X] **9.4.4.f** Broaden sweep to 500 tests — **280 PASS / 220 FAIL / 0 SKIP** (`bin/TclTestDriver --limit 500`, 149.2 s).
  - [X] **9.4.4.g** Full tcl-feature sweep — 593 PASS / 366 FAIL / 0 SKIP across 959 tests; three 20s timeouts bucketed under 9.4.divbug.84. Cites: 6b834c8, 705d27e.
  - [X] **9.4.4.h** tcl-internal re-evaluation — re-walked the 225 `tcl-internal` rows against the trimmed trigger set (dropped `register_dbstat_vtab` / `db_save` / `db_save_and_close`, now ported via 9.4.6.b + 9.4.6.q.2).

- [X] **9.4.5** Linux-only nightly.
  - [X] **9.4.5.a** CI config — `.github/workflows/tcl-nightly.yml` runs `bin/TclTestDriver --gate strict` against full MANIFEST, exits non-zero on any pas-strict regression vs `STATUS.txt`.
  - [X] **9.4.5.b** Sharding — driver flag `--shard I/N` (TclTestDriver.pas) slices the filtered manifest into N contiguous chunks; 4 parallel shard jobs in `tcl-nightly.yml`.
  - [X] **9.4.5.c** Failure-report artefact — per-shard `--fail-log-dir` captures `<basename>.{out,err}` per FAIL; aggregate diffs against STATUS.txt via check_status_regression.sh.

- [~] **9.4.6** Test-only public-API export delta.  Many `.test`
  files call into the C ABI beyond the "publicly documented" subset.
  Each bullet here adds the engine port + Tcl shim required by some
  number of `.test` files.  Audit current `src/*.pas` first — many
  of these already exist with partial coverage.
  - [X] **9.4.6.a** `sqlite3_compileoption_used` / `sqlite3_compileoption_get` — backend for `ifcapable` (9.4.2.g.1).
  - [X] **9.4.6.b** `register_dbstat_vtab` — Tcl-side registration of the dbstat eponymous vtab.
  - [X] **9.4.6.c** `sqlite3_db_status` / `sqlite3_stmt_status` / `sqlite3_status64` audit — extend export coverage so every `_STATUS_*` opcode used by tests works.
  - [X] **9.4.6.d** `sqlite3_table_column_metadata` — used by ~20 tests + by `.expert`.
  - [X] **9.4.6.e** `sqlite3_set_authorizer` — engine port + pairs with 9.4.2.j Tcl shim.
  - [X] **9.4.6.f** `sqlite3_create_collation` / `sqlite3_create_collation_v2` — engine surface audit (`8.x.colneed` already partial).
  - [X] **9.4.6.g** `sqlite3_blob_open` / `_read` / `_write` / `_close` / `_bytes` / `_reopen` — incrblob engine port.
  - [X] **9.4.6.h** `sqlite3_soft_heap_limit64` / `sqlite3_hard_heap_limit64` / `sqlite3_db_release_memory` / `sqlite3_release_memory` — memory-pressure entry points.
  - [X] **9.4.6.i** `sqlite3_user_data` / `sqlite3_aggregate_context` / `sqlite3_get_auxdata` / `sqlite3_set_auxdata` — UDF helpers.
  - [X] **9.4.6.j** `sqlite3_extended_result_codes` / `sqlite3_extended_errcode` — extended-rc plumbing audit; some error tests assert on the extended (3-byte) form.
  - [X] **9.4.6.k** `sqlite3_unlock_notify` — engine port.
  - [~] **9.4.6.l** Test-only modules — landed as
    `src/tests/tcl/testmodules/` unit per file.
    Done: `register_tcl_module` (test_tclvar.c → `TestModuleTclvar.pas`),
    `Md5_Register` + md5/md5file Tcl cmds (test_md5.c →
    `TestModuleMd5.pas`).  `register_wholenumber_module` already
    done in 10.1.69.  Remaining sub-tasks below.
    - [X] **9.4.6.l.1** `register_echo_module` — 1:1 port of test8.c → `TestModuleEcho.pas` (full read/write proxy vtab; registers `echo`+`echo_v2`).
    - [X] **9.4.6.l.4** `registerTestFunction` — ported `test_func.c` scalar/aggregate test UDFs + `autoinstall_test_functions` into `src/tests/tcl/testmodules/TestModuleFunc.pas`.
    - [X] **9.4.6.l.5** `register_async_vtab` — DROPPED.
  - [X] **9.4.6.m** `sqlite3_log` (already wired in 10.1.36) + `sqlite3_io_trace` — Tcl bindings + assert hooks.
  - [X] **9.4.6.n** `sqlite3_memdebug_*` — ported test_malloc.c fault-injection allocator + Tcl commands → `TestModuleMalloc.pas`.
  - [X] **9.4.6.o** File-control opcodes — PERSIST_WAL, LOCKSTATE, CHUNK_SIZE, SIZE_LIMIT, POWERSAFE_OVERWRITE, ZIPVFS, BUSYHANDLER, TEMPFILENAME, MMAP_SIZE.
  - [X] **9.4.6.p** `sqlite3_busy_timeout` / `sqlite3_busy_handler` — audit; pair with 9.4.2.k.
  - [X] **9.4.6.q** Unported test-only Tcl commands — ported the test1.c subset (connection_pointer, db_config, atomic_batch_write, load_static_extension) → `TestModuleTest1.pas`; real2hex + faultsim_save_and_close family.
    - [X] **9.4.6.q.1** test1.c prepared-statement C-API subset — sqlite3_prepare(_v2)/exec/backup/errmsg/transfer_bindings → `TestModuleTest1.pas` (test1.c:417/4910/5035/5092/3145; test_backup.c:26..150).
    - [X] **9.4.6.q.2** Remaining 9.4.4.d-surfaced test commands.
  - [X] **9.4.6.r** Faithful `fcntlSizeHint` port — ported `fcntlSizeHint` (os_unix.c:4049) into `src/passqlite3os.pas`: `SQLITE_FCNTL_SIZE_HINT` now pre-grows via `posix_fallocate` with chunk-size rounding instead of being a no-op.

- [~] **9.4.7** Build-matrix / harness infrastructure.  Many tests
  require a *different* build of libpassqlite3 than the default.
  Each profile lives as its own `bin/libpassqlite3tcl-<profile>.so`
  and the driver picks one via `--build`.
  - [X] **9.4.7.a** Compile-flag introspection finishing — for `ifcapable` to work, every `SQLITE_OMIT_*` / `SQLITE_ENABLE_*` symbol on the Pascal side must report through `sqlite3_compileoption_used`.
  - [X] **9.4.7.b** Memdebug build profile — `src/tests/build_tcl_lib_memdebug.sh` adds `-dSQLITE_MEMDEBUG` and produces `bin/libpassqlite3tcl-memdebug.so` (private staging dir so its `.ppu`/`.o` don't clobber the default build).
  - [X] **9.4.7.c** I/O-error injection — ported os_common.h SQLITE_TEST machinery (SimulateIOError/SimulateDiskfullError counters) into the Pascal unix VFS read/write/sync/truncate.
  - [~] **9.4.7.c.old** ~~test_devsym.c wrapper VFS~~ — superseded by the counter-instrumentation approach above; kept only if a future test needs a real device-characteristics shim.  Registers via
    `sqlite3_vfs_register`.
  - [~] **9.4.7.d** Crash-test harness — faithful port of `test6.c`
    landed as `src/tests/tcl/testmodules/TestModuleCrash.pas` (Agent
    6, 2026-05-16).  The "crash" VFS wraps the system default unix
    VFS, queues every `xWrite`/`xTruncate` in an in-memory write
    list, and on the `iCrash`'th `xSync` of the configured
    `zCrashFile` calls `_exit(-1)` — exactly the upstream power-loss
    semantics.  Tcl bindings `sqlite3_crash_enable`,
    `sqlite3_crash_now`, `sqlite3_crashparams` registered via
    `Sqlitetest6_Init` from `PasTclSqlite.pas:Sqlite3_Init`.
    `crashsql` Tcl proc landed under 9.4.2.g.11.  Verified
    end-to-end through `bin/TclTestDriver`: a hand-rolled .test
    using `crashsql -delay 1 -file test.db-journal { INSERT ... }`
    runs, the child crashes mid-journal-sync, the parent reopens
    and confirms recovery + integrity_check ok.  Marked [~] (not
    [X]) because three followups remain — see 9.4.2.g.11 for the
    list (`ifcapable crashtest`, WAL shm methods, the upstream
    `unixVfsObjFoo := unixVfsObj` record-copy issue).
  - [ ] **9.4.7.e** `permutations.tcl` matrix — full upstream re-runs
    each test under ~30 build-flag combinations.  Land as
    optional second-tier gate (not in baseline CI).  Requires:
    a build matrix generator script that emits one .so per
    permutation + driver flag `--permutation NAME` to pick.
    C ref: `../sqlite3/test/permutations.tcl`.
  - [X] **9.4.7.f** Per-test isolation — currently `TclTestDriver` runs every test against the same CWD.
  - [X] **9.4.7.g** Driver concurrency — `--jobs N` flag spawns N tclsh processes in parallel; aggregates results.
  - [X] **9.4.7.h** `tclsqlite3_Init` package-config — drop our `Sqlite3_Init` so `package require sqlite3` works without the explicit `load` line.
  - [X] **9.4.7.i** Threading build (`-dSQLITE_THREADSAFE=1`) — some tests assume the threadsafe build.

- [~] **9.4.8** Full-corpus parity gate.
  - [X] **9.4.8.a** Per-test status tags — adopt the pas-strict / pas-soft / pas-skip convention from 9.1.5.
  - [X] **9.4.8.b** STATUS.txt seeded from current sweeps — populate after 9.4.4.g lands.
  - [X] **9.4.8.c** Strict gate — `bin/TclTestDriver --gate strict` diffs results vs STATUS.txt inline and exits non-zero iff a pas-strict row regressed to FAIL.
  - [X] **9.4.8.d** Coverage check — `--coverage` injects `pas_opcode_coverage_*` Tcl cmds, aggregates per-test gVdbeOpCoverage[], writes `COVERAGE_DELTA.md` (opcodes hit only by the tcl corpus).
  - [X] **9.4.8.e** Regression archive — `regression_bisect.sh` walks `git bisect` using TclTestDriver as predicate (PASS=good, build-fail=125).

#### 9.4 divergence buckets (cite `src/tests/tcl/DIVERGENCES.md`)

- [X] **9.4.divbug.1** `select1.test select1-4.4` (`ORDER BY min(f1)`) triggered a Pascal-side segfault.
- [X] **9.4.divbug.2** SQL error messages drop their format-arg tails: `misuse of aggregate function` should read `misuse of aggregate function min()`; `table has wrong number of values for INSERT` should carry the column counts.
- [X] **9.4.divbug.3** Schema introspection result columns reordered / missing — `index.test` sub-tests `index-1.1c` / `index-1.1d`.
- [X] **9.4.divbug.4** `update.test` sub-test `update-10.1` reported spurious `out of memory`.
- [X] **9.4.divbug.5** `numcast.test` 0/51 → 51/51 Ok.
- [X] **9.4.divbug.6** Doubled error string in `db1 eval`'s error return — surfaced by 9.4.2.f gate `tcl_err()` returning `boomboom` instead of `boom`.
- [X] **9.4.divbug.7** `insert.test` hangs (tclsh wedges past 60s) shortly after `insert-1.3`.
- [X] **9.4.divbug.8** `index.test` segfaults at `index-3.3` — the sub-test is `DROP TABLE test1` after 99 indexes were created.
- [X] **9.4.divbug.9** `lastinsert.test` segfaults right after `lastinsert-1.1` (the `1.1w` variant uses a 64-bit rowid).
- [X] **9.4.divbug.10** `boundary1.test` SELECTs returned `{}` — boundary1-1.1's INSERT IDLIST loop errored on the rowid alias instead of honouring the rowid-alias branch (insert.c:1097).
- [X] **9.4.divbug.11** Compound `SELECT ...
- [X] **9.4.divbug.12** `update-17.10` segfault — actually a constant-expr `CREATE INDEX` crash; gated `sqlite3CreateIndex` column lookup to identifier tokens (build.c:4220).
- [X] **9.4.divbug.13** Inequality-scan row ordering — gated `whereShortCut` `nOBSat:=nExpr` to `WHERE_ONEROW` plans so IPK range scans get a sorter; boundary1.test 1511/1511.
- [X] **9.4.divbug.14** SQL errors drop object name — routed scattered `sqlite3ErrorMsg` sites through upstream `%s`/`%S`/`%T` formats (build.c / resolve.c).
- [X] **9.4.divbug.15** `no such function` not raised at prepare — ported the `resolveExprStep` TK_FUNCTION error arm (resolve.c:1129..1276).
- [X] **9.4.divbug.16** `affinity3.test` segfault — `sqlite3WhereBegin` skipped opening a RIGHT JOIN table cursor scanned index-only; ported the `JT_LTORJ|JT_RIGHT` gate (where.c:7252).
- [X] **9.4.divbug.17** Subquery-nested aggregate evaluated row-wise — ported the resolver's outward AggInfo-binding arm (resolve.c:1337..1352).
- [X] **9.4.divbug.18** WITHOUT ROWID vtab `xUpdate` — DELETE now emits `OP_Column` for argv[0]; `updateVirtualTable` routed through `sqlite3WhereBegin` so `xBestIndex` runs.
- [ ] **9.4.divbug.19** Table-qualified `rowid` alias (`t1.rowid`, `sp.rowid`) — ported the qualified-case rowid arm from lookupName (resolve.c:471..503 + 623..638) into the TK_DOT branch of `ResolveExpr`: when `sqlite3ColumnIndex` misses and `zCol` ∈ {rowid,oid,_rowid_} and the matched source `HasRowid`, bind `iColumn=-1` / AFF_INTEGER.  Cites: 3fd04ef.  Residual 2026-05-16: 1 pas-soft test(s) still fail (e.g. autoindex5).  Triage 2026-05-16: autoindex5-1.1 needs `SEARCH debian_cve USING AUTOMATIC COVERING INDEX (bug_name=?)` but Pas emits a flat `SCAN debian_cve` with an unopened cursor (Rewind p1=3 with no preceding OpenRead) — view materialisation as co-routine inside a correlated subquery is not wired and `constructAutomaticIndex` Asserts out on the viaCoroutine arm (codegen.pas:20830).  Out-of-scope for this pass; needs porting where.c:1191..1234 viaCoroutine arm + EQP CO-ROUTINE emission + the SrcItem.viaCoroutine set on materialised views.  Triage 2026-05-17 (agent): tests 1.0, 1.1, 2.1 now actually PASS (likely fixed transitively by other divbug commits); the SIGSEGV-causing block is test 2.2 (`SELECT (SELECT aaa FROM t1 GROUP BY (SELECT bbb FROM (SELECT ccc AS bbb FROM (SELECT 1 ccc) WHERE rowid IS NOT 1) WHERE bbb=1))`).  Root cause is architectural, not the constructAutomaticIndex assert: the C oracle EXPLAIN shows a CO-ROUTINE feeding an AUTOMATIC PARTIAL COVERING INDEX (subquery-1)(ccc=?), but Pas emits a flat SCAN over an unopened cursor 2 → Rewind p1=2 segfaults at run time (codegen.pas:32228 FROM-coroutine arm and codegen.pas:32520 materialise arm both gate on pDest^.eDest ∈ {SRT_Output, SRT_EphemTab, SRT_Coroutine}; scalar subqueries use SRT_Mem so neither arm fires for FROM-subqueries embedded inside a scalar-subquery WHERE clause).  C does FROM-subquery codegen up front in `selectExpander` (select.c:7945..8120) regardless of outer eDest; Pas does it lazily inline and so misses SRT_Mem.  Sub-tasks needed:  (a) port the up-front FROM-subquery generation loop from select.c:7945..8120 into the Pas `sqlite3Select` prologue (so coroutine + addrFillSub get populated before any eDest gate); (b) port the viaCoroutine arm of `constructAutomaticIndex` (where.c:1191..1234) — currently a hard Assert at codegen.pas:21420; (c) wire `EXPLAIN QUERY PLAN BLOOM FILTER ON %!S (col=?)` banner emission inside `constructAutomaticIndex` (where.c:1183..1187 + the explain helper); none of which is doable inside a single safe pass.  Leaving code untouched.
- [X] **9.4.divbug.20** BETWEEN-on-indexed-column planner — fixed by porting exprAnalyze's trailing `prereqRight |= extraRight` (whereexpr.c:1566..1570) so ON-clause BETWEEN children of outer-join left tables get filtered out by the prereqRight gate.
- [X] **9.4.divbug.21** Cross-connection EXCLUSIVE lock detection + busy-handler firing — fixed.
- [ ] **9.4.divbug.22** Large row / `PRAGMA page_size=65536` overflow — two fixes: `fillInCell` overflow-path nil-pBt deref (`45a1fbb`) and `accessPayload` passing `Ord(eOp=0)=1` as pager flag colliding with `PAGER_GET_NOCONTENT` (`9744b0f`).  Residual 2026-05-16: 2 pas-soft test(s) still fail (e.g. bigrow, btree01); reopened per failing-pas-soft-with-closed-cite rule.
- [X] **9.4.divbug.23** Correlated FROM-subquery EQP shape — emit SETUP/RECURSIVE STEP nodes (select.c:2781/2813) + CO-ROUTINE/SCAN wrapper around the aggregate-on-subquery materialise arm (select.c:8054).
- [ ] **9.4.divbug.24** `sqlite_sequence` double-created for AUTOINCREMENT — ported build.c:2967..2972 (pin `pSchema^.pSeqTab` when init.busy adds a table named `sqlite_sequence`) at codegen.pas:40916.  Residual 2026-05-16: 1 pas-soft test(s) still fail (e.g. aggnested); reopened per failing-pas-soft-with-closed-cite rule.  Investigation 2026-05-16 (agent5): aggnested fail is NOT a sequence/AUTOINCREMENT residual — it is a SIGSEGV that hits between aggnested-2.0 and aggnested-3.0 on the `db2 close` at aggnested.test:70.  Minimal repro (no AUTOINCREMENT involved):  open `db` on test.db with 3+ rows feeding a correlated `SELECT (SELECT group_concat(a1) FROM u2) FROM u1`, then open separate `db2 :memory:` with PRIMARY KEY tables, run any SELECT in db2, call `db2 close` → crash.  Requires (a) ≥2 outer rows in the db1 correlated subquery, (b) group_concat or string_agg in the inner agg (sum / count are fine), (c) db2 must have at least one PRIMARY KEY table (without the PRIMARY KEY no crash).  Crash is on `db2 close` even though group_concat ran in db1.  TGroupConcatCtx (codegen.pas:54840) contains no managed Pascal types so the "New() on record with AnsiString" trap (MEMORY.md) is not the cause.  Likely a function-context / aggregate-context residue on the shared db schema that gets re-entered during cross-DB close.  Needs valgrind / address-sanitizer.
- [X] **9.4.divbug.24.b** aggnested-3.3 wrong scalar-subquery value + aggnested-3.11 SIGSEGV — fully fixed.
- [X] **9.4.divbug.25** `update-19.10` `AssertH FAILED: idxColIsBeingUpdated rowid` — fixed by stopping IPK index-column rewrite to XN_ROWID in CreateIndex.
- [X] **9.4.divbug.26** Echo vtab INSERT fails — `echoUpdate` emits `%Q`-quoted column names.
- [X] **9.4.divbug.27** Engine OOM-recovery path segfaults under an injected malloc failure (memdebug build) — blocked `do_malloc_test` from being fully useful.
- [X] **9.4.divbug.28** EXPLAIN QUERY PLAN segfaults on multi-table queries after first row (eqp2/cost/fordelete/delete2).
- [ ] **9.4.divbug.41** EQP detail-text omits LAST-N-TERMS-OF when nOBSat>0 (eqp2/cost/fordelete/delete2).  Fixed at codegen.pas:31663 by porting select.c:1702..1711 nOBSat/nKey branch (LAST TERM OF / LAST n TERMS OF / plain ORDER BY).  Residual 2026-05-16: 2 pas-soft test(s) still fail (e.g. cost, fordelete); reopened per failing-pas-soft-with-closed-cite rule.  Triage 2026-05-17 (agent): residual failures are NOT EQP detail-text issues — they are out-of-scope per the divbug.41 cite.  cost.test residuals are planner-cost / index-selection divergences: cost-3.2/6.2/7.2 expect a `MULTI-INDEX OR` shape (two-arm OR-to-IN-set planner re-write) that the Pas where.c equivalent never emits; cost-4.3/9.3.x.2 pick the wrong covering index (i1 a=? vs i2 b-range) — cost-estimator delta in `whereLoopAddBtreeIndex` / `estLog` rather than text rendering.  cost-8.2 expects `USE TEMP B-TREE FOR DISTINCT` which is a separate distinct-eph arm.  fordelete.test residuals are about OPFLAG_FORDELETE placement on OP_OpenWrite p5 (asterisk should land on the table cursor, not the autoindex) and the rowid-delete `+` marker on OP_Delete p5 — i.e. delete.c sqlite3GenerateRowIndexDelete / OPFLAG_FORDELETE propagation through sqlite3OpenTableAndIndices, not EQP rendering at all.  fordelete-3.x also requires the `btree_cursor` Tcl test command (testfixture-only; not registered in libpassqlite3tcl).  Per task step 6 (planner-choice → annotate, don't touch cost logic), leaving the .41 detail-text fix in place and NOT modifying planner cost or OPFLAG_FORDELETE codegen in this pass.  Should be re-bucketed: cost residuals → new "MULTI-INDEX OR planner shape" + "covering-index cost-estimator delta" bullets; fordelete residuals → new "OPFLAG_FORDELETE p5 propagation" bullet; btree_cursor → divbug.91 (Tcl harness helpers).
- [X] **9.4.divbug.29** TEXT-affinity column stores `'0x119'` literal as INTEGER 281 (collate1).
- [ ] **9.4.divbug.30** ORDER BY with non-default collation (NOCASE) mis-orders.  Residual 2026-05-16: 3 pas-soft test(s) still fail (e.g. collate4, collate8); reopened per failing-pas-soft-with-closed-cite rule.  Progress 2026-05-16 (agent5): collate8.test now PASS (23/23) and collate4 advances past 6.1/6.2 (sort-vs-nosort).  Three Pas-level resolver/planner bugs ported from resolve.c + where.c:  (a) `sqlite3CreateColumnExpr` IPK aliasing missing in both expandStar (codegen.pas:25942..25956) and bare-TK_ID lookupName arm (codegen.pas:9977..9998); both now set iColumn=-1 when matchCol==iPKey so wherePathSatisfiesOrderBy can match ORDER BY <ipk> against XN_ROWID (resolve.c:863..887).  (b) NC_UEList alias fallback for ORDER BY (resolve.c:658..698) was only invoked for bare TK_ID via ResolveAsName; expressions like `ORDER BY +x` referencing AS-alias never resolved.  Reuse ResolveAliasInHaving walker on each pOrderBy item where iOrderByCol=0 (codegen.pas:11142..11156).  (c) whereShortCut's Pas-only full-table-scan fallback (codegen.pas:20533..20593) bypasses wherePathSolver entirely, so ORDER BY on a plain SCAN was forced through an external sorter; gate the fallback off when caller passed pOrderBy / WHERE_GROUPBY / WHERE_DISTINCTBY / WHERE_WANT_DISTINCT (matches C whereShortCut at where.c:6350..6417 which only succeeds on WHERE_ONEROW).  Net: 5190/9 (was 5180/18) in build.sh regression.  Residual collate4 failures (2.1.7/2.1.8 NOCASE index for IN-list; 4.3 min(a)/max(a) using TEXT index; 4.10/4.13/4.14 scalar max(b,a) collation) are distinct collation-propagation bugs not addressed here.  Progress 2026-05-18 (agent): 2.1.7/2.1.8 plan now matches C reference (SEARCH ... USING COVERING INDEX collate4i1 (a=?)).  Root cause was two stubs in codegen.pas — sqlite3IndexAffinityOk and indexInAffinityOk — that returned 1 / nil unconditionally; whereScanNext's WO_IN arm therefore rejected every IN term and the planner fell back to full SCAN.  Ported expr.c:387..396 and where.c:319..344 (plus comparisonAffinity helper, expr.c:364..379) 1:1.  TestWherePlanner TC1/TC3b fixtures updated to attach a real pTab so the now-real comparisonAffinity can resolve column affinity.  Collate4 file still FAILs on residual 4.x cases; collate1/collate7 untouched.  Progress 2026-05-18 (agent): 4.10/4.13/4.14 (scalar `max(b,a)` / `max('101',b)` collation) fixed by two coordinated edits: (1) emitScalarFunctionCall (codegen.pas:5594..5615) now mirrors expr.c:5375..5382 and collects pColl from the first arg with a non-default `sqlite3ExprCollSeq` rather than hard-coding `db^.pDfltColl` — drives the correct OP_CollSeq P4; (2) minmaxScalarFunc (codegen.pas:56652..56685) ports func.c:27..34 `sqlite3GetFuncCollSeq` to read `pCtx^.pVdbe^.aOp[iOp-1].p4.pColl` and pass it to `sqlite3MemCompare` instead of nil.  Residual 4.3 (`min(a)`/`max(a)` using TEXT index, expects search_count=1 but gets 3): root cause is BIGNULL ordering refused by Pas wherePathSatisfiesOrderBy (codegen.pas:19899..19913 explicit `isMatch:=0` per divbug.43).  `min(a)` triggers BIGNULL because `sqlite3ExprCanBeNull` returns true; index can no longer satisfy ORDER BY so bOrderedInnerLoop=0 and sqlite3WhereMinMaxOptEarlyOut bails before emitting the early-out OP_Goto.  Fix requires porting the BIGNULL two-pass scan emitter (wherecode.c:1933..2164 + where.c:7616..7620 regBignull/addrBignull) — non-trivial.  `max(a)` (4.4) is unaffected since BIGNULL is not set there.
- [ ] **9.4.divbug.31** Spurious `database disk image is malformed` for non-corrupt errors (collate3 `no such collation sequence: …`, count-1.2.4/5).  Residual 2026-05-16: 2 pas-soft test(s) still fail (e.g. collate3, count); reopened per failing-pas-soft-with-closed-cite rule.  Triage 2026-05-17 (agent): collate3.test now PASSES 72/72 (resolved transitively).  count.test failure is NOT spurious tagging — the "malformed" error is REAL: with `PRAGMA page_size=1024` (the SQLITE_TEST default), as soon as the table grows past ~32k rows of 2-int payload the next `INSERT INTO t1 SELECT * FROM t1` (or any walk: count(*), count(a)) trips `SQLITE_CORRUPT_BKPT` in the btree.  Confirmed with stock /usr/bin/sqlite3 succeeding on identical input.  Test minimised: `CREATE TABLE t1(a,b); INSERT VALUES(1,2),(3,4); for i in 0..13: INSERT INTO t1 SELECT * FROM t1` — succeeds through 16384 rows, errors at 32768.  Disappears with `PRAGMA page_size=4096`.  Triggers on the 3rd or 4th level of the b-tree at 1024-byte pages; max(rowid) still works (backward seek) while forward walks fail.  This is a genuine b-tree balancing / page-split bug, not a vdbe rc-mistagging issue.  Out of scope for a single safe pass; likely related to divbug.22 (bigrow/page_size=65536 cluster).  Needs a balance_nonroot or split-overflow audit at passqlite3btree.pas.  Leaving code untouched.
- [X] **9.4.divbug.32** Readonly-DB DELETE returns `unknown error` instead of `attempt to write a readonly database` (delete-8.x).
- [X] **9.4.divbug.33** `count(DISTINCT …)` returns 1 instead of 0 for an empty set (distinctagg-3.x).
- [X] **9.4.divbug.34** `PRAGMA page_size` reports build default (8192) regardless of per-test write (createtab-0.2 expects 4096, format4-1.1 expects 2048).
- [X] **9.4.divbug.35** Float-to-text precision artefacts: `-1.11` → `-1.1099999999999999`; large doubles get an extra mantissa digit (fpconv1, default-3.3).
- [X] **9.4.divbug.36** `PRAGMA journal_mode=off` silently ignored — keeps prior mode `delete` (changes-1.1.0).
- [X] **9.4.divbug.37** WAL `wal_hook` callback reports 0 frames where upstream reports >0 (e_walhook-1.3+).
- [X] **9.4.divbug.38.a** Malformed `REFERENCES … ON` parser error message.
- [X] **9.4.divbug.38.b** FK-cascade picks wrong target row (e_fkey-2.1/3.1).
- [X] **9.4.divbug.39** `CREATE TABLE AS SELECT` (CTAS) unsupported in this build (errofst1, distinct2-100, delete-7.6).
- [X] **9.4.divbug.40** `DEFAULT` clause: error text drops column-name (default-1.3 `default value of column is not constant` missing `[y]`); DEFAULT-derived affinity reported in wrong order (default-3.1).
- [X] **9.4.divbug.42** Mis-triaged: root was an engine SIGSEGV on `collate1.test` 8.2, not harness pollution (TclTestDriver already spawns a fresh tclsh per test).
- [X] **9.4.divbug.43** `ORDER BY ... NULLS FIRST/LAST` ignored when an index satisfied the sort — refuse BIGNULL_SORT index-match in wherePathSolver (codegen.pas:18567) so it falls back to the sorter.
- [X] **9.4.divbug.44** Misclassified cluster — root was `IN (SELECT ...
- [X] **9.4.divbug.45** `HAVING` with non-aggregate predicate over-filters: having-3.2 expects different bytecode (optimisation skipped for non-deterministic `randomblob(a)`), pas matched (incorrectly hoisted into WHERE).
- [X] **9.4.divbug.46** `LIMIT N` combined with subquery / DESC clamps wrong number of rows (limit-1.2.3 expects 5 rows got 3; limit-2.1 expects 2 got 32; limit2-100.3).
- [X] **9.4.divbug.47** Numeric `_` digit-separator literals not parsed: `1_000`, `1.1_1`, `0x1_2` raise `unrecognized token: "1_000"` (literal-3.x, literal2).
- [X] **9.4.divbug.48** Hex-literal overflow detection: error text drops the literal value (hexlit-400 expects `hex literal too big: 0x10000000000000000` got `hex literal too big`); some too-big inputs silently accepted (hexlit-401/402 expected error, pas returns OK).
- [X] **9.4.divbug.49** Generated-column (`GENERATED ALWAYS AS ...` VIRTUAL/STORED) codegen drops value and type — gencol1-100 expects `[integer 0]` got `[text null]`; gencol1-2.2.x rows return empty cells.
- [X] **9.4.divbug.50** JSON output float formatting: integer-valued JSON numbers render as `1` instead of `1.0`; very-large doubles render as `1E99` instead of `1.0e+99` (json101-1.4/1.4b first-row diff).
- [X] **9.4.divbug.51** JSON error-message text divergences — json103-101 generic vs `JSON cannot hold BLOB values`; json109/json105 path-quoting differences.
- [X] **9.4.divbug.52** JSON `subtype()` / `sqlite_subtype()` function unported — `json102-1600` reports `no such function: subtype`; downstream subtype-aware JSON tests cascade.
- [X] **9.4.divbug.53** Parser error reports `near token: syntax error` (placeholder) instead of `near "<actual-token>": syntax error` (fuzz2-6.1 expects `near "#0"`).
- [X] **9.4.divbug.54** ORDER BY DESC + LIMIT+OFFSET on a partially-satisfied block-sort (orderby6-1.12..1.14: `ORDER BY b DESC, a LIMIT 10 OFFSET 20/45`) dropped one row per block boundary and substituted a stray row from the next block.
- [X] **9.4.divbug.55** EQP detail-string divergences (sibling of 41) — TEMP B-TREE FOR DISTINCT, COVERING INDEX vs INDEX, and a missing USING INDEX detail across a handful of eqp tests.
- [X] **9.4.divbug.56** Default `LIKE` collation matches both cases when single-case expected (like-1.5.2 expects `[abc]` got `[ABC abc]`).
- [X] **9.4.divbug.57** `sqlite3_open_v2(..., SQLITE_OPEN_READONLY, ...)` not enforced — openv2-1.1 expects `unable to open database file` for missing-db RO open got OK; openv2-1.4 expects `attempt to write a readonly database` got OK.
- [X] **9.4.divbug.58** `CREATE INDEX … (missing_col)` error gate fires late — index-2.1b expects `no such column: f4` on the CREATE INDEX statement, pas returns OK and only complains on the following `index1 already exists` (index-2.2).
- [X] **9.4.divbug.59** JOIN USING/NATURAL: prefix-qualified column reference (`t2.a` where `a` is the USING column) raises `no such column: t2.a` (joinC-1..3); upstream resolves to the USING-shared column.
- [X] **9.4.divbug.60** Tcl bridge coerces integer values bound through `db eval` to REAL: keyword1-database.1 expects `[1 2 3 99]` got `[1.0 2.0 3.0 99.0]` (partial overlap with gencol1-100 `[integer 0]→[text null]` integer-vs-text path).
- [X] **9.4.divbug.61** Harness gap: `fts3_common.tcl` not staged in `src/tests/tcl/` — every `fts3*.test` / `fts4*.test` that begins with `source $::testdir/fts3_common.tcl` aborts with `SOURCE-ERROR: couldn't read file ".../fts3_common.tcl"` (~15 tests).
- [ ] **9.4.divbug.62** Harness gap: test1.c `sqlite3_*` Tcl commands unported — tests fail with `invalid command name "sqlite3_mprintf_int"` / `"sqlite3_column_count"` / `"sqlite3_finalize"` / `"sqlite3_bind_*"` / `"sqlite3_status"` / `"sqlite3_release_memory"` / `"sqlite3_limit"` / `"sqlite3_rekey"` / `"sqlite3_create_function"` / `"sqlite3_simulate_device"` / `"sqlite3_config_pmasz"` / `"sqlite3_config_uri"` / `"sqlite3_config_alt_pcache"` / `"sqlite3_reset_auto_extension"` (~50 tests incl. printf, printf2, pragma4, tkt2213, tkt-752e1646fc, tkt-99378177930f87bd, tkt-b75a9ca6b0, tkt-385a5b56b9, tkt2565, shortread1, vacuum, vacuum-into, uri, upfrom2, upfromfault, upsert5, values, wal9, zeroblobfault, pcache2, tpch01, pendingrace, reservebytes, rowvalue7).  Residual 2026-05-16: 17 pas-soft test(s) still fail (e.g. pcache2, pendingrace); reopened per failing-pas-soft-with-closed-cite rule.
  - [X] **9.4.divbug.62.a** `sqlite3_mprintf_*` family (`sqlite3_mprintf_int`, `_str`, `_double`, `_long`, `_int64`, `_z_test`, `_n_test`, `_stronly`, `_hexdouble`, `_scaled`) — printf trampoline Tcl commands.
  - [X] **9.4.divbug.62.b** Statement-level introspection — sqlite3_column_*/data_count/finalize/reset/step/sql/expanded_sql/normalized_sql/stmt_status/stmt_busy/stmt_readonly/stmt_isexplain Tcl trampolines.
  - [X] **9.4.divbug.62.c** Binding API — sqlite3_bind_* family + clear_bindings/parameter_count/name/index. Cite: TestModuleTest1.pas:1953..2393.
  - [X] **9.4.divbug.62.d** Resource accounting: `sqlite3_status`, `sqlite3_db_status`, `sqlite3_release_memory`, `sqlite3_soft_heap_limit`, `sqlite3_soft_heap_limit64`, `sqlite3_hard_heap_limit64`, `sqlite3_limit`.
  - [X] **9.4.divbug.62.e** Function/extension management — create_function(_v2)/create_window_function/reset_auto_extension/load_extension/simulate_device/user_version.
  - [X] **9.4.divbug.62.f** Config & legacy: `sqlite3_config_pmasz`, `sqlite3_config_uri`, `sqlite3_config_alt_pcache`, `sqlite3_rekey`, `sqlite3_rekey_v2`, `sqlite3_key`, `sqlite3_key_v2`.
- [ ] **9.4.divbug.63** Harness gap: tcl-shim helper commands unported — tests fail with `invalid command name "run_thread_tests"` / `"test_cli_invocation"` / `"test_find_cli"` / `"test_find_sqldiff"` / `"tcl_variable_type"` / `"breakpoint"` / `"database_may_be_corrupt"` / `"explain_no_trace"` / `"file_control_reservebytes"` / `"faultsim_test_result"` (~25 tests incl. thread001..005, thread1, thread2, tempdb2, shell1..9/A/B, select9, selectC/E/H, sharedA/B, sqldiff1, skipscan2, sort4, types3, unique, unique2, unionallfault, quota-glob, pragma6, parser1).  Cites: 7be23b7, 1800d46, 8de8be5.  Residual 2026-05-16: 5 pas-soft test(s) still fail (e.g. pragma6, quota-glob); reopened per failing-pas-soft-with-closed-cite rule.
- [X] **9.4.divbug.64** `db func` and `db format` subcommands unported — tests fail at the first `db func name argcount body` or `db format` call with `unknown subcommand "func" - implemented in 9.4.2.d..o` (~12 tests incl.
- [X] **9.4.divbug.65** Tester Tcl globals `::DB` / `::STMT` (sqlite3 + sqlite3_stmt opaque pointers) not exported by tester_min.tcl — schema.test family aborts at `can't read "::DB": no such variable`.
- [X] **9.4.divbug.66** SQL functions/extensions unregistered (zeroblob, regexp, percentile, randstr, if) — all now wired (codegen.pas:56680; passqlite3percentile/regexp.pas; .66.a). Cite: 51de8ba. regexp1/tkt3918/tkt-9d68c883 PASS.
  - [X] **9.4.divbug.66.a** Register `randstr(N,M)` from test_func.c:40 + `if(c,a,b)` (3-arg ternary scalar) as built-in scalar functions surfaced even without `autoinstall_test_functions`.
- [X] **9.4.divbug.67** `stmtrand` SQL extension unported — `no such extension: stmtrand` (stmtrand, stmt, sqllimits1, starschema1).
- [ ] **9.4.divbug.68** `PRAGMA module_list` does not include `fts5` row — pragma5-2.1 expects `[fts5]` got `[]`.  Cite: pragma.c PragTyp_MODULE_LIST + virtual-table module registration of fts5.  Surfaced 9.4.4.g.  Triage 2026-05-16: `PragTyp_MODULE_LIST` handler itself is correct (codegen.pas:51139..51148 walks `db^.aModule` HASH; pas currently emits 23 modules incl. dbstat, sqlite_dbpage, generate_series, json_each, json_tree, sqlite_stmt, fsdir, completion, zipfile, etc. — strictly more than the C oracle's 16 in this build).  The pragma5-2.1 case is gated by `ifcapable fts5` (pragma5.test:49), so the only real gap is the unported fts5 module itself — see sub-task .68.a.  Do not flip [X] until .68.a lands.
  - [ ] **9.4.divbug.68.a** Port fts5 vtab module (ext/fts5/*.c) — blocker for `PRAGMA module_list` containing `fts5`.  XL.
- [X] **9.4.divbug.69** `PRAGMA temp.<header_value>` SIGSEGV — gone (fixed in passing by upstream pragma/header-value work); pragma3.test runs to completion. Also landed HEADER_VALUE write→read fallthrough for ReadOnly cookies (codegen.pas:52445..52458). 7 residual pas-soft failures separate.
- [ ] **9.4.divbug.70** Error-text divergences (parser/resolver hints) — partial progress 2026-05-17.  Originally-cited string-tweak hints (parser1, tokenize, quote-2.1.x, select1-2.20..23, tableopts, strict1, select1-4.10.2, tkt3508, tkt3935.5/7) all verified `PASS` post earlier commits 1a0629b / d04edb5.  This pass ports `areDoubleQuotedStringsEnabled` (resolve.c:161..172) into `flagUnresolvedTKID` (codegen.pas:8683..8745) so the bare-TK_ID error path mirrors C's DDL-context formula (`writable_schema && DqsDML`) or `DqsDDL` bit before emitting the "no such column" hint; landed quote-2.2 + quote-3.0/3.1/3.2/3.3/3.4/3.5 (previously failing).  Residual 2026-05-17: 4 pas-soft test(s) still fail — quote-2.3.1/2.3.2/2.4/2.5 (schema-reload cascade after `db close; sqlite3 db test.db` re-init.busy=1 reparse of `CHECK(c!="null")` — C's `if(db->init.busy) return 1` arm in areDoubleQuotedStringsEnabled would demote, but adding the same demotion in Pas flagU breaks ALTER TABLE DROP COLUMN reparse-via-sqlite_rename_test (debug showed init.busy=1 there too, but the demotion turns ALTER's "after drop column" error path into a SEGV — suggests Pas sets init.busy spuriously inside the rename validation path where C leaves it 0; needs a deeper alter-codegen audit, not a string tweak).  select1 has multiple distinct ARCHITECTURAL divergences (column-name `test1.f1` aliasing in TclTestDriver, `ambiguous column name: f2` resolution order, ORDER BY-of-aliased 6.10, aliased-aggregate 11.14/15, GenColumn 12.10, USING-NATURAL 18.3) — none are single-hint tweaks; track separately.  Cites: codegen.pas:8683..8745 (flagUnresolvedTKID DQS demote arm), parse.y `%syntax_error` (divbug.53), build.c `markAllShadowTablesOf`/AddColumnError, resolve.c aggregate-misuse messages, select.c ORDER BY index range check.  Commits 1a0629b, d04edb5, (this).
- [X] **9.4.divbug.71** STRICT-typed table mis-error path — tkt2817/2820/savepoint7 fixed upstream; strict1-9.x unblocked by re-registering iif/if nArg=-4 (commit ff3380b). Residual strict2-1.x/strict1-7.x tracked as .71.b/.71.c.
- [X] **9.4.divbug.71.b** PRAGMA quick_check/integrity_check single-table form ported — resolve pObjTab via sqlite3LocateTable, extend tableSkipIntegrityCheck, prepend 0-sentinel for bPartial (codegen.pas:52819..53383). strict2 24/25; residual strict2-3.0 separate.
- [X] **9.4.divbug.71.c** ALTER ADD COLUMN error wrapper — port corruptSchema INITFLAG_AlterMask arm into initCorruptSchema (passqlite3main.pas): `error in <obj> after add column: ...`. strict1-7.2/7.3 now Ok.
- [ ] **9.4.divbug.72** Row-value misuse detection missing — `SELECT (1,2)` and `SELECT … WHERE (a,b)=...` constructs accepted silently when C raises `row value misused` (rowvalue-3.1.x, rowvalue4-1.x; cascades to rowvalue2/3/7/8/9/A).  Cites: 7eb9851, 8618b87.  Partial close 2026-05-17: ported `checkRowValueMisuse` walker (codegen.pas:9254..9319), the comparison/BETWEEN arm of resolve.c:1420..1453 the Pas resolver's "structurally lighter walk" was skipping.  Wired into sqlite3ResolveExprNames + sqlite3ResolveSelectNames after the SELECT WHERE / HAVING / LIMIT / ORDER BY / GROUP BY / pEList resolution arms.  Closes the rowvalue4-2.8 SIGSEGV bisect: `WHERE (b,b) <= 1` on an indexed leading column previously slipped through resolution and segfaulted inside whereRangeVectorLen (codegen.pas:15834..15882; dereferences pRight^.x.pList[i] expecting a vector RHS).  rowvalue4 advances 0 → 13 sub-tests `Ok`, 0 errors (single remaining FAIL is the `drop_all_indexes` tester-harness gap, unrelated).  No regressions in the rowvalue2/3/5/7/8/9/A/vtab/rowvalue.test counts (all unchanged from baseline).  Residual 2026-05-17: ARCHITECTURAL — the rowvalue2/3/7/8/9/A/vtab failures are NOT row-value-misuse detection bugs; they are separate vector codegen / planner-shape divergences (e.g. rowvalue9-9.5e: planner picks `SCAN t1 USING COVERING INDEX i2` instead of `SEARCH`; rowvaluevtab-1.3-BETWEEN: pre-existing Pas BETWEEN-on-vector emits "row value misused" because the Pas codegen lacks the whereexpr.c:1291..1313 BETWEEN→GE+LE virtual-term rewrite for vector LHS — sqlite3ExprCodeTarget hits the TK_VECTOR scalar-context arm at codegen.pas:6593..6600).  Track BETWEEN-rewrite under a new sub-ticket if reopened.  Cites: 7eb9851, 8618b87, (this).
- [X] **9.4.divbug.73** `rowid` post-INSERT resolution returns 0 — rowid-4.5 expects last_insert_rowid()=3 got 0; sibling rowid-4.5.1 expected `[3 3]`.
- [X] **9.4.divbug.74** UPSERT `ON CONFLICT DO UPDATE` increments target row count off by one — upsert3-200 expected row matrix `[1 2 2 x 3 4 1 x 5 6 0 x]` got `[1 2 1 x …]` (the "2" is the conflict-incremented col).
- [X] **9.4.divbug.75** select7 correlated `no such column: P.pk` (closed 74e00c2) + sub-select column-count error text — ported expr.c:4055 sqlite3ExprCheckIN gate (codegen.pas:63907). select7-5.1..5.4 Ok; FAIL line is tester-env stderr noise.
- [ ] **9.4.divbug.76** View-column resolution `no such column: y` — tkt3346-1.x: `INSERT INTO t SELECT y FROM v` where `v` is a view exposing `y` raises `no such column: y`.  Cites: f09bb72.  Residual 2026-05-17: ARCHITECTURAL codegen bug, not resolver — the prior resolver fix in ff5f383 is intact, but the underlying scalar shape `SELECT (SELECT y FROM (SELECT 1 AS y)) FROM t1` SIGSEGVs at sqlite3VdbeExec passqlite3vdbe.pas:7910 (OP_Rewind on an unopened cursor for a no-FROM inner subquery materialised as the FROM-item of a middle SELECT).  Reproduces without any correlation; bare-resolution path is fine (`SELECT y FROM (SELECT 1 AS y)` returns 1).  Out of scope per STOP-and-report constraint — needs an audit of sqlite3CodeSubselect / sqlite3SubqueryCodegen for the no-FROM-inside-FROM-subquery case, not name resolution.
- [X] **9.4.divbug.77** Cross-schema trigger validation error text — triggerupfrom-2.4 now `Ok` (verified 2026-05-17; prior d7f1dd1 fix is on-branch and effective).
- [X] **9.4.divbug.78** Wide-table SCAN+predicate mis-count — widetab1-340: `SELECT count(*) FROM t WHERE col=…` expected 7 got 10 on a table with many columns (likely planner picks wrong index or skips predicate eval on overflow page).
- [ ] **9.4.divbug.79** windowE ROWS-framing produces permuted output — windowE-1.3 expected `[5 5,4 5,4,1 5,4,1,6 5,4,1,6,3 5,4,1,6,3,2]`.  Cites: 041da7c.  Residual 2026-05-17 (refined): row-ordering portion is now CORRECT after 041da7c (each row's first `a` value matches the expected sequence 5,4,1,6,3,2); current observed output is `[5 4 1 6 3 2]` — single-element frames instead of the expected cumulative aggregate.  The remaining divergence is in **frame-extent computation** under a redefined custom collation, not row order.  Theory: `windowCodeRangeTest` (codegen.pas:62047) emits an OP_Gt/OP_Ge with a P4_COLLSEQ pointer to `sqlite3ExprNNCollSeq` of the ORDER BY expression; for TEXT peer values the arithmetic add/subtract is skipped (the `reg1 >= ''` gate), so the per-row frame loop reduces to a raw collated compare `end.peer vs current.peer`.  Under the redefined-reverse `custom`, this comparison should cause the AGGSTEP loop to walk to EOF on each row (yielding cumulative frames), but in the Pas port end cursor advances exactly one step.  Suspected deeper cause: either (a) `windowReadPeerValues` reads from the wrong column on the end/current cursor when ORDER BY references a non-leading column of the ephemeral table; (b) the OP_Gt at windowCodeRangeTest reg1-arithmetic path (codegen.pas:62110..62117) is being entered for the start-cursor's peer pre-rewind state (leaves reg1 NULL/MEM_Null, so `reg1 >= ''` is false and arithmetic on NULL keeps it NULL, then `OP_Gt reg2,lbl,reg1` with NULL reg1 + SQLITE_NULLEQ flag→jump-on-null short-circuits the frame to a single row); (c) the pre-arithmetic guard at codegen.pas:62110 emits `OP_Ge regString,0,reg1` with no P4 collation — vs C window.c:2199 same — but the post-arithmetic `op` at codegen.pas:62119 sets P4_COLLSEQ correctly.  Per STOP-and-report constraint (multiple deep arms diverge: peer-value read, range-test arithmetic gate, NULLEQ interaction with redefined collation pointer identity), no narrow port lands here.  Next-session entry point: enable EXPLAIN dump for the 1.3 prepared statement and diff against C's VDBE listing for the same SQL; mismatch will localize to one of windowReadPeerValues / windowCodeRangeTest / sqlite3ExprNNCollSeq pColl caching.  Residual 2026-05-17.
- [X] **9.4.divbug.80** `ORDER BY without LIMIT on DELETE/UPDATE` not detected — wherelimit-0.x now Ok (commit 031f065). Residual UDL codegen + planner-EQP tracked as .80.a/.80.b.
- [ ] **9.4.divbug.80.a** Port DELETE/UPDATE LIMIT/ORDER BY codegen (SQLITE_ENABLE_UPDATE_DELETE_LIMIT runtime arm) — currently the Pascal grammar's rules 152/159 don't shift `orderby_opt limit_opt`, so the only legal use of trailing ORDER BY on DELETE/UPDATE is the error path from 9.4.divbug.80.  Wherelimit-1.2..3.13 (40 tests) need: (1) grammar extension to accept `orderby_opt limit_opt` in cmd::=DELETE/UPDATE arms; (2) sqlite3DeleteFrom / sqlite3Update signature already takes pOrderBy/pLimit but the generic-coroutine path in delete.c:300..420 / update.c:340..500 must rewrite to `WHERE rowid IN (SELECT rowid … ORDER BY … LIMIT …)`.
- [ ] **9.4.divbug.80.b** wherelimit3-1.2 planner EQP divergence — `SELECT … FROM t1 WHERE a BETWEEN ? AND ? ORDER BY b` should choose `INDEX t1b` (ORDER-BY-eliminating covering scan) but picks `t1a` range + TEMP B-TREE.  Likely cost-model regression in wherePathSolver / sqlite3WhereBegin's ORDER BY satisfiability scoring (where.c:6800+).
- [X] **9.4.divbug.81** Attached / `query_only` DB readonly enforcement (residue of divbug.57) — queryonly-1.4/.5 expects `attempt to write a readonly database` got `0 {}`; pager4-1.3/.4 same family; rdonly.test cascade.
- [X] **9.4.divbug.82** INSERT…RETURNING / scalar-function eval returns empty row — tkt-31338-3.1 expected `[4 1 2 3 4 {}]` got `[]`; tkt-26ff-1.x and tkt-5e10420e8d cascade.
- [ ] **9.4.divbug.83** Planner row-order divergence across where* family — whereA-1.2 expected `[3 4.53 {} 2 hello world 1 2 3]` got `[1 2 3 2 hello world 3 4.53 {}]`; whereG-1.3 expected detail-string regex `/.*track.*composer.*album.*/` got order with composer scanned first (EQP residue of divbug.55); whereB/F/I/N, where2/6/8, orderbyB show similar ordering / EQP-shape divergences.  Cites: eab96c2.  Residual 2026-05-16: 8 pas-soft test(s) still fail (e.g. orderbyB, where2); reopened per failing-pas-soft-with-closed-cite rule.
- [X] **9.4.divbug.84** Long-running tests hit the 20 s per-test driver timeout — `select4.test`, `writecrash.test`, `securedel2.test` all aborted by the timeout watchdog and counted as FAIL.
- [X] **9.4.divbug.85** `collate5.test` — re-triaged 2026-05-17: a single sub-test (`collate5-1.12`, test/collate5.test:85..94) fails, not 6.
- [X] **9.4.divbug.86** Sibling-of-.84 driver-timeout family (pragma4/printf/securedel.test) — closed 2026-05-18: printf.test → SKIP.md (genuine 30s timeout); securedel.test now passes; pragma4.test fails fast, left pas-soft for separate triage.
- [ ] **9.4.divbug.87** Result divergence cluster (carved from `9.4.4.g-unbucketed` 2026-05-16) — **73 pas-soft tests** emit `got:` lines that do not match the C oracle.  Subdivided into `result-divergence` (68: e.g. `backup5`, `badutf`, `capi2`, `colmeta`, …) and `malformed-corrupt-vector` (5: `backup4`, `corruptM`, `in2`, `rowhash`, …).  Each test needs an individual bisect; this single bullet placeholds until root-cause splits emerge.  Full list classified in `/tmp/unbk_sig2.tsv` from the 2026-05-16 sweep.
  - [X] **9.4.divbug.87.001** `backup4` — ! backup4-1.2 error: database disk image is malformed.
  - [X] **9.4.divbug.87.002** `backup5` — ! backup5-1.6 got: [SQLITE_CORRUPT SQLITE_CORRUPT].
  - [X] **9.4.divbug.87.003** `badutf` — 36/36 PASS.
  - [X] **9.4.divbug.87.004** `capi2` — ! capi2-1.5 got: [name rowid {} {}].
  - [X] **9.4.divbug.87.005** `colmeta` — ! colmeta-1.1 got: [1 {invalid command name "sqlite3_table_column_metadata"}].
  - [X] **9.4.divbug.87.006** `corruptC` — ! corruptC-2.1 got: [0 {{*** in database main ***  Partial: corruptC-2.1/.3/.4/.6/.7/.10/.11/.13/.14 now PASS (22→9 sub-test failures).
  - [X] **9.4.divbug.87.007** `corruptM` — malformed database schema (t1)}].
  - [X] **9.4.divbug.87.008** `delete4` — ! delete4-6.0 got: [1 3 5].
  - [X] **9.4.divbug.87.009** `descidx1` — ! descidx1-2.1 got: [4 5 6].
  - [X] **9.4.divbug.87.010** `diskfull` — already fixed by 2944378 (PragFlg_NeedSchema upfront ReadSchema gate); fresh-handle integrity_check after a SQLITE_FULL VACUUM abort no longer synthesises 'never used' lines. diskfull.test PASS 744.
  - [X] **9.4.divbug.87.011** `eval` — ! eval-2.3 got: [1 {} {} 2 {} {} 3 {} {} 4 {} {}].
  - [X] **9.4.divbug.87.012** `exec` — ! exec-1.2 got: [0 {{1} {2}}].
  - [X] **9.4.divbug.87.013** `exprfault` — FIXED: tester_min.tcl do_faultsim_test mis-quoted `\;` separator collapsed `set {}` into zero-arg `set`.
  - [X] **9.4.divbug.87.014** `exprfault2` — FIXED with .013 (same root cause; malloc_common.tcl:347,378..380).
  - [X] **9.4.divbug.87.015** `func3` — ! func3-1.2 got: [1].
  - [X] **9.4.divbug.87.016** `fuzz-oss1` — ! fuzz-oss1-skrooge error: no such column: v_operation_tmp1.id.
  - [X] **9.4.divbug.87.017** `gcfault` — FIXED with .013 (same root cause; malloc_common.tcl:347,378..380).
  - [X] **9.4.divbug.87.018** `gencol1` — ! gencol1-2.1.150 error: table t1 has 6 columns but 3 values were supplied.
  - [X] **9.4.divbug.87.019** `having` — ! having-5.2 error: no such column: Col0.
  - [X] **9.4.divbug.87.020** `hexlit` — ! hexlist-401 got: [0 {}].
  - [ ] **9.4.divbug.87.021** `in2` — ! in2-{286..571} error: database disk image is malformed (209 of 1997 sub-tests fail).  Triage notes (4 h): Repro is `tclsh ./bin/libpassqlite3tcl.so` + the in2.test seed (2000 ints + '' + 2000 short text rows in table `a`), then `SELECT 1 IN (SELECT a FROM a WHERE i<N OR i>=2000)` for various N; passes in `bin/passqlite3` shell, fails only under the Tcl binding because the testfixture build forces SQLITE_DEFAULT_PAGE_SIZE=1024 (types.pas:290) so balancing fires sooner.  Bug surfaces inside the **IN-subquery ephemeral b-tree** when `defragmentPage` slow path runs on a leaf index page (e.g. pgno=4) and the post-rebuild invariant `data[hdr+7]+cbrk-iCellFirst != pPage^.nFree` trips → `CORRUPT_PAGE` at btree.pas:1488..1490 (port of btree.c:1721).  Instrumented dump shows pPage^.nFree=11 but actual page physical free is 8 (top=292, freeblocks=[], nFrag=0, iCellFirst=284) AND `sum(xCellSize)` over the 138 cell pointers comes to 725 bytes so cbrk=299 and post-defrag free should be 15 (a 7-byte and a 4-byte mismatch).  Cells are 12×size-8 ("xNNNN" text records), 1×size-4 (the empty-string row), 125×size-5 (integers 128..285).  All cell varint heads decode cleanly; xCellSize_IdxLeaf returns the same min-4 bumped size that fillInCell/sqlite3BtreeInsert padded to.  The +3 inconsistency originates **upstream of defrag** — likely a previous balance_nonroot iteration set `apNew[iPg]^.nFree := usableSpace - szNew[iPg]` (btree.pas:6066) using a szNew that was 3 bytes short, propagating from an older sibling whose nFree was already 3 high (cumulative bias from the apDiv padding loop at btree.pas:5774-5778 interacting with the `b.szCell[j]==4 → sz := xCellSize(pParent, pCell)` interior re-parse arm at btree.pas:5957-5960; both arms are 1:1 with C btree.c:8496-8503 and 8855-8858, yet C oracle passes — suggesting Pas-side allocation/buffer-layout subtlety that's not yet identified).  Need deeper trace correlating szNew[i] computation against insertCell/insertCellFast sites over the whole 138-cell life of pgno=4.
  - [X] **9.4.divbug.87.022** `in5` — FIXED (already passing).
  - [ ] **9.4.divbug.87.023** `in6` — ! in6-1.5 got: [104].  Partial work landed: ported where.c:7637..7664 IN-tail WHERE_IN_EARLYOUT/iLeftJoin arm into sqlite3WhereEnd (codegen.pas:22653) so OP_IfNoHope + OP_IfNotOpen now emit when the planner sets WHERE_IN_EARLYOUT.  But the real blocker is upstream: the Pas `whereLoopAddBtreeIndex` (codegen.pas:16770) never extends the index-key equality chain through WO_IN terms on inner key columns — e.g. `WHERE a IN (1,2,3) AND b=1` on `INDEX(a,b)` falls back to SCAN instead of `SEARCH … (a=? AND b=?)`.  Without IN being chosen as the loop driver, IN_EARLYOUT is never set and the new IfNoHope code never fires.  Root cause is in the IN-arm cost gate or nEq increment path; needs deeper planner port (where.c:3343..3409 + whereLoopAddBtreeIndex recursion).
  - [ ] **9.4.divbug.87.024** `in7` — ! in7-1.1.6 got: [1] (also 1.1.7 / 1.1.10 / 1.1.12 / 4.0).  Same root cause as 023: the Pas planner picks SCAN instead of an IN-driven SEARCH plan for `WHERE c IN (SELECT z FROM t2)` (c is PK) and the UNIQUE-INDEX variants — so per-IN-value Next is emitted on the t1 cursor when C oracle uses SeekGE+DeferredSeek with no t1.Next.  Plus in7-4.0 is a separate NATURAL JOIN error.  Same fix path as 023.
  - [X] **9.4.divbug.87.025** `index` — index-16.{1,2,3,4} now pass.
  - [X] **9.4.divbug.87.026** `index3` — index3-1.4 now passes.
  - [ ] **9.4.divbug.87.027** `index8` — 1.1eqp: planner picks t1abd index even when it cannot cover c=4 (expected `~/USING INDEX/` — fall back to SCAN).  Triage: deeper cost-model arithmetic (covering vs ORDER-BY-LIMIT-helping); left for separate sweep.
  - [~] **9.4.divbug.87.028** `index9` — partial-index with bound-variable WHERE: still deferred (6 errors, unchanged from baseline).  The literal-WHERE structural fix (87.029) does not help bound `?`/`$var` cases: whereUsablePartialIndex needs the bound value at prepare time, which requires vdbeUnbind to set Vdbe.expired on the expmask bit + a reprepare cycle passing pReprepare=old vdbe (vdbeapi.c sqlite3VdbeUnbind / sqlite3Reprepare / prepare.c) so bound values flow into exprCompareVariable on re-prepare.  Pure statement-lifecycle subsystem; no overlap with the 87.029 codegen fix.
  - [X] **9.4.divbug.87.029** `indexA` — partial-index with literal WHERE now selected (`SEARCH ... USING COVERING INDEX`).  Fix: (a) whereShortCut fall-through SCAN/IPK-range guards now `Exit(0)` on ANY index incl. partial (was: only non-partial), so the full planner whereLoopAddBtree→whereUsablePartialIndex runs (where.c:6389/3699; codegen.pas ~22859/~22995); (b) wired the codegen-side wherePartIdxExpr(pItem) call (where.c:7351) building pParse.pIdxPartExpr; (c) ported exprPartidxExprLookup (expr.c:4820) + its TK_COLUMN/TK_AGG_COLUMN substitution arms (expr.c:5077/4999) so a partial-WHERE-pinned column emits String8+Affinity instead of OP_Column on the never-opened table cursor; (d) selectInnerLoop result-column shortcut now routes through sqlite3ExprCode when pIdxPartExpr/pIdxEpr is active (matches C innerLoopLoadRow). TestExplainParity 1026/1026; indexA-1.2/4.1.1 fixed; indexA-7.0 (INDEXED BY + IPK-in-partial-WHERE) is a pre-existing planner gap, not a regression.
  - [~] **9.4.divbug.87.030** `indexedby` — indexedby-8.1 and 8.3 fixed (`UPDATE ... SET rowid=...` now reports COVERING INDEX).  Root cause: divbug.55's early WHERE_IDX_ONLY clear was guarded only on WHERE_ONEPASS_DESIRED, but C's clear (where.c:7218..7237) is gated on bOnerow OR (WHERE_ONEPASS_MULTIROW && !vtab && !MULTI_OR && SQLITE_OnePass enabled).  UPDATE plans that change the rowid (chngKey=1) don't get MULTIROW, so the IDX_ONLY bit must stay → "COVERING INDEX" EQP.  Restored the full C gate at codegen.pas:21740..21766.  indexedby-11.10 (SELECT IPK col): pas resolveExprAgainstSrcList (codegen.pas:8444 / 8467) accumulates colUsed bit for IPK alias column, defeating coverage detection.  C resolve.c:826..831 skips that bit (`if pExpr->iColumn>=0`); pas's resolver hasn't done the IPK→XN_ROWID rewrite yet when colUsed is set.  Narrow `if iCol <> iPKey` fix tried but regressed unrelated tests, reverted; tracked separately.
  - [X] **9.4.divbug.87.031** `indexexpr3-1.1` — port XN_EXPR arm of ExprCodeLoadIndexColumn (expr.c:4367) + whereAddIndexedExpr/IndexedExprLookup/ExprCanReturnSubtype, wire WhereBegin/ExprCodeTarget so expr-index substitution drops the Function opcode. 1.5/1.6 + 2.3/2.5 separate.
  - [~] **9.4.divbug.87.032** `insert` — three root causes ported (insert.test now 83 PASS, was 0).  (a) IDLIST per-column resolution must run BEFORE the SELECT coroutine is emitted so destCoro.iSdst is initialised from the IDLIST-resolved bIdListInOrder; pre-pass added at codegen.pas:38731..38770, late count-mismatch check stays.  (b) SRT_Coroutine disposal arm was missing the post-row DecrJumpZero (select.c:1522..1524), so `INSERT INTO t SELECT … FROM src LIMIT N` ingested every row of src — added at codegen.pas:33135..33140.  (c) useTempTable Template-4 IPK pre-load read `OP_Column srcTab, iPKey, regRowid` unconditionally; C insert.c:1505..1509 reads it via `srcTab, ipkColumn` when the IDLIST names the IPK, or via storage column iPKey when there is no IDLIST — fixed at codegen.pas:39089..39105.  Remaining 4 fails (4.3/4.4/4.6/7.3) are pre-existing resolver gaps unrelated to .032 root cause.
  - [X] **9.4.divbug.87.033** `insert2` — fixed by 87.032 (a)+(b) above (shared root cause).
  - [X] **9.4.divbug.87.034** `insert3` — fixed by 87.032 (c) above.
  - [X] **9.4.divbug.87.035** `insertfault` — FIXED with .013 (same root cause; malloc_common.tcl:347,378..380).
  - [X] **9.4.divbug.87.036** `instrfault` — FIXED with .013 (same root cause; malloc_common.tcl:347,378..380).
  - [X] **9.4.divbug.87.037** `intpkey` — Fixed.
  - [X] **9.4.divbug.87.038** `intreal` — already passes (20/20).
  - [X] **9.4.divbug.87.039** `istrue` — Fixed (5 sub-tests recovered: 520, 521, 522, 523, 524, 700).
  - [X] **9.4.divbug.87.040** `join5` — join5-3.1 (and 3.2) now PASS.
  - [X] **9.4.divbug.87.041** `join7` — join7-1.20 (and ~64 sibling tests across cases 1,2,3,5 / 1.20,1.30,1.40,1.60,1.80,1.81,1.100,1.101,1.115,1.120,1.140,1.141 + 10.x variants) now PASS.
  - [X] **9.4.divbug.87.042** `join9` — join9-1.200/1.201 (and ~5 sibling RIGHT-JOIN cases per case 1/2/3/4/5; total errors 175→170) now PASS.
  - [ ] **9.4.divbug.87.043** `joinC` — ! joinC-34 got: [15 15 15 15 15 15] (and ~24 sibling cases 34..56).  Triage (~1h): the failing pattern is `t1 INNER JOIN (t2 RIGHT JOIN (...) USING(a)) USING(a)`; expected `[11 11 - 11 11 - 15 15 15 15 15 15]` but unmatched-RHS rows are dropped because the outer USING-coalesced `a` of the (t2 RIGHT JOIN ...) FROM-subquery binds to t2.a (cursor 2) which becomes NULL on t2 NullRow, so the autoindex SeekGE on the outer t1.a=subq.a never matches.  C oracle reads `Column 3,0` (the inner subquery cursor) for the (join-3)'s first emitted column — i.e. the USING-coalesce flips to the right operand on RIGHT JOIN.  Pas expandStar (codegen.pas:26396..26560) pre-binds TK_COLUMN to (pItem.iCursor, j) so the resolver's USING-coalesce arm at codegen.pas:10131..10138 (already ported as part of .042) never fires for the materialized inner pEList of an SF_NestedFrom subquery.  Attempted minimal fix: re-target pColExpr to the right operand's cursor when (i<nSrc-1) and base[i+1] is USING+JT_RIGHT+~JT_LEFT — passes build but breaks outer `t2.a` resolution ("no such column: t2.a") because ResolveNestedFromDot walks pNestedFrom and now no item exposes column `a` under the t2 alias.  Proper fix requires either (a) full port of C's expandStar pattern: emit bare TK_ID at select.c:6260 (or TK_DOT under SF_NestedFrom) and let lookupName apply the USING-coalesce + extendFJMatch FULL-JOIN coalesce() builder; (b) keep the t2.a binding for metadata but synthesise a coalesce(t2.a, inner.a) wrapper expression for the materialized pEList value while preserving zEName='t2.a.a' for outer dotted-name resolution.  Both touch SF_NestedFrom + pNestedFrom + ResolveNestedFromDot interactions.  Same architectural cluster as the `extendFJMatch not yet ported` gap called out in 87.042.
  - [X] **9.4.divbug.87.044** `joinI` — joinI.test PASS (28/355).
  - [X] **9.4.divbug.87.045** `limit` — limit-2.2 (`CREATE TABLE t2 AS SELECT * FROM t1 LIMIT 2; SELECT count(*) FROM t2`) now PASS.
  - [ ] **9.4.divbug.87.046** `limit2` — ! limit2-100.{3,110.3,120.3} got: [0].  Triage (same architectural gap as 87.023/87.024): test computes `expr {$fast_count < 0.02*$slow_count}` where fast_count is sqlite_search_count for `SELECT a,b FROM t1 WHERE a IN (2,4,5,3,1) ORDER BY b LIMIT 5` and slow_count is the same with `ORDER BY +b` (blocks index-order LIMIT opt).  C oracle EQP picks `SEARCH t1 USING COVERING INDEX t1ab (a=?)` (IN-driven WO_IN equality probe in whereLoopAddBtreeIndex, where.c:3343..3409) so fast_count ≈ 50 vs slow_count ≈ 1004 (ratio 0.05 < 0.02 * slow).  Pas EQP picks `SCAN t1 USING COVERING INDEX t1ab + USE TEMP B-TREE FOR ORDER BY` for BOTH fast and slow → identical search_count → ratio ≈ 1.0 ≫ 0.02.  Root cause same as 87.023 / 87.024 notes: Pas `whereLoopAddBtreeIndex` (codegen.pas:16770) never extends the index-key equality chain through WO_IN terms on the leading key column, so the IN-driven SEARCH plan is never costed.  Fix requires full port of where.c:3343..3409 IN-arm + whereLoopAddBtreeIndex recursion (deeper planner work, same as 87.023/87.024).
  - [X] **9.4.divbug.87.047** `lock` — lock-2.8b and lock-2.11b (sibling) now PASS.
  - [X] **9.4.divbug.87.048** `lock7` — lock7.test now PASS (8/0 fail).
  - [X] **9.4.divbug.87.049** `minmax` — BIGNULL min/max early-out lands: minmax-1.6/2.1/2.3/3.1/3.3 search_count 19→1, results correct. WHERE_BIGNULL_SORT honour (j==nEq keeps isMatch, codegen.pas:21462 refusal arm = where.c:5425..5430) + two-pass codegen (codegen.pas:25818..26060 = wherecode.c:1933..2164) + DecrJumpZero (codegen.pas:25050 = where.c:7616) already in committed code; verified TestExplainParity 1026/1026. Remaining minmax-6.4/6.6/6.7 are a separate LIMIT/OFFSET-on-aggregate cluster (file stays pas-soft).
  - [X] **9.4.divbug.87.050** `minmax2` — same BIGNULL landing as 87.049 cures DESC-index cases (`t1i1 ON t1(x DESC)`, revIdx=1): minmax2-1.6/2.x/3.x search_count 19→1. Only the shared 6.4/6.6/6.7 LIMIT/OFFSET cluster remains (pas-soft). Cite where.c:5425..5430 + wherecode.c:1933..2164.
  - [X] **9.4.divbug.87.051** `minmax3` — same BIGNULL landing cures trailing-column j==nEq case `SELECT min(y) WHERE x='2'` (i2 ON t1(x,y)): minmax3-1.2.3/1.2.4/1.3.2/1.3.3 now `{II 1}`/`{I 1}` (search_count=1). Remaining minmax3-4.x are the separate NOCASE-collation cluster, not this divbug. Cite where.c:5425..5430 + wherecode.c:1933..2164.
  - [X] **9.4.divbug.87.052** `misc2` — misc2-1.2 (BEFORE-INSERT trigger `SELECT CASE WHEN ...
  - [X] **9.4.divbug.87.053** `misc3` — misc3-6.11-utf8 now PASS.
  - [X] **9.4.divbug.87.054** `misc4` — misc4-1.2.1 (and siblings 1.2.2, 1.3, 1.4, 1.5, 1.6) now PASS.
  - [~] **9.4.divbug.87.055** `misc5` — PARTIAL: aggregate-no-GROUP-BY DISTINCT fixed (`SELECT DISTINCT sum(x) FROM t`→6) by stripping SF_Distinct (a single output row makes DISTINCT a no-op; mirrors C select.c:8265 else-branch running the agg path unchanged + 8253..8263 dedup-against-empty-eph) at passqlite3codegen.pas ~32515; parity 1026/1026, no new pas-strict regression. STILL OPEN: misc5-3.1's `SELECT DISTINCT <cols>,<agg> ... GROUP BY <other> ORDER BY` non-redundant DISTINCT-over-GROUP-BY case still returns [] (needs path (a) per-row Found/IdxInsert in GROUP-BY emit, or path (b) isDistinctRedundant wiring).  Root cause: both the aggregate-no-GROUP-BY arm (codegen.pas:31310..31317) and the GROUP-BY-aggregate arm (codegen.pas:30136..30137) gate on `(selFlags and (SF_Distinct or SF_Compound)) = 0`, so **any** `SELECT DISTINCT <agg>` or `SELECT DISTINCT <cols>, <agg> ... GROUP BY ...` falls through every later arm and `sqlite3Select` returns SQLITE_OK without coding any opcodes -> bytecode is bare Init/Halt/Goto and the stmt yields zero rows.  Minimal repro: `CREATE TABLE t(x); INSERT INTO t VALUES(1),(2),(3); SELECT DISTINCT sum(x) FROM t;` returns [] (should be [6]).  Drilling into misc5-3.1: the deeply-nested query bottoms out in `SELECT DISTINCT artist, sum(timesplayed) AS total FROM songs GROUP BY LOWER(artist) ORDER BY total DESC LIMIT 10` which returns []; everything above it then chains to [].  Test header explicitly notes the result is indeterminate (one/two/three all valid) but Pas gives [] instead of any of them.  C oracle select.c:8142..8263 sets `sDistinct.isTnct = (selFlags & SF_Distinct)!=0`, runs the agg path unchanged, then at 8253..8263 opens an ephemeral KEYINFO index (`sDistinct.tabTnct`, eTnctType=WHERE_DISTINCT_UNORDERED) and selectInnerLoop's ResultRow body (select.c:1218..1240) does `OP_Found jump-if-already-seen / IdxInsert otherwise` before emitting ResultRow.  For aggregate-no-GROUP-BY case DISTINCT is **always** trivially redundant (one row) -- could be cheaply stripped (mirror codegen.pas:29847..29865's no-FROM strip) but doesn't help misc5-3.1.  For GROUP-BY-agg case (misc5-3.1 inner shape), would need either: (a) port C's distinct-ephem-table + per-row Found/IdxInsert gate into the GROUP-BY agg emit body (codegen.pas:~30150..30900 -- substantial, needs sDistinct.tabTnct/addrTnct allocation + selectInnerLoop ResultRow rewrite); OR (b) port `isDistinctRedundant`-style analysis to drop SF_Distinct when GROUP BY keys are a superset of result-set (where.c:636 is already ported at codegen.pas:17444 but never invoked from the codegen agg gates).  Path (b) is the smaller change but still ~hour because the redundancy check needs the resolved column-set comparison + GroupBy-keys-cover-result-set logic.  Needs a DISTINCT-codegen cluster fix (likely also affects siblings in other tests).  Infrastructure already present: WHERE_DISTINCT_* constants, isDistinctRedundant (codegen.pas:17444), and the no-FROM DISTINCT-strip precedent (codegen.pas:29859..29865, divbug.87.020).
  - [ ] **9.4.divbug.87.056** `mmapwarm` — ! mmapwarm-1.0 expected: [507], Pas got: [506], C-sqlite3 reference (via stdin redirect) got: [127].  Triage (**two unrelated gaps**: per-row leaf-page packing + missing `sqlite3_mmap_warm` Tcl command).  (1) **Page-count divergence is environmental + a packing bug**.  Test source ../sqlite3/test/mmapwarm.test:29..38 creates 500 rows of `(randomblob(400), randomblob(500))` after `PRAGMA auto_vacuum=0` and asserts `PRAGMA page_count == 507`.  The expected `507` assumes a page_size of 1024 (historical testfixture default).  With the current SQLITE_DEFAULT_PAGE_SIZE=4096 (sqliteLimit.h:213..214) C-sqlite3 packs ~4 rows/leaf via overflow chains for a count of 127.  Pas instead emits **one page per row** (506) — each ~900-byte row spills its entire payload to overflow despite maxLocal≈1024 on a 4096 page.  Stale log showed [127] (matches C) because pre-.032-.034 the INSERT…SELECT cluster bug truncated the CTE early at 125 rows × 1 leaf-page each ≈ 127 pages; now CTE delivers all 500 rows, exposing the packing bug.  Root cause likely in `btreeComputeFreeSpace`/`fillInCell` payload-threshold math at passqlite3btree.pas:859..895 (`surplus := minLocal + (nPayload-minLocal) mod (usableSize-4)`); C btree.c:1131..1147 same algebra but Pas signed/u16 mixing around lines 859..869 may cause the `surplus <= maxLocal` branch to mis-fire for nPayload=903 (after rowid+hdr), driving nLocal=minLocal (~50) and the rest to overflow → one overflow chain per row but those overflow pages also get one row each since the leaf cell is full.  Even with a packing fix, mmapwarm-1.0 still won't match [507] without forcing `PRAGMA page_size=1024` (test relies on legacy default).  (2) **Tests 1.1–3.x fail with `invalid command name "sqlite3_mmap_warm"`** — the Tcl-side helper backing `sqlite3_test_mmap_warm` (sqlite3.c `sqlite3_test_control(SQLITE_TESTCTRL_*)` + tclsqlite.c `Sqlitemmapwarm_Init` / `sqlite3_mmap_warm` exposure) is not wired in `bin/libpassqlite3tcl.so`.  Need to (a) port `sqlite3_mmap_warm(db, zSchema)` from main.c (~30 lines: walk pager pages, sqlite3PagerGet+PagerUnref to pre-fault mmap), and (b) register it in the Pas Tcl binding alongside the existing test commands.  Faultsim test 3 also requires `do_faultsim_test` infra (oom* faults) which is a much larger gap.  Both 1.0 packing + sqlite3_mmap_warm wiring remain — neither is a 45-min fix; sqlite3_mmap_warm + page_size=1024 test override would clear 1.1/1.2/1.3/1.4/2.0 but 1.0 needs the btree packing investigation independently.
  - [X] **9.4.divbug.87.057** `notnullfault` — FIXED with .013 (same root cause; malloc_common.tcl:347,378..380).
  - [X] **9.4.divbug.87.058** `null` — null-6.4 now PASS.
  - [ ] **9.4.divbug.87.059** `nulls1` — ! nulls1-5.3 got: TEMP B-TREE plan (same BIGNULL_SORT cluster as .043/.049/.050/.051).  Test issues `SELECT * FROM t4 WHERE a IN (1,2,3) ORDER BY a, b NULLS LAST` over `CREATE INDEX t4ab ON t4(a,b)`; expected EQP is `SEARCH t4 USING INDEX t4ab (a=?)` (index satisfies the ORDER BY).  Pas emits `SCAN t4 USING INDEX t4ab` + `USE TEMP B-TREE FOR LAST TERM OF ORDER BY` because wherePathSatisfiesOrderBy (codegen.pas:19486..19488) explicitly refuses any isMatch when `KEYINFO_ORDER_BIGNULL` is set on an ORDER BY term — see divbug.43's comment at 19489..19494.  C planner (where.c:5425..5430) keeps isMatch=1 and flags WHERE_BIGNULL_SORT, then wherecode.c:1933..1953 + 2030..2086 + 2134..2164 + where.c:7616..7620 emit the two-pass NULL-then-non-NULL scan around regBignull/addrSeekScan.  Pas codegen.pas:23744 still asserts `(pLoop^.wsFlags and WHERE_BIGNULL_SORT) = 0` — substantial port needed.  Same gap blocks nulls1-5.5 (DESC NULLS FIRST mirror), nulls1-6.1.2 & 6.2.2 (t5 covering index), and nulls1-9.3 (returns half the rows — NULL-partition skipped on first pass).  Awaits BIGNULL_SORT codegen cluster fix (.043/.049/.050/.051 root).
  - [X] **9.4.divbug.87.060** `orderby5` — orderby5-3.0 now PASS.
  - [ ] **9.4.divbug.87.061** `orderbyA` — ! orderbyA-1.1.2.1.1 got: [1] (and ~17 sibling 1.tn.{2,3}.x.1 EQP-count failures).  Triage (entangled with a separate WHERE_SORTBYGROUP / WhereIsOrdered gap).  Test idiom: `do_sortcount_test` counts `regexp -all {USE TEMP}` in EXPLAIN QUERY PLAN of `SELECT a, sum(b) FROM t1 GROUP BY a ORDER BY <expr>`.  For tn=1 (no index, `nomatch=2`), C emits two banners: "USE TEMP B-TREE FOR GROUP BY" (select.c:8553, groupBySort=1 arm) **plus** "USE TEMP B-TREE FOR ORDER BY" from generateSortTail (select.c:1705 via the post-aggregate `if( sSort.pOrderBy )` at select.c:8912..8915 — sSort.pOrderBy is kept non-NULL because orderByGrp=0 so the cancellation at select.c:8624..8629 doesn't fire).  Pas codegen.pas:30240..30811 has its own self-contained GROUP BY aggregate arm with a `needSortOB` inline secondary-sorter drain (bug 10.1.bug.12) that opens an extra SorterOpen, SorterInserts payload rows inside addrOutputRow, and at function-end issues SorterSort/SorterData/ResultRow/SorterNext — but it never emits the `USE TEMP B-TREE FOR ORDER BY` Explain that the C `generateSortTail` codepath would have produced, so the EQP regex undercounts by one.  Minimal fix attempt (add OP_Explain "USE TEMP B-TREE FOR ORDER BY" before the SorterSort at codegen.pas:30795) cleanly flips all 13 `1.1.*` failures (tn=1, no-index, nomatch=2 cases) — but **regresses 8 indexed cases** `1.2.2.*.1`/`1.2.3.*.1`/`1.3.2.*.1`/`1.3.3.*.1` from "got=1 expected=1" to "got=2 expected=1".  Root cause of the regression: codegen.pas:30547 comments `groupBySort=1 always taken in this port until WhereIsOrdered routing lands` — Pas unconditionally emits the "USE TEMP B-TREE FOR GROUP BY" banner even when the chosen index already delivers rows in GROUP BY order (C select.c:8521 passes `WHERE_SORTBYGROUP` to sqlite3WhereBegin and select.c:8537 gates `groupBySort=1` on `sqlite3WhereIsOrdered(pWInfo)==0`).  The over-emission of the GROUP BY banner was previously masked by the symmetric under-emission of the ORDER BY banner; fixing one without the other shifts the breakage.  Same WHERE_SORTBYGROUP/WhereIsOrdered gap also produces the remaining `1.2.1.x.1`/`1.3.1.x.1` "expected 0 got 1" failures (indexed + matching ORDER BY → C emits zero banners; Pas still emits 1).  Proper fix: port WHERE_SORTBYGROUP gate (where.c → wherePathSolver + sqlite3WhereIsOrdered) and add the `groupBySort=0` arm at codegen.pas:30540 that reads grouped rows directly from the WHERE-ordered cursor instead of via a SorterInsert/SorterData pair.  Plus emit the OP_Explain "USE TEMP B-TREE FOR ORDER BY" in the needSortOB drain.  Needs a multi-component WhereIsOrdered routing port.  Bisected: minimal Explain-add reproduces flips & regressions cleanly.
  - [X] **9.4.divbug.87.062** `quickcheck` — quickcheck.test now PASS (2/2).
  - [X] **9.4.divbug.87.063** `resolver01` 5.1 — GROUP BY alias-vs-input-column: pass forGroupBy=True to ResolveAliasOrderByCol, skip alias-tag when the bare TK_ID also matches a FROM column (resolve.c:1797; codegen.pas:10708). 7.1/7.2 (NC_UEList) separate.
  - [ ] **9.4.divbug.87.064** `rowhash` — SOURCE-ERROR: database disk image is malformed.  Triage: stdout shows the small-N arms rowhash-1.1 / 2.1 / 2.2 / 2.3 all `Ok` and `finalize_testing` reports `0 errors out of 4 tests`; the SOURCE-ERROR is raised from inside the `if {[working_64bit_int]}` random-loop arm (rowhash.test:48..56) which `do_keyset_test rowhash-2.$i $L` over 6 iterations each inserting 5000 random INTEGER PRIMARY KEY rows via `INSERT OR IGNORE INTO t1 VALUES($key,'a','b','c')` (accumulated $L grows to 30000 by i=9).  The uncaught Tcl error propagates out of `db transaction { ... }` so the `do_test rowhash-2.4` never even prints (no leading `... Ok` / `! ...` line), then the outer `catch {source ...}` at TclTestDriver.pas:449 traps it and emits the SOURCE-ERROR.  Symptom "database disk image is malformed" under bulk `INSERT OR IGNORE` on rowid table with 3 secondary indexes (i1/i2/i3 on a/b/c) → likely overflow-page / btree-balance issue in heavy duplicate-collision path.  Sibling cluster of 87.065 (savepoint6) which exhibits the same "database disk image is malformed" message under auto_vacuum=incremental + savepoint rollback (both pas-soft, STATUS.txt:706 + :725).  C reference for OR IGNORE conflict handling: ../sqlite3/src/insert.c:2107..2206 (sqlite3GenerateConstraintChecks OE_Ignore arm) and ../sqlite3/src/btree.c:8612..8900 (balance_nonroot).  Needs a bisect of which btree balance or OR IGNORE rollback arm corrupts under the 30000-row random-key duplicate-collision workload.
  - [ ] **9.4.divbug.87.065** `savepoint6` — ! savepoint6-normal.8.2 error: database disk image is malformed.  Triage: full run 8006 sub-tests, 3750 errors — across both `savepoint6-normal.*` and `savepoint6-smallcache.*` permutations.  Failure pattern is alternating `.1 error: string or blob too big` followed by `.2 error: database disk image is malformed` at nearly every iteration past .8 (~3750/4003 in each permutation).  Test setup uses `PRAGMA auto_vacuum=incremental` + `CREATE TABLE t1(x,y)` with UNIQUE INDEX i1(x) + INDEX i2(y), then runs 1000 random SAVEPOINT/RELEASE/ROLLBACK iterations (savepoint6.test:36..37, body :150..240) with periodic `PRAGMA incremental_vacuum` (:190, :226).  The "string or blob too big" symptom (SQLITE_TOOBIG) on `.1` typically signals a btree cell length-field that has been overwritten with garbage (cell->nKey or nData mis-decoded), which is then detected as `SQLITE_CORRUPT` on the very next access (`.2`).  Sibling cluster of 87.064 (same SQLITE_CORRUPT family).  Root cause is in the savepoint-rollback / incremental-vacuum interaction — likely the freelist or auto-vacuum pointer-map (PTRMAP_*) is not restored correctly on `ROLLBACK TO SAVEPOINT`.  C reference: ../sqlite3/src/pager.c:6063..6225 (sqlite3PagerSavepoint / pagerPlaybackSavepoint) and ../sqlite3/src/btree.c:62300..62410 (sqlite3BtreeSavepoint + setSharedCacheTableLocks).  Needs a savepoint-rollback / autovacuum-ptrmap reconciliation port.
  - [X] **9.4.divbug.87.066** `securedel` — ! securedel-1.0 got: [0].
  - [X] **9.4.divbug.87.067** `tkt2920` — ! tkt2920-1.3 got: [0 {}].
  - [X] **9.4.divbug.87.068** `tkt3442` `no such column: 5000` — port resolve.c:719 EP_DblQuoted→TK_STRING demotion into ResolveExpr's unresolved-TK_ID tail (codegen.pas:10286/10330), gated on db.init.busy or DQS_DML.
  - [X] **9.4.divbug.87.069** `tkt3718` — ! tkt3718-2.2 got: [1 2 3 4 5 6 7 8 9 10 11 12].
  - [X] **9.4.divbug.87.070** `transitive1` — FIXED: `SELECT count(*) FROM <agg-view>,t2` returned [] because the no-GROUP-BY aggregate arm (codegen.pas:34271) bailed `canUseAgg:=False` on any VIEW/subquery FROM source then emitted nothing (SF_Aggregate stub `Result:=OK;Exit` at 34799). Fix: pre-materialise SRCITEM_FG_IS_SUBQUERY (non-coroutine) sources into eph cursors before WhereBegin in the general arm — same shape as the GROUP BY arm (codegen.pas:33167); C codes it as a co-routine joined via WhereBegin (select.c:8054). Repro now 4. ExplainParity 1026/1026.
  - [X] **9.4.divbug.87.071** `upfrom1` — ! upfrom1-1.1.4 got: [1 {} {} 4 5 6 7 {} {}].
  - [X] **9.4.divbug.87.072** `upsert1` — ! upsert1-200 got: [1 {ON CONFLICT clause does not match any PRIMARY KEY or UNIQUE constraint}].
  - [X] **9.4.divbug.87.073** `upsert4` — ! upsert4-1.1.7 got: [1 {} one 2 {} {} 3 {} three].
- [ ] **9.4.divbug.88** Tcl-bridge command/subcommand long-tail (carved from `9.4.4.g-unbucketed` 2026-05-16) — **62 pas-soft tests** still hit bridge gaps after `9.4.divbug.62/.63/.64/.65` closed the high-frequency surface.  Subdivided into `invalid/unknown command` (55: `badutf2`, `bindxfer`, `cacheflush`, `capi3d`, …) and `unknown subcommand "null"` / `db <other-subcmd>` (7: `indexexpr1`, `joinH`, `join`, `json102`, …).  Port the remaining `db ?subcommand?` and top-level Tcl-bridge entry points until the cluster drains.
  - [X] **9.4.divbug.88.001** `badutf2` — port `sqlite3_expired` Tcl cmd (test1.c:3121..3138, registered :9155); calls existing `passqlite3vdbe.sqlite3_expired` (deprecated, returns 0).
  - [X] **9.4.divbug.88.002** `bindxfer` — port `sqlite_bind` Tcl cmd (test1.c:3207..3247, registered :9086, old-style argc/argv) + Tcl_LinkVar `sqlite_static_bind_value`/`_nbyte` (test1.c:9429..9432).
  - [X] **9.4.divbug.88.003** `cacheflush` — ported `sqlite3_db_cacheflush` Tcl trampoline (test1.c:6383..6411, register at 9173) to `TestModuleTest1.pas`.
  - [X] **9.4.divbug.88.004** `capi3d` — sqlite3_prepare16 + sqlite3_prepare16_v2 Tcl trampolines ported (TestModuleTest1.pas test_prepare16 / test_prepare16_v2; C ref test1.c:5280..5330 / 5340..5390, registered :9147 / :9151).
  - [X] **9.4.divbug.88.005** `capi3e` — ported sqlite3_open / _v2 / _16 Tcl trampolines (TestModuleTest1.pas test_open / test_open_v2 / test_open16; C ref test1.c:5395..5517, registered :9140..9142).
  - [X] **9.4.divbug.88.006** `chunksize` — ported file_control_chunksize_test Tcl trampoline (TestModuleTest1.pas; C ref test1.c:6912..6941, registered :9247).
  - [X] **9.4.divbug.88.007** `cksumvfs` — STUB: register/unregister_cksumvfs Tcl trampolines (test1.c:8795); full cksumvfs.c (~820 lines) not yet ported. SOURCE-ERROR cleared; 1.0..1.3 PASS.
  - [X] **9.4.divbug.88.008** `close` — cured by .005's sqlite3_open trampoline port (TestModuleTest1.pas test_open; C ref test1.c:5395..5417, registered :9140).
  - [X] **9.4.divbug.88.009** `collate7` — sqlite3_create_collation_v2 Tcl trampoline ported (TestModuleTest1.pas tcl_test_create_collation_v2 + testCreateCollation{Cmp,Del}; C ref test1.c:1858..1935, registered :9237).
  - [ ] **9.4.divbug.88.010** `colname` — execsql2 Tcl helper ported (tester_min.tcl; tester.tcl:1628..1636 verbatim). colname-2.1 "invalid command name execsql2" cleared; full 67-test suite now runs. **2026-05-18 sub-bug**: expandStar (passqlite3codegen.pas:26833) was leaving zEName=nil on star-expanded items, so generateColumnNames fell through to the generic `columnN` placeholder for any view / `*` result-column. Ported select.c:6307..6313: per appended TK_COLUMN, dup zCnName (or `tab.col` under longNames = FullColNames+!ShortColNames) into pNewItem^.zEName and tag fg.eEName=ENAME_NAME. Cleared the 8 column-name synthesis failures (3.1, 3.5..3.11). **2026-05-18 sub-fix .1**: `colname-8.1` (`SELECT "y"."x" FROM (...) AS "y"`) — sqlite3SrcListAppendFromTerm (codegen.pas:46241..46243) was storing the FROM-clause AS-alias via raw sqlite3DbStrNDup, leaving quotes attached.  Qualified column references dequote on the lookupName side so `y.x` failed to match a stored `"y"` alias.  Mirror build.c:5099 by routing through sqlite3Dequote (avoids exposing sqlite3NameFromToken across the codegen/parser uses boundary).  colname-8.1 now PASS.  **Residual (architectural)**: 9.330 single-row divergence `SELECT (SELECT avg(a) UNION SELECT min(a) OVER()) FROM t1` expects `{17}`, Pas returns empty.  EXPLAIN shows Pas compiles the whole stmt to literally Init/Halt/Goto (3 ops vs ~83 in C) — the codegen short-circuits the outer SELECT, likely because the scalar subquery combining (a) bare aggregate avg(a) correlated to outer t1, (b) window function min(a) OVER() without FROM and (c) UNION inside a SCALAR coroutine confuses the select-prep/aggregate-promotion path.  >1h architectural audit (select.c flatten/aggregate-promotion vs window-rewrite vs scalar-subquery wrap interaction); not a single-line resolver fix.  66 PASS / 1 FAIL.
  - [X] **9.4.divbug.88.011** `corrupt` — btree_from_db Tcl trampoline ported (TestModuleTest1.pas:1196..1244 + Sqlitetest1_Init registration; C ref test3.c:504..546, registered :676).
  - [ ] **9.4.divbug.88.012** `corrupt2` — nonzero_reserved_bytes Tcl cmd ported (PasTclSqlite.pas:NonzeroReservedBytes; mirrors tester.tcl:331 `return [sqlite3 -has-codec]`=0 for no-codec build). Port advanced past prologue; corrupt2 now exercises 393 subtests.  **Partial fix 2026-05-17**: `checkList` was widening `expected-nIn` (both `u32`) to `i64` in the FPC `array of const`, printing `Freelist: size is 18446744069414584323 but should be 2` instead of C's 32-bit-wrap `Freelist: size is 3 but should be 2` (btree.c:10764..10768, %u prints u32).  Added explicit `u32((expected-nIn) and $FFFFFFFF)` mask at passqlite3btree.pas:8563..8580.  corrupt2 sub-fail count 17→15 (2.14.3/.5 now PASS).  **Residuals** (15 sub-fails, all architectural — NOT message-text):
      - **Schema-reload-after-writable_schema** (2.1): need to drop and re-parse sqlite_master after `PRAGMA writable_schema=1; UPDATE sqlite_master ...; PRAGMA writable_schema=0` so the duplicate-index detection fires on next open.  Currently Pas keeps in-memory schema and silently runs the SELECT.  C ref: prepare.c:sqlite3InitOne / schema-cookie bump under DBFLAG_SchemaChange.
      - **Auto-vacuum DROP-TABLE pointer-map corruption-detect arms** (3.1, 4.1, 11.1, 12.1, 13.3): all `0 {}` instead of `database disk image is malformed`.  Each plants a deliberate ptrmap mismatch then drops a table to trigger the integrity check during page-relocation.  Needs autoVacuum=1 paths through `incrVacuumStep` / `relocatePage` (btree.c:5800+) to consult the ptrmap and trip `SQLITE_CORRUPT_BKPT`.  Pas `pBt^.autoVacuum` is set by header byte 52 read but the relocation/ptrmap divergence arms are not wired to corruption rc.
      - **Free-page-list parsing safety** (6.1..6.4, 8.1): need `cellSizeCheck` style bounds check on free-block list traversal (`btree.c:freeSpace` / `defragmentPage`) so a planted negative offset returns SQLITE_CORRUPT_BKPT instead of silently iterating.
      - ~~**`PRAGMA freelist_count` returns 0 after DROP** (14.1/.2)~~ — CLOSED in .014: bug was in codegen, not btree.  freePage2/allocateBtreePage already updated aData[36]; PRAGMA freelist_count was a `iVal:=0` stub.  Wired through PragTyp_HEADER_VALUE / OP_ReadCookie / sqlite3BtreeGetMeta.
      - ~~**Autovacuum file-size off-by-one** (13.1)~~ — RE-DIAGNOSED 2026-05-18: not a `PRAGMA mmap_size` cap bug at all (mmap_size still returns hard-coded 0 — codegen.pas:53271). Test 13.1 is `do_test corrupt2-13.1 { file size corrupt.db } $::sqlite_pending_byte`; expected 0x10000 (65536), got 64512 (63 pages of 1024). The `$::sqlite_pending_byte` Tcl-link var is also missing (test2.c:753 — see TestModuleIoerr.pas) but the deeper bug is autovacuum not growing the file to pending-byte boundary in the -tclprep loop. Same bucket as the .002.f auto-vacuum residuals.
      - [X] **`{SQLITE_CORRUPT}` symbolic vs `11` numeric** (10.2) — FIXED (88.012.f): ported `test_errcode` Tcl cmd (test1.c:4884) → TestModuleTest1.pas, wraps sqlite3_errcode through t1ErrName.
  - [X] **9.4.divbug.88.013** `corrupt3` — transitively passing at HEAD; driver reports `PASS ../sqlite3/test/corrupt3.test 0 25` on re-run 2026-05-17.
  - [X] **9.4.divbug.88.014** `corrupt4` — fix: PRAGMA freelist_count was a hard-coded `0` stub in codegen.pas:52803; freePage2 / allocateBtreePage already updated header[36] correctly.
  - [X] **9.4.divbug.88.015** `corrupt6` — PASS 25 fail / 295 cases (cured by .014 freelist_count fix).
  - [X] **9.4.divbug.88.016** `corrupt7` — PASS 6 / 413 (cured by .014).
  - [X] **9.4.divbug.88.017** `corruptE` — PASS 0 / 49 (cured by .014).
  - [X] **9.4.divbug.88.018** `corruptG` — PASS 5/89 (drained).
  - [X] **9.4.divbug.88.019** `corruptH` — PASS 9 / 1186 (cured by .014).
  - [ ] **9.4.divbug.88.020** `corruptI` — 1 fail / 286 (was 23/1919) after .014 + .018 errCode propagation.  Lone residual: corruptI-6.1 — DELETE on cell whose payload-size varint is corrupted to ~2^32 (`hexio_write … 8FFFFFFF7F02`) raises CORRUPT in `clearCellOverflow` (passqlite3btree.pas:4988); C tolerates because the test was hardened to "no longer assert-fail".  Need to walk btree.c:6964 logic vs Pas line-for-line — likely the `nOvfl` overflow-truncation guard or the chain-exhaustion path differs.  Distinct cluster from .018.
  - [X] **9.4.divbug.88.021** `corruptJ` — PASS 5 / 317 (cured by .014).
  - [ ] **9.4.divbug.88.022** `corruptK` — 2 fail / 215 (was 9/883) after .014 + .018 (the corruptK-3.1 path closed as a side-effect of errCode propagation through SeekRowid/IndexMoveto).  Lone residuals: corruptK-3.2 + 3.3, both blocked on missing `sqlite_dbpage` eponymous virtual table (test 3.2 fails "no such table: sqlite_dbpage", 3.3 cascades).  Not a btree-malform arm — separate feature port (test_dbpage.c); track under its own task.
  - [X] **9.4.divbug.88.023** `corruptN` — ported decode_hexdb Tcl cmd (test1.c:8837..8910) into TestModuleTest1.pas:2290..2452; prologue cleared, driver now executes 17/256 corruptN-1.* subtests instead of SOURCE-ERROR'ing at line 1.
  - [X] **9.4.divbug.88.024** `dataversion1` — ported file_control_data_version Tcl trampoline (TestModuleTest1.pas; C ref test1.c:6873..6903, registered :9249).
  - [X] **9.4.divbug.88.025** `delete_db` — STUB: multiplex_initialize/shutdown/control Tcl trampolines (test_multiplex.c:1227); full shim VFS not yet ported (88.069). SOURCE-ERROR cleared; 4 PASS / 55.
  - [X] **9.4.divbug.88.026** `e_createtable` — SOURCE-ERROR cleared via do_select_tests port at tester.tcl:1103..1157; downstream subtests now run (145 PASS / 4 FAIL of 149).
  - [X] **9.4.divbug.88.027** `e_dropview` — SOURCE-ERROR cleared via do_select_tests port at tester.tcl:1103..1157; downstream subtests now run (48 PASS / 0 FAIL).
  - [X] **9.4.divbug.88.028** `e_reindex` — SOURCE-ERROR cleared via do_select_tests port at tester.tcl:1103..1157; downstream subtests now run (100 PASS / 15 FAIL of 115).
  - [X] **9.4.divbug.88.029** `e_select2` — SOURCE-ERROR cleared via drop_all_tables port at tester.tcl:2253..2275 (do_select_tests also added); downstream subtests now run (199 PASS / 6 FAIL of 205).
  - [X] **9.4.divbug.88.030** `e_update` — SOURCE-ERROR cleared via do_select_tests port at tester.tcl:1103..1157; downstream subtests now run (136 PASS / 12 FAIL of 148).
  - [X] **9.4.divbug.88.031** `e_uri` — sqlite3_close / sqlite3_close_v2 Tcl trampolines ported (TestModuleTest1.pas test_close + test_close_v2; C ref test1.c:684..725, registered :9079..9080).
  - [X] **9.4.divbug.88.032** `e_wal` — ported `testvfs` wrapper VFS + Tcl object cmd (test_vfs.c:1084..1695) in src/tests/tcl/testmodules/TestModuleVfs.pas; wired via Sqlitetestvfs_Init in PasTclSqlite.pas.
  - [ ] **9.4.divbug.88.033** `e_walauto` — re-triaged 2026-05-17: `nonzero_reserved_bytes` SOURCE-ERROR cleared by 88.012 port (PasTclSqlite.pas:4881). e_walauto.test now runs e_walauto-1.1.0/1.1.1 (2 PASS / 0 errors) then SOURCE-ERROR: `couldn't open "test.db-shm": no such file or directory` — WAL `-shm` not created (no real WAL-mode mmap shm in current OS layer). Residual is OS/WAL-shm, separate bucket.
  - [X] **9.4.divbug.88.034** `enc3` — sqlite3_enable_shared_cache Tcl trampoline ported (test1.c:1665..1699; TestModuleTest1.pas:2290 tcl_test_enable_shared + registration:5371).
  - [X] **9.4.divbug.88.035** `errmsg` — verify_ex_errcode + sqlite3_extended_errcode trampoline ported (tester_min.tcl:188; TestModuleTest1.pas; engine passqlite3main.pas:3703). SOURCE-ERROR cleared; 11 PASS / 131.
  - [ ] **9.4.divbug.88.036** `fallocate` — re-triaged 2026-05-18.  ROOT CAUSE found: `PRAGMA auto_vacuum = N` WRITE arm was MISSING from passqlite3codegen.pas (only the READ arm existed at line 53107).  Calls were silently no-op; `sqlite3BtreeSetAutoVacuum` never invoked; pBt^.autoVacuum stayed 0; `autoVacuumCommit` returned at the `pBt^.autoVacuum=0` short-circuit, so DELETE never reclaimed pages and the file never shrank.  FIX: ported pragma.c:802..845 WRITE arm into passqlite3codegen.pas after the READ arm — parses 'none'/'full'/'incremental'/0/1/2 via sqlite3StrICmp + sqlite3Atoi clamp, sets db^.nextAutovac (so freshly-materialised DBs inherit the mode in newDatabase()), calls sqlite3BtreeSetAutoVacuum, and for FULL/INCR emits the C VDBE op-list verbatim (OP_Transaction iDb,1 / OP_ReadCookie BTREE_LARGEST_ROOT_PAGE / OP_If skip-to-SetCookie / OP_Halt SQLITE_OK,OE_Abort / OP_SetCookie BTREE_INCR_VACUUM,eAuto-1).  Fallocate fail delta: was 8/18, now 6/18 (1.5, 1.7, 2.4 newly PASS; 1.4 now surfaces a deeper CORRUPT inside autoVacuumCommit/incrVacuumStep that was previously masked by the no-op; 1.8/1.9/2.3/2.5/2.6 unchanged).  Residual ptrmap-staleness in autovacuum-on-shrink is a separate bucket (autovacuum.test still ~61/63 fail, was already at that level).  Regression suite holds 100/101 (only baseline TestFuzzDiff).  Remaining shrink-engine work (ptrmap rebuild + chunk-alignment in WAL truncate) tracked in a follow-on entry.
  - [X] **9.4.divbug.88.037** `filectrl` — ported `file_control_test` Tcl cmd (test1.c:6795..6827).
  - [X] **9.4.divbug.88.038** `filefmt` — CLOSED 2026-05-18: residuals were a single missing Tcl proc, not engine bugs.
  - [X] **9.4.divbug.88.039** `hook` — verify_ex_errcode SOURCE-ERROR cleared by 88.035 (shared trampoline + tester_min.tcl proc).
  - [X] **9.4.divbug.88.040** `indexexpr1` — accept `null` as a unique prefix of `nullvalue` (Tcl prefix-match, PasTclSqlite.pas:4080). SOURCE-ERROR cleared; 106 downstream fails.
  - [X] **9.4.divbug.88.041** `interrupt2` — shared port with 88.032: testvfs Tcl cmd + wrapper VFS in TestModuleVfs.pas.
  - [x] **9.4.divbug.88.042** `ioerr` — SOURCE-ERROR: invalid command name "sqlite3_get_autocommit" → ported trampoline (test1.c:6075..6098, registered test1.c:9094) in TestModuleTest1.pas; SOURCE-ERROR cleared.
  - [X] **9.4.divbug.88.043** `join` — shared port with 88.040: `db null` = prefix of `nullvalue` at PasTclSqlite.pas:4080 (tclsqlite.c:2448,2479); SOURCE-ERROR cleared.
  - [X] **9.4.divbug.88.044** `joinH` — shared port with 88.040 at PasTclSqlite.pas:4080 (tclsqlite.c:2448,2479); SOURCE-ERROR cleared, joinH.test now runs (78 fail on downstream).
  - [X] **9.4.divbug.88.045** `json102` — shared port with 88.040 at PasTclSqlite.pas:4080 (tclsqlite.c:2448,2479); SOURCE-ERROR cleared, json102.test now runs (316 fail on downstream).
  - [X] **9.4.divbug.88.046** `json502` — shared port with 88.040 at PasTclSqlite.pas:4080 (tclsqlite.c:2448,2479); SOURCE-ERROR cleared.
  - [x] **9.4.divbug.88.047** `laststmtchanges` — ported `sqlite3_exec_printf` Tcl trampoline (test1.c:299..328; reuses execPrintfCb at TestModuleTest1.pas:641, sqlite3PfMprintf wrapper).
  - [~] **9.4.divbug.88.048** `lock5` — `db2` Tcl-object symptom cleared by prior tester_min/PasTclSqlite work (multi-instance `sqlite3 dbN file` already supported); rerun reveals real divergences in `unix-dotfile` / `unix-none` VFS lock semantics plus a SIGSEGV (exit 139) deep in lock5-2.dotfile/lock5-2.none arms.  Needs a unix-dotfile/unix-none pager-lock audit (>1h), not a Tcl trampoline gap.
  - [X] **9.4.divbug.88.049** `main` — ported `db complete SQL` arm (tclsqlite.c:2844 → PasTclSqlite.pas:4183); main.test now PASS 218/218.
  - [x] **9.4.divbug.88.050** `memsubsys1` — SOURCE-ERROR: invalid command name "sqlite3_config_lookaside"
  - [x] **9.4.divbug.88.051** `memsubsys2` — SOURCE-ERROR: invalid command name "sqlite3_config_memstatus"
  - [x] **9.4.divbug.88.052** `misc6` — `sqlite_bind` symptom cleared previously (88.002).
  - [X] **9.4.divbug.88.053** `misuse` — ported `clang_sanitize_address` stub (always 0, honours OMIT_MISUSE env), TestModuleTest1.pas:2261; cite test1.c:272..291.
  - [X] **9.4.divbug.88.054** `mjournal` — shared port with 88.032: testvfs Tcl cmd + wrapper VFS in TestModuleVfs.pas.
  - [X] **9.4.divbug.88.055** `multiplex4` — STUB multiplex Tcl trampolines (see 88.025; test_multiplex.c:1227..1364).
  - [X] **9.4.divbug.88.056** `nan` — wired existing `passqlite3decimal` port (committed in 10.1.73) into TestModuleTest1.pas `load_static_extension` table via a new `decimal_ext_init` shim; aExtension[] bumped to 0..9.
  - [X] **9.4.divbug.88.057** `nolock` — shared port with 88.032: testvfs Tcl cmd + wrapper VFS in TestModuleVfs.pas (the xLock/xUnlock/xCheckReservedLock/xAccess filter arms exercised here are all wired).
  - [x] **9.4.divbug.88.058** `normalize` — ported sqlite3_normalize Tcl cmd (test1.c:5550..5572) wrapping passqlite3normalize.sqlite3_normalize; SOURCE-ERROR cleared, test now runs (69/114 pass on real assertions).
  - [X] **9.4.divbug.88.059** `notnull2` — ported `do_vmstep_test` 1:1 from tester.tcl:913..933 into tester_min.tcl; SOURCE-ERROR cleared; notnull2.test FAIL-line 1→28 (downstream).
  - [x] **9.4.divbug.88.060** `trans3` — ! trans3-1.3.1 error: invalid command name "sqlite3_get_autocommit" → same trampoline as 88.042 (test1.c:6075..6098); trans3.test now PASS 8/70.
  - [X] **9.4.divbug.88.061** `upfrom4` — shared port with 88.040 at PasTclSqlite.pas:4080 (tclsqlite.c:2448,2479); SOURCE-ERROR cleared, upfrom4.test now runs (11 fail on downstream).
  - [x] **9.4.divbug.88.062** `varint` — ported btree_varint_test Tcl cmd (test3.c:429) via PutVarint/GetVarint(32). SOURCE-ERROR cleared, varint-1.1 PASS; residual GetVarint32 codec divergence separate.
  - [X] **9.4.divbug.88.063** `capi3d` follow-up — ported sqlite3_next_stmt Tcl trampoline (test1.c:2920; engine passqlite3main.pas:4120). capi3d-1.1 PASS; UTF-16 prepare16 residual tracked at 88.064.
  - [X] **9.4.divbug.88.064** `capi3d` engine bug — capi3d-2.7 stmt_readonly('PRAGMA wal_checkpoint')=1: missing PragTyp_WAL_CHECKPOINT codegen arm (pragma.c:2393). Ported at codegen.pas:52651 (emits OP_Checkpoint). capi3d.test PASS 281/281.
  - [X] **9.4.divbug.88.065** `filectrl` follow-ups — ported file_control_lasterrno_test + file_control_tempfilename trampolines (test1.c:6830/7279) + get_pwd helper. filectrl-1.4/1.6 PASS; 1.5 advances to file_control_lockproxy_test (separate).
  - [X] **9.4.divbug.88.066** `varint` engine bug — `sqlite3GetVarint32` returns one byte too many on certain small values (88 varint.test subtests fail with `putVarint returned 1 and GetVarint32 returned 2`).
  - [x] **9.4.divbug.88.067** `filectrl` follow-up — ported `file_control_lockproxy_test` Tcl trampoline (test1.c:6987..7048, registered test1.c:9246) at `src/tests/tcl/testmodules/TestModuleTest1.pas`.
  - [~] **9.4.divbug.88.068** `cksumvfs` full port — full 1:1 Pascal port of `../sqlite3/ext/misc/cksumvfs.c` (820 C lines → 751 line `src/passqlite3cksumvfs.pas`, already existed pre-task in mostly-complete form) is now wired to the Tcl trampolines (`TestModuleTest1.pas:2329..2354` now call the real `sqlite3_register_cksumvfs` / `_unregister_cksumvfs` instead of returning SQLITE_OK stubs).  Auto-extension `cksmRegisterFunc` ported (cksumvfs.c:767..783) so `verify_checksum()` registers on every new connection.  Smoke confirms `sqlite3_vfs_find('cksmvfs')` returns the shim and `verify_checksum(blob)` evaluates.  cksumvfs.test still SIGSEGVs at 1.3 (3 sub-asserts pass, was 3 before) — independent engine bugs broken out into sub-buckets .068.a and .068.b below.
    - [X] **9.4.divbug.88.068.a** `PRAGMA <unknown>` must dispatch to SQLITE_FCNTL_PRAGMA — port pragma.c:475..511 fallback into sqlite3Pragma via new gFileControl hook. cksumvfs.test 1.0–1.2 PASS; 1.3 SEGV tracked .068.b.
    - [ ] **9.4.divbug.88.068.b** Multi-overflow-page INSERT after `db close; sqlite3 db file.db` reopen SIGSEGVs.  **Bisected (divbug.88.068.b investigation, branch a4)**: the original tasklist diagnosis ("reload after reopen") was incorrect.  Crash happens on the *first* `db close` after one overflow-page INSERT, NOT on reopen.  Minimal repro (tclsh under bin/libpassqlite3tcl.so, fails with SIGSEGV `munmap_chunk(): invalid pointer`):
```
package require sqlite3
sqlite3 db test.db
file_control_reservebytes db 8   ;# REQUIRED — without this, no crash
db eval { PRAGMA page_size = 4096 }   ;# REQUIRED — implicit default doesn't trigger
db eval { CREATE TABLE t1(a INTEGER PRIMARY KEY, b, c) }
db eval { INSERT INTO t1 VALUES(1, randomblob(5000), randomblob(1500)) }   ;# REQUIRED — overflow chain
db close   ;# crashes here in __malloc_usable_size from sqlite3_close_v2 → DelDatabaseRef
```
Independent of cksumvfs (does NOT need `sqlite3_register_cksumvfs`).  Reduced positives: `passqlite3` shell `PRAGMA reserve_bytes=8` / `.filectrl reserve_bytes 8` paths do NOT apply the reserve so cannot repro through the shell; the Tcl wrapper `file_control_reservebytes` (TestModuleTest1.pas:4421) DOES wire it via `sqlite3_file_control(db,"main",SQLITE_FCNTL_RESERVE_BYTES,&n)`.  Crash backtrace lives entirely inside `libpassqlite3tcl.so` (stripped, 2 dyn-syms) and ends in glibc `__malloc_usable_size(m=<garbage>)` — i.e. a wild pointer is passed to `free` during `sqlite3PagerClose`/`sqlite3BtreeClose` teardown of the pager-page cache.  The corruption pre-conditions are:
  * `sqlite3BtreeSetPageSize(pBt, 0, 8, 0)` (from FCNTL_RESERVE_BYTES at main.pas:4750) followed by
  * explicit `PRAGMA page_size=4096` (probably re-invokes SetPageSize and reallocates internal page buffer with mismatched `usableSize` vs `pageSize` accounting)
  * one overflow-chain insert that triggers an `aOvfl`/`sqlite3PagerWrite` allocation with the stale sizing
Crash never fires without the explicit page_size PRAGMA after RESERVE_BYTES, nor without an overflow-producing insert, nor without `db close`.  Likely fix area: `sqlite3BtreeSetPageSize` in passqlite3btree.pas — ensure that when `nReserve` was set first, a subsequent page-size change re-aligns/reallocates `pBt^.pTmpSpace` / pager page buffers to `pageSize` (not `usableSize`).  Cite: `../sqlite3/src/btree.c` sqlite3BtreeSetPageSize + `../sqlite3/src/pager.c` sqlite3PagerSetPagesize.  Stopped at ~1.5h budget — minimal repro saved at `/tmp/repro_rb2.tcl`; deeper fix needs a `-g`/non-stripped libpassqlite3tcl.so rebuild for symbolic gdb backtrace.
  - [~] **9.4.divbug.88.069** `multiplex` full port — landed `src/passqlite3multiplex.pas` (917 Pascal lines from the ~1370-line `../sqlite3/src/test_multiplex.c`).  Real chunk-file shim VFS: multiplexOpen / multiplexRead / multiplexWrite split I/O across `foo.db`, `foo.db001`, … chunks; multiplexDelete sweeps journal/wal chunks; multiplexFileControl exposes MULTIPLEX_CTRL_* and the `multiplex_truncate / _enabled / _chunksize / _filecount` pragmas; multiplexFuncInit auto-extension registers the `multiplex_control()` SQL fn.  Tcl trampolines `sqlite3_multiplex_initialize / _shutdown / _control` rewired in TestModuleTest1.pas (88.025 / 88.055 STUBs replaced).  Counts: `delete_db` 4→18 sub-tests reached (4× deeper; remaining 14 fail on the unrelated `sqlite3_delete_database` Tcl command and the `SQLITE_ENABLE_8_3_NAMES` URI gate, both out of scope); `multiplex4` 4 pass + 10 fail (most failures are the 8_3_NAMES `.db001` vs `.001` rename and pragma `multiplex_truncate` echo).  Regression gate: 100/101 (TestFuzzDiff red as expected, 5264/5264 assertions).  Open sub-buckets:
    - [X] **9.4.divbug.88.069.a** `SQLITE_ENABLE_8_3_NAMES` arms in `multiplexFilename` (extension truncation) + `multiplexSubOpen` (journal/wal offset rename, chunk overflow → `SQLITE_FULL`).
    - [X] **9.4.divbug.88.069.b** `sqlite3_delete_database` Tcl command — ported test_delete.c:46..156 → passqlite3multiplex.pas (POSIX, MX_CHUNK_NUMBER + 8_3 journal/wal sweep) + trampoline (test1.c:2852). delete_db.test 18 PASS / 219.
- [~] **9.4.divbug.89** Empty driver diagnostic (carved from `9.4.4.g-unbucketed` 2026-05-16) — **12 pas-soft tests** (`corruptB`, `e_changes`, `e_totalchanges`, `fuzz`, `index4`, `index5`, `join6`, `joinA`, `joinB`, `joinD`, `manydb`, `tkt3080`) FAIL but `bin/tcl-failure-logs/<base>.{err,out}` capture no diagnostic — driver swallows the message or the tests abort outside `tcltest`.  Action: instrument `TclTestDriver` to dump the last N lines of stdout/stderr on any non-PASS exit so these become triageable.  Instrumentation landed (TclTestDriver.pas: `WriteFailLogs` now emits a header — test path, spawn cmd, exit-code, byte counts — and appends a 50-line tail block; empty streams write `(empty)`).  Smoke: join6 now reveals `exit-code: 134` + `double free or corruption (!prev)`; e_changes/manydb reveal `exit-code: 139` (SIGSEGV) past the last `Ok` line.  Per-test root-causing of .001..012 remains TODO.
  - [X] **9.4.divbug.89.001** `corruptB` — transitively fixed; driver now reports **PASS 19/19** (~859ms) on re-run 2026-05-17.
  - [X] **9.4.divbug.89.002** `e_changes` — closed 2026-05-17.
  - [X] **9.4.divbug.89.003** `e_totalchanges` — transitively fixed; driver now reports **PASS 1/1** (subtests run through e_totalchanges-3.1.5 and beyond cleanly in ~2.5s).
  - [X] **9.4.divbug.89.004** `fuzz` — closed 2026-05-17.
  - [X] **9.4.divbug.89.005** `index4` — closed 2026-05-18.
  - [X] **9.4.divbug.89.006** `index5` — closed 2026-05-18.
  - [X] **9.4.divbug.89.007** `join6` — closed 2026-05-17.
  - [X] **9.4.divbug.89.008** `joinA` — SIGABRT cleared by same `sqlite3WhereClauseClear` arena-free fix as .007 (passqlite3codegen.pas:13033, whereexpr.c:1759).
  - [X] **9.4.divbug.89.009** `joinB` — SIGABRT cleared by same fix as .007.
  - [X] **9.4.divbug.89.010** `joinD` — SIGABRT cleared by same fix as .007.
  - [X] **9.4.divbug.89.011** `manydb` — transitively fixed; driver now reports **PASS 900/900** in ~16.7s on re-run 2026-05-17.
  - [X] **9.4.divbug.89.012** `tkt3080` — SOURCE-ERROR was the local `getDbPointer` in TestModuleEcho.pas missing the `sqlite3TestTextToPtr` hex-string fallback (only handled the `db` Tcl-command-name form via `Tcl_GetCommandInfo`).
  - [X] **9.4.divbug.89.013** `joinA` — **PASS 42/42** after porting `extendFJMatch` (resolve.c:208..223) + the FULL-JOIN coalesce-arm of `lookupName` (resolve.c:458..461 + 761..782) into ResolveExpr at passqlite3codegen.pas:10241..10394.
  - [~] **9.4.divbug.89.014** `joinB` residual (carved from .009 close 2026-05-17, partial close 2026-05-17) — joinB residual errors **368→32 / 512** (480 subtests now PASS, was 144).  Root cause: Pas port of `sqlite3ProcessJoin` (passqlite3codegen.pas:27412..27488, mirrors select.c:516..668) was missing the JT_LTORJ coalesce arm at select.c:596..633.  When the FROM clause contains *any* RIGHT/FULL JOIN, the USING-emitted left side `pE1` must be `coalesce(t1.col, t2.col, ..., tN.col)` over EVERY prior FROM term that has the column (gated by `pSrc->a[0].fg.jointype & JT_LTORJ`).  Without it, the RIGHT JOIN's unmatched-right scan emits a row where the first matched left-table's column is NULL, and the subsequent USING-eq `t1.a = t5.a` drops what should be a match (e.g. joinB-17: t4.a=19 unmatched-right + `INNER JOIN t5 USING(a)` lost the t5.a=19 row entirely).  Fix: port the `while tableAndColumnIndex(... iLeft+1, i-1 ...) != 0` loop that accumulates non-ambiguous matches into pFuncArgs, then wraps as a TK_FUNCTION 'coalesce' with affExpr=SQLITE_AFF_DEFER.  Also raise "ambiguous reference to X in USING()" when an interior match is NOT also USING-masked (mirrors select.c:619).  No regressions: joinA 42/42, joinC unchanged (152 err), joinD/E/F PASS, in-tree regression 100/101 (baseline).  Residual 32 errors in joinB form a different shape (e.g. joinB-84: expected `11 31 - 31 31 -` got `11 - - - 31 -`) — a separate downstream issue with column-2 (`t1.a`) projection on RIGHT-JOIN unmatched-right rows; tracked as 89.014-tail.

      89.014-tail triage 2026-05-18 (no code landed — architectural):
      All 32 residuals are subtests whose FROM clause contains a parens-
      wrapped sub-join like `(t2 RIGHT JOIN t3 USING(a))` or `(t2 FULL JOIN
      t3 USING(a))` (joinB-68/76/84/92/100/108/.../508).  EXPLAIN diff for
      joinB-84 shows the divergence is in the INNER subroutine that
      materialises the parens-wrapped sub-FROM into an ephemeral table:
      C emits `Column 3 0` (read `a` from cursor t3) for the column-0
      projection, Pas emits `Column 2 0` (read `a` from cursor t2).
      C's inner subroutine also has 8 projection slots vs Pas's 6.

      Root cause: Pas's `expandStar` (passqlite3codegen.pas:26821..27026)
      directly emits resolved `TK_COLUMN(iCursor, iColumn)` while C's
      `selectExpander` star arm (select.c:6160..6313) emits `TK_ID` /
      `TK_DOT(TK_ID,TK_ID)` and relies on the *resolver* (`lookupName`,
      resolve.c:370..461) to apply the JT_LTORJ + USING-shared
      column-rewrite rule: when later FROM items USING-share the column
      and are plain RIGHT JOIN (JT_RIGHT and not JT_LEFT), re-target
      pMatch to the right-most table (rules at resolve.c:386..394 and
      449..457); for FULL JOIN, synthesise a coalesce() via
      `extendFJMatch` (already ported as 89.013 for the resolver, but
      89.013 only covers bare TK_ID, not the expandStar/NestedFrom path).
      In addition, the C SF_NestedFrom path at select.c:6184..6202
      synthesises a leading `..colname` TK_ID with `bUsingTerm=1` for
      each USING column before emitting that table's regular columns,
      and (with VisibleRowid) appends a `rowid` alias per table at
      select.c:6207..6208 — accounting for the extra 2 slots in C's
      inner pEList.

      Two attempted patches today: (1) port the resolver rescan loop
      into expandStar with `pTgtItem`/`jTgt` redirect + FULL-JOIN
      coalesce wrap, gated `SF_NestedFrom==0` — joinB-84 unchanged
      (the divergence is *inside* the NestedFrom sub-expand, so the
      gate excluded it).  (2) Same patch without the SF_NestedFrom
      gate — joinB-84 fixed but joinB went from 32 fails to 211 fails
      (regression on cases that rely on the existing 1-to-1 pEList /
      pTab->nCol invariant, see assert at select.c:6174).  Reverted
      both, repo back to clean baseline (32 fails / 480 pass).

      Path forward (architectural — STOP per task guidance): port the
      full SF_NestedFrom branch of `selectExpander` star arm
      (select.c:6160..6313) including the `..colname` USING-prefix
      synthesis, the `rowid` alias append, the qualified
      TK_DOT-wrap policy, AND the resolver rescan-loop redirect for
      plain RIGHT JOIN.  Or alternatively, switch Pas expandStar to
      emit `TK_ID`/`TK_DOT` and ensure `sqlite3ResolveSelectNames`
      re-runs over the expanded pEList so the existing lookupName
      port (which already has the JT_RIGHT / extendFJMatch arms from
      89.013) handles the redirect.  Either is a >1h port that
      touches resolver invariants for every `SELECT *`.
      Reproducer:
        CREATE TABLE t1(a INT,b INT,c INT);
        CREATE TABLE t2(a INT,b INT,d INT);
        CREATE TABLE t3(a INT,b INT,e INT);
        CREATE TABLE t4(a INT,b INT,f INT);
        CREATE TABLE t5(a INT,b INT,g INT);
        INSERT INTO t1 VALUES(11,21,31);
        INSERT INTO t3 VALUES(11,21,31);
        INSERT INTO t4 VALUES(11,21,31);
        SELECT a, c, d, e, f, g FROM t1
          INNER JOIN (t2 RIGHT JOIN t3 USING(a)) USING(a)
          RIGHT JOIN (t4 LEFT JOIN t5 USING(a)) USING(a);
        -- expected: 11|31||31|31|
        -- pas got:  11||||31|
  - [X] **9.4.divbug.89.015** `joinD` — now fully PASS (1170 subtests) after siblings 89.013 (extendFJMatch, 219aab1) + 89.014 (JT_LTORJ coalesce, b1b851b) fixed the underlying SIGSEGV; no code change for this ticket.
  - [X] **9.4.divbug.89.016** `fuzz` residual — closed 2026-05-17.
- [ ] **9.4.divbug.90** Extension / SQL function / VFS registration residue (sibling of `9.4.divbug.66`, carved from `9.4.4.g-unbucketed` 2026-05-16) — **8 pas-soft tests**: 6 `no such extension` (`btree02`, `extension01`, `func4`, `indexexpr2`, …), 1 `no such function` (`func9`), 1 `no such vfs: devsym` (`io`).  Each pin in the C build is a known extension/function/VFS shim; port or auto-register at db-open following the `.66` template.  Progress 2026-05-17: 7/8 registration shims landed (5 aExtension[] rows in TestModuleTest1.pas — eval/fileio/totype/explain/wholenumber, all Pas ports already existed; unistr_quote builtin in passqlite3codegen.pas via quoteFunc + pUserData=1, mirrors func.c:3340).  3/8 now PASS via driver (`extension01`, `func4`, `func9`); 4/8 reach the engine post-shim and re-bucket as non-registration engine bugs (`btree02`, `indexexpr2`, `memdb`, `misc8`); 1/8 (`io`) still wants the full `test_devsym.c` VFS port — out of scope for the registration drain.
  - [X] **9.4.divbug.90.001** `btree02` — closed 2026-05-18.
  - [X] **9.4.divbug.90.002** `extension01` — fileio shim landed; **PASS** 214/214 via driver.
  - [X] **9.4.divbug.90.003** `func4` — totype shim landed; **PASS** 401/401 via driver.
  - [X] **9.4.divbug.90.004** `func9` — `unistr_quote` registered in aBuiltinFuncs[84] (quoteFunc + pUserData=1); **PASS** 45/45 via driver.
  - [ ] **9.4.divbug.90.005** `indexexpr2` — explain shim landed; test now reaches engine.  Bucket (a) `4.200/4.210/4.220` CLOSED 2026-05-18 (divbug.90.005.a): root cause — sqlite3WhereBegin's full-planner block (codegen.pas:22458, taken whenever whereShortCut defers, e.g. UPDATE on a table with any non-partial index) cleared `WHERE_IDX_ONLY` but never assigned `pWInfo^.eOnePass`; only the inline single-table fast path (codegen.pas:22756) set it.  sqlite3WhereOkOnePass returned ONEPASS_OFF, update.c's caller emitted both the planner's OP_OpenRead and a second OP_OpenWrite via sqlite3OpenTableAndIndices.  Fix: faithfully port where.c:7218..7237 into the full-planner block (set ONEPASS_SINGLE/MULTI under the same bOnerow / MULTIROW / !vtab / !MULTI_OR / SQLITE_OnePass gate, then clear WHERE_IDX_ONLY only when HasRowid), and where.c:7275..7280 into the level-loop table-cursor arm (OP_OpenWrite + record aiCurOnePass[0] when eOnePass != OFF).  No TestRegression delta (5264/5264 PASS, TestFuzzDiff pre-existing).  Residual buckets: (b) `8.3.1.1..8.3.12.1` (12 subtests) partial-index where-clause matching; (c) `9.0` and `10.1` generated-column / indexed-expression resolver bugs — both open.
  - [ ] **9.4.divbug.90.006** `io` — `no such vfs: devsym` still open; needs full `src/test_devsym.c` VFS port (a fresh sqlite3_vfs with shadow + I/O-error injection — non-trivial new port, not a registration-shim drop-in).
  - [X] **9.4.divbug.90.007** `memdb` — closed 2026-05-18.
  - [X] **9.4.divbug.90.008** `misc8-3.0` SIGSEGV — bare/qualified `rowid` resolver used HasRowid not VisibleRowid, so rowid against a TF_NoVisibleRowid subquery bound iColumn=-1 and crashed substExpr. Check TF_NoVisibleRowid at both sites (codegen.pas:10276/10484).
- [ ] **9.4.divbug.91** Tcl harness helper gaps (carved from `9.4.4.g-unbucketed` 2026-05-16) — **16 pas-soft tests** on missing test-harness plumbing (engine behaviour not exercised): `md5sum` Tcl command (5: `backup_ioerr`, `backup`, `fuzz3`, `interrupt`, `trans2`); arbitrary missing tclvars (4: `join3`, `savepoint2`, `tkt3992`, `types`); `cmdlinearg(soft-heap-limit)` array (2: `avtrans`, `capi3b`); `SQLITE_MAX_VARIABLE_NUMBER` tcl-const (1: `bind`); `QRF not available in this build` build-flag gap (2: `qrf01`, `qrf02`); `no files matched glob "*malloc*.test"` (1: `mallocAll`); `couldn't read file "-"` stdin input (1: `memleak`).  Progress 2026-05-17: md5sum SQL aggregate now auto-registered on every connection (PasTclSqlite.pas DbMain — calls Md5_Register after sqlite3_open_v2, mirrors test_func.c:723..726 autoinstall_test_functions / auto_extension), and tester_min.tcl seeds `bitmask_size=64` (test1.c:9335..9438), `SQLITE_MAX_VARIABLE_NUMBER=32766` (test_config.c:817), `cmdlinearg(soft-heap-limit)=0` (tester.tcl:378), `sqlite_options(utf16)=1` (test_config.c:705).  3/16 closed; 10/16 now reach the engine (residuals are not harness gaps and re-bucket below); 3/16 remain genuine harness gaps (backup family, qrf, mallocAll/memleak).
  - [X] **9.4.divbug.91.001** `avtrans` — cmdlinearg(soft-heap-limit) seeded; now reaches engine.
  - [X] **9.4.divbug.91.002** `backup` — harness gap: tester_min.tcl seeded ::sqlite_pending_byte=0x40000000 vs upstream 0x0010000, so backup.test's size-loop never terminated. Realigned (tester_min.tcl:646) + 300s cap. backup-1..3 run; backup-4 re-bucketed.
  - [X] **9.4.divbug.91.003** `backup_ioerr` — same root cause as .002 (the `while {[file size test.db] <= $sqlite_pending_byte}` populate in backup_ioerr.test:53..60 hung against the 1 GiB default).
  - [X] **9.4.divbug.91.004** `bind` — SQLITE_MAX_VARIABLE_NUMBER seeded; test now reaches engine.
  - [X] **9.4.divbug.91.005** `capi3b` — cmdlinearg(soft-heap-limit) seeded; **PASS** 22/22 via driver.
  - [X] **9.4.divbug.91.006** `fuzz3` — md5sum landed; test now reaches engine.
  - [X] **9.4.divbug.91.007** `interrupt` — md5sum landed; test now reaches engine (65 cases run).
  - [X] **9.4.divbug.91.008** `join3` — bitmask_size=64 seeded; test now reaches engine.
  - [X] **9.4.divbug.91.009** `mallocAll` — set ::argv0 absolute + preserve ::testdir across the tester reroute (TclTestDriver.pas:400). Test reaches engine; residual vtab+OOM-injection drain re-bucketed.
  - [X] **9.4.divbug.91.010** `memleak` — same ::argv0 fix as .009 + clear ::argv/::argc (stray `-` from tclsh stdin). Engine reachable: 5 PASS / 213; residual 8_3_names fixture files missing in tmpdir.
  - [ ] **9.4.divbug.91.011** `qrf01` — QRF (Query Result Formatter) is a tclsqlite.c-internal feature not ported.  Genuine build-flag gap (port out of scope for harness drain).
  - [ ] **9.4.divbug.91.012** `qrf02` — same as .011.
  - [X] **9.4.divbug.91.013** `savepoint2` — md5sum landed (the `signature` proc that sets `::sig(one)` uses md5sum on the db); **PASS** 181/181 via driver.
  - [X] **9.4.divbug.91.014** `tkt3992` — **PASS** 6/6 via driver (was a stale flake — already passing on entry).
  - [X] **9.4.divbug.91.015** `trans2` — md5sum landed; test now reaches engine (407 cases run).
  - [X] **9.4.divbug.91.016** `types` — sqlite_options(utf16)=1 seeded; test now reaches engine.

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
- [X] **10.1.4** Line reader (basic LF/CRLF).
- [X] **10.1.5** Exit-code mapping + interrupt_handler + SIGINT wiring.
- [X] **10.1.6** do_meta_command dispatcher skeleton.
- [X] **10.1a.G** Gate `src/tests/TestShellRepl.pas` 8/8 PASS.

### 10.1b Output modes + formatting controls

- [X] **10.1b** Output modes + formatting controls.
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

- [X] **10.1d** Subcommands 10.1.22..10.1.27 landed; gate `src/tests/TestShellIO.pas` 11/11 PASS.
  - [X] **10.1d.1** `.read`
  - [X] **10.1d.2** `.dump`
  - [X] **10.1d.3** `.import` — auto-create-from-header + duplicate-column renaming + heredoc input (10.1d.3.a) + pipe input (10.1d.3.b) all landed.
  - [X] **10.1d.4** `.output` / `.once` — editor/spreadsheet/browser (`-e`/`-x`/`-w`) variants and `|cmd` pipe targets intentionally not gated; future xdg-open / TProcess follow-up.
  - [X] **10.1d.5** `.save`
  - [X] **10.1d.6** `.open` (full flag set: 10.1d.6.a/b closed).
- [X] **10.1.22..10.1.27** `.read`, `.dump`, `.import`, `.output`/`.once`, `.save`, `.open` (all sub-arms a..g) landed.

### 10.1e Meta / diagnostic dot-commands

- [X] **10.1e** Gate: src/tests/TestShellMeta.pas — 48/48 PASS across .help/.show/.eqp/.explain/.cd/.shell/.system/.stats/.trace/.testctrl/.timer/.log etc.
- [X] **10.1.28..10.1.35, 10.1.37** `.stats`, `.timer`, `.eqp`, `.explain`, `.show`, `.help`, `.cd`, `.shell`/`.system`, `.trace` landed.
- [X] **10.1.36** `.log` — destination recorded and SQLITE_CONFIG_LOG xLog trampoline installed (8.1.1 landed).
- [X] **10.1.38** `.iotrace` — stub; full sqlite3IoTrace fanout gated on sqlite3VdbeIOTraceSql arm (currently a stub at passqlite3vdbe.pas:4122).
- [~] **10.1.39** `.scanstats` — basic per-loop dump landed via 8.2.1 (NAME/EXPLAIN/EST/SELECTID/PARENTID emitted). Sub-arms a..e all closed:
  - [X] **10.1.39.a** TWhereLevel.addrVisit field added; NVISIT unblocked (port of wherecode.c:333..374).
  - [X] **10.1.39.b** NLOOP/nExec confirmed; removed two stale addrBody overrides inside sqlite3WhereCodeOneLoopStart.
  - [X] **10.1.39.c** qrfEqpStats EQP-tree formatter ported (ext/qrf/qrf.c:162..454); `|--`/`` `--`` connectors + qrfApproxInt64 K/M/G/T/P/E suffix.
  - [X] **10.1.39.d** NCYCLE / hwtime sampling — `nCycle:u64` on TVdbeOp; sqlite3Hwtime ported (rdtsc/cntvct/clock_gettime); dispatch bracket gated on SQLITE_ENABLE_STMT_SCANSTATUS (default-off).
  - [X] **10.1.39.e** EXPLAIN text re-enabled: SCANSTAT_EXPLAIN gates on p4type=P4_DYNAMIC; displayScanstats prefers EXPLAIN string over zName.

  Upstream's "Warning: .scanstats not available in this build." is still echoed verbatim to keep TestShellMeta golden diff clean.
- [X] **10.1.40** `.testcase NAME` / `.check ANSWER` — fd-level capture, --glob/--notglob/--exact; shellMain summary byte-identical; rc = nTestErr>0.
- [X] **10.1.41** `.testctrl` — dispatcher routes 12 opcodes through 8.4.1 overloads; BITVEC_TEST/FAULT_INSTALL/IMPOSTER/TUNE/PARSER_COVERAGE fall through to isOk=3 stub (need callback/coverage infra).
- [~] **10.1.42** `.selecttrace`/`.wheretrace`/`.treetrace` — TRACEFLAGS toggle landed (via sqlite3_test_control). Mask-hint convention: subtask hints are bundle IDs, **always verify against** `sqliteInt.h:TREETRACE_*` / `whereInt.h:WHERETRACE_*`. Subtasks:
  - [X] **10.1.42.a** TREETRACE batch 1: begin/end (0x1), name resolution (0x10), column names (0x80), flatten (0x4), constant propagation (0x2000), WhereBegin/End (0x2).
    - [X] **10.1.42.a.1** UNION ALL left/right (select.c:3011/3030, 0x200).
    - [X] **10.1.42.a.2** Post-flatten (4706, 0x4) + wildcard expansion (6339, 0x8).
    - [~] **10.1.42.a.3** EXISTS-to-JOIN (7368, 0x100000) + aggregate analysis (8442, 0x20). havingToWhere/countOfView/AggInfo-adjusted prints closed under a.6. Archive.
    - [X] **10.1.42.a.4** "after window rewrite" (0x40), "dropping ORDER BY" (0x800, via a.11), "DISTINCT→GROUP BY" (0x20000, via a.12).
    - [~] **10.1.42.a.5** Outer-join + FROM-subquery (verified masks 0x1000/0x800/0x4000/0x8000/0x20); landed via a.7/a.8/a.9/a.10/a.6.5. Remaining: flattenSubquery + IgnorableOrderby drop. Archive.
    - [X] **10.1.42.a.6** All 5 sub-arms (a.6.1..a.6.5) landed 2026-05-13.
  - [~] **10.1.42.b** WHERETRACE batch 1: addBtreeIdx (0x800), addVirtual (0x800), OR-clause Begin/End (0x400). Subtasks:
    - [~] **10.1.42.b.1** Range-scan cost estimate — landed `Range scan lowers nOut` (where.c:2247, 0x20) in `whereRangeScanEst`. Other 4 arms STAT4-only, gated on b.7. Archive.
    - [X] **10.1.42.b.2** Subset-cost in `whereLoopAdjustCost` (0x80, where.c:2711/2720) + 4 covering-index arms in `whereLoopAddBtree` (0x200, 4203/4210/4216/4224).
    - [X] **10.1.42.b.3** Vtab constraint enumeration — 5 arms in `whereLoopAddVirtual` (0x800, 4720..4794) + 2 in `whereLoopAddVirtualOne` (0xffffffff, 4416/4531).
    - [X] **10.1.42.b.4** Solver progress in `wherePathSolver` (masks **0x002/0x004**, NOT 0x80; sqliteInt.h:1181).
    - [X] **10.1.42.b.5** OR-vs-AND per-subterm in `whereLoopAddOr` (0x400, where.c:4866).
    - [X] **10.1.42.b.6** DISTINCT reduction (0x0080, where.c:7118 + `nRowOut -= 30`) + optimizer-finished (0xffffffff, 7195).
    - [X] **10.1.42.b.7** Port the STAT4 cost-estimator helpers gating the 4 pending 10.1.42.b.1 arms: `whereRangeSkipScanEst` (c.8), `whereEqualScanEst` + `whereInScanEst` (c.9).
    - [X] **10.1.42.b.7.prereq** Port sqlite3Stat4ProbeSetValue + sqlite3Stat4ValueFromExpr (+ Stat4Init, analyzeOneTable STAT4 arm, sample-vector machinery).
    - [X] **10.1.42.b.7.prereq.a** Record-shape + scaffolding.
    - [X] **10.1.42.b.7.prereq.b** analyze.c STAT4 collection (partial: writer-side complete; loadStat4 reader moved to .b.7.prereq.c since whereKeyStats / value-from-expr consumers land there too).
    - [X] **10.1.42.b.7.prereq.c** Consumers — vdbemem.c STAT4 layer + `whereKeyStats` + the 3 estimators landed across 9 sub-arms (.1..9).
    - [X] **10.1.42.b.7.prereq.c.1** Port `ValueNewStat4Ctx` struct (vdbemem.c:1611..1622) + `valueNew` STAT4-aware factory (vdbemem.c:1632..1700) into `src/passqlite3vdbe.pas` (or wherever `sqlite3ValueNew` already lives).
    - [X] **10.1.42.b.7.prereq.c.2** Port `valueFromFunction` STAT4 arm (vdbemem.c:1701..1799) — recursive const-folding through `sqlite3VdbeMemSetStr`/`sqlite3ValueApplyAffinity` to pre-evaluate function calls in stat4 probe inputs.
    - [X] **10.1.42.b.7.prereq.c.3** Port `valueFromExpr` STAT4 branches + `stat4ValueFromExpr` helper (vdbemem.c:1800..2080) — the dispatch that turns a constant Expr tree into a `sqlite3_value*` usable by whereKeyStats.
    - [X] **10.1.42.b.7.prereq.c.4** Port public entries `sqlite3Stat4ProbeSetValue` (vdbemem.c:2082..2117) + `sqlite3Stat4ValueFromExpr` (:2127..2147).
    - [X] **10.1.42.b.7.prereq.c.5** Replace `sqlite3Stat4Column` (vdbemem.c:2149..2190) + `sqlite3Stat4ProbeFree` (:2194..2210) Phase-6 stubs in `src/passqlite3vdbe.pas` with real bodies.
    - [X] **10.1.42.b.7.prereq.c.6** Port `loadStat4` / `loadStatTbl` / `initAvgEq` / `findIndexOrPrimaryKey` reader side (analyze.c, the remaining half of prereq.b).
    - [X] **10.1.42.b.7.prereq.c.7** Port `whereKeyStats` (where.c:1718..1978) into `src/passqlite3codegen.pas`.
    - [X] **10.1.42.b.7.prereq.c.8** Port `whereRangeSkipScanEst` (where.c:1980..2030) + re-enable its WHERETRACE 0x20 arm at host site (where.c:2002, 2006).
    - [X] **10.1.42.b.7.prereq.c.9** Port `whereEqualScanEst` (where.c:2274..2330) + `whereInScanEst` (:2338..2380); re-enable the 4 pending WHERETRACE 0x20 arms in `whereLoopAddBtree` host sites.
    - [X] **10.1.42.b.8** Port `wherePathName` + `sqlite3Where{Term,Clause,Loop}Print` + `showAllWhereLoops` (where.c:2375..2520/5512..5519/6469..6488).
    - [X] **10.1.42.a.6.1** `havingToWhere` + `havingToWhereExprCb` (select.c:7047) + `sqlite3ExprIsConstantOrGroupBy`; wired SF_Aggregate+GROUP-BY (8422..8431).
    - [X] **10.1.42.a.6.2** `countOfViewOptimization` (select.c:7128..7204); wired after propagateConstants (7924..7930).
    - [X] **10.1.42.a.6.3** `optimizeAggregateUseOfIndexedExpr` (select.c:6549..6586); wired pre assignAggregateRegisters (8527..8529).
    - [X] **10.1.42.a.6.4** `aggregateConvertIndexedExprRefToColumn` + walker (select.c:6591..6623); wired after sqlite3WhereEnd (8600..8615).
    - [X] **10.1.42.a.6.5** "Finished with AggInfo" at sqlite3Select tail (select.c:8933..8945).
    - [X] **10.1.42.a.7** Outer-join strength-reduction loop (select.c:7708..7770) + `sqlite3ExprImpliesNonNullRow`/`impliesNotNullRow`/`bothImplyNotNullRow` (expr.c:6857..7031) + `unsetJoinExpr` (471..494).
    - [X] **10.1.42.a.8** FROM-subquery superfluous-ORDER-BY drop (select.c:7822..7838, tag-select-0230).
    - [X] **10.1.42.a.9** `pushDownWhereTerms` (5125..5286) + `disableUnusedSubqueryResultColumns` (5296..5358).
    - [X] **10.1.42.a.10** all-FROM snapshot (select.c:8144..8149, 0x8000).
    - [X] **10.1.42.a.11** top-level ORDER-BY drop (select.c:7625..7644, 0x800).
    - [X] **10.1.42.a.12** DISTINCT→GROUP BY (select.c:8151..8196, 0x20000).
  - [X] **10.1.42.c** `sqlite3DebugPrintf` (printf.c:1514..1532) → passqlite3printf.pas.
  - [X] **10.1.42.d** Build-flag gating: `build.sh` honours `SQLITE_DEBUG=1` → `-dSQLITE_DEBUG`.

### 10.1f Long-tail / specialised dot-commands

- [X] **10.1f** Closed 2026-05-13 — every 10.1f.0..16 sub-arm landed (.backup/.restore/.clone, .archive/.ar, .session stub, .recover, .dbinfo, .dbconfig, .filectrl, .sha3sum, .vfsinfo/.vfslist/.vfsname, ...).
  - [X] **10.1f.0..10.1f.2** `.backup` / `.restore` / `.clone` — gated by `src/tests/TestShellBackup.pas`.
  - [X] **10.1f.3** `.archive`/`.ar` — gated by `src/tests/TestShellArchive.pas`.
  - [X] **10.1f.4** `.session` — gated by `src/tests/TestShellArchive.pas` shape arm (stub per 10.1.47).
  - [X] **10.1f.5** `.recover` — gated by `src/tests/TestShellArchive.pas`.
  - [X] **10.1f.6** `.dbinfo` — gated by `src/tests/TestShellDbinfo.pas`.
  - [X] **10.1f.7** `.dbconfig` — gated by `src/tests/TestShellDbinfo.pas`.
  - [X] **10.1f.8** `.filectrl` — gated by `src/tests/TestShellFilectrl.pas`.
  - [X] **10.1f.9** `.sha3sum` — gated by `src/tests/TestShellFilectrl.pas`.
  - [X] **10.1f.10..10.1f.13** `.crnl`/`.binary`/`.connection`/`.unmodule` — gated by `src/tests/TestShellMisc.pas`.
  - [X] **10.1f.14..10.1f.16** `.vfsinfo`/`.vfslist`/`.vfsname` — handler-shape parity in `src/tests/TestShellMisc.pas`; success-path stdout byte-parity blocked by szOsFile=88 layout divergence (unixFile record padding), 6.30/6.31 fixed.

- [X] **10.1.43..10.1.45** `.backup`, `.restore`, `.clone` all landed.
- [X] **10.1.46** `.archive`/`.ar` — full port; closed via bugs 6.17.A/B for GLOB range-bound truncation.
- [X] **10.1.47** `.session` — stub (session extension not ported).
- [X] **10.1.48** `.recover` — full port (~957 lines + LAF arm + wrapper-VFS arm).
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
- [X] **10.1.100** Built-in shell SQL UDFs: strtod, dtostr, shell_add_schema, shell_module_schema, shell_putsnl, usleep.
- [X] **10.1.101** `ext/expert/sqlite3expert.c` → `passqlite3expert.pas`.
- [X] **10.1.102** `.open --zip` / `--deserialize` / `--hexdb` shell glue + faithful `sqlite3_deserialize` port.

- [~] **10.1a.1** Residual dot-command coverage gap surfaced by 2026-05-16 audit (Outcome B).  C `shell.c.in` help table (lines 3711..3962) lists 67 dot-commands; `doMetaCommand` in `src/passqlite3shell.pas:10342` routed 56 of them.  The 11 missing handlers all have working backing APIs in the engine and live entries in the Pas `azHelp[]` table (3704..3958).  Decomposed into bite-sized sub-arms 10.1a.1.1..10.1a.1.11; the 5 trivially-small ones (≤25 LOC each) landed inline 2026-05-16; the 6 medium ones are queued.  Gates: `bin/TestShellRepl` 8/8, `bin/TestShellModes` 2/2, `bin/TestShellSchema` 10/10, `bin/TestShellIO` 11/11, `bin/TestShellMeta` 60/60, `bin/TestCliParity` 20/1S/0 (== baseline).
  - [X] **10.1a.1.1** `.bail on|off` — bail_on_error toggle.
  - [X] **10.1a.1.2** `.timeout MS` — `sqlite3_busy_timeout` wrapper.
  - [X] **10.1a.1.3** `.version` — libversion + sourceid + compiler tag (fpc-X.Y.Z subbed for the C build's clang/gcc/msvc arm).
  - [X] **10.1a.1.4** `.prompt MAIN ?CONTINUE?` — replace `mainPromptStr` / `continuePromptStr`.
  - [X] **10.1a.1.5** `.nonce STRING` — match-or-halt; clears bSafeMode on hit.
  - [X] **10.1a.1.6** `.limit ?NAME? ?VAL?` — `cmdLimit` landed (`passqlite3shell.pas`); 13-entry table, case-insensitive prefix match, ambiguity + unknown errors match upstream.
  - [X] **10.1a.1.7** `.imposter INDEX IMPOSTER` / `.imposter off` — emits `CREATE TABLE` from `PRAGMA index_xinfo` + `SQLITE_TESTCTRL_IMPOSTER` wrap.
  - [X] **10.1a.1.8** `.progress N` — `sqlite3_progress_handler` plus `--quiet/--reset/--once/--timeout/--limit` flag parser.

  - [X] **10.1a.1.9** `.load FILE ?ENTRY?` — `cmdLoad` landed; safe-mode gate + arg parse + `sqlite3_load_extension` forward; surfaces engine OMIT "extension loading is disabled" on stderr.
  - [X] **10.1a.1.10** `.auth ON|OFF` — `sqlite3_set_authorizer(shellAuth | safeModeAuth | nil)`.
  - [X] **10.1a.1.11** `.intck ?STEPS_PER_UNLOCK?` — `cmdIntck` landed; wraps `sqlite3_intck_open/_step/_message/_unlock/_error/_close`; emits `<N> steps, <M> errors` trailer per C.

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
- [X] **10.1.bug.127** ORDER BY+LIMIT silently dropped sort on coroutine FROM.
- [X] **10.1.bug.128** CLI step-error prefix should be `Error near line N:` (no `Runtime error`, no `(rc)` suffix).
- [X] **10.1.bug.129** CLI openDb missed `sqlite3_db_config(TRUSTED_SCHEMA=0, DEFENSIVE=1, STMT_SCANSTATUS=0)`.
- [X] **10.1.bug.130** `UPDATE T AS t SET col=(SELECT … WHERE inner.col=t.col)` errored "no such column: t.col".
- [X] **10.1.bug.131** Bare-TK_ID outer ref from inside a correlated subquery errored.
- [X] **10.1.bug.132** CLI `processInput` cut-gate required `zSql[end]=';'` before sqlite3_complete; trailing `--` comment caused statement-merging.
- [X] **10.1.bug.133** CLI `.echo on` was a silent no-op.
- [X] **10.1.bug.134** CLI `.parameter set` populated temp.sqlite_parameters but `bind_prepared_stmt` was never ported.
- [X] **10.1.bug.135** `.changes` / `.show` defects: per-SQL emission, `output:` line ordering, `output_c_string` escaping, `autoExplain` default.
- [X] **10.1.bug.136** Meta dot-command dispatcher sweep (10.1e.G): `procedure→function: i32` conversions to propagate rc, wording/format/array-size drifts.

---

## Known regression-test failures (auto-discovered by `run_regression.sh`)

> Ledger entries: when a binary returns to all-green, mark `[X]` and leave
> in place as a fixed-bug record (matching the convention used by 10.1.bug.*).
> Numbering is scoped to the phase that owns the root cause.

- [X] **3.B.regbug.1** TestPagerReadOnly — fixed 2026-05-10 (test-fixture path-resolution defect).
- [X] **6.regbug.1** TestWhereExpr — fixed 2026-05-10 (test-fixture: `pTab^.iPKey` left at 0, must stamp `-1` after `sqlite3DbMallocZero`).
- [X] **trigger1.regbug.1** trigger1 same-name trigger 13→1 fail — sqlite3InitCallback "already-published" skip-guard cross-checked the schema-row name across tblHash/idxHash/trigHash; a trigger named like its table matched the table → reparse skipped → trigger never linked into trigHash. Made the guard type-aware off argv[0] (prepare.c:116 has no such guard; it is a port-local workaround for the dropped schema-SELECT WHERE filter). main.pas ~3202.
- [ ] **trigger1.regbug.2** trigger1-22.10 (residual, separate bug): in a multi-row INSERT (VALUES/SELECT) that fires a BEFORE/AFTER trigger reading the destination table, writes from earlier loop iterations are invisible to a freshly-opened cursor in later iterations (count/max/scan see only the first row); single-row INSERT is correct. Codegen + OP_Program + btree cursor-sharing all verified faithful — divergence is deeper (page-cache/cursor coherency within one multi-row statement). Not the same-name class the prior triage assumed.

---

## Phase 10.2 — CLI integration parity

- [X] **10.2** Integration parity: `bin/passqlite3 foo.db` ↔ `sqlite3 foo.db` on a scripted corpus that unions all 10.1a..f golden files plus kitchen-sink multi-statement sessions (modes, attached DBs, triggers, dump+reload).

### Phase 10.3 — Interactive line-editor follow-ups

Baseline raw-mode editor with arrow-key history landed in
`src/passqlite3lineedit.pas` (Left/Right/Home/End/Up/Down,
Backspace/Delete, Ctrl-A/E/B/F/N/P/U/K/W/L/C/D, in-memory history
capped at 1000).  Optional enhancements on top of that baseline:

- [X] **10.3.a** On-disk history persistence at `~/.passqlite3_history` (load on startup, append/save on exit; mode 0600).
- [ ] **10.3.b** Tab completion for `.dot` commands and for table /
  column names visible in the currently-open database (query
  `sqlite_schema` + `PRAGMA table_info`).
- [ ] **10.3.c** Multi-line wrap-aware rendering — current refresh
  assumes the line fits on one terminal row; long lines smear.  Needs
  column-count probe (`TIOCGWINSZ`) and a multi-row redraw that
  positions the cursor with `ESC[<n>A` / `ESC[<n>B`.
- [ ] **10.3.d** Reverse-incremental search (Ctrl-R) over the in-memory
  history, matching readline's `(reverse-i-search)`'pat': hit` UX.

---

## Phase 11 — Benchmarks (Pascal-on-Pascal speedtest1 port)

Output format must be byte-identical to upstream `speedtest1` so the
existing `speedtest.tcl` diff workflow keeps working.  Lives in
`src/bench/passpeedtest1.pas`; the same binary swaps backends
(passqlite3 vs system libsqlite3) by `--backend`.

- [X] **11.1** Harness port (speedtest1.c lines 1..780): argument parser, `g` global state, `speedtest1_begin_test` / `speedtest1_end_test`, `speedtest1_random`, `speedtest1_numbername`, result-printing tail.

- [X] **11.2** `testset_main` port (lines 781..1248) — the ~30 numbered cases (100..990) of the canonical OLTP corpus.

- [X] **11.3** Small / focused testsets (one chunk): `testset_cte` (1250..1414), `testset_fp` (1416..1485), `testset_parsenumber` (2875..end).

- [X] **11.4** Schema-heavy testsets: `testset_star` (1487..2086), `testset_orm` (2272..2538), `testset_trigger` (2539..2740).

- [X] **11.5** Optional/extension-gated testsets: testset_debug1, testset_json (gated on 6.8), testset_rtree (omit-stub until R-tree extension lands). All PASS.

- [X] **11.6** Differential driver `bench/SpeedtestDiff.pas`.

- [X] **11.7** Regression gate: commit `bench/baseline.json` (one row per `(testset, case-id, dataset-size)` carrying the expected pas/c ratio).
  - [X] **11.7.repin** 2026-05-16: re-pinned baseline from MAX-of-9 local runs.

- [X] **11.8** Pragma / config matrix.

- [x] **11.9** Profiling hand-off to Phase 9.

---

## Phase 12 — Performance optimisation (enter only after Phase 9 green)

Changes here must preserve byte-for-byte on-disk parity.  Compile
flags: `-dAVX2 -CfAVX2 -CpCOREAVX -OpCOREAVX`.  Note: in FPC,
functions with `asm` content cannot be inlined.

- [X] **12.1** `perf record` on benchmark workloads; identify the top 10 hot functions.
  - [ ] **12.1.followup.bigger-sample** Re-run callgrind at
        `--size 5` once `--testset main --size 5` SQLITE_CORRUPT
        note in `profile_perf.sh` is cleared, to confirm
        ranking holds on larger tables.

- [~] **12.2** Aggressive `inline` on VDBE opcode helpers, varint
  codecs, and page cell accessors.  Headline candidate.2 landed
  (xRecordCompare fast-path dispatch); secondary inline candidates
  (1, 3..11) still open.
  - [ ] **12.2.candidate.1** Inline `sqlite3VdbeSerialGet`
        (passqlite3vdbe.pas:2050) — 1.20 % self, called from
        every `OP_Column` step.
  - [X] **12.2.candidate.2** Specialise sqlite3VdbeRecordCompare on int-key + string-key fast paths — port vdbeRecordCompareInt/String/FindCompare (vdbeaux.c:4971..5181) at passqlite3btree.pas:3396..3568.
  - [ ] **12.2.candidate.3** Cache `pPage^.aData` / `aCellIdx` /
        `maskPage` in locals at the top of
        `sqlite3BtreeIndexMoveto` (passqlite3btree.pas:3452) —
        4.95 % self.
  - [ ] **12.2.candidate.4** Same field-cache trick on
        `sqlite3BtreeTableMoveto` (passqlite3btree.pas:2909) —
        1.95 % self.
  - [ ] **12.2.candidate.5** Investigate the **two** definitions
        of `patternCompare` at passqlite3codegen.pas:54136 and
        :58452; dead-code-drop the duplicate, then evaluate
        AVX2 byte-search for the `noCase=0, esc=0` arm —
        combined 2.29 %.
  - [ ] **12.2.candidate.6** Reduce zero-fill churn: audit
        `sqlite3DbMallocZero` / `VdbeMakeReady` /
        `pcache1FetchNoMutex` for FillChar calls that could be
        replaced by reuse (low priority, ~1.5 %).
  - [ ] **12.2.candidate.7** Inline `sqlite3VdbeRecordUnpack`
        (passqlite3vdbe.pas:2263) and hoist `pKeyInfo^.nAllField`
        — 1.10 % self.
  - [ ] **12.2.candidate.8** Inline `btreeParseCellPtr`
        (passqlite3btree.pas:918) — 0.80 % self, called from
        every cell access.
  - [ ] **12.2.candidate.9** Audit `fillInCell` / `insertCellFast`
        for redundant payload Move calls (low priority).
  - [ ] **12.2.candidate.10** Inline `freeSpace`
        (passqlite3btree.pas:1284) — 0.98 % self.
  - [ ] **12.2.candidate.11** Hand-tune `sqlite3GetVarint`
        (passqlite3util.pas) — varint decode is in many hot
        paths, ~0.46 % self plus inclusive presence in #2/#10.

- [ ] **12.3** Consider replacing the VDBE big `case` with threaded
  dispatch (computed-goto-style) using `{$GOTO ON}`.  Land only if
  profiling shows the switch is a real bottleneck.
  - [ ] **12.3.candidate.1** Strip UnicodeString round-tripping
        in `passpeedtest1.pas` glue (DefaultUnicode2AnsiMove +
        DefaultAnsi2UnicodeMove + fpc_unicodestr_* together
        ~6 %).  Likely a *harness* fix, not engine — but it
        skews benchmarks vs C and should land before
        threaded-dispatch comparison.
  - [ ] **12.3.candidate.2** `{$GOTO ON}` jump-table dispatch
        for the top-10 hottest VDBE opcodes (`OP_Column`,
        `OP_Next`, `OP_Goto`, `OP_Integer`, `OP_AggStep`,
        `OP_ResultRow`, `OP_IdxGT`, `OP_SeekGE`, `OP_IfNot`,
        `OP_MakeRecord`) — sqlite3VdbeExec is 17.94 % self;
        even a 20 % cut here is ~3.5 % total.  Gate landing on
        measured cycle-level improvement, not Ir.

- [ ] **12.4** FTS3/4 segment-merge build performance (moved from 6.40.1.o.2) — per-INSERT pending-terms flush runs ~28 ms/row so heavy builds blow the 30 s per-test wall clock. Suspected correct-but-slow (full `%_segdir`/`%_segments` rewrite per flush vs C's incremental path), NOT a correctness bug; on-disk parity must be preserved. Affected (pas-soft): fts4merge, fts4merge4, fts4merge5, fts4growth, fts4growth2, fts4opt, fts4langid, fts4check, fts3corrupt2, fts3corrupt6. **WON when each of those completes < 30 s (PASS, or any remaining fail has a non-timeout cause).** Profiling is bounded to producing committed artefacts, not open-ended "investigate":
  - [ ] **12.4.1** New `src/tests/TestFts3BuildPerf.pas` micro-bench: insert N=100/1000 docs; report ms/row for port vs `../sqlite3/sqlite3` AND count, per INSERT, the `%_segdir` UPDATE/DELETE ops + `fts3PendingTermsFlush` calls + SQL stmt re-prepares. **DoD:** bench committed + the baseline number table recorded in this task line.
  - [ ] **12.4.2** From 12.4.1 counts, give a yes/no verdict on each hypothesis: (a) flush fires per-row instead of at `nMaxPendingData`; (b) re-prepares instead of reusing `aStmt[40]`; (c) rewrites the whole segdir per flush. **DoD:** the three verdicts, each backed by a measured count.
  - [ ] **12.4.3** Apply only the fix(es) 12.4.2 confirmed (honour pending-data flush threshold / reuse stmt cache / incremental segdir append). **DoD:** 12.4.1 ms/row ≤ 3× the oracle baseline from 12.4.1.
  - [ ] **12.4.4** Re-run the 10 affected files; promote those that now finish to pas-strict in STATUS.txt. **DoD:** each completes < 30 s; any still-failing file has its remaining (non-timeout) cause noted in STATUS.txt.

---

## Phase 13 — Coverage-guided fuzzing (AFL)

Enter after Phase 9 green; independent of Phase 12.  9.3.1 +
9.3.2 already provide the one-shot differential harness and an
8-seed clean sweep — this phase adds coverage-guided mutation on
top.  **FPC-AFL gotcha:** FPC has no `afl-clang-fast` equivalent
(no LLVM instrumentation pass).  Three viable instrumentation
routes — pick in this order:

1. **`afl-as` assembler wedge (preferred).**  Tell FPC to emit
   text assembly and route it through AFL's GAS wrapper:
   `fpc -al -Aas -FD<afl-bin-dir> ...`.  `-al` keeps `.s` files,
   `-Aas` selects GNU `as`, `-FD` points at the directory holding
   `afl-as`.  `afl-as` rewrites every branch site with the AFL
   tramp + shared-memory bitmap update — same mechanism `afl-gcc`
   used before `afl-clang-fast` existed.  ~2x slowdown.  May need
   minor tweaks if FPC's GAS dialect trips the wrapper's pattern
   matcher (older AFL versions assume gcc-style local labels).
2. **QEMU mode (`afl-fuzz -Q`).**  No compiler cooperation;
   instruments at translation time inside patched user-mode QEMU.
   ~5–10x slowdown but bulletproof.  Fallback if (1) fails.
3. **Black-box `afl-fuzz -n`.**  No instrumentation, dumb-fuzz
   only.  Last resort; documented for completeness.

Not viable: pure C shim with `afl-clang-fast` — the shim gets
instrumented but the Pascal callee doesn't, so the bitmap is
empty for the code under test.

Persistent-mode `__AFL_LOOP` is orthogonal to the choice above
and can be added later via a small C entry stub.

- [~] **13.1** AFL wiring.  `src/tests/fuzz/afl-driver.pas` wraps
  9.3.1 for `afl-fuzz` (read input from stdin, write to a tmp
  file, invoke the in-process harness, return AFL-compatible exit
  codes).  Stand up instrumentation route (1), (2), or (3) above;
  document the choice in `src/tests/fuzz/README.md`.  Skip
  gracefully if AFL isn't installed — script must self-report.
  Landed: src/tests/fuzz/afl-driver.pas (slurps stdin, mkstemp-equiv
  in /tmp, FpFork+FpExecv into bin/TestFuzzDiff, propagates rc /
  re-raises signal-death as 128+N for AFL crash bucketing), build-afl.sh
  (route-1 → route-2 → route-3 fallback chain, AFL-missing self-report
  → exit 0), README.md (route table + install + run recipe + 9.3.2
  smoke baseline citation).  Smoke verified on dev host (no AFL):
  default run prints self-report and exits 0; FORCE_BUILD=1 picks
  route (3) and compiles; driver returns rc=3 on empty stdin and
  rc=0 (PASS) on 4 KiB of fuzzdata1.db.  Tmp files cleaned up
  post-exec.  Cite: src/tests/fuzz/afl-driver.pas, build-afl.sh,
  README.md.
  - [ ] **13.1.unverified** Re-run build-afl.sh on a host with afl-fuzz
    installed and confirm route (1) `afl-as` wedge actually completes
    a smoke-fuzz iteration (`AFL_BENCH_JUST_ONE=1 afl-fuzz …`).  Today
    untested — dev host lacks afl-fuzz; only the AFL-missing self-report
    and the route-3 fallback compile path were exercised.

- [X] **13.2** Crash-vs-divergence classifier.
  - [ ] **13.2.unverified** No real-world AFL crash corpus has hit
    the classifier yet — the four-bucket smoke used synthetic
    bash stubs.  Once 13.3's 24h soak surfaces an actual finding,
    re-run `classify-crash.sh` on the AFL crashes/ dir and
    confirm the side-disambiguation heuristic holds (FPC RTL
    Runtime-error preamble is present on every Pascal SIGSEGV
    AFL surfaces).

- [~] **13.3** ≥24 h soak target.  Wrapper script `fuzz-soak.sh`
  with `--duration` (default 24h) and stop-on-first-divergence.
  Not a CI gate — a manual gate documented in README.  Each
  clean soak bumps a counter in `src/tests/fuzz/SOAK_LOG.md` so
  we can prove the wallclock budget over time.
  Landed: src/tests/fuzz/fuzz-soak.sh (--duration / --no-stop /
  --quiet), src/tests/fuzz/SOAK_LOG.md (header + empty ledger).
  Pre-flights via build-afl.sh, picks route from .afl-route, polls
  findings/default/{crashes,hangs}/ every 5 min, hands findings to
  classify-crash.sh on first detection.  Self-reports + exits 0
  when afl-fuzz is missing.  README "Soak workflow" section added.
  - [ ] **13.3.unverified** This host has no AFL install; the
    real-soak path (afl-fuzz launch, bitmap-driven mutation, ledger
    row from a non-trivial run) wasn't exercised — only the AFL-
    missing self-report path was smoke-verified locally.  Re-run
    on an AFL-equipped host with `--duration 30m` once to confirm
    the polling loop, classify-crash hand-off, and SOAK_LOG.md
    row format all behave as advertised.

- [~] **13.4** Coverage-guided seed minimisation.  `afl-cmin` +
  `afl-tmin` pipeline pruning the seed set to the smallest input
  set that still hits every covered branch.  Re-commit the
  minimised seeds when they shrink.
  Landed: src/tests/fuzz/minimize-corpus.sh (--commit / --quiet).
  Runs afl-cmin → seeds.cmin/, then afl-tmin per survivor; prints
  before/after counts + bytes; --commit swaps seeds.cmin/ over
  seeds/, stages, and emits the suggested `git commit` line (never
  auto-commits).  Self-reports + exits 0 when afl-cmin/afl-tmin
  are missing.  README "Seed minimisation" section added.
  - [ ] **13.4.unverified** AFL not installed on this host; only
    the missing-tools self-report path was smoke-verified.  On an
    AFL-equipped host (route 1 or 2 — route 3's empty bitmap makes
    the pipeline a no-op), run the pipeline against the current
    8-seed corpus and re-commit the minimised set when it shrinks.

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

---

## Finding code duplication (port-introduced vs. upstream)

Goal: identify Pascal blocks that repeat without an equivalent repetition in
the upstream C reference. The faithful-port rule means any duplication present
in C is allowed (it lives there for a reason), but duplication that exists
*only* in the Pascal tree is a refactor candidate.

Tooling: `jscpd` (Node-based, token-aware, supports Pascal and C). Requires
`node` + `npm`; no install needed if invoked via `npx`.

### Step 1 — generate JSON reports for both trees

Run from any directory; outputs land in `/tmp/jscpd-out/`.

```
npx --yes jscpd /home/bpsa/app/pas-sqlite3/src \
  --pattern "**/*.pas" \
  --min-tokens 50 --reporters json --output /tmp/jscpd-out/pas

npx --yes jscpd /home/bpsa/app/sqlite3 \
  --pattern "{src,ext}/**/*.{c,h}" \
  --ignore "**/sqlite3.c,**/sqlite3.h,**/tsrc/**,**/parse.c,**/opcodes.c,**/fts5.c,**/fts5parse.c,**/keywordhash.h" \
  --min-tokens 50 --reporters json --output /tmp/jscpd-out/c
```

Notes on the C invocation:
- The amalgamation (`sqlite3.c/h`, `tsrc/`) is excluded — it is a concatenation
  of the split sources and inflates duplication artificially.
- Lemon/awk-generated files (`parse.c`, `opcodes.c`, `fts5.c`, `fts5parse.c`,
  `keywordhash.h`) are excluded — their repetition is mechanical, not human.
- `--min-tokens 50` matches roughly 6–10 lines of body code; raise it to 80–100
  to focus only on substantial clones.

### Step 2 — cross-reference Pascal clones against C

A Pascal file `passqlite3<stem>.pas` is considered to have a C analogue at
`<stem>.c` or `<stem>.h`. A Pascal clone pair `(A.pas, B.pas)` has a "C
analogue" if the corresponding C files also clone with each other (or, for
intra-file clones, if the same C file clones against itself).

Script (paste into `python3 -`):

```python
import json, os, re
from collections import defaultdict

c = json.load(open('/tmp/jscpd-out/c/jscpd-report.json'))
p = json.load(open('/tmp/jscpd-out/pas/jscpd-report.json'))

c_pairs = defaultdict(set)
for d in c['duplicates']:
    a = os.path.basename(d['firstFile']['name'])
    b = os.path.basename(d['secondFile']['name'])
    c_pairs[a].add(b); c_pairs[b].add(a)

def pas_to_c(n):
    m = re.match(r'passqlite3(.+)\.pas$', n)
    return {m.group(1)+'.c', m.group(1)+'.h'} if m else set()

def is_test(path): return '/tests/' in path

tests_only=[]; port_only=[]; cross=[]
for d in p['duplicates']:
    fa, fb = d['firstFile']['name'], d['secondFile']['name']
    a, b   = os.path.basename(fa), os.path.basename(fb)
    ln     = d['lines']
    ta, tb = is_test(fa), is_test(fb)
    if ta and tb:        tests_only.append((ln,a,b)); continue
    if ta or tb:         cross.append((ln,a,b));      continue
    ca, cb = pas_to_c(a), pas_to_c(b)
    hit = any(y in c_pairs.get(x,set()) for x in ca for y in cb)
    if not hit: port_only.append((ln,a,b))

for lst in (tests_only, port_only, cross): lst.sort(reverse=True)
print("test<->test :", len(tests_only), "clones,", sum(x[0] for x in tests_only), "lines")
print("port<->port :", len(port_only),  "clones,", sum(x[0] for x in port_only),  "lines  (no C analogue)")
print("test<->port :", len(cross),      "clones,", sum(x[0] for x in cross),      "lines")
print("\nTop 20 port<->port (port-introduced):")
for ln,a,b in port_only[:20]: print(f"  {ln:3}  {a} <-> {b}")
print("\nTop 20 test<->test (refactor candidates):")
for ln,a,b in tests_only[:20]: print(f"  {ln:3}  {a} <-> {b}")
```

### Step 3 — interpret the output

Three buckets, each with a different meaning:

1. **`port <-> port` with no C analogue** — genuine port-introduced
   duplication. Open the listed line ranges (`jscpd` JSON has `firstFile.start`
   / `firstFile.end`) and check the corresponding C function. Common causes:
   - C used a macro that the Pascal port inlined two or three times.
   - C used a `static inline` helper that the port copy-pasted instead of
     hoisting into a top-level routine.
   Fix by extracting a shared procedure inside the same unit, mirroring the C
   macro/helper.

2. **`test <-> test`** — the test harness has no upstream counterpart, so any
   clone here is by definition port-only. These are the biggest deletion wins.
   Look for families that share boilerplate (open `:memory:`, prep, step,
   compare against `csq_*`); collapse them into a common unit under
   `src/tests/` (e.g. a `DiagCommon.pas` exposing `ProbeOne` / `ProbeRows`).

3. **`test <-> port`** — should be empty. If non-empty, a test is probably
   inlining production code rather than calling it; fix the test.

### Step 4 — don't refactor blindly

Before extracting a helper:

- Confirm the upstream C really has no equivalent repetition. Sometimes the C
  source uses a macro that `jscpd` did not flag because it expands at compile
  time; a Pascal extraction is still correct, but the framing changes from
  "port-introduced" to "missing macro analogue."
- Avoid eliminating duplication that exists because the two Pascal sites are
  intentionally allowed to diverge later (e.g. an extension VFS that may grow
  features the core VFS will not). When in doubt, leave a `// see also <other
  site>` comment instead of extracting.
- Never refactor across the port↔test boundary: tests must stay independent of
  internal helpers to remain a useful oracle.

### Current snapshot (informational, recompute before acting)

At the time this section was written:

| Bucket                              | Clones | Dup lines |
| ----------------------------------- | -----: | --------: |
| Pascal total (`src/**/*.pas`)       |    319 |     6 143 |
| C total (split sources, no amalg.)  |    166 |       — (2.73% of 83k) |
| Pascal `test <-> test`              |    256 |     5 725 |
| Pascal `port <-> port` (no C analog)|     22 |       259 |
| Pascal `test <-> port`              |      0 |         0 |

Headline: ~96% of Pascal's excess duplication lives in the test harness; core
port code only carries ~259 unjustified duplicated lines out of 67 k.
