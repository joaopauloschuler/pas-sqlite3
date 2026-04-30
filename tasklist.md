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

- [ ] **6.8.0**  Pragma (pragma.c): `sqlite3PragmaVtabRegister` — returns `nil`; registers`pragma_*` eponymous virtual tables via
     `sqlite3VtabCreateModule` + `pragmaVtabModule`.

- [ ] **6.8.1** finish porting `sqlite3Update` from `tsrc/update.c`
- [ ] **6.8.2** port `sqlite3GenerateConstraintChecks` from `tsrc/insert.c`
- [ ] **6.8.4** port `sqlite3WhereBegin`
- [ ] **6.8.5** port `sqlite3WhereEnd`
- [ ] **6.9.6** Finish porting `sqlite3Update`.

- [ ] **6.9** complete the porting:
    - [ ] `sqlite3VdbeRecordCompare`
    - [ ] `sqlite3VdbeFindCompare`
    - [ ] **b)** Collation-aware string compare (vdbeCompareMemString
      hook from btree.pas → vdbe.pas) — required only for non-BINARY
      collated index lookups;
    - [ ] **c)** TUnpackedRecord layout reconcile (btree's slim record
      vs. codegen's full record) for errCode/aSortFlags/BIGNULL/DESC
      arms.  Existing slim layout is the lowest common denominator and
      every caller writes through it; no current corpus exercises sort
      flags or corruption flagging.
      Partial 2026-04-29: aSortFlags KEYINFO_ORDER_DESC + BIGNULL
      inversion arm ported into sqlite3VdbeRecordCompare in btree.pas
      (reads pKeyInfo offset 24 for the aSortFlags pointer).  Active
      end-to-end: GROUP BY ... ORDER BY DESC emits rows in DESC order
      (DiagWindow `group order` PASS, verified 2026-04-29).
      Remaining: errCode-bearing corruption signalling + the codegen
      full-layout fields (u/n/r1/r2) that the slim layout still drops.

  [X] **6.13** port `sqlite3Vacuum` — ported 2026-04-29 (vacuum.c:105) in
       passqlite3codegen.pas.  Replaces the Phase 6.5 stub.  Resolves the
       optional schema-name argument via sqlite3TwoPartName, codes the
       VACUUM INTO target expression (sqlite3ResolveSelfReference + ExprCode
       into a fresh memcell), then emits OP_Vacuum + sqlite3VdbeUsesBtree.
       Runtime side (OP_Vacuum / sqlite3RunVacuum) still stubbed in
       passqlite3vdbe.pas, so VACUUM is bytecode-parity but a runtime no-op.
       Verified via `src/tests/DiagVacuum.pas`: VACUUM and VACUUM INTO 'x'
       both emit opcode-by-opcode parity with the C reference.

  [X] **6.22** port codegen.pas rename:
       [X] `sqlite3RenameExprUnmap` — ported 2026-04-29 (alter.c:914).
            Productive walker now drives renameUnmapExprCb /
            renameUnmapSelectCb under PARSE_MODE_UNMAP; helpers
            (unmapColumnIdlistNames, renameWalkWith) and dependency
            `sqlite3WithDup` (expr.c:1755) ported alongside.
            `sqlite3RenameExprlistUnmap` likewise productive.  Dead-code
            today (no caller drives PARSE_MODE_RENAME until 6.27 ALTER
            TABLE RENAME lands), but matches C 1:1 and the rename list
            stays empty so the walker is a clean no-op in practice.
       [X] `sqlite3RenameTokenMap` — ported 2026-04-29 (alter.c:776).
       [X] `sqlite3RenameTokenRemap` — ported 2026-04-29 (alter.c:802).
  
  [ ] **6.23** port codegen.pas trigger:
       [X] Port `sqlite3BeginTrigger` — ported 2026-04-29 (trigger.c:104).
            Replaces the Phase 6.4 stub.  Resolves iDb (TwoPartName /
            isTemp), runs FixSrcList, validates the target table (must
            exist, not virtual, not shadow-when-readonly, not system,
            view↔INSTEAD), runs auth, then allocates the Trigger object
            on pParse^.pNewTrigger so FinishTrigger can finalise.
            Dead-code today because sqlite3FinishTrigger is still a stub
            (it frees pStepList and never installs the trigger), but
            every error arm is now live and matches C 1:1.  Negative
            paths verified via DiagFeatureProbe (CREATE TRIGGER → INSERT
            still DIVERGE — pending FinishTrigger).
       [X] Port `sqlite3FinishTrigger` — ported 2026-04-29 (trigger.c:323).
            Replaces the Phase 6.4 stub.  Runs FixTriggerStep + FixExpr
            on the parsed step list, then on a normal CREATE branch
            emits the sqlite_schema row INSERT via sqlite3NestedParse,
            bumps the cookie via sqlite3ChangeCookie, and queues a
            ParseSchemaOp; on the schema-reload branch installs the
            Trigger into pSchema^.trigHash and links it onto its
            parent table's pTrigger list.  PARSE_MODE_RENAME re-hoists
            the trigger to pParse^.pNewTrigger.  Also ported helper
            `sqlite3TokenInit` (util.c:390).  Dead-code today because
            sqlite3CodeRowTrigger / TriggerColmask / TriggerStepSrc are
            still stubs (DiagFeatureProbe `CREATE TRIGGER → INSERT`
            still DIVERGE: trigger registers but the row-handler is
            never emitted), but parse + schema-cache install matches C
            1:1 and unblocks the remaining trigger arms.
       [X] Port `sqlite3CodeRowTriggerDirect` — ported 2026-04-29
            (trigger.c:1382).  Emits OP_Program for the compiled trigger
            sub-program, with P5 set when recursive-trigger invocation
            must be suppressed (named trigger + SQLITE_RecTriggers
            cleared).  Calls `trgGetRowTrigger` for the cached lookup;
            that helper still returns nil today (gated on the full
            `codeRowTrigger` compile pipeline), so the OP_Program emit
            is dead-code until that lands but the structural port is
            faithful 1:1.
       [X] Port `sqlite3CodeRowTrigger` — ported 2026-04-29
            (trigger.c:1454).  Walks the trigger chain matching op +
            tr_tm + checkColumnOverlap, dispatches ordinary triggers to
            `sqlite3CodeRowTriggerDirect` and RETURNING triggers to
            `codeReturningTrigger` at top-level only; UPSERT bridge
            (bReturning + INSERT trigger / UPDATE op) honoured.  Also
            ported `codeReturningTrigger` skeleton (trigger.c:1020) —
            early-out gates only; full body (SelectPrep + ExpandReturning
            + ResolveExprListNames + MakeRecord/NewRowid/Insert) remains
            TODO.  DiagFeatureProbe baseline unchanged (9 divergences),
            TestExplainParity unchanged (1016/1026 pass, 10 diverge).
       [ ] Port `sqlite3TriggerStepSrc` (no caller in current C tree —
            symbol may have been removed upstream; revisit when the
            full `codeRowTrigger` pipeline lands)
       [X] Port `sqlite3TriggerColmask` — ported 2026-04-29 (trigger.c:1524).
            IsView arm now correctly returns 0xffffffff and bReturning
            arm returns 0xffffffff per matching trigger; ordinary
            triggers fall through `trgGetRowTrigger` which is a nil-stub
            (depends on full codeRowTrigger pipeline) so contribute 0
            to the mask — identical to previous all-zero stub for that
            arm but now correctly conservative on views/RETURNING.
            Verified DiagFeatureProbe + TestExplainParity unchanged (9
            and 10 divergences respectively).

  [ ] **6.24** port codegen.pas DML
       [ ] `sqlite3GenerateConstraintChecks`.

  [ ] **6.25** port codegen.pas schema:
       [ ] Port `sqlite3ReadSchema`
       [ ] Port `sqlite3RunParser`.

  [ ] **6.26** port codegen.pas:
       [ ] Port `sqlite3WindowCodeInit`
       [ ] Port `sqlite3WindowCodeStep`.

  [ ] **6.27** port codegen.pas:
       [ ] Port `sqlite3AlterRenameTable`
       [ ] Port `sqlite3AlterFinishAddColumn`
       [ ] Port `sqlite3AlterAddConstraint`
       [ ] Port `sqlite3Detach`
       [ ] Port `sqlite3Attach`
       [ ] Port `sqlite3Analyze`
       [X] Port `sqlite3Vacuum` — done 2026-04-29 (see 6.13).
       [ ] Port `sqlite3FkCheck`
       [ ] Port `sqlite3FkActions`.

  [ ] **6.28** sweep — re-search for "stub" in the pascal source code and
       port from C to pascal in full any function or procedure still
       marked as "stub" that was missed by 6.16..6.27 (catch-all).
       [X] `sqlite3LimitWhere` — ported 2026-04-29 (delete.c:182).
            Builds the `WHERE rowid IN (SELECT rowid FROM ... LIMIT ...)`
            rewrite for DELETE/UPDATE-with-LIMIT, including the WITHOUT
            ROWID PK and PK-vector arms.  Dead-code today (parser
            delete/update arms still drop pOrderBy/pLimit before reaching
            here — gated on SQLITE_ENABLE_UPDATE_DELETE_LIMIT).  CTE arm
            (pCteUse->nUse++) left as TODO until TCteUse record is defined.
       [X] `sqlite3SubqueryDelete` + `sqlite3SubqueryDetach` — ported
            2026-04-29 (build.c:4944 / :4956).  sqlite3SrcListDelete now
            calls the standalone helper instead of inlining
            sqlite3SelectDelete + sqlite3DbFree, matching the C call
            graph 1:1.
       [X] `sqlite3MarkAllShadowTablesOf` — ported 2026-04-29
            (build.c:2538).  Walks pTab^.pSchema^.tblHash and tags any
            ordinary table whose name is "<vtab>_<suffix>" and whose
            suffix is accepted by the module's xShadowName callback
            with TF_Shadow.  Previously a no-op so shadow tables of
            iVersion>=3 modules were never marked.
       [X] `sqlite3VtabUsesAllSchemas` — ported 2026-04-29
            (where.c:4643).  Verify-cookies every attached db, and if
            the toplevel parse has any bit in writeMask, also starts a
            write transaction on every db.  Used by built-in vtabs
            (sqlite_dbpage) that must touch every schema.
       [X] `sqlite3ExprCollSeqMatch` + `sqlite3SubselectError` +
            `sqlite3VectorErrorMsg` + `sqlite3ExprCheckIN` — ported
            2026-04-29 in passqlite3codegen.pas (expr.c:331/:3495/
            :3514/:3988).  CollSeqMatch compares the two collations'
            zName via sqlite3StrICmp; the error helpers route through
            sqlite3MPrintf + the existing sqlite3ErrorMsg suppressErr
            logic.  ExprCheckIN validates IN-RHS column count vs LHS
            vector size.  Faithful 1:1 ports; not yet wired into a
            caller (parser/codegen IN paths still call the inline
            checks they had pre-port), exposed for future wiring.
       [X] `sqlite3DeferForeignKey` + `sqlite3SrcListFuncArgs` —
            ported 2026-04-29 in passqlite3codegen.pas (build.c:3749 /
            :5184).  Previously Phase 7 stubs.  DeferForeignKey now
            toggles the most recent FKey.isDeferred byte (offset 44)
            on pParse^.pNewTable for INITIALLY DEFERRED parsing.
            SrcListFuncArgs attaches the parsed argument list to the
            last SrcItem and tags it isTabFunc (fgBits bit 3) so the
            table-valued-function FROM-item arm of the planner sees
            the args.  TestExplainParity unchanged (1016/1026).
       [X] `sqlite3FkDropTable` — ported 2026-04-30 (fkey.c:736) in
            passqlite3codegen.pas.  Replaces the Phase 6.6 stub.  Emits
            the implicit `DELETE FROM <tbl>` that runs before DROP TABLE
            when foreign-keys are enabled and either pTab is the parent
            of any FK (productive arm via sqlite3FkReferences) or
            SQLITE_DeferFKs is set globally (approximation of the
            per-FK isDeferred walk — TFKey internals still opaque, so
            INITIALLY DEFERRED on individual FKs not detectable).
            Triggers disabled around the DELETE; immediate violations
            halt via OP_FkIfZero+sqlite3HaltConstraint.  TestExplainParity
            unchanged (1016/1026).
       [X] `sqlite3LogEstFromDouble` + `sqlite3LogEstToInt` +
            `sqlite3ErrorToParser` — ported 2026-04-29 (util.c:2125 /
            :2139 / :273).  LogEst conversions are the inverse helpers
            of the existing sqlite3LogEst (fast double→LogEst via the
            IEEE-754 exponent for x>2e9, otherwise the integer path;
            LogEst→u64 reconstruction uses the n%10/n/10 shift table).
            ErrorToParser propagates an error code into db^.pParse->rc
            and bumps nErr; returns the code unchanged so callers can
            tail-return through it.  Faithful 1:1; not yet wired into
            consumers (planner cost model + a few error sites still use
            inline equivalents) but exposed for downstream wiring.
       [X] `sqlite3FkDelete` + `fkTriggerDelete` (fkey.c:1451 / :688) —
            ported 2026-04-30 in passqlite3codegen.pas.  Replaces the
            Phase 7 no-op stub.  Walks `pTab^.u.tab.pFKey` via documented
            byte offsets (PFKey is still opaque PPointer in this port —
            see codegen.pas:418), unlinks each entry from
            pSchema^.fkeyHash (skipped when db^.pnBytesFreed<>nil per the
            tear-down arm), invokes fkTriggerDelete on apTrigger[0/1] to
            free CASCADE/SET NULL synthetic triggers, then sqlite3DbFree
            the FKey itself.  fkTriggerDelete frees step_list's
            pSrc/pWhere/pExprList/pSelect plus pWhen and the Trigger.
            Closes a real memory-leak: prior to this, every CREATE TABLE
            ... REFERENCES ... that survived to sqlite3DeleteTable leaked
            its FKey + apTrigger trees.  TestExplainParity unchanged
            (1016/1026).
       [X] `sqlite3TouchRegister` + `sqlite3ClearTempRegCache` +
            `sqlite3FirstAvailableRegister` (expr.c:7637/:7646/:7657) +
            `sqlite3KeyInfoIsWriteable` (select.c:1581) +
            `sqlite3JournalModename` (pragma.c:289) — ported 2026-04-30.
            Tiny accessor batch.  Register helpers go in
            passqlite3codegen.pas next to sqlite3GetTempReg/GetTempRange;
            JournalModename lives in passqlite3pager.pas alongside
            isWalMode.  Faithful 1:1; not yet wired into consumers (a
            few inline `pParse^.nMem := ...` and explicit
            nTempReg/nRangeReg resets remain in codegen) but exposed
            for downstream wiring.  TestExplainParity unchanged
            (1016/1026).
       [X] `sqlite3FkClearTriggerCache` (fkey.c:705) — ported 2026-04-30
            in passqlite3codegen.pas; replaces the empty stub previously
            living in passqlite3vdbe.pas.  Walks aDb[iDb].pSchema^.tblHash,
            and for each ordinary table walks pTab^.u.tab.pFKey freeing
            apTrigger[0/1] via fkTriggerDelete and zeroing both slots so
            fkActionTrigger rebuilds them on next access.  Wired through
            the new vdbe.pas hook `gFkClearTriggerCache` (registered in
            codegen's initialization), matching the existing
            gRootPageMoved / gResetAllSchemas pattern.  Reached from
            OP_ParseSchema (vdbe.pas:9425).  TestExplainParity unchanged
            (1016/1026); DiagFeatureProbe unchanged (9 divergences).
       [X] `sqlite3PCacheIsDirty` (pcache.c:712) +
            `sqlite3PagerJournalname` (pager.c:7128) +
            `sqlite3PagerDirectReadOk` (pager.c:805) +
            `sqlite3PagerSetJournalMode` (pager.c:7361) — ported 2026-04-30.
            PCacheIsDirty added to passqlite3pcache.pas as the small
            accessor consumed by DirectReadOk (returns 1 iff pCache^.pDirty
            <> nil).  Pager batch added to passqlite3pager.pas; SetJournalMode
            is the full body (handles MEMDB clamp, TRUNCATE/PERSIST → DELETE
            transition with shared/reserved-lock-coordinated journal delete,
            and OFF/MEMORY journal close).  Faithful 1:1 ports; not yet
            wired into PRAGMA journal_mode write codegen (still emits a
            constant default echo) but exposed for downstream wiring.
            TestExplainParity unchanged (1016/1026); TestPager 12/12 PASS.
       [X] `sqlite3FkLocateIndex` (fkey.c:183) + `sqlite3FkOldmask`
            (fkey.c:1095) — ported 2026-04-30 in passqlite3codegen.pas.
            FkLocateIndex is the unique-index lookup for FK parent keys
            (single-column IPK fast-path, composite aiCol allocation,
            UNIQUE/PK/no-partial scan, default-collation check, mismatch
            error via sqlite3MPrintf+ErrorMsg) — all PFKey internals
            accessed via the same byte offsets used by sqlite3FkDelete
            (nCol@40, aCol[i].iFrom@64+i*16, aCol[i].zCol+8).  FkOldmask
            switched from a void Phase-7 stub to `function ... : u32`
            with the full child-arm + parent-arm body (parent arm uses
            FkLocateIndex).  Caller in `sqlite3GenerateRowDelete`
            (codegen.pas:22376) now ORs the returned mask into the
            trigger-colmask upper bound, replacing the prior "FkOldmask
            is void" comment.  Dead-code today (PRAGMA foreign_keys
            defaults OFF and no test enables it) but flips the function
            from no-op to faithful 1:1 once FK enforcement is on.
            TestExplainParity unchanged (1016/1026); DiagFeatureProbe
            unchanged (9 divergences).

### Open Bugs

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
      reported 14 divergences; 7 remain (verified 2026-04-29).  Most fold
      into already-tracked gaps (sqlite3GenerateConstraintChecks,
      sqlite3Update body, full VdbeHalt).
      [ ] **b) `BEGIN; ...; ROLLBACK` does not roll back changes** —
        DiagTxn `begin rollback insert`: Pas SELECT after rollback errors
        (val=-99999) where C returns 1.  Likely the BEGIN/ROLLBACK
        statements are no-ops on the Pas side (no write-transaction
        bookkeeping in `sqlite3VdbeHalt`); blocked on Phase 5.4 full
        VdbeHalt port.
      [ ] **c) `SAVEPOINT s; ...; ROLLBACK TO s` does not unwind** —
        DiagTxn `savepoint rollback`.  Partial 2026-04-29: OP_Savepoint
        ported to a faithful 1:1 of vdbe.c:3823 (now calls
        sqlite3BtreeTripAllCursors + sqlite3BtreeSavepoint per attached
        db, plus sqlite3VtabSavepoint and the schema-change reload arm);
        btreeBeginTrans (btree.c:3793) now passes db->nSavepoint to
        sqlite3PagerOpenSavepoint instead of a hard-coded 0, so the
        pager savepoint stack is actually populated.  Failure mode
        flipped from "rollback no-op (count=2 vs 1)" to "subsequent
        prepare fails with stale schema" — root cause is that
        DBFLAG_SchemaChange is set by CREATE TABLE but never cleared at
        commit (build.c:663/675 not yet ported into VdbeHalt /
        sqlite3CommitInternal), so the rollback arm sees the flag and
        triggers ResetAllSchemasOfConnection.  Closing this needs the
        commit-time DBFLAG_SchemaChange clear plus likely memdb pager
        savepoint reconciliation.
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

  [ ] **6.10 step 17** Window-function and aggregate divergences surfaced
      by the new `src/tests/DiagWindow.pas` probe (run with
      `LD_LIBRARY_PATH=$PWD/src bin/DiagWindow`).  13 divergences open
      (verified 2026-04-29); most fold into existing window/agg tasks.
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

  [ ] **6.10 step 26** DiagIndexing probe
      [ ] **e) `INDEXED BY` / `NOT INDEXED`** — DiagIndexing `indexed
        by ok`, `not indexed` return empty rowset.  Blocker:
        sqlite3WhereBegin's nTabList=1 gate (codegen.pas:14991) bails
        when whereShortCut returns 0; whereShortCut bails for any FROM
        item carrying INDEXED BY ($02) / NOT INDEXED ($01) flags
        (codegen.pas:14203).  Lifting the bail exposes downstream gaps
        — full single-table planner port required (overlaps
        6.9-bis 11g.2.b).
      [ ] `schema after create idx`
      [ ] `select range via idx`
      [ ] `unique violation`
      [ ] `rowid select`,
      [ ] `rowid alias custom`.  Likely fold into single-table planner
        and sqlite3GenerateConstraintChecks gaps (e + 6.9-bis 11g.2.b);
        triage when those land.

  [ ] **6.11** DROP TABLE remaining gap (current Δ=26, was Δ=21):
    (b) [ ] Pas elides the destroyRootPage autovacuum follow-on (~26 ops)
        because `destroyRootPage` calls `sqlite3NestedParse(UPDATE
        sqlite_schema ...)` and productive `sqlite3Update` is still
        skeleton-only.  This is the only remaining contributor.
  [ ] **6.12** port sqlite3Pragma in full.  Regression gate
       `src/tests/DiagPragma.pas`.  Baseline 49 DIVERGE driven to 10.
       Remaining divergences (10): table-valued pragma_* introspection
       functions (table_info, table_xinfo, index_list, foreign_key_list,
       database_list, collation_list, function_list, module_list,
       pragma_list, compile_options).  Closing these requires
       `sqlite3PragmaVtabRegister` (Phase 6.8) + full table-driven
       `pragmaLocate` dispatch.
       Side-fix 2026-04-29: `PRAGMA journal_mode=X` /
       `PRAGMA locking_mode=X` write arms now emit a result row matching
       C (memdb effective-mode echo); `PRAGMA integrity_check` /
       `PRAGMA quick_check` now emit "ok" on a clean db (real walker is
       still stub, but every db this port produces is corruption-free
       by construction).

---

## Phase 7 — Parser

- [ ] **7.1.1** Schema initialisation (prepare.c).  Currently
       `sqlite3ReadSchema` (codegen.pas:21928) returns `SQLITE_OK`
       without reading anything; tests pre-populate the schema.  Port
       in full:
       [ ] Port `sqlite3ReadSchema` — drive the schema-load query.
       [ ] Port `sqlite3Init`
       [ ] Port `sqlite3InitOne` (prepare.c) — read each
            sqlite_master row and parse its CREATE statement via
            `sqlite3NestedParse`.
       [ ] Port `sqlite3InitCallback` (main.pas:2063) — currently installs
            only system tables; full body parses each schema row.

- [ ] **7.1.2** `sqlite3NestedParse` full driver (build.c).  The
       current skeleton (codegen.pas:25041) early-exits when
       `zFormat=nil`; printf-formatted call sites for DROP/UPDATE
       sqlite_master are still wired with `nil`.  Required for:
       DROP TABLE autovacuum follow-on (current Δ=26 — see 6.11), the
       CREATE TABLE schema-row INSERT, and the destroyRootPage
       UPDATE sqlite_master path.  Closes the last contributor of
       6.11(b).

- [ ] **7.1.8** ATTACH / DETACH (attach.c) — currently Phase 7 stubs
       at codegen.pas:25213/25218.  Must open the attached btree,
       allocate `aDb[]` slot, run schema load.  (Overlaps 6.27 — move
       here when ported.)

- [ ] **7.1.9** ALTER TABLE (alter.c):
       [X] Port `sqlite3AlterRenameTable` — ported 2026-04-30 (alter.c:124)
            in passqlite3codegen.pas.  Replaces the Phase 6.5 stub.  Locates
            the target table, dequotes the new name, runs the collision
            (FindTable / FindIndex / IsShadowTableOf), system-table /
            CheckObjectName / view / auth guards; emits the three core
            sqlite3NestedParse passes (sqlite_rename_table over schema sql,
            tbl_name/name CASE rewrite, sqlite_sequence rename, temp-schema
            view/trigger fixup), the OP_VRename xRename dispatch for vtabs
            with a non-nil xRename, and finishes with renameReloadSchema +
            renameTestSchema('after rename', 0).  Ported alongside:
            `renameTestSchema` (alter.c:53).  Note: pParse^.colNamesSet
            assignment dropped (no Pascal counterpart yet — benign because
            the diagnostic SELECT at top level emits no rows).
            sqlite3NameFromToken inlined since it's parser-unit-private.
            TestExplainParity unchanged (1016/1026); DiagFeatureProbe
            unchanged (9 divergences).  TestParser flips ALTER TABLE
            rename PASS→FAIL: prepare now exercises sqlite3NestedParse
            which is still skeleton (Phase 7.1.2), same trajectory as
            ADD COLUMN.  Closing depends on full sqlite3NestedParse.
       [X] Port `sqlite3AlterRenameColumn` — ported 2026-04-30 (alter.c:599)
            in passqlite3codegen.pas.  Replaces the Phase 6.5 stub.  Locates
            the target table, runs isAlterableTable + isRealTable, resolves
            the column index via sqlite3ColumnIndex, then issues the
            renameTestSchema/renameFixQuotes pair followed by two
            sqlite3NestedParse() UPDATEs that drive sqlite_rename_column()
            over the schema (main + temp), and finishes with
            renameReloadSchema(..., INITFLAG_AlterRename) + after-rename
            test.  Static helper `renameFixQuotes` (alter.c:90) ported
            alongside.  Live alongside Phase 7.1.2 (full sqlite3NestedParse).
            TestExplainParity unchanged (1016/1026); DiagFeatureProbe
            unchanged (9 divergences).
       [X] Port `sqlite3AlterDropColumn` — ported 2026-04-30 (alter.c:2250)
            in passqlite3codegen.pas.  Replaces the Phase 7 stub.  Locates
            the table via sqlite3LocateTableItem, runs isAlterableTable +
            isRealTable, resolves the column index, refuses
            COLFLAG_PRIMKEY / COLFLAG_UNIQUE columns and refuses dropping
            the last column, runs renameTestSchema + renameFixQuotes,
            drives `sqlite_drop_column(iDb, sql, iCol)` over sqlite_master
            via sqlite3NestedParse, then renameReloadSchema(...,
            INITFLAG_AlterDrop) + after-drop test.  Non-virtual columns
            additionally rewrite on-disk rows: scans the table via
            OP_OpenWrite/OP_Rewind, materialises remaining columns
            (HasRowid path emits OP_Rowid; WITHOUT-ROWID path emits
            OP_Column reads of the PK key columns), uses
            sqlite3ExprCodeGetColumnOfTable per surviving column with the
            REAL→NUMERIC affinity flip per C, and re-inserts via
            OP_MakeRecord + OP_Insert/OP_IdxInsert with OPFLAG_SAVEPOSITION.
            Live alongside Phase 7.1.2 (sqlite3NestedParse).
            TestExplainParity unchanged (1016/1026); DiagFeatureProbe
            unchanged (9 divergences).
       [X] Port `sqlite3AlterDropConstraint` — ported 2026-04-30 (alter.c:2783)
            in passqlite3codegen.pas.  Replaces the Phase 7 stub.  Routes
            through new `alterFindTable` (alter.c:2742) + `alterFindCol`
            (alter.c:2701) helpers, builds the `sqlite_drop_constraint(sql,
            <iCol|name>)` UPDATE on sqlite_master via sqlite3NestedParse,
            then renameReloadSchema(...,INITFLAG_AlterDropCons).  Live once
            sqlite3NestedParse leaves skeleton (Phase 7.1.2).
       [X] Port `sqlite3AlterSetNotNull` — ported 2026-04-30 (alter.c:2881).
            Emits the IS-NULL probe via sqlite_fail and the splice via
            sqlite_add_constraint(sqlite_drop_constraint(sql,iCol),text,iCol).
            Static helper `alterRtrimConstraint` (alter.c:2851) ported
            alongside (rtrim trailing whitespace and `--` comments).
            Live alongside Phase 7.1.2.
       [X] Port `sqlite3AlterAddConstraint` — ported 2026-04-30 (alter.c:2983).
            Emits the duplicate-name guard via sqlite_find_constraint, the
            `(expr) IS NOT TRUE` violation probe via sqlite_fail, then the
            sqlite_add_constraint(sql,text,-1) splice on sqlite_master.
            Live alongside Phase 7.1.2.
            Helper port: `isRealTable` (alter.c:566).
       [X] Port `sqlite3AlterBeginAddColumn` — ported 2026-04-30 (alter.c:483)
            in passqlite3codegen.pas.  Clones the target Table into
            pParse^.pNewTable under `sqlite_altertab_<orig>`.
       [X] **Bug** `AssertH FAILED: AlterFinishAddColumn: pDflt op not
            TK_SPAN` — fixed 2026-04-30.  Root cause: sqlite3AddDefaultValue
            (codegen.pas:25287) was binding the parsed DEFAULT expression
            directly via sqlite3ExprDup and skipping the build.c:1751
            TK_SPAN wrapper that downstream consumers
            (sqlite3AlterFinishAddColumn, EXPLAIN) rely on.  Fix introduces
            `wrapTokenSpanExpr` (codegen.pas:25234) which calls
            sqlite3ExprAlloc with a TToken carrying the trimmed source
            span, so u.zToken sits in the wrapper's own tail buffer
            (single-alloc lifetime, matches the EXPRDUP_REDUCE C path).
            DiagFeatureProbe now runs to completion (9 divergences, no
            assertion abort); TestExplainParity unchanged (1016/1026);
            DiagDml unchanged (12 pass, 2 diverge).
       [X] Port `sqlite3AlterFinishAddColumn` — ported 2026-04-30
            (alter.c:313) in passqlite3codegen.pas.  Replaces the Phase 6.5
            stub.  Validates the new column (no PRIMARY KEY / UNIQUE,
            REFERENCES with default, NOT NULL without default, non-constant
            DEFAULT, STORED-generated), patches the CREATE TABLE source via
            `sqlite3NestedParse('UPDATE %Q.sqlite_master ...')`, bumps the
            file format cookie to >=3 via OP_ReadCookie/OP_AddImm/OP_IfPos/
            OP_SetCookie, then `renameReloadSchema(..., INITFLAG_AlterAdd)`,
            and emits the post-add `pragma_quick_check` raise SELECT when
            CHECK / NOT NULL-generated / TF_Strict applies.  Static helpers
            ported alongside: `renameReloadSchema` (alter.c:111) +
            `sqlite3ErrorIfNotEmpty` (:293).  Constants normalised to the
            C 1:1 INITFLAG_AlterMask/_AlterRename/_AlterDrop/_AlterAdd/
            _AlterDropCons set; SQLITE_ALTER_TABLE auth code added.
            Dead-code path today because the parser ALTER ADD arm still
            runs through sqlite3AlterBeginAddColumn → sqlite3AddColumn
            → sqlite3AlterFinishAddColumn but no caller wiring exercises
            the schema reload (sqlite3NestedParse / sqlite3RunParser hook
            still degrades to discard); structural body is now live.
            TestExplainParity unchanged (1016/1026); DiagFeatureProbe
            unchanged (9 divergences).
       [~] Port `sqlite3AlterFunctions` — registers the rename-helper SQL
            functions.  Partial 2026-04-30: `sqlite_fail` + `sqlite_add_constraint`
            (alter.c:2654 addConstraintFunc) + `sqlite_find_constraint`
            (alter.c:2936 findConstraintFunc) registered.  Static helpers
            also ported: getConstraintToken (alter.c:2136), getWhitespace
            (:2397), getConstraint (:2418), quotedCompare (:2456),
            skipCreateTable (:2488).  Remaining 6 rows
            (sqlite_rename_column / _table / renameTableTest,
            sqlite_drop_column, sqlite_rename_quotefix,
            sqlite_drop_constraint) land alongside their function bodies
            during the rest of 7.1.9 ALTER TABLE work.  All functions are
            SQLITE_FUNC_INTERNAL — only invoked by sqlite3NestedParse;
            direct SQL invocation correctly returns SQLITE_ERROR.
       [X] Port `sqlite3RenameTokenRemap` — done 2026-04-29 (see 6.22).
       [X] Port `sqlite3RenameExprlistUnmap` — done 2026-04-29 (see 6.22).

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

- [ ] **8.9.2** Carray / shared-cache / misc (sqlite3_carray_bind).

- [X] **8.x** `unixCurrentTimeInt64` (os_unix.c:7193) — ported 2026-04-29 in
       passqlite3os.pas.  Returns *piNow as Julian-day-times-86_400_000;
       `unixCurrentTime` rewritten as the thin wrapper used in C.  VFS
       `iVersion` bumped 1→2 so `xCurrentTimeInt64` is now reachable through
       the shared `sqlite3OsCurrentTimeInt64` chain (memdb already wraps it).

- [X] **8.x** `sqlite3OsCurrentTimeInt64` + `sqlite3OsCurrentTime` (os.c:290)
       and `sqlite3StmtCurrentTime` (vdbeapi.c:1106) — ported 2026-04-29.
       OS wrappers prefer the iVersion>=2 xCurrentTimeInt64 slot and fall back
       through xCurrentTime * 86400000.  StmtCurrentTime latches the per-Vdbe
       iCurrentTime so multiple julianday('now')/datetime('now') calls within
       one statement run observe a single timestamp; the wired chain reaches
       the existing unixCurrentTimeInt64 / memdbCurrentTimeInt64 backends.

- [X] **8.x** `sqlite3_temp_directory` / `sqlite3_data_directory` public
       extern globals + `unixTempFileInit` / `unixTempFileDir` /
       `unixGetTempname` (main.c:148/:157, os_unix.c:6262..6342) — ported
       2026-04-29.  Globals live in passqlite3util.pas and are zeroed by
       `sqlite3_shutdown` (main.c:405 parity).  unixOpen no longer rolls
       its own `/tmp/sqlite_<pid>_<seq>` name; on `zPath=nil` it routes
       through unixGetTempname which honours the application override
       global, then $SQLITE_TMPDIR / $TMPDIR (captured once at
       sqlite3_os_init via unixTempFileInit), then the static fallback
       list `/var/tmp`, `/usr/tmp`, `/tmp`, `.` — matching the C 1:1.

- [X] **8.x** `sqlite3_database_file_object` (pager.c:5090) — ported
       2026-04-29 in passqlite3pager.pas.  Walks back from any filename
       pointer inside a pager-allocated buffer to the 4-byte zero prefix,
       then reads the Pager* back-pointer that lives just before it and
       returns `pPager^.fd`.  Differential probe
       `src/tests/DiagDbFileObject.pas` opens an on-disk db, fetches the
       main filename via `sqlite3_db_filename`, and confirms the
       returned `sqlite3_file*` matches `sqlite3PagerFile` of the
       backing pager.

- [X] **8.x** Btree accessor batch — ported 2026-04-29 in
       passqlite3btree.pas: `sqlite3BtreeSchema` (btree.c:11365 — lazy
       allocation of the per-BtShared schema blob with caller-supplied
       xFree destructor; not yet wired into `openDatabase`, which still
       allocates schemas via `sqlite3SchemaGet(db, nil)`),
       `sqlite3BtreeIsInBackup` (:11339), `sqlite3HeaderSizeBtree`
       (:11538), `sqlite3BtreeSharable` (:11555),
       `sqlite3BtreeConnectionCount` (:11564).  Closes the corresponding
       symbol-gap entries from the 2026-04-28 public-API audit.

- [X] **8.x** Small pager accessor batch — ported 2026-04-29 in
       passqlite3pager.pas: `sqlite3PagerSetMmapLimit` (pager.c:3549),
       `sqlite3PagerTempSpace` (:3836), `sqlite3PagerPagenumber` (:4239),
       `sqlite3PagerIswriteable` (:6258), `sqlite3PagerRefcount` (:6826),
       `sqlite3PagerPageRefcount` (:6846).  Faithful 1:1 thin wrappers
       around the existing pcache + Pager fields; exposed for downstream
       PRAGMA / debug / btree consumers (closes the corresponding
       symbol-gap entries from the 2026-04-28 public-API audit).

- [X] **8.x** Btree pragma/transaction accessor batch — ported 2026-04-29
       in passqlite3btree.pas: `sqlite3BtreeSecureDelete` (btree.c:3177),
       `sqlite3BtreeSetAutoVacuum` (:3198), `sqlite3BtreeGetAutoVacuum`
       (:3222), `sqlite3BtreeSetMmapLimit` (:3017),
       `sqlite3BtreeSetPagerFlags` (:3036), `sqlite3BtreeSchemaLocked`
       (:11382 — no-shared-cache build → unconditional SQLITE_OK after
       enter/leave), `sqlite3BtreeBeginStmt` (:4583 — anonymous savepoint
       wrapper).  Faithful 1:1 ports of the small btree-mutex accessors
       used by PRAGMA dispatch (auto_vacuum / secure_delete /
       mmap_size / synchronous), schema-lock probing in prepare, and
       VDBE statement sub-transactions.  Closes the corresponding
       symbol-gap entries from the 2026-04-28 public-API audit.

- [X] **8.x** `sqlite3PagerOkToChangeJournalMode` (pager.c:7460) +
       `sqlite3PagerJournalSizeLimit` (pager.c:7473) — ported 2026-04-29
       in passqlite3pager.pas.  Tiny accessor pair: the first guards
       PRAGMA journal_mode writes (refuses once the pager is in
       WRITER_CACHEMOD or has a non-zero journalOff with an open jfd);
       the second is the get/set for the persistent-journal size limit
       and propagates the new ceiling into the WAL via sqlite3WalLimit.
       Both faithful 1:1 from the C, and now exposed for future PRAGMA
       wiring (the journal_size_limit / journal_mode pragma codegen
       still emits the constant default — wiring is downstream work).

- [X] **8.x** `sqlite3ReportError` / `sqlite3CorruptError` /
       `sqlite3MisuseError` / `sqlite3CantopenError` (main.c:3957..3973) —
       ported 2026-04-29 in passqlite3main.pas.  Faithful translation of
       the four error-reporting helpers used widely from btree.c / pager.c
       when a low-level error is first detected: format
       "<zType> at line <lineno> of [<sourceid>]" via sqlite3MPrintf and
       dispatch to the configured xLog callback (sqlite3GlobalConfig.xLog),
       returning iErr unchanged so callers can write
       `return sqlite3CorruptError(__LINE__);`.

- [X] **8.x** `sqlite3_errmsg16` (main.c:2775) — ported 2026-04-29 in
       passqlite3main.pas alongside the existing `sqlite3_errmsg`.
       Faithful UTF-16 sibling: returns the static UTF-16 "out of
       memory" / "bad parameter or other API misuse" buffers on the
       error paths and routes through `sqlite3_value_text16(db^.pErr)`
       when a per-connection error value is set; inlines the
       `sqlite3OomClear` post-condition (malloc.c:854) since that
       helper has no separate Pas port.  Differential probe
       `src/tests/DiagErrMsg16.pas` confirms parity on nil-db /
       clean-db / parse-error.

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
