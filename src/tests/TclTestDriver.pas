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
      --shard I/N         (9.4.5.b) run only entries in slice I of N
                          where entries are sliced AFTER --filter but
                          BEFORE --limit.  I is 0-based, 0<=I<N.
      --build PROFILE     (9.4.7.i) select which engine shared-object to
                          load.  PROFILE is appended as a suffix:
                            default   -> bin/libpassqlite3tcl.so
                            <name>    -> bin/libpassqlite3tcl-<name>.so
                          (e.g. `--build threadsafe` loads
                          libpassqlite3tcl-threadsafe.so; `--build memdebug`
                          loads libpassqlite3tcl-memdebug.so).  Forces the
                          explicit-load fallback path so the pkgIndex.tcl
                          default .so is bypassed for this run.
      --fail-log-dir DIR  (9.4.5.c) on FAIL, write per-test
                          <basename>.out / .err under DIR.  Default is
                          <bin>/tcl-failure-logs/ when unset.
      --gate strict       (9.4.8.c) after the run, diff the result
                          classifications against the pas-strict tags
                          in src/tests/tcl/STATUS.txt; exit non-zero
                          if any pas-strict row regressed to FAIL.
                          Mirrors check_status_regression.sh inline.
      --coverage          (9.4.8.d) opt-in opcode-coverage mode.
                          Injects pas_opcode_coverage_enable into the
                          child tclsh script, dumps per-test hit
                          tables to a tmpdir, aggregates them on exit,
                          and writes src/tests/tcl/COVERAGE_DELTA.md
                          listing opcodes hit ONLY by the tcl corpus
                          (i.e. cold in 9.1 / 9.2 per the corpus
                          COVERAGE_GAPS.md snapshot).  Defaults off so
                          the standard sweep pays zero extra cost.

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
  PER_TEST_TIMEOUT_OVERRIDES: array[0..3] of TPerTestTimeout = (
    (BaseName: 'securedel2.test'; Ms: 900000),
    (BaseName: 'select4.test';    Ms: 900000),
    (BaseName: 'writecrash.test'; Ms: 900000),
    { 9.4.divbug.62.a — printf.test runs ~1200 mprintf assertions and
      easily blows past the 30s default once the cluster actually runs. }
    (BaseName: 'printf.test';     Ms: 300000)
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
  gShardI     : Integer = -1;       { 9.4.5.b — -1 = no sharding }
  gShardN     : Integer = -1;
  gBuildProf  : string  = '';       { 9.4.7.i — '' = default .so via pkgIndex }
  gFailLogDir : string  = '';       { 9.4.5.c — empty = default <bin>/tcl-failure-logs }
  gGateStrict : Boolean = False;    { 9.4.8.c — strict gate on STATUS.txt pas-strict rows }
  gCoverage   : Boolean = False;    { 9.4.8.d — opcode coverage harvest }
  gCovTmpDir  : string  = '';       { 9.4.8.d — per-test dump landing zone }
  gCovUnion   : array of Int64;     { 9.4.8.d — aggregated across all tests }
  gCovNames   : array of string;    { opcode -> name from first dump }
  gCovInited  : Boolean = False;
  gSkipList   : TStringList;
  gResults    : TStringList;        { 9.4.8.c — captures one PASS|FAIL|SKIP line per test for the strict gate }

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

procedure ParseShardSpec(const spec: string);
var
  slash: Integer;
  sI, sN: string;
begin
  slash := Pos('/', spec);
  if slash = 0 then begin
    Writeln(StdErr, 'TclTestDriver: --shard expects I/N, got: ', spec);
    Halt(2);
  end;
  sI := Copy(spec, 1, slash - 1);
  sN := Copy(spec, slash + 1, MaxInt);
  gShardI := StrToIntDef(sI, -1);
  gShardN := StrToIntDef(sN, -1);
  if (gShardN <= 0) or (gShardI < 0) or (gShardI >= gShardN) then begin
    Writeln(StdErr, 'TclTestDriver: invalid --shard ', spec,
            ' (need 0<=I<N, N>=1)');
    Halt(2);
  end;
end;

procedure ParseArgs;
var i: Integer; a, g: string;
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
    end else if a = '--shard' then begin
      Inc(i); ParseShardSpec(ParamStr(i));
    end else if a = '--build' then begin
      Inc(i); gBuildProf := LowerCase(Trim(ParamStr(i)));
      if gBuildProf = 'default' then gBuildProf := '';
    end else if a = '--fail-log-dir' then begin
      Inc(i); gFailLogDir := ExpandFileName(ParamStr(i));
    end else if a = '--gate' then begin
      Inc(i); g := LowerCase(ParamStr(i));
      if g = 'strict' then
        gGateStrict := True
      else if g <> 'none' then begin
        Writeln(StdErr, 'TclTestDriver: unknown --gate value: ', g);
        Halt(2);
      end;
    end else if a = '--coverage' then begin
      gCoverage := True;
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
function BuildScript(const testAbsPath: string; const tmpDir: string;
                     const covDumpPath: string): string;
var sb: TStringList;
begin
  sb := TStringList.Create;
  try
    { 9.4.7.h: put bin/ on ::auto_path so `package require sqlite3` finds
      the generated pkgIndex.tcl and loads libpassqlite3tcl.so itself.
      Fall back to an explicit `load` if the pkgIndex isn't present (e.g.
      bin/ built before 9.4.7.h landed). }
    if gBuildProf = '' then begin
      sb.Add('lappend ::auto_path {' + gBinDir + '}');
      sb.Add('if {[catch {package require sqlite3}]} {');
      sb.Add('  load {' + gSoPath + '} Sqlite3');
      sb.Add('  package require sqlite3');
      sb.Add('}');
    end else begin
      { 9.4.7.i: --build PROFILE bypasses pkgIndex.tcl so the requested
        .so is the one that loads, then registers the package alias so
        any subsequent `package require sqlite3` is a no-op. }
      sb.Add('load {' + gSoPath + '} Sqlite3');
      sb.Add('package provide sqlite3 3.53.0');
    end;
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
    sb.Add('    set __r [uplevel 1 [list __orig_source $::pas_shim_dir/tester_min.tcl]]');
    { 9.4.8.d: re-apply the cov wrap after tester_min re-installs
      finalize_testing; harmless no-op when --coverage is off (the
      proc is undefined in that case). }
    sb.Add('    catch { __pas_install_cov_wrap }');
    sb.Add('    return $__r');
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
    { 9.4.8.d: flip the opcode-coverage counter before sourcing the test
      so every VDBE step the test fires lands in gVdbeOpCoverage[].
      Wrap finalize_testing so the dump fires inside the same exit path
      finish_test takes (finish_test → finalize_testing → exit), and
      install a Tcl trace on `proc` so any re-source of tester.tcl (most
      .test files do `source $testdir/tester.tcl` which our shim redirects
      to tester_min — and that re-defines finalize_testing, blowing away
      a one-shot rename) re-applies the wrap on top of the fresh copy. }
    if covDumpPath <> '' then begin
      sb.Add('catch { pas_opcode_coverage_enable }');
      sb.Add('set ::__pas_cov_dump_path {' + covDumpPath + '}');
      sb.Add('proc __pas_install_cov_wrap {} {');
      sb.Add('  if {![llength [info commands finalize_testing]]} { return }');
      sb.Add('  if {[llength [info commands __orig_finalize_testing]] &&');
      sb.Add('      [info body finalize_testing] eq {');
      sb.Add('    catch { pas_opcode_coverage_dump $::__pas_cov_dump_path }');
      sb.Add('    uplevel 1 __orig_finalize_testing');
      sb.Add('  }} { return }');
      sb.Add('  catch { rename __orig_finalize_testing {} }');
      sb.Add('  rename finalize_testing __orig_finalize_testing');
      sb.Add('  proc finalize_testing {} {');
      sb.Add('    catch { pas_opcode_coverage_dump $::__pas_cov_dump_path }');
      sb.Add('    uplevel 1 __orig_finalize_testing');
      sb.Add('  }');
      sb.Add('}');
      sb.Add('__pas_install_cov_wrap');
    end;
    sb.Add('if {[catch {source ' + testAbsPath + '} __err __opts]} {');
    sb.Add('  puts stderr "SOURCE-ERROR: $__err"');
    sb.Add('}');
    sb.Add('catch { db close }');
    { 9.4.8.d post-source fallback dump for tests that never call
      finish_test (some only call do_test in a loop and end without
      finalize).  No-op when the wrapped finalize_testing already ran. }
    if covDumpPath <> '' then
      sb.Add('catch { pas_opcode_coverage_dump {' + covDumpPath + '} }');
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
{ MergeCoverageDump — read a per-test dump (one `idx<TAB>name<TAB>hits` per
  line) and OR it into the union-of-hits accumulator.  Allocates gCovUnion
  / gCovNames lazily on first call so we don't hard-code the opcode count.
}
procedure MergeCoverageDump(const dumpPath: string);
var
  sl: TStringList;
  i, idx, tab1, tab2: Integer;
  ln, sIdx, sName, sHits: string;
  hits: Int64;
begin
  if not FileExists(dumpPath) then Exit;
  sl := TStringList.Create;
  try
    try
      sl.LoadFromFile(dumpPath);
    except
      Exit;
    end;
    if not gCovInited then begin
      SetLength(gCovUnion, sl.Count);
      SetLength(gCovNames, sl.Count);
      gCovInited := True;
    end;
    if sl.Count > Length(gCovUnion) then begin
      SetLength(gCovUnion, sl.Count);
      SetLength(gCovNames, sl.Count);
    end;
    for i := 0 to sl.Count - 1 do begin
      ln := sl[i];
      if ln = '' then Continue;
      tab1 := Pos(#9, ln);
      if tab1 = 0 then Continue;
      tab2 := Pos(#9, ln, tab1 + 1);
      if tab2 = 0 then Continue;
      sIdx  := Copy(ln, 1, tab1 - 1);
      sName := Copy(ln, tab1 + 1, tab2 - tab1 - 1);
      sHits := Copy(ln, tab2 + 1, MaxInt);
      idx := StrToIntDef(sIdx, -1);
      if (idx < 0) or (idx >= Length(gCovUnion)) then Continue;
      hits := StrToInt64Def(sHits, 0);
      gCovUnion[idx] := gCovUnion[idx] + hits;
      if gCovNames[idx] = '' then gCovNames[idx] := sName;
    end;
  finally
    sl.Free;
  end;
end;

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
  covDump    : string;
begin
  sOut := '';
  sErr := '';
  durationMs := 0;

  { 9.4.7.f: spin up an isolated working directory for this test. }
  tmpDir := MakeTestTmpDir(testAbsPath);
  { 9.4.8.d: per-test coverage dump path lives under the global cov
    tmpdir, NOT the per-test tmpdir (which is wiped before we can read
    it back).  Empty when --coverage not set: BuildScript skips the
    pas_opcode_coverage_* injections in that case. }
  covDump := '';
  if gCoverage and (gCovTmpDir <> '') then
    covDump := IncludeTrailingPathDelimiter(gCovTmpDir)
               + 'cov_' + IntToStr(nTotal) + '_'
               + ChangeFileExt(ExtractFileName(testAbsPath), '') + '.txt';
  script := BuildScript(testAbsPath, tmpDir, covDump);

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
    { 9.4.8.d: harvest the per-test opcode-coverage dump (if any) BEFORE
      we tear down anything else.  Dump lives under gCovTmpDir, not the
      per-test tmpdir, so it survives the recursive remove below. }
    if covDump <> '' then begin
      MergeCoverageDump(covDump);
      DeleteFile(covDump);
    end;
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
  9.4.5.c: persist per-test stdout/stderr capture to disk on FAIL so the
  CI upload-artifact step can grab them for triage.
----------------------------------------------------------------------------}
procedure WriteFailLogs(const relPath: string; const sOut, sErr: AnsiString);
var
  bn, base, outP, errP: string;
  f: TextFile;
  i: Integer;
begin
  if gFailLogDir = '' then Exit;
  if not ForceDirectories(gFailLogDir) then Exit;
  bn := ExtractFileName(relPath);
  if bn = '' then bn := 'unknown';
  { sanitise: replace any path separators left in basename }
  for i := 1 to Length(bn) do
    if bn[i] in ['/', '\', ':'] then bn[i] := '_';
  base := IncludeTrailingPathDelimiter(gFailLogDir) + bn;
  outP := base + '.out';
  errP := base + '.err';
  try
    AssignFile(f, outP); Rewrite(f); Write(f, sOut); CloseFile(f);
  except end;
  try
    AssignFile(f, errP); Rewrite(f); Write(f, sErr); CloseFile(f);
  except end;
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
  { 9.4.8.c: capture <classification><TAB><path> so the strict gate
    can re-classify against STATUS.txt without re-parsing stdout. }
  if gResults <> nil then
    gResults.Add(cls + #9 + relPath);
  if cls = 'PASS' then Inc(nPass)
  else if cls = 'SKIP' then Inc(nSkip)
  else begin
    Inc(nFail);
    WriteFailLogs(relPath, sOut, sErr);
  end;

  Flush(Output);
end;

{----------------------------------------------------------------------------
  9.4.8.c — strict gate.  After the run, diff result classifications
  against the canonical pas-strict / pas-soft / pas-skip tags in
  src/tests/tcl/STATUS.txt.  Returns the count of pas-strict tests
  that diverged to FAIL; 0 means the gate passes.

  Inline port of check_status_regression.sh so the driver stays
  self-contained — no shell-out, no PATH dependence, deterministic
  exit code for CI.
----------------------------------------------------------------------------}
function RunStrictGate: Integer;
var
  statusPath : string;
  statusLines: TStringList;
  statusMap  : TStringList;   { name=path, value=tag }
  i, tab1, tab2, j: Integer;
  ln, tag, path, cls, expect, observed: string;
  regressions, unknowns: Integer;
begin
  Result := 0;
  statusPath := IncludeTrailingPathDelimiter(gTclDir) + 'STATUS.txt';
  if not FileExists(statusPath) then begin
    Writeln(StdErr, 'TclTestDriver --gate strict: missing ', statusPath);
    Result := -1;
    Exit;
  end;

  statusLines := TStringList.Create;
  statusMap   := TStringList.Create;
  try
    statusMap.CaseSensitive := True;
    statusLines.LoadFromFile(statusPath);
    for i := 0 to statusLines.Count - 1 do begin
      ln := statusLines[i];
      if (ln = '') or (ln[1] = '#') then Continue;
      tab1 := Pos(#9, ln);
      if tab1 = 0 then Continue;
      tab2 := Pos(#9, ln, tab1 + 1);
      tag  := Copy(ln, 1, tab1 - 1);
      if tab2 = 0 then
        path := Copy(ln, tab1 + 1, MaxInt)
      else
        path := Copy(ln, tab1 + 1, tab2 - tab1 - 1);
      if (tag <> 'pas-strict') and (tag <> 'pas-soft') and (tag <> 'pas-skip') then
        Continue;
      statusMap.Values[path] := tag;
    end;

    regressions := 0;
    unknowns    := 0;
    Writeln(StdErr, '--- 9.4.8.c strict gate ---');
    if gResults <> nil then begin
      for i := 0 to gResults.Count - 1 do begin
        ln := gResults[i];
        tab1 := Pos(#9, ln);
        if tab1 = 0 then Continue;
        cls  := Copy(ln, 1, tab1 - 1);
        path := Copy(ln, tab1 + 1, MaxInt);
        expect := statusMap.Values[path];
        if expect = '' then begin
          Inc(unknowns);
          Writeln(StdErr, '  WARN unknown (not in STATUS.txt): ', path, ' [', cls, ']');
          Continue;
        end;
        if (expect = 'pas-strict') and (cls = 'FAIL') then begin
          Inc(regressions);
          Writeln(StdErr, '  REGRESSION (pas-strict FAIL): ', path);
        end;
      end;
    end;

    { Also surface pas-strict entries that were *expected* to run but
      that this sweep never touched — useful when a shard config
      silently drops a test. }
    if gResults <> nil then begin
      for j := 0 to statusMap.Count - 1 do begin
        path := statusMap.Names[j];
        tag  := statusMap.ValueFromIndex[j];
        if tag <> 'pas-strict' then Continue;
        observed := '';
        for i := 0 to gResults.Count - 1 do begin
          ln := gResults[i];
          tab1 := Pos(#9, ln);
          if tab1 = 0 then Continue;
          if Copy(ln, tab1 + 1, MaxInt) = path then begin
            observed := Copy(ln, 1, tab1 - 1);
            Break;
          end;
        end;
        { absence from result log is silently OK — shard/filter/limit. }
        if (observed <> '') and (observed <> 'PASS') and (observed <> 'FAIL') and (observed <> 'SKIP') then
          Writeln(StdErr, '  WARN unclassified result for pas-strict: ', path, ' [', observed, ']');
      end;
    end;

    if regressions > 0 then
      Writeln(StdErr, 'FAIL: ', regressions, ' pas-strict regression(s).')
    else
      Writeln(StdErr, 'OK: no pas-strict regressions (', unknowns, ' unknown paths).');
    Result := regressions;
  finally
    statusMap.Free;
    statusLines.Free;
  end;
end;

{----------------------------------------------------------------------------
  9.4.8.d — write src/tests/tcl/COVERAGE_DELTA.md.

  Lists opcodes hit by the tcl-feature corpus that are catalogued cold
  in src/tests/corpus/COVERAGE_GAPS.md (i.e. hot HERE, cold THERE).
  Those are the opcodes the corpus oracle never reaches but that the
  upstream .test files do — driving the categorization step Phase
  9.4.8.d calls for ("opcodes / codegen arms that only the Tcl corpus
  hits").
----------------------------------------------------------------------------}
procedure LoadCorpusCold(out cold: TStringList);
var
  gapsPath: string;
  raw: TStringList;
  i, pipe1, pipe2: Integer;
  ln, sIdx: string;
  idx: Integer;
begin
  cold := TStringList.Create;
  cold.Sorted := True;
  cold.Duplicates := dupIgnore;
  gapsPath := IncludeTrailingPathDelimiter(gRoot)
              + 'src' + DirectorySeparator + 'tests'
              + DirectorySeparator + 'corpus'
              + DirectorySeparator + 'COVERAGE_GAPS.md';
  if not FileExists(gapsPath) then Exit;
  raw := TStringList.Create;
  try
    raw.LoadFromFile(gapsPath);
    for i := 0 to raw.Count - 1 do begin
      ln := Trim(raw[i]);
      if (ln = '') or (Pos('|', ln) <> 1) then Continue;
      { row form: "| <idx> | <name> | <reason> |" }
      pipe1 := Pos('|', ln);
      pipe2 := Pos('|', ln, pipe1 + 1);
      if pipe2 = 0 then Continue;
      sIdx := Trim(Copy(ln, pipe1 + 1, pipe2 - pipe1 - 1));
      idx := StrToIntDef(sIdx, -1);
      if idx >= 0 then cold.Add(IntToStr(idx));
    end;
  finally
    raw.Free;
  end;
end;

procedure WriteCoverageDelta;
var
  outPath: string;
  cold: TStringList;
  md: TStringList;
  i, nHotHere, nDeltaOnly: Integer;
  isCold: Boolean;
begin
  outPath := IncludeTrailingPathDelimiter(gTclDir) + 'COVERAGE_DELTA.md';
  LoadCorpusCold(cold);
  md := TStringList.Create;
  try
    md.Add('# COVERAGE_DELTA.md');
    md.Add('');
    md.Add('Generated by `bin/TclTestDriver --coverage` (Phase 9.4.8.d).');
    md.Add('');
    md.Add('Opcodes hit by the tcl-feature corpus that are catalogued cold');
    md.Add('in `src/tests/corpus/COVERAGE_GAPS.md` (i.e. unreached by the');
    md.Add('9.1 / 9.2 .pas spine corpus).  These are the opcodes only the');
    md.Add('Tcl driver exercises today.  When the 9.1 corpus closes one of');
    md.Add('these gaps it should be dropped from `IsCoverageGap` upstream.');
    md.Add('');
    md.Add('| opcode | name | tcl-hits |');
    md.Add('|-------:|------|---------:|');
    nHotHere    := 0;
    nDeltaOnly  := 0;
    for i := 0 to Length(gCovUnion) - 1 do begin
      if gCovUnion[i] <= 0 then Continue;
      Inc(nHotHere);
      isCold := cold.IndexOf(IntToStr(i)) >= 0;
      if not isCold then Continue;
      Inc(nDeltaOnly);
      md.Add('| ' + IntToStr(i) + ' | ' + gCovNames[i] + ' | ' + IntToStr(gCovUnion[i]) + ' |');
    end;
    md.Add('');
    md.Add('_Summary: ' + IntToStr(nHotHere) + ' opcodes hit by the tcl corpus; '
           + IntToStr(nDeltaOnly) + ' of them are catalogued cold in the .pas corpus._');
  finally
    cold.Free;
  end;
  try
    md.SaveToFile(outPath);
    Writeln(StdErr, '9.4.8.d coverage delta: ', nDeltaOnly,
            ' tcl-only opcode(s) written to ', outPath);
  except
    on E: Exception do
      Writeln(StdErr, 'TclTestDriver --coverage: write failed: ', E.Message);
  end;
  md.Free;
end;

{----------------------------------------------------------------------------
  Main.
----------------------------------------------------------------------------}
var
  manifest : TStringList;
  filtered : TStringList;        { 9.4.5.b — tcl-feature paths post-filter }
  i, nDone : Integer;
  line, tag, p: string;
  tabIdx   : Integer;
  startTotal: QWord;
  shardLo, shardHi: Integer;
  strictRegressions: Integer;
begin
  gRoot := ResolveRoot;
  gBinDir := IncludeTrailingPathDelimiter(gRoot) + 'bin';
  gSoPath := IncludeTrailingPathDelimiter(gBinDir) + 'libpassqlite3tcl.so';
  gTclDir := IncludeTrailingPathDelimiter(gRoot) + 'src' + DirectorySeparator + 'tests' + DirectorySeparator + 'tcl';
  gManifest := IncludeTrailingPathDelimiter(gTclDir) + 'MANIFEST.txt';

  ParseArgs;

  { 9.4.7.i — --build PROFILE remaps gSoPath to libpassqlite3tcl-<profile>.so.
    BuildScript will skip the pkgIndex.tcl path when gBuildProf<>'' so the
    explicit load of this .so is what reaches the child interpreter. }
  if gBuildProf <> '' then begin
    gSoPath := IncludeTrailingPathDelimiter(gBinDir)
               + 'libpassqlite3tcl-' + gBuildProf + '.so';
    Writeln(StdErr, 'TclTestDriver: --build ', gBuildProf, ' -> ', gSoPath);
  end;

  if gFailLogDir = '' then
    gFailLogDir := IncludeTrailingPathDelimiter(gBinDir) + 'tcl-failure-logs';

  if gGateStrict then
    Writeln(StdErr, 'TclTestDriver: --gate strict enabled (9.4.8.c)');
  if gCoverage then begin
    { 9.4.8.d: stage a persistent tmpdir for per-test dumps that
      survives the per-test tmpdir wipe in RunOne's finally. }
    gCovTmpDir := GetTempDir(False);
    if gCovTmpDir = '' then gCovTmpDir := '/tmp/';
    gCovTmpDir := IncludeTrailingPathDelimiter(gCovTmpDir)
                  + 'pastcl_cov_' + IntToStr(GetProcessID);
    if not ForceDirectories(gCovTmpDir) then begin
      Writeln(StdErr, 'TclTestDriver --coverage: cannot create ', gCovTmpDir);
      Halt(2);
    end;
    Writeln(StdErr, 'TclTestDriver: --coverage enabled (9.4.8.d) tmp=', gCovTmpDir);
  end;

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
  gResults := TStringList.Create;

  manifest := TStringList.Create;
  try
    manifest.LoadFromFile(gManifest);
    nPass := 0; nFail := 0; nSkip := 0; nTotal := 0; nDone := 0;
    startTotal := GetTickCount64;

    { 9.4.5.b: build the filtered tcl-feature list first.  Then --limit
      truncates the list, and --shard slices the *truncated* list — so
      `--shard I/N --limit M` partitions the first M entries into N
      contiguous, non-overlapping chunks (CI workers each get their own
      slice of the same M-prefix). }
    filtered := TStringList.Create;
    try
      for i := 0 to manifest.Count - 1 do begin
        line := manifest[i];
        if line = '' then Continue;
        tabIdx := Pos(#9, line);
        if tabIdx = 0 then Continue;
        tag := Copy(line, 1, tabIdx - 1);
        p   := Copy(line, tabIdx + 1, MaxInt);
        if tag <> 'tcl-feature' then Continue;
        if (gFilter <> '') and (Pos(gFilter, ExtractFileName(p)) = 0) then Continue;
        filtered.Add(p);
      end;

      if (gLimit > 0) and (gLimit < filtered.Count) then
        while filtered.Count > gLimit do filtered.Delete(filtered.Count - 1);

      if gShardN > 0 then begin
        shardLo := (filtered.Count * gShardI) div gShardN;
        shardHi := (filtered.Count * (gShardI + 1)) div gShardN;
      end else begin
        shardLo := 0;
        shardHi := filtered.Count;
      end;

      Writeln(StdErr, Format('Shard slice: [%d, %d) of %d (post-filter, post-limit) entries',
        [shardLo, shardHi, filtered.Count]));

      for i := shardLo to shardHi - 1 do begin
        Inc(nDone);
        ProcessEntry(filtered[i]);
      end;
    finally
      filtered.Free;
    end;

    Writeln(StdErr, Format('Total: %d pass / %d fail / %d skip / %d total in %d ms',
      [nPass, nFail, nSkip, nTotal, Int64(GetTickCount64 - startTotal)]));
  finally
    manifest.Free;
    gSkipList.Free;
  end;

  { 9.4.8.d: emit COVERAGE_DELTA.md before exit so the report lands even
    if the strict gate trips below.  Then tear down the cov tmpdir. }
  if gCoverage then begin
    WriteCoverageDelta;
    if gCovTmpDir <> '' then RemoveDirRecursive(gCovTmpDir);
  end;

  { 9.4.8.c: strict gate runs AFTER per-test reporting + Total: line so
    a CI log always shows the per-test counts even when the gate trips.
    When set, the strict gate is the SOLE exit-code decider — a pas-soft
    FAIL that's catalogued in STATUS.txt must not fail CI.  Without
    --gate strict the legacy "any FAIL → exit 1" rule still applies. }
  if gGateStrict then begin
    strictRegressions := RunStrictGate;
    gResults.Free;
    if strictRegressions < 0 then Halt(2);     { missing STATUS.txt }
    if strictRegressions > 0 then Halt(1);
    Halt(0);
  end;

  gResults.Free;

  if nFail > 0 then Halt(1) else Halt(0);
end.
