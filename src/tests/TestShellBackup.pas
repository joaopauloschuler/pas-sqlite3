{
  SPDX-License-Identifier: blessing

  TestShellBackup — phase 10.1f.0/1/2 gate.  Exercises the `.backup`,
  `.restore`, and `.clone` dot-commands by piping a fixed script into
  both the port (`bin/passqlite3`) and the upstream `sqlite3` binary,
  diffing stdout+stderr byte-for-byte, and additionally re-opening the
  resulting on-disk files in both binaries to confirm content parity.

  Coverage (mirrors tasklist.md 10.1f.*):
    - backup            .backup FILE                      (10.1f.0)
    - restore           .restore FILE (round-trip)        (10.1f.1)
    - clone             .clone NEWFILE                    (10.1f.2)

  Upstream C arms:
    - .backup   shell.c.in:9034..9101
    - .restore  shell.c.in:10492..10542
    - .clone    shell.c.in:9166..9174 → tryToClone

  Skips with PASS if the upstream sqlite3 binary is unavailable.
}
{$I ../passqlite3.inc}
program TestShellBackup;

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
  workDirExp, workDirAct: AnsiString;

procedure InitPaths;
begin
  exeDir  := ExtractFilePath(ExpandFileName(ParamStr(0)));
  binPath := exeDir + 'passqlite3';
  libDir  := ExtractFilePath(ExcludeTrailingPathDelimiter(exeDir)) + 'src';
  tag     := IntToStr(GetProcessID);
  workDirExp := SysUtils.GetTempDir(False) + 'pas_backup_exp_' + tag;
  workDirAct := SysUtils.GetTempDir(False) + 'pas_backup_act_' + tag;
  ForceDirectories(workDirExp);
  ForceDirectories(workDirAct);
end;

procedure CleanupPaths;
begin
  fpsystem('rm -rf "' + workDirExp + '" "' + workDirAct + '"');
end;

{ Run upstream against workDirExp and port against workDirAct, diff
  merged stdout+stderr byte-for-byte. Each run uses its own working
  directory so files written by one shell do not pollute the other. }
procedure DiffRun(const name, argTail, scriptExp, scriptAct: AnsiString);
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

  writeFileBytes(sqlExp, scriptExp);
  writeFileBytes(sqlAct, scriptAct);

  cmd := 'cd "' + workDirExp + '" && "' + upstream + '" ' + argTail +
         ' <"' + sqlExp + '" >"' + expOut + '" 2>&1';
  rcExp := fpsystem(cmd);

  cmd := 'cd "' + workDirAct + '" && LD_LIBRARY_PATH="' + libDir + '" "' +
         binPath + '" ' + argTail +
         ' <"' + sqlAct + '" >"' + actOut + '" 2>&1';
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

{ Re-open a file produced by each shell in its own binary, run a
  SELECT, capture stdout, and diff. Confirms the resulting on-disk
  databases have the same logical content (file headers/freelist may
  legitimately differ, so we don't byte-diff the raw .db files). }
procedure DiffOpenedContent(const tag, expFile, actFile, sql: AnsiString);
var
  sqlPath, expOut, actOut, cmd: AnsiString;
  rcExp, rcAct: i32;
  eOut, aOut: AnsiString;
  ok: Boolean;
begin
  sqlPath := workDirExp + '/' + tag + '.query.sql';
  expOut  := workDirExp + '/' + tag + '.query.exp';
  actOut  := workDirExp + '/' + tag + '.query.act';
  writeFileBytes(sqlPath, sql);

  cmd := '"' + upstream + '" "' + expFile + '" <"' + sqlPath +
         '" >"' + expOut + '" 2>&1';
  rcExp := fpsystem(cmd);

  cmd := 'LD_LIBRARY_PATH="' + libDir + '" "' + binPath + '" "' + actFile +
         '" <"' + sqlPath + '" >"' + actOut + '" 2>&1';
  rcAct := fpsystem(cmd);

  eOut := readAll(expOut);
  aOut := readAll(actOut);

  ok := (rcExp = rcAct) and (eOut = aOut) and (Length(aOut) > 0);
  if ok then begin
    WriteLn('PASS    ', tag, '-content (rc=', rcAct,
            ' stdout=', Length(aOut), 'B)');
    Inc(passCount);
  end else begin
    WriteLn('FAIL    ', tag, '-content (rcExp=', rcExp, ' rcAct=', rcAct, ')');
    WriteLn('  exp (', Length(eOut), 'B): |', eOut, '|');
    WriteLn('  act (', Length(aOut), 'B): |', aOut, '|');
    Inc(failCount);
  end;
end;

const
  { Source DB seed used by all three gates.  Keep it small and fully
    deterministic — three rows, mixed types, primary key. }
  SeedSql =
    'CREATE TABLE t(a INTEGER PRIMARY KEY, b TEXT, c REAL);'#10 +
    'INSERT INTO t VALUES(1, ''alpha'', 1.5);'#10 +
    'INSERT INTO t VALUES(2, ''bravo'', 2.5);'#10 +
    'INSERT INTO t VALUES(3, ''charlie'', NULL);'#10 +
    'CREATE INDEX ix_t_b ON t(b);'#10;

procedure SeedSource(const dbPath: AnsiString);
var
  sqlPath, cmd: AnsiString;
begin
  sqlPath := workDirExp + '/seed_' + ExtractFileName(dbPath) + '.sql';
  writeFileBytes(sqlPath, SeedSql);
  { Use upstream to seed both sides — guarantees the source file is
    byte-identical regardless of port format quirks. }
  cmd := '"' + upstream + '" "' + dbPath + '" <"' + sqlPath +
         '" >/dev/null 2>&1';
  fpsystem(cmd);
end;

var
  script, srcExp, srcAct, dstExp, dstAct, restExp, restAct,
  cloneExp, cloneAct: AnsiString;

begin
  upstream := findUpstreamSqlite3;
  if upstream = '' then begin
    WriteLn('SKIP    TestShellBackup: no upstream sqlite3 binary found');
    WriteLn('        Set UPSTREAM_SQLITE3=/path/to/sqlite3 to enable.');
    Halt(0);
  end;
  InitPaths;
  WriteLn('Using upstream: ', upstream);
  WriteLn('Using port    : ', binPath);
  WriteLn('Work dirs     : ', workDirExp, ' | ', workDirAct);

  { -------- backup (10.1f.0) -------------------------------------- }
  { `.backup FILE` clones the open main db onto FILE via
    sqlite3_backup_init/_step/_finish.  Source is seeded identically
    via upstream so the .backup output is the only port-vs-upstream
    surface.  Script emits no stdout on success — both shells should
    print nothing.  We then open the produced backup file in each
    shell's own binary and confirm SELECT * matches. }
  srcExp := workDirExp + '/src.db';
  srcAct := workDirAct + '/src.db';
  dstExp := workDirExp + '/backup.db';
  dstAct := workDirAct + '/backup.db';
  SeedSource(srcExp);
  SeedSource(srcAct);

  script :=
    '.open ' + 'src.db'#10 +
    '.backup ' + 'backup.db'#10;
  DiffRun('backup', ':memory:', script, script);
  DiffOpenedContent('backup', dstExp, dstAct,
    'SELECT * FROM t ORDER BY a;'#10 +
    'SELECT name FROM sqlite_schema ORDER BY name;'#10);

  { Usage error: bare .backup with no FILENAME emits
    `missing FILENAME argument on .backup\n` on stderr. }
  script := '.backup'#10;
  DiffRun('backup-usage', ':memory:', script, script);

  { -------- restore (10.1f.1) ------------------------------------- }
  { `.restore FILE` copies FILE into the open main db.  We seed a
    distinct source file, run restore into a :memory: db, and then
    SELECT to confirm the round-trip.  Stdout should be silent. }
  script :=
    '.restore src.db'#10 +
    'SELECT a, b, c FROM t ORDER BY a;'#10;
  DiffRun('restore', ':memory:', script, script);

  { Restore-into-named-db (`.restore main FILE`): same effect as the
    one-arg form but exercises the 3-arg parse branch. }
  script :=
    '.restore main src.db'#10 +
    'SELECT count(*) FROM t;'#10;
  DiffRun('restore-named', ':memory:', script, script);

  { Usage error path. }
  script := '.restore'#10;
  DiffRun('restore-usage', ':memory:', script, script);

  { Round-trip: backup the seeded source, drop the table from a
    fresh in-memory db, then restore it back.  Verifies both arms
    work together. }
  script :=
    '.open src.db'#10 +
    '.backup roundtrip.db'#10 +
    '.open :memory:'#10 +
    'CREATE TABLE t(a INTEGER PRIMARY KEY, b TEXT, c REAL);'#10 +
    'INSERT INTO t VALUES(99, ''gone'', 0);'#10 +
    '.restore roundtrip.db'#10 +
    'SELECT a, b FROM t ORDER BY a;'#10;
  DiffRun('backup-restore-roundtrip', ':memory:', script, script);

  { -------- clone (10.1f.2) -------------------------------------- }
  { `.clone NEWFILE` walks sqlite_schema replaying CREATE/INSERTs.
    Emits a per-table breadcrumb (`tablename... done\n`) on stdout.
    NEWFILE must not pre-exist.  Each binary writes into its own
    workdir so the "already exists" check is independent. }
  cloneExp := workDirExp + '/clone.db';
  cloneAct := workDirAct + '/clone.db';

  script :=
    '.open src.db'#10 +
    '.clone clone.db'#10;
  DiffRun('clone', ':memory:', script, script);
  DiffOpenedContent('clone', cloneExp, cloneAct,
    'SELECT * FROM t ORDER BY a;'#10 +
    'SELECT name FROM sqlite_schema ORDER BY name;'#10);

  { Re-running .clone against an existing file emits
    `File "X" already exists.\n` on stderr (shell.c.in tryToClone). }
  script :=
    '.open src.db'#10 +
    '.clone clone.db'#10;
  DiffRun('clone-exists', ':memory:', script, script);

  { Usage error: bare .clone. }
  script := '.clone'#10;
  DiffRun('clone-usage', ':memory:', script, script);

  CleanupPaths;

  WriteLn;
  WriteLn(Format('TestShellBackup: %d PASS / %d FAIL',
                 [passCount, failCount]));
  if failCount > 0 then Halt(1);
end.
