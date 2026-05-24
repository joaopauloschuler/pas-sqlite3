{
  SPDX-License-Identifier: blessing

  Faithful port of ../sqlite3/ext/misc/tmstmpvfs.c (1042 lines in C).

  A VFS shim ("tmstmpvfs") that writes a 16-byte timestamp tag into the
  reserve area of every database page and (optionally) emits a binary
  log of WAL/DB events when a sibling directory "<dbname>-tmstmp/" exists
  next to the database file.

  Public entry: sqlite3_register_tmstmpvfs(zArg: PAnsiChar) — same surface
  as the C source's SQLITE_TMSTMPVFS_STATIC variant.  Once registered the
  layered VFS becomes the new default VFS.
}
{$I passqlite3.inc}
unit passqlite3tmstmpvfs;

interface

uses
  ctypes,
  passqlite3types,
  passqlite3os,
  passqlite3util,
  passqlite3main;

{ Returns SQLITE_OK on success.  The argument is currently unused but
  retained so the signature matches upstream. }
function sqlite3_register_tmstmpvfs(NotUsed: PAnsiChar): i32;
function sqlite3_unregister_tmstmpvfs: i32;

implementation

uses
  passqlite3printf,
  passqlite3pager;   { sqlite3_database_file_object }

{ -------- libc bindings ----------------------------------------------- }

function tsLibcGetpid: cint; cdecl;
  external 'c' name 'getpid';

{ -------- constants --------------------------------------------------- }

const
  TMSTMP_RESERVE = 16;
  TMSTMP_MAGIC   : u32 = $2a87b72d;

  { Event log opcodes (tmstmpvfs.c:353..362) }
  ELOG_OPEN_DB    = $01;
  ELOG_OPEN_WAL   = $02;
  ELOG_WAL_PAGE   = $03;
  ELOG_DB_PAGE    = $04;
  ELOG_CKPT_START = $05;
  ELOG_CKPT_PAGE  = $06;
  ELOG_CKPT_DONE  = $07;
  ELOG_WAL_RESET  = $08;
  ELOG_CLOSE_WAL  = $0e;
  ELOG_CLOSE_DB   = $0f;

{ -------- types ------------------------------------------------------- }

type
  PTmstmpLog = ^TTmstmpLog;
  TTmstmpLog = record
    zLogname : PAnsiChar;            { Log filename }
    log      : PFILE;                { Open log file (lazy) }
    n        : cint;                 { Bytes of a[] used }
    a        : array[0..16*6 - 1] of Byte;  { Buffered header for the log }
  end;

  PTmstmpFile = ^TTmstmpFile;
  TTmstmpFile = record
    base               : sqlite3_file;     { IO methods.  MUST BE FIRST. }
    uMagic             : u32;              { Magic number for sanity checking }
    salt1              : u32;              { Last WAL salt-1 value }
    iFrame             : u32;              { Last WAL frame number }
    pgno               : u32;              { Current page number }
    pgsz               : u32;              { Size of each page, in bytes }
    isWal              : u8;               { True if this is a WAL file }
    isDb               : u8;               { True if this is a DB file }
    isCommit           : u8;               { Last WAL frame header was a tx commit }
    hasCorrectReserve  : u8;               { File has the correct reserve size }
    inCkpt             : u8;               { True if in a checkpoint }
    pLog               : PTmstmpLog;       { Log file (DB-side only) }
    pPartner           : PTmstmpFile;      { DB->WAL or WAL->DB mapping }
    iOfst              : i64;              { Offset of last WAL frame header }
    pSubVfs            : Psqlite3_vfs;     { Underlying VFS }
  end;

{ -------- forward decls of methods ------------------------------------ }

function tmstmpClose(pFile: Psqlite3_file): cint; cdecl; forward;
function tmstmpRead(pFile: Psqlite3_file; zBuf: Pointer;
                    iAmt: cint; iOfst: i64): cint; cdecl; forward;
function tmstmpWrite(pFile: Psqlite3_file; zBuf: Pointer;
                     iAmt: cint; iOfst: i64): cint; cdecl; forward;
function tmstmpTruncate(pFile: Psqlite3_file; size: i64): cint; cdecl; forward;
function tmstmpSync(pFile: Psqlite3_file; flags: cint): cint; cdecl; forward;
function tmstmpFileSize(pFile: Psqlite3_file; pSize: Pi64): cint; cdecl; forward;
function tmstmpLock(pFile: Psqlite3_file; eLock: cint): cint; cdecl; forward;
function tmstmpUnlock(pFile: Psqlite3_file; eLock: cint): cint; cdecl; forward;
function tmstmpCheckReservedLock(pFile: Psqlite3_file;
                                 pResOut: PcInt): cint; cdecl; forward;
function tmstmpFileControl(pFile: Psqlite3_file; op: cint;
                           pArg: Pointer): cint; cdecl; forward;
function tmstmpSectorSize(pFile: Psqlite3_file): cint; cdecl; forward;
function tmstmpDeviceCharacteristics(pFile: Psqlite3_file): cint; cdecl; forward;
function tmstmpShmMap(pFile: Psqlite3_file; iPg, pgsz, bExtend: cint;
                      pp: PPointer): cint; cdecl; forward;
function tmstmpShmLock(pFile: Psqlite3_file; offset, n, flags: cint): cint;
  cdecl; forward;
procedure tmstmpShmBarrier(pFile: Psqlite3_file); cdecl; forward;
function tmstmpShmUnmap(pFile: Psqlite3_file; deleteFlag: cint): cint;
  cdecl; forward;
function tmstmpFetch(pFile: Psqlite3_file; iOfst: i64; iAmt: cint;
                     pp: PPointer): cint; cdecl; forward;
function tmstmpUnfetch(pFile: Psqlite3_file; iOfst: i64;
                       pPage: Pointer): cint; cdecl; forward;

function tmstmpOpen(pVfs: Psqlite3_vfs; zName: sqlite3_filename;
                    pFile: Psqlite3_file; flags: cint;
                    pOutFlags: PcInt): cint; cdecl; forward;
function tmstmpDelete(pVfs: Psqlite3_vfs; zName: PChar;
                      syncDir: cint): cint; cdecl; forward;
function tmstmpAccess(pVfs: Psqlite3_vfs; zName: PChar; flags: cint;
                      pResOut: PcInt): cint; cdecl; forward;
function tmstmpFullPathname(pVfs: Psqlite3_vfs; zName: PChar;
                            nOut: cint; zOut: PChar): cint; cdecl; forward;
function tmstmpDlOpen(pVfs: Psqlite3_vfs; zFilename: PChar): Pointer;
  cdecl; forward;
procedure tmstmpDlError(pVfs: Psqlite3_vfs; nByte: cint;
                        zErrMsg: PChar); cdecl; forward;
function tmstmpDlSym(pVfs: Psqlite3_vfs; pHandle: Pointer;
                     zSymbol: PChar): sqlite3_syscall_ptr; cdecl; forward;
procedure tmstmpDlClose(pVfs: Psqlite3_vfs; pHandle: Pointer); cdecl; forward;
function tmstmpRandomness(pVfs: Psqlite3_vfs; nByte: cint;
                          zOut: PChar): cint; cdecl; forward;
function tmstmpSleep(pVfs: Psqlite3_vfs; microseconds: cint): cint;
  cdecl; forward;
function tmstmpCurrentTime(pVfs: Psqlite3_vfs;
                           pTimeOut: PDouble): cint; cdecl; forward;
function tmstmpGetLastError(pVfs: Psqlite3_vfs; n: cint;
                            zBuf: PChar): cint; cdecl; forward;
function tmstmpCurrentTimeInt64(pVfs: Psqlite3_vfs;
                                p: Pi64): cint; cdecl; forward;
function tmstmpSetSystemCall(pVfs: Psqlite3_vfs; zName: PChar;
                             pNewFunc: sqlite3_syscall_ptr): cint;
  cdecl; forward;
function tmstmpGetSystemCall(pVfs: Psqlite3_vfs;
                             zName: PChar): sqlite3_syscall_ptr;
  cdecl; forward;
function tmstmpNextSystemCall(pVfs: Psqlite3_vfs;
                              zName: PChar): PChar; cdecl; forward;

{ -------- module-level state ------------------------------------------ }

var
  tmstmp_vfs        : sqlite3_vfs;
  tmstmp_io_methods : sqlite3_io_methods;
  gTmstmpvfsInitialised : Boolean = False;

{ -------- ORIGVFS / ORIGFILE helpers (tmstmpvfs.c:320..321) ------------ }

function ORIGVFS(pVfs: Psqlite3_vfs): Psqlite3_vfs; inline;
begin
  Result := Psqlite3_vfs(pVfs^.pAppData);
end;

function ORIGFILE(pFile: Psqlite3_file): Psqlite3_file; inline;
begin
  { (sqlite3_file*)(((TmstmpFile*)p)+1) }
  Result := Psqlite3_file(PtrUInt(pFile) + SizeOf(TTmstmpFile));
end;

{ -------- helpers (tmstmpvfs.c:454..548) ------------------------------- }

{ Write a 6-byte millisecond timestamp into aOut[] }
procedure tmstmpPutTS(p: PTmstmpFile; aOut: PByte);
var
  tm : u64;
begin
  tm := 0;
  p^.pSubVfs^.xCurrentTimeInt64(p^.pSubVfs, Pi64(@tm));
  { tmstmpvfs.c uses the JD-to-Unix-millis offset 210866760000000. }
  tm := tm - u64(210866760000000);
  aOut[0] := Byte((tm shr 40) and $ff);
  aOut[1] := Byte((tm shr 32) and $ff);
  aOut[2] := Byte((tm shr 24) and $ff);
  aOut[3] := Byte((tm shr 16) and $ff);
  aOut[4] := Byte((tm shr 8)  and $ff);
  aOut[5] := Byte(tm and $ff);
end;

function tmstmpGetU32(a: PByte): u32; inline;
begin
  Result := (u32(a[0]) shl 24) + (u32(a[1]) shl 16)
          + (u32(a[2]) shl 8)  + u32(a[3]);
end;

procedure tmstmpPutU32(v: u32; a: PByte);
begin
  a[0] := Byte((v shr 24) and $ff);
  a[1] := Byte((v shr 16) and $ff);
  a[2] := Byte((v shr 8)  and $ff);
  a[3] := Byte(v and $ff);
end;

procedure tmstmpLogFree(pLog: PTmstmpLog);
begin
  if pLog = nil then Exit;
  if pLog^.log <> nil then libc_fclose(pLog^.log);
  sqlite3_free(pLog^.zLogname);
  sqlite3_free(pLog);
end;

{ Flush log content.  Open the file if necessary.  Returns the number of
  errors (0 on success, 1 on fopen failure). }
function tmstmpLogFlush(p: PTmstmpFile): cint;
var
  pLog : PTmstmpLog;
begin
  pLog := p^.pLog;
  Assert(pLog <> nil);
  if pLog^.log = nil then begin
    pLog^.log := libc_fopen(pLog^.zLogname, PAnsiChar('wb'));
    if pLog^.log = nil then begin
      tmstmpLogFree(pLog);
      p^.pLog := nil;
      Exit(1);
    end;
  end;
  libc_fwrite(@pLog^.a[0], pLog^.n, 1, pLog^.log);
  libc_fflush(pLog^.log);
  pLog^.n := 0;
  Result := 0;
end;

{ Write a record onto the event log (tmstmpvfs.c:514..548). }
procedure tmstmpEvent(p: PTmstmpFile; op, a1: u8; a2, a3: u32; pTS: PByte);
var
  a    : PByte;
  pLog : PTmstmpLog;
begin
  if p^.isWal <> 0 then begin
    p := p^.pPartner;
    Assert(p <> nil);
    Assert(p^.isDb <> 0);
  end;
  pLog := p^.pLog;
  if pLog = nil then Exit;
  if pLog^.n >= cint(SizeOf(pLog^.a)) then begin
    if tmstmpLogFlush(p) <> 0 then Exit;
  end;
  a := @pLog^.a[pLog^.n];
  a[0] := op;
  a[1] := a1;
  if pTS <> nil then
    Move(pTS^, a[2], 6)
  else
    tmstmpPutTS(p, @a[2]);
  tmstmpPutU32(a2, @a[8]);
  tmstmpPutU32(a3, @a[12]);
  Inc(pLog^.n, 16);
  if (pLog^.log <> nil)
     or ((op >= ELOG_WAL_PAGE) and (op <= ELOG_WAL_RESET)) then
    tmstmpLogFlush(p);
end;

{ -------- IO methods -------------------------------------------------- }

function tmstmpClose(pFile: Psqlite3_file): cint; cdecl;
var
  p   : PTmstmpFile;
  pSub: Psqlite3_file;
begin
  p := PTmstmpFile(pFile);
  if p^.hasCorrectReserve <> 0 then begin
    if p^.isDb <> 0 then
      tmstmpEvent(p, ELOG_CLOSE_DB, 0, 0, 0, nil)
    else
      tmstmpEvent(p, ELOG_CLOSE_WAL, 0, 0, 0, nil);
  end;
  tmstmpLogFree(p^.pLog);
  p^.pLog := nil;
  if p^.pPartner <> nil then begin
    Assert(p^.pPartner^.pPartner = p);
    p^.pPartner^.pPartner := nil;
    p^.pPartner := nil;
  end;
  pSub := ORIGFILE(pFile);
  Result := pSub^.pMethods^.xClose(pSub);
end;

function tmstmpRead(pFile: Psqlite3_file; zBuf: Pointer;
                    iAmt: cint; iOfst: i64): cint; cdecl;
var
  rc   : cint;
  p    : PTmstmpFile;
  pSub : Psqlite3_file;
  a    : PByte;
begin
  p := PTmstmpFile(pFile);
  pSub := ORIGFILE(pFile);
  rc := pSub^.pMethods^.xRead(pSub, zBuf, iAmt, iOfst);
  if rc <> SQLITE_OK then Exit(rc);
  if (p^.isDb <> 0) and (iOfst = 0) and (iAmt >= 100) then begin
    a := PByte(zBuf);
    if a[20] = TMSTMP_RESERVE then
      p^.hasCorrectReserve := 1
    else
      p^.hasCorrectReserve := 0;
    p^.pgsz := (u32(a[16]) shl 8) + u32(a[17]);
    if p^.pgsz = 1 then p^.pgsz := 65536;
    if p^.pPartner <> nil then begin
      p^.pPartner^.hasCorrectReserve := p^.hasCorrectReserve;
      p^.pPartner^.pgsz := p^.pgsz;
    end;
  end;
  if (p^.isWal <> 0) and (p^.inCkpt <> 0)
     and (iAmt >= 512) and (iAmt <= 65535)
     and ((iAmt and (iAmt - 1)) = 0) then begin
    p^.pPartner^.iFrame := u32((iOfst - 56) div (i64(p^.pgsz) + 24)) + 1;
  end;
  Result := rc;
end;

function tmstmpWrite(pFile: Psqlite3_file; zBuf: Pointer;
                     iAmt: cint; iOfst: i64): cint; cdecl;
var
  p    : PTmstmpFile;
  pSub : Psqlite3_file;
  s    : PByte;
  x    : u32;
begin
  p := PTmstmpFile(pFile);
  pSub := ORIGFILE(pFile);
  if p^.hasCorrectReserve = 0 then begin
    { No-op — DB does not have the correct reserve size. }
  end else if p^.isWal <> 0 then begin
    if iAmt = 24 then begin
      { A WAL frame header. }
      x := 0;
      p^.iFrame := u32((iOfst - 32) div (i64(p^.pgsz) + 24)) + 1;
      p^.pgno := tmstmpGetU32(PByte(zBuf));
      p^.salt1 := tmstmpGetU32(PByte(PtrUInt(zBuf) + 8));
      Move(PByte(PtrUInt(zBuf) + 4)^, x, 4);
      if x <> 0 then p^.isCommit := 1 else p^.isCommit := 0;
      p^.iOfst := iOfst;
    end else if (iAmt >= 512) and (iOfst = p^.iOfst + 24) then begin
      s := PByte(PtrUInt(zBuf) + iAmt - TMSTMP_RESERVE);
      FillChar(s^, TMSTMP_RESERVE, 0);
      tmstmpPutTS(p, PByte(PtrUInt(s) + 2));
      tmstmpEvent(p, ELOG_WAL_PAGE, p^.isCommit, p^.pgno, p^.iFrame,
                  PByte(PtrUInt(s) + 2));
    end else if (iAmt = 32) and (iOfst = 0) then begin
      p^.salt1 := tmstmpGetU32(PByte(PtrUInt(zBuf) + 16));
      tmstmpEvent(p, ELOG_WAL_RESET, 0, 0, p^.salt1, nil);
    end;
  end else if p^.inCkpt <> 0 then begin
    s := PByte(PtrUInt(zBuf) + iAmt - TMSTMP_RESERVE);
    FillChar(s^, TMSTMP_RESERVE, 0);
    tmstmpPutTS(p, PByte(PtrUInt(s) + 2));
    tmstmpPutU32(p^.iFrame, PByte(PtrUInt(s) + 8));
    tmstmpPutU32(p^.pPartner^.salt1 and $00ffffff, PByte(PtrUInt(s) + 12));
    Assert(p^.pgsz > 0);
    tmstmpEvent(p, ELOG_CKPT_PAGE, 0, u32(iOfst div p^.pgsz) + 1,
                p^.iFrame, nil);
  end else if p^.pPartner = nil then begin
    { Writing into a database in rollback mode. }
    s := PByte(PtrUInt(zBuf) + iAmt - TMSTMP_RESERVE);
    FillChar(s^, TMSTMP_RESERVE, 0);
    tmstmpPutTS(p, PByte(PtrUInt(s) + 2));
    s[12] := 2;
    Assert(p^.pgsz > 0);
    tmstmpEvent(p, ELOG_DB_PAGE, 0, u32(iOfst div p^.pgsz) + 1, 0,
                PByte(PtrUInt(s) + 2));
  end;
  Result := pSub^.pMethods^.xWrite(pSub, zBuf, iAmt, iOfst);
end;

function tmstmpTruncate(pFile: Psqlite3_file; size: i64): cint; cdecl;
var pSub: Psqlite3_file;
begin
  pSub := ORIGFILE(pFile);
  Result := pSub^.pMethods^.xTruncate(pSub, size);
end;

function tmstmpSync(pFile: Psqlite3_file; flags: cint): cint; cdecl;
var pSub: Psqlite3_file;
begin
  pSub := ORIGFILE(pFile);
  Result := pSub^.pMethods^.xSync(pSub, flags);
end;

function tmstmpFileSize(pFile: Psqlite3_file; pSize: Pi64): cint; cdecl;
var pSub: Psqlite3_file;
begin
  pSub := ORIGFILE(pFile);
  Result := pSub^.pMethods^.xFileSize(pSub, pSize);
end;

function tmstmpLock(pFile: Psqlite3_file; eLock: cint): cint; cdecl;
var pSub: Psqlite3_file;
begin
  pSub := ORIGFILE(pFile);
  Result := pSub^.pMethods^.xLock(pSub, eLock);
end;

function tmstmpUnlock(pFile: Psqlite3_file; eLock: cint): cint; cdecl;
var pSub: Psqlite3_file;
begin
  pSub := ORIGFILE(pFile);
  Result := pSub^.pMethods^.xUnlock(pSub, eLock);
end;

function tmstmpCheckReservedLock(pFile: Psqlite3_file;
                                 pResOut: PcInt): cint; cdecl;
var pSub: Psqlite3_file;
begin
  pSub := ORIGFILE(pFile);
  Result := pSub^.pMethods^.xCheckReservedLock(pSub, pResOut);
end;

function tmstmpFileControl(pFile: Psqlite3_file; op: cint;
                           pArg: Pointer): cint; cdecl;
var
  rc    : cint;
  p     : PTmstmpFile;
  pSub  : Psqlite3_file;
  zOld  : PAnsiChar;
  zNew  : PAnsiChar;
begin
  p := PTmstmpFile(pFile);
  pSub := ORIGFILE(pFile);
  rc := pSub^.pMethods^.xFileControl(pSub, op, pArg);
  case op of
    SQLITE_FCNTL_VFSNAME: begin
      if (p^.hasCorrectReserve <> 0) and (rc = SQLITE_OK) then begin
        zOld := PPAnsiChar(pArg)^;
        zNew := sqlite3PfMprintf(PAnsiChar('tmstmp/%s'), [zOld]);
        if zOld <> nil then sqlite3_free(zOld);
        PPAnsiChar(pArg)^ := zNew;
      end;
    end;
    SQLITE_FCNTL_CKPT_START: begin
      p^.inCkpt := 1;
      Assert(p^.isDb <> 0);
      Assert(p^.pPartner <> nil);
      p^.pPartner^.inCkpt := 1;
      if p^.hasCorrectReserve <> 0 then
        tmstmpEvent(p, ELOG_CKPT_START, 0, 0, 0, nil);
      rc := SQLITE_OK;
    end;
    SQLITE_FCNTL_CKPT_DONE: begin
      p^.inCkpt := 0;
      Assert(p^.isDb <> 0);
      Assert(p^.pPartner <> nil);
      p^.pPartner^.inCkpt := 0;
      if p^.hasCorrectReserve <> 0 then
        tmstmpEvent(p, ELOG_CKPT_DONE, 0, 0, 0, nil);
      rc := SQLITE_OK;
    end;
  end;
  Result := rc;
end;

function tmstmpSectorSize(pFile: Psqlite3_file): cint; cdecl;
var pSub: Psqlite3_file;
begin
  pSub := ORIGFILE(pFile);
  Result := pSub^.pMethods^.xSectorSize(pSub);
end;

function tmstmpDeviceCharacteristics(pFile: Psqlite3_file): cint; cdecl;
var
  pSub    : Psqlite3_file;
  devchar : cint;
begin
  pSub := ORIGFILE(pFile);
  devchar := pSub^.pMethods^.xDeviceCharacteristics(pSub);
  Result := devchar and (not SQLITE_IOCAP_SUBPAGE_READ);
end;

function tmstmpShmMap(pFile: Psqlite3_file; iPg, pgsz, bExtend: cint;
                      pp: PPointer): cint; cdecl;
var pSub: Psqlite3_file;
begin
  pSub := ORIGFILE(pFile);
  Result := pSub^.pMethods^.xShmMap(pSub, iPg, pgsz, bExtend, pp);
end;

function tmstmpShmLock(pFile: Psqlite3_file; offset, n, flags: cint): cint;
  cdecl;
var pSub: Psqlite3_file;
begin
  pSub := ORIGFILE(pFile);
  Result := pSub^.pMethods^.xShmLock(pSub, offset, n, flags);
end;

procedure tmstmpShmBarrier(pFile: Psqlite3_file); cdecl;
var pSub: Psqlite3_file;
begin
  pSub := ORIGFILE(pFile);
  pSub^.pMethods^.xShmBarrier(pSub);
end;

function tmstmpShmUnmap(pFile: Psqlite3_file; deleteFlag: cint): cint; cdecl;
var pSub: Psqlite3_file;
begin
  pSub := ORIGFILE(pFile);
  Result := pSub^.pMethods^.xShmUnmap(pSub, deleteFlag);
end;

function tmstmpFetch(pFile: Psqlite3_file; iOfst: i64; iAmt: cint;
                     pp: PPointer): cint; cdecl;
var pSub: Psqlite3_file;
begin
  pSub := ORIGFILE(pFile);
  Result := pSub^.pMethods^.xFetch(pSub, iOfst, iAmt, pp);
end;

function tmstmpUnfetch(pFile: Psqlite3_file; iOfst: i64;
                       pPage: Pointer): cint; cdecl;
var pSub: Psqlite3_file;
begin
  pSub := ORIGFILE(pFile);
  Result := pSub^.pMethods^.xUnfetch(pSub, iOfst, pPage);
end;

{ -------- VFS methods (tmstmpvfs.c:816..985) -------------------------- }

function tmstmpOpen(pVfs: Psqlite3_vfs; zName: sqlite3_filename;
                    pFile: Psqlite3_file; flags: cint;
                    pOutFlags: PcInt): cint; cdecl;
var
  p, pDb       : PTmstmpFile;
  pSubFile     : Psqlite3_file;
  pSubVfs      : Psqlite3_vfs;
  rc           : cint;
  r1           : u64;
  r2           : u32;
  pid          : u32;
  pLog         : PTmstmpLog;
  days, sod, z, era : u64;
  hh, mm, ss, f : cint;
  Y, Mo, D, y_  : cint;
  doe, yoe, doy, mp : cuint;
label
  done_;
begin
  pSubVfs := ORIGVFS(pVfs);
  if (flags and (SQLITE_OPEN_MAIN_DB or SQLITE_OPEN_WAL)) = 0 then begin
    { Not a persistent DB or WAL — bypass the timestamp logic. }
    Exit(pSubVfs^.xOpen(pSubVfs, zName, pFile, flags, pOutFlags));
  end;
  pDb := nil;
  if (flags and SQLITE_OPEN_WAL) <> 0 then begin
    pDb := PTmstmpFile(sqlite3_database_file_object(zName));
    if (pDb = nil) or (pDb^.uMagic <> TMSTMP_MAGIC)
       or (pDb^.isDb = 0) or (pDb^.pPartner <> nil) then begin
      Exit(pSubVfs^.xOpen(pSubVfs, zName, pFile, flags, pOutFlags));
    end;
  end;
  p := PTmstmpFile(pFile);
  FillChar(p^, SizeOf(TTmstmpFile), 0);
  pSubFile := ORIGFILE(pFile);
  pFile^.pMethods := @tmstmp_io_methods;
  p^.pSubVfs := pSubVfs;
  p^.uMagic := TMSTMP_MAGIC;
  rc := pSubVfs^.xOpen(pSubVfs, zName, pSubFile, flags, pOutFlags);
  if rc <> 0 then goto done_;
  if pDb <> nil then begin
    p^.isWal := 1;
    p^.pPartner := pDb;
    pDb^.pPartner := p;
  end else begin
    p^.isDb := 1;
    r1 := 0;
    pLog := PTmstmpLog(sqlite3_malloc64(SizeOf(TTmstmpLog)));
    if pLog = nil then begin
      pSubFile^.pMethods^.xClose(pSubFile);
      rc := SQLITE_NOMEM;
      goto done_;
    end;
    FillChar(pLog^, SizeOf(TTmstmpLog), 0);
    p^.pLog := pLog;
    p^.pSubVfs^.xCurrentTimeInt64(p^.pSubVfs, Pi64(@r1));
    r1 := r1 - u64(210866760000000);
    days := r1 div 86400000;
    sod  := (r1 mod 86400000) div 1000;
    f    := cint(r1 mod 1000);

    hh := cint(sod div 3600);
    mm := cint((sod mod 3600) div 60);
    ss := cint(sod mod 60);
    z := days + 719468;
    era := z div 146097;
    doe := cuint(z - era * 146097);
    yoe := (doe - doe div 1460 + doe div 36524 - doe div 146096) div 365;
    y_  := cint(yoe) + cint(era) * 400;
    doy := doe - (365 * yoe + yoe div 4 - yoe div 100);
    mp  := (5 * doy + 2) div 153;
    D   := cint(doy) - cint((153 * mp + 2) div 5) + 1;
    if mp < 10 then Mo := cint(mp) + 3 else Mo := cint(mp) - 9;
    Y := y_;
    if Mo <= 2 then Inc(Y);
    sqlite3_randomness(SizeOf(r2), @r2);
    pid := u32(tsLibcGetpid);
    pLog^.zLogname := sqlite3PfMprintf(
      PAnsiChar('%s-tmstmp/%04d%02d%02dT%02d%02d%02d%03d-%08d-%08x'),
      [zName, Y, Mo, D, hh, mm, ss, f, pid, r2]);
  end;
  if p^.isWal <> 0 then
    tmstmpEvent(p, ELOG_OPEN_WAL, 0, u32(tsLibcGetpid), 0, nil)
  else
    tmstmpEvent(p, ELOG_OPEN_DB, 0, u32(tsLibcGetpid), 0, nil);

done_:
  if rc <> 0 then pFile^.pMethods := nil;
  Result := rc;
end;

function tmstmpDelete(pVfs: Psqlite3_vfs; zName: PChar;
                      syncDir: cint): cint; cdecl;
var pSub: Psqlite3_vfs;
begin
  pSub := ORIGVFS(pVfs);
  Result := pSub^.xDelete(pSub, zName, syncDir);
end;

function tmstmpAccess(pVfs: Psqlite3_vfs; zName: PChar; flags: cint;
                      pResOut: PcInt): cint; cdecl;
var pSub: Psqlite3_vfs;
begin
  pSub := ORIGVFS(pVfs);
  Result := pSub^.xAccess(pSub, zName, flags, pResOut);
end;

function tmstmpFullPathname(pVfs: Psqlite3_vfs; zName: PChar;
                            nOut: cint; zOut: PChar): cint; cdecl;
var pSub: Psqlite3_vfs;
begin
  pSub := ORIGVFS(pVfs);
  Result := pSub^.xFullPathname(pSub, zName, nOut, zOut);
end;

function tmstmpDlOpen(pVfs: Psqlite3_vfs; zFilename: PChar): Pointer; cdecl;
var pSub: Psqlite3_vfs;
begin
  pSub := ORIGVFS(pVfs);
  Result := pSub^.xDlOpen(pSub, zFilename);
end;

procedure tmstmpDlError(pVfs: Psqlite3_vfs; nByte: cint;
                        zErrMsg: PChar); cdecl;
var pSub: Psqlite3_vfs;
begin
  pSub := ORIGVFS(pVfs);
  pSub^.xDlError(pSub, nByte, zErrMsg);
end;

function tmstmpDlSym(pVfs: Psqlite3_vfs; pHandle: Pointer;
                     zSymbol: PChar): sqlite3_syscall_ptr; cdecl;
var pSub: Psqlite3_vfs;
begin
  pSub := ORIGVFS(pVfs);
  Result := pSub^.xDlSym(pSub, pHandle, zSymbol);
end;

procedure tmstmpDlClose(pVfs: Psqlite3_vfs; pHandle: Pointer); cdecl;
var pSub: Psqlite3_vfs;
begin
  pSub := ORIGVFS(pVfs);
  pSub^.xDlClose(pSub, pHandle);
end;

function tmstmpRandomness(pVfs: Psqlite3_vfs; nByte: cint;
                          zOut: PChar): cint; cdecl;
var pSub: Psqlite3_vfs;
begin
  pSub := ORIGVFS(pVfs);
  Result := pSub^.xRandomness(pSub, nByte, zOut);
end;

function tmstmpSleep(pVfs: Psqlite3_vfs; microseconds: cint): cint; cdecl;
var pSub: Psqlite3_vfs;
begin
  pSub := ORIGVFS(pVfs);
  Result := pSub^.xSleep(pSub, microseconds);
end;

function tmstmpCurrentTime(pVfs: Psqlite3_vfs;
                           pTimeOut: PDouble): cint; cdecl;
var pSub: Psqlite3_vfs;
begin
  pSub := ORIGVFS(pVfs);
  Result := pSub^.xCurrentTime(pSub, pTimeOut);
end;

function tmstmpGetLastError(pVfs: Psqlite3_vfs; n: cint;
                            zBuf: PChar): cint; cdecl;
var pSub: Psqlite3_vfs;
begin
  pSub := ORIGVFS(pVfs);
  Result := pSub^.xGetLastError(pSub, n, zBuf);
end;

function tmstmpCurrentTimeInt64(pVfs: Psqlite3_vfs;
                                p: Pi64): cint; cdecl;
var pSub: Psqlite3_vfs;
begin
  pSub := ORIGVFS(pVfs);
  Result := pSub^.xCurrentTimeInt64(pSub, p);
end;

function tmstmpSetSystemCall(pVfs: Psqlite3_vfs; zName: PChar;
                             pNewFunc: sqlite3_syscall_ptr): cint; cdecl;
var pSub: Psqlite3_vfs;
begin
  pSub := ORIGVFS(pVfs);
  Result := pSub^.xSetSystemCall(pSub, zName, pNewFunc);
end;

function tmstmpGetSystemCall(pVfs: Psqlite3_vfs;
                             zName: PChar): sqlite3_syscall_ptr; cdecl;
var pSub: Psqlite3_vfs;
begin
  pSub := ORIGVFS(pVfs);
  Result := pSub^.xGetSystemCall(pSub, zName);
end;

function tmstmpNextSystemCall(pVfs: Psqlite3_vfs;
                              zName: PChar): PChar; cdecl;
var pSub: Psqlite3_vfs;
begin
  pSub := ORIGVFS(pVfs);
  Result := pSub^.xNextSystemCall(pSub, zName);
end;

{ -------- registration ------------------------------------------------ }

procedure ensureMethodTablesPopulated;
begin
  { Mirrors tmstmpvfs.c:406 — tmstmp_vfs is a static struct-literal initialised
    exactly once.  Without this guard, re-invocation while tmstmp_vfs is
    already linked into the VFS list would FillChar+zero pNext BEFORE
    vfs_register's vfsUnlink walked the chain, severing every subsequent VFS
    (bug 6.20, mirrors the appendvfs 6.19 fix). }
  if gTmstmpvfsInitialised then Exit;

  FillChar(tmstmp_io_methods, SizeOf(tmstmp_io_methods), 0);
  tmstmp_io_methods.iVersion               := 3;
  tmstmp_io_methods.xClose                 := @tmstmpClose;
  tmstmp_io_methods.xRead                  := @tmstmpRead;
  tmstmp_io_methods.xWrite                 := @tmstmpWrite;
  tmstmp_io_methods.xTruncate              := @tmstmpTruncate;
  tmstmp_io_methods.xSync                  := @tmstmpSync;
  tmstmp_io_methods.xFileSize              := @tmstmpFileSize;
  tmstmp_io_methods.xLock                  := @tmstmpLock;
  tmstmp_io_methods.xUnlock                := @tmstmpUnlock;
  tmstmp_io_methods.xCheckReservedLock     := @tmstmpCheckReservedLock;
  tmstmp_io_methods.xFileControl           := @tmstmpFileControl;
  tmstmp_io_methods.xSectorSize            := @tmstmpSectorSize;
  tmstmp_io_methods.xDeviceCharacteristics := @tmstmpDeviceCharacteristics;
  tmstmp_io_methods.xShmMap                := @tmstmpShmMap;
  tmstmp_io_methods.xShmLock               := @tmstmpShmLock;
  tmstmp_io_methods.xShmBarrier            := @tmstmpShmBarrier;
  tmstmp_io_methods.xShmUnmap              := @tmstmpShmUnmap;
  tmstmp_io_methods.xFetch                 := @tmstmpFetch;
  tmstmp_io_methods.xUnfetch               := @tmstmpUnfetch;

  FillChar(tmstmp_vfs, SizeOf(tmstmp_vfs), 0);
  tmstmp_vfs.iVersion        := 3;
  tmstmp_vfs.szOsFile        := 0; { set below }
  tmstmp_vfs.mxPathname      := 1024;
  tmstmp_vfs.zName           := PChar('tmstmpvfs');
  tmstmp_vfs.xOpen           := @tmstmpOpen;
  tmstmp_vfs.xDelete         := @tmstmpDelete;
  tmstmp_vfs.xAccess         := @tmstmpAccess;
  tmstmp_vfs.xFullPathname   := @tmstmpFullPathname;
  tmstmp_vfs.xDlOpen         := @tmstmpDlOpen;
  tmstmp_vfs.xDlError        := @tmstmpDlError;
  tmstmp_vfs.xDlSym          := @tmstmpDlSym;
  tmstmp_vfs.xDlClose        := @tmstmpDlClose;
  tmstmp_vfs.xRandomness     := @tmstmpRandomness;
  tmstmp_vfs.xSleep          := @tmstmpSleep;
  tmstmp_vfs.xCurrentTime    := @tmstmpCurrentTime;
  tmstmp_vfs.xGetLastError   := @tmstmpGetLastError;
  tmstmp_vfs.xCurrentTimeInt64 := @tmstmpCurrentTimeInt64;
  tmstmp_vfs.xSetSystemCall  := @tmstmpSetSystemCall;
  tmstmp_vfs.xGetSystemCall  := @tmstmpGetSystemCall;
  tmstmp_vfs.xNextSystemCall := @tmstmpNextSystemCall;

  gTmstmpvfsInitialised := True;
end;

function tmstmpRegisterVfs: i32;
var
  pOrig : Psqlite3_vfs;
begin
  pOrig := sqlite3_vfs_find(nil);
  if pOrig = nil then Exit(SQLITE_ERROR);
  if pOrig = @tmstmp_vfs then Exit(SQLITE_OK);
  ensureMethodTablesPopulated;
  tmstmp_vfs.iVersion := pOrig^.iVersion;
  tmstmp_vfs.pAppData := pOrig;
  tmstmp_vfs.szOsFile := pOrig^.szOsFile + cint(SizeOf(TTmstmpFile));
  Result := sqlite3_vfs_register(@tmstmp_vfs, 1);
end;

function sqlite3_register_tmstmpvfs(NotUsed: PAnsiChar): i32;
begin
  if NotUsed = NotUsed then ; { silence }
  Result := tmstmpRegisterVfs;
end;

function sqlite3_unregister_tmstmpvfs: i32;
begin
  if sqlite3_vfs_find(PChar('tmstmpvfs')) <> nil then
    sqlite3_vfs_unregister(@tmstmp_vfs);
  Result := SQLITE_OK;
end;

end.
