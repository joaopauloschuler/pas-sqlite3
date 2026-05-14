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

var
  gRoot       : string;        { absolute pas-sqlite3 root }
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
  s := ExpandFileName(ParamStr(0));
  { strip /bin/TclTestDriver -> root }
  Result := ExtractFileDir(ExtractFileDir(s));
  if Result = '' then Result := GetCurrentDir;
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
----------------------------------------------------------------------------}
function BuildScript(const testAbsPath: string): string;
var sb: TStringList;
begin
  sb := TStringList.Create;
  try
    sb.Add('load ' + gSoPath + ' Sqlite3');
    sb.Add('package require sqlite3');
    sb.Add('set ::testdir ' + gTclDir);
    sb.Add('source $::testdir/tester_min.tcl');
    { 9.4.4.a: monkey-patch [source] so upstream .test files that begin with
      `source $testdir/tester.tcl` transparently re-route to our tester_min
      shim.  Without this, every upstream .test fails at the first line. }
    sb.Add('set ::pas_shim_dir ' + gTclDir);
    sb.Add('rename source __orig_source');
    sb.Add('proc source {path args} {');
    sb.Add('  set tail [file tail $path]');
    sb.Add('  if {$tail eq "tester.tcl"} {');
    sb.Add('    return [uplevel 1 [list __orig_source $::pas_shim_dir/tester_min.tcl]]');
    sb.Add('  }');
    sb.Add('  return [uplevel 1 __orig_source [list $path] $args]');
    sb.Add('}');
    sb.Add('sqlite3 db :memory:');
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
  cwd        : string;
begin
  sOut := '';
  sErr := '';
  durationMs := 0;
  script := BuildScript(testAbsPath);

  p := TProcess.Create(nil);
  try
    p.Executable := '/usr/bin/tclsh';
    { read script from stdin (single dash) }
    p.Parameters.Add('-');
    cwd := ExtractFileDir(testAbsPath);
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

    { feed script then close stdin }
    SetLength(scriptBytes, Length(script));
    if Length(script) > 0 then
      Move(script[1], scriptBytes[0], Length(script));
    if Length(scriptBytes) > 0 then
      p.Input.Write(scriptBytes[0], Length(scriptBytes));
    p.CloseInput;

    while p.Running do begin
      AppendChunk(p.Output, sOut);
      AppendChunk(p.Stderr, sErr);
      if (GetTickCount64 - startTick) > PER_TEST_TIMEOUT_MS then begin
        Writeln(StdErr, 'timeout: ', testAbsPath);
        p.Terminate(124);
        durationMs := PER_TEST_TIMEOUT_MS;
        Result := -2;
        Exit;
      end;
      Sleep(10);
    end;
    { final drain }
    AppendChunk(p.Output, sOut);
    AppendChunk(p.Stderr, sErr);

    durationMs := Int64(GetTickCount64 - startTick);
    Result := p.ExitStatus;
  finally
    p.Free;
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
  absPath := relPath;
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
  gSoPath := IncludeTrailingPathDelimiter(gRoot) + 'bin' + DirectorySeparator + 'libpassqlite3tcl.so';
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
