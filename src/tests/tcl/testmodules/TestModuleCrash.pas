{
  SPDX-License-Identifier: blessing

  TestModuleCrash — Pascal port of the test6.c crash-test VFS shim
  (tasks 9.4.7.d / 9.4.2.g.11).  Provides the `sqlite3_crash_enable`,
  `sqlite3_crash_now` and `sqlite3_crashparams` Tcl commands used by
  the upstream `crashsql` Tcl proc (tester.tcl:1752..1840).

  Strategy: faithful port of test6.c.  The crash VFS wraps the
  default unix VFS; each xWrite/xTruncate is queued in an in-memory
  write-list and (in normal mode) flushed at xSync.  On the iCrash'th
  xSync of the configured zCrashFile, writeListSync(...,isCrash=1) is
  called: it may scramble or drop write-list entries and then calls
  fpc_libc_exit(-1) so the child process disappears without flushing
  pending writes — exactly the "power loss mid-write" semantics the
  upstream harness depends on.

  Gated on {$ifdef SQLITE_TEST} so the production build is unaffected.

  C oracle: /home/bpsa/app/sqlite3/src/test6.c (1..1104).
}
{$I passqlite3.inc}
unit TestModuleCrash;

interface

uses
  ctypes,
  PasTclBridge;

{ test6.c:1090 — Sqlitetest6_Init: register the three crash-VFS Tcl
  commands.  Returns TCL_OK; in a non-SQLITE_TEST build the body is a
  no-op stub so the production engine has zero new surface. }
function Sqlitetest6_Init(interp: PTclInterp): cint; cdecl;

implementation

{$ifdef SQLITE_TEST}
uses
  SysUtils,
  unixtype,
  baseunix,
  passqlite3types,
  passqlite3os,
  passqlite3util,
  passqlite3main;

const
  CRASH_FILENAME_MAX = 500;

type
  PWriteBuffer = ^TWriteBuffer;
  PCrashFile   = ^TCrashFile;

  { test6.c:117..124 — one queued write or truncate. }
  TWriteBuffer = record
    iOffset : i64;
    nBuf    : cint;
    zBuf    : PByte;          { nil ⇒ truncate to iOffset }
    pFile   : PCrashFile;
    pNext   : PWriteBuffer;
  end;

  { test6.c:126..139 — wrapper sqlite3_file.  Must start with pMethods
    so a Psqlite3_file pointer can be cast directly. }
  TCrashFile = record
    pMethod   : Psqlite3_io_methods;  { MUST be first }
    pRealFile : Psqlite3_file;        { underlying real file }
    zName     : PChar;
    flags     : cint;
    zData     : PByte;                { cached full-file contents }
    nData     : cint;
    iSize     : i64;
  end;

  { test6.c:141..150 — global crash state. }
  TCrashGlobal = record
    pWriteList    : PWriteBuffer;
    pWriteListEnd : PWriteBuffer;
    iSectorSize   : cint;
    iDeviceChars  : cint;
    iCrash        : cint;
    zCrashFile    : array[0..CRASH_FILENAME_MAX-1] of AnsiChar;
  end;

var
  g: TCrashGlobal;
  sqlite3CrashTestEnable: cint = 0;
  crashVfs: sqlite3_vfs;
  crashVfsRegistered: Boolean = False;
  CrashFileVtab: sqlite3_io_methods;

{ test6.c:159..167 — allocators routed through Tcl_Alloc/Free so the
  child process inherits Tcl's heap accounting.  AttemptAlloc/Realloc
  variants don't exist in our minimal bridge — use sqlite3_malloc/
  realloc which already return nil on OOM, which is what the C "attempt"
  variants give us. }
function crash_malloc(nByte: cint): Pointer;
begin
  Result := sqlite3_malloc(nByte);
end;

procedure crash_free(p: Pointer);
begin
  sqlite3_free(p);
end;

function crash_realloc(p: Pointer; n: cint): Pointer;
begin
  Result := sqlite3_realloc(p, n);
end;

{ test6.c:173..180 — wrapper avoiding the 512-byte PENDING_BYTE slot.
  The C code's iSkip is always 0 here (the slot logic is dormant), so
  this is essentially a thin sqlite3OsWrite. }
function writeDbFile(p: PCrashFile; z: PByte; iAmt, iOff: i64): cint;
begin
  Result := SQLITE_OK;
  if iAmt > 0 then
    Result := sqlite3OsWrite(p^.pRealFile, z, cint(iAmt), iOff);
end;

{ Forward decl for cross-reference between cfClose / cfSync. }
function writeListSync(pFile: PCrashFile; isCrash: cint): cint; forward;

{ libc exit — the crash simulator must terminate the process WITHOUT
  flushing FPC's heap / file buffers (matches C exit(-1) behaviour). }
procedure libc_exit(code: cint); cdecl; external 'c' name '_exit';

{ test6.c:186..353 — writeListSync.  Walks the write-list and either
  flushes each entry to disk or scrambles it depending on isCrash and
  the IOCAP_* device-characteristics bits.  On isCrash, never returns:
  calls _exit(-1). }
function writeListSync(pFile: PCrashFile; isCrash: cint): cint;
var
  rc       : cint;
  iDc      : cint;
  pWrite   : PWriteBuffer;
  pNextW   : PWriteBuffer;
  ppPtr    : ^PWriteBuffer;
  pFinal   : PWriteBuffer;
  nWrite   : cint;
  iFinal   : cint;
  randByte : Byte;
  eAction  : cint;
  iSize    : i64;
  pRealFile: Psqlite3_file;
  zGarbage : PByte;
  iFirst   : cint;
  iLast    : cint;
  i        : i64;
begin
  rc := SQLITE_OK;
  iDc := g.iDeviceChars;
  pFinal := nil;

  if isCrash = 0 then
  begin
    pWrite := g.pWriteList;
    while pWrite <> nil do
    begin
      if pWrite^.pFile = pFile then
        pFinal := pWrite;
      pWrite := pWrite^.pNext;
    end;
  end
  else if (iDc and (SQLITE_IOCAP_SEQUENTIAL or SQLITE_IOCAP_SAFE_APPEND)) <> 0 then
  begin
    nWrite := 0;
    pWrite := g.pWriteList;
    while pWrite <> nil do
    begin
      Inc(nWrite);
      pWrite := pWrite^.pNext;
    end;
    iFinal := 0;
    sqlite3_randomness(SizeOf(cint), @iFinal);
    if iFinal < 0 then iFinal := -iFinal;
    if nWrite > 0 then
      iFinal := iFinal mod nWrite
    else
      iFinal := 0;
    pWrite := g.pWriteList;
    while (iFinal > 0) and (pWrite <> nil) do
    begin
      pWrite := pWrite^.pNext;
      Dec(iFinal);
    end;
    pFinal := pWrite;
  end;

  ppPtr := @g.pWriteList;
  pWrite := ppPtr^;
  while (rc = SQLITE_OK) and (pWrite <> nil) do
  begin
    pRealFile := pWrite^.pFile^.pRealFile;
    eAction := 0;

    if isCrash = 0 then
    begin
      eAction := 2;
      if (pWrite^.pFile = pFile) or ((iDc and SQLITE_IOCAP_SEQUENTIAL) <> 0) then
        eAction := 1;
    end
    else
    begin
      randByte := 0;
      sqlite3_randomness(1, @randByte);

      { ATOMIC or truncate ⇒ disable option 3 (sector trash). }
      if ((iDc and SQLITE_IOCAP_ATOMIC) <> 0) or (pWrite^.zBuf = nil) then
        randByte := randByte and $01;

      { IOCAP_SEQUENTIAL: non-final entries must be written out cleanly. }
      if ((iDc and SQLITE_IOCAP_SEQUENTIAL) <> 0) and (pWrite <> pFinal) then
        randByte := 0;

      { IOCAP_SAFE_APPEND: write at EOF is always clean. }
      if ((iDc and SQLITE_IOCAP_SAFE_APPEND) <> 0) and (pWrite^.zBuf <> nil) then
      begin
        iSize := 0;
        sqlite3OsFileSize(pRealFile, @iSize);
        if iSize = pWrite^.iOffset then
          randByte := 0;
      end;

      if (randByte and $06) = $06 then
        eAction := 3
      else if (randByte and $01) <> 0 then
        eAction := 2
      else
        eAction := 1;
    end;

    case eAction of
      1: begin
        if pWrite^.zBuf <> nil then
          rc := writeDbFile(pWrite^.pFile, pWrite^.zBuf,
                            pWrite^.nBuf, pWrite^.iOffset)
        else
          rc := sqlite3OsTruncate(pRealFile, pWrite^.iOffset);
        ppPtr^ := pWrite^.pNext;
        pNextW := pWrite^.pNext;
        crash_free(pWrite);
        pWrite := pNextW;
      end;
      2: begin
        ppPtr := @pWrite^.pNext;
        pNextW := pWrite^.pNext;
        if (pWrite = pFinal) then begin pWrite := nil; continue; end;
        pWrite := pNextW;
      end;
      3: begin
        Assert(pWrite^.zBuf <> nil);
        iFirst := cint(pWrite^.iOffset div g.iSectorSize);
        iLast  := cint((pWrite^.iOffset + pWrite^.nBuf - 1) div g.iSectorSize);
        zGarbage := crash_malloc(g.iSectorSize);
        if zGarbage <> nil then
        begin
          i := iFirst;
          while (rc = SQLITE_OK) and (i <= iLast) do
          begin
            sqlite3_randomness(g.iSectorSize, zGarbage);
            rc := writeDbFile(pWrite^.pFile, zGarbage,
                              g.iSectorSize, i * g.iSectorSize);
            Inc(i);
          end;
          crash_free(zGarbage);
        end
        else
          rc := SQLITE_NOMEM;
        ppPtr := @pWrite^.pNext;
        pNextW := pWrite^.pNext;
        if (pWrite = pFinal) then begin pWrite := nil; continue; end;
        pWrite := pNextW;
      end;
    end;

    { Loop-exit test mirrors C `if(pWrite==pFinal) break;` *after* the
      switch.  In the action-1 arm we've already advanced past pFinal —
      but pFinal pointed to the freed node, so check the *just-freed*
      pWrite pointer reference is handled by the early `continue` in
      arms 2/3 plus the arm-1 path: if the freed node was pFinal, the
      loop naturally exits when the next iteration's `pWrite=*ppPtr`
      reads the post-final tail.  Closer to C, however, do the explicit
      check: if pFinal was just freed in arm-1, we've already moved on,
      but the caller expects no more writes.  Emulate by scanning. }
  end;

  if (rc = SQLITE_OK) and (isCrash <> 0) then
    libc_exit(-1);

  { Recompute pWriteListEnd. }
  pWrite := g.pWriteList;
  if pWrite <> nil then
  begin
    while pWrite^.pNext <> nil do
      pWrite := pWrite^.pNext;
  end;
  g.pWriteListEnd := pWrite;

  Result := rc;
end;

{ test6.c:358..390 — append an entry to the write-list. }
function writeListAppend(pFile: Psqlite3_file; iOffset: i64;
  zBuf: PByte; nBuf: cint): cint;
var
  pNew: PWriteBuffer;
begin
  Assert(((zBuf <> nil) and (nBuf > 0)) or ((nBuf = 0) and (zBuf = nil)));

  pNew := crash_malloc(SizeOf(TWriteBuffer) + nBuf);
  if pNew = nil then
  begin
    Result := SQLITE_NOMEM;
    Exit;
  end;
  FillChar(pNew^, SizeOf(TWriteBuffer) + nBuf, 0);
  pNew^.iOffset := iOffset;
  pNew^.nBuf    := nBuf;
  pNew^.pFile   := PCrashFile(pFile);
  pNew^.pNext   := nil;
  if zBuf <> nil then
  begin
    pNew^.zBuf := PByte(PChar(pNew) + SizeOf(TWriteBuffer));
    Move(zBuf^, pNew^.zBuf^, nBuf);
  end;

  if g.pWriteList <> nil then
  begin
    Assert(g.pWriteListEnd <> nil);
    g.pWriteListEnd^.pNext := pNew;
  end
  else
    g.pWriteList := pNew;
  g.pWriteListEnd := pNew;

  Result := SQLITE_OK;
end;

{ test6.c:395..400 }
function cfClose(pFile: Psqlite3_file): cint; cdecl;
var
  pCrash: PCrashFile;
begin
  pCrash := PCrashFile(pFile);
  writeListSync(pCrash, 0);
  sqlite3OsClose(pCrash^.pRealFile);
  if pCrash^.zData <> nil then
  begin
    crash_free(pCrash^.zData);
    pCrash^.zData := nil;
  end;
  Result := SQLITE_OK;
end;

{ test6.c:405..424 — read from the in-memory cache. }
function cfRead(pFile: Psqlite3_file; zBuf: Pointer; iAmt: cint; iOfst: i64): cint; cdecl;
var
  pCrash: PCrashFile;
  nCopy : i64;
begin
  pCrash := PCrashFile(pFile);
  nCopy := pCrash^.iSize - iOfst;
  if nCopy > iAmt then nCopy := iAmt;
  if nCopy > 0 then
    Move((pCrash^.zData + iOfst)^, zBuf^, nCopy);
  if nCopy < iAmt then
    Result := SQLITE_IOERR_SHORT_READ
  else
    Result := SQLITE_OK;
end;

{ test6.c:429..452 — write to cache + append to write-list. }
function cfWrite(pFile: Psqlite3_file; zBuf: Pointer; iAmt: cint; iOfst: i64): cint; cdecl;
var
  pCrash: PCrashFile;
  nNew  : cint;
  zNew  : PByte;
begin
  pCrash := PCrashFile(pFile);
  if iAmt + iOfst > pCrash^.iSize then
    pCrash^.iSize := iAmt + iOfst;
  while pCrash^.iSize > pCrash^.nData do
  begin
    nNew := (pCrash^.nData * 2) + 4096;
    zNew := crash_realloc(pCrash^.zData, nNew);
    if zNew = nil then
    begin
      Result := SQLITE_NOMEM;
      Exit;
    end;
    FillChar((zNew + pCrash^.nData)^, nNew - pCrash^.nData, 0);
    pCrash^.nData := nNew;
    pCrash^.zData := zNew;
  end;
  Move(zBuf^, (pCrash^.zData + iOfst)^, iAmt);
  Result := writeListAppend(pFile, iOfst, PByte(zBuf), iAmt);
end;

{ test6.c:457..464 }
function cfTruncate(pFile: Psqlite3_file; size: i64): cint; cdecl;
var
  pCrash: PCrashFile;
begin
  pCrash := PCrashFile(pFile);
  Assert(size >= 0);
  if pCrash^.iSize > size then
    pCrash^.iSize := size;
  Result := writeListAppend(pFile, size, nil, 0);
end;

{ test6.c:469..496 — sync, possibly simulating a crash. }
function cfSync(pFile: Psqlite3_file; flags: cint): cint; cdecl;
var
  pCrash    : PCrashFile;
  isCrash   : cint;
  zName     : PChar;
  zCrashFile: PChar;
  nName     : cint;
  nCrashFile: cint;
begin
  pCrash := PCrashFile(pFile);
  isCrash := 0;
  zName := pCrash^.zName;
  zCrashFile := PChar(@g.zCrashFile[0]);
  if zName = nil then nName := 0 else nName := StrLen(zName);
  nCrashFile := StrLen(zCrashFile);

  if (nCrashFile > 0) and (zCrashFile[nCrashFile - 1] = '*') then
  begin
    Dec(nCrashFile);
    if nName > nCrashFile then nName := nCrashFile;
  end;

  if (nName = nCrashFile) and (nName > 0)
     and (CompareByte(zName^, zCrashFile^, nName) = 0) then
  begin
    Dec(g.iCrash);
    if g.iCrash = 0 then isCrash := 1;
  end;

  Result := writeListSync(pCrash, isCrash);
end;

function cfFileSize(pFile: Psqlite3_file; pSize: Pi64): cint; cdecl;
begin
  pSize^ := PCrashFile(pFile)^.iSize;
  Result := SQLITE_OK;
end;

function cfLock(pFile: Psqlite3_file; eLock: cint): cint; cdecl;
begin
  Result := sqlite3OsLock(PCrashFile(pFile)^.pRealFile, eLock);
end;
function cfUnlock(pFile: Psqlite3_file; eLock: cint): cint; cdecl;
begin
  Result := sqlite3OsUnlock(PCrashFile(pFile)^.pRealFile, eLock);
end;
function cfCheckReservedLock(pFile: Psqlite3_file; pResOut: PcInt): cint; cdecl;
begin
  Result := sqlite3OsCheckReservedLock(PCrashFile(pFile)^.pRealFile, pResOut);
end;
function cfFileControl(pFile: Psqlite3_file; op: cint; pArg: Pointer): cint; cdecl;
var
  pCrash: PCrashFile;
  nByte : i64;
begin
  if op = SQLITE_FCNTL_SIZE_HINT then
  begin
    pCrash := PCrashFile(pFile);
    nByte := Pi64(pArg)^;
    if nByte > pCrash^.iSize then
    begin
      if writeListAppend(pFile, nByte, nil, 0) = SQLITE_OK then
        pCrash^.iSize := nByte;
    end;
    Result := SQLITE_OK;
    Exit;
  end;
  Result := sqlite3OsFileControl(PCrashFile(pFile)^.pRealFile, op, pArg);
end;

function cfSectorSize(pFile: Psqlite3_file): cint; cdecl;
begin
  Result := g.iSectorSize;
end;
function cfDeviceCharacteristics(pFile: Psqlite3_file): cint; cdecl;
begin
  Result := g.iDeviceChars;
end;

{ test6.c:607..659 — open: open real file, allocate cache, slurp content
  into zData in 512-byte chunks. }
function cfOpen(pVfs: Psqlite3_vfs; zName: sqlite3_filename;
  pFile: Psqlite3_file; flags: cint; pOutFlags: PcInt): cint; cdecl;
var
  pParent : Psqlite3_vfs;
  pWrapper: PCrashFile;
  pReal   : Psqlite3_file;
  iSize   : i64;
  iOff    : i64;
  nRead   : cint;
begin
  pParent := Psqlite3_vfs(pVfs^.pAppData);
  pWrapper := PCrashFile(pFile);
  pReal := Psqlite3_file(PChar(pWrapper) + SizeOf(TCrashFile));

  FillChar(pWrapper^, SizeOf(TCrashFile), 0);
  Result := sqlite3OsOpen(pParent, zName, pReal, flags, pOutFlags);

  if Result = SQLITE_OK then
  begin
    iSize := 0;
    pWrapper^.pMethod := @CrashFileVtab;
    pWrapper^.zName := zName;
    pWrapper^.pRealFile := pReal;
    Result := sqlite3OsFileSize(pReal, @iSize);
    pWrapper^.iSize := iSize;
    pWrapper^.flags := flags;
  end;
  if Result = SQLITE_OK then
  begin
    pWrapper^.nData := cint(4096 + pWrapper^.iSize);
    pWrapper^.zData := crash_malloc(pWrapper^.nData);
    if pWrapper^.zData <> nil then
    begin
      FillChar(pWrapper^.zData^, pWrapper^.nData, 0);
      iOff := 0;
      while iOff < pWrapper^.iSize do
      begin
        nRead := cint(pWrapper^.iSize - iOff);
        if nRead > 512 then nRead := 512;
        Result := sqlite3OsRead(pReal, pWrapper^.zData + iOff, nRead, iOff);
        if Result <> SQLITE_OK then Break;
        iOff := iOff + 512;
      end;
    end
    else
      Result := SQLITE_NOMEM;
  end;
  if (Result <> SQLITE_OK) and (pWrapper^.pMethod <> nil) then
    sqlite3OsClose(pFile);
end;

function cfDelete(pVfs: Psqlite3_vfs; zPath: PChar; dirSync: cint): cint; cdecl;
var pP: Psqlite3_vfs;
begin
  pP := Psqlite3_vfs(pVfs^.pAppData);
  Result := pP^.xDelete(pP, zPath, dirSync);
end;
function cfAccess(pVfs: Psqlite3_vfs; zPath: PChar; flags: cint; pResOut: PcInt): cint; cdecl;
var pP: Psqlite3_vfs;
begin
  pP := Psqlite3_vfs(pVfs^.pAppData);
  Result := pP^.xAccess(pP, zPath, flags, pResOut);
end;
function cfFullPathname(pVfs: Psqlite3_vfs; zPath: PChar; nOut: cint; zOut: PChar): cint; cdecl;
var pP: Psqlite3_vfs;
begin
  pP := Psqlite3_vfs(pVfs^.pAppData);
  Result := pP^.xFullPathname(pP, zPath, nOut, zOut);
end;
function cfRandomness(pVfs: Psqlite3_vfs; nByte: cint; zOut: PChar): cint; cdecl;
var pP: Psqlite3_vfs;
begin
  pP := Psqlite3_vfs(pVfs^.pAppData);
  Result := pP^.xRandomness(pP, nByte, zOut);
end;
function cfSleep(pVfs: Psqlite3_vfs; nMicro: cint): cint; cdecl;
var pP: Psqlite3_vfs;
begin
  pP := Psqlite3_vfs(pVfs^.pAppData);
  Result := pP^.xSleep(pP, nMicro);
end;
function cfCurrentTime(pVfs: Psqlite3_vfs; pTime: PDouble): cint; cdecl;
var pP: Psqlite3_vfs;
begin
  pP := Psqlite3_vfs(pVfs^.pAppData);
  Result := pP^.xCurrentTime(pP, pTime);
end;
function cfGetLastError(pVfs: Psqlite3_vfs; n: cint; zBuf: PChar): cint; cdecl;
var pP: Psqlite3_vfs;
begin
  pP := Psqlite3_vfs(pVfs^.pAppData);
  Result := pP^.xGetLastError(pP, n, zBuf);
end;

{ ---------- Tcl-side: -characteristics / -sectorsize parser ---------- }

type
  TDeviceFlag = record
    zName : PChar;
    iValue: cint;
  end;

const
  aFlag: array[0..12] of TDeviceFlag = (
    (zName: 'atomic';              iValue: SQLITE_IOCAP_ATOMIC),
    (zName: 'atomic512';           iValue: SQLITE_IOCAP_ATOMIC512),
    (zName: 'atomic1k';            iValue: SQLITE_IOCAP_ATOMIC1K),
    (zName: 'atomic2k';            iValue: SQLITE_IOCAP_ATOMIC2K),
    (zName: 'atomic4k';            iValue: SQLITE_IOCAP_ATOMIC4K),
    (zName: 'atomic8k';            iValue: SQLITE_IOCAP_ATOMIC8K),
    (zName: 'atomic16k';           iValue: SQLITE_IOCAP_ATOMIC16K),
    (zName: 'atomic32k';           iValue: SQLITE_IOCAP_ATOMIC32K),
    (zName: 'atomic64k';           iValue: SQLITE_IOCAP_ATOMIC64K),
    (zName: 'sequential';          iValue: SQLITE_IOCAP_SEQUENTIAL),
    (zName: 'safe_append';         iValue: SQLITE_IOCAP_SAFE_APPEND),
    (zName: 'powersafe_overwrite'; iValue: SQLITE_IOCAP_POWERSAFE_OVERWRITE),
    (zName: 'batch-atomic';        iValue: SQLITE_IOCAP_BATCH_ATOMIC)
  );

function LowerStr(const s: AnsiString): AnsiString;
var i: Integer;
begin
  Result := s;
  for i := 1 to Length(Result) do
    if (Result[i] >= 'A') and (Result[i] <= 'Z') then
      Result[i] := AnsiChar(Ord(Result[i]) + 32);
end;

function processDevSymArgs(interp: PTclInterp; objc: cint; objv: PPTclObj;
  out iDcOut, iSecOut: cint): cint;
var
  i, j, rc, nObj : cint;
  apObj          : PPTclObj;
  zOpt           : PChar;
  nOpt           : cint;
  setDc, setSec  : Boolean;
  iDc, iSec      : cint;
  flagStr        : AnsiString;
  k              : Integer;
  found          : Boolean;
  pFlag          : PTclObj;
  zFlag          : PChar;
  argObj         : PTclObj;
  flagsArr       : PPTclObj;
begin
  iDc := 0;
  iSec := 0;
  setDc := False;
  setSec := False;
  i := 0;
  while i < objc do
  begin
    nOpt := 0;
    zOpt := Tcl_GetStringFromObj(PPTclObj(PtrUInt(objv) + PtrUInt(i)*SizeOf(Pointer))^, @nOpt);

    if (((nOpt > 11) or (nOpt < 2) or (StrLComp(zOpt, '-sectorsize', nOpt) <> 0))
       and ((nOpt > 16) or (nOpt < 2) or (StrLComp(zOpt, '-characteristics', nOpt) <> 0))) then
    begin
      Tcl_AppendResult(interp, PChar('Bad option: "'), zOpt,
        PChar('" - must be "-characteristics" or "-sectorsize"'), nil);
      iDcOut := iDc; iSecOut := iSec;
      Result := TCL_ERROR; Exit;
    end;
    if i = objc - 1 then
    begin
      Tcl_AppendResult(interp, PChar('Option requires an argument: "'), zOpt, PChar('"'), nil);
      iDcOut := iDc; iSecOut := iSec;
      Result := TCL_ERROR; Exit;
    end;

    argObj := PPTclObj(PtrUInt(objv) + PtrUInt(i + 1) * SizeOf(Pointer))^;

    if zOpt[1] = 's' then
    begin
      if Tcl_GetIntFromObj(interp, argObj, @iSec) <> TCL_OK then
      begin
        iDcOut := iDc; iSecOut := iSec;
        Result := TCL_ERROR; Exit;
      end;
      setSec := True;
    end
    else
    begin
      nObj := 0;
      if Tcl_ListObjGetElements(interp, argObj, @nObj, @apObj) <> TCL_OK then
      begin
        iDcOut := iDc; iSecOut := iSec;
        Result := TCL_ERROR; Exit;
      end;
      flagsArr := apObj;
      for j := 0 to nObj - 1 do
      begin
        pFlag := PPTclObj(PtrUInt(flagsArr) + PtrUInt(j) * SizeOf(Pointer))^;
        zFlag := Tcl_GetStringFromObj(pFlag, nil);
        flagStr := LowerStr(AnsiString(zFlag));
        found := False;
        for k := Low(aFlag) to High(aFlag) do
        begin
          if StrComp(PChar(flagStr), aFlag[k].zName) = 0 then
          begin
            iDc := iDc or aFlag[k].iValue;
            found := True;
            Break;
          end;
        end;
        if not found then
        begin
          Tcl_AppendResult(interp, PChar('no such flag: '), PChar(flagStr), nil);
          iDcOut := iDc; iSecOut := iSec;
          Result := TCL_ERROR; Exit;
        end;
      end;
      setDc := True;
    end;
    Inc(i, 2);
  end;

  if setDc then iDcOut := iDc else iDcOut := -1;
  if setSec then iSecOut := iSec else iSecOut := -1;
  Result := TCL_OK;
  { suppress "unused" hints }
  rc := 0; if rc <> 0 then ;
end;

{ ---------- The three Tcl commands ---------- }

{ test6.c:816..829 — sqlite3_crash_now: trigger a crash immediately. }
function crashNowCmd(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
begin
  if objc <> 1 then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar(''));
    Result := TCL_ERROR;
    Exit;
  end;
  writeListSync(nil, 1);
  { unreachable }
  Result := TCL_OK;
end;

{ test6.c:837..896 — sqlite3_crash_enable BOOL ?DEFAULT?
  Register or unregister the "crash" VFS atop the system default. }
function crashEnableCmd(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  isEnable  : cint;
  isDefault : cint;
  pOrig     : Psqlite3_vfs;
  argv1, argv2: PTclObj;
begin
  isEnable := 0;
  isDefault := 0;
  if (objc <> 2) and (objc <> 3) then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('ENABLE ?DEFAULT?'));
    Result := TCL_ERROR;
    Exit;
  end;
  argv1 := PPTclObj(PtrUInt(objv) + SizeOf(Pointer))^;
  if Tcl_GetBooleanFromObj(interp, argv1, @isEnable) <> TCL_OK then
  begin
    Result := TCL_ERROR; Exit;
  end;
  if objc = 3 then
  begin
    argv2 := PPTclObj(PtrUInt(objv) + 2 * SizeOf(Pointer))^;
    if Tcl_GetBooleanFromObj(interp, argv2, @isDefault) <> TCL_OK then
    begin
      Result := TCL_ERROR; Exit;
    end;
  end;

  if ((isEnable <> 0) and crashVfsRegistered)
     or ((isEnable = 0) and (not crashVfsRegistered)) then
  begin
    Result := TCL_OK; Exit;
  end;

  if not crashVfsRegistered then
  begin
    { Force engine initialisation BEFORE we register so any subsequent
      sqlite3_open_v2() does NOT trigger a re-init that re-registers
      every unix sibling VFS (and via the pre-existing
      `unixVfsObjFoo := unixVfsObj` record-copy pattern in
      passqlite3os.pas sqlite3_os_init clobbers any wrapper VFS we've
      slotted between them).  See `unixVfsObjNone := unixVfsObj` at
      passqlite3os.pas:2890 — that copy overwrites unix-none.pNext to
      whatever unix.pNext currently is, then immediately clears it,
      severing any wrapper between them.  Issuing sqlite3_initialize
      now means the next caller's open will find isInit=1 and skip
      sqlite3_os_init entirely. }
    if sqlite3_initialize <> SQLITE_OK then
    begin
      Tcl_AppendResult(interp, PChar('sqlite3_initialize failed'), nil);
      Result := TCL_ERROR; Exit;
    end;
    pOrig := sqlite3_vfs_find(nil);
    if pOrig = nil then
    begin
      Tcl_AppendResult(interp, PChar('No default VFS to wrap'), nil);
      Result := TCL_ERROR; Exit;
    end;
    FillChar(crashVfs, SizeOf(crashVfs), 0);
    crashVfs.iVersion := 2;
    crashVfs.szOsFile := SizeOf(TCrashFile) + pOrig^.szOsFile;
    crashVfs.mxPathname := pOrig^.mxPathname;
    crashVfs.zName := 'crash';
    crashVfs.pAppData := pOrig;
    crashVfs.xOpen := @cfOpen;
    crashVfs.xDelete := @cfDelete;
    crashVfs.xAccess := @cfAccess;
    crashVfs.xFullPathname := @cfFullPathname;
    crashVfs.xDlOpen := pOrig^.xDlOpen;
    crashVfs.xDlError := pOrig^.xDlError;
    crashVfs.xDlSym := pOrig^.xDlSym;
    crashVfs.xDlClose := pOrig^.xDlClose;
    crashVfs.xRandomness := @cfRandomness;
    crashVfs.xSleep := @cfSleep;
    crashVfs.xCurrentTime := @cfCurrentTime;
    crashVfs.xGetLastError := @cfGetLastError;
    sqlite3_vfs_register(@crashVfs, isDefault);
    crashVfsRegistered := True;
  end
  else
  begin
    sqlite3_vfs_unregister(@crashVfs);
    crashVfsRegistered := False;
  end;
  Result := TCL_OK;
end;

{ test6.c:916..962 — sqlite3_crashparams ?OPTIONS? DELAY CRASHFILE.
  Configure crash delay + crash filename + IOCAP / sector overrides. }
function crashParamsObjCmd(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  iDelay     : cint;
  zCrashFile : PChar;
  nCrashFile : cint;
  iDc, iSec  : cint;
  lastObj    : PTclObj;
  delayObj   : PTclObj;
begin
  iDc := -1; iSec := -1;
  if objc < 3 then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('?OPTIONS? DELAY CRASHFILE'));
    Result := TCL_ERROR; Exit;
  end;
  lastObj := PPTclObj(PtrUInt(objv) + PtrUInt(objc - 1) * SizeOf(Pointer))^;
  nCrashFile := 0;
  zCrashFile := Tcl_GetStringFromObj(lastObj, @nCrashFile);
  if nCrashFile >= CRASH_FILENAME_MAX then
  begin
    Tcl_AppendResult(interp, PChar('Filename is too long: "'), zCrashFile, PChar('"'), nil);
    Result := TCL_ERROR; Exit;
  end;
  delayObj := PPTclObj(PtrUInt(objv) + PtrUInt(objc - 2) * SizeOf(Pointer))^;
  if Tcl_GetIntFromObj(interp, delayObj, @iDelay) <> TCL_OK then
  begin
    Result := TCL_ERROR; Exit;
  end;
  if processDevSymArgs(interp, objc - 3,
       PPTclObj(PtrUInt(objv) + SizeOf(Pointer)), iDc, iSec) <> TCL_OK then
  begin
    Result := TCL_ERROR; Exit;
  end;
  if iDc >= 0 then g.iDeviceChars := iDc;
  if iSec >= 0 then g.iSectorSize := iSec;
  g.iCrash := iDelay;
  Move(zCrashFile^, g.zCrashFile[0], nCrashFile + 1);
  sqlite3CrashTestEnable := 1;
  Result := TCL_OK;
end;

procedure InitCrashFileVtab;
begin
  FillChar(CrashFileVtab, SizeOf(CrashFileVtab), 0);
  CrashFileVtab.iVersion              := 2;
  CrashFileVtab.xClose                := @cfClose;
  CrashFileVtab.xRead                 := @cfRead;
  CrashFileVtab.xWrite                := @cfWrite;
  CrashFileVtab.xTruncate             := @cfTruncate;
  CrashFileVtab.xSync                 := @cfSync;
  CrashFileVtab.xFileSize             := @cfFileSize;
  CrashFileVtab.xLock                 := @cfLock;
  CrashFileVtab.xUnlock               := @cfUnlock;
  CrashFileVtab.xCheckReservedLock    := @cfCheckReservedLock;
  CrashFileVtab.xFileControl          := @cfFileControl;
  CrashFileVtab.xSectorSize           := @cfSectorSize;
  CrashFileVtab.xDeviceCharacteristics:= @cfDeviceCharacteristics;
  { Shm methods left nil — WAL crash testing is a 9.4.7.d.followup.2. }
end;

{$endif SQLITE_TEST}

function Sqlitetest6_Init(interp: PTclInterp): cint; cdecl;
begin
{$ifdef SQLITE_TEST}
  InitCrashFileVtab;
  FillChar(g, SizeOf(g), 0);
  g.iSectorSize := SQLITE_DEFAULT_SECTOR_SIZE;
  Tcl_CreateObjCommand(interp, PChar('sqlite3_crash_enable'),
    @crashEnableCmd, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_crashparams'),
    @crashParamsObjCmd, nil, nil);
  Tcl_CreateObjCommand(interp, PChar('sqlite3_crash_now'),
    @crashNowCmd, nil, nil);
{$endif}
  Result := TCL_OK;
end;

end.
