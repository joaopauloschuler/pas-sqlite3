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
      - [ ] port in full or re-enable `sqlite3Update`
      - [ ] port in full or re-enable `sqlite3GenerateConstraintChecks`
      - [X] port in full `sqlite3CompleteInsertion` (insert.c:2782..2847).
        Function is ported and compiles; not yet wired into `sqlite3Insert`
        (still inline-emits the OP_Insert path) so does not move Δ until
        `sqlite3GenerateConstraintChecks` lands and call-site swaps over.
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
    - [X] **6.10 step 4** DROP TABLE schema-row deletion now runs.
      `sqlite3NestedParse` dispatches the DELETE through the
      `gNestedRunParser` hook (registered by `passqlite3parser` at unit
      init), so the schema row is removed before OP_DropTable destroys
      the btree root.  Verified 2026-04-28: CREATE / INSERT / DROP /
      CREATE / SELECT round-trip succeeds (rc=0 / DONE on every step)
      and `SELECT name FROM sqlite_schema` no longer shows the dropped
      table.  The remaining DROP TABLE Δ=26 entry is the destroyRootPage
      autovacuum follow-on (6.11(b)).

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
        [X] **IPK-IN execution path** — string / blob / real RHS arms
            of `sqlite3VdbeRecordCompare` ported 2026-04-28 (see
            6.9-complete (a)).  Collation-aware string compare and the
            TUnpackedRecord layout reconcile remain open under
            6.9-complete (b)/(c) — neither blocks current-corpus tests.
        [ ] `SELECT DISTINCT a FROM t` — Δ=13 (DISTINCT codegen,
          ephemeral-table dedup not yet wired in `sqlite3Select`).
        [ ] `SELECT a FROM t ORDER BY a` (asc/desc/multi-col) —
          Δ=16..18 (ORDER BY sorter / ephemeral-key path: Pas emits
          only 3 ops, no sorter open / KeyInfo / sort-finalise loop).
        [ ] `SELECT a FROM t GROUP BY a` — Δ=42 (aggregate-group
          path, not yet ported).
        [X] `SELECT SUM(a)` — closed 2026-04-28 by 6.10 step 7(c3..c7)
          aggregate-no-GROUP-BY codegen path.  `SELECT MIN/MAX(a)`
          closed 2026-04-28 — added SQLITE_FUNC_NEEDCOLL to min/max
          agg registration (matching WAGGREGATE nc=1 in func.c:3300/
          3303), wired the OP_CollSeq emit before OP_AggStep in
          updateAccumulatorSimple (select.c:6918..6932), and ported
          minMaxQuery (select.c:5377) so the agg gate also passes
          minMaxFlag / pMinMaxOrderBy through to sqlite3WhereBegin
          and calls sqlite3WhereMinMaxOptEarlyOut after the inner
          loop.  Removed the prior NEEDCOLL bail in the gate now
          that updateAccumulatorSimple handles it.
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
        + 8819..9050):
        [X] **(c1)** TAggInfoCol / TAggInfoFunc / TAggInfo records
              already match the C layout (codegen.pas:433..473);
              only the lifecycle helper
              `sqlite3AggInfoPersistWalkerInit` (select.c:6121)
              remains for (c2) wiring.
        [X] **(c2)** Port `analyzeAggregate` (expr.c:7383) +
              dependencies — landed 2026-04-28.  Ported
              `sqlite3ArrayAllocate` (build.c:4680) into util.pas
              and the AggInfo helper cluster in codegen.pas:
              `addAggInfoColumn`, `addAggInfoFunc`,
              `findOrCreateAggInfoColumn`, `analyzeAggregate`,
              `sqlite3ExprAnalyzeAggregates`,
              `sqlite3ExprAnalyzeAggList`, `agginfoPersistExprCb`,
              `sqlite3AggInfoPersistWalkerInit`.  Default arm
              (`pParse->pIdxEpr` indexed-expression shortcut) is
              a documented no-op until `pIdxEpr` lands.  Code is
              uncalled until (c3) opens the SF_Aggregate gate, so
              Δ-neutral (TestExplainParity 1012/14, TestVdbeAgg
              11/11, TestSelectBasic 49/49, TestParser 45/45 all
              green).  Next: (c3) replace the
              codegen.pas:18180 `Exit` for SF_Aggregate (pGroupBy=nil)
              with the agg-codegen tail using the now-real walker.
        [X] **(c3..c7)** Aggregate-no-GROUP-BY codegen path landed
              2026-04-28.  Ported assignAggregateRegisters,
              resetAccumulatorSimple, updateAccumulatorSimple,
              finalizeAggFunctionsSimple, agginfoFreeCleanup,
              analyzeAggFuncArgs (select.c:6498/6643/6658/6724/6799/
              7101).  Added TK_AGG_FUNCTION + TK_AGG_COLUMN arms to
              sqlite3ExprCodeTarget (expr.c:4957..5004 and 5313..5325).
              Wired a new agg gate in sqlite3Select that fires for
              SF_Aggregate selects with no GROUP BY / HAVING / DISTINCT
              / Compound / Window, no DISTINCT/ORDER-BY/FILTER/NEEDCOLL
              on the agg, single- or two-table base FROM (no vtab/view/
              subquery), SRT_Output or SRT_Mem.  Pas-only Pre-step
              markAggregateInExprList rewrites TK_FUNCTION → TK_AGG_FUNCTION
              when the FuncDef has xFinalize (Pas resolver does not).
              Verified: DiagAggWhere `count(*) FROM t WHERE a IS NULL`
              now byte-identical with C; TestExplainParity 1012/14 →
              1013/13 (SUM matches; MIN/MAX still differ by 1 op due
              to the unported WHERE_ORDERBY_MIN/MAX optimisation);
              TestSelectBasic 49/49, TestVdbeAgg 11/11, TestParser
              45/45 all green.  Out of scope: COUNT(DISTINCT x), agg
              with FILTER clause, agg with ORDER BY in arg list,
              NEEDCOLL aggregates (group_concat etc.), no-FROM
              aggregate (`SELECT count(*)`).

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
        `SELECT count(*) FROM v` returns no row on Pas.  The
        `sqlite3MaterializeView` body just landed (6.24) but is wired
        only for INSTEAD OF DELETE/UPDATE; non-trigger SELECT … FROM v
        still needs view-expansion in `sqlite3SelectExpand`.
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
      `LD_LIBRARY_PATH=$PWD/src bin/DiagFunctions`):
      [X] **a) `quote(text)` drops the trailing quote** — fixed
        2026-04-28.  Both the BLOB and TEXT arms of `quoteFunc`
        (codegen.pas:24823, codegen.pas:24841) passed `p - zOut - 1`
        to `sqlite3_result_text`.  After the trailing `Inc(p)` and
        `p^ := #0` the cursor `p` already points at the null
        terminator, so `p - zOut` is the correct payload length;
        the `- 1` was an off-by-one truncating the closing `'`.
        Verified: `SELECT quote('a')` now returns `'a'` (was `'a`).
      [X] **b) `round(x, n)` text formatting** — fixed
        2026-04-28.  Ported `sqlite3Fp10Convert2` (util.c:775),
        wired the `iRound==17` round-trip arm into `fpDecode`
        (util.c:1465..1498), and added a public
        `sqlite3RenderNumF` helper in passqlite3printf.pas that
        runs the full `%!.*g` (altform2) pipeline.
        `vdbeMemRenderNum` (vdbe.pas:8581) now calls it instead
        of libc `snprintf("%.*g", ...)`.  Verified via
        src/tests/DiagFloatRender.pas (11/11 PASS); no
        TestExplainParity regression (1012 pass / 14 diverge —
        same).  Closes architectural note 5 for the REAL→TEXT
        coercion path.
      [X] **c) `substr(text, -k, n)` returns empty** — fixed
        2026-04-28.  Pas had a clamp-style branch
        (`if p1 < 1 then begin p2 := p2 + p1 - 1; p1 := 1; end`)
        that turned negative offsets into "before-string" with
        the count chopped, so `substr('hello', -3, 2)` produced
        '' instead of 'll'.  Replaced with the faithful C
        normalisation chain (func.c:382..415): `p1 += len; if
        p1<0 then ... else if p1>0 then p1--; else if p2>0 then
        p2--; if p2<0 then ...`.  Also added the missing NULL
        arms (`p1==NULL`, `p2==NULL` early-return) per
        func.c:378/391.  Indices widened to i64 to mirror C.
        DiagFunctions "substr neg" → PASS.
      [X] **d) `printf('%.2f', x)` ignores precision** — fixed
        2026-04-28.  `printfFunc`'s `f/e/E/g/G` arm called
        `FloatToStr(vDbl)`, dropping the parsed precision/width
        on the floor.  Extended `SkipFmtMeta` to capture
        width/precision (and the "have" flags), added an
        `FmtFloat` helper that maps `f→ffFixed`, `e/E→ffExponent`,
        `g/G→ffGeneral` via `FloatToStrF` and applies width
        padding/zero-fill from the captured flags.  Unadorned
        specifiers still use `FloatToStr` to preserve the prior
        natural-%g shape.  DiagFunctions "printf %.2f" → PASS.
      [X] **e) UTF-8 char advance off-by-one in `substrFunc`** —
        fixed 2026-04-28.  The slicing advance loops mishandled
        multi-byte chars: `if u8(z^) >= $80 then begin while
        (u8(z^) and $C0) = $80 do Inc(z); end; Inc(z); Inc(i)`
        treated each continuation byte as a separate char (the
        outer `>= $80` re-fires for every continuation, but
        the inner while only fires once we already moved off the
        lead).  Replaced with the SQLITE_SKIP_UTF8 shape: step
        past the lead first (`>= $C0`), then drain continuation
        bytes.  `length()` was already correct (uses
        `sqlite3Utf8CharLen`).  Verified: `substr('café',4,1)`
        now returns 'é' (was 0xC3 alone), `substr('日本語',2,1)`
        returns '本'.  DiagFunctions utf8 cases → PASS.

  [ ] **6.10 step 11** Runtime divergences surfaced by the new
      `src/tests/DiagDate.pas` probe (date/time + scalar coercion).
      Run with `LD_LIBRARY_PATH=$PWD/src bin/DiagDate`.
      [X] **a) `quote(int)` / `quote(real)` returned wrong type** —
        fixed 2026-04-28.  C semantics: quote() always returns TEXT
        (sqlite3StrAccumFinish in func.c:1265).  Pas was calling
        `sqlite3_result_value` for SQLITE_INTEGER / SQLITE_REAL,
        which copies the original value preserving its type.  Now
        renders int via `sqlite3Int64ToText` and real via
        `sqlite3RenderNumF(r, 17, altform2=true)` (matching C's
        `"%lld"` / `"%!0.17g"`), then emits as TEXT.
      [X] **b) `round(-2.5)` returned -2 (banker's) instead of -3** —
        fixed 2026-04-28.  Pas used `Int(r * factor + 0.5)` which is
        round-half-up, wrong for negatives.  Now mirrors C
        (func.c:462): `r + (r<0 ? -0.5 : +0.5)` cast to i64 — round
        half away from zero.  Also added the func.c:447 NULL-second-
        arg early-return arm, the |r|>2^52 no-fractional-part arm,
        and bumped the n cap from 15 to 30 per C.  n>0 path still
        uses factor multiply (TODO: switch to `%!.*f` once
        sqlite3RenderNumF gains a fixed-point arm — currently only
        does general/`%!.*g`); ordinary inputs match C.
      [X] **c) `last_insert_rowid()` / `changes()` / `total_changes()`
        crashed with EAccessViolation** — fixed 2026-04-28.  Root
        cause: `sqlite3VdbeMakeReady` zero-initialised aMem[]
        registers but never set `Mem.db`.  `sqlite3_context_db_handle
        (pCtx) := pCtx^.pOut^.db` therefore deref'd a NULL.  Now
        mirrors C's `initMemArray` (vdbeaux.c:2740) — every Mem slot
        gets pVdbe^.db on allocation.  Verified DiagDate
        last_insert_rowid / changes / total_changes → PASS, no
        TestExplainParity regression (1012 pass / 14 diverge — same).
      [X] **d) `date()` formatted as "2024- 1-15"** — fixed
        2026-04-28.  Pascal's `SysUtils.Format` does not honour the
        C `%0Nd` 0-pad+width syntax used throughout date.c snpFmt
        callers.  Replaced `snpFmt` with a hand-rolled C-style
        snprintf clone (parses %0Nd / %lld / %s / %05.3f / %.16g).
        Closes the date / strftime ymd / unixepoch DiagDate
        divergences.
      [X] **e) Date-time functions never registered with the DB** —
        fixed 2026-04-28.  `sqlite3RegisterDateTimeFunctions` existed
        but was not invoked by `sqlite3RegisterBuiltinFunctions`, so
        date() / time() / datetime() / julianday() / strftime() /
        unixepoch() resolved at prepare time only via the global
        builtins hash being unpopulated → SQL parser registered them
        as user functions returning NULL.  Wired through.
      [X] **f) `time('13:45:00')` / `datetime('2024-01-15 13:45:00')`
        return NULL** — fixed 2026-04-28.  Refactored `parseDateTime`
        to mirror date.c:parseYyyyMmDd + parseHhMmSs (date.c:207..366):
        accepts time-only `HH:MM[:SS[.FFF]]` (defaults date to
        2000-01-01 per date.c:269), and skips space/'T' between date
        and time.  Also fixed time/datetime/date output formatting to
        emit integer `%02d:%02d:%02d` instead of `%02d:%02d:%05.3f`
        (date.c:1283..1287 — useSubsec is off by default).
      [X] **g) `julianday('2000-01-01 12:00:00')` returns NULL** —
        closed by (f).  DiagDate "julianday epoch" → PASS.
      [X] **h) `strftime('%w', ...)` returns "%w"** — fixed
        2026-04-28.  Added %w (weekday 0=Sun..6=Sat) and %u
        (1=Mon..7=Sun) per date.c:1379.  Also added %e, %F, %k, %I,
        %l, %p, %P, %R, %T arms for strftime parity (date.c:1438..1527);
        fixed %S to emit integer seconds and %f to use %06.3f.
        Remaining unported: %g/%G (ISO week year), %j is already
        partial (uses Trunc(jd-jan1)+1 vs C's daysAfterJan01).
      [X] **i) Date modifiers (`+5 days`, `-1 month`, `start of
        month`) ignored** — fixed 2026-04-28.  Date funcs (date /
        time / datetime / julianday / strftime / unixepoch) now
        register variadic (`nArg=-1`) per date.c:1808..1813, and
        a subset port of `parseModifier` (date.c:730..1095) handles
        `±N {seconds|minutes|hours|days|months|years}` and
        `start of {day|month|year}`.  Day/month/year arms bump
        the YMD field directly with default-ceiling normalisation;
        sub-day arms add to JD and re-derive YMD via fromJulianDay.
        DiagDate divergences 3 → 0.  Out-of-scope for now: floor /
        ceiling / weekday N / unixepoch-as-modifier / localtime /
        utc / auto / julianday-as-modifier / `±YYYY-MM-DD HH:MM`
        absolute forms — call sites needing those still get NULL.
      [X] **j) `sign(x)` returns NULL** — fixed 2026-04-28.  Ported
        signFunc (func.c:2621) and registered as aBuiltinFuncs[48]
        per func.c:3427 `FUNCTION(sign,1,0,0,signFunc)`.  Returns
        -1/0/+1 for negative/zero/positive numeric inputs, NULL
        otherwise.  DiagDate sign pos/neg/zero → PASS.
      [X] **k) `'abc' GLOB '[ab]bc'` mismatches** — fixed
        2026-04-28.  Ported `patternCompare` in full (func.c:728..855)
        replacing the simplified ASCII-only `sqlite3_strglob` /
        `sqlite3_strlike` helpers.  Adds `[...]` / `[^...]` /
        `[a-z]` char-class support, UTF-8 lookahead in the wildcard
        tail-search, and `SQLITE_NOWILDCARDMATCH` semantics (mapped
        back to `SQLITE_NOMATCH` at the public-API boundary).
        Verified via DiagDate "glob []" → PASS; TestExplainParity
        unchanged (1012 pass / 14 diverge).

  [X] **6.10 step 8** Auto-named result columns carry a trailing space
      on Pas — fixed.  Root cause was `sqlite3DbSpanDup`
      (passqlite3util.pas) skipping the leading/trailing whitespace
      strip that the C reference performs (malloc.c:792).  Pas now
      mirrors C: skip leading sqlite3Isspace, decrement n while
      sqlite3Isspace at tail.  `SELECT count(*) FROM t` now returns
      `"count(*)"`.  Verified via DiagColName 4/4 PASS; no bytecode-Δ
      regression in TestExplainParity (1012 pass / 14 diverge — same
      as before).

  [ ] **6.10 step 12** Runtime divergences surfaced by the new
      `src/tests/DiagMoreFunc.pas` probe (built-in functions / expression
      edges).  Run with `LD_LIBRARY_PATH=$PWD/src bin/DiagMoreFunc`.
      Initial run 2026-04-28 reported 27 divergences; 2 remain after
      fixes to TRUE/FALSE, printf width/flags, %e, %c, %q, %Q,
      TK_AND/TK_OR/TK_BETWEEN/TK_IN scalar arms, and math-function
      registration.  Both remaining divergences are `count(*)` /
      `sum(5)` no-FROM — same root cause as 6.10 step 7(c).
      [X] **a) Default arm of `sqlite3ExprCodeTarget` emits OP_Null
        for TK_BETWEEN / TK_IN / TK_AND / TK_OR.**  Fixed 2026-04-28.
        Ported the four scalar arms from expr.c:5208..5512 — TK_AND/
        TK_OR inline `exprCodeTargetAndOr` (sqlite3ExprSimplifiedAndOr
        + exprEvalRhsFirst + short-circuit OP_If/OP_IfNot when one
        operand is a sub-select); TK_IN emits Null/<test>/Integer 1/
        AddImm via sqlite3ExprCodeIN with split labels; TK_BETWEEN
        dispatches through exprCodeBetween's new `jumpKind=0` scalar
        arm (signature changed from `jumpIsTrue: Boolean` to
        `jumpKind: i32` so the xJump=NULL path can route through
        sqlite3ExprCodeTarget on the synthesised AND).  Verified
        DiagMoreFunc BETWEEN true/false / NOT BETWEEN / IN literal
        yes/no / NOT IN → all PASS (17 → 11 divergences).
        TestExplainParity unchanged (1012 pass / 14 diverge).
      [X] **b) `TRUE` / `FALSE` keyword literals return NULL.**
        Fixed 2026-04-28.  `SELECT TRUE` lands at parse time as a bare
        TK_ID whose TK_TRUEFALSE rewrite (resolve.c:747) was only
        triggered when the resolver had a non-nil pSrc.  Now
        `sqlite3ExprIdToTrueFalse` is also invoked at the no-FROM /
        no-column-match tail of ResolveExpr (codegen.pas:7298 +
        the new bare-TK_ID arm right after).  DiagMoreFunc TRUE /
        FALSE → PASS; TestExplainParity unchanged (1012 pass / 14
        diverge).
      [X] **c) Math functions not registered.**  Fixed 2026-04-28.
        Ported `ceilingFunc`, `logFunc`, `math1Func`, `math2Func`,
        `piFunc` (func.c:2455..2614) and registered the full
        `func.c:3391..3425` math table — ceil/ceiling/floor/trunc,
        ln/log/log10/log2/log(B,X), exp, pow/power/mod, acos/asin/
        atan/atan2, cos/sin/tan, cosh/sinh/tanh, acosh/asinh/atanh,
        sqrt, radians, degrees, pi.  C reference stashes a libm
        function pointer in `pUserData`; the Pas port stores a
        small integer tag (`MATH_TAG_*`) instead, since Pascal
        cannot portably round-trip an arbitrary function pointer
        through a `Pointer` slot.  `valueIsNumericLike` mirrors C's
        `sqlite3_value_numeric_type` filter (returns 1 for int/real
        or TEXT/BLOB that parse to numeric).  DiagMoreFunc sqrt /
        exp / ln / pow / sin / cos / floor / ceil / pi → all PASS;
        TestExplainParity unchanged (1012 pass / 14 diverge).
      [X] **d) printf/format width / flag specifiers** — fixed
        2026-04-28.  Added `ApplyIntWidth` / `FmtSignedInt` helpers
        that honour width / '-' / '0' / '+' / ' ' flags for integer
        specifiers (d/i/u/x/X/o); rewrote `FmtFloat` so %e/%E always
        take the scientific-notation arm via the new `FmtSciE` helper
        (mantissa with `prec` fractional digits, lowercase/upper
        'e±NN' with 2-digit minimum exponent — matches printf.c
        et_EXP behaviour).  `%c` now mirrors printf.c:752..761 by
        copying the first UTF-8 character of the textified arg
        (printf invoked via SQL function takes the bArgList branch).
        DiagMoreFunc %05d / %-5d / %+d / %e / %c → PASS.
      [X] **e) printf %q drops outer quotes; %Q not implemented**
        — fixed 2026-04-28.  `%q` no longer wraps in outer quotes
        (just doubles internal `'`, NULL → "(NULL)" per printf.c:861);
        `%Q` arm added (wraps in outer quotes, NULL → "NULL").
        DiagMoreFunc %q / %Q str / %Q null → PASS.
      [X] **f) Aggregate-no-FROM no-row.**  Closed 2026-04-28.  Added
        an `agg-no-FROM` arm in `sqlite3Select` (codegen.pas, just after
        the no-FROM fast path) that handles SF_Aggregate with
        `pSrc=nil` / `nSrc=0` by emitting reset / AggStep / AggFinal
        / ResultRow with no WhereBegin/End wrapper.  Surfaced two
        latent runtime bugs in the aggregate plumbing that broke
        finalize for *every* aggregate (count/sum/min/max/avg) — both
        fixed in the same commit:
          - `sqlite3_aggregate_context` (vdbe.pas) was not setting
            `pAggMem^.u.pDef := pCtx^.pFunc`; MemFinalize relies on
            this when MEM_Agg is set, so the FuncDef pointer was
            picked up as nil/garbage and finalize silently fell
            through to MEM_Null.
          - `sqlite3VdbeMemFinalize` (vdbe.pas) called
            `sqlite3VdbeMemRelease` after `xFinalize`, which recursed
            via `vdbeMemClearExternAndSetNull`'s MEM_Agg arm back into
            MemFinalize.  Replaced with the direct
            `sqlite3DbFreeNN(zMalloc)` cleanup C uses
            (`vdbemem.c sqlite3VdbeMemFinalize`).
          - `TSumAcc` (codegen.pas) inverted: `isInt` was False on
            allocation (FillChar zero) so the integer-tracking arm
            never fired and `SUM(5)` came back as REAL 5.0.  Renamed
            to `approx`/`cnt` and aligned with C's SumCtx: track
            both `iVal` (i64) and `rVal` (double) every step, set
            `approx` only on a non-integer arg, return integer iff
            `!approx`, return NULL when `cnt=0`.
        DiagMoreFunc 2 → 0 divergences; TestExplainParity 1012 pass
        / 14 diverge → 1013 pass / 13 diverge (no regressions).
        TestSelectBasic / TestVdbeAgg / TestParser / TestDMLBasic /
        TestSchemaBasic / TestWhereBasic / TestWhereSimple all green.
      [X] **g) printf `%s` precision / width ignored.**  Fixed
        2026-04-28.  `%s` arm appended raw with no truncation/padding;
        now honours width + precision per printf.c et_STRING (precision
        truncates, '-' flag left-aligns, otherwise right-aligns with
        spaces).  `%.5s 'abcdefg'` → "abcde", `%10.5s` → "     abcde",
        `%-10.5s|` → "abcde     |".
      [X] **h) printf `%g`/`%G` exponent missing '+' sign.**  Fixed
        2026-04-28.  FPC's `FloatToStr` / `FloatToStrF` emit
        "1.5E20" without the '+', whereas C printf always emits
        "1.5e+20" / "1.5E+20".  Post-process inserts '+' after E/e
        when no explicit sign follows.  Verified `printf('%G',1.5e20)`
        → "1.5E+20".
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
       (`addModuleArgument` already fully ported — parser.pas:2020.
       `sqlite3Reindex` ported in full — parser.pas:1821.)
       [X] `sqlite3TriggerUpdateStep` + Insert/Delete/Select step
            siblings — ported in full (trigger.c:443..635) 2026-04-28.
            Replaces the field-zeroed stubs with faithful builders:
            triggerSpanDup whitespace-normalises the span text;
            triggerStepAllocate duplicates the target SrcList via
            sqlite3SrcListDup (EXPRDUP_REDUCE) and rejects qualified
            db.tbl names inside non-temp triggers; UpdateStep wraps a
            non-empty FROM clause as a SF_NestedFrom subquery and
            appends it via sqlite3SrcListAppendList; rename-mode arms
            transfer ownership to the step (no dup) and remap zName
            via sqlite3RenameTokenRemap.  Δ-neutral on TestExplainParity
            (1012/14) — productive only after Phase 6.23 trigger
            codegen lands.
       [X] `sqlite3ExprForVectorField` + `sqlite3ExprListAppendVector` —
            ported in full (expr.c:574, expr.c:2093) 2026-04-28.
            ExprForVectorField builds TK_SELECT_COLUMN nodes for
            TK_SELECT vectors, returns/duplicates element exprs for
            TK_VECTOR / scalar inputs (with rename-mode ownership
            transfer arm).  AppendVector replaces the parse-time
            "vector assignment not yet supported" error stub; vector
            UPDATEs (`SET (a,b)=(...)` / `SET (a,b)=(SELECT ...)`)
            now reach codegen.  Δ-neutral on TestExplainParity (1012
            pass / 14 diverge — same), DiagFeatureProbe unchanged
            (12 divergences); productive runtime gated on
            `sqlite3Update` body.
       [X] `sqlite3CteNew` / `sqlite3WithAdd` — ported in full
            (build.c:5702, 5753) 2026-04-28.  TWith stub replaced with
            faithful header layout (nCte/bView/pOuter + flex array of
            TCte = zName/pCols/pSelect/zCteErr/pUse/eM10d, sizeof=48).
            sqlite3WithDelete + sqlite3CteDelete + cteClear added so the
            CTE allocations are released cleanly; duplicate-name check
            via sqlite3MPrintf + sqlite3ErrorMsg.  Δ-neutral on
            TestExplainParity (1012 pass / 14 diverge); CTE codegen
            still gated on full select.c CTE expansion, so DiagFeatureProbe
            CTE probes still diverge.
  [ ] **6.21** port vdbe.pas stubs in full from C to pascal:
       `sqlite3VdbeMultiLoad` (blocked: only used by pragma.c and
       requires va_list — defer until 6.12 sqlite3Pragma lands),
       `sqlite3VdbeDisplayComment` (blocked: needs opcode-synopsis
       tables appended after each name in sqlite3OpcodeName — Pas
       OpcodeNames table is plain names only, defer),
       `sqlite3VdbeList`, `sqlite3_blob_open`,
       `sqlite3AnalysisLoad`.
       [X] `sqlite3VdbeDisplayP4` — ported in full (vdbeaux.c:1905)
            2026-04-28.  Inline arms in vdbe.pas handle FUNCDEF/
            FUNCCTX/INT32/INT64/REAL/MEM/VTAB/INTARRAY/SUBPROGRAM/
            SUBRTNSIG/COLLSEQ/default; KEYINFO/TABLE/TABLEREF/INDEX
            arms dispatch through the new gDisplayP4 hook to a
            displayP4Trampoline in codegen.pas (PTable2/PIndex2/
            PKeyInfo2 not visible to vdbe.pas).  Δ-neutral on
            TestExplainParity (1012/14) — no current call site
            invokes DisplayP4 (sqlite3VdbeList still stubbed);
            unblocks future VdbeList port + Phase 7.4c trace gate.
       [X] `sqlite3VdbeMemTranslate` — ported in full (utf.c:242..423).
       [X] `sqlite3VdbeEnter` / `sqlite3VdbeLeave` — gated under
            `!OMIT_SHARED_CACHE && THREADSAFE>0`; this port omits
            SHARED_CACHE per Phase 4.4 (sqlite3BtreeEnter is the
            db-pointer-copy stub), so the existing no-op matches the
            default-build branch exactly.
       [X] `sqlite3VdbeCloseStatement` — vdbeaux.c:3265 early-exit guard
            ported.  The non-trivial savepoint-walk arm is gated on
            `p->iStatement<>0`, which only triggers under per-statement
            savepoints (sqlite3VdbeOpenStatement / sqlite3BtreeSavepoint —
            not yet ported); current path always returns SQLITE_OK,
            matching C's early-exit.
       [X] `sqlite3FkClearTriggerCache` — fkey.c:705 walks tblHash and
            clears apTrigger[0/1] via fkTriggerDelete; productive only
            once FK trigger codegen lands (Phase 6.23 + 6.27 FK port).
            No FKey records are populated in current build; existing
            no-op matches default behaviour.
       [X] `sqlite3Stat4ProbeFree` — vdbemem.c:2194 STAT4-only; gated off
            in default upstream build, existing no-op matches.
       [X] `sqlite3ResetOneSchema` + `sqlite3ResetAllSchemasOfConnection`
            + `sqlite3CollapseDatabaseArray` — ported in full
            (build.c:599, build.c:625, build.c:650) 2026-04-28.  vdbe.pas
            stubs now dispatch through `gResetOneSchema` /
            `gResetAllSchemas` hooks wired by codegen at unit init, so
            OP_ParseSchema fault recovery and the `resetSchemaOnFault`
            arm in OP_Halt actually clear the schemas.  ResetAllSchemas
            now honours `db^.nSchemaLock` (defers via DB_ResetWanted),
            clears DBFLAG_SchemaChange|DBFLAG_SchemaKnownOk, and calls
            CollapseDatabaseArray to release detached attached-DB slots
            past index 1.  Δ-neutral on TestExplainParity (1012/14).
       [X] `sqlite3ExpirePreparedStatements` — ported in full
            (vdbeaux.c:5337).  Walks db->pVdbe and writes (iCode+1) into
            the 2-bit `expired` field via VDBF_EXPIRED_MASK.  Replaces a
            no-op stub in vdbe.pas plus a duplicate-but-wrong impl in
            codegen.pas that ORed the full mask (= expired=3) regardless
            of iCode.
       [X] `sqlite3VdbeMemHandleBom` — ported in full (utf.c:437..465).
            Strips a UTF-16 BOM if present and updates pMem^.enc to the
            BOM-derived encoding (no byte-swap, just header adjustment).
       [X] `sqlite3VdbeSetColName` + `sqlite3VdbeSetNumCols` — ported in
            full (vdbeaux.c:2866..2911).  SetNumCols now allocates
            aColName as nResColumn*COLNAME_N Mem cells (was a no-op
            stub that only set nResColumn); SetColName stores zName via
            sqlite3VdbeMemSetText.  Vdbe destructor extended with
            vdbeReleaseColNames to free Mem-owned strings.  Verified
            via src/tests/DiagColName.pas — sqlite3_column_name now
            returns "a", "xyz" etc. instead of NULL.
       [X] `sqlite3VdbeSetP4KeyInfo` — ported in full (vdbeaux.c:1629).
            Real body lives in passqlite3codegen as setP4KeyInfoTrampoline
            (needs PIndex2 + sqlite3KeyInfoOfIndex which are codegen-private);
            registered into vdbe.pas's gSetP4KeyInfo hook at codegen
            unit-init, mirroring the existing gUnlinkAndDelete* pattern.
       [X] `sqlite3VdbeFrameMemDel` — ported in full (vdbeaux.c:2247);
            adds the frame to v->pDelFrame for deferred free.
       [X] `sqlite3VdbeNextOpcode` — ported in full (vdbeaux.c:2262).
            Pas signature corrected to mirror C (Mem* pSub instead of
            SubProgram*; piPc/piAddr/paOp out-params; rc return).
            Δ-neutral until `sqlite3VdbeList` is also ported (existing
            stubbed VdbeList does not call NextOpcode).
       [X] `sqlite3VdbeFrameRestore` — ported in full (vdbeaux.c:2812).
            Real body lived in sqlite3VdbeFrameRestoreFull but the
            externally-named entry point was a 0-returning stub; now
            forwards to the real impl.  Also fixed FrameRestoreFull's
            previously TODO'd db->lastRowid / db->nChange propagation
            (was unwritten on frame return).
       [X] `sqlite3VdbeExplainParent` — ported in full (vdbeaux.c:493).
       [X] `sqlite3VdbeScanStatus` / `sqlite3VdbeScanStatusRange` /
            `sqlite3VdbeScanStatusCounters` — gated by
            `SQLITE_ENABLE_STMT_SCANSTATUS` (off in default upstream
            build); no-op matches default-build behaviour exactly.
       [X] `sqlite3ExplainBreakpoint` — `SQLITE_DEBUG`-only debugger
            hook (vdbeaux.c:505); no-op matches default (NDEBUG) build.
       [X] `sqlite3VdbePrintSql` — `SQLITE_DEBUG`-only (vdbeaux.c:2501);
            no-op matches default-build behaviour.
       [X] `sqlite3UnlinkAndDeleteTable` / `Index` / `Trigger` and
            `sqlite3RootPageMoved` — wired via callback hooks
            (gUnlinkAndDelete{Table,Index,Trigger}, gRootPageMoved)
            registered by passqlite3codegen at unit-init.  Real ports
            live in codegen.pas; vdbe.pas's stubs now invoke the hooks
            so OP_DropTable/Index/Trigger and OP_Destroy autovacuum
            follow-on update the in-memory schema (idxHash/tblHash/
            trigHash unlink + DBFLAG_SchemaChange).  On-disk
            sqlite_schema row deletion still gated on Phase 7
            sqlite3RunParser (see 6.10 step 4).
       [X] `sqlite3VdbeError` — ported in full (vdbeaux.c:59).
            Pas signature drops the va_list (every call site already
            passes a pre-formatted plain string); strdups into db-tracked
            memory after freeing prior message.
       [X] `sqlite3VdbeSetChanges` — ported in full (vdbeaux.c:5305).
       [X] `sqlite3SystemError` — ported in full (util.c:155);
            `SQLITE_USE_SEH` arm gated off in default build, matches
            default-build behaviour.
       [X] `sqlite3VdbeLogAbort` — ported in full (vdbe.c:800).  Renders
            `statement aborts at <pc>: <errMsg>; [<prefix><sql>]` via
            sqlite3PfSnprintf and dispatches through sqlite3GlobalConfig.xLog
            (avoiding a uses-cycle to passqlite3pager).  Trigger-frame prefix
            arm honoured: when running inside a sub-program, the OP_Init's
            P4 "-- ..." trigger label is rendered as "/* ... */ ".  No
            TestExplainParity regression (1012 pass / 14 diverge — same).
       [X] `sqlite3VdbeIncrWriteCounter` — SQLITE_DEBUG-only
            (vdbeaux.c:829); existing no-op matches default-build
            behaviour exactly (release `Vdbe` record has no `nWrite`
            field).
  [ ] **6.22** port codegen.pas rename / error-offset stubs in full from C
       to pascal:
       [X] `sqlite3RecordErrorOffsetOfExpr` — ported in full
            (printf.c:1066).
       [X] `sqlite3VdbeAddDblquoteStr` — gated under
            `SQLITE_ENABLE_NORMALIZE` (off in default upstream build);
            no-op matches default-build behaviour exactly.
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
       [X] `sqlite3ColumnDefault` — ported in full (update.c:61).  Attaches
            P4_MEM default-value metadata via sqlite3ValueFromExpr (currently
            dormant — sqlite3ValueFromExpr is itself a Phase-6 stub returning
            nil; forward-wired so the P4 attach activates when ValueFromExpr
            lands), and emits trailing OP_RealAffinity on REAL-affinity
            columns of ordinary tables.  Δ-neutral against current corpus
            (no REAL-affinity schemas exercised in TestExplainParity).
       [X] `sqlite3ExprReferencesUpdatedColumn` + `checkConstraintExprNode`
            — ported in full (insert.c:1689, insert.c:1718).  Walker callback
            sets CKCNSTRNT_COLUMN/CKCNSTRNT_ROWID bits when a CHECK
            constraint or index-on-expression references an UPDATE-changed
            column.  TWalkerU gained an `aiCol: Pi32` arm (insert.c:1727).
            Productive once `sqlite3GenerateConstraintChecks` lands.
       [X] `sqlite3TableAffinity` + `sqlite3TableAffinityStr` — ported
            in full (insert.c:122, insert.c:179).  STRICT arm reachable
            once AddColumn lands TF_Strict; non-STRICT arm wired but
            Δ-neutral until call sites in sqlite3Insert /
            sqlite3GenerateConstraintChecks switch off the inline path.
       (`sqlite3CompleteInsertion` is now fully ported — see 6.9-bis 11g.2.b.)
       [X] `sqlite3MaterializeView` — ported in full (delete.c:142).  Builds
            `SELECT * FROM <view> WHERE … ORDER BY … LIMIT …` with
            SF_IncludeHidden and runs it into an SRT_EphemTab cursor for
            INSTEAD OF DELETE/UPDATE trigger paths.  Δ-neutral against the
            current corpus (no view-with-trigger tests yet); productive
            once trigger codegen lands.
       [X] `sqlite3LimitWhere` — gated under SQLITE_ENABLE_UPDATE_DELETE_LIMIT
            (off in default upstream build); existing no-op stub matches
            default-build behaviour.
  [ ] **6.25** port codegen.pas schema / index stubs in full from C to pascal:
       `sqlite3ReadSchema`, `sqlite3RunParser`.
       [X] `sqlite3PrimaryKeyIndex` — already a faithful port (build.c:1069);
            comment cleaned up.
       [X] `sqlite3CheckObjectName` — ported in full (build.c:1031): rejects
            "sqlite_" prefix outside nested parses, validates init.azInit
            tuple under db->init.busy, honours writable_schema /
            imposterTable / bExtraSchemaChecks bypass arms.
       [X] `sqlite3FreeIndex` — ported in full (build.c:546): frees
            pPartIdxWhere, aColExpr, zColAff, and azColl when isResized.
       [X] `sqlite3AddNotNull` — uniqNotNull propagation loop now ported
            (build.c:1604); flags any UNIQUE/PK index already attached
            for the column.
  [ ] **6.26** port codegen.pas where / select / window stubs in full from C
       to pascal: `sqlite3WhereExplainBloomFilter`,
       `sqlite3WhereAddExplainText`, `sqlite3WindowCodeInit`,
       `sqlite3WindowCodeStep`.
       [X] `sqlite3SelectAddTypeInfo` — ported in full (select.c:6399..6439)
            2026-04-28.  Replaced the "set SF_HasTypeInfo and exit" stub
            with the real walker: xSelectCallback2 = selectAddSubqueryTypeInfo
            (Pas) which, for every TF_Ephemeral FROM-subquery item, calls
            sqlite3SubqueryColumnTypes(pTab, pSel, SQLITE_AFF_NONE) to fill
            Column.affinity from the subquery's projection list.  Productive
            for sub-FROM type/affinity propagation once selectExpander wires
            the SF_NestedFrom / view-expansion arms; Δ-neutral on current
            corpus (TestExplainParity 1013/13, TestSelectBasic 49/49,
            TestParser 45/45, TestWhereBasic 52/0, TestVdbeAgg 11/0,
            TestDMLBasic 54/0, TestSchemaBasic 44/0 — same as before).
       [X] `sqlite3SelectPopWith` — ported in full (select.c:5857..5866)
            2026-04-28.  xSelectCallback2 used by sqlite3SelectExpand: when
            the walker unwinds back through the rightmost SELECT of a
            compound, the WITH clause is popped off pParse^.pWith via
            findRightmost(pSel)^.pWith^.pOuter (TWith record landed in 6.20).
            Δ-neutral on TestExplainParity (1012/14); current corpus has no
            CTE fixtures, productive once SelectExpand wires CTE resolution.
       [X] `sqlite3WhereMinMaxOptEarlyOut` — ported in full (where.c:124..137)
            2026-04-28.  Honours `bOrderedInnerLoop` (bit 2 of bitwiseFlags) +
            `nOBSat`; emits OP_Goto to the innermost WHERE_COLUMN_IN level's
            addrNxt or to pWInfo^.iBreak.  Wired into the agg-no-GROUP-BY
            gate via the minMaxQuery probe 2026-04-28; productive once an
            ordered index scan satisfies pMinMaxOrderBy.  Closed the MIN/
            MAX divergence in TestExplainParity (1013/13 → 1015/11).
       [X] `sqlite3KeyInfoFromExprList` — completed in full (select.c:1598)
            2026-04-28.  CollSeq nil-stub replaced with productive
            `sqlite3ExprNNCollSeq(pParse, pItem^.pExpr)` — the helper has been
            real since 6.6.  Δ-neutral on TestExplainParity (1012/14).
       [X] `sqlite3SelectCheckOnClauses` — ported in full (select.c:7398..7508)
            2026-04-28.  CheckOnCtx record + xExpr/xSelect walker callbacks
            mirror the C; selectCheckOnClausesExpr emits
            `"ON clause references tables to its right"` (or the
            table-function-argument variant) when a TK_COLUMN inside an
            ON-attributed predicate references a cursor past the join
            cursor.  TWalkerU gained a 9th case (pCheckOnCtx).  Wired from
            the tail of `sqlite3ResolveSelectNames` (mirroring
            resolve.c:2079) so SF_OnToWhere triggers the check.  Selects
            with <2 SrcList items short-circuit (matches C `nSrc>=2`
            assert).  TestExplainParity unchanged (1012 pass / 14 diverge);
            DiagFeatureProbe unchanged (12 divergences); TestParser /
            TestSelectBasic / TestWhereBasic / TestWhereSimple all green.
       [X] `wherePathMatchSubqueryOB` — ported in full (where.c:5077..5127)
            2026-04-28.  Detects whether a sub-FROM's ORDER BY (carried in
            pLoop^.u.btree.pOrderBy) satisfies leading terms of the outer
            ORDER BY without a sort.  Was a 0-returning stub silently
            disabling the SQLITE_OrderBySubq optimisation; the call site
            in wherePathSatisfiesOrderBy:12590 already passes obSat by
            address and updates pRevMask, so the optimiser now activates
            whenever a materialised sub-FROM has a productive ORDER BY.
            Δ-neutral on TestExplainParity (1012/14 — same) since the
            current corpus has no sub-FROM ORDER BY fixtures; productive
            once 6.10 step 6 sub-FROM materialise lands.
       [X] `whereRightSubexprIsColumn` — ported in full (where.c:302).
            Strips TK_COLLATE/TK_LIKELY off p->pRight and returns the inner
            TK_COLUMN node when EP_FixedCol is unset.
       [X] `sqlite3SelectWalkAssert2` — `SQLITE_DEBUG`-only assert(0) walker
            (select.c:6351); existing no-op matches default-build behaviour.
       [X] `sqlite3BtreeHoldsAllMutexes` — `#ifndef NDEBUG` only
            (btmutex.c:223), used inside assert() statements only; existing
            `Result := 1` stub matches default-build behaviour exactly.
       [X] `sqlite3ExprCollSeq` / `sqlite3ExprNNCollSeq` — ported in full
            (expr.c:248, expr.c:321).  Walks TK_COLLATE / EP_Collate
            precedence, descends through TK_CAST/TK_UPLUS/TK_VECTOR and
            SQLITE_AFF_DEFER, fetches column collation via the now-real
            sqlite3ColumnColl.  Productive return values flow into
            sqlite3KeyInfoFromExprList consumers; further KeyInfo
            wiring still gated on the rest of 6.26.
       [X] `sqlite3ColumnSetColl` / `sqlite3ColumnColl` — ported in full
            (build.c:720, build.c:745).  Packs/recovers collation name
            in the zCnName allocation.  Was a Phase 6.6 stub pair.
       [X] `sqlite3MatchEName` — ported in full (resolve.c:125).  Was a
            Phase 6.1 stub returning 0; now matches SF_NestedFrom result-
            column entries against (zDb, zTab, zCol) triples and reports
            ENAME_ROWID hits via pbRowid.  No call sites yet exercise this
            (resolveAlias / lookupName paths still gated), so Δ-neutral
            today; unblocks the SF_NestedFrom resolver work.
  [ ] **6.27** port codegen.pas alter / attach / analyze / vacuum / FK /
       extension / scalar-function stubs in full from C to pascal:
       `sqlite3AlterRenameTable`, `sqlite3AlterFinishAddColumn`,
       `sqlite3AlterAddConstraint`, `sqlite3Detach`, `sqlite3Attach`,
       `sqlite3Analyze`, `sqlite3Vacuum`,
       `sqlite3FkCheck`, `sqlite3FkActions`.
       [X] `sqlite3DeleteIndexSamples` — analyze.c:1656; gated under
            SQLITE_ENABLE_STAT4 (off in default upstream build), the
            non-STAT4 arm is a no-op pair of UNUSED_PARAMETER macros.
            Existing no-op matches default-build behaviour exactly.
       [X] `sqlite3AutoLoadExtensions` — loadext.c:908; early-exits when
            wsdAutoext.nExt==0 (the common case for this build, no auto
            extensions registered).  Productive arm requires the loadext.c
            machinery (Phase 8.9); existing no-op matches default-build
            behaviour until then.
       [X] `errlogFunc` — ported in full (func.c:1026): dispatches the
            configured xLog callback with the int code + text message.
       [X] `unlikelyFunc` — C registers `noopFunc` (=versionFunc) as the
            runtime placeholder, since the INLINEFUNC_unlikely arm folds the
            call away at compile time; existing Pas stub returning argv[0]
            is never reached during normal compilation and is benign.
       [X] `concatFunc` / `concatwsFunc` — ported in full (func.c:1656..1725)
            2026-04-28.  Shared `concatFuncCore` skips NULL args, joins
            remaining values with optional separator, allocates via
            sqlite3_malloc; concat_ws returns NULL when separator is NULL.
            Registered as aBuiltinFuncs[49]/[50] with nArg=-3/-4 per
            func.c:3329..3330.  DiagConcat 6/6 PASS after `matchQuality`
            was reworked (callback.c:299) to honour the -3/-4 min-arity
            encoding and resolveExpr now emits "no such function" /
            "wrong number of arguments to function" at parse time per
            resolve.c:1131..1278.  TestExplainParity unchanged (1012/14).
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
