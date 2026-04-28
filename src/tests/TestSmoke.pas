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
program TestSmoke;

{
  Phase 0.8 — Smoke test for the build system and csqlite3 bindings.

  Validates that:
    1. libsqlite3.so loads and csq_libversion() returns a non-empty string.
    2. csq_open_v2(":memory:", ...) succeeds.
    3. A trivial "SELECT 1;" prepared, stepped, and finalised returns SQLITE_DONE.
    4. The result column value equals 1.
    5. csq_close() succeeds.

  Any failure prints a clear message and exits with code 1.
  Success exits with code 0.

  Run with:
    LD_LIBRARY_PATH=src/ bin/TestSmoke
}

uses
  SysUtils,
  passqlite3types,
  csqlite3;

procedure Fail(const msg: string);
begin
  WriteLn('FAIL: ', msg);
  Halt(1);
end;

procedure Check(rc: Int32; const op: string);
begin
  if rc <> SQLITE_OK then
    Fail(op + ' returned ' + IntToStr(rc));
end;

var
  db:   Pcsq_db;
  stmt: Pcsq_stmt;
  tail: PChar;
  rc:   Int32;
  ver:  PChar;
  val:  Int32;
begin
  { 1. Library version }
  ver := csq_libversion;
  if (ver = nil) or (ver^ = #0) then
    Fail('csq_libversion returned empty string');
  WriteLn('sqlite3 version : ', ver);

  { 2. Open in-memory database }
  rc := csq_open_v2(':memory:', db,
        SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE, nil);
  Check(rc, 'csq_open_v2');
  WriteLn('csq_open_v2     : OK');

  { 3. Prepare "SELECT 1;" }
  rc := csq_prepare_v2(db, 'SELECT 1;', -1, stmt, tail);
  Check(rc, 'csq_prepare_v2');
  WriteLn('csq_prepare_v2  : OK');

  { 4. Step — expect SQLITE_ROW }
  rc := csq_step(stmt);
  if rc <> SQLITE_ROW then
    Fail('csq_step expected SQLITE_ROW (' + IntToStr(SQLITE_ROW) +
         '), got ' + IntToStr(rc));
  WriteLn('csq_step        : SQLITE_ROW');

  { 5. Read column 0 — expect integer 1 }
  val := csq_column_int(stmt, 0);
  if val <> 1 then
    Fail('csq_column_int expected 1, got ' + IntToStr(val));
  WriteLn('column value    : ', val);

  { 6. Step again — expect SQLITE_DONE }
  rc := csq_step(stmt);
  if rc <> SQLITE_DONE then
    Fail('second csq_step expected SQLITE_DONE (' + IntToStr(SQLITE_DONE) +
         '), got ' + IntToStr(rc));
  WriteLn('csq_step (done) : SQLITE_DONE');

  { 7. Finalize }
  Check(csq_finalize(stmt), 'csq_finalize');
  WriteLn('csq_finalize    : OK');

  { 8. Close }
  Check(csq_close(db), 'csq_close');
  WriteLn('csq_close       : OK');

  WriteLn;
  WriteLn('TestSmoke PASSED.');
end.
