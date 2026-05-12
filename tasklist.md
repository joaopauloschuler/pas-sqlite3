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

* `bin/TestExplainParity` — the **bytecode** gate.  **1026/1026** SQL
  statements emit byte-identical VDBE vs C as of 2026-05-06 (a3).
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

> TestExplainParity reports **1026 / 1026 PASS** as of 2026-05-06 (a3).

- [X] **6.8.0..6.8.6** Pragma vtab register, GenerateConstraintChecks, CompleteInsertion, WhereBegin, WhereEnd, Insert (incl. multi-row VALUES coroutine arm).
- [X] **6.8.1** sqlite3Update — single-table, UPDATE FROM, vtab dispatch, RETURNING all DONE.
- [X] **6.9** sqlite3VdbeRecordCompare / FindCompare full bodies in btree.pas.
- [X] **6.24** Aggregate-with-ORDER-BY codegen.
- [~] **6.26** Window functions (window.c). DiagWindow: 0 divergences. All window paths PASS including multi-window arm. Defensive: no known gaps; reopen if DiagWindow regresses.
- [X] **6.27** schema-mutation + statistics. Analyze, Vacuum, RunVacuum, FkCheck/FkActions all ported.
- [ ] **6.28** sweep — re-search for "stub" in the pascal source code and port from C to pascal in full any function or procedure still marked as "stub" that was missed (catch-all). OP_Vacuum, BtreeIncrVacuum done; incrVacuumStep / relocatePage / modifyPagePointer not ported (gated on productive ptrmap).

### Open Bugs

- [X] **6.13** `pragma_foreign_key_list(s.name)` (and other table-valued PRAGMA functions). **Sub-bug A** (column-list emission) closed 2026-05-08. **Sub-bug B** (lateral join with hidden-arg pushdown) closed 2026-05-11 via B.1..B.9: `whereLoopAddVirtual` + Case-1 codegen + WhereBegin OP_VOpen now push the lateral arg through xBestIndex/xFilter; TABFUNC arg lists are resolved before fitTabFuncArgs; `f.[table]` identifier syntax now dequotes.  `SELECT s.name, f.* FROM sqlite_schema s, pragma_foreign_key_list(s.name) f` returns the canonical row, and `bin/TestVtabLateral` is byte-identical with upstream across generate_series / pragma_foreign_key_list / json_each.  B.10 closed 2026-05-11: multi-source GROUP BY arm now drives the full pSrc through sqlite3WhereBegin / lateral pushdown.  **Sub-bug C** (sorter tie-stability for multi-row aggregates) closed 2026-05-11: `vdbeSorterCompareRec` left `UnpackedRecord.default_rc` uninitialized (`sqlite3VdbeAllocUnpackedRecord` uses `DbMallocRaw`) and `vdbeSorterListToArray` walked the LIFO insertion list head→tail.  For records whose key fields all tied, the merge sort kept reverse-insertion order — heap-layout-dependent and visible to any GROUP BY aggregate over a multi-row pragma vtab (e.g. multi-column `pragma_foreign_key_list`).  Fix: zero `default_rc` per compare and have `ListToArray` fill the array back-to-front so the stable merge preserves insertion order.  Gate: `bin/TestShellSchema` now exercises a multi-column-FK `.lint fkey-indexes` script that was previously emitting columns in reversed seq order.

- [X] **6.16** Multi-vtab LEFT-JOIN + multi-aggregate AV — closed
      2026-05-11.  Root cause was *not* in updateAccumulatorSimple
      or the LEFT-JOIN/aggregate codegen.  It was a Vdbe init bug in
      `sqlite3VdbeMakeReady` (passqlite3vdbe.pas:3663): the C oracle
      `vdbeaux.c:2731-2742` unconditionally assigns `p->nCursor =
      nCursor` (and `p->nMem`, `p->apCsr`) on the success branch,
      including when `nCursor==0`.  The Pascal port had wrapped the
      `nCursor`/`apCsr` write inside `if nCursor > 0`, so a zero-
      cursor sub-statement (the `PRAGMA table_info='parent'`
      prepared lazily by `pragmaVtabFilter`) inherited stale
      `nCursor=3` / `apCsr=2` left in the raw-malloc'd Vdbe by a
      previously freed Vdbe at the same address.  Halt-time
      `closeAllCursors` then looped over `0..stale-1` and AVed at
      `pC := v^.apCsr[i]` (`passqlite3vdbe.pas:4250`).  Fix:
      restructure MakeReady to set `p^.nCursor`, `p^.apCsr`,
      `p^.nMem`, `p^.aMem` on every path (zero-init when the
      corresponding count is 0).  `.lint fkey-indexes` /
      `.archive` / `.recover` now run byte-identical with upstream
      sqlite3 against `/tmp/lint.db`.  Phase 10.1.20 / 10.1.46 /
      10.1.48 unblocked.

- [X] **6.17** OR-decomposed Case-5 codegen + LIKE/GLOB range-bound
      prefix truncation — opened and closed 2026-05-11.  Both sub-bugs
      fixed; full regression (5020 assertions) and C-oracle parity on
      the minimal repros verified.

    - [X] **6.17.A** OR-decomposed Case-5 codegen references an
          un-opened table cursor.  Minimal repro outside .archive:
          `CREATE TABLE t(name TEXT PRIMARY KEY);
           INSERT INTO t VALUES('a/b'),('c');
           SELECT name FROM t WHERE name='c' OR name>'a';`
          → EAccessViolation at `OP_Column` reading `pCol^.nField`
          on a nil cursor (passqlite3vdbe.pas:8180).  EXPLAIN shows
          two index searches joined via OP_RowSetTest + Gosub to a
          subroutine that emits `Column|1` after OpenRead only
          allocates cursors 0,2,3.  C oracle on same schema/query
          picks a single full-scan plan instead; ours takes the
          OR-decomposition path but emits a Case-5 body that uses
          the wrong cursor index.  Suspect: the index→table cursor
          rewrite at codegen.pas:19422 (`WHERE_MULTI_OR` arm using
          `pLevel^.u.pCoveringIdx`) does not run / runs with nil.
          Root cause was actually in `sqlite3WhereBegin`'s cursor-
          open block (codegen.pas:18640): the WHERE_INDEXED branch
          always allocated a fresh cursor via `pParse^.nTab++` even
          when invoked under `WHERE_OR_SUBCLAUSE` with a positive
          `iAuxArg`.  C `where.c:7343..7345` reuses iAuxArg as
          `iIndexCur` and emits `OP_ReopenIdx` so every disjunct
          shares one covering-index cursor.  Fix: honour the
          WHERE_OR_SUBCLAUSE+iAuxArg branch.  C oracle parity
          verified on `SELECT name FROM t WHERE name='c' OR
          name>'a';` — Pascal now emits ReopenIdx 1 / SeekGE 1 /
          DeferredSeek 1 just like C, and the Column at the body
          tail (`Column 1 0 6`) reads from the now-opened cursor.

    - [X] **6.17.B** LIKE/GLOB range-bound prefix truncation never
          reaches `OP_String8`.  Root cause: Pascal
          `sqlite3IsLikeFunction` hard-coded the LIKE wildcards
          (`%`/`_`/`\\`) for both LIKE and GLOB; the builtin func
          registrations also left `pUserData` nil instead of pointing
          at globInfo/likeInfoNorm.  `isLikeOrGlob` therefore never
          recognised `*` as a wildcard in a GLOB pattern → `cnt`
          walked past the end of the string, `c` ended at NUL, and the
          truncation `zNew[cnt] := #0` wrote one past the buffer
          tail (no effective truncation).  Fix in codegen.pas: hoist
          `TCompareInfo` / `globInfo` / `likeInfoNorm` ahead of
          `InitBuiltinFuncs`, stamp `aBuiltinFuncs[36..38].pUserData`
          with the right compareInfo, and read `pUserData` in
          `sqlite3IsLikeFunction` (falling back to LIKE defaults when
          nil).  C oracle parity verified on `SELECT name FROM sqlar
          WHERE name GLOB 'src/dir1/*'` — String8 now emits
          `'src/dir1/'`/`'src/dir10'` and the residual `glob()`
          Function call disappears (isComplete now correctly true).  Minimal repro:
          `SELECT name FROM sqlar WHERE name GLOB 'src/dir1/*'`
          on an archive that contains `src/dir1/b.txt` returns
          zero rows from our shell but the expected row from C.
          EXPLAIN shows `String8 'src/dir1/*'` / `String8
          'src/dir1/+'` as the SeekGE / IdxGE keys — both still
          carry the trailing `*`, where C emits the truncated
          prefix `'src/dir1/'` / `'src/dir10'` (last byte of
          the prefix incremented).  `isLikeOrGlob` does write the
          null terminator (`zNew[cnt] := #0` at
          codegen.pas:11021) and the iFrom/iTo dequote loop ends
          with `zNew[iTo] := #0`, but the OP_String8 emission
          still picks up the original 10-byte token.  Suspect:
          either sqlite3ExprDup at codegen.pas:12223 is copying
          the raw allocation rather than respecting the new
          strlen, or the caller wraps pStr1 in a TK_GE term that
          re-reads the original RHS pattern instead of pStr1.
          Both branches (lower bound from pStr1 and upper from
          pStr2) emit the un-truncated string, so the dup is the
          most likely culprit.

    Subtasks (each lands independently; gate names are proposed):

    - [X] **6.13.B.1** Scout pass — `TWhereLoopVtab` (codegen.pas:1336)
          already carries `idxNum / bFlags(needFree+bOmitOffset+
          bIdxNumHex) / isOrdered / omitMask / idxStr / mHandleIn`;
          `TWhereLevel.p1/p2/regFilter/op` (codegen.pas:1375) carry
          the vtab loop plumbing; `Tsqlite3_index_info` and the
          constraint/orderby/usage trio are complete in
          passqlite3vtab.pas:122..142.  Only the `HiddenIndexInfo`
          trailing record is missing — covered by B.2.  No struct
          surgery needed before B.2.
    - [X] **6.13.B.2** Port `HiddenIndexInfo` trailing record
          (where.c:31..47) — `THiddenIndexInfo` declared at
          codegen.pas:1446, `SZ_HIDDENINDEXINFO` and
          `HiddenIndexInfoRhs` accessors implemented at
          codegen.pas:3306..3319.  Owns `pWC / pParse / eDistinct /
          mIn / mHandleIn` + trailing `aRhs[]` of `Psqlite3_value`.
          codegen.pas builds clean.
    - [X] **6.13.B.3** Port `allocateIndexInfo` (where.c:1413..1626)
          landed at codegen.pas:14882.  Walks the WhereClause +
          pOuter chain marking TERM_OK terms, allocates the
          contiguous `sqlite3_index_info` + HiddenIndexInfo block,
          fills `aConstraint[] / aOrderBy[] / colUsed / eDistinct /
          mIn` plus the vector LT/GT→LE/GE relax + `mNoOmit` mask.
          Case-collision rename: pParse→pPrs, pExpr→pE, p→pWcCur.
          Clean compile.
    - [X] **6.13.B.4** `freeIdxStr` + `freeIndexInfo` ported at
          codegen.pas:15120 / 15131.  Releases `needToFreeIdxStr` +
          all aRhs[] sqlite3_value slots before sqlite3DbFree-ing the
          contiguous block.
    - [X] **6.13.B.5** `vtabBestIndex` ported at codegen.pas:15166.
          Single xBestIndex dispatch with SQLITE_CONSTRAINT→no-plan,
          SQLITE_NOMEM→sqlite3OomFault, other-rc→sqlite3ErrorMsg
          (falling back to sqlite3ErrStr when zErrMsg is nil).
          Honours bAllSchemas, releases pVTab^.zErrMsg.  Clean compile.
    - [X] **6.13.B.6** `whereLoopAddVirtualOne` ported at
          codegen.pas:15291 (plus `termFromWhereClause`,
          `isLimitTerm`, `allConstraintsUsed` helpers).  Marks the
          usable subset, calls vtabBestIndex, unmarshals
          aConstraintUsage[] into pNew (aLTerm + prereq + omitMask +
          mHandleIn + cost), wires bFlags packing (needFree=bit0,
          bOmitOffset=bit1, bIdxNumHex=bit2), and commits via
          whereLoopInsert.  SQLITE_CONSTRAINT → SQLITE_OK no-insert;
          LIMIT-vs-IN conflict → *pbRetryLimit signal.  Clean compile.
    - [X] **6.13.B.7** `whereLoopAddVirtual` four-pass driver ported
          at codegen.pas:15461 (replaces the stub).  Pass 1 all-usable
          + LIMIT/OFFSET retry; pass 2 WO_IN excluded; pass 3 distinct-
          prereq walk with mUsable = mPrereq | mNext; pass 4 zero-
          prereq / zero-prereq+noIN fallbacks.  Honours mUnusable via
          allocateIndexInfo, sizes pNew via whereLoopResize, releases
          pIdxInfo via freeIndexInfo on exit.  Existing dispatch sites
          (whereLoopAddOr / whereLoopAddAll vtab arms) need no edits.
          Clean compile.
    - [X] **6.13.B.8** Codegen — Case 1 vtab arm in
          `sqlite3WhereCodeOneLoopStart` at codegen.pas:19720..19815
          (OP_VOpen prelude in WhereBegin at codegen.pas:18558).
          Emits OP_VFilter against the chosen WhereLoop's
          `idxNum / idxStr / argvIndex` map with full IN-loop
          plumbing (VInitIn / mHandleIn / per-row residual EQ
          replay).  Also lifted the `TABTYP_VTAB` trivial-gate bail
          at codegen.pas:27590 and added `ResolveTabFuncArgs`
          (codegen.pas:9050) so lateral args resolve before
          fitTabFuncArgs.  Drive-by: parser now passes `dequote=1`
          on all 7 TK_ID Expr allocs so `f.[table]` /
          `s."from"` identifier syntax lowers to the underlying
          name.
    - [X] **6.13.B.9** Gate — `bin/TestVtabLateral` (5/5 PASS)
          covers generate_series standalone + WHERE residual +
          lateral, pragma_foreign_key_list lateral, and
          json_each lateral on a JSON column.  fsdir / wholenumber
          / completion left for a future gate (need extension load
          plumbing or vtab modules not registered by default).
    - [X] **6.13.B.10** Multi-source GROUP BY arm extended at
          codegen.pas:25437 — single-source `pSrc^.nSrc = 1` gate
          lifted to `>= 1`.  For multi-source the per-item walk
          rejects subquery / VIEW / TF_Ephemeral sources (those
          still need the coroutine/eph-materialise plumbing from
          the single-source path) and accepts vtab sources, which
          flow through `sqlite3WhereBegin` /
          `whereLoopAddVirtual` with lateral-arg pushdown already
          in place from 6.13.B.7/B.8.  Schema-verify iterates the
          full pSrc instead of just `pSrc->a[0]`.  Sponsor query
          `SELECT a.x, count(*) FROM a, b GROUP BY a.x` now
          matches upstream; `SELECT s.name, f.id, f.[from] FROM
          sqlite_schema, pragma_foreign_key_list(s.name) AS f
          GROUP BY s.name, f.id` (the vtab-lateral shape behind
          `.lint fkey-indexes`) lowers and runs.
          `.lint fkey-indexes` / `.archive` / `.recover` still
          fail on a **separate pre-existing bug** (multi-vtab
          LEFT-JOIN with two aggregates whose arg columns span
          both inner vtabs trips a register-allocation issue in
          updateAccumulatorSimple — repros without GROUP BY too,
          via `SELECT f.[from], p.[name] FROM sqlite_schema AS s,
          pragma_foreign_key_list(s.name) AS f LEFT JOIN
          pragma_table_info AS p ON (pk-1=seq AND
          p.arg=f.[table])` when s.name is omitted from the
          SELECT list).  Track that under a new bug; it is not on
          the GROUP BY path.

    - [X] **6.13.B.11** Eponymous-vtab fast arm in sqlite3Select was
          firing for every single-source vtab SELECT, bypassing
          sqlite3WhereBegin → whereLoopAddVirtual.  Restricted the arm
          to the bare "SELECT ... FROM <vtab>" shape (no
          pWhere/pOrderBy/pGroupBy/pHaving/pLimit); everything else now
          falls through to the productive planner and drives
          vtabBestIndex.  `.expert` produces the expected
          `CREATE INDEX t1_idx_033e95fe ON t1(a, b, c)` plus the
          `SEARCH t1 USING INDEX ...` plan, byte-identical with
          upstream.  (The eTabType-after-reload hypothesis in the
          original entry was a red herring — eTabType is correctly
          TABTYP_VTAB at hash-insert time.)

          Repro (smallest):

              sqlite3 :memory:
              .load <module>          -- or built-in 'expert' via .expert
              CREATE VIRTUAL TABLE t USING expert('CREATE TABLE x(a,b)');
              -- WhereBegin sees eTabType=0 here:
              EXPLAIN QUERY PLAN SELECT * FROM t WHERE a=1;

          Symptom: the planner takes the btree branch at
          `whereLoopAddAll` (codegen.pas:15841) and **never calls
          `vtabBestIndex`** (codegen.pas:15217), so any module that
          relies on xBestIndex pushdown to translate WHERE / ORDER
          BY clauses (expert, fts, rtree, dbpage, ...) silently
          degrades to "scan everything in xFilter".

          Surfaced by **10.1.101** (passqlite3expert.pas): `.expert`
          runs the full pipeline (sql → analyze → report) but
          `pScan` is always empty, so the report is locked at
          `(no new indexes)`.  Stderr instrumentation in
          `sqlite3WhereBegin` confirms eTabType=0 for the
          re-published vtab even though `sqlite3VtabBeginParse`
          (parser.pas:2403) writes `TABTYP_VTAB` unconditionally.

          Suspect chain (verify in order):

            1. After `CREATE VIRTUAL TABLE`, `sqlite3VtabFinishCreateOps`
               (codegen.pas:56697) emits UPDATE sqlite_schema +
               OP_Expire + OP_ParseSchema + OP_VCreate.
            2. `OP_ParseSchema` → `vdbeParseSchemaExec` →
               `execParseSchemaImpl` (main.pas:2707) iterates every
               row and dispatches to `sqlite3InitCallback`
               (main.pas:2570).
            3. The "already in tblHash" shortcut at main.pas:2633..2642
               may fire on the freshly inserted (init.busy=0) pTab
               that still has `TABTYP_VTAB`, **or** the re-prepare
               at main.pas:2659 may parse the sql column as a plain
               CREATE TABLE (parser dispatch wired at
               parser.pas:4114 for rule 304 — confirm yymsp slot
               indices when init.busy=1).
            4. `sqlite3VtabFinishParse` init.busy branch
               (parser.pas:2458..2475) hashes the pTab into
               tblHash; assert pTab^.eTabType is still
               `TABTYP_VTAB` at that point.

          Acceptance: with this closed, the existing
          passqlite3expert.pas unit produces a non-empty zCandidates
          buffer for

              CREATE TABLE t1(a,b,c,d);
              .expert
              SELECT * FROM t1 WHERE a=1 AND b=2 ORDER BY c;

          and the resulting CREATE INDEX statement is byte-identical
          with upstream sqlite3's output.  No code change required
          inside passqlite3expert.pas; flip the "Known limitation"
          paragraph at the top of that unit to "(closed by 6.13.B.11)".

- [X] **6.18** pcachetrace / memtrace trampoline AV when sink is non-nil.
      Closed 2026-05-11: SQLITE_CONFIG_GETPCACHE2 / GETMALLOC arms in
      `sqlite3_config` (passqlite3util.pas) now call SetDefault when
      `xInit`/`xMalloc == 0` before copying the methods record out, matching
      C `main.c:503..511` / `:564..574`.  Without the guard the trampoline
      was installed over an all-zero base, so the first wrapped call
      dereferenced a nil function pointer.  pcache hook is wired via a new
      `gPCacheSetDefaultHook` published from passqlite3pcache.initialization
      (avoids a circular `uses`); GETMALLOC arm calls the local
      `sqlite3MemSetDefault` directly.  Repro
      `bin/passqlite3 -pcachetrace ":memory:" "SELECT 1;"` now streams
      PCACHETRACE lines without crashing.  Note: `-memtrace` no longer
      crashes but produces no output because `sqlite3Malloc` bypasses the
      configured `sqlite3GlobalConfig.m.x*` vtable — a separate porting
      gap, not part of 6.18.

- [X] **6.19** `.open --deserialize` now works (repro prints `42`).  Root
      cause: `sqlite3AppendvfsInit` (passqlite3appendvfs.pas) did
      `FillChar(apnd_vfs, 0)` + per-field reinit on *every* call.  When
      apnd_vfs was already linked in the VFS list, FillChar zeroed its
      `pNext` field BEFORE vfs_register's vfsUnlink walked the chain,
      severing the list after apnd_vfs and dropping every subsequent
      VFS — notably `memdb`.  attachFunc's reopen-as-memdb arm then
      could not `sqlite3_vfs_find("memdb")` and aborted; OP_VTab returned
      SQLITE_ERROR, deserialize bubbled it out.  Fix: gate the one-time
      vtable init behind a `gApndvfsInitialised` Boolean so subsequent
      calls only re-stamp iVersion / szOsFile / pAppData (matching C's
      static struct-literal apnd_vfs in appendvfs.c:177).

- [X] **6.20** Shim-VFS re-init chain corruption — latent twin of 6.19.
      `sqlite3AppendvfsInit` had `FillChar(apnd_vfs, 0)` + per-field
      stamping on every call, which zeroes `pNext` while the VFS is
      already linked and severs the list.  6.19 fixed `apnd_vfs`; the
      same pattern still ships in four sibling shims and will corrupt
      the VFS chain if any of their init functions is invoked a second
      time while already registered:
      - `cksm_vfs` — passqlite3cksumvfs.pas:687
      - `vstat_vfs` — passqlite3vfsstat.pas:714
      - `tmstmp_vfs` — passqlite3tmstmpvfs.pas:776
      - `vlog_vfs` — passqlite3vfslog.pas:848
      None surface in the current regression suite (each shim only
      registers once today).  Repro path is the same shape as 6.19:
      anything that re-invokes one of these initialisers after the VFS
      is in the chain (e.g. an extension `.load` that re-runs the
      activator) would drop every VFS after it.  Fix per shim: copy
      6.19's `gApndvfsInitialised` Boolean guard so the FillChar +
      per-field stamping runs exactly once, mirroring C's
      static-struct-literal idiom.
      Closure: audit showed three of the four shims (`cksm_vfs`,
      `vstat_vfs`, `vlog_vfs`) already carried equivalent boolean/cint
      guards (`cksmInitialised`, `vstatInitialised`, `vlogInitialised`)
      inside their `cksmInitMethodsTables` / `ensureMethodTablesPopulated`
      helpers — only `tmstmp_vfs` still re-ran the FillChar + per-field
      stamp on every call.  Added `gTmstmpvfsInitialised` module-private
      Boolean (default False) in passqlite3tmstmpvfs.pas with an early
      `if gTmstmpvfsInitialised then Exit` at the top of
      `ensureMethodTablesPopulated` and a `gTmstmpvfsInitialised := True`
      at the tail, mirroring the 6.19 appendvfs pattern verbatim.  Build
      green (79/79 binaries, 5020/5020 assertions).

- [X] **6.21** `-memtrace` is silent — `sqlite3Malloc`
      (passqlite3util.pas:2417) calls `sqlite3_malloc` directly instead
      of dispatching through `sqlite3GlobalConfig.m.xMalloc`, so the
      memtrace trampoline installed via SQLITE_CONFIG_MALLOC is never
      reached.  6.18 made the trampoline plumbing safe (no more AV) but
      no MEMTRACE lines are emitted.  C oracle: `sqlite3Malloc` in
      `../sqlite3/src/malloc.c` routes every allocation through
      `mem0.alloc(nByte)` / the installed `xMalloc` slot.  The Pascal
      port short-circuits to its own allocator regardless of what
      SQLITE_CONFIG_MALLOC installed.  Fix: route allocations through
      the methods table.  Same routing gap likely affects `sqlite3_free`
      / `sqlite3Realloc` / size accounting — audit while there.
      Closure (2026-05-11): root cause was deeper than the task title
      suggests — `sqlite3_malloc` / `sqlite3_malloc64` / `sqlite3_free`
      / `sqlite3_realloc` / `sqlite3_realloc64` in `passqlite3os.pas`
      were declared as raw `external 'c' name 'malloc'` / `'free'` /
      `'realloc'` bindings, so every internal Pascal call site went
      straight to libc.  `sqlite3Malloc` then re-called `sqlite3_malloc`,
      meaning the methods-table `xMalloc` slot was wired but no
      Pascal allocation site ever consulted it.  Fix:
      (a) renamed the libc bindings in passqlite3os.pas:74..79 to
          `libc_malloc` / `libc_malloc64` / `libc_realloc` /
          `libc_realloc64` / `libc_free`;
      (b) added Pascal implementations of `sqlite3_malloc` /
          `sqlite3_malloc64` / `sqlite3_realloc` / `sqlite3_realloc64`
          / `sqlite3_free` in passqlite3os.pas implementation
          (cdecl, mirroring malloc.c:316/322/391/562/569), each
          dispatching through `sqlite3GlobalConfig.m.xMalloc` /
          `xFree` / `xRealloc`;
      (c) rewrote `sqlite3Malloc` (passqlite3util.pas:2417) and added
          `sqlite3Realloc` to mirror malloc.c:296/503 — xRoundup +
          xMalloc/xRealloc + xSize accounting under bMemstat, with
          gMallocMutex serialisation;
      (d) routed `sqlite3MallocSize` through `xSize` per malloc.c:344
          (still falls back to `malloc_usable_size` if no allocator
          installed yet, for very early init);
      (e) rebased the `mem1_xMalloc` / `mem1_xFree` / `mem1_xRealloc`
          / `mem1_xSize` backends on direct `libc_*` calls so the
          default leaf of the SQLITE_CONFIG_MALLOC chain no longer
          recurses through the dispatch.
      Build green (79/79 binaries, 5020/5020 assertions).  Memtrace
      smoke test: `LD_LIBRARY_PATH=src/ bin/passqlite3 -memtrace -
      ':memory:' 'select 42;'` now emits 383 MEMTRACE lines on
      stderr while `42` still prints on stdout (note: Pascal shell
      currently treats `-memtrace` as a one-arg option per its
      grouped option-parser arm — upstream C takes no arg; that's a
      separate pre-existing divergence outside 6.21's scope).

- [X] **6.22** Safe-mode error-prefix gap — `data.zErrPrefix = zErrCtx`
      plumbing not ported.  When a dot-command is supplied via argv
      (e.g. `bin/passqlite3 -safe ":memory:" ".import |echo 1 t"`),
      upstream prints `argv[N]: cannot run .import in safe mode` because
      shell.c.in:13544 sets `data.zErrPrefix = zErrCtx` before
      dispatching the argv-sourced command.  The Pascal port emits the
      stdin-style `line N:` / `<file>:N:` prefix even for argv input.
      Error-message text itself is byte-identical; only the location
      prefix diverges.  Surfaced 2026-05-11 during 10.1.24.b
      verification.  Fix: port the argv-prefix swap in
      `process_command_line` / `main` (locate by grepping
      `zErrPrefix` in shell.c.in) and mirror it in the Pascal
      `processCommandLine` arg dispatcher.
      Closure (2026-05-11): ported the argv-prefix swap to
      `passqlite3shell.pas` positional dispatch loop (around line
      10247).  Before each argv-sourced dot-command, we now set
      `state.zInFile := '<cmdline>'` and `state.zErrPrefix :=
      'argv[N]:'` (N = `positional[k].iArg`), restoring to nil
      after `doMetaCommand` returns — mirroring shell.c.in:
      13539..13547.  Backing string `gErrPrefixBacking` declared
      alongside `gNonceBacking`.  `failIfSafeMode`'s inline
      shellErrorLocation arm at the .import entry (8133..8142)
      already honored `p^.zErrPrefix` when non-nil, so no further
      reader changes were required.  Smoke
      `LD_LIBRARY_PATH=src/ bin/passqlite3 -safe ":memory:"
      ".import |echo 1 t" 2>&1` now emits `argv[3]: cannot run
      .import in safe mode`, byte-identical to upstream.
      Regression: 5020/5020 assertions.

- [X] **6.23** `sqlite3_open_v2` doesn't honor `file:` URI filenames.
      Surfaced 2026-05-11 during 10.1.27.d verification: with the new
      URI-aware `--new` deletion working, `.open --new
      'file:/tmp/newdb?mode=rwc'` correctly unlinks the target, but the
      subsequent `openDb` fails with `unable to open database file`
      because the Pascal `sqlite3_open_v2` doesn't peel URIs.  Same
      failure when passing a `file:` URI as the top-level filename on
      the command line.  C oracle: `sqlite3_open_v2` in
      `../sqlite3/src/main.c` (search for `SQLITE_OPEN_URI` and
      `sqlite3ParseUri`).  Fix: port `sqlite3ParseUri` (if missing) and
      wire it into the open path so URI filenames, query parameters
      (`mode=`, `cache=`, `nolock=`, `psow=`, `immutable=`, `vfs=`), and
      flag interactions match upstream.  Likely also unblocks other
      URI-dependent gates.
      Closure (2026-05-11): the existing `sqlite3ParseUri` port at
      passqlite3util.pas:3134 was orphaned — `openDatabase`
      (passqlite3main.pas:735) ran its own inline `sqlite3_vfs_find` +
      `':memory:'` default and forwarded the raw `zFilename` straight
      to `sqlite3BtreeOpen`, so `file:` prefixes were never peeled.
      Fix: (a) wire `sqlite3ParseUri(zVfs, zFilename, &uFlags, &db->pVfs,
      &zOpen, &zErrMsg)` into `openDatabase` at the main.c:3560 spot,
      replacing the inline VFS lookup; pass the parsed `zOpen` (not the
      raw `zFilename`) to `sqlite3BtreeOpen`; free via
      `sqlite3_free_filename` at `opendb_out`.  (b) Call
      `sqlite3_config(SQLITE_CONFIG_URI, 1)` in `shellMain` right after
      `outputInit` — mirrors shell.c.in:12820 so the CLI honors URIs by
      default just like upstream.  Smoke parity vs
      `/home/bpsa/app/sqlite3/sqlite3`:
        `passqlite3 'file:/tmp/uritest.db?mode=rwc' '...'` → `1`, exit 0
        `passqlite3 ':memory:' ".open --new 'file:/tmp/newdb?mode=rwc'"
         ".tables"` → empty, exit 0
      both match upstream byte-for-byte.  Regression: 5020/5020 green.
      Files: passqlite3main.pas:735..917, passqlite3shell.pas:~9974.
      Follow-up:  `sqlite3_uri_parameter` / `_boolean` / `_int64` /
      `_key` already exist in passqlite3util.pas (~2995..3070) — no
      stubs left in this lane.

- [X] **6.10** TestExplainParity closed.
- [X] **6.11** PRAGMA page_count + DROP TABLE remaining gap closed.
- [X] **6.12** sqlite3Pragma full port; DiagPragma all PASS.
- [X] **6.14** Compound `SELECT … FROM sqlite_schema … UNION ALL …` — both sub-bugs closed (compound dispatch + selectExpander/resolveSelectNames walk pPrior).
- [X] **6.15** TestExplainParity transient regression — resolved on clean rebuild.
- [X] **6.29 / 6.29.followup** `sum(b) OVER ()` / `avg(b) OVER ()` — closed via colUsed propagation across window-rewrite boundary in sqlite3WindowRewrite.

---

## Phase 7 — Parser

- [X] **7.1.1** Schema initialisation (prepare.c) + ATTACH reload.
- [X] **7.1.2** sqlite3NestedParse full driver.
- [X] **7.1.8** ATTACH / DETACH (attach.c).
- [X] **7.1.9** ALTER TABLE (alter.c) — all five entry points + nine SQL helpers.
- [X] **7.4b** TestBytecodeParity gate landed; sub-tasks 7.4b.1..7.4b.6 closed.
- [X] **7.4c** TestVdbeTrace differential opcode-trace gate.
- [X] **7.4d** WITHOUT ROWID runtime corruption — closed by 10.1.bug.16.
- [X] **7.4e** Bare-bareword INSERT → no-such-column error wired in resolver.

---

## Phase 8 — Public API

Public-API gap analysis: `../sqlite3/src/sqlite.h.in` exports
~238 `sqlite3_*` symbols; the Pascal port currently exposes ~156.
Windows-only entry points (`sqlite3_win32_*`) and pure typedefs are excluded.

- [X] **8.9.2** Carray / shared-cache / misc (sqlite3_carray_bind).
- [X] **8.x** unixCurrentTimeInt64; VFS iVersion bumped 1→2.
- [X] **8.10** Public-API sample-program gate (DiagSampleProg 6 PASS / 0 FAIL).
- [X] **8.x.colneed** sqlite3_collation_needed callback fires.
- [X] **8.x.memused** db^.pnBytesFreed dry-run accounting honoured.

---

## Phase 10 — CLI tool (`shell.c`, ~12k lines → `passqlite3shell.pas`)

Each chunk lands with a scripted parity gate that diffs `bin/passqlite3`
against the upstream `sqlite3` binary.  Unported dot-commands must return
the upstream `Error: unknown command or invalid arguments: ".foo"` so
partial landings cannot silently no-op.

### 10.1a Skeleton + arg parsing + REPL loop

- [X] **10.1a** Skeleton landed; remaining deferrals broken out into 10.1.2.a/b/c and 10.1.3.a/b/c below.  Gate: `tests/cli/10a_repl/` scaffolded under 10.1a.G (was previously punted to 10.2).
- [X] **10.1.1** ShellState record + global state.
- [~] **10.1.2** processInput / oneInputLine REPL core landed; `echoGroupInput`
      hook is wired (passqlite3shell.pas:8881 / 8924 / 8929 / 8961 / 8973) and
      `.echo` toggles MFLG_ECHO (passqlite3shell.pas:3672).  Upstream
      `quickscan` state machine still stubbed — broken out below.
  - [X] **10.1.2.a** Ported `QuickScanState` + `quickScan()` beside
        `isPlainWhiteOrComment` (passqlite3shell.pas:1410); processInput cut
        gate now reads `QSS_SEMITERM(qss) and sqlite3_complete(...)` and
        resets `qss := 0` after each cut.  Continue-prompt/paren tracker
        deferred to 10.1.2.c.
  - [X] **10.1.2.b** Port `line_is_command_terminator` (shell.c.in:12182..12191) —
        landed as `lineIsCommandTerminator` + `lineIsComplete` near
        passqlite3shell.pas:1620; `processInput` rewrites the line to `;`
        when QSS_INPLAIN and the accumulator is complete (mirrors
        shell.c.in:12451..12455).  Verified byte-identical against upstream
        for `go`, `GO`, and bare `/` smokes.
  - [X] **10.1.2.c** Wire `CONTINUE_PROMPT_PSTATE` continuation-prompt tracker —
        landed `TDynaPrompt` + `trackParenLevel` + `setLexemeOpen` +
        `dynamicContinuePromptStr` near passqlite3shell.pas:1350, plus
        `continuePromptReset` / `AwaitS` / `AwaitC` / `ParenIncr` helpers.
        `quickScan` now takes a `pst: PDynaPrompt` and calls the hooks at
        every C call site; `oneInputLine` renders via
        `dynamicContinuePromptStr`.  Interactive smokes show `'  ...>`,
        `(x1...>`, and `/* ...>` continuation prompts.
- [~] **10.1.3** main + process_command_line two-pass arg parser landed.
      Three deferrals broken out:
  - [X] **10.1.3.a** Port `find_home_dir` + `find_xdg_file` +
        `process_sqliterc` (shell.c.in:12548..12714).  Sequence: lookup
        `XDG_CONFIG_HOME/sqlite3/sqliterc` (fall back to `~/.config/...`
        then `~/.sqliterc`).  Call `process_input(p, sqliterc)` with `p^.in`
        swapped to the rc handle, save/restore `zInFile` + `lineno`.  Honour
        `bail_on_error` on a user-supplied `-init` path miss.  Stub at
        passqlite3shell.pas:9374..9378 (`if noInit then ; if zInitFile <> '' then ;`)
        becomes the call site.
        **Done:** findHomeDir/findXdgFile/processSqliteRc landed; Linux-only
        port skips Windows arms; getpwuid arm collapsed to $HOME (FPC base
        RTL has no getpwuid).  Routes line reads through curInputText with
        inFile sentinel marker for stdin-only guards.
  - [X] **10.1.3.b** `-init <file>` payload loading — once 10.1.3.a lands,
        `noInit=False` with `zInitFile=''` reads the default rc, and
        `zInitFile<>''` forwards to `processSqliteRc(state, zInitFile)`
        (mirrors shell.c.in:13309 `process_sqliterc(&data,zInitFile)`).
        Independent test surface from 10.1.3.a — separate gate.
        **Done:** stub replaced with `if not noInit then processSqliteRc(@state, zInitFile)`;
        byte-identical to upstream on `-init`, default `~/.sqliterc`, and
        `-bail -init /nonexistent` smoke tests.
  - [X] **10.1.3.c** Wire `-memtrace` / `-pcachetrace` to the **stderr** sink
        (shell.c.in:13196..13199 `sqlite3MemTraceActivate(stderr)` /
        `sqlite3PcacheTraceActivate(stderr)`).
        **Done:** `shellLibcStderr: Pointer; external 'c' name 'stderr'`
        binding near passqlite3shell.pas:4632; CLI activations call
        `sqlite3MemTraceActivate(shellLibcStderr)` /
        `sqlite3PcacheTraceActivate(shellLibcStderr)` at
        passqlite3shell.pas:10037..10038.  Option arity fixed to match C
        shell.c.in pass 1 (zero-arg) — `-memtrace` / `-pcachetrace` split
        out of the 1-arg group (passqlite3shell.pas:10025..10031) so that
        the next argv slot (e.g. `:memory:`) is no longer eaten as a value;
        pass 2 keeps `Inc(i)` (passqlite3shell.pas:10195) mirroring C
        shell.c.in:13455..13458.  No `.memtrace` / `.pcachetrace`
        dot-commands exist in upstream C — nothing to wire in
        `do_meta_command`.  Smoke: stdout shows `42` for
        `-memtrace :memory: 'select 42;'`, stderr emits MEMTRACE lines;
        parity vs `/home/bpsa/app/sqlite3/sqlite3` confirmed.
- [X] **10.1.4** Line reader (basic LF/CRLF). GNU readline integration deferred.
- [X] **10.1.5** Exit-code mapping + interrupt_handler + SIGINT wiring.
- [X] **10.1.6** do_meta_command dispatcher skeleton.
- [X] **10.1a.G** Gate: scaffold `tests/cli/10a_repl/` — golden-diff harness
      that pipes a fixed script (mixed `.dot` cmds, multi-line SQL,
      `--`/`/* */` comments, `'..'` and `"..."` strings, `go`/`/` terminators,
      `~/.sqliterc` + `-init` loading, `-memtrace`/`-pcachetrace` stderr
      capture) into both `bin/passqlite3` and the upstream `sqlite3` and
      diffs stdout+stderr byte-for-byte.  Move 10.1a from `[~]` to `[X]`
      once 10.1.2.a..c, 10.1.3.a..c and this gate are green.
      **Done:** landed as `src/tests/TestShellRepl.pas` (Pascal binary —
      matches TestShellModes/TestShellSchema convention), wired into
      `src/tests/build.sh` next to TestShellSchema.  8/8 PASS:
      mixed .dot, multi-line SQL, -- + /* */ comments, '..''..' +
      "col with spaces", `go`/`/` terminators, `-init` payload load,
      `-memtrace` (stderr-only marker), `-pcachetrace` (stderr-only
      marker, pre-clean removes p.db between exp/act runs).
      One section **deferred with TODO**: `~/.sqliterc` auto-load.
      Upstream resolves $HOME via getpwuid(getuid()) before falling
      back to $HOME (shell.c.in:12548..12582 find_home_dir); the port
      collapses to $HOME only (FPC base RTL has no getpwuid — see
      memory note from 10.1.3.a closure).  Setting HOME=<tempdir>
      therefore makes the port read the temp rc while upstream still
      reads the real user rc, defeating a hermetic byte-diff.  The
      `-init` payload section already exercises the same
      `processSqliteRc()` call site with a deterministic argv path,
      so coverage of the rc loading code path is preserved.  TODO
      tagged inline in TestShellRepl.pas.

### 10.1b Output modes + formatting controls

- [X] **10.1b** Output modes + formatting controls. Gate: `bin/TestShellModes` diffs the port byte-for-byte against the upstream `sqlite3` binary across every `.mode` plus `.headers/.separator/.nullvalue/.width/.print`.
  - [X] **10.1b.1** `.mode` (list, line, column, csv, tabs, html, insert, quote, json, markdown, table, box, tcl, ascii)
  - [X] **10.1b.2** `.headers`
  - [X] **10.1b.3** `.separator`
  - [X] **10.1b.4** `.nullvalue`
  - [X] **10.1b.5** `.width`
  - [X] **10.1b.6** `.echo`
  - [X] **10.1b.7** `.changes`
  - [X] **10.1b.8** `.print` / `.parameter` (formatting-only subset), Unicode-width helpers, box-drawing renderer

- [X] **10.1.7..10.1.14** `.mode` dispatcher, shell_callback row dispatcher, columnar renderers (Column/Table/Markdown/Box), `.headers/.separator/.nullvalue/.echo/.changes/.width` setters, `.print/.parameter`, CSV/JSON/HTML writer helpers all landed.

### 10.1c Schema introspection dot-commands

- [~] **10.1c** Gate: `bin/TestShellSchema` diffs the port byte-for-byte
  against the upstream `sqlite3` binary for the schema-introspection
  dot-commands.  Multi-result `.tables` / `.indexes`-no-arg / temp-schema
  side-effects on `.databases` after `.indexes` are pre-existing port
  divergences and stay out of the gate.
  - [X] **10.1c.1** `.schema` (basic + pattern + `--indent` + `--nosys`)
  - [X] **10.1c.2** `.tables` (single-result + pattern)
  - [X] **10.1c.3** `.indexes` (with table arg)
  - [X] **10.1c.4** `.databases`
  - [X] **10.1c.5** `.fullschema`
  - [X] **10.1c.6** `.lint fkey-indexes` — closed 2026-05-11 via
        bugs 6.13.B and 6.16.  TestShellSchema now exercises a
        mixed-FK script (`parent` + `child` with covering index +
        `orphan` without) byte-identical with upstream.
  - [X] **10.1c.7** `.expert` (read-only subset) — engine ported in
        10.1.101; `cmdExpert` parses `-verbose` / `-sample N` and
        routes the next SQL through `expertHandleSQL` / `expertFinish`.
        Index recommendations are degenerate today (always
        "(no new indexes)") pending 6.13.B.11.

- [X] **10.1.15..10.1.19, 10.1.21** `.schema --indent`, `.tables`, `.indexes`, `.databases`, `.fullschema`, `.expert` (stub) all landed.
- [X] **10.1.20** `.lint fkey-indexes` — unblocked by bugs 6.13.B and 6.16 (2026-05-11); gated by `bin/TestShellSchema`.

### 10.1d Data I/O dot-commands

- [X] **10.1d** Most subcommands landed under 10.1.22..10.1.27; the
      `.import` heredoc/pipe input arms (10.1d.3.a/b), `.open` flag
      wire-up (10.1d.6.a/b) and the 10.1d.G golden-diff gate
      (`src/tests/TestShellIO.pas`) are all `[X]`.  No external
      dependencies — `appendvfs` (10.1.84), `zipfile` (10.1.98) and the
      `sqlite3_deserialize` + `openDb` switch (10.1.102) are all `[X]`.
  - [X] **10.1d.1** `.read` — landed under 10.1.22.
  - [X] **10.1d.2** `.dump` — landed under 10.1.23.
  - [~] **10.1d.3** `.import` — auto-create-from-header + duplicate-column
        renaming closed under 10.1.24.  Two sub-arms remain:
    - [X] **10.1d.3.a** Heredoc input — `FILE` of the form `<<EOF` reads
          subsequent lines from `p^.in` into an `sqlite3_str` until a
          line begins with the end-mark, then feeds the buffered text to
          the CSV reader via `sCtx.zIn` (shell.c.in:7601..7637).  Landed
          via `TImportCtx.zIn`/`zInCur` + `importGetc` heredoc arm; error
          path mirrors `shellErrorLocation` "line N:" / "<file>:N:" prefix.
    - [X] **10.1d.3.b** Pipe input — `FILE` of the form `|cmd` does
          `sqlite3_popen(zFile+1,"r")` and sets `xCloser = pclose`
          (shell.c.in:7593..7600).  Landed via libc-bound
          `shellLibcPOpen`/`shellLibcPClose`/`shellLibcFRead`
          (passqlite3shell.pas:4639..4647), `TImportCtx.pipeFile`/
          `pipeOpen` (passqlite3shell.pas:7665..7669), `importGetc`
          pipe-`fread` arm (passqlite3shell.pas:7729..7733) and the pipe
          branch in `cmdImport` (passqlite3shell.pas:8185..8202) with
          `sCtx.zFile := '<pipe>'` swap.  Safe-mode gate landed inline
          at function entry (passqlite3shell.pas:8072..8085) — emits
          `cannot run .import in safe mode` via the
          `shellErrorLocation` "line N:" / "<file>:N:" prefix and
          `Halt(1)`s (matching C `failIfSafeMode`).
  - [X] **10.1d.4** `.output` / `.once` — landed under 10.1.25.
        Editor / spreadsheet / web-browser (`-e`/`-x`/`-w`) variants and
        pipe targets (`|cmd`) intentionally not gated here; tracked as a
        future xdg-open / TProcess follow-up.
  - [X] **10.1d.5** `.save` — landed under 10.1.26.
  - [~] **10.1d.6** `.open` — base flag set landed under 10.1.27.
        `cmdOpen` at passqlite3shell.pas:5349 carries the full upstream
        flag set; remaining work is the 10.1d.G gate harness.
    - [X] **10.1d.6.a** Wire `--zip` / `--deserialize` / `--hexdb` in
          `cmdOpen` so they set `p^.openMode` to `SHELL_OPEN_ZIPFILE` /
          `SHELL_OPEN_DESERIALIZE` / `SHELL_OPEN_HEXDB` before calling
          `openDb(p, 1)` (the post-open switch in `openDb` is already
          present from 10.1.102 — only the dot-command parser needs the
          three extra arms).  Also wire `--maxsize N` → `p^.szMax`,
          which `openDb`'s deserialize arm reads.  Done: arms live at
          passqlite3shell.pas:5369..5384.  Verified `.open --deserialize
          /tmp/d.db` byte-matches upstream on a SELECT round-trip;
          `--maxsize N` survives into `p^.szMax` (intentional divergence
          from shell.c.in:10206 which zeroes szMax — see 10.1.27.c).
    - [X] **10.1d.6.b** Bring the upstream `--readonly`/`--new`/
          `--ifexists`/`--nofollow`/`--exclusive` error messages
          byte-identical with shell.c.in (`unknown option:` ordering and
          punctuation) so the 10.1d gate diffs clean.  Drive-by while
          touching `cmdOpen` for 10.1d.6.a.  Done: `unknown option: %s`
          and `extra argument: "%s"` confirmed byte-identical vs upstream
          via `.open --bogus foo` / `.open a b` smokes.
  - [X] **10.1d.G** Gate: golden-diff harness landed at
        `src/tests/TestShellIO.pas`, wired into `src/tests/build.sh`
        next to `TestShellRepl`.  Sections covered (11/11 PASS today):
        csv-roundtrip, ascii-roundtrip, heredoc-import (10.1d.3.a),
        pipe-import (10.1d.3.b), output-file, once-file, save-file +
        save-file-reopen, read-file, open-zip, open-deserialize.
        Both stdout and the persisted file bytes
        (`.output`/`.once`/`.save` outputs) are diff'd against the
        upstream `sqlite3` binary.  One sub-arm deferred:
        **open-hexdb** — the port emits `Error: cannot open ''`
        before `readHexDb()` consumes the dbtotxt stream, indicating
        the `cmdOpen --hexdb` arm still rejects the empty-filename
        path that upstream allows (shell.c.in routes through
        `readHexDb()` from `cmdOpen` directly when no FILE arg).
        Tagged `TODO 10.1d.G` inline in TestShellIO.pas; re-enable
        once `cmdOpen`'s `--hexdb` no-filename branch is fixed.
        Flips 10.1d to `[X]`.

- [X] **10.1.22, 10.1.23, 10.1.25, 10.1.26** `.read FILE`, `.dump` (full), `.output`/`.once`, `.save` all landed.
- [~] **10.1.24** `.import` — option parser + reader landed at
      passqlite3shell.pas:7609 (`cmdImport`).  Done:
      `--csv` / `--ascii` / `--colsep` / `--rowsep` / `--esc` / `--qesc` /
      `-v` / `--schema` / `--skip` flag arms; CSV (`csv_read_one_field`) +
      ASCII (`ascii_read_one_field`) readers at passqlite3shell.pas:7274..7397;
      auto-create-from-header (`shellAutoColumnAdd`/`shellAutoColumnFinish`,
      shell.c.in:7165..7339); duplicate-column renaming via 10.1.bug.131
      (now `[X]`).  Remaining sub-arms — broken out under 10.1d so the
      gate sits next to the other I/O dot-commands:
  - [X] **10.1.24.a** Heredoc input (`FILE` = `<<END`) — see
        [10.1d.3.a](#10.1d).  Landed: `else if (Length(zFile) > 2) and
        (zFile[1]='<') and (zFile[2]='<')` arm inside `cmdImport`
        accumulates lines from `p^.in` (via `oneInputLine`) into a
        `Psqlite3_str` until a line begins with the end-mark, then routes
        through the existing CSV/ASCII reader via `sCtx.zIn` / `zInCur`
        (importGetc heredoc arm).  Error: `Content terminator "%s" not
        found.` (shell.c.in:7634) with `line N:` / `<file>:N:` prefix.
  - [X] **10.1.24.b** Pipe input (`FILE` = `|cmd`) — landed jointly
        with [10.1d.3.b](#10.1d).  Uses libc-bound popen/pclose/fread
        (passqlite3shell.pas:4639..4647), wired through
        `TImportCtx.pipeFile`/`pipeOpen` and `importGetc`'s pipe-fread
        arm (passqlite3shell.pas:7665..7733); pipe arm at
        passqlite3shell.pas:8185..8202 swaps `sCtx.zFile := '<pipe>'`
        on success and errors `Error: cannot open "%s"` on popen failure.
        Safe-mode gate at passqlite3shell.pas:8072..8085 mirrors C
        `failIfSafeMode(p, "cannot run .import in safe mode")`.
- [X] **10.1.27** `.open` — `cmdOpen` at passqlite3shell.pas:5394 covers
      the full upstream flag set (`-new`, `-readonly`, `-exclusive`,
      `-ifexists`, `-nofollow`, `-zip`, `-append`, `-deserialize`,
      `-hexdb`, `-normal`, `-maxsize N`), URI-aware `-new` deletion,
      safe-mode enforcement, and the session_close_all pre-close hook
      stub.  All sub-arms `.a..g` `[X]`; see breakdown below for the
      per-arm landing notes:
  - [X] **10.1.27.a** Add `-zip` / `-append` flag arms (shell.c.in:10158..10162).
        Done: both arms gated on `p^.bSafeMode = 0`; `--zip` round-trip
        verified byte-parity vs upstream sqlite3 on a `zipfile` vtab read.
  - [X] **10.1.27.b** Add `-deserialize` / `-hexdb` / `-normal` flag arms
        (shell.c.in:10172..10178).  Done: post-flag guard relaxed to
        `(zFN <> '') or (p^.openMode = SHELL_OPEN_HEXDB)` and filename
        allocation skipped when zFN is empty (matches shell.c.in:10231
        zNewFilename=NULL).  `--deserialize` flag now flows to openDb;
        any residual sqlite3_deserialize failure is a 10.1.102 issue.
  - [X] **10.1.27.c** Add `-maxsize N` arm (shell.c.in:10179..10180).
        Done: szMax tracked in a local, assigned to `p^.szMax` after the
        loop so it survives.  Verified byte-parity with upstream on a
        `.open --maxsize N FILE` + SELECT round-trip.
  - [X] **10.1.27.d** `-new` URI-aware deletion (shell.c.in:10210..10218).
        Done: ported `shellFilenameFromUri` (shell.c.in:5807..5834) at
        passqlite3shell.pas just above `cmdOpen` — percent-decodes
        everything between `file:` and `?`.  `-new` arm at
        passqlite3shell.pas:5413..5419 now branches on `file:` prefix
        and unlinks the decoded path; also gated on `p^.bSafeMode = 0`
        per shell.c.in:10210.  Verified: `.open --new
        'file:/tmp/newdb?mode=rwc'` deletes `/tmp/newdb` (the post-open
        URI-aware sqlite3_open is a separate gap — port's openDb does
        not enable URI parsing at the C-API level).
  - [X] **10.1.27.e** `bSafeMode` enforcement (shell.c.in:10148 +
        10221..10227).  Done: `cmdOpen` now forces `openFlags :=
        SQLITE_OPEN_READONLY` up front when `p^.bSafeMode <> 0`
        (passqlite3shell.pas after the `openFlags` init).  The
        `-zip`/`-append` arms already had `(p^.bSafeMode = 0)` gates
        from 10.1.27.a — in safe mode they silently fall through to
        the `unknown option:` arm, byte-matching upstream (which uses
        `&& !p->bSafeMode` on the optionMatch and does NOT call
        failIfSafeMode for those flags).  Disk-backed `zFN` is refused
        post-loop unless `:memory:` or `SHELL_OPEN_HEXDB`, via a new
        `failIfSafeMode(p, AnsiString)` helper that mirrors
        shell.c.in:1779..1810 (shellErrorLocation prefix + cli_exit(1)).
        Smoke vs upstream sqlite3: `.open --zip /tmp/foo.zip` →
        `unknown option: --zip`; `.open /tmp/foo.db` →
        `argv[3]: cannot open disk-based database files in safe mode`;
        `.open :memory:`, `.open --readonly :memory:`, `.open --hexdb
        /tmp/foo.hex` all succeed.  Byte-identical messages.
  - [X] **10.1.27.f** `session_close_all(p, -1)` pre-close hook
        (shell.c.in:10198).  Done: added `sessionCloseAll(p, -1)` call
        just above `closeDb(p^.db)` in `cmdOpen` plus a stub
        `procedure sessionCloseAll(p: PShellState; bArg: i32)` that
        no-ops with a `{ TODO: session extension not ported — 10.1.47 }`
        comment.  Call site is now byte-comparable with C; future
        10.1.47 wiring is a one-line body change.
  - [X] **10.1.27.g** Drive-by: byte-identical `unknown option:` /
        `extra argument:` error strings against shell.c.in:10186..10193.
        Done jointly with 10.1d.6.b; smokes `.open --bogus foo` and
        `.open a b` produce identical bytes vs upstream.

  10.1d.6.a / 10.1d.6.b are the gate-side mirror of this list; once
  all `.a..g` land and the gate passes, 10.1.27 flips to `[X]`.

### 10.1e Meta / diagnostic dot-commands

- [X] **10.1e** Gate: src/tests/TestShellMeta.pas (10.1e.G).  Byte-identical across .help/.show/.eqp/.explain/.cd/.shell/.system/.stats/.trace/.testcase/.testctrl/.iotrace/.scanstats/.selecttrace/.wheretrace/.timer/.log within their deterministic scope (48/48 PASS).
  - [X] **10.1e.1** `.stats` — byte-parity gate (stats-state / stats-usage); deterministic state-flip arms only (`.stats on|off|stmt|vmstep` round-tripped via `.show`) plus usage-error path.  Bare `.stats` (display_stats counter dump) deliberately out of scope — memory/lookaside hi-water values are not deterministic across binaries.  Fixed cmdStats to call display_stats on bare arg, route 1-arg through booleanValue (parseOnOff), and return rc=1 on usage error with `Usage: .stats ?on|off|stmt|vmstep?\n` to match C (shell.c.in:11324..11339).
  - [X] **10.1e.2** `.timer` — byte-parity gate (timer-state / timer-usage); deterministic state-flip arms only (`.timer on|off|once`).  Bare `.timer` → `Usage: .timer on|off|once\n` rc=1 (shell.c.in:11886..11901).  Fixed cmdTimer to return i32 so the usage path propagates rc=1 (was silent rc=0).  Runtime consumers (begin_timer/end_timer wall+rusage triple) are non-deterministic by construction and excluded; `true`/`false` tokens route through booleanValue stderr-prints and are also out of gate scope.
  - [X] **10.1e.3** `.eqp` — byte-parity gate landed in
        src/tests/TestShellMeta.pas (eqp-state round-trips on/full/
        trigger/off via `.show`; eqp-usage covers nArg<1 → `Usage:
        .eqp off|on|trace|trigger|full` rc=1).  cmdEqp now returns
        rc=1 on the usage path (was silent rc=0).
  - [X] **10.1e.4** `.explain` — byte-parity gate landed in
        src/tests/TestShellMeta.pas (explain-state round-trips
        auto/on/off/auto via `.show`, reading the
        autoExplain ? 'auto' : 'off' slot at shell.c.in:11279).
  - [X] **10.1e.5** `.show` — byte-parity gate landed in
        src/tests/TestShellMeta.pas (show-default, show-tweaked covering
        csv/headers/nullvalue/separator, show-usage for `nArg!=1`); fixed
        latent miss: cmdShow now enforces `Usage: .show` per shell.c.in:11271..11275.
  - [X] **10.1e.6** `.help` — byte-parity gate landed in
        src/tests/TestShellMeta.pas (help section: `.help` + `.help schema`).
        Closure also pruned the `.session` block from azHelp (passqlite3shell.pas:3726)
        to mirror upstream's `#if defined(SQLITE_ENABLE_SESSION)` gate
        (shell.c.in:3894..3908): the port's cmdSession is a "not compiled in"
        stub, so azHelp must match the undefined-SESSION C build.  Array
        bound shrunk from 0..264 to 0..251.  Re-add when 10.1.47 lands.
  - [X] **10.1e.7** `.shell`/`.system` — byte-parity gate (shell-echo / system-echo / shell-multiarg / shell-usage / system-usage / shell-safemode); fixed cmdShell to return rc=1 on missing-arg so dispatcher/exit code matches C (shell.c.in:11241..11264).  FILE*-vs-fd redirect divergence (10.1.34) and runner-shell not-found wording deliberately out of scope; documented in section header.
  - [X] **10.1e.8** `.cd` — byte-parity gate (cd-ok / cd-usage / cd-missing / cd-mixed); fixed cmdCd to return rc=1 on usage+chdir-failure and added failIfSafeMode gate so dispatcher/exit code matches C (shell.c.in:9127..9145).
  - [X] **10.1e.9** `.log` — byte-parity gate (log-state {stdout/stderr/off/on} / log-file / log-usage / log-usage-multi); silent destination-state flip matches upstream's silent flip (shell.c.in:10091..10109).  SQLITE_CONFIG_LOG wiring is stubbed per 10.1.36 (raw-varargs sqlite3_config gate, 8.1.1), so neither upstream nor port emits logger output at non-debug runtime.  Fixed cmdLog to return i32 so `Usage: .log FILENAME\n` rc=1 propagates on wrong nArg (was silent rc=0).  Out of scope: safe-mode "cannot set .log to anything other than \"on\" or \"off\"" rewrite and live logger output.
  - [X] **10.1e.10** `.trace` — byte-parity gate (trace-stderr / trace-stdout / trace-file / trace-bare / trace-unknown).  Rewrote traceCallback to mirror sql_trace_callback (shell.c.in:4886..4940): STMT/ROW emit `<SQL>;\n` with trailing semicolons stripped + one re-added, CLOSE emits `-- closing database connection\n`, PROFILE emits `<SQL>; -- <ns> ns\n`.  Fixed unknown-option wording to `Unknown option "%s" on ".trace"\n`, file-open error to `Error: cannot open "%s"\n`, and converted cmdTrace to a function so rc=1 propagates on unknown option.  Scope: SQL-text trace in default --stmt + plain mode and trace destinations (stdout / stderr / FILE / no-arg = off).  Deterministic-only: --profile (ns timing), --expanded round-trips, and the SQLITE_TRACE_CLOSE arm are kept out of the gate.
  - [X] **10.1e.11** `.iotrace` — byte-parity gate (iotrace-off / iotrace-stdout / iotrace-file / iotrace-bare).  Upstream `.iotrace` is wrapped in `#ifdef SQLITE_ENABLE_IOTRACE` (shell.c.in:9979..9999); the standard non-debug CLI build leaves the symbol undefined, so every `.iotrace ...` invocation falls through to the unknown-command tail (rc=1).  Fixed the port to match: removed the `iotrace` dispatch line in doMetaCommand so the cmd reaches the unknown-command arm exactly like upstream.  cmdIotrace stub body retained (as a doc comment) for the future SQLITE_ENABLE_IOTRACE wiring; sqlite3IoTrace sink in passqlite3vdbe.pas:4122 stays a no-op until then.  Scope: non-debug build only.
  - [X] **10.1e.12** `.scanstats` — byte-parity gate (scanstats-state {on/off/est/vm} / scanstats-usage / scanstats-bare).  cmdScanstats (shell.c.in:10545..10573) accepts one positional arg and stashes the value in ShellState.mode.scanstatsOn; in a non-debug build (SQLITE_ENABLE_STMT_SCANSTATUS undefined) the C arm unconditionally emits `Warning: .scanstats not available in this build.\n` on stderr, and `Usage: .scanstats on|off|est\n` + rc=1 on wrong arg count.  Fixed the port to propagate the usage rc=1 (cmdScanstats converted to `function: i32` so the dispatcher sets Result on the Usage path).  Scope: non-debug build, state-flip + usage arms only; the runtime consumer (display_scanstats() before each finalize) is tracked separately.
  - [X] **10.1e.13** `.testcase` — byte-parity gate (testcase-silent: bare `.testcase` + `.testcase NAME`).  Both arms are silent on stdout/stderr with rc=0, matching shell.c.in:8868..8904 (dotCmdTestcase records zTestcase via sqlite3_snprintf and primes cli_output_capture).  Out of scope: `.check ANSWER` comparator (10.1.40 follow-up — capture redirector pending) and the dotCmdError-prefixed unknown-option / missing-arg arms (line-number prefix is not byte-deterministic across binaries).
  - [X] **10.1e.14** `.testctrl` — byte-parity gate (testctrl-byteorder / testctrl-prng / testctrl-help / testctrl-unknown).  Fixed two latent port bugs surfaced by the gate: (a) sqlite3_test_control(BYTEORDER) returned 0 instead of `SQLITE_BYTEORDER*100 + LE*10 + BE` = 123410 on x86_64 (passqlite3main.pas:4313..); (b) aTestctrl[] was missing the json_selfcheck entry; (c) cmdTestctrl was a `procedure` so the `rc=1; goto meta_command_exit` exits in shell.c.in:11451 (help dump), :11467 (ambiguous), :11869..11872 (Usage with iCtrl>=0) never propagated to errCnt — converted to function returning i32 and wired through doMetaCommand.  Deterministic-only: byteorder + prng_save/prng_restore (isOk==1/3 renders); the help dump (rc=1); and the unknown verb error path (rc=0, error to stderr).  Out of scope: every sub-control whose dispatcher arm relies on the variadic cdecl boundary (optimizations / json_selfcheck / pending_byte / ...) — gated by Phase 8.4.1.
  - [X] **10.1e.15** `.selecttrace` — byte-parity gate (selecttrace-zero / selecttrace-mask / selecttrace-bare).  cmdSelecttrace/cmdTreetrace (shell.c.in:10711..10716) call sqlite3_test_control(SQLITE_TESTCTRL_TRACEFLAGS, 1, &x), which in a non-debug CLI build (SQLITE_DEBUG / SQLITE_ENABLE_SELECTTRACE undefined) is a silent no-op — upstream emits nothing and returns rc=0 for every invocation.  Fixed the port's cmdTraceFlags stub: was emitting `Note: .X requires a debug build; ignored\n`, now silent + rc=0 so it byte-matches the non-debug reference build.  Scope: non-debug build only; when TRACEFLAGS is wired the stub can install the flag word.
  - [X] **10.1e.16** `.wheretrace` — byte-parity gate (wheretrace-zero / wheretrace-mask / wheretrace-bare).  cmdWheretrace (shell.c.in:12042..12045) calls sqlite3_test_control(SQLITE_TESTCTRL_TRACEFLAGS, 3, &x); like .selecttrace it is a silent no-op in a non-debug CLI build.  Same fix as 10.1e.15: cmdTraceFlags silent, rc=0.  Scope: non-debug build only.
  - [X] **10.1e.G** Gate: byte-parity harness landed at
        src/tests/TestShellMeta.pas (analogous to 10.1d.G TestShellIO).
        Pipes a fixed dot-command script into both bin/passqlite3 and
        the upstream `sqlite3` binary and diffs stdout+stderr
        byte-for-byte; skips with PASS if upstream missing.  Covers
        .help/.show/.eqp/.explain/.cd/.shell/.system/.stats/.trace/
        .testcase/.testctrl/.iotrace/.scanstats/.selecttrace/.wheretrace
        /.timer/.log within their deterministic scope (48/48 PASS).

- [X] **10.1.28..10.1.33, 10.1.35, 10.1.37** `.stats`, `.timer`, `.eqp`, `.explain`, `.show`, `.help` (full azHelp[]), `.cd`, `.trace` landed.
- [X] **10.1.34** `.shell`/`.system` — output capture into `.output` sink lands automatically because cmdOutput redirects at the POSIX-fd level (dup2 onto fd 1), so the child inherits the redirected stdout via fork/exec.  Closure: added `failIfSafeMode(p, 'cannot run .'+zCmdName+' in safe mode')` gate at cmdShell entry (shell.c.in:11248), threaded zCmdName through the dispatcher, and Flush(Output) before fpsystem so prior Pascal writes hit the active sink before the child writes to inherited fd 1.  Smoke: `.output /tmp/s1.out ; .shell echo hello` captures to file (port) — upstream actually leaks to terminal because upstream redirects at FILE* level only; safe-mode refusal byte-parity (`argv[3]: cannot run .shell in safe mode` exit 1); direct `.shell echo direct` byte-parity.  passqlite3shell.pas:4766..4798 + dispatcher:9426.
- [~] **10.1.36** `.log` — destination recorded; SQLITE_CONFIG_LOG wiring gated on raw-varargs sqlite3_config (8.1.1).
- [X] **10.1.38** `.iotrace` — stub; full sqlite3IoTrace fanout gated on sqlite3VdbeIOTraceSql arm (currently a stub at passqlite3vdbe.pas:4122).
- [~] **10.1.39** `.scanstats` — stub; gated on sqlite3VdbeScanStatus* arms + 8.2.1.
- [~] **10.1.40** `.testcase NAME` — records NAME; `.check ANSWER` comparator side pending.
- [~] **10.1.41** `.testctrl` — dispatcher landed; non-PRNG/BYTEORDER opcodes stub-return 0 (gated on Phase 8.4.1 varargs cdecl boundary).
- [~] **10.1.42** `.selecttrace`/`.wheretrace`/`.treetrace` — emit "requires debug build" breadcrumb. Full wiring needs varargs sqlite3_test_control variant (deferred).

### 10.1f Long-tail / specialised dot-commands

- [ ] **10.1f** Out-of-scope dependencies (session, archive, recover) may stub with the upstream `SQLITE_OMIT_*` "feature not compiled in" message. Gate: `tests/cli/10f_misc/`.
  - [X] **10.1f.0** `.backup` — gated by `src/tests/TestShellBackup.pas` (byte-parity vs upstream).
  - [X] **10.1f.1** `.restore` — gated by `src/tests/TestShellBackup.pas` (round-trip + byte-parity).
  - [X] **10.1f.2** `.clone` — gated by `src/tests/TestShellBackup.pas` (byte-parity + content diff).
  - [X] **10.1f.3** `.archive`/`.ar` — gated by `src/tests/TestShellArchive.pas` (byte-parity vs upstream: create/list-verbose/glob-filter/extract-roundtrip/--dryrun/--help).
  - [X] **10.1f.4** `.session` — gated by `src/tests/TestShellArchive.pas` shape arm (port emits friendly "session extension not compiled in" stub per 10.1.47; upstream falls through to unknown-command — deliberate divergence).
  - [X] **10.1f.5** `.recover` — gated by `src/tests/TestShellArchive.pas` (byte-parity vs upstream over 3-row+index fixture; complements DiagRecover.pas shape gate).
  - [X] **10.1f.6** `.dbinfo` — gated by `src/tests/TestShellDbinfo.pas` (byte-parity vs upstream over 3-row+index fixture: default/`main`/`temp` arms, with rc=1 propagation on "unable to read database header"). Side-fix: route positional dot-cmd rc through process exit (shell.c.in:13548 unconditional propagation).
  - [X] **10.1f.7** `.dbconfig` — gated by `src/tests/TestShellDbinfo.pas` (bare-list + per-op read + toggle, 11 subtests). Side-fixes: aDbConfig table now mirrors shell.c.in:9280 (names + order + FP_DIGITS); openDatabase default flags now include SQLITE_EnableView/LoadExtension per main.c:3430,3473. Counter/pointer-style DBCONFIG_* ops still gated on Phase 8.1.1.
  - [ ] **10.1f.8** `.filectrl`
  - [ ] **10.1f.9** `.sha3sum`
  - [ ] **10.1f.10** `.crnl`
  - [ ] **10.1f.11** `.binary`
  - [ ] **10.1f.12** `.connection`
  - [ ] **10.1f.13** `.unmodule`
  - [ ] **10.1f.14** `.vfsinfo`
  - [ ] **10.1f.15** `.vfslist`
  - [ ] **10.1f.16** `.vfsname`

- [X] **10.1.43, 10.1.44, 10.1.45** `.backup`, `.restore`, `.clone` all landed.
- [X] **10.1.46** `.archive`/`.ar` — closed 2026-05-11.  Full port landed; create / list-all / list-positional / list-glob / extract-all / extract-positional / insert / update / dryrun all byte-identical with the C oracle.  Two porting bugs closed: (a) `arWhereClause` non-glob branch wasn't closing the `name IN(..` list (shell.c.in:6581 uses a single template with conditional `)` arg); (b) the `CREATE TABLE sqlar(...)` template was missing the upstream column-purpose comments.  Positional-name filter codegen + GLOB range-bound truncation were tracked under [bug 6.17](#) (OR-decomposed Case-5 codegen + LIKE/GLOB range-bound prefix truncation) — both subtasks 6.17.A/B closed 2026-05-11; verified `.ar -tvf … <name>` and `.ar --glob` shapes now match C byte-for-byte on a 3-file fixture (src/, src/dir1/, c.txt).
- [X] **10.1.47** `.session` — stub (session extension not ported).
- [X] **10.1.48** `.recover` — extension dispatcher landed (passqlite3recover.pas, ~957 lines + LAF arm + wrapper-VFS arm).  Three porting bugs closed 2026-05-11:
      (a) **wrapper-VFS canonical aHdr** at recoverVfsRead was shifted by 4 bytes — Pascal had `aHdr[101..107]` for the bytes that should sit at `aHdr[97..104]` (the C oracle's `0x00 0x2e 0x5b 0x30 / 0x0D 0x00 ... 0xFF 0xFF 0x00` block).  `SELECT 1 FROM sqlite_schema` was returning SQLITE_CORRUPT(11) because the rewritten page-1 header had no valid tail sentinel.
      (b) **GROUP BY over a single-source vtab** at codegen.pas:25475 was bailing (`pTab^.eTabType = TABTYP_VTAB → Result := SQLITE_OK; Exit`).  C `select.c:8456` runs the GROUP BY arm whenever `pGroupBy != 0`, no eTabType filter; bug 6.13.B already wired vtab argument-pushdown through WhereBegin / whereLoopAddVirtual, so the bail was redundant and dropped the body of e.g. `SELECT key, count(*) FROM json_each(...) GROUP BY key` to a 3-op Init/Halt/Goto.
      (c) **OP_ParseSchema unqualified sqlite_master** at main.pas:execParseSchemaImpl emitted `SELECT … FROM sqlite_master` instead of `FROM "<dbname>".sqlite_master` (C `vdbe.c:7152..7154`).  Every CREATE TABLE in an attached db reloaded the wrong schema cache — `ATTACH ':memory:' AS aux; CREATE TABLE aux.foo(a,b); INSERT INTO aux.foo VALUES(...);` errored out at the INSERT with "no such table".  `.recover` now reaches `recoverWriteSchema1` (PRAGMA encoding / page_size / auto_vacuum / user_version / application_id all emit byte-identical with the C oracle).
      Remaining gap: `recoverCacheSchema`'s `INSERT INTO recovery.schema SELECT max(CASE WHEN field=…) … FROM sqlite_dbdata(…) WHERE pgno IN (SELECT p FROM pages) GROUP BY pgno, cell` drives the GROUP BY arm with `pDest^.eDest = SRT_Coroutine` (INSERT…FROM…SELECT consumer), which the codegen short-circuits — sqlite3Select emits an empty coroutine body, then OP_Rewind on an unallocated cursor AVs in OP_Rewind (vdbe.pas:7910).  Three follow-up features to close 10.1.48 end-to-end:
  - [X] **10.1.48.a** Threaded `SRT_Coroutine` / `SRT_EphemTab` / `SRT_Table` through the single-source GROUP BY agg arm at `codegen.pas:25468..25470`; the per-row emit at the addrOutputRow subroutine now dispatches OP_Yield (coroutine) and OP_MakeRecord+NewRowid+Insert(APPEND) (eph-table) in addition to OP_ResultRow.  Mirrors `select.c:8736` `selectInnerLoop(..., pDest, addrOutputRow+1, addrSetAbort)`.  Also lifted the NEEDCOLL-aggregate bail in `canUseAgg`: `updateAccumulatorSimple` already emits OP_CollSeq before OP_AggStep at `codegen.pas:24494..24509`, so the conservative bail was redundant — `INSERT INTO … SELECT max(CASE WHEN field=N THEN value END) … GROUP BY pgno, cell` (the recoverCacheSchema shape) now compiles end-to-end.  Regression gate clean (5020 assertions).  New diag: `src/tests/DiagInsertSelectGroupBy.pas`.
  - [X] **10.1.48.b** `WHERE pgno IN (SELECT p FROM pages)` over a recursive CTE: closed 2026-05-11.  Root cause: the sub-SELECT materialise arm at `codegen.pas:27486` gated FROM-clause-subquery materialisation on `pDest^.eDest ∈ {SRT_Output, SRT_EphemTab}`, so when `sqlite3CodeRhsOfIN`'s Case-1 recursed into `sqlite3Select` on the duplicate with `SRT_Set` destination, the CTE's eph cursor was never opened — execution AV'd at `OP_Rewind` (`vdbe.pas:7910`).  C `select.c:7939..8129` runs the FROM-subquery materialisation unconditionally for every FROM-clause subquery item, independent of the outer destination.  Fix: extend the gate to admit `SRT_Set` and add the `SRT_Set` disposal arm (MakeRecord+IdxInsert into `pDest^.iSDParm`, mirrors `selectInnerLoop` SRT_Set at `codegen.pas:21417..21428`).  DiagInRecursive tests 2 + 4 now pass (UNION ALL recursive CTE driven via `WHERE p IN (SELECT p FROM pages)` and through `INSERT … SELECT … WHERE p IN (SELECT p FROM pages)`).  Regression gate clean (5020 assertions).
  - [X] **10.1.48.d** Closed 2026-05-11.  Three fixes land `.recover` byte-identical with upstream sqlite3:
        1. **`recoverGetPage` page-1 swap-back (passqlite3recover.pas:488..505)** mirrors `sqlite3recover.c:723` — when the wrapper-VFS-sanitised page-1 bytes match `p^.pPage1Cache`, swap in the cached on-disk copy (`p^.pPage1Disk`) so `sqlite_dbdata`/`sqlite_dbptr` walk the real b-tree header instead of the rewritten sentinel.  Without this `recoverCacheSchema` saw nCell=0 and fell back to `lost_and_found`.
        2. **`sqlite3VdbeMemSetStr` over-read (passqlite3vdbe.pas:12866..12889)**: the SQLITE_TRANSIENT arm mutated `nAlloc` to 32 *before* `Move(z^, pMem^.z^, nAlloc)`, so any quoted value with `nAlloc < 32` (e.g. `'alpha'` → 8 bytes) was Move'd 32 bytes — reading past the source `sqlite3_malloc` block and tripping glibc's `free(): invalid pointer` on the next free.  C `vdbemem.c:1338..1342` only widens the *resize* argument via `MAX(nAlloc,32)`, leaving `nAlloc` for `memcpy`.  Fix mirrors that: pass `32` as the resize floor but copy the original `nAlloc` bytes.  This is a port bug surfaced by `.recover`'s `quote(value)` arm but the corruption was latent everywhere `SQLITE_TRANSIENT` was used with small payloads — saving as feedback memory.
        3. **`recoverFinalCleanup` double-free (passqlite3recover.pas:763..769)**: the Pas port called `sqlite3_free(pTab^.zTab)` and `sqlite3_free(pTab^.aCol)` before `sqlite3_free(pTab)` — but `recoverAddTable` lays both sub-pointers out *inside* the same `recoverMalloc(...nByte...)` allocation (`pNew^.aCol := &pNew[1]; pNew^.zTab := &pNew^.aCol[nCol] + nName`), so each separate `sqlite3_free` was an invalid free on a mid-block address.  C `sqlite3recover.c:2031..2034` just frees `pTab`.  Removed the bogus child-frees.
        DiagRecover now asserts the full schema-recovered shape (CREATE TABLE t + 3 INSERT OR IGNORE rows + CREATE INDEX ti + no `lost_and_found`).  Manual byte-parity check: `diff <(passqlite3 ... .recover) <(/home/bpsa/app/sqlite3/sqlite3 ... .recover)` returns no diff.  Regression gate clean (5020 assertions).
  - [X] **10.1.48.c** Closed 2026-05-11.  Two codegen fixes + a port deviation + a new `DiagRecover` gate land `.recover` end-to-end against a locally-generated fixture (no upstream binary needed at test time).  Fixes:
        1. **FROM-subquery materialise arm gate (codegen.pas:27486..27489)** extended to admit `SRT_Fifo` / `SRT_DistFifo` outer destinations and a matching disposal arm (MakeRecord + NewRowid + Insert(APPEND), plus the DistFifo Found/IdxInsert dedup prefix that mirrors `selectInnerLoop` at 21388..21410 / `select.c:1307..1352`).  Closes the recursive-CTE setup query whose base case is `SELECT r FROM <inner-CTE>` — `generateWithRecursiveQuery` drives that with `eDest = SRT_Fifo` / `SRT_DistFifo`, so without the gate extension the inner CTE's eph cursor was never opened and OP_Rewind AV'd at `vdbe.pas:7910`.  Exercised by `recoverLostAndFound1Init`'s `used(page) AS (SELECT r FROM roots UNION SELECT child FROM sqlite_dbptr('getpage()'), used WHERE pgno=page)` shape, which crashed at runtime before this fix.
        2. **`recoverLostAndFound2Init.pMaxField` port deviation (recover.pas:1548..1561)**: C upstream's SQL is `sqlite_dbdata('getpage')` (no parens) and relies on the planner pushing `WHERE pgno = ?` into xBestIndex so dbdataFilter sees the pgno constraint and never reaches dbdataDbsize.  Our eponymous-vtab agg arm (codegen.pas:26621..26743) does not push regular-column WHERE constraints into BestIndex, so dbdataFilter falls through to dbdataDbsize and `PRAGMA 'getpage'.page_count` fails with "unknown database 'getpage'".  Forcing the function form (`sqlite_dbdata('getpage()')`) here keeps the runtime semantics identical — dbdataDbsize then takes the `SELECT getpage(0)` path that returns the page count — without requiring the BestIndex WHERE-pushdown to land first.  Docs the divergence at the call site so the deviation can be reverted once codegen pushdown is wired.
        3. **DiagRecover gate (src/tests/DiagRecover.pas)**: creates a small 3-row table + index fixture via the passqlite3 shell itself, runs `.recover` against it, and asserts 12 invariants on the recovered SQL stream (header PRAGMAs, lost_and_found CREATE + data rows for alpha/beta/gamma, COMMIT trailer).  Wired into `src/tests/build.sh`.
        Remaining (post-10.1.48 follow-up): the C oracle re-creates `t` and re-emits the original `INSERT OR IGNORE` rows; the Pas port falls back to `lost_and_found` because `recoverGetPage` does not yet do the `pPage1Cache == aPg → aPg = pPage1Disk` swap (sqlite3recover.c:723).  Adding the swap unblocks `recoverCacheSchema` (recovery.schema lands two rows: type=table/index, sqlLen=45/23) but uncovers a `free(): invalid pointer` further down `recoverWriteData` after the first emitted INSERT — separate port bug, tracked as 10.1.48.d.
- [X] **10.1.49** `.dbinfo`.
- [X] **10.1.50** `.dbconfig` — boolean DBCONFIG_* + FP_DIGITS dispatched and byte-parity gated by `src/tests/TestShellDbinfo.pas`. Counter/pointer-style ops (LOOKASIDE, MAINDBNAME, MAX_*) remain gated on raw-varargs sqlite3_db_config (8.1.1); upstream's `.dbconfig` arm itself does not surface those.
- [X] **10.1.51..10.1.59** `.filectrl`, `.sha3sum`, `.crnl`, `.binary`, `.connection`, `.unmodule`, `.vfsinfo`/`.vfslist`/`.vfsname`, `.dbtotxt`, `.breakpoint` all landed.

### 10.1.60..10.1.100 — ext/misc and ext/* extension ports (all landed)

All ported as new units under `src/`. Wired via per-unit `sqlite3<Name>Init`
in shell `openDb` unless noted. Common caveat across many eponymous-vtab
ports: bare table-valued or MATCH-style invocations are blocked by bug 6.13
(WhereBegin's vtab xBestIndex argument-pushdown not yet wired at
codegen.pas:13938 / 28163); the modules themselves are faithful end-to-end
and constraints flow once that lands.

- [X] **10.1.60** sha1.c → passqlite3sha1.pas (sha1, sha1b, sha1_query)
- [X] **10.1.61** uuid.c → passqlite3uuid.pas
- [X] **10.1.62** ieee754.c → passqlite3ieee754.pas (full ieee754 family)
- [X] **10.1.63** percentile.c → passqlite3percentile.pas (median, percentile, percentile_cont, percentile_disc; window arms wired). Companion fix to sqlite3CreateFunc xSFunc=xStep fallback.
- [X] **10.1.64** rot13.c + uint.c + base64.c → three units
- [X] **10.1.65** totype.c → passqlite3totype.pas
- [X] **10.1.66** base85.c + eval.c + urifuncs.c → three units
- [X] **10.1.67** anycollseq.c + blobio.c + nextchar.c + remember.c + stmtrand.c → five units
- [X] **10.1.68** noop.c + zorder.c + randomjson.c → three units
- [X] **10.1.69** wholenumber.c + templatevtab.c + showauth.c + mmapwarm.c → four units
- [X] **10.1.70** prefixes.c + memstat.c → two units
- [X] **10.1.71** series.c → passqlite3series.pas (generate_series)
- [X] **10.1.72** completion.c → passqlite3completion.pas
- [X] **10.1.73** decimal.c → passqlite3decimal.pas
- [X] **10.1.74** normalize.c → passqlite3normalize.pas
- [X] **10.1.75** regexp.c → passqlite3regexp.pas
- [X] **10.1.76** stmt.c + explain.c → two units
- [X] **10.1.77** qpvtab.c + memtrace.c + pcachetrace.c → three units. Companion fix: sqlite3_config now dispatches MALLOC/GETMALLOC/GETPCACHE2.
- [X] **10.1.78** btreeinfo.c + vtablog.c → two units
- [X] **10.1.79** scrub.c → passqlite3scrub.pas (sqlite3_scrub_backup)
- [X] **10.1.80** fossildelta.c → passqlite3fossildelta.pas
- [X] **10.1.81** dbdump.c → passqlite3dbdump.pas (sqlite3_db_dump)
- [X] **10.1.82** csv.c → passqlite3csv.pas
- [X] **10.1.83** closure.c → passqlite3closure.pas (transitive_closure)
- [X] **10.1.84** appendvfs.c → passqlite3appendvfs.pas (apndvfs)
- [X] **10.1.85** vfslog.c → passqlite3vfslog.pas
- [X] **10.1.86** fileio.c → passqlite3fileio.pas (readfile, writefile, lsmode, realpath, fsdir vtab)
- [X] **10.1.87** vfsstat.c → passqlite3vfsstat.pas
- [X] **10.1.88** vfstrace.c → passqlite3vfstrace.pas
- [X] **10.1.89** vtshim.c → passqlite3vtshim.pas
- [X] **10.1.90** cksumvfs.c → passqlite3cksumvfs.pas (verify_checksum auto-installed; VFS shim exported but not auto-installed)
- [X] **10.1.91** unionvtab.c → passqlite3unionvtab.pas (unionvtab + swarmvtab)
- [X] **10.1.92** fuzzer.c → passqlite3fuzzer.pas
- [X] **10.1.93** tmstmpvfs.c → passqlite3tmstmpvfs.pas (NOT auto-installed)
- [X] **10.1.94** amatch.c → passqlite3amatch.pas (approximate_match)
- [X] **10.1.95** compress.c + sqlar.c → two units (libz via cdecl, `-k-lz`)
- [X] **10.1.96** ext/intck/sqlite3intck.c → passqlite3intck.pas
- [X] **10.1.97** ext/recover/dbdata.c → passqlite3dbdata.pas (sqlite_dbdata + sqlite_dbptr)
- [X] **10.1.98** zipfile.c → passqlite3zipfile.pas
- [X] **10.1.99** spellfix.c → passqlite3spellfix.pas (full module: phonehash, editdist1, scriptcode, translit, editdist3 family, spellfix1 vtab)
- [X] **10.1.100** Built-in shell SQL UDFs: strtod, dtostr, shell_add_schema, shell_module_schema, shell_putsnl, usleep. editFunc deferred (needs system() spawn + temp-file shuttle).

- [X] **10.1.102** `.open --zip` / `--deserialize` / `--hexdb` shell
      glue.  Two pieces landed: (1) faithful port of `memdb.c:839..928`
      `sqlite3_deserialize` in passqlite3main.pas, including the
      reopenMemdb branch in attachFunc (codegen.pas) and a tiny
      `sqlite3MemdbIoMethods` accessor on passqlite3pager.pas so
      `memdbFromDbSchema` can recognise a MemFile by its vtable; (2)
      shell.c.in:4491..4510 switch + 4613..4644 post-open block in
      `openDb` (passqlite3shell.pas), backed by new `shellReadFile`
      and `shellReadHexDb` helpers.  Smoke: `--deserialize FILE` and
      `--zip FILE` both round-trip a SELECT through the CLI.

- [X] **10.1.101** `ext/expert/sqlite3expert.c` → `passqlite3expert.pas`
      (2236 lines C → ~1700 lines Pascal) + `sqlite3expert.h`.
      Public surface complete: `sqlite3_expert_new`,
      `sqlite3_expert_config` (single-int shim — only
      EXPERT_CONFIG_SAMPLE is defined), `sqlite3_expert_sql`,
      `sqlite3_expert_analyze`, `sqlite3_expert_count`,
      `sqlite3_expert_report` (SQL / INDEXES / PLAN / CANDIDATES),
      `sqlite3_expert_destroy`.  Internal vtab module ("expert"),
      idx-hash, scan / write / statement / table linked lists,
      idxCreateCandidates, idxPopulateStat1 (sqlite_expert_rem /
      sqlite_expert_sample UDFs), trigger-write replay, idxAuthCallback,
      dummy-collation + dummy-UDF mirroring all ported faithfully.
      Shell wiring landed in passqlite3shell.pas: `cmdExpert` parses
      `-verbose` / `-sample N`, `expertHandleSQL` and `expertFinish`
      route the next SQL through the engine at the head of
      runOneSqlLine, and shellMain cleans up an abandoned expert
      handle on exit.  Build clean; 5019/5019 assertions pass.

      Known limitation tracked at the head of passqlite3expert.pas:
      the engine relies on xBestIndex pushdown against the synthetic
      dbv mirror schema, but the Pascal port's CREATE VIRTUAL TABLE
      + OP_ParseSchema reload path surfaces eTabType=0 for the
      re-published vtab in WhereBegin, so whereLoopAddVirtual is
      never reached and pScan stays empty.  Consequence: `.expert`
      runs end-to-end but always reports `(no new indexes)`.  Fix
      is purely upstream of this unit (vtab/eTabType preservation
      in execParseSchemaImpl + sqlite3InitCallback); landing it
      promotes the existing engine to producing real recommendations
      with no changes here.  See 6.13.B.11.

- [X] **10.1c.7** `.expert` dot-command — wired to the ported engine.
      The disabled stub at passqlite3shell.pas:6685 was replaced
      with the real `cmdExpert` (`--verbose`, `--sample N`),
      `expertHandleSQL`, and `expertFinish` helpers from shell.c.in
      §3088..3208.  Output shape and option parsing mirror upstream
      verbatim; the only divergence is the empty index recommendation
      caused by 6.13.B.11.

- [ ] **10.1a.1** fill the next porting chunk here.

### 10.1.bug.* — fixed bug ledger (kept as ticked stubs only)

> Closed bugs: history is in git. Each line below records the slot for
> regression-tracking purposes — re-open the slot if the symptom returns.

- [X] **10.1.bug.1** Header row leak in `.mode list` (QRF tri-state semantics).
- [X] **10.1.bug.103** strftime('%u') ISO weekday off-by-one.
- [X] **10.1.bug.105** ISO 8601 `[+-]HH:MM` timezone suffix dropped.
- [X] **10.1.bug.106** `'localtime'` / `'utc'` date modifiers were no-ops.
- [X] **10.1.bug.107** CREATE UNIQUE INDEX on pre-populated dups silently succeeded (sqlite3VdbeSorterCompare).
- [X] **10.1.bug.108** UNIQUE INDEX with COLLATE NOCASE ignored collation (sqlite3CreateIndex must peel TK_COLLATE).
- [X] **10.1.bug.109** `SELECT * FROM v ORDER BY a,b` with covering UNIQUE index returned `0.0|0.0` rows (nOBSat shortcut must reset bSortOmitRef/nPrefixReg).
- [X] **10.1.bug.110** current_date / current_time / current_timestamp not registered.
- [X] **10.1.bug.111** AUTOINCREMENT counter not consulted (OP_NewRowid missing P3 arm).
- [X] **10.1.bug.112** Star expansion skipped in prior arms of compound (selectExpander must walk pPrior).
- [X] **10.1.bug.113** FROM-subquery coroutine in compound MERGE arms.
- [X] **10.1.bug.114** Numeric-prefix coercion lost decimal/exponent (numericType missing `(rcM and 2)=0` guard).
- [X] **10.1.bug.115** WITH RECURSIVE … LIMIT inside body: ran forever / no rows (recursiveInnerLoop regLimit + iContinue<>0 fix).
- [X] **10.1.bug.116** Correlated subqueries with qualified outer refs failed (resolver order + ResolveOuterRefs walks pEList/pHaving/pGroupBy/pOrderBy + x.pList).
- [X] **10.1.bug.117** min(x)/max(x) over all-NULL returned blob "0.0" (minMaxFinal must check flags<>0, not MEM_Null).
- [X] **10.1.bug.118** shellEPutZ stderr/stdout interleave order (drain Output first).
- [X] **10.1.bug.119** replace(s,p,r) with NULL p or r returned s instead of NULL.
- [X] **10.1.bug.120** Result-set column aliases not visible in WHERE (ResolveAliasInWhere walker).
- [X] **10.1.bug.121** LIMIT/OFFSET ignored on eponymous-vtab fast-arm (must call computeLimitRegisters + codeOffset + DecrJumpZero around VFilter/ResultRow).
- [X] **10.1.bug.122** Aggregates over eponymous-vtab returned empty (isVtabAgg arm must drive xBestIndex).
- [X] **10.1.bug.123** WITH RECURSIVE … ORDER BY dropped (SRT_Queue/SRT_DistQueue dispatch arms).
- [X] **10.1.bug.124** CLI `near line N` off-by-one with comment-interleaved scripts (isPlainWhiteOrComment).
- [X] **10.1.bug.125** Step-error rc was extended code, missing " (rc)" suffix; sqlite3VdbeReset must apply errMask.
- [X] **10.1.bug.126** JSON-function malformed-input errors silently swallowed (jsonConvertTextToBlob + jsonParseFuncArg sinks).
- [X] **10.1.bug.127** ORDER BY+LIMIT silently dropped sort on coroutine FROM (drop pLimit=nil gate; route LIMIT/OFFSET through sort tail). Bonus: signFunc must use numeric_type, not value_type.
- [X] **10.1.bug.128** CLI step-error prefix should be `Error near line N:` (no `Runtime error`, no `(rc)` suffix) — upstream's step-time path.
- [X] **10.1.bug.129** CLI openDb missed `sqlite3_db_config(TRUSTED_SCHEMA=0, DEFENSIVE=1, STMT_SCANSTATUS=0)` from shell.c.in:4530..4537; `PRAGMA trusted_schema;` returned engine default 1 instead of CLI default 0. Regression: bin/TestShellTrustedSchema.
- [X] **10.1.bug.130** `UPDATE T AS t SET col=(SELECT … WHERE inner.col=t.col)` errored "no such column: t.col". sqlite3ResolveExprNames (the lean resolver entry used by UPDATE / DELETE / triggers) skipped subquery descent, so outer-alias TK_DOTs survived into sqlite3SelectPrep which only sees the inner FROM. Fix: post-resolveExprAgainstSrcList walker (`resolveSubqueryOuterRefs`) expands inner pSrc, pre-resolves outer-ref TK_DOTs in inner clauses, and stamps EP_VarSelect + SF_Correlated so codegen re-evaluates per outer row. Recurses through nested subqueries. Regression: bin/TestUpdateCorrelated.
- [X] **10.1.bug.131** Bare-TK_ID outer ref from inside a correlated subquery errored "no such column: X". The SELECT-prep correlation walker handled qualified TK_DOT outer refs but not unqualified TK_ID — so a recursive CTE column referenced inside `EXISTS(...)` (and the .import duplicate-column zRenameRank query) was rejected. Fix: ExprRefsOuterID / ResolveOuterIDs siblings to the existing TK_DOT helpers, wired into the same SELECT-prep block. Inner-scope wins per resolve.c:393..489. Regression: bin/TestCteOuterID.
- [X] **10.1.bug.132** CLI `processInput` cut-gate required `zSql[end]=';'` before calling sqlite3_complete; a trailing `--` comment after `;` left the last char as `r`/whitespace so the buffer kept accumulating subsequent statements into one prepare. Symptom: a parse error on the first statement also swallowed every CREATE/INSERT/SELECT that followed (because they were inside the same over-long prepared text). Upstream shell.c.in:12507 gates on `QSS_SEMITERM(qss) && sqlite3_complete(zSql)` — quickscan treats `;`+trailing-whitespace/comments as semi-terminated. Fix: drop the `;`-precondition and rely on sqlite3_complete alone (complete.c already handles trailing comments). Regression: bin/TestShellSemiComment.
- [X] **10.1.bug.133** CLI `.echo on` was a silent no-op.
- [X] **10.1.bug.134** CLI `.parameter set` populated temp.sqlite_parameters but `bind_prepared_stmt` (shell.c.in:2993..3075) was never ported, so subsequent `SELECT @x` saw NULL. Same gap for `$int_N` / `$text_X` literal-name encodings and `$TIMER`. Fix: port `bindPreparedStmt` and call it after sqlite3_prepare_v2 in runOneSqlLine. Regression: bin/TestShellParameter. The port set `MFLG_ECHO` from `.echo on` and `-echo`, but never wired the `echo_group_input(p,zSql)` emissions upstream issues at shell.c.in:12461..12532 (plain-white swallow, dot/`#` dispatch, full-SQL-cut, leftover at EOF). Fix: add `echoGroupInput` helper in passqlite3shell.pas and call it at the four matching processInput cut points so each non-`.echo` input line is echoed verbatim before it runs. Regression: bin/TestShellEcho.
- [X] **10.1.bug.135** Three `.changes` / `.show` CLI defects. (a) `.changes on` set `SHFLG_CountChanges` but the per-SQL emission at shell.c.in:12356..12361 (`changes: %lld   total_changes: %lld`) was never ported, so the flag was a silent no-op. (b) `cmdShow` mis-ordered the `output:` line — upstream emits it between `nullvalue` and `colseparator` (shell.c.in:11301..11302); the port emitted it after `filename`. (c) `nullvalue` / `colseparator` / `rowseparator` values were rendered with plain `Format('"%s"')` instead of `output_c_string`, so a literal newline appeared instead of `\n` and any control byte was unescaped. (d) `p->mode.autoExplain` defaulted to 0 instead of 1 (modeDefault at shell.c.in:1697), so `.show` reported `explain: off` on a fresh process. Fix: emit changes summary at the end of runOneSqlLine, reorder cmdShow, add `cEscapeStr` AnsiString-returning helper mirroring output_c_string, and seed `p^.mode.autoExplain := 1` in init. Regression: bin/TestShellChanges.
- [X] **10.1.bug.136** Meta dot-command dispatcher sweep (10.1e.G discoveries). Root-cause family: meta-command dispatchers were declared as `procedure` and silently dropped rc, plus several wording/format/array-size drifts vs shell.c.in. Closed under the per-command ticks in 10.1e: (a) `.help` azHelp[] included the `SQLITE_ENABLE_SESSION`-gated block (14 lines / array bound 264→251) — pruned to match non-SESSION C build (shell.c.in:3894..3908). (b) `.show` missing `Usage: .show` for `nArg!=1` (shell.c.in:11271..11275). (c) `.eqp` / `.cd` / `.shell` / `.stats` / `.trace` / `.testctrl` / `.scanstats` / `.timer` / `.log` — all converted from `procedure` → `function: i32` and dispatcher wired to propagate `Result`, so usage / chdir-failure / unknown-option paths now exit rc=1 matching C. (d) `.stats` bare-arg printed `off|on|stmt|vmstep` instead of calling `display_stats`; 1-arg branch now routes unknown values through `parseOnOff` (booleanValue equivalent); usage wording fixed to `?on|off|stmt|vmstep?` (shell.c.in:11324..11339). (e) `.trace` callback emitted wrong STMT/ROW/CLOSE/PROFILE formats vs `sql_trace_callback` (shell.c.in:4886..4940) — rewrote to strip trailing `;` then emit `<SQL>;\n`; `-- closing database connection\n`; `<SQL>; -- <ns> ns\n`; error strings `Unknown option "%s" on ".trace"\n` and `Error: cannot open "%s"\n`; bare `.trace` now uninstalls via `sqlite3_trace_v2(...,0,0,0)`. (f) `sqlite3_test_control(BYTEORDER)` returned 0 instead of `SQLITE_BYTEORDER*100 + LE*10 + BE = 123410` (sqlite3.c:191530..191532). (g) `aTestctrl[]` missing `json_selfcheck` row (bound 18→19); `.testctrl` help dump diverged by one line. (h) `.iotrace` was emitting `Warning: .iotrace not available...` with rc=0; upstream wraps the arm in `#ifdef SQLITE_ENABLE_IOTRACE` so non-debug build falls through to unknown-command rc=1 — dispatcher line dropped. (i) `.selecttrace`/`.wheretrace`/`.treetrace` emitted `Note: .X requires a debug build...`; upstream's `sqlite3_test_control(TRACEFLAGS)` is silent no-op in non-debug — made `cmdTraceFlags` silent rc=0. Regression: bin/TestShellMeta (10.1e.G, 48/48 PASS).

---

## Known regression-test failures (auto-discovered by `run_regression.sh`)

> Ledger entries: when a binary returns to all-green, mark `[X]` and leave
> in place as a fixed-bug record (matching the convention used by 10.1.bug.*).
> Numbering is scoped to the phase that owns the root cause.

- [X] **3.B.regbug.1** TestPagerReadOnly — fixed 2026-05-10 (test-fixture path-resolution defect, not engine bug).
- [X] **6.regbug.1** TestWhereExpr — fixed 2026-05-10 (test-fixture: `pTab^.iPKey` left at 0, must stamp `-1` after `sqlite3DbMallocZero`).

---

## Phase 10.2 — CLI integration parity

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
