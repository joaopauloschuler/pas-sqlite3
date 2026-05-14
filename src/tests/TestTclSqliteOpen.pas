program TestTclSqliteOpen;

{
  Phase 9.4.2.c smoke gate.

  Verifies that DbMain actually constructs a `:memory:` connection and
  that `db1 close` (DB_CLOSE arm) plus the implicit-delete path
  (`rename db1 ""`) both fire DbDeleteCmd without crashing.

  Sequence:
    1. Load bin/libpassqlite3tcl.so; package require sqlite3.
    2. `sqlite3 db1 :memory:`            — DbMain → sqlite3_open_v2.
    3. `db1 close`                       — DbObjCmd close arm.
    4. `sqlite3 db1 :memory:` again.
    5. `db1 unknownsub`                  — assert TCL_ERROR (subcommands
                                            other than close land in
                                            9.4.2.d..f); record the
                                            error message.
    6. `rename db1 ""`                   — implicit Tcl_DeleteCommand
                                            path; DbDeleteCmd must
                                            close the connection.

  Halts 0 only when every step matches expectation.
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
  libPath, exeDir, loadCmd: AnsiString;

procedure Die(const msg: AnsiString);
begin
  Writeln('FAIL: ', msg);
  if interp <> nil then Tcl_DeleteInterp(interp);
  Halt(1);
end;

function EvalOk(const cmd: AnsiString; const tag: AnsiString): AnsiString;
begin
  rc := Tcl_Eval(interp, PChar(cmd));
  zRes := Tcl_GetStringFromObj(Tcl_GetObjResult(interp), nil);
  if zRes = nil then Result := '' else Result := zRes;
  if rc <> TCL_OK then
    Die(tag + ' rc=' + IntToStr(rc) + ' err=' + Result);
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

  loadCmd := 'load {' + libPath + '} Sqlite3';
  EvalOk(loadCmd, 'load');
  EvalOk('package require sqlite3', 'package require');

  { Step 2 — explicit open. }
  EvalOk('sqlite3 db1 :memory:', 'sqlite3 db1 :memory:');
  Writeln('PASS: sqlite3 db1 :memory: opened');

  { Step 3 — close arm. }
  EvalOk('db1 close', 'db1 close');
  Writeln('PASS: db1 close OK');

  { Step 4 — re-open. }
  EvalOk('sqlite3 db1 :memory:', 'sqlite3 db1 :memory: (re-open)');

  { Step 5 — unknown subcommand must return TCL_ERROR, not crash. }
  rc := Tcl_Eval(interp, PChar('db1 unknownsub'));
  zRes := Tcl_GetStringFromObj(Tcl_GetObjResult(interp), nil);
  if zRes = nil then sRes := '' else sRes := zRes;
  if rc = TCL_OK then
    Die('db1 unknownsub returned TCL_OK; expected TCL_ERROR');
  Writeln('PASS: db1 unknownsub rc=', rc, ' msg="', sRes, '"');

  { Step 6 — rename to "" must invoke DbDeleteCmd without crashing. }
  EvalOk('rename db1 ""', 'rename db1 ""');
  Writeln('PASS: rename db1 "" OK (DbDeleteCmd fired)');

  Tcl_DeleteInterp(interp);
  Halt(0);
end.
