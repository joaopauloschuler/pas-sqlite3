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

- [ ] **6.17** OR-decomposed Case-5 codegen + LIKE/GLOB range-bound
      prefix truncation — opened 2026-05-11 from `.archive`/`.ar`
      positional-name filters (see 10.1.46).  Two independent
      sub-bugs sharing the same gate (the .archive filtered flows):

    - [ ] **6.17.A** OR-decomposed Case-5 codegen references an
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

    - [ ] **6.17.B** LIKE/GLOB range-bound prefix truncation never
          reaches `OP_String8`.  Minimal repro:
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

- [~] **10.1a** Skeleton landed; full arg-parser coverage pending under 10.1.3. Gate: `tests/cli/10a_repl/` (not yet created — 10.2 will scaffold it).
- [X] **10.1.1** ShellState record + global state.
- [~] **10.1.2** processInput / oneInputLine REPL core landed; `.echo` plumbing and the upstream `quickscan` state machine deferred.
- [~] **10.1.3** main + process_command_line argument parser — full two-pass parser; process_sqliterc / -init contents loading + memtrace/pcachetrace FILE* sinks still deferred.
- [X] **10.1.4** Line reader (basic LF/CRLF). GNU readline integration deferred.
- [X] **10.1.5** Exit-code mapping + interrupt_handler + SIGINT wiring.
- [X] **10.1.6** do_meta_command dispatcher skeleton.

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

- [ ] **10.1d** Gate: `tests/cli/10d_io/`.
  - [ ] **10.1d.1** `.read` (CSV/ASCII)
  - [ ] **10.1d.2** `.dump` (CSV/ASCII)
  - [ ] **10.1d.3** `.import` (CSV/ASCII)
  - [ ] **10.1d.4** `.output` / `.once`
  - [ ] **10.1d.5** `.save`
  - [ ] **10.1d.6** `.open`

- [X] **10.1.22, 10.1.23, 10.1.25, 10.1.26** `.read FILE`, `.dump` (full), `.output`/`.once`, `.save` all landed.
- [~] **10.1.24** `.import` — auto-create-from-header landed (shellAutoColumnAdd/Finish, shell.c.in:7165..7339); duplicate column renaming now unblocked (bug 10.1.bug.131 closed). Heredoc input and pipe input still deferred.
- [~] **10.1.27** `.open` — handles `-new`, `-readonly`, `-exclusive`, `-ifexists`, `-nofollow`. `--zip` and `--deserialize` deferred until those VFSes/extensions are ported.

### 10.1e Meta / diagnostic dot-commands

- [ ] **10.1e** Gate: `tests/cli/10e_meta/`.
  - [ ] **10.1e.1** `.stats`
  - [ ] **10.1e.2** `.timer`
  - [ ] **10.1e.3** `.eqp`
  - [ ] **10.1e.4** `.explain`
  - [ ] **10.1e.5** `.show`
  - [ ] **10.1e.6** `.help`
  - [ ] **10.1e.7** `.shell`/`.system`
  - [ ] **10.1e.8** `.cd`
  - [ ] **10.1e.9** `.log`
  - [ ] **10.1e.10** `.trace`
  - [ ] **10.1e.11** `.iotrace`
  - [ ] **10.1e.12** `.scanstats`
  - [ ] **10.1e.13** `.testcase`
  - [ ] **10.1e.14** `.testctrl`
  - [ ] **10.1e.15** `.selecttrace`
  - [ ] **10.1e.16** `.wheretrace`

- [X] **10.1.28..10.1.33, 10.1.35, 10.1.37** `.stats`, `.timer`, `.eqp`, `.explain`, `.show`, `.help` (full azHelp[]), `.cd`, `.trace` landed.
- [~] **10.1.34** `.shell`/`.system` — output capture into `.output` sink pending.
- [~] **10.1.36** `.log` — destination recorded; SQLITE_CONFIG_LOG wiring gated on raw-varargs sqlite3_config (8.1.1).
- [X] **10.1.38** `.iotrace` — stub; full sqlite3IoTrace fanout gated on sqlite3VdbeIOTraceSql arm (currently a stub at passqlite3vdbe.pas:4122).
- [~] **10.1.39** `.scanstats` — stub; gated on sqlite3VdbeScanStatus* arms + 8.2.1.
- [~] **10.1.40** `.testcase NAME` — records NAME; `.check ANSWER` comparator side pending.
- [~] **10.1.41** `.testctrl` — dispatcher landed; non-PRNG/BYTEORDER opcodes stub-return 0 (gated on Phase 8.4.1 varargs cdecl boundary).
- [~] **10.1.42** `.selecttrace`/`.wheretrace`/`.treetrace` — emit "requires debug build" breadcrumb. Full wiring needs varargs sqlite3_test_control variant (deferred).

### 10.1f Long-tail / specialised dot-commands

- [ ] **10.1f** Out-of-scope dependencies (session, archive, recover) may stub with the upstream `SQLITE_OMIT_*` "feature not compiled in" message. Gate: `tests/cli/10f_misc/`.
  - [ ] **10.1f.0** `.backup`
  - [ ] **10.1f.1** `.restore`
  - [ ] **10.1f.2** `.clone`
  - [ ] **10.1f.3** `.archive`/`.ar`
  - [ ] **10.1f.4** `.session`
  - [ ] **10.1f.5** `.recover`
  - [ ] **10.1f.6** `.dbinfo`
  - [ ] **10.1f.7** `.dbconfig`
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
- [~] **10.1.46** `.archive`/`.ar` — full port landed; create / list-all / extract-all / insert / update / dryrun all byte-identical with the C oracle (verified 2026-05-11 with `sqlite3 .ar` round-trip).  Two porting bugs closed 2026-05-11: (a) `arWhereClause` non-glob branch wasn't closing the `name IN(..` list (shell.c.in:6581 uses a single template with conditional `)` arg); (b) the `CREATE TABLE sqlar(...)` template was missing the upstream column-purpose comments.  Remaining gap: positional-name filters (`.ar -t/-x/-r name1 [name2 ...]`) build `WHERE (name IN(...) OR (name GLOB '*/*' AND (substr(name,1,N) = 'name/'))) ` — that shape lets the OR-decomposition planner pick two index searches joined via OP_RowSetTest+OP_DeferredSeek, but the Case-5 OR codegen leaves a Column reference on an un-opened cursor (`OP_Column|1` after `OpenRead` only allocates cursors 0,2,3).  Reproduces outside `.archive`: `CREATE TABLE t(name TEXT PRIMARY KEY); INSERT INTO t VALUES('a/b'),('c'); SELECT name FROM t WHERE name='c' OR name>'a';` → EAccessViolation in `OP_Column` reading `pCol^.nField` on a nil cursor.  Independent secondary issue: GLOB-prefix range bounds emit the full pattern (e.g. `'src/dir1/*'`/`'src/dir1/+'`) instead of the truncated prefix bounds (`'src/dir1/'`/`'src/dir10'`), so even no-IN glob filters return zero rows; root cause in `isLikeOrGlob` / range-bound emission — the `zNew[cnt] := #0` truncation never reaches `OP_String8`.  Track both under **bug 6.17** (OR-decomposed Case-5 codegen + LIKE/GLOB range-bound prefix truncation).
- [X] **10.1.47** `.session` — stub (session extension not ported).
- [~] **10.1.48** `.recover` — extension dispatcher landed (passqlite3recover.pas, ~957 lines + LAF arm + wrapper-VFS arm). End-to-end blocked on `WITH RECURSIVE … sqlite_dbptr('getpage()')` returning rows (related to bug 6.13).
- [X] **10.1.49** `.dbinfo`.
- [~] **10.1.50** `.dbconfig` — boolean DBCONFIG_* dispatched. Counter-style and pointer-style ops gated on raw-varargs sqlite3_db_config (8.1.1).
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
