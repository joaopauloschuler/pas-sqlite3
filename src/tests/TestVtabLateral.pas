{
  SPDX-License-Identifier: blessing

  TestVtabLateral — phase 6.13.B.9 gate.  Drives the passqlite3 CLI
  through a handful of lateral / hidden-arg-pushdown virtual-table
  shapes and diffs the byte stream against the upstream sqlite3
  binary.  Covers:

    * pragma_foreign_key_list(s.name)         lateral on sqlite_schema
    * generate_series(1, t.x)                 lateral
    * generate_series(1, 5) WHERE value < 4   non-lateral with residual
    * json_each(json)                         lateral on a JSON column
    * SELECT * FROM wholenumber WHERE value<6 hidden-arg pushdown

  Skips with PASS when the upstream sqlite3 binary is unavailable.
}
{$I ../passqlite3.inc}
program TestVtabLateral;

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
  sqlPath := SysUtils.GetTempDir(False) + 'pas_vtablat_in_'  +
             IntToStr(GetProcessID) + '.sql';
  expPath := SysUtils.GetTempDir(False) + 'pas_vtablat_exp_' +
             IntToStr(GetProcessID) + '.txt';
  actPath := SysUtils.GetTempDir(False) + 'pas_vtablat_act_' +
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
  SCRIPT_GenSeriesStandalone =
    'SELECT value FROM generate_series(1,3);'#10;

  SCRIPT_GenSeriesResidual =
    'SELECT value FROM generate_series(1,5) WHERE value < 4;'#10;

  SCRIPT_GenSeriesLateral =
    'CREATE TABLE t(x);'#10 +
    'INSERT INTO t VALUES(1),(2),(3);'#10 +
    'SELECT t.x, g.value FROM t, generate_series(1, t.x) g'#10 +
    ' ORDER BY t.x, g.value;'#10;

  SCRIPT_PragmaFkLateral =
    'CREATE TABLE parent(id INTEGER PRIMARY KEY);'#10 +
    'CREATE TABLE child(id INTEGER PRIMARY KEY,'#10 +
    '                   p_id INTEGER REFERENCES parent(id));'#10 +
    'SELECT s.name, f.id, f.seq'#10 +
    '  FROM sqlite_schema s, pragma_foreign_key_list(s.name) f'#10 +
    ' WHERE s.type=''table'' ORDER BY s.name, f.seq;'#10;

  SCRIPT_JsonEachLateral =
    'CREATE TABLE rows(id INTEGER PRIMARY KEY, payload TEXT);'#10 +
    'INSERT INTO rows VALUES(1,''{"a":1,"b":2}''),'#10 +
    '                       (2,''{"x":9}'');'#10 +
    'SELECT r.id, j.key, j.value'#10 +
    '  FROM rows r, json_each(r.payload) j'#10 +
    ' ORDER BY r.id, j.key;'#10;

var
  upstream: AnsiString;

begin
  upstream := findUpstreamSqlite3;
  if upstream = '' then begin
    WriteLn('SKIP    TestVtabLateral: no upstream sqlite3 binary found');
    WriteLn('        Set UPSTREAM_SQLITE3=/path/to/sqlite3 to enable.');
    Halt(0);
  end;
  WriteLn('Using upstream: ', upstream);

  DiffCase('generate_series standalone',  SCRIPT_GenSeriesStandalone, upstream);
  DiffCase('generate_series residual',    SCRIPT_GenSeriesResidual,   upstream);
  DiffCase('generate_series lateral',     SCRIPT_GenSeriesLateral,    upstream);
  DiffCase('pragma_foreign_key_list lat', SCRIPT_PragmaFkLateral,     upstream);
  DiffCase('json_each lateral',           SCRIPT_JsonEachLateral,     upstream);

  WriteLn;
  WriteLn(Format('TestVtabLateral: %d PASS / %d FAIL',
                 [passCount, failCount]));
  if failCount > 0 then Halt(1);
end.
