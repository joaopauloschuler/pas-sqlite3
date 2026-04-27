{$I passqlite3.inc}
unit passqlite3util;

{
  Phase 2 — Utilities port for SQLite 3.53.0.

  Source files ported:
    global.c   -- sqlite3UpperToLower, sqlite3CtypeMap, sqlite3GlobalConfig
    util.c     -- string utils, varint codec, big-endian accessors, atof/atoi
    hash.c     -- generic string-keyed hash table
    random.c   -- ChaCha20 PRNG (sqlite3_randomness)
    bitvec.c   -- space-efficient bitvector
    status.c   -- sqlite3_status() counters
    malloc.c   -- malloc dispatch layer
    mem0.c     -- no-op memory backend stub
    mem1.c     -- system malloc backend
    fault.c    -- benign malloc hooks
    printf.c   -- sqlite3_mprintf/sqlite3_snprintf (via libc vasprintf + extensions)
    utf.c      -- UTF-8/16 read functions (VdbeMemTranslate stubbed — Phase 6)

  Porting conventions follow passqlite3os.pas.
  NO Pascal Boolean — use i32/u8 with 0/1.
}

interface

uses
  passqlite3types,
  passqlite3internal,
  passqlite3os,
  BaseUnix,
  UnixType,
  SysUtils,
  Math;

{ ============================================================
  Forward / opaque types for not-yet-ported structs
  ============================================================ }

type
  Psqlite3db  = Pointer;   { forward: sqlite3 connection handle }
  PPsqlite3db = ^Psqlite3db;
  PParse      = Pointer;   { forward: Parse struct — Phase 6 }

{ ============================================================
  Section 0: Extra constants
  ============================================================ }

const
  SQLITE_NOMEM_BKPT = SQLITE_NOMEM;  { alias used by internal code }

  SQLITE_STATUS_MEMORY_USED        = 0;
  SQLITE_STATUS_PAGECACHE_USED     = 1;
  SQLITE_STATUS_PAGECACHE_OVERFLOW = 2;
  SQLITE_STATUS_SCRATCH_USED       = 3;  { Unused }
  SQLITE_STATUS_SCRATCH_OVERFLOW   = 4;  { Unused }
  SQLITE_STATUS_MALLOC_SIZE        = 5;
  SQLITE_STATUS_PARSER_STACK       = 6;
  SQLITE_STATUS_PAGECACHE_SIZE     = 7;
  SQLITE_STATUS_SCRATCH_SIZE       = 8;  { Unused }
  SQLITE_STATUS_MALLOC_COUNT       = 9;

  SQLITE_UTF8    = 1;
  SQLITE_UTF16LE = 2;
  SQLITE_UTF16BE = 3;
  SQLITE_UTF16   = 4;

  BITVEC_SZ    = 512;

{ ============================================================
  Section 1: sqlite3_mem_methods and sqlite3_mutex_methods types
  (parallel to sqliteInt.h; used in TSqlite3Config)
  ============================================================ }

type
  { sqlite3_mem_methods — allocator function table }
  Tsqlite3_mem_methods = record
    xMalloc:   function(sz: i32): Pointer; cdecl;
    xFree:     procedure(p: Pointer); cdecl;
    xRealloc:  function(p: Pointer; sz: i32): Pointer; cdecl;
    xSize:     function(p: Pointer): i32; cdecl;
    xRoundup:  function(sz: i32): i32; cdecl;
    xInit:     function(pAppData: Pointer): i32; cdecl;
    xShutdown: procedure(pAppData: Pointer); cdecl;
    pAppData:  Pointer;
  end;

  { sqlite3_mutex_methods — mutex function table }
  Tsqlite3_mutex_methods = record
    xMutexInit:    function: i32; cdecl;
    xMutexEnd:     function: i32; cdecl;
    xMutexAlloc:   function(id: i32): Psqlite3_mutex; cdecl;
    xMutexFree:    procedure(p: Psqlite3_mutex); cdecl;
    xMutexEnter:   procedure(p: Psqlite3_mutex); cdecl;
    xMutexTry:     function(p: Psqlite3_mutex): i32; cdecl;
    xMutexLeave:   procedure(p: Psqlite3_mutex); cdecl;
    xMutexHeld:    function(p: Psqlite3_mutex): i32; cdecl;
    xMutexNotheld: function(p: Psqlite3_mutex): i32; cdecl;
  end;

{ ============================================================
  Section 1.5: Page cache interface types (pcache.h / sqlite3.h)
  Added in Phase 3.A.
  ============================================================ }

const
  SQLITE_CONFIG_PAGECACHE = 7;   { sqlite3_config(SQLITE_CONFIG_PAGECACHE, pBuf, sz, N) }
  SQLITE_CONFIG_PCACHE2   = 14;  { sqlite3_config(SQLITE_CONFIG_PCACHE2, &methods2) }

type
  Psqlite3_pcache_page = ^sqlite3_pcache_page;
  { sqlite3_pcache_page: base-class for a single cache line (sqlite3.h §8455) }
  sqlite3_pcache_page = record
    pBuf:   Pointer;   { Page data buffer — szPage bytes }
    pExtra: Pointer;   { Extra buffer — szExtra bytes; PgHdr lives here }
  end;

  Tsqlite3_pcache_methods2 = record
    iVersion:   i32;
    pArg:       Pointer;
    xInit:      function(pArg: Pointer): i32;
    xShutdown:  procedure(pArg: Pointer);
    xCreate:    function(szPage: i32; szExtra: i32; bPurgeable: i32): Pointer;
    xCachesize: procedure(p: Pointer; nCachesize: i32);
    xPagecount: function(p: Pointer): i32;
    xFetch:     function(p: Pointer; key: u32; createFlag: i32): Psqlite3_pcache_page;
    xUnpin:     procedure(p: Pointer; pPage: Psqlite3_pcache_page; discard: i32);
    xRekey:     procedure(p: Pointer; pPage: Psqlite3_pcache_page; oldKey: u32; newKey: u32);
    xTruncate:  procedure(p: Pointer; iLimit: u32);
    xDestroy:   procedure(p: Pointer);
    xShrink:    procedure(p: Pointer);
  end;
  PTsqlite3_pcache_methods2 = ^Tsqlite3_pcache_methods2;

  PPsqlite3_pcache_page = ^Psqlite3_pcache_page;

{ ============================================================
  Section 2: Global config record (TSqlite3Config / sqlite3Config)
  Only Phase-2-needed fields are fully ported; the rest are TBD.
  ============================================================ }

type
  TSqlite3Config = record
    bMemstat:         i32;    { True to enable memory status }
    bCoreMutex:       i32;    { True to enable core mutexing }
    bFullMutex:       i32;    { True to enable full mutexing }
    bOpenUri:         i32;    { True to interpret filenames as URIs }
    bUseCis:          i32;    { Use covering index scan }
    bSmallMalloc:     i32;    { Avoid large memory allocations if true }
    bExtraSchemaChecks: i32;  { Verify type,name,tbl_name in schema }
    mxStrlen:         i32;    { Maximum string length }
    neverCorrupt:     i32;    { Database is always well-formed }
    szLookaside:      i32;    { Default lookaside buffer size }
    nLookaside:       i32;    { Default lookaside buffer count }
    nStmtSpill:       i32;    { Stmt journal spill-to-disk threshold }
    m:                Tsqlite3_mem_methods;   { Low-level memory allocator }
    mutex:            Tsqlite3_mutex_methods; { Low-level mutex interface }
    pcache2:          Tsqlite3_pcache_methods2; { Pluggable page cache module }
    pPage:            Pointer;    { Page cache memory }
    szPage:           i32;        { Size of each page in pPage[] }
    nPage:            i32;        { Number of pages in pPage[] }
    mxParserStack:    i32;        { LIMIT_PARSER_STACK }
    sharedCacheEnabled: i32;      { true if shared-cache mode enabled }
    szPma:            u32;        { Maximum Sorter PMA size }
    isInit:           i32;        { True after initialization has finished }
    inProgress:       i32;        { True while initialization in progress }
    isMutexInit:      i32;        { True after mutexes are initialized }
    isMallocInit:     i32;        { True after malloc is initialized }
    isPCacheInit:     i32;        { True after pcache_init() }
    nRefInitMutex:    i32;        { Number of users of pInitMutex }
    pInitMutex:       Psqlite3_mutex; { Mutex used by sqlite3_initialize() }
    xLog:             Pointer;    { Function for logging — TBD }
    pLogArg:          Pointer;    { First argument to xLog() }
    mxMemdbSize:      i64;        { Default max memdb size }
    xTestCallback:    Pointer;    { Invoked by sqlite3FaultSim() }
    bLocaltimeFault:  i32;        { True to fail localtime() calls }
    xAltLocaltime:    Pointer;    { Alternative localtime() callback }
    iOnceResetThreshold: i32;     { When to reset OP_Once counters }
    szSorterRef:      u32;        { Min size in bytes to use sorter-refs }
    iPrngSeed:        u32;        { Alternative fixed seed for the PRNG }
    { TBD fields: pHeap,nHeap,mnHeap,mxHeap,szMmap,mxMmap (Phase 3-4) }
    pHeap:            Pointer;
    nHeap:            i32;
    mnHeap:           i32;
    mxHeap:           i32;
    szMmap:           i64;
    mxMmap:           i64;
  end;

{ ============================================================
  Section 3: Hash table types  (hash.c)
  ============================================================ }

type
  { _ht bucket used in the hash array }
  THashBucket = record
    count: u32;
    chain: Pointer; { ^THashElem — forward ref resolved in impl }
  end;
  PHashBucket = ^THashBucket;

  { Hash element — a doubly-linked list node }
  THashElem = record
    next, prev: Pointer;  { ^THashElem }
    data:       Pointer;
    pKey:       PChar;
    h:          u32;
  end;
  PHashElem = ^THashElem;

  { The Hash object itself }
  THash = record
    htsize: u32;          { Number of buckets in the hash table }
    count:  u32;          { Number of entries in this table }
    first:  PHashElem;    { First element of the hash chain }
    ht:     PHashBucket;  { the hash table }
  end;
  PHash = ^THash;

{ ============================================================
  Section 3b: sqlite3 connection struct and dependencies
  (sqliteInt.h: BusyHandler, Lookaside, Schema, Db, Savepoint, sqlite3)
  Added Phase 5.4 — needed by the VDBE executor.
  Field order matches C struct exactly for correctness.
  Opaque Pointer used for cross-unit types (PBtree, PVdbe, Parse, etc.)
  ============================================================ }

const
  SQLITE_N_LIMIT = 13;  { SQLITE_LIMIT_PARSER_DEPTH+1 = 12+1 }

  { Flags for sqlite3.flags (u64) }
  SQLITE_WriteSchema    = u64($00000001);
  SQLITE_LegacyFileFmt  = u64($00000002);
  SQLITE_FullColNames   = u64($00000004);
  SQLITE_FullFSync      = u64($00000008);
  SQLITE_CkptFullFSync  = u64($00000010);
  SQLITE_CacheSpill     = u64($00000020);
  SQLITE_ShortColNames  = u64($00000040);
  SQLITE_TrustedSchema  = u64($00000080);
  SQLITE_NullCallback   = u64($00000100);
  SQLITE_IgnoreChecks   = u64($00000200);
  SQLITE_RecTriggers    = u64($00002000);
  SQLITE_ForeignKeys    = u64($00004000);
  SQLITE_AutoIndex      = u64($00008000);
  SQLITE_EnableTrigger  = u64($00040000);
  SQLITE_DeferFKs       = u64($00080000);
  SQLITE_QueryOnly      = u64($00100000);
  SQLITE_CellSizeCk     = u64($00200000);
  SQLITE_CorruptRdOnly  = u64($02000000);  { internal flag }
  SQLITE_VdbeListing    = u64($0000000100000000);
  SQLITE_VdbeTrace      = u64($0000000200000000);
  SQLITE_VdbeEQP        = u64($0000001000000000);
  SQLITE_SqlTrace       = u64($0000000400000000);

  { Flags for sqlite3.mDbFlags }
  DBFLAG_SchemaChange   = $0002;
  DBFLAG_PreferBuiltin  = $0008;
  DBFLAG_Vacuum         = $0100;
  DBFLAG_VacuumInto     = $0200;

  { Schema flags }
  DB_SchemaLoaded  = $0001;
  DB_UnresetViews  = $0002;
  DB_ResetWanted   = $0008;

  { mTrace flags }
  SQLITE_TRACE_STMT    = $01;
  SQLITE_TRACE_PROFILE = $02;
  SQLITE_TRACE_ROW     = $04;
  SQLITE_TRACE_CLOSE   = $08;
  SQLITE_TRACE_LEGACY  = $40;

  { Conflict resolution actions }
  OE_None      = 0;
  OE_Rollback  = 1;
  OE_Abort     = 2;
  OE_Fail      = 3;
  OE_Ignore    = 4;
  OE_Replace   = 5;
  OE_Update    = 6;
  OE_Restrict  = 7;
  OE_SetNull   = 8;
  OE_SetDflt   = 9;
  OE_Cascade   = 10;
  OE_Default   = 11;

  { OPFLAG values (vdbe.c / sqliteInt.h) — exact values from sqliteInt.h }
  OPFLAG_NCHANGE       = $01;  { OP_Insert/Delete P5/P2: update db->nChange }
  OPFLAG_NOCHNG        = $01;  { OP_VColumn nochange for UPDATE }
  OPFLAG_EPHEM         = $01;  { OP_Column: ephemeral output ok }
  OPFLAG_ISUPDATE      = $04;  { OP_Insert is an SQL UPDATE }
  OPFLAG_AUXDELETE     = $04;  { OP_Delete: index in a DELETE op }
  OPFLAG_APPEND        = $08;  { likely to be an append }
  OPFLAG_FORDELETE     = $08;  { OP_Open: use BTREE_FORDELETE }
  OPFLAG_USESEEKRESULT = $10;  { try to avoid seek in BtreeInsert }
  OPFLAG_P2ISREG       = $10;  { P2 to OP_Open** is a register number }
  OPFLAG_LASTROWID     = $20;  { set to update db->lastRowid }
  OPFLAG_ISNOOP        = $40;  { OP_Delete does pre-update-hook only }
  OPFLAG_LENGTHARG     = $40;  { OP_Column only used for length() }
  OPFLAG_TYPEOFARG     = $80;  { OP_Column only used for typeof() }
  OPFLAG_BYTELENARG    = $C0;  { OP_Column only for octet_length() }
  OPFLAG_BULKCSR       = $01;  { OP_Open** used to open bulk cursor }
  OPFLAG_SEEKEQ        = $02;  { OP_Open** cursor uses EQ seek only }
  OPFLAG_SAVEPOSITION  = $02;  { OP_Delete/Insert: save cursor pos }
  OPFLAG_PREFORMAT     = $80;  { OP_Insert uses preformatted cell }
  OPFLAG_NOCHNG_MAGIC  = $6D;  { OP_MakeRecord: serialtype 10 is ok }
  OPFLAG_PERMUTE       = $01;  { OP_Compare: use the permutation }

  { BTREE cursor flags (btree.h) }
  BTREE_WRCSR    = $00000004;
  BTREE_BULKLOAD = $00000001;
  BTREE_SEEK_EQ  = $00000002;
  BTREE_FORDELETE= $00000008;

type
  { BusyHandler (sqliteInt.h:1216) }
  TBusyHandler = record
    xBusyHandler : function(p: Pointer; n: i32): i32; cdecl;
    pBusyArg     : Pointer;
    nBusy        : i32;
  end;
  PBusyHandler = ^TBusyHandler;

  { LookasideSlot (sqliteInt.h:1606) }
  PLookasideSlot = ^TLookasideSlot;
  TLookasideSlot = record
    pNext: PLookasideSlot;
  end;

  { Lookaside (sqliteInt.h:1587) }
  TLookaside = record
    bDisable  : u32;
    sz        : u16;
    szTrue    : u16;
    bMalloced : u8;
    nSlot     : u32;
    anStat    : array[0..2] of u32;
    pInit     : PLookasideSlot;
    pFree     : PLookasideSlot;
    pSmallInit: PLookasideSlot;
    pSmallFree: PLookasideSlot;
    pMiddle   : Pointer;
    pStart    : Pointer;
    pEnd      : Pointer;
    pTrueEnd  : Pointer;
  end;
  PLookaside = ^TLookaside;

  { Schema (sqliteInt.h:1499) }
  PSchema = ^TSchema;
  TSchema = record
    schema_cookie : i32;
    iGeneration   : i32;
    tblHash       : THash;
    idxHash       : THash;
    trigHash      : THash;
    fkeyHash      : THash;
    pSeqTab       : Pointer;  { PTable — opaque until Phase 6 }
    file_format   : u8;
    enc           : u8;
    schemaFlags   : u16;
    cache_size    : i32;
  end;

  { Db (sqliteInt.h:1474) }
  PDb = ^TDb;
  TDb = record
    zDbSName    : PAnsiChar;
    pBt         : Pointer;   { PBtree — opaque (btree uses util, circular) }
    safety_level: u8;
    bSyncSet    : u8;
    pSchema     : PSchema;
  end;

  { Savepoint (sqliteInt.h:2190) }
  PSavepoint = ^TSavepoint;
  TSavepoint = record
    zName            : PAnsiChar;
    nDeferredCons    : i64;
    nDeferredImmCons : i64;
    pNext            : PSavepoint;
  end;

  { sqlite3InitInfo sub-struct (sqliteInt.h:1700) }
  Tsqlite3InitInfo = record
    newTnum  : u32;   { Pgno }
    iDb      : u8;
    busy     : u8;
    flags    : u8;    { orphanTrigger:1, imposterTable:2, reopenMemdb:1 packed }
    azInit   : ^PAnsiChar;
  end;

  { sqlite3 trace union (sqliteInt.h:1716) }
  Tsqlite3TraceUnion = record
    case Boolean of
      False: (xLegacy: procedure(p: Pointer; s: PAnsiChar); cdecl);
      True:  (xV2: function(n: u32; p: Pointer; x: Pointer; y: Pointer): i32; cdecl);
  end;

  { DbClientData stub }
  TDbClientData = record
    pData: Pointer;
    xDestroyData: procedure(p: Pointer); cdecl;
    pNext: Pointer;
  end;
  PDbClientData = ^TDbClientData;

  { Full sqlite3 connection struct (sqliteInt.h:1662)
    Field order matches C struct for the oracle build configuration:
      NOT SQLITE_OMIT_DEPRECATED (xProfile present)
      NOT SQLITE_OMIT_VIRTUALTABLE (nVTrans etc. present)
      NOT SQLITE_OMIT_WAL (xWalCallback present)
      NOT SQLITE_OMIT_PROGRESS_CALLBACK (xProgress present)
      NOT SQLITE_OMIT_AUTHORIZATION (xAuth present)
      NOT SQLITE_ENABLE_PREUPDATE_HOOK (pPreUpdate NOT present)
      NOT SQLITE_ENABLE_SETLK_TIMEOUT (setlkTimeout NOT present)
      NOT SQLITE_ENABLE_UNLOCK_NOTIFY (pBlockingConnection NOT present) }
  PTsqlite3 = ^Tsqlite3;
  Tsqlite3 = record
    pVfs           : Pointer;          { sqlite3_vfs* }
    pVdbe          : Pointer;          { Vdbe* — opaque (circular) }
    pDfltColl      : Pointer;          { CollSeq* — opaque }
    mutex          : Pointer;          { sqlite3_mutex* }
    aDb            : PDb;              { All backends (dynamic array) }
    nDb            : i32;              { Number of backends currently in use }
    mDbFlags       : u32;
    flags          : u64;
    lastRowid      : i64;
    szMmap         : i64;
    nSchemaLock    : u32;
    openFlags      : u32;
    errCode        : i32;
    errByteOffset  : i32;
    errMask        : i32;
    iSysErrno      : i32;
    dbOptFlags     : u32;
    enc            : u8;
    autoCommit     : u8;
    temp_store     : u8;
    mallocFailed   : u8;
    bBenignMalloc  : u8;
    dfltLockMode   : u8;
    nextAutovac    : Int8;
    suppressErr    : u8;
    vtabOnConflict : u8;
    isTransactionSavepoint : u8;
    mTrace         : u8;
    noSharedCache  : u8;
    nSqlExec       : u8;
    eOpenState     : u8;
    nFpDigit       : u8;
    nextPagesize   : i32;
    nChange        : i64;
    nTotalChange   : i64;
    aLimit         : array[0..SQLITE_N_LIMIT-1] of i32;
    nMaxSorterMmap : i32;
    init           : Tsqlite3InitInfo;
    nVdbeActive    : i32;
    nVdbeRead      : i32;
    nVdbeWrite     : i32;
    nVdbeExec      : i32;
    nVDestroy      : i32;
    nExtension     : i32;
    aExtension     : ^Pointer;
    trace          : Tsqlite3TraceUnion;
    pTraceArg      : Pointer;
    xProfile       : Pointer;          { profiling callback }
    pProfileArg    : Pointer;
    pCommitArg     : Pointer;
    xCommitCallback: function(p: Pointer): i32; cdecl;
    pRollbackArg   : Pointer;
    xRollbackCallback: procedure(p: Pointer); cdecl;
    pUpdateArg     : Pointer;
    xUpdateCallback: Pointer;
    pAutovacPagesArg: Pointer;
    xAutovacDestr  : procedure(p: Pointer); cdecl;
    xAutovacPages  : Pointer;
    pParse         : Pointer;          { PParse — opaque }
    xWalCallback   : Pointer;
    pWalArg        : Pointer;
    xCollNeeded    : Pointer;
    xCollNeeded16  : Pointer;
    pCollNeededArg : Pointer;
    pErr           : Pointer;          { sqlite3_value* }
    u1             : record
      case Boolean of
        False: (isInterrupted: i32);   { volatile in C; i32 here }
        True:  (notUsed1: Double);
    end;
    lookaside      : TLookaside;
    xAuth          : Pointer;          { sqlite3_xauth — authorization callback }
    pAuthArg       : Pointer;
    xProgress      : function(p: Pointer): i32; cdecl;
    pProgressArg   : Pointer;
    nProgressOps   : u32;
    nVTrans        : i32;
    aModule        : THash;
    pVtabCtx       : Pointer;
    aVTrans        : ^Pointer;
    pDisconnect    : Pointer;
    aFunc          : THash;
    aCollSeq       : THash;
    busyHandler    : TBusyHandler;
    aDbStatic      : array[0..1] of TDb;
    pSavepoint     : PSavepoint;
    nAnalysisLimit : i32;
    busyTimeout    : i32;
    nSavepoint     : i32;
    nStatement     : i32;
    nDeferredCons  : i64;
    nDeferredImmCons: i64;
    pnBytesFreed   : Pi32;
    pDbData        : PDbClientData;
    nSpill         : u64;
  end;

{ ============================================================
  Section 4: Bitvec type  (bitvec.c)
  ============================================================ }

const
  BITVEC_USIZE = ((BITVEC_SZ - (3*SizeOf(u32))) div SizeOf(Pointer)) * SizeOf(Pointer);
  BITVEC_TELEM_SIZE = 1; { sizeof(u8) }
  BITVEC_SZELEM = 8;
  BITVEC_NELEM = BITVEC_USIZE div BITVEC_TELEM_SIZE;
  BITVEC_NBIT  = BITVEC_NELEM * BITVEC_SZELEM;
  BITVEC_NINT  = BITVEC_USIZE div 4; { sizeof(u32) }
  BITVEC_MXHASH = BITVEC_NINT div 2;
  BITVEC_NPTR  = BITVEC_USIZE div SizeOf(Pointer);

type
  PBitvec = ^TBitvec;
  TBitvecUnion = record
    case byte of
      0: (aBitmap: array[0..BITVEC_NELEM-1] of u8);
      1: (aHash:   array[0..BITVEC_NINT-1] of u32);
      2: (apSub:   array[0..BITVEC_NPTR-1] of PBitvec);
  end;
  TBitvec = record
    iSize:    u32;
    nSet:     u32;
    iDivisor: u32;
    u:        TBitvecUnion;
  end;

{ ============================================================
  Section 5: Status type  (status.c)
  ============================================================ }

type
  sqlite3StatValueType = i64;
  Tsqlite3StatType = record
    nowValue: array[0..9] of sqlite3StatValueType;
    mxValue:  array[0..9] of sqlite3StatValueType;
  end;

{ ============================================================
  Section 6: PRNG state  (random.c)
  ============================================================ }

type
  Tsqlite3PrngType = record
    s:   array[0..15] of u32;  { 64 bytes of chacha20 state }
    out_: array[0..63] of u8;  { Output bytes }
    n:   u8;                   { Output bytes remaining }
  end;

{ ============================================================
  Section 7: malloc_usable_size (mem1.c / Linux)
  ============================================================ }

function malloc_usable_size(p: Pointer): csize_t;
  external 'c' name 'malloc_usable_size';

{ ============================================================
  Exported globals
  ============================================================ }

var
  sqlite3UpperToLower: array[0..273] of u8;
  sqlite3CtypeMap:     array[0..255] of u8;
  sqlite3GlobalConfig: TSqlite3Config;

{ ============================================================
  Exported function declarations
  ============================================================ }

{ Character classification (inline wrappers — from sqliteInt.h macros) }
function sqlite3Isspace(x: u8): i32; inline;
function sqlite3Isalnum(x: u8): i32; inline;
function sqlite3Isalpha(x: u8): i32; inline;
function sqlite3Isdigit(x: u8): i32; inline;
function sqlite3Isxdigit(x: u8): i32; inline;
function sqlite3Isupper(x: u8): i32; inline;
function sqlite3Islower(x: u8): i32; inline;
function sqlite3Toupper(x: u8): u8; inline;
function sqlite3Tolower(x: u8): u8; inline;

{ String utilities (util.c) }
function  sqlite3HexToInt(h: i32): u8; inline;
function  sqlite3HexToBlob(db: Psqlite3db; z: PAnsiChar; n: i32): Pointer;
function  sqlite3Strlen30(z: PChar): i32;
function  sqlite3Strlen30NN(z: PChar): i32;
function  sqlite3StrICmp(zLeft, zRight: PChar): i32;
function  sqlite3_strnicmp(zLeft, zRight: PChar; N: i32): i32;
function  sqlite3StrIHash(z: PChar): u8;
function  sqlite3AtoF(zIn: PChar; out pResult: Double): i32;
function  sqlite3Atoi64(zNum: PChar; out pNum: i64; length: i32; enc: u8): i32;
function  sqlite3Int64ToText(v: i64; zOut: PChar): i32;
function  sqlite3DecOrHexToI64(z: PChar; out pOut: i64): i32;

{ Big-endian 4-byte accessors (util.c) }
function  sqlite3Get4byte(p: Pu8): u32;
procedure sqlite3Put4byte(p: Pu8; v: u32);

{ Varint codec (util.c) }
function sqlite3PutVarint(p: Pu8; v: u64): i32;
function sqlite3GetVarint(p: Pu8; out v: u64): u8;
function sqlite3GetVarint32(p: Pu8; out v: u32): u8;
function sqlite3VarintLen(v: u64): i32;

{ Hash table (hash.c) }
procedure sqlite3HashInit(pNew: PHash);
procedure sqlite3HashClear(pH: PHash);
function  sqlite3HashFind(pH: PHash; pKey: PChar): Pointer;
function  sqlite3HashInsert(pH: PHash; pKey: PChar; data: Pointer): Pointer;

{ PRNG (random.c) }
procedure sqlite3_randomness(N: i32; pBuf: Pointer);
procedure sqlite3PrngSaveState;
procedure sqlite3PrngRestoreState;

{ Local: VFS randomness helper }
function sqlite3OsRandomness(pVfs: Pointer; nByte: i32; zBufOut: PChar): i32;

{ Bitvec (bitvec.c) }
function  sqlite3BitvecCreate(iSize: u32): PBitvec;
function  sqlite3BitvecTest(p: PBitvec; i: u32): i32;
function  sqlite3BitvecTestNotNull(p: PBitvec; i: u32): i32;
function  sqlite3BitvecSet(p: PBitvec; i: u32): i32;
procedure sqlite3BitvecClear(p: PBitvec; i: u32; pBuf: Pointer);
procedure sqlite3BitvecDestroy(p: PBitvec);
function  sqlite3BitvecSize(p: PBitvec): u32;

{ Status (status.c) }
function  sqlite3StatusValue(op: i32): i64;
procedure sqlite3StatusUp(op: i32; N: i32);
procedure sqlite3StatusDown(op: i32; N: i32);
procedure sqlite3StatusHighwater(op: i32; X: i32);
function  sqlite3_status64(op: i32; pCurrent: Pi64; pHighwater: Pi64;
            resetFlag: i32): i32;
function  sqlite3_status(op: i32; pCurrent: Pi32; pHighwater: Pi32;
            resetFlag: i32): i32;

{ Malloc layer (malloc.c + mem1.c) }
function  sqlite3MallocSize(p: Pointer): i32;
function  sqlite3Malloc(n: i32): Pointer;
function  sqlite3MallocZero64(n: u64): Pointer;
function  sqlite3DbMalloc(db: Psqlite3db; n: i32): Pointer;
function  sqlite3DbMallocZero(db: Psqlite3db; n: u64): Pointer;
function  sqlite3DbMallocRaw(db: Psqlite3db; n: u64): Pointer;
function  sqlite3DbMallocRawNN(db: Psqlite3db; n: u64): Pointer;
procedure sqlite3DbFree(db: Psqlite3db; p: Pointer);
procedure sqlite3DbFreeNN(db: Psqlite3db; p: Pointer);
function  sqlite3DbStrDup(db: Psqlite3db; z: PChar): PChar;
function  sqlite3DbStrNDup(db: Psqlite3db; z: PChar; n: u64): PChar;
function  sqlite3DbRealloc(db: Psqlite3db; p: Pointer; n: u64): Pointer;
function  sqlite3DbMallocSize(db: Psqlite3db; p: Pointer): i32;
function  sqlite3DbReallocOrFree(db: Psqlite3db; p: Pointer; n: u64): Pointer;
procedure sqlite3OomFault(db: Psqlite3db);
procedure sqlite3OomClear(db: Psqlite3db);
function  sqlite3ApiExit(db: Psqlite3db; rc: i32): i32;
procedure sqlite3MemSetDefault;
function  sqlite3MallocInit: i32;
procedure sqlite3MallocEnd;
function  sqlite3MallocMutex: Psqlite3_mutex;
function  sqlite3_memory_used: i64;
function  sqlite3HeapNearlyFull: i32;

{ Reference-counted string/blob (RCStr) — printf.c.
  An RCStr is a libc-malloc'd buffer prefixed by an 8-byte refcount header.
  The pointer returned to the caller addresses the payload (header is at
  z - SizeOf(TRCStr)).  sqlite3RCStrUnref is cdecl so it can be passed
  directly to sqlite3_result_text* as the xDel destructor. }
function  sqlite3RCStrNew(N: u64): PAnsiChar;
function  sqlite3RCStrRef(z: PAnsiChar): PAnsiChar;
procedure sqlite3RCStrUnref(z: Pointer); cdecl;
function  sqlite3RCStrResize(z: PAnsiChar; N: u64): PAnsiChar;

{ Fault / benign malloc hooks (fault.c) }
procedure sqlite3BenignMallocHooks(xBegin, xEnd: Pointer);
procedure sqlite3BeginBenignMalloc;
procedure sqlite3EndBenignMalloc;

{ Fault-sim (util.c) }
function sqlite3FaultSim(iTest: i32): i32;

{ printf (printf.c — implemented via libc vasprintf + extensions) }
function sqlite3_vmprintf(zFormat: PChar; va: Pointer): PChar; cdecl;
function sqlite3_mprintf(zFormat: PChar): PChar; cdecl;
function sqlite3_vsnprintf(n: i32; zBuf: PChar; zFormat: PChar; va: Pointer): PChar; cdecl;
function sqlite3_snprintf(n: i32; zBuf: PChar; zFormat: PChar): PChar; cdecl;

{ UTF utilities (utf.c) }
function sqlite3Utf8Read(pIn: PPChar): u32;
function sqlite3Utf8ReadLimited(z: Pu8; n: i32; out piOut: u32): i32;
function sqlite3Utf8CharLen(z: PChar; nByte: i32): i32;
function sqlite3AppendOneUtf8Character(zOut: PChar; v: u32): i32;

{ Config (main.c §sqlite3_config — minimal Phase 3 stub) }
function  sqlite3_config(op: i32; pArg: Pointer): i32; overload;

{ Pragma/URI helpers (pragma.c, main.c) }
function sqlite3GetBoolean(z: PChar; dflt: u8): u8;
function sqlite3_uri_parameter(zFilename: PChar; zParam: PChar): PChar;
function sqlite3_uri_boolean(zFilename: PChar; zParam: PChar; bDflt: i32): i32;
function sqlite3Atoi(z: PChar): i32;

{ Alignment helpers (used by pcache and btree) }
function ROUND8(n: SizeInt): SizeInt; inline;
function ROUNDDOWN8(n: SizeInt): SizeInt; inline;
function SQLITE_WITHIN(p, pStart, pEnd: Pointer): Boolean; inline;

{ String helpers (util.c) }
procedure sqlite3Dequote(z: PAnsiChar);
function  sqlite3DbSpanDup(db: Psqlite3db; zStart: PAnsiChar; zEnd: PAnsiChar): PAnsiChar;
procedure sqlite3DbNNFreeNN(db: Psqlite3db; p: Pointer);
function  sqlite3GetInt32(zNum: PAnsiChar; pValue: Pi32): i32;
function  sqlite3GetUInt32(z: PAnsiChar; pI: Pu32): i32;

{ Pcache1 mutex getter (set by pcache1Init) }
function  sqlite3Pcache1Mutex: Psqlite3_mutex;

var
  gPcache1Mutex: Psqlite3_mutex = nil;  { set by pcache1Init — interface-visible }

implementation

{ ============================================================
  libc helpers
  ============================================================ }

function libc_strlen(s: PChar): csize_t; external 'c' name 'strlen';
function libc_memcpy(dst, src: Pointer; n: csize_t): Pointer; external 'c' name 'memcpy';
procedure libc_memset(dst: Pointer; c: i32; n: csize_t); external 'c' name 'memset';
function libc_vasprintf(out strp: PChar; fmt: PChar; ap: Pointer): i32; external 'c' name 'vasprintf';
function libc_vsnprintf(str: PChar; size: csize_t; fmt: PChar; ap: Pointer): i32; external 'c' name 'vsnprintf';
function libc_pow(base, exp: Double): Double; external 'c' name 'pow';

{ ============================================================
  Global variable initialisations (from global.c)
  ============================================================ }

procedure InitUpperToLower;
{ ASCII table: upper-case letters mapped to lower-case; rest identity. }
const
  tbl: array[0..273] of u8 = (
      0,  1,  2,  3,  4,  5,  6,  7,  8,  9, 10, 11, 12, 13, 14, 15, 16, 17,
     18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35,
     36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53,
     54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 64, 97, 98, 99,100,101,102,103,
    104,105,106,107,108,109,110,111,112,113,114,115,116,117,118,119,120,121,
    122, 91, 92, 93, 94, 95, 96, 97, 98, 99,100,101,102,103,104,105,106,107,
    108,109,110,111,112,113,114,115,116,117,118,119,120,121,122,123,124,125,
    126,127,128,129,130,131,132,133,134,135,136,137,138,139,140,141,142,143,
    144,145,146,147,148,149,150,151,152,153,154,155,156,157,158,159,160,161,
    162,163,164,165,166,167,168,169,170,171,172,173,174,175,176,177,178,179,
    180,181,182,183,184,185,186,187,188,189,190,191,192,193,194,195,196,197,
    198,199,200,201,202,203,204,205,206,207,208,209,210,211,212,213,214,215,
    216,217,218,219,220,221,222,223,224,225,226,227,228,229,230,231,232,233,
    234,235,236,237,238,239,240,241,242,243,244,245,246,247,248,249,250,251,
    252,253,254,255,
    { Comparison extension (18 extra bytes — UBSAN workaround) }
    1, 0, 0, 1, 1, 0,   { aLTb }
    0, 1, 0, 1, 0, 1,   { aEQb }
    1, 0, 1, 0, 0, 1    { aGTb }
  );
var i: i32;
begin
  for i := 0 to 273 do sqlite3UpperToLower[i] := tbl[i];
end;

procedure InitCtypeMap;
const
  tbl: array[0..255] of u8 = (
    $00,$00,$00,$00,$00,$00,$00,$00, $00,$01,$01,$01,$01,$01,$00,$00,
    $00,$00,$00,$00,$00,$00,$00,$00, $00,$00,$00,$00,$00,$00,$00,$00,
    $01,$00,$80,$00,$40,$00,$00,$80, $00,$00,$00,$00,$00,$00,$00,$00,
    $0c,$0c,$0c,$0c,$0c,$0c,$0c,$0c, $0c,$0c,$00,$00,$00,$00,$00,$00,
    $00,$0a,$0a,$0a,$0a,$0a,$0a,$02, $02,$02,$02,$02,$02,$02,$02,$02,
    $02,$02,$02,$02,$02,$02,$02,$02, $02,$02,$02,$80,$00,$00,$00,$40,
    $80,$2a,$2a,$2a,$2a,$2a,$2a,$22, $22,$22,$22,$22,$22,$22,$22,$22,
    $22,$22,$22,$22,$22,$22,$22,$22, $22,$22,$22,$00,$00,$00,$00,$00,
    $40,$40,$40,$40,$40,$40,$40,$40, $40,$40,$40,$40,$40,$40,$40,$40,
    $40,$40,$40,$40,$40,$40,$40,$40, $40,$40,$40,$40,$40,$40,$40,$40,
    $40,$40,$40,$40,$40,$40,$40,$40, $40,$40,$40,$40,$40,$40,$40,$40,
    $40,$40,$40,$40,$40,$40,$40,$40, $40,$40,$40,$40,$40,$40,$40,$40,
    $40,$40,$40,$40,$40,$40,$40,$40, $40,$40,$40,$40,$40,$40,$40,$40,
    $40,$40,$40,$40,$40,$40,$40,$40, $40,$40,$40,$40,$40,$40,$40,$40,
    $40,$40,$40,$40,$40,$40,$40,$40, $40,$40,$40,$40,$40,$40,$40,$40,
    $40,$40,$40,$40,$40,$40,$40,$40, $40,$40,$40,$40,$40,$40,$40,$40
  );
var i: i32;
begin
  for i := 0 to 255 do sqlite3CtypeMap[i] := tbl[i];
end;

procedure InitGlobalConfig;
begin
  libc_memset(@sqlite3GlobalConfig, 0, SizeOf(sqlite3GlobalConfig));
  sqlite3GlobalConfig.bMemstat    := 1;      { SQLITE_DEFAULT_MEMSTATUS }
  sqlite3GlobalConfig.bCoreMutex  := 1;
  sqlite3GlobalConfig.bFullMutex  := 1;      { SQLITE_THREADSAFE==1 }
  sqlite3GlobalConfig.bOpenUri    := 0;
  sqlite3GlobalConfig.bUseCis     := 1;
  sqlite3GlobalConfig.bSmallMalloc := 0;
  sqlite3GlobalConfig.bExtraSchemaChecks := 1;
  sqlite3GlobalConfig.mxStrlen    := $7ffffffe;
  sqlite3GlobalConfig.neverCorrupt := 0;
  sqlite3GlobalConfig.szLookaside := 1200;
  sqlite3GlobalConfig.nLookaside  := 40;
  sqlite3GlobalConfig.nStmtSpill  := 64*1024;
  sqlite3GlobalConfig.szPage      := 0;
  sqlite3GlobalConfig.nPage       := 0;
  sqlite3GlobalConfig.mxParserStack := 0;
  sqlite3GlobalConfig.sharedCacheEnabled := 0;
  sqlite3GlobalConfig.szPma       := 250;
  sqlite3GlobalConfig.iOnceResetThreshold := $7ffffffe;
  sqlite3GlobalConfig.szSorterRef := 512;
  sqlite3GlobalConfig.mxMemdbSize := 1073741824;
end;

{ ============================================================
  Section: Character classification  (from sqliteInt.h macros)
  ============================================================ }

function sqlite3Isspace(x: u8): i32; inline;
begin
  if (sqlite3CtypeMap[x] and $01) <> 0 then Result := 1 else Result := 0;
end;

function sqlite3Isalnum(x: u8): i32; inline;
begin
  if (sqlite3CtypeMap[x] and $06) <> 0 then Result := 1 else Result := 0;
end;

function sqlite3Isalpha(x: u8): i32; inline;
begin
  if (sqlite3CtypeMap[x] and $02) <> 0 then Result := 1 else Result := 0;
end;

function sqlite3Isdigit(x: u8): i32; inline;
begin
  if (sqlite3CtypeMap[x] and $04) <> 0 then Result := 1 else Result := 0;
end;

function sqlite3Isxdigit(x: u8): i32; inline;
begin
  if (sqlite3CtypeMap[x] and $08) <> 0 then Result := 1 else Result := 0;
end;

function sqlite3Isupper(x: u8): i32; inline;
begin
  if (sqlite3CtypeMap[x] and $20) <> 0 then Result := 0 else
  if (sqlite3CtypeMap[x] and $02) <> 0 then Result := 1 else Result := 0;
end;

function sqlite3Islower(x: u8): i32; inline;
begin
  if (sqlite3CtypeMap[x] and $20) <> 0 then Result := 1 else Result := 0;
end;

function sqlite3Toupper(x: u8): u8; inline;
begin
  Result := x and not (sqlite3CtypeMap[x] and $20);
end;

function sqlite3Tolower(x: u8): u8; inline;
begin
  Result := sqlite3UpperToLower[x];
end;

{ ============================================================
  Section: String utilities  (util.c)
  ============================================================ }

function sqlite3Strlen30(z: PChar): i32;
begin
  if z = nil then Exit(0);
  Result := $3fffffff and i32(libc_strlen(z));
end;

function sqlite3StrICmp(zLeft, zRight: PChar): i32;
var
  a, b: Pu8;
  c, x: i32;
begin
  a := Pu8(zLeft);
  b := Pu8(zRight);
  repeat
    c := a^;
    x := b^;
    if c = x then begin
      if c = 0 then break;
    end else begin
      c := i32(sqlite3UpperToLower[c]) - i32(sqlite3UpperToLower[x]);
      if c <> 0 then break;
    end;
    Inc(a); Inc(b);
  until False;
  Result := c;
end;

function sqlite3_strnicmp(zLeft, zRight: PChar; N: i32): i32;
var
  a, b: Pu8;
begin
  if zLeft = nil then begin
    if zRight <> nil then Exit(-1) else Exit(0);
  end else if zRight = nil then
    Exit(1);
  a := Pu8(zLeft);
  b := Pu8(zRight);
  while (N > 0) and (a^ <> 0) and (sqlite3UpperToLower[a^] = sqlite3UpperToLower[b^]) do begin
    Inc(a); Inc(b); Dec(N);
  end;
  if N <= 0 then Exit(0);
  Result := i32(sqlite3UpperToLower[a^]) - i32(sqlite3UpperToLower[b^]);
end;

function sqlite3StrIHash(z: PChar): u8;
var
  h: u8;
  p: Pu8;
begin
  h := 0;
  if z = nil then Exit(0);
  p := Pu8(z);
  while p^ <> 0 do begin
    h += sqlite3UpperToLower[p^];
    Inc(p);
  end;
  Result := h;
end;

{ sqlite3AtoF — faithful port of util.c:866.
  Returns the parse state flags; *pResult receives the double value. }
function sqlite3AtoF(zIn: PChar; out pResult: Double): i32;
label start_of_text, parse_integer_part, after_integer;
var
  z:      Pu8;
  neg:    i32;
  s:      u64;
  d:      i32;
  mState: i32;
  v:      u32;
  esign:  i32;
  exp_:   i32;
begin
  z := Pu8(zIn);
  neg := 0;
  s := 0;
  d := 0;
  mState := 0;
  pResult := 0.0;

start_of_text:
  v := u32(z^) - u32(Ord('0'));
  if v < 10 then
    goto parse_integer_part
  else if z^ = Ord('-') then begin
    neg := 1;
    Inc(z);
    v := u32(z^) - u32(Ord('0'));
    if v < 10 then goto parse_integer_part;
  end else if z^ = Ord('+') then begin
    Inc(z);
    v := u32(z^) - u32(Ord('0'));
    if v < 10 then goto parse_integer_part;
  end else if sqlite3Isspace(z^) <> 0 then begin
    repeat Inc(z); until sqlite3Isspace(z^) = 0;
    goto start_of_text;
  end else
    s := 0;
  goto after_integer;

parse_integer_part:
  mState := 1;
  s := v;
  Inc(z);
  while True do begin
    v := u32(z^) - u32(Ord('0'));
    if v >= 10 then break;
    s := s * 10 + v;
    Inc(z);
    if s >= (High(u64) - 9) div 10 then begin
      mState := 9;
      while sqlite3Isdigit(z^) <> 0 do begin Inc(z); Inc(d); end;
      break;
    end;
  end;

after_integer:
  { decimal point }
  if z^ = Ord('.') then begin
    Inc(z);
    if sqlite3Isdigit(z^) <> 0 then begin
      mState := mState or 1;
      repeat
        if s < (High(u64) - 9) div 10 then begin
          s := s * 10 + u32(z^) - u32(Ord('0'));
          Dec(d);
        end else
          mState := 11;
        Inc(z);
      until sqlite3Isdigit(z^) = 0;
    end else if mState = 0 then begin
      pResult := 0.0; Exit(0);
    end;
    mState := mState or 2;
  end else if mState = 0 then begin
    pResult := 0.0; Exit(0);
  end;

  { exponent }
  if (z^ = Ord('e')) or (z^ = Ord('E')) then begin
    Inc(z);
    if z^ = Ord('-') then begin esign := -1; Inc(z); end
    else begin esign := 1; if z^ = Ord('+') then Inc(z); end;
    v := u32(z^) - u32(Ord('0'));
    if v < 10 then begin
      exp_ := v;
      Inc(z);
      mState := mState or 2;
      while True do begin
        v := u32(z^) - u32(Ord('0'));
        if v >= 10 then break;
        if exp_ < 10000 then exp_ := exp_ * 10 + i32(v) else exp_ := 10000;
        Inc(z);
      end;
      Inc(d, esign * exp_);
    end else
      Dec(z);
  end;

  { convert s * 10^d to double }
  if s = 0 then begin
    pResult := 0.0;
    mState := mState or 4;
  end else begin
    pResult := s * libc_pow(10.0, d);
  end;
  if neg <> 0 then pResult := -pResult;

  { return }
  if z^ = 0 then
    Exit(mState);
  if sqlite3Isspace(z^) <> 0 then begin
    repeat Inc(z); until sqlite3Isspace(z^) = 0;
    if z^ = 0 then Exit(mState);
  end;
  Result := i32($fffffff0) or mState;
end;

function sqlite3HexToInt(h: i32): u8; inline;
begin
  { ASCII: digits 0-9 add 0, letters a-f/A-F add 9 }
  h := h + 9 * (1 and (h shr 6));
  Result := u8(h and $F);
end;

function sqlite3HexToBlob(db: Psqlite3db; z: PAnsiChar; n: i32): Pointer;
{ Faithful port of util.c:1892..1905 — caller passes the body of an
  x'…' BLOB literal (without the leading "x'" but with the trailing "'"
  byte still counted).  Allocates n/2+1 bytes via sqlite3DbMallocRawNN
  and packs each pair of hex bytes into one output byte; the trailing
  byte is the contract NUL terminator (P4_DYNAMIC consumers ignore it,
  but SQLite always writes it). }
var
  zBlob: PAnsiChar;
  i:     i32;
begin
  zBlob := PAnsiChar(sqlite3DbMallocRawNN(db, u64(n div 2 + 1)));
  Dec(n);
  if zBlob <> nil then
  begin
    i := 0;
    while i < n do
    begin
      zBlob[i div 2] := AnsiChar(
        (sqlite3HexToInt(Ord(z[i])) shl 4) or sqlite3HexToInt(Ord(z[i + 1])));
      Inc(i, 2);
    end;
    zBlob[i div 2] := #0;
  end;
  Result := zBlob;
end;

function sqlite3Strlen30NN(z: PChar): i32;
begin
  Result := $3fffffff and i32(libc_strlen(z));
end;

{ compare2pow63 — helper for sqlite3Atoi64 }
function compare2pow63(zNum: PChar; incr: i32): i32;
const
  pow63: PAnsiChar = '922337203685477580';
var
  c, i: i32;
begin
  c := 0;
  i := 0;
  while (c = 0) and (i < 18) do begin
    c := (Ord(zNum[i*incr]) - Ord(pow63[i])) * 10;
    Inc(i);
  end;
  if c = 0 then
    c := Ord(zNum[18*incr]) - Ord('8');
  Result := c;
end;

{ sqlite3Atoi64 — faithful port of util.c:1161.
  Converts a string to a 64-bit signed integer.
  Returns: -1=no digits, 0=ok, 1=extra text, 2=overflow, 3=MinInt64 special }
function sqlite3Atoi64(zNum: PChar; out pNum: i64; length: i32; enc: u8): i32;
var
  incr:    i32;
  u:       u64;
  neg:     i32;
  i, j:    i32;
  c:       u32;
  nonNum:  i32;
  rc:      i32;
  jj:      i32;
  zStart:  PChar;
  zEnd:    PChar;
begin
  u := 0;
  neg := 0;
  nonNum := 0;
  rc := 0;
  zEnd := zNum + length;
  if enc = SQLITE_UTF8 then
    incr := 1
  else begin
    incr := 2;
    length := length and not 1;
    i := 3 - i32(enc);
    while (i < length) and (zNum[i] = #0) do Inc(i, 2);
    if i < length then nonNum := 1;
    zEnd := @zNum[i xor 1];
    zNum := zNum + (enc and 1);
  end;
  while (zNum < zEnd) and (sqlite3Isspace(Ord(zNum^)) <> 0) do
    Inc(zNum, incr);
  if zNum < zEnd then begin
    if zNum^ = '-' then begin
      neg := 1; Inc(zNum, incr);
    end else if zNum^ = '+' then
      Inc(zNum, incr);
  end;
  zStart := zNum;
  while (zNum < zEnd) and (zNum^ = '0') do Inc(zNum, incr);
  i := 0;
  while (@zNum[i] < zEnd) do begin
    c := u32(Ord(zNum[i])) - u32(Ord('0'));
    if c > 9 then break;
    u := u * 10 + c;
    Inc(i, incr);
  end;
  if u > u64(LARGEST_INT64) then begin
    if neg <> 0 then pNum := SMALLEST_INT64 else pNum := LARGEST_INT64;
  end else if neg <> 0 then
    pNum := -i64(u)
  else
    pNum := i64(u);
  if (i = 0) and (zStart = zNum) then
    rc := -1
  else if nonNum <> 0 then
    rc := 1
  else if @zNum[i] < zEnd then begin
    jj := i;
    repeat
      if sqlite3Isspace(Ord(zNum[jj])) = 0 then begin
        rc := 1; break;
      end;
      Inc(jj, incr);
    until @zNum[jj] >= zEnd;
  end;
  if i < 19 * incr then begin
    Result := rc; Exit;
  end else begin
    if i > 19 * incr then j := 1
    else j := compare2pow63(zNum, incr);
    if j < 0 then begin
      Result := rc; Exit;
    end else begin
      if neg <> 0 then pNum := SMALLEST_INT64 else pNum := LARGEST_INT64;
      if j > 0 then
        Result := 2
      else begin
        if neg <> 0 then Result := rc else Result := 3;
      end;
      Exit;
    end;
  end;
end;

{ sqlite3Int64ToText — faithful port of util.c:1076. }
function sqlite3Int64ToText(v: i64; zOut: PChar): i32;
var
  u:   u64;
  i:   i32;
  buf: array[0..22] of AnsiChar;
begin
  if v > 0 then
    u := u64(v)
  else if v = 0 then begin
    zOut[0] := '0';
    zOut[1] := #0;
    Result := 1;
    Exit;
  end else begin
    if v = SMALLEST_INT64 then
      u := u64(1) shl 63
    else
      u := u64(-v);
  end;
  i := 21;
  buf[i] := #0;
  while u >= 10 do begin
    Dec(i);
    buf[i] := AnsiChar(Ord('0') + i32(u mod 10));
    u := u div 10;
  end;
  if u > 0 then begin
    Dec(i);
    buf[i] := AnsiChar(Ord('0') + i32(u));
  end;
  if v < 0 then begin
    Dec(i);
    buf[i] := '-';
  end;
  Result := 21 - i;
  Move(buf[i], zOut^, Result + 1);
end;

{ sqlite3DecOrHexToI64 — port of util.c:1264. }
function sqlite3DecOrHexToI64(z: PChar; out pOut: i64): i32;
var
  u: u64;
  k, i: i32;
begin
  if (z[0] = '0') and ((z[1] = 'x') or (z[1] = 'X')) then begin
    u := 0;
    i := 2;
    while z[i] = '0' do Inc(i);
    k := i;
    while sqlite3Isxdigit(Ord(z[k])) <> 0 do begin
      u := u * 16 + u64(sqlite3HexToInt(Ord(z[k])));
      Inc(k);
    end;
    Move(u, pOut, 8);
    if k - i > 16 then begin Result := 2; Exit; end;
    if z[k] <> #0 then begin Result := 1; Exit; end;
    Result := 0;
  end else
    Result := sqlite3Atoi64(z, pOut, sqlite3Strlen30(z), SQLITE_UTF8);
end;

{ ============================================================
  Section: Big-endian 4-byte accessors (util.c)
  ============================================================ }

function sqlite3Get4byte(p: Pu8): u32;
begin
  Result := (u32(p[0]) shl 24) or (u32(p[1]) shl 16) or (u32(p[2]) shl 8) or u32(p[3]);
end;

procedure sqlite3Put4byte(p: Pu8; v: u32);
begin
  p[0] := u8(v shr 24);
  p[1] := u8(v shr 16);
  p[2] := u8(v shr 8);
  p[3] := u8(v);
end;

{ ============================================================
  Section: Varint codec  (util.c lines 1574–1860 — port verbatim)
  ============================================================ }

const
  SLOT_2_0:   u32 = $001fc07f;
  SLOT_4_2_0: u32 = $f01fc07f;

function putVarint64(p: Pu8; v: u64): i32;
var
  i, j, n: i32;
  buf: array[0..9] of u8;
begin
  if (v and (u64($ff000000) shl 32)) <> 0 then begin
    p[8] := u8(v);
    v := v shr 8;
    for i := 7 downto 0 do begin
      p[i] := u8((v and $7f) or $80);
      v := v shr 7;
    end;
    Exit(9);
  end;
  n := 0;
  repeat
    buf[n] := u8((v and $7f) or $80);
    Inc(n);
    v := v shr 7;
  until v = 0;
  buf[0] := buf[0] and $7f;
  j := n - 1;
  for i := 0 to n - 1 do begin
    p[i] := buf[j];
    Dec(j);
  end;
  Result := n;
end;

function sqlite3PutVarint(p: Pu8; v: u64): i32;
begin
  if v <= $7f then begin
    p[0] := u8(v and $7f);
    Exit(1);
  end;
  if v <= $3fff then begin
    p[0] := u8(((v shr 7) and $7f) or $80);
    p[1] := u8(v and $7f);
    Exit(2);
  end;
  Result := putVarint64(p, v);
end;

function sqlite3GetVarint(p: Pu8; out v: u64): u8;
var
  a, b, s: u32;
begin
  if i8(p[0]) >= 0 then begin
    v := p[0];
    Exit(1);
  end;
  if i8(p[1]) >= 0 then begin
    v := (u32(p[0] and $7f) shl 7) or u32(p[1]);
    Exit(2);
  end;

  a := u32(p[0]) shl 14;
  b := u32(p[1]);
  Inc(p, 2);
  a := a or u32(p^);
  { a: p0<<14 | p2 (unmasked) }
  if (a and $80) = 0 then begin
    a := a and SLOT_2_0;
    b := b and $7f;
    b := b shl 7;
    a := a or b;
    v := a;
    Exit(3);
  end;

  a := a and SLOT_2_0;
  Inc(p);
  b := b shl 14;
  b := b or u32(p^);
  { b: p1<<14 | p3 (unmasked) }
  if (b and $80) = 0 then begin
    b := b and SLOT_2_0;
    a := a shl 7;
    a := a or b;
    v := a;
    Exit(4);
  end;

  b := b and SLOT_2_0;
  s := a;
  Inc(p);
  a := a shl 14;
  a := a or u32(p^);
  { a: p0<<28 | p2<<14 | p4 (unmasked) }
  if (a and $80) = 0 then begin
    b := b shl 7;
    a := a or b;
    s := s shr 18;
    v := (u64(s) shl 32) or u64(a);
    Exit(5);
  end;

  s := s shl 7;
  s := s or b;
  Inc(p);
  b := b shl 14;
  b := b or u32(p^);
  { b: p1<<28 | p3<<14 | p5 (unmasked) }
  if (b and $80) = 0 then begin
    a := a and SLOT_2_0;
    a := a shl 7;
    a := a or b;
    s := s shr 18;
    v := (u64(s) shl 32) or u64(a);
    Exit(6);
  end;

  Inc(p);
  a := a shl 14;
  a := a or u32(p^);
  { a: p2<<28 | p4<<14 | p6 (unmasked) }
  if (a and $80) = 0 then begin
    a := a and SLOT_4_2_0;
    b := b and SLOT_2_0;
    b := b shl 7;
    a := a or b;
    s := s shr 11;
    v := (u64(s) shl 32) or u64(a);
    Exit(7);
  end;

  a := a and SLOT_2_0;
  Inc(p);
  b := b shl 14;
  b := b or u32(p^);
  { b: p3<<28 | p5<<14 | p7 (unmasked) }
  if (b and $80) = 0 then begin
    b := b and SLOT_4_2_0;
    a := a shl 7;
    a := a or b;
    s := s shr 4;
    v := (u64(s) shl 32) or u64(a);
    Exit(8);
  end;

  Inc(p);
  a := a shl 15;
  a := a or u32(p^);

  b := b and SLOT_2_0;
  b := b shl 8;
  a := a or b;

  s := s shl 4;
  b := u32(p[-4]);
  b := b and $7f;
  b := b shr 3;
  s := s or b;

  v := (u64(s) shl 32) or u64(a);
  Result := 9;
end;

function sqlite3GetVarint32(p: Pu8; out v: u32): u8;
var
  v64: u64;
  n:   u8;
begin
  { Caller guarantees (p[0] and $80) <> 0 }
  if (p[1] and $80) = 0 then begin
    v := (u32(p[0] and $7f) shl 7) or u32(p[1]);
    Exit(2);
  end;
  if (p[2] and $80) = 0 then begin
    v := (u32(p[0] and $7f) shl 14) or (u32(p[1] and $7f) shl 7) or u32(p[2]);
    Exit(3);
  end;
  n := sqlite3GetVarint(p, v64);
  if (v64 and u64($ffffffff)) <> v64 then
    v := $ffffffff
  else
    v := u32(v64);
  Result := n;
end;

function sqlite3VarintLen(v: u64): i32;
var i: i32;
begin
  i := 1;
  v := v shr 7;
  while v <> 0 do begin Inc(i); v := v shr 7; end;
  Result := i;
end;

{ ============================================================
  Section: Hash table  (hash.c)
  ============================================================ }

function strHash(z: PChar): u32;
var h: u32;
begin
  h := 0;
  while z^ <> #0 do begin
    h += $df and u8(z^);
    h *= $9e3779b1;
    Inc(z);
  end;
  Result := h;
end;

procedure insertElement(pH: PHash; pEntry: PHashBucket; pNew: PHashElem);
var pHead: PHashElem;
begin
  if pEntry <> nil then begin
    if pEntry^.count <> 0 then
      pHead := PHashElem(pEntry^.chain)
    else
      pHead := nil;
    Inc(pEntry^.count);
    pEntry^.chain := pNew;
  end else
    pHead := nil;

  if pHead <> nil then begin
    pNew^.next := pHead;
    pNew^.prev := pHead^.prev;
    if pHead^.prev <> nil then
      PHashElem(pHead^.prev)^.next := pNew
    else
      pH^.first := pNew;
    pHead^.prev := pNew;
  end else begin
    pNew^.next := pH^.first;
    if pH^.first <> nil then
      pH^.first^.prev := pNew;
    pNew^.prev := nil;
    pH^.first := pNew;
  end;
end;

function rehash(pH: PHash; new_size: u32): i32;
var
  new_ht:   PHashBucket;
  elem, next_elem: PHashElem;
  allocSz:  csize_t;
  actual_size: u32;
begin
  allocSz := new_size * SizeOf(THashBucket);
  new_ht := PHashBucket(sqlite3_malloc(i32(allocSz)));
  if new_ht = nil then Exit(0);
  sqlite3_free(pH^.ht);
  pH^.ht := new_ht;
  actual_size := u32(malloc_usable_size(new_ht) div SizeOf(THashBucket));
  if actual_size < new_size then actual_size := new_size;
  pH^.htsize := actual_size;
  libc_memset(new_ht, 0, csize_t(actual_size) * SizeOf(THashBucket));
  elem := pH^.first;
  pH^.first := nil;
  while elem <> nil do begin
    next_elem := PHashElem(elem^.next);
    insertElement(pH, @new_ht[elem^.h mod actual_size], elem);
    elem := next_elem;
  end;
  Result := 1;
end;

function findElementWithHash(pH: PHash; pKey: PChar; pHash: Pu32): PHashElem;
var
  elem:  PHashElem;
  count: u32;
  h:     u32;
  pEntry: PHashBucket;
begin
  h := strHash(pKey);
  if pH^.ht <> nil then begin
    pEntry := @pH^.ht[h mod pH^.htsize];
    elem  := PHashElem(pEntry^.chain);
    count := pEntry^.count;
  end else begin
    elem  := pH^.first;
    count := pH^.count;
  end;
  if pHash <> nil then pHash^ := h;
  while count > 0 do begin
    if (h = elem^.h) and (sqlite3StrICmp(elem^.pKey, pKey) = 0) then
      Exit(elem);
    elem := PHashElem(elem^.next);
    Dec(count);
  end;
  Result := nil; { no match }
end;

procedure removeElement(pH: PHash; elem: PHashElem);
var pEntry: PHashBucket;
begin
  if elem^.prev <> nil then
    PHashElem(elem^.prev)^.next := elem^.next
  else
    pH^.first := PHashElem(elem^.next);
  if elem^.next <> nil then
    PHashElem(elem^.next)^.prev := elem^.prev;
  if pH^.ht <> nil then begin
    pEntry := @pH^.ht[elem^.h mod pH^.htsize];
    if pEntry^.chain = elem then
      pEntry^.chain := elem^.next;
    Dec(pEntry^.count);
  end;
  sqlite3_free(elem);
  Dec(pH^.count);
  if pH^.count = 0 then
    sqlite3HashClear(pH);
end;

procedure sqlite3HashInit(pNew: PHash);
begin
  pNew^.first  := nil;
  pNew^.count  := 0;
  pNew^.htsize := 0;
  pNew^.ht     := nil;
end;

procedure sqlite3HashClear(pH: PHash);
var
  elem, next_elem: PHashElem;
begin
  elem := pH^.first;
  pH^.first := nil;
  sqlite3_free(pH^.ht);
  pH^.ht := nil;
  pH^.htsize := 0;
  while elem <> nil do begin
    next_elem := PHashElem(elem^.next);
    sqlite3_free(elem);
    elem := next_elem;
  end;
  pH^.count := 0;
end;

function sqlite3HashFind(pH: PHash; pKey: PChar): Pointer;
var elem: PHashElem;
begin
  elem := findElementWithHash(pH, pKey, nil);
  if elem = nil then Exit(nil);
  Result := elem^.data;
end;

function sqlite3HashInsert(pH: PHash; pKey: PChar; data: Pointer): Pointer;
var
  h:        u32;
  elem:     PHashElem;
  new_elem: PHashElem;
  old_data: Pointer;
begin
  elem := findElementWithHash(pH, pKey, @h);
  if elem <> nil then begin
    old_data := elem^.data;
    if data = nil then
      removeElement(pH, elem)
    else begin
      elem^.data := data;
      elem^.pKey := pKey;
    end;
    Exit(old_data);
  end;
  if data = nil then Exit(nil);
  new_elem := PHashElem(sqlite3_malloc(SizeOf(THashElem)));
  if new_elem = nil then Exit(data);
  new_elem^.pKey := pKey;
  new_elem^.h    := h;
  new_elem^.data := data;
  new_elem^.next := nil;
  new_elem^.prev := nil;
  Inc(pH^.count);
  if (pH^.count >= 5) and (pH^.count > 2 * pH^.htsize) then
    rehash(pH, pH^.count * 3);
  if pH^.ht <> nil then
    insertElement(pH, @pH^.ht[new_elem^.h mod pH^.htsize], new_elem)
  else
    insertElement(pH, nil, new_elem);
  Result := nil;
end;

{ ============================================================
  Section: PRNG — ChaCha20  (random.c)
  ============================================================ }

var
  sqlite3Prng:      Tsqlite3PrngType;
  sqlite3SavedPrng: Tsqlite3PrngType;

{ Call VFS xRandomness through the sqlite3_vfs function pointer }
function sqlite3OsRandomness(pVfs: Pointer; nByte: i32; zBufOut: PChar): i32;
var vp: Psqlite3_vfs;
begin
  if pVfs = nil then Exit(SQLITE_ERROR);
  vp := Psqlite3_vfs(pVfs);
  Result := vp^.xRandomness(vp, cint(nByte), zBufOut);
end;

procedure chacha_block(out_: Pu32; const in_: Pu32);
var
  x: array[0..15] of u32;
  i: i32;
begin
  libc_memcpy(@x[0], in_, 64);
  for i := 0 to 9 do begin
    { column rounds }
    x[ 0] += x[ 4]; x[12] := x[12] xor x[ 0]; x[12] := (x[12] shl 16) or (x[12] shr 16);
    x[ 8] += x[12]; x[ 4] := x[ 4] xor x[ 8]; x[ 4] := (x[ 4] shl 12) or (x[ 4] shr 20);
    x[ 0] += x[ 4]; x[12] := x[12] xor x[ 0]; x[12] := (x[12] shl  8) or (x[12] shr 24);
    x[ 8] += x[12]; x[ 4] := x[ 4] xor x[ 8]; x[ 4] := (x[ 4] shl  7) or (x[ 4] shr 25);

    x[ 1] += x[ 5]; x[13] := x[13] xor x[ 1]; x[13] := (x[13] shl 16) or (x[13] shr 16);
    x[ 9] += x[13]; x[ 5] := x[ 5] xor x[ 9]; x[ 5] := (x[ 5] shl 12) or (x[ 5] shr 20);
    x[ 1] += x[ 5]; x[13] := x[13] xor x[ 1]; x[13] := (x[13] shl  8) or (x[13] shr 24);
    x[ 9] += x[13]; x[ 5] := x[ 5] xor x[ 9]; x[ 5] := (x[ 5] shl  7) or (x[ 5] shr 25);

    x[ 2] += x[ 6]; x[14] := x[14] xor x[ 2]; x[14] := (x[14] shl 16) or (x[14] shr 16);
    x[10] += x[14]; x[ 6] := x[ 6] xor x[10]; x[ 6] := (x[ 6] shl 12) or (x[ 6] shr 20);
    x[ 2] += x[ 6]; x[14] := x[14] xor x[ 2]; x[14] := (x[14] shl  8) or (x[14] shr 24);
    x[10] += x[14]; x[ 6] := x[ 6] xor x[10]; x[ 6] := (x[ 6] shl  7) or (x[ 6] shr 25);

    x[ 3] += x[ 7]; x[15] := x[15] xor x[ 3]; x[15] := (x[15] shl 16) or (x[15] shr 16);
    x[11] += x[15]; x[ 7] := x[ 7] xor x[11]; x[ 7] := (x[ 7] shl 12) or (x[ 7] shr 20);
    x[ 3] += x[ 7]; x[15] := x[15] xor x[ 3]; x[15] := (x[15] shl  8) or (x[15] shr 24);
    x[11] += x[15]; x[ 7] := x[ 7] xor x[11]; x[ 7] := (x[ 7] shl  7) or (x[ 7] shr 25);

    { diagonal rounds }
    x[ 0] += x[ 5]; x[15] := x[15] xor x[ 0]; x[15] := (x[15] shl 16) or (x[15] shr 16);
    x[10] += x[15]; x[ 5] := x[ 5] xor x[10]; x[ 5] := (x[ 5] shl 12) or (x[ 5] shr 20);
    x[ 0] += x[ 5]; x[15] := x[15] xor x[ 0]; x[15] := (x[15] shl  8) or (x[15] shr 24);
    x[10] += x[15]; x[ 5] := x[ 5] xor x[10]; x[ 5] := (x[ 5] shl  7) or (x[ 5] shr 25);

    x[ 1] += x[ 6]; x[12] := x[12] xor x[ 1]; x[12] := (x[12] shl 16) or (x[12] shr 16);
    x[11] += x[12]; x[ 6] := x[ 6] xor x[11]; x[ 6] := (x[ 6] shl 12) or (x[ 6] shr 20);
    x[ 1] += x[ 6]; x[12] := x[12] xor x[ 1]; x[12] := (x[12] shl  8) or (x[12] shr 24);
    x[11] += x[12]; x[ 6] := x[ 6] xor x[11]; x[ 6] := (x[ 6] shl  7) or (x[ 6] shr 25);

    x[ 2] += x[ 7]; x[13] := x[13] xor x[ 2]; x[13] := (x[13] shl 16) or (x[13] shr 16);
    x[ 8] += x[13]; x[ 7] := x[ 7] xor x[ 8]; x[ 7] := (x[ 7] shl 12) or (x[ 7] shr 20);
    x[ 2] += x[ 7]; x[13] := x[13] xor x[ 2]; x[13] := (x[13] shl  8) or (x[13] shr 24);
    x[ 8] += x[13]; x[ 7] := x[ 7] xor x[ 8]; x[ 7] := (x[ 7] shl  7) or (x[ 7] shr 25);

    x[ 3] += x[ 4]; x[14] := x[14] xor x[ 3]; x[14] := (x[14] shl 16) or (x[14] shr 16);
    x[ 9] += x[14]; x[ 4] := x[ 4] xor x[ 9]; x[ 4] := (x[ 4] shl 12) or (x[ 4] shr 20);
    x[ 3] += x[ 4]; x[14] := x[14] xor x[ 3]; x[14] := (x[14] shl  8) or (x[14] shr 24);
    x[ 9] += x[14]; x[ 4] := x[ 4] xor x[ 9]; x[ 4] := (x[ 4] shl  7) or (x[ 4] shr 25);
  end;
  for i := 0 to 15 do out_[i] := x[i] + in_[i];
end;

procedure sqlite3_randomness(N: i32; pBuf: Pointer);
var
  zBuf:  Pu8;
  mutex: Psqlite3_mutex;
  pVfs:  Psqlite3_vfs;
  i:     i32;
const
  chacha20_init: array[0..3] of u32 = ($61707865, $3320646e, $79622d32, $6b206574);
begin
  zBuf  := Pu8(pBuf);
  mutex := sqlite3MutexAlloc(SQLITE_MUTEX_STATIC_PRNG);
  sqlite3_mutex_enter(mutex);

  if (N <= 0) or (pBuf = nil) then begin
    sqlite3Prng.s[0] := 0;
    sqlite3_mutex_leave(mutex);
    Exit;
  end;

  { Initialize state on first call }
  if sqlite3Prng.s[0] = 0 then begin
    pVfs := sqlite3_vfs_find(nil);
    libc_memcpy(@sqlite3Prng.s[0], @chacha20_init[0], 16);
    if pVfs = nil then
      libc_memset(@sqlite3Prng.s[4], 0, 44)
    else
      sqlite3OsRandomness(pVfs, 44, PChar(@sqlite3Prng.s[4]));
    sqlite3Prng.s[15] := sqlite3Prng.s[12];
    sqlite3Prng.s[12] := 0;
    sqlite3Prng.n := 0;
  end;

  while True do begin
    if N <= i32(sqlite3Prng.n) then begin
      libc_memcpy(zBuf, @sqlite3Prng.out_[sqlite3Prng.n - u8(N)], csize_t(N));
      sqlite3Prng.n := sqlite3Prng.n - u8(N);
      break;
    end;
    if sqlite3Prng.n > 0 then begin
      libc_memcpy(zBuf, @sqlite3Prng.out_[0], csize_t(sqlite3Prng.n));
      Dec(N, sqlite3Prng.n);
      Inc(zBuf, sqlite3Prng.n);
    end;
    Inc(sqlite3Prng.s[12]);
    chacha_block(Pu32(@sqlite3Prng.out_[0]), Pu32(@sqlite3Prng.s[0]));
    sqlite3Prng.n := 64;
  end;
  sqlite3_mutex_leave(mutex);
end;

procedure sqlite3PrngSaveState;
begin
  libc_memcpy(@sqlite3SavedPrng, @sqlite3Prng, SizeOf(sqlite3Prng));
end;

procedure sqlite3PrngRestoreState;
begin
  libc_memcpy(@sqlite3Prng, @sqlite3SavedPrng, SizeOf(sqlite3Prng));
end;

{ ============================================================
  Section: Bitvec  (bitvec.c)
  ============================================================ }

function BITVEC_HASH(x: u32): u32; inline;
begin
  Result := (x * 1) mod u32(BITVEC_NINT);
end;

function sqlite3BitvecCreate(iSize: u32): PBitvec;
var p: PBitvec;
begin
  p := PBitvec(sqlite3MallocZero(SizeOf(TBitvec)));
  if p <> nil then
    p^.iSize := iSize;
  Result := p;
end;

function sqlite3BitvecTestNotNull(p: PBitvec; i: u32): i32;
var
  bin_: u32;
  h:    u32;
begin
  Dec(i);
  if i >= p^.iSize then Exit(0);
  while p^.iDivisor <> 0 do begin
    bin_ := i div p^.iDivisor;
    i    := i mod p^.iDivisor;
    p    := p^.u.apSub[bin_];
    if p = nil then Exit(0);
  end;
  if p^.iSize <= u32(BITVEC_NBIT) then begin
    if (p^.u.aBitmap[i div BITVEC_SZELEM] and u8(1 shl (i and (BITVEC_SZELEM-1)))) <> 0 then
      Exit(1)
    else
      Exit(0);
  end else begin
    Inc(i); { restore 1-based }
    h := BITVEC_HASH(i - 1);
    while p^.u.aHash[h] <> 0 do begin
      if p^.u.aHash[h] = i then Exit(1);
      h := (h + 1) mod u32(BITVEC_NINT);
    end;
    Exit(0);
  end;
end;

function sqlite3BitvecTest(p: PBitvec; i: u32): i32;
begin
  if p = nil then Exit(0);
  Result := sqlite3BitvecTestNotNull(p, i);
end;

function sqlite3BitvecSet(p: PBitvec; i: u32): i32;
label bitvec_set_end, bitvec_set_rehash;
var
  h:    u32;
  bin_: u32;
  pNew: PBitvec;
  j:    u32;
  rc:   i32;
begin
  if p = nil then Exit(SQLITE_OK);
  Dec(i);
  while (p^.iSize > u32(BITVEC_NBIT)) and (p^.iDivisor <> 0) do begin
    bin_ := i div p^.iDivisor;
    i    := i mod p^.iDivisor;
    if p^.u.apSub[bin_] = nil then begin
      p^.u.apSub[bin_] := sqlite3BitvecCreate(p^.iDivisor);
      if p^.u.apSub[bin_] = nil then Exit(SQLITE_NOMEM_BKPT);
    end;
    p := p^.u.apSub[bin_];
  end;
  if p^.iSize <= u32(BITVEC_NBIT) then begin
    p^.u.aBitmap[i div BITVEC_SZELEM] := p^.u.aBitmap[i div BITVEC_SZELEM]
      or u8(1 shl (i and (BITVEC_SZELEM-1)));
    Exit(SQLITE_OK);
  end;
  Inc(i); { restore 1-based }
  h := BITVEC_HASH(i - 1);
  if p^.u.aHash[h] = 0 then begin
    if p^.nSet < u32(BITVEC_NINT - 1) then
      goto bitvec_set_end
    else
      goto bitvec_set_rehash;
  end;
  { collision check }
  while p^.u.aHash[h] <> 0 do begin
    if p^.u.aHash[h] = i then Exit(SQLITE_OK);
    h := (h + 1) mod u32(BITVEC_NINT);
  end;
  goto bitvec_set_end;

bitvec_set_rehash:
  p^.iDivisor := (p^.iSize + u32(BITVEC_NPTR) - 1) div u32(BITVEC_NPTR);
  pNew := sqlite3BitvecCreate(p^.iSize);
  if pNew = nil then Exit(SQLITE_NOMEM_BKPT);
  for j := 0 to u32(BITVEC_NINT) - 1 do begin
    if p^.u.aHash[j] <> 0 then begin
      rc := sqlite3BitvecSet(pNew, p^.u.aHash[j]);
      if rc <> SQLITE_OK then begin sqlite3BitvecDestroy(pNew); Exit(rc); end;
    end;
  end;
  libc_memcpy(p, pNew, SizeOf(TBitvec));
  sqlite3_free(pNew);
  Exit(sqlite3BitvecSet(p, i));

bitvec_set_end:
  Inc(p^.nSet);
  p^.u.aHash[h] := i;
  Result := SQLITE_OK;
end;

procedure sqlite3BitvecClear(p: PBitvec; i: u32; pBuf: Pointer);
var
  bin_:    u32;
  h:       u32;
  aiValues: Pu32;
  j:       i32;
begin
  if p = nil then Exit;
  Dec(i);
  while p^.iDivisor <> 0 do begin
    bin_ := i div p^.iDivisor;
    i    := i mod p^.iDivisor;
    p    := p^.u.apSub[bin_];
    if p = nil then Exit;
  end;
  if p^.iSize <= u32(BITVEC_NBIT) then begin
    p^.u.aBitmap[i div BITVEC_SZELEM] :=
      p^.u.aBitmap[i div BITVEC_SZELEM]
      and not u8(1 shl (i and (BITVEC_SZELEM-1)));
  end else begin
    Inc(i); { restore 1-based }
    aiValues := Pu32(pBuf);
    libc_memcpy(pBuf, @p^.u.aHash[0], csize_t(BITVEC_NINT) * SizeOf(u32));
    libc_memset(@p^.u.aHash[0], 0, csize_t(BITVEC_NINT) * SizeOf(u32));
    p^.nSet := 0;
    for j := 0 to BITVEC_NINT - 1 do begin
      if (aiValues[j] <> 0) and (aiValues[j] <> i) then begin
        h := BITVEC_HASH(aiValues[j] - 1);
        while p^.u.aHash[h] <> 0 do
          h := (h + 1) mod u32(BITVEC_NINT);
        p^.u.aHash[h] := aiValues[j];
        Inc(p^.nSet);
      end;
    end;
  end;
end;

procedure sqlite3BitvecDestroy(p: PBitvec);
var i: i32;
begin
  if p = nil then Exit;
  if p^.iDivisor <> 0 then
    for i := 0 to BITVEC_NPTR - 1 do
      sqlite3BitvecDestroy(p^.u.apSub[i]);
  sqlite3_free(p);
end;

function sqlite3BitvecSize(p: PBitvec): u32;
begin
  Result := p^.iSize;
end;

{ ============================================================
  Section: Status counters  (status.c)
  ============================================================ }

var
  sqlite3Stat: Tsqlite3StatType;

const
  statMutex: array[0..9] of u8 = (
    0, { SQLITE_STATUS_MEMORY_USED }
    1, { SQLITE_STATUS_PAGECACHE_USED }
    1, { SQLITE_STATUS_PAGECACHE_OVERFLOW }
    0, { SQLITE_STATUS_SCRATCH_USED (unused) }
    0, { SQLITE_STATUS_SCRATCH_OVERFLOW (unused) }
    0, { SQLITE_STATUS_MALLOC_SIZE }
    0, { SQLITE_STATUS_PARSER_STACK }
    1, { SQLITE_STATUS_PAGECACHE_SIZE }
    0, { SQLITE_STATUS_SCRATCH_SIZE (unused) }
    0  { SQLITE_STATUS_MALLOC_COUNT }
  );

var
  gMallocMutex: Psqlite3_mutex = nil;  { set by sqlite3MallocInit }

function sqlite3MallocMutex: Psqlite3_mutex;
begin
  Result := gMallocMutex;
end;

{ Pcache1 mutex: set by pcache1Init in passqlite3pcache.pas }
function sqlite3Pcache1Mutex: Psqlite3_mutex;
begin
  Result := gPcache1Mutex;
end;

function ROUND8(n: SizeInt): SizeInt; inline;
begin
  Result := (n + 7) and not 7;
end;

function ROUNDDOWN8(n: SizeInt): SizeInt; inline;
begin
  Result := n and not 7;
end;

function SQLITE_WITHIN(p, pStart, pEnd: Pointer): Boolean; inline;
begin
  Result := (PtrUInt(p) >= PtrUInt(pStart)) and (PtrUInt(p) < PtrUInt(pEnd));
end;

function sqlite3_config(op: i32; pArg: Pointer): i32; overload;
begin
  Result := SQLITE_OK;
  case op of
    SQLITE_CONFIG_PCACHE2:
      if pArg <> nil then
        sqlite3GlobalConfig.pcache2 := PTsqlite3_pcache_methods2(pArg)^;
    { All other ops silently accepted for now }
  end;
end;

function sqlite3StatusValue(op: i32): i64;
begin
  Result := sqlite3Stat.nowValue[op];
end;

procedure sqlite3StatusUp(op: i32; N: i32);
begin
  Inc(sqlite3Stat.nowValue[op], N);
  if sqlite3Stat.nowValue[op] > sqlite3Stat.mxValue[op] then
    sqlite3Stat.mxValue[op] := sqlite3Stat.nowValue[op];
end;

procedure sqlite3StatusDown(op: i32; N: i32);
begin
  Dec(sqlite3Stat.nowValue[op], N);
end;

procedure sqlite3StatusHighwater(op: i32; X: i32);
var newVal: sqlite3StatValueType;
begin
  newVal := sqlite3StatValueType(X);
  if newVal > sqlite3Stat.mxValue[op] then
    sqlite3Stat.mxValue[op] := newVal;
end;

function sqlite3_status64(op: i32; pCurrent: Pi64; pHighwater: Pi64;
  resetFlag: i32): i32;
var pMutex: Psqlite3_mutex;
begin
  if (op < 0) or (op > 9) then Exit(SQLITE_MISUSE);
  if statMutex[op] <> 0 then
    pMutex := sqlite3Pcache1Mutex
  else
    pMutex := sqlite3MallocMutex;
  if pMutex <> nil then sqlite3_mutex_enter(pMutex);
  pCurrent^   := sqlite3Stat.nowValue[op];
  pHighwater^ := sqlite3Stat.mxValue[op];
  if resetFlag <> 0 then
    sqlite3Stat.mxValue[op] := sqlite3Stat.nowValue[op];
  if pMutex <> nil then sqlite3_mutex_leave(pMutex);
  Result := SQLITE_OK;
end;

function sqlite3_status(op: i32; pCurrent: Pi32; pHighwater: Pi32;
  resetFlag: i32): i32;
var
  iCurrent, iHighwater: i64;
  rc: i32;
begin
  rc := sqlite3_status64(op, @iCurrent, @iHighwater, resetFlag);
  if rc = SQLITE_OK then begin
    pCurrent^   := i32(iCurrent);
    pHighwater^ := i32(iHighwater);
  end;
  Result := rc;
end;

{ ============================================================
  Section: Malloc layer  (malloc.c + mem1.c)
  ============================================================ }

var
  gMem0Mutex:      Psqlite3_mutex = nil;
  gAlarmThreshold: i64 = 0;       { soft heap limit }
  gHardLimit:      i64 = 0;
  gNearlyFull:     i32 = 0;

{ mem1.c: size via malloc_usable_size }
function sqlite3MallocSize(p: Pointer): i32;
begin
  if p = nil then Exit(0);
  Result := i32(malloc_usable_size(p));
end;

function mem1_xMalloc(sz: i32): Pointer; cdecl;
begin
  Result := sqlite3_malloc(sz);
end;

procedure mem1_xFree(p: Pointer); cdecl;
begin
  sqlite3_free(p);
end;

function mem1_xRealloc(p: Pointer; sz: i32): Pointer; cdecl;
begin
  Result := sqlite3_realloc(p, sz);
end;

function mem1_xSize(p: Pointer): i32; cdecl;
begin
  Result := sqlite3MallocSize(p);
end;

function mem1_xRoundup(sz: i32): i32; cdecl;
begin
  Result := sz;
end;

function mem1_xInit(pAppData: Pointer): i32; cdecl;
begin
  Result := SQLITE_OK;
end;

procedure mem1_xShutdown(pAppData: Pointer); cdecl;
begin
end;

procedure sqlite3MemSetDefault;
begin
  sqlite3GlobalConfig.m.xMalloc   := @mem1_xMalloc;
  sqlite3GlobalConfig.m.xFree     := @mem1_xFree;
  sqlite3GlobalConfig.m.xRealloc  := @mem1_xRealloc;
  sqlite3GlobalConfig.m.xSize     := @mem1_xSize;
  sqlite3GlobalConfig.m.xRoundup  := @mem1_xRoundup;
  sqlite3GlobalConfig.m.xInit     := @mem1_xInit;
  sqlite3GlobalConfig.m.xShutdown := @mem1_xShutdown;
  sqlite3GlobalConfig.m.pAppData  := nil;
end;

function sqlite3MallocInit: i32;
begin
  if not Assigned(sqlite3GlobalConfig.m.xMalloc) then
    sqlite3MemSetDefault;
  gMallocMutex := sqlite3MutexAlloc(SQLITE_MUTEX_STATIC_MEM);
  gMem0Mutex   := gMallocMutex;
  Result := sqlite3GlobalConfig.m.xInit(sqlite3GlobalConfig.m.pAppData);
end;

procedure sqlite3MallocEnd;
begin
  if Assigned(sqlite3GlobalConfig.m.xShutdown) then
    sqlite3GlobalConfig.m.xShutdown(sqlite3GlobalConfig.m.pAppData);
  gMem0Mutex   := nil;
  gMallocMutex := nil;
end;

function sqlite3Malloc(n: i32): Pointer;
var sz: i32;
begin
  if n <= 0 then Exit(nil);
  Result := sqlite3_malloc(n);
  if (Result <> nil) and (sqlite3GlobalConfig.bMemstat <> 0) then begin
    sz := sqlite3MallocSize(Result);
    if gMallocMutex <> nil then sqlite3_mutex_enter(gMallocMutex);
    sqlite3StatusUp(SQLITE_STATUS_MEMORY_USED, sz);
    sqlite3StatusUp(SQLITE_STATUS_MALLOC_COUNT, 1);
    sqlite3StatusHighwater(SQLITE_STATUS_MALLOC_SIZE, sz);
    if gMallocMutex <> nil then sqlite3_mutex_leave(gMallocMutex);
  end;
end;

function sqlite3MallocZero64(n: u64): Pointer;
begin
  Result := sqlite3_malloc64(n);
  if Result <> nil then libc_memset(Result, 0, csize_t(n));
end;

function sqlite3DbMalloc(db: Psqlite3db; n: i32): Pointer;
begin
  Result := sqlite3_malloc(n);
end;

function sqlite3DbMallocZero(db: Psqlite3db; n: u64): Pointer;
begin
  Result := sqlite3MallocZero(csize_t(n));
end;

function sqlite3DbMallocRaw(db: Psqlite3db; n: u64): Pointer;
begin
  Result := sqlite3_malloc64(n);
end;

function sqlite3DbMallocRawNN(db: Psqlite3db; n: u64): Pointer;
begin
  Result := sqlite3_malloc64(n);
end;

procedure sqlite3DbFree(db: Psqlite3db; p: Pointer);
begin
  sqlite3_free(p);
end;

procedure sqlite3DbFreeNN(db: Psqlite3db; p: Pointer);
begin
  sqlite3_free(p);
end;

function sqlite3DbStrDup(db: Psqlite3db; z: PChar): PChar;
begin
  Result := sqlite3StrDup(z);
end;

function sqlite3DbStrNDup(db: Psqlite3db; z: PChar; n: u64): PChar;
var p: PChar;
begin
  if z = nil then Exit(nil);
  p := PChar(sqlite3_malloc64(n + 1));
  if p <> nil then begin
    libc_memcpy(p, z, csize_t(n));
    p[n] := #0;
  end;
  Result := p;
end;

function sqlite3DbRealloc(db: Psqlite3db; p: Pointer; n: u64): Pointer;
begin
  Result := sqlite3_realloc64(p, n);
end;

function sqlite3DbMallocSize(db: Psqlite3db; p: Pointer): i32;
begin
  Result := sqlite3MallocSize(p);
end;

function sqlite3DbReallocOrFree(db: Psqlite3db; p: Pointer; n: u64): Pointer;
begin
  Result := sqlite3_realloc64(p, n);
  if Result = nil then sqlite3_free(p);
end;

{ sqlite3OomFault — port of malloc.c:827.
  Set the OOM flag, interrupt running VDBEs, and disable lookaside. }
procedure sqlite3OomFault(db: Psqlite3db);
var
  p: PTsqlite3;
begin
  if db = nil then Exit;
  p := PTsqlite3(db);
  if (p^.mallocFailed = 0) and (p^.bBenignMalloc = 0) then begin
    p^.mallocFailed := 1;
    if p^.nVdbeExec > 0 then
      p^.u1.isInterrupted := 1;
    { DisableLookaside: bump bDisable and clear sz }
    Inc(p^.lookaside.bDisable);
    p^.lookaside.sz := 0;
    { Note: the C version also calls sqlite3ErrorMsg(db->pParse, ...) and
      walks pOuterParse to bump nErr/rc.  That requires codegen and is
      handled by callers via the per-API mallocFailed checks. }
  end;
end;

{ sqlite3OomClear — port of malloc.c:854.
  Clear the OOM flag once VDBE execution has settled and re-enable lookaside. }
procedure sqlite3OomClear(db: Psqlite3db);
var
  p: PTsqlite3;
begin
  if db = nil then Exit;
  p := PTsqlite3(db);
  if (p^.mallocFailed <> 0) and (p^.nVdbeExec = 0) then begin
    p^.mallocFailed := 0;
    p^.u1.isInterrupted := 0;
    { EnableLookaside: drop bDisable and restore sz from szTrue }
    if p^.lookaside.bDisable > 0 then
      Dec(p^.lookaside.bDisable);
    if p^.lookaside.bDisable = 0 then
      p^.lookaside.sz := p^.lookaside.szTrue;
  end;
end;

function sqlite3ApiExit(db: Psqlite3db; rc: i32): i32;
begin
  Result := rc;
end;

function sqlite3_memory_used: i64;
var res, mx: i64;
begin
  sqlite3_status64(SQLITE_STATUS_MEMORY_USED, @res, @mx, 0);
  Result := res;
end;

function sqlite3HeapNearlyFull: i32;
begin
  Result := gNearlyFull;
end;

{ ============================================================
  Section: Reference-counted string/blob (RCStr)  (printf.c)
  ============================================================ }

type
  PRCStr = ^TRCStr;
  TRCStr = record
    nRCRef: u64;  { reference count; total header size kept at 8 bytes }
  end;

function sqlite3RCStrNew(N: u64): PAnsiChar;
var
  p: PRCStr;
begin
  p := PRCStr(sqlite3_malloc64(N + SizeOf(TRCStr) + 1));
  if p = nil then
  begin
    Result := nil;
    Exit;
  end;
  p^.nRCRef := 1;
  Result := PAnsiChar(PByte(p) + SizeOf(TRCStr));
end;

function sqlite3RCStrRef(z: PAnsiChar): PAnsiChar;
var
  p: PRCStr;
begin
  Assert(z <> nil);
  p := PRCStr(PByte(z) - SizeOf(TRCStr));
  Inc(p^.nRCRef);
  Result := z;
end;

procedure sqlite3RCStrUnref(z: Pointer); cdecl;
var
  p: PRCStr;
begin
  Assert(z <> nil);
  p := PRCStr(PByte(z) - SizeOf(TRCStr));
  Assert(p^.nRCRef > 0);
  if p^.nRCRef >= 2 then
    Dec(p^.nRCRef)
  else
    sqlite3_free(p);
end;

function sqlite3RCStrResize(z: PAnsiChar; N: u64): PAnsiChar;
var
  p, pNew: PRCStr;
begin
  Assert(z <> nil);
  p := PRCStr(PByte(z) - SizeOf(TRCStr));
  Assert(p^.nRCRef = 1);
  pNew := PRCStr(sqlite3_realloc64(p, N + SizeOf(TRCStr) + 1));
  if pNew = nil then
  begin
    sqlite3_free(p);
    Result := nil;
    Exit;
  end;
  Result := PAnsiChar(PByte(pNew) + SizeOf(TRCStr));
end;

{ ============================================================
  Section: Benign malloc hooks  (fault.c)
  ============================================================ }

var
  gBenignBeginProc: Pointer = nil;
  gBenignEndProc:   Pointer = nil;

procedure sqlite3BenignMallocHooks(xBegin, xEnd: Pointer);
begin
  gBenignBeginProc := xBegin;
  gBenignEndProc   := xEnd;
end;

procedure sqlite3BeginBenignMalloc;
type TProc = procedure;
begin
  if gBenignBeginProc <> nil then TProc(gBenignBeginProc)();
end;

procedure sqlite3EndBenignMalloc;
type TProc = procedure;
begin
  if gBenignEndProc <> nil then TProc(gBenignEndProc)();
end;

{ ============================================================
  Section: FaultSim  (util.c)
  ============================================================ }

function sqlite3FaultSim(iTest: i32): i32;
type
  TFaultSimCallback = function(i: i32): i32; cdecl;
begin
  if sqlite3GlobalConfig.xTestCallback <> nil then
    Result := TFaultSimCallback(sqlite3GlobalConfig.xTestCallback)(iTest)
  else
    Result := SQLITE_OK;
end;

{ ============================================================
  Section: printf  (printf.c)
  Implementation: delegate to libc vasprintf / vsnprintf.
  SQLite-specific format extensions (%q, %Q, %w, %z) are
  TODO: implemented as pass-through stubs for Phase 2.
  Full port deferred to Phase 6.
  ============================================================ }

function sqlite3_vmprintf(zFormat: PChar; va: Pointer): PChar; cdecl;
var
  rawStr: PChar;
  n:      i32;
begin
  n := libc_vasprintf(rawStr, zFormat, va);
  if n < 0 then Exit(nil);
  Result := rawStr;
end;

function sqlite3_mprintf(zFormat: PChar): PChar; cdecl;
begin
  { Stub: returns copy of format for Phase 2; full port in Phase 6 }
  Result := PChar(sqlite3StrDup(zFormat));
end;

function sqlite3_vsnprintf(n: i32; zBuf: PChar; zFormat: PChar; va: Pointer): PChar; cdecl;
begin
  libc_vsnprintf(zBuf, csize_t(n), zFormat, va);
  Result := zBuf;
end;

function sqlite3_snprintf(n: i32; zBuf: PChar; zFormat: PChar): PChar; cdecl;
begin
  if (n > 0) and (zBuf <> nil) then zBuf[0] := #0;
  Result := zBuf;
end;

{ ============================================================
  Section: UTF utilities  (utf.c)
  ============================================================ }

const
  sqlite3Utf8Trans1: array[0..63] of u8 = (
    $00,$01,$02,$03,$04,$05,$06,$07,$08,$09,$0a,$0b,$0c,$0d,$0e,$0f,
    $10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$1a,$1b,$1c,$1d,$1e,$1f,
    $00,$01,$02,$03,$04,$05,$06,$07,$08,$09,$0a,$0b,$0c,$0d,$0e,$0f,
    $00,$01,$02,$03,$04,$05,$06,$07,$00,$01,$02,$03,$00,$01,$00,$00
  );

function sqlite3Utf8Read(pIn: PPChar): u32;
var
  c: u32;
  p: Pu8;
begin
  p := Pu8(pIn^);
  c := p^;
  Inc(p);
  if c >= $c0 then begin
    c := sqlite3Utf8Trans1[c - $c0];
    while (p^ and $c0) = $80 do begin
      c := (c shl 6) or u32(p^ and $3f);
      Inc(p);
    end;
    if c < $80 then c := $fffd;
  end;
  pIn^ := PChar(p);
  Result := c;
end;

function sqlite3Utf8ReadLimited(z: Pu8; n: i32; out piOut: u32): i32;
var
  c: u32;
  i: i32;
begin
  i := 1;
  c := z[0];
  if c >= $c0 then begin
    c := sqlite3Utf8Trans1[c - $c0];
    if n > 4 then n := 4;
    while (i < n) and ((z[i] and $c0) = $80) do begin
      c := (c shl 6) + u32(z[i] and $3f);
      Inc(i);
    end;
  end;
  piOut := c;
  Result := i;
end;

function sqlite3Utf8CharLen(z: PChar; nByte: i32): i32;
var
  r: i32;
  p: PChar;
  zEnd: PChar;
begin
  r := 0;
  p := z;
  if nByte < 0 then
    zEnd := PChar(PtrUInt(High(PtrUInt)))
  else
    zEnd := z + nByte;
  while (p < zEnd) and (p^ <> #0) do begin
    sqlite3Utf8Read(@p);
    Inc(r);
  end;
  Result := r;
end;

function sqlite3AppendOneUtf8Character(zOut: PChar; v: u32): i32;
begin
  if v < $80 then begin
    zOut[0] := Char(v and $ff);
    Exit(1);
  end;
  if v < $800 then begin
    zOut[0] := Char($c0 or u8((v shr 6) and $1f));
    zOut[1] := Char($80 or u8(v and $3f));
    Exit(2);
  end;
  if v < $10000 then begin
    zOut[0] := Char($e0 or u8((v shr 12) and $0f));
    zOut[1] := Char($80 or u8((v shr 6) and $3f));
    zOut[2] := Char($80 or u8(v and $3f));
    Exit(3);
  end;
  zOut[0] := Char($f0 or u8((v shr 18) and $07));
  zOut[1] := Char($80 or u8((v shr 12) and $3f));
  zOut[2] := Char($80 or u8((v shr 6) and $3f));
  zOut[3] := Char($80 or u8(v and $3f));
  Result := 4;
end;

{ ============================================================
  Pragma/URI helpers (pragma.c + main.c)
  ============================================================ }

{ pragma.c ~72: getSafetyLevel -- interpret string as safety/sync level }
function getSafetyLevel(z: PChar; omitFull: i32; dflt: u8): u8;
const
  zText   : PChar  = 'onoffalseyestruextrafull';
  iOffset : array[0..7] of u8 = (0, 1, 2,  4,  9, 12, 15, 20);
  iLength : array[0..7] of u8 = (2, 2, 3,  5,  3,  4,  5,  4);
  iValue  : array[0..7] of u8 = (1, 0, 0,  0,  1,  1,  3,  2);
var
  i, n: i32;
begin
  if sqlite3Isdigit(u8(z^)) <> 0 then Exit(u8(sqlite3Atoi(z)));
  n := sqlite3Strlen30(z);
  for i := 0 to 7 do
  begin
    if (iLength[i] = n) and
       (sqlite3_strnicmp(zText + iOffset[i], z, n) = 0) and
       ((omitFull = 0) or (iValue[i] <= 1)) then
      Exit(iValue[i]);
  end;
  Result := dflt;
end;

{ pragma.c ~97: sqlite3GetBoolean }
function sqlite3GetBoolean(z: PChar; dflt: u8): u8;
begin
  if getSafetyLevel(z, 1, dflt) <> 0 then Result := 1 else Result := 0;
end;

{ main.c ~3306: uriParameter (internal) }
function uriParameter(zFilename: PChar; zParam: PChar): PChar;
begin
  zFilename := zFilename + sqlite3Strlen30(zFilename) + 1;
  while zFilename^ <> #0 do
  begin
    if StrComp(zFilename, zParam) = 0 then
    begin
      zFilename := zFilename + sqlite3Strlen30(zFilename) + 1;
      Exit(zFilename);
    end;
    zFilename := zFilename + sqlite3Strlen30(zFilename) + 1;
    zFilename := zFilename + sqlite3Strlen30(zFilename) + 1;
  end;
  Result := nil;
end;

{ main.c ~4795: databaseName (internal) -- walk back past 4-byte zero prefix }
function databaseName(zName: PChar): PChar;
begin
  while (zName[-1] <> #0) or (zName[-2] <> #0) or
        (zName[-3] <> #0) or (zName[-4] <> #0) do
    Dec(zName);
  Result := zName;
end;

{ main.c ~4875: sqlite3_uri_parameter }
function sqlite3_uri_parameter(zFilename: PChar; zParam: PChar): PChar;
begin
  if (zFilename = nil) or (zParam = nil) then Exit(nil);
  zFilename := databaseName(zFilename);
  Result := uriParameter(zFilename, zParam);
end;

{ main.c ~4898: sqlite3_uri_boolean }
function sqlite3_uri_boolean(zFilename: PChar; zParam: PChar; bDflt: i32): i32;
var
  z  : PChar;
  df : u8;
begin
  z := sqlite3_uri_parameter(zFilename, zParam);
  if bDflt <> 0 then df := 1 else df := 0;
  if z <> nil then Result := sqlite3GetBoolean(z, df)
  else Result := df;
end;

{ util.c ~1357: sqlite3Atoi -- parse integer from string }
function sqlite3Atoi(z: PChar): i32;
var
  v   : i64;
  neg : i32;
  c   : i32;
begin
  v   := 0;
  neg := 0;
  if z = nil then Exit(0);
  if z^ = '-' then begin neg := 1; Inc(z); end
  else if z^ = '+' then Inc(z);
  while sqlite3Isdigit(u8(z^)) <> 0 do
  begin
    c := Ord(z^) - Ord('0');
    if v > (High(i32) - c) div 10 then begin v := High(i32); break; end;
    v := v * 10 + c;
    Inc(z);
  end;
  if neg <> 0 then v := -v;
  Result := i32(v);
end;

{ ============================================================
  String helpers (util.c)
  ============================================================ }

{ util.c ~298: sqlite3Dequote — remove surrounding quotes in-place }
procedure sqlite3Dequote(z: PAnsiChar);
var
  quote: AnsiChar;
  i, j: i32;
begin
  if z = nil then Exit;
  quote := z[0];
  if (quote <> '"') and (quote <> '''') and (quote <> '[') and (quote <> '`') then Exit;
  if quote = '[' then quote := ']';
  j := 0;
  i := 1;
  while True do
  begin
    if z[i] = #0 then Break;
    if z[i] = quote then
    begin
      if z[i+1] = quote then
      begin
        z[j] := quote;
        Inc(j);
        Inc(i, 2);
      end else
        Break;
    end else
    begin
      z[j] := z[i];
      Inc(j);
      Inc(i);
    end;
  end;
  z[j] := #0;
end;

{ util.c equivalent: duplicate string from zStart up to (not including) zEnd }
function sqlite3DbSpanDup(db: Psqlite3db; zStart: PAnsiChar; zEnd: PAnsiChar): PAnsiChar;
var n: i32;
begin
  if zStart = nil then begin Result := nil; Exit; end;
  if zEnd = nil then
    n := sqlite3Strlen30(zStart)
  else
    n := zEnd - zStart;
  Result := sqlite3DbStrNDup(db, zStart, u64(n));
end;

{ malloc.c ~458: sqlite3DbNNFreeNN — free; both db and p guaranteed non-nil }
procedure sqlite3DbNNFreeNN(db: Psqlite3db; p: Pointer);
begin
  sqlite3DbFreeNN(db, p);
end;

{ util.c: sqlite3GetInt32 — parse a decimal integer string into *pValue.
  Returns 1 on success (fits in i32), 0 on failure. }
function sqlite3GetInt32(zNum: PAnsiChar; pValue: Pi32): i32;
var
  v:    i64;
  neg:  Boolean;
  p:    PAnsiChar;
begin
  Result := 0;
  if zNum = nil then Exit;
  p   := zNum;
  neg := False;
  if p^ = '-' then begin neg := True; Inc(p); end
  else if p^ = '+' then Inc(p);
  if not (p^ in ['0'..'9']) then Exit;
  v := 0;
  while p^ in ['0'..'9'] do
  begin
    v := v * 10 + (Ord(p^) - Ord('0'));
    if v > $80000000 then Exit;
    Inc(p);
  end;
  if neg then v := -v;
  if (v < Low(i32)) or (v > High(i32)) then Exit;
  if pValue <> nil then pValue^ := i32(v);
  Result := 1;
end;

{ Decimal-only u32 parser, mirrors util.c:1533 sqlite3GetUInt32.
  Returns 1 on success and stores the parsed value in pI^; returns 0
  on failure (non-digit, empty, overflow, trailing garbage) and sets
  pI^ := 0 in the failure cases that the C reference also clears. }
function sqlite3GetUInt32(z: PAnsiChar; pI: Pu32): i32;
var
  v: u64;
  p: PAnsiChar;
  i: i32;
begin
  v := 0;
  i := 0;
  if z = nil then begin
    if pI <> nil then pI^ := 0;
    Result := 0; Exit;
  end;
  p := z;
  while p^ in ['0'..'9'] do begin
    v := v * 10 + u64(Ord(p^) - Ord('0'));
    if v > u64($100000000) then begin   { > 2^32, matching C's 4294967296LL gate }
      if pI <> nil then pI^ := 0;
      Result := 0; Exit;
    end;
    Inc(p); Inc(i);
  end;
  if (i = 0) or (p^ <> #0) then begin
    if pI <> nil then pI^ := 0;
    Result := 0; Exit;
  end;
  if pI <> nil then pI^ := u32(v);
  Result := 1;
end;

{ ============================================================
  Initialisation
  ============================================================ }

initialization
  InitUpperToLower;
  InitCtypeMap;
  InitGlobalConfig;
  libc_memset(@sqlite3Stat, 0, SizeOf(sqlite3Stat));
  libc_memset(@sqlite3Prng, 0, SizeOf(sqlite3Prng));

end.
