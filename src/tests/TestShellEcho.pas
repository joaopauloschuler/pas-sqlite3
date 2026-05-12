{
  SPDX-License-Identifier: blessing

  TestShellEcho — regression for CLI `.echo on` echoing input lines.

  Before the fix, the CLI parsed/stored MFLG_ECHO but never wired the
  echo_group_input(p,zSql) calls upstream emits at six locations in
  shell.c.in (process_input around lines 12461..12532, and the -cmd
  driver at 13527).  Symptom: `.echo on` was a silent no-op.

  This regression spawns bin/passqlite3 and confirms every non-`.echo`
  input line is echoed to stdout immediately before it runs.
}
{$I ../passqlite3.inc}
program TestShellEcho;

uses
  SysUtils, BaseUnix, Unix,
  passqlite3types, passqlite3util;

var
  failCount: i32 = 0;
  passCount: i32 = 0;

function readAll(const path: AnsiString): AnsiString;
var f: TextFile; line, acc: AnsiString;
begin
  acc := '';
  AssignFile(f, path); {$I-} Reset(f); {$I+}
  if IOResult <> 0 then begin Result := ''; Exit; end;
  while not Eof(f) do begin ReadLn(f, line); acc := acc + line + #10; end;
  CloseFile(f);
  Result := acc;
end;

procedure RunCase(const name, sql, expectSubstr: AnsiString;
                  mustNotContain: AnsiString = '');
var
  sqlPath, outPath, cmd, exeDir, binPath, libDir: AnsiString;
  f: TextFile;
  rc: i32;
  body: AnsiString;
  ok: Boolean;
begin
  sqlPath := SysUtils.GetTempDir(False) + 'pas_echo_in_' +
             IntToStr(GetProcessID) + '.sql';
  outPath := SysUtils.GetTempDir(False) + 'pas_echo_out_' +
             IntToStr(GetProcessID) + '.txt';
  AssignFile(f, sqlPath); Rewrite(f); Write(f, sql); CloseFile(f);

  exeDir  := ExtractFilePath(ExpandFileName(ParamStr(0)));
  binPath := exeDir + 'passqlite3';
  libDir  := ExtractFilePath(ExcludeTrailingPathDelimiter(exeDir)) + 'src';

  cmd := 'LD_LIBRARY_PATH="' + libDir + '" "' + binPath +
         '" :memory: <"' + sqlPath + '" >"' + outPath + '" 2>&1';
  rc := fpsystem(cmd);
  body := readAll(outPath);
  SysUtils.DeleteFile(sqlPath);
  SysUtils.DeleteFile(outPath);

  ok := Pos(expectSubstr, body) > 0;
  if (mustNotContain <> '') and (Pos(mustNotContain, body) > 0) then
    ok := False;
  if ok then begin
    WriteLn('PASS    ', name, ' (rc=', rc, ')');
    Inc(passCount);
  end else begin
    WriteLn('FAIL    ', name, ' (rc=', rc, ')');
    WriteLn('  expected substring: |', expectSubstr, '|');
    if mustNotContain <> '' then
      WriteLn('  must NOT contain: |', mustNotContain, '|');
    WriteLn('  full output: |', body, '|');
    Inc(failCount);
  end;
end;

const
  S1 =
    '.echo on'#10 +
    'CREATE TABLE t(a INT);'#10 +
    'INSERT INTO t VALUES(1),(2);'#10 +
    'SELECT * FROM t;'#10;

  { With echo OFF the SQL text must NOT appear in output. }
  S2 =
    'CREATE TABLE t(a INT);'#10 +
    'INSERT INTO t VALUES(7);'#10 +
    'SELECT * FROM t;'#10;

  { Echo a dot-command after enabling echo. }
  S3 =
    '.echo on'#10 +
    '.headers on'#10 +
    'CREATE TABLE t(a INT);'#10 +
    'SELECT * FROM t;'#10;

begin
  { Each subsequent SQL line should appear verbatim in the output stream. }
  RunCase('echo on prints CREATE',  S1, 'CREATE TABLE t(a INT);');
  RunCase('echo on prints INSERT',  S1, 'INSERT INTO t VALUES(1),(2);');
  RunCase('echo on prints SELECT',  S1, 'SELECT * FROM t;');

  { Echo off (default) must not print SQL back. }
  RunCase('echo off: no SQL echo', S2, '7', 'CREATE TABLE t');

  { Dot-commands also echo when MFLG_ECHO is set. }
  RunCase('echo on prints .headers', S3, '.headers on');

  WriteLn;
  WriteLn(Format('TestShellEcho: %d PASS / %d FAIL',
                 [passCount, failCount]));
  if failCount > 0 then Halt(1);
end.
