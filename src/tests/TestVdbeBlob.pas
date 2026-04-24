{$I passqlite3.inc}
program TestVdbeBlob;
{
  Phase 5.6 gate test — vdbeblob.c incremental blob I/O.

  sqlite3_blob_open requires the SQL compiler (Phase 7+) and is stubbed.
  This test verifies the null-guard and argument-checking behavior of all
  six blob API functions without needing a real open blob handle.

    T1  sqlite3_blob_open → non-SQLITE_OK (stub; compiler not available)
    T2  sqlite3_blob_close(nil) = SQLITE_OK
    T3  sqlite3_blob_bytes(nil) = 0
    T4  sqlite3_blob_read(nil,...) = SQLITE_MISUSE
    T5  sqlite3_blob_write(nil,...) = SQLITE_MISUSE
    T6  sqlite3_blob_reopen(nil,...) = SQLITE_MISUSE
    T7  sqlite3_blob_bytes on valid stub handle with pStmt=nil returns 0
    T8  sqlite3_blob_read on invalidated handle (pStmt=nil) = SQLITE_ABORT
    T9  sqlite3_blob_write on invalidated handle (pStmt=nil) = SQLITE_ABORT
    T10 sqlite3_blob_reopen on invalidated handle (pStmt=nil) = SQLITE_ABORT
    T11 sqlite3_blob_close on valid-but-empty stub handle returns SQLITE_OK

  Gate: T1–T11 all PASS.
}

uses
  SysUtils,
  passqlite3types,
  passqlite3os,
  passqlite3util,
  passqlite3pcache,
  passqlite3pager,
  passqlite3wal,
  passqlite3btree,
  passqlite3vdbe;

{ ===== helpers ============================================================== }

var
  gPass: i32 = 0;
  gFail: i32 = 0;

procedure Check(name: string; cond: Boolean);
begin
  if cond then begin
    WriteLn('  PASS ', name);
    Inc(gPass);
  end else begin
    WriteLn('  FAIL ', name);
    Inc(gFail);
  end;
end;

{ ===== T1: sqlite3_blob_open stub ========================================== }

procedure TestBlobOpen;
var
  md:    Tsqlite3;
  pBlob: Psqlite3_blob;
  rc:    i32;
begin
  WriteLn('T1: sqlite3_blob_open returns non-OK (SQL compiler stub)');
  FillChar(md, SizeOf(md), 0);
  md.enc := SQLITE_UTF8;
  pBlob := nil;
  rc := sqlite3_blob_open(@md, 'main', 't', 'c', 1, 0, pBlob);
  Check('T1 open<>OK', rc <> SQLITE_OK);
  Check('T1 ppBlob=nil', pBlob = nil);
end;

{ ===== T2: close nil handle ================================================ }

procedure TestBlobCloseNil;
begin
  WriteLn('T2: sqlite3_blob_close(nil) = SQLITE_OK');
  Check('T2 close_nil', sqlite3_blob_close(nil) = SQLITE_OK);
end;

{ ===== T3: bytes nil handle ================================================ }

procedure TestBlobBytesNil;
begin
  WriteLn('T3: sqlite3_blob_bytes(nil) = 0');
  Check('T3 bytes_nil', sqlite3_blob_bytes(nil) = 0);
end;

{ ===== T4–T6: read/write/reopen nil handle ================================= }

procedure TestBlobNilGuards;
var
  buf: array[0..3] of Byte;
begin
  WriteLn('T4–T6: read/write/reopen(nil) = SQLITE_MISUSE');
  Check('T4 read_nil',   sqlite3_blob_read(nil,  @buf, 4, 0) = SQLITE_MISUSE);
  Check('T5 write_nil',  sqlite3_blob_write(nil, @buf, 4, 0) = SQLITE_MISUSE);
  Check('T6 reopen_nil', sqlite3_blob_reopen(nil, 1)         = SQLITE_MISUSE);
end;

{ Build a stub TIncrblob with pStmt=nil (invalidated handle). }

function MakeInvalidatedHandle(pDb: PTsqlite3): Psqlite3_blob;
var
  p: PIncrblob;
begin
  p := PIncrblob(sqlite3DbMallocZero(pDb, SizeOf(TIncrblob)));
  if p = nil then begin Result := nil; Exit; end;
  p^.nByte  := 100;
  p^.pStmt  := nil;    { pStmt=nil → invalidated }
  p^.db     := pDb;
  Result := p;
end;

{ ===== T7–T10: operations on invalidated (pStmt=nil) handle ================ }

procedure TestBlobInvalidated;
var
  md:    Tsqlite3;
  pBlob: Psqlite3_blob;
  buf:   array[0..3] of Byte;
  rc:    i32;
begin
  WriteLn('T7–T10: invalidated handle (pStmt=nil) behaviors');
  FillChar(md, SizeOf(md), 0);
  md.enc := SQLITE_UTF8;

  pBlob := MakeInvalidatedHandle(@md);
  if pBlob = nil then begin
    Check('T7 alloc', False); Check('T8 alloc', False);
    Check('T9 alloc', False); Check('T10 alloc', False);
    Exit;
  end;

  Check('T7 bytes=0',     sqlite3_blob_bytes(pBlob) = 0);
  Check('T8 read=ABORT',  sqlite3_blob_read(pBlob,  @buf, 4, 0) = SQLITE_ABORT);
  Check('T9 write=ABORT', sqlite3_blob_write(pBlob, @buf, 4, 0) = SQLITE_ABORT);
  Check('T10 reopen=ABORT', sqlite3_blob_reopen(pBlob, 99) = SQLITE_ABORT);

  { close the handle — pStmt=nil so finalize(nil)=OK }
  rc := sqlite3_blob_close(pBlob);
  Check('T10 close=OK', rc = SQLITE_OK);
  { pBlob is now freed; do NOT use it again }
end;

{ ===== T11: close a stub handle with pStmt=nil ============================= }

procedure TestBlobCloseStub;
var
  md:    Tsqlite3;
  pBlob: Psqlite3_blob;
  rc:    i32;
begin
  WriteLn('T11: sqlite3_blob_close on stub handle (pStmt=nil) = SQLITE_OK');
  FillChar(md, SizeOf(md), 0);
  md.enc := SQLITE_UTF8;

  pBlob := MakeInvalidatedHandle(@md);
  if pBlob = nil then begin Check('T11 alloc', False); Exit; end;

  rc := sqlite3_blob_close(pBlob);
  Check('T11 close=OK', rc = SQLITE_OK);
end;

{ ===== main ================================================================= }

begin
  sqlite3OsInit;
  sqlite3PcacheInitialize;

  WriteLn('=== TestVdbeBlob — Phase 5.6 gate test ===');
  WriteLn;

  TestBlobOpen;      WriteLn;
  TestBlobCloseNil;  WriteLn;
  TestBlobBytesNil;  WriteLn;
  TestBlobNilGuards; WriteLn;
  TestBlobInvalidated; WriteLn;
  TestBlobCloseStub; WriteLn;

  WriteLn(Format('Results: %d passed, %d failed', [gPass, gFail]));
  if gFail > 0 then Halt(1);
end.
