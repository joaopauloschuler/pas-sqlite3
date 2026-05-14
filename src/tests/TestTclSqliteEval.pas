program TestTclSqliteEval;

{
  Phase 9.4.2.d smoke gate.

  Verifies that `db eval $sql` runs SQL through pas-sqlite3 via the
  Tcl bridge and returns rows as a flat Tcl list, matching what
  `puts [db eval ...]` users in tester.tcl expect.

  Step list (all must pass; otherwise Halt(1) with a FAIL line):
    1. Load bin/libpassqlite3tcl.so; package require sqlite3.
    2. sqlite3 db1 :memory:
    3. `db1 eval {create table t(x); insert into t values (1),(2),(3);
                   select x from t order by x}` -> expect "1 2 3".
    4. `db1 eval {select 'a', 'b', 'c'}`         -> expect "a b c".
    5. `db1 eval {select null, 42}`              -> expect "{} 42".
         The "{}" is Tcl's canonical rendering of an empty list
         element (Tcl_NewStringObj("", -1) with no escaping needed
         in any other form).  This matches upstream tclsqlite.c:1871
         when zNull == "" — Tcl serialises empty leading elements as
         "{}", not as a bare leading space.  Once `db nullvalue NIL`
         (9.4.2.e) sets zNull to a non-empty marker, that marker
         appears verbatim instead.
    6. Negative: `db1 eval {garbage syntax here}` -> rc=TCL_ERROR;
         result string should contain "syntax error" (case-insensitive
         match; we accept anything sqlite3_errmsg returns that starts
         with "near " — historically "near \"garbage\": syntax error").
    7. db1 close.
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

function LowerCase(const s: AnsiString): AnsiString;
var i: Integer;
begin
  SetLength(Result, Length(s));
  for i := 1 to Length(s) do
    if (s[i] >= 'A') and (s[i] <= 'Z') then
      Result[i] := Chr(Ord(s[i]) + 32)
    else
      Result[i] := s[i];
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
  sRes := EvalGet(loadCmd, rc);
  if rc <> TCL_OK then Die('load rc=' + IntToStr(rc) + ' err=' + sRes);
  sRes := EvalGet('package require sqlite3', rc);
  if rc <> TCL_OK then Die('package require rc=' + IntToStr(rc) + ' err=' + sRes);

  sRes := EvalGet('sqlite3 db1 :memory:', rc);
  if rc <> TCL_OK then Die('sqlite3 db1 :memory: rc=' + IntToStr(rc) + ' err=' + sRes);
  Writeln('PASS: sqlite3 db1 :memory: opened');

  { Step 3 — 3-row select returns "1 2 3". }
  ExpectOk(
    'db1 eval {create table t(x); insert into t values (1),(2),(3); select x from t order by x}',
    '1 2 3',
    'three-row select');

  { Step 4 — string literals. }
  ExpectOk(
    'db1 eval {select ''a'', ''b'', ''c''}',
    'a b c',
    'three string literals');

  { Step 5 — null + 42 with default zNull=nil renders as " 42"
    (empty-string column followed by space + 42). }
  ExpectOk(
    'db1 eval {select null, 42}',
    '{} 42',
    'null + 42 with default zNull');

  { Step 6 — syntax error path. }
  sRes := EvalGet('db1 eval {garbage syntax here}', rc);
  if rc = TCL_OK then
    Die('garbage SQL returned TCL_OK; expected TCL_ERROR');
  if Pos('syntax', LowerCase(sRes)) = 0 then
    Die('garbage SQL err msg did not contain "syntax": [' + sRes + ']');
  Writeln('PASS: garbage SQL rc=', rc, ' msg="', sRes, '"');

  sRes := EvalGet('db1 close', rc);
  if rc <> TCL_OK then Die('db1 close rc=' + IntToStr(rc) + ' err=' + sRes);
  Writeln('PASS: db1 close OK');

  Tcl_DeleteInterp(interp);
  Halt(0);
end.
