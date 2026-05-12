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
  CorpusOracle.pas — Phase 9.1.2 oracle runner helper.

  Exposes two procedures with identical signatures, one driven by the C
  oracle (csq_* via csqlite3.pas → libsqlite3.so) and one driven by the
  Pascal port (sqlite3_* via passqlite3main.pas).  Each takes a SQL
  script and an empty workdir, opens a fresh on-disk DB at
  <zWorkDir>/test.db, sqlite3_exec()'s the script with a row-printing
  callback that produces upstream's `.mode list` default formatting
  (pipe-separated columns, NULL printed empty, no header — matches the
  C shell's default and the sqlite3_exec callback's argv contract),
  captures rc and any error message into outStderr, closes the DB, and
  reads the .db file back into outDbBlob.

  This is an *in-process* helper — test binaries link against both
  oracle libraries (csqlite3 + passqlite3main) and call both
  procedures back-to-back from the same process.  See
  TestExplainParity for the existing dual-link pattern.
}
unit CorpusOracle;

interface

uses
  SysUtils, Classes,
  csqlite3,
  passqlite3types,
  passqlite3util,
  passqlite3os,
  passqlite3main;

procedure RunCOracle(const zSql: PAnsiChar; const zWorkDir: PAnsiChar;
                    out outStdout, outStderr: AnsiString;
                    out outRc: i32; out outDbBlob: AnsiString);

procedure RunPasOracle(const zSql: PAnsiChar; const zWorkDir: PAnsiChar;
                      out outStdout, outStderr: AnsiString;
                      out outRc: i32; out outDbBlob: AnsiString);

implementation

{ ----------------------------------------------------------------------
  Shared helpers: workdir clean-up + file read + .mode list row format.

  The row format mirrors the upstream shell `.mode list` default:
    * column values joined by '|'
    * NULL printed as an empty field (consistent with the sqlite3_exec
      callback contract: argv[i] == NULL means SQL NULL)
    * a single '\n' (LF) terminator after each row
    * no header line (.headers OFF is the default)

  Both oracles share the implementation so any reformatting drift is
  impossible by construction.
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

procedure WipeWorkDir(const zWorkDir: PAnsiChar);
var
  dir   : AnsiString;
  sr    : TSearchRec;
  path  : AnsiString;
begin
  dir := IncludeTrailingPathDelimiter(AnsiString(zWorkDir));
  if not DirectoryExists(dir) then begin
    ForceDirectories(dir);
    Exit;
  end;
  if FindFirst(dir + '*', faAnyFile, sr) = 0 then begin
    repeat
      if (sr.Name = '.') or (sr.Name = '..') then Continue;
      path := dir + sr.Name;
      if (sr.Attr and faDirectory) = 0 then
        DeleteFile(path);
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
end;

function ReadFileBlob(const path: AnsiString): AnsiString;
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
  C oracle.

  Open a fresh on-disk DB at <zWorkDir>/test.db, exec the script with a
  row-printing callback that appends to a per-call AnsiString, capture
  rc + pzErrMsg, close.
  ---------------------------------------------------------------------- }

type
  PSinkBuf = ^AnsiString;

function CRowCb(pArg: Pointer; argc: i32;
                argv: PPChar; colNames: PPChar): i32; cdecl;
begin
  PSinkBuf(pArg)^ := PSinkBuf(pArg)^ + FormatRow(argc, PPAnsiChar(argv));
  Result := 0;
end;

procedure RunCOracle(const zSql: PAnsiChar; const zWorkDir: PAnsiChar;
                    out outStdout, outStderr: AnsiString;
                    out outRc: i32; out outDbBlob: AnsiString);
var
  db      : Pcsq_db;
  dbPath  : AnsiString;
  pzErr   : PChar;
  rc      : i32;
  sink    : AnsiString;
begin
  outStdout := '';
  outStderr := '';
  outRc     := SQLITE_OK;
  outDbBlob := '';

  WipeWorkDir(zWorkDir);
  dbPath := IncludeTrailingPathDelimiter(AnsiString(zWorkDir)) + 'test.db';

  db    := nil;
  pzErr := nil;
  rc    := csq_open(PChar(dbPath), db);
  if rc <> SQLITE_OK then begin
    outRc := rc;
    if db <> nil then begin
      outStderr := AnsiString(csq_errmsg(db));
      csq_close(db);
    end;
    Exit;
  end;

  sink := '';
  rc := csq_exec(db, PChar(AnsiString(zSql)), @CRowCb, @sink, pzErr);
  outStdout := sink;
  outRc := rc;
  if pzErr <> nil then begin
    outStderr := AnsiString(pzErr);
    { pzErr is allocated by sqlite3_exec via sqlite3_malloc; release
      it via csq_free to mirror upstream lifecycle (avoids a leak that
      would skew valgrind, not the byte-compare). }
    csq_free(pzErr);
  end else if (rc <> SQLITE_OK) and (db <> nil) then
    outStderr := AnsiString(csq_errmsg(db));

  csq_close(db);
  outDbBlob := ReadFileBlob(dbPath);
end;

{ ----------------------------------------------------------------------
  Pascal oracle.

  Mirror of the C oracle, driven by the in-tree passqlite3 port.
  ---------------------------------------------------------------------- }

function PasRowCb(pArg: Pointer; nCol: i32;
                  argv: PPAnsiChar; colv: PPAnsiChar): i32; cdecl;
begin
  PSinkBuf(pArg)^ := PSinkBuf(pArg)^ + FormatRow(nCol, argv);
  Result := 0;
end;

procedure RunPasOracle(const zSql: PAnsiChar; const zWorkDir: PAnsiChar;
                      out outStdout, outStderr: AnsiString;
                      out outRc: i32; out outDbBlob: AnsiString);
var
  db      : PTsqlite3;
  dbPath  : AnsiString;
  pzErr   : PAnsiChar;
  rc      : i32;
  sink    : AnsiString;
begin
  outStdout := '';
  outStderr := '';
  outRc     := SQLITE_OK;
  outDbBlob := '';

  WipeWorkDir(zWorkDir);
  dbPath := IncludeTrailingPathDelimiter(AnsiString(zWorkDir)) + 'test.db';

  db    := nil;
  pzErr := nil;
  rc    := sqlite3_open(PAnsiChar(dbPath), @db);
  if rc <> SQLITE_OK then begin
    outRc := rc;
    if db <> nil then begin
      outStderr := AnsiString(sqlite3_errmsg(db));
      sqlite3_close(db);
    end;
    Exit;
  end;

  sink := '';
  rc := sqlite3_exec(db, zSql, @PasRowCb, @sink, @pzErr);
  outStdout := sink;
  outRc := rc;
  if pzErr <> nil then begin
    outStderr := AnsiString(pzErr);
    sqlite3_free(pzErr);
  end else if (rc <> SQLITE_OK) and (db <> nil) then
    outStderr := AnsiString(sqlite3_errmsg(db));

  sqlite3_close(db);
  outDbBlob := ReadFileBlob(dbPath);
end;

end.
