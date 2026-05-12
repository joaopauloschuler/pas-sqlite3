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
  TestVectorReadOnly.pas — Phase 9.2.2 read-only parity probe.

  Walks every `*.queries.sql` under src/tests/vectors/, opens the
  matching `<name>.db` in SQLITE_OPEN_READONLY mode under both the
  C oracle (libsqlite3.so via csqlite3) AND the Pascal port
  (passqlite3main), runs the script via sqlite3_exec with a row-printing
  callback (FormatRow contract = upstream `.mode list`: pipe-separated
  columns, NULL printed empty, '\n' terminator, no header line), and
  byte-diffs the captured stdout + stderr + rc.

  No writes performed — the gate is about read-side compatibility with
  files the port did not author.  Vectors tagged `pas-skip` or `[SKIP]`
  in MANIFEST.txt are skipped (corpus skip-and-cite contract).

  First divergence prints a one-screen summary (vector, channel, first
  16-byte window) and exits non-zero.  Re-uses CorpusOracle.pas's
  FormatRow + ApplyHeaderMask plumbing rather than re-implementing the
  row-printing contract.
}
program TestVectorReadOnly;

uses
  SysUtils, Classes,
  csqlite3,
  passqlite3types,
  passqlite3util,
  passqlite3os,
  passqlite3main;

var
  VectorDir: AnsiString;  { resolved at startup — see ResolveRepoRoot }

type
  PSinkBuf = ^AnsiString;

{ ----------------------------------------------------------------------
  Row-printing callback — mirrors CorpusOracle.FormatRow exactly.

  Upstream `.mode list` default formatting:
    * column values joined by '|'
    * NULL printed as an empty field (sqlite3_exec callback contract:
      argv[i] == NULL means SQL NULL)
    * single '\n' (LF) terminator after each row
    * no header line (.headers OFF is the default)
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
  Read-only execution helpers.  Both open the existing .db file via
  *_open_v2(SQLITE_OPEN_READONLY), run the script, capture rc + stdout
  + stderr, close.
  ---------------------------------------------------------------------- }

procedure RunCReadOnly(const dbPath, zSql: AnsiString;
                      out outStdout, outStderr: AnsiString;
                      out outRc: i32);
var
  db    : Pcsq_db;
  pzErr : PChar;
  rc    : i32;
  sink  : AnsiString;
begin
  outStdout := '';
  outStderr := '';
  outRc     := SQLITE_OK;
  db    := nil;
  pzErr := nil;

  rc := csq_open_v2(PChar(dbPath), db, SQLITE_OPEN_READONLY, nil);
  if rc <> SQLITE_OK then begin
    outRc := rc;
    if db <> nil then begin
      outStderr := AnsiString(csq_errmsg(db));
      csq_close(db);
    end;
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
end;

procedure RunPasReadOnly(const dbPath, zSql: AnsiString;
                        out outStdout, outStderr: AnsiString;
                        out outRc: i32);
var
  db    : PTsqlite3;
  pzErr : PAnsiChar;
  rc    : i32;
  sink  : AnsiString;
begin
  outStdout := '';
  outStderr := '';
  outRc     := SQLITE_OK;
  db    := nil;
  pzErr := nil;

  rc := sqlite3_open_v2(PAnsiChar(dbPath), @db, SQLITE_OPEN_READONLY, nil);
  if rc <> SQLITE_OK then begin
    outRc := rc;
    if db <> nil then begin
      outStderr := AnsiString(sqlite3_errmsg(db));
      sqlite3_close(db);
    end;
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

{ ----------------------------------------------------------------------
  MANIFEST.txt parser — reads the status tag for each vector.  Per
  9.2.1 the status legend is:  [X]  [~]  [SKIP]  -- column 2 of the
  table.  We treat [SKIP] as skip.  Additionally, an explicit
  `pas-skip` tag added by 9.2.2 follow-up (see DIVERGENCES.md) also
  skips the vector.  All other vectors are gated.
  ---------------------------------------------------------------------- }

type
  TStatusEntry = record
    name:   AnsiString;   { e.g. 'simple.db' }
    status: AnsiString;   { 'X', '~', 'SKIP', 'pas-skip' }
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
      { skip blank lines, headers, separators }
      if (line = '') or (line[1] = '-') or (line[1] = '=') then
        Continue;
      { rough column-1 == vector name (ends in .db).  Split on whitespace. }
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
      { 9.2.x override block: lines like `pas-skip simple.db ...` set the
        skip tag explicitly and override any earlier table-row status. }
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
      { strip [...] brackets }
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
  { pas-skip overrides win — scan once for the override. }
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
  Diff helpers.
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

procedure PrintDivergence(const vector, channel: AnsiString;
                          const cBlob, pBlob: AnsiString);
var
  diffPos: i32;
begin
  diffPos := FirstDiff(cBlob, pBlob);
  Writeln('---- DIVERGENCE ----');
  Writeln('  vector  : ', vector);
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
  { bin/TestVectorReadOnly → <repo>/bin → <repo> }
  Result := ExtractFilePath(ExcludeTrailingPathDelimiter(binDir));
  if (Length(Result) = 0) or (not DirectoryExists(Result + 'src/tests')) then
    Result := GetCurrentDir + PathDelim;
  Result := IncludeTrailingPathDelimiter(Result);
end;

{ ----------------------------------------------------------------------
  Walk every *.queries.sql under src/tests/vectors/.
  ---------------------------------------------------------------------- }

var
  manifest: TStatusList;
  sr: TSearchRec;
  qPath, dbName, dbPath, base, sql: AnsiString;
  status: AnsiString;
  cOut, cErr, pOut, pErr: AnsiString;
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
  Writeln('TestVectorReadOnly — 9.2.2 read-only parity probe');
  Writeln('Vector dir: ', VectorDir);
  Writeln('Manifest entries: ', Length(manifest));
  Writeln;

  if FindFirst(IncludeTrailingPathDelimiter(VectorDir) + '*.queries.sql',
               faAnyFile and not faDirectory, sr) = 0 then begin
    repeat
      qPath := IncludeTrailingPathDelimiter(VectorDir) + sr.Name;
      base := Copy(sr.Name, 1, Length(sr.Name) - Length('.queries.sql'));
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

      sql := ReadFileText(qPath);
      if sql = '' then begin
        Writeln('SKIP   ', dbName, '  (empty queries file)');
        Inc(totalSkipped);
        Continue;
      end;

      Inc(totalGated);
      RunCReadOnly(dbPath, sql, cOut, cErr, cRc);
      RunPasReadOnly(dbPath, sql, pOut, pErr, pRc);

      divergedThisVector := 0;
      if cRc <> pRc then begin
        Writeln('DIVERGE rc  ', dbName, ' : C=', cRc, ' Pas=', pRc);
        Inc(divergedThisVector);
      end;
      if cOut <> pOut then begin
        PrintDivergence(dbName, 'stdout', cOut, pOut);
        Inc(divergedThisVector);
      end;
      if cErr <> pErr then begin
        PrintDivergence(dbName, 'stderr', cErr, pErr);
        Inc(divergedThisVector);
      end;

      if divergedThisVector = 0 then begin
        Writeln('OK     ', dbName, '  (', Length(cOut), ' bytes stdout, rc=', cRc, ')');
        Inc(totalOk);
      end else begin
        Inc(totalDiverged);
        exitCode := 1;
      end;
    until FindNext(sr) <> 0;
    FindClose(sr);
  end else begin
    Writeln('ERROR: no *.queries.sql files found under ', VectorDir);
    Halt(2);
  end;

  Writeln;
  Writeln('Summary: gated=', totalGated, ' ok=', totalOk,
          ' diverged=', totalDiverged, ' skipped=', totalSkipped);
  if exitCode <> 0 then
    Writeln('FAIL: read-only parity divergence(s) above')
  else
    Writeln('PASS: all gated vectors byte-identical across both oracles');
  Halt(exitCode);
end.
