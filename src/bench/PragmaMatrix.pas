{$mode objfpc}
{$H+}
program PragmaMatrix;
{
  Phase 11.8 — Pragma / config matrix.

  Runs `testset_main --size 1` across the cartesian product
    journal_mode  ∈ {WAL, DELETE}
    synchronous   ∈ {NORMAL, FULL}
    page_size     ∈ {4096, 8192, 16384}
    cache_size    ∈ {default(-2000), 10× default(-20000)}
  = 24 cells.

  For each cell, spawns bin/passpeedtest1 and ../sqlite3/speedtest1 with
  matching args, extracts the "TOTAL" wall-clock from each stdout,
  computes pas/C ratio, and writes a markdown table to bench/pragma_matrix.txt.

  Cells whose pas (or C) run crashes / exits non-zero / fails to emit a TOTAL
  line are flagged "crash" in the table; the run continues.

  Build via src/bench/build.sh (bin/PragmaMatrix).
  Run   via bench/run_pragma_matrix.sh (or invoke directly with --out PATH).
}

uses
  SysUtils, Classes, Process, pipes;

const
  CHUNK = 8192;

type
  TCell = record
    Journal   : AnsiString;
    Sync      : AnsiString;
    PageSize  : Integer;
    CacheSize : Integer;       { negative = KiB }
    CacheLbl  : AnsiString;    { 'default' | '10x' }
    PasMs     : Double;        { milliseconds; -1 = crash/no-total }
    CMs       : Double;
    PasNote   : AnsiString;
    CNote     : AnsiString;
  end;

var
  ArgPasBin : AnsiString = '';
  ArgCBin   : AnsiString = '';
  ArgLibDir : AnsiString = '';
  ArgOut    : AnsiString = '';
  ArgSize   : Integer    = 1;

{----------------------------------------------------------------------------
  AppendChunk / DrainAll / RunBinary — same shape as SpeedtestDiff.pas.
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

function RunBinary(const exe: AnsiString;
                   const args: array of AnsiString;
                   const libDir: AnsiString;
                   var sOut, sErr: AnsiString;
                   var elapsedMs: Int64): Integer;
var
  p   : TProcess;
  ii  : Integer;
  t0  : QWord;
begin
  sOut := '';
  sErr := '';
  elapsedMs := 0;
  Result := -1;
  p := TProcess.Create(nil);
  try
    p.Executable := exe;
    for ii := 0 to High(args) do p.Parameters.Add(args[ii]);
    p.Options := [poUsePipes];
    p.ShowWindow := swoHIDE;
    if libDir <> '' then
    begin
      p.Environment.Add('LD_LIBRARY_PATH=' + libDir);
      for ii := 0 to GetEnvironmentVariableCount - 1 do
        if Pos('LD_LIBRARY_PATH=', GetEnvironmentString(ii)) <> 1 then
          p.Environment.Add(GetEnvironmentString(ii));
    end;
    t0 := GetTickCount64;
    try
      p.Execute;
    except
      on E: Exception do
      begin
        Writeln(StdErr, 'PragmaMatrix: spawn ', exe, ' failed: ', E.Message);
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
  ExtractTotalMs — find the "TOTAL ... DDD.DDDs" line, return milliseconds.
  Returns -1.0 if no TOTAL line found.
----------------------------------------------------------------------------}
function ExtractTotalMs(const s: AnsiString): Double;
var
  lines : TStringList;
  i, k, start : Integer;
  ln, numStr  : AnsiString;
  secs        : Double;
  fs          : TFormatSettings;
begin
  Result := -1.0;
  fs := DefaultFormatSettings;
  fs.DecimalSeparator := '.';
  lines := TStringList.Create;
  try
    lines.Text := s;
    for i := 0 to lines.Count - 1 do
    begin
      ln := lines[i];
      if Pos('TOTAL', ln) = 0 then Continue;
      k := Length(ln);
      if (k < 3) or (ln[k] <> 's') then Continue;
      Dec(k);
      start := k;
      while (start >= 1) and (((ln[start] >= '0') and (ln[start] <= '9')) or (ln[start] = '.')) do
        Dec(start);
      if start = k then Continue;
      numStr := Copy(ln, start + 1, k - start);
      if TryStrToFloat(numStr, secs, fs) then
      begin
        Result := secs * 1000.0;
        Exit;
      end;
    end;
  finally
    lines.Free;
  end;
end;

{----------------------------------------------------------------------------
  BuildCellArgs — common arg-vector for both pas and C invocations.
  The db path is appended by the caller.
----------------------------------------------------------------------------}
function BuildCellArgs(const c: TCell; const dbPath: AnsiString): TStringList;
begin
  Result := TStringList.Create;
  Result.Add('--testset');     Result.Add('main');
  Result.Add('--size');        Result.Add(IntToStr(ArgSize));
  Result.Add('--journal');     Result.Add(c.Journal);
  Result.Add('--synchronous'); Result.Add(c.Sync);
  Result.Add('--pagesize');    Result.Add(IntToStr(c.PageSize));
  Result.Add('--cachesize');   Result.Add(IntToStr(c.CacheSize));
  Result.Add(dbPath);
end;

function ListToArr(l: TStringList): TStringArray;
var i: Integer;
begin
  SetLength(Result, l.Count);
  for i := 0 to l.Count - 1 do Result[i] := l[i];
end;

procedure RunCell(var c: TCell);
var
  tmpDir, pasDb, cDb : AnsiString;
  pasArgs, cArgs     : TStringList;
  pasOut, pasErr, cOut, cErr : AnsiString;
  pasRc, cRc         : Integer;
  pasMs, cMs         : Int64;
begin
  c.PasMs   := -1;
  c.CMs     := -1;
  c.PasNote := '';
  c.CNote   := '';

  tmpDir := GetTempDir(False);
  if tmpDir = '' then tmpDir := '/tmp/';
  tmpDir := IncludeTrailingPathDelimiter(tmpDir);
  pasDb := tmpDir + 'pragmatrix_pas_' + IntToStr(GetProcessID) + '_'
           + IntToStr(GetTickCount64) + '.db';
  cDb   := tmpDir + 'pragmatrix_c_'   + IntToStr(GetProcessID) + '_'
           + IntToStr(GetTickCount64) + '.db';
  DeleteFile(pasDb); DeleteFile(cDb);

  pasArgs := BuildCellArgs(c, pasDb);
  cArgs   := BuildCellArgs(c, cDb);
  try
    pasRc := RunBinary(ArgPasBin, ListToArr(pasArgs), ArgLibDir, pasOut, pasErr, pasMs);
    cRc   := RunBinary(ArgCBin,   ListToArr(cArgs),   '',        cOut,   cErr,   cMs);

    if pasRc <> 0 then c.PasNote := 'rc=' + IntToStr(pasRc)
    else
    begin
      c.PasMs := ExtractTotalMs(pasOut);
      if c.PasMs < 0 then c.PasNote := 'no-total';
    end;
    if cRc <> 0 then c.CNote := 'rc=' + IntToStr(cRc)
    else
    begin
      c.CMs := ExtractTotalMs(cOut);
      if c.CMs < 0 then c.CNote := 'no-total';
    end;
    if pasMs > 0 then ; { suppress unused warning }
    if cMs   > 0 then ;
    if Length(pasErr) > 0 then ;
    if Length(cErr)   > 0 then ;
  finally
    pasArgs.Free;
    cArgs.Free;
    DeleteFile(pasDb); DeleteFile(cDb);
    { wal/journal sidecars }
    DeleteFile(pasDb + '-wal'); DeleteFile(pasDb + '-journal'); DeleteFile(pasDb + '-shm');
    DeleteFile(cDb   + '-wal'); DeleteFile(cDb   + '-journal'); DeleteFile(cDb   + '-shm');
  end;
end;

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
  if ArgOut    = '' then ArgOut    := IncludeTrailingPathDelimiter(rootDir) + 'bench' + PathDelim + 'pragma_matrix.txt';
end;

procedure ParseArgs;
var i: Integer; a: AnsiString;
begin
  i := 1;
  while i <= ParamCount do
  begin
    a := ParamStr(i);
    if      a = '--pas-bin' then begin Inc(i); ArgPasBin := ParamStr(i); end
    else if a = '--c-bin'   then begin Inc(i); ArgCBin   := ParamStr(i); end
    else if a = '--lib-dir' then begin Inc(i); ArgLibDir := ParamStr(i); end
    else if a = '--out'     then begin Inc(i); ArgOut    := ParamStr(i); end
    else if a = '--size'    then begin Inc(i); ArgSize   := StrToIntDef(ParamStr(i), 1); end
    else if (a = '-h') or (a = '--help') then
    begin
      Writeln('PragmaMatrix — Phase 11.8 pragma/config matrix driver.');
      Writeln('Usage: PragmaMatrix [--pas-bin P] [--c-bin P] [--lib-dir D] [--out F] [--size N]');
      Halt(0);
    end
    else
    begin
      Writeln(StdErr, 'PragmaMatrix: unknown argument: ', a);
      Halt(2);
    end;
    Inc(i);
  end;
end;

procedure WriteFileStr(const path, content: AnsiString);
var f: TFileStream;
begin
  f := TFileStream.Create(path, fmCreate);
  try
    if Length(content) > 0 then
      f.Write(content[1], Length(content));
  finally
    f.Free;
  end;
end;

function FmtCell(ms: Double; const note: AnsiString): AnsiString;
begin
  if ms < 0 then Result := note
  else Result := Format('%.0f', [ms]);
end;

function FmtRatio(pas_, c: Double; const pasNote, cNote: AnsiString): AnsiString;
begin
  if (pas_ < 0) or (c < 0) then
  begin
    if (pasNote <> '') and (cNote <> '') then Result := 'pas:' + pasNote + ' c:' + cNote
    else if pasNote <> '' then Result := 'pas:' + pasNote
    else if cNote   <> '' then Result := 'c:'   + cNote
    else Result := 'crash';
  end
  else if c = 0 then Result := 'inf'
  else Result := Format('%.2fx', [pas_ / c]);
end;

var
  cells : array of TCell;
  jms   : array[0..1] of AnsiString = ('WAL', 'DELETE');
  syms  : array[0..1] of AnsiString = ('NORMAL', 'FULL');
  psz   : array[0..2] of Integer    = (4096, 8192, 16384);
  csz   : array[0..1] of Integer    = (-2000, -20000);
  cslbl : array[0..1] of AnsiString = ('default', '10x');
  idx, ij, isy, ip, ic : Integer;
  buf   : AnsiString;
  c     : TCell;
  totMin, totMax, totSum : Double;
  okCount : Integer;
  bestKnobJ, bestKnobS, bestKnobP, bestKnobC : Double; { ratio deltas }
  jSum, jCnt : array[0..1] of Double;
  sSum, sCnt : array[0..1] of Double;
  pSum, pCnt : array[0..2] of Double;
  cSum, cCnt : array[0..1] of Double;

begin
  ParseArgs;
  SetDefaults;

  if not FileExists(ArgPasBin) then
  begin
    Writeln(StdErr, 'ERROR: pas binary missing: ', ArgPasBin);
    Halt(2);
  end;
  if not FileExists(ArgCBin) then
  begin
    Writeln(StdErr, 'ERROR: C oracle binary missing: ', ArgCBin);
    Halt(2);
  end;

  Writeln('PragmaMatrix: pas = ', ArgPasBin);
  Writeln('PragmaMatrix: C   = ', ArgCBin);
  Writeln('PragmaMatrix: out = ', ArgOut);
  Writeln('PragmaMatrix: size = ', ArgSize);

  SetLength(cells, 24);
  idx := 0;
  for ij := 0 to 1 do
    for isy := 0 to 1 do
      for ip := 0 to 2 do
        for ic := 0 to 1 do
        begin
          cells[idx].Journal   := jms[ij];
          cells[idx].Sync      := syms[isy];
          cells[idx].PageSize  := psz[ip];
          cells[idx].CacheSize := csz[ic];
          cells[idx].CacheLbl  := cslbl[ic];
          Inc(idx);
        end;

  for idx := 0 to High(cells) do
  begin
    Writeln(Format('[%2d/24] journal=%s sync=%s page=%d cache=%s ...',
      [idx + 1, cells[idx].Journal, cells[idx].Sync,
       cells[idx].PageSize, cells[idx].CacheLbl]));
    RunCell(cells[idx]);
    c := cells[idx];
    if (c.PasMs >= 0) and (c.CMs >= 0) then
      Writeln(Format('         pas=%.0fms c=%.0fms ratio=%.2fx',
        [c.PasMs, c.CMs, c.PasMs / c.CMs]))
    else
      Writeln(Format('         pas=%s c=%s',
        [FmtCell(c.PasMs, c.PasNote), FmtCell(c.CMs, c.CNote)]));
  end;

  { Build markdown table. }
  buf := '# Pragma / config matrix (testset_main, --size '
         + IntToStr(ArgSize) + ')'#10#10;
  buf := buf + 'pas/C TOTAL ratio per cell.  '
              + 'Numbers below the ratio are raw pas_ms / c_ms.'#10#10;

  { Header: journal × sync grouping, then for each (page,cache) a column. }
  buf := buf + '| journal | sync | page_size | cache_size | pas_ms | c_ms | ratio |'#10;
  buf := buf + '|---------|------|-----------|------------|--------|------|-------|'#10;

  totMin := 1.0e30; totMax := -1.0; totSum := 0.0; okCount := 0;
  for ij := 0 to 1 do begin jSum[ij] := 0; jCnt[ij] := 0; end;
  for isy := 0 to 1 do begin sSum[isy] := 0; sCnt[isy] := 0; end;
  for ip := 0 to 2 do begin pSum[ip] := 0; pCnt[ip] := 0; end;
  for ic := 0 to 1 do begin cSum[ic] := 0; cCnt[ic] := 0; end;

  for idx := 0 to High(cells) do
  begin
    c := cells[idx];
    buf := buf + '| ' + c.Journal + ' | ' + c.Sync + ' | '
              + IntToStr(c.PageSize) + ' | ' + c.CacheLbl + ' | '
              + FmtCell(c.PasMs, c.PasNote) + ' | '
              + FmtCell(c.CMs, c.CNote) + ' | '
              + FmtRatio(c.PasMs, c.CMs, c.PasNote, c.CNote)
              + ' |'#10;
    if (c.PasMs > 0) and (c.CMs > 0) then
    begin
      Inc(okCount);
      totSum := totSum + (c.PasMs / c.CMs);
      if (c.PasMs / c.CMs) < totMin then totMin := c.PasMs / c.CMs;
      if (c.PasMs / c.CMs) > totMax then totMax := c.PasMs / c.CMs;
      { axis aggregates }
      for ij := 0 to 1 do
        if c.Journal = jms[ij] then
        begin
          jSum[ij] := jSum[ij] + (c.PasMs / c.CMs);
          jCnt[ij] := jCnt[ij] + 1;
        end;
      for isy := 0 to 1 do
        if c.Sync = syms[isy] then
        begin
          sSum[isy] := sSum[isy] + (c.PasMs / c.CMs);
          sCnt[isy] := sCnt[isy] + 1;
        end;
      for ip := 0 to 2 do
        if c.PageSize = psz[ip] then
        begin
          pSum[ip] := pSum[ip] + (c.PasMs / c.CMs);
          pCnt[ip] := pCnt[ip] + 1;
        end;
      for ic := 0 to 1 do
        if c.CacheSize = csz[ic] then
        begin
          cSum[ic] := cSum[ic] + (c.PasMs / c.CMs);
          cCnt[ic] := cCnt[ic] + 1;
        end;
    end;
  end;

  buf := buf + #10'## Summary'#10#10;
  if okCount > 0 then
    buf := buf + Format('- cells with both totals: %d/24'#10
                      + '- ratio min: %.2fx, max: %.2fx, mean: %.2fx'#10,
                        [okCount, totMin, totMax, totSum / okCount])
  else
    buf := buf + '- no cells produced both totals'#10;

  buf := buf + #10'### Mean pas/C ratio by axis'#10#10;
  buf := buf + '| axis | value | mean ratio |'#10;
  buf := buf + '|------|-------|------------|'#10;
  for ij := 0 to 1 do
    if jCnt[ij] > 0 then
      buf := buf + '| journal_mode | ' + jms[ij] + ' | '
                + Format('%.2fx', [jSum[ij]/jCnt[ij]]) + ' |'#10;
  for isy := 0 to 1 do
    if sCnt[isy] > 0 then
      buf := buf + '| synchronous | ' + syms[isy] + ' | '
                + Format('%.2fx', [sSum[isy]/sCnt[isy]]) + ' |'#10;
  for ip := 0 to 2 do
    if pCnt[ip] > 0 then
      buf := buf + '| page_size | ' + IntToStr(psz[ip]) + ' | '
                + Format('%.2fx', [pSum[ip]/pCnt[ip]]) + ' |'#10;
  for ic := 0 to 1 do
    if cCnt[ic] > 0 then
      buf := buf + '| cache_size | ' + cslbl[ic] + ' | '
                + Format('%.2fx', [cSum[ic]/cCnt[ic]]) + ' |'#10;

  { Largest axis swing }
  buf := buf + #10'### Knob impact (max-min mean ratio across axis values)'#10#10;
  bestKnobJ := 0; bestKnobS := 0; bestKnobP := 0; bestKnobC := 0;
  if (jCnt[0] > 0) and (jCnt[1] > 0) then
    bestKnobJ := Abs(jSum[0]/jCnt[0] - jSum[1]/jCnt[1]);
  if (sCnt[0] > 0) and (sCnt[1] > 0) then
    bestKnobS := Abs(sSum[0]/sCnt[0] - sSum[1]/sCnt[1]);
  if (pCnt[0] > 0) and (pCnt[1] > 0) and (pCnt[2] > 0) then
  begin
    bestKnobP := pSum[0]/pCnt[0];
    if pSum[1]/pCnt[1] > bestKnobP then bestKnobP := pSum[1]/pCnt[1];
    if pSum[2]/pCnt[2] > bestKnobP then bestKnobP := pSum[2]/pCnt[2];
    totSum := pSum[0]/pCnt[0];
    if pSum[1]/pCnt[1] < totSum then totSum := pSum[1]/pCnt[1];
    if pSum[2]/pCnt[2] < totSum then totSum := pSum[2]/pCnt[2];
    bestKnobP := bestKnobP - totSum;
  end;
  if (cCnt[0] > 0) and (cCnt[1] > 0) then
    bestKnobC := Abs(cSum[0]/cCnt[0] - cSum[1]/cCnt[1]);

  buf := buf + Format('- journal_mode swing: %.2fx'#10, [bestKnobJ]);
  buf := buf + Format('- synchronous  swing: %.2fx'#10, [bestKnobS]);
  buf := buf + Format('- page_size    swing: %.2fx'#10, [bestKnobP]);
  buf := buf + Format('- cache_size   swing: %.2fx'#10, [bestKnobC]);

  buf := buf + #10'Cells flagged `crash` / `rc=N` / `no-total` indicate the '
              + 'corresponding binary failed in that configuration.'#10;

  ForceDirectories(ExtractFilePath(ArgOut));
  WriteFileStr(ArgOut, buf);
  Writeln;
  Writeln('PragmaMatrix: wrote ', ArgOut);
end.
