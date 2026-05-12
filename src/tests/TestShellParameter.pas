{
  SPDX-License-Identifier: blessing

  TestShellParameter — regression for CLI `.parameter set` bindings.

  Before the fix, `.parameter set @x 42` populated
  temp.sqlite_parameters but bind_prepared_stmt
  (shell.c.in:2993..3075) was not ported, so any subsequent
  `SELECT @x` saw NULL instead of 42.  Same for `$int_N` literal
  encoding and `$text_X` literal encoding.

  This regression spawns bin/passqlite3 and verifies that
  parameter values flow into prepared statements.
}
{$I ../passqlite3.inc}
program TestShellParameter;

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
  sqlPath := SysUtils.GetTempDir(False) + 'pas_param_in_' +
             IntToStr(GetProcessID) + '.sql';
  outPath := SysUtils.GetTempDir(False) + 'pas_param_out_' +
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

  if Pos(expectSubstr, body) > 0 then begin
    WriteLn('PASS    ', name, ' (rc=', rc, ')');
    Inc(passCount);
  end else begin
    WriteLn('FAIL    ', name, ' (rc=', rc, ')');
    WriteLn('  expected substring: |', expectSubstr, '|');
    WriteLn('  full output: |', body, '|');
    Inc(failCount);
  end;
end;

const
  S1 =
    '.parameter init'#10 +
    '.parameter set @x 42'#10 +
    'SELECT @x;'#10;

  S2 =
    '.parameter init'#10 +
    '.parameter set @x 7'#10 +
    '.parameter set @y 8'#10 +
    'SELECT @x + @y;'#10;

  { $int_N literal-name encoding: no temp row needed. }
  S3 =
    'SELECT $int_123;'#10;

  { $text_X literal-name encoding: no temp row needed. }
  S4 =
    'SELECT $text_hello;'#10;

  { Unbound named parameter must default to NULL (not unbound -> error). }
  S5 =
    'SELECT coalesce(@unset, ''N'');'#10;

begin
  RunCase('@x binds to 42',          S1, '42');
  RunCase('@x + @y binds (7+8)',     S2, '15');
  RunCase('$int_123 literal bind',   S3, '123');
  RunCase('$text_hello literal',     S4, 'hello');
  RunCase('unset @ binds NULL',      S5, 'N');

  WriteLn;
  WriteLn(Format('TestShellParameter: %d PASS / %d FAIL',
                 [passCount, failCount]));
  if failCount > 0 then Halt(1);
end.
