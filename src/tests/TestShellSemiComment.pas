{
  SPDX-License-Identifier: blessing

  TestShellSemiComment — regression for the CLI's processInput statement
  cutter when a SQL line ends with `;` followed by a `--` trailer or has
  comment-only lines between statements.  Earlier ports gated the cut on
  `zSql[end]=';' && sqlite3_complete(zSql)`; with a trailing `--` comment
  the last character is not `;`, so the buffer kept accumulating subsequent
  statements into one over-long prepare.  Symptom: the first statement's
  prepare error swallowed every following statement.

  Upstream shell.c.in:12507 uses `QSS_SEMITERM(qss) && sqlite3_complete(zSql)`
  where quickscan treats `;` + trailing whitespace/comments as semi-terminated.
  The lean port drops the quickscan fast-path and relies on sqlite3_complete
  alone — which is correct: complete.c already handles the trailing-comment
  case.

  This regression spawns bin/passqlite3 in a subshell against a fixture that
  reproduces the original divergence (sqlite3 oracle's behaviour: a failed
  statement does not prevent the next CREATE/SELECT from running).
}
{$I ../passqlite3.inc}
program TestShellSemiComment;

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

procedure RunCase(const name, sql, expectSubstr: AnsiString);
var
  sqlPath, outPath, cmd, exeDir, binPath, libDir: AnsiString;
  f: TextFile;
  rc: i32;
  body: AnsiString;
begin
  sqlPath := SysUtils.GetTempDir(False) + 'pas_semi_in_' +
             IntToStr(GetProcessID) + '.sql';
  outPath := SysUtils.GetTempDir(False) + 'pas_semi_out_' +
             IntToStr(GetProcessID) + '.txt';
  AssignFile(f, sqlPath); Rewrite(f); Write(f, sql); CloseFile(f);

  { ParamStr(0) is the absolute path to the test binary in bin/.
    Derive sibling passqlite3 and the LD_LIBRARY_PATH that points at src/
    so the test runs no matter what cwd run_regression.sh chose. }
  exeDir  := ExtractFilePath(ExpandFileName(ParamStr(0)));
  binPath := exeDir + 'passqlite3';
  libDir  := ExtractFilePath(ExcludeTrailingPathDelimiter(exeDir)) + 'src';

  cmd := 'LD_LIBRARY_PATH="' + libDir + '" "' + binPath +
         '" :memory: <"' + sqlPath + '" >"' + outPath + '" 2>&1';
  rc := fpsystem(cmd);
  body := readAll(outPath);
  SysUtils.DeleteFile(sqlPath);
  SysUtils.DeleteFile(outPath);

  if Pos(expectSubstr, body) > 0 then begin
    WriteLn('PASS    ', name, ' (rc=', rc, ')');
    Inc(passCount);
  end else begin
    WriteLn('FAIL    ', name, ' (rc=', rc, ')');
    WriteLn('  expected substring: ', expectSubstr);
    WriteLn('  full output: |', body, '|');
    Inc(failCount);
  end;
end;

const
  C_FIX_SCRIPT =
    'SELECT no_such_col; -- trailer1'#10 +
    '-- trailer2 between statements'#10 +
    'CREATE TABLE g(x INT);'#10 +
    'INSERT INTO g VALUES(42);'#10 +
    'SELECT * FROM g;'#10;

  C_FIX_SCRIPT2 =
    'CREATE TABLE t(a); -- after-semi line comment'#10 +
    'INSERT INTO t VALUES(7);'#10 +
    'SELECT a FROM t;'#10;

  C_FIX_SCRIPT3 =
    '/* leading block */ SELECT 1;'#10 +
    '-- pure comment line'#10 +
    'SELECT 2;'#10;

begin
  { Case 1: error in first stmt + `--` trailer must not eat the next CREATE.
    Pre-fix, output was `Parse error ... no such table: g`.  Post-fix, the
    CREATE/INSERT/SELECT all run and we see `42` on its own line. }
  RunCase('failed-stmt + trailing -- comment does not swallow next stmt',
          C_FIX_SCRIPT, #10'42'#10);

  { Case 2: trailing `--` comment after a successful CREATE; the next INSERT
    and SELECT must still execute. }
  RunCase('successful CREATE; -- trailer + next INSERT/SELECT execute',
          C_FIX_SCRIPT2, '7'#10);

  { Case 3: block-comment + interleaved line-comment separation. }
  RunCase('block comment + interleaved -- comment',
          C_FIX_SCRIPT3, '1'#10'2'#10);

  WriteLn;
  WriteLn(Format('TestShellSemiComment: %d PASS / %d FAIL',
                 [passCount, failCount]));
  if failCount > 0 then Halt(1);
end.
