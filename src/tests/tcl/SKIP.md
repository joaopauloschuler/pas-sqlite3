# SKIP.md — tcl-feature tests gated out of the 9.4 sweep

Tests listed here fail not because of an engine divergence but because
`tester_min.tcl` lacks a helper, or because the test reaches for an
unported test-only C API (`sqlite3_test_control`, `optimization_control`,
private pragmas, `db_save`, vfs-injection harness, etc.).

Bootstrapped under task **9.4.4.a**.  Format:

    - **<path>** — <reason>.  Cite: <Phase X.Y bullet | unported helper | etc.>

## Tester-shim helpers (`tester_min.tcl` does not yet expose them)

- **../sqlite3/test/insert.test**       — needs `ifcapable`, `catchsql`,
  `do_catchsql_test`, `integrity_check`, `finish_test`.  Cite: 9.4.2.g
  bullet (tester_min.tcl intentionally omits these — listed in "What is
  intentionally NOT ported here").
- **../sqlite3/test/update.test**       — needs `ifcapable`, `catchsql`,
  `do_catchsql_test`, `do_eqp_test`, `integrity_check`, `finish_test`.
  Cite: 9.4.2.g bullet.
- **../sqlite3/test/delete.test**       — needs `ifcapable`, `catchsql`,
  `integrity_check`, `forcedelete`, `finish_test`.  Cite: 9.4.2.g bullet
  (`forcedelete` lives in tester.tcl head ~line 200 and shells `file delete`
  with retry).
- **../sqlite3/test/index.test**        — needs `ifcapable`, `catchsql`,
  `integrity_check`, `finish_test`.  Cite: 9.4.2.g bullet.
- **../sqlite3/test/cast.test**         — needs `do_realnum_test`,
  `ifcapable`, `finish_test`.  Cite: 9.4.2.g bullet (`do_realnum_test`
  is the regex-match-with-tolerance variant of `do_test`).
- **../sqlite3/test/lastinsert.test**   — needs `catchsql`, `ifcapable`,
  `finish_test`.  Cite: 9.4.2.g bullet.
- **../sqlite3/test/reindex.test**      — needs `catchsql`, `ifcapable`,
  `integrity_check`, `finish_test`.  Cite: 9.4.2.g bullet.
- **../sqlite3/test/boundary1.test**    — needs `working_64bit_int`,
  `finish_test`.  `working_64bit_int` is a build-cap probe gating the
  whole file (skips body if false).  Cite: 9.4.2.g bullet.

## Notes for future shim growth

When `tester_min.tcl` grows, prefer to land helpers in this order — each
unblocks the most tests:

1. ~~`ifcapable {EXPR} {BODY} ?elseBODY?` — unconditionally execute
   BODY, ignore EXPR.  Stub matches our default build (all caps
   enabled).~~  **Landed 9.4.2.g.1.**
2. `catchsql SQL ?DB?` — `[list $rc $msg]` wrapper around `db eval`.
3. `do_catchsql_test NAME SQL EXP` — `catchsql` + `do_test` combo
   (upstream tester.tcl:993..1006).
4. `integrity_check NAME ?DB?` — `do_test NAME { execsql {PRAGMA
   integrity_check} } {ok}` (upstream tester.tcl:1620..1627).
5. `finish_test` — alias for `finalize_testing` (upstream tester.tcl:1255).
6. `forcedelete FILE` — `file delete -force` retry loop (~tester.tcl:200).
7. `working_64bit_int` — return `1` (probe is always true on x86_64).
8. `do_eqp_test NAME SQL EXP` — `EXPLAIN QUERY PLAN` parity helper
   (upstream tester.tcl:1018..1032).
9. `do_realnum_test NAME SQL EXP` — match with `[regexp]` tolerance
   (upstream tester.tcl:983..991).
