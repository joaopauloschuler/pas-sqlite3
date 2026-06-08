{
  SPDX-License-Identifier: blessing

  TestModuleVfs — port of the `testvfs` Tcl object command from
  /home/bpsa/app/sqlite3/src/test_vfs.c (1697 lines in C).

  Provides:

    testvfs VFSNAME ?-default BOOL? ?-iversion INT? ?-noshm BOOL?
                    ?-fullshm BOOL? ?-szosfile INT? ?-mxpathname INT?

  This creates a SQLite VFS and a same-named Tcl object command.  The
  VFS wraps the default VFS and forwards all xRead/xWrite/xOpen/xLock/
  ... calls to its parent.  Optionally, when a per-method filter bit
  is set AND a Tcl callback script is registered, the VFS evaluates

      $script $methodName $filename ...

  in the interpreter — letting Tcl test scripts inject SQLITE_IOERR /
  count calls / etc.  Used by interrupt2.test (xWrite), mjournal.test
  (xOpen), nolock.test (xLock/xUnlock/xCheckReservedLock/xAccess),
  e_wal.test (-iversion 1, no callback).

  Object subcommands implemented:
    filter      LIST       — set the per-method mask
    script      ?SCRIPT?   — register/clear the callback script
    devchar     ?FLAGS?    — override device characteristics
    sectorsize  ?VALUE?    — override sector size
    ioerr       ?CNT P?    — schedule SQLITE_IOERR fault injection
    fullerr     ?CNT P?    — schedule SQLITE_FULL
    cantopenerr ?CNT P?    — schedule SQLITE_CANTOPEN
    delete                 — Tcl_DeleteCommand on self (triggers VFS
                              unregister via the cmd-delete hook)

  Subcommand intentionally NOT ported (none of the four target tests
  use it; the wal/locktest matrix that drives `shm` is gated as a
  follow-up):
    shm FILE ?VAL?         — read/write the shared-memory buffer

  Also registered (test_vfs.c:1690..1694):
    vfs_shmlock DB ...     — STUB (returns SQLITE_OK)
    vfs_set_readmark DB... — STUB (returns -1)

  Gated on {$ifdef SQLITE_TEST} so the production engine is untouched.
}
{$I passqlite3.inc}
unit TestModuleVfs;

interface

uses
  ctypes,
  PasTclBridge;

{ test_vfs.c:1690 — Sqlitetestvfs_Init: registers the `testvfs`,
  `vfs_shmlock`, `vfs_set_readmark` Tcl commands. }
function Sqlitetestvfs_Init(interp: PTclInterp): cint; cdecl;

implementation

{$ifdef SQLITE_TEST}
uses
  SysUtils,
  strings,
  passqlite3types,
  passqlite3os,
  passqlite3util,
  passqlite3main;

type
  { Mirror of the leading field of struct SqliteDb (tclsqlite.c:215) —
    only the sqlite3* handle is needed to reach xShmLock. }
  PVfsTestSqliteDb = ^TVfsTestSqliteDb;
  TVfsTestSqliteDb = record
    db: PTsqlite3;
  end;

const
  { test_vfs.c:114..135 — per-method mask bits. }
  TESTVFS_SHMOPEN_MASK      = $00000001;
  TESTVFS_SHMLOCK_MASK      = $00000010;
  TESTVFS_SHMMAP_MASK       = $00000020;
  TESTVFS_SHMBARRIER_MASK   = $00000040;
  TESTVFS_SHMCLOSE_MASK     = $00000080;

  TESTVFS_OPEN_MASK         = $00000100;
  TESTVFS_SYNC_MASK         = $00000200;
  TESTVFS_DELETE_MASK       = $00000400;
  TESTVFS_CLOSE_MASK        = $00000800;
  TESTVFS_WRITE_MASK        = $00001000;
  TESTVFS_TRUNCATE_MASK     = $00002000;
  TESTVFS_ACCESS_MASK       = $00004000;
  TESTVFS_FULLPATHNAME_MASK = $00008000;
  TESTVFS_READ_MASK         = $00010000;
  TESTVFS_UNLOCK_MASK       = $00020000;
  TESTVFS_LOCK_MASK         = $00040000;
  TESTVFS_CKLOCK_MASK       = $00080000;
  TESTVFS_FCNTL_MASK        = $00100000;
  TESTVFS_SLEEP_MASK        = $00200000;

  TESTVFS_ALL_MASK          = $003FFFFF;

  { test_vfs.c:61..63 — fault-inject eFault values. }
  FAULT_INJECT_NONE       = 0;
  FAULT_INJECT_TRANSIENT  = 1;
  FAULT_INJECT_PERSISTENT = 2;

  { test_vfs.c:138 — TESTVFS_MAX_PAGES. }
  TESTVFS_MAX_PAGES = 1024;

type
  PTestvfsFile     = ^TTestvfsFile;
  PTestvfsFd       = ^TTestvfsFd;
  PPTestvfsFd      = ^PTestvfsFd;
  PTestvfs         = ^TTestvfs;
  PTestvfsBuffer   = ^TTestvfsBuffer;
  PPTestvfsBuffer  = ^PTestvfsBuffer;
  PTestFaultInject = ^TTestFaultInject;

  { test_vfs.c:66..70 — TestFaultInject. }
  TTestFaultInject = record
    iCnt   : cint;
    eFault : cint;
    nFail  : cint;
  end;

  { test_vfs.c:42..45 — TestvfsFile.  Must start with sqlite3_file so
    a Psqlite3_file cast works. }
  TTestvfsFile = record
    base : sqlite3_file;
    pFd  : PTestvfsFd;
  end;

  { test_vfs.c:48..58 — TestvfsFd.  The real underlying sqlite3_file
    lives immediately after this record (ckalloc'd with extra
    szOsFile bytes). }
  TTestvfsFd = record
    pVfs      : Psqlite3_vfs;
    zFilename : PChar;
    pReal     : Psqlite3_file;
    pShmId    : PTclObj;
    pShm      : PTestvfsBuffer;  { test_vfs.c:53 — shared memory buffer }
    excllock  : cuint;
    sharedlock: cuint;
    pNext     : PTestvfsFd;      { next handle opened on the same file }
  end;

  { test_vfs.c:144..151 — TestvfsBuffer.  zFile lives just past the
    record (ckalloc'd with szName+1 extra bytes). }
  TTestvfsBuffer = record
    zFile : PChar;
    pgsz  : cint;
    aPage : array[0..TESTVFS_MAX_PAGES-1] of PByte;
    pFile : PTestvfsFd;          { list of open handles }
    pNext : PTestvfsBuffer;      { next in linked list of all buffers }
  end;

  { test_vfs.c:77..104 — Testvfs.  zName lives just past the record;
    pVfs is the registered sqlite3_vfs that points back here via
    pAppData. }
  TTestvfs = record
    zName       : PChar;
    pParent     : Psqlite3_vfs;
    pVfs        : Psqlite3_vfs;
    interp      : PTclInterp;
    pScript     : PTclObj;
    pBuffer     : PTestvfsBuffer;  { test_vfs.c:84 — list of shared buffers }
    isNoshm     : cint;
    isFullshm   : cint;
    mask        : cint;
    ioerr_err   : TTestFaultInject;
    full_err    : TTestFaultInject;
    cantopen_err: TTestFaultInject;
    iDevchar    : cint;
    iSectorsize : cint;
  end;

var
  tvfs_io_methods: sqlite3_io_methods;

{ Forward decls for the io_methods table. }
function tvfsClose(pFile: Psqlite3_file): cint; cdecl; forward;
function tvfsRead(pFile: Psqlite3_file; pBuf: Pointer; iAmt: cint; iOfst: i64): cint; cdecl; forward;
function tvfsWrite(pFile: Psqlite3_file; pBuf: Pointer; iAmt: cint; iOfst: i64): cint; cdecl; forward;
function tvfsTruncate(pFile: Psqlite3_file; size: i64): cint; cdecl; forward;
function tvfsSync(pFile: Psqlite3_file; flags: cint): cint; cdecl; forward;
function tvfsFileSize(pFile: Psqlite3_file; pSize: Pi64): cint; cdecl; forward;
function tvfsLock(pFile: Psqlite3_file; eLock: cint): cint; cdecl; forward;
function tvfsUnlock(pFile: Psqlite3_file; eLock: cint): cint; cdecl; forward;
function tvfsCheckReservedLock(pFile: Psqlite3_file; pResOut: PcInt): cint; cdecl; forward;
function tvfsFileControl(pFile: Psqlite3_file; op: cint; pArg: Pointer): cint; cdecl; forward;
function tvfsSectorSize(pFile: Psqlite3_file): cint; cdecl; forward;
function tvfsDeviceCharacteristics(pFile: Psqlite3_file): cint; cdecl; forward;
function tvfsShmOpen(pFile: Psqlite3_file): cint; forward;
function tvfsShmMap(pFile: Psqlite3_file; iPage: cint; pgsz: cint;
  isWrite: cint; pp: PPointer): cint; cdecl; forward;
function tvfsShmLock(pFile: Psqlite3_file; ofst: cint; n: cint;
  flags: cint): cint; cdecl; forward;
procedure tvfsShmBarrier(pFile: Psqlite3_file); cdecl; forward;
function tvfsShmUnmap(pFile: Psqlite3_file; deleteFlag: cint): cint; cdecl; forward;

{ Forward decls for the sqlite3_vfs slot. }
function tvfsOpen(pVfs: Psqlite3_vfs; zName: sqlite3_filename;
  pFile: Psqlite3_file; flags: cint; pOutFlags: PcInt): cint; cdecl; forward;
function tvfsDelete(pVfs: Psqlite3_vfs; zPath: PChar; dirSync: cint): cint; cdecl; forward;
function tvfsAccess(pVfs: Psqlite3_vfs; zPath: PChar; flags: cint; pResOut: PcInt): cint; cdecl; forward;
function tvfsFullPathname(pVfs: Psqlite3_vfs; zPath: PChar; nOut: cint; zOut: PChar): cint; cdecl; forward;
function tvfsRandomness(pVfs: Psqlite3_vfs; nByte: cint; zOut: PChar): cint; cdecl; forward;
function tvfsSleep(pVfs: Psqlite3_vfs; nMicro: cint): cint; cdecl; forward;
function tvfsCurrentTime(pVfs: Psqlite3_vfs; pTime: PDouble): cint; cdecl; forward;
function tvfsGetLastError(pVfs: Psqlite3_vfs; n: cint; zBuf: PChar): cint; cdecl; forward;

{ ckalloc / ckfree shorthand. }
function ckalloc(n: cuint): Pointer;
begin
  Result := Tcl_Alloc(n);
end;

procedure ckfree(p: Pointer);
begin
  Tcl_Free(PChar(p));
end;

{ Reach into objv[i].  Each slot is a Pointer, so step by SizeOf(Pointer). }
function objAt(objv: PPTclObj; i: cint): PTclObj; inline;
begin
  Result := PPTclObj(PtrUInt(objv) + PtrUInt(i) * SizeOf(Pointer))^;
end;

{ Parent VFS shorthand — test_vfs.c:154 PARENTVFS macro. }
function ParentVfs(pVfs: Psqlite3_vfs): Psqlite3_vfs; inline;
begin
  Result := PTestvfs(pVfs^.pAppData)^.pParent;
end;

{ test_vfs.c:223..251 — tvfsResultCode: map the interp result string to
  one of a few common SQLite error codes.  Returns 1 if matched. }
function tvfsResultCode(p: PTestvfs; var rc: cint): cint;
type
  TErrCode = record eCode: cint; zCode: PChar; end;
const
  aCode: array[0..8] of TErrCode = (
    (eCode: SQLITE_OK;       zCode: 'SQLITE_OK'),
    (eCode: SQLITE_ERROR;    zCode: 'SQLITE_ERROR'),
    (eCode: SQLITE_IOERR;    zCode: 'SQLITE_IOERR'),
    (eCode: SQLITE_LOCKED;   zCode: 'SQLITE_LOCKED'),
    (eCode: SQLITE_BUSY;     zCode: 'SQLITE_BUSY'),
    (eCode: SQLITE_READONLY; zCode: 'SQLITE_READONLY'),
    (eCode: SQLITE_READONLY_CANTINIT; zCode: 'SQLITE_READONLY_CANTINIT'),
    (eCode: SQLITE_NOTFOUND; zCode: 'SQLITE_NOTFOUND'),
    (eCode: -1;              zCode: 'SQLITE_OMIT')
  );
var
  z: PChar;
  i: cint;
begin
  z := Tcl_GetStringResult(p^.interp);
  for i := 0 to High(aCode) do
    if (z <> nil) and (StrComp(z, aCode[i].zCode) = 0) then begin
      rc := aCode[i].eCode;
      Result := 1;
      Exit;
    end;
  Result := 0;
end;

{ test_vfs.c:253..263 — tvfsInjectFault. }
function tvfsInjectFault(p: PTestFaultInject): cint;
begin
  Result := 0;
  if p^.eFault <> 0 then begin
    Dec(p^.iCnt);
    if (p^.iCnt = 0)
       or ((p^.iCnt < 0) and (p^.eFault = FAULT_INJECT_PERSISTENT)) then begin
      Result := 1;
      Inc(p^.nFail);
    end;
  end;
end;

function tvfsInjectIoerr(p: PTestvfs): cint;        inline; begin Result := tvfsInjectFault(@p^.ioerr_err); end;
function tvfsInjectFullerr(p: PTestvfs): cint;      inline; begin Result := tvfsInjectFault(@p^.full_err); end;
function tvfsInjectCantopenerr(p: PTestvfs): cint;  inline; begin Result := tvfsInjectFault(@p^.cantopen_err); end;

{ test_vfs.c:278..308 — tvfsExecTcl: $script $method arg1 arg2 arg3 arg4. }
procedure tvfsExecTcl(p: PTestvfs; zMethod: PChar;
  arg1, arg2, arg3, arg4: PTclObj);
var
  pEval: PTclObj;
  rc: cint;
begin
  Assert(p^.pScript <> nil);
  pEval := Tcl_DuplicateObj(p^.pScript);
  Tcl_IncrRefCount(p^.pScript);
  Tcl_ListObjAppendElement(p^.interp, pEval, Tcl_NewStringObj(zMethod, -1));
  if arg1 <> nil then Tcl_ListObjAppendElement(p^.interp, pEval, arg1);
  if arg2 <> nil then Tcl_ListObjAppendElement(p^.interp, pEval, arg2);
  if arg3 <> nil then Tcl_ListObjAppendElement(p^.interp, pEval, arg3);
  if arg4 <> nil then Tcl_ListObjAppendElement(p^.interp, pEval, arg4);

  rc := Tcl_EvalObjEx(p^.interp, pEval, TCL_EVAL_GLOBAL);
  if rc <> TCL_OK then begin
    Tcl_BackgroundError(p^.interp);
    Tcl_ResetResult(p^.interp);
  end;
end;

{ ============================================================
  sqlite3_io_methods implementations.
  ============================================================ }

function tvfsClose(pFile: Psqlite3_file): cint; cdecl;
var
  pTestfile: PTestvfsFile;
  pFd      : PTestvfsFd;
  p        : PTestvfs;
begin
  pTestfile := PTestvfsFile(pFile);
  pFd := pTestfile^.pFd;
  p := PTestvfs(pFd^.pVfs^.pAppData);

  if (p^.pScript <> nil) and ((p^.mask and TESTVFS_CLOSE_MASK) <> 0) then
    tvfsExecTcl(p, 'xClose',
      Tcl_NewStringObj(pFd^.zFilename, -1), pFd^.pShmId, nil, nil);

  if pFd^.pShmId <> nil then begin
    Tcl_DecrRefCount(pFd^.pShmId);
    pFd^.pShmId := nil;
  end;
  if pFile^.pMethods <> nil then
    ckfree(pFile^.pMethods);
  sqlite3OsClose(pFd^.pReal);
  ckfree(pFd);
  pTestfile^.pFd := nil;
  Result := SQLITE_OK;
end;

function tvfsRead(pFile: Psqlite3_file; pBuf: Pointer;
  iAmt: cint; iOfst: i64): cint; cdecl;
var
  pFd: PTestvfsFd;
  p  : PTestvfs;
  rc : cint;
begin
  rc := SQLITE_OK;
  pFd := PTestvfsFile(pFile)^.pFd;
  p := PTestvfs(pFd^.pVfs^.pAppData);
  if (p^.pScript <> nil) and ((p^.mask and TESTVFS_READ_MASK) <> 0) then begin
    tvfsExecTcl(p, 'xRead',
      Tcl_NewStringObj(pFd^.zFilename, -1), pFd^.pShmId, nil, nil);
    tvfsResultCode(p, rc);
  end;
  if (rc = SQLITE_OK)
     and ((p^.mask and TESTVFS_READ_MASK) <> 0)
     and (tvfsInjectIoerr(p) <> 0) then rc := SQLITE_IOERR;
  if rc = SQLITE_OK then
    rc := sqlite3OsRead(pFd^.pReal, pBuf, iAmt, iOfst);
  Result := rc;
end;

function tvfsWrite(pFile: Psqlite3_file; pBuf: Pointer;
  iAmt: cint; iOfst: i64): cint; cdecl;
var
  pFd: PTestvfsFd;
  p  : PTestvfs;
  rc : cint;
begin
  rc := SQLITE_OK;
  pFd := PTestvfsFile(pFile)^.pFd;
  p := PTestvfs(pFd^.pVfs^.pAppData);
  if (p^.pScript <> nil) and ((p^.mask and TESTVFS_WRITE_MASK) <> 0) then begin
    tvfsExecTcl(p, 'xWrite',
      Tcl_NewStringObj(pFd^.zFilename, -1), pFd^.pShmId,
      Tcl_NewWideIntObj(iOfst), Tcl_NewIntObj(iAmt));
    tvfsResultCode(p, rc);
    if rc < 0 then begin Result := SQLITE_OK; Exit; end;
  end;
  if (rc = SQLITE_OK) and (tvfsInjectFullerr(p) <> 0) then
    rc := SQLITE_FULL;
  if (rc = SQLITE_OK)
     and ((p^.mask and TESTVFS_WRITE_MASK) <> 0)
     and (tvfsInjectIoerr(p) <> 0) then rc := SQLITE_IOERR;
  if rc = SQLITE_OK then
    rc := sqlite3OsWrite(pFd^.pReal, pBuf, iAmt, iOfst);
  Result := rc;
end;

function tvfsTruncate(pFile: Psqlite3_file; size: i64): cint; cdecl;
var
  pFd: PTestvfsFd;
  p  : PTestvfs;
  rc : cint;
begin
  rc := SQLITE_OK;
  pFd := PTestvfsFile(pFile)^.pFd;
  p := PTestvfs(pFd^.pVfs^.pAppData);
  if (p^.pScript <> nil) and ((p^.mask and TESTVFS_TRUNCATE_MASK) <> 0) then begin
    tvfsExecTcl(p, 'xTruncate',
      Tcl_NewStringObj(pFd^.zFilename, -1), pFd^.pShmId, nil, nil);
    tvfsResultCode(p, rc);
  end;
  if rc = SQLITE_OK then
    rc := sqlite3OsTruncate(pFd^.pReal, size);
  Result := rc;
end;

function tvfsSync(pFile: Psqlite3_file; flags: cint): cint; cdecl;
var
  pFd  : PTestvfsFd;
  p    : PTestvfs;
  rc   : cint;
  zFlags: PChar;
begin
  rc := SQLITE_OK;
  pFd := PTestvfsFile(pFile)^.pFd;
  p := PTestvfs(pFd^.pVfs^.pAppData);
  if (p^.pScript <> nil) and ((p^.mask and TESTVFS_SYNC_MASK) <> 0) then begin
    case flags of
      SQLITE_SYNC_NORMAL: zFlags := 'normal';
      SQLITE_SYNC_FULL:   zFlags := 'full';
      SQLITE_SYNC_NORMAL or SQLITE_SYNC_DATAONLY: zFlags := 'normal|dataonly';
      SQLITE_SYNC_FULL   or SQLITE_SYNC_DATAONLY: zFlags := 'full|dataonly';
    else
      zFlags := 'unknown';
    end;
    tvfsExecTcl(p, 'xSync',
      Tcl_NewStringObj(pFd^.zFilename, -1), pFd^.pShmId,
      Tcl_NewStringObj(zFlags, -1), nil);
    tvfsResultCode(p, rc);
  end;
  if (rc = SQLITE_OK) and (tvfsInjectFullerr(p) <> 0) then rc := SQLITE_FULL;
  if rc = SQLITE_OK then
    rc := sqlite3OsSync(pFd^.pReal, flags);
  Result := rc;
end;

function tvfsFileSize(pFile: Psqlite3_file; pSize: Pi64): cint; cdecl;
begin
  Result := sqlite3OsFileSize(PTestvfsFile(pFile)^.pFd^.pReal, pSize);
end;

function tvfsLock(pFile: Psqlite3_file; eLock: cint): cint; cdecl;
var
  pFd  : PTestvfsFd;
  p    : PTestvfs;
  zLock: array[0..29] of AnsiChar;
begin
  pFd := PTestvfsFile(pFile)^.pFd;
  p := PTestvfs(pFd^.pVfs^.pAppData);
  if (p^.pScript <> nil) and ((p^.mask and TESTVFS_LOCK_MASK) <> 0) then begin
    StrPCopy(zLock, IntToStr(eLock));
    tvfsExecTcl(p, 'xLock', Tcl_NewStringObj(pFd^.zFilename, -1),
      Tcl_NewStringObj(zLock, -1), nil, nil);
  end;
  if ((p^.mask and TESTVFS_LOCK_MASK) <> 0) and (tvfsInjectIoerr(p) <> 0) then begin
    Result := SQLITE_IOERR_LOCK; Exit;
  end;
  Result := sqlite3OsLock(pFd^.pReal, eLock);
end;

function tvfsUnlock(pFile: Psqlite3_file; eLock: cint): cint; cdecl;
var
  pFd  : PTestvfsFd;
  p    : PTestvfs;
  zLock: array[0..29] of AnsiChar;
begin
  pFd := PTestvfsFile(pFile)^.pFd;
  p := PTestvfs(pFd^.pVfs^.pAppData);
  if (p^.pScript <> nil) and ((p^.mask and TESTVFS_UNLOCK_MASK) <> 0) then begin
    StrPCopy(zLock, IntToStr(eLock));
    tvfsExecTcl(p, 'xUnlock', Tcl_NewStringObj(pFd^.zFilename, -1),
      Tcl_NewStringObj(zLock, -1), nil, nil);
  end;
  if ((p^.mask and TESTVFS_UNLOCK_MASK) <> 0) and (tvfsInjectIoerr(p) <> 0) then begin
    Result := SQLITE_IOERR_UNLOCK; Exit;
  end;
  Result := sqlite3OsUnlock(pFd^.pReal, eLock);
end;

function tvfsCheckReservedLock(pFile: Psqlite3_file; pResOut: PcInt): cint; cdecl;
var
  pFd: PTestvfsFd;
  p  : PTestvfs;
begin
  pFd := PTestvfsFile(pFile)^.pFd;
  p := PTestvfs(pFd^.pVfs^.pAppData);
  if (p^.pScript <> nil) and ((p^.mask and TESTVFS_CKLOCK_MASK) <> 0) then
    tvfsExecTcl(p, 'xCheckReservedLock',
      Tcl_NewStringObj(pFd^.zFilename, -1), nil, nil, nil);
  Result := sqlite3OsCheckReservedLock(pFd^.pReal, pResOut);
end;

function tvfsFileControl(pFile: Psqlite3_file; op: cint; pArg: Pointer): cint; cdecl;
type
  TPCharArray = array[0..2] of PChar;
  PPCharArray = ^TPCharArray;
const
  aFnctl: array[0..2] of cint = (
    SQLITE_FCNTL_BEGIN_ATOMIC_WRITE,
    SQLITE_FCNTL_COMMIT_ATOMIC_WRITE,
    SQLITE_FCNTL_ZIPVFS);
  aFnctlName: array[0..2] of PChar = (
    'BEGIN_ATOMIC_WRITE',
    'COMMIT_ATOMIC_WRITE',
    'ZIPVFS');
var
  pFd : PTestvfsFd;
  p   : PTestvfs;
  argv: PPCharArray;
  rc  : cint;
  z   : PChar;
  x   : cint;
  i   : cint;
begin
  pFd := PTestvfsFile(pFile)^.pFd;
  p := PTestvfs(pFd^.pVfs^.pAppData);
  if op = SQLITE_FCNTL_PRAGMA then
  begin
    argv := PPCharArray(pArg);
    if sqlite3_stricmp(argv^[1], 'error') = 0 then
    begin
      rc := SQLITE_ERROR;
      if argv^[2] <> nil then
      begin
        z := argv^[2];
        x := sqlite3Atoi(z);
        if x <> 0 then
        begin
          rc := x;
          while sqlite3Isdigit(u8(z[0])) <> 0 do Inc(z);
          while sqlite3Isspace(u8(z[0])) <> 0 do Inc(z);
        end;
        if z[0] <> #0 then
          argv^[0] := sqlite3_mprintf(z);
      end;
      Result := rc;
      Exit;
    end;
    if sqlite3_stricmp(argv^[1], 'filename') = 0 then
    begin
      argv^[0] := sqlite3_mprintf(pFd^.zFilename);
      Result := SQLITE_OK;
      Exit;
    end;
  end;
  if (p^.pScript <> nil) and ((p^.mask and TESTVFS_FCNTL_MASK) <> 0) then
  begin
    i := 0;
    while i < 3 do
    begin
      if op = aFnctl[i] then Break;
      Inc(i);
    end;
    if i < 3 then
    begin
      rc := 0;
      tvfsExecTcl(p, 'xFileControl',
        Tcl_NewStringObj(pFd^.zFilename, -1),
        Tcl_NewStringObj(aFnctlName[i], -1),
        nil, nil);
      tvfsResultCode(p, rc);
      if rc <> 0 then
      begin
        if rc < 0 then Result := SQLITE_OK else Result := rc;
        Exit;
      end;
    end;
  end;
  Result := sqlite3OsFileControl(pFd^.pReal, op, pArg);
end;

function tvfsSectorSize(pFile: Psqlite3_file): cint; cdecl;
var
  pFd: PTestvfsFd;
  p  : PTestvfs;
begin
  pFd := PTestvfsFile(pFile)^.pFd;
  p := PTestvfs(pFd^.pVfs^.pAppData);
  if p^.iSectorsize >= 0 then begin
    Result := p^.iSectorsize; Exit;
  end;
  Result := sqlite3OsSectorSize(pFd^.pReal);
end;

function tvfsDeviceCharacteristics(pFile: Psqlite3_file): cint; cdecl;
var
  pFd: PTestvfsFd;
  p  : PTestvfs;
begin
  pFd := PTestvfsFile(pFile)^.pFd;
  p := PTestvfs(pFd^.pVfs^.pAppData);
  if p^.iDevchar >= 0 then begin
    Result := p^.iDevchar; Exit;
  end;
  Result := sqlite3OsDeviceCharacteristics(pFd^.pReal);
end;

{ ============================================================
  sqlite3_vfs implementations.
  ============================================================ }

function tvfsOpen(pVfs: Psqlite3_vfs; zName: sqlite3_filename;
  pFile: Psqlite3_file; flags: cint; pOutFlags: PcInt): cint; cdecl;
var
  pTestfile: PTestvfsFile;
  pFd      : PTestvfsFd;
  p        : PTestvfs;
  pId      : PTclObj;
  pParent  : Psqlite3_vfs;
  rc       : cint;
  pMethods : Psqlite3_io_methods;
  pArg     : PTclObj;
  z        : PChar;
begin
  pTestfile := PTestvfsFile(pFile);
  p := PTestvfs(pVfs^.pAppData);
  pParent := p^.pParent;
  pId := nil;

  pFd := PTestvfsFd(ckalloc(cuint(SizeOf(TTestvfsFd) + pParent^.szOsFile)));
  FillChar(pFd^, SizeOf(TTestvfsFd) + pParent^.szOsFile, 0);
  pFd^.zFilename := zName;
  pFd^.pVfs := pVfs;
  pFd^.pReal := Psqlite3_file(PChar(pFd) + SizeOf(TTestvfsFd));
  FillChar(pTestfile^, SizeOf(TTestvfsFile), 0);
  pTestfile^.pFd := pFd;

  Tcl_ResetResult(p^.interp);
  if (p^.pScript <> nil) and ((p^.mask and TESTVFS_OPEN_MASK) <> 0) then begin
    { test_vfs.c:636..648 — build the key-value-args list.  For a MAIN_DB
      open, walk the NUL-separated URI parameter pairs stored immediately
      past the filename's terminating NUL and append each as a list element. }
    pArg := Tcl_NewObj;
    Tcl_IncrRefCount(pArg);
    if (flags and SQLITE_OPEN_MAIN_DB) <> 0 then begin
      z := PChar(zName) + strlen(PChar(zName)) + 1;
      while z^ <> #0 do begin
        Tcl_ListObjAppendElement(nil, pArg, Tcl_NewStringObj(z, -1));
        z := z + strlen(z) + 1;
        Tcl_ListObjAppendElement(nil, pArg, Tcl_NewStringObj(z, -1));
        z := z + strlen(z) + 1;
      end;
    end;
    tvfsExecTcl(p, 'xOpen', Tcl_NewStringObj(pFd^.zFilename, -1),
      pArg, nil, nil);
    Tcl_DecrRefCount(pArg);
    if tvfsResultCode(p, rc) <> 0 then begin
      if rc <> SQLITE_OK then begin
        ckfree(pFd);
        pTestfile^.pFd := nil;
        Result := rc;
        Exit;
      end;
    end else
      pId := Tcl_GetObjResult(p^.interp);
  end;

  if ((p^.mask and TESTVFS_OPEN_MASK) <> 0) and (tvfsInjectIoerr(p) <> 0) then begin
    ckfree(pFd); pTestfile^.pFd := nil; Result := SQLITE_IOERR; Exit;
  end;
  if tvfsInjectCantopenerr(p) <> 0 then begin
    ckfree(pFd); pTestfile^.pFd := nil; Result := SQLITE_CANTOPEN; Exit;
  end;
  if tvfsInjectFullerr(p) <> 0 then begin
    ckfree(pFd); pTestfile^.pFd := nil; Result := SQLITE_FULL; Exit;
  end;

  if pId = nil then
    pId := Tcl_NewStringObj('anon', -1);
  Tcl_IncrRefCount(pId);
  pFd^.pShmId := pId;
  Tcl_ResetResult(p^.interp);

  rc := sqlite3OsOpen(pParent, zName, pFd^.pReal, flags, pOutFlags);
  if (pFd^.pReal^.pMethods <> nil) then begin
    { test_vfs.c:673..688.  For iVersion>1 copy the full methods table;
      for iVersion 1 the shm slots stay nil (they live past the v1 layout).
      The whole table is zero-filled first either way. }
    pMethods := Psqlite3_io_methods(ckalloc(SizeOf(sqlite3_io_methods)));
    FillChar(pMethods^, SizeOf(sqlite3_io_methods), 0);
    if pVfs^.iVersion > 1 then
      Move(tvfs_io_methods, pMethods^, SizeOf(sqlite3_io_methods))
    else
      { Only the v1 prefix (through xDeviceCharacteristics) — leave the
        shm/fetch slots nil by copying just the leading methods. }
      Move(tvfs_io_methods, pMethods^,
        PtrUInt(@tvfs_io_methods.xShmMap) - PtrUInt(@tvfs_io_methods));
    pMethods^.iVersion := pFd^.pReal^.pMethods^.iVersion;
    if pMethods^.iVersion > pVfs^.iVersion then
      pMethods^.iVersion := pVfs^.iVersion;
    { test_vfs.c:683..688 — only suppress shm when -noshm is set. }
    if (pVfs^.iVersion > 1) and (p^.isNoshm <> 0) then begin
      pMethods^.xShmUnmap := nil;
      pMethods^.xShmLock := nil;
      pMethods^.xShmBarrier := nil;
      pMethods^.xShmMap := nil;
    end;
    { xFetch/xUnfetch not wired in this port (see InitIoMethodsTable). }
    pMethods^.xFetch := nil;
    pMethods^.xUnfetch := nil;
    pFile^.pMethods := pMethods;
  end;
  Result := rc;
end;

function tvfsDelete(pVfs: Psqlite3_vfs; zPath: PChar; dirSync: cint): cint; cdecl;
var
  p : PTestvfs;
  rc: cint;
begin
  rc := SQLITE_OK;
  p := PTestvfs(pVfs^.pAppData);
  if (p^.pScript <> nil) and ((p^.mask and TESTVFS_DELETE_MASK) <> 0) then begin
    tvfsExecTcl(p, 'xDelete',
      Tcl_NewStringObj(zPath, -1), Tcl_NewIntObj(dirSync), nil, nil);
    tvfsResultCode(p, rc);
  end;
  if rc = SQLITE_OK then
    rc := sqlite3OsDelete(p^.pParent, zPath, dirSync);
  Result := rc;
end;

function tvfsAccess(pVfs: Psqlite3_vfs; zPath: PChar; flags: cint; pResOut: PcInt): cint; cdecl;
var
  p   : PTestvfs;
  rc  : cint;
  zArg: PChar;
  bRes: cint;
begin
  p := PTestvfs(pVfs^.pAppData);
  if (p^.pScript <> nil) and ((p^.mask and TESTVFS_ACCESS_MASK) <> 0) then begin
    zArg := nil;
    case flags of
      SQLITE_ACCESS_EXISTS:    zArg := 'SQLITE_ACCESS_EXISTS';
      SQLITE_ACCESS_READWRITE: zArg := 'SQLITE_ACCESS_READWRITE';
      SQLITE_ACCESS_READ:      zArg := 'SQLITE_ACCESS_READ';
    end;
    tvfsExecTcl(p, 'xAccess',
      Tcl_NewStringObj(zPath, -1), Tcl_NewStringObj(zArg, -1), nil, nil);
    if tvfsResultCode(p, rc) <> 0 then begin
      if rc <> SQLITE_OK then begin Result := rc; Exit; end;
    end else begin
      bRes := 0;
      if Tcl_GetBooleanFromObj(nil, Tcl_GetObjResult(p^.interp), @bRes) = TCL_OK then begin
        pResOut^ := bRes;
        Result := SQLITE_OK; Exit;
      end;
    end;
  end;
  Result := sqlite3OsAccess(p^.pParent, zPath, flags, pResOut);
end;

function tvfsFullPathname(pVfs: Psqlite3_vfs; zPath: PChar; nOut: cint; zOut: PChar): cint; cdecl;
var
  p : PTestvfs;
  rc: cint;
begin
  p := PTestvfs(pVfs^.pAppData);
  if (p^.pScript <> nil) and ((p^.mask and TESTVFS_FULLPATHNAME_MASK) <> 0) then begin
    tvfsExecTcl(p, 'xFullPathname', Tcl_NewStringObj(zPath, -1), nil, nil, nil);
    if tvfsResultCode(p, rc) <> 0 then begin
      if rc <> SQLITE_OK then begin Result := rc; Exit; end;
    end;
  end;
  Result := sqlite3OsFullPathname(p^.pParent, zPath, nOut, zOut);
end;

function tvfsRandomness(pVfs: Psqlite3_vfs; nByte: cint; zOut: PChar): cint; cdecl;
var pP: Psqlite3_vfs;
begin
  pP := PTestvfs(pVfs^.pAppData)^.pParent;
  Result := pP^.xRandomness(pP, nByte, zOut);
end;

function tvfsSleep(pVfs: Psqlite3_vfs; nMicro: cint): cint; cdecl;
var pP: Psqlite3_vfs;
begin
  pP := PTestvfs(pVfs^.pAppData)^.pParent;
  Result := pP^.xSleep(pP, nMicro);
end;

function tvfsCurrentTime(pVfs: Psqlite3_vfs; pTime: PDouble): cint; cdecl;
var pP: Psqlite3_vfs;
begin
  pP := PTestvfs(pVfs^.pAppData)^.pParent;
  Result := pP^.xCurrentTime(pP, pTime);
end;

function tvfsGetLastError(pVfs: Psqlite3_vfs; n: cint; zBuf: PChar): cint; cdecl;
var pP: Psqlite3_vfs;
begin
  pP := PTestvfs(pVfs^.pAppData)^.pParent;
  if pP^.xGetLastError <> nil then
    Result := pP^.xGetLastError(pP, n, zBuf)
  else
    Result := 0;
end;

{ test_vfs.c:830..879 — tvfsShmOpen.  Search for (or create) the
  TestvfsBuffer for this filename and connect this handle to it. }
function tvfsShmOpen(pFile: Psqlite3_file): cint;
var
  p      : PTestvfs;
  rc     : cint;
  pBuf   : PTestvfsBuffer;
  pFd    : PTestvfsFd;
  szName : cint;
  nByte  : cint;
begin
  rc := SQLITE_OK;
  pFd := PTestvfsFile(pFile)^.pFd;
  p := PTestvfs(pFd^.pVfs^.pAppData);
  Assert(p^.isFullshm = 0);
  Assert((pFd^.pShmId <> nil) and (pFd^.pShm = nil) and (pFd^.pNext = nil));

  { Evaluate the Tcl script: SCRIPT xShmOpen FILENAME }
  Tcl_ResetResult(p^.interp);
  if (p^.pScript <> nil) and ((p^.mask and TESTVFS_SHMOPEN_MASK) <> 0) then begin
    tvfsExecTcl(p, 'xShmOpen', Tcl_NewStringObj(pFd^.zFilename, -1), nil, nil, nil);
    if tvfsResultCode(p, rc) <> 0 then
      if rc <> SQLITE_OK then begin Result := rc; Exit; end;
  end;

  Assert(rc = SQLITE_OK);
  if ((p^.mask and TESTVFS_SHMOPEN_MASK) <> 0) and (tvfsInjectIoerr(p) <> 0) then begin
    Result := SQLITE_IOERR; Exit;
  end;

  { Search for a TestvfsBuffer.  Create a new one if required. }
  pBuf := p^.pBuffer;
  while pBuf <> nil do begin
    if StrComp(pFd^.zFilename, pBuf^.zFile) = 0 then Break;
    pBuf := pBuf^.pNext;
  end;
  if pBuf = nil then begin
    szName := cint(StrLen(pFd^.zFilename));
    nByte := SizeOf(TTestvfsBuffer) + szName + 1;
    pBuf := PTestvfsBuffer(ckalloc(cuint(nByte)));
    FillChar(pBuf^, nByte, 0);
    pBuf^.zFile := PChar(PtrUInt(pBuf) + SizeOf(TTestvfsBuffer));
    Move(pFd^.zFilename^, pBuf^.zFile^, szName + 1);
    pBuf^.pNext := p^.pBuffer;
    p^.pBuffer := pBuf;
  end;

  { Connect the TestvfsBuffer to the new TestvfsShm handle and return. }
  pFd^.pNext := pBuf^.pFile;
  pBuf^.pFile := pFd;
  pFd^.pShm := pBuf;
  Result := rc;
end;

{ test_vfs.c:881..888 — tvfsAllocPage. }
procedure tvfsAllocPage(pBuf: PTestvfsBuffer; iPage: cint; pgsz: cint);
begin
  Assert(iPage < TESTVFS_MAX_PAGES);
  if pBuf^.aPage[iPage] = nil then begin
    pBuf^.aPage[iPage] := PByte(ckalloc(cuint(pgsz)));
    FillChar(pBuf^.aPage[iPage]^, pgsz, 0);
    pBuf^.pgsz := pgsz;
  end;
end;

{ test_vfs.c:890..939 — tvfsShmMap. }
function tvfsShmMap(pFile: Psqlite3_file; iPage: cint; pgsz: cint;
  isWrite: cint; pp: PPointer): cint; cdecl;
var
  rc   : cint;
  pFd  : PTestvfsFd;
  p    : PTestvfs;
  pReal: Psqlite3_file;
  pArg : PTclObj;
begin
  rc := SQLITE_OK;
  pFd := PTestvfsFile(pFile)^.pFd;
  p := PTestvfs(pFd^.pVfs^.pAppData);

  if p^.isFullshm <> 0 then begin
    pReal := pFd^.pReal;
    Result := pReal^.pMethods^.xShmMap(pReal, iPage, pgsz, isWrite, pp);
    Exit;
  end;

  if pFd^.pShm = nil then begin
    rc := tvfsShmOpen(pFile);
    if rc <> SQLITE_OK then begin Result := rc; Exit; end;
  end;

  if (p^.pScript <> nil) and ((p^.mask and TESTVFS_SHMMAP_MASK) <> 0) then begin
    pArg := Tcl_NewObj;
    Tcl_IncrRefCount(pArg);
    Tcl_ListObjAppendElement(p^.interp, pArg, Tcl_NewIntObj(iPage));
    Tcl_ListObjAppendElement(p^.interp, pArg, Tcl_NewIntObj(pgsz));
    Tcl_ListObjAppendElement(p^.interp, pArg, Tcl_NewIntObj(isWrite));
    tvfsExecTcl(p, 'xShmMap',
      Tcl_NewStringObj(pFd^.pShm^.zFile, -1), pFd^.pShmId, pArg, nil);
    tvfsResultCode(p, rc);
    Tcl_DecrRefCount(pArg);
  end;
  if (rc = SQLITE_OK) and ((p^.mask and TESTVFS_SHMMAP_MASK) <> 0)
     and (tvfsInjectIoerr(p) <> 0) then
    rc := SQLITE_IOERR;

  if (rc = SQLITE_OK) and (isWrite <> 0) and (pFd^.pShm^.aPage[iPage] = nil) then
    tvfsAllocPage(pFd^.pShm, iPage, pgsz);
  if (rc = SQLITE_OK) or (rc = SQLITE_READONLY) then
    pp^ := Pointer(pFd^.pShm^.aPage[iPage]);

  Result := rc;
end;

{ test_vfs.c:942..1008 — tvfsShmLock. }
function tvfsShmLock(pFile: Psqlite3_file; ofst: cint; n: cint;
  flags: cint): cint; cdecl;
var
  rc    : cint;
  pFd   : PTestvfsFd;
  p     : PTestvfs;
  zLock : array[0..79] of AnsiChar;
  s     : AnsiString;
  isLock: cint;
  isExcl: cint;
  mask  : cuint;
  p2    : PTestvfsFd;
begin
  rc := SQLITE_OK;
  pFd := PTestvfsFile(pFile)^.pFd;
  p := PTestvfs(pFd^.pVfs^.pAppData);

  if p^.isFullshm <> 0 then begin
    Result := pFd^.pReal^.pMethods^.xShmLock(pFd^.pReal, ofst, n, flags);
    Exit;
  end;

  if (p^.pScript <> nil) and ((p^.mask and TESTVFS_SHMLOCK_MASK) <> 0) then begin
    s := IntToStr(ofst) + ' ' + IntToStr(n);
    if (flags and SQLITE_SHM_LOCK) <> 0 then s := s + ' lock'
    else s := s + ' unlock';
    if (flags and SQLITE_SHM_SHARED) <> 0 then s := s + ' shared'
    else s := s + ' exclusive';
    StrPLCopy(zLock, s, SizeOf(zLock) - 1);
    tvfsExecTcl(p, 'xShmLock',
      Tcl_NewStringObj(pFd^.pShm^.zFile, -1), pFd^.pShmId,
      Tcl_NewStringObj(zLock, -1), nil);
    tvfsResultCode(p, rc);
  end;

  if (rc = SQLITE_OK) and ((p^.mask and TESTVFS_SHMLOCK_MASK) <> 0)
     and (tvfsInjectIoerr(p) <> 0) then
    rc := SQLITE_IOERR;

  if rc = SQLITE_OK then begin
    isLock := flags and SQLITE_SHM_LOCK;
    isExcl := flags and SQLITE_SHM_EXCLUSIVE;
    mask := (cuint(cuint(1) shl n) - 1) shl ofst;
    if isLock <> 0 then begin
      p2 := pFd^.pShm^.pFile;
      while p2 <> nil do begin
        if p2 <> pFd then begin
          if ((p2^.excllock and mask) <> 0)
             or ((isExcl <> 0) and ((p2^.sharedlock and mask) <> 0)) then begin
            rc := SQLITE_BUSY;
            Break;
          end;
        end;
        p2 := p2^.pNext;
      end;
      if rc = SQLITE_OK then begin
        if isExcl <> 0 then pFd^.excllock := pFd^.excllock or mask;
        if isExcl = 0 then pFd^.sharedlock := pFd^.sharedlock or mask;
      end;
    end else begin
      if isExcl <> 0 then pFd^.excllock := pFd^.excllock and (not mask);
      if isExcl = 0 then pFd^.sharedlock := pFd^.sharedlock and (not mask);
    end;
  end;

  Result := rc;
end;

{ test_vfs.c:1010..1024 — tvfsShmBarrier. }
procedure tvfsShmBarrier(pFile: Psqlite3_file); cdecl;
var
  pFd: PTestvfsFd;
  p  : PTestvfs;
  z  : PChar;
begin
  pFd := PTestvfsFile(pFile)^.pFd;
  p := PTestvfs(pFd^.pVfs^.pAppData);

  if (p^.pScript <> nil) and ((p^.mask and TESTVFS_SHMBARRIER_MASK) <> 0) then begin
    if pFd^.pShm <> nil then z := pFd^.pShm^.zFile else z := '';
    tvfsExecTcl(p, 'xShmBarrier', Tcl_NewStringObj(z, -1), pFd^.pShmId, nil, nil);
  end;

  if p^.isFullshm <> 0 then begin
    pFd^.pReal^.pMethods^.xShmBarrier(pFd^.pReal);
    Exit;
  end;
end;

{ test_vfs.c:1026..1071 — tvfsShmUnmap. }
function tvfsShmUnmap(pFile: Psqlite3_file; deleteFlag: cint): cint; cdecl;
var
  rc    : cint;
  pFd   : PTestvfsFd;
  p     : PTestvfs;
  pBuf  : PTestvfsBuffer;
  ppFd  : PPTestvfsFd;
  i     : cint;
  ppBuf : PPTestvfsBuffer;
begin
  rc := SQLITE_OK;
  pFd := PTestvfsFile(pFile)^.pFd;
  p := PTestvfs(pFd^.pVfs^.pAppData);
  pBuf := pFd^.pShm;

  if p^.isFullshm <> 0 then begin
    Result := pFd^.pReal^.pMethods^.xShmUnmap(pFd^.pReal, deleteFlag);
    Exit;
  end;

  if pBuf = nil then begin Result := SQLITE_OK; Exit; end;
  Assert((pFd^.pShmId <> nil) and (pFd^.pShm <> nil));

  if (p^.pScript <> nil) and ((p^.mask and TESTVFS_SHMCLOSE_MASK) <> 0) then begin
    tvfsExecTcl(p, 'xShmUnmap',
      Tcl_NewStringObj(pFd^.pShm^.zFile, -1), pFd^.pShmId, nil, nil);
    tvfsResultCode(p, rc);
  end;

  { Unlink this handle from the buffer's list. }
  ppFd := @pBuf^.pFile;
  while ppFd^ <> pFd do
    ppFd := @(ppFd^^.pNext);
  Assert(ppFd^ = pFd);
  ppFd^ := pFd^.pNext;
  pFd^.pNext := nil;

  if pBuf^.pFile = nil then begin
    ppBuf := @p^.pBuffer;
    while ppBuf^ <> pBuf do
      ppBuf := @(ppBuf^^.pNext);
    ppBuf^ := ppBuf^^.pNext;
    i := 0;
    while (i < TESTVFS_MAX_PAGES) and (pBuf^.aPage[i] <> nil) do begin
      ckfree(pBuf^.aPage[i]);
      Inc(i);
    end;
    ckfree(pBuf);
  end;
  pFd^.pShm := nil;

  Result := rc;
end;

procedure InitIoMethodsTable;
begin
  FillChar(tvfs_io_methods, SizeOf(tvfs_io_methods), 0);
  tvfs_io_methods.iVersion              := 3;
  tvfs_io_methods.xClose                := @tvfsClose;
  tvfs_io_methods.xRead                 := @tvfsRead;
  tvfs_io_methods.xWrite                := @tvfsWrite;
  tvfs_io_methods.xTruncate             := @tvfsTruncate;
  tvfs_io_methods.xSync                 := @tvfsSync;
  tvfs_io_methods.xFileSize             := @tvfsFileSize;
  tvfs_io_methods.xLock                 := @tvfsLock;
  tvfs_io_methods.xUnlock               := @tvfsUnlock;
  tvfs_io_methods.xCheckReservedLock    := @tvfsCheckReservedLock;
  tvfs_io_methods.xFileControl          := @tvfsFileControl;
  tvfs_io_methods.xSectorSize           := @tvfsSectorSize;
  tvfs_io_methods.xDeviceCharacteristics:= @tvfsDeviceCharacteristics;
  tvfs_io_methods.xShmMap               := @tvfsShmMap;
  tvfs_io_methods.xShmLock              := @tvfsShmLock;
  tvfs_io_methods.xShmBarrier           := @tvfsShmBarrier;
  tvfs_io_methods.xShmUnmap             := @tvfsShmUnmap;
  { xFetch/xUnfetch left nil — Pascal port does not exercise mmap I/O
    through the wrapper (C wires tvfsFetch/tvfsUnfetch; omitted here as
    no target test memory-maps through testvfs). }
end;

{ ============================================================
  test_vfs.c:1084..1396 — testvfs_obj_cmd: per-VFS subcommand dispatch.
  ============================================================ }

function testvfsObjCmd(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
const
  CMD_SHM         = 0;
  CMD_DELETE      = 1;
  CMD_FILTER      = 2;
  CMD_IOERR       = 3;
  CMD_SCRIPT      = 4;
  CMD_DEVCHAR     = 5;
  CMD_SECTORSIZE  = 6;
  CMD_FULLERR     = 7;
  CMD_CANTOPENERR = 8;
  N_SUB = 9;
  aSubcmd: array[0..N_SUB-1] of PChar = (
    'shm', 'delete', 'filter', 'ioerr', 'script',
    'devchar', 'sectorsize', 'fullerr', 'cantopenerr'
  );
  aFlagName: array[0..14] of PChar = (
    'default', 'atomic', 'atomic512', 'atomic1k', 'atomic2k',
    'atomic4k', 'atomic8k', 'atomic16k', 'atomic32k', 'atomic64k',
    'sequential', 'safe_append', 'undeletable_when_open',
    'powersafe_overwrite', 'immutable'
  );
  aFlagValue: array[0..14] of cint = (
    -1,
    SQLITE_IOCAP_ATOMIC,
    SQLITE_IOCAP_ATOMIC512, SQLITE_IOCAP_ATOMIC1K, SQLITE_IOCAP_ATOMIC2K,
    SQLITE_IOCAP_ATOMIC4K, SQLITE_IOCAP_ATOMIC8K, SQLITE_IOCAP_ATOMIC16K,
    SQLITE_IOCAP_ATOMIC32K, SQLITE_IOCAP_ATOMIC64K,
    SQLITE_IOCAP_SEQUENTIAL, SQLITE_IOCAP_SAFE_APPEND,
    SQLITE_IOCAP_UNDELETABLE_WHEN_OPEN, SQLITE_IOCAP_POWERSAFE_OVERWRITE,
    SQLITE_IOCAP_IMMUTABLE
  );
  N_METHOD = 19;
  aMethodName: array[0..N_METHOD-1] of PChar = (
    'xShmOpen', 'xShmLock', 'xShmBarrier', 'xShmUnmap', 'xShmMap',
    'xSync', 'xDelete', 'xWrite', 'xRead', 'xTruncate', 'xOpen',
    'xClose', 'xAccess', 'xFullPathname', 'xUnlock', 'xLock',
    'xCheckReservedLock', 'xFileControl', 'xSleep'
  );
  aMethodMask: array[0..N_METHOD-1] of cint = (
    TESTVFS_SHMOPEN_MASK, TESTVFS_SHMLOCK_MASK, TESTVFS_SHMBARRIER_MASK,
    TESTVFS_SHMCLOSE_MASK, TESTVFS_SHMMAP_MASK,
    TESTVFS_SYNC_MASK, TESTVFS_DELETE_MASK, TESTVFS_WRITE_MASK,
    TESTVFS_READ_MASK, TESTVFS_TRUNCATE_MASK, TESTVFS_OPEN_MASK,
    TESTVFS_CLOSE_MASK, TESTVFS_ACCESS_MASK, TESTVFS_FULLPATHNAME_MASK,
    TESTVFS_UNLOCK_MASK, TESTVFS_LOCK_MASK, TESTVFS_CKLOCK_MASK,
    TESTVFS_FCNTL_MASK, TESTVFS_SLEEP_MASK
  );
var
  p       : PTestvfs;
  eCmd    : cint;
  zSub    : PChar;
  i       : cint;
  pFault  : PTestFaultInject;
  iCnt    : cint;
  iPersist: cint;
  iRet    : cint;
  apElem  : PPTclObj;
  nElem   : cint;
  newMask : cint;
  iMethod : cint;
  zMet    : PChar;
  flagsList: PPTclObj;
  nFlags  : cint;
  j       : cint;
  iNew    : cint;
  iFlag   : cint;
  pRet    : PTclObj;
  zFlag   : PChar;
  found   : Boolean;
  nByte   : cint;
  pScriptObj: PTclObj;
begin
  p := PTestvfs(clientData);

  if objc < 2 then begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('SUBCOMMAND ...'));
    Result := TCL_ERROR; Exit;
  end;

  zSub := Tcl_GetString(objAt(objv, 1));
  eCmd := -1;
  for i := 0 to N_SUB - 1 do
    if StrComp(zSub, aSubcmd[i]) = 0 then begin
      eCmd := i; Break;
    end;
  if eCmd < 0 then begin
    Tcl_AppendResult(interp, PChar('bad subcommand "'),
      zSub, PChar('": must be one of: filter script ioerr fullerr cantopenerr devchar sectorsize delete'), nil);
    Result := TCL_ERROR; Exit;
  end;
  Tcl_ResetResult(interp);

  case eCmd of
    CMD_FILTER:
    begin
      if objc <> 3 then begin
        Tcl_WrongNumArgs(interp, 2, objv, PChar('LIST'));
        Result := TCL_ERROR; Exit;
      end;
      apElem := nil; nElem := 0;
      if Tcl_ListObjGetElements(interp, objAt(objv, 2), @nElem, @apElem) <> TCL_OK then begin
        Result := TCL_ERROR; Exit;
      end;
      newMask := 0;
      Tcl_ResetResult(interp);
      for i := 0 to nElem - 1 do begin
        zMet := Tcl_GetString(PPTclObj(PtrUInt(apElem) + PtrUInt(i) * SizeOf(Pointer))^);
        found := False;
        for iMethod := 0 to N_METHOD - 1 do
          if StrComp(zMet, aMethodName[iMethod]) = 0 then begin
            newMask := newMask or aMethodMask[iMethod];
            found := True;
            Break;
          end;
        if not found then begin
          Tcl_AppendResult(interp, PChar('unknown method: '), zMet, nil);
          Result := TCL_ERROR; Exit;
        end;
      end;
      p^.mask := newMask;
      Result := TCL_OK; Exit;
    end;

    CMD_SCRIPT:
    begin
      if objc = 3 then begin
        if p^.pScript <> nil then begin
          Tcl_DecrRefCount(p^.pScript);
          p^.pScript := nil;
        end;
        nByte := 0;
        Tcl_GetStringFromObj(objAt(objv, 2), @nByte);
        if nByte > 0 then begin
          p^.pScript := Tcl_DuplicateObj(objAt(objv, 2));
          Tcl_IncrRefCount(p^.pScript);
        end;
      end else if objc <> 2 then begin
        Tcl_WrongNumArgs(interp, 2, objv, PChar('?SCRIPT?'));
        Result := TCL_ERROR; Exit;
      end;
      Tcl_ResetResult(interp);
      if p^.pScript <> nil then Tcl_SetObjResult(interp, p^.pScript);
      Result := TCL_OK; Exit;
    end;

    CMD_IOERR, CMD_FULLERR, CMD_CANTOPENERR:
    begin
      case eCmd of
        CMD_IOERR:       pFault := @p^.ioerr_err;
        CMD_FULLERR:     pFault := @p^.full_err;
        CMD_CANTOPENERR: pFault := @p^.cantopen_err;
      else
        pFault := @p^.ioerr_err;
      end;
      iRet := pFault^.nFail;
      pFault^.nFail := 0;
      pFault^.eFault := 0;
      pFault^.iCnt := 0;
      if objc = 4 then begin
        iCnt := 0; iPersist := 0;
        if Tcl_GetIntFromObj(interp, objAt(objv, 2), @iCnt) <> TCL_OK then begin
          Result := TCL_ERROR; Exit;
        end;
        if Tcl_GetBooleanFromObj(interp, objAt(objv, 3), @iPersist) <> TCL_OK then begin
          Result := TCL_ERROR; Exit;
        end;
        if iPersist <> 0 then
          pFault^.eFault := FAULT_INJECT_PERSISTENT
        else
          pFault^.eFault := FAULT_INJECT_TRANSIENT;
        pFault^.iCnt := iCnt;
      end else if objc <> 2 then begin
        Tcl_WrongNumArgs(interp, 2, objv, PChar('?CNT PERSIST?'));
        Result := TCL_ERROR; Exit;
      end;
      Tcl_SetObjResult(interp, Tcl_NewIntObj(iRet));
      Result := TCL_OK; Exit;
    end;

    CMD_DELETE:
    begin
      { test_vfs.c:1304..1307 — delete the Tcl command, which triggers
        the cmd-delete hook (testvfs_obj_del) which unregisters the VFS
        and frees the Testvfs object. }
      Tcl_DeleteCommand(interp, Tcl_GetString(objAt(objv, 0)));
      Result := TCL_OK; Exit;
    end;

    CMD_DEVCHAR:
    begin
      if objc > 3 then begin
        Tcl_WrongNumArgs(interp, 2, objv, PChar('?ATTR-LIST?'));
        Result := TCL_ERROR; Exit;
      end;
      if objc = 3 then begin
        flagsList := nil; nFlags := 0;
        if Tcl_ListObjGetElements(interp, objAt(objv, 2), @nFlags, @flagsList) <> TCL_OK then begin
          Result := TCL_ERROR; Exit;
        end;
        iNew := 0;
        for j := 0 to nFlags - 1 do begin
          zFlag := Tcl_GetString(PPTclObj(PtrUInt(flagsList) + PtrUInt(j) * SizeOf(Pointer))^);
          found := False;
          for iFlag := 0 to High(aFlagName) do
            if StrComp(zFlag, aFlagName[iFlag]) = 0 then begin
              if (aFlagValue[iFlag] < 0) and (nFlags > 1) then begin
                Tcl_AppendResult(interp, PChar('bad flags: '),
                  Tcl_GetString(objAt(objv, 2)), nil);
                Result := TCL_ERROR; Exit;
              end;
              iNew := iNew or aFlagValue[iFlag];
              found := True; Break;
            end;
          if not found then begin
            Tcl_AppendResult(interp, PChar('unknown flag: '), zFlag, nil);
            Result := TCL_ERROR; Exit;
          end;
        end;
        p^.iDevchar := iNew or $10000000;
      end;
      pRet := Tcl_NewObj;
      for iFlag := 0 to High(aFlagName) do
        if (p^.iDevchar and aFlagValue[iFlag]) <> 0 then
          Tcl_ListObjAppendElement(interp, pRet,
            Tcl_NewStringObj(aFlagName[iFlag], -1));
      Tcl_SetObjResult(interp, pRet);
      Result := TCL_OK; Exit;
    end;

    CMD_SECTORSIZE:
    begin
      if objc > 3 then begin
        Tcl_WrongNumArgs(interp, 2, objv, PChar('?VALUE?'));
        Result := TCL_ERROR; Exit;
      end;
      if objc = 3 then begin
        iNew := 0;
        if Tcl_GetIntFromObj(interp, objAt(objv, 2), @iNew) <> TCL_OK then begin
          Result := TCL_ERROR; Exit;
        end;
        p^.iSectorsize := iNew;
      end;
      Tcl_SetObjResult(interp, Tcl_NewIntObj(p^.iSectorsize));
      Result := TCL_OK; Exit;
    end;

    CMD_SHM:
    begin
      { Not implemented — none of the four target tests use it. }
      Tcl_AppendResult(interp, PChar('testvfs subcommand "shm" not implemented in pas-sqlite3'), nil);
      Result := TCL_ERROR; Exit;
    end;
  end;
  Result := TCL_OK;
  if pScriptObj = nil then ; { suppress unused-var hint }
end;

{ test_vfs.c:1398..1406 — testvfs_obj_del.  Cmd-delete hook: unregister
  the VFS, free the Testvfs.  Called by Tcl when the named object cmd
  goes away (interp exit, or via [VFSNAME delete]). }
procedure testvfsObjDel(clientData: TClientData); cdecl;
var
  p: PTestvfs;
begin
  p := PTestvfs(clientData);
  if p^.pScript <> nil then Tcl_DecrRefCount(p^.pScript);
  sqlite3_vfs_unregister(p^.pVfs);
  FillChar(p^.pVfs^, SizeOf(sqlite3_vfs), 0);
  ckfree(p^.pVfs);
  FillChar(p^, SizeOf(TTestvfs), 0);
  ckfree(p);
end;

{ ============================================================
  test_vfs.c:1443..1583 — testvfs_cmd: top-level constructor.
  ============================================================ }

function testvfsCmd(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  p           : PTestvfs;
  pVfs        : Psqlite3_vfs;
  zVfs        : PChar;
  nByte       : cint;
  nVfs        : cint;
  i           : cint;
  isNoshm     : cint;
  isFullshm   : cint;
  isDefault   : cint;
  szOsFile    : cint;
  mxPathname  : cint;
  iVersion    : cint;
  nSwitch     : cint;
  zSwitch     : PChar;
  badArgs     : Boolean;
begin
  isNoshm := 0; isFullshm := 0; isDefault := 0;
  szOsFile := 0; mxPathname := -1; iVersion := 3;
  badArgs := False;

  if (objc < 2) or ((objc mod 2) <> 0) then begin
    badArgs := True;
  end else begin
    i := 2;
    while i < objc do begin
      nSwitch := 0;
      zSwitch := Tcl_GetStringFromObj(objAt(objv, i), @nSwitch);
      if (nSwitch > 2) and (StrLComp(zSwitch, '-noshm', nSwitch) = 0) then begin
        if Tcl_GetBooleanFromObj(interp, objAt(objv, i + 1), @isNoshm) <> TCL_OK then begin
          Result := TCL_ERROR; Exit;
        end;
        if isNoshm <> 0 then isFullshm := 0;
      end
      else if (nSwitch > 2) and (StrLComp(zSwitch, '-default', nSwitch) = 0) then begin
        if Tcl_GetBooleanFromObj(interp, objAt(objv, i + 1), @isDefault) <> TCL_OK then begin
          Result := TCL_ERROR; Exit;
        end;
      end
      else if (nSwitch > 2) and (StrLComp(zSwitch, '-szosfile', nSwitch) = 0) then begin
        if Tcl_GetIntFromObj(interp, objAt(objv, i + 1), @szOsFile) <> TCL_OK then begin
          Result := TCL_ERROR; Exit;
        end;
      end
      else if (nSwitch > 2) and (StrLComp(zSwitch, '-mxpathname', nSwitch) = 0) then begin
        if Tcl_GetIntFromObj(interp, objAt(objv, i + 1), @mxPathname) <> TCL_OK then begin
          Result := TCL_ERROR; Exit;
        end;
      end
      else if (nSwitch > 2) and (StrLComp(zSwitch, '-iversion', nSwitch) = 0) then begin
        if Tcl_GetIntFromObj(interp, objAt(objv, i + 1), @iVersion) <> TCL_OK then begin
          Result := TCL_ERROR; Exit;
        end;
      end
      else if (nSwitch > 2) and (StrLComp(zSwitch, '-fullshm', nSwitch) = 0) then begin
        if Tcl_GetBooleanFromObj(interp, objAt(objv, i + 1), @isFullshm) <> TCL_OK then begin
          Result := TCL_ERROR; Exit;
        end;
        if isFullshm <> 0 then isNoshm := 0;
      end
      else begin
        badArgs := True; Break;
      end;
      Inc(i, 2);
    end;
  end;
  if badArgs then begin
    Tcl_WrongNumArgs(interp, 1, objv,
      PChar('VFSNAME ?-noshm BOOL? ?-fullshm BOOL? ?-default BOOL? ?-mxpathname INT? ?-szosfile INT? ?-iversion INT?'));
    Result := TCL_ERROR; Exit;
  end;

  if szOsFile < SizeOf(TTestvfsFile) then
    szOsFile := SizeOf(TTestvfsFile);

  zVfs := Tcl_GetString(objAt(objv, 1));
  nVfs := StrLen(zVfs);
  nByte := SizeOf(TTestvfs) + nVfs + 1;
  p := PTestvfs(ckalloc(nByte));
  FillChar(p^, nByte, 0);
  p^.iDevchar := -1;
  p^.iSectorsize := -1;

  { Tcl_CreateObjCommand FIRST — creating a same-named VFS below may
    delete an existing testvfs whose obj-cmd would otherwise refer to
    a freed Testvfs.  test_vfs.c:1548..1554. }
  Tcl_CreateObjCommand(interp, zVfs, @testvfsObjCmd, p, @testvfsObjDel);
  p^.pParent := sqlite3_vfs_find(nil);
  p^.interp := interp;

  p^.zName := PChar(PtrUInt(p) + SizeOf(TTestvfs));
  Move(zVfs^, p^.zName^, nVfs + 1);

  pVfs := Psqlite3_vfs(ckalloc(SizeOf(sqlite3_vfs)));
  FillChar(pVfs^, SizeOf(sqlite3_vfs), 0);
  pVfs^.iVersion := iVersion;
  pVfs^.szOsFile := szOsFile;
  pVfs^.mxPathname := p^.pParent^.mxPathname;
  if (mxPathname >= 0) and (mxPathname < pVfs^.mxPathname) then
    pVfs^.mxPathname := mxPathname;
  pVfs^.zName := p^.zName;
  pVfs^.pAppData := p;
  pVfs^.xOpen := @tvfsOpen;
  pVfs^.xDelete := @tvfsDelete;
  pVfs^.xAccess := @tvfsAccess;
  pVfs^.xFullPathname := @tvfsFullPathname;
  pVfs^.xRandomness := @tvfsRandomness;
  pVfs^.xSleep := @tvfsSleep;
  pVfs^.xCurrentTime := @tvfsCurrentTime;
  pVfs^.xGetLastError := @tvfsGetLastError;
  { No xDl* — we don't load extensions through the wrapper. }

  p^.pVfs := pVfs;
  p^.isNoshm := isNoshm;
  p^.isFullshm := isFullshm;
  p^.mask := TESTVFS_ALL_MASK;

  sqlite3_vfs_register(pVfs, isDefault);

  Result := TCL_OK;
  if clientData = nil then ; { suppress hint }
end;

{ Minimal sqlite3ErrName for the result codes xShmLock can return
  (main.c:1533 — only the codes reachable here are mapped). }
function vfsShmlockErrName(rc: cint): PAnsiChar;
begin
  case rc of
    SQLITE_OK:            Result := 'SQLITE_OK';
    SQLITE_BUSY:          Result := 'SQLITE_BUSY';
    SQLITE_READONLY:      Result := 'SQLITE_READONLY';
    SQLITE_NOMEM:         Result := 'SQLITE_NOMEM';
    SQLITE_IOERR:         Result := 'SQLITE_IOERR';
    SQLITE_IOERR_SHMLOCK: Result := 'SQLITE_IOERR_SHMLOCK';
  else
    Result := 'SQLITE_ERROR';
  end;
end;

{ test_vfs.c:1591..1635 — vfs_shmlock DB DBNAME (shared|exclusive)
  (lock|unlock) OFFSET N.  Grabs the sqlite3_file* via
  SQLITE_FCNTL_FILE_POINTER and calls its xShmLock method directly. }
function testVfsShmlock(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
const
  azArg1 : array[0..2] of PAnsiChar = ('shared', 'exclusive', nil);
  azArg2 : array[0..2] of PAnsiChar = ('lock', 'unlock', nil);
var
  cmdInfo : TTclCmdInfo;
  db      : PTsqlite3;
  pDb     : PVfsTestSqliteDb;
  zDbname : PAnsiChar;
  iArg1   : cint;
  iArg2   : cint;
  iOffset : cint;
  n       : cint;
  pFd     : Psqlite3_file;
  rc      : cint;
  shmFlags: cint;
begin
  if clientData = clientData then ;
  iArg1 := 0; iArg2 := 0; iOffset := 0; n := 0;
  pFd := nil;

  if objc <> 7 then
  begin
    Tcl_WrongNumArgs(interp, 1, objv,
      PChar('DB DBNAME (shared|exclusive) (lock|unlock) OFFSET N'));
    Result := TCL_ERROR;
    Exit;
  end;

  zDbname := Tcl_GetString(objAt(objv, 2));

  { getDbPointer(interp, objv[1], &db) }
  db := nil;
  FillChar(cmdInfo, SizeOf(cmdInfo), 0);
  if Tcl_GetCommandInfo(interp, Tcl_GetString(objAt(objv, 1)), @cmdInfo) <> 0 then
  begin
    pDb := PVfsTestSqliteDb(cmdInfo.objClientData);
    if pDb <> nil then db := pDb^.db;
  end;
  if db = nil then
  begin
    Tcl_AppendResult(interp, PChar('expected database handle, got "'),
      Tcl_GetString(objAt(objv, 1)), PChar('"'), Pointer(nil));
    Result := TCL_ERROR;
    Exit;
  end;

  if (Tcl_GetIndexFromObj(interp, objAt(objv, 3), @azArg1[0], PChar('ARG'), 0, @iArg1) <> TCL_OK)
   or (Tcl_GetIndexFromObj(interp, objAt(objv, 4), @azArg2[0], PChar('ARG'), 0, @iArg2) <> TCL_OK)
   or (Tcl_GetIntFromObj(interp, objAt(objv, 5), @iOffset) <> TCL_OK)
   or (Tcl_GetIntFromObj(interp, objAt(objv, 6), @n) <> TCL_OK) then
  begin
    Result := TCL_ERROR;
    Exit;
  end;

  sqlite3_file_control(db, zDbname, SQLITE_FCNTL_FILE_POINTER, @pFd);
  if pFd = nil then
  begin
    Result := TCL_ERROR;
    Exit;
  end;

  if iArg1 = 0 then shmFlags := SQLITE_SHM_SHARED
  else shmFlags := SQLITE_SHM_EXCLUSIVE;
  if iArg2 = 0 then shmFlags := shmFlags or SQLITE_SHM_LOCK
  else shmFlags := shmFlags or SQLITE_SHM_UNLOCK;
  rc := pFd^.pMethods^.xShmLock(pFd, iOffset, n, shmFlags);
  Tcl_SetObjResult(interp, Tcl_NewStringObj(vfsShmlockErrName(rc), -1));
  Result := TCL_OK;
end;

{ test_vfs.c:1637..1688 — vfs_set_readmark DB DBNAME SLOT ?VALUE?.
  Stub: returns -1. }
function testVfsSetReadmark(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
begin
  Tcl_SetObjResult(interp, Tcl_NewIntObj(-1));
  Result := TCL_OK;
  if (clientData = nil) and (objc = 0) and (objv = nil) then ;
end;

{$endif SQLITE_TEST}

function Sqlitetestvfs_Init(interp: PTclInterp): cint; cdecl;
begin
{$ifdef SQLITE_TEST}
  InitIoMethodsTable;
  Tcl_CreateObjCommand(interp, PChar('testvfs'), @testvfsCmd, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('vfs_shmlock'), @testVfsShmlock, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('vfs_set_readmark'), @testVfsSetReadmark, nil, nil);
{$endif}
  Result := TCL_OK;
end;

end.
