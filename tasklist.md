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

---

## Working on this codebase (orientation for new contributors)

Correctness is defined **differentially against the C oracle**, not by hand-written
assertions.  Two gates matter:

* `bin/TestExplainParity` — the **bytecode** gate.  **1026/1026** SQL
  statements emit byte-identical VDBE vs C as of 2026-05-06 (a3); the
  multi-row VALUES coroutine row closed under 6.8.6 / 6.10 step 6.
* `src/tests/Diag*.pas` (`DiagOps`, `DiagCast`, `DiagFunctions`, `DiagWindow`,
  `DiagTxn`, `DiagFeatureProbe`, …) — the **runtime** gates.  Each probe pins a
  narrow runtime divergence to a numbered "Open Bugs" bullet.  When a Diag
  starts passing, tick the bullet.

Build with `src/tests/build.sh`; run binaries with
`LD_LIBRARY_PATH=src/ bin/<TestName>`.  **Always wrap `DiagTxn` in `timeout 10`** —
it has a known hang at savepoint rollback (pre-existing, separate task).

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

> **2026-05-06 (a3):** TestExplainParity reports **1026 / 1026 PASS**
> after Phase 6.8.6 close-out (steps 3+4+5).  Multi-row VALUES coroutine
> row now byte-identical to C; the no-FROM fast path pre-bumps nMem by
> 3 on SF_MultiValue + SRT_Coroutine to mirror C's selectInnerLoop
> temp-reg accounting, and the Goto-after-ReleaseReg-before-Yield emits
> p5=1 as in insert.c:1619..1626.

- [X] **6.8.0** Pragma (pragma.c): `sqlite3PragmaVtabRegister`

- [X] **6.8.2** port `sqlite3GenerateConstraintChecks`

- [X] **6.8.3** port `sqlite3CompleteInsertion` (insert.c)

- [X] **6.8.4** `sqlite3WhereBegin` (where.c) — full WhereInfo /
     codeOneLoopStart, multi-table loop nesting, INDEXED BY / NOT
     INDEXED, bloom-filter + covering-index arms.  Gate:
     TestExplainParity + DiagIndexing + DiagCovering + DiagBloom.

- [X] **6.8.6** productive `sqlite3Insert` body (insert.c).  Single-row
     VALUES, IPK-alias rebinding, AUTOINCREMENT, BEFORE/AFTER triggers,
     RETURNING, vtab xUpdate dispatch, xferOptimization all DONE.
     Multi-row VALUES — runtime + bytecode parity DONE via
     sqlite3MultiValues coroutine arm.  INSERT FROM SELECT bails —
     folds into 6.10 step 6 sub-FROM.
          Close-out plan (land steps 1+2 together — step 1 alone would
          break DiagMultiValues runtime since the parser would emit a
          viaCoroutine Select that sqlite3Insert can't yet consume):
          [X] 1. `sqlite3MultiValues` coroutine arm landed
               (codegen.pas:29446).  Conditions (a)..(d) + IN_SPECIAL_PARSE
               gate the UNION-ALL fallback; otherwise: 2nd-row call
               allocates wrapper Select + viaCoroutine SrcItem, attaches
               pLeft as subquery, allocates regReturn/addrFillSub, emits
               OP_InitCoroutine, recurses `sqlite3Select(pLeft,
               SRT_Coroutine)` to emit row-1 Integer ops + Yield, sets
               regResult = dest.iSdst.  3rd+ rows bump u1.nRow.  Tail
               emits ExprCodeExprList(pRow, regResult) + OP_Yield.
               Also gated OP_Explain in the no-FROM fast path
               (codegen.pas:22799) on SF_MultiValue to suppress
               the inside-coroutine Explain (mirrors C).
          [X] 2. `sqlite3Insert` viaCoroutine consumer arm landed.
               Detection at codegen.pas:29670 sets useCoroutine when
               pSelect carries a single viaCoroutine SrcItem; reg-reuse
               override at codegen.pas:30030 sets regData = regFromSelect,
               regRowid = regData-1, regIns = regRowid (or -1 for vtab)
               when bIdListInOrder + full-cols.  OP_Explain SCAN emitted
               before OpenTableAndIndices, then ReleaseRegisters + Yield
               loop-top + Copy regFromSelect+ipkColumn → regRowid (when
               IPK in result block) frame the bytecode loop; tail emits
               Goto(addrCont) + JumpHere(addrInsTop).  Column-eval inner
               loop is skipped (or emits SCopy for IDLIST out-of-order).
               Existing rowid arm skips its SCopy when regRowid was
               pre-loaded.  Verification: DiagMultiValues runtime green;
               DiagDml 14/14; TestExplainParity 1025/1026 (residual
               diff is register-numbering — MakeRecord p3=11 vs 14 —
               from C's selectInnerLoop temp-reg pattern not yet
               mirrored in the no-FROM fast path; runtime-equivalent).
          [X] 3. The SF_Values UNION-ALL fallback chain is no longer
               reached (steps 1+2 catch it via useCoroutine), so the
               isMulti detection is narrowed to handle only the
               `INSERT INTO t SELECT a UNION ALL SELECT b` shape with
               empty FROM and constant pELists — kept for DiagDml's
               `insert select const` row, which has no SF_Values flag
               and is not produced through sqlite3MultiValues.  Banner
               at codegen.pas:29899 documents the narrowed scope.
          [X] 4. DiagMultiValues runtime green; TestExplainParity
               1026/1026; DiagDml 14/14; DiagIndexing / DiagWindow /
               DiagOps / DiagCovering / DiagFunctions all clean.
          [X] 5. nMem-parity gap closed in the no-FROM fast path
               (codegen.pas:22778) by pre-bumping pParse^.nMem by 3
               on SF_MultiValue + SRT_Coroutine, matching C's
               selectInnerLoop temp-reg accounting (sqlite3GetTempReg
               bumps nMem; ReleaseTempReg returns to the free pool
               but does NOT decrement nMem).  Plus the Goto-tail in
               sqlite3Insert now emits p5=1 when the op before
               addrCont is OP_ReleaseReg (mirrors insert.c:1619..1626).

- [X] **6.8.5** `sqlite3WhereEnd` — DONE.

- [X] **6.8.1** `sqlite3Update` (update.c) — single-table arm, UPDATE
     FROM, virtual-table dispatch (updateVirtualTable), RETURNING all
     DONE.  PREUPDATE_HOOK arm N/A (gated on SQLITE_ENABLE_PREUPDATE_HOOK).

- [X] **6.9** sqlite3VdbeRecordCompare / sqlite3VdbeFindCompare full
     bodies in btree.pas; vdbe.pas wrappers delegate.  Collation-aware
     string compare wired (UTF-8 fast path; transcoding arm N/A in
     default UTF-8 build).  TUnpackedRecord layout reconciled with C.

  [X] **6.24** Aggregate-with-ORDER-BY codegen
       (analyzeAggregate + generateAggSelect ORDER-BY-inside-aggregate
       arm).  Gate: DiagWindow `group_concat order` PASSes.

  [X] **6.26** Window functions (window.c).  DiagWindow: ALL PASS
       (multi-window arm closed by lifting the window-arm SRT_Output gate
       to admit SRT_EphemTab — recursive sqlite3Select from the outer
       eph-materialise now runs the window arm again on the inner sub-
       SELECT carrying orphan windows, mirroring the C nested-coroutine
       layering one layer per distinct OVER spec).  Gate: DiagWindow.
       [X] sqlite3WindowRewrite / WindowCodeInit / WindowCodeStep
            ported with all helpers (windowArgCount, windowAggStep,
            windowAggFinal, windowFullScan, windowCodeRangeTest,
            windowCodeOp, etc.).
       [X] Wired into sqlite3Select via linkWindowsForSelect +
            EP_WinFunc fast-path in sqlite3ExprCodeTarget + window
            arm replacing the old bail (commit 91dc50d).
       [X] Frame-spec ROWS / RANGE / GROUPS + EXCLUDE clauses.
            xInverse wired for count/sum/total/avg.
       [X] Built-in window dispatch (row_number, rank, dense_rank,
            ntile, lag, lead, first_value, last_value, nth_value,
            percent_rank, cume_dist).
       [X] Aggregate-as-window (sum/avg/min/max OVER) via xValue
            wiring + bSort SRT_EphemTab inner-sub ORDER BY.
       [X] Subset-gate lifts: outer ORDER BY (incl. ORDER-BY-by-alias
            via resolveAsName), outer DISTINCT, LIMIT / OFFSET.
       [X] **Multi-window arm** (several distinct OVER clauses with
            incompatible partition/order).  Closed by admitting
            SRT_EphemTab in the window-arm gate at codegen.pas:23212 +
            mirrored MakeRecord/NewRowid/Insert disposal in the inner
            Gosub subroutine and bSort tail.  Orphan windows (those
            not chained into pSel^.pWin via sqlite3WindowLink) ride out
            on the rewritten sub-SELECT's pEList as TK_FUNCTION+EP_WinFunc
            nodes; when the outer materialise calls sqlite3Select on
            that sub-SELECT, linkWindowsForSelect picks them up and the
            window arm runs again — one rewrite layer per distinct OVER
            spec, mirroring C's nested-coroutine emission.

  [X] **6.27** codegen.pas schema-mutation + statistics.
       Sub-rows that overlapped Phase 7 have been moved out
       (ATTACH/DETACH → 7.1.8; the ALTER trio → 7.1.9).  ANALYZE
       end-to-end on a fresh DB is now the only carve-out; the gap is
       Phase 7.1.1 schema reload after sqlite_stat1 CREATE — tracked
       under 7.1.1, not 6.27.
       [X] Port `sqlite3Analyze` (analyze.c).  Entry-stack +
            `analyzeOneTable` + StatAccum SQL function triplet
            (stat_init/stat_push/stat_get, analyze.c:401..923,
            non-STAT4 build) all ported and registered.  Gate
            `DiagAnalyze` 3/3 PASS with pre-created sqlite_stat1.
            `decodeIntArray` + `analysisLoader` wired through
            `gStat1Exec`.  End-to-end ANALYZE on a fresh DB
            blocked only by 7.1.1 schema reload after sqlite_stat1
            CREATE — see 7.1.1.
       [X] Port `sqlite3Vacuum` (vacuum.c).
       [X] Port `sqlite3RunVacuum` (vacuum.c:143) + execSql/execSqlF —
            body landed in passqlite3main.pas, wired into OP_Vacuum via
            new vdbeRunVacuum hook.  Faithful 1:1 with the
            !SQLITE_OMIT_VACUUM && !SQLITE_OMIT_ATTACH arm; PREUPDATE_HOOK
            and AUTHORIZATION arms left out (default build).  Both
            `VACUUM INTO 'file.db'` and plain in-place `VACUUM` work
            end-to-end (data preserved across rebuild).  The
            "SQL statements in progress" false-positive on plain
            VACUUM was a missing nVdbeActive decrement in
            sqlite3VdbeReset when the stmt was paused at SQLITE_ROW —
            fixed alongside this row.
       [X] `sqlite3FkCheck` (fkey.c) + `sqlite3FkActions` /
            `fkActionTrigger` (fkey.c:1217..1442) ported.  Pairs with
            runtime OP_FkCheck (commit 775ffc0).

  [ ] **6.28** sweep — re-search for "stub" in the pascal source code and
       port from C to pascal in full any function or procedure still
       marked as "stub" that was missed (catch-all).
       [X] OP_Vacuum — wired to vdbeRunVacuum hook (sqlite3RunVacuum
            ported in passqlite3main.pas).  Both `VACUUM` and
            `VACUUM INTO 'file.db'` work end-to-end (closed under 6.27).
       [X] `sqlite3BtreeIncrVacuum` + `finalDbSize` + `sqlite3PagerMovepage`
            ported.  OP_IncrVacuum returns SQLITE_DONE on first step in
            default build (autoVacuum=0).  incrVacuumStep / relocatePage /
            modifyPagePointer not ported (gated on productive ptrmap).

### Open Bugs

- [ ] **6.11** `PRAGMA page_count` returns no rows on the Pascal port
    (verified 2026-05-06 against an on-disk db with 2 pages: upstream
    sqlite3 returns `2`, pas-sqlite3 prints nothing and step returns
    DONE on first call).  `PRAGMA page_size` works as expected.
    Surfaces under `.dbtotxt`, which works around it by counting
    `sqlite_dbpage` rows; revisit this when porting the rest of the
    PRAGMA dispatch table.

- [X] **6.10** `TestExplainParity.pas` — **1026/1026 PASS** as of
    2026-05-06 (a3).  Oracle is built with `-DSQLITE_DEBUG
    -DSQLITE_ENABLE_EXPLAIN_COMMENTS`, so emits OP_Explain /
    OP_ReleaseReg (vdbeaux.c gates them under `#if !defined(SQLITE_DEBUG)`);
    Pas matches.  Bytecode gate fully closed; all runtime sub-steps
    (6, 7, 8, 9, 15, 17) closed 2026-05-06.  Verification: DiagFeatureProbe
    0 divergences; DiagMisc / DiagTxn / DiagWindow / DiagDml / DiagPragma
    / DiagIndexing / DiagOps / DiagMultiValues / DiagDropTable all green.
    - [X] **6.10 step 6** Remaining bytecode-Δ row:
        [X] `INSERT multi-row VALUES` — bytecode parity reached
          (22 ops, byte-identical to C) via the sqlite3MultiValues
          coroutine arm (codegen.pas:29446) + sqlite3Insert
          viaCoroutine consumer (codegen.pas:29670, :30030) +
          no-FROM fast-path nMem pre-bump and Goto-after-ReleaseReg
          p5=1 emission landed under 6.8.6 steps 1..5.  TestExplainParity
          1026/1026; DiagMultiValues + DiagDml green.
  
  [X] **6.10 step 7** `DiagMisc` runtime divergences

  [X] **6.10 step 8** Closed 2026-05-06.  Residual planner gap was the
      synthetic full-table-scan stand-in in `whereShortCut` (codegen.pas
      ~15958): it set `pLoop^.wsFlags := 0` instead of `WHERE_IPK`,
      diverging from where.c:4150 where the IPK heap-walk arm assigns
      `pNew->wsFlags = WHERE_IPK`.  With wsFlags=0, sqlite3WhereAddExplainText
      entered the non-IPK/non-vtab branch and dereferenced a nil pIndex
      (the IPK pseudo-index probe is not synthesized in pas-sqlite3).
      Fix: stamp `WHERE_IPK` on the fallback (mirrors C); the runtime case
      dispatch in sqlite3WhereCodeOneLoopStart still routes pure-WHERE_IPK
      (no COLUMN_EQ/IN/RANGE/CONSTRAINT) past Cases 2/3 into Case 6 (full
      scan), so the emitted bytecode is unchanged.  Soft nil-guard removed;
      assert restored to match wherecode.c:117.  TestExplainParity holds
      at 1026/1026; TestWherePlanner 679/679; DiagFeatureProbe / DiagAutoIdx
      / DiagWindow / DiagTxn / DiagDml / DiagOps / DiagMisc / DiagPragma
      / DiagIndexing / DiagSubsel / DiagAggWhere / DiagInnerJoin /
      DiagMultiValues green.

  [X] **6.10 step 9** Runtime divergences surfaced by
      `src/tests/DiagFeatureProbe.pas` (run with `LD_LIBRARY_PATH=$PWD/src
      bin/DiagFeatureProbe`).  All sub-arms (c view, e UNION/LIMIT,
      f recursive CTE, g ALTER TABLE) closed 2026-05-06; probe reports
      0 divergences across all 26 rows.

      **Residual-work map across all open 6.10 sub-steps (2026-05-06, a3):**

      | Sub-step | Diagnosis | Specific gap |
      |----------|-----------|--------------|
      | step 8 (autoindex pIndex) | **CLOSED 2026-05-06** | Real culprit was the synthetic full-scan stand-in in whereShortCut (codegen.pas ~15958) setting `wsFlags := 0` instead of `WHERE_IPK`.  Mirrored where.c:4150; restored the assert in sqlite3WhereAddExplainText. |
      | step 9(e) (UNION ALL + LIMIT) | **CLOSED 2026-05-06** | Compound dispatch arm extended to port select.c:3007..3043 (LIMIT/OFFSET propagation onto pPrior via Expr-dup, OP_IfNot reuse, OP_OffsetLimit, JumpHere).  No-FROM fast path lifted its `pLimit=nil` gate — calls `computeLimitRegisters`, `codeOffset`, `OP_DecrJumpZero` around the single-row body. |
      | step 9(f) (recursive CTE) | **CLOSED 2026-05-06** | Two-line fix in `sqlite3Select` source-loop (codegen.pas:24279) and `sqlite3WhereCodeOneLoopStart` full-scan tail (codegen.pas:17312): allow TF_Ephemeral source items whose fgBits has the isRecursive bit ($80) set, and emit `pLevel^.op := OP_Noop` (no Rewind/Next) for the recursive pseudo-cursor.  Mirrors wherecode.c:2568..2571.  `count(*) FROM r` over `WITH RECURSIVE r(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM r WHERE n<5)` now returns 5 (DiagFeatureProbe `CTE recursive` PASS). |
      | step 15(b) (`:memory:` rollback) | All ported, **logic bug** | `pager_open_journal`, `pager_playback`, `pager_playback_one_page`, `sqlite3MemJournalOpen` all present (passqlite3pager.pas:4132, 3667, 3505; memjournal ~:833).  Bug is in lazy-open-across-autocommit-boundary or memjournal record survival. |
      | step 15(c) (`:memory:` savepoint) | All ported, **logic bug** | `sqlite3PagerSavepoint` (passqlite3pager.pas:4641), `pagerPlaybackSavepoint` (:3593), `sqlite3BtreeSavepoint` (passqlite3btree.pas:6514) all complete.  Likely `pager_playback_one_page` savepoint-specific page-recovery branch is incomplete. |

      **Tractable wins (ascending difficulty):**
      1. ~~**step 9(e)**~~ — closed 2026-05-06.
      2. ~~**step 9(f)**~~ — closed 2026-05-06.
      3. ~~**step 15(b/c)**~~ — closed 2026-05-06.
      4. ~~**step 8**~~ — closed 2026-05-06.

      [X] **c) View materialisation in SELECT.**  agg-on-subquery arm
        materialises subquery into eph cursor and drives
        Rewind/updateAccumulator/Next.
      [X] **e) UNION / compound SELECT.**  ORDER-BY and no-ORDER-BY
        UNION / INTERSECT / EXCEPT dispatch through multiSelectByMerge.
        LIMIT/OFFSET propagation through UNION ALL closed (2026-05-06):
        compound dispatch arm at codegen.pas:22717 now ports
        select.c:3007..3043 (Expr-dup pLimit onto pPrior, recurse left,
        delete dup, OP_IfNot guard reusing pPrior^.iLimit, OP_OffsetLimit
        when iOffset, recurse right, JumpHere); plus the no-FROM fast
        path at codegen.pas:22818 lifted its `pLimit=nil` gate, calls
        `computeLimitRegisters` with a tail label, applies `codeOffset`
        before the row emission, and emits `OP_DecrJumpZero` after.
        DiagFeatureProbe rows `SELECT 1 LIMIT 1 (sub-FROM)`,
        `UNION ALL + LIMIT`, `UNION ALL + LIMIT + OFFSET` all PASS.
      [X] **f) Recursive CTE not productive.**  Closed 2026-05-06.
        Anchor row emitted but recursive step `sqlite3Select(p, &destQueue)`
        emitted no ops because the source-loop check at the top of
        `sqlite3Select` (codegen.pas:24279) bailed on TF_Ephemeral for
        every source.  Two-line fix:
          - codegen.pas:24279 — allow TF_Ephemeral when the source item's
            fgBits has the isRecursive bit ($80) set.  C dispatches the
            recursive pseudo-cursor through the standard scan path; the
            ephemeral guard was Pas-only.
          - codegen.pas:17312 — full-scan tail in
            `sqlite3WhereCodeOneLoopStart` was emitting OP_Rewind / OP_Next
            unconditionally; gate that on `not isRecursive` and set
            `pLevel^.op := OP_Noop` for recursive sources (mirrors
            wherecode.c:2568..2571).
        DiagFeatureProbe `CTE recursive` PASS (val=5).
        TestExplainParity holds at 1026/1026.  No regressions across
        DiagWindow / DiagTxn / DiagPragma / DiagDml / DiagIndexing /
        DiagSubsel / DiagAggWhere / DiagInnerJoin / DiagMisc / DiagOps
        / DiagMultiValues.
      [X] **g) ALTER TABLE no-op.**  Closed 2026-05-06.  Three gaps,
        all traced to faithful 1:1 omissions in the ported alter.c /
        prepare.c / vdbe.c arms:

        1. **`sqlite3AddColumn` skipped the IN_RENAME_OBJECT token-map.**
           build.c:1546 calls `sqlite3RenameTokenMap(pParse, (void*)z,
           &sName)` so `renameColumnFunc` (alter.c:1530) can later
           locate the column-name token via `renameTokenFind`.  The
           Pascal port (codegen.pas sqlite3AddColumn) had dropped that
           call, so `sCtx.pList` was empty and `renameEditSql` produced
           the input verbatim — `sqlite_rename_column(...)` returned
           the *original* `CREATE TABLE` text, the
           `sqlite3NestedParse(UPDATE %Q.sqlite_schema SET sql=...)`
           wrote the same text back, and the row looked unchanged.
           Restored the C call site verbatim
           (codegen.pas:33082..33084).

        2. **Eponymous-vtab WHERE was a `pWhere=nil` gate.**  Both the
           agg arm (`isVtabAgg` at codegen.pas:~23715) and the FROM-item
           arm (codegen.pas:~23957) bailed when `p^.pWhere` was non-nil
           — `count(*) FROM pragma_table_info('t') WHERE name='c'`
           emitted Init/Halt/Goto only.  Lifted both gates and threaded
           `sqlite3ExprIfFalse(pWhere, addrSkip, JUMPIFNULL)` into the
           `OP_VFilter` body (skip the row when WHERE is false, then
           `OP_VNext`).  The check query that gates this row of the
           probe (`SELECT count(*) FROM pragma_table_info('t') WHERE
           name='c'`) now produces the expected count of 1 / 0.

        3. **`OP_ParseSchema` ALTER branch (p4=NULL) was a no-op stub.**
           vdbe.c:7137..7142 calls `sqlite3SchemaClear` + `sqlite3InitOne`
           + `db->mDbFlags |= DBFLAG_SchemaChange` so the in-memory
           `Schema` for iDb is rebuilt from the (just-rewritten)
           `sqlite_master` row.  The Pas port left the branch as
           `rc := SQLITE_OK` with a TODO; routed both p4 modes through
           `vdbeParseSchemaExec` and added a nil-zWhere arm in
           `execParseSchemaImpl` (main.pas:~2697) that calls
           `sqlite3SchemaClear` then `sqlite3InitOne` so the renamed
           column actually shows up in `pragma_table_info`.  Vdbe-side,
           `OP_ParseSchema` now sets `DBFLAG_SchemaChange` after the
           ALTER reload (passqlite3vdbe.pas:9924..).

        Verification (2026-05-06, a3): DiagFeatureProbe — `ALTER TABLE
        rename column` and `ALTER TABLE add column` both PASS;
        TestExplainParity 1026/1026; no regressions across DiagPragma /
        DiagDml / DiagIndexing / DiagSubsel / DiagAggWhere /
        DiagInnerJoin / DiagMisc / DiagOps / DiagMultiValues / DiagTxn /
        DiagWindow / DiagCreateIdx / DiagAutoIdx.  This also unblocks
        the runtime side of 7.1.9 (ALTER end-to-end parity) for the
        RENAME COLUMN and ADD COLUMN paths; RENAME TABLE and DROP
        COLUMN follow the same OP_ParseSchema reload pattern so they
        should now light up too.

  [X] **6.10 step 15** Runtime divergences surfaced by `DiagTxn`
      (transactions, savepoints, conflict resolution).  All PASS as of
      2026-05-06 — DiagTxn 0 divergences; TestExplainParity 1026/1026;
      TestPager / TestPagerRollback / TestPagerCompat all green.
      [X] **b) `BEGIN; ...; ROLLBACK` does not roll back on `:memory:`** —
      [X] **c) `SAVEPOINT s; ROLLBACK TO s` does not unwind** —
        Both closed by single fix in `memjrnlRead`
        (passqlite3pager.pas:599..610).  The Pas port advanced
        `pChunk := pChunk^.pNext` unconditionally at the end of every
        loop iteration; the C reference (memjournal.c) advances inside
        the do-while condition only when more bytes remain.  After a
        small read that fits in a single chunk, the Pas port cached a
        `readpoint.pChunk` one chunk past the actual position, so the
        next read at any offset within that chunk fell into the wrong
        chunk and returned zero-filled bytes from page-record payload.
        Concretely, `readJournalHdr` read nRec correctly at offset 8
        but then read `dbOrigSize` (offset 16), `sectorSize` (offset 20)
        and `pageSize` (offset 24) all as zero, failing the page-size
        sanity check and returning SQLITE_DONE without playing back.
        Replaced the unconditional advance with a conditional advance
        matching C's `(pChunk = pChunk->pNext) != 0` semantics inside
        the loop tail.

  [X] **6.10 step 17** Window-function and aggregate divergences
      surfaced by `DiagWindow`.  All PASS as of 2026-05-06 (multi-window
      arm closed under 6.26).
      [X] **b) `group_concat(val, ',' ORDER BY val DESC)` empty** —
        Closed by 6.24.
      [X] **d) Window aggregates `sum() OVER ()` / `OVER (ORDER BY)`
        / `row_number() OVER (...)` empty rows** — Closed under 6.26.

  [X] **6.11** DROP TABLE remaining gap.  Closed 2026-05-06.
    (b) [X] Bytecode parity already at 1026/1026 in TestExplainParity
        (DROP TABLE PASS at 49 ops vs C reference built with same
        autovacuum settings).  Runtime parity now also clean: the
        nested `DELETE FROM sqlite_master WHERE tbl_name=%Q` emitted
        from `sqlite3CodeDropTable` is productively expanded
        (where-loop DELETE arm via 6.5 ONEPASS_MULTI +
        OpenTableAndIndices), and the trailing OP_ParseSchema reload
        (closed under 6.10 step 9(g) — p4=NULL branch now
        SchemaClear+InitOne) refreshes the in-memory schema so
        re-CREATE / SELECT / INSERT against the same name behave
        identically to C.  Verification (2026-05-06, a3): new
        `DiagDropTable` probe — 9 / 9 PASS (drop+reselect,
        drop+recreate, drop+recreate+insert content witness, drop
        only, drop+select sqlite_master, drop indexed, drop two
        tables one survives, drop indexed then recreate+insert).
        TestExplainParity 1026/1026; no regressions across DiagDml /
        DiagPragma / DiagFeatureProbe / DiagTxn / DiagWindow /
        DiagMisc / DiagOps.
  [X] **6.12** port sqlite3Pragma in full.  Gate `DiagPragma` — all PASS.

  [X] **6.13** Non-regular FROM-item codegen in `sqlite3Select`
       (select.c).  All three sub-arms (eponymous-vtab, sub-SELECT/view,
       compound-SELECT/CTE) landed.  Verification (2026-05-06, a3):
       TestExplainParity 1026/1026; DiagPragma 0 divergences;
       DiagFeatureProbe view / sub-SELECT / UNION compound / CTE-simple
       all PASS.  Recursive-CTE divergence closed 2026-05-06 under
       6.10 step 9(f) (codegen-side, not parser-side).

       **Gate reach (rows closed by 6.13 landing):**
       - 6.10 step 6 sub-FROM (`SELECT a FROM (SELECT a FROM t)`) — closed
       - 6.10 step 9(c) view materialisation (`count(*) FROM v`) — closed
       - 6.10 step 9(e) UNION compound source — closed
       - 6.10 step 9(f) WITH / CTE non-productive — closed 2026-05-06
         (recursive arm now PASS; was a codegen gap, not parser-gated)
       - 6.12 the 10 DiagPragma table-valued probes (eponymous-vtab
         path through pragma_table_info / pragma_index_list / …) — closed
       - DiagFeatureProbe rows (c) view, (e) compound, (f) CTE — closed
         (recursive CTE still tracked under 6.10 step 9(f) / 6.20).

       **Sub-arms ported:**
       [X] **a) Eponymous-vtab arm** — DONE.  `SELECT name FROM
            pragma_pragma_list` returns 66 rows; count(*) and
            arg-bound forms (`pragma_table_info('t')`) now productive
            (DiagPragma 0 divergences; DiagFeatureProbe `pragma
            table_info count` PASS).
       [X] **b) Sub-SELECT / view arm** — flattenSubquery wired into
            sqlite3Select before the co-routine arm; selectExpander now
            assigns the outer iCursor before recursing into the subquery
            (matches build.c:4926..4940), so the splice preserves the
            expected cursor numbers.  Sub-FROM bytecode-Δ row under
            6.10 step 6 closed (1025/1026).
            [X] **6.13(b)-coagg**: agg-arm subquery dispatch (count(*) /
                sum / min / max FROM (SELECT…) and … FROM v) via
                materialise + Rewind scan (codegen.pas:21088..).
       [X] **c) Compound-SELECT / CTE arm** — UNION ALL inline +
            multiSelectByMerge dispatch (with no-ORDER-BY ORDER BY 1
            invention) all wired into sqlite3Select compound dispatch.
            `WITH … AS (…)` non-recursive references still need
            parser-side `WithAdd` / `CteNew` to populate
            `pParse^.pWith` (tracked under 6.20).

---

## Phase 7 — Parser

- [X] **7.1.1** Schema initialisation (prepare.c).  Closed 2026-05-06.
       sqlite3InitOne / sqlite3Init / sqlite3ReadSchema /
       sqlite3InitCallback / sqlite3RunParser bodies all ported 1:1 with
       prepare.c:199..484.  Schema-row INSERT/UPDATE wiring landed
       earlier through the direct `emitSchemaRowInsert` /
       `emitSchemaRowUpdate` paths (CREATE TABLE/INDEX/TRIGGER all
       round-trip across close+reopen — verified manually).
       [X] **Schema reload after ATTACH** — closed by adding the
            `sqlite3Init(db, &zErrDyn)` call inside `attachFunc`
            (passqlite3codegen.pas:39626..) mirroring attach.c:225..242,
            and by setting the `SQLITE_AttachCreate` / `SQLITE_AttachWrite`
            default-on flags in `openDatabase` (passqlite3main.pas:794..)
            to match main.c:3432..3433 — without these flags ATTACH
            silently opened the auxiliary DB read-only and any subsequent
            statement faulted with SQLITE_READONLY.  End-to-end:
            `ATTACH '/tmp/aux.db' AS aux; SELECT a FROM aux.x` now
            returns rows on the Pascal side.  TestExplainParity 1026/1026;
            no regressions across DiagDml / DiagPragma / DiagFeatureProbe /
            DiagTxn / DiagWindow / DiagMisc / DiagOps / DiagDropTable /
            DiagCreateIdx / DiagAnalyze.  Closes the cross-cutting gate
            for ATTACH-reload (7.1.8 below).

- [X] **7.1.2** `sqlite3NestedParse` full driver (build.c).

- [X] **7.1.8** ATTACH / DETACH (attach.c).  Closed 2026-05-06.
       sqlite3Attach / sqlite3Detach / sqlite3ParseUri
       (main.c:3069..3308) all ported 1:1; codegen path productive.
       ATTACH 'file:…?mode=ro' / 'file:…?vfs=memdb' resolve correctly.
       Schema reload after ATTACH wired (see 7.1.1) — `aux.t` is now
       readable end-to-end after `ATTACH 'file' AS aux`.

- [X] **7.1.9** ALTER TABLE (alter.c).  Closed 2026-05-06.  All five
       codegen entry points (sqlite3AlterRenameTable / FinishAddColumn /
       AddConstraint / RenameColumn / DropColumn) and all nine
       sqlite_rename_* / sqlite_drop_* SQL helpers ported.  TestParser
       ALTER TABLE rows PASS.  End-to-end runtime parity verified via
       new DiagFeatureProbe rows (added 2026-05-06): RENAME COLUMN +
       SELECT renamed, ADD COLUMN + SELECT new col, RENAME TABLE +
       SELECT new name, RENAME TABLE + pragma_table_info, DROP COLUMN
       + pragma_table_info, DROP COLUMN + SELECT survivor — all 8
       ALTER probes PASS, total divergences 0.  Unblocked by the
       OP_ParseSchema p4=NULL SchemaClear+InitOne reload landed under
       6.10 step 9(g) / 7.1.1.  Regression sweep (2026-05-06, a3):
       DiagDml / DiagPragma / DiagDropTable / DiagCreateIdx / DiagTxn /
       DiagMisc / DiagOps / DiagAnalyze / DiagSubsel / DiagAggWhere /
       DiagInnerJoin / DiagAutoIdx / DiagIndexing / DiagMultiValues all
       clean; DiagWindow's 2 pre-existing sum/avg-OVER divergences
       unchanged.

- [~] **7.4b** Bytecode-diff scope landed via `TestBytecodeParity.pas`.
  Done 2026-05-06.  Drives `EXPLAIN <sql>` through `sqlite3_prepare_v2 /
  sqlite3_step` on BOTH sides and diffs (opcode, p1, p2, p3, p4, p5)
  byte-for-byte.  17/17 PASS today: CREATE TABLE simple/typed, DROP
  TABLE/INDEX IF EXISTS, INSERT (VALUES + DEFAULT VALUES), UPDATE,
  DELETE, BEGIN (default/IMMEDIATE/EXCLUSIVE/DEFERRED), COMMIT,
  ROLLBACK, SAVEPOINT/RELEASE/ROLLBACK TO.  Companion fix: Pascal
  `sqlite3VdbeList` (vdbe.c port) was setting EXPLAIN result column 6
  to NULL instead of `pOp->p5` — TestExplainParity hid this by walking
  `aOp[]` directly on the Pascal side; new gate exposed it and the
  one-line fix in `passqlite3vdbe.pas` now mirrors `vdbeaux.c:2471`.

  [X] **7.4b.1** OP_Explain p4 string for no-FROM SELECT.  Done
       2026-05-06.  C runs `sqlite3WhereBegin` even on empty FROM
       clause and emits `ExplainQueryPlan(("SCAN CONSTANT ROW"))`
       at where.c:6954.  Pascal's no-FROM fast path
       (codegen.pas:22894) bypasses WhereBegin, so the narrator is
       now emitted inline via `sqlite3VdbeAddOp4(...,'SCAN CONSTANT ROW',
       P4_DYNAMIC)`.  Lifts SELECT-literal rows in TestBytecodeParity.
  [X] **7.4b.2** OP_OpenRead p4 nField (P4_INT32) — Pascal now reduces
       the column count to MSB(pTabItem^.colUsed) when only a prefix
       is referenced, mirroring where.c:7284..7297.  Applied at both
       OpenTable sites in sqlite3WhereBegin (the multi-level loop and
       the single-level fast path).  Lifts table-scan SELECT rows.
  [X] **7.4b.3** OP_MakeRecord p4 affinity for sqlite_master row
       insertion.  Done 2026-05-06.  `emitSchemaRowInsert`
       (codegen.pas:33701) now emits MakeRecord with p4="BBBDB" via
       AddOp4, mirroring sqlite3TableAffinity's iReg=0 ChangeP4 path
       in C's sqlite3NestedParse(INSERT INTO sqlite_master ...).
       Lifts CREATE INDEX rows; remaining CREATE UNIQUE INDEX gap is
       a separate KeyInfo/nKeyField issue tracked in the test header.
  [X] **7.4b.4** CREATE UNIQUE INDEX SorterOpen KeyInfo nKeyField.
       Closed 2026-05-06.  Root cause was in `sqlite3CreateIndex`
       (codegen.pas:35107..), not in `sqlite3KeyInfoOfIndex` as the
       header note guessed.  C's build.c:4241..4243 clears
       `pIndex->uniqNotNull` whenever an indexed column is not
       declared NOT NULL; the Pascal port set the bit unconditionally
       when `onError != OE_None` and never cleared it.  Result:
       sqlite3KeyInfoOfIndex took the `uniqNotNull` branch and
       allocated `KeyInfoAlloc(nKeyCol=1, 0)` instead of
       `KeyInfoAlloc(nColumn=2, 0)` — emitting SorterOpen p4="k(1,)"
       instead of C's "k(2,,)".  Fix: clone the build.c clear inside
       the column-resolution loop right after the column index is
       resolved.  Companion fix: `sqlite3UniqueConstraint`
       (codegen.pas:35976) emitted OP_Halt with a NULL p4; now builds
       the "tab.col[, tab.col2]" zErr (or "index 'name'" for
       expression indices) with sqlite3MPrintf and feeds it as
       P4_DYNAMIC, mirroring build.c:5482..5495.
       Verification: TestBytecodeParity row 'CREATE UNIQUE INDEX i2
       ON t(b)' now PASS; corpus 29 → 30, all PASS.  Regression
       sweep clean (TestExplainParity 1026/1026; DiagDml / DiagPragma
       / DiagDropTable / DiagCreateIdx / DiagTxn / DiagMisc / DiagOps
       / DiagAnalyze / DiagFeatureProbe / DiagIndexing all 0 div).
  [X] **7.4b.5** Implicit PK / WITHOUT ROWID index MakeRecord p4
       affinity.  Closed 2026-05-06.  Re-checking on a3 with the
       7.4b.4 fix in place: both `CREATE TABLE z7(a,b, PRIMARY
       KEY(a,b))` and `CREATE TABLE z8(a PRIMARY KEY, b) WITHOUT
       ROWID` now emit byte-identical bytecode to C (MakeRecord p4
       affinity included).  The header note's reference to
       insert.c:204..222 was misdirection — that affinity comes
       from sqlite3NestedParse on the schema-row INSERT, not from
       any index-key MakeRecord — and the gap was lifted earlier
       by 7.4b.3's emitSchemaRowInsert AddOp4 path.  Folded both
       rows back into TestBytecodeParity ('CREATE TABLE composite
       PK', 'CREATE TABLE WITHOUT ROWID'); corpus 30 → 32, all PASS.
  [X] **7.4b.6** "database disk image is malformed" after a CREATE
       INDEX is followed by a subsequent btree-allocating statement.
       Closed 2026-05-06.  Root cause was NOT in btree at all — the
       earlier "OP_CreateBtree trips a corruption check" framing
       was wrong.  btreeCreateTable returned OK with pgno=4; the
       corruption surfaced from OP_ParseSchema fired at the tail
       of CREATE TABLE u.  execParseSchemaImpl
       (passqlite3main.pas:2688) runs an unfiltered
       `SELECT type,name,tbl_name,rootpage,sql FROM sqlite_master`
       (the WHERE-filter elision documented in the surrounding
       banner — Pascal sqlite3Select can't yet handle it
       productively), and sqlite3InitCallback's "skip already-
       published" gate only consulted sqlite3FindTable.  Rows of
       type='index' fell through that gate, so on the third
       ParseSchema fire (after CREATE TABLE u) row `i1` re-prepared
       `CREATE INDEX i1 ON t(a)` against an already-populated
       idxHash → "index already exists" → initCorruptSchema set
       pData^.rc to SQLITE_CORRUPT, which the OP_ParseSchema worker
       reported as "database disk image is malformed".  Fix:
       passqlite3main.pas:2618 — extend the gate to also skip when
       sqlite3FindIndex returns non-nil (sqlite3FindTable already
       covers tables and views; triggers are not exposed via a
       Find* helper in this port and don't currently surface in
       the corpus).  Verification: minimal repro (CREATE TABLE t /
       CREATE INDEX i1 / CREATE TABLE u) returns rc=0 on the
       trailing CREATE TABLE; DiagCovering 0 div (was 1);
       DiagCreateIdx / DiagIndexing / DiagDml / DiagPragma /
       DiagDropTable / DiagTxn / DiagMisc / DiagOps / DiagAnalyze
       / DiagFeatureProbe all 0 div; TestExplainParity 1026/1026;
       TestBytecodeParity 32/32.

- [ ] **7.4d** WITHOUT ROWID runtime corruption.  Bytecode parity for
  `CREATE TABLE x(k PRIMARY KEY, v) WITHOUT ROWID` was closed under
  7.4b.5, but the runtime path corrupts the page on the first INSERT —
  `INSERT INTO x VALUES('k','v'); SELECT * FROM x;` raises `database
  disk image is malformed`.  Repro: `bin/passqlite3 t.db` followed by
  the two statements above.  Workaround currently in passqlite3shell:
  paramTableInit emits a plain rowid `temp.sqlite_parameters` table
  instead of the upstream WITHOUT ROWID variant.  Fix likely in the
  btree-cell payload assembly for a clustered-key insert.

- [ ] **7.4e** Bare-bareword `INSERT INTO ... VALUES('k', hello)`
  silently binds NULL instead of raising `no such column: hello`.
  Reproduced via `.parameter set $name 'hello'` (the dot-cmd tokenizer
  strips the quotes, then the SQL splice produces the above).
  Worked around in cmdParameter via `looksLikeSqlLiteral`, but the
  underlying parser/expr-resolver gap should be fixed: an unresolved
  bare identifier in a value position must error, not coerce to NULL.

- [X] **7.4c** `TestVdbeTrace.pas` differential opcode-trace gate.  Done
  2026-05-06.  `passqlite3vdbe` exports `gVdbeTraceBuf` and the
  `sqlite3VdbeExec` main loop appends one normalised line per executed
  opcode (`pc opname p1 p2 p3 p5`) when `db^.flags & SQLITE_VdbeTrace`
  is set, mirroring the C reference's `sqlite3VdbePrintOp` call gated
  on the same flag at vdbe.c:954.  The test enables the flag only for
  the user statement's `sqlite3_step` (so schema-load bytecode emitted
  during `prepare_v2` is excluded) and on the C side runs `PRAGMA
  vdbe_trace=ON` after `csq_prepare_v2`, redirects libc fd-1 to a
  temp file, parses the trace lines back out, and skips everything
  before the last `VDBE Trace:` marker (the PRAGMA's own trace).
  Corpus: 8 statements (`SELECT 1`, `SELECT 1+2`, `SELECT NULL`,
  `SELECT 1,2,3`, `SELECT abs(-7)`, `SELECT 2*3+4`,
  `SELECT length('hi')`, `SELECT 5>3`) — all pass byte-for-byte
  on opcode/p1/p2/p3/p5.

---

## Phase 8 — Public API (one gate open)

Public-API gap analysis 2026-04-28: `../sqlite3/src/sqlite.h.in` exports
~238 `sqlite3_*` symbols; the Pascal port currently exposes ~156.  The
items below enumerate every missing symbol grouped by sub-phase.
Windows-only entry points (`sqlite3_win32_*`) and pure typedefs
(`sqlite3_int64`, `sqlite3_uint64`, opaque struct names) are excluded.

- [X] **8.9.2** Carray / shared-cache / misc (sqlite3_carray_bind) — done

- [X] **8.x** `unixCurrentTimeInt64` (os_unix.c:7193) — ported 2026-04-29 in
       passqlite3os.pas.  Returns *piNow as Julian-day-times-86_400_000;
       `unixCurrentTime` rewritten as the thin wrapper used in C.  VFS
       `iVersion` bumped 1→2 so `xCurrentTimeInt64` is now reachable through
       the shared `sqlite3OsCurrentTimeInt64` chain (memdb already wraps it).

- [X] **8.10** Public-API sample-program gate — closed 2026-05-06 in
  `src/tests/DiagSampleProg.pas`.  Three canonical samples
  (quickstart `sqlite3_exec`+callback, cintro prepare/step loop, and a
  prepared-INSERT bind variant) run through both the upstream C library
  (via `csqlite3` → `libsqlite3.so` built by `build.sh`) and the Pascal
  port; the gate captures each sample's textual transcript and asserts
  byte-for-byte parity.  Current run: 6 PASS / 0 FAIL.

---

## Phase 10 — CLI tool (`shell.c`, ~12k lines → `passqlite3shell.pas`)

Each chunk lands with a scripted parity gate that diffs
`bin/passqlite3` against the upstream `sqlite3` binary.  Unported
dot-commands must return the upstream
`Error: unknown command or invalid arguments: ".foo"` so partial
landings cannot silently no-op.

Sub-tasks 10.1.x decompose 10.1a..10.1f into one item per dot-command
or helper.  Source references are line ranges in
`../sqlite3/src/shell.c.in`.  Skeleton landed 2026-05-06 in
`src/passqlite3shell.pas` (~990 lines, built into `bin/passqlite3` by
`src/tests/build.sh`); 10.1.7..10.1.59 hang per-command arms off the
existing dispatcher.

- [~] **10.1a** Skeleton + arg parsing + REPL loop.  Entry point,
  command-line flag parser, `ShellState` struct, line reader, prompts,
  the read-eval-print loop, statement-completeness via
  `sqlite3_complete`, exit codes.  Skeleton landed 2026-05-06; full
  arg-parser coverage pending under 10.1.3.  Gate: `tests/cli/10a_repl/`
  (not yet created — 10.2 will scaffold it).

  [X] **10.1.1** `ShellState` record + global state (shell.c.in
       `struct ShellState` ~363..441) — landed 2026-05-06 in
       passqlite3shell.pas.  All non-FIDDLE non-SESSION fields ported
       1:1, plus the Mode / ModeInfo / TDotCmdLine / TAuxDb /
       TSavedMode satellites and the full constant blocks (AUTOEQP_*,
       SHELL_OPEN_*, SHELL_TRACE_*, SHELL_PROGRESS_*, SHFLG_*,
       MODE_*, MFLG_*, DFLT_*, SEP_*).  aModeInfo[] / aModeStr[] /
       qrfEscNames / qrfQuoteNames carried verbatim from
       shell.c.in:480..605.
  [~] **10.1.2** `process_input` / `one_input_line` REPL core landed
       2026-05-06 (passqlite3shell.pas processInput / oneInputLine).
       Continuation prompt + sqlite3_complete-driven dispatch + dot/
       hash early-exit + bail_on_error all wired.  `.echo` plumbing
       and the upstream `quickscan` state machine (which gates the
       buffer growth path more tightly) are deferred — current cut
       falls back to raw sqlite3_complete on every accumulated
       semicolon, matching upstream's pre-quickscan branch.
  [~] **10.1.3** `main` + `process_command_line` argument parser —
       initial cut (2026-05-06) handles `-bail`, `-batch`, `-readonly`,
       `-version`, `-help`, `--`, plus a positional FILENAME and
       optional trailing SQL string.  Remaining flags (`-cmd`, `-init`,
       `-newline`, `-mode`, `-separator`, `-nullvalue`, `-header`, the
       SHFLG_* toggles, `-vfs`, `-stats`, `-zip`, `-deserialize`, …)
       still pending; tracked here.
  [X] **10.1.4** Line reader / readline integration — basic
       `localGetLine` (LF / CRLF aware) + `oneInputLine` landed
       2026-05-06.  GNU readline integration (history, line editing)
       deferred to a 10.1.4 follow-up; current cut uses FPC stdin.
  [X] **10.1.5** Exit-code mapping + `interrupt_handler` + signal
       wiring — `installInterruptHandler` (SIGINT → seenInterrupt +
       sqlite3_interrupt(globalDb)) landed 2026-05-06.
  [X] **10.1.6** `do_meta_command` dispatcher skeleton — landed
       2026-05-06.  `.quit` / `.exit` exit cleanly; `.help` / `.show`
       are minimal stubs; every other dot-command emits
       `Error: unknown command or invalid arguments:  "<name>". Enter ".help" for help`
       — verified byte-identical to system `sqlite3` for `.foo`.
       Per-command handlers land in 10.1.7..10.1.59.

- [ ] **10.1b** Output modes + formatting controls.  `.mode`
  (`list`, `line`, `column`, `csv`, `tabs`, `html`, `insert`, `quote`,
  `json`, `markdown`, `table`, `box`, `tcl`, `ascii`), `.headers`,
  `.separator`, `.nullvalue`, `.width`, `.echo`, `.changes`,
  `.print` / `.parameter` (formatting-only subset), Unicode-width
  helpers, box-drawing renderer.  Gate: `tests/cli/10b_modes/`.

  [X] **10.1.7** `.mode` dispatcher (~10470) — `modeChange` /
       `modeChangeBuiltin` / `modeFind` ported from shell.c.in:1642..1728
       in passqlite3shell.pas; the ShellState QRF spec is updated in the
       same field order as C (eCSep/eRSep/eNull/eText/eBlob/eTitle/
       bBorder/bSplitColumn).  `.mode <name> [tableName]` arms in
       doMetaCommand wired through.  BATCH/TTY templates also handled.
  [X] **10.1.8** `shell_callback` row dispatcher + per-mode renderers
       (subset).  TRenderState + emitHeader/emitRowOne/emitFooter +
       stepAndRender drive runOneSqlLine.  Modes covered: List, Line,
       Csv, Tabs, Ascii, Quote, Insert (with decltype-aware integer
       promotion), Json (array-of-objects with leading "["/trailing
       "]"), Tcl (C-style escapes), Html (TR/TD with HTML-escape),
       Markdown (pipe-bordered with separator row), Column (naive
       left-aligned), Off.  Box / Table / QBox / Www / JAtom / JObject
       / Split / Psql / Count fall through to a pipe-delimited
       fallback so the REPL stays usable; full QRF wiring lands when
       the QRF unit ports.
  [X] **10.1.9** Columnar renderers — `MODE_Column`, `MODE_Table`,
       `MODE_Markdown`, `MODE_Box`.  Buffered renderer (`emitColumnar`,
       passqlite3shell.pas) computes per-column max display widths from
       header + every row, honours `.width` minimums, then emits.
       `utf8DispWidth` counts non-continuation UTF-8 bytes (one glyph
       per code point); CJK wide-char support arrives with the full QRF
       port.  Glyph sets: Box uses Unicode box-drawing (┌ ─ ┬ ┐ │ ├ ┼ ┤
       └ ┴ ┘); Table uses MySQL-style `+ -- |`; Markdown uses pipes with
       a `|---|` separator row; Column has no borders, two spaces between
       columns and a `---` underline under each header.  Headers are
       centered in Box / Table / Markdown, left-aligned in Column.
       MODE_Line auto-width also closed (was hard-coded `width=20`; now
       uses max column-name length + 1 like upstream).  Verification
       (2026-05-06): 12-cell mode×headers matrix (column / table / box
       / list / line / markdown × on / off) + edge-case suite (empty
       result, single-column, NULL+nullvalue, .width override, long
       values, UTF-8 data, multi-statement) all byte-identical to system
       sqlite3.  TestExplainParity 1026/1026; DiagFeatureProbe / DiagDml
       / DiagMisc / DiagTxn / DiagOps / DiagPragma / DiagDropTable green;
       DiagWindow 2 divergences (pre-existing, unrelated).
  [X] **10.1.10** `.headers` / `.separator` / `.nullvalue` / `.echo`
       / `.changes` / `.width` setters landed in doMetaCommand.
       AnsiString backing for the PAnsiChar fields lives in unit-level
       zUserColSep / zUserRowSep / zUserNull; `.width` stores parsed
       widths in aUserWidth and points spec.aWidth/nWidth at it.
  [X] **10.1.11** `.print` / `.parameter init|list|set|unset|clear`.
       cmdParameter mirrors shell.c.in:10264..10367; paramTableInit
       creates temp.sqlite_parameters (with-rowid; upstream's WITHOUT
       ROWID variant is gated on a port bug logged separately).
       paramSet uses looksLikeSqlLiteral to decide whether to splice
       the value as a literal (digits / quotes / NULL / X'...') or
       wrap it as text — sidesteps the upstream "bare bareword binds
       NULL" quirk that the Pascal parser inherits.
  [X] **10.1.12** CSV writer helpers — `outputCsvField` mirrors
       `output_csv` (quote-on-{sep,",CR,LF}; embedded quotes doubled).
       Wired into emitRowOne MODE_Csv arm.
  [X] **10.1.13** JSON writer helpers — `outputJsonString` (RFC 8259
       \" \\ \b \f \n \r \t and \u00XX) wired into emitRowOne MODE_Json.
  [X] **10.1.14** HTML writer helpers — `outputHtmlString` (escape
       <, >, &, ", ') wired into emitRowOne MODE_Html.

- [ ] **10.1c** Schema introspection dot-commands. Gate: `tests/cli/10c_schema/`. 
  - [ ] `.schema`,
  - [ ] `.tables`, 
  - [ ] `.indexes`, 
  - [ ] `.databases`, 
  - [ ] `.fullschema`,
  - [ ] `.lint fkey-indexes`, 
  - [ ] `.expert` (read-only subset).  

  [~] **10.1.15** `.schema` arm landed (cmdSchema): pulls
       `SELECT sql FROM sqlite_schema [WHERE name LIKE pat] ORDER BY
       tbl_name, type DESC, name`.  `--indent` / `--nosys` flags
       still pending; `.sqlite_schema` alias not yet wired.
  [X] **10.1.16** `.tables` — cmdTables runs
       `SELECT name FROM sqlite_schema WHERE type IN ('table','view')
       AND name LIKE pat AND name NOT LIKE 'sqlite_%' ORDER BY 1`.
       One name per line for now; upstream's 3-column auto-format
       lands with 10.1.9 column-width work.
  [X] **10.1.17** `.indexes` — cmdIndexes runs
       `SELECT name FROM sqlite_schema WHERE type='index' [AND
       tbl_name=?] ORDER BY 1`.
  [X] **10.1.18** `.databases` — cmdDatabases runs
       `SELECT name, file FROM pragma_database_list ORDER BY seq`.
  [~] **10.1.19** `.fullschema` — cmdFullschema dumps CREATE statements
       (excluding sqlite_stat%) plus sqlite_stat1/sqlite_stat4 INSERTs
       (when those tables exist).  --indent reformatter still pending
       with .schema's --indent option.
  [~] **10.1.20** `.lint fkey-indexes` — cmdLint runs a simplified FK
       audit (CREATE INDEX suggestion per FK constraint, derived from
       pragma_foreign_key_list).  The full upstream variant uses
       fkey_collate_clause()+EXPLAIN-based coverage detection;
       deferred until those helpers are ported.
  [X] **10.1.21** `.expert` — cmdExpert emits the upstream
       "this build does not support the .expert command" stub
       (sqlite3_expert.c not yet ported).

- [ ] **10.1d** Data I/O dot-commands.  `.read`, `.dump`, `.import`
  (CSV/ASCII), `.output` / `.once`, `.save`, `.open`.  Gate:
  `tests/cli/10d_io/`.

  [X] **10.1.22** `.read FILE` — cmdRead pushes the named file onto a
       Pascal-side input stack (curInputText) and re-enters processInput;
       inputNesting still gates the existing recursion guard.  Pipe
       (`|cmd`) variants emit the upstream "pipes are not supported"
       error.
  [~] **10.1.23** `.dump` — minimal viable port landed
       (cmdDump / dumpOneObject).  Emits PRAGMA foreign_keys=OFF +
       BEGIN TRANSACTION header, dumps CREATE TABLE statements +
       INSERT INTO rows (rendered through MODE_Insert with zDestTable
       set), then non-table objects (indexes/views/triggers), then
       COMMIT.  Honours `--data-only` and `--nosys` plus a LIKE
       pattern.  `--preserve-rowids` and `--newlines`, the upstream
       sqlite_sequence handling, the corruption detour with `ORDER BY
       rowid DESC`, and explicit column-list INSERTs (via
       `tableColumnList`) defer to a follow-up.  Round-trip verified
       on simple schemas; used by `.once` integration test.
  [~] **10.1.24** `.import` — initial cut landed (cmdImport):
       ImportCtx + importGetc + importAppendChar + csvReadOneField +
       asciiReadOneField mirror shell.c.in:4958..5150; the dispatcher
       handles `-csv`, `-ascii`, `-schema`, `-skip N`, `-v`, `-esc`,
       `-qesc`, `-colsep`, `-rowsep` and runs the bulk INSERT in a
       single transaction (BEGIN/COMMIT gated on sqlite3_get_autocommit).
       BOM strip, RFC-4180 quoted fields with embedded separators /
       row terminators / doubled quotes, the per-row "expected N found
       M — filling with NULL / extras ignored" warnings, and the final
       `Added R rows with E errors using L lines` -v breadcrumb all
       wired.  Deferred: the auto-create-from-header path (zAutoColumn,
       shell.c.in:7165..7470 — needs the side-memory ColNames db),
       the `<<MARK` heredoc input mode (shell.c.in:7601..7638), and
       pipe input (`|cmd`).  Destination table must exist; clear
       error otherwise.
  [X] **10.1.25** `.output` / `.once` — cmdOutput landed.
       Redirection sits at the POSIX-fd level (dup the original
       stdout at startup; dup2 the file fd onto fd 1 to redirect;
       dup2 the saved fd back to revert) so all `Write` / `WriteLn`
       follow without per-call-site changes.  `.output FILE`,
       `.output stdout`, `.output off` (-> /dev/null), `.once FILE`,
       `--bom` all wired.  `nPopOutput=2` set on `.once`,
       decremented after each dot-cmd and forced to 0 after each SQL
       line (mirrors shell.c.in:12068..12071 + 12512..12517).
       cmdShow now reports the active output sink.  Pipe targets
       (`|cmd`) emit "pipes are not supported".  `.excel` / `.www`
       (xdg-open shorthands) emit a "not wired in this build" warn.
  [X] **10.1.26** `.save ?DB? FILE` — cmdBackup arm (shared with .backup).
       sqlite3_backup_init/_step/_finish copy main into a fresh dest db
       opened with READWRITE|CREATE.
  [~] **10.1.27** `.open ?-options? ?FILE?` — cmdOpen handles `-new`,
       `-readonly`, `-exclusive`, `-ifexists`, `-nofollow`; closes the
       current db, opens new (with TEMP fallback on failure).  `--zip`
       and `--deserialize` defer until those VFSes/extensions are
       ported.

- [ ] **10.1e** Meta / diagnostic dot-commands. Gate: `tests/cli/10e_meta/`.  
  - [ ] `.stats`
  - [ ] `.timer`
  - [ ] `.eqp`, 
  - [ ] `.explain`, 
  - [ ] `.show`, 
  - [ ] `.help`, 
  - [ ] `.shell`/`.system`, 
  - [ ] `.cd`,
  - [ ] `.log`, 
  - [ ] `.trace`, 
  - [ ] `.iotrace`, 
  - [ ] `.scanstats`, 
  - [ ] `.testcase`,
  - [ ] `.testctrl`, 
  - [ ] `.selecttrace`, 
  - [ ] `.wheretrace`.  

  [X] **10.1.28** `.stats off|on|stmt|vmstep` — cmdStats setter +
       displayStats / displayStatLine / displayLinuxIoStats port of
       shell.c.in:2722..2944.  Walks sqlite3_status64 / sqlite3_db_status
       / sqlite3_stmt_status counter sets and emits the upstream
       label/value table; statsOn=2 prints per-column metadata, =3 prints
       only the VM-step counter.  pStmt is now plumbed through
       runOneSqlLine so per-statement counters resolve.
  [~] **10.1.29** `.timer on|off|once` setter landed (cmdTimer);
       sets ShellState.enableTimer to 0/1/2.  Wall/user/sys clock
       probe around stepAndRender still pending.
  [X] **10.1.30** `.eqp off|on|trace|trigger|full` — cmdEqp updates
       mode.autoEQP / autoEQPtrace, toggles `PRAGMA vdbe_trace`.
  [X] **10.1.31** `.explain auto|on|off` — cmdExplain sets
       mode.autoExplain.  Bytecode dump formatting deferred.
  [X] **10.1.32** `.show` — cmdShow dumps echo / eqp / explain /
       headers / mode / nullvalue / colseparator / rowseparator /
       stats / width / filename in upstream's `%12.12s: …` format.
       The `output` field is still pending (depends on `.output`).
  [X] **10.1.33** `.help ?-all? ?PATTERN?` — full upstream azHelp[]
       table (~175 documented entries) ported from shell.c.in:3708..3965
       plus the showHelp() walker (3980..4090): bare invocation prints
       the one-line summary; `-a` / `-all` / `--all` shows every
       documented command's full block; `0` shows undocumented commands;
       PATTERN does prefix-glob first, then substring-LIKE fallback via
       sqlite3_strglob / sqlite3_strlike.
  [~] **10.1.34** `.shell` / `.system` — cmdShell concatenates args
       (single-token args bare, multi-word args wrapped in `"`),
       runs them via libc system()/Unix.fpsystem, and emits the
       upstream `System command returns N` breadcrumb on non-zero
       exit.  Output capture into the `.output` sink pending.
  [X] **10.1.35** `.cd DIRECTORY` — cmdCd wraps FpChdir; mirrors
       upstream's `Cannot change to directory "…"` error string.
  [~] **10.1.36** `.log FILENAME|on|off` — cmdLog records the
       destination so `.show` reflects it; SQLITE_CONFIG_LOG wiring
       gated on the raw-varargs sqlite3_config port (8.1.1).
  [~] **10.1.37** `.trace ?OPTIONS?` — cmdTrace parses the upstream
       option set (FILE / stdout / stderr / off / --expanded / --plain
       / --stmt / --profile / --row / --close), opens the requested
       sink, builds the mTrace mask, and registers a Pascal cdecl
       traceCallback through sqlite3_trace_v2.  Actual firing of the
       callback is gated on the VDBE-side trace dispatch — db^.mTrace /
       db^.trace.xV2 are stored but never invoked from the step path
       yet.  When that wires (separate VDBE follow-up), `.trace` will
       light up without further shell-side changes.
  [ ] **10.1.38** `.iotrace` — wires `sqlite3IoTrace` (gated on the
       6.8 `sqlite3VdbeIOTraceSql` arm landing first).
  [~] **10.1.39** `.scanstats on|off|est|vm` — cmdScanstats records the
       mode locally and emits upstream's "not available in this build"
       warning; full wiring still gated on the 6.8
       `sqlite3VdbeScanStatus*` arms + 8.2.1 `sqlite3_stmt_scanstatus`.
  [~] **10.1.40** `.testcase NAME` — cmdTestcase records NAME in
       p^.zTestcase; the `.check ANSWER` comparator side (which
       redirects shell output to a buffer) is still pending.
  [ ] **10.1.41** `.testctrl` — `sqlite3_test_control` opcode
       dispatcher (gated on 8.4.1).
  [~] **10.1.42** `.selecttrace` / `.wheretrace` / `.treetrace` —
       cmdTraceFlags emits a "requires a debug build; ignored"
       breadcrumb so partial landings don't fall through to the unknown-
       command arm.  Full TRACEFLAGS wiring needs the varargs
       sqlite3_test_control variant (deferred).

- [ ] **10.1f** Long-tail / specialised dot-commands.  
  Out-of-scope dependencies (session, archive, recover)
  may stub with the upstream `SQLITE_OMIT_*` "feature not compiled
  in" message.  Gate: `tests/cli/10f_misc/`.  - [ ] `.backup`,
  - [ ] `.restore`, 
  - [ ] `.clone`, 
  - [ ] `.archive`/`.ar`, 
  - [ ] `.session`, 
  - [ ] `.recover`,
  - [ ] `.dbinfo`, 
  - [ ] `.dbconfig`, 
  - [ ] `.filectrl`, 
  - [ ] `.sha3sum`, 
  - [ ] `.crnl`,
  - [ ] `.binary`, 
  - [ ] `.connection`, 
  - [ ] `.unmodule`, 
  - [ ] `.vfsinfo`, 
  - [ ] `.vfslist`,
  - [ ] `.vfsname`. 
  

  [X] **10.1.43** `.backup ?DB? ?-async? ?-append? FILE` — cmdBackup
       wraps sqlite3_backup_init/_step/_finish (100-page chunks).
       --async runs `PRAGMA synchronous=OFF; PRAGMA journal_mode=OFF`
       on the destination; --append accepted but no-ops because the
       apndvfs has not been registered.
  [X] **10.1.44** `.restore ?DB? FILE` — cmdRestore runs the symmetric
       backup with the upstream 3-attempt SQLITE_BUSY retry loop
       (sqlite3_sleep(100) between attempts).
  [X] **10.1.45** `.clone NEWFILE` — cmdClone + cloneTransferSchema +
       cloneTransferData mirror tryToClone / tryToCloneSchema /
       tryToCloneData (shell.c.in:5157..5368).  Schema replayed via
       sqlite3_exec; data copied through INSERT OR IGNORE with the
       upstream `ORDER BY rowid DESC` retry on read errors.  Honours the
       "File already exists" guard.
  [ ] **10.1.46** `.archive` / `.ar` — sqlar reader/writer; gated on
       sqlar extension.  Stub with omit-message until that lands.
  [ ] **10.1.47** `.session` — session-extension dispatcher
       (`attach`, `enable`, `filter`, `indirect`, `isempty`, `list`,
       `changeset`, `patchset`).  Gated on session extension; stub
       with omit-message.
  [ ] **10.1.48** `.recover` — corruption-recovery extension dispatcher.
       Gated on recover extension; stub with omit-message.
  [X] **10.1.49** `.dbinfo` — cmdDbinfo reads the 100-byte page-1
       header via `SELECT data FROM sqlite_dbpage(?) WHERE pgno=1`
       and prints the canonical field/query block; also calls
       SQLITE_FCNTL_DATA_VERSION for the `data version` line.
       sqlite_dbpage virtual table is now auto-registered on every
       openDb() so `.dbinfo` works without explicit module loading.
  [~] **10.1.50** `.dbconfig ?op? ?val?` — cmdDbconfig dispatches
       through sqlite3_db_config_int across the boolean DBCONFIG_* set
       (defensive, dqs_*, enable_*, legacy_*, no_ckpt_on_close,
       reset_database, trusted_schema).  Counter-style and pointer-
       style ops still gated on the raw-varargs sqlite3_db_config port
       (8.1.1).
  [ ] **10.1.51** `.filectrl` — `sqlite3_file_control` opcode
       dispatcher (gated on 8.4.1).
  [ ] **10.1.52** `.sha3sum` — runs the SHA3 hash extension over
       schema + data.  Bundles a Pascal SHA3 implementation or links
       the existing extension.
  [X] **10.1.53** `.crnl` — cmdCrnl on Linux always clears MFLG_CRLF
       and echoes `crlf is OFF`; matches upstream's non-Windows arm.
  [X] **10.1.54** `.binary` — cmdBinary emits the upstream
       `The ".binary" command is deprecated.` breadcrumb.
  [X] **10.1.55** `.connection ?N? | close N` — cmdConnection swaps
       p^.pAuxDb across the aAuxDb[0..4] slots.  Bare `.connection`
       lists ACTIVE / open / not-open slots in upstream's column
       layout; `close N` releases a slot's db without disturbing the
       active one.
  [X] **10.1.56** `.unmodule [--allexcept] NAME ...` — cmdUnmodule
       dispatches through sqlite3_drop_modules (with the NULL-
       terminated PPAnsiChar) for `--allexcept`, otherwise calls
       sqlite3_create_module(name, NULL, NULL) per name.
  [~] **10.1.57** `.vfsinfo` / `.vfslist` / `.vfsname` — cmdVfsinfo /
       cmdVfslist / cmdVfsname use SQLITE_FCNTL_VFS_POINTER and walk
       sqlite3_vfs_find chain.  `.vfsname` returns empty for the unix
       VFS because SQLITE_FCNTL_VFSNAME is only handled by the memdb
       VFS today (small follow-up: surface the unix-VFS variant via
       sqlite3OsFileControl).
  [X] **10.1.58** `.dbtotxt` — cmdDbtotxt ports
       shell.c.in:5579..5674 page-by-page hex dump.  Reads page size
       via `PRAGMA page_size`, page count via
       `SELECT count(*) FROM sqlite_dbpage` (workaround for a Pascal-
       port `PRAGMA page_count` gap that returns no rows — tracked
       separately under Phase 6 PRAGMA follow-up).  Skips all-zero
       16-byte runs to keep dumps compact.  Hex output is lowercase
       to match upstream.
  [X] **10.1.59** `.breakpoint` — cmdBreakpoint no-op stub
       (gdb-attach hook only; not exercised by any gate).

- [ ] **10.1.bug.2** sqlite3_trace_v2 callback never fires.  The
  Pascal port's sqlite3_trace_v2 stores db^.mTrace + db^.trace.xV2 but
  nothing in the VDBE step path invokes db^.trace.xV2 — neither at
  SQLITE_TRACE_STMT prepare-start, PROFILE end-of-stmt, ROW per-row,
  nor CLOSE on connection close.  Port the upstream trace fanout
  (vdbe.c/main.c — search for `mTrace` and `trace.xV2`) so .trace
  lights up.  Until then `.trace` is a configurable no-op.

- [X] **10.1.bug.1** Header row leak in `.mode list` fixed: the port
  was treating `bTitles` as a 0/1 boolean while upstream uses QRF
  tri-state semantics (QRF_No=1=off, QRF_Yes=2=on).  Defined the QRF_*
  constants, switched `renderInit`/`cmdShow` to compare against
  `QRF_Yes`, and updated `cmdHeaders` and the startup default to use
  `QRF_No`/`QRF_Yes` so `aModeInfo[].bHdr` (which already follows the
  upstream tri-state) flows through correctly.

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

- [ ] **11.9** Profiling hand-off to Phase 12.  Wrapper scripts that
  run `passpeedtest1` under `perf record` and
  `valgrind --tool=callgrind`, plus a small Pascal helper that
  annotates the resulting reports against `passqlite3*.pas` source
  lines.  Output of this task is the input of 12.1.

---

## Phase 12 — Acceptance: differential + fuzz

- [ ] **12.1** `TestSQLCorpus.pas`: full SQL corpus (Phase 0.10 + any
  additions) runs end-to-end.  stdout, stderr, return code, and the
  resulting `.db` byte-identical to the C reference.

- [ ] **12.2** `TestReferenceVectors.pas`: every canonical `.db` in
  `vectors/` opens, queries, and reports results identically.

- [ ] **12.3** `TestFuzzDiff.pas`: AFL-driven differential fuzzer.
  Seed from the `dbsqlfuzz` corpus.  Run for ≥24 h.  Any divergence
  is a bug.

- [ ] **12.4** SQLite's own Tcl test suite (`../sqlite3/test/*.test`):
  wire the Pascal port in as an alternate target where feasible.
  Internal-API tests will not apply; the "TCL" feature tests should.

---

## Phase 13 — Performance optimisation (enter only after Phase 9 green)

Changes here must preserve byte-for-byte on-disk parity.  Compile
flags: `-dAVX2 -CfAVX2 -CpCOREAVX -OpCOREAVX`.  Note: in FPC,
functions with `asm` content cannot be inlined.

- [ ] **13.1** `perf record` on benchmark workloads; identify the
  top 10 hot functions.

- [ ] **13.2** Aggressive `inline` on VDBE opcode helpers, varint
  codecs, and page cell accessors.

- [ ] **13.3** Consider replacing the VDBE big `case` with threaded
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
