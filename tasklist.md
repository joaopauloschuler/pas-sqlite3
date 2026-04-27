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

- [ ] **6.9-bis 11g.2.f** Audit + regression.  Land
    `TestWhereCorpus.pas` covering the full WHERE shape matrix
    (single rowid-EQ, multi-AND, OR-decomposed, LIKE, IN-subselect,
    composite index range-scan, LEFT JOIN, virtual table xFilter).
    Verify byte-identical bytecode emission against C via
    TestExplainParity expansion.  Re-enable any disabled assertion /
    safety-net guards left in place during 11g.2.b..e.

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
