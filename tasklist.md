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

> Closed tasks/bugs are intentionally terse — full postmortems live in git
> history. Re-open a bullet (flip `[X]` → `[ ]`) and re-add detail only if the
> symptom returns.

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
it has a known hang at savepoint rollback (see 6.32).

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
- [X] **6.8.1** sqlite3Update — single-table, UPDATE FROM, vtab dispatch, RETURNING.
- [X] **6.9** sqlite3VdbeRecordCompare / FindCompare full bodies in btree.pas.
- [X] **6.24** Aggregate-with-ORDER-BY codegen.
- [~] **6.26** Window functions (window.c). DiagWindow: 0 divergences. Reopen if DiagWindow regresses.
- [X] **6.27** schema-mutation + statistics. Analyze, Vacuum, RunVacuum, FkCheck/FkActions.
- [ ] **6.28** sweep — re-search for "stub" in the pascal source code and port from C to pascal in full any function or procedure still marked as "stub" that was missed (catch-all). OP_Vacuum, BtreeIncrVacuum done; incrVacuumStep / relocatePage / modifyPagePointer not ported (gated on productive ptrmap).

### Closed bugs (kept as ticked stubs)

- [X] **6.10** TestExplainParity closed.
- [X] **6.11** PRAGMA page_count + DROP TABLE remaining gap closed.
- [X] **6.12** sqlite3Pragma full port; DiagPragma all PASS.
- [X] **6.13** `pragma_foreign_key_list(s.name)` (and other table-valued PRAGMA functions). Sub-bugs A/B/C all closed; lateral join with hidden-arg pushdown wired through `whereLoopAddVirtual` + Case-1 codegen + WhereBegin OP_VOpen. See also subtasks 6.13.B.1..B.10 (all closed).
- [X] **6.14** Compound `SELECT … FROM sqlite_schema … UNION ALL …` — compound dispatch + selectExpander/resolveSelectNames walk pPrior.
- [X] **6.15** TestExplainParity transient regression — resolved on clean rebuild.
- [X] **6.16** Multi-vtab LEFT-JOIN + multi-aggregate AV — fixed by `sqlite3VdbeMakeReady` zero-init (see feedback memory `vdbemakeready_zero_init`).
- [X] **6.17** OR-decomposed Case-5 codegen + LIKE/GLOB range-bound prefix truncation (sub-bugs 6.17.A/B).
- [X] **6.18** pcachetrace / memtrace trampoline AV when sink is non-nil (SQLITE_CONFIG_GETPCACHE2/GETMALLOC arms now call SetDefault before copying methods).
- [X] **6.19** `.open --deserialize` — `sqlite3AppendvfsInit` was FillChar-zeroing apnd_vfs.pNext on every call, severing the VFS chain.
- [X] **6.20** Shim-VFS re-init chain corruption — same FillChar pattern in cksm/vstat/tmstmp/vlog VFS shims; all gated by initialised-Boolean now.
- [X] **6.21** `-memtrace` silent — `sqlite3Malloc` now routes through `sqlite3GlobalConfig.m.xMalloc`; libc bindings renamed to `libc_*`.
- [X] **6.22** Safe-mode error-prefix gap (`data.zErrPrefix = zErrCtx`) — argv-prefix swap ported to `processCommandLine`.
- [X] **6.23** `sqlite3_open_v2` doesn't honor `file:` URI filenames — wired `sqlite3ParseUri` into `openDatabase`; CLI calls `sqlite3_config(SQLITE_CONFIG_URI, 1)`.
- [X] **6.29 / 6.29.followup** `sum(b) OVER ()` / `avg(b) OVER ()` — colUsed propagation across window-rewrite boundary in sqlite3WindowRewrite.

### Open Bugs (re-opened 2026-05-11)

- [ ] **6.30** unix VFS `iVersion = 2` vs upstream `3`. Surfaces in `.vfslist` success-path stdout (deferred from the 10.1f.15 byte-parity gate). Pas `sqlite3_vfs.iVersion` is initialised at `2` in the unix-VFS registration; C upstream `os_unix.c` sets it to `3` (adds `xSetSystemCall`/`xGetSystemCall`/`xNextSystemCall`). Fix: bump iVersion + port the three missing v3 method slots. Gate: extend TestShellMisc `.vfslist` arm to assert stdout parity, not just rc parity.

- [ ] **6.31** Missing unix-VFS locking-style shims (`unix-excl`, `unix-dotfile`, `unix-none`, and the rest of the autolist at `os_unix.c:8200..8240`). Pas registers only the base `unix` VFS, so `.vfslist` shows one entry instead of upstream's full chain. Same root cause as 6.30. Fix: port the per-locking-style auto-registration block; each shim is a thin wrapper that overrides `xOpen` to force a fixed locking method. Gate: `.vfslist` stdout byte-parity.

- [ ] **6.13.B.11** CREATE VIRTUAL TABLE + OP_ParseSchema vtab `eTabType` not preserved across the schema reload. Surfaces as: `.expert` (10.1.101) always reports `(no new indexes)` because the synthetic dbv mirror schema's republished vtabs come back from execParseSchemaImpl with `eTabType = 0`, so `sqlite3WhereBegin` never reaches `whereLoopAddVirtual` and `pScan` stays empty. Fix: stamp `eTabType = TABTYP_VTAB` (and the module pointer) in `execParseSchemaImpl` / `sqlite3InitCallback` when the parsed CREATE was a `CREATE VIRTUAL TABLE`.

- [ ] **6.32** DiagTxn savepoint-rollback hang (pre-existing). Symptom: `ROLLBACK TO sp` after a deep savepoint stack never returns. Root cause not yet investigated; `timeout 10` is the standing workaround so the suite stays green. Fix: bisect against C oracle to find which savepoint-tree walk loops.

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

Each chunk lands with a scripted parity gate that diffs `bin/passqlite3`
against the upstream `sqlite3` binary.  Unported dot-commands must return
the upstream `Error: unknown command or invalid arguments: ".foo"` so
partial landings cannot silently no-op.

### 10.1a Skeleton + arg parsing + REPL loop

- [X] **10.1a** Skeleton landed; gate `tests/cli/10a_repl/` green.
- [X] **10.1.1** ShellState record + global state.
- [X] **10.1.2** processInput / oneInputLine REPL core; quickscan + line-is-terminator + continue-prompt all wired.
- [X] **10.1.3** main + process_command_line two-pass arg parser; `~/.sqliterc`/`-init` loading + `-memtrace`/`-pcachetrace` stderr sinks wired.
- [X] **10.1.4** Line reader (basic LF/CRLF). GNU readline integration deferred.
- [X] **10.1.5** Exit-code mapping + interrupt_handler + SIGINT wiring.
- [X] **10.1.6** do_meta_command dispatcher skeleton.
- [X] **10.1a.G** Gate `src/tests/TestShellRepl.pas` 8/8 PASS. One deferred section: `~/.sqliterc` auto-load (FPC base RTL has no getpwuid; port resolves $HOME only).

### 10.1b Output modes + formatting controls

- [X] **10.1b** Output modes + formatting controls. Gate: `bin/TestShellModes`.
- [X] **10.1.7..10.1.14** `.mode` dispatcher, shell_callback row dispatcher, columnar renderers, `.headers/.separator/.nullvalue/.echo/.changes/.width`, `.print/.parameter`, CSV/JSON/HTML writer helpers all landed.

### 10.1c Schema introspection dot-commands

- [~] **10.1c** Gate: `bin/TestShellSchema`. Multi-result `.tables` / `.indexes`-no-arg / temp-schema side-effects on `.databases` after `.indexes` are pre-existing port divergences and stay out of the gate.
  - [X] **10.1c.1** `.schema` (basic + pattern + `--indent` + `--nosys`)
  - [X] **10.1c.2** `.tables` (single-result + pattern)
  - [X] **10.1c.3** `.indexes` (with table arg)
  - [X] **10.1c.4** `.databases`
  - [X] **10.1c.5** `.fullschema`
  - [X] **10.1c.6** `.lint fkey-indexes` — closed via 6.13.B and 6.16.
  - [X] **10.1c.7** `.expert` (read-only subset) — engine ported in 10.1.101; recommendations degenerate ("(no new indexes)") pending 6.13.B.11.
- [X] **10.1.15..10.1.21** `.schema --indent`, `.tables`, `.indexes`, `.databases`, `.fullschema`, `.lint fkey-indexes`, `.expert` all landed.

### 10.1d Data I/O dot-commands

- [X] **10.1d** Subcommands 10.1.22..10.1.27 landed; gate `src/tests/TestShellIO.pas` 11/11 PASS. One sub-arm deferred: **open-hexdb** (cmdOpen --hexdb still rejects empty filename — TODO inline in TestShellIO.pas).
  - [X] **10.1d.1** `.read`
  - [X] **10.1d.2** `.dump`
  - [X] **10.1d.3** `.import` — auto-create-from-header + duplicate-column renaming + heredoc input (10.1d.3.a) + pipe input (10.1d.3.b) all landed.
  - [X] **10.1d.4** `.output` / `.once` — editor/spreadsheet/browser (`-e`/`-x`/`-w`) variants and `|cmd` pipe targets intentionally not gated; future xdg-open / TProcess follow-up.
  - [X] **10.1d.5** `.save`
  - [X] **10.1d.6** `.open` (full flag set: 10.1d.6.a/b closed).
- [X] **10.1.22..10.1.27** `.read`, `.dump`, `.import`, `.output`/`.once`, `.save`, `.open` (all sub-arms a..g) landed.

### 10.1e Meta / diagnostic dot-commands

- [X] **10.1e** Gate: src/tests/TestShellMeta.pas (10.1e.G, 48/48 PASS) across .help/.show/.eqp/.explain/.cd/.shell/.system/.stats/.trace/.testcase/.testctrl/.iotrace/.scanstats/.selecttrace/.wheretrace/.timer/.log within their deterministic scope. Non-debug-build arms (`.iotrace`, `.selecttrace`, `.wheretrace`) are silent rc=0/rc=1 fall-through to match the undefined SQLITE_DEBUG / SQLITE_ENABLE_IOTRACE / SQLITE_ENABLE_SELECTTRACE C build.
- [X] **10.1.28..10.1.35, 10.1.37** `.stats`, `.timer`, `.eqp`, `.explain`, `.show`, `.help`, `.cd`, `.shell`/`.system`, `.trace` landed.
- [~] **10.1.36** `.log` — destination recorded; SQLITE_CONFIG_LOG wiring gated on raw-varargs sqlite3_config (8.1.1).
- [X] **10.1.38** `.iotrace` — stub; full sqlite3IoTrace fanout gated on sqlite3VdbeIOTraceSql arm (currently a stub at passqlite3vdbe.pas:4122).
- [~] **10.1.39** `.scanstats` — stub; gated on sqlite3VdbeScanStatus* arms + 8.2.1.
- [~] **10.1.40** `.testcase NAME` — records NAME; `.check ANSWER` comparator side pending.
- [~] **10.1.41** `.testctrl` — dispatcher landed; non-PRNG/BYTEORDER opcodes stub-return 0 (gated on Phase 8.4.1 varargs cdecl boundary).
- [~] **10.1.42** `.selecttrace`/`.wheretrace`/`.treetrace` — silent no-op (matches non-debug build); full wiring needs varargs sqlite3_test_control variant (deferred).

### 10.1f Long-tail / specialised dot-commands

- [ ] **10.1f** Out-of-scope dependencies (session, archive, recover) may stub with the upstream `SQLITE_OMIT_*` "feature not compiled in" message. Gate: `tests/cli/10f_misc/`.
  - [X] **10.1f.0..10.1f.2** `.backup` / `.restore` / `.clone` — gated by `src/tests/TestShellBackup.pas`.
  - [X] **10.1f.3** `.archive`/`.ar` — gated by `src/tests/TestShellArchive.pas`.
  - [X] **10.1f.4** `.session` — gated by `src/tests/TestShellArchive.pas` shape arm (stub per 10.1.47).
  - [X] **10.1f.5** `.recover` — gated by `src/tests/TestShellArchive.pas`.
  - [X] **10.1f.6** `.dbinfo` — gated by `src/tests/TestShellDbinfo.pas`. Side-fix: route positional dot-cmd rc through process exit (shell.c.in:13548).
  - [X] **10.1f.7** `.dbconfig` — gated by `src/tests/TestShellDbinfo.pas`. Counter/pointer-style DBCONFIG_* ops still gated on Phase 8.1.1.
  - [X] **10.1f.8** `.filectrl` — gated by `src/tests/TestShellFilectrl.pas`. PERSIST_WAL/POWERSAFE_OVERWRITE skipped (port unix VFS xFileControl lacks those arms).
  - [X] **10.1f.9** `.sha3sum` — gated by `src/tests/TestShellFilectrl.pas`.
  - [X] **10.1f.10..10.1f.13** `.crnl`/`.binary`/`.connection`/`.unmodule` — gated by `src/tests/TestShellMisc.pas`.
  - [X] **10.1f.14..10.1f.16** `.vfsinfo`/`.vfslist`/`.vfsname` — handler-shape parity in `src/tests/TestShellMisc.pas`; success-path stdout byte-parity blocked by 6.30/6.31.

- [X] **10.1.43..10.1.45** `.backup`, `.restore`, `.clone` all landed.
- [X] **10.1.46** `.archive`/`.ar` — full port; closed via bugs 6.17.A/B for GLOB range-bound truncation.
- [X] **10.1.47** `.session` — stub (session extension not ported).
- [X] **10.1.48** `.recover` — full port (~957 lines + LAF arm + wrapper-VFS arm). Sub-arms 10.1.48.a/b/c/d all closed; remaining issue (eTabType reload) tracked in 6.13.B.11.
- [X] **10.1.49** `.dbinfo`.
- [X] **10.1.50** `.dbconfig` — boolean DBCONFIG_* + FP_DIGITS dispatched. Counter/pointer ops gated on 8.1.1.
- [X] **10.1.51..10.1.59** `.filectrl`, `.sha3sum`, `.crnl`, `.binary`, `.connection`, `.unmodule`, `.vfsinfo`/`.vfslist`/`.vfsname`, `.dbtotxt`, `.breakpoint` all landed.

### 10.1.60..10.1.100 — ext/misc and ext/* extension ports (all landed)

All ported as new units under `src/`. Wired via per-unit `sqlite3<Name>Init`
in shell `openDb` unless noted. Common caveat across many eponymous-vtab
ports: bare table-valued or MATCH-style invocations are blocked by bug 6.13
(now closed via 6.13.B); the modules themselves are faithful end-to-end.

- [X] **10.1.60** sha1.c → passqlite3sha1.pas
- [X] **10.1.61** uuid.c → passqlite3uuid.pas
- [X] **10.1.62** ieee754.c → passqlite3ieee754.pas
- [X] **10.1.63** percentile.c → passqlite3percentile.pas
- [X] **10.1.64** rot13.c + uint.c + base64.c
- [X] **10.1.65** totype.c → passqlite3totype.pas
- [X] **10.1.66** base85.c + eval.c + urifuncs.c
- [X] **10.1.67** anycollseq.c + blobio.c + nextchar.c + remember.c + stmtrand.c
- [X] **10.1.68** noop.c + zorder.c + randomjson.c
- [X] **10.1.69** wholenumber.c + templatevtab.c + showauth.c + mmapwarm.c
- [X] **10.1.70** prefixes.c + memstat.c
- [X] **10.1.71** series.c → passqlite3series.pas
- [X] **10.1.72** completion.c → passqlite3completion.pas
- [X] **10.1.73** decimal.c → passqlite3decimal.pas
- [X] **10.1.74** normalize.c → passqlite3normalize.pas
- [X] **10.1.75** regexp.c → passqlite3regexp.pas
- [X] **10.1.76** stmt.c + explain.c
- [X] **10.1.77** qpvtab.c + memtrace.c + pcachetrace.c
- [X] **10.1.78** btreeinfo.c + vtablog.c
- [X] **10.1.79** scrub.c → passqlite3scrub.pas
- [X] **10.1.80** fossildelta.c → passqlite3fossildelta.pas
- [X] **10.1.81** dbdump.c → passqlite3dbdump.pas
- [X] **10.1.82** csv.c → passqlite3csv.pas
- [X] **10.1.83** closure.c → passqlite3closure.pas
- [X] **10.1.84** appendvfs.c → passqlite3appendvfs.pas
- [X] **10.1.85** vfslog.c → passqlite3vfslog.pas
- [X] **10.1.86** fileio.c → passqlite3fileio.pas
- [X] **10.1.87** vfsstat.c → passqlite3vfsstat.pas
- [X] **10.1.88** vfstrace.c → passqlite3vfstrace.pas
- [X] **10.1.89** vtshim.c → passqlite3vtshim.pas
- [X] **10.1.90** cksumvfs.c → passqlite3cksumvfs.pas (VFS shim exported but not auto-installed)
- [X] **10.1.91** unionvtab.c → passqlite3unionvtab.pas
- [X] **10.1.92** fuzzer.c → passqlite3fuzzer.pas
- [X] **10.1.93** tmstmpvfs.c → passqlite3tmstmpvfs.pas (NOT auto-installed)
- [X] **10.1.94** amatch.c → passqlite3amatch.pas
- [X] **10.1.95** compress.c + sqlar.c (libz via cdecl, `-k-lz`)
- [X] **10.1.96** ext/intck/sqlite3intck.c → passqlite3intck.pas
- [X] **10.1.97** ext/recover/dbdata.c → passqlite3dbdata.pas
- [X] **10.1.98** zipfile.c → passqlite3zipfile.pas
- [X] **10.1.99** spellfix.c → passqlite3spellfix.pas
- [X] **10.1.100** Built-in shell SQL UDFs: strtod, dtostr, shell_add_schema, shell_module_schema, shell_putsnl, usleep. editFunc deferred.
- [X] **10.1.101** `ext/expert/sqlite3expert.c` → `passqlite3expert.pas`. Known limitation: degenerate recommendations pending 6.13.B.11.
- [X] **10.1.102** `.open --zip` / `--deserialize` / `--hexdb` shell glue + faithful `sqlite3_deserialize` port.

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
- [X] **10.1.bug.115** WITH RECURSIVE … LIMIT inside body: ran forever / no rows.
- [X] **10.1.bug.116** Correlated subqueries with qualified outer refs failed (resolver order + ResolveOuterRefs walk).
- [X] **10.1.bug.117** min(x)/max(x) over all-NULL returned blob "0.0" (minMaxFinal flag check).
- [X] **10.1.bug.118** shellEPutZ stderr/stdout interleave order (drain Output first).
- [X] **10.1.bug.119** replace(s,p,r) with NULL p or r returned s instead of NULL.
- [X] **10.1.bug.120** Result-set column aliases not visible in WHERE (ResolveAliasInWhere walker).
- [X] **10.1.bug.121** LIMIT/OFFSET ignored on eponymous-vtab fast-arm.
- [X] **10.1.bug.122** Aggregates over eponymous-vtab returned empty (isVtabAgg must drive xBestIndex).
- [X] **10.1.bug.123** WITH RECURSIVE … ORDER BY dropped (SRT_Queue/SRT_DistQueue dispatch).
- [X] **10.1.bug.124** CLI `near line N` off-by-one with comment-interleaved scripts.
- [X] **10.1.bug.125** Step-error rc was extended code, missing " (rc)" suffix; sqlite3VdbeReset must apply errMask.
- [X] **10.1.bug.126** JSON-function malformed-input errors silently swallowed.
- [X] **10.1.bug.127** ORDER BY+LIMIT silently dropped sort on coroutine FROM. Bonus: signFunc must use numeric_type, not value_type.
- [X] **10.1.bug.128** CLI step-error prefix should be `Error near line N:` (no `Runtime error`, no `(rc)` suffix).
- [X] **10.1.bug.129** CLI openDb missed `sqlite3_db_config(TRUSTED_SCHEMA=0, DEFENSIVE=1, STMT_SCANSTATUS=0)`. Regression: bin/TestShellTrustedSchema.
- [X] **10.1.bug.130** `UPDATE T AS t SET col=(SELECT … WHERE inner.col=t.col)` errored "no such column: t.col". Regression: bin/TestUpdateCorrelated.
- [X] **10.1.bug.131** Bare-TK_ID outer ref from inside a correlated subquery errored. Regression: bin/TestCteOuterID.
- [X] **10.1.bug.132** CLI `processInput` cut-gate required `zSql[end]=';'` before sqlite3_complete; trailing `--` comment caused statement-merging. Regression: bin/TestShellSemiComment.
- [X] **10.1.bug.133** CLI `.echo on` was a silent no-op.
- [X] **10.1.bug.134** CLI `.parameter set` populated temp.sqlite_parameters but `bind_prepared_stmt` was never ported. Also wired echo_group_input emissions at the four matching processInput cut points. Regression: bin/TestShellParameter, bin/TestShellEcho.
- [X] **10.1.bug.135** `.changes` / `.show` defects: per-SQL emission, `output:` line ordering, `output_c_string` escaping, `autoExplain` default. Regression: bin/TestShellChanges.
- [X] **10.1.bug.136** Meta dot-command dispatcher sweep (10.1e.G): `procedure→function: i32` conversions to propagate rc, wording/format/array-size drifts. Regression: bin/TestShellMeta.

---

## Known regression-test failures (auto-discovered by `run_regression.sh`)

> Ledger entries: when a binary returns to all-green, mark `[X]` and leave
> in place as a fixed-bug record (matching the convention used by 10.1.bug.*).
> Numbering is scoped to the phase that owns the root cause.

- [X] **3.B.regbug.1** TestPagerReadOnly — fixed 2026-05-10 (test-fixture path-resolution defect).
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

- [ ] **11.9** Profiling hand-off to Phase 9.  Wrapper scripts that
  run `passpeedtest1` under `perf record` and
  `valgrind --tool=callgrind`, plus a small Pascal helper that
  annotates the resulting reports against `passqlite3*.pas` source
  lines.  Output of this task is the input of 9.1.

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
