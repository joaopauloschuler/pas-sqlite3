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

### 8. `code_outer_join_constraints` / `pLevel^.pRJ`
- Pascal: `src/passqlite3codegen.pas:20768`.
- C ref : `where.c:1442..1521`.
- Note  : RIGHT JOIN / FULL OUTER JOIN reordering arm absent; matches
  upstream's `SQLITE_OMIT_RIGHT_JOIN` build but tasklist 6.x targets full
  RIGHT JOIN.
- Prio  : med (blocks any RIGHT JOIN row in TestExplainParity).

### 9. `sqlite3ExprNNCollSeq` Phase 6.6 stub
- Pascal: `src/passqlite3codegen.pas:16274`.
- C ref : `expr.c:174..208`.
- Note  : Returns nil → conservative BINARY collation fallback.
- Prio  : med (non-BINARY-collation corpora silently coerce to BINARY).
- Size  : ~40 lines C.

### 10. `sqlite3DefaultRowEst` Phase-6.3 stub fallback
- Pascal: `src/passqlite3codegen.pas:23998..24020`.
- C ref : `build.c:4551..4606`.
- Note  : Already largely ported per build.c surface; one rarely-touched
  arm (`pIdx->szIdxRow` floor) flagged in the banner as Phase 6.3-era.
- Prio  : med (planner cost-model accuracy on small indexes).

### 11. `codeVectorCompare` fast path
- Pascal: `src/passqlite3codegen.pas:5520`.
- C ref : `expr.c:3210..3327`.
- Note  : Vector `(a,b) = (?,?)` IN-compare falls through to the slow
  per-component path.  Correctness preserved.
- Prio  : med (perf).

### 12. `sqlite3HasExplicitNulls` of NULLS LAST sort
- Pascal: not flagged as stub but C `expr.c:1882` `(void)` cast wraps it
  — the Pascal version forces the error, mirroring C.  No action.

### 13. `sqlite3VdbeSorter*` family — Phase 5.7
- Pascal: `src/passqlite3vdbe.pas:6232..6500` (banner + bodies).
- C ref : `vdbesort.c` entire file.
- Note  : External sorter falls back to in-memory list; ORDER BY past
  ~16 MB silently truncates to RAM-only sort (no PMA spill).  Bug
  surface: only on DB files larger than `sqlite3GlobalConfig.szMmap`.
- Prio  : med-low.
- Size  : ~2400 lines C — DO NOT attempt as the "one small port".

## Low priority — debug, OMIT_*, or already-faithful no-ops

### 14. `sqlite3VdbeComment` / `sqlite3VdbeNoopComment`
- Pascal: `src/passqlite3vdbe.pas:2939, 2948`.
- C ref : SQLITE_DEBUG-only.
- Note  : Production builds in C are also no-ops.  No port required.
- Prio  : low (intentional).

### 15. `sqlite3VdbeAssertAbortable` / `VdbeVerifyNoMallocRequired` /
       `VdbeVerifyNoResultRow`
- Pascal: `src/passqlite3vdbe.pas:3158, 3167, 3171`.
- C ref : SQLITE_DEBUG-only.
- Prio  : low (intentional).

### 16. `sqlite3VdbeEnter` / `sqlite3VdbeLeave`
- Pascal: `src/passqlite3vdbe.pas:3550, 3554`.
- C ref : SQLITE_THREADSAFE-only.  Single-conn port intentionally inert.
- Prio  : low (intentional).

### 17. `sqlite3SchemaMutexHeld`
- Pascal: `src/passqlite3vdbe.pas:12745`.
- C ref : `prepare.c`.
- Note  : Returns 1 unconditionally — correct under single-conn model.
- Prio  : low (intentional).

### 18. `noopWindowValueFunc` / `noopWindowStepFunc`
- Pascal: `src/passqlite3codegen.pas:52321, 52323`.
- C ref : `window.c:1234..1240`.
- Note  : These ARE no-ops in C too.
- Prio  : low (intentional).

### 19. `sqlite3VtabEponymousTableClear` banner notes
- Pascal: `src/passqlite3vtab.pas:39, 66`.
- C ref : `vtab.c:1298`.
- Note  : The function body at vtab.pas:1335 is the **full port** (mirrors
  C exactly).  The banner comments at 39 and 66 are stale and call the
  function a "stub" — purely a comment refresh, no behaviour change.
- Prio  : low (banner refresh only).

### 20. `invalidateAllOverflowCache` / `invalidateOverflowCache`
- Pascal: `src/passqlite3btree.pas:2019..2042`.
- C ref : `btree.c:565..575, 591..609`.
- Note  : Already fully ported; comment at btree.pas:6618 calling the
  call site a "no-op stub" is stale.
- Prio  : low (banner refresh).

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

| Priority   | Count |
|------------|------:|
| high       |     7 (6 CLOSED after 6.28.3/6.28.7/6.28.8 audits; 1 DRIFTED-S) |
| med        |     6 |
| low        |     8 |
| (intentional / shell deferred) | ~18 |
| **total productive markers**   | ~256 raw / ~21 actionable |

Audit summary (6.28.3 / 6.28.7 / 6.28.8): of the original seven
"high-priority stubs", six turned out to be real ports under stale
marker comments (#1, #2, #3, #5, #6, #7), and #4 is a small-S drift
(three minor arms missing).  Only `pas_openDirectory` (entry 21) was
ported in the 6.28 commit itself; the audit replaced "size ~600 lines
C, large port" estimates with actual line-by-line verdicts.

End of inventory.
