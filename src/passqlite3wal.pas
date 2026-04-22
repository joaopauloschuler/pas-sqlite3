{$I passqlite3.inc}
unit passqlite3wal;
{
  Port of SQLite's wal.c (write-ahead log) to Free Pascal.
  Source: ../sqlite3/src/wal.c  (SQLite 3.53.0)
  Not using SQLITE_OMIT_WAL or SQLITE_USE_SEH (Linux build).
}

interface

uses
  passqlite3types, passqlite3internal, passqlite3os, passqlite3util,
  passqlite3pcache, ctypes;

{ ============================================================
  WAL constants (wal.c, wal.h)
  ============================================================ }
const
  WAL_MAX_VERSION      = 3007000;
  WALINDEX_MAX_VERSION = 3007000;

  WAL_WRITE_LOCK   = 0;
  WAL_ALL_BUT_WRITE = 1;
  WAL_CKPT_LOCK    = 1;
  WAL_RECOVER_LOCK = 2;
  WAL_NREADER      = SQLITE_SHM_NLOCK - 3;   { = 5 }

  WAL_FRAME_HDRSIZE = 24;
  WAL_HDRSIZE       = 32;
  WAL_MAGIC         = $377F0682;

  READMARK_NOT_USED = $FFFFFFFF;

  { walTryBeginRead retry logic }
  WAL_RETRY = -1;
  WAL_RETRY_PROTOCOL_LIMIT = 100;

  { exclusiveMode values }
  WAL_NORMAL_MODE    = 0;
  WAL_EXCLUSIVE_MODE = 1;
  WAL_HEAPMEMORY_MODE = 2;

  { readOnly field values }
  WAL_RDWR       = 0;
  WAL_RDONLY     = 1;
  WAL_SHM_RDONLY = 2;

  { Hash table parameters }
  HASHTABLE_NPAGE    = 4096;
  HASHTABLE_HASH_1   = 383;
  HASHTABLE_NSLOT    = HASHTABLE_NPAGE * 2;   { = 8192 }
  HASHTABLE_NPAGE_ONE = HASHTABLE_NPAGE - (136 div 4); { = 4062 }

  { WAL-index page size: hash table (u16*8192) + pgno array (u32*4096) }
  WALINDEX_PGSZ = SizeOf(u16) * HASHTABLE_NSLOT + HASHTABLE_NPAGE * SizeOf(u32);
                  { = 16384 + 16384 = 32768 }

  { WAL_SAVEPOINT_NDATA: words needed to save WAL write position }
  WAL_SAVEPOINT_NDATA_W = 4;

  { SQLITE_CHECKPOINT modes (sqlite3.h) }
  SQLITE_CHECKPOINT_PASSIVE  = 0;
  SQLITE_CHECKPOINT_FULL     = 1;
  SQLITE_CHECKPOINT_RESTART  = 2;
  SQLITE_CHECKPOINT_TRUNCATE = 3;
  SQLITE_CHECKPOINT_NOOP     = -1;   { internal use only }

  { SQLITE_BIGENDIAN: 0 on x86_64/little-endian }
  SQLITE_BIGENDIAN = 0;

  SQLITE_DEFAULT_SECTOR_SIZE = 4096;

{ ============================================================
  Types
  ============================================================ }
type
  ht_slot = u16;
  PHtSlot = ^ht_slot;
  PPHtSlot = ^PHtSlot;

  { Pointer-to-pointer-to-u32 for apWiData (volatile u32 ** in C) }
  PPu32 = ^Pu32;

  { WalIndexHdr (48 bytes): two copies live at start of SHM page 0 }
  PWalIndexHdr = ^TWalIndexHdr;
  TWalIndexHdr = record
    iVersion    : u32;                     { Wal-index version }
    unused      : u32;                     { Padding }
    iChange     : u32;                     { Counter incremented each txn }
    isInit      : u8;                      { 1 when initialized }
    bigEndCksum : u8;                      { True if WAL checksums are big-endian }
    szPage      : u16;                     { Database page size in bytes. 1==64K }
    mxFrame     : u32;                     { Index of last valid frame in WAL }
    nPage       : u32;                     { Size of database in pages }
    aFrameCksum : array[0..1] of u32;      { Checksum of last frame in log }
    aSalt       : array[0..1] of u32;      { Two salt values copied from WAL header }
    aCksum      : array[0..1] of u32;      { Checksum over all prior fields }
  end;

  { WalCkptInfo (40 bytes): immediately follows the two WalIndexHdr copies }
  PWalCkptInfo = ^TWalCkptInfo;
  TWalCkptInfo = record
    nBackfill          : u32;                            { Frames backfilled into DB }
    aReadMark          : array[0..WAL_NREADER-1] of u32; { Reader marks }
    aLock              : array[0..SQLITE_SHM_NLOCK-1] of u8; { Lock bytes }
    nBackfillAttempted : u32;                            { WAL frames perhaps written }
    notUsed0           : u32;                            { Available for future use }
  end;

  { WalSegment: one segment in a WalIterator }
  PWalSegment = ^TWalSegment;
  TWalSegment = record
    iNext  : cint;      { Next slot in aIndex[] not yet returned }
    aIndex : PHtSlot;   { Sorted page indices }
    aPgno  : Pu32;      { Array of page numbers }
    nEntry : cint;      { Number of entries in aPgno[] and aIndex[] }
    iZero  : cint;      { Frame number associated with aPgno[0] }
  end;

  { WalIterator: checkpoint iterator; flexible aSegment[] at end }
  PWalIterator = ^TWalIterator;
  TWalIterator = record
    iPrior   : u32;     { Last result returned from the iterator }
    nSegment : cint;    { Number of entries in aSegment[] }
    aSegment : array[0..0] of TWalSegment;  { One per 32KB wal-index page }
  end;

  { WalHashLoc: describes a hash-table location in the wal-index }
  PWalHashLoc = ^TWalHashLoc;
  TWalHashLoc = record
    aHash : PHtSlot;    { Start of hash table }
    aPgno : Pu32;       { aPgno[0] is first indexed page number }
    iZero : u32;        { One less than frame number of first indexed frame }
  end;

  { Wal: main WAL connection struct — field order matches C struct Wal exactly }
  PWal = ^TWal;
  TWal = record
    pVfs              : Psqlite3_vfs;          { VFS used to create pDbFd }
    pDbFd             : Psqlite3_file;          { File handle for database }
    pWalFd            : Psqlite3_file;          { File handle for WAL file }
    iCallback         : u32;                    { Value to pass to log callback }
    mxWalSize         : i64;                    { Truncate WAL to this size on reset }
    nWiData           : cint;                   { Size of array apWiData }
    szFirstBlock      : cint;                   { Size of first block in WAL }
    apWiData          : PPu32;                  { Pointer to wal-index content }
    szPage            : u32;                    { Database page size }
    readLock          : i16;                    { Which read lock held. -1 = none }
    syncFlags         : u8;                     { Flags for header writes }
    exclusiveMode     : u8;                     { Non-zero if exclusive mode }
    writeLock         : u8;                     { True if in write transaction }
    ckptLock          : u8;                     { True if holding checkpoint lock }
    readOnly          : u8;                     { WAL_RDWR/RDONLY/SHM_RDONLY }
    truncateOnCommit  : u8;                     { True to truncate WAL on commit }
    syncHeader        : u8;                     { Fsync WAL header if true }
    padToSectorBoundary : u8;                   { Pad transactions to next sector }
    bShmUnreliable    : u8;                     { SHM content read-only/unreliable }
    hdr               : TWalIndexHdr;           { Wal-index header for current txn }
    minFrame          : u32;                    { Ignore wal frames before this one }
    iReCksum          : u32;                    { On commit, recalc checksums here }
    zWalName          : PChar;                  { Name of WAL file }
    nCkpt             : u32;                    { Checkpoint sequence counter }
  end;

  { WalWriter: used internally in walFrames }
  PWalWriter = ^TWalWriter;
  TWalWriter = record
    pWal        : PWal;
    pFd         : Psqlite3_file;
    iSyncPoint  : i64;
    syncFlags   : cint;
    szPage      : cint;
  end;

  PPWal = ^PWal;
  PPWalIterator = ^PWalIterator;
  TxUndoCallback = function(pCtx: Pointer; pgno: Pgno): cint;
  TxBusyCallback = function(pCtx: Pointer): cint;

{ ============================================================
  WALINDEX_LOCK_OFFSET and WALINDEX_HDR_SIZE (derived constants)
  ============================================================ }
const
  WALINDEX_LOCK_OFFSET = SizeOf(TWalIndexHdr) * 2 + 24;   { = 120 }
  WALINDEX_HDR_SIZE    = SizeOf(TWalIndexHdr) * 2 + SizeOf(TWalCkptInfo); { = 136 }

{ ============================================================
  WAL sync-flag helpers (wal.h macros)
  ============================================================ }
function WAL_SYNC_FLAGS(x: cint): cint; inline;
function CKPT_SYNC_FLAGS(x: cint): cint; inline;

{ ============================================================
  Public API (wal.h)
  ============================================================ }

function  sqlite3WalOpen(pVfs: Psqlite3_vfs; pDbFd: Psqlite3_file;
                         zWalName: PChar; bNoShm: cint; mxWalSize: i64;
                         ppWal: PPWal): cint;
function  sqlite3WalClose(pWal: PWal; db: Pointer; sync_flags: cint;
                          nBuf: cint; zBuf: Pu8): cint;
procedure sqlite3WalLimit(pWal: PWal; iLimit: i64);
function  sqlite3WalBeginReadTransaction(pWal: PWal; pChanged: PcInt): cint;
procedure sqlite3WalEndReadTransaction(pWal: PWal);
function  sqlite3WalFindFrame(pWal: PWal; pgno: Pgno; piRead: Pu32): cint;
function  sqlite3WalReadFrame(pWal: PWal; iRead: u32; nOut: cint; pOut: Pu8): cint;
function  sqlite3WalDbsize(pWal: PWal): Pgno;
function  sqlite3WalBeginWriteTransaction(pWal: PWal): cint;
function  sqlite3WalEndWriteTransaction(pWal: PWal): cint;
function  sqlite3WalUndo(pWal: PWal; xUndo: TxUndoCallback; pUndoCtx: Pointer): cint;
procedure sqlite3WalSavepoint(pWal: PWal; aWalData: Pu32);
function  sqlite3WalSavepointUndo(pWal: PWal; aWalData: Pu32): cint;
function  sqlite3WalFrames(pWal: PWal; szPage: cint; pList: PPgHdr;
                           nTruncate: Pgno; isCommit: cint;
                           sync_flags: cint): cint;
function  sqlite3WalCheckpoint(pWal: PWal; db: Pointer; eMode: cint;
                               xBusy: TxBusyCallback; pBusyArg: Pointer;
                               sync_flags: cint; nBuf: cint; zBuf: Pu8;
                               pnLog: PcInt; pnCkpt: PcInt): cint;
function  sqlite3WalCallback(pWal: PWal): cint;
function  sqlite3WalExclusiveMode(pWal: PWal; op: cint): cint;
function  sqlite3WalHeapMemory(pWal: PWal): cint;
function  sqlite3WalFile(pWal: PWal): Psqlite3_file;

implementation

uses
  BaseUnix;

{ ============================================================
  Local stubs and helpers (avoid circular dependency with pager.pas)
  ============================================================ }

{ Local sqlite3Realloc: realloc with zero-free semantics }
function sqlite3Realloc(p: Pointer; n: NativeUInt): Pointer;
begin
  if n = 0 then begin
    sqlite3_free(p);
    Result := nil;
  end else begin
    Result := sqlite3_realloc(p, n);
  end;
end;

{ Local sqlite3_log stub — full impl deferred to Phase 8 (main.c) }
procedure sqlite3_log_wal(iErrCode: i32; zMsg: PChar);
begin
  { no-op stub }
  iErrCode := iErrCode; { suppress unused warning }
  zMsg := zMsg;
end;

{ sqlite3SectorSize: minimum sector size from VFS (pager.c ~2694) }
function sqlite3SectorSize(pFile: Psqlite3_file): i32;
begin
  Result := sqlite3OsSectorSize(pFile);
  if Result < 32 then Result := SQLITE_DEFAULT_SECTOR_SIZE
  else if Result > $10000 then Result := $10000;
end;

{ ============================================================
  AtomicLoad / AtomicStore  (no-op wrappers; single-threaded port)
  ============================================================ }

function AtomicLoad(p: Pu32): u32; inline;
begin
  Result := p^;
end;

procedure AtomicStore(p: Pu32; val: u32); inline;
begin
  p^ := val;
end;

{ ============================================================
  BYTESWAP32 macro
  ============================================================ }

function BYTESWAP32(x: u32): u32; inline;
begin
  Result := ((x and $000000FF) shl 24)
          + ((x and $0000FF00) shl 8)
          + ((x and $00FF0000) shr 8)
          + ((x and $FF000000) shr 24);
end;

{ ============================================================
  walFrameOffset macro (wal.c ~498)
  ============================================================ }

function walFrameOffset(iFrame: u32; szPage: i32): i64; inline;
begin
  Result := WAL_HDRSIZE + i64(iFrame - 1) * i64(szPage + WAL_FRAME_HDRSIZE);
end;

{ ============================================================
  WAL_SYNC_FLAGS / CKPT_SYNC_FLAGS
  ============================================================ }

function WAL_SYNC_FLAGS(x: cint): cint; inline;
begin
  Result := x and $03;
end;

function CKPT_SYNC_FLAGS(x: cint): cint; inline;
begin
  Result := (x shr 2) and $03;
end;

function WAL_READ_LOCK(i: cint): cint; inline;
begin
  Result := 3 + i;
end;

{ ============================================================
  Helper: get page k of wal-index as Pu32
  ============================================================ }

function walGetWiPage(pWal: PWal; iPage: cint): Pu32; inline;
begin
  Result := (pWal^.apWiData + iPage)^;
end;

procedure walSetWiPage(pWal: PWal; iPage: cint; p: Pu32); inline;
begin
  (pWal^.apWiData + iPage)^ := p;
end;

{ ============================================================
  walCkptInfo / walIndexHdr (wal.c ~820,829)
  ============================================================ }

function walCkptInfo(pWal: PWal): PWalCkptInfo; inline;
begin
  { WalCkptInfo starts at byte offset 2*sizeof(TWalIndexHdr) = 96 }
  { apWiData[0] is Pu32; advance by sizeof(TWalIndexHdr)/sizeof(u32) * 2 = 24 }
  Result := PWalCkptInfo(walGetWiPage(pWal, 0) + SizeOf(TWalIndexHdr) div 2);
end;

function walIndexHdr(pWal: PWal): PWalIndexHdr; inline;
begin
  Result := PWalIndexHdr(walGetWiPage(pWal, 0));
end;

{ ============================================================
  walShmBarrier (wal.c ~918)
  ============================================================ }

procedure walShmBarrier(pWal: PWal);
begin
  if pWal^.exclusiveMode <> WAL_HEAPMEMORY_MODE then
    sqlite3OsShmBarrier(pWal^.pDbFd);
end;

{ ============================================================
  walChecksumBytes (wal.c ~856)
  ============================================================ }

procedure walChecksumBytes(nativeCksum: cint; a: Pu8; nByte: cint;
                            aIn: Pu32; aOut: Pu32);
var
  s1, s2  : u32;
  aData   : Pu32;
  aEnd    : Pu32;
begin
  aData := Pu32(a);
  aEnd  := Pu32(a + nByte);

  if aIn <> nil then begin
    s1 := aIn[0];
    s2 := aIn[1];
  end else begin
    s1 := 0; s2 := 0;
  end;

  if nativeCksum = 0 then begin
    repeat
      s1 += BYTESWAP32(aData[0]) + s2;
      s2 += BYTESWAP32(aData[1]) + s1;
      aData := aData + 2;
    until aData >= aEnd;
  end else if (nByte mod 64) = 0 then begin
    repeat
      s1 += aData[0] + s2;  aData := aData + 1;
      s2 += aData[0] + s1;  aData := aData + 1;
      s1 += aData[0] + s2;  aData := aData + 1;
      s2 += aData[0] + s1;  aData := aData + 1;
      s1 += aData[0] + s2;  aData := aData + 1;
      s2 += aData[0] + s1;  aData := aData + 1;
      s1 += aData[0] + s2;  aData := aData + 1;
      s2 += aData[0] + s1;  aData := aData + 1;
      s1 += aData[0] + s2;  aData := aData + 1;
      s2 += aData[0] + s1;  aData := aData + 1;
      s1 += aData[0] + s2;  aData := aData + 1;
      s2 += aData[0] + s1;  aData := aData + 1;
      s1 += aData[0] + s2;  aData := aData + 1;
      s2 += aData[0] + s1;  aData := aData + 1;
      s1 += aData[0] + s2;  aData := aData + 1;
      s2 += aData[0] + s1;  aData := aData + 1;
    until aData >= aEnd;
  end else begin
    repeat
      s1 += aData[0] + s2;  aData := aData + 1;
      s2 += aData[0] + s1;  aData := aData + 1;
    until aData >= aEnd;
  end;

  aOut[0] := s1;
  aOut[1] := s2;
end;

{ ============================================================
  walIndexWriteHdr (wal.c ~942)
  ============================================================ }

procedure walIndexWriteHdr(pWal: PWal);
var
  aHdr   : PWalIndexHdr;
  nCksum : cint;
begin
  aHdr := walIndexHdr(pWal);
  nCksum := SizeOf(TWalIndexHdr) - SizeOf(pWal^.hdr.aCksum);

  pWal^.hdr.isInit := 1;
  pWal^.hdr.iVersion := WALINDEX_MAX_VERSION;
  walChecksumBytes(1, Pu8(@pWal^.hdr), nCksum, nil, @pWal^.hdr.aCksum[0]);
  Move(pWal^.hdr, (aHdr + 1)^, SizeOf(TWalIndexHdr));
  walShmBarrier(pWal);
  Move(pWal^.hdr, aHdr^, SizeOf(TWalIndexHdr));
end;

{ ============================================================
  walEncodeFrame (wal.c ~969)
  ============================================================ }

procedure walEncodeFrame(pWal: PWal; iPage: u32; nTruncate: u32;
                         aData: Pu8; aFrame: Pu8);
var
  nativeCksum : cint;
  aCksum      : Pu32;
begin
  aCksum := @pWal^.hdr.aFrameCksum[0];
  sqlite3Put4byte(@aFrame[0], iPage);
  sqlite3Put4byte(@aFrame[4], nTruncate);
  if pWal^.iReCksum = 0 then begin
    Move(pWal^.hdr.aSalt[0], aFrame[8], 8);
    nativeCksum := ord(pWal^.hdr.bigEndCksum = SQLITE_BIGENDIAN);
    walChecksumBytes(nativeCksum, aFrame, 8, aCksum, aCksum);
    walChecksumBytes(nativeCksum, aData, cint(pWal^.szPage), aCksum, aCksum);
    sqlite3Put4byte(@aFrame[16], aCksum[0]);
    sqlite3Put4byte(@aFrame[20], aCksum[1]);
  end else begin
    FillChar(aFrame[8], 16, 0);
  end;
end;

{ ============================================================
  walDecodeFrame (wal.c ~1000)
  ============================================================ }

function walDecodeFrame(pWal: PWal; piPage: Pu32; pnTruncate: Pu32;
                        aData: Pu8; aFrame: Pu8): cint;
var
  nativeCksum : cint;
  aCksum      : Pu32;
  pgno        : u32;
begin
  aCksum := @pWal^.hdr.aFrameCksum[0];

  if CompareByte(pWal^.hdr.aSalt[0], aFrame[8], 8) <> 0 then begin
    Result := 0; Exit;
  end;

  pgno := sqlite3Get4byte(@aFrame[0]);
  if pgno = 0 then begin
    Result := 0; Exit;
  end;

  nativeCksum := ord(pWal^.hdr.bigEndCksum = SQLITE_BIGENDIAN);
  walChecksumBytes(nativeCksum, aFrame, 8, aCksum, aCksum);
  walChecksumBytes(nativeCksum, aData, cint(pWal^.szPage), aCksum, aCksum);
  if (aCksum[0] <> sqlite3Get4byte(@aFrame[16]))
  or (aCksum[1] <> sqlite3Get4byte(@aFrame[20])) then begin
    Result := 0; Exit;
  end;

  piPage^    := pgno;
  pnTruncate^ := sqlite3Get4byte(@aFrame[4]);
  Result := 1;
end;

{ ============================================================
  Lock helpers (wal.c ~1079)
  ============================================================ }

function walLockShared(pWal: PWal; lockIdx: cint): cint;
begin
  if pWal^.exclusiveMode <> 0 then begin
    Result := SQLITE_OK; Exit;
  end;
  Result := sqlite3OsShmLock(pWal^.pDbFd, lockIdx, 1,
                              SQLITE_SHM_LOCK or SQLITE_SHM_SHARED);
end;

procedure walUnlockShared(pWal: PWal; lockIdx: cint);
begin
  if pWal^.exclusiveMode <> 0 then Exit;
  sqlite3OsShmLock(pWal^.pDbFd, lockIdx, 1,
                   SQLITE_SHM_UNLOCK or SQLITE_SHM_SHARED);
end;

function walLockExclusive(pWal: PWal; lockIdx: cint; n: cint): cint;
begin
  if pWal^.exclusiveMode <> 0 then begin
    Result := SQLITE_OK; Exit;
  end;
  Result := sqlite3OsShmLock(pWal^.pDbFd, lockIdx, n,
                              SQLITE_SHM_LOCK or SQLITE_SHM_EXCLUSIVE);
end;

procedure walUnlockExclusive(pWal: PWal; lockIdx: cint; n: cint);
begin
  if pWal^.exclusiveMode <> 0 then Exit;
  sqlite3OsShmLock(pWal^.pDbFd, lockIdx, n,
                   SQLITE_SHM_UNLOCK or SQLITE_SHM_EXCLUSIVE);
end;

{ ============================================================
  Hash helpers (wal.c ~1132)
  ============================================================ }

function walHash(iPage: u32): cint; inline;
begin
  Result := cint((iPage * HASHTABLE_HASH_1) and (HASHTABLE_NSLOT - 1));
end;

function walNextHash(iPriorHash: cint): cint; inline;
begin
  Result := (iPriorHash + 1) and (HASHTABLE_NSLOT - 1);
end;

{ ============================================================
  walFramePage / walFramePgno (wal.c ~1197, ~1212)
  ============================================================ }

function walFramePage(iFrame: u32): cint; inline;
begin
  Result := cint((iFrame + HASHTABLE_NPAGE - HASHTABLE_NPAGE_ONE - 1) div HASHTABLE_NPAGE);
end;

function walFramePgno(pWal: PWal; iFrame: u32): u32; inline;
var
  iHash : cint;
begin
  iHash := walFramePage(iFrame);
  if iHash = 0 then
    Result := walGetWiPage(pWal, 0)[WALINDEX_HDR_SIZE div SizeOf(u32) + iFrame - 1]
  else
    Result := walGetWiPage(pWal, iHash)[(iFrame - 1 - HASHTABLE_NPAGE_ONE) mod HASHTABLE_NPAGE];
end;

{ ============================================================
  walIndexPageRealloc (wal.c ~756) + walIndexPage (wal.c ~805)
  ============================================================ }

function walIndexPageRealloc(pWal: PWal; iPage: cint;
                              ppPage: PPu32): cint;
var
  nByte  : i64;
  apNew  : PPu32;
begin
  Result := SQLITE_OK;

  if pWal^.nWiData <= iPage then begin
    nByte := i64(SizeOf(Pu32)) * (1 + i64(iPage));
    apNew := PPu32(sqlite3Realloc(pWal^.apWiData, NativeUInt(nByte)));
    if apNew = nil then begin
      ppPage^ := nil;
      Result := SQLITE_NOMEM_BKPT; Exit;
    end;
    FillChar((apNew + pWal^.nWiData)^,
             SizeOf(Pu32) * (iPage + 1 - pWal^.nWiData), 0);
    pWal^.apWiData := apNew;
    pWal^.nWiData  := iPage + 1;
  end;

  if pWal^.exclusiveMode = WAL_HEAPMEMORY_MODE then begin
    (pWal^.apWiData + iPage)^ := Pu32(sqlite3MallocZero(WALINDEX_PGSZ));
    if (pWal^.apWiData + iPage)^ = nil then
      Result := SQLITE_NOMEM_BKPT;
  end else begin
    Result := sqlite3OsShmMap(pWal^.pDbFd, iPage, WALINDEX_PGSZ,
                               cint(pWal^.writeLock),
                               @(pWal^.apWiData + iPage)^);
    if Result = SQLITE_OK then begin
      { ok }
    end else if (Result and $FF) = SQLITE_READONLY then begin
      pWal^.readOnly := pWal^.readOnly or WAL_SHM_RDONLY;
      if Result = SQLITE_READONLY then
        Result := SQLITE_OK;
    end;
  end;

  ppPage^ := (pWal^.apWiData + iPage)^;
  if (ppPage^ = nil) and (Result = SQLITE_OK) then
    Result := SQLITE_ERROR;
end;

function walIndexPage(pWal: PWal; iPage: cint; ppPage: PPu32): cint;
begin
  if (pWal^.nWiData <= iPage) or ((pWal^.apWiData + iPage)^ = nil) then
    Result := walIndexPageRealloc(pWal, iPage, ppPage)
  else begin
    ppPage^ := (pWal^.apWiData + iPage)^;
    Result := SQLITE_OK;
  end;
end;

{ ============================================================
  walHashGet (wal.c ~1167)
  ============================================================ }

function walHashGet(pWal: PWal; iHash: cint; pLoc: PWalHashLoc): cint;
begin
  Result := walIndexPage(pWal, iHash, @pLoc^.aPgno);
  if pLoc^.aPgno <> nil then begin
    pLoc^.aHash := PHtSlot(pLoc^.aPgno + HASHTABLE_NPAGE);
    if iHash = 0 then begin
      pLoc^.aPgno := pLoc^.aPgno + WALINDEX_HDR_SIZE div SizeOf(u32);
      pLoc^.iZero := 0;
    end else begin
      pLoc^.iZero := HASHTABLE_NPAGE_ONE + u32(iHash - 1) * HASHTABLE_NPAGE;
    end;
  end else if Result = SQLITE_OK then begin
    Result := SQLITE_ERROR;
  end;
end;

{ ============================================================
  walCleanupHash (wal.c ~1233)
  ============================================================ }

procedure walCleanupHash(pWal: PWal);
var
  sLoc   : TWalHashLoc;
  iLimit : cint;
  nByte  : cint;
  i      : cint;
begin
  if pWal^.hdr.mxFrame = 0 then Exit;

  if walHashGet(pWal, walFramePage(pWal^.hdr.mxFrame), @sLoc) <> 0 then Exit;

  iLimit := cint(pWal^.hdr.mxFrame - sLoc.iZero);
  for i := 0 to HASHTABLE_NSLOT - 1 do begin
    if cint(sLoc.aHash[i]) > iLimit then
      sLoc.aHash[i] := 0;
  end;

  nByte := cint(PByte(sLoc.aHash) - PByte(@sLoc.aPgno[iLimit]));
  if nByte > 0 then
    FillChar(sLoc.aPgno[iLimit], nByte, 0);
end;

{ ============================================================
  walIndexAppend (wal.c ~1295)
  ============================================================ }

function walIndexAppend(pWal: PWal; iFrame: u32; iPage: u32): cint;
var
  sLoc    : TWalHashLoc;
  iKey    : cint;
  idx     : cint;
  nCollide : cint;
  nByte   : cint;
begin
  Result := walHashGet(pWal, walFramePage(iFrame), @sLoc);
  if Result <> SQLITE_OK then Exit;

  idx := cint(iFrame - sLoc.iZero);

  if idx = 1 then begin
    nByte := cint(PByte(@sLoc.aHash[HASHTABLE_NSLOT]) - PByte(sLoc.aPgno));
    if nByte > 0 then FillChar(sLoc.aPgno^, nByte, 0);
  end;

  if sLoc.aPgno[idx - 1] <> 0 then
    walCleanupHash(pWal);

  nCollide := idx;
  iKey := walHash(iPage);
  while sLoc.aHash[iKey] <> 0 do begin
    Dec(nCollide);
    if nCollide = 0 then begin
      Result := SQLITE_CORRUPT_BKPT; Exit;
    end;
    iKey := walNextHash(iKey);
  end;
  sLoc.aPgno[(idx - 1) and (HASHTABLE_NPAGE - 1)] := iPage;
  AtomicStore(@sLoc.aHash[iKey], ht_slot(idx));

  Result := SQLITE_OK;
end;

{ ============================================================
  walIndexClose (wal.c ~1613)
  ============================================================ }

procedure walIndexClose(pWal: PWal; isDelete: cint);
var
  i : cint;
begin
  if (pWal^.exclusiveMode = WAL_HEAPMEMORY_MODE) or (pWal^.bShmUnreliable <> 0) then begin
    if pWal^.nWiData > 0 then
      for i := 0 to pWal^.nWiData - 1 do begin
        sqlite3_free((pWal^.apWiData + i)^);
        (pWal^.apWiData + i)^ := nil;
      end;
  end;
  if pWal^.exclusiveMode <> WAL_HEAPMEMORY_MODE then
    sqlite3OsShmUnmap(pWal^.pDbFd, isDelete);
end;

{ ============================================================
  walIndexRecover (wal.c ~1384)
  ============================================================ }

function walIndexRecover(pWal: PWal): cint;
label
  finished, recovery_error;
var
  rc           : cint;
  nSize        : i64;
  aFrameCksum  : array[0..1] of u32;
  iLock        : cint;
  aBuf         : array[0..WAL_HDRSIZE - 1] of u8;
  aPrivate     : Pu32;
  aFrame       : Pu8;
  szFrame      : cint;
  aData        : Pu8;
  szPage       : cint;
  magic        : u32;
  version      : u32;
  isValid      : cint;
  iPg          : u32;
  iLastFrame   : u32;
  aShare       : Pu32;
  iFrame       : u32;
  iLast        : u32;
  iFirst       : u32;
  nHdr, nHdr32 : u32;
  pgno, nTrunc : u32;
  iOffset      : i64;
  pInfo        : PWalCkptInfo;
  i            : cint;
begin
  aFrameCksum[0] := 0; aFrameCksum[1] := 0;
  aFrame := nil;
  aPrivate := nil;

  iLock := WAL_ALL_BUT_WRITE + cint(pWal^.ckptLock);
  rc := walLockExclusive(pWal, iLock, WAL_READ_LOCK(0) - iLock);
  if rc <> SQLITE_OK then begin
    Result := rc; Exit;
  end;

  FillChar(pWal^.hdr, SizeOf(TWalIndexHdr), 0);

  rc := sqlite3OsFileSize(pWal^.pWalFd, @nSize);
  if rc <> SQLITE_OK then goto recovery_error;

  if nSize > WAL_HDRSIZE then begin
    rc := sqlite3OsRead(pWal^.pWalFd, @aBuf[0], WAL_HDRSIZE, 0);
    if rc <> SQLITE_OK then goto recovery_error;

    magic  := sqlite3Get4byte(@aBuf[0]);
    szPage := cint(sqlite3Get4byte(@aBuf[8]));
    if ((magic and $FFFFFFFE) <> WAL_MAGIC)
    or ((szPage and (szPage - 1)) <> 0)
    or (szPage > SQLITE_MAX_PAGE_SIZE)
    or (szPage < 512)
    then
      goto finished;

    pWal^.hdr.bigEndCksum := u8(magic and 1);
    pWal^.szPage := u32(szPage);
    pWal^.nCkpt  := sqlite3Get4byte(@aBuf[12]);
    Move(aBuf[16], pWal^.hdr.aSalt[0], 8);

    walChecksumBytes(cint(pWal^.hdr.bigEndCksum = SQLITE_BIGENDIAN),
                     @aBuf[0], WAL_HDRSIZE - 8, nil,
                     @pWal^.hdr.aFrameCksum[0]);
    if (pWal^.hdr.aFrameCksum[0] <> sqlite3Get4byte(@aBuf[24]))
    or (pWal^.hdr.aFrameCksum[1] <> sqlite3Get4byte(@aBuf[28]))
    then
      goto finished;

    version := sqlite3Get4byte(@aBuf[4]);
    if version <> WAL_MAX_VERSION then begin
      rc := SQLITE_CANTOPEN_BKPT; goto finished;
    end;

    szFrame := szPage + WAL_FRAME_HDRSIZE;
    aFrame  := Pu8(sqlite3_malloc64(szFrame + WALINDEX_PGSZ));
    if aFrame = nil then begin
      rc := SQLITE_NOMEM_BKPT; goto recovery_error;
    end;
    aData    := aFrame + WAL_FRAME_HDRSIZE;
    aPrivate := Pu32(aData + szPage);

    iLastFrame := u32((nSize - WAL_HDRSIZE) div szFrame);
    iPg := 0;
    while iPg <= u32(walFramePage(iLastFrame)) do begin
      rc := walIndexPage(pWal, cint(iPg), PPu32(@aShare));
      if (aShare = nil) then begin
        if rc = SQLITE_OK then rc := SQLITE_ERROR;
        break;
      end;
      walSetWiPage(pWal, cint(iPg), aPrivate);

      if iPg = 0 then iFirst := 1
      else iFirst := 1 + HASHTABLE_NPAGE_ONE + (iPg - 1) * HASHTABLE_NPAGE;
      if iPg = u32(walFramePage(iLastFrame)) then
        iLast := iLastFrame
      else
        iLast := HASHTABLE_NPAGE_ONE + iPg * HASHTABLE_NPAGE;

      iFrame := iFirst;
      while iFrame <= iLast do begin
        iOffset := walFrameOffset(iFrame, szPage);
        rc := sqlite3OsRead(pWal^.pWalFd, aFrame, szFrame, iOffset);
        if rc <> SQLITE_OK then break;
        isValid := walDecodeFrame(pWal, @pgno, @nTrunc, aData, aFrame);
        if isValid = 0 then break;
        rc := walIndexAppend(pWal, iFrame, pgno);
        if rc <> SQLITE_OK then break;
        if nTrunc <> 0 then begin
          pWal^.hdr.mxFrame := iFrame;
          pWal^.hdr.nPage   := nTrunc;
          pWal^.hdr.szPage  := u16((szPage and $FF00) or (szPage shr 16));
          aFrameCksum[0]    := pWal^.hdr.aFrameCksum[0];
          aFrameCksum[1]    := pWal^.hdr.aFrameCksum[1];
        end;
        Inc(iFrame);
      end;

      walSetWiPage(pWal, cint(iPg), aShare);
      if iPg = 0 then nHdr := WALINDEX_HDR_SIZE else nHdr := 0;
      nHdr32 := nHdr div SizeOf(u32);
      Move((aShare + nHdr32)^, (aPrivate + nHdr32)^, WALINDEX_PGSZ - cint(nHdr));

      if iFrame <= iLast then break;
      Inc(iPg);
    end;

    sqlite3_free(aFrame);
    aFrame := nil;
  end;

  finished:
  if rc = SQLITE_OK then begin
    pWal^.hdr.aFrameCksum[0] := aFrameCksum[0];
    pWal^.hdr.aFrameCksum[1] := aFrameCksum[1];
    walIndexWriteHdr(pWal);

    pInfo := walCkptInfo(pWal);
    pInfo^.nBackfill := 0;
    pInfo^.nBackfillAttempted := pWal^.hdr.mxFrame;
    pInfo^.aReadMark[0] := 0;
    for i := 1 to WAL_NREADER - 1 do begin
      rc := walLockExclusive(pWal, WAL_READ_LOCK(i), 1);
      if rc = SQLITE_OK then begin
        if (i = 1) and (pWal^.hdr.mxFrame <> 0) then
          pInfo^.aReadMark[i] := pWal^.hdr.mxFrame
        else
          pInfo^.aReadMark[i] := READMARK_NOT_USED;
        walUnlockExclusive(pWal, WAL_READ_LOCK(i), 1);
        rc := SQLITE_OK;
      end else if rc <> SQLITE_BUSY then begin
        goto recovery_error;
      end;
    end;

    if pWal^.hdr.nPage <> 0 then
      sqlite3_log_wal(SQLITE_NOTICE_RECOVER_WAL, pWal^.zWalName);
  end;

  recovery_error:
  walUnlockExclusive(pWal, iLock, WAL_READ_LOCK(0) - iLock);
  Result := rc;
end;

{ ============================================================
  walRestartHdr (wal.c ~2146)
  ============================================================ }

procedure walRestartHdr(pWal: PWal; salt1: u32);
var
  pInfo : PWalCkptInfo;
  aSalt : Pu32;
  i     : cint;
begin
  pInfo := walCkptInfo(pWal);
  aSalt := @pWal^.hdr.aSalt[0];
  Inc(pWal^.nCkpt);
  pWal^.hdr.mxFrame := 0;
  sqlite3Put4byte(Pu8(aSalt), 1 + sqlite3Get4byte(Pu8(aSalt)));
  Move(salt1, pWal^.hdr.aSalt[1], 4);
  walIndexWriteHdr(pWal);
  AtomicStore(@pInfo^.nBackfill, 0);
  pInfo^.nBackfillAttempted := 0;
  pInfo^.aReadMark[1] := 0;
  for i := 2 to WAL_NREADER - 1 do
    pInfo^.aReadMark[i] := READMARK_NOT_USED;
end;

{ ============================================================
  walLimitSize (wal.c ~2395)
  ============================================================ }

procedure walLimitSize(pWal: PWal; nMax: i64);
var
  sz : i64;
  rx : cint;
begin
  sqlite3BeginBenignMalloc;
  rx := sqlite3OsFileSize(pWal^.pWalFd, @sz);
  if (rx = SQLITE_OK) and (sz > nMax) then
    rx := sqlite3OsTruncate(pWal^.pWalFd, nMax);
  sqlite3EndBenignMalloc;
  if rx <> SQLITE_OK then
    sqlite3_log_wal(rx, pWal^.zWalName);
end;

{ ============================================================
  walIndexTryHdr (wal.c ~2584)
  ============================================================ }

function walIndexTryHdr(pWal: PWal; pChanged: PcInt): cint;
var
  aCksum : array[0..1] of u32;
  h1, h2 : TWalIndexHdr;
  aHdr   : PWalIndexHdr;
begin
  aHdr := walIndexHdr(pWal);
  Move(aHdr^,     h1, SizeOf(TWalIndexHdr));
  walShmBarrier(pWal);
  Move((aHdr + 1)^, h2, SizeOf(TWalIndexHdr));

  if CompareByte(h1, h2, SizeOf(TWalIndexHdr)) <> 0 then begin
    Result := 1; Exit;
  end;
  if h1.isInit = 0 then begin
    Result := 1; Exit;
  end;
  walChecksumBytes(1, Pu8(@h1),
                   SizeOf(TWalIndexHdr) - SizeOf(h1.aCksum),
                   nil, @aCksum[0]);
  if (aCksum[0] <> h1.aCksum[0]) or (aCksum[1] <> h1.aCksum[1]) then begin
    Result := 1; Exit;
  end;

  if CompareByte(pWal^.hdr, h1, SizeOf(TWalIndexHdr)) <> 0 then begin
    pChanged^ := 1;
    Move(h1, pWal^.hdr, SizeOf(TWalIndexHdr));
    pWal^.szPage := u32(pWal^.hdr.szPage and $FE00) +
                    u32((pWal^.hdr.szPage and 1) shl 16);
  end;

  Result := 0;
end;

{ ============================================================
  walIndexReadHdr (wal.c ~2654)
  ============================================================ }

function walIndexReadHdr(pWal: PWal; pChanged: PcInt): cint;
var
  rc       : cint;
  badHdr   : cint;
  page0    : Pu32;
  bWriteLock : cint;
begin
  rc := walIndexPage(pWal, 0, @page0);
  if rc <> SQLITE_OK then begin
    if rc = SQLITE_READONLY_CANTINIT then begin
      pWal^.bShmUnreliable := 1;
      pWal^.exclusiveMode  := WAL_HEAPMEMORY_MODE;
      pChanged^            := 1;
    end else begin
      Result := rc; Exit;
    end;
  end;

  badHdr := 1;
  if page0 <> nil then
    badHdr := walIndexTryHdr(pWal, pChanged);

  if badHdr <> 0 then begin
    if (pWal^.bShmUnreliable = 0) and ((pWal^.readOnly and WAL_SHM_RDONLY) <> 0) then begin
      if walLockShared(pWal, WAL_WRITE_LOCK) = SQLITE_OK then begin
        walUnlockShared(pWal, WAL_WRITE_LOCK);
        rc := SQLITE_READONLY_RECOVERY;
      end;
    end else begin
      bWriteLock := cint(pWal^.writeLock);
      if (bWriteLock <> 0)
      or (walLockExclusive(pWal, WAL_WRITE_LOCK, 1) = SQLITE_OK) then begin
        if bWriteLock = 0 then pWal^.writeLock := 2;
        if walIndexPage(pWal, 0, @page0) = SQLITE_OK then begin
          badHdr := walIndexTryHdr(pWal, pChanged);
          if badHdr <> 0 then begin
            rc := walIndexRecover(pWal);
            pChanged^ := 1;
          end;
        end;
        if bWriteLock = 0 then begin
          pWal^.writeLock := 0;
          walUnlockExclusive(pWal, WAL_WRITE_LOCK, 1);
        end;
      end;
    end;
  end;

  if (badHdr = 0) and (pWal^.hdr.iVersion <> WALINDEX_MAX_VERSION) then
    rc := SQLITE_CANTOPEN_BKPT;

  if pWal^.bShmUnreliable <> 0 then begin
    if rc <> SQLITE_OK then begin
      walIndexClose(pWal, 0);
      pWal^.bShmUnreliable := 0;
      if rc = SQLITE_IOERR_SHORT_READ then rc := WAL_RETRY;
    end;
    pWal^.exclusiveMode := WAL_NORMAL_MODE;
  end;

  Result := rc;
end;

{ ============================================================
  walBeginShmUnreliable (wal.c ~2786)
  ============================================================ }

function walBeginShmUnreliable(pWal: PWal; pChanged: PcInt): cint;
label
  begin_unreliable_shm_out;
var
  szWal     : i64;
  iOffset   : i64;
  aBuf      : array[0..WAL_HDRSIZE-1] of u8;
  aFrame    : Pu8;
  szFrame   : cint;
  aData     : Pu8;
  pDummy    : Pointer;
  rc        : cint;
  aSaveCksum : array[0..1] of u32;
  pgno, nTrunc : u32;
  ii        : cint;
begin
  aFrame := nil;

  rc := walLockShared(pWal, WAL_READ_LOCK(0));
  if rc <> SQLITE_OK then begin
    if rc = SQLITE_BUSY then rc := WAL_RETRY;
    goto begin_unreliable_shm_out;
  end;
  pWal^.readLock := 0;

  rc := sqlite3OsShmMap(pWal^.pDbFd, 0, WALINDEX_PGSZ, 0, @pDummy);
  if rc <> SQLITE_READONLY_CANTINIT then begin
    if rc = SQLITE_READONLY then rc := WAL_RETRY;
    goto begin_unreliable_shm_out;
  end;

  Move(walIndexHdr(pWal)^, pWal^.hdr, SizeOf(TWalIndexHdr));

  rc := sqlite3OsFileSize(pWal^.pWalFd, @szWal);
  if rc <> SQLITE_OK then goto begin_unreliable_shm_out;
  if szWal < WAL_HDRSIZE then begin
    pChanged^ := 1;
    if pWal^.hdr.mxFrame = 0 then rc := SQLITE_OK
    else rc := WAL_RETRY;
    goto begin_unreliable_shm_out;
  end;

  rc := sqlite3OsRead(pWal^.pWalFd, @aBuf[0], WAL_HDRSIZE, 0);
  if rc <> SQLITE_OK then goto begin_unreliable_shm_out;
  if CompareByte(pWal^.hdr.aSalt[0], aBuf[16], 8) <> 0 then begin
    rc := WAL_RETRY;
    goto begin_unreliable_shm_out;
  end;

  szFrame := cint(pWal^.szPage) + WAL_FRAME_HDRSIZE;
  aFrame  := Pu8(sqlite3_malloc64(szFrame));
  if aFrame = nil then begin
    rc := SQLITE_NOMEM_BKPT;
    goto begin_unreliable_shm_out;
  end;
  aData := aFrame + WAL_FRAME_HDRSIZE;

  aSaveCksum[0] := pWal^.hdr.aFrameCksum[0];
  aSaveCksum[1] := pWal^.hdr.aFrameCksum[1];
  iOffset := walFrameOffset(pWal^.hdr.mxFrame + 1, cint(pWal^.szPage));
  while iOffset + szFrame <= szWal do begin
    rc := sqlite3OsRead(pWal^.pWalFd, aFrame, szFrame, iOffset);
    if rc <> SQLITE_OK then break;
    if walDecodeFrame(pWal, @pgno, @nTrunc, aData, aFrame) = 0 then break;
    if nTrunc <> 0 then begin
      rc := WAL_RETRY; break;
    end;
    iOffset += szFrame;
  end;
  pWal^.hdr.aFrameCksum[0] := aSaveCksum[0];
  pWal^.hdr.aFrameCksum[1] := aSaveCksum[1];

  begin_unreliable_shm_out:
  sqlite3_free(aFrame);
  if rc <> SQLITE_OK then begin
    if pWal^.nWiData > 0 then begin
      for ii := 0 to pWal^.nWiData - 1 do begin
        sqlite3_free((pWal^.apWiData + ii)^);
        (pWal^.apWiData + ii)^ := nil;
      end;
    end;
    pWal^.bShmUnreliable := 0;
    sqlite3WalEndReadTransaction(pWal);
    pChanged^ := 1;
  end;
  Result := rc;
end;

{ ============================================================
  walTryBeginRead (wal.c ~3014)
  ============================================================ }

function walTryBeginRead(pWal: PWal; pChanged: PcInt; useWal: cint;
                         pCnt: PcInt): cint;
var
  pInfo      : PWalCkptInfo;
  rc         : cint;
  mxReadMark : u32;
  mxI, mxFrame, i : cint;
  thisMark   : u32;
  nDelay     : cint;
  cnt        : cint;
begin
  rc := SQLITE_OK;
  Inc(pCnt^);
  if pCnt^ > 5 then begin
    nDelay := 1;
    cnt := pCnt^;
    if cnt > WAL_RETRY_PROTOCOL_LIMIT then begin
      Result := SQLITE_PROTOCOL; Exit;
    end;
    if cnt >= 10 then nDelay := (cnt - 9) * (cnt - 9) * 39;
    sqlite3OsSleep(pWal^.pVfs, nDelay);
  end;

  if useWal = 0 then begin
    if pWal^.bShmUnreliable = 0 then
      rc := walIndexReadHdr(pWal, pChanged);
    if rc = SQLITE_BUSY then begin
      if (pWal^.apWiData + 0)^ = nil then
        rc := WAL_RETRY
      else if walLockShared(pWal, WAL_RECOVER_LOCK) = SQLITE_OK then begin
        walUnlockShared(pWal, WAL_RECOVER_LOCK);
        rc := WAL_RETRY;
      end else if rc = SQLITE_BUSY then
        rc := SQLITE_BUSY_RECOVERY;
    end;
    if rc <> SQLITE_OK then begin
      Result := rc; Exit;
    end;
    if pWal^.bShmUnreliable <> 0 then begin
      Result := walBeginShmUnreliable(pWal, pChanged); Exit;
    end;
  end;

  pInfo := walCkptInfo(pWal);
  mxFrame := cint(pWal^.hdr.mxFrame);

  if (useWal = 0) and (AtomicLoad(@pInfo^.nBackfill) = u32(mxFrame)) then begin
    rc := walLockShared(pWal, WAL_READ_LOCK(0));
    walShmBarrier(pWal);
    if rc = SQLITE_OK then begin
      if CompareByte(walIndexHdr(pWal)^, pWal^.hdr, SizeOf(TWalIndexHdr)) <> 0 then begin
        walUnlockShared(pWal, WAL_READ_LOCK(0));
        Result := WAL_RETRY; Exit;
      end;
      pWal^.readLock := 0;
      Result := SQLITE_OK; Exit;
    end else if rc <> SQLITE_BUSY then begin
      Result := rc; Exit;
    end;
  end;

  mxReadMark := 0;
  mxI := 0;
  for i := 1 to WAL_NREADER - 1 do begin
    thisMark := AtomicLoad(@pInfo^.aReadMark[i]);
    if (mxReadMark <= thisMark) and (thisMark <= u32(mxFrame)) then begin
      mxReadMark := thisMark;
      mxI := i;
    end;
  end;
  if ((pWal^.readOnly and WAL_SHM_RDONLY) = 0)
  and ((mxReadMark < u32(mxFrame)) or (mxI = 0)) then begin
    for i := 1 to WAL_NREADER - 1 do begin
      rc := walLockExclusive(pWal, WAL_READ_LOCK(i), 1);
      if rc = SQLITE_OK then begin
        AtomicStore(@pInfo^.aReadMark[i], u32(mxFrame));
        mxReadMark := u32(mxFrame);
        mxI := i;
        walUnlockExclusive(pWal, WAL_READ_LOCK(i), 1);
        break;
      end else if rc <> SQLITE_BUSY then begin
        Result := rc; Exit;
      end;
    end;
  end;
  if mxI = 0 then begin
    if rc = SQLITE_BUSY then Result := WAL_RETRY
    else Result := SQLITE_READONLY_CANTINIT;
    Exit;
  end;

  rc := walLockShared(pWal, WAL_READ_LOCK(mxI));
  if rc <> SQLITE_OK then begin
    if (rc and $FF) = SQLITE_BUSY then Result := WAL_RETRY
    else Result := rc;
    Exit;
  end;

  pWal^.minFrame := AtomicLoad(@pInfo^.nBackfill) + 1;
  walShmBarrier(pWal);
  if (AtomicLoad(@pInfo^.aReadMark[mxI]) <> mxReadMark)
  or (CompareByte(walIndexHdr(pWal)^, pWal^.hdr, SizeOf(TWalIndexHdr)) <> 0) then begin
    walUnlockShared(pWal, WAL_READ_LOCK(mxI));
    Result := WAL_RETRY; Exit;
  end;

  pWal^.readLock := i16(mxI);
  Result := SQLITE_OK;
end;

{ ============================================================
  walBeginReadTransaction (wal.c ~3368)
  ============================================================ }

function walBeginReadTransaction(pWal: PWal; pChanged: PcInt): cint;
var
  rc  : cint;
  cnt : cint;
begin
  cnt := 0;
  repeat
    rc := walTryBeginRead(pWal, pChanged, 0, @cnt);
  until rc <> WAL_RETRY;
  Result := rc;
end;

{ ============================================================
  walFindFrame (wal.c ~3519)
  ============================================================ }

function walFindFrame(pWal: PWal; pgno: Pgno; piRead: Pu32): cint;
var
  iRead     : u32;
  iLast     : u32;
  iHash     : cint;
  iMinHash  : cint;
  sLoc      : TWalHashLoc;
  iKey      : cint;
  nCollide  : cint;
  rc        : cint;
  iH        : u32;
  iFrame    : u32;
begin
  iRead := 0;
  iLast := pWal^.hdr.mxFrame;

  if (iLast = 0) or ((pWal^.readLock = 0) and (pWal^.bShmUnreliable = 0)) then begin
    piRead^ := 0; Result := SQLITE_OK; Exit;
  end;

  iMinHash := walFramePage(pWal^.minFrame);
  iHash := walFramePage(iLast);
  while iHash >= iMinHash do begin
    rc := walHashGet(pWal, iHash, @sLoc);
    if rc <> SQLITE_OK then begin
      Result := rc; Exit;
    end;
    nCollide := HASHTABLE_NSLOT;
    iKey := walHash(pgno);
    iH := AtomicLoad(@sLoc.aHash[iKey]);
    while iH <> 0 do begin
      iFrame := iH + sLoc.iZero;
      if (iFrame <= iLast)
      and (iFrame >= pWal^.minFrame)
      and (sLoc.aPgno[(iH - 1) and (HASHTABLE_NPAGE - 1)] = pgno) then begin
        if iFrame > iRead then iRead := iFrame;
      end;
      Dec(nCollide);
      if nCollide = 0 then begin
        piRead^ := 0; Result := SQLITE_CORRUPT_BKPT; Exit;
      end;
      iKey := walNextHash(iKey);
      iH := AtomicLoad(@sLoc.aHash[iKey]);
    end;
    if iRead <> 0 then break;
    Dec(iHash);
  end;

  piRead^ := iRead;
  Result := SQLITE_OK;
end;

{ ============================================================
  walIterator functions (wal.c ~1758+)
  ============================================================ }

function walIteratorNext(p: PWalIterator; piPage: Pu32; piFrame: Pu32): cint;
var
  iMin  : u32;
  iRet  : u32;
  i     : cint;
  pSeg  : PWalSegment;
  iPg   : u32;
begin
  iMin := p^.iPrior;
  iRet := $FFFFFFFF;

  for i := p^.nSegment - 1 downto 0 do begin
    pSeg := @p^.aSegment[i];
    while pSeg^.iNext < pSeg^.nEntry do begin
      iPg := Pu32(pSeg^.aPgno)[pSeg^.aIndex[pSeg^.iNext]];
      if iPg > iMin then begin
        if iPg < iRet then begin
          iRet := iPg;
          piFrame^ := u32(pSeg^.iZero) + pSeg^.aIndex[pSeg^.iNext];
        end;
        break;
      end;
      Inc(pSeg^.iNext);
    end;
  end;

  p^.iPrior := iRet;
  piPage^ := iRet;
  if iRet = $FFFFFFFF then Result := 1 else Result := 0;
end;

procedure walIteratorFree(p: PWalIterator);
begin
  sqlite3_free(p);
end;

procedure walMerge(const aContent: Pu32; aLeft: PHtSlot; nLeft: cint;
                   paRight: PPHtSlot; pnRight: PcInt; aTmp: PHtSlot);
var
  iLeft  : cint;
  iRight : cint;
  iOut   : cint;
  nRight : cint;
  aRight : PHtSlot;
  logpage : ht_slot;
  dbpage  : Pgno;
begin
  iLeft  := 0; iRight := 0; iOut := 0;
  nRight := pnRight^;
  aRight := paRight^;

  while (iRight < nRight) or (iLeft < nLeft) do begin
    if (iLeft < nLeft)
    and ((iRight >= nRight)
         or ((aContent + aLeft[iLeft])^ < (aContent + aRight[iRight])^))
    then begin
      logpage := aLeft[iLeft]; Inc(iLeft);
    end else begin
      logpage := aRight[iRight]; Inc(iRight);
    end;
    dbpage := (aContent + logpage)^;
    aTmp[iOut] := logpage; Inc(iOut);
    if (iLeft < nLeft) and ((aContent + aLeft[iLeft])^ = dbpage) then Inc(iLeft);
  end;

  paRight^ := aLeft;
  pnRight^ := iOut;
  Move(aTmp^, aLeft^, SizeOf(ht_slot) * iOut);
end;

procedure walMergesort(const aContent: Pu32; aBuffer: PHtSlot;
                       aList: PHtSlot; pnList: PcInt);
type
  TSublist = record
    nList : cint;
    aList : PHtSlot;
  end;
const
  NSUB = 13;
var
  nList  : cint;
  nMerge : cint;
  aMerge : PHtSlot;
  iList  : cint;
  iSub   : u32;
  aSub   : array[0..NSUB-1] of TSublist;
begin
  nList  := pnList^;
  nMerge := 0;
  aMerge := nil;
  iSub := 0;
  FillChar(aSub, SizeOf(aSub), 0);

  for iList := 0 to nList - 1 do begin
    nMerge := 1;
    aMerge := aList + iList;
    iSub := 0;
    while (iList and (1 shl iSub)) <> 0 do begin
      walMerge(aContent, aSub[iSub].aList, aSub[iSub].nList,
               @aMerge, @nMerge, aBuffer);
      Inc(iSub);
    end;
    aSub[iSub].aList := aMerge;
    aSub[iSub].nList := nMerge;
  end;

  Inc(iSub);
  while iSub < NSUB do begin
    if (nList and (1 shl iSub)) <> 0 then
      walMerge(aContent, aSub[iSub].aList, aSub[iSub].nList,
               @aMerge, @nMerge, aBuffer);
    Inc(iSub);
  end;

  pnList^ := nMerge;
end;

function walIteratorInit(pWal: PWal; nBackfill: u32; pp: PPWalIterator): cint;
var
  p        : PWalIterator;
  nSegment : cint;
  iLast    : u32;
  nByte    : i64;
  i        : cint;
  aTmp     : PHtSlot;
  rc       : cint;
  sLoc     : TWalHashLoc;
  nEntry   : cint;
  aIndex   : PHtSlot;
  j        : cint;
begin
  rc := SQLITE_OK;
  iLast    := pWal^.hdr.mxFrame;
  nSegment := walFramePage(iLast) + 1;
  nByte    := i64(SizeOf(TWalIterator) - SizeOf(TWalSegment))
            + i64(nSegment) * SizeOf(TWalSegment)
            + i64(iLast) * SizeOf(ht_slot);

  if iLast > HASHTABLE_NPAGE then
    p := PWalIterator(sqlite3_malloc64(nByte + i64(SizeOf(ht_slot)) * HASHTABLE_NPAGE))
  else
    p := PWalIterator(sqlite3_malloc64(nByte + i64(SizeOf(ht_slot)) * cint(iLast)));
  if p = nil then begin
    Result := SQLITE_NOMEM_BKPT; Exit;
  end;
  FillChar(p^, nByte, 0);
  p^.nSegment := nSegment;

  { aTmp points just after the WalIterator struct including all segment descriptors }
  aTmp := PHtSlot(PByte(p) + nByte);

  i := walFramePage(nBackfill + 1);
  while (rc = SQLITE_OK) and (i < nSegment) do begin
    rc := walHashGet(pWal, i, @sLoc);
    if rc = SQLITE_OK then begin
      if (i + 1) = nSegment then
        nEntry := cint(iLast - sLoc.iZero)
      else
        nEntry := cint(PByte(sLoc.aHash) - PByte(sLoc.aPgno)) div SizeOf(u32);

      aIndex := PHtSlot(PByte(p)
                + (SizeOf(TWalIterator) - SizeOf(TWalSegment))
                + i64(nSegment) * SizeOf(TWalSegment))
                + sLoc.iZero;
      Inc(sLoc.iZero);

      for j := 0 to nEntry - 1 do
        (aIndex + j)^ := ht_slot(j);

      walMergesort(sLoc.aPgno, aTmp, aIndex, @nEntry);
      p^.aSegment[i].iZero  := cint(sLoc.iZero);
      p^.aSegment[i].nEntry := nEntry;
      p^.aSegment[i].aIndex := aIndex;
      p^.aSegment[i].aPgno  := sLoc.aPgno;
    end;
    Inc(i);
  end;

  if rc <> SQLITE_OK then begin
    walIteratorFree(p);
    p := nil;
  end;
  pp^ := p;
  Result := rc;
end;

{ ============================================================
  walPagesize (wal.c ~2125)
  ============================================================ }

function walPagesize(pWal: PWal): cint; inline;
begin
  Result := cint(pWal^.hdr.szPage and $FE00) + cint((pWal^.hdr.szPage and 1) shl 16);
end;

{ ============================================================
  walBusyLock (wal.c ~2101)
  ============================================================ }

function walBusyLock(pWal: PWal; xBusy: TxBusyCallback; pBusyArg: Pointer;
                     lockIdx: cint; n: cint): cint;
begin
  repeat
    Result := walLockExclusive(pWal, lockIdx, n);
  until not ((xBusy <> nil) and (Result = SQLITE_BUSY) and (xBusy(pBusyArg) <> 0));
end;

{ ============================================================
  walRestartLog (wal.c ~3869)
  ============================================================ }

function walRestartLog(pWal: PWal): cint;
var
  rc    : cint;
  cnt   : cint;
  pInfo : PWalCkptInfo;
  salt1 : u32;
  notUsed: cint;
begin
  rc := SQLITE_OK;
  if pWal^.readLock = 0 then begin
    pInfo := walCkptInfo(pWal);
    if pInfo^.nBackfill > 0 then begin
      sqlite3_randomness(4, @salt1);
      rc := walLockExclusive(pWal, WAL_READ_LOCK(1), WAL_NREADER - 1);
      if rc = SQLITE_OK then begin
        walRestartHdr(pWal, salt1);
        walUnlockExclusive(pWal, WAL_READ_LOCK(1), WAL_NREADER - 1);
      end else if rc <> SQLITE_BUSY then begin
        Result := rc; Exit;
      end;
    end;
    walUnlockShared(pWal, WAL_READ_LOCK(0));
    pWal^.readLock := -1;
    cnt := 0;
    repeat
      rc := walTryBeginRead(pWal, @notUsed, 1, @cnt);
    until rc <> WAL_RETRY;
  end;
  Result := rc;
end;

{ ============================================================
  walWriteToLog / walWriteOneFrame (wal.c ~3932, ~3957)
  ============================================================ }

function walWriteToLog(p: PWalWriter; pContent: Pointer; iAmt: cint;
                       iOffset: i64): cint;
var
  rc         : cint;
  iFirstAmt  : cint;
begin
  if (iOffset < p^.iSyncPoint) and (iOffset + iAmt >= p^.iSyncPoint) then begin
    iFirstAmt := cint(p^.iSyncPoint - iOffset);
    rc := sqlite3OsWrite(p^.pFd, pContent, iFirstAmt, iOffset);
    if rc <> SQLITE_OK then begin Result := rc; Exit; end;
    iOffset  := iOffset + iFirstAmt;
    iAmt     := iAmt - iFirstAmt;
    pContent := Pointer(PByte(pContent) + iFirstAmt);
    rc := sqlite3OsSync(p^.pFd, WAL_SYNC_FLAGS(p^.syncFlags));
    if (iAmt = 0) or (rc <> SQLITE_OK) then begin Result := rc; Exit; end;
  end;
  Result := sqlite3OsWrite(p^.pFd, pContent, iAmt, iOffset);
end;

function walWriteOneFrame(p: PWalWriter; pPage: PPgHdr; nTruncate: cint;
                          iOffset: i64): cint;
var
  rc     : cint;
  aFrame : array[0..WAL_FRAME_HDRSIZE-1] of u8;
begin
  walEncodeFrame(p^.pWal, pPage^.pgno, u32(nTruncate),
                 Pu8(pPage^.pData), @aFrame[0]);
  rc := walWriteToLog(p, @aFrame[0], SizeOf(aFrame), iOffset);
  if rc <> SQLITE_OK then begin Result := rc; Exit; end;
  Result := walWriteToLog(p, pPage^.pData, p^.szPage,
                          iOffset + SizeOf(aFrame));
end;

{ ============================================================
  walRewriteChecksums (wal.c ~3983)
  ============================================================ }

function walRewriteChecksums(pWal: PWal; iLast: u32): cint;
var
  szPage   : cint;
  rc       : cint;
  aBuf     : Pu8;
  aFrame   : array[0..WAL_FRAME_HDRSIZE-1] of u8;
  iRead    : u32;
  iCksumOff : i64;
  iPgno, nDbSize : u32;
  iOff     : i64;
begin
  szPage := cint(pWal^.szPage);
  aBuf   := Pu8(sqlite3_malloc(szPage + WAL_FRAME_HDRSIZE));
  if aBuf = nil then begin Result := SQLITE_NOMEM_BKPT; Exit; end;
  rc := SQLITE_OK;

  if pWal^.iReCksum = 1 then
    iCksumOff := 24
  else
    iCksumOff := walFrameOffset(pWal^.iReCksum - 1, szPage) + 16;

  rc := sqlite3OsRead(pWal^.pWalFd, aBuf, SizeOf(u32) * 2, iCksumOff);
  if rc = SQLITE_OK then begin
    pWal^.hdr.aFrameCksum[0] := sqlite3Get4byte(aBuf);
    pWal^.hdr.aFrameCksum[1] := sqlite3Get4byte(aBuf + SizeOf(u32));

    iRead := pWal^.iReCksum;
    pWal^.iReCksum := 0;
    while (rc = SQLITE_OK) and (iRead <= iLast) do begin
      iOff := walFrameOffset(iRead, szPage);
      rc := sqlite3OsRead(pWal^.pWalFd, aBuf, szPage + WAL_FRAME_HDRSIZE, iOff);
      if rc = SQLITE_OK then begin
        iPgno   := sqlite3Get4byte(aBuf);
        nDbSize := sqlite3Get4byte(aBuf + 4);
        walEncodeFrame(pWal, iPgno, nDbSize, aBuf + WAL_FRAME_HDRSIZE, @aFrame[0]);
        rc := sqlite3OsWrite(pWal^.pWalFd, @aFrame[0], SizeOf(aFrame), iOff);
      end;
      Inc(iRead);
    end;
  end;

  sqlite3_free(aBuf);
  Result := rc;
end;

{ ============================================================
  walFrames (internal) (wal.c ~4032)
  ============================================================ }

function walFrames(pWal: PWal; szPage: cint; pList: PPgHdr;
                   nTruncate: Pgno; isCommit: cint; sync_flags: cint): cint;
var
  rc         : cint;
  iFrame     : u32;
  p          : PPgHdr;
  pLast      : PPgHdr;
  nExtra     : cint;
  szFrame    : cint;
  iOffset    : i64;
  w          : TWalWriter;
  iFirst     : u32;
  pLive      : PWalIndexHdr;
  aWalHdr    : array[0..WAL_HDRSIZE-1] of u8;
  aCksum     : array[0..1] of u32;
  bSync      : cint;
  sectorSize : cint;
  nDbSize    : cint;
  iWrite     : u32;
  iOff       : i64;
  sz         : i64;
begin
  pLast  := nil;
  nExtra := 0;
  rc     := SQLITE_OK;
  iFirst := 0;

  pLive := PWalIndexHdr(walIndexHdr(pWal));
  if CompareByte(pWal^.hdr, pLive^, SizeOf(TWalIndexHdr)) <> 0 then
    iFirst := pLive^.mxFrame + 1;

  rc := walRestartLog(pWal);
  if rc <> SQLITE_OK then begin Result := rc; Exit; end;

  iFrame := pWal^.hdr.mxFrame;
  if iFrame = 0 then begin
    sqlite3Put4byte(@aWalHdr[0], WAL_MAGIC or SQLITE_BIGENDIAN);
    sqlite3Put4byte(@aWalHdr[4], WAL_MAX_VERSION);
    sqlite3Put4byte(@aWalHdr[8], u32(szPage));
    sqlite3Put4byte(@aWalHdr[12], pWal^.nCkpt);
    if pWal^.nCkpt = 0 then
      sqlite3_randomness(8, @pWal^.hdr.aSalt[0]);
    Move(pWal^.hdr.aSalt[0], aWalHdr[16], 8);
    walChecksumBytes(1, @aWalHdr[0], WAL_HDRSIZE - 8, nil, @aCksum[0]);
    sqlite3Put4byte(@aWalHdr[24], aCksum[0]);
    sqlite3Put4byte(@aWalHdr[28], aCksum[1]);

    pWal^.szPage            := u32(szPage);
    pWal^.hdr.bigEndCksum   := SQLITE_BIGENDIAN;
    pWal^.hdr.aFrameCksum[0] := aCksum[0];
    pWal^.hdr.aFrameCksum[1] := aCksum[1];
    pWal^.truncateOnCommit  := 1;

    rc := sqlite3OsWrite(pWal^.pWalFd, @aWalHdr[0], SizeOf(aWalHdr), 0);
    if rc <> SQLITE_OK then begin Result := rc; Exit; end;

    if pWal^.syncHeader <> 0 then begin
      rc := sqlite3OsSync(pWal^.pWalFd, CKPT_SYNC_FLAGS(sync_flags));
      if rc <> SQLITE_OK then begin Result := rc; Exit; end;
    end;
  end;

  if cint(pWal^.szPage) <> szPage then begin
    Result := SQLITE_CORRUPT_BKPT; Exit;
  end;

  w.pWal       := pWal;
  w.pFd        := pWal^.pWalFd;
  w.iSyncPoint := 0;
  w.syncFlags  := sync_flags;
  w.szPage     := szPage;
  iOffset := walFrameOffset(iFrame + 1, szPage);
  szFrame := szPage + WAL_FRAME_HDRSIZE;

  p := pList;
  while p <> nil do begin
    if (iFirst <> 0) and ((p^.pDirty <> nil) or (isCommit = 0)) then begin
      iWrite := 0;
      walFindFrame(pWal, p^.pgno, @iWrite);
      if iWrite >= iFirst then begin
        iOff := walFrameOffset(iWrite, szPage) + WAL_FRAME_HDRSIZE;
        if (pWal^.iReCksum = 0) or (iWrite < pWal^.iReCksum) then
          pWal^.iReCksum := iWrite;
        rc := sqlite3OsWrite(pWal^.pWalFd, p^.pData, szPage, iOff);
        if rc <> SQLITE_OK then begin Result := rc; Exit; end;
        p^.flags := p^.flags and not PGHDR_WAL_APPEND;
        p := p^.pDirty; continue;
      end;
    end;

    Inc(iFrame);
    if isCommit <> 0 then begin
      if p^.pDirty = nil then nDbSize := cint(nTruncate) else nDbSize := 0;
    end else
      nDbSize := 0;
    rc := walWriteOneFrame(@w, p, nDbSize, iOffset);
    if rc <> SQLITE_OK then begin Result := rc; Exit; end;
    pLast   := p;
    iOffset := iOffset + szFrame;
    p^.flags := p^.flags or PGHDR_WAL_APPEND;
    p := p^.pDirty;
  end;

  if (isCommit <> 0) and (pWal^.iReCksum <> 0) then begin
    rc := walRewriteChecksums(pWal, iFrame);
    if rc <> SQLITE_OK then begin Result := rc; Exit; end;
  end;

  if (isCommit <> 0) and (WAL_SYNC_FLAGS(sync_flags) <> 0) then begin
    bSync := 1;
    if pWal^.padToSectorBoundary <> 0 then begin
      sectorSize := sqlite3SectorSize(pWal^.pWalFd);
      w.iSyncPoint := ((iOffset + sectorSize - 1) div sectorSize) * sectorSize;
      bSync := ord(w.iSyncPoint = iOffset);
      while iOffset < w.iSyncPoint do begin
        rc := walWriteOneFrame(@w, pLast, cint(nTruncate), iOffset);
        if rc <> SQLITE_OK then begin Result := rc; Exit; end;
        iOffset := iOffset + szFrame;
        Inc(nExtra);
      end;
    end;
    if bSync <> 0 then begin
      rc := sqlite3OsSync(w.pFd, WAL_SYNC_FLAGS(sync_flags));
      if rc <> SQLITE_OK then begin Result := rc; Exit; end;
    end;
  end;

  if (isCommit <> 0) and (pWal^.truncateOnCommit <> 0) and (pWal^.mxWalSize >= 0) then begin
    sz := pWal^.mxWalSize;
    if walFrameOffset(iFrame + nExtra + 1, szPage) > pWal^.mxWalSize then
      sz := walFrameOffset(iFrame + nExtra + 1, szPage);
    walLimitSize(pWal, sz);
    pWal^.truncateOnCommit := 0;
  end;

  iFrame := pWal^.hdr.mxFrame;
  p := pList;
  while (p <> nil) and (rc = SQLITE_OK) do begin
    if (p^.flags and PGHDR_WAL_APPEND) = 0 then begin
      p := p^.pDirty; continue;
    end;
    Inc(iFrame);
    rc := walIndexAppend(pWal, iFrame, p^.pgno);
    p := p^.pDirty;
  end;
  while (rc = SQLITE_OK) and (nExtra > 0) do begin
    Inc(iFrame); Dec(nExtra);
    rc := walIndexAppend(pWal, iFrame, pLast^.pgno);
  end;

  if rc = SQLITE_OK then begin
    pWal^.hdr.szPage := u16((szPage and $FF00) or (szPage shr 16));
    pWal^.hdr.mxFrame := iFrame;
    if isCommit <> 0 then begin
      Inc(pWal^.hdr.iChange);
      pWal^.hdr.nPage := nTruncate;
    end;
    if isCommit <> 0 then begin
      walIndexWriteHdr(pWal);
      pWal^.iCallback := iFrame;
    end;
  end;

  Result := rc;
end;

{ ============================================================
  walCheckpoint (internal) (wal.c ~2193)
  ============================================================ }

function walCheckpoint(pWal: PWal; db: Pointer; eMode: cint;
                       xBusy: TxBusyCallback; pBusyArg: Pointer;
                       sync_flags: cint; zBuf: Pu8): cint;
label
  walcheckpoint_out;
var
  rc          : cint;
  szPage      : cint;
  pIter       : PWalIterator;
  iDbpage     : u32;
  iFrame      : u32;
  mxSafeFrame : u32;
  mxPage      : u32;
  i           : cint;
  pInfo       : PWalCkptInfo;
  nBackfill   : u32;
  pLive       : PWalIndexHdr;
  bChg        : cint;
  nReq        : i64;
  nSize       : i64;
  szDb        : i64;
  iOffset     : i64;
  y           : u32;
  salt1       : u32;
begin
  rc := SQLITE_OK;
  pIter := nil;
  iFrame := 0;
  iDbpage := 0;
  szPage := walPagesize(pWal);
  pInfo := walCkptInfo(pWal);

  if pInfo^.nBackfill < pWal^.hdr.mxFrame then begin
    mxSafeFrame := pWal^.hdr.mxFrame;
    mxPage      := pWal^.hdr.nPage;

    for i := 1 to WAL_NREADER - 1 do begin
      y := AtomicLoad(@pInfo^.aReadMark[i]);
      if mxSafeFrame > y then begin
        rc := walBusyLock(pWal, xBusy, pBusyArg, WAL_READ_LOCK(i), 1);
        if rc = SQLITE_OK then begin
          if i = 1 then
            AtomicStore(@pInfo^.aReadMark[i], mxSafeFrame)
          else
            AtomicStore(@pInfo^.aReadMark[i], READMARK_NOT_USED);
          walUnlockExclusive(pWal, WAL_READ_LOCK(i), 1);
        end else if rc = SQLITE_BUSY then begin
          mxSafeFrame := y;
          xBusy := nil;
        end else
          goto walcheckpoint_out;
      end;
    end;

    if mxSafeFrame > pInfo^.nBackfill then begin
      rc := walIteratorInit(pWal, pInfo^.nBackfill, @pIter);
    end;

    if (pIter <> nil)
    and (walBusyLock(pWal, xBusy, pBusyArg, WAL_READ_LOCK(0), 1) = SQLITE_OK) then begin
      nBackfill := pInfo^.nBackfill;
      pLive := PWalIndexHdr(walIndexHdr(pWal));
      bChg := ord(CompareByte(pLive^.aSalt[0], pWal^.hdr.aSalt[0],
                               SizeOf(pWal^.hdr.aSalt)) <> 0);
      if bChg = 0 then begin
        AtomicStore(@pInfo^.nBackfillAttempted, mxSafeFrame);

        rc := sqlite3OsSync(pWal^.pWalFd, CKPT_SYNC_FLAGS(sync_flags));

        if rc = SQLITE_OK then begin
          nReq := i64(mxPage) * szPage;
          sqlite3OsFileControl(pWal^.pDbFd, SQLITE_FCNTL_CKPT_START, nil);
          rc := sqlite3OsFileSize(pWal^.pDbFd, @nSize);
          if (rc = SQLITE_OK) and (nSize < nReq) then begin
            if (nSize + 65536 + i64(pWal^.hdr.mxFrame) * szPage) < nReq then
              rc := SQLITE_CORRUPT_BKPT
            else
              sqlite3OsFileControlHint(pWal^.pDbFd, SQLITE_FCNTL_SIZE_HINT, @nReq);
          end;
        end;

        while (rc = SQLITE_OK) and (walIteratorNext(pIter, @iDbpage, @iFrame) = 0) do begin
          if iFrame <= nBackfill then continue;
          if iFrame > mxSafeFrame then continue;
          if iDbpage > mxPage then continue;
          iOffset := walFrameOffset(iFrame, szPage) + WAL_FRAME_HDRSIZE;
          rc := sqlite3OsRead(pWal^.pWalFd, zBuf, szPage, iOffset);
          if rc <> SQLITE_OK then break;
          iOffset := i64(iDbpage - 1) * szPage;
          rc := sqlite3OsWrite(pWal^.pDbFd, zBuf, szPage, iOffset);
          if rc <> SQLITE_OK then break;
        end;
        sqlite3OsFileControl(pWal^.pDbFd, SQLITE_FCNTL_CKPT_DONE, nil);

        if rc = SQLITE_OK then begin
          if mxSafeFrame = walIndexHdr(pWal)^.mxFrame then begin
            szDb := i64(pWal^.hdr.nPage) * szPage;
            rc := sqlite3OsTruncate(pWal^.pDbFd, szDb);
            if rc = SQLITE_OK then
              rc := sqlite3OsSync(pWal^.pDbFd, CKPT_SYNC_FLAGS(sync_flags));
          end;
          if rc = SQLITE_OK then
            AtomicStore(@pInfo^.nBackfill, mxSafeFrame);
        end;
      end;

      walUnlockExclusive(pWal, WAL_READ_LOCK(0), 1);
    end;

    if rc = SQLITE_BUSY then rc := SQLITE_OK;
  end;

  if (rc = SQLITE_OK) and (eMode <> SQLITE_CHECKPOINT_PASSIVE) then begin
    if pInfo^.nBackfill < pWal^.hdr.mxFrame then
      rc := SQLITE_BUSY
    else if eMode >= SQLITE_CHECKPOINT_RESTART then begin
      sqlite3_randomness(4, @salt1);
      rc := walBusyLock(pWal, xBusy, pBusyArg, WAL_READ_LOCK(1), WAL_NREADER - 1);
      if rc = SQLITE_OK then begin
        if eMode = SQLITE_CHECKPOINT_TRUNCATE then begin
          walRestartHdr(pWal, salt1);
          rc := sqlite3OsTruncate(pWal^.pWalFd, 0);
        end;
        walUnlockExclusive(pWal, WAL_READ_LOCK(1), WAL_NREADER - 1);
      end;
    end;
  end;

  walcheckpoint_out:
  walIteratorFree(pIter);
  Result := rc;
end;

{ ============================================================
  Public functions (wal.h implementations)
  ============================================================ }

{ wal.c ~1641: sqlite3WalOpen }
function sqlite3WalOpen(pVfs: Psqlite3_vfs; pDbFd: Psqlite3_file;
                        zWalName: PChar; bNoShm: cint; mxWalSize: i64;
                        ppWal: PPWal): cint;
var
  rc    : cint;
  pRet  : PWal;
  flags : cint;
  iDC   : cint;
begin
  ppWal^ := nil;
  pRet := PWal(sqlite3MallocZero(SizeOf(TWal) + pVfs^.szOsFile));
  if pRet = nil then begin
    Result := SQLITE_NOMEM_BKPT; Exit;
  end;

  pRet^.pVfs        := pVfs;
  pRet^.pWalFd      := Psqlite3_file(PByte(pRet) + SizeOf(TWal));
  pRet^.pDbFd       := pDbFd;
  pRet^.readLock    := -1;
  pRet^.mxWalSize   := mxWalSize;
  pRet^.zWalName    := zWalName;
  pRet^.syncHeader  := 1;
  pRet^.padToSectorBoundary := 1;
  if bNoShm <> 0 then
    pRet^.exclusiveMode := WAL_HEAPMEMORY_MODE
  else
    pRet^.exclusiveMode := WAL_NORMAL_MODE;

  flags := SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE or SQLITE_OPEN_WAL;
  rc := sqlite3OsOpen(pVfs, zWalName, pRet^.pWalFd, flags, @flags);
  if (rc = SQLITE_OK) and ((flags and SQLITE_OPEN_READONLY) <> 0) then
    pRet^.readOnly := WAL_RDONLY;

  if rc <> SQLITE_OK then begin
    walIndexClose(pRet, 0);
    sqlite3OsClose(pRet^.pWalFd);
    sqlite3_free(pRet);
  end else begin
    iDC := sqlite3OsDeviceCharacteristics(pDbFd);
    if (iDC and SQLITE_IOCAP_SEQUENTIAL) <> 0 then
      pRet^.syncHeader := 0;
    if (iDC and SQLITE_IOCAP_POWERSAFE_OVERWRITE) <> 0 then
      pRet^.padToSectorBoundary := 0;
    ppWal^ := pRet;
  end;
  Result := rc;
end;

{ wal.c ~1744: sqlite3WalLimit }
procedure sqlite3WalLimit(pWal: PWal; iLimit: i64);
begin
  if pWal <> nil then pWal^.mxWalSize := iLimit;
end;

{ wal.c ~2501: sqlite3WalClose }
function sqlite3WalClose(pWal: PWal; db: Pointer; sync_flags: cint;
                         nBuf: cint; zBuf: Pu8): cint;
var
  rc       : cint;
  isDelete : cint;
  bPersist : cint;
begin
  rc := SQLITE_OK;
  if pWal <> nil then begin
    isDelete := 0;

    if (zBuf <> nil)
    and (sqlite3OsLock(pWal^.pDbFd, SQLITE_LOCK_EXCLUSIVE) = SQLITE_OK) then begin
      if pWal^.exclusiveMode = WAL_NORMAL_MODE then
        pWal^.exclusiveMode := WAL_EXCLUSIVE_MODE;
      rc := sqlite3WalCheckpoint(pWal, db, SQLITE_CHECKPOINT_PASSIVE,
                                  nil, nil, sync_flags, nBuf, zBuf, nil, nil);
      if rc = SQLITE_OK then begin
        bPersist := -1;
        sqlite3OsFileControlHint(pWal^.pDbFd, SQLITE_FCNTL_PERSIST_WAL, @bPersist);
        if bPersist <> 1 then
          isDelete := 1
        else if pWal^.mxWalSize >= 0 then
          walLimitSize(pWal, 0);
      end;
    end;

    walIndexClose(pWal, isDelete);
    sqlite3OsClose(pWal^.pWalFd);
    if isDelete <> 0 then begin
      sqlite3BeginBenignMalloc;
      sqlite3OsDelete(pWal^.pVfs, pWal^.zWalName, 0);
      sqlite3EndBenignMalloc;
    end;
    sqlite3_free(pWal^.apWiData);
    sqlite3_free(pWal);
  end;
  Result := rc;
end;

{ wal.c ~3487: sqlite3WalBeginReadTransaction }
function sqlite3WalBeginReadTransaction(pWal: PWal; pChanged: PcInt): cint;
begin
  Result := walBeginReadTransaction(pWal, pChanged);
end;

{ wal.c ~3500: sqlite3WalEndReadTransaction }
procedure sqlite3WalEndReadTransaction(pWal: PWal);
begin
  if pWal^.readLock >= 0 then begin
    sqlite3WalEndWriteTransaction(pWal);
    walUnlockShared(pWal, WAL_READ_LOCK(pWal^.readLock));
    pWal^.readLock := -1;
  end;
end;

{ wal.c ~3634: sqlite3WalFindFrame }
function sqlite3WalFindFrame(pWal: PWal; pgno: Pgno; piRead: Pu32): cint;
begin
  Result := walFindFrame(pWal, pgno, piRead);
end;

{ wal.c ~3652: sqlite3WalReadFrame }
function sqlite3WalReadFrame(pWal: PWal; iRead: u32; nOut: cint;
                              pOut: Pu8): cint;
var
  sz      : cint;
  iOffset : i64;
begin
  sz := cint(pWal^.hdr.szPage);
  sz := (sz and $FE00) + ((sz and 1) shl 16);
  iOffset := walFrameOffset(iRead, sz) + WAL_FRAME_HDRSIZE;
  if nOut > sz then nOut := sz;
  Result := sqlite3OsRead(pWal^.pWalFd, pOut, nOut, iOffset);
end;

{ wal.c ~3672: sqlite3WalDbsize }
function sqlite3WalDbsize(pWal: PWal): Pgno;
begin
  if (pWal <> nil) and (pWal^.readLock >= 0) then
    Result := pWal^.hdr.nPage
  else
    Result := 0;
end;

{ wal.c ~3693: sqlite3WalBeginWriteTransaction }
function sqlite3WalBeginWriteTransaction(pWal: PWal): cint;
var
  rc : cint;
begin
  if pWal^.writeLock <> 0 then begin
    Result := SQLITE_OK; Exit;
  end;
  if pWal^.readOnly <> 0 then begin
    Result := SQLITE_READONLY; Exit;
  end;
  rc := walLockExclusive(pWal, WAL_WRITE_LOCK, 1);
  if rc <> SQLITE_OK then begin
    Result := rc; Exit;
  end;
  pWal^.writeLock := 1;
  if CompareByte(pWal^.hdr, walIndexHdr(pWal)^, SizeOf(TWalIndexHdr)) <> 0 then begin
    walUnlockExclusive(pWal, WAL_WRITE_LOCK, 1);
    pWal^.writeLock := 0;
    Result := SQLITE_BUSY_SNAPSHOT; Exit;
  end;
  Result := SQLITE_OK;
end;

{ wal.c ~3746: sqlite3WalEndWriteTransaction }
function sqlite3WalEndWriteTransaction(pWal: PWal): cint;
begin
  if pWal^.writeLock <> 0 then begin
    walUnlockExclusive(pWal, WAL_WRITE_LOCK, 1);
    pWal^.writeLock       := 0;
    pWal^.iReCksum        := 0;
    pWal^.truncateOnCommit := 0;
  end;
  Result := SQLITE_OK;
end;

{ wal.c ~3768: sqlite3WalUndo }
function sqlite3WalUndo(pWal: PWal; xUndo: TxUndoCallback; pUndoCtx: Pointer): cint;
var
  rc    : cint;
  iMax  : Pgno;
  iFrm  : Pgno;
begin
  rc := SQLITE_OK;
  if pWal^.writeLock <> 0 then begin
    iMax := pWal^.hdr.mxFrame;
    Move(walIndexHdr(pWal)^, pWal^.hdr, SizeOf(TWalIndexHdr));
    iFrm := pWal^.hdr.mxFrame + 1;
    while (rc = SQLITE_OK) and (iFrm <= iMax) do begin
      rc := xUndo(pUndoCtx, walFramePgno(pWal, iFrm));
      Inc(iFrm);
    end;
    if iMax <> pWal^.hdr.mxFrame then walCleanupHash(pWal);
    pWal^.iReCksum := 0;
  end;
  Result := rc;
end;

{ wal.c ~3812: sqlite3WalSavepoint }
procedure sqlite3WalSavepoint(pWal: PWal; aWalData: Pu32);
begin
  aWalData[0] := pWal^.hdr.mxFrame;
  aWalData[1] := pWal^.hdr.aFrameCksum[0];
  aWalData[2] := pWal^.hdr.aFrameCksum[1];
  aWalData[3] := pWal^.nCkpt;
end;

{ wal.c ~3826: sqlite3WalSavepointUndo }
function sqlite3WalSavepointUndo(pWal: PWal; aWalData: Pu32): cint;
begin
  Result := SQLITE_OK;
  if aWalData[3] <> pWal^.nCkpt then begin
    aWalData[0] := 0;
    aWalData[3] := pWal^.nCkpt;
  end;
  if aWalData[0] < pWal^.hdr.mxFrame then begin
    pWal^.hdr.mxFrame          := aWalData[0];
    pWal^.hdr.aFrameCksum[0]   := aWalData[1];
    pWal^.hdr.aFrameCksum[1]   := aWalData[2];
    walCleanupHash(pWal);
    if pWal^.iReCksum > pWal^.hdr.mxFrame then
      pWal^.iReCksum := 0;
  end;
end;

{ wal.c ~4269: sqlite3WalFrames }
function sqlite3WalFrames(pWal: PWal; szPage: cint; pList: PPgHdr;
                          nTruncate: Pgno; isCommit: cint;
                          sync_flags: cint): cint;
begin
  Result := walFrames(pWal, szPage, pList, nTruncate, isCommit, sync_flags);
end;

{ wal.c ~4295: sqlite3WalCheckpoint }
function sqlite3WalCheckpoint(pWal: PWal; db: Pointer; eMode: cint;
                               xBusy: TxBusyCallback; pBusyArg: Pointer;
                               sync_flags: cint; nBuf: cint; zBuf: Pu8;
                               pnLog: PcInt; pnCkpt: PcInt): cint;
var
  rc         : cint;
  isChanged  : cint;
  eMode2     : cint;
  xBusy2     : TxBusyCallback;
begin
  isChanged := 0;
  eMode2    := eMode;
  xBusy2    := xBusy;

  if pWal^.readOnly <> 0 then begin
    Result := SQLITE_READONLY; Exit;
  end;

  if eMode <> SQLITE_CHECKPOINT_NOOP then begin
    rc := walLockExclusive(pWal, WAL_CKPT_LOCK, 1);
    if rc = SQLITE_OK then begin
      pWal^.ckptLock := 1;
      if eMode <> SQLITE_CHECKPOINT_PASSIVE then begin
        rc := walBusyLock(pWal, xBusy2, pBusyArg, WAL_WRITE_LOCK, 1);
        if rc = SQLITE_OK then
          pWal^.writeLock := 1
        else if rc = SQLITE_BUSY then begin
          eMode2 := SQLITE_CHECKPOINT_PASSIVE;
          xBusy2 := nil;
          rc := SQLITE_OK;
        end;
      end;
    end;
  end else
    rc := SQLITE_OK;

  if rc = SQLITE_OK then begin
    rc := walIndexReadHdr(pWal, @isChanged);
    if (isChanged <> 0) and (pWal^.pDbFd^.pMethods^.iVersion >= 3) then
      sqlite3OsUnfetch(pWal^.pDbFd, 0, nil);

    if rc = SQLITE_OK then begin
      if (pWal^.hdr.mxFrame <> 0) and (walPagesize(pWal) <> nBuf) then
        rc := SQLITE_CORRUPT_BKPT
      else if eMode2 <> SQLITE_CHECKPOINT_NOOP then
        rc := walCheckpoint(pWal, db, eMode2, xBusy2, pBusyArg, sync_flags, zBuf);

      if (rc = SQLITE_OK) or (rc = SQLITE_BUSY) then begin
        if pnLog <> nil then pnLog^ := cint(pWal^.hdr.mxFrame);
        if pnCkpt <> nil then pnCkpt^ := cint(walCkptInfo(pWal)^.nBackfill);
      end;
    end;
  end;

  if isChanged <> 0 then
    FillChar(pWal^.hdr, SizeOf(TWalIndexHdr), 0);

  sqlite3WalEndWriteTransaction(pWal);
  if pWal^.ckptLock <> 0 then begin
    walUnlockExclusive(pWal, WAL_CKPT_LOCK, 1);
    pWal^.ckptLock := 0;
  end;

  if (rc = SQLITE_OK) and (eMode <> eMode2) then
    Result := SQLITE_BUSY
  else
    Result := rc;
end;

{ wal.c ~4433: sqlite3WalCallback }
function sqlite3WalCallback(pWal: PWal): cint;
var
  ret : u32;
begin
  ret := 0;
  if pWal <> nil then begin
    ret := pWal^.iCallback;
    pWal^.iCallback := 0;
  end;
  Result := cint(ret);
end;

{ wal.c ~4466: sqlite3WalExclusiveMode }
function sqlite3WalExclusiveMode(pWal: PWal; op: cint): cint;
begin
  if op = 0 then begin
    if pWal^.exclusiveMode <> WAL_NORMAL_MODE then begin
      pWal^.exclusiveMode := WAL_NORMAL_MODE;
      if walLockShared(pWal, WAL_READ_LOCK(pWal^.readLock)) <> SQLITE_OK then
        pWal^.exclusiveMode := WAL_EXCLUSIVE_MODE;
      Result := ord(pWal^.exclusiveMode = WAL_NORMAL_MODE);
    end else
      Result := 0;
  end else if op > 0 then begin
    walUnlockShared(pWal, WAL_READ_LOCK(pWal^.readLock));
    pWal^.exclusiveMode := WAL_EXCLUSIVE_MODE;
    Result := 1;
  end else begin
    Result := ord(pWal^.exclusiveMode = WAL_NORMAL_MODE);
  end;
end;

{ wal.c ~4510: sqlite3WalHeapMemory }
function sqlite3WalHeapMemory(pWal: PWal): cint;
begin
  if (pWal <> nil) and (pWal^.exclusiveMode = WAL_HEAPMEMORY_MODE) then
    Result := 1
  else
    Result := 0;
end;

{ wal.c ~4635: sqlite3WalFile }
function sqlite3WalFile(pWal: PWal): Psqlite3_file;
begin
  Result := pWal^.pWalFd;
end;

end.
