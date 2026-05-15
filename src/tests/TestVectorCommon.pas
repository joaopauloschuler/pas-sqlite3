{
  SPDX-License-Identifier: blessing

  This work is dedicated to all human kind, and also to all non-human kinds.

  Faithful port of SQLite 3 (https://sqlite.org/) from C to Free Pascal.
}
{$I ../passqlite3.inc}
{
  TestVectorCommon — shared harness for TestVectorRoundTrip /
  TestVectorSchemaChange (Phase 9.2.3 / 9.2.4 vector probes).

  Both binaries copy a seed `<name>.db` into two fresh workdirs (C oracle
  side + Pascal port side), open RW, exec a mutator/schema script, capture
  rc + stdout + stderr, close, then byte-diff the resulting blob after
  applying CorpusOracle.ApplyHeaderMask.  The scaffolding around that —
  file/dir helpers, row-printing callbacks, the two exec runners, the
  diff/window/print helpers, and the binary-relative repo-root resolver —
  was duplicated byte-for-byte between the two .pas files.

  This unit hoists that scaffolding.  Per-program differences that remain
  inline in each program:
    * MANIFEST.txt parser shape — round-trip honours a flat `pas-skip`
      block; schema-change splits the cite on commas and only honours
      non-bucket-A skips.  Different record layouts, different shape.
    * The walk loop itself — different glob (`*.mutate.sql` vs
      `*.schema.sql`), different tmpRoot suffix, different banner /
      summary strings.

  PrintDivergence takes a `mutatorLabel` parameter so each program can
  keep its own column header ("mutator" for round-trip, "script" for
  schema-change) without forking the body.
}
unit TestVectorCommon;

interface

uses
  SysUtils, Classes,
  csqlite3,
  passqlite3types,
  passqlite3util,
  passqlite3os,
  passqlite3main;

type
  PSinkBuf = ^AnsiString;

{ Row-printing callbacks — mirror CorpusOracle.FormatRow exactly so
  accidental output divergences surface.  cdecl on both because both
  the C oracle (csq_exec) and the Pascal port (sqlite3_exec) take a
  cdecl callback. }

function FormatRow(nCol: i32; argv: PPAnsiChar): AnsiString;
function CRowCb(pArg: Pointer; argc: i32;
                argv: PPChar; colNames: PPChar): i32; cdecl;
function PasRowCb(pArg: Pointer; nCol: i32;
                  argv: PPAnsiChar; colv: PPAnsiChar): i32; cdecl;

{ File / directory helpers. }
function ReadFileText(const path: AnsiString): AnsiString;
procedure WriteFileBlob(const path: AnsiString; const blob: AnsiString);
procedure WipeDir(const dir: AnsiString);

{ Exec runners.  Both copy the seed `.db` into a clean workdir, open RW
  (default flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE), exec the
  script, capture rc + stdout + stderr, close, then read the resulting
  blob back into outDbBlob. }
procedure RunCExec(const seedPath, workDir, zSql: AnsiString;
                   out outStdout, outStderr: AnsiString;
                   out outRc: i32; out outDbBlob: AnsiString);
procedure RunPasExec(const seedPath, workDir, zSql: AnsiString;
                     out outStdout, outStderr: AnsiString;
                     out outRc: i32; out outDbBlob: AnsiString);

{ Read-only runners.  Open the existing dbPath via *_open_v2 with
  SQLITE_OPEN_READONLY, exec the script, capture rc + stdout + stderr,
  close.  No workdir copy, no blob readback — the gate is read-side
  output parity, not file mutation parity (used by TestVectorReadOnly). }
procedure RunCReadOnly(const dbPath, zSql: AnsiString;
                       out outStdout, outStderr: AnsiString;
                       out outRc: i32);
procedure RunPasReadOnly(const dbPath, zSql: AnsiString;
                         out outStdout, outStderr: AnsiString;
                         out outRc: i32);

{ Diff / window helpers. }
function FirstDiff(const a, b: AnsiString): i32;
function HexWindow(const s: AnsiString; pos1: i32; n: i32): AnsiString;
function PrintableWindow(const s: AnsiString; pos1: i32; n: i32): AnsiString;

{ mutatorLabel is the column header for the script-path line; round-trip
  uses 'mutator', schema-change uses 'script '.  (Trailing space kept by
  the caller to align with the 7-char widest label.) }
procedure PrintDivergence(const vector, mutator, channel: AnsiString;
                          const cBlob, pBlob: AnsiString;
                          const mutatorLabel: AnsiString);

{ Read-only variant — no mutator/script line.  Used by TestVectorReadOnly
  which gates queries.sql vectors that have no per-vector mutator. }
procedure PrintDivergenceRO(const vector, channel: AnsiString;
                            const cBlob, pBlob: AnsiString);

function ResolveRepoRoot: AnsiString;

implementation

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

procedure RunCExec(const seedPath, workDir, zSql: AnsiString;
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

procedure RunPasExec(const seedPath, workDir, zSql: AnsiString;
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
                          const cBlob, pBlob: AnsiString;
                          const mutatorLabel: AnsiString);
var
  diffPos: i32;
begin
  diffPos := FirstDiff(cBlob, pBlob);
  Writeln('---- DIVERGENCE ----');
  Writeln('  vector  : ', vector);
  Writeln('  ', mutatorLabel, ' : ', mutator);
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

procedure PrintDivergenceRO(const vector, channel: AnsiString;
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
  Result := ExtractFilePath(ExcludeTrailingPathDelimiter(binDir));
  if (Length(Result) = 0) or (not DirectoryExists(Result + 'src/tests')) then
    Result := GetCurrentDir + PathDelim;
  Result := IncludeTrailingPathDelimiter(Result);
end;

end.
