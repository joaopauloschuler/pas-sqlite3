{
  SPDX-License-Identifier: blessing

  TestShellMisc — phase 10.1f.10/11/12/13 gate.  Exercises `.crnl`/`.crlf`,
  `.binary`, `.connection` and `.unmodule` by piping fixed scripts into both
  binaries (bin/passqlite3 and /home/bpsa/app/sqlite3/sqlite3) and diffing
  stdout+stderr byte-for-byte.

  Upstream C arms:
    - .crnl / .crlf  shell.c.in:9223..9240   (n==4, "crlf"/"crnl")
    - .binary        shell.c.in:9113..9117   (deprecated stub, rc=1)
    - .connection    shell.c.in:9177..9221   (aAuxDb slot switch, rc=1 on
                                              usage / active-close)
    - .unmodule      shell.c.in:11954..11975 (drop / --allexcept, rc=1 on
                                              missing arg)

  Both arms are essentially no-ops on POSIX:
    - .crnl always emits "crlf is OFF\n" on stderr, rc=0, regardless of
      argv (the flag is unconditionally cleared on non-_WIN32 builds and
      the post-block stderr line is always printed).
    - .binary always emits the deprecation line on stderr, rc=1, with no
      nArg gating.

  Coverage:
    - .crnl              (no value)
    - .crnl on / off     (boolean value paths)
    - .crlf              (alias)
    - .crlf on
    - .binary
    - .binary on
    - .binary bogus      (the arm ignores extra args)

  Skips with PASS if the upstream sqlite3 binary is unavailable.
}
{$I ../passqlite3.inc}
program TestShellMisc;

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

var
  upstream: AnsiString;
  exeDir, binPath, libDir: AnsiString;
  tag: AnsiString;
  workDirExp, workDirAct: AnsiString;

procedure InitPaths;
begin
  exeDir  := ExtractFilePath(ExpandFileName(ParamStr(0)));
  binPath := exeDir + 'passqlite3';
  libDir  := ExtractFilePath(ExcludeTrailingPathDelimiter(exeDir)) + 'src';
  tag     := IntToStr(GetProcessID);
  workDirExp := SysUtils.GetTempDir(False) + 'pas_misc_exp_' + tag;
  workDirAct := SysUtils.GetTempDir(False) + 'pas_misc_act_' + tag;
  ForceDirectories(workDirExp);
  ForceDirectories(workDirAct);
end;

procedure CleanupPaths;
begin
  fpsystem('rm -rf "' + workDirExp + '" "' + workDirAct + '"');
end;

{ Diff a dot-command script piped on stdin to both binaries. }
procedure DiffScript(const name, script: AnsiString);
var
  scriptExp, scriptAct, expOut, actOut, cmd: AnsiString;
  rcExp, rcAct: i32;
  eOut, aOut: AnsiString;
  f: Text;
  ok: Boolean;
begin
  scriptExp := workDirExp + '/' + name + '.sql';
  scriptAct := workDirAct + '/' + name + '.sql';
  expOut    := workDirExp + '/' + name + '.out';
  actOut    := workDirAct + '/' + name + '.out';

  AssignFile(f, scriptExp); Rewrite(f); Write(f, script); CloseFile(f);
  AssignFile(f, scriptAct); Rewrite(f); Write(f, script); CloseFile(f);

  cmd := 'cd "' + workDirExp + '" && timeout 15 "' + upstream +
         '" :memory: <"' + scriptExp + '" >"' + expOut + '" 2>&1';
  rcExp := fpsystem(cmd);
  cmd := 'cd "' + workDirAct + '" && LD_LIBRARY_PATH="' + libDir +
         '" timeout 15 "' + binPath + '" :memory: <"' + scriptAct +
         '" >"' + actOut + '" 2>&1';
  rcAct := fpsystem(cmd);

  eOut := readAll(expOut);
  aOut := readAll(actOut);
  ok := (rcExp = rcAct) and (eOut = aOut);
  if ok then begin
    WriteLn('PASS    ', name, ' (rc=', rcAct,
            ' out=', Length(aOut), 'B)');
    Inc(passCount);
  end else begin
    WriteLn('FAIL    ', name, ' (rcExp=', rcExp, ' rcAct=', rcAct, ')');
    WriteLn('  exp (', Length(eOut), 'B): |', eOut, '|');
    WriteLn('  act (', Length(aOut), 'B): |', aOut, '|');
    Inc(failCount);
  end;
end;

procedure RunCrnl;
begin
  { Bare invocation: emits "crlf is OFF\n" on stderr, rc=0. }
  DiffScript('crnl-bare',  '.crnl'#10);

  { Boolean value paths: on Linux these don't flip the flag, so still OFF. }
  DiffScript('crnl-on',    '.crnl on'#10);
  DiffScript('crnl-off',   '.crnl off'#10);

  { Alias `.crlf` is the same arm in C (cli_strncmp matches either token). }
  DiffScript('crlf-bare',  '.crlf'#10);
  DiffScript('crlf-on',    '.crlf on'#10);

  { Multi-line script: both invocations of the same arm. }
  DiffScript('crnl-twice', '.crnl on'#10'.crnl off'#10);
end;

procedure RunBinary;
begin
  { Bare: deprecation line on stderr, rc=1. }
  DiffScript('binary-bare', '.binary'#10);
  { With arg: arm ignores extra args, same deprecation line, rc=1. }
  DiffScript('binary-on',   '.binary on'#10);
  DiffScript('binary-off',  '.binary off'#10);
  { Bogus arg: still the same — the arm fires on prefix "bin" (n>=3). }
  DiffScript('binary-bogus','.binary bogus'#10);
end;

procedure RunConnection;
begin
  { Bare: lists slots. With :memory: argv we get a single ACTIVE 0 row. }
  DiffScript('conn-bare',       '.connection'#10);
  { Switch to slot 0 (already active) — silent no-op, rc=0. }
  DiffScript('conn-switch-0',   '.connection 0'#10);
  { Out-of-range single digit — body's range check fails silently, rc=0. }
  DiffScript('conn-switch-9',   '.connection 9'#10);
  { Close the active slot — eputz + rc=1. }
  DiffScript('conn-close-active', '.connection close 0'#10);
  { Close an out-of-range slot — no-op, rc=0. }
  DiffScript('conn-close-9',    '.connection close 9'#10);
  { Usage paths: missing arg / non-digit / multi-char digit-string. }
  DiffScript('conn-close-bare', '.connection close'#10);
  DiffScript('conn-close-bad',  '.connection close foo'#10);
  DiffScript('conn-bogus',      '.connection wibble'#10);
end;

procedure RunUnmodule;
begin
  { Missing arg: Usage on stderr, rc=1. }
  DiffScript('unmod-bare',      '.unmodule'#10);
  { Drop a non-existent module: silent, rc=0 (create_module(NULL,NULL)). }
  DiffScript('unmod-name',      '.unmodule nosuchmod'#10);
  { Drop multiple non-existent modules: silent, rc=0. }
  DiffScript('unmod-names',     '.unmodule one two three'#10);
  { --allexcept with no names: drops every registered module, silent rc=0. }
  DiffScript('unmod-allex-bare','.unmodule --allexcept'#10);
  { --allexcept keeping some names: silent rc=0. }
  DiffScript('unmod-allex-keep','.unmodule --allexcept json json_tree'#10);
  { Single-dash prefix is accepted too (zOpt++ runs only on `--`). }
  DiffScript('unmod-allex-1dash','.unmodule -allexcept'#10);
end;

begin
  upstream := findUpstreamSqlite3;
  InitPaths;
  if upstream = '' then begin
    WriteLn('SKIP    crnl/binary/connection/unmodule: ',
            'no upstream sqlite3 binary found');
    WriteLn('        Set UPSTREAM_SQLITE3=/path/to/sqlite3 to enable.');
    CleanupPaths;
    WriteLn;
    WriteLn(Format('TestShellMisc: %d PASS / %d FAIL',
                   [passCount, failCount]));
    Halt(0);
  end;

  WriteLn('Using upstream: ', upstream);
  WriteLn('Using port    : ', binPath);
  WriteLn('Work dirs     : ', workDirExp, ' | ', workDirAct);

  RunCrnl;
  RunBinary;
  RunConnection;
  RunUnmodule;

  CleanupPaths;

  WriteLn;
  WriteLn(Format('TestShellMisc: %d PASS / %d FAIL',
                 [passCount, failCount]));
  if failCount > 0 then Halt(1);
end.
