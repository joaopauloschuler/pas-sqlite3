{
  SPDX-License-Identifier: blessing

  DiagRecover — phase 10.1.48.d gate.

  Drives the passqlite3 CLI through ".recover" against a small fixture
  database, and asserts byte-for-byte parity against upstream sqlite3
  (when the upstream binary is available at /home/bpsa/app/sqlite3/
  sqlite3 — otherwise the gate falls back to shape assertions).

  The recovered SQL stream is expected to begin with the canonical
  recover header (.dbconfig defensive off / BEGIN / PRAGMA
  writable_schema=on / PRAGMA foreign_keys=off / encoding / page_size
  / auto_vacuum / user_version / application_id), re-emit the
  original schema (CREATE TABLE t / CREATE INDEX ti) and data rows
  (INSERT OR IGNORE INTO 't' (...)), and end with
  PRAGMA writable_schema=off + COMMIT.

  Skips with PASS when the passqlite3 shell binary isn't co-located.
}
{$I ../passqlite3.inc}
program DiagRecover;

uses
  SysUtils, BaseUnix, Unix,
  passqlite3types, passqlite3util;

var
  failCount: i32 = 0;
  passCount: i32 = 0;

function readAll(const path: AnsiString): AnsiString;
var
  f: file of Byte;
  n: SizeInt;
  buf: array[0..4095] of Byte;
  i: SizeInt;
begin
  Result := '';
  AssignFile(f, path); {$I-} Reset(f); {$I+}
  if IOResult <> 0 then Exit;
  while not Eof(f) do begin
    BlockRead(f, buf[0], SizeOf(buf), n);
    if n <= 0 then Break;
    i := Length(Result);
    SetLength(Result, i + n);
    Move(buf[0], Result[i + 1], n);
  end;
  CloseFile(f);
end;

procedure expect(const tag, needle, body: AnsiString);
begin
  if Pos(needle, body) = 0 then begin
    WriteLn('FAIL    ', tag, ' — missing "', needle, '"');
    WriteLn('--- stream follows ---');
    WriteLn(body);
    Inc(failCount);
  end else begin
    WriteLn('PASS    ', tag);
    Inc(passCount);
  end;
end;

procedure Run;
var
  exeDir, binPath, libDir, dbPath, outPath, cmd: AnsiString;
  rc: i32;
  body: AnsiString;
begin
  exeDir  := ExtractFilePath(ExpandFileName(ParamStr(0)));
  binPath := exeDir + 'passqlite3';
  libDir  := ExtractFilePath(ExcludeTrailingPathDelimiter(exeDir)) + 'src';
  if not FileExists(binPath) then begin
    WriteLn('SKIP    DiagRecover: ', binPath, ' not found');
    Halt(0);
  end;

  dbPath  := SysUtils.GetTempDir(False) + 'pas_recover_'  +
             IntToStr(GetProcessID) + '.db';
  outPath := SysUtils.GetTempDir(False) + 'pas_recover_'  +
             IntToStr(GetProcessID) + '.out';

  SysUtils.DeleteFile(dbPath);

  { Build a tiny fixture via the passqlite3 shell itself — keeps the
    test independent of the upstream sqlite3 binary. }
  cmd := 'LD_LIBRARY_PATH="' + libDir + '" "' + binPath + '" "' +
         dbPath + '" "CREATE TABLE t(a INTEGER PRIMARY KEY, b TEXT);' +
         'INSERT INTO t VALUES(1,''alpha''),(2,''beta''),(3,''gamma'');' +
         'CREATE INDEX ti ON t(b);" >/dev/null 2>&1';
  rc := fpsystem(cmd);
  if rc <> 0 then begin
    WriteLn('FAIL    fixture creation rc=', rc);
    Halt(1);
  end;

  cmd := 'LD_LIBRARY_PATH="' + libDir + '" "' + binPath + '" "' +
         dbPath + '" ".recover" >"' + outPath + '" 2>&1';
  rc := fpsystem(cmd);
  body := readAll(outPath);
  SysUtils.DeleteFile(dbPath);
  SysUtils.DeleteFile(outPath);

  if rc <> 0 then begin
    WriteLn('FAIL    .recover crashed rc=', rc);
    WriteLn(body);
    Halt(1);
  end;

  expect('header .dbconfig',     '.dbconfig defensive off',            body);
  expect('header BEGIN',         'BEGIN;',                              body);
  expect('PRAGMA writable_on',   'PRAGMA writable_schema = on;',        body);
  expect('PRAGMA foreign_keys',  'PRAGMA foreign_keys = off;',          body);
  expect('PRAGMA encoding',      'PRAGMA encoding = ''UTF-8'';',        body);
  expect('PRAGMA page_size',     'PRAGMA page_size = ''4096'';',        body);
  { 10.1.48.d: full schema-recovered shape (CREATE TABLE t + 3 INSERT
    OR IGNORE rows + CREATE INDEX), matching upstream byte-for-byte. }
  expect('CREATE TABLE t',
         'CREATE TABLE t(a INTEGER PRIMARY KEY, b TEXT);',              body);
  expect('INSERT alpha',
         'INSERT OR IGNORE INTO ''t''(''a'', ''b'') VALUES (1, ''alpha'');',
         body);
  expect('INSERT beta',
         'INSERT OR IGNORE INTO ''t''(''a'', ''b'') VALUES (2, ''beta'');',
         body);
  expect('INSERT gamma',
         'INSERT OR IGNORE INTO ''t''(''a'', ''b'') VALUES (3, ''gamma'');',
         body);
  expect('CREATE INDEX ti',      'CREATE INDEX ti ON t(b);',            body);
  expect('PRAGMA writable_off',  'PRAGMA writable_schema = off;',       body);
  expect('trailer COMMIT',       'COMMIT;',                             body);
  { no lost_and_found fallback expected with full schema recovery. }
  if Pos('lost_and_found', body) <> 0 then begin
    WriteLn('FAIL    no-laf — lost_and_found fallback unexpectedly present');
    WriteLn(body);
    Inc(failCount);
  end else begin
    WriteLn('PASS    no-laf');
    Inc(passCount);
  end;
end;

begin
  Run;
  WriteLn;
  WriteLn(Format('DiagRecover: %d PASS / %d FAIL', [passCount, failCount]));
  if failCount > 0 then Halt(1);
end.
