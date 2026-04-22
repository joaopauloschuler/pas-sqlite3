{$I passqlite3.inc}
unit passqlite3pager;
{
  Phase 3.A.3 + 3.A.4 + 3.B.1 -- MemJournal, MemDB, and Pager struct port
  for SQLite 3.53.0.

  Source files ported (upstream commit in ../sqlite3/):
    memjournal.c (~440 lines) -- in-memory rollback journal VFS
    memdb.c      (~936 lines) -- :memory: database backing VFS over RAM buffer
    pager.h      (~263 lines) -- public Pager API declarations
    pager.c      (Pager struct + constants, Phase 3.B.1)

  Porting conventions follow passqlite3pcache.pas and passqlite3os.pas:
    - Field order in records matches C exactly (memcmp-safe).
    - C static functions are implementation-only (not exported).
    - Public functions declared in interface section only.
    - All VFS/IO callback functions carry cdecl to match procedural types.
    - sqlite3_malloc / sqlite3_free from passqlite3os for allocation.
    - SQLITE_THREADSAFE=1: mutexes used for shared MemStore objects.
}

interface

uses
  passqlite3types,
  passqlite3internal,
  passqlite3os,
  passqlite3util,
  passqlite3pcache,
  BaseUnix,
  UnixType,
  SysUtils;

{ ============================================================
  3.A.3: memjournal.c types
  ============================================================ }

type
  PFileChunk  = ^FileChunk;
  PFilePoint  = ^FilePoint;
  PMemJournal = ^MemJournal;

  { FileChunk -- one node in the linked list that makes up the journal.
    Field order matches C struct FileChunk. }
  FileChunk = record
    pNext  : PFileChunk;        { Next chunk in the journal }
    zChunk : array[0..7] of u8; { Content -- actually nChunkSize bytes }
  end;

  { FilePoint -- cursor into the rollback journal. }
  FilePoint = record
    iOffset : i64;        { Byte offset from start of file }
    pChunk  : PFileChunk; { Chunk that the cursor points into }
  end;

  { MemJournal -- in-memory rollback journal; subclass of sqlite3_file.
    pMethod MUST be the first field (same ABI as sqlite3_file.pMethods). }
  MemJournal = record
    pMethod    : Psqlite3_io_methods; { Parent class -- MUST be first }
    nChunkSize : i32;                 { In-memory chunk size }
    nSpill     : i32;                 { Bytes of data before flushing to disk }
    pFirst     : PFileChunk;          { Head of in-memory chunk list }
    endpoint   : FilePoint;           { Pointer to end of file }
    readpoint  : FilePoint;           { Pointer to end of last xRead }
    flags      : i32;                 { xOpen flags }
    pVfs       : Psqlite3_vfs;        { The "real" underlying VFS }
    zJournal   : PChar;               { Name of the journal file }
  end;

{ ============================================================
  3.A.3: memjournal.c exported functions
  ============================================================ }

function  sqlite3JournalOpen(pVfs: Psqlite3_vfs; zName: PChar;
            pJfd: Psqlite3_file; flags: i32; nSpill: i32): i32;
procedure sqlite3MemJournalOpen(pJfd: Psqlite3_file);
function  sqlite3JournalCreate(pJfd: Psqlite3_file): i32;
function  sqlite3JournalIsInMemory(p: Psqlite3_file): i32;
function  sqlite3JournalSize(pVfs: Psqlite3_vfs): i32;

{ ============================================================
  3.A.4: memdb.c types
  ============================================================ }

type
  PMemStore  = ^MemStore;
  PPMemStore = ^PMemStore;
  PMemFile   = ^MemFile;

  { MemStore -- the actual content storage for a :memory: database.
    Field order matches C struct MemStore. }
  MemStore = record
    sz       : i64;             { Current size of the file }
    szAlloc  : i64;             { Space allocated to aData }
    szMax    : i64;             { Maximum allowed size of the file }
    aData    : Pu8;             { Content of the file }
    pMutex   : Psqlite3_mutex;  { Mutex used by shared stores }
    nMmap    : i32;             { Number of memory-mapped pages outstanding }
    mFlags   : u32;             { SQLITE_DESERIALIZE_* flags }
    nRdLock  : i32;             { Number of readers }
    nWrLock  : i32;             { Number of writers (0 or 1) }
    nRef     : i32;             { Number of users of this MemStore }
    zFName   : PChar;           { Filename for shared stores }
  end;

  { MemFile -- an open handle on a memdb file; subclass of sqlite3_file.
    base MUST be the first field (same ABI as sqlite3_file). }
  MemFile = record
    base   : sqlite3_file;  { IO methods -- MUST be first }
    pStore : PMemStore;     { The underlying storage }
    eLock  : i32;           { Most recent lock level }
  end;

{ ============================================================
  3.A.4: memdb.c exported functions
  ============================================================ }

function  sqlite3MemdbInit: i32;
function  sqlite3IsMemdb(pVfs: Psqlite3_vfs): i32;

{ SQLITE_DESERIALIZE_* flags (sqlite3.h) }
const
  SQLITE_DESERIALIZE_FREEONCLOSE = 1;
  SQLITE_DESERIALIZE_RESIZEABLE  = 2;
  SQLITE_DESERIALIZE_READONLY    = 4;

{ ============================================================
  3.B.1: pager.h / pager.c -- Pager struct and related types
  ============================================================ }

{ pager.h constants }
const
  SQLITE_DEFAULT_JOURNAL_SIZE_LIMIT = -1;

  { PAGER_OMIT_JOURNAL / PAGER_MEMORY flags for sqlite3PagerOpen }
  PAGER_OMIT_JOURNAL = $0001;
  PAGER_MEMORY       = $0002;

  { Locking-mode values for sqlite3PagerLockingMode() }
  PAGER_LOCKINGMODE_QUERY     = -1;
  PAGER_LOCKINGMODE_NORMAL    = 0;
  PAGER_LOCKINGMODE_EXCLUSIVE = 1;

  { Journal modes (exposed via PRAGMA journal_mode -- values are stable API) }
  PAGER_JOURNALMODE_QUERY    = -1;
  PAGER_JOURNALMODE_DELETE   = 0;
  PAGER_JOURNALMODE_PERSIST  = 1;
  PAGER_JOURNALMODE_OFF      = 2;
  PAGER_JOURNALMODE_TRUNCATE = 3;
  PAGER_JOURNALMODE_MEMORY   = 4;
  PAGER_JOURNALMODE_WAL      = 5;

  { Flags for sqlite3PagerGet() }
  PAGER_GET_NOCONTENT = $01;
  PAGER_GET_READONLY  = $02;

  { Flags for sqlite3PagerSetFlags() }
  PAGER_SYNCHRONOUS_OFF    = $01;
  PAGER_SYNCHRONOUS_NORMAL = $02;
  PAGER_SYNCHRONOUS_FULL   = $03;
  PAGER_SYNCHRONOUS_EXTRA  = $04;
  PAGER_SYNCHRONOUS_MASK   = $07;
  PAGER_FULLFSYNC          = $08;
  PAGER_CKPT_FULLFSYNC     = $10;
  PAGER_CACHESPILL         = $20;
  PAGER_FLAGS_MASK         = $38;

  { pager.c internal constants }
  UNKNOWN_LOCK    = SQLITE_LOCK_EXCLUSIVE + 1;
  MAX_SECTOR_SIZE = $10000;

  { PagerSavepoint.bTruncateOnRelease: boolean }
  SPILLFLAG_OFF      = $01;
  SPILLFLAG_ROLLBACK = $02;
  SPILLFLAG_NOSYNC   = $04;

  { Pager.aStat[] indices }
  PAGER_STAT_HIT   = 0;
  PAGER_STAT_MISS  = 1;
  PAGER_STAT_WRITE = 2;
  PAGER_STAT_SPILL = 3;

  { WAL savepoint data words (wal.h WAL_SAVEPOINT_NDATA) }
  WAL_SAVEPOINT_NDATA = 4;

  { Journal magic bytes (pager.c aJournalMagic) }
  JOURNAL_MAGIC_0 = $D9;
  JOURNAL_MAGIC_1 = $D5;
  JOURNAL_MAGIC_2 = $05;
  JOURNAL_MAGIC_3 = $F9;
  JOURNAL_MAGIC_4 = $20;
  JOURNAL_MAGIC_5 = $A1;
  JOURNAL_MAGIC_6 = $63;
  JOURNAL_MAGIC_7 = $D7;

type
  { Forward declarations }
  PPager          = ^Pager;
  PPagerSavepoint = ^PagerSavepoint;
  PWal            = ^TWal;     { wal.c -- ported in Phase 3.B.3 }
  Psqlite3_backup = Pointer;   { backup.c -- ported in Phase 8.7 }
  TDbPage         = PgHdr;     { pager.h: typedef struct PgHdr DbPage }
  PDbPage         = ^TDbPage;

  { pager.c PagerSavepoint -- active savepoint state.
    Field order matches C exactly. }
  PagerSavepoint = record
    iOffset            : i64;     { Starting offset in main journal }
    iHdrOffset         : i64;     { Byte after last jrnl record before hdr }
    pInSavepoint       : PBitvec; { Set of pages in this savepoint }
    nOrig              : Pgno;    { Original number of pages in file }
    iSubRec            : Pgno;    { Index of first record in sub-journal }
    bTruncateOnRelease : i32;     { If stmt journal may be truncated }
    aWalData : array[0..WAL_SAVEPOINT_NDATA-1] of u32; { WAL savepoint ctx }
  end;

  { TWal -- opaque WAL handle; full definition in passqlite3wal.pas (Phase 3.B.3).
    Declared here as an opaque record so Pager can hold a pointer to it. }
  TWal = record end;

  { Pager -- the central pager struct. Field order MUST match C exactly.
    Source: pager.c struct Pager (lines 619-706 in SQLite 3.53.0).
    Large allocation: always heap-allocated, never stack. }
  Pager = record
    { ---- configuration (set once at open, or on mode change) }
    pVfs           : Psqlite3_vfs;   { OS functions to use for IO }
    exclusiveMode  : u8;             { Boolean: locking_mode==EXCLUSIVE }
    journalMode    : u8;             { PAGER_JOURNALMODE_* }
    useJournal     : u8;             { Use a rollback journal on this file }
    noSync         : u8;             { Do not sync the journal if true }
    fullSync       : u8;             { Extra syncs of journal for robustness }
    extraSync      : u8;             { sync directory after journal delete }
    syncFlags      : u8;             { SYNC_NORMAL or SYNC_FULL }
    walSyncFlags   : u8;             { WAL sync flags (see comment in C) }
    tempFile       : u8;             { zFilename is a temporary/immutable file }
    noLock         : u8;             { Do not lock (except WAL mode) }
    readOnly       : u8;             { True for a read-only database }
    memDb          : u8;             { True to inhibit all file I/O }
    memVfs         : u8;             { VFS-implemented memory database }
    { ---- state (changes during normal operation) }
    eState         : u8;             { OPEN / READER / WRITER_LOCKED / ... }
    eLock          : u8;             { Current lock held on database file }
    changeCountDone: u8;             { Set after incrementing change-counter }
    setSuper       : u8;             { Super-jrnl name written into jrnl }
    doNotSpill     : u8;             { Do not spill cache when non-zero }
    subjInMemory   : u8;             { True to use in-memory sub-journals }
    bUseFetch      : u8;             { True to use xFetch() }
    hasHeldSharedLock: u8;           { True if shared lock ever held }
    dbSize         : Pgno;           { Number of pages in the database }
    dbOrigSize     : Pgno;           { dbSize before current transaction }
    dbFileSize     : Pgno;           { Number of pages in the database file }
    dbHintSize     : Pgno;           { Value passed to FCNTL_SIZE_HINT }
    errCode        : i32;            { One of several kinds of errors }
    nRec           : i32;            { Pages journalled since last j-header }
    cksumInit      : u32;            { Quasi-random value in every checksum }
    nSubRec        : u32;            { Records written to sub-journal }
    pInJournal     : PBitvec;        { One bit per page in database file }
    fd             : Psqlite3_file;  { File descriptor for database }
    jfd            : Psqlite3_file;  { File descriptor for main journal }
    sjfd           : Psqlite3_file;  { File descriptor for sub-journal }
    journalOff     : i64;            { Current write offset in journal file }
    journalHdr     : i64;            { Byte offset to previous journal header }
    pBackup        : Psqlite3_backup;{ List of ongoing backup processes }
    aSavepoint     : PPagerSavepoint;{ Array of active savepoints }
    nSavepoint     : i32;            { Number of elements in aSavepoint[] }
    iDataVersion   : u32;            { Changes whenever database content changes }
    dbFileVers     : array[0..15] of AnsiChar; { Changes on file change }
    nMmapOut       : i32;            { Number of mmap pages outstanding }
    szMmap         : i64;            { Desired maximum mmap size }
    pMmapFreelist  : PPgHdr;         { List of free mmap page headers }
    { ---- configuration (not in the "state" block) }
    nExtra         : u16;            { Extra bytes per in-memory page }
    nReserve       : i16;            { Unused bytes at end of each page }
    vfsFlags       : u32;            { Flags for sqlite3_vfs.xOpen() }
    sectorSize     : u32;            { Assumed sector size during rollback }
    mxPgno         : Pgno;           { Maximum allowed size of the database }
    lckPgno        : Pgno;           { Page number for the locking page }
    pageSize       : i64;            { Number of bytes in a page }
    journalSizeLimit: i64;           { Size limit for persistent journal files }
    zFilename      : PChar;          { Name of the database file }
    zJournal       : PChar;          { Name of the journal file }
    xBusyHandler   : function(p: Pointer): i32; { Function to call when busy }
    pBusyHandlerArg: Pointer;        { Context argument for xBusyHandler }
    aStat          : array[0..3] of u32;  { Cache hits, misses, writes, spills }
    xReiniter      : procedure(p: PDbPage); { Called when reloading pages }
    xGet           : function(pPager: PPager; pgno: Pgno;
                       ppPage: PDbPage; flags: i32): i32; { Fetch a page }
    pTmpSpace      : PChar;          { Pager.pageSize bytes of tmp space }
    pPCache        : PPCache;        { Pointer to page cache object }
    pWal           : PWal;           { Write-ahead log (journal_mode=wal) }
    zWal           : PChar;          { File name for write-ahead log }
  end;

{ ============================================================
  3.B.1: pager.h public API declarations
  (implementations in later sub-phases 3.B.2 and 3.B.3)
  ============================================================ }

{ pager.h macros as inline functions }
function isWalMode(x: i32): i32; inline;
function isOpen(pFd: Psqlite3_file): i32; inline;

implementation

{ ============================================================
  3.B.1 Implementation: pager.h inline helpers
  ============================================================ }

function isWalMode(x: i32): i32; inline;
begin
  if x = PAGER_JOURNALMODE_WAL then Result := 1 else Result := 0;
end;

function isOpen(pFd: Psqlite3_file): i32; inline;
begin
  if Assigned(pFd^.pMethods) then Result := 1 else Result := 0;
end;

{ ============================================================
  3.A.3 Implementation: memjournal.c
  ============================================================ }

const
  MEMJOURNAL_DFLT_FILECHUNKSIZE = 1024;

function fileChunkSize(nChunkSize: i32): i32; inline;
begin
  Result := SizeOf(FileChunk) + (nChunkSize - 8);
end;

{ Forward declarations for MemJournal IO methods (all cdecl to match TxXxx types). }
function memjrnlClose(pJfd: Psqlite3_file): cint; cdecl; forward;
function memjrnlRead(pJfd: Psqlite3_file; zBuf: Pointer;
           iAmt: cint; iOfst: i64): cint; cdecl; forward;
function memjrnlWrite(pJfd: Psqlite3_file; zBuf: Pointer;
           iAmt: cint; iOfst: i64): cint; cdecl; forward;
function memjrnlTruncate(pJfd: Psqlite3_file; size: i64): cint; cdecl; forward;
function memjrnlSync(pJfd: Psqlite3_file; flags: cint): cint; cdecl; forward;
function memjrnlFileSize(pJfd: Psqlite3_file; pSize: Pi64): cint; cdecl; forward;

{ IO methods vtable for MemJournal. Initialized in implementation. }
var
  MemJournalMethods: sqlite3_io_methods;

{ memjournal.c ~80: memjrnlRead }
function memjrnlRead(pJfd: Psqlite3_file; zBuf: Pointer;
           iAmt: cint; iOfst: i64): cint; cdecl;
var
  p            : PMemJournal;
  zOut         : Pu8;
  nRead        : i32;
  iChunkOffset : i32;
  pChunk       : PFileChunk;
  iOff         : i64;
  iSpace       : i32;
  nCopy        : i32;
begin
  p     := PMemJournal(pJfd);
  zOut  := Pu8(zBuf);
  nRead := iAmt;

  if (iAmt + iOfst) > p^.endpoint.iOffset then
    Exit(SQLITE_IOERR_SHORT_READ);

  if (p^.readpoint.iOffset <> iOfst) or (iOfst = 0) then
  begin
    iOff   := 0;
    pChunk := p^.pFirst;
    while Assigned(pChunk) and ((iOff + p^.nChunkSize) <= iOfst) do
    begin
      iOff   += p^.nChunkSize;
      pChunk := pChunk^.pNext;
    end;
  end
  else
    pChunk := p^.readpoint.pChunk;

  iChunkOffset := i32(iOfst mod p^.nChunkSize);
  repeat
    iSpace := p^.nChunkSize - iChunkOffset;
    nCopy  := iSpace;
    if nCopy > nRead then nCopy := nRead;
    Move((Pu8(@pChunk^.zChunk[0]) + iChunkOffset)^, zOut^, nCopy);
    zOut  += nCopy;
    nRead -= iSpace;
    iChunkOffset := 0;
    pChunk := pChunk^.pNext;
  until not ((nRead >= 0) and Assigned(pChunk) and (nRead > 0));

  if Assigned(pChunk) then
    p^.readpoint.iOffset := iOfst + iAmt
  else
    p^.readpoint.iOffset := 0;
  p^.readpoint.pChunk := pChunk;
  Result := SQLITE_OK;
end;

{ memjournal.c ~143: memjrnlFreeChunks }
procedure memjrnlFreeChunks(pFirst: PFileChunk);
var
  pIter : PFileChunk;
  pNext : PFileChunk;
begin
  pIter := pFirst;
  while Assigned(pIter) do
  begin
    pNext := pIter^.pNext;
    sqlite3_free(pIter);
    pIter := pNext;
  end;
end;

{ memjournal.c ~156: memjrnlCreateFile -- flush to real disk file }
function memjrnlCreateFile(p: PMemJournal): i32;
var
  rc    : i32;
  pReal : Psqlite3_file;
  copy  : MemJournal;
  nChunk: i32;
  iOff  : i64;
  pIter : PFileChunk;
begin
  pReal := Psqlite3_file(p);
  copy  := p^;
  FillChar(p^, SizeOf(MemJournal), 0);
  rc := sqlite3OsOpen(copy.pVfs, copy.zJournal, pReal, copy.flags, nil);
  if rc = SQLITE_OK then
  begin
    nChunk := copy.nChunkSize;
    iOff   := 0;
    pIter  := copy.pFirst;
    while Assigned(pIter) do
    begin
      if iOff + nChunk > copy.endpoint.iOffset then
        nChunk := i32(copy.endpoint.iOffset - iOff);
      rc := sqlite3OsWrite(pReal, @pIter^.zChunk[0], nChunk, iOff);
      if rc <> SQLITE_OK then break;
      iOff  += nChunk;
      pIter := pIter^.pNext;
    end;
    if rc = SQLITE_OK then
      memjrnlFreeChunks(copy.pFirst);
  end;
  if rc <> SQLITE_OK then
  begin
    sqlite3OsClose(pReal);
    p^ := copy;
  end;
  Result := rc;
end;

{ memjournal.c ~216 forward ref -- declared cdecl }
function memjrnlTruncate(pJfd: Psqlite3_file; size: i64): cint; cdecl;
var
  p    : PMemJournal;
  pIter: PFileChunk;
  iOff : i64;
begin
  p := PMemJournal(pJfd);
  if size < p^.endpoint.iOffset then
  begin
    if size = 0 then
    begin
      memjrnlFreeChunks(p^.pFirst);
      p^.pFirst := nil;
      pIter     := nil;
    end
    else
    begin
      iOff  := p^.nChunkSize;
      pIter := p^.pFirst;
      while Assigned(pIter) and (iOff < size) do
      begin
        iOff  += p^.nChunkSize;
        pIter := pIter^.pNext;
      end;
      if Assigned(pIter) then
      begin
        memjrnlFreeChunks(pIter^.pNext);
        pIter^.pNext := nil;
      end;
    end;
    p^.endpoint.pChunk  := pIter;
    p^.endpoint.iOffset := size;
    p^.readpoint.pChunk  := nil;
    p^.readpoint.iOffset := 0;
  end;
  Result := SQLITE_OK;
end;

{ memjournal.c ~193: memjrnlWrite }
function memjrnlWrite(pJfd: Psqlite3_file; zBuf: Pointer;
           iAmt: cint; iOfst: i64): cint; cdecl;
var
  p            : PMemJournal;
  nWrite       : i32;
  zWrite       : Pu8;
  rc           : i32;
  pChunk       : PFileChunk;
  iChunkOffset : i32;
  iSpace       : i32;
  pNew         : PFileChunk;
begin
  p      := PMemJournal(pJfd);
  nWrite := iAmt;
  zWrite := Pu8(zBuf);

  if (p^.nSpill > 0) and ((iAmt + iOfst) > p^.nSpill) then
  begin
    rc := memjrnlCreateFile(p);
    if rc = SQLITE_OK then
      rc := sqlite3OsWrite(pJfd, zBuf, iAmt, iOfst);
    Exit(rc);
  end;

  if (iOfst > 0) and (iOfst <> p^.endpoint.iOffset) then
    memjrnlTruncate(pJfd, iOfst);

  if (iOfst = 0) and Assigned(p^.pFirst) then
  begin
    Move(zBuf^, p^.pFirst^.zChunk[0], iAmt);
  end
  else
  begin
    while nWrite > 0 do
    begin
      pChunk       := p^.endpoint.pChunk;
      iChunkOffset := i32(p^.endpoint.iOffset mod p^.nChunkSize);
      iSpace       := p^.nChunkSize - iChunkOffset;
      if iSpace > nWrite then iSpace := nWrite;

      if iChunkOffset = 0 then
      begin
        pNew := PFileChunk(sqlite3_malloc(fileChunkSize(p^.nChunkSize)));
        if pNew = nil then
          Exit(SQLITE_IOERR_NOMEM);
        pNew^.pNext := nil;
        if Assigned(pChunk) then
          pChunk^.pNext := pNew
        else
          p^.pFirst := pNew;
        pChunk := pNew;
        p^.endpoint.pChunk := pNew;
      end;

      Move(zWrite^, (Pu8(@pChunk^.zChunk[0]) + iChunkOffset)^, iSpace);
      zWrite += iSpace;
      nWrite -= iSpace;
      p^.endpoint.iOffset += iSpace;
    end;
  end;
  Result := SQLITE_OK;
end;

{ memjournal.c ~289: memjrnlClose }
function memjrnlClose(pJfd: Psqlite3_file): cint; cdecl;
var
  p: PMemJournal;
begin
  p := PMemJournal(pJfd);
  memjrnlFreeChunks(p^.pFirst);
  Result := SQLITE_OK;
end;

{ memjournal.c ~300: memjrnlSync -- no-op for in-memory journal }
function memjrnlSync(pJfd: Psqlite3_file; flags: cint): cint; cdecl;
begin
  { suppress unused warnings }
  if pJfd = nil then;
  if flags = 0 then;
  Result := SQLITE_OK;
end;

{ memjournal.c ~310: memjrnlFileSize }
function memjrnlFileSize(pJfd: Psqlite3_file; pSize: Pi64): cint; cdecl;
var
  p: PMemJournal;
begin
  p      := PMemJournal(pJfd);
  pSize^ := p^.endpoint.iOffset;
  Result := SQLITE_OK;
end;

{ ============================================================
  3.A.3: Exported MemJournal functions
  ============================================================ }

{ memjournal.c ~330: sqlite3JournalOpen }
function sqlite3JournalOpen(pVfs: Psqlite3_vfs; zName: PChar;
           pJfd: Psqlite3_file; flags: i32; nSpill: i32): i32;
var
  p: PMemJournal;
begin
  p := PMemJournal(pJfd);
  FillChar(p^, SizeOf(MemJournal), 0);
  if nSpill = 0 then
    Exit(sqlite3OsOpen(pVfs, zName, pJfd, flags, nil));

  if nSpill > 0 then
    p^.nChunkSize := nSpill
  else
    p^.nChunkSize := 8 + MEMJOURNAL_DFLT_FILECHUNKSIZE - SizeOf(FileChunk);

  pJfd^.pMethods := @MemJournalMethods;
  p^.nSpill   := nSpill;
  p^.flags    := flags;
  p^.zJournal := zName;
  p^.pVfs     := pVfs;
  Result := SQLITE_OK;
end;

{ memjournal.c ~371: sqlite3MemJournalOpen }
procedure sqlite3MemJournalOpen(pJfd: Psqlite3_file);
begin
  sqlite3JournalOpen(nil, nil, pJfd, 0, -1);
end;

{ memjournal.c ~378: sqlite3JournalCreate }
function sqlite3JournalCreate(pJfd: Psqlite3_file): i32;
var
  p : PMemJournal;
begin
  p := PMemJournal(pJfd);
  if (pJfd^.pMethods = @MemJournalMethods) and (p^.nSpill > 0) then
    Result := memjrnlCreateFile(p)
  else
    Result := SQLITE_OK;
end;

{ memjournal.c ~400: sqlite3JournalIsInMemory }
function sqlite3JournalIsInMemory(p: Psqlite3_file): i32;
begin
  if p^.pMethods = @MemJournalMethods then Result := 1
  else Result := 0;
end;

{ memjournal.c ~409: sqlite3JournalSize }
function sqlite3JournalSize(pVfs: Psqlite3_vfs): i32;
var
  szMemJournal: i32;
begin
  szMemJournal := SizeOf(MemJournal);
  if pVfs^.szOsFile > szMemJournal then Result := pVfs^.szOsFile
  else Result := szMemJournal;
end;

{ ============================================================
  3.A.4 Implementation: memdb.c
  ============================================================ }

type
  TMemFS = record
    nMemStore  : i32;          { Number of shared MemStore objects }
    apMemStore : PPMemStore;   { Array of all shared MemStore objects }
  end;

var
  memdb_g   : TMemFS;
  memdb_vfs : sqlite3_vfs;

{ Forward declarations for MemDB IO methods (all cdecl). }
function memdbClose(pFile: Psqlite3_file): cint; cdecl; forward;
function memdbRead(pFile: Psqlite3_file; zBuf: Pointer;
           iAmt: cint; iOfst: i64): cint; cdecl; forward;
function memdbWrite(pFile: Psqlite3_file; zBuf: Pointer;
           iAmt: cint; iOfst: i64): cint; cdecl; forward;
function memdbTruncate(pFile: Psqlite3_file; size: i64): cint; cdecl; forward;
function memdbSync(pFile: Psqlite3_file; flags: cint): cint; cdecl; forward;
function memdbFileSize(pFile: Psqlite3_file; pSize: Pi64): cint; cdecl; forward;
function memdbLock(pFile: Psqlite3_file; eLock: cint): cint; cdecl; forward;
function memdbUnlock(pFile: Psqlite3_file; eLock: cint): cint; cdecl; forward;
function memdbFileControl(pFile: Psqlite3_file; op: cint;
           pArg: Pointer): cint; cdecl; forward;
function memdbDeviceCharacteristics(pFile: Psqlite3_file): cint; cdecl; forward;
function memdbFetch(pFile: Psqlite3_file; iOfst: i64;
           iAmt: cint; pp: PPointer): cint; cdecl; forward;
function memdbUnfetch(pFile: Psqlite3_file; iOfst: i64;
           p: Pointer): cint; cdecl; forward;

{ Forward declarations for MemDB VFS methods (all cdecl). }
function  memdbOpen(pVfs: Psqlite3_vfs; zName: sqlite3_filename;
            pFd: Psqlite3_file; flags: cint;
            pOutFlags: PcInt): cint; cdecl; forward;
function  memdbAccess(pVfs: Psqlite3_vfs; zName: PChar;
            flags: cint; pResOut: PcInt): cint; cdecl; forward;
function  memdbFullPathname(pVfs: Psqlite3_vfs; zName: PChar;
            nOut: cint; zOut: PChar): cint; cdecl; forward;
function  memdbDlOpen(pVfs: Psqlite3_vfs; zFilename: PChar): Pointer; cdecl; forward;
procedure memdbDlError(pVfs: Psqlite3_vfs; nByte: cint;
            zErrMsg: PChar); cdecl; forward;
function  memdbDlSym(pVfs: Psqlite3_vfs; p: Pointer;
            zSymbol: PChar): sqlite3_syscall_ptr; cdecl; forward;
procedure memdbDlClose(pVfs: Psqlite3_vfs; pHandle: Pointer); cdecl; forward;
function  memdbRandomness(pVfs: Psqlite3_vfs; nByte: cint;
            zOut: PChar): cint; cdecl; forward;
function  memdbSleep(pVfs: Psqlite3_vfs; microseconds: cint): cint; cdecl; forward;
function  memdbGetLastError(pVfs: Psqlite3_vfs; a: cint;
            b: PChar): cint; cdecl; forward;
function  memdbCurrentTimeInt64(pVfs: Psqlite3_vfs; p: Pi64): cint; cdecl; forward;

{ IO methods vtable for memdb files. Initialized in unit body. }
var
  memdb_io_methods: sqlite3_io_methods;

{ Return the "lower" (real) VFS that memdb delegates non-storage operations to. }
function ORIGVFS(p: Psqlite3_vfs): Psqlite3_vfs; inline;
begin
  Result := Psqlite3_vfs(p^.pAppData);
end;

procedure memdbEnter(p: PMemStore); inline;
begin
  sqlite3_mutex_enter(p^.pMutex);
end;

procedure memdbLeave(p: PMemStore); inline;
begin
  sqlite3_mutex_leave(p^.pMutex);
end;

{ memdb.c ~194: memdbClose }
function memdbClose(pFile: Psqlite3_file): cint; cdecl;
var
  p         : PMemStore;
  pVfsMutex : Psqlite3_mutex;
  i         : i32;
begin
  p := PMemFile(pFile)^.pStore;

  if Assigned(p^.zFName) then
  begin
    pVfsMutex := sqlite3MutexAlloc(SQLITE_MUTEX_STATIC_VFS1);
    sqlite3_mutex_enter(pVfsMutex);
    i := 0;
    while i < memdb_g.nMemStore do
    begin
      if (memdb_g.apMemStore + i)^ = p then
      begin
        memdbEnter(p);
        if p^.nRef = 1 then
        begin
          Dec(memdb_g.nMemStore);
          (memdb_g.apMemStore + i)^ := (memdb_g.apMemStore + memdb_g.nMemStore)^;
          if memdb_g.nMemStore = 0 then
          begin
            sqlite3_free(memdb_g.apMemStore);
            memdb_g.apMemStore := nil;
          end;
        end;
        break;
      end;
      Inc(i);
    end;
    sqlite3_mutex_leave(pVfsMutex);
  end
  else
    memdbEnter(p);

  Dec(p^.nRef);
  if p^.nRef <= 0 then
  begin
    if (p^.mFlags and SQLITE_DESERIALIZE_FREEONCLOSE) <> 0 then
      sqlite3_free(p^.aData);
    memdbLeave(p);
    sqlite3_mutex_free(p^.pMutex);
    sqlite3_free(p);
  end
  else
    memdbLeave(p);
  Result := SQLITE_OK;
end;

{ memdb.c ~239: memdbRead }
function memdbRead(pFile: Psqlite3_file; zBuf: Pointer;
           iAmt: cint; iOfst: i64): cint; cdecl;
var
  p: PMemStore;
begin
  p := PMemFile(pFile)^.pStore;
  memdbEnter(p);
  if (iOfst + iAmt) > p^.sz then
  begin
    FillChar(zBuf^, iAmt, 0);
    if iOfst < p^.sz then
      Move((p^.aData + iOfst)^, zBuf^, p^.sz - iOfst);
    memdbLeave(p);
    Exit(SQLITE_IOERR_SHORT_READ);
  end;
  Move((p^.aData + iOfst)^, zBuf^, iAmt);
  memdbLeave(p);
  Result := SQLITE_OK;
end;

{ memdb.c ~257: memdbEnlarge }
function memdbEnlarge(p: PMemStore; newSz: i64): i32;
var
  pNew: Pu8;
begin
  if (p^.mFlags and SQLITE_DESERIALIZE_RESIZEABLE) = 0 then
    Exit(SQLITE_FULL);
  if newSz > p^.szMax then
    Exit(SQLITE_FULL);
  newSz := newSz * 2;
  if newSz > p^.szMax then newSz := p^.szMax;
  pNew := Pu8(sqlite3_realloc(p^.aData, i32(newSz)));
  if pNew = nil then Exit(SQLITE_IOERR_NOMEM);
  p^.aData   := pNew;
  p^.szAlloc := newSz;
  Result := SQLITE_OK;
end;

{ memdb.c ~271: memdbWrite }
function memdbWrite(pFile: Psqlite3_file; zBuf: Pointer;
           iAmt: cint; iOfst: i64): cint; cdecl;
var
  p  : PMemStore;
  rc : i32;
begin
  p := PMemFile(pFile)^.pStore;
  memdbEnter(p);
  if (p^.mFlags and SQLITE_DESERIALIZE_READONLY) <> 0 then
  begin
    memdbLeave(p);
    Exit(SQLITE_IOERR_WRITE);
  end;
  if (iOfst + iAmt) > p^.sz then
  begin
    if (iOfst + iAmt) > p^.szAlloc then
    begin
      rc := memdbEnlarge(p, iOfst + iAmt);
      if rc <> SQLITE_OK then
      begin
        memdbLeave(p);
        Exit(rc);
      end;
    end;
    if iOfst > p^.sz then
      FillChar((p^.aData + p^.sz)^, iOfst - p^.sz, 0);
    p^.sz := iOfst + iAmt;
  end;
  Move(zBuf^, (p^.aData + iOfst)^, iAmt);
  memdbLeave(p);
  Result := SQLITE_OK;
end;

{ memdb.c ~302: memdbTruncate }
function memdbTruncate(pFile: Psqlite3_file; size: i64): cint; cdecl;
var
  p  : PMemStore;
  rc : i32;
begin
  p  := PMemFile(pFile)^.pStore;
  rc := SQLITE_OK;
  memdbEnter(p);
  if size > p^.sz then rc := SQLITE_CORRUPT
  else p^.sz := size;
  memdbLeave(p);
  Result := rc;
end;

{ memdb.c ~319: memdbSync (no-op) }
function memdbSync(pFile: Psqlite3_file; flags: cint): cint; cdecl;
begin
  if pFile = nil then;
  if flags = 0 then;
  Result := SQLITE_OK;
end;

{ memdb.c ~329: memdbFileSize }
function memdbFileSize(pFile: Psqlite3_file; pSize: Pi64): cint; cdecl;
var
  p: PMemStore;
begin
  p      := PMemFile(pFile)^.pStore;
  memdbEnter(p);
  pSize^ := p^.sz;
  memdbLeave(p);
  Result := SQLITE_OK;
end;

{ memdb.c ~340: memdbLock }
function memdbLock(pFile: Psqlite3_file; eLock: cint): cint; cdecl;
var
  pThis : PMemFile;
  p     : PMemStore;
  rc    : i32;
begin
  pThis := PMemFile(pFile);
  p     := pThis^.pStore;
  rc    := SQLITE_OK;

  if eLock <= pThis^.eLock then Exit(SQLITE_OK);
  memdbEnter(p);

  if (eLock > SQLITE_LOCK_SHARED) and
     ((p^.mFlags and SQLITE_DESERIALIZE_READONLY) <> 0) then
  begin
    rc := SQLITE_READONLY;
  end
  else
  begin
    case eLock of
      SQLITE_LOCK_SHARED:
      begin
        if p^.nWrLock > 0 then rc := SQLITE_BUSY
        else Inc(p^.nRdLock);
      end;
      SQLITE_LOCK_RESERVED,
      SQLITE_LOCK_PENDING:
      begin
        if pThis^.eLock = SQLITE_LOCK_SHARED then
        begin
          if p^.nWrLock > 0 then rc := SQLITE_BUSY
          else p^.nWrLock := 1;
        end;
      end;
    else
      { SQLITE_LOCK_EXCLUSIVE }
      if p^.nRdLock > 1 then rc := SQLITE_BUSY
      else if pThis^.eLock = SQLITE_LOCK_SHARED then p^.nWrLock := 1;
    end;
  end;

  if rc = SQLITE_OK then pThis^.eLock := eLock;
  memdbLeave(p);
  Result := rc;
end;

{ memdb.c ~395: memdbUnlock }
function memdbUnlock(pFile: Psqlite3_file; eLock: cint): cint; cdecl;
var
  pThis : PMemFile;
  p     : PMemStore;
begin
  pThis := PMemFile(pFile);
  p     := pThis^.pStore;

  if eLock >= pThis^.eLock then Exit(SQLITE_OK);
  memdbEnter(p);

  if eLock = SQLITE_LOCK_SHARED then
  begin
    if pThis^.eLock > SQLITE_LOCK_SHARED then Dec(p^.nWrLock);
  end
  else
  begin
    if pThis^.eLock > SQLITE_LOCK_SHARED then Dec(p^.nWrLock);
    Dec(p^.nRdLock);
  end;
  pThis^.eLock := eLock;
  memdbLeave(p);
  Result := SQLITE_OK;
end;

{ memdb.c ~432: memdbFileControl }
function memdbFileControl(pFile: Psqlite3_file; op: cint;
           pArg: Pointer): cint; cdecl;
var
  p      : PMemStore;
  rc     : i32;
  iLimit : i64;
  buf    : array[0..63] of AnsiChar;
begin
  p  := PMemFile(pFile)^.pStore;
  rc := SQLITE_NOTFOUND;
  memdbEnter(p);
  if op = SQLITE_FCNTL_VFSNAME then
  begin
    { Build "memdb(ptr,sz)" into a stack buffer then StrNew it. }
    StrPCopy(buf, Format('memdb(%p,%d)', [Pointer(p^.aData), Int64(p^.sz)]));
    PPChar(pArg)^ := StrNew(buf);
    rc := SQLITE_OK;
  end;
  if op = SQLITE_FCNTL_SIZE_LIMIT then
  begin
    iLimit := Pi64(pArg)^;
    if iLimit < p^.sz then
    begin
      if iLimit < 0 then iLimit := p^.szMax
      else iLimit := p^.sz;
    end;
    p^.szMax    := iLimit;
    Pi64(pArg)^ := iLimit;
    rc := SQLITE_OK;
  end;
  memdbLeave(p);
  Result := rc;
end;

{ memdb.c ~501: memdbDeviceCharacteristics }
function memdbDeviceCharacteristics(pFile: Psqlite3_file): cint; cdecl;
begin
  if pFile = nil then;
  Result := SQLITE_IOCAP_ATOMIC or
            SQLITE_IOCAP_POWERSAFE_OVERWRITE or
            SQLITE_IOCAP_SAFE_APPEND or
            SQLITE_IOCAP_SEQUENTIAL;
end;

{ memdb.c ~510: memdbFetch }
function memdbFetch(pFile: Psqlite3_file; iOfst: i64;
           iAmt: cint; pp: PPointer): cint; cdecl;
var
  p: PMemStore;
begin
  p := PMemFile(pFile)^.pStore;
  memdbEnter(p);
  if ((iOfst + iAmt) > p^.sz) or
     ((p^.mFlags and SQLITE_DESERIALIZE_RESIZEABLE) <> 0) then
    pp^ := nil
  else
  begin
    Inc(p^.nMmap);
    pp^ := Pointer(p^.aData + iOfst);
  end;
  memdbLeave(p);
  Result := SQLITE_OK;
end;

{ memdb.c ~529: memdbUnfetch }
function memdbUnfetch(pFile: Psqlite3_file; iOfst: i64;
           p: Pointer): cint; cdecl;
var
  pStore: PMemStore;
begin
  pStore := PMemFile(pFile)^.pStore;
  if iOfst = 0 then;
  if p = nil then;
  memdbEnter(pStore);
  Dec(pStore^.nMmap);
  memdbLeave(pStore);
  Result := SQLITE_OK;
end;

{ memdb.c ~542: memdbOpen }
function memdbOpen(pVfs: Psqlite3_vfs; zName: sqlite3_filename;
           pFd: Psqlite3_file; flags: cint;
           pOutFlags: PcInt): cint; cdecl;
var
  pFile     : PMemFile;
  p         : PMemStore;
  szName    : i32;
  pVfsMutex : Psqlite3_mutex;
  apNew     : PPMemStore;
  i         : i32;
begin
  pFile := PMemFile(pFd);
  p     := nil;
  if pVfs = nil then;

  FillChar(pFile^, SizeOf(MemFile), 0);

  if not Assigned(zName) then szName := 0
  else szName := sqlite3Strlen30(zName);

  if (szName > 1) and ((zName[0] = '/') or (zName[0] = '\')) then
  begin
    pVfsMutex := sqlite3MutexAlloc(SQLITE_MUTEX_STATIC_VFS1);
    sqlite3_mutex_enter(pVfsMutex);
    for i := 0 to memdb_g.nMemStore - 1 do
    begin
      if StrComp((memdb_g.apMemStore + i)^^.zFName, zName) = 0 then
      begin
        p := (memdb_g.apMemStore + i)^;
        break;
      end;
    end;

    if p = nil then
    begin
      p := PMemStore(sqlite3_malloc(SizeOf(MemStore) + szName + 3));
      if p = nil then
      begin
        sqlite3_mutex_leave(pVfsMutex);
        Exit(SQLITE_NOMEM);
      end;
      apNew := PPMemStore(sqlite3_realloc(memdb_g.apMemStore,
                  SizeOf(PMemStore) * (memdb_g.nMemStore + 1)));
      if apNew = nil then
      begin
        sqlite3_free(p);
        sqlite3_mutex_leave(pVfsMutex);
        Exit(SQLITE_NOMEM);
      end;
      (apNew + memdb_g.nMemStore)^ := p;
      Inc(memdb_g.nMemStore);
      memdb_g.apMemStore := apNew;

      FillChar(p^, SizeOf(MemStore), 0);
      p^.mFlags := SQLITE_DESERIALIZE_RESIZEABLE or SQLITE_DESERIALIZE_FREEONCLOSE;
      p^.szMax  := sqlite3GlobalConfig.mxMemdbSize;
      p^.zFName := PChar(PByte(p) + SizeOf(MemStore));
      Move(zName^, p^.zFName^, szName + 1);
      p^.pMutex := sqlite3_mutex_alloc(SQLITE_MUTEX_FAST);
      if p^.pMutex = nil then
      begin
        Dec(memdb_g.nMemStore);
        sqlite3_free(p);
        sqlite3_mutex_leave(pVfsMutex);
        Exit(SQLITE_NOMEM);
      end;
      p^.nRef := 1;
      memdbEnter(p);
    end
    else
    begin
      memdbEnter(p);
      Inc(p^.nRef);
    end;
    sqlite3_mutex_leave(pVfsMutex);
  end
  else
  begin
    p := PMemStore(sqlite3_malloc(SizeOf(MemStore)));
    if p = nil then Exit(SQLITE_NOMEM);
    FillChar(p^, SizeOf(MemStore), 0);
    p^.mFlags := SQLITE_DESERIALIZE_RESIZEABLE or SQLITE_DESERIALIZE_FREEONCLOSE;
    p^.szMax  := sqlite3GlobalConfig.mxMemdbSize;
    p^.pMutex := sqlite3_mutex_alloc(SQLITE_MUTEX_FAST);
    if p^.pMutex = nil then
    begin
      sqlite3_free(p);
      Exit(SQLITE_NOMEM);
    end;
  end;

  pFile^.pStore := p;
  if Assigned(pOutFlags) then
    pOutFlags^ := flags or SQLITE_OPEN_MEMORY;
  pFd^.pMethods := @memdb_io_methods;
  memdbLeave(p);
  Result := SQLITE_OK;
end;

{ memdb.c VFS helper functions }

function memdbAccess(pVfs: Psqlite3_vfs; zName: PChar;
           flags: cint; pResOut: PcInt): cint; cdecl;
begin
  if pVfs = nil then;
  if zName = nil then;
  if flags = 0 then;
  pResOut^ := 0;
  Result   := SQLITE_OK;
end;

function memdbFullPathname(pVfs: Psqlite3_vfs; zName: PChar;
           nOut: cint; zOut: PChar): cint; cdecl;
begin
  if pVfs = nil then;
  StrLCopy(zOut, zName, nOut - 1);
  Result := SQLITE_OK;
end;

function memdbDlOpen(pVfs: Psqlite3_vfs; zFilename: PChar): Pointer; cdecl;
begin
  Result := ORIGVFS(pVfs)^.xDlOpen(ORIGVFS(pVfs), zFilename);
end;

procedure memdbDlError(pVfs: Psqlite3_vfs; nByte: cint; zErrMsg: PChar); cdecl;
begin
  ORIGVFS(pVfs)^.xDlError(ORIGVFS(pVfs), nByte, zErrMsg);
end;

function memdbDlSym(pVfs: Psqlite3_vfs; p: Pointer;
           zSymbol: PChar): sqlite3_syscall_ptr; cdecl;
begin
  Result := ORIGVFS(pVfs)^.xDlSym(ORIGVFS(pVfs), p, zSymbol);
end;

procedure memdbDlClose(pVfs: Psqlite3_vfs; pHandle: Pointer); cdecl;
begin
  ORIGVFS(pVfs)^.xDlClose(ORIGVFS(pVfs), pHandle);
end;

function memdbRandomness(pVfs: Psqlite3_vfs; nByte: cint; zOut: PChar): cint; cdecl;
begin
  Result := ORIGVFS(pVfs)^.xRandomness(ORIGVFS(pVfs), nByte, zOut);
end;

function memdbSleep(pVfs: Psqlite3_vfs; microseconds: cint): cint; cdecl;
begin
  Result := ORIGVFS(pVfs)^.xSleep(ORIGVFS(pVfs), microseconds);
end;

function memdbGetLastError(pVfs: Psqlite3_vfs; a: cint; b: PChar): cint; cdecl;
begin
  Result := ORIGVFS(pVfs)^.xGetLastError(ORIGVFS(pVfs), a, b);
end;

function memdbCurrentTimeInt64(pVfs: Psqlite3_vfs; p: Pi64): cint; cdecl;
begin
  Result := ORIGVFS(pVfs)^.xCurrentTimeInt64(ORIGVFS(pVfs), p);
end;

{ ============================================================
  3.A.4: Exported memdb functions
  ============================================================ }

function sqlite3IsMemdb(pVfs: Psqlite3_vfs): i32;
begin
  if pVfs = @memdb_vfs then Result := 1
  else Result := 0;
end;

{ memdb.c ~765: sqlite3MemdbInit -- register the memdb VFS }
function sqlite3MemdbInit: i32;
var
  pLower : Psqlite3_vfs;
  sz     : cint;
begin
  pLower := sqlite3_vfs_find(nil);
  if pLower = nil then Exit(SQLITE_ERROR);
  sz := pLower^.szOsFile;

  FillChar(memdb_io_methods, SizeOf(memdb_io_methods), 0);
  memdb_io_methods.iVersion               := 3;
  memdb_io_methods.xClose                 := @memdbClose;
  memdb_io_methods.xRead                  := @memdbRead;
  memdb_io_methods.xWrite                 := @memdbWrite;
  memdb_io_methods.xTruncate              := @memdbTruncate;
  memdb_io_methods.xSync                  := @memdbSync;
  memdb_io_methods.xFileSize              := @memdbFileSize;
  memdb_io_methods.xLock                  := @memdbLock;
  memdb_io_methods.xUnlock                := @memdbUnlock;
  memdb_io_methods.xCheckReservedLock     := nil;
  memdb_io_methods.xFileControl           := @memdbFileControl;
  memdb_io_methods.xSectorSize            := nil;
  memdb_io_methods.xDeviceCharacteristics := @memdbDeviceCharacteristics;
  memdb_io_methods.xShmMap                := nil;
  memdb_io_methods.xShmLock               := nil;
  memdb_io_methods.xShmBarrier            := nil;
  memdb_io_methods.xShmUnmap              := nil;
  memdb_io_methods.xFetch                 := @memdbFetch;
  memdb_io_methods.xUnfetch               := @memdbUnfetch;

  FillChar(memdb_vfs, SizeOf(memdb_vfs), 0);
  memdb_vfs.iVersion          := 2;
  if sz < SizeOf(MemFile) then sz := SizeOf(MemFile);
  memdb_vfs.szOsFile          := sz;
  memdb_vfs.mxPathname        := 1024;
  memdb_vfs.zName             := 'memdb';
  memdb_vfs.pAppData          := pLower;
  memdb_vfs.xOpen             := @memdbOpen;
  memdb_vfs.xDelete           := nil;
  memdb_vfs.xAccess           := @memdbAccess;
  memdb_vfs.xFullPathname     := @memdbFullPathname;
  memdb_vfs.xDlOpen           := @memdbDlOpen;
  memdb_vfs.xDlError          := @memdbDlError;
  memdb_vfs.xDlSym            := @memdbDlSym;
  memdb_vfs.xDlClose          := @memdbDlClose;
  memdb_vfs.xRandomness       := @memdbRandomness;
  memdb_vfs.xSleep            := @memdbSleep;
  memdb_vfs.xCurrentTime      := nil;
  memdb_vfs.xGetLastError     := @memdbGetLastError;
  memdb_vfs.xCurrentTimeInt64 := @memdbCurrentTimeInt64;

  Result := sqlite3_vfs_register(@memdb_vfs, 0);
end;

{ ============================================================
  Unit initialization: set up the MemJournal methods vtable.
  ============================================================ }
initialization
  FillChar(MemJournalMethods, SizeOf(MemJournalMethods), 0);
  MemJournalMethods.iVersion               := 1;
  MemJournalMethods.xClose                 := @memjrnlClose;
  MemJournalMethods.xRead                  := @memjrnlRead;
  MemJournalMethods.xWrite                 := @memjrnlWrite;
  MemJournalMethods.xTruncate              := @memjrnlTruncate;
  MemJournalMethods.xSync                  := @memjrnlSync;
  MemJournalMethods.xFileSize              := @memjrnlFileSize;

end.
