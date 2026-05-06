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

* `bin/TestExplainParity` — the **bytecode** gate.  1025/1026 SQL statements
  emit byte-identical VDBE vs C as of 2026-05-03.  Only the multi-row VALUES
  coroutine arm row remains (see "Open Bugs" 6.10 step 6).
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

> **2026-05-05 (a3):** TestExplainParity reports **1025 / 1026 PASS**
> (re-confirmed after Phase 7.1.1 InitOne/Init port lands).  Only the
> multi-row VALUES coroutine row diverges (C=22 vs Pas=17 ops; see
> 6.10 step 6).

- [X] **6.8.0** Pragma (pragma.c): `sqlite3PragmaVtabRegister`

- [X] **6.8.2** port `sqlite3GenerateConstraintChecks`

- [X] **6.8.3** port `sqlite3CompleteInsertion` (insert.c)

- [X] **6.8.4** port `sqlite3WhereBegin` (where.c) — DONE.
     Gate: TestExplainParity SELECT-WHERE corpus + DiagIndexing
     `indexed by ok` / `not indexed` + DiagCovering (closes
     6.10 step 26(e)).
     [X] Allocate `WhereInfo` + per-loop `WhereLevel` array.
     [X] Drive `whereLoopAddAll` + `wherePathSolver` for the
          cost-based plan.
     [X] Single-table fast path: every shape whereShortCut bails on
          now routes through codeOneLoopStart (WHERE_OR_SUBCLAUSE
          recursion, virtual tables, viaCoroutine, INDEXED BY / NOT
          INDEXED).
     [X] `not indexed` / `INDEXED BY` honour (DiagIndexing PASS).
     [X] Multi-table loop nesting + per-loop WHERE-clause splitting
          — sqlite3WhereBegin iterates `for ii := 0 to nTabList - 1`
          driving codeOneLoopStart per level; TestExplainParity
          1025/1026 with the only remaining divergence being the
          INSERT VALUES coroutine (tracked under 6.10 step 6,
          unrelated to WHERE).
     [X] Bloom-filter and covering-index arms (covers 6.10 step 9
          d-INNER).  Bloom-filter machinery: whereCheckIfBloomFilterIsUseful
          (where.c:6622) wired post-wherePathSolver, full
          sqlite3ConstructBloomFilter (where.c:1273) wired into the
          per-level loop in sqlite3WhereBegin alongside
          constructAutomaticIndex; DiagBloom probe lands as a tripwire.
          Covering-index pick now lands too: whereShortCut's synthetic
          SCAN fallback (codegen.pas:15842..15878) was firing whenever
          its ONEROW probes failed, swallowing every shape that
          should have flowed into wherePathSolver.  Fix: defer to the
          cost-based planner whenever the table has any non-partial
          index (regardless of pWC^.nTerm).  DiagCovering tripwire
          asserts `CREATE INDEX i1 ON t(a,b); SELECT a,b FROM t
          WHERE a > 0` and the WHERE a=4 variant now open the index
          cursor and emit SeekGT / SeekGE+IdxGT (PASS, matches C
          oracle "SEARCH t USING COVERING INDEX i1 (a>?)").
          TestExplainParity unchanged at 1025/1026 — the EXPLAIN
          corpus never fires DDL so its t/s/u tables stay
          index-free, so the fix is functionally invisible there;
          DiagCovering closes the gap for shapes that do see real
          indices.

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
     [X] RETURNING clause emission — DiagDml RETURNING corpus PASS.
          codeReturningTrigger body now ports trigger.c:1020 1:1 (with
          companion sqlite3ExpandReturning, sqlite3ProcessReturningSubqueries
          and the two walker callbacks); sqlite3FinishCoding now emits the
          OP_OpenEphemeral header and the Rewind/Column/ResultRow/Next tail
          (build.c:171..192 + 252..259) so RETURNING actually surfaces rows
          to step() instead of silently returning none.
     [X] Vtab xUpdate dispatch (`IsVirtual(pTab)`) — DONE.
          isVirtual flag added at the eTabType branch; register
          allocation bumps regRowid + nMem by one (insert.c:1051..1054)
          so regIns lands at argv[0].  Per-row loop now branches:
          OP_Null at regIns + OP_Null at regRowid (no IDLIST IPK
          rebinding yet — rare on vtabs), then sqlite3GetVTable +
          sqlite3VtabMakeWritable + OP_VUpdate p1=1 p2=nCol+2 p3=regIns
          p4=pVTab P4_VTAB, P5=onError (OE_Default folds to OE_Abort),
          sqlite3MayAbort.  Mirrors insert.c:1502..1564 1:1.
          GenerateConstraintChecks/CompleteInsertion are bypassed for
          vtabs.  TestExplainParity holds at 1025/1026 (no vtab DML in
          corpus); TestVtab + Test{Vdbe}Vtab{,Exec} green.
     [X] xferOptimization (`INSERT INTO t1 SELECT * FROM t2`
          fast path) — DONE.  Body ported at codegen.pas (1:1 with
          insert.c:3012..3392).  Wired into sqlite3Insert via the
          `pColumn=nil && pSelect && !pTrigger` gate (insert.c:1030)
          with `goto insert_end`.  PREUPDATE_HOOK and OMIT_SHARED_CACHE
          arms not in default build.

- [X] **6.8.5** port `sqlite3WhereEnd` (where.c) — DONE.

- [X] **6.8.1** finish porting `sqlite3Update` (update.c) — single-table
     arm DONE.  `passqlite3codegen.pas:23457..24115`, 1:1 port of
     `update.c:285..1163`.  Deferred sub-arms (early-bail today):
     [X] UPDATE FROM arm (multi-table source) — DONE.  `updateFromSelect`
          (update.c:187..274) ported just before sqlite3Update; the
          `nChangeFrom>0` early-bail is gone, and the C-reference
          register/eph allocation (update.c:670..702), MultiWrite/
          ONEPASS_OFF setup (update.c:704..708), inner-loop top
          (update.c:847..871), chngRowid arm (update.c:887..893) and
          NEW-row population from iEph (update.c:949..952) are now wired
          1:1.  Companion lifts in sqlite3Select: SRT_Upfrom passes the
          eDest gate and gets its own selectInnerLoop disposal arm
          (select.c:1355..1377); resolveExprAgainstSrcList +
          sqlite3ResolveSelectNames each grew the TK_ROW arm
          (resolve.c:976..993) so exprRowColumn / bare TK_ROW resolve
          to TK_COLUMN against pSrc->a[0].  DiagDml `update from` probe
          rewritten to actually exercise the path (was false-PASS via
          multi-statement SQL); now PASSes for real (sum=60).
     [X] Virtual-table dispatch (`updateVirtualTable`) — DONE.
          `exprRowColumn` (update.c:143) and `updateVirtualTable`
          (update.c:1196..1361) ported just before sqlite3Update; the
          single-source arm replaces the early bail at update.c:646..652.
          Scan uses a manual VOpen + VFilter(idxNum=0,argc=0) full-scan
          (mirrors codegen.pas:23253 eponymous-vtab arm) since the
          Pas WhereBegin's vtab arm is not yet wired; pWhere is applied
          in-loop via sqlite3ExprIfFalse to a per-row skip label.
          Argv layout (oldRowid/PK + newRowid/PK + col0..colN-1) is
          buffered through an ephemeral table (avoids invalidating the
          vtab cursor mid-scan), then drained by a Rewind/Column loop
          that emits OP_VUpdate per row with P5=onError (OE_Default
          folds to OE_Abort) + sqlite3MayAbort.  Multi-source FROM is
          a graceful no-op (depends on UPDATE FROM above).  Bytecode
          diverges from C (no xBestIndex pushdown) until WhereBegin
          gains its vtab arm; runtime parity for `UPDATE vtab SET …
          [WHERE …]` is restored.
     [X] RETURNING clause emission — DiagDml UPDATE-RETURNING PASS.
     [X] PREUPDATE_HOOK `OP_Delete OPFLAG_ISNOOP` arm — N/A in the
          default build (gated on SQLITE_ENABLE_PREUPDATE_HOOK, which
          oracle and Pas both compile without).

- [X] **6.9** complete the porting:
    - [X] `sqlite3VdbeRecordCompare` — full body in btree.pas:3130;
      vdbe.pas wrappers (passqlite3vdbe.pas:2154/2174) delegate.
    - [X] `sqlite3VdbeFindCompare` — full body in btree.pas:3310;
      vdbe.pas wrapper (passqlite3vdbe.pas:2181) delegates.
    - [X] **b)** Collation-aware string compare (vdbeCompareMemString
      hook from btree.pas → vdbe.pas) — required only for non-BINARY
      collated index lookups.  Same-encoding fast path landed at
      btree.pas:3221 — pIdxKey^.pKeyInfo^.aColl[i] is consulted via
      a TBtCollView opaque view (matches TCollSeq layout); xCmp is
      called directly when collEnc == kiEnc == pRhs^.enc.  Encoding-
      mismatch transcoding (vdbeCompareMemString:4450) is N/A in the
      default UTF-8 build (the only build supported by this port — the
      transcoding arm is unreachable when pMem^.enc == pColl^.enc ==
      SQLITE_UTF8 throughout the connection); same N/A pattern as the
      PREUPDATE_HOOK arm in 6.8.
    - [X] **c)** TUnpackedRecord layout reconcile — btree.pas's
      TUnpackedRecord now matches the C struct (vdbeInt.h) and
      codegen.pas TUnpackedRecord exactly (sizeof=40, fields
      pKeyInfo/aMem/u/n/nField:u16/default_rc:i8/errCode/r1/r2/eqSeen).
      Records allocated by either side are now interchangeable; the
      slim layout (i32 nField, missing u/n/r1/r2/errCode) is gone.
      aSortFlags KEYINFO_ORDER_DESC + BIGNULL inversion arm was
      already in place.
  
  [X] **6.24** Aggregate-with-ORDER-BY codegen (select.c
       `analyzeAggregate` + `generateAggSelect`).  The
       ORDER-BY-inside-aggregate arm — `group_concat(val, ',' ORDER BY
       val DESC)`, `string_agg(... ORDER BY ...)`, etc. — now honoured.
       Gate: DiagWindow `group_concat order` PASSes (closes 6.10 step
       17(b)); 13 → 12 divergences, the remaining twelve are pure
       window-function rows under 6.26.
       [X] Per-aggregate `OrderByExpr` capture during
            `sqlite3FuncDefRef` resolution — analyzeAggregate at
            codegen.pas:21647 sets iOBTab / bOBUnique / bOBPayload /
            bUseSubtype off `pExpr^.pLeft` (TK_ORDER) per select.c:5475.
       [X] Sorter open + key-encode in the inner-loop arm of
            `generateAggSelect` — iOBTab>=0 arm in
            resetAccumulatorSimple opens the per-Func ephemeral with
            KeyInfo from the ORDER BY exprs (+ Sequence / payload /
            subtype extras).  Mirrors select.c:6686..6716.
       [X] Sorted-feed of values into the aggregate step function —
            updateAccumulatorSimple's iOBTab arm encodes ORDER-BY key
            (+ Sequence + payload + subtypes), MakeRecord, IdxInsert
            into iOBTab; finalizeAggFunctionsSimple Rewinds the
            ephemeral and emits OP_AggStep per row before the
            OP_AggFinal.  Mirrors select.c:6848..6915 + 6733..6776.
       [X] DISTINCT-aggregate variant (`count(DISTINCT x)` etc.) —
            already PASSed via the iDistinct OP_Found dedup path
            already in place (DiagWindow `count distinct` /
            `sum distinct`).  C's "same sorter machinery" wording
            describes its own factoring; the Pas iDistinct ephemeral
            arm at resetAccumulatorSimple covers the same ground.

  [X] **6.26** Window functions (window.c).
       DiagWindow: 1 divergence open (multi-window arm with
       distinct partition/order specs).  All other rows PASS.
       Gate: DiagWindow — closes 6.10 step 17(c) (rank, dense_rank,
       lag, lead, first_value, ntile prepare-time failures) and step
       17(d) (`sum() OVER (...)`, `row_number() OVER (...)` empty
       result-set).
       [X] Port `sqlite3WindowRewrite` (window.c:958) — full body at
            codegen.pas, replacing the SF_WinRewrite-only stub.  Builds
            the per-window subquery, sets up nBufferCol / iEphCsr /
            iArgCol / regAccum / regResult, walks pSub with
            sqlite3WindowExtraAggFuncDepth (also ported) to bump
            outer-agg depths.  Companion callback
            disallowAggregatesInOrderByCb ported.  Not yet productively
            reachable — sqlite3Select still bails on `p^.pWin <> nil`
            (codegen.pas ~22252); CodeInit/Step land next.
       [X] Port `sqlite3WindowCodeInit` (window.c:1388) — full 1:1 body
            replacing the prior stub.  Opens iEphCsr..iEphCsr+3, allocs
            PARTITION BY register array + regOne, and per-window inline
            machinery (min/max key store, nth_value/first_value frame
            indices, lead/lag duplicate cursor).  Leaf helpers ported in
            same drop: TWindowCodeArg/TWindowCsrAndReg types,
            WINDOW_RETURN_ROW/AGGINVERSE/AGGSTEP + WINDOW_STARTING_*/
            ENDING_* constants, windowArgCount (window.c:1527),
            windowReadPeerValues (1619), windowCheckValue (1480),
            windowAggStep (1656), windowAggFinal (1775),
            windowInitAccum (1997), windowCacheFrame (2029),
            windowIfNewPeer (2055).  Not yet productively wired —
            sqlite3Select still bails on `p^.pWin <> nil`; CodeStep
            below is next gate.
       [X] Port `sqlite3WindowCodeStep` — full 1:1 body at codegen.pas
            replacing the prior stub, alongside its helpers
            windowExprGtZero (window.c:2437), windowFullScan (1814),
            windowReturnOneRow (1920), windowCodeRangeTest (2101) and
            windowCodeOp (2233).  Not yet productively wired —
            sqlite3Select still bails on `p^.pWin <> nil`; wiring is
            the next gate (closes 6.10 step 17(d)).
       [X] Wire window arm into sqlite3Select (commit 91dc50d).  Three
            landings, all in passqlite3codegen.pas:
              (a) `linkWindowsForSelect` (~22345) — pas-only stand-in
                  for the resolve.c:1314..1325 arm.  Walks pEList /
                  pOrderBy and for each EP_WinFunc-bearing TK_FUNCTION
                  calls sqlite3WindowUpdate (frame-spec patch for
                  built-ins) + sqlite3WindowLink (attaches pWin to
                  pSel).  Skips eFrmType=TK_FILTER carriers so plain
                  aggregates with FILTER aren't touched.  Without
                  this, pSel^.pWin was always nil — the entire 6.26
                  codepath was unreachable.
              (b) TK_FUNCTION fast-path in sqlite3ExprCodeTarget
                  (codegen.pas ~5638, mirrors expr.c:5358) — when
                  EP_WinFunc set and pWin^.regResult>0, return
                  pExpr^.y.pWin^.regResult directly so the inner-loop
                  column emit reads the populated window-result reg
                  instead of trying to evaluate as a scalar function.
              (c) Window arm at the old bail (~23119) — replaces the
                  `Result := SQLITE_OK; Exit;` with the C
                  select.c:8265..8331 flow for the no-isAgg /
                  no-pGroupBy pWin branch:
                    sqlite3WindowRewrite
                    materialise subquery FROM into eph rowid table
                      (mirrors the isSubqueryAgg arm at ~23495 —
                      pas's sqlite3WhereBegin doesn't yet auto-
                      materialise subquery FROMs)
                    sqlite3WindowCodeInit
                    sqlite3WhereBegin
                    sqlite3WindowCodeStep
                    coroutine inner-loop subroutine
                      (Goto iBreak / addrGosub /
                       ExprCodeTarget+Copy* / ResultRow /
                       Return regGosub / iBreak)
                  Subset gates: SRT_Output only, no DISTINCT / no
                  ORDER BY / no LIMIT.  No regressions across
                  DiagWindow / DiagAggWhere / DiagFunctions /
                  DiagFeatureProbe / DiagInnerJoin / DiagDml.
       [X] Inner-subquery materialise: clear SF_Aggregate on pSub
            before the inner `sqlite3Select(@innerDest=SRT_EphemTab)`
            call in the wired window arm (codegen.pas:23172).
            sqlite3WindowRewrite ORs SF_Aggregate from outer onto
            pSub (mirrors window.c:1086) — Pas's sqlite3Select then
            silently bails at the SF_Aggregate exit gate
            (codegen.pas:23603, the path C handles via its general
            agg codegen but Pas's agg arms gate on
            eDest=SRT_Output|SRT_Mem).  Stripping SF_Aggregate for
            the materialise restores the row-by-row eph-table fill;
            the flag is restored after so any later inspector still
            sees the C-faithful state.  Suspected previously to be
            "wrong inner column" — the bytecode column indices were
            actually correct all along; the materialise loop just
            wasn't running.
       [X] Aggregate xValue dispatch — `MakeAgg` now sets
            `fd.xValue := final_` for every built-in aggregate
            (codegen.pas:43864).  C's WAGGREGATE registers
            sum/total/avg/count/min/max with xValue=xFinalize so
            `sum(x) OVER (...)` etc. work as whole-frame window
            functions (OP_AggValue calls xValue, not xFinalize).
            Without this, AggValue produced NULL → ResultRow output
            was 0 even though AggStep accumulated correctly.  Closes
            DiagWindow `sum() OVER all` and `avg() OVER`; 12 → 10
            divergences.
       [X] Inner-sub ORDER BY support — bSort + generateSortTail
            extended to fire for SRT_EphemTab destinations.  Path 1
            from the prior open blocker (codegen.pas:24073 +
            ~24264 + ~24514): bSort gate now accepts SRT_EphemTab,
            body emit pushes ORDER BY exprs + result data into the
            sorter (non-OMITREF, non-Top-N slice), and the sort tail
            drains the sorter into the eph table via
            MakeRecord+NewRowid+Insert(APPEND) instead of
            OP_ResultRow.  Window inner sub now correctly populates
            cur5 in (PARTITION BY ++ ORDER BY) order, so the entire
            window pipeline produces rows for: `sum() running`,
            `partition sum`, `row_number basic`, `rank basic`,
            `dense_rank`, `lag basic`, `lead basic`, `first_value`,
            `ntile 2`.  10 → 1 divergence.
       [X] exprListAppendList — propagate `sortFlags` from source
            list to dup'd item (codegen.pas:47370).  Mirrors
            window.c:921; without this, DESC / NULLS FIRST clauses
            on PARTITION BY / ORDER BY were stripped during
            sub-select build.
       [X] **Last DiagWindow divergence: `partition row_num`.**
            Root cause: in `sqlite3VdbeRecordCompare` (btree.pas),
            `pRhs` was declared `PBtMemView` (a 23-byte packed
            view), but the underlying `aMem[]` array stride is
            `SizeOf(passqlite3vdbe.TMem) = 56`.  `Inc(pRhs)` after
            iter 0 advanced 23 bytes — landing inside the next
            Mem cell — and the misread `flags` field fell through
            to the final `else rc := 0` arm, so every multi-key
            compare whose first key was equal silently returned 0.
            Single-key sorts and most index probes worked because
            they exit before the increment.  Fix: introduce
            `BT_MEM_STRIDE = 56` and step `pRhs` by raw bytes
            (`pRhs := PBtMemView(PByte(pRhs) + BT_MEM_STRIDE)`).
            DiagWindow: 1 → 0 divergences.
       [X] Frame-spec emission: ROWS / RANGE / GROUPS, with all
            five bound types (UNBOUNDED PRECEDING, n PRECEDING,
            CURRENT ROW, n FOLLOWING, UNBOUNDED FOLLOWING) and
            EXCLUDE clauses.  DiagWindow rows added 2026-05-06:
            `rows preceding` / `rows following` / `rows unbounded` /
            `range current` / `range preceding` / `groups` /
            `exclude current` / `exclude group` / `exclude ties` —
            all PASS.  Root-cause fix landed in `MakeAgg`
            (codegen.pas:43922): `xInverse` was nil for
            count/sum/total/avg, so OP_AggInverse was a silent
            no-op (vdbe.pas:8927 short-circuits on
            `Assigned(pFdAgg^.xInverse)`).  Without the inverse,
            every non-default ROWS/RANGE/GROUPS frame degenerated
            to a running-sum from partition start.  Added
            `sumInverse` (port of func.c:1972) and `countInverse`
            (port of func.c:1196), wired both into MakeAgg, and
            extended the registration call to take an optional
            inverse fn.  min/max/group_concat still nil-inverse
            (fall back to windowFullScan rescan path; not needed
            by current DiagWindow rows).
       [X] Built-in window-function dispatch table:
            `row_number` / `rank` / `dense_rank` / `ntile` / `lag` /
            `lead` / `first_value` PASS.  `percent_rank` /
            `cume_dist` / `last_value` / `nth_value` confirmed PASS
            via DiagWindow rows added 2026-05-06.
       [X] Aggregate-as-window arm (`sum(x) OVER (...)`,
            `avg(x) OVER (...)`, etc.) — whole-frame case PASSes
            via MakeAgg xValue wiring; running-sum + partition-sum
            cases PASS via the bSort SRT_EphemTab extension;
            non-default frames PASS via xInverse wiring (above).
       [X] Subset-gate lift: LIMIT / OFFSET in window arm.
            Moved `computeLimitRegisters` to BEFORE
            `sqlite3WhereBegin` so the OP_Integer init lands
            outside the partition scan loop (otherwise the OP_Next
            at end of partition jumped back to the init opcode
            and the limit counter reset every iteration).  Added
            `codeOffset` + OP_DecrJumpZero around OP_ResultRow in
            the gosub body.  DiagWindow `window outer limit` /
            `window outer offset` PASS.
       [ ] Multi-window arm (one SELECT with several distinct
            OVER clauses sharing different partition/order).
            DiagWindow `multi window` (3 windows: row_number
            PARTITION grp + sum PARTITION grp + rank ORDER val)
            returns empty result set.  Two-window same-partition
            case (`multi window same partition`) PASSes — gap
            opens once the windows have incompatible specs.
            Root cause (verified 2026-05-06): `sqlite3WindowLink`
            only links windows whose specs match the first one
            already linked (`sqlite3WindowCompare(...)==0`,
            i.e. *identical*); incompatible windows stay
            orphaned with `pNextWin=nil`, never enter
            `pSel^.pWin` chain, so `sqlite3WindowCodeInit/Step`
            never populates their `regResult`.  At
            `sqlite3ExprCodeTarget` (codegen.pas:~5638) the
            EP_WinFunc fast-path falls through (regResult=0)
            and the func evaluates as a scalar, producing the
            empty result.  Fix path (matches C, but unported):
            iterate over the orphaned windows and wrap them
            in nested sub-SELECTs (like `sqlite3WindowRewrite`
            does for the linked group), one rewrite layer per
            distinct partition/order.  Substantial port —
            requires extending `selectWindowRewriteEList` to
            walk the orphan list and emit successive sub-
            SELECT layers.
       [X] Subset-gate lift: outer ORDER BY (`SELECT ... OVER ...
            FROM t ORDER BY ...`).  Sorter opened before WhereBegin;
            gosub body emits SorterInsert (orderby keys ++ result
            cols) instead of OP_ResultRow; sort tail drains via
            OpenPseudo + SorterSort + SorterData + per-col Column
            extract + ResultRow + SorterNext.  DiagWindow `window
            outer order` PASSes.  Outer-ORDER-BY-by-alias
            (`AS rn ... ORDER BY rn`) closed via ResolveAsName
            port (resolve.c:1472..1494) wired into sqlite3SelectExpr
            ahead of ResolveExprList for pOrderBy.  DiagWindow
            `window outer order alias` PASSes.
       [X] Subset-gate lift: outer DISTINCT (`SELECT DISTINCT
            ... OVER ...`).  Dedup ephemeral opened before
            WhereBegin; per-row OP_Found + IdxInsert in gosub
            body before the ResultRow / SorterInsert.  DiagWindow
            `window outer distinct` PASSes.

  [ ] **6.27** codegen.pas schema-mutation + statistics.
       Sub-rows that overlapped Phase 7 have been moved out
       (ATTACH/DETACH → 7.1.8; the ALTER trio → 7.1.9).
       [~] Port `sqlite3Analyze` (analyze.c).  Emits the bytecode
            that populates `sqlite_stat1` / `sqlite_stat4`; gates the
            cost-based planner work in 6.8.4 (without ANALYZE rows
            the planner falls back to heuristic costs and several
            DiagIndexing cases pick the wrong plan).
            Building blocks landed: `decodeIntArray`
            (analyze.c:1520..1580 — int-list + unordered/sz=N/
            noskipscan token scanner) and `analysisLoader`
            (analyze.c:1593..1650 — sqlite3_exec callback for
            sqlite_stat1 rows), wired into `analysisLoadTrampoline`
            via the new `gStat1Exec` hook (passqlite3main installs
            sqlite3_exec).
            [X] Entry-stack ported (sqlite3Analyze, analyzeDatabase,
                 analyzeTable, openStatTable, callStatGet,
                 loadAnalysis) — analyze.c:166..251 + 935..946 +
                 1384..1503.  ANALYZE now emits BeginWrite +
                 openStatTable + LoadAnalysis + Expire framing.
            [X] Port the leaf `analyzeOneTable` (analyze.c:977..1378)
                 — DONE.
            [X] Port + register StatAccum SQL function triplet
                 `stat_init` / `stat_push` / `stat_get` (analyze.c:401..923,
                 non-STAT4 build).  TStatAccum record + statAccumDestructor
                 + `sqlite3AnalyzeFunctions` registration hooked into
                 `sqlite3RegisterBuiltinFunctions`.  callStatGet and the
                 two analyzeOneTable call sites now pass the FuncDef
                 pointers directly.  Gate `DiagAnalyze` (3/3 PASS with
                 pre-created sqlite_stat1).  End-to-end ANALYZE on a
                 fresh DB still gated on Phase 7.1.1 (sqlite3InitOne) —
                 `sqlite3NestedParse('CREATE TABLE %Q.sqlite_stat1...')`
                 in openStatTable runs but the schema cache is not
                 reloaded so the subsequent OpenWrite fails.
       [X] Port `sqlite3Vacuum` (vacuum.c).
       [~] Port `sqlite3RunVacuum` (vacuum.c:143) + execSql/execSqlF —
            body landed in passqlite3main.pas, wired into OP_Vacuum via
            new vdbeRunVacuum hook.  Faithful 1:1 with the
            !SQLITE_OMIT_VACUUM && !SQLITE_OMIT_ATTACH arm; PREUPDATE_HOOK
            and AUTHORIZATION arms left out (default build).
            `VACUUM INTO 'file.db'` works end-to-end.  Plain `VACUUM`
            (in-place) still fails with rc=7 SQLITE_NOMEM and leaves
            the source DB degraded (post-VACUUM count(*) returns 0).
            Remaining gap is the in-place finalize path that swaps the
            temp btree back into aDb[0] (vacuum.c:343..366).
       [X] Port `sqlite3FkCheck` (fkey.c) — DONE.  fkScanChildren
            (fkey.c:547..660) and the dispatcher body (fkey.c:889..
            1087) ported at codegen.pas:38136..38470, replacing the
            prior stub.  Walks every FK for which pTab is the child
            (fkLookupParent) then every FK for which pTab is the
            parent (fkScanChildren).  Pairs with the runtime
            OP_FkCheck path wired in commit 775ffc0.
       [X] Port `sqlite3FkActions` + `fkActionTrigger` (fkey.c:1217..
            1442) — DONE.  Body at codegen.pas, replaces the prior
            no-op stub.  Synthesises CASCADE / SET NULL / SET DEFAULT /
            RESTRICT trigger programs (NO ACTION returns nil).  Cached
            in pFKey^.apTrigger[iAction] via the documented byte-offset
            layout; freed by sqlite3FkClearTriggerCache /
            sqlite3FkDelete.

  [ ] **6.28** sweep — re-search for "stub" in the pascal source code and
       port from C to pascal in full any function or procedure still
       marked as "stub" that was missed (catch-all).
       [~] OP_Vacuum — wired to vdbeRunVacuum hook (sqlite3RunVacuum
            ported in passqlite3main.pas).  End-to-end completion gated
            on Phase 7.1.1 schema reload after ATTACH (see 6.27).
       [X] Port `sqlite3BtreeIncrVacuum` (btree.c:4161) + `finalDbSize`
            (btree.c:4135) + `sqlite3PagerMovepage` (pager.c:7158).
            OP_IncrVacuum (vdbe.c:8174) now calls the real btree entry
            instead of unconditionally taking the jump.  With the default
            build (autoVacuum=0) the entry returns SQLITE_DONE on the
            first step — same observable behaviour as the prior stub
            but matching the upstream call shape.  incrVacuumStep /
            relocatePage / modifyPagePointer not ported (gated on a
            productive ptrmap that this port doesn't have).

### Open Bugs

- [ ] **6.10** `TestExplainParity.pas` — 1025/1026 PASS as currently
    measured (2026-05-03).  Oracle is built with `-DSQLITE_DEBUG
    -DSQLITE_ENABLE_EXPLAIN_COMMENTS`, so emits OP_Explain /
    OP_ReleaseReg (vdbeaux.c gates them under `#if !defined(SQLITE_DEBUG)`);
    Pas matches.  Only 1 corpus row still diverges.
    - [ ] **6.10 step 6** Remaining TestExplainParity bytecode-Δ rows:
        [X] `SELECT a FROM (SELECT a FROM t)` — DONE (2026-05-03).
          flattenSubquery wired into sqlite3Select before the co-routine
          arm; selectExpander cursor-assignment order corrected to match
          C (build.c:4926..4940 — outer iCursor before recursing into
          inner pSrc) so the spliced-in inner item carries the expected
          number.
        [ ] `INSERT multi-row VALUES` — Runtime parity reached; bytecode
          parity needs the coroutine arm of sqlite3MultiValues AND the
          matching sqlite3Insert consumer for a Select with a
          viaCoroutine SrcItem (reads pSubq^.regResult..+nSdst-1 in
          place — insert.c:1030..1500 chunk).  All helpers ported
          (sqlite3SrcItemAttachSubquery, sqlite3VdbeEndCoroutine,
          OP_InitCoroutine/Yield, sqlite3SelectDestInit, etc.) — the
          gap is purely the consumer side.  Deferred — runtime is
          correct via UNION-ALL fallback.
        [X] `SELECT p FROM u;` — DONE (2026-05-03).  Ported
          `estimateIndexWidth` (build.c:2236) so autoindex rows carry
          a non-zero szIdxRow, replaced the hard-coded `210` in
          `sqlite3DefaultRowEst` with the C reference's `pTable
          ->nRowLogEst` lookup (build.c:4551), and lifted the
          synthetic table-scan stand-in in `whereShortCut` for the
          no-WHERE-non-partial-index case so the cost-based planner
          can pick the covering autoindex.
  
  [X] **6.10 step 7** `DiagMisc` runtime divergences

  [~] **6.10 step 8** EQP P4 text wired on OP_Explain via
      sqlite3WhereAddExplainText.  TestExplainParity stays at 1025/1026
      (P4 stripped from the diff); no Diag regressions.
      [ ] Chase the residual planner gap on the autoindex / scan
           stand-in path so `pLoop->u.btree.pIndex` is populated on every
           non-IPK/non-vtab btree loop, then convert the nil guard in
           sqlite3WhereAddExplainText back to an Assert (matches C).

  [ ] **6.10 step 9** Runtime divergences surfaced by
      `src/tests/DiagFeatureProbe.pas` (run with `LD_LIBRARY_PATH=$PWD/src
      bin/DiagFeatureProbe`).  Most fold into existing tasks; the genuinely
      new silent-result bugs are listed first.
      [X] **c) View materialisation in SELECT.**  DONE — agg-on-subquery
        arm (codegen.pas:21088..) materialises subquery into eph cursor
        and drives Rewind/updateAccumulator/Next; `count(*) FROM v`,
        `count(*) FROM (SELECT ...)`, `sum(a) / min(a) / max(a) FROM
        (SELECT a FROM t WHERE …)` all PASS.  nAccumulator>0 bail lifted
        for the isSubqueryAgg arm (eph cursor is what the directMode
        OP_Column reads).
      [~] **e) UNION / compound SELECT.**  ORDER-BY and no-ORDER-BY
        UNION / INTERSECT / EXCEPT all dispatch through
        multiSelectByMerge (the no-ORDER-BY non-TK_ALL arm invents an
        ORDER BY 1 per select.c:2984..2994 before dispatch).
        DiagFeatureProbe `UNION compound` PASS.  UNION ALL no-ORDER-BY
        no-LIMIT inlined; LIMIT propagation through UNION ALL still
        bails.
      [~] **f) WITH / CTE not productive** — simple non-recursive CTE
        works.  Recursive CTE preps cleanly (recursion-detection arm of
        resolveFromTermToCte + early pTab^.aCol from explicit pCt^.pCols
        so recursive arm column refs resolve).  Runtime still DIVERGES:
        `WITH RECURSIVE r(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM r
        WHERE n<5) SELECT count(*) FROM r` returns 0 instead of 5.
        [X] Body ported: `generateWithRecursiveQuery` (select.c:2680..
            2826) at codegen.pas, with companion `recursiveInnerLoop`
            (select.c selectInnerLoop's srcTab>=0 arm — pseudo-cursor
            row dispatch for SRT_Output / SRT_Coroutine / SRT_Mem /
            SRT_EphemTab / SRT_Table / SRT_Set / SRT_Exists / SRT_Discard).
            Building-blocks already ported: `computeLimitRegisters`,
            `hasAnchor`.
        [X] Wire the dispatch into sqlite3Select's compound arm — DONE.
            generateWithRecursiveQuery now fires from the compound arm
            of sqlite3Select when SF_Recursive + hasAnchor; reaches the
            body with eDest=SRT_EphemTab via the agg-on-subquery path.
            Companion fix: recursiveInnerLoop's SRT_EphemTab/SRT_Table
            arm allocated NewRowid into r1+1 (collision risk); now uses
            two GetTempReg calls matching select.c:1346..1349.
        [~] Runtime parity gap — anchor row emits (`count(*) FROM r`
            returns 1, C returns 5).  Recursive step bails at
            sqlite3Select's TF_Ephemeral check (codegen.pas:23367) on
            r's synthesized table.  Lifting the bail when isRecursive
            bit ($80) is set reaches the scan body but AVs at runtime;
            likely culprit is incomplete pTab^.aCol/nCol on the
            synthetic recursive table or missing column-cache rewriting
            (C's wherecode.c isRecursive arm) for refs against iCurrent.
      [ ] **g) ALTER TABLE no-op.**
        `RENAME COLUMN` and `ADD COLUMN` both prepare+step cleanly but
        do not modify the schema.  Tracked under 7.1.9.

  [ ] **6.10 step 15** Runtime divergences surfaced by `DiagTxn`
      (transactions, savepoints, conflict resolution).  2 remain.
      [ ] **b) `BEGIN; ...; ROLLBACK` does not roll back** — DiagTxn
        `begin rollback insert` (CREATE+INSERT(1)+BEGIN+INSERT(2)+
        ROLLBACK on `:memory:`) returns count=2 instead of 1.  Reproed
        2026-05-05 in a standalone harness: `:memory:` uses
        journalMode=PAGER_JOURNALMODE_MEMORY, so the rollback path
        depends on jfd being opened (memjournal) at INSERT(2) time —
        if the lazy `pager_open_journal` from sqlite3PagerWrite is not
        firing across the autocommit→explicit-txn boundary, or the
        memjournal records do not survive into pager_playback for
        memdb, the transaction state never reverts.  Sub-bug (i) —
        nVdbeWrite/nVdbeRead counters not tracked — fixed in 1f67e38.
      [~] **c) `SAVEPOINT s; ROLLBACK TO s` does not unwind** —
        schema-cache side fixed.  Remaining: memdb pager savepoint
        reconciliation — btree pages not unwound on ROLLBACK TO.

  [ ] **6.10 step 17** Window-function and aggregate divergences
      surfaced by `DiagWindow`.  13 runtime empty-row divergences open.
      [X] **b) `group_concat(val, ',' ORDER BY val DESC)` empty** —
        Closed by 6.24.  DiagWindow `group_concat order` PASSes;
        runtime divergence count drops 13 → 12.
      [ ] **d) Window aggregates `sum() OVER ()` / `OVER (ORDER BY)`
        prepare cleanly but emit no rows** — `row_number() OVER (...)`
        same.  Window-codegen sub-issue under 6.26.

  [ ] **6.11** DROP TABLE remaining gap (current Δ=26):
    (b) [ ] Pas elides the destroyRootPage autovacuum follow-on (~26 ops)
        because the `sqlite3NestedParse(UPDATE %Q.sqlite_schema SET
        rootpage=%d WHERE …)` sub-statement emitted at codegen.pas:30076
        runs through `gNestedRunParser` but the resulting program does
        not productively rewrite sqlite_schema (sqlite3Update on system
        tables is gated on Phase 7.1.1 schema reload).  Only remaining
        contributor.
  [X] **6.12** port sqlite3Pragma in full.  Gate `DiagPragma` — all PASS.

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

- [~] **7.1.1** Schema initialisation (prepare.c).  Bodies for
       sqlite3InitOne / sqlite3Init / sqlite3ReadSchema are now ported
       1:1 with prepare.c:199..484.  TestExplainParity 1025/1026
       holds; Diag suite stable (no regressions surfaced by activating
       the productive path).  Remaining sub-arms below.
       [X] Port `sqlite3ReadSchema` — productive body in
            passqlite3codegen.pas (delegates through gSqlite3Init).
       [X] Port `sqlite3Init` — passqlite3main.pas; iterates aDb[]
            main-first / temp-last per prepare.c:438..464.
       [X] Port `sqlite3InitOne` (prepare.c:199..427) — read meta
            cookies (encoding, file_format, schema_cookie, cache_size),
            run `SELECT*FROM "<dbname>".<sqlite_master> ORDER BY rowid`
            via sqlite3_exec → sqlite3InitCallback, then
            sqlite3AnalysisLoad.  The synthesised bootstrap "table"
            row at iDb=0 is a no-op against the in-memory schema
            because sqlite3InstallSchemaTable already pre-installs
            sqlite_master before InitOne runs.
       [X] Port `sqlite3InitCallback` — already complete in main.pas
            (re-prepare under init.busy=1 publishes to tblHash).
       [X] Port `sqlite3RunParser` (tokenize.c) — already landed in
            passqlite3parser.pas:1156, productively wired through
            passqlite3main.pas:1064.  zErrMsg fallback fill
            (tokenize.c:736..738) and apVtabLock cleanup (746) ported
            2026-05-05 to bring the tail of the function to 1:1.
            Remaining omissions documented in the function header
            comment (sqlite3_log, ParserTrace, printf-style error
            formatting) are intentional — they are gated on facilities
            the supporting units do not yet expose.
       [ ] Schema-row INSERT / UPDATE wiring — sqlite3Insert against
            sqlite_master still emits zero rows, so a re-open does
            not pick up Pascal-port-created user tables (gates
            DROP TABLE 6.11(b), VACUUM 6.27, ATTACH-reload 7.1.8,
            ALTER TABLE 7.1.9).  Last load-bearing piece.

- [X] **7.1.2** `sqlite3NestedParse` full driver (build.c).

- [~] **7.1.8** ATTACH / DETACH (attach.c) — codegen path productive
       (closes the prior parse-time stubs).  Parser productions for
       ATTACH/DETACH already wired through the codegen; runtime SQL
       functions now do real work.
       [X] Port `sqlite3Attach` — emits OP_Function via codeAttach,
            attachFunc grows `db^.aDb[]`, opens the new btree, calls
            sqlite3SchemaGet + SecureDelete plumbing.  URI parsing
            now honoured via sqlite3ParseUri (passqlite3util.pas);
            pager-flag plumbing still deferred (passqlite3pager not in
            codegen's uses-list).
       [X] Port `sqlite3ParseUri` (main.c:3069..3308) — full 1:1 body
            at passqlite3util.pas, including %HH decoding, vfs/cache/mode
            option arms, SQLITE_OPEN_URI gating off bOpenUri, and the
            non-URI verbatim-copy fallback.  Wired into attachFunc so
            `ATTACH 'file:foo.db?mode=ro' AS x` and
            `ATTACH 'file:foo.db?vfs=memdb' AS x` resolve correctly.
       [X] Port `sqlite3Detach` — codeAttach emits OP_Function;
            detachFunc closes the btree, frees the `aDb[]` slot, calls
            sqlite3CollapseDatabaseArray.  TEMP-trigger pTabSchema
            rewrite stub until full TTrigger layout settles.
       [X] Wire ATTACH/DETACH parser productions — already routed
            through codeAttach via the renamed sqlite3Attach /
            sqlite3Detach.
       [ ] Schema reload after ATTACH (sqlite3Init / sqlite3InitOne)
            — gated on Phase 7.1.1.  Without it, the new aDb[] slot
            is opened but the on-disk schema is not loaded.

- [~] **7.1.9** ALTER TABLE (alter.c).  All five codegen entry points
       and all nine sqlite_rename_* / sqlite_drop_* SQL helpers have
       full bodies ported (TestParser ALTER TABLE rows PASS — gated on
       `eOpenState <> $76` matching the Insert/Update/DropIndex idiom).
       End-to-end runtime parity verified missing 2026-05-05 via local
       repro: `ALTER TABLE t RENAME COLUMN a TO aa` returns rc=0 but
       `SELECT aa FROM t` then fails with SQLITE_ERROR — purely gated
       on the Phase 7.1.1 schema-row INSERT/UPDATE wiring (sqlite_master
       mutations emit ops but rows do not persist or trigger reload).
       [X] Port `sqlite3RenameTokenRemap`.
       [X] Port `sqlite3RenameExprlistUnmap`.
       [X] Port `sqlite3AlterRenameTable` (codegen.pas:32527).
       [X] Port `sqlite3AlterFinishAddColumn` (codegen.pas:32266).
       [X] Port `sqlite3AlterAddConstraint` (codegen.pas:33144).
       [X] Port `sqlite3AlterRenameColumn` (codegen.pas:32879).
       [X] Port `sqlite3AlterDropColumn` (codegen.pas:32714).
       [X] Port `sqlite3AlterFunctions` — all nine INTERNAL_FUNCTION
            rows registered: `sqlite_fail`, `sqlite_add_constraint`,
            `sqlite_find_constraint`, `sqlite_drop_column`,
            `sqlite_rename_quotefix`, `sqlite_rename_test`,
            `sqlite_rename_column` (alter.c:1530), `sqlite_rename_table`
            (alter.c:1754), `sqlite_drop_constraint` (alter.c:2519).
            End-to-end runtime parity for `ALTER TABLE ... RENAME
            COLUMN` / `ADD COLUMN` / `DROP COLUMN` / `DROP CONSTRAINT`
            still gated on Phase 7.1.1 (sqlite3InitOne — the schema
            reload after the NestedParse'd UPDATE sqlite_master sub-
            statements is a no-op without it).  Closes 6.10 step 9(g)
            once those land.

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
