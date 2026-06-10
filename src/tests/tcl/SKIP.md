# SKIP.md — tcl-feature tests gated out of the 9.4 sweep

Tests listed here fail not because of an engine divergence but because
`tester_min.tcl` lacks a helper, or because the test reaches for an
unported test-only C API (`sqlite3_test_control`, `optimization_control`,
private pragmas, `db_save`, vfs-injection harness, etc.).

Bootstrapped under task **9.4.4.a**; re-curated under **9.4.4.b**;
re-swept under **9.4.4.b.2** (see the 9.4.4.b.2 re-sweep note at the
bottom — most of the original SKIP entries now *run* and several
PASS).  Format:

    - **<path>** — <reason>.  Cite: <Phase X.Y bullet | unported helper | etc.>

**Policy (added 2026-06-09):** every entry must carry an explicit
**RECHECK** gate — a tasklist bullet, divbug number, or sweep task on
whose close the entry is re-probed.  A skip with only a *condition*
("once X lands") and no gate is a permanent skip: nobody comes back to
check whether the condition fired.  Proof: select4.test and printf.test
sat in the long-running section after their blocking divbugs (84/86)
closed, and both turned out to already PASS.

## Tester-shim helpers (`tester_min.tcl` does not yet expose them)

- **../sqlite3/test/insert.test**       — needs `ifcapable`, `catchsql`,
  `do_catchsql_test`, `integrity_check`, `finish_test` (all landed
  g.1..g.5).  9.4.4.b re-sweep: now **hangs** past `insert-1.3` (60s
  driver timeout fires).  Reclassified as engine divergence —
  see **9.4.divbug.7** in `tasklist.md`.  Kept here for the
  re-sweep gate but should move out once divbug.7 is rooted.
  RECHECK on 9.4.4.c.
- **../sqlite3/test/update.test**       — shim helpers all landed; still
  needs `reset_db` (sub-command for fresh DB rebuild used between
  major test groups) and `do_eqp_test` (9.4.2.g.6).  9.4.4.b
  re-sweep: 34 errors / 128 tests with `SOURCE-ERROR: invalid
  command name "reset_db"` at the end.  Most failures are
  **9.4.divbug.4** (out-of-memory) and **9.4.divbug.2** (truncated
  error messages).  Cite: 9.4.2.g.6 bullet (`do_eqp_test` pending)
  and new sub-task for `reset_db`.  RECHECK on 9.4.2.g.6 close
  (and see 9.4.divbug.12 — the b.2 re-sweep SIGSEGV).
- **../sqlite3/test/delete.test**       — shim helpers all landed.
  9.4.4.b re-sweep: 1 error / 23 sub-tests; SOURCE-ERROR is
  `unknown subcommand "one"` — the `db one` sub-command (single-row
  shortcut over `db eval`) is still unported (PasTclSqlite.pas;
  follow-up to 9.4.2.d..f).  Close to PASS once `db one` lands.
  RECHECK on the 9.4.2.d..f follow-up close.
- **../sqlite3/test/index.test**        — shim helpers landed.
  9.4.4.b re-sweep: **segfaults** at `index-3.3` after surfacing
  **9.4.divbug.3** (schema columns) on `index-1.1c/1.1d`.  Crash
  reclassified as **9.4.divbug.8**.  RECHECK on divbug.8 close.
- **../sqlite3/test/lastinsert.test**   — shim helpers landed.
  9.4.4.b re-sweep: **segfaults** at `lastinsert-1.1w` (64-bit
  rowid variant).  Reclassified as engine divergence
  **9.4.divbug.9**.  RECHECK on 9.4.4.c.
- **../sqlite3/test/boundary1.test**    — shim-complete after
  9.4.2.g.5 (`working_64bit_int`).  9.4.4.b re-sweep: **runs**
  (1511 sub-tests) but 1481/1511 fail with empty result on
  large-rowid range queries.  Reclassified as engine divergence
  **9.4.divbug.10**.  RECHECK on 9.4.4.c.

## Promoted to PASS under 9.4.4.b (no longer in SKIP)

- **../sqlite3/test/cast.test** — ~~vacuous PASS via the old
  `ifcapable` stub that unconditionally executed BODY~~.
  **RESOLVED 2026-06-09:** `ifcapable` gained real expression
  evaluation (tester_min.tcl, unset caps default to enabled);
  cast.test now runs 134 real sub-tests and PASSes.
- **../sqlite3/test/reindex.test** — ~~same vacuous-PASS pattern~~.
  **RESOLVED 2026-06-09:** runs 33 real sub-tests, PASSes (e_reindex
  115 sub-tests likewise).

## 9.4.4.b shim-completeness note

After landing g.1..g.5 + g.7 every helper in the original SKIP
list is shim-complete; remaining failures fall into:

  - engine divergences (divbug.1..5, 7..10) — listed as
    `9.4.divbug.*` bullets in `tasklist.md`;
  - missing `db` sub-commands (`db one`, `reset_db`) — port-side
    follow-ups to 9.4.2.d..f, *not* shim limitations;
  - the lingering `do_eqp_test` helper (9.4.2.g.6) which only
    `update.test` depends on inside the 10-test set.

## `*_common.tcl` source-include helpers — 9.4.2.g.13 audit

Upstream `.test` files `source $testdir/<name>_common.tcl`.  The
TclTestDriver sets `::testdir` at `src/tests/tcl/`, so a copy of
each safe helper must live here for the `source` to resolve.

Audited every `../sqlite3/test/*_common.tcl` (note: there is **no**
`incrblob_common.tcl` upstream — incrblob tests inline their helpers).

### Copied verbatim into `src/tests/tcl/` (no internal hooks)

- **wal_common.tcl** — pure Tcl: `expr` / `binary` / `file` / `open`
  arithmetic + WAL header checksum helpers.  `set_tvfs_hdr` /
  `incr_tvfs_hdr` reference the `tvfs` testvfs command, but only
  inside proc bodies (not at source time) — tests that actually call
  those still need 9.4.7.b testvfs wiring, but the file is safe to
  source.
- **fuzz_common.tcl** — pure-Tcl SQL fuzz generators; at source time
  only opens `fuzzy.log` and defines procs.  `do_fuzzy_test` uses
  `do_test` / `execsql` / `subst` (all in tester_min.tcl).

### SKIP-and-cite (depend on unported internal hooks — NOT copied)

- **malloc_common.tcl** — `do_malloc_test` / `do_faultsim_test` /
  `do_select_test` need `sqlite3_memdebug_fail`,
  `sqlite3_db_config_lookaside`, `sqlite3_extended_result_codes`,
  `save_prng_state` / `restore_prng_state`, and `testvfs` (shmfault).
  Source-time itself is harmless (our `ifcapable` stub runs the
  `builtin_test` body → `set MEMDEBUG 1`).  Cite: 9.4.2.g.9 (do_malloc_test)
  / 9.4.7.b (sqlite3_memdebug_* + testvfs).
- **lock_common.tcl** — `do_multiclient_test` / `launch_testfixture` /
  `testfixture` need a child `testfixture` process,
  `sqlite3_test_control_pending_byte`, and `permutation`.
  Cite: 9.4.7.c (testfixture multi-process harness) / 9.4.2.g.8
  (permutation matrix).
- **bc_common.tcl** — `bc_find_binaries` / `do_bc_test` need
  `launch_testfixture` + `testfixture` (backwards-compat against
  historical binaries).  Cite: 9.4.7.c (testfixture harness).
- **fts3_common.tcl** — source-time `ifcapable fts3 {
  sqlite3_fts3_may_be_corrupt 0 }`: our `ifcapable` stub runs the
  body unconditionally → calls the unported `sqlite3_fts3_may_be_corrupt`
  test command → **source-time error**.  Helpers also use
  `fts3_tokenizer_test` and `read_fts3varint`.  Cite: 9.4.7.d (fts3
  test-only commands) / 9.4.2.g.1 follow-up (real `ifcapable` EXPR).
- **pg_common.tcl** — `package require Pgtcl`, connects to a live
  Postgres at source time, and **redefines** `execsql` to route to
  pg_exec.  Not a SQLite-side helper at all (used only to regenerate
  golden `.test` files).  Cite: not applicable — out of scope for the
  pas-sqlite3 sweep.
- **thread_common.tcl** — source-time `return 0` early, so sourcing is
  inert, but `thread_spawn` / `run_thread_tests` need `sqlthread`,
  `enter_db_mutex` / `leave_db_mutex`, and the low-level
  `sqlite3_prepare_v2` / `sqlite3_step` / `sqlite3_column_*` Tcl
  bridge.  Cite: 9.4.7.e (sqlthread + threading test API).

## 9.4.4.b.2 re-sweep result

Re-ran the 10-test set under `bin/TclTestDriver` after fixing the
driver's relative-path regression (see the 9.4.4.b.2 divbug bullets
in tasklist.md).  Every original SKIP entry is now shim-complete *and*
runs to completion or further:

- **numcast.test** — now **PASS 51/51** (divbug.5 fixed).  Removed
  from the SKIP gate.
- **lastinsert.test** — now **PASS 6/6** (divbug.9 fixed).  Removed.
- **insert.test** — now **runs** 36 sub-tests, 3 errors (divbug.7
  hang fixed); remaining fails are divbug.14/.15 + a `source`-time
  `can't read "AUTOVACUUM"` (the test reads `$AUTOVACUUM` from the
  shim — `tester_min.tcl` should `set ::AUTOVACUUM 0`).  Stays as a
  divergence-gated entry, not a shim gate.
- **index.test** — now **runs** 101 sub-tests, 11 errors (divbug.3
  + .8 crashes fixed); remaining are divbug.14 error-text +
  `sqlite3_db_config` SOURCE-ERROR (unported test command).
- **delete.test** — now **runs** 49 sub-tests, 2 errors; the old
  `db one` blocker is gone; remaining are divbug.15 + a
  `sqlite3_connection_pointer` SOURCE-ERROR (unported test command).
  (CTAS-blocker fixed by 9.4.divbug.39.)
- **update.test** — now SIGSEGVs at `update-17.10` — new
  **9.4.divbug.12**.
- **boundary1.test** — empty-result (divbug.10) fixed; now fails on
  row *ordering* — new **9.4.divbug.13**.

Remaining shim/test-command gaps surfaced (port-side follow-ups,
not divergences): `sqlite3_db_config`, `sqlite3_connection_pointer`,
and `set ::AUTOVACUUM` in `tester_min.tcl`.

## Long-running tests — watchdog timeouts

These tests run to completion under upstream tclsh but exceed the
TclTestDriver per-test watchdog under our port.  2026-06-09 re-probe
after divbug.84/86 closed: **select4.test now PASSes** (123 sub-tests,
5.1 s) and **printf.test now PASSes** (1409 sub-tests, 0.5 s) — both
promoted to pas-strict and removed from this list.  The two below
still time out at the 240 s watchdog with 0 sub-tests completed.

- **../sqlite3/test/writecrash.test** — `for {set tn 1} {$bGo} {incr tn}`
  crash-injection loop at :38 walks every byte offset of every write
  inside the VFS shim; 240 s timeout, 0 sub-tests (2026-06-09 sweep).
  Cite + RECHECK: **9.4.8.f.6**.
- **../sqlite3/test/securedel2.test** — generates 1000 pseudo-random
  64-bit blobs at :21 then runs three nested 850/5000/850-iteration
  insert/delete loops at :39/:79/:88; 240 s timeout, 0 sub-tests
  (2026-06-09 sweep).  Cite + RECHECK: **9.4.8.f.6**.

## Notes for future shim growth

When `tester_min.tcl` grows, prefer to land helpers in this order — each
unblocks the most tests:

1. ~~`ifcapable {EXPR} {BODY} ?elseBODY?` — unconditionally execute
   BODY, ignore EXPR.  Stub matches our default build (all caps
   enabled).~~  **Landed 9.4.2.g.1.**  (Caveat: causes vacuous PASS
   on tests whose entire body is wrapped in `ifcapable !FEATURE`;
   real-EXPR upgrade is a 9.4.2.g.* follow-up.)
2. ~~`catchsql SQL ?DB?` — `[list $rc $msg]` wrapper around `db eval`.~~
   **Landed 9.4.2.g.2.**
3. ~~`do_catchsql_test NAME SQL EXP` — `catchsql` + `do_test` combo
   (upstream tester.tcl:973..976).~~  **Landed 9.4.2.g.2.**
4. ~~`integrity_check NAME ?DB?` — `do_test NAME { execsql {PRAGMA
   integrity_check} } {ok}` (upstream tester.tcl:1674..1678).~~
   **Landed 9.4.2.g.4.**
5. ~~`finish_test` — alias for `finalize_testing` (upstream tester.tcl:1255).~~
   **Landed 9.4.2.g.3.**
6. ~~`forcedelete FILE` — `file delete -force` retry loop (~tester.tcl:200).~~
   **Landed 9.4.2.g.3** (also `delete_file`).
7. ~~`working_64bit_int` — return `1` (probe is always true on x86_64).~~
   **Landed 9.4.2.g.5** (also `presql`, `omit_test`).
8. `do_eqp_test NAME SQL EXP` — `EXPLAIN QUERY PLAN` parity helper
   (upstream tester.tcl:1018..1032).  Pending 9.4.2.g.6.
9. ~~`do_realnum_test NAME SQL EXP` — match with `[regexp]` tolerance
   (upstream tester.tcl:892..896).~~  **Landed 9.4.2.g.7** alongside
   the prefix-driven match-mode dispatch in do_test.
