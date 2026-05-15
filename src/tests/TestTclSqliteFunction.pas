program TestTclSqliteFunction;

{
  Phase 9.4.2.f smoke gate.

  Verifies `db1 function NAME ?-argcount N? ?-deterministic? PROC`
  on the per-connection DbObjCmd.  See tclsqlite.c:3386 (DB_FUNCTION
  arm) and tclsqlite.c:1015 (tclSqlFunc trampoline) for the C
  reference.

  Step list (all must pass; otherwise Halt(1) with a FAIL line):
    1. Load bin/libpassqlite3tcl.so + package require sqlite3.
    2. sqlite3 db1 :memory:
    3. db1 function tcl_add {a b} { expr {$a + $b} }
       db1 eval {select tcl_add(2, 3)} -> "5"
    4. db1 function tcl_upper {s} { string toupper $s }
       db1 eval {select tcl_upper('hello')} -> "HELLO"
    5. db1 function tcl_err {} { error "boom" }
       db1 eval {select tcl_err()} -> rc=TCL_ERROR, message contains
       "boom".
    6. db1 function tcl_det -deterministic {x} { expr {$x*$x} }
       db1 eval {select tcl_det(7)} -> "49"  (just confirms the
       flag parser accepts -deterministic; we don't probe the
       function-flags bitmask explicitly).
    7. db1 close.  Halt(0).
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
  libPath, exeDir: AnsiString;

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

procedure ExpectOk(const cmd, want, tag: AnsiString);
begin
  sRes := EvalGet(cmd, rc);
  if rc <> TCL_OK then
    Die(tag + ' rc=' + IntToStr(rc) + ' err=' + sRes);
  if sRes <> want then
    Die(tag + ' got=[' + sRes + '] want=[' + want + ']');
  Writeln('PASS: ', tag, ' -> [', sRes, ']');
end;

begin
  InitTclLibrary;
  interp := Tcl_CreateInterp;
  if interp = nil then
  begin
    Writeln('FAIL: Tcl_CreateInterp returned nil');
    Halt(1);
  end;

  exeDir  := ExtractFilePath(ExpandFileName(ParamStr(0)));
  libPath := exeDir + 'libpassqlite3tcl.so';
  if not FileExists(libPath) then
    Die('cannot find shared library at ' + libPath);

  sRes := EvalGet('load {' + libPath + '} Sqlite3', rc);
  if rc <> TCL_OK then Die('load rc=' + IntToStr(rc) + ' err=' + sRes);
  sRes := EvalGet('package require sqlite3', rc);
  if rc <> TCL_OK then Die('package require rc=' + IntToStr(rc) + ' err=' + sRes);

  sRes := EvalGet('sqlite3 db1 :memory:', rc);
  if rc <> TCL_OK then Die('sqlite3 db1 :memory: rc=' + IntToStr(rc) + ' err=' + sRes);
  Writeln('PASS: sqlite3 db1 :memory: opened');

  { Define Tcl procs first; pScript is a procedure name.  This is the
    most common upstream usage pattern (see ext/misc/tester.tcl
    `set_test_count_increment` etc.). }
  sRes := EvalGet('proc p_add {a b} { expr {$a + $b} }', rc);
  if rc <> TCL_OK then Die('proc p_add rc=' + IntToStr(rc) + ' err=' + sRes);
  sRes := EvalGet('proc p_upper {s} { string toupper $s }', rc);
  if rc <> TCL_OK then Die('proc p_upper rc=' + IntToStr(rc) + ' err=' + sRes);
  sRes := EvalGet('proc p_err {} { error "boom" }', rc);
  if rc <> TCL_OK then Die('proc p_err rc=' + IntToStr(rc) + ' err=' + sRes);
  sRes := EvalGet('proc p_sq {x} { expr {$x*$x} }', rc);
  if rc <> TCL_OK then Die('proc p_sq rc=' + IntToStr(rc) + ' err=' + sRes);

  { Step 3 — tcl_add: numeric UDF. }
  sRes := EvalGet('db1 function tcl_add p_add', rc);
  if rc <> TCL_OK then Die('register tcl_add rc=' + IntToStr(rc) + ' err=' + sRes);
  Writeln('PASS: db1 function tcl_add registered');
  ExpectOk('db1 eval {select tcl_add(2, 3)}', '5', 'tcl_add(2,3)');

  { Step 4 — tcl_upper: text UDF. }
  sRes := EvalGet('db1 function tcl_upper p_upper', rc);
  if rc <> TCL_OK then Die('register tcl_upper rc=' + IntToStr(rc) + ' err=' + sRes);
  Writeln('PASS: db1 function tcl_upper registered');
  ExpectOk('db1 eval {select tcl_upper(''hello'')}', 'HELLO', 'tcl_upper(hello)');

  { Step 5 — tcl_err: error propagation. }
  sRes := EvalGet('db1 function tcl_err p_err', rc);
  if rc <> TCL_OK then Die('register tcl_err rc=' + IntToStr(rc) + ' err=' + sRes);
  sRes := EvalGet('db1 eval {select tcl_err()}', rc);
  if rc = TCL_OK then
    Die('tcl_err: expected TCL_ERROR but got TCL_OK with result=[' + sRes + ']');
  if Pos('boom', sRes) = 0 then
    Die('tcl_err: error message missing "boom", got=[' + sRes + ']');
  Writeln('PASS: tcl_err -> rc=', rc, ' msg=[', sRes, ']');

  { Step 6 — -deterministic flag accepted. }
  sRes := EvalGet('db1 function tcl_det -deterministic p_sq', rc);
  if rc <> TCL_OK then Die('register tcl_det rc=' + IntToStr(rc) + ' err=' + sRes);
  Writeln('PASS: db1 function tcl_det -deterministic registered');
  ExpectOk('db1 eval {select tcl_det(7)}', '49', 'tcl_det(7)');

  sRes := EvalGet('db1 close', rc);
  if rc <> TCL_OK then Die('db1 close rc=' + IntToStr(rc) + ' err=' + sRes);
  Writeln('PASS: db1 close OK');

  Tcl_DeleteInterp(interp);
  Halt(0);
end.
