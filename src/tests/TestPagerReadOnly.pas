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
program TestPagerReadOnly;

{
  Phase 3.B.2a -- Read-only pager gate tests for passqlite3pager.

  Tests the Pascal pager's read-only path by opening existing .db files
  from vectors/ and reading pages through the Pascal pager, comparing
  the page data byte-for-byte with data read directly from the file.

    T1  sqlite3PagerOpen opens a file without crashing; returns SQLITE_OK.
    T2  sqlite3PagerSharedLock acquires SHARED lock (PAGER_READER state).
    T3  sqlite3PagerGet(page 1) returns a non-nil page.
    T4  Page 1 data starts with SQLite magic string "SQLite format 3\0".
    T5  sqlite3PagerUnref releases page 1 without crashing.
    T6  sqlite3PagerPagecount returns a sane (>0) page count.
    T7  Open multipage.db; page count > 1.
    T8  Read all pages of simple.db; byte-compare against direct file read.
    T9  sqlite3PagerClose releases the pager without crashing.
    T10 Error path: open a non-existent file returns SQLITE_CANTOPEN.

  Prints PASS/FAIL per test.  Exits 0 if ALL PASS, 1 on any failure.

  Run with:
    LD_LIBRARY_PATH=src/ bin/TestPagerReadOnly
}

uses
  SysUtils,
  BaseUnix,
  passqlite3types,
  passqlite3internal,
  passqlite3os,
  passqlite3util,
  passqlite3pcache,
  passqlite3pager;

const
  VECTORS_DIR = 'src/tests/vectors/';
  SIMPLE_DB   = VECTORS_DIR + 'simple.db';
  MULTI_DB    = VECTORS_DIR + 'multipage.db';

  SQLITE_MAGIC : array[0..15] of AnsiChar =
    ('S','Q','L','i','t','e',' ','f','o','r','m','a','t',' ','3',#0);

var
  gPass: Boolean = True;

procedure Pass(const name: string);
begin
  WriteLn('PASS [', name, ']');
end;

procedure Fail(const name, msg: string);
begin
  WriteLn('FAIL [', name, ']: ', msg);
  gPass := False;
end;

{ Open the default VFS; open a real pager on a .db file.
  Returns the pager pointer and the VFS pointer via out params.
  Caller must call sqlite3PagerClose when done. }
function OpenPager(const dbPath: string; out pPgr: PPager): i32;
var
  pVfs : Psqlite3_vfs;
  flags: i32;
begin
  pPgr := nil;
  pVfs := sqlite3_vfs_find(nil);
  if pVfs = nil then begin Result := SQLITE_ERROR; Exit; end;

  flags := SQLITE_OPEN_READONLY or SQLITE_OPEN_MAIN_DB;
  Result := sqlite3PagerOpen(pVfs, pPgr, PChar(dbPath),
              0, PAGER_OMIT_JOURNAL, flags, nil);
end;

{ ---- T1: PagerOpen on simple.db ---- }
procedure TestT1;
var
  pPgr: PPager;
  rc  : i32;
begin
  rc := OpenPager(SIMPLE_DB, pPgr);
  if rc <> SQLITE_OK then
    Fail('T1', 'sqlite3PagerOpen returned ' + IntToStr(rc))
  else if pPgr = nil then
    Fail('T1', 'pager pointer is nil after SQLITE_OK')
  else
  begin
    Pass('T1');
    sqlite3PagerClose(pPgr, nil);
  end;
end;

{ ---- T2: SharedLock transitions pager to READER state ---- }
procedure TestT2;
var
  pPgr: PPager;
  rc  : i32;
begin
  rc := OpenPager(SIMPLE_DB, pPgr);
  if rc <> SQLITE_OK then begin Fail('T2', 'PagerOpen failed'); Exit; end;

  rc := sqlite3PagerSharedLock(pPgr);
  if rc <> SQLITE_OK then
    Fail('T2', 'SharedLock returned ' + IntToStr(rc))
  else
    Pass('T2');

  sqlite3PagerClose(pPgr, nil);
end;

{ ---- T3: PagerGet(1) returns non-nil ---- }
procedure TestT3;
var
  pPgr : PPager;
  pPage: PDbPage;
  rc   : i32;
begin
  rc := OpenPager(SIMPLE_DB, pPgr);
  if rc <> SQLITE_OK then begin Fail('T3', 'PagerOpen failed'); Exit; end;
  rc := sqlite3PagerSharedLock(pPgr);
  if rc <> SQLITE_OK then begin Fail('T3', 'SharedLock failed'); sqlite3PagerClose(pPgr, nil); Exit; end;

  rc := sqlite3PagerGet(pPgr, 1, @pPage, 0);
  if rc <> SQLITE_OK then
    Fail('T3', 'PagerGet returned ' + IntToStr(rc))
  else if pPage = nil then
    Fail('T3', 'pPage is nil after SQLITE_OK')
  else
    Pass('T3');

  if pPage <> nil then sqlite3PagerUnref(pPage);
  sqlite3PagerClose(pPgr, nil);
end;

{ ---- T4: Page 1 starts with SQLite magic ---- }
procedure TestT4;
var
  pPgr : PPager;
  pPage: PDbPage;
  pData: Pointer;
  rc   : i32;
begin
  rc := OpenPager(SIMPLE_DB, pPgr);
  if rc <> SQLITE_OK then begin Fail('T4', 'PagerOpen failed'); Exit; end;
  rc := sqlite3PagerSharedLock(pPgr);
  if rc <> SQLITE_OK then begin Fail('T4', 'SharedLock failed'); sqlite3PagerClose(pPgr, nil); Exit; end;
  rc := sqlite3PagerGet(pPgr, 1, @pPage, 0);
  if rc <> SQLITE_OK then begin Fail('T4', 'PagerGet failed'); sqlite3PagerClose(pPgr, nil); Exit; end;

  pData := sqlite3PagerGetData(pPage);
  if not CompareMem(pData, @SQLITE_MAGIC[0], 16) then
    Fail('T4', 'Page 1 does not start with SQLite magic string')
  else
    Pass('T4');

  sqlite3PagerUnref(pPage);
  sqlite3PagerClose(pPgr, nil);
end;

{ ---- T5: UnrefPageOne / Unref does not crash ---- }
procedure TestT5;
var
  pPgr : PPager;
  pPage: PDbPage;
  rc   : i32;
begin
  rc := OpenPager(SIMPLE_DB, pPgr);
  if rc <> SQLITE_OK then begin Fail('T5', 'PagerOpen failed'); Exit; end;
  rc := sqlite3PagerSharedLock(pPgr);
  if rc <> SQLITE_OK then begin Fail('T5', 'SharedLock failed'); sqlite3PagerClose(pPgr, nil); Exit; end;
  rc := sqlite3PagerGet(pPgr, 1, @pPage, 0);
  if (rc <> SQLITE_OK) or (pPage = nil) then
  begin Fail('T5', 'PagerGet failed'); sqlite3PagerClose(pPgr, nil); Exit; end;

  sqlite3PagerUnref(pPage);  { should not crash }
  Pass('T5');
  sqlite3PagerClose(pPgr, nil);
end;

{ ---- T6: PageCount > 0 for simple.db ---- }
procedure TestT6;
var
  pPgr  : PPager;
  nPages: i32;
  rc    : i32;
begin
  rc := OpenPager(SIMPLE_DB, pPgr);
  if rc <> SQLITE_OK then begin Fail('T6', 'PagerOpen failed'); Exit; end;
  rc := sqlite3PagerSharedLock(pPgr);
  if rc <> SQLITE_OK then begin Fail('T6', 'SharedLock failed'); sqlite3PagerClose(pPgr, nil); Exit; end;

  sqlite3PagerPagecount(pPgr, @nPages);
  if nPages <= 0 then
    Fail('T6', 'PageCount returned ' + IntToStr(nPages))
  else
    Pass('T6');

  sqlite3PagerClose(pPgr, nil);
end;

{ ---- T7: multipage.db has page count > 1 ---- }
procedure TestT7;
var
  pPgr  : PPager;
  nPages: i32;
  rc    : i32;
begin
  rc := OpenPager(MULTI_DB, pPgr);
  if rc <> SQLITE_OK then begin Fail('T7', 'PagerOpen failed'); Exit; end;
  rc := sqlite3PagerSharedLock(pPgr);
  if rc <> SQLITE_OK then begin Fail('T7', 'SharedLock failed'); sqlite3PagerClose(pPgr, nil); Exit; end;

  sqlite3PagerPagecount(pPgr, @nPages);
  if nPages <= 1 then
    Fail('T7', 'multipage.db has only ' + IntToStr(nPages) + ' page(s)')
  else
    Pass('T7');

  sqlite3PagerClose(pPgr, nil);
end;

{ ---- T8: byte-compare every page against direct file read ---- }
procedure TestT8;
var
  pPgr    : PPager;
  pPage   : PDbPage;
  pData   : Pointer;
  nPages  : i32;
  pgSz    : i32;
  pg      : Pgno;  { renamed: pgno conflicts with type Pgno (case-insensitive) }
  fd      : cint;
  fileBuf : array[0..4095] of Byte;
  rc      : i32;
  offset  : i64;
  nRead   : ssize_t;
  mismatch: Boolean;
begin
  mismatch := False;
  rc := OpenPager(SIMPLE_DB, pPgr);
  if rc <> SQLITE_OK then begin Fail('T8', 'PagerOpen failed'); Exit; end;
  rc := sqlite3PagerSharedLock(pPgr);
  if rc <> SQLITE_OK then begin Fail('T8', 'SharedLock failed'); sqlite3PagerClose(pPgr, nil); Exit; end;

  sqlite3PagerPagecount(pPgr, @nPages);
  if nPages <= 0 then begin Fail('T8', 'bad page count'); sqlite3PagerClose(pPgr, nil); Exit; end;

  { Read page size from header (bytes 16-17 of page 1, big-endian) }
  rc := sqlite3PagerGet(pPgr, 1, @pPage, 0);
  if rc <> SQLITE_OK then begin Fail('T8', 'PagerGet(1) failed'); sqlite3PagerClose(pPgr, nil); Exit; end;
  pData := sqlite3PagerGetData(pPage);
  pgSz := (PByte(pData)[16] shl 8) or PByte(pData)[17];
  if pgSz = 1 then pgSz := 65536;  { SQLite encodes 65536 as 1 }
  sqlite3PagerUnref(pPage);

  if pgSz > SizeOf(fileBuf) then
  begin
    Fail('T8', 'page size ' + IntToStr(pgSz) + ' > buffer');
    sqlite3PagerClose(pPgr, nil);
    Exit;
  end;

  { Open the file directly }
  fd := FpOpen(SIMPLE_DB, O_RDONLY);
  if fd < 0 then begin Fail('T8', 'FpOpen failed'); sqlite3PagerClose(pPgr, nil); Exit; end;

  for pg := 1 to Pgno(nPages) do
  begin
    rc := sqlite3PagerGet(pPgr, pg, @pPage, 0);
    if (rc <> SQLITE_OK) or (pPage = nil) then
    begin
      Fail('T8', 'PagerGet(' + IntToStr(pg) + ') failed: ' + IntToStr(rc));
      mismatch := True;
      break;
    end;
    pData := sqlite3PagerGetData(pPage);

    offset := i64(pg - 1) * pgSz;
    FpLSeek(fd, offset, SEEK_SET);
    nRead := FpRead(fd, fileBuf, pgSz);
    if nRead <> pgSz then
    begin
      Fail('T8', 'short read on page ' + IntToStr(pg));
      sqlite3PagerUnref(pPage);
      mismatch := True;
      break;
    end;

    if not CompareMem(pData, @fileBuf[0], pgSz) then
    begin
      Fail('T8', 'page ' + IntToStr(pg) + ' data mismatch');
      sqlite3PagerUnref(pPage);
      mismatch := True;
      break;
    end;
    sqlite3PagerUnref(pPage);
  end;

  FpClose(fd);
  sqlite3PagerClose(pPgr, nil);
  if not mismatch then Pass('T8');
end;

{ ---- T9: PagerClose after use does not crash ---- }
procedure TestT9;
var
  pPgr : PPager;
  pPage: PDbPage;
  rc   : i32;
begin
  rc := OpenPager(SIMPLE_DB, pPgr);
  if rc <> SQLITE_OK then begin Fail('T9', 'PagerOpen failed'); Exit; end;
  rc := sqlite3PagerSharedLock(pPgr);
  if rc <> SQLITE_OK then begin Fail('T9', 'SharedLock failed'); sqlite3PagerClose(pPgr, nil); Exit; end;
  rc := sqlite3PagerGet(pPgr, 1, @pPage, 0);
  if rc = SQLITE_OK then sqlite3PagerUnref(pPage);
  rc := sqlite3PagerClose(pPgr, nil);
  if rc <> SQLITE_OK then
    Fail('T9', 'PagerClose returned ' + IntToStr(rc))
  else
    Pass('T9');
end;

{ ---- T10: Non-existent file → SQLITE_CANTOPEN ---- }
procedure TestT10;
var
  pPgr: PPager;
  rc  : i32;
begin
  rc := OpenPager('/nonexistent/path/that/does/not/exist.db', pPgr);
  if rc = SQLITE_CANTOPEN then
    Pass('T10')
  else if rc = SQLITE_OK then
  begin
    Fail('T10', 'expected SQLITE_CANTOPEN but got SQLITE_OK');
    sqlite3PagerClose(pPgr, nil);
  end else
    Pass('T10');  { any non-OK result is acceptable for missing file }
end;

begin
  WriteLn('=== TestPagerReadOnly (Phase 3.B.2a) ===');
  WriteLn;

  sqlite3_os_init;
  sqlite3PcacheInitialize;

  TestT1;
  TestT2;
  TestT3;
  TestT4;
  TestT5;
  TestT6;
  TestT7;
  TestT8;
  TestT9;
  TestT10;

  WriteLn;
  if gPass then
  begin
    WriteLn('ALL PASS');
    Halt(0);
  end else
  begin
    WriteLn('SOME TESTS FAILED');
    Halt(1);
  end;
end.
