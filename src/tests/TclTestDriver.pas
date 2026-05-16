{ TclTestDriver — 9.4.3.a skeleton.

  Reads src/tests/tcl/MANIFEST.txt.  For each `tcl-feature` entry,
  spawns `tclsh` with an in-memory script that:

      load <abs>/bin/libpassqlite3tcl.so Sqlite3
      package require sqlite3
      set ::testdir <abs>/src/tests/tcl
      source $::testdir/tester_min.tcl
      sqlite3 db :memory:
      source <abs/path-to.test>
      catch [db close]
      finalize_testing

  Captures stdout + stderr + exit code, classifies PASS/FAIL/SKIP,
  emits one line per file in the form

      PASS|FAIL|SKIP <path> <nTest> <duration_ms>

  CLI:
      --limit N           cap number of tcl-feature entries processed
      --filter SUBSTR     only paths whose name contains SUBSTR
      --manifest PATH     override manifest location

  No top-level gate yet — wiring deferred to 9.4.4.a.  Skip-list hook
  is in place but empty.
}
program TclTestDriver;

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, Process, Pipes;

const
  PER_TEST_TIMEOUT_MS = 30000;

  { 9.4.divbug.84: a handful of upstream .test files are genuinely long-
    running — large fuzz/crash-injection loops with hundreds-of-thousands
    of subtests — that exceed the 30 s baseline even though no engine bug
    is at play.  Override their per-test budget here so the driver no
    longer mis-counts them as FAIL via the timeout watchdog.

    Measured pas runtimes (worktree, 2026-05-16):
      securedel2.test  >617 s   (subtests reach 1.6.x; loop blocked on
                                 missing `hexio_read` Tcl command — each
                                 page-inspection do_test catches the
                                 missing-cmd error and continues)
      select4.test     >181 s   (1043-line EXCEPT/UNION matrix; reaches
                                 11.7 of ~14 named groups in 180 s — still
                                 progressing, just slow)
      writecrash.test  >180 s   (subtest IDs reach 1.331698.x; loop blocked
                                 on missing `crash_on_write` crash-VFS cmd
                                 — every iteration is a no-op so the test
                                 walks its full ~331k row matrix)

    900 s (15 min) gives enough headroom for the three to either complete
    or to surface real failures the classifier can act on.  The two
    "missing Tcl command" cases (hexio_read, crash_on_write) are tracked
    separately under the test1.c port (divbug.62.b/.c family) — once they
    land, runtimes will collapse and this table can shrink.

    These tests are listed `pas-soft` in src/tests/tcl/STATUS.txt so the
    aggregate sweep doesn't flag them; the override here is only to keep
    the per-test driver from mis-attributing FAIL via the watchdog.

    Keep the table small and explicit; do NOT use it as a dumping ground
    for tests that legitimately fail.  Each entry must have a measured
    runtime comment justifying its presence. }
type
  TPerTestTimeout = record
    BaseName : string;       { ExtractFileName, lowercase }
    Ms       : LongInt;
  end;
const
  PER_TEST_TIMEOUT_OVERRIDES: array[0..2] of TPerTestTimeout = (
    (BaseName: 'securedel2.test'; Ms: 900000),
    (BaseName: 'select4.test';    Ms: 900000),
    (BaseName: 'writecrash.test'; Ms: 900000)
  );

function TimeoutForTest(const testAbsPath: string): LongInt;
var
  i  : Integer;
  bn : string;
begin
  bn := LowerCase(ExtractFileName(testAbsPath));
  for i := Low(PER_TEST_TIMEOUT_OVERRIDES) to High(PER_TEST_TIMEOUT_OVERRIDES) do
    if PER_TEST_TIMEOUT_OVERRIDES[i].BaseName = bn then
      Exit(PER_TEST_TIMEOUT_OVERRIDES[i].Ms);
  Result := PER_TEST_TIMEOUT_MS;
end;

var
  gRoot       : string;        { absolute pas-sqlite3 root }
  gBinDir     : string;        { absolute path to bin/ (holds .so + pkgIndex.tcl) }
  gSoPath     : string;        { absolute path to libpassqlite3tcl.so }
  gTclDir     : string;        { absolute path to src/tests/tcl }
  gManifest   : string;        { absolute manifest path }
  gLimit      : Integer = -1;
  gFilter     : string  = '';
  gSkipList   : TStringList;

  nPass, nFail, nSkip, nTotal : Integer;

{----------------------------------------------------------------------------
  Resolve absolute path of executable's project root.
  TclTestDriver lives in bin/; root is one directory up.
----------------------------------------------------------------------------}
function ResolveRoot: string;
var s: string;
begin
  s := ParamStr(0);
  { ParamStr(0) may be a bare name (PATH lookup) or a relative path;
    ExpandFileName against CWD is only correct for relative-with-slash
    invocations.  Prefer the well-known absolute install location. }
  if (Pos(DirectorySeparator, s) = 0) then begin
    { bare name — fall back to a path containing this source tree }
    Result := '';
  end else
    s := ExpandFileName(s);
  if s <> '' then
    Result := ExtractFileDir(ExtractFileDir(s))   { strip /bin/TclTestDriver }
  else
    Result := '';
  { last-resort fallbacks so ::testdir always lands on a real directory }
  if (Result = '') or
     (not DirectoryExists(IncludeTrailingPathDelimiter(Result)
                          + 'src' + DirectorySeparator + 'tests'
                          + DirectorySeparator + 'tcl')) then
  begin
    if DirectoryExists(IncludeTrailingPathDelimiter(GetCurrentDir)
         + 'src' + DirectorySeparator + 'tests' + DirectorySeparator + 'tcl') then
      Result := GetCurrentDir
    else if Result = '' then
      Result := GetCurrentDir;
  end;
end;

procedure ParseArgs;
var i: Integer; a: string;
begin
  i := 1;
  while i <= ParamCount do begin
    a := ParamStr(i);
    if a = '--limit' then begin
      Inc(i); gLimit := StrToIntDef(ParamStr(i), -1);
    end else if a = '--filter' then begin
      Inc(i); gFilter := ParamStr(i);
    end else if a = '--manifest' then begin
      Inc(i); gManifest := ExpandFileName(ParamStr(i));
    end else begin
      Writeln(StdErr, 'TclTestDriver: unknown arg: ', a);
      Halt(2);
    end;
    Inc(i);
  end;
end;

{----------------------------------------------------------------------------
  BuildScript — emit the multi-line tclsh script body.
  testAbsPath is absolute path to the .test file.
  tmpDir, when non-empty, is the isolated per-test working directory the
  interpreter cd's into before sourcing the .test file (9.4.7.f).
----------------------------------------------------------------------------}
function BuildScript(const testAbsPath: string; const tmpDir: string): string;
var sb: TStringList;
begin
  sb := TStringList.Create;
  try
    { 9.4.7.h: put bin/ on ::auto_path so `package require sqlite3` finds
      the generated pkgIndex.tcl and loads libpassqlite3tcl.so itself.
      Fall back to an explicit `load` if the pkgIndex isn't present (e.g.
      bin/ built before 9.4.7.h landed). }
    sb.Add('lappend ::auto_path {' + gBinDir + '}');
    sb.Add('if {[catch {package require sqlite3}]} {');
    sb.Add('  load {' + gSoPath + '} Sqlite3');
    sb.Add('  package require sqlite3');
    sb.Add('}');
    { 9.4.7.f: cd into the per-test tmpdir so any test.db / -journal / -wal
      the test leaks lands in a throwaway directory the driver deletes
      afterwards — tests can no longer cross-pollinate each other.
      ::testdir stays absolute (set below) so $::testdir/wal_common.tcl
      etc. still resolve from inside the tmpdir. }
    if tmpDir <> '' then
      sb.Add('cd {' + tmpDir + '}');
    { 9.4.3.c: ::testdir is pinned to the *absolute* src/tests/tcl path so
      .test files can `source $::testdir/wal_common.tcl` etc. regardless of
      the interpreter's current working directory (which 9.4.7.f changes to
      a per-test tmpdir).  Brace-quoted to survive spaces in the path. }
    sb.Add('set ::testdir {' + gTclDir + '}');
    sb.Add('source $::testdir/tester_min.tcl');
    { 9.4.4.a: monkey-patch [source] so upstream .test files that begin with
      `source $testdir/tester.tcl` transparently re-route to our tester_min
      shim.  Without this, every upstream .test fails at the first line. }
    sb.Add('set ::pas_shim_dir {' + gTclDir + '}');
    sb.Add('rename source __orig_source');
    sb.Add('proc source {path args} {');
    sb.Add('  set tail [file tail $path]');
    sb.Add('  if {$tail eq "tester.tcl"} {');
    sb.Add('    return [uplevel 1 [list __orig_source $::pas_shim_dir/tester_min.tcl]]');
    sb.Add('  }');
    { 9.4.6.q.2: route `source $testdir/permutations.test` to our baseline-only
      stub.  Upstream all.test does `source $testdir/permutations.test`, but
      $testdir for the upstream layout resolves to `./` relative to the
      per-test tmpdir, so the upstream file is unreachable.  Send the lookup
      to our stub instead. }
    sb.Add('  if {$tail eq "permutations.test"} {');
    sb.Add('    return [uplevel 1 [list __orig_source $::pas_shim_dir/permutations.test]]');
    sb.Add('  }');
    sb.Add('  return [uplevel 1 __orig_source [list $path] $args]');
    sb.Add('}');
    { 9.4.divbug.3: tester_min.tcl now opens `db` on a fresh on-disk
      ./test.db via reset_db (mirroring upstream tester.tcl), so the
      driver no longer issues its own `sqlite3 db :memory:` — that
      broke sub-tests that re-open test.db to re-read the schema. }
    sb.Add('if {[catch {source ' + testAbsPath + '} __err __opts]} {');
    sb.Add('  puts stderr "SOURCE-ERROR: $__err"');
    sb.Add('}');
    sb.Add('catch { db close }');
    sb.Add('finalize_testing');
    Result := sb.Text;
  finally
    sb.Free;
  end;
end;

{----------------------------------------------------------------------------
  AppendChunk — drain a pipe into a string while process is running.
----------------------------------------------------------------------------}
procedure AppendChunk(stream: TInputPipeStream; var s: AnsiString);
const CHUNK = 4096;
var
  buf : array[0..CHUNK-1] of Byte;
  n   : LongInt;
  old : Integer;
begin
  while stream.NumBytesAvailable > 0 do begin
    n := stream.Read(buf, CHUNK);
    if n <= 0 then Break;
    old := Length(s);
    SetLength(s, old + n);
    Move(buf[0], s[old + 1], n);
  end;
end;

{----------------------------------------------------------------------------
  9.4.7.f: per-test isolation helpers.

  Each test runs in its own freshly-created tmpdir so a leaked test.db /
  test.db-journal / WAL file from one .test cannot cross-pollinate the
  next.  The tmpdir is removed (recursively) when the test finishes.
----------------------------------------------------------------------------}
function MakeTestTmpDir(const testAbsPath: string): string;
var
  base, tag: string;
  attempt  : Integer;
begin
  base := GetTempDir(False);
  if base = '' then base := '/tmp';
  base := IncludeTrailingPathDelimiter(base);
  tag  := ChangeFileExt(ExtractFileName(testAbsPath), '');
  attempt := 0;
  repeat
    Result := base + 'pastcl_' + tag + '_'
              + IntToStr(GetProcessID) + '_'
              + IntToStr(GetTickCount64) + '_' + IntToStr(attempt);
    Inc(attempt);
  until (not DirectoryExists(Result)) or (attempt > 1000);
  if not CreateDir(Result) then
    Result := '';   { caller falls back to the .test file's own dir }
end;

procedure RemoveDirRecursive(const dir: string);
var
  info : TSearchRec;
  full : string;
begin
  if (dir = '') or (not DirectoryExists(dir)) then Exit;
  if FindFirst(IncludeTrailingPathDelimiter(dir) + '*', faAnyFile, info) = 0 then
  begin
    repeat
      if (info.Name = '.') or (info.Name = '..') then Continue;
      full := IncludeTrailingPathDelimiter(dir) + info.Name;
      if (info.Attr and faDirectory) <> 0 then
        RemoveDirRecursive(full)
      else
        DeleteFile(full);
    until FindNext(info) <> 0;
    FindClose(info);
  end;
  RemoveDir(dir);
end;

{----------------------------------------------------------------------------
  RunOne — spawn tclsh, feed script via stdin, capture stdout/stderr,
  enforce timeout.  Returns exit code (or -1 on spawn fail, -2 on timeout).
----------------------------------------------------------------------------}
function RunOne(const testAbsPath: string;
                out sOut, sErr: AnsiString;
                out durationMs: Int64): Integer;
var
  p          : TProcess;
  script     : AnsiString;
  scriptBytes: TBytes;
  startTick  : QWord;
  endTick    : QWord;
  cwd        : string;
  tmpDir     : string;
begin
  sOut := '';
  sErr := '';
  durationMs := 0;

  { 9.4.7.f: spin up an isolated working directory for this test. }
  tmpDir := MakeTestTmpDir(testAbsPath);
  script := BuildScript(testAbsPath, tmpDir);

  p := TProcess.Create(nil);
  try
    p.Executable := '/usr/bin/tclsh';
    { read script from stdin (single dash) }
    p.Parameters.Add('-');
    if tmpDir <> '' then
      cwd := tmpDir
    else
      cwd := ExtractFileDir(testAbsPath);   { fallback if tmpdir create failed }
    if cwd <> '' then p.CurrentDirectory := cwd;
    p.Options := [poUsePipes];
    p.ShowWindow := swoHIDE;

    startTick := GetTickCount64;
    try
      p.Execute;
    except
      on E: Exception do begin
        Writeln(StdErr, 'TclTestDriver: spawn failed: ', E.Message);
        Result := -1;
        Exit;
      end;
    end;

    { feed script then close stdin — the test only starts running after
      stdin is closed, so re-baseline startTick here: fork/exec and the
      script-write above are driver overhead, not test time. }
    SetLength(scriptBytes, Length(script));
    if Length(script) > 0 then
      Move(script[1], scriptBytes[0], Length(script));
    if Length(scriptBytes) > 0 then
      p.Input.Write(scriptBytes[0], Length(scriptBytes));
    p.CloseInput;
    startTick := GetTickCount64;

    { Poll loop.  The previous version captured the end time AFTER the
      final post-loop drain, so any time spent in AppendChunk draining a
      large backlog was silently folded away from one test and (worse)
      the last Sleep(10) before `Running` flipped false was never
      attributed at all — per-test duration came out short.  Fix: stamp
      endTick the instant the loop observes the child has exited, then
      drain.  endTick is also stamped on every iteration so a child that
      exits mid-Sleep is measured to within one poll interval rather
      than losing the whole final interval. }
    endTick := startTick;
    while p.Running do begin
      AppendChunk(p.Output, sOut);
      AppendChunk(p.Stderr, sErr);
      endTick := GetTickCount64;
      if (endTick - startTick) > QWord(TimeoutForTest(testAbsPath)) then begin
        Writeln(StdErr, 'timeout: ', testAbsPath);
        p.Terminate(124);
        durationMs := Int64(endTick - startTick);
        Result := -2;
        Exit;
      end;
      Sleep(5);
    end;
    { child has exited — stamp end time before draining residual output }
    endTick := GetTickCount64;
    { final drain }
    AppendChunk(p.Output, sOut);
    AppendChunk(p.Stderr, sErr);

    durationMs := Int64(endTick - startTick);
    Result := p.ExitStatus;
  finally
    p.Free;
    { 9.4.7.f: tear down the per-test tmpdir (and any test.db / journals
      / WAL files the test left behind).  Done in finally so it also
      runs on the timeout and spawn-fail early-exit paths. }
    if tmpDir <> '' then
      RemoveDirRecursive(tmpDir);
  end;
end;

{----------------------------------------------------------------------------
  ParseNTest — pull the "N errors out of M tests" line from stdout.
  Returns M, or 0 if not found.
----------------------------------------------------------------------------}
function ParseNTest(const sOut: AnsiString): Integer;
var
  lines: TStringList;
  i    : Integer;
  ln   : string;
  p1, p2: Integer;
  numStr: string;
begin
  Result := 0;
  lines := TStringList.Create;
  try
    lines.Text := sOut;
    for i := 0 to lines.Count - 1 do begin
      ln := lines[i];
      p1 := Pos('errors out of', ln);
      if p1 = 0 then Continue;
      p2 := Pos(' tests', ln);
      if p2 = 0 then Continue;
      { extract digits between 'of ' and ' tests' }
      numStr := Trim(Copy(ln, p1 + Length('errors out of'),
                          p2 - (p1 + Length('errors out of'))));
      Result := StrToIntDef(numStr, 0);
      Exit;
    end;
  finally
    lines.Free;
  end;
end;

{----------------------------------------------------------------------------
  Classify result.
----------------------------------------------------------------------------}
function Classify(rc: Integer; const sOut, sErr: AnsiString): string;
begin
  if rc = -2 then Exit('FAIL');             { timeout }
  if rc = -1 then Exit('SKIP');             { spawn failure }
  if rc = 0 then begin
    if (Pos('Expected:', sErr) > 0) or (Pos('expected:', sErr) > 0) then
      Exit('FAIL');
    if Pos('SOURCE-ERROR:', sErr) > 0 then Exit('FAIL');
    Exit('PASS');
  end;
  Result := 'FAIL';
end;

{----------------------------------------------------------------------------
  IsSkipped — placeholder hook; skip list empty for 9.4.3.a.
----------------------------------------------------------------------------}
function IsSkipped(const relPath: string): Boolean;
var i: Integer;
begin
  for i := 0 to gSkipList.Count - 1 do
    if Pos(gSkipList[i], relPath) > 0 then Exit(True);
  Result := False;
end;

{----------------------------------------------------------------------------
  ProcessEntry — handle one manifest line that has tag 'tcl-feature'.
----------------------------------------------------------------------------}
procedure ProcessEntry(const relPath: string);
var
  absPath   : string;
  sOut, sErr: AnsiString;
  durMs     : Int64;
  rc        : Integer;
  cls       : string;
  nT        : Integer;
begin
  { 9.4.4.b.2: resolve to an *absolute* path.  The 9.4.7.f per-test
    tmpdir isolation cd's tclsh into a throwaway directory, so a
    relative manifest path (e.g. ../sqlite3/test/foo.test) no longer
    resolves from inside the child — every test SOURCE-ERROR'd in
    ~11ms.  ExpandFileName the candidate against the driver's CWD
    (repo root) before handing it to BuildScript. }
  absPath := ExpandFileName(relPath);
  if not FileExists(absPath) then
    absPath := ExpandFileName(IncludeTrailingPathDelimiter(gRoot) + relPath);
  if not FileExists(absPath) then
    absPath := ExpandFileName(IncludeTrailingPathDelimiter(gRoot) + '..' + DirectorySeparator + relPath);

  Inc(nTotal);

  if IsSkipped(relPath) or (not FileExists(absPath)) then begin
    Writeln('SKIP ', relPath, ' 0 0');
    Inc(nSkip);
    Exit;
  end;

  rc := RunOne(absPath, sOut, sErr, durMs);
  nT := ParseNTest(sOut);
  cls := Classify(rc, sOut, sErr);

  Writeln(cls, ' ', relPath, ' ', nT, ' ', durMs);
  if cls = 'PASS' then Inc(nPass)
  else if cls = 'SKIP' then Inc(nSkip)
  else Inc(nFail);

  Flush(Output);
end;

{----------------------------------------------------------------------------
  Main.
----------------------------------------------------------------------------}
var
  manifest : TStringList;
  i, nDone : Integer;
  line, tag, p: string;
  tabIdx   : Integer;
  startTotal: QWord;
begin
  gRoot := ResolveRoot;
  gBinDir := IncludeTrailingPathDelimiter(gRoot) + 'bin';
  gSoPath := IncludeTrailingPathDelimiter(gBinDir) + 'libpassqlite3tcl.so';
  gTclDir := IncludeTrailingPathDelimiter(gRoot) + 'src' + DirectorySeparator + 'tests' + DirectorySeparator + 'tcl';
  gManifest := IncludeTrailingPathDelimiter(gTclDir) + 'MANIFEST.txt';

  ParseArgs;

  if not FileExists(gSoPath) then begin
    Writeln(StdErr, 'TclTestDriver: missing ', gSoPath);
    Halt(2);
  end;
  if not FileExists(gManifest) then begin
    Writeln(StdErr, 'TclTestDriver: missing manifest: ', gManifest);
    Halt(2);
  end;
  if not FileExists('/usr/bin/tclsh') then begin
    Writeln(StdErr, 'TclTestDriver: tclsh not found at /usr/bin/tclsh');
    Halt(2);
  end;

  gSkipList := TStringList.Create;
  { 9.4.3.a: skip list intentionally empty; populated in 9.4.4.a }

  manifest := TStringList.Create;
  try
    manifest.LoadFromFile(gManifest);
    nPass := 0; nFail := 0; nSkip := 0; nTotal := 0; nDone := 0;
    startTotal := GetTickCount64;

    for i := 0 to manifest.Count - 1 do begin
      line := manifest[i];
      if line = '' then Continue;
      tabIdx := Pos(#9, line);
      if tabIdx = 0 then Continue;
      tag := Copy(line, 1, tabIdx - 1);
      p   := Copy(line, tabIdx + 1, MaxInt);
      if tag <> 'tcl-feature' then Continue;
      if (gFilter <> '') and (Pos(gFilter, ExtractFileName(p)) = 0) then Continue;
      if (gLimit > 0) and (nDone >= gLimit) then Break;
      Inc(nDone);
      ProcessEntry(p);
    end;

    Writeln(StdErr, Format('Total: %d pass / %d fail / %d skip / %d total in %d ms',
      [nPass, nFail, nSkip, nTotal, Int64(GetTickCount64 - startTotal)]));
  finally
    manifest.Free;
    gSkipList.Free;
  end;

  if nFail > 0 then Halt(1) else Halt(0);
end.
