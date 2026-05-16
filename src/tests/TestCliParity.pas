{
  SPDX-License-Identifier: blessing

  TestCliParity — task 10.2 CLI integration parity gate.

  Replays every src/tests/cli_parity/corpus/*.sql script through BOTH
  the in-tree bin/passqlite3 (with LD_LIBRARY_PATH=src) AND the upstream
  sqlite3 binary, byte-diffing stdout + stderr + rc.  Any divergence is
  a hard FAIL unless the basename is listed in SOFT_SKIP (each soft
  entry must cite a 10.2.divbug.N bullet in cli_parity/DIVERGENCES.md).

  Mirrors src/tests/cli_parity/run_corpus.sh — both gates share the same
  corpus and the same soft-skip set so CI behaviour is identical whether
  invoked from the Pas test-binary harness or the shell harness.

  Skips cleanly with PASS if the upstream sqlite3 binary is unavailable
  on PATH or at $UPSTREAM_SQLITE3 — keeps the build green on stripped
  CI while still gating locally.
}
{$I ../passqlite3.inc}
program TestCliParity;

uses
  SysUtils, BaseUnix, Unix,
  passqlite3types, passqlite3util,
  TestShellCommon;

var
  failCount: i32 = 0;
  passCount: i32 = 0;
  softCount: i32 = 0;

{ Soft-skip basenames (without .sql).  Each entry must point at an open
  10.2.divbug.N bullet in cli_parity/DIVERGENCES.md.  Keep this list in
  sync with the SOFT_SKIP heredoc in cli_parity/run_corpus.sh. }
function IsSoftSkip(const base: AnsiString): Boolean;
begin
  Result := (base = 'sink_mode_switching');
end;

function FindCorpusDir: AnsiString;
var
  exeDir, candidate: AnsiString;
begin
  exeDir := ExtractFilePath(ExpandFileName(ParamStr(0)));
  { When run from bin/, the repo root is one level up. }
  candidate := ExtractFilePath(ExcludeTrailingPathDelimiter(exeDir)) +
               'src/tests/cli_parity/corpus/';
  if DirectoryExists(candidate) then begin Result := candidate; Exit; end;
  { When run from the repo root or src/tests/. }
  if DirectoryExists('src/tests/cli_parity/corpus/') then begin
    Result := 'src/tests/cli_parity/corpus/'; Exit;
  end;
  if DirectoryExists('cli_parity/corpus/') then begin
    Result := 'cli_parity/corpus/'; Exit;
  end;
  Result := '';
end;

procedure RunOne(const upstream, sqlPath, base: AnsiString);
var
  expOut, expErr, actOut, actErr: AnsiString;
  exeDir, binPath, libDir, cmd: AnsiString;
  rcExp, rcAct: i32;
  bo, be: AnsiString;
  oo, oe: AnsiString;
  ok: Boolean;
begin
  exeDir  := ExtractFilePath(ExpandFileName(ParamStr(0)));
  binPath := exeDir + 'passqlite3';
  libDir  := ExtractFilePath(ExcludeTrailingPathDelimiter(exeDir)) + 'src';

  expOut := SysUtils.GetTempDir(False) + 'pas_cli_parity_' + base +
            '_exp_' + IntToStr(GetProcessID) + '.out';
  expErr := SysUtils.GetTempDir(False) + 'pas_cli_parity_' + base +
            '_exp_' + IntToStr(GetProcessID) + '.err';
  actOut := SysUtils.GetTempDir(False) + 'pas_cli_parity_' + base +
            '_act_' + IntToStr(GetProcessID) + '.out';
  actErr := SysUtils.GetTempDir(False) + 'pas_cli_parity_' + base +
            '_act_' + IntToStr(GetProcessID) + '.err';

  cmd := '"' + upstream + '" :memory: <"' + sqlPath +
         '" >"' + expOut + '" 2>"' + expErr + '"';
  rcExp := fpsystem(cmd);

  cmd := 'LD_LIBRARY_PATH="' + libDir + '" "' + binPath +
         '" :memory: <"' + sqlPath + '" >"' + actOut +
         '" 2>"' + actErr + '"';
  rcAct := fpsystem(cmd);

  bo := ShellReadAll(expOut); oo := ShellReadAll(actOut);
  be := ShellReadAll(expErr); oe := ShellReadAll(actErr);
  SysUtils.DeleteFile(expOut);
  SysUtils.DeleteFile(expErr);
  SysUtils.DeleteFile(actOut);
  SysUtils.DeleteFile(actErr);

  ok := (rcExp = rcAct) and (bo = oo) and (be = oe);
  if ok then begin
    WriteLn('PASS    ', base, ' (rc=', rcAct, ')');
    Inc(passCount);
  end else if IsSoftSkip(base) then begin
    WriteLn('SOFT    ', base, ' (rcExp=', rcExp, ' rcAct=', rcAct,
            ') — cited divergence');
    Inc(softCount);
  end else begin
    WriteLn('FAIL    ', base, ' (rcExp=', rcExp, ' rcAct=', rcAct, ')');
    if bo <> oo then begin
      WriteLn('  stdout exp (', Length(bo), ' bytes):');
      WriteLn('  |', bo, '|');
      WriteLn('  stdout act (', Length(oo), ' bytes):');
      WriteLn('  |', oo, '|');
    end;
    if be <> oe then begin
      WriteLn('  stderr exp (', Length(be), ' bytes):');
      WriteLn('  |', be, '|');
      WriteLn('  stderr act (', Length(oe), ' bytes):');
      WriteLn('  |', oe, '|');
    end;
    Inc(failCount);
  end;
end;

var
  upstream, corpusDir, sqlPath, base: AnsiString;
  sr: TSearchRec;
  names: array of AnsiString;
  i, n: SizeInt;
  tmp: AnsiString;
  j: SizeInt;

begin
  upstream := FindUpstreamSqlite3;
  if upstream = '' then begin
    WriteLn('SKIP    TestCliParity: no upstream sqlite3 binary found');
    WriteLn('        Set UPSTREAM_SQLITE3=/path/to/sqlite3 to enable.');
    Halt(0);
  end;
  corpusDir := FindCorpusDir;
  if corpusDir = '' then begin
    WriteLn('SKIP    TestCliParity: cli_parity/corpus/ not located');
    Halt(0);
  end;
  WriteLn('Using upstream: ', upstream);
  WriteLn('Using corpus  : ', corpusDir);

  { Collect basenames so the order is stable (alphabetical) across both
    gates.  FindFirst order is FS-dependent otherwise. }
  n := 0;
  SetLength(names, 0);
  if FindFirst(corpusDir + '*.sql', faAnyFile, sr) = 0 then begin
    repeat
      if (sr.Attr and faDirectory) <> 0 then Continue;
      SetLength(names, n + 1);
      names[n] := sr.Name;
      Inc(n);
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;

  { Trivial insertion sort — < 100 entries, no need for QuickSort. }
  for i := 1 to High(names) do begin
    j := i;
    while (j > 0) and (names[j-1] > names[j]) do begin
      tmp := names[j-1]; names[j-1] := names[j]; names[j] := tmp;
      Dec(j);
    end;
  end;

  for i := 0 to High(names) do begin
    sqlPath := corpusDir + names[i];
    base    := ChangeFileExt(names[i], '');
    RunOne(upstream, sqlPath, base);
  end;

  WriteLn;
  WriteLn(Format('TestCliParity: %d PASS / %d SOFT / %d FAIL  (%d total)',
                 [passCount, softCount, failCount, Length(names)]));
  if failCount > 0 then Halt(1);
end.
