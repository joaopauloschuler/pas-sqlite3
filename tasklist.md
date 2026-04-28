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
      [X] **a) DEFAULT clause ignored by INSERT.**  Fixed by porting
        `sqlite3AddDefaultValue` (build.c:1729), `sqlite3ColumnSetExpr`
        (build.c:683), `sqlite3ColumnExpr` (build.c:709), and
        `sqlite3ExprIsConstantOrFunction` (eCode=4/5 variants of
        exprIsConst) — none were wired before, so DEFAULT expressions
        never reached pTab->u.tab.pDfltList and `pCol^.iDflt` stayed 0.
        Also wired the missing-column / DEFAULT-VALUES arms of
        `sqlite3Insert` (codegen.pas:19852) to consult sqlite3ColumnExpr
        instead of always emitting OP_Null.  The TK_SPAN source-text
        wrapper from C is not duplicated faithfully (Pas exprDup_
        cannot yet duplicate a stack TExpr with EP_Skip + extra zToken
        — the ExprDup buffer-passing recursion AVs); pExpr is dup'd
        directly which is sufficient for runtime semantics, only the
        DEFAULT source-text round-trip in EXPLAIN/error messages is
        lost.  Verified via DiagMisc "INSERT default literal" PASS.
      [X] **b) Hex integer literal decoded as 0.**  Fixed by porting
        the missing hex arm in `sqlite3GetInt32` (util.c:1298..1326);
        previous decimal-only scan stopped at "0", set EP_IntValue
        with iValue=0, and codeInteger emitted OP_Integer 0.  Hex
        literals now flow through as i32 (or fall back to the zToken
        + sqlite3DecOrHexToI64 path for >32-bit values).  Verified
        via DiagMisc "INSERT hex literal" → PASS.
      [ ] **c) Aggregate-no-GROUP-BY codegen path.**
        Silent gap for `count(*)`, `sum`, `min`, `max`, `avg` etc. when
        the SELECT carries a WHERE / multi-table FROM / DISTINCT-arg /
        anything that misses the bytecode simple-count fast path.
        DiagAggWhere (`bin/DiagAggWhere`) confirms `SELECT count(*)
        FROM t WHERE a IS NULL` lands as 3 ops on Pas (Init / Halt /
        Goto) vs 16 on C — Pas emits *no* loop body at all.
        **Exact gate:** `passqlite3codegen.pas:18045` — a hard `Exit`
        on any `selFlags & (SF_Distinct | SF_Aggregate | SF_Compound)`
        that didn't match the inline simple-count optimisation at
        18002..18043.  Decomposition into achievable sub-tasks (each
        a discrete commit unit; the C reference is select.c
        analyzeAggregate / generateAggSelect, ≈ select.c:6120..6450
        + 8819..9050).

  [ ] **6.10 step 9** Runtime divergences surfaced by
      `src/tests/DiagFeatureProbe.pas` (run with `LD_LIBRARY_PATH=$PWD/src
      bin/DiagFeatureProbe`).  Most fold into existing tasks; the genuinely
      new silent-result bugs are listed first.
      [X] **a) COLLATE NOCASE operator silently case-sensitive.**  Fixed
        2026-04-28 by porting the missing collation arm of
        `sqlite3MemCompare` (vdbeaux.c:4659..4661 / vdbeCompareMemString
        same-encoding branch).  Bytecode was already correct (`OP_Eq`
        carried `P4=COLLSEQ(NOCASE)` and `P5=64` — verified via
        src/tests/DiagCollate.pas); the runtime helper just dropped
        pColl on the floor with a `"no collation support"` TODO.  Now
        invokes `pColl^.xCmp` when both operands share `pColl^.enc`.
        UTF-8/UTF-16 transcoding arm (vdbeaux.c:4450) deferred — default
        UTF-8 build never reaches it.  DiagFeatureProbe COLLATE NOCASE
        compare → PASS; total divergences 14 → 13.  No
        TestExplainParity regression (1012 pass / 14 diverge — same).
      [X] **b) Scalar subquery returns 0 instead of value.**  Fixed
        2026-04-28 by accepting `SRT_Mem` in the `sqlite3Select`
        eDest gate (codegen.pas:17578) and adding the SRT_Mem disposal
        arm (selectInnerLoop:1422..1438) — column codegen targets
        iSdst (=iSDParm) directly, then OP_DecrJumpZero on the
        sqlite3CodeSubselect-installed LIMIT 1 breaks the loop.
        Previously the gate exited early so the subroutine body was
        empty (just OP_Null + OP_Return).  Verified via DiagSubsel:
        `SELECT (SELECT a FROM t)` now returns 42; bytecode mirrors C
        modulo the deferred OP_Explain EQP metadata.  DiagFeatureProbe
        divergences 13 → 12; TestExplainParity unchanged
        (1012 pass / 14 diverge).
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
      [ ] **d-INNER) `INNER JOIN` aggregate raises SQL logic
        error.** `SELECT count(*) FROM t INNER JOIN u ON t.a=u.b`
        prepares cleanly (bytecode generated by the agg-no-GROUP-BY
        gate) but `step` returns SQLITE_ERROR.  Bytecode diff vs C:
        Pas omits the bloom-filter OP_Explain (C:[8] `BLOOM FILTER
        ON u`) and emits OP_Filter/OP_SeekGE/OP_IdxGT *without* the
        p4 KeyInfo carried by C.  Root cause is in the auto-index
        + bloom-filter codegen path inside sqlite3WhereBegin (not
        the agg gate, not pSTab resolution as previously diagnosed).
        Closes once whereBloomFilterOptHelper / setupAutoIndex
        wire p4 KeyInfo + the bloom-filter explain.
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
      [ ] **i) GENERATED column virtual.**
        Inserting into `(a INTEGER, b INTEGER GENERATED ALWAYS AS (a*2)
        VIRTUAL)` and selecting `b` returns 0 instead of `a*2`.
        Tracked under 6.24 (`sqlite3ComputeGeneratedColumns`).
      [ ] **j) AFTER INSERT trigger does not fire.**
        Side-table populated by the trigger remains empty.  Tracked
        under 6.23 (trigger codegen stubs).
      [ ] **k) `pragma_table_info(...)` table-valued function.**
        `SELECT count(*) FROM pragma_table_info('t')` returns no row.
        Tracked under 6.12 (sqlite3Pragma).

  [ ] **6.10 step 10** Built-in scalar function bugs (surfaced via the
      DiagFunctions probe — `src/tests/DiagFunctions.pas`, run with
      `LD_LIBRARY_PATH=$PWD/src bin/DiagFunctions`)

  [ ] **6.10 step 11** Runtime divergences surfaced by the new
      `src/tests/DiagDate.pas` probe (date/time + scalar coercion).
      Run with `LD_LIBRARY_PATH=$PWD/src bin/DiagDate`.

  [ ] **6.10 step 12** Runtime divergences surfaced by the new
      `src/tests/DiagMoreFunc.pas` probe (built-in functions / expression
      edges).  Run with `LD_LIBRARY_PATH=$PWD/src bin/DiagMoreFunc`.
      Initial run 2026-04-28 reported 27 divergences; 2 remain after
      fixes to TRUE/FALSE, printf width/flags, %e, %c, %q, %Q,
      TK_AND/TK_OR/TK_BETWEEN/TK_IN scalar arms, and math-function
      registration.  Both remaining divergences are `count(*)` /
      `sum(5)` no-FROM — same root cause as 6.10 step 7(c).
      [ ] **i) Built-in scalar functions missing.**
        [X] `unistr(text)` — ported 2026-04-28 (func.c:1174).
            Decodes \XXXX / \uXXXX / \+XXXXXX / \UXXXXXXXX, plus \\
            literal backslash; "invalid Unicode escape" otherwise.
            Registered as aBuiltinFuncs[78] (nArg=1).  DiagMoreFunc
            unistr 4hex / backslash / u / U / + / null → all PASS.
        [X] printf `%w` — ported 2026-04-28 (printf.c:848 etESCAPE_w).
            Doubles internal `"` characters; NULL → "(NULL)".
            DiagMoreFunc printf %w / printf %w null → PASS.
        [ ] `sqlite_compileoption_used(name)` / `sqlite_compileoption_get(idx)`
            (func.c:1042/1066) — blocked on porting `sqlite3_compileoption_used`
            / `sqlite3_compileoption_get` (ctime.c), which require the
            compile-options table not yet built on the Pas side.  Defer.
        [ ] `%b` / `%n` printf specifiers — not present in upstream
            printf.c fmtinfo[] (probe artifacts).  Drop from scope.

  [ ] **6.10 step 15** Runtime divergences surfaced by the new
      `src/tests/DiagTxn.pas` probe (transactions, savepoints, conflict
      resolution, ROWID/IPK alias edges, BLOB literals, PRAGMA round-trips,
      typeof boundaries, NULL propagation).  Run with
      `LD_LIBRARY_PATH=$PWD/src bin/DiagTxn`.  Initial sweep (~52 cases)
      reported 14 divergences; 1 fixed.  Most remaining fold into already-
      tracked gaps (sqlite3Pragma, sqlite3GenerateConstraintChecks,
      sqlite3Update body).
      [X] **a) `total_changes()` returned 0 after INSERT** — fixed
        2026-04-28.  `sqlite3VdbeHalt` (vdbe.pas:3328) was a stub that
        only closed cursors; never flushed `v^.nChange` to the connection.
        Per vdbeaux.c:3481, when `p->changeCntOn` is set the halt path
        must call `sqlite3VdbeSetChanges(db, p->nChange)` and reset
        `p->nChange = 0`.  Added that arm gated on `VDBF_ChangeCntOn`.
        DiagTxn `total_changes()` → PASS; no regression in
        TestExplainParity (1016/10) or any of TestVdbeTxn / TestVdbeAgg /
        TestSelectBasic / TestParser / TestDMLBasic / TestSchemaBasic /
        TestWhereBasic / TestVdbeRecord / TestVdbeApi (all green).
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
      [ ] **g) Most PRAGMAs return no row** — partially closed
        2026-04-28.  Extended `sqlite3Pragma` (codegen.pas:25427) with
        explicit arms for application_id (read+write via
        PragTyp_HEADER_VALUE / pragma.c:2324), user_version SET (same
        path, was read-only), page_size (PragTyp_PAGE_SIZE /
        pragma.c:598 — captures sqlite3BtreeGetPageSize at codegen),
        cache_size (PragTyp_CACHE_SIZE / pragma.c:882 — reads
        pSchema^.cache_size, now seeded to SQLITE_DEFAULT_CACHE_SIZE
        in sqlite3SchemaGet), and synchronous (PragTyp_SYNCHRONOUS /
        pragma.c:1132 — reads safety_level-1).  DiagTxn pragma
        divergences 6 → 1.  Remaining: `journal_mode` — needs a real
        OP_JournalMode runtime arm (currently a 0-returning stub at
        vdbe.pas:8140) plus the per-db pager journal-mode plumbing.
        Full table-driven `pragmaLocate` dispatch still deferred
        under 6.12.

  [ ] **6.11** DROP TABLE remaining gap (current Δ=26, was Δ=21):
    (a) [X] ONEPASS_MULTI promotion landed in sqlite3WhereBegin,
        the sqlite_schema scrub now uses one-pass inline delete.
    (b) [ ] Pas elides the destroyRootPage autovacuum follow-on (~26 ops)
        because `destroyRootPage` calls `sqlite3NestedParse(UPDATE
        sqlite_schema ...)` and productive `sqlite3Update` is still
        skeleton-only.  This is the only remaining contributor.
  [ ] **6.12** port sqlite3Pragma in full
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
  [ ] **6.28** sweep — re-search for "stub" in the pascal source code and
       port from C to pascal in full any function or procedure still
       marked as "stub" that was missed by 6.16..6.27 (catch-all).
---

## Phase 7 — Parser (one gate open)

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

- [ ] **10.1a** Skeleton + arg parsing + REPL loop.  Entry point,
  command-line flag parser, `ShellState` struct, line reader,
  prompts, the read-eval-print loop, statement-completeness via
  `sqlite3_complete`, exit codes.  Gate: `tests/cli/10a_repl/`.

- [ ] **10.1b** Output modes + formatting controls.  `.mode`
  (`list`, `line`, `column`, `csv`, `tabs`, `html`, `insert`, `quote`,
  `json`, `markdown`, `table`, `box`, `tcl`, `ascii`), `.headers`,
  `.separator`, `.nullvalue`, `.width`, `.echo`, `.changes`,
  `.print` / `.parameter` (formatting-only subset), Unicode-width
  helpers, box-drawing renderer.  Gate: `tests/cli/10b_modes/`.

- [ ] **10.1c** Schema introspection dot-commands.  `.schema`,
  `.tables`, `.indexes`, `.databases`, `.fullschema`,
  `.lint fkey-indexes`, `.expert` (read-only subset).  Gate:
  `tests/cli/10c_schema/`.

- [ ] **10.1d** Data I/O dot-commands.  `.read`, `.dump`, `.import`
  (CSV/ASCII), `.output` / `.once`, `.save`, `.open`.  Gate:
  `tests/cli/10d_io/`.

- [ ] **10.1e** Meta / diagnostic dot-commands.  `.stats`, `.timer`,
  `.eqp`, `.explain`, `.show`, `.help`, `.shell`/`.system`, `.cd`,
  `.log`, `.trace`, `.iotrace`, `.scanstats`, `.testcase`,
  `.testctrl`, `.selecttrace`, `.wheretrace`.  Gate:
  `tests/cli/10e_meta/`.

- [ ] **10.1f** Long-tail / specialised dot-commands.  `.backup`,
  `.restore`, `.clone`, `.archive`/`.ar`, `.session`, `.recover`,
  `.dbinfo`, `.dbconfig`, `.filectrl`, `.sha3sum`, `.crnl`,
  `.binary`, `.connection`, `.unmodule`, `.vfsinfo`, `.vfslist`,
  `.vfsname`.  Out-of-scope dependencies (session, archive, recover)
  may stub with the upstream `SQLITE_OMIT_*` "feature not compiled
  in" message.  Gate: `tests/cli/10f_misc/`.

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
