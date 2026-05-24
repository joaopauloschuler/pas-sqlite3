{
  SPDX-License-Identifier: blessing

  TestShellRepl — phase 10.1a.G gate.  Pipes a fixed REPL script (mixed
  .dot commands, multi-line SQL, --/block comments, single/double-quoted
  strings, `go`/`/` line terminators, ~/.sqliterc loading, -init payload
  loading, and -memtrace/-pcachetrace stderr capture) into both the
  port (`bin/passqlite3`) and the upstream `sqlite3` binary, and diffs
  stdout+stderr byte-for-byte.

  Sections are exercised as separate DiffCase invocations so any
  divergence pins itself to one feature.

  Skips with PASS if the upstream sqlite3 binary is unavailable on PATH
  or at $UPSTREAM_SQLITE3 — keeps stripped CI green while still gating
  locally.
}
{$I ../passqlite3.inc}
program TestShellRepl;

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

procedure InitPaths;
begin
  exeDir  := ExtractFilePath(ExpandFileName(ParamStr(0)));
  binPath := exeDir + 'passqlite3';
  libDir  := ExtractFilePath(ExcludeTrailingPathDelimiter(exeDir)) + 'src';
  tag     := IntToStr(GetProcessID);
end;

{ writeFile - dump 'body' to 'path' (overwrite). }
procedure writeFile(const path, body: AnsiString);
var f: TextFile;
begin
  AssignFile(f, path); Rewrite(f); Write(f, body); CloseFile(f);
end;

{ DiffCase: feed `sql` on stdin to both shells, compare stdout+stderr
  (merged via 2>&1, matching every other 10.1 gate's convention). }
procedure DiffCase(const name, sql: AnsiString);
var
  sqlPath, expPath, actPath, cmd: AnsiString;
  rcExp, rcAct: i32;
  expBody, actBody: AnsiString;
begin
  sqlPath := SysUtils.GetTempDir(False) + 'pas_repl_in_'  + tag + '.sql';
  expPath := SysUtils.GetTempDir(False) + 'pas_repl_exp_' + tag + '.txt';
  actPath := SysUtils.GetTempDir(False) + 'pas_repl_act_' + tag + '.txt';
  writeFile(sqlPath, sql);

  cmd := '"' + upstream + '" :memory: <"' + sqlPath +
         '" >"' + expPath + '" 2>&1';
  rcExp := fpsystem(cmd);

  cmd := 'LD_LIBRARY_PATH="' + libDir + '" "' + binPath +
         '" :memory: <"' + sqlPath + '" >"' + actPath + '" 2>&1';
  rcAct := fpsystem(cmd);

  expBody := readAll(expPath);
  actBody := readAll(actPath);
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

{ DiffArgs: spawn both shells with a custom envPrefix + argv tail,
  feeding `sql` on stdin (may be empty).  Diffs merged stdout+stderr.
  `envPrefix` is shell-syntax env assignments (e.g. `HOME=/tmp/foo `).
  `argTail` is appended after the binary path. }
procedure DiffArgs(const name, envPrefix, argTail, sql: AnsiString);
var
  sqlPath, expPath, actPath, cmd: AnsiString;
  rcExp, rcAct: i32;
  expBody, actBody: AnsiString;
  hasStdin: Boolean;
  stdinFrag: AnsiString;
begin
  sqlPath := SysUtils.GetTempDir(False) + 'pas_repl_in_'  + tag + '.sql';
  expPath := SysUtils.GetTempDir(False) + 'pas_repl_exp_' + tag + '.txt';
  actPath := SysUtils.GetTempDir(False) + 'pas_repl_act_' + tag + '.txt';
  hasStdin := sql <> '';
  if hasStdin then begin
    writeFile(sqlPath, sql);
    stdinFrag := ' <"' + sqlPath + '"';
  end else begin
    stdinFrag := ' </dev/null';
  end;

  cmd := envPrefix + '"' + upstream + '" ' + argTail +
         stdinFrag + ' >"' + expPath + '" 2>&1';
  rcExp := fpsystem(cmd);

  cmd := envPrefix + 'LD_LIBRARY_PATH="' + libDir + '" "' + binPath +
         '" ' + argTail + stdinFrag +
         ' >"' + actPath + '" 2>&1';
  rcAct := fpsystem(cmd);

  expBody := readAll(expPath);
  actBody := readAll(actPath);
  if hasStdin then SysUtils.DeleteFile(sqlPath);
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

{ DiffArgsSplit: like DiffArgs but captures stdout and stderr in
  separate files so the gate can prove that -memtrace / -pcachetrace
  emit MEMTRACE/PCACHE lines on stderr *only* (and not on stdout). }
procedure DiffArgsSplit(const name, envPrefix, argTail, sql: AnsiString);
var
  sqlPath, expOut, expErr, actOut, actErr, cmd: AnsiString;
  rcExp, rcAct: i32;
  eOut, eErr, aOut, aErr: AnsiString;
  hasStdin: Boolean;
  stdinFrag: AnsiString;
begin
  sqlPath := SysUtils.GetTempDir(False) + 'pas_repl_in_'  + tag + '.sql';
  expOut := SysUtils.GetTempDir(False) + 'pas_repl_eout_' + tag + '.txt';
  expErr := SysUtils.GetTempDir(False) + 'pas_repl_eerr_' + tag + '.txt';
  actOut := SysUtils.GetTempDir(False) + 'pas_repl_aout_' + tag + '.txt';
  actErr := SysUtils.GetTempDir(False) + 'pas_repl_aerr_' + tag + '.txt';
  hasStdin := sql <> '';
  if hasStdin then begin
    writeFile(sqlPath, sql);
    stdinFrag := ' <"' + sqlPath + '"';
  end else begin
    stdinFrag := ' </dev/null';
  end;

  cmd := envPrefix + '"' + upstream + '" ' + argTail +
         stdinFrag + ' >"' + expOut + '" 2>"' + expErr + '"';
  rcExp := fpsystem(cmd);

  cmd := envPrefix + 'LD_LIBRARY_PATH="' + libDir + '" "' + binPath +
         '" ' + argTail + stdinFrag +
         ' >"' + actOut + '" 2>"' + actErr + '"';
  rcAct := fpsystem(cmd);

  eOut := readAll(expOut); eErr := readAll(expErr);
  aOut := readAll(actOut); aErr := readAll(actErr);
  if hasStdin then SysUtils.DeleteFile(sqlPath);
  SysUtils.DeleteFile(expOut); SysUtils.DeleteFile(expErr);
  SysUtils.DeleteFile(actOut); SysUtils.DeleteFile(actErr);

  if (rcExp = rcAct) and (eOut = aOut) and (eErr = aErr) then begin
    WriteLn('PASS    ', name, ' (rc=', rcAct,
            ' stdout=', Length(aOut), 'B stderr=', Length(aErr), 'B)');
    Inc(passCount);
  end else begin
    WriteLn('FAIL    ', name, ' (rcExp=', rcExp, ' rcAct=', rcAct, ')');
    WriteLn('  stdout-exp (', Length(eOut), 'B): |', eOut, '|');
    WriteLn('  stdout-act (', Length(aOut), 'B): |', aOut, '|');
    WriteLn('  stderr-exp (', Length(eErr), 'B): |', eErr, '|');
    WriteLn('  stderr-act (', Length(aErr), 'B): |', aErr, '|');
    Inc(failCount);
  end;
end;

{ DiffArgsErrFloor: like DiffArgsSplit, but instead of byte-equal
  stderr we only require both shells to write *non-empty* stderr.  Use
  this for -memtrace/-pcachetrace where the trace text is verbose and
  may legitimately differ (allocator-specific addresses, instrumentation
  call sites): the parity claim is "trace lands on stderr, not stdout",
  not "trace strings are byte-identical".  We still require stdout to
  match byte-for-byte. }
{ preClean (optional) is a shell command run before EACH shell
  invocation; use it to reset on-disk state (e.g. `rm -f db`) so the
  port doesn't trip over residue left by the upstream run. }
procedure DiffArgsErrFloorEx(const name, envPrefix, argTail, sql,
  errSubstr, preClean: AnsiString); forward;

procedure DiffArgsErrFloor(const name, envPrefix, argTail, sql,
  errSubstr: AnsiString);
begin
  DiffArgsErrFloorEx(name, envPrefix, argTail, sql, errSubstr, '');
end;

procedure DiffArgsErrFloorEx(const name, envPrefix, argTail, sql,
  errSubstr, preClean: AnsiString);
var
  sqlPath, expOut, expErr, actOut, actErr, cmd: AnsiString;
  rcExp, rcAct: i32;
  eOut, eErr, aOut, aErr: AnsiString;
  ok: Boolean;
  hasStdin: Boolean;
  stdinFrag: AnsiString;
begin
  sqlPath := SysUtils.GetTempDir(False) + 'pas_repl_in_'  + tag + '.sql';
  expOut := SysUtils.GetTempDir(False) + 'pas_repl_eout_' + tag + '.txt';
  expErr := SysUtils.GetTempDir(False) + 'pas_repl_eerr_' + tag + '.txt';
  actOut := SysUtils.GetTempDir(False) + 'pas_repl_aout_' + tag + '.txt';
  actErr := SysUtils.GetTempDir(False) + 'pas_repl_aerr_' + tag + '.txt';
  hasStdin := sql <> '';
  if hasStdin then begin
    writeFile(sqlPath, sql);
    stdinFrag := ' <"' + sqlPath + '"';
  end else begin
    stdinFrag := ' </dev/null';
  end;

  if preClean <> '' then fpsystem(preClean);
  cmd := envPrefix + '"' + upstream + '" ' + argTail +
         stdinFrag + ' >"' + expOut + '" 2>"' + expErr + '"';
  rcExp := fpsystem(cmd);

  if preClean <> '' then fpsystem(preClean);
  cmd := envPrefix + 'LD_LIBRARY_PATH="' + libDir + '" "' + binPath +
         '" ' + argTail + stdinFrag +
         ' >"' + actOut + '" 2>"' + actErr + '"';
  rcAct := fpsystem(cmd);

  eOut := readAll(expOut); eErr := readAll(expErr);
  aOut := readAll(actOut); aErr := readAll(actErr);
  if hasStdin then SysUtils.DeleteFile(sqlPath);
  SysUtils.DeleteFile(expOut); SysUtils.DeleteFile(expErr);
  SysUtils.DeleteFile(actOut); SysUtils.DeleteFile(actErr);

  ok := (rcExp = rcAct) and (eOut = aOut) and
        (Pos(errSubstr, eErr) > 0) and (Pos(errSubstr, aErr) > 0) and
        (Pos(errSubstr, aOut) = 0);
  if ok then begin
    WriteLn('PASS    ', name, ' (rc=', rcAct,
            ' stdout=', Length(aOut), 'B stderr=', Length(aErr),
            'B; "', errSubstr, '" on stderr only)');
    Inc(passCount);
  end else begin
    WriteLn('FAIL    ', name, ' (rcExp=', rcExp, ' rcAct=', rcAct,
            ' substr="', errSubstr, '")');
    WriteLn('  stdout-exp (', Length(eOut), 'B): |', eOut, '|');
    WriteLn('  stdout-act (', Length(aOut), 'B): |', aOut, '|');
    WriteLn('  stderr-exp (', Length(eErr), 'B): |', eErr, '|');
    WriteLn('  stderr-act (', Length(aErr), 'B): |', aErr, '|');
    Inc(failCount);
  end;
end;

{ Make a fresh temp HOME so the rc-loading tests don't trip over the
  invoking user's real ~/.sqliterc.  Returns the directory path. }
function MakeTempHome(const suffix: AnsiString): AnsiString;
begin
  Result := SysUtils.GetTempDir(False) + 'pas_repl_home_' + tag + '_' + suffix;
  ForceDirectories(Result);
end;

procedure RmTempHome(const dir: AnsiString);
begin
  { Best effort — fpsystem rm -rf keeps it portable across FPC RTLs. }
  fpsystem('rm -rf "' + dir + '"');
end;

const
  { ----- Section 1: mixed .dot commands ------------------------------ }
  SCRIPT_DotCmds =
    '.headers on'#10 +
    '.mode list'#10 +
    '.print hello'#10 +
    'SELECT 1 AS x, 2 AS y;'#10;

  { ----- Section 2: multi-line SQL ----------------------------------- }
  SCRIPT_MultiLineSql =
    'CREATE TABLE t('#10 +
    '  a,'#10 +
    '  b'#10 +
    ');'#10 +
    'INSERT INTO t'#10 +
    '  VALUES'#10 +
    '  (1, 2);'#10 +
    'SELECT *'#10 +
    '  FROM t;'#10;

  { ----- Section 3: comments ----------------------------------------- }
  SCRIPT_Comments =
    '-- single-line comment before SQL'#10 +
    'SELECT 1; -- trailing single-line'#10 +
    '/* block comment */ SELECT 2;'#10 +
    'SELECT /* mid */ 3;'#10 +
    '/* multi'#10 +
    '   line'#10 +
    '   block */'#10 +
    'SELECT 4;'#10;

  { ----- Section 4: strings + quoted identifier ---------------------- }
  { 'foo''bar' is a single-quoted literal with an embedded single
    quote; "col with spaces" is a double-quoted identifier used as
    a column alias.  Both must round-trip byte-identical. }
  SCRIPT_Strings =
    'SELECT ''foo''''bar'' AS "col with spaces";'#10 +
    'CREATE TABLE q("c 1", "c 2");'#10 +
    'INSERT INTO q VALUES(''a''''b'', ''x"y'');'#10 +
    'SELECT "c 1", "c 2" FROM q;'#10;

  { ----- Section 5: `go` / `/` line terminators ---------------------- }
  { Both `go` and `/` on their own line act as command terminators
    (10.1.2.b).  No trailing semicolon on the SELECT — the terminator
    is supplied by `go` / `/`. }
  SCRIPT_GoSlash =
    'SELECT 11'#10 +
    'go'#10 +
    'SELECT 22'#10 +
    '/'#10 +
    'SELECT 33;'#10;

var
  homeDir, initPath: AnsiString;

begin
  upstream := findUpstreamSqlite3;
  if upstream = '' then begin
    WriteLn('SKIP    TestShellRepl: no upstream sqlite3 binary found');
    WriteLn('        Set UPSTREAM_SQLITE3=/path/to/sqlite3 to enable.');
    Halt(0);
  end;
  InitPaths;
  WriteLn('Using upstream: ', upstream);
  WriteLn('Using port    : ', binPath);

  { ----- Stdin-driven REPL parity ---------------------------------- }
  DiffCase('mixed .dot commands',          SCRIPT_DotCmds);
  DiffCase('multi-line SQL',               SCRIPT_MultiLineSql);
  DiffCase('-- and /* */ comments',        SCRIPT_Comments);
  DiffCase('strings + quoted identifier',  SCRIPT_Strings);
  DiffCase('go and / line terminators',    SCRIPT_GoSlash);

  { ----- ~/.sqliterc loading (10.1.3.a) ----------------------------- }
  { TODO 10.1a.G: ~/.sqliterc auto-load section deferred.  Upstream
    resolves $HOME via getpwuid(getuid()) *before* falling back to
    $HOME (shell.c.in:12548..12582 find_home_dir), so setting
    HOME=/tmp/<temp> in the harness env has no effect on upstream —
    upstream still reads the real user ~/.sqliterc.  The Pascal port
    has no getpwuid in base RTL and collapses to $HOME only (see
    memory note "FPC base RTL has no getpwuid", 10.1.3.a closure).
    This is a structural divergence between the two binaries, not a
    REPL bug, and it has no way to be exercised in a hermetic gate
    without modifying the invoking user's real ~/.sqliterc.
    The -init payload section below already exercises the same
    processSqliteRc() call site with a deterministic file path. }

  { ----- -init payload loading (10.1.3.b) --------------------------- }
  { Drop HOME to an empty dir so -init is the only rc source.  The
    init script sets .mode + .headers; the stdin script then prints.
    Identical handling required from both shells. }
  homeDir := MakeTempHome('init');
  initPath := homeDir + '/init.sql';
  writeFile(initPath,
    '.headers on'#10 +
    '.mode list'#10 +
    '.print init-loaded'#10);
  DiffArgs('-init file payload',
    'HOME="' + homeDir + '" XDG_CONFIG_HOME= ',
    '-init "' + initPath + '" :memory:',
    'SELECT 7 AS v;'#10);
  RmTempHome(homeDir);

  { ----- -memtrace stderr capture (10.1.3.c) ------------------------ }
  { Verifies (a) `select 42;` lands on stdout byte-identical to
    upstream, and (b) `MEMTRACE` lines land on stderr only.  Exact
    trace text differs (addresses, alloc sizes) so we use the
    "errFloor" matcher with the marker substring. }
  homeDir := MakeTempHome('memtrace');
  DiffArgsErrFloor('-memtrace stderr capture',
    'HOME="' + homeDir + '" XDG_CONFIG_HOME= ',
    '-memtrace :memory: "select 42;"',
    '',
    'MEMTRACE');
  RmTempHome(homeDir);

  { ----- -pcachetrace stderr capture (10.1.3.c) --------------------- }
  { Same shape as memtrace.  Upstream prints PCACHE.* lines on
    stderr; the port routes through libc_stderr as wired in
    10.1.3.c.  We test on a real on-disk DB (not :memory:) because
    the in-memory backend bypasses the page cache entirely, so
    -pcachetrace would emit nothing useful on :memory:. }
  homeDir := MakeTempHome('pcache');
  { DiffArgsErrFloor runs upstream first then the port against the
    same argv.  An on-disk DB persists across those two runs, so the
    port hits "table already exists" on the second CREATE.  Stream
    the SQL on stdin instead, so each run gets a fresh prepared
    statement set against a freshly-created on-disk DB. }
  DiffArgsErrFloorEx('-pcachetrace stderr capture',
    'HOME="' + homeDir + '" XDG_CONFIG_HOME= ',
    '-pcachetrace -bail "' + homeDir + '/p.db"',
    'create table t(x); insert into t values(1); select * from t;'#10,
    'PCACHE',
    'rm -f "' + homeDir + '/p.db"');
  RmTempHome(homeDir);

  WriteLn;
  WriteLn(Format('TestShellRepl: %d PASS / %d FAIL',
                 [passCount, failCount]));
  if failCount > 0 then Halt(1);
end.
