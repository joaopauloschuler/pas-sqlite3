{
  SPDX-License-Identifier: blessing

  9.4.divbug.88.069 — Faithful port of ../sqlite3/src/test_multiplex.c
  (1369 C lines).

  Multiplex VFS shim — splits a large database file across multiple smaller
  chunk files on disk (foo.db, foo.db001, foo.db002, ...).  All I/O is
  routed across chunks; locks and shared-memory pass through to the
  underlying VFS unchanged.

  Public entries:
    * sqlite3_multiplex_initialize(zOrigVfsName, makeDefault) — register
      the "multiplex" VFS shim layered on top of zOrigVfsName (or the
      current default if NULL).
    * sqlite3_multiplex_shutdown(eForce) — unregister.

  Pascal-port adaptations:
    * SQLITE_ENABLE_8_3_NAMES is not defined in upstream default builds,
      so the 8_3 journal/wal extension renumbering branches are dropped.
      MX_CHUNK_NUMBER / *_8_3_OFFSET constants retained for parity.
    * sqlite3_snprintf("%03d") is replaced by a small Pascal helper
      multiplexAppend03d that writes the zero-padded 3-digit decimal
      directly into the output buffer with a trailing double NUL —
      matching the upstream contract that the buffer is safe to pass
      to sqlite3_uri_parameter() and similar.
    * sqlite3_log diagnostics are dropped (the Pascal port's sqlite3_log
      is private to passqlite3pager); the rc is still surfaced.
    * extern sqlite3PendingByte → fixed 0x40000000 (upstream's
      SQLITE_OMIT_WSD fallback).
    * The auto-extension hook for multiplex_control() is installed via
      sqlite3_auto_extension, same convention as cksumvfs.
}
{$I passqlite3.inc}
unit passqlite3multiplex;

interface

uses
  ctypes,
  passqlite3types,
  passqlite3os,
  passqlite3util,
  passqlite3vdbe,
  passqlite3main;

{ Register the multiplex VFS shim.  Mirrors
  sqlite3_multiplex_initialize() in test_multiplex.c:1150..1200. }
function sqlite3_multiplex_initialize(zOrigVfsName: PAnsiChar;
                                      makeDefault: cint): cint;

{ Unregister the multiplex VFS shim.  Mirrors
  sqlite3_multiplex_shutdown() in test_multiplex.c:1211..1218. }
function sqlite3_multiplex_shutdown(eForce: cint): cint;

implementation

uses
  passqlite3printf;  { sqlite3PfMprintf }

{ ----------------------------------------------------------------------
  Constants — test_multiplex.c:67..101 and test_multiplex.h:46..48.
  ---------------------------------------------------------------------- }
const
  MAX_PAGE_SIZE         = $10000;
  DEFAULT_SECTOR_SIZE   = $1000;
  MX_CHUNK_NUMBER       = 299;
  SQLITE_MULTIPLEX_JOURNAL_8_3_OFFSET = 400;
  SQLITE_MULTIPLEX_WAL_8_3_OFFSET     = 700;
  SQLITE_MULTIPLEX_VFS_NAME           = 'multiplex';
  SQLITE_MULTIPLEX_CHUNK_SIZE         = 2147418112;

  MULTIPLEX_CTRL_ENABLE         = 214014;
  MULTIPLEX_CTRL_SET_CHUNK_SIZE = 214015;
  MULTIPLEX_CTRL_SET_MAX_CHUNKS = 214016;

{ ----------------------------------------------------------------------
  Object Definitions — test_multiplex.c:106..140.
  ---------------------------------------------------------------------- }
type
  PmultiplexReal = ^TmultiplexReal;
  TmultiplexReal = record
    p : Psqlite3_file;  { Handle for the chunk }
    z : PAnsiChar;      { Name of this chunk (from sqlite3_create_filename) }
  end;
  TmultiplexRealArray = array[0..(MaxInt div SizeOf(TmultiplexReal)) - 1]
                        of TmultiplexReal;
  PmultiplexRealArray = ^TmultiplexRealArray;

  PmultiplexGroup = ^TmultiplexGroup;
  TmultiplexGroup = record
    aReal     : PmultiplexRealArray;   { list of all chunks }
    nReal     : cint;                  { Number of chunks }
    zName     : PAnsiChar;             { Base filename of this group }
    nName     : cint;                  { Length of base filename }
    flags     : cint;                  { Flags used for original opening }
    szChunk   : cuint;                 { Chunk size used for this group }
    bEnabled  : Byte;                  { TRUE → use Multiplex VFS for file }
    bTruncate : Byte;                  { TRUE → enable truncation of databases }
  end;

  PmultiplexConn = ^TmultiplexConn;
  TmultiplexConn = record
    base   : sqlite3_file;     { Base class — MUST BE FIRST }
    pGroup : PmultiplexGroup;  { The underlying group of files }
  end;

{ ----------------------------------------------------------------------
  Global state — test_multiplex.c:147..176.
  ---------------------------------------------------------------------- }
var
  gMultiplex_pOrigVfs       : Psqlite3_vfs       = nil;
  gMultiplex_sThisVfs       : sqlite3_vfs;
  gMultiplex_sIoMethodsV1   : sqlite3_io_methods;
  gMultiplex_sIoMethodsV2   : sqlite3_io_methods;
  gMultiplex_isInitialized  : cint = 0;

{ ----------------------------------------------------------------------
  Forward declarations.
  ---------------------------------------------------------------------- }
function multiplexOpen(pVfs: Psqlite3_vfs; zName: sqlite3_filename;
                       pConn: Psqlite3_file; flags: cint;
                       pOutFlags: PcInt): cint; cdecl; forward;
function multiplexDelete(pVfs: Psqlite3_vfs; zName: PChar;
                         syncDir: cint): cint; cdecl; forward;
function multiplexAccess(a: Psqlite3_vfs; b: PChar; c: cint;
                         d: PcInt): cint; cdecl; forward;
function multiplexFullPathname(a: Psqlite3_vfs; b: PChar; c: cint;
                               d: PChar): cint; cdecl; forward;
function multiplexDlOpen(a: Psqlite3_vfs; b: PChar): Pointer; cdecl; forward;
procedure multiplexDlError(a: Psqlite3_vfs; b: cint; c: PChar); cdecl; forward;
function multiplexDlSym(a: Psqlite3_vfs; b: Pointer;
                        c: PChar): sqlite3_syscall_ptr; cdecl; forward;
procedure multiplexDlClose(a: Psqlite3_vfs; b: Pointer); cdecl; forward;
function multiplexRandomness(a: Psqlite3_vfs; b: cint;
                             c: PChar): cint; cdecl; forward;
function multiplexSleep(a: Psqlite3_vfs; b: cint): cint; cdecl; forward;
function multiplexCurrentTime(a: Psqlite3_vfs;
                              b: PDouble): cint; cdecl; forward;
function multiplexGetLastError(a: Psqlite3_vfs; b: cint;
                               c: PChar): cint; cdecl; forward;
function multiplexCurrentTimeInt64(a: Psqlite3_vfs;
                                   b: Pi64): cint; cdecl; forward;

function multiplexClose(pConn: Psqlite3_file): cint; cdecl; forward;
function multiplexRead(pConn: Psqlite3_file; pBuf: Pointer; iAmt: cint;
                       iOfst: i64): cint; cdecl; forward;
function multiplexWrite(pConn: Psqlite3_file; pBuf: Pointer; iAmt: cint;
                        iOfst: i64): cint; cdecl; forward;
function multiplexTruncate(pConn: Psqlite3_file; size: i64): cint;
                           cdecl; forward;
function multiplexSync(pConn: Psqlite3_file; flags: cint): cint;
                       cdecl; forward;
function multiplexFileSize(pConn: Psqlite3_file; pSize: Pi64): cint;
                           cdecl; forward;
function multiplexLock(pConn: Psqlite3_file; lock: cint): cint;
                       cdecl; forward;
function multiplexUnlock(pConn: Psqlite3_file; lock: cint): cint;
                         cdecl; forward;
function multiplexCheckReservedLock(pConn: Psqlite3_file;
                                    pResOut: PcInt): cint; cdecl; forward;
function multiplexFileControl(pConn: Psqlite3_file; op: cint;
                              pArg: Pointer): cint; cdecl; forward;
function multiplexSectorSize(pConn: Psqlite3_file): cint; cdecl; forward;
function multiplexDeviceCharacteristics(pConn: Psqlite3_file): cint;
                                        cdecl; forward;
function multiplexShmMap(pConn: Psqlite3_file; iRegion, szRegion,
                         bExtend: cint; pp: PPointer): cint;
                         cdecl; forward;
function multiplexShmLock(pConn: Psqlite3_file; ofst, n, flags: cint): cint;
                          cdecl; forward;
procedure multiplexShmBarrier(pConn: Psqlite3_file); cdecl; forward;
function multiplexShmUnmap(pConn: Psqlite3_file;
                           deleteFlag: cint): cint; cdecl; forward;

{ ----------------------------------------------------------------------
  Utility — multiplexStrlen30, test_multiplex.c:187..192.
  ---------------------------------------------------------------------- }
function multiplexStrlen30(z: PAnsiChar): cint;
var
  z2: PAnsiChar;
begin
  if z = nil then Exit(0);
  z2 := z;
  while z2^ <> #0 do Inc(z2);
  Result := $3fffffff and cint(PtrUInt(z2) - PtrUInt(z));
end;

{ Write the 3-digit zero-padded decimal value of n at zOut, NUL-terminate,
  and double-NUL-terminate (matches sqlite3_snprintf(4,...) usage in
  multiplexFilename — buffer is safe for sqlite3_uri_parameter). }
procedure multiplexAppend03d(zOut: PAnsiChar; n: cint);
begin
  zOut[0] := AnsiChar(Ord('0') + ((n div 100) mod 10));
  zOut[1] := AnsiChar(Ord('0') + ((n div 10) mod 10));
  zOut[2] := AnsiChar(Ord('0') + (n mod 10));
  zOut[3] := #0;
end;

{ multiplexFilename — test_multiplex.c:219..252.

  Generate the file-name for chunk iChunk into zOut (caller-allocated,
  at least nBase+5 bytes).  Buffer is terminated with two 0x00 bytes. }
procedure multiplexFilename(zBase: PAnsiChar; nBase, flags, iChunk: cint;
                            zOut: PAnsiChar);
var
  n: cint;
begin
  n := nBase;
  Move(zBase^, zOut^, n + 1);
  if (iChunk <> 0) and (iChunk <= MX_CHUNK_NUMBER) then begin
    { SQLITE_ENABLE_8_3_NAMES branch omitted — not defined upstream.  When
      that gate is enabled it folds journal/wal offsets into iChunk and
      truncates after the last '.' within the final 4 chars. }
    if flags = flags then ;  { silence unused-param warning }
    multiplexAppend03d(zOut + n, iChunk);
    n := n + 3;
  end;
  Assert(zOut[n] = #0);
  zOut[n + 1] := #0;
end;

{ multiplexSubFilename — test_multiplex.c:256..280.

  Compute (and lazily cache) the filename for chunk iChunk.  Grows
  pGroup->aReal if iChunk is past the current high-water mark. }
function multiplexSubFilename(pGroup: PmultiplexGroup; iChunk: cint): cint;
var
  newArr : Pointer;
  z      : PAnsiChar;
  n      : cint;
begin
  if iChunk >= pGroup^.nReal then begin
    newArr := sqlite3_realloc64(pGroup^.aReal,
                                u64((iChunk + 1) * SizeOf(TmultiplexReal)));
    if newArr = nil then Exit(SQLITE_NOMEM);
    FillChar(PmultiplexRealArray(newArr)^[pGroup^.nReal], SizeOf(TmultiplexReal)
              * (iChunk + 1 - pGroup^.nReal), 0);
    pGroup^.aReal := PmultiplexRealArray(newArr);
    pGroup^.nReal := iChunk + 1;
  end;
  if (pGroup^.zName <> nil) and (pGroup^.aReal^[iChunk].z = nil) then begin
    n := pGroup^.nName;
    z := PAnsiChar(sqlite3_malloc64(u64(n + 5)));
    if z = nil then Exit(SQLITE_NOMEM);
    multiplexFilename(pGroup^.zName, pGroup^.nName, pGroup^.flags, iChunk, z);
    pGroup^.aReal^[iChunk].z := PAnsiChar(sqlite3_create_filename(z, '', '', 0, nil));
    sqlite3_free(z);
    if pGroup^.aReal^[iChunk].z = nil then Exit(SQLITE_NOMEM);
  end;
  Result := SQLITE_OK;
end;

{ multiplexSubOpen — test_multiplex.c:289..350.

  Lazily open chunk iChunk via the underlying VFS and cache the handle
  in pGroup^.aReal[iChunk].p.  Returns nil on error (rc updated) or when
  the chunk does not exist on disk and createFlag is 0. }
function multiplexSubOpen(pGroup: PmultiplexGroup; iChunk: cint;
                          rc: PcInt; pOutFlags: PcInt;
                          createFlag: cint): Psqlite3_file;
var
  pSubOpen : Psqlite3_file;
  pOrigVfs : Psqlite3_vfs;
  flags    : cint;
  bExists  : cint;
begin
  pSubOpen := nil;
  pOrigVfs := gMultiplex_pOrigVfs;

  { SQLITE_ENABLE_8_3_NAMES branch (iChunk >= JOURNAL_8_3_OFFSET → SQLITE_FULL)
    omitted — gate not defined upstream. }

  rc^ := multiplexSubFilename(pGroup, iChunk);
  if rc^ = SQLITE_OK then begin
    pSubOpen := pGroup^.aReal^[iChunk].p;
    if pSubOpen = nil then begin
      flags := pGroup^.flags;
      if createFlag <> 0 then
        flags := flags or SQLITE_OPEN_CREATE
      else if iChunk = 0 then begin
        { Fall through — use pGroup^.flags as-is for chunk 0. }
      end else if pGroup^.aReal^[iChunk].z = nil then begin
        Exit(nil);
      end else begin
        bExists := 0;
        rc^ := pOrigVfs^.xAccess(pOrigVfs, pGroup^.aReal^[iChunk].z,
                                 SQLITE_ACCESS_EXISTS, @bExists);
        if (rc^ <> 0) or (bExists = 0) then begin
          Exit(nil);
        end;
        flags := flags and (not SQLITE_OPEN_CREATE);
      end;
      pSubOpen := Psqlite3_file(sqlite3_malloc64(u64(pOrigVfs^.szOsFile)));
      if pSubOpen = nil then begin
        rc^ := SQLITE_IOERR or (12 shl 8);  { SQLITE_IOERR_NOMEM = SQLITE_IOERR|(12<<8) }
        Exit(nil);
      end;
      pGroup^.aReal^[iChunk].p := pSubOpen;
      rc^ := pOrigVfs^.xOpen(pOrigVfs, pGroup^.aReal^[iChunk].z, pSubOpen,
                             flags, pOutFlags);
      if rc^ <> SQLITE_OK then begin
        sqlite3_free(pSubOpen);
        pGroup^.aReal^[iChunk].p := nil;
        Exit(nil);
      end;
    end;
  end;
  Result := pSubOpen;
end;

{ multiplexSubSize — test_multiplex.c:357..370. }
function multiplexSubSize(pGroup: PmultiplexGroup; iChunk: cint;
                          rc: PcInt): i64;
var
  pSub : Psqlite3_file;
  sz   : i64;
begin
  sz := 0;
  if rc^ <> 0 then Exit(0);
  pSub := multiplexSubOpen(pGroup, iChunk, rc, nil, 0);
  if pSub = nil then Exit(0);
  rc^ := pSub^.pMethods^.xFileSize(pSub, @sz);
  Result := sz;
end;

{ multiplexControlFunc — test_multiplex.c:375..411.
  multiplex_control(op, val) SQL function. }
procedure multiplexControlFunc(context: Psqlite3_context;
                               argc: cint; argv: PPMem); cdecl;
var
  rc   : cint;
  db   : PTsqlite3;
  op   : cint;
  iVal : cint;
begin
  rc := SQLITE_OK;
  db := sqlite3_context_db_handle(context);
  op := 0;
  iVal := 0;
  if (db = nil) or (argc <> 2) then
    rc := SQLITE_ERROR
  else begin
    op := sqlite3_value_int(argv[0]);
    iVal := sqlite3_value_int(argv[1]);
    case op of
      1: op := MULTIPLEX_CTRL_ENABLE;
      2: op := MULTIPLEX_CTRL_SET_CHUNK_SIZE;
      3: op := MULTIPLEX_CTRL_SET_MAX_CHUNKS;
    else
      rc := SQLITE_NOTFOUND;
    end;
  end;
  if rc = SQLITE_OK then
    rc := sqlite3_file_control(db, nil, op, @iVal);
  sqlite3_result_error_code(context, rc);
end;

{ multiplexFuncInit — test_multiplex.c:417..426.
  Auto-extension entry registering multiplex_control() on each new db. }
function multiplexFuncInit(db: PTsqlite3; pzErrMsg: PPAnsiChar;
                           pApi: Pointer): cint; cdecl;
begin
  if (pzErrMsg = pzErrMsg) and (pApi = pApi) then ; { silence unused }
  Result := sqlite3_create_function(db, 'multiplex_control', 2, SQLITE_ANY,
              nil, @multiplexControlFunc, nil, nil);
end;

{ multiplexSubClose — test_multiplex.c:431..446. }
procedure multiplexSubClose(pGroup: PmultiplexGroup; iChunk: cint;
                            pOrigVfs: Psqlite3_vfs);
var
  pSubOpen : Psqlite3_file;
begin
  pSubOpen := pGroup^.aReal^[iChunk].p;
  if pSubOpen <> nil then begin
    pSubOpen^.pMethods^.xClose(pSubOpen);
    if (pOrigVfs <> nil) and (pGroup^.aReal^[iChunk].z <> nil) then
      pOrigVfs^.xDelete(pOrigVfs, pGroup^.aReal^[iChunk].z, 0);
    sqlite3_free(pGroup^.aReal^[iChunk].p);
  end;
  sqlite3_free_filename(pGroup^.aReal^[iChunk].z);
  FillChar(pGroup^.aReal^[iChunk], SizeOf(TmultiplexReal), 0);
end;

{ multiplexFreeComponents — test_multiplex.c:451..457. }
procedure multiplexFreeComponents(pGroup: PmultiplexGroup);
var
  i: cint;
begin
  for i := 0 to pGroup^.nReal - 1 do
    multiplexSubClose(pGroup, i, nil);
  sqlite3_free(pGroup^.aReal);
  pGroup^.aReal := nil;
  pGroup^.nReal := 0;
end;

{ ************************ VFS Method Wrappers ************************** }

{ multiplexOpen — test_multiplex.c:469..605. }
function multiplexOpen(pVfs: Psqlite3_vfs; zName: sqlite3_filename;
                       pConn: Psqlite3_file; flags: cint;
                       pOutFlags: PcInt): cint; cdecl;
const
  PENDING_BYTE = $40000000;  { SQLITE_OMIT_WSD fallback for sqlite3PendingByte. }
var
  rc              : cint;
  pMultiplexOpen  : PmultiplexConn;
  pGroup          : PmultiplexGroup;
  pSubOpen        : Psqlite3_file;
  pOrigVfs        : Psqlite3_vfs;
  nName           : cint;
  sz              : cint;
  zUri            : PAnsiChar;
  p               : PAnsiChar;
  sz64            : i64;
  bExists         : cint;
  iChunk          : cint;
begin
  rc := SQLITE_OK;
  pSubOpen := nil;
  pOrigVfs := gMultiplex_pOrigVfs;
  nName := 0;
  sz := 0;

  if pVfs = pVfs then ; { silence }
  FillChar(pConn^, pVfs^.szOsFile, 0);
  Assert((zName <> nil) or ((flags and SQLITE_OPEN_DELETEONCLOSE) <> 0));

  pMultiplexOpen := PmultiplexConn(pConn);

  if rc = SQLITE_OK then begin
    if zName <> nil then
      nName := multiplexStrlen30(zName)
    else
      nName := 0;
    sz := SizeOf(TmultiplexGroup) + nName + 1;
    pGroup := PmultiplexGroup(sqlite3_malloc64(u64(sz)));
    if pGroup = nil then rc := SQLITE_NOMEM;
  end;

  if rc = SQLITE_OK then begin
    if (flags and SQLITE_OPEN_URI) <> 0 then zUri := zName else zUri := nil;
    FillChar(pGroup^, sz, 0);
    pMultiplexOpen^.pGroup := pGroup;
    pGroup^.bEnabled := Byte(-1);
    if (flags and SQLITE_OPEN_MAIN_DB) = 0 then
      pGroup^.bTruncate := Byte(sqlite3_uri_boolean(zUri, 'truncate', 1))
    else
      pGroup^.bTruncate := Byte(sqlite3_uri_boolean(zUri, 'truncate', 0));
    pGroup^.szChunk := cuint(sqlite3_uri_int64(zUri, 'chunksize',
                                               SQLITE_MULTIPLEX_CHUNK_SIZE));
    pGroup^.szChunk := (pGroup^.szChunk + $ffff) and not cuint($ffff);
    if zName <> nil then begin
      p := PAnsiChar(pGroup) + SizeOf(TmultiplexGroup);
      pGroup^.zName := p;
      Move(zName^, pGroup^.zName^, nName + 1);
      pGroup^.nName := nName;
    end;
    if pGroup^.bEnabled <> 0 then begin
      { Ensure the pending byte does not fall at the end of a chunk. }
      while (PENDING_BYTE mod pGroup^.szChunk) >= (pGroup^.szChunk - 65536) do
        pGroup^.szChunk := pGroup^.szChunk + 65536;
    end;
    pGroup^.flags := flags and (not SQLITE_OPEN_URI);
    rc := multiplexSubFilename(pGroup, 1);
    if rc = SQLITE_OK then begin
      pSubOpen := multiplexSubOpen(pGroup, 0, @rc, pOutFlags, 0);
      if (pSubOpen = nil) and (rc = SQLITE_OK) then rc := SQLITE_CANTOPEN;
    end;
    if rc = SQLITE_OK then begin
      rc := pSubOpen^.pMethods^.xFileSize(pSubOpen, @sz64);
      if (rc = SQLITE_OK) and (zName <> nil) then begin
        if (flags and SQLITE_OPEN_SUPER_JOURNAL) <> 0 then
          pGroup^.bEnabled := 0
        else if sz64 = 0 then begin
          if (flags and SQLITE_OPEN_MAIN_JOURNAL) <> 0 then begin
            { Main journal whose first chunk is zero bytes → drop any
              cached subsequent chunks from disk. }
            iChunk := 1;
            bExists := 0;
            repeat
              rc := pOrigVfs^.xAccess(pOrigVfs,
                  pGroup^.aReal^[iChunk].z, SQLITE_ACCESS_EXISTS, @bExists);
              if (rc = SQLITE_OK) and (bExists <> 0) then begin
                rc := pOrigVfs^.xDelete(pOrigVfs,
                                        pGroup^.aReal^[iChunk].z, 0);
                if rc = SQLITE_OK then begin
                  Inc(iChunk);
                  rc := multiplexSubFilename(pGroup, iChunk);
                end;
              end;
            until not ((rc = SQLITE_OK) and (bExists <> 0));
          end;
        end else begin
          { Either fix szChunk from the existing layout, or disable the
            multiplexor if first overflow is missing but chunk 0 is big. }
          rc := pOrigVfs^.xAccess(pOrigVfs, pGroup^.aReal^[1].z,
                                  SQLITE_ACCESS_EXISTS, @bExists);
          bExists := Ord(multiplexSubSize(pGroup, 1, @rc) > 0);
          if (rc = SQLITE_OK) and (bExists <> 0)
             and (sz64 = (sz64 and i64($ffffffffffff0000)))
             and (sz64 > 0) and (sz64 <> pGroup^.szChunk) then
            pGroup^.szChunk := cuint(sz64)
          else if (rc = SQLITE_OK) and (bExists = 0)
                  and (sz64 > pGroup^.szChunk) then
            pGroup^.bEnabled := 0;
        end;
      end;
    end;

    if rc = SQLITE_OK then begin
      if pSubOpen^.pMethods^.iVersion = 1 then
        pConn^.pMethods := @gMultiplex_sIoMethodsV1
      else
        pConn^.pMethods := @gMultiplex_sIoMethodsV2;
    end else begin
      multiplexFreeComponents(pGroup);
      sqlite3_free(pGroup);
    end;
  end;
  Result := rc;
end;

{ multiplexDelete — test_multiplex.c:611..654. }
function multiplexDelete(pVfs: Psqlite3_vfs; zName: PChar;
                         syncDir: cint): cint; cdecl;
var
  rc       : cint;
  pOrigVfs : Psqlite3_vfs;
  nName    : cint;
  z        : PAnsiChar;
  iChunk   : cint;
  bExists  : cint;
begin
  if pVfs = pVfs then ; { silence }
  pOrigVfs := gMultiplex_pOrigVfs;
  rc := pOrigVfs^.xDelete(pOrigVfs, zName, syncDir);
  if rc = SQLITE_OK then begin
    nName := cint(StrLen(zName));
    z := PAnsiChar(sqlite3_malloc64(u64(nName + 5)));
    if z = nil then
      rc := SQLITE_IOERR or (12 shl 8)  { SQLITE_IOERR_NOMEM }
    else begin
      iChunk := 0;
      bExists := 0;
      repeat
        Inc(iChunk);
        multiplexFilename(zName, nName, SQLITE_OPEN_MAIN_JOURNAL, iChunk, z);
        rc := pOrigVfs^.xAccess(pOrigVfs, z, SQLITE_ACCESS_EXISTS, @bExists);
      until not ((rc = SQLITE_OK) and (bExists <> 0));
      while (rc = SQLITE_OK) and (iChunk > 1) do begin
        Dec(iChunk);
        multiplexFilename(zName, nName, SQLITE_OPEN_MAIN_JOURNAL, iChunk, z);
        rc := pOrigVfs^.xDelete(pOrigVfs, z, syncDir);
      end;
      if rc = SQLITE_OK then begin
        iChunk := 0;
        bExists := 0;
        repeat
          Inc(iChunk);
          multiplexFilename(zName, nName, SQLITE_OPEN_WAL, iChunk, z);
          rc := pOrigVfs^.xAccess(pOrigVfs, z, SQLITE_ACCESS_EXISTS, @bExists);
        until not ((rc = SQLITE_OK) and (bExists <> 0));
        while (rc = SQLITE_OK) and (iChunk > 1) do begin
          Dec(iChunk);
          multiplexFilename(zName, nName, SQLITE_OPEN_WAL, iChunk, z);
          rc := pOrigVfs^.xDelete(pOrigVfs, z, syncDir);
        end;
      end;
    end;
    sqlite3_free(z);
  end;
  Result := rc;
end;

{ Pass-through VFS methods — test_multiplex.c:656..692. }

function multiplexAccess(a: Psqlite3_vfs; b: PChar; c: cint; d: PcInt): cint; cdecl;
begin
  if a = a then ;
  Result := gMultiplex_pOrigVfs^.xAccess(gMultiplex_pOrigVfs, b, c, d);
end;

function multiplexFullPathname(a: Psqlite3_vfs; b: PChar; c: cint;
                               d: PChar): cint; cdecl;
begin
  if a = a then ;
  Result := gMultiplex_pOrigVfs^.xFullPathname(gMultiplex_pOrigVfs, b, c, d);
end;

function multiplexDlOpen(a: Psqlite3_vfs; b: PChar): Pointer; cdecl;
begin
  if a = a then ;
  Result := gMultiplex_pOrigVfs^.xDlOpen(gMultiplex_pOrigVfs, b);
end;

procedure multiplexDlError(a: Psqlite3_vfs; b: cint; c: PChar); cdecl;
begin
  if a = a then ;
  gMultiplex_pOrigVfs^.xDlError(gMultiplex_pOrigVfs, b, c);
end;

function multiplexDlSym(a: Psqlite3_vfs; b: Pointer;
                        c: PChar): sqlite3_syscall_ptr; cdecl;
begin
  if a = a then ;
  Result := gMultiplex_pOrigVfs^.xDlSym(gMultiplex_pOrigVfs, b, c);
end;

procedure multiplexDlClose(a: Psqlite3_vfs; b: Pointer); cdecl;
begin
  if a = a then ;
  gMultiplex_pOrigVfs^.xDlClose(gMultiplex_pOrigVfs, b);
end;

function multiplexRandomness(a: Psqlite3_vfs; b: cint; c: PChar): cint; cdecl;
begin
  if a = a then ;
  Result := gMultiplex_pOrigVfs^.xRandomness(gMultiplex_pOrigVfs, b, c);
end;

function multiplexSleep(a: Psqlite3_vfs; b: cint): cint; cdecl;
begin
  if a = a then ;
  Result := gMultiplex_pOrigVfs^.xSleep(gMultiplex_pOrigVfs, b);
end;

function multiplexCurrentTime(a: Psqlite3_vfs; b: PDouble): cint; cdecl;
begin
  if a = a then ;
  Result := gMultiplex_pOrigVfs^.xCurrentTime(gMultiplex_pOrigVfs, b);
end;

function multiplexGetLastError(a: Psqlite3_vfs; b: cint;
                               c: PChar): cint; cdecl;
begin
  if a = a then ;
  if Pointer(gMultiplex_pOrigVfs^.xGetLastError) <> nil then
    Result := gMultiplex_pOrigVfs^.xGetLastError(gMultiplex_pOrigVfs, b, c)
  else
    Result := 0;
end;

function multiplexCurrentTimeInt64(a: Psqlite3_vfs; b: Pi64): cint; cdecl;
begin
  if a = a then ;
  Result := gMultiplex_pOrigVfs^.xCurrentTimeInt64(gMultiplex_pOrigVfs, b);
end;

{ ************************ I/O Method Wrappers ************************** }

{ multiplexClose — test_multiplex.c:701..708. }
function multiplexClose(pConn: Psqlite3_file): cint; cdecl;
var
  p      : PmultiplexConn;
  pGroup : PmultiplexGroup;
begin
  p := PmultiplexConn(pConn);
  pGroup := p^.pGroup;
  multiplexFreeComponents(pGroup);
  sqlite3_free(pGroup);
  Result := SQLITE_OK;
end;

{ multiplexRead — test_multiplex.c:714..753. }
function multiplexRead(pConn: Psqlite3_file; pBuf: Pointer; iAmt: cint;
                       iOfst: i64): cint; cdecl;
var
  p        : PmultiplexConn;
  pGroup   : PmultiplexGroup;
  rc       : cint;
  pSubOpen : Psqlite3_file;
  i        : cint;
  extra    : cint;
begin
  p := PmultiplexConn(pConn);
  pGroup := p^.pGroup;
  rc := SQLITE_OK;
  if pGroup^.bEnabled = 0 then begin
    pSubOpen := multiplexSubOpen(pGroup, 0, @rc, nil, 0);
    if pSubOpen = nil then
      rc := SQLITE_IOERR or (1 shl 8)  { SQLITE_IOERR_READ }
    else
      rc := pSubOpen^.pMethods^.xRead(pSubOpen, pBuf, iAmt, iOfst);
  end else begin
    while iAmt > 0 do begin
      i := cint(iOfst div pGroup^.szChunk);
      pSubOpen := multiplexSubOpen(pGroup, i, @rc, nil, 1);
      if pSubOpen <> nil then begin
        extra := (cint(iOfst mod pGroup^.szChunk) + iAmt) - cint(pGroup^.szChunk);
        if extra < 0 then extra := 0;
        iAmt := iAmt - extra;
        rc := pSubOpen^.pMethods^.xRead(pSubOpen, pBuf, iAmt,
                                        iOfst mod pGroup^.szChunk);
        if rc <> SQLITE_OK then Break;
        pBuf := Pointer(PAnsiChar(pBuf) + iAmt);
        iOfst := iOfst + iAmt;
        iAmt := extra;
      end else begin
        rc := SQLITE_IOERR or (1 shl 8);
        Break;
      end;
    end;
  end;
  Result := rc;
end;

{ multiplexWrite — test_multiplex.c:759..793. }
function multiplexWrite(pConn: Psqlite3_file; pBuf: Pointer; iAmt: cint;
                        iOfst: i64): cint; cdecl;
var
  p        : PmultiplexConn;
  pGroup   : PmultiplexGroup;
  rc       : cint;
  pSubOpen : Psqlite3_file;
  i        : cint;
  extra    : cint;
begin
  p := PmultiplexConn(pConn);
  pGroup := p^.pGroup;
  rc := SQLITE_OK;
  if pGroup^.bEnabled = 0 then begin
    pSubOpen := multiplexSubOpen(pGroup, 0, @rc, nil, 0);
    if pSubOpen = nil then
      rc := SQLITE_IOERR or (3 shl 8)  { SQLITE_IOERR_WRITE }
    else
      rc := pSubOpen^.pMethods^.xWrite(pSubOpen, pBuf, iAmt, iOfst);
  end else begin
    while (rc = SQLITE_OK) and (iAmt > 0) do begin
      i := cint(iOfst div pGroup^.szChunk);
      pSubOpen := multiplexSubOpen(pGroup, i, @rc, nil, 1);
      if pSubOpen <> nil then begin
        extra := (cint(iOfst mod pGroup^.szChunk) + iAmt) - cint(pGroup^.szChunk);
        if extra < 0 then extra := 0;
        iAmt := iAmt - extra;
        rc := pSubOpen^.pMethods^.xWrite(pSubOpen, pBuf, iAmt,
                                         iOfst mod pGroup^.szChunk);
        pBuf := Pointer(PAnsiChar(pBuf) + iAmt);
        iOfst := iOfst + iAmt;
        iAmt := extra;
      end;
    end;
  end;
  Result := rc;
end;

{ multiplexTruncate — test_multiplex.c:799..835. }
function multiplexTruncate(pConn: Psqlite3_file; size: i64): cint; cdecl;
var
  p          : PmultiplexConn;
  pGroup     : PmultiplexGroup;
  rc         : cint;
  pSubOpen   : Psqlite3_file;
  pOrigVfs   : Psqlite3_vfs;
  i          : cint;
  iBaseGroup : cint;
begin
  p := PmultiplexConn(pConn);
  pGroup := p^.pGroup;
  rc := SQLITE_OK;
  if pGroup^.bEnabled = 0 then begin
    pSubOpen := multiplexSubOpen(pGroup, 0, @rc, nil, 0);
    if pSubOpen = nil then
      rc := SQLITE_IOERR or (6 shl 8)  { SQLITE_IOERR_TRUNCATE }
    else
      rc := pSubOpen^.pMethods^.xTruncate(pSubOpen, size);
  end else begin
    iBaseGroup := cint(size div pGroup^.szChunk);
    pOrigVfs := gMultiplex_pOrigVfs;
    i := pGroup^.nReal - 1;
    while (i > iBaseGroup) and (rc = SQLITE_OK) do begin
      if pGroup^.bTruncate <> 0 then
        multiplexSubClose(pGroup, i, pOrigVfs)
      else begin
        pSubOpen := multiplexSubOpen(pGroup, i, @rc, nil, 0);
        if pSubOpen <> nil then
          rc := pSubOpen^.pMethods^.xTruncate(pSubOpen, 0);
      end;
      Dec(i);
    end;
    if rc = SQLITE_OK then begin
      pSubOpen := multiplexSubOpen(pGroup, iBaseGroup, @rc, nil, 0);
      if pSubOpen <> nil then
        rc := pSubOpen^.pMethods^.xTruncate(pSubOpen, size mod pGroup^.szChunk);
    end;
    if rc <> 0 then rc := SQLITE_IOERR or (6 shl 8);
  end;
  Result := rc;
end;

{ multiplexSync — test_multiplex.c:839..852. }
function multiplexSync(pConn: Psqlite3_file; flags: cint): cint; cdecl;
var
  p        : PmultiplexConn;
  pGroup   : PmultiplexGroup;
  rc, rc2  : cint;
  i        : cint;
  pSubOpen : Psqlite3_file;
begin
  p := PmultiplexConn(pConn);
  pGroup := p^.pGroup;
  rc := SQLITE_OK;
  for i := 0 to pGroup^.nReal - 1 do begin
    pSubOpen := pGroup^.aReal^[i].p;
    if pSubOpen <> nil then begin
      rc2 := pSubOpen^.pMethods^.xSync(pSubOpen, flags);
      if rc2 <> SQLITE_OK then rc := rc2;
    end;
  end;
  Result := rc;
end;

{ multiplexFileSize — test_multiplex.c:857..878. }
function multiplexFileSize(pConn: Psqlite3_file; pSize: Pi64): cint; cdecl;
var
  p        : PmultiplexConn;
  pGroup   : PmultiplexGroup;
  rc       : cint;
  i        : cint;
  sz       : i64;
  pSubOpen : Psqlite3_file;
begin
  p := PmultiplexConn(pConn);
  pGroup := p^.pGroup;
  rc := SQLITE_OK;
  if pGroup^.bEnabled = 0 then begin
    pSubOpen := multiplexSubOpen(pGroup, 0, @rc, nil, 0);
    if pSubOpen = nil then
      rc := SQLITE_IOERR or (7 shl 8)  { SQLITE_IOERR_FSTAT }
    else
      rc := pSubOpen^.pMethods^.xFileSize(pSubOpen, pSize);
  end else begin
    pSize^ := 0;
    i := 0;
    while rc = SQLITE_OK do begin
      sz := multiplexSubSize(pGroup, i, @rc);
      if sz = 0 then Break;
      pSize^ := i * i64(pGroup^.szChunk) + sz;
      Inc(i);
    end;
  end;
  Result := rc;
end;

{ multiplexLock — test_multiplex.c:882..890. }
function multiplexLock(pConn: Psqlite3_file; lock: cint): cint; cdecl;
var
  p        : PmultiplexConn;
  rc       : cint;
  pSubOpen : Psqlite3_file;
begin
  p := PmultiplexConn(pConn);
  pSubOpen := multiplexSubOpen(p^.pGroup, 0, @rc, nil, 0);
  if pSubOpen <> nil then
    Exit(pSubOpen^.pMethods^.xLock(pSubOpen, lock));
  Result := SQLITE_BUSY;
end;

{ multiplexUnlock — test_multiplex.c:894..902. }
function multiplexUnlock(pConn: Psqlite3_file; lock: cint): cint; cdecl;
var
  p        : PmultiplexConn;
  rc       : cint;
  pSubOpen : Psqlite3_file;
begin
  p := PmultiplexConn(pConn);
  pSubOpen := multiplexSubOpen(p^.pGroup, 0, @rc, nil, 0);
  if pSubOpen <> nil then
    Exit(pSubOpen^.pMethods^.xUnlock(pSubOpen, lock));
  Result := SQLITE_IOERR or (8 shl 8);  { SQLITE_IOERR_UNLOCK }
end;

{ multiplexCheckReservedLock — test_multiplex.c:906..914. }
function multiplexCheckReservedLock(pConn: Psqlite3_file;
                                    pResOut: PcInt): cint; cdecl;
var
  p        : PmultiplexConn;
  rc       : cint;
  pSubOpen : Psqlite3_file;
begin
  p := PmultiplexConn(pConn);
  pSubOpen := multiplexSubOpen(p^.pGroup, 0, @rc, nil, 0);
  if pSubOpen <> nil then
    Exit(pSubOpen^.pMethods^.xCheckReservedLock(pSubOpen, pResOut));
  Result := SQLITE_IOERR or (14 shl 8);  { SQLITE_IOERR_CHECKRESERVEDLOCK }
end;

{ multiplexFileControl — test_multiplex.c:919..1053. }
function multiplexFileControl(pConn: Psqlite3_file; op: cint;
                              pArg: Pointer): cint; cdecl;
var
  p        : PmultiplexConn;
  pGroup   : PmultiplexGroup;
  rc       : cint;
  pSubOpen : Psqlite3_file;
  aFcntl   : PPAnsiChar;
  sz       : i64;
  n, ii    : cint;
  zOld     : PAnsiChar;
  ppRet    : PPAnsiChar;

  function az(i: cint): PAnsiChar; inline;
  begin
    Result := PPointerArray(aFcntl)^[i];
  end;

  procedure setAz0(z: PAnsiChar); inline;
  begin
    PPointerArray(aFcntl)^[0] := z;
  end;

label
  PassThru;
begin
  p := PmultiplexConn(pConn);
  pGroup := p^.pGroup;
  rc := SQLITE_ERROR;

  if gMultiplex_isInitialized = 0 then Exit(SQLITE_MISUSE);

  case op of
    MULTIPLEX_CTRL_ENABLE:
      begin
        if pArg <> nil then begin
          pGroup^.bEnabled := Byte(PcInt(pArg)^);
          rc := SQLITE_OK;
        end;
      end;
    MULTIPLEX_CTRL_SET_CHUNK_SIZE:
      begin
        if pArg <> nil then begin
          if Pcuint(pArg)^ < 1 then
            rc := SQLITE_MISUSE
          else begin
            { Round up to nearest multiple of MAX_PAGE_SIZE. }
            pGroup^.szChunk := (Pcuint(pArg)^ + (MAX_PAGE_SIZE - 1))
                               and not cuint(MAX_PAGE_SIZE - 1);
            rc := SQLITE_OK;
          end;
        end;
      end;
    MULTIPLEX_CTRL_SET_MAX_CHUNKS:
      rc := SQLITE_OK;
    SQLITE_FCNTL_SIZE_HINT, SQLITE_FCNTL_CHUNK_SIZE:
      rc := SQLITE_OK;
    SQLITE_FCNTL_PRAGMA:
      begin
        aFcntl := PPAnsiChar(pArg);
        if (az(1) <> nil)
           and (sqlite3_strnicmp(az(1), 'multiplex_', 10) = 0) then begin
          sz := 0;
          multiplexFileSize(pConn, @sz);
          if sqlite3_stricmp(az(1), 'multiplex_truncate') = 0 then begin
            if (az(2) <> nil) and (az(2)[0] <> #0) then begin
              if (sqlite3_stricmp(az(2), 'on') = 0)
                 or (sqlite3_stricmp(az(2), '1') = 0) then
                pGroup^.bTruncate := 1
              else if (sqlite3_stricmp(az(2), 'off') = 0)
                      or (sqlite3_stricmp(az(2), '0') = 0) then
                pGroup^.bTruncate := 0;
            end;
            if pGroup^.bTruncate <> 0 then
              setAz0(sqlite3PfMprintf('on', []))
            else
              setAz0(sqlite3PfMprintf('off', []));
            Exit(SQLITE_OK);
          end;
          if sqlite3_stricmp(az(1), 'multiplex_enabled') = 0 then begin
            if pGroup^.bEnabled <> 0 then
              setAz0(sqlite3PfMprintf('%d', [1]))
            else
              setAz0(sqlite3PfMprintf('%d', [0]));
            Exit(SQLITE_OK);
          end;
          if (sqlite3_stricmp(az(1), 'multiplex_chunksize') = 0)
             and (pGroup^.bEnabled <> 0) then begin
            setAz0(sqlite3PfMprintf('%u', [PtrUInt(pGroup^.szChunk)]));
            Exit(SQLITE_OK);
          end;
          if sqlite3_stricmp(az(1), 'multiplex_filecount') = 0 then begin
            n := 0;
            for ii := 0 to pGroup^.nReal - 1 do
              if pGroup^.aReal^[ii].p <> nil then Inc(n);
            setAz0(sqlite3PfMprintf('%d', [n]));
            Exit(SQLITE_OK);
          end;
        end;
        goto PassThru;  { Fall through into default. }
      end;
  else
PassThru:
    pSubOpen := multiplexSubOpen(pGroup, 0, @rc, nil, 0);
    if pSubOpen <> nil then begin
      rc := pSubOpen^.pMethods^.xFileControl(pSubOpen, op, pArg);
      if (op = SQLITE_FCNTL_VFSNAME) and (rc = SQLITE_OK) then begin
        ppRet := PPAnsiChar(pArg);
        zOld := ppRet^;
        ppRet^ := sqlite3PfMprintf('multiplex/%s', [zOld]);
        if zOld <> nil then sqlite3_free(zOld);
      end;
    end;
  end;
  Result := rc;
end;

{ multiplexSectorSize — test_multiplex.c:1057..1065. }
function multiplexSectorSize(pConn: Psqlite3_file): cint; cdecl;
var
  p        : PmultiplexConn;
  rc       : cint;
  pSubOpen : Psqlite3_file;
begin
  p := PmultiplexConn(pConn);
  pSubOpen := multiplexSubOpen(p^.pGroup, 0, @rc, nil, 0);
  if (pSubOpen <> nil) and (Pointer(pSubOpen^.pMethods^.xSectorSize) <> nil) then
    Exit(pSubOpen^.pMethods^.xSectorSize(pSubOpen));
  Result := DEFAULT_SECTOR_SIZE;
end;

{ multiplexDeviceCharacteristics — test_multiplex.c:1069..1077. }
function multiplexDeviceCharacteristics(pConn: Psqlite3_file): cint; cdecl;
var
  p        : PmultiplexConn;
  rc       : cint;
  pSubOpen : Psqlite3_file;
begin
  p := PmultiplexConn(pConn);
  pSubOpen := multiplexSubOpen(p^.pGroup, 0, @rc, nil, 0);
  if pSubOpen <> nil then
    Exit(pSubOpen^.pMethods^.xDeviceCharacteristics(pSubOpen));
  Result := 0;
end;

{ multiplexShmMap — test_multiplex.c:1081..1095. }
function multiplexShmMap(pConn: Psqlite3_file; iRegion, szRegion,
                         bExtend: cint; pp: PPointer): cint; cdecl;
var
  p        : PmultiplexConn;
  rc       : cint;
  pSubOpen : Psqlite3_file;
begin
  p := PmultiplexConn(pConn);
  pSubOpen := multiplexSubOpen(p^.pGroup, 0, @rc, nil, 0);
  if pSubOpen <> nil then
    Exit(pSubOpen^.pMethods^.xShmMap(pSubOpen, iRegion, szRegion, bExtend, pp));
  Result := SQLITE_IOERR;
end;

{ multiplexShmLock — test_multiplex.c:1099..1112. }
function multiplexShmLock(pConn: Psqlite3_file; ofst, n, flags: cint): cint; cdecl;
var
  p        : PmultiplexConn;
  rc       : cint;
  pSubOpen : Psqlite3_file;
begin
  p := PmultiplexConn(pConn);
  pSubOpen := multiplexSubOpen(p^.pGroup, 0, @rc, nil, 0);
  if pSubOpen <> nil then
    Exit(pSubOpen^.pMethods^.xShmLock(pSubOpen, ofst, n, flags));
  Result := SQLITE_BUSY;
end;

{ multiplexShmBarrier — test_multiplex.c:1116..1123. }
procedure multiplexShmBarrier(pConn: Psqlite3_file); cdecl;
var
  p        : PmultiplexConn;
  rc       : cint;
  pSubOpen : Psqlite3_file;
begin
  p := PmultiplexConn(pConn);
  pSubOpen := multiplexSubOpen(p^.pGroup, 0, @rc, nil, 0);
  if pSubOpen <> nil then
    pSubOpen^.pMethods^.xShmBarrier(pSubOpen);
end;

{ multiplexShmUnmap — test_multiplex.c:1127..1135. }
function multiplexShmUnmap(pConn: Psqlite3_file; deleteFlag: cint): cint; cdecl;
var
  p        : PmultiplexConn;
  rc       : cint;
  pSubOpen : Psqlite3_file;
begin
  p := PmultiplexConn(pConn);
  pSubOpen := multiplexSubOpen(p^.pGroup, 0, @rc, nil, 0);
  if pSubOpen <> nil then
    Exit(pSubOpen^.pMethods^.xShmUnmap(pSubOpen, deleteFlag));
  Result := SQLITE_OK;
end;

{ ************************** Public Interfaces *************************** }

{ sqlite3_multiplex_initialize — test_multiplex.c:1150..1200. }
function sqlite3_multiplex_initialize(zOrigVfsName: PAnsiChar;
                                      makeDefault: cint): cint;
var
  pOrigVfs: Psqlite3_vfs;
begin
  if gMultiplex_isInitialized <> 0 then Exit(SQLITE_MISUSE);
  { Mirror cksumvfs: ensure SQLite is initialised so the VFS chain is
    populated before we look up the parent. }
  sqlite3_initialize;
  pOrigVfs := sqlite3_vfs_find(zOrigVfsName);
  if pOrigVfs = nil then Exit(SQLITE_ERROR);
  Assert(pOrigVfs <> @gMultiplex_sThisVfs);
  gMultiplex_isInitialized := 1;
  gMultiplex_pOrigVfs := pOrigVfs;
  gMultiplex_sThisVfs := pOrigVfs^;
  gMultiplex_sThisVfs.szOsFile := gMultiplex_sThisVfs.szOsFile
                                  + SizeOf(TmultiplexConn);
  gMultiplex_sThisVfs.zName := SQLITE_MULTIPLEX_VFS_NAME;
  gMultiplex_sThisVfs.xOpen := @multiplexOpen;
  gMultiplex_sThisVfs.xDelete := @multiplexDelete;
  gMultiplex_sThisVfs.xAccess := @multiplexAccess;
  gMultiplex_sThisVfs.xFullPathname := @multiplexFullPathname;
  gMultiplex_sThisVfs.xDlOpen := @multiplexDlOpen;
  gMultiplex_sThisVfs.xDlError := @multiplexDlError;
  gMultiplex_sThisVfs.xDlSym := @multiplexDlSym;
  gMultiplex_sThisVfs.xDlClose := @multiplexDlClose;
  gMultiplex_sThisVfs.xRandomness := @multiplexRandomness;
  gMultiplex_sThisVfs.xSleep := @multiplexSleep;
  gMultiplex_sThisVfs.xCurrentTime := @multiplexCurrentTime;
  gMultiplex_sThisVfs.xGetLastError := @multiplexGetLastError;
  gMultiplex_sThisVfs.xCurrentTimeInt64 := @multiplexCurrentTimeInt64;

  FillChar(gMultiplex_sIoMethodsV1, SizeOf(sqlite3_io_methods), 0);
  gMultiplex_sIoMethodsV1.iVersion := 1;
  gMultiplex_sIoMethodsV1.xClose := @multiplexClose;
  gMultiplex_sIoMethodsV1.xRead := @multiplexRead;
  gMultiplex_sIoMethodsV1.xWrite := @multiplexWrite;
  gMultiplex_sIoMethodsV1.xTruncate := @multiplexTruncate;
  gMultiplex_sIoMethodsV1.xSync := @multiplexSync;
  gMultiplex_sIoMethodsV1.xFileSize := @multiplexFileSize;
  gMultiplex_sIoMethodsV1.xLock := @multiplexLock;
  gMultiplex_sIoMethodsV1.xUnlock := @multiplexUnlock;
  gMultiplex_sIoMethodsV1.xCheckReservedLock := @multiplexCheckReservedLock;
  gMultiplex_sIoMethodsV1.xFileControl := @multiplexFileControl;
  gMultiplex_sIoMethodsV1.xSectorSize := @multiplexSectorSize;
  gMultiplex_sIoMethodsV1.xDeviceCharacteristics := @multiplexDeviceCharacteristics;
  gMultiplex_sIoMethodsV2 := gMultiplex_sIoMethodsV1;
  gMultiplex_sIoMethodsV2.iVersion := 2;
  gMultiplex_sIoMethodsV2.xShmMap := @multiplexShmMap;
  gMultiplex_sIoMethodsV2.xShmLock := @multiplexShmLock;
  gMultiplex_sIoMethodsV2.xShmBarrier := @multiplexShmBarrier;
  gMultiplex_sIoMethodsV2.xShmUnmap := @multiplexShmUnmap;
  sqlite3_vfs_register(@gMultiplex_sThisVfs, makeDefault);
  sqlite3_auto_extension(Tsqlite3_loadext_fn(Pointer(@multiplexFuncInit)));
  Result := SQLITE_OK;
end;

{ sqlite3_multiplex_shutdown — test_multiplex.c:1211..1218. }
function sqlite3_multiplex_shutdown(eForce: cint): cint;
begin
  if eForce = eForce then ; { silence }
  if gMultiplex_isInitialized = 0 then Exit(SQLITE_MISUSE);
  gMultiplex_isInitialized := 0;
  sqlite3_vfs_unregister(@gMultiplex_sThisVfs);
  FillChar(gMultiplex_sThisVfs, SizeOf(gMultiplex_sThisVfs), 0);
  FillChar(gMultiplex_sIoMethodsV1, SizeOf(gMultiplex_sIoMethodsV1), 0);
  FillChar(gMultiplex_sIoMethodsV2, SizeOf(gMultiplex_sIoMethodsV2), 0);
  gMultiplex_pOrigVfs := nil;
  Result := SQLITE_OK;
end;

end.
