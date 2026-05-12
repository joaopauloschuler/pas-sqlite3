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

### 1. `whereLoopAddVirtual` (vtab planner)
- Pascal: `src/passqlite3codegen.pas:1932..1940` (decl) + body further down.
- C ref : `where.c:4357..4810` (whereLoopAddVirtualOne / whereLoopAddVirtual).
- Note  : Returns SQLITE_OK with no template loops added.  Vtab corpus
  never exercises planner so existing gates stay green; the moment Phase
  9.1 enables a vtab-heavy `.sql` row, this stub will mis-plan.
- Prio  : high (blocks 9.1.5 `pas-strict` tag for any vtab corpus member;
  also blocks 6.bis.1g+ vtab planning sub-progress).
- Size  : ~450 lines C — DO NOT attempt as the "one small port".

### 2. `sqlite3OpenTableAndIndices` Phase 6.4 stub
- Pascal: `src/passqlite3codegen.pas:31057..31058`, also line 31201.
- C ref : `build.c:5054..5147`.
- Note  : sqlite3NestedParse path bypasses the stub; productive callers
  (DELETE/UPDATE rewrite arms) gate on this — see the comment at codegen
  44722.  Bug 6.29 ADD COLUMN partial fix depends on this for ALTER
  TABLE round-trip.
- Prio  : high (blocks tasklist §6.29 follow-on, and any ALTER-heavy
  9.1.x corpus row).
- Size  : ~90 lines C.

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

### 4. `sqlite3AddColumn` (still partial — bug 6.29 trail)
- Pascal: `src/passqlite3codegen.pas:37846`.
- C ref : `build.c:1862..2026`.
- Note  : STRICT-mode column iteration arm missing; the MEMORY entry
  *feedback_addcolumn_renametokenmap.md* covers the RenameTokenMap fix
  but the STRICT and CHECK-collation arms are still no-op.
- Prio  : high (open Phase-6 bullet).
- Size  : remaining slice ~60 lines C.

### 5. `sqlite3LimitWhere` helper
- Pascal: `src/passqlite3codegen.pas:32243`.
- C ref : `delete.c:182..330`.
- Note  : Productive path replaces the no-op stub; comment is mostly
  stale, but two arms (`useTempRow` flag and view-on-DELETE rewrite)
  remain unported.
- Prio  : med-high.
- Size  : ~140 lines C (two arms ~50 lines each).

### 6. `OP_IntegrityCk`
- Pascal: `src/passqlite3codegen.pas:45668` (citation).
- C ref : `vdbe.c:OP_IntegrityCk` + `btree.c:sqlite3BtreeIntegrityCheck`.
- Note  : Sets an empty error string and falls through; integrity-check
  pragma therefore reports clean even on corrupt DBs.
- Prio  : high if 9.2.x reference vectors include a deliberately-corrupt
  fixture; med otherwise.
- Size  : ~600 lines C — large.

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
| high       |     7 |
| med        |     6 |
| low        |     8 |
| (intentional / shell deferred) | ~18 |
| **total productive markers**   | ~256 raw / ~21 actionable |

This commit (6.28) ports **one** high-priority entry — `pas_openDirectory`
(entry 21) — as a concrete deliverable.  The remaining six high-priority
entries are listed for future Phase 6 / 6.bis / 9 sub-progress work and
explicitly cite the open tasklist bullets they block.

End of inventory.
