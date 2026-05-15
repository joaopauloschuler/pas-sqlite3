program TestTclSqliteMeta;

{
  Phase 9.4.2.e smoke gate.

  Verifies the metadata passthroughs on the per-connection DbObjCmd:
    version, changes, last_insert_rowid, errorcode, nullvalue.
  See tclsqlite.c arms at 4161 (version), 2728 (changes), 3236
  (errorcode), 3524 (nullvalue), 3552 (last_insert_rowid).

  Step list (all must pass; otherwise Halt(1) with a FAIL line):
    1. Load bin/libpassqlite3tcl.so + package require sqlite3.
    2. sqlite3 db1 :memory:
    3. db1 version -> non-empty string starting with a decimal digit.
    4. Create table + 3 inserts.
       db1 changes  -> "3"  -- sqlite3_changes64 after final INSERT.
       db1 last_insert_rowid -> >0  -- autoincrement-style rowid.
    5. db1 errorcode -> "0".
    6. db1 nullvalue (getter) -> "".
       db1 nullvalue NIL ; db1 eval {select null} -> "NIL".
       db1 nullvalue ""  ; db1 eval {select null} -> "{}"
         (Tcl renders empty list element with braces).
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

  { Step 3 — version. }
  sRes := EvalGet('db1 version', rc);
  if rc <> TCL_OK then Die('db1 version rc=' + IntToStr(rc) + ' err=' + sRes);
  if Length(sRes) = 0 then Die('db1 version returned empty');
  if not (sRes[1] in ['0'..'9']) then
    Die('db1 version not digit-led: [' + sRes + ']');
  Writeln('PASS: db1 version -> [', sRes, ']');

  { Step 4 — DML + changes + last_insert_rowid. }
  sRes := EvalGet('db1 eval {create table t(x); insert into t values (1),(2),(3)}', rc);
  if rc <> TCL_OK then Die('insert rc=' + IntToStr(rc) + ' err=' + sRes);
  ExpectOk('db1 changes', '3', 'changes after 3-row insert');

  sRes := EvalGet('db1 last_insert_rowid', rc);
  if rc <> TCL_OK then Die('last_insert_rowid rc=' + IntToStr(rc) + ' err=' + sRes);
  if StrToIntDef(sRes, 0) <= 0 then
    Die('last_insert_rowid not >0: [' + sRes + ']');
  Writeln('PASS: db1 last_insert_rowid -> [', sRes, ']');

  { Step 5 — errorcode. }
  ExpectOk('db1 errorcode', '0', 'errorcode (no error)');

  { Step 6 — nullvalue getter / setter. }
  ExpectOk('db1 nullvalue', '', 'nullvalue default getter');

  sRes := EvalGet('db1 nullvalue NIL', rc);
  if rc <> TCL_OK then Die('nullvalue NIL rc=' + IntToStr(rc) + ' err=' + sRes);
  ExpectOk('db1 eval {select null}', 'NIL', 'select null with zNull=NIL');

  sRes := EvalGet('db1 nullvalue ""', rc);
  if rc <> TCL_OK then Die('nullvalue "" rc=' + IntToStr(rc) + ' err=' + sRes);
  ExpectOk('db1 eval {select null}', '{}', 'select null with zNull=""');

  sRes := EvalGet('db1 close', rc);
  if rc <> TCL_OK then Die('db1 close rc=' + IntToStr(rc) + ' err=' + sRes);
  Writeln('PASS: db1 close OK');

  Tcl_DeleteInterp(interp);
  Halt(0);
end.
