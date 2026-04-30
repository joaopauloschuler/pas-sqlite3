{
  SPDX-License-Identifier: blessing

  The author disclaims copyright to this source code.  In place of
  a legal notice, here is a blessing:

     May you do good and not evil.
     May you find forgiveness for yourself and forgive others.
     May you share freely, never taking more than you give.

  ------------------------------------------------------------------------

  This work is dedicated to all human kind, and also to all non-human kinds.

  This is a faithful port of SQLite 3.53 (https://sqlite.org/) from C to
  Free Pascal, authored by Dr. Joao Paulo Schwarz Schuler and contributors
  (see commit history). The original SQLite C source code is in the public
  domain, authored by D. Richard Hipp and contributors. This Pascal port
  adopts the same public-domain posture.
}
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
  passqlite3wal,
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

  { Pager state values (pager.c; stored in Pager.eState) }
  PAGER_OPEN             = 0;
  PAGER_READER           = 1;
  PAGER_WRITER_LOCKED    = 2;
  PAGER_WRITER_CACHEMOD  = 3;
  PAGER_WRITER_DBMOD     = 4;
  PAGER_WRITER_FINISHED  = 5;
  PAGER_ERROR            = 6;

  { SQLITE_PTRSIZE (64-bit Linux) }
  SQLITE_PTRSIZE = SizeOf(Pointer);

  { sqlite3.h ~581: internal return code for VFS symlink detection }
  SQLITE_OK_SYMLINK = SQLITE_OK or (2 shl 8);

  { sqliteInt.h ~1456: default synchronous mode (2=FULL for non-WAL builds) }
  SQLITE_DEFAULT_SYNCHRONOUS = 2;

type
  { Forward declarations }
  PPager          = ^Pager;
  PPagerSavepoint = ^PagerSavepoint;
  { PWal comes directly from passqlite3wal (already in uses clause) }
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

  { Callback types }
  TDbPageReinit   = procedure(p: PDbPage);
  TBusyHandler    = function(p: Pointer): i32;
  PPDbPage        = ^PDbPage;            { DbPage** in C: out-param for page getters }
  TPageGetter     = function(pPager: PPager; pgno: Pgno; ppPage: PPDbPage; flags: i32): i32;

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
    xBusyHandler   : TBusyHandler;              { Function to call when busy }
    pBusyHandlerArg: Pointer;        { Context argument for xBusyHandler }
    aStat          : array[0..3] of u32;  { Cache hits, misses, writes, spills }
    xReiniter      : TDbPageReinit;         { Called when reloading pages }
    xGet           : TPageGetter;                          { Fetch a page }
    pTmpSpace      : PChar;          { Pager.pageSize bytes of tmp space }
    pPCache        : PPCache;        { Pointer to page cache object }
    pWal           : PWal;           { Write-ahead log (journal_mode=wal) }
    zWal           : PChar;          { File name for write-ahead log }
  end;

{ ============================================================
  3.B.1 + 3.B.2a: pager.h public API declarations
  ============================================================ }

{ pager.h macros as inline functions }
function isWalMode(x: i32): i32; inline;
function isOpen(pFd: Psqlite3_file): i32; inline;

{ Lowercase journal-mode name for PRAGMA journal_mode echo. Port of
  pragma.c:289 sqlite3JournalModename. }
function sqlite3JournalModename(eMode: i32): PAnsiChar;

{ 3.B.2a: Open/close/configure }
function sqlite3PagerOpen(
  pVfs      : Psqlite3_vfs;
  out ppPager: PPager;
  zFilename  : PChar;
  nExtra     : i32;
  flags      : i32;
  vfsFlags   : i32;
  xReinit    : TDbPageReinit): i32;
function  sqlite3PagerClose(pPager: PPager; db: Pointer): i32;
function  sqlite3PagerReadFileheader(pPager: PPager; N: i32; pDest: Pu8): i32;
procedure sqlite3PagerSetBusyHandler(pPager: PPager;
            xBusy: TBusyHandler; pArg: Pointer);
function  sqlite3PagerSetPagesize(pPager: PPager; pPageSize: Pu32;
            nReserve: i32): i32;
procedure sqlite3PagerSetCachesize(pPager: PPager; mxPage: i32);
function  sqlite3PagerSetSpillsize(pPager: PPager; mxPage: i32): i32;
procedure sqlite3PagerSetMmapLimit(pPager: PPager; szMmap: i64);
procedure sqlite3PagerShrink(pPager: PPager);
function  sqlite3PagerTempSpace(pPager: PPager): Pointer;
procedure sqlite3PagerSetFlags(pPager: PPager; pgFlags: u32);
function  sqlite3PagerLockingMode(pPager: PPager; eMode: i32): i32;
function  sqlite3PagerPagenumber(pPg: PDbPage): Pgno;
function  sqlite3PagerIswriteable(pPg: PDbPage): i32;
function  sqlite3PagerRefcount(pPager: PPager): i32;
function  sqlite3PagerPageRefcount(pPg: PDbPage): i32;

{ 3.B.2a: Page access }
function  sqlite3PagerSharedLock(pPager: PPager): i32;
function  sqlite3PagerGet(pPager: PPager; pgno: Pgno;
            ppPage: PPDbPage; flags: i32): i32;
function  sqlite3PagerLookup(pPager: PPager; pgno: Pgno): PDbPage;
procedure sqlite3PagerRef(pPg: PDbPage);
procedure sqlite3PagerUnref(pPg: PDbPage);
procedure sqlite3PagerUnrefNotNull(pPg: PDbPage);
procedure sqlite3PagerUnrefPageOne(pPg: PDbPage);
function  sqlite3PagerGetData(pPg: PDbPage): Pointer;
function  sqlite3PagerGetExtra(pPg: PDbPage): Pointer;

{ 3.B.2a: Query state / config }
procedure sqlite3PagerPagecount(pPager: PPager; pnPage: Pi32);
function  sqlite3PagerMaxPageCount(pPager: PPager; mxPage: Pgno): Pgno;
function  sqlite3PagerIsreadonly(pPager: PPager): u8;
function  sqlite3PagerDataVersion(pPager: PPager): u32;
function  sqlite3PagerIsMemdb(pPager: PPager): i32;
function  sqlite3PagerFilename(pPager: PPager; nullIfMemDb: i32): PChar;
function  sqlite3PagerVfs(pPager: PPager): Psqlite3_vfs;
function  sqlite3PagerFile(pPager: PPager): Psqlite3_file;
function  sqlite3PagerJrnlFile(pPager: PPager): Psqlite3_file;

{ pager.c:5090 — public API.  Given any filename pointer that lies inside
  the buffer allocated by sqlite3PagerOpen (database, journal, or WAL
  name), walk back to the 4-byte zero prefix that precedes the database
  filename and read the back-pointer to the Pager that lives just before
  it.  Returns the main database sqlite3_file. }
function  sqlite3_database_file_object(zName: PChar): Psqlite3_file; cdecl;

{ 3.B.2b: Write transaction / journaling / commit / rollback }
const
  SAVEPOINT_BEGIN    = 0;
  SAVEPOINT_RELEASE  = 1;
  SAVEPOINT_ROLLBACK = 2;

function  sqlite3PagerBegin(pPager: PPager; exFlag: i32; subjInMemory: i32): i32;
function  sqlite3PagerWrite(pPg: PDbPage): i32;
procedure sqlite3PagerDontWrite(pPg: PDbPage);
function  sqlite3PagerSync(pPager: PPager; zSuper: PChar): i32;
function  sqlite3PagerExclusiveLock(pPager: PPager): i32;
function  sqlite3PagerCommitPhaseOne(pPager: PPager; zSuper: PChar;
            noSync: i32): i32;
function  sqlite3PagerCommitPhaseTwo(pPager: PPager): i32;
function  sqlite3PagerRollback(pPager: PPager): i32;
function  sqlite3PagerOpenSavepoint(pPager: PPager; nSavepoint: i32): i32;
function  sqlite3PagerSavepoint(pPager: PPager; op: i32; iSavepoint: i32): i32;
function  sqlite3PagerFlush(pPager: PPager): i32;
procedure sqlite3PagerTruncateImage(pPager: PPager; nPage: Pgno);
function  sqlite3PagerCacheStat(pPager: PPager; eStat: i32; reset: i32): u64;
function  sqlite3PagerMemUsed(pPager: PPager): i32;
{ Memory helpers used by btree and other consumers }
function  sqlite3Realloc(p: Pointer; n: NativeUInt): Pointer;

{ WAL public API (Phase 3.B.3b) }
function  sqlite3PagerOpenWal(pPager: PPager; pbOpen: PcInt): i32;
function  sqlite3PagerWalSupported(pPager: PPager): i32;
function  sqlite3PagerCheckpoint(pPager: PPager; db: Pointer; eMode: i32;
                                 xBusy: TxBusyCallback; pBusyArg: Pointer;
                                 pnLog: PcInt; pnCkpt: PcInt): i32;
function  sqlite3PagerWalCallback(pPager: PPager): i32;
function  sqlite3PagerWalFile(pPager: PPager): Psqlite3_file;

{ ===========================================================================
  Phase 8.7 — accessors required by backup.c
  =========================================================================== }
{ pager.c:1497 — return the current journal mode (PAGER_JOURNALMODE_*). }
function  sqlite3PagerGetJournalMode(pPager: PPager): i32;
{ pager.c:7838 — &pPager->pBackup, used to thread sqlite3_backup objects. }
function  sqlite3PagerBackupPtr(pPager: PPager): PPointer;
{ pager.c:6857 — drop every page out of the page cache. }
procedure sqlite3PagerClearCache(pPager: PPager);
{ pager.c:7460 — return 1 if it is safe to change the journal mode. }
function  sqlite3PagerOkToChangeJournalMode(pPager: PPager): i32;
{ pager.c:7473 — get/set the persistent-journal size limit (-1 = no limit). }
function  sqlite3PagerJournalSizeLimit(pPager: PPager; iLimit: i64): i64;

{ Cross-unit hook: backup.c's sqlite3BackupRestart, installed by
  passqlite3backup at unit initialisation.  Faithful port of pager_reset
  needs to call sqlite3BackupRestart, but passqlite3backup `uses`
  passqlite3pager — direct call would cycle.  Hook breaks the cycle while
  keeping behaviour identical to the C source. }
type
  TPagerBackupRestartProc = procedure(pBackupHead: Pointer);
var
  sqlite3PagerBackupRestartFn: TPagerBackupRestartProc;

{ SQLITE_DBSTATUS constants (sqlite.h.in:9194).  Public so that
  sqlite3_db_status / sqlite3_db_status64 callers can name the verbs. }
const
  SQLITE_DBSTATUS_LOOKASIDE_USED      = 0;
  SQLITE_DBSTATUS_CACHE_USED          = 1;
  SQLITE_DBSTATUS_SCHEMA_USED         = 2;
  SQLITE_DBSTATUS_STMT_USED           = 3;
  SQLITE_DBSTATUS_LOOKASIDE_HIT       = 4;
  SQLITE_DBSTATUS_LOOKASIDE_MISS_SIZE = 5;
  SQLITE_DBSTATUS_LOOKASIDE_MISS_FULL = 6;
  SQLITE_DBSTATUS_CACHE_HIT           = 7;
  SQLITE_DBSTATUS_CACHE_MISS          = 8;
  SQLITE_DBSTATUS_CACHE_WRITE         = 9;
  SQLITE_DBSTATUS_DEFERRED_FKS        = 10;
  SQLITE_DBSTATUS_CACHE_USED_SHARED   = 11;
  SQLITE_DBSTATUS_CACHE_SPILL         = 12;
  SQLITE_DBSTATUS_TEMPBUF_SPILL       = 13;
  SQLITE_DBSTATUS_MAX                 = 13;

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

{ sqlite3JournalModename — port of pragma.c:289.  Returns the lowercase
  string name corresponding to a PAGER_JOURNALMODE_* constant, or nil
  for an out-of-range index. }
const
  azJournalModeName: array[0..5] of PAnsiChar = (
    'delete', 'persist', 'off', 'truncate', 'memory', 'wal'
  );

function sqlite3JournalModename(eMode: i32): PAnsiChar;
begin
  Assert(PAGER_JOURNALMODE_DELETE = 0);
  Assert(PAGER_JOURNALMODE_PERSIST = 1);
  Assert(PAGER_JOURNALMODE_OFF = 2);
  Assert(PAGER_JOURNALMODE_TRUNCATE = 3);
  Assert(PAGER_JOURNALMODE_MEMORY = 4);
  Assert(PAGER_JOURNALMODE_WAL = 5);
  Assert((eMode >= 0) and (eMode <= Length(azJournalModeName)));
  if eMode = Length(azJournalModeName) then
  begin
    Result := nil;
    Exit;
  end;
  Result := azJournalModeName[eMode];
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

{ Journal magic byte array -- matches C static const aJournalMagic[] }
const
  aJournalMagic: array[0..7] of u8 = (
    $D9, $D5, $05, $F9, $20, $A1, $63, $D7);

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
  3.B.2a Implementation: pager.c read-only path
  ============================================================ }

{ pager.c ~2694: sqlite3SectorSize }
function sqlite3SectorSize(pFile: Psqlite3_file): i32;
var
  iRet: i32;
begin
  iRet := sqlite3OsSectorSize(pFile);
  if iRet < 32 then iRet := 512
  else if iRet > MAX_SECTOR_SIZE then iRet := MAX_SECTOR_SIZE;
  Result := iRet;
end;

{ pager.c ~2728: setSectorSize }
procedure setSectorSize(pPager: PPager);
begin
  if (pPager^.tempFile <> 0)
    or ((sqlite3OsDeviceCharacteristics(pPager^.fd) and SQLITE_IOCAP_POWERSAFE_OVERWRITE) <> 0)
  then
    pPager^.sectorSize := 512
  else
    pPager^.sectorSize := u32(sqlite3SectorSize(pPager^.fd));
end;

{ Forward declarations for page getter functions }
function getPageError(pPager: PPager; pgno: Pgno; ppPage: PPDbPage; flags: i32): i32; forward;
function getPageNormal(pPager: PPager; pgno: Pgno; ppPage: PPDbPage; flags: i32): i32; forward;
function pagerStress(p: Pointer; pPg: PPgHdr): i32; forward;
function pagerSyncHotJournal(pPager: PPager): i32; forward;
procedure pagerFreeMapHdrs(pPager: PPager); forward;
procedure pagerReleaseMapPage(pPg: PPgHdr); forward;
function pager_playback(pPager: PPager; isHot: i32): i32; forward;
function pagerSetError(pPager: PPager; rc: i32): i32; forward;
procedure pager_unlock(pPager: PPager); forward;
procedure releaseAllSavepoints(pPager: PPager); forward;
procedure pager_reset(pPager: PPager); forward;
function pagerLockDb(pPager: PPager; eLock: i32): i32; forward;
function pagerUnlockDb(pPager: PPager; eLock: i32): i32; forward;
procedure pagerUnlockAndRollback(pPager: PPager); forward;
procedure pagerUnlockIfUnused(pPager: PPager); forward;
function pagerPagecount(pPager: PPager; pnPage: PPgno): i32; forward;
function pagerOpenWalIfPresent(pPager: PPager): i32; forward;
function pager_wait_on_lock(pPager: PPager; locktype: i32): i32; forward;
function hasHotJournal(pPager: PPager; pExists: PcInt): i32; forward;
function readDbPage(pPg: PPgHdr): i32; forward;
{ Phase 3.B.2b forward declarations }
function readSuperJournal(pJrnl: Psqlite3_file; zSuper: PChar; nSuper: i64): i32; forward;
function read32bits(fd: Psqlite3_file; offset: i64; pRes: Pu32): i32; forward;
function write32bits(fd: Psqlite3_file; offset: i64; val: u32): i32; forward;
function journalHdrOffset(pPager: PPager): i64; forward;
function pager_cksum(pPager: PPager; aData: Pu8): u32; forward;
function syncJournal(pPager: PPager; newHdr: i32): i32; forward;
function pager_write_pagelist(pPager: PPager; pList: PPgHdr): i32; forward;
function pager_open_journal(pPager: PPager): i32; forward;
function pager_end_transaction(pPager: PPager; hasSuper: i32; bCommit: i32): i32; forward;
function pager_truncate(pPager: PPager; nPage: Pgno): i32; forward;
function pager_playback_one_page(pPager: PPager; pOffset: Pi64;
  pDone: PBitvec; isMainJrnl: i32; isSavepnt: i32): i32; forward;
function pagerPlaybackSavepoint(pPager: PPager; pSavepoint: PPagerSavepoint): i32; forward;
function databaseIsUnmoved(pPager: PPager): i32; forward;
function subjournalPageIfRequired(pPg: PPgHdr): i32; forward;
function subjournalPage(pPg: PPgHdr): i32; forward;
function addToSavepointBitvecs(pPager: PPager; pgno: Pgno): i32; forward;
function pager_delsuper(pPager: PPager; zSuper: PChar): i32; forward;
procedure sqlite3_log(iErrCode: i32; zMsg: PChar); forward;
{ WAL wiring forward declarations (Phase 3.B.3b) }
function pagerUseWal(pPager: PPager): i32; forward;
function pagerBeginReadTransaction(pPager: PPager): i32; forward;
function pagerWalFrames(pPager: PPager; pList: PPgHdr; nTruncate: Pgno; isCommit: i32): i32; forward;
function pagerRollbackWal(pPager: PPager): i32; forward;
function pagerUndoCallback(pCtx: Pointer; pgno: Pgno): i32; forward;
function pagerExclusiveLock(pPager: PPager): i32; forward;
procedure pager_write_changecounter(pPg: PPgHdr); forward;
{ Public 3.B.2b functions declared in interface; no forward needed here }

procedure setGetterMethod(pPager: PPager);
begin
  if pPager^.errCode <> 0 then
    pPager^.xGet := @getPageError
  else
    pPager^.xGet := @getPageNormal;
end;

{ pager.c ~1772: pager_reset }
procedure pager_reset(pPager: PPager);
begin
  Inc(pPager^.iDataVersion);
  if Assigned(sqlite3PagerBackupRestartFn) then
    sqlite3PagerBackupRestartFn(pPager^.pBackup);
  sqlite3PcacheClear(pPager^.pPCache);
end;

{ pager.c ~1781: sqlite3PagerDataVersion }
function sqlite3PagerDataVersion(pPager: PPager): u32;
begin
  Result := pPager^.iDataVersion;
end;

{ pager.c ~1790: releaseAllSavepoints }
procedure releaseAllSavepoints(pPager: PPager);
var
  ii: i32;
begin
  for ii := 0 to pPager^.nSavepoint - 1 do
    sqlite3BitvecDestroy((pPager^.aSavepoint + ii)^.pInSavepoint);
  if (pPager^.exclusiveMode = 0) or (sqlite3JournalIsInMemory(pPager^.sjfd) <> 0) then
    sqlite3OsClose(pPager^.sjfd);
  sqlite3_free(pPager^.aSavepoint);
  pPager^.aSavepoint := nil;
  pPager^.nSavepoint := 0;
  pPager^.nSubRec := 0;
end;

{ pager.c ~1841: pager_unlock }
procedure pager_unlock(pPager: PPager);
var
  rc  : i32;
  iDc : i32;
begin
  sqlite3BitvecDestroy(pPager^.pInJournal);
  pPager^.pInJournal := nil;
  releaseAllSavepoints(pPager);

  if pagerUseWal(pPager) <> 0 then
  begin
    if pPager^.eState = PAGER_ERROR then
      sqlite3WalEndWriteTransaction(pPager^.pWal);
    sqlite3WalEndReadTransaction(pPager^.pWal);
    pPager^.eState := PAGER_OPEN;
  end
  else if pPager^.exclusiveMode = 0 then
  begin
    if isOpen(pPager^.fd) <> 0 then
      iDc := sqlite3OsDeviceCharacteristics(pPager^.fd)
    else
      iDc := 0;

    { Close journal if OS supports deletion of open files }
    if ((iDc and SQLITE_IOCAP_UNDELETABLE_WHEN_OPEN) = 0)
      or ((pPager^.journalMode and 5) <> 1)
    then
      sqlite3OsClose(pPager^.jfd);

    rc := pagerUnlockDb(pPager, NO_LOCK);
    if (rc <> SQLITE_OK) and (pPager^.eState = PAGER_ERROR) then
      pPager^.eLock := UNKNOWN_LOCK;

    pPager^.eState := PAGER_OPEN;
  end;

  if pPager^.errCode <> 0 then
  begin
    if pPager^.tempFile = 0 then
    begin
      pager_reset(pPager);
      pPager^.changeCountDone := 0;
      pPager^.eState := PAGER_OPEN;
    end else
    begin
      if isOpen(pPager^.jfd) <> 0 then
        pPager^.eState := PAGER_OPEN
      else
        pPager^.eState := PAGER_READER;
    end;
    pPager^.errCode := SQLITE_OK;
    setGetterMethod(pPager);
  end;

  pPager^.journalOff := 0;
  pPager^.journalHdr := 0;
  pPager^.setSuper   := 0;
end;

{ pager.c ~1133: pagerUnlockDb }
function pagerUnlockDb(pPager: PPager; eLock: i32): i32;
var
  rc: i32;
begin
  rc := SQLITE_OK;
  if isOpen(pPager^.fd) <> 0 then
  begin
    if pPager^.noLock = 0 then
      rc := sqlite3OsUnlock(pPager^.fd, eLock);
    if pPager^.eLock <> UNKNOWN_LOCK then
      pPager^.eLock := u8(eLock);
  end;
  if pPager^.tempFile <> 0 then
    pPager^.changeCountDone := 1
  else
    pPager^.changeCountDone := 0;
  Result := rc;
end;

{ pager.c ~1161: pagerLockDb }
function pagerLockDb(pPager: PPager; eLock: i32): i32;
var
  rc: i32;
begin
  rc := SQLITE_OK;
  if (pPager^.eLock < eLock) or (pPager^.eLock = UNKNOWN_LOCK) then
  begin
    if pPager^.noLock = 0 then
      rc := sqlite3OsLock(pPager^.fd, eLock);
    if (rc = SQLITE_OK) and ((pPager^.eLock <> UNKNOWN_LOCK) or (eLock = EXCLUSIVE_LOCK)) then
      pPager^.eLock := u8(eLock);
  end;
  Result := rc;
end;

{ pager.c ~1947: pagerSetError }
function pagerSetError(pPager: PPager; rc: i32): i32;
var
  rc2: i32;
begin
  rc2 := rc and $ff;
  if (rc2 = SQLITE_FULL) or (rc2 = SQLITE_IOERR) then
  begin
    pPager^.errCode := rc;
    pPager^.eState  := PAGER_ERROR;
    setGetterMethod(pPager);
  end;
  Result := rc;
end;

{ pager.c ~3533: pagerFixMaplimit -- mmap support }
procedure pagerFixMaplimit(pPager: PPager);
begin
  { SQLITE_MAX_MMAP_SIZE > 0 on 64-bit; pass hint to VFS }
  if isOpen(pPager^.fd) <> 0 then
  begin
    pPager^.bUseFetch := 0;  { not using mmap in this port }
    setGetterMethod(pPager);
  end;
end;

{ pager.c ~3946: pager_wait_on_lock }
function pager_wait_on_lock(pPager: PPager; locktype: i32): i32;
var
  rc: i32;
begin
  repeat
    rc := pagerLockDb(pPager, locktype);
  until not ((rc = SQLITE_BUSY) and Assigned(pPager^.xBusyHandler)
        and (pPager^.xBusyHandler(pPager^.pBusyHandlerArg) <> 0));
  Result := rc;
end;

{ pager.c ~3279: pagerPagecount }
function pagerPagecount(pPager: PPager; pnPage: PPgno): i32;
var
  nPage: Pgno;
  n    : i64;
  rc   : i32;
begin
  nPage := sqlite3WalDbsize(pPager^.pWal);
  if nPage = 0 then
  begin
    n := 0;
    rc := sqlite3OsFileSize(pPager^.fd, @n);
    if rc <> SQLITE_OK then
    begin
      Result := rc;
      Exit;
    end;
    nPage := Pgno((n + pPager^.pageSize - 1) div pPager^.pageSize);
  end;
  if nPage > pPager^.mxPgno then
    pPager^.mxPgno := nPage;
  pnPage^ := nPage;
  Result := SQLITE_OK;
end;

{ pager.c ~5134: hasHotJournal }
function hasHotJournal(pPager: PPager; pExists: PcInt): i32;
var
  rc       : i32;
  exists   : i32;
  locked   : i32;
  nPage    : Pgno;
  jrnlOpen : i32;
  first    : u8;
  f        : i32;
  fout     : i32;
begin
  rc       := SQLITE_OK;
  exists   := 1;
  locked   := 0;
  jrnlOpen := isOpen(pPager^.jfd);
  pExists^ := 0;

  if jrnlOpen = 0 then
    rc := sqlite3OsAccess(pPager^.pVfs, pPager^.zJournal, SQLITE_ACCESS_EXISTS, @exists);

  if (rc = SQLITE_OK) and (exists <> 0) then
  begin
    rc := sqlite3OsCheckReservedLock(pPager^.fd, @locked);
    if (rc = SQLITE_OK) and (locked = 0) then
    begin
      rc := pagerPagecount(pPager, @nPage);
      if rc = SQLITE_OK then
      begin
        if (nPage = 0) and (jrnlOpen = 0) then
        begin
          sqlite3BeginBenignMalloc;
          if pagerLockDb(pPager, RESERVED_LOCK) = SQLITE_OK then
          begin
            sqlite3OsDelete(pPager^.pVfs, pPager^.zJournal, 0);
            if pPager^.exclusiveMode = 0 then
              pagerUnlockDb(pPager, SHARED_LOCK);
          end;
          sqlite3EndBenignMalloc;
        end else
        begin
          if jrnlOpen = 0 then
          begin
            f    := SQLITE_OPEN_READONLY or SQLITE_OPEN_MAIN_JOURNAL;
            fout := 0;
            rc   := sqlite3OsOpen(pPager^.pVfs, pPager^.zJournal, pPager^.jfd, f, @fout);
          end;
          if rc = SQLITE_OK then
          begin
            first := 0;
            rc    := sqlite3OsRead(pPager^.jfd, @first, 1, 0);
            if rc = SQLITE_IOERR_SHORT_READ then rc := SQLITE_OK;
            if jrnlOpen = 0 then sqlite3OsClose(pPager^.jfd);
            if first <> 0 then pExists^ := 1 else pExists^ := 0;
          end else if rc = SQLITE_CANTOPEN then
          begin
            pExists^ := 1;
            rc := SQLITE_OK;
          end;
        end;
      end;
    end;
  end;
  Result := rc;
end;

{ pager.c ~7558: sqlite3PagerWalSupported }
function sqlite3PagerWalSupported(pPager: PPager): i32;
var
  pMethods: Psqlite3_io_methods;
begin
  if pPager^.noLock <> 0 then begin Result := 0; Exit; end;
  pMethods := pPager^.fd^.pMethods;
  if (pPager^.exclusiveMode <> 0)
  or ((pMethods^.iVersion >= 2) and Assigned(pMethods^.xShmMap))
  then Result := 1
  else Result := 0;
end;

{ pager.c ~7561: pagerExclusiveLock }
function pagerExclusiveLock(pPager: PPager): i32;
var
  rc         : i32;
  eOrigLock  : u8;
begin
  eOrigLock := pPager^.eLock;
  rc := pagerLockDb(pPager, EXCLUSIVE_LOCK);
  if rc <> SQLITE_OK then
  begin
    rc := pagerLockDb(pPager, PENDING_LOCK);
    if rc = SQLITE_OK then
      pagerUnlockDb(pPager, eOrigLock);
  end;
  Result := rc;
end;

{ pager.c ~7581: pagerOpenWal (internal) }
function pagerOpenWal(pPager: PPager): i32;
var
  rc: i32;
begin
  rc := SQLITE_OK;
  if pPager^.exclusiveMode <> 0 then
    rc := pagerExclusiveLock(pPager);
  if rc = SQLITE_OK then
    rc := sqlite3WalOpen(pPager^.pVfs, pPager^.fd, pPager^.zWal,
                         pPager^.exclusiveMode, pPager^.journalSizeLimit,
                         @pPager^.pWal);
  pagerFixMaplimit(pPager);
  Result := rc;
end;

{ pager.c ~7631: sqlite3PagerOpenWal }
function sqlite3PagerOpenWal(pPager: PPager; pbOpen: PcInt): i32;
var
  rc: i32;
begin
  rc := SQLITE_OK;
  if (pPager^.tempFile = 0) and (pPager^.pWal = nil) then
  begin
    if sqlite3PagerWalSupported(pPager) = 0 then Exit(SQLITE_CANTOPEN);
    sqlite3OsClose(pPager^.jfd);
    rc := pagerOpenWal(pPager);
    if rc = SQLITE_OK then
    begin
      pPager^.journalMode := PAGER_JOURNALMODE_WAL;
      pPager^.eState      := PAGER_OPEN;
    end;
  end
  else if pbOpen <> nil then
    pbOpen^ := 1;
  Result := rc;
end;

{ pager.c ~3339: pagerOpenWalIfPresent }
function pagerOpenWalIfPresent(pPager: PPager): i32;
var
  rc     : i32;
  isWal  : cint;
  nPage  : Pgno;
begin
  rc := SQLITE_OK;
  if pPager^.tempFile = 0 then
  begin
    isWal := 0;
    rc := sqlite3OsAccess(pPager^.pVfs, pPager^.zWal,
                          SQLITE_ACCESS_EXISTS, @isWal);
    if rc = SQLITE_OK then
    begin
      if isWal <> 0 then
      begin
        rc := pagerPagecount(pPager, @nPage);
        if rc = SQLITE_OK then
        begin
          if nPage = 0 then
            rc := sqlite3OsDelete(pPager^.pVfs, pPager^.zWal, 0)
          else
            rc := sqlite3PagerOpenWal(pPager, nil);
        end;
      end
      else if pPager^.journalMode = PAGER_JOURNALMODE_WAL then
        pPager^.journalMode := PAGER_JOURNALMODE_DELETE;
    end;
  end;
  Result := rc;
end;

{ pager.c ~3250: pagerBeginReadTransaction }
function pagerBeginReadTransaction(pPager: PPager): i32;
var
  rc      : i32;
  changed : cint;
begin
  sqlite3WalEndReadTransaction(pPager^.pWal);
  changed := 0;
  rc := sqlite3WalBeginReadTransaction(pPager^.pWal, @changed);
  if (rc <> SQLITE_OK) or (changed <> 0) then
    pager_reset(pPager);
  Result := rc;
end;

{ pager.c ~3098: pagerUndoCallback }
function pagerUndoCallback(pCtx: Pointer; pgno: Pgno): i32;
var
  pPgr : PPager;  { renamed: pPager conflicts with type PPager }
  pPg  : PPgHdr;
  rc   : i32;
begin
  rc := SQLITE_OK;
  pPgr := PPager(pCtx);
  pPg := sqlite3PagerLookup(pPgr, pgno);
  if pPg <> nil then
  begin
    if sqlite3PcachePageRefcount(pPg) = 1 then
      sqlite3PcacheDrop(pPg)
    else
    begin
      rc := readDbPage(pPg);
      if (rc = SQLITE_OK) and Assigned(pPgr^.xReiniter) then
        pPgr^.xReiniter(pPg);
      sqlite3PagerUnrefNotNull(pPg);
    end;
  end;
  Result := rc;
end;

{ pager.c ~3146: pagerRollbackWal }
function pagerRollbackWal(pPager: PPager): i32;
var
  rc    : i32;
  pList : PPgHdr;
begin
  pPager^.dbSize := pPager^.dbOrigSize;
  rc := sqlite3WalUndo(pPager^.pWal, @pagerUndoCallback, pPager);
  pList := sqlite3PcacheDirtyList(pPager^.pPCache);
  while (pList <> nil) and (rc = SQLITE_OK) do
  begin
    rc := pagerUndoCallback(pPager, pList^.pgno);
    pList := pList^.pDirty;
  end;
  Result := rc;
end;

{ pager.c ~3179: pagerWalFrames -- write dirty pages to WAL }
function pagerWalFrames(pPager: PPager; pList: PPgHdr; nTruncate: Pgno;
                        isCommit: i32): i32;
var
  rc      : i32;
  nList   : i32;
  p, pPrev: PPgHdr;
begin
  rc := SQLITE_OK;
  nList := 0;
  if isCommit <> 0 then
  begin
    { Remove pages with pgno > nTruncate from the dirty list }
    pPrev := nil;
    p := pList;
    while p <> nil do
    begin
      if p^.pgno <= nTruncate then
      begin
        pPrev := p;
        Inc(nList);
        p := p^.pDirty;
      end
      else
      begin
        if pPrev <> nil then
          pPrev^.pDirty := p^.pDirty
        else
          pList := p^.pDirty;
        p := p^.pDirty;
      end;
    end;
  end
  else
    nList := 1;

  Inc(pPager^.aStat[PAGER_STAT_WRITE], nList);

  if pList^.pgno = 1 then pager_write_changecounter(pList);
  rc := sqlite3WalFrames(pPager^.pWal, pPager^.pageSize, pList,
                         nTruncate, isCommit, pPager^.walSyncFlags);
  Result := rc;
end;

{ pager.c ~3021: readDbPage }
function readDbPage(pPg: PPgHdr): i32;
var
  pPgr    : PPager;  { renamed: pPager conflicts with type PPager (case-insensitive) }
  rc      : i32;
  iOffset : i64;
  pDbVers : Pu8;
  iFrame  : u32;
begin
  pPgr := pPg^.pPager;
  rc := SQLITE_OK;
  iFrame := 0;

  if pagerUseWal(pPgr) <> 0 then
  begin
    rc := sqlite3WalFindFrame(pPgr^.pWal, pPg^.pgno, @iFrame);
    if rc <> SQLITE_OK then Exit(rc);
    if iFrame <> 0 then
    begin
      rc := sqlite3WalReadFrame(pPgr^.pWal, iFrame, pPgr^.pageSize,
                                Pu8(pPg^.pData));
      { fall through to page-1 version-byte update below }
    end;
  end;
  if iFrame = 0 then
  begin
    iOffset := (pPg^.pgno - 1) * i64(pPgr^.pageSize);
    rc := sqlite3OsRead(pPgr^.fd, pPg^.pData, pPgr^.pageSize, iOffset);
    if rc = SQLITE_IOERR_SHORT_READ then rc := SQLITE_OK;
  end;

  if pPg^.pgno = 1 then
  begin
    if rc <> 0 then
      FillChar(pPgr^.dbFileVers, SizeOf(pPgr^.dbFileVers), $ff)
    else
    begin
      pDbVers := Pu8(pPg^.pData) + 24;
      Move(pDbVers^, pPgr^.dbFileVers, SizeOf(pPgr^.dbFileVers));
    end;
  end;
  Result := rc;
end;

{ pager.c ~5471: pagerUnlockIfUnused }
procedure pagerUnlockIfUnused(pPager: PPager);
begin
  if sqlite3PcacheRefCount(pPager^.pPCache) = 0 then
    pagerUnlockAndRollback(pPager);
end;

{ pager.c ~5535: getPageNormal }
function getPageNormal(pPager: PPager; pgno: Pgno; ppPage: PPDbPage; flags: i32): i32;
label pager_acquire_err;
var
  rc        : i32;
  pPg       : PPgHdr;
  noContent : u8;
  pBase     : Psqlite3_pcache_page;
begin
  rc := SQLITE_OK;
  if pgno = 0 then
  begin
    ppPage^ := nil;
    Result  := SQLITE_CORRUPT;
    Exit;
  end;

  pBase := sqlite3PcacheFetch(pPager^.pPCache, pgno, 3);
  if pBase = nil then
  begin
    pPg   := nil;
    rc    := sqlite3PcacheFetchStress(pPager^.pPCache, pgno, @pBase);
    if rc <> SQLITE_OK then goto pager_acquire_err;
    if pBase = nil then
    begin
      rc := SQLITE_NOMEM;
      goto pager_acquire_err;
    end;
  end;
  pPg := PPgHdr(sqlite3PcacheFetchFinish(pPager^.pPCache, pgno, pBase));
  ppPage^ := PDbPage(pPg);

  noContent := u8((flags and PAGER_GET_NOCONTENT) <> 0);

  if (pPg^.pPager <> nil) and (noContent = 0) then
  begin
    { cache hit }
    Inc(pPager^.aStat[PAGER_STAT_HIT]);
    Result := SQLITE_OK;
    Exit;
  end else
  begin
    { new page -- check locking page }
    if pgno = pPager^.lckPgno then
    begin
      rc := SQLITE_CORRUPT;
      goto pager_acquire_err;
    end;

    pPg^.pPager := pPager;

    if (isOpen(pPager^.fd) = 0) or (pPager^.dbSize < pgno) or (noContent <> 0) then
    begin
      if pgno > pPager^.mxPgno then
      begin
        rc := SQLITE_FULL;
        if pgno <= pPager^.dbSize then
        begin
          sqlite3PcacheRelease(pPg);
          pPg := nil;
        end;
        goto pager_acquire_err;
      end;
      FillChar(pPg^.pData^, pPager^.pageSize, 0);
    end else
    begin
      Inc(pPager^.aStat[PAGER_STAT_MISS]);
      rc := readDbPage(pPg);
      if rc <> SQLITE_OK then goto pager_acquire_err;
    end;
  end;
  Result := SQLITE_OK;
  Exit;

pager_acquire_err:
  if pPg <> nil then sqlite3PcacheDrop(pPg);
  pagerUnlockIfUnused(pPager);
  ppPage^ := nil;
  Result  := rc;
end;

{ pager.c ~5709: getPageError }
function getPageError(pPager: PPager; pgno: Pgno; ppPage: PPDbPage; flags: i32): i32;
begin
  if pgno = 0 then;
  if flags = 0 then;
  ppPage^ := nil;
  Result  := pPager^.errCode;
end;

{ ============================================================
  3.B.2a: sqlite3PagerSetFlags -- pager.c ~3612
  ============================================================ }
procedure sqlite3PagerSetFlags(pPager: PPager; pgFlags: u32);
var
  level: u32;
begin
  level := pgFlags and PAGER_SYNCHRONOUS_MASK;
  if (pPager^.tempFile <> 0) or (level = PAGER_SYNCHRONOUS_OFF) then
  begin
    pPager^.noSync    := 1;
    pPager^.fullSync  := 0;
    pPager^.extraSync := 0;
  end else
  begin
    pPager^.noSync   := 0;
    if level >= PAGER_SYNCHRONOUS_FULL then pPager^.fullSync := 1
    else pPager^.fullSync := 0;
    if level = PAGER_SYNCHRONOUS_EXTRA then pPager^.extraSync := 1
    else pPager^.extraSync := 0;
  end;
  if pPager^.noSync <> 0 then
    pPager^.syncFlags := 0
  else if (pgFlags and PAGER_FULLFSYNC) <> 0 then
    pPager^.syncFlags := SQLITE_SYNC_FULL
  else
    pPager^.syncFlags := SQLITE_SYNC_NORMAL;
  pPager^.walSyncFlags := (pPager^.syncFlags shl 2);
  if pPager^.fullSync <> 0 then
    pPager^.walSyncFlags := pPager^.walSyncFlags or pPager^.syncFlags;
  if ((pgFlags and PAGER_CKPT_FULLFSYNC) <> 0) and (pPager^.noSync = 0) then
    pPager^.walSyncFlags := pPager^.walSyncFlags or (SQLITE_SYNC_FULL shl 2);
  if (pgFlags and PAGER_CACHESPILL) <> 0 then
    pPager^.doNotSpill := pPager^.doNotSpill and not SPILLFLAG_OFF
  else
    pPager^.doNotSpill := pPager^.doNotSpill or SPILLFLAG_OFF;
end;

{ pager.c ~3767: sqlite3PagerSetPagesize }
function sqlite3PagerSetPagesize(pPager: PPager; pPageSize: Pu32; nReserve: i32): i32;
var
  rc      : i32;
  pageSize: u32;
  pNew    : PChar;
  nByte   : i64;
begin
  rc       := SQLITE_OK;
  pageSize := pPageSize^;
  if ((pPager^.memDb = 0) or (pPager^.dbSize = 0))
    and (sqlite3PcacheRefCount(pPager^.pPCache) = 0)
    and (pageSize <> 0) and (pageSize <> u32(pPager^.pageSize))
  then
  begin
    pNew  := nil;
    nByte := 0;
    if (pPager^.eState > PAGER_OPEN) and (isOpen(pPager^.fd) <> 0) then
      rc := sqlite3OsFileSize(pPager^.fd, @nByte);

    if rc = SQLITE_OK then
    begin
      pNew := PChar(sqlite3PageMalloc(pageSize + 8));
      if pNew = nil then
        rc := SQLITE_NOMEM
      else
        FillChar((pNew + pageSize)^, 8, 0);
    end;

    if rc = SQLITE_OK then
    begin
      pager_reset(pPager);
      rc := sqlite3PcacheSetPageSize(pPager^.pPCache, pageSize);
    end;
    if rc = SQLITE_OK then
    begin
      sqlite3PageFree(pPager^.pTmpSpace);
      pPager^.pTmpSpace := pNew;
      pPager^.dbSize    := Pgno((nByte + pageSize - 1) div pageSize);
      pPager^.pageSize  := pageSize;
      pPager^.lckPgno   := Pgno(PENDING_BYTE div pageSize) + 1;
    end else
      sqlite3PageFree(pNew);
  end;

  pPageSize^ := pPager^.pageSize;
  if rc = SQLITE_OK then
  begin
    if nReserve < 0 then nReserve := pPager^.nReserve;
    pPager^.nReserve := i16(nReserve);
    pagerFixMaplimit(pPager);
  end;
  Result := rc;
end;

{ pager.c ~3518: sqlite3PagerSetCachesize }
procedure sqlite3PagerSetCachesize(pPager: PPager; mxPage: i32);
begin
  sqlite3PcacheSetCachesize(pPager^.pPCache, mxPage);
end;

{ pager.c:3526 — sqlite3PagerSetSpillsize. }
function sqlite3PagerSetSpillsize(pPager: PPager; mxPage: i32): i32;
begin
  Result := sqlite3PcacheSetSpillsize(pPager^.pPCache, mxPage);
end;

{ pager.c:3549 — sqlite3PagerSetMmapLimit. }
procedure sqlite3PagerSetMmapLimit(pPager: PPager; szMmap: i64);
begin
  pPager^.szMmap := szMmap;
  pagerFixMaplimit(pPager);
end;

{ pager.c:3557 — sqlite3PagerShrink. }
procedure sqlite3PagerShrink(pPager: PPager);
begin
  sqlite3PcacheShrink(pPager^.pPCache);
end;

{ pager.c:3836 — sqlite3PagerTempSpace.  Returns the page-sized scratch
  buffer allocated alongside the pager; used by btree.c freelist code. }
function sqlite3PagerTempSpace(pPager: PPager): Pointer;
begin
  Result := pPager^.pTmpSpace;
end;

{ pager.c:4239 — sqlite3PagerPagenumber. }
function sqlite3PagerPagenumber(pPg: PDbPage): Pgno;
begin
  Result := PPgHdr(pPg)^.pgno;
end;

{ pager.c:6258 — sqlite3PagerIswriteable. }
function sqlite3PagerIswriteable(pPg: PDbPage): i32;
begin
  Result := i32(PPgHdr(pPg)^.flags and PGHDR_WRITEABLE);
end;

{ pager.c:6826 — sqlite3PagerRefcount (SQLITE_DEBUG only in C; exposed
  unconditionally here since the Pas port has no SQLITE_DEBUG gate). }
function sqlite3PagerRefcount(pPager: PPager): i32;
begin
  Result := i32(sqlite3PcacheRefCount(pPager^.pPCache));
end;

{ pager.c:6846 — sqlite3PagerPageRefcount. }
function sqlite3PagerPageRefcount(pPg: PDbPage): i32;
begin
  Result := i32(sqlite3PcachePageRefcount(PPgHdr(pPg)));
end;

{ pager.c ~3723: sqlite3PagerSetBusyHandler }
procedure sqlite3PagerSetBusyHandler(pPager: PPager;
  xBusy: TBusyHandler; pArg: Pointer);
begin
  pPager^.xBusyHandler    := xBusy;
  pPager^.pBusyHandlerArg := pArg;
  sqlite3OsFileControlHint(pPager^.fd, SQLITE_FCNTL_BUSYHANDLER, @pPager^.xBusyHandler);
end;

{ pager.c ~3847: sqlite3PagerMaxPageCount }
function sqlite3PagerMaxPageCount(pPager: PPager; mxPage: Pgno): Pgno;
begin
  if mxPage > 0 then pPager^.mxPgno := mxPage;
  Result := pPager^.mxPgno;
end;

{ pager.c ~3331: sqlite3PagerLockingMode }
function sqlite3PagerLockingMode(pPager: PPager; eMode: i32): i32;
begin
  if (eMode >= 0) and (pPager^.tempFile = 0)
  and (sqlite3WalHeapMemory(pPager^.pWal) = 0) then
    pPager^.exclusiveMode := u8(eMode);
  Result := pPager^.exclusiveMode;
end;

{ pager.c ~4735: sqlite3PagerOpen }
function sqlite3PagerOpen(pVfs: Psqlite3_vfs; out ppPager: PPager;
  zFilename: PChar; nExtra: i32; flags: i32; vfsFlags: i32;
  xReinit: TDbPageReinit): i32;
label act_like_temp_file;
var
  pPtr           : Pu8;
  pPgr           : PPager;  { renamed: pPager conflicts with type PPager (case-insensitive) }
  rc             : i32;
  tempFile       : i32;
  memDb          : i32;
  memJM          : i32;
  readOnly       : i32;
  journalFileSize: i32;
  zPathname      : PChar;
  nPathname      : i32;
  useJournal     : i32;
  pcacheSize     : i32;
  szPageDflt     : u32;
  zUri           : PChar;
  nUriByte       : i32;
  fout           : i32;
  iDc            : i32;
  z              : PChar;
  nTotal         : SizeInt;
  pPgrBack       : PPager;
begin
  ppPager        := nil;
  rc             := SQLITE_OK;
  tempFile       := 0;
  memDb          := 0;
  memJM          := 0;
  readOnly       := 0;
  zPathname      := nil;
  nPathname      := 0;
  useJournal     := i32((flags and PAGER_OMIT_JOURNAL) = 0);
  pcacheSize     := sqlite3PcacheSize;
  szPageDflt     := SQLITE_DEFAULT_PAGE_SIZE;
  zUri           := nil;
  nUriByte       := 1;

  journalFileSize := ROUND8(sqlite3JournalSize(pVfs));

  { Handle PAGER_MEMORY flag — also recognise the literal ":memory:"
    filename so we don't fall through to the unix VFS and open a real
    on-disk file by that name (mirrors the higher-level :memory:
    detection in C openDatabase). }
  if Assigned(zFilename) and (zFilename[0] = ':')
     and (StrComp(zFilename, ':memory:') = 0) then
  begin
    flags := flags or PAGER_MEMORY;
    zFilename := nil;
  end;
  if (flags and PAGER_MEMORY) <> 0 then
  begin
    memDb := 1;
    if Assigned(zFilename) and (zFilename[0] <> #0) then
    begin
      nPathname := sqlite3Strlen30(zFilename);
      zPathname  := PChar(sqlite3_malloc(nPathname + 1));
      if zPathname = nil then
      begin
        Result := SQLITE_NOMEM;
        Exit;
      end;
      Move(zFilename^, zPathname^, nPathname + 1);
      zFilename := nil;
    end;
  end;

  { Compute full path }
  if Assigned(zFilename) and (zFilename[0] <> #0) then
  begin
    nPathname := pVfs^.mxPathname + 1;
    zPathname  := PChar(sqlite3_malloc(2 * nPathname));
    if zPathname = nil then
    begin
      Result := SQLITE_NOMEM;
      Exit;
    end;
    zPathname[0] := #0;
    rc := sqlite3OsFullPathname(pVfs, zFilename, nPathname, zPathname);
    if rc = SQLITE_OK_SYMLINK then
    begin
      if (vfsFlags and SQLITE_OPEN_NOFOLLOW) <> 0 then
        rc := SQLITE_CANTOPEN
      else
        rc := SQLITE_OK;
    end;
    nPathname := sqlite3Strlen30(zPathname);
    z := zUri;
    z := PChar(PByte(zFilename) + sqlite3Strlen30(zFilename) + 1);
    zUri := z;
    while z^ <> #0 do
    begin
      z := PChar(PByte(z) + StrLen(z) + 1);
      z := PChar(PByte(z) + StrLen(z) + 1);
    end;
    nUriByte := i32(PByte(z) + 1 - PByte(zUri));
    if nUriByte < 1 then nUriByte := 1;
    if (rc = SQLITE_OK) and (nPathname + 8 > pVfs^.mxPathname) then
      rc := SQLITE_CANTOPEN;
    if rc <> SQLITE_OK then
    begin
      sqlite3_free(zPathname);
      Result := rc;
      Exit;
    end;
  end;

  { Compute allocation size:
      Pager + PCache + fd + sjfd + jfd + Pager* + 4 + filename + uri +
      journal + wal + terminator }
  nTotal := ROUND8(SizeOf(Pager))
          + ROUND8(pcacheSize)
          + ROUND8(pVfs^.szOsFile)
          + journalFileSize * 2
          + SQLITE_PTRSIZE
          + 4
          + nPathname + 1
          + nUriByte
          + nPathname + 8 + 1
          + nPathname + 4 + 1
          + 3;

  pPtr := Pu8(sqlite3MallocZero(nTotal));
  if pPtr = nil then
  begin
    sqlite3_free(zPathname);
    Result := SQLITE_NOMEM;
    Exit;
  end;

  pPgr := PPager(pPtr);                Inc(pPtr, ROUND8(SizeOf(Pager)));
  pPgr^.pPCache := PPCache(pPtr);      Inc(pPtr, ROUND8(pcacheSize));
  pPgr^.fd      := Psqlite3_file(pPtr);Inc(pPtr, ROUND8(pVfs^.szOsFile));
  pPgr^.sjfd    := Psqlite3_file(pPtr);Inc(pPtr, journalFileSize);
  pPgr^.jfd     := Psqlite3_file(pPtr);Inc(pPtr, journalFileSize);
  { Store back-pointer }
  pPgrBack := pPgr;
  Move(pPgrBack, pPtr^, SQLITE_PTRSIZE); Inc(pPtr, SQLITE_PTRSIZE);

  { Skip 4-byte zero prefix, then store filename }
  Inc(pPtr, 4);
  pPgr^.zFilename := PChar(pPtr);
  if nPathname > 0 then
  begin
    Move(zPathname^, pPtr^, nPathname);
    Inc(pPtr, nPathname + 1);
    if Assigned(zUri) then
    begin
      Move(zUri^, pPtr^, nUriByte);
      Inc(pPtr, nUriByte);
    end else
      Inc(pPtr);
  end;

  { Journal filename }
  if nPathname > 0 then
  begin
    pPgr^.zJournal := PChar(pPtr);
    Move(zPathname^, pPtr^, nPathname);  Inc(pPtr, nPathname);
    Move('-journal'[1], pPtr^, 8);       Inc(pPtr, 8 + 1);
  end else
    pPgr^.zJournal := nil;

  { WAL filename }
  if nPathname > 0 then
  begin
    pPgr^.zWal := PChar(pPtr);
    Move(zPathname^, pPtr^, nPathname);  Inc(pPtr, nPathname);
    Move('-wal'[1], pPtr^, 4);           Inc(pPtr, 4 + 1);
  end else
    pPgr^.zWal := nil;

  if nPathname > 0 then sqlite3_free(zPathname);
  pPgr^.pVfs    := pVfs;
  pPgr^.vfsFlags := u32(vfsFlags);

  { Open the database file }
  if Assigned(zFilename) and (zFilename[0] <> #0) then
  begin
    fout := 0;
    rc   := sqlite3OsOpen(pVfs, pPgr^.zFilename, pPgr^.fd, vfsFlags, @fout);
    pPgr^.memVfs := u8((fout and SQLITE_OPEN_MEMORY) <> 0);
    memJM    := i32((fout and SQLITE_OPEN_MEMORY) <> 0);
    readOnly := i32((fout and SQLITE_OPEN_READONLY) <> 0);

    if rc = SQLITE_OK then
    begin
      iDc := sqlite3OsDeviceCharacteristics(pPgr^.fd);
      if readOnly = 0 then
      begin
        setSectorSize(pPgr);
        if szPageDflt < pPgr^.sectorSize then
        begin
          if pPgr^.sectorSize > SQLITE_MAX_DEFAULT_PAGE_SIZE then
            szPageDflt := SQLITE_MAX_DEFAULT_PAGE_SIZE
          else
            szPageDflt := pPgr^.sectorSize;
        end;
      end;
      if sqlite3_uri_boolean(pPgr^.zFilename, 'nolock', 0) <> 0 then
        pPgr^.noLock := 1;
      if ((iDc and SQLITE_IOCAP_IMMUTABLE) <> 0)
        or (sqlite3_uri_boolean(pPgr^.zFilename, 'immutable', 0) <> 0)
      then
      begin
        vfsFlags := vfsFlags or SQLITE_OPEN_READONLY;
        goto act_like_temp_file;
      end;
    end;
  end else
  begin
act_like_temp_file:
    tempFile             := 1;
    pPgr^.eState       := PAGER_READER;
    pPgr^.eLock        := EXCLUSIVE_LOCK;
    pPgr^.noLock       := 1;
    readOnly             := i32((vfsFlags and SQLITE_OPEN_READONLY) <> 0);
  end;

  { Set page size and allocate tmp space }
  if rc = SQLITE_OK then
    rc := sqlite3PagerSetPagesize(pPgr, @szPageDflt, -1);

  { Init PCache }
  if rc = SQLITE_OK then
  begin
    nExtra := ROUND8(nExtra);
    if memDb <> 0 then
      rc := sqlite3PcacheOpen(szPageDflt, nExtra, 0, nil, pPgr, pPgr^.pPCache)
    else
      rc := sqlite3PcacheOpen(szPageDflt, nExtra, 1, @pagerStress, pPgr, pPgr^.pPCache);
  end;

  if rc <> SQLITE_OK then
  begin
    sqlite3OsClose(pPgr^.fd);
    sqlite3PageFree(pPgr^.pTmpSpace);
    sqlite3_free(pPgr);
    Result := rc;
    Exit;
  end;

  pPgr^.useJournal    := u8(useJournal);
  pPgr^.mxPgno        := SQLITE_MAX_PAGE_COUNT;
  pPgr^.tempFile      := u8(tempFile);
  pPgr^.exclusiveMode := u8(tempFile);
  if tempFile <> 0 then
    pPgr^.changeCountDone := 1
  else
    pPgr^.changeCountDone := 0;
  pPgr^.memDb         := u8(memDb);
  pPgr^.readOnly      := u8(readOnly);
  sqlite3PagerSetFlags(pPgr, (SQLITE_DEFAULT_SYNCHRONOUS + 1) or PAGER_CACHESPILL);
  pPgr^.nExtra        := u16(nExtra);
  pPgr^.journalSizeLimit := SQLITE_DEFAULT_JOURNAL_SIZE_LIMIT;
  setSectorSize(pPgr);
  if useJournal = 0 then
    pPgr^.journalMode := PAGER_JOURNALMODE_OFF
  else if (memDb <> 0) or (memJM <> 0) then
    pPgr^.journalMode := PAGER_JOURNALMODE_MEMORY;
  pPgr^.xReiniter := xReinit;
  setGetterMethod(pPgr);

  ppPager := pPgr;
  Result  := SQLITE_OK;
end;

{ pager.c ~4176: sqlite3PagerClose }
function sqlite3PagerClose(pPager: PPager; db: Pointer): i32;
begin
  if db = nil then;
  pagerFreeMapHdrs(pPager);
  pPager^.exclusiveMode := 0;
  if pPager^.pWal <> nil then
  begin
    sqlite3WalClose(pPager^.pWal, db, pPager^.walSyncFlags,
                    pPager^.pageSize, Pu8(pPager^.pTmpSpace));
    pPager^.pWal := nil;
  end;
  pager_reset(pPager);
  if pPager^.memDb <> 0 then
    pager_unlock(pPager)
  else
  begin
    if isOpen(pPager^.jfd) <> 0 then
      pagerSetError(pPager, pagerSyncHotJournal(pPager));
    pagerUnlockAndRollback(pPager);
  end;
  sqlite3OsClose(pPager^.jfd);
  sqlite3OsClose(pPager^.fd);
  sqlite3PageFree(pPager^.pTmpSpace);
  sqlite3PcacheClose(pPager^.pPCache);
  sqlite3_free(pPager);
  Result := SQLITE_OK;
end;

{ Helper used by sqlite3PagerClose }
function pagerSyncHotJournal(pPager: PPager): i32;
var
  rc: i32;
begin
  rc := SQLITE_OK;
  if pPager^.noSync = 0 then
    rc := sqlite3OsSync(pPager^.jfd, SQLITE_SYNC_NORMAL);
  if rc = SQLITE_OK then
    rc := sqlite3OsFileSize(pPager^.jfd, @pPager^.journalHdr);
  Result := rc;
end;

{ pager.c ~4682: pagerStress -- spill dirty pages to disk (Phase 3.B.2b full impl) }
function pagerStress(p: Pointer; pPg: PPgHdr): i32;
var
  pPgr: PPager;  { renamed: pPager conflicts with type PPager (case-insensitive) }
  rc: i32;
begin
  pPgr := PPager(p);
  rc := SQLITE_OK;
  if pPgr^.errCode <> 0 then begin Result := SQLITE_OK; Exit; end;
  if (pPgr^.doNotSpill and (SPILLFLAG_ROLLBACK or SPILLFLAG_OFF)) <> 0 then
    begin Result := SQLITE_OK; Exit; end;
  if (pPgr^.doNotSpill <> 0) and ((pPg^.flags and PGHDR_NEED_SYNC) <> 0) then
    begin Result := SQLITE_OK; Exit; end;

  Inc(pPgr^.aStat[PAGER_STAT_SPILL]);
  pPg^.pDirty := nil;

  { Rollback journal write path }
  if (pPg^.flags and PGHDR_NEED_SYNC) <> 0 then
    rc := syncJournal(pPgr, 1);
  if rc = SQLITE_OK then
    rc := pager_write_pagelist(pPgr, pPg);
  if rc = SQLITE_OK then
    sqlite3PcacheMakeClean(pPg);
  Result := pagerSetError(pPgr, rc);
end;

{ pager.c ~4128: pagerFreeMapHdrs }
procedure pagerFreeMapHdrs(pPager: PPager);
var
  p, pNext: PPgHdr;
begin
  p := pPager^.pMmapFreelist;
  while p <> nil do
  begin
    pNext := p^.pDirty;
    sqlite3_free(p);
    p := pNext;
  end;
end;

{ pager.c ~3897: sqlite3PagerReadFileheader }
function sqlite3PagerReadFileheader(pPager: PPager; N: i32; pDest: Pu8): i32;
var
  rc: i32;
begin
  rc := SQLITE_OK;
  FillChar(pDest^, N, 0);
  if isOpen(pPager^.fd) <> 0 then
  begin
    rc := sqlite3OsRead(pPager^.fd, pDest, N, 0);
    if rc = SQLITE_IOERR_SHORT_READ then rc := SQLITE_OK;
  end;
  Result := rc;
end;

{ pager.c ~3925: sqlite3PagerPagecount }
procedure sqlite3PagerPagecount(pPager: PPager; pnPage: Pi32);
begin
  pnPage^ := i32(pPager^.dbSize);
end;

{ pager.c ~5254: sqlite3PagerSharedLock }
function sqlite3PagerSharedLock(pPager: PPager): i32;
label failed;
var
  rc           : i32;
  bHotJournal  : i32;
  dbFileVers   : array[0..15] of AnsiChar;
  pVfs2        : Psqlite3_vfs;
  bExists      : i32;
  fout2        : i32;
  f2           : i32;
begin
  rc := SQLITE_OK;

  if (pPager^.pWal = nil) and (pPager^.eState = PAGER_OPEN) then
  begin
    bHotJournal := 1;

    rc := pager_wait_on_lock(pPager, SHARED_LOCK);
    if rc <> SQLITE_OK then goto failed;

    if pPager^.eLock <= SHARED_LOCK then
      rc := hasHotJournal(pPager, @bHotJournal);
    if rc <> SQLITE_OK then goto failed;

    if bHotJournal <> 0 then
    begin
      if pPager^.readOnly <> 0 then
      begin
        rc := SQLITE_READONLY_ROLLBACK;
        goto failed;
      end;
      rc := pagerLockDb(pPager, EXCLUSIVE_LOCK);
      if rc <> SQLITE_OK then goto failed;

      if (isOpen(pPager^.jfd) = 0) and (pPager^.journalMode <> PAGER_JOURNALMODE_OFF) then
      begin
        pVfs2   := pPager^.pVfs;
        bExists := 0;
        fout2   := 0;
        rc := sqlite3OsAccess(pVfs2, pPager^.zJournal, SQLITE_ACCESS_EXISTS, @bExists);
        if (rc = SQLITE_OK) and (bExists <> 0) then
        begin
          f2 := SQLITE_OPEN_READWRITE or SQLITE_OPEN_MAIN_JOURNAL;
          rc := sqlite3OsOpen(pVfs2, pPager^.zJournal, pPager^.jfd, f2, @fout2);
          if (rc = SQLITE_OK) and ((fout2 and SQLITE_OPEN_READONLY) <> 0) then
          begin
            rc := SQLITE_CANTOPEN;
            sqlite3OsClose(pPager^.jfd);
          end;
        end;
      end;

      if isOpen(pPager^.jfd) <> 0 then
      begin
        rc := pagerSyncHotJournal(pPager);
        if rc = SQLITE_OK then
        begin
          rc := pager_playback(pPager, i32(pPager^.tempFile = 0));
          pPager^.eState := PAGER_OPEN;
        end;
      end else if pPager^.exclusiveMode = 0 then
        pagerUnlockDb(pPager, SHARED_LOCK);

      if rc <> SQLITE_OK then
      begin
        pagerSetError(pPager, rc);
        goto failed;
      end;
    end;

    if (pPager^.tempFile = 0) and (pPager^.hasHeldSharedLock <> 0) then
    begin
      rc := sqlite3OsRead(pPager^.fd, @dbFileVers, SizeOf(dbFileVers), 24);
      if rc <> SQLITE_OK then
      begin
        if rc <> SQLITE_IOERR_SHORT_READ then goto failed;
        FillChar(dbFileVers, SizeOf(dbFileVers), 0);
      end;
      if CompareMem(@pPager^.dbFileVers, @dbFileVers, SizeOf(dbFileVers)) <> True then
        pager_reset(pPager);
    end;

    rc := pagerOpenWalIfPresent(pPager);
  end;

  if (rc = SQLITE_OK) and (pagerUseWal(pPager) <> 0) then
    rc := pagerBeginReadTransaction(pPager);

  if (pPager^.tempFile = 0) and (pPager^.eState = PAGER_OPEN) and (rc = SQLITE_OK) then
    rc := pagerPagecount(pPager, @pPager^.dbSize);

failed:
  if rc <> SQLITE_OK then
  begin
    pager_unlock(pPager);
  end else
  begin
    pPager^.eState := PAGER_READER;
    pPager^.hasHeldSharedLock := 1;
  end;
  Result := rc;
end;

{ pager.c ~5726: sqlite3PagerGet }
function sqlite3PagerGet(pPager: PPager; pgno: Pgno; ppPage: PPDbPage;
  flags: i32): i32;
begin
  ppPage^ := nil;
  Result := pPager^.xGet(pPager, pgno, ppPage, flags);
end;

{ pager.c ~5759: sqlite3PagerLookup }
function sqlite3PagerLookup(pPager: PPager; pgno: Pgno): PDbPage;
var
  pPage: Psqlite3_pcache_page;
begin
  pPage := sqlite3PcacheFetch(pPager^.pPCache, pgno, 0);
  if pPage = nil then begin Result := nil; Exit; end;
  Result := PDbPage(sqlite3PcacheFetchFinish(pPager^.pPCache, pgno, pPage));
end;

{ pager.c ~5247: sqlite3PagerRef }
procedure sqlite3PagerRef(pPg: PDbPage);
begin
  sqlite3PcacheRef(PPgHdr(pPg));
end;

{ pager.c ~5784: sqlite3PagerUnrefNotNull }
procedure sqlite3PagerUnrefNotNull(pPg: PDbPage);
begin
  if (PPgHdr(pPg)^.flags and PGHDR_MMAP) <> 0 then
    pagerReleaseMapPage(PPgHdr(pPg))
  else
    sqlite3PcacheRelease(PPgHdr(pPg));
end;

{ pager.c ~5796: sqlite3PagerUnref }
procedure sqlite3PagerUnref(pPg: PDbPage);
begin
  if pPg <> nil then sqlite3PagerUnrefNotNull(pPg);
end;

{ pager.c ~5799: sqlite3PagerUnrefPageOne }
procedure sqlite3PagerUnrefPageOne(pPg: PDbPage);
var
  pPgr: PPager;  { renamed: pPager conflicts with type PPager (case-insensitive) }
begin
  pPgr := PPgHdr(pPg)^.pPager;
  sqlite3PcacheRelease(PPgHdr(pPg));
  pagerUnlockIfUnused(pPgr);
end;

{ pager.c: accessors }
function sqlite3PagerGetData(pPg: PDbPage): Pointer;
begin
  Result := PPgHdr(pPg)^.pData;
end;

function sqlite3PagerGetExtra(pPg: PDbPage): Pointer;
begin
  Result := PPgHdr(pPg)^.pExtra;
end;

function sqlite3PagerIsreadonly(pPager: PPager): u8;
begin
  Result := pPager^.readOnly;
end;

function sqlite3PagerIsMemdb(pPager: PPager): i32;
begin
  if pPager^.memDb <> 0 then Result := 1 else Result := 0;
end;

{ pager.c:7088 — sqlite3PagerFilename.  When nullIfMemDb is set, memory
  / temp dbs report a static empty string (NOT NULL); callers such as
  sqlite3_db_filename use that empty-string convention to distinguish
  "no schema" (NULL) from "memory schema" (""). }
function sqlite3PagerFilename(pPager: PPager; nullIfMemDb: i32): PChar;
const zFake: array[0..0] of AnsiChar = (#0);
begin
  if (nullIfMemDb <> 0) and (pPager^.tempFile <> 0) then
    Result := PChar(@zFake[0])
  else
    Result := pPager^.zFilename;
end;

function sqlite3PagerVfs(pPager: PPager): Psqlite3_vfs;
begin
  Result := pPager^.pVfs;
end;

function sqlite3PagerFile(pPager: PPager): Psqlite3_file;
begin
  Result := pPager^.fd;
end;

function sqlite3PagerJrnlFile(pPager: PPager): Psqlite3_file;
begin
  Result := pPager^.jfd;
end;

{ pager.c:5090 — sqlite3_database_file_object. }
function sqlite3_database_file_object(zName: PChar): Psqlite3_file; cdecl;
var
  pPgr  : PPager;
  pBack : Pu8;
  pName : PChar;
begin
  pName := zName;
  while (pName[-1] <> #0) or (pName[-2] <> #0) or
        (pName[-3] <> #0) or (pName[-4] <> #0) do
    Dec(pName);
  pBack := Pu8(pName) - 4 - SQLITE_PTRSIZE;
  Move(pBack^, pPgr, SQLITE_PTRSIZE);
  Result := pPgr^.fd;
end;

{ pager.c: pagerReleaseMapPage stub (mmap pages) }
procedure pagerReleaseMapPage(pPg: PPgHdr);
var
  pPgr: PPager;  { renamed: pPager conflicts with type PPager (case-insensitive) }
begin
  pPgr := pPg^.pPager;
  Dec(pPgr^.nMmapOut);
  pPg^.pDirty := pPgr^.pMmapFreelist;
  pPgr^.pMmapFreelist := pPg;
  sqlite3OsUnfetch(pPgr^.fd, i64(pPg^.pgno - 1) * pPgr^.pageSize, pPg^.pData);
end;

{ ============================================================
  3.B.2b Implementation: rollback journaling write path
  ============================================================ }

{ sqlite3Realloc: thin wrapper matching C sqlite3Realloc semantics }
function sqlite3Realloc(p: Pointer; n: NativeUInt): Pointer;
begin
  if n = 0 then begin sqlite3_free(p); Result := nil; Exit; end;
  Result := sqlite3_realloc(p, i32(n));
end;

{ pager.c: readSuperJournal -- read super-journal name from end of journal }
function readSuperJournal(pJrnl: Psqlite3_file; zSuper: PChar; nSuper: i64): i32;
var
  rc: i32;
  len: u32;
  szJ: i64;
  cksum: u32;
  u: u32;
  aMagic: array[0..7] of u8;
begin
  zSuper[0] := #0;
  szJ := 0;
  rc := sqlite3OsFileSize(pJrnl, @szJ);
  if (rc <> SQLITE_OK) or (szJ < 16) then Exit(rc);
  rc := read32bits(pJrnl, szJ - 16, @len);
  if rc <> SQLITE_OK then Exit(rc);
  if (len >= u32(nSuper)) or (i64(len) > szJ - 16) or (len = 0) then Exit(SQLITE_OK);
  rc := read32bits(pJrnl, szJ - 12, @cksum);
  if rc <> SQLITE_OK then Exit(rc);
  rc := sqlite3OsRead(pJrnl, @aMagic[0], 8, szJ - 8);
  if rc <> SQLITE_OK then Exit(rc);
  if CompareByte(aMagic[0], aJournalMagic[0], 8) <> 0 then Exit(SQLITE_OK);
  rc := sqlite3OsRead(pJrnl, zSuper, i32(len), szJ - 16 - i64(len));
  if rc <> SQLITE_OK then Exit(rc);
  u := 0;
  while u < len do
  begin
    cksum -= u32(Byte(zSuper[u]));
    Inc(u);
  end;
  if cksum <> 0 then len := 0;
  zSuper[len]     := #0;
  zSuper[len + 1] := #0;
  Result := SQLITE_OK;
end;

{ Inline helpers ported from pager.c macros }

function JOURNAL_PG_SZ(pPager: PPager): i64; inline;
begin
  Result := pPager^.pageSize + 8;
end;

function JOURNAL_HDR_SZ(pPager: PPager): i64; inline;
begin
  Result := pPager^.sectorSize;
end;

{ pager.c ~829: pagerUseWal }
function pagerUseWal(pPager: PPager): i32; inline;
begin
  if pPager^.pWal <> nil then Result := 1 else Result := 0;
end;

{ pager.c ~1099: read32bits }
function read32bits(fd: Psqlite3_file; offset: i64; pRes: Pu32): i32;
var
  ac: array[0..3] of u8;
  rc: i32;
begin
  rc := sqlite3OsRead(fd, @ac[0], 4, offset);
  if rc = SQLITE_OK then
    pRes^ := sqlite3Get4byte(@ac[0]);
  Result := rc;
end;

{ pager.c ~1118: write32bits }
function write32bits(fd: Psqlite3_file; offset: i64; val: u32): i32;
var
  ac: array[0..3] of u8;
begin
  sqlite3Put4byte(@ac[0], val);
  Result := sqlite3OsWrite(fd, @ac[0], 4, offset);
end;

{ pager.c ~1355: journalHdrOffset -- next sector-aligned journal header offset }
function journalHdrOffset(pPager: PPager): i64;
var
  c: i64;
begin
  c := pPager^.journalOff;
  if c <> 0 then
    Result := ((c - 1) div JOURNAL_HDR_SZ(pPager) + 1) * JOURNAL_HDR_SZ(pPager)
  else
    Result := 0;
end;

{ pager.c ~1194: jrnlBufferSize -- 0 for our build (no ATOMIC_WRITE) }
function jrnlBufferSize(pPager: PPager): i32;
begin
  Result := 0;
  if pPager = nil then;
end;

{ pager.c ~1981: pagerFlushOnCommit }
function pagerFlushOnCommit(pPager: PPager; bCommit: i32): i32;
begin
  if pPager^.tempFile = 0 then begin Result := 1; Exit; end;
  if bCommit = 0 then begin Result := 0; Exit; end;
  if isOpen(pPager^.fd) = 0 then begin Result := 0; Exit; end;
  Result := i32(sqlite3PCachePercentDirty(pPager^.pPCache) >= 25);
end;

{ pager.c ~2240: pager_cksum }
function pager_cksum(pPager: PPager; aData: Pu8): u32;
var
  cksum: u32;
  i: i32;
begin
  cksum := pPager^.cksumInit;
  i := i32(pPager^.pageSize) - 200;
  while i > 0 do
  begin
    cksum += (aData + i)^;
    Dec(i, 200);
  end;
  Result := cksum;
end;

{ pager.c ~3084: pager_write_changecounter }
procedure pager_write_changecounter(pPg: PPgHdr);
var
  change_counter: u32;
  pData: Pu8;
  pPgr: PPager;
begin
  if pPg = nil then Exit;
  pData := Pu8(pPg^.pData);
  pPgr := pPg^.pPager;
  change_counter := sqlite3Get4byte(Pu8(Pointer(@pPgr^.dbFileVers))) + 1;
  sqlite3Put4byte(pData + 24, change_counter);
  sqlite3Put4byte(pData + 92, change_counter);
  sqlite3Put4byte(pData + 96, SQLITE_VERSION_NUMBER);
end;

{ pager.c ~1066: subjRequiresPage }
function subjRequiresPage(pPg: PPgHdr): i32;
var
  pPgr: PPager;
  pSP: PPagerSavepoint;
  pg: u32;
  i: i32;
begin
  pPgr := pPg^.pPager;
  pg := pPg^.pgno;
  i := 0;
  while i < pPgr^.nSavepoint do
  begin
    pSP := PPagerSavepoint(PByte(pPgr^.aSavepoint) + i * SizeOf(PagerSavepoint));
    if (pSP^.nOrig >= pg) and
       (sqlite3BitvecTestNotNull(pSP^.pInSavepoint, pg) = 0) then
    begin
      Inc(i);
      while i < pPgr^.nSavepoint do
      begin
        PPagerSavepoint(PByte(pPgr^.aSavepoint) + i * SizeOf(PagerSavepoint))^.bTruncateOnRelease := 0;
        Inc(i);
      end;
      Result := 1;
      Exit;
    end;
    Inc(i);
  end;
  Result := 0;
end;

{ pager.c ~4142: databaseIsUnmoved }
function databaseIsUnmoved(pPager: PPager): i32;
var
  bHasMoved: i32;
  rc: i32;
begin
  if pPager^.tempFile <> 0 then begin Result := SQLITE_OK; Exit; end;
  if pPager^.dbSize = 0 then begin Result := SQLITE_OK; Exit; end;
  bHasMoved := 0;
  rc := sqlite3OsFileControl(pPager^.fd, SQLITE_FCNTL_HAS_MOVED, @bHasMoved);
  if rc = SQLITE_NOTFOUND then
    rc := SQLITE_OK
  else if (rc = SQLITE_OK) and (bHasMoved <> 0) then
    rc := SQLITE_READONLY_DBMOVED;
  Result := rc;
end;

{ pager.c ~1388: zeroJournalHdr -- invalidate journal header on commit }
function zeroJournalHdr(pPager: PPager; doTruncate: i32): i32;
const
  zeroHdr: array[0..27] of AnsiChar = (
    #0,#0,#0,#0,#0,#0,#0,#0,#0,#0,#0,#0,#0,#0,
    #0,#0,#0,#0,#0,#0,#0,#0,#0,#0,#0,#0,#0,#0);
var
  rc: i32;
  iLimit: i64;
  sz: i64;
begin
  rc := SQLITE_OK;
  if pPager^.journalOff <> 0 then
  begin
    iLimit := pPager^.journalSizeLimit;
    if (doTruncate <> 0) or (iLimit = 0) then
      rc := sqlite3OsTruncate(pPager^.jfd, 0)
    else
      rc := sqlite3OsWrite(pPager^.jfd, @zeroHdr[0], 28, 0);
    if (rc = SQLITE_OK) and (pPager^.noSync = 0) then
      rc := sqlite3OsSync(pPager^.jfd, SQLITE_SYNC_DATAONLY or pPager^.syncFlags);
    if (rc = SQLITE_OK) and (iLimit > 0) then
    begin
      sz := 0;
      rc := sqlite3OsFileSize(pPager^.jfd, @sz);
      if (rc = SQLITE_OK) and (sz > iLimit) then
        rc := sqlite3OsTruncate(pPager^.jfd, iLimit);
    end;
  end;
  Result := rc;
end;

{ pager.c ~1438: writeJournalHdr -- write journal header at current offset }
function writeJournalHdr(pPager: PPager): i32;
var
  rc: i32;
  zHeader: PChar;
  nHeader: u32;
  nWrite: u32;
  ii: i32;
  iDc: i32;
  tmp32: u32;
begin
  rc := SQLITE_OK;
  zHeader := pPager^.pTmpSpace;
  nHeader := u32(pPager^.pageSize);
  if nHeader > u32(JOURNAL_HDR_SZ(pPager)) then
    nHeader := u32(JOURNAL_HDR_SZ(pPager));

  { Update savepoint iHdrOffset fields }
  ii := 0;
  while ii < pPager^.nSavepoint do
  begin
    if PPagerSavepoint(PByte(pPager^.aSavepoint) + ii * SizeOf(PagerSavepoint))^.iHdrOffset = 0 then
      PPagerSavepoint(PByte(pPager^.aSavepoint) + ii * SizeOf(PagerSavepoint))^.iHdrOffset := pPager^.journalOff;
    Inc(ii);
  end;

  pPager^.journalHdr := journalHdrOffset(pPager);
  pPager^.journalOff := pPager^.journalHdr;

  { Determine nRec field: 0xFFFFFFFF for no-sync / SAFE_APPEND, else 0 }
  iDc := 0;
  if isOpen(pPager^.fd) <> 0 then
    iDc := sqlite3OsDeviceCharacteristics(pPager^.fd);
  if (pPager^.noSync <> 0) or (pPager^.journalMode = PAGER_JOURNALMODE_MEMORY)
     or ((iDc and SQLITE_IOCAP_SAFE_APPEND) <> 0) then
  begin
    Move(aJournalMagic[0], zHeader^, 8);
    sqlite3Put4byte(Pu8(zHeader) + 8, $FFFFFFFF);
  end
  else
  begin
    FillChar(zHeader^, 12, 0);
  end;

  { Random checksum initializer }
  if pPager^.journalMode <> PAGER_JOURNALMODE_MEMORY then
    sqlite3_randomness(SizeOf(pPager^.cksumInit), @pPager^.cksumInit);

  sqlite3Put4byte(Pu8(zHeader) + 12, pPager^.cksumInit);
  sqlite3Put4byte(Pu8(zHeader) + 16, pPager^.dbOrigSize);
  sqlite3Put4byte(Pu8(zHeader) + 20, pPager^.sectorSize);
  sqlite3Put4byte(Pu8(zHeader) + 24, u32(pPager^.pageSize));
  FillChar((Pu8(zHeader) + 28)^, nHeader - 28, 0);

  { Write header to journal (only first sector bytes matter for header) }
  nWrite := 0;
  while (rc = SQLITE_OK) and (nWrite < u32(JOURNAL_HDR_SZ(pPager))) do
  begin
    tmp32 := nHeader;
    if tmp32 > u32(JOURNAL_HDR_SZ(pPager)) - nWrite then
      tmp32 := u32(JOURNAL_HDR_SZ(pPager)) - nWrite;
    rc := sqlite3OsWrite(pPager^.jfd, zHeader, i32(tmp32),
                         pPager^.journalOff + nWrite);
    Inc(nWrite, tmp32);
  end;
  pPager^.journalOff += JOURNAL_HDR_SZ(pPager);
  Result := rc;
end;

{ pager.c ~1579: readJournalHdr -- read journal header }
function readJournalHdr(pPager: PPager; isHot: i32; journalSize: i64;
  pNRec: Pu32; pDbSize: Pu32): i32;
var
  rc: i32;
  aMagic: array[0..7] of u8;
  iHdrOff: i64;
  iPageSize: u32;
  iSectorSize: u32;
begin
  pPager^.journalOff := journalHdrOffset(pPager);
  if pPager^.journalOff + JOURNAL_HDR_SZ(pPager) > journalSize then
    Exit(SQLITE_DONE);
  iHdrOff := pPager^.journalOff;

  if (isHot <> 0) or (iHdrOff <> pPager^.journalHdr) then
  begin
    rc := sqlite3OsRead(pPager^.jfd, @aMagic[0], 8, iHdrOff);
    if rc <> SQLITE_OK then Exit(rc);
    if CompareByte(aMagic[0], aJournalMagic[0], 8) <> 0 then
      Exit(SQLITE_DONE);
  end;

  rc := read32bits(pPager^.jfd, iHdrOff + 8,  pNRec);
  if rc <> SQLITE_OK then Exit(rc);
  rc := read32bits(pPager^.jfd, iHdrOff + 12, @pPager^.cksumInit);
  if rc <> SQLITE_OK then Exit(rc);
  rc := read32bits(pPager^.jfd, iHdrOff + 16, pDbSize);
  if rc <> SQLITE_OK then Exit(rc);

  if pPager^.journalOff = 0 then
  begin
    rc := read32bits(pPager^.jfd, iHdrOff + 20, @iSectorSize);
    if rc <> SQLITE_OK then Exit(rc);
    rc := read32bits(pPager^.jfd, iHdrOff + 24, @iPageSize);
    if rc <> SQLITE_OK then Exit(rc);
    if iPageSize = 0 then iPageSize := u32(pPager^.pageSize);
    if (iPageSize < 512) or (iSectorSize < 32) or
       (iPageSize > SQLITE_MAX_PAGE_SIZE) or (iSectorSize > MAX_SECTOR_SIZE) or
       ((iPageSize - 1) and iPageSize <> 0) or
       ((iSectorSize - 1) and iSectorSize <> 0) then
      Exit(SQLITE_DONE);
    rc := sqlite3PagerSetPagesize(pPager, @iPageSize, -1);
    if rc <> SQLITE_OK then Exit(rc);
    pPager^.sectorSize := iSectorSize;
  end;

  pPager^.journalOff += JOURNAL_HDR_SZ(pPager);
  Result := rc;
end;

{ pager.c ~1704: writeSuperJournal -- write super-journal name into journal }
function writeSuperJournal(pPager: PPager; zSuper: PChar): i32;
var
  rc: i32;
  nSuper: i32;
  iHdrOff: i64;
  jrnlSize: i64;
  cksum: u32;
  i: i32;
begin
  if (zSuper = nil) or (pPager^.journalMode = PAGER_JOURNALMODE_MEMORY)
     or (isOpen(pPager^.jfd) = 0) then
    Exit(SQLITE_OK);
  pPager^.setSuper := 1;

  nSuper := 0;
  cksum  := 0;
  while zSuper[nSuper] <> #0 do
  begin
    cksum += u32(Byte(zSuper[nSuper]));
    Inc(nSuper);
  end;

  if pPager^.fullSync <> 0 then
    pPager^.journalOff := journalHdrOffset(pPager);
  iHdrOff := pPager^.journalOff;

  { PAGER_SJ_PGNO: max valid page number + 1 = $FFFFFFFF is used as sentinel
    The actual C macro is: ((Pgno)((PENDING_BYTE/pageSize)+1))
    For simplicity write $FFFFFFFF like SQLite does for super-journal pgno }
  rc := write32bits(pPager^.jfd, iHdrOff, $FFFFFFFF);
  if rc <> SQLITE_OK then Exit(rc);
  rc := sqlite3OsWrite(pPager^.jfd, zSuper, nSuper, iHdrOff + 4);
  if rc <> SQLITE_OK then Exit(rc);
  rc := write32bits(pPager^.jfd, iHdrOff + 4 + nSuper, u32(nSuper));
  if rc <> SQLITE_OK then Exit(rc);
  rc := write32bits(pPager^.jfd, iHdrOff + 4 + nSuper + 4, cksum);
  if rc <> SQLITE_OK then Exit(rc);
  rc := sqlite3OsWrite(pPager^.jfd, @aJournalMagic[0], 8,
                       iHdrOff + 4 + nSuper + 8);
  if rc <> SQLITE_OK then Exit(rc);
  pPager^.journalOff += nSuper + 20;

  jrnlSize := 0;
  if (sqlite3OsFileSize(pPager^.jfd, @jrnlSize) = SQLITE_OK)
     and (jrnlSize > pPager^.journalOff) then
    rc := sqlite3OsTruncate(pPager^.jfd, pPager^.journalOff);
  Result := rc;
  if i = 0 then; { suppress unused warning }
end;

{ pager.c ~1809: addToSavepointBitvecs }
function addToSavepointBitvecs(pPager: PPager; pgno: Pgno): i32;
var
  ii: i32;
  p: PPagerSavepoint;
  rc: i32;
begin
  rc := SQLITE_OK;
  ii := 0;
  while ii < pPager^.nSavepoint do
  begin
    p := PPagerSavepoint(PByte(pPager^.aSavepoint) + ii * SizeOf(PagerSavepoint));
    if pgno <= p^.nOrig then
      rc := rc or sqlite3BitvecSet(p^.pInSavepoint, pgno);
    Inc(ii);
  end;
  Result := rc;
end;

{ pager.c ~4546: openSubJournal -- ensure sub-journal is open }
function openSubJournal(pPager: PPager): i32;
var
  rc: i32;
  flags: i32;
  nStmtSpill: i32;
begin
  rc := SQLITE_OK;
  if isOpen(pPager^.sjfd) = 0 then
  begin
    flags := SQLITE_OPEN_SUBJOURNAL or SQLITE_OPEN_READWRITE
           or SQLITE_OPEN_CREATE or SQLITE_OPEN_EXCLUSIVE
           or SQLITE_OPEN_DELETEONCLOSE;
    nStmtSpill := sqlite3GlobalConfig.nStmtSpill;
    if (pPager^.journalMode = PAGER_JOURNALMODE_MEMORY)
       or (pPager^.subjInMemory <> 0) then
      nStmtSpill := -1;
    rc := sqlite3JournalOpen(pPager^.pVfs, nil, pPager^.sjfd, flags, nStmtSpill);
  end;
  Result := rc;
end;

{ pager.c ~4546: subjournalPage -- write page to sub-journal }
function subjournalPage(pPg: PPgHdr): i32;
var
  rc: i32;
  pPgr: PPager;
  offset: i64;
begin
  rc := SQLITE_OK;
  pPgr := pPg^.pPager;
  if pPgr^.journalMode <> PAGER_JOURNALMODE_OFF then
  begin
    rc := openSubJournal(pPgr);
    if rc = SQLITE_OK then
    begin
      offset := i64(pPgr^.nSubRec) * (4 + pPgr^.pageSize);
      rc := write32bits(pPgr^.sjfd, offset, pPg^.pgno);
      if rc = SQLITE_OK then
        rc := sqlite3OsWrite(pPgr^.sjfd, pPg^.pData, pPgr^.pageSize, offset + 4);
    end;
  end;
  if rc = SQLITE_OK then
  begin
    Inc(pPgr^.nSubRec);
    rc := addToSavepointBitvecs(pPgr, pPg^.pgno);
  end;
  Result := rc;
end;

{ pager.c ~4582: subjournalPageIfRequired }
function subjournalPageIfRequired(pPg: PPgHdr): i32;
begin
  if subjRequiresPage(pPg) <> 0 then
    Result := subjournalPage(pPg)
  else
    Result := SQLITE_OK;
end;

{ pager.c ~3684: pagerOpentemp -- open a temp file }
function pagerOpentemp(pPager: PPager; pFile: Psqlite3_file; vfsFlags: i32): i32;
var
  rc: i32;
begin
  vfsFlags := vfsFlags or SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE
           or SQLITE_OPEN_EXCLUSIVE or SQLITE_OPEN_DELETEONCLOSE;
  rc := sqlite3OsOpen(pPager^.pVfs, nil, pFile, vfsFlags, nil);
  Result := rc;
end;

{ pager.c ~1963: pager_truncate -- resize database file }
function pager_truncate(pPager: PPager; nPage: Pgno): i32;
var
  rc: i32;
  currentSize, newSize: i64;
  szPage: i32;
  pTmp: PChar;
begin
  rc := SQLITE_OK;
  if (isOpen(pPager^.fd) <> 0) and
     ((pPager^.eState >= PAGER_WRITER_DBMOD) or (pPager^.eState = PAGER_OPEN)) then
  begin
    szPage := i32(pPager^.pageSize);
    currentSize := 0;
    rc := sqlite3OsFileSize(pPager^.fd, @currentSize);
    newSize := i64(szPage) * i64(nPage);
    if (rc = SQLITE_OK) and (currentSize <> newSize) then
    begin
      if currentSize > newSize then
        rc := sqlite3OsTruncate(pPager^.fd, newSize)
      else if (currentSize + szPage) <= newSize then
      begin
        pTmp := pPager^.pTmpSpace;
        FillChar(pTmp^, szPage, 0);
        sqlite3OsFileControlHint(pPager^.fd, SQLITE_FCNTL_SIZE_HINT, @newSize);
        rc := sqlite3OsWrite(pPager^.fd, pTmp, szPage, newSize - szPage);
      end;
      if rc = SQLITE_OK then
        pPager^.dbFileSize := nPage;
    end;
  end;
  Result := rc;
end;

{ pager.c ~2287: pager_playback_one_page -- restore one journal page }
function pager_playback_one_page(pPager: PPager; pOffset: Pi64;
  pDone: PBitvec; isMainJrnl: i32; isSavepnt: i32): i32;
var
  rc: i32;
  pPg: PPgHdr;
  pg: u32;
  cksum: u32;
  aData: PChar;
  jfd: Psqlite3_file;
  isSynced: i32;
  pData: Pointer;
begin
  aData := pPager^.pTmpSpace;
  if isMainJrnl <> 0 then jfd := pPager^.jfd else jfd := pPager^.sjfd;

  rc := read32bits(jfd, pOffset^, @pg);
  if rc <> SQLITE_OK then Exit(rc);
  rc := sqlite3OsRead(jfd, aData, pPager^.pageSize, pOffset^ + 4);
  if rc <> SQLITE_OK then Exit(rc);
  pOffset^ += pPager^.pageSize + 4 + isMainJrnl * 4;

  { Sanity check }
  if (pg = 0) or (pg = u32(($ffffffff div u32(pPager^.pageSize)) + 1)) then
    Exit(SQLITE_DONE);
  if (pg > pPager^.dbSize) or ((pDone <> nil) and (sqlite3BitvecTest(pDone, pg) <> 0)) then
    Exit(SQLITE_OK);

  if isMainJrnl <> 0 then
  begin
    rc := read32bits(jfd, pOffset^ - 4, @cksum);
    if rc <> SQLITE_OK then Exit(rc);
    if (isSavepnt = 0) and (pager_cksum(pPager, Pu8(aData)) <> cksum) then
      Exit(SQLITE_DONE);
  end;

  if (pDone <> nil) then
  begin
    rc := sqlite3BitvecSet(pDone, pg);
    if rc <> SQLITE_OK then Exit(rc);
  end;

  if (pg = 1) and (pPager^.nReserve <> i16((Pu8(aData) + 20)^)) then
    pPager^.nReserve := i16((Pu8(aData) + 20)^);

  if pagerUseWal(pPager) <> 0 then pPg := nil
  else pPg := sqlite3PagerLookup(pPager, pg);

  if isMainJrnl <> 0 then
    isSynced := i32((pPager^.noSync <> 0) or (pOffset^ <= pPager^.journalHdr))
  else
  begin
    if (pPg = nil) or ((pPg^.flags and PGHDR_NEED_SYNC) = 0) then
      isSynced := 1
    else
      isSynced := 0;
  end;

  if (isOpen(pPager^.fd) <> 0) and
     ((pPager^.eState >= PAGER_WRITER_DBMOD) or (pPager^.eState = PAGER_OPEN)) and
     (isSynced <> 0) then
  begin
    rc := sqlite3OsWrite(pPager^.fd, aData, pPager^.pageSize,
                         (i64(pg) - 1) * pPager^.pageSize);
    if pg > pPager^.dbFileSize then
      pPager^.dbFileSize := pg;
  end
  else if (isMainJrnl = 0) and (pPg = nil) then
  begin
    pPager^.doNotSpill := pPager^.doNotSpill or SPILLFLAG_ROLLBACK;
    rc := sqlite3PagerGet(pPager, pg, @pPg, 1);
    pPager^.doNotSpill := pPager^.doNotSpill and (not SPILLFLAG_ROLLBACK);
    if rc <> SQLITE_OK then Exit(rc);
    sqlite3PcacheMakeDirty(pPg);
  end;

  if pPg <> nil then
  begin
    pData := pPg^.pData;
    Move(aData^, pData^, pPager^.pageSize);
    pPager^.xReiniter(pPg);
    if pg = 1 then
      Move((Pu8(pData) + 24)^, pPager^.dbFileVers[0], SizeOf(pPager^.dbFileVers));
    sqlite3PcacheRelease(pPg);
  end;
  Result := rc;
end;

{ pager.c ~3406: pagerPlaybackSavepoint }
function pagerPlaybackSavepoint(pPager: PPager; pSavepoint: PPagerSavepoint): i32;
var
  szJ: i64;
  iHdrOff: i64;
  rc: i32;
  pDone: PBitvec;
  ii: u32;
  nJRec: u32;
  dummy: u32;
  offset: i64;
begin
  rc := SQLITE_OK;
  pDone := nil;
  if pSavepoint <> nil then
  begin
    pDone := sqlite3BitvecCreate(pSavepoint^.nOrig);
    if pDone = nil then Exit(SQLITE_NOMEM);
  end;

  if pSavepoint <> nil then
    pPager^.dbSize := pSavepoint^.nOrig
  else
    pPager^.dbSize := pPager^.dbOrigSize;
  pPager^.changeCountDone := pPager^.tempFile;

  szJ := pPager^.journalOff;

  if (pSavepoint <> nil) and (pagerUseWal(pPager) = 0) then
  begin
    if pSavepoint^.iHdrOffset <> 0 then iHdrOff := pSavepoint^.iHdrOffset
    else iHdrOff := szJ;
    pPager^.journalOff := pSavepoint^.iOffset;
    while (rc = SQLITE_OK) and (pPager^.journalOff < iHdrOff) do
      rc := pager_playback_one_page(pPager, @pPager^.journalOff, pDone, 1, 1);
  end
  else
    pPager^.journalOff := 0;

  while (rc = SQLITE_OK) and (pPager^.journalOff < szJ) do
  begin
    nJRec := 0;
    dummy := 0;
    rc := readJournalHdr(pPager, 0, szJ, @nJRec, @dummy);
    if nJRec = 0 then
    begin
      if pPager^.journalHdr + JOURNAL_HDR_SZ(pPager) = pPager^.journalOff then
        nJRec := u32((szJ - pPager^.journalOff) div JOURNAL_PG_SZ(pPager));
    end;
    ii := 0;
    while (rc = SQLITE_OK) and (ii < nJRec) and (pPager^.journalOff < szJ) do
    begin
      rc := pager_playback_one_page(pPager, @pPager^.journalOff, pDone, 1, 1);
      Inc(ii);
    end;
  end;

  if (pSavepoint <> nil) then
  begin
    offset := i64(pSavepoint^.iSubRec) * (4 + pPager^.pageSize);
    ii := pSavepoint^.iSubRec;
    while (rc = SQLITE_OK) and (ii < pPager^.nSubRec) do
    begin
      rc := pager_playback_one_page(pPager, @offset, pDone, 0, 1);
      Inc(ii);
    end;
  end;

  sqlite3BitvecDestroy(pDone);
  if rc = SQLITE_OK then
    pPager^.journalOff := szJ;
  Result := rc;
end;

{ pager.c ~2801: pager_playback -- full rollback journal playback }
function pager_playback(pPager: PPager; isHot: i32): i32;
label
  end_playback;
var
  szJ: i64;
  nRec: u32;
  u: u32;
  mxPg: Pgno;
  rc: i32;
  res: i32;
  zSuper: PChar;
  needPagerReset: i32;
  nPlayback: i32;
  savedPageSize: u32;
begin
  szJ := 0;
  nRec := 0;
  mxPg := 0;
  rc := SQLITE_OK;
  res := 1;
  needPagerReset := isHot;
  nPlayback := 0;
  savedPageSize := u32(pPager^.pageSize);

  rc := sqlite3OsFileSize(pPager^.jfd, @szJ);
  if rc <> SQLITE_OK then goto end_playback;

  zSuper := pPager^.pTmpSpace;
  rc := readSuperJournal(pPager^.jfd, zSuper,
                         1 + i64(pPager^.pVfs^.mxPathname));
  if (rc = SQLITE_OK) and (zSuper[0] <> #0) then
    rc := sqlite3OsAccess(pPager^.pVfs, zSuper, SQLITE_ACCESS_EXISTS, @res);
  zSuper := nil;
  if (rc <> SQLITE_OK) or (res = 0) then goto end_playback;

  pPager^.journalOff := 0;

  while True do
  begin
    nRec := 0;
    mxPg := 0;
    rc := readJournalHdr(pPager, isHot, szJ, @nRec, @mxPg);
    if rc <> SQLITE_OK then
    begin
      if rc = SQLITE_DONE then rc := SQLITE_OK;
      goto end_playback;
    end;

    if nRec = $FFFFFFFF then
    begin
      nRec := u32((szJ - JOURNAL_HDR_SZ(pPager)) div JOURNAL_PG_SZ(pPager));
    end;

    if (nRec = 0) and (isHot = 0) and
       (pPager^.journalHdr + JOURNAL_HDR_SZ(pPager) = pPager^.journalOff) then
    begin
      nRec := u32((szJ - pPager^.journalOff) div JOURNAL_PG_SZ(pPager));
    end;

    if pPager^.journalOff = JOURNAL_HDR_SZ(pPager) then
    begin
      rc := pager_truncate(pPager, mxPg);
      if rc <> SQLITE_OK then goto end_playback;
      pPager^.dbSize := mxPg;
      if pPager^.mxPgno < mxPg then pPager^.mxPgno := mxPg;
    end;

    if nRec > 0 then
    begin
      u := 0;
      while u < nRec do
      begin
        if needPagerReset <> 0 then
        begin
          pager_reset(pPager);
          needPagerReset := 0;
        end;
        rc := pager_playback_one_page(pPager, @pPager^.journalOff, nil, 1, 0);
        if rc = SQLITE_OK then
          Inc(nPlayback)
        else
        begin
          if rc = SQLITE_DONE then
          begin
            pPager^.journalOff := szJ;
            Break;
          end
          else if rc = SQLITE_IOERR_SHORT_READ then
          begin
            rc := SQLITE_OK;
            goto end_playback;
          end
          else
            goto end_playback;
        end;
        Inc(u);
      end;
    end;
  end;

end_playback:
  if rc = SQLITE_OK then
    rc := sqlite3PagerSetPagesize(pPager, @savedPageSize, -1);

  pPager^.changeCountDone := pPager^.tempFile;

  if rc = SQLITE_OK then
  begin
    zSuper := @pPager^.pTmpSpace[4];
    rc := readSuperJournal(pPager^.jfd, zSuper,
                           1 + i64(pPager^.pVfs^.mxPathname));
  end;
  if (rc = SQLITE_OK) and
     ((pPager^.eState >= PAGER_WRITER_DBMOD) or (pPager^.eState = PAGER_OPEN)) then
    rc := sqlite3PagerSync(pPager, nil);
  if rc = SQLITE_OK then
    rc := pager_end_transaction(pPager, i32(zSuper[0] <> #0), 0);
  if (rc = SQLITE_OK) and (zSuper[0] <> #0) and (res <> 0) then
  begin
    FillChar(pPager^.pTmpSpace^, 4, 0);
    rc := pager_delsuper(pPager, zSuper);
  end;
  if (isHot <> 0) and (nPlayback <> 0) then
    sqlite3_log(SQLITE_NOTICE_RECOVER_ROLLBACK,
      PChar(Format('recovered %d pages from %s', [nPlayback, string(pPager^.zJournal)])));

  setSectorSize(pPager);
  Result := rc;
end;

{ printf.c:1499 — sqlite3_log.  C uses varargs + sqlite3_str_vappendf to
  format zFormat; Pas callers pre-render the message with Format() and
  pass it as zMsg, so this port skips the format step and dispatches the
  finished message directly to the configured xLog callback. }
type
  TSqlite3LogCallback = procedure(pArg: Pointer; iErrCode: i32; zMsg: PChar); cdecl;

procedure sqlite3_log(iErrCode: i32; zMsg: PChar);
var
  xLog: TSqlite3LogCallback;
begin
  if sqlite3GlobalConfig.xLog <> nil then
  begin
    xLog := TSqlite3LogCallback(sqlite3GlobalConfig.xLog);
    xLog(sqlite3GlobalConfig.pLogArg, iErrCode, zMsg);
  end;
end;

{ pager.c ~2635: pager_delsuper -- delete super-journal if no children reference it }
function pager_delsuper(pPager: PPager; zSuper: PChar): i32;
label
  delsuper_out;
var
  pVfs: Psqlite3_vfs;
  rc: i32;
  pSuperFile: Psqlite3_file;
  pJrnlFile: Psqlite3_file;
  zSuperJournal: PChar;
  nSuperJournal: i64;
  zJournal: PChar;
  zSuperPtr: PChar;
  zFree: PChar;
  nSuperPtr: i64;
  exists: i32;
  c: i32;
begin
  pVfs := pPager^.pVfs;
  zFree := nil;
  pSuperFile := nil;
  rc := SQLITE_OK;

  pSuperFile := Psqlite3_file(sqlite3MallocZero(2 * i64(pVfs^.szOsFile)));
  if pSuperFile = nil then
  begin
    rc := SQLITE_NOMEM;
    pJrnlFile := nil;
    goto delsuper_out;
  end;

  rc := sqlite3OsOpen(pVfs, zSuper, pSuperFile,
                      SQLITE_OPEN_READONLY or SQLITE_OPEN_SUPER_JOURNAL, nil);
  pJrnlFile := Psqlite3_file(PByte(pSuperFile) + pVfs^.szOsFile);
  if rc <> SQLITE_OK then goto delsuper_out;

  nSuperJournal := 0;
  rc := sqlite3OsFileSize(pSuperFile, @nSuperJournal);
  if rc <> SQLITE_OK then goto delsuper_out;

  nSuperPtr := 1 + i64(pVfs^.mxPathname);
  zFree := sqlite3_malloc(i32(4 + nSuperJournal + nSuperPtr + 2));
  if zFree = nil then
  begin
    rc := SQLITE_NOMEM;
    goto delsuper_out;
  end;
  FillChar(zFree^, 4, 0);
  zSuperJournal := zFree + 4;
  zSuperPtr := zSuperJournal + nSuperJournal + 2;

  rc := sqlite3OsRead(pSuperFile, zSuperJournal, i32(nSuperJournal), 0);
  if rc <> SQLITE_OK then goto delsuper_out;
  (zSuperJournal + nSuperJournal)^ := #0;
  (zSuperJournal + nSuperJournal + 1)^ := #0;

  zJournal := zSuperJournal;
  while (zJournal - zSuperJournal) < nSuperJournal do
  begin
    exists := 0;
    rc := sqlite3OsAccess(pVfs, zJournal, SQLITE_ACCESS_EXISTS, @exists);
    if rc <> SQLITE_OK then goto delsuper_out;
    if exists <> 0 then
    begin
      rc := sqlite3OsOpen(pVfs, zJournal, pJrnlFile,
                          SQLITE_OPEN_READONLY or SQLITE_OPEN_SUPER_JOURNAL, nil);
      if rc <> SQLITE_OK then goto delsuper_out;
      rc := readSuperJournal(pJrnlFile, zSuperPtr, nSuperPtr);
      sqlite3OsClose(pJrnlFile);
      if rc <> SQLITE_OK then goto delsuper_out;
      c := i32((zSuperPtr[0] <> #0) and (StrComp(zSuperPtr, zSuper) = 0));
      if c <> 0 then goto delsuper_out;
    end;
    Inc(zJournal, sqlite3Strlen30(zJournal) + 1);
  end;

  sqlite3OsClose(pSuperFile);
  rc := sqlite3OsDelete(pVfs, zSuper, 0);

delsuper_out:
  sqlite3_free(zFree);
  if pSuperFile <> nil then
  begin
    sqlite3OsClose(pSuperFile);
    sqlite3_free(pSuperFile);
  end;
  Result := rc;
end;

{ pager.c ~2041: pager_end_transaction -- finalize journal and unlock }
function pager_end_transaction(pPager: PPager; hasSuper: i32; bCommit: i32): i32;
var
  rc: i32;
  rc2: i32;
  iDc: i32;
begin
  rc  := SQLITE_OK;
  rc2 := SQLITE_OK;

  if (pPager^.eState < PAGER_WRITER_LOCKED) and (pPager^.eLock < RESERVED_LOCK) then
    Exit(SQLITE_OK);

  releaseAllSavepoints(pPager);

  if isOpen(pPager^.jfd) <> 0 then
  begin
    if sqlite3JournalIsInMemory(pPager^.jfd) <> 0 then
      sqlite3OsClose(pPager^.jfd)
    else if pPager^.journalMode = PAGER_JOURNALMODE_TRUNCATE then
    begin
      if pPager^.journalOff = 0 then
        rc := SQLITE_OK
      else
      begin
        rc := sqlite3OsTruncate(pPager^.jfd, 0);
        if (rc = SQLITE_OK) and (pPager^.fullSync <> 0) then
          rc := sqlite3OsSync(pPager^.jfd, pPager^.syncFlags);
      end;
      pPager^.journalOff := 0;
    end
    else if (pPager^.journalMode = PAGER_JOURNALMODE_PERSIST)
         or ((pPager^.exclusiveMode <> 0) and (pPager^.journalMode < PAGER_JOURNALMODE_WAL)) then
    begin
      rc := zeroJournalHdr(pPager, i32((hasSuper <> 0) or (pPager^.tempFile <> 0)));
      pPager^.journalOff := 0;
    end
    else
    begin
      iDc := 0;
      if isOpen(pPager^.fd) <> 0 then
        iDc := sqlite3OsDeviceCharacteristics(pPager^.fd);
      if (iDc and SQLITE_IOCAP_UNDELETABLE_WHEN_OPEN = 0)
         or (pPager^.journalMode and 5 <> 1) then
        sqlite3OsClose(pPager^.jfd);
      if pPager^.tempFile = 0 then
        rc := sqlite3OsDelete(pPager^.pVfs, pPager^.zJournal, pPager^.extraSync);
    end;
  end;

  sqlite3BitvecDestroy(pPager^.pInJournal);
  pPager^.pInJournal := nil;
  pPager^.nRec := 0;

  if rc = SQLITE_OK then
  begin
    if (pPager^.memDb <> 0) or (pagerFlushOnCommit(pPager, bCommit) <> 0) then
      sqlite3PcacheCleanAll(pPager^.pPCache)
    else
      sqlite3PcacheClearWritable(pPager^.pPCache);
    sqlite3PcacheTruncate(pPager^.pPCache, pPager^.dbSize);
  end;

  if pagerUseWal(pPager) <> 0 then
    rc2 := sqlite3WalEndWriteTransaction(pPager^.pWal)
  else if (rc = SQLITE_OK) and (bCommit <> 0) and (pPager^.dbFileSize > pPager^.dbSize) then
    rc := pager_truncate(pPager, pPager^.dbSize);

  if rc = SQLITE_OK then
  begin
    rc := sqlite3OsFileControl(pPager^.fd, SQLITE_FCNTL_COMMIT_PHASETWO, nil);
    if rc = SQLITE_NOTFOUND then rc := SQLITE_OK;
  end;

  if (pPager^.exclusiveMode = 0)
  and ((pagerUseWal(pPager) = 0)
       or (sqlite3WalExclusiveMode(pPager^.pWal, 0) = 0)) then
    rc2 := pagerUnlockDb(pPager, SHARED_LOCK);

  pPager^.eState  := PAGER_READER;
  pPager^.setSuper := 0;

  if rc = SQLITE_OK then Result := rc2 else Result := rc;
end;

{ pager.c ~2173: pagerUnlockAndRollback -- full rollback version }
procedure pagerUnlockAndRollback(pPager: PPager);
var
  errCode: i32;
  eLock: u8;
begin
  if (pPager^.eState <> PAGER_ERROR) and (pPager^.eState <> PAGER_OPEN) then
  begin
    if pPager^.eState >= PAGER_WRITER_LOCKED then
    begin
      sqlite3BeginBenignMalloc;
      sqlite3PagerRollback(pPager);
      sqlite3EndBenignMalloc;
    end
    else if pPager^.exclusiveMode = 0 then
      pager_end_transaction(pPager, 0, 0);
  end
  else if (pPager^.eState = PAGER_ERROR)
       and (pPager^.journalMode = PAGER_JOURNALMODE_MEMORY)
       and (isOpen(pPager^.jfd) <> 0) then
  begin
    errCode := pPager^.errCode;
    eLock    := pPager^.eLock;
    pPager^.eState   := PAGER_OPEN;
    pPager^.errCode  := SQLITE_OK;
    pPager^.eLock    := EXCLUSIVE_LOCK;
    pager_playback(pPager, 1);
    pPager^.errCode := errCode;
    pPager^.eLock   := eLock;
  end;
  pager_unlock(pPager);
end;

{ pager.c ~4286: syncJournal -- sync journal and advance to WRITER_DBMOD }
function syncJournal(pPager: PPager; newHdr: i32): i32;
var
  rc: i32;
  iDc: i32;
  iNextHdrOffset: i64;
  aMagic: array[0..7] of u8;
  zHeader: array[0..11] of u8;
  zerobyte: u8;
begin
  rc := sqlite3PagerExclusiveLock(pPager);
  if rc <> SQLITE_OK then Exit(rc);

  if pPager^.noSync = 0 then
  begin
    if (isOpen(pPager^.jfd) <> 0) and (pPager^.journalMode <> PAGER_JOURNALMODE_MEMORY) then
    begin
      iDc := sqlite3OsDeviceCharacteristics(pPager^.fd);

      if (iDc and SQLITE_IOCAP_SAFE_APPEND) = 0 then
      begin
        Move(aJournalMagic[0], zHeader[0], 8);
        sqlite3Put4byte(@zHeader[8], pPager^.nRec);

        iNextHdrOffset := journalHdrOffset(pPager);
        rc := sqlite3OsRead(pPager^.jfd, @aMagic[0], 8, iNextHdrOffset);
        if (rc = SQLITE_OK) and (CompareByte(aMagic[0], aJournalMagic[0], 8) = 0) then
        begin
          zerobyte := 0;
          rc := sqlite3OsWrite(pPager^.jfd, @zerobyte, 1, iNextHdrOffset);
        end;
        if (rc <> SQLITE_OK) and (rc <> SQLITE_IOERR_SHORT_READ) then Exit(rc);

        if (pPager^.fullSync <> 0) and ((iDc and SQLITE_IOCAP_SEQUENTIAL) = 0) then
        begin
          rc := sqlite3OsSync(pPager^.jfd, pPager^.syncFlags);
          if rc <> SQLITE_OK then Exit(rc);
        end;
        rc := sqlite3OsWrite(pPager^.jfd, @zHeader[0], 12, pPager^.journalHdr);
        if rc <> SQLITE_OK then Exit(rc);
      end;

      if (iDc and SQLITE_IOCAP_SEQUENTIAL) = 0 then
      begin
        rc := sqlite3OsSync(pPager^.jfd, pPager^.syncFlags or
          i32(i32(pPager^.syncFlags = SQLITE_SYNC_FULL) * SQLITE_SYNC_DATAONLY));
        if rc <> SQLITE_OK then Exit(rc);
      end;

      pPager^.journalHdr := pPager^.journalOff;
      if (newHdr <> 0) and ((iDc and SQLITE_IOCAP_SAFE_APPEND) = 0) then
      begin
        pPager^.nRec := 0;
        rc := writeJournalHdr(pPager);
        if rc <> SQLITE_OK then Exit(rc);
      end;
    end
    else
      pPager^.journalHdr := pPager^.journalOff;
  end;

  sqlite3PcacheClearSyncFlags(pPager^.pPCache);
  pPager^.eState := PAGER_WRITER_DBMOD;
  Result := SQLITE_OK;
end;

{ pager.c ~4429: pager_write_pagelist -- write dirty pages to database file }
function pager_write_pagelist(pPager: PPager; pList: PPgHdr): i32;
var
  rc: i32;
  pg: u32;
  pData: PChar;
  offset: i64;
  szFile: sqlite3_int64;
begin
  rc := SQLITE_OK;
  if isOpen(pPager^.fd) = 0 then
  begin
    rc := pagerOpentemp(pPager, pPager^.fd, pPager^.vfsFlags);
    if rc <> SQLITE_OK then Exit(rc);
  end;

  if (pPager^.dbHintSize < pPager^.dbSize) and (pList <> nil) then
  begin
    szFile := pPager^.pageSize * i64(pPager^.dbSize);
    sqlite3OsFileControlHint(pPager^.fd, SQLITE_FCNTL_SIZE_HINT, @szFile);
    pPager^.dbHintSize := pPager^.dbSize;
  end;

  while (rc = SQLITE_OK) and (pList <> nil) do
  begin
    pg := pList^.pgno;
    if (pg <= pPager^.dbSize) and ((pList^.flags and PGHDR_DONT_WRITE) = 0) then
    begin
      offset := (i64(pg) - 1) * pPager^.pageSize;
      if pList^.pgno = 1 then pager_write_changecounter(pList);
      pData := PChar(pList^.pData);
      rc := sqlite3OsWrite(pPager^.fd, pData, pPager^.pageSize, offset);
      if pg = 1 then
        Move((pData + 24)^, pPager^.dbFileVers[0], SizeOf(pPager^.dbFileVers));
      if pg > pPager^.dbFileSize then
        pPager^.dbFileSize := pg;
      Inc(pPager^.aStat[PAGER_STAT_WRITE]);
    end;
    pList := pList^.pDirty;
  end;
  Result := rc;
end;

{ pager.c ~5831: pager_open_journal -- open rollback journal for writing }
function pager_open_journal(pPager: PPager): i32;
var
  rc: i32;
  flags: i32;
  nSpill: i32;
begin
  rc := SQLITE_OK;
  if pPager^.errCode <> 0 then Exit(pPager^.errCode);

  if (pagerUseWal(pPager) = 0) and (pPager^.journalMode <> PAGER_JOURNALMODE_OFF) then
  begin
    pPager^.pInJournal := sqlite3BitvecCreate(pPager^.dbSize);
    if pPager^.pInJournal = nil then Exit(SQLITE_NOMEM);

    if isOpen(pPager^.jfd) = 0 then
    begin
      if pPager^.journalMode = PAGER_JOURNALMODE_MEMORY then
        sqlite3MemJournalOpen(pPager^.jfd)
      else
      begin
        flags := SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE;
        if pPager^.tempFile <> 0 then
        begin
          flags := flags or SQLITE_OPEN_DELETEONCLOSE or SQLITE_OPEN_TEMP_JOURNAL
                        or SQLITE_OPEN_EXCLUSIVE;
          nSpill := sqlite3GlobalConfig.nStmtSpill;
        end
        else
        begin
          flags := flags or SQLITE_OPEN_MAIN_JOURNAL;
          nSpill := jrnlBufferSize(pPager);
        end;
        rc := databaseIsUnmoved(pPager);
        if rc = SQLITE_OK then
          rc := sqlite3JournalOpen(pPager^.pVfs, pPager^.zJournal,
                                   pPager^.jfd, flags, nSpill);
      end;
    end;

    if rc = SQLITE_OK then
    begin
      pPager^.nRec       := 0;
      pPager^.journalOff := 0;
      pPager^.setSuper   := 0;
      pPager^.journalHdr := 0;
      rc := writeJournalHdr(pPager);
    end;
  end;

  if rc <> SQLITE_OK then
  begin
    sqlite3BitvecDestroy(pPager^.pInJournal);
    pPager^.pInJournal := nil;
    pPager^.journalOff := 0;
  end
  else
  begin
    pPager^.eState := PAGER_WRITER_CACHEMOD;
  end;
  Result := rc;
end;

{ pager.c ~5922: sqlite3PagerBegin -- begin a write transaction }
function sqlite3PagerBegin(pPager: PPager; exFlag: i32; subjInMemory: i32): i32;
var
  rc: i32;
begin
  rc := SQLITE_OK;
  if pPager^.errCode <> 0 then Exit(pPager^.errCode);

  pPager^.subjInMemory := u8(subjInMemory);
  if pPager^.eState = PAGER_READER then
  begin
    if pagerUseWal(pPager) <> 0 then
    begin
      if (pPager^.exclusiveMode <> 0)
      and (sqlite3WalExclusiveMode(pPager^.pWal, -1) <> 0) then
      begin
        rc := pagerLockDb(pPager, EXCLUSIVE_LOCK);
        if rc = SQLITE_OK then
          sqlite3WalExclusiveMode(pPager^.pWal, 1);
        if rc <> SQLITE_OK then Exit(rc);
      end;
      rc := sqlite3WalBeginWriteTransaction(pPager^.pWal);
    end
    else
    begin
      rc := pagerLockDb(pPager, RESERVED_LOCK);
      if (rc = SQLITE_OK) and (exFlag <> 0) then
        rc := pager_wait_on_lock(pPager, EXCLUSIVE_LOCK);
    end;

    if rc = SQLITE_OK then
    begin
      pPager^.eState       := PAGER_WRITER_LOCKED;
      pPager^.dbHintSize   := pPager^.dbSize;
      pPager^.dbFileSize   := pPager^.dbSize;
      pPager^.dbOrigSize   := pPager^.dbSize;
      pPager^.journalOff   := 0;
    end;
  end;
  Result := rc;
end;

{ pager.c ~6048: pagerAddPageToRollbackJournal -- journal one page }
function pagerAddPageToRollbackJournal(pPg: PPgHdr): i32;
var
  pPgr: PPager;
  rc: i32;
  cksum: u32;
  iOff: i64;
begin
  pPgr := pPg^.pPager;
  iOff := pPgr^.journalOff;

  pPg^.flags := pPg^.flags or PGHDR_NEED_SYNC;

  cksum := pager_cksum(pPgr, Pu8(pPg^.pData));
  rc := write32bits(pPgr^.jfd, iOff, pPg^.pgno);
  if rc <> SQLITE_OK then Exit(rc);
  rc := sqlite3OsWrite(pPgr^.jfd, pPg^.pData, pPgr^.pageSize, iOff + 4);
  if rc <> SQLITE_OK then Exit(rc);
  rc := write32bits(pPgr^.jfd, iOff + pPgr^.pageSize + 4, cksum);
  if rc <> SQLITE_OK then Exit(rc);

  pPgr^.journalOff += 8 + pPgr^.pageSize;
  Inc(pPgr^.nRec);
  rc := sqlite3BitvecSet(pPgr^.pInJournal, pPg^.pgno);
  if rc = SQLITE_OK then
    rc := addToSavepointBitvecs(pPgr, pPg^.pgno);
  Result := rc;
end;

{ pager.c ~6048: pager_write -- mark one page dirty and journal it }
function pager_write(pPg: PPgHdr): i32;
var
  pPgr: PPager;
  rc: i32;
begin
  pPgr := pPg^.pPager;
  rc := SQLITE_OK;

  if pPgr^.eState = PAGER_WRITER_LOCKED then
  begin
    rc := pager_open_journal(pPgr);
    if rc <> SQLITE_OK then Exit(rc);
  end;

  sqlite3PcacheMakeDirty(pPg);

  if (pPgr^.pInJournal <> nil) and
     (sqlite3BitvecTestNotNull(pPgr^.pInJournal, pPg^.pgno) = 0) then
  begin
    if pPg^.pgno <= pPgr^.dbOrigSize then
    begin
      rc := pagerAddPageToRollbackJournal(pPg);
      if rc <> SQLITE_OK then Exit(rc);
    end
    else
    begin
      if pPgr^.eState <> PAGER_WRITER_DBMOD then
        pPg^.flags := pPg^.flags or PGHDR_NEED_SYNC;
    end;
  end;

  pPg^.flags := pPg^.flags or PGHDR_WRITEABLE;

  if pPgr^.nSavepoint > 0 then
    rc := subjournalPageIfRequired(pPg);

  if pPgr^.dbSize < pPg^.pgno then
    pPgr^.dbSize := pPg^.pgno;
  Result := rc;
end;

{ pager.c ~6234: sqlite3PagerWrite -- public write API (handles large sectors) }
function sqlite3PagerWrite(pPg: PDbPage): i32;
var
  pPgr: PPager;
  pHdr: PPgHdr;
  nPagePerSector: Pgno;
  pg1: Pgno;
  nPageCount: Pgno;
  nPage: i32;
  ii: i32;
  needSync: i32;
  rc: i32;
  pPage: PPgHdr;
begin
  pHdr := PPgHdr(pPg);
  pPgr := pHdr^.pPager;

  if ((pHdr^.flags and PGHDR_WRITEABLE) <> 0) and (pPgr^.dbSize >= pHdr^.pgno) then
  begin
    if pPgr^.nSavepoint > 0 then
      Result := subjournalPageIfRequired(pHdr)
    else
      Result := SQLITE_OK;
    Exit;
  end;

  if pPgr^.errCode <> 0 then Exit(pPgr^.errCode);

  { Large sector case }
  if pPgr^.sectorSize > u32(pPgr^.pageSize) then
  begin
    nPagePerSector := Pgno(pPgr^.sectorSize div u32(pPgr^.pageSize));
    pg1 := ((pHdr^.pgno - 1) and not (nPagePerSector - 1)) + 1;
    nPageCount := pPgr^.dbSize;
    if pHdr^.pgno > nPageCount then
      nPage := i32(pHdr^.pgno - pg1) + 1
    else if (pg1 + nPagePerSector - 1) > nPageCount then
      nPage := i32(nPageCount) + 1 - i32(pg1)
    else
      nPage := i32(nPagePerSector);
    needSync := 0;
    rc := SQLITE_OK;
    pPgr^.doNotSpill := pPgr^.doNotSpill or SPILLFLAG_NOSYNC;
    ii := 0;
    while (ii < nPage) and (rc = SQLITE_OK) do
    begin
      if (pg1 + Pgno(ii) = pHdr^.pgno) or
         (sqlite3BitvecTest(pPgr^.pInJournal, pg1 + Pgno(ii)) = 0) then
      begin
        rc := sqlite3PagerGet(pPgr, pg1 + Pgno(ii), @pPage, 0);
        if rc = SQLITE_OK then
        begin
          rc := pager_write(pPage);
          if (pPage^.flags and PGHDR_NEED_SYNC) <> 0 then needSync := 1;
          sqlite3PagerUnrefNotNull(pPage);
        end;
      end
      else
      begin
        pPage := sqlite3PagerLookup(pPgr, pg1 + Pgno(ii));
        if pPage <> nil then
        begin
          if (pPage^.flags and PGHDR_NEED_SYNC) <> 0 then needSync := 1;
          sqlite3PagerUnrefNotNull(pPage);
        end;
      end;
      Inc(ii);
    end;
    if (rc = SQLITE_OK) and (needSync <> 0) then
    begin
      ii := 0;
      while ii < nPage do
      begin
        pPage := sqlite3PagerLookup(pPgr, pg1 + Pgno(ii));
        if pPage <> nil then
        begin
          pPage^.flags := pPage^.flags or PGHDR_NEED_SYNC;
          sqlite3PagerUnrefNotNull(pPage);
        end;
        Inc(ii);
      end;
    end;
    pPgr^.doNotSpill := pPgr^.doNotSpill and (not SPILLFLAG_NOSYNC);
    Exit(rc);
  end;

  Result := pager_write(pHdr);
end;

{ pager.c: sqlite3PagerDontWrite -- mark page as not needing write }
procedure sqlite3PagerDontWrite(pPg: PDbPage);
var
  pHdr: PPgHdr;
  pPgr: PPager;
begin
  pHdr := PPgHdr(pPg);
  pPgr := pHdr^.pPager;
  if (pPgr^.tempFile = 0) and ((pHdr^.flags and PGHDR_DIRTY) <> 0) and
     (pPgr^.nSavepoint = 0) then
  begin
    pHdr^.flags := pHdr^.flags or PGHDR_DONT_WRITE;
    pHdr^.flags := pHdr^.flags and not PGHDR_WRITEABLE;
  end;
end;

{ pager.c: pager_incr_changecounter -- increment change counter (non-atomic mode) }
function pager_incr_changecounter(pPager: PPager; isDirectMode: i32): i32;
var
  rc: i32;
  pHdr: PPgHdr;
begin
  rc := SQLITE_OK;
  pHdr := nil;
  if (pPager^.changeCountDone = 0) and (pPager^.dbSize > 0) then
  begin
    rc := sqlite3PagerGet(pPager, 1, @pHdr, 0);
    if rc = SQLITE_OK then
    begin
      rc := sqlite3PagerWrite(pHdr);
      if rc = SQLITE_OK then
      begin
        pager_write_changecounter(pHdr);
        pPager^.changeCountDone := 1;
      end;
      sqlite3PagerUnref(pHdr);
    end;
  end;
  Result := rc;
  if isDirectMode = 0 then; { suppress unused warning }
end;

{ pager.c: sqlite3PagerSync -- sync the database file }
function sqlite3PagerSync(pPager: PPager; zSuper: PChar): i32;
var
  rc: i32;
  pArg: Pointer;
begin
  rc := SQLITE_OK;
  pArg := Pointer(zSuper);
  rc := sqlite3OsFileControl(pPager^.fd, SQLITE_FCNTL_SYNC, pArg);
  if rc = SQLITE_NOTFOUND then rc := SQLITE_OK;
  if (rc = SQLITE_OK) and (pPager^.noSync = 0) then
    rc := sqlite3OsSync(pPager^.fd, pPager^.syncFlags);
  Result := rc;
end;

{ pager.c: sqlite3PagerExclusiveLock -- obtain EXCLUSIVE lock }
function sqlite3PagerExclusiveLock(pPager: PPager): i32;
var
  rc: i32;
begin
  rc := pPager^.errCode;
  if rc = SQLITE_OK then
  begin
    if pagerUseWal(pPager) = 0 then
      rc := pager_wait_on_lock(pPager, EXCLUSIVE_LOCK);
  end;
  Result := rc;
end;

{ pager.c ~6465: sqlite3PagerCommitPhaseOne }
function sqlite3PagerCommitPhaseOne(pPager: PPager; zSuper: PChar;
  noSync: i32): i32;
label
  commit_phase_one_exit;
var
  rc       : i32;
  pList    : PPgHdr;
  pPageOne : PPgHdr;
begin
  rc := SQLITE_OK;
  pPageOne := nil;
  if pPager^.errCode <> 0 then Exit(pPager^.errCode);
  if pPager^.eState < PAGER_WRITER_CACHEMOD then Exit(SQLITE_OK);

  if pagerFlushOnCommit(pPager, 1) = 0 then
  begin
    Exit(SQLITE_OK);
  end;

  if pagerUseWal(pPager) <> 0 then
  begin
    { WAL commit path }
    pList := sqlite3PcacheDirtyList(pPager^.pPCache);
    if pList = nil then
    begin
      rc := sqlite3PagerGet(pPager, 1, @pPageOne, 0);
      pList := pPageOne;
      if pList <> nil then pList^.pDirty := nil;
    end;
    if (rc = SQLITE_OK) and (pList <> nil) then
      rc := pagerWalFrames(pPager, pList, pPager^.dbSize, 1);
    sqlite3PagerUnref(pPageOne);
    if rc = SQLITE_OK then
      sqlite3PcacheCleanAll(pPager^.pPCache);
  end
  else
  begin
    { Non-WAL rollback path }
    rc := pager_incr_changecounter(pPager, 0);
    if rc <> SQLITE_OK then goto commit_phase_one_exit;

    rc := writeSuperJournal(pPager, zSuper);
    if rc <> SQLITE_OK then goto commit_phase_one_exit;

    rc := syncJournal(pPager, 0);
    if rc <> SQLITE_OK then goto commit_phase_one_exit;

    pList := sqlite3PcacheDirtyList(pPager^.pPCache);
    rc := pager_write_pagelist(pPager, pList);
    if rc <> SQLITE_OK then goto commit_phase_one_exit;

    sqlite3PcacheCleanAll(pPager^.pPCache);

    if pPager^.dbSize > pPager^.dbFileSize then
    begin
      rc := pager_truncate(pPager, pPager^.dbSize);
      if rc <> SQLITE_OK then goto commit_phase_one_exit;
    end;

    if noSync = 0 then
      rc := sqlite3PagerSync(pPager, zSuper);
  end;

commit_phase_one_exit:
  if (rc = SQLITE_OK) and (pagerUseWal(pPager) = 0) then
    pPager^.eState := PAGER_WRITER_FINISHED;
  Result := rc;
end;

{ pager.c ~6702: sqlite3PagerCommitPhaseTwo }
function sqlite3PagerCommitPhaseTwo(pPager: PPager): i32;
var
  rc: i32;
begin
  if pPager^.errCode <> 0 then Exit(pPager^.errCode);
  Inc(pPager^.iDataVersion);

  if (pPager^.eState = PAGER_WRITER_LOCKED)
     and (pPager^.exclusiveMode <> 0)
     and (pPager^.journalMode = PAGER_JOURNALMODE_PERSIST) then
  begin
    pPager^.eState := PAGER_READER;
    Exit(SQLITE_OK);
  end;

  rc := pager_end_transaction(pPager, pPager^.setSuper, 1);
  Result := pagerSetError(pPager, rc);
end;

{ pager.c ~6768: sqlite3PagerRollback }
function sqlite3PagerRollback(pPager: PPager): i32;
var
  rc: i32;
  eState: i32;
begin
  rc := SQLITE_OK;
  if pPager^.eState = PAGER_ERROR then Exit(pPager^.errCode);
  if pPager^.eState <= PAGER_READER then Exit(SQLITE_OK);

  if pagerUseWal(pPager) <> 0 then
  begin
    rc := pagerRollbackWal(pPager);
    if rc = SQLITE_OK then
      rc := pager_end_transaction(pPager, 0, 0);
  end
  else if (isOpen(pPager^.jfd) = 0) or (pPager^.eState = PAGER_WRITER_LOCKED) then
  begin
    eState := pPager^.eState;
    rc := pager_end_transaction(pPager, 0, 0);
    if (pPager^.memDb = 0) and (eState > PAGER_WRITER_LOCKED) then
    begin
      pPager^.errCode := SQLITE_ABORT;
      pPager^.eState  := PAGER_ERROR;
      setGetterMethod(pPager);
      Exit(rc);
    end;
  end
  else
    rc := pager_playback(pPager, 0);

  Result := pagerSetError(pPager, rc);
end;

{ pager.c ~6965: pagerOpenSavepoint (internal) }
function pagerOpenSavepoint(pPager: PPager; nSavepoint: i32): i32;
var
  rc: i32;
  nCurrent: i32;
  ii: i32;
  aNew: PPagerSavepoint;
  p: PPagerSavepoint;
begin
  rc := SQLITE_OK;
  nCurrent := pPager^.nSavepoint;

  aNew := PPagerSavepoint(sqlite3Realloc(pPager^.aSavepoint,
                          SizeOf(PagerSavepoint) * nSavepoint));
  if aNew = nil then Exit(SQLITE_NOMEM);
  FillChar(PByte(aNew)[nCurrent * SizeOf(PagerSavepoint)],
           (nSavepoint - nCurrent) * SizeOf(PagerSavepoint), 0);
  pPager^.aSavepoint := aNew;

  ii := nCurrent;
  while ii < nSavepoint do
  begin
    p := PPagerSavepoint(PByte(aNew) + ii * SizeOf(PagerSavepoint));
    p^.nOrig := pPager^.dbSize;
    if (isOpen(pPager^.jfd) <> 0) and (pPager^.journalOff > 0) then
      p^.iOffset := pPager^.journalOff
    else
      p^.iOffset := JOURNAL_HDR_SZ(pPager);
    p^.iSubRec := pPager^.nSubRec;
    p^.pInSavepoint := sqlite3BitvecCreate(pPager^.dbSize);
    p^.bTruncateOnRelease := 1;
    if pagerUseWal(pPager) <> 0 then
      sqlite3WalSavepoint(pPager^.pWal, @p^.aWalData[0]);
    if p^.pInSavepoint = nil then Exit(SQLITE_NOMEM);
    pPager^.nSavepoint := ii + 1;
    Inc(ii);
  end;
  Result := rc;
end;

{ pager.c ~6965: sqlite3PagerOpenSavepoint }
function sqlite3PagerOpenSavepoint(pPager: PPager; nSavepoint: i32): i32;
begin
  if (nSavepoint > pPager^.nSavepoint) and (pPager^.useJournal <> 0) then
    Result := pagerOpenSavepoint(pPager, nSavepoint)
  else
    Result := SQLITE_OK;
end;

{ pager.c ~7007: sqlite3PagerSavepoint }
function sqlite3PagerSavepoint(pPager: PPager; op: i32; iSavepoint: i32): i32;
var
  rc: i32;
  nNew: i32;
  ii: i32;
  pRel: PPagerSavepoint;
  pSavepoint: PPagerSavepoint;
begin
  rc := pPager^.errCode;
  if rc = SQLITE_OK then
  begin
    if iSavepoint < pPager^.nSavepoint then
    begin
      nNew := iSavepoint + i32(i32(op = SAVEPOINT_ROLLBACK));
      ii := nNew;
      while ii < pPager^.nSavepoint do
      begin
        sqlite3BitvecDestroy(
          PPagerSavepoint(PByte(pPager^.aSavepoint) + ii * SizeOf(PagerSavepoint))^.pInSavepoint);
        Inc(ii);
      end;
      pPager^.nSavepoint := nNew;

      if op = SAVEPOINT_RELEASE then
      begin
        pRel := PPagerSavepoint(PByte(pPager^.aSavepoint) + nNew * SizeOf(PagerSavepoint));
        if (pRel^.bTruncateOnRelease <> 0) and (isOpen(pPager^.sjfd) <> 0) then
        begin
          if sqlite3JournalIsInMemory(pPager^.sjfd) <> 0 then
            sqlite3OsTruncate(pPager^.sjfd, (pPager^.pageSize + 4) * i64(pRel^.iSubRec));
          pPager^.nSubRec := pRel^.iSubRec;
        end;
      end
      else
      begin
        if nNew > 0 then
          pSavepoint := PPagerSavepoint(PByte(pPager^.aSavepoint) + (nNew - 1) * SizeOf(PagerSavepoint))
        else
          pSavepoint := nil;
        if (pSavepoint <> nil) and (pagerUseWal(pPager) <> 0) then
          rc := sqlite3WalSavepointUndo(pPager^.pWal, @pSavepoint^.aWalData[0]);
        if (rc = SQLITE_OK) and (isOpen(pPager^.jfd) <> 0) then
          rc := pagerPlaybackSavepoint(pPager, pSavepoint);
      end;
    end;
  end;
  Result := rc;
end;

{ pager.c: sqlite3PagerFlush -- flush unreferenced dirty pages }
function sqlite3PagerFlush(pPager: PPager): i32;
var
  rc: i32;
  pList: PPgHdr;
  pNext: PPgHdr;
begin
  rc := pPager^.errCode;
  if pPager^.memDb = 0 then
  begin
    pList := sqlite3PcacheDirtyList(pPager^.pPCache);
    while (rc = SQLITE_OK) and (pList <> nil) do
    begin
      pNext := pList^.pDirty;
      if pList^.nRef = 0 then
        rc := pagerStress(pPager, pList);
      pList := pNext;
    end;
  end;
  Result := rc;
end;

{ pager.c: sqlite3PagerTruncateImage }
procedure sqlite3PagerTruncateImage(pPager: PPager; nPage: Pgno);
begin
  pPager^.dbSize := nPage;
  sqlite3PcacheTruncate(pPager^.pPCache, nPage);
end;

{ pager.c: sqlite3PagerCacheStat -- cache stats accessor }
function sqlite3PagerCacheStat(pPager: PPager; eStat: i32; reset: i32): u64;
var
  idx: i32;
begin
  idx := eStat - SQLITE_DBSTATUS_CACHE_HIT;
  if idx < 0 then idx := 0;
  if idx > 3 then idx := 3;
  Result := pPager^.aStat[idx];
  if reset <> 0 then pPager^.aStat[idx] := 0;
end;

{ pager.c: sqlite3PagerMemUsed }
function sqlite3PagerMemUsed(pPager: PPager): i32;
var
  perPageSize: i32;
begin
  perPageSize := i32(pPager^.pageSize) + pPager^.nExtra
               + SizeOf(PgHdr) + 5 * SizeOf(Pointer);
  Result := perPageSize * sqlite3PcachePagecount(pPager^.pPCache)
           + i32(sqlite3MallocSize(pPager))
           + i32(pPager^.pageSize);
end;

{ pager.c ~7518: sqlite3PagerCheckpoint }
function sqlite3PagerCheckpoint(pPager: PPager; db: Pointer; eMode: i32;
                                xBusy: TxBusyCallback; pBusyArg: Pointer;
                                pnLog: PcInt; pnCkpt: PcInt): i32;
var
  rc: i32;
begin
  rc := SQLITE_OK;
  if pPager^.pWal <> nil then
    rc := sqlite3WalCheckpoint(pPager^.pWal, db, eMode,
          xBusy, pBusyArg,
          pPager^.walSyncFlags, pPager^.pageSize,
          Pu8(pPager^.pTmpSpace), pnLog, pnCkpt);
  Result := rc;
end;

{ pager.c ~7541: sqlite3PagerWalCallback }
function sqlite3PagerWalCallback(pPager: PPager): i32;
begin
  Result := sqlite3WalCallback(pPager^.pWal);
end;

{ pager.c ~7121: sqlite3PagerWalFile }
function sqlite3PagerWalFile(pPager: PPager): Psqlite3_file;
begin
  if pPager^.pWal <> nil then
    Result := sqlite3WalFile(pPager^.pWal)
  else
    Result := pPager^.jfd;
end;

{ updated pagerStress -- now calls syncJournal and pager_write_pagelist }
{ NOTE: the stub above is replaced by this full implementation; forward-declared above }

{ ===========================================================================
  Phase 8.7 — accessors required by backup.c
  =========================================================================== }

{ pager.c:1497 }
function sqlite3PagerGetJournalMode(pPager: PPager): i32;
begin
  Result := i32(pPager^.journalMode);
end;

{ pager.c:7838 — &pPager->pBackup }
function sqlite3PagerBackupPtr(pPager: PPager): PPointer;
begin
  Result := PPointer(@pPager^.pBackup);
end;

{ pager.c:6857 — drop every page from the cache.  Used after a failed
  copy in sqlite3BtreeCopyFile to discard any half-copied destination
  pages so a future query re-reads from disk. }
procedure sqlite3PagerClearCache(pPager: PPager);
begin
  if pPager^.pPCache <> nil then
    sqlite3PcacheClear(pPager^.pPCache);
end;

{ pager.c:7460 — sqlite3PagerOkToChangeJournalMode.
  Return TRUE iff it is currently safe to change the journal mode.
  The journal mode cannot be changed once we have started writing. }
function sqlite3PagerOkToChangeJournalMode(pPager: PPager): i32;
begin
  if pPager^.eState >= PAGER_WRITER_CACHEMOD then begin Result := 0; Exit; end;
  if (isOpen(pPager^.jfd) <> 0) and (pPager^.journalOff > 0) then
  begin
    Result := 0;
    Exit;
  end;
  Result := 1;
end;

{ pager.c:7473 — sqlite3PagerJournalSizeLimit.
  Get or set the persistent-journal size limit.  iLimit = -1 disables. }
function sqlite3PagerJournalSizeLimit(pPager: PPager; iLimit: i64): i64;
begin
  if iLimit >= -1 then
  begin
    pPager^.journalSizeLimit := iLimit;
    sqlite3WalLimit(pPager^.pWal, iLimit);
  end;
  Result := pPager^.journalSizeLimit;
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
