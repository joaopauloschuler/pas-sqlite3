{$mode objfpc}
{$H+}
program SpeedtestDiff;
{
  Phase 11.6 — Differential driver: pas vs C oracle.

  Runs two speedtest1 binaries with the *same* CLI args, captures stdout +
  stderr, strips wall-clock fields (same regex as bench/check_harness.sh),
  diffs the stripped output, and emits a side-by-side ratio table from the
  *un-stripped* per-test timings.

  Two binaries:
    * pas engine : bin/passpeedtest1            (this tree)
    * C oracle   : ../sqlite3/speedtest1        (upstream C build)

  Build the C oracle first:
    cd ../sqlite3
    gcc -O2 -o speedtest1 test/speedtest1.c -I. -L. -l:libsqlite3.a \
        -lpthread -lm -ldl

  Output gate:
    * stripped diff non-empty  → "CORRECTNESS DIVERGENCE" + exit 1
    * stripped diff empty      → "CORRECTNESS PASS" + ratio table + exit 0

  C citations:
    speedtest1.c:472..492  speedtest1_final TOTAL line
    speedtest1.c:413..469  begin_test/end_test per-case wall-clock format
}

uses
  SysUtils, Classes, Process, pipes;

const
  STRIP_REGEX_LINE_VERSION = '-- Speedtest1 for SQLite';
  CHUNK = 8192;

var
  ArgPasBin   : AnsiString = '';
  ArgCBin     : AnsiString = '';
  ArgLibDir   : AnsiString = '';
  ArgDbPath   : AnsiString = '';
  ArgKeepTmp  : Boolean = False;
  PassThru    : array of AnsiString;

{----------------------------------------------------------------------------
  AppendChunk — drain a pipe into an AnsiString.
  Same shape as src/tests/TclTestDriver.pas:234.
----------------------------------------------------------------------------}
procedure AppendChunk(stream: TInputPipeStream; var s: AnsiString);
var
  buf : array[0..CHUNK-1] of Byte;
  n   : LongInt;
  old : Integer;
begin
  while stream.NumBytesAvailable > 0 do
  begin
    n := stream.Read(buf, CHUNK);
    if n <= 0 then Break;
    old := Length(s);
    SetLength(s, old + n);
    Move(buf[0], s[old + 1], n);
  end;
end;

procedure DrainAll(p: TProcess; var sOut, sErr: AnsiString);
begin
  while p.Running do
  begin
    AppendChunk(p.Output, sOut);
    AppendChunk(p.Stderr, sErr);
    Sleep(5);
  end;
  AppendChunk(p.Output, sOut);
  AppendChunk(p.Stderr, sErr);
end;

{----------------------------------------------------------------------------
  RunBinary — spawn binary with given args, env LD_LIBRARY_PATH if set.
----------------------------------------------------------------------------}
function RunBinary(const exe: AnsiString;
                   const args: array of AnsiString;
                   const libDir: AnsiString;
                   var sOut, sErr: AnsiString;
                   var elapsedMs: Int64): Integer;
var
  p   : TProcess;
  i   : Integer;
  t0  : QWord;
begin
  sOut := '';
  sErr := '';
  elapsedMs := 0;
  Result := -1;
  p := TProcess.Create(nil);
  try
    p.Executable := exe;
    for i := 0 to High(args) do p.Parameters.Add(args[i]);
    p.Options := [poUsePipes];
    p.ShowWindow := swoHIDE;
    if libDir <> '' then
      p.Environment.Add('LD_LIBRARY_PATH=' + libDir);
    { Inherit the rest of the env. TProcess only inherits when Environment
      is empty; once we add one entry we must populate the lot. }
    if libDir <> '' then
    begin
      for i := 0 to GetEnvironmentVariableCount - 1 do
      begin
        if Pos('LD_LIBRARY_PATH=', GetEnvironmentString(i)) <> 1 then
          p.Environment.Add(GetEnvironmentString(i));
      end;
    end;
    t0 := GetTickCount64;
    try
      p.Execute;
    except
      on E: Exception do
      begin
        Writeln(StdErr, 'SpeedtestDiff: spawn ', exe, ' failed: ', E.Message);
        Exit;
      end;
    end;
    DrainAll(p, sOut, sErr);
    elapsedMs := Int64(GetTickCount64 - t0);
    Result := p.ExitStatus;
  finally
    p.Free;
  end;
end;

{----------------------------------------------------------------------------
  StripVolatile — apply the same regex as bench/check_harness.sh:
    * delete leading "-- Speedtest1 for SQLite ..." banner
    * collapse "<spaces><digits>.<digits>s" runs to "  TIME"
  Done line-by-line in pure Pascal (no regex dep).
----------------------------------------------------------------------------}
function StripTimeToken(const line: AnsiString): AnsiString;
{ Replace runs of ' '+ digits '.' digits 's' with '  TIME'. }
var
  i, j, k : Integer;
  c       : AnsiChar;
  ws      : Integer;
  hasDigit: Boolean;
  digits1, digits2: Integer;
begin
  Result := '';
  i := 1;
  while i <= Length(line) do
  begin
    if line[i] = ' ' then
    begin
      { count whitespace }
      j := i;
      ws := 0;
      while (j <= Length(line)) and (line[j] = ' ') do
      begin
        Inc(ws);
        Inc(j);
      end;
      if ws >= 1 then
      begin
        { try to match digits.digits's' }
        k := j;
        digits1 := 0;
        while (k <= Length(line)) and (line[k] >= '0') and (line[k] <= '9') do
        begin
          Inc(digits1);
          Inc(k);
        end;
        if (digits1 > 0) and (k <= Length(line)) and (line[k] = '.') then
        begin
          Inc(k);
          digits2 := 0;
          while (k <= Length(line)) and (line[k] >= '0') and (line[k] <= '9') do
          begin
            Inc(digits2);
            Inc(k);
          end;
          if (digits2 > 0) and (k <= Length(line)) and (line[k] = 's') then
          begin
            { match! emit "  TIME" and advance past the 's' }
            Result := Result + '  TIME';
            i := k + 1;
            hasDigit := True; { suppress warning }
            if hasDigit then ;
            Continue;
          end;
        end;
      end;
      { not a time token — emit one space at a time }
      Result := Result + line[i];
      Inc(i);
    end
    else
    begin
      Result := Result + line[i];
      Inc(i);
    end;
  end;
  c := #0; if c = #0 then ;
end;

function StripVolatile(const s: AnsiString): AnsiString;
var
  lines : TStringList;
  i     : Integer;
  ln    : AnsiString;
begin
  Result := '';
  lines := TStringList.Create;
  try
    lines.Text := s;
    for i := 0 to lines.Count - 1 do
    begin
      ln := lines[i];
      if Pos(STRIP_REGEX_LINE_VERSION, ln) = 1 then Continue;
      Result := Result + StripTimeToken(ln) + LineEnding;
    end;
  finally
    lines.Free;
  end;
end;

{----------------------------------------------------------------------------
  ParseTimings — extract (caseId, label, seconds) per non-banner line that
  matches the speedtest1 per-case output:
       NNN - <label>........... DDD.DDDs
  Also captures the closing "       TOTAL .... DDD.DDDs" line under caseId=0.
----------------------------------------------------------------------------}
type
  TTiming = record
    CaseId : Integer;
    Label_ : AnsiString;
    Seconds: Double;
  end;
  TTimingArr = array of TTiming;

function ExtractTrailingSeconds(const ln: AnsiString; out secs: Double): Boolean;
var
  k, start : Integer;
  numStr   : AnsiString;
  fs       : TFormatSettings;
begin
  Result := False;
  k := Length(ln);
  if (k < 3) or (ln[k] <> 's') then Exit;
  Dec(k);
  start := k;
  while (start >= 1) and (((ln[start] >= '0') and (ln[start] <= '9')) or (ln[start] = '.')) do
    Dec(start);
  if start = k then Exit;
  numStr := Copy(ln, start + 1, k - start);
  fs := DefaultFormatSettings;
  fs.DecimalSeparator := '.';
  Result := TryStrToFloat(numStr, secs, fs);
end;

function ParseTimings(const s: AnsiString): TTimingArr;
var
  lines : TStringList;
  i, j  : Integer;
  ln, lab : AnsiString;
  caseId  : Integer;
  secs    : Double;
  t       : TTiming;
begin
  Result := nil;
  lines := TStringList.Create;
  try
    lines.Text := s;
    for i := 0 to lines.Count - 1 do
    begin
      ln := lines[i];
      if not ExtractTrailingSeconds(ln, secs) then Continue;
      { per-case line begins with " NNN - ..." }
      j := 1;
      while (j <= Length(ln)) and (ln[j] = ' ') do Inc(j);
      caseId := 0;
      if (j <= Length(ln)) and (ln[j] >= '0') and (ln[j] <= '9') then
      begin
        caseId := 0;
        while (j <= Length(ln)) and (ln[j] >= '0') and (ln[j] <= '9') do
        begin
          caseId := caseId * 10 + Ord(ln[j]) - Ord('0');
          Inc(j);
        end;
        { skip ' - ' }
        if (j <= Length(ln)-2) and (ln[j] = ' ') and (ln[j+1] = '-') then
        begin
          Inc(j, 3);
          lab := '';
          while (j <= Length(ln)) and (ln[j] <> '.') do
          begin
            lab := lab + ln[j];
            Inc(j);
          end;
          lab := Trim(lab);
        end
        else lab := '';
      end
      else if Pos('TOTAL', ln) > 0 then
      begin
        caseId := 0;
        lab := 'TOTAL';
      end
      else
        Continue;
      t.CaseId := caseId;
      t.Label_ := lab;
      t.Seconds := secs;
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := t;
    end;
  finally
    lines.Free;
  end;
end;

{----------------------------------------------------------------------------
  PrintRatioTable — side-by-side pas vs C with ratio (pas/C).
----------------------------------------------------------------------------}
procedure PrintRatioTable(const pasT, cT: TTimingArr);
var
  i, j     : Integer;
  ratio    : Double;
  ratioStr : AnsiString;
  totPas, totC : Double;
  pasSeen  : Boolean;
begin
  Writeln;
  Writeln('=== Per-case timings (seconds) ===');
  Writeln(Format('%-5s  %-58s  %8s  %8s  %8s',
                 ['case', 'label', 'pas', 'C', 'pas/C']));
  Writeln(StringOfChar('-', 99));
  totPas := 0;
  totC   := 0;
  for i := 0 to High(cT) do
  begin
    { locate matching pas case }
    pasSeen := False;
    ratio := 0;
    for j := 0 to High(pasT) do
      if (pasT[j].CaseId = cT[i].CaseId) and (pasT[j].Label_ = cT[i].Label_) then
      begin
        pasSeen := True;
        if cT[i].Seconds > 0 then ratio := pasT[j].Seconds / cT[i].Seconds
        else ratio := 0;
        if cT[i].CaseId <> 0 then
        begin
          totPas := totPas + pasT[j].Seconds;
          totC   := totC + cT[i].Seconds;
        end;
        Break;
      end;
    if pasSeen then
    begin
      if ratio > 0 then ratioStr := Format('%8.2fx', [ratio])
      else ratioStr := '     n/a';
      Writeln(Format('%5d  %-58s  %8.3f  %8.3f  %s',
                     [cT[i].CaseId,
                      Copy(cT[i].Label_, 1, 58),
                      pasT[j].Seconds,
                      cT[i].Seconds,
                      ratioStr]));
    end
    else
      Writeln(Format('%5d  %-58s  %8s  %8.3f  %8s',
                     [cT[i].CaseId,
                      Copy(cT[i].Label_, 1, 58),
                      'missing', cT[i].Seconds, '-']));
  end;
  Writeln(StringOfChar('-', 99));
  if totC > 0 then
    Writeln(Format('%-5s  %-58s  %8.3f  %8.3f  %8.2fx',
                   ['', 'SUMMED PER-CASE', totPas, totC, totPas / totC]))
  else
    Writeln('(no C totals to compute ratio)');
end;

{----------------------------------------------------------------------------
  ParseArgs — own args, then everything we don't consume is passed through
  to both speedtest1 invocations.
----------------------------------------------------------------------------}
procedure ParseArgs;
var
  i : Integer;
  a : AnsiString;
begin
  SetLength(PassThru, 0);
  i := 1;
  while i <= ParamCount do
  begin
    a := ParamStr(i);
    if a = '--pas-bin' then
    begin
      Inc(i); ArgPasBin := ParamStr(i);
    end
    else if a = '--c-bin' then
    begin
      Inc(i); ArgCBin := ParamStr(i);
    end
    else if a = '--lib-dir' then
    begin
      Inc(i); ArgLibDir := ParamStr(i);
    end
    else if a = '--db-path' then
    begin
      Inc(i); ArgDbPath := ParamStr(i);
    end
    else if a = '--keep-tmp' then
      ArgKeepTmp := True
    else if (a = '-h') or (a = '--help') then
    begin
      Writeln('SpeedtestDiff — pas vs C speedtest1 differential driver.');
      Writeln;
      Writeln('Usage: SpeedtestDiff [options] [-- speedtest1-args ...]');
      Writeln('  --pas-bin PATH    pas engine binary (default bin/passpeedtest1)');
      Writeln('  --c-bin   PATH    C oracle binary  (default ../sqlite3/speedtest1)');
      Writeln('  --lib-dir DIR     LD_LIBRARY_PATH for pas binary (default src/)');
      Writeln('  --db-path PATH    db path passed to both runs (default tmpdir)');
      Writeln('  --keep-tmp        do not remove tmpdir on exit');
      Writeln('  --                end of own args; remainder forwarded to both runs');
      Writeln;
      Writeln('Examples:');
      Writeln('  SpeedtestDiff --testset main --size 1');
      Writeln('  SpeedtestDiff --testset cte  --size 5');
      Halt(0);
    end
    else if a = '--' then
    begin
      Inc(i);
      while i <= ParamCount do
      begin
        SetLength(PassThru, Length(PassThru) + 1);
        PassThru[High(PassThru)] := ParamStr(i);
        Inc(i);
      end;
      Exit;
    end
    else
    begin
      SetLength(PassThru, Length(PassThru) + 1);
      PassThru[High(PassThru)] := a;
    end;
    Inc(i);
  end;
end;

{----------------------------------------------------------------------------
  Defaults — compute default paths relative to the binary location.
----------------------------------------------------------------------------}
procedure SetDefaults;
var
  binDir, rootDir : AnsiString;
begin
  binDir := ExpandFileName(ExtractFilePath(ParamStr(0)));
  if (Length(binDir) > 0) and (binDir[Length(binDir)] = PathDelim) then
    rootDir := ExpandFileName(binDir + '..' + PathDelim)
  else
    rootDir := ExpandFileName(binDir + PathDelim + '..' + PathDelim);
  if ArgPasBin = '' then ArgPasBin := IncludeTrailingPathDelimiter(rootDir) + 'bin' + PathDelim + 'passpeedtest1';
  if ArgCBin   = '' then ArgCBin   := ExpandFileName(IncludeTrailingPathDelimiter(rootDir) + '..' + PathDelim + 'sqlite3' + PathDelim + 'speedtest1');
  if ArgLibDir = '' then ArgLibDir := IncludeTrailingPathDelimiter(rootDir) + 'src';
end;

function MakeTmpDir: AnsiString;
var
  base : AnsiString;
  i    : Integer;
begin
  base := GetTempDir(False);
  if base = '' then base := '/tmp';
  base := IncludeTrailingPathDelimiter(base);
  i := 0;
  repeat
    Result := base + 'speedtestdiff_' + IntToStr(GetProcessID) + '_'
              + IntToStr(GetTickCount64) + '_' + IntToStr(i);
    Inc(i);
  until (not DirectoryExists(Result)) or (i > 1000);
  CreateDir(Result);
end;

procedure RmTree(const dir: AnsiString);
var
  info : TSearchRec;
  full : AnsiString;
begin
  if (dir = '') or (not DirectoryExists(dir)) then Exit;
  if FindFirst(IncludeTrailingPathDelimiter(dir) + '*', faAnyFile, info) = 0 then
  begin
    repeat
      if (info.Name = '.') or (info.Name = '..') then Continue;
      full := IncludeTrailingPathDelimiter(dir) + info.Name;
      if (info.Attr and faDirectory) <> 0 then RmTree(full)
      else DeleteFile(full);
    until FindNext(info) <> 0;
    FindClose(info);
  end;
  RemoveDir(dir);
end;

procedure WriteFileStr(const path, content: AnsiString);
var
  f : TFileStream;
begin
  f := TFileStream.Create(path, fmCreate);
  try
    if Length(content) > 0 then
      f.Write(content[1], Length(content));
  finally
    f.Free;
  end;
end;

{----------------------------------------------------------------------------
  Main.
----------------------------------------------------------------------------}
var
  pasOut, pasErr, cOut, cErr : AnsiString;
  pasOutS, cOutS             : AnsiString;
  pasRc, cRc                 : Integer;
  pasMs, cMs                 : Int64;
  pasArgs, cArgs             : array of AnsiString;
  i                          : Integer;
  tmpDir                     : AnsiString;
  pasDb, cDb                 : AnsiString;
  divergence                 : Boolean;
  pasT, cT                   : TTimingArr;

begin
  ParseArgs;
  SetDefaults;

  if not FileExists(ArgPasBin) then
  begin
    Writeln(StdErr, 'ERROR: pas binary missing: ', ArgPasBin);
    Writeln(StdErr, '       Build with: ./src/bench/build.sh');
    Halt(2);
  end;
  if not FileExists(ArgCBin) then
  begin
    Writeln(StdErr, 'ERROR: C oracle binary missing: ', ArgCBin);
    Writeln(StdErr, '       Build with:');
    Writeln(StdErr, '         cd ../sqlite3 && gcc -O2 -o speedtest1 \');
    Writeln(StdErr, '             test/speedtest1.c -I. -L. -l:libsqlite3.a \');
    Writeln(StdErr, '             -lpthread -lm -ldl');
    Halt(2);
  end;

  tmpDir := MakeTmpDir;
  if tmpDir = '' then
  begin
    Writeln(StdErr, 'ERROR: could not create tmpdir');
    Halt(2);
  end;

  try
    if ArgDbPath <> '' then
    begin
      pasDb := ArgDbPath + '.pas';
      cDb   := ArgDbPath + '.c';
    end
    else
    begin
      pasDb := IncludeTrailingPathDelimiter(tmpDir) + 'pas.db';
      cDb   := IncludeTrailingPathDelimiter(tmpDir) + 'oracle.db';
    end;

    { Build arg vectors — passthru + db path. }
    SetLength(pasArgs, Length(PassThru) + 1);
    SetLength(cArgs,   Length(PassThru) + 1);
    for i := 0 to High(PassThru) do
    begin
      pasArgs[i] := PassThru[i];
      cArgs[i]   := PassThru[i];
    end;
    pasArgs[High(pasArgs)] := pasDb;
    cArgs[High(cArgs)]     := cDb;

    Writeln('SpeedtestDiff: pas = ', ArgPasBin);
    Writeln('SpeedtestDiff: C   = ', ArgCBin);
    Write  ('SpeedtestDiff: args =');
    for i := 0 to High(PassThru) do Write(' ', PassThru[i]);
    Writeln;
    Writeln('SpeedtestDiff: running pas engine ...');
    pasRc := RunBinary(ArgPasBin, pasArgs, ArgLibDir, pasOut, pasErr, pasMs);
    Writeln(Format('SpeedtestDiff: pas done rc=%d (%d ms)', [pasRc, pasMs]));

    Writeln('SpeedtestDiff: running C oracle ...');
    cRc := RunBinary(ArgCBin, cArgs, '', cOut, cErr, cMs);
    Writeln(Format('SpeedtestDiff: C  done rc=%d (%d ms)', [cRc, cMs]));

    if ArgKeepTmp then
    begin
      WriteFileStr(IncludeTrailingPathDelimiter(tmpDir) + 'pas.out',  pasOut);
      WriteFileStr(IncludeTrailingPathDelimiter(tmpDir) + 'pas.err',  pasErr);
      WriteFileStr(IncludeTrailingPathDelimiter(tmpDir) + 'c.out',    cOut);
      WriteFileStr(IncludeTrailingPathDelimiter(tmpDir) + 'c.err',    cErr);
      Writeln('SpeedtestDiff: artefacts kept in ', tmpDir);
    end;

    if (pasRc <> 0) or (cRc <> 0) then
    begin
      Writeln(StdErr, 'SpeedtestDiff: one or both binaries exited non-zero');
      if pasErr <> '' then begin Writeln(StdErr, '--- pas stderr ---'); Writeln(StdErr, pasErr); end;
      if cErr   <> '' then begin Writeln(StdErr, '--- C   stderr ---'); Writeln(StdErr, cErr);   end;
      Halt(3);
    end;

    pasOutS := StripVolatile(pasOut);
    cOutS   := StripVolatile(cOut);

    divergence := pasOutS <> cOutS;
    if divergence then
    begin
      Writeln(StdErr);
      Writeln(StdErr, '!!! CORRECTNESS DIVERGENCE — stripped outputs differ !!!');
      { Always dump artefacts on divergence for triage. }
      WriteFileStr(IncludeTrailingPathDelimiter(tmpDir) + 'pas.stripped.txt', pasOutS);
      WriteFileStr(IncludeTrailingPathDelimiter(tmpDir) + 'c.stripped.txt',   cOutS);
      WriteFileStr(IncludeTrailingPathDelimiter(tmpDir) + 'pas.out',          pasOut);
      WriteFileStr(IncludeTrailingPathDelimiter(tmpDir) + 'c.out',            cOut);
      Writeln(StdErr, '    triage artefacts: ', tmpDir);
      Writeln(StdErr, '    diff -u ', tmpDir, '/c.stripped.txt ', tmpDir, '/pas.stripped.txt');
      Halt(1);
    end;

    Writeln;
    Writeln('CORRECTNESS PASS — stripped outputs identical.');

    pasT := ParseTimings(pasOut);
    cT   := ParseTimings(cOut);
    PrintRatioTable(pasT, cT);

  finally
    if not ArgKeepTmp then RmTree(tmpDir);
  end;

  Halt(0);
end.
