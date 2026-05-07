{
  SPDX-License-Identifier: blessing

  Faithful port of ../sqlite3/ext/misc/vfstrace.c (1211 lines in C).

  Implements an SQLite VFS shim that writes a strace-style diagnostic
  trace of every VFS call (xOpen, xRead, xWrite, xLock, xFileControl, ...)
  to a caller-supplied output routine.  Output is "%s.<method>(args) -> rc"
  one line per call.

  Public entries:

    function vfstrace_register(zTraceName, zOldVfsName: PAnsiChar;
                               xOut: TvfstraceOutFn; pOutArg: Pointer;
                               makeDefault: cint): i32;
    procedure vfstrace_unregister(zTraceName: PAnsiChar);

  The output routine matches `fputs` semantics:
    function xOut(zMsg: PAnsiChar; pAppData: Pointer): cint; cdecl;

  The shim is NOT auto-installed by the shell openDb because the trace
  output would corrupt every shell session — same convention as memtrace
  / pcachetrace / showauth.

  Pascal-port adaptations:

  * `vfstrace_printf` uses sqlite3PfMprintf with `array of const`
    instead of C va_list.  Emits via xOut(...).
  * The `aKw[]` keyword table inside the FCNTL_PRAGMA arm is mirrored as
    a constant array of records.
  * Identifier `pTraceVfs` retained but layout matches C `vfstrace_info`.
}
{$I passqlite3.inc}
unit passqlite3vfstrace;

interface

uses
  ctypes,
  passqlite3types,
  passqlite3os,
  passqlite3util,
  passqlite3main;

type
  { Same signature as fputs(s, FILE*).  Non-zero return = success in
    fputs convention; the trace plumbing ignores the return value, but
    we still pass it through. }
  TvfstraceOutFn = function(zMsg: PAnsiChar; pAppData: Pointer): cint; cdecl;

function vfstrace_register(zTraceName, zOldVfsName: PAnsiChar;
                           xOut: TvfstraceOutFn; pOutArg: Pointer;
                           makeDefault: cint): i32;
procedure vfstrace_unregister(zTraceName: PAnsiChar);

implementation

uses
  SysUtils,
  passqlite3printf;

{ -------- types ------------------------------------------------------- }

const
  { vfstrace.c:163..191 — bit values for vfstrace_info.mTrace. }
  VTR_CLOSE       = $00000001;
  VTR_READ        = $00000002;
  VTR_WRITE       = $00000004;
  VTR_TRUNC       = $00000008;
  VTR_SYNC        = $00000010;
  VTR_FSIZE       = $00000020;
  VTR_LOCK        = $00000040;
  VTR_UNLOCK      = $00000080;
  VTR_CRL         = $00000100;
  VTR_FCTRL       = $00000200;
  VTR_SECSZ       = $00000400;
  VTR_DEVCHAR     = $00000800;
  VTR_SHMLOCK    = $00001000;
  VTR_SHMMAP     = $00002000;
  VTR_SHMBAR     = $00004000;
  VTR_SHMUNMAP   = $00008000;
  VTR_OPEN        = $00010000;
  VTR_DELETE     = $00020000;
  VTR_ACCESS     = $00040000;
  VTR_FULLPATH   = $00080000;
  VTR_DLOPEN     = $00100000;
  VTR_DLERR      = $00200000;
  VTR_DLSYM      = $00400000;
  VTR_DLCLOSE    = $00800000;
  VTR_RAND        = $01000000;
  VTR_SLEEP      = $02000000;
  VTR_CURTIME    = $04000000;
  VTR_LASTERR    = $08000000;
  VTR_FETCH      = $10000000;

type
  PvfstraceInfo = ^TvfstraceInfo;
  TvfstraceInfo = record
    pRootVfs  : Psqlite3_vfs;        { The underlying real VFS }
    xOut      : TvfstraceOutFn;      { Send output here }
    mTrace    : cuint;               { Mask of interfaces to trace }
    bOn       : cuchar;              { Tracing on/off }
    pOutArg   : Pointer;             { First argument to xOut }
    zVfsName  : PAnsiChar;           { Name of this trace-VFS }
    pTraceVfs : Psqlite3_vfs;        { Pointer back to the trace VFS }
  end;

  PvfstraceFile = ^TvfstraceFile;
  TvfstraceFile = record
    base   : sqlite3_file;     { Base class.  MUST BE FIRST. }
    pInfo  : PvfstraceInfo;    { The trace-VFS to which this file belongs }
    zFName : PAnsiChar;        { Base name of the file }
    pReal  : Psqlite3_file;    { The real underlying file }
  end;

{ -------- forward decls of methods ------------------------------------ }

function vfstraceClose(pFile: Psqlite3_file): cint; cdecl; forward;
function vfstraceRead(pFile: Psqlite3_file; zBuf: Pointer;
                      iAmt: cint; iOfst: i64): cint; cdecl; forward;
function vfstraceWrite(pFile: Psqlite3_file; zBuf: Pointer;
                       iAmt: cint; iOfst: i64): cint; cdecl; forward;
function vfstraceTruncate(pFile: Psqlite3_file; size: i64): cint; cdecl; forward;
function vfstraceSync(pFile: Psqlite3_file; flags: cint): cint; cdecl; forward;
function vfstraceFileSize(pFile: Psqlite3_file; pSize: Pi64): cint; cdecl; forward;
function vfstraceLock(pFile: Psqlite3_file; eLock: cint): cint; cdecl; forward;
function vfstraceUnlock(pFile: Psqlite3_file; eLock: cint): cint; cdecl; forward;
function vfstraceCheckReservedLock(pFile: Psqlite3_file;
                                   pResOut: PcInt): cint; cdecl; forward;
function vfstraceFileControl(pFile: Psqlite3_file; op: cint;
                             pArg: Pointer): cint; cdecl; forward;
function vfstraceSectorSize(pFile: Psqlite3_file): cint; cdecl; forward;
function vfstraceDeviceCharacteristics(pFile: Psqlite3_file): cint; cdecl;
                                       forward;
function vfstraceShmLock(pFile: Psqlite3_file; ofst, n,
                         flags: cint): cint; cdecl; forward;
function vfstraceShmMap(pFile: Psqlite3_file; iRegion, szRegion,
                        isWrite: cint; pp: PPointer): cint; cdecl; forward;
procedure vfstraceShmBarrier(pFile: Psqlite3_file); cdecl; forward;
function vfstraceShmUnmap(pFile: Psqlite3_file; delFlag: cint): cint;
                          cdecl; forward;
function vfstraceFetch(pFile: Psqlite3_file; iOff: i64; nAmt: cint;
                       pptr: PPointer): cint; cdecl; forward;
function vfstraceUnfetch(pFile: Psqlite3_file; iOff: i64;
                         ptr: Pointer): cint; cdecl; forward;

function vfstraceOpen(pVfs: Psqlite3_vfs; zName: sqlite3_filename;
                      pFile: Psqlite3_file; flags: cint;
                      pOutFlags: PcInt): cint; cdecl; forward;
function vfstraceDelete(pVfs: Psqlite3_vfs; zPath: PChar;
                        syncDir: cint): cint; cdecl; forward;
function vfstraceAccess(pVfs: Psqlite3_vfs; zPath: PChar; flags: cint;
                        pResOut: PcInt): cint; cdecl; forward;
function vfstraceFullPathname(pVfs: Psqlite3_vfs; zPath: PChar;
                              nOut: cint; zOut: PChar): cint; cdecl; forward;
function vfstraceDlOpen(pVfs: Psqlite3_vfs; zPath: PChar): Pointer;
                        cdecl; forward;
procedure vfstraceDlError(pVfs: Psqlite3_vfs; nByte: cint;
                          zErrMsg: PChar); cdecl; forward;
function vfstraceDlSym(pVfs: Psqlite3_vfs; p: Pointer;
                       zSym: PChar): sqlite3_syscall_ptr; cdecl; forward;
procedure vfstraceDlClose(pVfs: Psqlite3_vfs; pHandle: Pointer);
                          cdecl; forward;
function vfstraceRandomness(pVfs: Psqlite3_vfs; nByte: cint;
                            zBufOut: PChar): cint; cdecl; forward;
function vfstraceSleep(pVfs: Psqlite3_vfs; nMicro: cint): cint;
                       cdecl; forward;
function vfstraceCurrentTime(pVfs: Psqlite3_vfs;
                             pTimeOut: PDouble): cint; cdecl; forward;
function vfstraceCurrentTimeInt64(pVfs: Psqlite3_vfs;
                                  pTimeOut: Pi64): cint; cdecl; forward;
function vfstraceGetLastError(pVfs: Psqlite3_vfs; nErr: cint;
                              zErr: PChar): cint; cdecl; forward;
function vfstraceSetSystemCall(pVfs: Psqlite3_vfs; zName: PChar;
                               pNewFunc: sqlite3_syscall_ptr): cint;
                               cdecl; forward;
function vfstraceGetSystemCall(pVfs: Psqlite3_vfs;
                               zName: PChar): sqlite3_syscall_ptr;
                               cdecl; forward;
function vfstraceNextSystemCall(pVfs: Psqlite3_vfs;
                                zName: PChar): PChar; cdecl; forward;

{ -------- helpers ----------------------------------------------------- }

{ vfstrace.c:239..245 fileTail — return pointer to base name of a path. }
function fileTail(z: PAnsiChar): PAnsiChar;
var
  i : SizeUInt;
begin
  if z = nil then begin
    Result := nil;
    Exit;
  end;
  i := StrLen(z);
  if i > 0 then Dec(i);
  while (i > 0) and (z[i-1] <> '/') do Dec(i);
  Result := z + i;
end;

{ vfstrace.c:250..264 vfstrace_printf — emit one trace line. }
procedure vfstrace_printf(pInfo: PvfstraceInfo; zFormat: PAnsiChar;
                          const args: array of const);
var
  zMsg : PAnsiChar;
begin
  if pInfo^.bOn = 0 then Exit;
  zMsg := sqlite3PfMprintf(zFormat, args);
  if zMsg <> nil then begin
    pInfo^.xOut(zMsg, pInfo^.pOutArg);
    sqlite3_free(zMsg);
  end;
end;

{ vfstrace.c:269..326 vfstrace_errcode_name — resolve rc to symbolic
  string.  Returns nil if unknown. }
function vfstrace_errcode_name(rc: cint): PAnsiChar;
begin
  case rc of
    SQLITE_OK:                   Result := 'SQLITE_OK';
    SQLITE_INTERNAL:             Result := 'SQLITE_INTERNAL';
    SQLITE_ERROR:                Result := 'SQLITE_ERROR';
    SQLITE_PERM:                 Result := 'SQLITE_PERM';
    SQLITE_ABORT:                Result := 'SQLITE_ABORT';
    SQLITE_BUSY:                 Result := 'SQLITE_BUSY';
    SQLITE_LOCKED:               Result := 'SQLITE_LOCKED';
    SQLITE_NOMEM:                Result := 'SQLITE_NOMEM';
    SQLITE_READONLY:             Result := 'SQLITE_READONLY';
    SQLITE_INTERRUPT:            Result := 'SQLITE_INTERRUPT';
    SQLITE_IOERR:                Result := 'SQLITE_IOERR';
    SQLITE_CORRUPT:              Result := 'SQLITE_CORRUPT';
    SQLITE_NOTFOUND:             Result := 'SQLITE_NOTFOUND';
    SQLITE_FULL:                 Result := 'SQLITE_FULL';
    SQLITE_CANTOPEN:             Result := 'SQLITE_CANTOPEN';
    SQLITE_PROTOCOL:             Result := 'SQLITE_PROTOCOL';
    SQLITE_EMPTY:                Result := 'SQLITE_EMPTY';
    SQLITE_SCHEMA:               Result := 'SQLITE_SCHEMA';
    SQLITE_TOOBIG:               Result := 'SQLITE_TOOBIG';
    SQLITE_CONSTRAINT:           Result := 'SQLITE_CONSTRAINT';
    SQLITE_MISMATCH:             Result := 'SQLITE_MISMATCH';
    SQLITE_MISUSE:               Result := 'SQLITE_MISUSE';
    SQLITE_NOLFS:                Result := 'SQLITE_NOLFS';
    SQLITE_IOERR_READ:           Result := 'SQLITE_IOERR_READ';
    SQLITE_IOERR_SHORT_READ:     Result := 'SQLITE_IOERR_SHORT_READ';
    SQLITE_IOERR_WRITE:          Result := 'SQLITE_IOERR_WRITE';
    SQLITE_IOERR_FSYNC:          Result := 'SQLITE_IOERR_FSYNC';
    SQLITE_IOERR_DIR_FSYNC:      Result := 'SQLITE_IOERR_DIR_FSYNC';
    SQLITE_IOERR_TRUNCATE:       Result := 'SQLITE_IOERR_TRUNCATE';
    SQLITE_IOERR_FSTAT:          Result := 'SQLITE_IOERR_FSTAT';
    SQLITE_IOERR_UNLOCK:         Result := 'SQLITE_IOERR_UNLOCK';
    SQLITE_IOERR_RDLOCK:         Result := 'SQLITE_IOERR_RDLOCK';
    SQLITE_IOERR_DELETE:         Result := 'SQLITE_IOERR_DELETE';
    SQLITE_IOERR_BLOCKED:        Result := 'SQLITE_IOERR_BLOCKED';
    SQLITE_IOERR_NOMEM:          Result := 'SQLITE_IOERR_NOMEM';
    SQLITE_IOERR_ACCESS:         Result := 'SQLITE_IOERR_ACCESS';
    SQLITE_IOERR_CHECKRESERVEDLOCK:
                                 Result := 'SQLITE_IOERR_CHECKRESERVEDLOCK';
    SQLITE_IOERR_LOCK:           Result := 'SQLITE_IOERR_LOCK';
    SQLITE_IOERR_CLOSE:          Result := 'SQLITE_IOERR_CLOSE';
    SQLITE_IOERR_DIR_CLOSE:      Result := 'SQLITE_IOERR_DIR_CLOSE';
    SQLITE_IOERR_SHMOPEN:        Result := 'SQLITE_IOERR_SHMOPEN';
    SQLITE_IOERR_SHMSIZE:        Result := 'SQLITE_IOERR_SHMSIZE';
    SQLITE_IOERR_SHMLOCK:        Result := 'SQLITE_IOERR_SHMLOCK';
    SQLITE_IOERR_SHMMAP:         Result := 'SQLITE_IOERR_SHMMAP';
    SQLITE_IOERR_SEEK:           Result := 'SQLITE_IOERR_SEEK';
    SQLITE_IOERR_GETTEMPPATH:    Result := 'SQLITE_IOERR_GETTEMPPATH';
    SQLITE_IOERR_CONVPATH:       Result := 'SQLITE_IOERR_CONVPATH';
    SQLITE_READONLY_DBMOVED:     Result := 'SQLITE_READONLY_DBMOVED';
    SQLITE_LOCKED_SHAREDCACHE:   Result := 'SQLITE_LOCKED_SHAREDCACHE';
    SQLITE_BUSY_RECOVERY:        Result := 'SQLITE_BUSY_RECOVERY';
    SQLITE_CANTOPEN_NOTEMPDIR:   Result := 'SQLITE_CANTOPEN_NOTEMPDIR';
  else
    Result := nil;
  end;
end;

{ vfstrace.c:332..350 vfstrace_print_errcode — resolve rc and emit. }
procedure vfstrace_print_errcode(pInfo: PvfstraceInfo;
                                 zFormat: PAnsiChar; rc: cint);
var
  zVal : PAnsiChar;
  zBuf : array[0..63] of AnsiChar;
begin
  zVal := vfstrace_errcode_name(rc);
  if zVal = nil then begin
    zVal := vfstrace_errcode_name(rc and $ff);
    if zVal <> nil then
      sqlite3PfSnprintf(SizeOf(zBuf), @zBuf[0],
        PAnsiChar('%s | 0x%x'), [zVal, rc and $ffff00])
    else
      sqlite3PfSnprintf(SizeOf(zBuf), @zBuf[0],
        PAnsiChar('%d (0x%x)'), [rc, rc]);
    zVal := @zBuf[0];
  end;
  vfstrace_printf(pInfo, zFormat, [zVal]);
end;

{ vfstrace.c:355..360 strappend — append zAppend to z at offset *pI. }
procedure strappend(z: PAnsiChar; pI: PcInt; zAppend: PAnsiChar);
var
  i : cint;
begin
  i := pI^;
  while zAppend^ <> #0 do begin
    z[i] := zAppend^; Inc(i); Inc(zAppend);
  end;
  z[i] := #0;
  pI^ := i;
end;

{ vfstrace.c:365..367 vfstraceOnOff — toggle bOn from mask. }
procedure vfstraceOnOff(pInfo: PvfstraceInfo; mMask: cuint);
begin
  if (pInfo^.mTrace and mMask) <> 0 then
    pInfo^.bOn := 1
  else
    pInfo^.bOn := 0;
end;

{ vfstrace.c:485..494 lockName — symbolic name for SQLITE_LOCK_*. }
function lockName(eLock: cint): PAnsiChar;
const
  azLockNames : array[0..4] of PAnsiChar = (
    'NONE', 'SHARED', 'RESERVED', 'PENDING', 'EXCLUSIVE'
  );
begin
  if (eLock < 0) or (eLock > 4) then
    Result := '???'
  else
    Result := azLockNames[eLock];
end;

{ -------- vfstrace_file methods --------------------------------------- }

function vfstraceClose(pFile: Psqlite3_file): cint; cdecl;
var
  p     : PvfstraceFile;
  pInfo : PvfstraceInfo;
  rc    : cint;
begin
  p := PvfstraceFile(pFile);
  pInfo := p^.pInfo;
  vfstraceOnOff(pInfo, VTR_CLOSE);
  vfstrace_printf(pInfo, '%s.xClose(%s)', [pInfo^.zVfsName, p^.zFName]);
  rc := p^.pReal^.pMethods^.xClose(p^.pReal);
  vfstrace_print_errcode(pInfo, ' -> %s'#10, rc);
  if rc = SQLITE_OK then begin
    sqlite3_free(Pointer(p^.base.pMethods));
    p^.base.pMethods := nil;
  end;
  Result := rc;
end;

function vfstraceRead(pFile: Psqlite3_file; zBuf: Pointer;
                      iAmt: cint; iOfst: i64): cint; cdecl;
var
  p     : PvfstraceFile;
  pInfo : PvfstraceInfo;
  rc    : cint;
begin
  p := PvfstraceFile(pFile);
  pInfo := p^.pInfo;
  vfstraceOnOff(pInfo, VTR_READ);
  vfstrace_printf(pInfo, '%s.xRead(%s,n=%d,ofst=%lld)',
    [pInfo^.zVfsName, p^.zFName, iAmt, iOfst]);
  rc := p^.pReal^.pMethods^.xRead(p^.pReal, zBuf, iAmt, iOfst);
  vfstrace_print_errcode(pInfo, ' -> %s'#10, rc);
  Result := rc;
end;

function vfstraceWrite(pFile: Psqlite3_file; zBuf: Pointer;
                       iAmt: cint; iOfst: i64): cint; cdecl;
var
  p     : PvfstraceFile;
  pInfo : PvfstraceInfo;
  rc    : cint;
begin
  p := PvfstraceFile(pFile);
  pInfo := p^.pInfo;
  vfstraceOnOff(pInfo, VTR_WRITE);
  vfstrace_printf(pInfo, '%s.xWrite(%s,n=%d,ofst=%lld)',
    [pInfo^.zVfsName, p^.zFName, iAmt, iOfst]);
  rc := p^.pReal^.pMethods^.xWrite(p^.pReal, zBuf, iAmt, iOfst);
  vfstrace_print_errcode(pInfo, ' -> %s'#10, rc);
  Result := rc;
end;

function vfstraceTruncate(pFile: Psqlite3_file; size: i64): cint; cdecl;
var
  p     : PvfstraceFile;
  pInfo : PvfstraceInfo;
  rc    : cint;
begin
  p := PvfstraceFile(pFile);
  pInfo := p^.pInfo;
  vfstraceOnOff(pInfo, VTR_TRUNC);
  vfstrace_printf(pInfo, '%s.xTruncate(%s,%lld)',
    [pInfo^.zVfsName, p^.zFName, size]);
  rc := p^.pReal^.pMethods^.xTruncate(p^.pReal, size);
  vfstrace_printf(pInfo, ' -> %d'#10, [rc]);
  Result := rc;
end;

function vfstraceSync(pFile: Psqlite3_file; flags: cint): cint; cdecl;
const
  SQLITE_SYNC_NORMAL_   = $00002;
  SQLITE_SYNC_FULL_     = $00003;
  SQLITE_SYNC_DATAONLY_ = $00010;
var
  p     : PvfstraceFile;
  pInfo : PvfstraceInfo;
  rc, i : cint;
  zBuf  : array[0..127] of AnsiChar;
begin
  p := PvfstraceFile(pFile);
  pInfo := p^.pInfo;
  zBuf[0] := '|'; zBuf[1] := '0'; zBuf[2] := #0;
  i := 0;
  if (flags and SQLITE_SYNC_FULL_) = SQLITE_SYNC_FULL_ then
    strappend(@zBuf[0], @i, '|FULL')
  else if (flags and SQLITE_SYNC_NORMAL_) <> 0 then
    strappend(@zBuf[0], @i, '|NORMAL');
  if (flags and SQLITE_SYNC_DATAONLY_) <> 0 then
    strappend(@zBuf[0], @i, '|DATAONLY');
  if (flags and (not (SQLITE_SYNC_FULL_ or SQLITE_SYNC_DATAONLY_))) <> 0 then
    sqlite3PfSnprintf(SizeOf(zBuf) - i, @zBuf[i],
      PAnsiChar('|0x%x'), [flags]);
  vfstraceOnOff(pInfo, VTR_SYNC);
  vfstrace_printf(pInfo, '%s.xSync(%s,%s)',
    [pInfo^.zVfsName, p^.zFName, PAnsiChar(@zBuf[1])]);
  rc := p^.pReal^.pMethods^.xSync(p^.pReal, flags);
  vfstrace_printf(pInfo, ' -> %d'#10, [rc]);
  Result := rc;
end;

function vfstraceFileSize(pFile: Psqlite3_file; pSize: Pi64): cint; cdecl;
var
  p     : PvfstraceFile;
  pInfo : PvfstraceInfo;
  rc    : cint;
begin
  p := PvfstraceFile(pFile);
  pInfo := p^.pInfo;
  vfstraceOnOff(pInfo, VTR_FSIZE);
  vfstrace_printf(pInfo, '%s.xFileSize(%s)',
    [pInfo^.zVfsName, p^.zFName]);
  rc := p^.pReal^.pMethods^.xFileSize(p^.pReal, pSize);
  vfstrace_print_errcode(pInfo, ' -> %s,', rc);
  vfstrace_printf(pInfo, ' size=%lld'#10, [pSize^]);
  Result := rc;
end;

function vfstraceLock(pFile: Psqlite3_file; eLock: cint): cint; cdecl;
var
  p     : PvfstraceFile;
  pInfo : PvfstraceInfo;
  rc    : cint;
begin
  p := PvfstraceFile(pFile);
  pInfo := p^.pInfo;
  vfstraceOnOff(pInfo, VTR_LOCK);
  vfstrace_printf(pInfo, '%s.xLock(%s,%s)',
    [pInfo^.zVfsName, p^.zFName, lockName(eLock)]);
  rc := p^.pReal^.pMethods^.xLock(p^.pReal, eLock);
  vfstrace_print_errcode(pInfo, ' -> %s'#10, rc);
  Result := rc;
end;

function vfstraceUnlock(pFile: Psqlite3_file; eLock: cint): cint; cdecl;
var
  p     : PvfstraceFile;
  pInfo : PvfstraceInfo;
  rc    : cint;
begin
  p := PvfstraceFile(pFile);
  pInfo := p^.pInfo;
  vfstraceOnOff(pInfo, VTR_UNLOCK);
  vfstrace_printf(pInfo, '%s.xUnlock(%s,%s)',
    [pInfo^.zVfsName, p^.zFName, lockName(eLock)]);
  rc := p^.pReal^.pMethods^.xUnlock(p^.pReal, eLock);
  vfstrace_print_errcode(pInfo, ' -> %s'#10, rc);
  Result := rc;
end;

function vfstraceCheckReservedLock(pFile: Psqlite3_file;
                                   pResOut: PcInt): cint; cdecl;
var
  p     : PvfstraceFile;
  pInfo : PvfstraceInfo;
  rc    : cint;
begin
  p := PvfstraceFile(pFile);
  pInfo := p^.pInfo;
  vfstraceOnOff(pInfo, VTR_CRL);
  vfstrace_printf(pInfo, '%s.xCheckReservedLock(%s)',
    [pInfo^.zVfsName, p^.zFName]);
  rc := p^.pReal^.pMethods^.xCheckReservedLock(p^.pReal, pResOut);
  vfstrace_print_errcode(pInfo, ' -> %s', rc);
  vfstrace_printf(pInfo, ', out=%d'#10, [pResOut^]);
  Result := rc;
end;

{ vfstrace.c:545..742 vfstraceFileControl. }
function vfstraceFileControl(pFile: Psqlite3_file; op: cint;
                             pArg: Pointer): cint; cdecl;
const
  { 0xca093fa0 = SQLITE_FCNTL_DB_UNCHANGED (debug-only opcode) }
  FCNTL_DB_UNCHANGED = i32($ca093fa0);
type
  TKwRow = record z: PAnsiChar; m: cuint; end;
const
  aKw : array[0..30] of TKwRow = (
    (z: 'all';                    m: $ffffffff),
    (z: 'close';                  m: VTR_CLOSE),
    (z: 'read';                   m: VTR_READ),
    (z: 'write';                  m: VTR_WRITE),
    (z: 'truncate';               m: VTR_TRUNC),
    (z: 'sync';                   m: VTR_SYNC),
    (z: 'filesize';               m: VTR_FSIZE),
    (z: 'lock';                   m: VTR_LOCK),
    (z: 'unlock';                 m: VTR_UNLOCK),
    (z: 'checkreservedlock';      m: VTR_CRL),
    (z: 'filecontrol';            m: VTR_FCTRL),
    (z: 'sectorsize';             m: VTR_SECSZ),
    (z: 'devicecharacteristics';  m: VTR_DEVCHAR),
    (z: 'shmlock';                m: VTR_SHMLOCK),
    (z: 'shmmap';                 m: VTR_SHMMAP),
    (z: 'shmummap';               m: VTR_SHMUNMAP),
    (z: 'shmbarrier';             m: VTR_SHMBAR),
    (z: 'open';                   m: VTR_OPEN),
    (z: 'delete';                 m: VTR_DELETE),
    (z: 'access';                 m: VTR_ACCESS),
    (z: 'fullpathname';           m: VTR_FULLPATH),
    (z: 'dlopen';                 m: VTR_DLOPEN),
    (z: 'dlerror';                m: VTR_DLERR),
    (z: 'dlsym';                  m: VTR_DLSYM),
    (z: 'dlclose';                m: VTR_DLCLOSE),
    (z: 'randomness';             m: VTR_RAND),
    (z: 'sleep';                  m: VTR_SLEEP),
    (z: 'currenttime';            m: VTR_CURTIME),
    (z: 'currenttimeint64';       m: VTR_CURTIME),
    (z: 'getlasterror';           m: VTR_LASTERR),
    (z: 'fetch';                  m: VTR_FETCH)
  );
var
  p     : PvfstraceFile;
  pInfo : PvfstraceInfo;
  rc    : cint;
  zBuf  : array[0..127] of AnsiChar;
  zBuf2 : array[0..127] of AnsiChar;
  zOp   : PAnsiChar;
  zRVal : PAnsiChar;
  a     : PPAnsiChar;
  zArg  : PAnsiChar;
  onOff, jj, n: cint;
begin
  p := PvfstraceFile(pFile);
  pInfo := p^.pInfo;
  zRVal := nil;
  zOp := nil;
  vfstraceOnOff(pInfo, VTR_FCTRL);
  case op of
    SQLITE_FCNTL_LOCKSTATE:           zOp := 'LOCKSTATE';
    SQLITE_FCNTL_GET_LOCKPROXYFILE:   zOp := 'GET_LOCKPROXYFILE';
    SQLITE_FCNTL_SET_LOCKPROXYFILE:   zOp := 'SET_LOCKPROXYFILE';
    SQLITE_FCNTL_LAST_ERRNO:          zOp := 'LAST_ERRNO';
    SQLITE_FCNTL_SIZE_HINT:
      begin
        sqlite3PfSnprintf(SizeOf(zBuf), @zBuf[0],
          PAnsiChar('SIZE_HINT,%lld'), [Pi64(pArg)^]);
        zOp := @zBuf[0];
      end;
    SQLITE_FCNTL_CHUNK_SIZE:
      begin
        sqlite3PfSnprintf(SizeOf(zBuf), @zBuf[0],
          PAnsiChar('CHUNK_SIZE,%d'), [PcInt(pArg)^]);
        zOp := @zBuf[0];
      end;
    SQLITE_FCNTL_FILE_POINTER:        zOp := 'FILE_POINTER';
    SQLITE_FCNTL_WIN32_AV_RETRY:      zOp := 'WIN32_AV_RETRY';
    SQLITE_FCNTL_PERSIST_WAL:
      begin
        sqlite3PfSnprintf(SizeOf(zBuf), @zBuf[0],
          PAnsiChar('PERSIST_WAL,%d'), [PcInt(pArg)^]);
        zOp := @zBuf[0];
      end;
    SQLITE_FCNTL_OVERWRITE:           zOp := 'OVERWRITE';
    SQLITE_FCNTL_VFSNAME:             zOp := 'VFSNAME';
    SQLITE_FCNTL_POWERSAFE_OVERWRITE: zOp := 'POWERSAFE_OVERWRITE';
    SQLITE_FCNTL_PRAGMA:
      begin
        a := PPAnsiChar(pArg);
        if (a[1] <> nil) and (StrPas(a[1]) = 'vfstrace') and
           (a[2] <> nil) then begin
          zArg := a[2];
          if (zArg[0] >= '0') and (zArg[0] <= '9') then begin
            { strtoll on a[2] with base 0 — accept hex/octal/decimal.
              We just use a quick base-10 fallback (the documented form);
              if hex/octal needed in future, expand. }
            pInfo^.mTrace := cuint(StrToInt64Def(StrPas(zArg), 0));
          end else begin
            onOff := 1;
            while zArg[0] <> #0 do begin
              while (zArg[0] <> #0) and (zArg[0] <> '-') and (zArg[0] <> '+')
                    and not ((zArg[0] in ['a'..'z','A'..'Z'])) do
                Inc(zArg);
              if zArg[0] = #0 then Break;
              if zArg[0] = '-' then begin onOff := 0; Inc(zArg); end
              else if zArg[0] = '+' then begin onOff := 1; Inc(zArg); end;
              while not (zArg[0] in ['a'..'z','A'..'Z']) do begin
                if zArg[0] = #0 then Break;
                Inc(zArg);
              end;
              if (zArg[0] = 'x') and (zArg[1] in ['a'..'z','A'..'Z']) then
                Inc(zArg);
              n := 0;
              while zArg[n] in ['a'..'z','A'..'Z'] do Inc(n);
              for jj := 0 to High(aKw) do begin
                if sqlite3_strnicmp(aKw[jj].z, zArg, n) = 0 then begin
                  if onOff <> 0 then
                    pInfo^.mTrace := pInfo^.mTrace or aKw[jj].m
                  else
                    pInfo^.mTrace := pInfo^.mTrace and (not aKw[jj].m);
                  Break;
                end;
              end;
              Inc(zArg, n);
            end;
          end;
        end;
        sqlite3PfSnprintf(SizeOf(zBuf), @zBuf[0],
          PAnsiChar('PRAGMA,[%s,%s]'), [a[1], a[2]]);
        zOp := @zBuf[0];
      end;
    SQLITE_FCNTL_BUSYHANDLER:         zOp := 'BUSYHANDLER';
    SQLITE_FCNTL_TEMPFILENAME:        zOp := 'TEMPFILENAME';
    SQLITE_FCNTL_MMAP_SIZE:
      begin
        sqlite3PfSnprintf(SizeOf(zBuf), @zBuf[0],
          PAnsiChar('MMAP_SIZE,%lld'), [Pi64(pArg)^]);
        zOp := @zBuf[0];
      end;
    SQLITE_FCNTL_TRACE:               zOp := 'TRACE';
    SQLITE_FCNTL_HAS_MOVED:           zOp := 'HAS_MOVED';
    SQLITE_FCNTL_SYNC:                zOp := 'SYNC';
    SQLITE_FCNTL_COMMIT_PHASETWO:     zOp := 'COMMIT_PHASETWO';
    SQLITE_FCNTL_WIN32_SET_HANDLE:    zOp := 'WIN32_SET_HANDLE';
    SQLITE_FCNTL_WAL_BLOCK:           zOp := 'WAL_BLOCK';
    SQLITE_FCNTL_ZIPVFS:              zOp := 'ZIPVFS';
    SQLITE_FCNTL_RBU:                 zOp := 'RBU';
    SQLITE_FCNTL_VFS_POINTER:         zOp := 'VFS_POINTER';
    SQLITE_FCNTL_JOURNAL_POINTER:     zOp := 'JOURNAL_POINTER';
    SQLITE_FCNTL_WIN32_GET_HANDLE:    zOp := 'WIN32_GET_HANDLE';
    SQLITE_FCNTL_PDB:                 zOp := 'PDB';
    SQLITE_FCNTL_BEGIN_ATOMIC_WRITE:  zOp := 'BEGIN_ATOMIC_WRITE';
    SQLITE_FCNTL_COMMIT_ATOMIC_WRITE: zOp := 'COMMIT_ATOMIC_WRITE';
    SQLITE_FCNTL_ROLLBACK_ATOMIC_WRITE: zOp := 'ROLLBACK_ATOMIC_WRITE';
    SQLITE_FCNTL_LOCK_TIMEOUT:
      begin
        sqlite3PfSnprintf(SizeOf(zBuf), @zBuf[0],
          PAnsiChar('LOCK_TIMEOUT,%d'), [PcInt(pArg)^]);
        zOp := @zBuf[0];
      end;
    SQLITE_FCNTL_DATA_VERSION:        zOp := 'DATA_VERSION';
    SQLITE_FCNTL_SIZE_LIMIT:          zOp := 'SIZE_LIMIT';
    SQLITE_FCNTL_CKPT_DONE:           zOp := 'CKPT_DONE';
    SQLITE_FCNTL_RESERVE_BYTES:       zOp := 'RESERVED_BYTES';
    SQLITE_FCNTL_CKPT_START:          zOp := 'CKPT_START';
    SQLITE_FCNTL_EXTERNAL_READER:     zOp := 'EXTERNAL_READER';
    SQLITE_FCNTL_CKSM_FILE:           zOp := 'CKSM_FILE';
    SQLITE_FCNTL_RESET_CACHE:         zOp := 'RESET_CACHE';
    FCNTL_DB_UNCHANGED:               zOp := 'DB_UNCHANGED';
  else
    sqlite3PfSnprintf(SizeOf(zBuf), @zBuf[0], PAnsiChar('%d'), [op]);
    zOp := @zBuf[0];
  end;
  vfstrace_printf(pInfo, '%s.xFileControl(%s,%s)',
    [pInfo^.zVfsName, p^.zFName, zOp]);
  rc := p^.pReal^.pMethods^.xFileControl(p^.pReal, op, pArg);
  if rc = SQLITE_OK then begin
    case op of
      SQLITE_FCNTL_VFSNAME:
        begin
          PPAnsiChar(pArg)^ := sqlite3PfMprintf(
            PAnsiChar('vfstrace.%s/%z'),
            [pInfo^.zVfsName, PPAnsiChar(pArg)^]);
          zRVal := PPAnsiChar(pArg)^;
        end;
      SQLITE_FCNTL_MMAP_SIZE:
        begin
          sqlite3PfSnprintf(SizeOf(zBuf2), @zBuf2[0],
            PAnsiChar('%lld'), [Pi64(pArg)^]);
          zRVal := @zBuf2[0];
        end;
      SQLITE_FCNTL_HAS_MOVED, SQLITE_FCNTL_PERSIST_WAL:
        begin
          sqlite3PfSnprintf(SizeOf(zBuf2), @zBuf2[0],
            PAnsiChar('%d'), [PcInt(pArg)^]);
          zRVal := @zBuf2[0];
        end;
      SQLITE_FCNTL_PRAGMA, SQLITE_FCNTL_TEMPFILENAME:
        zRVal := PPAnsiChar(pArg)^;
    end;
  end;
  if zRVal <> nil then begin
    vfstrace_print_errcode(pInfo, ' -> %s', rc);
    vfstrace_printf(pInfo, ', %s'#10, [zRVal]);
  end else
    vfstrace_print_errcode(pInfo, ' -> %s'#10, rc);
  Result := rc;
end;

function vfstraceSectorSize(pFile: Psqlite3_file): cint; cdecl;
var
  p     : PvfstraceFile;
  pInfo : PvfstraceInfo;
  rc    : cint;
begin
  p := PvfstraceFile(pFile);
  pInfo := p^.pInfo;
  vfstraceOnOff(pInfo, VTR_SECSZ);
  vfstrace_printf(pInfo, '%s.xSectorSize(%s)',
    [pInfo^.zVfsName, p^.zFName]);
  rc := p^.pReal^.pMethods^.xSectorSize(p^.pReal);
  vfstrace_printf(pInfo, ' -> %d'#10, [rc]);
  Result := rc;
end;

function vfstraceDeviceCharacteristics(pFile: Psqlite3_file): cint; cdecl;
var
  p     : PvfstraceFile;
  pInfo : PvfstraceInfo;
  rc    : cint;
begin
  p := PvfstraceFile(pFile);
  pInfo := p^.pInfo;
  vfstraceOnOff(pInfo, VTR_DEVCHAR);
  vfstrace_printf(pInfo, '%s.xDeviceCharacteristics(%s)',
    [pInfo^.zVfsName, p^.zFName]);
  rc := p^.pReal^.pMethods^.xDeviceCharacteristics(p^.pReal);
  vfstrace_printf(pInfo, ' -> 0x%08x'#10, [rc]);
  Result := rc;
end;

function vfstraceShmLock(pFile: Psqlite3_file; ofst, n,
                         flags: cint): cint; cdecl;
const
  azLockName : array[0..7] of PAnsiChar = (
    'WRITE', 'CKPT', 'RECOVER',
    'READ0', 'READ1', 'READ2', 'READ3', 'READ4'
  );
var
  p     : PvfstraceFile;
  pInfo : PvfstraceInfo;
  rc, i : cint;
  zLck  : array[0..127] of AnsiChar;
begin
  p := PvfstraceFile(pFile);
  pInfo := p^.pInfo;
  vfstraceOnOff(pInfo, VTR_SHMLOCK);
  zLck[0] := '|'; zLck[1] := '0'; zLck[2] := #0;
  i := 0;
  if (flags and SQLITE_SHM_UNLOCK) <> 0 then strappend(@zLck[0], @i, '|UNLOCK');
  if (flags and SQLITE_SHM_LOCK) <> 0 then strappend(@zLck[0], @i, '|LOCK');
  if (flags and SQLITE_SHM_SHARED) <> 0 then strappend(@zLck[0], @i, '|SHARED');
  if (flags and SQLITE_SHM_EXCLUSIVE) <> 0 then strappend(@zLck[0], @i,
    '|EXCLUSIVE');
  if (flags and (not $f)) <> 0 then
    sqlite3PfSnprintf(SizeOf(zLck) - i, @zLck[i],
      PAnsiChar('|0x%x'), [flags]);
  if (ofst >= 0) and (ofst < 8) then
    vfstrace_printf(pInfo, '%s.xShmLock(%s,ofst=%d(%s),n=%d,%s)',
      [pInfo^.zVfsName, p^.zFName, ofst, azLockName[ofst], n,
       PAnsiChar(@zLck[1])])
  else
    vfstrace_printf(pInfo, '%s.xShmLock(%s,ofst=%d,n=%d,%s)',
      [pInfo^.zVfsName, p^.zFName, ofst, n, PAnsiChar(@zLck[1])]);
  rc := p^.pReal^.pMethods^.xShmLock(p^.pReal, ofst, n, flags);
  vfstrace_print_errcode(pInfo, ' -> %s'#10, rc);
  Result := rc;
end;

function vfstraceShmMap(pFile: Psqlite3_file; iRegion, szRegion,
                        isWrite: cint; pp: PPointer): cint; cdecl;
var
  p     : PvfstraceFile;
  pInfo : PvfstraceInfo;
  rc    : cint;
begin
  p := PvfstraceFile(pFile);
  pInfo := p^.pInfo;
  vfstraceOnOff(pInfo, VTR_SHMMAP);
  vfstrace_printf(pInfo, '%s.xShmMap(%s,iRegion=%d,szRegion=%d,isWrite=%d,*)',
    [pInfo^.zVfsName, p^.zFName, iRegion, szRegion, isWrite]);
  rc := p^.pReal^.pMethods^.xShmMap(p^.pReal, iRegion, szRegion, isWrite, pp);
  vfstrace_print_errcode(pInfo, ' -> %s'#10, rc);
  Result := rc;
end;

procedure vfstraceShmBarrier(pFile: Psqlite3_file); cdecl;
var
  p     : PvfstraceFile;
  pInfo : PvfstraceInfo;
begin
  p := PvfstraceFile(pFile);
  pInfo := p^.pInfo;
  vfstraceOnOff(pInfo, VTR_SHMBAR);
  vfstrace_printf(pInfo, '%s.xShmBarrier(%s)'#10,
    [pInfo^.zVfsName, p^.zFName]);
  p^.pReal^.pMethods^.xShmBarrier(p^.pReal);
end;

function vfstraceShmUnmap(pFile: Psqlite3_file; delFlag: cint): cint; cdecl;
var
  p     : PvfstraceFile;
  pInfo : PvfstraceInfo;
  rc    : cint;
begin
  p := PvfstraceFile(pFile);
  pInfo := p^.pInfo;
  vfstraceOnOff(pInfo, VTR_SHMUNMAP);
  vfstrace_printf(pInfo, '%s.xShmUnmap(%s,delFlag=%d)',
    [pInfo^.zVfsName, p^.zFName, delFlag]);
  rc := p^.pReal^.pMethods^.xShmUnmap(p^.pReal, delFlag);
  vfstrace_print_errcode(pInfo, ' -> %s'#10, rc);
  Result := rc;
end;

function vfstraceFetch(pFile: Psqlite3_file; iOff: i64; nAmt: cint;
                       pptr: PPointer): cint; cdecl;
var
  p     : PvfstraceFile;
  pInfo : PvfstraceInfo;
  rc    : cint;
begin
  p := PvfstraceFile(pFile);
  pInfo := p^.pInfo;
  vfstraceOnOff(pInfo, VTR_FETCH);
  vfstrace_printf(pInfo, '%s.xFetch(%s,iOff=%lld,nAmt=%d,p=%p)',
    [pInfo^.zVfsName, p^.zFName, iOff, nAmt, pptr^]);
  rc := p^.pReal^.pMethods^.xFetch(p^.pReal, iOff, nAmt, pptr);
  vfstrace_print_errcode(pInfo, ' -> %s'#10, rc);
  Result := rc;
end;

function vfstraceUnfetch(pFile: Psqlite3_file; iOff: i64;
                         ptr: Pointer): cint; cdecl;
var
  p     : PvfstraceFile;
  pInfo : PvfstraceInfo;
  rc    : cint;
begin
  p := PvfstraceFile(pFile);
  pInfo := p^.pInfo;
  vfstraceOnOff(pInfo, VTR_FETCH);
  vfstrace_printf(pInfo, '%s.xUnfetch(%s,iOff=%lld,p=%p)',
    [pInfo^.zVfsName, p^.zFName, iOff, ptr]);
  rc := p^.pReal^.pMethods^.xUnfetch(p^.pReal, iOff, ptr);
  vfstrace_print_errcode(pInfo, ' -> %s'#10, rc);
  Result := rc;
end;

{ -------- vfstrace_vfs methods ---------------------------------------- }

function vfstraceOpen(pVfs: Psqlite3_vfs; zName: sqlite3_filename;
                      pFile: Psqlite3_file; flags: cint;
                      pOutFlags: PcInt): cint; cdecl;
var
  rc    : cint;
  p     : PvfstraceFile;
  pInfo : PvfstraceInfo;
  pRoot : Psqlite3_vfs;
  pNew  : Psqlite3_io_methods;
  pSub  : Psqlite3_io_methods;
begin
  p := PvfstraceFile(pFile);
  pInfo := PvfstraceInfo(pVfs^.pAppData);
  pRoot := pInfo^.pRootVfs;
  p^.pInfo := pInfo;
  if zName <> nil then
    p^.zFName := fileTail(zName)
  else
    p^.zFName := '<temp>';
  p^.pReal := Psqlite3_file(PtrUInt(p) + SizeOf(TvfstraceFile));
  rc := pRoot^.xOpen(pRoot, zName, p^.pReal, flags, pOutFlags);
  vfstraceOnOff(pInfo, VTR_OPEN);
  vfstrace_printf(pInfo, '%s.xOpen(%s,flags=0x%x)',
    [pInfo^.zVfsName, p^.zFName, flags]);
  if p^.pReal^.pMethods <> nil then begin
    pNew := Psqlite3_io_methods(sqlite3_malloc64(SizeOf(sqlite3_io_methods)));
    pSub := p^.pReal^.pMethods;
    FillChar(pNew^, SizeOf(sqlite3_io_methods), 0);
    pNew^.iVersion := pSub^.iVersion;
    pNew^.xClose := @vfstraceClose;
    pNew^.xRead := @vfstraceRead;
    pNew^.xWrite := @vfstraceWrite;
    pNew^.xTruncate := @vfstraceTruncate;
    pNew^.xSync := @vfstraceSync;
    pNew^.xFileSize := @vfstraceFileSize;
    pNew^.xLock := @vfstraceLock;
    pNew^.xUnlock := @vfstraceUnlock;
    pNew^.xCheckReservedLock := @vfstraceCheckReservedLock;
    pNew^.xFileControl := @vfstraceFileControl;
    pNew^.xSectorSize := @vfstraceSectorSize;
    pNew^.xDeviceCharacteristics := @vfstraceDeviceCharacteristics;
    if pNew^.iVersion >= 2 then begin
      if Assigned(pSub^.xShmMap) then pNew^.xShmMap := @vfstraceShmMap
      else pNew^.xShmMap := nil;
      if Assigned(pSub^.xShmLock) then pNew^.xShmLock := @vfstraceShmLock
      else pNew^.xShmLock := nil;
      if Assigned(pSub^.xShmBarrier) then pNew^.xShmBarrier := @vfstraceShmBarrier
      else pNew^.xShmBarrier := nil;
      if Assigned(pSub^.xShmUnmap) then pNew^.xShmUnmap := @vfstraceShmUnmap
      else pNew^.xShmUnmap := nil;
    end;
    if pNew^.iVersion >= 3 then begin
      if Assigned(pSub^.xFetch) then pNew^.xFetch := @vfstraceFetch
      else pNew^.xFetch := nil;
      if Assigned(pSub^.xUnfetch) then pNew^.xUnfetch := @vfstraceUnfetch
      else pNew^.xUnfetch := nil;
    end;
    pFile^.pMethods := pNew;
  end;
  vfstrace_print_errcode(pInfo, ' -> %s', rc);
  if pOutFlags <> nil then
    vfstrace_printf(pInfo, ', outFlags=0x%x'#10, [pOutFlags^])
  else
    vfstrace_printf(pInfo, #10, []);
  Result := rc;
end;

function vfstraceDelete(pVfs: Psqlite3_vfs; zPath: PChar;
                        syncDir: cint): cint; cdecl;
var
  pInfo : PvfstraceInfo;
  pRoot : Psqlite3_vfs;
  rc    : cint;
begin
  pInfo := PvfstraceInfo(pVfs^.pAppData);
  pRoot := pInfo^.pRootVfs;
  vfstraceOnOff(pInfo, VTR_DELETE);
  vfstrace_printf(pInfo, '%s.xDelete("%s",%d)',
    [pInfo^.zVfsName, zPath, syncDir]);
  rc := pRoot^.xDelete(pRoot, zPath, syncDir);
  vfstrace_print_errcode(pInfo, ' -> %s'#10, rc);
  Result := rc;
end;

function vfstraceAccess(pVfs: Psqlite3_vfs; zPath: PChar; flags: cint;
                        pResOut: PcInt): cint; cdecl;
var
  pInfo : PvfstraceInfo;
  pRoot : Psqlite3_vfs;
  rc    : cint;
begin
  pInfo := PvfstraceInfo(pVfs^.pAppData);
  pRoot := pInfo^.pRootVfs;
  vfstraceOnOff(pInfo, VTR_ACCESS);
  vfstrace_printf(pInfo, '%s.xAccess("%s",%d)',
    [pInfo^.zVfsName, zPath, flags]);
  rc := pRoot^.xAccess(pRoot, zPath, flags, pResOut);
  vfstrace_print_errcode(pInfo, ' -> %s', rc);
  vfstrace_printf(pInfo, ', out=%d'#10, [pResOut^]);
  Result := rc;
end;

function vfstraceFullPathname(pVfs: Psqlite3_vfs; zPath: PChar;
                              nOut: cint; zOut: PChar): cint; cdecl;
var
  pInfo : PvfstraceInfo;
  pRoot : Psqlite3_vfs;
  rc    : cint;
begin
  pInfo := PvfstraceInfo(pVfs^.pAppData);
  pRoot := pInfo^.pRootVfs;
  vfstraceOnOff(pInfo, VTR_FULLPATH);
  vfstrace_printf(pInfo, '%s.xFullPathname("%s")',
    [pInfo^.zVfsName, zPath]);
  rc := pRoot^.xFullPathname(pRoot, zPath, nOut, zOut);
  vfstrace_print_errcode(pInfo, ' -> %s', rc);
  vfstrace_printf(pInfo, ', out="%.*s"'#10, [nOut, zOut]);
  Result := rc;
end;

function vfstraceDlOpen(pVfs: Psqlite3_vfs; zPath: PChar): Pointer; cdecl;
var
  pInfo : PvfstraceInfo;
  pRoot : Psqlite3_vfs;
begin
  pInfo := PvfstraceInfo(pVfs^.pAppData);
  pRoot := pInfo^.pRootVfs;
  vfstraceOnOff(pInfo, VTR_DLOPEN);
  vfstrace_printf(pInfo, '%s.xDlOpen("%s")'#10,
    [pInfo^.zVfsName, zPath]);
  Result := pRoot^.xDlOpen(pRoot, zPath);
end;

procedure vfstraceDlError(pVfs: Psqlite3_vfs; nByte: cint;
                          zErrMsg: PChar); cdecl;
var
  pInfo : PvfstraceInfo;
  pRoot : Psqlite3_vfs;
begin
  pInfo := PvfstraceInfo(pVfs^.pAppData);
  pRoot := pInfo^.pRootVfs;
  vfstraceOnOff(pInfo, VTR_DLERR);
  vfstrace_printf(pInfo, '%s.xDlError(%d)',
    [pInfo^.zVfsName, nByte]);
  pRoot^.xDlError(pRoot, nByte, zErrMsg);
  vfstrace_printf(pInfo, ' -> "%s"', [zErrMsg]);
end;

function vfstraceDlSym(pVfs: Psqlite3_vfs; p: Pointer;
                       zSym: PChar): sqlite3_syscall_ptr; cdecl;
var
  pInfo : PvfstraceInfo;
  pRoot : Psqlite3_vfs;
begin
  pInfo := PvfstraceInfo(pVfs^.pAppData);
  pRoot := pInfo^.pRootVfs;
  vfstrace_printf(pInfo, '%s.xDlSym("%s")'#10,
    [pInfo^.zVfsName, zSym]);
  Result := pRoot^.xDlSym(pRoot, p, zSym);
end;

procedure vfstraceDlClose(pVfs: Psqlite3_vfs; pHandle: Pointer); cdecl;
var
  pInfo : PvfstraceInfo;
  pRoot : Psqlite3_vfs;
begin
  pInfo := PvfstraceInfo(pVfs^.pAppData);
  pRoot := pInfo^.pRootVfs;
  vfstraceOnOff(pInfo, VTR_DLCLOSE);
  vfstrace_printf(pInfo, '%s.xDlClose()'#10, [pInfo^.zVfsName]);
  pRoot^.xDlClose(pRoot, pHandle);
end;

function vfstraceRandomness(pVfs: Psqlite3_vfs; nByte: cint;
                            zBufOut: PChar): cint; cdecl;
var
  pInfo : PvfstraceInfo;
  pRoot : Psqlite3_vfs;
begin
  pInfo := PvfstraceInfo(pVfs^.pAppData);
  pRoot := pInfo^.pRootVfs;
  vfstraceOnOff(pInfo, VTR_RAND);
  vfstrace_printf(pInfo, '%s.xRandomness(%d)'#10,
    [pInfo^.zVfsName, nByte]);
  Result := pRoot^.xRandomness(pRoot, nByte, zBufOut);
end;

function vfstraceSleep(pVfs: Psqlite3_vfs; nMicro: cint): cint; cdecl;
var
  pInfo : PvfstraceInfo;
  pRoot : Psqlite3_vfs;
begin
  pInfo := PvfstraceInfo(pVfs^.pAppData);
  pRoot := pInfo^.pRootVfs;
  vfstraceOnOff(pInfo, VTR_SLEEP);
  vfstrace_printf(pInfo, '%s.xSleep(%d)'#10,
    [pInfo^.zVfsName, nMicro]);
  Result := pRoot^.xSleep(pRoot, nMicro);
end;

function vfstraceCurrentTime(pVfs: Psqlite3_vfs;
                             pTimeOut: PDouble): cint; cdecl;
var
  pInfo : PvfstraceInfo;
  pRoot : Psqlite3_vfs;
  rc    : cint;
begin
  pInfo := PvfstraceInfo(pVfs^.pAppData);
  pRoot := pInfo^.pRootVfs;
  vfstraceOnOff(pInfo, VTR_CURTIME);
  vfstrace_printf(pInfo, '%s.xCurrentTime()', [pInfo^.zVfsName]);
  rc := pRoot^.xCurrentTime(pRoot, pTimeOut);
  vfstrace_printf(pInfo, ' -> %.17g'#10, [pTimeOut^]);
  Result := rc;
end;

function vfstraceCurrentTimeInt64(pVfs: Psqlite3_vfs;
                                  pTimeOut: Pi64): cint; cdecl;
var
  pInfo : PvfstraceInfo;
  pRoot : Psqlite3_vfs;
  rc    : cint;
begin
  pInfo := PvfstraceInfo(pVfs^.pAppData);
  pRoot := pInfo^.pRootVfs;
  vfstraceOnOff(pInfo, VTR_CURTIME);
  vfstrace_printf(pInfo, '%s.xCurrentTimeInt64()', [pInfo^.zVfsName]);
  rc := pRoot^.xCurrentTimeInt64(pRoot, pTimeOut);
  vfstrace_printf(pInfo, ' -> %lld'#10, [pTimeOut^]);
  Result := rc;
end;

function vfstraceGetLastError(pVfs: Psqlite3_vfs; nErr: cint;
                              zErr: PChar): cint; cdecl;
var
  pInfo : PvfstraceInfo;
  pRoot : Psqlite3_vfs;
  rc    : cint;
  zEmpty : PAnsiChar;
begin
  pInfo := PvfstraceInfo(pVfs^.pAppData);
  pRoot := pInfo^.pRootVfs;
  vfstraceOnOff(pInfo, VTR_LASTERR);
  vfstrace_printf(pInfo, '%s.xGetLastError(%d,zBuf)',
    [pInfo^.zVfsName, nErr]);
  if nErr <> 0 then zErr[0] := #0;
  rc := pRoot^.xGetLastError(pRoot, nErr, zErr);
  if nErr <> 0 then zEmpty := zErr else zEmpty := '';
  vfstrace_printf(pInfo, ' -> zBuf[] = "%s", rc = %d'#10,
    [zEmpty, rc]);
  Result := rc;
end;

function vfstraceSetSystemCall(pVfs: Psqlite3_vfs; zName: PChar;
                               pNewFunc: sqlite3_syscall_ptr): cint; cdecl;
var
  pInfo : PvfstraceInfo;
  pRoot : Psqlite3_vfs;
begin
  pInfo := PvfstraceInfo(pVfs^.pAppData);
  pRoot := pInfo^.pRootVfs;
  Result := pRoot^.xSetSystemCall(pRoot, zName, pNewFunc);
end;

function vfstraceGetSystemCall(pVfs: Psqlite3_vfs;
                               zName: PChar): sqlite3_syscall_ptr; cdecl;
var
  pInfo : PvfstraceInfo;
  pRoot : Psqlite3_vfs;
begin
  pInfo := PvfstraceInfo(pVfs^.pAppData);
  pRoot := pInfo^.pRootVfs;
  Result := pRoot^.xGetSystemCall(pRoot, zName);
end;

function vfstraceNextSystemCall(pVfs: Psqlite3_vfs;
                                zName: PChar): PChar; cdecl;
var
  pInfo : PvfstraceInfo;
  pRoot : Psqlite3_vfs;
begin
  pInfo := PvfstraceInfo(pVfs^.pAppData);
  pRoot := pInfo^.pRootVfs;
  Result := pRoot^.xNextSystemCall(pRoot, zName);
end;

{ -------- public API -------------------------------------------------- }

function vfstrace_register(zTraceName, zOldVfsName: PAnsiChar;
                           xOut: TvfstraceOutFn; pOutArg: Pointer;
                           makeDefault: cint): i32;
var
  pNew  : Psqlite3_vfs;
  pRoot : Psqlite3_vfs;
  pInfo : PvfstraceInfo;
  nName : SizeUInt;
  nByte : SizeUInt;
  zNameDst : PAnsiChar;
begin
  pRoot := sqlite3_vfs_find(zOldVfsName);
  if pRoot = nil then begin Result := SQLITE_NOTFOUND; Exit; end;
  nName := StrLen(zTraceName);
  nByte := SizeOf(sqlite3_vfs) + SizeOf(TvfstraceInfo) + nName + 1;
  pNew := Psqlite3_vfs(sqlite3_malloc64(nByte));
  if pNew = nil then begin Result := SQLITE_NOMEM; Exit; end;
  FillChar(pNew^, nByte, 0);
  pInfo := PvfstraceInfo(PtrUInt(pNew) + SizeOf(sqlite3_vfs));
  pNew^.iVersion := pRoot^.iVersion;
  pNew^.szOsFile := pRoot^.szOsFile + cint(SizeOf(TvfstraceFile));
  pNew^.mxPathname := pRoot^.mxPathname;
  zNameDst := PAnsiChar(PtrUInt(pInfo) + SizeOf(TvfstraceInfo));
  Move(zTraceName^, zNameDst^, nName + 1);
  pNew^.zName := zNameDst;
  pNew^.pAppData := pInfo;
  pNew^.xOpen := @vfstraceOpen;
  pNew^.xDelete := @vfstraceDelete;
  pNew^.xAccess := @vfstraceAccess;
  pNew^.xFullPathname := @vfstraceFullPathname;
  if Assigned(pRoot^.xDlOpen)  then pNew^.xDlOpen  := @vfstraceDlOpen
  else pNew^.xDlOpen := nil;
  if Assigned(pRoot^.xDlError) then pNew^.xDlError := @vfstraceDlError
  else pNew^.xDlError := nil;
  if Assigned(pRoot^.xDlSym)   then pNew^.xDlSym   := @vfstraceDlSym
  else pNew^.xDlSym := nil;
  if Assigned(pRoot^.xDlClose) then pNew^.xDlClose := @vfstraceDlClose
  else pNew^.xDlClose := nil;
  pNew^.xRandomness := @vfstraceRandomness;
  pNew^.xSleep := @vfstraceSleep;
  pNew^.xCurrentTime := @vfstraceCurrentTime;
  if Assigned(pRoot^.xGetLastError) then
    pNew^.xGetLastError := @vfstraceGetLastError
  else
    pNew^.xGetLastError := nil;
  if pNew^.iVersion >= 2 then begin
    if Assigned(pRoot^.xCurrentTimeInt64) then
      pNew^.xCurrentTimeInt64 := @vfstraceCurrentTimeInt64
    else
      pNew^.xCurrentTimeInt64 := nil;
    if pNew^.iVersion >= 3 then begin
      if Assigned(pRoot^.xSetSystemCall) then
        pNew^.xSetSystemCall := @vfstraceSetSystemCall
      else
        pNew^.xSetSystemCall := nil;
      if Assigned(pRoot^.xGetSystemCall) then
        pNew^.xGetSystemCall := @vfstraceGetSystemCall
      else
        pNew^.xGetSystemCall := nil;
      if Assigned(pRoot^.xNextSystemCall) then
        pNew^.xNextSystemCall := @vfstraceNextSystemCall
      else
        pNew^.xNextSystemCall := nil;
    end;
  end;
  pInfo^.pRootVfs := pRoot;
  pInfo^.xOut := xOut;
  pInfo^.pOutArg := pOutArg;
  pInfo^.zVfsName := pNew^.zName;
  pInfo^.pTraceVfs := pNew;
  pInfo^.mTrace := $ffffffff;
  pInfo^.bOn := 1;
  vfstrace_printf(pInfo, '%s.enabled_for("%s")'#10,
    [pInfo^.zVfsName, pRoot^.zName]);
  Result := sqlite3_vfs_register(pNew, makeDefault);
end;

procedure vfstrace_unregister(zTraceName: PAnsiChar);
var
  pVfs : Psqlite3_vfs;
begin
  pVfs := sqlite3_vfs_find(zTraceName);
  if pVfs = nil then Exit;
  if Pointer(pVfs^.xOpen) <> Pointer(@vfstraceOpen) then Exit;
  sqlite3_vfs_unregister(pVfs);
  sqlite3_free(pVfs);
end;

end.
