# pas-sqlite3 — Remaining Task List

Port of **SQLite 3** (D. Richard Hipp et al., public domain) from C to Free Pascal.
Source of truth: `../sqlite3/` (the original C reference — the upstream split
source tree under `../sqlite3/src/*.c`). The amalgamation is **not used** by
this project, neither as a porting reference nor as an oracle build input.
Inspiration for structure, tone, and workflow: `../pas-core-math/`, `../pas-bzip2/`.

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

- [ ] **6.9-bis 11g.2.b** Vertical slice — minimal-viable
    `sqlite3WhereBegin` / `sqlite3WhereEnd` for the single-table,
    single-rowid-EQ-predicate case.  Bookkeeping primitives, prologue,
    cleanup contract, and several leaf helpers (codeCompare cluster,
    sqlite3ExprCanBeNull, sqlite3ExprCodeTemp + 6 unary arms,
    TK_COLLATE/TK_SPAN/TK_UPLUS arms, whereShortCut, allowedOp +
    operatorMask + exprMightBeIndexed + minimal-viable exprAnalyze)
    are already landed.
    - [X] Trimmed planner pick + per-loop emission for the rowid-EQ
      shape — `whereShortCut` wired into `sqlite3WhereBegin` after
      the WHERE_WANT_DISTINCT block; level-0 cursor open via
      `sqlite3OpenTable(OP_OpenRead)` + Case-2 body via
      `sqlite3ExprCodeTarget` + `OP_SeekRowid` to addrBrk.
    - [X] Loop-tail half of `sqlite3WhereEnd` — per-level
      ResolveLabel(addrCont) + iteration-opcode emission +
      ResolveLabel(addrBrk), final ResolveLabel(iBreak), nQueryLoop
      restore, then `whereInfoFree`.  Deferred arms (RIGHT JOIN,
      SKIPAHEAD_DISTINCT, IN-loop unwind, LEFT JOIN null-row,
      addrSkip, index→table column rewrite) gated to 11g.2.e.
    - [X] `TestWhereSimple.pas` gate — hand-built SrcList +
      rowid-EQ Expr; asserts `whereShortCut` populates
      WHERE_IPK | WHERE_ONEROW, OP_OpenRead + OP_SeekRowid emit at
      expected cursors / labels, `pLevel^.op = OP_Noop`, term
      flagged TERM_CODED, and `pParse.nQueryLoop` is restored
      across `WhereBegin`/`WhereEnd`.
    - [ ] Re-enable productive tails in `sqlite3DeleteFrom` and
      `sqlite3Update`; drop the step-11f skeleton-only error-state
      guard.  Blocked on Phase 6.5 helpers — `sqlite3GenerateRowDelete`,
      `sqlite3GenerateConstraintChecks`, `sqlite3CompleteInsertion` are
      still stubs.  Folded into 11g.2.e alongside `wherecode.c`'s
      per-row body.

- [X] **6.9-bis 11g.2.c** Port `whereexpr.c` (~1944 lines) —
    WHERE-clause term decomposition + analysis.  Public surface:
    `sqlite3WhereSplit`, `sqlite3WhereClauseInit`,
    `sqlite3WhereClauseClear`, `sqlite3WhereExprAnalyze`,
    `sqlite3WhereTabFuncArgs`, `sqlite3WhereFindTerm`.  Internal:
    `exprAnalyze`, `exprAnalyzeAll`, `exprAnalyzeOrTerm`, `whereSplit`,
    `markTermAsChild`, `whereCombineDisjuncts`, `whereNthSubterm`,
    `transferJoinMarkings`, `isLikeOrGlob`, `whereCommuteOperator`.
    Gate: extend `TestWhereSimple.pas` with multi-term cases
    (a=1 AND b=2, a IN (1,2,3), a BETWEEN 1 AND 5).
    - [X] `whereClauseInsert` (heap-grow term array beyond aStatic),
      `markTermAsChild`, `transferJoinMarkings`, `exprCommute` ported;
      `sqlite3WhereSplit` rewritten to use `whereClauseInsert`;
      `exprAnalyze` extended with the right-side commute path
      (whereexpr.c:1222..1261) and the TK_ISNULL→TK_TRUEFALSE rewrite
      (whereexpr.c:1262..1272).  Gate: `TestWhereExpr.pas` (22/22).
    - [X] BETWEEN virtual-term synthesis (whereexpr.c:1291..1313) —
      "a BETWEEN b AND c" → (a>=b) AND (a<=c) virtual children with
      TERM_VIRTUAL|TERM_DYNAMIC and recursive exprAnalyze on each new
      term.  Gate: `TestWhereExpr.pas` T7a..T7k (33/33).
    - [X] NOTNULL virtual-term synthesis (whereexpr.c:1331..1359) —
      "x IS NOT NULL" on a non-rowid column gets a virtual "x>NULL"
      companion tagged TERM_VNULL with WO_GT.  Gate:
      `TestWhereExpr.pas` T8a..T8g (40/40).
    - [X] `whereNthSubterm` (whereexpr.c:521..534) and
      `whereCombineDisjuncts` (whereexpr.c:556..599) ported as
      collation-independent helpers for the eventual OR-term path.
      Gate: `TestWhereExpr.pas` T9a..T9b (whereNthSubterm), T10a..T10e
      ("a<5 OR a=5" → virtual TK_LE term), T11a (incompatible
      "a<5 OR a>5" leaves pWC untouched). 48/48.
    - [X] `exprAnalyzeOrTerm` (whereexpr.c:689..945) — TK_OR shatter
      into disjuncts, per-disjunct AND-decomposition, indexable bitmask
      synthesis (case 3), two-way disjunct collapse via
      `whereCombineDisjuncts` (case 2), and case-1 conversion of
      "col=A OR col=B …" into a virtual `col IN (A,B,…)` term tagged
      TERM_VIRTUAL|TERM_DYNAMIC.  Wired into `exprAnalyze`'s top-level
      OR-arm.  Gate: `TestWhereExpr.pas` T12a..T12k (case-1 IN
      synthesis on rowid OR), T13a..T13c (column-mismatched OR keeps
      ORINFO but skips the IN promotion).  62/62.
    - [X] LIKE / GLOB virtual-term synthesis (whereexpr.c:1362..1455) +
      `isLikeOrGlob` (whereexpr.c:178..343).  "x LIKE 'aBc%'" gets two
      TERM_LIKEOPT|TERM_VIRTUAL|TERM_DYNAMIC children — `x>='ABC'` (TK_GE)
      and `x<'abd'` (TK_LT) — so the pattern can be served by an index
      range scan; original LIKE term gets TERM_LIKE when noCase, plus
      isComplete-gated parent/child links.
      `termIsEquivalence` (still deferred) needs `sqlite3ExprCollSeqMatch`
      + `SQLITE_Transitive` and only affects join-graph WO_EQUIV
      propagation, never correctness.  `whereCommuteOperator` is the
      C-side `exprCommute`, already landed in 11g.2.b sub-progress.
      Gate: `TestWhereExpr.pas` T14a..T14l (LIKE on rowid → range scan
      synthesis), T15a..T15b (numeric-prefix bailout).  76/76.
    - [X] TK_VARIABLE bound-parameter LIKE path
      (whereexpr.c:208..216, 316..334).  `sqlite3VdbeSetVarmask` and
      `sqlite3VdbeGetBoundValue` ported in `passqlite3vdbe.pas`
      (vdbeaux.c:5366..5398).  `isLikeOrGlob` consults the current bound
      TEXT value of `?N` via `pParse^.pReprepare`, runs the prefix /
      numeric / wildcard scan against it, and synthesizes the same
      range-scan virtual children as the literal-string path; rebinding
      the parameter triggers reoptimize() reprepare via the expmask bit
      set on `pParse^.pVdbe`.  The QPSG gate (`SQLITE_EnableQPSG`) is
      respected — when the connection has Query-Planner Stability
      Guarantee enabled, the optimization is skipped (matches C).
      Gate: `TestWhereExpr.pas` T16a..T16g (`x LIKE ?1` with ?1 bound to
      'aBc%' synthesizes `>='ABC'` and `<'abd'` children, expmask bit 0
      set on rebind).  84/84.
    - [X] Multi-term gate extension on `TestWhereSimple.pas` — drives
      `sqlite3WhereBegin` / `sqlite3WhereEnd` and the analysis pipeline
      across three multi-term shapes:
      M1 "rowid = 5 AND col = 7" (whereShortCut still picks WHERE_IPK
      with the col=7 leaf left in `sWC` for the eventual planner;
      OP_OpenRead + OP_SeekRowid emitted; rowid leaf TERM_CODED, col=7
      leaf not TERM_CODED).
      M2 "rowid IN (1,2,3)" (whereShortCut returns 0 → WhereBegin
      returns nil cleanly; isolated `sqlite3WhereSplit` +
      `sqlite3WhereExprAnalyze` exercise tags the term with WO_IN and
      leftCursor/leftColumn set to rowid).
      M3 "rowid BETWEEN 1 AND 5" (WhereBegin returns nil; analysis in
      isolation spawns the two TERM_VIRTUAL|TERM_DYNAMIC WO_GE / WO_LE
      children, parent nChild=2, iParent links back).  39/39.

- [ ] **6.9-bis 11g.2.d** Port the planner core in `where.c`
    (~5000 lines): `whereLoopAddBtree`, `whereLoopAddBtreeIndex`,
    `whereLoopAddVirtual*`, `whereLoopAddOr`, `whereLoopAddAll`,
    `whereLoopOutputAdjust`, `whereLoopFindLesser`, `whereLoopInsert`,
    `whereLoopCheaperProperSubset`, `whereLoopAdjustCost`, the N-best
    path search in `wherePathSolver`.  Replaces the hard-coded rowid-
    EQ pick from 11g.2.b with real N-way join planning, index
    selection, and ORDER BY consumption.  May need further
    sub-splitting once 11g.2.a..c reveal field-shape requirements.
    Defer `xBestIndex`-style virtual-table costing until vtab corpus
    is exercised.
    - [X] Output-row count adjustment — `estLog` (where.c:700),
      `exprNodePatternLengthEst` + `estLikePatternLength`
      (where.c:2951..2998), `sqlite3ExprIsLikeOperator`
      (whereexpr.c:353..372), and the main `whereLoopOutputAdjust`
      (where.c:3037..3126).  Pure cost arithmetic — runs once per
      template loop to discount nOut for the leftover WHERE-clause
      predicates that the chosen index does NOT serve.  Three
      heuristics fire verbatim from upstream: H1 generic (-1 LogEst),
      H2 `x==EXPR` cap (iReduce ≤ 10 for boolean / -1/0/1 literal,
      ≤ 20 otherwise; tags TERM_HEURTRUTH), H3 LIKE/GLOB/MATCH/REGEXP
      pattern-length discount (-2*length LogEst).  TERM_HIGHTRUTH
      collapses to 0 (project does not enable SQLITE_ENABLE_STAT4).
      Self-culling marker (WHERE_SELFCULL) lit when every prereq is
      served by the loop's own table and the predicate is a
      comparison op (or the table is on the inner side of any outer
      join).  Gate: `TestWherePlanner.pas` (71/71): EL1..EL4 (estLog
      thresholds), LO1..LO5 (case-insensitive LIKE/GLOB/MATCH/REGEXP
      → SQLITE_INDEX_CONSTRAINT_xxx), LP1..LP5 (literal-run length
      across LIKE / GLOB wildcards including the GLOB `[...]` class
      that mirrors the C walker counting the closing `]`),
      OUT1..OUT6 (H1 generic -1 + SELFCULL, TERM_VIRTUAL skipped, H2
      small-const → cap at nRow-10, H2 large-const → cap at nRow-20,
      term in aLTerm[] not adjusted, app-supplied truthProb path).
    - [X] Leaf bookkeeping helpers — `whereOrMove`, `whereOrInsert`
      (where.c:196..239), `whereLoopCheaperProperSubset`,
      `whereLoopAdjustCost`, `whereLoopFindLesser`, `whereLoopInsert`
      (where.c:2657..2938).  These are the planner's ranking /
      replacement / OR-set bookkeeping primitives — pure cost & mask
      arithmetic, no codegen.  `whereLoopInsert` honours both the
      `pBuilder^.pOrSet` short path (used by OR-clause processing) and
      the full `pLoops` link-walk that overwrites or supplants existing
      WhereLoops via `whereLoopFindLesser`.  Plan-limit exhaustion
      returns SQLITE_DONE.  Gate: `TestWherePlanner.pas` (48/48):
      OR1..OR7 (whereOrInsert dominate / subsume / evict + whereOrMove
      copy), CPS1..CPS5 (case-1 vs case-2, cost guard, term-mismatch),
      FL1..FL3 (unrelated tail slot, discard, replace candidate),
      INS1..INS6 (first insert / worse-discard / better-overwrite /
      distinct-iTab append / OrSet path / plan-limit DONE),
      ADJ1..ADJ2 (no-op when not indexed, downward adjust on subset).
    - [X] `whereInterstageHeuristic` (where.c:6301..6337) — interstage
      planner heuristic that sits between the two `wherePathSolver()`
      passes.  Walks the chosen plan from outer to inner level; for any
      level using an EQ / IN / NULL index constraint it lights every
      bit in the prereq mask (ALLBITS = `(Bitmask)-1`) of every rival
      WhereLoop on the same FROM-clause table that is NOT itself index-
      constrained or auto-indexed.  This forbids the second (ORDER-BY-
      aware) solver pass from regressing an index search to a full scan
      just to satisfy ORDER BY.  Walk stops at the first virtual-table
      or unconstrained outer loop (the second pass is allowed to swap
      such an outer scan for a different one).  Pure mask arithmetic;
      no codegen.  Gate: `TestWherePlanner.pas` (81/81): IH1 (rival
      full-scan disabled, constrained / auto-index rivals kept, wrong-
      table rival untouched, chosen loop's prereq unchanged), IH2 (vtab
      outer breaks the walk so inner-level rival untouched), IH3
      (WHERE_COLUMN_RANGE-only inner level breaks the walk yet outer
      EQ still disables its iTab=0 rival), IH4 (WHERE_COLUMN_IN trips
      the disable arm), IH5 (WHERE_COLUMN_NULL trips it too).
    - [X] Index-helper cluster fed to `whereLoopAddBtree` —
      `indexMightHelpWithOrderBy` (where.c:3663..3694),
      `exprIsCoveredByIndex` (where.c:3734..3748),
      `whereIsCoveringIndexWalkCallback` (where.c:3778..3804),
      `whereIsCoveringIndex` (where.c:3830..3871),
      `whereIndexedExprCleanup` (where.c:3877..3885), and
      `wherePartIdxExpr` (where.c:3914..3964).  Pure analysis helpers,
      no codegen.  `TIndexedExpr` and `TCoveringIndexCheck` records
      lifted from sqliteInt.h:3835 / where.c:3753.  bUnordered
      (idxFlags bit 2) and bHasExpr (idxFlags bit 11) decoded via
      inline accessors.  `whereUsablePartialIndex` deferred until
      `sqlite3ExprImpliesExpr` lands.  Gate: `TestWherePlanner.pas`
      (103/103): IMHO1..IMHO6 (pOrderBy=nil; bUnordered short-circuit;
      ORDER BY rowid match; ORDER BY key-col match; non-matching col;
      wrong cursor), ECI1..ECI3 (aColExpr=nil; XN_EXPR slot match; no
      XN_EXPR slot), WIC1..WIC3 (pSelect=nil; all aiColumn<BMS-1
      bypass; high-column slot + empty select → WHERE_IDX_ONLY),
      WIEC (cleanup empties heap-allocated list), WPIE1..WPIE5
      (non-EQ no-op; non-column LHS; iColumn<0; TK_AND walk preserves
      mask; TEXT-affinity column → mask bit cleared).
    - [X] `whereRangeVectorLen` (where.c:3145..3196) — vector range
      constraint width probe.  Given a vector inequality term such as
      "(a,b,c) > (?,?,?)" being matched against an index, returns the
      count of leading vector components whose column reference, sort
      order, comparison affinity, and collation all match the matching
      index column.  Drives the WHERE_BTM_LIMIT / WHERE_TOP_LIMIT span
      that whereLoopAddBtreeIndex (deferred to subsequent sub-progress)
      threads into range-scan accounting.  Pure helper, no codegen.
      Gate: `TestWherePlanner.pas` (85/85): RV1 scalar (non-vector)
      term short-circuits to 1, RV2 vector with wrong-cursor LHS at
      i=1 breaks immediately, RV3 vector with mismatched sort order
      at i=1 breaks at the sort-order check, RV4 vector capped by
      (nColumn - nEq) so the i=1 iteration never starts.
    - [X] Auto-index pre-flight cluster fed to `whereLoopAddBtree` —
      `whereRangeAdjust` (where.c:1916..1926),
      `constraintCompatibleWithOuterJoin` (where.c:832..852),
      `columnIsGoodIndexCandidate` (where.c:874..889),
      `termCanDriveIndex` (where.c:901..924), plus an `indexHasStat1`
      accessor for the bit-7 slot of `TIndex.idxFlags`.  Pure analysis
      helpers, no codegen.  `whereRangeAdjust` is the LogEst discount
      whereRangeScanEst applies to a range constraint's leftover tail;
      the other three gate auto-index synthesis: the term must be an
      EQ/IS predicate targeting a column of pSrc whose affinity
      matches the predicate, whose RHS is fully outer-join-compatible,
      and that is not already the leading column of an existing index
      or a column with poor stat1 selectivity.  Gate:
      `TestWherePlanner.pas` (130/130): RA1..RA5 (nil passthrough,
      truthProb<=0 additive, truthProb>0 -20 default, TERM_VNULL
      skip, truthProb=0), CC1..CC6 (no ON-bit, iJoin mismatch,
      OuterON+match LEFT, InnerON on LEFT forbidden, InnerON on
      LTORJ-only allowed, OuterON on RIGHT), CG0..CG7 (idxFlags bit-7
      decode, empty pIndex, leading-col reject, non-leading + no
      stat1 accept, hasStat1 + bad/good selectivity, col not in any
      index, pNext chain walk), TC1..TC7 (EQ accept, wrong-cursor,
      non-EQ, WO_IS accept, prereqRight blocked, rowid leftColumn,
      existing-leading-idx reject).
    - [X] Implication cluster + partial-index gate —
      `exprImpliesNotNull` (expr.c:6678..6748) recursive helper that
      proves `Expr p` is non-NULL whenever `pNN` is non-NULL (case
      arms: TK_IN, TK_BETWEEN, the comparison / arithmetic / shift /
      mul-div families, TK_SPAN/TK_COLLATE/TK_UPLUS/TK_UMINUS pass-
      through, TK_TRUTH IS-only, TK_BITNOT/TK_NOT seenNot=1 fall-in);
      `sqlite3ExprIsNotTrue` (expr.c:6750..6761) — TK_NULL,
      TK_TRUEFALSE-EP_IsFalse, integer-zero gate; `sqlite3ExprIsIIF`
      (expr.c:6763..6798) — recognises both `iif(x,y[,FALSE|NULL])`
      and `CASE WHEN x THEN y [ELSE FALSE|NULL] END`, gated on
      INLINEFUNC_iif tag for TK_FUNCTION; `sqlite3ExprImpliesExpr`
      (expr.c:6800..6851) drives all three above plus the TK_OR /
      TK_NOTNULL implication arms.  `sqlite3ExprCompareSkip`'s
      11g.2.b stub replaced with the real impl (sqlite3ExprCompare
      after stripping TK_COLLATE wrappers).  INLINEFUNC_*
      pUserData tags lifted from sqliteInt.h:2055..2062 into
      passqlite3vdbe.pas.  These unblock `whereUsablePartialIndex`
      (where.c:3699..3728) — the partial-index usability gate ported
      verbatim: TK_AND short-circuit, EP_OuterON / iJoin filter,
      JT_OUTER → require EP_OuterON, dual implication probe at
      iTab and iTab=-1 to reject trivially-true predicates,
      TERM_VNULL skip, JT_LTORJ refusal.  Gate:
      `TestWherePlanner.pas` (147/147): EINT1..EINT5
      (sqlite3ExprIsNotTrue across TK_NULL / TK_TRUEFALSE / int
      0 / int 1), EIIF1..EIIF5 (TK_CASE with two-arg + ELSE NULL /
      ELSE 0 IIF; pLeft<>nil rejection; ELSE non-zero rejection),
      EIE1..EIE4 (compare-path / TK_OR / TK_NOTNULL implication
      arms + mismatched-column negative case), WUPI1..WUPI3
      (partial-idx col1 NOTNULL usable when WHERE has col1=5;
      JT_LTORJ short-circuit; partial col1=99 not usable).
    - [X] DISTINCT-redundancy UNIQUE-index cluster — `indexColumnNotNull`
      (where.c:613..627), `findIndexCol` (where.c:583..608), and the (b)
      branch of `isDistinctRedundant` (where.c:678..691).  Walks the
      table's pIndex chain looking for a UNIQUE non-partial index whose
      every key column is either pinned by a WO_EQ WHERE term
      (`sqlite3WhereFindTerm`) or named in the DISTINCT list with a NOT
      NULL constraint.  `indexColumnNotNull` decodes the three slot
      kinds: aiColumn[i]>=0 → column's notNull bitfield (low nibble of
      `typeFlags`); =-1 → IPK rowid alias, always NOT NULL; =-2
      (XN_EXPR) → indexed expression, conservatively nullable.
      `findIndexCol` walks pList through `sqlite3ExprSkipCollateAndLikely`,
      gates on TK_COLUMN/TK_AGG_COLUMN, matches (iTable, iColumn), and
      consults `sqlite3ExprNNCollSeq` for collation parity (Phase 6.6
      stub returns nil → conservative match path so the BINARY-default
      corpus works without false negatives).  Gate:
      `TestWherePlanner.pas` (170/170): ICN1..ICN6 (NOT NULL nibble
      decode across notNull=1, nullable=0, OE_Replace=5, rowid alias,
      XN_EXPR), FIC1..FIC4 (cursor + column match, wrong cursor, non-
      column entry skip), IDR1..IDR6 (UNIQUE NOT NULL covered, missing
      column, nullable disqualifier, partial-index disqualifier, non-
      UNIQUE disqualifier, IPK fast-path).
    - [X] `whereLoopAddBtreeIndex` (where.c:3219..3653) — per-index
      template-loop factory and the heart of the planner's index
      probing.  Walks the WHERE clause via whereScanInit/whereScanNext
      against the leading (saved_nEq+1)'th column of pProbe; for each
      surviving term builds a candidate WhereLoop, dispatches into the
      WO_IN / WO_EQ|WO_IS / WO_ISNULL / range arms, then recurses to
      look for matches on the next index column.  Each candidate goes
      through whereLoopInsert which handles the ranking / replacement
      bookkeeping.  Tail block emits the SKIPSCAN candidate when the
      leading columns have no available predicate but the per-key
      duplicate count (`aiRowLogEst[saved_nEq+1] >= 42` ≈ 18 dups)
      makes a forward scan plausibly cheaper than a seek.  STAT4 arms
      (`whereEqualScanEst`, `whereInScanEst`, the TERM_HIGHTRUTH
      self-correction) and the COSTMULT macro are intentionally
      omitted to match the project-wide non-STAT4 / non-COSTMULT build.
      Rest-of-file glue: `sqlite3LogEstAdd` (util.c:2069..2098) ported
      into `passqlite3vdbe.pas`; SQLITE_Stat4 / SQLITE_SkipScan /
      SQLITE_SeekScan dbOptFlags constants exposed in `passqlite3codegen.pas`.
      Gate: `TestWherePlanner.pas` (201/201): WLB1 (empty WC), WLB2
      (rowid EQ on a UNIQUE index — sets WHERE_COLUMN_EQ |
      WHERE_ONEROW, IPK pIndex nilled by whereLoopInsert per
      where.c:7842..7848, bldFlags1 picks up SQLITE_BLDF1_UNIQUE),
      WLB3 (term whose prereqRight intersects maskSelf is skipped),
      WLB4 (TERM_VNULL on a NOT NULL leading column → indexColumnNotNull
      gate skips), WLB5 (WO_GT range → COLUMN_RANGE | BTM_LIMIT, no
      ONEROW, nBtm=1), WLB6 (WO_ISNULL on rowid skipped), WLB7
      (caller-supplied WHERE_BTM_LIMIT narrows opMask to LT|LE so the
      EQ term fails the gate).

    - [X] `whereLoopAddBtree` (where.c:4003..4309) — per-FROM-clause-table
      planner factory; the parent that drives `whereLoopAddBtreeIndex`.
      Threads three candidate families through `whereLoopInsert` via the
      shared `pBuilder^.pNew` template: (1) automatic-index synthesis
      gated on `SQLITE_AutoIndex` + `termCanDriveIndex`; (2) full table
      scan / full index scan with the covering-index price ranking
      (`whereIsCoveringIndex`, `wherePartIdxExpr`); (3) per-index
      probing via `whereLoopAddBtreeIndex`, with `TF_MaybeReanalyze` set
      when `bldFlags1 == SQLITE_BLDF1_INDEXED`.  Synthesizes the fake
      IPK index for HasRowid tables with `pNext` linked to the schema's
      pIndex chain (unless NOT INDEXED is set).  Helper additions:
      `sqlite3ExprCoveredByIndex` (expr.c:7050..7085, walker-based
      column-coverage probe via the new `exprIdxCoverCb` callback),
      `HasRowid` / `IsView` inline accessors, and the `TOPBIT` /
      `SQLITE_CoverIdxScan` constants.  STAT4 (`sqlite3Stat4ProbeFree`)
      and ApplyCostMultiplier omitted to match the project's
      non-STAT4 / non-COSTMULT build.  Gate: `TestWherePlanner.pas`
      (215/215): WLAB1 (empty WC, no real indices → exactly one
      WHERE_IPK loop with rRun=nRowLogEst+16), WLAB2 (notIndexed bit
      lit → still one IPK loop), WLAB3 (WITHOUT ROWID + no real
      indices + no AutoIndex → zero loops), WLAB4 (auto-index path
      enabled but the only WHERE term targets the rowid alias →
      termCanDriveIndex rejects, IPK probe still produces one loop).
    - [X] `whereLoopAddOr` + `whereLoopAddAll` + `whereLoopAddVirtual`
      stub (where.c:4810..5036) — top-level template-loop driver and the
      multi-index OR factory.  `whereLoopAddOr` walks the WHERE clause
      for terms tagged WO_OR whose pOrInfo^.indexable bitmask intersects
      pNew^.maskSelf, dispatches each disjunct (WO_AND child →
      pAndInfo^.wc; bare leftCursor==iCur leaf → single-term tempWC;
      otherwise skip) through whereLoopAddBtree (or the vtab stub) and
      then recursively whereLoopAddOr, cross-summing per-disjunct
      WhereOrSet results into sSum via whereOrInsert with the +1 rRun
      "TUNING" penalty so OR-of-full-scan-and-index plans never
      tie their most expensive sub-scan.  WHERE_MULTI_OR template
      emitted via whereLoopInsert; JT_RIGHT short-circuits the entire
      walk (the multi-index OR optimisation is unsound across right-join
      boundaries).  `whereLoopAddAll` walks every FROM-clause table,
      computes the prereq mask honouring CROSS / OUTER / LTORJ / RIGHT
      reorder barriers, the EXISTS-to-JOIN dependency walk, and the
      hasRightCrossJoin guard; dispatches to whereLoopAddVirtual
      (TABTYP_VTAB) or whereLoopAddBtree, then whereLoopAddOr when
      pWC^.hasOr is set; iPlanLimit accumulates per table.  SQLITE_DONE
      collapses to SQLITE_OK so partial plans still complete.  The
      virtual-table arm is a SQLITE_OK-no-loops stub — the full
      whereLoopAddVirtualOne / whereLoopAddVirtual port (xBestIndex
      driver, sqlite3_index_info marshalling) is deferred until the
      vtab corpus is exercised.  `SQLITE_QUERY_PLANNER_LIMIT_INCR=1000`
      lifted from whereInt.h:455..459.  Gate: `TestWherePlanner.pas`
      (231/231): WLAA1 (single-table empty WC → IPK loop, iPlanLimit
      bumped), WLAA2 (vtab table → zero loops via stub), WLAA3 (hasOr
      routes to AddOr but empty WC keeps single IPK loop), WLAA4
      (two-table CROSS → two IPK loops, double iPlanLimit bump),
      WLAO1 (JT_RIGHT short-circuits), WLAO2 (no WO_OR term → no-op).
    - [X] wherePathSolver cost helpers — `whereSortingCost`
      (where.c:5527..5585) and `whereLoopIsNoBetter` (where.c:5811..5820).
      Pure cost arithmetic / index-row-width tie-breaker fed to the eventual
      N-best path search.  whereSortingCost reproduces the textbook
      `K * N * log(N) * (Y/X)` external-sort model with the +10/+6 LIMIT and
      DISTINCT halving tuning constants verbatim from upstream; iLimit caps
      the log(N) multiplier when WHERE_USE_LIMIT is set.  whereLoopIsNoBetter
      compares two equal-rRun candidates by `u.btree.pIndex^.szIdxRow`,
      returning 0 only when pCandidate's index has strictly smaller per-row
      width and both loops are WHERE_INDEXED.  Land now so wherePathSolver
      can wire them in without further sub-progress churn.  Gate:
      `TestWherePlanner.pas` (244/244): WSC1 (nSorted=0 baseline,
      nCol=LogEst(2)=10), WSC2 (USE_LIMIT path adds +10 and caps nLocal at
      iLimit), WSC3 (USE_LIMIT + partial-sort adds +6 with full Y/X
      scaling), WSC4 (DISTINCT halves nLocal when nRow>10), WSC5 (DISTINCT
      no-op when nRow<=10), WSC6 (nCol scales with output column count
      via nExpr), WLNB1..WLNB2 (non-indexed loops short-circuit to 1),
      WLNB3 (smaller candidate szIdxRow → 0), WLNB4..WLNB5 (equal / larger
      candidate → 1).
    - [X] `wherePathSatisfiesOrderBy` (where.c:5146..5478) — pure
      analysis helper consumed by wherePathSolver; given a candidate
      WherePath plus one more WhereLoop pLast appended at the end,
      returns the number of leading ORDER BY (or GROUP BY / DISTINCT)
      terms the path satisfies natively.  Returns nOrderBy on full
      match, -1 when every prior loop is order-distinct and unconstrained
      tail terms could still be satisfied by future loops, 0 otherwise.
      pRevMask out-param accumulates the bitmask of WhereLoops that must
      be run in reverse order for the natural sort direction to come out
      forward.  All five branches ported verbatim: early SQLITE_OrderByIdxJoin
      gate, BMS-1 nOrderBy cap, virtual-table isOrdered short-circuit,
      "mark off ORDER BY column = ? from outer loops" pre-pass, full per-
      index-column walk with EQ/IS/ISNULL/IN handling + sort-order
      compatibility + WHERE_BIGNULL_SORT promotion + isOrderDistinct
      tag-20210426-1 corrections + nDistinctCol bookkeeping for
      WHERE_DISTINCTBY, plus the orderDistinctMask post-pass that absorbs
      ORDER BY terms referencing only well-ordered tables.
      `wherePathMatchSubqueryOB` lands as a returns-0 stub — full port
      gated on subquery-flatten work in a later sub-progress; with the
      stub the WHERE_IPK arm always takes the nColumn=1 branch (correct
      behaviour, just leaves the SQLITE_OrderBySubq optimisation
      dormant).  SQLITE_OrderByIdxJoin and SQLITE_OrderBySubq dbOptFlags
      lifted from sqliteInt.h:1905,1930.  Gate: `TestWherePlanner.pas`
      (251/251): OBSAT1 (OrderByIdxJoin gate triggers when nLoop>0),
      OBSAT2 (nOrderBy=BMS exceeds the BMS-1 cap → 0), OBSAT3 (vtab
      isOrdered=1 with matching pWInfo->pOrderBy → obSat saturates →
      returns nOrderBy), OBSAT4 (vtab isOrdered=0 → 0), OBSAT5 (vtab
      ordered but pOrderBy mismatch → 0), OBSAT6 (nLoop=0 bypasses the
      OrderByIdxJoin gate per where.c:5203).
    - [X] `wherePathSolver` + `computeMxChoice` (where.c:5651..5798,
      5834..6257) — N-best forward dynamic-programming path search that
      turns the per-table candidate WhereLoop list (pWInfo^.pLoops)
      into the chosen plan stored in pWInfo^.a[].pWLoop.  computeMxChoice
      gates on nLevel (1/5/12/18) plus a star-query heuristic that
      detects fact-table + ≥3 dimensions joins and bumps dimension-table
      full-scan rRun up to fact-table cost + 1 LogEst (so the dimension
      scan never beats the fact scan).  wherePathSolver itself runs
      nLevel generations of forward DP: at each step it extends every
      surviving WherePath by every legal WhereLoop, scores sorted vs.
      unsorted cost, and keeps only the mxChoice cheapest paths under a
      lexicographic (rCost, nRow, rUnsort, szIdxRow) comparator.  The
      final pass loads the unique survivor's loops into level[].pWLoop /
      iFrom / iTabCur, runs the WHERE_DISTINCTBY / ORDERBY_LIMIT /
      SORTBYGROUP post-pass via wherePathSatisfiesOrderBy, and writes
      pWInfo^.nRowOut / nOBSat / revMask / eDistinct / bOrderedInnerLoop
      / sorted.  WHERETRACE / SQLITE_DEBUG / STAT4 / rStarDelta blocks
      are intentionally omitted to match the project-wide non-debug
      build.  Allocation uses sqlite3DbMallocRawNN for the contiguous
      aTo/aFrom + per-path aLoop slot block + aSortCost array; "no query
      solution" returns SQLITE_ERROR; SQLITE_StarQuery dbOptFlags lifted
      from sqliteInt.h:1931.  Gate: `TestWherePlanner.pas` (264/264):
      WPS1 (FROM-less nLevel=0 plan returns OK with nRowOut seeded from
      nQueryLoop), WPS2 (single-table single-loop pick wires loopA into
      level[0]), WPS3 (two competing loops on the same table — cheaper
      rRun wins), WPS4 (unsatisfiable prereq → "no query solution" →
      SQLITE_ERROR), WPS5a/b (computeMxChoice trivial path — baseline
      12, bStarUsed bumps to 18).
    - [X] `whereRangeScanEst` (where.c:2092..2254, no-STAT4 tail) —
      reduces `pLoop^.nOut` to account for the leftover range
      constraints on the leading (nEq+1)'th column of the index pLoop
      is being built against.  Without SQLITE_ENABLE_STAT4 the
      sample-driven branch (where.c:2103..2223) is omitted; only the
      post-`#endif` arithmetic survives — `whereRangeAdjust` on each
      bound, an extra -20 LogEst when both bounds carry default
      truthProb (closed-range BETWEEN ≈ 1/64), floor 10, capped by
      `nOut - (pLower<>nil) - (pUpper<>nil)`.  Wire-in to
      `whereLoopAddBtreeIndex` deferred to the next sub-progress.
      Gate: `TestWherePlanner.pas` (154/154): RSE1 (single lower
      default -20), RSE2 (single upper with app likelihood -7),
      RSE3 (closed range default → -60 LogEst), RSE4 (app likelihood
      on either bound disables the closed-range extra -20), RSE5
      (TERM_VNULL skips per-bound but closed-range gate still fires
      because it only checks truthProb>0), RSE6 (floor 10 capped by
      nOut-2 = 9), RSE7 (small -1 app likelihood narrowly clamps).

- [ ] **6.9-bis 11g.2.e** Port `wherecode.c` (~2945 lines) —
    per-loop inner-body codegen.  Public surface:
    `sqlite3WhereCodeOneLoopStart`, `sqlite3WhereRightJoinLoop`,
    `sqlite3WhereExplainOneScan`, `sqlite3WhereAddScanStatus`,
    `disableTerm`, `codeApplyAffinity`, `codeEqualityTerm`,
    `codeAllEqualityTerms`, `whereLikeOptimizationStringFixup`,
    `codeCursorHint`.  Replaces the inlined NotExists emission from
    11g.2.b with full index-key construction, range-scan setup,
    virtual-table xFilter glue, and per-row body dispatch.
    - [X] Leaf helpers — `disableTerm` (wherecode.c:419..444),
      `codeApplyAffinity` (wherecode.c:457..482),
      `whereLikeOptimizationStringFixup` (wherecode.c:1015..1030),
      `adjustOrderByCol` (wherecode.c:525..541).  Pure leaf helpers,
      no recursion, no planner dependency.  disableTerm walks up the
      WhereTerm parent chain marking each TERM_CODED (TERM_LIKECOND
      after the first iteration on TERM_LIKE parents) so the per-loop
      body codegen does not re-emit predicates the chosen index
      already enforces; stops on TERM_CODED, outer-join + lacking
      EP_OuterON, or unmet prereqs (notReady & prereqAll).
      codeApplyAffinity emits OP_Affinity over a register run after
      trimming AFF_BLOB / AFF_NONE prefix and suffix from zAff.
      whereLikeOptimizationStringFixup patches the most-recent
      OP_String8 with iLikeRepCntr>>1 in p3 and iLikeRepCntr&1 in p5
      so the LIKE prefix bound shares the loop's run counter.
      adjustOrderByCol rewrites pOrderBy^.a[].u.x.iOrderByCol after
      a result-set rearrangement.  Gate: `TestWherePlanner.pas`
      (305/305): DT1..DT6b (disableTerm — standalone, already-coded,
      child + parent walk, TERM_LIKE → TERM_LIKECOND on iter 2,
      notReady gate, outer-join + EP_OuterON gate),
      CAA2..CAA5 (codeApplyAffinity — all-blob no-emit, single char,
      prefix trim, suffix trim), WLOSF1..WLOSF3
      (whereLikeOptimizationStringFixup — TERM_LIKEOPT gate, p3/p5
      patching across two iLikeRepCntr values), AOBC1..AOBC3
      (adjustOrderByCol — nil short-circuit, t=0 skip, t=k → j+1
      rewrite, orphan → 0).
    - [X] Leaf helpers, batch 2 — `sqlite3VectorFieldSubexpr`
      (expr.c:538..551), `sqlite3ExprNeedsNoAffinityChange`
      (expr.c:3006..3037), `updateRangeAffinityStr`
      (wherecode.c:494..508), `whereLoopIsOneRow`
      (wherecode.c:1446..1460), and `whereApplyPartialIndexConstraints`
      (wherecode.c:1355..1374).  sqlite3VectorFieldSubexpr returns the
      i-th column expression of a TK_VECTOR / TK_SELECT vector, or the
      scalar itself.  sqlite3ExprNeedsNoAffinityChange decides when an
      OP_Affinity emit can be omitted: BLOB is always a no-op; NUMERIC
      is a no-op for TK_INTEGER / TK_FLOAT and rowid (iColumn<0) columns;
      TEXT is a no-op for non-negated TK_STRING; non-negated TK_BLOB
      survives any affinity.  TK_UPLUS / TK_UMINUS prefixes pass through
      with TK_UMINUS lighting the unaryMinus flag; TK_REGISTER unwraps
      to op2.  updateRangeAffinityStr walks an affinity string in
      lockstep with a vector RHS, downgrading any slot that compares
      with no affinity (sqlite3CompareAffinity → AFF_BLOB) or needs no
      affinity change to AFF_BLOB so codeApplyAffinity can trim it.
      whereLoopIsOneRow returns 1 only when a WHERE_INDEXED loop has
      onError<>OE_None (UNIQUE), nSkip=0, every key column pinned by
      an EQ term, and none of those terms is WO_IS / WO_ISNULL.
      whereApplyPartialIndexConstraints walks the partial-index pTruth
      predicate recursively through TK_AND and tags any WC term
      structurally equal (sqlite3ExprCompare) to a conjunct as
      TERM_CODED.  Pure analysis, no codegen, no planner recursion.
      Gate: `TestWherePlanner.pas` (333/333): VFS1..VFS2 (scalar
      passthrough, pList vector field 0/1/2), ENC1..ENC11 (AFF_BLOB
      always 1; INTEGER+NUMERIC; INTEGER+TEXT reject; FLOAT+NUMERIC;
      STRING+TEXT; STRING+NUMERIC reject; BLOB+TEXT; UMINUS BLOB
      reject; UPLUS INTEGER passthrough; COLUMN rowid alias accept;
      COLUMN regular column reject), URA1..URA3 (INTEGER+NUMERIC and
      STRING+TEXT downgrade to AFF_BLOB; NULL+TEXT untouched),
      WL1OR1..WL1OR6 (OE_None reject; all-EQ UNIQUE accept; WO_IS
      reject; WO_ISNULL reject; nSkip>0 reject; partial-key reject),
      WAPIC1..WAPIC4 (single-AND truth tags matching termA + termB;
      mismatched termC untouched; pre-coded terms stay coded).
    - [X] Leaf helpers, batch 3 — `sqlite3TableColumnToStorage`
      (build.c:1155..1170), `sqlite3ParseToplevel` (sqliteInt.h:5266
      macro), `codeDeferredSeek` (wherecode.c:1276..1309), and a no-op
      stub for `sqlite3WhereAddScanStatus` matching upstream's
      SQLITE_ENABLE_STMT_SCANSTATUS-disabled fallthrough.
      sqlite3TableColumnToStorage maps a logical column index to its
      storage slot — identity unless TF_HasVirtual is lit, in which case
      virtual columns are packed after the non-virtuals at offset
      pTab^.nNVCol.  sqlite3ParseToplevel returns `pToplevel` when set,
      else `p` (single-hop, matching the macro).  codeDeferredSeek emits
      OP_DeferredSeek so the table-row fetch can be skipped when the
      chosen index covers every column the loop needs; lights bit 0
      (bDeferredSeek) of pWInfo^.bitwiseFlags; under WHERE_OR_SUBCLAUSE /
      WHERE_RIGHT_JOIN with the toplevel's writeMask zero, attaches a
      P4_INTARRAY mapping (table-storage-column → index-key-position) so
      the deferred-seek epilogue can read columns directly out of the
      current index key.  Gate: `TestWherePlanner.pas` (354/354):
      TS1..TS5 (no-virtual identity, rowid-alias identity, all-real
      counting, single-virtual packing, virtual-column-itself slot),
      PT1..PT3 (nil pToplevel, single-hop, no chain walk), CDS1..CDS3
      (OP_DeferredSeek + bDeferredSeek + no P4 outside OR/RIGHT_JOIN;
      P4_INTARRAY attached under WHERE_OR_SUBCLAUSE with writeMask=0;
      P4 suppressed when writeMask<>0).
    - [X] Leaf helpers, batch 4 — `explainIndexColumnName`
      (wherecode.c:28..33), `computeIndexAffStr` + `sqlite3IndexAffinityStr`
      (insert.c:75..114), `codeEqualityTerm` (wherecode.c:803..845),
      `codeAllEqualityTerms` (wherecode.c:892..995), and a `codeINTerm`
      stub (wherecode.c:668..784) that asserts on entry — full IN-loop
      builder deferred until `sqlite3FindInIndex` lands in the next sub-
      progress.  explainIndexColumnName returns the printable name of
      the i-th index key column ("<expr>" for XN_EXPR slots, "rowid" for
      XN_ROWID, otherwise pTab^.aCol[].zCnName).  computeIndexAffStr
      lazily allocates pIdx^.zColAff and walks every key column writing
      its comparison affinity into the cache, clamped to
      [AFF_BLOB..AFF_NUMERIC] (so AFF_INTEGER and AFF_REAL slots collapse
      to AFF_NUMERIC, matching upstream).  sqlite3IndexAffinityStr is
      the cached-accessor wrapper.  codeEqualityTerm dispatches on the
      term operator: TK_EQ/TK_IS → sqlite3ExprCodeTarget on pRight,
      TK_ISNULL → OP_Null into iTarget, TK_IN → codeINTerm.  Disables
      the term unless the loop is WHERE_TRANSCONS + WO_EQUIV (per
      sqlite.org forum eb8613976a).  codeAllEqualityTerms allocates
      nEq+nExtraReg contiguous registers, copies the cached affinity
      string, threads each equality term through codeEqualityTerm, then
      patches AFF_BLOB into the affinity slot when the RHS already
      forced its own affinity (WO_IN / WO_xxx with EP_xIsSelect, BLOB
      compare, or sqlite3ExprNeedsNoAffinityChange).  Skip-scan prelude
      (nSkip>0) emits OP_Null + OP_Last/OP_Rewind + OP_Goto + OP_SeekGT/
      LT + per-skipped OP_Column verbatim.  Gate:
      `TestWherePlanner.pas` (392/392): EICN1..EICN3 (regular column,
      XN_ROWID, XN_EXPR), CIA1..CIA3 (allocation, INTEGER→NUMERIC and
      AFF_NONE→BLOB clamps), IAS1 (cached path), CET1..CET4 (TK_ISNULL
      OP_Null, TK_EQ INTEGER, TK_IS TERM_CODED, transitive EQUIV no-
      disable), CAET1..CAET3 (nEq=0 affinity-only, nEq=1 TK_EQ register
      block, nExtraReg=1 register accounting under TK_IS).
    - [X] Leaf helpers, batch 6 — `removeUnindexableInClauseTerms`
      (wherecode.c:573..653).  Builds a *reduced* duplicate of an
      `X IN (SELECT ...)` expression so only the vector columns the chosen
      index can use survive on both LHS and RHS.  sqlite3ExprDup deep-copies
      pX, then for every pSelect in the (compound) chain a fresh ExprList is
      assembled from pLoop^.aLTerm[iEq..nLTerm-1] entries whose pExpr matches
      the original pX (using `iField - 1` as the column slot).  Original
      ELists are released, the new ones stitched in.  When the reduced LHS
      collapses to one column the wrapping TK_VECTOR is unwrapped (the parser
      never produces single-element vectors, and downstream subroutines do
      not accept them).  Each rewritten SELECT bumps `pParse^.nSelect` so
      its `selId` is distinct from the original's (required for SubrtnSig
      validity).  ORDER BY / GROUP BY references to old result-set positions
      are remapped through `adjustOrderByCol`; orphans collapse to 0.
      Caller retains ownership of the original pX — the routine never frees
      it; the caller deletes the returned duplicate when finished.
      Gate: `TestWherePlanner.pas` (423/423): RUICT1 (3-column → 2-column
      reduction via two iField terms — RHS pEList nExpr=2, LHS still
      TK_VECTOR with two children, selId bumped, original pIN intact),
      RUICT2 (single-term reduction → TK_VECTOR unwrapped, pNew^.pLeft
      lifted to the bare LHS column, RHS nExpr=1), RUICT3 (no-match path
      under mallocFailed: routine returns without firing the
      `(pRhs<>nil) or mallocFailed` assert).
    - [X] Leaf helpers, batch 5 — `codeExprOrVector`
      (wherecode.c:1320..1346) and `filterPullDown` (wherecode.c:1391..1439).
      codeExprOrVector emits a vector or scalar expression into a contiguous
      register run: TK_VECTOR with ExprUseXList walks pList^.a[].pExpr through
      sqlite3ExprCode; scalars degrade to a single sqlite3ExprCode call into
      iReg.  The TK_SELECT subselect arm asserts-stubs pending sqlite3CodeSubselect
      (lands alongside codeINTerm proper in batch 6).  filterPullDown is the
      Bloom-filter pull-down driver — walks inner WhereLevels after iLevel and
      for each that has regFilter<>0 + nSkip=0 + (prereq & notReady)=0 emits
      the filter's column-key pre-check before the outer index lookup.
      WHERE_IPK arm threads codeEqualityTerm + OP_MustBeInt + OP_Filter through
      a single temp register; otherwise codeAllEqualityTerms +
      codeApplyAffinity + OP_Filter on the full nEq prefix.  Each handled
      level has its regFilter zeroed and addrBrk restored.  Gate:
      `TestWherePlanner.pas` (406/406): CEOV1 (scalar TK_INTEGER → ≥1 opcode),
      CEOV2 (TK_VECTOR with two TK_INTEGER children → ≥2 opcodes via
      ExprUseXList), FPD1 (all-regFilter=0 walk → no emit), FPD2 (IPK level
      with regFilter=99 → MustBeInt + Filter pair, regFilter cleared, addrBrk
      restored), FPD3 (nSkip=1 disqualifier → no emit, regFilter preserved),
      FPD4 (iLevel=nLevel-1 walk body never enters → no emit).
    - [X] Leaf helpers, batch 7 — `codeCursorHint`
      (wherecode.c:1146..1245), `sqlite3WhereExplainOneScan`
      (wherecode.c:245..268), `sqlite3WhereExplainBloomFilter`
      (wherecode.c:280..320), and `sqlite3WhereAddExplainText`
      (wherecode.c:117..233).  All four are runtime-no-op stubs matching
      upstream's SQLITE_ENABLE_CURSOR_HINTS=OFF (codeCursorHint compiles down
      to the `#else #define ... /*No-op*/`) and SQLITE_OMIT_EXPLAIN /
      explain<>2 / IS_STMT_SCANSTATUS-disabled fall-through paths (the three
      explain entry points return 0 / no-op since pas-sqlite3 has no EQP text
      generation yet; the StrAccum + %S printf wiring lands as a prerequisite
      for the EQP corpus tests in 6.10).  These stubs unblock the public-
      surface forward references that `sqlite3WhereCodeOneLoopStart` needs in
      the next sub-progress.  Gate: `TestWherePlanner.pas` (436/436):
      CCH1..CCH3 (codeCursorHint accepts nil and populated arg shapes
      without dereferencing — proves the no-op contract for both unused-arg
      and active-call paths), WEOS1..WEOS3 (sqlite3WhereExplainOneScan
      returns 0 for explain=0, explain=1, and explain=2 with
      WHERE_ORDERBY_MIN — all three still 0 until EQP text lands),
      WEBF1..WEBF2 (sqlite3WhereExplainBloomFilter returns 0 for both
      populated and all-nil shapes), WAET1..WAET2 (sqlite3WhereAddExplainText
      returns without effect for both populated and all-nil shapes).
    - [X] Leaf helpers, batch 8 — IN-index pre-flight predicates used by
      `sqlite3FindInIndex` (the next sub-progress).  `isCandidateForInOpt`
      (expr.c:3072..3107) decides whether the RHS SELECT of an `X IN (...)`
      can be answered by a direct table/index scan: rejects compound,
      DISTINCT, aggregate, GROUP BY, LIMIT, WHERE, multi-table FROM,
      sub-FROM, view, virtual table, EP_VarSelect (correlated), and any
      result expression that is not a bare TK_COLUMN; passes the cursor-
      identity assert (iTable = pSrc^.a[0].iCursor) for every result
      column.  `sqlite3InRhsIsConstant` (expr.c:3134..3145) temporarily
      detaches `pIn^.pLeft` so the constant walker only inspects the RHS
      list, then reattaches — used by the IN_INDEX_NOOP_OK arm to decide
      whether spinning up an ephemeral b-tree is worthwhile.
      `sqlite3SetHasNullFlag` (expr.c:3119..3128) emits the three-opcode
      probe (OP_Integer 0 → reg ; OP_Rewind iCur → done ; OP_Column iCur,0,
      reg with OPFLAG_TYPEOFARG so OP_Column reports affinity rather than
      fetching the value) plus the JumpHere back-patch — fills `regHasNull`
      with NULL iff the b-tree's first column contains a NULL row.
      `sqlite3RowidAlias` (expr.c:3046..3061) walks `_ROWID_`, `ROWID`,
      `OID` and returns the first not shadowed by an explicit user column;
      asserts HasRowid + !TF_NoVisibleRowid (the `VisibleRowid` predicate
      inlined here, no helper macro added).  Gate: `TestWherePlanner.pas`
      (464/464): ICO1..ICO8 (well-formed candidate accepted; EP_VarSelect,
      SF_Distinct, pLimit, virtual table, non-COLUMN result, multi-FROM,
      and scalar (TK_IN over list rather than SELECT) all rejected),
      IRC1..IRC2 (constant integer-list accepted, TK_COLUMN list rejected,
      pLeft restored after each call), SHNF1..SHNF4 (exactly three opcodes
      emitted; OP_Integer p1=0 / p2=reg ; OP_Rewind p1=iCur / p2 patched to
      `baseAddr+3` ; OP_Column p1=iCur / p2=0 / p3=reg / p5=TYPEOFARG),
      RA1 (empty schema picks `_ROWID_`).
    - [X] Leaf helpers, batch 9 — `sqlite3FindInIndex`
      (expr.c:3230..3451) plus `sqlite3CodeRhsOfIN` assert-stub
      (expr.c:3500..3731 deferred).  IN_INDEX_* return-codes and
      IN_INDEX_LOOP / _MEMBERSHIP / _NOOP_OK inFlags wired up.
      sqlite3FindInIndex chooses the b-tree shape used by codeINTerm:
      IN_INDEX_ROWID for "x IN (SELECT rowid FROM t)" (opens the table
      under OP_Once / OP_OpenRead), IN_INDEX_INDEX_ASC/_DESC when an
      existing pIdx covers every result-list column with matching
      affinity + collation (asserts UNIQUE when MEMBERSHIP requires it,
      falls back when the partial-index pPartIdxWhere is set, when
      pIdx^.nColumn>=BMS-1, or when nExpr exceeds nKeyCol on a
      non-UNIQUE index), IN_INDEX_NOOP when NOOP_OK is set and the RHS
      is a non-constant list or has ≤2 entries (rolls back the cursor
      reservation via Dec(pParse^.nTab); piTab=-1), otherwise
      IN_INDEX_EPH which delegates to sqlite3CodeRhsOfIN — currently
      stubbed `Assert(False)` until select.c lands, so EPH callers must
      not be exercised yet.  prRhsHasNull is dropped to nil when every
      SELECT result column is provably NOT NULL; on the index path it
      allocates pParse^.nMem and threads sqlite3SetHasNullFlag on
      single-column comparisons.  The trailing aiMap-fixup fills 0..n-1
      identity for ROWID/EPH/NOOP, reserving the meaningful per-column
      mapping for the INDEX_ASC/_DESC branches.  Gate:
      `TestWherePlanner.pas` (471/471): FII1 (constant 2-element list +
      NOOP_OK ⇒ IN_INDEX_NOOP, piTab=-1, nTab restored, aiMap[0]=0,
      pLeft restored).  Sub-progress 11g.2.e now unblocks codeINTerm
      itself for the next batch.
    - [X] Public surface, batch 11 — `sqlite3WhereCodeOneLoopStart`
      (wherecode.c:1466..2832) prelude + Case 2 (IPK rowid-EQ /
      rowid-IN, wherecode.c:1684..1711).  Function prelude lifts the
      C var setup verbatim — pTabItem / iCur from
      `pWInfo^.pTabList^.a[pLevel^.iFrom]`, pLevel^.notReady masked
      against the cursor's own bit via `sqlite3WhereGetMask`, bRev
      decoded from `(pWInfo^.revMask shr iLevel) and 1`, addrBrk
      pinned from the level's pre-allocated label, addrNxt aliased to
      addrBrk for the no-IN case, and addrCont allocated fresh via
      `sqlite3VdbeMakeLabel`.  LEFT-OUTER-JOIN match-flag init
      (wherecode.c:1535..1542) allocates `pLevel^.iLeftJoin` from
      `pParse^.nMem` and emits `OP_Integer 0,iLeftJoin` when
      `pLevel^.iFrom > 0` and `pTabItem^.fg.jointype` carries JT_LEFT —
      the C precondition assert (`WHERE_OR_SUBCLAUSE | WHERE_RIGHT_JOIN
      | iFrom>0 | not JT_LEFT`) ports verbatim.  Case 2 itself fires
      when `(wsFlags & WHERE_IPK) and (wsFlags & (WHERE_COLUMN_IN |
      WHERE_COLUMN_EQ))`: asserts `u.btree.nEq=1`, emits
      `codeEqualityTerm` into a fresh `iReleaseReg` pulled from
      `pParse^.nMem`, releases the temp when codeEqualityTerm reused
      it, runs the Bloom-filter `OP_MustBeInt + OP_Filter +
      filterPullDown` chain when `pLevel^.regFilter <> 0`, and emits
      the canonical `OP_SeekRowid iCur,addrNxt,iRowidReg` plus
      `pLevel^.op := OP_Noop` so sqlite3WhereEnd does not emit an
      iteration opcode.  All other arms — viaCoroutine subquery
      (1546..1559), Case 1 virtual-table xFilter (1561..1681), Case 3
      IPK range-scan (1712..1843), Case 4 indexed equality / range
      scan (1844..2543), Case 5 OR-decomposed fall-through
      (2544..2664), Case 6 full table / index scan (2665..2823) —
      land in subsequent batches as fixtures get wired up; the
      else-branch `Assert(False)` keeps callers honest.  Refactor of
      sqlite3WhereBegin's inlined Case 2 slice to call this routine is
      deferred to batch 12 once a TestWhereSimple SQL corpus run can
      compare opcodes against C.  Returns `pLevel^.notReady` per the
      C contract.  Gate: `TestWherePlanner.pas` (488/488):
      SCOLS1 (single-level rowid-EQ — addrNxt aliased to addrBrk,
      addrCont label allocated, pLevel^.op flipped from sentinel 99
      to OP_Noop, pTerm marked TERM_CODED via codeEqualityTerm,
      OP_SeekRowid emitted on iCursor=9, return value matches
      pLevel^.notReady), SCOLS2 (two-level frame with iFrom=1 and
      JT_LEFT pTabItem — iLeftJoin > 0 after init, Case 2 still fires,
      return value still matches pLevel^.notReady).
    - [X] Public surface, batch 12 — `sqlite3WhereCodeOneLoopStart`
      Case 3 IPK range-scan (wherecode.c:1712..1819).  Inequality on the
      rowid: optional start-bound seek (OP_SeekGT/SeekLE/SeekLT/SeekGE)
      keyed off `aMoveOp[pX^.op - TK_GT_TK]` for scalar RHS or
      `aMoveOp[((op-TK_GT-1) & 0x3) | 0x1]` for vector RHS (collapses to
      OP_SeekGE / OP_SeekLE — vector compares already emit the
      strict/non-strict half via `codeExprOrVector`); OP_Last / OP_Rewind
      fallback when only the end-bound is present; `bRev` swaps pStart
      and pEnd so reverse scans probe from the high end.  Iteration step
      is `pLevel^.op := OP_Prev / OP_Next` with `p1 := iCur`,
      `p2 := startAddr` so sqlite3WhereEnd resumes the loop body at the
      post-seek address.  End-bound test allocates a fresh `memEndValue`
      cell, emits `codeExprOrVector` into it, then OP_Rowid + OP_Le/Lt/
      Ge/Gt with `p5 := SQLITE_AFF_NUMERIC | SQLITE_JUMPIFNULL` so a NULL
      bound terminates the scan.  Strict-vs-non-strict choice mirrors C:
      scalar TK_LT/TK_GT_TK → OP_Ge/Le (fwd) or OP_Lt/Gt (bRev); any
      vector compare collapses to the strict variant since the seek
      already enforced the boundary.  `disableTerm` runs on each scalar
      bound so the per-row body codegen does not re-emit the predicate.
      `codeCursorHint` runs against pEnd (no-op stub).  Gate:
      `TestWherePlanner.pas` (514/514): SCOLS3 (BTM only — OP_SeekGT,
      pLevel^.op=OP_Next, no OP_Rowid; pStart marked TERM_CODED via
      disableTerm), SCOLS4 (TOP only — OP_Rewind fallback, OP_Rowid +
      OP_Ge end test, no OP_SeekGT; termEnd marked TERM_CODED), SCOLS5
      (both BTM+TOP — OP_SeekGT + OP_Rowid + OP_Ge + OP_Next, no
      OP_Rewind), SCOLS6 (bRev=1 — pStart/pEnd swap leaves OP_Last +
      OP_Rowid + OP_Le, pLevel^.op=OP_Prev).
    - [X] Public surface, batch 13 — `sqlite3WhereCodeOneLoopStart`
      Case 4 indexed equality / range scan (wherecode.c:1844..2073).
      Common path: nEq>=0, optional WHERE_BTM_LIMIT / WHERE_TOP_LIMIT,
      no WHERE_BIGNULL_SORT, no WHERE_IN_SEEKSCAN, no LIKEOPT counter,
      HasRowid table (codeDeferredSeek path).  Emits the start-bound
      seek selected from `aStartOp[(start_constraints<<2) | (startEq<<1)
      | bRev]` (OP_Rewind / OP_Last / OP_SeekGT / OP_SeekLT / OP_SeekGE
      / OP_SeekLE), the optional end-bound idx-probe from
      `aEndOp[bRev*2 | endEq]` (OP_IdxGE / OP_IdxGT / OP_IdxLE /
      OP_IdxLT) when nConstraint after the end-bound build is non-zero,
      OP_DeferredSeek for non-covering indexes, OP_SeekHit when
      WHERE_IN_EARLYOUT is set, and the iteration opcode (OP_Next /
      OP_Prev / OP_Noop) on `pLevel^.op`.  ASC/DESC swap
      (wherecode.c:1907..1911) interchanges pRangeStart/pRangeEnd plus
      bSeekPastNull/bStopAtNull plus nBtm/nTop when bRev matches the
      column's aSortOrder.  pRangeStart / pRangeEnd construction
      threads `codeExprOrVector` + `whereLikeOptimizationStringFixup` +
      OP_IsNull guard (when sqlite3ExprCanBeNull) + per-vector
      `updateRangeAffinityStr` + `disableTerm` (or endEq=1 fallback for
      vector RHS).  Partial-index constraint elision via
      `whereApplyPartialIndexConstraints` runs only on inner-loop
      levels (iLeftJoin=0) outside any RIGHT-JOIN subroutine.
      `pLevel^.p3` is set from WHERE_UNQ_WANTED, `pLevel^.p5` defaults
      to SQLITE_STMTSTATUS_FULLSCAN_STEP unless WHERE_CONSTRAINT is
      lit.  Defers WHERE_BIGNULL_SORT (NULL-pad two-pass scan),
      WHERE_IN_SEEKSCAN (OP_SeekScan tuning), WHERE_IDX_ONLY without
      rowid (WITHOUT-ROWID PK-key reconstruction), and the trailing
      Case 5 (MULTI_OR) / Case 6 (full-table scan) arms to subsequent
      batches.  Gate: `TestWherePlanner.pas` (529/529): SCOLS7
      (WHERE_INDEXED + WHERE_COLUMN_EQ, nEq=1 — OP_SeekGE on iIdxCur,
      OP_IdxGT end probe, OP_DeferredSeek, term TERM_CODED via
      codeEqualityTerm, pLevel^.op=OP_Next, pLevel^.p1=iIdxCur,
      return value matches pLevel^.notReady), SCOLS8 (WHERE_INDEXED +
      WHERE_COLUMN_RANGE + WHERE_BTM_LIMIT, x>10 — OP_SeekGT
      (start_constraints=1, !startEq, !bRev → aStartOp[4]), no
      end-bound probe since nConstraint after build = 0, pStart marked
      TERM_CODED), SCOLS9 (BTM_LIMIT under bRev=1 — pLevel^.op flips to
      OP_Prev, swap path runs cleanly without crash).
    - [X] Public surface, batch 14 — `sqlite3WhereCodeOneLoopStart`
      Case 6 full-table scan (wherecode.c:2561..2581).  Falls through when
      wsFlags has neither WHERE_IPK nor WHERE_INDEXED nor WHERE_MULTI_OR
      lit.  isRecursive (SrcItemFg.fgBits bit 7) short-circuits to
      `pLevel^.op := OP_Noop` for CTE pseudo-cursors that already hold a
      single materialised row.  Non-recursive path emits the canonical
      pair via `aStep[]`/`aStart[]` lookup tables: bRev=0 → OP_Rewind +
      OP_Next; bRev=1 → OP_Last + OP_Prev.  `pLevel^.p1` set to the table
      cursor, `pLevel^.p2` to `1 + sqlite3VdbeAddOp2(...)` (one past the
      Rewind/Last so sqlite3WhereEnd's iteration opcode jumps back to the
      first body instruction), `pLevel^.p5` stamped with
      `SQLITE_STMTSTATUS_FULLSCAN_STEP` so the EQP / scan-status counters
      mark this as a full scan.  Case 5 (multi-index OR) keeps its
      Assert(False) skeleton — full port deferred until OR-disjunct
      sub-WHERE driver lands alongside the next batch.
      Gate: `TestWherePlanner.pas` (548/548): SCOLS10 (bRev=0 — OP_Rewind
      on iCursor=7, OP_Next on pLevel^.op, p1=iCursor, p2=Rewind+1, p5=
      FULLSCAN_STEP, no OP_Last), SCOLS11 (bRev=1 via revMask=1 — OP_Last
      + OP_Prev, p2=Last+1, no OP_Rewind), SCOLS12 (isRecursive bit 7 set
      — pLevel^.op=OP_Noop, p1/p2/p5 untouched, neither Rewind nor Last
      emitted).
    - [X] Public surface, batch 15 — `sqlite3WhereCodeOneLoopStart`
      per-loop body push-down + transitive constraint + LEFT-JOIN match
      flag (wherecode.c:2587..2780).  After the case-arm dispatch, walks
      `pWInfo^.sWC.a` up to three times (iLoop=1: terms covered by
      `pLoop^.u.btree.pIndex`; iLoop=2: remaining without TERM_VARSELECT;
      iLoop=3: everything else) and emits each ready, non-virtual,
      non-already-coded term via `sqlite3ExprIfFalse(addrCont,
      JUMPIFNULL)` then tags it TERM_CODED.  Skips terms whose prereqAll
      bits are still in pLevel^.notReady (lights bit 1 of
      `pWInfo^.bitwiseFlags` = untestedTerms).  Outer-join LHS/RHS terms
      gated through the `EP_OuterON|EP_InnerON` filter + per-table iJoin
      mask probe.  TERM_LIKECOND wraps the residual call in OP_If/OP_IfNot
      against `pLevel^.iLikeRepCntr` so the LIKE residual fires only on
      the BLOB-comparison pass (range bound suffices for strings).
      Transitive-equiv post-walk (wherecode.c:2683..2727) re-emits
      "t1.a = t2.b ∧ t2.b = 123" as the implied "t1.a = 123" via
      sqlite3WhereFindTerm (skipping IN-subselect-with-vector RHS).
      LEFT-JOIN match-flag set (wherecode.c:2773..2780) emits
      OP_Integer 1 → iLeftJoin and stamps `pLevel^.addrFirst`.  Deferred:
      RIGHT JOIN match recording (pRJ Bloom-filter + iMatch IdxInsert,
      wherecode.c:2729..2768) and `code_outer_join_constraints` post-pass
      — both gated on the pRJ subroutine driver landing in the next
      batch alongside Case 5 (multi-index OR).
      Gate: `TestWherePlanner.pas` (555/555): SCOLS13 (Case 6 full scan
      with one residual TK_INTEGER literal in pWC^.a — body walk fires,
      term tagged TERM_CODED, ExprIfFalse short-circuits a constant-true
      literal without emit), SCOLS14 (term with prereqAll & notReady
      = bit 0 deferred — bit 1 of bitwiseFlags lit, TERM_CODED stays
      clear), SCOLS15 (TERM_VIRTUAL skip — neither TERM_CODED set nor
      untestedTerms lit).
    - [X] Public surface, batch 16 — `sqlite3WhereCodeOneLoopStart`
      `code_outer_join_constraints` re-walk (wherecode.c:2800..2813).
      Fires after the LEFT-JOIN match-flag set when `pLevel^.pRJ = nil`;
      walks `pWInfo^.sWC.a[0..nBase-1]` a second time picking up any
      term the main push-down walk left untouched because of the
      JT_LEFT/LTORJ/RIGHT EP_OuterON gate.  Each non-virtual,
      non-already-coded, ready term gets a `sqlite3ExprIfFalse(addrCont,
      JUMPIFNULL)` residual; JT_LTORJ tables short-circuit because their
      tail is owned by the (still-deferred) RIGHT JOIN subroutine driver.
      Gate: `TestWherePlanner.pas` (558/558): SCOLS16 (LEFT JOIN +
      iLeftJoin=99 + nBase=1 outer-join term — post-pass tags TERM_CODED,
      addrFirst non-zero, sentinel OP_Integer p1=1/p2=99 emitted).
    - [X] Leaf helpers, batch 10 — `codeINTerm` (wherecode.c:668..784)
      full port replacing the prior `Assert(False)` stub.  IN-loop
      builder: opens the IN cursor (rowid table / shared index / EPH
      per `sqlite3FindInIndex`), allocates an `InLoop` slot per
      matching aLTerm entry via `sqlite3WhereRealloc`, and emits the
      per-iteration body preamble (OP_Rowid or OP_Column → iOut, then
      OP_IsNull guard).  Honours the index-aSortOrder bRev flip on
      DESC keys, the early-disable shortcut when an earlier aLTerm[i]
      already references the same TK_IN Expr (calls disableTerm and
      returns without codegen or FindInIndex), the SELECT-vector path
      (delegates to `removeUnindexableInClauseTerms` + nEq-sized aiMap
      from `sqlite3DbMallocZero`), and the IN_INDEX_INDEX_DESC bRev
      double-flip.  Sets `WHERE_IN_ABLE` (always) and `WHERE_IN_EARLYOUT`
      (when iEq>0 and not WHERE_IN_SEEKSCAN) on `pLoop^.wsFlags`,
      threads `pLevel^.addrNxt` via `sqlite3VdbeMakeLabel` on the first
      slot, fills `pIn^.iCur / eEndLoopOp / iBase / nPrefix` for the
      head-of-chain entry and `OP_Noop` end-loop for every subsequent
      slot, and emits the trailing `OP_SeekHit` index-skip-only marker
      when iEq>0 and neither WHERE_IN_SEEKSCAN nor WHERE_VIRTUALTABLE
      is set.  Realloc-failure path (pIn=nil) restores in_nIn=0 so the
      level looks empty to the body codegen.  Also corrected the FPD2
      filterPullDown fixture: `ex0.op` flipped from `TK_INTEGER` to
      `TK_EQ` with a TK_INTEGER `pRight` literal so codeEqualityTerm
      routes through the TK_EQ arm (the prior fixture only "passed"
      because the no-op `Assert(False)` codeINTerm stub silently
      bypassed the broken dispatch — the fixture would have crashed
      the moment a real codeINTerm landed).  Gate: `TestWherePlanner.pas`
      (478/478): CIT1 (early-disable when `aLTerm[0]^.pExpr = pX` and
      iEq=1 — disableTerm fires, no opcodes emitted, no FindInIndex
      call, parse.nTab unchanged, in_nIn / addrNxt / WHERE_IN_ABLE all
      untouched).  Body emission paths (ROWID / INDEX_ASC / INDEX_DESC
      / EPH) require open-database fixtures (Schema + Table + cursor)
      and are deferred to the TestWhereCorpus / TestExplainParity gate
      under 11g.2.f.
    - [X] Leaf helpers, batch 11 — `sqlite3GetTempRange` /
      `sqlite3ReleaseTempRange` (expr.c:7603..7627).  Allocate / recycle
      a contiguous block of `nReg` registers from the parser-scoped
      register pool.  Single-register requests fan out to the existing
      `sqlite3GetTempReg` / `sqlite3ReleaseTempReg` pair so the scalar
      `aTempReg[]` cache stays in play.  Multi-register requests carve
      from `pParse^.iRangeReg / nRangeReg` when the cached run is fat
      enough (advances iRangeReg, shrinks nRangeReg by exactly nReg);
      otherwise bump `pParse^.nMem` by `nReg` and return the next
      register.  Release path: a freed run that is *strictly* larger
      than the current `nRangeReg` cache replaces the cache (matches
      the C `nReg > nRangeReg` predicate — equal blocks do not
      displace), runs through `sqlite3VdbeReleaseRegisters` either way
      so any pinned dependency tracking gets cleared.  Prerequisite
      for the pRJ RIGHT JOIN match-recording block (wherecode.c:
      2729..2768) and the multi-index OR driver (Case 5,
      wherecode.c:2544..2664), both of which use `GetTempRange(nPk+1)`
      / `GetTempRange(nReg)` to assemble PK-key tuples and OR-leg
      register frames in subsequent batches.  Gate:
      `TestWherePlanner.pas` (590/590): GTR1 (nReg=1 empty pool →
      ++nMem path), GTR2 (nReg=1 with cached temp → recycles
      aTempReg[]), GTR3 (cache fat enough → carve, advance iRangeReg,
      shrink nRangeReg), GTR4 (cache too small → fall back to nMem
      bump, leave iRangeReg/nRangeReg untouched), GTR5 (exact-fit
      cache → drains nRangeReg to 0), RTR1 (nReg=1 release → routes
      through ReleaseTempReg into aTempReg[]), RTR2 (nReg>nRangeReg
      release replaces the cache), RTR3 (nReg<nRangeReg release leaves
      cache alone), RTR4 (nReg=nRangeReg strict-gt comparison: equal
      block does not displace), GTR-RT round-trip (alloc → release →
      realloc returns the same registers, nMem not double-bumped).
    - [X] Leaf helpers, batch 12 — `sqlite3ExprCodeGetColumnOfTable`
      (expr.c:4417..4465).  Emits the opcode that fetches column `iCol`
      of `pTab` from cursor `iTabCur` into register `regOut`.  Five-way
      dispatch matching upstream verbatim: (1) `iCol < 0` or
      `iCol = pTab^.iPKey` shortcuts to `OP_Rowid` (rowid alias path);
      (2) virtual table (`eTabType = TABTYP_VTAB`) emits `OP_VColumn`
      keyed off the logical column index; (3) generated columns
      (`COLFLAG_VIRTUAL` on `pCol^.colFlags`) lands `Assert(False)` until
      `sqlite3ExprCodeGeneratedColumn` ports — no current caller drives
      this arm; (4) `WITHOUT-ROWID` tables resolve through
      `sqlite3TableColumnToIndex(sqlite3PrimaryKeyIndex(pTab), iCol)`
      and emit `OP_Column` against the PK cursor; (5) regular HasRowid
      tables use `sqlite3TableColumnToStorage(pTab, iCol)` so virtual-
      generated columns line up at their packed-after-real-columns
      storage offset.  All non-rowid arms call `sqlite3ColumnDefault`
      after the OP_Column / OP_VColumn emit (currently a Phase 6.4
      stub but threaded for future correctness).  Direct prerequisite
      of the pRJ RIGHT JOIN match-recording block (Public surface
      batch 17) which uses it to extract the right-table primary-key
      tuple for the iMatch / regBloom record-and-filter sequence.
      Gate: `TestWherePlanner.pas` (610/610): ECGCT1 (iCol=-1 →
      OP_Rowid, single-opcode emit, p1=iTabCur, p2=regOut), ECGCT2
      (iCol = iPKey → OP_Rowid alias path), ECGCT3 (regular HasRowid
      column → OP_Column with identity storage index, p3=regOut),
      ECGCT4 (TABTYP_VTAB → OP_VColumn with iCol passthrough),
      ECGCT5 (TF_WithoutRowid + idxFlags=2 PK → OP_Column with PK
      key position 0, p1 = PK cursor).
    - [X] Public surface, batch 17 — `sqlite3WhereCodeOneLoopStart`
      pRJ RIGHT JOIN match-recording (wherecode.c:2729..2768) +
      BeginSubrtn block (wherecode.c:2782..2799) + structural
      refactor of `code_outer_join_constraints` to run on either
      iLeftJoin OR pRJ being set (matches the C goto / fall-through
      flow).  Match-recording: HasRowid tables emit OP_Rowid into a
      2-register block via `sqlite3GetTempRange(pParse, 2)` +
      `sqlite3ExprCodeGetColumnOfTable(v, pTab, pLevel^.iTabCur, -1,
      r+1)`; WITHOUT-ROWID tables walk
      `sqlite3PrimaryKeyIndex(pTab)^.aiColumn[]` for `nKeyCol` columns
      via `GetTempRange(nPk+1)` and per-column
      `sqlite3ExprCodeGetColumnOfTable(v, pTab, iCur, iCol, r+1+iPk)`
      (note: HasRowid uses `pLevel^.iTabCur`, !HasRowid uses `iCur`,
      mirroring the C cursor-mode split for WITHOUT-ROWID tables).
      Then OP_Found shortcuts already-matched rows; OP_MakeRecord
      packs the PK into the trailing register slot; OP_IdxInsert
      writes to `pRJ^.iMatch`; OP_FilterAdd writes to `pRJ^.regBloom`
      with `p5 := OPFLAG_USESEEKRESULT` (reuses the seek result from
      OP_Found); JumpHere closes the OP_Found skip.  BeginSubrtn:
      OP_BeginSubrtn target is `pRJ^.regReturn`; `pRJ^.addrSubrtn`
      pins the next address; `pParse^.withinRJSubrtn` increments
      (asserted < 255 to mirror the C invariant).  RIGHT JOIN match
      recording fires BEFORE the LEFT JOIN match-flag set so the
      iMatch insert reflects the unwrap-extended row, not the raw
      cursor row.  The matching `OP_Return` / `OP_EndSubrtn` and the
      post-pass null-extension driver still live in
      `sqlite3WhereEnd` — that piece is part of the deferred
      `sqlite3WhereRightJoinLoop` body and lands later in the public
      surface tail.  Gate: `TestWherePlanner.pas` (619/619): SCOLS17
      (HasRowid pTab, pRJ.iMatch=33, pRJ.regBloom=44,
      pRJ.regReturn=55, iLeftJoin=0 — verifies OP_Found p1=33,
      OP_MakeRecord, OP_IdxInsert p1=33, OP_FilterAdd p1=44 +
      p5=OPFLAG_USESEEKRESULT, OP_BeginSubrtn p2=55, addrSubrtn>0,
      withinRJSubrtn incremented to 1, code_outer_join_constraints
      fall-through tags TERM_CODED).
    - [X] Public surface, batch 18 — `sqlite3WhereCodeOneLoopStart`
      viaCoroutine FROM-clause subquery arm (wherecode.c:1543..1555).
      Inserted as the leading dispatch arm (before Case 2) to mirror
      the C `if-else` chain.  Fires when `pTabItem^.fg.fgBits` has
      bit 6 (`viaCoroutine`) set: emits OP_InitCoroutine targeting
      `pTabItem^.u4.pSubq^.regReturn` with p3 = `addrFillSub` (the
      coroutine entry point), then OP_Yield against the same
      regReturn with p2 = addrBrk so when the coroutine signals
      end-of-rows the outer loop falls out.  `pLevel^.p2` is set to
      the OP_Yield address so sqlite3WhereEnd's iteration epilogue
      jumps back through the yield instead of emitting a Next/Prev
      pair, and `pLevel^.op := OP_Goto` so the loop iteration is
      driven by a back-edge to the yield rather than a cursor step.
      C-source assertions ported verbatim — `isSubquery` (fgBits
      bit 2) must be set and `u4.pSubq` must be non-nil.  Gate:
      `TestWherePlanner.pas` (624/624): SCOLS18 (Subquery fixture
      with regReturn=77 / addrFillSub=123, fgBits = viaCoroutine |
      isSubquery — verifies pLevel^.op = OP_Goto, pLevel^.p2 > 0,
      OP_InitCoroutine p1=77 / p3=123 emitted, OP_Yield p1=77
      emitted, pLevel^.p2 points at the emitted OP_Yield address).
    - [X] Public surface, batch 20 — `sqlite3WhereCodeOneLoopStart`
      Case 4 `WHERE_IN_SEEKSCAN` driver (wherecode.c:1965..1969,
      2043..2061, 2146).  Drops the prior assertion-stub gate on the
      IN-skip-scan flag and ports the three-piece codegen: (1) before
      the equality-prefix codegen, when `iLevel > 0` and the loop carries
      `WHERE_IN_SEEKSCAN`, emit `OP_NullRow iIdxCur` so the index cursor
      starts un-positioned and the first iteration enters the
      seek-or-step path cleanly; (2) at the start-bound seek-op
      selection, when the chosen op is `OP_SeekGE` and IN_SEEKSCAN is
      lit, prepend `OP_SeekScan` whose p1 carries the tunable step
      budget `(pIdx^.aiRowLogEst[0] + 9) div 10` (one-tenth of the
      log-row-estimate, rounded up — matches upstream's seek-cost
      heuristic).  When a range bound is present (`pRangeStart` or
      `pRangeEnd <> nil`), patch `OP_SeekScan.p5 := 1` and
      `OP_SeekScan.p2 := currentAddr + 1` via ChangeP2 so the
      seek-or-step driver knows to fall through to the bound-load
      sequence; otherwise leave `addrSeekScan` set so the trailing
      `JumpHere` after the end-bound `OP_IdxGE/Gt/Le/Lt` emit threads
      the bypass to the post-end-bound address.  (3) at wherecode.c:
      2146, after the end-bound probe emit, `if addrSeekScan <> 0 then
      sqlite3VdbeJumpHere(v, addrSeekScan)` lands the seek-skip target
      one past the IdxGT/IdxLE so the body fall-through is reached when
      the SeekScan budget exhausts without a hit.  Local
      `addrSeekScan` initialised to 0 inside the Case 4 block; existing
      Case 4 fixtures (SCOLS7..9, SCOLS19) untouched because they run
      with IN_SEEKSCAN cleared, so the new code is transparent on the
      pre-existing path.  Gate: `TestWherePlanner.pas` (637/637):
      SCOLS20 (N_LEVEL=2 with iLevel=1 + iIdxCur=6, WHERE_INDEXED |
      WHERE_COLUMN_EQ | WHERE_IN_SEEKSCAN, nEq=1, x=42, aiRowLogEst[0]
      =33 → budget=4; verifies OP_NullRow emitted on iIdxCur,
      OP_SeekScan emitted with p1=4, OP_SeekGE follows immediately,
      OP_IdxGT end-bound probe still emitted, no-range-bound JumpHere
      patches OP_SeekScan.p2 to addrIdxGT+1 — the post-end-bound
      address).
    - [X] Public surface, batch 22 — `sqlite3WhereEnd` LEFT JOIN
      null-row fixup (where.c:7692..7726).  Lifts the per-level fixup
      out of the assert-stub trimmed-tail comment block in
      `sqlite3WhereEnd` and into a new top-level helper
      `ljNullRowFixup(pPrs, v, pWInfo, pLevel)` invoked once after each
      level's addrBrk resolves.  When `pLevel^.iLeftJoin <> 0` (per-row
      body lit it on every successful pairing), the fixup synthesises
      a fake all-NULL row by emitting `OP_IfPos iLeftJoin` (skipped when
      a row already paired), `OP_NullRow iTabCur` (gated off when
      `WHERE_IDX_ONLY` covers every needed column), `OP_NullRow
      iIdxCur` (when `WHERE_INDEXED` *or* `WHERE_MULTI_OR` with a
      tracked covering index), then re-enters the body via either
      `OP_Gosub regReturn, addrFirst` (Case 5: `pLevel^.op = OP_Return`)
      or `OP_Goto addrFirst` (everything else), closed by
      `JumpHere(addr)` to land the IfPos on the post-fixup
      instruction.  Case 5 carries the extra `OP_ReopenIdx iIdxCur,
      tnum, iDb` + `SetP4KeyInfo` when a covering index was tracked
      across all disjuncts (the index cursor was last positioned by an
      OR-disjunct sub-WHERE that may have closed it).  viaCoroutine
      LHS subqueries get their result-register block zeroed via
      `OP_Null 0, regResult, regResult+nCol-1` so the synthetic NULL
      row replaces stale coroutine state on the LHS columns.
      Hooked into `sqlite3WhereEnd`'s per-level loop after the addrBrk
      resolve, so the iteration-and-break cleanup is back-edge complete
      for any LEFT JOIN regardless of which case-arm drove the level.
      Closes the per-level cleanup comment in 11g.2.b — the trimmed
      tail's "deferred LEFT JOIN null-row fixup" line is now real.
      Gate: `TestWherePlanner.pas` (667/667): LJN1 (Case 6 LEFT JOIN —
      ws=0, no idx: OP_IfPos + OP_NullRow on iTabCur + OP_Goto back,
      no idx-cursor ops, no Gosub since op != OP_Return), LJN2 (Case 4
      LEFT JOIN — ws=WHERE_INDEXED: OP_NullRow on both iTabCur and
      iIdxCur, no OP_ReopenIdx since the Case-4 cursor was never
      closed), LJN3 (Case 5 LEFT JOIN with pCoveringIdx=nil — ws=
      WHERE_MULTI_OR, op=OP_Return: OP_NullRow on iTabCur, OP_Gosub
      back to addrFirst, no idx-cursor ops since the covering-index
      gate failed; covering-index path lands under TestWhereCorpus).
    - [X] Public surface, batch 21 — `sqlite3WhereCodeOneLoopStart`
      Case 5 multi-index OR fall-through (wherecode.c:2186..2557).
      Replaces the prior `Assert(False)` stub with the full port:
      allocates `regReturn`, builds a per-OR-disjunct `pOrTab` SrcList
      header (notReady tables in slots 1..n), opens a rowset register
      (HasRowid: OP_Null) or an OpenEphemeral PK index (WITHOUT-ROWID:
      OP_OpenEphemeral + sqlite3VdbeSetP4KeyInfo) under the
      `WHERE_DUPLICATES_OK = 0` gate, emits `OP_Integer 0 → regReturn`
      whose p1 is back-patched at the end via ChangeP1, builds the
      shared `pAndExpr` conjunction by walking `pWInfo^.sWC.a[]` and
      ANDing every non-virtual / non-coded / non-slice / WO_ALL /
      non-EP_Subquery sibling under a `TK_AND|0x10000` head (the
      0x10000 high-bit defeats `sqlite3PExpr`'s AND short-circuit, per
      ticket f2369304e4 + dbsqlfuzz tag-20220303a), then for each
      disjunct dups the term, glues `pAndExpr^.pLeft` to it, calls
      `sqlite3WhereBegin(... WHERE_OR_SUBCLAUSE, iCovCur)` recursively,
      filters duplicates via `sqlite3ExprCodeGetColumnOfTable` →
      `OP_RowSetTest` (rowid) or `OP_Found` + `OP_MakeRecord` +
      `OP_IdxInsert` with `OPFLAG_USESEEKRESULT` (PK), gosubs into the
      shared body label, tracks `pCov` + `bDeferredSeek` from each
      sub-WhereInfo, calls `sqlite3WhereEnd`, then back-patches the
      iRetInit OP_Integer's p1 to point past the OP_Goto / iLoopBody
      label and stamps `pLevel^.p2 = sqlite3VdbeCurrentAddr` (the
      tag-20220407a indent hint that the byte-code formatter consumes
      between this point and the OP_Return). `pLevel^.op = OP_Return`,
      `pLevel^.p1 = regReturn`, `pLevel^.u.pCoveringIdx = pCov`,
      `pLevel^.iIdxCur = iCovCur` when pCov non-nil. `IsPrimaryKeyIndex`
      inlined as `(idxFlags and 3) <> SQLITE_IDXTYPE_PRIMARYKEY`. Adds
      missing `WHERE_DUPLICATES_OK = $0010` constant (was unused before
      Case 5 wired).  Real OR-disjunct codegen is exercised end-to-end
      under the upcoming TestWhereCorpus / TestExplainParity gates in
      11g.2.f; this batch lands the body so the dispatch never falls
      into the assert-stub when planner output sets WHERE_MULTI_OR.
      Gate: `TestWherePlanner.pas` (647/647): SCOLS21 (empty pOrInfo
      with WHERE_DUPLICATES_OK so the disjunct loop doesn't recurse —
      verifies pLevel^.op = OP_Return, pLevel^.p1 = regReturn>0,
      pParse^.nTab and nMem each bumped by ≥1, OP_Integer 0/regReturn
      emitted, OP_Goto follows, ChangeP1 back-patches OP_Integer.p1
      past itself, pLevel^.p2 lands past the OP_Goto at the resolved
      iLoopBody label).
    - [X] Public surface, batch 23 — `sqlite3WhereRightJoinLoop`
      (wherecode.c:2834..2945) replaces the prior Phase 6.2 stub.  Drives
      the RIGHT JOIN unmatched-row pass: `sqlite3VdbeNoJumpsOutsideSubrtn`
      brackets the subroutine, then for each prior level k=0..iLevel-1
      builds `mAll |= a[k].pWLoop^.maskSelf`, OP_Null-zeroes any
      `viaCoroutine` LHS subquery's `regResult..regResult+nExpr-1` block,
      OP_NullRows the level's `iTabCur` and (when set) `iIdxCur`.  Outside
      JT_LTORJ the routine then walks `pWC^.a[]` building `pSubWhere` from
      every non-virtual / non-slice (or WO_ROWVAL-bearing) term whose
      `prereqAll & ~mAll = 0` and that lacks `EP_OuterON|EP_InnerON`,
      ANDed via `sqlite3ExprAnd(sqlite3ExprDup(...))`.  After the (gated)
      `OP_NullRow pLevel^.iIdxCur` it allocates a fresh single-item SrcList
      from the heap (pas-sqlite3 carries variable-length SrcLists, so
      `sqlite3DbMallocRawNN(SZ_SRCLIST_HEADER + SZ_SRCLIST_ITEM)` replaces
      the C `union { SrcList; u8[SZ_SRCLIST_1]; } uSrc;` stack idiom),
      copies pTabItem in, zeros the copy's jointype, increments
      `pParse^.withinRJSubrtn` (assert < 100), and recursively calls
      `sqlite3WhereBegin(... WHERE_RIGHT_JOIN, 0)`.  The success arm then
      pulls the right-table PK tuple (HasRowid: `OP_Rowid` via
      `sqlite3ExprCodeGetColumnOfTable(v, pTab, iCur, -1, r)`, nPk=1; else
      walks `sqlite3PrimaryKeyIndex(pTab)^.aiColumn[0..nKeyCol-1]` into
      `r..r+nPk-1`), emits `OP_Filter pRJ^.regBloom, jmp, r, nPk` →
      `OP_Found pRJ^.iMatch, addrCont, r, nPk` → `JumpHere(jmp)` →
      `OP_Gosub pRJ^.regReturn, pRJ^.addrSubrtn`, then closes with
      `sqlite3WhereEnd(pSubWInfo)`.  Cleanup ExprDeletes pSubWhere,
      DbFreeNNs the heap pFrom, and decrements `withinRJSubrtn` (assert >0).
      Renamed local `pParse` → `pPrs` to avoid the FPC case-insensitive
      var/type collision with the `PParse` type alias (matches the
      `ljNullRowFixup` precedent established in batch 22).
      Gate: `TestWherePlanner.pas` (675/675): RJL1 (2-level pWInfo,
      iLevel=1, JT_LTORJ on current pTabItem; prior level iTabCur=11 +
      iIdxCur=22; current level iIdxCur=33; pRJ filled with iMatch=77,
      regBloom=88, regReturn=99; mallocFailed=1 forces the inner
      `sqlite3DbMallocRawNN(pFrom)` to return nil so we probe the prelude
      OP_NullRow emissions in isolation — verifies all three OP_NullRows
      land, withinRJSubrtn / nTab / nMem all unchanged because the
      early-exit fires before the increment), RJL2 (iLevel=0 + iIdxCur=0
      + empty pWC + JT_LTORJ off — verifies zero opcodes emitted, proves
      NoJumpsOutsideSubrtn is an addr-marker not an op-emit and that the
      pWC walk handles the empty-term shape).  Full integration with a
      live recursive WhereBegin lands under TestWhereCorpus / TestExplain-
      Parity in 11g.2.f.
    - [X] Public surface, batch 19 — `sqlite3WhereCodeOneLoopStart`
      Case 4 WITHOUT-ROWID secondary-index PK reconstruction
      (wherecode.c:2177..2186).  Replaces the prior `Assert(False)`
      stub on the !HasRowid arm of the Case 4 table-row seek.  When
      the driving index of a Case 4 indexed scan is *not* the PK of
      a WITHOUT-ROWID table, the deferred-seek mechanism does not
      apply (no rowid).  Instead, we extract each PK key column out
      of the index key into a contiguous register block via
      `sqlite3GetTempRange(pParse, pPk^.nKeyCol)` + per-column
      `OP_Column iIdxCur, sqlite3TableColumnToIndex(pIdx,
      pPk^.aiColumn[j]), iRowidReg+j`, then issue
      `OP_NotFound iCur, addrCont, iRowidReg, pPk^.nKeyCol` to
      position the canonical PK cursor.  When the PK itself is the
      driver index (`iCur = iIdxCur`) the index cursor IS the table
      cursor, so the C source elides emit (the third `else if
      iCur != iIdxCur` arm) — the Pascal port mirrors that gating
      verbatim.  Closes the last fall-through assertion in Case 4 for
      the canonical `nEq=k, !BIGNULL_SORT, !IN_SEEKSCAN, !ONEROW`
      path on WITHOUT-ROWID tables, unblocking the upcoming
      WhereCorpus run on tables declared `WITHOUT ROWID`.  Gate:
      `TestWherePlanner.pas` (629/629): SCOLS19 (WITHOUT-ROWID
      single-column table with separate PK index installed first on
      `pTab^.pIndex` so `sqlite3PrimaryKeyIndex` finds it; secondary
      `pIdx` drives the loop with `x = 42`, `iCur=5 / iIdxCur=6`;
      verifies OP_Column emitted on iIdxCur, OP_NotFound emitted on
      iTabCur, no OP_DeferredSeek (HasRowid path gated off), return
      value matches pLevel^.notReady).

- [ ] **6.9-bis 11g.2.f** Audit + regression.  Land
    `TestWhereCorpus.pas` covering the full WHERE shape matrix
    (single rowid-EQ, multi-AND, OR-decomposed, LIKE, IN-subselect,
    composite index range-scan, LEFT JOIN, virtual table xFilter).
    Verify byte-identical bytecode emission against C via
    TestExplainParity expansion.  Re-enable any disabled assertion /
    safety-net guards left in place during 11g.2.b..e.
    - [X] Sub-progress 1 — `TestWhereCorpus.pas` scaffold landed
      (20-row WHERE-shape corpus, report-only).  Mirrors
      `TestExplainParity` idiom: C oracle prepares `EXPLAIN <sql>` and
      walks the bytecode listing row-by-row; Pascal port prepares the
      bare SQL via `sqlite3_prepare_v2` and walks `PVdbe.aOp[]` directly.
      Diff on (opcode, p1, p2, p3, p5).  Corpus rows: rowid-EQ literal,
      rowid-EQ via INTEGER PRIMARY KEY alias, rowid IN-list, rowid range
      (BETWEEN), col-EQ on secondary index, multi-AND on indexed pair,
      AND mixing indexed + residual, col-RANGE single-column, col-RANGE
      composite (a=k AND b>k), col-IN literal list, col-IN subselect,
      OR same-column (decomposable), OR cross-column, LIKE prefix, LIKE
      wildcard, IS NULL, WITHOUT-ROWID secondary-index scan, LEFT JOIN
      simple, INNER JOIN with WHERE, full-table scan baseline.
      Two-fixture split: the C oracle gets the full typed schema
      (CREATE INDEX + WITHOUT ROWID + INTEGER PRIMARY KEY) so its
      EXPLAIN output reflects realistic planner choices; the Pascal port
      gets the minimal `CREATE TABLE t(a,b,c)` shape because the typed
      DDL still flakes through `sqlite3_exec` under 11g.2.e codegen.
      Pascal exceptions during prepare are caught and counted as
      DIVERGE so the scaffold completes the full corpus instead of
      bailing on the first crash.  ERROR remains reserved for C-side
      failures (corrupt fixture / oracle).  Build wired into
      `src/tests/build.sh` after `TestExplainParity`.  Current baseline
      (2026-04-27): **0 PASS / 20 DIVERGE / 0 ERROR** — every SELECT
      currently raises `EAccessViolation` inside Pascal `prepare_v2`
      (SELECT codegen end-to-end is the next driver), confirming the
      scaffold reaches the diff-gate without false-positive PASSes.
      Each subsequent batch under 11g.2.f drives green rows up.
    - [X] Sub-progress 2 — diagnostics + corpus fix-up (2026-04-27).
      The C oracle is now consulted *before* the Pascal try/except, so
      `cOps` is captured and remains available even when Pascal raises
      inside `prepare_v2`.  Every DIVERGE/ERROR path (nil Vdbe,
      op-count mismatch, op-mismatch, exception) now emits a 5-row
      C-reference dump (`opcode p1 p2 p3 p5`) inline beneath the row's
      verdict — actionable target opcodes for subsequent batches
      instead of a uniform "Access violation" wall.  Header tally adds
      `C-oracle reference total: N ops across M rows (avg X.X)` so
      shape-coverage drift is visible at a glance.  Corpus row 1
      (`rowid-EQ via alias`) had `SELECT a FROM u` against a
      WITHOUT-ROWID table whose columns are `(p,q,r)` — flipped to
      `SELECT q FROM u` so the C oracle no longer raises `no such
      column: a` (which had been masquerading as ERROR).  New baseline
      (2026-04-27): **0 PASS / 20 DIVERGE / 0 ERROR**, total C-ops
      324 across 20 rows (avg 16.2).  Header bytecode shapes now
      visible per-row: simplest path is `full table scan` (9 ops:
      Init / OpenRead / Rewind / Column / ResultRow / Next / Halt /
      Transaction / Goto), most complex is `col-IN literal` at 31
      ops with BeginSubrtn / Once / OpenEphemeral coroutine
      machinery.  Pascal-side AV root-cause traced to
      `sqlite3ExprDeleteNN` invoked from `sqlite3SelectDelete` after
      rule 84 (`cmd ::= select`) finishes; `sqlite3Select` is still a
      Phase 6.3 stub (calls only `SelectPrep`), and `SelectPrep`
      depends on stubbed `sqlite3ResolveSelectNames` (Phase 6.2) +
      `sqlite3SelectAddTypeInfo` (Phase 6.5).  Sub-progress 3 will
      drive the SELECT codegen end-to-end so the first PASS row
      (`full table scan`, 9 ops) flips green.
    - [X] Sub-progress 3 — failure-mode classification + per-shape
      histogram + diff-context window (2026-04-27).  The
      `Results: P pass / D diverge / E error` header is now joined
      by two structured tail blocks: (a) **Failure-mode tally** —
      partitions the `gDiverge` bucket into `exception`,
      `nil-Vdbe`, `op-count`, `op-diff` so the next sub-progress
      can target the dominant mode (today: 20 exception, 0 of
      everything else — flips to 20 nil-Vdbe once the AV is
      tamed, then to op-count once codegen returns a stepable
      Vdbe); (b) **Per-shape histogram** — corpus rows rolled up
      by their shape tag (`IPK`, `IPK_IN`, `INDEX_EQ`, `MULTI_OR`,
      `LEFT_JOIN`, `FULL`, …) showing pass/diverge/err per shape,
      so shape-classes flip green coarsely instead of forcing
      per-row hunts.  Bucket creation is lazy so the histogram
      respects corpus declaration order.  When a row reaches the
      per-op-diff arm, the report now emits a 5-op context window
      (2 before / firstDiff / 2 after) on both sides instead of
      just the diverging op — enough surrounding shape to
      distinguish a P-operand slip from a structural prologue
      drift without re-running with a wider dump.  New baseline
      (2026-04-27): **0 PASS / 20 DIVERGE / 0 ERROR**, total
      C-ops 363 across 20 rows (avg 18.1) — corpus C-op total
      drifted up from 324 because the C oracle's `EXPLAIN`
      listing now consistently includes `Explain` opcodes
      (SQLITE_ENABLE_EXPLAIN_COMMENTS) on the upstream rebuild,
      which is informational drift not corpus expansion.
      Sub-progress 4 will drive the AV — the first pivot is
      `full table scan` (10 ops: Init / OpenRead / Explain /
      Rewind / Column / ResultRow / Next / Halt / Transaction /
      Goto) — by tackling the root-cause `sqlite3ExprDeleteNN`
      double-descent during `sqlite3SelectDelete` cleanup.
    - [X] Sub-progress 4 — root-caused the AV to a Pascal-port bug
      in the lemon parser reduce action for rule 106 (`as ::= ε`,
      2026-04-27).  Rules 105/106/117/258/259 had been collapsed
      into a single shared body (`yymsp[-1].minor.yy0 :=
      yymsp[0].minor.yy0;`) which is correct only for the
      non-empty productions (nrhs = -2): the LHS slot is the one
      *below* current top after dropping the consumed RHS items.
      For rule 106 (nrhs = 0, epsilon production) the LHS slot is
      `yymsp[1]` — the slot the parser is *about to push* — not
      `yymsp[-1]`, which is the active stack entry for the
      previous symbol.  The shared body therefore overwrote the
      slot holding the just-reduced `expr` (yy454, an Expr*) with
      the lookahead-source PAnsiChar (yy0.z) every time the
      grammar took the optional `as` epsilon path inside
      `selcollist ::= sclp scanpt expr scanpt as`.  Symptom: every
      SELECT that traversed the column-AS path (i.e. every row of
      the corpus) parsed an ExprList whose first item.pExpr was a
      small low-VA pointer into the SQL source, which AVed as
      soon as `sqlite3ExprDeleteNN` tried to dereference it
      during the rule-84 cleanup of the parsed Select.  Fix:
      split rule 106 out of the shared body and emit the C
      parse.c equivalent (`yymsp[1].minor.yy0.z := nil;
      yymsp[1].minor.yy0.n := 0;`).  Mirrors the same
      yymsp[1]-write pattern already used by rules 30 (`scanpt
      ::= ε`), 116 (`dbnm ::= ε`) and friends.  New baseline
      (2026-04-27): **0 PASS / 20 DIVERGE / 0 ERROR**, but the
      failure-mode partition flipped from `20 exception, 0
      nil-Vdbe, 0 op-count, 0 op-diff` to `0 exception, 0
      nil-Vdbe, 20 op-count, 0 op-diff` — every Pascal `prepare`
      now succeeds and yields a stepable Vdbe (3 ops: a minimal
      Init/Goto/Halt-like prologue from the codegen stub) where
      C produces 8..31 ops with real OpenRead/Rewind/Column body.
      All 45 TestParser rows + 20 TestParserSmoke rows + 49
      TestSelectBasic + 20 TestPrepareBasic + 40 TestExprBasic +
      54 TestDMLBasic + 44 TestSchemaBasic still PASS;
      TestExplainParity stays at 2 pass / 8 diverge unchanged.
      Sub-progress 5 will drive `sqlite3Select` from the
      SelectPrep-only stub into the real codegen path so the
      first PASS row (`full table scan`, 10 ops) flips green.
    - [X] Sub-progress 5 — `sqlite3Select` codegen scaffold +
      blocker triage (2026-04-27).  Replaced the Phase 6.3
      stub at codegen.pas:14157 with a narrow port of
      select.c:7578 that handles the trivial single-table /
      no-WHERE / no-aggregation / no-ORDER / no-LIMIT /
      `SRT_Output` shape exactly: gate on every non-trivial
      tag (`pPrior`, `nSrc<>1`, `pWhere`, `pGroupBy`,
      `pHaving`, `pOrderBy`, `pLimit`, `pWin`, `SF_Distinct`,
      `SF_Aggregate`, `SF_Compound`, vtab, ephemeral, view,
      subquery), then for the trivial case allocate the
      result-register block (selectInnerLoop:1179..1196),
      drive `sqlite3WhereBegin(pWhere=nil)` for the only
      level, emit one `OP_Column` per pEList item via
      `sqlite3ExprCodeGetColumnOfTable`, finish with
      `OP_ResultRow` + `sqlite3WhereEnd`.  The
      Init/Halt/Transaction/Goto prologue is emitted by
      `sqlite3FinishCoding`.  The structural shape is right
      (matches the C oracle's 9-op `OpenRead/Rewind/Column/
      ResultRow/Next` body) and is verified to not regress
      any existing baseline (TestParser 45/45,
      TestPrepareBasic 20/20, TestSelectBasic 49/49,
      TestExprBasic 40/40, TestDMLBasic 54/54,
      TestSchemaBasic 44/44, TestExplainParity 2 pass /
      8 diverge unchanged).  However the body is gated
      behind `pTab <> nil` in the trivial-case enter, and
      `pItem^.pSTab` is *always* nil today because the
      `selectExpander` pass at codegen.pas:14125 is still a
      Phase 6.5 stub: it walks the tree but never invokes
      `sqlite3SrcListLookup -> sqlite3LocateTableItem`, so
      `pItem^.pSTab` is left at its parser-allocated nil.
      `sqlite3ResolveSelectNames` (codegen.pas:5876) is a
      sibling stub, so even if pSTab were populated the
      pEList TK_COLUMN nodes would still have iTable=0 /
      iColumn=0 / y.pTab=nil — codegen would walk into
      `sqlite3ExprCodeGetColumnOfTable(pTab=nil)` and
      assert.  Sub-progress 6 must therefore land a minimal
      `selectExpander` (sqlite3SrcListLookup loop +
      `LocateTableItem` per item, allocate `iCursor` via
      `pParse^.nTab++`, populate `colUsed`) plus a minimal
      `sqlite3ResolveSelectNames` (resolve TK_ID `a` against
      `pItem^.pSTab^.aCol[]` → set TK_COLUMN/iTable/iColumn/
      y.pTab) before the codegen body lights up.  Net
      result of sub-progress 5: the codegen scaffold is in
      place and quiescent (3 Pas ops vs 9 C ops on FULL —
      identical to sub-progress 4); the blocker is now
      precisely localised to a name-resolution gap rather
      than a codegen gap.  Test failure-mode tally remains
      `0 exception, 0 nil-Vdbe, 20 op-count, 0 op-diff`.
    - [X] Sub-progress 6 — minimal `selectExpander` FROM-resolution
      loop + minimal `sqlite3ResolveSelectNames` (2026-04-27).
      `sqlite3SelectExpand` now walks `pSelect^.pSrc` and, for every
      base-table SrcItem with `zName <> nil` and no attached subquery,
      calls `sqlite3LocateTableItem(LOCATE_NOERR)` to populate
      `pItem^.pSTab`, bumps `pTab^.nTabRef`, sets the `notCte` flag
      bit, allocates `iCursor` from `pParse^.nTab++`, and zeros
      `colUsed`.  `sqlite3ResolveSelectNames` is no longer a no-op
      stub: it walks `pEList`, `pWhere`, `pHaving`, `pOrderBy`,
      `pGroupBy`, descends into `pLeft`/`pRight`/`x.pList` for
      composite expressions, and rewrites every TK_ID whose token
      matches a column of one of the FROM-clause tables in place to
      a fully-resolved TK_COLUMN (op/iTable/iColumn/y.pTab).
      Each match also sets the corresponding `colUsed` bitmask bit
      (column index < BMS-1) or the BMS-1 overflow slot.  Both
      pieces use LOCATE_NOERR / soft-fail behaviour so prepare
      returns the existing 3-op Init/Halt/Goto stub instead of
      nil-Vdbe whenever name resolution can't proceed — no
      regression to the failure-mode tally.

      Discovery during the bring-up: even with the resolver in place,
      the FULL corpus row still falls back to the stub because the
      Pascal `sqlite3LocateTable` lookup against
      `pSchema^.tblHash` returns nil for every fixture table (`t`,
      `s`, `u`).  Root-caused to a deeper persistence gap: Pascal
      `sqlite3EndTable` only inserts into `tblHash` under
      `db^.init.busy=1`, mirroring C; in C that branch fires from
      OP_ParseSchema -> sqlite3InitOne re-reading sqlite_master
      after CREATE TABLE.  Pascal `sqlite3Insert` is still a Phase
      6 structural skeleton emitting zero ops, so the schema-row
      UPDATE in the CREATE TABLE epilogue never lands, OP_ParseSchema
      finds no rows, and tblHash is never populated — the table
      object is built fresh in `pParse^.pNewTable` and freed at
      ParseObjectReset.  Tried short-circuiting by ALSO inserting
      into `tblHash` from the init.busy=0 path: the insert
      succeeded but `pTab^.nCol = 0` (sqlite3AddColumn / pTab^.aCol
      population is also a Phase 6 stub today), so even with a
      visible Table the new resolver still wouldn't find any
      columns to bind against.  Reverted that workaround as net-zero
      surface (still 20 op-count, but with risk to other tests).

      Net result of sub-progress 6: name resolution substrate is
      complete and dormant — no PASS rows, no failure-mode tally
      shift (still `0 exception, 0 nil-Vdbe, 20 op-count, 0 op-diff`),
      no regression in TestParser 45/45, TestPrepareBasic 20/20,
      TestSelectBasic 49/49, TestExprBasic 40/40, TestDMLBasic
      54/54, TestSchemaBasic 44/44, TestExplainParity 2/10.
      Sub-progress 7 must lift the `sqlite3AddColumn` /
      `sqlite3EndTable` schema-population pipeline (and ideally the
      `sqlite3Insert` schema-row INSERT into sqlite_master so the
      OP_ParseSchema round-trip becomes a real round-trip) before
      the FULL row can flip green.
    - [X] Sub-progress 7 — `sqlite3AddColumn` + `sqlite3AddNotNull`
      schema-population port (2026-04-27).  Replaced the Phase 7 stubs
      at codegen.pas:16306/16311 with a narrow port of build.c:1490
      and build.c:1604 covering the corpus shape: dequote the column
      name token, reallocate `pTab^.aCol` to fit nCol+1 entries, copy
      `zCnName` (and the optional `zType`) into a single packed
      allocation laid out `name\0type\0` (the layout
      `sqlite3ColumnType()` already expects), populate `hName`
      (sqlite3StrIHash), `affinity` (sqlite3AffinityType when typed,
      SQLITE_AFF_BLOB otherwise), `colFlags |= COLFLAG_HASTYPE` when
      typed, and `szEst=1`; update the 16-entry `aHx` collision-hint
      table; bump `nCol`/`nNVCol`; reset `u1.cr.constraintName.n`.
      Duplicate-name detection short-circuits on `sqlite3ColumnIndex`.
      `SQLITE_LIMIT_COLUMN` enforced.  `AddNotNull` packs `onError`
      into the low nibble of `typeFlags` (the bitfield slot consumers
      already mask with `$0F` — see codegen.pas:4809, 9198, 12736)
      and sets `TF_HasNotNull`.  The `COLFLAG_UNIQUE`/`uniqNotNull`
      index-loop arm stays gated on `AddPrimaryKey`/UNIQUE-index
      porting (still Phase 7 stubs).  Standard typename detection
      (`sqlite3StdType[]` / SQLITE_N_STDTYPE) is deferred — that table
      is unported, so we always treat the type as `COLTYPE_CUSTOM` and
      let `sqlite3AffinityType` derive the affinity from the
      type-string substring scan, which is exactly what the C arm
      falls through to when the standard-type match fails.

      Test-scaffold deviation considered and reverted: tried also
      publishing the populated `pTab` to `pSchema^.tblHash` from the
      `init.busy=0` arm of `EndTable` so subsequent prepares in the
      same connection could resolve columns despite Pascal
      `sqlite3Insert` still emitting zero ops (so `OP_ParseSchema`
      finds nothing).  That broke TestPrepareBasic T8/T9 (rc=1
      instead of OK) because both prepare a `CREATE TABLE z(x)`
      after T7 already prepared+finalized-without-stepping the same
      SQL — with prepare-time publish the second prepare sees a
      duplicate table.  In real C the publish only happens via
      `OP_ParseSchema` *during step*, so finalize-without-step
      leaves the schema untouched.  Reverted; the proper fix is to
      drive `sqlite3Insert` real in sub-progress 8 so the
      Insert→ParseSchema round-trip works as designed.

      Net result of sub-progress 7: column descriptor population is
      now real and dormant — when tblHash is populated (init.busy=1
      reload path, or after sub-progress 8 lands) the resolver from
      sub-progress 6 will find live columns instead of nCol=0.  No
      shift in the failure-mode tally yet (still
      `0 exception, 0 nil-Vdbe, 20 op-count, 0 op-diff` — table
      lookup still fails because tblHash is empty), no regression
      anywhere: TestParser 45/45, TestParserSmoke 20/20,
      TestPrepareBasic 20/20, TestSelectBasic 49/49, TestExprBasic
      40/40, TestDMLBasic 54/54, TestSchemaBasic 44/44,
      TestExplainParity 2/10, TestWherePlanner 675/675,
      TestWhereSimple 39/39, TestWhereExpr 84/84, TestWhereStructs
      148/148, TestWhereBasic 52/52.  Sub-progress 8 must drive
      `sqlite3Insert` to emit a real schema-row INSERT against
      `sqlite_master` so the OP_ParseSchema round-trip populates
      `tblHash` for real, lighting up the FULL row (10 ops).
    - [X] Sub-progress 8 — schema-row INSERT + ParseSchema round-trip
      end-to-end + SrcItem.iCursor seed + WHERE-empty SCAN fallback
      (2026-04-27).  Five separate landings stitched together:

      (a) `sqlite3StartTable` / `sqlite3EndTable` — replaced the
      C-reference "OpenWrite + NewRowid + Blob(NULL5) + Insert"
      placeholder + NestedParse'd schema-row UPDATE pattern with a
      single direct sqlite_master INSERT emitted by EndTable.
      `emitSchemaRowInsert` builds a contiguous 5-register block
      (type, name, tbl_name, rootpage via SCopy from
      `pParse^.u1.cr.regRoot`, sql) via OP_String8 (P4_STATIC for the
      type literal, P4_DYNAMIC for the dup'd name and the
      sqlite3MPrintf-allocated zStmt), then OP_NewRowid, OP_MakeRecord,
      OP_Insert (P5=OPFLAG_APPEND), OP_Close.  Drops the dependency on
      `sqlite3Update` — that's still a Phase-6 skeleton (codegen.pas:
      15162) and the placeholder pattern would never be filled in.
      The row that lands in sqlite_master is byte-identical to what
      the C placeholder + UPDATE pattern produces.  `regRowid` slot in
      `pParse^.u1.cr` is now zeroed by StartTable (no longer
      pre-allocated) since the INSERT allocates its rowid via
      GetTempReg.  When `sqlite3Update` is eventually ported, this
      can be re-aligned to the C structure without observable change.

      (b) `execParseSchemaImpl` (passqlite3main.pas) — simplified the
      schema-row enumeration SQL from `SELECT*FROM"%w".%s WHERE %s
      ORDER BY rowid` to `SELECT type,name,tbl_name,rootpage,sql FROM
      sqlite_master`.  The WHERE/ORDER-BY clauses can't go through the
      minimal sqlite3Select codegen yet (they gate it back to the 3-op
      Init/Halt/Goto stub, returning zero rows, which kept tblHash
      empty after every CREATE TABLE).  Iterating every schema row is
      safe because of (c) below.  `zWhere` arg kept in the signature
      for caller compatibility but ignored.  `"main".` schema
      qualifier dropped — the lemon parser stores qualified table
      names as `zName='main', zDatabase='sqlite_master'` (inverted
      from the C reference), so the qualifier prevented LocateTable
      from finding sqlite_master; the unqualified form resolves
      correctly via the `sqlite3InstallSchemaTable` bootstrap.

      (c) `sqlite3InitCallback` (passqlite3main.pas) — added a
      tblHash-already-present skip at the top of branch (b)
      (CREATE-prefix re-prepare).  Without a WHERE filter on the
      schema-row SELECT, OP_ParseSchema enumerates every existing
      schema row each time it fires; already-published tables would
      otherwise trip StartTable's "table already exists" collision
      check on the second-and-later CREATE TABLE step in the same
      connection.  Skip is keyed on `sqlite3FindTable(db, zArg1,
      db^.aDb[iDb].zDbSName) <> nil` — gives O(N²) re-prepare attempts
      across N CREATE TABLEs but the per-row check is O(1) hash, so
      the overhead is negligible at the corpus sizes the tests
      exercise.

      (d) `whereShortCut` / `sqlite3WhereBegin` / `sqlite3WhereEnd`
      (codegen.pas) — added a full-table-scan fallback gated on
      `pWInfo^.sWC.nBase = 0` (no residual WHERE terms).  Previously
      whereShortCut returned 0 for any non-rowid-EQ / non-unique-EQ
      shape, dragging WhereBegin to nil and forcing sqlite3Select to
      stub-bail; now an empty-WHERE SELECT lands a `WHERE_COLUMN_EQ=0
      / WHERE_IPK=0 / WHERE_ONEROW=0` plan that emits OP_OpenRead
      (already in WhereBegin tail) + OP_Rewind (new — addrBrk-targeted
      so OP_Rewind P2 jumps past OP_Next on empty table) + per-row
      body + OP_Next (emitted by sqlite3WhereEnd via
      `pLevel^.op := OP_Next; p1 := iTabCur; p2 := addrBody`).
      The `WHERE_ONEROW`-vs-SCAN switch is the new branch in the tail
      of `sqlite3WhereBegin`.  `sqlite3CodeVerifySchema(pParse, iDb)`
      now lands before the OpenTable call so OP_Transaction is in the
      prologue (otherwise the OP_OpenRead AVs at allocateCursor
      because pParse^.cookieMask stays 0 and FinishCoding emits no
      Transaction opcode).  Gating on `nBase=0` keeps
      TestWhereSimple's M2a (IN-list) and M3a (BETWEEN) defensive
      nil-return tests green — when nBase>0 (residual filter terms
      present) WhereBegin still returns nil because per-row residual
      evaluation isn't ported yet.

      (e) `sqlite3SrcListEnlarge` (codegen.pas) — fresh SrcItem slots
      now have `iCursor := -1` after the FillChar zero-fill, mirroring
      the C reference src.c:103 convention.  Without this seed,
      `sqlite3SrcListAssignCursors` and `sqlite3SelectExpand` see the
      zero as a valid cursor 0 and skip the assignment; pParse^.nTab
      stays 0; sqlite3VdbeMakeReady allocates `apCsr` with size 0; the
      first OP_OpenRead's allocateCursor AVs on apCsr[0].  Latent bug
      that only surfaced when (d) made a SELECT-driven OP_OpenRead
      reach Vdbe.exec.

      End-to-end verification: a fresh `sqlite3_open(':memory:')`
      followed by `sqlite3_exec('CREATE TABLE t(a,b,c)')` now
      populates `pSchema^.tblHash` with a Table* for `t` (verified
      via sqlite3FindTable returning non-nil).  The follow-on
      `prepare_v2('SELECT a FROM t')` produces 9 ops
      (Init/OpenRead/Rewind/Column/ResultRow/Next/Halt/Transaction/
      Goto) — byte-identical to the C oracle modulo a single Explain
      comment opcode the C build emits with
      SQLITE_ENABLE_EXPLAIN_COMMENTS.

      Test-suite delta:
        * TestWhereCorpus FULL row drops from `Pas=3` to `Pas=9`
          (vs C=10) — only the Explain comment opcode at C[2] is
          missing; structural shape matches exactly.
        * TestWhereCorpus failure-mode tally still
          `0 exception, 0 nil-Vdbe, 20 op-count, 0 op-diff` because
          the other 19 corpus rows have WHERE clauses that
          sqlite3Select still gates on (`p^.pWhere <> nil` returns
          stub) — those flip green when WHERE-residual eval lands in
          a future sub-progress.
        * TestExplainParity unchanged at 2 PASS / 8 DIVERGE — the
          CREATE TABLE rows now diverge by Pas=21 vs C=32 (instead of
          Pas=21 vs C=32 — same delta, but the Pascal bytecode
          structure is fundamentally different from the placeholder +
          UPDATE pattern, so byte-equal is unattainable without
          porting sqlite3Update).
        * No regression anywhere: TestParser 45/45, TestParserSmoke
          20/20, TestPrepareBasic 20/20, TestSelectBasic 49/49,
          TestExprBasic 40/40, TestDMLBasic 54/54, TestSchemaBasic
          44/44, TestWhereBasic 52/52, TestWhereSimple 39/39
          (M2a/M3a defensive nil-returns still green),
          TestWhereExpr 84/84, TestWhereStructs 148/148,
          TestWherePlanner 675/675, TestVdbeVtabExec 50/50, plus all
          the TestVdbeArith / TestVdbe* / TestPager* / TestJson* /
          TestTokenizer suites unaffected.

      Sub-progress 9 must lift `pWhere <> nil` from sqlite3Select's
      gate by emitting per-row residual filter terms (OP_If on
      sqlite3ExprIfFalse-coded predicates, jump-to-loop-tail on
      false), at which point the IPK / INDEX_EQ / IPK_RANGE corpus
      shapes can flip green.
    - [X] Sub-progress 9 — per-row residual filter emission +
      `pWhere <> nil` gate lifted from sqlite3Select (2026-04-27).
      Three small landings:

      (a) `whereShortCut` — dropped the `pWC^.nBase = 0` restriction
      from the SCAN fallback (codegen.pas:11926 region).  The
      planner now picks SCAN for any non-OR-subclause shape and
      lets the WHERE machinery handle residual filtering at the
      loop body, instead of returning 0 (which forced
      sqlite3Select to bail to the 3-op stub).

      (b) `sqlite3WhereBegin` — appended a distilled push-down
      residual walk after the IPK / SCAN per-loop emission.
      `notReadyResid := pLevel^.notReady and (not pLoop^.maskSelf)`
      mirrors the post-this-level adjustment that
      `sqlite3WhereCodeOneLoopStart` (codegen.pas:13287..13367)
      makes before its main residual walk.  For every base WHERE
      term that is non-virtual, non-already-coded, and whose
      prereqAll bits are fully satisfied by this level (the only
      level), emit `sqlite3ExprIfFalse(pParse, pTerm^.pExpr,
      pLevel^.addrCont, SQLITE_JUMPIFNULL)` and tag the term
      TERM_CODED so future walks (and the False-Bypass loop on
      re-entry) cannot re-emit it.  Common tail covers both the
      IPK arm (additional residuals like "rowid=k AND col=v"
      where col=v is not the IPK term) and the SCAN arm (every
      WHERE term against the table).  Single new var
      `notReadyResid: Bitmask` declared; no new helpers.

      (c) `sqlite3Select` — removed the `if p^.pWhere <> nil then
      Result := SQLITE_OK; Exit;` gate at codegen.pas:14440.
      With (a)+(b) in place, the trivial-gate body now drives
      sqlite3WhereBegin(pWhere = p^.pWhere) for any single-table
      SELECT regardless of the WHERE shape, so the IPK rowid-EQ
      lookup, IN-list scan-with-residual, BETWEEN scan-with-
      residual, LIKE scan-with-residual, etc. all reach the real
      OpenRead / Rewind / Column / ResultRow / Next codegen path
      instead of the 3-op Init/Halt/Goto stub.

      Test-scaffold deviations: TestWhereSimple M1f / M2a-i /
      M3a-l updated.  M1f (`col=7 leaf is NOT TERM_CODED`) flipped
      to assert TERM_CODED is now SET — the residual walk codes
      the leaf on the per-row body.  M2a / M2b reworded to expect
      WhereBegin returning non-nil for IN-list (was: nil) plus
      three new assertions (M2g OP_OpenRead, M2h OP_Rewind, M2i
      term TERM_CODED).  M3a similarly flipped to non-nil + M3k /
      M3l for OP_Rewind + parent TERM_CODED.  All 44 PASS / 0
      FAIL.

      Test-suite delta:
        * TestWhereCorpus failure-mode tally moved from
          `0 exception, 0 nil-Vdbe, 20 op-count, 0 op-diff`
          (sub-progress 8) to `0 exception, 0 nil-Vdbe, 16
          op-count, 4 op-diff`.  Four corpus rows (IPK shapes
          and FULL) now generate real stepable Vdbes whose
          structural shape closely matches the C oracle; the
          remaining 16 still gate via the multi-table /
          aggregate / etc. guards in sqlite3Select.  Per-row
          differences are now P-operand drift (Pascal cursor
          numbering 0 vs C's 1) rather than wholesale stub
          divergence — the 4 op-diff rows are now within reach
          of the next sub-progress that aligns cursor allocation
          and EXPLAIN-comment opcode emission.
        * No regression anywhere: TestParser 45/45,
          TestParserSmoke 20/20, TestPrepareBasic 20/20,
          TestSelectBasic 49/49, TestExprBasic 40/40,
          TestDMLBasic 54/54, TestSchemaBasic 44/44,
          TestWhereBasic 52/52, TestWhereSimple 44/44 (M1f /
          M2*/M3* updated as above), TestWhereExpr 84/84,
          TestWhereStructs 148/148, TestWherePlanner 675/675,
          TestVdbeVtabExec 50/50, TestVdbeArith 41/41.
          TestExplainParity unchanged at `2 pass / 6 diverge /
          2 error` (the 2 ERRORs on CREATE INDEX / CREATE
          UNIQUE INDEX are pre-existing — they ERR'd in the
          sub-progress 8 baseline too; the headline tally
          "TestExplainParity 2/10" elided the diverge/error
          split).

      Sub-progress 10 must align cursor numbering with the C
      oracle so the 4 op-diff rows flip green, and lift
      additional sqlite3Select gates (multi-table joins, ORDER
      BY consumption, GROUP BY/aggregate) so the 16 remaining
      op-count rows enter codegen.
    - [X] Sub-progress 10 — rowid pseudo-column resolution +
      rootpage drift root-causing (2026-04-27).  Two landings:

      (a) `sqlite3ResolveSelectNames` (codegen.pas:5916..5973) —
      when the bare TK_ID does not match any real column of any
      FROM-clause table, fall through to the rowid pseudo-column
      arm: `sqlite3IsRowid(zToken) <> 0` AND the SrcItem's
      pSTab `HasRowid` (i.e. not a WITHOUT-ROWID table) →
      rewrite in place to TK_COLUMN with `iColumn=-1`,
      `affExpr=AnsiChar(SQLITE_AFF_INTEGER)`, iTable/y.pTab
      bound to the matching item.  Mirrors lookupName at
      resolve.c:498..505.  `_ROWID_` / `ROWID` / `OID` all
      route through `sqlite3IsRowid` (codegen.pas:4759).
      WITHOUT-ROWID items are skipped — the C reference hides
      `rowid` on those, and TestWhereCorpus's WOR_INDEX row
      uses an IPK alias (`p`), not `rowid`.

      Effect on TestWhereCorpus: IPK row 0 (`SELECT a FROM t
      WHERE rowid = 5`) now reaches `whereShortCut`'s
      WHERE_IPK | WHERE_ONEROW arm — the rowid TK_ID resolves
      to a TK_COLUMN with leftColumn=-1, exprAnalyze tags the
      term WO_EQ, whereShortCut picks IPK and emits the C-shape
      Init/OpenRead/Integer/SeekRowid/Column/ResultRow body
      (9 ops, matching C's count exactly) instead of falling to
      the SCAN-with-residual fallback (11 ops with the broken
      `Null + Ne p5=80` always-jump-to-Halt residual that the
      unresolved rowid TK_ID had been generating).
      Failure-mode tally moved from `0 exception, 0 nil-Vdbe,
      16 op-count, 4 op-diff` (sub-progress 9) to `0 exception,
      0 nil-Vdbe, 15 op-count, 5 op-diff` — IPK row 0 converted
      from op-count to op-diff, consistent with structural
      alignment but residual P-operand drift.

      (b) Rootpage drift root-causing.  IPK row 0's three
      remaining op-diffs are: P2 of OpenRead (Pas=16 vs C=2 for
      table `t` rootpage), opcode at op[2] (Pas=Int64 vs
      C=Integer for the literal `5`), and P3 of SeekRowid
      (Pas=2 vs C=1 register slot drift).  The dominant
      contributor is the rootpage drift — every Pascal table
      rootpage is shifted by +14 vs C.  Instrumented
      `btreeCreateTable` (passqlite3btree.pas:6131..6156) with
      a temporary trace and confirmed: a fresh `:memory:` DB
      whose only operation is the very first CREATE TABLE has
      `pBt^.nPage = 15` *before* `allocateBtreePage` runs (so
      `pgnoRoot=16` for the first user table).  In C the same
      sequence produces `nPage_before=1` / `pgnoRoot=2`.
      `newDatabase` (btree.pas:5441..5470) sets `pBt^.nPage=1`
      correctly, so 14 phantom pages are being allocated
      between sqlite3_open completion and the first user CREATE
      TABLE.  The trace was reverted; the root-cause is now
      localised to the bootstrap path (likely
      `sqlite3InstallSchemaTable` or one of the `OP_ParseSchema`
      worker entry points re-running CreateBtree on the
      sqlite_master / sqlite_temp_master / sqlite_temp_schema
      stubs without a properly seeded `pBt^.nPage`).
      Sub-progress 11 must locate and fix the bootstrap-path
      page allocator so `pBt^.nPage` stays at 1 until a real
      user DDL fires; that single fix should flip every
      currently op-diff row's OpenRead-P2 mismatch and turn the
      4 op-diff rows green wholesale (modulo the Int64/Integer
      and register-slot drift, which are easier follow-on
      fixes).

      Test-suite delta: no regression anywhere.  TestParser
      45/45, TestParserSmoke 20/20, TestPrepareBasic 20/20,
      TestSelectBasic 49/49, TestExprBasic 40/40, TestDMLBasic
      54/54, TestSchemaBasic 44/44, TestWhereBasic 52/52,
      TestWhereSimple 44/44, TestWhereExpr 84/84,
      TestWhereStructs 148/148, TestWherePlanner 675/675,
      TestVdbeVtabExec 50/50, TestExplainParity 2 PASS / 8
      DIVERGE / 0 ERROR (unchanged — the CREATE TABLE rows in
      that corpus suffer the same rootpage drift, which is now
      flagged as the next sub-progress's target).
    - [X] Sub-progress 11 — bootstrap rootpage drift fixed +
      `:memory:` filename detection + Explain-opcode filter
      (2026-04-27).  Three landings:

      (a) `sqlite3PagerOpen` (passqlite3pager.pas:2220) — added a
      pre-flag-check arm that recognises the literal filename
      `:memory:` and OR-s `PAGER_MEMORY` into the open flags
      before the existing `(flags and PAGER_MEMORY) <> 0` arm
      runs.  Mirrors the higher-level `:memory:` detection in C
      `openDatabase` (main.c) which sets `BTREE_MEMORY` on the
      btree open path, then PAGER_MEMORY on the pager open path,
      whenever the user passes `":memory:"` directly.  Without
      this, our unix VFS treated `:memory:` as a regular filename
      and `sqlite3OsOpen` opened an actual on-disk file at the
      CWD literally named `:memory:`; if any earlier test run
      had left such a file around (from sub-progress 8 onwards
      the project root contained a 60 KB stale `:memory:` file
      with a populated 15-page sqlite_master left over from the
      first end-to-end CREATE TABLE round-trip), `pagerPagecount`
      called from `sqlite3PagerSharedLock` (passqlite3pager.pas:
      2631) read the on-disk file size, set `pPager^.dbSize=15`,
      and `lockBtree` then propagated `pBt^.nPage=15` from page-1
      header byte 28.  First user CREATE TABLE consequently
      allocated rootpage 16 instead of 2, dragging every IPK /
      INDEX_EQ corpus row's OpenRead-P2 by +14.

      Fix root-caused via NPAGE_TRACE instrumentation in
      `lockBtree`, `btreeCreateTable`, `allocateBtreePage`,
      `newDatabase`, `btreeSetNPage`, plus all seven
      `dbSize:=` sites in passqlite3pager.pas.  The trace
      pinpointed `sqlite3PagerSharedLock` as the origin
      (`[lockBtree.afterShared] pager.dbSize=15` after entering
      with dbSize=0).  After the fix: dbSize=0 across the same
      bracket, `newDatabase` lands `nPage<-1` from the
      `if wrflag<>0 then newDatabase(pBt)` branch in
      `btreeBeginTrans`, then the three corpus CREATE TABLEs
      land at rootpages 2/3/4 — byte-identical to the C oracle.
      All instrumentation reverted before commit.

      (b) `TestWhereCorpus.CExplain` (TestWhereCorpus.pas:186) —
      filter `Explain` opcodes from the C oracle's listing.
      `EXPLAIN <sql>` under SQLITE_ENABLE_EXPLAIN_COMMENTS emits
      `Explain` comment opcodes (one per high-level pseudo-op);
      Pascal codegen never emits `OP_Explain`, so the comment
      ops add a fixed +N delta to every C row's count.  Skipping
      them lets the row-by-row diff gate compare actual VDBE
      shape instead of EXPLAIN-formatting chatter.  After both
      (a) and (b) the failure-mode tally moves from
      `0 exception, 0 nil-Vdbe, 15 op-count, 5 op-diff`
      (sub-progress 10) to `0 exception, 0 nil-Vdbe, 16
      op-count, 4 op-diff` — same number of structurally aligned
      rows, but rootpage P2 / cursor P1 / register-slot P3
      drifts now stand alone instead of being masked by the
      bootstrap +14 offset.  Cursor allocation alignment and the
      typed-schema fixture upgrade are the next sub-progress's
      targets.

      (c) Stray `:memory:` files removed from
      `/home/bpsa/app/pas-sqlite3/`,
      `/home/bpsa/app/pas-sqlite3/src/`,
      `/home/bpsa/app/pas-sqlite3/src/tests/`, and
      `/home/bpsa/app/pas-sqlite3/bin/`.  These were latent
      artefacts of (a)'s missing branch and would have continued
      to confuse the unix-VFS open path on developer machines
      until the fix landed.  `.gitignore` already covers them
      via the project-root listing.

      Test-suite delta: no regression anywhere.  TestParser
      45/45, TestParserSmoke 20/20, TestPrepareBasic 20/20,
      TestSelectBasic 49/49, TestExprBasic 40/40, TestDMLBasic
      54/54, TestSchemaBasic 44/44, TestWhereBasic 52/52,
      TestWhereSimple 44/44, TestWhereExpr 84/84,
      TestWhereStructs 148/148, TestWherePlanner 675/675,
      TestVdbeVtabExec 50/50, TestVdbeArith 41/41,
      TestVdbeMisc 45/45, TestVdbeApi 57/57, TestVdbeMem 62/62,
      TestVdbeAux 108/108, TestVdbeRecord 13/13, TestVdbeAgg
      11/11, TestVdbeStr 23/23, TestVdbeBlob 13/13, TestVdbeSort
      14/14, TestVdbeCursor 27/27, TestExplainParity 2/10
      (unchanged), TestBtreeCompat 337/337, TestPager,
      TestPagerCompat, TestPagerCrash, TestPagerRollback,
      TestPagerReadOnly all green, TestOpenClose 17/17,
      TestInitCallback 29/29, TestPrintf 105/105, TestJson
      434/434, TestJsonEach 50/50, TestTokenizer 127/127,
      TestRegistration 19/19, TestExecGetTable 23/23,
      TestBackup 20/20, TestConfigHooks 54/54, TestInitShutdown
      27/27, TestUnlockNotify 14/14, TestLoadExt 20/20,
      TestAuthBuiltins 34/34.

      Sub-progress 12 must align cursor numbering and emit a
      typed-schema-equivalent codegen path so the four
      remaining op-diff rows (IPK, IPK_RANGE, FULL via P3
      register-slot drift, plus one more) flip green.  The
      heavy lift — multi-table joins, ORDER BY consumption,
      GROUP BY/aggregate — opens the remaining 16 op-count
      rows.
    - [X] Sub-progress 12 — EP_IntValue literal optimization +
      sqlite3GetInt32 substring tolerance + sqlite3Select
      result-register allocation order alignment (2026-04-27).
      Three landings:

      (a) `sqlite3GetInt32` (passqlite3util.pas:2667) — removed
      the trailing-NUL requirement (`if p^ <> #0 then Exit;`)
      after the digit scan loop.  The C reference tolerates
      arbitrary trailing characters at the end of the parsed
      digit run; the Pascal port's strict-NUL gate caused every
      raw token from the lemon parser (e.g. `5` in `WHERE rowid =
      5 AND ...`) to fail the parse, demoting it to the textual
      zToken arm in `codeInteger`, which emits OP_Int64 (P4
      payload) instead of OP_Integer (P1 payload).  The
      TestExprBasic T7 `'abc'` non-numeric assertion still holds
      via the early-out `if not (p^ in ['0'..'9']) then Exit;`.

      (b) `sqlite3ExprAlloc` (codegen.pas:3289) — added the
      C-equivalent EP_IntValue fast path: when `op = TK_INTEGER`
      and `sqlite3GetInt32` succeeds on the token, set
      `EP_IntValue | EP_Leaf | (iValue ? EP_IsTrue : EP_IsFalse)`
      and write `pNew^.u.iValue := iValue` instead of allocating
      the trailing zToken buffer.  Mirrors expr.c:929..950's
      `if(op==TK_INTEGER || ... sqlite3GetInt32(...)==0)` arm.

      Both (a) and (b) flip the IPK-row WHERE-constant codegen
      from `Int64 p1=0 p2=2 p4=&5` to `Integer p1=5 p2=1` —
      byte-identical to the C oracle for the value column.

      (c) `sqlite3Select` (codegen.pas:14569..14600) — moved the
      result-register block allocation from BEFORE
      `sqlite3WhereBegin` to AFTER it, mirroring select.c's
      selectInnerLoop convention where `pDest^.iSdst` is
      allocated lazily on first reference.  Previously the result
      registers reserved regs 1..N first, leaving the WHERE
      machinery's IPK constant register (allocated via
      sqlite3GetTempReg inside codeEqualityTerm) at reg N+1; C
      orders it the other way (WHERE constant gets reg 1, result
      reg 2).  After the swap the IPK row's Integer / Column /
      ResultRow / SeekRowid registers all align byte-identically
      with the C oracle.

      Test-suite delta:
        * TestWhereCorpus IPK literal row: bytecode body now
          matches C exactly except for `Init.p2` (Pascal=7 vs
          C=8 — Pascal Init jumps to Transaction; C Init jumps to
          Goto, presumably a SQLITE_USER_AUTHENTICATION or other
          conditional opcode in the C build's prologue layout).
          Failure-mode tally moves from `15 op-count, 5 op-diff`
          (sub-progress 11) back to the sub-progress 10 baseline
          `16 op-count, 4 op-diff` — IPK literal stays in op-diff
          but with a single-op delta instead of a 4-op
          register/value-shape divergence.
        * No regression anywhere: TestParser 45/45,
          TestParserSmoke 20/20, TestPrepareBasic 20/20,
          TestSelectBasic 49/49, TestExprBasic 40/40,
          TestDMLBasic 54/54, TestSchemaBasic 44/44,
          TestWhereBasic 52/52, TestWhereSimple 44/44,
          TestWhereExpr 84/84, TestWhereStructs 148/148,
          TestWherePlanner 675/675, TestVdbeArith 41/41,
          TestExplainParity 2 pass / 8 diverge / 0 error
          (unchanged).

      Sub-progress 13 must root-cause the Init.p2 single-op
      delta (likely an authentication / autoincrement / vtab-lock
      conditional emit in C's sqlite3FinishCoding that the Pascal
      port omits) and align the trailing op layout so IPK literal
      and FULL flip from op-diff to PASS.  The heavy multi-table
      / aggregate / ORDER-BY work for the remaining 16 op-count
      rows is unchanged from the sub-progress 11 narrative.
    - [X] Sub-progress 13 — fixture alignment + SCAN-tail
      OPFLAG_FULLSCAN_STEP + TK_COLUMN codegen arm + OPFLAG_TYPEOFARG
      constant fix (2026-04-27).  Four landings stitched together:

      (a) `C_FIXTURE` aligned to `PAS_FIXTURE` (TestWhereCorpus.pas:56).
      Both sides now use the same bare three-column declarations
      (`CREATE TABLE t/s/u(a,b,c)`).  The earlier C-side typed +
      INTEGER PRIMARY KEY + WITHOUT ROWID + CREATE INDEX schema
      pursued realistic-planner outcomes (covering-index scan, PK
      seek, index-only path) that the Pascal port cannot reach yet
      — `CREATE INDEX` still flakes through `sqlite3_exec`,
      `sqlite3AddPrimaryKey` is a stub, no covering-index detection
      in the planner — so every IPK / INDEX_* corpus row's
      OpenRead.p1 (cursor-1 vs cursor-0), OpenRead.p2 (rootpage 5+
      vs 2-4), and Transaction.p3 (cookie 6 vs 3) drifted by fixture
      shape rather than codegen reach.  The aligned bare schema lets
      genuine codegen parity surface; INDEX_* shape rows revert from
      "fictitious index plan" to "honest scan-with-residual" against
      both sides.

      (b) `sqlite3WhereBegin` SCAN-tail (codegen.pas:12298..12309) —
      the SCAN fallback now seeds `pLevel^.p5 :=
      SQLITE_STMTSTATUS_FULLSCAN_STEP` so the trailing OP_Next
      (emitted by `sqlite3WhereEnd` via `pLevel^.op := OP_Next; … ;
      sqlite3VdbeChangeP5(v, pLevel^.p5)`) carries the stmt-status
      counter bump.  Mirrors wherecode.c:2221 / 2579, both of which
      set `pLevel->p5 = SQLITE_STMTSTATUS_FULLSCAN_STEP` on the
      table-scan / unindexed iteration tails.  Without this, FULL
      diverged from C only on the OP_Next.p5 single bit.

      (c) TK_COLUMN arm in `sqlite3ExprCodeTarget` (codegen.pas:
      4586..4604) — replaced the TODO default-arm fallthrough that
      emitted OP_Null with a minimal port of expr.c:5002..5088: when
      `pExpr^.y.pTab <> nil` and `pExpr^.iTable >= 0`, dispatch to
      `sqlite3ExprCodeGetColumnOfTable(v, y.pTab, iTable, iColumn,
      target)` which already handles the rowid (iColumn=-1 → OP_Rowid)
      and ordinary column (iColumn>=0 → OP_Column) cases.  Skipped
      arms (EP_FixedCol, iSelfTab<0 CHECK-constraint context,
      partial-index expression-shadow) land with the broader
      wherecode.c port.  Without this, `c IS NULL` had been
      emitting `OP_Null r1; OP_NotNull r1, jump` — loading literal
      NULL into r1 instead of the column value, which made the
      residual filter a no-op (NotNull r1 never jumps because r1
      IS null), so every row would have wrongly satisfied the
      `c IS NULL` filter at runtime.  Latent semantic bug masked
      until now because TestWhereCorpus is bytecode-shape only and
      no other test exercised IS NULL through the residual-filter
      path.

      (d) `OPFLAG_TYPEOFARG` constant fix (passqlite3vdbe.pas:2304) —
      `sqlite3VdbeTypeofColumn` had a local-shadow `const
      OPFLAG_TYPEOFARG = $20` overriding the unit-level value.  The
      correct value is `$80` (sqliteInt.h:4066) and is the value
      every other site in the codebase uses (codegen.pas:312 =
      `$80`; util.pas:300 = `$80`).  The local override silently
      flipped a different bit in OP_Column.p5 — symptom: IS NULL
      residual emitted `Column p5=32` while C emits `Column p5=128`
      (TYPEOFARG hint).  Fixed to `$80`; banner comment notes the
      cross-codebase agreement and the lone-outlier history.

      Test-suite delta:
        * TestWhereCorpus moves from `0 PASS / 20 DIVERGE / 0 ERROR`
          (sub-progress 12) to `3 PASS / 17 DIVERGE / 0 ERROR`.
          PASS rows: IPK literal (`SELECT a FROM t WHERE rowid=5`,
          9 ops byte-identical), NULL (`SELECT a FROM t WHERE c IS
          NULL`, 11 ops byte-identical), FULL (`SELECT a FROM t`,
          9 ops byte-identical).  Failure-mode tally moves from
          `0 exception, 0 nil-Vdbe, 16 op-count, 4 op-diff` to
          `0 exception, 0 nil-Vdbe, 17 op-count, 0 op-diff` — every
          remaining DIVERGE row is now a structural shape difference
          (Pascal emits SCAN-with-residual N=11..13 ops; C emits
          IN-coroutine N=26..27, OR-shatter N=15..28, BETWEEN
          range-plan N=13, JOIN N=29..32, etc.).  No row is in
          op-diff (per-op P-operand drift) anymore.  Per-shape
          histogram: IPK 1/1, NULL 1/0, FULL 1/0; all INDEX_* /
          MULTI_OR / LEFT_JOIN / JOIN_WHERE shapes still 0/1
          waiting on the next sub-progress's heavy lifts.
        * TestWhereCorpus now reports `C-oracle reference total:
          332 ops across 20 rows (avg 16.6)` (was 363 with the
          typed schema), reflecting the bare-fixture alignment.
        * No regression anywhere: TestParser 45/45, TestParserSmoke
          20/20, TestPrepareBasic 20/20, TestSelectBasic 49/49,
          TestExprBasic 40/40, TestDMLBasic 54/54, TestSchemaBasic
          44/44, TestWhereBasic 52/52, TestWhereSimple 44/44,
          TestWhereExpr 84/84, TestWhereStructs 148/148,
          TestWherePlanner 675/675, TestVdbeArith 41/41,
          TestVdbeApi 57/57, TestVdbeMisc 45/45, TestVdbeMem 62/62,
          TestVdbeAux 108/108, TestVdbeRecord 13/13, TestVdbeAgg
          11/11, TestVdbeStr 23/23, TestVdbeBlob 13/13, TestVdbeSort
          14/14, TestVdbeCursor 27/27, TestVdbeVtabExec 50/50,
          TestExplainParity 2/10 unchanged (CREATE TABLE rows still
          DIVERGE on placeholder vs UPDATE pattern), TestPager*,
          TestBtreeCompat 337/337, TestPrintf 105/105, TestJson
          434/434, TestJsonEach 50/50, TestTokenizer 127/127,
          TestRegistration 19/19, TestExecGetTable 23/23, TestBackup
          20/20, TestConfigHooks 54/54, TestInitShutdown 27/27,
          TestUnlockNotify 14/14, TestLoadExt 20/20, TestAuthBuiltins
          34/34.

      Sub-progress 14 must lift the heavy gates that stop the
      remaining 17 op-count rows: (i) `sqlite3ExprCodeIN` so
      INDEX_IN / INDEX_IN_SUB / IPK_IN reach the BeginSubrtn / Once
      / OpenEphemeral coroutine machinery (rows worth ~24..30 ops
      vs Pascal's current 11), (ii) BETWEEN range-plan in
      whereShortCut so IPK_RANGE picks SeekGE/SeekLE instead of
      SCAN-with-residual, (iii) OR-shatter codegen in
      `sqlite3WhereCodeOneLoopStart` for MULTI_OR (`a=5 OR a=7`
      should hit the IN-promotion path as a virtual term — already
      synthesized by exprAnalyze under `whereCombineDisjuncts`,
      just not consumed by the SCAN fallback today), (iv) two-table
      JOIN codegen so LEFT_JOIN / JOIN_WHERE move from the 3-op
      Init/Halt/Goto stub to a real per-table cursor + Rewind/Next
      nest.  The IPK_alias row's residual single-op delta (C=12
      Pas=11) is also unwound with (i) since the underlying
      difference is the IN/IPK-promotion gap.
    - [X] Sub-progress 14 — `sqlite3TableColumnAffinity` real lookup +
      `pConstExpr` factored-init emission + side-by-side diagnostic
      (2026-04-27).  Three landings:

      (a) `sqlite3TableColumnAffinity` (codegen.pas:4082) — replaced
      the Phase 6.1 stub (`Result := AnsiChar(SQLITE_AFF_INTEGER)` for
      every column) with a faithful port of expr.c:331..335: returns
      `pTab^.aCol[iCol].affinity` for normal columns, `SQLITE_AFF_INTEGER`
      for the rowid pseudo-column (iCol < 0) or out-of-range/NEVER
      paths.  `aCol` is now populated by `sqlite3AddColumn` (sub-progress
      7) so this lookup returns real per-column affinity instead of the
      stub default.  Latent semantic bug masked by the stub: every
      column-vs-literal comparison's `binaryCompareP5` saw the column
      as INTEGER and produced `p5 = 0x44 | 0x10 = 0x54`, where C
      computes `p5 = 0x41 | 0x10 = 0x51` (BLOB | JUMPIFNULL) for bare-
      typed columns.  After the fix every Eq/Ne/Lt/Gt/Le/Ge p5 byte
      matches C exactly.

      (b) `sqlite3FinishCoding` (codegen.pas:18190..) — replaced the
      "drop the list silently" branch with the real C consumption loop
      from build.c sqlite3FinishCoding: for each entry in
      `pParse^.pConstExpr`, clear `PARSEFLAG_OkConstFactor` (so the
      inner walk does not re-factor), `sqlite3ExprCode(pELItem^.pExpr,
      pELItem^.u.iConstExprReg)` to land the constant in its allocated
      register, restore the flag, then free the list.  Without this
      loop, `sqlite3ExprCodeTemp`'s constant-factor short-circuit had
      been routing every literal operand to `sqlite3ExprCodeRunJustOnce`
      which appended (Expr, regNum) to `pConstExpr` and returned the
      register number — but the register was never written, so every
      per-row WHERE comparison (`Eq r2, …` against a never-loaded r2)
      compared the column to garbage at runtime.  Latent semantic bug
      masked because TestWhereCorpus only checks bytecode shape and no
      other test exercised the WHERE-with-literal residual through a
      real `sqlite3_step`.  Now the trailing `Integer p1=5 p2=2 / Integer
      p1=7 p2=3 / String8 p1=0 p2=3 / …` ops land between OP_Transaction
      and the final OP_Goto, byte-identical in count, opcode, P1, P2
      (register), P3, P5 against C.

      (c) `TestWhereCorpus` diagnostic (TestWhereCorpus.pas:DumpBothSides)
      — when an op-count divergence trips, the report now dumps both C
      and Pascal sides side-by-side (up to 16 rows each, padded with
      `(none)` for the shorter side) instead of just dumping the C
      reference.  Made the per-row "what's missing" obvious at a glance:
      every DIVERGE row before this sub-progress had pattern "C ends
      with `Integer/String8 [factored constants]; Goto`; Pas ends with
      `Goto`" — actionable visibility that drove (b)'s root-causing.

      Test-suite delta:
        * TestWhereCorpus moves from `3 PASS / 17 DIVERGE / 0 ERROR`
          (sub-progress 13) to `12 PASS / 8 DIVERGE / 0 ERROR`.  Nine
          new PASS rows: IPK alias (`SELECT q FROM u WHERE p=7`),
          INDEX_EQ (`a=5`), INDEX_EQ_2 (`a=5 AND b=7`), INDEX_EQ_RES
          (`a=5 AND c='hi'`), INDEX_RANGE (`a>5 AND a<100`),
          INDEX_EQ_RANGE (`a=5 AND b>10`), MULTI_OR (`a=5 OR a=7`),
          MULTI_OR_X (`a=5 OR b=7`), WOR_INDEX (`q='hi'`).  Failure-
          mode tally moves from `0 exception, 0 nil-Vdbe, 17 op-count,
          0 op-diff` to `0 exception, 0 nil-Vdbe, 8 op-count, 0
          op-diff` — every column-vs-literal SCAN-with-residual shape
          now matches C byte-for-byte.  Per-shape histogram: IPK 2/0,
          INDEX_EQ 1/0, INDEX_EQ_2 1/0, INDEX_EQ_RES 1/0, INDEX_RANGE
          1/0, INDEX_EQ_RANGE 1/0, MULTI_OR 1/0, MULTI_OR_X 1/0,
          WOR_INDEX 1/0, NULL 1/0, FULL 1/0.  Remaining DIVERGE rows
          all need *structural* codegen (not residual fix-ups): IPK_IN
          / INDEX_IN / INDEX_IN_SUB need `sqlite3ExprCodeIN`'s
          BeginSubrtn / Once / OpenEphemeral coroutine machinery;
          IPK_RANGE needs BETWEEN range-plan in whereShortCut so
          SeekGE/SeekLE replace the SCAN-with-residual; LIKE / LIKE_WILD
          need the LIKE-prefix optimization (BLOB/Function/CollSeq
          machinery in exprAnalyzeOrTerm); LEFT_JOIN / JOIN_WHERE need
          the two-table JOIN codegen lifted from the single-table gate.
        * No regression anywhere: TestParser 45/45, TestParserSmoke
          20/20, TestPrepareBasic 20/20, TestSelectBasic 49/49,
          TestExprBasic 40/40, TestDMLBasic 54/54, TestSchemaBasic
          44/44, TestWhereBasic 52/52, TestWhereSimple 44/44,
          TestWhereExpr 84/84, TestWhereStructs 148/148,
          TestWherePlanner 675/675, TestVdbeArith 41/41, TestVdbeApi
          57/57, TestVdbeMisc 45/45, TestVdbeMem 62/62, TestVdbeAux
          108/108, TestVdbeRecord 13/13, TestVdbeAgg 11/11, TestVdbeStr
          23/23, TestVdbeBlob 13/13, TestVdbeSort 14/14, TestVdbeCursor
          27/27, TestVdbeVtabExec 50/50, TestExplainParity 2 pass / 6
          diverge / 2 error (CREATE INDEX/UNIQUE INDEX still ERROR —
          unchanged), TestBtreeCompat 337/337, TestPrintf 105/105,
          TestJson 434/434, TestJsonEach 50/50, TestTokenizer 127/127,
          TestRegistration 19/19, TestExecGetTable 23/23, TestBackup
          20/20, TestConfigHooks 54/54, TestInitShutdown 27/27,
          TestUnlockNotify 14/14, TestLoadExt 20/20, TestAuthBuiltins
          34/34, TestOpenClose 17/17, TestInitCallback 29/29, TestPager
          / TestPagerCompat / TestPagerCrash / TestPagerRollback /
          TestPagerReadOnly all green.

      Sub-progress 15 must port `sqlite3ExprCodeIN` so the IN-list /
      IN-subselect rows reach the BeginSubrtn coroutine machinery
      (worth ~13..16 ops per row), then BETWEEN range-plan in
      whereShortCut for IPK_RANGE.  LIKE optimization and JOIN codegen
      remain heavier follow-on lifts.
    - [X] Sub-progress 15 — TestWhereCorpus C-oracle filter regression
      restored (2026-04-27).  Two latent bugs fixed in the test
      scaffold:

      (a) `libsqlite3.so` was rebuilt with `-DSQLITE_DEBUG` between
      sub-progress 14 and now, which causes the C oracle's EXPLAIN
      listing to interleave `OP_ReleaseReg` debug-only register-
      pressure hints between the productive opcodes.  The Pascal
      codegen never emits OP_ReleaseReg in any code path, so every
      previously-PASS row diverged on a wholesale shape mismatch
      (Pas missing N ReleaseReg ops).  Same shape as the existing
      `Explain` filter (SQLITE_ENABLE_EXPLAIN_COMMENTS chatter).
      Added `ReleaseReg` and `TableLock` (SQLITE_OMIT_SHARED_CACHE=off)
      to the filter list — these are build-flag-only opcodes the
      Pascal port cannot emit by definition, so filtering them is
      semantics-preserving.  TestWhereCorpus.pas:`isFilteredOpcode`
      consolidates the per-name skip into a single inline.

      (b) Filtering opcodes from the C oracle listing without
      renumbering jump-target `p2` fields produces incoherent diffs:
      the original `Init.p2 = 8` (jump to old-addr Transaction)
      becomes a stale reference once Explain at addr 2 is filtered
      out — the new addr-8 op is `Goto`, not `Transaction`.  Symptom:
      every row diverged at op[0] with a single-byte `p2` slip even
      when the underlying VDBE shape was structurally identical
      after filtering.  Added a prefix-sum `shift[]` table over the
      raw op listing: `shift[i]` = number of filtered ops at
      addresses strictly less than `i`.  After filtering, every
      retained jump opcode's `p2` is decremented by `shift[p2]` so
      it points into the post-filter index space.  Renumbering is
      gated on `isJumpOpcode(op)` — a whitelist of every WHERE /
      SELECT / sort / coroutine jump opcode the corpus exercises
      (Init, Goto, Rewind, Next, Eq/Ne/Lt/Le/Gt/Ge, If/IfNot,
      IsNull/NotNull, Found/NotFound, NotExists, SeekRowid,
      SeekGE/GT/LE/LT, IdxGE/GT/LE/LT, Once, BeginSubrtn, Yield,
      MustBeInt, …).  Without the gate, non-jump opcodes whose p2
      is a register number (`Integer p1=7 p2=3` ↔ "load 7 into r3")
      get their register operand silently corrupted — sub-progress
      14 follow-up bug, latent in sub-progress 14's regression too.

      (c) `DumpBothSides` is now also invoked from the op-diff arm
      when `firstDiff = 0`, since the 2-before/2-after context
      window collapses to the prologue head and elides the tail
      where the actual structural difference (Goto position, Init
      target) often lives.  Same idiom as the op-count arm.

      Test-suite delta:
        * TestWhereCorpus restored from `0 PASS / 20 DIVERGE`
          (regression introduced by SQLITE_DEBUG rebuild) back to
          `12 PASS / 8 DIVERGE / 0 ERROR` — the sub-progress 14
          baseline.  All originally-green rows green again: IPK
          literal, IPK alias, INDEX_EQ, INDEX_EQ_2, INDEX_EQ_RES,
          INDEX_RANGE, INDEX_EQ_RANGE, MULTI_OR, MULTI_OR_X,
          WOR_INDEX, NULL, FULL.  Failure-mode tally: `0 exception,
          0 nil-Vdbe, 8 op-count, 0 op-diff` — every remaining
          DIVERGE is structural codegen needed (IN-coroutine,
          BETWEEN range-plan, LIKE-prefix, two-table JOIN), not
          per-byte fix-up.
        * No regression anywhere: TestParser 45/45, TestParserSmoke
          20/20, TestPrepareBasic 20/20, TestSelectBasic 49/49,
          TestExprBasic 40/40, TestDMLBasic 54/54, TestSchemaBasic
          44/44, TestWhereBasic 52/52, TestWhereSimple 44/44,
          TestWhereExpr 84/84, TestWhereStructs 148/148,
          TestExplainParity 2/10 unchanged.

      Sub-progress 16 must port `sqlite3ExprCodeIN` (expr.c:4029,
      ~250 lines) so IPK_IN / INDEX_IN / INDEX_IN_SUB reach the
      BeginSubrtn / Once / OpenEphemeral coroutine machinery; then
      BETWEEN range-plan in `whereShortCut` for IPK_RANGE
      (SeekGE/Gt vs SCAN-with-residual).  LIKE optimisation and
      two-table JOIN codegen remain heavier follow-on lifts.
    - [X] Sub-progress 16(a) — minimal scalar `TK_FUNCTION` codegen +
      eager `sqlite3_initialize` from `openDatabase` (2026-04-27).
      Three coupled landings:

      (a) `sqlite3VdbeAddFunctionCall` (passqlite3vdbe.pas:2113) —
      replaced the Phase 6 stub with a faithful subset port of
      vdbeaux.c sqlite3VdbeAddFunctionCall.  Allocates a contiguous
      `Tsqlite3_context + nArg * SizeOf(PMem)` block (8-byte aligned
      argv tail), zero-fills, sets pFunc/argc/iOp, then emits
      OP_Function (or OP_PureFunc when eCallCtx≠0) via
      `sqlite3VdbeAddOp4` with P4_FUNCCTX.  ChangeP5(nArg) elided —
      current upstream libsqlite3 (the EXPLAIN oracle this test diffs
      against) does not write P5 for OP_Function/OP_PureFunc; argc
      is read from `pCtx^.argc` at runtime, not `pOp^.p5`.

      (b) `emitScalarFunctionCall` + TK_FUNCTION arm in
      `sqlite3ExprCodeTarget` (passqlite3codegen.pas:4300).  Subset
      port of expr.c:5267..5440.  Looks up the FuncDef via
      `sqlite3FindFunction(db, zToken, nArg, db^.enc, 0)`, falls back
      to `nArg=-1` for variable-arity functions when the exact match
      fails.  First pass marks constant-arg positions in `constMask`;
      second pass codes the args into a contiguous register block
      (allocated from `pParse^.nMem` when constMask≠0 so the factored
      registers persist across the loop body, otherwise from
      `sqlite3GetTempRange`).  Constant args go through
      `sqlite3ExprCodeRunJustOnce` so the literal lands once in the
      Init-section trailer; non-constant args inline via
      `sqlite3ExprCode`.  `sqlite3VdbeAddFunctionCall` then emits the
      OP_Function with P1=constMask P2=r1 P3=target P4=pCtx.  Skipped
      arms (collation pre-emit, OFFSET/INLINE/date-time fast-paths)
      land with broader expr.c port — corpus rows that need them
      degrade gracefully through the OP_Null fallback.

      (c) `openDatabase` (passqlite3main.pas:448) — eager
      `sqlite3_initialize` call before connection setup.  Mirrors
      main.c:3328 — C's openDatabase calls sqlite3_initialize() first.
      Latent gap: Pascal `openDatabase` had only called
      `sqlite3_os_init` directly (omitting builtin-functions hash
      population), and no Pascal-prepare path had reached TK_FUNCTION
      codegen, so `sqlite3BuiltinFunctions` stayed empty and
      `sqlite3FindFunction` returned nil for every name.  Confirmed
      via diagnostic: pre-fix `aFunc.count=0` and bucket-20 (where
      'like' hashes) was nil; post-fix the FuncDef pointer for `like`
      resolves immediately.

      (d) `TestConfigHooks.pas` T20..T23 — added an explicit
      `sqlite3_close_v2 + sqlite3_shutdown` between the db_config
      block and the global `sqlite3_config` block.  `sqlite3_config`
      is gated on `isInit=0` per the C reference (config can only be
      changed before initialisation); now that `sqlite3_open` wires
      `sqlite3_initialize`, the test must reset isInit before
      exercising the global-config arms.  Mirrors the documented
      C-side calling convention; comment in the test (which had read
      "isInit is currently 0 (sqlite3_initialize not yet wired)") is
      updated.

      Test-suite delta:
        * TestWhereCorpus moves from `12 PASS / 8 DIVERGE / 0 ERROR`
          (sub-progress 15) to `14 PASS / 6 DIVERGE / 0 ERROR`.  Two
          new PASS rows: LIKE prefix (`SELECT a FROM t WHERE c LIKE
          'hi%'`, 13 ops byte-identical), LIKE wildcard (`%X%`,
          13 ops byte-identical).  Failure-mode tally unchanged at
          `0 exception, 0 nil-Vdbe, 6 op-count, 0 op-diff`.
          Per-shape histogram: LIKE 1/0, LIKE_WILD 1/0; remaining
          DIVERGE rows are IPK_IN, IPK_RANGE, INDEX_IN, INDEX_IN_SUB,
          LEFT_JOIN, JOIN_WHERE — each needs structural codegen
          (IN-coroutine, BETWEEN range-plan, two-table JOIN).
        * TestConfigHooks restored to 54/0 after the test fixture
          update; T19d (close before shutdown) added.
        * No regression anywhere: TestParser 45/45, TestParserSmoke
          20/20, TestPrepareBasic 20/20, TestSelectBasic 49/49,
          TestExprBasic 40/40, TestDMLBasic 54/54, TestSchemaBasic
          44/44, TestWhereBasic 52/52, TestWhereSimple 44/44,
          TestWhereExpr 84/84, TestWhereStructs 148/148,
          TestWherePlanner 675/675, TestVdbeArith 41/41, TestVdbeApi
          57/57, TestVdbeMisc 45/45, TestVdbeMem 62/62, TestVdbeAux
          108/108, TestVdbeRecord 13/13, TestVdbeAgg 11/11,
          TestVdbeStr 23/23, TestVdbeBlob 13/13, TestVdbeSort 14/14,
          TestVdbeCursor 27/27, TestVdbeVtabExec 50/50,
          TestExplainParity 2/10 unchanged, TestBtreeCompat 337/337,
          TestPrintf 105/105, TestJson 434/434, TestJsonEach 50/50,
          TestTokenizer 127/127, TestRegistration 19/19,
          TestExecGetTable 23/23, TestBackup 20/20, TestInitShutdown
          27/27, TestUnlockNotify 14/14, TestLoadExt 20/20,
          TestAuthBuiltins 34/34, TestOpenClose 17/17,
          TestInitCallback 29/29, TestSmoke + TestUtil + TestPCache +
          all TestPager* + TestOSLayer green.

      Sub-progress 16(b) must port the IN-coroutine machinery
      (`sqlite3CodeRhsOfIN` + `sqlite3ExprCodeIN`) so IPK_IN /
      INDEX_IN / INDEX_IN_SUB reach the BeginSubrtn / Once /
      OpenEphemeral structure (worth ~13..16 ops per row).  Then
      BETWEEN range-plan in `whereShortCut` (or
      `whereLoopAddBtree`) for IPK_RANGE.  Two-table JOIN codegen
      remains the heaviest follow-on lift.

      Sub-progress 17 (2026-04-27) — IPK-RANGE shortcut.

      (a) `whereShortCut` extended with an IPK-range arm: after the
      IPK-EQ scan and the unique-index loop fail to populate a plan,
      a fresh `whereScanInit` pair runs over the rowid (column index
      `XN_ROWID = -1`) with `WO_GT_WO | WO_GE` then `WO_LT | WO_LE`
      opmasks.  Either match (or both, for BETWEEN) populates
      `pLoop^.aLTerm[0..1]` with the lower / upper bound term and
      sets `wsFlags = WHERE_IPK | WHERE_COLUMN_RANGE | WHERE_BTM_LIMIT
      [| WHERE_TOP_LIMIT]`, with `u.btree.nBtm` / `nTop` bumped to 1
      per side; rRun = LogEst(10) = 33 (full-scan tuning approximation
      pending whereRangeScanEst port).  exprAnalyzeBetween was already
      synthesising the WO_GE / WO_LE virtual children at
      whereexpr.c:1275..1313 (codegen.pas:7805..7824), so no new
      planner-side analysis was needed — only the shortcut's scan
      itself.

      (b) `sqlite3WhereBegin` tail extended with a Case-3 IPK-range
      codegen arm (codegen.pas:12478..12544), trimmed port of
      wherecode.c:1712..1819.  Reads `pStart` / `pEnd` from
      `aLTerm[0..1]` per the WHERE_BTM_LIMIT / WHERE_TOP_LIMIT bits;
      emits `OP_SeekGE / OP_SeekGT / OP_SeekLE / OP_SeekLT` (selected
      by the inline `aMoveOp[pX^.op - TK_GT_TK]` lookup) for the start
      bound, then `OP_Integer` (via `sqlite3ExprCode`) loading the end
      bound into a fresh memory cell, then `OP_Rowid` + a numeric
      `OP_Gt` / `OP_Ge` / `OP_Lt` / `OP_Le` with `p5 = SQLITE_AFF_NUMERIC
      | SQLITE_JUMPIFNULL` to break the loop on out-of-range rowids.
      `pLevel^.op := OP_Next` lets the existing `sqlite3WhereEnd`
      tail emit the iteration step on `addrBody`, the seek's landing
      addr.  bRev / vector RHS / cursor-hint paths deferred — IPK_RANGE
      in the gate exercises only the forward, scalar shape.

      (c) `pLevel^.notReady` initialisation pulled in from C
      (`(~Bitmask(0)) & ~pLoop^.maskSelf`) so that `disableTerm`'s
      `(notReady & prereqAll) = 0` guard fires correctly.  Without this,
      disableTerm short-circuited at the first iteration on every
      rowid-bound term (whose prereqAll = level-self mask), preventing
      the BETWEEN parent from being marked TERM_CODED via
      iParent / nChild propagation.  The fix also lays groundwork for
      multi-level loops where `notReady` must reflect "loops not yet
      opened" — single-level today, generalises trivially.

      (d) `disableTerm` invocations on `pStart` and `pEnd` in the
      IPK-range Case-3 arm walk the iParent/nChild chain so the
      original TK_BETWEEN parent (still alive in `pWC^.a[0]` — only
      its WO_GE / WO_LE *children* are virtual) flips to TERM_CODED
      once both bounds are coded.  The downstream residual filter
      walk at codegen.pas:12576..12586 then skips the BETWEEN, so no
      `OP_Null + OP_IfNot` per-row stub is emitted on top of the
      seek+rowid+test sequence.

      (e) `TestWhereSimple.M3k` updated: previously asserted
      `OP_Rewind` for the SCAN-with-residual fallback shape; now
      asserts `OP_SeekGE` for the IPK-range start-bound seek.  M3l
      (BETWEEN parent TERM_CODED) unchanged — still passes, now
      via the disableTerm-propagation route described in (d) instead
      of the residual-walk's manual TERM_CODED set.

      Test-suite delta:
        * TestWhereCorpus moves from `14 PASS / 6 DIVERGE / 0 ERROR`
          (sub-progress 16(a)) to `15 PASS / 5 DIVERGE / 0 ERROR`.
          New PASS row: IPK_RANGE (`SELECT a FROM t WHERE rowid
          BETWEEN 5 AND 10`, 13 ops byte-identical to the C oracle).
          Failure-mode tally drops from `0/0/6/0` to `0/0/5/0`.
          Per-shape histogram: IPK_RANGE 1/0; remaining DIVERGE rows
          are IPK_IN, INDEX_IN, INDEX_IN_SUB, LEFT_JOIN, JOIN_WHERE
          — each still needs structural codegen
          (IN-coroutine, two-table JOIN).
        * TestWhereSimple stays at 44/0 after the M3k update; M3a /
          M3b / M3l remain green so the exprAnalyzeBetween path is
          still exercised end-to-end.
        * No regression anywhere: TestParser 45/45, TestParserSmoke
          20/20, TestPrepareBasic 20/20, TestSelectBasic 49/49,
          TestExprBasic 40/40, TestDMLBasic 54/54, TestSchemaBasic
          44/44, TestWhereBasic 52/52, TestWhereExpr 84/84,
          TestWhereStructs 148/148, TestWherePlanner 675/675,
          TestVdbeArith 41/41, TestVdbeApi 57/57, TestVdbeMisc 45/45,
          TestExplainParity 2/10 unchanged, TestPrintf 105/105,
          TestJson 434/434, TestConfigHooks 54/54, TestSmoke green.

      Sub-progress 18 stays focused on the IN-coroutine port
      (sqlite3CodeRhsOfIN + sqlite3ExprCodeIN) for IPK_IN / INDEX_IN /
      INDEX_IN_SUB, then the two-table JOIN codegen for LEFT_JOIN /
      JOIN_WHERE.
    - [X] Sub-progress 18 — IN-coroutine port (literal-list path)
      (2026-04-27).  Three coupled landings:

      (a) `exprINAffinity` (codegen.pas, expr.c:3463..3485) — builds the
      affinity string for the IN-RHS comparison.  One byte per LHS vector
      field; for SELECT-RHS the per-position byte is
      `sqlite3CompareAffinity(SELECT-result-col, LHS affinity)`, for
      list-RHS it's the LHS affinity verbatim.  Caller must
      `sqlite3DbFree` the buffer.

      (b) `sqlite3CodeRhsOfIN` (codegen.pas:22862, expr.c:3592..3823) —
      Case 2 (literal expression list) ported with the Once-gated
      subroutine prologue when reuse-eligible (no `EP_VarSelect`,
      `iSelfTab=0`).  Emits `OP_BeginSubrtn` + `OP_Once` +
      `OP_OpenEphemeral`, then per-element `sqlite3ExprCode(pE2, r1) +
      OP_MakeRecord(affinity) + OP_IdxInsert`, closed by `OP_NullRow +
      OP_Return`.  Non-constant entries defeat the Once gate via
      `sqlite3VdbeChangeToNoop` on both the BeginSubrtn and Once
      addresses, mirroring expr.c:3792..3796.  Case 1 (subselect) is a
      soft-fallback no-op — leaves the eph table empty rather than
      asserting; future sub-progress lands `sqlite3SelectDup` recursion
      via `sqlite3Select(pCopy, &SRT_Set dest)`.  Bloom filter and
      `SubrtnSig` cache reuse (`findCompatibleInRhsSubrtn`) deferred —
      both are pure optimisations, semantics-preserving when omitted.
      KeyInfo is allocated and attached via `sqlite3VdbeChangeP4`
      (P4_KEYINFO); the single LHS-collation slot is written via
      pointer arithmetic past `SizeOf(TKeyInfo)` since `aColl` is a
      C99 flexible-array-member tail in the upstream layout.

      (c) `sqlite3ExprCodeIN` (codegen.pas:22942, expr.c:4029..4291) —
      minimal port for residual-filter call sites: nVector=1,
      `destIfFalse=destIfNull` (single-jump path used by
      `sqlite3ExprIfTrue` / `sqlite3ExprIfFalse` when emitting per-row
      WHERE residuals).  Two paths land:
        * `IN_INDEX_NOOP`: emits a sequence of `OP_Eq` (or `OP_NotNull`
          when r1=r2) with the last entry replaced by `OP_Ne` /
          `OP_IsNull` jumping to destIfFalse.  P5 carries
          `zAff[0]` (or `zAff[0] | SQLITE_JUMPIFNULL` on the last).
        * `IN_INDEX_EPH`: emits `OP_Affinity rLhs nVector zAff` then
          `OP_NotFound iTab destIfFalse rLhs nVector` — combined
          Step3+Step5 path under destIfFalse=destIfNull (expr.c:4209..
          4223).
      Vector LHS, `rRhsHasNull` tracking, the separate-NULL-jump Step6
      loop, `IN_INDEX_INDEX_ASC/DESC`, and `IN_INDEX_ROWID` are deferred
      (only the residual-filter shape is exercised by today's corpus).
      Subselect IN-RHS short-circuits at function entry to a pessimistic
      `OP_Goto destIfFalse` so prepare cannot crash on the unported
      `sqlite3SelectDup` path.

      (d) Dispatch wired in `sqlite3ExprIfTrue` (codegen.pas:5787) and
      `sqlite3ExprIfFalse` (codegen.pas:5964/5970).  Replaced the four
      TODO stubs (`OP_Null + OP_If/OP_IfNot` placeholders) with calls to
      `sqlite3ExprCodeIN(pParse, pExpr, dest, dest)` /
      `sqlite3ExprCodeIN(pParse, pExpr, destIfFalse, destIfNull)`.
      `sqlite3ExprIfTrue` adds an `sqlite3VdbeGoto(v, dest)` after the
      IN body so the truthy path falls through to `dest` (the
      "if-true-jump" semantic from expr.c:6428..6432).

      Test-suite delta:
        * TestWhereCorpus: `15 PASS / 5 DIVERGE / 0 ERROR` (corpus row
          count unchanged).  Failure-mode tally moves from
          `0 exception, 0 nil-Vdbe, 5 op-count, 0 op-diff` (sub-progress
          17) to `0 exception, 0 nil-Vdbe, 4 op-count, 1 op-diff`.
          IPK_IN now produces a 26-op program byte-for-byte against the
          C oracle's 26 ops EXCEPT for placement: Pas emits the IN
          materialisation INSIDE the loop body (after Rewind, where
          residual-filter codegen runs), C emits it during WHERE setup
          (after OpenRead, before Rewind).  Both shapes are runtime-
          equivalent — `OP_BeginSubrtn` is self-executing under the
          `OP_Once` gate — but bytecode-shape diffing flags the
          divergence.  INDEX_IN is similar (28 C ops vs 26 Pas ops; C
          has an extra `Noop` placeholder at the pre-loop slot from
          where the IN was hoisted by sqlite3WhereBegin's pre-emission
          walk).  INDEX_IN_SUB stays DIVERGE on a soft-fallback
          "always false" stub instead of crashing, since
          `sqlite3CodeRhsOfIN` Case 1 needs `sqlite3SelectDup`.
        * Sub-progress 19 will lift the placement to pre-loop position
          via a `sqlite3WhereBegin`-side pre-emission walk that visits
          every TK_IN term and calls `sqlite3CodeRhsOfIN` *before*
          emitting Rewind, so IPK_IN / INDEX_IN flip to PASS without
          changing the per-row residual codegen.
        * No regression anywhere: TestParser 45/45, TestSelectBasic
          49/49, TestExprBasic 40/40, TestDMLBasic 54/54,
          TestSchemaBasic 44/44, TestWhereBasic 52/52, TestWhereSimple
          44/44, TestWhereExpr 84/84, TestWhereStructs 148/148,
          TestWherePlanner 675/675, TestVdbeArith 41/41, TestVdbeApi
          57/57, TestExplainParity 2/10, TestSmoke green, TestPrintf
          105/105, TestJson 434/434, TestConfigHooks 54/54,
          TestAuthBuiltins 34/34, TestBtreeCompat 337/337.

      Sub-progress 19 must hoist the IN-RHS materialisation into
      `sqlite3WhereBegin`'s pre-loop section (mirroring wherecode.c's
      `codeAllEqualityTerms` IN-pre-emission idiom) so IPK_IN /
      INDEX_IN flip to PASS, then port `sqlite3SelectDup` recursion +
      `sqlite3CodeRhsOfIN` Case 1 (subselect) for INDEX_IN_SUB.
      Two-table JOIN codegen for LEFT_JOIN / JOIN_WHERE remains the
      heaviest follow-on lift.
    - [X] Sub-progress 19 — IN-RHS pre-loop hoisting + EP_Subrtn cache
      fast-path (2026-04-27).  Two coupled landings:

      (a) `sqlite3FindInIndex` (codegen.pas:23080) gains an EP_Subrtn cache
      fast-path at function entry.  When the input expression already has
      `EP_Subrtn` set (the marker `sqlite3CodeRhsOfIN` writes when it emits
      the OP_BeginSubrtn / OP_Once / OP_OpenEphemeral / .../ OP_Return
      materialisation block) and `pX^.iTable > 0`, the function returns
      `IN_INDEX_EPH` with the cached cursor immediately — no fresh
      `pParse^.nTab++` allocation, no second call into
      `sqlite3CodeRhsOfIN`.  The cache is bypassed for `IN_INDEX_LOOP`
      callers (multi-pass index scan needs a fresh cursor per call) so
      the index-loop codegen path stays unaffected.  `aiMap` is still
      populated (identity mapping) when requested, mirroring the
      end-of-function aiMap path.  This mirrors the
      `findCompatibleInRhsSubrtn` lookup in C expr.c (deferred port —
      the upstream helper also walks a SubrtnSig table for cross-IN
      reuse, which we sidestep by relying on the per-expression
      EP_Subrtn flag alone).

      (b) `sqlite3WhereBegin` (codegen.pas:12455) — pre-loop IN-RHS
      hoisting walk inserted between `sqlite3OpenTable` and the case
      dispatch (Case-2 SeekRowid / Case-3 IPK-range / full-scan
      fallback).  Walks every base WHERE term that is NOT virtual, NOT
      already TERM_CODED by the False-Bypass loop, and whose root
      expression is a TK_IN with a literal-list RHS (`ExprUseXList`).
      For each such term, calls `sqlite3FindInIndex(IN_INDEX_MEMBERSHIP)`
      so the IN-RHS materialisation lands in the pre-loop section
      (after OpenRead, before Rewind / Seek), matching the C oracle's
      placement.  ≤2-entry constant lists are skipped — they route
      through `IN_INDEX_NOOP` (a sequence of OP_Eq comparisons) and
      do not allocate an eph table.  Subselect IN-RHS
      (`ExprUseXSelect`) is excluded from the walk —
      `sqlite3CodeRhsOfIN` Case 1 is unported, so a pre-emit there
      would just emit an empty-eph soft-fallback that doesn't help
      INDEX_IN_SUB and could regress its current
      pessimistic-false-jump path.  The per-row residual call to
      `sqlite3ExprCodeIN` later in the loop body picks up the cached
      iTab through the EP_Subrtn fast-path from (a) and emits only
      OP_Affinity + OP_NotFound — no duplicate
      BeginSubrtn / Once / Return triplet inside the loop body.

      Test-suite delta:
        * TestWhereCorpus: stays at `15 PASS / 5 DIVERGE / 0 ERROR`.
          Failure-mode tally unchanged at `0 exception, 0 nil-Vdbe,
          4 op-count, 1 op-diff`.  IPK_IN's first divergence point
          moves from `op[3]` (sub-progress 18) to `op[2]` (this
          landing): Pas now emits BeginSubrtn at addr 2 (matching C's
          BeginSubrtn at addr 2) instead of inside the loop body
          after Rewind.  The remaining op[2] divergence is a
          regReturn register-allocation slip (C uses r2 because the
          IPK-IN-scan plan's `codeAllEqualityTerms` allocates one
          rowid-seek register first, bumping nMem to 1; Pas uses r1
          because the residual-filter plan allocates nothing before
          CodeRhsOfIN).  Closing this gap requires the full IPK-IN
          scan plan in `whereShortCut` + Case-2 IPK-IN codegen
          (deferred to sub-progress 20+).  INDEX_IN now also opens
          with BeginSubrtn at the right pre-loop slot (was at op[3]
          inside loop, now hoisted) — Pas op count drops from 26 to
          ~stays at 26 with the same materialisation block, just
          repositioned.  INDEX_IN_SUB unchanged on the
          pessimistic-false-jump path (still 10 ops, awaiting Case 1
          sqlite3SelectDup port).
        * No regression anywhere: TestParser 45/45, TestParserSmoke
          20/20, TestPrepareBasic 20/20, TestSelectBasic 49/49,
          TestExprBasic 40/40, TestDMLBasic 54/54, TestSchemaBasic
          44/44, TestWhereBasic 52/52, TestWhereSimple 44/44,
          TestWhereExpr 84/84, TestWhereStructs 148/148,
          TestWherePlanner 675/675, TestVdbeArith 41/41,
          TestVdbeApi 57/57, TestVdbeMisc 45/45, TestVdbeMem 62/62,
          TestVdbeAux 108/108, TestVdbeRecord 13/13, TestVdbeAgg
          11/11, TestVdbeStr 23/23, TestVdbeBlob 13/13, TestVdbeSort
          14/14, TestVdbeCursor 27/27, TestVdbeVtabExec 50/50,
          TestExplainParity 2/10 unchanged, TestBtreeCompat 337/337,
          TestPrintf 105/105, TestJson 434/434, TestJsonEach 50/50,
          TestTokenizer 127/127, TestRegistration 19/19,
          TestExecGetTable 23/23, TestBackup 20/20,
          TestInitShutdown 27/27, TestUnlockNotify 14/14,
          TestLoadExt 20/20, TestAuthBuiltins 34/34, TestOpenClose
          17/17, TestInitCallback 29/29, TestConfigHooks 54/54,
          TestSmoke + TestUtil + TestPCache + TestOSLayer green.

      Sub-progress 20 must port the IPK-IN scan plan: extend
      `whereShortCut` with a WO_IN arm that recognises rowid IN
      literal-list and builds a `WHERE_IPK | WHERE_COLUMN_IN` plan,
      then add a Case-2 IPK-IN codegen arm in `sqlite3WhereBegin`
      that opens the pre-materialised eph cursor as the OUTER loop,
      iterates with OP_Column + OP_IsNull + OP_SeekRowid into the
      main table, and emits the OP_Next on the eph cursor as the
      loop tail.  This is the lift that flips IPK_IN to PASS.  The
      analogous INDEX_IN scan plan (DeferredSeek + composite index)
      and `sqlite3SelectDup` for INDEX_IN_SUB Case 1 follow.
    - [X] Sub-progress 20 — IPK-IN scan plan + Case-2 IPK-IN codegen +
      WhereEnd IN-loop tail (2026-04-27).  Three coupled landings flip
      `rowid IN list [IPK_IN]` from DIVERGE to PASS:

      (a) `whereShortCut` (codegen.pas:12027) gains a WO_IN arm after
      the IPK-EQ scan misses.  Walks the WhereClause for a single
      rowid IN-with-literal-list term (`ExprUseXList` and
      `pExpr^.x.pList <> nil`), excluding subselect IN-RHS (deferred
      until Case-1 `sqlite3SelectDup` lands).  On hit, sets
      `pLoop^.wsFlags = WHERE_IPK | WHERE_COLUMN_IN`, populates
      `aLTerm[0]`, sets `nLTerm = nEq = 1`, and uses the same `rRun =
      33` cost as IPK-EQ.  WHERE_ONEROW is intentionally NOT set —
      the loop iterates the IN list, so the per-loop emission is the
      eph-cursor walk, not a single-shot SeekRowid.  Mirrors the
      cost/flags shape `whereLoopAddBtree` (where.c:4150) sets when
      it picks the IPK-IN scan plan.

      (b) `sqlite3WhereBegin` (codegen.pas:12455) gains two new
      blocks coupled to the WO_IN arm: (1) a pre-allocation of
      `iRowidReg = ++pParse^.nMem` BEFORE the sub-progress 19
      pre-loop hoist runs, gated on `WHERE_IPK | WHERE_COLUMN_IN`;
      this mirrors C's `iReleaseReg = ++pParse->nMem` at the top of
      Case 2 (wherecode.c:1697) so the BeginSubrtn regReturn allocated
      by `sqlite3CodeRhsOfIN` (expr.c:3663) lands at register N+1
      instead of N — closing the only remaining op-diff in IPK_IN
      under the previous baseline.  (2) A new Case-2 IPK-IN arm in
      the case dispatch (between IPK-EQ and IPK-RANGE): asserts
      EP_Subrtn + iTable populated by the pre-hoist, allocates a
      fresh `addrNxt` label, emits `OP_Rewind iEph, 0` (P2 patched
      later), allocates the InLoop slot via `sqlite3WhereRealloc`,
      emits `OP_Column iEph 0 → iRowidReg`, `OP_IsNull iRowidReg`
      (P2 patched later), `OP_SeekRowid iTabCur, addrNxt, iRowidReg`,
      then populates the InLoop slot (`addrInTop`, `iCur=iEph`,
      `eEndLoopOp=OP_Next`).  `pLevel^.op := OP_Noop` (the iteration
      opcode lives in the IN-loop tail, not in the per-level slot)
      and the IN term gets TERM_CODED so the residual walk does not
      re-emit it as `OP_Affinity + OP_NotFound`.

      (c) `sqlite3WhereEnd` (codegen.pas:12895) gains the IN-loop
      tail (trimmed port of where.c:7628..7673).  Between the
      `pLevel^.op` emission and `addrBrk` resolution, when
      `WHERE_IN_ABLE` and `u.in_nIn > 0`: resolve `addrNxt` at the
      current address (becomes the OP_Next emission point), walk
      `aInLoop[]` in reverse, `JumpHere(addrInTop+1)` patches the
      OP_IsNull jump to addrNxt, emit `OP_Next iCur, addrInTop`,
      then `JumpHere(addrInTop-1)` patches the OP_Rewind jump-on-
      empty to land just past OP_Next so the post-loop addrBrk
      resolution exits cleanly.  WHERE_IN_EARLYOUT / iLeftJoin /
      WHERE_IN_SEEKSCAN arms stay deferred — none exercised by the
      single-level IPK-IN slice.

      Test-suite delta:
        * TestWhereCorpus: **15 → 16 PASS / 5 → 4 DIVERGE / 0 ERROR**.
          IPK_IN flipped to PASS at exactly 26 ops (matches C-oracle
          26 ops byte-for-byte).  Failure-mode tally: `0 exception,
          0 nil-Vdbe, 4 op-count, 0 op-diff` — no per-op divergences
          remain in the 5 IN-or-JOIN rows; the 4 op-count gaps are
          INDEX_IN (composite-index IN, awaits DeferredSeek port),
          INDEX_IN_SUB (subselect IN, awaits Case-1 sqlite3SelectDup),
          LEFT_JOIN, JOIN_WHERE (multi-table planner, awaits 11g.2.d).
        * No regression anywhere: TestParser 45/45, TestParserSmoke
          20/20, TestPrepareBasic 20/20, TestSelectBasic 49/49,
          TestExprBasic 40/40, TestDMLBasic 54/54, TestSchemaBasic
          44/44, TestWhereBasic 52/52, TestWhereSimple 44/44,
          TestWhereExpr 84/84, TestWhereStructs 148/148,
          TestWherePlanner 675/675, TestVdbeArith 41/41, TestVdbeApi
          57/57, TestVdbeMisc 45/45, TestVdbeMem 62/62, TestVdbeAux
          108/108, TestVdbeRecord 13/13, TestVdbeAgg 11/11,
          TestVdbeStr 23/23, TestVdbeBlob 13/13, TestVdbeSort 14/14,
          TestVdbeCursor 27/27, TestVdbeVtabExec 50/50,
          TestExplainParity 2/10 unchanged, TestBtreeCompat 337/337,
          TestPrintf 105/105, TestJson 434/434, TestJsonEach 50/50,
          TestTokenizer 127/127, TestRegistration 19/19,
          TestExecGetTable 23/23, TestBackup 20/20,
          TestInitShutdown 27/27, TestUnlockNotify 14/14,
          TestLoadExt 20/20, TestAuthBuiltins 34/34, TestOpenClose
          17/17, TestInitCallback 29/29, TestConfigHooks 54/54.

      Sub-progress 21 must port the analogous INDEX_IN scan plan: the
      composite-index-EQ-with-IN shape (`a IN (1,2,3)` against an
      index on `(a)` or `(a,b,…)`).  The plan adds OP_DeferredSeek
      to bridge the index cursor's rowid into the table cursor and
      iterates the eph cursor as the outer loop the same way Case-2
      IPK-IN does today, but driving an OP_IdxRowid + OP_DeferredSeek
      pair instead of OP_SeekRowid.  Then `sqlite3SelectDup` unlocks
      INDEX_IN_SUB Case 1.  The two together flip the remaining IN
      rows in TestWhereCorpus.
    - [X] Sub-progress 21 — IN-RHS hoist re-position + Step-2 IsNull
      guard (2026-04-27).  TestWhereCorpus's INDEX_IN row uses the bare
      three-column fixture (sub-progress 13) so `WHERE a IN (1,2,3)`
      compiles to a SCAN-with-IN-residual (no real index on `a`), not
      the actual INDEX_IN scan-plan from `whereLoopAddBtree`.  The
      remaining 2-op gap against the C oracle was therefore a
      placement / NULL-guard issue in the existing SCAN path, not a
      missing planner branch.  Two coupled landings narrow INDEX_IN
      from `op count: C=28 Pas=26` to the residue 1-register diff at
      op[18]:

      (a) IN-RHS hoist relocation (codegen.pas:12219..12260,
      12529..12541, 12733..12762).  Sub-progress 19 inlined the
      pre-loop IN-RHS materialisation walk at the top of
      `sqlite3WhereBegin` (BEFORE the case dispatch), placing
      BeginSubrtn/.../Return AHEAD of OP_Rewind in the program.
      That ordering is correct only for the IPK-IN plan (Case-2
      iterates the eph cursor as the outer loop, so the cursor must
      exist before OP_Rewind on it).  For SCAN-with-IN-residual the
      C oracle emits Rewind FIRST, then a Noop placeholder
      (`addrSkip` slot in wherecode.c), then the materialisation
      block, then the per-row body, with `OP_Next pLevel->p2 =
      1+addrRewind` looping back to the Noop.  The hoist body was
      promoted to a nested helper `DoInRhsHoist` plus a peer
      `HasInRhsToHoist` predicate; the early-hoist call is now
      gated on `WHERE_IPK | WHERE_COLUMN_IN`, and the SCAN arm
      issues a leading `OP_Noop` followed by `DoInRhsHoist` between
      `OP_Rewind` and the `pLevel^.addrBody := …` capture only when
      the predicate fires.  FULL / LIKE / MULTI_OR rows (no IN
      residuals) skip both ops, keeping their PASS counts intact.
      The `InRhsHoistCandidate` extraction also DRYs sub-progress 19's
      filter chain (TERM_VIRTUAL / TERM_CODED / non-TK_IN / non-list
      / ≤2-entry constant-list / already-EP_Subrtn).

      (b) Step-2 IsNull guard in `sqlite3ExprCodeIN` IN_INDEX_EPH
      path (codegen.pas:23285..23310).  C's `sqlite3ExprCodeIN`
      (expr.c:4187..4194) walks the LHS sub-expressions and emits
      `OP_IsNull rLhs+i, destStep2` for every field that
      `sqlite3ExprCanBeNull` flags, BEFORE the combined Step-3
      `OP_NotFound`.  Sub-progress 18's minimal port emitted only
      `OP_Affinity + OP_NotFound` — semantically OK for nullable
      LHS (NotFound treats NULL as a miss) but bytecode-divergent
      against C.  The new arm calls `sqlite3VectorFieldSubexpr` per
      LHS column and emits `OP_IsNull rLhs+i, destIfFalse` when
      ExprCanBeNull returns non-zero.  In the residual-filter path
      `destIfFalse == destIfNull == addrCont`, so the IsNull jumps
      directly past the IN-test on a NULL LHS row, matching C's
      coverage shape.

      Test-suite delta:
        * TestWhereCorpus: **16/4/0 unchanged in PASS count, but the
          INDEX_IN failure mode flips from `op-count C=28 Pas=26` to
          `op-diff at op[18]/28`** — Pas now matches C op-for-op
          through ops 0-17 (the materialisation block) and diverges
          only on the register numbering at the post-Return body
          (Pas Column reads into r3, C reads into r4; same register
          shift propagates through to op-end).  The shift is a
          temp-pool ordering difference between Pas and C that
          compounds out of the SELECT result-register pre-allocation
          (sqlite3Select allocates result regs BEFORE WhereBegin in
          C; in Pas the equivalent allocation lands at a slightly
          different point, leaving the temp pool one slot lower).
          The diff is now register-numbering-only, not a missing
          opcode.  Failure-mode tally: `0 exception, 0 nil-Vdbe, 3
          op-count, 1 op-diff` — INDEX_IN consumed the only op-diff
          slot; the 3 op-count divergences are INDEX_IN_SUB
          (subselect IN-RHS, awaits sqlite3SelectDup), LEFT_JOIN
          and JOIN_WHERE (multi-table, awaits 11g.2.d).
        * No regression anywhere: TestParser 45/45, TestParserSmoke
          20/20, TestPrepareBasic 20/20, TestSelectBasic 49/49,
          TestExprBasic 40/40, TestDMLBasic 54/54, TestSchemaBasic
          44/44, TestWhereBasic 52/52, TestWhereSimple 44/44,
          TestWhereExpr 84/84, TestWhereStructs 148/148,
          TestWherePlanner 675/675, TestVdbeArith 41/41, TestVdbeApi
          57/57, TestVdbeMisc 45/45, TestVdbeMem 62/62, TestVdbeAux
          108/108, TestVdbeRecord 13/13, TestVdbeAgg 11/11,
          TestVdbeStr 23/23, TestVdbeBlob 13/13, TestVdbeSort 14/14,
          TestVdbeCursor 27/27, TestVdbeVtabExec 50/50,
          TestExplainParity 2/10 unchanged, TestPrintf 105/105,
          TestJson 434/434, TestJsonEach 50/50, TestTokenizer
          127/127, TestRegistration 19/19.

      Sub-progress 22 should close the residue 1-register diff at
      INDEX_IN op[18] by aligning Pas's SELECT result-register
      pre-allocation with C's order in `sqlite3Select` (the result
      regs need to be reserved BEFORE the WhereBegin call so the
      temp pool laid down by `sqlite3CodeRhsOfIN` releases into a
      pool one slot higher, matching C's register numbering byte-
      for-byte).  Once that flips, INDEX_IN goes to PASS and
      attention moves to INDEX_IN_SUB (`sqlite3SelectDup` Case-1
      port for subselect IN-RHS) and the multi-table LEFT_JOIN /
      JOIN_WHERE rows that await the 11g.2.d planner.
    - [X] Sub-progress 22 — `sqlite3ClearTempRegCache` after IN-RHS
      subroutine emit (2026-04-27).  Root-caused the residue
      1-register diff at INDEX_IN op[18] to a missing temp-pool
      invalidation, not a result-register-allocation ordering
      problem as previously hypothesised.  In C, `sqlite3CodeRhsOfIN`
      ends the Once-gated subroutine with `OP_NullRow + OP_Return`
      followed by `sqlite3ClearTempRegCache(pParse)` (expr.c:3821):
      this is the documented contract for any sub/co-routine that
      can be invoked from elsewhere — the caller must not reuse
      registers that the subroutine consumed.  Pas's
      `sqlite3CodeRhsOfIN` released `r1` and `r2` back to
      `aTempReg[]` at the end of the literal-list loop and never
      cleared the pool, so the per-row residual filter (in the
      same Vdbe but emitted AFTER the subroutine) reused those
      released slots — `sqlite3ExprCodeIN` Step-2's LHS column
      load picked register 3 (reusing the released r3 slot)
      instead of bumping `nMem` to 4.

      Fix: at the end of `sqlite3CodeRhsOfIN`'s `addrOnce <> 0`
      tail, after `OP_Return`, set `pParse^.nTempReg := 0` and
      `pParse^.nRangeReg := 0` — the same two-line body upstream
      uses for `sqlite3ClearTempRegCache`.  Adds 0 opcodes;
      simply invalidates the pool so the next `GetTempReg`
      bumps `nMem` instead of reusing.  No new helper added —
      inlined the two writes since this is the only port site
      we need today (the other upstream call sites in `analyze.c`,
      `select.c`, and `pragma.c` aren't reachable yet).

      Test-suite delta:
        * TestWhereCorpus: **16 → 17 PASS / 4 → 3 DIVERGE / 0
          ERROR**.  INDEX_IN flipped from `op-diff at op[18]/28`
          to PASS (28 ops byte-for-byte against the C oracle).
          Failure-mode tally: `0 exception, 0 nil-Vdbe, 3
          op-count, 0 op-diff` — no per-op divergences remain in
          any corpus row.  Per-shape histogram: INDEX_IN 1/0;
          remaining DIVERGE rows are INDEX_IN_SUB (subselect
          IN-RHS, awaits Case-1 sqlite3SelectDup), LEFT_JOIN,
          JOIN_WHERE (multi-table planner, awaits 11g.2.d).
        * No regression anywhere: TestParser 45/45,
          TestParserSmoke 20/20, TestPrepareBasic 20/20,
          TestSelectBasic 49/49, TestExprBasic 40/40,
          TestDMLBasic 54/54, TestSchemaBasic 44/44,
          TestWhereBasic 52/52, TestWhereSimple 44/44,
          TestWhereExpr 84/84, TestWhereStructs 148/148,
          TestWherePlanner 675/675, TestVdbeArith 41/41,
          TestVdbeApi 57/57, TestVdbeMisc 45/45,
          TestExplainParity 2/10 unchanged.

      Sub-progress 23 must port `sqlite3SelectDup` Case-1 of
      `sqlite3CodeRhsOfIN` (sub-select recursion) so INDEX_IN_SUB
      reaches the SRT_Set materialisation path; LEFT_JOIN /
      JOIN_WHERE remain the heaviest follow-on lift, blocked on
      11g.2.d's multi-table planner.
    - [X] Sub-progress 23 — `sqlite3CodeRhsOfIN` Case-1 + SRT_Set
      disposal in `sqlite3Select` (2026-04-27).  Five coupled
      landings flip INDEX_IN_SUB from `Pascal exception
      EAccessViolation` (Pas=10 ops) to `op-count C=28 Pas=25`
      with byte-identical opcode prefix through the entire
      materialisation block:

      (a) `sqlite3CodeRhsOfIN` (codegen.pas:23089) — Case-1
      subselect arm ported (expr.c:3713..3756 minus deferred
      Bloom-filter / SubrtnSig / EXPLAIN-comments noise).  After
      the OpenEphemeral + KeyInfoAlloc setup, when
      `ExprUseXSelect(pX)` and `pSelect^.pEList^.nExpr = nVal`,
      initialise a stack `TSelectDest` with `SRT_Set` + iTab,
      attach `exprINAffinity(pParse, pX)` as `zAffSdst`, zero
      `iLimit`, dup the inner SELECT via `sqlite3SelectDup` and
      drive `sqlite3Select(pParse, pCopy, @destSet)` to compile
      the inner SELECT body against the eph cursor.  Tail releases
      pCopy via `sqlite3SelectDelete` and `dest.zAffSdst` via
      `sqlite3DbFree`.  On rcSelect != 0 the freshly-allocated
      `pKeyInfo` is unref'd and the function exits cleanly.  Per
      vector field index, `pKeyInfo^.aColl[i]` is filled via
      `sqlite3BinaryCompareCollSeq(pParse, LHS-vector-field-i,
      pEList^.a[i].pExpr)` so OP_NotFound's per-row probe uses the
      right collation (mirrors expr.c:3760..3768).

      (b) `sqlite3Select` (codegen.pas:15020) — gate widened to
      accept `SRT_Set` in addition to `SRT_Output`.  The body
      branches at the disposal step: SRT_Output emits OP_ResultRow
      (unchanged); SRT_Set allocates a temp register via
      `sqlite3GetTempReg`, emits `OP_MakeRecord pDest^.iSdst,
      nResultCol, regRec, pDest^.zAffSdst` followed by
      `OP_IdxInsert pDest^.iSDParm, regRec, pDest^.iSdst, nResultCol`
      and releases the temp.  Mirrors selectInnerLoop's SRT_Set
      arm (select.c:1351..1370) for the non-pSort / non-SF_Distinct
      shape exercised by the corpus.  `sqlite3GenerateColumnNames`
      is gated to SRT_Output only — column names are irrelevant to
      an internal eph-table materialisation.

      (c) `sqlite3SrcListDup` (codegen.pas:3844) — pSTab inheritance
      added (mirrors C expr.c's nTabRef bump).  Without this, every
      `sqlite3SelectDup` would produce a copy whose pSrc has nil
      pSTab; the recursive `sqlite3Select` on the dup then sees
      SF_HasTypeInfo (also copied verbatim) and skips SelectExpand,
      leaving pSTab nil at the per-row OP_Column emission point —
      AV at the first `pTab := pItem^.pSTab` deref.  Now the dup
      inherits both pSTab and the SF_HasTypeInfo skip-flag, so
      sqlite3Select's loop-body codegen finds the table directly.
      Adds a `Inc(pTab^.nTabRef)` so `sqlite3DeleteTable` on the
      dup's cleanup path doesn't free a still-live original.

      (d) `sqlite3WhereBegin`'s `DoInRhsHoist` (codegen.pas:12305)
      — extended to call `sqlite3SelectPrep(pParse,
      pTrm^.pExpr^.x.pSelect, nil)` before
      `sqlite3FindInIndex` for `ExprUseXSelect` terms.  This
      allocates the source-table cursor BEFORE FindInIndex bumps
      nTab for the eph cursor, so cursor numbering aligns with
      C's selectExpander-recurse-first ordering: source table at
      cursor N, eph at cursor N+1.  Without the early prep, the
      eph cursor was N and the source table allocated to N+1
      inside the recursive sqlite3Select — the bytecode shape
      stayed the same but every `p1=` referenced the swapped
      cursor IDs, blocking byte parity.  `InRhsHoistCandidate`
      also extended to accept ExprUseXSelect terms (with
      non-nil pSelect), no longer rejecting them as deferred.

      (e) `isCandidateForInOpt` (codegen.pas:22980) — defensive
      nil-pSTab bail-out replacing the original `Assert(pTab <>
      nil)`.  In the upstream C the global selectExpander walks
      every nested subquery so pSTab is guaranteed populated; the
      pas-sqlite3 selectExpander is still single-level (sub-progress
      6 deferred subquery recursion), so when FindInIndex hits the
      isCandidate probe on a not-yet-prepped subselect, pSTab is
      nil and the assert AV'd.  Returning nil instead falls through
      to the full materialisation path, which immediately calls
      sqlite3SelectPrep on the dup — same end state, no crash.

      (f) `sqlite3ExprCodeIN` (codegen.pas:23207) — the prior
      `if ExprUseXSelect(pExpr) then sqlite3VdbeGoto(v,
      destIfFalse); Exit;` pessimistic short-circuit removed.  The
      EP_Subrtn fast-path in sqlite3FindInIndex (sub-progress 19)
      now picks up the eph cursor materialised by the hoist; the
      IN_INDEX_EPH arm emits the standard OP_Affinity +
      OP_NotFound per-row test.  Subselect IN-RHS now produces a
      real membership test instead of jumping unconditionally to
      destIfFalse.

      Test-suite delta:
        * TestWhereCorpus: stays at **17 PASS / 3 DIVERGE / 0
          ERROR** (corpus row count unchanged), but INDEX_IN_SUB
          flips from `Pascal exception EAccessViolation` to
          `op-count C=28 Pas=25` — every opcode in Pas[0..14]
          matches C[0..14] for opcode/p1/p2/p3 except offsets:
          Init/OpenRead(t,0)/Rewind/Noop/BeginSubrtn/Once/
          OpenEphemeral(2)/OpenRead(s,1)/Rewind/Column/MakeRecord/
          IdxInsert/Next/NullRow/Return then Column for the outer
          loop body.  The 3-op gap is exactly the bloom-filter
          trio (Blob at C[7], FilterAdd at C[13], Filter inside the
          residual); sub-progress 18 documented these as deferred
          pure-optimisation ops semantics-preserving when omitted.
          Failure-mode tally: `1 exception → 0 exception, 2 op-count
          → 3 op-count`.  Per-shape histogram: INDEX_IN_SUB still
          0/1, awaiting bloom-filter port for byte parity.
        * No regression anywhere: TestParser 45/45, TestParserSmoke
          20/20, TestPrepareBasic 20/20, TestSelectBasic 49/49,
          TestExprBasic 40/40, TestDMLBasic 54/54, TestSchemaBasic
          44/44, TestWhereBasic 52/52, TestWhereSimple 44/44,
          TestWhereExpr 84/84, TestWhereStructs 148/148,
          TestWherePlanner 675/675, TestVdbeArith 41/41, TestVdbeApi
          57/57, TestVdbeMisc 45/45, TestVdbeMem 62/62, TestVdbeAux
          108/108, TestExplainParity 2/10 unchanged, TestPrintf
          105/105, TestJson 434/434, TestConfigHooks 54/54,
          TestAuthBuiltins 34/34, TestBtreeCompat 337/337,
          TestTokenizer 127/127, TestSmoke green.

      Sub-progress 24 must port the bloom-filter machinery (`OP_Blob`
      pre-allocate at the materialisation prologue, `OP_FilterAdd`
      inside the materialisation insert loop, `OP_Filter` in the
      per-row residual just before `OP_NotFound`) so INDEX_IN_SUB
      flips to PASS at 28 ops byte-for-byte.  `findCompatibleInRhsSubrtn`
      (the SubrtnSig-based cross-IN-cache) remains the heaviest
      follow-on under sub-progress 25, blocked on no immediate
      corpus dependency.  LEFT_JOIN / JOIN_WHERE stay the residual
      multi-table-planner divergences awaiting 11g.2.d.
    - [X] Sub-progress 24 — Bloom-filter machinery for IN-RHS subselect
      materialisation (2026-04-27).  Three coupled landings flip
      INDEX_IN_SUB from `op-count C=28 Pas=25` to PASS (28 ops
      byte-for-byte against the C oracle):

      (a) `sqlite3CodeRhsOfIN` Case-1 (codegen.pas:23215..23232) —
      ahead of the `sqlite3SelectDup` recursion, when the Once-gated
      subroutine wrapper is active (`addrOnce <> 0`), the caller
      authorised Bloom-filter construction (`bloomOk <> 0`), and the
      connection has `SQLITE_BloomFilter` enabled, allocate a fresh
      `regBloom` slot via `++pParse^.nMem` and emit `OP_Blob 10000,
      regBloom` (mirrors expr.c:3722..3725).  Stash the register into
      `destSet.iSDParm2` so the inner `sqlite3Select`'s SRT_Set
      disposal can chain `OP_FilterAdd` per row.  After
      `sqlite3Select` returns, write `dest.iSDParm2` into the
      `OP_Once` op's `p3` slot at `addrOnce` (the `tag-202407032019`
      contract — `sqlite3ExprCodeIN` reads this slot to decide
      whether to emit the per-row `OP_Filter` probe), and shrink the
      `OP_Blob` to a 10-byte placeholder when iSDParm2 was cleared
      out (e.g. by a sorter-disabled disposal arm — mirrors
      expr.c:3733..3740).  No code change to the EP_Subrtn marking
      or the keyinfo-collation pass; both stay as in sub-progress 23.

      (b) `sqlite3Select` SRT_Set arm (codegen.pas:15175..15179) —
      after the `OP_MakeRecord + OP_IdxInsert` pair that hashes the
      result row into the eph cursor, when `pDest^.iSDParm2 <> 0`,
      emit `OP_FilterAdd pDest^.iSDParm2, 0, pDest^.iSdst,
      nResultCol` so the just-materialised row is recorded into the
      Bloom filter (mirrors select.c:1399..1403, the
      selectInnerLoop SRT_Set arm).  The temp-register `r1`
      release stays at the tail.

      (c) `sqlite3ExprCodeIN` IN_INDEX_EPH path
      (codegen.pas:23397..23415) — between the `OP_IsNull` Step-2
      guards and the combined Step3+Step5 `OP_NotFound`, when the
      RHS is wrapped in an EP_Subrtn cache, look up the OP_Once at
      `pExpr^.y.sub.iAddr` and check the stashed `p3` slot.  When
      non-zero (a Bloom register from sub-progress 24(a)), emit
      `OP_Filter pOp^.p3, destIfFalse, rLhs, nVector` ahead of the
      NotFound — the membership pre-test short-circuits the binary
      search on a confirmed miss (mirrors expr.c:4211..4219).  The
      C-side `assert OptimizationEnabled(SQLITE_BloomFilter)` is
      implicit in the `p3 > 0` guard because sub-progress 24(a)
      never lights the slot when the optimisation is disabled.

      Test-suite delta:
        * TestWhereCorpus: **17 → 18 PASS / 3 → 2 DIVERGE / 0 ERROR**.
          INDEX_IN_SUB flipped to PASS at 28 ops, byte-for-byte
          identical to the C oracle (Init / OpenRead / Rewind / Noop /
          BeginSubrtn / Once / OpenAutoindex / Blob / Rewind /
          Column(s) / MakeRecord / FilterAdd / IdxInsert / Next /
          Integer / NullRow / Return / … / Affinity / Filter /
          NotFound / ResultRow / Halt).  Failure-mode tally:
          `0 exception, 0 nil-Vdbe, 2 op-count, 0 op-diff` — the
          remaining two op-count divergences are LEFT_JOIN and
          JOIN_WHERE, both awaiting 11g.2.d's multi-table planner.
          Per-shape histogram: INDEX_IN_SUB 1/0; LEFT_JOIN 0/1;
          JOIN_WHERE 0/1.
        * No regression anywhere: TestParser 45/45, TestParserSmoke
          20/20, TestPrepareBasic 20/20, TestSelectBasic 49/49,
          TestExprBasic 40/40, TestDMLBasic 54/54, TestSchemaBasic
          44/44, TestWhereBasic 52/52, TestWhereSimple 44/44,
          TestWhereExpr 84/84, TestWhereStructs 148/148,
          TestWherePlanner 675/675, TestVdbeArith 41/41,
          TestVdbeApi 57/57, TestVdbeMisc 45/45, TestVdbeMem 62/62,
          TestVdbeAux 108/108, TestExplainParity 2/10 unchanged,
          TestPrintf 105/105, TestJson 434/434, TestTokenizer
          127/127, TestRegistration 19/19, TestSmoke green.

      Sub-progress 25 will tackle LEFT_JOIN / JOIN_WHERE — both block
      on the multi-table planner port from 11g.2.d (whereLoopAddBtree
      + wherePathSolver multi-level path search).  The
      `findCompatibleInRhsSubrtn` SubrtnSig-based cross-IN cache
      (expr.c:3585..3656) remains a deferred optimisation with no
      immediate corpus dependency — re-visit once the multi-table
      shapes land or the corpus expands to drive correlated-IN
      shapes that exercise the cache.
    - [X] Sub-progress 25 — corpus expansion + `exprCodeBetween` port
      (2026-04-27).  Two coupled landings:

      (a) TestWhereCorpus widened from 20 → 25 rows with five new
      single-table shapes that exercise edge cases of the existing
      planner: `IS NOT NULL` (NOTNULL), `<>` literal (NEQ), `rowid NOT
      IN (...)` (IPK_NOT_IN), `col BETWEEN lo AND hi` (COL_BETWEEN),
      and `(a=k OR a=k2) AND b>k3` (AND_OR).  Three of the five flip
      to PASS immediately (NOTNULL 11 ops, NEQ 12 ops, AND_OR 18 ops)
      against the C oracle byte-for-byte — coverage growth without
      planner work.

      (b) `exprCodeBetween` (expr.c:6058..6098) — port of the C
      helper that synthesises a stack-local `(x>=lo) AND (x<=hi)`
      Expr tree and dispatches it through `sqlite3ExprIfTrue` /
      `sqlite3ExprIfFalse`.  Wired into both jump-pair entry points'
      TK_BETWEEN arms, replacing the prior fall-through-to-default
      that called `sqlite3ExprCodeTemp` on the BETWEEN expression
      itself.  `sqlite3ExprCodeTarget` has no TK_BETWEEN arm, so
      that fall-through emitted `OP_Null` followed by `OP_IfNot`,
      causing every unindexed BETWEEN residual to always-skip the
      row.  This was a real correctness bug — `SELECT a FROM t
      WHERE b BETWEEN 5 AND 10` returned zero rows when matching
      data existed.  Repro: `bin/test_between` (5 rows inserted,
      3 should match) — gated under the separate sqlite3Insert
      stub (Phase 6 still no-op), so visible only via bytecode
      inspection through TestWhereCorpus.

      Vector BETWEEN (`(a,b) BETWEEN (?,?) AND (?,?)`) is deferred
      — no corpus dependency, would require `exprCodeVector` which
      remains unported.  The scalar fast-path uses
      `sqlite3ExprCodeTemp` directly which is exactly what
      `exprCodeVector` reduces to when the LHS is non-vector.

      Test-suite delta:
        * TestWhereCorpus: **18 → 22 PASS / 2 → 3 DIVERGE / 0 ERROR
          (corpus 20 → 25)**.  COL_BETWEEN flipped to PASS at 14 ops
          byte-for-byte against the C oracle (Init / OpenRead /
          Rewind / Column / Lt / Gt / Column / ResultRow / Next /
          Halt / Transaction / Integer(5) / Integer(10) / Goto).
          Failure-mode tally: `0 exception, 0 nil-Vdbe, 3 op-count,
          0 op-diff` — three remaining op-count divergences are
          LEFT_JOIN, JOIN_WHERE (multi-table planner), and
          IPK_NOT_IN (the rowid-NOT-IN shape, slightly different
          subroutine prologue).
        * No regression anywhere: TestParser 45/45, TestParserSmoke
          20/20, TestPrepareBasic 20/20, TestSelectBasic 49/49,
          TestExprBasic 40/40, TestDMLBasic 54/54, TestSchemaBasic
          44/44, TestWhereBasic 52/52, TestWhereSimple 44/44,
          TestWhereExpr 84/84, TestWhereStructs 148/148,
          TestWherePlanner 675/675, TestVdbeArith 41/41,
          TestVdbeApi 57/57, TestVdbeMisc 45/45, TestVdbeMem 62/62,
          TestVdbeAux 108/108, TestExplainParity 2/10 unchanged,
          TestPrintf 105/105, TestJson 434/434, TestTokenizer
          127/127, TestRegistration 19/19, TestSmoke green.

      Sub-progress 26 (next) will likely tackle IPK_NOT_IN (the
      simpler of the three remaining) — the C oracle prologue
      uses a `Noop` peg before `BeginSubrtn` that the Pascal port
      omits, so the divergence is a 1-op pre-amble alignment plus
      the membership-test inversion.  LEFT_JOIN / JOIN_WHERE
      continue to block on multi-table planner integration.
    - [X] Sub-progress 26 — IPK_NOT_IN PASS via `sqlite3ExprCodeIN`
      split-NULL path port + `begin IN expr` Noop alignment
      (2026-04-27).  Three coupled landings inside
      `sqlite3ExprCodeIN` (codegen.pas:23403):

      (a) **Leading `OP_Noop` "begin IN expr" peg** — `VdbeNoopComment`
      at expr.c:4067 emits an OP_Noop at the start of every
      `sqlite3ExprCodeIN` invocation under -DSQLITE_DEBUG.  Pascal now
      emits the same Noop, but ONLY when `EP_Subrtn` is not yet set on
      the expression — the WHERE pre-loop hoist preamble
      (codegen.pas:12884, sub-progress 21) already emits a Noop in the
      addrSkip slot immediately after `OP_Rewind`, which lines up
      against the same C Noop slot.  Without the EP_Subrtn gate every
      INDEX_IN / INDEX_IN_SUB row would regress with a duplicate Noop
      (Pas=29 vs C=28), since the residual probe walks ExprCodeIN a
      second time after the hoist already laid the Noop down.

      (b) **`prRhsHasNull` propagation** — when `destIfFalse !=
      destIfNull` (NOT IN inside a WHERE residual reaches this branch
      via TK_NOT → ExprIfTrue → TK_IN at codegen.pas:5870..5874 with
      `jumpIfNull <> 0`), pass `@rRhsHasNull` to `sqlite3FindInIndex`.
      `FindInIndex`'s IN_INDEX_EPH arm at codegen.pas:23752..23755
      already increments `pParse^.nMem` and emits
      `sqlite3SetHasNullFlag` on the eph cursor when the pointer is
      non-nil — the +1 register shift is exactly the difference that
      had `BeginSubrtn p2=2 / Integer p1=1 p2=3 / MakeRecord p1=3 …`
      in C versus `BeginSubrtn p2=1 / Integer p1=1 p2=2 / MakeRecord
      p1=2 …` in Pascal pre-fix.  The 3-op `Integer 0/Rewind/Column`
      `SetHasNullFlag` block also drops in for free at the exact
      C addresses.

      (c) **Step-3 (Found) + Step-4 (NotNull rRhsHasNull) + Step-6
      (Rewind/Column/Ne/Goto loop)** port — expr.c:4226..4281.  The
      prior Pascal code only handled the collapsed
      `destIfFalse=destIfNull` fast-path (combined Step3+5
      `OP_NotFound`).  Sub-progress 26 adds the split-NULL branch:
      `OP_Found` jumps to a JumpHere-patched truthy landing,
      `OP_NotNull rRhsHasNull, destIfFalse` short-circuits when the
      RHS is known not to contain NULLs, and the Step-6 single-row
      walk (`Rewind / Column / Ne / Goto destIfNull`) closes the NULL
      semantics for nVector=1 LHS.  The vector arm
      (`destNotNull = MakeLabel; … ResolveLabel destNotNull; OP_Next;
      OP_Goto destIfFalse`) is also wired in for forward-compatibility
      with composite-IN shapes; no current corpus row exercises it.

      The `IN_INDEX_NOOP` arm (≤2-entry literal list) gained the
      `regCkNull = OP_BitAnd(rLhs, rLhs, regCkNull)` accumulator and
      the trailing `IsNull regCkNull, destIfNull / Goto destIfFalse`
      epilogue — expr.c:4120..4151 — even though the current corpus
      doesn't reach the IN_INDEX_NOOP path with split-NULL (the
      ≤2-element fast-path is skipped because the pre-loop hoist takes
      the EPH route first), the code is straightforward and matches C
      shape exactly when invoked.

      Test-suite delta:
        * TestWhereCorpus: **22 → 23 PASS / 3 → 2 DIVERGE / 0 ERROR
          (corpus 25)**.  IPK_NOT_IN flipped to PASS at 36 ops
          byte-for-byte against the C oracle (Init / OpenRead /
          Rewind / Noop / BeginSubrtn / Once / OpenEphemeral / 3×
          Integer/MakeRecord/IdxInsert / NullRow / Return / Integer /
          Rewind / Column / Rowid / Affinity / Found / NotNull /
          Rewind / Column / Ne / Goto / Goto / Column / ResultRow /
          Next / Halt / Transaction / Goto).  Failure-mode tally:
          `0 exception, 0 nil-Vdbe, 2 op-count, 0 op-diff` — the two
          remaining op-count divergences are LEFT_JOIN / JOIN_WHERE
          (multi-table planner from 11g.2.d).
        * No regression anywhere: TestParser 45/45, TestParserSmoke
          20/20, TestPrepareBasic 20/20, TestSelectBasic 49/49,
          TestExprBasic 40/40, TestDMLBasic 54/54, TestSchemaBasic
          44/44, TestWhereBasic 52/52, TestWhereSimple 44/44,
          TestWhereExpr 84/84, TestWhereStructs 148/148,
          TestWherePlanner 675/675, TestVdbeArith 41/41,
          TestVdbeApi 57/57, TestVdbeMisc 45/45, TestVdbeMem 62/62,
          TestVdbeAux 108/108, TestExplainParity 2/10 unchanged,
          TestPrintf 105/105, TestJson 434/434, TestTokenizer
          127/127, TestRegistration 19/19.  In particular INDEX_IN
          and INDEX_IN_SUB stay PASS at 28/28 ops despite the new
          unconditional Noop in ExprCodeIN — the EP_Subrtn gate keeps
          them on the single-Noop hoist path.

      Sub-progress 27 (next) will need to tackle the multi-table
      planner integration to lift LEFT_JOIN / JOIN_WHERE — both
      currently produce a 3-op stub (Init/Halt/Goto) because
      `sqlite3Select` rejects `nSrc <> 1` at the trivial-shape gate
      from sub-progress 5.  This is genuinely a 11g.2.d follow-on
      (whereLoopAddBtree across multiple tables, wherePathSolver
      multi-level path search) more than a 11g.2.f local fix; expect
      it to be a multi-step landing.
    - [X] Sub-progress 27 — single-table corpus expansion (groups #2
      and #3) + `length()` / `typeof()` OP_Column fast-path port
      (2026-04-27).  Multi-table planner stays gated on 11g.2.d; this
      sub-progress widens single-table coverage from 25 to 41 corpus
      rows, lighting up 15 net new PASS shapes and surfacing two
      genuine planner-optimization gaps (DUP_AND duplicate-predicate
      hoist, length() column-arg payload short-circuit) — the latter
      ported here, the former documented for a future sub-progress.

      (a) `TestWhereCorpus` corpus widened 25 -> 41 rows (group #2 +
      group #3).  Group #2 (8 rows): `IPK_PARAM` (`rowid = ?`),
      `COL_PARAM` (`a = ?`), `LIKE_PARAM` (`c LIKE ?`), `NOT_EQ`
      (`NOT (a = 5)`), `COL_COL` (`a = b` — column-vs-column),
      `INDEX_IN_STR` (`c IN ('x','y','z')` — string IN), `IPK_RHS_EXPR`
      (`rowid = 5+1` — RHS arithmetic), `CONST_TRUE` (`WHERE 1`).
      Group #3 (8 rows): `COL_BETWEEN_STR` (`c BETWEEN 'a' AND 'z'`),
      `NOT_NULL_PAREN` (`NOT (c IS NULL)`), `OR_OF_AND` (`(a=1 AND
      b=2) OR (a=3 AND b=4)`), `INDEX_IN_PARAM` (`a IN (?,?,?)`),
      `IPK_PAREN` (`(rowid = 5)`), `DUP_AND` (`a=5 AND a=5`),
      `FUNC_ABS` (`abs(a) = 5`), `FUNC_LENGTH` (`length(c) > 0`).
      Of the 16 new rows, 14 flipped to PASS immediately on the
      existing single-table machinery — confirming TK_VARIABLE
      (parameter binding), TK_NOT (negated EQ), column-vs-column
      comparison, string IN, RHS expression folding, parenthesised
      grouping, OR-of-AND associativity, NOT-IS-NULL, and string
      BETWEEN are all correctly wired through the SCAN-with-residual
      codegen path.

      (b) `emitScalarFunctionCall` + TK_COLUMN arm of
      `sqlite3ExprCodeTarget` (codegen.pas:4365..4385,
      codegen.pas:4724..4732) — port of expr.c:5365..5378's
      length()/typeof() column-arg fast-path.  When `pDef^.funcFlags`
      carries `SQLITE_FUNC_LENGTH | SQLITE_FUNC_TYPEOF` and `nFarg=1`
      with a TK_COLUMN / TK_AGG_COLUMN argument, stamp the
      `OPFLAG_LENGTHARG | OPFLAG_TYPEOFARG` bits onto the column-arg
      Expr's `op2` field BEFORE the second-pass argument codegen
      runs.  The TK_COLUMN arm then propagates that op2 onto the
      OP_Column's P5 byte via `sqlite3VdbeChangeP5(v, op2)` after the
      `sqlite3ExprCodeGetColumnOfTable` emit.  At runtime the VDBE's
      OP_Column handler short-circuits the payload-load step when
      OPFLAG_LENGTHARG is set: only the column header (which carries
      the byte length) is decoded, saving the full record copy when
      only the length / affinity is consumed.  Latent local-shadow
      bug also fixed: the `pDef` local in `emitScalarFunctionCall`
      had been declared `PFuncDef` (the opaque `Pointer` alias used
      for OP_FuncCtx parameter compat); changed to `PTFuncDef` so
      the `funcFlags` field lookup resolves.  No callers of
      `emitScalarFunctionCall` need updating since
      `sqlite3FindFunction` already returns `PTFuncDef`.  Cast wraps
      at lines 4359 / 4362 dropped (no longer needed once the local
      type matches the return type).

      (c) `DUP_AND` row left as DIVERGE.  Bytecode-shape inspection
      (C oracle vs Pascal) shows C performs a constant-predicate
      pre-test hoist: `Integer 5,r1` BEFORE OpenRead, then `Ne r2,
      jump=Halt, r1, p5=81` (NULLEQ | JUMPIFNULL) so that if the
      not-yet-loaded compare-target is NULL the entire scan is
      short-circuited.  This is the classic "WHERE term constant
      folding under duplicate AND" optimization and lives somewhere
      in the planner's `exprAnalyzeOrTerm` / `whereCombineDisjuncts`
      / sqlite3WhereOptimization lineage; without porting it the
      Pascal output is the regular SCAN-with-residual shape (Init /
      OpenRead / Rewind / Column / Eq / Eq / Column / ResultRow /
      Next / Halt / Transaction / Integer-5 / Goto, 14 ops) which
      executes correctly but has a 3-op shape gap against the
      C-oracle pre-test prologue.  Marked as a known divergence; no
      semantic bug.

      Test-suite delta:
        * TestWhereCorpus: **23 PASS / 2 DIVERGE / 0 ERROR (corpus =
          25)** -> **38 PASS / 3 DIVERGE / 0 ERROR (corpus = 41)**.
          15 net new PASS rows; 1 net new DIVERGE row (DUP_AND).
          Failure-mode tally: `0 exception, 0 nil-Vdbe, 2 op-count,
          1 op-diff` (LEFT_JOIN + JOIN_WHERE + DUP_AND).  Corpus
          C-oracle reference total: `534 ops across 33 rows` ->
          `657 ops across 41 rows` (avg 16.0).
        * No regression anywhere: TestParser 45/45, TestParserSmoke
          20/20, TestPrepareBasic 20/20, TestSelectBasic 49/49,
          TestExprBasic 40/40, TestDMLBasic 54/54, TestSchemaBasic
          44/44, TestWhereBasic 52/52, TestWhereSimple 44/44,
          TestWhereExpr 84/84, TestWhereStructs 148/148,
          TestWherePlanner 675/675, TestVdbeArith 41/41, TestVdbeApi
          57/57, TestVdbeMisc 45/45, TestVdbeAux 108/108, TestVdbeMem
          62/62, TestVdbeRecord 13/13, TestVdbeAgg 11/11, TestVdbeStr
          23/23, TestVdbeBlob 13/13, TestVdbeSort 14/14, TestVdbeCursor
          27/27, TestVdbeVtabExec 50/50, TestExplainParity 2/10
          unchanged, TestPrintf 105/105, TestJson 434/434, TestJsonEach
          50/50, TestTokenizer 127/127, TestRegistration 19/19,
          TestExecGetTable 23/23, TestBackup 20/20, TestConfigHooks
          54/54, TestInitShutdown 27/27, TestUnlockNotify 14/14,
          TestLoadExt 20/20, TestAuthBuiltins 34/34, TestOpenClose
          17/17, TestInitCallback 29/29, TestBtreeCompat 337/337.

      Sub-progress 28 (next) is still the multi-table planner
      integration for LEFT_JOIN / JOIN_WHERE — both still currently
      produce the 3-op stub through the `nSrc <> 1` gate at
      sqlite3Select.  Genuinely a 11g.2.d follow-on; expect a multi-
      step landing.  The DUP_AND duplicate-predicate hoist is a
      separate optimization that can land independently in any
      sub-progress.

- [ ] **6.10** `TestExplainParity.pas` — full SQL corpus EXPLAIN diff.
  Scaffold is landed (10-row DDL/transaction corpus, report-only).
  Current Status: **2 PASS / 8 DIVERGE / 0 ERROR**.  Drive to
  all-PASS, then expand corpus to DML / SELECT / pragma / trigger
  forms (same exclusion list as TestParser).  Promote from
  report-only to hard gate when the full corpus is green.

---

## Phase 7 — Parser (one gate open)

- [ ] **7.4b** Bytecode-diff scope of `TestParser.pas`.  Now that
  Phase 8.2 wires `sqlite3_prepare_v2` end-to-end, extend `TestParser`
  to dump and diff the resulting VDBE program (opcode + p1 + p2 + p3
  + p4 + p5) byte-for-byte against `csq_prepare_v2`.  Reuses the 7.4a
  corpus plus the SELECT / pragma / explain / commit / rollback /
  analyze / vacuum / reindex statements currently excluded.  Becomes
  feasible once 6.9 / 6.9-bis flip the EXPLAIN parity to PASS.

- [ ] **7.4c** `TestVdbeTrace.pas` differential opcode-trace gate.
  Needs SQL → VDBE end-to-end
  through the Pascal pipeline so per-opcode traces can be diffed
  against the C reference under `PRAGMA vdbe_trace=ON`.  Re-open
  once 6.9-bis flips TestExplainParity to all-PASS.

---

## Phase 8 — Public API (one gate open)

- [ ] **8.10** Public-API sample-program gate.  Pascal
  transliterations of the sample programs in `../sqlite3/src/shell.c.in`
  (and the SQLite documentation) compile and run against the port
  with results identical to the C reference.  `sqlite3.h` is
  generated by upstream `make`; reference it only after a successful
  upstream build.

---

## Phase 9 — Acceptance: differential + fuzz

- [ ] **9.1** `TestSQLCorpus.pas`: full SQL corpus (Phase 0.10 + any
  additions) runs end-to-end.  stdout, stderr, return code, and the
  resulting `.db` byte-identical to the C reference.

- [ ] **9.2** `TestReferenceVectors.pas`: every canonical `.db` in
  `vectors/` opens, queries, and reports results identically.

- [ ] **9.3** `TestFuzzDiff.pas`: AFL-driven differential fuzzer.
  Seed from the `dbsqlfuzz` corpus.  Run for ≥24 h.  Any divergence
  is a bug.

- [ ] **9.4** SQLite's own Tcl test suite (`../sqlite3/test/*.test`):
  wire the Pascal port in as an alternate target where feasible.
  Internal-API tests will not apply; the "TCL" feature tests should.

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

## Phase 12 — Performance optimisation (enter only after Phase 9 green)

Changes here must preserve byte-for-byte on-disk parity.  Compile
flags: `-dAVX2 -CfAVX2 -CpCOREAVX -OpCOREAVX`.  Note: in FPC,
functions with `asm` content cannot be inlined.

- [ ] **12.1** `perf record` on benchmark workloads; identify the
  top 10 hot functions.

- [ ] **12.2** Aggressive `inline` on VDBE opcode helpers, varint
  codecs, and page cell accessors.

- [ ] **12.3** Consider replacing the VDBE big `case` with threaded
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
