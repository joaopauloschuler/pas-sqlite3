# STUB_INVENTORY.md — task 6.28 catch-all sweep

Generated for tasklist bullet 6.28 ("sweep — re-search for stub markers …").
Scope: every `stub`, `TODO`, `not ported`, `not yet ported`, `placeholder`,
`no-op` marker under `src/*.pas` and `src/*.inc` (excluding `src/tests/`).
Excludes the explicitly-gated `incrVacuumStep` / `relocatePage` /
`modifyPagePointer` family (gated on the unported productive ptrmap; see
tasklist §6 note).

Raw count: 256 marker hits across the production source.  After
deduplication and removal of stale-comment cases (helpers that *were*
stubs at the cited phase but have since been fully ported — the comment
banner just was not rewritten), the inventory below is the productive
list of behavioural stubs still in tree.

After the 6.28.3 / 6.28.4 / 6.28.7 / 6.28.8 / 6.28.9 / 6.28.10 audit
passes — and the 2026-06-09 re-audit — **0 actionable entries** remain
out of the original 21:
- #4 `sqlite3AddColumn` — DRIFTED-S; **landed in 6.28.4** (all 3 drift arms verified).
- #13 `sqlite3VdbeSorter*` PMA disk-spill — **CLOSED**: the disk-spill
  read-back landed in Phase 5.7.b.6..b.9 and `SORTER_PMA_ENABLED=True`
  since 5.7.b.9 (passqlite3vdbe.pas; verified 5.7.b.10).
All other entries are either CLOSED (was real, stale banner scrubbed)
or INTENTIONAL (faithful empty body matching C's preprocessor-gated
no-op).

Each entry uses the form:
```
Pascal: <file>:<line>  <symbol>
C ref : <file>:<line>
Note  : one line
Prio  : high|med|low   (blocks open tasklist bullet?)
```

---

## High priority — actively blocks an open tasklist bullet

### 1. `whereLoopAddVirtual` (vtab planner) — CLOSED (was real, task 6.28.8)
- Pascal: forward decl `src/passqlite3codegen.pas:1932`, body
  `src/passqlite3codegen.pas:15658..15818` (driver) +
  `:15458..15630` (whereLoopAddVirtualOne).
- C ref : `where.c:4681..4803` (whereLoopAddVirtual),
  `where.c:4313..4530` (whereLoopAddVirtualOne).
- Verdict: 6.28.8 audit found the body is a 1:1 four-pass driver port:
  (1) ALLBITS+IN-allowed with bRetry for LIMIT/IN conflict;
  (2) ALLBITS+WO_IN excluded if first plan used IN;
  (3) per-distinct-prereqRight loop;
  (4) all-disabled and all-disabled+no-IN fallbacks.  WHERETRACE 0x800
  banners faithful to where.c:4719..4801.  Callees
  (allocateIndexInfo, freeIndexInfo, whereLoopResize,
  whereLoopAddVirtualOne) are all real.  Stale "stub" banner at decl
  scrubbed.

### 2. `sqlite3OpenTableAndIndices` — CLOSED (was real, task 6.28.8)
- Pascal: forward decl `src/passqlite3codegen.pas:2507`, body
  `src/passqlite3codegen.pas:35907..35963`.
- C ref : `insert.c:2870..2925` (not build.c; original inventory cite
  was wrong).
- Verdict: 6.28.8 audit found the body is a 1:1 port: vtab no-op,
  iDataCur/iIdxCur cursor assignment, HasRowid + aToOpen[0] gate to
  sqlite3OpenTable, index loop with IsPrimaryKeyIndex+!HasRowid
  re-routing, sqlite3VdbeSetP4KeyInfo + ChangeP5.  The sqlite3TableLock
  fallback is correctly inert under the OMIT_SHARED_CACHE build (note
  in body matches C's `db->noSharedCache==0` arm).  Multiple stale
  "Phase 6.4 stub" comments in sqlite3DeleteFrom / its tail scrubbed.

### 3. `sqlite3NestedParse` — CLOSED (task 6.28.3)
- Pascal: `src/passqlite3codegen.pas:40499` (body), hook at
  `passqlite3parser.pas:4687`.
- C ref : `build.c:293..323`.
- Note  : Fully ported.  Mirrors C control flow byte-for-byte: early-out
  on nErr/eParseMode, sqlite3VMPrintf format, PARSE_TAIL save/restore via
  Move/FillChar, DBFLAG_PreferBuiltin toggle, dispatch through
  gNestedRunParser hook to sqlite3RunParser.  The stale "stub" notes at
  31164 / 37841 / 38937 are comments inside unrelated helpers (the line
  numbers shifted as code grew); the actual driver is at 40499 and was
  already structurally complete since commit c8aaa43.  Task 6.28.3
  removed the residual `if zFormat = nil then Exit` deviation from C and
  refreshed the banner to reflect production status.
- Prio  : —
- Size  : ~25 lines Pascal mirroring ~30 lines C.

### 4. `sqlite3AddColumn` — DRIFTED (port-extend: 3 small arms, S)
- Pascal: `src/passqlite3codegen.pas:37284..37407` (body).
- C ref : `build.c:1490..1596` (NOT 1862..2026; original inventory cite
  was wrong — STRICT-table column enforcement does not live in
  sqlite3AddColumn, it lives in sqlite3EndTable).
- Verdict: 6.28.8 audit found the body is largely 1:1.  Missing arms
  (all small, total ~25 lines C):
  - build.c:1507 `if( !IN_RENAME_OBJECT ) sqlite3DequoteToken(&sName);`
    — pre-allocation token dequote.
  - build.c:1513..1524 `GENERATED ALWAYS` trailing-text strip — surplus
    keyword trim when type ends with "always" / "generated always".
  - build.c:1530 `sqlite3DequoteToken(&sType);` inside the standard-
    typename check (Pascal compares against quoted tokens).
  - cosmetic: build.c:1531 uses a table-driven loop over
    sqlite3StdType[] / StdTypeLen[] / StdTypeAffinity[]; Pascal hardcodes
    the 6 branches — functionally equivalent but the table form would
    track upstream additions.
  No STRICT-arm work to do here (STRICT lives downstream).
- Prio  : low-med (none of the missing arms regress productive corpora;
  the GENERATED ALWAYS strip only affects unusual user-supplied type
  tokens).
- Size  : S (~25 lines C).

### 5. `sqlite3LimitWhere` helper — CLOSED (was real, task 6.28.8)
- Pascal: `src/passqlite3codegen.pas:31123..31217` (body).
- C ref : `delete.c:182..277` (only ~95 lines — earlier "..330" /
  "two arms" inventory cite was wrong; C has no useTempRow or
  view-on-DELETE rewrite arm in this helper).
- Verdict: 6.28.8 audit found the body is a 1:1 port: ORDER-BY-without-
  LIMIT error, LIMIT==NULL early-out, rowid arm (TK_ROW LHS + TK_ROW
  EList), single-column WITHOUT-ROWID PK arm, multi-column PK vector
  arm with TK_VECTOR LHS, FROM dup with isIndexedBy / isCte handling,
  inner SELECT build and TK_IN wrap.  Pending work is caller-side
  (sqlite3DeleteFrom / sqlite3Update do not yet pass pOrderBy/pLimit
  through to this helper) — annotated at the TODO sites in
  codegen.pas:31338 and :32419.  Stale "no-op stub" comments scrubbed.

### 6. `OP_IntegrityCk` opcode — CLOSED (was real, task 6.28.8)
- Pascal: `src/passqlite3vdbe.pas:10715..10748` (opcode arm),
  `src/passqlite3btree.pas:7916..8043` (sqlite3BtreeIntegrityCheck
  driver, with checkTreePage / checkPtrmap / checkAppendMsg /
  checkList callees all real).
- C ref : `vdbe.c` OP_IntegrityCk arm + `btree.c
  sqlite3BtreeIntegrityCheck`.
- Verdict: 6.28.8 audit found both the opcode arm and the btree
  integrity walker are real 1:1 ports.  Opcode marshals nRoot / aRoot,
  allocates per-tree row-count buffer, calls
  sqlite3BtreeIntegrityCheck, marshals row counts into aMem[p3..],
  handles SQLITE_DYNAMIC error-string marshalling and encoding
  conversion.  The walker covers freelist integrity, auto-vacuum
  rootpage cross-check, per-tree checkTreePage walk, page-coverage
  map.  Pending work is **pragma-driver-side**: `PRAGMA integrity_check`
  in codegen.pas:45844 still emits a hardcoded "ok" instead of building
  the OP_IntegrityCk plan.  Wiring slice (root-page enumeration,
  OP_IntegrityCk emission with P4_INTARRAY, multi-row error output)
  belongs in a future tasklist bullet — not "port OP_IntegrityCk".
  Stale "OP_IntegrityCk is a stub" comment at codegen.pas:45840
  scrubbed.

### 7. `getRowTrigger` mask helper — CLOSED (task 6.28.7)
- Pascal: `src/passqlite3codegen.pas:30884` (`trgGetRowTrigger`) +
  `:30709` (`codeRowTrigger`).
- C ref : `trigger.c:1347` / `trigger.c:1231`.
- Verdict: audit found inventory entry stale — both `trgGetRowTrigger`
  and `codeRowTrigger` were already 1:1 with C (cache lookup +
  TriggerPrg/SubProgram allocation, sub-Parse, codeTriggerProgram,
  aColmask[0/1] populated from sub-Parse oldmask/newmask).
  `sqlite3TriggerColmask` (`:30905`) now picks up real per-column bits
  for ordinary triggers (View/bReturning paths already correct).
  Stale "not yet ported" comments removed.  Build 87/87.

## Medium priority — degrades coverage but not parity

### 8. `code_outer_join_constraints` / `pLevel^.pRJ` — CLOSED (was real, task 6.28.9)
- Pascal: pRJ match-record block at
  `src/passqlite3codegen.pas:21092..21125`;
  code_outer_join_constraints walk at `:21150..21173`.
- C ref : `wherecode.c:2729..2768` (pRJ block),
  `wherecode.c:2800..2813` (code_outer_join_constraints walk).
  (Original inventory cite `where.c:1442..1521` was wrong; that range
  is the unrelated codeAllEqualityTerms helper.)
- Verdict: 6.28.9 audit found both arms are real 1:1 ports.  pRJ block
  handles HasRowid + WITHOUT-ROWID PK paths, OP_Found short-circuit,
  OP_MakeRecord + OP_IdxInsert + OP_FilterAdd with OPFLAG_USESEEKRESULT.
  code_outer_join_constraints walks pWC^.a[0..nBase-1] and emits
  residuals for outer-join terms left untouched by the main walk, with
  the JT_LTORJ short-circuit for RIGHT-JOIN-subroutine tables.  The
  BeginSubrtn / EndSubrtn driver is also coded at :21136..21148 (and
  symmetric tail in sqlite3WhereEnd).  Stale "pRJ is a stub" banner at
  codegen.pas:20975 scrubbed.

### 9. `sqlite3ExprNNCollSeq` — CLOSED (was real, task 6.28.9)
- Pascal: body at `src/passqlite3codegen.pas:29221..29230` (forward decl
  at `:2138`).  Original inventory cite to `:16274` pointed at a usage
  site inside wherePathMatchSubqueryOB, not the body.
- C ref : `expr.c:321..328` (NOT `:174..208`; original cite was wrong).
- Verdict: 6.28.9 audit found the body is a 1:1 port: calls
  sqlite3ExprCollSeq, falls back to `db^.pDfltColl` when no defined
  collation matches, AssertH non-nil contract.  This is the canonical
  non-null-collation lookup; the "returns nil → BINARY fallback" note
  in the original inventory was simply wrong.  Stale "Phase 6.6 stub"
  comment at codegen.pas:16424 (inside wherePathMatchSubqueryOB)
  scrubbed.

### 10. `sqlite3DefaultRowEst` — CLOSED (was real, task 6.28.9)
- Pascal: body at `src/passqlite3codegen.pas:36624..36655`.  Original
  inventory cite to `:23998..24020` pointed at the unrelated
  sqlite3SelectCheckOnClauses driver.
- C ref : `build.c:4551..4606`.
- Verdict: 6.28.9 audit found the body is a 1:1 port: nRowLogEst floor
  to 99, partial-index `-10` discount, aVal table seeding
  `(33,32,30,28,26)` for the first five key columns, LogEst(23) default
  for trailing columns.  Earlier "Phase 6.3 stub" / "szIdxRow floor"
  note was stale; the szIdxRow floor lives in decodeIntArray
  (codegen.pas:36697..36702) which is also fully ported.
- Prio  : —

### 11. `codeVectorCompare` fast path — CLOSED (was real, task 6.28.9)
- Pascal: body at `src/passqlite3codegen.pas:17360..17445`; dispatch in
  the TK_EQ/LT/LE/GT/GE/NE arm of sqlite3ExprCodeTarget at
  `:5537..5540`.
- C ref : `expr.c:697..784` (codeVectorCompare body),
  `expr.c:5174..5176` (dispatch).  (Original inventory cite to
  `expr.c:3210..3327` was wrong — that range is the unrelated
  sqlite3ExprForVectorField helper.)
- Verdict: 6.28.9 audit found both the body and the dispatch are real
  1:1 ports: nLeft/nRight mismatch error, opx normalisation for LE/GE/
  NE, exprCodeSubselect for both operands, OP_ZeroOrNull /
  SQLITE_NULLEQ branch, OP_ElseEq for LT/GT inner-loop, OP_NotNull
  short-circuit for TK_EQ, trailing OP_Not for TK_NE.  Earlier "fast
  path not yet ported / falls through to slow" note in the dispatch
  comment was stale and has been scrubbed.

### 12. `sqlite3HasExplicitNulls` of NULLS LAST sort — CLOSED (was real, task 6.28.9)
- Pascal: body at `src/passqlite3codegen.pas:36602..36622`.
- C ref : `select.c:5859` + `expr.c:1882` `(void)` cast site.
- Verdict: 6.28.9 audit confirmed body is a faithful 1:1 port — walks
  pList, raises "unsupported use of NULLS FIRST" / "NULLS LAST" error
  when explicit NULLS ordering is requested but the column has no
  matching index ordering, mirroring the C error string verbatim.  No
  action.

### 13. `sqlite3VdbeSorter*` family — CLOSED (PMA disk-spill landed, Phase 5.7.b; re-audited 2026-06-09)
- Pascal: `src/passqlite3vdbe.pas:6232..6551` (banner +
  Init / Reset / Close / Write / Rewind / Next / Rowkey / Compare
  bodies, plus vdbeSorterMergeSort / vdbeSorterCompareRec /
  vdbeSorterListToArray / vdbeSorterCountRecords helpers).
- C ref : `vdbesort.c` entire file.
- Verdict: 6.28.9 audit found the in-memory single-PMA path fully
  ported (stable mergesort, KeyInfo+UnpackedRecord packing with
  default_rc=0 fix from bug 6.13); at that time the
  PmaReader / MergeEngine disk-spill read-back was still unported.
  **2026-06-09 re-audit: CLOSED** — the disk-spill subsystem landed in
  Phase 5.7.b.6..b.9 (write side + MergeEngine/IncrMerger read-back)
  and `SORTER_PMA_ENABLED = True` since 5.7.b.9 (verified 5.7.b.10).
  The stale "GATED OFF =False" banner above the const was rewritten in
  the same re-audit.
- Prio  : none (closed).

## Low priority — debug, OMIT_*, or already-faithful no-ops

### 14. `sqlite3VdbeComment` / `sqlite3VdbeNoopComment` — INTENTIONAL (verified 6.28.10)
- Pascal: `src/passqlite3vdbe.pas:2939, 2943` (sqlite3VdbeNoopComment
  emits OP_Noop when the Vdbe is non-nil, matching the C macro form).
- C ref : `vdbeaux.c` — only bodied under SQLITE_ENABLE_EXPLAIN_COMMENTS.
- Verdict: 6.28.10 audit confirmed empty body is the faithful port for
  the !SQLITE_ENABLE_EXPLAIN_COMMENTS production build.  No port
  required.
- Prio  : low (intentional).

### 15. `sqlite3VdbeAssertAbortable` / `sqlite3VdbeNoJumpsOutsideSubrtn` / `VdbeVerifyNoMallocRequired` / `VdbeVerifyNoResultRow` — INTENTIONAL (verified 6.28.10)
- Pascal: `src/passqlite3vdbe.pas:3158, 3162, 3167, 3171`.
- C ref : `vdbeaux.c` — SQLITE_DEBUG-only.
- Verdict: 6.28.10 audit confirmed empty bodies are the faithful port
  for the !SQLITE_DEBUG production build.
- Prio  : low (intentional).

### 16. `sqlite3VdbeEnter` / `sqlite3VdbeLeave` — INTENTIONAL (verified 6.28.10)
- Pascal: `src/passqlite3vdbe.pas:3550, 3554` (with banner at :3545
  citing vdbeInt.h:714/720 empty-macro expansion).
- C ref : `vdbeaux.c:2066/2101` only bodied when
  !SQLITE_OMIT_SHARED_CACHE && SQLITE_THREADSAFE>0.
- Verdict: 6.28.10 audit confirmed empty bodies are the faithful port
  for the no-shared-cache / single-conn build.
- Prio  : low (intentional).

### 17. `sqlite3SchemaMutexHeld` — INTENTIONAL (verified 6.28.10)
- Pascal: `src/passqlite3vdbe.pas:12745` — `Result := 1` unconditional.
- C ref : `prepare.c` — guards SQLITE_DEBUG asserts under THREADSAFE.
- Verdict: 6.28.10 audit confirmed unconditional-1 is correct under the
  single-conn model (asserts that consume this always pass).
- Prio  : low (intentional).

### 18. `noopWindowValueFunc` / `noopWindowStepFunc` — INTENTIONAL (verified 6.28.10)
- Pascal: `src/passqlite3codegen.pas:52792, 52796` (cite shifted from
  `:52321/:52323`).
- C ref : `window.c:1234..1240`.
- Verdict: 6.28.10 audit confirmed these ARE no-ops in C too — they
  fill xValue / xInverse slots for ordinary aggregates promoted to
  window functions (first_value, nth_value etc.) where no work is
  required.  Faithful 1:1.
- Prio  : low (intentional).

### 19. `sqlite3VtabEponymousTableClear` banner notes — CLOSED (banner refresh, 6.28.10)
- Pascal: `src/passqlite3vtab.pas:39, 66` (banner notes refreshed);
  body at `:1335..1347` is the full port and mirrors `vtab.c:1298`.
- C ref : `vtab.c:1298`.
- Verdict: 6.28.10 audit confirmed body is a faithful 1:1 port (marks
  TF_Ephemeral, dispatches to sqlite3DeleteTable, clears
  pMod^.pEpoTab).  Banner notes at 39/66 calling it a "stub" / "still
  a no-op for now" scrubbed.
- Prio  : low (closed).

### 20. `invalidateAllOverflowCache` / `invalidateOverflowCache` — CLOSED (verified 6.28.10)
- Pascal: `src/passqlite3btree.pas:2022..2038`.
- C ref : `btree.c:565..575, 591..609`.
- Verdict: 6.28.10 audit confirmed both are faithful 1:1 ports — free
  pCur^.aOverflow, clear BTCF_ValidOvfl, walk pBt^.pCursor chain.  The
  original inventory pointed at a stale comment at btree.pas:6618, but
  that comment is actually about invalidateIncrblobCursors (a separate
  incrblob-cursor stub, tracked outside 6.28).  No action here.
- Prio  : low (closed).

### 21. `pas_openDirectory`
- Pascal: `src/passqlite3os.pas:2331` (BEFORE this commit) — was a no-op
  stub returning 0 with `*pFd = -1`, kept only as a non-nil marker for
  `aSyscall[]`.
- C ref : `os_unix.c:3874..3894`.
- Note  : **PORTED IN THIS COMMIT (6.28).**  Now mirrors the C arm:
  truncate to parent-directory path, FpOpen(O_RDONLY), report SQLITE_OK
  / SQLITE_CANTOPEN per C.  Selected as the "one small high-priority
  stub (<=50 lines C)" deliverable because:
    1. faithful 1:1 port from C, no foreign dependencies;
    2. exercised by `aSyscall[]` enumeration tests if/when the test
       harness invokes the slot directly;
    3. lays the groundwork for productive directory-fsync paths on
       SYNC_DATAONLY (currently inlined in unixDelete:2002).
- Prio  : high (small but unblocks aSyscall directory-fsync correctness).

## Shell / extension stubs (deliberate, tracked outside 6.28)

These live under `passqlite3shell.pas` and are listed for completeness
but are tracked by Phase 10.1.x bullets, not by 6.28.  They are
intentional gates on currently-unported subsystems (session, sqlar
write, edit/spreadsheet/web-browser pipe targets) — see tasklist 10.1.27,
10.1.47, 10.1.54.  Count: ~18 callsites.

### 22. Module banners noting deferred infrastructure (no behavioural impact)
- `src/passqlite3btree.pas:148` (opaque pointers); 391 (Phase 4.2);
  526 (VDBE stubs); 571 (mutex stubs); 729 (sharedCacheTableLock);
  3034 (ROWID-RHS arm); 3281 (vdbeCompareMemString transcoding); 3475
  (record-compare fallback); 3892 (auto-vacuum stubs); 7378, 7421, 7459
  (incrVacuumStep family — gated on ptrmap, explicitly excluded by
  task 6.28).
- `src/passqlite3vdbe.pas:34, 637, 1198, 1273, 1510, 1746, 1809, 2109,
  2200, 2231, 3037, 3138, 4318, 6021, 6232, 10205, 10209, 10253` —
  Phase-N transition banners; bodies underneath either fully ported or
  flagged in entries 13–17 above.
- `src/passqlite3codegen.pas:29, 31, 404, 405, 438, 452, 2176, 2329,
  2368, 3434, 3451, 3536, 3538, 4717, 7602, 11544, 11559, 11776, 12556,
  14022, 15695, 15863, 17394, 17545, 18528, 19367, 22706, 22769, 22779,
  22977, 23603, 24873, 25286, 26229, 26703, 26796, 26991, 27183, 27482,
  27975, 31057, 31145, 31164, 31201, 32243, 32965, 37841, 37846, 38937,
  44722, 45668, 47681, 47686, 55156` — banners, gated arms, and
  intentional no-ops captured above.

## Summary

| Priority   | Count | Status after audit                                            |
|------------|------:|---------------------------------------------------------------|
| high       |     7 | 6 CLOSED (was real), 1 DRIFTED-S (#4, landed in 6.28.4)       |
| med        |     6 | 5 CLOSED (was real, 6.28.9), 1 CLOSED (#13 PMA, Phase 5.7.b)  |
| low        |     8 | 7 INTENTIONAL/CLOSED (6.28.10), 1 closed in 6.28 (#21)        |
| (intentional / shell deferred) | ~18 | tracked outside 6.28                          |
| **total productive markers**   | ~256 raw / **0 actionable** (#4 landed 6.28.4, #13 landed 5.7.b) |

Audit summary (6.28.3 / 6.28.7 / 6.28.8 / 6.28.9 / 6.28.10): of the
original 21 productive markers, 18 turned out to be real ports under
stale marker comments, 1 is a small-S drift that already landed
(#4 sqlite3AddColumn, 6.28.4), 1 was ported in the 6.28 commit itself
(#21 pas_openDirectory), and 1 is a large XL deferral
(#13 sqlite3VdbeSorter PMA disk-spill).  Inventory line/file
references were wrong on the majority of entries — 6.28.9 alone
corrected 4 of 6 medium-priority cites (#8 where.c→wherecode.c,
#9 expr.c:174→expr.c:321, #10 codegen.pas:23998→:36624,
#11 expr.c:3210→expr.c:697).  Future agents have realistic per-entry
sizing rather than the fabricated "~600 lines / ~2400 lines" worst-
case estimates the original inventory used.

End of inventory.
