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

## 9.4.2.g.3 re-evaluation note

After landing `finish_test`, `forcedelete`, and `delete_file`, several
entries above now lack only `integrity_check` (still pending under
9.4.2.g.4) to be source-able through `tester_min.tcl`:

  - **insert.test**, **index.test**, **reindex.test**, **update.test**,
    **delete.test** — block only on `integrity_check`
    (and `do_eqp_test` for update.test).
  - **lastinsert.test** — fully unblocked on the shim side after
    9.4.2.g.3; may now run end-to-end.  Pending 9.4.4.b re-sweep to
    confirm.
  - **cast.test** — still blocked on `do_realnum_test` (9.4.2.g.7).
  - **boundary1.test** — still blocked on `working_64bit_int`
    (9.4.2.g.5).

These tests stay listed here until 9.4.4.b actually re-runs them against
the grown shim; `integrity_check` is the remaining single bottleneck for
most of the bucket.

## Notes for future shim growth

When `tester_min.tcl` grows, prefer to land helpers in this order — each
unblocks the most tests:

1. ~~`ifcapable {EXPR} {BODY} ?elseBODY?` — unconditionally execute
   BODY, ignore EXPR.  Stub matches our default build (all caps
   enabled).~~  **Landed 9.4.2.g.1.**
2. ~~`catchsql SQL ?DB?` — `[list $rc $msg]` wrapper around `db eval`.~~
   **Landed 9.4.2.g.2.**
3. ~~`do_catchsql_test NAME SQL EXP` — `catchsql` + `do_test` combo
   (upstream tester.tcl:973..976).~~  **Landed 9.4.2.g.2.**
4. `integrity_check NAME ?DB?` — `do_test NAME { execsql {PRAGMA
   integrity_check} } {ok}` (upstream tester.tcl:1620..1627).
5. ~~`finish_test` — alias for `finalize_testing` (upstream tester.tcl:1255).~~
   **Landed 9.4.2.g.3.**
6. ~~`forcedelete FILE` — `file delete -force` retry loop (~tester.tcl:200).~~
   **Landed 9.4.2.g.3** (also `delete_file`).
7. `working_64bit_int` — return `1` (probe is always true on x86_64).
8. `do_eqp_test NAME SQL EXP` — `EXPLAIN QUERY PLAN` parity helper
   (upstream tester.tcl:1018..1032).
9. `do_realnum_test NAME SQL EXP` — match with `[regexp]` tolerance
   (upstream tester.tcl:983..991).
