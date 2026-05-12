{
  SPDX-License-Identifier: blessing

  TestShellModes — phase 10.1b gate.  Drives the passqlite3 CLI through
  every output mode (.mode list/line/column/csv/tabs/html/insert/quote/
  json/markdown/table/box/tcl/ascii) plus .headers / .separator /
  .nullvalue / .width / .print, and diffs the byte stream against the
  upstream sqlite3 binary (the same canon used by all other 10.1 gates).

  Fixed regressions:
    * MODE_Column / MODE_Table / MODE_Box left-aligned every cell.
      qrf.c:1514 right-aligns numeric (INTEGER/FLOAT) columns by
      default; mixing in any TEXT/BLOB cell flips the column back to
      left-align.  A negative .width N forces right-align regardless
      of types (qrf.c:1696).

  Skips cleanly with PASS if the upstream sqlite3 binary is unavailable
  on PATH or at $UPSTREAM_SQLITE3 — keeps build green on stripped CI
  while still gating locally.
}
{$I ../passqlite3.inc}
program TestShellModes;

uses
  SysUtils, BaseUnix, Unix,
  passqlite3types, passqlite3util;

var
  failCount: i32 = 0;
  passCount: i32 = 0;

function readAll(const path: AnsiString): AnsiString;
var
  f: file of Byte;
  n: SizeInt;
  buf: array[0..4095] of Byte;
  i: SizeInt;
begin
  Result := '';
  AssignFile(f, path); {$I-} Reset(f); {$I+}
  if IOResult <> 0 then Exit;
  while not Eof(f) do begin
    BlockRead(f, buf[0], SizeOf(buf), n);
    if n <= 0 then Break;
    i := Length(Result);
    SetLength(Result, i + n);
    Move(buf[0], Result[i + 1], n);
  end;
  CloseFile(f);
end;

function findUpstreamSqlite3: AnsiString;
var
  z: AnsiString;
  candidates: array[0..3] of AnsiString;
  i: SizeInt;
begin
  z := GetEnvironmentVariable('UPSTREAM_SQLITE3');
  if (z <> '') and FileExists(z) then begin Result := z; Exit; end;
  candidates[0] := '/home/bpsa/app/sqlite3/sqlite3';
  candidates[1] := ExtractFilePath(ExpandFileName(ParamStr(0))) +
                   '../../sqlite3/sqlite3';
  candidates[2] := '/usr/local/bin/sqlite3';
  candidates[3] := '/usr/bin/sqlite3';
  for i := 0 to High(candidates) do
    if FileExists(candidates[i]) then begin Result := candidates[i]; Exit; end;
  Result := '';
end;

procedure DiffCase(const name, sql: AnsiString; upstream: AnsiString);
var
  sqlPath, expPath, actPath, cmd, exeDir, binPath, libDir: AnsiString;
  f: TextFile;
  rcExp, rcAct: i32;
  expBody, actBody: AnsiString;
begin
  sqlPath := SysUtils.GetTempDir(False) + 'pas_modes_in_'  +
             IntToStr(GetProcessID) + '.sql';
  expPath := SysUtils.GetTempDir(False) + 'pas_modes_exp_' +
             IntToStr(GetProcessID) + '.txt';
  actPath := SysUtils.GetTempDir(False) + 'pas_modes_act_' +
             IntToStr(GetProcessID) + '.txt';
  AssignFile(f, sqlPath); Rewrite(f); Write(f, sql); CloseFile(f);

  exeDir  := ExtractFilePath(ExpandFileName(ParamStr(0)));
  binPath := exeDir + 'passqlite3';
  libDir  := ExtractFilePath(ExcludeTrailingPathDelimiter(exeDir)) + 'src';

  cmd := '"' + upstream + '" :memory: <"' + sqlPath +
         '" >"' + expPath + '" 2>&1';
  rcExp := fpsystem(cmd);

  cmd := 'LD_LIBRARY_PATH="' + libDir + '" "' + binPath +
         '" :memory: <"' + sqlPath + '" >"' + actPath + '" 2>&1';
  rcAct := fpsystem(cmd);

  expBody := readAll(expPath);
  actBody := readAll(actPath);
  SysUtils.DeleteFile(sqlPath);
  SysUtils.DeleteFile(expPath);
  SysUtils.DeleteFile(actPath);

  if (rcExp = rcAct) and (expBody = actBody) then begin
    WriteLn('PASS    ', name, ' (rc=', rcAct, ')');
    Inc(passCount);
  end else begin
    WriteLn('FAIL    ', name, ' (rcExp=', rcExp, ' rcAct=', rcAct, ')');
    WriteLn('  expected (', Length(expBody), ' bytes):');
    WriteLn('  |', expBody, '|');
    WriteLn('  actual   (', Length(actBody), ' bytes):');
    WriteLn('  |', actBody, '|');
    Inc(failCount);
  end;
end;

const
  { Exercises every column-mode renderer plus .headers/.separator/
    .nullvalue/.width and .print formatting controls.  Three rows with
    INTEGER / TEXT / REAL columns so numeric right-align vs text
    left-align is visible in MODE_Column/Table/Box. }
  SCRIPT_AllModes =
    'CREATE TABLE t(a INTEGER, b TEXT, c REAL);'#10 +
    'INSERT INTO t VALUES(1,''one'',1.5),(2,''two'',NULL),'+
                       '(3,''three'',3.14);'#10 +
    '.headers on'#10 +
    '.mode list'#10     + 'SELECT * FROM t;'#10 +
    '.mode line'#10     + 'SELECT * FROM t;'#10 +
    '.mode column'#10   + 'SELECT * FROM t;'#10 +
    '.mode csv'#10      + 'SELECT * FROM t;'#10 +
    '.mode tabs'#10     + 'SELECT * FROM t;'#10 +
    '.mode html'#10     + 'SELECT * FROM t;'#10 +
    '.mode insert tt'#10+ 'SELECT * FROM t;'#10 +
    '.mode quote'#10    + 'SELECT * FROM t;'#10 +
    '.mode json'#10     + 'SELECT * FROM t;'#10 +
    '.mode markdown'#10 + 'SELECT * FROM t;'#10 +
    '.mode table'#10    + 'SELECT * FROM t;'#10 +
    '.mode box'#10      + 'SELECT * FROM t;'#10 +
    '.mode tcl'#10      + 'SELECT * FROM t;'#10 +
    '.mode ascii'#10    + 'SELECT * FROM t;'#10 +
    '.headers off'#10 +
    '.nullvalue NIL'#10 +
    '.separator |~| @'#10 +
    '.mode list'#10     + 'SELECT * FROM t;'#10 +
    '.separator | @'#10 +
    '.width 5 10 5'#10 +
    '.mode column'#10 +
    '.headers on'#10 +
    'SELECT * FROM t;'#10 +
    '.width -5 -10 -5'#10 +
    'SELECT * FROM t;'#10 +
    '.print Hello, World'#10;

  { Right-align is type-driven: a TEXT cell in the second column forces
    that column to left-align even though the first row's value would
    parse as a number on its own.  Catches the regression where the
    type-tracking only checked the first row. }
  SCRIPT_MixedTypes =
    'CREATE TABLE m(x);'#10 +
    'INSERT INTO m VALUES(1),(2),(''abc'');'#10 +
    '.mode column'#10 +
    '.headers on'#10 +
    'SELECT * FROM m;'#10;

var
  upstream: AnsiString;

begin
  upstream := findUpstreamSqlite3;
  if upstream = '' then begin
    WriteLn('SKIP    TestShellModes: no upstream sqlite3 binary found');
    WriteLn('        Set UPSTREAM_SQLITE3=/path/to/sqlite3 to enable.');
    Halt(0);
  end;
  WriteLn('Using upstream: ', upstream);

  DiffCase('all modes parity',  SCRIPT_AllModes,   upstream);
  DiffCase('mixed-type column', SCRIPT_MixedTypes, upstream);

  WriteLn;
  WriteLn(Format('TestShellModes: %d PASS / %d FAIL',
                 [passCount, failCount]));
  if failCount > 0 then Halt(1);
end.
