{
  SPDX-License-Identifier: blessing

  This work is dedicated to all human kind, and also to all non-human kinds.

  Faithful port of SQLite 3 (https://sqlite.org/) from C to Free Pascal.
}
{$I ../passqlite3.inc}
{
  TestShellCommon — shared harness for the byte-diff-against-upstream-
  sqlite3 family of test programs (TestShell* and TestVtabLateral).

  jscpd flagged a ten-way clone cluster: every probe re-declared the
  same three procs verbatim:

    * readAll(path)           — slurp a file into AnsiString.
    * writeFileBytes(p, body) — dump an AnsiString to a file.
    * findUpstreamSqlite3     — resolve $UPSTREAM_SQLITE3 or one of
                                four well-known on-disk locations.

  Three of those probes (TestShellSchema, TestShellModes,
  TestVtabLateral) additionally shared a full ~50-line `DiffCase`
  proc — same `:memory: <sql >out 2>&1` shape on both shells, byte
  compare, PASS/FAIL accounting — differing only in the tempfile
  name prefix.  That body is hoisted as ShellDiffCase.

  Per-probe DiffXxx variants that need cwd control, work-dir trees,
  argv tails, or persisted-file diffs (TestShellIO.DiffIO,
  TestShellMisc.DiffScript, TestShellBackup, TestShellFilectrl,
  TestShellDbinfo, TestShellArchive) keep their own bodies — those
  shapes are not byte-identical and differ in semantic intent.

  Name choice: `TestShellCommon` over `TestOracleCommon` because the
  full set of users (including TestVtabLateral) all funnel through
  the same `:memory: <stdin >stdout` shell-pipe pattern; the unit is
  the *shell-probe* harness, not a generic oracle.  `TestOracle*` is
  also already implied by the upstream-sqlite3-binary terminology
  inside SQLite itself, but here we are pinned to the shell pipe.
}
unit TestShellCommon;

interface

uses
  SysUtils, BaseUnix, Unix,
  passqlite3types, passqlite3util;

{ Slurp `path` byte-for-byte into AnsiString.  Empty result on open
  failure — matches the original inline readAll exactly so behaviour
  on missing-file is unchanged. }
function ShellReadAll(const path: AnsiString): AnsiString;

{ Dump `body` to `path` via raw BlockWrite.  Truncates an existing
  file (Rewrite semantics).  No-op-body just truncates. }
procedure ShellWriteFileBytes(const path, body: AnsiString);

{ Resolve the upstream sqlite3 binary.  $UPSTREAM_SQLITE3 wins; then
  a fixed four-entry fallback list.  Returns '' when nothing matches
  (callers SKIP+Halt(0) in that case). }
function FindUpstreamSqlite3: AnsiString;

{ Run a fixed `:memory: <sql >out 2>&1` byte-diff between the
  upstream sqlite3 and the in-tree passqlite3.  `prefix` distinguishes
  per-probe tempfile names (e.g. 'pas_schema_', 'pas_modes_',
  'pas_vtablat_').  pass/fail counters are bumped via var-params so
  the call site keeps its own totals. }
procedure ShellDiffCase(const prefix, name, sql, upstream: AnsiString;
                        var passCount, failCount: i32);

implementation

function ShellReadAll(const path: AnsiString): AnsiString;
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

procedure ShellWriteFileBytes(const path, body: AnsiString);
var
  f: file of Byte;
begin
  AssignFile(f, path); Rewrite(f);
  if Length(body) > 0 then
    BlockWrite(f, body[1], Length(body));
  CloseFile(f);
end;

function FindUpstreamSqlite3: AnsiString;
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

procedure ShellDiffCase(const prefix, name, sql, upstream: AnsiString;
                        var passCount, failCount: i32);
var
  sqlPath, expPath, actPath, cmd, exeDir, binPath, libDir: AnsiString;
  f: TextFile;
  rcExp, rcAct: i32;
  expBody, actBody: AnsiString;
begin
  sqlPath := SysUtils.GetTempDir(False) + prefix + 'in_'  +
             IntToStr(GetProcessID) + '.sql';
  expPath := SysUtils.GetTempDir(False) + prefix + 'exp_' +
             IntToStr(GetProcessID) + '.txt';
  actPath := SysUtils.GetTempDir(False) + prefix + 'act_' +
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

  expBody := ShellReadAll(expPath);
  actBody := ShellReadAll(actPath);
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

end.
