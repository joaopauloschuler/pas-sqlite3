{
  SPDX-License-Identifier: blessing

  TestShellDbinfo — phase 10.1f.6/7 gate.  Exercises `.dbinfo` and
  `.dbconfig` by piping fixed scripts into both binaries
  (`bin/passqlite3` and `/home/bpsa/app/sqlite3/sqlite3`) and diffing
  stdout+stderr byte-for-byte.

  Coverage (mirrors tasklist.md):
    - .dbinfo            (10.1f.6) — three-row fixture, default DB +
                                     explicit "main" arg + "temp".
    - .dbconfig          (10.1f.7) — bare (lists all wired DBCONFIG_*
                                     ops in upstream's order), per-op
                                     read (defensive / enable_fkey /
                                     trusted_schema / fp_digits), and
                                     toggle-then-read for the boolean
                                     ops.

  Upstream C arms:
    - .dbinfo            shell.c.in:5485..5575
    - .dbconfig          shell.c.in:9279..9330

  Notes on the .dbconfig coverage scope:
    The port's sqlite3_db_config_int dispatcher already wires every
    boolean DBCONFIG_* op upstream's `.dbconfig` knows about, plus the
    integer-valued FP_DIGITS.  Counter/pointer-style ops (LOOKASIDE,
    MAINDBNAME, MAX_SCHEMA_RETRY, MAX_ALLOWED_*) remain gated on
    Phase 8.1.1's raw varargs and are NOT exercised here.  Upstream's
    `.dbconfig` arm itself does not surface those either, so the bare
    listing is still a byte-parity gate.

  Skips with PASS if the upstream sqlite3 binary is unavailable.
}
{$I ../passqlite3.inc}
program TestShellDbinfo;

uses
  SysUtils, BaseUnix, Unix,
  passqlite3types, passqlite3util,
  TestShellCommon;

var
  failCount: i32 = 0;
  passCount: i32 = 0;

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
  workDirExp := SysUtils.GetTempDir(False) + 'pas_dbinfo_exp_' + tag;
  workDirAct := SysUtils.GetTempDir(False) + 'pas_dbinfo_act_' + tag;
  ForceDirectories(workDirExp);
  ForceDirectories(workDirAct);
end;

procedure CleanupPaths;
begin
  fpsystem('rm -rf "' + workDirExp + '" "' + workDirAct + '"');
end;

{ Diff a single CLI invocation (no script piped). }
procedure DiffArgv(const name, argTail: AnsiString);
var
  expOut, actOut, cmd: AnsiString;
  rcExp, rcAct: i32;
  eOut, aOut: AnsiString;
  ok: Boolean;
begin
  expOut := workDirExp + '/' + name + '.out';
  actOut := workDirAct + '/' + name + '.out';
  cmd := 'cd "' + workDirExp + '" && "' + upstream + '" ' + argTail +
         ' >"' + expOut + '" 2>&1';
  rcExp := fpsystem(cmd);
  cmd := 'cd "' + workDirAct + '" && LD_LIBRARY_PATH="' + libDir + '" "' +
         binPath + '" ' + argTail +
         ' >"' + actOut + '" 2>&1';
  rcAct := fpsystem(cmd);
  eOut := ShellReadAll(expOut);
  aOut := ShellReadAll(actOut);
  ok := (rcExp = rcAct) and (eOut = aOut);
  if ok then begin
    WriteLn('PASS    ', name, ' (rc=', rcAct,
            ' stdout=', Length(aOut), 'B)');
    Inc(passCount);
  end else begin
    WriteLn('FAIL    ', name, ' (rcExp=', rcExp, ' rcAct=', rcAct, ')');
    WriteLn('  exp (', Length(eOut), 'B): |', eOut, '|');
    WriteLn('  act (', Length(aOut), 'B): |', aOut, '|');
    Inc(failCount);
  end;
end;

procedure SeedDatabases;
var
  seedSql: AnsiString;
begin
  seedSql :=
    'CREATE TABLE t(a INTEGER PRIMARY KEY, b TEXT);'#10 +
    'INSERT INTO t VALUES(1,''alpha''),(2,''beta''),(3,''gamma'');'#10 +
    'CREATE INDEX ti ON t(b);'#10;
  ShellWriteFileBytes(workDirExp + '/seed.sql', seedSql);
  ShellWriteFileBytes(workDirAct + '/seed.sql', seedSql);
  { Build the same DB with the upstream binary in BOTH workdirs so each
    binary's .dbinfo reads byte-identical page-1 headers. }
  fpsystem('"' + upstream + '" "' + workDirExp + '/info.db" <"' +
           workDirExp + '/seed.sql" >/dev/null 2>&1');
  fpsystem('"' + upstream + '" "' + workDirAct + '/info.db" <"' +
           workDirAct + '/seed.sql" >/dev/null 2>&1');
end;

procedure RunDbinfo;
begin
  { Bare .dbinfo against the three-row fixture.  The page header,
    schema-count queries and data-version line are all deterministic. }
  DiffArgv('dbinfo-default',
    '"' + workDirExp + '/info.db" ".dbinfo"');
  { Explicit "main" argument routes through the same arm but exercises
    the args[0]<>'temp' branch in cmdDbinfo's zSchemaTab formatter. }
  DiffArgv('dbinfo-main',
    '"' + workDirExp + '/info.db" ".dbinfo main"');
  { "temp" routes through the cli_strcmp(zDb,"temp")==0 branch, which
    rewrites zSchemaTab to sqlite_temp_schema; with no temp tables the
    five count queries all return 0. }
  DiffArgv('dbinfo-temp',
    '"' + workDirExp + '/info.db" ".dbinfo temp"');
end;

procedure RunDbconfig;
begin
  { Bare .dbconfig — lists every boolean DBCONFIG op + FP_DIGITS in
    upstream's order; byte-parity verifies the aDbConfig table mirrors
    shell.c.in:9280. }
  DiffArgv('dbconfig-bare', ':memory: ".dbconfig"');
  { Per-op read.  Each of these probes a different default state. }
  DiffArgv('dbconfig-defensive',     ':memory: ".dbconfig defensive"');
  DiffArgv('dbconfig-enable_fkey',   ':memory: ".dbconfig enable_fkey"');
  DiffArgv('dbconfig-trusted_schema',':memory: ".dbconfig trusted_schema"');
  DiffArgv('dbconfig-enable_view',   ':memory: ".dbconfig enable_view"');
  DiffArgv('dbconfig-load_extension',':memory: ".dbconfig load_extension"');
  DiffArgv('dbconfig-fp_digits',     ':memory: ".dbconfig fp_digits"');
  { Toggle then re-read in a single CLI: each ".dbconfig X v" emits the
    new state once. }
  DiffArgv('dbconfig-toggle-defensive',
    ':memory: ".dbconfig defensive on" ".dbconfig defensive off" ".dbconfig defensive"');
  DiffArgv('dbconfig-toggle-fkey',
    ':memory: ".dbconfig enable_fkey on" ".dbconfig enable_fkey"');
  DiffArgv('dbconfig-toggle-view',
    ':memory: ".dbconfig enable_view off" ".dbconfig enable_view on" ".dbconfig enable_view"');
  DiffArgv('dbconfig-toggle-fp_digits',
    ':memory: ".dbconfig fp_digits 10" ".dbconfig fp_digits"');
end;

begin
  upstream := FindUpstreamSqlite3;
  InitPaths;
  if upstream = '' then begin
    WriteLn('SKIP    dbinfo/dbconfig: no upstream sqlite3 binary found');
    WriteLn('        Set UPSTREAM_SQLITE3=/path/to/sqlite3 to enable.');
    CleanupPaths;
    WriteLn;
    WriteLn(Format('TestShellDbinfo: %d PASS / %d FAIL',
                   [passCount, failCount]));
    Halt(0);
  end;

  WriteLn('Using upstream: ', upstream);
  WriteLn('Using port    : ', binPath);
  WriteLn('Work dirs     : ', workDirExp, ' | ', workDirAct);

  SeedDatabases;
  RunDbinfo;
  RunDbconfig;

  CleanupPaths;

  WriteLn;
  WriteLn(Format('TestShellDbinfo: %d PASS / %d FAIL',
                 [passCount, failCount]));
  if failCount > 0 then Halt(1);
end.
