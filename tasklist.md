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

- [X] **6.8.0** Pragma (pragma.c): `sqlite3PragmaVtabRegister` — DONE.
     1:1 port of pragma.c:2791..3101 (aPragmaName, pragCName, all 12
     vtab callbacks, pragmaVtabModule).  Underlying PRAGMA codegen arms
     (TABLE_INFO, INDEX_LIST, …) still stubs — see 6.12.

- [~] **6.8.2** port `sqlite3GenerateConstraintChecks` (insert.c).
     Body ported (codegen.pas:24529..25303); 1:1 with
     insert.c:1895..2723.  All arms ([X] NOT NULL, [X] CHECK,
     [X] PK/UNIQUE incl. partial-index, [X] FOREIGN KEY,
     [X] Conflict-resolution + UPSERT OE_Update).  Wired via 6.8.6.
     [ ] Auto-rowid for IPK alias on NULL (max(rowid)+1, AUTOINCREMENT)
          — belongs to sqlite3Insert (insert.c:1454..1559), not here.

- [X] **6.8.3** port `sqlite3CompleteInsertion` (insert.c) — DONE.
     Body at `passqlite3codegen.pas:25319..25395`, 1:1 port of
     `insert.c:2782..2847`.  Companion to 6.8.2.  Wired into the
     productive `sqlite3Insert` cascade via 6.8.6.

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
     [X] `INDEXED BY` honour — planner + codegen wired; DiagIndexing
          `indexed by ok` PASS.
     [ ] Multi-table loop nesting + per-loop WHERE-clause splitting
          (codeOneLoopStart already supports it; corpus parity
          deferred — TestExplainParity multi-table rows still
          mostly diverging on join-order / explain-text edges).
     [ ] Bloom-filter and covering-index arms (covers 6.10 step 9
          d-INNER and the `SELECT p FROM u` planner Δ).

- [~] **6.8.6** port the productive `sqlite3Insert` body (insert.c).
     Single-row VALUES path DONE.  Inline four-op shortcut replaced
     by `sqlite3OpenTableAndIndices` + per-loop column eval +
     `sqlite3GenerateConstraintChecks` (6.8.2) +
     `sqlite3CompleteInsertion` (6.8.3) with aRegIdx[nIdx+1] alloc.
     [X] IPK-alias rebinding (insert.c:1488..1531).
     [~] Multi-row VALUES — runtime DONE; bytecode-Δ remains
          (C=22 vs Pas=17 — coroutine arm of sqlite3MultiValues).
          INSERT FROM SELECT bails — folds into 6.10 step 6 sub-FROM.
     [X] AUTOINCREMENT.
     [X] BEFORE / AFTER INSERT triggers.
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
     arm DONE.  `passqlite3codegen.pas:23457..24115`, 1:1 port of
     `update.c:285..1163`.  Deferred sub-arms (early-bail today):
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
            (prepare.c:865-866) — DONE.

### Open Bugs

- [ ] **6.10** `TestExplainParity.pas`
    - [ ] **6.10 step 6** Remaining TestExplainParity bytecode-Δ rows
       (7 diverges in 1019/1026 corpus):
        [ ] `SELECT a FROM t ORDER BY a` (asc/desc/multi-col) —
          asc/desc: C=19 Pas=20 (Δ=1); 2col: C=20 Pas=21 (Δ=1).
          sqlite3ExprCodeExprList has all four ECEL arms;
          structural-compare arm of resolveOrderGroupBy ported
          2026-05-02 (resolve.c:1820..1833) — ORDER BY/GROUP BY terms
          now get iOrderByCol set when their expr matches a result
          column.  Closing Δ=1 still requires the nPrefixReg layout in
          selectInnerLoop / pushOntoSorter so OMITREF drops the
          duplicate Column read (select.c:1216 + select.c:771..782),
          plus matching SorterOpen p2 (= nKey + nData + 1 for the
          rowid/sequence slot).
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
  
  [ ] **6.10 step 7** Runtime divergences surfaced by `DiagMisc`.
      Silent result-set bugs (prep+step clean, wrong value).
      [ ] **c) Aggregate-no-GROUP-BY codegen path** — partial.  Common
        cases PASS.  Remaining gaps fold into the open INNER-JOIN
        bloom-filter case (6.10 step 9 d-INNER) and sub-FROM
        materialise (step 6 sub-FROM).

  [ ] **6.10 step 9** Runtime divergences surfaced by
      `src/tests/DiagFeatureProbe.pas` (run with `LD_LIBRARY_PATH=$PWD/src
      bin/DiagFeatureProbe`).  Most fold into existing tasks; the genuinely
      new silent-result bugs are listed first.
      [ ] **c) View materialisation in SELECT.**  Folds into 6.13(b).
        Plain `SELECT a FROM v` PASS; `count(*) FROM v` still bails
        (the agg-no-GROUP-BY gates reject SRCITEM_FG_IS_SUBQUERY).
        Closing needs sub-FROM materialise / co-routine codegen path
        (6.10 step 6 sub-FROM entry).
      [ ] **e) UNION / compound SELECT.**  Folds into 6.13(c).
        `SELECT count(*) FROM (SELECT 1 UNION SELECT 2 UNION SELECT 1)`
        returns no row.  Compound-select codegen / sub-FROM
        materialisation gap (overlaps step 6 sub-FROM Δ=7 entry).
      [~] **f) WITH / CTE not productive** — simple non-recursive CTE
        DONE 2026-05-02.  Recursive CTE still DIVERGES — needs the
        recursive-CTE arm of resolveFromTermToCte (select.c:5760..5839)
        plus compound SF_Recursive codegen.
      [ ] **g) ALTER TABLE no-op.**
        `RENAME COLUMN` and `ADD COLUMN` both prepare+step cleanly but
        do not modify the schema.  Tracked under 7.1.9.
      [X] **h) CHECK constraint not enforced** — DONE 2026-05-01.
      [X] **j) AFTER INSERT trigger does not fire** — DONE 2026-05-01.
      [ ] **k) `pragma_table_info(...)` table-valued function.**
        `SELECT count(*) FROM pragma_table_info('t')` returns no row.
        Tracked under 6.12 (sqlite3Pragma).

  [ ] **6.10 step 15** Runtime divergences surfaced by `DiagTxn`
      (transactions, savepoints, conflict resolution).  7 remain;
      most fold into existing gaps (full VdbeHalt, sqlite3Update).
      [ ] **b) `BEGIN; ...; ROLLBACK` does not roll back** — BEGIN/
        ROLLBACK are no-ops on Pas side; blocked on Phase 5.4 full
        VdbeHalt port.
      [~] **c) `SAVEPOINT s; ROLLBACK TO s` does not unwind** —
        schema-cache side fixed.  Remaining: memdb pager savepoint
        reconciliation — btree pages not unwound on ROLLBACK TO.

  [ ] **6.10 step 17** Window-function and aggregate divergences
      surfaced by `DiagWindow`.  13 runtime empty-row divergences open.
      [ ] **b) `group_concat(val, ',' ORDER BY val DESC)` empty** —
        ORDER-BY-in-aggregate not honoured.  Tracked under 6.24.
      [ ] **d) Window aggregates `sum() OVER ()` / `OVER (ORDER BY)`
        prepare cleanly but emit no rows** — `row_number() OVER (...)`
        same.  Window-codegen sub-issue under 6.26.

  [ ] **6.10 step 19** DiagDml runtime probe — all 14 PASS.
      [X] **a) `INSERT INTO t SELECT … UNION ALL SELECT …`** — DONE.
        Bytecode parity deferred (coroutine arm of sqlite3MultiValues).
      [X] **b) Multi-row VALUES with non-constant exprs** — DONE.

  [X] **6.10 step 26** DiagIndexing probe — DONE.  Minimal ORDER BY
      sorter ported (SRT_Output, plain LIMIT, LIMIT+OFFSET).
      Deferred sorter sub-arms (none in current corpus):
      [X] DISTINCT + ORDER BY — DONE.
      [ ] Top-N sorter — currently pushes all rows then trims with
          DecrJumpZero.
      [ ] nOBSat shortcut — when the planner reports the loop already
          delivers rows in ORDER BY order, skip the sorter.

  [ ] **6.11** DROP TABLE remaining gap (current Δ=26, was Δ=21):
    (b) [ ] Pas elides the destroyRootPage autovacuum follow-on (~26 ops)
        because `destroyRootPage` calls `sqlite3NestedParse(UPDATE
        sqlite_schema ...)` and productive `sqlite3Update` is still
        skeleton-only.  This is the only remaining contributor.
  [~] **6.12** port sqlite3Pragma in full.  Gate `DiagPragma`.
       Direct PragTyp dispatch landed (TABLE_INFO / INDEX_INFO /
       INDEX_LIST / DATABASE_LIST / COLLATION_LIST / FUNCTION_LIST /
       MODULE_LIST / PRAGMA_LIST / COMPILE_OPTIONS).  5 DiagPragma
       divergences remain (was 9): the agg-no-GROUP-BY arm now branches
       to a VOpen/VFilter/VNext loop for single-source eponymous-vtabs
       so `count(*) >= N FROM pragma_*` shapes work (closed
       function_list / module_list / pragma_list).  Remaining gaps:
       (a) arg-bound vtabs (`pragma_table_info('t')`,
       `pragma_table_xinfo('t')`, `pragma_index_list('t')`,
       `pragma_foreign_key_list('c')`) need hidden-column WHERE binding
       — TVF args populate `pItem^.u1.pFuncArg` but the vtab agg arm
       doesn't yet pass them through to xFilter; FOREIGN_KEY_LIST also
       blocked on TFKey opaque.  (b) COMPILE_OPTIONS needs
       `sqlite3azCompileOpt` populated.

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
       [X] **a) Eponymous-vtab arm** — DONE.  `SELECT name FROM
            pragma_pragma_list` returns 66 rows.  count(*) /
            arg-bound forms (pragma_table_info('t')) still bail —
            need WhereBegin's vtab branch or count-on-vtab special.
       [~] **b) Sub-SELECT / view arm** — co-routine emission landed;
            simple `SELECT a FROM (SELECT a FROM t)` returns live rows.
            Bytecode shape diverges from C (subquery flattening).
            Open follow-ups:
            - **6.13(b)-fl**: port `flattenSubquery` (select.c, ~600
              lines).  Closes the flattenable agg-on-subquery case
              with bytecode parity.
            - **6.13(b)-coagg**: agg-arm + dispatcher integration for
              the non-flattenable case.  Lift IS_SUBQUERY bails in
              agg arms; existing WhereBegin viaCoroutine picks up rest.
       [ ] **c) Compound-SELECT / CTE arm** — UNION / INTERSECT /
            EXCEPT FROM-sources and `WITH … AS (…)` references.
            CTE name resolution needs parser-side `WithAdd` / `CteNew`
            to populate `pParse^.pWith` (tracked under 6.20).

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
       [~] Port `sqlite3AlterFunctions` — `sqlite_fail`,
            `sqlite_add_constraint`, `sqlite_find_constraint` registered.
            Remaining 6 rows (sqlite_rename_column / _table /
            renameTableTest, sqlite_drop_column, sqlite_rename_quotefix,
            sqlite_drop_constraint) land with their bodies below.
       [X] Port `sqlite3RenameTokenRemap`.
       [X] Port `sqlite3RenameExprlistUnmap`.
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
