program TestTclSqliteInit;

{
  Phase 9.4.2.b smoke gate.

  Exercises the round trip:
    1.  InitTclLibrary + Tcl_CreateInterp.
    2.  `load <abs-path>/bin/libpassqlite3tcl.so Sqlite3`  — Tcl dlopens
        the shared object and calls Sqlite3_Init(interp).
    3.  `package require sqlite3`                          — checks that
        Tcl_PkgProvide ran (i.e. Sqlite3_Init returned TCL_OK) and
        echoes back the SQLITE_VERSION string.

  Library path resolution: we infer bin/ relative to ParamStr(0) so the
  test stays portable across checkout locations.  Tcl `load` rejects
  relative paths in some configurations, so we normalise to absolute
  via ExpandFileName.

  Exits Halt(0) on full success, Halt(1) with a stderr-shaped diagnostic
  on any failure.
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
begin
  InitTclLibrary;

  interp := Tcl_CreateInterp;
  if interp = nil then
  begin
    Writeln('FAIL: Tcl_CreateInterp returned nil');
    Halt(1);
  end;

  { ParamStr(0) is bin/TestTclSqliteInit; sibling .so is the package. }
  exeDir  := ExtractFilePath(ExpandFileName(ParamStr(0)));
  libPath := exeDir + 'libpassqlite3tcl.so';
  if not FileExists(libPath) then
  begin
    Writeln('FAIL: cannot find shared library at ', libPath);
    Tcl_DeleteInterp(interp);
    Halt(1);
  end;

  loadCmd := 'load {' + libPath + '} Sqlite3';
  rc := Tcl_Eval(interp, PChar(loadCmd));
  if rc <> TCL_OK then
  begin
    Writeln('FAIL: load rc=', rc,
            ' err=', Tcl_GetStringResult(interp));
    Tcl_DeleteInterp(interp);
    Halt(1);
  end;

  rc := Tcl_Eval(interp, PChar('package require sqlite3'));
  if rc <> TCL_OK then
  begin
    Writeln('FAIL: package require sqlite3 rc=', rc,
            ' err=', Tcl_GetStringResult(interp));
    Tcl_DeleteInterp(interp);
    Halt(1);
  end;

  zRes := Tcl_GetStringFromObj(Tcl_GetObjResult(interp), nil);
  if zRes = nil then sRes := '' else sRes := zRes;

  if sRes = '' then
  begin
    Writeln('FAIL: package require sqlite3 returned empty version');
    Tcl_DeleteInterp(interp);
    Halt(1);
  end;

  Writeln('PASS: load ', libPath, ' Sqlite3 OK');
  Writeln('PASS: package require sqlite3 -> ', sRes);
  Tcl_DeleteInterp(interp);
  Halt(0);
end.
