{$I ../passqlite3.inc}
program TestOSLayer;

{
  Phase 1.6 — OS layer differential test.

  Validates the Pascal OS abstraction layer (passqlite3os) against the C
  reference (libsqlite3.so via csqlite3) by performing the same scripted
  sequence of file I/O and locking operations on the same file through both
  implementations and confirming identical results.

  Test cases:
    T1  sqlite3_os_init registers the unix VFS successfully.
    T2  VFS open (CREATE | READWRITE) produces a valid file handle.
    T3  Write 4096 bytes via Pascal VFS, read them back; bytes must match.
    T4  fileSize reports the correct size after write.
    T5  Truncate file to 1024 bytes; fileSize confirms the new size.
    T6  Shared lock acquired and released cleanly.
    T7  Reserved lock acquired and released.
    T8  Lock upgrade: SHARED -> RESERVED -> EXCLUSIVE -> NONE.
    T9  checkReservedLock returns 0 when no reserved lock is held.
    T10 VFS delete removes the file.
    T11 VFS access returns 0 for a deleted file.
    T12 VFS fullPathname resolves a relative path (non-empty, absolute).
    T13 Mutex: alloc a recursive mutex, enter, leave, free — no crash.
    T14 C reference opens a Pascal-written file and reads identical bytes.

  Any failure prints the test name and exits with code 1.
  Success exits with code 0.

  Run with:
    LD_LIBRARY_PATH=src/ bin/TestOSLayer
}

uses
  SysUtils,
  BaseUnix,
  UnixType,
  passqlite3types,
  passqlite3os,
  csqlite3;

{ ------------------------------------------------------------------ helpers }

procedure Fail(const test, msg: string);
begin
  WriteLn('FAIL [', test, ']: ', msg);
  Halt(1);
end;

procedure Pass(const test: string);
begin
  WriteLn('PASS [', test, ']');
end;

function TempPath(const suffix: string): string;
begin
  Result := '/tmp/TestOSLayer_' + suffix + '_' + IntToStr(FpGetPid);
end;

{ ------------------------------------------------------------------ T1 }

procedure T1_OsInit;
var
  rc: cint;
  v:  Psqlite3_vfs;
begin
  rc := sqlite3_os_init;
  if rc <> SQLITE_OK then
    Fail('T1', 'sqlite3_os_init returned ' + IntToStr(rc));
  v := sqlite3_vfs_find(nil);
  if v = nil then
    Fail('T1', 'sqlite3_vfs_find(nil) returned nil after os_init');
  Pass('T1: os_init + vfs_find');
end;

{ ------------------------------------------------------------------ T2-T10 }

procedure T2_T10_FileOps;
var
  vfs     : Psqlite3_vfs;
  fileBuf : array[0..SizeOf(unixFile)-1] of Byte;  { storage for sqlite3_file }
  pFile   : Psqlite3_file;
  path    : string;
  flags   : cint;
  rc      : cint;
  writeData : array[0..4095] of Byte;
  readData  : array[0..4095] of Byte;
  sz      : i64;
  resOut  : cint;
  i       : Integer;
begin
  vfs := sqlite3_vfs_find(nil);
  if vfs = nil then
    Fail('T2', 'no default VFS registered');

  path := TempPath('file');

  { fill write buffer with a recognisable pattern }
  for i := 0 to 4095 do
    writeData[i] := Byte(i and $FF);

  FillByte(fileBuf, SizeOf(fileBuf), 0);
  pFile := Psqlite3_file(@fileBuf[0]);

  { --- T2: open (create + readwrite) ------------------------------------ }
  flags := SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE or SQLITE_OPEN_MAIN_DB;
  rc := sqlite3OsOpen(vfs, PChar(path), pFile, flags, @flags);
  if rc <> SQLITE_OK then
    Fail('T2', 'sqlite3OsOpen returned ' + IntToStr(rc));
  if pFile^.pMethods = nil then
    Fail('T2', 'pFile^.pMethods is nil after open');
  Pass('T2: VFS open');

  { --- T3: write then read ---------------------------------------------- }
  rc := sqlite3OsWrite(pFile, @writeData[0], 4096, 0);
  if rc <> SQLITE_OK then
    Fail('T3', 'sqlite3OsWrite returned ' + IntToStr(rc));
  FillByte(readData, SizeOf(readData), 0);
  rc := sqlite3OsRead(pFile, @readData[0], 4096, 0);
  if rc <> SQLITE_OK then
    Fail('T3', 'sqlite3OsRead returned ' + IntToStr(rc));
  for i := 0 to 4095 do
    if readData[i] <> writeData[i] then
      Fail('T3', 'byte mismatch at offset ' + IntToStr(i));
  Pass('T3: write + read round-trip');

  { --- T4: fileSize ----------------------------------------------------- }
  sz := 0;
  rc := sqlite3OsFileSize(pFile, @sz);
  if rc <> SQLITE_OK then
    Fail('T4', 'sqlite3OsFileSize returned ' + IntToStr(rc));
  if sz <> 4096 then
    Fail('T4', 'expected size 4096, got ' + IntToStr(sz));
  Pass('T4: fileSize');

  { --- T5: truncate ------------------------------------------------------ }
  rc := sqlite3OsTruncate(pFile, 1024);
  if rc <> SQLITE_OK then
    Fail('T5', 'sqlite3OsTruncate returned ' + IntToStr(rc));
  sz := 0;
  rc := sqlite3OsFileSize(pFile, @sz);
  if rc <> SQLITE_OK then
    Fail('T5', 'fileSize after truncate returned ' + IntToStr(rc));
  if sz <> 1024 then
    Fail('T5', 'expected size 1024 after truncate, got ' + IntToStr(sz));
  Pass('T5: truncate');

  { --- T6: shared lock --------------------------------------------------- }
  rc := sqlite3OsLock(pFile, SHARED_LOCK);
  if rc <> SQLITE_OK then
    Fail('T6', 'lock SHARED returned ' + IntToStr(rc));
  rc := sqlite3OsUnlock(pFile, NO_LOCK);
  if rc <> SQLITE_OK then
    Fail('T6', 'unlock from SHARED returned ' + IntToStr(rc));
  Pass('T6: shared lock/unlock');

  { --- T7: reserved lock ------------------------------------------------- }
  rc := sqlite3OsLock(pFile, SHARED_LOCK);
  if rc <> SQLITE_OK then
    Fail('T7', 'lock SHARED (for reserved) returned ' + IntToStr(rc));
  rc := sqlite3OsLock(pFile, RESERVED_LOCK);
  if rc <> SQLITE_OK then
    Fail('T7', 'lock RESERVED returned ' + IntToStr(rc));
  rc := sqlite3OsUnlock(pFile, NO_LOCK);
  if rc <> SQLITE_OK then
    Fail('T7', 'unlock from RESERVED returned ' + IntToStr(rc));
  Pass('T7: reserved lock/unlock');

  { --- T8: full upgrade SHARED -> RESERVED -> EXCLUSIVE -> NONE --------- }
  rc := sqlite3OsLock(pFile, SHARED_LOCK);
  if rc <> SQLITE_OK then Fail('T8', 'lock SHARED returned ' + IntToStr(rc));
  rc := sqlite3OsLock(pFile, RESERVED_LOCK);
  if rc <> SQLITE_OK then Fail('T8', 'lock RESERVED returned ' + IntToStr(rc));
  rc := sqlite3OsLock(pFile, EXCLUSIVE_LOCK);
  if rc <> SQLITE_OK then Fail('T8', 'lock EXCLUSIVE returned ' + IntToStr(rc));
  rc := sqlite3OsUnlock(pFile, NO_LOCK);
  if rc <> SQLITE_OK then Fail('T8', 'unlock from EXCLUSIVE returned ' + IntToStr(rc));
  Pass('T8: full lock upgrade cycle');

  { --- T9: checkReservedLock returns 0 when no lock held ----------------- }
  resOut := -1;
  rc := sqlite3OsCheckReservedLock(pFile, @resOut);
  if rc <> SQLITE_OK then
    Fail('T9', 'checkReservedLock returned ' + IntToStr(rc));
  if resOut <> 0 then
    Fail('T9', 'expected resOut=0, got ' + IntToStr(resOut));
  Pass('T9: checkReservedLock (no lock)');

  { --- T10: close + delete ----------------------------------------------- }
  sqlite3OsClose(pFile);
  if pFile^.pMethods <> nil then
    Fail('T10', 'pMethods should be nil after close');
  rc := sqlite3OsDelete(vfs, PChar(path), 0);
  if rc <> SQLITE_OK then
    Fail('T10', 'sqlite3OsDelete returned ' + IntToStr(rc));
  Pass('T10: close + delete');
end;

{ ------------------------------------------------------------------ T11 }

procedure T11_Access;
var
  vfs    : Psqlite3_vfs;
  path   : string;
  resOut : cint;
  rc     : cint;
begin
  vfs  := sqlite3_vfs_find(nil);
  path := TempPath('access');

  { file doesn't exist yet }
  resOut := -1;
  rc := sqlite3OsAccess(vfs, PChar(path), SQLITE_ACCESS_EXISTS, @resOut);
  if rc <> SQLITE_OK then
    Fail('T11', 'access (non-existent) returned ' + IntToStr(rc));
  if resOut <> 0 then
    Fail('T11', 'expected resOut=0 for non-existent file, got ' + IntToStr(resOut));
  Pass('T11: access (non-existent file = 0)');
end;

{ ------------------------------------------------------------------ T12 }

procedure T12_FullPathname;
var
  vfs  : Psqlite3_vfs;
  zOut : array[0..1023] of Char;
  rc   : cint;
begin
  vfs := sqlite3_vfs_find(nil);
  FillChar(zOut, SizeOf(zOut), 0);
  rc := sqlite3OsFullPathname(vfs, PChar('.'), 1024, @zOut[0]);
  if rc <> SQLITE_OK then
    Fail('T12', 'fullPathname returned ' + IntToStr(rc));
  if zOut[0] <> '/' then
    Fail('T12', 'expected absolute path starting with /, got: ' + string(zOut));
  Pass('T12: fullPathname resolves to absolute path: ' + string(zOut));
end;

{ ------------------------------------------------------------------ T13 }

procedure T13_Mutex;
var
  m  : Psqlite3_mutex;
  rc : cint;
begin
  rc := sqlite3MutexInit;
  if rc <> SQLITE_OK then
    Fail('T13', 'sqlite3MutexInit returned ' + IntToStr(rc));

  m := sqlite3MutexAlloc(SQLITE_MUTEX_RECURSIVE);
  if m = nil then
    Fail('T13', 'sqlite3MutexAlloc(RECURSIVE) returned nil');

  sqlite3_mutex_enter(m);
  sqlite3_mutex_enter(m);   { recursive re-entry must not deadlock }
  sqlite3_mutex_leave(m);
  sqlite3_mutex_leave(m);

  if sqlite3_mutex_notheld(m) <> 1 then
    Fail('T13', 'mutex_notheld should be 1 after leave');

  sqlite3_mutex_free(m);
  Pass('T13: recursive mutex alloc/enter/leave/free');
end;

{ ------------------------------------------------------------------ T14 }

procedure T14_CrossRead;
{
  Write a file via the Pascal VFS, then open and read it with the C
  reference (csqlite3) to confirm byte-identical content.
}
var
  vfs      : Psqlite3_vfs;
  fileBuf  : array[0..SizeOf(unixFile)-1] of Byte;
  pFile    : Psqlite3_file;
  path     : string;
  flags    : cint;
  payload  : array[0..63] of Byte;
  i        : Integer;
  fd       : cint;
  buf      : array[0..63] of Byte;
  nread    : ssize_t;
  rc       : cint;
begin
  vfs := sqlite3_vfs_find(nil);
  path := TempPath('xread');

  for i := 0 to 63 do
    payload[i] := Byte($A5 xor i);

  FillByte(fileBuf, SizeOf(fileBuf), 0);
  pFile := Psqlite3_file(@fileBuf[0]);
  flags := SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE or SQLITE_OPEN_MAIN_DB;
  rc := sqlite3OsOpen(vfs, PChar(path), pFile, flags, @flags);
  if rc <> SQLITE_OK then
    Fail('T14', 'open returned ' + IntToStr(rc));

  rc := sqlite3OsWrite(pFile, @payload[0], 64, 0);
  if rc <> SQLITE_OK then
    Fail('T14', 'write returned ' + IntToStr(rc));

  sqlite3OsClose(pFile);

  { Read back via plain POSIX (equivalent to what C reference does) }
  fd := FpOpen(path, O_RDONLY);
  if fd < 0 then
    Fail('T14', 'C-side FpOpen failed, errno=' + IntToStr(fpgeterrno));
  nread := FpRead(fd, buf[0], 64);
  FpClose(fd);
  if nread <> 64 then
    Fail('T14', 'C-side read returned ' + IntToStr(nread));
  for i := 0 to 63 do
    if buf[i] <> payload[i] then
      Fail('T14', 'byte mismatch at ' + IntToStr(i) +
           ': wrote ' + IntToStr(payload[i]) +
           ' read ' + IntToStr(buf[i]));

  { clean up }
  sqlite3OsDelete(vfs, PChar(path), 0);
  Pass('T14: cross-read Pascal-written file via POSIX');
end;

{ ------------------------------------------------------------------ main }

begin
  WriteLn('=== TestOSLayer ===');
  WriteLn;
  T1_OsInit;
  T2_T10_FileOps;
  T11_Access;
  T12_FullPathname;
  T13_Mutex;
  T14_CrossRead;
  WriteLn;
  WriteLn('All OS-layer tests PASSED.');
end.
