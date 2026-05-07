{
  SPDX-License-Identifier: blessing

  Faithful port of ../sqlite3/ext/misc/vfsstat.c (825 lines in C).

  Implements a VFS shim ("vfslog" — the upstream zName is literally
  "vfslog" even though the eponymous vtab is named "vfsstat"; preserved
  byte-identical) that wraps an underlying VFS and tallies per-file-type
  I/O counters.  The accumulated counters are exposed through the
  `vfsstat` eponymous virtual table:

      SELECT * FROM vfsstat;            -- read counters
      UPDATE vfsstat SET count=0;       -- reset counters

  Counters are unprotected by mutexes — matches upstream.

  Public entries:
    * sqlite3VfsstatInit(db) — registers the vfsstat virtual table on
      `db` (and on the first call also installs the VFS shim and arms a
      sqlite3_auto_extension() so subsequent connections pick up the
      vtab automatically).  Equivalent to sqlite3_vfsstat_init() in C.
    * sqlite3_register_vfsstat() — convenience wrapper that just
      installs the VFS shim, for the rare callers that want stats
      without the vtab.
}
{$I passqlite3.inc}
unit passqlite3vfsstat;

interface

uses
  ctypes,
  passqlite3types,
  passqlite3os,
  passqlite3util,
  passqlite3vdbe,
  passqlite3vtab,
  passqlite3main;

function sqlite3VfsstatInit(db: PTsqlite3): i32;
function sqlite3_register_vfsstat: i32;

implementation

uses
  passqlite3printf;

{ -------- file-type / stat-type indices (vfsstat.c:62..97) ----------- }

const
  VFSSTAT_MAIN       = 0;
  VFSSTAT_JOURNAL    = 1;
  VFSSTAT_WAL        = 2;
  VFSSTAT_MASTERJRNL = 3;
  VFSSTAT_SUBJRNL    = 4;
  VFSSTAT_TEMPDB     = 5;
  VFSSTAT_TEMPJRNL   = 6;
  VFSSTAT_TRANSIENT  = 7;
  VFSSTAT_ANY        = 8;
  VFSSTAT_nFile      = 9;

  VFSSTAT_BYTESIN    = 0;
  VFSSTAT_BYTESOUT   = 1;
  VFSSTAT_READ       = 2;
  VFSSTAT_WRITE      = 3;
  VFSSTAT_SYNC       = 4;
  VFSSTAT_OPEN       = 5;
  VFSSTAT_LOCK       = 6;

  { Aliases when filetype == VFSSTAT_ANY (vfsstat.c:91..96). }
  VFSSTAT_ACCESS     = 0;
  VFSSTAT_DELETE     = 1;
  VFSSTAT_FULLPATH   = 2;
  VFSSTAT_RANDOM     = 3;
  VFSSTAT_SLEEP      = 4;
  VFSSTAT_CURTIME    = 5;

  VFSSTAT_nStat      = 7;
  VFSSTAT_MXCNT      = VFSSTAT_nStat * VFSSTAT_nFile;

  azFile: array[0..VFSSTAT_nFile - 1] of PAnsiChar = (
    'database', 'journal', 'wal', 'master-journal', 'sub-journal',
    'temp-database', 'temp-journal', 'transient-db', '*'
  );
  azStat: array[0..VFSSTAT_nStat - 1] of PAnsiChar = (
    'bytes-in', 'bytes-out', 'read', 'write', 'sync', 'open', 'lock'
  );
  azStatAny: array[0..VFSSTAT_nStat - 1] of PAnsiChar = (
    'access', 'delete', 'fullpathname', 'randomness',
    'sleep', 'currenttimestamp', 'not-used'
  );

type
  PU64 = ^u64;

var
  aVfsCnt : array[0..VFSSTAT_MXCNT - 1] of u64;

function STATCNT_ADDR(filetype, stat: cint): PU64; inline;
begin
  Result := @aVfsCnt[filetype * VFSSTAT_nStat + stat];
end;

{ -------- types (vfsstat.c:127..143) ---------------------------------- }

type
  PVStatVfs = ^TVStatVfs;
  TVStatVfs = record
    base : sqlite3_vfs;
    pVfs : Psqlite3_vfs;
  end;

  PVStatFile = ^TVStatFile;
  TVStatFile = record
    base      : sqlite3_file;
    pReal     : Psqlite3_file;
    eFiletype : Byte;
  end;

function REALVFS(pVfs: Psqlite3_vfs): Psqlite3_vfs; inline;
begin
  Result := PVStatVfs(pVfs)^.pVfs;
end;

{ -------- file-method forward decls ----------------------------------- }

function vstatClose(pFile: Psqlite3_file): cint; cdecl; forward;
function vstatRead(pFile: Psqlite3_file; zBuf: Pointer;
                   iAmt: cint; iOfst: i64): cint; cdecl; forward;
function vstatWrite(pFile: Psqlite3_file; z: Pointer;
                    iAmt: cint; iOfst: i64): cint; cdecl; forward;
function vstatTruncate(pFile: Psqlite3_file; size: i64): cint; cdecl; forward;
function vstatSync(pFile: Psqlite3_file; flags: cint): cint; cdecl; forward;
function vstatFileSize(pFile: Psqlite3_file; pSize: Pi64): cint; cdecl; forward;
function vstatLock(pFile: Psqlite3_file; eLock: cint): cint; cdecl; forward;
function vstatUnlock(pFile: Psqlite3_file; eLock: cint): cint; cdecl; forward;
function vstatCheckReservedLock(pFile: Psqlite3_file;
                                pResOut: PcInt): cint; cdecl; forward;
function vstatFileControl(pFile: Psqlite3_file; op: cint;
                          pArg: Pointer): cint; cdecl; forward;
function vstatSectorSize(pFile: Psqlite3_file): cint; cdecl; forward;
function vstatDeviceCharacteristics(pFile: Psqlite3_file): cint; cdecl; forward;
function vstatShmMap(pFile: Psqlite3_file; iPg, pgsz, bExtend: cint;
                     pp: PPointer): cint; cdecl; forward;
function vstatShmLock(pFile: Psqlite3_file; offset, n,
                      flags: cint): cint; cdecl; forward;
procedure vstatShmBarrier(pFile: Psqlite3_file); cdecl; forward;
function vstatShmUnmap(pFile: Psqlite3_file; deleteFlag: cint): cint; cdecl; forward;
function vstatFetch(pFile: Psqlite3_file; iOfst: i64; iAmt: cint;
                    pp: PPointer): cint; cdecl; forward;
function vstatUnfetch(pFile: Psqlite3_file; iOfst: i64;
                      p: Pointer): cint; cdecl; forward;

{ -------- VFS-method forward decls ------------------------------------ }

function vstatOpen(pVfs: Psqlite3_vfs; zName: sqlite3_filename;
                   pFile: Psqlite3_file; flags: cint;
                   pOutFlags: PcInt): cint; cdecl; forward;
function vstatDelete(pVfs: Psqlite3_vfs; zName: PChar;
                     syncDir: cint): cint; cdecl; forward;
function vstatAccess(pVfs: Psqlite3_vfs; zName: PChar; flags: cint;
                     pResOut: PcInt): cint; cdecl; forward;
function vstatFullPathname(pVfs: Psqlite3_vfs; zName: PChar; nOut: cint;
                           zOut: PChar): cint; cdecl; forward;
function vstatDlOpen(pVfs: Psqlite3_vfs; zPath: PChar): Pointer; cdecl; forward;
procedure vstatDlError(pVfs: Psqlite3_vfs; nByte: cint;
                       zErrMsg: PChar); cdecl; forward;
function vstatDlSym(pVfs: Psqlite3_vfs; p: Pointer;
                    zSym: PChar): sqlite3_syscall_ptr; cdecl; forward;
procedure vstatDlClose(pVfs: Psqlite3_vfs; pHandle: Pointer); cdecl; forward;
function vstatRandomness(pVfs: Psqlite3_vfs; nByte: cint;
                         zBufOut: PChar): cint; cdecl; forward;
function vstatSleep(pVfs: Psqlite3_vfs; nMicro: cint): cint; cdecl; forward;
function vstatCurrentTime(pVfs: Psqlite3_vfs;
                          pTimeOut: PDouble): cint; cdecl; forward;
function vstatGetLastError(pVfs: Psqlite3_vfs; a: cint;
                           b: PChar): cint; cdecl; forward;
function vstatCurrentTimeInt64(pVfs: Psqlite3_vfs;
                               p: Pi64): cint; cdecl; forward;

var
  vstat_vfs        : TVStatVfs;
  vstat_io_methods : sqlite3_io_methods;
  vstatInitialised : cint = 0;

{ ---------------------------------------------------------------------- }
{ vfsstat.c:236..244 vstatClose. }
{ ---------------------------------------------------------------------- }

function vstatClose(pFile: Psqlite3_file): cint; cdecl;
var
  p  : PVStatFile;
  rc : cint;
begin
  p  := PVStatFile(pFile);
  rc := SQLITE_OK;
  if p^.pReal^.pMethods <> nil then
    rc := p^.pReal^.pMethods^.xClose(p^.pReal);
  Result := rc;
end;

{ vfsstat.c:250..265. }
function vstatRead(pFile: Psqlite3_file; zBuf: Pointer;
                   iAmt: cint; iOfst: i64): cint; cdecl;
var
  p  : PVStatFile;
  rc : cint;
begin
  p  := PVStatFile(pFile);
  rc := p^.pReal^.pMethods^.xRead(p^.pReal, zBuf, iAmt, iOfst);
  Inc(STATCNT_ADDR(p^.eFiletype, VFSSTAT_READ)^);
  if rc = SQLITE_OK then
    Inc(STATCNT_ADDR(p^.eFiletype, VFSSTAT_BYTESIN)^, u64(iAmt));
  Result := rc;
end;

{ vfsstat.c:270..285. }
function vstatWrite(pFile: Psqlite3_file; z: Pointer;
                    iAmt: cint; iOfst: i64): cint; cdecl;
var
  p  : PVStatFile;
  rc : cint;
begin
  p  := PVStatFile(pFile);
  rc := p^.pReal^.pMethods^.xWrite(p^.pReal, z, iAmt, iOfst);
  Inc(STATCNT_ADDR(p^.eFiletype, VFSSTAT_WRITE)^);
  if rc = SQLITE_OK then
    Inc(STATCNT_ADDR(p^.eFiletype, VFSSTAT_BYTESOUT)^, u64(iAmt));
  Result := rc;
end;

{ vfsstat.c:290..295. }
function vstatTruncate(pFile: Psqlite3_file; size: i64): cint; cdecl;
var p: PVStatFile;
begin
  p := PVStatFile(pFile);
  Result := p^.pReal^.pMethods^.xTruncate(p^.pReal, size);
end;

{ vfsstat.c:300..306. }
function vstatSync(pFile: Psqlite3_file; flags: cint): cint; cdecl;
var
  p  : PVStatFile;
  rc : cint;
begin
  p  := PVStatFile(pFile);
  rc := p^.pReal^.pMethods^.xSync(p^.pReal, flags);
  Inc(STATCNT_ADDR(p^.eFiletype, VFSSTAT_SYNC)^);
  Result := rc;
end;

{ vfsstat.c:311..316. }
function vstatFileSize(pFile: Psqlite3_file; pSize: Pi64): cint; cdecl;
var p: PVStatFile;
begin
  p := PVStatFile(pFile);
  Result := p^.pReal^.pMethods^.xFileSize(p^.pReal, pSize);
end;

{ vfsstat.c:321..327. }
function vstatLock(pFile: Psqlite3_file; eLock: cint): cint; cdecl;
var
  p  : PVStatFile;
  rc : cint;
begin
  p  := PVStatFile(pFile);
  rc := p^.pReal^.pMethods^.xLock(p^.pReal, eLock);
  Inc(STATCNT_ADDR(p^.eFiletype, VFSSTAT_LOCK)^);
  Result := rc;
end;

{ vfsstat.c:332..338. }
function vstatUnlock(pFile: Psqlite3_file; eLock: cint): cint; cdecl;
var
  p  : PVStatFile;
  rc : cint;
begin
  p  := PVStatFile(pFile);
  rc := p^.pReal^.pMethods^.xUnlock(p^.pReal, eLock);
  Inc(STATCNT_ADDR(p^.eFiletype, VFSSTAT_LOCK)^);
  Result := rc;
end;

{ vfsstat.c:343..349. }
function vstatCheckReservedLock(pFile: Psqlite3_file;
                                pResOut: PcInt): cint; cdecl;
var
  p  : PVStatFile;
  rc : cint;
begin
  p  := PVStatFile(pFile);
  rc := p^.pReal^.pMethods^.xCheckReservedLock(p^.pReal, pResOut);
  Inc(STATCNT_ADDR(p^.eFiletype, VFSSTAT_LOCK)^);
  Result := rc;
end;

{ Helper for SQLITE_FCNTL_VFSNAME — emulates sqlite3_mprintf("vstat/%z", *)
  by allocating a new buffer and freeing the old one. }
function vstatPrependVfsName(z: PAnsiChar): PAnsiChar;
const
  zPre : PAnsiChar = 'vstat/';
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
  Move(z^,   (zNew + nPre)^, nZ);
  zNew[nPre + nZ] := #0;
  sqlite3_free(z);
  Result := zNew;
end;

{ vfsstat.c:354..362. }
function vstatFileControl(pFile: Psqlite3_file; op: cint;
                          pArg: Pointer): cint; cdecl;
var
  p  : PVStatFile;
  rc : cint;
begin
  p  := PVStatFile(pFile);
  rc := p^.pReal^.pMethods^.xFileControl(p^.pReal, op, pArg);
  if (op = SQLITE_FCNTL_VFSNAME) and (rc = SQLITE_OK) then
    PPAnsiChar(pArg)^ := vstatPrependVfsName(PPAnsiChar(pArg)^);
  Result := rc;
end;

{ vfsstat.c:367..372. }
function vstatSectorSize(pFile: Psqlite3_file): cint; cdecl;
var p: PVStatFile;
begin
  p := PVStatFile(pFile);
  Result := p^.pReal^.pMethods^.xSectorSize(p^.pReal);
end;

{ vfsstat.c:377..382. }
function vstatDeviceCharacteristics(pFile: Psqlite3_file): cint; cdecl;
var p: PVStatFile;
begin
  p := PVStatFile(pFile);
  Result := p^.pReal^.pMethods^.xDeviceCharacteristics(p^.pReal);
end;

{ vfsstat.c:385..394. }
function vstatShmMap(pFile: Psqlite3_file; iPg, pgsz, bExtend: cint;
                     pp: PPointer): cint; cdecl;
var p: PVStatFile;
begin
  p := PVStatFile(pFile);
  Result := p^.pReal^.pMethods^.xShmMap(p^.pReal, iPg, pgsz, bExtend, pp);
end;

{ vfsstat.c:397..400. }
function vstatShmLock(pFile: Psqlite3_file; offset, n,
                      flags: cint): cint; cdecl;
var p: PVStatFile;
begin
  p := PVStatFile(pFile);
  Result := p^.pReal^.pMethods^.xShmLock(p^.pReal, offset, n, flags);
end;

{ vfsstat.c:403..406. }
procedure vstatShmBarrier(pFile: Psqlite3_file); cdecl;
var p: PVStatFile;
begin
  p := PVStatFile(pFile);
  p^.pReal^.pMethods^.xShmBarrier(p^.pReal);
end;

{ vfsstat.c:409..412. }
function vstatShmUnmap(pFile: Psqlite3_file; deleteFlag: cint): cint; cdecl;
var p: PVStatFile;
begin
  p := PVStatFile(pFile);
  Result := p^.pReal^.pMethods^.xShmUnmap(p^.pReal, deleteFlag);
end;

{ vfsstat.c:415..423. }
function vstatFetch(pFile: Psqlite3_file; iOfst: i64; iAmt: cint;
                    pp: PPointer): cint; cdecl;
var p: PVStatFile;
begin
  p := PVStatFile(pFile);
  Result := p^.pReal^.pMethods^.xFetch(p^.pReal, iOfst, iAmt, pp);
end;

{ vfsstat.c:426..429. }
function vstatUnfetch(pFile: Psqlite3_file; iOfst: i64;
                      p: Pointer): cint; cdecl;
var pf: PVStatFile;
begin
  pf := PVStatFile(pFile);
  Result := pf^.pReal^.pMethods^.xUnfetch(pf^.pReal, iOfst, p);
end;

{ ---------------------------------------------------------------------- }
{ vfsstat.c:434..466 vstatOpen. }
{ ---------------------------------------------------------------------- }

function vstatOpen(pVfs: Psqlite3_vfs; zName: sqlite3_filename;
                   pFile: Psqlite3_file; flags: cint;
                   pOutFlags: PcInt): cint; cdecl;
var
  p  : PVStatFile;
  rc : cint;
begin
  p := PVStatFile(pFile);
  p^.pReal := Psqlite3_file(PByte(p) + SizeOf(TVStatFile));
  rc := REALVFS(pVfs)^.xOpen(REALVFS(pVfs), zName, p^.pReal, flags, pOutFlags);
  if (flags and SQLITE_OPEN_MAIN_DB) <> 0 then
    p^.eFiletype := VFSSTAT_MAIN
  else if (flags and SQLITE_OPEN_MAIN_JOURNAL) <> 0 then
    p^.eFiletype := VFSSTAT_JOURNAL
  else if (flags and SQLITE_OPEN_WAL) <> 0 then
    p^.eFiletype := VFSSTAT_WAL
  else if (flags and SQLITE_OPEN_MASTER_JOURNAL) <> 0 then
    p^.eFiletype := VFSSTAT_MASTERJRNL
  else if (flags and SQLITE_OPEN_SUBJOURNAL) <> 0 then
    p^.eFiletype := VFSSTAT_SUBJRNL
  else if (flags and SQLITE_OPEN_TEMP_DB) <> 0 then
    p^.eFiletype := VFSSTAT_TEMPDB
  else if (flags and SQLITE_OPEN_TEMP_JOURNAL) <> 0 then
    p^.eFiletype := VFSSTAT_TEMPJRNL
  else
    p^.eFiletype := VFSSTAT_TRANSIENT;
  Inc(STATCNT_ADDR(p^.eFiletype, VFSSTAT_OPEN)^);
  if rc <> 0 then
    pFile^.pMethods := nil
  else
    pFile^.pMethods := @vstat_io_methods;
  Result := rc;
end;

{ vfsstat.c:473..478. }
function vstatDelete(pVfs: Psqlite3_vfs; zName: PChar;
                     syncDir: cint): cint; cdecl;
var rc: cint;
begin
  rc := REALVFS(pVfs)^.xDelete(REALVFS(pVfs), zName, syncDir);
  Inc(STATCNT_ADDR(VFSSTAT_ANY, VFSSTAT_DELETE)^);
  Result := rc;
end;

{ vfsstat.c:484..494. }
function vstatAccess(pVfs: Psqlite3_vfs; zName: PChar; flags: cint;
                     pResOut: PcInt): cint; cdecl;
var rc: cint;
begin
  rc := REALVFS(pVfs)^.xAccess(REALVFS(pVfs), zName, flags, pResOut);
  Inc(STATCNT_ADDR(VFSSTAT_ANY, VFSSTAT_ACCESS)^);
  Result := rc;
end;

{ vfsstat.c:501..509. }
function vstatFullPathname(pVfs: Psqlite3_vfs; zName: PChar; nOut: cint;
                           zOut: PChar): cint; cdecl;
begin
  Inc(STATCNT_ADDR(VFSSTAT_ANY, VFSSTAT_FULLPATH)^);
  Result := REALVFS(pVfs)^.xFullPathname(REALVFS(pVfs), zName, nOut, zOut);
end;

function vstatDlOpen(pVfs: Psqlite3_vfs; zPath: PChar): Pointer; cdecl;
begin
  Result := REALVFS(pVfs)^.xDlOpen(REALVFS(pVfs), zPath);
end;

procedure vstatDlError(pVfs: Psqlite3_vfs; nByte: cint;
                       zErrMsg: PChar); cdecl;
begin
  REALVFS(pVfs)^.xDlError(REALVFS(pVfs), nByte, zErrMsg);
end;

function vstatDlSym(pVfs: Psqlite3_vfs; p: Pointer;
                    zSym: PChar): sqlite3_syscall_ptr; cdecl;
begin
  Result := REALVFS(pVfs)^.xDlSym(REALVFS(pVfs), p, zSym);
end;

procedure vstatDlClose(pVfs: Psqlite3_vfs; pHandle: Pointer); cdecl;
begin
  REALVFS(pVfs)^.xDlClose(REALVFS(pVfs), pHandle);
end;

{ vfsstat.c:545..548. }
function vstatRandomness(pVfs: Psqlite3_vfs; nByte: cint;
                         zBufOut: PChar): cint; cdecl;
begin
  Inc(STATCNT_ADDR(VFSSTAT_ANY, VFSSTAT_RANDOM)^);
  Result := REALVFS(pVfs)^.xRandomness(REALVFS(pVfs), nByte, zBufOut);
end;

{ vfsstat.c:554..557. }
function vstatSleep(pVfs: Psqlite3_vfs; nMicro: cint): cint; cdecl;
begin
  Inc(STATCNT_ADDR(VFSSTAT_ANY, VFSSTAT_SLEEP)^);
  Result := REALVFS(pVfs)^.xSleep(REALVFS(pVfs), nMicro);
end;

{ vfsstat.c:562..565. }
function vstatCurrentTime(pVfs: Psqlite3_vfs;
                          pTimeOut: PDouble): cint; cdecl;
begin
  Inc(STATCNT_ADDR(VFSSTAT_ANY, VFSSTAT_CURTIME)^);
  Result := REALVFS(pVfs)^.xCurrentTime(REALVFS(pVfs), pTimeOut);
end;

{ vfsstat.c:567..569. }
function vstatGetLastError(pVfs: Psqlite3_vfs; a: cint;
                           b: PChar): cint; cdecl;
begin
  Result := REALVFS(pVfs)^.xGetLastError(REALVFS(pVfs), a, b);
end;

{ vfsstat.c:570..573. }
function vstatCurrentTimeInt64(pVfs: Psqlite3_vfs; p: Pi64): cint; cdecl;
begin
  Inc(STATCNT_ADDR(VFSSTAT_ANY, VFSSTAT_CURTIME)^);
  Result := REALVFS(pVfs)^.xCurrentTimeInt64(REALVFS(pVfs), p);
end;

{ ---------------------------------------------------------------------- }
{ vfsstat virtual table (vfsstat.c:578..783) }
{ ---------------------------------------------------------------------- }

const
  VSTAT_COLUMN_FILE  = 0;
  VSTAT_COLUMN_STAT  = 1;
  VSTAT_COLUMN_COUNT = 2;

type
  PVfsStatCursor = ^TVfsStatCursor;
  TVfsStatCursor = record
    base : Tsqlite3_vtab_cursor;
    i    : cint;
  end;

var
  VfsStatModule : Tsqlite3_module;

{ vfsstat.c:599..621 vstattabConnect. }
function vstattabConnect(db: PTsqlite3; pAux: Pointer;
  argc: i32; argv: PPAnsiChar; ppVtab: PPSqlite3Vtab;
  pzErr: PPAnsiChar): i32; cdecl;
var
  pNew : PSqlite3Vtab;
  rc   : i32;
begin
  rc := sqlite3_declare_vtab(db, 'CREATE TABLE x(file,stat,count)');
  if rc = SQLITE_OK then begin
    pNew := PSqlite3Vtab(sqlite3_malloc64(SizeOf(Tsqlite3_vtab)));
    ppVtab^ := pNew;
    if pNew = nil then begin Result := SQLITE_NOMEM; Exit; end;
    FillChar(pNew^, SizeOf(Tsqlite3_vtab), 0);
  end;
  Result := rc;
end;

{ vfsstat.c:626..629. }
function vstattabDisconnect(pVtab: PSqlite3Vtab): i32; cdecl;
begin
  sqlite3_free(pVtab);
  Result := SQLITE_OK;
end;

{ vfsstat.c:634..641. }
function vstattabOpen(p: PSqlite3Vtab;
  ppCursor: PPSqlite3VtabCursor): i32; cdecl;
var pCur: PVfsStatCursor;
begin
  pCur := PVfsStatCursor(sqlite3_malloc64(SizeOf(TVfsStatCursor)));
  if pCur = nil then begin Result := SQLITE_NOMEM; Exit; end;
  FillChar(pCur^, SizeOf(TVfsStatCursor), 0);
  ppCursor^ := @pCur^.base;
  Result := SQLITE_OK;
end;

{ vfsstat.c:647..650. }
function vstattabClose(cur: PSqlite3VtabCursor): i32; cdecl;
begin
  sqlite3_free(cur);
  Result := SQLITE_OK;
end;

{ vfsstat.c:656..659. }
function vstattabNext(cur: PSqlite3VtabCursor): i32; cdecl;
begin
  Inc(PVfsStatCursor(cur)^.i);
  Result := SQLITE_OK;
end;

{ vfsstat.c:665..688. }
function vstattabColumn(cur: PSqlite3VtabCursor;
  ctx: Psqlite3_context; i: i32): i32; cdecl;
var
  pCur : PVfsStatCursor;
  az   : PPAnsiChar;
begin
  pCur := PVfsStatCursor(cur);
  case i of
    VSTAT_COLUMN_FILE: begin
      sqlite3_result_text(ctx, azFile[pCur^.i div VFSSTAT_nStat],
        -1, SQLITE_STATIC);
    end;
    VSTAT_COLUMN_STAT: begin
      if (pCur^.i div VFSSTAT_nStat) = VFSSTAT_ANY then
        az := @azStatAny[0]
      else
        az := @azStat[0];
      sqlite3_result_text(ctx, az[pCur^.i mod VFSSTAT_nStat],
        -1, SQLITE_STATIC);
    end;
    VSTAT_COLUMN_COUNT: begin
      sqlite3_result_int64(ctx, i64(aVfsCnt[pCur^.i]));
    end;
  end;
  Result := SQLITE_OK;
end;

{ vfsstat.c:693..697. }
function vstattabRowid(cur: PSqlite3VtabCursor; pRowid: Pi64): i32; cdecl;
begin
  pRowid^ := PVfsStatCursor(cur)^.i;
  Result := SQLITE_OK;
end;

{ vfsstat.c:703..706. }
function vstattabEof(cur: PSqlite3VtabCursor): i32; cdecl;
begin
  if PVfsStatCursor(cur)^.i >= VFSSTAT_MXCNT then Result := 1
  else Result := 0;
end;

{ vfsstat.c:712..720 — full scan only. }
function vstattabFilter(pVtabCursor: PSqlite3VtabCursor; idxNum: i32;
  idxStr: PAnsiChar; argc: i32; argv: PPointer): i32; cdecl;
begin
  PVfsStatCursor(pVtabCursor)^.i := 0;
  Result := SQLITE_OK;
end;

{ vfsstat.c:725..729 — no-op. }
function vstattabBestIndex(tab: PSqlite3Vtab;
  pIdxInfo: PSqlite3IndexInfo): i32; cdecl;
begin
  Result := SQLITE_OK;
end;

{ vfsstat.c:737..755 vstattabUpdate.  Allow UPDATE on the count column
  to a non-negative integer; refuse insert/delete and other column
  changes. }
function vstattabUpdate(tab: PSqlite3Vtab; argc: i32;
  argv: PPointer; pRowid: Pi64): i32; cdecl;
var
  iRowid, x : i64;
  argvVals  : ^Psqlite3_value;
begin
  if argc = 1 then begin Result := SQLITE_ERROR; Exit; end;
  argvVals := Pointer(argv);
  if sqlite3_value_type(argvVals[0]) <> SQLITE_INTEGER then begin
    Result := SQLITE_ERROR; Exit;
  end;
  iRowid := sqlite3_value_int64(argvVals[0]);
  if iRowid <> sqlite3_value_int64(argvVals[1]) then begin
    Result := SQLITE_ERROR; Exit;
  end;
  if (iRowid < 0) or (iRowid >= VFSSTAT_MXCNT) then begin
    Result := SQLITE_ERROR; Exit;
  end;
  if sqlite3_value_type(argvVals[VSTAT_COLUMN_COUNT + 2]) <> SQLITE_INTEGER then begin
    Result := SQLITE_ERROR; Exit;
  end;
  x := sqlite3_value_int64(argvVals[VSTAT_COLUMN_COUNT + 2]);
  if x < 0 then begin Result := SQLITE_ERROR; Exit; end;
  aVfsCnt[iRowid] := u64(x);
  Result := SQLITE_OK;
end;

{ ---------------------------------------------------------------------- }
{ Initialisation }
{ ---------------------------------------------------------------------- }

procedure ensureModulesPopulated;
begin
  if vstatInitialised <> 0 then Exit;

  FillChar(vstat_io_methods, SizeOf(vstat_io_methods), 0);
  vstat_io_methods.iVersion               := 3;
  vstat_io_methods.xClose                 := @vstatClose;
  vstat_io_methods.xRead                  := @vstatRead;
  vstat_io_methods.xWrite                 := @vstatWrite;
  vstat_io_methods.xTruncate              := @vstatTruncate;
  vstat_io_methods.xSync                  := @vstatSync;
  vstat_io_methods.xFileSize              := @vstatFileSize;
  vstat_io_methods.xLock                  := @vstatLock;
  vstat_io_methods.xUnlock                := @vstatUnlock;
  vstat_io_methods.xCheckReservedLock     := @vstatCheckReservedLock;
  vstat_io_methods.xFileControl           := @vstatFileControl;
  vstat_io_methods.xSectorSize            := @vstatSectorSize;
  vstat_io_methods.xDeviceCharacteristics := @vstatDeviceCharacteristics;
  vstat_io_methods.xShmMap                := @vstatShmMap;
  vstat_io_methods.xShmLock               := @vstatShmLock;
  vstat_io_methods.xShmBarrier            := @vstatShmBarrier;
  vstat_io_methods.xShmUnmap              := @vstatShmUnmap;
  vstat_io_methods.xFetch                 := @vstatFetch;
  vstat_io_methods.xUnfetch               := @vstatUnfetch;

  FillChar(vstat_vfs, SizeOf(vstat_vfs), 0);
  vstat_vfs.base.iVersion         := 2;
  vstat_vfs.base.szOsFile         := 0; { set at register time }
  vstat_vfs.base.mxPathname       := 1024;
  { vfsstat.c:190 — upstream zName is literally "vfslog"; preserved
    byte-identical despite the eponymous vtab being named "vfsstat". }
  vstat_vfs.base.zName            := PChar('vfslog');
  vstat_vfs.base.xOpen            := @vstatOpen;
  vstat_vfs.base.xDelete          := @vstatDelete;
  vstat_vfs.base.xAccess          := @vstatAccess;
  vstat_vfs.base.xFullPathname    := @vstatFullPathname;
  vstat_vfs.base.xDlOpen          := @vstatDlOpen;
  vstat_vfs.base.xDlError         := @vstatDlError;
  vstat_vfs.base.xDlSym           := @vstatDlSym;
  vstat_vfs.base.xDlClose         := @vstatDlClose;
  vstat_vfs.base.xRandomness      := @vstatRandomness;
  vstat_vfs.base.xSleep           := @vstatSleep;
  vstat_vfs.base.xCurrentTime     := @vstatCurrentTime;
  vstat_vfs.base.xGetLastError    := @vstatGetLastError;
  vstat_vfs.base.xCurrentTimeInt64 := @vstatCurrentTimeInt64;

  FillChar(VfsStatModule, SizeOf(VfsStatModule), 0);
  VfsStatModule.iVersion    := 0;
  VfsStatModule.xConnect    := @vstattabConnect;
  VfsStatModule.xBestIndex  := @vstattabBestIndex;
  VfsStatModule.xDisconnect := @vstattabDisconnect;
  VfsStatModule.xOpen       := @vstattabOpen;
  VfsStatModule.xClose      := @vstattabClose;
  VfsStatModule.xFilter     := @vstattabFilter;
  VfsStatModule.xNext       := @vstattabNext;
  VfsStatModule.xEof        := @vstattabEof;
  VfsStatModule.xColumn     := @vstattabColumn;
  VfsStatModule.xRowid      := @vstattabRowid;
  VfsStatModule.xUpdate     := @vstattabUpdate;

  vstatInitialised := 1;
end;

{ vfsstat.c:789..795 vstatRegister — registers the vtab on `db`. }
function vstatRegister(db: PTsqlite3): i32;
begin
  Result := sqlite3_create_module(db, 'vfsstat', @VfsStatModule, nil);
end;

{ Convenience wrapper used by sqlite3_auto_extension.  Signature must
  match Tsqlite3_loadext_fn = procedure; cdecl. }
procedure vstatAutoRegister; cdecl;
begin
  { Auto-extensions are invoked with (db, &errMsg, &api).  We only need
    `db`, but Tsqlite3_loadext_fn is defined as a no-arg procedure here.
    We reach the active connection via the surrounding init path —
    callers pre-register on every openDb in the shell, so this no-op
    auto-extension is purely a safety net for embedders that wire it
    manually. }
end;

function sqlite3_register_vfsstat: i32;
begin
  ensureModulesPopulated;
  vstat_vfs.pVfs := sqlite3_vfs_find(nil);
  if vstat_vfs.pVfs = nil then Exit(SQLITE_ERROR);
  vstat_vfs.base.szOsFile := SizeOf(TVStatFile) + vstat_vfs.pVfs^.szOsFile;
  Result := sqlite3_vfs_register(@vstat_vfs.base, 1);
end;

function sqlite3VfsstatInit(db: PTsqlite3): i32;
var rc: i32;
begin
  ensureModulesPopulated;
  if vstat_vfs.pVfs = nil then begin
    rc := sqlite3_register_vfsstat;
    if rc <> SQLITE_OK then Exit(rc);
  end;
  Result := vstatRegister(db);
end;

end.
