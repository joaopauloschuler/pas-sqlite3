{
  SPDX-License-Identifier: blessing

  Faithful port of ../sqlite3/ext/misc/vfslog.c (760 lines in C).

  Implements a VFS shim ("vfslog") that wraps an underlying VFS and
  records a CSV-formatted trace of every disk operation into per-database
  log files.  The log files live next to the original database file with
  a "-debuglog-<usec-since-epoch>" suffix appended; one log file is shared
  between the main database file and its rollback journal so a single
  connection's activity stays in one file.

  Each log line has eight comma-separated fields:
    tStart, tElapsed, opcode, isJournal, iArg1, iArg2, zArg3, iResult

  Public entry: sqlite3_register_vfslog(zArg) — equivalent to the C
  sqlite3_register_vfslog().  zArg is currently unused; the layered VFS
  becomes the new default VFS, wrapping whatever VFS was the default at
  the time of the call.

  Pascal-port adaptations:

  * The C source allocates a paired VLogLog[2] block (with the second
    instance only carrying the FILE* — used for the rollback journal of
    the same DB).  This layout is preserved 1:1 because the read/write
    methods walk through `pLog++` to switch between the two halves of
    the pair.
  * `vlog_time` uses libc's `gettimeofday` to keep the upstream
    tStart/tElapsed semantics.
  * `gethostname(2)` and `getpid(2)` are bound through libc directly.
  * The CSV output buffer is composed via `sqlite3PfSnprintf` with the
    upstream `%w` quoting escape so embedded `"` characters in the third
    argument are doubled, matching upstream byte-for-byte.
  * The master-journal name pattern test from vfslog.c:268..272
    (`sqlite3_strglob("-mj??????9??", ...)`) is preserved with
    `sqlite3_strglob` (already exported from passqlite3codegen).
}
{$I passqlite3.inc}
unit passqlite3vfslog;

interface

uses
  ctypes,
  passqlite3types,
  passqlite3os,
  passqlite3util,
  passqlite3main;

{ Returns SQLITE_OK on success.  zArg is reserved for future use and may
  be nil.  The "vfslog" VFS becomes the new default, layered on top of
  whatever VFS was previously default. }
function sqlite3_register_vfslog(zArg: PAnsiChar): i32;

{ Convenience entry used by extensions that want to wire vfslog from a
  db-init style callback (signature mirrors the rest of the ext/misc
  ports landed in this tree). }
function sqlite3VfslogInit(db: PTsqlite3): i32;

implementation

uses
  passqlite3printf,
  passqlite3codegen;  { sqlite3_strglob }

{ -------- libc bindings ----------------------------------------------- }

function vlogLibcGetpid: cint; cdecl;
  external 'c' name 'getpid';
function vlogLibcGethostname(buf: PAnsiChar; len: csize_t): cint; cdecl;
  external 'c' name 'gethostname';

type
  Ttimeval = record
    tv_sec  : clong;
    tv_usec : clong;
  end;

function vlogLibcGettimeofday(tv, tz: Pointer): cint; cdecl;
  external 'c' name 'gettimeofday';

{ -------- types ------------------------------------------------------- }

type
  PVLogLog = ^TVLogLog;
  TVLogLog = record
    pNext     : PVLogLog;       { Next in a list of all active logs }
    ppPrev    : ^PVLogLog;      { Pointer to this in the list }
    nRef      : cint;           { Number of references to this object }
    nFilename : cint;           { Length of zFilename in bytes }
    zFilename : PAnsiChar;      { Name of database file.  NULL for journal half }
    outF      : PFILE;          { Write information here }
  end;

  PVLogVfs = ^TVLogVfs;
  TVLogVfs = record
    base : sqlite3_vfs;     { VFS methods.  MUST BE FIRST. }
    pVfs : Psqlite3_vfs;    { Parent VFS }
  end;

  PVLogFile = ^TVLogFile;
  TVLogFile = record
    base  : sqlite3_file;     { IO methods.  MUST BE FIRST. }
    pReal : Psqlite3_file;    { Underlying file handle }
    pLog  : PVLogLog;         { The log file for this file }
  end;

{ -------- forward decls of methods ------------------------------------ }

function vlogClose(pFile: Psqlite3_file): cint; cdecl; forward;
function vlogRead(pFile: Psqlite3_file; zBuf: Pointer;
                  iAmt: cint; iOfst: i64): cint; cdecl; forward;
function vlogWrite(pFile: Psqlite3_file; zBuf: Pointer;
                   iAmt: cint; iOfst: i64): cint; cdecl; forward;
function vlogTruncate(pFile: Psqlite3_file; size: i64): cint; cdecl; forward;
function vlogSync(pFile: Psqlite3_file; flags: cint): cint; cdecl; forward;
function vlogFileSize(pFile: Psqlite3_file; pSize: Pi64): cint; cdecl; forward;
function vlogLock(pFile: Psqlite3_file; eLock: cint): cint; cdecl; forward;
function vlogUnlock(pFile: Psqlite3_file; eLock: cint): cint; cdecl; forward;
function vlogCheckReservedLock(pFile: Psqlite3_file;
                               pResOut: PcInt): cint; cdecl; forward;
function vlogFileControl(pFile: Psqlite3_file; op: cint;
                         pArg: Pointer): cint; cdecl; forward;
function vlogSectorSize(pFile: Psqlite3_file): cint; cdecl; forward;
function vlogDeviceCharacteristics(pFile: Psqlite3_file): cint; cdecl; forward;

function vlogOpen(pVfs: Psqlite3_vfs; zName: sqlite3_filename;
                  pFile: Psqlite3_file; flags: cint;
                  pOutFlags: PcInt): cint; cdecl; forward;
function vlogDelete(pVfs: Psqlite3_vfs; zPath: PChar;
                    syncDir: cint): cint; cdecl; forward;
function vlogAccess(pVfs: Psqlite3_vfs; zPath: PChar; flags: cint;
                    pResOut: PcInt): cint; cdecl; forward;
function vlogFullPathname(pVfs: Psqlite3_vfs; zPath: PChar; nOut: cint;
                          zOut: PChar): cint; cdecl; forward;
function vlogDlOpen(pVfs: Psqlite3_vfs; zPath: PChar): Pointer; cdecl; forward;
procedure vlogDlError(pVfs: Psqlite3_vfs; nByte: cint;
                      zErrMsg: PChar); cdecl; forward;
function vlogDlSym(pVfs: Psqlite3_vfs; p: Pointer;
                   zSym: PChar): sqlite3_syscall_ptr; cdecl; forward;
procedure vlogDlClose(pVfs: Psqlite3_vfs; pHandle: Pointer); cdecl; forward;
function vlogRandomness(pVfs: Psqlite3_vfs; nByte: cint;
                        zBufOut: PChar): cint; cdecl; forward;
function vlogSleep(pVfs: Psqlite3_vfs; nMicro: cint): cint; cdecl; forward;
function vlogCurrentTime(pVfs: Psqlite3_vfs;
                         pTimeOut: PDouble): cint; cdecl; forward;
function vlogGetLastError(pVfs: Psqlite3_vfs; a: cint;
                          b: PChar): cint; cdecl; forward;
function vlogCurrentTimeInt64(pVfs: Psqlite3_vfs;
                              p: Pi64): cint; cdecl;  forward;

var
  vlog_vfs        : TVLogVfs;
  vlog_io_methods : sqlite3_io_methods;

  { vfslog.c:240 — list of all active log connections, protected by the
    static-master mutex. }
  allLogs : PVLogLog = nil;

  { Set to 1 once sqlite3_register_vfslog has installed the methods table. }
  vlogInitialised : cint = 0;

{ REALVFS macro from vfslog.c:93. }
function REALVFS(pVfs: Psqlite3_vfs): Psqlite3_vfs; inline;
begin
  Result := PVLogVfs(pVfs)^.pVfs;
end;

{ ----------------------------------------------------------------------
  vfslog.c:175..200 vlog_time — microseconds since epoch.
  ---------------------------------------------------------------------- }
function vlog_time: u64;
var
  tv : Ttimeval;
begin
  tv.tv_sec  := 0;
  tv.tv_usec := 0;
  vlogLibcGettimeofday(@tv, nil);
  Result := u64(tv.tv_usec) + u64(tv.tv_sec) * u64(1000000);
end;

{ ----------------------------------------------------------------------
  vfslog.c:206..235 vlogLogPrint — write one CSV record.
  ---------------------------------------------------------------------- }
procedure vlogLogPrint(pLog: PVLogLog; tStart, tElapse: i64;
                       zOp: PAnsiChar; iArg1, iArg2: i64;
                       zArg3: PAnsiChar; iRes: cint);
var
  z1, z2 : array[0..39] of AnsiChar;
  z3     : array[0..1999] of AnsiChar;
  isJ    : cint;
  z3Use  : PAnsiChar;
begin
  if pLog = nil then Exit;
  if iArg1 >= 0 then
    sqlite3PfSnprintf(SizeOf(z1), @z1[0], PAnsiChar('%lld'), [iArg1])
  else
    z1[0] := #0;
  if iArg2 >= 0 then
    sqlite3PfSnprintf(SizeOf(z2), @z2[0], PAnsiChar('%lld'), [iArg2])
  else
    z2[0] := #0;
  if zArg3 <> nil then begin
    { vfslog.c uses sqlite3_snprintf(sizeof(z3),z3,"\"%.*w\"", sizeof(z3)-4, zArg3).
      The %w escape doubles embedded ", matching upstream byte-for-byte. }
    sqlite3PfSnprintf(SizeOf(z3), @z3[0],
      PAnsiChar('"%.*w"'), [SizeOf(z3) - 4, zArg3]);
    z3Use := @z3[0];
  end else begin
    z3[0] := #0;
    z3Use := @z3[0];
  end;
  if pLog^.zFilename = nil then isJ := 1 else isJ := 0;
  libc_fprintf(pLog^.outF,
    PAnsiChar('%lld,%lld,%s,%d,%s,%s,%s,%d'#10),
    tStart, tElapse, zOp, isJ,
    PAnsiChar(@z1[0]),
    PAnsiChar(@z2[0]),
    z3Use,
    iRes);
end;

{ ----------------------------------------------------------------------
  vfslog.c:245..258 vlogLogClose.
  ---------------------------------------------------------------------- }
procedure vlogLogClose(p: PVLogLog);
var
  pMutex : Psqlite3_mutex;
begin
  if p = nil then Exit;
  Dec(p^.nRef);
  if (p^.nRef > 0) or (p^.zFilename = nil) then Exit;
  pMutex := sqlite3_mutex_alloc(SQLITE_MUTEX_STATIC_MAIN);
  sqlite3_mutex_enter(pMutex);
  p^.ppPrev^ := p^.pNext;
  if p^.pNext <> nil then p^.pNext^.ppPrev := p^.ppPrev;
  sqlite3_mutex_leave(pMutex);
  libc_fclose(p^.outF);
  sqlite3_free(p);
end;

{ ----------------------------------------------------------------------
  vfslog.c:263..324 vlogLogOpen.

  Allocates a paired VLogLog[2] entry — index 0 carries the database
  filename, index 1 carries a NULL filename and is used to log the
  rollback journal that pairs with the database.  Both entries share the
  same FILE* sink.
  ---------------------------------------------------------------------- }
function vlogLogOpen(zFilename: PAnsiChar): PVLogLog;
var
  nName     : cint;
  isJournal : cint;
  pMutex    : Psqlite3_mutex;
  pLog, pTemp : PVLogLog;
  tNow      : i64;
  pBuf      : PAnsiChar;
  zHost     : array[0..199] of AnsiChar;
  zNameBuf  : PAnsiChar;
begin
  Result    := nil;
  isJournal := 0;
  tNow      := 0;

  if zFilename = nil then Exit;
  nName := StrLen(zFilename);

  { vfslog.c:269 — skip WAL files. }
  if (nName > 4)
   and (zFilename[nName-4] = '-')
   and (zFilename[nName-3] = 'w')
   and (zFilename[nName-2] = 'a')
   and (zFilename[nName-1] = 'l') then
    Exit;

  if (nName > 8)
   and (zFilename[nName-8] = '-')
   and (zFilename[nName-7] = 'j')
   and (zFilename[nName-6] = 'o')
   and (zFilename[nName-5] = 'u')
   and (zFilename[nName-4] = 'r')
   and (zFilename[nName-3] = 'n')
   and (zFilename[nName-2] = 'a')
   and (zFilename[nName-1] = 'l') then begin
    Dec(nName, 8);
    isJournal := 1;
  end else if (nName > 12)
        and (sqlite3_strglob(PAnsiChar('-mj??????9??'),
                             zFilename + nName - 12) = 0) then
    Exit; { Do not log master journal files }

  { Allocate sizeof(*pLog)*2 + nName + 60 bytes (vfslog.c:279).  The
    extra 60 leaves room for "-debuglog-<usec>" plus a NUL. }
  pTemp := PVLogLog(sqlite3_malloc64(SizeOf(TVLogLog)*2 + nName + 60));
  if pTemp = nil then Exit;

  pMutex := sqlite3_mutex_alloc(SQLITE_MUTEX_STATIC_MAIN);
  sqlite3_mutex_enter(pMutex);

  pLog := allLogs;
  while pLog <> nil do begin
    if (pLog^.nFilename = nName)
     and (CompareByte(pLog^.zFilename^, zFilename^, nName) = 0) then
      Break;
    pLog := pLog^.pNext;
  end;

  if pLog = nil then begin
    pLog  := pTemp;
    pTemp := nil;
    FillChar(pLog^, SizeOf(TVLogLog)*2, 0);
    { zFilename buffer follows the two TVLogLog records. }
    pBuf  := PAnsiChar(PByte(pLog) + SizeOf(TVLogLog)*2);
    pLog^.zFilename := pBuf;
    tNow  := i64(vlog_time);
    { Compose "<originalName>-debuglog-<usec>".  We ignore the trailing
      "-journal" suffix when present, matching vfslog.c:294. }
    zNameBuf := sqlite3PfMprintf(PAnsiChar('%.*s-debuglog-%lld'),
                                 [nName, zFilename, tNow]);
    if zNameBuf = nil then begin
      sqlite3_mutex_leave(pMutex);
      sqlite3_free(pLog);
      Exit;
    end;
    Move(zNameBuf^, pBuf^, StrLen(zNameBuf) + 1);
    sqlite3_free(zNameBuf);

    pLog^.outF := libc_fopen(pBuf, PAnsiChar('a'));
    if pLog^.outF = nil then begin
      sqlite3_mutex_leave(pMutex);
      sqlite3_free(pLog);
      Exit;
    end;
    pLog^.nFilename := nName;
    { Second half of the pair shares the same FILE*. }
    PVLogLog(PByte(pLog) + SizeOf(TVLogLog))^.outF := pLog^.outF;

    pLog^.ppPrev := @allLogs;
    if allLogs <> nil then allLogs^.ppPrev := @pLog^.pNext;
    pLog^.pNext  := allLogs;
    allLogs := pLog;
  end;

  sqlite3_mutex_leave(pMutex);

  if pTemp <> nil then
    sqlite3_free(pTemp)
  else begin
    { vfslog.c:313..319 — emit IDENT line on first open. }
    FillChar(zHost, SizeOf(zHost), 0);
    vlogLibcGethostname(@zHost[0], SizeOf(zHost) - 1);
    zHost[High(zHost)] := #0;
    vlogLogPrint(pLog, tNow, 0,
                 PAnsiChar('IDENT'),
                 i64(vlogLibcGetpid), -1,
                 PAnsiChar(@zHost[0]), 0);
  end;

  if (pLog <> nil) and (isJournal <> 0) then
    pLog := PVLogLog(PByte(pLog) + SizeOf(TVLogLog));
  Inc(pLog^.nRef);
  Result := pLog;
end;

{ ----------------------------------------------------------------------
  Per-file methods (vfslog.c:330..600).
  ---------------------------------------------------------------------- }

function vlogClose(pFile: Psqlite3_file): cint; cdecl;
var
  tStart, tElapse : i64;
  rc : cint;
  p  : PVLogFile;
begin
  rc     := SQLITE_OK;
  p      := PVLogFile(pFile);
  tStart := i64(vlog_time);
  if p^.pReal^.pMethods <> nil then
    rc := p^.pReal^.pMethods^.xClose(p^.pReal);
  tElapse := i64(vlog_time) - tStart;
  vlogLogPrint(p^.pLog, tStart, tElapse,
               PAnsiChar('CLOSE'), -1, -1, nil, rc);
  vlogLogClose(p^.pLog);
  Result := rc;
end;

{ vfslog.c:354..370 vlogSignature — hex dump for short blocks, FNV-style
  rolling sum tail for long ones.  The C source reads 32-bit unsigned
  ints natively, so we do the same — both sides are little-endian on
  x86_64. }
procedure vlogSignature(p: PByte; n: cint; zCksum: PAnsiChar);
var
  s0, s1 : u32;
  pI     : ^u32;
  i      : cint;
  byteHex: array[0..2] of AnsiChar;
begin
  if n <= 16 then begin
    for i := 0 to n - 1 do begin
      sqlite3PfSnprintf(3, zCksum + i*2, PAnsiChar('%02x'), [p[i]]);
    end;
    zCksum[n*2] := #0;
  end else begin
    s0 := 0; s1 := 0;
    pI := PUInt32(p);
    i := 0;
    while i < n - 7 do begin
      Inc(s0, pI[0] + s1);
      Inc(s1, pI[1] + s0);
      pI := PUInt32(PByte(pI) + 8);
      Inc(i, 8);
    end;
    for i := 0 to 7 do begin
      sqlite3PfSnprintf(3, @byteHex[0], PAnsiChar('%02x'), [p[i]]);
      zCksum[i*2]   := byteHex[0];
      zCksum[i*2+1] := byteHex[1];
    end;
    sqlite3PfSnprintf(18, zCksum + 16, PAnsiChar('-%08x%08x'), [s0, s1]);
  end;
end;

{ vfslog.c:375..377 — big-endian 32-bit decode. }
function bigToNative(x: PByte): u32; inline;
begin
  Result := (u32(x[0]) shl 24) or (u32(x[1]) shl 16)
         or (u32(x[2]) shl  8) or  u32(x[3]);
end;

function vlogRead(pFile: Psqlite3_file; zBuf: Pointer;
                  iAmt: cint; iOfst: i64): cint; cdecl;
var
  rc : cint;
  tStart, tElapse : i64;
  p  : PVLogFile;
  zSig : array[0..39] of AnsiChar;
  pX   : PByte;
  iCtr : u32;
  nFree: i64;
  zStr : array[0..11] of AnsiChar;
  zFree: PAnsiChar;
begin
  p      := PVLogFile(pFile);
  tStart := i64(vlog_time);
  rc     := p^.pReal^.pMethods^.xRead(p^.pReal, zBuf, iAmt, iOfst);
  tElapse := i64(vlog_time) - tStart;
  if rc = SQLITE_OK then
    vlogSignature(zBuf, iAmt, @zSig[0])
  else
    zSig[0] := #0;
  vlogLogPrint(p^.pLog, tStart, tElapse,
               PAnsiChar('READ'), iAmt, iOfst, @zSig[0], rc);
  if (rc = SQLITE_OK)
   and (p^.pLog <> nil)
   and (p^.pLog^.zFilename <> nil)
   and (iOfst <= 24)
   and (iOfst + iAmt >= 28) then begin
    pX    := PByte(zBuf) + (24 - iOfst);
    nFree := -1;
    zFree := nil;
    iCtr  := bigToNative(pX);
    if iOfst + iAmt >= 40 then begin
      zFree := @zStr[0];
      sqlite3PfSnprintf(SizeOf(zStr), zFree,
                        PAnsiChar('%d'), [bigToNative(pX + 8)]);
      nFree := bigToNative(pX + 12);
    end;
    vlogLogPrint(p^.pLog, tStart, 0,
                 PAnsiChar('CHNGCTR-READ'), i64(iCtr), nFree, zFree, 0);
  end;
  Result := rc;
end;

function vlogWrite(pFile: Psqlite3_file; zBuf: Pointer;
                   iAmt: cint; iOfst: i64): cint; cdecl;
var
  rc : cint;
  tStart, tElapse : i64;
  p  : PVLogFile;
  zSig : array[0..39] of AnsiChar;
  pX   : PByte;
  iCtr : u32;
  nFree: i64;
  zStr : array[0..11] of AnsiChar;
  zFree: PAnsiChar;
begin
  p      := PVLogFile(pFile);
  tStart := i64(vlog_time);
  vlogSignature(zBuf, iAmt, @zSig[0]);
  rc     := p^.pReal^.pMethods^.xWrite(p^.pReal, zBuf, iAmt, iOfst);
  tElapse := i64(vlog_time) - tStart;
  vlogLogPrint(p^.pLog, tStart, tElapse,
               PAnsiChar('WRITE'), iAmt, iOfst, @zSig[0], rc);
  if (rc = SQLITE_OK)
   and (p^.pLog <> nil)
   and (p^.pLog^.zFilename <> nil)
   and (iOfst <= 24)
   and (iOfst + iAmt >= 28) then begin
    pX    := PByte(zBuf) + (24 - iOfst);
    nFree := -1;
    zFree := nil;
    iCtr  := bigToNative(pX);
    if iOfst + iAmt >= 40 then begin
      zFree := @zStr[0];
      sqlite3PfSnprintf(SizeOf(zStr), zFree,
                        PAnsiChar('%d'), [bigToNative(pX + 8)]);
      nFree := bigToNative(pX + 12);
    end;
    vlogLogPrint(p^.pLog, tStart, 0,
                 PAnsiChar('CHNGCTR-WRITE'), i64(iCtr), nFree, zFree, 0);
  end;
  Result := rc;
end;

function vlogTruncate(pFile: Psqlite3_file; size: i64): cint; cdecl;
var
  tStart, tElapse : i64;
  rc : cint;
  p  : PVLogFile;
begin
  p      := PVLogFile(pFile);
  tStart := i64(vlog_time);
  rc     := p^.pReal^.pMethods^.xTruncate(p^.pReal, size);
  tElapse := i64(vlog_time) - tStart;
  vlogLogPrint(p^.pLog, tStart, tElapse,
               PAnsiChar('TRUNCATE'), size, -1, nil, rc);
  Result := rc;
end;

function vlogSync(pFile: Psqlite3_file; flags: cint): cint; cdecl;
var
  tStart, tElapse : i64;
  rc : cint;
  p  : PVLogFile;
begin
  p      := PVLogFile(pFile);
  tStart := i64(vlog_time);
  rc     := p^.pReal^.pMethods^.xSync(p^.pReal, flags);
  tElapse := i64(vlog_time) - tStart;
  vlogLogPrint(p^.pLog, tStart, tElapse,
               PAnsiChar('SYNC'), flags, -1, nil, rc);
  Result := rc;
end;

function vlogFileSize(pFile: Psqlite3_file; pSize: Pi64): cint; cdecl;
var
  tStart, tElapse : i64;
  rc : cint;
  p  : PVLogFile;
begin
  p      := PVLogFile(pFile);
  tStart := i64(vlog_time);
  rc     := p^.pReal^.pMethods^.xFileSize(p^.pReal, pSize);
  tElapse := i64(vlog_time) - tStart;
  vlogLogPrint(p^.pLog, tStart, tElapse,
               PAnsiChar('FILESIZE'), pSize^, -1, nil, rc);
  Result := rc;
end;

function vlogLock(pFile: Psqlite3_file; eLock: cint): cint; cdecl;
var
  tStart, tElapse : i64;
  rc : cint;
  p  : PVLogFile;
begin
  p      := PVLogFile(pFile);
  tStart := i64(vlog_time);
  rc     := p^.pReal^.pMethods^.xLock(p^.pReal, eLock);
  tElapse := i64(vlog_time) - tStart;
  vlogLogPrint(p^.pLog, tStart, tElapse,
               PAnsiChar('LOCK'), eLock, -1, nil, rc);
  Result := rc;
end;

function vlogUnlock(pFile: Psqlite3_file; eLock: cint): cint; cdecl;
var
  tStart : i64;
  p      : PVLogFile;
begin
  p      := PVLogFile(pFile);
  tStart := i64(vlog_time);
  vlogLogPrint(p^.pLog, tStart, 0,
               PAnsiChar('UNLOCK'), eLock, -1, nil, 0);
  Result := p^.pReal^.pMethods^.xUnlock(p^.pReal, eLock);
end;

function vlogCheckReservedLock(pFile: Psqlite3_file;
                               pResOut: PcInt): cint; cdecl;
var
  tStart, tElapse : i64;
  rc : cint;
  p  : PVLogFile;
begin
  p      := PVLogFile(pFile);
  tStart := i64(vlog_time);
  rc     := p^.pReal^.pMethods^.xCheckReservedLock(p^.pReal, pResOut);
  tElapse := i64(vlog_time) - tStart;
  vlogLogPrint(p^.pLog, tStart, tElapse,
               PAnsiChar('CHECKRESERVEDLOCK'),
               pResOut^, -1, PAnsiChar(''), rc);
  Result := rc;
end;

{ Helper for the SQLITE_FCNTL_VFSNAME `*pArg = sqlite3_mprintf("vlog/%z",
  *pArg)` substitution.  The Pascal port's sqlite3_mprintf is a single-
  arg cdecl wrapper, so we emulate the `%z` (concatenate-and-take-
  ownership) variant by hand here. }
function vlogPrependVfsName(z: PAnsiChar): PAnsiChar;
const
  zPre : PAnsiChar = 'vlog/';
var
  nPre, nZ : SizeUInt;
  zNew     : PAnsiChar;
begin
  if z = nil then Exit(nil);
  nPre := StrLen(zPre);
  nZ   := StrLen(z);
  zNew := sqlite3_malloc64(nPre + nZ + 1);
  if zNew = nil then begin
    sqlite3_free(z);
    Exit(nil);
  end;
  Move(zPre^, zNew^, nPre);
  Move(z^, (zNew + nPre)^, nZ);
  zNew[nPre + nZ] := #0;
  sqlite3_free(z);
  Result := zNew;
end;

function vlogFileControl(pFile: Psqlite3_file; op: cint;
                         pArg: Pointer): cint; cdecl;
var
  tStart, tElapse : i64;
  rc : cint;
  p  : PVLogFile;
  sz : i64;
  azArg : PPAnsiChar;
begin
  p      := PVLogFile(pFile);
  tStart := i64(vlog_time);
  rc     := p^.pReal^.pMethods^.xFileControl(p^.pReal, op, pArg);
  if (op = SQLITE_FCNTL_VFSNAME) and (rc = SQLITE_OK) then
    PPAnsiChar(pArg)^ := vlogPrependVfsName(PPAnsiChar(pArg)^);
  tElapse := i64(vlog_time) - tStart;
  if op = SQLITE_FCNTL_TRACE then
    vlogLogPrint(p^.pLog, tStart, tElapse,
                 PAnsiChar('TRACE'), op, -1, PAnsiChar(pArg), rc)
  else if op = SQLITE_FCNTL_PRAGMA then begin
    azArg := PPAnsiChar(pArg);
    vlogLogPrint(p^.pLog, tStart, tElapse,
                 PAnsiChar('FILECONTROL'), op, -1, azArg[1], rc);
  end else if op = SQLITE_FCNTL_SIZE_HINT then begin
    sz := Pi64(pArg)^;
    vlogLogPrint(p^.pLog, tStart, tElapse,
                 PAnsiChar('FILECONTROL'), op, sz, nil, rc);
  end else
    vlogLogPrint(p^.pLog, tStart, tElapse,
                 PAnsiChar('FILECONTROL'), op, -1, nil, rc);
  Result := rc;
end;

function vlogSectorSize(pFile: Psqlite3_file): cint; cdecl;
var
  tStart, tElapse : i64;
  rc : cint;
  p  : PVLogFile;
begin
  p      := PVLogFile(pFile);
  tStart := i64(vlog_time);
  rc     := p^.pReal^.pMethods^.xSectorSize(p^.pReal);
  tElapse := i64(vlog_time) - tStart;
  vlogLogPrint(p^.pLog, tStart, tElapse,
               PAnsiChar('SECTORSIZE'), -1, -1, nil, rc);
  Result := rc;
end;

function vlogDeviceCharacteristics(pFile: Psqlite3_file): cint; cdecl;
var
  tStart, tElapse : i64;
  rc : cint;
  p  : PVLogFile;
begin
  p      := PVLogFile(pFile);
  tStart := i64(vlog_time);
  rc     := p^.pReal^.pMethods^.xDeviceCharacteristics(p^.pReal);
  tElapse := i64(vlog_time) - tStart;
  vlogLogPrint(p^.pLog, tStart, tElapse,
               PAnsiChar('DEVCHAR'), -1, -1, nil, rc);
  Result := rc;
end;

{ ----------------------------------------------------------------------
  Per-VFS methods (vfslog.c:606..750).
  ---------------------------------------------------------------------- }

function vlogOpen(pVfs: Psqlite3_vfs; zName: sqlite3_filename;
                  pFile: Psqlite3_file; flags: cint;
                  pOutFlags: PcInt): cint; cdecl;
var
  rc : cint;
  tStart, tElapse : i64;
  iArg2 : i64;
  p  : PVLogFile;
begin
  p := PVLogFile(pFile);
  p^.pReal := Psqlite3_file(PByte(p) + SizeOf(TVLogFile));
  if (flags and (SQLITE_OPEN_MAIN_DB or SQLITE_OPEN_MAIN_JOURNAL)) <> 0 then
    p^.pLog := vlogLogOpen(zName)
  else
    p^.pLog := nil;
  tStart := i64(vlog_time);
  rc := REALVFS(pVfs)^.xOpen(REALVFS(pVfs), zName, p^.pReal, flags, pOutFlags);
  tElapse := i64(vlog_time) - tStart;
  if pOutFlags <> nil then iArg2 := pOutFlags^ else iArg2 := -1;
  vlogLogPrint(p^.pLog, tStart, tElapse,
               PAnsiChar('OPEN'), flags, iArg2, nil, rc);
  if rc = SQLITE_OK then
    pFile^.pMethods := @vlog_io_methods
  else begin
    if p^.pLog <> nil then vlogLogClose(p^.pLog);
    p^.pLog := nil;
  end;
  Result := rc;
end;

function vlogDelete(pVfs: Psqlite3_vfs; zPath: PChar;
                    syncDir: cint): cint; cdecl;
var
  rc : cint;
  tStart, tElapse : i64;
  pLog : PVLogLog;
begin
  tStart := i64(vlog_time);
  rc     := REALVFS(pVfs)^.xDelete(REALVFS(pVfs), zPath, syncDir);
  tElapse := i64(vlog_time) - tStart;
  pLog   := vlogLogOpen(zPath);
  vlogLogPrint(pLog, tStart, tElapse,
               PAnsiChar('DELETE'), syncDir, -1, nil, rc);
  vlogLogClose(pLog);
  Result := rc;
end;

function vlogAccess(pVfs: Psqlite3_vfs; zPath: PChar; flags: cint;
                    pResOut: PcInt): cint; cdecl;
var
  rc : cint;
  tStart, tElapse : i64;
  pLog : PVLogLog;
begin
  tStart := i64(vlog_time);
  rc     := REALVFS(pVfs)^.xAccess(REALVFS(pVfs), zPath, flags, pResOut);
  tElapse := i64(vlog_time) - tStart;
  pLog   := vlogLogOpen(zPath);
  vlogLogPrint(pLog, tStart, tElapse,
               PAnsiChar('ACCESS'), flags, pResOut^, nil, rc);
  vlogLogClose(pLog);
  Result := rc;
end;

function vlogFullPathname(pVfs: Psqlite3_vfs; zPath: PChar; nOut: cint;
                          zOut: PChar): cint; cdecl;
begin
  Result := REALVFS(pVfs)^.xFullPathname(REALVFS(pVfs), zPath, nOut, zOut);
end;

function vlogDlOpen(pVfs: Psqlite3_vfs; zPath: PChar): Pointer; cdecl;
begin
  Result := REALVFS(pVfs)^.xDlOpen(REALVFS(pVfs), zPath);
end;

procedure vlogDlError(pVfs: Psqlite3_vfs; nByte: cint;
                      zErrMsg: PChar); cdecl;
begin
  REALVFS(pVfs)^.xDlError(REALVFS(pVfs), nByte, zErrMsg);
end;

function vlogDlSym(pVfs: Psqlite3_vfs; p: Pointer;
                   zSym: PChar): sqlite3_syscall_ptr; cdecl;
begin
  Result := REALVFS(pVfs)^.xDlSym(REALVFS(pVfs), p, zSym);
end;

procedure vlogDlClose(pVfs: Psqlite3_vfs; pHandle: Pointer); cdecl;
begin
  REALVFS(pVfs)^.xDlClose(REALVFS(pVfs), pHandle);
end;

function vlogRandomness(pVfs: Psqlite3_vfs; nByte: cint;
                        zBufOut: PChar): cint; cdecl;
begin
  Result := REALVFS(pVfs)^.xRandomness(REALVFS(pVfs), nByte, zBufOut);
end;

function vlogSleep(pVfs: Psqlite3_vfs; nMicro: cint): cint; cdecl;
begin
  Result := REALVFS(pVfs)^.xSleep(REALVFS(pVfs), nMicro);
end;

function vlogCurrentTime(pVfs: Psqlite3_vfs;
                         pTimeOut: PDouble): cint; cdecl;
begin
  Result := REALVFS(pVfs)^.xCurrentTime(REALVFS(pVfs), pTimeOut);
end;

function vlogGetLastError(pVfs: Psqlite3_vfs; a: cint;
                          b: PChar): cint; cdecl;
begin
  Result := REALVFS(pVfs)^.xGetLastError(REALVFS(pVfs), a, b);
end;

function vlogCurrentTimeInt64(pVfs: Psqlite3_vfs; p: Pi64): cint; cdecl;
begin
  Result := REALVFS(pVfs)^.xCurrentTimeInt64(REALVFS(pVfs), p);
end;

{ ----------------------------------------------------------------------
  Initialiser — vfslog.c:755..760 sqlite3_register_vfslog.
  ---------------------------------------------------------------------- }

procedure ensureMethodTablesPopulated;
begin
  if vlogInitialised <> 0 then Exit;

  FillChar(vlog_io_methods, SizeOf(vlog_io_methods), 0);
  vlog_io_methods.iVersion               := 1;
  vlog_io_methods.xClose                 := @vlogClose;
  vlog_io_methods.xRead                  := @vlogRead;
  vlog_io_methods.xWrite                 := @vlogWrite;
  vlog_io_methods.xTruncate              := @vlogTruncate;
  vlog_io_methods.xSync                  := @vlogSync;
  vlog_io_methods.xFileSize              := @vlogFileSize;
  vlog_io_methods.xLock                  := @vlogLock;
  vlog_io_methods.xUnlock                := @vlogUnlock;
  vlog_io_methods.xCheckReservedLock     := @vlogCheckReservedLock;
  vlog_io_methods.xFileControl           := @vlogFileControl;
  vlog_io_methods.xSectorSize            := @vlogSectorSize;
  vlog_io_methods.xDeviceCharacteristics := @vlogDeviceCharacteristics;
  { v2 / v3 stays nil-filled — vfslog is iVersion=1 in upstream. }

  FillChar(vlog_vfs, SizeOf(vlog_vfs), 0);
  vlog_vfs.base.iVersion        := 1;
  vlog_vfs.base.szOsFile        := 0; { set by register call below }
  vlog_vfs.base.mxPathname      := 1024;
  vlog_vfs.base.zName           := PChar('vfslog');
  vlog_vfs.base.xOpen           := @vlogOpen;
  vlog_vfs.base.xDelete         := @vlogDelete;
  vlog_vfs.base.xAccess         := @vlogAccess;
  vlog_vfs.base.xFullPathname   := @vlogFullPathname;
  vlog_vfs.base.xDlOpen         := @vlogDlOpen;
  vlog_vfs.base.xDlError        := @vlogDlError;
  vlog_vfs.base.xDlSym          := @vlogDlSym;
  vlog_vfs.base.xDlClose        := @vlogDlClose;
  vlog_vfs.base.xRandomness     := @vlogRandomness;
  vlog_vfs.base.xSleep          := @vlogSleep;
  vlog_vfs.base.xCurrentTime    := @vlogCurrentTime;
  vlog_vfs.base.xGetLastError   := @vlogGetLastError;
  vlog_vfs.base.xCurrentTimeInt64 := @vlogCurrentTimeInt64;

  vlogInitialised := 1;
end;

function sqlite3_register_vfslog(zArg: PAnsiChar): i32;
begin
  if zArg = zArg then ; { silence unused }
  ensureMethodTablesPopulated;
  vlog_vfs.pVfs := sqlite3_vfs_find(nil);
  if vlog_vfs.pVfs = nil then Exit(SQLITE_ERROR);
  vlog_vfs.base.szOsFile := SizeOf(TVLogFile) + vlog_vfs.pVfs^.szOsFile;
  Result := sqlite3_vfs_register(@vlog_vfs.base, 1);
end;

function sqlite3VfslogInit(db: PTsqlite3): i32;
begin
  if Pointer(db) = Pointer(db) then ;
  Result := sqlite3_register_vfslog(nil);
end;

end.
