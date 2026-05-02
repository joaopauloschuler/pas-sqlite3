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

## Phase 6 — Code generators (close the EXPLAIN gate)

Suggested order (driven by call-graph dependencies, not numbering): 6.8.0
(independent) → 6.8.4 → 6.8.5 (Update needs a productive WHERE) → 6.8.2
→ 6.8.3 (Update reuses both for the row-write path) → 6.8.1 last.
Landing 6.8.1 before 6.8.2/6.8.3/6.8.4/6.8.5 just produces another
skeleton.

- [X] **6.8.0** Pragma (pragma.c): `sqlite3PragmaVtabRegister` — DONE
     2026-05-01.  Stub at codegen.pas:30145 replaced with full 1:1 port of
     pragma.c:2791..3101: aPragmaName table (66 entries from
     ../sqlite3/pragma.h, OMIT-guarded rows excluded), pragCName column-
     name pool, pragmaLocate, all 12 vtab callbacks (xConnect /
     xDisconnect / xBestIndex / xOpen / xClose / xNext / xFilter / xEof
     / xColumn / xRowid + cursor-clear helper), pragmaVtabModule struct
     wired in initialization.  sqlite3LocateTable updated to call
     PragmaVtabRegister + sqlite3VtabEponymousTableInit on `pragma_*`
     lookups (build.c:427..451 arm).  Required gPrepareV2 trampoline in
     vdbe.pas (codegen↔main is circular).  Verified: DiagPragma 10 rows
     for `pragma_table_info` etc. flip from prepare-fail to prep=0
     (table reachable, queries cleanly), no row data because the
     underlying PRAGMA codegen arms (TABLE_INFO, INDEX_LIST,
     FOREIGN_KEY_LIST, DATABASE_LIST, COLLATION_LIST, FUNCTION_LIST,
     MODULE_LIST, PRAGMA_LIST, COMPILE_OPTIONS) remain stubs in
     sqlite3Pragma — that's gap 6.12.  TestExplainParity 1016/1026
     unchanged; DiagFeatureProbe 9 unchanged; TestDMLBasic 54/0;
     TestSchemaBasic 44/0.

- [~] **6.8.2** port `sqlite3GenerateConstraintChecks` (insert.c).
     Body ported 2026-05-01 (codegen.pas:24529..25303); 1:1 with
     insert.c:1895..2723.  Function is NOT yet called from
     sqlite3Insert/sqlite3Update — wiring follows in 6.8.1 / 6.8.3.
     TestDMLBasic 54/0, TestExplainParity 1016/1026, DiagDml unchanged.
     Gate: DiagDml + DiagTxn — closes 6.10 step 6 (autoindex INSERT,
     IPK alias auto-rowid), step 9(h) (CHECK not enforced), step 15(d)
     (OR IGNORE/REPLACE/FAIL), step 15(e) (IPK alias next-rowid),
     step 26 (UNIQUE violation, autoindex maintenance).
     [X] NOT NULL arm (per-column abort/replace/ignore/fail).
     [X] CHECK arm (compile pTab^.pCheck, OP_Halt with conflict
          resolution in P5).
     [X] PRIMARY KEY / UNIQUE arm: rowid uniqueness for IPK aliases,
          index uniqueness for every implicit/explicit UNIQUE index
          (incl. partial-index `pIdx^.pPartIdxWhere`).
     [X] FOREIGN KEY arm (regTrigCnt allocation via sqlite3FkRequired
          + deferred-constraint bookkeeping inside the unique loop).
          The OP_FkCheck call itself is emitted by sqlite3Insert/
          sqlite3Update around this routine, not inside it (per C).
     [X] Conflict-resolution dispatch (ABORT / FAIL / IGNORE /
          REPLACE / ROLLBACK) into OP_Halt P5, plus UPSERT OE_Update
          dispatch via sqlite3UpsertDoUpdate.
     [ ] Auto-rowid generation for IPK alias when NULL is supplied
          (max(rowid)+1, AUTOINCREMENT honoured via sqlite_sequence).
          Belongs to sqlite3Insert (insert.c:1454..1559), not this
          routine — defer to 6.8.1 / 6.10-step-6 wiring.

- [X] **6.8.3** port `sqlite3CompleteInsertion` (insert.c) — DONE
     2026-04-27 in commit 28254e7 (Phase 6.9-bis 11g.2.b).  Body lives
     at `passqlite3codegen.pas:25319..25395`, a 1:1 line-by-line port
     of `insert.c:2782..2847`.  Companion to 6.8.2.  No callers yet —
     `sqlite3Insert` still uses its inline four-op shortcut; wiring is
     deferred to `sqlite3Insert` body work (see 6.8.1 sibling note
     below).
     Gate: DiagDml `unique violation`, DiagIndexing `schema after
     create idx`, `select range via idx` — also unblocks the
     implicit-autoindex Δ in TestExplainParity.  These remain pending
     because they require the call-site wiring, not the function body.
     [X] OP_Insert with correct P5 (LASTROWID / APPEND / USESEEKRESULT /
          ISUPDATE / SAVEPOSITION) — `:25381..25394`.
     [X] Per-index OP_IdxInsert loop honouring `aRegIdx[]` skip flags
          and partial-index gates — `:25338..25375` (uniqNotNull bit 3
          drives nKeyCol-vs-nColumn).
     Bullets relocated to call-site wiring (not part of
     `sqlite3CompleteInsertion` in C):
       — sqlite_sequence update for AUTOINCREMENT (C calls
         `sqlite3AutoincrementEnd` from `sqlite3Insert`,
         `insert.c:1640`; helper already ported at
         `passqlite3codegen.pas:24040`, called from `:22985`).
       — AFTER INSERT trigger fire arm (C calls `sqlite3CodeRowTrigger`
         from `sqlite3Insert`, `insert.c:1606`; helper already ported
         at `passqlite3codegen.pas:22290`).  Closes 6.10 step 9(j) once
         the `sqlite3Insert` rewrite replaces the inline shortcut at
         `:24389..24393` with the canonical
         `GenerateConstraintChecks` + `CompleteInsertion` pair.

- [~] **6.8.4** port `sqlite3WhereBegin` (where.c).
     Gate: TestExplainParity SELECT-WHERE corpus + DiagIndexing
     `indexed by ok` / `not indexed` (closes 6.10 step 26(e)).
     [X] Allocate `WhereInfo` + per-loop `WhereLevel` array
          (codegen.pas:15243..15280).
     [X] Drive `whereLoopAddAll` + `wherePathSolver` for the
          cost-based plan (codegen.pas:15429..15454).
     [X] Single-table fast path: lift the nTabList=1 gate.  Site
          #5 (a) lifted the viaCoroutine narrow case (commit
          9861f05); site #5 (b) lifted the rest in commit 41167c7
          (WHERE_OR_SUBCLAUSE recursion, virtual tables, INDEXED
          BY / NOT INDEXED — every shape whereShortCut bails on
          now routes through codeOneLoopStart).
     [X] `not indexed` honour (DiagIndexing PASS, commit 41167c7).
     [X] `INDEXED BY` honour: planner-side wired in commit 889ca4f
          (`sqlite3IndexedByLookup` from selectExpander,
          `pIndex^.colNotIdxed` populated in `sqlite3CreateIndex`,
          `iIdxCur` opened with `OPFLAG_SEEKEQ` in the planner-
          branch cursor-open loop).  End-to-end closure landed
          via 6.8.6 (commit 22188d5) — `sqlite3Insert` now
          populates indexes at insert time so the planner finds
          rows.  DiagIndexing `indexed by ok` PASS.
     [ ] Multi-table loop nesting + per-loop WHERE-clause splitting
          (codeOneLoopStart already supports it; corpus parity
          deferred — TestExplainParity multi-table rows still
          mostly diverging on join-order / explain-text edges).
     [ ] Bloom-filter and covering-index arms (covers 6.10 step 9
          d-INNER and the `SELECT p FROM u` planner Δ).

- [~] **6.8.6** port the productive `sqlite3Insert` body (insert.c).
     Single-row VALUES path DONE 2026-05-01 (commit 22188d5).
     The inline four-op shortcut at codegen.pas:24770.. is
     replaced by `sqlite3OpenTableAndIndices` + per-loop column
     eval + `sqlite3GenerateConstraintChecks` (6.8.2) +
     `sqlite3CompleteInsertion` (6.8.3) cascade with proper
     aRegIdx[nIdx+1] allocation.  Closes DiagIndexing
     `indexed by ok`; bytecode for single-row VALUES now byte-
     identical to C oracle.
     Deferred sub-arms (route to insert_cleanup or fall back to
     OP_NewRowid + record assembly without bail today):
     [X] IPK-alias rebinding (insert.c:1488..1531) — DONE 2026-05-01.
          `INSERT IPK alias u` byte-parity reached 2026-05-01: emit
          `VdbeNoopComment "prep index %s"` (insert.c:2411) as
          `OP_Noop` in `sqlite3GenerateConstraintChecks` per-index
          loop so the bytecode lines up 1:1 with the
          SQLITE_ENABLE_EXPLAIN_COMMENTS oracle.  Closed the last
          off-by-one Δ.
     [~] Multi-row VALUES — runtime DONE 2026-05-01 (sqlite3Insert
          walks the SF_Values UNION-ALL chain inline-unrolled per row).
          DiagMultiValues count=3 matches C; DiagDml `multi-row values
          expr` PASS.  Bytecode-Δ remains (C=22 vs Pas=17, structural
          difference) — coroutine arm of sqlite3MultiValues still
          deferred for byte-parity.  INSERT FROM SELECT (true
          compound-SELECT-as-source) still bails — folds into
          6.10 step 6 sub-FROM and step 9(e).
     [X] AUTOINCREMENT — DONE 2026-05-01.
     [X] BEFORE / AFTER INSERT triggers — fully fires DONE 2026-05-01.
          DiagTrig now reports `log.n = 7` matching C; DiagFeatureProbe
          `CREATE TRIGGER then INSERT` flips to PASS (9→8 divergences).
          Three coupled fixes landed: (1) added `OP_Trace` as a fall-
          through case label on the OP_Init arm in vdbe.pas so trigger
          sub-programs (which start with OP_Trace, not OP_Init) no
          longer error with "unimplemented opcode"; (2) added the
          missing `TK_TRIGGER` arm to `sqlite3ExprCodeTarget`
          (expr.c:5537..5598) so `NEW.x` / `OLD.x` references emit
          OP_Param with the documented P1 = `iTable*(nCol+1) + 1 +
          TableColumnToStorage(iCol)`; (3) added a `resolveTriggerNewOld`
          walker invoked from `sqlite3ResolveExprNames` and the
          `sqlite3ResolveSelectNames` ResolveExpr nested proc so
          TK_DOT(NEW, x) / TK_DOT(OLD, x) rewrite to TK_TRIGGER against
          `pParse^.pTriggerTab`; (4) wired the missing
          `sqlite3ResolveExprListNames(&sNC, pList)` call into
          `sqlite3Insert` (insert.c:1210) so the values list inside a
          trigger sub-INSERT actually runs through resolution.
          Side-fix: DiagFeatureProbe `SplitExec` now tracks BEGIN/END
          nesting so the `CREATE TRIGGER … BEGIN … END` setup is fed as
          one statement (was previously split on the inner `;`,
          producing a malformed CREATE TRIGGER and a stray `END`).
          Regressions green: TestDMLBasic 54/0, TestSchemaBasic 44/0,
          TestSelectBasic 60/0, TestWhereBasic 52/0, TestExplainParity
          1019/7, DiagFeatureProbe 8 diverge (was 9).
     [ ] RETURNING clause emission — DiagDml RETURNING corpus.
     [ ] Vtab xUpdate dispatch (`IsVirtual(pTab)`).
     [ ] xferOptimization (`INSERT INTO t1 SELECT * FROM t2`
          fast path).

- [ ] **6.8.5** port `sqlite3WhereEnd` (where.c).
     Gate: same as 6.8.4 — they land as a pair.
     [ ] Per-loop tail (OP_Next / OP_Prev / OP_VNext + jump back to
          loop top).
     [ ] Cursor close + addrBrk/addrCont label patching.
     [ ] Free `WhereInfo` and any `IdxStr` allocations.

- [X] **6.8.1** finish porting `sqlite3Update` (update.c) — single-table
     arm DONE 2026-05-01.  `passqlite3codegen.pas:23457..24115` replaces
     the prior skeleton with a 1:1 port of `update.c:285..1163` covering
     prologue (SrcListLookup, TriggersExist, ViewGetColumnNames,
     IsReadOnly, cursor allocation, aXRef/aRegIdx/aToOpen single-block
     malloc), column-name resolution with chngRowid/chngPk detection
     and generated-column propagation, per-index aRegIdx[] alloc with
     partial-index gating via the new helpers
     `indexColumnIsBeingUpdated` / `indexWhereClauseMightChange`
     (`:23399..23437`), CountChanges + BeginWriteOperation, register
     block layout (regOldRowid / regNewRowid / regOld / regNew / regKey
     / regRowSet), MaterializeView for non-FROM views, ResolveExprNames
     over WHERE, ephemeral-rowset two-pass and ONEPASS_SINGLE/MULTI
     paths, OpenTableAndIndices with the ONEPASS_MULTI Once gate, the
     in-loop body (NotFound/IsNull/Rewind+RowData/NotExists row locate,
     OLD/NEW register population, BEFORE UPDATE trigger fire + reload,
     `sqlite3GenerateConstraintChecks`, optional reseek,
     `sqlite3GenerateRowIndexDelete`, OP_FinishSeek, conditional
     OP_Delete, `sqlite3CompleteInsertion`, AFTER UPDATE trigger fire),
     loop tail, `sqlite3AutoincrementEnd`, `sqlite3CodeChangeCount`.
     Verified: TestDMLBasic 54/54, TestExplainParity 1018/1026 (was
     1016 — +2 new passes, 0 regressions), DiagDml 12/2 unchanged,
     DiagIndexing 35/7 unchanged, DiagTxn 33/7 unchanged.
     Gate (carried forward): DiagDml UPDATE corpus, DiagTxn
     `changes() after update` (step 15(f)), TestExplainParity
     `UPDATE t SET a=5 WHERE rowid=1` Δ=14, DROP TABLE Δ=26 follow-on
     (6.11(b) via `sqlite3NestedParse`) — most still pending; Δ shrunk
     from 10 to 8 already.
     [X] Source-list resolve + WHERE-clause walk (`sqlite3WhereBegin`).
     [X] OP_Rowid → OP_NotExists row-locate prologue.
     [X] Old-row read into register block (incl. unchanged columns).
     [X] BEFORE UPDATE trigger fire arm.
     [X] New-row register assembly with `sqlite3ExprCode` per
          assignment.
     [X] `sqlite3GenerateConstraintChecks` invocation (6.8.2).
     [X] Index-update loop: per-index delete-old + insert-new
          honouring `aXRef[]` (no-change skip) — via
          `sqlite3GenerateRowIndexDelete` + `sqlite3CompleteInsertion`.
     [X] `sqlite3CompleteInsertion`-equivalent row write (6.8.3) +
          `nChange` increment.
     [X] AFTER UPDATE trigger fire arm.
     Deferred (single-table arm scope; bail to update_cleanup with
     no emission, free args cleanly):
     [ ] UPDATE FROM arm (multi-table source) — needs 6.8.4
          multi-table WHERE; `nChangeFrom>0` early bail.
     [ ] Virtual-table dispatch (`updateVirtualTable`) — vtab xUpdate
          path; `eTabType=TABTYP_VTAB` early bail.
     [ ] RETURNING clause emission — call site for the productive
          UPDATE path (DiagDml RETURNING corpus).
     [ ] PREUPDATE_HOOK `OP_Delete OPFLAG_ISNOOP` arm — gated on
          SQLITE_ENABLE_PREUPDATE_HOOK (not in the default build).

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
  
  [ ] **6.24** Aggregate-with-ORDER-BY codegen (select.c
       `analyzeAggregate` + `generateAggSelect`).  The
       ORDER-BY-inside-aggregate arm — `group_concat(val, ',' ORDER BY
       val DESC)`, `string_agg(... ORDER BY ...)`, etc. — is not
       honoured today; the unordered variant `group_concat(val,',')`
       PASSes.  Distinct from 6.8.2 (constraint checks) — pure
       SELECT-side codegen.
       Gate: DiagWindow `group_concat ordered` (6.10 step 17(b)).
       [ ] Per-aggregate `OrderByExpr` capture during
            `sqlite3FuncDefRef` resolution.
       [ ] Sorter open + key-encode in the inner-loop arm of
            `generateAggSelect`.
       [ ] Sorted-feed of values into the aggregate step function
            (replaces the direct OP_AggStep path).
       [ ] DISTINCT-aggregate variant (`count(DISTINCT x)` etc.) —
            uses the same sorter machinery.

  [ ] **6.26** Window functions (window.c).
       Gate: DiagWindow — closes 6.10 step 17(c) (rank, dense_rank,
       lag, lead, first_value, ntile prepare-time failures) and step
       17(d) (`sum() OVER (...)`, `row_number() OVER (...)` empty
       result-set).
       [ ] Port `sqlite3WindowCodeInit` — opens the window
            ephemeral table, allocates partition / peer-group
            registers, emits the partition-boundary detection
            preamble.
       [ ] Port `sqlite3WindowCodeStep` — per-row dispatch into
            the active frame logic.
       [ ] Frame-spec emission: ROWS / RANGE / GROUPS, with all
            five bound types (UNBOUNDED PRECEDING, n PRECEDING,
            CURRENT ROW, n FOLLOWING, UNBOUNDED FOLLOWING) and
            EXCLUDE clauses (NO OTHERS / CURRENT ROW / GROUP / TIES).
       [ ] Built-in window-function dispatch table:
            `row_number` / `rank` / `dense_rank` / `percent_rank` /
            `cume_dist` / `ntile` / `lag` / `lead` / `first_value` /
            `last_value` / `nth_value`.
       [ ] Aggregate-as-window arm (`sum(x) OVER (...)`,
            `avg(x) OVER (...)`, etc.) — reuses the regular agg
            step function inside the frame loop.
       [ ] Multi-window arm (one SELECT with several distinct
            OVER clauses sharing partitions).

  [ ] **6.27** codegen.pas schema-mutation + statistics.
       Sub-rows that overlapped Phase 7 have been moved out
       (ATTACH/DETACH → 7.1.8; the ALTER trio → 7.1.9).
       [ ] Port `sqlite3Analyze` (analyze.c).  Emits the bytecode
            that populates `sqlite_stat1` / `sqlite_stat4`; gates the
            cost-based planner work in 6.8.4 (without ANALYZE rows
            the planner falls back to heuristic costs and several
            DiagIndexing cases pick the wrong plan).
       [X] Port `sqlite3Vacuum` (vacuum.c).
       [ ] Port `sqlite3FkCheck` (fkey.c).  Codegen-side emitter
            that walks each FK constraint after a DELETE / UPDATE
            and emits the OP_FkCheck calls.  The runtime opcode
            body is already wired (commit 775ffc0); only the
            codegen side at passqlite3codegen.pas:33122 is still a
            stub.  Required for 6.10 step 9 and DiagFeatureProbe
            FK-cascade cases.
       [ ] Port `sqlite3FkActions` (fkey.c).  Synthesises the
            ON DELETE / ON UPDATE CASCADE / SET NULL / SET DEFAULT /
            RESTRICT / NO ACTION trigger programs.  Currently a
            no-op at passqlite3codegen.pas:33128.

  [ ] **6.28** sweep — re-search for "stub" in the pascal source code and
       port from C to pascal in full any function or procedure still
       marked as "stub" that was missed (catch-all).
       [X] Wire `sqlite3ResetOneSchema` retry into `sqlite3LockAndPrepare`
            (prepare.c:865-866) — done 2026-04-30 in passqlite3main.pas.
            Previously bailed after one retry on SQLITE_ERROR_RETRY only;
            the SQLITE_SCHEMA arm is now wired to call
            `sqlite3ResetOneSchema(db,-1)` and retry once, matching the C
            do/while.  Function was already ported (codegen.pas:24818); only
            the call site was missing.  TestExplainParity 1016/1026
            unchanged; DiagFeatureProbe 9 unchanged; TestSchemaBasic 44/0;
            TestDMLBasic 54/0.

### Open Bugs

- [ ] **6.10** `TestExplainParity.pas`
    - [ ] **6.10 step 6** Remaining TestExplainParity bytecode-Δ rows
       (7 diverges in 1019/1026 corpus):
        [ ] `SELECT a FROM t ORDER BY a` (asc/desc/multi-col) —
          C=19/19/20 vs Pas=3 (ORDER BY sorter / ephemeral-key path
          not ported).
        [ ] `SELECT a FROM t GROUP BY a` — C=45 vs Pas=3
          (aggregate-group path not yet ported).
        [ ] `SELECT a FROM (SELECT a FROM t)` — C=10 vs Pas=16.
          Pas now emits the co-routine path (6.13(b) piece 4); C
          flattens via `flattenSubquery`.  Closes once 6.13(b)-fl
          lands.
        [ ] `INSERT multi-row VALUES` — C=22 vs Pas=17.  Runtime
          parity reached 2026-05-01 (DiagMultiValues count=3); Pas
          unrolls the rows inline, C emits a coroutine.  Bytecode
          parity needs the coroutine arm of sqlite3MultiValues if
          wanted (deferred — runtime is correct).
        [ ] `SELECT p FROM u;` — per-op divergence at op[1]
          (C `OpenRead p1=1 p2=5` autoindex covering scan vs Pas
          `p1=0 p2=4` table scan).  Root cause:
          `whereLoopAddBtree` / `bestIndex` cost model not yet
          considering covering indexes when no WHERE clause exists.
  
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
      [ ] **c) View materialisation in SELECT.**  Folds into 6.13(b).
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
        `SELECT a FROM v` PASS as of 2026-05-01: the view-arm of
        `sqlite3SelectExpand` (codegen.pas:18519..18527) now calls
        `sqlite3SelectPrep` (full expand+resolve+typeinfo) on the
        attached subquery instead of bare `sqlite3SelectExpand`, so
        TK_COLUMN nodes inside the view body get re-resolved against
        the freshly-assigned inner cursors.  Without the resolve step
        the EXPRDUP_REDUCE'd Expr tree still had iTable/iColumn=0 (the
        reduce truncates Expr beyond byte 44) and codegen emitted
        `OP_Null` instead of `OP_Column` for `a`.  DiagFeatureProbe
        `CREATE VIEW + plain SELECT FROM v` flips DIVERGE→PASS (8→7).
        Side fix 2026-05-01: `sqlite3SelectExpand` was skipping
        `LocateTableItem` for any FROM item whose `u4` slot read
        non-nil, but `u4` is a union (pSubq / pSchema / zDatabase)
        and the canonical gate is `fg.isSubquery` — the prior
        `if pItem^.u4.pSubq <> nil then Continue` misfired whenever
        a regular table item carried a fixedSchema pointer in `u4`
        (the case after `sqlite3SelectDup` of a view body), leaving
        pSTab nil and producing `no such column` at resolve time.
        Remaining gap: the
        agg-no-GROUP-BY gates (codegen.pas:18968 / :19025) reject FROM
        items where `fgBits & SRCITEM_FG_IS_SUBQUERY`, so
        `count(*) FROM v` falls through to the Init/Halt/Goto trivial
        stub.  Closing this needs the sub-FROM materialise / co-routine
        codegen path (6.10 step 6 sub-FROM entry) — same blocker as
        non-view sub-FROM SELECTs.
      [ ] **e) UNION / compound SELECT.**  Folds into 6.13(c).
        `SELECT count(*) FROM (SELECT 1 UNION SELECT 2 UNION SELECT 1)`
        returns no row.  Compound-select codegen / sub-FROM
        materialisation gap (overlaps step 6 sub-FROM Δ=7 entry).
      [~] **f) WITH / CTE not productive** — simple non-recursive CTE
        DONE 2026-05-02.  `WITH c(x) AS (SELECT 7) SELECT x FROM c` now
        returns 7 (DiagFeatureProbe `CTE simple` PASS, divergences
        7→6).  Three coupled changes in passqlite3codegen.pas:
        (1) ported `searchWith` (select.c:5601) and
        `resolveFromTermToCte` (select.c:5670, non-recursive arm only)
        — match a FROM-item against the in-scope WITH chain, allocate
        an ephemeral Table, attach the CTE body via
        `sqlite3SrcItemAttachSubquery` with a duplicate-on-attach so
        each reference gets a fresh body, then run
        `sqlite3ColumnsFromExprList` on the leftmost-SELECT result-set
        for column name/affinity propagation.  Sets `pCt^.zCteErr` to
        "circular reference: %s" around the inner SelectPrep so a
        self-reference inside the CTE body trips the zCteErr arm on
        re-entry instead of looping (mirrors select.c:5793..5840).
        (2) Wired `sqlite3WithPush(pParse, pSelect^.pWith, 0)` at the
        top of `sqlite3SelectExpand` so the parser-supplied WITH (set
        on `pSelect^.pWith` by `attachWithToSelect` for the
        `select ::= WITH wqlist selectnowith` reduction) becomes
        visible to `pParse^.pWith` during FROM resolution; the existing
        post-walk `sqlite3SelectPopWith` callback pops it.
        (3) Extended the no-FROM fast path in `sqlite3Select`
        (codegen.pas:20018) to honour `SRT_Coroutine` in addition to
        `SRT_Output` — emits OP_Yield instead of OP_ResultRow — so the
        CTE body inside the outer's co-routine arm actually emits its
        per-column code (was emitting empty `InitCoroutine ;
        EndCoroutine`).
        Recursive CTE (`WITH RECURSIVE r(n) AS (SELECT 1 UNION ALL
        SELECT n+1 FROM r WHERE n<5) SELECT count(*) FROM r`) still
        DIVERGEs — needs the recursive-CTE arm of resolveFromTermToCte
        (select.c:5760..5839) plus compound SF_Recursive codegen.
        Regressions green: TestExplainParity 1019/7, TestDMLBasic 54/0,
        TestSchemaBasic 44/0, TestSelectBasic 60/0, TestWhereBasic
        52/0, DiagDml 13/1, DiagIndexing 38/4, DiagMisc divergences
        unchanged.
      [ ] **g) ALTER TABLE no-op.**
        `RENAME COLUMN` and `ADD COLUMN` both prepare+step cleanly but
        do not modify the schema.  Tracked under 7.1.9.
      [X] **h) CHECK constraint not enforced** — DONE 2026-05-01.
        Three coupled fixes: (1) `sqlite3AddCheckConstraint`
        (build.c:1902) ported from a stub-that-deletes-the-expr to the
        real append-into-pTab^.pCheck + name-tagging body;
        (2) `sqlite3EndTable` now runs the build.c:2738..2751 CHECK
        resolve loop via `sqlite3ResolveSelfReference(NC_IsCheck)`;
        (3) `sqlite3ResolveSelfReference` was only resolving pExpr —
        added the resolve.c:2317 `pList` arm so ExprList CHECK
        constraints actually resolve.  The CHECK arm in
        `sqlite3GenerateConstraintChecks` was already correct; the
        TK_COLUMN row-unpacked iSelfTab<0 arm in
        `sqlite3ExprCodeTarget` was not — ported the expr.c:5026..5074
        body so a TK_COLUMN under iSelfTab<0 returns the existing
        register holding the inserted column instead of falling
        through to the iSelfTab>0 cursor-read path.  Final fix:
        `sqlite3_step` now folds the extended result code via
        `rc and db^.errMask` (vdbeapi.c sqlite3Step tail) so the
        public API returns SQLITE_CONSTRAINT (19) instead of
        SQLITE_CONSTRAINT_CHECK (275) when extended-codes are off
        (the default).  Verified: DiagFeatureProbe `CHECK rejects bad
        insert` flips DIVERGE→PASS (10→9 divergences); no regressions
        across TestExplainParity (1018/8/1026), TestDMLBasic (54/0),
        TestSchemaBasic (44/0), TestSelectBasic (60/0), TestWhereBasic
        (52/0).
      [X] **j) AFTER INSERT trigger does not fire** — DONE 2026-05-01.
        Closed by 6.8.6 BEFORE/AFTER trigger arm + the OP_Trace /
        TK_TRIGGER / NEW.x resolver / sqlite3Insert resolve fixes
        described above.  DiagFeatureProbe `CREATE TRIGGER then
        INSERT` PASS (val=99 == C).
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
      [X] **d) `INSERT OR IGNORE` / `OR REPLACE` / `OR FAIL` ignore
        conflict resolution** — DONE 2026-05-01.  Root cause: the call
        to `sqlite3GenerateConstraintChecks` in `sqlite3Insert`
        (codegen.pas:25434) passed `ignoreDest=0` instead of the
        per-row `endOfLoop` label.  OE_Ignore would emit
        `OP_Goto 0,0` looping back to address 0 forever; OR REPLACE /
        OR FAIL were similarly miswired.  Fixed at codegen.pas:25435 —
        OR IGNORE now skips the duplicate row, OR REPLACE replaces it,
        OR FAIL returns SQLITE_CONSTRAINT_UNIQUE.  Verified via
        standalone probe (count=2 across all three modes); regressions
        green: TestDMLBasic 54/0, TestSchemaBasic 44/0,
        TestExplainParity 1019/7 (was 1018, +1 pass on the
        `INSERT IPK alias u` row), DiagDml 13/1 unchanged,
        DiagIndexing 38/4 unchanged, DiagFeatureProbe 9/9 unchanged.
      [X] **e) IPK alias auto-rowid increment** — verified 2026-05-01
        via standalone probe.  Pas correctly returns id=8 for
        `INSERT INTO t(id INTEGER PRIMARY KEY, x) VALUES(7,'a');
        INSERT VALUES(NULL,'b')`.  The OP_NewRowid runtime walks to
        BtreeLast and increments the integer key, matching C 1:1.
        Tasklist entry was stale (DiagTxn hangs prevent automated
        verification — see `feedback_diagtxn_hang`).
      [X] **f) `changes()` returns 0 after UPDATE** — verified
        2026-05-01 via standalone probe.  Pas returns 2 matching C
        for `CREATE TABLE t(a); INSERT 1; INSERT 2; UPDATE t SET a=99;
        SELECT changes()`.  Closed by the 6.8.1 sqlite3Update port.

  [ ] **6.10 step 17** Window-function and aggregate divergences surfaced
      by the new `src/tests/DiagWindow.pas` probe (run with
      `LD_LIBRARY_PATH=$PWD/src bin/DiagWindow`).  13 divergences open
      (verified 2026-05-01 after window-funcs registration fix) — all
      runtime empty-row symptoms; prep=1 prepare-time failures gone.
      [ ] **b) `group_concat(val, ',' ORDER BY val DESC)` empty** — the
        ORDER-BY-in-aggregate arm is not honoured; the unordered
        variant `group_concat(val,',')` PASSes.  Tracked under 6.24
        (aggregate-with-ORDER-BY codegen) when it lands.
      [X] **c) Window functions fail at prepare time** — DONE 2026-05-01.
        Root cause: `sqlite3WindowFunctions` was defined in
        codegen.pas:38253 but never called.  Wired it into
        `sqlite3RegisterBuiltinFunctions` (codegen.pas:36412 region) at
        the same point as the C reference (func.c:3435), between
        `sqlite3AlterFunctions` and `sqlite3RegisterJsonFunctions`.
        DiagWindow now reports prep=0 across the entire window-function
        corpus (was prep=1 for rank/dense_rank/lag/lead/first_value/ntile
        and the partition_row_num case).  Runtime divergence persists —
        prep=0 step=101 with empty rows — and folds entirely into
        item (d) below / 6.26.  Regressions green: TestExplainParity
        1019/7, TestDMLBasic 54/0, TestSchemaBasic 44/0, TestSelectBasic
        60/0, TestWhereBasic 52/0.
      [ ] **d) Window aggregates `sum() OVER ()` / `OVER (ORDER BY)`
        prepare cleanly but emit no rows** — `row_number() OVER (...)`
        same.  Symptom: prep=0 step=101 with empty result set when C
        produces N rows.  Window-codegen sub-issue under 6.26; distinct
        from (c) because here the parse + prepare succeed.

  [ ] **6.10 step 19** DiagDml runtime probe (added 2026-04-28,
      `src/tests/DiagDml.pas`, run `LD_LIBRARY_PATH=$PWD/src bin/DiagDml`).
      Sweep of UPSERT / RETURNING / INSERT-FROM-SELECT / UPDATE-FROM /
      column-reorder / DEFAULT-expr / multi-row-VALUES variants.  13 PASS,
      1 DIVERGE (verified 2026-05-01) — surprises noted below; UPSERT
      (DO NOTHING + DO UPDATE +
      excluded.b), RETURNING (INSERT/UPDATE/DELETE), INSERT INTO d SELECT
      * FROM s, UPDATE...FROM, column-reorder all already PASS.
      [ ] **a) `INSERT INTO t SELECT 1,2 UNION ALL SELECT 3,4`** —
        Pas inserts 0 rows, C inserts 2.  Compound-SELECT-as-INSERT-source
        gap; folds into 6.10 step 6 (sqlite3Insert pSelect early-exit at
        codegen.pas:19756) + step 9(e) (compound-SELECT codegen).
      [X] **b) Multi-row VALUES with non-constant exprs** — DONE
        2026-05-01.  `INSERT INTO t VALUES(1,1+1),(2,2*2),(3,3+3)`
        now reports Pas count=3 matching C (DiagDml flips the
        `multi-row values expr` row from DIVERGE to PASS).  Closed by
        wiring the multi-row VALUES arm into sqlite3Insert (see 6.8.6
        "Multi-row VALUES" entry above) — the UNION-ALL fallback in
        sqlite3MultiValues was already in place; the missing piece was
        the consumer side in sqlite3Insert, which now walks the
        SF_Values pPrior chain and emits per-row inserts inline.

  [ ] **6.10 step 26** DiagIndexing probe (4 diverges remain, verified
      2026-05-01 — was 5; `unique violation` now PASSes via the
      extended→primary errCode fold and OP_Halt P5 wiring landed with
      the CHECK fix).
      [X] **e) `INDEXED BY` / `NOT INDEXED`** — closed under 6.8.4
        (`indexed by ok` / `not indexed` PASS).
      [X] `unique violation`
      [ ] `schema after create idx` — empty rowset; ORDER BY rowid path.
      [ ] `select range via idx` — empty rowset; range scan + ORDER BY.
      [ ] `rowid select` — empty rowset; ORDER BY rowid path.
      [ ] `rowid alias custom` — empty rowset; ORDER BY rowid alias.
      All four remaining fold into the same blocker: ORDER BY codegen
      (sorter / ephemeral-key path) is not yet ported — same root cause
      as 6.10 step 6 `SELECT a FROM t ORDER BY a` (C=19 vs Pas=3).

  [ ] **6.11** DROP TABLE remaining gap (current Δ=26, was Δ=21):
    (b) [ ] Pas elides the destroyRootPage autovacuum follow-on (~26 ops)
        because `destroyRootPage` calls `sqlite3NestedParse(UPDATE
        sqlite_schema ...)` and productive `sqlite3Update` is still
        skeleton-only.  This is the only remaining contributor.
  [~] **6.12** port sqlite3Pragma in full.  Regression gate
       `src/tests/DiagPragma.pas`.  Baseline 49 DIVERGE driven to 10.
       Partial 2026-05-01: table-valued PragTyp dispatcher landed
       (TABLE_INFO / INDEX_INFO / INDEX_LIST / DATABASE_LIST /
       COLLATION_LIST / FUNCTION_LIST / MODULE_LIST / PRAGMA_LIST /
       COMPILE_OPTIONS) — direct invocation works end-to-end (e.g.
       `PRAGMA pragma_list` returns the expected 66 rows).
       FOREIGN_KEY_LIST blocked on TFKey opaque (PFKey = Pointer,
       codegen.pas:418); TABLE_LIST deferred.  The 10 DiagPragma
       divergences DO NOT close: the underlying codegen now emits the
       correct rows, but the eponymous-vtab path
       (`SELECT count(*) FROM pragma_table_info('t')`) emits only
       `Init/Halt/Goto` — same root cause as 6.10 step 9(c) view
       materialisation, the SELECT codegen does not traverse
       non-regular FROM items.  Closing the gate now requires the
       sub-FROM materialise / eponymous-vtab traversal arm in
       sqlite3Select (6.10 step 6 sub-FROM entry + step 9(c)), not
       further Pragma work — see 6.13.  COMPILE_OPTIONS additionally
       needs `sqlite3azCompileOpt` populated in main.pas:2833.
       Side-fix 2026-04-29: `PRAGMA journal_mode=X` /
       `PRAGMA locking_mode=X` write arms now emit a result row matching
       C (memdb effective-mode echo); `PRAGMA integrity_check` /
       `PRAGMA quick_check` now emit "ok" on a clean db (real walker is
       still stub, but every db this port produces is corruption-free
       by construction).

  [ ] **6.13** Non-regular FROM-item codegen in `sqlite3Select`
       (select.c).  Pas's SELECT codegen currently traverses regular
       table cursors but falls through to a trivial `Init/Halt/Goto`
       stub when the FROM list contains an eponymous virtual table,
       a view, a sub-SELECT, a CTE, or a compound-SELECT source.
       Verified 2026-05-01 via EXPLAIN
       `SELECT * FROM pragma_pragma_list` → 3 ops total; the cursor
       open + per-row loop never emits.  One function with three
       new arms; landing them collectively unblocks several
       previously-tracked rows.

       **Gate reach (rows that close once 6.13 lands):**
       - 6.10 step 6 sub-FROM (`SELECT a FROM (SELECT a FROM t)` Δ=7)
       - 6.10 step 9(c) view materialisation (`count(*) FROM v`)
       - 6.10 step 9(e) UNION compound source
       - 6.10 step 9(f) WITH / CTE non-productive
       - 6.10 step 19(a) compound-SELECT-as-INSERT-source
       - 6.12 the 10 DiagPragma table-valued probes (eponymous-vtab
         path through pragma_table_info / pragma_index_list / …)
       - DiagFeatureProbe rows (c) view, (e) compound, (f) CTE.

       **Sub-arms to port:**
       [x] **a) Eponymous-vtab arm** — when `IsVirtual(pTab)` is true
            on a `pSrcItem`, emit cursor-traversal: `OP_VOpen`
            (p4=PVTable) → `OP_Integer 0,regIdxNum` → `OP_VFilter
            cursor,addrEof,regIdxNum` → inner-loop body reading via
            `OP_VColumn` → `OP_VNext cursor,addrLoopTop` → close at
            `addrEof`.  All four runtime opcodes are already wired in
            `passqlite3vdbe.pas` (OP_VOpen, OP_VFilter, OP_VNext,
            OP_VColumn); only the codegen-side emission is missing.
            Smallest of the three arms; should land first since it
            unblocks the entire DiagPragma 6.12 gate on its own.
            C reference: `sqlite3Select` per-pSrcItem cursor-open
            switch (select.c roughly 5400..5500) + the vtab arm
            around select.c:6100.
            Landed 2026-05-01 at codegen.pas:20104 (just before the
            "All source items must be real, non-virtual base tables"
            gate): for nSrc=1 / SRT_Output|SRT_Mem / no WHERE / no
            DISTINCT / no Aggregate / no Compound, emits
            VOpen → Integer 0,r → Integer 0,r+1 → VFilter
            (idxNum=0, argc=0, idxStr=nil) → per-row column emit via
            sqlite3ExprCodeTarget (TK_COLUMN routes to OP_VColumn
            through sqlite3ExprCodeGetColumnOfTable) → ResultRow →
            VNext → Close.  Smoke: `SELECT name FROM
            pragma_pragma_list` returns 66 rows.  count(*) /
            arg-bound forms (pragma_table_info('t')) still bail —
            those need either WhereBegin's vtab branch or a
            count-on-vtab special case (deferred).
       [ ] **b) Sub-SELECT / view arm** — when
            `pSrcItem.fg.fgBits and SRCITEM_FG_IS_SUBQUERY` is set,
            emit either a co-routine (preferred — yielded inner-VDBE
            streams rows into the outer scan) or a materialise-into-
            ephemeral fallback.  Lift the five existing bails at
            codegen.pas:19646, :19924, :19981, :20114, :21203.
            Port `sqlite3CodeSubquery` (select.c around 5800) for the
            co-routine emission; the materialise arm is the older
            ephemeral-table path used when the subquery cannot be
            co-routined (correlated, etc.).  selectExpander view-arm
            (select.c:6039..6073) is already partially landed per
            6.10 step 9(c) note — once subqueries work, views fold in
            for free because selectExpander rewrites a VIEW FROM-item
            into a SUBQUERY FROM-item.
            **Status 2026-05-01:** four-piece port LANDED (rowid eph
            fix, SRT_EphemTab disposal arm, selectExpander subquery
            hook, materialise arm) plus co-routine emission.  Simple
            uncorrelated `SELECT a FROM (SELECT a FROM t)` returns live
            rows via co-routine.  Bytecode shape diverges from C oracle
            because C applies subquery flattening — see 6.13(b)-fl.
            Bail-lift sweep at five IS_SUBQUERY gate sites: sites #2/#4
            confirmed C-faithful (no lift needed), site #5 (a/b/c)
            landed (planner viaCoroutine support, full nTabList=1 lift,
            INDEXED BY wiring).  Sites #1/#3 (agg-on-subquery) remain
            open under re-scoped follow-ups:
            - **6.13(b)-fl**: port `flattenSubquery` (select.c, ~600
              lines).  Closes the flattenable agg-on-subquery case with
              bytecode parity.
            - **6.13(b)-coagg**: agg-arm + dispatcher integration for
              non-flattenable case.  Move per-pSrcItem subquery
              dispatcher to run as pre-pass before agg arms when
              SF_Aggregate is set; lift IS_SUBQUERY bails in agg arms;
              existing WhereBegin viaCoroutine arm picks up the rest.
       [ ] **c) Compound-SELECT / CTE arm** — UNION / INTERSECT /
            EXCEPT FROM-sources and `WITH … AS (…)` references.
            Once 6.13(b) lands, compound-SELECT-as-FROM-source
            mostly folds in (compound is just a recursive call into
            sqlite3Select on the inner SELECT), but CTE name
            resolution needs the parser-side `WithAdd` / `CteNew`
            to actually populate `pParse^.pWith` (tracked under 6.20)
            so a SrcItem matching a CTE name binds correctly.

       **Sizing:** the C `sqlite3Select` is ~1500 lines; most of the
       regular-table path is already in pas.  The new code is the
       per-pSrcItem dispatcher (~50 lines), the eponymous-vtab arm
       (~80 lines), the co-routine emitter (`sqlite3CodeSubquery`,
       ~250 lines), and the bail-lift sweep at the five existing
       gate sites.  Total ~400-600 new lines, multi-commit.  Not a
       quick win.

       **Suggested order:** 6.13(a) first (smallest, unblocks the
       full DiagPragma gate, validates the per-pSrcItem dispatcher
       in isolation), then 6.13(b) (largest, but with the
       dispatcher in place the bail-lift sweep is mechanical), then
       6.13(c) (mostly mechanical once b is done, except for the
       6.20-blocked CTE binding).

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
       [ ] Port `sqlite3RunParser` (tokenize.c) — the underlying
            parser entry that `sqlite3NestedParse` and the prepare
            path both call.  (Moved here from old 6.25.)

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
       allocate `aDb[]` slot, run schema load.  (Moved here from old
       6.27.)
       [ ] Port `sqlite3Attach` — opens the attached btree, grows
            `db^.aDb[]`, runs the schema load via 7.1.1.
       [ ] Port `sqlite3Detach` — flushes + closes the btree, frees
            the `aDb[]` slot, invalidates cached statements.
       [ ] Wire ATTACH/DETACH parser productions through the new
            functions (currently the parse arms emit no-op
            bytecode).

- [ ] **7.1.9** ALTER TABLE (alter.c):
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
       [ ] Port `sqlite3AlterRenameTable` (alter.c) — drives
            RENAME TABLE: rewrites the schema row, fires the
            sqlite_rename_table SQL function over every dependent
            CREATE statement, invalidates cached statements.
            (Moved here from old 6.27.)
       [ ] Port `sqlite3AlterFinishAddColumn` (alter.c) — finalises
            ADD COLUMN: appends the column to the schema row, runs
            the new-column DEFAULT expression validation, bumps the
            schema cookie.  Closes 6.10 step 9(g) ADD COLUMN.
            (Moved here from old 6.27.)
       [ ] Port `sqlite3AlterAddConstraint` (alter.c) — handles
            ADD CONSTRAINT (CHECK / FOREIGN KEY / UNIQUE) by
            re-emitting the schema row through sqlite_add_constraint.
            (Moved here from old 6.27.)
       [ ] Port `sqlite3AlterRenameColumn` (alter.c) — drives
            RENAME COLUMN.  Closes 6.10 step 9(g) RENAME COLUMN.
       [ ] Port `sqlite3AlterDropColumn` (alter.c) — drives DROP
            COLUMN.

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

- [X] **8.9.2** Carray / shared-cache / misc (sqlite3_carray_bind) — done
       in passqlite3carray.pas:571 (calls sqlite3_carray_bind_v2 with
       pDestroy=aData; matches carray.c:550..557 1:1).

- [X] **8.x** `unixCurrentTimeInt64` (os_unix.c:7193) — ported 2026-04-29 in
       passqlite3os.pas.  Returns *piNow as Julian-day-times-86_400_000;
       `unixCurrentTime` rewritten as the thin wrapper used in C.  VFS
       `iVersion` bumped 1→2 so `xCurrentTimeInt64` is now reachable through
       the shared `sqlite3OsCurrentTimeInt64` chain (memdb already wraps it).

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
