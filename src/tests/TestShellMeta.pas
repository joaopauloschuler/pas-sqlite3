{
  SPDX-License-Identifier: blessing

  TestShellMeta — phase 10.1e.G gate.  Pipes a fixed meta/diagnostic
  dot-command script into both the port (`bin/passqlite3`) and the
  upstream `sqlite3` binary, and diffs stdout+stderr byte-for-byte.

  Coverage (mirrors tasklist.md 10.1e.*):
    - help              .help / .help schema           (10.1e.6)  [COVERED]
    - stats             .stats                         (10.1e.1)  TODO
    - timer             .timer                         (10.1e.2)  TODO
    - eqp               .eqp                           (10.1e.3)  TODO
    - explain           .explain                       (10.1e.4)  TODO
    - show              .show                          (10.1e.5)  [COVERED]
    - shell-system      .shell / .system               (10.1e.7)  TODO
    - cd                .cd                            (10.1e.8)  TODO
    - log               .log                           (10.1e.9)  TODO
    - trace             .trace                         (10.1e.10) TODO
    - iotrace           .iotrace                       (10.1e.11) TODO
    - scanstats         .scanstats                     (10.1e.12) TODO
    - testcase          .testcase                      (10.1e.13) TODO
    - testctrl          .testctrl                      (10.1e.14) TODO
    - selecttrace       .selecttrace                   (10.1e.15) TODO
    - wheretrace        .wheretrace                    (10.1e.16) TODO

  Skips with PASS if the upstream sqlite3 binary is unavailable on
  PATH or at $UPSTREAM_SQLITE3.
}
{$I ../passqlite3.inc}
program TestShellMeta;

uses
  SysUtils, BaseUnix, Unix,
  passqlite3types, passqlite3util;

var
  failCount: i32 = 0;
  passCount: i32 = 0;
  skipCount: i32 = 0;

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

procedure writeFileBytes(const path, body: AnsiString);
var
  f: file of Byte;
begin
  AssignFile(f, path); Rewrite(f);
  if Length(body) > 0 then
    BlockWrite(f, body[1], Length(body));
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

var
  upstream: AnsiString;
  exeDir, binPath, libDir: AnsiString;
  tag: AnsiString;
  workDir: AnsiString;

procedure InitPaths;
begin
  exeDir  := ExtractFilePath(ExpandFileName(ParamStr(0)));
  binPath := exeDir + 'passqlite3';
  libDir  := ExtractFilePath(ExcludeTrailingPathDelimiter(exeDir)) + 'src';
  tag     := IntToStr(GetProcessID);
  workDir := SysUtils.GetTempDir(False) + 'pas_meta_' + tag;
  ForceDirectories(workDir);
end;

procedure CleanupPaths;
begin
  fpsystem('rm -rf "' + workDir + '"');
end;

{ Run both shells on `script` (stdin) with optional argv tail and diff
  merged stdout+stderr byte-for-byte. }
procedure DiffMeta(const name, argTail, script: AnsiString);
var
  sqlPath, expOut, actOut, cmd: AnsiString;
  rcExp, rcAct: i32;
  eOut, aOut: AnsiString;
  ok: Boolean;
begin
  sqlPath := workDir + '/' + name + '.sql';
  expOut  := workDir + '/' + name + '.exp.out';
  actOut  := workDir + '/' + name + '.act.out';

  writeFileBytes(sqlPath, script);

  cmd := '"' + upstream + '" ' + argTail +
         ' <"' + sqlPath + '" >"' + expOut + '" 2>&1';
  rcExp := fpsystem(cmd);

  cmd := 'LD_LIBRARY_PATH="' + libDir + '" "' + binPath + '" ' + argTail +
         ' <"' + sqlPath + '" >"' + actOut + '" 2>&1';
  rcAct := fpsystem(cmd);

  eOut := readAll(expOut);
  aOut := readAll(actOut);

  ok := (rcExp = rcAct) and (eOut = aOut);
  if ok then begin
    WriteLn('PASS    ', name, ' (rc=', rcAct,
            ' stdout=', Length(aOut), 'B)');
    Inc(passCount);
  end else begin
    WriteLn('FAIL    ', name, ' (rcExp=', rcExp, ' rcAct=', rcAct, ')');
    WriteLn('  stdout-exp (', Length(eOut), 'B): |', eOut, '|');
    WriteLn('  stdout-act (', Length(aOut), 'B): |', aOut, '|');
    Inc(failCount);
  end;
end;

var
  script: AnsiString;

begin
  upstream := findUpstreamSqlite3;
  if upstream = '' then begin
    WriteLn('SKIP    TestShellMeta: no upstream sqlite3 binary found');
    WriteLn('        Set UPSTREAM_SQLITE3=/path/to/sqlite3 to enable.');
    Halt(0);
  end;
  InitPaths;
  WriteLn('Using upstream: ', upstream);
  WriteLn('Using port    : ', binPath);
  WriteLn('Work dir      : ', workDir);

  { -------- help (10.1e.6) ---------------------------------------- }
  { `.help` (no args) emits the full azHelp[] table.  `.help schema`
    matches a known top-level command (showHelp uses sqlite3_strglob
    then sqlite3_strlike fallback). }
  script :=
    '.help'#10 +
    '.help schema'#10;
  DiffMeta('help', ':memory:', script);

  { -------- show (10.1e.5) ---------------------------------------- }
  { cmdShow emits a fixed-order table of shell settings (shell.c.in
    cmdShow at 11267..11322).  Defaults exercise the simple branch;
    forcing non-default mode/headers/nullvalue/separator covers the
    cEscapeStr arm for nullvalue/colseparator/rowseparator and the
    QRF_Yes headers path.  Passing an argument to `.show` must emit
    `Usage: .show` and set the per-statement error counter. }
  script := '.show'#10;
  DiffMeta('show-default', ':memory:', script);

  script :=
    '.mode csv'#10 +
    '.headers on'#10 +
    '.nullvalue NULL'#10 +
    '.separator |'#10 +
    '.show'#10;
  DiffMeta('show-tweaked', ':memory:', script);

  script := '.show foo'#10;
  DiffMeta('show-usage', ':memory:', script);

  CleanupPaths;

  WriteLn;
  WriteLn(Format('TestShellMeta: %d PASS / %d FAIL / %d SKIP',
                 [passCount, failCount, skipCount]));
  if failCount > 0 then Halt(1);
end.
