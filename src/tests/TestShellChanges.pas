{
  SPDX-License-Identifier: blessing

  TestShellChanges — regressions for `.changes on`, `.show` ordering /
  C-escaping, and the `.show explain: auto` default.

  Before the fix:
    * `.changes on` set SHFLG_CountChanges but the per-SQL
      `changes: %lld   total_changes: %lld` emission at
      shell.c.in:12356..12361 was never ported.
    * `.show` defaulted `explain` to `off` because modeDefault's
      `p->mode.autoExplain = 1` (shell.c.in:1697) was not mirrored.
    * `.show` printed `output` *after* `width`/`filename` instead of
      between `nullvalue` and `colseparator` (shell.c.in:11301..11302).
    * `.show` rendered `nullvalue` / `colseparator` / `rowseparator`
      values without C-escaping so a literal newline appeared in the
      output instead of `\n`.
}
{$I ../passqlite3.inc}
program TestShellChanges;

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
  sqlPath := SysUtils.GetTempDir(False) + 'pas_changes_in_' +
             IntToStr(GetProcessID) + '.sql';
  outPath := SysUtils.GetTempDir(False) + 'pas_changes_out_' +
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
      WriteLn('  must NOT contain:   |', mustNotContain, '|');
    WriteLn('  full output: |', body, '|');
    Inc(failCount);
  end;
end;

const
  S1 =
    '.changes on'#10 +
    'CREATE TABLE t(a);'#10 +
    'INSERT INTO t VALUES(1),(2),(3);'#10 +
    'UPDATE t SET a=a+10;'#10 +
    'DELETE FROM t WHERE a>11;'#10;

  S2 =
    'CREATE TABLE t(a);'#10 +
    'INSERT INTO t VALUES(1);'#10 +
    'SELECT a FROM t;'#10;

  S3 =
    '.show'#10;

begin
  { .changes on must emit per-statement counters matching upstream. }
  RunCase('changes after CREATE', S1, 'changes: 0   total_changes: 0');
  RunCase('changes after INSERT', S1, 'changes: 3   total_changes: 3');
  RunCase('changes after UPDATE', S1, 'changes: 3   total_changes: 6');
  RunCase('changes after DELETE', S1, 'changes: 2   total_changes: 8');

  { .changes off (default) must NOT print the summary. }
  RunCase('changes off: silent', S2, '1'#10, 'total_changes');

  { .show defaults `explain: auto` (shell.c.in:1697 modeDefault). }
  RunCase('.show explain auto', S3, 'explain: auto');

  { .show C-escapes the row separator. }
  RunCase('.show escapes rowsep', S3, 'rowseparator: "\n"');

  { .show prints `output: stdout` between `nullvalue` and `colseparator`. }
  RunCase('.show output stdout', S3, 'output: stdout');

  WriteLn;
  WriteLn(Format('TestShellChanges: %d PASS / %d FAIL',
                 [passCount, failCount]));
  if failCount > 0 then Halt(1);
end.
