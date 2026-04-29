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
       [X] `sqlite3VdbeExplainPop` — closed
       [X] `sqlite3VdbeEnter` / `sqlite3VdbeLeave` — closed 2026-04-29.
            Empty bodies match the OMIT_SHARED_CACHE macro expansions
            (vdbeInt.h:714/720); Pas has no shared-cache so this is the
            faithful port for the build configuration.

       Pragma (pragma.c):
       [ ] `sqlite3PragmaVtabRegister` — returns `nil`; registers
            `pragma_*` eponymous virtual tables via
            `sqlite3VtabCreateModule` + `pragmaVtabModule`.

       Btree mutex (btmutex.c / btree.c):
       [X] `sqlite3BtreeHoldsAllMutexes` — closed 2026-04-29.  Returns
            constant 1 (matches btree.h:420 macro for OMIT_SHARED_CACHE).
       [X] `sqlite3BtreeSchemaLocked` — closed 2026-04-29.  Returns
            SQLITE_OK (querySharedCacheTableLock is no-op without
            shared cache).

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
    - [X] **a)** RHS arms for Real / String / Blob / extra-Null
      ported 2026-04-28.  serialGet7 + IntFloatCompare + isAllZero
      helpers added locally in btree.pas (avoids uses-cycle to
      vdbe.pas).  String / Blob RHS use memcmp (BINARY only — see (b)).
    - [ ] **b)** Collation-aware string compare (vdbeCompareMemString
      hook from btree.pas → vdbe.pas) — required only for non-BINARY
      collated index lookups; current corpus has none.  Defer until
      a test needs it.
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

- [ ] **6.9-bis 11g.2.f** Audit + regression.  Tests run with
        `LD_LIBRARY_PATH=$PWD/src` so the csq_* oracle resolves to
        src/libsqlite3.so, not the system one.

    - [ ] Port `sqlite3Update` body in full (skeleton-only today;
      blocks DROP TABLE Δ=21 destroyRootPage and UPDATE rowid=1 Δ=14).

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
      [X] **a) DEFAULT clause ignored by INSERT** — closed.
      [X] **b) Hex integer literal decoded as 0** — closed.
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
      [X] **a) COLLATE NOCASE** — closed.
      [X] **b) Scalar subquery returns 0** — closed.
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
      [X] **d-INNER) `INNER JOIN` aggregate** — closed 2026-04-29.
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
      [X] **i) GENERATED column virtual** — closed 2026-04-29.
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
      [X] **a) `total_changes()` returned 0 after INSERT** — closed.
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
      [X] **g) `journal_mode` PRAGMA** — closed (DiagTxn `pragma
        journal_mode memory default mem` PASSes; covered by the 6.12
        PragTyp_JOURNAL read arm landed via the table-driven dispatch).
        Full table-driven `pragmaLocate` (table-valued pragma_* etc.)
        still deferred under 6.12.

  [ ] **6.10 step 17** Window-function and aggregate divergences surfaced
      by the new `src/tests/DiagWindow.pas` probe (run with
      `LD_LIBRARY_PATH=$PWD/src bin/DiagWindow`).  19 divergences open;
      most fold into existing window/agg tasks.
      [X] **a) `max(val) FROM g` returns `0.0`** — closed 2026-04-28.
      [X] **a-bis) `sum(int)` integer-overflow / `total`/`avg`
        precision** — closed 2026-04-28.
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
      [X] **e) `count(*) FILTER (WHERE …)` / `sum() FILTER`** —
        closed 2026-04-29.
      [X] **f) `count(DISTINCT col)` / `sum(DISTINCT col)`** —
        closed 
      [X] **g) `GROUP BY ... HAVING ...`** — closed 2026-04-29.
      [X] **h) `GROUP BY ... ORDER BY <col> DESC`** — closed 2026-04-29.

  [X] **6.10 step 20** Host-parameter binding (`?`/`?N`/`:name`/
      `@name`/`$name`)

  [X] **6.10 step 21** DiagPrintfFmt probe

  [X] **6.10 step 18** TestAuthBuiltins

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

  [X] **6.10 step 22** Ephemeral b-tree dedup over TEXT/BLOB keys

  [X] **6.10 step 23** absFunc error-message parity

  [X] **6.10 step 24** Scalar built-in parity sweep — closed

  [X] **6.10 step 27** LIKE / GLOB / NOT LIKE / NOT GLOB / ESCAPE
      parity sweep — closed 2026-04-29 (DiagLikeGlob, 55/55 PASS).

  [ ] **6.10 step 26** DiagIndexing probe
      (`src/tests/DiagIndexing.pas`, baseline 44 cases / 15 DIVERGE on
      add).  35 PASS / 7 DIVERGE on 2026-04-29 re-run — a..d closed.
      Run with `LD_LIBRARY_PATH=$PWD/src bin/DiagIndexing`.
      [X] **a) `CREATE INDEX <name> ON t(col)`** — closed.
      [X] **b) Partial index `... WHERE b='y'`** — closed.
      [X] **c) Expression index `... ON t(a*2)`** — closed.
      [X] **d) Affinity not applied at INSERT time** — closed.
      [ ] **e) `INDEXED BY` / `NOT INDEXED`** — DiagIndexing `indexed
        by ok`, `not indexed` return empty rowset.  Blocker:
        sqlite3WhereBegin's nTabList=1 gate (codegen.pas:14991) bails
        when whereShortCut returns 0; whereShortCut bails for any FROM
        item carrying INDEXED BY ($02) / NOT INDEXED ($01) flags
        (codegen.pas:14203).  Lifting the bail exposes downstream gaps
        — full single-table planner port required (overlaps
        6.9-bis 11g.2.b).
      [ ] **f) Remaining 5 divergences** — `schema after create idx`,
        `select range via idx`, `unique violation`, `rowid select`,
        `rowid alias custom`.  Likely fold into single-table planner
        and sqlite3GenerateConstraintChecks gaps (e + 6.9-bis 11g.2.b);
        triage when those land.

  [X] **6.10 step 25** Date/time `'now'` + strftime `%s` parity —
      closed 2026-04-29.

  [ ] **6.11** DROP TABLE remaining gap (current Δ=26, was Δ=21):
    (a) [X] ONEPASS_MULTI promotion landed in sqlite3WhereBegin,
        the sqlite_schema scrub now uses one-pass inline delete.
    (b) [ ] Pas elides the destroyRootPage autovacuum follow-on (~26 ops)
        because `destroyRootPage` calls `sqlite3NestedParse(UPDATE
        sqlite_schema ...)` and productive `sqlite3Update` is still
        skeleton-only.  This is the only remaining contributor.
  [ ] **6.12** port sqlite3Pragma in full.  Regression gate
       `src/tests/DiagPragma.pas`.  Baseline 49 DIVERGE driven to 12.
       Remaining divergences (12): table-valued pragma_* introspection
       functions (table_info, table_xinfo, index_list, foreign_key_list,
       database_list, collation_list, function_list, module_list,
       pragma_list, compile_options), integrity_check / quick_check.
       Closing these requires `sqlite3PragmaVtabRegister` (Phase 6.8) +
       full table-driven `pragmaLocate` dispatch.
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
       [X] `sqlite3_blob_open` / `sqlite3_blob_reopen` — ported 2026-04-29.
       [X] `OP_FilterAdd` / `OP_Filter` — ported 2026-04-29.
       [X] `sqlite3VdbeList` — ported 2026-04-29.
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
       `sqlite3AutoincrementBegin`, `sqlite3AutoincrementEnd`,
       `sqlite3MultiValues`, `autoIncBegin`,
       `sqlite3GenerateConstraintChecks`.
       [X] `sqlite3MultiValuesEnd` — ported 2026-04-29.
       [X] `sqlite3ComputeGeneratedColumns` — ported 2026-04-29 (dead-code
            until sqlite3Insert / sqlite3Update / GenerateConstraintChecks land).
  [ ] **6.25** port codegen.pas schema / index stubs in full from C to pascal:
       `sqlite3ReadSchema`, `sqlite3RunParser`.
  [ ] **6.26** port codegen.pas where / select / window stubs in full from C
       to pascal:
       [X] `sqlite3WhereExplainBloomFilter` — ported 2026-04-29.
       [X] `sqlite3WhereAddExplainText` — ported 2026-04-29.
       [ ] `sqlite3WindowCodeInit`, `sqlite3WindowCodeStep`.
  [ ] **6.27** port codegen.pas alter / attach / analyze / vacuum / FK /
       extension / scalar-function stubs in full from C to pascal:
       `sqlite3AlterRenameTable`, `sqlite3AlterFinishAddColumn`,
       `sqlite3AlterAddConstraint`, `sqlite3Detach`, `sqlite3Attach`,
       `sqlite3Analyze`, `sqlite3Vacuum`,
       `sqlite3FkCheck`, `sqlite3FkActions`.
  [X] **6.27a** `sqlite3AddCollateType` — ported 2026-04-28.
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

- [X] **7.1.3** Statement re-prepare (sqlite3Reprepare) — closed
       2026-04-29.  Full body at main.pas:1001 (sqlite3LockAndPrepare +
       VdbeSwap + TransferBindings + ResetStepResult + Finalize); all
       callees present and non-stub.  Activates the SQLITE_SCHEMA
       transparent-recompile path used by sqlite3_step on prepare_v2
       statements.

- [X] **7.1.4** DbFixer

- [ ] **7.1.7** Lemon parser tail (parse.c epilogue) — gaps inside
       `passqlite3parser.pas`:
       [X] `sqlite3ParserFallback` — done.
       [X] `yy_accept` / `yy_parse_failed` / `yy_syntax_error` — done.
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
       [X] `sqlite3_open16` — ported 2026-04-29.
       [X] `sqlite3_db_config` — closed 2026-04-29 by design (see
            main.pas:1291 / codegen.pas:2791 "No C-ABI varargs").  The
            varargs ABI is split into the typed entry points
            `_text` / `_lookaside` / `_int`; together they provide the
            full functional surface of the C `sqlite3_db_config(...)`
            (MAINDBNAME, LOOKASIDE, FP_DIGITS, all 21 boolean flag-ops
            via `dbConfigFlagOp`).  No Pascal consumer needs the raw
            varargs shape; if a future C-ABI export is added, expose a
            cdecl shim that dispatches into the typed wrappers.
       [X] `sqlite3_set_clientdata` / `sqlite3_get_clientdata` — ported 2026-04-29.

- [ ] **8.2.1** Statement-introspection gaps (vdbeapi.c):
       [X] `sqlite3_stmt_busy` — ported 2026-04-28.
       [ ] `sqlite3_stmt_scanstatus` / `_scanstatus_v2` /
            `_scanstatus_reset` — gated on the 6.8
            `sqlite3VdbeScanStatus*` arms landing first.

- [ ] **8.3.1** Bind variants (vdbeapi.c):
       [X] `sqlite3_bind_blob64` / `sqlite3_bind_text64` /
            `sqlite3_bind_text16` — ported 2026-04-28.

- [ ] **8.3.2** Result / value variants (vdbeapi.c, vdbemem.c).
       [X] `sqlite3_value_text16` / `_text16be` / `_text16le` — ported 2026-04-29.

- [X] **8.3.2-bis** Error-message routing.

- [X] **8.3.2-ter** `sqlite3VdbeReset` errCode reset — closed

- [ ] **8.4.1** Hooks / control / change-counter / errors / limits
       (main.c, status.c):
       [X] `sqlite3_progress_handler` — ported 2026-04-28.
       [ ] `sqlite3_test_control` — testing back-door (subset).

- [X] **8.5.1** Dynamic string builder API (`sqlite3_str_*`,
       printf.c).

- [ ] **8.7.1** Snapshot / WAL APIs:
       [ ] `sqlite3_snapshot_get` / `_open` / `_free` / `_cmp` /
            `_recover`.
       [X] `sqlite3_wal_autocheckpoint` / `sqlite3_wal_hook` /
            `sqlite3_wal_checkpoint` / `_v2` — ported 2026-04-29.

- [ ] **8.7.2** Backup / serialization (currently `sqlite3_backup_init`
       / `_step` / `_finish` exist; the remaining surface is missing):
       [X] `sqlite3_serialize` — ported 2026-04-29 (real-Btree path only;
            memdb VFS branch unreachable).  Gate: `src/tests/TestSerialize.pas`.
       [ ] `sqlite3_deserialize` — open in-memory db from a buffer.

- [ ] **8.8.1** Pre-update hook (preupdate.c — `SQLITE_ENABLE_PREUPDATE_HOOK`):
       [ ] `sqlite3_preupdate_count` / `_new` / `_old` / `_depth` /
            `_blobwrite`.

- [ ] **8.9.1** Vtab helper APIs (vtab.c, vdbeapi.c):
       [ ] `sqlite3_vtab_distinct` — query-planner DISTINCT hint.
       [ ] `sqlite3_vtab_in` / `_in_first` / `_in_next` — IN-operator
            helpers.
       [X] `sqlite3_vtab_nochange` — ported 2026-04-29.
       [ ] `sqlite3_vtab_rhs_value` — extract RHS value of a constraint.

- [ ] **8.9.2** Carray / shared-cache / misc (sqlite3_carray_bind).

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
