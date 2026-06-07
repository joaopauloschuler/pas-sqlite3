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
`LD_LIBRARY_PATH=src/ bin/<TestName>`.

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

> Closed-task postmortems live in git history.  This file keeps task IDs +
> one-line outcomes + key cites only.

## Phase 5 — carry-overs

- [X] **5.7.b** PMA disk-spill port COMPLETE
  - [X] **5.7.b.1** Sorter struct decls
  - [X] **5.7.b.2** Temp-file plumbing
  - [X] **5.7.b.3** `PmaWriter`
  - [X] **5.7.b.4** `PmaReader` read primitives
  - [X] **5.7.b.5** In-memory engine rebased 1:1 onto C
  - [X] **5.7.b.6** `MergeEngine` aTree[] tournament
  - [X] **5.7.b.7** Single-threaded `IncrMerger`
  - [X] **5.7.b.8** Tree build + merge setup
  - [X] **5.7.b.9** Public-API PMA arms wired
  - [X] **5.7.b.10** Verify

---

## Phase 6 — Code generators (close the EXPLAIN gate)

> TestExplainParity reports **1026 / 1026 PASS** as of 2026-05-06 (a3).

- [X] **6.8.0..6.8.6** Pragma vtab register, GenerateConstraintChecks
- [X] **6.8.1** sqlite3Update
- [X] **6.9** sqlite3VdbeRecordCompare / FindCompare full bodies in btree.pas
- [X] **6.24** Aggregate-with-ORDER-BY codegen
- [~] **6.26** Window functions (window.c). DiagWindow: 0 divergences. Reopen if DiagWindow regresses.
- [X] **6.27** schema-mutation + statistics
- [~] **6.28** sweep — re-search for "stub" in the pascal source code and port from C to pascal in full any function or procedure still marked as "stub" that was missed (catch-all). OP_Vacuum, BtreeIncrVacuum done; incrVacuumStep / relocatePage / modifyPagePointer not ported (gated on productive ptrmap). Inventory landed at `src/tests/STUB_INVENTORY.md` (21 actionable entries: 7 high / 6 med / 8 low). One small high-priority entry ported in 6.28 commit (`pas_openDirectory`, os_unix.c:3874..3894 → src/passqlite3os.pas:2331). Doable subtasks for the remaining six high-priority stubs (each cites the open Phase-6/9 bullet it blocks; see STUB_INVENTORY.md for full Pascal/C citations):
  - [X] **6.28.1** `whereLoopAddVirtual` deeper arms
  - [X] **6.28.2** `sqlite3OpenTableAndIndices` full body
  - [X] **6.28.3** `sqlite3NestedParse` body ported
  - [X] **6.28.4** `sqlite3AddColumn` drift arms
  - [X] **6.28.5** `sqlite3LimitWhere`
  - [X] **6.28.6** `OP_IntegrityCk` body + `sqlite3BtreeIntegrityCheck`
  - [X] **6.28.6.b** Higher-level `PRAGMA integrity_check` walk arms
  - [X] **6.28.6.a** PRAGMA integrity_check/quick_check wired to emit real
  - [X] **6.28.6.c** vtab xIntegrity dispatch
    - [~] **6.28.6.c.1** ~~FK referential walk~~ DROPPED 2026-05-13 — phantom cite (integrity_check carries no FK walk; PRAGMA foreign_key_check is separate). Archive.
    - [X] **6.28.6.c.2** vtab `xIntegrity` dispatch
  - [X] **6.28.7** `getRowTrigger` / `codeRowTrigger`
  - [X] **6.28.8** Audit pass on high-priority STUB_INVENTORY entries
  - [X] **6.28.9** Medium-priority audit pass
  - [X] **6.28.10** Low-priority audit pass

### Closed bugs (kept as ticked stubs)

- [X] **6.10** TestExplainParity closed
- [X] **6.11** PRAGMA page_count + DROP TABLE remaining gap closed
- [X] **6.12** sqlite3Pragma full port
- [X] **6.13** `pragma_foreign_key_list(s.name)`
- [X] **6.14** Compound `SELECT … FROM sqlite_schema … UNION ALL …`
- [X] **6.15** TestExplainParity transient regression
- [X] **6.16** Multi-vtab LEFT-JOIN + multi-aggregate AV
- [X] **6.17** OR-decomposed Case-5 codegen + LIKE/GLOB range-bound prefix
- [X] **6.18** pcachetrace / memtrace trampoline AV when sink is non-nil
- [X] **6.19** `.open --deserialize`
- [X] **6.20** Shim-VFS re-init chain corruption
- [X] **6.21** `-memtrace` silent
- [X] **6.22** Safe-mode error-prefix gap
- [X] **6.23** `sqlite3_open_v2` doesn't honor `file:` URI filenames
- [X] **6.29 / 6.29.followup** `sum(b) OVER
- [X] **6.30** unix VFS iVersion bumped to 3
- [X] **6.31** unix-VFS locking-style shims
- [X] **6.13.B.11** `.expert` `(no new indexes)`

### Open Bugs (re-opened 2026-05-11)

- [X] **6.32** DiagTxn savepoint-rollback hang

### 6.40 — Unported feature/extension gaps surfaced by Tcl sweep (2026-05-22)

> Each bullet is a Tcl `.test` failure whose *root cause is a missing ported
> feature*, not a runtime divergence. Counts are occurrences across the
> 2026-05-22 full-suite run (612 pass / 347 fail). "ENGINE" = real library
> feature to port; "EXT" = loadable/test extension to register; "HARNESS" =
> testfixture-only Tcl command. Port the C source 1:1 as usual; for HARNESS
> entries the C lives in `../sqlite3/src/test*.c` and is registered through the
> Tcl bridge (`src/tests/tcl/testmodules/`), not the engine.

- [~] **6.40.1** **FTS3/FTS4 full-text search** (ENGINE/EXT, XL; ~21 kLOC across `../sqlite3/ext/fts3/`). All of fts3.c/fts3_*.c ported into `src/passqlite3fts3.pas` and auto-registered from `sqlite3Fts3Init` at openDatabase (.a..o all DONE). fts3/fts4/fts4aux/fts3tokenize modules + fts3_tokenizer(_test) funcs + the fts3_test.c Tcl harness all live; the `fts3` capability is flipped on. Core FTS works (35 fts .test files PASS pas-strict + basic MATCH/phrase/NEAR/snippet/offsets/matchinfo/prefix/aux all green, oracle-diff'd). STAYS `[~]`: ~50 fts files remain pas-soft on three documented residual classes — (1) order=desc doclist hang/corruption (6.40.1.o.1), (2) heavy-segment-merge build perf timeouts (6.40.1.o.2), (3) assorted per-file edge cases (6.40.1.o.3). Reopen-to-strict as those residuals close.
  - **Cluster A — tokenizer subsystem (the easy wins; entirely independent of the 12 kLOC segment/vtab core).** Each item drives the `sqlite3_tokenizer_module` vtable directly, so each is unit-testable in isolation against the C oracle via a small `DiagFts3Tok` probe — no FTS vtab needed. Landing all of Cluster A flips the two biggest buckets: `fts3_tokenizer_test` (77) and `fts3tokenize` (2).
    - [X] **6.40.1.a** ABI skeleton landed in new unit
    - [X] **6.40.1.b** `fts3_hash.c` ported
    - [X] **6.40.1.c** `fts3_tokenizer1.c` 1:1
    - [X] **6.40.1.d** `fts3_porter.c` 1:1
    - [X] **6.40.1.e** `fts3_unicode2.c` ported verbatim
    - [X] **6.40.1.f** `fts3_unicode.c` "unicode61" tokenizer ported
    - [X] **6.40.1.g** fts3_tokenizer.c ported into passqlite3fts3.pas
    - [X] **6.40.1.h** `fts3_tokenize_vtab.c` ported into passqlite3fts3.pas
    - [X] **6.40.1.i** `fts3_expr.c` ported into passqlite3fts3.pas
    - [X] **6.40.1.j** `fts3_write.c`
    - [X] **6.40.1.k** fts3.c fts3/fts4 vtab module ported into
      - [X] **6.40.1.k.1** FTS4 key=value option parser ported
      - [X] **6.40.1.k.2** %_docsize/%_stat DDL in fts3CreateTables
      - [X] **6.40.1.k.3** FTS4 feature tests run under the cap flip
    - [X] **6.40.1.l** `fts3_snippet.c` ported into passqlite3fts3.pas
    - [X] **6.40.1.m** `fts3_aux.c` ported into passqlite3fts3.pas
    - [X] **6.40.1.n** `fts3_term.c` ported
    - [X] **6.40.1.o** Wiring + cap flip + sweep DONE
      - [X] **6.40.1.o.1** order=desc / docid-update doclist residual CLOSED
        - [X] **6.40.1.o.1.1** TestFts3DescUpdate.pas added
        - [X] **6.40.1.o.1.2** Reverse-poslist reader, not pending arm: final
        - [X] **6.40.1.o.1.3** Fixed `fts3ReversePoslist`
        - [X] **6.40.1.o.1.4** Promoted fts4docid + tkt-bdc6bbbb38 + orderby7
        - [X] **6.40.1.o.1.5** fts3aa-10.1 fixed → pas-strict
      - [X] **6.40.1.o.3** misc per-file FTS edge-case fails
        - [X] **6.40.1.o.3.1** corruption-detection: fts3corrupt +
        - [X] **6.40.1.o.3.2** fault-injection/OOM: all three demoted with
        - [X] **6.40.1.o.3.3** eval output: fts3snippet + fts3rank PASS
        - [X] **6.40.1.o.3.4** content/notindexed/external-content: all
        - [X] **6.40.1.o.3.5** DDL: fts3drop + fts3dropmod PASS
        - [X] **6.40.1.o.3.6** conflict/upsert + misc: all demoted with cause
        - [X] **6.40.1.o.3.7** fts3 acceptance-suite chunks
        - [X] **6.40.1.o.3.8** fts3shared
    - [X] **6.40.1.p** Replaced 5 libc externals in passqlite3fts3.pas with
    - [X] **6.40.1.p.2** DONE
      - [X] **6.40.1.p.2.1** `passqlite3util.pas`: removed
      - [X] **6.40.1.p.2.2** Removed `libc_strcmp`/`libc_atoi`
      - [X] **6.40.1.p.2.3** Removed strlenC/strcmpC/strncmpC/memcmpC
      - [X] **6.40.1.p.2.4** Removed strlenC/strcmpC/memcmpC externals
      - [X] **6.40.1.p.2.5** spellfix: strlen→StrLen
      - [X] **6.40.1.p.2.6** Replaced libc_qsort external with `fts3Qsort`
- [X] **6.40.2** ICU extension
- [X] **6.40.3** preupdate_hook
- [~] **6.40.4** Loadable extensions for `load_static_extension` — DONE: extended the existing aExtension[] table (TestModuleTest1.pas:581 tclLoadStaticExtensionCmd, mirrors test1.c:8406) from 11→23 names by wiring the already-ported sqlite3*Init shims: series/spellfix/closure/csv/fuzzer/prefixes/randomjson/appendvfs/amatch/nextchar/remember/unionvtab. All now load (was "no such extension"). prefixes/fuzzer1/fuzzer2/json108 now PASS; series/csv/spellfix/closure/randomjson/appendvfs load OK but tests still FAIL on deeper pre-existing engine bugs (tabfunc01 hangs at 1.7 4-arg series-arg rejection; join8 SIGSEGV at 9000; csv01/spellfix2/json106 deeper). All flagged tests were baseline-FAIL (errored on the first `load_static_extension` line), so no NEW pas-strict regression. TODO: port `register_fs_module` (vtabH, test_fs.c 920L) + `register_schema_module` (test_schema.c 367L) — full vtab-module ports (tracked as 9.4.port.fs-schema-vtab). (`echo` already works via register_echo_module, test8.c; swarmvtab2 PASS.)
- [X] **6.40.5** `sqlite3_prepare_v3` Tcl trampoline
- [~] **6.40.6** Crash/pager/IO harness cmds. DONE: `btree_pager_stats` (test3.c:147→TestModuleTest1; needed engine `sqlite3PagerStats` pager.c:6854 + `sqlite3PcacheGetCachesize` pcache.c:855 + new `Pager.nRead` field & PAGER_INCR at pager.c:3068); `sqlite3_pager_refcounts` (test1.c:6558); `pcache_stats` (test1.c:7573 + engine `sqlite3PcacheStats` pcache1.c:1261); `uses_stmt_journal` (test1.c:3060); `extra_schema_checks` (test1.c:7522); `file_control_powersafe_overwrite` (test1.c:7190); pure-Tcl `catchcmd`/`catchsafecmd`/`catchcmdex`/`dumpbytes` (tester.tcl:821-871) + `allcksum` (tester.tcl:2145) into tester_min.tcl. Results: cache.test 2→189 subtests (4 residual = pre-existing PRAGMA cache_size=0 readback bug), incrblob 12→7 err, pcache.test/fkey8.test PASS, ioerr2 now runs 3528 subtests (1 residual = unrelated dir-perms test). No NEW pas-strict regression (cache/incrblob were already baseline-FAIL stale-strict; both improved). TODO: port `crash_on_write` (test6.c:984, needs devsym VFS test_devsym.c); `btree_open` (test3.c:36 standalone Btree harness); `sqlite3_config_heap`/`mutex_counters`/`sorter_test_*`/`clock_seconds`/`isquick` (separate subsystems).
- [X] **6.40.7** Snapshot Tcl trampolines NOT registered
- [X] **6.40.8** Misc test SQL fns: added test_setsubtype/test_getsubtype to
- [~] **6.40.9** WAL/blob harness cmds: ported blob_reopen, wal_checkpoint_v2, mmap_warm, interrupt, is_interrupted, utf8_to_utf8 + utf8To8Inplace (TestModuleTest1.pas; test1.c:1824/5984/6005/7685/8734, test_hexio.c:306). incrblob3 29→4 err, badutf2/mmapwarm cmds pass. TODO: port quota_glob (test_quota.c VFS shim — large).

> NOTE (2026-05-22): securedel.test failures are NOT an engine porting gap — the
> engine returns the correct `secure_delete` propagation when driven via the CLI;
> the residual `{1 0}` is a Tcl-bridge prepared-statement-caching interaction with
> codegen-time pragma side effects. Track separately if pursued.

---

## Phase 7 — Parser

- [X] **7.1.1** Schema initialisation
- [X] **7.1.2** sqlite3NestedParse full driver
- [X] **7.1.8** ATTACH / DETACH
- [X] **7.1.9** ALTER TABLE
- [X] **7.4b** TestBytecodeParity gate landed
- [X] **7.4c** TestVdbeTrace differential opcode-trace gate
- [X] **7.4d** WITHOUT ROWID runtime corruption
- [X] **7.4e** Bare-bareword INSERT → no-such-column error wired in resolver

---

## Phase 8 — Public API

Public-API gap analysis: `../sqlite3/src/sqlite.h.in` exports
~238 `sqlite3_*` symbols; the Pascal port currently exposes ~156.
Windows-only entry points (`sqlite3_win32_*`) and pure typedefs are excluded.

- [X] **8.4.1** sqlite3_test_control full varargs coverage
- [X] **8.2.1** sqlite3VdbeScanStatus + ScanStatusRange + ScanStatusCounters
- [X] **8.1.1** sqlite3_config / sqlite3_db_config full varargs coverage
- [X] **8.9.2** Carray / shared-cache / misc
- [X] **8.x** unixCurrentTimeInt64
- [X] **8.10** Public-API sample-program gate
- [X] **8.x.colneed** sqlite3_collation_needed callback fires
- [X] **8.x.memused** db^.pnBytesFreed dry-run accounting honoured

---

## Phase 9 — Acceptance: differential + fuzz

> **a4 session 2026-06-04 (pas-soft sweep):** Verified-and-FIXED — `reservebytes` 3→0
> (full `sqlite3BtreeSetPageSize` port incl. `nReserveWanted`, btree.c:3069..3100; 7b5c5e0);
> `shell2` 10→3 / `shell3` 1→0 (CLI: `.header` abbrev, case-insens on/off, `-safe` auth,
> hexdb `%x` parse; c39a82a — NOTE shell tests need `TESTFIXTURE_HOME=$(pwd)/bin` or
> runtest.sh measures /usr/bin/sqlite3); `corrupt2` 3→1 (dup-index schema via INITFLAG_FreshLoad
> + flipped-page-type seek leaving *pRes=0, btree.c:5945; cd9b1ca); `e_fkey` 10→4
> (INSERT…SELECT into parent must keep isMultiWrite so sqlite3FkLocateIndex runs, insert.c:1018;
> 583ecfc).  WATER-LEAKS (root-caused, reverted, do NOT re-pick as quick wins):
> `pushdown-6.x` needs IN-RHS subroutine-dedup/bloom machinery (not yet implemented at codegen 74088; → 9.4.port.coroutine-from);
> `pushdown-3.6`/`select9-4.5` flatten a compound view C keeps as CO-ROUTINE (affinity restriction-17h);
> `aggnested-10.1` needs NameContext `pNC->nRef` correlation accounting (port uses bespoke passes
> that don't descend into expr-subqueries); `update-21.12` flattens a windowed CTE (no auto-idx/bloom);
> `corruptN-6.3`/`corruptK-3.3` need deeper btree cell-overflow / cursor-save corruption checks.
> Many other pas-soft files now pass (joinC, windowE, collate4, count, etc.) — tasklist notes stale.

Each 9.x lands a self-contained gate.  All four use the same C oracle:
`libsqlite3.so` from `../sqlite3/` (already built by `src/tests/build.sh`).
Pascal output → C output diff is the only pass criterion; any deviation
is a port bug (see top of file).  All gates must run unattended under
`src/tests/build.sh` and exit non-zero on first divergence so CI catches
regressions without human triage.

### 9.1 `TestSQLCorpus.pas` — full SQL corpus differential

- [X] **9.1.1** Corpus inventory

- [X] **9.1.2** Oracle runner helper

- [~] **9.1.3** `TestSQLCorpus.pas` skeleton — iterate MANIFEST, run both oracles, byte-compare all four channels; first diverging file prints summary and exits non-zero. Gate: `bin/TestSQLCorpus` rc=0. Skeleton landed 2026-05-12; full coverage delivered by 9.1.3.followup.

- [X] **9.1.3.followup** Full MANIFEST coverage via `SQLLiteralExtractor.pas`

- [X] **9.1.4** Determinism scrub
  - [X] **9.1.divbug.1** RELEASE-without-SAVEPOINT errmsg
  - [X] **9.1.divbug.2** PRAGMA mmap_size / journal_mode output shape
  - [X] **9.1.divbug.3** DROP INDEX errmsg truncation
  - [X] **9.1.divbug.4..8** Five sites, single root cause

- [X] **9.1.5** Corpus status tags landed in `src/tests/corpus/STATUS.txt`

- [X] **9.1.6** Coverage check

### 9.2 `TestReferenceVectors.pas` — canonical `.db` snapshots

- [X] **9.2.1** Vector inventory

- [~] **9.2.2** Read-only parity probe — `bin/TestVectorReadOnly` + per-vector `*.queries.sql` (11 vectors). Bucket-A FIXED in 9.2.divbug.A (btreeBeginTrans wrflag gate); the unioned pas-skip list now covers bucket-F (autovacuum/incrvacuum), bucket-G (utf16), bucket-H (withoutrowid), bucket-I (wal/multipage/generated-column round-trip drift) and bucket-J (triggers round-trip crash) plus bucket-C/E for view-cte/partial-index — but those buckets affect 9.2.3/9.2.4 only.  RO probe today: gated=1 ok=1 diverged=0 skipped=10 rc=0; the actual fix lifted SQLITE_READONLY for every vector and the remaining skips are pre-existing non-RO bugs surfaced after bucket-A was lifted.

- [~] **9.2.3** Round-trip probe — `bin/TestVectorRoundTrip` + per-vector `<name>.mutate.sql` (11 mutators each exercising the vector's feature). Re-uses `CorpusOracle.ApplyHeaderMask`. Today (post-9.2.3.followup, cite-aware RT filter): gated=8 ok=8 diverged=0 skipped=3 rc=0.  Remaining skips: autovacuum (bucket-L, also bucket-B for schema-change), incrvacuum (bucket-L), utf16 (bucket-M, also bucket-K for RO).  Bucket-A umbrella lifted; bucket-I (4-vector RT cell-layout drift) closed; bucket-J (triggers RT crash) closed.

- [~] **9.2.4** Schema-change probe — `bin/TestVectorSchemaChange` + per-vector `<name>.schema.sql` (8 vectors). Opens RW so does NOT inherit bucket-A; surfaced 4 new buckets (B/C/D/E — see 9.2.divbug.* below). 9.2.divbug.C closed (view-cte rename arm), 9.2.divbug.E closed (partial-index RENAME COLUMN aColExpr pin), but both view-cte and partial-index still hit bucket-B at the trailing VACUUM so they stay pas-skip. Today: gated=1 ok=1 diverged=0 skipped=7 rc=0.

- [X] **9.2.5** Vector regen script
  - [X] **9.2.divbug.A** RO-open trips `SQLITE_READONLY`
  - [X] **9.2.divbug.F** PRAGMA auto_vacuum returns 0 on RO-open
  - [X] **9.2.divbug.G** PRAGMA encoding garbled on UTF-16 RO
  - [X] **9.2.divbug.H** WITHOUT ROWID count(*) fast path → CORRUPT
  - [X] **9.2.divbug.I** Round-trip cell-layout drift
  - [X] **9.2.divbug.J** Round-trip trigger-fire EAV
  - [X] **9.2.divbug.B** Bare `VACUUM;` EAccessViolation
  - [X] **9.2.divbug.C** ALTER TABLE RENAME on VIEW-dependent table → EAV
  - [X] **9.2.divbug.D** CREATE INDEX on WITHOUT ROWID byte-different
  - [X] **9.2.divbug.E** RENAME COLUMN on partial-index byte-different
  - [X] **9.2.divbug.K** UTF-16 `hex()` byte-swapped
  - [X] **9.2.divbug.L** Auto-vacuum round-trip page-count drift
  - [X] **9.2.divbug.L.1** Port `incrVacuumStep`
  - [X] **9.2.divbug.L.2** Port `relocatePage` + `modifyPagePointer`
  - [X] **9.2.divbug.L.3** Wire `autoVacuumCommit` body
  - [X] **9.2.divbug.M** ~~UTF-16 INSERT raw-UTF-8~~ CLOSED
  - [X] **9.2.divbug.N** ~~Freeblock zeroing~~ CLOSED

- [X] **9.2.3.followup** Round-trip parser cite-aware

- [X] **9.1.6.followup** Categorize 47 cold opcodes

### 9.3 `TestFuzzDiff.pas` — differential fuzzer

- [X] **9.3.1** In-process harness

- [X] **9.3.2** Seed corpus import

### 9.4 SQLite Tcl test suite as alternate target

> Reorganised 2026-05-13: each umbrella bullet (9.4.1 .. 9.4.5) is
> immediately followed by its decomposed sub-arms; trailing
> `9.4.divbug.N` cluster bullets sit at the end in numeric order
> (matching `src/tests/tcl/DIVERGENCES.md`).
>
> **Timing & timeout rules (read before launching a run — 2026-05-16).**
> The driver applies a **20 s per-test watchdog**; the full MANIFEST
> (~959 entries) takes ~25 min unsharded and will be killed by any
> 20-min outer wall-clock (CI, `timeout`, agent harnesses).  Always
> shard 4-way — but **run the shards sequentially, never in parallel**:
> concurrent shards OOM-kill each other (silent partial results) due to
> stacked page caches + per-shard `libpassqlite3tcl.so` + tclsh
> footprints on a typical workstation.  Sequential 4-shard cost is
> ~25–60 min wall-clock.  See `README.md` → "Upstream Tcl test suite"
> for the exact command.  The same rule applies to running multiple
> `bin/Test*` binaries — `run_regression.sh` is already sequential;
> keep manual invocations the same way.  Three test files currently exceed the
> watchdog and **burn the entire shard-2 budget** if left in:
> `pragma4.test`, `printf.test`, `securedel.test` (tracked as
> `9.4.divbug.86`; sibling `.84` covers `select4.test` /
> `writecrash.test` / `securedel2.test`).  Until those are fixed or
> moved to `src/tests/tcl/SKIP.md`, shard 2 will not complete under
> 25 min — accept the partial result or skip them.  Most `FAIL` lines
> in shard logs are `pas-soft` and already cited in `STATUS.txt`; the
> only signal that matters is `REGRESSION (pas-strict FAIL): <path>`
> from `src/tests/tcl/check_status_regression.sh`.

- [X] **9.4.1** Inventory
  - [X] **9.4.1.a** Inventory script `src/tests/tcl/inventory.sh`

- [~] **9.4.2** Tcl binding shim.  Reuse / port the minimum of
  `../sqlite3/src/tclsqlite.c` (~6000 C lines total, but only a
  small subset is needed) so the upstream `interp` can attach to
  passqlite3 via the same `sqlite3` Tcl command.  Realistic complexity:
  **M** for the minimal `sqlite3 db1 :memory:` + `db eval` + `db close`
  trio that unblocks ~80% of `tcl-feature`; **L** if `db function` /
  `db trace` / `db authorizer` callbacks also need wiring (many
  feature tests use them).  Pre-requisite: a working
  FPC↔Tcl bridge (likely `tcl.pp` from fpc-extras or a hand-rolled
  cdecl binding to libtcl).  Sub-step before any porting: port
  `../sqlite3/test/tester.tcl` dependencies — it's the common harness
  every `.test` file loads via `source $testdir/tester.tcl`, and it
  pulls in `do_test` / `do_execsql_test` / `expected` / etc.  Without
  tester.tcl no `.test` file runs.
  - [X] **9.4.2.0** Plan doc `src/tests/tcl/PLAN.md`
  - [X] **9.4.2.a** Bridge unit
  - [X] **9.4.2.b** `Sqlite3_Init` exporter
  - [X] **9.4.2.c** `sqlite3 db1 :memory:` constructor
  - [X] **9.4.2.d** `db eval $sql`
  - [X] **9.4.2.e** `db version` / `changes` / `last_insert_rowid`
  - [X] **9.4.2.f** `db function NAME ?-argcount N? proc`
  - [~] **9.4.2.g** `tester_min.tcl` — `src/tests/tcl/tester_min.tcl`
    re-exports just `do_test`, `do_execsql_test`, `execsql`,
    `expected`, `set_test_counter`, `finalize_testing`, and the global
    `db` handle — enough to source a hand-picked simple `.test` file.
    Body adapted from `../sqlite3/test/tester.tcl:703..` and `941..`.
    Smoke gate `bin/TestTclTesterMin` sources tester_min.tcl + runs
    `do_test foo-1.0 {expr 1+1} 2`.  Remaining helpers tracked in
    9.4.2.g.1.
  - [X] **9.4.2.g.1** `ifcapable`
  - [X] **9.4.2.g.2** `catchsql` + `do_catchsql_test`
  - [X] **9.4.2.g.3** `finish_test` + `forcedelete` + `delete_file`
  - [X] **9.4.2.g.4** `integrity_check`
  - [X] **9.4.2.g.5** `working_64bit_int` + `presql` + `omit_test`
  - [X] **9.4.2.g.6** `do_eqp_test`
  - [X] **9.4.2.g.7** `do_test` glob/regexp/numeric-range forms +
  - [X] **9.4.2.g.8** `permutations.tcl` skip-shim
  - [X] **9.4.2.g.9** `do_malloc_test` ported verbatim into `tester_min.tcl`
  - [X] **9.4.2.g.10** `do_ioerr_test` + `run_ioerr_prep` ported verbatim into
  - [X] **9.4.2.g.11** `crashsql` Tcl proc
  - [X] **9.4.2.g.12** `db_save_and_close` / `db_restore_and_reopen` +
  - [X] **9.4.2.g.13** `*_common.tcl` source-include shims
  - [X] **9.4.2.g.14** `tester_min.tcl` config vars
  - [X] **9.4.2.h** `db eval` 3-arg form
  - [X] **9.4.2.i** `db trace` / `db trace_v2` / `db profile`
  - [X] **9.4.2.j** `db authorizer`
  - [X] **9.4.2.k** `db busy` + `db progress` + `db interrupt`
  - [X] **9.4.2.l** `db update_hook` / `db commit_hook` / `db rollback_hook`
  - [X] **9.4.2.m** `db collate` + `db collation_needed`
  - [X] **9.4.2.n** `db transaction { script }`
  - [X] **9.4.2.o** `db total_changes` / `db onecolumn
  - [X] **9.4.2.p** `db incrblob`
  - [X] **9.4.2.q** `db backup` / `db restore`
  - [X] **9.4.2.r** `db serialize` / `db deserialize`
  - [X] **9.4.2.s** `db function` enhancements: `-returntype`, `-directonly`
  - [X] **9.4.2.s.1** `DbSqlFunc` script-body forms
  - [X] **9.4.2.t** `db nullvalue` follow-ups + `db errorcode` extended-code
  - [X] **9.4.2.u** `db preupdate_hook`
  - [X] **9.4.2.u.1** Runtime-exercise the preupdate hook
  - [X] **9.4.2.v** `db unlock_notify`
  - [X] **9.4.2.w** Bridge symbol-table audit
  - [~] **9.4.2.x** NRE (Non-Recursive Eval) support — `db eval`
    with a script body and `db transaction` need
    `Tcl_NRCreateCommand` + `Tcl_NREvalObj` arms to interrupt
    cleanly across nested `vwait`.  Optional for first cut; many
    tests pass without it.  C ref: `tclsqlite.c:1888..1915`
    Done: command-dispatch NRE trampoline (`Tcl_NRCreateCommand` +
    `DbObjCmdNRE` + `DbUseNre` version probe) + the NRE externs in
    `PasTclBridge.pas`.  Non-NRE paths left intact.
  - [~] **9.4.2.x.1** NRE continuations — convert `DbEvalArm` and
    `DbTransactionArm` script bodies from the recursive
    `Tcl_EvalObjEx` path to genuine `Tcl_NRAddCallback` /
    `Tcl_NREvalObj` continuations (`DbEvalNextCmd` / `DbTransPostCmd`
    as `TTclNRPostProc`s).  C ref: `tclsqlite.c` `DbEvalNextCmd` /
    `DbTransPostCmd`.
    Done (transaction half): added `DbTransPostCmdNRE` matching the
    `TTclNRPostProc` shape (tclsqlite.c:1308..1348) and wired
    `DbTransactionArm` to take the NRE branch (tclsqlite.c:4002..4004)
    when `DbUseNre` is true.  Recursive `Tcl_EvalObjEx` path retained as
    the `!DbUseNre` fallback (tclsqlite.c:4005..4006).
    Eval half left as sub-arms because the Pascal `DbEvalArm` differs
    structurally from upstream and cannot be wholesale-converted (per
    9.4.2.x.1's "surface the gap" guidance):
    - [X] **9.4.2.x.1.a** Port `SqlPreparedStmt` cache + `DbPrepareAndBind`
    - [X] **9.4.2.x.1.b** Port `AddDatabaseRef` / `DelDatabaseRef`
    - [X] **9.4.2.x.1.c** `TDbEvalContext` record
    - [X] **9.4.2.x.1.d** Implement `DbEvalNextCmd: TTclNRPostProc`
    - [X] **9.4.2.x.1.e** Closed 2026-06-05

- [~] **9.4.3** Driver `src/tests/TclTestDriver.pas`.  Spawns
  `tclsh` against each manifest entry with the port's shim
  preloaded; collects pass/fail/skip per test.  Output format:
  one line per test (`PASS|FAIL|SKIP <path> <assertions> <duration>`),
  matching upstream's `make test` log shape.  The gate is "every
  `tcl-feature` test exits 0 or matches the upstream skip list".
  Per the skip-and-cite contract from 9.1.3.followup, divergences
  surface into `src/tests/tcl/DIVERGENCES.md` rather than blocking
  the driver — each cluster becomes a `9.4.divbug.N` follow-up
  bullet for triage.
  - [X] **9.4.3.a** Driver skeleton `src/tests/TclTestDriver.pas`
  - [X] **9.4.3.b** Fix the driver polling race
  - [X] **9.4.3.c** Per-test `testdir` wiring

- [~] **9.4.4** Skip-list curation.  Tests that depend on
  `sqlite3_test_control`, `PRAGMA legacy_*`, or other internal
  knobs land in `src/tests/tcl/SKIP.md` with a citation to the
  Phase 6/7/8 bullet that gates them.  Empty skip-list is the
  long-term goal; closed bullets prune entries here.
  - [X] **9.4.4.a** First 10-test sweep
  - [X] **9.4.4.b** Re-ran 10-test sweep after g.1..g.5 + g.7 + divbug.6
  - [X] **9.4.4.b.2** Re-sweep of the first 10 tests after the 2026-05-14 wave
  - [X] **9.4.4.c** Broaden sweep to first 50 tcl-feature tests
  - [X] **9.4.4.d** Broaden sweep to first 100 tcl-feature tests
  - [X] **9.4.4.e** Broaden sweep to 250 tests
  - [X] **9.4.4.f** Broaden sweep to 500 tests
  - [X] **9.4.4.g** Full tcl-feature sweep
  - [X] **9.4.4.h** tcl-internal re-evaluation

- [X] **9.4.5** Linux-only nightly
  - [X] **9.4.5.a** CI config
  - [X] **9.4.5.b** Sharding
  - [X] **9.4.5.c** Failure-report artefact

- [~] **9.4.6** Test-only public-API export delta.  Many `.test`
  files call into the C ABI beyond the "publicly documented" subset.
  Each bullet here adds the engine port + Tcl shim required by some
  number of `.test` files.  Audit current `src/*.pas` first — many
  of these already exist with partial coverage.
  - [X] **9.4.6.a** `sqlite3_compileoption_used` / `sqlite3_compileoption_get`
  - [X] **9.4.6.b** `register_dbstat_vtab`
  - [X] **9.4.6.c** `sqlite3_db_status` / `sqlite3_stmt_status`
  - [X] **9.4.6.d** `sqlite3_table_column_metadata`
  - [X] **9.4.6.e** `sqlite3_set_authorizer`
  - [X] **9.4.6.f** `sqlite3_create_collation` / `sqlite3_create_collation_v2`
  - [X] **9.4.6.g** `sqlite3_blob_open` / `_read` / `_write` / `_close`
  - [X] **9.4.6.h** `sqlite3_soft_heap_limit64` / `sqlite3_hard_heap_limit64`
  - [X] **9.4.6.i** `sqlite3_user_data` / `sqlite3_aggregate_context`
  - [X] **9.4.6.j** `sqlite3_extended_result_codes`
  - [X] **9.4.6.k** `sqlite3_unlock_notify`
  - [~] **9.4.6.l** Test-only modules — landed as
    `src/tests/tcl/testmodules/` unit per file.
    Done: `register_tcl_module` (test_tclvar.c → `TestModuleTclvar.pas`),
    `Md5_Register` + md5/md5file Tcl cmds (test_md5.c →
    `TestModuleMd5.pas`).  `register_wholenumber_module` already
    done in 10.1.69.  Remaining sub-tasks below.
    - [X] **9.4.6.l.1** `register_echo_module`
    - [X] **9.4.6.l.4** `registerTestFunction`
    - [X] **9.4.6.l.5** `register_async_vtab`
  - [X] **9.4.6.m** `sqlite3_log`
  - [X] **9.4.6.n** `sqlite3_memdebug_*`
  - [X] **9.4.6.o** File-control opcodes
  - [X] **9.4.6.p** `sqlite3_busy_timeout` / `sqlite3_busy_handler`
  - [X] **9.4.6.q** Unported test-only Tcl commands
    - [X] **9.4.6.q.1** test1.c prepared-statement C-API subset
    - [X] **9.4.6.q.2** Remaining 9.4.4.d-surfaced test commands
  - [X] **9.4.6.r** Faithful `fcntlSizeHint` port

- [~] **9.4.7** Build-matrix / harness infrastructure.  Many tests
  require a *different* build of libpassqlite3 than the default.
  Each profile lives as its own `bin/libpassqlite3tcl-<profile>.so`
  and the driver picks one via `--build`.
  - [X] **9.4.7.a** Compile-flag introspection finishing
  - [X] **9.4.7.b** Memdebug build profile
  - [X] **9.4.7.c** I/O-error injection
  - [~] **9.4.7.c.old** ~~test_devsym.c wrapper VFS~~ — superseded by the counter-instrumentation approach above; kept only if a future test needs a real device-characteristics shim.  Registers via
    `sqlite3_vfs_register`.
  - [~] **9.4.7.d** Crash-test harness — faithful port of `test6.c`
    landed as `src/tests/tcl/testmodules/TestModuleCrash.pas` (Agent
    6, 2026-05-16).  The "crash" VFS wraps the system default unix
    VFS, queues every `xWrite`/`xTruncate` in an in-memory write
    list, and on the `iCrash`'th `xSync` of the configured
    `zCrashFile` calls `_exit(-1)` — exactly the upstream power-loss
    semantics.  Tcl bindings `sqlite3_crash_enable`,
    `sqlite3_crash_now`, `sqlite3_crashparams` registered via
    `Sqlitetest6_Init` from `PasTclSqlite.pas:Sqlite3_Init`.
    `crashsql` Tcl proc landed under 9.4.2.g.11.  Verified
    end-to-end through `bin/TclTestDriver`: a hand-rolled .test
    using `crashsql -delay 1 -file test.db-journal { INSERT ... }`
    runs, the child crashes mid-journal-sync, the parent reopens
    and confirms recovery + integrity_check ok.  Marked [~] (not
    [X]) because three followups remain — see 9.4.2.g.11 for the
    list (`ifcapable crashtest`, WAL shm methods, the upstream
    `unixVfsObjFoo := unixVfsObj` record-copy issue).
  - [ ] **9.4.7.e** `permutations.tcl` matrix — full upstream re-runs
    each test under ~30 build-flag combinations.  Land as
    optional second-tier gate (not in baseline CI).  Requires:
    a build matrix generator script that emits one .so per
    permutation + driver flag `--permutation NAME` to pick.
    C ref: `../sqlite3/test/permutations.tcl`.
  - [X] **9.4.7.f** Per-test isolation
  - [X] **9.4.7.g** Driver concurrency
  - [X] **9.4.7.h** `tclsqlite3_Init` package-config
  - [X] **9.4.7.i** Threading build

- [~] **9.4.8** Full-corpus parity gate.
  - [X] **9.4.8.a** Per-test status tags
  - [X] **9.4.8.b** STATUS.txt seeded from current sweeps
  - [X] **9.4.8.c** Strict gate
  - [X] **9.4.8.d** Coverage check
  - [X] **9.4.8.e** Regression archive

#### 9.4 — Missing routines still to port (engine + harness gaps)

> First-class list of the genuinely-unported code behind the remaining
> live FAILs. The `divbug.*` bullets below track *symptoms*; these track
> the *routine to port*. (See also: fts5 `divbug.68.a`, QRF `divbug.91`,
> FTS3/4 merge perf `12.4`.)

- [X] **9.4.port.coroutine-from** Single-source FROM-subquery coroutine consumer routed through sqlite3WhereBegin (b66e4b4: set fg.viaCoroutine + fall through to generic consumer, select.c:8043/8265; ba81bb8: extended to SRT_Set IN-RHS + multiSelectValues EQP + fromClauseTermCanBeCoroutine restr-2 CTE-materialize). Fixed autoindex5-1.1, with5-310, update-21.12, pushdown-6.1/6.2/6.3 (update/with5/pushdown fully green). Gated TestExplainParity 1026/1026 (note: the "224/802" claim in the old text was STALE — gate is 1026/1026) + broad Tcl sweep, no regressions. STILL DEFERRED separately: autoindex5-3.0 (gatherSelectWindows expr.c:1987 unported — windowed dup row_number misuse, needs addrFillSub single-coding dedup or becomes a hang); with1-19.1b/22.1 (CTE flatten, codegen.pas:36601 skips CTE items, risks finalize SIGSEGV).
- [X] **9.4.port.intarray-addr** Ported intarray_addr + siblings int64array_addr/doublearray_addr/textarray_addr Tcl cmds (TestModuleTest1.pas, test1.c:3836..3962/9110..9113); tabfunc01 now 1 err/140 (residual 1370 stale newer-version expectation — 3.53 oracle also returns 0 for generate_series(0,0,0)).
- [X] **9.4.port.fs-schema-vtab** DONE — both modules ported+registered+load: TestModuleSchema.pas (test_schema.c, vtab2 0/18, vtabH 0/26) + TestModuleFs.pas fs/fsdir/fstree (test_fs.c, fts4content 0/128, no more "no such module: fs").

#### 9.4 divergence buckets (cite `src/tests/tcl/DIVERGENCES.md`)

- [X] **9.4.divbug.1** `select1.test select1-4.4`
- [X] **9.4.divbug.2** SQL error messages drop their format-arg tails
- [X] **9.4.divbug.3** Schema introspection result columns reordered / missing
- [X] **9.4.divbug.4** `update.test` sub-test `update-10.1` reported spurious
- [X] **9.4.divbug.5** `numcast.test` 0/51 → 51/51 Ok
- [X] **9.4.divbug.6** Doubled error string in `db1 eval`'s error return
- [X] **9.4.divbug.7** `insert.test` hangs
- [X] **9.4.divbug.8** `index.test` segfaults at `index-3.3`
- [X] **9.4.divbug.9** `lastinsert.test` segfaults right after
- [X] **9.4.divbug.10** `boundary1.test` SELECTs returned `{}`
- [X] **9.4.divbug.11** Compound
- [X] **9.4.divbug.12** `update-17.10` segfault
- [X] **9.4.divbug.13** Inequality-scan row ordering
- [X] **9.4.divbug.14** SQL errors drop object name
- [X] **9.4.divbug.15** `no such function` not raised at prepare
- [X] **9.4.divbug.16** `affinity3.test` segfault
- [X] **9.4.divbug.17** Subquery-nested aggregate evaluated row-wise
- [X] **9.4.divbug.18** WITHOUT ROWID vtab `xUpdate`
- [ ] **9.4.divbug.19** autoindex5-1.1 live FAIL — Pas NOW emits `CO-ROUTINE debian_cve` (coroutine machinery landed) but the single-source coroutine consumer hand-roll (codegen.pas:40878..41016) never calls sqlite3WhereBegin, so it emits `SCAN debian_cve` instead of oracle's `SEARCH debian_cve USING AUTOMATIC COVERING INDEX (bug_name=?)`. Also autoindex5-3.0 = unported gatherSelectWindows (now clean error, not crash). ROOT → **9.4.port.coroutine-from**.
- [X] **9.4.divbug.20** BETWEEN-on-indexed-column planner
- [X] **9.4.divbug.21** Cross-connection EXCLUSIVE lock detection +
- [X] **9.4.divbug.22** page_size=65536 overflow — bigrow+btree01 PASS
- [X] **9.4.divbug.23** Correlated FROM-subquery EQP shape
- [X] **9.4.divbug.24** sqlite_sequence AUTOINCREMENT — aggnested PASS
- [X] **9.4.divbug.24.b** aggnested-3.3 wrong scalar-subquery value +
- [X] **9.4.divbug.24.b.4** aggnested-3.11 "misuse of aggregate: max()"
- [X] **9.4.divbug.25** `update-19.10
- [X] **9.4.divbug.26** Echo vtab INSERT fails
- [X] **9.4.divbug.27** Engine OOM-recovery path segfaults under an injected
- [X] **9.4.divbug.28** EXPLAIN QUERY PLAN segfaults on multi-table queries
- [X] **9.4.divbug.41** EQP LAST-N-TERMS-OF — eqp2/cost/fordelete/delete2 PASS
- [X] **9.4.divbug.29** TEXT-affinity column stores `'0x119'` literal as
- [X] **9.4.divbug.30** ORDER BY NOCASE mis-order — collate4/collate8 PASS
- [X] **9.4.divbug.31** "malformed" on non-corrupt — collate3/count PASS (btree fixed)
- [X] **9.4.divbug.32** Readonly-DB DELETE returns `unknown error` instead of
- [X] **9.4.divbug.33** `count(DISTINCT …)` returns 1 instead of 0 for an
- [X] **9.4.divbug.34** `PRAGMA page_size` reports build default
- [X] **9.4.divbug.35** Float-to-text precision artefacts: `-1.11` →
- [X] **9.4.divbug.36** `PRAGMA journal_mode=off` silently ignored
- [X] **9.4.divbug.37** WAL `wal_hook` callback reports 0 frames where
- [X] **9.4.divbug.38.a** Malformed `REFERENCES … ON` parser error message
- [X] **9.4.divbug.38.b** FK-cascade picks wrong target row
- [X] **9.4.divbug.39** `CREATE TABLE AS SELECT`
- [X] **9.4.divbug.40** `DEFAULT` clause: error text drops column-name
- [X] **9.4.divbug.42** Mis-triaged: root was an engine SIGSEGV on
- [X] **9.4.divbug.43** `ORDER BY
- [X] **9.4.divbug.44** Misclassified cluster
- [X] **9.4.divbug.45** `HAVING` with non-aggregate predicate over-filters
- [X] **9.4.divbug.46** `LIMIT N` combined with subquery / DESC clamps wrong
- [X] **9.4.divbug.47** Numeric `_` digit-separator literals not parsed
- [X] **9.4.divbug.48** Hex-literal overflow detection: error text drops the
- [X] **9.4.divbug.49** Generated-column
- [X] **9.4.divbug.50** JSON output float formatting: integer-valued JSON
- [X] **9.4.divbug.51** JSON error-message text divergences
- [X] **9.4.divbug.52** JSON `subtype()` / `sqlite_subtype()` function
- [X] **9.4.divbug.53** Parser error reports `near token: syntax error`
- [X] **9.4.divbug.54** ORDER BY DESC + LIMIT+OFFSET on a partially-satisfied
- [X] **9.4.divbug.55** EQP detail-string divergences
- [X] **9.4.divbug.56** Default `LIKE` collation matches both cases when
- [X] **9.4.divbug.57** `sqlite3_open_v2(..., SQLITE_OPEN_READONLY, ...)` not
- [X] **9.4.divbug.58** `CREATE INDEX …
- [X] **9.4.divbug.59** JOIN USING/NATURAL: prefix-qualified column reference
- [X] **9.4.divbug.60** Tcl bridge coerces integer values bound through
- [X] **9.4.divbug.61** Harness gap: `fts3_common.tcl` not staged in
- [X] **9.4.divbug.62** test1.c `sqlite3_*` Tcl trampolines
  - [X] **9.4.divbug.62.a** `sqlite3_mprintf_*` family
  - [X] **9.4.divbug.62.b** Statement-level introspection
  - [X] **9.4.divbug.62.c** Binding API
  - [X] **9.4.divbug.62.d** Resource accounting: `sqlite3_status`
  - [X] **9.4.divbug.62.e** Function/extension management
  - [X] **9.4.divbug.62.f** Config & legacy: `sqlite3_config_pmasz`
- [X] **9.4.divbug.63** tcl-shim helper cmds
- [X] **9.4.divbug.63.sweep** Full live-driver bridge sweep
- [X] **9.4.divbug.64** `db func` and `db format` subcommands unported
- [X] **9.4.divbug.65** Tester Tcl globals `::DB` / `::STMT`
- [X] **9.4.divbug.66** SQL functions/extensions unregistered
  - [X] **9.4.divbug.66.a** Register `randstr(N,M)` from test_func.c:40 +
- [X] **9.4.divbug.67** `stmtrand` SQL extension unported
- [X] **9.4.divbug.68** PRAGMA module_list fts5 row — pragma5 PASS
  - [ ] **9.4.divbug.68.a** Port fts5 vtab module (ext/fts5/*.c) — XL, ~29 kLOC C.  REFRAMED: the oracle `/home/bpsa/app/sqlite3/sqlite3` is built WITHOUT fts5 (compile_options = ENABLE_FTS3/FTS4 only; `CREATE VIRTUAL TABLE..USING fts5` → "no such module: fts5" on BOTH engines; `nm -D` has no fts5 syms).  So module_list must NOT contain fts5 to stay faithful — current state (cap `fts5=0`, module absent) already matches; pragma5's fts5 row is gated behind `ifcapable fts5` and skipped.  Do NOT register an fts5 module while the oracle lacks it (would cause a module_list divergence and there is no oracle to verify any fts5 behaviour against).  Component/LOC map + port-order in memory project_fts5_port_map.md.
    - [X] **9.4.divbug.68.a.1** Port fts5_varint.c (344 LoC, zero deps) → src/passqlite3fts5varint.pas; bench src/tests/TestFts5Varint.pas (self-check + `dump` mode) byte-parity vs verbatim-C ref over 20020 values incl. all 1..9-byte boundaries: 60060/60060 lines identical.
    - [ ] **9.4.divbug.68.a.2** Port fts5_buffer.c (411 LoC) — Fts5Buffer grow/append/varint helpers + poslist iterators; deps: fts5_varint, sqlite3 malloc.
    - [ ] **9.4.divbug.68.a.3** Port fts5_hash.c (590 LoC) — in-memory term hash (Fts5Hash); deps: fts5_buffer, fts5_varint.
    - [ ] **9.4.divbug.68.a.4** Port fts5_config.c (1125 LoC) — CREATE-arg parser, Fts5Config; deps: tokenizer registry, fts5Int.h structs.
    - [ ] **9.4.divbug.68.a.5** Port fts5_tokenize.c (1490 LoC) + fts5_unicode2.c (780 LoC tables) — unicode61/ascii/porter/trigram tokenizers; deps: fts5_config.
    - [ ] **9.4.divbug.68.a.6** Port fts5_index.c (9545 LoC, BIGGEST) — segment b-tree / doclist storage; deps: fts5_buffer, fts5_hash, fts5_config, sqlite3 btree. Split into structmap/segwrite/segread/iter/merge sub-passes.
    - [ ] **9.4.divbug.68.a.7** Port fts5_storage.c (1530 LoC) — %_content/%_docsize/%_config shadow-table I/O; deps: fts5_index, fts5_config.
    - [ ] **9.4.divbug.68.a.8** Port fts5parse.y (lemon) → fts5parse + fts5_expr.c (3286 LoC) — MATCH query parser/evaluator; deps: fts5_index iterators, fts5_config. (fts5parse.c lemon-generated, excluded from diff.)
    - [ ] **9.4.divbug.68.a.9** Port fts5_main.c (3900 LoC) — the vtab module xConnect/xBestIndex/xFilter/xColumn/xUpdate + sqlite3Fts5Init; deps: ALL above. ONLY THIS registers the `fts5` module (gate on oracle gaining fts5 first).
    - [ ] **9.4.divbug.68.a.10** Port fts5_aux.c (821 LoC: bm25/highlight/snippet) + fts5_vocab.c (819 LoC: fts5vocab module); deps: fts5_main, fts5_index.
- [X] **9.4.divbug.69** `PRAGMA temp.<header_value>` SIGSEGV
- [X] **9.4.divbug.70** parser/resolver error-text — parser1/tokenize/quote/select1 PASS
- [X] **9.4.divbug.71** STRICT-typed table mis-error path
- [X] **9.4.divbug.71.b** PRAGMA quick_check/integrity_check single-table form
- [X] **9.4.divbug.71.c** ALTER ADD COLUMN error wrapper
- [X] **9.4.divbug.72** row-value misuse detection — rowvalue PASS
- [X] **9.4.divbug.73** `rowid` post-INSERT resolution returns 0
- [X] **9.4.divbug.74** UPSERT `ON CONFLICT DO UPDATE` increments target row
- [X] **9.4.divbug.75** select7 correlated `no such column: P.pk`
- [X] **9.4.divbug.76** View-column resolution / no-FROM-inside-FROM-subquery
- [X] **9.4.divbug.77** Cross-schema trigger validation error text
- [X] **9.4.divbug.78** Wide-table SCAN+predicate mis-count
- [X] **9.4.divbug.79** windowE ROWS-framing permute — windowE PASS
- [X] **9.4.divbug.80** `ORDER BY without LIMIT on DELETE/UPDATE` not detected
- [X] **9.4.divbug.80.a** STALE — UDL parser+codegen already fully ported & enabled; wherelimit/e_delete/upfrom2 all 0-err, semantics verified.
- [X] **9.4.divbug.80.b** wherelimit3 planner EQP — wherelimit3 PASS
- [X] **9.4.divbug.81** Attached / `query_only` DB readonly enforcement
- [X] **9.4.divbug.82** INSERT…RETURNING / scalar-function eval returns empty
- [X] **9.4.divbug.83** where* row-order — whereA/whereC/whereD/whereG PASS
- [X] **9.4.divbug.84** Long-running tests hit the 20 s per-test driver
- [X] **9.4.divbug.85** `collate5.test`
- [X] **9.4.divbug.86** Sibling-of-.84 driver-timeout family
- [X] **9.4.divbug.87** result-divergence cluster — in2/in7/index9/insert/joinC/nulls1 PASS; residual mmapwarm (stale expectation, non-bug) + savepoint6 (timeout)
  - [X] **9.4.divbug.87.001** `backup4`
  - [X] **9.4.divbug.87.002** `backup5`
  - [X] **9.4.divbug.87.003** `badutf`
  - [X] **9.4.divbug.87.004** `capi2`
  - [X] **9.4.divbug.87.005** `colmeta`
  - [X] **9.4.divbug.87.006** `corruptC`
  - [X] **9.4.divbug.87.007** `corruptM`
  - [X] **9.4.divbug.87.008** `delete4`
  - [X] **9.4.divbug.87.009** `descidx1`
  - [X] **9.4.divbug.87.010** `diskfull`
  - [X] **9.4.divbug.87.011** `eval`
  - [X] **9.4.divbug.87.012** `exec`
  - [X] **9.4.divbug.87.013** `exprfault`
  - [X] **9.4.divbug.87.014** `exprfault2`
  - [X] **9.4.divbug.87.015** `func3`
  - [X] **9.4.divbug.87.016** `fuzz-oss1`
  - [X] **9.4.divbug.87.017** `gcfault`
  - [X] **9.4.divbug.87.018** `gencol1`
  - [X] **9.4.divbug.87.019** `having`
  - [X] **9.4.divbug.87.020** `hexlit`
  - [X] **9.4.divbug.87.021** in2 PASS
  - [X] **9.4.divbug.87.022** `in5`
  - [X] **9.4.divbug.87.023** `in6`
  - [X] **9.4.divbug.87.024** in7 PASS
  - [X] **9.4.divbug.87.025** `index`
  - [X] **9.4.divbug.87.026** `index3`
  - [X] **9.4.divbug.87.027** `index8`
  - [X] **9.4.divbug.87.028** index9 PASS
  - [X] **9.4.divbug.87.029** `indexA`
  - [X] **9.4.divbug.87.030** `indexedby`
  - [X] **9.4.divbug.87.031** `indexexpr3-1.1`
  - [X] **9.4.divbug.87.032** insert PASS
  - [X] **9.4.divbug.87.033** `insert2`
  - [X] **9.4.divbug.87.034** `insert3`
  - [X] **9.4.divbug.87.035** `insertfault`
  - [X] **9.4.divbug.87.036** `instrfault`
  - [X] **9.4.divbug.87.037** `intpkey`
  - [X] **9.4.divbug.87.038** `intreal`
  - [X] **9.4.divbug.87.039** `istrue`
  - [X] **9.4.divbug.87.040** `join5`
  - [X] **9.4.divbug.87.041** `join7`
  - [X] **9.4.divbug.87.042** `join9`
  - [X] **9.4.divbug.87.043** joinC PASS
  - [X] **9.4.divbug.87.044** `joinI`
  - [X] **9.4.divbug.87.045** `limit`
  - [X] **9.4.divbug.87.046** `limit2`
  - [X] **9.4.divbug.87.047** `lock`
  - [X] **9.4.divbug.87.048** `lock7`
  - [X] **9.4.divbug.87.049** `minmax`
  - [X] **9.4.divbug.87.050** `minmax2`
  - [X] **9.4.divbug.87.051** `minmax3`
  - [X] **9.4.divbug.87.052** `misc2`
  - [X] **9.4.divbug.87.053** `misc3`
  - [X] **9.4.divbug.87.054** `misc4`
  - [X] **9.4.divbug.87.055** `misc5`
  - [ ] **9.4.divbug.87.056** mmapwarm live FAIL — STALE TEST EXPECTATION (test wants 507; port==oracle==506). Not an engine bug; don't chase.
  - [X] **9.4.divbug.87.057** `notnullfault`
  - [X] **9.4.divbug.87.058** `null`
  - [X] **9.4.divbug.87.059** nulls1 PASS
  - [X] **9.4.divbug.87.060** `orderby5`
  - [X] **9.4.divbug.87.061** `orderbyA`
  - [X] **9.4.divbug.87.062** `quickcheck`
  - [X] **9.4.divbug.87.063** `resolver01` 5.1
  - [X] **9.4.divbug.87.064** `rowhash`
  - [ ] **9.4.divbug.87.065** savepoint6 live FAIL — TIMEOUT (~60s watchdog), 0 real subtest failures; perf/timeout class, not correctness.
  - [X] **9.4.divbug.87.066** `securedel`
  - [X] **9.4.divbug.87.067** `tkt2920`
  - [X] **9.4.divbug.87.068** `tkt3442` `no such column: 5000`
  - [X] **9.4.divbug.87.069** `tkt3718`
  - [X] **9.4.divbug.87.070** `transitive1`
  - [X] **9.4.divbug.87.071** `upfrom1`
  - [X] **9.4.divbug.87.072** `upsert1`
  - [X] **9.4.divbug.87.073** `upsert4`
- [X] **9.4.divbug.88** Tcl-bridge command long-tail — cited tests PASS (cksumvfs etc.); no live bridge FAILs remain
  - [X] **9.4.divbug.88.001** `badutf2`
  - [X] **9.4.divbug.88.002** `bindxfer`
  - [X] **9.4.divbug.88.003** `cacheflush`
  - [X] **9.4.divbug.88.004** `capi3d`
  - [X] **9.4.divbug.88.005** `capi3e`
  - [X] **9.4.divbug.88.006** `chunksize`
  - [X] **9.4.divbug.88.007** `cksumvfs`
  - [X] **9.4.divbug.88.008** `close`
  - [X] **9.4.divbug.88.009** `collate7`
  - [X] **9.4.divbug.88.010** `colname`
  - [X] **9.4.divbug.88.011** `corrupt`
  - [X] **9.4.divbug.88.012** `corrupt2`
      - [X] **`{SQLITE_CORRUPT}` symbolic vs `11` numeric** (10.2)
  - [X] **9.4.divbug.88.013** `corrupt3`
  - [X] **9.4.divbug.88.014** `corrupt4`
  - [X] **9.4.divbug.88.015** `corrupt6`
  - [X] **9.4.divbug.88.016** `corrupt7`
  - [X] **9.4.divbug.88.017** `corruptE`
  - [X] **9.4.divbug.88.018** `corruptG`
  - [X] **9.4.divbug.88.019** `corruptH`
  - [X] **9.4.divbug.88.020** `corruptI`
  - [X] **9.4.divbug.88.021** `corruptJ`
  - [X] **9.4.divbug.88.022** `corruptK`
  - [X] **9.4.divbug.88.023** `corruptN`
  - [X] **9.4.divbug.88.024** `dataversion1`
  - [X] **9.4.divbug.88.025** `delete_db`
  - [X] **9.4.divbug.88.026** `e_createtable`
  - [X] **9.4.divbug.88.027** `e_dropview`
  - [X] **9.4.divbug.88.028** `e_reindex`
  - [X] **9.4.divbug.88.029** `e_select2`
  - [X] **e_select-0.2.0001.1 family** no-FROM GROUP BY admitted by aggregate
  - [X] **9.4.divbug.88.030** `e_update`
  - [X] **9.4.divbug.88.031** `e_uri`
  - [X] **9.4.divbug.88.032** `e_wal`
  - [X] **9.4.divbug.88.033** `e_walauto`
  - [X] **9.4.divbug.88.034** `enc3`
  - [X] **9.4.divbug.88.035** `errmsg`
  - [X] **9.4.divbug.88.036** `fallocate`
  - [X] **9.4.divbug.88.037** `filectrl`
  - [X] **9.4.divbug.88.038** `filefmt`
  - [X] **9.4.divbug.88.039** `hook`
  - [X] **9.4.divbug.88.040** `indexexpr1`
  - [X] **9.4.divbug.88.041** `interrupt2`
  - [X] **9.4.divbug.88.042** `ioerr`
  - [X] **9.4.divbug.88.043** `join`
  - [X] **9.4.divbug.88.044** `joinH`
  - [X] **9.4.divbug.88.045** `json102`
  - [X] **9.4.divbug.88.046** `json502`
  - [X] **9.4.divbug.88.047** `laststmtchanges`
  - [X] **9.4.divbug.88.048** `lock5`
  - [X] **9.4.divbug.88.049** `main`
  - [X] **9.4.divbug.88.050** `memsubsys1`
  - [X] **9.4.divbug.88.051** `memsubsys2`
  - [X] **9.4.divbug.88.052** `misc6`
  - [X] **9.4.divbug.88.053** `misuse`
  - [X] **9.4.divbug.88.054** `mjournal`
  - [X] **9.4.divbug.88.055** `multiplex4`
  - [X] **9.4.divbug.88.056** `nan`
  - [X] **9.4.divbug.88.057** `nolock`
  - [X] **9.4.divbug.88.058** `normalize`
  - [X] **9.4.divbug.88.059** `notnull2`
  - [X] **9.4.divbug.88.060** `trans3`
  - [X] **9.4.divbug.88.061** `upfrom4`
  - [X] **9.4.divbug.88.062** `varint`
  - [X] **9.4.divbug.88.063** `capi3d` follow-up
  - [X] **9.4.divbug.88.064** `capi3d` engine bug
  - [X] **9.4.divbug.88.065** `filectrl` follow-ups
  - [X] **9.4.divbug.88.066** `varint` engine bug
  - [X] **9.4.divbug.88.067** `filectrl` follow-up
  - [X] **9.4.divbug.88.068** cksumvfs full port — cksumvfs PASS
    - [X] **9.4.divbug.88.068.a** `PRAGMA <unknown>` must dispatch to
    - [X] **9.4.divbug.88.068.b** multi-overflow reopen SIGSEGV — fixed (cksumvfs PASS, btree byte-identical at 1M rows)
  - [X] **9.4.divbug.88.069** multiplex full port — landed, not in live FAIL set
    - [X] **9.4.divbug.88.069.a** `SQLITE_ENABLE_8_3_NAMES` arms in
    - [X] **9.4.divbug.88.069.b** `sqlite3_delete_database` Tcl command
- [X] **9.4.divbug.89** empty-driver-diagnostic cluster — corruptB/e_changes/e_totalchanges/index4/index5/joinB PASS; residual fuzz = timeout
  - [X] **9.4.divbug.89.001** `corruptB`
  - [X] **9.4.divbug.89.002** `e_changes`
  - [X] **9.4.divbug.89.003** `e_totalchanges`
  - [X] **9.4.divbug.89.004** `fuzz`
  - [X] **9.4.divbug.89.005** `index4`
  - [X] **9.4.divbug.89.006** `index5`
  - [X] **9.4.divbug.89.007** `join6`
  - [X] **9.4.divbug.89.008** `joinA`
  - [X] **9.4.divbug.89.009** `joinB`
  - [X] **9.4.divbug.89.010** `joinD`
  - [X] **9.4.divbug.89.011** `manydb`
  - [X] **9.4.divbug.89.012** `tkt3080`
  - [X] **9.4.divbug.89.013** `joinA`
  - [X] **9.4.divbug.89.014** joinB PASS
  - [X] **9.4.divbug.89.015** `joinD`
  - [X] **9.4.divbug.89.016** `fuzz` residual
- [X] **9.4.divbug.90** extension/VFS registration residue — io PASS; no live FAILs
  - [X] **9.4.divbug.90.001** `btree02`
  - [X] **9.4.divbug.90.002** `extension01`
  - [X] **9.4.divbug.90.003** `func4`
  - [X] **9.4.divbug.90.004** `func9`
  - [X] **9.4.divbug.90.005** `indexexpr2` PASS 126/126
  - [X] **9.4.divbug.90.006** io devsym VFS — io.test PASS
  - [X] **9.4.divbug.90.007** `memdb`
  - [X] **9.4.divbug.90.008** `misc8-3.0` SIGSEGV
- [ ] **9.4.divbug.91** Tcl harness helper gaps — residual live FAILs are qrf01-06 (QRF formatter — unported tclsqlite.c build feature; to port, see divbug.91.011/.012).
  - [X] a4 2026-06-05: strftime/sqlite3_libversion_number/save_prng_state/reset_
  - [X] **9.4.divbug.92** incrvacuum `no such column: t2.oid`
  - [X] **9.4.divbug.91.001** `avtrans`
  - [X] **9.4.divbug.91.002** `backup`
  - [X] **9.4.divbug.91.003** `backup_ioerr`
  - [X] **9.4.divbug.91.004** `bind`
  - [X] **9.4.divbug.91.005** `capi3b`
  - [X] **9.4.divbug.91.006** `fuzz3`
  - [X] **9.4.divbug.91.007** `interrupt`
  - [X] **9.4.divbug.91.008** `join3`
  - [X] **9.4.divbug.91.009** `mallocAll`
  - [X] **9.4.divbug.91.010** `memleak`
  - [X] **9.4.divbug.91.011** qrf01 PASS (0/106) — ported QRF (ext/qrf/qrf.c) to new unit src/tests/tcl/PasQrf.pas + DbFormatArm dispatch in PasTclSqlite.pas.
  - [X] **9.4.divbug.91.012** qrf02 PASS (0/4) — same QRF port (PasQrf.pas explain/eqp styles); qrf03-06 also green.
  - [X] **9.4.divbug.91.013** `savepoint2`
  - [X] **9.4.divbug.91.014** `tkt3992`
  - [X] **9.4.divbug.91.015** `trans2`
  - [X] **9.4.divbug.91.016** `types`
  - [X] **9.4.divbug.92.001** `filter1-3.3/3.5`
  - [X] **9.4.divbug.92.002** `json101-19.3`
  - [X] **9.4.divbug.92.003** `gencol1-23.5`
  - [X] **9.4.divbug.92.004** `gencol1-20.2`
  - [X] **9.4.divbug.92.005** `gencol1-8.20`
  - [X] **9.4.divbug.92.006** gencol1 virtual-gencol auto-index — gencol1 PASS
  - [X] **9.4.divbug.92.007** `vtab2-5.3`
  - [X] **9.4.divbug.92.008** `with1-22.1`
  - [ ] **9.4.divbug.92.009** with5-310 live FAIL — recursive-CTE outer ORDER BY wrongly eliminated (dup outer SELECT binds result col iColumn=-1/rowid → WHERE_IPK ordered match drops sorter). ROOT → **9.4.port.coroutine-from**.p materialise/dup fix.

---

## Phase 10 — CLI tool (`shell.c`, ~12k lines → `passqlite3shell.pas`)

Each chunk lands with a scripted parity gate that diffs `bin/passqlite3`
against the upstream `sqlite3` binary.  Unported dot-commands must return
the upstream `Error: unknown command or invalid arguments: ".foo"` so
partial landings cannot silently no-op.

### 10.1a Skeleton + arg parsing + REPL loop

- [X] **10.1a** Skeleton landed
- [X] **10.1.1** ShellState record + global state
- [X] **10.1.2** processInput / oneInputLine REPL core
- [X] **10.1.3** main + process_command_line two-pass arg parser
- [X] **10.1.4** Line reader
- [X] **10.1.5** Exit-code mapping + interrupt_handler + SIGINT wiring
- [X] **10.1.6** do_meta_command dispatcher skeleton
- [X] **10.1a.G** Gate `src/tests/TestShellRepl.pas` 8/8 PASS

### 10.1b Output modes + formatting controls

- [X] **10.1b** Output modes + formatting controls
- [X] **10.1.7..10.1.14** `.mode` dispatcher, shell_callback row dispatcher

### 10.1c Schema introspection dot-commands

- [~] **10.1c** Gate: `bin/TestShellSchema`. Multi-result `.tables` / `.indexes`-no-arg / temp-schema side-effects on `.databases` after `.indexes` are pre-existing port divergences and stay out of the gate.
  - [X] **10.1c.1** `.schema`
  - [X] **10.1c.2** `.tables`
  - [X] **10.1c.3** `.indexes`
  - [X] **10.1c.4** `.databases`
  - [X] **10.1c.5** `.fullschema`
  - [X] **10.1c.6** `.lint fkey-indexes`
  - [X] **10.1c.7** `.expert`
- [X] **10.1.15..10.1.21** `.schema --indent`, `.tables`, `.indexes`

### 10.1d Data I/O dot-commands

- [X] **10.1d** Subcommands 10.1.22..10.1.27 landed
  - [X] **10.1d.1** `.read`
  - [X] **10.1d.2** `.dump`
  - [X] **10.1d.3** `.import`
  - [X] **10.1d.4** `.output` / `.once`
  - [X] **10.1d.5** `.save`
  - [X] **10.1d.6** `.open`
- [X] **10.1.22..10.1.27** `.read`, `.dump`, `.import`, `.output`/`.once`

### 10.1e Meta / diagnostic dot-commands

- [X] **10.1e** Gate: src/tests/TestShellMeta.pas
- [X] **10.1.28..10.1.35, 10.1.37** `.stats`, `.timer`, `.eqp`, `.explain`
- [X] **10.1.36** `.log`
- [X] **10.1.38** `.iotrace`
- [~] **10.1.39** `.scanstats` — basic per-loop dump landed via 8.2.1 (NAME/EXPLAIN/EST/SELECTID/PARENTID emitted). Sub-arms a..e all closed:
  - [X] **10.1.39.a** TWhereLevel.addrVisit field added
  - [X] **10.1.39.b** NLOOP/nExec confirmed
  - [X] **10.1.39.c** qrfEqpStats EQP-tree formatter ported
  - [X] **10.1.39.d** NCYCLE / hwtime sampling
  - [X] **10.1.39.e** EXPLAIN text re-enabled: SCANSTAT_EXPLAIN gates on
- [X] **10.1.40** `.testcase NAME` / `.check ANSWER`
- [X] **10.1.41** `.testctrl`
- [~] **10.1.42** `.selecttrace`/`.wheretrace`/`.treetrace` — TRACEFLAGS toggle landed (via sqlite3_test_control). Mask-hint convention: subtask hints are bundle IDs, **always verify against** `sqliteInt.h:TREETRACE_*` / `whereInt.h:WHERETRACE_*`. Subtasks:
  - [X] **10.1.42.a** TREETRACE batch 1: begin/end
    - [X] **10.1.42.a.1** UNION ALL left/right
    - [X] **10.1.42.a.2** Post-flatten
    - [~] **10.1.42.a.3** EXISTS-to-JOIN (7368, 0x100000) + aggregate analysis (8442, 0x20). havingToWhere/countOfView/AggInfo-adjusted prints closed under a.6. Archive.
    - [X] **10.1.42.a.4** "after window rewrite"
    - [~] **10.1.42.a.5** Outer-join + FROM-subquery (verified masks 0x1000/0x800/0x4000/0x8000/0x20); landed via a.7/a.8/a.9/a.10/a.6.5. Remaining: flattenSubquery + IgnorableOrderby drop. Archive.
    - [X] **10.1.42.a.6** All 5 sub-arms
  - [~] **10.1.42.b** WHERETRACE batch 1: addBtreeIdx (0x800), addVirtual (0x800), OR-clause Begin/End (0x400). Subtasks:
    - [~] **10.1.42.b.1** Range-scan cost estimate — landed `Range scan lowers nOut` (where.c:2247, 0x20) in `whereRangeScanEst`. Other 4 arms STAT4-only, gated on b.7. Archive.
    - [X] **10.1.42.b.2** Subset-cost in `whereLoopAdjustCost`
    - [X] **10.1.42.b.3** Vtab constraint enumeration
    - [X] **10.1.42.b.4** Solver progress in `wherePathSolver`
    - [X] **10.1.42.b.5** OR-vs-AND per-subterm in `whereLoopAddOr`
    - [X] **10.1.42.b.6** DISTINCT reduction
    - [X] **10.1.42.b.7** Port the STAT4 cost-estimator helpers gating the 4
    - [X] **10.1.42.b.7.prereq** Port sqlite3Stat4ProbeSetValue +
    - [X] **10.1.42.b.7.prereq.a** Record-shape + scaffolding
    - [X] **10.1.42.b.7.prereq.b** analyze.c STAT4 collection
    - [X] **10.1.42.b.7.prereq.c** Consumers
    - [X] **10.1.42.b.7.prereq.c.1** Port `ValueNewStat4Ctx` struct
    - [X] **10.1.42.b.7.prereq.c.2** Port `valueFromFunction` STAT4 arm
    - [X] **10.1.42.b.7.prereq.c.3** Port `valueFromExpr` STAT4 branches +
    - [X] **10.1.42.b.7.prereq.c.4** Port public entries
    - [X] **10.1.42.b.7.prereq.c.5** Replace `sqlite3Stat4Column`
    - [X] **10.1.42.b.7.prereq.c.6** Port `loadStat4` / `loadStatTbl`
    - [X] **10.1.42.b.7.prereq.c.7** Port `whereKeyStats`
    - [X] **10.1.42.b.7.prereq.c.8** Port `whereRangeSkipScanEst`
    - [X] **10.1.42.b.7.prereq.c.9** Port `whereEqualScanEst`
    - [X] **10.1.42.b.8** Port `wherePathName` +
    - [X] **10.1.42.a.6.1** `havingToWhere` + `havingToWhereExprCb`
    - [X] **10.1.42.a.6.2** `countOfViewOptimization`
    - [X] **10.1.42.a.6.3** `optimizeAggregateUseOfIndexedExpr`
    - [X] **10.1.42.a.6.4** `aggregateConvertIndexedExprRefToColumn` + walker
    - [X] **10.1.42.a.6.5** "Finished with AggInfo" at sqlite3Select tail
    - [X] **10.1.42.a.7** Outer-join strength-reduction loop
    - [X] **10.1.42.a.8** FROM-subquery superfluous-ORDER-BY drop
    - [X] **10.1.42.a.9** `pushDownWhereTerms`
    - [X] **10.1.42.a.10** all-FROM snapshot
    - [X] **10.1.42.a.11** top-level ORDER-BY drop
    - [X] **10.1.42.a.12** DISTINCT→GROUP BY
  - [X] **10.1.42.c** `sqlite3DebugPrintf`
  - [X] **10.1.42.d** Build-flag gating: `build.sh` honours `SQLITE_DEBUG=1` →

### 10.1f Long-tail / specialised dot-commands

- [X] **10.1f** Closed 2026-05-13
  - [X] **10.1f.0..10.1f.2** `.backup` / `.restore` / `.clone`
  - [X] **10.1f.3** `.archive`/`.ar`
  - [X] **10.1f.4** `.session`
  - [X] **10.1f.5** `.recover`
  - [X] **10.1f.6** `.dbinfo`
  - [X] **10.1f.7** `.dbconfig`
  - [X] **10.1f.8** `.filectrl`
  - [X] **10.1f.9** `.sha3sum`
  - [X] **10.1f.10..10.1f.13** `.crnl`/`.binary`/`.connection`/`.unmodule`
  - [X] **10.1f.14..10.1f.16** `.vfsinfo`/`.vfslist`/`.vfsname`

- [X] **10.1.43..10.1.45** `.backup`, `.restore`, `.clone` all landed
- [X] **10.1.46** `.archive`/`.ar`
- [X] **10.1.47** `.session`
- [X] **10.1.48** `.recover`
- [X] **10.1.49** `.dbinfo`
- [X] **10.1.50** `.dbconfig`
- [X] **10.1.51..10.1.59** `.filectrl`, `.sha3sum`, `.crnl`, `.binary`

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
- [X] **10.1.67** anycollseq.c + blobio.c + nextchar.c + remember.c +
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
- [X] **10.1.90** cksumvfs.c → passqlite3cksumvfs.pas
- [X] **10.1.91** unionvtab.c → passqlite3unionvtab.pas
- [X] **10.1.92** fuzzer.c → passqlite3fuzzer.pas
- [X] **10.1.93** tmstmpvfs.c → passqlite3tmstmpvfs.pas
- [X] **10.1.94** amatch.c → passqlite3amatch.pas
- [X] **10.1.95** compress.c + sqlar.c
- [X] **10.1.96** ext/intck/sqlite3intck.c → passqlite3intck.pas
- [X] **10.1.97** ext/recover/dbdata.c → passqlite3dbdata.pas
- [X] **10.1.98** zipfile.c → passqlite3zipfile.pas
- [X] **10.1.99** spellfix.c → passqlite3spellfix.pas
- [X] **10.1.100** Built-in shell SQL UDFs: strtod, dtostr, shell_add_schema
- [X] **10.1.101** `ext/expert/sqlite3expert.c` → `passqlite3expert.pas`
- [X] **10.1.102** `.open --zip` / `--deserialize` / `--hexdb` shell glue +

- [~] **10.1a.1** Residual dot-command coverage gap surfaced by 2026-05-16 audit (Outcome B).  C `shell.c.in` help table (lines 3711..3962) lists 67 dot-commands; `doMetaCommand` in `src/passqlite3shell.pas:10342` routed 56 of them.  The 11 missing handlers all have working backing APIs in the engine and live entries in the Pas `azHelp[]` table (3704..3958).  Decomposed into bite-sized sub-arms 10.1a.1.1..10.1a.1.11; the 5 trivially-small ones (≤25 LOC each) landed inline 2026-05-16; the 6 medium ones are queued.  Gates: `bin/TestShellRepl` 8/8, `bin/TestShellModes` 2/2, `bin/TestShellSchema` 10/10, `bin/TestShellIO` 11/11, `bin/TestShellMeta` 60/60, `bin/TestCliParity` 20/1S/0 (== baseline).
  - [X] **10.1a.1.1** `.bail on|off`
  - [X] **10.1a.1.2** `.timeout MS`
  - [X] **10.1a.1.3** `.version`
  - [X] **10.1a.1.4** `.prompt MAIN ?CONTINUE?`
  - [X] **10.1a.1.5** `.nonce STRING`
  - [X] **10.1a.1.6** `.limit ?NAME? ?VAL?`
  - [X] **10.1a.1.7** `.imposter INDEX IMPOSTER` / `.imposter off`
  - [X] **10.1a.1.8** `.progress N`

  - [X] **10.1a.1.9** `.load FILE ?ENTRY?`
  - [X] **10.1a.1.10** `.auth ON|OFF`
  - [X] **10.1a.1.11** `.intck ?STEPS_PER_UNLOCK?`

### 10.1.bug.* — fixed bug ledger (kept as ticked stubs only)

> Closed bugs: history is in git. Each line below records the slot for
> regression-tracking purposes — re-open the slot if the symptom returns.

- [X] **10.1.bug.1** Header row leak in `.mode list`
- [X] **10.1.bug.103** strftime('%u') ISO weekday off-by-one
- [X] **10.1.bug.105** ISO 8601 `[+-]HH:MM` timezone suffix dropped
- [X] **10.1.bug.106** `'localtime'` / `'utc'` date modifiers were no-ops
- [X] **10.1.bug.107** CREATE UNIQUE INDEX on pre-populated dups silently
- [X] **10.1.bug.108** UNIQUE INDEX with COLLATE NOCASE ignored collation
- [X] **10.1.bug.109** `SELECT * FROM v ORDER BY a,b` with covering UNIQUE
- [X] **10.1.bug.110** current_date / current_time / current_timestamp not
- [X] **10.1.bug.111** AUTOINCREMENT counter not consulted
- [X] **10.1.bug.112** Star expansion skipped in prior arms of compound
- [X] **10.1.bug.113** FROM-subquery coroutine in compound MERGE arms
- [X] **10.1.bug.114** Numeric-prefix coercion lost decimal/exponent
- [X] **10.1.bug.115** WITH RECURSIVE … LIMIT inside body: ran forever / no
- [X] **10.1.bug.116** Correlated subqueries with qualified outer refs failed
- [X] **10.1.bug.117** min(x)/max(x) over all-NULL returned blob "0.0"
- [X] **10.1.bug.118** shellEPutZ stderr/stdout interleave order
- [X] **10.1.bug.119** replace(s,p,r) with NULL p or r returned s instead of
- [X] **10.1.bug.120** Result-set column aliases not visible in WHERE
- [X] **10.1.bug.121** LIMIT/OFFSET ignored on eponymous-vtab fast-arm
- [X] **10.1.bug.122** Aggregates over eponymous-vtab returned empty
- [X] **10.1.bug.123** WITH RECURSIVE … ORDER BY dropped
- [X] **10.1.bug.124** CLI `near line N` off-by-one with comment-interleaved
- [X] **10.1.bug.125** Step-error rc was extended code, missing "
- [X] **10.1.bug.126** JSON-function malformed-input errors silently swallowed
- [X] **10.1.bug.127** ORDER BY+LIMIT silently dropped sort on coroutine FROM
- [X] **10.1.bug.128** CLI step-error prefix should be `Error near line N:`
- [X] **10.1.bug.129** CLI openDb missed
- [X] **10.1.bug.130** `UPDATE T AS t SET col=(SELECT … WHERE inner.col=t.col)`
- [X] **10.1.bug.131** Bare-TK_ID outer ref from inside a correlated subquery
- [X] **10.1.bug.132** CLI `processInput` cut-gate required `zSql[end]=';'`
- [X] **10.1.bug.133** CLI `.echo on` was a silent no-op
- [X] **10.1.bug.134** CLI `.parameter set` populated temp.sqlite_parameters
- [X] **10.1.bug.135** `.changes` / `.show` defects: per-SQL emission
- [X] **10.1.bug.136** Meta dot-command dispatcher sweep

---

## Known regression-test failures (auto-discovered by `run_regression.sh`)

> Ledger entries: when a binary returns to all-green, mark `[X]` and leave
> in place as a fixed-bug record (matching the convention used by 10.1.bug.*).
> Numbering is scoped to the phase that owns the root cause.

- [X] **3.B.regbug.1** TestPagerReadOnly
- [X] **6.regbug.1** TestWhereExpr
- [X] **trigger1.regbug.1** trigger1 same-name trigger 13→1 fail
- [X] **trigger1.regbug.2** trigger1-22.10 + trigger2 1.x.x cleared

---

## Phase 10.2 — CLI integration parity

- [X] **10.2** Integration parity: `bin/passqlite3 foo.db` ↔ `sqlite3 foo.db`

### Phase 10.3 — Interactive line-editor follow-ups

Baseline raw-mode editor with arrow-key history landed in
`src/passqlite3lineedit.pas` (Left/Right/Home/End/Up/Down,
Backspace/Delete, Ctrl-A/E/B/F/N/P/U/K/W/L/C/D, in-memory history
capped at 1000).  Optional enhancements on top of that baseline:

- [X] **10.3.a** On-disk history persistence at `~/.passqlite3_history`
- [ ] **10.3.b** Tab completion for `.dot` commands and for table /
  column names visible in the currently-open database (query
  `sqlite_schema` + `PRAGMA table_info`).
- [ ] **10.3.c** Multi-line wrap-aware rendering — current refresh
  assumes the line fits on one terminal row; long lines smear.  Needs
  column-count probe (`TIOCGWINSZ`) and a multi-row redraw that
  positions the cursor with `ESC[<n>A` / `ESC[<n>B`.
- [ ] **10.3.d** Reverse-incremental search (Ctrl-R) over the in-memory
  history, matching readline's `(reverse-i-search)`'pat': hit` UX.

---

## Phase 11 — Benchmarks (Pascal-on-Pascal speedtest1 port)

Output format must be byte-identical to upstream `speedtest1` so the
existing `speedtest.tcl` diff workflow keeps working.  Lives in
`src/bench/passpeedtest1.pas`; the same binary swaps backends
(passqlite3 vs system libsqlite3) by `--backend`.

- [X] **11.1** Harness port

- [X] **11.2** `testset_main` port

- [X] **11.3** Small / focused testsets

- [X] **11.4** Schema-heavy testsets: `testset_star`

- [X] **11.5** Optional/extension-gated testsets: testset_debug1, testset_json

- [X] **11.6** Differential driver `bench/SpeedtestDiff.pas`

- [X] **11.7** Regression gate: commit `bench/baseline.json`
  - [X] **11.7.repin** 2026-05-16: re-pinned baseline from MAX-of-9 local runs

- [X] **11.8** Pragma / config matrix

- [X] **11.9** Profiling hand-off to Phase 9

---

## Phase 12 — Performance optimisation (enter only after Phase 9 green)

Changes here must preserve byte-for-byte on-disk parity.  Compile
flags: `-dAVX2 -CfAVX2 -CpCOREAVX -OpCOREAVX`.  Note: in FPC,
functions with `asm` content cannot be inlined.

- [X] **12.1** `perf record` on benchmark workloads
  - [ ] **12.1.followup.bigger-sample** Re-run callgrind at
        `--size 5` once `--testset main --size 5` SQLITE_CORRUPT
        note in `profile_perf.sh` is cleared, to confirm
        ranking holds on larger tables.

- [~] **12.2** Aggressive `inline` on VDBE opcode helpers, varint
  codecs, and page cell accessors.  Headline candidate.2 landed
  (xRecordCompare fast-path dispatch); secondary inline candidates
  (1, 3..11) still open.
  - [ ] **12.2.candidate.1** Inline `sqlite3VdbeSerialGet`
        (passqlite3vdbe.pas:2050) — 1.20 % self, called from
        every `OP_Column` step.
  - [X] **12.2.candidate.2** Specialise sqlite3VdbeRecordCompare on int-key +
  - [ ] **12.2.candidate.3** Cache `pPage^.aData` / `aCellIdx` /
        `maskPage` in locals at the top of
        `sqlite3BtreeIndexMoveto` (passqlite3btree.pas:3452) —
        4.95 % self.
  - [ ] **12.2.candidate.4** Same field-cache trick on
        `sqlite3BtreeTableMoveto` (passqlite3btree.pas:2909) —
        1.95 % self.
  - [ ] **12.2.candidate.5** Investigate the **two** definitions
        of `patternCompare` at passqlite3codegen.pas:54136 and
        :58452; dead-code-drop the duplicate, then evaluate
        AVX2 byte-search for the `noCase=0, esc=0` arm —
        combined 2.29 %.
  - [ ] **12.2.candidate.6** Reduce zero-fill churn: audit
        `sqlite3DbMallocZero` / `VdbeMakeReady` /
        `pcache1FetchNoMutex` for FillChar calls that could be
        replaced by reuse (low priority, ~1.5 %).
  - [ ] **12.2.candidate.7** Inline `sqlite3VdbeRecordUnpack`
        (passqlite3vdbe.pas:2263) and hoist `pKeyInfo^.nAllField`
        — 1.10 % self.
  - [ ] **12.2.candidate.8** Inline `btreeParseCellPtr`
        (passqlite3btree.pas:918) — 0.80 % self, called from
        every cell access.
  - [ ] **12.2.candidate.9** Audit `fillInCell` / `insertCellFast`
        for redundant payload Move calls (low priority).
  - [ ] **12.2.candidate.10** Inline `freeSpace`
        (passqlite3btree.pas:1284) — 0.98 % self.
  - [ ] **12.2.candidate.11** Hand-tune `sqlite3GetVarint`
        (passqlite3util.pas) — varint decode is in many hot
        paths, ~0.46 % self plus inclusive presence in #2/#10.

- [ ] **12.3** Consider replacing the VDBE big `case` with threaded
  dispatch (computed-goto-style) using `{$GOTO ON}`.  Land only if
  profiling shows the switch is a real bottleneck.
  - [ ] **12.3.candidate.1** Strip UnicodeString round-tripping
        in `passpeedtest1.pas` glue (DefaultUnicode2AnsiMove +
        DefaultAnsi2UnicodeMove + fpc_unicodestr_* together
        ~6 %).  Likely a *harness* fix, not engine — but it
        skews benchmarks vs C and should land before
        threaded-dispatch comparison.
  - [ ] **12.3.candidate.2** `{$GOTO ON}` jump-table dispatch
        for the top-10 hottest VDBE opcodes (`OP_Column`,
        `OP_Next`, `OP_Goto`, `OP_Integer`, `OP_AggStep`,
        `OP_ResultRow`, `OP_IdxGT`, `OP_SeekGE`, `OP_IfNot`,
        `OP_MakeRecord`) — sqlite3VdbeExec is 17.94 % self;
        even a 20 % cut here is ~3.5 % total.  Gate landing on
        measured cycle-level improvement, not Ir.

- [X] **12.4** FTS3/4 segment-merge build perf — DIAGNOSED, no engine fix needed. The "~28 ms/row" premise does not reproduce: port runs ~2 ms/row and is already ≤3× the oracle (the slowness is fsync/autocommit-bound and SHARED with the C oracle, not a port regression). All 3 hypotheses measured FALSE (12.4.2). On-disk same-binary build: oracle 109 s vs port 120 s (~1.1×) for 1533 prefix-fts4 rows; both >200 s for 30040 rows. Heavy files (fts4merge/fts4opt/fts4check/fts4growth2/fts3corrupt6) time out on BOTH engines → stay pas-soft with measured cite; this is the task's escape-hatch (fundamentally slow, not fixable to ≤3× without changing the faithful test's per-row autocommit/sync). On-disk parity verified (integrity-check + fts4aux content == oracle).
  - [X] **12.4.1** `src/tests/TestFts3BuildPerf.pas` committed (wired into build.sh; perf counters `gFts3Perf*`/`fts3PerfReset` added to passqlite3fts3.pas). Baseline (in-memory; port = in-process insert loop, oracle = full sqlite3 process so its ms/row is startup-amortised at high N):

    | N | port ms/row | oracle ms/row | flushes/row | segdir-ops/row | prepares (total) |
    |---|---|---|---|---|---|
    | 100 | ~2.0 | ~3.0 | 1.000 | 2.12 | 11 |
    | 1000 | ~2.0 | ~0.8–1.0 | 1.000 | 2.13 | 12 |

    Fairest comparison (both binaries, on-disk, via stdin): 1533-row prefix-fts4 autocommit build = oracle 108.7 s vs port ~120 s (~1.1×); 30040-row build = both >200 s.
  - [X] **12.4.2** (a) flush per-row not at `nMaxPendingData`? **NO** — flushes=1.000/row is autocommit-driven (xSync flushes at each commit, identical to oracle); `nMaxPendingData`=1 MB threshold IS honoured (code matches fts3_write.c:906). (b) re-prepares vs `aStmt[]`? **NO** — only 11 (N=100)/12 (N=1000) total prepares for the whole build (~0.012/row); cache works. (c) rewrites whole segdir per flush? **NO** — segdir-ops/row is CONSTANT at 2.12–2.13 regardless of table size (a wholesale rewrite would grow O(#segments)); incremental level-0 append, matches C.
  - [X] **12.4.3** No hypothesis confirmed → no engine fix applicable; DoD met as-is (port ≤3× oracle: 0.68–3.0× in-memory, ~1.1× on-disk). Slowness is fsync/autocommit-bound, shared with the oracle (oracle >200 s on the same 30040-row on-disk autocommit build) — only "fix" would be transaction-wrapping or `synchronous=OFF`, which diverges from the faithful test; STOP per escape hatch.
  - [X] **12.4.4** Re-ran all 10. PASS/<30 s already pas-strict: fts4merge4, fts4merge5, fts4growth, fts4langid, fts3corrupt2. Pure 30001 ms timeouts (0 correctness errors, oracle equally slow): fts4merge, fts4opt, fts4check, fts4growth2, fts3corrupt6 → stay pas-soft, STATUS.txt cites updated with measured cause (cannot promote: fts4merge.test exceeds even 360 s; one 30040-row build alone >200 s on the oracle). Also added `genesis.tcl` to the run_one_tcl shim dir (harness gap, unrelated to perf).

---

## Phase 13 — Coverage-guided fuzzing (AFL)

Enter after Phase 9 green; independent of Phase 12.  9.3.1 +
9.3.2 already provide the one-shot differential harness and an
8-seed clean sweep — this phase adds coverage-guided mutation on
top.  **FPC-AFL gotcha:** FPC has no `afl-clang-fast` equivalent
(no LLVM instrumentation pass).  Three viable instrumentation
routes — pick in this order:

1. **`afl-as` assembler wedge (preferred).**  Tell FPC to emit
   text assembly and route it through AFL's GAS wrapper:
   `fpc -al -Aas -FD<afl-bin-dir> ...`.  `-al` keeps `.s` files,
   `-Aas` selects GNU `as`, `-FD` points at the directory holding
   `afl-as`.  `afl-as` rewrites every branch site with the AFL
   tramp + shared-memory bitmap update — same mechanism `afl-gcc`
   used before `afl-clang-fast` existed.  ~2x slowdown.  May need
   minor tweaks if FPC's GAS dialect trips the wrapper's pattern
   matcher (older AFL versions assume gcc-style local labels).
2. **QEMU mode (`afl-fuzz -Q`).**  No compiler cooperation;
   instruments at translation time inside patched user-mode QEMU.
   ~5–10x slowdown but bulletproof.  Fallback if (1) fails.
3. **Black-box `afl-fuzz -n`.**  No instrumentation, dumb-fuzz
   only.  Last resort; documented for completeness.

Not viable: pure C shim with `afl-clang-fast` — the shim gets
instrumented but the Pascal callee doesn't, so the bitmap is
empty for the code under test.

Persistent-mode `__AFL_LOOP` is orthogonal to the choice above
and can be added later via a small C entry stub.

- [~] **13.1** AFL wiring.  `src/tests/fuzz/afl-driver.pas` wraps
  9.3.1 for `afl-fuzz` (read input from stdin, write to a tmp
  file, invoke the in-process harness, return AFL-compatible exit
  codes).  Stand up instrumentation route (1), (2), or (3) above;
  document the choice in `src/tests/fuzz/README.md`.  Skip
  gracefully if AFL isn't installed — script must self-report.
  Landed: src/tests/fuzz/afl-driver.pas (slurps stdin, mkstemp-equiv
  in /tmp, FpFork+FpExecv into bin/TestFuzzDiff, propagates rc /
  re-raises signal-death as 128+N for AFL crash bucketing), build-afl.sh
  (route-1 → route-2 → route-3 fallback chain, AFL-missing self-report
  → exit 0), README.md (route table + install + run recipe + 9.3.2
  smoke baseline citation).  Smoke verified on dev host (no AFL):
  default run prints self-report and exits 0; FORCE_BUILD=1 picks
  route (3) and compiles; driver returns rc=3 on empty stdin and
  rc=0 (PASS) on 4 KiB of fuzzdata1.db.  Tmp files cleaned up
  post-exec.  Cite: src/tests/fuzz/afl-driver.pas, build-afl.sh,
  README.md.
  - [ ] **13.1.unverified** Re-run build-afl.sh on a host with afl-fuzz
    installed and confirm route (1) `afl-as` wedge actually completes
    a smoke-fuzz iteration (`AFL_BENCH_JUST_ONE=1 afl-fuzz …`).  Today
    untested — dev host lacks afl-fuzz; only the AFL-missing self-report
    and the route-3 fallback compile path were exercised.

- [X] **13.2** Crash-vs-divergence classifier
  - [ ] **13.2.unverified** No real-world AFL crash corpus has hit
    the classifier yet — the four-bucket smoke used synthetic
    bash stubs.  Once 13.3's 24h soak surfaces an actual finding,
    re-run `classify-crash.sh` on the AFL crashes/ dir and
    confirm the side-disambiguation heuristic holds (FPC RTL
    Runtime-error preamble is present on every Pascal SIGSEGV
    AFL surfaces).

- [~] **13.3** ≥24 h soak target.  Wrapper script `fuzz-soak.sh`
  with `--duration` (default 24h) and stop-on-first-divergence.
  Not a CI gate — a manual gate documented in README.  Each
  clean soak bumps a counter in `src/tests/fuzz/SOAK_LOG.md` so
  we can prove the wallclock budget over time.
  Landed: src/tests/fuzz/fuzz-soak.sh (--duration / --no-stop /
  --quiet), src/tests/fuzz/SOAK_LOG.md (header + empty ledger).
  Pre-flights via build-afl.sh, picks route from .afl-route, polls
  findings/default/{crashes,hangs}/ every 5 min, hands findings to
  classify-crash.sh on first detection.  Self-reports + exits 0
  when afl-fuzz is missing.  README "Soak workflow" section added.
  - [ ] **13.3.unverified** This host has no AFL install; the
    real-soak path (afl-fuzz launch, bitmap-driven mutation, ledger
    row from a non-trivial run) wasn't exercised — only the AFL-
    missing self-report path was smoke-verified locally.  Re-run
    on an AFL-equipped host with `--duration 30m` once to confirm
    the polling loop, classify-crash hand-off, and SOAK_LOG.md
    row format all behave as advertised.

- [~] **13.4** Coverage-guided seed minimisation.  `afl-cmin` +
  `afl-tmin` pipeline pruning the seed set to the smallest input
  set that still hits every covered branch.  Re-commit the
  minimised seeds when they shrink.
  Landed: src/tests/fuzz/minimize-corpus.sh (--commit / --quiet).
  Runs afl-cmin → seeds.cmin/, then afl-tmin per survivor; prints
  before/after counts + bytes; --commit swaps seeds.cmin/ over
  seeds/, stages, and emits the suggested `git commit` line (never
  auto-commits).  Self-reports + exits 0 when afl-cmin/afl-tmin
  are missing.  README "Seed minimisation" section added.
  - [ ] **13.4.unverified** AFL not installed on this host; only
    the missing-tools self-report path was smoke-verified.  On an
    AFL-equipped host (route 1 or 2 — route 3's empty bitmap makes
    the pipeline a no-op), run the pipeline against the current
    8-seed corpus and re-commit the minimised set when it shrinks.

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

17. **`external 'c'` scalar params use the `ctypes` aliases, not ad-hoc Pascal
    widths.** Map C scalar types to the canonical aliases: `cint` ← `int`,
    `clong` ← `long`, `csize_t` ← `size_t`, `coff_t` ← `off_t`. Do NOT reach for
    `NativeInt`/`NativeUInt`/`i32`/`Integer` — on x86_64 LP64 they happen to be
    width-equivalent so it compiles, but it (a) silently drifts when the same C
    function is bound in two places and (b) is a portability bug off LP64.
    Concentrate shared libc bindings in **one** unit so there is a single source
    of truth — the FILE* stdio family (`fopen`/`fclose`/`fread`/`fwrite`/`fseek`/
    `ftell`/`fflush`/`rewind`/`fprintf`, plus `PFILE`/`stdout`) lives in
    `passqlite3os.pas` (interface), shared by the csv/fileio/zipfile/vfslog/
    tmstmpvfs extensions and the shell. `UnixType` (already used by os.pas)
    exports `cint`/`clong`/`csize_t`; do not add `ctypes` alongside it (the two
    units both define those names and will clash).

---

## Finding code duplication (port-introduced vs. upstream)

Goal: identify Pascal blocks that repeat without an equivalent repetition in
the upstream C reference. The faithful-port rule means any duplication present
in C is allowed (it lives there for a reason), but duplication that exists
*only* in the Pascal tree is a refactor candidate.

Tooling: `jscpd` (Node-based, token-aware, supports Pascal and C). Requires
`node` + `npm`; no install needed if invoked via `npx`.

### Step 1 — generate JSON reports for both trees

Run from any directory; outputs land in `/tmp/jscpd-out/`.

```
npx --yes jscpd /home/bpsa/app/pas-sqlite3/src \
  --pattern "**/*.pas" \
  --min-tokens 50 --reporters json --output /tmp/jscpd-out/pas

npx --yes jscpd /home/bpsa/app/sqlite3 \
  --pattern "{src,ext}/**/*.{c,h}" \
  --ignore "**/sqlite3.c,**/sqlite3.h,**/tsrc/**,**/parse.c,**/opcodes.c,**/fts5.c,**/fts5parse.c,**/keywordhash.h" \
  --min-tokens 50 --reporters json --output /tmp/jscpd-out/c
```

Notes on the C invocation:
- The amalgamation (`sqlite3.c/h`, `tsrc/`) is excluded — it is a concatenation
  of the split sources and inflates duplication artificially.
- Lemon/awk-generated files (`parse.c`, `opcodes.c`, `fts5.c`, `fts5parse.c`,
  `keywordhash.h`) are excluded — their repetition is mechanical, not human.
- `--min-tokens 50` matches roughly 6–10 lines of body code; raise it to 80–100
  to focus only on substantial clones.

### Step 2 — cross-reference Pascal clones against C

A Pascal file `passqlite3<stem>.pas` is considered to have a C analogue at
`<stem>.c` or `<stem>.h`. A Pascal clone pair `(A.pas, B.pas)` has a "C
analogue" if the corresponding C files also clone with each other (or, for
intra-file clones, if the same C file clones against itself).

Script (paste into `python3 -`):

```python
import json, os, re
from collections import defaultdict

c = json.load(open('/tmp/jscpd-out/c/jscpd-report.json'))
p = json.load(open('/tmp/jscpd-out/pas/jscpd-report.json'))

c_pairs = defaultdict(set)
for d in c['duplicates']:
    a = os.path.basename(d['firstFile']['name'])
    b = os.path.basename(d['secondFile']['name'])
    c_pairs[a].add(b); c_pairs[b].add(a)

def pas_to_c(n):
    m = re.match(r'passqlite3(.+)\.pas$', n)
    return {m.group(1)+'.c', m.group(1)+'.h'} if m else set()

def is_test(path): return '/tests/' in path

tests_only=[]; port_only=[]; cross=[]
for d in p['duplicates']:
    fa, fb = d['firstFile']['name'], d['secondFile']['name']
    a, b   = os.path.basename(fa), os.path.basename(fb)
    ln     = d['lines']
    ta, tb = is_test(fa), is_test(fb)
    if ta and tb:        tests_only.append((ln,a,b)); continue
    if ta or tb:         cross.append((ln,a,b));      continue
    ca, cb = pas_to_c(a), pas_to_c(b)
    hit = any(y in c_pairs.get(x,set()) for x in ca for y in cb)
    if not hit: port_only.append((ln,a,b))

for lst in (tests_only, port_only, cross): lst.sort(reverse=True)
print("test<->test :", len(tests_only), "clones,", sum(x[0] for x in tests_only), "lines")
print("port<->port :", len(port_only),  "clones,", sum(x[0] for x in port_only),  "lines  (no C analogue)")
print("test<->port :", len(cross),      "clones,", sum(x[0] for x in cross),      "lines")
print("\nTop 20 port<->port (port-introduced):")
for ln,a,b in port_only[:20]: print(f"  {ln:3}  {a} <-> {b}")
print("\nTop 20 test<->test (refactor candidates):")
for ln,a,b in tests_only[:20]: print(f"  {ln:3}  {a} <-> {b}")
```

### Step 3 — interpret the output

Three buckets, each with a different meaning:

1. **`port <-> port` with no C analogue** — genuine port-introduced
   duplication. Open the listed line ranges (`jscpd` JSON has `firstFile.start`
   / `firstFile.end`) and check the corresponding C function. Common causes:
   - C used a macro that the Pascal port inlined two or three times.
   - C used a `static inline` helper that the port copy-pasted instead of
     hoisting into a top-level routine.
   Fix by extracting a shared procedure inside the same unit, mirroring the C
   macro/helper.

2. **`test <-> test`** — the test harness has no upstream counterpart, so any
   clone here is by definition port-only. These are the biggest deletion wins.
   Look for families that share boilerplate (open `:memory:`, prep, step,
   compare against `csq_*`); collapse them into a common unit under
   `src/tests/` (e.g. a `DiagCommon.pas` exposing `ProbeOne` / `ProbeRows`).

3. **`test <-> port`** — should be empty. If non-empty, a test is probably
   inlining production code rather than calling it; fix the test.

### Step 4 — don't refactor blindly

Before extracting a helper:

- Confirm the upstream C really has no equivalent repetition. Sometimes the C
  source uses a macro that `jscpd` did not flag because it expands at compile
  time; a Pascal extraction is still correct, but the framing changes from
  "port-introduced" to "missing macro analogue."
- Avoid eliminating duplication that exists because the two Pascal sites are
  intentionally allowed to diverge later (e.g. an extension VFS that may grow
  features the core VFS will not). When in doubt, leave a `// see also <other
  site>` comment instead of extracting.
- Never refactor across the port↔test boundary: tests must stay independent of
  internal helpers to remain a useful oracle.

### Current snapshot (informational, recompute before acting)

At the time this section was written:

| Bucket                              | Clones | Dup lines |
| ----------------------------------- | -----: | --------: |
| Pascal total (`src/**/*.pas`)       |    319 |     6 143 |
| C total (split sources, no amalg.)  |    166 |       — (2.73% of 83k) |
| Pascal `test <-> test`              |    256 |     5 725 |
| Pascal `port <-> port` (no C analog)|     22 |       259 |
| Pascal `test <-> port`              |      0 |         0 |

Headline: ~96% of Pascal's excess duplication lives in the test harness; core
port code only carries ~259 unjustified duplicated lines out of 67 k.
