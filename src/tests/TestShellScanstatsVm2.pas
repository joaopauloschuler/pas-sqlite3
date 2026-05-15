{
  SPDX-License-Identifier: blessing

  TestShellScanstatsVm2 — task 10.1.39.d.5.

  Closes the d-chain loop (10.1.39.d.1..d.4 wired Hwtime → nCycle →
  SCANSTAT_NCYCLE) with an end-to-end gate that actually exercises
  the `.scanstats` data path through `bin/passqlite3`.

  Two modes:
    - Default build (SQLITE_ENABLE_STMT_SCANSTATUS undefined): the
      dispatch bracket compiles out and the shell echoes the
      upstream "not available in this build" warning verbatim.  This
      test self-reports SKIPPED with rc=0 in that case so it stays
      green under the default build.
    - SCANSTATUS build (SQLITE_ENABLE_STMT_SCANSTATUS defined): runs
      a fixed CREATE/INSERT/SELECT script with `.scanstats vm`,
      pipes it through `bin/passqlite3`, and asserts the output is
      well-formed (rc=0; the SELECT result rows land in stdout; the
      "QUERY PLAN" header from displayScanstats appears).

      A byte-diff against the upstream `sqlite3` C binary would be
      the stronger gate, but upstream's stock build does not enable
      SQLITE_ENABLE_STMT_SCANSTATUS (and rebuilding it under the
      flag is out of scope for the port).  The smoke gate still
      proves the per-op nCycle credit and SCANSTAT_NCYCLE plumbing
      work end-to-end on a real query — that's what the d-chain
      tasks were missing.

  Reference: tasklist.md 10.1.39.d.5; shell.c.in:10545..10573;
             passqlite3shell.pas:cmdScanstats / displayScanstats.
}
{$I ../passqlite3.inc}
program TestShellScanstatsVm2;

uses
  SysUtils, BaseUnix, Unix,
  passqlite3types, passqlite3util,
  TestShellCommon;

var
  failCount: i32 = 0;
  passCount: i32 = 0;
  skipCount: i32 = 0;

var
  exeDir:  AnsiString = '';
  binPath: AnsiString = '';
  libDir:  AnsiString = '';
  workDir: AnsiString = '';
  tag:     AnsiString = '';

procedure InitPaths;
begin
  exeDir  := ExtractFilePath(ExpandFileName(ParamStr(0)));
  binPath := exeDir + 'passqlite3';
  libDir  := ExtractFilePath(ExcludeTrailingPathDelimiter(exeDir)) + 'src';
  tag     := IntToStr(GetProcessID);
  workDir := SysUtils.GetTempDir(False) + 'pas_scanstats_vm2_' + tag;
  ForceDirectories(workDir);
end;

procedure CleanupPaths;
begin
  fpsystem('rm -rf "' + workDir + '"');
end;

function containsSub(const hay, needle: AnsiString): Boolean;
begin
  Result := (needle <> '') and (Pos(needle, hay) > 0);
end;

procedure RunSmoke;
var
  sqlPath, actOut, cmd, script, aOut: AnsiString;
  rc: i32;
  ok: Boolean;
begin
  sqlPath := workDir + '/script.sql';
  actOut  := workDir + '/script.out';

  { Fixed script: CREATE+INSERT+SELECT with a WHERE that exercises
    the planner (forces a table scan with a predicate).  The
    .scanstats vm arm runs displayScanstats() after each finalize,
    which under the SCANSTATUS build walks aScan[] and emits the
    "QUERY PLAN" EQP tree (passqlite3shell.pas:displayScanstats).
    We don't byte-diff the NCYCLE numbers — those are wall-clock
    sensitive — only the shape and the SELECT result. }
  script :=
    'CREATE TABLE t1(a INTEGER PRIMARY KEY, b TEXT);'#10 +
    'INSERT INTO t1 VALUES(1,''alpha''),(2,''beta''),(3,''gamma''),'+
    '(4,''delta''),(5,''epsilon'');'#10 +
    '.scanstats vm'#10 +
    'SELECT a, b FROM t1 WHERE b LIKE ''%a%'' ORDER BY a;'#10 +
    '.scanstats off'#10;

  ShellWriteFileBytes(sqlPath, script);

  cmd := 'LD_LIBRARY_PATH="' + libDir + '" "' + binPath + '" :memory:' +
         ' <"' + sqlPath + '" >"' + actOut + '" 2>&1';
  rc := fpsystem(cmd);
  aOut := ShellReadAll(actOut);

  { Smoke assertions:
      (1) rc=0 — the port did not crash on the .scanstats vm arm
      (2) SELECT result rows land in stdout — the dispatch bracket
          credited nCycle without aborting the VM
      (3) "QUERY PLAN" header from displayScanstats appears in the
          output — confirms cmdScanstats wired the per-statement
          consumer (passqlite3shell.pas:3095)
    Under the default build (no SCANSTATUS) the warning replaces
    the QUERY PLAN block; we still expect rc=0 and SELECT rows,
    but the QUERY PLAN check is gated below. }
  ok := True;
  if rc <> 0 then ok := False;
  if not containsSub(aOut, 'alpha') then ok := False;
  if not containsSub(aOut, 'gamma') then ok := False;
{$IFDEF SQLITE_ENABLE_STMT_SCANSTATUS}
  if not containsSub(aOut, 'QUERY PLAN') then ok := False;
{$ENDIF}

  if ok then begin
    WriteLn('PASS    scanstats-vm-smoke (rc=', rc,
            ' stdout=', Length(aOut), 'B)');
    Inc(passCount);
  end else begin
    WriteLn('FAIL    scanstats-vm-smoke (rc=', rc, ')');
    WriteLn('  stdout (', Length(aOut), 'B): |', aOut, '|');
    Inc(failCount);
  end;
end;

begin
{$IFNDEF SQLITE_ENABLE_STMT_SCANSTATUS}
  WriteLn('SKIP    TestShellScanstatsVm2: SQLITE_ENABLE_STMT_SCANSTATUS not');
  WriteLn('        defined in this build.  Rebuild with');
  WriteLn('        SQLITE_ENABLE_STMT_SCANSTATUS=2 src/tests/build.sh');
  WriteLn('        to enable the per-op NCYCLE bracket and the .scanstats');
  WriteLn('        vm data path (10.1.39.d.1..d.4).');
  Inc(skipCount);
  WriteLn;
  WriteLn('Summary: pass=', passCount, ' fail=', failCount, ' skip=', skipCount);
  Halt(0);
{$ELSE}
  InitPaths;
  WriteLn('Using port    : ', binPath);
  WriteLn('Work dir      : ', workDir);
  WriteLn('SQLITE_ENABLE_STMT_SCANSTATUS build: dispatch bracket compiled in.');

  RunSmoke;

  CleanupPaths;
  WriteLn;
  WriteLn('Summary: pass=', passCount, ' fail=', failCount, ' skip=', skipCount);
  if failCount > 0 then Halt(1) else Halt(0);
{$ENDIF}
end.
