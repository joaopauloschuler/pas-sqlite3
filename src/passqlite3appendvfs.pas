{
  SPDX-License-Identifier: blessing

  Faithful port of ../sqlite3/ext/misc/appendvfs.c (672 lines in C).

  Implements an SQLite VFS shim ("apndvfs") that allows a SQLite database
  to be appended onto the end of some other file (typically an
  executable).  An append-mark trailer at end of file identifies the
  start of the database content:

      Start-Of-SQLite3-NNNNNNNN
      123456789 123456789 12345

  where NNNNNNNN is a 64-bit big-endian unsigned integer giving the
  offset of the first database page from the start of the prefix file.
  The combined prefix + database + append-mark is capped at 1GiB.

  Behaviour rules at xOpen:
    (1) Empty file -> ordinary database (passthrough).
    (2) File ends with the append-mark -> appended database.
    (3) File begins with "SQLite format 3\0" -> ordinary database.
    (4) Otherwise, with SQLITE_OPEN_CREATE, append a new database after
        rounding the existing file size up to APND_ROUNDUP (4096).
    (5) Otherwise, return SQLITE_CANTOPEN.

  Public entry: sqlite3AppendvfsInit(db) — equivalent to
  sqlite3_appendvfs_init() in C; safe to call multiple times because
  sqlite3_vfs_register short-circuits on a duplicate name.
}
{$I passqlite3.inc}
unit passqlite3appendvfs;

interface

uses
  ctypes,
  passqlite3types,
  passqlite3os,
  passqlite3util,
  passqlite3main;

{ Returns SQLITE_OK on success.  The db argument is unused and may be nil. }
function sqlite3AppendvfsInit(db: PTsqlite3): i32;

implementation

uses
  passqlite3printf;

const
  APND_MARK_PREFIX     = 'Start-Of-SQLite3-';
  APND_MARK_PREFIX_SZ  = 17;
  APND_MARK_FOS_SZ     = 8;
  APND_MARK_SIZE       = APND_MARK_PREFIX_SZ + APND_MARK_FOS_SZ; { 25 }

  { Maximum size of prefix + database + append-mark.  Must be < 0x40000000
    to avoid Windows locking issues. }
  APND_MAX_SIZE        = $40000000;

  APND_ROUNDUP         = 4096;
  APND_ALIGN_MASK      = i64(APND_ROUNDUP - 1);

  apvfsSqliteHdr       : array[0..15] of AnsiChar = 'SQLite format 3'#0;

function APND_START_ROUNDUP(fsz: i64): i64; inline;
begin
  Result := (fsz + APND_ALIGN_MASK) and (not APND_ALIGN_MASK);
end;

type
  PApndFile = ^TApndFile;
  TApndFile = record
    base   : sqlite3_file;  { Subclass.  MUST BE FIRST! }
    iPgOne : i64;           { Offset to start of database }
    iMark  : i64;           { Offset of append mark; -1 if unwritten }
    { Always followed by another sqlite3_file describing the whole file. }
  end;

{ Forward declarations of methods }
function apndClose(pFile: Psqlite3_file): cint; cdecl; forward;
function apndRead(pFile: Psqlite3_file; zBuf: Pointer;
                  iAmt: cint; iOfst: i64): cint; cdecl; forward;
function apndWrite(pFile: Psqlite3_file; zBuf: Pointer;
                   iAmt: cint; iOfst: i64): cint; cdecl; forward;
function apndTruncate(pFile: Psqlite3_file; size: i64): cint; cdecl; forward;
function apndSync(pFile: Psqlite3_file; flags: cint): cint; cdecl; forward;
function apndFileSize(pFile: Psqlite3_file; pSize: Pi64): cint; cdecl; forward;
function apndLock(pFile: Psqlite3_file; eLock: cint): cint; cdecl; forward;
function apndUnlock(pFile: Psqlite3_file; eLock: cint): cint; cdecl; forward;
function apndCheckReservedLock(pFile: Psqlite3_file;
                               pResOut: PcInt): cint; cdecl; forward;
function apndFileControl(pFile: Psqlite3_file; op: cint;
                         pArg: Pointer): cint; cdecl; forward;
function apndSectorSize(pFile: Psqlite3_file): cint; cdecl; forward;
function apndDeviceCharacteristics(pFile: Psqlite3_file): cint; cdecl; forward;
function apndShmMap(pFile: Psqlite3_file; iPg, pgsz, bExtend: cint;
                    pp: PPointer): cint; cdecl; forward;
function apndShmLock(pFile: Psqlite3_file; offset, n,
                     flags: cint): cint; cdecl; forward;
procedure apndShmBarrier(pFile: Psqlite3_file); cdecl; forward;
function apndShmUnmap(pFile: Psqlite3_file; deleteFlag: cint): cint;
                      cdecl; forward;
function apndFetch(pFile: Psqlite3_file; iOfst: i64; iAmt: cint;
                   pp: PPointer): cint; cdecl; forward;
function apndUnfetch(pFile: Psqlite3_file; iOfst: i64;
                     p: Pointer): cint; cdecl; forward;

function apndOpen(pVfs: Psqlite3_vfs; zName: sqlite3_filename;
                  pFile: Psqlite3_file; flags: cint;
                  pOutFlags: PcInt): cint; cdecl; forward;
function apndDelete(pVfs: Psqlite3_vfs; zPath: PChar;
                    syncDir: cint): cint; cdecl; forward;
function apndAccess(pVfs: Psqlite3_vfs; zPath: PChar; flags: cint;
                    pResOut: PcInt): cint; cdecl; forward;
function apndFullPathname(pVfs: Psqlite3_vfs; zPath: PChar; nOut: cint;
                          zOut: PChar): cint; cdecl; forward;
function apndDlOpen(pVfs: Psqlite3_vfs; zPath: PChar): Pointer;
                    cdecl; forward;
procedure apndDlError(pVfs: Psqlite3_vfs; nByte: cint;
                      zErrMsg: PChar); cdecl; forward;
function apndDlSym(pVfs: Psqlite3_vfs; p: Pointer;
                   zSym: PChar): sqlite3_syscall_ptr; cdecl; forward;
procedure apndDlClose(pVfs: Psqlite3_vfs; pHandle: Pointer); cdecl; forward;
function apndRandomness(pVfs: Psqlite3_vfs; nByte: cint;
                        zBufOut: PChar): cint; cdecl; forward;
function apndSleep(pVfs: Psqlite3_vfs; nMicro: cint): cint; cdecl; forward;
function apndCurrentTime(pVfs: Psqlite3_vfs;
                         pTimeOut: PDouble): cint; cdecl; forward;
function apndGetLastError(pVfs: Psqlite3_vfs; a: cint;
                          b: PChar): cint; cdecl; forward;
function apndCurrentTimeInt64(pVfs: Psqlite3_vfs;
                              p: Pi64): cint; cdecl; forward;
function apndSetSystemCall(pVfs: Psqlite3_vfs; zName: PChar;
                           pCall: sqlite3_syscall_ptr): cint;
                           cdecl; forward;
function apndGetSystemCall(pVfs: Psqlite3_vfs;
                           zName: PChar): sqlite3_syscall_ptr;
                           cdecl; forward;
function apndNextSystemCall(pVfs: Psqlite3_vfs;
                            zName: PChar): PChar; cdecl; forward;

var
  apnd_vfs        : sqlite3_vfs;
  apnd_io_methods : sqlite3_io_methods;

{ ORIGVFS / ORIGFILE helpers (appendvfs.c:91..92). }
function ORIGVFS(pVfs: Psqlite3_vfs): Psqlite3_vfs; inline;
begin
  Result := Psqlite3_vfs(pVfs^.pAppData);
end;

function ORIGFILE(pFile: Psqlite3_file): Psqlite3_file; inline;
begin
  Result := Psqlite3_file(PByte(pFile) + SizeOf(TApndFile));
end;

{ ----------------------------------------------------------------------
  ApndFile methods (pass-through to ORIGFILE with offset adjustment).
  ---------------------------------------------------------------------- }

function apndClose(pFile: Psqlite3_file): cint; cdecl;
begin
  pFile := ORIGFILE(pFile);
  Result := pFile^.pMethods^.xClose(pFile);
end;

function apndRead(pFile: Psqlite3_file; zBuf: Pointer;
                  iAmt: cint; iOfst: i64): cint; cdecl;
var
  paf: PApndFile;
begin
  paf := PApndFile(pFile);
  pFile := ORIGFILE(pFile);
  Result := pFile^.pMethods^.xRead(pFile, zBuf, iAmt, paf^.iPgOne + iOfst);
end;

{ Add the append-mark onto what should become the end of the file.
  iWriteEnd is the appendvfs-relative offset of the new mark.
  Mirrors appendvfs.c apndWriteMark. }
function apndWriteMark(paf: PApndFile; pFile: Psqlite3_file;
                       iWriteEnd: i64): cint;
var
  iPgOne : i64;
  a      : array[0..APND_MARK_SIZE-1] of Byte;
  i      : cint;
  rc     : cint;
begin
  iPgOne := paf^.iPgOne;
  Move(APND_MARK_PREFIX[1], a[0], APND_MARK_PREFIX_SZ);
  i := APND_MARK_FOS_SZ;
  while i > 0 do begin
    Dec(i);
    a[APND_MARK_PREFIX_SZ + i] := Byte(iPgOne and $ff);
    iPgOne := iPgOne shr 8;
  end;
  iWriteEnd := iWriteEnd + paf^.iPgOne;
  rc := pFile^.pMethods^.xWrite(pFile, @a[0], APND_MARK_SIZE, iWriteEnd);
  if rc = SQLITE_OK then paf^.iMark := iWriteEnd;
  Result := rc;
end;

function apndWrite(pFile: Psqlite3_file; zBuf: Pointer;
                   iAmt: cint; iOfst: i64): cint; cdecl;
var
  paf       : PApndFile;
  iWriteEnd : i64;
  rc        : cint;
begin
  paf := PApndFile(pFile);
  iWriteEnd := iOfst + iAmt;
  if iWriteEnd >= APND_MAX_SIZE then Exit(SQLITE_FULL);
  pFile := ORIGFILE(pFile);
  if (paf^.iMark < 0) or (paf^.iPgOne + iWriteEnd > paf^.iMark) then begin
    rc := apndWriteMark(paf, pFile, iWriteEnd);
    if rc <> SQLITE_OK then Exit(rc);
  end;
  Result := pFile^.pMethods^.xWrite(pFile, zBuf, iAmt, paf^.iPgOne + iOfst);
end;

function apndTruncate(pFile: Psqlite3_file; size: i64): cint; cdecl;
var
  paf: PApndFile;
begin
  paf := PApndFile(pFile);
  pFile := ORIGFILE(pFile);
  if apndWriteMark(paf, pFile, size) <> SQLITE_OK then Exit(SQLITE_IOERR);
  Result := pFile^.pMethods^.xTruncate(pFile, paf^.iMark + APND_MARK_SIZE);
end;

function apndSync(pFile: Psqlite3_file; flags: cint): cint; cdecl;
begin
  pFile := ORIGFILE(pFile);
  Result := pFile^.pMethods^.xSync(pFile, flags);
end;

function apndFileSize(pFile: Psqlite3_file; pSize: Pi64): cint; cdecl;
var
  paf: PApndFile;
begin
  paf := PApndFile(pFile);
  if paf^.iMark >= 0 then pSize^ := paf^.iMark - paf^.iPgOne
  else pSize^ := 0;
  Result := SQLITE_OK;
end;

function apndLock(pFile: Psqlite3_file; eLock: cint): cint; cdecl;
begin
  pFile := ORIGFILE(pFile);
  Result := pFile^.pMethods^.xLock(pFile, eLock);
end;

function apndUnlock(pFile: Psqlite3_file; eLock: cint): cint; cdecl;
begin
  pFile := ORIGFILE(pFile);
  Result := pFile^.pMethods^.xUnlock(pFile, eLock);
end;

function apndCheckReservedLock(pFile: Psqlite3_file;
                               pResOut: PcInt): cint; cdecl;
begin
  pFile := ORIGFILE(pFile);
  Result := pFile^.pMethods^.xCheckReservedLock(pFile, pResOut);
end;

function apndFileControl(pFile: Psqlite3_file; op: cint;
                         pArg: Pointer): cint; cdecl;
var
  paf : PApndFile;
  rc  : cint;
  pp  : PPAnsiChar;
  zOld: PAnsiChar;
  zNew: PAnsiChar;
begin
  paf := PApndFile(pFile);
  pFile := ORIGFILE(pFile);
  if op = SQLITE_FCNTL_SIZE_HINT then
    Pi64(pArg)^ := Pi64(pArg)^ + paf^.iPgOne;
  rc := pFile^.pMethods^.xFileControl(pFile, op, pArg);
  if (rc = SQLITE_OK) and (op = SQLITE_FCNTL_VFSNAME) then begin
    pp := PPAnsiChar(pArg);
    zOld := pp^;
    zNew := sqlite3PfMprintf('apnd(%lld)/%s',
                             [Int64(paf^.iPgOne), zOld]);
    if zOld <> nil then sqlite3_free(zOld);
    pp^ := zNew;
  end;
  Result := rc;
end;

function apndSectorSize(pFile: Psqlite3_file): cint; cdecl;
begin
  pFile := ORIGFILE(pFile);
  Result := pFile^.pMethods^.xSectorSize(pFile);
end;

function apndDeviceCharacteristics(pFile: Psqlite3_file): cint; cdecl;
begin
  pFile := ORIGFILE(pFile);
  Result := pFile^.pMethods^.xDeviceCharacteristics(pFile);
end;

function apndShmMap(pFile: Psqlite3_file; iPg, pgsz, bExtend: cint;
                    pp: PPointer): cint; cdecl;
begin
  pFile := ORIGFILE(pFile);
  Result := pFile^.pMethods^.xShmMap(pFile, iPg, pgsz, bExtend, pp);
end;

function apndShmLock(pFile: Psqlite3_file; offset, n, flags: cint): cint;
                     cdecl;
begin
  pFile := ORIGFILE(pFile);
  Result := pFile^.pMethods^.xShmLock(pFile, offset, n, flags);
end;

procedure apndShmBarrier(pFile: Psqlite3_file); cdecl;
begin
  pFile := ORIGFILE(pFile);
  pFile^.pMethods^.xShmBarrier(pFile);
end;

function apndShmUnmap(pFile: Psqlite3_file; deleteFlag: cint): cint; cdecl;
begin
  pFile := ORIGFILE(pFile);
  Result := pFile^.pMethods^.xShmUnmap(pFile, deleteFlag);
end;

function apndFetch(pFile: Psqlite3_file; iOfst: i64; iAmt: cint;
                   pp: PPointer): cint; cdecl;
var
  p: PApndFile;
begin
  p := PApndFile(pFile);
  if (p^.iMark < 0) or (iOfst + iAmt > p^.iMark) then
    Exit(SQLITE_IOERR);
  pFile := ORIGFILE(pFile);
  Result := pFile^.pMethods^.xFetch(pFile, iOfst + p^.iPgOne, iAmt, pp);
end;

function apndUnfetch(pFile: Psqlite3_file; iOfst: i64; p: Pointer): cint;
                     cdecl;
var
  pa: PApndFile;
begin
  pa := PApndFile(pFile);
  pFile := ORIGFILE(pFile);
  Result := pFile^.pMethods^.xUnfetch(pFile, iOfst + pa^.iPgOne, p);
end;

{ ----------------------------------------------------------------------
  apndReadMark / apndIsAppendvfsDatabase / apndIsOrdinaryDatabaseFile.
  Mirrors appendvfs.c:441..502.
  ---------------------------------------------------------------------- }

function apndReadMark(sz: i64; pFile: Psqlite3_file): i64;
var
  rc, i, msbs : cint;
  iMark       : i64;
  a           : array[0..APND_MARK_SIZE-1] of Byte;
begin
  msbs := 8 * (APND_MARK_FOS_SZ - 1);
  if (sz and $1ff) <> APND_MARK_SIZE then Exit(-1);
  rc := pFile^.pMethods^.xRead(pFile, @a[0], APND_MARK_SIZE,
                               sz - APND_MARK_SIZE);
  if rc <> 0 then Exit(-1);
  if CompareByte(a[0], APND_MARK_PREFIX[1], APND_MARK_PREFIX_SZ) <> 0 then
    Exit(-1);
  iMark := i64(a[APND_MARK_PREFIX_SZ] and $7f) shl msbs;
  for i := 1 to 7 do begin
    Dec(msbs, 8);
    iMark := iMark or (i64(a[APND_MARK_PREFIX_SZ + i]) shl msbs);
  end;
  if iMark > (sz - APND_MARK_SIZE - 512) then Exit(-1);
  if (iMark and $1ff) <> 0 then Exit(-1);
  Result := iMark;
end;

function apndIsAppendvfsDatabase(sz: i64; pFile: Psqlite3_file): Boolean;
var
  rc    : cint;
  zHdr  : array[0..15] of AnsiChar;
  iMark : i64;
begin
  Result := False;
  iMark := apndReadMark(sz, pFile);
  if iMark >= 0 then begin
    rc := pFile^.pMethods^.xRead(pFile, @zHdr[0], SizeOf(zHdr), iMark);
    if (rc = SQLITE_OK)
       and (CompareByte(zHdr[0], apvfsSqliteHdr[0], SizeOf(zHdr)) = 0)
       and ((sz and $1ff) = APND_MARK_SIZE)
       and (sz >= 512 + APND_MARK_SIZE) then
      Result := True;
  end;
end;

function apndIsOrdinaryDatabaseFile(sz: i64; pFile: Psqlite3_file): Boolean;
var
  zHdr: array[0..15] of AnsiChar;
begin
  if apndIsAppendvfsDatabase(sz, pFile) then Exit(False);
  if (sz and $1ff) <> 0 then Exit(False);
  if pFile^.pMethods^.xRead(pFile, @zHdr[0], SizeOf(zHdr), 0) <> SQLITE_OK then
    Exit(False);
  Result := CompareByte(zHdr[0], apvfsSqliteHdr[0], SizeOf(zHdr)) = 0;
end;

{ ----------------------------------------------------------------------
  apndOpen — appendvfs.c:507..566.
  ---------------------------------------------------------------------- }

function apndOpen(pVfs: Psqlite3_vfs; zName: sqlite3_filename;
                  pFile: Psqlite3_file; flags: cint;
                  pOutFlags: PcInt): cint; cdecl;
var
  paf       : PApndFile;
  pBaseFile : Psqlite3_file;
  pBaseVfs  : Psqlite3_vfs;
  rc        : cint;
  sz        : i64;
begin
  paf := PApndFile(pFile);
  pBaseFile := ORIGFILE(pFile);
  pBaseVfs := ORIGVFS(pVfs);
  sz := 0;

  if (flags and SQLITE_OPEN_MAIN_DB) = 0 then begin
    { appendvfs is not used for transient/temporary databases — passthrough. }
    Result := pBaseVfs^.xOpen(pBaseVfs, zName, pFile, flags, pOutFlags);
    Exit;
  end;

  FillChar(paf^, SizeOf(TApndFile), 0);
  pFile^.pMethods := @apnd_io_methods;
  paf^.iMark := -1;

  rc := pBaseVfs^.xOpen(pBaseVfs, zName, pBaseFile, flags, pOutFlags);
  if rc = SQLITE_OK then begin
    rc := pBaseFile^.pMethods^.xFileSize(pBaseFile, @sz);
    if rc <> 0 then pBaseFile^.pMethods^.xClose(pBaseFile);
  end;
  if rc <> 0 then begin
    pFile^.pMethods := nil;
    Exit(rc);
  end;

  if apndIsOrdinaryDatabaseFile(sz, pBaseFile) then begin
    { Plain DB — copy base dispatch table so this instance mimics base VFS. }
    Move(pBaseFile^, paf^, pBaseVfs^.szOsFile);
    Exit(SQLITE_OK);
  end;

  paf^.iPgOne := apndReadMark(sz, pFile);
  if paf^.iPgOne >= 0 then begin
    paf^.iMark := sz - APND_MARK_SIZE;
    Exit(SQLITE_OK);
  end;
  if (flags and SQLITE_OPEN_CREATE) = 0 then begin
    pBaseFile^.pMethods^.xClose(pBaseFile);
    rc := SQLITE_CANTOPEN;
    pFile^.pMethods := nil;
  end else begin
    { Round newly added appendvfs location to APND_ROUNDUP.  Nothing has
      been written yet; iMark < 0 indicates the mark is not on disk. }
    paf^.iPgOne := APND_START_ROUNDUP(sz);
  end;
  Result := rc;
end;

{ ----------------------------------------------------------------------
  Pass-through VFS methods.
  ---------------------------------------------------------------------- }

function apndDelete(pVfs: Psqlite3_vfs; zPath: PChar;
                    syncDir: cint): cint; cdecl;
begin
  Result := ORIGVFS(pVfs)^.xDelete(ORIGVFS(pVfs), zPath, syncDir);
end;

function apndAccess(pVfs: Psqlite3_vfs; zPath: PChar; flags: cint;
                    pResOut: PcInt): cint; cdecl;
begin
  Result := ORIGVFS(pVfs)^.xAccess(ORIGVFS(pVfs), zPath, flags, pResOut);
end;

function apndFullPathname(pVfs: Psqlite3_vfs; zPath: PChar; nOut: cint;
                          zOut: PChar): cint; cdecl;
begin
  Result := ORIGVFS(pVfs)^.xFullPathname(ORIGVFS(pVfs), zPath, nOut, zOut);
end;

function apndDlOpen(pVfs: Psqlite3_vfs; zPath: PChar): Pointer; cdecl;
begin
  Result := ORIGVFS(pVfs)^.xDlOpen(ORIGVFS(pVfs), zPath);
end;

procedure apndDlError(pVfs: Psqlite3_vfs; nByte: cint;
                      zErrMsg: PChar); cdecl;
begin
  ORIGVFS(pVfs)^.xDlError(ORIGVFS(pVfs), nByte, zErrMsg);
end;

function apndDlSym(pVfs: Psqlite3_vfs; p: Pointer;
                   zSym: PChar): sqlite3_syscall_ptr; cdecl;
begin
  Result := ORIGVFS(pVfs)^.xDlSym(ORIGVFS(pVfs), p, zSym);
end;

procedure apndDlClose(pVfs: Psqlite3_vfs; pHandle: Pointer); cdecl;
begin
  ORIGVFS(pVfs)^.xDlClose(ORIGVFS(pVfs), pHandle);
end;

function apndRandomness(pVfs: Psqlite3_vfs; nByte: cint;
                        zBufOut: PChar): cint; cdecl;
begin
  Result := ORIGVFS(pVfs)^.xRandomness(ORIGVFS(pVfs), nByte, zBufOut);
end;

function apndSleep(pVfs: Psqlite3_vfs; nMicro: cint): cint; cdecl;
begin
  Result := ORIGVFS(pVfs)^.xSleep(ORIGVFS(pVfs), nMicro);
end;

function apndCurrentTime(pVfs: Psqlite3_vfs;
                         pTimeOut: PDouble): cint; cdecl;
begin
  Result := ORIGVFS(pVfs)^.xCurrentTime(ORIGVFS(pVfs), pTimeOut);
end;

function apndGetLastError(pVfs: Psqlite3_vfs; a: cint;
                          b: PChar): cint; cdecl;
begin
  Result := ORIGVFS(pVfs)^.xGetLastError(ORIGVFS(pVfs), a, b);
end;

function apndCurrentTimeInt64(pVfs: Psqlite3_vfs; p: Pi64): cint; cdecl;
begin
  Result := ORIGVFS(pVfs)^.xCurrentTimeInt64(ORIGVFS(pVfs), p);
end;

function apndSetSystemCall(pVfs: Psqlite3_vfs; zName: PChar;
                           pCall: sqlite3_syscall_ptr): cint; cdecl;
begin
  Result := ORIGVFS(pVfs)^.xSetSystemCall(ORIGVFS(pVfs), zName, pCall);
end;

function apndGetSystemCall(pVfs: Psqlite3_vfs;
                           zName: PChar): sqlite3_syscall_ptr; cdecl;
begin
  Result := ORIGVFS(pVfs)^.xGetSystemCall(ORIGVFS(pVfs), zName);
end;

function apndNextSystemCall(pVfs: Psqlite3_vfs;
                            zName: PChar): PChar; cdecl;
begin
  Result := ORIGVFS(pVfs)^.xNextSystemCall(ORIGVFS(pVfs), zName);
end;

{ ----------------------------------------------------------------------
  Initialiser — appendvfs.c:649..672 sqlite3_appendvfs_init.
  ---------------------------------------------------------------------- }

var
  gApndvfsInitialised: Boolean = False;

function sqlite3AppendvfsInit(db: PTsqlite3): i32;
var
  pOrig: Psqlite3_vfs;
begin
  if Pointer(db) = Pointer(db) then ; { silence unused-arg }
  pOrig := sqlite3_vfs_find(nil);
  if pOrig = nil then Exit(SQLITE_ERROR);

  { Mirrors appendvfs.c:177..200 — apnd_vfs / apnd_io_methods are static
    struct-literal initialised exactly once.  The Pascal port previously
    re-ran FillChar + per-field assignment on every call; if apnd_vfs was
    already linked in the VFS list, FillChar would zero its pNext pointer
    BEFORE vfs_register's vfsUnlink walked the chain, severing the list
    after apnd_vfs and dropping every subsequent VFS (notably memdb).
    That broke `.open --deserialize` (bug 6.19) because the reopen-as-memdb
    arm in attachFunc could no longer find the memdb VFS. }
  if not gApndvfsInitialised then begin
    FillChar(apnd_io_methods, SizeOf(apnd_io_methods), 0);
    apnd_io_methods.iVersion               := 3;
    apnd_io_methods.xClose                 := @apndClose;
    apnd_io_methods.xRead                  := @apndRead;
    apnd_io_methods.xWrite                 := @apndWrite;
    apnd_io_methods.xTruncate              := @apndTruncate;
    apnd_io_methods.xSync                  := @apndSync;
    apnd_io_methods.xFileSize              := @apndFileSize;
    apnd_io_methods.xLock                  := @apndLock;
    apnd_io_methods.xUnlock                := @apndUnlock;
    apnd_io_methods.xCheckReservedLock     := @apndCheckReservedLock;
    apnd_io_methods.xFileControl           := @apndFileControl;
    apnd_io_methods.xSectorSize            := @apndSectorSize;
    apnd_io_methods.xDeviceCharacteristics := @apndDeviceCharacteristics;
    apnd_io_methods.xShmMap                := @apndShmMap;
    apnd_io_methods.xShmLock               := @apndShmLock;
    apnd_io_methods.xShmBarrier            := @apndShmBarrier;
    apnd_io_methods.xShmUnmap              := @apndShmUnmap;
    apnd_io_methods.xFetch                 := @apndFetch;
    apnd_io_methods.xUnfetch               := @apndUnfetch;

    FillChar(apnd_vfs, SizeOf(apnd_vfs), 0);
    apnd_vfs.mxPathname      := 1024;
    apnd_vfs.zName           := 'apndvfs';
    apnd_vfs.xOpen           := @apndOpen;
    apnd_vfs.xDelete         := @apndDelete;
    apnd_vfs.xAccess         := @apndAccess;
    apnd_vfs.xFullPathname   := @apndFullPathname;
    apnd_vfs.xDlOpen         := @apndDlOpen;
    apnd_vfs.xDlError        := @apndDlError;
    apnd_vfs.xDlSym          := @apndDlSym;
    apnd_vfs.xDlClose        := @apndDlClose;
    apnd_vfs.xRandomness     := @apndRandomness;
    apnd_vfs.xSleep          := @apndSleep;
    apnd_vfs.xCurrentTime    := @apndCurrentTime;
    apnd_vfs.xGetLastError   := @apndGetLastError;
    apnd_vfs.xCurrentTimeInt64 := @apndCurrentTimeInt64;
    apnd_vfs.xSetSystemCall  := @apndSetSystemCall;
    apnd_vfs.xGetSystemCall  := @apndGetSystemCall;
    apnd_vfs.xNextSystemCall := @apndNextSystemCall;
    gApndvfsInitialised := True;
  end;
  { iVersion / szOsFile / pAppData track the underlying default VFS, which
    may have changed since the previous init call; mirror appendvfs.c:661.. }
  apnd_vfs.iVersion        := pOrig^.iVersion;
  apnd_vfs.szOsFile        := pOrig^.szOsFile + SizeOf(TApndFile);
  apnd_vfs.pAppData        := pOrig;

  Result := sqlite3_vfs_register(@apnd_vfs, 0);
end;

end.
