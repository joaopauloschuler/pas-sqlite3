{
  SPDX-License-Identifier: blessing

  The author disclaims copyright to this source code.  In place of
  a legal notice, here is a blessing:

     May you do good and not evil.
     May you find forgiveness for yourself and forgive others.
     May you share freely, never taking more than you give.

  ------------------------------------------------------------------------

  This work is dedicated to all human kind, and also to all non-human kinds.
}
{$I ../../passqlite3.inc}
{
  afl-driver.pas — Phase 13.1 AFL wrapper around the 9.3.1 in-process
  differential harness (TestFuzzDiff).

  Contract with afl-fuzz:
      * Read the test input from stdin to EOF (AFL feeds one input per
        fork via stdin when @@ is omitted from the target command).
      * Persist it to a tmp file in /tmp (the differential harness is
        path-driven — see TestFuzzDiff header).
      * Spawn bin/TestFuzzDiff <tmpfile> and propagate its exit status.
      * On Pascal-side SIGSEGV inside TestFuzzDiff the child dies with
        signal; we re-raise the same signal in the driver so AFL marks
        the input as a crash (this is what AFL hunts for).
      * Otherwise:
          rc=0     PASS (byte-identical output across C/Pas oracles)
          rc=2     divergence detected — AFL counts as "interesting"
                   thanks to the unique exit code surfacing through
                   the bitmap path.
          rc=1/3   I/O or malformed-frame error — bubble through.

  Why a separate driver rather than embedding the harness?  Keeping the
  harness as-is means Phase 9.3.1's one-shot CLI semantics are preserved
  for non-AFL callers (regression runs, manual triage), and the AFL
  driver picks up future TestFuzzDiff changes for free.

  This file is the wrappee — see build-afl.sh for instrumentation
  routing and README.md for the chosen route.
}
program afl_driver;

uses
  SysUtils, BaseUnix, Unix, Classes;

const
  TMP_PREFIX = '/tmp/afl-pas-sqlite3-input-';
  HARNESS_NAME = 'TestFuzzDiff';

function FindHarness: AnsiString;
var
  selfDir, candidate, envOverride: AnsiString;
begin
  { Allow override for in-place runs from arbitrary cwd. }
  envOverride := GetEnvironmentVariable('PAS_FUZZDIFF_BIN');
  if (envOverride <> '') and FileExists(envOverride) then
  begin
    Result := envOverride;
    Exit;
  end;
  { afl-driver and TestFuzzDiff both land in bin/ — first try a
    sibling lookup. }
  selfDir := ExtractFilePath(ExpandFileName(ParamStr(0)));
  if selfDir = '' then selfDir := './';
  candidate := selfDir + HARNESS_NAME;
  if FileExists(candidate) then
  begin
    Result := candidate;
    Exit;
  end;
  { Then ../bin/ in case afl-driver was relocated. }
  candidate := selfDir + '../bin/' + HARNESS_NAME;
  if FileExists(candidate) then
  begin
    Result := ExpandFileName(candidate);
    Exit;
  end;
  { Final fallback: bare name → execvp-equivalent fails here because we
    use FpExecv (no PATH search); operator must set PAS_FUZZDIFF_BIN. }
  Result := HARNESS_NAME;
end;

function SlurpStdin: AnsiString;
var
  buf: array[0..65535] of Byte;
  n, total: SizeInt;
  ms: TMemoryStream;
begin
  ms := TMemoryStream.Create;
  try
    total := 0;
    repeat
      n := FpRead(StdInputHandle, buf, SizeOf(buf));
      if n > 0 then
      begin
        ms.WriteBuffer(buf, n);
        Inc(total, n);
      end;
    until n <= 0;
    SetLength(Result, total);
    if total > 0 then
    begin
      ms.Position := 0;
      ms.ReadBuffer(Result[1], total);
    end;
  finally
    ms.Free;
  end;
end;

function MakeTmpFile(const payload: AnsiString): AnsiString;
var
  candidate: AnsiString;
  fd, attempt: LongInt;
  pid: TPid;
begin
  { Roll our own mkstemp-equivalent — older FPC RTLs don't export
    FpMkstemp.  O_EXCL guarantees no race with a concurrent driver. }
  pid := FpGetPid;
  for attempt := 0 to 999 do
  begin
    candidate := Format('%s%d-%d-%d', [TMP_PREFIX, pid, GetProcessId, attempt]);
    fd := FpOpen(candidate, O_WRONLY or O_CREAT or O_EXCL, &600);
    if fd >= 0 then
    begin
      if Length(payload) > 0 then
        FpWrite(fd, payload[1], Length(payload));
      FpClose(fd);
      Result := candidate;
      Exit;
    end;
  end;
  Writeln(StdErr, 'afl-driver: could not create tmp file under ', TMP_PREFIX);
  Halt(1);
end;

function RunHarness(const harness, inputPath: AnsiString; out childRc: LongInt): Boolean;
var
  pid: TPid;
  status: LongInt;
  args: array[0..2] of PChar;
  hC, inC: PAnsiChar;
begin
  hC  := PAnsiChar(harness);
  inC := PAnsiChar(inputPath);
  pid := FpFork;
  if pid < 0 then
  begin
    Writeln(StdErr, 'afl-driver: fork failed');
    childRc := 1;
    Result := False;
    Exit;
  end;
  if pid = 0 then
  begin
    args[0] := hC;
    args[1] := inC;
    args[2] := nil;
    FpExecv(hC, @args[0]);
    { execv only returns on failure. }
    Writeln(StdErr, 'afl-driver: exec ', harness, ' failed: ', fpgeterrno);
    Halt(127);
  end;
  FpWaitPid(pid, status, 0);
  if wifsignaled(status) then
  begin
    { Child died on signal — re-raise so AFL classifies as a crash. }
    childRc := 128 + wtermsig(status);
    Result := False;
    Exit;
  end;
  childRc := wexitstatus(status);
  Result := True;
end;

var
  payload, tmpFile, harness: AnsiString;
  rc: LongInt;
  ok: Boolean;
begin
  harness := FindHarness;
  payload := SlurpStdin;
  tmpFile := MakeTmpFile(payload);
  try
    ok := RunHarness(harness, tmpFile, rc);
  finally
    { Best-effort cleanup — AFL will spam these; leaving stragglers
      around fills /tmp during a soak. }
    if FileExists(tmpFile) then
      DeleteFile(tmpFile);
  end;
  if not ok then
  begin
    { Propagate the death-by-signal as a non-zero exit; AFL inspects
      the child's wait status when persistent-mode is off, so any rc
      >= 128 is fine.  We do NOT re-kill the driver because that
      would lose the cleanup above. }
    Halt(rc);
  end;
  Halt(rc);
end.
