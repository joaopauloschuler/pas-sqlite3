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
program TestPager;

{
  Phase 3.A.3 + 3.A.4 -- MemJournal and MemDB gate tests.

  Tests the Pascal in-memory journal (memjournal.c port) and the
  in-memory database VFS (memdb.c port) via their public APIs:

    T1  sqlite3MemJournalOpen: open pure in-memory journal; verify IsInMemory.
    T2  MemJournal write then read back identical bytes.
    T3  MemJournal write past nSpill triggers spill (returns OK, real VFS used).
    T4  MemJournal truncate to zero clears data; subsequent FileSize = 0.
    T5  MemJournal FileSize matches bytes written.
    T6  MemJournal close (no crash, no leak).
    T7  sqlite3MemdbInit registers "memdb" VFS; sqlite3IsMemdb returns 1.
    T8  MemDB open + write + read back identical bytes.
    T9  MemDB lock/unlock cycle succeeds (SHARED -> EXCLUSIVE -> UNLOCKED).
    T10 MemDB truncate reduces size; read beyond new size returns SHORT_READ.
    T11 sqlite3JournalSize >= sizeof(MemJournal).
    T12 sqlite3JournalOpen with nSpill=0 falls through to real VFS (no memory file).

  Prints PASS/FAIL per test. Exits 0 if ALL PASS, 1 on any failure.

  Run with:
    LD_LIBRARY_PATH=src/ bin/TestPager
}

uses
  SysUtils,
  BaseUnix,
  UnixType,
  passqlite3types,
  passqlite3internal,
  passqlite3os,
  passqlite3util,
  passqlite3pager;

{ ------------------------------------------------------------------ helpers }

var
  gAllPass: Boolean = True;

procedure Fail(const test, msg: string);
begin
  WriteLn('FAIL [', test, ']: ', msg);
  gAllPass := False;
end;

procedure Pass(const test: string);
begin
  WriteLn('PASS [', test, ']');
end;

{ Allocate a zeroed buffer of SizeOf(MemJournal) + szOsFile for a sqlite3_file. }
function AllocJFD: Psqlite3_file;
var
  sz: i32;
  p : Psqlite3_file;
begin
  sz := SizeOf(MemJournal);
  p  := Psqlite3_file(sqlite3_malloc(sz));
  if Assigned(p) then FillChar(p^, sz, 0);
  Result := p;
end;

{ Allocate a MemFile-sized file handle for memdb. }
function AllocMFD: Psqlite3_file;
var
  sz: i32;
  p : Psqlite3_file;
begin
  sz := SizeOf(MemFile);
  p  := Psqlite3_file(sqlite3_malloc(sz));
  if Assigned(p) then FillChar(p^, sz, 0);
  Result := p;
end;

{ ------------------------------------------------------------------ T1 }

procedure T1_MemJournalOpen_IsInMemory;
var
  pJfd: Psqlite3_file;
begin
  pJfd := AllocJFD;
  if pJfd = nil then begin Fail('T1', 'alloc failed'); Exit; end;
  sqlite3MemJournalOpen(pJfd);
  if sqlite3JournalIsInMemory(pJfd) = 0 then
    Fail('T1', 'IsInMemory returned 0 for pure-memory journal')
  else
    Pass('T1');
  { close via method }
  if Assigned(pJfd^.pMethods) and Assigned(pJfd^.pMethods^.xClose) then
    pJfd^.pMethods^.xClose(pJfd);
  sqlite3_free(pJfd);
end;

{ ------------------------------------------------------------------ T2 }

procedure T2_MemJournal_WriteRead;
const
  N = 512;
var
  pJfd  : Psqlite3_file;
  wbuf  : array[0..N-1] of u8;
  rbuf  : array[0..N-1] of u8;
  i, rc : i32;
begin
  pJfd := AllocJFD;
  if pJfd = nil then begin Fail('T2', 'alloc failed'); Exit; end;
  sqlite3MemJournalOpen(pJfd);

  { fill write buffer with a pattern }
  for i := 0 to N-1 do wbuf[i] := u8(i and $FF);
  FillChar(rbuf, N, 0);

  rc := pJfd^.pMethods^.xWrite(pJfd, @wbuf[0], N, 0);
  if rc <> SQLITE_OK then
  begin
    Fail('T2', 'xWrite returned ' + IntToStr(rc));
    pJfd^.pMethods^.xClose(pJfd);
    sqlite3_free(pJfd);
    Exit;
  end;

  rc := pJfd^.pMethods^.xRead(pJfd, @rbuf[0], N, 0);
  if rc <> SQLITE_OK then
  begin
    Fail('T2', 'xRead returned ' + IntToStr(rc));
    pJfd^.pMethods^.xClose(pJfd);
    sqlite3_free(pJfd);
    Exit;
  end;

  if not CompareMem(@wbuf[0], @rbuf[0], N) then
    Fail('T2', 'read-back bytes differ from written bytes')
  else
    Pass('T2');

  pJfd^.pMethods^.xClose(pJfd);
  sqlite3_free(pJfd);
end;

{ ------------------------------------------------------------------ T3 }

procedure T3_MemJournal_SpillToReal;
{ nSpill = 64; write 128 bytes => should trigger spill to real VFS.
  We use a temp file name and a real VFS for this. }
var
  pVfs : Psqlite3_vfs;
  pJfd : Psqlite3_file;
  jPath: array[0..255] of AnsiChar;
  buf  : array[0..127] of u8;
  i, rc: i32;
  sz   : i32;
begin
  pVfs := sqlite3_vfs_find(nil);
  if pVfs = nil then begin Fail('T3', 'no default VFS'); Exit; end;

  { Create a temp file path }
  StrPCopy(jPath, '/tmp/pas_sqlite3_test_journal.tmp');

  { Allocate a file handle large enough for both MemJournal and real VFS file }
  sz   := sqlite3JournalSize(pVfs);
  pJfd := Psqlite3_file(sqlite3_malloc(sz));
  if pJfd = nil then begin Fail('T3', 'alloc failed'); Exit; end;
  FillChar(pJfd^, sz, 0);

  rc := sqlite3JournalOpen(pVfs, @jPath[0], pJfd,
          SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE, 64);
  if rc <> SQLITE_OK then
  begin
    Fail('T3', 'sqlite3JournalOpen returned ' + IntToStr(rc));
    sqlite3_free(pJfd);
    Exit;
  end;

  { should still be in-memory (no write yet) }
  if sqlite3JournalIsInMemory(pJfd) = 0 then
  begin
    Fail('T3', 'expected in-memory before first write');
    pJfd^.pMethods^.xClose(pJfd);
    sqlite3_free(pJfd);
    sqlite3OsDelete(pVfs, @jPath[0], 0);
    Exit;
  end;

  { Write 128 bytes -> exceeds nSpill=64 -> should spill to disk }
  for i := 0 to 127 do buf[i] := u8(i);
  rc := pJfd^.pMethods^.xWrite(pJfd, @buf[0], 128, 0);
  if rc <> SQLITE_OK then
  begin
    Fail('T3', 'xWrite (spill) returned ' + IntToStr(rc));
    pJfd^.pMethods^.xClose(pJfd);
    sqlite3_free(pJfd);
    sqlite3OsDelete(pVfs, @jPath[0], 0);
    Exit;
  end;

  { After spill, IsInMemory should return 0 (now a real file) }
  if sqlite3JournalIsInMemory(pJfd) <> 0 then
    Fail('T3', 'expected NOT in-memory after spill')
  else
    Pass('T3');

  pJfd^.pMethods^.xClose(pJfd);
  sqlite3_free(pJfd);
  sqlite3OsDelete(pVfs, @jPath[0], 0);
end;

{ ------------------------------------------------------------------ T4 }

procedure T4_MemJournal_Truncate;
var
  pJfd   : Psqlite3_file;
  buf    : array[0..255] of u8;
  pSize  : i64;
  rc     : i32;
begin
  pJfd := AllocJFD;
  if pJfd = nil then begin Fail('T4', 'alloc failed'); Exit; end;
  sqlite3MemJournalOpen(pJfd);

  FillChar(buf, 256, $AB);
  rc := pJfd^.pMethods^.xWrite(pJfd, @buf[0], 256, 0);
  if rc <> SQLITE_OK then begin Fail('T4', 'xWrite failed'); pJfd^.pMethods^.xClose(pJfd); sqlite3_free(pJfd); Exit; end;

  rc := pJfd^.pMethods^.xTruncate(pJfd, 0);
  if rc <> SQLITE_OK then begin Fail('T4', 'xTruncate failed'); pJfd^.pMethods^.xClose(pJfd); sqlite3_free(pJfd); Exit; end;

  pSize := -1;
  pJfd^.pMethods^.xFileSize(pJfd, @pSize);
  if pSize <> 0 then
    Fail('T4', 'FileSize after truncate(0) = ' + IntToStr(pSize) + ', expected 0')
  else
    Pass('T4');

  pJfd^.pMethods^.xClose(pJfd);
  sqlite3_free(pJfd);
end;

{ ------------------------------------------------------------------ T5 }

procedure T5_MemJournal_FileSize;
var
  pJfd  : Psqlite3_file;
  buf   : array[0..99] of u8;
  pSize : i64;
  rc    : i32;
begin
  pJfd := AllocJFD;
  if pJfd = nil then begin Fail('T5', 'alloc failed'); Exit; end;
  sqlite3MemJournalOpen(pJfd);

  FillChar(buf, 100, $77);
  rc := pJfd^.pMethods^.xWrite(pJfd, @buf[0], 100, 0);
  if rc <> SQLITE_OK then begin Fail('T5', 'xWrite failed'); pJfd^.pMethods^.xClose(pJfd); sqlite3_free(pJfd); Exit; end;

  pSize := 0;
  pJfd^.pMethods^.xFileSize(pJfd, @pSize);
  if pSize <> 100 then
    Fail('T5', 'FileSize = ' + IntToStr(pSize) + ', expected 100')
  else
    Pass('T5');

  pJfd^.pMethods^.xClose(pJfd);
  sqlite3_free(pJfd);
end;

{ ------------------------------------------------------------------ T6 }

procedure T6_MemJournal_Close;
var
  pJfd : Psqlite3_file;
  buf  : array[0..511] of u8;
  rc   : i32;
begin
  pJfd := AllocJFD;
  if pJfd = nil then begin Fail('T6', 'alloc failed'); Exit; end;
  sqlite3MemJournalOpen(pJfd);
  FillChar(buf, 512, $CC);
  rc := pJfd^.pMethods^.xWrite(pJfd, @buf[0], 512, 0);
  if rc <> SQLITE_OK then begin Fail('T6', 'xWrite failed'); sqlite3_free(pJfd); Exit; end;
  { Close should free chunks without crashing }
  rc := pJfd^.pMethods^.xClose(pJfd);
  if rc <> SQLITE_OK then
    Fail('T6', 'xClose returned ' + IntToStr(rc))
  else
    Pass('T6');
  sqlite3_free(pJfd);
end;

{ ------------------------------------------------------------------ T7 }

procedure T7_MemdbInit_IsMemdb;
var
  rc   : i32;
  pVfs : Psqlite3_vfs;
begin
  rc := sqlite3MemdbInit;
  if rc <> SQLITE_OK then
  begin
    Fail('T7', 'sqlite3MemdbInit returned ' + IntToStr(rc));
    Exit;
  end;
  pVfs := sqlite3_vfs_find('memdb');
  if pVfs = nil then
  begin
    Fail('T7', 'sqlite3_vfs_find("memdb") returned nil');
    Exit;
  end;
  if sqlite3IsMemdb(pVfs) = 0 then
    Fail('T7', 'sqlite3IsMemdb returned 0 for memdb VFS')
  else
    Pass('T7');
end;

{ ------------------------------------------------------------------ T8 }

procedure T8_Memdb_WriteRead;
var
  pVfs  : Psqlite3_vfs;
  pFd   : Psqlite3_file;
  wbuf  : array[0..255] of u8;
  rbuf  : array[0..255] of u8;
  i, rc : i32;
  flags : i32;
begin
  pVfs := sqlite3_vfs_find('memdb');
  if pVfs = nil then begin Fail('T8', 'memdb VFS not found'); Exit; end;

  pFd := AllocMFD;
  if pFd = nil then begin Fail('T8', 'alloc failed'); Exit; end;

  flags := SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE or SQLITE_OPEN_MEMORY;
  rc := pVfs^.xOpen(pVfs, nil, pFd, flags, nil);
  if rc <> SQLITE_OK then
  begin
    Fail('T8', 'xOpen returned ' + IntToStr(rc));
    sqlite3_free(pFd);
    Exit;
  end;

  for i := 0 to 255 do wbuf[i] := u8(255 - i);
  FillChar(rbuf, 256, 0);

  rc := pFd^.pMethods^.xWrite(pFd, @wbuf[0], 256, 0);
  if rc <> SQLITE_OK then begin Fail('T8', 'xWrite returned ' + IntToStr(rc)); pFd^.pMethods^.xClose(pFd); sqlite3_free(pFd); Exit; end;

  rc := pFd^.pMethods^.xRead(pFd, @rbuf[0], 256, 0);
  if rc <> SQLITE_OK then begin Fail('T8', 'xRead returned ' + IntToStr(rc)); pFd^.pMethods^.xClose(pFd); sqlite3_free(pFd); Exit; end;

  if not CompareMem(@wbuf[0], @rbuf[0], 256) then
    Fail('T8', 'read-back bytes differ from written bytes')
  else
    Pass('T8');

  pFd^.pMethods^.xClose(pFd);
  sqlite3_free(pFd);
end;

{ ------------------------------------------------------------------ T9 }

procedure T9_Memdb_LockUnlock;
var
  pVfs  : Psqlite3_vfs;
  pFd   : Psqlite3_file;
  rc    : i32;
  flags : i32;
begin
  pVfs := sqlite3_vfs_find('memdb');
  if pVfs = nil then begin Fail('T9', 'memdb VFS not found'); Exit; end;

  pFd := AllocMFD;
  if pFd = nil then begin Fail('T9', 'alloc failed'); Exit; end;

  flags := SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE or SQLITE_OPEN_MEMORY;
  rc := pVfs^.xOpen(pVfs, nil, pFd, flags, nil);
  if rc <> SQLITE_OK then begin Fail('T9', 'xOpen returned ' + IntToStr(rc)); sqlite3_free(pFd); Exit; end;

  rc := pFd^.pMethods^.xLock(pFd, SQLITE_LOCK_SHARED);
  if rc <> SQLITE_OK then begin Fail('T9', 'xLock SHARED failed: ' + IntToStr(rc)); pFd^.pMethods^.xClose(pFd); sqlite3_free(pFd); Exit; end;

  rc := pFd^.pMethods^.xLock(pFd, SQLITE_LOCK_EXCLUSIVE);
  if rc <> SQLITE_OK then begin Fail('T9', 'xLock EXCLUSIVE failed: ' + IntToStr(rc)); pFd^.pMethods^.xClose(pFd); sqlite3_free(pFd); Exit; end;

  rc := pFd^.pMethods^.xUnlock(pFd, SQLITE_LOCK_NONE);
  if rc <> SQLITE_OK then begin Fail('T9', 'xUnlock NONE failed: ' + IntToStr(rc)); pFd^.pMethods^.xClose(pFd); sqlite3_free(pFd); Exit; end;

  Pass('T9');
  pFd^.pMethods^.xClose(pFd);
  sqlite3_free(pFd);
end;

{ ------------------------------------------------------------------ T10 }

procedure T10_Memdb_Truncate_ShortRead;
var
  pVfs  : Psqlite3_vfs;
  pFd   : Psqlite3_file;
  buf   : array[0..255] of u8;
  rbuf  : array[0..255] of u8;
  pSize : i64;
  rc    : i32;
  flags : i32;
begin
  pVfs := sqlite3_vfs_find('memdb');
  if pVfs = nil then begin Fail('T10', 'memdb VFS not found'); Exit; end;

  pFd := AllocMFD;
  if pFd = nil then begin Fail('T10', 'alloc failed'); Exit; end;

  flags := SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE or SQLITE_OPEN_MEMORY;
  rc := pVfs^.xOpen(pVfs, nil, pFd, flags, nil);
  if rc <> SQLITE_OK then begin Fail('T10', 'xOpen returned ' + IntToStr(rc)); sqlite3_free(pFd); Exit; end;

  FillChar(buf, 256, $55);
  rc := pFd^.pMethods^.xWrite(pFd, @buf[0], 256, 0);
  if rc <> SQLITE_OK then begin Fail('T10', 'xWrite failed'); pFd^.pMethods^.xClose(pFd); sqlite3_free(pFd); Exit; end;

  rc := pFd^.pMethods^.xTruncate(pFd, 128);
  if rc <> SQLITE_OK then begin Fail('T10', 'xTruncate(128) failed'); pFd^.pMethods^.xClose(pFd); sqlite3_free(pFd); Exit; end;

  pSize := 0;
  pFd^.pMethods^.xFileSize(pFd, @pSize);
  if pSize <> 128 then
  begin
    Fail('T10', 'FileSize after truncate(128) = ' + IntToStr(pSize));
    pFd^.pMethods^.xClose(pFd);
    sqlite3_free(pFd);
    Exit;
  end;

  { Reading 200 bytes from offset 0 should return SHORT_READ }
  FillChar(rbuf, 256, 0);
  rc := pFd^.pMethods^.xRead(pFd, @rbuf[0], 200, 0);
  if rc <> SQLITE_IOERR_SHORT_READ then
    Fail('T10', 'Expected SHORT_READ, got ' + IntToStr(rc))
  else
    Pass('T10');

  pFd^.pMethods^.xClose(pFd);
  sqlite3_free(pFd);
end;

{ ------------------------------------------------------------------ T11 }

procedure T11_JournalSize;
var
  pVfs : Psqlite3_vfs;
  sz   : i32;
begin
  pVfs := sqlite3_vfs_find(nil);
  if pVfs = nil then begin Fail('T11', 'no default VFS'); Exit; end;
  sz := sqlite3JournalSize(pVfs);
  if sz < SizeOf(MemJournal) then
    Fail('T11', 'JournalSize ' + IntToStr(sz) + ' < SizeOf(MemJournal) ' + IntToStr(SizeOf(MemJournal)))
  else
    Pass('T11');
end;

{ ------------------------------------------------------------------ T12 }

procedure T12_JournalOpen_nSpill0_RealVFS;
{ When nSpill=0, sqlite3JournalOpen must delegate directly to the real VFS
  (not use the MemJournal vtable). We verify IsInMemory returns 0. }
var
  pVfs  : Psqlite3_vfs;
  pJfd  : Psqlite3_file;
  jPath : array[0..255] of AnsiChar;
  rc    : i32;
  sz    : i32;
begin
  pVfs := sqlite3_vfs_find(nil);
  if pVfs = nil then begin Fail('T12', 'no default VFS'); Exit; end;

  StrPCopy(jPath, '/tmp/pas_sqlite3_t12_journal.tmp');
  sz   := sqlite3JournalSize(pVfs);
  pJfd := Psqlite3_file(sqlite3_malloc(sz));
  if pJfd = nil then begin Fail('T12', 'alloc failed'); Exit; end;
  FillChar(pJfd^, sz, 0);

  rc := sqlite3JournalOpen(pVfs, @jPath[0], pJfd,
          SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE, 0);
  if rc <> SQLITE_OK then
  begin
    Fail('T12', 'sqlite3JournalOpen(nSpill=0) returned ' + IntToStr(rc));
    sqlite3_free(pJfd);
    Exit;
  end;

  if sqlite3JournalIsInMemory(pJfd) <> 0 then
    Fail('T12', 'Expected real-file journal (not in-memory) when nSpill=0')
  else
    Pass('T12');

  if Assigned(pJfd^.pMethods) and Assigned(pJfd^.pMethods^.xClose) then
    pJfd^.pMethods^.xClose(pJfd);
  sqlite3_free(pJfd);
  sqlite3OsDelete(pVfs, @jPath[0], 0);
end;

{ ================================================================== main }

begin
  sqlite3_os_init;
  sqlite3MallocInit;

  WriteLn('=== TestPager (Phase 3.A.3 + 3.A.4) ===');
  WriteLn;

  T1_MemJournalOpen_IsInMemory;
  T2_MemJournal_WriteRead;
  T3_MemJournal_SpillToReal;
  T4_MemJournal_Truncate;
  T5_MemJournal_FileSize;
  T6_MemJournal_Close;
  T7_MemdbInit_IsMemdb;
  T8_Memdb_WriteRead;
  T9_Memdb_LockUnlock;
  T10_Memdb_Truncate_ShortRead;
  T11_JournalSize;
  T12_JournalOpen_nSpill0_RealVFS;

  WriteLn;
  if gAllPass then
  begin
    WriteLn('ALL PASS');
    Halt(0);
  end
  else
  begin
    WriteLn('SOME TESTS FAILED');
    Halt(1);
  end;
end.
