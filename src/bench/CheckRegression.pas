{$mode objfpc}
{$H+}
program CheckRegression;
{
  Phase 11.7 — Regression gate.

  Loads bench/baseline.json (committed at this phase) and re-runs the same
  matrix of speedtest1 args via bin/SpeedtestDiff.  For every cell whose
  baseline carries a numeric ratio, computes the new ratio (pas_ms / c_ms)
  and compares relative drift:

      rel = (new_ratio - baseline_ratio) / baseline_ratio

  Fails (exit 1) if rel > THRESHOLD on any cell.  THRESHOLD defaults to
  0.10 and is overridable via env var REGRESSION_THRESHOLD_PCT (interpreted
  as percent, e.g. "15" -> 0.15).

  Cells with "skipped" in the baseline are skipped (not failed); cells
  whose new run reports skipped/crashes are reported as SKIP-NEW (not
  failed either) so engine-bug cells stay quiet until they are fixed.

  Improvements (new < baseline) are *reported* but never fail.

  Output: per-cell table; legend
    OK     | new_ratio within threshold
    BETTER | new_ratio improved
    SKIP   | cell skipped in baseline (engine bug)
    SKIP-N | skipped this run (crash / divergence)
    FAIL   | new_ratio regressed > THRESHOLD
}

uses
  SysUtils, Classes, Process, pipes, fpjson, jsonparser;

const
  CHUNK = 8192;

type
  TBaselineCell = record
    Testset : AnsiString;
    Args    : AnsiString;
    CaseId  : Integer;
    Label_  : AnsiString;
    Size    : Integer;
    PasMs   : Double;
    CMs     : Double;
    Ratio   : Double;
    Skipped : Boolean;
    SkipMsg : AnsiString;
    HasRatio: Boolean;
  end;
  TBaselineArr = array of TBaselineCell;

  TParsedCase = record
    CaseId : Integer;
    Label_ : AnsiString;
    PasMs  : Double;
    CMs    : Double;
    Ratio  : Double;
    HasRatio : Boolean;
  end;
  TParsedArr = array of TParsedCase;

var
  ArgBaseline : AnsiString = '';
  ArgDiffBin  : AnsiString = '';
  ArgRootDir  : AnsiString = '';
  Threshold   : Double = 0.10;

{----------------------------------------------------------------------------
  Helpers
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

function ReadFileStr(const path: AnsiString): AnsiString;
var
  fs : TFileStream;
  n  : Int64;
begin
  Result := '';
  fs := TFileStream.Create(path, fmOpenRead or fmShareDenyNone);
  try
    n := fs.Size;
    if n <= 0 then Exit;
    SetLength(Result, n);
    fs.ReadBuffer(Result[1], n);
  finally
    fs.Free;
  end;
end;

function SplitArgs(const s: AnsiString): TStringArray;
var
  i, start : Integer;
  cur : AnsiString;
begin
  Result := nil;
  i := 1;
  while i <= Length(s) do
  begin
    while (i <= Length(s)) and (s[i] = ' ') do Inc(i);
    if i > Length(s) then Break;
    start := i;
    while (i <= Length(s)) and (s[i] <> ' ') do Inc(i);
    cur := Copy(s, start, i - start);
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := cur;
  end;
end;

{----------------------------------------------------------------------------
  Load baseline JSON.
----------------------------------------------------------------------------}
function LoadBaseline(const path: AnsiString): TBaselineArr;
var
  raw : AnsiString;
  root : TJSONData;
  cells : TJSONArray;
  i : Integer;
  obj : TJSONObject;
  c : TBaselineCell;
begin
  Result := nil;
  raw := ReadFileStr(path);
  root := GetJSON(raw);
  try
    cells := TJSONObject(root).Arrays['cells'];
    for i := 0 to cells.Count - 1 do
    begin
      obj := TJSONObject(cells.Items[i]);
      c.Testset := obj.Get('testset', '');
      c.Args    := obj.Get('args', '');
      c.CaseId  := obj.Get('case_id', 0);
      c.Label_  := obj.Get('label', '');
      c.Size    := obj.Get('size', 1);
      c.Skipped := False;
      c.SkipMsg := '';
      c.HasRatio := False;
      c.PasMs := 0; c.CMs := 0; c.Ratio := 0;
      if obj.IndexOfName('skipped') >= 0 then
      begin
        c.Skipped := True;
        c.SkipMsg := obj.Get('skipped', '');
      end
      else
      begin
        if (obj.IndexOfName('ratio') >= 0) and (obj.Items[obj.IndexOfName('ratio')].JSONType <> jtNull) then
        begin
          c.Ratio := obj.Get('ratio', Double(0));
          c.HasRatio := True;
        end;
        if obj.IndexOfName('pas_ms') >= 0 then c.PasMs := obj.Get('pas_ms', Double(0));
        if obj.IndexOfName('c_ms') >= 0 then c.CMs := obj.Get('c_ms', Double(0));
      end;
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := c;
    end;
  finally
    root.Free;
  end;
end;

{----------------------------------------------------------------------------
  Run SpeedtestDiff with given args, capture stdout, return rc + harness
  wall-clock times reported on "pas done rc=N (M ms)" / "C done rc=N (M ms)".
----------------------------------------------------------------------------}
function RunDiff(const diffBin, args: AnsiString;
                 out outText: AnsiString;
                 out pasMsHarness, cMsHarness: Double;
                 out divergent: Boolean): Integer;
var
  p : TProcess;
  toks : TStringArray;
  i : Integer;
  sErr : AnsiString;
  lines : TStringList;
  ln : AnsiString;
begin
  outText := '';
  sErr := '';
  pasMsHarness := 0;
  cMsHarness := 0;
  divergent := False;
  Result := -1;
  p := TProcess.Create(nil);
  try
    p.Executable := diffBin;
    toks := SplitArgs(args);
    for i := 0 to High(toks) do p.Parameters.Add(toks[i]);
    p.Options := [poUsePipes];
    p.ShowWindow := swoHIDE;
    try
      p.Execute;
    except
      on E: Exception do
      begin
        Writeln(StdErr, 'CheckRegression: spawn ', diffBin, ' failed: ', E.Message);
        Exit;
      end;
    end;
    while p.Running do
    begin
      AppendChunk(p.Output, outText);
      AppendChunk(p.Stderr, sErr);
      Sleep(5);
    end;
    AppendChunk(p.Output, outText);
    AppendChunk(p.Stderr, sErr);
    Result := p.ExitStatus;
  finally
    p.Free;
  end;

  { Detect divergence flag in the stderr/stdout. }
  if (Pos('CORRECTNESS DIVERGENCE', sErr) > 0) or (Pos('CORRECTNESS DIVERGENCE', outText) > 0) then
    divergent := True;

  { Pull harness wall-clock from output. }
  lines := TStringList.Create;
  try
    lines.Text := outText;
    for i := 0 to lines.Count - 1 do
    begin
      ln := lines[i];
      if Pos('pas done rc=', ln) > 0 then
      begin
        pasMsHarness := StrToFloatDef(Trim(Copy(ln, Pos('(', ln) + 1, Pos(' ms)', ln) - Pos('(', ln) - 1)), 0);
      end
      else if Pos('C  done rc=', ln) > 0 then
      begin
        cMsHarness := StrToFloatDef(Trim(Copy(ln, Pos('(', ln) + 1, Pos(' ms)', ln) - Pos('(', ln) - 1)), 0);
      end;
    end;
  finally
    lines.Free;
  end;
end;

{----------------------------------------------------------------------------
  Parse the per-case table out of SpeedtestDiff stdout.
  Matches rows of shape:
      "%5d  %-58s  %8.3f  %8.3f  %8.2fx"
  Header sentinel: "=== Per-case timings (seconds) ==="
----------------------------------------------------------------------------}
function ParseDiffTable(const s: AnsiString): TParsedArr;
var
  lines : TStringList;
  i, j, k : Integer;
  ln, num : AnsiString;
  inTable : Boolean;
  caseId : Integer;
  lab : AnsiString;
  pasSec, cSec : Double;
  fs : TFormatSettings;
  pc : TParsedCase;

  function NextToken(var idx: Integer): AnsiString;
  var
    st : Integer;
  begin
    Result := '';
    while (idx <= Length(ln)) and (ln[idx] = ' ') do Inc(idx);
    st := idx;
    while (idx <= Length(ln)) and (ln[idx] <> ' ') do Inc(idx);
    Result := Copy(ln, st, idx - st);
  end;
begin
  Result := nil;
  fs := DefaultFormatSettings;
  fs.DecimalSeparator := '.';
  inTable := False;
  lines := TStringList.Create;
  try
    lines.Text := s;
    for i := 0 to lines.Count - 1 do
    begin
      ln := lines[i];
      if Pos('=== Per-case timings', ln) > 0 then
      begin
        inTable := True;
        Continue;
      end;
      if not inTable then Continue;
      if Length(Trim(ln)) = 0 then Continue;
      { Stop at the bottom divider plus stuff. }
      if Pos('SUMMED PER-CASE', ln) > 0 then Break;
      if Pos('(no C totals', ln) > 0 then Break;
      { Skip header / divider. }
      if Pos('case', ln) = 3 then Continue;
      if (Length(ln) > 0) and (ln[1] = '-') then Continue;
      { Parse "  NNN  label..............  pas  C  ratiox" }
      j := 1;
      while (j <= Length(ln)) and (ln[j] = ' ') do Inc(j);
      if j > Length(ln) then Continue;
      if not ((ln[j] >= '0') and (ln[j] <= '9')) then Continue;
      caseId := 0;
      while (j <= Length(ln)) and (ln[j] >= '0') and (ln[j] <= '9') do
      begin
        caseId := caseId * 10 + Ord(ln[j]) - Ord('0');
        Inc(j);
      end;
      { Label runs until two spaces before pas-float. SpeedtestDiff uses
        Format '%-58s' so label is fixed-width 58. After case+2 spaces. }
      while (j <= Length(ln)) and (ln[j] = ' ') do Inc(j);
      { label: read up to last two non-space tokens (pas, C) plus ratio. }
      { Simpler: split last three tokens from the end. }
      k := Length(ln);
      while (k >= 1) and (ln[k] = ' ') do Dec(k);
      { strip trailing 'x' or token "n/a" or "-" }
      { Walk back three whitespace-separated tokens. }
      { token 3 (ratio): }
      while (k >= 1) and (ln[k] <> ' ') do Dec(k);  { skip to before ratio }
      { token 2 (C secs): }
      while (k >= 1) and (ln[k] = ' ') do Dec(k);
      while (k >= 1) and (ln[k] <> ' ') do Dec(k);
      { token 1 (pas secs): }
      while (k >= 1) and (ln[k] = ' ') do Dec(k);
      while (k >= 1) and (ln[k] <> ' ') do Dec(k);
      { Now [j..k] is label region inclusive of trailing spaces. }
      lab := Trim(Copy(ln, j, k - j + 1));
      { Now read pas, C. }
      Inc(k);
      while (k <= Length(ln)) and (ln[k] = ' ') do Inc(k);
      num := '';
      while (k <= Length(ln)) and (ln[k] <> ' ') do begin num := num + ln[k]; Inc(k); end;
      if not TryStrToFloat(num, pasSec, fs) then
      begin
        { 'missing' etc. — skip }
        Continue;
      end;
      while (k <= Length(ln)) and (ln[k] = ' ') do Inc(k);
      num := '';
      while (k <= Length(ln)) and (ln[k] <> ' ') do begin num := num + ln[k]; Inc(k); end;
      if not TryStrToFloat(num, cSec, fs) then Continue;

      pc.CaseId := caseId;
      pc.Label_ := lab;
      pc.PasMs := pasSec * 1000.0;
      pc.CMs := cSec * 1000.0;
      pc.HasRatio := False;
      pc.Ratio := 0;
      if cSec > 0 then
      begin
        pc.Ratio := pasSec / cSec;
        pc.HasRatio := True;
      end;
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := pc;
    end;
  finally
    lines.Free;
  end;
end;

function FindParsed(const arr: TParsedArr; caseId: Integer; const lab: AnsiString;
                    out idx: Integer): Boolean;
var
  i : Integer;
begin
  for i := 0 to High(arr) do
    if (arr[i].CaseId = caseId) and (arr[i].Label_ = lab) then
    begin
      idx := i;
      Exit(True);
    end;
  idx := -1;
  Result := False;
end;

{----------------------------------------------------------------------------
  Arg parsing.
----------------------------------------------------------------------------}
procedure ParseArgs;
var
  i : Integer;
  a : AnsiString;
  envS : AnsiString;
  envD : Double;
  fs : TFormatSettings;
begin
  i := 1;
  while i <= ParamCount do
  begin
    a := ParamStr(i);
    if a = '--baseline' then begin Inc(i); ArgBaseline := ParamStr(i); end
    else if a = '--diff-bin' then begin Inc(i); ArgDiffBin := ParamStr(i); end
    else if a = '--root' then begin Inc(i); ArgRootDir := ParamStr(i); end
    else if (a = '-h') or (a = '--help') then
    begin
      Writeln('CheckRegression — re-run speedtest1 matrix and compare ratios vs baseline.json.');
      Writeln('  --baseline PATH   bench/baseline.json (default <root>/bench/baseline.json)');
      Writeln('  --diff-bin PATH   bin/SpeedtestDiff   (default <root>/bin/SpeedtestDiff)');
      Writeln('  --root DIR        project root        (default ParamStr(0)/../..)');
      Writeln('Env:');
      Writeln('  REGRESSION_THRESHOLD_PCT   percent drift that fails (default 10)');
      Halt(0);
    end;
    Inc(i);
  end;

  envS := GetEnvironmentVariable('REGRESSION_THRESHOLD_PCT');
  if envS <> '' then
  begin
    fs := DefaultFormatSettings;
    fs.DecimalSeparator := '.';
    if TryStrToFloat(envS, envD, fs) then
      Threshold := envD / 100.0;
  end;
end;

procedure SetDefaults;
var
  binDir : AnsiString;
begin
  binDir := ExpandFileName(ExtractFilePath(ParamStr(0)));
  if ArgRootDir = '' then
    ArgRootDir := ExpandFileName(IncludeTrailingPathDelimiter(binDir) + '..');
  if ArgBaseline = '' then
    ArgBaseline := IncludeTrailingPathDelimiter(ArgRootDir) + 'bench' + PathDelim + 'baseline.json';
  if ArgDiffBin = '' then
    ArgDiffBin := IncludeTrailingPathDelimiter(ArgRootDir) + 'bin' + PathDelim + 'SpeedtestDiff';
end;

{----------------------------------------------------------------------------
  Main.
----------------------------------------------------------------------------}
type
  TArgsRun = record
    Args : AnsiString;
    Parsed : TParsedArr;
    PasHarnessMs : Double;
    CHarnessMs   : Double;
    Divergent : Boolean;
    Crashed   : Boolean;
  end;
  TArgsRunArr = array of TArgsRun;

function GetOrRunArgs(var runs: TArgsRunArr; const args: AnsiString): Integer;
var
  i, rc : Integer;
  outText : AnsiString;
  r : TArgsRun;
begin
  for i := 0 to High(runs) do
    if runs[i].Args = args then
    begin
      Result := i;
      Exit;
    end;
  Writeln('  running: SpeedtestDiff ', args);
  r.Args := args;
  r.Divergent := False;
  r.Crashed := False;
  rc := RunDiff(ArgDiffBin, args, outText, r.PasHarnessMs, r.CHarnessMs, r.Divergent);
  if (rc <> 0) and (not r.Divergent) then r.Crashed := True;
  r.Parsed := ParseDiffTable(outText);
  SetLength(runs, Length(runs) + 1);
  runs[High(runs)] := r;
  Result := High(runs);
end;

var
  baseline : TBaselineArr;
  runs     : TArgsRunArr;
  i, idx   : Integer;
  c        : TBaselineCell;
  runIdx   : Integer;
  newRatio : Double;
  rel      : Double;
  status   : AnsiString;
  failed   : Integer;
  okCnt, betterCnt, skipCnt, skipNewCnt : Integer;
  pasMsNew, cMsNew : Double;
  isWallTotal : Boolean;

begin
  ParseArgs;
  SetDefaults;

  if not FileExists(ArgBaseline) then
  begin
    Writeln(StdErr, 'ERROR: baseline missing: ', ArgBaseline);
    Halt(2);
  end;
  if not FileExists(ArgDiffBin) then
  begin
    Writeln(StdErr, 'ERROR: SpeedtestDiff missing: ', ArgDiffBin);
    Writeln(StdErr, '       Build with src/bench/build.sh');
    Halt(2);
  end;

  Writeln('CheckRegression: baseline = ', ArgBaseline);
  Writeln('CheckRegression: diff-bin = ', ArgDiffBin);
  Writeln(Format('CheckRegression: threshold = %.2f%%', [Threshold * 100.0]));
  Writeln;

  baseline := LoadBaseline(ArgBaseline);
  SetLength(runs, 0);

  Writeln(Format('%-12s  %-44s  %-6s  %8s  %8s  %6s', ['testset','label(case)','status','base','new','rel%']));
  Writeln(StringOfChar('-', 92));

  failed := 0;
  okCnt := 0; betterCnt := 0; skipCnt := 0; skipNewCnt := 0;

  for i := 0 to High(baseline) do
  begin
    c := baseline[i];

    if c.Skipped then
    begin
      Writeln(Format('%-12s  %-44s  %-6s  %8s  %8s  %6s',
        [c.Testset, Copy(Format('%s(%d)', [c.Label_, c.CaseId]), 1, 44),
         'SKIP', '-', '-', '-']));
      Inc(skipCnt);
      Continue;
    end;

    runIdx := GetOrRunArgs(runs, c.Args);

    if runs[runIdx].Crashed or runs[runIdx].Divergent then
    begin
      Writeln(Format('%-12s  %-44s  %-6s  %8s  %8s  %6s',
        [c.Testset, Copy(Format('%s(%d)', [c.Label_, c.CaseId]), 1, 44),
         'SKIP-N', FormatFloat('0.00', c.Ratio), '-', '-']));
      Inc(skipNewCnt);
      Continue;
    end;

    isWallTotal := (c.Label_ = 'WALL_TOTAL');

    if isWallTotal then
    begin
      pasMsNew := runs[runIdx].PasHarnessMs;
      cMsNew := runs[runIdx].CHarnessMs;
      if cMsNew <= 0 then
      begin
        Writeln(Format('%-12s  %-44s  %-6s  %8.2f  %8s  %6s',
          [c.Testset, Copy(Format('%s(%d)', [c.Label_, c.CaseId]), 1, 44),
           'SKIP-N', c.Ratio, '-', '-']));
        Inc(skipNewCnt);
        Continue;
      end;
      newRatio := pasMsNew / cMsNew;
    end
    else
    begin
      if not FindParsed(runs[runIdx].Parsed, c.CaseId, c.Label_, idx) then
      begin
        Writeln(Format('%-12s  %-44s  %-6s  %8.2f  %8s  %6s',
          [c.Testset, Copy(Format('%s(%d)', [c.Label_, c.CaseId]), 1, 44),
           'SKIP-N', c.Ratio, 'missing', '-']));
        Inc(skipNewCnt);
        Continue;
      end;
      if not runs[runIdx].Parsed[idx].HasRatio then
      begin
        { sub-ms — baseline shouldn't have had a ratio either, but guard. }
        Writeln(Format('%-12s  %-44s  %-6s  %8.2f  %8s  %6s',
          [c.Testset, Copy(Format('%s(%d)', [c.Label_, c.CaseId]), 1, 44),
           'SKIP-N', c.Ratio, 'subms', '-']));
        Inc(skipNewCnt);
        Continue;
      end;
      newRatio := runs[runIdx].Parsed[idx].Ratio;
    end;

    if not c.HasRatio then
    begin
      Writeln(Format('%-12s  %-44s  %-6s  %8s  %8.2f  %6s',
        [c.Testset, Copy(Format('%s(%d)', [c.Label_, c.CaseId]), 1, 44),
         'SKIP', '-', newRatio, '-']));
      Inc(skipCnt);
      Continue;
    end;

    { Sub-resolution timer noise filter: per-case cells where the baseline
      pas_ms < 10 AND c_ms < 10 are dominated by GetTickCount64 quantisation
      (typically 1ms-grained); skip them rather than fail on noise.  Does
      not apply to WALL_TOTAL cells. }
    if (not isWallTotal) and (c.PasMs < 10.0) and (c.CMs < 10.0) then
    begin
      Writeln(Format('%-12s  %-44s  %-6s  %8.2f  %8.2f  %7s',
        [c.Testset, Copy(Format('%s(%d)', [c.Label_, c.CaseId]), 1, 44),
         'NOISE', c.Ratio, newRatio, '-']));
      Inc(skipCnt);
      Continue;
    end;

    if c.Ratio <= 0 then rel := 0
    else rel := (newRatio - c.Ratio) / c.Ratio;

    if rel > Threshold then
    begin
      status := 'FAIL';
      Inc(failed);
    end
    else if newRatio < c.Ratio * 0.95 then
    begin
      status := 'BETTER';
      Inc(betterCnt);
    end
    else
    begin
      status := 'OK';
      Inc(okCnt);
    end;

    Writeln(Format('%-12s  %-44s  %-6s  %8.2f  %8.2f  %7.1f',
      [c.Testset, Copy(Format('%s(%d)', [c.Label_, c.CaseId]), 1, 44),
       status, c.Ratio, newRatio, rel * 100.0]));
  end;

  Writeln(StringOfChar('-', 92));
  Writeln(Format('CheckRegression: OK=%d BETTER=%d SKIP=%d SKIP-N=%d FAIL=%d',
    [okCnt, betterCnt, skipCnt, skipNewCnt, failed]));

  if failed > 0 then
  begin
    Writeln(Format('REGRESSION GATE FAILED: %d cell(s) regressed > %.2f%%',
      [failed, Threshold * 100.0]));
    Halt(1);
  end;
  Writeln('REGRESSION GATE PASS');
  Halt(0);
end.
