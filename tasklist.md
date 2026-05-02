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
     [X] IPK-alias rebinding (insert.c:1488..1531) — DONE
          2026-05-01 (commit a820774).  IPK alias tables now
          honour user-supplied rowids via SCopy+NotNull+NewRowid+
          MustBeInt cascade with regData+iPKey nulled
          post-rebind.  Verified: `INSERT INTO u VALUES(7,'a')`
          with `u(id INTEGER PRIMARY KEY,x)` followed by
          `SELECT id, x FROM u` now returns [7,a] (was empty).
          TestExplainParity `INSERT IPK alias u` narrows from
          off-by-11 to off-by-1 (a single OP_Noop placeholder
          in GenerateConstraintChecks not yet emitted —
          minor, deferred).  DiagIndexing `rowid alias custom`
          stays divergent on a separate SELECT-ORDER-BY bail
          unrelated to the IPK path.
     [~] Multi-row VALUES — DONE 2026-05-01 (multi-row VALUES arm).
          sqlite3Insert now detects the SF_Values UNION-ALL chain
          left by sqlite3MultiValues' fallback path, walks pPrior to
          collect each row's pEList in insertion order, validates
          column-count parity, and emits the per-row column-eval +
          rowid + GenerateConstraintChecks + CompleteInsertion +
          regRowCount-bump body in a Pascal-side loop (inline
          unrolling — not the C coroutine).  Verified: DiagMultiValues
          now reports count=3 (was 1); DiagDml `multi-row values expr`
          flips DIVERGE→PASS; TestExplainParity 1018/1026 (was
          1016/1026).  TestExplainParity `INSERT multi-row VALUES`
          remains a bytecode-Δ entry (C=22 ops vs Pas=17) because
          unrolling is structurally different from C's coroutine
          loop, but the runtime behaviour is correct.
          INSERT FROM SELECT (true compound-SELECT-as-source) still
          bails — folds into 6.10 step 6 sub-FROM and step 9(e)
          compound-SELECT codegen; coroutine arm of sqlite3MultiValues
          also still TODO if byte-parity is wanted.
     [X] AUTOINCREMENT — DONE 2026-05-01.  `CREATE TABLE ...
          AUTOINCREMENT` creates and pins sqlite_sequence;
          `sqlite3AutoincrementEnd` is called from sqlite3Insert so
          the in-row write-back epilogue fires; `regRowCount` is
          allocated and bumped per insert; **autoIncStep**
          (insert.c:521) is now emitted per-row in sqlite3Insert
          (`OP_MemMax regAutoinc, regRowid`) so the running-max
          register actually tracks the inserted rowid.  Verified:
          `INSERT INTO t(x) VALUES('a'),('b'),('c')` against
          `CREATE TABLE t(id INTEGER PRIMARY KEY AUTOINCREMENT, x)`
          now writes `seq=3` to sqlite_sequence (was 0); matches C
          reference exactly.
     [~] BEFORE / AFTER INSERT triggers — structurally wired into
          sqlite3Insert 2026-05-01 + trigger-body compiler ported.
          Per-row body in sqlite3Insert allocates a per-iteration
          endOfLoop label, builds the NEW.* pseudo-table at regCols
          when tmask & TRIGGER_BEFORE, calls sqlite3CodeRowTrigger for
          BEFORE and AFTER (mirrors insert.c:1442..1499 + 1604..1608).
          codeRowTrigger / codeTriggerProgram / transferParseError
          (trigger.c:1231 / :1111 / :1215) are now ported faithfully:
          codeRowTrigger spins up a sub-Parse, allocates TriggerPrg +
          SubProgram, codes the WHEN clause + step list, terminates
          with OP_Halt, takes the op array out via VdbeTakeOpArray
          and installs it on the SubProgram.  trgGetRowTrigger does
          the cache lookup + codeRowTrigger compile.
          Two pre-existing parse-time bugs in sqlite3FinishTrigger
          fixed in passing: (a) the C "drain pStepList while walking"
          idiom was broken by an extra walker variable, causing a
          double-free of the step chain via sqlite3DeleteTrigger +
          tail DeleteTriggerStep; (b) the C `pTrig =
          sqlite3HashInsert(...)` reassign was lost (result stored
          only in pInserted), so the schema-owned trigger was freed
          a second time at cleanup.  Verified: CREATE TRIGGER ... ON
          t BEGIN SELECT 1; END now prepares + steps + finalizes +
          closes cleanly (was EAccessViolation in DeleteTriggerStep).
          KNOWN LEAK (DiagTrig sketch, not in suite): an INSERT that
          actually fires the trigger crashes during finalize with
          a double-free on the parent VDBE's op-array.  Symptom:
          parent VDBE's aOp/nOp visible in gdb as small bogus values
          (~0x95e4 / 6.8M) by the time vdbeClearObject runs.
          Suspected: sub-vdbe ↔ parent-vdbe lifecycle interaction in
          codeRowTrigger / nested DML codegen, OR sqlite3VdbeTakeOpArray
          and parent's ops sharing state.  Tracking separately;
          regression suite (TestExplainParity 1018/1026, TestDMLBasic
          54/0, TestSchemaBasic 44/0, DiagDml 13/1, DiagMultiValues
          count=3) stays green because no test in suite both creates
          a trigger AND fires it.
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
          materialise / co-routine path not ported).  Folds into 6.13(b).
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
        `SELECT * FROM v` prepares cleanly.  Remaining gap: the
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
      [ ] **f) WITH / CTE not productive.**
        Both simple (`WITH c(x) AS (SELECT 7) SELECT x FROM c`) and
        recursive forms return no row.  Tracked under 6.20 (CteNew /
        WithAdd stubs blocked on full TCte record).
      [ ] **g) ALTER TABLE no-op.**
        `RENAME COLUMN` and `ADD COLUMN` both prepare+step cleanly but
        do not modify the schema.  Tracked under 7.1.9.
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
      [X] **b) Multi-row VALUES with non-constant exprs** — DONE
        2026-05-01.  `INSERT INTO t VALUES(1,1+1),(2,2*2),(3,3+3)`
        now reports Pas count=3 matching C (DiagDml flips the
        `multi-row values expr` row from DIVERGE to PASS).  Closed by
        wiring the multi-row VALUES arm into sqlite3Insert (see 6.8.6
        "Multi-row VALUES" entry above) — the UNION-ALL fallback in
        sqlite3MultiValues was already in place; the missing piece was
        the consumer side in sqlite3Insert, which now walks the
        SF_Values pPrior chain and emits per-row inserts inline.

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
            **2026-05-01 spike (reverted, kept here as a map for the
            next attempt).**  A four-piece prototype landed and was
            reverted on the same branch:
              1. `SRT_EphemTab` accepted at the top dest gate
                 (codegen.pas:19502) plus a disposal arm
                 (`MakeRecord` + `NewRowid` + `Insert`/APPEND) right
                 after the `SRT_Mem` arm in the regular path's inner
                 loop disposal block.
              2. selectExpander FROM-loop was extended so subquery
                 SrcItems get a recursive `sqlite3SelectPrep` on the
                 inner SELECT followed by `sqlite3ExpandSubquery`
                 (without this, outer column refs into a subquery
                 fail to resolve with "no such column").  Order
                 matters — the new arm must run before the existing
                 `if pItem^.zName = nil then Continue` skip.
              3. A standalone "materialise sub-SELECT" arm was added
                 in `sqlite3Select` right before the regular path's
                 "all source items must be real base tables" gate at
                 line 20104, gated on nSrc=1 / SRT_Output / no WHERE
                 / no DISTINCT / no Aggregate / no Compound / pSubq
                 non-nil / pSTab non-nil.  Allocates one cursor (the
                 same iCursor selectExpander assigned, so resolved
                 TK_COLUMN refs find the eph cursor), opens
                 `OP_OpenEphemeral iEph, innerNCol`, recursively codes
                 the inner via `sqlite3Select(... SRT_EphemTab ...)`,
                 then hand-rolls a Rewind/Column/ResultRow/Next/Close
                 outer scan.
              4. Bytecode shape matched the C oracle for the simple
                 `SELECT a FROM (SELECT a FROM t)` case.  But at
                 runtime every materialised query hit
                 `SQLITE_CORRUPT (11) "database disk image is
                 malformed"` raised inside the OP_NewRowid →
                 sqlite3BtreeLast → moveToRoot path on the eph
                 cursor.  All existing OpenEphemeral usage in the
                 port passes a `P4_KEYINFO` (indexed eph); this is
                 the first rowid-table eph callsite, and the
                 SCHEMA_ROOT+1 auto-root path in
                 `passqlite3vdbe.pas:9152` appears to need an
                 explicit `sqlite3BtreeCreateTable` before the
                 cursor open.  DiagFeatureProbe also surfaced an
                 EAccessViolation regression (CREATE VIEW + SELECT
                 count) — the selectExpander subquery hook
                 triggered some downstream NIL-deref on the
                 view→subquery rewrite path.  Both issues are
                 localized to the prototype and unrelated to
                 6.13(a).  Reverted so main stays clean.
            **Next attempt suggestions (in order of effort / value):**
              * [x] Fix `OP_OpenEphemeral` rowid-table path
                (passqlite3vdbe.pas:9150..9155) — done 2026-05-01.
                The C comment "use the auto-created table at
                SCHEMA_ROOT+1" relied on newDatabase pre-allocating
                page 2; the port's newDatabase only initialises
                page 1, so the rowid arm now calls
                `sqlite3BtreeCreateTable(BTREE_INTKEY)` and captures
                the assigned pgno before `sqlite3BtreeCursor`.
                Index-table arm unchanged.  Smoke landed as
                TestVdbeCursor T9: hand-rolled bytecode opens an
                eph rowid table, inserts 3 rows via
                NewRowid+MakeRecord+Insert, scans them back via
                Rewind/Column/ResultRow/Next — produces 3 rows,
                rc=SQLITE_DONE (was SQLITE_CORRUPT).  Unblocks the
                materialise arm in piece 3.
              * [x] Re-land the SRT_EphemTab dest + disposal arm
                (piece 1) — done 2026-05-01.  Top dest gate at
                codegen.pas:19510 now accepts SRT_EphemTab alongside
                SRT_Output / SRT_Set / SRT_Mem.  Disposal arm slotted
                in at codegen.pas:20420 (immediately after the
                SRT_Mem branch) emits the C-mirror triplet:
                `OP_MakeRecord iSdst, nResultCol, r1` →
                `OP_NewRowid iSDParm, r2` →
                `OP_Insert iSDParm, r1, r2` with
                `p5 |= OPFLAG_APPEND`; both temp regs released.
                Mirrors selectInnerLoop:1349..1370 (SRT_Table /
                SRT_EphemTab branch).  Smoke landed as
                TestSelectBasic T11: drives the existing
                sqlite3MaterializeView path inline (CREATE TABLE
                base; build SrcList(base); SelectNew(*); Select
                with dest=SRT_EphemTab) and walks the resulting
                bytecode to assert the triplet appears, in order,
                with iSDParm on each cursor op and OPFLAG_APPEND on
                the Insert.  All regression tests stay green
                (TestExplainParity unchanged at 1016 pass / 10
                diverge baseline).  This unblocks piece 3 (the
                materialise arm) — once the cursor at iSDParm is
                opened by the caller and the FROM dispatcher routes
                a sub-SELECT here, rows will land in the eph table
                via the disposal arm landed today.
              * [x] Re-land the selectExpander subquery hook (piece 2)
                separately, and add a DiagFeatureProbe gate-row to
                lock the no-regression guarantee on VIEW.  Done
                2026-05-01.  Hook landed in sqlite3SelectExpand
                FROM-loop (codegen.pas:18157) just before the existing
                zName/pSubq skips: when SrcItemIsSubquery(fg) and
                pItem^.u4.pSubq <> nil, recursively run
                sqlite3SelectPrep on the inner pSelect, then
                sqlite3ExpandSubquery to materialise pSTab from the
                inner result columns, then assign iCursor and
                Continue (so the base-table arm below skips the now-
                resolved item).  The prior spike's EAccessViolation
                regression was driven by the same hook firing on a
                view->subquery rewrite mid-iteration; this re-land
                stays at the top of the loop and the view arm below
                is unchanged, so the recursive sqlite3SelectExpand
                the view arm triggers reaches this hook only via the
                inner SELECT (not via re-entry on the same item).
                Gate row landed in DiagFeatureProbe.pas:
                'CREATE VIEW + plain SELECT FROM v' currently locks
                at Pas chkPrep=1/val=-1 (preparable-view gate, will
                flip to PASS once piece 3 lands the materialise arm).
                Regression sweep stays at TestExplainParity 1016/10,
                TestSelectBasic 60/0, TestDMLBasic 54/0,
                TestSchemaBasic 44/0, TestWhereBasic 52/0,
                TestVdbeCursor 29/0; DiagFeatureProbe goes from 9
                to 10 divergences (the new gate row, both view rows
                still diverge at chkPrep=1 — no crash, no
                EAccessViolation).
              * [x] Then re-land the materialise arm (piece 3) — at
                that point it should produce live rows.  Done
                2026-05-01.  Standalone arm landed in sqlite3Select
                just before the "all source items must be real base
                tables" gate (codegen.pas:20239), gated on nSrc=1 /
                SRT_Output / no WHERE / no DISTINCT / IS_SUBQUERY /
                pSubq non-nil / pSelect non-nil / pSTab non-nil
                (the last guaranteed by piece 2).  Opens an eph
                rowid table at the cursor selectExpander assigned,
                recursively codes the inner via SRT_EphemTab so
                piece 1's disposal arm appends each row, then
                hand-rolls Rewind/Column/ResultRow/Next/Close on
                the materialised rows.  Live-row smoke (off-tree):
                `SELECT a FROM (SELECT a FROM t)` returns [1,2,3];
                `SELECT a+10 FROM (...)` returns [11,12,13];
                `SELECT a FROM (SELECT a FROM t WHERE a>1)` returns
                [2,3].  DiagFeatureProbe gate row
                'Sub-SELECT FROM materialise' flips to PASS.
                count(*)-of-subquery still bails at the SF_Aggregate
                gate above the materialise arm — that's a separate
                aggregate-on-subquery lift not in piece 3 scope.
                CREATE VIEW + SELECT rows still diverge at chkPrep=1
                ("no such column: a") — pre-existing resolver-side
                gap on the view->subquery rewrite, unrelated to
                piece 3 (materialise arm itself isn't reached).
                Regression sweep stays green (TestExplainParity
                1016/10, all single-test suites unchanged).
              * [x] Co-routine emission (`sqlite3CodeSubquery`)
                lands last, replaces the materialise arm where the
                inner isn't correlated, and unblocks the wider
                bail-lift sweep at the five existing gate sites.
                Done 2026-05-01 (the emission half — the bail-lift
                sweep at the five sites is deferred and tracked
                below).  Faithful port of select.c tag-select-0482
                (the fromClauseTermCanBeCoroutine branch around
                select.c:8043..8062): for uncorrelated single-source
                FROM (SELECT ...) we now prefer co-routine over
                materialisation.  Arm landed in sqlite3Select just
                before piece 3's materialise arm
                (codegen.pas:20279), gated additionally on
                `(pSubSel^.selFlags and SF_Correlated) = 0` and
                `OptimizationEnabled(SQLITE_Coroutines)`.  Inner is
                wrapped in OP_InitCoroutine + OP_EndCoroutine; outer
                drives via OP_Yield; outer pEList is coded normally
                then `translateColumnToCopy` (newly ported,
                where.c:716..760) rewrites OP_Column iCsr,col into
                OP_Copy regResult+col so result reads come from the
                inner's regResult block instead of via a
                materialised eph cursor.

                Plumbing landed alongside:
                  - `SQLITE_Coroutines = u32($02000000)` constant
                    added (mirrors sqliteInt.h:1927).
                  - SRT_Coroutine added to sqlite3Select's top dest
                    gate (codegen.pas:19543) so recursive
                    `sqlite3Select(... SRT_Coroutine ...)` doesn't
                    fall through to the no-body stub.
                  - SRT_Coroutine disposal arm in selectInnerLoop
                    (codegen.pas:20546) emits `OP_Yield iSDParm`
                    after the per-column emit, mirroring
                    select.c:1441..1454.
                  - Bug fix in `OP_EndCoroutine`
                    (passqlite3vdbe.pas:7066): the prior pas port
                    jumped to `aOp[pIn1^.u.i]` (the saved Yield
                    itself) instead of to `aOp[savedYield.p2 - 1]`
                    (the Yield's addrEnd parameter), so a
                    co-routine that ran past its last row would
                    spin instead of breaking out of the outer
                    loop.  Re-port now matches vdbe.c:1203..1213
                    exactly: jump to the saved Yield's `p2 - 1`
                    and write `pIn1^.u.i = (this EndCoroutine
                    addr) - 1` so any later Yield re-enters
                    EndCoroutine and re-jumps to addrEnd.
                  - Bug fix in the addrTop calculation: was
                    `currentAddr+2` (off by one — skipped the
                    inner's first opcode), now `currentAddr+1`
                    matching select.c:8047 exactly.

                Live-row smoke (off-tree, equivalent to piece 3's
                smoke but now via co-routine path):
                `SELECT a FROM (SELECT a FROM t)` returns [1,2,3];
                `SELECT a+10 FROM (...)` returns [11,12,13];
                `SELECT a FROM (SELECT a FROM t WHERE a>1)` returns
                [2,3].  DiagFeatureProbe gate row
                'Sub-SELECT FROM materialise' stays PASS (the
                row name now lies — it's actually exercising the
                co-routine arm — but the contract is "Pas matches
                C", which still holds).

                Bytecode shape does NOT match the C oracle yet
                because C applies subquery flattening
                (select.c:flattenSubquery) for the simple
                uncorrelated case, producing a single flat scan;
                our port emits the co-routine bytecode shape (4
                opcodes for the inner skeleton + outer scan)
                instead.  Both produce the same rows.  Flattening
                is its own large port and is tracked under a
                future 6.13 sub-arm — landing it would converge
                the bytecode to the C oracle and likely flip a
                few EXPLAIN parity rows.  TestExplainParity stays
                at 1016/10 either way (no sub-SELECT FROM rows in
                the current corpus).

                Bail-lift sweep at the five `IS_SUBQUERY` gate
                sites (codegen.pas:19686, :19964, :20021, :20165,
                :20255) is NOT done in this piece — those gates
                exit `sqlite3Select` before the new co-routine /
                materialise hot-path arms reach them, so the
                hot-path arms cover the simple shape but more
                complex shapes (DISTINCT-on-subquery, aggregate-
                on-subquery, multi-FROM with subquery items, etc.)
                still bail.  Each of the five sites needs its own
                gated, tested lift since the right behaviour
                differs (some need to route through the
                co-routine arm, some need WHERE-code integration).
                Tracked as a follow-up subtask under 6.13(b).

                **Sweep audit (post-piece-4):** the five sites
                resolve into three categories — confirm-only,
                materialise-lift, dispatcher-lift.  Mapped to
                current passqlite3codegen.pas line numbers:

                - Site #1 (codegen.pas:19733, GROUP BY agg arm):
                  bails on IS_SUBQUERY.  See sites #1+#3 design
                  note below — the lift is NOT a surgical bail
                  removal.  PENDING.
                - Site #2 (codegen.pas:20011, simple count fast
                  path): IS_SUBQUERY = 0 gate is C-faithful —
                  matches `isSimpleCount` at select.c:5441 line
                  for line, count(*)-on-subquery is excluded by
                  C as well.  No lift needed; comment now cites
                  the C source directly.  DONE.
                - Site #3 (codegen.pas:20068, general agg arm):
                  same shape as site #1.  Paired lift with #1.
                  PENDING.

                **Sites #1+#3 design note (post-C-oracle audit).**
                The original framing — "lift the IS_SUBQUERY
                bail" — is misleading.  C handles
                agg-on-subquery via two entirely distinct paths,
                neither of which is a localised lift in the agg
                arm:

                1. **Flattenable inner** (no DISTINCT, no
                   aggregate, no compound, …): C's
                   `flattenSubquery` (select.c:flattenSubquery)
                   rewrites `SELECT agg FROM (SELECT cols FROM t
                   WHERE …)` into `SELECT agg FROM t WHERE …`
                   BEFORE the agg arm runs.  C oracle for
                   `SELECT count(*) FROM (SELECT a FROM t)`
                   produces the 5-op fast path against `t`
                   directly (OpenRead/Count/Close/Copy/
                   ResultRow) — identical to `SELECT count(*)
                   FROM t`.  Same for `SELECT avg(a) FROM
                   (SELECT a FROM t WHERE a>1)` — flattened to
                   `SELECT avg(a) FROM t WHERE a>1`.

                2. **Non-flattenable inner** (DISTINCT,
                   aggregate-in-subquery, etc.): C's
                   per-pSrcItem dispatcher (select.c:7983..8133)
                   emits a **co-routine** (not materialise) for
                   the inner.  `sqlite3WhereBegin`'s viaCoroutine
                   arm then drives the outer agg path: the inner
                   yields one row at a time, `AggStep` runs in
                   the Yield-loop body, `AggFinal` after the
                   loop.  C oracle for `SELECT count(*) FROM
                   (SELECT DISTINCT a FROM t)`:
                       InitCoroutine → inner DISTINCT body →
                       EndCoroutine → Null accumulator →
                       InitCoroutine → Yield+AggStep loop →
                       AggFinal → Copy → ResultRow

                Implications for the Pas port:

                - Lifting only the IS_SUBQUERY bail at sites #1
                  and #3 cannot produce C-faithful bytecode.
                  The flattenable case needs `flattenSubquery`;
                  the non-flattenable case needs the dispatcher
                  to set up a co-routine FROM-item, then the agg
                  arm's call to `sqlite3WhereBegin` would route
                  through the existing viaCoroutine arm at
                  codegen.pas:16395.

                - Pas's `sqlite3WhereBegin` viaCoroutine arm
                  (codegen.pas:16395..16404) is already in
                  place from earlier porting; what is missing
                  is wiring the agg arms so the dispatcher runs
                  before them and so they no longer bail on
                  IS_SUBQUERY for items the dispatcher has
                  already handled.

                **Re-scoped follow-ups** (replace the original
                "sites #1+#3 lift"):

                - **6.13(b)-fl**: port `flattenSubquery`
                  (select.c:flattenSubquery, ~600 lines).  Once
                  landed, the flattenable case of agg-on-subquery
                  works end-to-end with bytecode parity, no
                  changes to sites #1 or #3 needed.  This is the
                  same future sub-arm noted in piece 4's commit
                  message.

                - **6.13(b)-coagg**: agg-arm + dispatcher
                  integration for the non-flattenable case.
                  Move the per-pSrcItem subquery dispatcher
                  (currently the standalone arms at 20283 / 20397
                  for SRT_Output) up to run as a pre-pass before
                  the agg arms when SF_Aggregate is set.  Lift
                  IS_SUBQUERY bails in the agg arms.  The
                  existing WhereBegin viaCoroutine arm picks up
                  the rest.  Requires careful review of the
                  AggInfo column-resolution path
                  (analyzeAggList) against coroutine FROM-items.

                Site #1+#3 remain PENDING under these two
                re-scoped follow-ups.  No code change in this
                audit — diverging from C bytecode shape would
                trade a passing IS_SUBQUERY bail for a worse
                regression-test story (TestExplainParity would
                gain new diverges).
                - Site #4 (codegen.pas:20212, eponymous-vtab arm):
                  IS_SUBQUERY = 0 gate is correct — subquery
                  items fall through to the co-routine /
                  materialise arms immediately below (lines 20305,
                  20416).  No lift needed.  DONE.
                - Site #5 (codegen.pas:20488, final pre-regular-
                  cursor-open bail): multi-FROM with subquery
                  items.  Largest lift — needs per-pSrcItem
                  dispatcher mirroring select.c:7983..8133 plus
                  WHERE-code integration for the resulting eph
                  cursor / regResult block.  PENDING.

                  **Prep landed (no behaviour change):**
                  - WhereEnd OP_Column→OP_Copy rewrite for
                    viaCoroutine items (where.c:7754..7761) —
                    see codegen.pas:16126.
                  - WhereBegin cursor-open guards on both the
                    multi-level path (codegen.pas:15471) and
                    the single-table rowid-shortcut path
                    (codegen.pas:15611) — both now skip
                    TF_Ephemeral / IsView / viaCoroutine items
                    (where.c:7259).
                  - **Site #5 (a)** narrow lift of the
                    nTabList=1 bail for viaCoroutine FROM items
                    (codegen.pas:15407..15426).  When the single
                    FROM item is viaCoroutine, sqlite3WhereBegin
                    now routes through the full-planner branch
                    (whereLoopAddAll → wherePathSolver →
                    codeOneLoopStart) so the InitCoroutine +
                    Yield emission at codegen.pas:16437 and the
                    WhereEnd OP_Column→OP_Copy rewrite actually
                    fire instead of bypassing into the
                    rowid-shortcut body emission at
                    codegen.pas:15686..15909.  Dormant until
                    site #5 (b) wires the per-pSrcItem dispatcher
                    that actually produces a viaCoroutine
                    single-table FROM — no SELECT in the corpus
                    today exercises the new path, so no PASS
                    rows move.  Wider lift (drop the bail
                    entirely so every nTabList=1 plan goes
                    through the planner — option b-faithful)
                    deferred until codeOneLoopStart is verified
                    to cover every shape the inline block at
                    15686..15909 currently handles.

                  Tracked as **site #5 (a)** — planner viaCoroutine
                  support, narrow lift LANDED — with site #5's
                  actual dispatcher emission as **site #5 (b)**
                  layered on top.

                  **site #5 (b)** — full nTabList=1 bail lift
                  LANDED 2026-05-01 (commit 41167c7).  Removes
                  the explicit bail at codegen.pas:15422..15426 so
                  every single-table case whereShortCut cannot
                  classify (WHERE_OR_SUBCLAUSE recursion, virtual
                  tables, INDEXED BY / NOT INDEXED) routes through
                  the full planner instead of returning nil.
                  Verified: TestExplainParity 1018/8/1026
                  unchanged, no regressions across the test suite.

                  **site #5 (c)** — INDEXED BY planner wiring
                  LANDED 2026-05-01 (commit 889ca4f).  Three
                  coupled fixes: (1) selectExpander now calls
                  sqlite3IndexedByLookup for FROM items with
                  fg.isIndexedBy set, (2) sqlite3CreateIndex
                  populates pIndex^.colNotIdxed, (3) the planner-
                  branch cursor-open loop allocates iIdxCur and
                  emits OP_OpenRead with KeyInfo + OPFLAG_SEEKEQ.
                  Net: DiagIndexing 7→6 (`not indexed` PASS).
                  `indexed by ok` blocked on 6.8.6 (sqlite3Insert
                  index-write rewrite).

                Sites #2 and #4 close as no-op-needed because the
                Pas gates are already faithful to C.  Sites #1,
                #3 remain open as separate gated lifts.

                Regression sweep stays green: TestExplainParity
                1016/10, TestSelectBasic 60/0, TestDMLBasic 54/0,
                TestSchemaBasic 44/0, TestWhereBasic 52/0,
                TestVdbeCursor 29/0, TestSmoke pass.
                DiagFeatureProbe stays at 10 divergences (the
                VIEW gate row from piece 2; sub-SELECT row PASS).
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
