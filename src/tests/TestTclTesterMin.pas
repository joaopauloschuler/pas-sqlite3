program TestTclTesterMin;

{
  Phase 9.4.2.g smoke gate.

  Verifies tester_min.tcl (sourced from disk) wires do_test /
  do_execsql_test / execsql / set_test_counter correctly against the
  pas-sqlite3 Tcl bridge.

  Steps (Halt(1) with FAIL line on any failure):
    1. Load bin/libpassqlite3tcl.so; package require sqlite3.
    2. source ../src/tests/tcl/tester_min.tcl from the binary's dir.
    3. sqlite3 db :memory: (the global `db` handle tester_min expects).
    4. do_test foo-1.0 (expr 1+1, expected 2)
         expect rc=TCL_OK and set_test_counter nErr == 0.
    5. do_execsql_test foo-2.0 (create-table + select), expected 1 2 3
         expect rc=TCL_OK and set_test_counter nErr still 0.
    6. do_test foo-3.0 (1+1 vs 99, intentional fail)
         expect rc=TCL_OK and set_test_counter nErr == 1.
    7. db close; verify rc=0.
}

{$mode objfpc}{$H+}

uses
  SysUtils,
  ctypes,
  PasTclBridge;

var
  interp: PTclInterp;
  rc: cint;
  zRes: PChar;
  sRes: AnsiString;
  exeDir, libPath, testerPath, loadCmd, srcCmd: AnsiString;

procedure Die(const msg: AnsiString);
begin
  Writeln('FAIL: ', msg);
  if interp <> nil then Tcl_DeleteInterp(interp);
  Halt(1);
end;

function EvalGet(const cmd: AnsiString; out outRc: cint): AnsiString;
begin
  outRc := Tcl_Eval(interp, PChar(cmd));
  zRes := Tcl_GetStringFromObj(Tcl_GetObjResult(interp), nil);
  if zRes = nil then Result := '' else Result := zRes;
end;

function CounterNErr: Integer;
var s: AnsiString; r: cint;
begin
  s := EvalGet('set_test_counter errors', r);
  if r <> TCL_OK then
    Die('set_test_counter errors rc=' + IntToStr(r) + ' err=' + s);
  Result := StrToIntDef(s, -1);
end;

function CounterNTest: Integer;
var s: AnsiString; r: cint;
begin
  s := EvalGet('set_test_counter count', r);
  if r <> TCL_OK then
    Die('set_test_counter count rc=' + IntToStr(r) + ' err=' + s);
  Result := StrToIntDef(s, -1);
end;

begin
  InitTclLibrary;

  interp := Tcl_CreateInterp;
  if interp = nil then
  begin
    Writeln('FAIL: Tcl_CreateInterp returned nil');
    Halt(1);
  end;

  exeDir := ExtractFilePath(ExpandFileName(ParamStr(0)));
  libPath := exeDir + 'libpassqlite3tcl.so';
  if not FileExists(libPath) then Die('missing ' + libPath);

  { Tester shim path: bin/ -> ../src/tests/tcl/tester_min.tcl. }
  testerPath := exeDir + '../src/tests/tcl/tester_min.tcl';
  if not FileExists(testerPath) then Die('missing ' + testerPath);

  loadCmd := 'load {' + libPath + '} Sqlite3';
  sRes := EvalGet(loadCmd, rc);
  if rc <> TCL_OK then Die('load rc=' + IntToStr(rc) + ' err=' + sRes);
  sRes := EvalGet('package require sqlite3', rc);
  if rc <> TCL_OK then Die('package require rc=' + IntToStr(rc) + ' err=' + sRes);

  srcCmd := 'source {' + testerPath + '}';
  sRes := EvalGet(srcCmd, rc);
  if rc <> TCL_OK then Die('source tester_min.tcl rc=' + IntToStr(rc) + ' err=' + sRes);
  Writeln('PASS: sourced ', testerPath);

  sRes := EvalGet('sqlite3 db :memory:', rc);
  if rc <> TCL_OK then Die('sqlite3 db :memory: rc=' + IntToStr(rc) + ' err=' + sRes);

  if CounterNErr <> 0 then Die('initial nErr <> 0: ' + IntToStr(CounterNErr));
  if CounterNTest <> 0 then Die('initial nTest <> 0: ' + IntToStr(CounterNTest));

  { Step 4 — passing do_test. }
  sRes := EvalGet('do_test foo-1.0 { expr 1+1 } 2', rc);
  if rc <> TCL_OK then Die('do_test foo-1.0 rc=' + IntToStr(rc) + ' err=' + sRes);
  if CounterNErr <> 0 then Die('after foo-1.0 nErr=' + IntToStr(CounterNErr) + ' want 0');
  if CounterNTest <> 1 then Die('after foo-1.0 nTest=' + IntToStr(CounterNTest) + ' want 1');
  Writeln('PASS: foo-1.0 passing do_test, nTest=1 nErr=0');

  { Step 5 — passing do_execsql_test. }
  sRes := EvalGet(
    'do_execsql_test foo-2.0 ' +
    '{ create table t(x); insert into t values (1),(2),(3); select x from t } ' +
    '{1 2 3}',
    rc);
  if rc <> TCL_OK then Die('do_execsql_test foo-2.0 rc=' + IntToStr(rc) + ' err=' + sRes);
  if CounterNErr <> 0 then Die('after foo-2.0 nErr=' + IntToStr(CounterNErr) + ' want 0');
  if CounterNTest <> 2 then Die('after foo-2.0 nTest=' + IntToStr(CounterNTest) + ' want 2');
  Writeln('PASS: foo-2.0 passing do_execsql_test, nTest=2 nErr=0');

  { Step 6 — intentional failure: rc must still be TCL_OK (do_test
    catches and counts), but nErr must increment to 1. }
  sRes := EvalGet('do_test foo-3.0 { expr 1+1 } 99', rc);
  if rc <> TCL_OK then Die('do_test foo-3.0 unexpectedly rc=' + IntToStr(rc) + ' err=' + sRes);
  if CounterNErr <> 1 then Die('after foo-3.0 nErr=' + IntToStr(CounterNErr) + ' want 1');
  if CounterNTest <> 3 then Die('after foo-3.0 nTest=' + IntToStr(CounterNTest) + ' want 3');
  Writeln('PASS: foo-3.0 intentional fail counted, nTest=3 nErr=1');

  { Step 7 — ifcapable stub (9.4.2.g.1).  Body must run regardless of
    EXPR.  We seed a sentinel inside BODY and check it after; also run
    a do_test inside ifcapable to confirm the counter advances. }
  sRes := EvalGet('set ::ifcap_seen 0', rc);
  if rc <> TCL_OK then Die('seed ifcap_seen rc=' + IntToStr(rc) + ' err=' + sRes);
  sRes := EvalGet(
    'ifcapable {nosuchcap && bogus_expr} { set ::ifcap_seen 1; do_test foo-4.0 { expr 2+2 } 4 }',
    rc);
  if rc <> TCL_OK then Die('ifcapable rc=' + IntToStr(rc) + ' err=' + sRes);
  sRes := EvalGet('set ::ifcap_seen', rc);
  if (rc <> TCL_OK) or (sRes <> '1') then
    Die('ifcap_seen=' + sRes + ' want 1 (body did not execute)');
  if CounterNErr <> 1 then Die('after foo-4.0 nErr=' + IntToStr(CounterNErr) + ' want 1');
  if CounterNTest <> 4 then Die('after foo-4.0 nTest=' + IntToStr(CounterNTest) + ' want 4');
  Writeln('PASS: foo-4.0 ifcapable body ran, nTest=4 nErr=1');

  { Step 8 — catchsql (9.4.2.g.2).  Success arm returns "0 2"; failure
    arm returns "1 {no such table: ...}".  We check both strings
    exactly against the format tclsh produces under upstream tester.tcl. }
  sRes := EvalGet('catchsql {select 1+1}', rc);
  if rc <> TCL_OK then Die('catchsql ok rc=' + IntToStr(rc) + ' err=' + sRes);
  if sRes <> '0 2' then Die('catchsql ok got=[' + sRes + '] want [0 2]');
  Writeln('PASS: catchsql {select 1+1} -> [', sRes, ']');

  sRes := EvalGet('catchsql {select * from nosuchtable}', rc);
  if rc <> TCL_OK then Die('catchsql err rc=' + IntToStr(rc) + ' err=' + sRes);
  if sRes <> '1 {no such table: nosuchtable}' then
    Die('catchsql err got=[' + sRes + '] want [1 {no such table: nosuchtable}]');
  Writeln('PASS: catchsql {select * from nosuchtable} -> [', sRes, ']');

  { Step 9 — do_catchsql_test (9.4.2.g.2).  Wraps catchsql + do_test;
    the expected list is the `{rc errmsg}` pair.  Must PASS (no nErr
    bump). }
  sRes := EvalGet(
    'do_catchsql_test fail-1 {select * from nosuchtable} ' +
    '{1 {no such table: nosuchtable}}',
    rc);
  if rc <> TCL_OK then Die('do_catchsql_test rc=' + IntToStr(rc) + ' err=' + sRes);
  if CounterNErr <> 1 then Die('after fail-1 nErr=' + IntToStr(CounterNErr) + ' want 1');
  if CounterNTest <> 5 then Die('after fail-1 nTest=' + IntToStr(CounterNTest) + ' want 5');
  Writeln('PASS: do_catchsql_test fail-1, nTest=5 nErr=1');

  sRes := EvalGet('db close', rc);
  if rc <> TCL_OK then Die('db close rc=' + IntToStr(rc) + ' err=' + sRes);
  Writeln('PASS: db close OK');

  { Step 10 — forcedelete / delete_file smoke (9.4.2.g.3).
    (a) Create /tmp/pas94_g3_smoke; touch a file; forcedelete; assert gone.
    (b) delete_file on non-existent path -> silent (no error).
  }
  sRes := EvalGet('file mkdir /tmp/pas94_g3_smoke', rc);
  if rc <> TCL_OK then Die('mkdir rc=' + IntToStr(rc) + ' err=' + sRes);
  sRes := EvalGet(
    'set fp [open /tmp/pas94_g3_smoke/touched w]; puts $fp hi; close $fp; ' +
    'file exists /tmp/pas94_g3_smoke/touched',
    rc);
  if (rc <> TCL_OK) or (sRes <> '1') then
    Die('touch+exists got=[' + sRes + '] rc=' + IntToStr(rc));
  sRes := EvalGet('forcedelete /tmp/pas94_g3_smoke/touched', rc);
  if rc <> TCL_OK then Die('forcedelete rc=' + IntToStr(rc) + ' err=' + sRes);
  sRes := EvalGet('file exists /tmp/pas94_g3_smoke/touched', rc);
  if (rc <> TCL_OK) or (sRes <> '0') then
    Die('post-forcedelete exists=[' + sRes + '] want 0');
  Writeln('PASS: forcedelete removed /tmp/pas94_g3_smoke/touched');

  sRes := EvalGet('delete_file /tmp/pas94_g3_smoke/nosuchfile_xyz', rc);
  if rc = TCL_OK then
  begin
    { delete_file on a missing path: upstream behaviour is `file delete`
      which is silent on a non-existent leaf — accept that. }
    Writeln('PASS: delete_file on missing path is silent');
  end
  else
  begin
    Die('delete_file missing path unexpectedly errored: rc=' +
        IntToStr(rc) + ' err=' + sRes);
  end;

  { forcedelete the directory itself (recursive). }
  sRes := EvalGet('forcedelete /tmp/pas94_g3_smoke', rc);
  if rc <> TCL_OK then Die('forcedelete dir rc=' + IntToStr(rc) + ' err=' + sRes);

  { Step 11 — finish_test (9.4.2.g.3).  finalize_testing calls exit, so
    we cannot run it in-process here without aborting the harness.
    Instead, shell out to tclsh: source tester_min.tcl, run a tiny do_test,
    then finish_test.  Expect rc=0 and a "0 errors out of 1 tests" line. }
  Tcl_DeleteInterp(interp);
  interp := nil;
  Writeln('PASS: TestTclTesterMin in-process steps complete; finish_test covered by build_test_tcl_tester_min.sh sub-tclsh run.');
  Halt(0);
end.
