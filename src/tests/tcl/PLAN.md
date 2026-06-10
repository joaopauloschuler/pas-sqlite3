# PLAN — Phase 9.4 Tcl test-suite bridge (`src/tests/tcl/`)

## 1. Goal

Enable the upstream SQLite Tcl `.test` corpus (`../sqlite3/test/*.test`) to
run against pas-sqlite3 as a differential acceptance gate, matching the
skip-and-cite convention already established by phases 9.1 (corpus replay)
and 9.2 (oracle divergence triage). We embed a Tcl 8.6 interpreter, expose
pas-sqlite3 to it as the `sqlite3` Tcl command (ABI-identical to the C
`tclsqlite.c` shim), source a trimmed `tester_min.tcl`, then sweep
selected `.test` files via `bin/TclTestDriver`. New divergences are
bucketed into `9.4.divbug.*`.

## 2. Architecture

```
+-----------------+      fork+exec      +----------------------+
| TclTestDriver   | ------------------> | tclsh (Tcl 8.6)      |
| (Pascal, FPC)   |  per .test file     |                      |
| reads MANIFEST  | <------------------ |  load libpassqlite3- |
| collects rc     |  PASS/FAIL stdout   |       tcl.so Sqlite3 |
+-----------------+                     |  source tester_min   |
                                        |  source <test>.test  |
                                        +-----------+----------+
                                                    |
                                          Tcl_CreateObjCommand
                                                    |
                                                    v
                                        +----------------------+
                                        | libpassqlite3tcl.so  |
                                        | (FPC-built .so)      |
                                        |  Sqlite3_Init -> DbMain
                                        |  DbMain   -> sqlite3_open_v2
                                        |  DbObjCmd -> eval/close/...
                                        +-----------+----------+
                                                    |
                                            cdecl C ABI calls
                                                    v
                                        +----------------------+
                                        | passqlite3 (.a/.so)  |
                                        | pas-sqlite3 core     |
                                        +----------------------+
```

The driver never links Tcl itself; it shells out to system `tclsh` and
the bridge `.so` is loaded by Tcl's `load` command. The `.so` is the
only FPC artefact that imports libtcl symbols.

## 3. FPC <-> Tcl C ABI symbols (cdecl externs in `PasTclBridge.pas`)

All cites refer to `/home/bpsa/app/sqlite3/src/tclsqlite.c` (first use).

| Symbol                       | First use (tclsqlite.c) |
|------------------------------|-------------------------|
| `Tcl_CreateInterp`           | 4583                    |
| `Tcl_DeleteInterp`           | (paired w/ CreateInterp; standard cleanup) |
| `Tcl_Eval`                   | 703                     |
| `Tcl_EvalFile`               | (driver-side .test sourcing; std API)      |
| `Tcl_EvalObjEx`              | 757                     |
| `Tcl_CreateObjCommand`       | 4407                    |
| `Tcl_GetObjResult`           | 874                     |
| `Tcl_SetObjResult`           | 1451                    |
| `Tcl_GetString`              | 1094                    |
| `Tcl_GetStringFromObj`       | 535                     |
| `Tcl_GetStringResult`        | 688                     |
| `Tcl_NewStringObj`           | 751                     |
| `Tcl_NewIntObj`              | 872                     |
| `Tcl_NewWideIntObj`          | 754                     |
| `Tcl_NewDoubleObj`           | 1070                    |
| `Tcl_NewByteArrayObj`        | 1056                    |
| `Tcl_NewListObj`             | 1046                    |
| `Tcl_ListObjAppendElement`   | 753                     |
| `Tcl_ListObjGetElements`     | 1042                    |
| `Tcl_IncrRefCount`           | 752                     |
| `Tcl_DecrRefCount`           | 620                     |
| `Tcl_PkgProvide`             | 4452                    |
| `Tcl_FindExecutable`         | 4581                    |
| `Tcl_GetIntFromObj`          | 874                     |
| `Tcl_GetWideIntFromObj`      | 1138                    |
| `Tcl_GetDoubleFromObj`       | 1146                    |
| `Tcl_WrongNumArgs`           | 2476                    |
| `Tcl_AppendResult`           | 1339                    |
| `Tcl_GetVar`                 | (standard, paired w/ SetVar)               |
| `Tcl_SetVar`                 | 887                     |

## 4. Tcl ABI constants

```pascal
const
  TCL_OK         = 0;
  TCL_ERROR      = 1;
  TCL_RETURN     = 2;
  TCL_BREAK      = 3;
  TCL_CONTINUE   = 4;
  TCL_STATIC     : Pointer = Pointer(0);
  TCL_VOLATILE   : Pointer = Pointer(1);
  TCL_DYNAMIC    : Pointer = Pointer(3);
  TCL_GLOBAL_ONLY = 1;       (* see line 887 *)
  TCL_EVAL_DIRECT = $40000;  (* see line 757 *)
```

## 5. Library linking

System Tcl on this host is **8.6** (`/usr/include/tcl8.6`, `/usr/bin/tclsh`).

* FPC build flag for `libpassqlite3tcl.so`: `-k-ltcl8.6`
  (fallback `-k-ltcl` if the 8.6-suffixed alias is missing).
* Debian/Ubuntu so-name: `libtcl8.6.so` (resolved by `ld.so` via
  `/etc/ld.so.conf.d/x86_64-linux-gnu.conf`).
* The bridge `.so` must export `Sqlite3_Init` (PascalCase, cdecl) so
  Tcl's `load ... Sqlite3` succeeds; no `.def` file needed under ELF.

## 6. Stages (verbatim from tasklist.md §9.4)

* **9.4.2.0** Plan doc lands at `src/tests/tcl/PLAN.md` (this file).
* **9.4.2.a** Bridge unit `PasTclBridge.pas` + smoke `TestTclBridgeSmoke`
  (creates interp, `expr 2+2`, asserts "4"). No sqlite3 cmd yet.
* **9.4.2.b** `Sqlite3_Init` exporter + `libpassqlite3tcl.so` build;
  registers `sqlite3` obj-cmd; `DbMain`/`DbObjCmd` are TCL_ERROR stubs.
  Gate: `TestTclSqliteInit` confirms load+`package require sqlite3`.
* **9.4.2.c** `DbMain` opens `:memory:` via `sqlite3_open_v2`; `DbObjCmd`
  `close` arm wired. Gate: `TestTclSqliteOpen`.
* **9.4.2.d** `DbObjCmd eval $sql` minimum arm: prepare/step/finalize,
  rows as flat Tcl list. Gate: 3-row select returns `1 2 3`.
* **9.4.2.e** Trivial passthroughs: `version`, `changes`,
  `last_insert_rowid`, `errorcode`, `nullvalue`. Gate: `TestTclSqliteMeta`.
* **9.4.2.f** `db function NAME ?-argcount N? proc` via
  `sqlite3_create_function` + Tcl trampoline `DbSqlFunc`.
* **9.4.2.g** `tester_min.tcl` exporting `do_test`, `do_execsql_test`,
  `execsql`, `expected`, `set_test_counter`, `finalize_testing`, global
  `db`. Gate: sources file, runs `do_test foo-1.0 {expr 1+1} 2`.
* **9.4.3.a** `TclTestDriver.pas` reads MANIFEST.txt, forks `tclsh` per
  test, emits `PASS|FAIL|SKIP <path> <assertions> <duration>`.
* **9.4.4.a** First 10-test sweep (`select1`, `expr1`, `where1` family),
  classify, populate `SKIP.md` + the `9.4.divbug.*` ledger (kept as
  checkbox bullets in `tasklist.md`; the local `DIVERGENCES.md`
  skeleton was removed 2026-06-09).

## 7. Risks & open questions

* **NRE (Non-Recursive Eval).** Tcl 8.6's NRE-enabled callbacks can
  reenter our `DbObjCmd` from inside `Tcl_EvalObjEx`. We will stay on
  the legacy synchronous-callback API (`Tcl_CreateObjCommand`, not
  `Tcl_NRCreateCommand`) and accept the stack-recursion ceiling that
  upstream `tclsqlite.c` already lives with.
* **Tcl_Obj refcounting under FPC.** `Tcl_NewStringObj` etc. return
  ref=0 objects; appending to a list increments. We must mirror C
  exactly: `Tcl_IncrRefCount` immediately after `New*` when retaining,
  `Tcl_DecrRefCount` on release. See `feedback_new_record_ansistring.md`
  for analogous Pascal heap pitfalls — Tcl_Obj is opaque so this is safer.
* **Threading.** Bridge stays single-threaded; we do not import
  `Tcl_CreateThread`. Upstream test corpus mostly assumes ST too.
* **Driver failure-mode detection.** `tclsh` rc != 0 may indicate
  (a) test assertion failure, (b) interp crash, (c) load failure,
  (d) syntax error in the `.test`. Driver must capture both rc and
  the last 8 lines of stdout/stderr to disambiguate — emit FAIL with
  a short reason tag.
* **UTF-8 vs UTF-16 result paths.** Bridge will call
  `sqlite3_column_text` (UTF-8) and `Tcl_NewStringObj(..., -1)` which
  expects modified-UTF-8; embedded NULs need byte-array fallback —
  cross-reference `feedback_result_text_change_encoding.md`.
* **PACKAGE_VERSION.** Use pas-sqlite3's compile-time `SQLITE_VERSION`
  literal so `package require sqlite3 3.x` Just Works.

## 8. C reference cite block

All cites against `/home/bpsa/app/sqlite3/src/tclsqlite.c`:

* Stage 9.4.2.a (bridge skeleton)     — header includes 1..60; `Tclsqlite3_Init` shape ~4276.
* Stage 9.4.2.b (`Sqlite3_Init`)      — 4380..4470 (CreateObjCommand + PkgProvide).
* Stage 9.4.2.c (`DbMain` + close)    — `DbMain` 4253..4570; `close` arm of `DbObjCmd` 2480..2510.
* Stage 9.4.2.d (`db eval`)           — `dbEvalStep` 1766..; `eval` arm of `DbObjCmd` ~2700..2820.
* Stage 9.4.2.e (meta arms)           — `version` ~3705; `changes` ~2640; `last_insert_rowid` ~3300; `errorcode` ~2680; `nullvalue` ~3490.
* Stage 9.4.2.f (`db function`)       — `DbSqlFunc` 1000..1110; `function` arm of `DbObjCmd` ~3390..3470.
* Stage 9.4.2.g (`tester_min.tcl`)    — adapt `../sqlite3/test/tester.tcl:703..` (`do_test`) and `:941..` (`finalize_testing`).
* Stage 9.4.3.a (driver)              — no C ref; Pascal-only spawn harness.
* Stage 9.4.4.a (sweep)               — no C ref; triage convention only.
