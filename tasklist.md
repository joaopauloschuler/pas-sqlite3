# pas-sqlite3 — Remaining Task List

Port of **SQLite 3** (D. Richard Hipp et al., public domain) from C to Free Pascal.
Source of truth: `../sqlite3/` (the original C reference — the upstream split
source tree under `../sqlite3/src/*.c`). The amalgamation is **not used** by
this project, neither as a porting reference nor as an oracle build input.
Inspiration for structure, tone, and workflow: `../pas-core-math/`, `../pas-bzip2/`.

REMEMBER: You are porting code. DO NOT RANDOMLY ADD TESTS unless you are looking for a specific bug. If you are porting existing tests in C, mention the origin of the test that you are porting.

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

## Phase 6 — Code generators (close the EXPLAIN gate)

- [ ] **6.8** port one-line / empty-body stubs in full from C to pascal.
       Identified 2026-04-28 by cross-referencing each Pascal one-liner
       against `../sqlite3/src/`.  Each entry below has a non-trivial C
       body that the current Pascal version silently elides.

       VDBE auxiliary (vdbeaux.c):
       [X] `sqlite3VdbeCloseStatement` — closed 2026-04-29.  Ported the
            `vdbeCloseStatement` body in vdbe.pas (verbatim from
            vdbeaux.c:3215..3263): per-attached-btree
            sqlite3BtreeSavepoint(ROLLBACK then RELEASE), nStatement
            decrement, sqlite3VtabSavepoint pair, and nDeferredCons
            restore on ROLLBACK.  Required helper `sqlite3BtreeSavepoint`
            ported in btree.pas (verbatim from btree.c:4614 — no
            shared-cache, gated on inTrans=TRANS_WRITE; calls
            saveAllCursors → sqlite3PagerSavepoint → newDatabase →
            btreeSetNPage).  Not yet exercised by any test path because
            the VDBE op that opens a per-statement savepoint is not
            emitted yet (lands with sqlite3GenerateConstraintChecks /
            sqlite3Update); regressions clean: TestBtreeCompat 337/0,
            TestExplainParity 1016/10, TestVdbeApi 57/0, TestDMLBasic
            54/0, TestSelectBasic 49/0, TestVdbeAgg 11/0,
            TestPagerRollback ALL PASS, TestVdbeTxn 8/0.
       [X] `sqlite3VdbeRecordCompareWithSkip` — closed 2026-04-28.
            vdbe.pas wrapper now delegates to the full
            `sqlite3VdbeRecordCompare` body in btree.pas (bSkip=0 is
            the only value passed by current callsites; bSkip>0
            optimisation deferred).  Same fix lifted the
            `sqlite3VdbeRecordCompare` and `sqlite3VdbeFindCompare`
            local stubs in vdbe.pas onto the btree.pas bodies.
       [X] `sqlite3VdbeScanStatus` / `sqlite3VdbeScanStatusRange` /
            `sqlite3VdbeScanStatusCounters` — empty stubs match the C
            `#define foo(...)` arms when SQLITE_ENABLE_STMT_SCANSTATUS
            is not defined (vdbe.h:423..425).  Pas build does not enable
            this option; bodies will land alongside any future
            `sqlite3_stmt_scanstatus` port (8.2.1).
       [X] `sqlite3VdbeExplain` — closed 2026-04-29.  Verbatim port of
            vdbeaux.c:517 in vdbe.pas: gates on Parse.explain==2 (NDEBUG
            arm; no ENABLE_STMT_SCANSTATUS), formats the message via
            sqlite3VMPrintf, emits OP_Explain via sqlite3VdbeAddOp4 with
            P4_DYNAMIC ownership, optionally pushes the new addr onto
            pParse^.addrExplain when bPush<>0, and calls
            sqlite3VdbeScanStatus (currently a no-op stub matching the
            !ENABLE_STMT_SCANSTATUS arm).  Signature gained an
            `array of const` tail to match C's varargs; no callers exist
            yet so safe to extend.  TestExplainParity 1016/10, TestVdbeApi
            57/0, TestParser 45/0, TestSelectBasic 49/0, TestVdbeAgg 11/0,
            TestBtreeCompat 337/0, TestDMLBasic 54/0, TestPrintf 105/0,
            DiagPubApi 240/0, TestAuthBuiltins 34/0 — no regressions.
       [X] `sqlite3VdbeExplainPop` — closed 2026-04-28.  vdbe.pas now
            mirrors the C one-liner: `pParse^.addrExplain :=
            sqlite3VdbeExplainParent(pParse)`, reusing the existing
            offset-312 access into Parse used by ExplainParent.
       [ ] `sqlite3VdbeEnter` / `sqlite3VdbeLeave` — empty bodies.
            In C these are gated on
            `!defined(SQLITE_OMIT_SHARED_CACHE) && SQLITE_THREADSAFE>0`
            and early-out via `DbMaskAllZero(p->lockMask)` in the common
            single-cache case.  Pas port has no shared-cache, so empty
            bodies match the OMIT_SHARED_CACHE compile path; full bodies
            land with the shared-cache port.

       Bytecode virtual table (vdbevtab.c):
       [X] `sqlite3VdbeBytecodeVtabInit` — `return SQLITE_OK` matches
            the C arm at vdbevtab.c:445 when SQLITE_ENABLE_BYTECODE_VTAB
            is not defined.  Pas build does not enable that option;
            register the modules only when it does.

       Resolver (resolve.c):
       [X] `sqlite3ResolveExprListNames` — closed 2026-04-29.  Now walks
            every expression in pList through `sqlite3ResolveExprNames`
            (the Pas resolver entry point) and propagates
            NC_HasAgg|NC_MinMaxAgg|NC_HasWin|NC_OrderAgg flags onto each
            pExpr (EP_Agg/EP_Win) via the same save/clear/restore cycle
            as resolve.c:2191.  Aborts the loop on per-expression error
            and on pParse^.nErr>0.  TestExplainParity 1016/10,
            DiagWindow 17, DiagFeatureProbe 10, DiagPubApi 195/0,
            TestParser 45/0, TestVdbeAgg 11/0, TestSelectBasic 49/0,
            TestWhereBasic 52/0 — no regressions.
       [X] `sqlite3ResolveOrderGroupBy` — closed 2026-04-28.  Real body
            (resolve.c:1700) ported in passqlite3codegen.pas, plus the
            `resolveAlias` / `incrAggFunctionDepth` / `incrAggDepth`
            walker / `resolveOutOfRangeError` helpers it requires.
            iOrderByCol terms now rewrite into deferred-deleted aliases
            of the matching pEList expression; out-of-range terms
            surface "%r ORDER/GROUP BY term out of range" via
            sqlite3MPrintf.  TestExplainParity 1016/10 (no regression),
            TestParser 45/0, TestVdbeAgg 11/0, TestSelectBasic 49/0,
            TestWhereBasic 52/0.

       Foreign keys (fkey.c):
       [X] `sqlite3FkRequired` — DELETE arm ported 2026-04-28
            (codegen.pas).  Checks `db^.flags & SQLITE_ForeignKeys` +
            `pTab^.eTabType = TABTYP_NORM`, returns 1 when
            `sqlite3FkReferences(pTab) <> nil` or `pTab^.u.tab.pFKey <>
            nil`.  UPDATE arm (fkChildIsModified / fkParentIsModified
            walk) deferred — needs full TFKey record (PFKey is still
            `Pointer` at codegen.pas:418).  Safe under current corpus:
            no test enables PRAGMA foreign_keys, and FkCheck/FkActions
            remain no-op stubs so an over-approximation here would not
            emit real enforcement.  TestExplainParity 1016/10,
            TestDMLBasic 54/0, TestSelectBasic 49/0, TestVdbeAgg 11/0,
            TestBtreeCompat 337/0, DiagPubApi 138/0 — no regressions.

       Pragma (pragma.c):
       [ ] `sqlite3PragmaVtabRegister` — returns `nil`; registers
            `pragma_*` eponymous virtual tables via
            `sqlite3VtabCreateModule` + `pragmaVtabModule`.

       Btree mutex (btmutex.c / btree.c) — both gated on `#ifndef NDEBUG`
       and called only inside `assert()`.  Default Pas build is NDEBUG-
       equivalent, so the stubs are never invoked.  Land with the shared-
       cache / debug-assert port:
       [ ] `sqlite3BtreeHoldsAllMutexes` — assert-only helper.
       [ ] `sqlite3BtreeSchemaLocked` — assert-only helper.

- [ ] **6.9-bis 11g.2.b** Port `sqlite3WhereBegin` / `sqlite3WhereEnd` in full.  
    Bookkeeping primitives, prologue,
    cleanup contract, and several leaf helpers (codeCompare cluster,
    sqlite3ExprCanBeNull, sqlite3ExprCodeTemp + 6 unary arms,
    TK_COLLATE/TK_SPAN/TK_UPLUS arms, whereShortCut, allowedOp +
    operatorMask + exprMightBeIndexed + minimal-viable exprAnalyze)
    are already ported.
- [ ] **6.9-bis 11g.2.c** port in full or re-enable `sqlite3Update`
- [ ] **6.9-bis 11g.2.d** port in full or re-enable `sqlite3GenerateConstraintChecks`
- [ ] **6.9-complete** complete the porting of `sqlite3VdbeRecordCompare` and
  `sqlite3VdbeFindCompare` in FULL in `passqlite3btree.pas`.
    - [X] **a)** RHS arms for Real / String / Blob / extra-Null cases
      ported 2026-04-28.  serialGet7 + IntFloatCompare + isAllZero
      helpers added locally in btree.pas to avoid a uses-cycle to
      vdbe.pas.  Real RHS uses sqlite3IntFloatCompare; String / Blob
      RHS use memcmp (BINARY collation only — see (b)).  Verified
      TestExplainParity 1013/13, TestBtreeCompat 337/0, TestVdbeRecord
      13/0, TestVdbeCursor 27/0, TestRowidIn ALL PASS, TestVdbeAgg
      11/0, TestDMLBasic 54/0, TestSelectBasic 49/0, TestWhereBasic
      52/0, TestParser 45/0 — no regressions.
    - [ ] **b)** Collation-aware string compare (vdbeCompareMemString
      hook from btree.pas → vdbe.pas) — required only for non-BINARY
      collated index lookups; current corpus has none.  Defer until
      a test needs it.
    - [ ] **c)** TUnpackedRecord layout reconcile (btree's slim record
      vs. codegen's full record) for errCode/aSortFlags/BIGNULL/DESC
      arms.  Existing slim layout is the lowest common denominator and
      every caller writes through it; no current corpus exercises sort
      flags or corruption flagging.

- [ ] **6.9-bis 11g.2.f** Audit + regression.        
        Note: tests must be run with `LD_LIBRARY_PATH=$PWD/src` so the
        `csq_*` oracle resolves to the project's `src/libsqlite3.so`, not
        the system one.

    - [ ] Port in full `sqlite3Update` body (skeleton-only today;
      blocks DROP TABLE Δ=21 destroyRootPage path and UPDATE rowid=1
      Δ=14).

- [ ] **6.10** `TestExplainParity.pas`
    - [ ] **6.10 step 6** Make these to work (port code when required):
        [ ] `INSERT INTO t VALUES(1,2,3),(4,5,6)` — Δ=11 (multi-row
          VALUES path).  **Runtime impact (verified 2026-04-28 via
          src/tests/DiagMultiValues.pas):** silent data loss — Pas
          inserts only the first row (count=1), C inserts all three
          (count=3).  Stub `sqlite3MultiValues` (codegen.pas:19613)
          drops every pRow past the first; even if the UNION ALL
          fallback were ported, `sqlite3Insert` early-exits when
          `pSelect <> nil` (codegen.pas:19756 TODO) so the coroutine
          path through sqlite3Insert is required too.
        [ ] `SELECT a FROM t ORDER BY a` (asc/desc/multi-col) —
          Δ=16..18 (ORDER BY sorter / ephemeral-key path: Pas emits
          only 3 ops, no sorter open / KeyInfo / sort-finalise loop).
        [ ] `SELECT a FROM t GROUP BY a` — Δ=42 (aggregate-group
          path, not yet ported).
        [ ] `SELECT a FROM (SELECT a FROM t)` — Δ=7 (sub-FROM
          materialise / co-routine path not ported).
          Note 2026-04-28: `sqlite3SrcItemAttachSubquery` (build.c:5019)
          + the subquery branch of `sqlite3SrcListAppendFromTerm`
          (build.c:5102) are now real; the parser no longer drops the
          inner SELECT.  Remaining work: view-expansion arm of
          selectExpander (select.c:6045 IsView path) + sub-FROM
          codegen / co-routine emission in sqlite3Select.
        [ ] `UPDATE t SET a=5 WHERE rowid=1` — Δ=14 (`sqlite3Update`
          still skeleton-only — see 11g.2.f open follow-on).
        [ ] `INSERT INTO u VALUES(1, 2);` (u declared `p PRIMARY KEY,
          q` — non-INTEGER PK, so NOT a rowid alias) — Δ=11.  Diag
          (`src/tests/DiagAutoIdx.pas`) confirms the implicit
          `sqlite_autoindex_u_1` *is* registered at parse time
          (sqlite_schema row, rootpage 5), so the gap is downstream:
          the INSERT codegen does not maintain the autoindex because
          `sqlite3GenerateConstraintChecks` + `sqlite3CompleteInsertion`
          are still stubs (see 6.9-bis 11g.2.b open items).  Closing
          those will close this row.
        [ ] `SELECT p FROM u;` — per-op divergence at op[1]
          (`OpenRead p1=1 p2=5` in C vs `p1=0 p2=4` in Pas).  Same
          fixture: u has the implicit autoindex on `p`.  C planner
          picks the autoindex for a covering scan (rootpage 5);
          Pas planner falls through to the table scan (rootpage 4).
          Root cause: `whereLoopAddBtree` / `bestIndex` cost model
          not yet considering covering indexes when no WHERE clause
          exists.  Distinct from the INSERT row above — needs planner
          work, not insert.c work.
  
  [ ] **6.10 step 7** Runtime divergences surfaced by
      `src/tests/DiagMisc.pas` (run with `LD_LIBRARY_PATH=$PWD/src
      bin/DiagMisc`).  These all prepare+step cleanly on both Pas and C
      (rc=0/101) but produce wrong values, so they are *silent
      result-set bugs* — not bytecode-Δ entries:
      [X] **a) DEFAULT clause ignored by INSERT** — closed.  Ported
        sqlite3AddDefaultValue / ColumnSetExpr / ColumnExpr /
        ExprIsConstantOrFunction; wired sqlite3Insert's missing-
        column arm to consult ColumnExpr instead of OP_Null.
      [X] **b) Hex integer literal decoded as 0** — closed.  Ported
        the hex arm in sqlite3GetInt32.
      [ ] **c) Aggregate-no-GROUP-BY codegen path** — partially closed.
        DiagAggWhere `count(*) FROM t WHERE a IS NULL` now bytecode-
        parity with C (16 ops match exactly).  DiagMoreFunc count/sum
        no-FROM cases also PASS.  Remaining gaps land via the still-
        open INNER-JOIN bloom-filter case (see 6.10 step 9 d-INNER)
        and sub-FROM materialise (step 6 sub-FROM).  C reference:
        select.c analyzeAggregate / generateAggSelect.

  [ ] **6.10 step 9** Runtime divergences surfaced by
      `src/tests/DiagFeatureProbe.pas` (run with `LD_LIBRARY_PATH=$PWD/src
      bin/DiagFeatureProbe`).  Most fold into existing tasks; the genuinely
      new silent-result bugs are listed first.
      [X] **a) COLLATE NOCASE** — closed.  Ported same-encoding arm
        of `sqlite3MemCompare`/`vdbeCompareMemString` so the
        runtime invokes `pColl^.xCmp`.
      [X] **b) Scalar subquery returns 0** — closed.  Accepted
        `SRT_Mem` in the `sqlite3Select` gate + added SRT_Mem
        disposal in selectInnerLoop.
      [ ] **c) View materialisation in SELECT.**
        `SELECT count(*) FROM v` returns no row on Pas.  Foundation
        landed 2026-04-28: ported `sqlite3CreateView` (build.c:2990) so
        CREATE VIEW now stores the duplicated SELECT in
        `pTab^.u.view_pSelect`; ported `viewGetColumnNames`
        (build.c:3087) which runs `sqlite3ResultSetOfSelect` on the
        view's SELECT to compute column names/affinities (honours the
        `CREATE VIEW name(arglist)` arm too via pTable^.pCheck);
        wired the selectExpander view-arm (select.c:6039..6073) so a
        VIEW FROM-item is replaced by `sqlite3SrcItemAttachSubquery
        (..., pTab^.u.view_pSelect, 1)` and recursively expanded.
        Verified: schema row "CREATE view v AS SELECT a FROM t" is
        written and on reload `pTab^.u.view_pSelect` is repopulated;
        `SELECT * FROM v` prepares cleanly.  Remaining gap: the
        agg-no-GROUP-BY gates (codegen.pas:18968 / :19025) reject FROM
        items where `fgBits & SRCITEM_FG_IS_SUBQUERY`, so
        `count(*) FROM v` falls through to the Init/Halt/Goto trivial
        stub.  Closing this needs the sub-FROM materialise / co-routine
        codegen path (6.10 step 6 sub-FROM entry) — same blocker as
        non-view sub-FROM SELECTs.
      [X] **d-LEFT) `LEFT JOIN` aggregate** — closed 2026-04-28.
        DiagFeatureProbe `LEFT JOIN` now PASS (val=2, matches C).
        agg gate at codegen.pas:18979 accepts nSrc=2 and the
        WhereBegin LEFT JOIN nullification arm yields the correct
        row count.
      [X] **d-INNER) `INNER JOIN` aggregate returns count=0 vs C=1**
        — closed 2026-04-28.  Root cause: vdbe.pas had local stubs for
        `sqlite3VdbeRecordCompareWithSkip` / `sqlite3VdbeRecordCompare`
        / `sqlite3VdbeFindCompare` that always returned 0/nil, even
        though btree.pas already had the real bodies.  OP_IdxGT then
        computed `Inc(res) → 1 → jump_to_p2`, skipping OP_AggStep, so
        every join row was dropped.  Fixed by delegating the vdbe.pas
        wrappers to btree.pas's implementations.  DiagInnerJoin val=1,
        DiagFeatureProbe `INNER JOIN` PASS.  Bytecode parity gap
        (missing "BLOOM FILTER ON u" OP_Explain) unchanged and
        cosmetic only.
      [ ] **e) UNION / compound SELECT.**
        `SELECT count(*) FROM (SELECT 1 UNION SELECT 2 UNION SELECT 1)`
        returns no row.  Compound-select codegen / sub-FROM
        materialisation gap (overlaps step 6 sub-FROM Δ=7 entry).
      [ ] **f) WITH / CTE not productive.**
        Both simple (`WITH c(x) AS (SELECT 7) SELECT x FROM c`) and
        recursive forms return no row.  Tracked under 6.20 (CteNew /
        WithAdd stubs blocked on full TCte record).
      [ ] **g) ALTER TABLE no-op.**
        `RENAME COLUMN` and `ADD COLUMN` both prepare+step cleanly but
        do not modify the schema.  Tracked under 6.27.
      [ ] **h) CHECK constraint not enforced.**
        `CREATE TABLE t(a CHECK(a > 0)); INSERT INTO t VALUES(-1)` is
        accepted by Pas; C rejects with SQLITE_CONSTRAINT (rc=19).
        Wraps 6.9-bis 11g.2.b (`sqlite3GenerateConstraintChecks`).
      [X] **i) GENERATED column virtual** — closed 2026-04-29.  Three
        ports landed:
          1. `sqlite3AddGenerated` (codegen.pas) — verbatim port of
             build.c:1971: tags the most recently added column with
             COLFLAG_VIRTUAL (default) or COLFLAG_STORED (explicit
             "stored" type), updates pTab^.tabFlags via
             TF_HasVirtual/TF_HasStored, decrements nNVCol for VIRTUAL,
             wraps bare TK_ID in TK_UPLUS, sets pExpr^.affExpr from the
             column affinity, then binds the AS expression via
             sqlite3ColumnSetExpr.  Was a 1-liner that just deleted
             pExpr.
          2. `sqlite3ExprCodeGeneratedColumn` (codegen.pas) — verbatim
             port of expr.c:4384: emits OP_IfNullRow guard around the
             AS expression when iSelfTab>0, codes the AS expression
             into regOut via sqlite3ExprCode, applies OP_TypeCheck
             (STRICT) or OP_Affinity (>=TEXT) on the result.
          3. `sqlite3ExprCodeGetColumnOfTable` (codegen.pas) — added
             the COLFLAG_VIRTUAL arm (expr.c:4438..4452): under
             COLFLAG_BUSY recursion guard, sets
             pParse^.iSelfTab := iTabCur+1 and dispatches to
             sqlite3ExprCodeGeneratedColumn.
          4. `sqlite3EndTable` (codegen.pas) — added the
             TF_HasGenerated resolve loop (build.c:2753..2780): each
             AS expression is resolved against the new table via
             sqlite3ResolveSelfReference(NC_GenCol); on resolve failure
             the bound expression is replaced with TK_NULL via
             sqlite3ColumnSetExpr; tables with TF_HasGenerated must
             retain at least one non-generated column.
        DiagFeatureProbe `GENERATED column virtual` now PASS (10 → 9
        divergences).  Regressions clean: TestExplainParity 1016/10,
        TestVdbeAgg 11/0, TestSelectBasic 49/0, TestParser 45/0,
        TestBtreeCompat 337/0, TestDMLBasic 54/0, TestVdbeApi 57/0,
        TestWhereBasic 52/0, DiagPubApi 240/0, TestAuthBuiltins 34/0,
        TestCarray 74/0, TestPrintf 105/0, DiagSumOverflow 12/0,
        TestVdbeRecord 13/0, TestVdbeCursor 27/0.  STORED columns + the
        sqlite3ComputeGeneratedColumns post-INSERT dispatch (insert.c
        callsites) remain deferred under 6.24 (only matters when STORED
        is used or when a generated column is read after INSERT before
        commit; VIRTUAL columns route through the SELECT-time path
        landed here).
      [ ] **j) AFTER INSERT trigger does not fire.**
        Side-table populated by the trigger remains empty.  Tracked
        under 6.23 (trigger codegen stubs).
      [ ] **k) `pragma_table_info(...)` table-valued function.**
        `SELECT count(*) FROM pragma_table_info('t')` returns no row.
        Tracked under 6.12 (sqlite3Pragma).

  [ ] **6.10 step 15** Runtime divergences surfaced by the new
      `src/tests/DiagTxn.pas` probe (transactions, savepoints, conflict
      resolution, ROWID/IPK alias edges, BLOB literals, PRAGMA round-trips,
      typeof boundaries, NULL propagation).  Run with
      `LD_LIBRARY_PATH=$PWD/src bin/DiagTxn`.  Initial sweep (~52 cases)
      reported 14 divergences; 1 fixed.  Most remaining fold into already-
      tracked gaps (sqlite3Pragma, sqlite3GenerateConstraintChecks,
      sqlite3Update body).
      [X] **a) `total_changes()` returned 0 after INSERT** — closed.
        sqlite3VdbeHalt now flushes `v^.nChange` to the connection
        when `VDBF_ChangeCntOn` is set.
      [ ] **b) `BEGIN; ...; ROLLBACK` does not roll back changes** —
        DiagTxn `begin rollback insert`: Pas SELECT after rollback errors
        (val=-99999) where C returns 1.  Likely the BEGIN/ROLLBACK
        statements are no-ops on the Pas side (no write-transaction
        bookkeeping in `sqlite3VdbeHalt`); blocked on Phase 5.4 full
        VdbeHalt port.
      [ ] **c) `SAVEPOINT s; ...; ROLLBACK TO s` does not unwind** —
        DiagTxn `savepoint rollback` reports Pas count=2 vs C=1.  Same
        VdbeHalt root cause as (b) plus OP_Savepoint not wired.
      [ ] **d) `INSERT OR IGNORE` / `OR REPLACE` / `OR FAIL` ignore
        conflict resolution** — DiagTxn `insert or ignore unique`,
        `insert or replace unique`, `insert or fail returns err` all
        diverge.  Folds into the existing 6.9-bis 11g.2.b
        `sqlite3GenerateConstraintChecks` gap — the conflict-resolution
        action is encoded in OP_Halt P5 but currently not emitted.
      [ ] **e) IPK alias auto-rowid increment** — DiagTxn `integer
        primary key alias`: `INSERT INTO t(id INTEGER PRIMARY KEY, x)
        VALUES(7,'a'); INSERT VALUES(NULL,'b')` should set id=8 (next
        rowid past max), Pas sets id=2 (sequential).  Same root cause
        as INSERT IPK alias u Δ in TestExplainParity — folds into
        sqlite3GenerateConstraintChecks.
      [ ] **f) `changes()` returns 0 after UPDATE** — DiagTxn
        `changes() after update`.  Folds into `sqlite3Update` body
        skeleton (6.9-bis 11g.2.f); UPDATE never actually fires, so
        nChange stays 0 even with the new VdbeHalt accounting.
      [ ] **g) `journal_mode` PRAGMA** — only remaining DiagTxn pragma
        divergence.  Needs a real OP_JournalMode runtime arm
        (currently 0-returning stub at vdbe.pas:8140) + per-db pager
        journal-mode plumbing.  Other pragmas (application_id,
        user_version, page_size, cache_size, synchronous) closed.
        Full table-driven `pragmaLocate` dispatch still deferred
        under 6.12.

  [ ] **6.10 step 17** Window-function and aggregate divergences surfaced
      by the new `src/tests/DiagWindow.pas` probe (run with
      `LD_LIBRARY_PATH=$PWD/src bin/DiagWindow`).  19 divergences open;
      most fold into existing window/agg tasks.
      [X] **a) `max(val) FROM g` returns `0.0`** — closed 2026-04-28.
        minmaxStep's init branch must use `if pAgg^.flags = 0`, not
        `MEM_Null` flag (sqlite3_aggregate_context zero-inits Mem).
      [X] **a-bis) `sum(int)` integer-overflow silently wraps; `total`
        and `avg` over big ints lose precision** — closed 2026-04-28.
        Reworked TSumAcc to mirror func.c:1846 SumCtx (rSum + rErr Kahan-
        Babushka-Neumaier compensation, iSum, cnt, approx, ovrfl) and
        ported sumStep / sumFinal / totalFinal / avgFinal verbatim from
        func.c:1920..2032; sum() now raises "integer overflow" on i64
        wrap, total/avg switch to compensated double summation.  avg now
        shares the SumCtx accumulator via @sumStep (matches C wiring at
        func.c:3352).  Side fix: vdbemem.c:524 sqlite3VdbeMemFinalize now
        copies the result Mem into pMem unconditionally so the error
        string set by sqlite3_result_error survives back to OP_AggFinal,
        and OP_AggFinal recovers it via sqlite3_value_text(pMem) instead
        of the hard-coded "aggregate finalize error" string.  New gate:
        `src/tests/DiagSumOverflow.pas` (12 cases — empty/happy/overflow/
        mixed/big variants of sum/total/avg, all PASS).  Discovered
        side-issue: sqlite3ErrorWithMsg / sqlite3_errmsg are stubs that
        only record errCode (codegen.pas:25562 + main.pas:1671), so the
        nice "integer overflow" string still surfaces as generic "SQL
        logic error" via sqlite3_errmsg — see new task 8.4.2 below.
      [ ] **b) `group_concat(val, ',' ORDER BY val DESC)` empty** — the
        ORDER-BY-in-aggregate arm is not honoured; the unordered
        variant `group_concat(val,',')` PASSes.  Tracked under 6.24
        (aggregate-with-ORDER-BY codegen) when it lands.
      [ ] **c) Window functions fail at prepare time** —
        `rank()`, `dense_rank()`, `lag()`, `lead()`, `first_value()`,
        `ntile()` with OVER clauses all return prepRc=1.  Folds into
        6.26 `sqlite3WindowCodeInit` / `sqlite3WindowCodeStep` stubs.
      [ ] **d) Window aggregates `sum() OVER ()` / `OVER (ORDER BY)`
        prepare cleanly but emit no rows** — `row_number() OVER (...)`
        same.  Symptom: prep=0 step=101 with empty result set when C
        produces N rows.  Window-codegen sub-issue under 6.26; distinct
        from (c) because here the parse + prepare succeed.
      [X] **e) `count(*) FILTER (WHERE …)` / `sum() FILTER` empty
        result** — closed 2026-04-29.  Three sub-tasks landed:
          1. ResolveExpr (codegen.pas:7505) walks pE^.y.pWin^.pFilter
             when EP_WinFunc is set (mirrors resolve.c:1334).
          2. analyzeAggFuncArgs (codegen.pas) now calls
             sqlite3ExprAnalyzeAggregates on pE^.y.pWin^.pFilter under
             NC_InAggFunc so FILTER's column refs become TK_AGG_COLUMN
             and land in pAggInfo^.aCol[] (mirrors select.c:6534..6535).
          3. Both agg gates (no-FROM at :19030, with-FROM at :19150)
             accept EP_WinFunc when pWin^.eFrmType=TK_FILTER.
             updateAccumulatorSimple now emits the C 6826..6847 arm:
             addrNext := MakeLabel; ExprIfFalse(pFilter, addrNext,
             JUMPIFNULL); ... AggStep ... ResolveLabel(addrNext).
          DiagWindow `count filter` and `sum filter` PASS; total
          divergences 19 → 17.  TestExplainParity 1016/10, TestVdbeAgg
          11/0, TestSelectBasic 49/0, TestWhereBasic 52/0, TestParser
          45/0, TestDMLBasic 54/0, DiagPubApi 189/0 — no regressions.
          Note: the directMode column-emit / nAccumulator>0 pre-pass
          remains deferred (still rejected at :19071/:19261 — not
          required for the count/sum FILTER shapes since the FILTER
          predicate's columns are added to aCol[] AFTER nAccumulator is
          set, leaving nAccumulator at 0 for these cases).
      [X] **f) `count(DISTINCT col)` / `sum(DISTINCT col)` empty
        result** — closed 2026-04-29 (TEXT path closed by 6.10 step 22).  Ported the agg-DISTINCT
        codegen arm: `resetAccumulatorSimple` now opens an OP_OpenEphemeral
        with KeyInfo built from the agg arg-list for each `iDistinct>=0`
        function (mirrors select.c:6671..6685, including the "DISTINCT
        aggregates must have exactly one argument" error).
        `updateAccumulatorSimple` emits the WHERE_DISTINCT_UNORDERED dedup
        before AggStep: `OP_Found(iDistinct, addrNext, regAgg, nArg);
        OP_MakeRecord; OP_IdxInsert + OPFLAG_USESEEKRESULT` (mirrors
        select.c:6902..6908 + codeDistinct default arm).  Lifted the
        `iDistinct>=0` rejection in the agg-with-FROM gate
        (codegen.pas:19312).  DiagWindow `sum distinct` now PASS
        (17→16 divergences).  `count distinct` still DIVERGE because the
        ephemeral b-tree comparison over TEXT keys is broken — see new
        task **6.10 step 22** (`SELECT DISTINCT col` on TEXT/BLOB also
        returns only the first row, so the bug is upstream of the agg
        path).  Regressions clean: TestExplainParity 1016/10, TestVdbeAgg
        11/0, TestSelectBasic 49/0, TestParser 45/0, TestBtreeCompat
        337/0, TestDMLBasic 54/0, TestVdbeApi 57/0, TestWhereBasic 52/0,
        DiagPubApi 240/0, DiagSumOverflow 12/0, TestAuthBuiltins 34/0,
        TestCarray 74/0, TestPrintf 105/0.
      [ ] **g) `GROUP BY ... HAVING ...` returns no rows** —
        DiagWindow `group having`: HAVING clause filtering on aggregate
        result not emitted.
      [ ] **h) `GROUP BY ... ORDER BY ... DESC` returns no rows** —
        DiagWindow `group order`: GROUP BY combined with ORDER BY drops
        rows.  Likely shares root cause with (g) — agg-with-trailing-
        clauses gate at codegen.pas:18968.

  [X] **6.10 step 20** Host-parameter binding via `?` / `?N` / `:name` /
      `@name` / `$name` closed 2026-04-28.  Root cause: `sqlite3VdbeMakeReady`
      (vdbe.pas) read `pParse^.nVar` but never propagated it to `p^.nVar`
      nor allocated `p^.aVar[]`, so `OP_Variable` dereferenced nil and
      `sqlite3_bind_*` early-exited with SQLITE_RANGE.  Fix: add the
      vdbeaux.c:2714/2737-2738 arms (allocate aVar, set p^.nVar, init each
      slot to MEM_Null with db backref).  DiagPubApi now covers `SELECT ?`
      and `SELECT :a + :b` round-trips.  Released the deferred follow-on
      from the 8.3.1 sqlite3_bind_zeroblob entry.

  [X] **6.10 step 21** DiagPrintfFmt probe (added 2026-04-29,
      `src/tests/DiagPrintfFmt.pas`).  Covers SQL `printf()` /`format()`
      format-specifier coverage — 38 cases.  Initial sweep flagged 10
      divergences against the C reference; 8 closed in the same commit
      by extending `printfFunc` (codegen.pas:28080) — alt-form `#` for
      `%x`/`%X`/`%o` (prepends `0x`/`0X`/`0`), precision-pad-with-zeros
      for `%d`/`%i`/`%u` (e.g. `%.5d`→`00042`), star width/precision
      (`%*d` / `%.*f` consume an i32 argv), and consume-and-ignore for
      C length modifiers `l`/`ll`/`L`/`h`/`hh`/`j`/`z`/`t` (so `%lld`,
      `%llx` etc. now route to the `d`/`x` arms instead of being
      emitted verbatim).  TestPrintf 105/0, DiagFunctions 0,
      TestExplainParity 1016/10, DiagPubApi 240/0 — no regressions.
      Remaining 2 divergences closed 2026-04-29 by porting a proper
      `%g`/`%G` (etGENERIC) renderer in printfFunc (codegen.pas):
      default precision 6, switch to scientific when exp<-4 or
      exp>=precision, strip trailing zeros (and trailing '.') unless
      `#` alt-form is set.  `%!g` resolves as a side-effect — the C
      etGENERIC arm gates rtz on `#` (flag_alternateform), not on `!`
      (flag_altform2), so once rtz is honoured `%!g` matches.
      DiagPrintfFmt 38/0; TestPrintf 105/0, TestExplainParity 1016/10,
      TestVdbeAgg 11/0, TestSelectBasic 49/0, TestParser 45/0,
      TestBtreeCompat 337/0, TestDMLBasic 54/0, TestVdbeApi 57/0,
      TestAuthBuiltins 34/0 — no regressions.

  [X] **6.10 step 18** TestAuthBuiltins 34/0 closed 2026-04-28 — guard
      each `sqlite3Register*Functions` (Builtin/DateTime/Json/Window)
      with a one-shot `done` flag so re-entry doesn't FillChar
      module-static TFuncDef arrays and orphan bucket-chain links.

  [ ] **6.10 step 19** DiagDml runtime probe (added 2026-04-28,
      `src/tests/DiagDml.pas`, run `LD_LIBRARY_PATH=$PWD/src bin/DiagDml`).
      Sweep of UPSERT / RETURNING / INSERT-FROM-SELECT / UPDATE-FROM /
      column-reorder / DEFAULT-expr / multi-row-VALUES variants.  12 PASS,
      2 DIVERGE — surprises noted below; UPSERT (DO NOTHING + DO UPDATE +
      excluded.b), RETURNING (INSERT/UPDATE/DELETE), INSERT INTO d SELECT
      * FROM s, UPDATE...FROM, column-reorder all already PASS.
      [ ] **a) `INSERT INTO t SELECT 1,2 UNION ALL SELECT 3,4`** —
        Pas inserts 0 rows, C inserts 2.  Compound-SELECT-as-INSERT-source
        gap; folds into 6.10 step 6 (sqlite3Insert pSelect early-exit at
        codegen.pas:19756) + step 9(e) (compound-SELECT codegen).
      [ ] **b) Multi-row VALUES with non-constant exprs** —
        `INSERT INTO t VALUES(1,1+1),(2,2*2),(3,3+3)`: Pas count=1,
        C count=3.  Distinct from the constant variant logged in
        step 6 because non-constant rows force the C UNION-ALL fallback
        path in `sqlite3MultiValues` (insert.c:679 condition (c)) — the
        coroutine path is bypassed.  Closing requires the UNION-ALL arm of
        `sqlite3MultiValues` (codegen.pas:21268) plus sqlite3Insert pSelect
        path (same codegen.pas:19756 TODO).

  [X] **6.10 step 22** Ephemeral b-tree dedup over TEXT/BLOB keys —
      closed 2026-04-29.  Root cause: `sqlite3VdbeRecordCompare`
      (btree.pas) re-decoded `serial_type` inside the BT_MEM_Str /
      BT_MEM_Blob arms by calling `sqlite3GetVarint32(@aKey1[idx1], ...)`
      unconditionally, but that helper requires the high bit of p[0] to
      be set (multi-byte varint precondition documented at util.pas:1601).
      For a 1-byte TEXT serial type 0x0F it read p[0..1] and produced
      `(0x0F<<7) | next_byte` (= 1985 for "A"), so every comparison
      returned <0 / >0 inconsistently and the cursor's last-cell skip-to-
      root optimisation latched on the first inserted row, making every
      subsequent OP_Found report `seekResult=0` ("found").  Fix: drop the
      redundant re-read; `serial_type` is already correctly decoded at
      the top of the loop using the inline `aKey1[idx1] < $80` guard,
      which is what the C reference (vdbeaux.c:4839 / 4872) does too.
      DiagWindow `count distinct` now PASS (16→15 divergences).
      Regressions clean: TestExplainParity 1016/10, TestBtreeCompat
      337/0, TestVdbeAgg 11/0, TestVdbeRecord 13/0, TestSelectBasic
      49/0, TestVdbeApi 57/0, TestParser 45/0, TestDMLBasic 54/0,
      TestWhereBasic 52/0, TestPrintf 105/0, TestAuthBuiltins 34/0,
      TestCarray 74/0, TestVdbeCursor 27/0, TestRowidIn ALL PASS,
      TestPager/PagerRollback/WalCompat ALL PASS, DiagPubApi 240/0,
      DiagSumOverflow 12/0, DiagFunctions/Cast/Date/Printf 0/0.

  [X] **6.10 step 23** absFunc error-message parity — closed 2026-04-29.
      `SELECT abs(-9223372036854775808)` now raises the canonical
      "integer overflow" message (func.c:205) instead of the bespoke
      "-9223372036854775808 is not representable…" wording, so
      `sqlite3_errmsg` now matches C verbatim.  TestExplainParity
      1016/10, DiagFunctions/SumOverflow/Misc/Ops/PubApi/ErrMsg —
      no regressions.

  [X] **6.10 step 24** Scalar built-in parity sweep — closed 2026-04-29.
      New gate `src/tests/DiagScalarFunc.pas` (run with
      `LD_LIBRARY_PATH=$PWD/src bin/DiagScalarFunc`) — ~85 cases over
      printf %q/%Q/%w, format(), iif/nullif/coalesce, substr/substring,
      trim/ltrim/rtrim with custom char-list, replace/instr edges,
      hex/unhex/char/unicode, abs INT64 boundary, round precision,
      randomblob/zeroblob, quote, LIKE/GLOB classes, json_*, date()
      julianday arg, arithmetic edges.  Initial sweep flagged 3
      divergences, all closed:
        1. `unicode('')` returned 0 (INTEGER) — Pas now matches C
           NULL-on-empty (func.c:1284 `if( z && z[0] )`).
        2. `unhex(zHex, zIgnore)` 2-arg form was missing — registered
           the 2-arg variant (func.c:3328) and ported the full body
           with the `zIgnore`-codepoint allow-between-pairs arm
           (func.c:1396..1447) plus a strContainsChar helper.
        3. `date(2440587.5)` (Julian-Day numeric arg) returned NULL —
           parseDateTime now falls back to sqlite3AtoF + fromJulianDay
           when the input is a bare number (date.c:parseDateOrTime
           AtoF arm).  Same fix lifts time()/datetime()/strftime() for
           numeric JD inputs.
      Regressions clean: DiagFunctions/Date/Misc/SumOverflow/PubApi/
      PrintfFmt/FeatureProbe baselines unchanged; TestExplainParity
      1016/10, TestVdbeAgg 11/0, TestSelectBasic 49/0, TestParser
      45/0, TestBtreeCompat 337/0, TestDMLBasic 54/0, TestVdbeApi
      57/0, TestWhereBasic 52/0, TestPrintf 105/0, TestAuthBuiltins
      34/0, TestCarray 74/0, TestVdbeRecord 13/0.

  [ ] **6.11** DROP TABLE remaining gap (current Δ=26, was Δ=21):
    (a) [X] ONEPASS_MULTI promotion landed in sqlite3WhereBegin,
        the sqlite_schema scrub now uses one-pass inline delete.
    (b) [ ] Pas elides the destroyRootPage autovacuum follow-on (~26 ops)
        because `destroyRootPage` calls `sqlite3NestedParse(UPDATE
        sqlite_schema ...)` and productive `sqlite3Update` is still
        skeleton-only.  This is the only remaining contributor.
  [ ] **6.12** port sqlite3Pragma in full.  Regression gate
       `src/tests/DiagPragma.pas` (run with
       `LD_LIBRARY_PATH=$PWD/src bin/DiagPragma`).  Baseline 49 DIVERGE
       driven to 13 DIVERGE.  Existing PragTyp_FLAG arm (17 boolean
       pragmas: foreign_keys, recursive_triggers,
       reverse_unordered_selects, defer_foreign_keys, writable_schema,
       legacy_alter_table, cell_size_check, automatic_index,
       full_column_names, short_column_names, checkpoint_fullfsync,
       fullfsync, ignore_check_constraints, query_only, trusted_schema,
       count_changes, read_uncommitted, empty_result_callbacks); plus
       default-value dispatch for read-only pragmas (secure_delete=0,
       temp_store=0, threads=0, soft_heap_limit=0, hard_heap_limit=0,
       busy_timeout=0, analysis_limit=0, wal_autocheckpoint=1000,
       journal_size_limit=-1, auto_vacuum=0, freelist_count=0,
       schema_version=0, max_page_count via OP_MaxPgcnt) plus
       journal_mode='memory', locking_mode='normal'; data_version
       extension of the PragTyp_HEADER_VALUE arm landed 2026-04-29
       (BTREE_DATA_VERSION=15 read-only via OP_ReadCookie; writes
       silently no-op per the C ReadOnly flag).  SQLITE_CountRows/
       ReadUncommit HI() constants added to util.pas (HI(0x1)/HI(0x4)).
       Remaining divergences (13): table-valued pragma_* introspection
       functions (table_info, table_xinfo, index_list, foreign_key_list,
       database_list, collation_list, function_list, module_list,
       pragma_list, compile_options), integrity_check / quick_check,
       cache_spill.
  [ ] **6.13** port sqlite3Vacuum in full
  [X] **6.14** port sqlite3WhereTabFuncArgs in full (whereexpr.c:1899..1944).
  [X] **6.15** port sqlite3WhereAddLimit + whereAddLimitExpr in full
       (whereexpr.c:1620..1736).
  [X] **6.16** port btree.pas stubs in full: `ptrmapPutOvflPtr`,
       `invalidateIncrblobCursors`.
  [X] **6.17** port pager.pas stubs in full: `pager_reset`,
       `pagerReleaseMapPage`, `sqlite3_log`.
  [X] **6.18** port wal.pas stub `sqlite3_log_wal` in full.
  [X] **6.19** port util.pas stubs `sqlite3_mprintf` / `sqlite3_snprintf`
       in full.
  [ ] **6.20** port remaining parser.pas stubs in full:
  [ ] **6.21** port vdbe.pas stubs in full from C to pascal:
       `sqlite3VdbeMultiLoad` (blocked: only used by pragma.c and
       requires va_list — defer until 6.12 sqlite3Pragma lands),
       `sqlite3VdbeDisplayComment` (blocked: needs opcode-synopsis
       tables appended after each name in sqlite3OpcodeName — Pas
       OpcodeNames table is plain names only, defer),
       `sqlite3VdbeList`, `sqlite3_blob_open`.
  [ ] **6.22** port codegen.pas rename / error-offset stubs in full from C
       to pascal:
       [ ] `sqlite3RenameExprUnmap`, `sqlite3RenameTokenMap` — only
            productive under `PARSE_MODE_RENAME`.  Full bodies
            (`RenameToken` record + walker callbacks) deferred to land
            with `sqlite3AlterRenameTable` / `sqlite3AlterRenameColumn`
            in 6.27; current no-op matches C semantics whenever the
            parser is not in rename mode.
  [ ] **6.23** port codegen.pas trigger stubs in full from C to pascal:
       `sqlite3TriggerList`, `sqlite3BeginTrigger`, `sqlite3FinishTrigger`,
       `sqlite3DropTrigger`, `sqlite3DropTriggerPtr`,
       `sqlite3UnlinkAndDeleteTrigger`, `sqlite3TriggersExist`,
       `sqlite3CodeRowTriggerDirect`, `sqlite3CodeRowTrigger`,
       `sqlite3TriggerStepSrc`, `sqlite3TriggerColmask`.
  [ ] **6.24** port codegen.pas DML / insert stubs in full from C to pascal:
       `sqlite3UpsertAnalyzeTarget`, `sqlite3UpsertDoUpdate`,
       `sqlite3ComputeGeneratedColumns`, `sqlite3AutoincrementBegin`,
       `sqlite3AutoincrementEnd`, `sqlite3MultiValuesEnd`,
       `sqlite3MultiValues`, `autoIncBegin`,
       `sqlite3GenerateConstraintChecks`.
  [ ] **6.25** port codegen.pas schema / index stubs in full from C to pascal:
       `sqlite3ReadSchema`, `sqlite3RunParser`.
  [ ] **6.26** port codegen.pas where / select / window stubs in full from C
       to pascal: `sqlite3WhereExplainBloomFilter`,
       `sqlite3WhereAddExplainText`, `sqlite3WindowCodeInit`,
       `sqlite3WindowCodeStep`.
  [ ] **6.27** port codegen.pas alter / attach / analyze / vacuum / FK /
       extension / scalar-function stubs in full from C to pascal:
       `sqlite3AlterRenameTable`, `sqlite3AlterFinishAddColumn`,
       `sqlite3AlterAddConstraint`, `sqlite3Detach`, `sqlite3Attach`,
       `sqlite3Analyze`, `sqlite3Vacuum`,
       `sqlite3FkCheck`, `sqlite3FkActions`.
  [X] **6.27a** `sqlite3AddCollateType` ported 2026-04-28 from
       build.c:1938 (passqlite3codegen.pas).  Calls sqlite3LocateCollSeq
       to validate the name, then sqlite3ColumnSetColl to pack the
       collation into pCol^.zCnName + set COLFLAG_HASCOLL; also rewrites
       azColl[0] of any single-key Index already attached to this column
       (PRIMARY KEY COLLATE ordering arm).  IN_RENAME_OBJECT short-circuit
       preserved.  DiagPubApi `metadata b coll=NOCASE` now PASS (was
       BINARY); TestExplainParity 1016/10, TestVdbeAgg 11/0,
       TestSelectBasic 49/0, TestWhereBasic 52/0, TestBtreeCompat 337/0,
       TestVdbeRecord 13/0, TestParser 45/0 — no regressions.
  [ ] **6.28** sweep — re-search for "stub" in the pascal source code and
       port from C to pascal in full any function or procedure still
       marked as "stub" that was missed by 6.16..6.27 (catch-all).
---

## Phase 7 — Parser (one gate open)

- [ ] **7.1.1** Schema initialisation (prepare.c).  Currently
       `sqlite3ReadSchema` (codegen.pas:21928) returns `SQLITE_OK`
       without reading anything; tests pre-populate the schema.  Port
       in full:
       [ ] `sqlite3ReadSchema` — drive the schema-load query.
       [ ] `sqlite3Init` / `sqlite3InitOne` (prepare.c) — read each
            sqlite_master row and parse its CREATE statement via
            `sqlite3NestedParse`.
       [ ] `sqlite3InitCallback` (main.pas:2063) — currently installs
            only system tables; full body parses each schema row.
       [ ] `schemaIsValid` / `sqlite3SchemaToIndex` plumbing.

- [ ] **7.1.2** `sqlite3NestedParse` full driver (build.c).  The
       current skeleton (codegen.pas:25041) early-exits when
       `zFormat=nil`; printf-formatted call sites for DROP/UPDATE
       sqlite_master are still wired with `nil`.  Required for:
       DROP TABLE autovacuum follow-on (current Δ=26 — see 6.11), the
       CREATE TABLE schema-row INSERT, and the destroyRootPage
       UPDATE sqlite_master path.  Closes the last contributor of
       6.11(b).

- [ ] **7.1.3** Statement re-prepare / SQL plumbing (vdbeaux.c,
       prepare.c):
       [X] `sqlite3VdbeSetSql` — real body in vdbe.pas:3787 (writes
            `prepFlags`/`expmask`/`zSql`); the codegen.pas:25433
            duplicate is dead and shadowed by the vdbe.pas version that
            main.pas:802 actually calls (u8-cast confirms the dispatch).
       [X] `sqlite3Reprepare` — ported 2026-04-28 (passqlite3main.pas)
            — verbatim port of prepare.c:886; relies on sqlite3LockAndPrepare
            + sqlite3VdbeSwap + sqlite3TransferBindings + VdbeResetStepResult
            + VdbeFinalize.  Codegen forward decl + stub body removed.
            Build clean; TestExplainParity 1016/10, DiagPubApi 138/0 — no
            regressions.  Not currently called by any prepared-step path
            (sqlite3_step still re-runs without auto-reprepare on
            SQLITE_SCHEMA), so runtime behaviour unchanged.
       [X] `sqlite3TransferBindings` — ported 2026-04-28 (codegen.pas)
            — verbatim port of vdbeapi.c:1964; aVar[] entries moved via
            sqlite3VdbeMemMove with same-db / matching-nVar asserts.
       [X] `sqlite3VdbeResetStepResult` — real body in vdbe.pas:3493
            (resets `p^.rc`).  The codegen.pas:25449 duplicate that
            also clears `pc:=-1` is dead.
       [X] `sqlite3_prepare16` / `sqlite3_prepare16_v2` /
            `sqlite3_prepare16_v3` — ported 2026-04-29 (passqlite3main.pas)
            — verbatim port of prepare.c:983/1053/1065/1077.  Local
            `utf16ByteLenForChars` mirrors C's `sqlite3Utf16ByteLen`
            (UTF-16LE, surrogate-aware) so *pzTail correctly tracks the
            consumed UTF-16 byte offset.  Dead codegen.pas stubs removed.
            Smoke-verified end-to-end: `SELECT 42;` UTF-16 prepare → step
            yields col0=42, tail offset = 20 bytes (10 chars × 2).
            MISUSE on nil zSql / nil ppStmt.  No regressions:
            TestExplainParity 1016/10, DiagPubApi 231/0, TestVdbeApi
            57/0, TestParser 45/0, TestSelectBasic 49/0, TestVdbeAgg
            11/0, TestBtreeCompat 337/0, TestDMLBasic 54/0, TestPrintf
            105/0, TestAuthBuiltins 34/0, TestCarray 74/0,
            DiagSumOverflow 12/0.

- [X] **7.1.4** DbFixer — closed 2026-04-29.  Verbatim port of attach.c:457..621
       in passqlite3codegen.pas: `fixExprCb` tags every Expr with EP_FromDDL
       (when not in TEMP) and rejects bound parameters; `fixSelectCb` walks
       SrcList items, binds each non-subquery item to pFix^.pSchema, and
       reports `<type> <name> cannot reference objects in database <db>` when
       the original SQL named a different schema.  TDbFixer record extended
       to carry the embedded TWalker + bTemp; TWalkerU gained a pFix slot.
       Wired through the existing CREATE VIEW (codegen.pas:23985) and CREATE
       INDEX (codegen.pas:24607) call sites.  No regressions:
       TestExplainParity 1016/10, TestParser 45/0, TestVdbeApi 57/0,
       TestSelectBasic 49/0, TestVdbeAgg 11/0, TestBtreeCompat 337/0,
       TestDMLBasic 54/0, TestWhereBasic 52/0, TestCarray 74/0,
       TestPrintf 105/0, TestAuthBuiltins 34/0, DiagPubApi 240/0,
       DiagFeatureProbe 9, DiagWindow 15, DiagSumOverflow 12/0.

- [ ] **7.1.7** Lemon parser tail (parse.c epilogue) — gaps inside
       `passqlite3parser.pas`:
       [X] `sqlite3ParserFallback` — done; uses `yyFallbackTab`
            (parsertables.inc:703).  Original "stubbed as 0" comment
            block at parser.pas:1070 is stale; real body at parser.pas:4261.
       [X] `yy_accept` / `yy_parse_failed` / `yy_syntax_error` — done;
            bodies match C parse.c:6019/6042/6068 (the %parse_accept and
            %parse_failure blocks are empty in parse.y, so the Pas empty
            bodies are correct; %syntax_error mirrors `parserSyntaxError`).
       [ ] Per-rule reduce actions (Phase 7.2e) — several rule arms
            still TODO and gated on the codegen Phase 7 stubs
            (NestedParse, BeginWriteOperation, FK actions, etc.).
       [ ] `sqlite3RenameToken` / `sqlite3RenameTokenMap` /
            `sqlite3RenameExprUnmap` — needed for `PARSE_MODE_RENAME`
            (currently no-ops; OK in normal mode).

- [ ] **7.1.8** ATTACH / DETACH (attach.c) — currently Phase 7 stubs
       at codegen.pas:25213/25218.  Must open the attached btree,
       allocate `aDb[]` slot, run schema load.  (Overlaps 6.27 — move
       here when ported.)

- [ ] **7.1.9** ALTER TABLE (alter.c) — Full port from C to pascal:
       [ ] `sqlite3AlterRenameTable`, `sqlite3AlterRenameColumn`.
       [ ] `sqlite3AlterDropColumn`, `sqlite3AlterDropConstraint`.
       [ ] `sqlite3AlterSetNotNull`, `sqlite3AlterAddConstraint`.
       [ ] `sqlite3AlterBeginAddColumn`, `sqlite3AlterFinishAddColumn`.
       [ ] `sqlite3AlterFunctions` — registers the rename-helper SQL
            functions.
       [ ] `sqlite3RenameTokenRemap`, `sqlite3RenameExprlistUnmap`.
       (Overlaps 6.22 / 6.27 — move here when ported.)

- [ ] **7.4b** Bytecode-diff scope of `TestParser.pas`.  Now that
  Phase 8.2 wires `sqlite3_prepare_v2` end-to-end, extend `TestParser`
  to dump and diff the resulting VDBE program (opcode + p1 + p2 + p3
  + p4 + p5) byte-for-byte against `csq_prepare_v2`.  Reuses the 
  corpus plus the SELECT / pragma / explain / commit / rollback /
  analyze / vacuum / reindex statements.

- [ ] **7.4c** `TestVdbeTrace.pas` differential opcode-trace gate.
  Needs SQL → VDBE end-to-end
  through the Pascal pipeline so per-opcode traces can be diffed
  against the C reference under `PRAGMA vdbe_trace=ON`.

---

## Phase 8 — Public API (one gate open)

Public-API gap analysis 2026-04-28: `../sqlite3/src/sqlite.h.in` exports
~238 `sqlite3_*` symbols; the Pascal port currently exposes ~156.  The
items below enumerate every missing symbol grouped by sub-phase.
Windows-only entry points (`sqlite3_win32_*`) and pure typedefs
(`sqlite3_int64`, `sqlite3_uint64`, opaque struct names) are excluded.

- [ ] **8.1.1** Connection-lifecycle gaps (main.c):
       [X] `sqlite3_open16` — ported 2026-04-29 (passqlite3main.pas) —
            verbatim port of main.c:3706.  Wraps the UTF-16NATIVE
            filename in a sqlite3_value, transcodes via
            sqlite3ValueText(UTF8), forwards to openDatabase
            (READWRITE|CREATE).  When the open succeeds and the schema
            has not been loaded yet, sets db^.aDb[0].pSchema^.enc and
            db^.enc to SQLITE_UTF16NATIVE so subsequent prepares produce
            UTF-16.  csq_open16 binding added; DiagPubApi 163/0
            (was 156/0 — 7 new checks: :memory: OK + non-nil db +
            enc=UTF16LE + csq_open16 round-trip + nil-filename +
            nil-ppDb MISUSE).  TestExplainParity 1016/10 — no regression.
       [X] `sqlite3_db_readonly` (main.c:5001) — ported 2026-04-28
            (passqlite3main.pas) via sqlite3FindDbName + sqlite3BtreeIsReadonly.
       [X] `sqlite3_db_release_memory` (main.c:897) — ported 2026-04-28
            (passqlite3main.pas) — sqlite3BtreeEnterAll + per-db
            sqlite3PagerShrink loop; pager.pas wrapper added.
       [X] `sqlite3_db_status` / `sqlite3_db_status64` (status.c) — ported
            2026-04-29 (passqlite3main.pas) — verbatim port of status.c:188
            (sqlite3LookasideUsed) + status.c:203 (sqlite3_db_status64) +
            status.c:426 (sqlite3_db_status).  Verbs implemented:
            LOOKASIDE_USED (with reset arm), LOOKASIDE_HIT/MISS_SIZE/MISS_FULL,
            CACHE_USED, CACHE_USED_SHARED (no shared-cache → equiv to CACHE_USED),
            CACHE_HIT/MISS/WRITE/SPILL via sqlite3PagerCacheStat, TEMPBUF_SPILL
            via aDb[1] pager + db^.nSpill, DEFERRED_FKS via nDeferredImmCons /
            nDeferredCons.  SCHEMA_USED and STMT_USED return SQLITE_ERROR
            (require pnBytesFreed accounting plumbing through sqlite3DbFree
            — not yet wired).  SQLITE_DBSTATUS_* constants moved from impl
            to interface section of passqlite3pager.pas so callers can name
            the verbs.  csq_db_status binding added; DiagPubApi extended
            with 13 new cases (nil/bad-op/MISUSE guards, LOOKASIDE_USED /
            DEFERRED_FKS / CACHE_USED / CACHE_HIT happy-path round-trips,
            64-bit variant); 254/0.  TestExplainParity 1016/10, TestVdbeApi
            57/0, TestBtreeCompat 337/0, TestSelectBasic 49/0, TestParser
            45/0, TestVdbeAgg 11/0, TestDMLBasic 54/0, TestWhereBasic 52/0,
            TestAuthBuiltins 34/0, TestPrintf 105/0 — no regressions.
       [X] `sqlite3_db_cacheflush` (main.c:921) — ported 2026-04-28
            (passqlite3main.pas) — flushes dirty pages on every db with
            an open write txn; folds SQLITE_BUSY into a single trailing
            return as in the C body.
       [ ] `sqlite3_db_config` — raw varargs entry point (currently only
            typed wrappers `_text`/`_lookaside`/`_int` exist).
       [X] `sqlite3_filename_database` / `_journal` / `_wal` /
            `sqlite3_free_filename` / `sqlite3_uri_key` — ported
            2026-04-28 (passqlite3util.pas) — verbatim ports of
            main.c:4857..4953; reuse existing databaseName +
            sqlite3Strlen30 helpers.  Runtime smoke deferred until
            `sqlite3_create_filename` lands (no buffer producer yet).
       [X] `sqlite3_set_clientdata` / `sqlite3_get_clientdata` — ported
            2026-04-29 (passqlite3main.pas) — verbatim port of
            main.c:3854/3877.  Allocates each `DbClientData` node via
            `sqlite3_malloc64` with the C-string name appended after the
            struct (mirrors C's flexible `zName[]`).  Replace fires the
            old destructor before installing the new value; clear unlinks
            the node and frees it.  `sqlite3Close` now walks `db^.pDbData`
            firing each `xDestructor` and freeing the node before the
            connection transitions to ZOMBIE.  Local
            `clientNameEq`/`clientNameLen` helpers avoid pulling SysUtils
            into main.pas.  DiagPubApi extended with 19 cases:
            install/get/replace/clear, multi-key isolation, nil-name guard,
            destructor-on-replace fires once, destructor-on-close fires
            for all installed slots.  TestExplainParity 1016/10,
            TestVdbeApi 57/0, TestParser 45/0, TestSelectBasic 49/0,
            TestWhereBasic 52/0, TestBtreeCompat 337/0, TestDMLBasic 54/0,
            TestVdbeAgg 11/0, TestAuthBuiltins 34/0, TestCarray 74/0 — no
            regressions.

- [ ] **8.2.1** Statement-introspection gaps (vdbeapi.c):
       [X] `sqlite3_stmt_busy` (vdbeapi.c) — ported 2026-04-28
            (passqlite3main.pas) — `v <> nil and eVdbeState =
            VDBE_RUN_STATE`.
       [X] `sqlite3_stmt_explain` — ported 2026-04-28 (passqlite3main.pas)
            — verbatim port of vdbeapi.c:2038.  Decodes/encodes the
            2-bit explain field via VDBF_EXPLAIN_MASK; no-reprepare
            fast path when v^.nMem >= 10 and (eMode<>2 or
            VDBF_HaveEqpOps already set); reprepare fall-through via
            sqlite3Reprepare; nResColumn adjusted to 12-4*explain on
            EXPLAIN modes, restored to nResAlloc on mode 0.  Misuse
            (nil pStmt → MISUSE) and bad-mode (eMode<0/>2 → ERROR)
            covered by DiagPubApi.
       [X] `sqlite3_stmt_status` — ported 2026-04-29 (passqlite3main.pas)
            — verbatim port of vdbeapi.c:2106.  Returns v^.aCounter[op]
            and optionally clears it; SQLITE_STMTSTATUS_MEMUSED runs
            sqlite3VdbeDelete with db^.pnBytesFreed pointing at a local
            counter (lookaside^.pEnd lowered to pStart for the duration)
            so freed bytes accumulate into the result.  API-armor guards:
            nil pStmt or out-of-range op => 0.  DiagPubApi extended with
            9 cases (nil/bad-op guards, RUN/VM_STEP increment after step,
            reset semantics); 240/0.  TestExplainParity 1016/10,
            TestVdbeApi 57/0, TestParser 45/0 — no regressions.
       [ ] `sqlite3_stmt_scanstatus` / `_scanstatus_v2` /
            `_scanstatus_reset` — gated on the 6.8
            `sqlite3VdbeScanStatus*` arms landing first.

- [ ] **8.3.1** Bind variants (vdbeapi.c):
       [X] `sqlite3_bind_blob64` / `sqlite3_bind_text64` /
            `sqlite3_bind_text16` — ported 2026-04-28 (passqlite3vdbe.pas)
            mirroring the C bindText helper at vdbeapi.c:1696.  blob64
            takes a u64 length and routes to sqlite3VdbeMemSetStr with
            enc=0; text64 maps SQLITE_UTF16 → SQLITE_UTF16NATIVE and
            masks nData to even for non-UTF8 encodings before delegating
            to MemSetText/MemSetStr + ChangeEncoding to the connection
            encoding; text16 inlines the n & ~1 mask plus
            SQLITE_UTF16NATIVE delegation.  Misuse + round-trip covered
            by DiagPubApi (156/0).  TestExplainParity 1016/10 — no
            regression.
       [X] `sqlite3_bind_zeroblob` / `_zeroblob64` — ported 2026-04-28
            (passqlite3vdbe.pas) — vdbeUnbind55 + sqlite3VdbeMemSetZeroBlob;
            64-bit variant gates on aLimit[LIMIT_LENGTH] for SQLITE_TOOBIG.
            Misuse paths covered by DiagPubApi (nil → MISUSE, no-params
            stmt → RANGE, over-LENGTH → TOOBIG).  Round-trip via prepared
            statement closed 2026-04-28 — see "host-parameter binding"
            below.
       [X] `sqlite3_bind_pointer` — ported 2026-04-28
            (passqlite3vdbe.pas) — vdbeUnbind55 + sqlite3VdbeMemSetPointer;
            mirrors C destructor-on-error contract.  Replaces the
            sqlite3_value_pointer_stub in passqlite3carray.pas; carray
            xFilter now consults the real typed-pointer Mem.
       [X] `sqlite3_bind_parameter_index` / `sqlite3_bind_parameter_name`
            — ported 2026-04-28 (passqlite3vdbe.pas + util.pas).  Added
            full util.c VList machinery (sqlite3VListAdd /
            VListNumToName / VListNameToNum), wired
            `sqlite3ExprAssignVarNumber` to maintain `pParse^.pVList`
            with named-bind dedup, transferred Parse→Vdbe in
            `sqlite3VdbeMakeReady` and freed in `sqlite3VdbeClearObject`.
            DiagPubApi covers round-trip, `:x+:x` dedup (1 slot, value
            10), `?` returns nil name, out-of-range/nil-stmt guards.
            Side-effect: TestExplainParity 1013/13 → 1016/10 (3 prior
            divergences resolved by correct named-bind slot reuse).

- [ ] **8.3.2** Result / value variants (vdbeapi.c, vdbemem.c):
       [X] `sqlite3_result_blob64` — ported 2026-04-28 (passqlite3vdbe.pas).
            Mirrors existing `sqlite3_result_text64` shape: u64 length,
            n>0x7FFFFFFF routes to `sqlite3_result_error_toobig`,
            otherwise delegates to `sqlite3VdbeMemSetStr` with enc=0.
       [X] `sqlite3_result_text16` / `_text16be` / `_text16le` — ported
            2026-04-28 (passqlite3vdbe.pas) — verbatim port of
            vdbeapi.c:616/625/634; n masked with `not i64(1)` per the C
            `n & ~(u64)1` arm before delegating to sqlite3VdbeMemSetStr
            with SQLITE_UTF16NATIVE / SQLITE_UTF16BE / SQLITE_UTF16LE
            respectively.
       [X] `sqlite3_result_error16` — ported 2026-04-28
            (passqlite3vdbe.pas) — sets isError=SQLITE_ERROR and stores
            the UTF-16NATIVE message via sqlite3VdbeMemSetStr (mirrors
            vdbeapi.c:503).
       [X] `sqlite3_result_error_code` — ported 2026-04-28
            (passqlite3vdbe.pas) — sets `pCtx^.isError`, falls back to
            sqlite3ErrStr on MEM_Null Mem.
       [X] `sqlite3_result_pointer` — ported 2026-04-28
            (passqlite3vdbe.pas) — sqlite3VdbeMemRelease + SetPointer.
       [X] `sqlite3_result_zeroblob` — ported 2026-04-28
            (passqlite3vdbe.pas) — int wrapper around _zeroblob64,
            mapping negative n to 0 per C.
       [X] `sqlite3_value_bytes16` — ported 2026-04-28 (passqlite3vdbe.pas)
            wraps `sqlite3ValueBytes(pVal, SQLITE_UTF16NATIVE)`; added
            `SQLITE_UTF16NATIVE = SQLITE_UTF16LE` constant in
            passqlite3types.pas (LE-only port).  Covered by DiagPubApi.
       [X] `sqlite3_value_encoding` — ported 2026-04-28 (passqlite3vdbe.pas)
            returns `pVal^.enc`; UTF8 for nil. Covered by DiagPubApi.
       [X] `sqlite3_value_numeric_type` — ported 2026-04-28
            (passqlite3vdbe.pas) — applies numeric affinity for TEXT then
            re-reads `sqlite3_value_type`. Covered by DiagPubApi.
       [X] `sqlite3_column_bytes16` — ported 2026-04-28
            (passqlite3vdbe.pas) — `sqlite3_value_bytes16(columnMem(...))`.
            Covered by DiagPubApi.

- [X] **8.3.2-bis** Error-message routing — closed 2026-04-28.
       `sqlite3ErrorWithMsg` (codegen.pas) now allocates `db^.pErr` via
       `sqlite3ValueNew` and stores the duplicated message via
       `sqlite3VdbeMemSetStr` (mirrors util.c:192).  `sqlite3_errmsg`
       (main.pas) reads `sqlite3_value_text(db^.pErr)` first and falls
       back to `sqlite3ErrStr(errCode)` (mirrors main.c:2711).
       `sqlite3VdbeTransferError` (vdbe.pas) ported in full from
       vdbeaux.c:3536 — copies `p^.zErrMsg` into `db^.pErr` via
       `sqlite3ValueSetStr`.  `sqlite3_step` now calls TransferError on
       every non-DONE/non-ROW return (gate on SQLITE_PREPARE_SAVESQL
       relaxed: auto-reprepare not yet wired so the message-routing is
       the only effect).  Verified: `SELECT sum(a) FROM t` overflow
       now surfaces `errmsg = "integer overflow"` instead of generic
       "SQL logic error".  Regressions clean: TestExplainParity
       1016/10, DiagPubApi 156/0, DiagSumOverflow 12/0, TestVdbeAgg
       11/0, TestVdbeApi 57/0, TestParser 45/0, TestSelectBasic 49/0,
       TestWhereBasic 52/0, TestBtreeCompat 337/0, TestDMLBasic 54/0,
       TestAuthBuiltins 34/0; DiagFeatureProbe 10, DiagPragma 29,
       DiagWindow 19, DiagDml 12/2, DiagTxn 8 — all match prior
       baselines.

- [X] **8.3.2-ter** `sqlite3VdbeReset` errCode reset — closed 2026-04-29.
       After a clean SQLITE_DONE step + finalize, `sqlite3_errmsg` was
       returning "no more rows available" instead of "not an error"
       because Pas's `sqlite3VdbeReset` skipped the vdbeaux.c:3605..3611
       arm that syncs `db^.errCode := p^.rc` (or routes through
       TransferError if a message exists) once the VDBE has executed
       any instruction.  Fix: port the missing arm verbatim.  New gate
       `src/tests/DiagErrMsg.pas` (run with `LD_LIBRARY_PATH=$PWD/src
       bin/DiagErrMsg`): div0 / overflow / cast-bad now match C's
       "not an error" verdict.  Remaining DiagErrMsg divergences
       (parse-syntax token, unknown-col, unknown-tbl, ESCAPE arg
       check, `SELECT sum`, group_concat-3-args) are pre-existing
       parse/resolve gaps — not error-routing.  Regressions clean:
       TestExplainParity 1016/10, DiagPubApi 156/0, DiagSumOverflow
       12/0, TestVdbeApi 57/0, TestVdbeAgg 11/0, TestParser 45/0,
       TestSelectBasic 49/0, TestWhereBasic 52/0, TestBtreeCompat
       337/0, TestDMLBasic 54/0, TestAuthBuiltins 34/0, TestPrintf
       105/0, DiagFunctions/Date/Cast 0 div.

- [X] **8.3.2-quater** Pre-existing parse/resolve error-message gaps
       surfaced by `DiagErrMsg.pas` — all six entries closed 2026-04-29;
       DiagErrMsg now 10/0 PASS.  Each prepared cleanly on Pas where C
       errored at prepare or step time — NOT error-routing bugs, but
       catches in earlier phases:
       [X] `SLECT 1` — closed 2026-04-29.  Root cause: `yy_syntax_error`
            (passqlite3parser.pas) called `sqlite3ErrorMsg(pPse,
            'near "%T": syntax error')` but the existing one-arg
            sqlite3ErrorMsg passes `[]` to sqlite3MPrintf, so `%T`
            consumed nil → empty token rendered.  Fix: inline
            sqlite3MPrintf with `[@yyminor]` + replicate the
            nErr/rc/zErrMsg bookkeeping.  DiagErrMsg `parse syntax`
            now PASS (`near "SLECT": syntax error`).
       [X] `SELECT z FROM t` (z not a column) — closed 2026-04-29.
            Ported the resolve.c:784..795 lookupName "no such column"
            arm into ResolveExpr (codegen.pas): when a TK_ID reaches
            the bare-identifier branch and neither matches a FROM-clause
            column / rowid nor rewrites to TK_TRUEFALSE, emit
            `sqlite3ErrorMsg(pParse, "no such column: <token>")`.
            Same arm added to the no-FROM branch so `SELECT sum` (next
            entry) closes with the same fix.
       [X] `SELECT * FROM nonesuch` — closed 2026-04-29.  Lifted the
            `LOCATE_NOERR` flag in `sqlite3SelectExpand`'s FROM-clause
            resolution loop (codegen.pas) so a missing table now sets
            `pParse^.nErr` + `zErrMsg` via `sqlite3LocateTableItem` and
            the function exits early, matching select.c:6022.  Side
            benefit: DiagErrMsg `group concat dup sep` also flips to
            PASS (`no such table: t` now wins the resolve race over
            argument-count check, mirroring C ordering).
       [X] `SELECT 'a' LIKE 'b' ESCAPE 'abc'` — closed 2026-04-29.
            Two fixes: (1) likeFunc (codegen.pas) now validates the
            ESCAPE arg via sqlite3Utf8CharLen and raises
            `sqlite3_result_error("ESCAPE expression must be a single
            character")` when len<>1, mirroring func.c:947; (2) the
            OP_Function arm in vdbe.pas was dropping the function
            error message — now copies pCtx^.pOut into v^.zErrMsg via
            sqlite3VdbeError, mirroring vdbe.c:8884.  The latter fix
            also lifts every other sqlite3_result_error message into
            sqlite3_errmsg (was previously surfacing as generic "SQL
            logic error").  DiagErrMsg `like 3 args` PASS.
            Regressions clean: TestExplainParity 1016/10, DiagPubApi
            163/0, TestVdbeAgg 11/0, TestParser 45/0, TestSelectBasic
            49/0, TestWhereBasic 52/0, TestBtreeCompat 337/0,
            TestDMLBasic 54/0, TestVdbeApi 57/0, DiagSumOverflow 12/0,
            TestAuthBuiltins 34/0.
       [X] `SELECT sum` — closed 2026-04-29 as a side-effect of the
            ResolveExpr "no such column" arm landed for `SELECT z FROM t`.
            DiagErrMsg `open fail` now PASS (`no such column: sum`).
       [X] `SELECT group_concat(a, 'x', 'y') FROM t` — closed 2026-04-29
            as a side-effect of lifting `LOCATE_NOERR` in
            `sqlite3SelectExpand` (FROM-clause now resolves before the
            argument-count check, matching C ordering).

- [X] **8.3.3** Collation / function UTF-16 wrappers — closed 2026-04-29.
       All three ported (passqlite3main.pas) — verbatim ports of
       main.c:3783 / main.c:2161 / main.c:3834.  Each wraps the input
       UTF-16NATIVE name in a sqlite3_value, transcodes to UTF-8 via
       sqlite3ValueText, then forwards to the existing UTF-8 entry point
       (createCollation / sqlite3CreateFunc) under the db mutex.
       collation_needed16 sets db^.xCollNeeded16 and clears xCollNeeded
       (mirrors C exactly).  DiagPubApi extended with 14 new cases
       (round-trip + nil-db/nil-name MISUSE for each); 217/0.  No
       regressions: TestExplainParity 1016/10, TestParser 45/0,
       TestSelectBasic 49/0, TestVdbeAgg 11/0, TestBtreeCompat 337/0,
       TestVdbeApi 57/0.
       [X] `sqlite3_complete16` — ported 2026-04-29 (passqlite3main.pas) —
            verbatim port of complete.c:269: wraps the UTF-16NATIVE input
            in a sqlite3_value, transcodes via sqlite3ValueText(UTF8),
            forwards to sqlite3_complete, masks result with 0xFF.  Added
            csq_complete16 binding in csqlite3.pas; new T14b in
            TestTokenizer.pas drives 10 differential parity cases (empty,
            whitespace, complete/incomplete statements, comments, embedded
            string semicolons, trigger BEGIN…END).  Tokenizer 137/0,
            TestExplainParity 1016/10, DiagPubApi 156/0, TestParser 45/0,
            TestVdbeAgg 11/0, TestSelectBasic 49/0, TestWhereBasic 52/0,
            TestBtreeCompat 337/0, TestDMLBasic 54/0, TestAuthBuiltins
            34/0 — no regressions.

- [ ] **8.4.1** Hooks / control / change-counter / errors / limits
       (main.c, status.c):
       [X] `sqlite3_progress_handler` — ported 2026-04-28
            (passqlite3main.pas) — sets db^.{xProgress,nProgressOps,
            pProgressArg}; nOps<=0 clears.  Runtime invocation arm in
            sqlite3VdbeExec was already wired (vdbe.pas:8909..).
            Covered by DiagPubApi (set / clear / nil-db guard).
       [X] `sqlite3_autovacuum_pages` — ported 2026-04-28
            (passqlite3main.pas) — sets db^.{xAutovacPages, pAutovacPagesArg,
            xAutovacDestr}; previous destructor fires for stale pArg before
            the new one is installed.  Covered by DiagPubApi (set / clear /
            nil-db MISUSE).
       [X] `sqlite3_interrupt` / `sqlite3_is_interrupted` — ported
            2026-04-28 (passqlite3main.pas) — sets/reads
            db^.u1.isInterrupted.
       [X] `sqlite3_setlk_timeout` — ported 2026-04-29 (passqlite3main.pas)
            — verbatim port of main.c:1863 OMIT_SETLK_TIMEOUT path:
            MISUSE on safety-check fail, RANGE for ms<-1, otherwise OK
            no-op (timeout itself unimplemented; the port has no
            db^.setlkTimeout / SQLITE_FCNTL_BLOCK_ON_CONNECT plumbing).
            Covered by DiagPubApi.
       [X] `sqlite3_uri_int64` — ported 2026-04-28 (passqlite3util.pas)
            via sqlite3_uri_parameter + sqlite3DecOrHexToI64; mirrors
            main.c:4907 exactly.
       [X] `sqlite3_compileoption_used` / `sqlite3_compileoption_get` —
            ported 2026-04-29 (passqlite3main.pas) — verbatim port of
            main.c:5158/5191 plus the ctime.c:809 `sqlite3CompileOptions`
            accessor.  Pas options table is empty (no
            ENABLE_/OMIT_ flag plumbing reachable from this entry yet),
            so `_used()` always returns 0 and `_get(N)` always returns
            nil — matches the C build with no SQLITE_ENABLE_*/SQLITE_OMIT_
            defines.  DiagPubApi extended with 8 cases (nil/bogus/SQLITE_
            prefix strip / negative N / out-of-range / C-side parity);
            now 203/0.  TestExplainParity 1016/10 — no regression.
       [ ] `sqlite3_test_control` — testing back-door (subset).
       [X] `sqlite3_file_control` — ported 2026-04-29 (passqlite3main.pas) —
            verbatim port of main.c:4153.  Dispatches FILE_POINTER /
            VFS_POINTER / JOURNAL_POINTER / DATA_VERSION / RESERVE_BYTES /
            RESET_CACHE inline, falls through to sqlite3OsFileControl for
            unknown opcodes.  Helpers added: sqlite3DbNameToBtree (main.c:4958)
            in main.pas, sqlite3BtreeGetRequestedReserve (btree.c:3136) +
            sqlite3BtreeClearCache (btree.c:11544) in btree.pas.  DiagPubApi
            extended with 6 cases (FILE_POINTER on main, VFS_POINTER on
            nil-name, unknown-schema → ERROR, nil-db → MISUSE) — 195/0.
            TestExplainParity 1016/10, TestBtreeCompat 337/0, TestVdbeApi
            57/0, TestSelectBasic 49/0, TestPager ALL PASS — no regressions.
       [X] `sqlite3_overload_function` — ported 2026-04-28
            (passqlite3main.pas).  No-op when sqlite3FindFunction already
            resolves; otherwise registers a stub via
            sqlite3_create_function_v2 with sqlite3InvalidFunction (errors
            "unable to use function NAME in the requested context" at
            runtime).  Destructor = sqlite3_free for the strdup'd name
            buffer.  Covered by DiagPubApi (success path + SELECT runtime
            ERROR + nil/MISUSE guards).
       [X] `sqlite3_table_column_metadata` — ported 2026-04-28
            (passqlite3main.pas) — verbatim port of main.c:4009; added
            `sqlite3ColumnType` helper (util.c:104) to passqlite3codegen.pas
            using the existing eCType field + literal `sqlite3StdType[]`
            strings ("ANY"/"BLOB"/"INT"/"INTEGER"/"REAL"/"TEXT").  Skips
            sqlite3Init (Pas schema is in-process only — see 7.1.1).
            Covered by DiagPubApi (a/b/c column lookups, rowid alias,
            error_out paths, MISUSE guards).  Side-discovery: surfaced
            that `sqlite3AddCollateType` (codegen.pas:23244) is still a
            no-op stub, so `COLLATE NOCASE` never sets COLFLAG_HASCOLL
            and metadata falls back to "BINARY".  See new task 6.27a.

- [ ] **8.5.1** Dynamic string builder API (`sqlite3_str_*`,
       printf.c):
       [ ] `sqlite3_str_append`, `_appendall`, `_appendchar`,
            `_appendf`, `_vappendf`.
       [ ] `sqlite3_str_errcode`, `_free`, `_length`, `_reset`,
            `_truncate`.
       [X] `sqlite3_stricmp` — case-insensitive ASCII strcmp helper
            (passqlite3util.pas:957) — public-API wrapper around
            sqlite3StrICmp with NULL guards; covered by TestUtil T3.

- [ ] **8.7.1** Snapshot / WAL APIs:
       [ ] `sqlite3_snapshot_get` / `_open` / `_free` / `_cmp` /
            `_recover`.
       [X] `sqlite3_wal_autocheckpoint` / `sqlite3_wal_hook` /
            `sqlite3_wal_checkpoint` / `_v2` — ported 2026-04-29
            (passqlite3main.pas) — verbatim port of main.c:2470..2620 plus
            sqlite3Checkpoint (main.c:2644).  Added sqlite3BtreeCheckpoint
            (btree.c:11320) in passqlite3btree.pas; delegates to
            sqlite3PagerCheckpoint with the existing nil-pBt and
            inTransaction guards.  Default hook (sqlite3WalDefaultHook)
            invokes sqlite3_wal_checkpoint when the WAL has grown past
            the configured frame threshold.  DiagPubApi extended with 14
            cases (set/clear/replace hook, autocheckpoint MISUSE on
            nil-db, checkpoint with bad eMode -> MISUSE, unknown schema
            -> ERROR, nil-zDb -> OK or LOCKED depending on residual
            read-txn from earlier prepares); 231/0.  TestExplainParity
            1016/10, TestWalCompat ALL PASS, TestVdbeApi 57/0,
            TestSelectBasic 49/0, TestWhereBasic 52/0, TestBtreeCompat
            337/0, TestDMLBasic 54/0, TestVdbeAgg 11/0 — no regressions.

- [ ] **8.7.2** Backup / serialization (currently `sqlite3_backup_init`
       / `_step` / `_finish` exist; the remaining surface is missing):
       [ ] `sqlite3_deserialize` — open in-memory db from a buffer.

- [ ] **8.8.1** Pre-update hook (preupdate.c — `SQLITE_ENABLE_PREUPDATE_HOOK`):
       [ ] `sqlite3_preupdate_count` / `_new` / `_old` / `_depth` /
            `_blobwrite`.

- [ ] **8.9.1** Vtab helper APIs (vtab.c, vdbeapi.c):
       [ ] `sqlite3_vtab_distinct` — query-planner DISTINCT hint.
       [ ] `sqlite3_vtab_in` / `_in_first` / `_in_next` — IN-operator
            helpers.
       [ ] `sqlite3_vtab_nochange` — true when UPDATE doesn't change col.
       [ ] `sqlite3_vtab_rhs_value` — extract RHS value of a constraint.

- [ ] **8.9.2** Carray / shared-cache / misc:
       [X] `sqlite3_carray_bind` / `_carray_bind_v2` (carray.c) — ported
            2026-04-29 (passqlite3carray.pas) — verbatim port of
            carray.c:412..549 incl. SQLITE_TRANSIENT duplication arms for
            INT32/INT64/DOUBLE/TEXT/BLOB and the carrayBindDel destructor;
            wrapped via sqlite3_bind_pointer with type tag "carray-bind".
            TestCarray now drives bind smoke (D1..D3): bad-mFlags →
            SQLITE_ERROR, static-buffer round-trip, v2-with-destructor
            fires xDestroy exactly once on finalize.  Side fixes:
            (1) sqlite3VdbeMakeReady now sets `p^.nVar` unconditionally
            (was only set when nVar>0 → uninitialised garbage when SQL
            had no parameters, mirrors vdbeaux.c:2731..2737); (2)
            sqlite3VdbeClearObject now releases aVar entries via
            sqlite3VdbeMemRelease (mirrors vdbeaux.c:3748) so bind-
            pointer / bind-text/blob destructors fire on finalize.
            TestExplainParity 1016/10, TestCarray 74/0, DiagPubApi
            163/0, TestVdbeApi 57/0, TestParser 45/0, TestSelectBasic
            49/0, TestWhereBasic 52/0, TestBtreeCompat 337/0,
            TestDMLBasic 54/0, TestVdbeAgg 11/0, DiagSumOverflow 12/0,
            TestAuthBuiltins 34/0, TestPrintf 105/0 — no regressions.
       [X] `sqlite3_enable_shared_cache` — ported 2026-04-29
            (passqlite3main.pas).  This port is built equivalent to
            SQLITE_OMIT_SHARED_CACHE (loadext.c:91 stub posture):
            accept the call and return SQLITE_OK; future opens never
            actually enable shared cache.  Covered by DiagPubApi.
       [X] `sqlite3_activate_cerod` — ported 2026-04-29
            (passqlite3main.pas) — deprecated CEROD activator, no-op
            stub matching the !defined(SQLITE_ENABLE_CEROD) build
            path.  Covered by DiagPubApi.

- [ ] **8.10** Public-API sample-program gate.  Pascal
  transliterations of the sample programs in `../sqlite3/src/shell.c.in`
  (and the SQLite documentation) compile and run against the port
  with results identical to the C reference.  `sqlite3.h` is
  generated by upstream `make`; reference it only after a successful
  upstream build.

---

## Phase 10 — CLI tool (`shell.c`, ~12k lines → `passqlite3shell.pas`)

Each chunk lands with a scripted parity gate that diffs
`bin/passqlite3` against the upstream `sqlite3` binary.  Unported
dot-commands must return the upstream
`Error: unknown command or invalid arguments: ".foo"` so partial
landings cannot silently no-op.

Sub-tasks 10.1.x decompose 10.1a..10.1f into one item per dot-command
or helper.  Source references are line ranges in
`../sqlite3/src/shell.c.in`.  No `passqlite3shell.pas` exists yet, so
*every* item is missing — this list exists to break the 13 816-line
file into reviewable chunks.

- [ ] **10.1a** Skeleton + arg parsing + REPL loop.  Entry point,
  command-line flag parser, `ShellState` struct, line reader,
  prompts, the read-eval-print loop, statement-completeness via
  `sqlite3_complete`, exit codes.  Gate: `tests/cli/10a_repl/`.

  [ ] **10.1.1** `ShellState` record + global state (shell.c.in
       `struct ShellState` ~3650).  Counters, mode flags, current
       output FILE*, prompt strings, history settings.
  [ ] **10.1.2** `process_input` / `one_input_line` REPL core
       (~12530..12700).  Statement-completeness via `sqlite3_complete`,
       continuation-prompt switching, `.echo` plumbing.
  [ ] **10.1.3** `main` + `process_command_line` argument parser
       (~13200..13816).  All `-bail`, `-batch`, `-cmd`, `-init`,
       `-readonly`, `-newline`, `-mode`, `-separator`, `-nullvalue`,
       `-header`, `-version`, etc.
  [ ] **10.1.4** Line reader / readline integration
       (`local_getline` + `shell_readline`).  Includes basic edit
       support when linked without GNU readline.
  [ ] **10.1.5** Exit-code mapping + `interrupt_handler` + signal wiring.
  [ ] **10.1.6** `do_meta_command` dispatcher skeleton (~9100) —
       parses `.foo` lines, splits into `azArg[]`, invokes per-command
       handler.  Initially returns "unknown command" for everything;
       per-command handlers land in the 10.1.7..10.1.42 sub-tasks.

- [ ] **10.1b** Output modes + formatting controls.  `.mode`
  (`list`, `line`, `column`, `csv`, `tabs`, `html`, `insert`, `quote`,
  `json`, `markdown`, `table`, `box`, `tcl`, `ascii`), `.headers`,
  `.separator`, `.nullvalue`, `.width`, `.echo`, `.changes`,
  `.print` / `.parameter` (formatting-only subset), Unicode-width
  helpers, box-drawing renderer.  Gate: `tests/cli/10b_modes/`.

  [ ] **10.1.7** `.mode` dispatcher (~10470) — parses mode name +
       optional table-name argument, sets `p->mode` / `p->cMode`.
  [ ] **10.1.8** `shell_callback` row dispatcher + per-mode renderers
       (`exec_prepared_stmt_columnar`, `exec_prepared_stmt`).
       Renderers: `MODE_Line`, `MODE_List`, `MODE_Semi`, `MODE_Csv`,
       `MODE_Tcl`, `MODE_Insert`, `MODE_Quote`, `MODE_Html`,
       `MODE_Json`, `MODE_Ascii`, `MODE_Pretty`.
  [ ] **10.1.9** Columnar renderers — `MODE_Column`, `MODE_Table`,
       `MODE_Markdown`, `MODE_Box`.  Column-width auto-sizing,
       `utf8_width` / `utf8_printf` helpers, box-drawing glyphs.
  [ ] **10.1.10** `.headers` / `.separator` / `.nullvalue` / `.width`
       / `.echo` / `.changes` setters.
  [ ] **10.1.11** `.print` / `.parameter` (formatting subset) —
       `.parameter init / list / set / unset / clear`.
  [ ] **10.1.12** CSV writer helpers (`output_csv`, `output_quoted_string`,
       `output_quoted_escaped_string`) + `.nullvalue` integration.
  [ ] **10.1.13** JSON writer helpers (`output_json_string`).
  [ ] **10.1.14** HTML writer helpers (`output_html_string`).

- [ ] **10.1c** Schema introspection dot-commands.  `.schema`,
  `.tables`, `.indexes`, `.databases`, `.fullschema`,
  `.lint fkey-indexes`, `.expert` (read-only subset).  Gate:
  `tests/cli/10c_schema/`.

  [ ] **10.1.15** `.schema` + `.sqlite_schema` (shell.c.in
       `do_meta_command` schema arm).  LIKE-pattern argument,
       `--indent`, `--nosys` flags.
  [ ] **10.1.16** `.tables` — runs the canonical
       `SELECT name FROM sqlite_schema WHERE type IN ('table','view')`
       query with column-formatted output.
  [ ] **10.1.17** `.indexes` — per-table index listing.
  [ ] **10.1.18** `.databases` — list `main`/`temp`/attached files.
  [ ] **10.1.19** `.fullschema` — schema + sqlite_stat1/4 dump.
  [ ] **10.1.20** `.lint fkey-indexes` — runs the canonical FK-index
       audit query.  Other `.lint` sub-options remain stubs.
  [ ] **10.1.21** `.expert` — read-only subset wrapping the
       sqlite3_expert.c module (deferred until that module is ported;
       stub with the upstream "expert is disabled" message until then).

- [ ] **10.1d** Data I/O dot-commands.  `.read`, `.dump`, `.import`
  (CSV/ASCII), `.output` / `.once`, `.save`, `.open`.  Gate:
  `tests/cli/10d_io/`.

  [ ] **10.1.22** `.read` — push a script file onto the input stack,
       respecting `.echo` and recursion guard.
  [ ] **10.1.23** `.dump` — full schema-and-data dump.  Per-row
       INSERT generation via `run_schema_dump_query` +
       `run_table_dump_query` + `output_quoted_escaped_string`.
       `--preserve-rowids`, `--newlines`, `--data-only`.
  [ ] **10.1.24** `.import` — CSV / ASCII import.  ImportCtx struct,
       `csv_read_one_field`, `ascii_read_one_field`, auto-create
       table from header row, transactional bulk-insert path.
  [ ] **10.1.25** `.output` / `.once` — redirect to file / pipe /
       stdout; `-x` (Excel) and `--bom` flags.
  [ ] **10.1.26** `.save` — `VACUUM INTO 'file'` wrapper.
  [ ] **10.1.27** `.open` — close current db and re-open with
       `--readonly`, `--zip`, `--deserialize`, `--new`, `--nofollow`.

- [ ] **10.1e** Meta / diagnostic dot-commands.  `.stats`, `.timer`,
  `.eqp`, `.explain`, `.show`, `.help`, `.shell`/`.system`, `.cd`,
  `.log`, `.trace`, `.iotrace`, `.scanstats`, `.testcase`,
  `.testctrl`, `.selecttrace`, `.wheretrace`.  Gate:
  `tests/cli/10e_meta/`.

  [ ] **10.1.28** `.stats` — toggle per-stmt status counters output;
       reads `sqlite3_stmt_status` for each opcode set.
  [ ] **10.1.29** `.timer` — wall / user / sys clock around each
       statement.
  [ ] **10.1.30** `.eqp` — sets `EXPLAIN QUERY PLAN` auto-prefix mode.
       (`off` / `on` / `trigger` / `full`).
  [ ] **10.1.31** `.explain` — sets `EXPLAIN` auto-prefix mode and
       formats the bytecode dump.
  [ ] **10.1.32** `.show` — dump all current `ShellState` settings.
  [ ] **10.1.33** `.help` — built-in help text dispatch
       (`showHelp`, ~750-line static help table).
  [ ] **10.1.34** `.shell` / `.system` — fork+exec, `popen`, capture
       output to current `.output` sink.
  [ ] **10.1.35** `.cd` — `chdir` wrapper.
  [ ] **10.1.36** `.log` — opens / closes a logging FILE* + wires
       `sqlite3_config(SQLITE_CONFIG_LOG, …)`.
  [ ] **10.1.37** `.trace` — installs `sqlite3_trace_v2` callback
       (`stmt` / `profile` / `row` / `close`).
  [ ] **10.1.38** `.iotrace` — wires `sqlite3IoTrace` (gated on the
       6.8 `sqlite3VdbeIOTraceSql` arm landing first).
  [ ] **10.1.39** `.scanstats` — gated on the 6.8
       `sqlite3VdbeScanStatus*` arms + 8.2.1 `sqlite3_stmt_scanstatus`.
  [ ] **10.1.40** `.testcase` / `.check` — testcase output capture
       used by the upstream test runner.
  [ ] **10.1.41** `.testctrl` — `sqlite3_test_control` opcode
       dispatcher (gated on 8.4.1).
  [ ] **10.1.42** `.selecttrace` / `.wheretrace` / `.treetrace` —
       compile-time-debug toggles wrapping `sqlite3_test_control`.

- [ ] **10.1f** Long-tail / specialised dot-commands.  `.backup`,
  `.restore`, `.clone`, `.archive`/`.ar`, `.session`, `.recover`,
  `.dbinfo`, `.dbconfig`, `.filectrl`, `.sha3sum`, `.crnl`,
  `.binary`, `.connection`, `.unmodule`, `.vfsinfo`, `.vfslist`,
  `.vfsname`.  Out-of-scope dependencies (session, archive, recover)
  may stub with the upstream `SQLITE_OMIT_*` "feature not compiled
  in" message.  Gate: `tests/cli/10f_misc/`.

  [ ] **10.1.43** `.backup` — `sqlite3_backup_init/_step/_finish`
       wrapper writing to the destination file.
  [ ] **10.1.44** `.restore` — symmetric, source = file.
  [ ] **10.1.45** `.clone` — combines backup + reattach (multi-db
       variant of `.backup`).
  [ ] **10.1.46** `.archive` / `.ar` — sqlar reader/writer; gated on
       sqlar extension.  Stub with omit-message until that lands.
  [ ] **10.1.47** `.session` — session-extension dispatcher
       (`attach`, `enable`, `filter`, `indirect`, `isempty`, `list`,
       `changeset`, `patchset`).  Gated on session extension; stub
       with omit-message.
  [ ] **10.1.48** `.recover` — corruption-recovery extension dispatcher.
       Gated on recover extension; stub with omit-message.
  [ ] **10.1.49** `.dbinfo` — runs the canonical
       `pragma_database_list` + page-1 header dump.
  [ ] **10.1.50** `.dbconfig` — `sqlite3_db_config` opcode dispatcher
       (gated on 8.1.1 raw-varargs `sqlite3_db_config`).
  [ ] **10.1.51** `.filectrl` — `sqlite3_file_control` opcode
       dispatcher (gated on 8.4.1).
  [ ] **10.1.52** `.sha3sum` — runs the SHA3 hash extension over
       schema + data.  Bundles a Pascal SHA3 implementation or links
       the existing extension.
  [ ] **10.1.53** `.crnl` — toggles CR-NL translation on Windows
       output (no-op on Linux).
  [ ] **10.1.54** `.binary` — toggles binary stdout mode (no-op on
       Linux).
  [ ] **10.1.55** `.connection` — multi-connection switching
       (`.connection 0..N`, `.connection close N`).
  [ ] **10.1.56** `.unmodule` — `sqlite3_drop_modules` wrapper.
  [ ] **10.1.57** `.vfsinfo` / `.vfslist` / `.vfsname` — VFS
       introspection via `sqlite3_file_control`
       (`SQLITE_FCNTL_VFS_POINTER`).
  [ ] **10.1.58** `.dbtotxt` — page-by-page hex dump (used by the
       upstream `dbsqlfuzz` corpus); gated on the bytecode of the
       db being readable, no extension dependency.
  [ ] **10.1.59** `.breakpoint` — debug-only no-op breakpoint
       target (one-line stub).

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
