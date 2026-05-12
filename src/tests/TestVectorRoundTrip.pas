{
  SPDX-License-Identifier: blessing

  The author disclaims copyright to this source code.  In place of
  a legal notice, here is a blessing:

     May you do good and not evil.
     May you find forgiveness for yourself and forgive others.
     May you share freely, never taking more than you give.

  ------------------------------------------------------------------------

  This work is dedicated to all human kind, and also to all non-human kinds.

  This is a faithful port of SQLite 3.53 (https://sqlite.org/) from C to
  Free Pascal, authored by Dr. Joao Paulo Schwarz Schuler and contributors
  (see commit history). The original SQLite C source code is in the public
  domain, authored by D. Richard Hipp and contributors. This Pascal port
  adopts the same public-domain posture.
}
{$I ../passqlite3.inc}
{
  TestVectorRoundTrip.pas — Phase 9.2.3 round-trip mutator probe.

  Walks every `*.mutate.sql` under src/tests/vectors/, copies the source
  `<name>.db` into two fresh workdirs (one for the C oracle, one for the
  Pascal port), opens RW, executes the mutator script (a single explicit
  BEGIN ... COMMIT transaction), closes, then byte-diffs the resulting
  blobs after applying CorpusOracle.ApplyHeaderMask (the existing 9.1.4
  header mask).

  Vectors tagged `pas-skip` or `[SKIP]` in MANIFEST.txt are skipped (corpus
  skip-and-cite contract).  Each divergence prints a one-screen summary
  (vector, channel, first 16-byte window) and the binary exits rc=1.

  Re-uses CorpusOracle.pas's ApplyHeaderMask plumbing rather than
  re-implementing the mask offsets.
}
program TestVectorRoundTrip;

uses
  SysUtils, Classes,
  csqlite3,
  passqlite3types,
  passqlite3util,
  passqlite3os,
  passqlite3main,
  CorpusOracle;

var
  VectorDir: AnsiString;  { resolved at startup — see ResolveRepoRoot }

type
  PSinkBuf = ^AnsiString;

{ ----------------------------------------------------------------------
  Row-printing callback (mutator scripts may emit no rows, but PRAGMA
  arms in incrvacuum.mutate.sql do — keep the contract identical to
  CorpusOracle/TestVectorReadOnly so accidental output divergences
  surface).  Mirrors CorpusOracle.FormatRow exactly.
  ---------------------------------------------------------------------- }

function FormatRow(nCol: i32; argv: PPAnsiChar): AnsiString;
var
  i: i32;
  pp: PPAnsiChar;
  cell: PAnsiChar;
begin
  Result := '';
  pp := argv;
  for i := 0 to nCol - 1 do begin
    if i > 0 then Result := Result + '|';
    cell := pp^;
    if cell <> nil then
      Result := Result + AnsiString(cell);
    Inc(pp);
  end;
  Result := Result + #10;
end;

function CRowCb(pArg: Pointer; argc: i32;
                argv: PPChar; colNames: PPChar): i32; cdecl;
begin
  PSinkBuf(pArg)^ := PSinkBuf(pArg)^ + FormatRow(argc, PPAnsiChar(argv));
  Result := 0;
end;

function PasRowCb(pArg: Pointer; nCol: i32;
                  argv: PPAnsiChar; colv: PPAnsiChar): i32; cdecl;
begin
  PSinkBuf(pArg)^ := PSinkBuf(pArg)^ + FormatRow(nCol, argv);
  Result := 0;
end;

{ ----------------------------------------------------------------------
  File / directory helpers.
  ---------------------------------------------------------------------- }

function ReadFileText(const path: AnsiString): AnsiString;
var
  st: TFileStream;
begin
  Result := '';
  if not FileExists(path) then Exit;
  st := TFileStream.Create(path, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, st.Size);
    if st.Size > 0 then st.ReadBuffer(Result[1], st.Size);
  finally
    st.Free;
  end;
end;

procedure WriteFileBlob(const path: AnsiString; const blob: AnsiString);
var
  st: TFileStream;
begin
  st := TFileStream.Create(path, fmCreate);
  try
    if Length(blob) > 0 then st.WriteBuffer(blob[1], Length(blob));
  finally
    st.Free;
  end;
end;

procedure WipeDir(const dir: AnsiString);
var
  sr: TSearchRec;
  full: AnsiString;
begin
  if not DirectoryExists(dir) then begin
    ForceDirectories(dir);
    Exit;
  end;
  if FindFirst(IncludeTrailingPathDelimiter(dir) + '*', faAnyFile, sr) = 0 then begin
    repeat
      if (sr.Name = '.') or (sr.Name = '..') then Continue;
      full := IncludeTrailingPathDelimiter(dir) + sr.Name;
      if (sr.Attr and faDirectory) = 0 then DeleteFile(full);
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
end;

{ ----------------------------------------------------------------------
  Round-trip helpers.  Both copy the seed `.db` into a clean workdir,
  open RW (default flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE),
  exec the mutator script, capture rc + stdout + stderr, close, then
  read the resulting blob.
  ---------------------------------------------------------------------- }

procedure RunCRoundTrip(const seedPath, workDir, zSql: AnsiString;
                        out outStdout, outStderr: AnsiString;
                        out outRc: i32; out outDbBlob: AnsiString);
var
  db    : Pcsq_db;
  dbPath: AnsiString;
  pzErr : PChar;
  rc    : i32;
  sink  : AnsiString;
  seed  : AnsiString;
begin
  outStdout := '';
  outStderr := '';
  outRc     := SQLITE_OK;
  outDbBlob := '';

  WipeDir(workDir);
  dbPath := IncludeTrailingPathDelimiter(workDir) + 'test.db';
  seed := ReadFileText(seedPath);
  WriteFileBlob(dbPath, seed);

  db    := nil;
  pzErr := nil;
  rc    := csq_open(PChar(dbPath), db);
  if rc <> SQLITE_OK then begin
    outRc := rc;
    if db <> nil then begin
      outStderr := AnsiString(csq_errmsg(db));
      csq_close(db);
    end;
    outDbBlob := ReadFileText(dbPath);
    Exit;
  end;

  sink := '';
  rc := csq_exec(db, PChar(zSql), @CRowCb, @sink, pzErr);
  outStdout := sink;
  outRc := rc;
  if pzErr <> nil then begin
    outStderr := AnsiString(pzErr);
    csq_free(pzErr);
  end else if (rc <> SQLITE_OK) and (db <> nil) then
    outStderr := AnsiString(csq_errmsg(db));
  csq_close(db);
  outDbBlob := ReadFileText(dbPath);
end;

procedure RunPasRoundTrip(const seedPath, workDir, zSql: AnsiString;
                          out outStdout, outStderr: AnsiString;
                          out outRc: i32; out outDbBlob: AnsiString);
var
  db    : PTsqlite3;
  dbPath: AnsiString;
  pzErr : PAnsiChar;
  rc    : i32;
  sink  : AnsiString;
  seed  : AnsiString;
begin
  outStdout := '';
  outStderr := '';
  outRc     := SQLITE_OK;
  outDbBlob := '';

  WipeDir(workDir);
  dbPath := IncludeTrailingPathDelimiter(workDir) + 'test.db';
  seed := ReadFileText(seedPath);
  WriteFileBlob(dbPath, seed);

  db    := nil;
  pzErr := nil;
  rc    := sqlite3_open(PAnsiChar(dbPath), @db);
  if rc <> SQLITE_OK then begin
    outRc := rc;
    if db <> nil then begin
      outStderr := AnsiString(sqlite3_errmsg(db));
      sqlite3_close(db);
    end;
    outDbBlob := ReadFileText(dbPath);
    Exit;
  end;

  sink := '';
  rc := sqlite3_exec(db, PAnsiChar(zSql), @PasRowCb, @sink, @pzErr);
  outStdout := sink;
  outRc := rc;
  if pzErr <> nil then begin
    outStderr := AnsiString(pzErr);
    sqlite3_free(pzErr);
  end else if (rc <> SQLITE_OK) and (db <> nil) then
    outStderr := AnsiString(sqlite3_errmsg(db));
  sqlite3_close(db);
  outDbBlob := ReadFileText(dbPath);
end;

{ ----------------------------------------------------------------------
  MANIFEST.txt parser — copy of TestVectorReadOnly's parser.  Same
  legend: [X] / [~] / [SKIP] in column 2, plus explicit `pas-skip`
  override lines in the trailing block.
  ---------------------------------------------------------------------- }

type
  TStatusEntry = record
    name:   AnsiString;
    status: AnsiString;
  end;
  TStatusList = array of TStatusEntry;

procedure LoadManifest(out list: TStatusList);
var
  manifestPath: AnsiString;
  raw: AnsiString;
  lines: TStringList;
  i: i32;
  line: AnsiString;
  parts: TStringList;
  j: i32;
  toks: array of AnsiString;
  name, status: AnsiString;
begin
  SetLength(list, 0);
  manifestPath := IncludeTrailingPathDelimiter(VectorDir) + 'MANIFEST.txt';
  raw := ReadFileText(manifestPath);
  if raw = '' then begin
    Writeln('WARN: MANIFEST.txt not found at ', manifestPath, '; treating all vectors as gated.');
    Exit;
  end;
  lines := TStringList.Create;
  parts := TStringList.Create;
  try
    lines.Text := raw;
    for i := 0 to lines.Count - 1 do begin
      line := Trim(lines[i]);
      if (line = '') or (line[1] = '-') or (line[1] = '=') then Continue;
      parts.Clear;
      parts.Delimiter := ' ';
      parts.StrictDelimiter := False;
      parts.DelimitedText := line;
      SetLength(toks, 0);
      for j := 0 to parts.Count - 1 do
        if Trim(parts[j]) <> '' then begin
          SetLength(toks, Length(toks) + 1);
          toks[High(toks)] := Trim(parts[j]);
        end;
      if Length(toks) < 2 then Continue;
      if toks[0] = 'pas-skip' then begin
        name := toks[1];
        if Pos('.db', name) <> Length(name) - 2 then Continue;
        SetLength(list, Length(list) + 1);
        list[High(list)].name := name;
        list[High(list)].status := 'pas-skip';
        Continue;
      end;
      name := toks[0];
      if Pos('.db', name) <> Length(name) - 2 then Continue;
      status := toks[1];
      if (Length(status) >= 2) and (status[1] = '[') and
         (status[Length(status)] = ']') then
        status := Copy(status, 2, Length(status) - 2);
      SetLength(list, Length(list) + 1);
      list[High(list)].name := name;
      list[High(list)].status := status;
    end;
  finally
    parts.Free;
    lines.Free;
  end;
end;

function ManifestStatus(const list: TStatusList; const name: AnsiString): AnsiString;
var
  i: i32;
begin
  for i := 0 to High(list) do
    if (list[i].name = name) and (list[i].status = 'pas-skip') then begin
      Result := 'pas-skip';
      Exit;
    end;
  for i := 0 to High(list) do
    if list[i].name = name then begin
      Result := list[i].status;
      Exit;
    end;
  Result := '';
end;

{ ----------------------------------------------------------------------
  Diff helpers — copy of TestVectorReadOnly.
  ---------------------------------------------------------------------- }

function FirstDiff(const a, b: AnsiString): i32;
var
  i, n: i32;
begin
  if Length(a) < Length(b) then n := Length(a) else n := Length(b);
  for i := 1 to n do
    if a[i] <> b[i] then begin
      Result := i;
      Exit;
    end;
  if Length(a) <> Length(b) then Result := n + 1
  else Result := 0;
end;

function HexWindow(const s: AnsiString; pos1: i32; n: i32): AnsiString;
var
  i, lo, hi: i32;
  b: byte;
begin
  Result := '';
  if pos1 < 1 then pos1 := 1;
  lo := pos1;
  hi := pos1 + n - 1;
  if hi > Length(s) then hi := Length(s);
  for i := lo to hi do begin
    b := Byte(s[i]);
    if Result <> '' then Result := Result + ' ';
    Result := Result + LowerCase(IntToHex(b, 2));
  end;
end;

function PrintableWindow(const s: AnsiString; pos1: i32; n: i32): AnsiString;
var
  i, lo, hi: i32;
  c: AnsiChar;
begin
  Result := '';
  if pos1 < 1 then pos1 := 1;
  lo := pos1;
  hi := pos1 + n - 1;
  if hi > Length(s) then hi := Length(s);
  for i := lo to hi do begin
    c := s[i];
    if (c >= ' ') and (c < #127) then Result := Result + c
    else Result := Result + '.';
  end;
end;

procedure PrintDivergence(const vector, mutator, channel: AnsiString;
                          const cBlob, pBlob: AnsiString);
var
  diffPos: i32;
begin
  diffPos := FirstDiff(cBlob, pBlob);
  Writeln('---- DIVERGENCE ----');
  Writeln('  vector  : ', vector);
  Writeln('  mutator : ', mutator);
  Writeln('  channel : ', channel);
  Writeln('  C  len  : ', Length(cBlob));
  Writeln('  Pas len : ', Length(pBlob));
  Writeln('  first diff at byte (1-based) : ', diffPos);
  Writeln('  C  hex window : ', HexWindow(cBlob, diffPos, 16));
  Writeln('  C  asc window : "', PrintableWindow(cBlob, diffPos, 16), '"');
  Writeln('  Pas hex window: ', HexWindow(pBlob, diffPos, 16));
  Writeln('  Pas asc window: "', PrintableWindow(pBlob, diffPos, 16), '"');
  Writeln('--------------------');
end;

function ResolveRepoRoot: AnsiString;
var
  binPath, binDir: AnsiString;
begin
  binPath := ExpandFileName(ParamStr(0));
  binDir := ExtractFilePath(binPath);
  Result := ExtractFilePath(ExcludeTrailingPathDelimiter(binDir));
  if (Length(Result) = 0) or (not DirectoryExists(Result + 'src/tests')) then
    Result := GetCurrentDir + PathDelim;
  Result := IncludeTrailingPathDelimiter(Result);
end;

{ ----------------------------------------------------------------------
  Walk every *.mutate.sql under src/tests/vectors/.
  ---------------------------------------------------------------------- }

var
  manifest: TStatusList;
  sr: TSearchRec;
  mPath, dbName, dbPath, base, sql: AnsiString;
  status: AnsiString;
  tmpRoot, cWork, pWork: AnsiString;
  cOut, cErr, pOut, pErr, cBlob, pBlob: AnsiString;
  cRc, pRc: i32;
  totalGated, totalSkipped, totalDiverged, totalOk: i32;
  exitCode: i32;
  divergedThisVector: i32;
begin
  totalGated := 0;
  totalSkipped := 0;
  totalDiverged := 0;
  totalOk := 0;
  exitCode := 0;

  VectorDir := ResolveRepoRoot + 'src/tests/vectors';
  LoadManifest(manifest);
  Writeln('TestVectorRoundTrip — 9.2.3 round-trip mutator probe');
  Writeln('Vector dir: ', VectorDir);
  Writeln('Manifest entries: ', Length(manifest));
  Writeln;

  tmpRoot := IncludeTrailingPathDelimiter(GetTempDir) + 'pas-sqlite3-rt';
  ForceDirectories(tmpRoot);

  if FindFirst(IncludeTrailingPathDelimiter(VectorDir) + '*.mutate.sql',
               faAnyFile and not faDirectory, sr) = 0 then begin
    repeat
      mPath := IncludeTrailingPathDelimiter(VectorDir) + sr.Name;
      base := Copy(sr.Name, 1, Length(sr.Name) - Length('.mutate.sql'));
      dbName := base + '.db';
      dbPath := IncludeTrailingPathDelimiter(VectorDir) + dbName;

      status := ManifestStatus(manifest, dbName);

      if (status = 'SKIP') or (status = 'pas-skip') then begin
        Writeln('SKIP   ', dbName, '  (status=', status, ')');
        Inc(totalSkipped);
        Continue;
      end;

      if not FileExists(dbPath) then begin
        Writeln('SKIP   ', dbName, '  (no .db blob — script-only entry)');
        Inc(totalSkipped);
        Continue;
      end;

      sql := ReadFileText(mPath);
      if sql = '' then begin
        Writeln('SKIP   ', dbName, '  (empty mutator file)');
        Inc(totalSkipped);
        Continue;
      end;

      Inc(totalGated);
      cWork := IncludeTrailingPathDelimiter(tmpRoot) + base + '-c';
      pWork := IncludeTrailingPathDelimiter(tmpRoot) + base + '-pas';

      RunCRoundTrip(dbPath, cWork, sql, cOut, cErr, cRc, cBlob);
      RunPasRoundTrip(dbPath, pWork, sql, pOut, pErr, pRc, pBlob);

      ApplyHeaderMask(cBlob);
      ApplyHeaderMask(pBlob);

      divergedThisVector := 0;
      if cRc <> pRc then begin
        Writeln('DIVERGE rc  ', dbName, ' : C=', cRc, ' Pas=', pRc);
        Writeln('  C  stderr: ', cErr);
        Writeln('  Pas stderr: ', pErr);
        Inc(divergedThisVector);
      end;
      if cOut <> pOut then begin
        PrintDivergence(dbName, sr.Name, 'stdout', cOut, pOut);
        Inc(divergedThisVector);
      end;
      if cErr <> pErr then begin
        PrintDivergence(dbName, sr.Name, 'stderr', cErr, pErr);
        Inc(divergedThisVector);
      end;
      if cBlob <> pBlob then begin
        PrintDivergence(dbName, sr.Name, 'db-blob (post-mask)', cBlob, pBlob);
        Inc(divergedThisVector);
      end;

      if divergedThisVector = 0 then begin
        Writeln('OK     ', dbName, '  (', Length(cBlob), ' byte blob, rc=', cRc, ')');
        Inc(totalOk);
      end else begin
        Inc(totalDiverged);
        exitCode := 1;
      end;
    until FindNext(sr) <> 0;
    FindClose(sr);
  end else begin
    Writeln('ERROR: no *.mutate.sql files found under ', VectorDir);
    Halt(2);
  end;

  Writeln;
  Writeln('Summary: gated=', totalGated, ' ok=', totalOk,
          ' diverged=', totalDiverged, ' skipped=', totalSkipped);
  if exitCode <> 0 then
    Writeln('FAIL: round-trip parity divergence(s) above')
  else
    Writeln('PASS: all gated vectors byte-identical post-mutator across both oracles');
  Halt(exitCode);
end.
