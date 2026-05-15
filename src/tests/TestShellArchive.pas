{
  SPDX-License-Identifier: blessing

  TestShellArchive — phase 10.1f.3/4/5 gate.  Exercises the
  `.archive`/`.ar` family (create / list-verbose / glob-filter /
  extract-roundtrip / dryrun / help), the `.session` "not compiled in"
  stub, and the `.recover` SQL stream by piping fixed scripts into both
  the port (`bin/passqlite3`) and upstream (`/home/bpsa/app/sqlite3/
  sqlite3`), then diffing stdout+stderr byte-for-byte.

  Coverage (mirrors tasklist.md 10.1f.*):
    - .archive / .ar    (10.1f.3) — create, list -tvf, glob filter,
                                    extract round-trip, --dryrun,
                                    --help shape.
    - .session          (10.1f.4) — port emits a friendly
                                    "session extension not compiled in
                                    to this build." stub; upstream
                                    (built without SQLITE_ENABLE_SESSION)
                                    falls through to the unknown-command
                                    arm.  This divergence is deliberate
                                    (see ticked 10.1.47); the gate
                                    asserts the port's shape only.
    - .recover          (10.1f.5) — byte-parity diff against upstream
                                    over a 3-row + index fixture, same
                                    shape DiagRecover already covers.

  Upstream C arms:
    - .archive / .ar  shell.c.in:9026  + arUsage at line ~6262
    - .session        shell.c.in:10718 (SQLITE_ENABLE_SESSION-gated)
    - .recover        shell.c.in:9338

  Skips with PASS if the upstream sqlite3 binary is unavailable
  (the .session shape arm still runs, since it only needs the port).
}
{$I ../passqlite3.inc}
program TestShellArchive;

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
  workDirExp := SysUtils.GetTempDir(False) + 'pas_arch_exp_' + tag;
  workDirAct := SysUtils.GetTempDir(False) + 'pas_arch_act_' + tag;
  ForceDirectories(workDirExp);
  ForceDirectories(workDirAct);
end;

procedure CleanupPaths;
begin
  fpsystem('rm -rf "' + workDirExp + '" "' + workDirAct + '"');
end;

{ Plant the same fixture tree in both work dirs.  Three files across
  two directories, mirroring the ticked 10.1.46 fixture shape used for
  the original `.archive` byte-parity verification:

    src/a.txt          ("alpha\n")
    src/dir1/b.txt     ("beta\n")
    c.txt              ("gamma\n")

  fsdir() walks these in a deterministic order, and the mtimes are
  forced to a single fixed value so the rendered `-tvf` listing is
  byte-stable across runs and across binaries. }
procedure SeedFixture(const root: AnsiString);
begin
  ForceDirectories(root + '/src/dir1');
  ShellWriteFileBytes(root + '/src/a.txt',      'alpha'#10);
  ShellWriteFileBytes(root + '/src/dir1/b.txt', 'beta'#10);
  ShellWriteFileBytes(root + '/c.txt',          'gamma'#10);
  { Pin mtimes so .ar -tvf rendering is deterministic. }
  fpsystem('touch -d "2024-01-02 03:04:05" "' + root + '/src/a.txt" "' +
           root + '/src/dir1/b.txt" "' + root + '/c.txt" "' +
           root + '/src" "' + root + '/src/dir1" 2>/dev/null');
end;

{ Run a fixed script under both binaries in their own working dirs,
  diff merged stdout+stderr.  argTail is the trailing CLI args (we use
  ':memory:' so the .archive arms can `.open` their own files inside
  the script). }
procedure DiffRun(const name, argTail, script: AnsiString);
var
  sqlExp, sqlAct, expOut, actOut, cmd: AnsiString;
  rcExp, rcAct: i32;
  eOut, aOut: AnsiString;
  ok: Boolean;
begin
  sqlExp := workDirExp + '/' + name + '.sql';
  sqlAct := workDirAct + '/' + name + '.sql';
  expOut := workDirExp + '/' + name + '.out';
  actOut := workDirAct + '/' + name + '.out';

  ShellWriteFileBytes(sqlExp, script);
  ShellWriteFileBytes(sqlAct, script);

  cmd := 'cd "' + workDirExp + '" && "' + upstream + '" ' + argTail +
         ' <"' + sqlExp + '" >"' + expOut + '" 2>&1';
  rcExp := fpsystem(cmd);

  cmd := 'cd "' + workDirAct + '" && LD_LIBRARY_PATH="' + libDir + '" "' +
         binPath + '" ' + argTail +
         ' <"' + sqlAct + '" >"' + actOut + '" 2>&1';
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

{ Compare a single argv-style CLI invocation (no script piped).  Used
  for cases where the dot-command is passed as a positional arg, e.g.
  `sqlite3 :memory: '.ar -cf foo.sqlar src c.txt'`. }
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

procedure RunArchive;
begin
  SeedFixture(workDirExp);
  SeedFixture(workDirAct);

  { -- create + list-verbose ----------------------------------------- }
  { `.ar -cf foo.sqlar src c.txt` builds an SQLAR with the three-file
    fixture; `.ar -tvf foo.sqlar` then renders the mode/size/mtime/
    name columns.  Both are byte-comparable across binaries. }
  DiffArgv('archive-create-list',
    ':memory: ".ar -cf foo.sqlar src c.txt" ".ar -tvf foo.sqlar"');

  { -- glob/name filter on -tvf -------------------------------------- }
  DiffArgv('archive-filter',
    ':memory: ".ar -cf foo2.sqlar src c.txt" ".ar -tvf foo2.sqlar src/a.txt"');

  { -- --dryrun: emits the SAVEPOINT/CREATE/REPLACE SQL stream without
       touching disk.  Pure stdout-shape diff. }
  DiffArgv('archive-dryrun',
    ':memory: ".ar --dryrun -cf foo3.sqlar c.txt"');

  { -- --help: arUsage() shape from shell.c.in line ~6262. }
  DiffArgv('archive-help', ':memory: ".archive --help"');

  { -- extract round-trip: `.ar -xvf` re-emits the names on stdout and
       writes the files back to disk; we diff both stdout AND the
       extracted file bodies. }
  { First, build the SQLAR in BOTH workdirs (separate copies so each
    binary extracts into its own tree). }
  fpsystem('cd "' + workDirExp + '" && "' + upstream +
           '" :memory: ".ar -cf foo.sqlar src c.txt" >/dev/null 2>&1');
  fpsystem('cd "' + workDirAct + '" && LD_LIBRARY_PATH="' + libDir + '" "' +
           binPath + '" :memory: ".ar -cf foo.sqlar src c.txt" >/dev/null 2>&1');
  { Wipe the source trees so extract has fresh ground. }
  fpsystem('rm -rf "' + workDirExp + '/src" "' + workDirExp + '/c.txt"');
  fpsystem('rm -rf "' + workDirAct + '/src" "' + workDirAct + '/c.txt"');

  DiffArgv('archive-extract', ':memory: ".ar -xvf foo.sqlar"');

  { Verify extracted bytes match across binaries. }
  if (ShellReadAll(workDirExp + '/src/a.txt') =
      ShellReadAll(workDirAct + '/src/a.txt')) and
     (ShellReadAll(workDirExp + '/src/dir1/b.txt') =
      ShellReadAll(workDirAct + '/src/dir1/b.txt')) and
     (ShellReadAll(workDirExp + '/c.txt') =
      ShellReadAll(workDirAct + '/c.txt')) and
     (ShellReadAll(workDirAct + '/src/a.txt') = 'alpha'#10) then begin
    WriteLn('PASS    archive-extract-bytes');
    Inc(passCount);
  end else begin
    WriteLn('FAIL    archive-extract-bytes (extracted file bodies differ)');
    Inc(failCount);
  end;
end;

procedure RunSession;
var
  outPath, cmd, body, needle: AnsiString;
  rc: i32;
begin
  { Upstream sqlite3 here is built without SQLITE_ENABLE_SESSION, so
    `.session` falls through to the unknown-command arm.  The port
    deliberately keeps a friendly "not compiled in" stub (ticked
    10.1.47), so a byte diff would always fail by design.  Instead
    we run `.session` against the port and assert the stub wording. }
  outPath := workDirAct + '/session.out';
  cmd := 'LD_LIBRARY_PATH="' + libDir + '" "' + binPath +
         '" :memory: ".session" >"' + outPath + '" 2>&1';
  rc := fpsystem(cmd);
  body := ShellReadAll(outPath);
  needle := 'session extension not compiled in';
  if Pos(needle, body) > 0 then begin
    WriteLn('PASS    session-stub (rc=', rc, ' stdout=', Length(body), 'B)');
    Inc(passCount);
  end else begin
    WriteLn('FAIL    session-stub — expected "', needle, '" in output');
    WriteLn('  got (', Length(body), 'B): |', body, '|');
    Inc(failCount);
  end;
end;

procedure RunRecover;
var
  dbExp, dbAct, seedSql: AnsiString;
begin
  { Build identical seed DBs in each workdir via upstream so the input
    to .recover is byte-identical on both sides. }
  seedSql :=
    'CREATE TABLE t(a INTEGER PRIMARY KEY, b TEXT);'#10 +
    'INSERT INTO t VALUES(1,''alpha''),(2,''beta''),(3,''gamma'');'#10 +
    'CREATE INDEX ti ON t(b);'#10;
  ShellWriteFileBytes(workDirExp + '/seed.sql', seedSql);
  ShellWriteFileBytes(workDirAct + '/seed.sql', seedSql);
  dbExp := workDirExp + '/recover.db';
  dbAct := workDirAct + '/recover.db';
  fpsystem('"' + upstream + '" "' + dbExp + '" <"' + workDirExp +
           '/seed.sql" >/dev/null 2>&1');
  fpsystem('"' + upstream + '" "' + dbAct + '" <"' + workDirAct +
           '/seed.sql" >/dev/null 2>&1');

  DiffArgv('recover-three-rows',
    '"' + dbExp + '" ".recover"');
  { ^ DiffArgv uses workDirExp's path for both; we rely on absolute
    paths above so the cd doesn't change the target file. }

  { Re-run with the act path to confirm symmetry (both binaries take
    their respective seed DB and produce the same recover stream). }
  DiffArgv('recover-three-rows-act',
    '"' + dbAct + '" ".recover"');
end;

begin
  upstream := FindUpstreamSqlite3;
  InitPaths;
  if upstream = '' then begin
    WriteLn('SKIP    archive/recover: no upstream sqlite3 binary found');
    WriteLn('        Set UPSTREAM_SQLITE3=/path/to/sqlite3 to enable.');
    { .session shape arm still runs even without upstream. }
    RunSession;
    CleanupPaths;
    WriteLn;
    WriteLn(Format('TestShellArchive: %d PASS / %d FAIL',
                   [passCount, failCount]));
    if failCount > 0 then Halt(1);
    Halt(0);
  end;

  WriteLn('Using upstream: ', upstream);
  WriteLn('Using port    : ', binPath);
  WriteLn('Work dirs     : ', workDirExp, ' | ', workDirAct);

  RunArchive;
  RunSession;
  RunRecover;

  CleanupPaths;

  WriteLn;
  WriteLn(Format('TestShellArchive: %d PASS / %d FAIL',
                 [passCount, failCount]));
  if failCount > 0 then Halt(1);
end.
