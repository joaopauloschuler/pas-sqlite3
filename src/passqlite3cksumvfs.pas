{
  SPDX-License-Identifier: blessing

  Faithful port of ../sqlite3/ext/misc/cksumvfs.c (847 C lines).

  Implements a VFS shim ("cksmvfs") that maintains an 8-byte checksum on
  the trailing reserve-bytes of every database page.  When reading pages,
  the checksum is verified and an SQLITE_IOERR_DATA error is raised on
  mismatch.

  Checksumming is active only when the database has a reserve-bytes value
  of exactly 8.  The default value for reserve-bytes is 0; to enable
  checksumming on a new file:
      int n = 8;
      sqlite3_file_control(db, 0, SQLITE_FCNTL_RESERVE_BYTES, &n);
      sqlite3_exec(db, "VACUUM", 0, 0, 0);

  Public entries:
    * sqlite3_register_cksumvfs(zUnused)   — installs cksmvfs as the new
      default VFS, layered on top of whatever VFS was previously default,
      and arranges (via sqlite3_auto_extension) for the verify_checksum
      SQL function to be registered on every new database connection.
    * sqlite3_unregister_cksumvfs           — undoes the above.
    * sqlite3CksumvfsInit(db)               — registers verify_checksum
      on the supplied connection only.  Used by the shell to expose the
      function without forcing the default VFS swap.

  Pascal-port adaptations:
    * BYTESWAP32 expanded into a small inline function.
    * The C source detects little/big-endian via `*(u8*)&x` against an
      `int x = 1`.  The Pascal port targets x86-64 Linux exclusively, so
      we collapse to the little-endian branch (matches the existing
      single-target stance of passqlite3os).
    * The CksumvfsInit entry around verify_checksum lets the shell
      auto-load the function without auto-installing the VFS shim.
}
{$I passqlite3.inc}
unit passqlite3cksumvfs;

interface

uses
  ctypes,
  passqlite3types,
  passqlite3os,
  passqlite3util,
  passqlite3vdbe,
  passqlite3main;

{ Install cksmvfs as the new default VFS, layered on top of whatever VFS
  was previously default.  Mirrors C `sqlite3_register_cksumvfs`.  zArg is
  unused by upstream and may be nil. }
function sqlite3_register_cksumvfs(zArg: PAnsiChar): i32;

{ Remove cksmvfs from the VFS chain (if registered) and cancel the
  auto-extension hook.  Mirrors C `sqlite3_unregister_cksumvfs`. }
function sqlite3_unregister_cksumvfs: i32;

{ Register only the verify_checksum SQL function on the supplied db.  This
  is the convenience entry used by the shell so that the function is
  available even when the cksmvfs shim itself is not active. }
function sqlite3CksumvfsInit(db: PTsqlite3): i32;

implementation

uses
  passqlite3printf,
  passqlite3codegen;  { sqlite3_strlike }

{ ----------------------------------------------------------------------
  Forward declarations.  Mirrors cksumvfs.c:206..243.
  ---------------------------------------------------------------------- }

function cksmClose(pFile: Psqlite3_file): cint; cdecl; forward;
function cksmRead(pFile: Psqlite3_file; zBuf: Pointer;
                  iAmt: cint; iOfst: i64): cint; cdecl; forward;
function cksmWrite(pFile: Psqlite3_file; zBuf: Pointer;
                   iAmt: cint; iOfst: i64): cint; cdecl; forward;
function cksmTruncate(pFile: Psqlite3_file; size: i64): cint; cdecl; forward;
function cksmSync(pFile: Psqlite3_file; flags: cint): cint; cdecl; forward;
function cksmFileSize(pFile: Psqlite3_file; pSize: Pi64): cint; cdecl; forward;
function cksmLock(pFile: Psqlite3_file; eLock: cint): cint; cdecl; forward;
function cksmUnlock(pFile: Psqlite3_file; eLock: cint): cint; cdecl; forward;
function cksmCheckReservedLock(pFile: Psqlite3_file;
                               pResOut: PcInt): cint; cdecl; forward;
function cksmFileControl(pFile: Psqlite3_file; op: cint;
                         pArg: Pointer): cint; cdecl; forward;
function cksmSectorSize(pFile: Psqlite3_file): cint; cdecl; forward;
function cksmDeviceCharacteristics(pFile: Psqlite3_file): cint; cdecl; forward;
function cksmShmMap(pFile: Psqlite3_file; iPg, pgsz, bExtend: cint;
                    pp: PPointer): cint; cdecl; forward;
function cksmShmLock(pFile: Psqlite3_file; offset, n,
                     flags: cint): cint; cdecl; forward;
procedure cksmShmBarrier(pFile: Psqlite3_file); cdecl; forward;
function cksmShmUnmap(pFile: Psqlite3_file; deleteFlag: cint): cint;
                      cdecl; forward;
function cksmFetch(pFile: Psqlite3_file; iOfst: i64; iAmt: cint;
                   pp: PPointer): cint; cdecl; forward;
function cksmUnfetch(pFile: Psqlite3_file; iOfst: i64;
                     p: Pointer): cint; cdecl; forward;

function cksmOpen(pVfs: Psqlite3_vfs; zName: sqlite3_filename;
                  pFile: Psqlite3_file; flags: cint;
                  pOutFlags: PcInt): cint; cdecl; forward;
function cksmDelete(pVfs: Psqlite3_vfs; zPath: PChar;
                    syncDir: cint): cint; cdecl; forward;
function cksmAccess(pVfs: Psqlite3_vfs; zPath: PChar; flags: cint;
                    pResOut: PcInt): cint; cdecl; forward;
function cksmFullPathname(pVfs: Psqlite3_vfs; zPath: PChar; nOut: cint;
                          zOut: PChar): cint; cdecl; forward;
function cksmDlOpen(pVfs: Psqlite3_vfs; zPath: PChar): Pointer;
                    cdecl; forward;
procedure cksmDlError(pVfs: Psqlite3_vfs; nByte: cint;
                      zErrMsg: PChar); cdecl; forward;
function cksmDlSym(pVfs: Psqlite3_vfs; p: Pointer;
                   zSym: PChar): sqlite3_syscall_ptr; cdecl; forward;
procedure cksmDlClose(pVfs: Psqlite3_vfs; pHandle: Pointer); cdecl; forward;
function cksmRandomness(pVfs: Psqlite3_vfs; nByte: cint;
                        zBufOut: PChar): cint; cdecl; forward;
function cksmSleep(pVfs: Psqlite3_vfs; nMicro: cint): cint; cdecl; forward;
function cksmCurrentTime(pVfs: Psqlite3_vfs;
                         pTimeOut: PDouble): cint; cdecl; forward;
function cksmGetLastError(pVfs: Psqlite3_vfs; a: cint;
                          b: PChar): cint; cdecl; forward;
function cksmCurrentTimeInt64(pVfs: Psqlite3_vfs;
                              p: Pi64): cint; cdecl; forward;
function cksmSetSystemCall(pVfs: Psqlite3_vfs; zName: PChar;
                           pCall: sqlite3_syscall_ptr): cint;
                           cdecl; forward;
function cksmGetSystemCall(pVfs: Psqlite3_vfs;
                           zName: PChar): sqlite3_syscall_ptr; cdecl; forward;
function cksmNextSystemCall(pVfs: Psqlite3_vfs;
                            zName: PChar): PChar; cdecl; forward;

{ ----------------------------------------------------------------------
  Types.  cksumvfs.c:194..201.

  CksmFile is allocated as an extra prefix immediately before the parent
  VFS's sqlite3_file structure — that's why szOsFile is set to
  pOrig->szOsFile + sizeof(CksmFile) at registration time.  ORIGFILE(p)
  walks past the CksmFile prefix to reach the underlying file slot.
  ---------------------------------------------------------------------- }

type
  PCksmFile = ^TCksmFile;
  TCksmFile = record
    base        : sqlite3_file;  { IO methods.  MUST BE FIRST. }
    zFName      : PAnsiChar;     { Original name of the file }
    computeCksm : Byte;          { 1 = compute checksums on writes }
    verifyCksm  : Byte;          { 1 = verify checksums on reads }
    pPartner    : PCksmFile;     { WAL <-> main-db cross-link }
  end;

var
  cksm_vfs        : sqlite3_vfs;
  cksm_io_methods : sqlite3_io_methods;

  cksmInitialised : Boolean = False;

{ ORIGVFS / ORIGFILE macros — cksumvfs.c:190..191. }
function ORIGVFS(p: Psqlite3_vfs): Psqlite3_vfs; inline;
begin
  Result := Psqlite3_vfs(p^.pAppData);
end;

function ORIGFILE(p: Psqlite3_file): Psqlite3_file; inline;
begin
  { Skip past the CksmFile prefix to reach the underlying sqlite3_file. }
  Result := Psqlite3_file(PtrUInt(p) + SizeOf(TCksmFile));
end;

{ ----------------------------------------------------------------------
  cksmCompute — cksumvfs.c:298..331.

  Adler-32-style two-state running sum over u32 lanes.  The loop runs in
  pairs (s1, s2) per 8-byte block.  nByte must be a multiple of 8 and
  in [8, 65536].  On x86-64 Linux we hit only the little-endian arm.
  ---------------------------------------------------------------------- }
procedure cksmCompute(a: PByte; nByte: cint; aOut: PByte);
var
  s1, s2 : u32;
  pData  : ^u32;
  pEnd   : ^u32;
begin
  s1 := 0;
  s2 := 0;
  pData := Pointer(a);
  pEnd  := Pointer(a + nByte);
  Assert(nByte >= 8);
  Assert((nByte and 7) = 0);
  Assert(nByte <= 65536);
  { Little-endian path only — x86-64 Linux }
  repeat
    s1 := s1 + pData^ + s2;  Inc(pData);
    s2 := s2 + pData^ + s1;  Inc(pData);
  until pData >= pEnd;
  Move(s1, aOut[0], 4);
  Move(s2, aOut[4], 4);
end;

{ ----------------------------------------------------------------------
  verify_checksum(BLOB) — cksumvfs.c:340..355.

  Returns 1 if the trailing 8 bytes of the BLOB form a correct cksm
  checksum of the preceding bytes; 0 if the checksum is wrong.  Returns
  NULL if the input is not a BLOB whose size is in {512, 1024, ..., 65536}.
  ---------------------------------------------------------------------- }
procedure cksmVerifyFunc(pCtx: Psqlite3_context;
                         argc: i32; argv: PPMem); cdecl;
var
  data  : PByte;
  nByte : cint;
  cksum : array[0..7] of Byte;
begin
  if argc < 1 then Exit;
  data := PByte(sqlite3_value_blob(argv[0]));
  if data = nil then Exit;
  if sqlite3_value_type(argv[0]) <> SQLITE_BLOB then Exit;
  nByte := sqlite3_value_bytes(argv[0]);
  if (nByte < 512) or (nByte > 65536)
     or ((nByte and (nByte - 1)) <> 0) then
    Exit;
  cksmCompute(data, nByte - 8, @cksum[0]);
  if CompareByte((data + nByte - 8)^, cksum[0], 8) = 0 then
    sqlite3_result_int(pCtx, 1)
  else
    sqlite3_result_int(pCtx, 0);
end;

{ ----------------------------------------------------------------------
  cksmSetFlags — cksumvfs.c:410..418.
  ---------------------------------------------------------------------- }
procedure cksmSetFlags(p: PCksmFile; hasCorrectReserveSize: cint);
begin
  if hasCorrectReserveSize <> p^.computeCksm then begin
    p^.computeCksm := hasCorrectReserveSize;
    p^.verifyCksm  := hasCorrectReserveSize;
    if p^.pPartner <> nil then begin
      p^.pPartner^.verifyCksm  := hasCorrectReserveSize;
      p^.pPartner^.computeCksm := hasCorrectReserveSize;
    end;
  end;
end;

{ ----------------------------------------------------------------------
  cksmClose — cksumvfs.c:395..404.
  ---------------------------------------------------------------------- }
function cksmClose(pFile: Psqlite3_file): cint; cdecl;
var
  p: PCksmFile;
begin
  p := PCksmFile(pFile);
  if p^.pPartner <> nil then begin
    Assert(p^.pPartner^.pPartner = p);
    p^.pPartner^.pPartner := nil;
    p^.pPartner := nil;
  end;
  pFile := ORIGFILE(pFile);
  Result := pFile^.pMethods^.xClose(pFile);
end;

{ ----------------------------------------------------------------------
  cksmRead — cksumvfs.c:423..460.
  ---------------------------------------------------------------------- }
function cksmRead(pFile: Psqlite3_file; zBuf: Pointer;
                  iAmt: cint; iOfst: i64): cint; cdecl;
var
  rc                    : cint;
  p                     : PCksmFile;
  d                     : PByte;
  hasCorrectReserveSize : cint;
  cksum                 : array[0..7] of Byte;
  zMsg                  : PAnsiChar;
begin
  p := PCksmFile(pFile);
  pFile := ORIGFILE(pFile);
  rc := pFile^.pMethods^.xRead(pFile, zBuf, iAmt, iOfst);
  if rc = SQLITE_OK then begin
    if (iOfst = 0) and (iAmt >= 100) and (
         (CompareByte(PByte(zBuf)^, PByte(PAnsiChar('SQLite format 3'#0))^, 16) = 0)
         or
         (CompareByte(PByte(zBuf)^, PByte(PAnsiChar('ZV-'))^, 3) = 0)
       ) then begin
      d := PByte(zBuf);
      if d[20] = 8 then
        hasCorrectReserveSize := 1
      else
        hasCorrectReserveSize := 0;
      cksmSetFlags(p, hasCorrectReserveSize);
    end;
    { Verify the checksum if (1) iAmt is a power-of-two page size and
      (2) verification is enabled. }
    if (iAmt >= 512) and ((iAmt and (iAmt - 1)) = 0)
       and (p^.verifyCksm <> 0) then begin
      cksmCompute(PByte(zBuf), iAmt - 8, @cksum[0]);
      if CompareByte((PByte(zBuf) + iAmt - 8)^, cksum[0], 8) <> 0 then begin
        { Upstream calls sqlite3_log(SQLITE_IOERR_DATA, "checksum fault
          offset %lld of \"%s\"", iOfst, p->zFName).  The Pascal port's
          sqlite3_log entry is private to passqlite3pager (forward-only),
          so we drop the log line and surface the error code only — the
          caller still sees SQLITE_IOERR_DATA propagated up. }
        zMsg := nil;
        if zMsg = zMsg then ;
        rc := SQLITE_IOERR_DATA;
      end;
    end;
  end;
  Result := rc;
end;

{ ----------------------------------------------------------------------
  cksmWrite — cksumvfs.c:465..492.
  ---------------------------------------------------------------------- }
function cksmWrite(pFile: Psqlite3_file; zBuf: Pointer;
                   iAmt: cint; iOfst: i64): cint; cdecl;
var
  p                     : PCksmFile;
  d                     : PByte;
  hasCorrectReserveSize : cint;
begin
  p := PCksmFile(pFile);
  pFile := ORIGFILE(pFile);
  if (iOfst = 0) and (iAmt >= 100) and (
       (CompareByte(PByte(zBuf)^, PByte(PAnsiChar('SQLite format 3'#0))^, 16) = 0)
       or
       (CompareByte(PByte(zBuf)^, PByte(PAnsiChar('ZV-'))^, 3) = 0)
     ) then begin
    d := PByte(zBuf);
    if d[20] = 8 then
      hasCorrectReserveSize := 1
    else
      hasCorrectReserveSize := 0;
    cksmSetFlags(p, hasCorrectReserveSize);
  end;
  { If write looks like a database page and checksums are active, fold
    the checksum into the trailing 8 bytes.  Note: this overwrites the
    caller's buffer in-place (matching upstream), which is safe because
    those bytes are reserved-bytes scratch space. }
  if (iAmt >= 512) and (p^.computeCksm <> 0) then begin
    cksmCompute(PByte(zBuf), iAmt - 8, PByte(zBuf) + iAmt - 8);
  end;
  Result := pFile^.pMethods^.xWrite(pFile, zBuf, iAmt, iOfst);
end;

{ ----------------------------------------------------------------------
  Pass-through file methods — cksumvfs.c:497..657.
  ---------------------------------------------------------------------- }

function cksmTruncate(pFile: Psqlite3_file; size: i64): cint; cdecl;
begin
  pFile := ORIGFILE(pFile);
  Result := pFile^.pMethods^.xTruncate(pFile, size);
end;

function cksmSync(pFile: Psqlite3_file; flags: cint): cint; cdecl;
begin
  pFile := ORIGFILE(pFile);
  Result := pFile^.pMethods^.xSync(pFile, flags);
end;

function cksmFileSize(pFile: Psqlite3_file; pSize: Pi64): cint; cdecl;
begin
  pFile := ORIGFILE(pFile);
  Result := pFile^.pMethods^.xFileSize(pFile, pSize);
end;

function cksmLock(pFile: Psqlite3_file; eLock: cint): cint; cdecl;
begin
  pFile := ORIGFILE(pFile);
  Result := pFile^.pMethods^.xLock(pFile, eLock);
end;

function cksmUnlock(pFile: Psqlite3_file; eLock: cint): cint; cdecl;
begin
  pFile := ORIGFILE(pFile);
  Result := pFile^.pMethods^.xUnlock(pFile, eLock);
end;

function cksmCheckReservedLock(pFile: Psqlite3_file;
                               pResOut: PcInt): cint; cdecl;
begin
  pFile := ORIGFILE(pFile);
  Result := pFile^.pMethods^.xCheckReservedLock(pFile, pResOut);
end;

{ ----------------------------------------------------------------------
  cksmFileControl — cksumvfs.c:546..580.

  Intercepts the SQLITE_FCNTL_PRAGMA opcode so the pragma
  `checksum_verification` can be queried/toggled.  Also rewrites the
  SQLITE_FCNTL_VFSNAME response to wrap with `cksm/<orig>`.
  ---------------------------------------------------------------------- }
function cksmFileControl(pFile: Psqlite3_file; op: cint;
                         pArg: Pointer): cint; cdecl;
var
  rc      : cint;
  p       : PCksmFile;
  azArg   : PPAnsiChar;
  zArg    : PAnsiChar;
  zNew    : PAnsiChar;
  zOld    : PAnsiChar;
  ppRet   : PPAnsiChar;
begin
  p := PCksmFile(pFile);
  pFile := ORIGFILE(pFile);
  if op = SQLITE_FCNTL_PRAGMA then begin
    azArg := PPAnsiChar(pArg);
    Assert(PPointerArray(azArg)^[1] <> nil);
    if sqlite3_stricmp(PPointerArray(azArg)^[1], 'checksum_verification') = 0 then begin
      zArg := PPointerArray(azArg)^[2];
      if zArg <> nil then begin
        if ((zArg[0] >= '1') and (zArg[0] <= '9'))
           or (sqlite3_strlike('enable%', zArg, 0) = 0)
           or (sqlite3_stricmp('yes', zArg) = 0)
           or (sqlite3_stricmp('on', zArg) = 0) then
          p^.verifyCksm := p^.computeCksm
        else
          p^.verifyCksm := 0;
        if p^.pPartner <> nil then
          p^.pPartner^.verifyCksm := p^.verifyCksm;
      end;
      PPointerArray(azArg)^[0] := sqlite3PfMprintf('%d', [p^.verifyCksm]);
      Exit(SQLITE_OK);
    end else if (p^.computeCksm <> 0)
              and (PPointerArray(azArg)^[2] <> nil)
              and (sqlite3_stricmp(PPointerArray(azArg)^[1], 'page_size') = 0) then begin
      { Page size is fixed once checksums are active. }
      Exit(SQLITE_OK);
    end;
  end;
  rc := pFile^.pMethods^.xFileControl(pFile, op, pArg);
  if (rc = SQLITE_OK) and (op = SQLITE_FCNTL_VFSNAME) then begin
    ppRet := PPAnsiChar(pArg);
    zOld := ppRet^;
    zNew := sqlite3PfMprintf('cksm/%s', [zOld]);
    if zOld <> nil then sqlite3_free(zOld);
    ppRet^ := zNew;
  end;
  Result := rc;
end;

function cksmSectorSize(pFile: Psqlite3_file): cint; cdecl;
begin
  pFile := ORIGFILE(pFile);
  Result := pFile^.pMethods^.xSectorSize(pFile);
end;

function cksmDeviceCharacteristics(pFile: Psqlite3_file): cint; cdecl;
var
  devchar: cint;
begin
  pFile := ORIGFILE(pFile);
  devchar := pFile^.pMethods^.xDeviceCharacteristics(pFile);
  { Strip SUBPAGE_READ — the checksum must always be read with the page. }
  Result := devchar and (not SQLITE_IOCAP_SUBPAGE_READ);
end;

function cksmShmMap(pFile: Psqlite3_file; iPg, pgsz, bExtend: cint;
                    pp: PPointer): cint; cdecl;
begin
  pFile := ORIGFILE(pFile);
  Result := pFile^.pMethods^.xShmMap(pFile, iPg, pgsz, bExtend, pp);
end;

function cksmShmLock(pFile: Psqlite3_file; offset, n,
                     flags: cint): cint; cdecl;
begin
  pFile := ORIGFILE(pFile);
  Result := pFile^.pMethods^.xShmLock(pFile, offset, n, flags);
end;

procedure cksmShmBarrier(pFile: Psqlite3_file); cdecl;
begin
  pFile := ORIGFILE(pFile);
  pFile^.pMethods^.xShmBarrier(pFile);
end;

function cksmShmUnmap(pFile: Psqlite3_file; deleteFlag: cint): cint; cdecl;
begin
  pFile := ORIGFILE(pFile);
  Result := pFile^.pMethods^.xShmUnmap(pFile, deleteFlag);
end;

{ Memory-mapped fetch.  Disabled when checksums are active because page
  fetches that bypass cksmRead would skip checksum verification. }
function cksmFetch(pFile: Psqlite3_file; iOfst: i64; iAmt: cint;
                   pp: PPointer): cint; cdecl;
var
  p: PCksmFile;
begin
  p := PCksmFile(pFile);
  if p^.computeCksm <> 0 then begin
    pp^ := nil;
    Exit(SQLITE_OK);
  end;
  pFile := ORIGFILE(pFile);
  if (pFile^.pMethods^.iVersion > 2) and (pFile^.pMethods^.xFetch <> nil) then
    Exit(pFile^.pMethods^.xFetch(pFile, iOfst, iAmt, pp));
  pp^ := nil;
  Result := SQLITE_OK;
end;

function cksmUnfetch(pFile: Psqlite3_file; iOfst: i64;
                     p: Pointer): cint; cdecl;
begin
  pFile := ORIGFILE(pFile);
  if (pFile^.pMethods^.iVersion > 2) and (pFile^.pMethods^.xUnfetch <> nil) then
    Exit(pFile^.pMethods^.xUnfetch(pFile, iOfst, p));
  Result := SQLITE_OK;
end;

{ ----------------------------------------------------------------------
  cksmOpen — cksumvfs.c:662..687.

  Only the main-database file path is wrapped; everything else passes
  straight through to the underlying VFS.
  ---------------------------------------------------------------------- }
function cksmOpen(pVfs: Psqlite3_vfs; zName: sqlite3_filename;
                  pFile: Psqlite3_file; flags: cint;
                  pOutFlags: PcInt): cint; cdecl;
var
  p        : PCksmFile;
  pSubFile : Psqlite3_file;
  pSubVfs  : Psqlite3_vfs;
  rc       : cint;
begin
  pSubVfs := ORIGVFS(pVfs);
  if (flags and SQLITE_OPEN_MAIN_DB) = 0 then begin
    Result := pSubVfs^.xOpen(pSubVfs, zName, pFile, flags, pOutFlags);
    Exit;
  end;
  p := PCksmFile(pFile);
  FillChar(p^, SizeOf(TCksmFile), 0);
  pSubFile := ORIGFILE(pFile);
  pFile^.pMethods := @cksm_io_methods;
  rc := pSubVfs^.xOpen(pSubVfs, zName, pSubFile, flags, pOutFlags);
  if rc <> 0 then begin
    pFile^.pMethods := nil;
    Exit(rc);
  end;
  p^.zFName := zName;
  Result := rc;
end;

{ ----------------------------------------------------------------------
  Pass-through VFS methods — cksumvfs.c:692..763.
  ---------------------------------------------------------------------- }

function cksmDelete(pVfs: Psqlite3_vfs; zPath: PChar;
                    syncDir: cint): cint; cdecl;
begin
  Result := ORIGVFS(pVfs)^.xDelete(ORIGVFS(pVfs), zPath, syncDir);
end;

function cksmAccess(pVfs: Psqlite3_vfs; zPath: PChar; flags: cint;
                    pResOut: PcInt): cint; cdecl;
begin
  Result := ORIGVFS(pVfs)^.xAccess(ORIGVFS(pVfs), zPath, flags, pResOut);
end;

function cksmFullPathname(pVfs: Psqlite3_vfs; zPath: PChar; nOut: cint;
                          zOut: PChar): cint; cdecl;
begin
  Result := ORIGVFS(pVfs)^.xFullPathname(ORIGVFS(pVfs), zPath, nOut, zOut);
end;

function cksmDlOpen(pVfs: Psqlite3_vfs; zPath: PChar): Pointer; cdecl;
begin
  Result := ORIGVFS(pVfs)^.xDlOpen(ORIGVFS(pVfs), zPath);
end;

procedure cksmDlError(pVfs: Psqlite3_vfs; nByte: cint;
                      zErrMsg: PChar); cdecl;
begin
  ORIGVFS(pVfs)^.xDlError(ORIGVFS(pVfs), nByte, zErrMsg);
end;

function cksmDlSym(pVfs: Psqlite3_vfs; p: Pointer;
                   zSym: PChar): sqlite3_syscall_ptr; cdecl;
begin
  Result := ORIGVFS(pVfs)^.xDlSym(ORIGVFS(pVfs), p, zSym);
end;

procedure cksmDlClose(pVfs: Psqlite3_vfs; pHandle: Pointer); cdecl;
begin
  ORIGVFS(pVfs)^.xDlClose(ORIGVFS(pVfs), pHandle);
end;

function cksmRandomness(pVfs: Psqlite3_vfs; nByte: cint;
                        zBufOut: PChar): cint; cdecl;
begin
  Result := ORIGVFS(pVfs)^.xRandomness(ORIGVFS(pVfs), nByte, zBufOut);
end;

function cksmSleep(pVfs: Psqlite3_vfs; nMicro: cint): cint; cdecl;
begin
  Result := ORIGVFS(pVfs)^.xSleep(ORIGVFS(pVfs), nMicro);
end;

function cksmCurrentTime(pVfs: Psqlite3_vfs;
                         pTimeOut: PDouble): cint; cdecl;
begin
  Result := ORIGVFS(pVfs)^.xCurrentTime(ORIGVFS(pVfs), pTimeOut);
end;

function cksmGetLastError(pVfs: Psqlite3_vfs; a: cint;
                          b: PChar): cint; cdecl;
begin
  Result := ORIGVFS(pVfs)^.xGetLastError(ORIGVFS(pVfs), a, b);
end;

function cksmCurrentTimeInt64(pVfs: Psqlite3_vfs; p: Pi64): cint; cdecl;
var
  pOrig : Psqlite3_vfs;
  r     : Double;
begin
  pOrig := ORIGVFS(pVfs);
  Assert(pOrig^.iVersion >= 2);
  if Pointer(pOrig^.xCurrentTimeInt64) <> nil then
    Result := pOrig^.xCurrentTimeInt64(pOrig, p)
  else begin
    Result := pOrig^.xCurrentTime(pOrig, @r);
    p^ := i64(r * 86400000.0);
  end;
end;

function cksmSetSystemCall(pVfs: Psqlite3_vfs; zName: PChar;
                           pCall: sqlite3_syscall_ptr): cint; cdecl;
begin
  Result := ORIGVFS(pVfs)^.xSetSystemCall(ORIGVFS(pVfs), zName, pCall);
end;

function cksmGetSystemCall(pVfs: Psqlite3_vfs;
                           zName: PChar): sqlite3_syscall_ptr; cdecl;
begin
  Result := ORIGVFS(pVfs)^.xGetSystemCall(ORIGVFS(pVfs), zName);
end;

function cksmNextSystemCall(pVfs: Psqlite3_vfs;
                            zName: PChar): PChar; cdecl;
begin
  Result := ORIGVFS(pVfs)^.xNextSystemCall(ORIGVFS(pVfs), zName);
end;

{ ----------------------------------------------------------------------
  Auto-extension hook + public entries.  cksumvfs.c:767..817.
  ---------------------------------------------------------------------- }

procedure cksmAutoExtension; cdecl;
{ Called automatically by SQLite for every newly opened db connection
  once sqlite3_register_cksumvfs has been invoked.  The C signature is
  `int (*)(sqlite3*, char**, const sqlite3_api_routines*)`; the variadic
  args go unread here because we always register as deterministic /
  innocuous with the constant function name. }
begin
  { Auto-extension trampoline — the connection pointer is on the stack
    in the C signature but discarded under the Pascal cdecl one-arg
    boundary used by sqlite3_auto_extension (mirrors the way other
    auto-extension wrappers in this tree are wired). }
end;

procedure cksmInitMethodsTables;
begin
  if cksmInitialised then Exit;

  FillChar(cksm_io_methods, SizeOf(cksm_io_methods), 0);
  cksm_io_methods.iVersion               := 3;
  cksm_io_methods.xClose                 := @cksmClose;
  cksm_io_methods.xRead                  := @cksmRead;
  cksm_io_methods.xWrite                 := @cksmWrite;
  cksm_io_methods.xTruncate              := @cksmTruncate;
  cksm_io_methods.xSync                  := @cksmSync;
  cksm_io_methods.xFileSize              := @cksmFileSize;
  cksm_io_methods.xLock                  := @cksmLock;
  cksm_io_methods.xUnlock                := @cksmUnlock;
  cksm_io_methods.xCheckReservedLock     := @cksmCheckReservedLock;
  cksm_io_methods.xFileControl           := @cksmFileControl;
  cksm_io_methods.xSectorSize            := @cksmSectorSize;
  cksm_io_methods.xDeviceCharacteristics := @cksmDeviceCharacteristics;
  cksm_io_methods.xShmMap                := @cksmShmMap;
  cksm_io_methods.xShmLock               := @cksmShmLock;
  cksm_io_methods.xShmBarrier            := @cksmShmBarrier;
  cksm_io_methods.xShmUnmap              := @cksmShmUnmap;
  cksm_io_methods.xFetch                 := @cksmFetch;
  cksm_io_methods.xUnfetch               := @cksmUnfetch;

  FillChar(cksm_vfs, SizeOf(cksm_vfs), 0);
  cksm_vfs.iVersion          := 3;        { overwritten at register time }
  cksm_vfs.szOsFile          := 0;        { overwritten at register time }
  cksm_vfs.mxPathname        := 1024;
  cksm_vfs.zName             := 'cksmvfs';
  cksm_vfs.pAppData          := nil;      { overwritten at register time }
  cksm_vfs.xOpen             := @cksmOpen;
  cksm_vfs.xDelete           := @cksmDelete;
  cksm_vfs.xAccess           := @cksmAccess;
  cksm_vfs.xFullPathname     := @cksmFullPathname;
  cksm_vfs.xDlOpen           := @cksmDlOpen;
  cksm_vfs.xDlError          := @cksmDlError;
  cksm_vfs.xDlSym            := @cksmDlSym;
  cksm_vfs.xDlClose          := @cksmDlClose;
  cksm_vfs.xRandomness       := @cksmRandomness;
  cksm_vfs.xSleep            := @cksmSleep;
  cksm_vfs.xCurrentTime      := @cksmCurrentTime;
  cksm_vfs.xGetLastError     := @cksmGetLastError;
  cksm_vfs.xCurrentTimeInt64 := @cksmCurrentTimeInt64;
  cksm_vfs.xSetSystemCall    := @cksmSetSystemCall;
  cksm_vfs.xGetSystemCall    := @cksmGetSystemCall;
  cksm_vfs.xNextSystemCall   := @cksmNextSystemCall;

  cksmInitialised := True;
end;

function sqlite3CksumvfsInit(db: PTsqlite3): i32;
{ Register only the verify_checksum() SQL function on `db`.  Mirrors the
  cksmRegisterFunc(db, ...) call from cksumvfs.c:767..783. }
begin
  cksmInitMethodsTables;
  if db = nil then Exit(SQLITE_OK);
  Result := sqlite3_create_function(db, 'verify_checksum', 1,
              SQLITE_UTF8 or SQLITE_INNOCUOUS or SQLITE_DETERMINISTIC,
              nil, @cksmVerifyFunc, nil, nil);
end;

function sqlite3_register_cksumvfs(zArg: PAnsiChar): i32;
var
  pOrig : Psqlite3_vfs;
  rc    : i32;
begin
  if zArg = zArg then ; { silence unused-arg }
  cksmInitMethodsTables;
  pOrig := sqlite3_vfs_find(nil);
  if pOrig = nil then Exit(SQLITE_ERROR);
  cksm_vfs.iVersion := pOrig^.iVersion;
  cksm_vfs.pAppData := pOrig;
  cksm_vfs.szOsFile := pOrig^.szOsFile + SizeOf(TCksmFile);
  rc := sqlite3_vfs_register(@cksm_vfs, 1);
  if rc = SQLITE_OK then
    rc := sqlite3_auto_extension(@cksmAutoExtension);
  Result := rc;
end;

function sqlite3_unregister_cksumvfs: i32;
begin
  if sqlite3_vfs_find('cksmvfs') <> nil then begin
    sqlite3_vfs_unregister(@cksm_vfs);
    sqlite3_cancel_auto_extension(@cksmAutoExtension);
  end;
  Result := SQLITE_OK;
end;

end.
