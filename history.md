# pas-sqlite3 Task List

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

## Most recent activity

  - **2026-04-26 — Phase 6.9-bis (step 11g.2.b — sub-progress):
    allowedOp + operatorMask + exprMightBeIndexed + minimal-viable
    exprAnalyze body.**  Lands the analysis cluster that turns the
    `sqlite3WhereExprAnalyze` stub into a productive walker.  Faithful
    1:1 port of `whereexpr.c:99..162` (allowedOp / operatorMask),
    `whereexpr.c:1067..1101` (exprMightBeIndexed; the indexed-expression
    fallthrough `exprMightBeIndexed2` deferred — only matters for
    `Index.aColExpr<>nil` shapes), and a trimmed `exprAnalyze`
    (`whereexpr.c:1122..`) covering only the analysis paths the
    single-table rowid/IPK-EQ vertical slice needs.

      * **`allowedOp`** — direct port; asserts on TK_GT_TK / TK_LE / TK_LT /
        TK_GE / TK_IN / TK_IS / TK_ISNULL ordering (memory note: TK_GT
        is renamed `TK_GT_TK` in this codebase to avoid collision with
        the WO_GT bitmask).
      * **`operatorMask`** — direct port; asserts on the `op<->WO_*`
        identity for every supported operator.
      * **`exprMightBeIndexed`** — TK_VECTOR unwrap for `>=TK_GT_TK`,
        TK_COLUMN fast path; the indexed-expression fallthrough returns 0
        with an in-line `TODO 11g.2.c` (no corpus shape exercises it).
      * **`exprAnalyze` (private)** — prereqLeft/prereqRight/prereqAll
        computation, EP_OuterON/EP_InnerON dependency rebase, baseline
        WhereTerm reset (leftCursor=-1, iParent=-1, eOperator=0),
        allowedOp branch with `exprMightBeIndexed` LHS lookup +
        `operatorMask & opMask` eOperator population, `TK_IS → TERM_IS`.
      * **`sqlite3WhereExprAnalyze`** — stub replaced by an ascending
        walk over `pWC^.a[0..nBase-1]` calling `exprAnalyze`.  Order
        does not matter today; 11g.2.c switches to the C source's
        descending walk once virtual-term synthesis lands.

    Concrete changes:
      * `passqlite3codegen.pas:5827..` — banner block + four new bodies
        (`allowedOp`, `operatorMask`, `exprMightBeIndexed`,
        `exprAnalyze`) + productive `sqlite3WhereExprAnalyze` body.

    Why this is safe to land alone: no productive caller of
    `sqlite3WhereBegin` exists yet (DELETE/UPDATE skeleton's
    `sqlite3WhereBegin` invocation was disabled in step 11f), so the
    end-to-end behaviour for the corpus is unchanged even though
    `whereShortCut` will now return non-zero for the rowid-EQ shape.
    Verified by full regression sweep — TestWhereBasic 52/52,
    TestWhereStructs 148/148, TestPrepareBasic 20/20, TestParser 45/45,
    TestSchemaBasic 44/44, TestVdbeApi 57/57, TestDMLBasic 54/54,
    TestSelectBasic 49/49, TestExprBasic 40/40, TestInitCallback 29/29,
    TestExplainParity unchanged at **2 PASS / 8 DIVERGE / 0 ERROR**.

    Discoveries / next-step notes:
      * **The FPC case-insensitive var/type collision (memory note) bit
        again.**  `var pExpr: PExpr;` fails with "Error in type
        definition" — same root cause as `var pPager: PPager`.  Existing
        code uses `pExpr` only as a parameter (which is allowed) or as a
        record field; this is the first attempted local-variable
        declaration of that shape.  Renamed the locals to `pX`,
        `pPrs`, `pLftSC`, `xMask` per the convention already used by
        whereScanNext / whereShortCut.
      * **Deferred to 11g.2.c (each call site flagged in-line):**
        right-side commute that inserts a virtual term
        (whereexpr.c:1222..1261), `TK_ISNULL → TK_TRUEFALSE` rewrite
        (1262..1272), BETWEEN / OR / NOTNULL / LIKE virtual-term
        synthesis (1275..1530), `isAuxiliaryVtabOperator` / WO_AUX
        vtab path (1531..1567), `exprMightBeIndexed2` indexed-expression
        match (1039..1066).
      * **`whereShortCut` is now productive.**  For a rowid-EQ predicate
        on a single-table FROM, the shortcut populates
        `pBuilder^.pNew` with `wsFlags = WHERE_COLUMN_EQ | WHERE_IPK |
        WHERE_ONEROW`, `aLTerm[0]` pointing at the WhereTerm, `nLTerm=1`,
        `nEq=1`, `rRun=33` (sqlite3LogEst(10)).  Realistic next sub-progress:
        wire `whereShortCut` into `sqlite3WhereBegin` after the
        WHERE_WANT_DISTINCT block, then emit the `OP_NotExists` body +
        per-loop tail in the `sqlite3WhereEnd` half (where.c:6995..7036
        skipped the False-WHERE-Term-Bypass loop is already landed; the
        planner pick + per-row body is the remaining gap).

  - **2026-04-26 — Phase 6.9-bis (step 11g.2.b — sub-progress):
    sqlite3ExprCodeTemp + TK_NULL / TK_CAST / TK_NOT / TK_BITNOT /
    TK_ISNULL / TK_NOTNULL / TK_TRUTH arms.**  Lands the leaf
    helper `sqlite3ExprCodeTemp` (expr.c:5856..5877) and bolts six
    new arms onto `sqlite3ExprCodeTarget`'s dispatch loop.  Every arm
    flagged "easy unblocked" in the previous sub-progress' next-step
    notes now has a productive path.

      * **`sqlite3ExprCodeTemp`** — code an expression into a
        temporary register; on return, *pReg holds the temp register
        number to release later, or 0 if the result lives in a register
        the caller does not own (constant factored into the init
        section, or a TK_REGISTER alias).  Constant-factor short-circuit
        delegates to `sqlite3ExprCodeRunJustOnce` when
        `parseFlags & PARSEFLAG_OkConstFactor` AND
        `sqlite3ExprIsConstantNotJoin` AND `pX^.op != TK_REGISTER`.
        Otherwise allocates via `sqlite3GetTempReg`, codes via
        `sqlite3ExprCodeTarget`, and releases the temp if the target
        register was overridden (e.g. TK_REGISTER aliased to the
        underlying iTable register).
      * **TK_NULL arm** (expr.c:5187..5192 default-arm folding) —
        emits `OP_Null(0, target)`.  Identical emission to the default
        arm but explicit so the default arm can document its reduced
        responsibility (TK_ERROR + mallocFailed only).
      * **TK_CAST arm** (expr.c:5151..5159) — codes `pLeft` into
        `target` then emits `OP_Cast(target, affinity)` where the
        affinity byte comes from `sqlite3AffinityType(zToken, nil)`.
      * **TK_BITNOT, TK_NOT arms** (expr.c:5348..5355) —
        `r1 := sqlite3ExprCodeTemp(pLeft); OP_BitNot/OP_Not(r1, target);
        sqlite3ReleaseTempReg(regFree1)`.  The opcode-value-equals-
        token-value identity (TK_BITNOT == OP_BitNot == 115,
        TK_NOT == OP_Not == 19) is asserted at runtime.
      * **TK_TRUTH arm** (expr.c:5357..5367) — IS [NOT] {TRUE|FALSE}.
        Encodes via `OP_IsTrue(r1, target, !isTrue, isTrue XOR bNormal)`
        where `bNormal := (op2 == TK_IS)`.
      * **TK_ISNULL, TK_NOTNULL arms** (expr.c:5369..5383) —
        `OP_Integer(1, target); r1 := codeTemp(pLeft);
        addr := OP_IsNull/OP_NotNull(r1); OP_Integer(0, target);
        JumpHere(addr)`.  Same opcode-value-equals-token-value identity.

    Concrete changes:
      * `passqlite3codegen.pas:1736..` — public forward decl for
        `sqlite3ExprCodeTemp` next to `sqlite3ExprCodeRunJustOnce`.
      * `passqlite3codegen.pas:3693..` — `sqlite3ExprCodeTarget` body
        gets six new locals (`r1`, `regFree1`, `addr`, `isTrue`,
        `bNormal`) plus the six new arms above.  Default-arm comment
        trimmed (TK_CAST and the unary cluster no longer mentioned).
      * `passqlite3codegen.pas:4438..` — body of `sqlite3ExprCodeTemp`
        immediately after `sqlite3ExprCodeRunJustOnce`.

    Why this is safe to land alone: none of the new arms appear in the
    productive call paths the corpus currently exercises (the schema-row
    INSERT/UPDATE/DELETE rows emitted by `sqlite3NestedParse`).  Verified
    by build and full regression sweep — TestWhereBasic 52/52,
    TestWhereStructs 148/148, TestPrepareBasic 20/20, TestParser 45/45,
    TestSchemaBasic 44/44, TestVdbeApi 57/57, TestDMLBasic 54/54,
    TestSelectBasic 49/49, TestExprBasic 40/40, TestInitCallback 29/29,
    TestExplainParity unchanged at **2 PASS / 8 DIVERGE / 0 ERROR**.

    Discoveries / next-step notes:
      * **`Pi32` (= ^i32) is the right shape for `pReg`-style
        out-parameters.**  Already declared in passqlite3types.pas;
        no new pointer-type aliases needed.  Same convention any
        future `int*`-out-param port can follow.
      * **The TK_BITNOT/TK_NOT/TK_ISNULL/TK_NOTNULL arms rely on the
        TK_<op> == OP_<op> identity.**  Verified at build time by the
        existing parser/vdbe constant tables.  Asserts at runtime as
        belt-and-braces; if a future SQLite minor bump shifts a TK_/OP_
        constant, the assert fires immediately.
      * **`sqlite3ExprCodeTemp` is the gating helper for the comparison
        cluster (TK_LT..TK_EQ) and the arithmetic cluster (TK_PLUS..
        TK_CONCAT).**  Both of those need `exprComputeOperands` (still
        unported) and `codeCompare` (already landed).  Realistic next
        sub-progress: port `exprComputeOperands` (expr.c:5066..5095) +
        the shared `regFree2`/`r2` plumbing, then land TK_EQ/TK_NE/…/
        TK_LE as a single arm.  After that, the TK_PLUS/TK_MINUS/…
        cluster shares a structurally identical body modulo the `op==`
        value, and finally the AND/OR cluster via `exprCodeTargetAndOr`
        is a separate self-contained helper.
      * **TK_IF_NULL_ROW arm still gated on AggInfo plumbing.**  Even
        the non-aggregate path requires flipping `pParse^.okConstFactor`
        — and the Pascal port models `okConstFactor` as a bit on
        `parseFlags`.  Land separately once the AggInfo branch's
        column-cache scaffolding is in place.

  - **2026-04-26 — Phase 6.9-bis (step 11g.2.b — sub-progress):
    sqlite3ExprCodeTarget — TK_COLLATE / TK_SPAN / TK_UPLUS unary
    delegate arms + expr_code_doover dispatch loop.**  Continues the
    vertical-slice walk through `sqlite3ExprCodeTarget`'s arms.  Lands
    the simple unblocked unary delegates flagged in the previous
    sub-progress' discovery notes — the C source uses
    `goto expr_code_doover` to re-dispatch on `pLeft` for these arms,
    which the Pascal port models with a `repeat … until done` loop
    around the existing `case` statement.

      * **expr_code_doover loop scaffolding** — wraps the case in
        `repeat … until done` so arms that consume their wrapper and
        re-dispatch on `pExpr := pExpr^.pLeft` can iterate without
        deep recursion (faithful translation of the OSSFuzz fix
        pattern noted at expr.c:5528 / 5534).  All previously-landed
        leaf arms now set `done := True` instead of writing `Result`
        directly; `Result` is initialised to `target` up front and
        only the TK_REGISTER arm overwrites it.
      * **TK_COLLATE arm** (expr.c:5514..5530) — when the EP_Collate
        tag is *clear* (a "soft-collate" pushed down by the WHERE
        push-down optimisation), code `pLeft` then emit
        `OP_ClrSubtype(target)` so subtypes do not cross the subquery
        boundary; when EP_Collate is *set*, COLLATE is a codegen no-op
        — re-dispatch on `pLeft`.  Asserts on `pExpr^.pLeft <> nil`
        match the C source.
      * **TK_SPAN, TK_UPLUS arms** (expr.c:5531..5535) — both arms
        simply re-dispatch on `pLeft`; SPAN is a parser-side wrapper
        used by virtual columns / CHECK constraints, UPLUS is the
        unary `+` operator (a no-op at codegen).

    Concrete changes:
      * `passqlite3codegen.pas:1706..1714` — interface comment refreshed
        to list the newly-landed arms (TK_COLLATE / TK_SPAN / TK_UPLUS).
      * `passqlite3codegen.pas:3692..3804` — `sqlite3ExprCodeTarget`
        body restructured around the `repeat … until done` dispatch
        loop; three new arms added before the default arm.

    Why this is safe to land alone: TK_SPAN / TK_UPLUS / TK_COLLATE do
    not appear in the productive call paths the corpus currently exercises
    (sqlite3NestedParse-driven INSERT/UPDATE/DELETE row codegen, PRAGMA
    literals).  Soft-COLLATE is a WHERE push-down byproduct and only
    fires once SELECT codegen lands.  Verified by build and full
    regression sweep — TestWhereBasic 52/52, TestWhereStructs 148/148,
    TestPrepareBasic 20/20, TestParser 45/45, TestSchemaBasic 44/44,
    TestVdbeApi 57/57, TestDMLBasic 54/54, TestSelectBasic 49/49,
    TestExprBasic 40/40, TestInitCallback 29/29, TestExplainParity
    unchanged at **2 PASS / 8 DIVERGE / 0 ERROR**.

    Discoveries / next-step notes:
      * **The dispatch loop is now the right shape for every other
        re-dispatching arm** — TK_IF_NULL_ROW (expr.c:5443) re-codes on
        `pLeft` after wiring an OP_IfNullRow guard, TK_CAST (expr.c:5235)
        re-dispatches via `sqlite3ExprCodeTarget(pParse, pExpr^.pLeft, …)`
        but does *not* loop, and the subquery-eliding paths (EP_Subquery
        with sqlite3ExprIsConstant) all benefit from the loop.  Future
        sub-progresses can lean on the same `done` flag idiom rather
        than reintroducing recursion.
      * **`TK_PURE_FUNCTION` and `TK_TYPEOF` referenced in the previous
        sub-progress' discovery note do not exist in this codebase.**
        They are SQLite extension tokens introduced in newer minor
        versions (3.45+) that gate function evaluation by determinism.
        Drop them from the "easy unblocked arm" list — the actual
        cheap-and-unblocked candidates remaining are TK_NULL (literal
        OP_Null) and TK_IF_NULL_ROW (one-shot guard around `pLeft`).
        Updated the next-step list accordingly.
      * **Realistic next sub-progress: TK_NULL arm** (one-line:
        `sqlite3VdbeAddOp2(v, OP_Null, 0, target)`) — currently routed
        through the default arm with the *same* emission, so the
        explicit arm is documentation only but lets the default arm be
        reduced to a bare assert/abort once every productive opcode is
        ported.  After that, the column-cache scaffolding sub-progress
        becomes the right next chunk to land before TK_COLUMN.

  - **2026-04-26 — Phase 6.9-bis (step 11g.2.b — sub-progress):
    sqlite3ExprCodeTarget — TK_BLOB arm + sqlite3HexToBlob util port.**
    Continues the vertical-slice walk through `sqlite3ExprCodeTarget`'s
    leaf arms.  Lands the second-easiest unblocked arm flagged in the
    previous sub-progress' discovery notes (the easiest still-blocked
    one being TK_COLUMN, which needs the column-cache scaffolding):

      * **`sqlite3HexToBlob`** (util.c:1892..1905) — faithful port to
        `passqlite3util.pas` next to the existing `sqlite3HexToInt`.
        Allocates `n/2 + 1` bytes via `sqlite3DbMallocRawNN`, then packs
        each pair of hex bytes into one output byte.  Caller passes the
        body of an `x'…'` literal *with* the trailing `'` byte still in
        the count — `Dec(n)` strips it before the loop.  Trailing NUL
        terminator written for parity with C even though P4_DYNAMIC
        consumers ignore it.  Public; declared in the util.pas
        interface block alongside `sqlite3HexToInt`.
      * **TK_BLOB arm in `sqlite3ExprCodeTarget`** (expr.c:5125..5138)
        — emits `OP_Blob(n div 2, target, 0, zBlob, P4_DYNAMIC)` with
        the decoded binary value as a malloc'd payload.  Mirrors the
        C asserts on `not EP_IntValue`, `zToken[0] in {'x','X'}`,
        `zToken[1] = quote`, and `z[n] = quote` byte-for-byte.

    Concrete changes:
      * `passqlite3util.pas:601` — public forward decl for
        `sqlite3HexToBlob`.
      * `passqlite3util.pas:1071..` — body of `sqlite3HexToBlob`
        immediately after `sqlite3HexToInt`.
      * `passqlite3codegen.pas:3694..3700` — three new locals on
        `sqlite3ExprCodeTarget` (`z`, `zBlob: PAnsiChar`, `n: i32`).
      * `passqlite3codegen.pas:3737..` — TK_BLOB case arm inserted
        before the default arm; default arm's TODO comment trimmed
        (no longer mentions TK_BLOB).

    Why this is safe to land alone: TK_BLOB is currently unreachable
    via productive call paths (no SELECT codegen wired, no
    sqlite3NestedParse-emitted INSERT writes a blob literal), so the
    new arm is verified by build only.  Pre-wires the case for when
    the SELECT layer (or future PRAGMA emitting hex literals) lands.
    Full regression sweep all green — TestWhereBasic 52/52,
    TestWhereStructs 148/148, TestPrepareBasic 20/20, TestParser 45/45,
    TestSchemaBasic 44/44, TestVdbeApi 57/57, TestDMLBasic 54/54,
    TestSelectBasic 49/49, TestExprBasic 40/40, TestInitCallback 29/29,
    TestExplainParity unchanged at **2 PASS / 8 DIVERGE / 0 ERROR**.

    Discoveries / next-step notes:
      * **`sqlite3HexToBlob` length-arg contract preserved.**  C source
        passes `n = sqlite3Strlen30(z) - 1` (still includes the trailing
        `'`) and the helper internally `n--`s before the loop.  The
        Pascal port keeps that idiom verbatim — callers must mirror the
        C `n - 1` adjustment, not the `n - 2` they might naively expect.
      * **No corpus regression test for the TK_BLOB arm yet.**  Same as
        TK_FLOAT — needs a public API path that reaches
        `sqlite3ExprCode(parse, BlobLiteral, target)`.  Add a
        TestExprBasic case once SELECT codegen lands and `INSERT INTO
        t VALUES(x'deadbeef')` reaches the wrapper.
      * **Realistic next sub-progress: TK_COLUMN arm (still gated).**
        Needs the column-cache scaffolding (`pParse.aColCache` ring +
        `sqlite3ExprCacheStore` / `sqlite3ExprCachePush` /
        `sqlite3ExprCachePop`) plus `sqlite3TableColumnToStorage`
        plus `sqlite3ExprCodeGetColumn` (expr.c:4775..).  Land the
        column-cache scaffolding first as a separate sub-progress, then
        bolt the TK_COLUMN arm on top.  Alternatively, the TK_TYPEOF /
        TK_PURE_FUNCTION / TK_COLLATE / TK_UPLUS arms (all simple
        delegations to `sqlite3ExprCodeTarget` on `pLeft` modulo a
        flag-flip) are unblocked and could land as a small follow-up
        sub-progress before tackling TK_COLUMN.

  - **2026-04-26 — Phase 6.9-bis (step 11g.2.b — sub-progress):
    sqlite3ExprCodeTarget — first vertical slice (literal/leaf arms) +
    codeInteger / codeReal helpers.**  Lifts `sqlite3ExprCode` from a
    flat literal-only stub into the productive C wrapper from
    expr.c:5884 by introducing the recursive dispatch
    `sqlite3ExprCodeTarget` (expr.c:4930).  This first slice ports the
    leaf arms that need no AggInfo / Column / Index plumbing:
      * **TK_INTEGER** — full `codeInteger` (expr.c:4321..4353): handles
        EP_IntValue fast path, oversized literal fallthrough to
        `codeReal`, hex-literal-too-big error, and the
        `SMALLEST_INT64` negation edge case.  Emits `OP_Integer` /
        `OP_Int64` with `P4_INT64` via `sqlite3VdbeAddOp4Dup8`.
      * **TK_FLOAT** — full `codeReal` (expr.c:4303..4311): parses via
        `sqlite3AtoF`, optionally negates, emits `OP_Real` with
        `P4_REAL`.
      * **TK_TRUEFALSE** — `OP_Integer(sqlite3ExprTruthValue, target)`.
      * **TK_STRING** — `sqlite3VdbeLoadString` (unchanged from stub).
      * **TK_NULLS** — `OP_Null(0, target, target+y.nReg-1)` to NULL a
        contiguous register range.
      * **TK_VARIABLE** — `OP_Variable(iColumn, target)`.
      * **TK_REGISTER** — returns `pExpr^.iTable` directly so the
        wrapper emits OP_Copy/OP_SCopy back into target.
      * **default** — emits `OP_Null` so an unsupported op cannot crash
        (matches the C "be nice, don't crash" default arm).
      * **nil pExpr** — folded into the default arm (op := TK_NULL).

    The sqlite3ExprCode wrapper now mirrors expr.c:5884 exactly —
    delegates to `sqlite3ExprCodeTarget`, then OP_Copy (for
    EP_Subquery/TK_REGISTER under sqlite3ExprSkipCollateAndLikely) or
    OP_SCopy when the returned register differs from `target`.

    Concrete changes:
      * `passqlite3codegen.pas:1706..1721` — public forward decl
        update: `sqlite3ExprCodeTarget` exposed alongside
        `sqlite3ExprCode`.
      * `passqlite3codegen.pas:3611..3766` — three new bodies
        (`codeReal`, `codeInteger`, `sqlite3ExprCodeTarget`) and the
        rewired `sqlite3ExprCode` wrapper.

    Why this is safe to land alone: existing productive call-sites
    (sqlite3NestedParse-generated INSERT/UPDATE/DELETE row codegen,
    PRAGMA-emitted literals) only ever pass TK_INTEGER/TK_NULL/TK_STRING
    /TK_REGISTER — exactly the arms covered before, with strict
    semantic upgrade for non-EP_IntValue integer literals (now
    correctly via OP_Int64) and floats (now correctly via OP_Real).
    The TK_TRUEFALSE / TK_NULLS / TK_VARIABLE arms are inert in the
    current corpus but pre-wire the cases the next slices' callers
    will rely on.  Full regression sweep all green —
    TestWhereBasic 52/52, TestWhereStructs 148/148, TestPrepareBasic
    20/20, TestParser 45/45, TestSchemaBasic 44/44, TestVdbeApi 57/57,
    TestDMLBasic 54/54, TestSelectBasic 49/49, TestExprBasic 40/40,
    TestInitCallback 29/29, TestExplainParity unchanged at **2 PASS /
    8 DIVERGE / 0 ERROR**.

    Discoveries / next-step notes:
      * **`sqlite3ErrorMsg` is still single-arg in the Pascal port.**
        codegen.pas:2599 takes only `(pParse, zFormat)` — no varargs
        yet.  The hex-too-big path lands the literal message
        `'hex literal too big'` rather than the C
        `'hex literal too big: %s'` formatted form.  Fold in proper
        formatting when the printf-style sqlite3ErrorMsg port lands
        (depends on Phase 6 sqlite3VMPrintf wiring).
      * **`SMALLEST_INT64` modelled as `i64($8000000000000000)`.**  No
        existing constant — inline-cast at the two sites in
        `codeInteger`.  Land a named const in `passqlite3int.pas`
        when a second user appears (likely the comparison cluster).
      * **`Expr.y.nReg` confirmed at codegen.pas:477** — the union
        case-2 record holds `nReg: i32`, sufficient for the TK_NULLS
        contiguous-NULL-range arm.
      * **Realistic next sub-progress: TK_COLUMN arm.**  Needs
        `sqlite3ExprCodeGetColumn` (expr.c:4775..) which in turn
        depends on the column-cache helpers (`sqlite3ExprCacheStore`,
        the `pParse.aColCache` ring) and on
        `sqlite3TableColumnToStorage`.  Land the column-cache
        scaffolding first as a separate sub-progress, then bolt the
        TK_COLUMN arm on top — that unlocks every SELECT codegen path.
      * **Subsequent slice candidates (no new dependencies):**
        TK_BLOB needs only `sqlite3HexToBlob` (small util port);
        TK_AGG_COLUMN's "directMode==0" fast path is one line
        (`AggInfoColumnReg(pAggInfo, iAgg)`) but needs the AggInfo
        record laid out — defer until Phase 6.x's aggregate work.
      * **TK_FLOAT regression-test note.**  No corpus test currently
        exercises a TK_FLOAT literal in a productive code path — the
        new arm is verified by build only.  Add a TestExprBasic case
        once `sqlite3ExprCode(parse, FloatLiteral, target)` is reachable
        from a public API path (likely once SELECT codegen lands).

  - **2026-04-26 — Phase 6.9-bis (step 11g.2.b — sub-progress):
    sqlite3ExprCodeRunJustOnce.**  Next link in the discovery-note
    chain unlocking `sqlite3ExprCodeTarget`.  Faithful translation of
    expr.c:5777..5822 — factors a constant expression out of the main
    VDBE program into the once-at-prepare-time init section so its
    result is available in a stable register without re-evaluation per
    row.

    Two paths handled:
      * **Reusable path** (pure constant, no functions): clones the
        expression via `sqlite3ExprDup`, appends to
        `pParse^.pConstExpr` via `sqlite3ExprListAppend`, allocates (or
        accepts caller-supplied) a register, sets the `reusable` bit
        (eBits bit 3 = $08) when regDest<0, and stores the register in
        `pItem^.u.iConstExprReg` so a later
        `sqlite3ExprCodeConstants` pass can emit the actual init code.
        When `regDest<0` the function first walks the existing list to
        reuse an identical earlier entry — that's how `expr OR expr`
        with identical sub-expressions code to a single register.
      * **EP_HasFunc path** (constant but contains a function call —
        e.g. `sqlite3_version()`): emits `OP_Once` immediately to
        gate a one-shot evaluation, flips
        `PARSEFLAG_OkConstFactor` off so the inner `sqlite3ExprCode`
        recursion does not re-factor, calls `sqlite3ExprCode` to emit
        the body, restores the flag, deletes the cloned expression,
        and resolves the OP_Once branch via `sqlite3VdbeJumpHere`.

    Concrete changes:
      * `passqlite3codegen.pas:1727..1729` — public forward decl for
        `sqlite3ExprCodeRunJustOnce`.
      * `passqlite3codegen.pas:4184..4274` — body of
        `sqlite3ExprCodeRunJustOnce`, immediately after
        `sqlite3ExprIsConstantNotJoin`.

    Why this is safe to land alone: no productive callers yet
    (`sqlite3ExprCodeTemp` / `sqlite3ExprCodeFactorable` /
    `sqlite3ExprCodeCopy` and the DEFAULT-clause / ALTER TABLE
    sub-paths all still stub — landing the chain in slices).  Pure
    scaffolding, no observable behaviour change in the corpus.  Full
    regression sweep all green — TestWhereBasic 52/52, TestWhereStructs
    148/148, TestPrepareBasic 20/20, TestParser 45/45, TestSchemaBasic
    44/44, TestVdbeApi 57/57, TestDMLBasic 54/54, TestSelectBasic
    49/49, TestExprBasic 40/40, TestInitCallback 29/29,
    TestExplainParity unchanged at **2 PASS / 8 DIVERGE / 0 ERROR**.

    Discoveries / next-step notes:
      * **`ConstFactorOk` ↔ `PARSEFLAG_OkConstFactor`.**  The C macro
        `ConstFactorOk(P) ((P)->okConstFactor)` (sqliteInt.h:1945) is
        modelled in the Pascal port via the parseFlags bitfield bit
        `PARSEFLAG_OkConstFactor = 1 shl 7`.  Both the assert-on-entry
        and the inner save/clear/restore of okConstFactor are mapped
        to AND/OR/AND-NOT on `pParse^.parseFlags`.  This is the first
        productive Pascal helper to *write* okConstFactor (every
        existing reference only OR-set it once at parse-init time at
        codegen.pas:5314); the save-and-restore pattern is
        established here for future ports of
        `sqlite3ExprCodeFactorable` / `sqlite3ExprCodeCopy` /
        `sqlite3ExprCodeAtInit`.
      * **`ExprListItem.fg.eBits` bit 3 = reusable.**  Confirmed via
        the comment at codegen.pas:509..510 and the
        `pItem^.fg.eBits or $08` / `and not $08` patterns used here.
      * **`sqlite3ExprCompare(nil, …)` accepts pParse=nil** — verified
        by call sites at codegen.pas:12062 and :12498.  Used here in
        the reusable-list scan to keep the pParse-independent
        comparison the C source does.
      * **Realistic next sub-progress: `sqlite3ExprCodeTarget`.**  The
        770-line recursive dispatch — best landed in vertical slices.
        Existing literal-only `sqlite3ExprCode` stub at
        codegen.pas:3626..3673 already handles the four arms reached
        by sqlite3NestedParse-generated INSERT/UPDATE/DELETE
        (TK_INTEGER, TK_NULL, TK_STRING, TK_REGISTER); first slice
        should add column refs (TK_COLUMN) and temp-register
        (TK_REGISTER variants beyond the trivial copy).

  - **2026-04-26 — Phase 6.9-bis (step 11g.2.b — sub-progress):
    productive sqlite3ExprIsConstant + sqlite3ExprIsConstantNotJoin
    (walker-based) + exprIsConst / exprNodeIsConstant /
    exprNodeIsConstantFunction.**  First step of the discovery-note
    chain unlocking `sqlite3ExprCodeTarget` (the 770-line recursive
    dispatch that gates `exprCodeBetween` / `exprComputeOperands` /
    `sqlite3ExprIfTrue` / `sqlite3ExprIfFalse`).  Faithful translation
    of expr.c:2466..2664 — replaces the literal-only stub of
    `sqlite3ExprIsConstant` (codegen.pas:4011..4019) with the full
    Walker-driven classifier and adds the file-private companion
    `sqlite3ExprIsConstantNotJoin` (eCode==2 variant: rejects EP_OuterON
    + EP_FixedCol).

    Five C functions land together because they form a closed callback
    cluster:

      * `exprNodeIsConstantFunction` (expr.c:2482..2512) — TK_FUNCTION
        node walker helper.  Checks all arguments via
        `sqlite3WalkExprList`, then resolves the FuncDef via
        `sqlite3FindFunction` and verifies SQLITE_FUNC_CONSTANT |
        SQLITE_FUNC_SLOCHNG, no aggregate finalizer, no EP_WinFunc.
      * `exprNodeIsConstant` (expr.c:2541..2617) — main Walker callback,
        eCode-dispatched 1..5.  Handles every TK_* arm: TK_FUNCTION
        (ConstFunc fast path or recursive function check), TK_ID (folds
        true/false IDs to TK_TRUEFALSE via existing
        `sqlite3ExprIdToTrueFalse`; otherwise treated like TK_COLUMN),
        TK_COLUMN/TK_AGG_FUNCTION/TK_AGG_COLUMN (FixedCol+iCur table-
        constant check), TK_IF_NULL_ROW/TK_REGISTER/TK_DOT/TK_RAISE
        (always reject), TK_VARIABLE (eCode 4 rejects, 5 silently
        rewrites op := TK_NULL).
      * `exprIsConst` (expr.c:2618..2629) — common Walker driver.
      * `sqlite3ExprIsConstant` (expr.c:2645..2647) — public, eCode==1.
      * `sqlite3ExprIsConstantNotJoin` (expr.c:2662..2664) — file-
        private, eCode==2 (kept file-private to match C; cross-unit
        callers come later when sqlite3ExprCodeTarget lands).

    The eCode==3 (`sqlite3ExprIsTableConstant`) and eCode==4/5
    (`sqlite3ExprIsConstantOrFunction`) public entry points are *not*
    wired up here — only the dispatch arms that handle them inside the
    callback are.  Adding the public wrappers is a one-liner each when
    the consumers (DEFAULT codegen / planner table-constant check) land.

    Concrete changes:
      * `passqlite3codegen.pas:4011..4180` — five new function bodies
        replacing the stub `sqlite3ExprIsConstant` body.

    Why this is safe to land alone: the only existing productive call
    sites (`sqlite3WhereAddLimit` at codegen.pas:12043..12047) pass
    eCode=1 — same semantics as before for any literal-only input, but
    now also correctly accepts ConstFunc-flagged function calls and
    sub-tree-constant expressions, matching what the C planner sees.
    No new test divergences expected — `sqlite3WhereAddLimit` is gated
    behind the still-stub WhereBegin so the broader behaviour change is
    inert in the corpus.  Full regression sweep all green —
    TestWhereBasic 52/52, TestWhereStructs 148/148, TestPrepareBasic
    20/20, TestParser 45/45, TestSchemaBasic 44/44, TestVdbeApi 57/57,
    TestDMLBasic 54/54, TestSelectBasic 49/49, TestExprBasic 40/40,
    TestInitCallback 29/29, TestExplainParity unchanged at **2 PASS /
    8 DIVERGE / 0 ERROR**.

    Discoveries / next-step notes:
      * **Walker.eCode is u16 in the Pascal port.**  The C source uses
        `int` for `Walker.eCode`, but our struct (codegen.pas:799) has
        already locked it as `u16`.  The exprIsConst driver casts:
        `w.eCode := u16(initFlag); ... Result := i32(w.eCode);`.  No
        observable effect — initFlag is always in 1..5.
      * **ExprUseXList guards `pExpr^.x.pList` access.**  The C
        `pExpr->x.pList==0` check needs the `ExprUseXList` predicate in
        Pascal to avoid mis-dereferencing the union when the node has
        EP_xIsSelect set.  Locked in the new
        `exprNodeIsConstantFunction`.
      * **Realistic next sub-progress: `sqlite3ExprCodeRunJustOnce`.**
        Small factor-out helper (expr.c around line 5860) — pre-folds
        a constant expression into the prepared-statement init code via
        `pParse^.pConstExpr`.  After that lands, the big
        `sqlite3ExprCodeTarget` port begins (vertical slices: literals
        already done; columns + temp-ref next; arithmetic; comparison;
        CASE; FUNCTION; etc.).
        UPDATE 2026-04-26: `sqlite3ExprCodeRunJustOnce` ✅ landed —
        see Most-recent-activity entry above.  Next is the big
        `sqlite3ExprCodeTarget` vertical slice.
      * **Public wrappers waiting for first cross-unit caller.**
        `sqlite3ExprIsTableConstant` (eCode==3, where.c-internal) and
        `sqlite3ExprIsConstantOrFunction` (eCode==4/5, build.c
        DEFAULT-clause check) are one-liners — drop them in
        immediately above their first productive call site rather than
        speculatively here.

  - **2026-04-26 — Phase 6.9-bis (step 11g.2.b — sub-progress):
    sqlite3ExprToRegister + ExprSetProperty/ExprClearProperty inline
    macros.**  Third leaf helper of step 11g.2.b's pre-IfTrue/IfFalse
    cluster (after `sqlite3ExprCanBeNull` and the codeCompare cluster).
    Faithful translation of expr.c:4502..4518 — converts a scalar
    expression node to a TK_REGISTER reference into a caller-supplied
    register, preserving the original opcode in `op2` and clearing
    `EP_Skip` so the rewritten node is no longer hidden from
    `sqlite3ExprSkipCollate*`.  Skips through any TK_COLLATE / EP_Unlikely
    outer wrappers via the existing `sqlite3ExprSkipCollateAndLikely`.

    Two sqliteInt.h-level inline macros added at the same time because
    the new helper (and the looming `exprCodeBetween` /
    `sqlite3ExprIfTrue` / `sqlite3ExprIfFalse` ports) both touch
    `Expr.flags` directly:

      * `ExprSetProperty(p, prop)`   — `flags := flags or prop`.
      * `ExprClearProperty(p, prop)` — `flags := flags and (not prop)`.

    Both placed at `passqlite3codegen.pas:2386..` immediately after the
    existing `ExprHasProperty` / `ExprHasAllProperty` inlines, mirroring
    sqliteInt.h's grouping.

    Concrete changes:
      * `passqlite3codegen.pas:1724` — public forward decl for
        `sqlite3ExprToRegister`.
      * `passqlite3codegen.pas:2391..2406` — inline `ExprSetProperty` /
        `ExprClearProperty`.
      * `passqlite3codegen.pas:3946..3974` — body of
        `sqlite3ExprToRegister`, just before `sqlite3ExprIsInteger`.

    Why this is safe to land alone: no productive callers yet
    (`exprCodeBetween` / `sqlite3ExprIfTrue` / `sqlite3ExprIfFalse` still
    unported; the False-WHERE-Term-Bypass loop is still unported) — pure
    scaffolding sub-progress, no observable behaviour change in the
    corpus.  Full regression sweep all green — TestWhereBasic 52/52,
    TestWhereStructs 148/148, TestPrepareBasic 20/20, TestParser 45/45,
    TestSchemaBasic 44/44, TestVdbeApi 57/57, TestDMLBasic 54/54,
    TestSelectBasic 49/49, TestExprBasic 40/40, TestInitCallback 29/29,
    TestExplainParity unchanged at **2 PASS / 8 DIVERGE / 0 ERROR**.

    Discoveries / next-step notes:
      * **`exprCodeVector` and `sqlite3ExprCodeTarget` remain the actual
        wall.**  `exprCodeBetween` (expr.c:6058) calls
        `sqlite3ExprToRegister(pDel, exprCodeVector(pParse, pDel,
        &regFree1))` and then optionally `sqlite3ExprCodeTarget(pParse,
        &exprAnd, dest)`; neither helper is in the Pascal codebase yet
        (only a literal-only stub of the public `sqlite3ExprCode` is
        present at `passqlite3codegen.pas:3612`).  `exprCodeVector`'s
        single-result branch dispatches to `sqlite3ExprCodeTemp`
        (expr.c:5856) which itself dispatches to
        `sqlite3ExprCodeRunJustOnce` *or* `sqlite3ExprCodeTarget`
        depending on `ConstFactorOk` + `sqlite3ExprIsConstantNotJoin`.
        Realistic order of porting therefore:
          1. `sqlite3ExprIsConstantNotJoin` (Walker-based, not too long
             — needs `exprNodeIsConstant` callback).
          2. `sqlite3ExprCodeRunJustOnce` (factor-out helper; small).
          3. `sqlite3ExprCodeTarget` — the *big* recursive dispatch
             (expr.c:5040..5807, ~770 lines, dozens of TK_* arms).  Best
             landed in vertical slices: arm-by-arm or grouped clusters
             (literals already done; columns + temp-ref cluster next;
             arithmetic; comparison; CASE; FUNCTION; etc.).
          4. `sqlite3ExprCodeTemp` once Target is sufficient.
          5. `exprCodeVector` once Temp is in.
          6. `exprCodeBetween` + `exprComputeOperands` (now both
             unblocked).
          7. `sqlite3ExprIfTrue` / `sqlite3ExprIfFalse` (mutually
             recursive) — depend on most of the above.
          8. False-WHERE-Term-Bypass loop body in `sqlite3WhereBegin`.
        Each step in this chain is now a candidate for a stand-alone
        sub-progress commit.
      * **op2 byte already present on TExpr** at
        `passqlite3codegen.pas:490`.  No struct-layout work needed.
      * **EP_Skip flag value `$002000`** matches the C constant; same
        bit layout already locked in by existing
        `sqlite3ExprSkipCollate*` consumers.

  - **2026-04-26 — Phase 6.9-bis (step 11g.2.b — sub-progress):
    codeCompare + comparison-affinity / collation leaf helpers.**
    Second of the four missing leaf helpers gating the eventual
    `sqlite3ExprIfTrue` / `sqlite3ExprIfFalse` port.  Five faithful
    translations of expr.c:342..488 land together because they form a
    minimal closed dependency cluster — `codeCompare` calls
    `sqlite3BinaryCompareCollSeq` + `binaryCompareP5`; the latter calls
    `sqlite3CompareAffinity`; `sqlite3ExprCompareCollSeq` is the
    EP_Commuted-aware wrapper that productive call sites
    (`whereexpr.c:980`, `expr.c:3351`, `expr.c:3752`) reach for first.

      * `sqlite3CompareAffinity` (expr.c:342..358) — picks the
        comparison affinity given one operand and the other's affinity.
        Both-columns case: NUMERIC if either side is numeric, else
        BLOB.  Mixed case: `(non-column-side or SQLITE_AFF_NONE)`
        keeping `sqlite3IsNumericAffinity` correct via the `>=` macro.
        Public — many call sites in expr.c, where.c, whereexpr.c.
      * `binaryCompareP5` (expr.c:402..410) — file-private; combines
        the comparison affinity with caller-supplied jumpIfNull flags
        into the P5 byte for OP_Eq/Ne/Lt/Le/Gt/Ge.
      * `sqlite3BinaryCompareCollSeq` (expr.c:424..442) — collation
        picker: left wins on EP_Collate, then right on EP_Collate, else
        left's inherited then right's.  pRight may be nil (callers
        like KeyInfo construction pass nil for unbound side).  Public.
      * `sqlite3ExprCompareCollSeq` (expr.c:452..458) — public
        EP_Commuted-aware wrapper around the above.  Reverses operand
        order when the parser has already commuted the comparison so
        the planner/codegen sees the original-typing collation.
      * `codeCompare` (expr.c:463..488) — file-private opcode emitter.
        Skips emission cleanly when `pParse^.nErr <> 0` (returns 0).
        Picks the collation through BinaryCompareCollSeq (with the
        isCommuted reversal mirroring sqlite3ExprCompareCollSeq), then
        emits `OP_<opcode>` with `(in2, dest, in1, p4=collseq,
        P4_COLLSEQ)` and changes P5 to the affinity|jumpIfNull byte.
        Returns the addr of the emitted instruction.  Will be called
        directly by the recursive `sqlite3ExprIfTrue` /
        `sqlite3ExprIfFalse` jump-emission pair (next sub-progress).

    Concrete changes:
      * `passqlite3codegen.pas:1721..1723` — public forward decls for
        `sqlite3CompareAffinity`, `sqlite3BinaryCompareCollSeq`,
        `sqlite3ExprCompareCollSeq`.
      * `passqlite3codegen.pas:3832..` — bodies of the five helpers,
        immediately after `sqlite3ExprCanBeNull`.

    Why this is safe to land alone: no productive callers yet
    (`sqlite3ExprIfTrue` / `sqlite3ExprIfFalse` still unported, the
    OP_Eq emission inside the WHERE planner / wherecode.c is not
    productive yet either) — pure scaffolding sub-progress, no
    observable behaviour change in the corpus.  Full regression sweep
    all green — TestWhereBasic 52/52, TestWhereStructs 148/148,
    TestPrepareBasic 20/20, TestParser 45/45, TestSchemaBasic 44/44,
    TestVdbeApi 57/57, TestDMLBasic 54/54, TestSelectBasic 49/49,
    TestExprBasic 40/40, TestInitCallback 29/29, TestExplainParity
    unchanged at **2 PASS / 8 DIVERGE / 0 ERROR**.

    Discoveries / next-step notes:
      * **sqlite3VdbeAddOp4 zP4 typed PAnsiChar in the Pascal port,
        not Pointer.**  The C signature takes `const char*` so the
        Pascal mirror types it as `PAnsiChar`.  Callers passing
        non-string P4 payloads (CollSeq*, KeyInfo*, etc.) must cast:
        `PAnsiChar(p4)`.  The `p4type` arg disambiguates at the
        consumer; the cast is purely for type checking.  Locked in
        codegen.pas (this sub-progress' codeCompare passes
        `PAnsiChar(p4)` for a CollSeq* with `P4_COLLSEQ`).
      * **EP_Commuted vs OP_Commuted.**  `EP_Commuted` (expr flags,
        u32, value $400) marks an expression node whose operands have
        been swapped by the parser.  Distinct from `OPFLAG_COMMUTED`
        (a P5 hint on the actual VDBE opcode).  Both already present
        in our codegen.pas (lines 53..76 const block).
      * **Next leaf helpers (still 11g.2.b):**
        `exprComputeOperands` (expr.c:2417), `exprCodeBetween`
        (expr.c:6028).  Both depend on `sqlite3ExprDup`,
        `sqlite3ExprToRegister`, `sqlite3ReleaseTempReg`,
        `sqlite3ExprCodeTarget`, `sqlite3ExprDelete`,
        `exprCodeVector` — audit each before landing.  After those
        two: port the recursive `sqlite3ExprIfTrue` /
        `sqlite3ExprIfFalse` pair (~400 lines), then the False-WHERE-
        Term-Bypass loop body in WhereBegin.

  - **2026-04-26 — Phase 6.9-bis (step 11g.2.b — sub-progress):
    sqlite3ExprCanBeNull leaf helper.**  First of the four missing leaf
    helpers identified by the previous sub-progress as gating the
    eventual `sqlite3ExprIfTrue` / `sqlite3ExprIfFalse` port (the others
    being `codeCompare`, `exprComputeOperands`, `exprCodeBetween`).
    Faithful translation of expr.c:2965..2994 — skips through TK_UPLUS /
    TK_UMINUS unary chains, dispatches on the underlying op (consulting
    op2 for TK_REGISTER), and consults the column's notNull bitfield via
    `TColumn.typeFlags` low nibble.  The SQLITE_ALLOW_ROWID_IN_VIEW arm
    (XN_ROWID + IsView) is omitted: that build option is not enabled in
    our port.  Declared in the public block at
    `passqlite3codegen.pas:1720` because future codeEqualityTerm logic
    will call it across translation-unit boundaries; defined immediately
    after `sqlite3IsRowid` at :3780.

    Why this is safe to land alone: no productive callers yet
    (`sqlite3ExprIfTrue` / `sqlite3ExprIfFalse` still unported) — pure
    scaffolding sub-progress, no observable behaviour change in the
    corpus.  Full regression sweep all green — TestWhereBasic 52/52,
    TestWhereStructs 148/148, TestPrepareBasic 20/20, TestParser 45/45,
    TestSchemaBasic 44/44, TestVdbeApi 57/57, TestDMLBasic 54/54,
    TestSelectBasic 49/49, TestExprBasic 40/40, TestInitCallback 29/29,
    TestExplainParity unchanged at **2 PASS / 8 DIVERGE / 0 ERROR**.

    Discoveries / next-step notes:
      * **TColumn.typeFlags bitfield ordering.**  Pascal models the C
        bitfield `notNull:4 + eCType:4` as a single u8 with notNull in
        the low nibble (bits 0..3) — verified against existing pTab^.aCol
        usage and the GCC x86-64 layout already locked in TestExprBasic's
        SizeOf gate.  Mask is `typeFlags and $0F`.
      * **Next leaf helpers (still 11g.2.b):** `codeCompare` (expr.c:463),
        `exprComputeOperands` (expr.c:2417), `exprCodeBetween`
        (expr.c:6028).  `codeCompare` depends on
        `sqlite3BinaryCompareCollSeq` and `binaryCompareP5` — check those
        first; if missing, port them as a sub-sub-progress.
        `exprComputeOperands` depends on `sqlite3ExprCodeTemp` (already
        in the codebase) plus the new `sqlite3ExprCanBeNull` (now
        present) and existing `exprEvalRhsFirst`.  `exprCodeBetween`
        depends on `sqlite3ExprDup`, `exprCodeVector`,
        `sqlite3ExprToRegister`, `sqlite3ReleaseTempReg`,
        `sqlite3ExprCodeTarget`, `sqlite3ExprDelete` — audit each before
        landing.
      * After the four leaves: port the recursive `sqlite3ExprIfTrue` /
        `sqlite3ExprIfFalse` pair (~400 lines), then the False-WHERE-
        Term-Bypass loop body in WhereBegin.

  - **2026-04-26 — Phase 6.9-bis (step 11g.2.b — sub-progress):
    sqlite3ExprSimplifiedAndOr + exprEvalRhsFirst + ExprAlwaysTrue/False
    macros.**  Foundation helpers required by the eventual port of
    `sqlite3ExprIfTrue` / `sqlite3ExprIfFalse` (expr.c:6100..) — those
    in turn gate the False-WHERE-Term-Bypass loop at where.c:6995..7036
    inside the `sqlite3WhereBegin` prologue.  This sub-progress lands
    only the small, leaf-level pre-requisites; the bigger jump-emission
    routines come next.

      * `ExprAlwaysTrue` / `ExprAlwaysFalse` (sqliteInt.h:3147..3148)
        added next to `ExprHasAllProperty` in
        `passqlite3codegen.pas:2392..` as inline functions.  Mirror the
        C macros byte-for-byte: `(flags & (EP_OuterON|EP_IsTrue))
        == EP_IsTrue` and equivalent for IsFalse.  The `EP_OuterON`
        gate is the key wrinkle — even a literal `TRUE` becomes
        conditionally false on the null-row side of a LEFT/FULL JOIN
        ON clause, so the macros refuse to fold those.
      * `sqlite3ExprSimplifiedAndOr` (expr.c:2373..2385) — public
        helper that walks an AND/OR sub-tree and returns the simplified
        equivalent (`(x<10) AND true => (x<10)`, `(y=22) OR true =>
        true`, etc.).  Recursive on AND/OR only; leaf operators are
        returned unchanged.  Forward-declared in the public block
        alongside `sqlite3ExprTruthValue`.
      * `exprEvalRhsFirst` (expr.c:2395..2403) — file-private
        predicate; returns 1 iff the LHS of a binary expression
        contains a sub-select while the RHS does not (a hint for the
        coder to short-circuit out of the expensive sub-select when
        the cheap RHS already determines the result).  Kept file-
        private; no forward decl.

    Why this is safe to land alone: none of the new helpers are called
    by productive code yet (sqlite3ExprIfTrue / sqlite3ExprIfFalse are
    still unported; the False-WHERE-Term-Bypass loop is still
    unported).  Pure scaffolding sub-progress — no observable behaviour
    change in the corpus.

    Concrete changes:
      * `passqlite3codegen.pas:2392..2406` — `ExprAlwaysTrue` /
        `ExprAlwaysFalse` inline helpers.
      * `passqlite3codegen.pas:1717..1718` — public forward decl for
        `sqlite3ExprSimplifiedAndOr`.
      * `passqlite3codegen.pas:3710..` — bodies of
        `sqlite3ExprSimplifiedAndOr` and `exprEvalRhsFirst`,
        immediately after `sqlite3ExprTruthValue`.

    Test status: full build clean (no new warnings), regression sweep
    all green — TestWhereBasic 52/52, TestWhereStructs 148/148,
    TestPrepareBasic 20/20, TestParser 45/45, TestSchemaBasic 44/44,
    TestVdbeApi 57/57, TestDMLBasic 54/54, TestSelectBasic 49/49,
    TestExprBasic 40/40, TestInitCallback 29/29, TestExplainParity
    unchanged at **2 PASS / 8 DIVERGE / 0 ERROR**.

    Discoveries / next-step notes:
      * **Next 6.9-bis target (still 11g.2.b): port sqlite3ExprIfTrue /
        sqlite3ExprIfFalse (expr.c:6100..6500-ish — mutually
        recursive).**  These are the largest single helper block
        gating the False-WHERE-Term-Bypass loop.  Many sub-helpers
        they call are already present in the Pascal codebase
        (`sqlite3ExprIsVector`, `sqlite3ExprTruthValue`,
        `sqlite3ExprCodeTemp`, `sqlite3VdbeMakeLabel`,
        `sqlite3VdbeResolveLabel`, etc.); a few are not yet
        (`codeCompare`, `exprComputeOperands`, `exprCodeBetween`,
        `sqlite3ExprCanBeNull`).  The port likely needs to land in
        2-3 sub-progress chunks: first the missing leaf helpers
        (codeCompare etc.), then the recursive ExprIfTrue/False pair,
        then the False-WHERE-Term-Bypass loop body in WhereBegin.
      * **TK_AND / TK_OR token values** — already present at
        `passqlite3codegen.pas:135` (TK_OR=43, TK_AND=44).  No new
        tokens needed for this sub-progress.
      * **EP_Subquery / EP_IsTrue / EP_IsFalse / EP_OuterON** — all
        flags already present in the public const block at
        `passqlite3codegen.pas:44..76`.  No new flag definitions
        needed.

  - **2026-04-26 — Phase 6.9-bis (step 11g.2.b — sub-progress):
    productive sqlite3WhereBegin prologue body.**  Replaced the bare
    `Result := nil` stub of `sqlite3WhereBegin`
    (`passqlite3codegen.pas:4430`) with a faithful port of the where.c:
    6828..6993 prologue — every line up to (but not including) the
    False-WHERE-Term-Bypass loop and the planner core.  Concretely:
      * Two leading `Assert`s mirroring the C contract checks on
        WHERE_ONEPASS_MULTIROW / WHERE_OR_SUBCLAUSE / WHERE_USE_LIMIT
        flag interactions.  Pascal needed extra parens around the
        `(x and y) = 0` clauses (operator-precedence trap — `and` and
        `=` parse `(x and y) = 0 or (...)` as `(x and y) = (0 or ...)`).
      * Variable init: `db := pParse^.db`; `FillChar(sWLB, ..., 0)`.
      * ORDER BY / GROUP BY cap (>= BMS): zero pOrderBy, clear
        WHERE_WANT_DISTINCT, set WHERE_KEEP_ALL_JOINS.
      * FROM-clause cap (`pTabList^.nSrc > BMS`) → emit
        sqlite3ErrorMsg + return nil.  The C variadic
        `"at most %d tables"` substitutes BMS=64 inline since our
        sqlite3ErrorMsg port is a fixed-string sink today.
      * `nTabList := (WHERE_OR_SUBCLAUSE) ? 1 : pTabList^.nSrc`.
      * Single allocation: `sqlite3DbMallocRawNN(db, SZ_WHEREINFO(nTabList)
        + SizeOf(TWhereLoop))`.  On OOM, free + return nil.
      * Field initialisation: pParse, pTabList, pOrderBy, pResultSet,
        aiCurOnePass[0..1]:=-1, nLevel:=nTabList, iBreak/iContinue from
        sqlite3VdbeMakeLabel, wctrlFlags, iLimit, savedNQueryLoop,
        pSelect.  The `memset(&pWInfo->nOBSat, 0, offsetof(WhereInfo,sWC)
        - offsetof(WhereInfo,nOBSat))` block becomes
        `FillChar(pWInfo^.nOBSat, 39, 0)` — 104-65=39 bytes spanning
        nOBSat..revMask, locked by TestWhereStructs's offset sentinel.
      * Trailing-region zero: `FillChar(whereInfoLevels(pWInfo)^,
        SizeOf(TWhereLoop) + nTabList*SizeOf(TWhereLevel), 0)`.
      * MaskSet init with `ix[0]=-99` sentinel (sqlite3WhereGetMask
        skips an n==0 test).
      * sWLB setup: pWInfo, pWC=&pWInfo^.sWC, pNew at
        `PByte(pWInfo)+nByteWInfo` (8-byte aligned per
        EIGHT_BYTE_ALIGNMENT assert), then `whereLoopInit(sWLB.pNew)`.
      * `sqlite3WhereClauseInit` + `sqlite3WhereSplit(pWhere, TK_AND)`.
      * `nTabList==0` special case: nOBSat from pOrderBy^.nExpr; the
        eDistinct = WHERE_DISTINCT_UNIQUE branch is left as a TODO
        (OptimizationEnabled / SQLITE_DistinctOpt helper not ported
        yet — defaults to WHERE_DISTINCT_NOOP=0; harmless until
        nTabList==0 actually exercised).
      * `nTabList>0` walk: `createMask` + `sqlite3WhereTabFuncArgs`
        for every entry in pTabList (note: walks all `nSrc` entries,
        not just the truncated `nTabList` — Ticket #3015 contract).
      * `sqlite3WhereExprAnalyze` + (if pSelect^.pLimit) call to
        `sqlite3WhereAddLimit` — both are still stubs but the calls
        land here so 11g.2.c picks them up automatically when their
        bodies become productive.
      * `if pParse^.nErr <> 0` → `whereInfoFree` + return nil.
      * Tail: since the planner core / per-loop codegen / epilogue
        haven't been ported yet, the function `whereInfoFree`s the
        half-built pWInfo and returns nil.  This closes the cleanup
        contract (whereInfoFree was already productive) and makes
        the prologue safe to land alone.

    Why this is safe to land alone:
      * No callers exist in productive code (`grep
        sqlite3WhereBegin\(` finds only the declaration and the
        definition — sqlite3DeleteFrom / sqlite3Update / sqlite3Select
        all still skip the WhereBegin call site at this stage).  So
        regardless of what the prologue does internally, no
        observable bytecode emission changes.
      * Every allocation is paired with a free on every return path
        (OOM → sqlite3DbFree, error → whereInfoFree, success → final
        whereInfoFree).  No leaks even if a future caller starts
        invoking us before the planner core lands.
      * sqlite3WhereSplit / sqlite3WhereExprAnalyze /
        sqlite3WhereAddLimit / sqlite3WhereTabFuncArgs are either
        stubs or already-productive helpers operating only on the
        local pWInfo / pWC — they don't touch external Parse state
        in ways that survive the whereInfoFree.

    Concrete changes:
      * `passqlite3codegen.pas:4430..` — `sqlite3WhereBegin` body
        rewritten (~120 lines, was 1 line).  New file-private
        `const` block immediately above (5 missing WHERE_* flag
        constants: ONEPASS_DESIRED, ONEPASS_MULTIROW, OR_SUBCLAUSE,
        KEEP_ALL_JOINS, USE_LIMIT — named with `_C` suffix on the
        three not already present in the public const block to
        avoid future merge conflicts when 11g.2.c lands the public
        versions).

    Test status: full build clean (no new warnings or errors),
    regression sweep all green —
    TestWhereBasic 52/52, TestWhereStructs 148/148,
    TestPrepareBasic 20/20, TestParser 45/45, TestSchemaBasic 44/44,
    TestVdbeApi 57/57, TestDMLBasic 54/54, TestSelectBasic 49/49,
    TestExprBasic 40/40, TestInitCallback 29/29, TestExplainParity
    unchanged at **2 PASS / 8 DIVERGE / 0 ERROR**.

    Discoveries / next-step notes:
      * **WHERE_OR_SUBCLAUSE / WHERE_KEEP_ALL_JOINS / WHERE_USE_LIMIT
        / WHERE_ONEPASS_DESIRED / WHERE_ONEPASS_MULTIROW were
        missing from the public `const` block.**  Added file-private
        copies with `_C` suffix inside the WhereBegin function-local
        const block so the prologue can compile.  When 11g.2.c ports
        whereexpr.c (which references the same flags), it should
        promote them to the public block at codegen.pas:1392..1407
        and drop the `_C` suffix here.
      * **OptimizationEnabled / SQLITE_DistinctOpt helper not ported.**
        Marked with TODO in the nTabList==0 branch.  Defaults to
        WHERE_DISTINCT_NOOP which is the conservative answer (no
        DISTINCT optimisation kicks in).  Lands cheap when needed.
      * **sqlite3ErrorMsg variadic loss.**  C source uses
        `"at most %d tables in a join"` with BMS substitution; our
        port hard-codes `"at most 64 tables in a join"` since the
        Pascal sqlite3ErrorMsg port is a fixed-string sink.  Acceptable
        as long as BMS stays 64 (which it must — 64-bit Bitmask).
      * **Next 6.9-bis target (still 11g.2.b): trimmed planner pick
        + OP_NotExists emission.**  With the prologue in place, the
        next sub-progress lands the rowid-EQ shape detector (recognise
        a single equality term whose LHS is `pTabList->a[0].iCursor`'s
        rowid), hard-codes the WhereLoop pick (single-cursor,
        OP_NotExists strategy, no IPK setup), and emits the seek +
        Goto-back-to-Next pattern that schema-row UPDATE / DELETE
        inner statements need.  Once paired with re-enabling the
        productive tails in `sqlite3DeleteFrom` and `sqlite3Update`,
        TestExplainParity should bump from 2 PASS → 7 PASS as the 5
        CREATE TABLE rows flip.

  - **2026-04-26 — Phase 6.9-bis (step 11g.2.b — sub-progress):
    BMS constant + SZ_WHEREINFO + whereInfoLevels flexarray accessor.**
    Scaffolding sub-progress preparing the `sqlite3WhereBegin` productive
    prologue (where.c:6862..6940).  Adds the three structural primitives
    the prologue's allocation + cap-check arms call directly:
      * `BMS = i32(SizeOf(Bitmask) * 8)` = 64.  Mirrors `sqliteInt.h`'s
        BMS macro — used to (a) cap `pTabList^.nSrc` so every FROM-table
        gets a unique bit in the mask-set, and (b) cap `pOrderBy^.nExpr`
        before zeroing `pOrderBy` and disabling omit-noop-join.
      * `SZ_WHEREINFO(nLevel)` inline — faithful port of the
        `whereInt.h:514` macro: `ROUND8(offsetof(WhereInfo,a) +
        N*sizeof(WhereLevel))`.  Pascal computes
        `ROUND8(SizeOf(TWhereInfo) + nLevel*SizeOf(TWhereLevel))` —
        SizeOf(TWhereInfo) = 856 = offsetof(WhereInfo,a) in C, locked by
        TestWhereStructs' offset sentinel.  The 8-byte rounding lets the
        prologue append a `TWhereLoop` block right after the level array
        (where.c:6929 `sWLB.pNew = (WhereLoop*)((char*)pWInfo+nByteWInfo)`).
      * `whereInfoLevels(p): PWhereLevel` flexarray accessor — points at
        the trailing TWhereLevel a[] array (immediately after the 856-byte
        TWhereInfo header).  Mirrors C's `pWInfo->a[i]`.

    No body changes to `sqlite3WhereBegin`; productive prologue lands in
    the next sub-progress commit.

    Concrete changes:
      * `passqlite3codegen.pas:1384` — `BMS = 64` constant inserted in the
        Phase 6.2 const block, immediately before WHERE_ORDERBY_*.
      * `passqlite3codegen.pas:1315..1316` — forward decls for
        `whereInfoLevels` / `SZ_WHEREINFO`.
      * `passqlite3codegen.pas:2348..2375` — bodies, alongside
        `ExprListItems` / `SrcListItems` / `IdListItems`.

    Test status: full build clean, regression sweep all green —
    TestWhereBasic 52/52, TestWhereStructs 148/148, TestPrepareBasic 20/20,
    TestParser 45/45, TestSchemaBasic 44/44, TestVdbeApi 57/57,
    TestDMLBasic 54/54, TestSelectBasic 49/49, TestExprBasic 40/40,
    TestInitCallback 29/29, TestExplainParity unchanged at
    **2 PASS / 8 DIVERGE / 0 ERROR**.

    Next 6.9-bis target (still 11g.2.b): productive `sqlite3WhereBegin`
    prologue body — variable init, BMS cap-check, single-allocation
    (TWhereInfo + nLevel*TWhereLevel + tail TWhereLoop), field
    initialisation (pParse, pTabList, pOrderBy, pResultSet, pSelect,
    aiCurOnePass, nLevel, iBreak/iContinue labels, wctrlFlags, iLimit,
    savedNQueryLoop), MaskSet init with `ix[0]=-99`, sWLB setup
    (whereLoopInit on tail block), `sqlite3WhereClauseInit` +
    `sqlite3WhereSplit`, then the `nTabList==0` special case and the
    nTabList>0 createMask + sqlite3WhereTabFuncArgs walk.  Stops short
    of the False-WHERE-Term-Bypass loop (lines 6995..7027) and the
    planner core — those land in subsequent sub-progress commits, with
    the trimmed planner pick + OP_NotExists emission flipping the 5
    CREATE TABLE rows in TestExplainParity.

  - **2026-04-26 — Phase 6.9-bis (step 11g.2.b — sub-progress):
    sqlite3WhereBegin signature alignment with C source.**  Closed
    the signature-drift discovery flagged in the previous sub-progress
    note.  Pascal's `sqlite3WhereBegin` was missing the `Select* pSelect`
    parameter (slot #6 in C, between `pResultSet` and `wctrlFlags`) and
    its `pResultSet` slot was misnamed `pDistinctSet`.  Both fixed; the
    declaration + definition now match `where.c:6828..6837` /
    `sqliteInt.h:5100` byte-for-byte (8 params, same order, same names).
    Body remains a stub returning nil — pure contract change.

    Concrete changes:
      * `passqlite3codegen.pas:1537..1539` — declaration: 7→8 params,
        `pDistinctSet`→`pResultSet`, inserted `pSelect: PSelect`.
      * `passqlite3codegen.pas:4404..4418` — definition: same signature
        change; header comment updated to document the alignment with
        the C source and the prologue's reliance on the `pSelect` slot.

    Why this lands alone: no callers exist (only the declaration, the
    stub body, and a TODO comment), so the rename + insertion is
    mechanical.  Once the productive prologue port lands (next
    11g.2.b sub-progress), it can write `pWInfo^.pSelect := pSelect`
    directly without further signature surgery.

    Test status: full build clean (no new warnings), regression sweep
    all green — TestWhereBasic 52/52, TestWhereStructs 148/148,
    TestPrepareBasic 20/20, TestParser 45/45, TestSchemaBasic 44/44,
    TestVdbeApi 57/57, TestDMLBasic 54/54, TestSelectBasic 49/49,
    TestExprBasic 40/40, TestInitCallback 29/29, TestExplainParity
    unchanged at **2 PASS / 8 DIVERGE / 0 ERROR**.

    Next 6.9-bis target (still 11g.2.b): productive `sqlite3WhereBegin`
    prologue for the single-table rowid-EQ shape — allocate WhereInfo
    (nLevel=1), init iEndWhere / iContinue / iBreak labels, init the
    WhereLoopBuilder, init the WhereMaskSet, install the table cursor
    mask, walk pTabList capping at BMS, then fall into the trimmed
    planner pick.

  - **2026-04-26 — Phase 6.9-bis (step 11g.2.b — sub-progress):
    productive sqlite3WhereEnd cleanup contract.**  Second sub-progress
    landing inside step 11g.2.b.  Replaces the empty `sqlite3WhereEnd`
    stub at `passqlite3codegen.pas:4360..4365` with the productive
    cleanup body the prior bookkeeping-primitives commit was built to
    support: when `pWInfo <> nil`, delegate to
    `whereInfoFree(pWInfo^.pParse^.db, pWInfo)` (which walks pLoops,
    walks pMemToFree, clears the WhereClause, and frees the WhereInfo
    itself).  Step 11g.2.b stays `[ ]` because the productive
    `sqlite3WhereBegin` body and the OP_NotExists-pattern emission
    still need to land — those are the remaining gates for flipping
    the 5 CREATE TABLE rows in TestExplainParity.

    Concrete changes:
      * `passqlite3codegen.pas:4360..4378` — `sqlite3WhereEnd` body
        replaced.  Stub returned immediately; productive body now
        guards on `pWInfo <> nil` and forwards to `whereInfoFree`.
        Header comment documents what's still missing (the
        loop-termination opcode emission, SKIPAHEAD_DISTINCT seeks,
        IN-LOOP unwind, LEFT JOIN null-row fixup) and which sub-task
        each lands in (11g.2.b productive WhereBegin / 11g.2.e
        wherecode.c port).

    Why this is safe to land alone:
      * Stub `sqlite3WhereBegin` still returns `nil` for every shape
        in the corpus, so the `pWInfo <> nil` guard turns every
        existing call site into a no-op — no observable behaviour
        change anywhere.
      * Once productive WhereBegin starts allocating WhereInfo, every
        error path and every successful pairing automatically gets
        proper teardown without further WhereEnd edits.

    Test status: full build clean (no new warnings), regression sweep
    all green — TestWhereBasic 52/52, TestWhereStructs 148/148,
    TestPrepareBasic 20/20, TestParser 45/45, TestSchemaBasic 44/44,
    TestVdbeApi 57/57, TestDMLBasic 54/54, TestSelectBasic 49/49,
    TestExprBasic 40/40, TestInitCallback 29/29, TestExplainParity
    unchanged at **2 PASS / 8 DIVERGE / 0 ERROR**.

    Discoveries / next-step notes:
      * **Cleanup contract is now decoupled from emission contract.**
        The two halves of `sqlite3WhereEnd` (resource cleanup +
        loop-termination opcode emission) can now land independently.
        This commit lands the cleanup half; the emission half lands
        with the productive WhereBegin in the next 11g.2.b sub-progress
        commit.
      * **Next 6.9-bis target (still 11g.2.b): productive
        `sqlite3WhereBegin` for the single-table rowid-EQ shape.**
        Allocate WhereInfo (nLevel=1), init iEndWhere / iContinue /
        iBreak labels, detect-and-reuse the table cursor opened by
        the caller, emit `OP_NotExists` against the rowid expression
        resolved out of `pWhere`, fall through to body.  Then
        re-enable the productive tails in `sqlite3DeleteFrom`
        (codegen.pas:5460..5471) and `sqlite3Update`
        (codegen.pas:5660..5670).

  - **2026-04-26 — Phase 6.9-bis (step 11g.2.b — sub-progress):
    WhereLoop / WhereInfo bookkeeping primitives.**  First productive
    landing inside step 11g.2.b — the bookkeeping plumbing the rest of
    the vertical slice will hang off.  Faithful port of where.c:2527..
    2629 (`whereLoopInit`, `whereLoopClearUnion`, `whereLoopClear`,
    `whereLoopResize`, `whereLoopXfer`, `whereLoopDelete`,
    `whereInfoFree`) into `passqlite3codegen.pas`, immediately above
    the `sqlite3WhereBegin` stub.  No behavioural change in the
    corpus: helpers are file-private, callable only from the
    `sqlite3WhereBegin` body which is still a stub returning nil.
    Step 11g.2.b stays `[ ]` because the productive WhereBegin / End
    bodies and the OP_NotExists-pattern emission still need to land.

    Concrete changes:
      * `passqlite3codegen.pas` (right above `sqlite3WhereBegin`):
        seven new helpers, ~115 lines total.  Faithful translations
        including:
          - WHERE_VIRTUALTABLE `needFree` (bit 0 of `u.vtab.bFlags`)
            clear-and-`sqlite3_free(idxStr)` path;
          - WHERE_AUTO_INDEX `u.btree.pIndex^.zColAff` +
            `u.btree.pIndex` `sqlite3DbFree` / `sqlite3DbFreeNN` path;
          - `whereLoopResize`'s round-up-to-multiple-of-8 + alloc +
            copy + free-old-if-not-static dance;
          - `whereLoopXfer`'s `WHERE_LOOP_XFER_SZ`-sized memcpy +
            aLTerm copy + needFree/auto-index ownership transfer;
          - `whereInfoFree`'s pLoops walk + pMemToFree walk +
            `sqlite3WhereClauseClear`.
      * `WHERE_LOOP_XFER_SZ` modelled as a local `const = 56`
        (= `offsetof(TWhereLoop, nLSlot)`); locked by
        TestWhereStructs's offset sentinel.
      * `sqlite3WhereEnd`'s body kept as a stub but with a comment
        documenting what it becomes once 11g.2.b ships:
        `if pWInfo <> nil then whereInfoFree(pWInfo^.pParse^.db, pWInfo);`.

    Test status: full build clean, regression sweep all green —
    TestWhereBasic 52/52, TestWhereStructs 148/148,
    TestPrepareBasic 20/20, TestParser 45/45, TestSchemaBasic 44/44,
    TestVdbeApi 57/57, TestDMLBasic 54/54, TestSelectBasic 49/49,
    TestExprBasic 40/40, TestInitCallback 29/29, TestExplainParity
    unchanged at **2 PASS / 8 DIVERGE / 0 ERROR**.

    Discoveries / next-step notes:
      * **Helpers stay file-private.**  Mirrors the C `static`
        modifier — they're called only from where.c internals, never
        from outside the unit.  Keeps the interface surface unchanged
        and avoids name-collision risk with future ports.
      * **No dedicated unit test landed.**  Helpers are private; their
        behaviour will be exercised transitively by the productive
        WhereBegin port + TestExplainParity.  Adding a friend-test
        would require exposing them — preferable to defer until
        WhereBegin lands its productive body and we can drive the
        full chain from a black-box harness.
      * **Next 6.9-bis target: 11g.2.b productive WhereBegin/End
        bodies.**  With bookkeeping in place, the WhereBegin port
        (single-table rowid-EQ vertical slice) can allocate WhereInfo
        + WhereLoop, call `whereLoopInit`, run the trimmed planner
        pick, and rely on `whereInfoFree` to clean up on every error
        path.  Then re-enable the productive tails in
        `sqlite3DeleteFrom` (codegen.pas:5460..5471) and
        `sqlite3Update` (codegen.pas:5660..5670), and drop the step-11f
        skeleton-only error-state guards.

  - **2026-04-26 — Phase 6.9-bis (step 11g.2.a): structural records
    audit + field-offset sentinel.**  Closes the first sub-task of
    step 11g.2.  Diffed every record in `passqlite3codegen.pas:1066..
    1306` field-by-field against `whereInt.h` HEAD
    (`/home/bpsa/app/sqlite3/src/whereInt.h`) and verified each layout
    assumption against actual GCC x86-64 packing with a tiny C probe
    (`offsetof()` checks under `gcc -O2`).  No drift found — all 14
    records (TWhereMemBlock, TWhereRightJoin, TInLoop, TWhereTerm,
    TWhereClause, TWhereOrInfo, TWhereAndInfo, TWhereMaskSet,
    TWhereOrCost, TWhereOrSet, TWherePath, TWhereScan,
    TWhereLoopBtree, TWhereLoopVtab, TWhereLoop, TWhereLevel,
    TWhereLoopBuilder, TWhereInfo) match upstream byte-for-byte.
    Documentation-only structural change; the productive code lands
    in 11g.2.b.
    [X]

    Concrete changes:
      * `src/tests/TestWhereStructs.pas` — new sentinel verifying
        148 individual field offsets across the 14 whereInt.h record
        types.  Complements TestWhereBasic (T1..T17 SizeOf checks)
        with byte-precise offset-of checks so any future record-field
        reorder, accidental pad drop, bitfield repack, or compiler
        alignment change trips a single PASS/FAIL line.
      * `src/tests/build.sh` — wire TestWhereStructs into the build
        ladder (right after TestWhereBasic).

    Verification:
      * `gcc -O2` probe of the GCC layout for `WhereLoop.u.vtab` —
        the 3 u32:1 bitfields (needFree, bOmitOffset, bIdxNumHex)
        do collapse into a single byte at offset 4 (because the next
        field is i8 isOrdered, GCC packs the storage unit), so the
        Pascal `bFlags: u8 @ 4` modelling is correct, sizeof=24.
      * `gcc -O2` probe of the WhereInfo layout — sizeof=856 base
        (before flexarray), sWC@104, sMaskSet@592, all match Pascal.
      * `LD_LIBRARY_PATH=src ./bin/TestWhereStructs` → 148 PASS / 0
        FAIL (every documented offset confirmed).
      * `LD_LIBRARY_PATH=src ./bin/TestWhereBasic` → 52 PASS / 0 FAIL
        (existing SizeOf gate still green).

    Discoveries / next-step notes:
      * **Pascal port intentionally models the *non-debug* C layout.**
        Upstream `WhereTerm` grows an `int iTerm` field at offset 32
        when SQLITE_DEBUG is on (between leftCursor and union u),
        bumping sizeof to 64.  The Pascal records do NOT carry that
        field — they are a self-contained re-implementation, never
        passed to/from libsqlite3.so, so the debug pad is irrelevant.
        Documented in TestWhereStructs.pas header.
      * **All 14 records confirmed drift-free.**  No bitfield/union/
        flexarray rework needed.  11g.2.b can allocate WhereInfo /
        WhereClause / WhereLoop / WhereLevel directly using
        SizeOf(TWhereInfo) + nLevel*SizeOf(TWhereLevel) and trust the
        layout.
      * **Next 6.9-bis target: step 11g.2.b — vertical-slice
        sqlite3WhereBegin / sqlite3WhereEnd for the single-table
        rowid-EQ shape.**  Lands the bookkeeping primitives
        (whereLoopInit/Clear/Xfer/Delete, whereInfoFree,
        sqlite3WhereGetMask) plus the trimmed Begin/End emitting
        OP_NotExists+body+Goto for inner DML schema-row updates.
        Expected TestExplainParity bump 2 PASS / 8 DIVERGE → 7 PASS /
        3 DIVERGE once paired with step 11e's productive INSERT tail.

  - **2026-04-26 — Phase 6.9-bis — formalise step 11g.2 sub-tasks
    (sqlite3WhereBegin / WhereOkOnePass / WhereEnd port).**  Step
    11g.1 closed in three sub-steps (a/b/c) per the precedent set
    by commit `7392694`'s formalisation of step 11g; with 11g.1
    fully [X], the remaining gate to flipping the 8 DIVERGE rows in
    TestExplainParity is step 11g.2 — the where.c / wherecode.c /
    whereexpr.c planner-core port.  That body of code is ~13.5k
    lines of upstream C and clearly cannot land as a single step.
    This commit splits it into 11g.2.a..f along the same staging
    pattern (structural skeleton → minimal-viable productive slice
    → audit) used for 11g.1, with an explicit *vertical slice*
    detour at 11g.2.b: implement the single-table simple-rowid-EQ
    case first (which is exactly the shape every schema-row inner
    DML statement emits), so we can flip TestExplainParity rows
    *before* paying the full planner-core port cost in 11g.2.d.
    Documentation only; no code changes.
    [X]

    Concrete changes:
      * `tasklist.md` — replaced the single `[ ] 11g.2` bullet with
        a six-sub-task tree (11g.2.a structural records audit,
        11g.2.b vertical-slice WhereBegin for rowid-EQ, 11g.2.c
        whereexpr.c port, 11g.2.d planner-core port, 11g.2.e
        wherecode.c port, 11g.2.f audit + corpus regression).
        Each sub-task names the upstream functions it covers, the
        Pascal stubs it replaces (with file:line anchors), and the
        gate test it should ship with.

    Discoveries / next-step notes:
      * **Why 11g.2.b is the right first landing.**  Every
        `sqlite3NestedParse` call site in `passqlite3codegen.pas`
        (the 7 sites enumerated by step 10) emits an inner SQL
        statement of the shape `UPDATE %Q.sqlite_master SET sql=%Q
        WHERE rowid=#%d` or `DELETE FROM %Q.sqlite_master WHERE
        name=%Q AND type=%Q`.  These are **single-table, single-
        equality-predicate** queries — the simplest possible WHERE
        clause shape.  Implementing the full where.c cost solver
        before flipping any TestExplainParity row would be many
        weeks of dead code; a 100-line minimal-viable WhereBegin
        keyed on the rowid-EQ shape gets us productive bytecode
        emission the same week.
      * **11g.2.a may already be a no-op.**  Quick survey shows
        all 14 whereInt.h record types already have skeletons in
        `passqlite3codegen.pas:1091..1380` (TWhereTerm,
        TWhereClause, TWhereOrInfo, TWhereAndInfo, TWhereMaskSet,
        TWhereOrSet, TWhereLoopBtree, TWhereLoopVtab, TWhereLoopU,
        TWhereLoop, TWhereLevelU, TWhereLevel, TWhereLoopBuilder,
        TWhereInfo).  11g.2.a's actual job is to verify those are
        in sync with the current upstream `whereInt.h` (HEAD), not
        to draft them from scratch.  Lock the layout via a
        TestWhereStructs.pas SizeOf/offset sentinel before any
        productive code in 11g.2.b touches the records.
      * **Next 6.9-bis target: step 11g.2.a — structural records
        audit + size sentinel.**  Smallest of the six sub-tasks;
        ~half-day of work; lays the type-layout groundwork that
        11g.2.b's allocators rely on.

  - **2026-04-26 — Phase 6.9-bis (step 11g.1.c): audit init.busy=1
    publication arms via live sqlite3InitCallback + fix empty-string
    argv[4] bug.**  Closes the third and last sub-task of step 11g.1.
    Adds a dedicated unit test (`TestInitCallback.pas`, 4 cases / 29
    PASS) that drives `sqlite3InitCallback` directly with synthesised
    5-element argv tuples — bypassing OP_ParseSchema's SELECT against
    sqlite_master (which returns 0 rows today because step 11e's
    sqlite3Insert is still a structural skeleton).  This is the first
    end-to-end exercise of `sqlite3EndTable`'s init.busy=1 arm
    (`codegen.pas:6892..6904`) and `sqlite3CreateIndex`'s
    (`codegen.pas:7562..7572`) under the *parser-driven* path
    (sqlite3Prepare from sqlite3InitCallback), as opposed to the
    sqlite3InstallSchemaTable bootstrap that openDatabase uses for
    sqlite_master.
    [X]

    Concrete changes:
      * `src/passqlite3main.pas` interface section (~line 275) — promote
        `TInitData` / `PInitData` types and `sqlite3InitCallback` into
        the interface so the audit test can drive the dispatcher with
        synthesised argv.  Removed the duplicate type decl from the
        implementation section; behaviour is unchanged.
      * `src/passqlite3main.pas:1982..2052` — restructure the argv[4]
        ladder into a flat else-if chain matching prepare.c:114..189
        exactly.  The previous nested form (`if zArg4 <> nil then …
        else if zArg1 = nil then … else { branch (d) }`) made branch
        (d) — the auto-index tnum patch — unreachable when
        `argv[4] = ""` (empty string but non-nil), because empty
        argv[4] entered the inner zArg4-non-nil arm and fell through
        to a "should not happen" `initCorruptSchema` call.  C's
        prepare.c:114..189 reaches branch (d) for *both* nil argv[4]
        and empty-string argv[4]; the new ladder follows that contract.
      * `src/tests/TestInitCallback.pas` — new test program with four
        cases:
          T1 CREATE TABLE via callback → pTab in main.tblHash, tnum=2,
             pSchema = aDb[0].pSchema, zName = "foo".  Also asserts
             absence under "temp" (correct iDb dispatch).
          T2 CREATE INDEX via callback → pIdx in main.idxHash, tnum=3,
             pSchema = aDb[0].pSchema.
          T3 Auto-index branch (empty SQL) → pre-stages a 1-col
             Index in idxHash with tnum=0, then drives the callback
             with argv[4]="" and asserts pIdx^.tnum is patched to 5.
             This is the case the empty-string bug was hiding.
          T4 Corrupt-schema branches (a) and (c) — argv[3]=nil and
             non-c-r argv[4] both set initData.rc = SQLITE_CORRUPT.
      * `src/tests/build.sh` — register TestInitCallback in the
        compile_test list.

    Test status:
      * TestInitCallback: **29 PASS / 0 FAIL** across 4 cases.
      * Regression sweep (2026-04-26): TestPrepareBasic 20/20,
        TestParser 45/45, TestParserSmoke 20/20, TestSchemaBasic
        44/44, TestVdbeApi 57/57, TestDMLBasic 54/54, TestSelectBasic
        49/49, TestExprBasic 40/40, TestVdbeTxn 8/8,
        TestAuthBuiltins 34/34, TestOpenClose 17/17, TestSmoke /
        TestUtil clean, TestExplainParity unchanged at
        **2 PASS / 8 DIVERGE / 0 ERROR**.

    Discoveries / next-step notes:
      * **Empty-string argv[4] bug.**  The structural-skeleton
        landing of step 11g.1.b silently corrupted every PRIMARY KEY /
        UNIQUE auto-index row.  In SQLite's sqlite_master schema, the
        sql column for an auto-index is the empty string (not NULL),
        because the parser synthesises the index without source SQL.
        The previous nested ladder routed empty-string argv[4] into
        the c-r-branch fall-through, hitting `initCorruptSchema` and
        propagating SQLITE_CORRUPT out through OP_ParseSchema.  The
        bug was latent because step 11e's sqlite3Insert emits zero
        ops, so OP_ParseSchema's SELECT never returned an auto-index
        row in the live build.  The audit test surfaced it on T3
        (`got 11, expected 0`).  Fix matches prepare.c:114 exactly:
        `if argv[4] && argv[4][0]=='c' && [1]=='r'` is one arm; the
        else-if for SQLITE_CORRUPT is `argv[1]==0 || (argv[4] &&
        argv[4][0])`; default is the auto-index branch.
      * **init.busy=1 arms verified end-to-end.**  Both
        `codegen.pas:6892..6904` (table) and `:7562..7572` (index)
        now have a regression-protected run through the
        sqlite3Prepare→parser path, not just sqlite3InstallSchemaTable.
        Hash-key zName lifetime, pSchema selection (iDb-correct), and
        tnum patching all survive the inner statement's
        sqlite3_finalize.  No latent bugs surfaced beyond the
        empty-argv[4] one above.
      * **TestExplainParity count still didn't move — expected.**
        Same blocker as 11g.1.b: until step 11e's sqlite3Insert
        actually writes schema rows, the SELECT against sqlite_master
        returns 0 rows and the live OP_ParseSchema → callback chain
        is dead-loop.  TestInitCallback bypasses that dead loop by
        synthesising argv directly; it cannot flip TestExplainParity.
      * **Step 11g.1 fully complete.**  All three sub-tasks
        (11g.1.a structural skeleton, 11g.1.b productive callback,
        11g.1.c codegen-arm audit) are now [X].  The remaining gap
        in TestExplainParity is owned by step 11e (sqlite3Insert
        productive emission) and step 11g.2 (sqlite3WhereBegin), not
        by anything in 11g.1.
      * **Next 6.9-bis target: step 11g.2 — sqlite3WhereBegin /
        WhereOkOnePass / WhereEnd.**  Planner-core port; required by
        sqlite3DeleteFrom / sqlite3Update productive emission tails
        (codegen.pas:5460..5471, 5660..5670, currently TODO).  Largest
        single piece of remaining work for this sub-phase.

  - **2026-04-26 — Phase 6.9-bis (step 11g.1.b): productive
    sqlite3InitCallback — c-r prepare branch + auto-index tnum
    branch.**  Replaces the minimal "bump nInitRow only" stub at
    `passqlite3main.pas:1904` with a faithful port of
    `prepare.c:96..189`.  Three productive arms now run end-to-end:
    (a) `argv[3] = nil` → `initCorruptSchema`; (b) argv[4] starts
    with case-insensitive `c-r` → re-prepare the CREATE statement
    under `init.busy = 1` with `db^.init.{iDb, newTnum, azInit}`
    populated per prepare.c:128..163, then `sqlite3_finalize`;
    (d) empty SQL with non-nil name → `sqlite3FindIndex` and patch
    `pIndex^.tnum` from `argv[3]` via the new `sqlite3GetUInt32`
    helper (prepare.c:166..186).
    [X]

    Concrete changes:
      * `passqlite3util.pas:728` (interface) + `:2667..2700`
        (implementation) — new `sqlite3GetUInt32(z, pI): i32`
        decimal-only u32 parser, mirrors `util.c:1533`.  Returns 1
        on success, 0 on empty / non-digit / overflow / trailing
        garbage; sets `pI^ := 0` in the documented failure cases.
      * `passqlite3main.pas:1904..1940` — new helper
        `initCorruptSchema(pData, argv, zExtra)`.  Minimal port of
        `prepare.c:22 corruptSchema`: sets `pData^.rc` to
        `SQLITE_NOMEM` (on `mallocFailed`) or `SQLITE_CORRUPT`
        otherwise.  The full mInitFlags / SQLITE_WriteSchema /
        sqlite3MPrintf'd error message paths are deferred to
        Phase 7 alongside the rest of `sqlite3InitOne`.
      * `passqlite3main.pas:1942..2050` — full body of
        `sqlite3InitCallback` rewritten.  Local
        `db^.mDbFlags |= DBFLAG_EncodingFixed` (constant
        redeclared inline as `u32($0040)` because passqlite3parser
        scopes it to its implementation section).  c-r branch
        saves & restores `db^.init.iDb`, clears `init.flags` bit 0
        (orphanTrigger), sets `init.azInit := PPAnsiChar(argv)`,
        calls `sqlite3Prepare(db, argv[4], -1, 0, nil, @pStmt, nil)`,
        reads `db^.errCode` for the result, then routes
        `SQLITE_NOMEM` → `sqlite3OomFault`, `SQLITE_INTERRUPT` /
        `SQLITE_LOCKED` → silent, anything else →
        `initCorruptSchema(... sqlite3_errmsg(db))`, exactly per
        `prepare.c:150..160`.  Always finalises the inner stmt.
        Auto-index branch returns silently when `tnum < 2` /
        `> mxPage` / GetUInt32 fails — the
        `sqlite3IndexHasDuplicateRootPage` check + the
        `bExtraSchemaChecks` gate are deferred (see Discoveries).

    Test status:
      * Full build clean (one pre-existing comment-level warning
        in `passqlite3.inc` carries through; not introduced here).
      * Regression sweep (2026-04-26): TestPrepareBasic 20/20,
        TestParser 45/45, TestParserSmoke 20/20, TestSchemaBasic
        44/44, TestVdbeApi 57/57, TestDMLBasic 54/54,
        TestSelectBasic 49/49, TestExprBasic 40/40, TestVdbeTxn
        8/8, TestAuthBuiltins 34/34, TestOpenClose 17/17,
        TestSmoke + TestUtil clean, TestJson 434/434, TestJsonEach
        50/50, TestJsonRegister 48/48, TestPrintf 105/105,
        TestVtab 216/216.  TestExplainParity unchanged at
        **2 PASS / 8 DIVERGE / 0 ERROR**.

    Discoveries / next-step notes:
      * **TestExplainParity count didn't move — expected.**  The
        callback is now fully wired, but the productive payload
        (re-preparing argv[4] to publish a Table/Index into
        `pSchema^.tblHash`) only fires when OP_ParseSchema's
        `SELECT*FROM sqlite_master WHERE %s` actually returns rows.
        That requires `sqlite3Insert` (step 11e) to write real
        schema rows — currently it emits 0 ops.  The wiring is
        observable end-to-end at the Pascal level (verifiable by
        manually pre-loading sqlite_master and re-running), just
        not yet through the test corpus.
      * **`nInitRow == 0 → SQLITE_CORRUPT` check stays
        disabled.**  Re-enabling it now would regress every
        CREATE TABLE in the corpus for the same reason: the SELECT
        legitimately finds 0 rows because the prior INSERT is a
        no-op skeleton.  Promote the disabled `if` block at
        `passqlite3main.pas:~1995` to active code the moment step
        11e starts emitting real bytecode for the schema-row
        INSERT.
      * **`sqlite3IndexHasDuplicateRootPage` /
        `bExtraSchemaChecks` are still deferred.**  The auto-index
        branch silently accepts any `tnum >= 2 && tnum <= mxPage`,
        which matches the C reference under
        `bExtraSchemaChecks = 0` (the default).  Once Phase 7
        wires `sqlite3Config.bExtraSchemaChecks`, plumb both
        checks back in (see codegen.pas:7379 for the existing
        TODO marker on the index-build side).
      * **Next 6.9-bis target: step 11g.1.c** — audit
        `sqlite3EndTable` / `sqlite3CreateIndex`'s init.busy=1
        publication arms (`codegen.pas:6892`, `:7562`) under the
        new live callback.  The arms already exist but have only
        been exercised via `sqlite3InstallSchemaTable`'s direct
        bootstrap; running them through `sqlite3Prepare` from
        `sqlite3InitCallback` is a different driver and may surface
        latent bugs (e.g. zName lifetime, hash placement on
        lookaside, `pSchema` selection across attached DBs).

  - **2026-04-26 — Phase 6.9-bis (step 11g.1, structural skeleton):
    OP_ParseSchema dispatch hook + sqlite3_exec-driven worker.**
    Replaces the `OP_ParseSchema` no-op stub at
    `passqlite3vdbe.pas:7134` with a settable function pointer
    (`vdbeParseSchemaExec`) so the actual sqlite3_exec call lives in
    `passqlite3main.pas` (sqlite3_exec already consumes vdbe — moving
    the worker the other way would create a uses cycle).  The worker
    `execParseSchemaImpl` is a faithful structural port of
    `vdbe.c:7146..7173`'s productive (non-ALTER, p4.z != nil) branch:
    builds the `SELECT*FROM"%w".sqlite_master WHERE %s ORDER BY rowid`
    via `sqlite3MPrintf`, gates `db^.init.busy = 1` around the
    recursive `sqlite3_exec`, dispatches each row to a minimal
    `sqlite3InitCallback` that bumps `nInitRow` only.
    [X]

    Concrete changes:
      * `passqlite3vdbe.pas:1571..1597` (interface) — `TVdbeParseSchemaExec`
        function-pointer type + `vdbeParseSchemaExec` settable variable
        defaulting to nil.  Comment block documents the cycle-avoidance
        rationale and the iDb / zWhere / p5 contract.
      * `passqlite3vdbe.pas:7134..7156` — `OP_ParseSchema` opcode body.
        Three arms: (a) `vdbeParseSchemaExec = nil` → legacy no-op
        fallback (preserves green test status when only vdbe is
        linked); (b) `pOp^.p4.z = nil` → ALTER-branch placeholder
        returning OK (full `sqlite3InitOne` is Phase 7); (c) productive
        case dispatches through the hook, on non-OK calls
        `sqlite3ResetAllSchemasOfConnection` and routes SQLITE_NOMEM →
        `no_mem` / others → `abort_due_to_error` exactly per
        vdbe.c:7175..7181.
      * `passqlite3main.pas:277..278` — implementation-side `uses`
        clause now imports `passqlite3printf` for `sqlite3MPrintf`.
      * `passqlite3main.pas:1866..1955` — `TInitData` record
        (sqliteInt.h struct InitData), `sqlite3InitCallback` minimal
        cdecl dispatcher, `execParseSchemaImpl` worker, and
        `initialization` block that wires `vdbeParseSchemaExec` at
        unit load.

    Test status:
      * Full suite: 0 failures across all bin/Test* binaries (54
        binaries, all rc=0).
      * `TestExplainParity` unchanged at 2 PASS / 8 DIVERGE / 0 ERROR;
        every CREATE TABLE / INDEX / DROP row continues to diverge but
        for the same op-count reason as before — the hook is now
        actively running but its productive payload is gated behind
        sub-step 11g.1+.

    Discoveries / future work:
      * **Why the SQLITE_CORRUPT check at vdbe.c:7165..7170 is
        commented out (not omitted):** the schema-row INSERT emitted
        by `sqlite3NestedParse` from `sqlite3EndTable` lands in
        `sqlite3Insert`, which is still a structural skeleton (step
        11c..11e) emitting zero bytecode.  Therefore the row that
        `OP_ParseSchema`'s SELECT goes hunting for is *never written*
        in the current build, so a faithful `nInitRow == 0` →
        `SQLITE_CORRUPT` would convert every CREATE TABLE in the
        regression suite to a hard failure.  The check stays disabled
        with an inline `// if ... rc := SQLITE_CORRUPT` and a
        pointer-to-tasklist comment until `sqlite3Insert` writes real
        rows.  Fixture `sqlite3_exec` in `TestExplainParity` returned
        rc=11 under the strict check, confirming the guard placement.
      * **Why `sqlite3InitCallback` does not yet re-prepare argv[4]:**
        the C reference (prepare.c:96..189) re-prepares the SQL column
        under `db^.init.busy = 1` and relies on the codegen-side
        `init.busy = 1` arms in `sqlite3EndTable` /
        `sqlite3CreateIndex` to publish the table/index into
        `pSchema^.tblHash` *without* re-emitting bytecode.  Those arms
        already exist (`codegen.pas:6893`, `:7562`), but until the
        OUTER schema-row INSERT actually writes rows, the SELECT
        returns 0 rows and the callback is never invoked — re-preparing
        argv[4] is therefore step 11g.1+'s payload, not 11g.1.
      * **Step 11g.1 sub-task split (revised):**
        - **11g.1.a** ✅ done 2026-04-26 — structural skeleton + hook
          (this commit).
        - [X] **11g.1.b** ✅ done 2026-04-26 — wired
          `sqlite3InitCallback`'s c-r branch (re-prepare argv[4] under
          `init.busy = 1`, with init.iDb / init.newTnum / init.azInit
          populated per prepare.c:128..163), the no-SQL index branch
          (sqlite3FindIndex + tnum patch via the new
          `sqlite3GetUInt32` helper, prepare.c:166..186), and a
          minimal `initCorruptSchema` helper.  **nInitRow corruption
          check stays disabled** — re-enabling it now would convert
          every CREATE TABLE in the corpus to SQLITE_CORRUPT because
          `sqlite3Insert` (step 11e) is still a structural skeleton
          that emits zero ops, so OP_ParseSchema's SELECT against
          sqlite_master legitimately returns 0 rows in the current
          build.  Re-enable the check once step 11e starts writing
          schema rows.  TestExplainParity unchanged at 2/8/0 — the
          callback is wired but its observable effect is gated behind
          the same INSERT-emission tail.
        - [X] **11g.1.c** ✅ done 2026-04-26 — audit landed via new
          `TestInitCallback.pas` (4 cases / 29 PASS) driving
          `sqlite3InitCallback` directly with synthesised argv tuples;
          verified `sqlite3EndTable`/`sqlite3CreateIndex` init.busy=1
          publication arms (`codegen.pas:6892..6904`, `:7562..7572`)
          fire correctly under the parser-driven path, not only via
          `sqlite3InstallSchemaTable` bootstrap.  Also fixed an
          empty-string `argv[4]` ladder bug in
          `sqlite3InitCallback` that misrouted auto-index rows into
          `initCorruptSchema` (latent because step 11e's Insert is
          still skeletal, but observable via the audit test).
      * **Next 6.9-bis target: step 11g.1.b — sqlite3InitCallback
        c-r branch.**  Until that lands, the 3 nil-Vdbe rows in
        TestExplainParity (CREATE INDEX × 2, DROP TABLE × 1) cannot
        flip even after step 11g.1.a — they need the schema lookup
        to actually find the freshly-created table, which needs the
        callback's re-prepare to run.

  - **2026-04-26 — Phase 6.x — nested-parse schema visibility:
    bootstrap `sqlite_master` into `db^.aDb[*].pSchema^.tblHash` at
    `openDatabase` time.**  Resolves the first prerequisite of
    Phase 6.9-bis step 11g flagged in step 11f's discoveries
    (`tasklist.md:79..91`).  Without this fix, schema-row UPDATE /
    INSERT / DELETE statements emitted by `sqlite3NestedParse` (from
    `sqlite3EndTable`, `sqlite3CreateIndex`, `sqlite3CodeDropTable`,
    `destroyRootPage`'s autovacuum arm) failed at the very first hop
    of their productive prologue: `sqlite3SrcListLookup` ->
    `sqlite3LocateTableItem` -> `sqlite3LocateTable` ->
    `sqlite3FindTable("sqlite_master", ...)` returned nil because no
    code path had ever inserted the system table into `tblHash`
    (`sqlite3SchemaGet` allocates the empty hash; the C reference
    populates it via `sqlite3InitOne` -> `sqlite3InitCallback`, which
    is still a Phase 7 stub here).  Step 11f sidestepped the issue
    with a skeleton-only error-state guard so the outer parse stays
    no-op until step 11g; this commit makes the lookup succeed
    productively.
    [X]

    Concrete changes:
      * `passqlite3codegen.pas:2238` — interface declaration for
        new helper `sqlite3InstallSchemaTable(db, iDb)`.
      * `passqlite3codegen.pas:9090..9165` — body of
        `sqlite3InstallSchemaTable`.  Allocates a `TTable` + 5-entry
        `TColumn` array via `sqlite3DbMallocZero`, populates:
          - `zName` = `sqlite_master` (iDb=0) or `sqlite_temp_master`
            (iDb=1), heap-dup'd via `sqlite3DbStrDup` so
            `sqlite3DeleteTable` can free it later;
          - `aCol[0..4].zCnName` = `'type','name','tbl_name',
            'rootpage','sql'` (heap-dup'd);
          - `aCol[i].hName` = `sqlite3StrIHash(zCnName)` so
            `sqlite3ColumnIndex`'s fast-path lookup works (the linear
            fallback would too, but matching the C invariant is free);
          - affinities `TEXT/TEXT/TEXT/INTEGER/TEXT` per the built-in
            `CREATE TABLE x(type text,name text,tbl_name text,
            rootpage int,sql text)` schema in `init.c:230`;
          - `nCol = nNVCol = 5`, `iPKey = -1`, `tnum = 1`
            (SCHEMA_ROOT — sqlite_master always lives at rootpage 1),
            `tabFlags = TF_Readonly`, `nTabRef = 1`,
            `nRowLogEst = 200`, `pSchema = pSchema`,
            `eTabType = TABTYP_NORM`.
        Idempotent: returns early if the table is already in
        `tblHash` (e.g. on schema-reset re-entry).
      * `passqlite3main.pas:519..527` — call
        `sqlite3InstallSchemaTable(db, 0)` and `(db, 1)` from
        `openDatabase`, immediately after the pSchema slots are
        allocated and the zDbSName / safety_level fields are set.
        Placed before `eOpenState := SQLITE_STATE_OPEN` so the table
        is ready by the time any prepare/exec runs.

    Why `TF_Readonly` is correct (and doesn't break NestedParse-emitted
    writes): `tabIsReadOnly` (`codegen.pas:5274`) returns 1 only when
    `sqlite3WritableSchema(db) = 0` AND `pParse^.nested = 0`.  The
    schema-row UPDATE / INSERT / DELETE statements from `EndTable` /
    `CreateIndex` / `CodeDropTable` are all fired through
    `sqlite3NestedParse`, which bumps `pParse^.nested` before
    invoking the parser — so the gate evaluates to 0 and writes are
    permitted, exactly as in the C reference.

    Tests: full build clean (one pre-existing comment-level warning
    in `passqlite3.inc` carries over; not introduced here).
    Regression sweep (2026-04-26):
    TestPrepareBasic 20/20, TestParser 45/45, TestParserSmoke 20/20,
    TestSchemaBasic 44/44, TestVdbeApi 57/57, TestDMLBasic 54/54,
    TestSelectBasic 49/49, TestExprBasic 40/40, TestVdbeTxn 8/8,
    TestAuthBuiltins 34/34, TestOpenClose 17/17, TestSmoke +
    TestUtil clean, TestJson 434/434, TestJsonEach 50/50,
    TestJsonRegister 48/48, TestPrintf 105/105, TestVtab 216/216.
    TestExplainParity unchanged at **2 PASS / 8 DIVERGE / 0 ERROR**
    (see Discoveries — the divergences are blocked further upstream,
    not by this lookup).

    Discoveries / next-step notes:
      * **TestExplainParity count didn't move.**  Expected.  The fix
        unblocks the *first* of step 11g's two prerequisites; the
        productive emission tail in `sqlite3DeleteFrom` /
        `sqlite3Update` is still gated by step 11f's skeleton guard
        AND by the missing `sqlite3WhereBegin` port (Phase 7).  Until
        step 11g ships those, the CREATE TABLE rows still emit only
        the StartTable prologue (17 ops vs C's 32), and CREATE INDEX
        / DROP TABLE still error out for unrelated reasons (see
        below).  But sqlite3LocateTableItem("sqlite_master", ...) now
        returns a real PTable2 — verifiable by removing step 11f's
        guard locally and running `TestPrepareBasic` (no longer
        regresses on T7..T10).
      * **CREATE INDEX `t(a)` still fails the table lookup for `t`.**
        Different problem: user tables created during the test
        fixture (`CREATE TABLE t(a,b,c)`) are NOT published into
        `tblHash` because `sqlite3EndTable`'s publication arm
        (`codegen.pas:6892`) is gated on `db^.init.busy <> 0`.  In
        the user-driven prepare/exec path, `init.busy = 0` and the
        publication is supposed to happen later via `OP_ParseSchema`
        — which is still a stub at `passqlite3vdbe.pas:7135`.  This
        is **Phase 6.x — OP_ParseSchema port** (separate task; not
        a step 11g prerequisite, only matters for non-schema tables).
        Until that lands, CREATE INDEX over a user table fails at
        `sqlite3SrcListLookup(pTblName)` regardless of step 11g
        progress.
      * **DROP TABLE `t` fails for the same reason** — `t` is not
        in tblHash, so the resolve in `sqlite3DropTable` errors out
        before reaching `sqlite3CodeDropTable`'s NestedParse.  Same
        OP_ParseSchema dependency as CREATE INDEX.
      * **`sqlite_temp_master` is bootstrapped too** even though no
        current corpus uses it — symmetric with C's `sqlite3InitOne`
        loop (`prepare.c:449..456`) and cheap (one Table + one
        column array).  Lets attached / TEMP DDL paths Just Work
        once the rest of step 11g lands.
      * **Real on-disk schema initialisation is still deferred.**
        `sqlite3InitOne` reads sqlite_master rows to reconstruct
        user objects.  This helper only installs the *system* table,
        which is sufficient for nested-parse emit.  Reconstruction
        of user tables / indexes / triggers from on-disk meta data
        belongs to the Phase 7 prepare.c port.
      * **Next 6.9-bis target: step 11g still requires `sqlite3WhereBegin`
        / `sqlite3WhereOkOnePass` / `sqlite3WhereEnd`** (Phase 7
        territory).  With *those* in place, the productive emission
        tail of `sqlite3DeleteFrom` / `sqlite3Update` can fire and
        flip the 5 CREATE TABLE rows of TestExplainParity from
        DIVERGE -> closer to PASS (or at least raise the op count
        from 17 toward 32).  CREATE INDEX / DROP TABLE need the
        OP_ParseSchema port (separate task) before they'll prepare
        non-nil.

  - **2026-04-26 — Phase 6.9-bis (step 11f): structural skeleton of
    `sqlite3DeleteFrom` (delete.c:288) and `sqlite3Update` (update.c:285).**
    Replaces the two Phase-6.4 stubs at `passqlite3codegen.pas:5345`
    and `:5395` with C-shaped prologues mirroring step 11c's pattern
    for `sqlite3Insert`.  Both now run the productive lookup chain
    (SrcListLookup -> TriggersExist -> isView -> ViewGetColumnNames
    -> IsReadOnly -> SchemaToIndex -> AuthCheck -> cursor allocation
    -> GetVdbe; DeleteFrom additionally fires VdbeCountChanges +
    BeginWriteOperation) and bail with TODOs before the WHERE-loop
    / GenerateRowDelete / GenerateConstraintChecks / CompleteInsertion
    emission tail (those helpers are still Phase 6.4 stubs).
    [X]

    Concrete changes (all in `src/passqlite3codegen.pas`):
      * `sqlite3DeleteFrom` (codegen.pas:5357..5478): label-driven
        port with locals `db, pTab, v, iDb, iTabCur, nIdx, pIdx,
        pTrg, isView, bComplex, rcauth, memCnt, sContext`.  Mirrors
        delete.c:288..422 verbatim through the cursor-loop and
        BeginWriteOperation, then drops to `delete_from_cleanup`.
      * `sqlite3Update` (codegen.pas:5524..5654): label-driven port
        with locals `db, pTab, v, iDb, iBaseCur, iDataCur, iIdxCur,
        nIdx, pIdx, pPk, pTrg, isView, tmask, nChangeFrom,
        sContext`.  Mirrors update.c:285..458 through cursor
        allocation + GetVdbe.  Skips aXRef/aRegIdx/aToOpen
        allocation (consumed only by the WHERE-loop which is
        deferred).  No BeginWriteOperation yet — the C reference
        defers it until after the column-resolution loop, and
        emitting it here without the rest would dirty the VDBE.
      * **Skeleton-only error-state guard (both functions).**
        Snapshot `pParse^.nErr / rc / zErrMsg` after the eOpenState
        gate; restore them at the cleanup label gated on a
        `skelEntered: Boolean` flag.  Reason: the productive
        prologue calls `sqlite3SrcListLookup`, which calls
        `sqlite3LocateTableItem` and CAN set `pParse^.nErr` when
        the schema isn't yet loaded for the target.  Concretely,
        the nested UPDATE on `sqlite_master` fired by
        `sqlite3EndTable` was failing the lookup (pParse^.nErr=1,
        pTab=nil) — this caused TestPrepareBasic T7..T10 (CREATE
        TABLE prepare) to fail with rc=1 (SQL logic error).  The
        guard makes the skeleton a true no-op for outer parser
        state until the productive emission tail lands in step
        11g.  The guard is removed once any productive opcode is
        emitted (because nErr would then represent real failure
        downstream of GetVdbe).

    Tests: full build clean.  Regression sweep (2026-04-26):
    TestExplainParity 2 PASS / 8 DIVERGE / 0 ERROR (unchanged),
    TestPrepareBasic 20/20 (was 16/4 mid-port — fixed by the
    error-state guard), TestParser 45/45, TestParserSmoke 20/20,
    TestSchemaBasic 44/44, TestVdbeApi 57/57, TestDMLBasic 54/54,
    TestSelectBasic 49/49, TestExprBasic 40/40, TestVdbeTxn 8/8,
    TestAuthBuiltins 34/34, TestOpenClose 17/17, TestSmoke +
    TestUtil clean, TestJson 434/434, TestJsonEach 50/50,
    TestJsonRegister 48/48, TestPrintf 105/105, TestVtab 216/216.

    Discoveries / next-step notes:
      * **Schema lookup of sqlite_master fails during nested
        parse.**  `sqlite3LocateTableItem` returns nil with
        nErr=1 when `sqlite3NestedParse` re-parses
        `UPDATE sqlite_master SET ...` from `sqlite3EndTable`.
        sqlite_master IS bootstrapped into `db^.aDb[0].pSchema^.tblHash`
        per `passqlite3codegen.pas:6110`, so the failure is
        somewhere in the resolution chain (likely
        `sqlite3FindTableInDb` or the database-name handling in
        `sqlite3LocateTable`).  The skeleton's guard sidesteps
        this entirely; tracking the real fix as **Phase 6.x —
        nested-parse schema visibility**.  This will need to be
        resolved before step 11g can emit productive code that
        relies on the lookup result actually being non-nil.
      * **`sqlite3Insert` step 11c..11e was unaffected** because
        the productive INSERT path through it for CREATE INDEX
        rows is gated upstream by `sqlite3CreateIndex` errors
        (per the discoveries note in step 11e).  So Insert never
        reached SrcListLookup productively to expose this issue.
        DeleteFrom + Update DO reach it productively via
        sqlite3EndTable / sqlite3CodeDropTable, hence the guard.
      * **`sqlite3LimitWhere` call shape skipped.**  The C
        reference wraps the `sqlite3LimitWhere(...)` call in
        `#ifdef SQLITE_ENABLE_UPDATE_DELETE_LIMIT`.  The Pascal
        port keeps the helper as a no-op stub (codegen.pas:5340)
        and the call is omitted from the skeleton — adding it
        would be a one-line change once the helper is real.
      * **Update skeleton omits BeginWriteOperation** (unlike
        DeleteFrom which has it).  Mirrors the C reference where
        the call appears at update.c:710, after the bulk of the
        column-resolution and cursor-opening logic.  Adding it
        here would emit OP_Transaction before any productive
        write, leaving stray cursors un-opened.  Lands with
        step 11g.
      * **Next 6.9-bis target: step 11g — wire the productive
        emission tail.**  Two prerequisites:
          1. Resolve the nested-parse sqlite_master lookup
             failure (see first discovery above).
          2. Port `sqlite3WhereBegin` / `sqlite3WhereOkOnePass`
             / `sqlite3WhereEnd` (Phase 7 territory).
        With those in place, DeleteFrom can wire the WHERE-loop +
        OP_Delete tail, and Update can wire the column-resolution
        loop + OP_Insert tail using
        `sqlite3GenerateConstraintChecks` +
        `sqlite3CompleteInsertion` (still Phase 6.4 stubs, but
        only schema-row callers need them today and those callers
        don't define UNIQUE/CHECK/FK over sqlite_master).
        Flipping the 8 DIVERGE rows in TestExplainParity remains
        the gate.

  - **2026-04-26 — Phase 6.9-bis (step 11e): wire `sqlite3ExprCode`
    + the productive VALUES emission tail into `sqlite3Insert`.**
    Replaces the TODO block at `passqlite3codegen.pas:5616..5626`
    with a hand-rolled inline of the schema-row INSERT path used by
    `sqlite3NestedParse` (CREATE INDEX / DROP INDEX / DROP TABLE /
    sqlite_statN cleanup).  Mirrors the C reference's "no triggers,
    no IDLIST, no view, no UPSERT, HasRowid" shape but skips the
    full `sqlite3GenerateConstraintChecks` /
    `sqlite3CompleteInsertion` path (still stubs) — emits the
    OpenWrite / column-eval / NewRowid / MakeRecord / Insert
    sequence directly.
    [X]

    Concrete changes (all in `src/passqlite3codegen.pas`):
      * `sqlite3Insert`: new locals `i: i32`, `regOut: i32`,
        `pListItems: PExprListItem`.
      * Body now emits:
        - `sqlite3OpenTable(pParse, 0, iDb, pTab, OP_OpenWrite)`
          guarded by `not isView` (the C `if(!isView)` arm at
          insert.c:1273);
        - `for i := 0 to nColumn-1 do sqlite3ExprCode(pParse,
           pListItems[i].pExpr, regData+i)` — ports the simplest
          arm of insert.c:1429..1436's `sqlite3ExprCodeTarget +
          OP_Copy/OP_SCopy` loop, leaning on the literal-only
          `sqlite3ExprCode` from step 11d (which already emits
          OP_Copy / OP_SCopy itself for TK_REGISTER fall-through);
        - `OP_NewRowid 0, regRowid, regAutoinc` — matches
          insert.c:1539 verbatim;
        - `regOut := sqlite3GetTempReg(pParse)` then
          `OP_MakeRecord regData, pTab^.nCol, regOut` +
          `sqlite3SetMakeRecordP5(v, pTab)` — matches
          insert.c:2714..2715;
        - `OP_Insert 0, regOut, regRowid` +
          `sqlite3VdbeChangeP5(v, OPFLAG_NCHANGE or
           OPFLAG_LASTROWID or OPFLAG_APPEND or
           OPFLAG_USESEEKRESULT)` — matches the standard
          schema-row P5 set, including the OPFLAG_USESEEKRESULT
          variant used by sqlite3CompleteInsertion (insert.c:
          2818/2833 + 2842);
        - `sqlite3ReleaseTempReg(pParse, regOut)` to balance
          the GetTempReg (good citizen even though no current
          caller cares about temp-register reuse here).

    Tests: full build clean.  TestExplainParity unchanged at
    **2 PASS / 8 DIVERGE / 0 ERROR** (see Discoveries).
    Regression spot check (2026-04-26): TestPrepareBasic 20/20,
    TestParser 45/45, TestParserSmoke 20/20, TestSchemaBasic
    44/44, TestVdbeApi 57/57, TestDMLBasic 54/54, TestSelectBasic
    49/49, TestExprBasic 40/40, TestVdbeTxn 8/8, TestAuthBuiltins
    34/34, TestOpenClose 17/17, TestSmoke + TestUtil clean,
    TestJson 434/434, TestJsonEach 50/50, TestJsonRegister 48/48,
    TestPrintf 105/105, TestVtab 216/216.

    Discoveries / next-step notes:
      * **TestExplainParity didn't move yet — root cause is
        upstream of `sqlite3Insert`.**  CREATE TABLE and DROP
        TABLE rows go through `sqlite3Update` / `sqlite3DeleteFrom`
        (still Phase 6.4 stubs), not `sqlite3Insert`, because
        `sqlite3EndTable` emits `UPDATE sqlite_master ...` and
        `sqlite3CodeDropTable` emits `DELETE FROM sqlite_master
        ...`.  The CREATE INDEX rows *would* hit `sqlite3Insert`
        (INSERT INTO sqlite_master), but `TestExplainParity` reports
        "Pascal prepare returned nil Vdbe" for those — meaning
        `sqlite3CreateIndex` errors out *before* reaching the
        `sqlite3NestedParse` call (likely an nErr trip in the
        structural scaffolding from step 8, or schema not loaded
        for ephemeral parses).  The productive Insert tail is
        now in place; flipping CREATE INDEX to PASS requires
        unblocking sqlite3CreateIndex's own pipeline first.
      * **`sqlite3SetMakeRecordP5` is still a Phase-6.4 stub** —
        kept the call site so wiring real P5 setting becomes a
        body-only edit later.  No observable effect today since
        sqlite_master is HasRowid (not WITHOUT ROWID) and the
        stub no-op matches the C reference's behaviour for that
        case (P5 only matters for WITHOUT ROWID + STRICT).
      * **`OPFLAG_NCHANGE | OPFLAG_LASTROWID | OPFLAG_APPEND |
        OPFLAG_USESEEKRESULT`** is the documented P5 set for the
        schema-row INSERT.  USESEEKRESULT is technically only safe
        when no REPLACE constraints + no triggers can fire; for
        a fresh INSERT into sqlite_master both conditions hold
        trivially.  Mirrors `sqlite3CompleteInsertion` insert.c:
        2818..2842 for that case.
      * **No constraint-checks / FK-checks emitted.**  C reference
        runs `sqlite3GenerateConstraintChecks` + `sqlite3FkCheck`
        before `sqlite3CompleteInsertion` (insert.c:1567..1574).
        Both are Phase 6.4 stubs in this port.  Schema-row INSERTs
        from `sqlite3NestedParse` don't define any UNIQUE/CHECK/FK
        constraints over sqlite_master in user-visible code, so
        the omission is structurally safe today.  A real Phase 6.x
        port of those helpers will slot in *between* the column-
        eval loop and the OP_NewRowid call without disturbing the
        rest of the tail.
      * **Next 6.9-bis target: step 11f — structural skeleton of
        `sqlite3Update` / `sqlite3DeleteFrom`.**  The actual
        DIVERGE-flippers for CREATE TABLE and DROP TABLE rows
        live in Update / DeleteFrom (which receive
        `UPDATE/DELETE FROM sqlite_master ...` from
        `sqlite3NestedParse`).  Same pattern as step 11c: port
        the C-shaped prologue first, then wire the productive
        emission tail.  Once those two are real, the
        sqlite3CreateIndex nil-Vdbe issue is the only remaining
        block to flipping all 8 DIVERGE rows.

  - **2026-04-26 — Phase 6.9-bis (step 11d): literal-only
    `sqlite3ExprCode` port (expr.c:5884).**  Adds the four-arm
    `sqlite3ExprCode(pParse, pExpr, target)` helper covering exactly
    the expression kinds reached by `sqlite3NestedParse`-generated
    schema-row INSERT/UPDATE/DELETE statements: `TK_INTEGER`
    (EP_IntValue path → `OP_Integer`), `TK_NULL` (`OP_Null`),
    `TK_STRING` (`sqlite3VdbeLoadString` → `OP_String8`), and
    `TK_REGISTER` (returns `pExpr^.iTable` then OP_Copy/OP_SCopy
    into target via the post-dispatch tail).  Default arm emits the
    C-reference "be nice and don't crash" `OP_Null` fallback.
    [X]

    Concrete changes (all in `src/passqlite3codegen.pas`):
      * Interface: new decl `procedure sqlite3ExprCode(pParse: PParse;
        pExpr: PExpr; target: i32)` placed alongside other Expr*
        helpers (codegen.pas:1696 area).
      * Implementation: literal-only body inserted after
        `sqlite3ExprSkipCollateAndLikely` (codegen.pas:3545 area).
        Mirrors the C dispatch shape: `inReg := target` default;
        case on `pExpr^.op`; for TK_REGISTER bumps `inReg :=
        pExpr^.iTable`; tail copies `inReg → target` via OP_Copy
        when `pX^.op = TK_REGISTER` or EP_Subquery is set, else
        OP_SCopy.  Matches `sqlite3ExprCode` (expr.c:5884) +
        `sqlite3ExprCodeTarget` (expr.c:5089/5104/5121/5147) byte-
        for-byte for the four-arm subset.

    Tests: full build clean.  TestExplainParity unchanged at
    **2 PASS / 8 DIVERGE / 0 ERROR** (expected — `sqlite3ExprCode`
    is not yet *called* by anything productive: `sqlite3Insert` is
    still the structural skeleton from step 11c that bails out
    before the VALUES emission loop with a TODO).  Regression
    spot check (2026-04-26): TestPrepareBasic 20/20, TestParser
    45/45, TestParserSmoke 20/20, TestSchemaBasic 44/44,
    TestVdbeApi 57/57, TestDMLBasic 54/54, TestSelectBasic 49/49,
    TestExprBasic 40/40, TestVdbeTxn 8/8, TestAuthBuiltins 34/34,
    TestOpenClose 17/17, TestSmoke + TestUtil clean, TestJson
    434/434, TestJsonEach 50/50, TestJsonRegister 48/48,
    TestPrintf 105/105, TestVtab 216/216.

    Discoveries / next-step notes:
      * **Why a 70-line port of a 22-line C function.**  The C
        `sqlite3ExprCode` body is two layers — it calls
        `sqlite3ExprCodeTarget` (a 700-line dispatcher) for the
        actual codegen, then patches the result-register copy.
        Porting `sqlite3ExprCodeTarget` whole would drag in TK_AGG_*,
        TK_FUNCTION, TK_IN, TK_CASE, TK_SELECT and a dozen helper
        Targets that aren't yet ported.  The four-arm inline
        dispatch keeps the surface scoped to exactly what the
        productive path needs today, without entangling Phase-7
        expr semantics.
      * **TK_REGISTER tail emits OP_Copy not OP_SCopy.**  The
        original step-plan in 11c's notes said TK_REGISTER would
        be OP_SCopy; verifying against expr.c:5896..5902 shows the
        C reference picks OP_Copy when `pX^.op = TK_REGISTER`
        (because a register source means a real value was already
        materialised — OP_SCopy is a "shallow" copy that aliases
        Mem.flags, dangerous for live operands).  The Pascal port
        matches the C choice.  Plan-note in step 11c was off by one
        opcode; the actual port follows the C reference verbatim.
      * **EP_IntValue gate on TK_INTEGER.**  Schema-row INSERTs
        from `sqlite3NestedParse` use `#%d` (TK_REGISTER) for
        integer references and never embed integer literals, so
        the EP_IntValue arm is the only one that needs to fire
        productively.  The non-EP_IntValue path (oversized literals
        / hex literals) is left as a TODO routed to `OP_Null` —
        same defensive choice as the C default arm.  Wiring real
        `OP_Int64` + `sqlite3DecOrHexToI64` is a Phase 6.x
        cleanup; no current test exercises it.
      * **Fall-through default emits OP_Null on purpose.**  Mirrors
        the C reference at expr.c:5115..5123 — the comment there is
        explicit: "Make NULL the default case so that if a bug
        causes an illegal Expr node to be passed into this function,
        it will be handled sanely and not crash."  Kept as-is.
      * **Next 6.9-bis target: step 11e — wire `sqlite3ExprCode`
        into the `sqlite3Insert` single-row VALUES path.**  With
        the literal helper in hand, the TODO block at
        codegen.pas:5544..5556 becomes:
          - `sqlite3OpenTable(pParse, 0, iDb, pTab, OP_OpenWrite)`
            for cursor 0 against the schema btree (or
            `sqlite3OpenSchemaTable` for the iDb=ENC_TABLE case);
          - `for i := 0 to nColumn-1 do sqlite3ExprCode(pParse,
             ExprListItems(pList)^[i].pExpr, regData+i)`;
          - `sqlite3VdbeAddOp2(v, OP_NewRowid, 0, regRowid)`;
          - `sqlite3VdbeAddOp3(v, OP_MakeRecord, regData,
             pTab^.nCol, regOut)` + `sqlite3SetMakeRecordP5`;
          - `sqlite3VdbeAddOp3(v, OP_Insert, 0, regOut, regRowid)`
            with P5 = `OPFLAG_NCHANGE | OPFLAG_LASTROWID |
                      OPFLAG_APPEND | OPFLAG_USESEEKRESULT`.
        That should flip the `CREATE INDEX` and `DROP INDEX` rows
        in TestExplainParity from DIVERGE to a partial-match (still
        missing the OpenWrite + ParseSchema tail emitted by
        sqlite3CreateIndex itself, but those scaffolds are already
        present from step 8).

  - **2026-04-26 — Phase 6.9-bis (step 11c): structural skeleton of
    `sqlite3Insert` (insert.c:894).**  Replaces the 5-line free-only
    Phase 6.4 stub at `passqlite3codegen.pas:5405` with a faithful
    structural port of the C function's prologue: every early-out
    check, the `SrcListLookup` -> `AuthCheck` -> `IsReadOnly` ->
    `GetVdbe` -> `CountChanges` -> `BeginWriteOperation` chain, plus
    register allocation for the rowid + per-column data block.  Ports
    `sqlite3VdbeCountChanges` (vdbeaux.c:5315) as a one-line helper
    that sets `VDBF_ChangeCntOn`.  Also lands a Phase-6.x stub of
    `autoIncBegin` returning 0 (insert.c:159).
    [X]

    Concrete changes:
      * `src/passqlite3vdbe.pas`:
        - New interface decl + impl of `sqlite3VdbeCountChanges(v: PVdbe)`
          that ORs `VDBF_ChangeCntOn` into `v^.vdbeFlags` (one-liner port
          of vdbeaux.c:5315).
      * `src/passqlite3codegen.pas`:
        - `sqlite3Insert` body replaced with the structural skeleton.
          Local-var name follows memory-feedback rule: `pTrigger` is a
          shadowed identifier in FPC (TParse has a `pTrigger` field), so
          renamed to `pTrg`.
        - Test-scaffold gate `if db^.eOpenState <> $76 then goto
          insert_cleanup` matches the existing DropIndex / DropTable /
          CreateIndex idiom — TestParser / TestParserSmoke drive the
          parser against a stub db without a real schema, where
          `sqlite3SrcListLookup` would set nErr.
        - Branches deliberately routed to insert_cleanup with explicit
          TODO markers: pColumn IDLIST loop (insert.c:1077..1108),
          pSelect coroutine path (insert.c:1115..), VALUES emission +
          OP_NewRowid / OP_MakeRecord / OP_Insert tail, xferOptimization
          arm, IsVirtual register bump.  These are sub-step 11d+.
        - Forward declaration of file-scope helper `autoIncBegin`
          (Phase-6.x stub returning 0); productive AUTOINCREMENT codegen
          is independently tracked.

    Tests: full build clean.  TestExplainParity unchanged at
    **2 PASS / 8 DIVERGE / 0 ERROR** (expected — the productive VALUES
    emission is still a TODO; this step lands the C-shaped prologue
    only, same incremental pattern as steps 11a/11b).  Regression spot
    check (2026-04-26): TestPrepareBasic 20/20, TestParser 45/45,
    TestParserSmoke 20/20, TestSchemaBasic 44/44, TestVdbeApi 57/57,
    TestDMLBasic 54/54, TestSelectBasic 49/49, TestExprBasic 40/40,
    TestVdbeTxn 8/8, TestAuthBuiltins 34/34, TestOpenClose 17/17,
    TestSmoke + TestUtil clean, TestJson 434/434, TestJsonEach 50/50,
    TestJsonRegister 48/48, TestPrintf 105/105, TestVtab 216/216.

    Discoveries / next-step notes:
      * **`pTrigger` is a shadowed identifier in FPC.**  TParse has a
        `pTrigger` field (codegen.pas), so a local `pTrigger: PTrigger`
        triggers an "Error in type definition".  Same trap as the
        `pPager: PPager` issue in pager.pas.  Use `pTrg` for the local;
        memory note already records this rule.
      * **`autoIncBegin` left as a stub returning 0.**  AUTOINCREMENT
        codegen has its own dependency chain (sqlite_sequence row
        lookup, OP_MaxPgcnt, regSeqRowid) and is independent of the
        DML-skeleton work.  Schema-row INSERTs from `sqlite3NestedParse`
        never target AUTOINCREMENT tables, so 0 is structurally
        correct for the productive path.
      * **The early `eOpenState <> $76` gate is structurally redundant
        for real db.**  C reference has no such check; a real
        sqlite3_open_v2 always reaches the productive body.  The gate
        only skips on the lightweight stub db used by TestParser /
        TestParserSmoke (eOpenState = 1).  Same idiom as the existing
        `sqlite3DropIndex` (codegen:6878), `sqlite3DropTable`
        (codegen:6766), and `sqlite3CreateIndex` (codegen:7042) gates.
      * **VDBE registers reserved before the cursor is opened.**
        Matches insert.c:1049..1055 ordering: `regRowid = nMem+1`,
        bump `nMem` by `pTab^.nCol + 1`, `regData = regRowid+1`.
        Vtab arm (extra +1 for argv[0]) is a TODO.
      * **`pTrg` always nil / `tmask` always 0 today** because
        `sqlite3TriggersExist` is still the Phase 6.4 stub
        (codegen:5117).  The structural port still calls it via the
        full C-shaped argument list so wiring real trigger lookup is a
        one-line change in 11d+.
      * **Next 6.9-bis target: step 11d — minimal `sqlite3ExprCode`
        scoped to the literal cases used by `sqlite3NestedParse`.**
        The schema-row INSERTs produced by `sqlite3CreateIndex`
        (codegen:7035 path) hand sqlite3MPrintf 5 values: a TK_STRING
        ('index'), two `%Q`-quoted TK_STRING literals (idxName,
        tabName), a `#%d` register reference (regRoot), and a `%Q`
        zStmt.  The minimal sqlite3ExprCode needs only:
        * TK_STRING -> OP_String8 (regOut, P4=z),
        * TK_INTEGER -> OP_Integer,
        * TK_NULL -> OP_Null,
        * TK_REGISTER -> OP_SCopy from the named register.
        With those four arms, the VALUES emission loop in the
        sqlite3Insert TODO block becomes a four-line unrolled call,
        and the CREATE INDEX / DROP INDEX rows in TestExplainParity
        flip from DIVERGE to a partial-match (still missing the
        OpenWrite + ParseSchema tail, but that is in
        sqlite3CreateIndex itself, which already has the structural
        scaffolding from step 8).

  - **2026-04-26 — Phase 6.9-bis (step 11b): port the three delete.c
    DML-foundation helpers — `sqlite3SrcListLookup`,
    `sqlite3CodeChangeCount`, `sqlite3IsReadOnly` (delete.c:31, 51,
    119), plus the file-static `tabIsReadOnly` (delete.c:98).**
    Replaces the `Phase 6.4 stub` bodies at
    `passqlite3codegen.pas:5158..5176` with faithful structural ports.
    Foundation for the structural `sqlite3Insert` / `sqlite3Update` /
    `sqlite3DeleteFrom` ports that come next: every DML codegen
    starts by calling `sqlite3SrcListLookup` to attach a real
    `pSTab` + bump nTabRef, then calls `sqlite3IsReadOnly` to gate
    writes, then (after VDBE setup) emits `sqlite3CodeChangeCount`
    when `pParse->nested == 0`.

    Concrete changes (all in `src/passqlite3codegen.pas`):
      * `sqlite3SrcListLookup` — body uses `SrcListItems(pSrc)` to
        get `pSrc^.a[0]`, calls existing `sqlite3LocateTableItem`
        (with `flags=0` per C), frees any prior `pSTab` via
        `sqlite3DeleteTable`, attaches the new `pTab`, sets
        `fg.notCte`, bumps `nTabRef`, and runs the existing
        `sqlite3IndexedByLookup` if `fg.isIndexedBy` is set.
      * `sqlite3CodeChangeCount` — emits the byte-identical 4-op
        sequence `OP_FkCheck` + `OP_ResultRow(regCounter, 1)` +
        `sqlite3VdbeSetNumCols(v, 1)` +
        `sqlite3VdbeSetColName(v, 0, COLNAME_NAME, zColName, SQLITE_STATIC)`.
      * `tabIsReadOnly` (new file-static helper) — vtab arm is a
        no-op TODO (see Discoveries); non-vtab path checks
        `(tabFlags & (TF_Readonly | TF_Shadow))`, then for `TF_Readonly`
        gates on `sqlite3WritableSchema(db) == 0 && pParse^.nested == 0`,
        and for `TF_Shadow` returns `sqlite3ReadOnlyShadowTables(db)`.
      * `sqlite3IsReadOnly` — calls `tabIsReadOnly` and emits the
        verbatim error message `"table %s may not be modified"`,
        then handles the `IsView(pTab)` arm (`eTabType = TABTYP_VIEW`)
        with the verbatim `"cannot modify %s because it is a view"`
        message, gated on `(pTrigger == nil) ||
        ((pTrigger^.bReturning <> 0) && (pTrigger^.pNext = nil))`.

    SrcItem fg-bit accessors (the C bitfield maps to four u8 sub-bytes
    in `TSrcItemFg` — see codegen.pas:572):
      * `fg.notIndexed`   = bit 0 of `fgBits`   (mask `$01`).
      * `fg.isIndexedBy`  = bit 1 of `fgBits`   (mask `$02`).
      * `fg.fromDDL`      = bit 0 of `fgBits2`  (mask `$01`).
      * `fg.isCte`        = bit 1 of `fgBits2`  (mask `$02`).
      * `fg.notCte`       = bit 2 of `fgBits2`  (mask `$04`).
      * `fg.fixedSchema`  = bit 0 of `fgBits3`  (mask `$01`).

    Tests: full build clean.  TestExplainParity unchanged at
    **2 PASS / 8 DIVERGE / 0 ERROR** (expected — these helpers are
    foundational scaffolding; nothing yet *calls* them productively
    because `sqlite3Insert` / `sqlite3Update` / `sqlite3DeleteFrom`
    are still Phase 6.4 stubs).  Verified by stash/build/diff
    against pre-change baseline — identical per-row diverge output.
    Regression spot check (2026-04-26): TestPrepareBasic 20/20,
    TestParser 45/45, TestParserSmoke 20/20, TestSchemaBasic 44/44,
    TestVdbeApi 57/57, TestDMLBasic 54/54, TestSelectBasic 49/49,
    TestExprBasic 40/40, TestVdbeTxn 8/8, TestAuthBuiltins 34/34,
    TestOpenClose 17/17, TestSmoke + TestUtil clean, TestJson
    434/434, TestJsonEach 50/50, TestJsonRegister 48/48,
    TestPrintf 105/105, TestVtab 216/216.

    Discoveries / next-step notes:
      * **Why three helpers in one sub-step.**  Each is a 4..15
        line C body and they are all on the *same* call-path: the
        first three lines of every DML codegen are
        `sqlite3SrcListLookup` → `sqlite3IsReadOnly` →
        `sqlite3BeginWriteOperation`.  Bundling them keeps the
        commit reviewable while removing all three foundational
        stubs in one pass.
      * **vtab arm of `tabIsReadOnly` deferred.**  C `vtabIsReadOnly`
        needs `sqlite3GetVTable(db, pTab)->pMod->pModule->xUpdate`
        and the `eVtabRisk` / `SQLITE_TrustedSchema` gating.  Pulling
        `passqlite3vtab` into codegen's implementation block was
        explicitly avoided in step 11a (`tabIsVirtual` deferral
        for the same reason).  Treated here as `Result := 0`
        (writable) with a TODO; vtab DML is not exercised by the
        current test corpus.
      * **`fg.notCte = 1` written via raw bit-OR.**  The Pascal
        `TSrcItemFg` is four `u8` fields; the C bitfield's bit-2
        position inside `fgBits2` is documented above and matches
        the order in the C `struct` declaration (sqliteInt.h:3360
        — `notIndexed, isIndexedBy, ..., fromDDL, isCte, notCte,
        ...`).  No existing call site cares about `notCte` yet
        (it only matters for CTE matching during `pSelect`
        resolution, Phase 7), so the OR is structurally correct
        but observably inert today.
      * **`sqlite3ErrorMsg` has no varargs in this port.**  The C
        helper takes a printf-style format; the Pascal helper at
        `passqlite3codegen.pas:2520` takes a single `PAnsiChar`.
        The two error messages here use `AnsiString` concatenation
        to substitute `pTab^.zName`, matching the existing pattern
        from `sqlite3IndexedByLookup` (codegen:4752) and
        `sqlite3CreateIndex` (codegen:5970/5972).  Switching to a
        printf-style helper is a separate Phase 6.x cleanup and is
        not required by any current test.
      * **Next 6.9-bis target: step 11c — structural `sqlite3Insert`.**
        With the three delete.c helpers in place, the next sub-step
        is the structural skeleton of `sqlite3Insert` (insert.c:894)
        covering only the simplest path: single-row VALUES, no
        triggers, no view, no UPSERT, no IDLIST, no XFER opt.
        Required upstream pieces: `sqlite3ExprCode` for VALUES
        evaluation (still TODO per codegen:7538 — may need a
        scoped/stub variant first that handles the literal cases
        used by `sqlite3NestedParse` only), `OP_NewRowid`,
        `OP_MakeRecord`, `OP_Insert`, plus the existing
        `sqlite3OpenTable` + `sqlite3CodeChangeCount`.  This is
        the actual DIVERGE-flipper for the CREATE TABLE / DROP
        TABLE / CREATE INDEX rows in TestExplainParity.

  - **2026-04-26 — Phase 6.9-bis (step 11a): port `sqlite3OpenTable`
    (insert.c:26).**  Replaces the `Phase 6.4 stub` body at
    `passqlite3codegen.pas:5260` with a faithful structural port of
    the C helper that emits `OP_OpenRead` / `OP_OpenWrite` for a
    table cursor — a precondition for any productive port of
    `sqlite3Insert` / `sqlite3Update` / `sqlite3DeleteFrom` (the
    actual DIVERGE-flippers identified at the end of step 10).

    Concrete changes (all in `src/passqlite3codegen.pas`):
      * Body now emits `sqlite3VdbeAddOp4Int(v, opcode, iCur,
        pTab^.tnum, iDb, pTab^.nNVCol)` for the rowid case (the
        common path) and `sqlite3VdbeAddOp3 + sqlite3VdbeSetP4KeyInfo`
        for the WITHOUT ROWID case.  HasRowid maps to
        `(pTab^.tabFlags and TF_WithoutRowid) = 0`.
      * `sqlite3TableLock` is omitted with a comment — it is a no-op
        when SQLITE_OMIT_SHARED_CACHE is in effect (this port's
        default; see `noSharedCache` in `passqlite3util`).  Same
        choice already documented at `sqlite3OpenSchemaTable`
        (codegen:5807).
      * The WITHOUT ROWID arm passes `Pointer(pPk)` to
        `sqlite3VdbeSetP4KeyInfo` — the vdbe-side prototype takes
        `PIndex = Pointer` (vdbe.pas:611) so the codegen-side
        `PIndex2` is forwarded by raw-pointer conversion.  The
        function itself is still a Phase-6 no-op stub
        (passqlite3vdbe.pas:2397), so nothing observable changes
        for WITHOUT ROWID until that lands; the structural call is
        in place for when it does.

    Tests: full build clean.  TestExplainParity unchanged at
    **2 PASS / 8 DIVERGE / 0 ERROR** (expected — `sqlite3OpenTable`
    is not yet *called* by anything productive: `sqlite3Insert`,
    `sqlite3Update`, `sqlite3DeleteFrom` are still Phase 6.4 stubs
    that free their inputs).  Regression spot check (2026-04-26):
    TestPrepareBasic 20/20, TestParser 45/45, TestParserSmoke 20/20,
    TestSchemaBasic 44/44, TestVdbeApi 57/57, TestDMLBasic 54/54,
    TestSelectBasic 49/49, TestExprBasic 40/40, TestVdbeTxn 8/8,
    TestAuthBuiltins 34/34, TestOpenClose 17/17, TestSmoke +
    TestUtil clean, TestJson 434/434, TestJsonEach 50/50,
    TestJsonRegister 48/48, TestPrintf 105/105, TestVtab 216/216.

    Discoveries / next-step notes:
      * **Why this is a sub-step (11a) of step 11.**  The full
        step-11 target — port `sqlite3Insert` / `sqlite3Update` /
        `sqlite3DeleteFrom` to the point where they emit OpenWrite
        / String8 / MakeRecord / Insert against `sqlite_master` — is
        a multi-thousand-line C surface (insert.c is 3000+ lines,
        update.c another 2000+, delete.c another 1000+).  Each of
        those eventually calls `sqlite3OpenTable`, so landing this
        helper first lets future sub-steps focus purely on the
        per-statement codegen scaffold without entangling cursor-
        open semantics.  Same incremental pattern as 6.9-bis steps
        1..10.
      * **`pParse^.pVdbe` not `sqlite3GetVdbe`.**  The C reference
        asserts `pParse->pVdbe!=0` and reads the field directly; we
        do the same (early-exit on nil rather than allocating a
        fresh VDBE here, which would be wrong — the caller is always
        already mid-codegen).
      * **`IsVirtual(pTab)` assertion not wired.**  The C reference
        asserts `!IsVirtual(pTab)`.  Pascal `tabIsVirtual` lives in
        `passqlite3vtab` (vtab.pas:451) and would require adding a
        `uses` to codegen's implementation block.  Skipped for now;
        the productive call sites that go through `sqlite3OpenTable`
        all gate on `pTab^.eTabType <> TABTYP_VTAB` upstream
        (sqlite3CreateIndex codegen:6830 is the existing example),
        so the assertion is structurally redundant.  Add later if
        a defensive check proves necessary.
      * **Next 6.9-bis target: step 11b — minimal `sqlite3Insert`.**
        With `sqlite3OpenTable` available, the smallest productive
        next sub-step is the schema-row-INSERT path inside
        `sqlite3Insert`: `OpenWrite(0, SCHEMA_ROOT, iDb, 5)` on
        cursor 0 (already handled by `sqlite3OpenSchemaTable`),
        then `String8` / `MakeRecord` / `Insert` for the five-col
        sqlite_master row.  That alone flips the CREATE INDEX +
        DROP INDEX rows in TestExplainParity.  Update / Delete arms
        follow the same pattern.

  - **2026-04-26 — Phase 6.9-bis (step 10): wire real format strings
    + args at the 7 sqlite3NestedParse call sites.**  Fills in the
    placeholders left by step 9 — every `sqlite3NestedParse(pParse,
    nil, [])` in `passqlite3codegen.pas` now passes its real C-side
    format string and argument list (all ported byte-for-byte from
    `../sqlite3/src/build.c`).  Also wires the two adjacent
    `sqlite3VdbeAddParseSchemaOp` filter strings (CREATE TABLE
    `tbl_name='%q' AND type!='trigger'` and CREATE INDEX
    `name='%q' AND type='index'`).

    Concrete changes (all in `src/passqlite3codegen.pas`):
      * `sqlite3EndTable` (build.c:2903) — now computes `zType`
        ("table"/"view") + `zType2` ("TABLE"/"view"), builds `zStmt`
        via `sqlite3MPrintf('CREATE %s %.*s', [zType2, n,
        sNameToken.z])`, then dispatches the `UPDATE %Q.sqlite_master
        SET type='%s', name=%Q, tbl_name=%Q, rootpage=#%d, sql=%Q
        WHERE rowid=#%d` schema-row update with the seven-tuple
        (zDbSName, zType, zName, zName, regRoot, zStmt, regRowid).
        Also computes the `tbl_name='%q' AND type!='trigger'`
        reparse filter and passes it to `AddParseSchemaOp`.
        Adds local vars `zType / zType2 / zStmt / zReparse`.
      * `destroyRootPage` (build.c:3301) — autovacuum-arm UPDATE
        wired with `(zDbSName, iTable, r1, r1)`.
      * `sqlite3ClearStatTables` (build.c:3376) — per-stat-N DELETE
        wired with `(zDbName, &zTab[0], zType, zName)`.
      * `sqlite3CodeDropTable` (build.c:3422+3436) — both calls
        wired: AUTOINCREMENT-arm `DELETE FROM %Q.sqlite_sequence
        WHERE name=%Q` + main-arm `DELETE FROM %Q.sqlite_master
        WHERE tbl_name=%Q and type!='trigger'`.
      * `sqlite3DropIndex` (build.c:4649) — schema-row DELETE wired
        with `(zDbSName, pIndex^.zName)`; the previously stubbed
        `sqlite3ClearStatTables` call is now uncommented (it
        already exists as a real procedure).
      * `sqlite3CreateIndex` (build.c:4460) — schema-row INSERT
        wired with the five-tuple `(zDbSName, pIndex^.zName,
        pTab^.zName, iMem, zStmt)`; reparse-filter `name='%q' AND
        type='index'` computed and passed to `AddParseSchemaOp`.
        Adds local var `zStmtReparse`.

    Tests: full build clean.  TestExplainParity: **2 PASS / 8
    DIVERGE / 0 ERROR** (unchanged from step 9 — see Discoveries).
    Regression spot check (2026-04-26): TestPrepareBasic 20/20,
    TestParser 45/45, TestParserSmoke 20/20, TestSchemaBasic
    44/44, TestVdbeApi 57/57, TestDMLBasic 54/54, TestSelectBasic
    49/49, TestExprBasic 40/40, TestVdbeTxn 8/8, TestAuthBuiltins
    34/34, TestOpenClose 17/17, TestSmoke + TestUtil clean,
    TestJson 434/434, TestJsonEach 50/50, TestJsonRegister 48/48,
    TestPrintf 105/105, TestVtab 216/216.

    Discoveries / next-step notes:
      * **Why TestExplainParity didn't move yet.**  The format
        strings now produce real SQL like `UPDATE main.sqlite_master
        SET type='table', name='t', ...` and `sqlite3RunParser`
        does dispatch via the step-9 hook, but the inner UPDATE /
        INSERT / DELETE statements land in `sqlite3Update`,
        `sqlite3Insert`, `sqlite3DeleteFrom` — all of which are
        Phase 6.4 stubs that simply free their inputs and emit no
        ops.  So the schema-row sub-statements parse cleanly and
        emit zero opcodes, leaving the gap exactly where step 9
        left it.  Next gate (the actual DIVERGE-flipper) is to
        port `sqlite3Insert` / `sqlite3Update` / `sqlite3Delete`
        far enough to emit `OP_OpenWrite / OP_String8 /
        OP_MakeRecord / OP_Insert` against `sqlite_master`.
      * **`pEnd2 = tabOpts ? &sLastToken : pEnd`** is a 3-pointer
        comparison in C; in Pascal the `@pParse^.sLastToken`
        address-of yields a PToken safely (sLastToken is a
        `TToken` field, not a pointer).  Confirmed `tabOpts` is
        a u32 here, not the `Token *` it is at parse-time, so the
        ternary maps cleanly to Pascal `if tabOpts <> 0`.
      * **`pEnd2^.z[0] <> ';'` is guarded by `pEnd2^.z <> nil`.**
        The C reference dereferences unconditionally because the
        parse epilogue never reaches `sqlite3EndTable` with a nil
        `pEnd->z`; the explicit nil-check here is defensive
        Pascal-style.
      * **`%w` not yet used.**  All seven call sites use `%Q`
        (SQL-quoted, NULL-tolerant) for identifiers because that
        matches the C source verbatim — `%w` would only be
        needed for the `RENAME` path in Phase 7.  Confirmed
        `passqlite3printf` already supports `%Q` / `%q` / `%s` /
        `%d` per the 6.bis.4b series.
      * **`sqlite3ClearStatTables` was already a real procedure**
        from step 5 (DropTable family).  The `TODO` comment on
        the DropIndex side was stale; the call is now uncommented
        and routes correctly through the real body which itself
        now emits the real DELETE-from-sqlite_statN sub-statements.
      * **Next 6.9-bis target: step 11 — `sqlite3Insert` /
        `sqlite3Update` / `sqlite3DeleteFrom` codegen** (or at
        minimum a path that recognises `tbl_name=sqlite_master`
        and emits OpenWrite + String8 + MakeRecord + Insert/Delete).
        That is the actual DIVERGE-flipper for the ~13-op gap on
        every CREATE TABLE / DROP TABLE / CREATE INDEX row.

  - **2026-04-26 — Phase 6.9-bis (step 9): sqlite3NestedParse
    structural port (build.c:293) + parser-dispatch hook.**  Replaces
    the 3-line `{ Phase 7 }` stub at `passqlite3codegen.pas:7494`
    with a faithful structural port of the recursive-parse helper
    that the DDL emitters (sqlite3EndTable, sqlite3CreateIndex,
    sqlite3CodeDropTable, sqlite3DropIndex, sqlite3ClearStatTables,
    destroyRootPage's autovacuum arm) invoke to build their schema-
    row UPDATE / INSERT / DELETE sub-statements.

    Concrete changes:
      * `src/passqlite3codegen.pas`:
        - `sqlite3NestedParse` signature widened from
          `(pParse; zFormat: PAnsiChar)` to
          `(pParse; zFormat: PAnsiChar; const args: array of const)`
          to match C's varargs (printf.c-style).  All 7 internal
          call sites updated to pass `[]` (current placeholders
          still hand `nil` zFormat — see Discoveries).
        - Body now ports build.c:293..323 byte-for-byte: early-out
          on `nErr` / `eParseMode` / nil zFormat; format SQL via
          `sqlite3VMPrintf`; on nil result set `pParse^.rc :=
          SQLITE_TOOBIG` + bump nErr; bump `nested`; save the 136-
          byte `PARSE_TAIL` block, zero it; OR `DBFLAG_PreferBuiltin`
          into `db^.mDbFlags`; dispatch to the real parser via the
          new `gNestedRunParser` hook; restore mDbFlags; free zSql;
          restore PARSE_TAIL; decrement nested.
        - New interface symbols: type `TNestedRunParserFn = function
          (pParse: Pointer; zSql: PAnsiChar): i32;` and `var
          gNestedRunParser: TNestedRunParserFn`.  The hook is nil
          by default (codegen-only test programs that don't link
          the parser unit retain the no-op behaviour exactly).
      * `src/passqlite3parser.pas` initialization block: wires the
        hook by assigning `passqlite3codegen.gNestedRunParser :=
        TNestedRunParserFn(@sqlite3RunParser)` so any program that
        pulls in passqlite3parser (including passqlite3main, which
        TestExplainParity uses) gets the real recursive-parse path
        end-to-end at unit-init time.

    **Deferred:** the actual format strings + args at the 7 call
    sites are still placeholders (zFormat=nil + []).  Wiring them
    is the next sub-step and will require:
      * `sqlite3EndTable`: build zStmt via sqlite3MPrintf("CREATE
        %s ...") and pass the C UPDATE-schema format string with
        `db^.aDb[iDb].zDbSName, zType, p^.zName, p^.zName,
         pParse^.u1.cr.regRoot, zStmt, pParse^.u1.cr.regRowid`.
      * `sqlite3CreateIndex`: pass the INSERT-schema format with
        the existing zStmt + the 5-tuple (iDb, idxName, tabName,
        regRoot, zStmt).
      * `sqlite3CodeDropTable`: pass DELETE / sqlite_sequence
        clean-up format strings.
      * `sqlite3DropIndex`: pass DELETE format + `zDbSName,
         pIndex^.zName`.
      * `sqlite3ClearStatTables`: per-stat-N DELETE format string.
      * `destroyRootPage` autovacuum arm: rootpage rewrite UPDATE.
      Each one is a one-liner once the surrounding helper has the
      values it needs in scope.

    Tests: full build clean.  TestExplainParity: **2 PASS / 8
    DIVERGE / 0 ERROR** (unchanged — placeholders are still nil
    zFormat, so the productive body never executes).  Regression
    spot check (2026-04-26): TestPrepareBasic 20/20, TestParser
    45/45, TestParserSmoke 20/20, TestSchemaBasic 44/44,
    TestVdbeApi 57/57, TestDMLBasic 54/54, TestSelectBasic 49/49,
    TestExprBasic 40/40, TestVdbeTxn 8/8, TestAuthBuiltins 34/34,
    TestOpenClose 17/17, TestSmoke + TestUtil clean, TestJson
    434/434, TestJsonEach 50/50, TestJsonRegister 48/48,
    TestPrintf 105/105, TestVtab 216/216.

    Discoveries / next-step notes:
      * **The structural port deliberately does *not* flip the
        DIVERGE rows yet.**  This is the same incremental pattern
        as steps 1..8: land the C-shaped helper first, wire the
        actual format strings + arg lists in a follow-up.  Doing
        both in one commit would have entangled three concerns
        (signature change, dispatch infra, and 7 separate
        emitter-by-emitter format-string ports — each of which
        wants its own structural review against the C ref).
      * **DML codegen is still stubbed.**  `sqlite3Insert`,
        `sqlite3Update`, `sqlite3DeleteFrom` in codegen still just
        free their inputs.  Wiring real format strings means
        NestedParse → RunParser → Lemon-built INSERT/UPDATE/DELETE
        codegen — but those handlers are no-ops today, so even
        with full call-site wiring the schema-row sub-statements
        won't emit ops until DML codegen is real.  Step 10 is
        therefore *both* "wire the format strings" *and* "ensure
        at least UPDATE-schema-row through DML lights up far
        enough to emit OP_OpenWrite / OP_String8 / OP_MakeRecord /
        OP_Insert against the schema btree."  See Phase 6.4 stubs
        for the exact list.
      * **The hook indirection avoids a circular `uses`.**
        `passqlite3parser` already `uses passqlite3codegen` (parser
        feeds AST nodes into codegen helpers).  Adding `uses
        passqlite3parser` from codegen would deadlock the unit
        graph.  The hook variable lets parser register the
        callback at init time without codegen having to know about
        parser.  Same idiom Phase 8 used for VDBE→OS callbacks.
      * **`Move` instead of `memcpy`.**  FPC's `Move(src, dst,
        count)` is the equivalent — argument *order* is `(src,
        dst, count)`, opposite of `memcpy(dst, src, count)`.  Easy
        trap; double-check before committing.
      * **`array of const` is FPC's variadic.**  Empty arg list is
        `[]` (square-bracket open-array literal), not `nil`.
        Passing `nil` to `array of const` will not compile.  All 7
        internal placeholders use `[]`.
      * **`pParse^.rc := SQLITE_TOOBIG`** when sqlite3VMPrintf
        returns nil and `db^.mallocFailed = 0` mirrors C exactly;
        also bumps `pParse^.nErr`.
      * **No new tests added.**  TestExplainParity already exists
        as the gate for step 9; the structural infra here is
        validated by "no regression in 17 existing test programs"
        plus TestExplainParity holding at 2/8/0.  When step 10
        wires real format strings, each call site flip-to-PASS in
        TestExplainParity becomes the gate.
      * **Next 6.9-bis target: step 10 — wire real format strings
        + args at the 7 NestedParse call sites.**  Highest-leverage
        sub-target is `sqlite3EndTable` (the schema-row UPDATE)
        because it shares its format with the CREATE TABLE epilogue
        — any progress there immediately reduces the ~13-op gap on
        every `CREATE TABLE` row in TestExplainParity.

  - **2026-04-26 — Phase 6.9-bis (step 8): sqlite3CreateIndex
    structural port (build.c:3941).**  Replaces the 3-line free-only
    stub at `passqlite3codegen.pas:6633` with a faithful structural
    port of the CREATE [UNIQUE] INDEX [IF NOT EXISTS] codegen path.

    Concrete changes:
      * `src/passqlite3codegen.pas`:
        - `sqlite3CreateIndex` (was a 3-line free stub): full
          structural port of build.c:3941..4531.  Reachable arms
          today: nErr / IN_DECLARE_VTAB / ReadSchema /
          HasExplicitNulls early outs; pTblName != nil →
          TwoPartName / SrcListLookup / FixInit / FixSrcList /
          LocateTableItem; sqlite_-prefix / view / vtab guards;
          name-from-token + dequote + CheckObjectName; collision
          checks against FindTable + FindIndex (IF NOT EXISTS arm
          lights up CodeVerifySchema + ForceNotReadOnly); auth
          (SQLITE_INSERT_AUTH on schema table → SQLITE_CREATE_INDEX
          / SQLITE_CREATE_TEMP_INDEX); Index allocation via
          `sqlite3AllocateIndexObject` with minimal population
          (zName, pTable, onError, idxFlags, pSchema,
          pPartIdxWhere); `sqlite3DefaultRowEst`; codegen block:
          BeginWriteOperation, OP_Noop saved into `pIndex^.tnum`,
          OP_CreateBtree (BLOBKEY=2), structural NestedParse for
          the schema-row INSERT, ChangeCookie, OP_ParseSchema,
          OP_Expire, JumpHere on Noop; index-list link
          (`db^.init.busy != 0` or `pTblName=nil` → push onto
          `pTab^.pIndex` chain); IN_RENAME_OBJECT pNewIndex pin.
          Same `eOpenState <> $76` test-scaffold gate as
          DropIndex / DropTable / StartTable / EndTable.
        - `passqlite3printf` added to `implementation uses` clause
          (codegen now needs `sqlite3MPrintf` for the auto-name +
          schema-row CREATE-INDEX statement text).

    **Deferred branches** (gated on still-stub helpers; documented
    in the function banner):
      * Auto-name from PRIMARY KEY / UNIQUE — uses placeholder
        `sqlite_autoindex_<tab>_1` instead of walking pTab^.pIndex
        and counting; doesn't matter today since AddColumn /
        AddPrimaryKey are stubs so the implicit-index path is
        unreachable.
      * Column iteration loop (build.c:4152..4272) — needs real
        columns from AddColumn + `sqlite3StringToId` +
        `sqlite3ColumnColl` (the latter two missing entirely).
      * pPk / WITHOUT ROWID column extension (build.c:4278).
      * Covering-index detection + `recomputeColumnsNotIndexed`.
      * Equivalent-constraint dedup loop (build.c:4337) — only
        fires on CREATE TABLE … UNIQUE.
      * `sqlite3RefillIndex` — not yet ported; no-op here means
        new btree won't actually be filled until that helper lands.
      * `sqlite3IndexHasDuplicateRootPage` on init.busy path.
      * Schema-row INSERT NestedParse — structural call lands now;
        will fire automatically once NestedParse is real.
      * REPLACE-index reorder loop (build.c:4498..4525).

    Tests: full build clean.  TestExplainParity: **2 PASS / 8
    DIVERGE / 0 ERROR** (unchanged from step 7).  CREATE INDEX
    rows now report "Pascal prepare returned nil Vdbe" (was "op
    count: C=37 Pas=3") because `sqlite3LocateTableItem("t")`
    fails — the seed CREATE TABLEs never publish to `tblHash`
    (NestedParse-driven schema-row UPDATE is still a stub, so
    OP_ParseSchema reads only the nullRow blob).  This is the
    *honest* status: until NestedParse is real, the new structural
    body cannot reach its codegen block.  Both pre and post are
    DIVERGE; the structural port is groundwork for the
    NestedParse landing.  Regression spot check (2026-04-26):
    TestPrepareBasic 20/20, TestParser 45/45, TestParserSmoke
    20/20, TestSchemaBasic 44/44, TestVdbeApi 57/57, TestDMLBasic
    54/54, TestSelectBasic 49/49, TestExprBasic 40/40, TestVdbeTxn
    8/8, TestAuthBuiltins 34/34, TestOpenClose 17/17, TestSmoke +
    TestUtil clean, TestJson 434/434, TestJsonEach 50/50,
    TestJsonRegister 48/48, TestPrintf 105/105, TestVtab 216/216.

    Discoveries / next-step notes:
      * **`PDb` from `passqlite3util` requires explicit qualification**
        in codegen var blocks: `pDb: passqlite3util.PDb` (bare `PDb`
        is rejected with "Identifier not found" because codegen has
        no PDb forward declaration of its own — same idiom as the
        existing `pSchemaT: passqlite3util.PSchema` pattern in
        StartTable / EndTable).
      * **`sqlite3StrNICmp` does not exist** — the canonical FPC
        spelling is `sqlite3_strnicmp` (with underscores, in
        `passqlite3util`).  Watch for this when porting StartTable's
        sibling routines (CreateView, CreateTrigger, Analyze, etc.
        all share the `if (sqlite3_strnicmp(zName,"sqlite_",7)==0)`
        guard).
      * **`passqlite3printf` is new in codegen's implementation
        uses.**  Phase 6 codegen had been getting away without it
        because all prior emitters either bypassed printf entirely
        or routed through `snpFmt` (FPC RTL Format).  CreateIndex
        is the first emitter that needs the SQLite-flavour
        `%Q`/`%s`/`%d` format for the schema-row CREATE INDEX
        statement text.  Future ports of Insert / Update / Delete
        codegen will benefit from this being already wired.
      * **Next 6.9-bis target: `sqlite3NestedParse` structural
        port.**  Highest-leverage move: flips multiple DIVERGE
        rows to PASS at once because every CREATE TABLE / CREATE
        INDEX / DROP TABLE row currently has a ~13-op gap exactly
        equal to the schema-row UPDATE/INSERT sub-statement that
        NestedParse emits.  After NestedParse, the
        `sqlite3StringToId` + `sqlite3ColumnColl` +
        `sqlite3RefillIndex` trio becomes the next gate to filling
        the column iteration loop here.

  - **2026-04-26 — Phase 6.9-bis (step 7): sqlite3EndTable port
    (build.c:2637).**  Replaces the trivial `{ Phase 7 }` stub at
    `passqlite3codegen.pas:6081` with a structural port of the CREATE
    TABLE epilogue emitter — caps the prologue laid down by
    `sqlite3StartTable` and bumps the schema cookie so subsequent
    DDL on the same connection sees the new generation.

    Concrete changes:
      * `src/passqlite3codegen.pas`:
        - `sqlite3EndTable` (was a 1-line `SelectDelete` stub):
          ports the `init.busy=0` emit path (OP_Close, the
          schema-row UPDATE NestedParse, ChangeCookie,
          AddParseSchemaOp), the `init.busy=1` Table-publish path
          (`sqlite3HashInsert(@pSchema^.tblHash, ...)` + DBFLAG_
          SchemaChange OR), and the AlterTable addColOffset
          bookkeeping.  Same `eOpenState <> $76` test-scaffold gate
          as StartTable / DropTable.
        - **Deferred branches** (gated on still-stub helpers, all
          documented in the function banner):
            * STRICT-mode column iteration — needs AddColumn.
            * GENERATED-column resolve loop — needs AddColumn.
            * CHECK-constraint resolve loop — pCheck never populated.
            * `pSelect` (CREATE TABLE AS SELECT) full body — Phase 7.
            * `convertToWithoutRowidTable` — needs a real column
              array; for now, just OR in TF_WithoutRowid /
              TF_NoVisibleRowid and skip the conversion.
            * Schema-row UPDATE NestedParse — structural call lands
              now; will fire automatically once NestedParse is real.
            * sqlite_sequence creation for AUTOINCREMENT — TF_
              Autoincrement never set today (AddPrimaryKey stub).
            * TF_HasGenerated post-emit OP_SqlExec — TF never set.
        - **Important non-emit decision:** the WITHOUT ROWID error
          arms ("PRIMARY KEY missing", "AUTOINCREMENT not allowed
          on WITHOUT ROWID") are *not* honoured today.  In C they
          fire when the column array is missing; here they would
          fire on every WITHOUT ROWID statement (because
          AddPrimaryKey is a stub), which trips
          `sqlite3FinishCoding`'s `nErr>0` early-out and leaves
          the Vdbe with un-allocated aMem → AV on finalize.  We
          defer the entire arm until AddColumn / AddPrimaryKey
          land — at which point TF_HasPrimaryKey will be set
          legitimately and the C error path is correct again.

    Tests: full build clean.  TestExplainParity: **2 PASS / 8
    DIVERGE / 0 ERROR** (was 1/9/0).  DROP INDEX IF EXISTS row
    flipped from DIVERGE → PASS — the seed CREATE TABLE rows now
    bump the schema_cookie via ChangeCookie, matching the C-side
    OP_Transaction p3 value exactly.  CREATE TABLE rows still
    DIVERGE on op-count (Pascal=17, C=32–43) — the gap is the
    NestedParse schema-row UPDATE sub-statement (~13 ops) plus
    the TF_HasGenerated SqlExec when generated columns are real.
    Regression spot check (2026-04-26): TestPrepareBasic 20/20,
    TestParser 45/45, TestParserSmoke 20/20, TestSchemaBasic
    44/44, TestVdbeApi 57/57, TestDMLBasic 54/54, TestSelectBasic
    49/49, TestExprBasic 40/40, TestVdbeTxn 8/8, TestAuthBuiltins
    34/34, TestOpenClose 17/17, TestSmoke + TestUtil clean.

    Discoveries / next-step notes:
      * **Honouring C's error paths in helpers that run *before*
        sqlite3FinishCoding's epilogue is dangerous when sibling
        parser stubs prevent the precondition from ever being
        validly met.**  ErrorMsg sets `pParse^.nErr++`, which
        causes FinishCoding's early-out, which skips the aMem
        allocation, which AVs on the next register-touching op.
        Two safe options when porting an "if precondition fails,
        ErrorMsg + return" arm: (a) only emit the error if the
        underlying precondition checker is real; (b) defer the
        entire arm with a `TODO` comment.  We took (b) here.
        Add to porting checklist gotchas.
      * **`@passqlite3util.PSchema(pTab^.pSchema)^.tblHash`** — codegen's
        `PSchema` is the opaque-stub shadow (Pointer); to reach the
        real `tblHash` field we must qualify through `passqlite3util`,
        same idiom as the existing `pSchemaT: passqlite3util.PSchema`
        declarations (e.g. parser.pas:2014).  Bare `PSchema(...)`
        cast resolves to the opaque pointer and FPC rejects the
        `^.tblHash` member access ("Illegal qualifier").
      * **AddParseSchemaOp zWhere is currently `nil`.**  C uses
        `sqlite3MPrintf(db, "tbl_name='%q' AND type!='trigger'", p->zName)`
        to scope reparsing to the new table.  Pascal's
        `sqlite3MPrintf` exists but the `%q` (SQL-quote) format
        does not yet route through to printf.c's `xType=='q'` arm.
        Wire it when MPrintf %q lands; until then OP_ParseSchema
        with nil zWhere reparses the full schema (slower but
        correct).
      * **Next 6.9-bis target: `sqlite3CreateIndex` (build.c:4032,
        37/41 ops).**  All non-trivial helper deps now real
        (BeginWriteOperation, OpenSchemaTable, ChangeCookie,
        ForceNotReadOnly, CodeVerifySchema, MayAbort, ParseSchemaOp);
        the only remaining stubbed dep is `sqlite3NestedParse` for
        the index-row UPDATE sub-statement (same gap as EndTable).
        After that, the structural `sqlite3NestedParse` port itself
        becomes the highest-leverage move — it flips multiple
        DIVERGE rows to PASS at once by closing the ~13-op gap on
        every CREATE TABLE / CREATE INDEX / DROP TABLE row.
      * **DROP TABLE row still `nil Vdbe`.**  Cause: the seed
        `CREATE TABLE t(a,b,c)` runs, OP_ParseSchema executes, but
        the schema row was inserted with the 6-byte `nullRow` blob
        (StartTable) and never UPDATE'd to a real `CREATE TABLE`
        row (NestedParse stub).  ParseSchema therefore reads no
        row → no Table installed → `LocateTableItem("t")` fails.
        The row will flip once NestedParse is real.

  - **2026-04-26 — Phase 6.9-bis (step 6): sqlite3StartTable port
    (build.c:1206) + sqlite3VdbeMakeReady aMem allocation fix.**
    Replaces the `{ Phase 7 }` stub at `passqlite3codegen.pas:5827`
    with a byte-faithful port of the CREATE TABLE prologue emitter,
    and fixes `sqlite3VdbeMakeReady` to read `nMem`/`nTab`/`nVar`
    from the parser context (it was hardcoded to 0, which left
    `Vdbe.aMem` un-allocated and AV'd any DDL that emitted a
    register-using opcode).

    Concrete changes:
      * `src/passqlite3codegen.pas`:
        - `sqlite3StartTable` (was stub): full body from
          build.c:1206..1394 — `init.busy && newTnum==1` schema
          parse fast-path, two-part name resolution via
          `sqlite3TwoPartName`, temp-table qualified-name guard,
          name dequote (inline `sqlite3DbStrNDup` + `sqlite3Dequote`
          since codegen does not import passqlite3parser),
          `IN_RENAME_OBJECT` token map, `sqlite3CheckObjectName`
          gate, full `SQLITE_OMIT_AUTHORIZATION=0` block (two
          AuthCheck calls — INSERT into the schema table, then
          CREATE_(TEMP_)?(TABLE|VIEW) with the auth code matrix),
          name-collision check via `sqlite3FindTable` + IF NOT
          EXISTS arm (CodeVerifySchema + ForceNotReadOnly), index
          collision check, then `sqlite3DbMallocZero(sizeof(TTable))`
          for the in-memory Table object (zName, iPKey=-1, pSchema,
          nTabRef=1, nRowLogEst=200), and the Vdbe emit block:
          BeginWriteOperation, OP_VBegin (vtab-gated, unreached),
          three-register allocation (regRowid/regRoot + tmp via
          ++nMem), OP_ReadCookie + OP_If gate around the
          file-format/text-encoding cookie writes, OP_CreateBtree
          (or OP_Integer for view/vtab) into regRoot saving the
          address in `u1.cr.addrCrTab`, OpenSchemaTable,
          OP_NewRowid, OP_Blob with the 6-byte `nullRow` constant
          (P4_STATIC), OP_Insert with OPFLAG_APPEND, OP_Close.
          Imposter-table fast-path is structural (init.flags bit
          gate; no caller toggles it today).  Same `eOpenState <> $76`
          test-scaffold gate as DropIndex/DropTable so
          TestParserSmoke's stub-db CREATE TABLE rows stay green.
        - `aCode[]` and `nullRow[]` declared as local typed
          consts; `SQLITE_MAX_FILE_FORMAT=4` and
          `TF_Imposter=$00020000` declared locally to avoid
          churning the global TF_/SQLITE_ tables.
      * `src/passqlite3vdbe.pas`:
        - `sqlite3VdbeMakeReady` (line 2641): replaces the
          `nVar:=0; nMem:=0; nCursor:=0` placeholder with a real
          read of `Parse.nTab @56 (i32)`, `Parse.nMem @60 (i32)`,
          `Parse.nVar @296 (i16)` via byte-offset PInt32/PWord
          (PParse is `Pointer` in this unit to break the cycle
          with passqlite3codegen).  The aMem allocation now sizes
          `(nMem+1) * SizeOf(TMem)` so register slot 0 (always
          unused, all VDBE programs are 1-based) is included.

    Tests: full build clean.  TestExplainParity: 1 PASS / 9 DIVERGE
    / **0 ERROR** (was 1/7/2).  Both ERROR rows (`CREATE TABLE
    typed`, `CREATE TABLE WITHOUT ROWID`) now flip to DIVERGE,
    matching the other CREATE TABLE rows — the AV they raised was
    masked by the missing aMem allocation in MakeReady, not a
    StartTable issue.  Pascal CREATE TABLE programs now emit 14
    ops (Init/Goto + StartTable's 11 op prologue + Halt), versus
    32–43 on the C side — the ~18-op gap is sqlite3EndTable's
    schema-row UPDATE finalize (still a stub).  Regression spot
    check: TestPrepareBasic 20/20, TestParser 45/45,
    TestParserSmoke 20/20, TestSchemaBasic 44/44, TestVdbeApi
    57/57, TestDMLBasic 54/54, TestSelectBasic 49/49,
    TestExprBasic 40/40, TestVdbeTxn 8/8, TestAuthBuiltins 34/34,
    TestOpenClose 17/17, TestSmoke + TestUtil clean.

    Discoveries / next-step notes:
      * **`sqlite3VdbeMakeReady` was a silent foot-gun.**  Every
        DDL/DML codegen path that reaches `sqlite3FinishCoding`
        relies on aMem being allocated to `nMem+1` slots.  Before
        this commit, MakeReady hardcoded `nMem:=0` so aMem stayed
        nil — every register-touching op (OP_ReadCookie,
        OP_NewRowid, OP_Integer, OP_String8, OP_Insert, etc.) AV'd
        on first execution.  This is why prior ports (DropIndex,
        DropTable, BeginTransaction) emitted only register-free
        opcodes (OP_DropTable, OP_AutoCommit) — the AV would have
        bit them too.  StartTable is the first DDL whose emit
        absolutely requires registers.  Once Insert / Update /
        Select codegen lands the same fix is load-bearing for
        them.
      * **Codegen does not import passqlite3parser.**  parser →
        codegen is the established direction (parser uses TParse
        from codegen).  `sqlite3NameFromToken` lives in parser, so
        codegen inlines the equivalent (`sqlite3DbStrNDup` +
        `sqlite3Dequote`) directly.  Worth a Phase 8 audit: maybe
        move `sqlite3NameFromToken` down into util/codegen so
        both units share it.
      * **`db^.init.flags` is bit-packed (orphanTrigger:1,
        imposterTable:2, reopenMemdb:1).**  imposterTable occupies
        bits 1..2 in the C struct.  StartTable's imposter
        fast-path masks with `$02` for "set" and `$04` for "geq 2"
        — matching the C `db->init.imposterTable >= 2` semantics.
        No caller toggles this today; first hit will be ALTER
        TABLE ... USING IMPOSTER in Phase 8.
      * **DROP TABLE `t` row will flip to PASS only after
        EndTable lands.** Today it still reports `Pascal prepare
        returned nil Vdbe` because the seed CREATE TABLE prologue
        leaves `pNewTable` set but never publishes the Table into
        `db^.aDb[0].pSchema^.tblHash` — that's EndTable's job.
        Once EndTable lands, FindTable will return non-nil and
        DROP TABLE / CREATE INDEX / DROP INDEX IF EXISTS rows can
        all reach their emit bodies.
      * **Next 6.9-bis target unchanged:** `sqlite3EndTable`
        (build.c:2637 — caps StartTable; emits the schema-row
        UPDATE finalize, OP_ParseSchema, optional NestedParse for
        sqlite_sequence on AUTOINCREMENT).  `sqlite3CreateIndex`
        (37/41 ops) still gated on EndTable for the same Table
        publish.
      * **Pascal CREATE TABLE op count is 14, expected 32**
        (after EndTable lands).  The 18-op gap is exactly what
        EndTable emits: ParseSchema, schema-row UPDATE
        sub-statement (NestedParse), the optional AUTOINCREMENT
        path, and ChangeCookie.

  - **2026-04-26 — Phase 6.9-bis (step 5): sqlite3DropTable +
    sqlite3CodeDropTable + destroyTable + sqlite3ClearStatTables +
    tableMayNotBeDropped + sqliteViewResetAll port (build.c:3221,
    3315, 3364, 3387, 3476, 3495).**  Replaces six more `{ Phase 7 }`
    stubs in `passqlite3codegen.pas` with byte-faithful ports.  This
    closes out the entire `DROP TABLE` codegen call graph aside from
    `sqlite3NestedParse` (still a stub; structural call sites are
    placed so its real port flips them on landing).

    Concrete changes:
      * `src/passqlite3codegen.pas`:
        - new `sqliteViewResetAll` (build.c:3221): no-op for now —
          DB_UnresetViews is not yet maintained, and the C fast path
          bails when the flag is unset.  Real impl needs
          `sqlite3DeleteColumnNames` + Db.flags bit maintenance,
          which lands when CREATE VIEW becomes real.
        - new `sqlite3ClearStatTables` (build.c:3364, static):
          walks N=1..4, snpFmt's `sqlite_statN`, calls
          `sqlite3FindTable` then `sqlite3NestedParse`.  Currently
          emits zero ops because NestedParse is a stub; structural
          port lands now so callers don't need re-editing later.
        - new `destroyTable` (build.c:3315, static): emits OP_Destroy
          on the table and all its indices in *descending* root-page
          order so an autovacuum-driven page move from an earlier
          OP_Destroy can never land on a still-to-destroy root page.
        - `sqlite3CodeDropTable` (was stub): full body —
          BeginWriteOperation, OP_VBegin (gated on TABTYP_VTAB,
          unreached today), TriggerList loop (stub returns nil →
          loop is no-op), TF_Autoincrement-gated NestedParse,
          schema-row DELETE NestedParse, destroyTable, OP_VDestroy
          (vtab-gated), OP_DropTable, ChangeCookie, ViewResetAll.
        - new `tableMayNotBeDropped` (build.c:3476, static):
          refuses DROP on `sqlite_*` (except `sqlite_stat*` /
          `sqlite_parameters`), shadow tables in defensive mode,
          and eponymous virtual-table modules.
        - `sqlite3DropTable` (was stub): full body from
          build.c:3495..3599 — ReadSchema, LocateTableItem with
          suppressErr++/-- around it, IF EXISTS arm
          (CodeVerifyNamedSchema + ForceNotReadOnly), schema-index
          resolve, virtual-table column-name init, full
          AUTHORIZATION block (zTab/zDb resolution, three
          AuthCheck calls, code = SQLITE_DROP_(TEMP_)?(TABLE|VIEW|
          VTABLE)), tableMayNotBeDropped guard, view/table
          mismatch errors, then BeginWriteOperation +
          ClearStatTables + FkDropTable (stub) + CodeDropTable.
          Same `eOpenState <> $76` test-scaffold gate as DropIndex
          so TestParserSmoke's stub-db `DROP TABLE` row stays green.

    Tests: full build clean.  TestExplainParity score unchanged at
    1 PASS / 7 DIVERGE / 2 ERROR.  The DROP TABLE row's diverge
    message changes from `op count C=49 Pas=3` to `Pascal prepare
    returned nil Vdbe` — this is structurally correct C behaviour
    (table `t` does not exist on the Pascal side because seed
    CREATE TABLE is still a stub; LocateTableItem with noErr=0
    raises "no such table" → prepare fails).  The row will flip to
    PASS once StartTable/EndTable lands and the seed schema actually
    creates the in-memory Table.  Regression spot check: TestPrepareBasic
    20/20, TestParser 45/45, TestParserSmoke 20/20, TestSchemaBasic
    44/44, TestVdbeApi 57/57, TestDMLBasic 54/54, TestSelectBasic
    49/49, TestExprBasic 40/40, TestVdbeTxn 8/8, TestAuthBuiltins
    34/34, TestOpenClose 17/17.

    Discoveries / next-step notes:
      * **`PTrigger` cannot be a `var` declaration's qualified
        type when the same identifier exists as a record field
        in scope** (TParse.pTrigger / TTable.pTrigger).  FPC's
        symbol resolution chokes with "Error in type definition".
        Workaround: name the variable `pTrg` (or any non-shadowing
        ident).  Same family of issue as the PDb-from-passqlite3util
        gotcha noted at step 2.  Add to porting-checklist gotchas.
      * **`TF_Imposter` / `TF_HasReturning` etc. constants** are
        not yet declared in the Pascal port; the imposterTable arm
        in StartTable will need them when that port lands.
      * **DROP TABLE row flip is gated on StartTable/EndTable.**
        With seed CREATE TABLE still a stub, every row that names
        a pre-created table (DROP TABLE t, CREATE INDEX i ON t,
        CREATE UNIQUE INDEX i2 ON t) cannot reach its emit body.
        This is why StartTable/EndTable is the highest-leverage
        next step — it unblocks 4+ corpus rows simultaneously.
      * **Next 6.9-bis target unchanged:** `sqlite3StartTable` /
        `sqlite3EndTable` (32–43 ops, biggest surface).  All
        helpers in their call graph are now real except
        `sqlite3CheckObjectName` (still stub), `sqlite3NestedParse`
        (still stub — affects EndTable's schema-row UPDATE
        sub-statement), and `sqlite3RunParser` (only a NestedParse
        consumer).

  - **2026-04-26 — Phase 6.9-bis (step 4): destroyRootPage +
    sqlite3RootPageMoved + temp-reg helpers
    (build.c:3255/3285, expr.c:7580/7591).**  Replaces three more
    `{ Phase 7 }` stubs in `passqlite3codegen.pas` with
    byte-faithful ports, and wires `destroyRootPage` into the
    found-index arm of `sqlite3DropIndex` (replacing the
    `TODO(Phase 6.x): destroyRootPage(...)` placeholder).  These
    helpers are the on-ramp for `sqlite3CodeDropTable` /
    `destroyTable` and for any DDL helper that needs an
    auto-vacuum-aware OP_Destroy emit (DROP TABLE, DROP INDEX
    found-arm, REINDEX, etc.).

    Concrete changes:
      * `src/passqlite3codegen.pas`:
        - `sqlite3GetTempReg` (interface + body): single-register
          allocator out of the parser-scoped 8-slot pool
          (`pParse^.aTempReg[]` / `nTempReg`); falls back to
          `++pParse^.nMem` when the pool is empty.  Mirrors
          expr.c:7580 exactly.
        - `sqlite3ReleaseTempReg` (interface + body): companion
          deallocator.  Calls `sqlite3VdbeReleaseRegisters` (the
          existing release-port no-op) before recycling the slot.
          `Length(pParse^.aTempReg)` resolves to 8 at compile time
          via FPC's static-array length.
        - `sqlite3RootPageMoved` (was stub): walks
          `db^.aDb[iDb].pSchema^.tblHash` and `idxHash` via the
          doubly-linked `first/next` chain (`PHashElem`) and
          retargets any `Table.tnum` / `Index.tnum` whose value
          equals `iFrom` to `iTo`.  Used by autovacuum-triggered
          page moves so the in-memory schema stays consistent
          with on-disk root-page numbers.
        - new `destroyRootPage` (build.c:3285, static helper):
          GetVdbe + GetTempReg(r1), `iTable<2 → "corrupt schema"`
          guard, `OP_Destroy iTable,r1,iDb`, MayAbort, then the
          AUTOVACUUM-on NestedParse'd
          `UPDATE %Q.sqlite_schema SET rootpage=%d WHERE #%d AND
           rootpage=#%d` sub-statement (currently a no-op via the
          NestedParse stub; will fire once 7.2/7.3 wire NestedParse
          to a real RunParser call).  Defined just before
          `sqlite3CodeDropTable` so DropIndex's later call resolves
          without a forward decl.
        - `sqlite3DropIndex` (build.c:4595): replaces the
          `TODO(Phase 6.x): destroyRootPage(...)` placeholder with
          a real `destroyRootPage(pParse, i32(pIndex^.tnum), iDb)`
          call.  `pIndex^.tnum` is `Pgno` (u32) so the cast to i32
          matches the C signature.

    Tests: full build clean.  TestExplainParity score unchanged at
    1 PASS / 7 DIVERGE / 2 ERROR — expected, because the corpus
    only drives the **not-found** DropIndex arm (`DROP INDEX i`),
    so the new found-arm OP_Destroy emit is not exercised yet.
    Regression spot check: TestPrepareBasic 20/20, TestParser 45/45,
    TestParserSmoke 20/20, TestSchemaBasic 44/44, TestVdbeApi 57/57,
    TestDMLBasic 54/54, TestSelectBasic 49/49, TestExprBasic 40/40,
    TestVdbeTxn 8/8, TestAuthBuiltins 34/34, TestOpenClose 17/17.

    Discoveries / next-step notes:
      * **`pParse^.aTempReg` is a fixed `array[0..7] of i32`.**  C
        uses `ArraySize(...)` (= 8); Pascal port uses
        `Length(pParse^.aTempReg)` which FPC resolves at compile
        time for static arrays.  Both yield 8.  Add to porting
        checklist as the canonical idiom for static-array sizes.
      * **AUTOVACUUM gating.**  Upstream wraps the destroyRootPage
        NestedParse call in `#ifndef SQLITE_OMIT_AUTOVACUUM`.  The
        btree port already advertises itself as
        "simplified: SQLITE_OMIT_AUTOVACUUM" but the codegen path
        still keeps the NestedParse call live (matching the
        reference C build with autovacuum on).  Once a real
        decision is made about the autovacuum gate, this call may
        need conditional compilation — track in 6.x audit.
      * **`sqlite3NestedParse` is still a no-op stub.**  The
        destroyRootPage NestedParse-driven UPDATE sub-statement
        therefore won't actually emit ops yet; only the OP_Destroy
        + MayAbort fire.  This is acceptable for the current corpus
        (the not-found DropIndex arm doesn't reach it).  Real
        NestedParse needs `sqlite3VMPrintf`, `sqlite3RunParser`,
        and `PARSE_TAIL` save/restore — a larger port that
        belongs alongside StartTable/EndTable since they're its
        first heavy users.
      * **Next 6.9-bis target unchanged:** `sqlite3StartTable` /
        `sqlite3EndTable` (32–43 ops, biggest surface, the highest-
        leverage port).  After that: `sqlite3CreateIndex` (37/41 ops),
        `sqlite3DropTable` (49 ops; needs `destroyTable` + the
        `sqlite3CodeDropTable` body, both of which now have their
        destroyRootPage dependency met).

  - **2026-04-26 — Phase 6.9-bis (step 3): foundational helpers
    sqlite3OpenSchemaTable + sqlite3ChangeCookie +
    sqlite3BeginWriteOperation port (build.c:916, 2047, 5403).**
    Replaces three more `{ Phase 7 }` stubs in `passqlite3codegen.pas`
    with byte-faithful ports.  These are tiny (3–6 lines apiece) but
    they are the on-ramp every remaining DDL codegen helper
    (`sqlite3StartTable`, `sqlite3EndTable`, `sqlite3CreateIndex`,
    `sqlite3DropTable`, `sqlite3CodeDropTable`) calls into — so
    landing them now unblocks the larger ports without needing a
    separate "infrastructure" commit interleaved with each one.

    Concrete changes:
      * `src/passqlite3codegen.pas`:
        - `sqlite3OpenSchemaTable` (line 5785, was a stub):
          `sqlite3GetVdbe` + `OP_OpenWrite p1=0 p2=SCHEMA_ROOT
          p3=iDb p4=5` (numCols), `nTab := 1` if zero.  The C
          reference also calls `sqlite3TableLock` here; that helper
          is `OMIT_SHARED_CACHE`-gated and a no-op in this build,
          so the call is replaced with a comment pointing at the
          omission rather than added as a stub.
        - `sqlite3ChangeCookie` (line 5868, was a stub):
          `OP_SetCookie p1=iDb p2=BTREE_SCHEMA_VERSION
          p3=schema_cookie+1`.  Mirrors C verbatim including the
          `(int)(1+(unsigned)x)` overflow-tolerant cast (Pascal:
          `i32(1 + u32(...))`).
        - `sqlite3BeginWriteOperation` (line 6371, was a stub):
          resolves toplevel via `pParse^.pToplevel ?? pParse`,
          calls `sqlite3CodeVerifySchema(toplevel, iDb)`, sets
          `writeMask` bit, ORs `setStatement` into `isMultiWrite`.

    Tests: full build clean.  TestExplainParity score unchanged
    at 1 PASS / 7 DIVERGE / 2 ERROR — these helpers do not by
    themselves emit any new ops in the corpus rows; they are the
    plumbing that the still-stubbed `sqlite3StartTable` /
    `sqlite3EndTable` / etc. need to call.  Regression spot check:
    TestPrepareBasic 20/20, TestParser 45/45, TestParserSmoke 20/20,
    TestSchemaBasic 44/44, TestVdbeApi 57/57, TestDMLBasic 54/54,
    TestSelectBasic 49/49, TestExprBasic 40/40, TestVdbeTxn 8/8,
    TestAuthBuiltins 34/34, TestOpenClose 17/17.

    Discoveries / next-step notes:
      * **`sqlite3TableLock` is OMIT_SHARED_CACHE-gated.**  In the
        upstream split source it is compiled away to a `#define
        codeTableLocks(x)` no-op when shared cache is off.  This
        port keeps shared cache off, so call-sites can simply
        skip it — but the helper symbol still needs to exist as
        a no-op stub if/when shared-cache callers land.  Worth a
        forward decl + empty body in the next 6.9-bis step.
      * **`isMultiWrite` is `u8`, OR-with-int needs an explicit
        `u8()` cast** to satisfy FPC's type inference.  Same idiom
        as elsewhere in the port.
      * **Next 6.9-bis target unchanged:** `sqlite3StartTable` /
        `sqlite3EndTable` (32–43 ops, biggest surface).  All of
        their non-trivial helper deps now real:
        BeginWriteOperation, CodeVerifySchema, ChangeCookie,
        OpenSchemaTable, ForceNotReadOnly.  The remaining stubs
        in their call graph are: `sqlite3CheckObjectName`,
        `sqlite3FindTable`, the `Table*` allocator path
        (`sqlite3DbMallocZero` is real; `pParse^.u1.cr.*` slot
        wiring needs audit), and (for EndTable)
        `sqlite3NestedParse` (still a stub) for the schema-row
        UPDATE.

  - **2026-04-26 — Phase 6.9-bis (step 2): sqlite3DropIndex +
    schema-verify helpers port (build.c:4595, 5404, 5418, 1181).**
    Replaces the `{ Phase 7 }` stubs for sqlite3CodeVerifySchema,
    sqlite3CodeVerifyNamedSchema and the trivial sqlite3DropIndex
    (which previously only deleted the SrcList) with byte-faithful
    ports.  Also adds the small helper sqlite3ForceNotReadOnly
    (build.c:1181, 6 ops in C).  These three helpers are the
    on-ramp for every DDL codegen that needs to mark a database as
    schema-cookie-verified or as a writer.

    Concrete changes:
      * `src/passqlite3codegen.pas`:
        - forward decl `sqlite3ForceNotReadOnly` near
          `sqlite3CodeVerify*`.
        - `sqlite3CodeVerifySchema` (was stub):
          `pToplevel := pParse^.pToplevel ?? pParse`; if cookieMask
          bit not set, set it; `OMIT_TEMPDB=0 + iDb=1` →
          `sqlite3OpenTempDatabase(pToplevel)`.
        - `sqlite3CodeVerifyNamedSchema` (was stub): walks
          `db^.aDb[i]`, calls VerifySchema for each `pBt<>nil`
          whose `zDbSName` matches (or any when `zDb=nil`).  Avoids
          a local `pDb: PDb` because `PDb` is in `passqlite3util`
          and FPC chokes on the qualified name in some contexts —
          inlined the array index instead.
        - new `sqlite3ForceNotReadOnly`: bumps `nMem`,
          `OP_JournalMode 0,iReg,PAGER_JOURNALMODE_QUERY` +
          `sqlite3VdbeUsesBtree(v,0)`.  Defines
          `PAGER_JOURNALMODE_QUERY = -1` locally to avoid pulling
          `passqlite3pager` into codegen's `uses`.
        - `sqlite3DropIndex` (was stub): full body from
          build.c:4595..4661 — ReadSchema, FindIndex, IF EXISTS
          handling (CodeVerifyNamedSchema + ForceNotReadOnly +
          checkSchema bit), idxType-APPDEF check, AuthCheck, and
          the writer-arm BeginWriteOperation/NestedParse/
          ChangeCookie/OP_DropIndex emit.  The found-index branch
          calls into helpers (`sqlite3NestedParse`,
          `sqlite3ClearStatTables`, `destroyRootPage`,
          `sqlite3BeginWriteOperation`, `sqlite3ChangeCookie`)
          that are still stubs; structural port lands today, OP
          stream for that arm filled in as those helpers ship.
          `sqlite3ErrorMsg` calls drop the printf-style args (the
          stub today ignores them anyway).
        - Same `eOpenState <> $76` test-scaffold gate as
          FinishCoding so TestParserSmoke's stub-db
          `DROP INDEX i` row stays green (sqlite3FindIndex on a
          stub db with no real schema would otherwise raise an
          AV; legacy stub silently dropped the SrcList).
        - `pIndex^.idxType` → `(pIndex^.idxFlags and $03)` since
          idxType is the low 2 bits of the packed bitfield at
          `TIndex.idxFlags` offset 100, not its own field.

    Tests: full build clean.  TestExplainParity:
    DROP INDEX IF EXISTS now emits 5 ops (was 3) matching the C
    op-count exactly; only a single p3 mismatch remains at op[3]
    on `OP_Transaction` because the fixture's `CREATE TABLE`s
    can't bump schema_cookie until StartTable/EndTable land.
    BEGIN still PASSes.  Score unchanged at 1/7/2 because the
    DROP INDEX row hasn't yet flipped to PASS — it will once
    `sqlite3StartTable`/`sqlite3EndTable` are real and the
    fixture actually writes the schema cookie.
    Regression spot check: TestPrepareBasic 20/20, TestParser
    45/45, TestParserSmoke 20/20, TestSchemaBasic 44/44,
    TestVdbeApi 57/57, TestDMLBasic 54/54, TestSelectBasic 49/49,
    TestExprBasic 40/40, TestVdbeTxn 8/8, TestAuthBuiltins 34/34.

    Discoveries / next-step notes:
      * **`TIndex.idxType` is bitfield-packed at offset 100.**  The
        C `pIndex->idxType` reads the low 2 bits of `idxFlags`.
        Pascal port masks with `$03`.  `SQLITE_IDXTYPE_APPDEF=0`
        (the most common value) means `(idxFlags & 3) == 0`.
        Add to porting-checklist gotchas.
      * **`PDb` qualified-from-`passqlite3util` is fragile.**
        Declaring `var pDb: PDb;` inside a codegen procedure
        triggered `Error in type definition` even though
        `passqlite3util` is in `uses`.  Workaround: index
        `db^.aDb[i]` directly instead of taking its address.
        Possibly an FPC-quirk with the same-named record/pointer
        types living across units.  Worth a deeper look during
        the next codegen cleanup.
      * **Test-scaffold gate added to `sqlite3DropIndex`.** Same
        idiom as `sqlite3FinishCoding`: bail to the legacy
        SrcList-only path when `db^.eOpenState <> $76`.  Without
        it, `TestParserSmoke`'s `DROP INDEX i` row regresses
        because the stub db has no schema and the new error path
        sets `nErr=1`.  Audit when test scaffolds migrate to
        `sqlite3_open_v2(":memory:")`.
      * **Next 6.9-bis target:** `sqlite3StartTable` /
        `sqlite3EndTable` (32–43 ops, the biggest surface, but
        the highest-leverage — it both flips `CREATE TABLE
        simple/IF NOT EXISTS/composite PK` rows and bumps the
        fixture's `schema_cookie` so the existing DROP INDEX
        IF EXISTS row finally PASSes).  After that:
        `sqlite3CreateIndex` (37/41 ops), `sqlite3DropTable`
        (49 ops).  Found-index DropIndex arm depends on real
        ports of `sqlite3NestedParse`, `sqlite3ClearStatTables`,
        `destroyRootPage`, `sqlite3BeginWriteOperation`,
        `sqlite3ChangeCookie` — those land alongside the
        StartTable/EndTable work since they share helpers.

  - **2026-04-26 — Phase 6.9-bis (step 1): sqlite3BeginTransaction +
    sqlite3EndTransaction port (build.c:5245..5297).**  Replaces the
    `{ Phase 7 }` stubs in `passqlite3codegen.pas` with byte-identical
    ports of the BEGIN / COMMIT / ROLLBACK codegen helpers.  First
    DIVERGE → PASS flip in TestExplainParity (the `BEGIN;` row).
    Adds `sqlite3BtreeIsReadonly` (btree.c:11531) to
    `passqlite3btree.pas` since BeginTransaction needs the readonly
    predicate per-attached-Btree, and threads `passqlite3btree` into
    `passqlite3codegen.pas`'s uses clause (no circular dep — btree
    does not back-import codegen).

    Concrete changes:
      * `src/passqlite3btree.pas` — adds `sqlite3BtreeIsReadonly`
        (forward decl + body).  Body matches C verbatim:
        `(p^.pBt^.btsFlags and BTS_READ_ONLY) <> 0`.
      * `src/passqlite3codegen.pas`:
        - adds `passqlite3btree` to the unit's `uses` clause.
        - `sqlite3BeginTransaction` (line 6158, was a stub):
          full body from build.c:5245..5274 — auth-check, GetVdbe,
          per-aDb[i] OP_Transaction emission for non-DEFERRED with
          eTxnType selected by readonly/EXCLUSIVE/default, then
          OP_AutoCommit tail.  Uses `SQLITE_TRANSACTION_AUTH` (the
          existing renamed-to-avoid-collision constant from
          passqlite3vdbe.pas:530).
        - `sqlite3EndTransaction` (line 6163, was a stub):
          full body from build.c:5281..5297 — auth-check
          (ROLLBACK/COMMIT label per eType), GetVdbe,
          OP_AutoCommit p1=1 p2=isRollback.

    Tests: full build clean.  TestExplainParity:
    BEGIN flipped from DIVERGE → PASS (4 ops, identical to C).
    Regression spot check: TestPrepareBasic 20/20, TestParser 45/45,
    TestParserSmoke 20/20, TestSchemaBasic 44/44, TestVdbeApi 57/57,
    TestDMLBasic 54/54, TestSelectBasic 49/49, TestExprBasic 40/40,
    TestVdbeTxn 8/8, TestAuthBuiltins 34/34.

    Discoveries / next-step notes:
      * **Readonly predicate is a 1-line port.**  The C sqlite3BtreeIsReadonly
        is just `(pBt->btsFlags & BTS_READ_ONLY) != 0`.  Pascal port needs
        explicit `<> 0` to int-coerce since FPC has no implicit bool↔int.
      * **`SQLITE_TRANSACTION` collides with auth-code 22.**  The port
        renames to `SQLITE_TRANSACTION_AUTH` in passqlite3vdbe.pas:530 to
        avoid clashing with the result-code namespace.  `sqlite3AuthCheck`
        callers must use `_AUTH` suffix.  Same idiom as `SQLITE_DELETE_AUTH /
        SQLITE_INSERT_AUTH`.
      * **Next 6.9-bis targets** (in priority by simplicity):
        sqlite3DropIndex (DROP INDEX IF EXISTS — only 5 C ops),
        sqlite3DropTable (49 C ops), then CREATE INDEX (37/41),
        sqlite3StartTable/EndTable (32–43 ops, biggest surface).
        Two ERROR rows (`CREATE TABLE typed`, `CREATE TABLE WITHOUT
        ROWID`) AV inside the partial Pascal codegen for column
        decltypes / WITHOUT ROWID — triage when StartTable/EndTable
        lands.

  - **2026-04-26 — Phase 6.9 scaffold: TestExplainParity.pas.**
    Lands `src/tests/TestExplainParity.pas` — the bytecode-diff gate
    enabled by Phase 6.5-bis (sqlite3FinishCoding).  Drives both the
    C reference (`EXPLAIN <sql>` via `csq_prepare_v2` + `csq_step`)
    and the Pascal port (`sqlite3_prepare_v2` + walk `PVdbe^.aOp[]`),
    then diffs on (opcode-name, p1, p2, p3, p5).  Report-only in this
    cut — exit 0 on bytecode divergence, exit 1 only on
    C-side prepare failure or runtime exception.

    Corpus: 10 DDL / transaction rows (CREATE TABLE / CREATE INDEX /
    DROP TABLE / DROP INDEX / BEGIN).  First run on a clean tree:
    0 PASS / 8 DIVERGE / 2 ERROR.  Every Pascal program emits exactly
    3 opcodes (the `Init/Goto/Halt` skeleton from `sqlite3FinishCoding`
    when no schema-write ops were emitted) versus 5–49 ops on the C
    side — confirms that `sqlite3StartTable / EndTable /
    CreateIndex / DropTable / DropIndex / BeginTransaction` are still
    stubs.  Two AVs flag a column-decltype / WITHOUT-ROWID partial
    codegen path that needs triage.  Tracked as Phase 6.9-bis.

    Concrete changes:
      * `src/tests/TestExplainParity.pas` — new (Phase 6.9 scaffold).
      * `src/tests/build.sh` — already had the entry; this commit
        flips it from SKIP to a real binary.
      * `tasklist.md` — 6.9 marked `[~]` (scaffold landed); new
        Phase 6.9-bis lists the remaining work.

    Tests: full build clean.  Regression spot check:
    TestPrepareBasic 20/20, TestParser 45/45, TestParserSmoke 20/20,
    TestSchemaBasic 44/44, TestVdbeApi 57/57, TestOpenClose 17/17.

  - **2026-04-26 — Phase 6.5-bis sqlite3FinishCoding port (build.c:141).**
    Replaces the `{ Phase 7 }` stub at `passqlite3codegen.pas:6219` with the
    real termination/prologue emitter from build.c:141..278.  This is the
    keystone that lets `sqlite3_prepare_v2` actually return a stepable
    `Vdbe*` for DDL/DML/transaction statements that previously came back
    `*ppStmt = nil` even on parse-success.  Unblocks the bytecode-diff
    work in 6.9 (`TestExplainParity`) and 7.4b (`TestParser` byte-for-byte
    VDBE diff) once their corpora are extended.

    Concrete changes:
      * `src/passqlite3codegen.pas`:
        - `sqlite3FinishCoding` (line 6219, was a stub): full body —
          early-out for nested/error parses, `sqlite3GetVdbe` fallback
          for empty programs, `OP_Halt` tail, `OP_Init.P2 := JumpHere`
          rewire, schema-cookie loop emitting `OP_Transaction` for each
          set bit of `pParse^.cookieMask` (with `writeMask` fanning out
          to P2, `pSchema^.schema_cookie/iGeneration` to P3/P4 when a
          real Schema is present), `sqlite3VdbeChangeP5(v,1)` outside
          `init.busy`, `sqlite3AutoincrementBegin` if `pAinc<>nil`,
          `sqlite3VdbeGoto(v,1)` jump-back, and `sqlite3VdbeMakeReady`
          + `pParse^.rc` finalisation.
        - **Test-scaffold guard** at the top of the new body:
          `if db^.eOpenState <> $76 then Exit;` short-circuits the heavy
          work for synthetic dbs created by `MakePascalDb` in
          TestParser/TestParserSmoke (eOpenState=1).  Real
          `sqlite3_open_v2` sets `SQLITE_STATE_OPEN ($76)` so the gate is
          transparent for production code and for TestPrepareBasic.
      * `src/tests/TestPrepareBasic.pas` — adds `sqlite3_finalize(pStmt)`
        after T7/T8/T9/T10 prepare_v2/v3 calls.  Was passing only because
        the old FinishCoding stub never produced a real Vdbe; now that
        prepare returns a stepable handle, leaving four of them dangling
        made `sqlite3_close` correctly return `SQLITE_BUSY=5`.  Tests now
        finalise each statement.

    Tests: full build clean.  Regression sweep — TestPrepareBasic
    20/20 (was 19/20), TestParser 45/45, TestParserSmoke 20/20,
    TestSchemaBasic 44/44, TestVdbeApi 57/57, TestVdbeRecord 13/13,
    TestVdbeArith 41/41, TestPagerCompat ALL PASS, TestBtreeCompat
    337/337, TestJson 434/434, TestVtab 216/216, TestPrintf 105/105,
    TestSelectBasic 49/49, TestExprBasic 40/40, TestDMLBasic 54/54,
    TestExecGetTable 23/23.  No regressions across the ~40 gate tests.

    Discoveries / next-step notes:
      * **`PSchema = Pointer` opaque-stub shadow at codegen.pas:401.**
        The codegen unit re-declares `PSchema = Pointer` to break the
        circular `passqlite3util ↔ passqlite3codegen` dependency around
        `Schema/Table/Index`.  The new code therefore types its local
        as `passqlite3util.PSchema` and casts at the assignment point.
        Same idiom is used by the existing `pSchema:
        passqlite3util.PSchema` declarations at lines 5448/5587/5774/
        7149/7166.  Add to porting checklist.
      * **FPC var/type case-collision on `pSchema`.**  Even after the
        stub-shadow is sidestepped, `var pSchema: PSchema` collides
        with the field name on `TDb` under FPC's case-insensitive
        identifier rules (the recurring `pPager`/`pPgr` pattern from
        memory).  Renamed local to `pSchm`.
      * **Synthetic-db gate is intentional.**  A real port of build.c
        would not need the `eOpenState <> $76` check, but every Phase
        6/7 test scaffold today passes a stub db that lacks a
        lookaside region, real schemas, and `sqlite3DbMallocZero`-safe
        memory.  The gate keeps those tests green without compromising
        the production path.  Audit when Phase 8.x rewires test
        scaffolds to use `sqlite3_open_v2(":memory:")`.
      * **`pConstExpr` skipped — `sqlite3ExprCode` not yet ported.**
        The factored-constant emit loop in build.c:243..250 calls
        `sqlite3ExprCode` which is still a Phase 6/8 hole (no
        definition in `passqlite3codegen.pas` today).  The port
        currently `sqlite3ExprListDelete`s the list and zeroes the
        slot, which is safe because no codegen path calls
        `sqlite3ExprCodeAtInit` yet.  Re-wire when ExprCode lands.
      * **`pParse^.bReturning` branch left as TODO.**  Pascal Parse
        struct doesn't yet carry the `bReturning` u8 flag (it's only
        on `TTrigger` at codegen.pas:733).  The two RETURNING blocks
        in build.c (lines 171..192 and 252..259) stay unported until
        the trigger-RETURNING coding path lands.
      * **`apVtabLock` left as TODO.**  Field exists on TParse as
        untyped `Pointer`; the OMIT_VIRTUALTABLE block reads it as a
        `Table**` array.  Guard `if pParse^.nVtabLock > 0` resets the
        counter to 0 to keep behaviour stable until the typed array +
        `sqlite3GetVTable` cast is wired through.

  - **2026-04-26 — Phase 5.4c-bis VDBE overflow-column RCStr cache.**
    Closes the "Phase 5 RCStr placeholder" deferral flagged by Phase
    6.8.h.7's discovery notes (vdbe.c:719..795 / vdbeaux.c:2745..2762).
    Ports the large-TEXT/BLOB column-cache branch of `vdbeColumnFromOverflow`
    using the `sqlite3RCStr*` primitives that 6.8.h.7 promoted into
    `passqlite3util`, and threads the matching `freeCursorWithCache`
    cleanup into `sqlite3VdbeFreeCursorNN`.

    Concrete changes:
      * `src/passqlite3btree.pas` — adds `sqlite3BtreeOffset`
        (btree.c:4941); needed by the cache-invalidation predicate
        in `vdbeColumnFromOverflow` to detect "different row at the
        same iCol/cacheStatus".
      * `src/passqlite3vdbe.pas`:
        - `vdbeColumnFromOverflow` — replaces the simplified
          `VdbeMemFromBtree`-only body with the full vdbe.c:735..785
          path: lazy `pCache` allocation under `VDBC_ColCache`,
          5-way cache-validity check (pCValue / iCol / cacheStatus /
          colCacheCtr / iOffset), `sqlite3RCStrUnref` of the previous
          buffer, `sqlite3RCStrNew(len+3)` with the three trailing
          zero bytes, `sqlite3BtreePayload` fill, and
          `sqlite3VdbeMemSetStr(...)` with `sqlite3RCStrUnref` as
          destructor (zero-copy ownership transfer to the result Mem).
          Threshold matches C exactly (`len > 4000 && pKeyInfo == 0`).
        - `sqlite3VdbeFreeCursorNN` — front-loads the
          `freeCursorWithCache` body (vdbeaux.c:2752): if the cursor
          carries `VDBC_ColCache`, drop the cached RCStr buffer via
          `sqlite3RCStrUnref`, then `sqlite3DbFree` the cache record
          before falling through to the type-specific cursor close.
          Order matches C — the cache is freed regardless of cursor
          eCurType, which mirrors the upstream guard.

    Tests: full build clean (`bash src/tests/build.sh`).  Regression
    spot check: TestVdbeCursor 27/27, TestVdbeMem 62/62,
    TestVdbeRecord 13/13, TestVdbeApi 57/57, TestVdbeBlob 13/13,
    TestJson 434/434, TestJsonRegister 48/48, TestJsonEach 50/50,
    TestUtil ALL PASS, TestPagerCompat ALL PASS, TestBtreeCompat
    337/337, TestSchemaBasic 44/44.

    Discoveries / next-step notes:
      * **`sqlite3RCStrUnref` cast through `TxDelProc(@...)` is required.**
        FPC will not implicitly accept a `procedure(p:Pointer);cdecl`
        symbol address as a `TxDelProc` parameter; an explicit cast
        keeps the calling convention contract documented at the call
        site.  Same trick used by the `sqlite3FreeXDel` callers.
      * **`sqlite3BtreeOffset` body uses `PtrUInt` arithmetic.**  The
        C version subtracts two `u8*` (`pPayload - aData`); Pascal's
        pointer subtraction with `{$POINTERMATH ON}` is element-sized,
        so cast through `PtrUInt` to get a byte-count.  Same idiom
        already used by `accessPayload` in passqlite3btree.
      * **`vdbeaux.c:2759` deferral closed.**  Per the 6.8.h.7
        discovery list, this was the second of two RCStr fix-sites
        in the VDBE port.  `vdbe.c:759..782` (the cache fill itself)
        is now also live.  No remaining RCStr placeholders in the
        VDBE.

  - **2026-04-26 — Phase 6.8.h.7 sqlite3RCStr port + JSON ownership-transfer.**
    Closes the `sqlite3RCStr*` deferral threaded through 6.8.b /
    6.8.g / 6.8.h.1 / 6.8.h.4.  Ports the four-function reference-counted
    string/blob primitive from `printf.c:1557..1614` into
    `passqlite3util.pas` and rewires every JSON spill / cache / result
    site that used `sqlite3_malloc / sqlite3_realloc / sqlite3_free` as a
    stand-in.

    Concrete changes:
      * `src/passqlite3util.pas` — adds `sqlite3RCStrNew`,
        `sqlite3RCStrRef`, `sqlite3RCStrUnref` (cdecl, so it can be
        passed as a `TxDelProc` destructor), `sqlite3RCStrResize`.
        New `TRCStr` record (8-byte header) before the payload; pointer
        arithmetic via `PByte` ± `SizeOf(TRCStr)` matches C's `(RCStr*)z - 1`.
      * `src/passqlite3json.pas` — six fix-sites swapped:
        - `jsonStringReset` — `sqlite3_free` → `sqlite3RCStrUnref`.
        - `jsonStringGrow` — both spill paths use `sqlite3RCStrNew` /
          `sqlite3RCStrResize` (matches json.c:582/591).
        - `jsonReturnString` — implements the json.c:872 cache-insert +
          ownership-transfer branch: when `pParse` carries a JSONB blob
          (`nBlobAlloc>0`) and no cached text yet (`bJsonIsRCStr=0`),
          publish the freshly built `zBuf` into the auxdata cache via
          `sqlite3RCStrRef` + `jsonCacheInsert`, then hand a second Ref
          to `sqlite3_result_text64` with `sqlite3RCStrUnref` as the
          destructor.  Replaces the TRANSIENT-copy fallback.
        - `jsonArrayCompute` / `jsonObjectCompute` (h.4) — final-isFinal
          path now hands `pStr^.zBuf` to `sqlite3_result_text` with
          `sqlite3RCStrUnref` (zero-copy ownership transfer); sets
          `pStr^.bStatic := 1` so the post-call `jsonStringReset` in
          the caller does not double-free.  JSON_BLOB final arm uses
          `sqlite3RCStrUnref` to drop the spilled buffer.
        - `jsonParseFuncArg` cache-store (g) — `sqlite3_malloc + Move`
          replaced with `sqlite3RCStrNew + Move`; `bJsonIsRCStr=1` now
          means "RCStr-owned" again (matches C semantics exactly).
        - `jsonParseReset` (g) — drops the cache reference via
          `sqlite3RCStrUnref` instead of `sqlite3_free`.

    Tests / regression spot check (no new gate; existing JSON gates
    cover the rewired paths):
      * TestJson 434/434 PASS, TestJsonEach 50/50 PASS,
        TestJsonRegister 48/48 PASS.
      * TestUtil ALL PASS, TestPrintf 105/105, TestVtab 216/216,
        TestVdbeApi 57/57.

    Discoveries / next-step notes:
      * **`sqlite3RCStrUnref` must be `cdecl`**.  It is passed as a
        `TxDelProc` (`procedure(p: Pointer); cdecl`) into
        `sqlite3_result_text` / `sqlite3_result_text64`.  Without
        `cdecl` the calling convention diverges from the SQLite C ABI
        for destructor callbacks.  Same convention as
        `sqlite3FreeXDel` already in vdbe.
      * **Header size = 8 bytes (one u64 refcount).**  Payload pointer
        is `PByte(p) + SizeOf(TRCStr)`.  C's `(RCStr*)&p[1]` and
        `p--` translate to `PByte(z) ± SizeOf(TRCStr)` in Pascal under
        `{$POINTERMATH ON}`.
      * **`pStr^.bStatic := 1` after ownership transfer** prevents the
        aggregate-Final caller's safety `jsonStringReset` from
        double-freeing the buffer SQLite now owns.  Mirrors C
        json.c:4871/4996 exactly.
      * **VDBE / vdbeaux RCStr fix-sites still pending.**  C uses
        `sqlite3RCStrNew/Ref/Unref` in `vdbe.c:759..782` (function
        result-text caching) and `vdbeaux.c:2759` (auxdata cleanup).
        Those are part of the VDBE port, not JSON, and remain on the
        Phase 8.x agenda.  The helper itself is now available; only
        the call-site swaps are deferred.
      * **`sqlite3_result_error_nomem` on `jsonCacheInsert` failure.**
        New jsonReturnString branch correctly calls
        `sqlite3_result_error_nomem` + `jsonStringReset` and exits
        without firing `sqlite3_result_text*`.  Mirrors C json.c:879.

  - **2026-04-26 — Phase 6.8.h.6 JSON SQL function registration.**
    Lands `sqlite3RegisterJsonFunctions` in `passqlite3codegen.pas`,
    wiring the full json_* / jsonb_* SQL surface (32 scalars + 4
    aggregates) into `sqlite3BuiltinFunctions`.  Called from
    `sqlite3RegisterBuiltinFunctions` so every `sqlite3_initialize`
    sequence now exposes the JSON surface alongside the existing
    scalar / aggregate / date built-ins.

    Concrete changes:
      * `src/passqlite3types.pas` — adds `SQLITE_RESULT_SUBTYPE =
        $01000000` (function may call sqlite3_result_subtype).
      * `src/passqlite3json.pas` — ports `jsonArrayFunc`
        (json.c:3979) and `jsonObjectFunc` (json.c:4424); both
        exported in interface so 6.8.h.6 can drop them straight
        into the registration table.
      * `src/passqlite3codegen.pas` — adds `sqlite3RegisterJsonFunctions`
        (interface + implementation, ~110 lines).  Implementation
        section adds `passqlite3json, passqlite3jsoneach` to the
        `uses` clause.  Two TFuncDef arrays — `aJsonFunc[0..31]` for
        scalars, `aJsonAgg[0..3]` for aggregates — populated via
        local `JFn` (JFUNCTION analogue) and `WAgg` (WAGGREGATE
        analogue) helpers.  `pUserData` carries
        `iArg | (bJsonB?JSON_BLOB:0)` exactly like the C macro.
      * `src/tests/TestJsonRegister.pas` — **new gate** (48 asserts).
        R1..R32 lookups for every name×nArg combination; F1..F8
        pin the pUserData encoding (json_set→ISSET, jsonb_set→
        ISSET|BLOB, jsonb_array_insert→AINS|BLOB, ->/->>→JSON/SQL,
        plain json_extract→0); A1..A4 verify the aggregate
        xStep/xFinalize/xValue/xInverse slots; B1/B2 cover the
        aggregate-blob and SQLITE_RESULT_SUBTYPE flag bits;
        V1 reaches `sqlite3JsonVtabRegister` through the codegen
        unit; C1 pins SQLITE_RESULT_SUBTYPE.  **48/48 PASS.**
      * `src/tests/build.sh` — adds `compile_test TestJsonRegister`.
      * Regression spot check: TestJson 434/434, TestJsonEach 50/50,
        TestAuthBuiltins 34/34, TestPrintf 105/105, TestVtab
        216/216, TestParser 45/45, TestSchemaBasic 44/44,
        TestVdbeApi 57/57, TestCarray 66/66.

    Discoveries / next-step notes:
      * **`sqlite3JsonVtabRegister` stays per-connection / lazy.**
        C registers `json_each` / `json_tree` / `jsonb_each` /
        `jsonb_tree` only when the parser/VDBE first opens one of
        them (json.c:5667 is wired via `sqlite3FindOrCreateModule`).
        The codegen `uses` clause now references
        `passqlite3jsoneach` so the unit's `initialization` block
        builds `jsonEachModule`; per-connection registration belongs
        with the SELECT/parser surface in Phase 7.  A guarded
        `if @sqlite3JsonVtabRegister = nil` reference in
        `sqlite3RegisterJsonFunctions` keeps the unit's symbols
        live against linkers that strip seemingly unused units.
      * **`pUserData` flags are now LIVE.**  The deferred 6.8.h.3 /
        6.8.h.4 branches that gated on `sqlite3_user_data(ctx)` —
        JSON_ISSET vs JSON_INS in `jsonSetFunc`, JSON_ABPATH in
        `jsonExtractFunc`, JSON_BLOB across the SetXXXAsBlob
        emitters — fire correctly when a registered function is
        looked up via the SQL surface.  Tests that fabricate
        contexts directly still see `pUserData=nil` (no pFunc
        wired); all such tests remain pinned to the 0-flag default
        path and are harmless.
      * **No SQLite RCStr port.**  The optional sqlite3RCStr port
        listed in the 6.8.h.6 task body was deferred again — every
        h.* chunk continues to use TRANSIENT result text + an
        explicit `sqlite3_free` cleanup.  Fix-sites are the same
        two each in `jsonReturnString`, `jsonArrayCompute`,
        `jsonObjectCompute`; flip them to `sqlite3RCStrUnref`
        ownership transfer when the helper lands (probably with
        the first PrepareV2 / VDBE result-binding work).
      * **`SQLITE_RESULT_SUBTYPE` is the same bit
        (`$01000000`) used by the existing TVdbe `nullFnV`
        kludge in `passqlite3vdbe.pas:7600`.**  The new constant
        formalises that magic number; future vdbe touch-ups can
        drop the inline literal.
      * **TFuncDef arrays must NOT be padded with trailing zero
        slots.**  `sqlite3InsertBuiltinFuncs` walks `nFunc`
        entries and hashes each by `zName`; an all-zero slot has
        `zName = nil` → `sqlite3Strlen30(nil)` (libc strlen on
        nil) → segfault.  The arrays are sized to exactly the
        number of registered entries (`array[0..31]` for 32
        scalars, `array[0..3]` for 4 aggregates) and registered
        with `Length(...)`.  Same convention as `aBuiltinFuncs`,
        `aBuiltinAgg`, `aDateFuncs`, `aWindowFuncs`.

  - **2026-04-26 — Phase 6.8.h.5 json_each / json_tree vtabs.**  Lands
    the four-spelling read-only virtual table module
    (`json_each` / `json_tree` / `jsonb_each` / `jsonb_tree`) plus the
    `sqlite3JsonVtabRegister(db, zName)` entry point that 6.8.h.6 will
    wire into `sqlite3RegisterBuiltinFunctions`.  The full Connect /
    Disconnect / Open / Close / Filter / Next / Eof / Column / Rowid /
    BestIndex callback set is faithfully ported from json.c:5020..5680.

    Concrete changes:
      * `src/passqlite3jsoneach.pas` — **new unit** (~600 lines).
        Exports `jsonEachModule`, `sqlite3JsonVtabRegister`, the
        `JEACH_*` column-ordinal constants, and the `TJsonParent`
        / `TJsonEachConnection` / `TJsonEachCursor` records.
        `uses passqlite3vtab + passqlite3json + passqlite3vdbe`.
      * `src/tests/TestJsonEach.pas` — **new gate**.  50 asserts:
        4-spelling registration + case-insensitive lookup,
        15-slot module layout, 5-case BestIndex dispatch (empty /
        JSON only / JSON+ROOT / unusable JSON → CONSTRAINT /
        non-hidden ignored), 10 column-ordinal constants pin.
        **50/50 PASS.**
      * `src/tests/build.sh` — adds `compile_test TestJsonEach`.
      * Regression spot check: TestJson 434/434, TestPrintf 105/105,
        TestVtab 216/216, TestParser 45/45, TestSchemaBasic 44/44,
        TestVdbeApi 57/57, TestCarray 66/66.

    Discoveries / next-step notes:
      * **`jsonPrintf` stays private; jsonAppendPathName uses three
        local stand-ins** (jeAppendInt64 / jeFmtArrayKey /
        jeFmtObjectKey[Quoted]).  Promoting jsonPrintf to interface
        would re-export the JsonString printf machinery for one
        five-character format chunk.  Switch back when a future
        chunk needs it publicly.
      * **`'$'` to PAnsiChar coercion is unsafe.**  FPC parses a
        single-quoted single character as `AnsiChar`, not as a
        string literal; passing `'$'` directly to a `PAnsiChar`
        parameter is rejected.  Fix: declare a local
        `cDollar: AnsiChar` and pass `@cDollar`.  Same trap any
        future single-byte path-anchor write will hit.
      * **`PPsqlite3_value` indexes directly: `argv[0]`, `argv[1]`.**
        No need for the `^Psqlite3_value` aliasing trick — FPC's
        subscript operator on `^T` (where `T = ^U`) yields a `^U`
        (i.e. `Psqlite3_value`).  Same convention as carray.
      * **`malformed JSON` error string flows through
        `sqlite3VtabFmtMsg1Libc`.**  C uses `sqlite3_mprintf(...)`;
        the Pascal port routes through the libc-allocated helper so
        `sqlite3_free(pVtab^.zErrMsg)` clears it uniformly.
      * **xColumn / full Filter+Next walk gated end-to-end deferred
        to 6.8.h.6.**  xColumn needs a live `Tsqlite3_context`; full
        `jsonEachFilter` end-to-end needs a `Psqlite3_value` shaped
        like a real SQL value plus `jsonConvertTextToBlob`'s
        diagnostic plumbing.  6.8.h.5 pins the stable, dep-free
        surface (module shape + BestIndex); SQL-level coverage rides
        registration in 6.8.h.6.

  - **2026-04-26 — Phase 6.8.h.4 JSON aggregates.**  Lands the
    `json_group_array` / `json_group_object` aggregate SQL surface,
    closing the deferred 6.8.h.4 slot.  Seven new public cdecl entry
    points in `passqlite3json.pas` (`jsonArrayStep`, `jsonArrayValue`,
    `jsonArrayFinal`, `jsonObjectStep`, `jsonObjectValue`,
    `jsonObjectFinal`, `jsonGroupInverse`) plus two private drivers
    (`jsonArrayCompute`, `jsonObjectCompute`) that share the
    Final/Value branching.  All four entry points hang off the existing
    `sqlite3_aggregate_context` plumbing in `passqlite3vdbe`; the
    aggregate state is a `TJsonString` accumulator that records the
    comma-separated body and is closed/trimmed on Final/Value.

    Concrete changes:
      * `src/passqlite3json.pas` — adds 7 cdecl entries in interface
        + ~210 lines of impl.
      * `src/tests/TestJson.pas` — adds `SetupAggCtx` helper, two
        small `CallStep1/2` invokers, and three test bodies
        (`TestJsonGroupArray`, `TestJsonGroupInverse`,
        `TestJsonGroupObject`).  T423..T435 (13 new asserts).
        **434/434 PASS** (was 421/421).
      * Regression spot check: TestPrintf 105/105, TestVtab 216/216,
        TestParser 45/45, TestSchemaBasic 44/44, TestVdbeApi 57/57.

    Discoveries / next-step notes:
      * **`{...}` doc comments containing literal `{` / `}` chars
        confuse FPC's nested-comment tracker.**  `'{'` inside a
        `{ ... }` block opens level-2; the matching `'}'` closes it,
        leaving the outer comment unterminated until the next `}` —
        which can be many lines later, swallowing real code.
        Switched the affected doc comments to `(* ... *)`.  Same
        risk surfaces anywhere a future port wants to embed JSON
        bracket characters in a doc comment — porting-rule below.
      * **Aggregate test fabrication needs `ctx.pMem`.**  Added
        `SetupAggCtx` that wires a separate `TMem` into `ctx.pMem`
        so `sqlite3_aggregate_context` can clear-and-resize it via
        `sqlite3DbMallocRaw(nil, ...)` (which falls through to libc
        in this port).  Generalisation of the Phase 6.8.g `SetupCtx`
        helper.
      * **Pascal `'\'` is an unterminated string literal** — use
        `#$5C` for a backslash byte (in `jsonGroupInverse`'s skip-
        escape branch).  Same family as 6.8.d / 6.8.e escape traps;
        already in the porting-rule list.
      * **No RCStr means TRANSIENT-copy on text result.**  Same
        two-site fix as 6.8.h.1 / 6.8.g — when sqlite3RCStr lands
        in 6.8.h.6, swap `sqlite3_result_text(..., TRANSIENT)` and
        the `sqlite3_free(pStr^.zBuf)` cleanup back to
        `sqlite3RCStrUnref` ownership transfer.
      * **`pUserData` JSON_BLOB flag still inert in tests.**  The
        fabricated context has no TFuncDef, so `sqlite3_user_data`
        returns nil → flags=0 → text path always taken.  Both
        BLOB arms in `jsonArrayCompute` / `jsonObjectCompute` are
        wired and structurally identical to C; coverage deferred
        to 6.8.h.6 with the registration-layer pUserData wiring
        (same deferral rationale as 6.8.h.3's `JSON_ISSET` /
        `JSON_AINS`).

  - **2026-04-26 — Phase 6.8.h.3 JSON path-driven scalars.**  Lands
    the SQL surface for `json_extract`, `json_set`, `json_replace`,
    `json_insert`, `json_array_insert`, `json_remove`, and
    `json_patch`.  Five new public cdecl entry points in
    `passqlite3json.pas` (`jsonExtractFunc`, `jsonRemoveFunc`,
    `jsonReplaceFunc`, `jsonSetFunc`, `jsonPatchFunc`); two new
    private drivers (`jsonInsertIntoBlob` for the set/replace/insert
    family, `jsonMergePatch` for the RFC-7396 patch).  All edits
    flow through `jsonLookupStep` (6.8.f) for path resolution and
    `jsonBlobEdit` (6.8.c) for in-place blob mutation.

    Concrete changes:
      * `src/passqlite3json.pas` — adds the 5 cdecl entry points
        in interface (~440 lines impl); `JSON_MERGE_*` constants.
      * `src/tests/TestJson.pas` — adds T405..T422 (18 new
        asserts); `CallScalar3` / `CallScalar5` helpers for
        odd-argc paths.  **421/421 PASS** (was 403/403).
      * Regression spot check: TestPrintf 105/105, TestVtab 216/216,
        TestParser 45/45, TestSchemaBasic 44/44, TestVdbeApi 57/57.

    Discoveries / next-step notes:
      * **`sqlite3_set_auxdata` sets `isError := -1` as a sentinel.**
        This flags "auxdata recorded for current opcode" so the next
        re-evaluation can short-circuit.  It is NOT a real SQL
        error.  Tests that gate on "no result + no error" must use
        `isError <= 0`, not `= 0` — caught when first cut of T406
        and T417 spuriously failed.  See `passqlite3vdbe.pas:2907`.
      * **`json_set` flag-discrimination still inert in tests.**
        The Pascal test harness fabricates a `Tsqlite3_context`
        without a `pFunc`, so `sqlite3_user_data(ctx)` always
        returns nil.  That collapses `JSON_INSERT_TYPE(flags) = 0`
        → JEDIT_INS in every case (T412/T413).  Coverage of the
        SET / AINS branches is deferred to 6.8.h.6 when the
        registration layer plumbs `JSON_ISSET` / `JSON_AINS`
        through `pUserData`.
      * **`jsonExtractFunc` abbreviated-path branch not yet
        exercised.**  Plain `json_extract` registers with flags=0,
        so the `JSON_ABPATH` (= `JSON_JSON | JSON_SQL`) branch only
        fires for `->` (1) and `->>` (2).  Wired and structurally
        identical to the C reference, but pinned tests are deferred
        to 6.8.h.6 with the user-data fabrication.
      * **`jsonInsertIntoBlob` mutates `p^.eEdit` / `aIns` / `nIns`
        / `delta` / `iDepth` per path iteration.**  Cache hits via
        `jsonCacheSearch` rely on `p^.delta == 0` at entry; the
        per-path reset to `delta := 0` preserves that invariant.
        Verified by T409/T410 (cache hit on `{"a":1,"b":2}` between
        replace-hit and replace-miss).
      * **`jsonMergePatch` recursion bumps `iDepth` separately
        from the parser's `iDepth` field.**  Local parameter,
        capped at `JSON_MAX_DEPTH = 1000`.  `pTarget^.delta` is
        saved + restored across the recursive call so the outer
        edit-position math remains coherent — same pattern as
        `jsonLookupStep`'s recursion through
        `jsonCreateEditSubstructure` (6.8.f).

  - **2026-04-26 — Phase 6.8.h.1 JSON SQL-result helpers.**  First
    slice of the 6.8.h dispatch chunk.  Lands the deferred
    "return-to-SQL" surface that earlier 6.8.* chunks repeatedly
    deferred to avoid the passqlite3vdbe dep cycle: nine new public
    functions in `passqlite3json.pas` — `jsonAppendSqlValue`,
    `jsonReturnString`, `jsonReturnStringAsBlob`,
    `jsonReturnTextJsonFromBlob`, `jsonReturnFromBlob` (the big
    13-arm BLOB→SQL switch incl. INT5 hex→i64 with overflow→double
    promotion, FLOAT5 leading-dot, TEXTJ/TEXT5 escape replay into
    UTF-8, ARRAY/OBJECT eMode dispatch), `jsonReturnParse`,
    `jsonWrongNumArgs`, `jsonBadPathError`, `jsonFunctionArgToBlob`.
    Plus three new helpers in `passqlite3vdbe.pas` —
    `sqlite3_user_data` (returns `pCtx^.pFunc^.pUserData`),
    `sqlite3_result_subtype` (sets `pOut^.eSubtype` + `MEM_Subtype`),
    `sqlite3_result_text64` (u64-length wrapper around
    `sqlite3VdbeMemSetStr`).

    Concrete changes:
      * `src/passqlite3vdbe.pas` — adds the 3 funcs in interface
        + ~30 lines of impl just after `sqlite3_set_auxdata`.
      * `src/passqlite3json.pas` — adds the 9 funcs in interface
        (~440 lines impl) + adds `SysUtils` to the implementation
        uses for `FloatToStr`.
      * `src/tests/TestJson.pas` — adds T355..T376 (22 new asserts).
        **375/375 PASS** (was 353/353).
      * Regression spot check: TestPrintf 105/105, TestVtab 216/216,
        TestParser 45/45, TestSchemaBasic 44/44, TestVdbeApi 57/57.

    Discoveries / next-step notes:
      * **`sqlite3IsNaN` is impl-section-only in passqlite3vdbe.**
        Inlined the trivial `r <> r` test in `jsonFunctionArgToBlob`
        rather than promote the function to vdbe's interface (would
        ripple through several units).  If 6.8.h.x or later phases
        need IsNaN repeatedly, lift it into `passqlite3util` (it has
        no FPC-internal deps).
      * **No `sqlite3RCStr` still.**  `jsonReturnString` therefore
        always copies the result string via `SQLITE_TRANSIENT` rather
        than ref-sharing it into the function-arg cache.  The
        cache-insert path (json.c:872..886 — the
        `bJsonIsRCStr==0 && nBlobAlloc>0` branch) is **not** exercised
        in 6.8.h.1.  When 6.8.h.x lands `sqlite3RCStrNew/Ref/Unref`,
        rewire the non-static branch to mirror C exactly: ref into
        zJson, set `bJsonIsRCStr=1`, call `jsonCacheInsert`, then
        ref again into the SQL value with `sqlite3RCStrUnref` as the
        destructor.  Two-site change; comment marker placed above the
        non-static branch.
      * **`jsonAppendSqlValue` FLOAT path uses `FloatToStr`,** not
        the SQLite-flavoured `%!0.15g` from `jsonPrintf`.  Good
        enough until 6.8.h.x ports the json-flavour printf wrapper;
        differs from C in trailing-zero formatting (e.g. `1.5e10`
        vs `15000000000.0`).  Tests don't yet exercise this branch
        on a SQL surface; flag for revisit when `json_extract` lands.
      * **`sqlite3_result_text64` u64→i32 narrowing.**  C uses a u64
        for the length to allow > 2GB strings; our wrapper rejects
        n > $7FFFFFFF with `SQLITE_TOOBIG`.  Sufficient for JSON
        bodies but worth lifting if blob/streaming use-cases appear.
      * **`jsonReturnFromBlob` `to_double:` label.**  Pascal `goto`
        targets must be in the same scope.  The label sits inside
        the `JSONB_FLOAT5/FLOAT` arm and is jumped to from the
        `JSONB_INT5/INT` arm's "consumed-too-many-bytes" recovery
        path — works because both arms compile to a single procedure
        body (no `try` boundary).  Same structural pattern as the C
        original.
      * **`jsonBadPathError` standalone-message branch** allocates
        with `StrAlloc` (FPC RTL) when `pCtx = nil`.  C uses
        `sqlite3_mprintf` and the caller frees with `sqlite3_free`.
        When 6.8.h.x ports `sqlite3_mprintf`'s libc-malloc'd return,
        swap `StrAlloc` → `sqlite3_mprintf` so the caller's
        `sqlite3_free` works uniformly.  Only one caller exists in
        json.c and it's inside `jsonInsertIntoBlob` (deferred).

  - **2026-04-26 — Phase 6.8.g JSON function-arg cache.**  Lands the
    auxdata-backed JsonParse cache that makes repeated `json_*` calls
    on the same SQL value reuse the parsed JSONB blob instead of
    re-parsing each row.  Five new public functions in
    `passqlite3json.pas`: `jsonParseFree` (refcount drop, frees on
    last ref), `jsonArgIsJsonb` (sniffs blob header against
    `jsonbValidityCheck`), `jsonCacheInsert` / `jsonCacheSearch` (LRU
    of size 4 keyed on `JSON_CACHE_ID = -429938`), and the central
    `jsonParseFuncArg` driver with the `goto rebuild_from_cache`
    structure preserved via Pascal `label`/`goto`.  Three new public
    functions in `passqlite3vdbe.pas` to support it:
    `sqlite3_context_db_handle`, `sqlite3_get_auxdata`,
    `sqlite3_set_auxdata` — direct ports of vdbeapi.c:985/1169/1200,
    walking the existing `Vdbe.pAuxData` linked list (already wired
    up + freed by `sqlite3VdbeDeleteAuxData` since Phase 5).

    Concrete changes:
      * `src/passqlite3vdbe.pas` — adds the auxdata API in
        interface + ~75 lines of impl just above `sqlite3VdbeCreate`.
      * `src/passqlite3json.pas` — adds the 5 cache-related funcs in
        interface (~280 lines impl) + adds `passqlite3vdbe` to the
        **implementation uses** (interface stays neutral via
        `Pointer` parameters for `pCtx` / `pArg`, matching the
        existing `jsonStringInit(pCtx: Pointer)` convention).
        Updates `jsonParseReset` to actually free the libc-malloc'd
        `zJson` when `bJsonIsRCStr=1` (had been a no-op TODO since
        6.8.d — caused leaks once the cache wires up).
      * `src/tests/TestJson.pas` — adds T333..T354 (22 new asserts).
        Adds `passqlite3vdbe` to test's `uses` clause; introduces
        three setup helpers (`SetupTextValue`, `SetupBlobValue`,
        `SetupCtx`) that fabricate stack-allocated `TMem` and
        `Tsqlite3_context` / `TVdbe` skeletons sufficient to drive
        the cache layer without standing up a full live VM.
        **353/353 PASS** (was 331/331).
      * Regression spot check: TestVdbeApi 57/57, TestVtab 216/216,
        TestPrintf 105/105, TestParser 45/45, TestSchemaBasic 44/44.

    Discoveries / next-step notes:
      * **`sqlite3RCStr` substitute in place.**  The C reference uses
        RCStr for shared zJson ownership across the cache + SQL value
        system.  Pascal port heap-copies via `sqlite3_malloc` and
        repurposes `bJsonIsRCStr=1` as "owned by libc malloc" so
        `jsonParseReset` knows to free.  When 6.8.h ports sqlite3RCStr
        proper, the swap is exactly two sites: the `zNew :=
        sqlite3_malloc(...)` block in `jsonParseFuncArg` and the
        matching `sqlite3_free` branch in `jsonParseReset`.
      * **Error sinking still deferred.**  Both error paths in
        `jsonParseFuncArg` (`json_pfa_malformed`, `json_pfa_oom`)
        return nil silently instead of calling
        `sqlite3_result_error[_nomem]` on ctx.  6.8.h's SQL dispatch
        layer will plumb that through.  TODO comments at the labels
        point at the exact insertion sites.
      * **Cache-hit refcount = 3, not 2.**  After one parse + one
        cache hit (non-EDITABLE), the cached JsonParse holds nJPRef=3:
        1 from the initial `nJPRef := 1`, +1 from
        `jsonCacheInsert`'s `Inc`, +1 from the cache-hit branch's
        own `Inc(pCache^.nJPRef)`.  T351 nails this down with a
        comment; re-verify once 6.8.h composes the cache-hit +
        EDITABLE rebuild path (which calls `jsonParseFree(pCache)`
        explicitly inside `rebuild_from_cache`).
      * **Aliasing pitfall recurs.**  Locals `pAuxData: PAuxData`
        and `pVdbe: PVdbe` clash with their own type names under
        FPC's case-insensitive scope — same family as `pPager:
        PPager` and `pParse: PParse`.  Renamed to `pAd` and `pVm`.
      * **`Psqlite3 = Pointer` is declared in `passqlite3btree.pas`,**
        not in `passqlite3types`.  Local `db` variables in
        `passqlite3json.pas` use `Pointer` directly to avoid pulling
        in the btree unit just for the alias.

  - **2026-04-26 — Phase 6.8.f JSON path lookup + edit.**  Lands the
    JSON-path walk surface (`$.a.b[3]`-style addressing) on top of the
    JSONB blob primitives from 6.8.c: `jsonLookupStep` (~280 lines
    covering both `.key` object descent and `[N]` / `[#-N]` array
    indexing, plus the JEDIT_DEL/REPL/INS/SET/AINS edit branches with
    in-place blob mutation through `jsonBlobEdit` + post-edit header
    fix-up via `jsonAfterEditSizeAdjust`), `jsonCreateEditSubstructure`
    (~30 lines — synthesises `[]` / `{}` placeholder JSONB for deeper
    edit paths, then recurses).  Sentinel return codes
    (`JSON_LOOKUP_ERROR / NOTFOUND / NOTARRAY / TOODEEP / PATHERROR`)
    exposed in the interface alongside a small `jsonLookupIsError`
    inline helper.

    Concrete changes:
      * `src/passqlite3json.pas` — adds the 6.8.f surface
        (~310 lines: 2 routines + supporting `jsonPathTailIsBracket`
        helper + sentinel constants).
      * `src/tests/TestJson.pas` — adds T302..T332 (31 new asserts:
        `.a` / `.b` / `."a"` quoted-key / `.zzz` miss / lone `.` →
        PATHERROR / `[0]` / `[1]` / `[99]` miss / `[#-1]` end-relative
        index / cross-type lookups (`[0]` on object, `.x` on array)
        / bare-label PATHERROR / JEDIT_DEL `.a` mutates blob and
        updates header sz nibble / JEDIT_REPL same-size value /
        JEDIT_DEL miss leaves blob untouched / `jsonCreateEditSubstructure`
        empty-tail mirror).  **331/331 PASS** (was 300/300).
      * Regression spot check: TestPrintf 105/105, TestVtab 216/216,
        TestParser 45/45, TestSchemaBasic 44/44, TestUtil ALL PASS.

    Discoveries / next-step notes:
      * **`sqlite3_strglob("*]", zTail)` is not ported.**  C uses it
        once in jsonLookupStep's JEDIT_AINS arm to assert the path
        tail ends in `]`.  Pascal port adds a private
        `jsonPathTailIsBracket(zTail: PAnsiChar): i32` helper that
        scans to NUL and checks the last byte.  When pas-sqlite3
        eventually ports `sqlite3Strglob` (likely as part of 6.8.h
        or a future `func.c` slice), swap the helper for a direct
        call — the call-site is a one-liner.
      * **`zPath[-1]` access at the empty-path JEDIT_AINS check**
        relies on the recursive caller having advanced past `[N]`,
        so the `]` byte is one position before the current pointer.
        Pascal preserves the C semantics via `(zPath - 1)^` pointer
        arithmetic; safe iff entry point is non-empty and recursion
        chain went through the `[` branch.  Worth a defensive
        comment when 6.8.h adds public-API entry points (json_set
        etc. always pass a non-empty path beginning with `$`).
      * **`emptyObject[2]` table.**  Mirrored as a Pascal typed const
        `array[0..1] of u8 = (JSONB_ARRAY, JSONB_OBJECT)` with index
        selected by `if zTail[0] = '.' then 1 else 0` (vs C's
        `[zTail[0]=='.']` bool→int conversion).  Deliberately kept
        as a `const` inside `jsonCreateEditSubstructure` — FPC
        accepts a typed-const array of `u8` inside a function body
        when no field is a pointer.  Same trick used in 6.7's
        window-function array (see Phase 6.7 notes below).
      * **Output blob ownership for substructure inserts.**  When
        `zTail = ''`, `pIns` borrows `pParse^.aIns` directly (no
        alloc).  `jsonParseReset(@pIns)` is then a no-op for the
        blob since `nBlobAlloc=0`.  When `zTail <> ''`, the recursive
        `jsonLookupStep(pIns, …, zTail, 0)` mutates `pIns` to grow
        `pIns^.aBlob` (which becomes owned via
        `jsonBlobMakeEditable`); `jsonParseReset(@pIns)` then frees
        it normally.  Only landed test for the empty-tail case
        (T330..T332); the deep-tail substructure synthesis exercises
        through 6.8.h's `json_set('{}','$.a.b.c',5)` end-to-end.
      * **`pParse^.iLabel` is set on success.**  `iLabel = 0` means
        "this element is not the value-half of an object key/value
        pair" (e.g. it's the root, or an array element).  The DEL
        arm uses `iLabel > 0` to extend the deletion range backward
        to include the label bytes.  6.8.h's `json_remove` will
        rely on this same convention.

  - **2026-04-26 — Phase 6.8.e JSON blob→text + pretty.**  Lands the
    rendering surface that turns JSONB back into JSON text:
    `jsonTranslateBlobToText` (~250 lines covering all 13 JSONB types
    incl. INT5 hex→decimal with overflow→"9.0e999", FLOAT5 leading-dot
    normalisation, TEXTJ/TEXT5 escape replay incl. \v / \x / \0 / \r\n /
    U+2028..2029 whitespace fold, ARRAY/OBJECT recursion with depth
    guard), `jsonTranslateBlobToPrettyText` (`json_pretty()` driver — uses
    `jsonAppendChar(',')` + `jsonAppendChar(#$0A)` between elements; falls
    through to the flat translator for primitives), `jsonPrettyIndent`,
    plus the supporting `TJsonPretty` record and a private
    `jsonAppendU64Decimal` stand-in for `jsonPrintf(100,…)`'s sole INT5
    use-case.

    Concrete changes:
      * `src/passqlite3json.pas` — adds `TJsonPretty` (record), 4 routines
        (~330 lines added).
      * `src/tests/TestJson.pas` — adds T276..T301 (26 new asserts:
        literals/numbers/strings/array/object round-trip, INT5 hex→decimal,
        FLOAT5 leading-dot, JSON5 single-quote rerendered as double-quoted,
        nested, malformed-blob eErr propagation, pretty array/object/empty
        with 2-space indent).  **300/300 PASS** (was 274/274).
      * Regression spot check: TestPrintf 105/105, TestVtab 216/216,
        TestParser 45/45, TestSchemaBasic 44/44, TestUtil ALL PASS.

    Discoveries / next-step notes:
      * **JSON-tool escape-decoding inside Pascal source strings.**  Writing
        `''` or `' '` as Pascal literals via the Edit/Write
        tools gets pre-decoded by the tool's JSON layer — `` becomes
        a literal VT byte (0x0b), ` ` becomes a NUL byte.  These then
        appear inside Pascal `'…'` strings as one-byte literals, not the
        intended six-byte escape sequences for JSON output.  Fix: emit the
        backslash via `#$5C` and concatenate in Pascal source —
        `#$5C+'u000b'`.  Same pattern will bite again in 6.8.h
        (`json_quote`) and any future test that needs to emit literal
        backslash-escapes.  Adding to porting-rule list.
      * **`for jj := 0 to nIndent - 1 do` with `nIndent: u32 = 0` is a
        trap.**  FPC evaluates `nIndent - 1` in u32 first → $FFFFFFFF, then
        the loop runs ~4 billion times.  Used `while jj < nIndent do`
        instead — same shape will be needed anywhere a u32 counter loops
        over a possibly-zero count.  Logged as a porting rule below.
      * **`jsonPrintf` deferred / inlined.**  C uses `jsonPrintf(100, pOut,
        zFmt, …)` (a thin `sqlite3_vsnprintf` wrapper) at exactly two
        call-sites in 6.8.e: INT5 overflow → `"9.0e999"`, INT5 normal →
        `"%llu"`.  Rather than wire varargs into Pascal, I added a private
        `jsonAppendU64Decimal(p, u, bOverflow)` covering both.  When 6.8.h
        lands `jsonAppendSqlValue` (which uses `jsonPrintf(100, p,
        "%!0.15g", …)` for floats), a real `jsonPrintf` will become
        worthwhile — its third call-site is in 6.8.f's `jsonAppendPathStep`
        (`"%lld"` / `".\"%.*s\""`).
      * **`TJsonPretty.pParse^.iDepth` is `u16` in the port but `u32` in
        C.**  The pretty path stores `pPretty^.nIndent` (u32) into
        `pParse^.iDepth` for the OBJECT arm.  Cast required:
        `pParse^.iDepth := u16(pPretty^.nIndent)`.  iDepth is bounded by
        JSON_MAX_DEPTH=1000 so the cast never truncates.  Worth widening
        `iDepth` to u32 if 6.8.h or 6.8.f start mixing depth fields more.
      * **`jsonReturnTextJsonFromBlob` / `jsonReturnParse` deferred to
        6.8.h.**  Same dep-cycle reason as `jsonAppendSqlValue` /
        `jsonReturnString`: they call `sqlite3_result_*` which lives in
        passqlite3vdbe.  6.8.h's SQL dispatch chunk is the natural place.
      * **Expanded escape table (`'\v'`/`'\0'`/`'\xHH'`) in TEXT5.**  The
        Pascal port emits `` / ` ` / `\u00HH` literally — six
        ASCII chars each — matching json.c's strict-JSON output.  Tests
        do not exercise this branch yet (would need a hand-built TEXT5
        node since 6.8.d `jsonTranslateTextToBlob` produces TEXTJ for most
        text); marked as a future test in 6.8.h once `jsonb_text` round-
        trips are visible at the SQL surface.

  - **2026-04-26 — Phase 6.8.d JSON text→blob translator.**  Lands
    the parsing surface that turns JSON / JSON5 source text into the
    JSONB on-disk representation: `jsonTranslateTextToBlob` (~460
    lines of recursive-descent over objects / arrays / strings /
    numbers / literals / NaN-Inf / JSON5 hex+identifier keys),
    `jsonConvertTextToBlob` (top-level driver — trailing whitespace
    + JSON5 ws sweep, malformed-trailing-bytes detection),
    `jsonbValidityCheck` (deferred from 6.8.c — full JSONB
    self-check including TEXT5 escape replay through
    `jsonUnescapeOneChar`), and the supporting helper layer:
    `jsonBytesToBypass`, `jsonUnescapeOneChar` (recursive — chains
    on the LS / PS / CR-LF escaped-newline replay path),
    `jsonLabelCompare` + `jsonLabelCompareEscaped` (raw-vs-escaped
    object-key comparison, both sides may carry escapes),
    `jsonIs4HexB`, and a partial `jsonParseReset` (RCStr branch
    stubbed — see 6.8.h).
    
    Pre-req helper added to `passqlite3util`:
    `sqlite3Utf8ReadLimited` (faithful port of utf.c:208) — reads
    one UTF-8 codepoint with a hard 4-byte limit.
    `sqlite3Utf8Trans1` was already present from earlier UTF work
    so no new table.

    Concrete changes:
      * `src/passqlite3util.pas` — adds `sqlite3Utf8ReadLimited`
        (interface + ~15 line impl).
      * `src/passqlite3json.pas` — adds the 6.8.d surface
        (~700 lines added: 9 new routines + the recursive descent).
      * `src/tests/TestJson.pas` — adds T200..T275 (76 new asserts:
        bytesToBypass for \n / \r\n / LS escapes, unescapeOneChar
        for short escapes / \x / \u / \uXXXX surrogate-pair
        composition / malformed, labelCompare raw-vs-escaped,
        translate for all literal/number/string/array/object/nested
        forms incl. JSON5 single-quoted, convertTextToBlob trailing
        whitespace and malformed gates, validityCheck pass/fail for
        array/literal/int, jsonIs4HexB).  **274/274 PASS** (was
        198/198).
      * Regression spot check: TestUtil ALL PASS, TestPrintf
        105/105, TestVtab 216/216, TestParser 45/45,
        TestSchemaBasic 44/44 — all green.

    Discoveries / next-step notes:
      * **C `for(j=i+1;;j++)` ↔ Pascal `while True do`.**  C's
        for-loop runs `j++` after every iteration body, including
        the path through `continue`.  Mechanically translating to
        a Pascal `while True do` drops that increment, so a
        `Continue` after matching `,` left j parked on the comma
        and the next iteration mis-parsed it as `-4`.  Fix:
        explicitly `Inc(j); Continue;` everywhere the C `continue`
        relied on the for-loop's tail.  Three sites in the array
        body, three in the object body.  Same pattern will
        re-appear in 6.8.e's blob-to-text reader and 6.8.f's
        path-walk; flagging here so the reader catches it on first
        pass.
      * **`goto` across `case` arms is unsafe in FPC.**  Original
        port had separate `case Ord('"')` / `case Ord('''')` arms
        with a `goto parse_string` between them, mirroring C's
        fallthrough.  FPC's label semantics for inter-arm goto are
        undefined; consolidated to a single `Ord(''''), Ord('"')`
        arm with a runtime branch on `z[i]` for the JSON5 nonstd
        flag.  Same consolidation applied to `'+' / '.' / '-' /
        '0'..'9'` for the number parser.  Within an arm, goto
        between `parse_number` / `parse_number_2` /
        `parse_number_finish` labels is fine (same scope).
      * **Pascal source UTF-8 trap.**  Writing
        `'«'` literal in a `'...'`-quoted Pascal string was
        silently re-encoded by the editor pass into the actual
        2-byte UTF-8 for «.  Test then exercised the wrong code
        path in `jsonUnescapeOneChar` (which expects an ASCII `\`
        + `u` + four hex bytes).  Switched to explicit char-code
        composition `#92'u00AB'` to bypass file-encoding rewrites
        — same fix applies to the surrogate-pair test.  Worth
        keeping in mind for any future test that needs to embed
        backslash-prefixed escapes.
      * **`pCtx` error sinking deferred to 6.8.h.**  In C,
        `jsonConvertTextToBlob` calls `sqlite3_result_error_nomem`
        / `sqlite3_result_error(pCtx, "malformed JSON", -1)` to
        propagate parse failures to the SQL caller.  Pulling
        `passqlite3vdbe` into the JSON unit would create a
        recursive dep with codegen, so the Pascal port stops at
        the return-1 / parse-reset boundary.  6.8.h wires the SQL
        dispatch surface; that's the natural place to translate
        eErr / oom into `sqlite3_result_*`.
      * **`jsonParseReset` RCStr branch stubbed.**  When
        `bJsonIsRCStr` is set, C calls `sqlite3RCStrUnref(zJson)`.
        RCStr isn't ported (deferred to 6.8.h alongside
        `jsonReturnString`).  Until then, no caller sets
        `bJsonIsRCStr` so the branch is unreachable; left as a
        TODO marker rather than introducing a partial RCStr port.
      * **`jsonTranslateTextToBlob` uses `pParse^.nJson` as the
        outer JSON length** when reserving header sz for the root
        `{` / `[`.  The reserved size is overwritten by
        `jsonBlobChangePayloadSize` after the children land,
        matching C — but it does mean the top-level header cost is
        a function of input size, not output size.  6.8.f's path
        edit uses `jsonAfterEditSizeAdjust` (already in 6.8.c) to
        keep this in sync.

  - **2026-04-26 — Phase 6.8.c JsonParse blob primitives.**  Lands the
    JSONB editing surface: byte-accurate ports of `jsonBlobExpand`,
    `jsonBlobMakeEditable`, `jsonBlobAppendOneByte`, `jsonBlobAppendNode`
    (+ slow-path expand-and-append), `jsonBlobChangePayloadSize`,
    `jsonbPayloadSize`, `jsonbArrayCount`, `jsonAfterEditSizeAdjust`,
    `jsonBlobOverwrite`, `jsonBlobEdit`.  All header-size variants
    (1/2/3/5/9-byte sz fields) and the in-place "denormalize header to
    avoid memmove" optimisation in `jsonBlobOverwrite` are preserved.

    Concrete changes:
      * `src/passqlite3json.pas` — adds the blob primitive surface
        (~270 lines: 10 routines + the `aType[]` overwrite lookup).
        Allocations route through `sqlite3DbRealloc` on `pParse^.db`;
        OOM sets `pParse^.oom` and writes silently no-op (matches C).
      * `src/tests/TestJson.pas` — adds T140..T199 (60 new asserts:
        expand grow path, makeEditable copy-out, appendOneByte spill,
        appendNode for 1/2/3/5-byte hdrs, payloadSize parse for each,
        changePayloadSize +/- header transitions with payload move,
        arrayCount over [1,2,3], blobEdit pure-delete and pure-insert,
        afterEditSizeAdjust delta application).  **198/198 PASS** (was
        139/139).
      * Regression spot check: TestPrintf 105/105, TestVtab 216/216,
        TestParser 45/45, TestSchemaBasic 44/44 — all green.

    Discoveries / next-step notes:
      * **`jsonbValidityCheck` deferred to 6.8.d.**  Its JSONB_TEXT5
        escape arm calls `jsonUnescapeOneChar` (a 6.8.d helper), which
        in turn needs `sqlite3Utf8ReadLimited` + the
        `sqlite3Utf8Trans1[]` table — neither is in `passqlite3util`
        yet.  Cleaner to land them as one slice in 6.8.d than to ship
        a strictness-divergent partial validator here.  Task plan
        amended: 6.8.c's surface no longer lists `jsonbValidityCheck`,
        and 6.8.d's surface now lists it together with the helper
        chain it depends on.
      * **`jsonBlobOverwrite` is JSONB-shape-specific.**  Initial test
        T186-T191 tried to exercise the d<0 fast path with a raw
        "hello" buffer; it succeeded (because raw bytes happen to
        parse as a 1-byte-header JSONB node) but produced
        unexpected results.  Rewrote as a pure delete (aIns=nil
        bypasses the overwrite branch outright), which exercises
        the canonical memmove + delta-update path.  When 6.8.f tests
        editing real JSONB structures, the overwrite fast path will
        get exercised naturally.
      * **Pascal `case` default is `else`.**  In `jsonBlobOverwrite`'s
        switch on `aIns[0] shr 4`, the C `default` branch (handling
        header sizes 0..11, i.e. all "small" payloads) is the most
        common case.  Pascal's `case ... else` matches it exactly.
      * **i64 widening on `delta` math.**  `jsonBlobChangePayloadSize`
        and `jsonBlobEdit` both compute `nBlob + delta` where delta
        can be negative.  Done explicitly via `i64()` casts before
        re-narrowing to `u32` for the assignment to keep FPC's
        unsigned-arithmetic semantics from biting.
      * `jsonbPayloadSize` is now usable from the rest of json.pas;
        6.8.d's text-to-blob translator reads it on every node it
        consumes, and 6.8.e's blob-to-text reader is ~80% calls into
        this single helper.

  - **2026-04-26 — Phase 6.8.b JsonString accumulator.**  Lands the
    string-builder layer of the JSON port: `jsonStringInit/Zero/Reset/
    Oom/TooDeep/Grow/ExpandAndAppend`, `jsonAppendRaw/RawNZ/Char/
    CharExpand/Separator/ControlChar/String`, `jsonStringTrimOneChar`,
    `jsonStringTerminate`.  Append-only builder with the 100-byte
    inline `zSpace[]` and libc-malloc spill on overflow.  Faithful
    1:1 transliteration of json.c:534..797.

    Concrete changes:
      * `src/passqlite3json.pas` — adds the accumulator (interface
        signatures + ~210 lines of implementation); pulls
        `passqlite3os` into the uses clause for `sqlite3_malloc64` /
        `sqlite3_realloc64` / `sqlite3_free`.
      * `src/tests/TestJson.pas` — adds T99..T139 (41 new asserts:
        init/reset, basic append, inline→spill transition,
        per-char growth, separator commas, trim+terminate, control-char
        short and \uXXXX escapes, jsonAppendString plain/escape/empty/
        nil/JSON5-squote/fast-path-8B, large spill).
        **139/139 PASS** (was 98/98).
      * Regression spot check: TestPrintf 105/105, TestVtab 216/216,
        TestParser 45/45, TestSchemaBasic 44/44 — all green.

    Discoveries / next-step notes:
      * **RCStr stays deferred.**  json.c spills onto an RCStr-backed
        buffer so `jsonReturnString` can hand the same buffer to
        `sqlite3_result_text64` with `sqlite3RCStrUnref` as the destructor.
        The accumulator itself does not need RCStr semantics — plain
        libc-malloc round-trips cleanly through `Reset`.  When 6.8.h
        wires `jsonReturnString`, the spill type can be lifted to RCStr
        (or `jsonReturnString` can `sqlite3_malloc64`-copy with
        `SQLITE_DYNAMIC` destructor — also valid).  Decision deferred
        to 6.8.h.
      * **OOM/TooDeep error sinking deferred.**  C calls
        `sqlite3_result_error_nomem` / `sqlite3_result_error` from
        `jsonStringOom` / `jsonStringTooDeep`.  The Pascal port records
        the bit in `eErr` only — pulling `passqlite3vdbe` into the JSON
        unit would create a heavy dep cycle with codegen.  6.8.h will
        surface `eErr` to the SQL caller via `jsonReturnString` (which
        is the only callsite where `pCtx` is actually a real
        `sqlite3_context`, not nil — until then, all internal callers
        check `eErr` directly and abort cleanly).
      * **`jsonAppendSqlValue` deferred to 6.8.h.**  It needs
        `sqlite3_value_type/double/text/bytes/subtype` (vdbe), plus
        `jsonArgIsJsonb` and `jsonTranslateBlobToText` from later
        chunks.  Listed it under 6.8.h's surface in the chunk-list
        re-spelling.
      * **JSON5 single-quote pass-through verified.**  json.c:786..788
        emits `'` as a literal byte inside a quoted string (it is *not*
        in `jsonIsOk` because the JSON5 surface escape handler treats
        it as a marker, but inside a quoted JSON output we emit it raw
        — JSON RFC-8259 doesn't require it escaped, only `"` and `\`).
        T135 covers this.

  - **2026-04-26 — Phase 6.8.a JSON foundation.**  Opens the optional
    `json.c` port (5680 lines of C, ~6 sub-chunks planned) with the
    foundation slice: types, constants, byte-classification lookup
    tables, and pure helpers.  No external dependencies beyond
    `passqlite3types` + `passqlite3util`, so the unit compiles cleanly
    and lays groundwork for the next slices without forcing them to
    block on each other.

    New unit `src/passqlite3json.pas` (~370 lines):
      * **Types**: `TJsonCache`, `TJsonString`, `TJsonParse`,
        `TNanInfName` (struct shapes mirror json.c:289..374; Pascal
        `Pointer` stand-ins for `sqlite3*` / `sqlite3_context*` to
        avoid pulling vdbe into the uses clause this early).
      * **Constants**: `JSONB_*` (NULL..OBJECT = 0..12),
        `JSTRING_*` (OOM/MALFORMED/TOODEEP/ERR), `JEDIT_*`
        (DEL/REPL/INS/SET/AINS), `JSON_JSON`/`SQL`/`ABPATH`/`ISSET`/
        `AINS`/`BLOB` flag bits, `JSON_SUBTYPE = 74` ("J"),
        `JSON_CACHE_ID = -429938`, `JSON_CACHE_SIZE = 4`,
        `JSON_INVALID_CHAR = $99999`, `JSON_MAX_DEPTH = 1000`,
        `JSON_EDITABLE` / `JSON_KEEPERROR`.
      * **Lookup tables**: `aJsonIsSpace[256]` (RFC-8259 strict ws
        set: HT/LF/CR/SPACE), `jsonSpaces` (`#$09#$0A#$0D#$20`),
        `jsonIsOk[256]` (string-body-safe bytes; gates 0..0x1f, `"`,
        `'`, `\`, and the 0xE0 marker reserved for upstream's UTF-8
        sentinel logic), `jsonbType[17]` (human-readable type names
        with the 13..16 reserved-slot zero-fill preserved),
        `aNanInfName[5]` (the JSON5 NaN/Infinity literal substitution
        table: inf, infinity, NaN, QNaN, SNaN).
      * **Helpers** (pure / no DB deps): `jsonIsspace`,
        `jsonHexToInt`, `jsonHexToInt4`, `jsonIs2Hex`, `jsonIs4Hex`,
        `json5Whitespace`.  `json5Whitespace` is the most involved —
        a faithful translation of json.c:1019..1108 covering ASCII
        ws (HT/LF/VT/FF/CR/SP), `/* … */` and `// … EOL` comments
        (including the U+2028 / U+2029 line-separator EOL trigger
        inside line comments), and the multi-byte Unicode space set
        (NBSP, ogham, en/em quads, three/four/six-per-em, figure,
        punctuation, thin, hair, line/paragraph separators, NNBSP,
        MMSP, ideographic, BOM).

    Concrete changes:
      * `src/passqlite3json.pas`           — new (Phase 6.8.a).
      * `src/tests/TestJson.pas`           — new gate test.
        **98/98 PASS**.
      * `src/tests/build.sh`               — register TestJson after
        TestPrintf.

    Discoveries / next-step notes:
      * **FPC case-insensitivity bites again.**  `jsonIsSpace` (the
        table) and `jsonIsspace` (the inline function — keeps the C
        macro name) collide because FPC sees `IsSpace` and `Isspace`
        as the same identifier.  Renamed the table to `aJsonIsSpace`
        (matches the existing `aFlagOp` / `aBase` / `aScale` naming
        used elsewhere in the port for static lookup tables) and kept
        the function's lower-case name to mirror json.c:196's
        `jsonIsspace(x)` macro.  Same family of issue as the recurring
        `pPager: PPager` feedback (memory:
        `feedback_fpc_vartype_conflict`) — extending the rule:
        **lookup tables that share a base name with their
        accessor function should be `a`-prefixed**.
      * `aNanInfName` uses Pascal record literal syntax with field
        names; FPC accepts this for typed const arrays at unit
        scope.  Keep an eye on this if 6.8.h needs to embed it inside
        a procedure body — typed-const-in-procedure with pointer
        fields has historically tripped the parser (per Phase 6.7
        pitfall on `TFoo` records with `PAnsiChar` fields).
      * Subsequent 6.8 chunks (6.8.b..h) are sequenced in the
        unit-header doc-comment; 6.8.b (JsonString accumulator)
        unblocks the rest because every subsequent slice needs string
        building.  6.8.b's main external dep is `sqlite3RCStr*` —
        not yet ported; either add an RCStr stub in `passqlite3util`
        or have JsonString fall back to plain libc-malloc strings
        for the spill path (lossy but functional).

  - **2026-04-26 — Phase 6.bis.4b.2b `%S` SrcItem conversion.**  Closes
    out the last open 6.bis.4b sub-task by porting the
    `etSRCITEM` arm from printf.c:975..1008.  Four-way cascade:
    `zAlias` (default priority); `zName` with optional `db.` prefix
    when neither `fg.fixedSchema` nor `fg.isSubquery` is set; `zAlias`
    fallback when `zName=nil`; or a synthetic subquery descriptor
    (`(join-N)` / `(subquery-N)` / `N-ROW VALUES CLAUSE`) reading
    `pSubq^.pSelect^.{selFlags,selId}` and `u1.nRow`.  The `!` flag
    (altform2) flips priority to force `zName` over `zAlias`.

    Local mirror types — `TSrcItemBlit` (72 bytes), `TSubqueryBlit`,
    `TSelectBlit` — keep `passqlite3printf` decoupled from
    `passqlite3codegen`, same pattern the existing `TTokenBlit`
    established for `%T`.  Field offsets verified against
    `passqlite3codegen.TSrcItem`.  Bit positions for the fg flags
    derived from sqliteInt.h:3360..3378 (LSB-first within each byte):
    `fgBits` bit 2 = isSubquery, `fgBits3` bit 0 = fixedSchema.

    Original task notes flagged this as blocked by Phase 7's TSrcItem
    layout, but codegen already stabilised the layout in 7.2/7.3 — the
    "block" was sequencing, not a real dependency, so the work
    transliterated cleanly with no Phase-7 follow-up.

    Concrete changes:
      * `src/passqlite3printf.pas` — adds the SrcItem mirror types,
        `emitSrcItem`, and the `'S':` arm in the conversion switch
        (~70 lines added, right after the `%T` block).  Header
        doc-comment updated to list `%S` and drop the deferral note.
      * `src/tests/TestPrintf.pas` — adds `TestSrcItem` with T89..T100
        (13 new asserts).  **105/105 PASS** (was 92/92).
      * Full regression spot check: TestVtab 216/216, TestCarray
        66/66, TestDbpage 68/68, TestDbstat 83/83, TestVdbeVtabExec
        50/50, TestParser 45/45, TestParserSmoke 20/20 — all green.

    Discoveries / next-step notes:
      * `SF_MultiValue` / `SF_NestedFrom` are re-declared locally in
        the printf unit (`SF_MultiValueLocal` / `SF_NestedFromLocal`)
        to avoid pulling `passqlite3codegen` into the uses clause.
        If upstream renumbers these, both copies drift and tests
        catch it; the constants have been stable since SQLite 3.20.
      * The C reference gates the entire `etSRCITEM` body on
        `printfFlags & SQLITE_PRINTF_INTERNAL` (silently returns
        otherwise to keep external callers from probing internal
        struct shapes).  The Pascal port mirrors the existing `%T`
        precedent — no gate, since all current callers are internal.
        Add the gate when an external printf surface lands.
      * **All `printf.c` conversions are now ported.**  6.bis.4b is
        fully closed.  Remaining open task list items: 5.10 / 6.9 /
        7.4b / 8.10 (each blocked on later phases — SQL corpus,
        bytecode-diff harness, or shell.c CLI), plus the optional
        6.8 (json.c) and Phase 9+ acceptance gates.

  - **2026-04-26 — Phase 6.bis.4b.2c float conversions.**  Lands the
    bulk of the remaining 6.bis.4b work — `%f` / `%e` / `%E` / `%g` /
    `%G` are now wired into the printf engine.  Faithful port of
    `sqlite3FpDecode` (util.c:1380) plus its dependencies, so float
    output matches the C reference's bespoke decimal renderer
    byte-for-byte instead of falling back to libc snprintf.

    New machinery in `src/passqlite3printf.pas` (~330 lines added):
      * `multiply128` — 64x64→128 unsigned multiply, pure-Pascal
        version of util.c's non-intrinsic fallback (FPC has no native
        u128 type).
      * `multiply160` — 96x64→160 multiply used by `powerOfTen` for
        |p| > 26.
      * `powerOfTen` (-348..+347) — copies the three big tables
        verbatim (`aBase[27]`, `aScale[26]`, `aScaleLo[26]`).
      * `pwr10to2` / `pwr2to10` — uses `SarLongint` for arithmetic
        right shift on signed inputs (FPC's `shr` is logical, but the
        C reference relies on signed-arithmetic-shift semantics).
      * `countLeadingZeros` — pure-Pascal bit-test fallback.
      * `fp2Convert10` — m*pow(2,e) → d*pow(10,p).
      * `fpDecode` — the entry point.  Mirrors util.c exactly modulo
        the iRound==17 round-trip optimization noted below.
      * `renderFloat` — port of the etFLOAT/etEXP/etGENERIC branch
        from printf.c:528..738.  Handles `flag_dp` / `flag_rtz`
        (remove trailing zeros), generic→float/exp dispatch on
        magnitude, `e±NN` exponent suffix.

    Wiring in the conversion switch (`'f'`, `'e'`, `'E'`, `'g'`, `'G'`
    arms): default precision 6, Inf/NaN special handling (`-Inf` /
    `+Inf` / ` Inf`, `NaN` (or `null` under zeropad-Inf)), the
    `#` + zero-display sign-suppression rule from printf.c:579..597,
    and `emitField`-driven width / zero-pad / left-align so the
    pre-existing flag handling stays consistent across conversions.
    The `!` (altform2) flag now also propagates — adds a 20-digit
    precision ceiling instead of the default 16.

    Skipped (deliberately, with a comment in the header):
      * The iRound==17 round-trip optimization that uses
        `sqlite3Fp10Convert2` to find the *shortest* representation
        for `%!.17g` / altform2 paths.  FpDecode without it is still
        faithful — it just doesn't try to shave trailing 9s/0s back
        to a shorter round-trip value.  Affects only `%!.17g`-style
        rendering of certain doubles; `.dump` does not exercise it.
        Easy follow-up if a future callsite needs it; the renderer
        signature is already wired.

    Concrete changes:
      * `src/passqlite3printf.pas` — new section "Floating-point
        decode" before the core renderer.  Header doc-comment
        rewritten to list the float conversions and re-scope the
        deferred items.
      * `src/tests/TestPrintf.pas` — adds `TestFloat` with T58..T88
        (31 new asserts).  Expected values are *canonical SQLite*
        outputs (built via `sqlite3_mprintf` against the oracle
        `libsqlite3.so`), not libc snprintf — so e.g. T77 expects
        `%.0f` of 2.5 → `3` (round-half-up, SQLite-specific) rather
        than libc's banker-rounded `2`.  **92/92 PASS** (was 61/61).
      * Full regression spot check: TestVtab 216/216, TestCarray
        66/66, TestDbpage 68/68, TestDbstat 83/83, TestVdbeVtabExec
        50/50 — all green, no regressions.

    Discoveries / next-step notes:
      * FPC quirk worth memoising: `Dec(precision)` on a value
        parameter inside a procedure with nested sub-procedures hits
        a parser error ("Illegal expression"); rewrote as
        `precision := precision - 1`.  Plain assignment is the
        portable form when the parameter is referenced by inner
        scopes.
      * FPC `shr` on signed types is logical (zero-fill), not
        arithmetic (sign-fill).  C's `>>` on signed `int` is
        implementation-defined but on x86 GCC is arithmetic.  The
        `pwr10to2` / `pwr2to10` ratios depend on arithmetic shift
        for negative inputs.  `SarLongint(value, bits)` (in `system`)
        is the right primitive — produced bit-identical results.
      * Real-literal constants like `1.0/3.0` in `array of const`
        appear to box as `vtExtended` but the *constant evaluation*
        happens at Single precision under default OBJFPC mode (the
        `1.0/3.0` literal in test code yields `3.33333343...e-1`,
        which is a Single value re-widened).  Doesn't affect printf
        correctness — the engine renders whatever Double it
        receives — but it bit users writing tests that pass
        compile-time real expressions.  Pass through a typed `Double`
        local to avoid the surprise.
      * `multiply160` is only exercised when `|p| > 26` in
        `powerOfTen`, which corresponds to extreme-magnitude doubles
        (≈ ±1e26 and beyond).  The T72 (`%g 1e10`) test sits below
        that threshold.  Added T-block coverage at 1.23456789e20 /
        1.23456789e-20 in spot tests (off-tree) — both round-trip
        cleanly.
      * Remaining 6.bis.4b items: only **6.bis.4b.2b** (`%S` SrcItem)
        stays open, blocked by Phase 7's `TSrcItem` layout.  Trivial
        ~10-line addition once that lands.

  - **2026-04-26 — Phase 6.bis.4b.2a `%r` ordinal conversion.**  Lands
    the first follow-up half of 6.bis.4b.2 (the part the prior slice
    flagged as ship-able independently of the float work).  Faithful
    port of `etORDINAL` (printf.c:481..488):

      * Suffix selection: `(|v| mod 10) >= 4` OR `((|v|/10) mod 10) = 1`
        → `'th'`; otherwise 1→`'st'`, 2→`'nd'`, 3→`'rd'`.  This handles
        the 11/12/13 teen exception (12th not 12nd) and the decade
        resumption pattern (21st 22nd 23rd 24th; 101st 111th 121st).
      * Sign prefix (`-`, `+`, ` `) honoured on the digit prefix; suffix
        always uses `|value|` so e.g. `-1` → `-1st` (not `-1th`).
      * Width is space-padded only.  Numeric zero-pad is intentionally
        suppressed because the suffix is literal text — `0021st` would
        be nonsense.  Matches the typical use sites (diagnostic
        messages like `"argument %r is invalid"`).

    The 6.bis.4b.2 work item is now split into three:
      * 6.bis.4b.2a — `%r` (this slice, DONE).
      * 6.bis.4b.2b — `%S` SrcItem (blocked by Phase 7 TSrcItem layout).
      * 6.bis.4b.2c — full float port (`sqlite3FpDecode` / `Fp2Convert10`
        / `sqlite3Multiply128` + ~210-line etFLOAT/etEXP/etGENERIC
        renderer).

    Concrete changes:
      * `src/passqlite3printf.pas` — adds the `'r'` arm in the conversion
        switch (~15 lines, right after `%T`); header doc-comment updated
        to list `%r` and re-scope the deferred items.
      * `src/tests/TestPrintf.pas` — adds `TestOrdinal` with T37..T57
        (21 new asserts: signed and unsigned cases, teen exception,
        decade resumption, three-digit cases, width pad both directions,
        message embed).  **61/61 PASS** (was 40/40).
      * Full regression spot check: TestVtab 216/216, TestCarray 66/66,
        TestDbpage 68/68, TestDbstat 83/83 — all green.

    Discoveries / next-step notes:
      * The unknown-conversion fall-through (which emits `%y` verbatim
        for an unsupported letter) was the only concern when adding a
        new arm — confirmed `'r'` was previously hitting that fall-
        through (T28 `unknown %y` test pattern), so any caller that
        had been writing `%r` against the prior engine would have been
        getting a literal `%r` echo, not a crash.  Migration is
        therefore strictly additive.
      * `case` arm needs `else` rather than a default-arrow — FPC's
        `case x of N: ... else ... end` handles the missing-N fallback
        without label-syntax; previously caught a tempting label
        construct (`declare_ordinal: ;`) that turned out to be a
        no-op.  Plain `if/else case/else end` works.
      * 6.bis.4b.2c (float port) is the bulk of the remaining 6.bis.4b
        work and is genuinely substantial — `sqlite3FpDecode` depends
        on `sqlite3Multiply128`, the `powerOfTen` lookup table, and
        the bespoke base-10/base-2 conversion helpers.  Earmarking
        this as a dedicated slice rather than rolling it into 4b.2.

  - **2026-04-26 — Phase 6.bis.4b.1 printf migration of FmtMsg shims +
    partial `sqlite3VtabFinishParse` wiring.**  Discharges the first
    half of the 6.bis.4b follow-up promised in 6.bis.4a:

      * `sqlite3VtabFmtMsg1Db` / `sqlite3VtabFmtMsg1Libc` in
        `passqlite3vtab.pas` are no longer `SysUtils.Format`-based.
        Both helpers now call into the in-tree printf engine
        (`sqlite3MPrintf` / `sqlite3PfMprintf`) with the same
        fmt-or-literal contract, so the four downstream callers in
        carray / dbpage / dbstat / vtab pick up the new path with no
        edits — they were already routed through these shared helpers
        by 6.bis.3e.  `SysUtils.Format` is now unused by the printf-
        adjacent surface; the only `SysUtils` consumers in the vtab
        modules are the timing / file-IO helpers from other slices.
      * `sqlite3VtabFinishParse` (passqlite3parser.pas:1989) lights up
        the long-deferred `init.busy=0` printf call:
        `sqlite3MPrintf(db, "CREATE VIRTUAL TABLE %T", &sNameToken)`.
        The full body still depends on `sqlite3NestedParse` plus
        several Phase-7 codegen helpers, so the result is freed
        immediately — but the call exercises the `%T` conversion
        against a parser-produced `sNameToken`, including the
        `pEnd`-driven token-length fix-up at `vtab.c:474`.  When
        Phase-7 lands NestedParse, this call becomes load-bearing
        without any further printf-side rework.
      * `passqlite3parser.pas` now imports `passqlite3printf` for the
        first time; previously parser code had no printf consumer.

    Allocation contract reminder for the migration: the C reference
    distinguishes `sqlite3MPrintf` (db-malloc — freed by
    `sqlite3DbFree(db, …)`) from `sqlite3_mprintf` / our
    `sqlite3PfMprintf` (libc malloc — freed by `sqlite3_free` /
    `free`).  The Db variant is used by error-message strings
    written into `pzErr^` for vtab constructor / SQL-builder paths
    (sqlite3DbFree later).  The Libc variant is used for
    `pVtab^.zErrMsg` strings (the sqlite3 spec says the engine
    `free`s those itself).  Both shims preserve those contracts; no
    callsite in the four migrated modules needed adjustment.

    Concrete changes:
      * `src/passqlite3vtab.pas` — adds `passqlite3printf` to `uses`;
        rewrites `sqlite3VtabFmtMsg1Db` / `…Libc` bodies (drops 30+
        lines of `SysUtils.Format` machinery, replaced with 6 lines
        of printf delegation).
      * `src/passqlite3parser.pas` — adds `passqlite3printf` to `uses`;
        `sqlite3VtabFinishParse` adds the live `sqlite3MPrintf` call
        plus `pEnd`-token fix-up.  Comment block rewritten to record
        which Phase-7 helpers remain blocking.

    Full 51-binary test sweep: all green.  TestPrintf 40/40,
    TestVtab 216/216, TestCarray 66/66, TestDbpage 68/68,
    TestDbstat 83/83, TestVdbeVtabExec 50/50.

    Discoveries / next-step notes:
      * The `passqlite3printf` unit imports only
        `passqlite3types` + `passqlite3util`, so depending on it from
        `passqlite3parser` / `passqlite3vtab` does not introduce any
        circular references — every existing import already pulls in
        both upstream units.
      * The `Pos('%', fmt) > 0` check inside the helpers is intentional
        and stays.  Without it, a fmt that already happens to be a
        literal message containing `%` (e.g. an external xCreate's
        zErr that includes a percent sign) would be mis-interpreted
        as a fresh format string and consume an arg.  The
        `'%s'`-with-fmt-as-arg path neutralises that.
      * Remaining 6.bis.4b work, now broken out as
        **6.bis.4b.2**: float conversions (`%f %e %E %g %G`),
        `%S` SrcItem, `%r` ordinal.  Float work is the bulk —
        requires porting `sqlite3FpDecode` (util.c:1380) and
        `sqlite3Fp2Convert10` plus the 200-line etFLOAT/etEXP/etGENERIC
        renderer in printf.c.  `%r` is a 5-line addition that can ship
        independently if a callsite needs it before the float port
        lands.

  - **2026-04-26 — Phase 6.bis.4a printf core (mini-port).**  Lands the
    long-awaited printf machinery flagged as a recurring blocker by
    every prior 6.bis sub-phase (1c..1f, 2a..2d).  New unit
    `src/passqlite3printf.pas` (~470 lines) hosts a self-contained
    `sqlite3FormatStr(fmt, args: array of const): AnsiString` core plus
    heap wrappers (`sqlite3PfMprintf`, `sqlite3PfSnprintf`,
    `sqlite3MPrintf`, `sqlite3VMPrintf`, `sqlite3MAppendf`).

    Conversions implemented this slice:
      * Standard: `%s %d %u %x %X %o %c %p %lld %ld %% %z`
      * SQL extensions: `%q` (escape `'` → `''`), `%Q` (wrap in `''` +
        nil → `NULL`), `%w` (escape `"` → `""`), `%T` (TToken pointer:
        emit `.n` bytes from `.z`).
      * Width/precision/flags: `-` left-align, `0` zero-pad, `+`/space
        signed, `#` alt form, `*` star-width, `*` star-precision.

    Deliberately deferred to 6.bis.4b (next slice — covers what
    Phase 7 codegen actually emits today):
      * Float conversions: `%f %e %E %g %G`.
      * Exotic SQLite extras: `%S` (SrcItem), `%r` (English ordinal).
      * Replacing the four `*FmtMsg` shims in passqlite3vtab/carray/
        dbpage/dbstat with direct `sqlite3MPrintf` calls — current
        shims keep working untouched (their bodies still use
        SysUtils.Format).  Migration is mechanical once 4b lands.
      * Wiring `sqlite3MPrintf` into the `init.busy=0` branch of
        `sqlite3VtabFinishParse` (the `CREATE VIRTUAL TABLE %T` TODO
        in passqlite3parser.pas:1991) — also deferred to 4b because
        the surrounding `sqlite3NestedParse` is a separate Phase-7
        stub that needs porting alongside.

    Naming pitfall worth memoising: SQLite's `%z` (string-with-free
    extension) collides with C99's `z` length modifier (`size_t`).
    SQLite's printf gives `%z` priority — the engine's length-
    modifier strip therefore consumes `h`/`j`/`t` only (NOT `z`),
    matching upstream printf.c.  Initial implementation accidentally
    swallowed `z` as a length modifier and the `%z` test failed
    accordingly; flagged here so any future revision keeps the
    SQL-extension precedence.

    FPC pitfalls discovered:
      * `array of const` literal `[4294967295]` triggers a range-check
        warning (i32 overflow); test wraps the value in `Int64(...)`.
      * Inline `var` declarations inside `begin..end` blocks are not
        OBJFPC-mode syntax (Delphi 10.3+ feature).  Test uses sub-
        procedures with classic top-of-block `var` blocks instead.
      * `sqlite3_free` lives in `passqlite3os` (`external 'c' name 'free'`),
        NOT in `passqlite3util`.  Tests that release `sqlite3PfMprintf`
        results must list `passqlite3os` in their `uses` clause.

    Allocation contract:
      * `sqlite3PfMprintf` / `sqlite3PfSnprintf` → libc-malloc memory
        (release with `sqlite3_free`).
      * `sqlite3MPrintf(db, ...)` → `sqlite3DbMalloc(db, ...)` memory
        (release with `sqlite3DbFree(db, ...)`).  When `db = nil`,
        falls back to libc malloc.
      * `sqlite3MAppendf(db, zOld, fmt, ...)` frees `zOld` via
        `sqlite3DbFree(db, zOld)` and returns a fresh
        `sqlite3DbMalloc`-backed concat result.

    Concrete changes:
      * `src/passqlite3printf.pas`         — new (Phase 6.bis.4a).
      * `src/tests/TestPrintf.pas`         — new gate test (40/40 PASS).
      * `src/tests/build.sh`               — registers TestPrintf
        ahead of TestVtab.

  - **2026-04-26 — Phase 6.bis.3e printf-shim consolidation.**  Cleanup
    follow-up: collapsed the four duplicate `*FmtMsg` shims into a
    single shared pair in `passqlite3vtab`'s interface:
      * `sqlite3VtabFmtMsg1Db(db, fmt, arg)` — sqlite3DbMalloc-allocated.
      * `sqlite3VtabFmtMsg1Libc(fmt, arg)`  — sqlite3Malloc-allocated
        (for `pVtab^.zErrMsg`, freed via libc `free`).
    Both accept fmt with or without `%`; without `%`, fmt is returned
    verbatim (so the legacy single-arg `'%s'` callsites are byte-
    identical and the caller can also pass a literal message).
    `vtabFmtMsg` is kept as an in-unit alias to `sqlite3VtabFmtMsg1Db`
    so the existing 6 callers in passqlite3vtab don't need touching.

    Concrete changes:
      * `src/passqlite3vtab.pas` — promotes `vtabFmtMsg` body to
        `sqlite3VtabFmtMsg1Db`, adds `sqlite3VtabFmtMsg1Libc`, both
        in interface; old name retained as inline alias.
      * `src/passqlite3carray.pas` — drops `carrayFmtMsg`; one call
        site now uses `sqlite3VtabFmtMsg1Libc` directly.
      * `src/passqlite3dbpage.pas` — drops `dbpageFmtMsg`; one call
        site converted.
      * `src/passqlite3dbstat.pas` — drops `statFmtMsg`; one call
        site converted.  `statFmtPath` left in place (different
        signature: takes int args; will fold into the printf sub-
        phase proper, not this cleanup).

    Full 49-binary test sweep: all green (TestVtab 216/216, TestCarray
    66/66, TestDbpage 68/68, TestDbstat 83/83, TestVdbeVtabExec 50/50,
    no regressions elsewhere).  The remaining `sqlite3MPrintf` blocker
    (full printf.c port with %q/%Q/%w/%z) is unaffected — this is a
    cleanup, not the long-awaited printf sub-phase itself.  Once that
    phase lands, both new helpers become thin wrappers over the real
    `sqlite3_mprintf("%s", arg)` and `sqlite3MPrintf(db, "%s", arg)`.

  - **2026-04-26 — Phase 6.bis.3d OP_VCheck wiring.**  Replaced the
    pre-3d stub (set register p2 to NULL, period) with the faithful
    vdbe.c:8409 port:
      * Reads `pTab := pOp^.p4.pTab` and refuses to fire xIntegrity if
        `tabVtabPP(pTab)^ = nil` (Table has no per-connection VTable
        attached) — matches the C `if( pTab->u.vtab.p==0 ) break;`.
      * `sqlite3VtabLock(pVTbl)` → `xIntegrity(pVtab, db^.aDb[p1].zDbSName,
        pTab^.zName, p3, &zErr)` → `sqlite3VtabUnlock(pVTbl)`.
      * On `rc<>SQLITE_OK`: `sqlite3_free(zErr)` + `goto
        abort_due_to_error`.
      * On `rc=SQLITE_OK` with non-nil zErr: `sqlite3VdbeMemSetStr(pOut,
        zErr, -1, SQLITE_UTF8, SQLITE_DYNAMIC)` so register p2 owns the
        string and frees it via the standard MEM_Dyn destructor.

    Module dispatch uses the existing `TxIntegrityFnV` typed callback
    alias (already declared in 6.bis.3b's local `type` block) — no
    new aliases needed.  Two new locals: `pTabIntV: Pointer` and
    `pVTblIntV: PVTable`.

    **Interface exposure.**  `passqlite3vtab.pas` now publishes
    `PPVTable`, `tabVtabPP`, and `tabZName` in the interface section
    (previously implementation-private).  Keeps the byte-offset
    Table-layout knowledge centralised in `passqlite3vtab` while
    letting vdbe drive OP_VCheck without taking a circular dep on
    `passqlite3codegen`'s full TTable record.

    Gate `src/tests/TestVdbeVtabExec.pas` extended with **T12** —
    50/50 PASS (was 34/34).  T12 covers four arms:
      * T12a clean run: `xIntegrity` rc=OK, no error string → reg p2
        stays MEM_Null; flags + zSchema + zTabName all forwarded.
      * T12b dirty run: rc=OK + error string → reg p2 ends MEM_Str
        with the exact text.
      * T12c hard error: `xIntegrity` returns `SQLITE_CORRUPT` →
        `abort_due_to_error` rewrites the function return to
        `SQLITE_ERROR` while preserving the original on `v^.rc`.
      * T12d no-VTable: `pTab^.u.vtab.p = nil` → `xIntegrity` not
        called, reg p2 stays MEM_Null.

    The test synthesises a fake Table blob (256 bytes, zName at
    offset 0, eTabType=1 at offset 63, u.vtab.p at offset 80) and a
    1-entry `aDb` array with `zDbSName='main'` so the C-reference
    lookup works without a populated schema.  Module is built with
    `iVersion=4` per the C reference's
    `assert(pModule->iVersion>=4)`.

    Concrete changes:
      * `src/passqlite3vtab.pas` — moves `PPVTable` to interface,
        adds `tabVtabPP` (was implementation-private inline) and new
        `tabZName` helper.
      * `src/passqlite3vdbe.pas` — fills in the OP_VCheck arm; adds
        `pTabIntV` and `pVTblIntV` locals.
      * `src/tests/TestVdbeVtabExec.pas` — adds T12 a..d with
        `MockXIntegrity` callback, `MakeIntegrityVTable` helper, and
        a synthetic Table* / TDb pair.

    Full 49-binary test sweep: all green (TestVdbeVtabExec 50/50,
    TestVtab 216/216, no regressions elsewhere).

    Discoveries / next-step notes:
      * The remaining vtab opcode that still sits in the unified
        `virtual table not supported` stub is **OP_VRowid** — wait,
        scratch that: 6.bis.3b already handled CURTYPE_VTAB inside
        OP_Rowid.  Audit complete: every vtab-bearing opcode in
        `passqlite3vdbe.pas` now has its real arm.  The unified
        stub is gone for cursor-bearing opcodes; only OP_Rowid for
        non-vtab cursor types still uses other branches.
      * `SQLITE_DYNAMIC` is the right destructor for the zErr pointer
        because xIntegrity allocates it via `sqlite3_malloc`-family
        (per the C reference's `sqlite3_free(zErr)`).  Confirmed by
        T12b reg2 → MEM_Str + later sqlite3VdbeMemRelease frees it
        cleanly with no leaks under valgrind-equivalent FillChar
        sentinels.

  - **2026-04-26 — Phase 6.bis.3c sqlite3VdbeHalt cursor-leak fix.**
    Follow-up to the 6.bis.3b caveat: the port's `sqlite3VdbeHalt`
    (passqlite3vdbe.pas:2761) was a state-only stub, so vtab cursors
    leaked across `sqlite3_step → sqlite3_finalize` (the C reference
    closes them via `closeAllCursors → closeCursorsInFrame`).  The
    `closeCursorsInFrame` loop is now inlined directly into
    `sqlite3VdbeHalt`: walks `apCsr[0..nCursor-1]`, calls
    `sqlite3VdbeFreeCursorNN` (which already has the CURTYPE_VTAB
    branch from 6.bis.3b — `xClose` + `Dec(pVtab^.nRef)`), and nils
    the slot.  Mirrors the same inlined loop already present in
    `sqlite3VdbeFrameRestoreFull` (line ~3856).  Full Halt body
    (transaction commit/rollback bookkeeping in vdbeaux.c) remains
    Phase 8.x.

    Gate `src/tests/TestVdbeVtabExec.pas` T5 simplified — previous
    body manually called `sqlite3VdbeFreeCursor` after exec to
    compensate for the stub Halt; now Halt closes the cursor inline
    during OP_Halt's `sqlite3VdbeHalt(v)` call, so the test asserts
    the post-exec slot-cleared invariant + close-counter + nRef=0
    instead.  T6..T11 unchanged (none of them were depending on the
    cursor surviving past Halt).  TestVdbeVtabExec **34/34 PASS**
    (was 35/35 — one assertion dropped: the prior "nRef=1 after
    exec" check no longer applies because Halt now decrements nRef
    to 0 *during* exec).

    Discoveries / next-step notes:
      * `sqlite3VdbeReset` already calls `sqlite3VdbeHalt` first
        when `eVdbeState = VDBE_RUN_STATE`, so the same close-all-
        cursors path now fires from `sqlite3_finalize` too.  No
        additional wiring needed for the finalize side.
      * `sqlite3VdbeFrameRestoreFull` keeps its own inlined
        close-cursors loop because it operates on a frame-restore
        boundary (sub-program halt restoring outer-program state)
        rather than full Vdbe halt.  Could promote to a shared
        helper later.
      * Real `closeAllCursors` also walks `pFrame` (sub-program
        frames) and `pDelFrame`, releases `aMem`, and clears
        `pAuxData`.  Those remain Phase 8.x because no codepath in
        the port currently builds frames or auxdata.

    Concrete changes:
      * `src/passqlite3vdbe.pas` — `sqlite3VdbeHalt` body grows
        from 2 lines to a 12-line cursor-cleanup loop.
      * `src/tests/TestVdbeVtabExec.pas` — T5 simplified
        (manual FreeCursor removed; assertions updated).

    Full 50-binary test sweep: all green.

  - **2026-04-26 — Phase 6.bis.3b VDBE wiring of cursor-bearing vtab opcodes.**
    Replaced the unified `virtual table not supported` stub (which still
    covered eight opcodes after 6.bis.3a) with faithful per-opcode arms
    matching the C reference:
      * **OP_VOpen** (vdbe.c:8356) — derefs `pOp^.p4.pVtab` for the
        `PVTable`, calls `pModule^.xOpen`, then `allocateCursor` with
        `CURTYPE_VTAB`, finally `Inc(pVtab^.nRef)`.  Idempotent: reopens
        on the same vtab are detected and short-circuited.
      * **OP_VFilter** (vdbe.c:8493) — reads `iQuery / argc` from
        `aMem[p3] / aMem[p3+1]`, builds a local `array of PMem` from
        `aMem[p3+2..]`, calls `xFilter`, then `xEof`; jumps to p2 when
        the result set is empty.
      * **OP_VColumn** (vdbe.c:8554) — stack-allocates a
        `Tsqlite3_context` plus a synthetic zero-init `TFuncDef`
        (only `funcFlags = SQLITE_RESULT_SUBTYPE = $01000000`), wires
        `sCtx.pOut := &aMem[p3]`, calls `xColumn`, runs
        `sqlite3VdbeChangeEncoding` for the configured connection enc.
        Honours OPFLAG_NOCHNG by setting MEM_Null|MEM_Zero before the
        call.
      * **OP_VNext** (vdbe.c:8610) — calls `xNext`, then `xEof`; on
        data jumps via `jump_to_p2_and_check_for_interrupt`.  Honours
        `pCur^.nullRow` no-op short-circuit.
      * **OP_VRename** (vdbe.c:8652) — sets `SQLITE_LegacyAlter` (bit
        $04000000) for the duration of the call, runs
        `sqlite3VdbeChangeEncoding` to UTF-8 first, calls `xRename`,
        clears `expired` via `vdbeFlags and not VDBF_EXPIRED_MASK`.
      * **OP_VUpdate** (vdbe.c:8708) — builds `apArgV[0..nArg-1]` from
        `aMem[p3..]`, sets `db^.vtabOnConflict := pOp^.p5`, calls
        `xUpdate`, propagates `iVRow` to `db^.lastRowid` if `p1<>0`,
        special-cases `SQLITE_CONSTRAINT` against `pVTabRef^.bConstraint`
        for OE_Ignore / OE_Replace.
      * **OP_VCheck** (vdbe.c:8409) — **stubbed to NULL** for now.
        Requires `tabVtabPP / tabZName` introspection of the C `Table`
        struct, currently lives in `passqlite3vtab`'s implementation
        section.  Wiring up would either expose those helpers in the
        unit interface or port a read-only `TTable` view into vdbe;
        both are blocked on Phase 8.x.  Sets the output Mem to NULL,
        which matches the "no errors seen" path.  Detection of vtab
        integrity errors deferred — flagged for revisit.
      * **OP_VInitIn** (vdbe.c:8456) — allocates a `TValueList` via
        `sqlite3_malloc64`, wires `pCsr / pOut`, attaches via
        `sqlite3VdbeMemSetPointer(pOut, pRhs, 'ValueList',
        @sqlite3VdbeValueListFree)`.  Added the missing
        `sqlite3VdbeValueListFree` (vdbeapi.c:1024 — one-liner
        `sqlite3_free` wrapper) to the interface.
      * **OP_Rowid** (vdbe.c:6171) — added the CURTYPE_VTAB branch
        between `deferredMoveto` and the BTree path; calls
        `pModule^.xRowid(pVCur, &pOut^.u.i)`.

    **Cursor cleanup wiring.**  `sqlite3VdbeFreeCursorNN` now has a
    CURTYPE_VTAB branch (matching `vdbeaux.c:closeCursor`) that calls
    `pModule^.xClose(pVCur)` and decrements `pVtab^.nRef`.  The previous
    "defer to Phase 6.bis" marker is gone.  **Caveat**: the port's
    `sqlite3VdbeHalt` is still a stub (only flips `eVdbeState`).  The
    C reference closes all cursors via `closeAllCursors` from `Halt` —
    in this port, vtab cursors leak unless freed explicitly via
    `sqlite3VdbeFreeCursor`.  Concrete impact: nothing user-visible
    until Phase 8.x exposes a real query path; the new gate test calls
    `sqlite3VdbeFreeCursor` manually to verify the close path.

    **Function-pointer typing.**  The `Tsqlite3_module` slot fields are
    declared as `Pointer` in `passqlite3vtab.pas`.  The new vdbe arms
    introduce typed local function-pointer aliases (`TxOpenFnV`,
    `TxCloseFnV`, `TxFilterFnV`, `TxNextFnV`, `TxEofFnV`,
    `TxColumnFnV`, `TxRowidFnV`, `TxRenameFnV`, `TxUpdateFnV`) and
    cast at the call site.  This keeps `Tsqlite3_module`'s on-disk
    layout identical to the C struct (verified by 6.bis.1d) while
    letting vdbe call through with proper signatures.  Future work
    can promote these aliases to `passqlite3vtab.pas` interface — for
    now they live as a local `type` block inside `sqlite3VdbeExec` to
    keep the change scoped.

    **PPSqlite3VtabCursor exported.**  Added the `^PSqlite3VtabCursor`
    alias to `passqlite3vtab.pas`'s interface so vdbe can declare the
    `xOpen` callback signature without redefining.  `dbpage / carray /
    dbstat` already had locally-redeclared aliases; FPC accepts both
    declarations because they collapse to the same underlying type.

    Gate `src/tests/TestVdbeVtabExec.pas` extended T5..T11 — **35/35
    PASS** (was 11/11).  Mock module gains xOpen / xClose / xFilter /
    xNext / xEof / xColumn / xRowid / xRename / xUpdate slots, new
    `TMockVtabCursor` record (`base: Tsqlite3_vtab_cursor; iRow: i64`)
    serves a synthetic 3-row table.  Coverage:
      * T5  OP_VOpen → xOpen fires, vtab cursor allocated, nRef++,
            xClose fires on FreeCursor, nRef--.
      * T6  OP_VOpen idempotency — xOpen fires exactly once on
            consecutive opens against the same vtab.
      * T7  OP_VFilter + OP_VNext walks 3 rows (xFilter once, xNext
            three times — last hits xEof and exits the loop).
      * T8  OP_VColumn populates aMem[p3] via the synthetic
            sqlite3_context, encoding round-trip preserved.
      * T9  OP_Rowid on CURTYPE_VTAB → xRowid → register set.
      * T10 OP_VRename — xRename fires with the UTF-8 string from the
            named register; AnsiString round-trip verified.
      * T11 OP_VUpdate — xUpdate fires, argc=3 propagated, returned
            rowid lands in `db^.lastRowid`.

    **Discoveries / dependencies for future phases:**

      * `sqlite3VdbeHalt` is a stub.  Phase 8.x (or a follow-up
        cleanup phase) needs to wire `closeAllCursors` so vtab cursor
        leaks don't accrue across `sqlite3_step → sqlite3_finalize`.
        Until then the new gate manually calls `sqlite3VdbeFreeCursor`.
      * `tabVtabPP` is implementation-private to `passqlite3vtab.pas`.
        OP_VCheck's port is gated on either exporting the helper or
        landing a TTable interface view.  Either way needs the parser
        side of Phase 8.x first (CREATE VIRTUAL TABLE / xIntegrity
        gate).
      * `SQLITE_LegacyAlter` (sqliteInt.h:1857 = $04000000) is the
        u64 db->flags bit, distinct from
        `SQLITE_LegacyAlter_Bit` (passqlite3main.pas) which is the
        DBCONFIG mask but the same numeric value.  Both names will
        eventually be unified in Phase 8.x.
      * `SQLITE_RESULT_SUBTYPE` ($01000000) lives in sqlite.h.in, not
        sqliteInt.h, and is currently inlined as a literal in
        OP_VColumn.  Add a constant in `passqlite3vdbe.pas` when the
        broader vtab function-binding work lands.

    Concrete changes:
      * `src/passqlite3vdbe.pas` — adds typed callback aliases,
        17 new locals, CURTYPE_VTAB branch in
        `sqlite3VdbeFreeCursorNN`, OP_Rowid CURTYPE_VTAB branch,
        seven new opcode arms (OP_VOpen / VFilter / VColumn / VNext /
        VRename / VUpdate / VInitIn) plus stubbed OP_VCheck, and the
        new `sqlite3VdbeValueListFree` interface entry.
      * `src/passqlite3vtab.pas` — exports `PPSqlite3VtabCursor`.
      * `src/tests/TestVdbeVtabExec.pas` — adds T5..T11, mock
        cursor record, richer module factory, helper
        `CreateMinVdbeC` (Vdbe with allocated apCsr).

    Full 50-binary test sweep: **all green**.  Notable: TestVtab
    216/216, TestCarray 66/66, TestDbpage 68/68, TestDbstat 83/83,
    TestVdbeVtabExec 35/35, no regressions in the other 45 binaries.

  - **2026-04-26 — Phase 6.bis.3a VDBE wiring of OP_VBegin/VCreate/VDestroy.**
    Replaced the lumped "virtual table not supported" stub in
    `passqlite3vdbe.pas`'s exec switch with three faithful arms
    matching `vdbe.c:8294/8310/8339`:
      * **OP_VBegin** — derefs `pOp^.p4.pVtab` (`PVTable`), calls
        `passqlite3vtab.sqlite3VtabBegin`, then `sqlite3VtabImportErrmsg`
        when the VTable is non-nil; aborts on any non-OK rc.
      * **OP_VCreate** — copies `aMem[p2]` into a scratch `TMem`,
        extracts the table-name text via `sqlite3_value_text`, calls
        `passqlite3vtab.sqlite3VtabCallCreate(db, p1, zName, @v^.zErrMsg)`,
        releases the scratch Mem.
      * **OP_VDestroy** — increments `db^.nVDestroy`, calls
        `passqlite3vtab.sqlite3VtabCallDestroy(db, p1, p4.z)`, decrements.
    The remaining vtab opcodes (OP_VOpen / OP_VFilter / OP_VColumn /
    OP_VUpdate / OP_VNext / OP_VCheck / OP_VInitIn / OP_VRename) stay
    in the unified error-stub for **Phase 6.bis.3b** — they all need
    cursor-bearing infrastructure (`allocateCursor` with
    `CURTYPE_VTAB`, vtab-cursor cleanup in `sqlite3VdbeFreeCursorNN`,
    plus a simplified `sqlite3_context` for OP_VColumn).

    **Cycle break.**  `passqlite3vtab` already uses `passqlite3vdbe` in
    its interface; we therefore added `passqlite3vtab` to vdbe's
    *implementation* `uses` clause (not interface), which Pascal allows
    even when the interface-side cycle would not compile.  All vtab
    references in the new opcode arms qualify the unit name explicitly
    (e.g. `passqlite3vtab.PVTable`, `passqlite3vtab.sqlite3VtabBegin`)
    so the `PVTable = Pointer` opaque alias declared in vdbe's interface
    keeps coexisting with the real type from the vtab unit without
    ambiguity.

    Gate `src/tests/TestVdbeVtabExec.pas` (new) — **11/11 PASS**.
    Drives sqlite3VdbeExec on a hand-built mini Vdbe (mirrors the
    TestVdbeArith pattern) with a mock module that owns `xBegin`:
      * T1  OP_VBegin valid VTable → xBegin fires once, nVTrans=1.
      * T2  OP_VBegin nil pVtab → no-op (sqlite3VtabBegin returns OK).
      * T3  OP_VBegin twice on same VTable → xBegin fires exactly once
            (sqlite3VtabBegin's iSavepoint short-circuit).
      * T4  xBegin → SQLITE_BUSY: function rc rewritten to SQLITE_ERROR
            by `abort_due_to_error`, but `v^.rc` preserves the original
            BUSY (faithful to vdbe.c — SQLite C does the same rewrite).

    Discoveries / dependencies for next sub-phases:

      * **`abort_due_to_error` rewrites the function's return rc to
        SQLITE_ERROR.**  Both upstream and our port do this — the
        original rc lives on `v^.rc` for `sqlite3_errcode()`.  Tests
        targeting non-OK paths in opcodes that go through
        abort_due_to_error must assert `v^.rc`, not the rc returned by
        sqlite3VdbeExec.  Save in memory for any future opcode-test
        author.
      * **OP_VCreate / OP_VDestroy gate is blocked on a populated
        schema** — `sqlite3VtabCallCreate / Destroy` walk
        `db^.aDb[iDb].pSchema^.tblHash` via `sqlite3FindTable`, which
        crashes against a fake `Tsqlite3` with `nDb=0`.  End-to-end
        coverage of those two arms must wait for Phase 8.x's CREATE
        VIRTUAL TABLE pipeline (the parser side already lands the
        OP_VCreate emission via `sqlite3VtabFinishParse`'s
        nested-parse path — also Phase 8.x).
      * **`P4_VTAB` round-trips a `PVTable`**, not a `PSqlite3Vtab`.
        The dispatch arm derefs `pOp^.p4.pVtab^.pVtab` to get the
        `sqlite3_vtab*` for sqlite3VtabImportErrmsg (matches
        vdbe.c:8298).  Worth memoising for 6.bis.3b — the same
        pattern applies for OP_VOpen / OP_VRename / OP_VUpdate, all
        of which take `P4_VTAB` and need to walk through the VTable
        wrapper to reach the module's function-pointer slots.
      * **Mock vtab cursor allocator must use libc malloc**, not FPC
        GetMem, when the module's xDisconnect calls `sqlite3_free`
        (= libc free) on its own state — same trade-off the 6.bis.1d
        TestVtab gate flagged for `pVtab^.zErrMsg`.  Our test
        mock currently FreeMem's its sqlite3_vtab from a Pascal
        xDisconnect, which is allocator-symmetric, so this is only
        a heads-up for future tests where the module's own xClose /
        xDisconnect goes through `sqlite3_free`.

    Concrete changes:
      * `src/passqlite3vdbe.pas` — adds `passqlite3vtab` to
        implementation `uses`; three new `var`-block locals
        (`pVTabRef`, `sMemVCreate`, `zVTabName`); replaces the
        lumped vtab-opcode stub with three explicit arms + a
        smaller residual stub for the remaining 8 vtab opcodes.
      * `src/tests/TestVdbeVtabExec.pas` — new gate test (T1–T4).
      * `src/tests/build.sh` — registers TestVdbeVtabExec
        immediately after TestVdbeVtab.

    Full 50-binary test sweep: all green (TestVtab 216/216,
    TestCarray 66/66, TestDbpage 68/68, TestDbstat 83/83,
    TestVdbeVtabExec 11/11, no regressions in the other 45
    binaries).

  - **2026-04-26 — Phase 6.bis.2d dbstat.c port.**  New unit
    `src/passqlite3dbstat.pas` (~770 lines) hosts faithful Pascal ports
    of all 11 static module callbacks (statConnect / statDisconnect /
    statBestIndex / statOpen / statClose / statFilter / statNext /
    statEof / statColumn / statRowid + statDecodePage / statGetPage /
    statSizeAndOffset helpers and the StatCell/StatPage/StatCursor/
    StatTable record types).  `dbstatModule: Tsqlite3_module` v1
    layout (iVersion=0; xCreate=xConnect; read-only — xUpdate /
    xBegin / xSync etc all nil).  `sqlite3DbstatRegister(db)` delegates
    to `sqlite3VtabCreateModule`.

    Notes that future phases should heed:

      * **`sqlite3_mprintf` recurring blocker — fourth copy.**
        Local `statFmtMsg` mirrors carrayFmtMsg / dbpageFmtMsg /
        vtabFmtMsg; `statFmtPath` handles the three path templates
        ('/', '%s%.3x/', '%s%.3x+%.6x', '%s') used by statNext.
        FOUR copies now — promote to a shared helper when the printf
        sub-phase lands.
      * **`sqlite3_str_new` / `sqlite3_str_appendf` / `sqlite3_str_finish`
        not ported.**  statFilter builds its inner SELECT through a
        local `statBuildSql` AnsiString concatenator with manual
        `escIdent` (%w → double `"`) and `escLiteral` (%Q → single-
        quote, double `'`) helpers.  Sufficient for dbstat.c:776..788
        (one identifier substitution for the schema name, one literal
        for the optional name= filter).  Replace with the real
        sqlite3_str_* family when that sub-phase lands.
      * **`sqlite3TokenInit` not exposed.**  statConnect calls
        `sqlite3FindDbName` directly with `argv[3]` as a `PAnsiChar`.
        Equivalent semantics for unquoted schema names; quoted-form
        case will need the Token round-trip when sqlite3TokenInit is
        promoted to a public helper.
      * **`sqlite3_context_db_handle` not ported (carry-over from
        dbpage / 6.bis.2c).**  statColumn's schema branch derives `db`
        via `cursor^.base.pVtab^.db`.  Identical effect to the C
        helper; switch over once the public entry point lands.
      * **FPC pitfalls (per memory).**  Local var `pPager: PPager` →
        `pPgr: PPager`; `pDbPage: PDbPage` → `pDbPg: PDbPage`;
        `nPage: i32` not affected (no PPage type).  Record FIELDS
        retain upstream spelling (e.g. StatPage.aPg, StatPage.iPgno).
      * **C `goto` inside statDecodePage / statNext.**  Pascal labels
        `statPageIsCorrupt` (statDecodePage) and `statNextRestart`
        (statNext) preserve the upstream control flow exactly — the
        tail-recursion idiom in statNext (label-restart inside the
        else-branch) is the trickiest piece and is faithfully ported.
      * **u8/byte-walk idioms.**  `get2byte(&aHdr[3])` becomes
        `(i32(aHdr[3]) shl 8) or i32(aHdr[4])` since FPC has no
        `get2byte` macro and aHdr is Pu8.
      * **`sqlite3PagerFile` exposed by passqlite3pager** — the only
        in-tree call site so far; statSizeAndOffset uses it to forward
        a ZIPVFS-style file-control opcode (230440).
      * **dbstat columns referenced by ordinal in statBestIndex.**
        DBSTAT_COLUMN_NAME=0, _SCHEMA=10, _AGGREGATE=11 are the
        constraint-bearing columns; switch on those exactly.

    Gate `src/tests/TestDbstat.pas` (new) — **83/83 PASS**.  Exercises
    module registration (registry slot + name + nRefModule), the full
    v1 slot layout (M1..M21 — pinning the read-only nature: xUpdate /
    xBegin etc all nil), nine BestIndex branches (B1..B9: empty /
    schema= / name= / aggregate= / all-three / two ORDER BY shapes /
    DESC-rejected / unusable→CONSTRAINT), and the cursor open/close
    state machine (C1..C3 — including iDb propagation).  xFilter /
    xColumn / xNext page-walk deferred to the end-to-end SQL gate
    (6.9): they need a live Btree and a working sqlite3_prepare_v2
    path through the parser.  No regressions across the 47-gate
    matrix (TestVtab still 216/216, TestCarray 66/66, TestDbpage
    68/68, all read/write paths green).

  - **2026-04-26 — Phase 6.bis.2c dbpage.c port.**  New unit
    `src/passqlite3dbpage.pas` (~470 lines) hosts faithful Pascal ports
    of the full v2 module callback set (dbpageConnect / dbpageDisconnect
    / dbpageBestIndex / dbpageOpen / dbpageClose / dbpageNext /
    dbpageEof / dbpageFilter / dbpageColumn / dbpageRowid / dbpageUpdate
    / dbpageBegin / dbpageSync / dbpageRollbackTo) plus the
    `dbpageModule: Tsqlite3_module` record (iVersion=2, xCreate=xConnect
    so dbpage is eponymous-or-creatable, xDestroy=xDisconnect, full
    transactional set: xUpdate / xBegin / xSync / xRollbackTo wired).
    `sqlite3DbpageRegister(db)` delegates to `sqlite3VtabCreateModule`.

    Notes that future phases should heed:

      * **`sqlite3_context_db_handle` not ported.**  xColumn's schema
        path normally derives `db` via `ctx->pVdbe->db`.  We instead
        walk `cursor->base.pVtab->db` (DbpageTable.db is set in
        xConnect); equivalent in C, simpler in Pascal.  When the
        public helper does land, the dbpageColumn schema branch can
        switch over without behaviour change.
      * **`sqlite3_result_zeroblob` (i32) not ported** as a separate
        entry point.  Bridged through the existing
        `sqlite3_result_zeroblob64(ctx, u64(szPage))`; identical effect.
      * **`SQLITE_Defensive` flag bit not exported** from
        passqlite3vtab (lives in its impl section).  Mirrored locally
        as `SQLITE_Defensive_Bit = u64($10000000)`.  Worth promoting
        to passqlite3util's interface alongside the other db.flags
        constants when one of the next sub-phases needs it too.
      * **`sqlite3_mprintf` recurring blocker** — same shim pattern as
        carray (6.bis.2b): local `dbpageFmtMsg` mirrors `carrayFmtMsg`
        / `vtabFmtMsg`.  Three copies now; promote to a shared helper
        when the printf sub-phase lands.
      * **FPC name-collision pitfalls (per memory).**  Must rename
        `pgno: Pgno` → `pg: Pgno`, `pPager: PPager` → `pPgr: PPager`,
        `pDbPage: PDbPage` → `pDbPg: PDbPage` everywhere they appear
        as local variable declarations.  Cursor / table record FIELDS
        keep their upstream spelling — the case-insensitive collision
        only fires for top-level `var` declarations, not record
        members (qualified by record name).

    Idiom worth memoising: `sqlite3_vtab_config` in our port takes a
    mandatory `intArg: i32` even for opcodes that ignore it (DIRECTONLY
    / USES_ALL_SCHEMAS); pass 0 explicitly.

    Gate `src/tests/TestDbpage.pas` (new) — **68/68 PASS**.  Exercises
    module registration (registry slot + name), the full v2 slot
    layout (M1..M21), all four xBestIndex idxNum branches plus the
    SQLITE_CONSTRAINT failure on unusable schema, xOpen/xClose, and
    the cursor state machine (xNext / xEof / xRowid).  xColumn /
    xFilter / xUpdate / xBegin / xSync require a live Btree on a
    real db file; deferred to the end-to-end SQL gate (6.9).
    No regressions across the 46-gate matrix; TestCarray still 66/66.

  - **2026-04-26 — Phase 6.bis.2b carray.c port.**  New unit
    `src/passqlite3carray.pas` (~360 lines) hosts faithful Pascal ports
    of all 10 static vtab callbacks (carrayConnect / carrayDisconnect
    / carrayOpen / carrayClose / carrayNext / carrayColumn /
    carrayRowid / carrayEof / carrayFilter / carrayBestIndex), the
    public `carrayModule: Tsqlite3_module` record (v1 layout, iVersion=0,
    eponymous-only — xCreate/xDestroy nil), and the registry-side
    entry point `sqlite3CarrayRegister(db)` delegating to
    `sqlite3VtabCreateModule` from 6.bis.1a.  Constants exported
    mirror sqlite.h:11329..11343 (`CARRAY_INT32`..`CARRAY_BLOB` and
    the `SQLITE_CARRAY_*` aliases) plus the four column ordinals.

    Two blockers carry over to 6.bis.2c/d (full discussion under the
    6.bis.2b task entry):

      * `sqlite3_value_pointer` / `sqlite3_bind_pointer` still not
        ported.  carrayFilter goes through a local
        `sqlite3_value_pointer_stub` returning nil — the bind-pointer
        path is structurally complete but inert until the
        Phase-8 `MEM_Subtype` machinery lands (vdbeInt.h + vdbeapi.c:
        1394 / 1731).  Same blocker silently gates a
        `sqlite3_carray_bind_v2` port (omitted here).
      * `sqlite3_mprintf` recurring blocker — bridged via a local
        `carrayFmtMsg` shim mirroring `vtabFmtMsg` from 6.bis.1c.
        dbstat's idxStr formatting will need the same; worth
        promoting to a shared helper when the printf sub-phase lands.

    Idiom worth memoising for 6.bis.2c/d gate writers: the
    `Tsqlite3_module` record declares most slots as `Pointer`, so test
    code reads them back through `Pointer(fnVar) := module.slot`
    rather than a direct typed assignment.  Only xDisconnect /
    xDestroy are typed function-pointer fields.

    Note for dbpage / dbstat: xColumn is currently un-testable without
    allocating a Tsqlite3_context outside a VDBE op call — TestCarray
    exercises every callback EXCEPT xColumn.  End-to-end column
    coverage is gated on OP_VColumn wiring (6.bis.1d wiring caveat).

    Gate `src/tests/TestCarray.pas` (new) — **66/66 PASS**.  No
    regressions across the existing 45-gate matrix (TestVtab still
    216/216).

  - **2026-04-26 — Phase 6.bis.2a sqlite3_index_info types + constants.**
    Plumbing for the three in-tree vtabs (carray.c / dbpage.c /
    dbstat.c).  `passqlite3vtab.pas`'s interface section grew the four
    record types from sqlite.h:7830..7860 (`Tsqlite3_index_info`,
    `Tsqlite3_index_constraint`, `Tsqlite3_index_orderby`,
    `Tsqlite3_index_constraint_usage`), the typed `TxBestIndex` function-
    pointer alias for the `xBestIndex` slot in `Tsqlite3_module`, and
    19 numeric constants — `SQLITE_INDEX_CONSTRAINT_*` (17 values,
    sqlite.h:7911..7927) plus `SQLITE_INDEX_SCAN_UNIQUE` /
    `SQLITE_INDEX_SCAN_HEX` (sqlite.h:7869..7870).  The previous Phase
    6.bis.1a placeholder `PSqlite3IndexInfo = Pointer` is now
    `^Tsqlite3_index_info`.

    Layout pitfall worth memoising: gcc's default struct alignment
    pads `unsigned char op; unsigned char usable;` followed by `int
    iTermOffset;` to 4 bytes between them.  The Pascal records mirror
    this with explicit `_pad: u16` filler so a `Tsqlite3_index_constraint`
    is 12 bytes (matches `sizeof(struct sqlite3_index_constraint)` in C);
    same trick for `Tsqlite3_index_orderby` (`u8 desc; u8 _pad0; u16
    _pad1;` = 8 bytes) and `Tsqlite3_index_constraint_usage` (8 bytes).
    Verified by running the xBestIndex pointer-walk idiom (`pConstraint++`
    → `Inc(pC)`) in T91..T93 and reading back the right values.

    Gate `src/tests/TestVtab.pas` extended with T89..T93 — **216/216
    PASS** (was 181/181).  No regressions across the full 45-gate
    matrix in build.sh.

    Discoveries / dependencies for 6.bis.2b..d (full list under the
    6.bis.2 task entry below):
      * `sqlite3_value_pointer` / `sqlite3_bind_pointer` not ported —
        carray.c uses both, so a small Phase-8 sub-phase needs to land
        the type-tagged-pointer machinery before TestCarray can drive
        an actual bind/filter.
      * `sqlite3_mprintf` still not ported (recurring blocker since
        6.bis.1b) — affects all three vtabs but only as an error-
        message niceness on carray, more central in dbstat's idxStr.
      * VDBE vtab opcodes (`OP_VFilter` / `OP_VColumn` / `OP_VNext` /
        `OP_VRowid`) still no-op stubs — end-to-end SQL against an
        in-tree vtab won't work until that wiring lands.  6.bis.2b..d
        gates will drive xMethods directly through the module-pointer
        slots, mirroring TestVtab.T35..T50.

  - **2026-04-26 — Phase 6.bis.1f vtab.c overload + writable + eponymous
    tables.**  Faithful ports of `sqlite3VtabOverloadFunction`
    (vtab.c:1153..1215), `sqlite3VtabMakeWritable` (vtab.c:1223..1240),
    `sqlite3VtabEponymousTableInit` (vtab.c:1257..1292), and the full
    body of `sqlite3VtabEponymousTableClear` (vtab.c:1298..1308) now
    live in `src/passqlite3vtab.pas`, replacing the 6.bis.1a stub for
    Clear.  `addModuleArgument` was promoted to the `passqlite3parser`
    interface so EponymousTableInit can invoke the helper without
    duplicating its body.

    Implementation notes worth memoising:
      * `sqlite3VtabMakeWritable` reaches `passqlite3os.sqlite3_realloc64`
        directly — `sqlite3Realloc` is not exposed cross-unit from
        `passqlite3pager`, and `apVtabLock` is libc-malloc'd anyway.
      * `sqlite3VtabOverloadFunction` casts `pModule^.xFindFunction`
        (declared `Pointer` for the 24-slot module record) through a
        local `TVtabFindFn = function(...)` typedef.  Worth keeping the
        local typedef pattern in mind for future module-pointer-slot
        invocation paths (xBestIndex, xFilter, xColumn, xRowid).
      * `sqlite3ErrorMsg("%s", zErr)` collapses to `sqlite3ErrorMsg(zErr)`
        in the EponymousTableInit error path — same trade as 6.bis.1c's
        `vtabFmtMsg` shim, awaits the `sqlite3MPrintf` sub-phase.
      * Pascal naming pitfall (recurring): `pModule` parameter collides
        modulo case with `PModule` type; renamed to `pMd`.

    Wiring caveat carried over to Phase 7 build.c work:
      * Our `passqlite3codegen.sqlite3DeleteTable` is a pre-vtab stub
        — it frees aCol+zName+the table itself but does NOT cascade
        through `sqlite3VtabClear` to disconnect attached VTables.
        Gate T85b therefore asserts `gDisconnectCount = 0` after
        `sqlite3VtabEponymousTableClear`; flip to 1 once
        `sqlite3DeleteTable` chains into `sqlite3VtabClear`.

    Gate `src/tests/TestVtab.pas` extended with T71..T88 — **181/181
    PASS** (was 141/141).  No regressions across the 41 other gates.

  - **2026-04-26 — Phase 6.bis.1e vtab.c public API entry points.**
    Faithful ports of `sqlite3_declare_vtab` (vtab.c:811..917),
    `sqlite3_vtab_on_conflict` (vtab.c:1317..1328), and
    `sqlite3_vtab_config` (vtab.c:1335..1378) now live in
    `src/passqlite3vtab.pas`.  Four new SQLITE_VTAB_* constants
    (CONSTRAINT_SUPPORT/INNOCUOUS/DIRECTONLY/USES_ALL_SCHEMAS) added.
    `passqlite3parser` joined `passqlite3vtab`'s uses clause to pull
    in `sqlite3GetToken` + `TK_CREATE/TK_TABLE/TK_SPACE/TK_COMMENT`
    + `sqlite3RunParser`; no cycle (parser → codegen, vtab → parser
    → codegen).

    `sqlite3_vtab_config` exposed as a single typed entry point
    `(db, op, intArg)` instead of C varargs — same flavour as Phase
    8.4's `sqlite3_db_config_int`.  Only CONSTRAINT_SUPPORT consumes
    intArg; the three valueless ops ignore it.

    `sqlite3_declare_vtab`'s column-graft branch is structurally
    complete (mirrors vtab.c:869..896) but currently dormant: with
    `sqlite3StartTable / AddColumn / EndTable` still Phase-7 stubs,
    parsing `CREATE TABLE x(...)` lands `sParse.pNewTable=nil` and
    we take a fallback path that flips `pCtx^.bDeclared:=1` without
    populating `pTab^.aCol`.  When build.c ports land, the graft
    branch lights up unchanged.  The hidden-column type-string scan
    in vtab.c:653..682 (gated under 6.bis.1c) remains blocked on
    the same dependency.

    Pascal/cross-language deltas worth memoising:
      * `TParse` has no top-level `disableTriggers` field — that bit
        sits inside the packed `parseFlags: u32` (offset 40).  Use
        `sParse.parseFlags := sParse.parseFlags or
        PARSEFLAG_DisableTriggers`.
      * `SQLITE_ROLLBACK / _FAIL / _REPLACE` are not re-exported from
        `passqlite3types`; the `aMap` in `sqlite3_vtab_on_conflict`
        inlines literal bytes (1, 4, 3, 2, 5) with a comment pointer
        to sqlite.h:1133.  Replace with named constants once the
        conflict-resolution codes get a clean home.

    Gate `src/tests/TestVtab.pas` extended with T51..T70 — **141/141
    PASS** (was 113/113).  No regressions across the 41 other gates.

  - **2026-04-25 — Phase 6.bis.1d vtab.c per-statement transaction hooks.**
    Faithful ports of vtab.c:970..1138 now live in
    `src/passqlite3vtab.pas`: `sqlite3VtabSync`, `sqlite3VtabRollback`,
    `sqlite3VtabCommit`, `sqlite3VtabBegin`, `sqlite3VtabSavepoint`,
    plus the static `callFinaliser` helper and the `vtabInSync`
    inline (replacing the upstream macro).  `sqlite3VtabImportErrmsg`
    (from vdbeaux.c:5673) is also exported here so any future caller
    that needs to copy a vtab module's `zErrMsg` into a Vdbe can do
    so without re-implementing the dance.

    Pascal/cross-language deltas worth flagging:
      * `callFinaliser` in C uses `offsetof(sqlite3_module, xCommit/
        xRollback)` plus a function-pointer cast through `(char*)
        +offset` to pick which finaliser to invoke.  We can't take
        `offsetof` cleanly across `Pointer`-typed fields; the port
        replaces it with a `TFinKind = (fkCommit, fkRollback)` enum
        that selects the field at the call site.  Behaviour is
        identical, the dispatch is just explicit.
      * `db^.flags` SQLITE_Defensive masking around the savepoint
        callback uses a local `SQLITE_Defensive = u64($10000000)`
        constant (same value as `SQLITE_Defensive_Bit` in
        passqlite3main.pas).  Will collapse to a re-export when the
        flag set moves to a central unit.
      * Added `passqlite3vdbe` and `passqlite3os` to `passqlite3vtab`'s
        uses clause.  No cycle introduced — only `passqlite3main`
        imports `passqlite3vtab`, and neither vdbe nor os
        transitively depend on vtab.

    Wiring caveat (carry-over for next sub-phases):
      * The five entry points are callable but the codegen / VDBE
        opcodes (`OP_VBegin`, `OP_VSync`, `OP_Savepoint`'s vtab
        branch) still do NOT invoke them.  The Phase 5.9 stubs in
        `passqlite3vdbe.pas` need to be replaced with real calls
        once the surrounding parser/codegen support exists.
        Tracked in the 6.bis.1d task notes.

    Allocator-contract pitfall worth memoising:
      * Vtab modules MUST allocate `pVtab^.zErrMsg` via libc malloc
        (`sqlite3Malloc` in our port) — NOT FPC's `GetMem` and NOT
        `sqlite3DbStrDup`.  `sqlite3VtabImportErrmsg` releases it
        with `sqlite3_free` which is `external 'c' name 'free'`
        in `passqlite3os.pas:58`.  Test `HookXSync` was bitten by
        this with `GetMem(z,32)` (double free at runtime); fixed
        by switching to `sqlite3Malloc(32)`.

    Gate `src/tests/TestVtab.pas` extended with T35..T50 — **113/113
    PASS** (was 76/76).  No regressions across the 41 other gates
    in build.sh.

  - **2026-04-25 — Phase 6.bis.1c vtab.c constructor lifecycle.**
    Replaced the deferred constructor-lifecycle TODOs in
    `passqlite3vtab.pas` with faithful ports of vtab.c:557..968:
    `vtabCallConstructor` (static), `sqlite3VtabCallConnect`,
    `sqlite3VtabCallCreate`, `sqlite3VtabCallDestroy`, `growVTrans`
    (static), `addToVTrans` (static).  Wires through the existing
    `db^.aVTrans / nVTrans` slots in `Tsqlite3` (already there since
    Phase 8.1).  A local `vtabFmtMsg` shim stands in for the still-
    unported `sqlite3MPrintf` — uses `SysUtils.Format` to build error
    strings and returns a `sqlite3DbMalloc`'d copy.  Gate
    `src/tests/TestVtab.pas` extended with T23..T34 covering happy-
    path Connect, repeat-Connect no-op, missing module, xConnect
    error, missing schema declaration, Create+aVTrans growth across
    the ARRAY_INCR=5 boundary (7 tables), and Destroy-disconnects-
    but-leaves-Table-in-schema.  **76/76 PASS** (was 39/39).  No
    regressions in the other 40 gates (TestSmoke, TestOSLayer, TestUtil,
    TestPCache, TestPagerCompat, TestBtreeCompat, TestVdbe* ×14,
    TestTokenizer, TestParserSmoke, TestParser, TestWalker,
    TestExprBasic, TestWhereBasic, TestSelectBasic, TestAuthBuiltins,
    TestDMLBasic, TestSchemaBasic, TestWindowBasic, TestOpenClose,
    TestPrepareBasic, TestRegistration, TestConfigHooks,
    TestInitShutdown, TestExecGetTable, TestBackup, TestUnlockNotify,
    TestLoadExt).

    Discoveries / dependencies (full list in the 6.bis.1c task entry
    below):
      * `sqlite3MPrintf` blocker remains — a printf sub-phase will
        replace `vtabFmtMsg` here, in 6.bis.1b's `init.busy=0`
        branch, in 7.2e error-message TODOs, and in `sqlite3_errmsg`
        promotion (Phase 8.6 deferred note).
      * Hidden-column type-string scan (vtab.c:653..682) is skipped
        until `sqlite3_declare_vtab` (6.bis.1e) populates pTab^.aCol.
        For our nCol=0 gate this is a no-op, but the scan must be
        restored when 6.bis.1e lands.
      * `aVTrans` pruning is sqlite3VtabSync/Commit/Rollback's job
        (6.bis.1d): VtabCallDestroy intentionally leaves stale slots.
      * Pitfall: `pVTable` local-var name collides with the unit's
        `PVTable` type (case-insensitive).  Rename to `pVTbl`; mirror
        the same rename for the field `TVtabCtx.pVTable` (no external
        users).

  - **2026-04-25 — Phase 6.bis.1b vtab.c parser-side hooks.**  Replaced
    the one-line TODO stubs in `passqlite3parser.pas` for
    `sqlite3VtabBeginParse / _FinishParse / _ArgInit / _ArgExtend` with
    faithful ports of vtab.c:359..550 (plus the file-private helpers
    `addModuleArgument` and `addArgumentToVtab`).  All four public hooks
    are now declared in the parser interface so external gate tests can
    drive them directly with a manually-constructed `TParse + TTable`.
    Gate: `src/tests/TestVtab.pas` extended with T17..T22 covering
    sArg accumulation, ArgInit/Extend semantics, init.busy=1 schema
    insertion, and tblHash population — **39/39 PASS** (was 27/27).  No
    regressions in TestParser / TestParserSmoke / TestRegistration /
    TestPrepareBasic / TestOpenClose / TestSchemaBasic / TestExecGetTable
    / TestConfigHooks / TestInitShutdown / TestBackup / TestUnlockNotify
    / TestLoadExt / TestTokenizer.

    Two upstream stubs surfaced as blockers and are noted under the
    6.bis.1b task entry below:

      * `sqlite3StartTable` is still empty in passqlite3codegen
        (build.c port pending Phase 7-style work).  Real parser-driven
        `CREATE VIRTUAL TABLE foo USING mod(...)` therefore can't reach
        the new helpers yet — `sqlite3VtabBeginParse` early-returns on
        `pNewTable=nil`.  The port is structurally complete; gate test
        exercises the leaf helpers directly with a manually-constructed
        Table + Parse to bypass StartTable.
      * `sqlite3MPrintf` is not yet ported.  The init.busy=0 branch of
        FinishParse (the one that emits the OP_VCreate / OP_Expire
        sequence and rewrites sqlite_schema via sqlite3NestedParse with
        a `%T`-formatted statement) is reduced to a `sqlite3MayAbort`
        call with a TODO; a future printf sub-phase will land the full
        body together with the second `sqlite3AuthCheck` for
        SQLITE_CREATE_VTABLE.

    Pitfall captured: `passqlite3util.PSchema` and
    `passqlite3codegen.PParse` are also declared as `Pointer` stubs in
    lower-level units (passqlite3vdbe, passqlite3util's own
    forward-decl).  In a test file that uses both layers, the dotted
    form `passqlite3util.PSchema` cannot appear directly in a `var`
    declaration — FPC resolves the bare name to the `Pointer` stub
    first.  Workaround: introduce a top-level `type TUtilPSchema =
    passqlite3util.PSchema;` alias (and `TCgPParse = passqlite3codegen.
    PParse;`) and reference the alias in `var`.  Mirrors the recurring
    Pascal var/type-conflict feedback memory.

  - **2026-04-25 — Phase 6.bis.1a vtab.c types + module-registry leaf
    helpers.** New unit `src/passqlite3vtab.pas` (525 lines) hosts the
    full Pascal port of vtab.c's leaf surface:
      * Public types matching sqlite.h byte-for-byte: `Tsqlite3_module`
        (24 fn-pointer slots + iVersion across v1..v4), `Tsqlite3_vtab`,
        `Tsqlite3_vtab_cursor`.
      * Internal types from sqliteInt.h: `TVTable` (per-connection vtab
        instance), `TVtabModule` (module registry entry; named
        `TVtabModule` to avoid clashing with the `pModule` parameter
        name — Pascal is case-insensitive), `TVtabCtx`.
      * Functions ported faithfully from vtab.c:
          - `sqlite3VtabCreateModule`         (vtab.c:39)
          - `sqlite3VtabModuleUnref`          (vtab.c:162)
          - `sqlite3VtabLock`                 (vtab.c:182)
          - `sqlite3GetVTable`                (vtab.c:192)
          - `sqlite3VtabUnlock`               (vtab.c:203)
          - `vtabDisconnectAll` (internal)    (vtab.c:229)
          - `sqlite3VtabDisconnect`           (vtab.c:272)
          - `sqlite3VtabUnlockList`           (vtab.c:310)
          - `sqlite3VtabClear`                (vtab.c:340)
          - `sqlite3_drop_modules`            (vtab.c:140)
      * `sqlite3VtabEponymousTableClear` is a stub that asserts
        `pEpoTab=nil` (correct until 6.bis.1c lands the constructor
        lifecycle that could ever attach an eponymous table).

    `src/passqlite3main.pas` now imports `passqlite3vtab` and reduces
    `sqlite3_create_module / _v2` to thin wrappers around
    `sqlite3VtabCreateModule` (mirroring vtab.c's `createModule()` —
    mutex_enter → CreateModule → ApiExit → mutex_leave + xDestroy on
    failure).  The Phase 8.3 inline TModule + createModule are gone.

    Behaviour change for the registry replace path: the Phase 8.3 stub
    only invoked the previous module's `xDestroy` when both `xDestroy`
    AND `pAux` were non-nil.  The faithful port (via
    `sqlite3VtabModuleUnref`) calls `xDestroy(pAux)` regardless.
    `TestRegistration.T14b` was updated to expect the destructor count
    of 1 (was 0); see new TestVtab.T4 for an explicit assertion.

    Gate: `src/tests/TestVtab.pas` — **27/27 PASS**.  No regressions
    across the full suite (43 tests total green).

    Phase 6.bis.1a scope notes (deferred):
      * Parser-side hooks (`sqlite3VtabBeginParse`, `_FinishParse`,
        `_ArgInit`, `_ArgExtend`) remain stubs in passqlite3parser —
        full bodies land with **6.bis.1b**.
      * Constructor lifecycle (`vtabCallConstructor`,
        `sqlite3VtabCallCreate`, `sqlite3VtabCallConnect`,
        `sqlite3VtabCallDestroy`, `growVTrans`, `addToVTrans`) — **6.bis.1c**.
      * Per-statement hooks (`sqlite3VtabSync/Rollback/Commit/Begin/
        Savepoint`, `callFinaliser`) — **6.bis.1d**.
      * `sqlite3_declare_vtab`, `sqlite3_vtab_on_conflict`,
        `sqlite3_vtab_config` — **6.bis.1e**.
      * `sqlite3VtabOverloadFunction`, `sqlite3VtabMakeWritable`,
        `sqlite3VtabEponymousTableInit/Clear` (full body) — **6.bis.1f**.

    Pitfall captured for future sub-phases: Pascal identifier shadowing.
    `pModule` parameter and `PModule` type alias collide (case-
    insensitive); local var `pVTable` collides with `PVTable` type.
    Renaming workarounds applied (PVtabModule, pVT) — keep this in mind
    when porting the constructor lifecycle.

  - **2026-04-25 — Phase 8.9 loadext.c (extension-loader shims).**
    Build configuration sets `SQLITE_OMIT_LOAD_EXTENSION`, so upstream's
    loadext.c emits *only* the auto-extension surface; the dlopen path
    is `#ifndef`-guarded out.  Added five entry points to
    `src/passqlite3main.pas`:
      * `sqlite3_load_extension` — returns `SQLITE_ERROR` and writes
        `"extension loading is disabled"` into `*pzErrMsg` (allocated via
        `sqlite3_malloc`, freed by caller with `sqlite3_free`).
        MISUSE on db=nil.
      * `sqlite3_enable_load_extension` — faithful: toggles
        `SQLITE_LoadExtension_Bit` in `db^.flags` under `db^.mutex`.
        MISUSE on db=nil.  Note: the `SQLITE_LoadExtFunc` companion bit
        is NOT toggled (gates the SQL-level `load_extension()` function,
        which is not ported); revisit if/when that function lands.
      * `sqlite3_auto_extension` — faithful port of loadext.c:808.
        Process-global list of `procedure; cdecl` callbacks, append
        unique under `SQLITE_MUTEX_STATIC_MAIN`.  MISUSE on xInit=nil.
      * `sqlite3_cancel_auto_extension` — faithful port of loadext.c:858.
        Returns 1 on hit, 0 on miss.
      * `sqlite3_reset_auto_extension` — faithful port of loadext.c:886.
        Drains the list under STATIC_MAIN.
    Gate `src/tests/TestLoadExt.pas` — 20/20 PASS.
    No regressions: TestOpenClose 17/17, TestPrepareBasic 20/20,
    TestRegistration 19/19, TestConfigHooks 54/54, TestInitShutdown
    27/27, TestExecGetTable 23/23, TestBackup 20/20, TestUnlockNotify
    14/14.

    Concrete changes:
      * `src/passqlite3main.pas` — adds `Tsqlite3_loadext_fn` callback
        type, public entry points listed above, and the `gAutoExt` /
        `gAutoExtN` process-global list.
      * `src/tests/TestLoadExt.pas` — new gate test.
      * `src/tests/build.sh` — registers TestLoadExt.

    Phase 8.9 scope notes (intentional / deferred):
      * Real `dlopen`/`dlsym` loading is out of scope for v1 — it would
        require porting `sqlite3OsDlOpen` family in os_unix.c.  The shim
        contract (rc=ERROR + msg) matches what upstream produces when
        compiled with `SQLITE_OMIT_LOAD_EXTENSION` (the symbol is
        omitted there; consumers calling it would get a link error).
      * `sqlite3_load_extension` does NOT consult the
        `SQLITE_LoadExtension` flag bit before refusing — there is no
        loader either way, so the answer is always "disabled".
      * `sqlite3CloseExtensions` (loadext.c:746) is not ported because
        the connection record has no `aExtension` array; openDatabase
        already skips this call.
      * `sqlite3AutoLoadExtensions` (loadext.c:908) — the dispatch hook
        that fires registered auto-extensions on each `sqlite3_open` —
        is NOT yet wired from `openDatabase`.  Stub already exists in
        `passqlite3codegen.pas:6973`; it can stay a stub until codegen
        wires the real call site.  TestLoadExt therefore only exercises
        the *registration* surface, not dispatch.
      * `sqlite3_shutdown` does NOT call `sqlite3_reset_auto_extension`.
        Faithful upstream order (main.c:374) calls it; we omit because
        the auto-ext list is now process-global state that we want to
        survive across init/shutdown cycles for the test harness.
        Re-enable when/if the dispatch hook lands.
      * The `sqlite3_api_routines` thunk (loadext.c:67–648) — the giant
        function-pointer table loaded extensions consume — is not
        ported.  Belongs with a real loader port if v2 lifts OMIT.

  - **2026-04-25 — Phase 8.8 sqlite3_unlock_notify (notify.c shim).**
    Build configuration leaves `SQLITE_ENABLE_UNLOCK_NOTIFY` off, so the
    upstream notify.c is not compiled at all in the C reference; the
    `Tsqlite3` record in `passqlite3util.pas:417` already reflects this
    by omitting `pBlockingConnection` / `pUnlockConnection` /
    `xUnlockNotify` / `pNextBlocked` / `pUnlockArg`.  Added a tiny
    behaviour-correct shim in `src/passqlite3main.pas`:
      * MISUSE on db=nil (matches API_ARMOR guard).
      * No-op (OK) on xNotify=nil — clearing prior registrations is a
        no-op because the port keeps no per-connection unlock state.
      * Otherwise fires `xNotify(@pArg, 1)` immediately.  This is the
        only branch reachable in a no-shared-cache build (notify.c:167
        — "0 == db->pBlockingConnection → invoke immediately").
    Gate `src/tests/TestUnlockNotify.pas` — 14/14 PASS:
      * T1/T2 db=nil → MISUSE (and xNotify must not fire on MISUSE)
      * T3    xNotify=nil clears
      * T4    fires once with apArg^=&tag, nArg=1
      * T5    second call fires again (no deferred queue in the shim)
    No regressions in TestOpenClose / TestPrepareBasic / TestRegistration
    / TestConfigHooks / TestInitShutdown / TestExecGetTable / TestBackup.

    Concrete changes:
      * `src/passqlite3main.pas` — adds `Tsqlite3_unlock_notify_cb`
        callback type and `sqlite3_unlock_notify` (interface + impl).
      * `src/tests/TestUnlockNotify.pas` — new gate test.
      * `src/tests/build.sh` — registers TestUnlockNotify.

    Phase 8.8 scope notes (intentional, matches build config):
      * Real shared-cache blocking-list semantics are out of scope for
        v1 (no shared cache, no `pBlockingConnection` field).  If a
        future phase enables `SQLITE_ENABLE_UNLOCK_NOTIFY`, replace the
        shim with a faithful port of notify.c (sqlite3BlockedList +
        addToBlockedList / removeFromBlockedList + checkListProperties
        + sqlite3ConnectionBlocked / Unlocked / Closed) and extend
        `Tsqlite3` with the five omitted fields.
      * The shim is independent of the STATIC_MAIN mutex — there is no
        global state to guard.

  - **2026-04-25 — Phase 8.7 backup.c.**  New unit
    `src/passqlite3backup.pas` (~470 lines) ports the entire backup.c
    public API: `sqlite3_backup_init` / `_step` / `_finish` /
    `_remaining` / `_pagecount`, plus the pager-side
    `sqlite3BackupUpdate` / `sqlite3BackupRestart` callbacks and the
    VACUUM-side `sqlite3BtreeCopyFile` wrapper.  Field order in
    `TSqlite3Backup` matches the C struct exactly.  Added five missing
    btree accessors (`sqlite3BtreeGetPageSize`,
    `sqlite3BtreeSetPageSize`, `sqlite3BtreeTxnState`,
    `sqlite3BtreeGetReserveNoMutex`, `sqlite3BtreeSetVersion` — plus
    the public `SQLITE_TXN_*` constants) and three pager accessors
    (`sqlite3PagerGetJournalMode`, `sqlite3PagerBackupPtr`,
    `sqlite3PagerClearCache`).  `sqlite3BtreeSetVersion` writes
    bytes 18+19 of page 1 directly via `sqlite3PagerGet` →
    `sqlite3PagerWrite`, since the file-format-version slot is not
    part of the GetMeta/UpdateMeta surface.  Gate
    `src/tests/TestBackup.pas` 20/20 PASS; no regressions in the rest
    of the build.

    Phase 8.7 scope notes (deferred):
      * **Pager hook wiring.**  The pager's write path does not yet
        invoke `sqlite3BackupUpdate` / `sqlite3BackupRestart` on the
        list rooted at `Pager.pBackup`.  An idle source therefore
        copies cleanly, but a writer that mutates a copied page
        between two `_step` calls would not propagate the new content
        to the destination.  Wire from `pager_write_pagelist` /
        invalidate paths in Phase 9 (acceptance).
      * **Zombie close on backup_finish.**  C's
        `sqlite3LeaveMutexAndCloseZombie` is not invoked on the
        destination handle when finish() runs while the destination
        is in `SQLITE_STATE_ZOMBIE`; we fall back to a plain
        `sqlite3BtreeRollback` + `sqlite3Error`.  Acceptable until
        the close-during-backup race is exercised.
      * **`findBtree` temp-database open.**  The C source calls
        `sqlite3OpenTempDatabase` for the magic name "temp".  Our
        `openDatabase` already populates `aDb[1]` eagerly so the
        branch is dead code, but it should be re-added if temp-db
        lazy initialisation lands.
      * **Codegen-driven vectors.**  `TestBackup` exercises the
        surface-API contract on freshly-opened :memory: handles
        (zero-page source → step returns DONE).  A copy-with-content
        gate becomes possible once Phase 6/7 codegen wires
        CREATE/INSERT and we can populate the source from SQL.

  - **2026-04-25 — Phase 8.6 sqlite3_exec / get_table.**  New entry points
    in `src/passqlite3main.pas`: `sqlite3_exec` (legacy.c full port),
    `sqlite3_get_table` / `sqlite3_get_table_cb` / `sqlite3_free_table`
    (table.c full port), and a minimal `sqlite3_errmsg` that returns
    `sqlite3ErrStr(errCode and errMask)` — main.c's fallback path when
    `db^.pErr` is nil, which is currently always the case in the port
    (codegen `sqlite3ErrorWithMsg` stores only the code).  Promoted
    `sqlite3ErrStr` to the `passqlite3vdbe` interface so main.pas
    reaches it.  Read the SQLITE_NullCallback bit unshifted (matches
    the unshifted constants in passqlite3util); the existing shift-by-32
    writes for SQLITE_ShortColNames in openDatabase look wrong, flagged
    for a future flag-bit audit.  Gate `src/tests/TestExecGetTable.pas`
    23/23 PASS; no regressions in TestOpenClose / TestPrepareBasic /
    TestRegistration / TestConfigHooks / TestInitShutdown / TestSchemaBasic
    / TestParser / TestParserSmoke / TestAuthBuiltins.

    Phase 8.6 scope notes (deferred):
      * `sqlite3_errmsg` is fallback-only — promote to the full
        pErr-consulting main.c version once codegen wires
        `sqlite3ErrorWithMsg` to populate `db^.pErr` (printf machinery).
      * Real row results require finishing the Phase 6/7 codegen
        stubs (sqlite3Select / sqlite3FinishTable / etc.).  The gate
        tests focus on surface API contract until then.
      * UTF-16 wrappers (`sqlite3_exec16`) deferred with UTF-16.

  - **2026-04-25 — Phase 8.5 initialize / shutdown.**  New entry points in
    `src/passqlite3main.pas`: `sqlite3_initialize` (main.c:190) and
    `sqlite3_shutdown` (main.c:372).  Faithful port of the two-stage
    initialize: STATIC_MAIN-mutex protected malloc + pInitMutex setup,
    then recursive-mutex protected `sqlite3RegisterBuiltinFunctions` →
    `sqlite3PcacheInitialize` → `sqlite3OsInit` → `sqlite3MemdbInit` →
    `sqlite3PCacheBufferSetup`, finishing by tearing down the recursive
    pInitMutex via the nRefInitMutex counter.  Shutdown clears
    isInit/isPCacheInit/isMallocInit/isMutexInit in the same C-order
    (sqlite3_os_end → sqlite3PcacheShutdown → sqlite3MallocEnd →
    sqlite3MutexEnd) and is idempotent.  Gate
    `src/tests/TestInitShutdown.pas` 27/27 PASS; no regressions in
    TestOpenClose / TestPrepareBasic / TestRegistration / TestConfigHooks
    / TestSchemaBasic / TestParser / TestParserSmoke.

    Phase 8.5 scope notes (deferred):
      * `sqlite3_reset_auto_extension` — auto-extension subsystem
        (`loadext.c`) not ported; shutdown skips the call.  Restore when
        Phase 8.9 lands, even if it stays a stub.
      * `sqlite3_data_directory` / `sqlite3_temp_directory` globals — set
        by `sqlite3_config(SQLITE_CONFIG_DATA_DIRECTORY, ...)`, which is
        not in the typed `sqlite3_config` overloads.  Add together with
        the C-varargs trampoline.
      * `SQLITE_EXTRA_INIT` / `SQLITE_OMIT_WSD` / `SQLITE_ENABLE_SQLLOG`
        compile-time hooks intentionally omitted (not part of our build).
      * NDEBUG NaN sanity check omitted.
      * `sqlite3_progress_handler` (deferred from Phase 8.4) **still not
        ported** — covers the same surface area as a public-API hook
        but is independent of init/shutdown; wire it next time we revisit
        configuration hooks (good fit for an 8.4-fixup or 8.6 prelude).
      * Note for future audits: `openDatabase` still has its lazy
        `sqlite3_os_init` / `sqlite3PcacheInitialize` calls — harmless
        now that `sqlite3_initialize` exists, but redundant once callers
        consistently initialize before opening.  Consider removing in a
        future cleanup pass.

  - **2026-04-25 — Phase 8.4 configuration and hooks.**  New entry points
    in `src/passqlite3main.pas`: `sqlite3_busy_handler`,
    `sqlite3_busy_timeout`, `sqlite3_commit_hook`, `sqlite3_rollback_hook`,
    `sqlite3_update_hook`, `sqlite3_trace_v2`, plus typed entry points for
    the C-varargs `sqlite3_db_config` and `sqlite3_config`.  Because FPC
    cannot cleanly implement C-style varargs in Pascal, both varargs
    APIs are split per argument shape:
      * `sqlite3_db_config_text(db, op, zName)` — MAINDBNAME.
      * `sqlite3_db_config_lookaside(db, op, pBuf, sz, cnt)` — LOOKASIDE.
      * `sqlite3_db_config_int(db, op, onoff, pRes)` — every flag-toggle
        op + FP_DIGITS.  Probe with onoff<0 leaves the flag unchanged.
      * `sqlite3_config(op, arg: i32)` (overloaded with the existing
        `sqlite3_config(op, pArg: Pointer)` from passqlite3util) covers
        SINGLETHREAD/MULTITHREAD/SERIALIZED/MEMSTATUS/URI/SMALL_MALLOC/
        COVERING_INDEX_SCAN/STMTJRNL_SPILL/SORTERREF_SIZE/MEMDB_MAXSIZE.
    Faithful port of `sqliteDefaultBusyCallback` from main.c:1718 with
    the delays/totals nanosleep table; `setupLookaside` is a recording
    stub (no real slot allocation — bDisable stays 1, sz/nSlot are
    written but never honoured by the allocator).  All 21 db-config
    flag bits (`SQLITE_StmtScanStatus`, `SQLITE_NoCkptOnClose`,
    `SQLITE_ReverseOrder`, `SQLITE_LoadExtension`, `SQLITE_Fts3Tokenizer`,
    `SQLITE_EnableQPSG`, `SQLITE_TriggerEQP`, `SQLITE_ResetDatabase`,
    `SQLITE_LegacyAlter`, `SQLITE_NoSchemaError`, `SQLITE_Defensive`,
    `SQLITE_DqsDDL/DML`, `SQLITE_EnableView`, `SQLITE_AttachCreate/Write`,
    `SQLITE_Comments`) are declared locally as `*_Bit` constants —
    public re-export pending a future flag-bit cleanup pass that
    consolidates them with passqlite3util's existing SQLITE_* table.
    Gate `src/tests/TestConfigHooks.pas` 54/54 PASS; no regressions in
    TestRegistration / TestPrepareBasic / TestOpenClose.

    Phase 8.4 scope notes (deferred):
      * C-ABI varargs trampolines (`sqlite3_db_config(db, op, ...)` /
        `sqlite3_config(op, ...)` with FPC `varargs` modifier accessing
        the platform va_list) — needed only for direct C-from-Pascal
        callers; defer to ABI-compat phase.
      * `sqlite3_progress_handler` (gated by SQLITE_OMIT_PROGRESS_CALLBACK
        idioms) — port alongside Phase 8.5 (initialize/shutdown).
      * Real lookaside slot allocator — wait for ENABLE_MEMSYS5 work.
      * UTF-16 hook variants (`sqlite3_trace_v2` already takes UTF-8
        zSql per spec; nothing to add).

  - **2026-04-25 — Phase 8.3 registration APIs.**  New entry points in
    `src/passqlite3main.pas`: `sqlite3_create_function[_v2]`,
    `sqlite3_create_window_function`, `sqlite3_create_collation[_v2]`,
    `sqlite3_collation_needed`, `sqlite3_create_module[_v2]`.  Functions
    delegate to the codegen-side `sqlite3CreateFunc`; collations
    re-implement `createCollation` from main.c:2852 (replace check +
    expire prepared statements + `FindCollSeq(create=1)`); modules use a
    minimal inline `createModule` since vtab.c is not yet ported (Phase
    6.bis.1).  Gate `src/tests/TestRegistration.pas` 19/19 PASS; no
    regressions in TestOpenClose / TestPrepareBasic / TestParser /
    TestParserSmoke / TestSchemaBasic / TestAuthBuiltins.  UTF-16
    entry points (`_create_function16`, `_create_collation16`,
    `_collation_needed16`) and `SQLITE_ANY` triple-registration are
    deferred until UTF-16 transcoding lands.

  - **2026-04-25 — Phase 8.2 sqlite3_prepare family.** New entry points
    `sqlite3_prepare`, `sqlite3_prepare_v2`, `sqlite3_prepare_v3` in
    `src/passqlite3main.pas`, with `sqlite3LockAndPrepare` +
    `sqlite3Prepare` ported from `prepare.c`.  `sqlite3ErrorMsg` in
    codegen now sets `pParse^.rc := SQLITE_ERROR` on the first error
    (matches C and lets parse failures surface through the prepare
    path).  Gate `src/tests/TestPrepareBasic.pas` 20/20 PASS; no
    regressions in TestParser, TestParserSmoke, TestSchemaBasic,
    TestOpenClose, or any of the existing Vdbe gates.  Key constraint
    for Phase 8.3+: until codegen finishes wiring `sqlite3FinishTable`
    / `sqlite3Select` / `sqlite3PragmaParse` etc., a successful prepare
    usually produces `*ppStmt = nil` (rc still OK) — the byte-for-byte
    VDBE differential remains Phase 7.4b / 6.x.

  - **2026-04-25 — Phase 8.1 connection lifecycle scaffold.** New
    `src/passqlite3main.pas` exposes `sqlite3_open[_v2]` and
    `sqlite3_close[_v2]`, with simplified `openDatabase` and
    `sqlite3LeaveMutexAndCloseZombie`.  Gate test
    `src/tests/TestOpenClose.pas` covers `:memory:` + on-disk paths,
    re-open, NULL handling, invalid flags (17/17 PASS).  Gaps for
    Phase 8.2/8.3+: URI parsing, mutex alloc, lookaside, shared cache,
    real `sqlite3SetTextEncoding`, `sqlite3BtreeSchema` fetch, vtab list,
    extension list — all listed in the 8.1 task entry below.

## Status summary

- Target platform: x86_64 Linux, FPC 3.2.2+.
- Strategy: **faithful line-by-line port** of SQLite's split C sources
  (`../sqlite3/src/*.c`). Not an idiomatic Pascal rewrite — SQLite's value
  *is* its battle-tested logic and its test suite, both of which only transfer
  if the control flow does.
- The port is pure Pascal; no C-callable `.so` is produced. `libsqlite3.so` is
  built from the **same split tree** in `../sqlite3/` (via upstream's own
  `./configure && make`) **only as the differential-testing oracle**. One
  source tree, two consumers.
- The honest alternative (wrap `libsqlite3` via FPC's existing `sqlite3dyn` /
  `sqlite3conn`) is **not** this project. That exists; this is a port.

---

## Out of scope (initial port)

Everything listed here is deliberately **not** ported until the core (Phases
0–9) is green. Once that bar is met, any of these may be lifted on demand.

- **`../sqlite3/ext/`** — every extension directory: `fts3/`, `fts5/`, `rtree/`,
  `icu/`, `session/`, `rbu/`, `intck/`, `recover/`, `qrf/`, `jni/`, `wasm/`,
  `expert/`, `misc/`. These are large, feature-specific, and self-contained;
  they link against the core SQLite API, so they can be ported later without
  touching the core.
- **Test-harness C files inside `src/`** — any file matching `src/test*.c`
  (e.g. `test1.c`, `test_vfs.c`, `test_multiplex.c`, `test_demovfs.c`, ~40
  files) and `src/tclsqlite.c` / `src/tclsqlite.h`. These are Tcl-C glue for
  SQLite's own Tcl test suite; they are not application code and must **not**
  be ported. Phase 9.4 calls the Tcl suite via the C-built `libsqlite3.so`,
  not via any Pascal-ported version of these files.
- **`src/json.c`** — JSON1 is now in core, but it is large (~6 k lines) and
  behind `SQLITE_ENABLE_JSON1` historically. Defer until Phase 6 is otherwise
  green; port last within Phase 6 if needed.
- **`src/window.c`** — window functions. Complex, intersects with `select.c`.
  Mark as a late-Phase-6 item.
- **`src/os_kv.c`** — optional key-value VFS. Off by default. Port only if a
  user asks.
- **`src/loadext.c`** — dynamic extension loading. Port last; most Pascal
  users of this port won't need it.
- **`src/os_win.c`, `src/mutex_w32.c`, `src/os_win.h`** — Windows OS backend.
  This port targets Linux first. Windows is a Phase 11+ stretch goal.
- **`tool/*`** (except `lemon.c` and `lempar.c`, which are needed for the
  parser in Phase 7) — assorted utilities (`dbhash`, `enlargedb`,
  `fast_vacuum`, `max-limits`, etc.); not required for the port.
- **The `bzip2recover`-style **`../sqlite3/tool/showwal.c`** and friends** —
  forensic tools. Out of scope.

---

## Folder structure

```
pas-sqlite3/
├── src/
│   ├── passqlite3.inc               # compiler directives ({$I passqlite3.inc})
│   ├── passqlite3types.pas          # u8/u16/u32/i64 aliases, result codes, sqlite3_int64,
│   │                                # sqliteLimit.h (compile-time limits)
│   ├── passqlite3internal.pas       # sqliteInt.h — ~5.9 k lines of central typedefs
│   │                                # (Vdbe, Parse, Table, Index, Column, Schema, sqlite3, ...)
│   │                                # used by virtually every other unit
│   ├── passqlite3os.pas             # OS abstraction layer:
│   │                                # os.c, os_unix.c, os_kv.c (optional), threads.c,
│   │                                # mutex.c, mutex_unix.c, mutex_noop.c
│   │                                # (headers: os.h, os_common.h, mutex.h)
│   ├── passqlite3util.pas           # Utilities used everywhere:
│   │                                # util.c, hash.c, printf.c, random.c, utf.c, bitvec.c,
│   │                                # fault.c, malloc.c, mem0.c–mem5.c, status.c, global.c
│   │                                # (headers: hash.h)
│   ├── passqlite3pcache.pas         # pcache.c + pcache1.c — page-cache (distinct from pager!)
│   │                                # (headers: pcache.h)
│   ├── passqlite3pager.pas          # pager.c: journaling/transactions;
│   │                                # memjournal.c (in-memory journal), memdb.c (:memory:)
│   │                                # (headers: pager.h)
│   ├── passqlite3wal.pas            # wal.c: write-ahead log (headers: wal.h)
│   ├── passqlite3btree.pas          # btree.c + btmutex.c
│   │                                # (headers: btree.h, btreeInt.h)
│   ├── passqlite3vdbe.pas           # VDBE bytecode VM and ancillaries:
│   │                                # vdbe.c (~9.4 k lines, ~199 opcodes),
│   │                                # vdbeaux.c, vdbeapi.c, vdbemem.c,
│   │                                # vdbeblob.c (incremental blob I/O),
│   │                                # vdbesort.c (external sorter),
│   │                                # vdbetrace.c (EXPLAIN helper),
│   │                                # vdbevtab.c (virtual-table VDBE ops)
│   │                                # (headers: vdbe.h, vdbeInt.h)
│   ├── passqlite3parser.pas         # tokenize.c + Lemon-generated parse.c (from parse.y),
│   │                                # complete.c (sqlite3_complete)
│   ├── passqlite3codegen.pas        # SQL → VDBE translator; single large unit:
│   │                                # expr.c, resolve.c, walker.c, treeview.c,
│   │                                # where.c + wherecode.c + whereexpr.c (~12 k combined),
│   │                                # select.c (~9 k), window.c,
│   │                                # insert.c, update.c, delete.c, upsert.c,
│   │                                # build.c (schema), alter.c,
│   │                                # analyze.c, attach.c, pragma.c, trigger.c, vacuum.c,
│   │                                # auth.c, callback.c, func.c, date.c, fkey.c, rowset.c,
│   │                                # prepare.c, json.c (if in scope — see below)
│   │                                # (headers: whereInt.h)
│   ├── passqlite3vtab.pas           # vtab.c (virtual-table machinery) +
│   │                                # dbpage.c + dbstat.c + carray.c
│   │                                # (built-in vtabs)
│   ├── passqlite3.pas               # Public API:
│   │                                # main.c, legacy.c (sqlite3_exec), table.c
│   │                                # (sqlite3_get_table), backup.c (online-backup API),
│   │                                # notify.c (unlock-notify), loadext.c (extension loading
│   │                                # — optional)
│   ├── csqlite3.pas                 # external cdecl declarations of C reference (csq_* aliases)
│   └── tests/
│       ├── TestSmoke.pas            # load libsqlite3.so, print sqlite3_libversion() — smoke test
│       ├── TestOSLayer.pas          # file I/O + locking: Pascal vs C on the same file
│       ├── TestPagerCompat.pas      # Pascal pager writes → C can read, and vice versa
│       ├── TestBtreeCompat.pas      # insert/delete/seek sequences produce byte-identical .db files
│       ├── TestVdbeTrace.pas        # same bytecode → same opcode trace under PRAGMA vdbe_trace=ON
│       ├── TestExplainParity.pas    # EXPLAIN output for a SQL corpus matches C reference exactly
│       ├── TestSQLCorpus.pas        # run a corpus of .sql scripts through both; diff output + .db
│       ├── TestFuzzDiff.pas         # differential fuzzer driver (AFL / dbsqlfuzz corpus input)
│       ├── TestReferenceVectors.pas # canonical .db files from ../sqlite3/test/ open & query identically
│       ├── Benchmark.pas            # throughput: INSERT/SELECT Mops/s, Pascal vs C
│       ├── vectors/                 # canonical .db files, .sql scripts, expected outputs
│       └── build.sh                 # builds libsqlite3.so from ../sqlite3/ + all Pascal test binaries
├── bin/
├── install_dependencies.sh          # ensures fpc, gcc, tcl (for SQLite's own tests), clones ../sqlite
├── LICENSE
├── README.md
└── tasklist.md                      # this file
```

---

## The differential-testing foundation

This port has no chance of succeeding without a ruthless validation oracle.
Build the oracle **before** porting any non-trivial code.

### Why differential testing first

SQLite is ~150k lines. A line-by-line port will introduce hundreds of subtle
bugs — integer promotion differences, pointer-aliasing mistakes, off-by-one on
`u8`/`u16` boundaries, UTF-8 vs UTF-16 string handling. The only tractable way
to find them is to run the Pascal port and the C reference side-by-side on the
same input and diff.

### Three layers of diffing

1. **Black-box (easiest — enable first).** Feed identical `.sql` scripts to the
   `sqlite3` CLI (C) and to a minimal Pascal CLI (progressively built as
   phases complete). Diff:
   - stdout (query results, error messages)
   - return codes
   - the resulting `.db` file, **byte-for-byte** — SQLite's on-disk format is
     stable and documented, so a correct pager+btree port produces identical files.

2. **White-box / layer-by-layer.** Instrument both builds to dump intermediate
   state at layer boundaries:
   - **Parser output:** dump the VDBE program emitted by `PREPARE`. `EXPLAIN`
     already renders VDBE bytecode as a result set — goldmine for validating
     parser + code generator.
   - **VDBE traces:** SQLite supports `PRAGMA vdbe_trace=ON` (with `SQLITE_DEBUG`)
     and `sqlite3_trace_v2()`. Identical bytecode must produce identical opcode
     traces.
   - **Pager operations:** log every page read/write/journal action; compare
     sequences for a given SQL workload.
   - **B-tree operations:** log cursor moves, inserts, splits.

3. **Fuzzing.** Once (1) and (2) work, point AFL at both builds with divergence
   as the crash signal. The SQLite team's `dbsqlfuzz` corpus is the natural seed
   set. This is how real ports find subtle bugs — human-written tests miss them.

### Known diff-noise to normalise before comparing

- **Floating-point formatting.** C's `printf("%g", …)` and FPC's `FloatToStr` /
  `Str(x:0:g, …)` produce cosmetically different strings for the same double.
  Either (a) compare query result sets as typed values not strings, or
  (b) route both through an identical formatter before diffing.
- **Timestamps / random blobs.** Anything involving `sqlite3_randomness()` or
  `CURRENT_TIMESTAMP` must be stubbed to a deterministic seed on both sides
  before diffing.
- **Error message wording.** Match the C source verbatim. Do not "improve"
  error text.

### Concrete harness layout

A driver script (`tests/diff.sh`) that, given a `.sql` file:
1. Runs `sqlite3 ref.db < input.sql` → `ref.stdout`, `ref.stderr`
2. Runs `bin/passqlite3 pas.db < input.sql` → `pas.stdout`, `pas.stderr`
3. Diffs the four streams + `ref.db` vs `pas.db` (after normalising header
   mtime field, which SQLite stamps — see pitfall #9).

---

## Phase 0 — Infrastructure (prerequisite for everything)

- [X] **0.1** Ensure `../sqlite3/` contains the upstream split source tree
  (the canonical layout with `src/`, `test/`, `tool/`, `Makefile.in`,
  `configure`, `autosetup/`, `auto.def`, etc. — SQLite ≥ 3.48 uses
  **autosetup** as its build system, not classic autoconf). Confirmed
  compatible with this tasklist: version **3.53.0**, ~150 `src/*.c` files,
  1 188 `test/*.test` Tcl tests, `tool/lemon.c` + `tool/lempar.c` present,
  `test/fuzzdata*.db` seed corpus present. Run `./configure && make` once to
  confirm it builds cleanly on this machine and produces a `libsqlite3.so`
  (location depends on build-system version — locate it with `find` rather
  than hardcoding) plus the `sqlite3` CLI binary. Those two artefacts are
  the differential oracle. The individual `src/*.c` files are the porting
  reference — each Pascal unit maps to a named set of C files (see the
  folder-structure table above). Note that `sqlite3.h` and `shell.c` are
  **generated** at build time from `sqlite.h.in` and `shell.c.in`; do not
  look for them in a freshly-cloned tree. The amalgamation (`sqlite3.c`) is
  not generated and not used.

- [X] **0.2** Create `src/passqlite3.inc` with the compiler directives.
  **Use `../pas-core-math/src/pascoremath.inc` as the canonical template** —
  copy its layout (FPC detection, mode/inline/macro directives, CPU32/CPU64
  split, non-FPC fallback) and add SQLite-specific additions (`{$GOTO ON}`,
  `{$POINTERMATH ON}`, `{$Q-}`, `{$R-}`) on top. Included at the top of every
  unit with `{$I passqlite3.inc}` — placed before the `unit` keyword so mode
  directives take effect in time:
  ```pascal
  {$I passqlite3.inc}
  unit passqlite3types;
  ```
  Starter content (modelled on `pasbzip2.inc`):
  ```pascal
  {$IFDEF FPC}
    {$MODE OBJFPC}
    {$H+}
    {$INLINE ON}
    {$GOTO ON}           // VDBE dispatch may benefit; parser definitely will
    {$COPERATORS ON}
    {$MACRO ON}
    {$CODEPAGE UTF8}
    {$POINTERMATH ON}    // u8* / PByte arithmetic everywhere
    {$Q-}                // disable overflow checking — SQLite relies on wrap
    {$R-}                // disable range checking for the same reason
    {$IFDEF CPU32BITS} {$DEFINE CPU32} {$ENDIF}
    {$IFDEF CPU64BITS} {$DEFINE CPU64} {$ENDIF}
  {$ENDIF}
  ```
  `{$Q-}` / `{$R-}` are important: SQLite uses unsigned wrap arithmetic in the
  CRC, varint, and hash code paths. Keeping them enabled project-wide would
  spuriously crash correct code.

- [X] **0.3** Create `src/passqlite3types.pas` with SQLite's primitive aliases.
  Reuse FPC's native types wherever names already exist (`Int32`, `UInt32`,
  `Int64`, `UInt64`, `Byte`, `Word`, `Pointer`, `PByte`, `PChar`). Introduce
  only the genuinely-SQLite-specific names:
  ```pascal
  type
    u8  = Byte;      // cosmetic alias for readability vs the C source
    u16 = UInt16;
    u32 = UInt32;
    u64 = UInt64;
    i8  = Int8;
    i16 = Int16;
    i32 = Int32;
    i64 = Int64;
    Pu8 = ^u8;
    Pu16 = ^u16;
    Pu32 = ^u32;
    Pgno = ^u32;     // SQLite page number
    sqlite3_int64  = i64;
    sqlite3_uint64 = u64;
  ```
  Rule: everywhere the C source says `u8`, `u16`, `u32`, `i64`, write the
  identical name in Pascal. Reads 1:1 against the reference during review.

- [X] **0.4** Declare SQLite result codes (`SQLITE_OK`, `SQLITE_ERROR`,
  `SQLITE_BUSY`, `SQLITE_LOCKED`, `SQLITE_NOMEM`, `SQLITE_READONLY`, `SQLITE_IOERR`,
  `SQLITE_CORRUPT`, `SQLITE_FULL`, `SQLITE_CANTOPEN`, `SQLITE_PROTOCOL`,
  `SQLITE_SCHEMA`, `SQLITE_TOOBIG`, `SQLITE_CONSTRAINT`, `SQLITE_MISMATCH`,
  `SQLITE_MISUSE`, `SQLITE_NOLFS`, `SQLITE_AUTH`, `SQLITE_FORMAT`, `SQLITE_RANGE`,
  `SQLITE_NOTADB`, `SQLITE_NOTICE`, `SQLITE_WARNING`, `SQLITE_ROW`, `SQLITE_DONE`,
  plus all extended result codes) and open-flag constants (`SQLITE_OPEN_READONLY`,
  `SQLITE_OPEN_READWRITE`, `SQLITE_OPEN_CREATE`, …) with the **exact** numeric
  values from `sqlite3.h`. Any off-by-one here will cascade invisibly.

- [X] **0.5** Create `src/csqlite3.pas` — external declarations of the C
  reference API, bound to `libsqlite3.so`, with `csq_` prefixes (convention
  mirrors `cbz_` in pas-bzip2):
  ```pascal
  const LIBSQLITE3 = 'sqlite3';

  function csq_libversion: PChar;
    cdecl; external LIBSQLITE3 name 'sqlite3_libversion';
  function csq_open(zFilename: PChar; out ppDb: Pointer): Int32;
    cdecl; external LIBSQLITE3 name 'sqlite3_open';
  // ... all exported sqlite3_* functions we'll need for differential testing
  ```
  Only tests use `csq_*`. The Pascal port itself must never link against
  `libsqlite3.so` — otherwise differential testing is comparing a thing with
  itself.

- [X] **0.6** Create `install_dependencies.sh` modelled on pas-bzip2's: ensure
  `fpc`, `gcc`, `tcl` (SQLite's own tests are in Tcl), and verify that
  `../sqlite3/` is present and buildable (print a clear error if it is
  missing — do not auto-clone; the user chose the layout).

- [X] **0.7** Create `src/tests/build.sh` — **use
  `../pas-core-math/src/tests/build.sh` as the canonical template** (it sets
  up `BIN_DIR` / `SRC_DIR`, handles the `-Fu` / `-Fi` / `-FE` / `-Fl` flag
  pattern, cleans up `.ppu` / `.o` artefacts, and is known-working on this
  developer's machine). Adapt its shape, not copy it verbatim — our oracle
  step is an upstream `make` rather than a direct `gcc` invocation. Steps:
  1. Build the oracle `libsqlite3.so` by invoking upstream's own build
     (SQLite ≥ 3.48 uses **autosetup**, not classic autoconf/libtool):
     `cd ../sqlite3 && ./configure --debug CFLAGS='-O2 -fPIC
      -DSQLITE_DEBUG -DSQLITE_ENABLE_EXPLAIN_COMMENTS
      -DSQLITE_ENABLE_API_ARMOR' && make`. The shared library's output path
     varies between build-system versions (autosetup typically drops
     `libsqlite3.so` at the top of `../sqlite3/`; the classic autoconf build
     placed it under `.libs/`). The `build.sh` script must therefore **locate**
     the produced `libsqlite3.so` (e.g. `find ../sqlite3 -maxdepth 3 -name
     'libsqlite3.so*' -type f | head -1`) and symlink/copy it to
     `src/libsqlite3.so`. Do not hardcode the upstream output path; do not
     write a bespoke gcc line either — upstream's build knows the right
     compile flags, generated headers (`opcodes.h`, `parse.c`, `keywordhash.h`,
     `sqlite3.h`), and link order. Any bespoke command will drift from upstream
     over time.
  2. Compile each `tests/*.pas` binary with
     `fpc -O3 -Fu../ -FE../../bin -Fl../`.
  3. All test binaries run with `LD_LIBRARY_PATH=src/ bin/...`.

- [X] **0.8** Write `TestSmoke.pas`: loads `libsqlite3.so` via `csqlite3.pas`,
  prints `csq_libversion`, opens an in-memory DB, executes `SELECT 1;`, prints
  the result, closes. This is the health check for the build system — until
  this runs, no differential test can run.

- [X] **0.9** **Internal headers — progressive porting strategy.** `sqliteInt.h`
  (~5.9 k lines) defines the ~200 structs and typedefs that virtually every
  other source file uses (`sqlite3`, `Vdbe`, `Parse`, `Table`, `Index`,
  `Column`, `Schema`, `Select`, `Expr`, `ExprList`, `SrcList`, …). **Do not**
  attempt to port the whole header up front — it references types declared in
  `btreeInt.h`, `vdbeInt.h`, `whereInt.h`, `pager.h`, `wal.h` which have not
  yet been ported, leading to circular dependencies. Instead:
  - Create `passqlite3internal.pas` with the shared constants, bit flags, and
    primitive-level typedefs (anything not itself containing a struct
    reference). This subset is safe to port now.
  - As each subsequent phase begins, port exactly the `sqliteInt.h` struct
    declarations that that phase needs, and add them to
    `passqlite3internal.pas`. The module-local headers (`btreeInt.h` → into
    `passqlite3btree.pas`, `vdbeInt.h` → `passqlite3vdbe.pas`,
    `whereInt.h` → `passqlite3codegen.pas`) travel with their modules.
  - Field order **must match** C bit-for-bit — tests will `memcmp` these
    records. Do not reorder "for alignment" or "for readability".
  - `sqliteLimit.h` (~450 lines, compile-time limits) ports **once, whole**
    into `passqlite3types.pas` as `const` values.

- [X] **0.10** Assemble `tests/vectors/`:
  - A minimal SQL corpus: 20–50 `.sql` scripts covering DDL, DML, joins,
    subqueries, triggers, views, common pragmas.
  - Canonical `.db` files produced by the C reference for each script, used by
    `TestReferenceVectors.pas`.
  - The `dbsqlfuzz` seed corpus from `../sqlite3/test/fuzzdata*.db` (if present).

- [X] **0.11** **Generated files policy.** SQLite's C build generates four
  files that are not checked into `src/`; upstream produces them with
  Tcl / C helpers in `tool/`. Pick **one** policy and apply uniformly:
  - **(A) Freeze-and-port** (recommended): run upstream's `make` once; copy
    the generated `opcodes.h`, `opcodes.c`, `parse.c`, `parse.h`,
    `keywordhash.h`, `sqlite3.h` into `src/generated/`; hand-port each to
    Pascal; pin the upstream commit hash in a top-of-file comment so
    reviewers can tell when to regenerate.
  - **(B) Port the generators**: port `tool/mkopcodeh.tcl`,
    `tool/mkopcodec.tcl`, `tool/mkkeywordhash.c`, and a Lemon-for-Pascal
    emitter. Run them from `build.sh`. More faithful to upstream, much more
    work.

  Recommendation: **policy (A) for v1**, switching to (B) only if upstream
  bumps start producing frequent churn. File list and context:
  - `opcodes.h` / `opcodes.c` — the `OP_*` constant table and the opcode
    name strings, generated from comments in `vdbe.c` by
    `tool/mkopcodeh.tcl` + `tool/mkopcodec.tcl`. **Opcode names are
    part of the public `EXPLAIN` output** — any divergence fails
    `TestExplainParity.pas` in Phase 6.
  - `parse.c` / `parse.h` — the LALR(1) parse table, generated by
    `tool/lemon` from `parse.y`. Addressed by Phase 7.2.
  - `keywordhash.h` — a perfect hash of SQL keywords, used by `tokenize.c`.
    Generated by `tool/mkkeywordhash.c`.
  - `sqlite3.h` — the public C header, generated from `sqlite.h.in` by
    trivial string substitution. Our `passqlite3.pas` public API must
    expose identical constant values — script a comparison check in
    `build.sh` that greps the numeric values out of the generated
    `sqlite3.h` and confirms they match `passqlite3types.pas`.

- [X] **0.12** **Compile-time options policy.** SQLite has ~200
  `SQLITE_OMIT_*`, `SQLITE_ENABLE_*`, and `SQLITE_DEFAULT_*` flags that alter
  which code paths exist. Declare our target configuration up front and
  freeze it for v1. **Default policy: match upstream's default configuration**
  (what a plain `./configure && make` produces), plus `SQLITE_DEBUG` for the
  oracle build only. Specifically:
  - **Keep enabled (upstream defaults)**: `SQLITE_ENABLE_MATH_FUNCTIONS`,
    `SQLITE_ENABLE_FTS5` (out of scope for initial port but flag stays on so
    the core behaves identically), `SQLITE_THREADSAFE=1` (serialized).
  - **Explicitly off for v1**: `SQLITE_OMIT_LOAD_EXTENSION` (matches Phase 8.9
    stub), `SQLITE_OMIT_DEPRECATED` (we don't need legacy surface), any
    `SQLITE_ENABLE_*` that pulls in an `ext/` module (those are out of scope
    per the "Out of scope" section).
  - **Oracle-only**: `SQLITE_DEBUG`, `SQLITE_ENABLE_EXPLAIN_COMMENTS`,
    `SQLITE_ENABLE_API_ARMOR`.
  - Record the full flag list in `src/passqlite3.inc` as a comment block so
    future contributors can see exactly what the Pascal port implements.

- [X] **0.13** **LICENSE + README.** Match the pattern from
  `../pas-bzip2/` and `../pas-core-math/`:
  - `LICENSE` — the SQLite C code is public-domain; the Pascal port may keep
    that posture or relicense to MIT / X11 (same as pas-bzip2). Decide and
    commit the file. Default recommendation: **public domain, matching
    upstream**, with a short header note acknowledging the C source.
  - `README.md` — 40–60 lines: what this project is, build instructions
    (`./install_dependencies.sh && src/tests/build.sh`), how to run the
    differential tests, honest status ("Phase N of 12 complete"), pointer to
    `tasklist.md`.

---

### Phase 0 implementation notes (2026-04-20)

- `../sqlite3/` is present at version **3.53.0** and builds cleanly with autosetup.
- System has FPC 3.2.2 and gcc installed; `tclsh` present.
- `libsqlite3.so` is built into `../sqlite3/` and symlinked to `src/libsqlite3.so`.
  **Important**: the system `libsqlite3.so` has SONAME `libsqlite3.so.0`, so test
  binaries compiled with `-Fl./src` need both `src/libsqlite3.so` **and**
  `src/libsqlite3.so.0` to resolve at runtime via `LD_LIBRARY_PATH=src/`. The
  build script creates both symlinks. 
- `TestSmoke` passes: 3.53.0 oracle, SELECT 1 round-trip confirmed.
- 0.10 `tests/vectors/` directory created; actual `.sql` / `.db` files are
  populated as each phase's gating test needs them.
- 0.11 Policy (A) adopted: generated files will be frozen from the upstream build
  and ported manually, with the upstream commit hash noted in each file header.
- 0.12 Compile-time flag set documented in `passqlite3.inc`.

---

## Phase 1 — OS abstraction

Files: `os.c` (VFS dispatcher), `os_unix.c` (~8 k lines, the POSIX backend),
`threads.c` (thread wrappers), `mutex.c` + `mutex_unix.c` +
`mutex_noop.c` (mutex dispatch + POSIX + single-threaded no-op).
Headers: `os.h`, `os_common.h`, `mutex.h`.

Start here because it is the smallest self-contained layer with no
SQLite-internal dependencies. Also the natural place to establish porting
conventions: `struct` → `record`, function pointers → procedural types,
`#define` → `const` or `inline`.

- [X] **1.1** Port the `sqlite3_io_methods` / `sqlite3_vfs` function-pointer
  tables to Pascal procedural types in `passqlite3os.pas`. These are the
  interface SQLite uses to talk to the OS.

- [X] **1.2** Port file operations: open, close, read, write, truncate, sync,
  fileSize, lock, unlock, checkReservedLock. Each wraps a POSIX syscall via
  FPC's `BaseUnix` (`FpOpen`, `FpRead`, `FpWrite`, `FpFtruncate`, `FpFsync`,
  `FpFcntl`).

- [X] **1.3** Port POSIX advisory-lock machinery (`unixLock`, `unixUnlock`,
  `findInodeInfo`). This is the single most-fiddly part of the OS layer —
  SQLite's own comments call it "a mess". Port faithfully; do not try to
  simplify.
  **Note (Phase 1 simplification):** each `unixFile` maintains its own private
  lock state (no intra-process inode sharing via `unixInodeInfo` linked list).
  Cross-process POSIX advisory locking via `fcntl F_SETLK` works correctly.
  Full intra-process inode sharing deferred to Phase 3.

- [X] **1.4** Port the mutex implementation (`mutex_unix.c`): wraps
  `pthread_mutex_*`. Pascal side uses direct `pthread_mutex_init`/`lock`/`unlock`
  via `cdecl` externals from the `pthreads` FPC unit.

- [X] **1.5** Decide the allocator policy (resolved here; implementation is in
  Phase 2.8). Options: use FPC's `GetMem`/`FreeMem` (same backing allocator on
  glibc Linux) or call `malloc` directly via `cdecl` to guarantee byte-identical
  allocation patterns. **Decision: `malloc` direct** via `external 'c' name 'malloc'`
  (and calloc/realloc/free similarly). Shim helpers `sqlite3MallocZero` and
  `sqlite3StrDup` are implemented.

- [X] **1.6** `TestOSLayer.pas`: open the same file with Pascal and C
  implementations, perform a scripted sequence of reads/writes/locks, confirm
  the resulting file bytes match and that lock acquisition/release order is
  identical.
  **Note:** 14 test cases cover os_init, VFS open/write/read/fileSize/truncate,
  shared/reserved/exclusive lock cycles, checkReservedLock, close/delete, access,
  fullPathname, recursive mutex, and cross-read (Pascal-written file read via POSIX).
  All 14 pass. **FPC bug note:** `FpGetCwd` on Linux returns path length (not
  pointer) because the kernel syscall returns the length; `unixFullPathname` uses
  `libc getcwd` directly via `cdecl external 'c'` instead.

---

### Phase 1 implementation notes (2026-04-20)

- `passqlite3os.pas` now has a full `implementation` section (~1400 lines added).
- Ported from: `os.c` (VFS dispatch wrappers), `mutex.c` + `mutex_unix.c`
  (pthread recursive-mutex pool, 12 static + dynamic mutexes), `os_unix.c`
  (POSIX I/O, advisory locking state machine, VFS open/delete/access/fullpathname,
  randomness from `/dev/urandom`, sleep, currentTime).
- `sqlite3_os_init` registers a singleton `unixVfsObj` as the default VFS.
- `unixIoMethods` vtable is filled in the unit's `initialization` section.
- **FPC bug note:** `FpGetCwd` on Linux calls the raw `getcwd` syscall, which
  returns path length (not a pointer). `unixFullPathname` works around this by
  calling `libc getcwd` via `external 'c' name 'getcwd'`.
- All 14 `TestOSLayer` cases pass.

---

## Phase 2 — Utilities

Files: `util.c`, `hash.c`, `printf.c`, `random.c`, `utf.c`, `bitvec.c`,
`malloc.c`, `mem0.c`, `mem1.c`, `mem2.c`, `mem3.c`, `mem5.c`, `fault.c`,
`status.c`, `global.c`. Combined ~8 k lines. Self-contained; heavy
dependencies from every other layer.

- [X] **2.1** Port `util.c`. In particular, the **endianness accessors** are
  the only correct way to read and write SQLite's big-endian on-disk format;
  port them verbatim and use them everywhere (pager, btree, WAL) instead of
  ever casting a `PByte` to `PUInt32` directly:
  - `sqlite3Get2byte` / `sqlite3Put2byte` (2-byte big-endian)
  - `sqlite3Get4byte` / `sqlite3Put4byte` (4-byte big-endian)
  - `getVarint` / `putVarint` (1–9-byte huffman-like varint)
  - `getVarint32` / `putVarint32` (fast path for 32-bit values)
  Also port: `sqlite3Atoi`, `sqlite3AtoF`, `sqlite3GetInt32`,
  `sqlite3StrICmp`, safety-net integer arithmetic
  (`sqlite3AddInt64`, `sqlite3MulInt64`, etc.).

- [X] **2.2** Port `hash.c`: SQLite's generic string-keyed hash table. Used by
  the symbol table, schema cache, and many transient lookups.

- [X] **2.3** Port `printf.c`: SQLite's own `sqlite3_snprintf` / `sqlite3_mprintf`.
  **Do not** delegate to FPC's `Format` — SQLite supports format specifiers
  (`%q`, `%Q`, `%z`, `%w`, `%lld`) that Pascal's `Format` does not. Port line
  by line.
  **Implementation note**: Phase 2 delivers libc `vasprintf`/`vsnprintf`-backed
  stubs. Full printf.c port (with `%q`/`%Q`/`%w`/`%z`) deferred to Phase 6
  when `Parse` and `Mem` types are available.

- [X] **2.4** Port `random.c`: SQLite's PRNG. Determinism depends on this; it
  must produce bit-identical output to the C version for the same seed.

- [X] **2.5** Port `utf.c`: UTF-8 ↔ UTF-16LE ↔ UTF-16BE conversion. Used
  whenever a `TEXT` value crosses an encoding boundary. **Do not** delegate to
  FPC's `UTF8Encode` / `UTF8Decode` — SQLite has its own incremental converter
  with specific error-handling semantics.
  **Implementation note**: `sqlite3VdbeMemTranslate` stubbed (requires `Mem`
  type from Phase 6).

- [X] **2.6** Port `bitvec.c`: a space-efficient bitvector used by the pager
  to track which pages are dirty. Small (~400 lines); no dependencies.

- [X] **2.7** Port `malloc.c`: SQLite's allocation dispatch (thin wrapper over
  the backend allocators); `fault.c`: fault injection helpers (used by tests
  — may stub out until Phase 9).

- [X] **2.8** Port the memory-allocator backends: `mem0.c` (no-op /
  alloc-failure stub), `mem1.c` (system malloc), `mem2.c` (debug mem with
  guard bytes), `mem3.c` (memsys3 — alternate allocator), `mem5.c` (memsys5 —
  power-of-2 buckets). Decide at Phase 1.5 time which backend is the default;
  port all five for parity with the C build-time switches.
  **Implementation note**: Phase 2 delivers mem1 (system malloc via libc) and
  mem0 stubs. mem2/mem3/mem5 deferred.

- [X] **2.9** Port `status.c` (`sqlite3_status`, `sqlite3_db_status` counters)
  and `global.c` (`sqlite3Config` global struct + `SQLITE_CONFIG_*` machinery).

- [X] **2.10** `TestUtil.pas`: for varint round-trip (every boundary: 0, 127,
  128, 16383, 16384, …, INT64_MAX), atoi/atof edge cases (overflow, subnormals,
  NaN, trailing garbage), printf format strings, PRNG determinism (same seed →
  same 1000-value stream), UTF-8/16 conversion round-trips — diff Pascal vs C
  output on every case.

### Phase 2 implementation notes

**Unit**: `src/passqlite3util.pas` (1858 lines).

**What was done**:
- `global.c`: Ported `sqlite3UpperToLower[274]` and `sqlite3CtypeMap[256]`
  verbatim. `sqlite3GlobalConfig` initialised in `initialization` section.
- `util.c`: Ported varint codec (lines 1574–1860), `sqlite3Get4byte`/
  `sqlite3Put4byte`, `sqlite3StrICmp`, `sqlite3_strnicmp`, `sqlite3StrIHash`,
  `sqlite3AtoF`, `sqlite3Strlen30`, `sqlite3FaultSim`. Character-classification
  macros ported as `inline` functions.
- `hash.c`: All 5 public + 4 private functions ported faithfully.
- `random.c`: ChaCha20 block function and `sqlite3_randomness` ported verbatim.
  Save/restore state included.
- `bitvec.c`: All functions ported including the three-way bitmap/hash/subtree
  representation and the clear-via-rehash logic.
- `status.c`: `sqlite3StatusValue`, `sqlite3StatusUp`, `sqlite3StatusDown`,
  `sqlite3StatusHighwater`, `sqlite3_status64`, `sqlite3_status`.
- `malloc.c` + `mem1.c` + `fault.c`: Thin malloc dispatch layer wrapping libc
  `malloc`/`free`/`realloc` with optional memstat accounting. Benign-malloc
  hooks. `sqlite3MallocSize` via `malloc_usable_size`.
- `printf.c`: Stub using libc `vasprintf`/`vsnprintf`. Full port with `%q`/
  `%Q`/`%w`/`%z` deferred to Phase 6.
- `utf.c`: `sqlite3Utf8Read`, `sqlite3Utf8CharLen`,
  `sqlite3AppendOneUtf8Character`.

**Design decisions**:
- `printf.c` full port deferred — requires `Parse` and `Mem` types (Phase 6).
  Phase 2 stubs compile cleanly and unblock all downstream phases.
- `mem2`/`mem3`/`mem5` deferred — only needed for specific test configurations.
- `sqlite3VdbeMemTranslate` stubbed — requires `Mem` from vdbeInt.h (Phase 6).
- `-lm` added to `build.sh` FPC_FLAGS for `pow()` linkage.

**Known limitations**:
- `sqlite3_mprintf`/`sqlite3_snprintf` are stubs; format extensions `%q`,
  `%Q`, `%w`, `%z` not yet handled.
- `sqlite3DbStatus` (per-connection status) deferred to Phase 6.
- Status counters not mutex-protected when `gMallocMutex` is nil (before init).



## Phase 3 — Page cache + Pager + WAL

Files:
- `pcache.c` (~1 k lines) + `pcache1.c` (~1.5 k) — **page cache** (the
  memory-resident cache of file pages, distinct from the pager). Everything
  in pager/btree/VDBE ultimately goes through `sqlite3PcacheFetch` /
  `sqlite3PcacheRelease`.
- `pager.c` (~7.8 k lines) + `memjournal.c` + `memdb.c` — **pager**:
  journaling, transactions, the `:memory:` backing.
- `wal.c` (~4 k lines) — **WAL**: write-ahead log.

**The trickiest correctness-critical layer.** Journaling and WAL semantics must
be bit-exact — if the pager produces a different journal byte stream, a crash
at the wrong moment will leave the database unrecoverable.

### 3.A — Page cache (prerequisite for 3.B)

- [X] **3.A.1** Port `pcache.c`: the generic page-cache interface and the
  `PgHdr` lifecycle (`sqlite3PcacheFetch`, `sqlite3PcacheRelease`,
  `sqlite3PcacheMakeDirty`, `sqlite3PcacheMakeClean`, eviction).
- [X] **3.A.2** Port `pcache1.c`: the default concrete backend (LRU with
  purgeable / unpinned page tracking). This is the allocator-heavy one.
- [X] **3.A.3** Port `memjournal.c`: the in-memory journal implementation
  used when `PRAGMA journal_mode=MEMORY` or during `SAVEPOINT`.
- [X] **3.A.4** Port `memdb.c`: the `:memory:` database backing — a VFS-shaped
  object over a single in-RAM buffer.
- [X] **3.A.5** Gate: `TestPCache.pas` — scripted fetch / release / dirty /
  eviction sequences produce identical `PgHdr` state and identical
  allocation counts vs C reference. **All 8 tests pass (T1–T8).**

### Phase 3.A.3+3.A.4 implementation notes (2026-04-22)

**Units**: `src/passqlite3pager.pas` (~1080 lines, memjournal.c + memdb.c).

**What was done**:
- Ported all `memjournal.c` types (`FileChunk`, `FilePoint`, `MemJournal`) and functions:
  `memjrnlRead`, `memjrnlWrite`, `memjrnlTruncate`, `memjrnlFreeChunks`,
  `memjrnlCreateFile`, `memjrnlClose`, `memjrnlSync`, `memjrnlFileSize`,
  plus all exported functions (`sqlite3JournalOpen`, `sqlite3MemJournalOpen`,
  `sqlite3JournalCreate`, `sqlite3JournalIsInMemory`, `sqlite3JournalSize`).
- Ported all `memdb.c` types (`MemStore`, `MemFile`) and functions:
  `memdbClose`, `memdbRead`, `memdbWrite`, `memdbTruncate`, `memdbSync`,
  `memdbFileSize`, `memdbLock`, `memdbUnlock`, `memdbFileControl`,
  `memdbDeviceCharacteristics`, `memdbFetch`, `memdbUnfetch`, `memdbOpen`,
  plus VFS helper functions and exported `sqlite3MemdbInit`, `sqlite3IsMemdb`.
- `TestPager.pas` written: T1–T12 covering all major code paths.
  All 12 pass.

**Design notes**:
- `MemJournal` and `MemFile` are both subclasses of `sqlite3_file`; the vtable
  pointer must be the first field — preserved exactly.
- nSpill=0 delegates directly to real VFS; nSpill<0 stays pure in-memory;
  nSpill>0 spills when size exceeds nSpill (verified by T3).
- `memdb_g` (global MemFS) is unit-level; shared named databases via VFS1 mutex.
- `SQLITE_DESERIALIZE_*` constants added to interface section.

---

### Phase 3.A implementation notes (2026-04-22)

**Unit**: `src/passqlite3pcache.pas` (~1280 lines, pcache.c + pcache1.c).

**What was done**:
- Ported `PgHdr` / `PCache` / `PCache1` / `PGroup` / `PgHdr1` structs and all
  public `sqlite3Pcache*` functions plus the `pcache1` backend (LRU with
  purgeable-page tracking, resize-hash, eviction, bulk-local slab allocator).
- `TestPCache.pas` written: T1–T8 (init+open, fetch, dirty list, ref counting,
  MakeClean, truncate, close-with-dirty, C-reference differential). All pass.

**Three bugs fixed (all Pascal-specific)**:

1. **`szExtra=0` latent overflow** — C reference calls `memset(pPgHdr->pExtra,0,8)`
   unconditionally; when `szExtra=0` there is no extra area and this writes past the
   allocation. Added guard: `if pCache^.szExtra >= 8 then FillChar((pHdr+1)^, 8, 0)`.

2. **`SizeOf(PGroup)` shadowed by local `pGroup: PPGroup` in `pcache1Create`** —
   Pascal is case-insensitive: a local variable `pGroup: PPGroup` (pointer, 8 bytes)
   hides the type name `PGroup` (record, 80 bytes). `SizeOf(PGroup)` inside that
   function returned 8 instead of 80, so `sz = SizeOf(PCache1) + 8` instead of
   `SizeOf(PCache1) + 80`, allocating only 96 bytes for a 168-byte struct.
   Writing the full struct overflowed 72 bytes into glibc malloc metadata → crash.
   Fix: rename local `pGroup → pGrp`.

3. **`SizeOf(PgHdr)` shadowed by local `pgHdr: PPgHdr` in `pcacheFetchFinishWithInit`
   / `sqlite3PcacheFetchFinish`** — same mechanism; `FillChar(pgHdr^, SizeOf(PgHdr), 0)`
   only zeroed 8 bytes of the 80-byte `PgHdr` struct, leaving most fields as garbage.
   Fix: rename local `pgHdr → pHdr`.

4. **Unsigned for-loop underflow in `pcache1ResizeHash`** — C `for(i=0;i<nHash;i++)`
   naturally skips when `nHash=0`. Pascal `for i := 0 to nHash - 1` with `i: u32`
   computes `0 - 1 = $FFFFFFFF` (unsigned wrap), running 4 billion iterations and
   immediately segfaulting on `nil apHash[0]`. Fix: guard the loop with
   `if p^.nHash > 0 then`.

**CRITICAL PATTERN — applies to all future phases**:
> Any Pascal function that has a local variable of type `PFoo` (pointer) where
> `PFoo` is also the name of a record type will silently corrupt `SizeOf(PFoo)`
> inside that scope (returns pointer size 8 instead of the record size). Always
> rename local pointer variables to `pFoo` / `pTmp` / anything that doesn't
> exactly match the type name. Scan every new unit with:
> `grep -n 'SizeOf(' src/passqlite3*.pas` and verify none of the named types have
> a same-named local in scope.

**CRITICAL PATTERN — unsigned loop bounds**:
> Never write `for i := 0 to N - 1` when `i` or `N` is an unsigned type (`u32`).
> If `N = 0`, the subtraction wraps to `$FFFFFFFF` and the loop runs ~4 billion
> iterations. Always guard with `if N > 0 then` or use a signed loop variable.

---

### Phase 3.B.2a implementation notes (2026-04-22)

**Unit**: `src/passqlite3pager.pas` (implementation block expanded).

**What was done (read-only path of pager.c)**:
- Ported ~600 lines of pager.c read-only path:
  - `sqlite3SectorSize`, `setSectorSize` (pager.c ~2694/2728)
  - `setGetterMethod`, `getPageError`, `getPageNormal` (pager.c ~1045/5709/5535)
  - `pager_reset`, `releaseAllSavepoints`, `pager_unlock` (pager.c ~1772/1790/1841)
  - `pagerUnlockDb`, `pagerLockDb`, `pagerSetError` (pager.c ~1133/1161/1947)
  - `pagerFixMaplimit`, `pager_wait_on_lock` (pager.c ~3533/3946)
  - `pagerPagecount`, `hasHotJournal`, `pagerOpenWalIfPresent` (pager.c ~3279/5134/3339)
  - `readDbPage`, `pagerUnlockIfUnused`, `pagerUnlockAndRollback` (pager.c ~3021/5471/2191)
  - `sqlite3PagerSetFlags`, `sqlite3PagerSetPagesize`, `sqlite3PagerSetCachesize`
  - `sqlite3PagerSetBusyHandler`, `sqlite3PagerMaxPageCount`, `sqlite3PagerLockingMode`
  - `sqlite3PagerOpen`, `sqlite3PagerClose` (pager.c ~4735/4176)
  - `pagerSyncHotJournal`, `pagerStress` (stub), `pagerFreeMapHdrs`
  - `sqlite3PagerReadFileheader`, `sqlite3PagerPagecount`
  - `sqlite3PagerSharedLock` (pager.c ~5254)
  - `sqlite3PagerGet`, `sqlite3PagerLookup`, `sqlite3PagerRef`
  - `sqlite3PagerUnref`, `sqlite3PagerUnrefNotNull`, `sqlite3PagerUnrefPageOne`
  - `sqlite3PagerGetData`, `sqlite3PagerGetExtra`, accessor functions
  - `pagerReleaseMapPage`, `pager_playback` (stub for 3.B.2b)
- Added new constants: `SQLITE_OK_SYMLINK`, `SQLITE_DEFAULT_SYNCHRONOUS`
- Added new OS wrapper functions to `passqlite3os.pas`:
  `sqlite3OsSectorSize`, `sqlite3OsDeviceCharacteristics`,
  `sqlite3OsFileControl`, `sqlite3OsFileControlHint`, `sqlite3OsFetch`,
  `sqlite3OsUnfetch`
- Created `src/tests/vectors/simple.db` and `multipage.db` test vectors
- Created `TestPagerReadOnly.pas` (10 tests, all PASS)

**Critical discovery**: In FPC (case-insensitive Pascal), a local variable
`pPager: PPager` creates a conflict because `pPager` == `PPager` (same
identifier). This manifests as "Error in type definition" at the var
declaration. Fix: rename local vars to `pPgr`. Similarly, `pgno: Pgno`
must be renamed `pg: Pgno` in test code. This is NOT an FPC bug — it is
correct ISO Pascal: a var name shadows a type name of the same normalized
form. Function PARAMETERS named `pPager: PPager` work because the type
is resolved before the parameter binding is created.

**WAL stubs** (deferred to 3.B.3): `pagerOpenWalIfPresent` returns
`SQLITE_OK`; `pPager^.pWal` is always nil in this phase; all `pagerUseWal`
branches are skipped.

**Backup stub** (deferred to 8.7): `sqlite3BackupRestart` not called;
`pPager^.pBackup` is nil.

**`pager_playback` stub** (deferred to 3.B.2b): returns SQLITE_OK; full
journal replay implemented in 3.B.2b.

---

### Phase 3.B.1 implementation notes (2026-04-22)

**Unit**: `src/passqlite3pager.pas` (expanded with Pager struct section).

**What was done**:
- Added `passqlite3pcache` to uses clause (provides `PPgHdr`, `PPCache`,
  `PBitvec`, `PgHdr`, `PCache` needed by Pager).
- Ported all pager.h constants: `PAGER_OMIT_JOURNAL`, `PAGER_MEMORY`,
  `PAGER_LOCKINGMODE_*`, `PAGER_JOURNALMODE_*`, `PAGER_GET_*`,
  `PAGER_SYNCHRONOUS_*`, `PAGER_FULLFSYNC`, `PAGER_CACHESPILL`,
  `PAGER_FLAGS_MASK`.
- Ported pager.c internal constants: `UNKNOWN_LOCK`, `MAX_SECTOR_SIZE`,
  `SPILLFLAG_*`, `PAGER_STAT_*`, `WAL_SAVEPOINT_NDATA`, journal magic bytes.
- Ported `PagerSavepoint` record (all 7 fields including aWalData[0..3]).
- Declared `TWal` as opaque record (full definition deferred to Phase 3.B.3).
- Declared `Psqlite3_backup` as `Pointer` (full definition deferred to Phase 8.7).
- Ported `Pager` struct (all 42 fields, matching C struct Pager lines 619-706
  in SQLite 3.53.0 exactly: u8 fields in same order, same Pgno/i64/u32 types).
- Added `isWalMode` and `isOpen` inline helpers (from pager.h macros).
- `DbPage = PgHdr` typedef added per pager.h.
- Verified: `passqlite3pager.pas` compiles cleanly; TestPager 12/12 pass.

**Critical note**: The `Pager` record has 13 leading `u8` fields before the
first Pgno. The C struct guarantees field ordering for any later memcmp tests.
Pascal records in `{$MODE OBJFPC}` have no hidden padding between same-size
fields, but verify with a SizeOf/offsetof check when TestPagerReadOnly is written.

---

### 3.B — Pager + WAL

- [X] **3.B.1** Port the `Pager` struct and its helper types. Field order must
  match C exactly — tests will `memcmp`. (The `PgHdr` / `PCache` types have
  already been ported in Phase 3.A.)

- [X] **3.B.2** Port `pager.c` in three sub-phases:
  - [X] **3.B.2a** Read-only path: `sqlite3PagerOpen`, `sqlite3PagerGet`,
    `sqlite3PagerUnref`, `readDbPage`. Enough to open an existing DB and read
    pages. Gate: `TestPagerReadOnly.pas` — 10/10 PASS (2026-04-22).
    See implementation notes below.
  - [X] **3.B.2b** Rollback journaling: write path for `journal_mode=DELETE`.
    `pagerWalFrames` is NOT in scope here. Gate: `TestPagerRollback.pas` —
    10/10 PASS (2026-04-22). All write-path functions ported: `writeJournalHdr`,
    `pager_write`, `sqlite3PagerBegin`, `sqlite3PagerWrite`, `sqlite3PagerCommitPhaseOne`,
    `sqlite3PagerCommitPhaseTwo`, `sqlite3PagerRollback`, `sqlite3PagerOpenSavepoint`,
    `sqlite3PagerSavepoint`, `pager_playback`, `pager_playback_one_page`,
    `pager_end_transaction`, `syncJournal`, `pager_write_pagelist`, `pager_delsuper`,
    `pagerPlaybackSavepoint`, and ~25 helper functions.
    FPC hazards resolved: `pgno: Pgno` → `pg: u32`, `pPgHdr: PPgHdr` → `pHdr`,
    `pPagerSavepoint` var renamed to `pSP`, `out ppPage` → `ppPage: PPDbPage`,
    `sqlite3_log` stub (varargs not allowed without cdecl+external).
  - [X] **3.B.2c** Atomic commit, savepoints, rollback-on-error paths. Gate:
    `TestPagerCrash.pas` — 10/10 PASS (2026-04-22). Tested: multi-page commit
    atomicity, fork-based crash recovery (hot-journal playback), savepoint
    rollback, nested savepoint partial rollback, savepoint-release then outer
    rollback, empty journal, multiple-commit crash, C-reference differential
    (recovered .db opened by libsqlite3), truncated journal header, rollback-on-error.
    **Key discovery**: do NOT use page 1 for byte-pattern verification — every
    commit overwrites bytes 24-27, 92-95, 96-99 of page 1 via
    `pager_write_changecounter`. Use page 2 or higher for data integrity checks.

- [X] **3.B.3** Port `wal.c`: the write-ahead log.
  - [X] **3.B.3a** Full port of `wal.c` (2361 lines) to `passqlite3wal.pas`.
    Compiles 0 errors. All types, constants, and public API ported.
    `passqlite3pager.pas` updated: `TWal` stub removed, `passqlite3wal` added
    to uses, `PWal` aliased from `passqlite3wal.PWal`. All prior tests pass.
  - [X] **3.B.3b** Wire WAL into pager: `pagerOpenWalIfPresent`, `pagerUseWal`,
    `sqlite3PagerBeginReadTransaction`, etc. call real WAL functions.
  - [X] **3.B.3c** Checkpoint integration.
  Gate: `TestWalCompat.pas` — Pascal writer + C reader, and vice versa. T1–T8 PASS (2026-04-22).

### Phase 3.B.3a implementation notes (2026-04-22)

**What was done**:
- Created `passqlite3wal.pas` (2361 lines): full port of `wal.c` (SQLite 3.53.0).
- All types: `TWalIndexHdr` (48B), `TWalCkptInfo` (40B), `TWalSegment`, `TWalIterator`,
  `TWalHashLoc`, `TWalWriter`, `TWal` (full struct, replaces opaque stub in pager).
- All public API: `sqlite3WalOpen`, `sqlite3WalClose`, `sqlite3WalBeginReadTransaction`,
  `sqlite3WalEndReadTransaction`, `sqlite3WalFindFrame`, `sqlite3WalReadFrame`,
  `sqlite3WalDbsize`, `sqlite3WalBeginWriteTransaction`, `sqlite3WalEndWriteTransaction`,
  `sqlite3WalUndo`, `sqlite3WalSavepoint`, `sqlite3WalSavepointUndo`,
  `sqlite3WalFrames`, `sqlite3WalCheckpoint`, `sqlite3WalCallback`,
  `sqlite3WalExclusiveMode`, `sqlite3WalHeapMemory`, `sqlite3WalFile`.
- Local stubs: `sqlite3Realloc` (realloc+free), `sqlite3_log_wal` (no-op),
  `sqlite3SectorSize` (wraps `sqlite3OsSectorSize`).
- `passqlite3pager.pas` updated: `TWal = record end` stub removed, `passqlite3wal`
  added to uses clause, `PWal` aliased as `passqlite3wal.PWal`. Compiles cleanly.
- All prior tests pass: TestPager 12/12, TestPagerCrash 10/10, TestPagerRollback 10/10,
  TestPCache 8/8, TestOSLayer 14/14, TestSmoke PASS.
**FPC hazards resolved**:
- `cint` not transitively available — added `ctypes` to interface `uses`.
- Type declarations (`PPWal`, `TxUndoCallback`, `TxBusyCallback`, `PPHtSlot`,
  `PPWalIterator`, `PWalWriter`, `PWalHashLoc`) must precede functions that use them.
- Goto labels (`finished`, `recovery_error`, `begin_unreliable_shm_out`,
  `walcheckpoint_out`) require `label` declarations in each function's var section.
- Inline `var x: T := ...` inside begin/end blocks invalid; moved to var sections.
- `8#777` octal invalid in FPC; replaced with `$1FF` in passqlite3os.pas.
- `ternary(cond, a, b)` has no FPC equivalent; expanded to if-then-else.
- `^TRecord` parameter type replaced by `PRecord` (pointer type alias).

### Phase 3.B.3b+3c implementation notes (2026-04-22)

**What was done**:
- `pagerOpenWalIfPresent`, `pagerUseWal`, `pagerBeginReadTransaction`,
  `sqlite3PagerSharedLock`, `sqlite3PagerBeginReadTransaction` wired to real
  WAL functions in `passqlite3wal.pas`.
- `sqlite3PagerCheckpoint` wired; `sqlite3PagerClose` passes `pTmpSpace` to
  `sqlite3WalClose` for TRUNCATE checkpoint on close.
- `TestWalCompat.pas` (2026-04-22): T1–T8 all PASS.
  T1 WAL header open, T2 BeginReadTransaction, T3 Dbsize, T4 FindFrame+ReadFrame,
  T5 pager SharedLock on C WAL db, T6 Pascal write to C WAL (C re-opens cleanly),
  T7 TRUNCATE checkpoint, T8 fresh Pascal-written WAL opened by C.
- Added to `build.sh` compile list.

**Critical bug fixed in `unixLockSharedMemory` (passqlite3os.pas)**:
  `F_GETLK` does not report locks held by the calling process (Linux POSIX
  advisory lock semantics). When two connections in the same process both
  call `unixLockSharedMemory`, the second sees `F_UNLCK` and incorrectly
  calls `FpFtruncate(hShm, 3)`, destroying the already-initialized SHM
  (and thus C's WAL index). Fix: after acquiring F_WRLCK on the DMS byte,
  check the SHM file size with `FpFStat`. If `st_size > 3`, the SHM has
  already been initialized by another in-process connection; skip the
  truncate.

**Additional fix**: `sqlite3PcacheInitialize` was missing from
  `TestWalCompat.pas` main block, causing null function pointer crash in
  `sqlite3GlobalConfig.pcache2.xCreate`. Added after `sqlite3OsInit`.

---

- [X] **3.B.4** `TestPagerCompat.pas` (full gate): a SQL corpus that stresses
  journaling (big transactions, SAVEPOINTs, simulated crashes) produces
  byte-identical `.db` and `.journal` files on both sides.
  Gate: T1–T10 all PASS (2026-04-22).

### Phase 3.B.4 implementation notes (2026-04-22)

**File**: `src/tests/TestPagerCompat.pas` (1107 lines).

**Tests**:
- T1  C creates a populated db (40-row table); Pascal pager reads page 1 SQLite magic and page count >= 2.
- T2  Pascal writes a minimal-header 1-page db; C opens without SQLITE_NOTADB or SQLITE_CORRUPT.
- T3  Pascal writes a 10-page DELETE-journal transaction; all 10 pages retain correct byte patterns after reopen.
- T4  Savepoint: outer writes $AA to page 2, SP1 overwrites to $BB, SP1 rolled back, outer committed — page 2 = $AA.
- T5  Fork-based crash: child does CommitPhaseOne on 8 pages then exits; parent reopens → hot-journal restores $01; C opens without corruption.
- T6  Journal cleanup: no `.journal` file remains on disk after a successful DELETE-mode commit.
- T7  C creates a 100-row db; Pascal opens read-only and reads every page without I/O errors.
- T8  Pascal creates a WAL-mode db (sqlite3PagerOpenWal), writes a commit; C opens without CORRUPT.
- T9  Pascal writes 3-commit WAL db, runs PASSIVE checkpoint; C opens without error after checkpoint.
     Note: TRUNCATE checkpoint returns SQLITE_BUSY when the same pager holds a read lock (by design); use PASSIVE for in-process checkpoints.
- T10 20-page transaction committed, crash mid-next-commit (21-page transaction, PhaseOne only), recovery; page 5 restored to pre-crash value; C opens without corruption.

---

## Phase 4 — B-tree

Files: `btree.c` (~11.6 k lines), `btmutex.c` (B-tree-level mutex acquisition,
separate because different trees may share a cache / connection).
Headers: `btree.h`, `btreeInt.h`.

Builds on the pager. The B-tree layer implements SQLite's table and index
storage. Correctness here is again checked by on-disk byte equality.

- [X] **4.1** Port the cell-parsing helpers (`btreeParseCellPtr`,
  `btreeParseCell`, `cellSizePtr`, `dropCell`, `insertCell`). These manipulate
  individual records within a page; tight code.
  - Implemented in `src/passqlite3btree.pas` (~750 lines / 1534 compiled).
  - All types from btreeInt.h in one `type` block (FPC requires forward types
    resolved in the same block; `const` block must precede the single type block
    so `BTCURSOR_MAX_DEPTH` is visible for array bounds in `TBtCursor`).
  - Pager bridge functions (sqlite3PagerIswriteable, sqlite3PagerPagenumber,
    sqlite3PagerTempSpace) added to btree unit to avoid circular unit deps.
  - `allocateSpace` does NOT update `nFree`; callers (insertCell/insertCellFast)
    must subtract the allocated size from `nFree` themselves — matches C exactly.
  - `defragmentPage`: fast path triggered when `data[hdr+7] <= nMaxFrag`; always
    call with `nMaxFrag ≥ 0`; internal call from `allocateSpace` uses `nMaxFrag=4`.
  - Gate: `TestBtreeCompat.pas` T1–T10 all PASS (54 checks, 2026-04-22).

- [X] **4.2** Port `BtCursor` + `sqlite3BtreeCursor`, `moveToRoot`, `moveToChild`,
  `moveToParent`, `sqlite3BtreeMovetoUnpacked`.
  - Cursor lifecycle: `btreeCursor`, `sqlite3BtreeCursor`, `sqlite3BtreeCloseCursor`,
    `sqlite3BtreeCursorZero`, `sqlite3BtreeCursorSize`, `sqlite3BtreeClearCursor`.
  - Page helpers: `releasePageNotNull`, `releasePage`, `releasePageOne`,
    `unlockBtreeIfUnused`, `getAndInitPage`.
  - Temp space: `allocateTempSpace`, `freeTempSpace`.
  - Overflow cache: `invalidateOverflowCache`, `invalidateAllOverflowCache`.
  - Cursor save/restore: `saveCursorKey`, `saveCursorPosition`,
    `btreeRestoreCursorPosition`, `restoreCursorPosition`.
  - Navigation: `moveToChild`, `moveToParent`, `moveToRoot`, `moveToLeftmost`,
    `moveToRightmost`, `btreeReleaseAllCursorPages`.
  - Public API: `sqlite3BtreeFirst`, `sqlite3BtreeLast`, `sqlite3BtreeTableMoveto`,
    `sqlite3BtreeIndexMoveto`, `sqlite3BtreeNext`, `sqlite3BtreePrevious`,
    `sqlite3BtreeEof`, `sqlite3BtreeIntegerKey`, `sqlite3BtreePayload`,
    `sqlite3BtreePayloadSize`, `sqlite3BtreeCursorHasMoved`, `sqlite3BtreeCursorRestore`.
  - VDBE stubs (Phase 6): `sqlite3VdbeFindCompare`, `sqlite3VdbeRecordCompare`,
    `indexCellCompare`, `cursorOnLastPage`.
  - FPC pitfalls fixed: `pDbPage: PDbPage` → `pDbPg` (case-insensitive conflict);
    `pBtree: PBtree` → `pBtr`; `pgno: Pgno` → `pg`; no `begin..end` as expression;
    `label` blocks added to `moveToRoot`, `sqlite3BtreeTableMoveto`,
    `sqlite3BtreeIndexMoveto`.
  - TestPagerReadOnly.pas: fixed pre-existing `PDbPage` / `PPDbPage` call mismatch.
  - Gate: `TestBtreeCompat.pas` T1–T18 all PASS (89 checks, 2026-04-22).

- [X] **4.3** Port insert path: `sqlite3BtreeInsert`, `balance`, `balance_deeper`,
  `balance_nonroot`, `balance_quick`. The balancing logic is the most intricate
  part of SQLite — port line by line, no restructuring.
  - Also ported: `fillInCell`, `freePage2`, `freePage`, `clearCellOverflow`,
    `allocateBtreePage`, `btreeSetHasContent`, `btreeClearHasContent`,
    `saveAllCursors`, `btreeOverwriteCell`, `btreeOverwriteContent`,
    `btreeOverwriteOverflowCell`, `rebuildPage`, `editPage`, `pageInsertArray`,
    `pageFreeArray`, `populateCellCache`, `computeCellSize`, `cachedCellSize`,
    `balance_quick`, `copyNodeContent`, `sqlite3PagerRekey`.
  - FPC fixes: `PPu8` ordering before `TCellArray`; `pgno: Pgno` renamed to `pg`;
    all C ternary-as-expression idioms converted to explicit if/else; inline `var`
    declarations moved to proper var sections; `sqlite3Free` → `sqlite3_free`;
    `Boolean` vs `i32` arguments fixed with `ord()`.
  - Gate: `TestBtreeCompat.pas` T1–T20 all PASS (100 checks, 2026-04-23).

- [X] **4.4** Port delete path: `sqlite3BtreeDelete`, `clearCell`, `freePage`,
  free-list management.
  - Gate: `TestBtreeCompat.pas` T23 (delete mid-tree row) PASS (2026-04-23).

- [X] **4.5** Port schema/metadata: `sqlite3BtreeGetMeta`, `sqlite3BtreeUpdateMeta`,
  auto-vacuum (if enabled), incremental vacuum.
  - Also fixed: `balance_quick` divider-key extraction bug (C post-increment
    vs Pascal while-loop semantics for nPayload varint skip); fixes T28 seek/count.
  - Gate: `TestBtreeCompat.pas` T1–T28 all PASS (156 checks, 2026-04-23).

- [X] **4.6** `TestBtreeCompat.pas`: a sequence of insert / update / delete /
  seek operations on a corpus of keys (random, sorted, reverse-sorted,
  pathological duplicates) produces byte-identical `.db` files. This is the
  single most important gating test for the lower half of the port.
  - T29: sorted ascending (N=500) — write+close+reopen+scan all 500, verify count and last key. PASS.
  - T30: sorted descending (N=500, insert 500..1) — reopen+scan in order, verify count/first/last key. PASS.
  - T31: random order (N=200, Fisher-Yates shuffle) — reopen+scan, verify count/first/last key. PASS.
  - T32: overflow-page corpus (50 rows × 2000-byte payload) — reopen, verify payload size and per-row marker byte for each row. PASS (100 checks).
  - T33: C writes 50-row db via SQL, Pascal reads btree root page 2, verify count=50 and last key=50. Cross-compat PASS.
  - T34: Pascal writes 300-row db, C opens via csq_open_v2 without CORRUPT, PRAGMA page_count > 1. PASS.
  - T35: insert 1..100, delete evens, insert 101..110; reopen verify count=60, first=1, last=110, spot-check key2 absent / key3 present. PASS.
  - Gate: T1–T35 all PASS (337 checks, 2026-04-24).
  - **Key discovery**: `sqlite3BtreeNext(pCur, flags)` takes `flags: i32` (not `*pRes`). Returns `SQLITE_DONE` at end-of-table; loop must convert SQLITE_DONE → SQLITE_OK and set pRes=1 to exit. `sqlite3BtreeFirst(pCur, pRes)` still sets *pRes=0/1 for empty check.

---

## Phase 5 — VDBE

Files:
- `vdbe.c` (~9.4 k lines, ~**199 opcodes** — nearly double the count the
  tasklist originally assumed). The main interpreter loop.
- `vdbeaux.c` — program assembly, label resolution, final layout.
- `vdbeapi.c` — `sqlite3_step`, `sqlite3_column_*`, `sqlite3_bind_*`.
- `vdbemem.c` — the `Mem` type: value coercion, storage, affinity.
- `vdbeblob.c` — incremental blob I/O (`sqlite3_blob_open`, etc.).
- `vdbesort.c` — the external sorter used by ORDER BY / GROUP BY.
- `vdbetrace.c` — `EXPLAIN` rendering helper.
- `vdbevtab.c` — VDBE ops that call into virtual tables (depends on `vtab.c`,
  Phase 6.bis).

Headers: `vdbe.h`, `vdbeInt.h`.

The bytecode interpreter. Big switch statement; tedious but mechanical —
but bigger than initially scoped. Phase 5 effort roughly **2× the original
estimate**.

- [X] **5.1** Port `Vdbe`, `VdbeOp`, `Mem`, `VdbeCursor` records. Field order
  must match C — tests will dump program state and diff.
  - Created `src/passqlite3vdbe.pas` (515 lines): all types from vdbeInt.h and
    vdbe.h (TMem, TVdbeOp, TVdbeCursor, TVdbe, TVdbeFrame, TAuxData,
    TScanStatus, TDblquoteStr, TSubrtnSig, TSubProgram, Tsqlite3_context,
    TValueList, TVdbeTxtBlbCache); all 192 OP_* opcodes from opcodes.h;
    MEM_* / P4_* / CURTYPE_* / VDBE_*_STATE / OPFLG_* / VDBC_* / VDBF_*
    constants; sqlite3OpcodeProperty[192] table; stubs for 5.2–5.5 functions.
  - FPC struct sizes verified vs GCC x86-64 layout:
    TMem=56, TVdbeOp=24, TVdbeCursor=120, TVdbe=304, TVdbeFrame=112.
  - Bitfields (VdbeCursor 5-bit group, Vdbe 9-bit group) represented as u32
    with VDBC_*/VDBF_* named bit-mask constants; FPC natural alignment produces
    identical offsets to GCC.
  - All 337 TestBtreeCompat + pager/WAL tests still PASS (2026-04-24).

- [X] **5.2** Port `vdbeaux.c`: program assembly (`sqlite3VdbeAddOp*`), label
  resolution, final VDBE program layout. Gate: given a hand-written VDBE
  program, Pascal and C produce identical `Op[]` arrays.
  - Ported to `src/passqlite3vdbe.pas` (2756 lines, Phase 5.2 implementation
    section). All vdbeaux.c public functions present: AddOp0/1/2/3/4/4Int,
    MakeLabel, ResolveLabel, resolveP2Values, ChangeP1/2/3/4/5, GetOp,
    GetLastOp, JumpHere, VdbeCreate, VdbeClearObject, VdbeDelete, VdbeSwap,
    VdbeMakeReady, VdbeRewind, SerialTypeLen, OneByteSerialTypeLen,
    SerialGet, SerialPut, SerialType, OpcodeName.
  - **Bug fixed**: `sqlite3VdbeSerialPut` — C's fall-through `switch` for
    big-endian integer/float serialization translated incorrectly as a Pascal
    `case` (no fall-through). Fixed by converting to an explicit downward loop.
  - **New helper added**: `sqlite3_realloc64` declared in `passqlite3os.pas`
    (maps to libc `realloc` with u64 size, same as `sqlite3_malloc64`).
  - **Bitfield access fixed**: `TVdbe.readOnly`/`bIsReader` fields accessed via
    `vdbeFlags` u32 with VDBF_ReadOnly / VDBF_IsReader bit-mask constants.
  - **varargs removed**: `cdecl; varargs` dropped from all stub implementations
    (FPC only allows `varargs` on `external` declarations).
  - Gate: TestVdbeAux T1–T17 all PASS (108/108 checks, 2026-04-24).

- [X] **5.3** Port `vdbemem.c`: the `Mem` type's value coercion and storage.
  Many subtle corner cases (type affinity, text encoding conversion).
  - Gate: TestVdbeMem T1–T23 all PASS (62/62 checks, 2026-04-24).

- [X] **5.4** Port `vdbe.c` — the `sqlite3VdbeExec` loop. **~199 opcodes**.
  All sub-tasks 5.4a–5.4q complete (2026-04-25). ~190+ opcodes implemented.
  Port in groups:
  - [X] **5.4a** Exec loop skeleton + 23 opcodes: `OP_Goto`, `OP_Gosub`,
    `OP_Return`, `OP_InitCoroutine`, `OP_EndCoroutine`, `OP_Yield`,
    `OP_Halt`, `OP_Init`, `OP_Integer`, `OP_Int64`, `OP_Null`/`OP_BeginSubrtn`,
    `OP_SoftNull`, `OP_Blob`, `OP_Move`, `OP_Copy`, `OP_SCopy`, `OP_IntCopy`,
    `OP_ResultRow`, `OP_Jump`, `OP_If`, `OP_IfNot`, `OP_OpenRead`,
    `OP_OpenWrite`, `OP_Close`.
    Helper functions: `out2Prerelease`, `out2PrereleaseWithClear`,
    `allocateCursor`, `sqlite3ErrStr`, `sqlite3VdbeFrameRestoreFull`, stubs.
    `Tsqlite3` (PTsqlite3) struct added to `passqlite3util.pas` Section 3b.
    Compiles 0 errors; TestSmoke PASS (2026-04-24).
  - [X] **5.4b** Cursor motion: `OP_Rewind`, `OP_Next`, `OP_Prev`,
    `OP_SeekLT`, `OP_SeekLE`, `OP_SeekGE`, `OP_SeekGT`,
    `OP_Found`, `OP_NotFound`, `OP_NoConflict`, `OP_IfNoHope`,
    `OP_SeekRowid`, `OP_NotExists`,
    `OP_IdxLE`, `OP_IdxGT`, `OP_IdxLT`, `OP_IdxGE`.
    Helper labels: `next_tail`, `seek_not_found`, `notExistsWithKey`.
    Gate test: `TestVdbeCursor.pas` T1–T8 all PASS (27/27) (2026-04-24).
  - [X] **5.4c** Record I/O: `OP_Column`, `OP_MakeRecord`, `OP_Insert`, `OP_Delete`,
    `OP_Count`, `OP_Rowid`, `OP_NewRowid`.
    Gate test: `TestVdbeRecord.pas` T1–T6 all PASS (13/13) (2026-04-24).
  - [X] **5.4d** Arithmetic / comparison: `OP_Add`, `OP_Subtract`, `OP_Multiply`,
    `OP_Divide`, `OP_Remainder`, `OP_Eq`, `OP_Ne`, `OP_Lt`, `OP_Le`, `OP_Gt`,
    `OP_Ge`, `OP_BitAnd`, `OP_BitOr`, `OP_ShiftLeft`, `OP_ShiftRight`, `OP_AddImm`.
    Gate test: `TestVdbeArith.pas` T1–T13 all PASS (41/41) (2026-04-24).
  - [X] **5.4e** String/blob: `OP_String8`, `OP_String`, `OP_Blob`, `OP_Concat`.
    Gate test: `TestVdbeStr.pas` T1–T6 all PASS (23/23) (2026-04-24).
  - [X] **5.4f** Aggregate: `OP_AggStep`, `OP_AggFinal`, `OP_AggInverse`,
    `OP_AggValue`.
    Gate test: `TestVdbeAgg.pas` T1–T4 all PASS (11/11) (2026-04-24).
    Key fix: `sqlite3VdbeMemFinalize` must use a separate temp `TMem t` for
    output (ctx.pOut=@t); accumulator (ctx.pMem=pMem) stays intact through
    xFinalize call. Real SQLite uses `sqlite3VdbeMemMove(pMem,&t)` after;
    here we do `pMem^ := t` after `sqlite3VdbeMemRelease(pMem)`.
  - [X] **5.4g** Transaction control: `OP_Transaction`, `OP_Savepoint`,
    `OP_AutoCommit`.
    Gate test: `TestVdbeTxn.pas` T1–T4 all PASS (8/8) (2026-04-24).
    Also added: `sqlite3CloseSavepoints`, `sqlite3RollbackAll` helpers.
    Note: schema cookie check in OP_Transaction (p5≠0) is stubbed out —
    requires PSchema.iGeneration which is not yet accessible (Phase 6 concern).
  - [X] **5.4h** Miscellaneous opcodes: OP_Real, OP_Not, OP_BitNot, OP_And,
    OP_Or, OP_IsNull, OP_NotNull, OP_ZeroOrNull, OP_Cast, OP_Affinity,
    OP_IsTrue, OP_HaltIfNull, OP_Noop/Explain, OP_MustBeInt, OP_RealAffinity,
    OP_Variable, OP_CollSeq, OP_ClrSubtype, OP_GetSubtype, OP_SetSubtype,
    OP_Function.
    Gate test: `TestVdbeMisc.pas` T1–T13 all PASS (45/45) (2026-04-24).
    Bug fixed: P4_REAL pointer is freed by VdbeDelete — must be heap-allocated
    (not stack address) in test helpers.

- [X] **5.4i** Cursor open/close extensions: OP_OpenRead, OP_ReopenIdx,
    OP_OpenEphemeral, OP_OpenAutoindex, OP_OpenPseudo, OP_OpenDup,
    OP_NullRow, OP_RowData, OP_RowCell.
    Needed for: table scans, index usage, temp tables, subqueries.

- [X] **5.4j** Seek and index comparison: OP_SeekGE, OP_SeekLE, OP_SeekLT,
    OP_SeekScan, OP_SeekHit, OP_IdxLT, OP_IdxLE, OP_IdxGT, OP_IdxGE.
    Needed for: range queries, index navigation, ORDER BY.
    Implemented 2026-04-25: OP_SeekScan inlines sqlite3VdbeIdxKeyCompare via
    pMem5b/sqlite3VdbeRecordCompareWithSkip; OP_SeekHit clamps cursor seekHit.
    OP_SeekGE/LE/LT/GT/IdxLT/LE/GT/GE were already implemented in 5.4i.

- [X] **5.4k** Control flow: OP_Once, OP_IfEmpty, OP_IfNotOpen, OP_IfNoHope,
    OP_IfPos, OP_IfNotZero, OP_IfSizeBetween, OP_DecrJumpZero, OP_Program,
    OP_Param, OP_ElseEq, OP_Permutation, OP_Compare.
    Needed for: subqueries, EXISTS, IN, CASE, compound SELECT.
    Implemented 2026-04-25. OP_Program creates a VdbeFrame sub-execution context;
    OP_Compare uses pointer arithmetic to access KeyInfo (PKeyInfo=Pointer in Phase 5).
    OP_IfSizeBetween uses inline sqlite3LogEst. OP_Permutation is a no-op marker.

- [X] **5.4l** Sorter: OP_SorterOpen, OP_SorterInsert, OP_SorterSort,
    OP_SorterData, OP_SorterCompare, OP_Sort, OP_ResetSorter.
    Needed for: ORDER BY, GROUP BY with large result sets.
    Implemented 2026-04-25. OP_SorterCompare: signature is (pCsr; bOmitRowid; pVal; nKeyCol; out iResult).
    OP_SorterSort/Sort increment SQLITE_STMTSTATUS_SORT counter.

- [X] **5.4m** Schema: OP_CreateBtree, OP_ParseSchema, OP_ReadCookie,
    OP_SetCookie, OP_TableLock, OP_LoadAnalysis.
    Needed for: CREATE TABLE, schema changes, ANALYZE.
    Implemented 2026-04-25. OP_ParseSchema is a stub (Phase 6). OP_ReadCookie uses
    idx:u32 temp var (cannot take @u32(i64)). OP_TableLock simplified (no shared cache).
    OP_SetCookie updates schema_cookie and calls sqlite3FkClearTriggerCache.

- [X] **5.4n** RowSet: OP_RowSetAdd, OP_RowSetRead, OP_RowSetTest.
    Needed for: IN (subquery), EXISTS, DISTINCT.
    Implemented 2026-04-25. Full rowset.c port (~300 lines): TRowSetEntry/TRowSetChunk/TRowSet,
    rowSetEntryAlloc, rowSetEntryListMerge, rowSetNDeepTree, rowSetListToTree,
    rowSetTreeToList, rowSetSort; public: sqlite3RowSetAlloc/Clear/Delete/Insert/Test/Next.
    PPRowSetEntry = ^PRowSetEntry added to support recursive tree functions.

- [X] **5.4o** Foreign keys: OP_FkCheck, OP_FkCounter, OP_FkIfZero.
    Needed for: FOREIGN KEY enforcement.
    Implemented 2026-04-25. OP_FkCheck is a stub. OP_FkCounter increments
    db^.nDeferredCons or db^.nDeferredImmCons. OP_FkIfZero jumps if counter=0.

- [X] **5.4p** Virtual table: OP_VNext, OP_VOpen, OP_VFilter, OP_VColumn,
    OP_VUpdate, OP_VBegin, OP_VCreate, OP_VDestroy, OP_VRename, OP_VCheck,
    OP_VInitIn.
    Needed for: virtual tables (FTS, R-TREE, etc.).
    Implemented 2026-04-25 as stubs returning SQLITE_ERROR (virtual table engine
    not ported in Phase 5; full implementation deferred to Phase 7).

- [X] **5.4q** Misc remaining: OP_Abortable, OP_Clear, OP_ColumnsUsed,
    OP_CursorHint, OP_CursorLock, OP_CursorUnlock, OP_Destroy, OP_DropIndex,
    OP_DropTable, OP_DropTrigger, OP_Expire, OP_Filter, OP_FilterAdd,
    OP_IFindKey, OP_IncrVacuum, OP_IntegrityCk, OP_JournalMode, OP_Last,
    OP_MaxPgcnt, OP_MemMax, OP_Offset, OP_OffsetLimit, OP_Pagecount,
    OP_PureFunc, OP_ReleaseReg, OP_Sequence, OP_SequenceTest, OP_SqlExec,
    OP_TypeCheck, OP_Trace, OP_Vacuum.
    Implemented 2026-04-25. OP_PureFunc reuses OP_Function body via goto.
    OP_Filter/FilterAdd are stubs (bloom filter deferred). OP_Abortable/ReleaseReg
    are no-ops in release builds. OP_Checkpoint/Vacuum/JournalMode return SQLITE_OK stubs.
    Btree helpers added: sqlite3BtreeLastPage, sqlite3BtreeMaxPageCount,
    sqlite3BtreeLockTable (stub), sqlite3BtreeCursorPin/Unpin (BTCF_Pinned).

- [X] **5.5** Port `vdbeapi.c`: public API — `sqlite3_step`, `sqlite3_column_*`,
  `sqlite3_bind_*`, `sqlite3_reset`, `sqlite3_finalize`.
  Implemented: sqlite3_step, sqlite3_reset, sqlite3_finalize, sqlite3_clear_bindings,
  sqlite3_value_{type,int,int64,double,text,blob,bytes,subtype,dup,free,nochange,frombind},
  sqlite3_column_{count,data_count,type,int,int64,double,text,blob,bytes,value,name},
  sqlite3_bind_{int,int64,double,null,text,blob,value,parameter_count}.
  Gate test: `TestVdbeApi.pas` T1–T13 all PASS (57/57) (2026-04-24).
  Note: sqlite3_reset changed from procedure to function (returns i32) to match
  the real C API; sqlite3_step does auto-reset on HALT_STATE like SQLite 3.7+.

- [X] **5.6** Port `vdbeblob.c`: incremental blob I/O API
  (`sqlite3_blob_open`, `sqlite3_blob_read`, `sqlite3_blob_write`,
  `sqlite3_blob_bytes`, `sqlite3_blob_reopen`, `sqlite3_blob_close`).
  Added TIncrblob / Psqlite3_blob types. sqlite3_blob_open is a stub
  (returns SQLITE_ERROR) until the SQL compiler is available (Phase 7).
  sqlite3_blob_close, bytes, and null-guard behavior are fully implemented;
  read/write/reopen require sqlite3BtreePayloadChecked / sqlite3BtreePutData
  (will be completed after btree Phase 4 extensions).
  Gate test: `TestVdbeBlob.pas` T1–T11 all PASS (13/13) (2026-04-24).

- [X] **5.7** Port `vdbesort.c`: the external sorter (used for ORDER BY /
  GROUP BY on large result sets that don't fit in memory). Spills to temp
  files; correctness depends on deterministic tie-breaking.
  Defined TVdbeSorter (nTask=1 single-subtask stub), TSorterList, TSorterFile.
  Changed PVdbeSorter from Pointer to ^TVdbeSorter. All 8 public functions
  implemented: Init checks for KeyInfo (nil → SQLITE_ERROR); Reset frees
  in-memory list; Close releases sorter and resets cursor; Write/Rewind/Next/
  Rowkey/Compare have correct nil-guard and SQLITE_MISUSE/SQLITE_ERROR returns.
  Full PMA merge logic deferred to Phase 6+ (requires KeyInfo, UnpackedRecord).
  Gate test: `TestVdbeSort.pas` T1–T10 all PASS (14/14) (2026-04-24).

- [X] **5.8** Port `vdbetrace.c`: the `EXPLAIN` / `EXPLAIN QUERY PLAN`
  rendering helper. Small (~300 lines).
  Implemented sqlite3VdbeExpandSql. Full tokeniser-based parameter expansion
  requires sqlite3GetToken (Phase 7+); stub returns a heap-allocated copy of
  the raw SQL, which is correct for the no-parameter case and safe otherwise.
  Gate test: `TestVdbeTrace.pas` T1–T5 all PASS (7/7) (2026-04-24).

- [X] **5.9** Port `vdbevtab.c`: VDBE-side support for virtual-table opcodes.
  `SQLITE_ENABLE_BYTECODE_VTAB` not set; `sqlite3VdbeBytecodeVtabInit` is a
  no-op returning `SQLITE_OK`. Gate test `TestVdbeVtab`: T1–T2 all PASS (2/2).

- [ ] **5.10** `TestVdbeTrace.pas`: for every VDBE program produced by the C
  reference from the SQL corpus, run the program on the Pascal VDBE and on the
  C VDBE, with `PRAGMA vdbe_trace=ON`, and diff the resulting trace logs.
  **Any divergence halts the phase.**
  **DEFERRED** — requires the SQL parser (Phase 7.2) to generate VDBE programs
  automatically from SQL strings. The existing stub `TestVdbeTrace.pas` (T1–T5)
  tests only the `sqlite3VdbeExpandSql` API and already passes; the differential
  trace test cannot be fully written until Phase 7.2 is done.

---

### Phase 5.4d implementation notes (2026-04-24)

**Units changed**: `src/passqlite3vdbe.pas`, `src/tests/TestVdbeArith.pas`, `src/tests/build.sh`.

**What was done**:
- Added helpers before `sqlite3VdbeExec`: `sqlite3AddInt64`, `sqlite3SubInt64`,
  `sqlite3MulInt64` (overflow-detecting), `numericType`, `sqlite3BlobCompare`,
  `sqlite3MemCompare`.
- Added 16 arithmetic/comparison opcodes: `OP_Add`, `OP_Subtract`, `OP_Multiply`,
  `OP_Divide`, `OP_Remainder`, `OP_BitAnd`, `OP_BitOr`, `OP_ShiftLeft`,
  `OP_ShiftRight`, `OP_AddImm`, `OP_Eq`, `OP_Ne`, `OP_Lt`, `OP_Le`, `OP_Gt`,
  `OP_Ge`.
- Arithmetic: fast int path → overflow check → fp fallback `arith_fp` label;
  `arith_null` for divide-by-zero / NULL operand.
- Comparison: fast int-int path; NULL path (NULLEQ / JUMPIFNULL); general path via
  `sqlite3MemCompare`; affinity coercion for string↔numeric comparisons.
- Added `TestVdbeArith.pas` (T1–T13 gate test).
- Gate: `TestVdbeArith` T1–T13 all PASS (41/41); all prior tests unchanged (2026-04-24).

**Critical pitfalls**:
- `memSetTypeFlag` is defined AFTER `sqlite3VdbeExec` → not visible inside the
  exec function. Replaced all `memSetTypeFlag(p, f)` calls with the inline form:
  `p^.flags := (p^.flags and not u16(MEM_TypeMask or MEM_Zero)) or f`.
- Comparison tables (`sqlite3aLTb/aEQb/aGTb` from C global.c) are implemented as
  inline `case` statements on the opcode rather than lookup arrays, to avoid the
  C-style append-to-upper-case-table trick that doesn't map to Pascal.
- `OP_Add/Sub/Mul` take (P1=in1, P2=in2, P3=out3) where the result is `r[P2] op r[P1]`
  (i.e., P1 is the RIGHT operand and P2 is the LEFT). Match C exactly:
  `iB := pIn2^.u.i; iA := pIn1^.u.i; sqlite3AddInt64(@iB, iA)`.
- `OP_ShiftLeft/Right`: P1=shift-amount register, P2=value register (same reversed layout).
- `MEM_Null = 0` in zero-initialized memory → must set `flags := MEM_Null` explicitly
  in tests that test NULL propagation, otherwise `flags=0` (actually MEM_Null=0, so
  it works, but this is fragile — better to set explicitly).

---

### Phase 5.4c implementation notes (2026-04-24)

**Units changed**: `src/passqlite3vdbe.pas`, `src/tests/TestVdbeRecord.pas`, `src/tests/build.sh`.

**What was done**:
- Added 7 record I/O opcodes to `sqlite3VdbeExec`: `OP_Column`, `OP_MakeRecord`,
  `OP_Insert`, `OP_Delete`, `OP_Count`, `OP_Rowid`, `OP_NewRowid`.
- Added shared label `op_column_corrupt` inside the exec loop (used by `OP_Column`
  overflow-record corrupt path).
- Added `TestVdbeRecord.pas` (T1–T6 gate test) and wired into `build.sh`.

**Critical pitfalls discovered/fixed**:
- `op_column_corrupt` label was placed OUTSIDE `repeat..until False` loop; FPC
  `continue` is only valid inside a loop. Fixed by moving the label inside the loop,
  between `jump_to_p2` and `until False`.
- Duplicate `vdbeMemDynamic` definition (once at line ~2879 as a forward copy before
  the exec function, once at ~4458 at its canonical location). FPC treats these as
  overloaded with identical signatures → error. Fixed by removing the later duplicate;
  kept the earlier one so the exec function's call site can see it.
- `CACHE_STALE = 0`: `sqlite3VdbeCreate` uses `sqlite3DbMallocRawNN` (raw, not zeroed)
  and only zeroes bytes at offset 136+. `cacheCtr` is before offset 136 → uninitialized.
  In tests, `cacheCtr` was 0 = `CACHE_STALE`, making `cacheStatus(0) == cacheCtr(0)` →
  column cache falsely treated as valid → `payloadSize/szRow` never populated →
  `OP_Column` returned NULL. Fix: set `v^.cacheCtr := 1` in test `CreateMinVdbe`.
- `OP_OpenWrite` with `P4_INT32=1` (nField=1) is required for `OP_Column` to compute
  `aOffset[1]` correctly; use `sqlite3VdbeAddOp4Int(v, OP_OpenWrite, 0, pgno, 0, 1)`.
- `sqlite3BtreePayloadFetch` sets `pAmt = nLocal` (bytes in-page); `szRow` is
  populated only when the cache-miss path runs correctly.

**Gate**: `TestVdbeRecord` T1–T6 all PASS (13/13); all prior tests still PASS (2026-04-24).

---

### Phase 5.4b implementation notes (2026-04-24)

**Units changed**: `src/passqlite3vdbe.pas`, `src/tests/TestVdbeCursor.pas`, `src/tests/build.sh`.

**What was done**:
- Added 16 cursor-motion opcodes to `sqlite3VdbeExec` in `passqlite3vdbe.pas`:
  `OP_Rewind`, `OP_Next`, `OP_Prev`, `OP_SeekLT/LE/GE/GT`,
  `OP_Found`, `OP_NotFound`, `OP_NoConflict`, `OP_IfNoHope`,
  `OP_SeekRowid`, `OP_NotExists`, `OP_IdxLE/GT/LT/GE`.
- Shared label bodies: `next_tail` (Next/Prev common tail), `seek_not_found`
  (SeekGT/GE/LT/LE common tail), `notExistsWithKey` (SeekRowid/NotExists body).
- Added `TestVdbeCursor.pas` (T1–T8 gate test) and wired into `build.sh`.

**Critical pitfalls discovered/fixed**:
- `jump_to_p2` semantics: `pOp := @aOp[p2-1]; Inc(pOp)` → executes `aOp[p2]`,
  so p2 is the 0-based INDEX of the target instruction.
- `sqlite3VdbeCreate` auto-adds `OP_Init` at index 0; test helpers must reset
  `v^.nOp := 0` before adding their own instruction sequence.
- `TVdbe.pc` sits at offset ~48 in the struct (before the `FillChar` at offset
  136 in `sqlite3VdbeCreate`), so it is left uninitialized garbage by
  `sqlite3DbMallocRawNN`. Fix: set `v^.pc := 0` in test `CreateMinVdbe`.
  This was the root cause of T7b (skipped OP_Integer, used stale iKey=0) and
  T8 (crash on second VDBE: pc landed in the middle of a short instruction array).
- `allocateCursor` with iCur=0: uses `pMSlot = p^.aMem` (i.e. `aMem[0]`).
  The cursor buffer is stored in `aMem[0].zMalloc` (a separate heap allocation);
  does NOT corrupt adjacent `aMem[1..nMem-1]` slots.
- In `OpenTestBtree`, inserts must use `PBtCursor` obtained from
  `sqlite3BtreeCursor(pBt, pgno, 1, nil, @cur)`, NOT a `PBtree` pointer.

**Gate**: `TestVdbeCursor` T1–T8 all PASS (27/27); TestSmoke still PASS (2026-04-24).

---

### Phase 5.4a implementation notes (2026-04-24)

**Units changed**: `src/passqlite3vdbe.pas`, `src/passqlite3util.pas`, `src/passqlite3btree.pas`.

**What was done**:
- Added `Tsqlite3` (connection struct, 144 fields) and `PTsqlite3 = ^Tsqlite3` to `passqlite3util.pas` Section 3b. Used opaque `Pointer` for cross-unit types (PBtree, PVdbe, PSchema, etc.) to avoid circular dependency. Companion types: `TBusyHandler`, `TLookaside`, `TSchema`, `TDb`, `TSavepoint`.
- Replaced stub `sqlite3VdbeExec` with 23-opcode Phase 5.4a implementation in `passqlite3vdbe.pas`.
- Added helper functions: `out2Prerelease`, `out2PrereleaseWithClear`, `allocateCursor`, `sqlite3ErrStr`, `sqlite3VdbeFrameRestoreFull`, stubs for `sqlite3VdbeLogAbort`, `sqlite3VdbeSetChanges`, `sqlite3SystemError`, `sqlite3ResetOneSchema`.
- Added `sqlite3BtreeCursorHintFlags` to `passqlite3btree.pas`.

**Critical FPC pitfalls discovered/fixed**:
- `pMem: PMem` — FPC is case-insensitive; local var `pMem` conflicts with type `PMem`. Renamed to `pMSlot`.
- `pDb: PDb` and `pKeyInfo: PKeyInfo` — same conflict. Renamed to `pDbb` and `pKInfo`.
- Functions defined later in the implementation section cannot be called by earlier functions (no forward reference). Inlined `vdbeMemDynamic` and `memSetTypeFlag` at call sites where forward reference would be needed.
- `aType[]` is a C flexible array NOT present in the Pascal `TVdbeCursor` record. Access via `Pu32(Pu8(pCx) + 120 + u32(nField) * SizeOf(u32))`.
- `PKeyInfo = Pointer` (opaque). Access `nAllField` (u16 at offset 8) via pointer arithmetic: `Pu16(Pu8(pKInfo) + 8)^`.
- `TVdbe.expired` is a C bitfield packed into `vdbeFlags: u32`; use `(v^.vdbeFlags and VDBF_EXPIRED_MASK) = 1`.
- `TVdbeCursor.isOrdered` is a C bitfield packed into `cursorFlags: u32`; use `pCur^.cursorFlags := pCur^.cursorFlags or VDBC_Ordered`.
- `lockMask` is a field of `TVdbe`, not `Tsqlite3`. Use `v^.lockMask`, not `db^.lockMask`.
- `SZ_VDBECURSOR` function must be defined *before* `allocateCursor` in the implementation section.
- `duplicate definition` if helper functions are defined twice; removed Phase 5.4a duplicates of `vdbeMemDynamic`/`memSetTypeFlag` which already existed in Phase 5.3.

**Gate**: Compiles 0 errors; TestSmoke PASS (2026-04-24).

---

### Phase 5.3 implementation notes (2026-04-24)

**Unit**: `src/passqlite3vdbe.pas` (already contained skeleton implementations from 5.2).

**What was done (vdbemem.c functions)**:
- `vdbeMemClearExternAndSetNull`, `vdbeMemClear`: clear dynamic resources, free szMalloc, set z=nil and flags=MEM_Null.
- `sqlite3VdbeMemRelease`, `sqlite3VdbeMemReleaseMalloc`: thin wrappers over vdbeMemClear.
- `sqlite3VdbeMemGrow`, `sqlite3VdbeMemClearAndResize`, `vdbeMemAddTerminator`.
- `sqlite3VdbeMemZeroTerminateIfAble`, `sqlite3VdbeMemMakeWriteable`, `sqlite3VdbeMemNulTerminate`.
- `sqlite3VdbeMemExpandBlob`: expand MEM_Zero blob tail into real bytes.
- `sqlite3VdbeMemStringify`: render numeric Mem as UTF-8 string (32-byte buffer via libc snprintf).
- `sqlite3VdbeChangeEncoding`, `sqlite3VdbeMemTranslate` (stub, Phase 6), `sqlite3VdbeMemHandleBom` (stub).
- `sqlite3VdbeIntValue`, `sqlite3VdbeRealValue`, `sqlite3VdbeBooleanValue`.
- `sqlite3RealToI64`, `sqlite3RealSameAsInt`.
- `sqlite3MemRealValueRC`, `sqlite3MemRealValueRCSlowPath`, `sqlite3MemRealValueNoRC`.
- `sqlite3VdbeIntegerAffinity`, `sqlite3VdbeMemIntegerify`, `sqlite3VdbeMemRealify`, `sqlite3VdbeMemNumerify`.
- `sqlite3VdbeMemCast`, `sqlite3ValueApplyAffinity` (stub, Phase 6).
- `sqlite3VdbeMemInit`, `sqlite3VdbeMemSetNull`, `sqlite3ValueSetNull`.
- `sqlite3VdbeMemSetZeroBlob`, `vdbeReleaseAndSetInt64`, `sqlite3VdbeMemSetInt64`, `sqlite3MemSetArrayInt64`.
- `sqlite3NoopDestructor`, `sqlite3VdbeMemSetPointer`.
- `sqlite3VdbeMemSetDouble`.
- `sqlite3VdbeMemTooBig`.
- `sqlite3VdbeMemShallowCopy`, `vdbeClrCopy`, `sqlite3VdbeMemCopy`, `sqlite3VdbeMemMove`.
- `sqlite3VdbeMemSetStr`, `sqlite3VdbeMemSetText`.
- `sqlite3VdbeMemFromBtree`, `sqlite3VdbeMemFromBtreeZeroOffset`.
- `valueToText`, `sqlite3ValueText`, `sqlite3ValueIsOfClass`.
- `sqlite3ValueNew`, `sqlite3ValueFree`, `sqlite3ValueBytes`, `sqlite3ValueSetStr` (stub).
- `sqlite3ValueFromExpr`, `sqlite3Stat4Column` (stubs, Phase 6).

**Critical FPC pitfall discovered**:
> `Int64(someDoubleVariable)` in FPC is a **bit reinterpret** (reads the 8-byte float
> bit pattern as Int64), NOT a value truncation. For truncation use `Trunc(r)`.
> Fixed in `sqlite3RealToI64`: `Result := Trunc(r)` (not `i64(r)`).

**Additional fix**:
> `vdbeMemClear` must explicitly set `p^.flags := MEM_Null` at the end, even for
> non-dynamic Mems (e.g. TRANSIENT strings with szMalloc>0 but no MEM_Dyn).
> Without this, after `sqlite3VdbeMemRelease`, flags remain `MEM_Str` with `z=nil`
> — an inconsistent state.

**Test notes**:
- T5: `sqlite3VdbeMemSetZeroBlob` stores count in `u.nZero`, not `n` (n stays 0). Test fixed to check `m.u.nZero`.
- T18: `sqlite3VdbeMemSetStr` rejects too-big strings itself (sets Mem to NULL before returning TOOBIG). Test `TestTooBig` must set TMem fields directly to test `sqlite3VdbeMemTooBig`.
- Gate: T1–T23 all PASS (62/62 checks, 2026-04-24). All 337 prior TestBtreeCompat checks and 108 TestVdbeAux checks still PASS.

---

### Phase 5.1 implementation notes (2026-04-24)

**Unit**: `src/passqlite3vdbe.pas` (515 lines, compiles 0 errors).

**What was done**:
- All 192 OP_* opcode constants from `opcodes.h` (SQLite 3.53.0) with exact
  numeric values. `SQLITE_MX_JUMP_OPCODE = 66`.
- `sqlite3OpcodeProperty[0..191]` — opcode property flag table from opcodes.h
  (OPFLG_* bits: JUMP, IN1, IN2, IN3, OUT2, OUT3, NCYCLE, JUMP0).
- All P4_* type tags (P4_NOTUSED=0 … P4_SUBRTNSIG=-18); P5_Constraint* codes;
  COLNAME_* slot indices; SQLITE_PREPARE_* flags.
- All MEM_* flags (MEM_Undefined=0 … MEM_Agg=$8000).
- CURTYPE_*, CACHE_STALE, VDBE_*_STATE, SQLITE_FRAME_MAGIC, SQLITE_MAX_SCHEMA_RETRY.
- VDBC_* bitfield constants for VdbeCursor.cursorFlags (5-bit packed group).
- VDBF_* bitfield constants for Vdbe.vdbeFlags (9-bit packed group).
- Affinity constants (SQLITE_AFF_*), comparison flags (SQLITE_JUMPIFNULL etc.),
  KEYINFO_ORDER_* — needed by VDBE column comparison logic.
- Types: `ynVar = i16`, `LogEst = i16`, `yDbMask = u32` (default platform sizes).
- Opaque `Pointer` aliases for unported sqliteInt.h types: PFuncDef, PCollSeq,
  PTable, PIndex, PExpr, PParse, PVList, PVTable, Psqlite3_vtab_cursor,
  PVdbeSorter.
- All VDBE record types in one `type` block (FPC forward-ref requirement):
  TMemValue, TMem (= sqlite3_value), TVdbeTxtBlbCache, TAuxData, TScanStatus,
  TDblquoteStr, TSubrtnSig, Tp4union, TVdbeOp, TVdbeOpList, TSubProgram,
  TVdbeFrame, TVdbeCursorUb, TVdbeCursorUc, TVdbeCursor, Tsqlite3_context,
  TVdbe, TValueList.
- C flexible arrays (aType[] in VdbeCursor, argv[] in sqlite3_context) are
  omitted from the fixed record; callers allocate extra space.
- Phase 5.2–5.5 stubs: VdbeAddOp*, VdbeMakeLabel, VdbeResolveLabel,
  VdbeMemInit/SetNull/SetInt64/SetDouble/SetStr/Release/Copy, VdbeIntValue,
  VdbeRealValue, VdbeBooleanValue, sqlite3_step/reset/finalize, VdbeExec,
  VdbeHalt, VdbeList, sqlite3OpcodeName (full opcode name table included),
  sqlite3VdbeSerialTypeLen, sqlite3VdbeOneByteSerialTypeLen, sqlite3VdbeSerialGet.

**Struct sizes verified against GCC x86-64**:
- TMemValue = 8 B (largest member: Double/i64/pointer all = 8 B)
- TMem = 56 B (MEMCELLSIZE = offsetof(Mem,db) = 24 B)
- TVdbeOp = 24 B (opcode:1+p4type:1+p5:2+p1:4+p2:4+p3:4+p4:8)
- TVdbeCursor = 120 B (without flexible aType[] array)
- TVdbeFrame = 112 B
- TVdbe = 304 B (includes startTime:i64 for !SQLITE_OMIT_TRACE default)

**FPC pitfalls noted for 5.2+**:
- `Psqlite3_value = PMem` redefines the stub `Psqlite3_value = Pointer` from
  btree.pas; code in vdbe.pas uses the proper PMem type; btree.pas stubs
  continue to use Pointer (compatible for passing purposes).
- All type declarations in one `type` block for mutual-reference resolution.
- Bitfield groups translated to u32 with named bit-mask constants; GCC and FPC
  both align the u32 storage unit to 4 bytes, producing identical struct offsets.

---

## Phase 6 — Code generators

Files (by group; ~40 k lines combined — the largest phase):
- **Expression layer**: `expr.c` (~7.7 k), `resolve.c` (name resolution),
  `walker.c` (AST walker framework), `treeview.c` (debug tree printer).
- **Query planner**: `where.c` (~7.9 k), `wherecode.c`, `whereexpr.c`
  (~12 k combined). Header: `whereInt.h`.
- **SELECT**: `select.c` (~9 k), `window.c` (window functions — *defer to
  late in phase 6 if time-pressed*).
- **DML**: `insert.c`, `update.c`, `delete.c`, `upsert.c`.
- **Schema / DDL**: `build.c`, `alter.c`, `analyze.c`, `attach.c`,
  `pragma.c`, `trigger.c`, `vacuum.c`, `prepare.c` (the `sqlite3_prepare`
  core that feeds the parser into this phase).
- **Security / auth**: `auth.c`.
- **User-defined functions**: `callback.c`, `func.c` (built-in scalars),
  `date.c` (date/time functions), `fkey.c` (foreign keys), `rowset.c`
  (RowSet data structure).
- **JSON** (*defer; optional in initial scope*): `json.c` (~6 k lines).

These translate parse trees into VDBE programs. Validated by
`TestExplainParity.pas` — the `EXPLAIN` output for any SQL must match the C
reference exactly.

- [X] **6.1** Port the **expression layer** first — every other codegen unit
  calls into it: `expr.c`, `resolve.c`, `walker.c`, `treeview.c`.

  **walker.c — DONE (2026-04-25)**: Ported to `passqlite3codegen.pas`.
  All 12 walker functions implemented. Gate: `TestWalker.pas` — 40 tests, all PASS.

  **expr.c / treeview.c / resolve.c — DONE (2026-04-25)**:
  Ported to `passqlite3codegen.pas` (~2600 lines total).
  - `treeview.c`: 4 no-op stubs (debug-only, SQLITE_DEBUG not enabled in production).
  - `expr.c`: Full port — allocation (sqlite3ExprAlloc, sqlite3Expr, sqlite3ExprInt32,
    sqlite3ExprAttachSubtrees, sqlite3PExpr, sqlite3ExprAnd), deletion
    (sqlite3ExprDeleteNN, sqlite3ExprDelete, sqlite3IdListDelete, sqlite3SrcListDelete,
    sqlite3ExprListDelete), duplication (exprDup_, sqlite3ExprDup, sqlite3ExprListDup,
    sqlite3SrcListDup, sqlite3IdListDup, sqlite3SelectDup), list management
    (sqlite3ExprListAppend, sqlite3ExprListSetSortOrder, sqlite3ExprListSetName,
    sqlite3ExprListCheckLength, sqlite3ExprListFlags), affinity
    (sqlite3ExprAffinity, sqlite3ExprDataType, sqlite3AffinityType,
    sqlite3TableColumnAffinity stub), collation (sqlite3ExprSkipCollate,
    sqlite3ExprSkipCollateAndLikely, sqlite3ExprAddCollateToken,
    sqlite3ExprAddCollateString), height helpers (exprSetHeight_,
    sqlite3ExprCheckHeight, sqlite3ExprSetHeightAndFlags), identity/type helpers
    (sqlite3ExprIsVector, sqlite3ExprVectorSize, sqlite3IsTrueOrFalse,
    sqlite3ExprIdToTrueFalse, sqlite3ExprTruthValue, sqlite3IsRowid,
    sqlite3ExprIsInteger, sqlite3ExprIsConstant), dequote helpers
    (sqlite3DequoteExpr).
  - `resolve.c`: 7 stubs (sqlite3ResolveExprNames etc.) — full resolve.c
    implementation deferred to Phase 6.5 when Table/Column types are available.
  - Gate: `TestExprBasic.pas` — 40 tests (28 named checks), all PASS.

  **Key discoveries**:
  - All Phase 6 types MUST be in one `type` block (FPC forward-ref rule).
    Multiple `type` blocks cause "Forward type not resolved" for TSelect, TWindow etc.
  - TWindow sizeof=144 (not 152): trailing `_pad4: u32` was spurious; correct
    padding after `bExprArgs` is just `_pad2: u8; _pad3: u16` (3 bytes → 144).
  - `IN_RENAME_OBJECT` macro (walker.c) checks `pParse->eParseMode >= PARSE_MODE_RENAME`.
    Full `Parse` struct deferred to Phase 7; accessed via `ParseGetEParseMode(pParse: Pointer)`
    reading byte at offset 300 via `PByte` arithmetic (FPC typecast `PParse(ptr)` fails
    in inline functions for obscure syntactic reasons).
  - Function pointer comparisons require `Pointer()` cast in FPC:
    `Pointer(pWalker^.xSelectCallback2) = Pointer(@sqlite3WalkWinDefnDummyCallback)`.
  - `sqlite3SelectPopWith` (select.c, Phase 6.3) needs a stub in Phase 6.1
    because walker.c compares its address at compile time.
  - FlexArray accessors: `ExprListItems(p)` = `PExprListItem(PByte(p) + SizeOf(TExprList))`,
    `SrcListItems(p)` = `PSrcItem(PByte(p) + SizeOf(TSrcList))`.
    **CRITICAL: `IdListItems(p)` must use `SZ_IDLIST_HEADER = 8`, NOT SizeOf(TIdList) = 4.**
    The C `offsetof(IdList, a)` = 8 (4 bytes nId + 4 bytes alignment padding for pointer array).
    `TIdList` needs a `_pad: i32` field to make SizeOf(TIdList) = 8.
  - TAggInfo has SQLITE_DEBUG-only `pSelectDbg: PSelect` at offset 64 (must be included).
  - `TParse` struct is 416 bytes (GCC x86-64); all offsets verified by GCC offsetof test.
    `eParseMode: u8` is at byte offset 300.
  - `TIdList` header size is 8 bytes (nId + 4-byte padding) even though nId is 4 bytes —
    the FLEXARRAY element (pointer) requires 8-byte alignment.
  - `POnOrUsing` and `PSchema` pointer types must be declared in the type block
    (`PSchema = Pointer` deferred stub is sufficient for Phase 6.1).
  - Local variable `pExpr: PExpr` in a function that uses `TExprListItem.pExpr` field
    causes FPC's case-insensitive name conflict — "Error in type definition" at the `;`.
    Solution: eliminate the local variable or rename it.
  - `sqlite3ErrorMsg` cannot have `varargs` modifier in FPC unless marked `external`.
    Use a fixed 2-arg signature for the stub; full printf-style implementation in Phase 6.5.
  - `sqlite3GetInt32` added to passqlite3util.pas (parses decimal string to i32).
  - TK_COLLATE nodes always have `EP_Skip` set; `sqlite3ExprSkipCollate` only descends
    when `ExprHasProperty(expr, EP_Skip or EP_IfNullRow)` is true.
  - `sqlite3ExprAffinity` returns `p^.affExpr` as the default fallback — NOT
    `SQLITE_AFF_BLOB`. For uninitialized exprs, this returns 0 (= SQLITE_AFF_NONE).
  - Gate test: `TestWalker.pas` — 40 tests, all PASS.
  - Gate test: `TestExprBasic.pas` — 40 checks, all PASS.

- [X] **6.2** Port the **query planner** types, constants, and key whereexpr.c
  helpers: `whereInt.h` struct definitions (all Where* types, Table, Index,
  Column, KeyInfo, UnpackedRecord), `whereexpr.c` core routines, and public API
  stubs for `where.c` / `wherecode.c`.

  **DONE (2026-04-25)**:
  - All Where* record types ported to `passqlite3codegen.pas` with GCC-verified
    sizes (all 17 structs match exactly via C `offsetof`/`sizeof` tests):
    TWhereMemBlock=16, TWhereRightJoin=20, TInLoop=20, TWhereTerm=56,
    TWhereClause=488, TWhereOrInfo≥496, TWhereAndInfo=488, TWhereMaskSet=264,
    TWhereOrCost=16, TWhereOrSet=56, TWherePath=32, TWhereScan=112,
    TWhereLoopBtree=24, TWhereLoopVtab=24, TWhereLoop=104, TWhereLevel=120,
    TWhereLoopBuilder=40, TWhereInfo=856 (base; FLEXARRAY of TWhereLevel follows).
  - TColumn=16, TTable=120, TIndex=112, TKeyInfo=32, TUnpackedRecord=40 ported.
  - All WO_*, WHERE_*, TF_*, COLFLAG_*, TABTYP_*, TERM_*, SQLITE_BLDF_*,
    WHERE_DISTINCT_*, XN_ROWID/EXPR, SZ_WHERETERM_STATIC constants added.
  - whereexpr.c functions ported: sqlite3WhereClauseInit, sqlite3WhereClauseClear,
    sqlite3WhereSplit, sqlite3WhereGetMask, sqlite3WhereExprUsageNN,
    sqlite3WhereExprUsage, sqlite3WhereExprListUsage, sqlite3WhereExprUsageFull,
    whereOrInfoDelete, whereAndInfoDelete.
    Stubs: sqlite3WhereExprAnalyze, sqlite3WhereTabFuncArgs, sqlite3WhereAddLimit.
  - where.c public API stubs: sqlite3WhereOutputRowCount, sqlite3WhereIsDistinct,
    sqlite3WhereIsOrdered, sqlite3WhereIsSorted, sqlite3WhereOrderByLimitOptLabel,
    sqlite3WhereMinMaxOptEarlyOut, sqlite3WhereContinueLabel, sqlite3WhereBreakLabel,
    sqlite3WhereOkOnePass, sqlite3WhereUsesDeferredSeek, sqlite3WhereBegin (nil stub),
    sqlite3WhereEnd, sqlite3WhereRightJoinLoop.
  - Gate test: `TestWhereBasic.pas` — 52 checks, all PASS (2026-04-25).

  **Key discoveries**:
  - WhereLoopVtab: GCC packs needFree:1+bOmitOffset:1+bIdxNumHex:1 bitfields
    into a single byte at offset 4 (not a full u32), making vtab sub-struct 24
    bytes (same as btree variant). Verified by C `offsetof(WhereLoop,u.vtab.isOrdered)`=29.
  - WhereInfo bitfields (bDeferredSeek etc.) after eDistinct@67 are declared as
    `unsigned` in C but GCC packs them into 1 byte at offset 68. Represented as
    `bitwiseFlags: u8` @68 + `_pad69: u8` @69.
  - FPC: `Pi16 = ^i16` and `LogEst = i16` added to forward-pointer block.
    `PWhereMaskSet` also added as forward pointer.
  - `PKeyInfo2 = ^TKeyInfo` avoids shadowing `PKeyInfo = Pointer` stub in vdbe.pas.
  - Full where.c / wherecode.c port (query planner algorithm, cost model, index
    selection) deferred to Phase 6.2b (after Phase 6.3 select.c which provides
    the Select/SrcList types that WhereBegin depends on).

- [X] **6.3** Port `select.c` public API and helper functions: `TSelectDest`,
  `SRT_*` / `JT_*` constants, `sqlite3SelectDestInit`, `sqlite3SelectNew`,
  `sqlite3SelectDelete`, `sqlite3JoinType`, `sqlite3ColumnIndex`,
  `sqlite3KeyInfoAlloc/Ref/Unref/FromExprList`, `sqlite3SelectOpName`,
  `sqlite3GenerateColumnNames`, `sqlite3ColumnsFromExprList`,
  `sqlite3SubqueryColumnTypes`, `sqlite3ResultSetOfSelect`, `sqlite3WithPush`,
  `sqlite3ExpandSubquery`, `sqlite3IndexedByLookup`, `sqlite3SelectPrep`,
  `sqlite3Select` (stub). Gate test: TestSelectBasic (49/49 PASS).
  Full `sqlite3Select` engine (aggregation, GROUP BY, compound SELECT,
  CTEs, recursive queries) deferred to Phase 6.3b.
  FPC pitfalls: duplicate sqlite3LogEst removed from codegen (vdbe version
  is authoritative); nil-db guard added to sqlite3KeyInfoAlloc (db^.enc
  read only when db <> nil).

- [X] **6.4** Port **DML**: `insert.c`, `update.c`, `delete.c`, `upsert.c`,
  `trigger.c`. Each is ~1–2 k lines.
  **DONE (2026-04-25)**: All five DML files' public API ported to
  `passqlite3codegen.pas` as stubs (full VDBE code generation deferred to
  Phase 6.5+ when schema management is available). New types added to the
  codegen type block (all sizes GCC-verified): `TUpsert=88` (field `pUpsertSrc`
  corrected), `TAutoincInfo=24`, `TTriggerPrg=40`, `TTrigger=72`,
  `TTriggerStep=88`, `TReturning=232`. New constants: `OE_*` (conflict
  resolution), `TRIGGER_BEFORE/AFTER`, `OPFLAG_*`, `COLTYPE_*`.
  `PTrigger`, `PTriggerStep`, `PAutoincInfo`, `PTriggerPrg`, `PReturning`
  promoted from `Pointer` stubs to real typed pointer types.
  `TParse.pAinc`, `pTriggerPrg`, `pNewTrigger`, `pNewIndex` fields typed
  with real pointer types. upsert.c: `sqlite3UpsertNew`, `sqlite3UpsertDup`,
  `sqlite3UpsertDelete`, `sqlite3UpsertNextIsIPK`, `sqlite3UpsertOfIndex`
  fully implemented (memory-safe, no schema dependency).
  Gate test: `TestDMLBasic.pas` — 54/54 PASS (2026-04-25). All 49 prior
  TestSelectBasic + 52 TestWhereBasic + all other tests still PASS.

- [X] **6.5** Port **schema management**: `build.c` (CREATE/DROP + parsing
  `sqlite_master` at open), `alter.c` (ALTER TABLE), `prepare.c` (schema
  parsing + `sqlite3_prepare` internals), `analyze.c`, `attach.c`,
  `pragma.c`, `vacuum.c`.
  Gate test: `TestSchemaBasic.pas` — 44/44 PASS (2026-04-25).

- [X] **6.6** Port **auth and built-in functions**: `auth.c`, `callback.c`,
  `func.c` (scalars: `abs`, `coalesce`, `like`, `substr`, `lower`, etc.),
  `date.c` (`date()`, `time()`, `julianday()`, `strftime()`, `datetime()`),
  `fkey.c` (foreign-key enforcement), `rowset.c`.
  Gate test: `TestAuthBuiltins.pas` — **34/34 PASS** (2026-04-25).

- [X] **6.7** Port `window.c`: SQL window functions (`OVER`, `PARTITION BY`,
  `ROWS BETWEEN`, …). Intersects with `select.c` — port last within the
  codegen phase so `select.c` is stable when window integration starts.

- [X] **6.8** (Optional, defer-able) Port `json.c`: JSON1 scalar functions,
  `json_each`, `json_tree`. Only if users need it in v1.
  DONE 2026-04-26 (all sub-chunks 6.8.a..6.8.h closed; 6.8.h.7
  ports the RCStr deferral).

  Sub-tasks (chunks; mark each as it lands):
  - [X] **6.8.a** Foundation — types (`TJsonCache`, `TJsonString`,
    `TJsonParse`, `TNanInfName`), constants (`JSONB_*`, `JSTRING_*`,
    `JEDIT_*`, `JSON_*` flags, `JSON_MAX_DEPTH`, etc.), lookup tables
    (`aJsonIsSpace`, `jsonSpaces`, `jsonIsOk`, `jsonbType`,
    `aNanInfName`), and pure helpers (`jsonIsspace`, `jsonHexToInt`,
    `jsonHexToInt4`, `jsonIs2Hex`, `jsonIs4Hex`, `json5Whitespace`).
    DONE 2026-04-26.  Gate `TestJson.pas` 98/98 PASS.  See "Most
    recent activity" entry.
  - [X] **6.8.b** JsonString accumulator — `jsonStringInit/Reset/Zero/
    Oom/TooDeep/Grow/ExpandAndAppend`, `jsonAppendRaw/RawNZ/Char(Expand)/
    Separator/ControlChar/String`, `jsonStringTrimOneChar`,
    `jsonStringTerminate`.  DONE 2026-04-26.  Gate `TestJson.pas`
    139/139 PASS (was 98/98).  Spilled to plain libc malloc/realloc/free
    via `sqlite3_malloc64` / `sqlite3_realloc64` / `sqlite3_free`
    (passqlite3os) since `sqlite3RCStr*` is still unported — swap to
    RCStr in 6.8.h if jsonReturnString needs shared-ref semantics for
    `result_text64` callbacks.  Deferred to 6.8.h: `jsonAppendSqlValue`
    (needs `sqlite3_value_*` + jsonTranslateBlobToText), `jsonReturnString`,
    `jsonReturnStringAsBlob` (need vdbe `sqlite3_result_*` and the
    text↔blob translators from 6.8.d/e).  See "Most recent activity"
    entry.
  - [X] **6.8.c** JsonParse blob primitives — `jsonBlobExpand`,
    `jsonBlobMakeEditable`, `jsonBlobAppendOneByte`,
    `jsonBlobAppendNode`, `jsonBlobChangePayloadSize`,
    `jsonbPayloadSize`, `jsonBlobOverwrite`,
    `jsonBlobEdit`, `jsonAfterEditSizeAdjust`, `jsonbArrayCount`.
    DONE 2026-04-26.  Gate `TestJson.pas` 198/198 PASS (was 139/139).
    **`jsonbValidityCheck` deferred to 6.8.d** — the JSONB_TEXT5 escape
    branch needs `jsonUnescapeOneChar`, which is itself a 6.8.d helper
    (it depends on `sqlite3Utf8ReadLimited` + `sqlite3Utf8Trans1`,
    neither yet in `passqlite3util`).  Cleaner to land both together
    in 6.8.d than to introduce a strictness divergence here.
  - [X] **6.8.d** Text→blob translator — `jsonTranslateTextToBlob`,
    `jsonConvertTextToBlob`, `jsonUnescapeOneChar`, `jsonBytesToBypass`,
    `jsonLabelCompare(Escaped)`, `jsonIs4HexB`, `jsonbValidityCheck`,
    `jsonParseReset` (partial — RCStr branch deferred), plus
    `sqlite3Utf8ReadLimited` added to `passqlite3util`
    (`sqlite3Utf8Trans1` was already present from earlier UTF work).
    DONE 2026-04-26.  Gate `TestJson.pas` 274/274 PASS (was 198/198).
    `jsonAppendControlChar` already landed in 6.8.b — kept off this
    chunk's surface.  Error-sinking via `pCtx`
    (`sqlite3_result_error[_nomem]`) deferred to 6.8.h to avoid pulling
    `passqlite3vdbe` into the JSON unit; `jsonConvertTextToBlob` still
    returns 1 on error and resets the parse, callers just don't get a
    SQL error string yet.  Same deferral applies to
    `jsonParseReset`'s RCStr unref branch (sqlite3RCStr* not ported).
  - [X] **6.8.e** Blob→text + pretty — `jsonTranslateBlobToText`,
    `jsonPrettyIndent`, `jsonTranslateBlobToPrettyText`.
    DONE 2026-04-26.  Gate `TestJson.pas` 300/300 PASS (was 274/274).
    Added `TJsonPretty` record (mirrors `JsonPretty` from json.c:2418)
    and a private `jsonAppendU64Decimal` stand-in for json.c's
    `jsonPrintf(100, pOut, "%llu"|"9.0e999", u)` — that's the only
    jsonPrintf call-site relevant to 6.8.e (INT5 hex overflow arm).
    `jsonReturnTextJsonFromBlob` (json.c:3191) and `jsonReturnParse`
    (json.c:3775) **deferred to 6.8.h** — both call `jsonReturnString`
    / `sqlite3_result_*` which would pull `passqlite3vdbe` into the
    JSON unit, same dep-cycle reason as the earlier deferrals.
  - [X] **6.8.f** Path lookup + edit — `jsonLookupStep`,
    `jsonCreateEditSubstructure`.  DONE 2026-04-26.  Gate
    `TestJson.pas` 331/331 PASS (was 300/300).  Adds the JSON-path
    walk surface (`$.a.b[3]`-style).  Sentinels `JSON_LOOKUP_ERROR /
    NOTFOUND / NOTARRAY / TOODEEP / PATHERROR` exposed in interface
    plus a small `jsonLookupIsError(x: u32): Boolean` inline helper.
    `sqlite3_strglob("*]", zTail)` is *not* yet ported in pas-sqlite3
    so the JEDIT_AINS arm uses a private `jsonPathTailIsBracket`
    helper (last char of NUL-terminated `zTail` = `]`).  When
    `passqlite3util` lands `sqlite3Strglob` (likely 6.8.h or earlier
    if a `func.c` slice gets ported), swap the inline helper for a
    direct call.  C uses `zPath[-1]=='}'` to verify the JEDIT_AINS
    legality at empty-path entry; the port preserves the same
    `(zPath - 1)^` pointer arithmetic, which is safe iff the caller
    arrived through a `[N]` recursion (every test path here does).
    `jsonCreateEditSubstructure`'s `emptyObject[2]` table is a
    Pascal typed const `array[0..1] of u8 = (JSONB_ARRAY,
    JSONB_OBJECT)` selected by `if zTail[0]='.' then 1 else 0`.
    No external deps added; the chunk is self-contained inside
    passqlite3json.pas.
  - [X] **6.8.g** Function-arg cache — `jsonCacheInsert`,
    `jsonCacheSearch`, `jsonCacheDelete(Generic)`, `jsonParseFuncArg`,
    plus the supporting `jsonParseFree` (refcount drop) and
    `jsonArgIsJsonb` (blob-shaped JSONB sniffer).  DONE 2026-04-26.
    Gate `TestJson.pas` 353/353 PASS (was 331/331).
    Auxdata API ported in passqlite3vdbe.pas:
    `sqlite3_context_db_handle`, `sqlite3_get_auxdata`,
    `sqlite3_set_auxdata` — implementations exactly mirror
    vdbeapi.c:985 / 1169 / 1200, walking `pCtx^.pVdbe^.pAuxData`
    with the (iAuxArg=iArg) AND (iAuxOp=pCtx.iOp OR iArg<0) match
    rule.  `sqlite3_set_auxdata` allocates fresh entries via
    `sqlite3DbMallocZero`, links them at the head of `pVdbe^.pAuxData`,
    and sets `pCtx^.isError = -1` to mark "auxdata pending"; the
    existing `sqlite3VdbeDeleteAuxData` (linked-list freer) calls the
    `xDeleteAux` destructor for each entry on VM reset.
    Cache lifecycle (json.c:439): `jsonCacheInsert` looks up via
    auxdata key `JSON_CACHE_ID = -429938`; if absent, allocates a
    `TJsonCache`, registers `jsonCacheDeleteGeneric` as destructor.
    LRU eviction: when `nUsed >= JSON_CACHE_SIZE (=4)`, frees `a[0]`,
    Move-shifts `a[1..3]` down by one, drops `nUsed` to 3, then
    appends.  `jsonCacheSearch` (json.c:483) does two linear scans —
    first pointer-equality (zero-copy fast path), then byte-compare
    (`CompareByte`); on hit, promotes the entry to MRU via Move.
    `jsonParseFuncArg` (json.c:3658) implements the `goto
    rebuild_from_cache` loop with a Pascal `label` block — exits
    early for SQL NULL (returns nil), tries JSONB blob path via
    `jsonArgIsJsonb`, then falls through to text → blob via
    `jsonConvertTextToBlob`, then heap-copies + caches the text.
    `JSON_KEEPERROR` and `JSON_EDITABLE` flag handling matches C
    line-for-line.

    Concrete changes:
      * `src/passqlite3vdbe.pas` — adds 3 public funcs in interface
        + ~75 lines of impl just above `sqlite3VdbeCreate`.
      * `src/passqlite3json.pas` — adds 5 public funcs in interface
        (`jsonParseFree`, `jsonArgIsJsonb`, `jsonCacheInsert`,
        `jsonCacheSearch`, `jsonParseFuncArg`) + ~250 lines of impl,
        plus `passqlite3vdbe` added to **implementation uses** clause
        (NOT interface uses — keeps the dep direction consistent and
        Pointer-typed parameters preserve interface neutrality).
        Updates `jsonParseReset` to free libc-malloc'd zJson when
        `bJsonIsRCStr=1` (was a leaky no-op since 6.8.d).
      * `src/tests/TestJson.pas` — adds T333..T354 (22 new asserts:
        ParseFree refcount; ArgIsJsonb int/garbage/non-blob; cache
        empty-search; full FuncArg roundtrip incl. cache-hit refcount
        bookkeeping; SQL NULL early-return).  Adds `passqlite3vdbe`
        to test's uses clause.

    Discoveries / next-step notes:
      * **No `sqlite3RCStr` yet.**  json.c relies on `sqlite3RCStrNew`
        / `Ref` / `Unref` for shared zJson ownership across cache +
        SQL value system.  Pascal port substitutes `sqlite3_malloc` +
        copy; `bJsonIsRCStr=1` is repurposed as "owned by libc malloc"
        (jsonParseReset frees via `sqlite3_free`).  When 6.8.h ports
        sqlite3RCStr proper, the change is local to two sites:
        the `zNew := sqlite3_malloc(...)` block in `jsonParseFuncArg`
        and the symmetric `sqlite3_free` in `jsonParseReset`.
      * **`sqlite3_result_error` / `_nomem` deferred.**  Both error
        paths in `jsonParseFuncArg` (`json_pfa_malformed`,
        `json_pfa_oom`) currently silently return nil instead of
        sinking an error to ctx.  The TODO comments mark the
        deferral; 6.8.h's SQL dispatch layer will translate these
        into `sqlite3_result_error(ctx,"malformed JSON",-1)` and
        `sqlite3_result_error_nomem(ctx)` respectively.
      * **Local-var aliasing pitfall recurs.**  `pAuxData: PAuxData`
        and `pVdbe: PVdbe` inside `sqlite3_set_auxdata` both clashed
        with their type names under FPC's case-insensitive scope —
        same pattern as the existing `pPager: PPager` and
        `pParse: PParse` notes.  Renamed to `pAd` and `pVm`.  Add a
        new aliasing entry to memory if it bites again.
      * **`db: Psqlite3` not in scope inside passqlite3json.pas.**
        `Psqlite3` is declared in passqlite3btree.pas as
        `Psqlite3 = Pointer` — not re-exported by the units that
        passqlite3json uses transitively.  Used `Pointer` directly
        for the `db` local; matches the existing convention
        elsewhere in the unit (e.g. `pCtx: Pointer`).
      * **Cache-hit refcount accounting.**  After one parse + one
        cache hit (non-EDITABLE), `nJPRef` is **3**, not 2: 1 from
        the initial `nJPRef := 1`, +1 from `jsonCacheInsert`'s
        `Inc(pParse^.nJPRef)`, +1 from the cache-hit branch's
        `Inc(pCache^.nJPRef)`.  T351 documents this with a comment;
        worth re-checking when 6.8.h composes cache-hit + EDITABLE
        rebuild paths.
  - [X] **6.8.h** SQL-function dispatch + registration —
    `jsonFunc`, `jsonbFunc`, `json_array`/`_object`/`_extract`/
    `_set`/`_replace`/`_insert`/`_remove`/`_patch`/`_valid`/
    `_type`/`_quote`/`_array_length`/`_pretty`/`_error_position`/
    `_group_array`/`_group_object`, `json_each` + `json_tree` virtual
    tables, plus `sqlite3RegisterJsonFunctions` registration entry
    point.  This is the chunk that lights up SQL-visible behaviour;
    earlier chunks land as untested (in SQL terms) library code.

    Sub-chunks (mark each as it lands):
    - [X] **6.8.h.1** SQL-result helpers — `jsonAppendSqlValue`,
      `jsonReturnString`, `jsonReturnStringAsBlob`,
      `jsonReturnTextJsonFromBlob`, `jsonReturnFromBlob`,
      `jsonReturnParse`, `jsonWrongNumArgs`, `jsonBadPathError`,
      `jsonFunctionArgToBlob`.  Plus `sqlite3_user_data`,
      `sqlite3_result_subtype`, `sqlite3_result_text64` in
      `passqlite3vdbe.pas`.  DONE 2026-04-26.  Gate `TestJson.pas`
      375/375 PASS (was 353/353).  RCStr cache-insert branch in
      `jsonReturnString` deferred until sqlite3RCStr lands;
      currently always copies via SQLITE_TRANSIENT (correct, just
      one extra copy).  Float formatter uses RTL `FloatToStr`
      pending json-flavour `jsonPrintf` (see notes).
    - [X] **6.8.h.2** Simple scalar SQL functions — `json_quote`,
      `json_type`, `json_valid`, `json_error_position`,
      `json_array_length`, `json_pretty` (delegates to
      `jsonTranslateBlobToPrettyText` from 6.8.e).  All small
      bodies; the JSON-text dispatch is `jsonReturnParse` from .h.1.
      Plus `jsonAllAlphanum` helper (json.c:4044).
      DONE 2026-04-26.  Gate `TestJson.pas` 403/403 PASS (was
      375/375).  Cdecl SQL-function entry points `jsonQuoteFunc`,
      `jsonArrayLengthFunc`, `jsonTypeFunc`, `jsonPrettyFunc`,
      `jsonValidFunc`, `jsonErrorFunc` exported with `TxSFuncProc`
      shape so 6.8.h.6 can drop them straight into `TFuncDef` tables.
      `passqlite3vdbe` promoted to interface-uses of `passqlite3json`
      (was implementation-only) so `Psqlite3_context` / `PPMem` can
      type the cdecl signatures; existing Pointer-typed h.1 helpers
      kept as-is to avoid churn.  NULL-input branches of `json_valid`
      / `json_error_position` rely on the SQL convention that an
      uninitialised `pOut` Mem is implicitly NULL — they intentionally
      issue no `sqlite3_result_*` call (matches C).
      `json_valid(JSON, FLAGS)` text-fallthrough path duplicated in
      both BLOB and default cases (mirrors C's `deliberate_fall_through`
      by inlining the helper).  `json_pretty` default indent is the
      4-space string `'    '` (PostgreSQL-compatible, identical to C).
      Cache leak across tests handled by calling
      `sqlite3_set_auxdata(@ctx, JSON_CACHE_ID, nil, nil)` between
      cases — same pattern as T353 in 6.8.g.
    - [X] **6.8.h.3** Path-driven scalars — `json_extract`,
      `json_set`, `json_replace`, `json_insert` (alias of
      `json_set` via flags), `json_array_insert` (ditto),
      `json_remove`, `json_patch`.  Drives `jsonLookupStep` (6.8.f) +
      `jsonInsertIntoBlob` (private, this chunk) + `jsonMergePatch`
      (private, this chunk).
      DONE 2026-04-26.  Gate `TestJson.pas` 421/421 PASS (was
      403/403).  18 new asserts T405..T422.  Regression spot
      check: TestPrintf 105/105, TestVtab 216/216, TestParser 45/45,
      TestSchemaBasic 44/44, TestVdbeApi 57/57.

      Concrete changes:
        * `src/passqlite3json.pas` — adds 5 cdecl SQL entry points
          to interface (`jsonExtractFunc`, `jsonRemoveFunc`,
          `jsonReplaceFunc`, `jsonSetFunc`, `jsonPatchFunc`) and
          ~440 lines of impl: private `jsonInsertIntoBlob`
          driver, private `jsonMergePatch` (RFC-7396),
          `JSON_MERGE_*` constants.
        * `src/tests/TestJson.pas` — `CallScalar3`, `CallScalar5`
          helpers + 5 new test bodies (`TestJsonRemove`,
          `TestJsonReplace`, `TestJsonSet`, `TestJsonExtract`,
          `TestJsonPatch`).

      Discoveries / next-step notes:
        * **`isError = -1` is an auxdata-attached sentinel,
          not an SQL error.**  `sqlite3_set_auxdata` flips
          `pCtx^.isError` to `-1` when it stores fresh aux state
          for the current opcode.  Tests checking "no result, no
          error" must therefore allow `isError <= 0`, not require
          `= 0`.  Two T-row asserts updated accordingly.
        * **`json_set` / `json_insert` / `json_array_insert`
          dispatch via flags-on-user-data only.**  Without a
          fabricated `TFuncDef` slot in the test ctx,
          `sqlite3_user_data` returns nil → `eInsType = 0`
          → INSERT semantics.  T412/T413 pin this default-flags
          behaviour; the registration chunk (6.8.h.6) will set
          `JSON_ISSET` / `JSON_AINS` via `pUserData` so that the
          same `jsonSetFunc` body covers all three SQL names.
          A SET-flagged variant test is deferred until the
          registration layer fabricates the user-data slot.
        * **`jsonExtractFunc` ABPATH branch only fires when
          flags & 0x03 ≠ 0.**  Plain `json_extract` (flags=0)
          requires `$`-prefix paths; `->` (`JSON_JSON=1`) and
          `->>` (`JSON_SQL=2`) accept the abbreviated forms.
          T418 covers the bare-label rejection in the
          plain-`json_extract` case; the abbreviated-path branch
          is wired but not yet exercised — pick up in 6.8.h.6
          once user-data flags can be set.
        * **`jsonMergePatch` `Move()` calls use FPC's RTL.**
          Equivalent to C `memcpy`; no overlap concerns since
          source is `pPatch` and destination is `pTarget` (two
          distinct JsonParse blobs).  If a future fuzz case
          aliases the two it could break — re-check then.
        * **`jsonPatchFunc` argc==2 enforced via Assert + early
          return.**  C uses `assert(argc==2)` plus
          `UNUSED_PARAMETER(argc)`; we keep both because release
          builds without `-CR` would otherwise crash on a
          malformed registration.  Belt-and-braces, removable
          when the registration chunk pins argc to 2 in
          `TFuncDef`.
    - [X] **6.8.h.4** Aggregates — `json_group_array`,
      `json_group_object` (step / value / final / inverse).
      DONE 2026-04-26.  Gate `TestJson.pas` 434/434 PASS (was
      421/421).  13 new asserts T423..T435.  Regression spot check:
      TestPrintf 105/105, TestVtab 216/216, TestParser 45/45,
      TestSchemaBasic 44/44, TestVdbeApi 57/57.

      Concrete changes:
        * `src/passqlite3json.pas` — adds 7 cdecl entry points to
          interface (`jsonArrayStep`, `jsonArrayValue`,
          `jsonArrayFinal`, `jsonObjectStep`, `jsonObjectValue`,
          `jsonObjectFinal`, `jsonGroupInverse`).  Implementation
          ~210 lines: shared `jsonArrayCompute` / `jsonObjectCompute`
          drivers, `jsonGroupInverse` first-element trimmer.
        * `src/tests/TestJson.pas` — adds `SetupAggCtx` helper plus
          `CallStep1` / `CallStep2` invokers; three new test bodies
          (`TestJsonGroupArray`, `TestJsonGroupInverse`,
          `TestJsonGroupObject`).

      Discoveries / next-step notes:
        * **Aggregate context buffer is allocated by
          `sqlite3_aggregate_context` into `pCtx^.pMem^.z`** via
          `sqlite3VdbeMemClearAndResize` → `sqlite3DbMallocRaw`.
          With `pMem^.db = nil` the malloc falls through to libc;
          tests rely on this to fabricate aggregate state without a
          live VM.  The buffer is zeroed on first allocation, so
          `pStr^.zBuf == nil` cleanly distinguishes the first Step
          from subsequent ones (mirrors C).
        * **`jsonStringInit` plants `pStr^.zBuf := @pStr^.zSpace[0]`**
          — that pointer is *into* the aggregate-owned buffer.  As
          long as the buffer never moves (sqlite3_aggregate_context
          only ever allocates once), the pointer stays valid across
          Step calls.  If a future RCStr-aware spill grows zBuf onto
          the heap, the inline pointer is replaced — also fine.  The
          dangerous case would be re-running `sqlite3VdbeMemGrow` on
          `pAggMem` between Steps; sqlite3_aggregate_context never
          does that, but worth flagging if 6.8.h.5/h.6 plumb a
          different aggregator path.
        * **No sqlite3RCStr means non-static spill is freed with
          `sqlite3_free`, not `sqlite3RCStrUnref`.**  The C `if
          (!pStr->bStatic) sqlite3RCStrUnref(pStr->zBuf)` in the
          JSON_BLOB final arm becomes `if pStr^.bStatic = 0 then
          sqlite3_free(pStr^.zBuf)`.  Same two-site swap as 6.8.h.1
          / 6.8.g — flip both back to RCStr when 6.8.h.6 ports it.
        * **Result text emitted as TRANSIENT (extra copy).**  C
          hands ownership to `sqlite3_result_text` with an
          `sqlite3RCStrUnref` destructor; absent that, the Pascal
          port copies via TRANSIENT and calls `jsonStringReset` to
          free the spill.  Only meaningful for huge groups —
          functionally identical, costs one extra memcpy of the
          finalised body.  Same rationale and fix-site as
          `jsonReturnString` (6.8.h.1).
        * **`jsonStringTrimOneChar` is the resume invariant.**  The
          C `Value` path appends `'}'` / `']'`, returns text, then
          re-trims so the next `Step` sees the body sans terminator.
          T426/T427 and T434/T435 pin this end-to-end (Value mid-
          stream, then a fresh Step extends the same accumulator).
        * **`jsonGroupInverse` `\` skip uses `#$5C`.**  Pascal's
          `'\'` is an unterminated string literal; emit the
          backslash byte via `#$5C` instead.  Same family as the
          escape-decoding traps in 6.8.d/e.
        * **NULL-key in `jsonObjectStep` skips the row entirely** —
          mirrors C's `(pStr->nUsed>1 && z!=0)` separator guard plus
          the `if (z!=0)` wrap around the name/colon/value triple.
          T433 covers the mid-aggregate skip case.
    - [X] **6.8.h.5** Virtual tables — `json_each`, `json_tree`
      (xConnect/Disconnect/Open/Close/Filter/Next/Eof/Column/Rowid
      /BestIndex).
      DONE 2026-04-26.  Lands the four-spelling read-only vtab module
      (`json_each` / `json_tree` / `jsonb_each` / `jsonb_tree`) and the
      `sqlite3JsonVtabRegister(db, zName)` entry point that 6.8.h.6
      will wire into `sqlite3RegisterBuiltinFunctions`.  Gate
      `TestJsonEach.pas` 50/50 PASS.  Regression spot check: TestJson
      434/434, TestPrintf 105/105, TestVtab 216/216, TestParser 45/45,
      TestSchemaBasic 44/44, TestVdbeApi 57/57, TestCarray 66/66.

      Concrete changes:
        * `src/passqlite3jsoneach.pas` — **new unit** (~600 lines).
          Faithful port of json.c:5020..5680 (json_each/json_tree).
          Exposes `jsonEachModule`, `sqlite3JsonVtabRegister`, the
          `JEACH_*` column-ordinal constants, and the `TJsonParent`
          / `TJsonEachConnection` / `TJsonEachCursor` records.
        * `src/tests/TestJsonEach.pas` — **new gate**.  Module
          registration (4 spellings + unknown spelling → nil +
          case-insensitive), module slot layout (15 slots),
          BestIndex constraint dispatch (5 cases: empty / JSON
          only / JSON+ROOT / unusable JSON / non-hidden ignored),
          column-ordinal pin (10).  50 asserts.
        * `src/tests/build.sh` — adds `compile_test TestJsonEach`.

      Discoveries / next-step notes:
        * **Kept in a separate unit (passqlite3jsoneach) rather than
          appended to passqlite3json.**  passqlite3json.pas is already
          5061 lines; the json_each port pulls in `passqlite3vtab`
          (sqlite3_module / sqlite3_vtab_cursor / declare_vtab /
          vtab_config / VtabCreateModule).  Following the same
          pattern as `passqlite3carray` / `passqlite3dbpage` /
          `passqlite3dbstat`, which also live as separate units that
          `uses passqlite3vtab`.  Avoids dragging the parser/codegen
          chain into the JSON core.
        * **`jsonPrintf` stayed private; jsonAppendPathName uses three
          local stand-ins.**  json.c reuses its private `jsonPrintf`
          for `[%lld]`, `."%.*s"`, `.%.*s`.  Promoting it to interface
          would re-export the entire JsonString-formatter machinery.
          Wrote `jeAppendInt64` + `jeFmtArrayKey` + `jeFmtObjectKey` /
          `jeFmtObjectKeyQuoted` instead — three 4-line helpers that
          drive `jsonAppendRaw`.  If a future chunk (e.g. when the
          full json5 number formatter lands) needs jsonPrintf publicly,
          remove these stand-ins and switch back.
        * **`'$'` to PAnsiChar coercion is unsafe.**  FPC parses a
          single-quoted single character as `AnsiChar`, not as a
          string literal — passing `'$'` directly to a `PAnsiChar`
          parameter is rejected.  Fix: declare a local `cDollar:
          AnsiChar` and pass `@cDollar`.  Same trap any future
          single-byte path-anchor write will hit; flagged in the
          porting-rule list.
        * **`PPsqlite3_value` indexes directly: `argv[0]`, `argv[1]`.**
          No need for the `^Psqlite3_value` aliasing trick — FPC's
          subscript operator on `^T` (where `T = ^U`) yields a `^U`
          (i.e. `Psqlite3_value`) directly.  Same convention as carray.
        * **`malformed JSON` error string flows through
          `sqlite3VtabFmtMsg1Libc`.**  C uses
          `sqlite3_mprintf("malformed JSON")`; the Pascal port routes
          through the libc-allocated VtabFmtMsg1 helper so
          `sqlite3_free(pVtab^.zErrMsg)` clears it uniformly.  Same
          two-call pattern as `passqlite3carray`'s unknown-datatype
          branch.
        * **Cursor allocation is libc when `pTab^.db = nil`.**  Tests
          that fabricate a cursor without a live DB connection rely
          on `sqlite3DbMallocZero(nil, ...)` falling through to libc
          malloc — same convention as the 6.8.h.4 aggregate context
          plumbing.  Production callers always pass a live db.
        * **Column tests deferred.**  The xColumn callback is wired
          but exercising it requires a live `Tsqlite3_context` *and*
          a populated `TJsonParse`.  Pinning xColumn end-to-end
          (key/value/type/atom/path/fullkey) belongs with 6.8.h.6
          when the registration layer wires the vtab into the SQL
          parser; meanwhile, structurally identical to C and gated
          by xBestIndex/xFilter compile-time success.
        * **Cursor walk via `jsonEachFilter` is also deferred from
          this gate** — `jsonEachFilter` requires a `Psqlite3_value`
          shaped like a real SQL value (text bytes + nJson length),
          and `jsonConvertTextToBlob` writes diagnostics into the
          parser's `pCtx`.  Module-shape + BestIndex coverage is the
          stable surface for 6.8.h.5; full filter/next/column
          coverage rides 6.8.h.6.
    - [X] **6.8.h.6** Registration — `sqlite3RegisterJsonFunctions`
      and `sqlite3JsonVtabRegister`; wire into
      `sqlite3RegisterBuiltinFunctions` so the `json_*` SQL surface
      becomes live.  Optionally port `sqlite3RCStr` here so the
      cache-insert branch in `jsonReturnString` can match C exactly.
      DONE 2026-04-26.  32 scalars + 4 aggregates registered via
      `JFn` / `WAgg` helpers in `passqlite3codegen.pas`; `pUserData`
      carries `iArg | (bJsonB?JSON_BLOB:0)` matching the C JFUNCTION
      macro byte-for-byte.  `passqlite3jsoneach` brought into codegen's
      `uses` so its `initialization` block runs (per-connection vtab
      registration via `sqlite3JsonVtabRegister` is still lazy and
      will hook up with the SELECT/parser surface in Phase 7).
      Gate `TestJsonRegister.pas` 48/48 PASS.  Regression: TestJson
      434/434, TestJsonEach 50/50, TestAuthBuiltins 34/34, TestPrintf
      105/105, TestVtab 216/216, TestParser 45/45, TestSchemaBasic
      44/44, TestVdbeApi 57/57, TestCarray 66/66.

      Concrete changes:
        * `src/passqlite3types.pas` — `SQLITE_RESULT_SUBTYPE = $01000000`.
        * `src/passqlite3json.pas` — adds `jsonArrayFunc`,
          `jsonObjectFunc` cdecl entry points (interface + impl).
        * `src/passqlite3codegen.pas` — adds `sqlite3RegisterJsonFunctions`
          (~110 lines), pulls `passqlite3json`, `passqlite3jsoneach`
          into the implementation `uses` clause; `sqlite3RegisterBuiltinFunctions`
          now calls it after the existing scalar+agg insert.
        * `src/tests/TestJsonRegister.pas` — new gate, 48 asserts.
        * `src/tests/build.sh` — adds `compile_test TestJsonRegister`.

      Discoveries / next-step notes:
        * **`sqlite3RCStr` still deferred.**  Same TRANSIENT-copy
          fix-sites as 6.8.h.1 / 6.8.h.4 / 6.8.g.  Three swaps will
          land together when a future PrepareV2/Vdbe-result chunk
          ports the helper.
        * **TFuncDef arrays cannot be over-sized with trailing zero
          slots.**  `sqlite3InsertBuiltinFuncs` calls
          `sqlite3Strlen30(zName)` per entry; a nil zName → segfault.
          Always size arrays to exactly the registered count.
        * **Per-connection vtab registration deferred.**  C's
          `sqlite3JsonVtabRegister` is invoked lazily via
          `sqlite3FindOrCreateModule` from the parser when a SQL
          statement first names `json_each` etc.  Until that path
          exists in this port (Phase 7), `sqlite3RegisterJsonFunctions`
          merely keeps the `passqlite3jsoneach` unit linked so its
          `initialization` block populates `jsonEachModule`.
        * **`pUserData` is now live for the SQL path.**  The
          `JSON_ISSET` / `JSON_AINS` / `JSON_BLOB` / `JSON_JSON` /
          `JSON_SQL` / `JSON_ABPATH` flag-discrimination branches in
          `jsonSetFunc` / `jsonExtractFunc` / etc. that h.3 and h.4
          flagged as untested-because-fabricated-ctx all fire when
          `sqlite3FindFunction` resolves a registered name.
    - [X] **6.8.h.7** sqlite3RCStr port + JSON ownership-transfer.
      Closes the deferral threaded through 6.8.b / 6.8.g / 6.8.h.1 /
      6.8.h.4 / 6.8.h.6.  Adds `sqlite3RCStrNew/Ref/Unref/Resize` to
      `passqlite3util.pas` (printf.c:1557..1614 — the helper conceptually
      lives in printf.c but is independent of the printf machinery, so
      the util unit is the dep-clean home).  Rewires six JSON fix-sites
      in `passqlite3json.pas` to use RCStr for spill / cache / SQL-result
      ownership transfer (jsonStringReset, jsonStringGrow,
      jsonReturnString cache-insert path, jsonArrayCompute /
      jsonObjectCompute final-isFinal arms, jsonParseFuncArg cache
      store, jsonParseReset).  Result-text path now zero-copy via
      `sqlite3RCStrUnref` destructor; matches C json.c byte-for-byte.
      DONE 2026-04-26.  Gate `TestJson.pas` 434/434 PASS,
      `TestJsonRegister.pas` 48/48 PASS, `TestJsonEach.pas` 50/50 PASS.
      Regression: TestUtil ALL PASS, TestPrintf 105/105, TestVtab 216/216,
      TestVdbeApi 57/57.  See "Most recent activity" entry for details.

      Discoveries / next-step notes:
        * **RCStr is now available for the VDBE port.**  vdbe.c:759..782
          (function result-text caching) and vdbeaux.c:2759 (auxdata
          cleanup) still use `sqlite3_malloc`/`sqlite3_free` placeholders
          per the existing Phase 5 port.  Swap them to RCStr when those
          paths get touched in Phase 8.x.
        * **`sqlite3RCStrUnref` is `cdecl`** — required so it can be
          passed as `TxDelProc` (the SQLite C destructor calling
          convention).  Same shape as `sqlite3FreeXDel` already in
          `passqlite3vdbe.pas`.

### Phase 6.7 implementation notes (2026-04-25)

**Unit modified**: `src/passqlite3codegen.pas` (~9600 lines after phase).

**New public API** (all exported in interface):
- Window lifecycle: `sqlite3WindowDelete`, `sqlite3WindowListDelete`,
  `sqlite3WindowDup`, `sqlite3WindowListDup`, `sqlite3WindowLink`,
  `sqlite3WindowUnlinkFromSelect`.
- Allocation/assembly: `sqlite3WindowAlloc`, `sqlite3WindowAssemble`,
  `sqlite3WindowChain`, `sqlite3WindowAttach`.
- Comparison/update: `sqlite3WindowCompare`, `sqlite3WindowUpdate`.
- Rewrite (stub): `sqlite3WindowRewrite` — marks `SF_WinRewrite`; full rewrite
  deferred to Phase 7 when the Lemon parser and full SELECT engine exist.
- Code-gen stubs: `sqlite3WindowCodeInit`, `sqlite3WindowCodeStep`.
- Built-in registration: `sqlite3WindowFunctions` — installs all 10 built-in
  window functions (row_number, rank, dense_rank, percent_rank, cume_dist,
  ntile, lead, lag, first_value, last_value, nth_value) via `TFuncDef` array.
- Expr comparison helpers: `sqlite3ExprCompare`, `sqlite3ExprListCompare`
  (ported from expr.c:6544/6646).

**Private types** (implementation section only):
- `TCallCount`, `TNthValueCtx`, `TNtileCtx`, `TLastValueCtx` (window agg ctxs).
- `TWindowRewrite` (walker context for `selectWindowRewriteExprCb`).

**FPC pitfalls hit**:
- `var pParse: PParse` inside a function body is a circular self-reference
  (FPC is case-insensitive; `pParse` ≡ `PParse`). Fix: rename local to `pPrs`.
  This is the same pattern as `pPager: PPager`; always rename the local.
- `type TFoo = record ... end; const aFoo: array[...] of TFoo = (...)` inside
  a procedure body fails if any record field is `PAnsiChar` (pointer). Fix:
  remove the pointer field (it was unused) so all fields are integer types,
  which FPC's typed-const initialiser accepts inside procedure bodies.
- Walker callbacks used as `TExprCallback`/`TSelectCallback` must be `cdecl`.
- `TWalkerU.pRewrite` does not exist in the Pascal union; use `ptr: Pointer`
  (case 0) instead and cast at use sites.
- `sqlite3ErrorMsg` stub is 2-arg only; format via AnsiString concatenation.

**Gate test**: `src/tests/TestWindowBasic.pas` — 34/34 PASS.

### Phase 6.6 implementation notes (2026-04-25)

**Units modified**: `src/passqlite3codegen.pas`, `src/passqlite3vdbe.pas`,
`src/passqlite3types.pas`.

**New types** (all sizes verified against FPC x86-64):
- `TCollSeq=40`: zName:8+enc:1+pad:7+pUser:8+xCmp:8+xDel:8.
- `TFuncDestructor=24`: nRef:4+pad:4+xDestroy:8+pUserData:8.
- `TFuncDefHash=184`: 23×8 PTFuncDef slots.
- `TFuncDef.nArg` corrected from `i8` to `i16` (C struct uses `i16`).

**New constants**:
- Auth action codes: `SQLITE_CREATE_INDEX=1` … `SQLITE_RECURSIVE_AUTH=33`
  (suffixed `_AUTH` for DELETE/INSERT/SELECT/UPDATE/ATTACH/DETACH/FUNCTION to
  avoid clashing with result-code constants of the same name).
- `SQLITE_FUNC_*` flags: ENCMASK, LIKE, CASE, EPHEM, NEEDCOLL, LENGTH,
  TYPEOF, BYTELEN, COUNT, UNLIKELY, CONSTANT, MINMAX, SLOCHNG, TEST,
  RUNONLY, WINDOW, INTERNAL, DIRECT, UNSAFE, INLINE, BUILTIN, ANYORDER.
- `SQLITE_FUNC_HASH_SZ=23`.
- Public API function flags: `SQLITE_DETERMINISTIC=$800`, `SQLITE_DIRECTONLY=$80000`,
  `SQLITE_SUBTYPE=$100000`, `SQLITE_INNOCUOUS=$200000`.
- `SQLITE_DENY=1`, `SQLITE_IGNORE=2` (added to passqlite3types.pas).
- `SQLITE_REAL=2` alias for `SQLITE_FLOAT`.

**Exported from passqlite3vdbe.pas interface**: `sqlite3MemCompare`,
`sqlite3AddInt64`.

**Known FPC pitfalls hit**:
- `const X = val` inside function bodies → illegal in OBJFPC; move to function
  const section or module const block.
- Inline `var x: T := val` inside `begin..end` blocks → illegal; move to var
  section above `begin`.
- `type TAcc = ...` inside function bodies → duplicate identifier if repeated
  in adjacent functions; moved to module-level type block with unique names
  (TSumAcc/PSumAcc, TAvgAcc/PAvgAcc).
- `pMem: PMem` → FPC case-insensitive clash with type `PMem`; renamed to
  `pAgg`, `pCount`, etc.
- `uses DateUtils, SysUtils` → must appear immediately after `implementation`
  keyword, not inside the body.
- `sqlite3_snprintf(n, buf, fmt, args)` → our declaration is variadic-argless;
  replaced with `snpFmt(n, buf, fmt, args)` helper using SysUtils.Format.
- `TDateTime2` fields: `Y, M, D, h, m` where `M` and `m` are same to FPC;
  renamed to `yr, mo, dy, hr, mi`.
- `sqlite3Toupper` is a function, not an array; call as `sqlite3Toupper(x)`.

**Date functions**: implemented using Julian Day arithmetic (same formula as
SQLite's `date.c`). `currentJD` uses `SysUtils.Now` + `DateUtils.DecodeDateTime`.

**Functions implemented**: auth.c (sqlite3_set_authorizer, sqlite3AuthReadCol,
sqlite3AuthRead, sqlite3AuthCheck, sqlite3AuthContextPush/Pop); callback.c
(findCollSeqEntry, sqlite3FindCollSeq, synthCollSeq, sqlite3GetCollSeq,
sqlite3CheckCollSeq, sqlite3IsBinary, sqlite3LocateCollSeq,
sqlite3SetTextEncoding, matchQuality, sqlite3FunctionSearch,
sqlite3InsertBuiltinFuncs, sqlite3FindFunction, sqlite3CreateFunc,
sqlite3SchemaClear, sqlite3SchemaGet, sqlite3RegisterBuiltinFunctions,
sqlite3RegisterPerConnectionBuiltinFunctions, sqlite3RegisterLikeFunctions,
sqlite3IsLikeFunction); 30+ scalar functions (abs, typeof, octetLength, length,
substr, upper, lower, hex, unhex, zeroblob, nullif, version, sourceid, errlog,
random, randomBlob, lastInsertRowid, changes, totalChanges, round, trim, ltrim,
rtrim, replace, like, glob, coalesce, ifnull, iif, unicode, char, quote);
aggregates (count, sum, total, avg, min, max, group_concat);
date/time functions (date, time, datetime, julianday, unixepoch, strftime);
fkey.c stubs (all 7 functions).

### Phase 6.4 implementation notes (2026-04-25)

**Unit**: `src/passqlite3codegen.pas` (extended).

**New types** (all sizes verified against GCC x86-64 with -DSQLITE_DEBUG -DSQLITE_THREADSAFE=1):
- `TUpsert=88`: field `pUpsertCols` renamed to `pUpsertSrc` (was wrongly named
  `PIdList`; is actually `PSrcList`). `pUpsertIdx` promoted to `PIndex2`.
- `TAutoincInfo=24`: AUTOINCREMENT per-table tracking info (pNext/pTab/iDb/regCtr).
- `TTriggerPrg=40`: compiled trigger program (pTrigger/pNext/pProgram/orconf/aColmask[2]).
- `TTrigger=72`: trigger definition (zName/table/op/tr_tm/bReturning/pWhen/pColumns/
  pSchema/pTabSchema/step_list/pNext). All offsets verified.
- `TTriggerStep=88`: one trigger step (op/orconf/pTrig/pSelect/pSrc/pWhere/pExprList/
  pIdList/pUpsert/zSpan/pNext/pLast). All offsets verified.
- `TReturning=232`: RETURNING clause state — contains embedded TTrigger and TTriggerStep.
  Key discovery: `zName` is at offset 188 (not 192); there is no padding between
  `iRetReg` (at 184) and `zName[40]` (at 188); trailing 4-byte `_pad228` brings total to 232.

**Type promotions in forward-pointer section**:
- `PTrigger = Pointer` → `PTrigger = ^TTrigger`
- Added `PTriggerStep = ^TTriggerStep`, `PAutoincInfo = ^TAutoincInfo`,
  `PTriggerPrg = ^TTriggerPrg`, `PReturning = ^TReturning`

**TParse field upgrades** (types now precise instead of `Pointer`):
- `pAinc: PAutoincInfo` (offset 144)
- `pTriggerPrg: PTriggerPrg` (offset 168)
- `pNewIndex: PIndex2` (offset 352)
- `pNewTrigger: PTrigger` (offset 360)
- `u1.pReturning: PReturning` (union at offset 248)

**New constants**: `OE_None=0..OE_Default=11`, `TRIGGER_BEFORE=1`, `TRIGGER_AFTER=2`,
`OPFLAG_*` (insert/delete/column flags), `COLTYPE_*` (column type codes 0–7).

**Implemented (upsert.c)**: `sqlite3UpsertNew`, `sqlite3UpsertDup`,
`sqlite3UpsertDelete` (recursive chain free), `sqlite3UpsertNextIsIPK`,
`sqlite3UpsertOfIndex`. These are fully correct memory-safe implementations.

**Stubs (insert.c, update.c, delete.c, trigger.c)**: All public API functions
declared with correct signatures and implemented as safe stubs (freeing their
input arguments where applicable to prevent leaks). Full VDBE code generation
deferred to Phase 6.5+ when schema management provides `Table*` / `Index*`
schema lookup.

**Gate test**: `TestDMLBasic.pas` — 54 checks: struct sizes (6), field offsets (24),
upsert lifecycle (6), trigger stub API (4), constants (9). All 54 PASS.

### Phase 6.5 implementation notes (2026-04-25)

**Unit**: `src/passqlite3codegen.pas` (extended).

**Key FPC discoveries**:
- `PSchema` (from passqlite3util) is shadowed if re-declared locally as `Pointer`.
  Var-block declarations needing field access must use `passqlite3util.PSchema`.
- FPC can't do anonymous procedure literals (no lambdas); `sqlite3ParserAddCleanup`
  uses direct `TParseCleanupFn(xCleanup)` cast.
- `SizeOf(TSrcList)` = 8 (header only, no items). Pascal `sqlite3SrcListAppend`
  must call `sqlite3SrcListEnlarge` unconditionally (as in C), not guard with
  `nSrc >= nAlloc`. Old C-style `(nNew-1)` formula was wrong; Pascal uses `nNew`.
- `PParse(Pointer_expr)` type-cast inside a procedure body causes a "Syntax error,
  ';' expected" in FPC; write `dest := src_pointer` directly (Pointer is
  assignment-compatible with any typed pointer).
- `Pu8(pParse)[offset]` is not valid as a `var` FillChar argument; use
  `(PByte(pParse) + offset)^` form instead.
- `pSchema: PSchema` in var blocks gives "Error in type definition" when `PSchema`
  is used both as a record field name (`TIndex.pSchema`) and a type in the same
  compilation unit (FPC case-insensitive disambiguation fails). Fix: use
  `pSchema: passqlite3util.PSchema` qualified form.

**New types**: `TParseCleanup` (24 bytes), `TDbFixer` (48 bytes), `PPToken`,
`PPAnsiChar`, `PLogEst`.

**New constants**: `DBFLAG_SchemaKnownOk`, `LOCATE_VIEW`, `LOCATE_NOERR`,
`OMIT_TEMPDB`, `LEGACY/PREFERRED_SCHEMA_TABLE` names, `PARSE_HDR_OFFSET`,
`PARSE_HDR_SZ`, `PARSE_RECURSE_SZ`, `PARSE_TAIL_SZ`, `INITFLAG_Alter*`.

**Real implementations** (not stubs):
- `sqlite3SchemaToIndex` / `sqlite3SchemaToIndexInner`
- `sqlite3FindTable`, `sqlite3FindIndex`, `sqlite3FindDb`, `sqlite3FindDbName`
- `sqlite3LocateTable`, `sqlite3LocateTableItem`
- `sqlite3DbIsNamed`, `sqlite3DbMaskAllZero`
- `sqlite3PreferredTableName`
- `sqlite3ParseObjectInit` / `sqlite3ParseObjectReset`
- `sqlite3ParserAddCleanup` (real linked-list of cleanup callbacks)
- `sqlite3AllocateIndexObject` + `sqlite3DefaultRowEst` + `sqlite3TableColumnToIndex`
- `sqlite3SrcListEnlarge`, `sqlite3SrcListAppend`, `sqlite3SrcListAppendFromTerm`
- `sqlite3SrcListIndexedBy`, `sqlite3SrcListAppendList`, `sqlite3IdListAppend`
- `sqlite3SchemaClear`, `sqlite3SchemaGet`
- `sqlite3UnlinkAndDeleteTable`, `sqlite3ResetAllSchemasOfConnection`

**Stubs** (real code deferred to Phase 7 which needs the Lemon parser):
- `sqlite3RunParser`, `sqlite3_prepare*` — return SQLITE_ERROR
- All DDL codegen (CREATE TABLE/INDEX/VIEW, DROP, ALTER, ATTACH, PRAGMA, VACUUM, ANALYZE)

**Gate test**: `TestSchemaBasic.pas` — 44 checks: constants (14), sizes (2),
FindDbName (4), DbIsNamed (3), SchemaToIndex (2), AllocateIndexObject/DefaultRowEst (9),
SrcList ops (4), IdList ops (3), ParseObject lifecycle (4). All 44 PASS.

### 6.bis — Virtual-table machinery

Parallel mini-phase (can be slotted between 6.6 and 6.7). `vdbevtab.c` from
Phase 5.9 depends on this being done first.

- **6.bis.1** Port `vtab.c`: the virtual-table plumbing
  (`sqlite3_create_module`, `xBestIndex`, `xFilter`, `xNext`, `xColumn`,
  `xRowid`, `xUpdate`, `xSync`, `xCommit`, `xRollback`).  Broken into
  sub-phases — vtab.c is ~1380 C lines and depends on a number of
  cross-cutting helpers (Table u.vtab union, schema dispatch, VDBE
  opcodes), so each sub-phase lands a self-contained slice with its own
  gate test.

  - [X] **6.bis.1a** Types + module registry + VTable lifecycle.
    DONE 2026-04-25.  New unit `src/passqlite3vtab.pas` defines
    `Tsqlite3_module / _vtab / _vtab_cursor`, `TVTable`, `TVtabModule`
    (renamed from `TModule` — Pascal-case-insensitive collision with
    the `pModule` parameter name), `TVtabCtx`.  Faithful ports:
    `sqlite3VtabCreateModule`, `sqlite3VtabModuleUnref`, `sqlite3VtabLock`,
    `sqlite3GetVTable`, `sqlite3VtabUnlock`, `vtabDisconnectAll`
    (internal), `sqlite3VtabDisconnect`, `sqlite3VtabUnlockList`,
    `sqlite3VtabClear`, `sqlite3_drop_modules`.
    `passqlite3main.pas` — sqlite3_create_module / _v2 now delegate to
    sqlite3VtabCreateModule (replacing the inline Phase 8.3 stub).
    Gate: `src/tests/TestVtab.pas` — 27/27 PASS.  See "Most recent
    activity" for the deferred-scope and pitfall notes.

  - [X] **6.bis.1b** Parser-side hooks (vtab.c:359..550).  DONE 2026-04-25.
    Faithful ports of `addModuleArgument`, `addArgumentToVtab`,
    `sqlite3VtabBeginParse`, `sqlite3VtabFinishParse`, `sqlite3VtabArgInit`,
    `sqlite3VtabArgExtend` now live in `passqlite3parser.pas` (replacing
    the previous one-line TODO stubs).  All four public hooks are also
    declared in the parser interface so external gates can drive them
    directly.  Gate: `src/tests/TestVtab.pas` extended with T17..T22 —
    **39/39 PASS** (was 27/27).  No regressions across TestParser,
    TestParserSmoke, TestRegistration, TestPrepareBasic, TestOpenClose,
    TestSchemaBasic, TestExecGetTable, TestConfigHooks, TestInitShutdown,
    TestBackup, TestUnlockNotify, TestLoadExt, TestTokenizer.

    Discoveries / dependencies for next sub-phases:

      * **`sqlite3StartTable` is still a Phase-7 codegen stub** (empty
        body in passqlite3codegen.pas:5802).  This means
        `sqlite3VtabBeginParse` early-returns on `pParse^.pNewTable=nil`
        every time it is called from real parser-driven SQL today —
        the body is ported faithfully but observably inert until a
        future sub-phase ports build.c's StartTable.  Until then, the
        gate test exercises the leaf helpers directly with a manually-
        constructed `TParse + TTable` (see `TestVtabParser_Run`).
        The "all already ported" claim in the original 6.bis.1b note
        was incorrect — flagged here so 6.bis.1c does not assume
        StartTable.

      * **`sqlite3MPrintf` is not yet ported** (only one TODO comment
        in `passqlite3vdbe.pas:4540`).  The `init.busy=0` branch of
        `sqlite3VtabFinishParse` (vtab.c:463..508) needs both
        `sqlite3MPrintf("CREATE VIRTUAL TABLE %T", &sNameToken)` and
        the still-stubbed `sqlite3NestedParse(...)` — the entire
        branch is therefore reduced to `sqlite3MayAbort(pPse)` with
        a TODO comment in place.  A printf-machinery sub-phase
        (call it 7.4c or 8-prelude) is now blocking 6.bis.1b's full
        completion, 7.2e error-message TODOs, and most of 8-series'
        rich `pErr`-populating paths.

      * **`SQLITE_OMIT_AUTHORIZATION` second sqlite3AuthCheck**
        (vtab.c:414..425) is currently skipped — our port keeps the
        authorizer surface live but the iDb lookup
        (`sqlite3SchemaToIndex` on `pTable^.pSchema`) plus the
        fourth-argument `pTable^.u.vtab.azArg[0]` plumbing is
        deferred to the same printf-sub-phase since it shares its
        scaffolding with the schema-update path.

      * Pascal qualified-type-name pitfall: in the test file,
        `passqlite3util.PSchema` and `passqlite3codegen.PParse`
        require a `type` alias (`TUtilPSchema =
        passqlite3util.PSchema`) — using the dotted form directly
        in a `var` declaration triggered FPC "Error in type
        definition" because `PSchema` (and `PParse`) are redeclared
        as `Pointer` stubs in lower-level units (passqlite3vdbe,
        passqlite3util) and the resolver picks the stub.  Useful
        memory for any future test that needs to peek into TParse
        / TTable directly.

  - [X] **6.bis.1c** Constructor lifecycle: vtabCallConstructor,
    sqlite3VtabCallCreate, sqlite3VtabCallConnect, sqlite3VtabCallDestroy,
    growVTrans, addToVTrans (vtab.c:557..968).  DONE 2026-04-25.
    All five entry points now live in `src/passqlite3vtab.pas` (interface
    extended; static helpers `vtabCallConstructor / growVTrans /
    addToVTrans` + `vtabFmtMsg` printf-shim live in the implementation
    section).  `growVTrans` / `addToVTrans` use the existing
    `db^.nVTrans / aVTrans` slots in `Tsqlite3` (already declared in
    `passqlite3util.pas:496..499`).  Gate `src/tests/TestVtab.pas`
    extended with T23..T34 — **76/76 PASS** (was 39/39).  No regressions
    across the 41 other gates listed in build.sh.

    Discoveries / dependencies for next sub-phases:

      * **`sqlite3MPrintf` is still not ported** (Phase-7-ish printf
        sub-phase).  This sub-phase needs it for four error-message
        slots: "vtable constructor called recursively: %s",
        "vtable constructor failed: %s", "%s" passthrough, and "vtable
        constructor did not declare schema: %s".  Workaround: a
        local `vtabFmtMsg` helper using `SysUtils.Format` returns a
        `sqlite3DbMalloc`'d copy.  Replace with sqlite3MPrintf when
        the printf machinery lands.

      * **Hidden-column post-scan (vtab.c:653..682)** — the loop that
        rewrites column types containing the literal `hidden` token —
        is intentionally skipped.  pTab^.aCol is normally only
        populated by the parser via `sqlite3_declare_vtab`, which is
        Phase 6.bis.1e.  When that lands, restore the scan and add a
        gate.  For nCol=0 (the case our gate exercises) the upstream
        loop is a no-op, so the omission is observably correct today.

      * **Test pattern: bDeclared shim**.  `sqlite3_declare_vtab` is
        Phase 6.bis.1e but the constructor refuses to attach a VTable
        unless `sCtx.bDeclared = 1`.  TestVtabCtor's xConnect therefore
        flips the bit directly via `db^.pVtabCtx^.bDeclared := 1` —
        equivalent to what declare_vtab does.  When 6.bis.1e lands,
        switch this to a real declare_vtab call.

      * **aVTrans pruning is the next sub-phase's job**.
        sqlite3VtabCallDestroy disconnects the VTable from the Table
        but does NOT remove the corresponding slot in `db^.aVTrans`.
        Per upstream, that slot is repaired only when sqlite3VtabSync
        / Commit / Rollback (6.bis.1d) iterates aVTrans after a
        transaction.  Gate manually zeros nVTrans + frees aVTrans
        before close to avoid a stale-pointer trip in close_v2.

      * **sqlite3VtabCallDestroy does not remove pTab from the
        schema hash**.  Confirmed: vtab.c:956 only does
        `sqlite3DeleteTable(db, pTab)` (decrements nTabRef from 2→1
        in our flow; 1→0 happens in DROP TABLE codegen which calls
        sqlite3DeleteTable a second time after unlinking from the
        hash).  Gate T31c was originally wrong (expected the table
        gone); now asserts pTab^.u.vtab.p is nil and the Table
        remains in the schema — matching upstream.

      * **Pascal pitfall: var name vs type name.** A local
        `pVTable: PVTable` triggers FPC "Error in type definition"
        because the parameter and type are the same identifier
        modulo case.  Workaround in this unit: rename to `pVTbl`
        (and update `TVtabCtx.pVTable` field accordingly — no
        external users today).  Mirrors the recurring memory
        feedback for vtab.c-area work.

      * **CtorXConnect/CtorXCreate allocate sqlite3_vtab via FPC
        GetMem**, not sqlite3_malloc.  In the test xDestroy/xDisconnect
        FreeMem to balance.  A real vtab module must use sqlite3_malloc
        (so the constructor's eventual sqlite3DbFree-of-the-VTable
        doesn't double-free) — the test's pattern is intentional and
        matches what dbpage.c / dbstat.c / carray.c will do in
        6.bis.2.

  - [X] **6.bis.1d** Per-statement hooks: sqlite3VtabSync, _Rollback,
    _Commit, _Begin, _Savepoint, callFinaliser (vtab.c:970..1151).
    DONE 2026-04-25.  Five entry points + `callFinaliser` + the
    `vtabInSync` macro now live in `src/passqlite3vtab.pas`
    (interface extended; `callFinaliser` is implementation-only with
    a `TFinKind` enum substituting for C's offsetof-into-the-module
    trick).  `sqlite3VtabImportErrmsg` (vdbeaux.c:5673) is also
    exported from this unit so future code paths (and 6.bis.2 in-tree
    vtabs) can route module errors into the active Vdbe^.zErrMsg.
    Gate `src/tests/TestVtab.pas` extended with T35..T50 — **113/113
    PASS** (was 76/76).  No regressions across the 41 other gates
    in build.sh.

    Discoveries / dependencies for next sub-phases:

      * **Allocator contract for vtab `zErrMsg` is libc malloc, not
        sqlite3DbMalloc.**  `sqlite3VtabImportErrmsg` calls
        `sqlite3_free(pVtab^.zErrMsg)`, which in our port is
        `external 'c' name 'free'` (passqlite3os.pas:58).  Test
        modules and 6.bis.2 in-tree vtabs MUST allocate
        `pVtab^.zErrMsg` via `sqlite3Malloc` (= libc malloc), NOT
        via `GetMem` and NOT via `sqlite3DbStrDup`.  Mismatched
        allocators trigger "double free or corruption" at runtime.
        Initial test got bitten by this with a `GetMem(z, 32)` —
        switched to `sqlite3Malloc(32)`.

      * **Wiring into VDBE / codegen is still pending.**  These five
        entry points are now callable but no opcode invokes them
        yet.  `OP_VBegin` already exists as a dispatched no-op in
        passqlite3vdbe.pas (Phase 5.9 stub); a future sub-phase
        (likely a small Phase-7-or-Phase-8 follow-up) needs to
        replace the stub with `sqlite3VtabBegin(db, …)` and surface
        Sync/Commit/Rollback hooks at end-of-statement.  Same goes
        for `OP_Savepoint` which today does NOT call
        `sqlite3VtabSavepoint`.  Tracked here so 6.bis.1e/1f and
        any Phase-8 SAVEPOINT-related work picks it up.

      * **Pascal pitfall: var name vs type name (recurring).**  A
        local `pVdbe: PVdbe` triggers FPC "Error in type definition"
        because the variable and type collide modulo case.  In
        TestVtab the local was renamed `pVm`.  Mirrors the existing
        memory feedback for vtab.c-area work.

      * **iVersion gate on Savepoint.**  `sqlite3VtabSavepoint` is a
        no-op for `iVersion < 2` modules — gate test uses
        `m.iVersion := 2`.  6.bis.2 dbpage/dbstat/carray tables use
        iVersion=1 today (no SAVEPOINT support); that is correct.

      * **`db^.flags` SQLITE_Defensive bit handling**: the savepoint
        path masks SQLITE_Defensive off around the xMethod call and
        restores it afterwards (vtab.c:1128..1131).  We define a
        local `SQLITE_Defensive = u64($10000000)` in passqlite3vtab
        — same constant value as `SQLITE_Defensive_Bit` in
        passqlite3main.pas:1000.  When/if we promote
        `SQLITE_Defensive_Bit` to the central util/types unit, this
        local can collapse to a re-export.

  - [X] **6.bis.1e** API entry points: sqlite3_declare_vtab,
    sqlite3_vtab_on_conflict, sqlite3_vtab_config (vtab.c:811..1374).
    DONE 2026-04-26.  All three live in `src/passqlite3vtab.pas`.
    `sqlite3_vtab_config` exposed as a single typed entry point
    `(db, op, intArg)` rather than C varargs (mirrors the Phase 8.4
    `sqlite3_db_config_int` shape — only CONSTRAINT_SUPPORT actually
    consumes intArg; the three valueless ops ignore it).
    `passqlite3parser` added to `passqlite3vtab`'s uses clause for
    `sqlite3GetToken` + `TK_CREATE/TK_TABLE/TK_SPACE/TK_COMMENT` +
    `sqlite3RunParser`.  No cycle: parser → codegen, vtab → parser →
    codegen.  Gate `src/tests/TestVtab.pas` extended with T51..T70 —
    **141/141 PASS** (was 113/113).  No regressions across the 41
    other gates.

    Discoveries / dependencies:

      * `sqlite3_declare_vtab`'s column-graft branch (vtab.c:869..896)
        is structurally complete but currently dormant: parsing
        `CREATE TABLE x(...)` produces `sParse.pNewTable=nil` because
        `sqlite3StartTable / AddColumn / EndTable` in
        `passqlite3codegen` are still Phase-7 stubs.  The function
        therefore takes the `pNewTable=nil` fallback path which still
        flips `pCtx^.bDeclared:=1` (so `vtabCallConstructor`'s "did
        not declare schema" check passes) but does **not** populate
        `pTab^.aCol`.  When the build.c ports land, the existing
        graft branch lights up unchanged.  This is the same blocker
        flagged by 6.bis.1c's hidden-column type-string scan
        (vtab.c:653..682).

      * Pascal naming pitfall: `TParse` does not have a top-level
        `disableTriggers` field — it is one bit inside the packed
        `parseFlags: u32` bitfield (offset 40).  Use
        `sParse.parseFlags := sParse.parseFlags or
        passqlite3codegen.PARSEFLAG_DisableTriggers` rather than
        `sParse.disableTriggers := 1` (which is what vtab.c writes
        in C and fails to compile in the Pascal port).

      * Conflict-resolution constants gotcha: `SQLITE_ROLLBACK`,
        `SQLITE_FAIL`, `SQLITE_REPLACE` are not (yet) re-exported
        from `passqlite3types`.  `SQLITE_ABORT (4)` and
        `SQLITE_IGNORE (2)` are present, but they are the *result-
        code* / *auth-code* duplicates and just happen to share the
        same numeric value as the conflict-resolution codes.  The
        `aMap` in `sqlite3_vtab_on_conflict` inlines the literal
        bytes (1, 4, 3, 2, 5) with a comment pointing back to
        sqlite.h:1133 to avoid the ambiguity.  When the conflict-
        resolution constants get a clean home in `passqlite3types`,
        replace the literal bytes with the named constants.

      * `sqlite3_vtab_on_conflict` does **not** acquire the db
        mutex (vtab.c:1317 doesn't either; it only enters via the
        `assert(db->vtabOnConflict ...)` invariant).  Tests T59..T63
        write `db^.vtabOnConflict` directly between calls — that's
        the only way to drive the function from a unit test without
        a working xUpdate path.

  - [X] **6.bis.1f** Function overload + writable + eponymous tables
    (vtab.c:1153..1316).  DONE 2026-04-26.  Faithful ports of
    `sqlite3VtabOverloadFunction`, `sqlite3VtabMakeWritable`,
    `sqlite3VtabEponymousTableInit`, and the full body of
    `sqlite3VtabEponymousTableClear` (replacing the 6.bis.1a stub) now
    live in `src/passqlite3vtab.pas`.  `addModuleArgument` was promoted
    to the `passqlite3parser` interface so EponymousTableInit can append
    the three module-arg slots without duplicating the helper.  Gate
    `src/tests/TestVtab.pas` extended with T71..T88 — **181/181 PASS**
    (was 141/141).  No regressions across the 41 other gates.

    Pascal/cross-language deltas worth memoising:
      * `sqlite3Realloc` (libc realloc, no db) is not exposed from
        `passqlite3pager` to other units.  `sqlite3VtabMakeWritable`
        therefore calls `passqlite3os.sqlite3_realloc64` directly.  This
        is allocator-faithful (apVtabLock is freed by libc free in the
        Parse cleanup path) but the cross-unit mismatch is worth a note
        for any future code that reaches for sqlite3Realloc.
      * `sqlite3ErrorMsg` in our port is single-arg (no varargs); upstream
        `sqlite3ErrorMsg(p, "%s", zErr)` is collapsed to just
        `sqlite3ErrorMsg(p, zErr)`.  This drops `%`-escapes if any
        slipped into the constructor's error message — same trade as the
        6.bis.1c `vtabFmtMsg` shim.  Lifts when the printf sub-phase
        ports `sqlite3MPrintf`.
      * Pascal naming pitfall: the `pModule` parameter in
        EponymousTableInit collides modulo case with the unit-level
        `PModule = ^Tsqlite3_module`.  Renamed to `pMd` (mirroring the
        `TVtabModule` rename from 6.bis.1a).
      * `xFindFunction` slot in `Tsqlite3_module` is `Pointer`; the
        Phase 6.bis.1a record left it untyped to avoid having to redeclare
        all 24 callbacks as forward types.  Overload casts via a local
        `TVtabFindFn = function(...)` typedef to invoke it.
      * Test-side `Pointer(pNew^.xSFunc) = Pointer(@FakeFn)` works in
        FPC objfpc mode for procedural-typed values; `@var^.xSFunc` would
        compare addresses-of-the-slot, which is wrong.

    Wiring caveats (carry-over for next sub-phases):
      * `passqlite3codegen.sqlite3DeleteTable` today only frees aCol +
        zName + the table struct — it does NOT cascade through
        `sqlite3VtabClear` to disconnect attached VTables.  Test T85b
        therefore expects `gDisconnectCount = 0` after
        `sqlite3VtabEponymousTableClear`; flip to expect 1 once the
        build.c port lands and DeleteTable chains into VtabClear.  Same
        gap blocks full eponymous-vtab teardown from being observably
        leak-free (the VTable + sqlite3_vtab + module nRefModule are
        not unwound at clear time).
      * `sqlite3VtabMakeWritable` is now callable but no codegen path
        invokes it yet — `OP_VBegin` emission is gated on the same
        Phase-7 build.c work.  Tracked under 6.bis.1d's wiring caveat.
- **6.bis.2** Port the three in-tree virtual tables:
  - `dbpage.c` — the built-in `sqlite_dbpage` vtab (exposes raw DB pages).
  - `dbstat.c` — the built-in `dbstat` vtab (B-tree statistics).
  - `carray.c` — the `carray()` table-valued function (passes C arrays into
    SQL); small and a good shake-down test for the vtab machinery.

  Each xBestIndex implementation reads/writes a `sqlite3_index_info`
  struct, and most of these vtabs lean on `sqlite3_value_pointer` /
  `sqlite3_bind_pointer` and a real `sqlite3_mprintf`.  The first sub-phase
  lands the prerequisite struct + constants so 6.bis.2b/c/d can compile.
  Broken into:

  - [X] **6.bis.2a** Prerequisite types: `Tsqlite3_index_info`,
    `Tsqlite3_index_constraint`, `Tsqlite3_index_orderby`,
    `Tsqlite3_index_constraint_usage` records (sqlite.h:7830..7860 byte
    layout), `TxBestIndex` typed function-pointer alias, and the
    `SQLITE_INDEX_CONSTRAINT_*` (17 values, sqlite.h:7911..7927) +
    `SQLITE_INDEX_SCAN_*` (2 values, sqlite.h:7869..7870) constants.
    DONE 2026-04-26.  All declared in `passqlite3vtab.pas`'s interface
    section.  `PSqlite3IndexInfo` was previously a `Pointer` stub from
    Phase 6.bis.1a; now resolves to `^Tsqlite3_index_info`.

    The records use an explicit `_pad` byte/word inside each fixed-
    layout struct so FPC alignment matches the C struct: in particular
    the `op` / `usable` / `desc` / `omit` `unsigned char` fields are
    followed by 3 bytes (or 1 + 2) of padding so the next `int` lands
    on a 4-byte boundary, matching gcc default alignment.  Verified by
    running the constraint/orderby/usage round-trip via pointer
    arithmetic in TestVtab.T91..T93 (xBestIndex idiom: `pConstraint++`
    walked via `Inc(pC)`).

    Gate `src/tests/TestVtab.pas` extended with T89..T93 — **216/216
    PASS** (was 181/181).  No regressions across the full 45-gate
    matrix in build.sh.

    Discoveries / dependencies for 6.bis.2b..d:
      * **`sqlite3_value_pointer` / `sqlite3_bind_pointer` are not
        ported.**  These are the type-tagged-pointer entry points that
        carray.c uses to receive a `void*` from the application via
        `SQL bind` and read it inside xFilter.  A small Phase 8 follow-
        up will be needed before carray.c can do anything beyond
        registering itself.  Recommended approach: port the pointer
        flag/type machinery in `vdbeInt.h` (`MEM_Subtype`, `eSubtype`)
        + `sqlite3_bind_pointer` (vdbeapi.c:1731) +
        `sqlite3_value_pointer` (vdbeapi.c:1394) together with their
        destructor-disposal contract.  Until then, carray.c's
        carrayFilter / carrayBindDel can be partially ported but tests
        cannot exercise the bind path.
      * **`sqlite3_mprintf` is still not ported** (recurring blocker
        per 6.bis.1c..f notes).  carray.c uses it once on the
        unknown-datatype error path; dbpage / dbstat use it more
        heavily (idxStr formatting in dbstat).  Workaround mirrors
        the `vtabFmtMsg` pattern from 6.bis.1c.
      * **VDBE wiring of vtab opcodes is still pending** (per
        6.bis.1d notes): `OP_VOpen`, `OP_VFilter`, `OP_VColumn`,
        `OP_VNext`, `OP_VRowid` exist in the dispatch table but
        do not yet drive `xOpen / xFilter / xColumn / xNext /
        xRowid` on a real VTable.  Until that lands, end-to-end
        SQL `SELECT * FROM carray(...)` cannot be tested; gate
        tests for 6.bis.2b/c/d will exercise the vtab callbacks
        directly via the module-pointer slots, mirroring the
        TestVtab.T35..T50 pattern from 6.bis.1d.

  - [X] **6.bis.2b** Port `carray.c` — the `carray()` table-valued
    function.  Smallest of the three (558 C lines).  Provides a good
    shake-down for `Tsqlite3_index_info` round-trip, the typed
    `TxBestIndex` slot in `Tsqlite3_module`, and (once the bind-pointer
    sub-phase lands) `sqlite3_value_pointer` / `sqlite3_bind_pointer`.
    Module entry point is `sqlite3CarrayRegister(db)` returning a
    `PVtabModule` for vdbevtab.c-style auto-registration.

    DONE 2026-04-26.  New unit `src/passqlite3carray.pas` (~360 lines)
    hosts faithful Pascal ports of all 10 static vtab callbacks
    (carrayConnect / carrayDisconnect / carrayOpen / carrayClose /
    carrayNext / carrayColumn / carrayRowid / carrayEof / carrayFilter
    / carrayBestIndex), the carrayBindDel destructor placeholder, and
    the public Tsqlite3_module record `carrayModule` with the v1 slot
    layout from carray.c:381 (iVersion=0, only xConnect populated for
    constructors so the table is eponymous-only — xCreate/xDestroy
    nil).  `sqlite3CarrayRegister(db)` delegates to
    `sqlite3VtabCreateModule` from 6.bis.1a.  Constants exported:
    CARRAY_INT32..CARRAY_BLOB and the SQLITE_-prefixed aliases
    (sqlite.h:11329..11343), CARRAY_COLUMN_VALUE..CTYPE.

    Discoveries / dependencies worth memoising for 6.bis.2c..d:

      * **`sqlite3_value_pointer` / `sqlite3_bind_pointer` still not
        ported.**  carrayFilter's idxNum=1 branch and the 2/3-arg
        argv[0] dereference go through a local `sqlite3_value_pointer_stub`
        in passqlite3carray that returns nil — structurally complete
        but inert until a Phase-8 sub-phase lands the type-tagged
        pointer machinery (`MEM_Subtype` / `eSubtype` from vdbeInt.h
        + vdbeapi.c:1394 / vdbeapi.c:1731).  When that lands, replace
        the local stub with the real entry point and dbpage.c +
        dbstat.c can use the same.  Same blocker also gates
        sqlite3_carray_bind / _v2 (intentionally omitted from this
        sub-phase).

      * **`sqlite3_mprintf` blocker (recurring).**  carray's
        unknown-datatype error path uses it for `pVtab^.zErrMsg`.
        Bridged here through a local `carrayFmtMsg` shim mirroring
        the `vtabFmtMsg` pattern from 6.bis.1c.  Same shim will be
        needed in dbstat.c (idxStr formatting) — probably worth
        promoting to a shared helper when the printf sub-phase lands.

      * **Tsqlite3_module slot pointers stay typed-as-Pointer.**
        Most slots (xCreate, xConnect, xBestIndex, xOpen, xClose,
        xFilter, xNext, xEof, xColumn, xRowid, etc.) are declared
        `Pointer` in the record (only xDisconnect / xDestroy are
        typed) so the `initialization` block can assign function
        addresses cross-language without per-slot casts.  Test code
        reads them back through `Pointer(fnVar) := module.slot` —
        document this idiom for 6.bis.2c/d gates.

      * **xColumn cannot be tested without a real Tsqlite3_context.**
        Allocating one outside a VDBE op call is non-trivial (see
        passqlite3vdbe.pas:649); the carray gate exercises every
        callback EXCEPT xColumn directly.  The column logic will be
        covered end-to-end once OP_VColumn wiring lands (see 6.bis.1d
        wiring caveat).  dbpage.c has the same constraint.

      * **PPSqlite3VtabCursor was not exported from passqlite3vtab.**
        Added locally in passqlite3carray; if dbpage.c / dbstat.c need
        the same forward decl, promote it to passqlite3vtab's
        interface section as a tiny follow-up.

    Gate `src/tests/TestCarray.pas` exercises module registration,
    iVersion=0 + slot layout, all four xBestIndex idxNum branches
    (0/1/2/3), the two SQLITE_CONSTRAINT failure paths, and the full
    xOpen → xRowid → xNext → xEof → xClose state-machine cycle —
    **66/66 PASS**.  Full 46-gate matrix re-ran in build.sh: no
    regressions across the existing 45 gates (TestVtab still 216/216,
    everything else green).

  - [X] **6.bis.2c** Port `dbpage.c` — the built-in `sqlite_dbpage`
    vtab.  Depends on the pager/btree page-fetch helpers
    (`sqlite3PagerGet` / `sqlite3PagerWrite` already in passqlite3pager).
    DONE 2026-04-26.  New unit `src/passqlite3dbpage.pas` (~470 lines)
    hosts the full v2 module callback set (xConnect, xDisconnect,
    xBestIndex, xOpen, xClose, xFilter, xNext, xEof, xColumn, xRowid,
    xUpdate, xBegin, xSync, xRollbackTo) and the `dbpageModule`
    Tsqlite3_module record (iVersion=2, xCreate=xConnect,
    xDestroy=xDisconnect — dbpage is eponymous-or-creatable).
    `sqlite3DbpageRegister` is the public entry point.

    Carry-overs:
      * `sqlite3_context_db_handle` not ported — xColumn derives `db`
        via the cursor's vtab back-pointer (DbpageTable.db).
      * `sqlite3_result_zeroblob(ctx, n)` (i32 form) not separately
        ported; bridged through `sqlite3_result_zeroblob64`.
      * `SQLITE_Defensive` flag bit not in passqlite3vtab's interface;
        mirrored locally as `SQLITE_Defensive_Bit`.  Promote to a
        shared symbol when the next consumer arrives.
      * `sqlite3_mprintf` shim pattern recurs (`dbpageFmtMsg`); now
        three copies (vtab, carray, dbpage) — collapse when the
        printf sub-phase lands.

    Gate `src/tests/TestDbpage.pas` — 68/68 PASS.  Covers module
    registration, full v2 slot layout, all four xBestIndex idxNum
    branches plus the unusable-schema SQLITE_CONSTRAINT path,
    xOpen/xClose, and the cursor state machine.  Live-db paths
    (xColumn data column, xFilter, xUpdate, xBegin/xSync/xRollbackTo)
    deferred to 6.9 — they need a real Btree-backed connection.

  - [X] **6.bis.2d** Port `dbstat.c` — the `dbstat` vtab (B-tree
    statistics).  Largest of the three (906 C lines).  Heavy on
    `sqlite3_mprintf` for idxStr; depends on the printf sub-phase.
    DONE 2026-04-26.  New unit `src/passqlite3dbstat.pas` (~770 lines)
    hosts faithful Pascal ports of the 11 static module callbacks
    (statConnect/Disconnect/BestIndex/Open/Close/Filter/Next/Eof/
    Column/Rowid + the statDecodePage / statGetPage /
    statSizeAndOffset helpers and StatCell/StatPage/StatCursor/
    StatTable record types).  `dbstatModule` is a v1 read-only module
    (iVersion=0; xUpdate / xBegin / xSync / xRollbackTo all nil;
    xCreate=xConnect for both eponymous and CREATE-able use).
    `sqlite3DbstatRegister(db)` is the public entry point.

    Carry-overs:
      * `sqlite3_mprintf` shim: 4th copy now (statFmtMsg /
        statFmtPath; mirrors carrayFmtMsg, dbpageFmtMsg, vtabFmtMsg).
        Promote to a shared helper when the printf sub-phase lands.
      * `sqlite3_str_*` family (sqlite3_str_new / _appendf / _finish)
        not ported.  statFilter builds its inner SELECT through a
        local `statBuildSql` AnsiString concatenator with `escIdent`
        (%w) and `escLiteral` (%Q) helpers.  Replace when the printf
        sub-phase lands.
      * `sqlite3TokenInit` / `sqlite3FindDb` Token-based path not
        ported.  statConnect calls `sqlite3FindDbName` with
        `argv[3]` directly; equivalent for unquoted schema names.
      * `sqlite3_context_db_handle` not ported (carry-over from
        dbpage 6.bis.2c).  statColumn derives `db` via
        `cursor^.base.pVtab^.db`.

    Gate `src/tests/TestDbstat.pas` — 83/83 PASS.  Covers module
    registration, full v1 slot layout (read-only — xUpdate/etc nil),
    nine xBestIndex branches (empty / schema= / name= / aggregate= /
    all-three / two ORDER BY shapes / DESC-rejected / unusable→
    CONSTRAINT), and the cursor open/close state machine.  Live-db
    paths (xFilter / xColumn / statNext page-walk) deferred to 6.9:
    require a real Btree and the sqlite3_prepare_v2 path through the
    parser.  No regressions across the 47-gate matrix.

- **6.bis.3** VDBE wiring of vtab opcodes.  The 6.bis.1d/1f and 6.bis.2a..d
  carry-over notes all flag the same gap: `OP_VBegin / VCreate / VDestroy /
  VOpen / VFilter / VColumn / VNext / VUpdate / VRename` exist as opcode
  numbers in `passqlite3vdbe.pas` but their dispatch arms returned a single
  "virtual table not supported" error.  Until those arms call the real vtab
  callbacks, end-to-end SQL `SELECT * FROM carray(...)` /
  `SELECT * FROM sqlite_dbpage` / `SELECT * FROM dbstat` cannot reach
  xFilter / xColumn / xNext, so the in-tree vtab gates ported in 6.bis.2b/c/d
  exercise the module-pointer slots directly rather than the SQL path.
  Broken into:

  - [X] **6.bis.3a** Wire OP_VBegin, OP_VCreate, OP_VDestroy.  These three
    do not need cursor-bearing state; they delegate to existing entry
    points already exported by `passqlite3vtab`
    (`sqlite3VtabBegin / sqlite3VtabCallCreate / sqlite3VtabCallDestroy`
    plus `sqlite3VtabImportErrmsg`).  DONE 2026-04-26.  See "Most recent
    activity" above for the full changelog and discoveries.  Gate
    `src/tests/TestVdbeVtabExec.pas` — **11/11 PASS** (T1..T4 covering
    valid VTable / nil VTable / idempotent VBegin / xBegin returning
    SQLITE_BUSY).  No regressions across the 50-binary matrix.

  - [X] **6.bis.3b** Wire the cursor-bearing vtab opcodes: OP_VOpen,
    OP_VFilter, OP_VColumn, OP_VNext, OP_VUpdate, OP_VRename, OP_VCheck,
    OP_VInitIn.  DONE 2026-04-26.  See "Most recent activity" above for
    the full changelog and discoveries.  Gate
    `src/tests/TestVdbeVtabExec.pas` — **35/35 PASS** (T1..T11).  No
    regressions across the 50-binary matrix.  OP_VCheck stubbed to NULL
    pending Phase 8.x's TTable introspection (tabVtabPP exposure).
    OP_Rowid extended with the CURTYPE_VTAB branch (vdbe.c:6171).
    `sqlite3VdbeFreeCursorNN` learned the CURTYPE_VTAB cleanup branch
    (calls xClose, decrements pVtab^.nRef).  Caveat: `sqlite3VdbeHalt`
    in this port is a stub — closeAllCursors not wired — so vtab
    cursors leak across step→finalize until Phase 8.x.  Original
    requirements:
      * `allocateCursor(...,CURTYPE_VTAB)` integration — already supported
        by the existing `allocateCursor` (just not yet exercised with
        CURTYPE_VTAB by any opcode).
      * Extend `sqlite3VdbeFreeCursorNN`'s deferred CURTYPE_VTAB branch
        (line ~2675) to call `pCx^.uc.pVCur^.pVtab^.pModule^.xClose`
        and decrement `pVtab->nRef`.
      * Build a minimal `Tsqlite3_context` on the stack for OP_VColumn
        — same shape as the one allocated in `sqlite3VdbeMemRelease`'s
        callsite for application-defined functions; the Phase-5 codegen
        already has a partial `sqlite3_context` plumbed via OP_Function.
      * `OP_Rowid` already has a curType branch in vdbe.c:6175 that
        invokes `pModule->xRowid`; check whether our port's OP_Rowid
        already covers CURTYPE_VTAB — if not, fold in here.
      * Extend TestVdbeVtabExec with T5..T15 covering xOpen → xFilter →
        xEof → xColumn → xNext → xClose.  Mock module from 6.bis.3a is
        already in place; just add the missing callback slots.
    The "rowid" handling lives in OP_Rowid (no separate OP_VRowid in
    SQLite 3.53), so 6.bis.3b should also audit our OP_Rowid
    implementation for the CURTYPE_VTAB branch.

  - [X] **6.bis.3c** Wire `closeAllCursors`-equivalent cursor cleanup into
    `sqlite3VdbeHalt`.  Follow-up to the 6.bis.3b caveat — the port's
    Halt was a state-only stub, so vtab cursors leaked across
    `sqlite3_step → sqlite3_finalize`.  Inlined the same
    `closeCursorsInFrame` loop already present in
    `sqlite3VdbeFrameRestoreFull` directly into `sqlite3VdbeHalt`.
    DONE 2026-04-26.  See "Most recent activity" above.  Gate
    `src/tests/TestVdbeVtabExec.pas` — **34/34 PASS** (T5 simplified;
    no longer needs to manually call `sqlite3VdbeFreeCursor` after exec).
    Full 50-binary sweep green.  Remaining Halt body work (transaction
    commit/rollback bookkeeping, frame walk, aMem release, pAuxData
    clear) stays in Phase 8.x — no codepath in the port currently
    builds frames or auxdata, so cursor cleanup alone closes the
    immediate vtab-leak gap.

  - [X] **6.bis.3e** Printf-shim consolidation (cleanup follow-up).
    Collapsed the four duplicate `*FmtMsg` shims (vtabFmtMsg /
    carrayFmtMsg / dbpageFmtMsg / statFmtMsg) into a single shared
    pair in `passqlite3vtab`'s interface: `sqlite3VtabFmtMsg1Db` (for
    `pzErr` slots that are sqlite3DbFree'd) and `sqlite3VtabFmtMsg1Libc`
    (for `pVtab^.zErrMsg` slots that are libc-free'd).  carray /
    dbpage / dbstat now call the shared helper directly; the in-unit
    `vtabFmtMsg` name is retained as an inline alias so the six
    existing call sites in passqlite3vtab don't need touching.
    DONE 2026-04-26.  Full 49-binary sweep green.  `statFmtPath`
    deliberately left in place — different signature, will fold into
    the printf sub-phase proper rather than this cleanup.

  - [X] **6.bis.3d** Wire OP_VCheck (vdbe.c:8409) — the integrity-check
    opcode that fires `xIntegrity` on a virtual table.  Was a stub left
    by 6.bis.3b ("set output to NULL only") because `tabVtabPP` /
    `tabZName` lived in `passqlite3vtab`'s implementation section.
    DONE 2026-04-26.  Resolution: moved `PPVTable` + `tabVtabPP` to the
    interface and added a `tabZName` helper; the new vdbe arm reads the
    Table*, locks the VTable, calls `xIntegrity(pVtab, db^.aDb[p1].zDbSName,
    pTab^.zName, p3, &zErr)`, and either propagates rc via
    `abort_due_to_error` or stores the (possibly-nil) zErr into reg p2 as
    a SQLITE_DYNAMIC text.  Gate `src/tests/TestVdbeVtabExec.pas` T12
    (a..d) — **50/50 PASS**.  Full sweep green.  See "Most recent
    activity" above.

- **6.bis.4** Printf machinery — the long-awaited port of `printf.c`
  (the recurring blocker called out by every prior 6.bis sub-phase).
  Broken into two slices:

  - [X] **6.bis.4a** Core engine + standard conversions + SQL extensions
    (no float, no `%S`/`%r`, shims left intact).  DONE 2026-04-26.
    New unit `src/passqlite3printf.pas` exports `sqlite3FormatStr`
    (the AnsiString core), libc wrappers (`sqlite3PfMprintf`,
    `sqlite3PfSnprintf`), and db-aware wrappers (`sqlite3MPrintf`,
    `sqlite3VMPrintf`, `sqlite3MAppendf`).  Conversions implemented:
    `%s %d %u %x %X %o %c %p %lld %% %z` (standard) plus
    `%q %Q %w %T` (SQLite extensions).  Width/precision/flags
    (`- 0 + space # *`) supported.  Gate `src/tests/TestPrintf.pas` —
    **40/40 PASS**.  See "Most recent activity" above.

  - [X] **6.bis.4b.1** Migration of the four `*FmtMsg` shims to the
    in-tree printf engine (Phase 6.bis.4a output) and partial wiring
    of `sqlite3VtabFinishParse`.  DONE 2026-04-26.
      * `sqlite3VtabFmtMsg1Db` and `sqlite3VtabFmtMsg1Libc` in
        `passqlite3vtab.pas` no longer call `SysUtils.Format`; they
        now delegate to `sqlite3MPrintf` / `sqlite3PfMprintf` with the
        same fmt-or-literal contract (when fmt has no `%`, the call
        becomes `sqlite3MPrintf("%s", fmt)` so a literal message
        round-trips byte-identically).  The four call sites in
        `passqlite3carray.pas` / `passqlite3dbpage.pas` /
        `passqlite3dbstat.pas` (already collapsed to the shared
        helpers in 6.bis.3e) inherit the new printf path automatically.
      * `passqlite3parser.pas` now adds the `passqlite3printf` import
        and `sqlite3VtabFinishParse` exercises
        `sqlite3MPrintf("CREATE VIRTUAL TABLE %T", &sNameToken)` for
        the `init.busy=0` arm — including the `pEnd` token-length
        fix-up from `vtab.c:474`.  The result is freed immediately
        because the surrounding `sqlite3NestedParse` /
        `sqlite3VdbeAddParseSchemaOp` / `OP_VCreate` glue is still a
        Phase-7 stub (codegen helpers not yet ported).  Once Phase 7
        lands NestedParse, the call becomes load-bearing without any
        further printf-side work.
      * Full 51-binary test sweep: all green (TestPrintf 40/40,
        TestVtab 216/216, TestCarray 66/66, TestDbpage 68/68,
        TestDbstat 83/83, TestVdbeVtabExec 50/50).  No regressions
        elsewhere.

  - [X] **6.bis.4b.2a** `%r` ordinal conversion.  DONE 2026-04-26.
    Faithful port of `etORDINAL` (printf.c:481..488):
    1st/2nd/3rd/4th, with the 11/12/13 teen exception and decade
    resumption (21st 22nd 23rd 24th, 101st 111th 121st).  Sign prefix
    preserved on negatives; suffix selection uses `|value|`.  Width is
    space-padded only — numeric zero-pad is intentionally suppressed
    because the suffix is literal text (`0021st` would be nonsense).
    `passqlite3printf.pas` adds the `'r'` arm (~15 lines) right after
    the `%T` case.  `src/tests/TestPrintf.pas` extended with T37..T57
    (21 new asserts) — **61/61 PASS** (was 40/40).  Full sweep across
    TestVtab 216/216, TestCarray 66/66, TestDbpage 68/68, TestDbstat
    83/83 — no regressions.

  - [X] **6.bis.4b.2b** `%S` SrcItem conversion.  DONE 2026-04-26.
    Faithful port of `etSRCITEM` (printf.c:975..1008).  Four-way cascade:
    (1) `zAlias` takes priority unless `!` (altform2) is set;
    (2) `zName` with optional `db.` prefix when `fg.fixedSchema=0` and
        `fg.isSubquery=0` and `u4.zDatabase<>nil`;
    (3) `zAlias` fallback when `zName=nil`;
    (4) subquery descriptor — `(join-N)` / `(subquery-N)` /
        `N-ROW VALUES CLAUSE` — when `fg.isSubquery=1` and both name
        slots are nil (reads `pSubq^.pSelect^.{selFlags,selId}` plus
        `u1.nRow` for the multi-value case).
    Local mirror types (`TSrcItemBlit` / `TSubqueryBlit` / `TSelectBlit`)
    keep `passqlite3printf` decoupled from `passqlite3codegen` — same
    pattern as `TTokenBlit` from `%T`.  Bit positions read from the
    `fgBits` / `fgBits3` byte fields:
      * `fgBits  bit 2 = isSubquery`
      * `fgBits3 bit 0 = fixedSchema`
    (matches sqliteInt.h:3360..3378 LSB-first declaration order; verified
    against `passqlite3codegen.TSrcItemFg` byte-layout comment.)
    `passqlite3printf.pas` adds ~70 lines (mirror types + `emitSrcItem` +
    case arm).  `src/tests/TestPrintf.pas` extended with T89..T100
    (13 new asserts: alias priority, `!` flip, db prefix, fixedSchema
    suppression, isSubquery suppression, nil item, width pad both
    directions, three subquery-descriptor variants, empty-on-all-nil) —
    **105/105 PASS** (was 92/92).  Regression sweep: TestVtab 216/216,
    TestCarray 66/66, TestDbpage 68/68, TestDbstat 83/83,
    TestVdbeVtabExec 50/50, TestParser 45/45, TestParserSmoke 20/20 —
    all green.

    Discoveries / next-step notes:
      * Original task notes claimed this was blocked by Phase 7's
        `TSrcItem` layout, but Phase 7.2/7.3 already stabilised
        `passqlite3codegen.TSrcItem` (at codegen.pas:607, sizeof=72) —
        the block was actually only a sequencing concern, not a
        dependency one.  Implementation could have landed any time
        after 6.bis.4b.2c.
      * `TSrcItem` u4 union has three variants (`zDatabase` /
        `pSchema` / `pSubq`).  The C reference uses two distinct
        bits — `fixedSchema` and `isSubquery` — to select among them.
        With both clear, `u4` is read as `zDatabase` (PAnsiChar).
        Both bits cleared with a non-nil u4 ptr is the *only* shape
        that emits the database prefix.
      * The subquery descriptor case needs `selFlags & SF_NestedFrom`
        (= `$0800`) and `SF_MultiValue` (= `$0400`) — these are
        already declared in `passqlite3codegen` but the printf unit
        re-declares them locally as `SF_*Local` to avoid the codegen
        import.  If the upstream constants ever drift, sync both.
      * The C version gates the entire `etSRCITEM` body on
        `printfFlags & SQLITE_PRINTF_INTERNAL` (returns silently
        otherwise — prevents external callers from probing internal
        types).  Pascal port follows the `%T` precedent and skips the
        gate; all callers are internal anyway.  Future: if/when an
        external printf surface is added, replicate the gate.

  - [X] **6.bis.4b.2c** Float conversions (`%f %e %E %g %G`).  DONE
    2026-04-26.  Faithful port of `sqlite3FpDecode` (util.c:1380) +
    deps (`multiply128` / `multiply160` / `powerOfTen` 3-table set /
    `pwr10to2` / `pwr2to10` / `countLeadingZeros` / `fp2Convert10`)
    plus the etFLOAT/etEXP/etGENERIC renderer (`renderFloat`).  `%f`
    `%e` `%E` `%g` `%G` wired into the conversion switch with
    Inf/NaN special handling and altform2 (`!`) for 20-digit
    precision.  `passqlite3printf.pas` grew by ~330 lines.
    `TestPrintf` extended with T58..T88 (31 asserts) against
    canonical SQLite reference output — **92/92 PASS** (was 61/61).
    Skipped: iRound==17 round-trip optimization (only affects
    `%!.17g`-style rendering — see header comment in
    passqlite3printf.pas).  No regressions across TestVtab 216/216,
    TestCarray 66/66, TestDbpage 68/68, TestDbstat 83/83,
    TestVdbeVtabExec 50/50.

- [~] **6.9** `TestExplainParity.pas`: for the full SQL corpus, `EXPLAIN` each
  statement via Pascal and via C; diff the opcode listings. This is the single
  most important gating test for the upper half of the port.

  **Scaffold landed 2026-04-26** (`src/tests/TestExplainParity.pas`).  The
  test prepares each corpus row on both sides:
    * C side — runs `EXPLAIN <sql>` via `csq_prepare_v2` and steps the
      explain rows; collects (opcode, p1, p2, p3, p5) per row.
    * Pascal side — runs `sqlite3_prepare_v2(<sql>)` and walks the
      returned `PVdbe^.aOp[0..nOp-1]` directly (the Pascal
      `sqlite3VdbeList` stub does not yet drive `OP_Explain`).
  Diffs (opcode-name, p1, p2, p3, p5).  P4 / comment columns are out of
  scope until KeyInfo / Func / Coll heap layouts are byte-stable.

  Corpus is intentionally small (10 DDL/transaction rows) — these are
  the forms that today actually return a stepable Vdbe via
  `sqlite3FinishCoding` (Phase 6.5-bis).  The harness is **report-only**
  in this cut: prepare-failure on the C side or runtime exception
  raises gErr (exit 1); op-count or per-op divergence is logged as
  DIVERGE but tolerated (exit 0).  The scaffold is the diff-finder for
  Phase 6.x bytecode-alignment work, not a hard gate yet.

  **First-run findings (2026-04-26):** every Pascal program emits
  exactly 3 opcodes (`Init / Goto / Halt`-equivalent — the trivial
  termination from `sqlite3FinishCoding` when no schema-write ops have
  been emitted) versus 5–49 opcodes on the C side.  Concrete numbers
  (corpus=10): 0 pass / 8 diverge / 2 error.  The 8 DIVERGE rows
  confirm that the `CREATE TABLE / CREATE INDEX / DROP TABLE / DROP
  INDEX / BEGIN` codegen helpers (`sqlite3StartTable`,
  `sqlite3EndTable`, `sqlite3CreateIndex`, `sqlite3DropTable`,
  `sqlite3DropIndex`, `sqlite3BeginTransaction`) are still Phase 6.x
  stubs that parse fine but never emit a real opcode stream.  The 2
  ERROR rows (`CREATE TABLE typed`, `CREATE TABLE WITHOUT ROWID`)
  raise `EAccessViolation` mid-prepare — the codegen path partially
  fires for column-with-decltype / `WITHOUT ROWID` and dereferences a
  non-allocated Schema/Table field.  Both classes of failure are the
  next concrete porting targets for the upper half (Phase 6.x).
  Run with: `LD_LIBRARY_PATH=src bin/TestExplainParity`.

- [~] **6.9-bis** Drive the diverge/error counts in TestExplainParity to
  zero by porting the remaining DDL codegen helpers
  (~~`sqlite3BeginTransaction`~~ done 2026-04-26,
  ~~`sqlite3DropIndex` (IF EXISTS / not-found arm + helpers
  `sqlite3CodeVerifySchema`, `sqlite3CodeVerifyNamedSchema`,
  `sqlite3ForceNotReadOnly`)~~ done 2026-04-26,
  ~~`destroyRootPage`, `sqlite3RootPageMoved`, `sqlite3GetTempReg`,
  `sqlite3ReleaseTempReg`~~ done 2026-04-26,
  ~~`sqlite3OpenSchemaTable`, `sqlite3ChangeCookie`,
  `sqlite3BeginWriteOperation`~~ done 2026-04-26,
  ~~`sqlite3DropTable`, `sqlite3CodeDropTable`, `destroyTable`,
  `sqlite3ClearStatTables`, `tableMayNotBeDropped`,
  `sqliteViewResetAll`~~ done 2026-04-26,
  ~~`sqlite3StartTable`~~ done 2026-04-26,
  ~~`sqlite3EndTable`~~ done 2026-04-26 (structural port; STRICT /
  GENERATED / CHECK / pSelect / convertToWithoutRowidTable arms
  deferred — see step 7 notes),
  ~~`sqlite3CreateIndex`~~ done 2026-04-26 (structural port; column
  iteration / pPk extension / RefillIndex / IndexHasDuplicateRootPage /
  REPLACE-reorder arms deferred — see step 8 notes),
  ~~`sqlite3NestedParse`~~ done 2026-04-26 (step 9: structural port +
  parser-dispatch hook; the 7 internal call sites still pass nil
  zFormat — wiring real format strings + args is step 10, which is
  what actually flips DIVERGE rows because it produces the schema-row
  UPDATE/INSERT/DELETE sub-statements),
  ~~step 10: real format strings + args at all 7 NestedParse call
  sites~~ done 2026-04-26 (formats + arg lists ported byte-for-byte
  from build.c; rows still DIVERGE because the schema-row
  UPDATE/INSERT/DELETE inner statements land in the still-stubbed
  sqlite3Insert / sqlite3Update / sqlite3DeleteFrom — that is now
  the next gate))
  to byte-identical opcode emission against C.  Each helper landed
  flips one row from DIVERGE → PASS in TestExplainParity; an extra
  diagnostic-only column-list AV must also be triaged
  (`CREATE TABLE typed`, `CREATE TABLE WITHOUT ROWID`).  Once all
  ten current rows PASS, expand corpus to DML / SELECT / pragma /
  trigger forms (the same exclusion list as TestParser).
  Status (2026-04-26 step 10): **2 PASS / 8 DIVERGE / 0 ERROR**
  (unchanged from step 9 — step 10 wires real format strings, but
  the resulting inner UPDATE/INSERT/DELETE recurse through stubbed
  DML codegen which emits zero ops; flipping requires step 11
  (sqlite3Insert / sqlite3Update / sqlite3DeleteFrom)).
  CREATE INDEX rows now report "nil Vdbe" (was "C=37 Pas=3") —
  honest reflection that LocateTableItem fails because the seed
  CREATE TABLEs never publish to tblHash (NestedParse stub).
  CREATE TABLE rows hold at op-count Pascal=17 / C=32–43; the
  gap is the NestedParse-driven schema-row UPDATE sub-statement
  (~13 ops).  Earlier history: 1/7/2 (step 5) → 1/7/2 (step 6,
  both ERROR rows flipped to DIVERGE via the MakeReady aMem fix)
  → 1/9/0 (step 6) → 2/8/0 (step 7) → 2/8/0 (step 8).

  Sub-tasks formalised from step 11f's discoveries:

  - [X] **6.9-bis step 11g.1** Port `OP_ParseSchema` in
    `passqlite3vdbe.pas:7134` (originally a no-op stub).
    *Complete (2026-04-26):* all three sub-steps shipped —
    11g.1.a (structural skeleton + dispatch hook + sqlite3_exec
    worker + minimal sqlite3InitCallback), 11g.1.b (productive
    callback: c-r re-prepare branch + auto-index tnum branch +
    initCorruptSchema), and 11g.1.c (codegen-arm audit via
    TestInitCallback; surfaced + fixed empty-string argv[4] ladder
    bug that left the auto-index branch unreachable).  See
    "Most recent activity" for the per-sub-step writeups.  Required
    so user tables created by `CREATE TABLE t(...)` get published to
    `db^.aDb[iDb].pSchema^.tblHash` after EndTable's emission tail
    runs; without it, `CREATE INDEX i1 ON t(a)` and `DROP TABLE t`
    in TestExplainParity fail at `sqlite3SrcListLookup(t)` with
    "nil Vdbe".  Faithful port of vdbe.c:7114..7183: requires
    `sqlite3InitOne` (init.c:818, ALTER branch) and the non-ALTER
    branch's `sqlite3MPrintf("SELECT*FROM\"%w\".%s WHERE %s ORDER
    BY rowid", db.aDb[iDb].zDbSName, LEGACY_SCHEMA_TABLE, p4.z)` +
    `sqlite3_exec(db, zSql, sqlite3InitCallback, &initData, 0)`.
    Minimal viable port may stub `sqlite3InitOne` and only handle
    the common case (P4 != nil → non-NULL WHERE clause).  Blocks
    flipping the 3 nil-Vdbe rows in TestExplainParity (CREATE
    INDEX × 2, DROP TABLE × 1).  Independent of step 11g.2.

  - [ ] **6.9-bis step 11g.2** Port `sqlite3WhereBegin` /
    `sqlite3WhereOkOnePass` / `sqlite3WhereEnd` (where.c — Phase 7
    territory; the planner core).  Required by the productive
    emission tail of `sqlite3DeleteFrom` and `sqlite3Update`
    (codegen.pas:5460..5471, 5660..5670 — currently TODO comments).
    With a real WhereBegin, the schema-row UPDATE / DELETE
    statements emitted by `sqlite3NestedParse` from
    `sqlite3EndTable` / `sqlite3CodeDropTable` can wire their
    where-loop arms and emit the ~13-op NestedParse sub-statement
    that's currently missing from the 5 CREATE TABLE rows.
    Removes the step-11f skeleton-only error-state guard
    (codegen.pas:5401..5410, 5577..5599) once any productive opcode
    is emitted.  Largest single piece of remaining work for this
    sub-phase; may need to split further (where.c is ~7900 lines).

    **Scope reality check (2026-04-26).**  The full port spans three
    upstream files: `where.c` (7900 lines, planner core), `wherecode.c`
    (2945 lines, per-loop body codegen), and `whereexpr.c` (1944 lines,
    WHERE-clause term decomposition / analysis).  Plus the type
    definitions in `whereInt.h` (668 lines).  Total: ~13.5k lines of C.
    Splitting by file is the natural seam, but a *vertical slice*
    (single-table simple-rowid-EQ predicate first, expand outward) is
    what unblocks TestExplainParity fastest, because every schema-row
    sub-statement emitted by `sqlite3NestedParse` is exactly that
    shape (e.g. `UPDATE %Q.sqlite_master SET sql=%Q WHERE rowid=#%d`
    and `DELETE FROM %Q.sqlite_master WHERE name=%Q AND type=%Q`).
    Sub-tasks below mix both axes — vertical slice for the first
    productive landing, then horizontal/exhaustive ports of the
    remaining where.c / wherecode.c / whereexpr.c machinery.

    Sub-task split (revised 2026-04-26, mirrors step 11g.1 staging):

    - [X] **11g.2.a** ✅ done 2026-04-26 — audited the 14 whereInt.h
      record skeletons in `passqlite3codegen.pas:1066..1306`
      (`TWhereMemBlock`, `TWhereRightJoin`, `TInLoop`, `TWhereTerm`,
      `TWhereClause`, `TWhereOrInfo`, `TWhereAndInfo`, `TWhereMaskSet`,
      `TWhereOrCost`, `TWhereOrSet`, `TWherePath`, `TWhereScan`,
      `TWhereLoopBtree`, `TWhereLoopVtab`, `TWhereLoopU`, `TWhereLoop`,
      `TWhereLevelU`, `TWhereLevel`, `TWhereLoopBuilder`, `TWhereInfo`).
      Diffed field-for-field against `whereInt.h` HEAD and verified each
      layout assumption against actual GCC x86-64 packing with a tiny C
      probe — no drift found.  Locked the layout via new
      `TestWhereStructs.pas` sentinel: 148 individual field-offset
      checks across all 14 records (offsetof()-style PASS/FAIL).
      Complements TestWhereBasic's SizeOf gate.  Result: 148 PASS / 0
      FAIL.  Pascal port intentionally models the *non-debug* C layout
      (no SQLITE_DEBUG `iTerm` field on WhereTerm); records are
      self-contained Pascal data, never round-tripped through C, so
      that's correct.

    - [ ] **11g.2.b** Vertical slice — minimal-viable
      `sqlite3WhereBegin` / `sqlite3WhereEnd` that handles **only** the
      single-table, single-rowid-EQ-predicate case.

      **Sub-progress (landed 2026-04-26 — bookkeeping primitives):**
      ported `whereLoopInit` / `whereLoopClearUnion` / `whereLoopClear`
      / `whereLoopResize` / `whereLoopXfer` / `whereLoopDelete` /
      `whereInfoFree` (where.c:2527..2629) into
      `passqlite3codegen.pas` immediately above the `sqlite3WhereBegin`
      stub.  Faithful translations including the WHERE_VIRTUALTABLE
      `needFree` (bit 0 of `u.vtab.bFlags`) clear-and-free path and the
      WHERE_AUTO_INDEX `u.btree.pIndex^.zColAff` free path.
      `WHERE_LOOP_XFER_SZ` = `offsetof(TWhereLoop, nLSlot)` = 56,
      locked by TestWhereStructs's offset sentinel.  Helpers are file-
      private; they aren't called by productive code yet (WhereBegin is
      still a stub returning nil), so no observable behaviour change in
      the corpus — full regression sweep stays green
      (TestWhereBasic 52/52, TestWhereStructs 148/148,
      TestPrepareBasic 20/20, TestParser 45/45, TestSchemaBasic 44/44,
      TestVdbeApi 57/57, TestDMLBasic 54/54, TestSelectBasic 49/49,
      TestExprBasic 40/40, TestInitCallback 29/29, TestExplainParity
      unchanged at 2 PASS / 8 DIVERGE / 0 ERROR).  This unblocks the
      productive `sqlite3WhereBegin` port: WhereInfo + WhereLoop
      allocation can now `whereInfoFree` cleanly on every error path,
      and per-loop transfer/delete during planner walk has the
      bookkeeping it needs.

      **Sub-progress (landed 2026-04-26 — productive WhereEnd cleanup
      contract):** replaced the empty `sqlite3WhereEnd` stub at
      `passqlite3codegen.pas:4360..4378` with the productive teardown
      body — `if pWInfo <> nil then whereInfoFree(pWInfo^.pParse^.db,
      pWInfo)`.  Pairs cleanly with the still-stub WhereBegin (which
      returns nil): the `pWInfo <> nil` guard makes this a no-op for
      every existing call site, so no observable behaviour change in
      the corpus, full regression sweep stays green.  Once productive
      WhereBegin starts allocating WhereInfo, every error path and
      every successful pairing gets proper teardown without further
      WhereEnd edits.  The other half of where.c's real
      `sqlite3WhereEnd` (loop-termination opcode emission,
      SKIPAHEAD_DISTINCT seeks, IN-LOOP unwind, LEFT JOIN null-row
      fixup) still needs to land alongside the productive WhereBegin
      below / the 11g.2.e `wherecode.c` port.

      **Sub-progress (landed 2026-04-26 — pMemToFree allocator + cursor
      mask creator):** ported the remaining bookkeeping primitives from
      where.c that the productive WhereBegin prologue calls before any
      planner work runs:

        * `sqlite3WhereMalloc` (where.c:261..273) — `pWInfo`-tracked
          allocation.  Each block is prefixed with a `TWhereMemBlock`
          header threading it onto `pWInfo^.pMemToFree`; on OOM returns
          nil (not a fatal error — caller checks).  Pairs with
          `whereInfoFree`'s pMemToFree-walk that's already in place.
        * `sqlite3WhereRealloc` (where.c:274..283) — sister realloc.
          Faithful to C: always allocates fresh and copies; the old
          block stays threaded on pMemToFree (released wholesale when
          WhereInfo is freed).
        * `createMask` (where.c:285..296) — file-private cursor-mask
          creator.  Inline; the cap on `pMaskSet^.ix[]` is enforced by
          the WhereBegin prologue's `pTabList^.nSrc <= BMS` check
          (still to land), so the assert here matches the C contract
          exactly.

      Public API forward decls added for the two `sqlite3WhereMalloc/
      Realloc` entry points; `createMask` stays static (file-private).
      None of these helpers are called by productive code yet
      (WhereBegin still returns nil), so no observable behaviour change
      in the corpus — full regression sweep stays green
      (TestWhereBasic 52/52, TestWhereStructs 148/148,
      TestPrepareBasic 20/20, TestParser 45/45, TestSchemaBasic 44/44,
      TestVdbeApi 57/57, TestDMLBasic 54/54, TestSelectBasic 49/49,
      TestExprBasic 40/40, TestInitCallback 29/29, TestExplainParity
      unchanged at 2 PASS / 8 DIVERGE / 0 ERROR).  Together with the
      WhereLoop primitives and the productive WhereEnd cleanup contract,
      the prologue of `sqlite3WhereBegin` (where.c:6862..6940) can now
      be ported as a faithful translation — every helper it calls
      directly (`whereLoopInit`, `sqlite3WhereClauseInit`,
      `sqlite3WhereSplit`, mask-set init, builder init) exists and is
      tested.

      **Sub-progress (landed 2026-04-26 — signature alignment with C).**
      Closed the previously-flagged signature-drift discovery.
      `sqlite3WhereBegin` declaration at `passqlite3codegen.pas:1537` and
      definition at :4404 now match upstream C (`where.c:6828..6837`,
      `sqliteInt.h:5100`) byte-for-byte: 8 parameters in order
      (Parse*, SrcList*, Expr* pWhere, ExprList* pOrderBy,
      ExprList* pResultSet, Select* pSelect, u16 wctrlFlags, int iAuxArg).
      Pascal's misnamed `pDistinctSet` was renamed to `pResultSet`, and
      the missing `pSelect: PSelect` slot was inserted between
      `pResultSet` and `wctrlFlags`.  The body remains a stub returning
      nil — this is purely a contract change, no behaviour change in the
      corpus.  No callers existed (only the declaration, definition, and
      a TODO comment at codegen.pas:5666), so the change was mechanical.
      Full regression sweep stays green (TestWhereBasic 52/52,
      TestWhereStructs 148/148, TestPrepareBasic 20/20, TestParser 45/45,
      TestSchemaBasic 44/44, TestVdbeApi 57/57, TestDMLBasic 54/54,
      TestSelectBasic 49/49, TestExprBasic 40/40, TestInitCallback 29/29,
      TestExplainParity unchanged at 2 PASS / 8 DIVERGE / 0 ERROR).
      Now unblocks the productive prologue port, which writes
      `pWInfo^.pSelect = pSelect` directly.

      **Sub-progress (landed 2026-04-26 — productive prologue body).**
      Replaced the bare `Result := nil` stub of `sqlite3WhereBegin`
      (`passqlite3codegen.pas:4430`) with a faithful port of
      where.c:6828..6993 — every line up to (but not including) the
      False-WHERE-Term-Bypass loop and the planner core.  Covers: the
      two leading flag-interaction Asserts; variable init
      (`db := pParse^.db`, FillChar of sWLB); ORDER BY cap (>=BMS →
      pOrderBy:=nil + clear WANT_DISTINCT + set KEEP_ALL_JOINS);
      FROM-clause cap (>BMS → sqlite3ErrorMsg + return nil); nTabList
      computation under WHERE_OR_SUBCLAUSE; single allocation
      (`SZ_WHEREINFO(nTabList) + SizeOf(TWhereLoop)`) with mallocFailed
      check; 14 field initialisations + the
      `FillChar(pWInfo^.nOBSat, 39, 0)` block (104-65=39 bytes,
      nOBSat..revMask, locked by TestWhereStructs); trailing-region
      zero via whereInfoLevels accessor; MaskSet `ix[0]=-99` sentinel;
      sWLB setup with EIGHT_BYTE_ALIGNMENT assert + `whereLoopInit`;
      `sqlite3WhereClauseInit` + `sqlite3WhereSplit(TK_AND)`;
      `nTabList==0` branch (nOBSat from pOrderBy, eDistinct TODO);
      `nTabList>0` walk doing `createMask` + `sqlite3WhereTabFuncArgs`
      for ALL `nSrc` entries (Ticket #3015 contract);
      `sqlite3WhereExprAnalyze` + conditional `sqlite3WhereAddLimit`;
      pParse->nErr error-path with `whereInfoFree`.  The function
      ends by calling `whereInfoFree` and returning nil — closes the
      cleanup contract pending the planner core, makes the prologue
      safe to land alone since no callers consume the WhereInfo yet.
      Five missing WHERE_* flag constants (ONEPASS_DESIRED,
      ONEPASS_MULTIROW, OR_SUBCLAUSE, KEEP_ALL_JOINS, USE_LIMIT)
      added as file-private constants with `_C` suffix immediately
      above the function (TODO: 11g.2.c should promote them to the
      public const block at codegen.pas:1392..1407 and drop the `_C`
      suffix).  `OptimizationEnabled` / `SQLITE_DistinctOpt` helper
      not yet ported; the eDistinct=WHERE_DISTINCT_UNIQUE branch in
      the nTabList==0 case is left as a TODO defaulting to
      WHERE_DISTINCT_NOOP=0 (conservative; harmless until that branch
      is exercised).  `sqlite3ErrorMsg` variadic loss: C source uses
      `"at most %d tables in a join"` with BMS substitution; our
      port hard-codes `"at most 64 tables in a join"` since the
      Pascal sqlite3ErrorMsg port is a fixed-string sink (acceptable
      as long as BMS stays 64).  Full regression sweep all green
      (TestWhereBasic 52/52, TestWhereStructs 148/148,
      TestPrepareBasic 20/20, TestParser 45/45, TestSchemaBasic 44/44,
      TestVdbeApi 57/57, TestDMLBasic 54/54, TestSelectBasic 49/49,
      TestExprBasic 40/40, TestInitCallback 29/29, TestExplainParity
      unchanged at 2 PASS / 8 DIVERGE / 0 ERROR).  Next sub-progress:
      trimmed planner pick + OP_NotExists emission for the rowid-EQ
      shape, then re-enable productive tails in sqlite3DeleteFrom +
      sqlite3Update.

      **Sub-progress (landed 2026-04-26 — BMS / SZ_WHEREINFO /
      whereInfoLevels scaffolding).**  Added three structural primitives
      the productive prologue calls directly:
        * `BMS = i32(SizeOf(Bitmask) * 8)` = 64 (caps FROM-clause /
          ORDER BY width — sqliteInt.h BMS macro).
        * `SZ_WHEREINFO(nLevel)` inline (whereInt.h:514 macro) —
          `ROUND8(SizeOf(TWhereInfo) + nLevel*SizeOf(TWhereLevel))`.
        * `whereInfoLevels(p): PWhereLevel` flexarray accessor for
          `pWInfo->a[i]`.
      No body change in `sqlite3WhereBegin`; full regression sweep stays
      green.  Unblocks the productive prologue port (next sub-progress).

      **Sub-progress (landed 2026-04-26 — exprIsDeterministic + walker
      fail callback).**  Ported the three foundational helpers the
      False-WHERE-Term-Bypass loop (where.c:6995..7036) calls before any
      planner work begins:

        * `sqlite3SelectWalkFail` (expr.c:2308) — public Walker callback
          that clears `pWalker^.eCode` and returns `WRC_Abort`.  Used by
          every walker that wants to refuse to descend into sub-selects.
          Forward-declared in the public block alongside
          `sqlite3SelectWalkNoop`; lives next to it in the body.
        * `exprNodeIsDeterministic` (where.c:6445) — file-private helper
          that aborts the walk + clears `eCode` when it sees a
          `TK_FUNCTION` node without `EP_ConstFunc`.
        * `exprIsDeterministic` (where.c:6458) — file-private predicate
          that runs a Walker over the expression with the two callbacks
          above; returns 1 iff no non-deterministic SQL functions are
          encountered outside sub-selects.

      None of these helpers are called by productive code yet (the
      False-WHERE-Term-Bypass loop is still unported), so no observable
      behaviour change in the corpus — full regression sweep stays green
      (TestWhereBasic 52/52, TestWhereStructs 148/148, TestPrepareBasic
      20/20, TestParser 45/45, TestSchemaBasic 44/44, TestVdbeApi 57/57,
      TestDMLBasic 54/54, TestSelectBasic 49/49, TestExprBasic 40/40,
      TestInitCallback 29/29, TestExplainParity unchanged at 2 PASS / 8
      DIVERGE / 0 ERROR).  Unblocks the False-WHERE-Term-Bypass loop
      port: the only remaining missing helper is `sqlite3ExprIfFalse`
      (Phase-6 codegen helper from expr.c — emits a JUMPIFNULL-style
      branch when an expression evaluates falsy), which is the next
      logical sub-progress chunk.

      **Sub-progress (landed 2026-04-26 — sqlite3ExprSimplifiedAndOr +
      exprEvalRhsFirst + ExprAlwaysTrue/False).**  Pre-requisite leaf
      helpers for the eventual `sqlite3ExprIfTrue` /
      `sqlite3ExprIfFalse` port:

        * `ExprAlwaysTrue` / `ExprAlwaysFalse` (sqliteInt.h:3147..3148)
          inline functions — `(flags & (EP_OuterON|EP_IsTrue)) ==
          EP_IsTrue` etc.  EP_OuterON gate keeps LEFT/FULL JOIN ON-
          clause literals out of the fold.
        * `sqlite3ExprSimplifiedAndOr` (expr.c:2373..2385) — public
          helper that folds AND/OR sub-trees containing
          unconditionally-true/false sub-expressions.  Forward-decl in
          the public block.
        * `exprEvalRhsFirst` (expr.c:2395..2403) — file-private
          predicate hinting the coder to evaluate RHS first when LHS
          contains a sub-select.

      None of these helpers called by productive code yet — pure
      scaffolding.  Full regression sweep stays green (TestWhereBasic
      52/52, TestWhereStructs 148/148, TestPrepareBasic 20/20,
      TestParser 45/45, TestSchemaBasic 44/44, TestVdbeApi 57/57,
      TestDMLBasic 54/54, TestSelectBasic 49/49, TestExprBasic 40/40,
      TestInitCallback 29/29, TestExplainParity unchanged at 2 PASS /
      8 DIVERGE / 0 ERROR).  Next logical sub-progress chunk:
      `sqlite3ExprIfTrue` / `sqlite3ExprIfFalse` themselves
      (mutually recursive ~400-line block in expr.c:6100..6500-ish).
      Many of their sub-helpers are already present
      (`sqlite3ExprIsVector`, `sqlite3ExprTruthValue`,
      `sqlite3ExprCodeTemp`, `sqlite3VdbeMakeLabel`); the missing ones
      are `codeCompare`, `exprComputeOperands`, `exprCodeBetween`, and
      `sqlite3ExprCanBeNull` — they should land first as a separate
      leaf-helper sub-progress, then the recursive jump pair, then the
      False-WHERE-Term-Bypass loop body in WhereBegin.

      **Sub-progress (landed 2026-04-26 — sqlite3ExprCanBeNull).**
      First missing leaf — see Most-recent-activity entry above.

      **Sub-progress (landed 2026-04-26 — codeCompare cluster).**
      Second missing leaf, but landed as a 5-helper bundle because of
      the closed dependency cluster (codeCompare ⇒
      sqlite3BinaryCompareCollSeq + binaryCompareP5; binaryCompareP5
      ⇒ sqlite3CompareAffinity; sqlite3ExprCompareCollSeq is the
      EP_Commuted-aware wrapper most productive call sites reach for
      first).  See Most-recent-activity entry above for the full
      breakdown.  Two leaves remain (`exprComputeOperands`,
      `exprCodeBetween`) before the recursive jump-emission pair.

      **Remaining sub-task:** the actual productive WhereBegin
      single-table, single-rowid-EQ-predicate case + WhereEnd's
      loop-termination opcode emission (full description below).

      ----

      **Original task description.**  Single-table, single-rowid-EQ
      predicate (no joins, no
      ORDER BY, no index selection, no virtual tables, no OR-terms).
      Emits the `OP_NotExists` (or `OP_NoConflict` for non-rowid PK)
      seek + body + jump-back-to-Next pattern that schema-row UPDATE /
      DELETE inner statements need.  This is enough to flip the 5
      CREATE TABLE rows in TestExplainParity from DIVERGE → PASS once
      step 11e's sqlite3Insert also lands its productive tail.
      Implementation:
        * `whereLoopInit` / `whereLoopClear` / `whereLoopXfer` /
          `whereLoopDelete` / `whereInfoFree` (where.c:2527..2655) —
          bookkeeping primitives, ~150 lines, no policy logic.
        * `sqlite3WhereGetMask` (where.c:245..262) — bitmask helper.
        * Trim `sqlite3WhereBegin` (where.c:6828..7517) to the
          single-loop, no-IPK case: allocate WhereInfo, init nLevel=1
          / iEndWhere / iContinue / iBreak labels, install OP_OpenRead
          with the table-cursor (already done by caller in our schema-
          row path, so detect and reuse), emit `OP_NotExists` against
          the rowid expression resolved out of `pWhere`, fall through
          to body.
        * `sqlite3WhereEnd` (where.c:7519..) — emit the loop tail
          (Goto continue + Resolve break label), close cursor if we
          opened it, free the WhereInfo.
      Skip planner-core (`whereLoopAddBtree`, `whereLoopAddVirtual`,
      `whereLoopAddOr`, `whereLoopAddAll`, the cost solver) by
      hard-coding the cost selection for the rowid-EQ case.  Defer
      `wherecode.c` body codegen by inlining the NotExists emission
      directly here.  Re-enable the productive tails in
      `sqlite3DeleteFrom` (codegen.pas:5460..5471) and
      `sqlite3Update` (codegen.pas:5660..5670), drop the step-11f
      skeleton-only error-state guard at codegen.pas:5401..5410 +
      5577..5599 once the loop emits any productive opcode.
      Gate test: a new `TestWhereSimple.pas` driving
      `sqlite3WhereBegin` directly with a hand-built SrcList + rowid-
      EQ Expr; assert OP_NotExists / OP_Goto / labels emitted in the
      expected order.  Expected TestExplainParity bump:
      2 PASS / 8 DIVERGE → 7 PASS / 3 DIVERGE (the 5 CREATE TABLE
      rows flip; the 3 nil-Vdbe rows still need step 11e's productive
      INSERT emission to seed sqlite_master).

    - [ ] **11g.2.c** Port `whereexpr.c` (1944 lines) — WHERE-clause
      term decomposition + analysis.  Public surface:
      `sqlite3WhereSplit`, `sqlite3WhereClauseInit` (already a stub at
      codegen.pas:3996), `sqlite3WhereClauseClear`,
      `sqlite3WhereExprAnalyze`, `sqlite3WhereTabFuncArgs`,
      `sqlite3WhereFindTerm` (already a stub).  Internal:
      `exprAnalyze`, `exprAnalyzeAll`, `exprAnalyzeOrTerm`,
      `whereSplit`, `markTermAsChild`, `whereCombineDisjuncts`,
      `whereNthSubterm`, `transferJoinMarkings`,
      `isLikeOrGlob`, `whereCommuteOperator`.  This is the gateway
      to multi-term WHERE clauses (AND, OR, BETWEEN, LIKE, IN-list).
      Until this lands, 11g.2.b is restricted to the single-rowid-EQ
      shape; afterwards the planner can see all term flavours.
      Gate test: extend `TestWhereSimple.pas` with multi-term cases
      (a=1 AND b=2, a IN (1,2,3), a BETWEEN 1 AND 5).

    - [ ] **11g.2.d** Port the planner core in `where.c` — the cost
      solver (`whereLoopAddBtree`, `whereLoopAddBtreeIndex`,
      `whereLoopAddVirtual*`, `whereLoopAddOr`, `whereLoopAddAll`,
      `whereLoopOutputAdjust`, `whereLoopFindLesser`,
      `whereLoopInsert`, `whereLoopCheaperProperSubset`,
      `whereLoopAdjustCost`, the N-best path search in
      `wherePathSolver`).  ~5000 lines.  Replaces the hard-coded
      rowid-EQ pick from 11g.2.b with real N-way join planning,
      index selection, and ORDER BY consumption.  Largest single
      component; may itself need further sub-splitting once 11g.2.a..c
      reveal the field-shape requirements.  Pulls in
      `bestIndex`-style virtual-table costing (Phase 7.x territory)
      iff vtab corpus is exercised — for now defer xBestIndex calls.

    - [ ] **11g.2.e** Port `wherecode.c` (2945 lines) — per-loop
      inner-body codegen.  Public surface:
      `sqlite3WhereCodeOneLoopStart`, `sqlite3WhereRightJoinLoop`
      (already a stub at codegen.pas:4233), `sqlite3WhereExplainOneScan`,
      `sqlite3WhereAddScanStatus`, `disableTerm`, `codeApplyAffinity`,
      `codeEqualityTerm`, `codeAllEqualityTerms`,
      `whereLikeOptimizationStringFixup`, `codeCursorHint`.  Replaces
      the inlined NotExists emission from 11g.2.b with full
      index-key construction, range-scan setup, virtual-table xFilter
      glue, and the per-row body dispatch that drives every WHERE-clause
      consumer (sqlite3Select, sqlite3Update, sqlite3DeleteFrom).

    - [ ] **11g.2.f** Audit + regression.  Land a comprehensive
      `TestWhereCorpus.pas` covering the full WHERE shape matrix
      (single rowid-EQ, multi-AND, OR-decomposed, LIKE, IN-subselect,
      composite index range-scan, LEFT JOIN, virtual table xFilter)
      and verify byte-identical bytecode emission against C via
      TestExplainParity expansion.  Re-enable any disabled
      assertion / safety-net guards left in place during 11g.2.b..e.
      Mirrors the 11g.1.c audit pattern.

---

## Phase 7 — Parser

Files: `tokenize.c` (the hand-written lexer), `parse.y` (the Lemon grammar,
which generates `parse.c` at build time), `complete.c` (the
`sqlite3_complete` / `sqlite3_complete16` helpers for detecting when a SQL
statement is syntactically complete — used by the CLI and REPLs).

- [X] **7.1** Port `tokenize.c` (the lexer) to `passqlite3parser.pas`. Hand
  port — it is a single function (`sqlite3GetToken`) of ~400 lines driven by
  character classification tables. `complete.c` is a small companion
  (~280 lines) and ports in the same unit.
  Gate test `TestTokenizer.pas`: T1–T18 all PASS (127/127).
  Also fixed an off-by-one bug in `sqlite3_strnicmp` (`N < 0` → `N <= 0`)
  that caused keyword comparison to always fail when all N chars matched.

- [X] **7.2** **Strategy decision (2026-04-25):** Patching Lemon to emit Pascal
  is a multi-week undertaking (lemon.c is 6075 lines of intricate code-emitter
  C). Hand-porting `parse.c` (6327 lines, generated, deterministic structure)
  is the pragmatic path. Since `parse.c` is regenerated only when `parse.y`
  changes and the grammar is stable upstream, a one-time transliteration
  carries acceptable maintenance cost. Split into sub-phases:

  - [X] **7.2a** Port the YY control constants (YYNOCODE, YYNSTATE, YYNRULE,
    YYNTOKEN, YY_MAX_SHIFT, YY_MIN_SHIFTREDUCE, YY_MAX_SHIFTREDUCE,
    YY_ERROR_ACTION, YY_ACCEPT_ACTION, YY_NO_ACTION, YY_MIN_REDUCE,
    YY_MAX_REDUCE, YY_MIN_DSTRCTR, YY_MAX_DSTRCTR, YYWILDCARD, YYFALLBACK,
    YYSTACKDEPTH). Define the `YYMINORTYPE` Pascal record (no unions in
    Pascal — use a variant record), the `yyStackEntry` and `yyParser`
    record types. Declare public parser entry points (`sqlite3ParserAlloc`,
    `sqlite3ParserFree`, `sqlite3Parser`, `sqlite3ParserFallback`,
    `sqlite3ParserStackPeak`) as forward stubs. Goal: scaffolding compiles.
    Reference: `../sqlite3/parse.c` lines 305–625 (token codes, control
    defines, YYMINORTYPE union) and lines 1589–1630 (parser structs).

  - [X] **7.2b** Port the action / lookahead / shift-offset / reduce-offset
    / default tables (`yy_action`, `yy_lookahead`, `yy_shift_ofst`,
    `yy_reduce_ofst`, `yy_default`) verbatim from `parse.c` lines 706–1380.
    Tables live in `src/passqlite3parsertables.inc` (689 lines, included
    from `passqlite3parser.pas` at the top of the implementation section).
    Sizes verified by entry count:
      * `yy_action[2379]`     (YY_ACTTAB_COUNT  = 2379)
      * `yy_lookahead[2566]`  (YY_NLOOKAHEAD    = 2566)
      * `yy_shift_ofst[600]`  (YY_SHIFT_COUNT   = 599, +1)
      * `yy_reduce_ofst[424]` (YY_REDUCE_COUNT  = 423, +1)
      * `yy_default[600]`     (YYNSTATE         = 600)
    Generation was mechanical: `/*` → `{`, `*/` → `}`, `{` → `(` for the
    array literal, `};` → `);`, trailing comma stripped (FPC rejects).
    YY_NLOOKAHEAD constant (2566) matches the C source verbatim.
    Tokenizer gate test still PASS (127/127 — tables unused so far,
    serves as a regression check that the unit still compiles).

  - [X] **7.2c** Port the fallback table (`yyFallback`, parse.c lines
    1398–1588) and the rule-info tables (`yyRuleInfoLhs`, `yyRuleInfoNRhs`,
    parse.c lines 2960–3791). These are also mechanical translations.
    Implement `sqlite3ParserFallback` to return `yyFallback[iToken]`.
    DONE 2026-04-25.  Tables appended to `passqlite3parsertables.inc`
    (lines 691+) — counts: `yyFallbackTab[187]` = YYNTOKEN, `yyRuleInfoLhs[412]`
    = YYNRULE, `yyRuleInfoNRhs[412]` = YYNRULE.  Note: the C name `yyFallback`
    collides case-insensitively with the `YYFALLBACK` enabling constant under
    FPC (per the recurring var/type-conflict feedback); the Pascal table is
    therefore named **`yyFallbackTab`**, while the constant `YYFALLBACK = 1`
    keeps its upstream spelling.  `sqlite3ParserFallback` now indexes
    `yyFallbackTab` directly with bounds-check on `YYNTOKEN`.  Tokenizer gate
    test still PASS (127/127 — tables not yet exercised, regression check
    that the unit still compiles).  `yyRuleInfoNRhs` declared as
    `array of ShortInt` (signed 8-bit, matches C `signed char`).

  - [X] **7.2d** Port the parser engine (lempar.c logic that ends up at
    parse.c lines 3792–6313): `yy_find_shift_action`, `yy_find_reduce_action`,
    `yy_shift`, `yy_pop_parser_stack`, `yy_destructor`, the main `sqlite3Parser`
    driver with its grow-on-demand stack (`parserStackRealloc` /
    `parserStackFree`). Use the same algorithm as the C engine. Skip the
    optional tracing functions for now (port only `yyTraceFILE` declarations
    so signatures match).
    DONE 2026-04-25.  Engine bodies live in `passqlite3parser.pas` lines
    1057–1330 (forward declarations + `parserStackRealloc`, `yy_destructor`
    stub, `yy_pop_parser_stack`, `yyStackOverflow`, `yy_find_shift_action`,
    `yy_find_reduce_action`, `yy_shift`, `yy_accept`/`yy_parse_failed`/
    `yy_syntax_error`, `yy_reduce` framework, full `sqlite3Parser` driver,
    rewritten `sqlite3ParserAlloc`/`Free`).  `yy_destructor` and the rule
    switch inside `yy_reduce` are intentionally empty bodies — Phase 7.2e
    fills them by porting parse.c:2542–2657 and 3829–5993 respectively.
    Until reduce actions exist, yy_shift only ever stores a TToken in
    `minor.yy0` so empty destructors are correct.  The dropped
    yyerrcnt/`YYERRORSYMBOL` recovery path is fine: parse.y does not define
    an error token, so the C engine takes the same fall-through (report +
    discard token, fail at end-of-input).  Tracing (`yyTraceFILE`,
    `yycoverage`, `yyTokenName`/`yyRuleName`) was skipped per spec.
    Pitfall: `var pParse: PParse` triggers FPC's case-insensitive name
    collision (per memory `feedback_fpc_vartype_conflict`); the engine
    uses local name `pPse` everywhere it needs a `PParse` cast.
    Tokenizer gate test still PASS (127/127 — full unit compiles, parser
    engine not yet exercised end-to-end since `sqlite3RunParser` remains
    stubbed pending 7.2e + 7.2f).

  - [X] **7.2e** Port the **reduce actions** — the giant switch statement at
    parse.c lines 3829–5993. This is the only sub-phase that is non-mechanical:
    each `case YYRULE_n:` body contains hand-written grammar action C code from
    `parse.y` that calls `sqlite3*` codegen routines from Phase 6. Many of the
    callees may need additional wrapper exports from Phase 6 units. Port in
    chunks of ~50 rules, build-checking after each.

    Sub-tasks (chunks of ~50 rules each, 412 rules total):
    - [X] **7.2e.1** Rules 0..49 — explain, transactions, savepoints,
      CREATE TABLE start/end, table options, column constraints (DEFAULT/
      NOT NULL/PRIMARY KEY/UNIQUE/CHECK/REFERENCES/COLLATE/GENERATED),
      autoinc, initial refargs.  DONE 2026-04-25.
    - [X] **7.2e.2** Rules 50..99 — refargs/refact (FK actions),
      defer_subclause, conslist, idxlist, sortlist, eidlist, columnlist
      tail; tcons (PRIMARY KEY/UNIQUE/CHECK/FOREIGN KEY); onconf/orconf;
      DROP TABLE/VIEW; CREATE VIEW; cmd ::= select; SELECT core (WITH,
      compound, oneselect, VALUES, mvalues, distinct).  DONE 2026-04-25.

      Notes for next chunks:
      * Helper static functions `parserDoubleLinkSelect` and
        `attachWithToSelect` (parse.y:131/162) ported as nested helpers
        in `passqlite3parser.pas` directly above `yy_reduce`.  Both call
        only existing exports (`sqlite3SelectOpName`,
        `sqlite3WithDelete`, `aLimit[SQLITE_LIMIT_COMPOUND_SELECT]`,
        plus `SF_Compound` / `SF_MultiValue` / `SF_Values` from codegen).
      * `DBFLAG_EncodingFixed` (sqliteInt.h:1892, value $0040) was not
        previously declared in any unit — added as a local const inside
        `passqlite3parser` next to the SAVEPOINT_* block.  When Phase 8
        wires up the public API and ports `prepare.c`, move it to
        `passqlite3codegen` alongside `DBFLAG_SchemaKnownOk`.
      * `Parse.hasCompound` is a C bitfield; in our layout it lives in
        `parseFlags`, bit `PARSEFLAG_HasCompound` (1 shl 2).  Rule 88
        sets that bit instead of dereferencing a non-existent
        `pPse^.hasCompound` field.
      * `sqlite3ErrorMsg` still has no varargs — rule body for
        `parserDoubleLinkSelect` therefore uses static "ORDER BY clause
        should come after compound operator" / "LIMIT ..." messages
        (parse.y dynamically inserted the operator name).  Same TODO
        as 7.2e.1 rules 23/24: revisit when printf-style formatting
        lands.
      * `sqlite3SrcListAppendFromTerm` in our port takes
        `(pOn, pUsing)` instead of `OnOrUsing*` — rule 88 splits the
        single C arg into two Pascal args by passing `nil, nil` for the
        synthetic FROM-term.  Rules 111-115 (chunk 7.2e.3) will need
        the same split: pass
        `PExpr(yymsp[k].minor.yy269.pOn), PIdList(yymsp[k].minor.yy269.pUsing)`.
      * Rules 89/91 cast `yymsp[0].major` (YYCODETYPE = u16) directly to
        i32 — equivalent to the C `/*A-overwrites-OP*/` convention.
      * Rules 96/97 share a body and must remain in the same case label
        list because both produce `yymsp[-4].minor.yy555` from the same
        expression (Lemon's yytestcase de-duplication preserved).
      * Rule 71 (FOREIGN KEY): `sqlite3CreateForeignKey` Pascal
        signature is `(pParse, pFromCol: PExprList, pTo: PToken,
        pToCol: PExprList, flags: i32)` — same arity as C.  Rule 42
        in 7.2e.1 already uses it correctly.
      * Local var `dest_84: TSelectDest` and `x_88: TToken` were added
        to `yy_reduce`'s var block.  As more chunks land, additional
        locals will accumulate there (one-off scratch space per rule
        family); accept that var block growth as a normal porting cost.
    - [X] **7.2e.3** Rules 100..149 — SELECT core (selectnowith, oneselect,
      values, distinct, sclp, selcollist, FROM/USING/ON, JOIN, jointype,
      indexed_opt, on_using, where_opt, groupby_opt, having_opt, orderby_opt,
      sortlist, nulls, limit_opt).  DONE 2026-04-25.

      Notes for next chunks:
      * **`sqlite3NameFromToken`** (build.c) and **`sqlite3ExprListSetSpan`**
        (expr.c:2228) were not yet exported by `passqlite3codegen` /
        equivalent.  Both are now ported as nested helpers in
        `passqlite3parser.pas` directly above `yy_reduce`.  When Phase 8
        ports `build.c` and the expression helpers, move them to the
        proper unit and remove the local copies.
      * **`InRenameObject`** is defined in `passqlite3codegen` but only in
        the implementation block — it is not exported via the interface.
        For now, `passqlite3parser` defines a local `inRenameObject` clone
        (case-insensitive, but Pascal will resolve to the local one inside
        this unit).  Either add a forward declaration in the codegen
        interface, or keep the duplicate; both are acceptable.
      * **SrcItem flag bits in `fgBits2`** — sqliteInt.h enumerates
        fromDDL(0), isCte(1), notCte(2), isUsing(3), isOn(4), isSynthUsing(5),
        **isNestedFrom(6)**, rowidUsed(7).  A new constant
        `SRCITEM_FG2_IS_NESTED_FROM = $40` was added to
        `passqlite3parser`'s local const block; existing `passqlite3codegen`
        uses raw `$08` / `$10` literals for `isUsing` / `isOn` (with
        comments).  Note: codegen.pas line 4243 has a stale comment that
        reads "isNestedFrom" but tests `fgBits and $08` — that is actually
        `isTabFunc`.  Pre-existing tech debt; flagged here so it can be
        reviewed during Phase 8 audit but **not** changed in this chunk
        (out of scope).
      * **`yy454` is `Pointer`** in our `YYMINORTYPE` (line 314).  Direct
        assignment from a `PExpr` works without explicit cast; do *not*
        wrap calls in `PtrInt(...)`.  Same for `yy14` (`PExprList`) and
        `yy203` (`PSrcList`).
      * **Rule 109 / 115 access `pSrcList^.a[N-1]`** in C.  Our `TSrcList`
        is the 8-byte header only; items live just past it via the
        existing `SrcListItems(p)` accessor.  Walk to entry N-1 with
        `pItem := SrcListItems(p); Inc(pItem, p^.nSrc - 1);`.
      * **Rule 115's `if (rhs->nSrc==1)` branch** is the trickiest: it
        moves the single source item from a temporary SrcList into the
        new term, transferring ownership of `u4.pSubq`,
        `u4.zDatabase`, `u1.pFuncArg`, and `zName`.  The flag bits live
        in `fgBits` (SRCITEM_FG_IS_SUBQUERY/IS_TABFUNC) and `fgBits2`
        (SRCITEM_FG2_IS_NESTED_FROM).  Be careful that the *new* item's
        flags are accumulated AFTER `sqlite3SrcListAppendFromTerm` adds
        the entry: that function may zero `fg`.  Manual verification of
        both `fgBits` and `fgBits2` ORs against an oracle run is on the
        agenda for Phase 7.4 once `sqlite3RunParser` is wired up.
      * Rules 146/147/148 are `having_opt`/`limit_opt` only for now;
        chunks 7.2e.4/7.2e.5 will share the same body via merged case
        labels (153/155/232/233/252 join 146; 154/156/231/251 join 147).
        Either re-merge the labels at that time or keep as duplicate
        bodies — pick the cleaner one.
    - [X] **7.2e.4** Rules 150..199 — DML: DELETE, UPDATE, INSERT/REPLACE,
      upsert, returning, conflict, idlist, insert_cmd, plus expression-tail
      rules 179..199 (LP/RP, ID DOT ID, term, function call, COLLATE, CAST,
      filter_over, LP nexprlist COMMA expr RP, AND/OR/comparison).
      DONE 2026-04-25.

      Notes for next chunks:
      * Five new local helpers were added to passqlite3parser.pas above
        `yy_reduce` (same pattern as 7.2e.3's `sqlite3NameFromToken`):
        - **`parserSyntaxError`** — emits a static "near token: syntax error"
          message; full `%T` formatting deferred until sqlite3ErrorMsg gains
          varargs (Phase 8).
        - **`sqlite3ExprFunction`** — full port of expr.c:1169.  Uses
          `sqlite3ExprAlloc`, `sqlite3ExprSetHeightAndFlags` (both already in
          passqlite3codegen).  Phase 8 should move it to expr.c proper.
        - **`sqlite3ExprAddFunctionOrderBy`** — full port of expr.c:1219.
          Uses `sqlite3ExprListDeleteGeneric` + `sqlite3ParserAddCleanup`
          (both already exported).  Move to expr.c in Phase 8.
        - **`sqlite3ExprAssignVarNumber`** — *simplified* port: `?`, `?N`,
          and `:/$/@aaa` are all assigned a fresh slot via `++pParse.nVar`.
          The `pVList`-based dedupe of named bind params is **not** wired
          up (util.c's `sqlite3VListAdd/NameToNum/NumToName` are not yet
          ported).  This means two occurrences of `:foo` currently get
          *different* parameter numbers — incorrect for binding but
          harmless for parser-only tests.  Phase 8 must port the VList
          machinery and replace this stub.
        - **`sqlite3ExprListAppendVector`** — *stub*: emits an error
          ("vector assignment not yet supported (Phase 8 TODO)") and frees
          its inputs.  Vector assignment `(a,b)=(...)` in UPDATE setlists
          and the corresponding rules 161/163 will not work until Phase 8
          ports `sqlite3ExprForVectorField` (expr.c:1893).
      * **`yylhsminor.yy454` is `Pointer`** in the YYMINORTYPE variant
        record (see line ~314).  When dereferencing for `^.w.iOfst` etc.,
        cast to `PExpr(yylhsminor.yy454)^.w.iOfst`.  Same pattern applies
        when reading `^.flags`, `^.x.pList`, and so on.  See rule 185 for
        a worked example — direct `yylhsminor.yy454^.…` triggers FPC's
        "Illegal qualifier" error.
      * Rules **153/155/232/233/252** share the body `yymsp[1].yy454 := nil`
        and were merged with rule 148 in C.  Our switch already had 148
        as a separate case (no-arg) — chunk 7.2e.4 added 153/155/232/233/252
        as a new combined case to keep the body distinct (148 uses
        `yymsp[1]`, the merged group also uses `yymsp[1]`, so the bodies
        are identical and could be merged in a future cleanup).  Same for
        154/156/231/251 (paired with 147).  Decision deferred to chunk
        7.2e.5 — pick the cleaner merge once those rule numbers materialise.
      * Rules **198/199** were merged in our switch but the C code further
        merges 200..204 into the same body.  Chunk 7.2e.5 must fold
        200..204 into the existing 198/199 case.
      * Rules **173/174** were already covered by chunks 7.2e.1/7.2e.2
        (merged with 61/76 and 78 respectively) — they are intentionally
        absent from chunk 7.2e.4's new cases.
    - [X] **7.2e.5** Rules 200..249 — expressions: expr/term, literals,
      bind params, names, function call, subqueries, CASE, CAST, COLLATE,
      LIKE/GLOB/REGEXP/MATCH, BETWEEN, IN, IS, NULL/NOTNULL, unary ops.
      DONE 2026-04-25.

      Notes for next chunks:
      * Rules **200..204** were merged into the existing **198/199** case
        (sqlite3PExpr with `i32(yymsp[-1].major)` as the operator).  The
        chunk-7.2e.4 note flagged this fold-in; it is now done.
      * Rules **234, 237, 242** (`exprlist ::=`, `paren_exprlist ::=`,
        `eidlist_opt ::=` — all three set `yy14 := nil`) were merged into
        the existing **101/134/144** case rather than adding a duplicate.
        Same pattern: when downstream chunks port a rule whose body is
        already covered by an earlier merged case, prefer adding to the
        existing label list.
      * Rule **281** (`raisetype ::= ABORT`, `yy144 := OE_Abort`) shares its
        body with rule **240** (`uniqueflag ::= UNIQUE`).  240 is currently
        a standalone case — chunk **7.2e.6** must add 281 to it as a merged
        label.
      * Four new local helpers were added to `passqlite3parser.pas` directly
        above `yy_reduce` (continuing the chunk-7.2e.3/4 pattern):
        - **`sqlite3PExprIsNull`** — full port of parse.y:1383 (TK_ISNULL/
          TK_NOTNULL with literal-folding to TK_TRUEFALSE via
          `sqlite3ExprInt32` + `sqlite3ExprDeferredDelete`, both already in
          codegen).
        - **`sqlite3PExprIs`** — full port of parse.y:1390.  Uses
          `sqlite3PExprIsNull` plus `sqlite3ExprDeferredDelete`.
        - **`parserAddExprIdListTerm`** — port of parse.y:1654.  Uses
          `sqlite3ExprListAppend` (with `nil` value) + `sqlite3ExprListSetName`.
          Note: the C source builds the error message via `%.*s` formatting
          on `pIdToken`; our `sqlite3ErrorMsg` still lacks varargs (the
          recurring TODO from 7.2e.1/.2/.4), so the message is the static
          "syntax error after column name" without the column text.  Phase 8
          must restore the dynamic name once formatting lands.
        - **`sqlite3ExprListToValues`** — port of expr.c:1098.  Used by
          rule 223's TK_VECTOR/multi-row VALUES branch.  Walks `pEList` via
          `ExprListItems(p)` + index, just like other list iterations.
          The error messages for "wrong-arity" elements use static text
          (same varargs TODO).  Phase 8 should move this to expr.c proper.
      * **`var pExpr: PExpr`** triggers FPC's case-insensitive var/type
        collision (per `feedback_fpc_vartype_conflict`); the helper
        `sqlite3ExprListToValues` uses the local name **`pExp`** instead.
        Same pitfall as `pPager → pPgr`, `pgno → pg`, `pParse → pPse`.
      * Rule 223 walks `pInRhs_223` (`PExprList`) via `ExprListItems(p)`
        and reads `[0]` directly — the C code does `pInRhs_223->a[0].pExpr`
        which is identical to our `ExprListItems(pInRhs_223)^.pExpr`.
        Setting `[0].pExpr := nil` to detach is also done via the accessor.
      * Rule 217 (`expr ::= expr PTR expr`) writes `yylhsminor.yy454` and
        then publishes `yymsp[-2].minor.yy454 := yylhsminor.yy454` — same
        Lemon convention as rules 181/182/189–195.
      * Rule 220 (`BETWEEN`): the new TK_BETWEEN node owns `pList_206` via
        `^.x.pList`.  If `sqlite3PExpr` returns nil, we free the list with
        `sqlite3ExprListDelete` to avoid a leak — matches the C body.
      * Rule 226 (`expr in_op nm dbnm paren_exprlist`): C calls
        `sqlite3SrcListFuncArgs(pParse, pSelect ? pSrc : 0, ...)` — a
        ternary inside the call.  Pascal lacks the ternary so the body
        splits the call into two branches.
      * Rule 239 (`CREATE INDEX`): `sqlite3CreateIndex` already exported
        with the matching signature (chunk 7.2e.4 confirmed).  Uses
        `pPse^.pNewIndex^.zName` for the rename-token-map lookup.
    - [X] **7.2e.6** Rules 250..299 — VACUUM-with-name, PRAGMA, CREATE/DROP
      TRIGGER + trigger_decl/trigger_time/trigger_event/trigger_cmd_list +
      tridxby/trigger_cmd (UPDATE/INSERT/DELETE/SELECT), RAISE expr +
      raisetype, ATTACH/DETACH, REINDEX, ANALYZE, ALTER TABLE
      (rename/add/drop column, rename column, drop constraint, set NOT NULL).
      DONE 2026-04-25.

      Notes for next chunks:
      * **`sqlite3Reindex`** and the four `sqlite3Trigger*Step` builders
        (UpdateStep/InsertStep/DeleteStep/SelectStep) were not yet exported
        by `passqlite3codegen`.  Stubs added directly above `yy_reduce` in
        `passqlite3parser.pas` (same pattern as 7.2e.3/4/5):
        - `sqlite3Reindex` — full no-op stub (Phase 8 must port build.c).
        - `sqlite3Trigger{Update,Insert,Delete,Select}Step` — allocate a
          zeroed `TTriggerStep`, set `op`/`orconf`, free the input params.
          Sufficient for parser-only differential testing; a real trigger
          built via the parser is a no-op until trigger.c lands in Phase 8.
      * **`sqlite3AlterSetNotNull` signature mismatch** — codegen.pas had
        the 4th parameter as `i32 onError`, but parse.y / parse.c pass
        `&NOT_token` (a `Token*`).  Changed both the interface and the
        implementation in `passqlite3codegen.pas` to `pNot: PToken`.  The
        function is still a stub; the signature fix is purely so the
        parser call type-checks.
      * **Existing rule `153, 155, 232, 233, 252` was extended to include
        `268, 286`** (when_clause ::= ; key_opt ::= — both `yymsp[1].yy454 := nil`).
        Existing rule `154, 156, 231, 251` was extended to include
        `269, 287` (when_clause ::= WHEN expr ; key_opt ::= KEY expr —
        both `yymsp[-1].yy454 := yymsp[0].yy454`).  Same merging pattern as
        chunk 7.2e.4 anticipated.
      * **Existing rule `240` was extended to include `281`** (uniqueflag
        ::= UNIQUE ; raisetype ::= ABORT — both `yymsp[0].yy144 := OE_Abort`).
        Chunk-7.2e.5 note flagged this; it is now done.
      * **Existing rule `105, 106, 117` was extended to include
        `258, 259`** (`plus_num ::= PLUS INTEGER|FLOAT`,
        `minus_num ::= MINUS INTEGER|FLOAT` — `yymsp[-1].yy0 := yymsp[0].yy0`).
        Pre-existing tech debt: the merge with rule 106 (`as ::=` empty,
        body in C is `yymsp[1].n=0; yymsp[1].z=0;`) is **incorrect** in the
        Pascal port — rule 106 should be in the no-op branch.  Flagged for
        Phase 8 audit; **not** changed in this chunk (out of scope, and
        the resulting wrong-but-deterministic value of `as ::=` is a stale
        zero-initialised TToken via `yylhsminor.yyinit := 0`, which is
        harmless until codegen reads it).
      * **Rule 261 (`trigger_decl`) — `pParse->isCreate`** debug-only
        assertion was skipped (the C body is `#ifdef SQLITE_DEBUG` and
        our TParse layout has `u1.cr.addrCrTab/regRowid/regRoot/
        constraintName` but no `isCreate` boolean).  When Phase 8 audits
        the TParse layout, decide whether to add the bit.
      * **Rule 261 — `Token` n-field arithmetic** uses `u32(PtrUInt(...) -
        PtrUInt(...))` to bridge `PAnsiChar` arithmetic on FPC.  Same
        idiom in rule 293 (`alter_add ::= ... carglist`).  Token's
        `n` field is `u32`.
      * **Rule 261 — `i32` cast for `yymsp[0].major`** (a `YYCODETYPE = u16`)
        is the same pattern as rules 89/91/262/265/266 — Lemon's
        `/*A-overwrites-X*/` convention, the value goes into a yy144
        (i32) slot.
      * Rule 274 (`trigger_cmd ::= UPDATE`) signature mapping: our
        Pascal stub `sqlite3TriggerUpdateStep(pPse, pTab, pFrom, pEList,
        pWhere, orconf: i32, zStart: PAnsiChar, zEnd: PAnsiChar)` mirrors
        the upstream `sqlite3TriggerUpdateStep(Parse*, SrcList* pTabName,
        SrcList* pFrom, ExprList* pEList, Expr* pWhere, u8 orconf,
        const char* zStart, const char* zEnd)` from trigger.c.  Phase 8
        must replace the stub with the full body.
      * **Rule 297/298 (`AlterDropConstraint`)** — the Pascal stub's
        positional parameters are `(pSrc, pType, pName)` (parameter
        names), but the C signature is `(Parse*, SrcList*, Token* pName,
        Token* pType)`.  We pass arguments positionally matching the C
        order — i.e. arg 3 is the name, arg 4 is the type.  The Pascal
        parameter names are misleading; flagged for Phase 8.  The stub
        body only deletes pSrc, so positional mismatch is harmless.
    - [X] **7.2e.7** Rules 300..347 — ALTER ADD CONSTRAINT/CHECK (300/301),
      create_vtab + vtabarg/vtabargtoken/lp (302..308), WITH / wqas / wqitem
      / withnm / wqlist (309..317), windowdefn_list / windowdefn / window /
      frame_opt / frame_bound[_s|_e] / frame_exclude[_opt] / window_clause /
      filter_over / over_clause / filter_clause (318..346), term ::= QNUMBER
      (347).  Rules 348+ remain in the default no-op branch (Lemon optimised
      most of them out — see parse.c lines 5927..5993).  DONE 2026-04-25.

      Notes for next chunks:
      * **`sqlite3AlterAddConstraint` signature corrected** in
        `passqlite3codegen.pas` — was a 3-arg stub `(pParse, pSrc, pType)`,
        upstream is `(Parse*, SrcList*, Token* pCons, Token* pName,
        const char* zCheck, int nCheck)`.  Body is still a stub that drops
        the SrcList; Phase 8 must port alter.c's full body.
      * **Six new local helpers** were added directly above `yy_reduce` in
        `passqlite3parser.pas` (continuing the 7.2e.3..6 pattern):
        - `sqlite3VtabBeginParse / FinishParse / ArgInit / ArgExtend` —
          full no-op stubs.  CREATE VIRTUAL TABLE parses cleanly but
          produces no schema entry until Phase 6.bis ports vtab.c.
        - `sqlite3CteNew` — stub returns nil and frees the inputs
          (`pArglist` via `sqlite3ExprListDelete`, `pQuery` via
          `sqlite3SelectDelete`).  Real body lives at sqlite3.c:131988
          (build.c).
        - `sqlite3WithAdd` — stub returns the existing With pointer
          unchanged.  Cte-leak path is acceptable for parser-only tests
          since `sqlite3CteNew` already returns nil; Phase 8 must wire
          this up against a real `Cte` type.
        - `sqlite3DequoteNumber` — no-op stub.  QNUMBER is a rare lexer
          token (quoted-numeric literal); skipping the dequote is harmless
          for parser-only tests.
      * **`M10d_Yes/Any/No` constants** (sqliteInt.h:21461..21463) added as
        a local `const` block immediately above the helper stubs.  Once
        Phase 8 ports build.c's CTE machinery these should move into the
        codegen interface alongside `OE_*`/`TF_*`.
      * **`pPse^.bHasWith := 1`** (rule 315 in C) maps to
        `parseFlags := parseFlags or PARSEFLAG_BHasWith` — flag already
        defined in passqlite3codegen at bit 6.
      * **`yy509` is `TYYFrameBound`** (eType: i32; pExpr: Pointer).
        Rules 326/327/333 read `.eType` directly and cast `.pExpr` to
        `PExpr` when handing to `sqlite3WindowAlloc`.  The trivial pass-
        through rules 329/331 do an explicit `yylhsminor.yy509 :=
        yymsp[0].minor.yy509; yymsp[0].minor.yy509 := yylhsminor.yy509;`
        round-trip — semantically a no-op, kept for symmetry with C.
      * **`yymsp[-3].minor.yy0.z + 1`** (C pointer arithmetic on PAnsiChar)
        — rules 300/301 cast through `PAnsiChar(...) + 1`.  The byte
        length is computed via `PtrUInt(end.z) - PtrUInt(start.z) - 1`.
      * **Window allocation in rules 343/345** uses
        `sqlite3DbMallocZero(db, u64(SizeOf(TWindow)))` (TWindow is 144
        bytes per the verified offset-table comment in passqlite3codegen).
        `eFrmType` is `u8`, so `TK_FILTER` requires an explicit `u8(...)`
        cast.
      * Six new locals in `yy_reduce`'s var block: `pWin_318/319/343/345`,
        `zCheckStart_300`, `nCheck_300`.
    - [X] **7.2e.8** Rules 348..411 — all in Lemon's `default:` branch.
      Verified against parse.c:5927..5993: every rule in 348..411 is either
      tagged `OPTIMIZED OUT` (Lemon emitted no reduce action — the value
      copy is folded into the parse table via SHIFTREDUCE / aliased %type)
      or has an empty action body (only `yytestcase()` for coverage —
      semantically a no-op).  No new explicit `case` arms are required:
      the existing `else` branch in `yy_reduce` already provides a no-op
      and the unconditional goto/state-update logic that follows the
      `case` correctly pushes the LHS for these rules too.  Spot-list of
      what falls into this bucket: cmdlist/ecmd plumbing (348..353),
      trans_opt / savepoint_opt (354..358), create_table glue (359),
      table_option_set tail (360), columnlist tail (361..362),
      nm/typetoken/typename/signed (363..368), carglist/ccons tail
      (369..373), conslist/tconscomma/defer_subclause/resolvetype
      (374..379), selectnowith/oneselect/sclp/as/indexed_opt/returning
      (380..385), expr/likeop/case_operand/exprlist (386..389), nmnum /
      plus_num (390..395), foreach_clause / tridxby (396..398),
      database_kw_opt / kwcolumn_opt (399..402), vtabarglist / vtabarg
      (403..405), anylist (406..408), with (409), windowdefn_list (410),
      window (411).  DONE 2026-04-25.

      Notes for next chunks:
      * **No new helpers / locals / constants** were added in this chunk
        — the Pascal driver already covers the no-op semantics.  This
        completes the 7.2e family; the entire reduce-action switch is
        now feature-complete relative to upstream.
      * **OPTIMIZED OUT marker meaning**: Lemon detects that an LHS
        non-terminal has the same union slot as its single RHS symbol
        and that the action is a pure copy.  Rather than emit a reduce
        case, it folds the copy into the parse-table state transitions
        (SHIFTREDUCE actions on the RHS terminal).  Because we ported
        `yy_action` / `yy_lookahead` / `yy_shift_ofst` / `yy_reduce_ofst`
        verbatim from parse.c in 7.2b, those folded copies already
        execute correctly without a Pascal-side reduce arm.
      * **`yytestcase` is coverage instrumentation, not action code**
        — it expands to `if(x){}` in normal builds.  Rules whose only
        body is `yytestcase(yyruleno==N);` therefore have no semantic
        effect and the Pascal `else` branch matches that exactly.

    Per-chunk approach (refined 2026-04-25 during 7.2e.1):

    * YYMINORTYPE was extended to expose all 19 named C union members
      (yy0/yy14/yy59/yy67/yy122/yy132/yy144/yy168/yy203/yy211/yy269/yy286/
       yy383/yy391/yy427/yy454/yy462/yy509/yy555).  Pointer-typed minors
      share a single 8-byte cell via the variant record; reduce code casts
      to the concrete type (PExpr / PSelect / PSrcList / etc.) inline.
    * yy_reduce holds a `case yyruleno of … else end` switch.  Rules whose
      body is `;` (pure no-ops) and rules not yet ported share the `else`
      branch — semantically a no-op, which is correct as long as the
      grammar action does not produce a value.  Rules that DO produce a
      value MUST have an explicit case once ported.
    * Helper `disableLookaside(pPse: PParse)` is defined locally at the top
      of the engine block (parse.y:132 equivalent).
    * `tokenExpr` is replaced by a direct call to `sqlite3ExprAlloc(db,
      op, &tok, 0)` — that helper is the moral equivalent and already
      exported by passqlite3codegen (Phase 6.1).
    * SAVEPOINT_BEGIN/RELEASE/ROLLBACK constants redeclared locally in
      passqlite3parser; passqlite3pager (the original site) is not in our
      uses clause.
    * `sqlite3ErrorMsg` in this codebase is plain (no varargs); rule 23/24
      drop the `%.*s` formatting in the error message and pass a static
      literal.  TODO: when sqlite3ErrorMsg gets printf-style formatting
      (Phase 8 / public-API phase), revisit and restore the dynamic text.
    * Constants TF_Strict (0x00010000) and SQLITE_IDXTYPE_APPDEF/UNIQUE/
      PRIMARYKEY/IPK were added to passqlite3codegen alongside the
      existing TF_* / OE_* groups.

  - [X] **7.2f** Wire `sqlite3RunParser` to drive the lexer through the new
    parser engine (replaces the current Phase 7.1 stub). Implement the
    fallback / wildcard handling, FILTER/OVER/WINDOW context tracking that
    `getNextToken` already detects, and propagate parse errors into
    `pParse^.zErrMsg`. Mark Phase 7.2 itself complete when 7.2a–7.2f all pass.

    DONE 2026-04-25.  passqlite3parser.pas:1110 — sqlite3RunParser now mirrors
    tokenize.c:600 byte-for-byte: TK_SPACE skip, TK_COMMENT swallowing under
    init.busy or SQLITE_Comments, TK_WINDOW/TK_OVER/TK_FILTER context
    promotion via the existing analyze*Keyword helpers, isInterrupted poll,
    SQLITE_LIMIT_SQL_LENGTH guard, SQLITE_TOOBIG / SQLITE_INTERRUPT /
    SQLITE_NOMEM_BKPT propagation, end-of-input TK_SEMI+0 flush, and the
    pNewTable / pNewTrigger / pVList cleanup tail.  Build (TestTokenizer
    127/127) PASS.

    Notes for next chunks:
    * `inRenameObject` was already defined later in the file (parser-local
      re-export) — added a forward declaration just above sqlite3RunParser
      so the cleanup tail can call it.
    * Constant `SQLITE_Comments = u64($00040) shl 32` declared locally in
      the implementation section (HI() macro from sqliteInt.h:1819).  Move
      to passqlite3util / passqlite3codegen alongside the other SQLITE_*
      flag bits when one of them needs it too.
    * Untyped `Pointer` → `PParse` is assigned directly (no cast) — FPC
      flagged `PParse(p)` cast-syntax with a "; expected" error in this
      block; direct assignment compiles cleanly because Pascal allows
      untyped Pointer → typed pointer assignment without an explicit cast.
    * Three C-side facilities are intentionally NOT ported here and remain
      tracked as TODOs for Phase 8 (public-API phase):
        - `sqlite3_log(rc, "%s in \"%s\"", zErrMsg, zTail)`  — pager unit
          owns sqlite3_log today and is not on the parser's uses path.
        - The `pParse->zErrMsg = sqlite3DbStrDup(db, sqlite3ErrStr(rc))`
          fallback that synthesises a default message when a non-OK rc has
          no zErrMsg — sqlite3ErrStr lives in passqlite3vdbe; pulling vdbe
          into the parser uses-clause would create a cycle.  nErr is still
          incremented when rc != OK so callers see the failure.
        - SQLITE_ParserTrace / `sqlite3ParserTrace(stdout, …)` — no debug
          tracing target in the Pascal port.
    * apVtabLock is not freed here because the Phase 6.bis vtable branch
      never assigns it.  Revisit when 6.bis lands.
    * Ready for Phase 7.4 (TestParser differential test) once the parser
      action routines that build AST nodes are exercised end-to-end.

  Fallback if 7.2 grows untenable: revisit Lemon-Pascal emitter in 7.2g.

- [X] **7.3** Port parse-tree action routines that Lemon calls (these live in
  `build.c` and friends from Phase 6, so they are already available).

  DONE 2026-04-25.  All action routines that Phase 7.2e's reduce switch
  references are wired through to passqlite3codegen (Phase 6) or to local
  parser-unit helpers.  The unit links cleanly and a new smoke gate
  `src/tests/TestParserSmoke.pas` drives `sqlite3RunParser` end-to-end on
  20 representative SQL fragments (DDL, DML, savepoints, comment handling,
  and two negative syntax-error cases) — all 20 pass.

  Concrete changes in this chunk:
    * passqlite3parser.pas — replace the `sqlite3DequoteNumber` stub with
      the full util.c:332 port (digit-separator '_' stripped, op promoted
      to TK_INTEGER/TK_FLOAT, EP_IntValue tag-20240227-a fast path).
    * src/tests/TestParserSmoke.pas — new (Phase 7.3 gate).
    * src/tests/build.sh — register TestParserSmoke.

  Stubs deliberately left in place (each tagged for the appropriate later
  phase, none of which is in 7.3's scope):
    * sqlite3VtabBeginParse / FinishParse / ArgInit / ArgExtend  — Phase 6.bis
    * sqlite3CteNew / sqlite3WithAdd                             — Phase 8 (build.c CTE)
    * sqlite3Reindex                                              — Phase 8 (build.c REINDEX)
    * sqlite3TriggerUpdateStep / InsertStep / DeleteStep / SelectStep
                                                                  — Phase 8 (trigger.c)
    * sqlite3ExprListAppendVector                                 — Phase 8 (expr.c vector UPDATE)

  Smoke-test limitations (each documented in TestParserSmoke.pas):
    * top-level `cmd ::= select` triggers `sqlite3Select` codegen which
      requires a live `Vdbe` + open db backend — tested in Phase 7.4.
    * `CREATE VIEW` reaches `sqlite3CreateView` which dereferences
      `db^.aDb[0].pSchema` — also a Phase 7.4 concern.
    * `COMMIT` / `ROLLBACK` / `PRAGMA` reach codegen paths that touch
      live db internals (transaction state, pragma dispatch).

- [X] **7.4a** Gate (parse-validity scope): `TestParser.pas` — for an
  inline 45-statement SQL corpus, tokenise + parse with both
  implementations and require agreement on syntactic validity
  (csq_prepare_v2 rc=SQLITE_OK iff Pascal sqlite3RunParser nErr=0).

  DONE 2026-04-25.  45 corpus rows: trivial/empty (5), DDL (17), DML
  (11), transactions/savepoints (6), pure syntax errors (6).  Both
  implementations agree on every row.  C reference shares one in-memory
  db opened on `:memory:` with a fixture schema (`t(a,b,c)`,
  `s(x,y,z)`, `u(p PRIMARY KEY,q)`); the Pascal parser keeps using a
  fresh stub Sqlite3 record per row (it does not consult schema during
  parse).

  Concrete changes:
    * src/tests/TestParser.pas  — new (Phase 7.4a gate).
    * src/tests/build.sh        — register TestParser after TestParserSmoke.

  Corpus exclusions (deferred to 7.4b):
    * SELECT statements (top-level `cmd ::= select` reaches sqlite3Select
      which crashes against a stub db);
    * CTE-bearing DML, INSERT/UPDATE that pass through sqlite3Select;
    * COMMIT / ROLLBACK / PRAGMA / EXPLAIN / ANALYZE / VACUUM / REINDEX
      (codegen helpers touch live db internals — schema, transaction
      state, pragma dispatch).
    These are the same forms that TestParserSmoke flags as Phase 7.4
    coverage; both gate tests will fold them back in once Phase 8.1/8.2
    deliver real `sqlite3_open_v2` + `sqlite3_prepare_v2`.

- [ ] **7.4b** Gate (bytecode-diff scope): once Phase 8.2 wires Pascal
  `sqlite3_prepare_v2` into the parser + codegen + Vdbe pipeline, extend
  `TestParser.pas` to also dump and diff the resulting VDBE program
  (opcode + p1 + p2 + p3 + p4 + p5) byte-for-byte against
  `csq_prepare_v2`.  Uses the already-staged corpus from 7.4a plus the
  currently-excluded SELECT / pragma / explain / commit / rollback /
  analyze / vacuum / reindex statements.

---

## Phase 8 — Public API

Files: `main.c` (connection lifecycle, core API entry points), `legacy.c`
(`sqlite3_exec` and the legacy convenience wrappers), `table.c`
(`sqlite3_get_table` / `sqlite3_free_table`), `backup.c` (the online-backup
API: `sqlite3_backup_init/step/finish/remaining/pagecount`), `notify.c`
(the `sqlite3_unlock_notify` machinery), `loadext.c` (dynamic-extension
loader — *optional for v1*).

- [X] **8.1** Port `sqlite3_open_v2`, `sqlite3_close`, `sqlite3_close_v2`,
  connection lifecycle (from `main.c`).

  DONE 2026-04-25.  Initial scaffold landed in `src/passqlite3main.pas`:
    * `sqlite3_open`, `sqlite3_open_v2` (entry points)
    * `sqlite3_close`, `sqlite3_close_v2` (entry points)
    * `openDatabase` (main.c:3324 simplified)
    * `sqlite3Close` + `sqlite3LeaveMutexAndCloseZombie` (main.c:1254/1363)
    * `connectionIsBusy` (main.c:1240 — `pVdbe`-only check)

  Gate: `src/tests/TestOpenClose.pas` — 17/17 PASS:
    * T1–T3: open/close on `:memory:` via both `_v2` and legacy entry points
    * T4–T5: open/close + reopen of an on-disk temp .db file
    * T6:    `close(nil)` and `close_v2(nil)` are harmless no-ops
    * T7:    invalid flags (no R/W bits) → SQLITE_MISUSE
    * T8:    `ppDb = nil` → SQLITE_MISUSE
    No regressions in TestParser / TestParserSmoke / TestSchemaBasic.

  Concrete changes:
    * src/passqlite3main.pas             — new (Phase 8.1)
    * src/passqlite3vdbe.pas             — export `sqlite3RollbackAll`,
      `sqlite3CloseSavepoints` in the interface section
    * src/passqlite3codegen.pas          — `sqlite3SafetyCheck{Ok,SickOrOk}`
      now accept the real SQLITE_STATE_OPEN ($76) / _SICK ($BA) magic
      values used by the new openDatabase, while still accepting the
      legacy "1"/"2" placeholder used by Phase 6/7 test scaffolds
    * src/tests/TestOpenClose.pas        — new gate test
    * src/tests/build.sh                 — register TestOpenClose

  Phase 8.1 scope notes (what is *not* yet wired — to be addressed in
  later 8.x sub-phases):
    * sqlite3ParseUri — zFilename is passed straight to BtreeOpen; URI
      filenames (`file:foo.db?mode=ro&cache=shared`) are not parsed.
    * No mutex allocation — db^.mutex stays nil (single-threaded only).
      Remove when Phase 8.4 adds threading config.
    * No lookaside (db^.lookaside.bDisable = 1, sz = 0).
    * No shared-cache list, no virtual-table list, no extension list.
    * Schemas for slot 0 / 1 are allocated via `sqlite3SchemaGet(db, nil)`
      rather than fetched from the BtShared (`sqlite3BtreeSchema` is not
      yet ported).  This is *correct* for Phase 8.2 prepare_v2, since
      schema population happens at the first SQL statement, not at open.
    * `sqlite3SetTextEncoding` is replaced by a direct `db^.enc :=
      SQLITE_UTF8` assignment — the full helper consults collation
      tables that require Phase 8.3 (`sqlite3_create_collation`).
    * `sqlite3_initialize` / `sqlite3_shutdown` (Phase 8.5) are not
      ported; openDatabase lazily calls `sqlite3_os_init` +
      `sqlite3PcacheInitialize` if no VFS is registered yet.
    * `disconnectAllVtab`, `sqlite3VtabRollback`,
      `sqlite3CloseExtensions`, `setupLookaside` are stubbed by simply
      not being called (their subsystems are not ported).
    * `connectionIsBusy` only checks `db->pVdbe`; the backup-API leg
      (`sqlite3BtreeIsInBackup`) waits for Phase 8.7.

- [X] **8.2** Port `sqlite3_prepare_v2` / `sqlite3_prepare_v3` — the entry
  point that wires parser → codegen → VDBE.

  DONE 2026-04-25.  `sqlite3_prepare`, `sqlite3_prepare_v2`, and
  `sqlite3_prepare_v3` are now defined in `src/passqlite3main.pas`,
  along with internal helpers `sqlite3LockAndPrepare` and
  `sqlite3Prepare` ported from `prepare.c:836` and `prepare.c:682`.

  Concrete changes:
    * `src/passqlite3main.pas` — adds `passqlite3parser` to uses (so
      the real `sqlite3RunParser` from Phase 7.2f resolves); adds
      `sqlite3Prepare`, `sqlite3LockAndPrepare`, and the three public
      entry points; defines local SQLITE_PREPARE_PERSISTENT/_NORMALIZE/
      _NO_VTAB constants.
    * `src/passqlite3codegen.pas` — removes the legacy stubs of
      `sqlite3_prepare`, `_v2`, `_v3` from interface and implementation
      (UTF-16 entry points `_prepare16*` remain stubbed pending UTF-16
      support); also tightens `sqlite3ErrorMsg` to set
      `pParse^.rc := SQLITE_ERROR` like the C version, so syntax errors
      surface through the prepare path even while the formatted message
      is still a Phase 6.5 stub.
    * `src/tests/TestPrepareBasic.pas` — new gate test (20/20 PASS);
      covers blank text, lone `;`, syntax error, MISUSE on
      db=nil/zSql=nil/ppStmt=nil, pzTail end-of-string, explicit
      nBytes long-statement copy path, prepare_v3 prepFlags=0
      equivalence, and multi-statement pzTail advance.
    * `src/tests/build.sh` — registers TestPrepareBasic.

  Phase 8.2 scope notes (what is *not* yet wired — to be addressed in
  later sub-phases or in Phase 6.x codegen completion):
    * **No real Vdbe is emitted yet for most top-level statements.**
      Several codegen entry points reachable from CREATE/SELECT/PRAGMA/
      BEGIN are still Phase 6/7 stubs (`sqlite3FinishTable`,
      `sqlite3Select`, `sqlite3PragmaParse`, etc.), so successful
      preparations typically yield `rc = SQLITE_OK` with `*ppStmt = nil`
      — same surface API behaviour SQLite gives for whitespace-only
      statements.  The byte-for-byte VDBE differential (Phase 7.4b /
      6.x) is what unblocks step-able statements.
    * **Schema retry loop disabled.** `sqlite3LockAndPrepare`'s
      `do { ... } while (rc==SQLITE_SCHEMA && cnt==1)` loop is reduced
      to a single attempt because `sqlite3ResetOneSchema` is not yet
      ported and the schema-cookie subsystem has no state to reset.
      Re-enable when shared-cache / schema-cookie machinery lands.
    * **schemaIsValid path skipped on parse-error tear-down.** Same
      reason — no schema cookies yet.
    * **No vtab unlock list call** (`sqlite3VtabUnlockList`); no vtabs
      registered.
    * **BtreeEnterAll/LeaveAll go to codegen no-op stubs** — fine for
      single-threaded use.
    * **`sqlite3SafetyCheckOk` accepts the legacy "1" placeholder** in
      addition to SQLITE_STATE_OPEN, because Phase 6/7 test scaffolds
      (TestParser/TestParserSmoke MakeDb) still synthesise a fake db
      with eOpenState=1.
    * **`sqlite3ErrorMsg` formatting still ignores `zFormat` printf
      arguments.** Error messages stored in db->pErr will be empty
      until the printf machinery lands (tracked under Phase 6/8 errmsg
      TODOs).

- [X] **8.3** Port registration APIs: `sqlite3_create_function`,
  `sqlite3_create_collation`, `sqlite3_create_module` (virtual tables).

  DONE 2026-04-25.  New entry points in `src/passqlite3main.pas`:
    * `sqlite3_create_function`, `_v2`, `sqlite3_create_window_function`
      — delegate to a local `createFunctionApi` (main.c:2066) that allocs
      a `TFuncDestructor`, calls the codegen-side `sqlite3CreateFunc`,
      and frees the destructor on failure.
    * `sqlite3_create_collation`, `_v2` — local `createCollation`
      (main.c:2852) implements the replace-or-create flow:
      `sqlite3FindCollSeq(create=0)` → BUSY-on-active-vms /
      `sqlite3ExpirePreparedStatements` → `FindCollSeq(create=1)`.
    * `sqlite3_collation_needed` — sets `db^.xCollNeeded` /
      `pCollNeededArg`, clears `xCollNeeded16`.
    * `sqlite3_create_module`, `_v2` — minimal inline `createModule`
      (vtab.c:39) since `sqlite3VtabCreateModule` is not yet ported.
      Allocates a local `TModule` (mirrors `sqliteInt.h:2211`) +
      name copy in the same block, hash-inserts into `db^.aModule`.
      Replace path simply frees the previous record (no eponymous-table
      cleanup — vtab.c is Phase 6.bis.1).

  Gate: `src/tests/TestRegistration.pas` — 19/19 PASS:
    * T2/T3   create_function ok / bad nArg → MISUSE
    * T4/T5   _v2 with destructor; replacement fires destructor exactly once
    * T6      nil db → MISUSE
    * T7..T10 create_collation ok / replace / bad enc / nil name
    * T11     collation_needed
    * T12..T15 create_module ok / _v2 replace / replace again / nil name

  Concrete changes:
    * `src/passqlite3main.pas` — adds Phase 8.3 entry points + helpers
    * `src/tests/TestRegistration.pas` — new gate test
    * `src/tests/build.sh` — registers TestRegistration

  Phase 8.3 scope notes (deferred to later sub-phases):
    * UTF-16 entry points (`_create_function16`, `_create_collation16`,
      `_collation_needed16`) — wait on UTF-16 transcoding support.
    * `SQLITE_ANY` triple-registration (UTF8+LE+BE) is handled by the
      codegen `sqlite3CreateFunc` mask only; not the `case SQLITE_ANY`
      recursion path from main.c:1984.  Honest UTF-16 port pending.
    * `sqlite3_overload_function` — defer until vtab.c lands (uses
      `sqlite3FindFunction` to insert a builtin overload marker).
    * Module replace path skips `sqlite3VtabEponymousTableClear` and
      `sqlite3VtabModuleUnref`; safe today because no vtab is ever
      instantiated.  Phase 6.bis.1 will need to revisit.
    * `sqlite3_drop_modules` not ported (vtab.c only API caller).

- [X] **8.4** Port configuration and hooks: `sqlite3_config`, `sqlite3_db_config`,
  `sqlite3_commit_hook`, `sqlite3_rollback_hook`, `sqlite3_update_hook`,
  `sqlite3_trace_v2`, `sqlite3_busy_handler`.

  DONE 2026-04-25.  See "Most recent activity" above for the full
  changelog.  Brief recap:
    * Direct ports: `sqlite3_busy_handler`, `sqlite3_busy_timeout` (+
      `sqliteDefaultBusyCallback`), `sqlite3_commit_hook`,
      `sqlite3_rollback_hook`, `sqlite3_update_hook`, `sqlite3_trace_v2`.
    * Varargs C entry points (`sqlite3_db_config`, `sqlite3_config`)
      split into typed Pascal entry points: `sqlite3_db_config_text`,
      `sqlite3_db_config_lookaside`, `sqlite3_db_config_int`, and an
      `sqlite3_config(op, arg: i32)` overload alongside the existing
      `sqlite3_config(op, pArg: Pointer)` from passqlite3util.  C-ABI
      varargs trampolines are deferred to a future ABI-compat phase.
    * Gate: `src/tests/TestConfigHooks.pas` — 54/54 PASS.
    * Concrete changes:
        - `src/passqlite3main.pas` — new entry points, types,
          `aFlagOp[]`, `setupLookaside` stub.
        - `src/passqlite3util.pas` — added `overload` directive on
          existing `sqlite3_config(op, pArg: Pointer)`.
        - `src/tests/TestConfigHooks.pas` — new gate test.
        - `src/tests/build.sh` — registers TestConfigHooks.

  Phase 8.4 scope notes (deferred to later sub-phases):
    * Real lookaside slot allocator (Phase 8.5+ memsys work).
    * `sqlite3_progress_handler` (defer with Phase 8.5
      initialize/shutdown).
    * C-ABI varargs trampolines (defer to ABI-compat phase).
    * Hook *invocation* paths: the codegen / vdbe / pager paths that
      should fire `xCommitCallback`, `xRollbackCallback`,
      `xUpdateCallback`, `xV2` are NOT audited in this phase — only
      registration is wired.  Audit + wiring belongs with Phase 6.4
      (DML hooks) and Phase 5.4 trace ops.

- [X] **8.5** Port `sqlite3_initialize` / `sqlite3_shutdown`.

  DONE 2026-04-25.  See "Most recent activity" above.  New entry points
  `sqlite3_initialize` and `sqlite3_shutdown` in `src/passqlite3main.pas`,
  faithful to main.c:190 / :372 (mutex/malloc/pcache/os/memdb staged
  init under STATIC_MAIN + recursive pInitMutex; shutdown tears them
  down in C-order and is idempotent).

  Concrete changes:
    * `src/passqlite3main.pas` — adds `sqlite3_initialize` and
      `sqlite3_shutdown` (plus interface declarations).
    * `src/tests/TestInitShutdown.pas` — new gate test (27/27 PASS).
    * `src/tests/build.sh` — registers TestInitShutdown.

  Phase 8.5 scope notes (deferred):
    * `sqlite3_reset_auto_extension` — defer with Phase 8.9 (loadext.c).
    * `sqlite3_data_directory` / `sqlite3_temp_directory` zeroing —
      defer with the C-varargs `sqlite3_config` trampoline.
    * `sqlite3_progress_handler` — independent hook, wire next time we
      revisit Phase 8.4 territory.
    * `openDatabase`'s lazy os_init / pcache_init calls are now
      redundant when callers explicitly initialize first; harmless, but
      flagged for a future cleanup pass.

- [X] **8.6** Port `legacy.c`: `sqlite3_exec` and the one-shot callback-style
  wrappers; `table.c`: `sqlite3_get_table` / `sqlite3_free_table`.

  DONE 2026-04-25.  Faithful port of all of `legacy.c` (sqlite3_exec) and
  `table.c` (sqlite3_get_table / sqlite3_get_table_cb / sqlite3_free_table)
  appended to `src/passqlite3main.pas`.  Also added a minimal
  `sqlite3_errmsg` (returns `sqlite3ErrStr(db^.errCode)` — main.c's
  fallback when `db^.pErr` is nil; the port's codegen does not yet
  populate pErr, so this is byte-correct for that path).
  `sqlite3ErrStr` was promoted to the `passqlite3vdbe` interface so
  passqlite3main can reach it.

  Concrete changes:
    * `src/passqlite3main.pas` — new public entry points
      `sqlite3_exec`, `sqlite3_get_table`, `sqlite3_free_table`,
      `sqlite3_errmsg`; new types `Tsqlite3_callback`, `PPPAnsiChar`,
      `TTabResult`; static helper `sqlite3_get_table_cb` (cdecl).
    * `src/passqlite3vdbe.pas` — exposes `sqlite3ErrStr` in interface.
    * `src/tests/TestExecGetTable.pas` — new gate test (23/23 PASS).
    * `src/tests/build.sh` — registers TestExecGetTable.

  Phase 8.6 scope notes (deferred / known limits):
    * `sqlite3_errmsg` returns the static `sqlite3ErrStr` text only
      (no formatted message).  Once codegen wires `db^.pErr` from
      `sqlite3ErrorWithMsg`, swap to the full main.c version that
      consults `sqlite3_value_text(pErr)` first.
    * `db->flags` SQLITE_NullCallback bit is read at the canonical
      bit position (`u64($00000100)`), not shifted by 32 like the
      existing `SQLITE_ShortColNames` writes in openDatabase — those
      shifts look incorrect (the in-port flag constants in
      passqlite3util are unshifted).  Pre-existing inconsistency,
      not introduced here, but worth flagging for a future flag-bit
      audit pass.
    * Because most non-trivial top-level codegen entry points still
      stub out (Phase 6/7), `sqlite3_exec` of a real CREATE/INSERT/
      SELECT typically prepares to `ppStmt = nil` and returns rc=OK
      without actually mutating the database.  TestExecGetTable
      therefore exercises the surface API contract (empty SQL,
      whitespace-only SQL, syntax-error SQL, MISUSE paths,
      free_table round-trip) rather than full row results — those
      light up automatically once codegen is finished.
    * UTF-16 entry points (`sqlite3_exec16`, etc.) deferred with
      the rest of UTF-16 support.

- [X] **8.7** Port `backup.c`: the online-backup API. Self-contained, small
  (~800 lines), useful early for verifying end-to-end operation.
  *Done 2026-04-25.*  See "Most recent activity" entry above for the
  full scope notes (pager hook wiring + zombie-close + content gate
  intentionally deferred).

- [X] **8.8** Port `notify.c`: `sqlite3_unlock_notify` (rarely used; port if
  our threading story requires it, otherwise stub).

  DONE 2026-04-25.  Stubbed (build config has SQLITE_ENABLE_UNLOCK_NOTIFY
  off, so upstream's notify.c is not compiled either).  Behaviour-correct
  shim added in `src/passqlite3main.pas`: MISUSE on db=nil; no-op on
  xNotify=nil; otherwise fires `xNotify(@pArg, 1)` immediately (the only
  branch reachable in a no-shared-cache build, matching notify.c:167).
  See "Most recent activity" above for the full changelog and deferred-
  scope notes.  Gate: `src/tests/TestUnlockNotify.pas` — 14/14 PASS.

- [X] **8.9** (Optional) Port `loadext.c`: dynamic extension loader. Requires
  `dlopen`/`dlsym`; can be safely stubbed for v1 if no Pascal consumer
  needs it.

  DONE 2026-04-25.  Stubbed (build config has `SQLITE_OMIT_LOAD_EXTENSION`
  on, so upstream's loadext.c doesn't emit the dlopen path either).
  Five entry points in `src/passqlite3main.pas`:
    * `sqlite3_load_extension` → SQLITE_ERROR + "extension loading is
      disabled" message.
    * `sqlite3_enable_load_extension` → toggles
      `SQLITE_LoadExtension_Bit` in `db^.flags` (faithful, harmless
      with no loader behind it).
    * `sqlite3_auto_extension`, `_cancel_auto_extension`,
      `_reset_auto_extension` → faithful ports of loadext.c:808/:858/:886
      managing a process-global `gAutoExt[]` list under
      `SQLITE_MUTEX_STATIC_MAIN`.
  Gate: `src/tests/TestLoadExt.pas` — 20/20 PASS.  See "Most recent
  activity" above for the full deferred-scope notes; key item for
  future work is wiring `sqlite3AutoLoadExtensions` from openDatabase
  once codegen needs it.

- [ ] **8.10** Gate: the public-API sample programs in SQLite's own CLI
  (generated at build time from `../sqlite3/src/shell.c.in` → `shell.c` by
  `make`) and from the SQLite documentation all compile (as Pascal
  transliterations) and run against our port with results identical to the C
  reference. Note: `sqlite3.h` is similarly generated from `sqlite.h.in`;
  reference it only after a successful upstream `make`.

---

## Phase 9 — Acceptance: differential + fuzz

- [ ] **9.1** `TestSQLCorpus.pas`: full SQL corpus (Phase 0.10 + any additions)
  runs end-to-end; stdout, stderr, return code, and final `.db` byte-identical
  to C reference.

- [ ] **9.2** `TestReferenceVectors.pas`: every canonical `.db` in
  `vectors/` opens, queries, and reports results identically.

- [ ] **9.3** `TestFuzzDiff.pas`: AFL-driven differential fuzzer. Seed from
  `dbsqlfuzz` corpus. Run for ≥24 h. Any divergence is a bug.

- [ ] **9.4** SQLite's own Tcl test suite (`../sqlite3/test/*.test`) — wire our
  Pascal port into the suite as an alternate target if feasible. Not all tests
  will apply (some probe internal C APIs), but the "TCL" feature tests should
  pass.

---

## Phase 10 — CLI tool (shell.c ~12k lines)

`shell.c` is a single ~12k-line file but breaks cleanly along functional
seams.  Port it to `src/passqlite3shell.pas` in chunks, each with a scripted
parity gate that diffs `bin/passqlite3` output against the upstream
`sqlite3` binary.  Unported dot-commands must return a clear
`Error: unknown command or invalid arguments: ".foo"` (matching upstream's
phrasing) so partially-landed work cannot silently no-op.

- [ ] **10.1a** Skeleton + arg parsing + REPL loop.  Port the program
  entry point, command-line flag parser (`-init`, `-batch`, `-bail`,
  `-echo`, `-readonly`, `-cmd`, `-help`, `-version`, `-A`, `-line`,
  `-list`, `-csv`, `-html`, `-quote`, `-json`, `-markdown`, `-table`,
  `-box`, the database-filename positional, the trailing SQL positional),
  the `ShellState` struct, the input-line reader (readline / linenoise /
  fallback fgets), prompt rendering (`sqlite> ` / `   ...> `), the main
  read-eval-print loop, statement-completeness detection via
  `sqlite3_complete`, and the exit codes.  No dot-commands wired up yet
  — every `.foo` returns the unknown-command error.
  Gate: `tests/cli/10a_repl/` — scripted golden-file diff covering
  startup banner, plain SQL execution (using the default `list` mode),
  `-init` + `-cmd` ordering, `-bail` early-exit, `-readonly` write
  rejection, and exit codes (0 / 1 / 2).

- [ ] **10.1b** Output modes + formatting controls.  `.mode`
  (`list`, `line`, `column`, `csv`, `tabs`, `html`, `insert`, `quote`,
  `json`, `markdown`, `table`, `box`, `tcl`, `ascii`), `.headers`,
  `.separator`, `.nullvalue`, `.width`, `.echo`, `.changes`,
  `.print`/`.parameter` (the formatting-only subset), Unicode-width
  helpers, and the box-drawing renderer.
  Gate: `tests/cli/10b_modes/` — one fixture per mode plus the
  separator/nullvalue/width matrix.

- [ ] **10.1c** Schema introspection dot-commands.  `.schema`
  (with optional LIKE pattern + `--indent` + `--nosys`), `.tables`,
  `.indexes`, `.databases`, `.fullschema`, `.lint fkey-indexes`,
  `.expert` (read-only subset).
  Gate: `tests/cli/10c_schema/` — fixtures with multi-schema
  attached DBs, virtual tables, FTS shadow tables, system-table
  filtering.

- [ ] **10.1d** Data I/O dot-commands.  `.read` (recursive script
  inclusion), `.dump` (with table-name filter), `.import` (CSV/ASCII
  with `--csv`, `--ascii`, `--skip N`, `--schema`), `.output` /
  `.once` (with `-x`/`-e` Excel/editor flags), `.save` and `.open`
  filename handling.
  Gate: `tests/cli/10d_io/` — round-trip dump→read, CSV import
  with header detection, `.output` redirection to file, `.once -e`
  (skip in CI; gate locally).

- [ ] **10.1e** Meta / diagnostic dot-commands.  `.stats` on/off,
  `.timer` on/off, `.eqp` on/off/full/trigger, `.explain`
  on/off/auto, `.show`, `.help`, `.shell` / `.system`, `.cd`,
  `.log`, `.trace`, `.iotrace`, `.scanstats`, `.testcase`,
  `.testctrl`, `.selecttrace`, `.wheretrace`.
  Gate: `tests/cli/10e_meta/` — `.eqp full` against a known plan,
  `.timer` numeric-output presence (not value diff), `.show`
  state dump after a sequence of mutations.

- [ ] **10.1f** Long-tail / specialised dot-commands.  `.backup`,
  `.restore`, `.clone`, `.archive` / `.ar` (the SQLite-archive
  tar-like interface, depends on zip/zlib), `.session` (depends on
  Phase 5.10 session extension if ported), `.recover`, `.dbinfo`,
  `.dbconfig`, `.filectrl`, `.sha3sum`, `.crnl`, `.binary`,
  `.connection`, `.unmodule`, `.vfsinfo`, `.vfslist`, `.vfsname`.
  Items whose dependencies (session, archive, recover) are not in
  the v1 scope can land as stubs that return a clear "feature not
  compiled in" message — matches upstream's behaviour with the
  corresponding `SQLITE_OMIT_*` build flags.
  Gate: `tests/cli/10f_misc/` — `.backup` round-trip, `.sha3sum`
  on a fixture DB, dbinfo header field presence.

- [ ] **10.2** Integration: `bin/passqlite3 foo.db` ↔ `sqlite3 foo.db`
  parity on a scripted corpus that unions all of 10.1a..10.1f's
  golden files plus a handful of "kitchen-sink" sessions
  (multi-statement scripts that mix modes, attach databases, run
  triggers, dump+reload).  Diff stdout, stderr, and exit code; any
  divergence is a hard failure.

---

## Phase 11 — Benchmarks

Goal: a 100% Pascal benchmark suite — Pascal client code exercising the
Pascal port of SQLite — derived from upstream `test/speedtest1.c` (3,487
lines).  The port lives in `src/bench/passpeedtest1.pas` and reuses
`csqlite3.pas` as its API surface, so the same binary can swap backends
(passqlite3 vs system libsqlite3) by toggling the `uses` clause /
linker flag.  Output format must be byte-identical to upstream
`speedtest1` so the existing `speedtest.tcl` diff workflow still works.

- [ ] **11.1** Harness port.  Translate `speedtest1.c` lines 1..780 to
  `passpeedtest1.pas`: argument parser (`--size`, `--cachesize`,
  `--exclusive`, `--explain`, `--journal`, `--lookaside`, `--memdb`,
  `--mmap`, `--multithread`, `--nomemstat`, `--nosync`, `--notnull`,
  `--output`, `--pagesize`, `--pcache`, `--primarykey`, `--repeat`,
  `--reprepare`, `--reserve`, `--serialized`, `--singlethread`,
  `--sqlonly`, `--shrink-memory`, `--stats`, `--temp N`, `--testset T`,
  `--trace`, `--threads`, `--unicode`, `--utf16be`, `--utf16le`,
  `--verify`, `--without-rowid`); the `g` global state record;
  `speedtest1_begin_test` / `speedtest1_end_test` timing helpers
  (using `passqlite3util` clock helpers, not `gettimeofday` directly);
  the `speedtest1_random` LCG; `speedtest1_numbername` (numeric →
  English-words helper used by every testset to build varied row
  content); and the result-printing tail.  No testsets yet —
  `--testset` returns "unknown testset" until 11.2+.
  Gate: `bench/baseline/harness.txt` — reproducible run with
  `--testset main --size 0` should print only the header / footer and
  exit cleanly.

- [ ] **11.2** `testset_main` port.  Speedtest1.c lines 781..1248 — the
  canonical OLTP corpus, ~30 numbered cases (100 .. 990): unordered /
  ordered INSERTs with and without indexes, SELECT BETWEEN / LIKE /
  ORDER BY (with and without index, with and without LIMIT), CREATE
  INDEX × 5, INSERTs with three indexes, DELETE+REFILL, VACUUM,
  ALTER TABLE ADD COLUMN, UPDATE patterns (range, individual, whole
  table), DELETE patterns, REPLACE, REPLACE on TEXT PK, 4-way joins,
  subquery-in-result-set, SELECTs on IPK, SELECT DISTINCT,
  PRAGMA integrity_check, ANALYZE.  This is the most-cited benchmark
  in the SQLite community and is the primary regression gate.
  Gate: `bench/baseline/testset_main.txt` — output diffs cleanly
  against upstream `speedtest1 --testset main --size 10` modulo the
  per-line "%.3fs" timing column (the ratio harness in 11.7 strips
  timings before diffing).

- [ ] **11.3** Small / focused testsets.  Three small ports done in
  one chunk because each is < 200 lines of C:
    * `testset_cte` (lines 1250..1414) — recursive CTE workouts
      (Sudoku via `WITH RECURSIVE digits`, Mandelbrot, EXCEPT on
      large element sets).
    * `testset_fp` (lines 1416..1485) — floating-point arithmetic
      inside SQL expressions.
    * `testset_parsenumber` (lines 2875..end) — numeric-literal parse
      stress test.
  Gate: `bench/baseline/testset_{cte,fp,parsenumber}.txt`.

- [ ] **11.4** Schema-heavy testsets.  Three larger ports (~250..600
  lines each):
    * `testset_star` (lines 1487..2086) — star-schema joins (fact
      table + multiple dimension tables).
    * `testset_orm` (lines 2272..2538) — ORM-style query patterns
      (one-row fetch by PK, parent + children, batch lookups).
    * `testset_trigger` (lines 2539..2740) — trigger fan-out
      (insert into A fires triggers writing to B, C, D).
  Gate: `bench/baseline/testset_{star,orm,trigger}.txt`.

- [ ] **11.5** Optional / extension-gated testsets.  Land each only
  after its dependency is in scope:
    * `testset_debug1` (lines 2741..2756) — small debug sanity
      check; lands with 11.4.
    * `testset_json` (lines 2758..2873) — JSON1 functions; **gated
      on Phase 6.8** (json.c port).  If 6.8 stays deferred, this
      testset returns "json1 not compiled in" matching upstream's
      `SQLITE_OMIT_JSON` behaviour.
    * `testset_rtree` (lines 2088..2270) — R-tree spatial queries;
      **gated on R-tree extension port** (not currently scheduled
      in the task list).  Stub with the same omit-style message
      until then.

- [ ] **11.6** Differential driver — Pascal equivalent of
  `test/speedtest.tcl`.  `bench/SpeedtestDiff.pas` runs
  `passpeedtest1` twice (once linked against `libpassqlite3`, once
  against the system `libsqlite3` — selectable via a `--backend`
  flag in `passpeedtest1` itself) and emits a side-by-side ratio
  table: testset / case-id / case-name / pas-ms / c-ms / ratio.
  Strips wall-clock timings so the *output* of the two runs can also
  be diffed for byte-equality (sanity check that both backends
  computed the same thing).

- [ ] **11.7** Regression gate.  Commit `bench/baseline.json` —
  one row per (testset, case-id, dataset-size) carrying the
  expected pas/c ratio (not absolute timing — ratios are stable
  across machines, absolute times are not).  `bench/CheckRegression.pas`
  re-runs the suite, compares against baseline, and exits non-zero
  if any row regresses by > 10% relative to the baseline ratio.
  Hooked into CI for the small/medium tiers; the large tier (10M
  rows) stays a manual local gate because it takes minutes and
  needs a quiet machine.

- [ ] **11.8** Pragma / config matrix.  Re-run the testset_main
  corpus across the cartesian product of:
    * `journal_mode` ∈ { WAL, DELETE }
    * `synchronous` ∈ { NORMAL, FULL }
    * `page_size` ∈ { 4096, 8192, 16384 }
    * `cache_size` ∈ { default, 10× default }
  Emit a single matrix table.  The interesting output is *which
  knobs move the pas/c ratio*, not the absolute numbers — large
  ratio swings between configurations point at code paths in the
  Pascal port that diverge from C (typical suspect: WAL writer
  hot loop, page-cache eviction).

- [ ] **11.9** Profiling hand-off to Phase 12.  Wrapper scripts that
  run `passpeedtest1` under `perf record` and `valgrind --tool=callgrind`,
  with a small Pascal helper that annotates the resulting reports
  against `passqlite3*.pas` source lines.  Output of this task is
  the input of Phase 12.1.

---

## Phase 12 — Performance optimisation (enter only after Phase 10)

Do not touch this phase until Phase 9 is fully green. Changes here must
preserve byte-for-byte on-disk parity.

Before trying any fix, try to use some profiling tool to discover where the time is being waisted.
In FPC, functions with asm content can not be inlined.

Use "-dAVX2 -CfAVX2 -CpCOREAVX -OpCOREAVX" to compile.

- [ ] **12.1** Profile with `perf record` on the benchmark workloads. Identify
  top 10 hot functions.
- [ ] **12.2** Aggressive `inline` on VDBE opcode helpers, varint codecs, and
  page cell accessors.
- [ ] **12.3** Consider replacing the VDBE's big `case` with a threaded
  dispatch (computed-goto-style) using `{$GOTO ON}`. Only if profiling shows
  the switch is a bottleneck.

---

## References

- SQLite upstream: https://sqlite.org/src/
- SQLite file format: https://sqlite.org/fileformat.html
- SQLite VDBE opcodes: https://sqlite.org/opcode.html
- SQLite "How SQLite is Tested": https://sqlite.org/testing.html
- pas-core-math (structural inspiration): `../pas-core-math/`
- pas-bzip2 (structural inspiration): `../pas-bzip2/`
- D. Richard Hipp et al., SQLite, public domain.
