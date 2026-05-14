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

  sRes := EvalGet('db close', rc);
  if rc <> TCL_OK then Die('db close rc=' + IntToStr(rc) + ' err=' + sRes);
  Writeln('PASS: db close OK');

  Tcl_DeleteInterp(interp);
  Writeln('TestTclTesterMin: all expectations met (final nTest=3 nErr=1).');
  Halt(0);
end.
