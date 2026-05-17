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
unit passqlite3btree;

{
  Pascal port of SQLite's B-tree layer.
  Source files: btree.c (~11.6 k lines), btmutex.c (~309 lines).
  Headers:      btree.h, btreeInt.h.

  Phase 4.1 — cell-parsing helpers and page management infrastructure:
    - All types from btreeInt.h (MemPage, BtShared, Btree, BtCursor, …)
    - get2byte / put2byte / get2byteAligned / get2byteNotZero helpers
    - Cell-parsing:  btreeParseCellPtr, btreeParseCellPtrNoPayload,
                     btreeParseCellPtrIndex, btreeParseCell,
                     btreeParseCellAdjustSizeForOverflow, btreePayloadToLocal
    - Cell-size:     cellSizePtr, cellSizePtrIdxLeaf, cellSizePtrNoPayload,
                     cellSizePtrTableLeaf
    - findCell / findCellPastPtr inline helpers
    - Space management: pageFindSlot, allocateSpace, freeSpace, defragmentPage
    - Page lifecycle:   decodeFlags, btreeComputeFreeSpace, btreeCellSizeCheck,
                        btreeInitPage, zeroPage, btreePageFromDbPage,
                        btreeGetPage, btreePageLookup, btreePagecount
    - Cell operations:  dropCell, insertCell, insertCellFast
    - Pager helpers added here to avoid circular deps: sqlite3PagerIswriteable,
                        sqlite3PagerPagenumber, sqlite3PagerTempSpace
}

interface

uses
  SysUtils,
  ctypes,
  passqlite3types,
  passqlite3os,
  passqlite3util,
  passqlite3pcache,
  passqlite3pager;

{ ===========================================================================
  Constants from btreeInt.h and btree.h (must be before type block so that
  BTCURSOR_MAX_DEPTH is available for array bounds in TBtCursor)
  =========================================================================== }
const
  { Page-type flags — first byte of every btree page header }
  PTF_INTKEY   = $01;
  PTF_ZERODATA = $02;
  PTF_LEAFDATA = $04;
  PTF_LEAF     = $08;

  { BtLock.eLock values }
  READ_LOCK  = 1;
  WRITE_LOCK = 2;

  { Btree.inTrans values — must match SQLITE_TXN_* }
  TRANS_NONE  = 0;
  TRANS_READ  = 1;
  TRANS_WRITE = 2;

  { BtShared.btsFlags bits }
  BTS_READ_ONLY       = $0001;
  BTS_PAGESIZE_FIXED  = $0002;
  BTS_SECURE_DELETE   = $0004;
  BTS_OVERWRITE       = $0008;
  BTS_FAST_SECURE     = $000C;  { SECURE_DELETE | OVERWRITE }
  BTS_INITIALLY_EMPTY = $0010;
  BTS_NO_WAL          = $0020;
  BTS_EXCLUSIVE       = $0040;
  BTS_PENDING         = $0080;

  { BtCursor.curFlags bits }
  BTCF_WriteFlag  = $01;
  BTCF_ValidNKey  = $02;
  BTCF_ValidOvfl  = $04;
  BTCF_AtLast     = $08;
  BTCF_Incrblob   = $10;
  BTCF_Multiple   = $20;
  BTCF_Pinned     = $40;

  { BtCursor.eState values }
  CURSOR_VALID       = 0;
  CURSOR_INVALID     = 1;
  CURSOR_SKIPNEXT    = 2;
  CURSOR_REQUIRESEEK = 3;
  CURSOR_FAULT       = 4;

  { Pointer-map entry types }
  PTRMAP_ROOTPAGE  = 1;
  PTRMAP_FREEPAGE  = 2;
  PTRMAP_OVERFLOW1 = 3;
  PTRMAP_OVERFLOW2 = 4;
  PTRMAP_BTREE     = 5;

  { B-tree structural limits }
  BTCURSOR_MAX_DEPTH = 20;
  BT_MAX_LOCAL       = 65501;   { 65536 - 35 }

  { From btree.h }
  SQLITE_N_BTREE_META       = 16;
  SQLITE_DEFAULT_AUTOVACUUM = 0;
  BTREE_AUTOVACUUM_NONE     = 0;
  BTREE_AUTOVACUUM_FULL     = 1;
  BTREE_AUTOVACUUM_INCR     = 2;
  BTREE_OMIT_JOURNAL        = 1;
  BTREE_MEMORY              = 2;
  BTREE_SINGLE              = 4;
  BTREE_UNORDERED           = 8;
  BTREE_INTKEY              = 1;
  BTREE_BLOBKEY             = 2;

  { btree.h lines 152-161: meta-data slot indices for GetMeta/UpdateMeta }
  BTREE_FREE_PAGE_COUNT     = 0;
  BTREE_SCHEMA_VERSION      = 1;
  BTREE_FILE_FORMAT         = 2;
  BTREE_DEFAULT_CACHE_SIZE  = 3;
  BTREE_LARGEST_ROOT_PAGE   = 4;
  BTREE_TEXT_ENCODING       = 5;
  BTREE_USER_VERSION        = 6;
  BTREE_INCR_VACUUM         = 7;
  BTREE_APPLICATION_ID      = 8;
  BTREE_DATA_VERSION        = 15;  { virtual meta-value: DataVersion from pager }

  { SQLITE_CellSizeCk (from sqliteInt.h) — enables PRAGMA cell_size_check }
  SQLITE_CellSizeCk = $00200000;

{ ===========================================================================
  All types in one block (FPC requires forward types resolved in same block)
  =========================================================================== }
type
  { Opaque pointers for layers not yet ported }
  Psqlite3  = Pointer;   { sqlite3 — full def in passqlite3.pas (Phase 8) }
  PKeyInfo  = Pointer;   { KeyInfo — full def in passqlite3codegen.pas (Phase 6) }

  { Pointer forward declarations (needed for mutual references) }
  PMemPage  = ^TMemPage;
  PPMemPage = ^PMemPage;    { PMemPage* — out-param for getAndInitPage }
  PBtShared = ^TBtShared;
  PBtCursor = ^TBtCursor;
  PBtree    = ^TBtree;
  PBtLock   = ^TBtLock;
  PCellInfo = ^TCellInfo;

  { Function pointer types used in TMemPage }
  TxCellSize  = function(pPage: PMemPage; pCell: Pu8): u16;
  TxParseCell = procedure(pPage: PMemPage; pCell: Pu8; pInfo: PCellInfo);

  { CellInfo — result of parsing a single btree cell }
  TCellInfo = record
    nKey     : i64;   { INTKEY table key, or nPayload otherwise }
    pPayload : Pu8;   { Pointer to start of payload }
    nPayload : u32;   { Bytes of payload }
    nLocal   : u16;   { Amount of payload held locally, not on overflow }
    nSize    : u16;   { Size of cell content on the main b-tree page }
  end;

{ ===========================================================================
  TMemPage — one in-memory B-tree page
  =========================================================================== }
  TMemPage = record
    isInit          : u8;        { True if previously initialized. MUST BE FIRST! }
    intKey          : u8;        { True for table b-trees }
    intKeyLeaf      : u8;        { True if leaf of intKey table }
    pgno            : Pgno;      { Page number for this page }
    { Only bytes 0-7 above are zeroed by pager when a new page is allocated.
      All fields that follow must be initialized before use. }
    leaf            : u8;        { True if a leaf page }
    hdrOffset       : u8;        { 100 for page 1, 0 otherwise }
    childPtrSize    : u8;        { 0 if leaf==1, 4 if leaf==0 }
    max1bytePayload : u8;        { min(maxLocal, 127) }
    nOverflow       : u8;        { Number of overflow cell bodies in apOvfl[] }
    maxLocal        : u16;       { Copy of BtShared.maxLocal or .maxLeaf }
    minLocal        : u16;       { Copy of BtShared.minLocal or .minLeaf }
    cellOffset      : u16;       { Index in aData of first cell pointer }
    nFree           : i32;       { Number of free bytes on page (-1 = unknown) }
    nCell           : u16;       { Number of cells on this page }
    maskPage        : u16;       { Mask for page offset }
    aiOvfl          : array[0..3] of u16;  { Overflow-cell insertion indices }
    apOvfl          : array[0..3] of Pu8;  { Pointers to overflow cell bodies }
    pBt             : PBtShared; { The BtShared this page belongs to }
    aData           : Pu8;       { Pointer to on-disk image of page data }
    aDataEnd        : Pu8;       { One byte past end of entire page }
    aCellIdx        : Pu8;       { The cell index area }
    aDataOfst       : Pu8;       { Same as aData for leaves; aData+4 for interior }
    pDbPage         : PDbPage;   { Pager page handle }
    xCellSize       : TxCellSize;   { Dispatch: cell size method }
    xParseCell      : TxParseCell;  { Dispatch: cell parse method }
  end;

{ ===========================================================================
  TBtLock — per-table lock record (shared cache)
  =========================================================================== }
  TBtLock = record
    pBtree : PBtree;   { Btree handle holding this lock }
    iTable : Pgno;     { Root page of the table being locked }
    eLock  : u8;       { READ_LOCK or WRITE_LOCK }
    pNext  : PBtLock;  { Next in BtShared.pLock list }
  end;

{ ===========================================================================
  TBtree — per-connection B-tree handle
  =========================================================================== }
  TBtree = record
    db             : Psqlite3;   { The database connection holding this btree }
    pBt            : PBtShared;  { Sharable content of this btree }
    inTrans        : u8;         { TRANS_NONE, TRANS_READ or TRANS_WRITE }
    sharable       : u8;         { True if we can share pBt with another db }
    locked         : u8;         { True if db currently has pBt locked }
    hasIncrblobCur : u8;         { True if one or more Incrblob cursors exist }
    wantToLock     : i32;        { Nested calls to sqlite3BtreeEnter() }
    nBackup        : i32;        { Number of backup operations reading this btree }
    iBDataVersion  : u32;        { Combines with pBt->pPager->iDataVersion }
    pNext          : PBtree;     { Next sharable Btree from same db }
    pPrev          : PBtree;     { Back pointer of same list }
    lock           : TBtLock;    { Object used to lock page 1 (shared cache) }
  end;

{ ===========================================================================
  TBtShared — shared state for one physical database file
  =========================================================================== }
  TBtShared = record
    pPager         : PPager;         { The page cache }
    db             : Psqlite3;       { Database connection currently using this }
    pCursor        : PBtCursor;      { A list of all open cursors }
    pPage1         : PMemPage;       { First page of the database }
    openFlags      : u8;             { Flags to sqlite3BtreeOpen() }
    autoVacuum     : u8;             { True if auto-vacuum is enabled }
    incrVacuum     : u8;             { True if incr-vacuum is enabled }
    bDoTruncate    : u8;             { True to truncate db on commit }
    inTransaction  : u8;             { Transaction state }
    max1bytePayload: u8;             { Max first byte of cell for 1-byte payload }
    nReserveWanted : u8;             { Desired number of extra bytes per page }
    btsFlags       : u16;            { Boolean parameters — see BTS_* macros }
    maxLocal       : u16;            { Max local payload in non-LEAFDATA tables }
    minLocal       : u16;            { Min local payload in non-LEAFDATA tables }
    maxLeaf        : u16;            { Max local payload in LEAFDATA tables }
    minLeaf        : u16;            { Min local payload in LEAFDATA tables }
    pageSize       : u32;            { Total bytes on a page }
    usableSize     : u32;            { Usable bytes per page }
    nTransaction   : i32;            { Number of open transactions (read + write) }
    nPage          : u32;            { Number of pages in the database }
    pSchema        : Pointer;        { Allocated by sqlite3BtreeSchema() }
    xFreeSchema    : procedure(p: Pointer); { Destructor for pSchema }
    mutex          : Psqlite3_mutex; { Non-recursive mutex required to access }
    pHasContent    : PBitvec;        { Pages moved to free-list this transaction }
    nRef           : i32;            { Number of references (shared cache) }
    pNext          : PBtShared;      { Next on list of sharable BtShared structs }
    pLock          : PBtLock;        { List of locks held on this struct }
    pWriter        : PBtree;         { Btree with currently open write transaction }
    pTmpSpace      : Pu8;            { Temp space sufficient to hold a single cell }
    nPreformatSize : i32;            { Size of last cell written by TransferRow() }
  end;

{ ===========================================================================
  TBtCursor — a positioned pointer into a B-tree
  =========================================================================== }
  TBtCursor = record
    eState        : u8;           { One of the CURSOR_XXX constants }
    curFlags      : u8;           { Zero or more BTCF_* flags }
    curPagerFlags : u8;           { Flags to send to sqlite3PagerGet() }
    hints         : u8;           { As configured by CursorSetHints() }
    skipNext      : i32;          { Prev/Next noop control; or fault error code }
    pBtree        : PBtree;       { The Btree to which this cursor belongs }
    aOverflow     : PPgno;        { Cache of overflow page locations }
    pKey          : Pointer;      { Saved key for last known position }
    { === All fields above are zeroed by sqlite3BtreeCursorZero().
          Fields below must be manually initialized. === }
    pBt           : PBtShared;    { The BtShared this cursor points to }
    pNext         : PBtCursor;    { Linked list of all cursors }
    info          : TCellInfo;    { Parse of the cell we are pointing at }
    nKey          : i64;          { Size of pKey, or last integer key }
    pgnoRoot      : Pgno;         { Root page of this tree }
    iPage         : i8;           { Index of current page in apPage }
    curIntKey     : u8;           { Value of apPage[0]^.intKey }
    ix            : u16;          { Current index for apPage[iPage] }
    aiIdx         : array[0..BTCURSOR_MAX_DEPTH-2] of u16;
    pKeyInfo      : PKeyInfo;     { Arg passed to comparison function }
    pPage         : PMemPage;     { Current page }
    apPage        : array[0..BTCURSOR_MAX_DEPTH-2] of PMemPage;
  end;

{ ===========================================================================
  Public function declarations
  =========================================================================== }

{ Pager helpers needed by btree (bridged here to avoid circular unit deps) }
function  sqlite3PagerIswriteable(pPg: PDbPage): i32; inline;
function  sqlite3PagerPagenumber(pPg: PDbPage): Pgno; inline;
function  sqlite3PagerTempSpace(pPager: PPager): Pointer; inline;

{ Big-endian 2-byte accessors (btreeInt.h macros) }
function  get2byte(p: Pu8): i32; inline;
procedure put2byte(p: Pu8; v: i32); inline;
function  get2byteAligned(p: Pu8): i32; inline;  { same as get2byte on x86 }
function  get2byteNotZero(p: Pu8): i32; inline;  { 0 → 65536 }
{ Big-endian 4-byte accessors (btreeInt.h get4byte/put4byte macros) }
function  get4byte(p: Pu8): u32; inline;
procedure put4byte(p: Pu8; v: u32); inline;

{ Corruption-return helper }
function  CORRUPT_PAGE(pPage: PMemPage): i32; inline;

{ Cell parsing }
procedure btreeParseCellAdjustSizeForOverflow(pPage: PMemPage; pCell: Pu8; pInfo: PCellInfo);
function  btreePayloadToLocal(pPage: PMemPage; nPayload: i64): i32;
procedure btreeParseCellPtrNoPayload(pPage: PMemPage; pCell: Pu8; pInfo: PCellInfo); inline;
procedure btreeParseCellPtr(pPage: PMemPage; pCell: Pu8; pInfo: PCellInfo); inline;
procedure btreeParseCellPtrIndex(pPage: PMemPage; pCell: Pu8; pInfo: PCellInfo); inline;
procedure btreeParseCell(pPage: PMemPage; iCell: i32; pInfo: PCellInfo);

{ Cell size }
function  cellSizePtr(pPage: PMemPage; pCell: Pu8): u16;
function  cellSizePtrIdxLeaf(pPage: PMemPage; pCell: Pu8): u16;
function  cellSizePtrNoPayload(pPage: PMemPage; pCell: Pu8): u16;
function  cellSizePtrTableLeaf(pPage: PMemPage; pCell: Pu8): u16;

{ findCell / findCellPastPtr — btreeInt.h macros }
function  findCell(pPage: PMemPage; i: i32): Pu8; inline;
function  findCellPastPtr(pPage: PMemPage; i: i32): Pu8; inline;

{ Free-space and page management }
function  pageFindSlot(pPg: PMemPage; nByte: i32; out pRc: i32): Pu8;
function  allocateSpace(pPage: PMemPage; nByte: i32; out pIdx: i32): i32;
function  freeSpace(pPage: PMemPage; iStart: i32; iSize: i32): i32; inline;
function  defragmentPage(pPage: PMemPage; nMaxFrag: i32): i32;
function  decodeFlags(pPage: PMemPage; flagByte: i32): i32;
function  btreeComputeFreeSpace(pPage: PMemPage): i32;
function  btreeCellSizeCheck(pPage: PMemPage): i32;
function  btreeInitPage(pPage: PMemPage): i32;
procedure zeroPage(pPage: PMemPage; flags: i32);

{ Page fetch helpers }
function  btreePageFromDbPage(pDbPage: PDbPage; pgno: Pgno; pBt: PBtShared): PMemPage;
function  btreeGetPage(pBt: PBtShared; pgno: Pgno; out ppPage: PMemPage; flags: i32): i32;
function  btreePageLookup(pBt: PBtShared; pgno: Pgno): PMemPage;
function  btreePagecount(pBt: PBtShared): Pgno; inline;

{ Cell insert / drop }
procedure dropCell(pPage: PMemPage; idx: i32; sz: i32; pRC: Pi32);
function  insertCell(pPage: PMemPage; i: i32; pCell: Pu8; sz: i32;
                     pTemp: Pu8; iChild: Pgno): i32;
function  insertCellFast(pPage: PMemPage; i: i32; pCell: Pu8; sz: i32): i32;

{ ===========================================================================
  Helper macros from btreeInt.h / sqliteInt.h
  =========================================================================== }
{ MX_CELL_SIZE(pBt) = pageSize - 8 }
function MX_CELL_SIZE(pBt: PBtShared): i32; inline;
{ MX_CELL(pBt) = (pageSize - 8) / 6 }
function MX_CELL(pBt: PBtShared): i32; inline;

{ ===========================================================================
  Phase 4.2 additional constants (btree.h)
  =========================================================================== }
const
  BTREE_WRCSR        = $00000004;  { Read-write cursor flag }
  BTREE_FORDELETE    = $00000008;  { Cursor is for seek/delete only (hint) }
  BTREE_SAVEPOSITION = $02;        { Leave cursor at NEXT/PREV on delete }
  BTREE_AUXDELETE    = $04;        { Not the primary delete operation }
  BTREE_APPEND       = $08;        { Insert is likely an append }
  BTREE_PREFORMAT    = $80;        { Inserted data is a pre-formatted cell }
  BTREE_BULKLOAD     = $00000001;  { Used to fill index in sorted order }

  { allocateBtreePage eMode values (btree.c lines 49-51) }
  BTALLOC_ANY   = 0;
  BTALLOC_EXACT = 1;
  BTALLOC_LE    = 2;

  { Balance neighbor counts (btree.c lines 7504-7505) }
  NN = 1;
  NB = 3;

{ ===========================================================================
  Phase 4.2 opaque type stubs (resolved in later phases)
  =========================================================================== }
type
  { UnpackedRecord — ported from vdbeInt.h (exposed here for btree + vdbe).
    Phase 6.9(c) reconcile: layout now matches the C struct (sizeof=40)
    and codegen.pas TUnpackedRecord exactly, so a record allocated by
    either side is interchangeable. }
  TUnpackedRecordU = record
    case Integer of
      0: (z: PAnsiChar);
      1: (i: i64);
  end;
  TUnpackedRecord = record
    pKeyInfo  : PKeyInfo;             { 8 bytes @ 0  }
    aMem      : Pointer;              { 8 bytes @ 8  — Psqlite3_value array }
    u         : TUnpackedRecordU;     { 8 bytes @ 16 }
    n         : i32;                  { 4 bytes @ 24 }
    nField    : u16;                  { 2 bytes @ 28 }
    default_rc: i8;                   { 1 byte  @ 30 }
    errCode   : u8;                   { 1 byte  @ 31 }
    r1        : i8;                   { 1 byte  @ 32 }
    r2        : i8;                   { 1 byte  @ 33 }
    eqSeen    : u8;                   { 1 byte  @ 34 }
    _pad35    : array[0..4] of u8;    { 5 bytes @ 35 }
  end;
  PUnpackedRecord = ^TUnpackedRecord;
  { RecordCompare function pointer type }
  TRecordCompare  = function(nKey: i32; pKey: Pointer;
                             pRec: PUnpackedRecord): i32;

  { BtreePayload — content descriptor for sqlite3BtreeInsert (btree.h:307-315) }
  Psqlite3_value = Pointer;   { sqlite3_value stub — full def in Phase 6 }
  TBtreePayload = record
    pKey  : Pointer;         { Key for indexes; NULL for tables }
    nKey  : i64;             { Key size for indexes; rowid for tables }
    pData : Pointer;         { Row data for tables }
    aMem  : Psqlite3_value;  { Unpacked key values (index cursors) }
    nMem  : u16;             { Number of aMem[] values }
    nData : i32;             { Size of pData }
    nZero : i32;             { Extra zero bytes after pData }
  end;
  PBtreePayload = ^TBtreePayload;

{ ===========================================================================
  Phase 4.2 — page release / cursor lifecycle
  =========================================================================== }
procedure releasePageNotNull(pPage: PMemPage);
procedure releasePage(pPage: PMemPage);
procedure releasePageOne(pPage: PMemPage);
procedure unlockBtreeIfUnused(pBt: PBtShared);
function  getAndInitPage(pBt: PBtShared; pgno: Pgno; out ppPage: PMemPage;
                         bReadOnly: i32): i32;
function  allocateTempSpace(pBt: PBtShared): i32;
procedure freeTempSpace(pBt: PBtShared);
procedure invalidateOverflowCache(pCur: PBtCursor);
procedure invalidateAllOverflowCache(pBt: PBtShared);
procedure btreeReleaseAllCursorPages(pCur: PBtCursor);
procedure sqlite3BtreeClearCursor(pCur: PBtCursor);
procedure sqlite3BtreeCursorZero(p: PBtCursor);
function  sqlite3BtreeCursorSize: i32;
function  btreeCursor(p: PBtree; iTable: Pgno; wrFlag: i32;
                      pKeyInfo: PKeyInfo; pCur: PBtCursor): i32;
function  sqlite3BtreeCursor(p: PBtree; iTable: Pgno; wrFlag: i32;
                             pKeyInfo: PKeyInfo; pCur: PBtCursor): i32;
function  sqlite3BtreeCloseCursor(pCur: PBtCursor): i32;
procedure sqlite3BtreeCursorHintFlags(pCur: PBtCursor; x: u32);
function  sqlite3BtreeCursorHasHint(pCur: PBtCursor; mask: u32): i32;

{ ===========================================================================
  Phase 4.2 — cursor save/restore
  =========================================================================== }
function  saveCursorKey(pCur: PBtCursor): i32;
function  saveCursorPosition(pCur: PBtCursor): i32;
function  btreeRestoreCursorPosition(pCur: PBtCursor): i32;
{ Inline macro: if state >= CURSOR_REQUIRESEEK call the helper else SQLITE_OK }
function  restoreCursorPosition(pCur: PBtCursor): i32; inline;

{ ===========================================================================
  Phase 4.2 — navigation internals
  =========================================================================== }
function  moveToChild(pCur: PBtCursor; newPgno: Pgno): i32;
procedure moveToParent(pCur: PBtCursor);
function  moveToRoot(pCur: PBtCursor): i32;
function  moveToLeftmost(pCur: PBtCursor): i32;
function  moveToRightmost(pCur: PBtCursor): i32;

{ ===========================================================================
  Phase 4.2 — public cursor helpers
  =========================================================================== }
procedure getCellInfo(pCur: PBtCursor);
function  sqlite3BtreeCursorIsValidNN(pCur: PBtCursor): i32;
function  sqlite3BtreeCursorHasMoved(pCur: PBtCursor): i32;
function  sqlite3BtreeCursorRestore(pCur: PBtCursor; pDifferentRow: Pi32): i32;
function  sqlite3BtreeEof(pCur: PBtCursor): i32;
function  sqlite3BtreeIntegerKey(pCur: PBtCursor): i64;
function  sqlite3BtreePayloadSize(pCur: PBtCursor): u32;
function  sqlite3BtreeOffset(pCur: PBtCursor): i64;
function  sqlite3BtreeIsReadonly(p: PBtree): i32;
function  sqlite3BtreeGetFilename(p: PBtree): PAnsiChar;
function  sqlite3BtreeCheckpoint(p: PBtree; eMode: i32;
                                 pnLog, pnCkpt: PcInt): i32;

{ ===========================================================================
  Phase 4.2 — payload access
  =========================================================================== }
function  sqlite3BtreePayload(pCur: PBtCursor; offset: u32; amt: u32;
                               pBuf: Pointer): i32;
function  sqlite3BtreePayloadChecked(pCur: PBtCursor; offset: u32; amt: u32;
                                     pBuf: Pointer): i32;
function  sqlite3BtreePutData(pCsr: PBtCursor; offset: u32; amt: u32;
                              z: Pointer): i32;
procedure sqlite3BtreeIncrblobCursor(pCur: PBtCursor);
{ sqlite3BtreePayloadFetch: return pointer to in-page data if available.
  Sets pAmt to the number of contiguous bytes at the returned address.
  Returns nil if no in-page data is available (caller must use BtreePayload). }
function  sqlite3BtreePayloadFetch(pCur: PBtCursor; out pAmt: u32): PAnsiChar;
function  sqlite3BtreeMaxRecordSize(pCur: PBtCursor): u32;
function  sqlite3BtreeCursorIsValid(pCur: PBtCursor): i32;

{ ===========================================================================
  Phase 4.2 — public navigation
  =========================================================================== }
function  sqlite3BtreeFirst(pCur: PBtCursor; pRes: Pi32): i32;
function  sqlite3BtreeLast(pCur: PBtCursor; pRes: Pi32): i32;
function  sqlite3BtreeIsEmpty(pCur: PBtCursor; pRes: Pi32): i32;
function  sqlite3BtreeTableMoveto(pCur: PBtCursor; intKey: i64;
                                   biasRight: i32; pRes: Pi32): i32;
function  sqlite3BtreeIndexMoveto(pCur: PBtCursor; pIdxKey: PUnpackedRecord;
                                   pRes: Pi32): i32;
function  btreeNext(pCur: PBtCursor): i32;
function  sqlite3BtreeNext(pCur: PBtCursor; flags: i32): i32;
function  btreePrevious(pCur: PBtCursor): i32;
function  sqlite3BtreePrevious(pCur: PBtCursor; flags: i32): i32;

{ ===========================================================================
  Phase 4.2 — VDBE stubs (filled in Phase 6)
  =========================================================================== }
function  sqlite3VdbeFindCompare(pIdxKey: PUnpackedRecord): TRecordCompare;
function  sqlite3VdbeRecordCompare(nKey: i32; pKey: Pointer;
                                   pIdxKey: PUnpackedRecord): i32;

{ ---------------------------------------------------------------------------
  btreeMovetoIndexHook — vdbe.pas registers a callback here at unit init
  that allocates an UnpackedRecord, unpacks pKey into it, calls
  sqlite3BtreeIndexMoveto, then frees the record.  Pulled out of
  btreeMoveto to avoid a uses-cycle (vdbe.pas already uses btree.pas).
  --------------------------------------------------------------------------- }
type
  TBtreeMovetoIndexFn = function(pCur: PBtCursor; pKey: Pointer; nKey: i64;
                                 pRes: Pi32): i32;
var
  btreeMovetoIndexHook: TBtreeMovetoIndexFn;

{ ===========================================================================
  Phase 4.3 — Insert path public API
  =========================================================================== }
function  sqlite3BtreeInsert(pCur: PBtCursor; const pX: PBtreePayload;
                              flags: i32; seekResult: i32): i32;

{ Phase 4.3 internal helpers exposed for test access }
function  saveAllCursors(pBt: PBtShared; iRoot: Pgno; pExcept: PBtCursor): i32;
function  btreeSetHasContent(pBt: PBtShared; pgno: Pgno): i32;
function  btreeGetHasContent(pBt: PBtShared; pgno: Pgno): Boolean;
procedure btreeClearHasContent(pBt: PBtShared);
function  btreeGetUnusedPage(pBt: PBtShared; pgno: Pgno;
                              out ppPage: PMemPage; flags: i32): i32;
function  allocateBtreePage(pBt: PBtShared; out ppPage: PMemPage;
                             out pPgno: Pgno; nearby: Pgno; eMode: u8): i32;
function  freePage2(pBt: PBtShared; pMemPage: PMemPage; iPage: Pgno): i32;
procedure freePage(pPage: PMemPage; pRC: Pi32);

{ sqlite3PagerRekey — wraps sqlite3PcacheMove (used by balance_nonroot) }
procedure sqlite3PagerRekey(pPg: PDbPage; iNew: Pgno; flags: u16);

{ ===========================================================================
  Phase 4.4 — Pager page-refcount bridge
  =========================================================================== }
function  sqlite3PagerPageRefcount(pPage: PDbPage): i32;

{ ===========================================================================
  Phase 4.4 — B-tree mutex stubs (btmutex.c — SQLITE_OMIT_SHARED_CACHE path)
  =========================================================================== }
procedure sqlite3BtreeEnter(p: PBtree);
procedure sqlite3BtreeLeave(p: PBtree);
function  sqlite3BtreeHoldsMutex(p: PBtree): i32;
procedure sqlite3BtreeEnterCursor(pCur: PBtCursor);
procedure sqlite3BtreeLeaveCursor(pCur: PBtCursor);

{ ===========================================================================
  Phase 4.4 — B-tree open/close/lifecycle
  =========================================================================== }
type
  PPBtree = ^PBtree;  { pointer-to-pointer for sqlite3BtreeOpen out-param }

{ SQLite database file magic header (first 16 bytes of page 1) }
const
  SCHEMA_ROOT         = 1;   { Root page of sqlite_master }
  BTREE_ZERODATA      = 2;   { Index tables have no data }
  BTREE_LEAFDATA      = 4;   { Table b-trees have leaf data }

{ pager-callback: called when a page is reloaded after a write-back }
procedure pageReinit(pData: PDbPage);
function  btreeInvokeBusyHandler(pArg: Pointer): i32;

function  lockBtree(pBt: PBtShared): i32;
function  newDatabase(pBt: PBtShared): i32;
procedure btreeSetNPage(pBt: PBtShared; pPage1: PMemPage);
function  sqlite3BtreeNewDb(p: PBtree): i32;

function  sqlite3BtreeOpen(pVfs: Psqlite3_vfs; zFilename: PChar;
                           db: Psqlite3; ppBtree: PPBtree;
                           flags: i32; vfsFlags: i32): i32;
function  sqlite3BtreeClose(p: PBtree): i32;
function  sqlite3BtreePager(p: PBtree): PPager;

{ ===========================================================================
  Phase 4.4 — Transaction lifecycle
  =========================================================================== }
function  sqlite3BtreeTripAllCursors(pBtree: PBtree;
                                     errCode: i32; writeOnly: i32): i32;
procedure btreeEndTransaction(p: PBtree);
function  btreeBeginTrans(p: PBtree; wrflag: i32; pSchemaVersion: Pi32): i32;
function  sqlite3BtreeBeginTrans(p: PBtree; wrflag: i32;
                                  pSchemaVersion: Pi32): i32;
function  sqlite3BtreeCommitPhaseOne(p: PBtree; zSuperJrnl: PChar): i32;
function  sqlite3BtreeCommitPhaseTwo(p: PBtree; bCleanup: i32): i32;
function  sqlite3BtreeCommit(p: PBtree): i32;
function  sqlite3BtreeRollback(p: PBtree; tripCode: i32; writeOnly: i32): i32;
function  sqlite3BtreeSavepoint(p: PBtree; op: i32; iSavepoint: i32): i32;

{ ===========================================================================
  Phase 4.4 — Delete path
  =========================================================================== }
function  sqlite3BtreeDelete(pCur: PBtCursor; flags: u8): i32;

{ ===========================================================================
  Phase 4.5 — Schema / metadata
  =========================================================================== }
function  clearDatabasePage(pBt: PBtShared; pgno: Pgno;
                             freePageFlag: i32; pnChange: Pi64): i32;
function  sqlite3BtreeClearTable(p: PBtree; iTable: i32;
                                  pnChange: Pi64): i32;
function  sqlite3BtreeClearTableOfCursor(pCur: PBtCursor): i32;
function  btreeDropTable(p: PBtree; iTable: Pgno; piMoved: Pi32): i32;
function  sqlite3BtreeDropTable(p: PBtree; iTable: i32; piMoved: Pi32): i32;
function  btreeCreateTable(p: PBtree; piTable: PPgno; createTabFlags: i32): i32;
function  sqlite3BtreeCreateTable(p: PBtree; piTable: PPgno; flags: i32): i32;
procedure sqlite3BtreeGetMeta(p: PBtree; idx: i32; pMeta: Pu32);
function  sqlite3BtreeUpdateMeta(p: PBtree; idx: i32; iMeta: u32): i32;
function  sqlite3BtreeCount(db: Pointer; pCur: PBtCursor; pnEntry: Pi64): i32;
function  sqlite3BtreeRowCountEst(pCur: PBtCursor): i64;
function  sqlite3BtreeFakeValidCursor: PBtCursor;
function  sqlite3BtreeTransferRow(pDest, pSrc: PBtCursor; iKey: i64): i32;

{ ===========================================================================
  Phase 5.4 — Additional btree helpers needed by VDBE opcodes
  =========================================================================== }
{ btree.c:2367 — last page number (= page count) of this B-tree }
function  sqlite3BtreeLastPage(p: PBtree): Pgno;
{ btree.c:3151 — get/set the pager max page count; returns new limit }
function  sqlite3BtreeMaxPageCount(p: PBtree; mxPage: Pgno): Pgno;
{ btree.c:11400 — lock a table (no-op when shared cache disabled) }
function  sqlite3BtreeLockTable(p: PBtree; iTab: i32; isWriteLock: u8): i32;
{ btree.c:4928/4932 — pin/unpin a cursor (set/clear BTCF_Pinned) }
procedure sqlite3BtreeCursorPin(pCur: PBtCursor);
procedure sqlite3BtreeCursorUnpin(pCur: PBtCursor);

{ ===========================================================================
  Phase 8.7 — accessors required by backup.c
  =========================================================================== }

const
  { sqlite3.h SQLITE_TXN_* — public values returned by sqlite3BtreeTxnState }
  SQLITE_TXN_NONE  = 0;
  SQLITE_TXN_READ  = 1;
  SQLITE_TXN_WRITE = 2;

{ btree.c:3236 — return the current page size of the database. }
function  sqlite3BtreeGetPageSize(p: PBtree): i32;
function  sqlite3BtreeSetSpillSize(p: PBtree; mxPage: i32): i32;
procedure sqlite3BtreeSetCacheSize(p: PBtree; mxPage: i32);
{ btree.c:3185 — set page size + reserved-bytes; iFix locks pageSize. }
function  sqlite3BtreeSetPageSize(p: PBtree; iPageSize: i32;
                                  nReserve: i32; iFix: i32): i32;
{ btree.c:3296 — current Btree transaction state (TRANS_NONE/READ/WRITE). }
function  sqlite3BtreeTxnState(p: PBtree): i32;
{ btree.c:3257 — number of bytes of unused space at the end of every page. }
function  sqlite3BtreeGetReserveNoMutex(p: PBtree): i32;
{ btree.c:3136 — return the larger of the current reserve and the most
  recently requested reserve.  Mutex-aware variant. }
function  sqlite3BtreeGetRequestedReserve(p: PBtree): i32;
{ btree.c:11544 — clear the in-memory pager cache when no transaction is
  active and the database is not a temp-db. }
procedure sqlite3BtreeClearCache(p: PBtree);
{ btree.c:7046 — set the database file format version (1 or 2 = WAL). }
function  sqlite3BtreeSetVersion(p: PBtree; iVersion: i32): i32;

{ btree.c:11365 — lazily allocate (or fetch) the per-BtShared schema blob.
  Caller passes nBytes=SizeOf(TSchema) on first init and 0 thereafter.
  xFree is invoked when the BtShared is torn down. }
type TBtreeSchemaFree = procedure(p: Pointer);
function  sqlite3BtreeSchema(p: PBtree; nBytes: i32;
                              xFree: TBtreeSchemaFree): Pointer;

{ btree.c:11339 — true if a sqlite3_backup is active on this Btree. }
function  sqlite3BtreeIsInBackup(p: PBtree): i32;

{ btree.c:11538 — bytes of per-page header overhead reserved by btree. }
function  sqlite3HeaderSizeBtree: i32;

{ btree.c:11555 / :11564 — shared-cache introspection helpers.  In the
  no-shared-cache build the answers are constant: not sharable, refcount=1. }
function  sqlite3BtreeSharable(p: PBtree): i32;
function  sqlite3BtreeConnectionCount(p: PBtree): i32;

{ btree.c:3177 — toggle BTS_SECURE_DELETE on the BtShared.  newFlag<0 leaves
  the flag untouched and merely returns the current setting. }
function  sqlite3BtreeSecureDelete(p: PBtree; newFlag: i32): i32;

{ btree.c:3198 / :3222 — auto-vacuum get/set.  Honoured by PRAGMA auto_vacuum
  on connection open; once BTS_PAGESIZE_FIXED is set Set returns READONLY. }
function  sqlite3BtreeSetAutoVacuum(p: PBtree; autoVacuum: i32): i32;
function  sqlite3BtreeGetAutoVacuum(p: PBtree): i32;

{ btree.c:4161 — perform a single unit of work towards an incremental
  vacuum.  Without auto-vacuum this returns SQLITE_DONE immediately.
  Wired into OP_IncrVacuum (vdbe.c:8174). }
function  sqlite3BtreeIncrVacuum(p: PBtree): i32;

{ btree.c:3017 — propagate the connection's mmap-size ceiling to the pager. }
function  sqlite3BtreeSetMmapLimit(p: PBtree; szMmap: i64): i32;

{ btree.c:3036 — propagate PRAGMA synchronous / cache-spill flags to the
  pager.  Wraps sqlite3PagerSetFlags under the btree mutex. }
function  sqlite3BtreeSetPagerFlags(p: PBtree; pgFlags: u32): i32;

{ btree.c:11382 — read-lock the schema table; used by sqlite3LockAndPrepare
  to surface SQLITE_LOCKED before parsing.  Without shared-cache this always
  succeeds, matching querySharedCacheTableLock's stub. }
function  sqlite3BtreeSchemaLocked(p: PBtree): i32;

{ btree.c:4583 — open an anonymous savepoint to back a statement
  sub-transaction. }
function  sqlite3BtreeBeginStmt(p: PBtree; iStatement: i32): i32;

{ btree.c:11126 — sqlite3BtreeIntegrityCheck.  PRAGMA integrity_check
  body.  aRoot[0] == nRoot when the list is exhaustive (full check);
  aRoot[0] == 0 indicates a "partial" check — only verify the listed
  trees and skip freelist + page-coverage scans (except aRoot[1]==1
  retains the freelist scan).  Writes the per-tree row count into
  aRowCnt[i] (i in 0..nRoot-1).  *pnErr receives the error count;
  *pzOut receives a libc-malloc'd error message (or nil on success).
  Aim is byte-for-byte compatible reporting with the C oracle. }
function  sqlite3BtreeIntegrityCheck(db: Psqlite3; p: PBtree;
                                     aRoot: PPgno; aRowCnt: Pi64;
                                     nRoot, mxErr: i32;
                                     pnErr: Pi32;
                                     pzOut: PPAnsiChar): i32;

implementation

uses
  BaseUnix, UnixType, passqlite3internal, passqlite3printf;

{ ===========================================================================
  Inline pager helpers
  =========================================================================== }

function sqlite3PagerIswriteable(pPg: PDbPage): i32;
begin
  if (pPg^.flags and PGHDR_WRITEABLE) <> 0 then Result := 1 else Result := 0;
end;

function sqlite3PagerPagenumber(pPg: PDbPage): Pgno;
begin
  Result := pPg^.pgno;
end;

function sqlite3PagerTempSpace(pPager: PPager): Pointer;
begin
  Result := pPager^.pTmpSpace;
end;

{ ===========================================================================
  Big-endian 2-byte accessors (btreeInt.h macros get2byte / put2byte)
  =========================================================================== }

function get2byte(p: Pu8): i32;
begin
  Result := (i32(p[0]) shl 8) or i32(p[1]);
end;

procedure put2byte(p: Pu8; v: i32);
begin
  p[0] := u8(v shr 8);
  p[1] := u8(v);
end;

function get2byteAligned(p: Pu8): i32;
begin
  { On little-endian x86 without special compiler support, same as get2byte }
  Result := (i32(p[0]) shl 8) or i32(p[1]);
end;

function get2byteNotZero(p: Pu8): i32;
{ Returns 65536 if the stored value is 0 (special case for 65536-byte pages) }
begin
  Result := (((get2byte(p) - 1) and $FFFF) + 1);
end;

{ btreeInt.h get4byte/put4byte — thin wrappers around util }
function get4byte(p: Pu8): u32;
begin
  Result := sqlite3Get4byte(p);
end;

procedure put4byte(p: Pu8; v: u32);
begin
  sqlite3Put4byte(p, v);
end;

{ ===========================================================================
  Corruption helper
  =========================================================================== }

function CORRUPT_PAGE(pPage: PMemPage): i32;
begin
  Result := SQLITE_CORRUPT;
  { pPage parameter available for future debug logging }
end;

{ ===========================================================================
  MX helpers
  =========================================================================== }

function MX_CELL_SIZE(pBt: PBtShared): i32;
begin
  Result := i32(pBt^.pageSize) - 8;
end;

function MX_CELL(pBt: PBtShared): i32;
begin
  Result := (i32(pBt^.pageSize) - 8) div 6;
end;

{ ===========================================================================
  findCell / findCellPastPtr
  btreeInt.h:
    findCell(P,I) = (P)->aData + ((P)->maskPage & get2byteAligned(&(P)->aCellIdx[2*(I)]))
    findCellPastPtr(P,I) = (P)->aDataOfst + (...)
  =========================================================================== }

function findCell(pPage: PMemPage; i: i32): Pu8;
begin
  Result := pPage^.aData + (pPage^.maskPage and u16(get2byteAligned(pPage^.aCellIdx + 2*i)));
end;

function findCellPastPtr(pPage: PMemPage; i: i32): Pu8;
begin
  Result := pPage^.aDataOfst + (pPage^.maskPage and u16(get2byteAligned(pPage^.aCellIdx + 2*i)));
end;

{ ===========================================================================
  btreeParseCellAdjustSizeForOverflow
  btree.c lines 1178-1207
  =========================================================================== }
procedure btreeParseCellAdjustSizeForOverflow(pPage: PMemPage; pCell: Pu8; pInfo: PCellInfo);
var
  minLocal: i32;
  maxLocal: i32;
  surplus : i32;
begin
  minLocal := pPage^.minLocal;
  maxLocal := pPage^.maxLocal;
  surplus := minLocal + i32(i64(pInfo^.nPayload) - minLocal) mod i32(pPage^.pBt^.usableSize - 4);
  if surplus <= maxLocal then
    pInfo^.nLocal := u16(surplus)
  else
    pInfo^.nLocal := u16(minLocal);
  pInfo^.nSize := u16(pInfo^.pPayload + pInfo^.nLocal - pCell) + 4;
end;

{ ===========================================================================
  btreePayloadToLocal
  btree.c lines 1213-1226
  =========================================================================== }
function btreePayloadToLocal(pPage: PMemPage; nPayload: i64): i32;
var
  maxLocal: i32;
  minLocal: i32;
  surplus : i32;
begin
  maxLocal := pPage^.maxLocal;
  if nPayload <= maxLocal then begin
    Result := i32(nPayload);
    Exit;
  end;
  minLocal := pPage^.minLocal;
  surplus := i32(minLocal + (nPayload - minLocal) mod i64(pPage^.pBt^.usableSize - 4));
  if surplus <= maxLocal then
    Result := surplus
  else
    Result := minLocal;
end;

{ ===========================================================================
  btreeParseCellPtrNoPayload  — table btree interior nodes
  btree.c lines 1242-1258
  =========================================================================== }
procedure btreeParseCellPtrNoPayload(pPage: PMemPage; pCell: Pu8; pInfo: PCellInfo); inline;
var
  nBytes: i32;
  iKey  : u64;
begin
  { pCell[0..3] = left-child page number; varint key starts at offset 4 }
  nBytes := 4 + sqlite3GetVarint(pCell + 4, iKey);
  pInfo^.nKey     := i64(iKey);
  pInfo^.nSize    := u16(nBytes);
  pInfo^.nPayload := 0;
  pInfo^.nLocal   := 0;
  pInfo^.pPayload := nil;
end;

{ ===========================================================================
  btreeParseCellPtr  — table btree leaf nodes
  btree.c lines 1259-1346
  =========================================================================== }
{ NOTE: every hot call site dispatches through pPage^.xParseCell function
  pointer; FPC cannot inline through indirect calls.  The `inline;` directive
  is harmless (FPC emits an out-of-line body for the @-taken procvar at
  setup time) and lets any future direct caller benefit. }
procedure btreeParseCellPtr(pPage: PMemPage; pCell: Pu8; pInfo: PCellInfo); inline;
var
  pIter   : Pu8;
  nPayload: u64;
  iKey    : u64;
  x       : u8;
begin
  pIter := pCell;

  { --- decode nPayload varint (inlined fast path) --- }
  nPayload := pIter[0];
  if nPayload >= $80 then begin
    nPayload := nPayload and $7F;
    repeat
      Inc(pIter);
      nPayload := (nPayload shl 7) or (pIter[0] and $7F);
    until (pIter[0] < $80) or (pIter >= pCell + 8);
    nPayload := nPayload and $FFFFFFFF;
  end;
  Inc(pIter);

  { --- decode integer key varint (inlined 9-byte unrolled loop) --- }
  iKey := pIter[0];
  if iKey >= $80 then begin
    x := pIter[1]; Inc(pIter);
    iKey := (iKey shl 7) xor x;
    if x >= $80 then begin
      x := pIter[1]; Inc(pIter);
      iKey := (iKey shl 7) xor x;
      if x >= $80 then begin
        x := pIter[1]; Inc(pIter);
        iKey := (iKey shl 7) xor $10204000 xor x;
        if x >= $80 then begin
          x := pIter[1]; Inc(pIter);
          iKey := (iKey shl 7) xor $4000 xor x;
          if x >= $80 then begin
            x := pIter[1]; Inc(pIter);
            iKey := (iKey shl 7) xor $4000 xor x;
            if x >= $80 then begin
              x := pIter[1]; Inc(pIter);
              iKey := (iKey shl 7) xor $4000 xor x;
              if x >= $80 then begin
                x := pIter[1]; Inc(pIter);
                iKey := (iKey shl 7) xor $4000 xor x;
                if x >= $80 then begin
                  Inc(pIter);
                  iKey := (iKey shl 8) xor $8000 xor pIter[0];
                end;
              end;
            end;
          end;
        end;
      end else begin
        iKey := iKey xor $204000;
      end;
    end else begin
      iKey := iKey xor $4000;
    end;
  end;
  Inc(pIter);

  pInfo^.nKey     := i64(iKey);
  pInfo^.nPayload := u32(nPayload);
  pInfo^.pPayload := pIter;

  if nPayload <= u64(pPage^.maxLocal) then begin
    pInfo^.nSize := u16(nPayload) + u16(pIter - pCell);
    if pInfo^.nSize < 4 then pInfo^.nSize := 4;
    pInfo^.nLocal := u16(nPayload);
  end else begin
    btreeParseCellAdjustSizeForOverflow(pPage, pCell, pInfo);
  end;
end;

{ ===========================================================================
  btreeParseCellPtrIndex  — index btree nodes (interior and leaf)
  btree.c lines 1347-1385
  =========================================================================== }
procedure btreeParseCellPtrIndex(pPage: PMemPage; pCell: Pu8; pInfo: PCellInfo); inline;
var
  pIter   : Pu8;
  nPayload: u32;
begin
  pIter := pCell + pPage^.childPtrSize;
  nPayload := pIter[0];
  if nPayload >= $80 then begin
    nPayload := nPayload and $7F;
    repeat
      Inc(pIter);
      nPayload := (nPayload shl 7) or (pIter[0] and $7F);
    until (pIter[0] < $80) or (pIter >= pCell + 8);
  end;
  Inc(pIter);

  pInfo^.nKey     := nPayload;
  pInfo^.nPayload := nPayload;
  pInfo^.pPayload := pIter;

  if nPayload <= u32(pPage^.maxLocal) then begin
    pInfo^.nSize := u16(nPayload) + u16(pIter - pCell);
    if pInfo^.nSize < 4 then pInfo^.nSize := 4;
    pInfo^.nLocal := u16(nPayload);
  end else begin
    btreeParseCellAdjustSizeForOverflow(pPage, pCell, pInfo);
  end;
end;

{ ===========================================================================
  btreeParseCell  — dispatch via xParseCell, cell identified by index
  btree.c lines 1386-1392
  =========================================================================== }
procedure btreeParseCell(pPage: PMemPage; iCell: i32; pInfo: PCellInfo);
begin
  pPage^.xParseCell(pPage, findCell(pPage, iCell), pInfo);
end;

{ ===========================================================================
  cellSizePtr  — index interior nodes (childPtrSize = 4)
  btree.c lines 1408-1449
  =========================================================================== }
function cellSizePtr(pPage: PMemPage; pCell: Pu8): u16;
var
  pIter  : Pu8;
  pEnd   : Pu8;
  nSize  : u32;
  minLocal: i32;
begin
  pIter := pCell + 4;
  nSize := pIter[0];
  if nSize >= $80 then begin
    pEnd := pIter + 8;
    nSize := nSize and $7F;
    repeat
      Inc(pIter);
      nSize := (nSize shl 7) or (pIter[0] and $7F);
    until (pIter[0] < $80) or (pIter >= pEnd);
  end;
  Inc(pIter);
  if nSize <= u32(pPage^.maxLocal) then begin
    nSize := nSize + u32(pIter - pCell);
    { assert nSize > 4 }
  end else begin
    minLocal := pPage^.minLocal;
    nSize := u32(minLocal) + (nSize - u32(minLocal)) mod (pPage^.pBt^.usableSize - 4);
    if nSize > u32(pPage^.maxLocal) then
      nSize := u32(minLocal);
    nSize := nSize + 4 + u32(pIter - pCell);
  end;
  Result := u16(nSize);
end;

{ ===========================================================================
  cellSizePtrIdxLeaf  — index leaf nodes (childPtrSize = 0)
  btree.c lines 1450-1491
  =========================================================================== }
function cellSizePtrIdxLeaf(pPage: PMemPage; pCell: Pu8): u16;
var
  pIter   : Pu8;
  pEnd    : Pu8;
  nSize   : u32;
  minLocal: i32;
begin
  pIter := pCell;
  nSize := pIter[0];
  if nSize >= $80 then begin
    pEnd := pIter + 8;
    nSize := nSize and $7F;
    repeat
      Inc(pIter);
      nSize := (nSize shl 7) or (pIter[0] and $7F);
    until (pIter[0] < $80) or (pIter >= pEnd);
  end;
  Inc(pIter);
  if nSize <= u32(pPage^.maxLocal) then begin
    nSize := nSize + u32(pIter - pCell);
    if nSize < 4 then nSize := 4;
  end else begin
    minLocal := pPage^.minLocal;
    nSize := u32(minLocal) + (nSize - u32(minLocal)) mod (pPage^.pBt^.usableSize - 4);
    if nSize > u32(pPage^.maxLocal) then
      nSize := u32(minLocal);
    nSize := nSize + 4 + u32(pIter - pCell);
  end;
  Result := u16(nSize);
end;

{ ===========================================================================
  cellSizePtrNoPayload  — table interior nodes
  btree.c lines 1492-1512
  =========================================================================== }
function cellSizePtrNoPayload(pPage: PMemPage; pCell: Pu8): u16;
var
  pIter: Pu8;
  pEnd : Pu8;
begin
  pIter := pCell + 4;
  pEnd  := pIter + 9;
  while (pIter[0] and $80 <> 0) and (pIter < pEnd) do
    Inc(pIter);
  Inc(pIter);
  Result := u16(pIter - pCell);
end;

{ ===========================================================================
  cellSizePtrTableLeaf  — table leaf nodes
  btree.c lines 1513-1564
  =========================================================================== }
function cellSizePtrTableLeaf(pPage: PMemPage; pCell: Pu8): u16;
var
  pIter   : Pu8;
  pEnd    : Pu8;
  nSize   : u32;
  minLocal: i32;
begin
  pIter := pCell;
  nSize := pIter[0];
  if nSize >= $80 then begin
    pEnd := pIter + 8;
    nSize := nSize and $7F;
    repeat
      Inc(pIter);
      nSize := (nSize shl 7) or (pIter[0] and $7F);
    until (pIter[0] < $80) or (pIter >= pEnd);
  end;
  Inc(pIter);

  { Skip the 64-bit integer key varint (up to 9 bytes) }
  if (pIter[0] and $80 <> 0) and (pIter[1] and $80 <> 0) and
     (pIter[2] and $80 <> 0) and (pIter[3] and $80 <> 0) and
     (pIter[4] and $80 <> 0) and (pIter[5] and $80 <> 0) and
     (pIter[6] and $80 <> 0) and (pIter[7] and $80 <> 0) then
    Inc(pIter, 9)
  else begin
    { Advance past key bytes }
    while (pIter[0] and $80 <> 0) do
      Inc(pIter);
    Inc(pIter);
  end;

  if nSize <= u32(pPage^.maxLocal) then begin
    nSize := nSize + u32(pIter - pCell);
    if nSize < 4 then nSize := 4;
  end else begin
    minLocal := pPage^.minLocal;
    nSize := u32(minLocal) + (nSize - u32(minLocal)) mod (pPage^.pBt^.usableSize - 4);
    if nSize > u32(pPage^.maxLocal) then
      nSize := u32(minLocal);
    nSize := nSize + 4 + u32(pIter - pCell);
  end;
  Result := u16(nSize);
end;

{ ===========================================================================
  pageFindSlot
  btree.c lines 1747-1804
  =========================================================================== }
function pageFindSlot(pPg: PMemPage; nByte: i32; out pRc: i32): Pu8;
var
  hdr   : i32;
  aData : Pu8;
  iAddr : i32;
  pc    : i32;
  x     : i32;
  maxPC : i32;
  sz    : i32;
begin
  Result := nil;
  hdr    := pPg^.hdrOffset;
  aData  := pPg^.aData;
  iAddr  := hdr + 1;
  pc     := get2byte(aData + iAddr);
  maxPC  := i32(pPg^.pBt^.usableSize) - nByte;

  while pc <= maxPC do begin
    sz := get2byte(aData + pc + 2);
    x  := sz - nByte;
    if x >= 0 then begin
      if x < 4 then begin
        if aData[hdr + 7] > 57 then Exit;
        Move((aData + pc)^, (aData + iAddr)^, 2);
        aData[hdr + 7] := aData[hdr + 7] + u8(x);
        Result := aData + pc;
        Exit;
      end else if pc + x > maxPC then begin
        pRc := CORRUPT_PAGE(pPg);
        Exit;
      end else begin
        put2byte(aData + pc + 2, x);
      end;
      Result := aData + pc + x;
      Exit;
    end;
    iAddr := pc;
    pc    := get2byte(aData + pc);
    if pc <= iAddr then begin
      if pc <> 0 then
        pRc := CORRUPT_PAGE(pPg);
      Exit;
    end;
  end;

  if pc > maxPC + nByte - 4 then
    pRc := CORRUPT_PAGE(pPg);
end;

{ ===========================================================================
  allocateSpace
  btree.c lines 1819-1903
  =========================================================================== }
function allocateSpace(pPage: PMemPage; nByte: i32; out pIdx: i32): i32;
var
  hdr   : i32;
  data  : Pu8;
  top   : i32;
  rc    : i32;
  gap   : i32;
  pSpace: Pu8;
  g2    : i32;
begin
  hdr  := pPage^.hdrOffset;
  data := pPage^.aData;
  rc   := SQLITE_OK;

  gap := pPage^.cellOffset + 2 * pPage^.nCell;
  top := get2byte(data + hdr + 5);
  if gap > top then begin
    if (top = 0) and (pPage^.pBt^.usableSize = 65536) then
      top := 65536
    else begin
      Result := CORRUPT_PAGE(pPage); Exit;
    end;
  end else if top > i32(pPage^.pBt^.usableSize) then begin
    Result := CORRUPT_PAGE(pPage); Exit;
  end;

  if ((data[hdr+2] <> 0) or (data[hdr+1] <> 0)) and (gap + 2 <= top) then begin
    pSpace := pageFindSlot(pPage, nByte, rc);
    if pSpace <> nil then begin
      g2 := i32(pSpace - data);
      if g2 <= gap then begin
        Result := CORRUPT_PAGE(pPage); Exit;
      end;
      pIdx   := g2;
      Result := SQLITE_OK;
      Exit;
    end else if rc <> SQLITE_OK then begin
      Result := rc; Exit;
    end;
  end;

  if gap + 2 + nByte > top then begin
    rc := defragmentPage(pPage, 4);
    if rc <> SQLITE_OK then begin Result := rc; Exit; end;
    top := get2byteNotZero(data + hdr + 5);
  end;

  top   := top - nByte;
  put2byte(data + hdr + 5, top);
  pIdx   := top;
  Result := SQLITE_OK;
end;

{ ===========================================================================
  freeSpace
  btree.c lines 1918-2013
  =========================================================================== }
function freeSpace(pPage: PMemPage; iStart: i32; iSize: i32): i32; inline;
var
  iPtr    : i32;
  iFreeBlk: i32;
  hdr     : u8;
  nFrag   : i32;
  iOrigSize: i32;
  x       : i32;
  iEnd    : i32;
  data    : Pu8;
  pTmp    : Pu8;
begin
  nFrag     := 0;
  iOrigSize := iSize;
  iEnd      := iStart + iSize;
  data      := pPage^.aData;
  hdr       := pPage^.hdrOffset;

  iPtr := hdr + 1;
  if (data[iPtr + 1] = 0) and (data[iPtr] = 0) then begin
    iFreeBlk := 0;
  end else begin
    iFreeBlk := get2byte(data + iPtr);
    while (iFreeBlk <> 0) and (iFreeBlk < iStart) do begin
      if iFreeBlk <= iPtr then begin
        Result := CORRUPT_PAGE(pPage); Exit;
      end;
      iPtr     := iFreeBlk;
      iFreeBlk := get2byte(data + iFreeBlk);
    end;
    if iFreeBlk > i32(pPage^.pBt^.usableSize) - 4 then begin
      Result := CORRUPT_PAGE(pPage); Exit;
    end;

    if (iFreeBlk <> 0) and (iEnd + 3 >= iFreeBlk) then begin
      nFrag := iFreeBlk - iEnd;
      if iEnd > iFreeBlk then begin Result := CORRUPT_PAGE(pPage); Exit; end;
      iEnd     := iFreeBlk + get2byte(data + iFreeBlk + 2);
      if iEnd > i32(pPage^.pBt^.usableSize) then begin
        Result := CORRUPT_PAGE(pPage); Exit;
      end;
      iSize    := iEnd - iStart;
      iFreeBlk := get2byte(data + iFreeBlk);
    end;

    if iPtr > i32(hdr) + 1 then begin
      x := iPtr + get2byte(data + iPtr + 2);
      if x + 3 >= iStart then begin
        if x > iStart then begin Result := CORRUPT_PAGE(pPage); Exit; end;
        nFrag    := nFrag + (iStart - x);
        iSize    := iEnd - iPtr;
        iStart   := iPtr;
      end;
    end;

    if nFrag > i32(data[hdr + 7]) then begin
      Result := CORRUPT_PAGE(pPage); Exit;
    end;
    data[hdr + 7] := data[hdr + 7] - u8(nFrag);
  end;

  pTmp := data + hdr + 5;
  x    := get2byte(pTmp);

  if (pPage^.pBt^.btsFlags and BTS_FAST_SECURE) <> 0 then
    FillChar((data + iStart)^, iSize, 0);

  if iStart <= x then begin
    if iStart < x then begin Result := CORRUPT_PAGE(pPage); Exit; end;
    if iPtr <> i32(hdr) + 1 then begin Result := CORRUPT_PAGE(pPage); Exit; end;
    put2byte(data + hdr + 1, iFreeBlk);
    put2byte(data + hdr + 5, iEnd);
  end else begin
    put2byte(data + iPtr, iStart);
    put2byte(data + iStart, iFreeBlk);
    put2byte(data + iStart + 2, u32(iSize));
  end;
  pPage^.nFree := pPage^.nFree + iOrigSize;
  Result := SQLITE_OK;
end;

{ ===========================================================================
  defragmentPage
  btree.c lines 1613-1731
  =========================================================================== }
function defragmentPage(pPage: PMemPage; nMaxFrag: i32): i32;
var
  i          : i32;
  pc         : i32;
  hdr        : i32;
  sz         : i32;
  usableSize : i32;
  cellOffset : i32;
  cbrk       : i32;
  nCell      : i32;
  data       : Pu8;
  temp       : Pu8;
  src        : Pu8;
  iCellFirst : i32;
  iCellLast  : i32;
  iCellStart : i32;
  iFree      : i32;
  iFree2     : i32;
  sz2        : i32;
  top        : i32;
  pAddr      : Pu8;
  pEnd       : Pu8;
begin
  data       := pPage^.aData;
  hdr        := pPage^.hdrOffset;
  cellOffset := pPage^.cellOffset;
  nCell      := pPage^.nCell;
  iCellFirst := cellOffset + 2 * nCell;
  usableSize := i32(pPage^.pBt^.usableSize);

  { Fast path: 0 or 1 free blocks and few fragments }
  if i32(data[hdr + 7]) <= nMaxFrag then begin
    iFree := get2byte(data + hdr + 1);
    if iFree > usableSize - 4 then begin Result := CORRUPT_PAGE(pPage); Exit; end;
    if iFree <> 0 then begin
      iFree2 := get2byte(data + iFree);
      if iFree2 > usableSize - 4 then begin Result := CORRUPT_PAGE(pPage); Exit; end;
      if (iFree2 = 0) or ((data[iFree2] = 0) and (data[iFree2 + 1] = 0)) then begin
        pEnd := data + cellOffset + nCell * 2;
        sz2  := 0;
        sz   := get2byte(data + iFree + 2);
        top  := get2byte(data + hdr + 5);
        if top >= iFree then begin Result := CORRUPT_PAGE(pPage); Exit; end;
        if iFree2 <> 0 then begin
          if iFree + sz > iFree2 then begin Result := CORRUPT_PAGE(pPage); Exit; end;
          sz2 := get2byte(data + iFree2 + 2);
          if iFree2 + sz2 > usableSize then begin Result := CORRUPT_PAGE(pPage); Exit; end;
          Move((data + iFree + sz)^, (data + iFree + sz + sz2)^, iFree2 - (iFree + sz));
          sz := sz + sz2;
        end else if iFree + sz > usableSize then begin
          Result := CORRUPT_PAGE(pPage); Exit;
        end;

        cbrk := top + sz;
        Move((data + top)^, (data + cbrk)^, iFree - top);
        pAddr := data + cellOffset;
        while pAddr < pEnd do begin
          pc := get2byte(pAddr);
          if pc < iFree then put2byte(pAddr, pc + sz)
          else if pc < iFree2 then put2byte(pAddr, pc + sz2);
          Inc(pAddr, 2);
        end;
        { goto defragment_out }
        if i32(data[hdr+7]) + cbrk - iCellFirst <> pPage^.nFree then begin
          Result := CORRUPT_PAGE(pPage); Exit;
        end;
        put2byte(data + hdr + 5, cbrk);
        data[hdr + 1] := 0;
        data[hdr + 2] := 0;
        FillChar((data + iCellFirst)^, cbrk - iCellFirst, 0);
        Result := SQLITE_OK;
        Exit;
      end;
    end;
  end;

  cbrk       := usableSize;
  iCellLast  := usableSize - 4;
  iCellStart := get2byte(data + hdr + 5);

  if nCell > 0 then begin
    temp := sqlite3PagerTempSpace(pPage^.pBt^.pPager);
    Move(data^, temp^, usableSize);
    src := temp;
    for i := 0 to nCell - 1 do begin
      pAddr := data + cellOffset + i * 2;
      pc    := get2byte(pAddr);
      if pc > iCellLast then begin Result := CORRUPT_PAGE(pPage); Exit; end;
      sz    := i32(pPage^.xCellSize(pPage, src + pc));
      cbrk  := cbrk - sz;
      if (cbrk < iCellStart) or (pc + sz > usableSize) then begin
        Result := CORRUPT_PAGE(pPage); Exit;
      end;
      put2byte(pAddr, cbrk);
      Move((src + pc)^, (data + cbrk)^, sz);
    end;
  end;
  data[hdr + 7] := 0;

  { defragment_out: }
  if i32(data[hdr + 7]) + cbrk - iCellFirst <> pPage^.nFree then begin
    Result := CORRUPT_PAGE(pPage); Exit;
  end;
  put2byte(data + hdr + 5, cbrk);
  data[hdr + 1] := 0;
  data[hdr + 2] := 0;
  FillChar((data + iCellFirst)^, cbrk - iCellFirst, 0);
  Result := SQLITE_OK;
end;

{ ===========================================================================
  decodeFlags
  btree.c lines 2028-2085
  =========================================================================== }
function decodeFlags(pPage: PMemPage; flagByte: i32): i32;
var
  pBt: PBtShared;
begin
  pBt := pPage^.pBt;
  pPage^.max1bytePayload := pBt^.max1bytePayload;

  if flagByte >= (PTF_ZERODATA or PTF_LEAF) then begin
    pPage^.childPtrSize := 0;
    pPage^.leaf         := 1;
    if flagByte = (PTF_LEAFDATA or PTF_INTKEY or PTF_LEAF) then begin
      pPage^.intKeyLeaf  := 1;
      pPage^.xCellSize   := @cellSizePtrTableLeaf;
      pPage^.xParseCell  := @btreeParseCellPtr;
      pPage^.intKey      := 1;
      pPage^.maxLocal    := pBt^.maxLeaf;
      pPage^.minLocal    := pBt^.minLeaf;
    end else if flagByte = (PTF_ZERODATA or PTF_LEAF) then begin
      pPage^.intKey      := 0;
      pPage^.intKeyLeaf  := 0;
      pPage^.xCellSize   := @cellSizePtrIdxLeaf;
      pPage^.xParseCell  := @btreeParseCellPtrIndex;
      pPage^.maxLocal    := pBt^.maxLocal;
      pPage^.minLocal    := pBt^.minLocal;
    end else begin
      pPage^.intKey      := 0;
      pPage^.intKeyLeaf  := 0;
      pPage^.xCellSize   := @cellSizePtrIdxLeaf;
      pPage^.xParseCell  := @btreeParseCellPtrIndex;
      Result := CORRUPT_PAGE(pPage); Exit;
    end;
  end else begin
    pPage^.childPtrSize := 4;
    pPage^.leaf         := 0;
    if flagByte = PTF_ZERODATA then begin
      pPage^.intKey      := 0;
      pPage^.intKeyLeaf  := 0;
      pPage^.xCellSize   := @cellSizePtr;
      pPage^.xParseCell  := @btreeParseCellPtrIndex;
      pPage^.maxLocal    := pBt^.maxLocal;
      pPage^.minLocal    := pBt^.minLocal;
    end else if flagByte = (PTF_LEAFDATA or PTF_INTKEY) then begin
      pPage^.intKeyLeaf  := 0;
      pPage^.xCellSize   := @cellSizePtrNoPayload;
      pPage^.xParseCell  := @btreeParseCellPtrNoPayload;
      pPage^.intKey      := 1;
      pPage^.maxLocal    := pBt^.maxLeaf;
      pPage^.minLocal    := pBt^.minLeaf;
    end else begin
      pPage^.intKey      := 0;
      pPage^.intKeyLeaf  := 0;
      pPage^.xCellSize   := @cellSizePtr;
      pPage^.xParseCell  := @btreeParseCellPtrIndex;
      Result := CORRUPT_PAGE(pPage); Exit;
    end;
  end;
  Result := SQLITE_OK;
end;

{ ===========================================================================
  btreeComputeFreeSpace
  btree.c lines 2091-2167
  =========================================================================== }
function btreeComputeFreeSpace(pPage: PMemPage): i32;
var
  pc          : i32;
  hdr         : u8;
  data        : Pu8;
  usableSize  : i32;
  nFree       : i32;
  top         : i32;
  iCellFirst  : i32;
  iCellLast   : i32;
  next        : u32;
  sz          : u32;
begin
  usableSize := i32(pPage^.pBt^.usableSize);
  hdr        := pPage^.hdrOffset;
  data       := pPage^.aData;
  top        := get2byteNotZero(data + hdr + 5);
  iCellFirst := hdr + 8 + pPage^.childPtrSize + 2 * pPage^.nCell;
  iCellLast  := usableSize - 4;

  pc    := get2byte(data + hdr + 1);
  nFree := i32(data[hdr + 7]) + top;

  if pc > 0 then begin
    if pc < top then begin Result := CORRUPT_PAGE(pPage); Exit; end;
    while True do begin
      if pc > iCellLast then begin Result := CORRUPT_PAGE(pPage); Exit; end;
      next  := get2byte(data + pc);
      sz    := get2byte(data + pc + 2);
      nFree := nFree + i32(sz);
      if (next <= pc + i32(sz) + 3) then Break;
      pc    := i32(next);
    end;
    if next > 0 then begin Result := CORRUPT_PAGE(pPage); Exit; end;
    if pc + i32(sz) > u32(usableSize) then begin Result := CORRUPT_PAGE(pPage); Exit; end;
  end;

  if (nFree > usableSize) or (nFree < iCellFirst) then begin
    Result := CORRUPT_PAGE(pPage); Exit;
  end;
  pPage^.nFree := u16(nFree - iCellFirst);
  Result := SQLITE_OK;
end;

{ ===========================================================================
  btreeCellSizeCheck  — extra corruption check when cell_size_check=ON
  btree.c lines 2173-2203
  =========================================================================== }
function btreeCellSizeCheck(pPage: PMemPage): i32;
var
  iCellFirst: i32;
  iCellLast : i32;
  i         : i32;
  sz        : i32;
  pc        : i32;
  data      : Pu8;
  usableSize: i32;
  cellOffset: i32;
begin
  iCellFirst := pPage^.cellOffset + 2 * pPage^.nCell;
  usableSize := i32(pPage^.pBt^.usableSize);
  iCellLast  := usableSize - 4;
  data       := pPage^.aData;
  cellOffset := pPage^.cellOffset;
  if pPage^.leaf = 0 then Dec(iCellLast);

  for i := 0 to pPage^.nCell - 1 do begin
    pc := get2byteAligned(data + cellOffset + i * 2);
    if (pc < iCellFirst) or (pc > iCellLast) then begin
      Result := CORRUPT_PAGE(pPage); Exit;
    end;
    sz := i32(pPage^.xCellSize(pPage, data + pc));
    if pc + sz > usableSize then begin
      Result := CORRUPT_PAGE(pPage); Exit;
    end;
  end;
  Result := SQLITE_OK;
end;

{ ===========================================================================
  btreeInitPage
  btree.c lines 2214-2261
  =========================================================================== }
function btreeInitPage(pPage: PMemPage): i32;
var
  data: Pu8;
  pBt : PBtShared;
begin
  pBt  := pPage^.pBt;
  data := pPage^.aData + pPage^.hdrOffset;

  if decodeFlags(pPage, i32(data[0])) <> SQLITE_OK then begin
    Result := CORRUPT_PAGE(pPage); Exit;
  end;

  pPage^.maskPage   := u16(pBt^.pageSize - 1);
  pPage^.nOverflow  := 0;
  pPage^.cellOffset := u16(pPage^.hdrOffset + 8 + pPage^.childPtrSize);
  pPage^.aCellIdx   := data + pPage^.childPtrSize + 8;
  pPage^.aDataEnd   := pPage^.aData + pBt^.pageSize;
  pPage^.aDataOfst  := pPage^.aData + pPage^.childPtrSize;
  pPage^.nCell      := u16(get2byte(data + 3));

  if pPage^.nCell > u16(MX_CELL(pBt)) then begin
    Result := CORRUPT_PAGE(pPage); Exit;
  end;

  pPage^.nFree := -1;
  pPage^.isInit := 1;

  { PRAGMA cell_size_check path — only when db.flags has SQLITE_CellSizeCk set.
    Since pBt^.db is opaque (Pointer) at this phase, we skip the check. It is
    a debug-only feature and can be enabled when the sqlite3 struct is ported. }

  Result := SQLITE_OK;
end;

{ ===========================================================================
  zeroPage
  btree.c lines 2267-2297
  =========================================================================== }
procedure zeroPage(pPage: PMemPage; flags: i32);
var
  data : Pu8;
  pBt  : PBtShared;
  hdr  : i32;
  first: i32;
begin
  data := pPage^.aData;
  pBt  := pPage^.pBt;
  hdr  := pPage^.hdrOffset;

  if (pBt^.btsFlags and BTS_FAST_SECURE) <> 0 then
    FillChar((data + hdr)^, i32(pBt^.usableSize) - hdr, 0);

  data[hdr] := u8(flags);
  if (flags and PTF_LEAF) = 0 then
    first := hdr + 12
  else
    first := hdr + 8;

  FillChar((data + hdr + 1)^, 4, 0);
  data[hdr + 7] := 0;
  put2byte(data + hdr + 5, i32(pBt^.usableSize));

  pPage^.nFree       := u16(i32(pBt^.usableSize) - first);
  decodeFlags(pPage, flags);
  pPage^.cellOffset  := u16(first);
  pPage^.aDataEnd    := data + pBt^.pageSize;
  pPage^.aCellIdx    := data + first;
  pPage^.aDataOfst   := data + pPage^.childPtrSize;
  pPage^.nOverflow   := 0;
  pPage^.maskPage    := u16(pBt^.pageSize - 1);
  pPage^.nCell       := 0;
  pPage^.isInit      := 1;
end;

{ ===========================================================================
  btreePageFromDbPage
  btree.c lines 2304-2315
  =========================================================================== }
function btreePageFromDbPage(pDbPage: PDbPage; pgno: Pgno; pBt: PBtShared): PMemPage;
var
  pPage: PMemPage;
begin
  pPage := PMemPage(sqlite3PagerGetExtra(pDbPage));
  if pgno <> pPage^.pgno then begin
    pPage^.aData     := Pu8(sqlite3PagerGetData(pDbPage));
    pPage^.pDbPage   := pDbPage;
    pPage^.pBt       := pBt;
    pPage^.pgno      := pgno;
    if pgno = 1 then
      pPage^.hdrOffset := 100
    else
      pPage^.hdrOffset := 0;
  end;
  Result := pPage;
end;

{ ===========================================================================
  btreeGetPage
  btree.c lines 2328-2343
  =========================================================================== }
function btreeGetPage(pBt: PBtShared; pgno: Pgno; out ppPage: PMemPage; flags: i32): i32;
var
  rc    : i32;
  pDbPg : PDbPage;
begin
  rc    := sqlite3PagerGet(pBt^.pPager, pgno, @pDbPg, flags);
  if rc <> SQLITE_OK then begin ppPage := nil; Result := rc; Exit; end;
  ppPage := btreePageFromDbPage(pDbPg, pgno, pBt);
  Result := SQLITE_OK;
end;

{ ===========================================================================
  btreePageLookup
  btree.c lines 2350-2358
  =========================================================================== }
function btreePageLookup(pBt: PBtShared; pgno: Pgno): PMemPage;
var
  pDbPg: PDbPage;
begin
  pDbPg := sqlite3PagerLookup(pBt^.pPager, pgno);
  if pDbPg <> nil then
    Result := btreePageFromDbPage(pDbPg, pgno, pBt)
  else
    Result := nil;
end;

{ ===========================================================================
  btreePagecount
  btree.c lines 2364-2366
  =========================================================================== }
function btreePagecount(pBt: PBtShared): Pgno;
begin
  Result := pBt^.nPage;
end;

{ ptrmapPutOvflPtr — forward decl; implemented after ptrmapPut /
  SQLITE_OVERFLOW_CHK below (btree.c lines 1582-1597). }
procedure ptrmapPutOvflPtr(pPage: PMemPage; pSrc: PMemPage; pCell: Pu8;
                           pRC: Pi32); forward;

{ ===========================================================================
  dropCell
  btree.c lines 7252-7294
  =========================================================================== }
procedure dropCell(pPage: PMemPage; idx: i32; sz: i32; pRC: Pi32);
var
  pc  : u32;
  data: Pu8;
  ptr : Pu8;
  rc  : i32;
  hdr : i32;
begin
  if pRC^ <> SQLITE_OK then Exit;
  data := pPage^.aData;
  ptr  := pPage^.aCellIdx + 2 * idx;
  pc   := u32(get2byte(ptr));
  hdr  := pPage^.hdrOffset;

  if pc + u32(sz) > pPage^.pBt^.usableSize then begin
    pRC^ := SQLITE_CORRUPT_BKPT; Exit;
  end;

  rc := freeSpace(pPage, i32(pc), sz);
  if rc <> SQLITE_OK then begin pRC^ := rc; Exit; end;

  Dec(pPage^.nCell);
  if pPage^.nCell = 0 then begin
    FillChar((data + hdr + 1)^, 4, 0);
    data[hdr + 7] := 0;
    put2byte(data + hdr + 5, i32(pPage^.pBt^.usableSize));
    pPage^.nFree := i32(pPage^.pBt^.usableSize) - pPage^.hdrOffset
                    - pPage^.childPtrSize - 8;
  end else begin
    Move((ptr + 2)^, ptr^, 2 * (pPage^.nCell - idx));
    put2byte(data + hdr + 3, pPage^.nCell);
    pPage^.nFree := pPage^.nFree + 2;
  end;
end;

{ ===========================================================================
  insertCell
  btree.c lines 7316-7401
  =========================================================================== }
function insertCell(pPage: PMemPage; i: i32; pCell: Pu8; sz: i32;
                    pTemp: Pu8; iChild: Pgno): i32;
var
  idx : i32;
  j   : i32;
  data: Pu8;
  pIns: Pu8;
  rc  : i32;
  rc2 : i32;
begin
  idx  := 0;
  rc   := SQLITE_OK;

  if (pPage^.nOverflow <> 0) or (sz + 2 > pPage^.nFree) then begin
    if pTemp <> nil then begin
      Move(pCell^, pTemp^, sz);
      pCell := pTemp;
    end;
    sqlite3Put4byte(pCell, iChild);
    j := pPage^.nOverflow;
    Inc(pPage^.nOverflow);
    pPage^.apOvfl[j] := pCell;
    pPage^.aiOvfl[j] := u16(i);
  end else begin
    rc := sqlite3PagerWrite(pPage^.pDbPage);
    if rc <> SQLITE_OK then begin Result := rc; Exit; end;

    data := pPage^.aData;
    rc   := allocateSpace(pPage, sz, idx);
    if rc <> SQLITE_OK then begin Result := rc; Exit; end;

    pPage^.nFree := u16(pPage^.nFree - (2 + sz));
    Move((pCell + 4)^, (data + idx + 4)^, sz - 4);
    sqlite3Put4byte(data + idx, iChild);
    pIns := pPage^.aCellIdx + i * 2;
    Move(pIns^, (pIns + 2)^, 2 * (pPage^.nCell - i));
    put2byte(pIns, idx);
    Inc(pPage^.nCell);
    Inc(data[pPage^.hdrOffset + 4]);
    if data[pPage^.hdrOffset + 4] = 0 then
      Inc(data[pPage^.hdrOffset + 3]);

    if pPage^.pBt^.autoVacuum <> 0 then begin
      rc2 := SQLITE_OK;
      ptrmapPutOvflPtr(pPage, pPage, pCell, @rc2);
      if rc2 <> SQLITE_OK then begin Result := rc2; Exit; end;
    end;
  end;
  Result := SQLITE_OK;
end;

{ ===========================================================================
  insertCellFast  — optimised insertCell(pTemp=nil, iChild=0)
  btree.c lines 7413-7485
  =========================================================================== }
function insertCellFast(pPage: PMemPage; i: i32; pCell: Pu8; sz: i32): i32;
var
  idx : i32;
  j   : i32;
  data: Pu8;
  pIns: Pu8;
  rc  : i32;
  rc2 : i32;
begin
  idx := 0;
  rc  := SQLITE_OK;

  if sz + 2 > pPage^.nFree then begin
    j := pPage^.nOverflow;
    Inc(pPage^.nOverflow);
    pPage^.apOvfl[j] := pCell;
    pPage^.aiOvfl[j] := u16(i);
  end else begin
    rc := sqlite3PagerWrite(pPage^.pDbPage);
    if rc <> SQLITE_OK then begin Result := rc; Exit; end;

    data := pPage^.aData;
    rc   := allocateSpace(pPage, sz, idx);
    if rc <> SQLITE_OK then begin Result := rc; Exit; end;

    pPage^.nFree := u16(pPage^.nFree - (2 + sz));
    Move(pCell^, (data + idx)^, sz);
    pIns := pPage^.aCellIdx + i * 2;
    Move(pIns^, (pIns + 2)^, 2 * (pPage^.nCell - i));
    put2byte(pIns, idx);
    Inc(pPage^.nCell);
    Inc(data[pPage^.hdrOffset + 4]);
    if data[pPage^.hdrOffset + 4] = 0 then
      Inc(data[pPage^.hdrOffset + 3]);

    if pPage^.pBt^.autoVacuum <> 0 then begin
      rc2 := SQLITE_OK;
      ptrmapPutOvflPtr(pPage, pPage, pCell, @rc2);
      if rc2 <> SQLITE_OK then begin Result := rc2; Exit; end;
    end;
  end;
  Result := SQLITE_OK;
end;

{ ===========================================================================
  Phase 4.2 implementations
  =========================================================================== }

{ ---------------------------------------------------------------------------
  releasePageNotNull / releasePage / releasePageOne
  btree.c lines 2417-2438
  --------------------------------------------------------------------------- }
procedure releasePageNotNull(pPage: PMemPage);
begin
  sqlite3PagerUnrefNotNull(pPage^.pDbPage);
end;

procedure releasePage(pPage: PMemPage);
begin
  if pPage <> nil then releasePageNotNull(pPage);
end;

procedure releasePageOne(pPage: PMemPage);
begin
  sqlite3PagerUnrefPageOne(pPage^.pDbPage);
end;

{ ---------------------------------------------------------------------------
  unlockBtreeIfUnused
  btree.c lines 3489-3499
  --------------------------------------------------------------------------- }
procedure unlockBtreeIfUnused(pBt: PBtShared);
var
  pPage1: PMemPage;
begin
  if (pBt^.inTransaction = TRANS_NONE) and (pBt^.pPage1 <> nil) then begin
    pPage1 := pBt^.pPage1;
    pBt^.pPage1 := nil;
    releasePageOne(pPage1);
  end;
end;

{ ---------------------------------------------------------------------------
  getAndInitPage
  btree.c lines 2375-2413
  --------------------------------------------------------------------------- }
function getAndInitPage(pBt: PBtShared; pgno: Pgno; out ppPage: PMemPage;
                        bReadOnly: i32): i32;
var
  rc    : i32;
  pDbPg : PDbPage;
  pPage : PMemPage;
begin
  ppPage := nil;
  if pgno > btreePagecount(pBt) then begin
    Result := SQLITE_CORRUPT_BKPT;
    Exit;
  end;
  rc := sqlite3PagerGet(pBt^.pPager, pgno, @pDbPg, bReadOnly);
  if rc <> SQLITE_OK then begin
    Result := rc;
    Exit;
  end;
  pPage := PMemPage(sqlite3PagerGetExtra(pDbPg));
  if pPage^.isInit = 0 then begin
    btreePageFromDbPage(pDbPg, pgno, pBt);
    rc := btreeInitPage(pPage);
    if rc <> SQLITE_OK then begin
      releasePage(pPage);
      Result := rc;
      Exit;
    end;
  end;
  ppPage := pPage;
  Result := SQLITE_OK;
end;

{ ---------------------------------------------------------------------------
  allocateTempSpace / freeTempSpace
  btree.c lines 2869-2912
  --------------------------------------------------------------------------- }
function allocateTempSpace(pBt: PBtShared): i32;
var
  p   : Pu8;
  pCur: PBtCursor;
begin
  p := sqlite3PageMalloc(pBt^.pageSize);
  if p = nil then begin
    pCur := pBt^.pCursor;
    pBt^.pCursor := pCur^.pNext;
    FillChar(pCur^, SizeOf(TBtCursor), 0);
    Result := SQLITE_NOMEM_BKPT;
    Exit;
  end;
  FillChar(p^, 8, 0);
  p := p + 4;
  pBt^.pTmpSpace := p;
  Result := SQLITE_OK;
end;

procedure freeTempSpace(pBt: PBtShared);
var
  p: Pu8;
begin
  if pBt^.pTmpSpace <> nil then begin
    p := pBt^.pTmpSpace - 4;
    sqlite3PageFree(p);
    pBt^.pTmpSpace := nil;
  end;
end;

{ ---------------------------------------------------------------------------
  invalidateOverflowCache / invalidateAllOverflowCache
  btree.c lines 557-577
  --------------------------------------------------------------------------- }
procedure invalidateOverflowCache(pCur: PBtCursor);
begin
  sqlite3_free(Pointer(pCur^.aOverflow));
  pCur^.aOverflow := nil;
  pCur^.curFlags := pCur^.curFlags and (not BTCF_ValidOvfl);
end;

procedure invalidateAllOverflowCache(pBt: PBtShared);
var
  p: PBtCursor;
begin
  p := pBt^.pCursor;
  while p <> nil do begin
    invalidateOverflowCache(p);
    p := p^.pNext;
  end;
end;

{ ---------------------------------------------------------------------------
  btreeReleaseAllCursorPages
  btree.c lines 690-700
  --------------------------------------------------------------------------- }
procedure btreeReleaseAllCursorPages(pCur: PBtCursor);
var
  i: i32;
begin
  if pCur^.iPage >= 0 then begin
    for i := 0 to pCur^.iPage - 1 do
      releasePageNotNull(pCur^.apPage[i]);
    releasePageNotNull(pCur^.pPage);
    pCur^.iPage := -1;
  end;
end;

{ ---------------------------------------------------------------------------
  sqlite3BtreeClearCursor
  btree.c lines 848-854
  --------------------------------------------------------------------------- }
procedure sqlite3BtreeClearCursor(pCur: PBtCursor);
begin
  sqlite3_free(pCur^.pKey);
  pCur^.pKey := nil;
  pCur^.eState := CURSOR_INVALID;
end;

{ ---------------------------------------------------------------------------
  sqlite3BtreeCursorZero
  btree.c lines 4818-4821
  BTCURSOR_FIRST_UNINIT = pBt (offset of first un-zeroed field)
  --------------------------------------------------------------------------- }
procedure sqlite3BtreeCursorZero(p: PBtCursor);
begin
  { Zero from start of struct up to (not including) pBt — the first
    uninitialized field per btreeInt.h BTCURSOR_FIRST_UNINIT = pBt }
  FillChar(p^, PtrUInt(@p^.pBt) - PtrUInt(p), 0);
end;

function sqlite3BtreeCursorSize: i32;
begin
  Result := SizeOf(TBtCursor);
end;

{ ---------------------------------------------------------------------------
  btreeCursor  (internal)
  btree.c lines 4685-4750
  --------------------------------------------------------------------------- }
function btreeCursor(p: PBtree; iTable: Pgno; wrFlag: i32;
                     pKeyInfo: PKeyInfo; pCur: PBtCursor): i32;
var
  pBt: PBtShared;
  pX : PBtCursor;
begin
  pBt := p^.pBt;

  if iTable <= 1 then begin
    if iTable < 1 then begin
      Result := SQLITE_CORRUPT_BKPT;
      Exit;
    end else if btreePagecount(pBt) = 0 then begin
      iTable := 0;
    end;
  end;

  pCur^.pgnoRoot      := iTable;
  pCur^.iPage         := -1;
  pCur^.pKeyInfo      := pKeyInfo;
  pCur^.pBtree        := p;
  pCur^.pBt           := pBt;
  pCur^.curFlags      := 0;

  { If there are two or more cursors on the same btree set BTCF_Multiple }
  pX := pBt^.pCursor;
  while pX <> nil do begin
    if pX^.pgnoRoot = iTable then begin
      pX^.curFlags := pX^.curFlags or BTCF_Multiple;
      pCur^.curFlags := BTCF_Multiple;
    end;
    pX := pX^.pNext;
  end;

  pCur^.eState := CURSOR_INVALID;
  pCur^.pNext  := pBt^.pCursor;
  pBt^.pCursor := pCur;

  if wrFlag <> 0 then begin
    pCur^.curFlags      := pCur^.curFlags or BTCF_WriteFlag;
    pCur^.curPagerFlags := 0;
    if pBt^.pTmpSpace = nil then begin
      Result := allocateTempSpace(pBt);
      Exit;
    end;
  end else begin
    pCur^.curPagerFlags := PAGER_GET_READONLY;
  end;
  Result := SQLITE_OK;
end;

{ ---------------------------------------------------------------------------
  sqlite3BtreeCursor  (public)
  btree.c lines 4765-4785
  --------------------------------------------------------------------------- }
function sqlite3BtreeCursor(p: PBtree; iTable: Pgno; wrFlag: i32;
                            pKeyInfo: PKeyInfo; pCur: PBtCursor): i32;
begin
  { Shared-cache locking omitted (Phase 8 concern); call btreeCursor directly }
  Result := btreeCursor(p, iTable, wrFlag, pKeyInfo, pCur);
end;

{ ---------------------------------------------------------------------------
  sqlite3BtreeCloseCursor
  btree.c lines 4840-4863
  --------------------------------------------------------------------------- }
function sqlite3BtreeCloseCursor(pCur: PBtCursor): i32;
var
  pBtr  : PBtree;
  pBt   : PBtShared;
  pPrev : PBtCursor;
begin
  pBtr := pCur^.pBtree;
  if pBtr <> nil then begin
    pBt := pCur^.pBt;
    if pBt^.pCursor = pCur then begin
      pBt^.pCursor := pCur^.pNext;
    end else begin
      pPrev := pBt^.pCursor;
      while pPrev <> nil do begin
        if pPrev^.pNext = pCur then begin
          pPrev^.pNext := pCur^.pNext;
          break;
        end;
        pPrev := pPrev^.pNext;
      end;
    end;
    btreeReleaseAllCursorPages(pCur);
    unlockBtreeIfUnused(pBt);
    sqlite3_free(Pointer(pCur^.aOverflow));
    sqlite3_free(pCur^.pKey);
    pCur^.pBtree := nil;
  end;
  Result := SQLITE_OK;
end;

procedure sqlite3BtreeCursorHintFlags(pCur: PBtCursor; x: u32);
begin
  pCur^.hints := u8(x);
end;

function sqlite3BtreeCursorHasHint(pCur: PBtCursor; mask: u32): i32;
begin
  Result := ord((pCur^.hints and u8(mask)) <> 0);
end;

{ ---------------------------------------------------------------------------
  saveCursorKey
  btree.c lines 714-753
  --------------------------------------------------------------------------- }
function saveCursorKey(pCur: PBtCursor): i32;
var
  pKey: Pointer;
  rc  : i32;
begin
  rc := SQLITE_OK;
  if pCur^.curIntKey <> 0 then begin
    getCellInfo(pCur);
    pCur^.nKey := pCur^.info.nKey;
  end else begin
    pCur^.nKey := sqlite3BtreePayloadSize(pCur);
    pKey := sqlite3Malloc(pCur^.nKey + 9 + 8);
    if pKey <> nil then begin
      rc := sqlite3BtreePayload(pCur, 0, u32(pCur^.nKey), pKey);
      if rc = SQLITE_OK then begin
        FillChar((Pu8(pKey) + pCur^.nKey)^, 9 + 8, 0);
        pCur^.pKey := pKey;
      end else begin
        sqlite3_free(pKey);
      end;
    end else begin
      rc := SQLITE_NOMEM_BKPT;
    end;
  end;
  Result := rc;
end;

{ ---------------------------------------------------------------------------
  saveCursorPosition
  btree.c lines 757-780
  --------------------------------------------------------------------------- }
function saveCursorPosition(pCur: PBtCursor): i32;
var
  rc: i32;
begin
  if (pCur^.curFlags and BTCF_Pinned) <> 0 then begin
    Result := SQLITE_CONSTRAINT_PINNED;
    Exit;
  end;
  if pCur^.eState = CURSOR_SKIPNEXT then
    pCur^.eState := CURSOR_VALID
  else
    pCur^.skipNext := 0;

  rc := saveCursorKey(pCur);
  if rc = SQLITE_OK then begin
    btreeReleaseAllCursorPages(pCur);
    pCur^.eState := CURSOR_REQUIRESEEK;
  end;
  pCur^.curFlags := pCur^.curFlags and
    (not (BTCF_ValidNKey or BTCF_ValidOvfl or BTCF_AtLast));
  Result := rc;
end;

{ ---------------------------------------------------------------------------
  btreeRestoreCursorPosition  (forward-declared as btreeMoveto needs it)
  btree.c lines 893-926
  --------------------------------------------------------------------------- }

{ btreeMoveto forward declaration — needed by btreeRestoreCursorPosition }
function btreeMoveto(pCur: PBtCursor; pKey: Pointer; nKey: i64;
                     bias: i32; pRes: Pi32): i32; forward;

function btreeRestoreCursorPosition(pCur: PBtCursor): i32;
var
  rc      : i32;
  skipNext: i32;
begin
  if pCur^.eState = CURSOR_FAULT then begin
    Result := pCur^.skipNext;
    Exit;
  end;
  pCur^.eState := CURSOR_INVALID;
  skipNext := 0;
  rc := btreeMoveto(pCur, pCur^.pKey, pCur^.nKey, 0, @skipNext);
  if rc = SQLITE_OK then begin
    sqlite3_free(pCur^.pKey);
    pCur^.pKey := nil;
    if skipNext <> 0 then
      pCur^.skipNext := skipNext;
    if (pCur^.skipNext <> 0) and (pCur^.eState = CURSOR_VALID) then
      pCur^.eState := CURSOR_SKIPNEXT;
  end;
  Result := rc;
end;

function restoreCursorPosition(pCur: PBtCursor): i32;
begin
  if pCur^.eState >= CURSOR_REQUIRESEEK then
    Result := btreeRestoreCursorPosition(pCur)
  else
    Result := SQLITE_OK;
end;

{ ---------------------------------------------------------------------------
  getCellInfo
  btree.c lines 4867-4879
  --------------------------------------------------------------------------- }
procedure getCellInfo(pCur: PBtCursor);
begin
  if pCur^.info.nSize = 0 then begin
    pCur^.curFlags := pCur^.curFlags or BTCF_ValidNKey;
    btreeParseCell(pCur^.pPage, pCur^.ix, @pCur^.info);
  end;
end;

{ ---------------------------------------------------------------------------
  sqlite3BtreeCursorIsValidNN / sqlite3BtreeCursorHasMoved / etc.
  btree.c lines 4902-4932
  --------------------------------------------------------------------------- }
function sqlite3BtreeCursorIsValidNN(pCur: PBtCursor): i32;
begin
  if pCur^.eState = CURSOR_VALID then Result := 1 else Result := 0;
end;

function sqlite3BtreeCursorHasMoved(pCur: PBtCursor): i32;
begin
  if pCur^.eState <> CURSOR_VALID then Result := 1 else Result := 0;
end;

function sqlite3BtreeCursorRestore(pCur: PBtCursor; pDifferentRow: Pi32): i32;
var
  rc: i32;
begin
  rc := restoreCursorPosition(pCur);
  if rc <> SQLITE_OK then begin
    pDifferentRow^ := 1;
    Result := rc;
    Exit;
  end;
  if pCur^.eState <> CURSOR_VALID then
    pDifferentRow^ := 1
  else
    pDifferentRow^ := 0;
  Result := SQLITE_OK;
end;

function sqlite3BtreeEof(pCur: PBtCursor): i32;
begin
  if pCur^.eState <> CURSOR_VALID then Result := 1 else Result := 0;
end;

function sqlite3BtreeIntegerKey(pCur: PBtCursor): i64;
begin
  getCellInfo(pCur);
  Result := pCur^.info.nKey;
end;

function sqlite3BtreePayloadSize(pCur: PBtCursor): u32;
begin
  getCellInfo(pCur);
  Result := pCur^.info.nPayload;
end;

{ ---------------------------------------------------------------------------
  sqlite3BtreeOffset
  btree.c lines 4937-4948
  --------------------------------------------------------------------------- }
function sqlite3BtreeOffset(pCur: PBtCursor): i64;
begin
  getCellInfo(pCur);
  Result := i64(pCur^.pBt^.pageSize) * (i64(pCur^.pPage^.pgno) - 1) +
            i64(PtrUInt(pCur^.info.pPayload) - PtrUInt(pCur^.pPage^.aData));
end;

{ ---------------------------------------------------------------------------
  sqlite3BtreeIsReadonly
  btree.c lines 11528-11533
  --------------------------------------------------------------------------- }
function sqlite3BtreeIsReadonly(p: PBtree): i32;
begin
  if (p^.pBt^.btsFlags and BTS_READ_ONLY) <> 0 then
    Result := 1
  else
    Result := 0;
end;

{ ---------------------------------------------------------------------------
  sqlite3BtreeCheckpoint — btree.c:11320
  Run a WAL checkpoint on the database that p is connected to.  No-op when
  p is nil or no WAL is open.  SQLITE_LOCKED if a transaction is in flight.
  --------------------------------------------------------------------------- }
function sqlite3BtreeCheckpoint(p: PBtree; eMode: i32;
                                pnLog, pnCkpt: PcInt): i32;
var
  pBt: PBtShared;
begin
  Result := SQLITE_OK;
  if p = nil then Exit;
  pBt := p^.pBt;
  sqlite3BtreeEnter(p);
  if pBt^.inTransaction <> TRANS_NONE then
    Result := SQLITE_LOCKED
  else
    Result := sqlite3PagerCheckpoint(pBt^.pPager, p^.db, eMode,
                                     nil, nil, pnLog, pnCkpt);
  sqlite3BtreeLeave(p);
end;

{ ---------------------------------------------------------------------------
  copyPayload helper (internal, read-only path for Phase 4.2)
  btree.c lines 5106-5120
  --------------------------------------------------------------------------- }
function copyPayload(pPayload: Pointer; pBuf: Pointer; nByte: i32;
                     eOp: i32; pDbPage: PDbPage): i32;
begin
  if eOp = 0 then begin
    Move(pPayload^, pBuf^, nByte);
    Result := SQLITE_OK;
  end else begin
    Result := sqlite3PagerWrite(pDbPage);
    if Result = SQLITE_OK then
      Move(pBuf^, pPayload^, nByte);
  end;
end;

{ ---------------------------------------------------------------------------
  getOverflowPage
  btree.c lines 5000-5060
  --------------------------------------------------------------------------- }
function getOverflowPage(pBt: PBtShared; ovfl: Pgno;
                         ppPage: PPMemPage; pPgnoNext: PPgno): i32;
var
  next  : Pgno;
  pPage : PMemPage;
  rc    : i32;
begin
  next  := 0;
  pPage := nil;
  rc    := SQLITE_OK;

  rc := btreeGetPage(pBt, ovfl, pPage, PAGER_GET_READONLY);
  if rc = SQLITE_OK then
    next := get4byte(pPage^.aData);
  { btreeGetPage uses 'out ppPage: PMemPage' so pPage is already assigned }

  pPgnoNext^ := next;
  if ppPage <> nil then
    ppPage^ := pPage
  else
    releasePage(pPage);

  Result := rc;
end;

{ ---------------------------------------------------------------------------
  accessPayload
  btree.c lines 5121-5330
  --------------------------------------------------------------------------- }
function accessPayload(pCur: PBtCursor; offset: u32; amt: u32;
                       pBuf: Pu8; eOp: i32): i32;
var
  aPayload : Pu8;
  rc       : i32;
  iIdx     : i32;
  pPage    : PMemPage;
  pBt      : PBtShared;
  a        : i32;
  ovflSize : u32;
  nextPage : Pgno;
  pDbPg    : PDbPage;
  nOvfl    : i32;
  aNew     : PPgno;
  iAmt     : i32;
begin
  rc := SQLITE_OK;
  iIdx := 0;
  pPage := pCur^.pPage;
  pBt   := pCur^.pBt;

  getCellInfo(pCur);
  aPayload := pCur^.info.pPayload;

  { Check in-page data first }
  if offset < pCur^.info.nLocal then begin
    a := i32(amt);
    if i32(a) + i32(offset) > i32(pCur^.info.nLocal) then
      a := i32(pCur^.info.nLocal) - i32(offset);
    rc := copyPayload(aPayload + offset, pBuf, a, eOp, pPage^.pDbPage);
    offset := 0;
    pBuf := pBuf + a;
    amt  := amt - u32(a);
  end else begin
    offset := offset - pCur^.info.nLocal;
  end;

  if (rc = SQLITE_OK) and (amt > 0) then begin
    ovflSize := pBt^.usableSize - 4;
    nextPage := get4byte(aPayload + pCur^.info.nLocal);

    { Allocate / use overflow page cache }
    if (pCur^.curFlags and BTCF_ValidOvfl) = 0 then begin
      nOvfl := (i32(pCur^.info.nPayload) - i32(pCur^.info.nLocal) +
                i32(ovflSize) - 1) div i32(ovflSize);
      aNew := PPgno(sqlite3Realloc(Pointer(pCur^.aOverflow),
                                    NativeUInt(nOvfl) * 2 * SizeOf(Pgno)));
      if aNew = nil then begin
        Result := SQLITE_NOMEM_BKPT;
        Exit;
      end;
      pCur^.aOverflow := aNew;
      FillChar(pCur^.aOverflow^, nOvfl * SizeOf(Pgno), 0);
      pCur^.curFlags := pCur^.curFlags or BTCF_ValidOvfl;
    end else begin
      if pCur^.aOverflow[offset div ovflSize] <> 0 then begin
        iIdx     := i32(offset div ovflSize);
        nextPage := pCur^.aOverflow[iIdx];
        offset   := offset mod ovflSize;
      end;
    end;

    while nextPage <> 0 do begin
      if nextPage > pBt^.nPage then begin
        Result := SQLITE_CORRUPT_BKPT;
        Exit;
      end;
      pCur^.aOverflow[iIdx] := nextPage;

      if offset >= ovflSize then begin
        if pCur^.aOverflow[iIdx + 1] <> 0 then
          nextPage := pCur^.aOverflow[iIdx + 1]
        else
          rc := getOverflowPage(pBt, nextPage, nil, @nextPage);
        offset := offset - ovflSize;
      end else begin
        iAmt := i32(amt);
        if iAmt + i32(offset) > i32(ovflSize) then
          iAmt := i32(ovflSize) - i32(offset);
        { btree.c:5283 — read uses PAGER_GET_READONLY, write uses 0.
          NB: must NOT pass Ord(eOp=0)=1, which collides with
          PAGER_GET_NOCONTENT ($01) and zeroes the page buffer. }
        if eOp = 0 then
          rc := sqlite3PagerGet(pBt^.pPager, nextPage, @pDbPg, PAGER_GET_READONLY)
        else
          rc := sqlite3PagerGet(pBt^.pPager, nextPage, @pDbPg, 0);
        if rc = SQLITE_OK then begin
          aPayload := Pu8(sqlite3PagerGetData(pDbPg));
          nextPage := get4byte(aPayload);
          rc := copyPayload(aPayload + offset + 4, pBuf, iAmt, eOp, pDbPg);
          sqlite3PagerUnref(pDbPg);
          offset := 0;
        end;
        amt := amt - u32(iAmt);
        if amt = 0 then begin
          Result := rc;
          Exit;
        end;
        pBuf := pBuf + iAmt;
      end;
      if rc <> SQLITE_OK then break;
      Inc(iIdx);
    end;
  end;

  if (rc = SQLITE_OK) and (amt > 0) then
    Result := CORRUPT_PAGE(pCur^.pPage)
  else
    Result := rc;
end;

{ ---------------------------------------------------------------------------
  sqlite3BtreePayload
  btree.c lines 5333-5349
  --------------------------------------------------------------------------- }
function sqlite3BtreePayload(pCur: PBtCursor; offset: u32; amt: u32;
                              pBuf: Pointer): i32;
begin
  Result := accessPayload(pCur, offset, amt, Pu8(pBuf), 0);
end;

{ ---------------------------------------------------------------------------
  accessPayloadChecked — slow path of sqlite3BtreePayloadChecked.
  btree.c lines 5346-5358.  Used by the incremental-blob read path when the
  cursor may have been invalidated by an intervening write.
  --------------------------------------------------------------------------- }
function accessPayloadChecked(pCur: PBtCursor; offset: u32; amt: u32;
                              pBuf: Pointer): i32;
var
  rc: i32;
begin
  if pCur^.eState = CURSOR_INVALID then begin
    Result := SQLITE_ABORT;
    Exit;
  end;
  rc := btreeRestoreCursorPosition(pCur);
  if rc <> SQLITE_OK then
    Result := rc
  else
    Result := accessPayload(pCur, offset, amt, Pu8(pBuf), 0);
end;

{ ---------------------------------------------------------------------------
  sqlite3BtreePayloadChecked
  btree.c lines 5360-5367.  Like sqlite3BtreePayload but tolerates a cursor
  whose state is not CURSOR_VALID (used only by sqlite3_blob_read).
  --------------------------------------------------------------------------- }
function sqlite3BtreePayloadChecked(pCur: PBtCursor; offset: u32; amt: u32;
                                    pBuf: Pointer): i32;
begin
  if pCur^.eState = CURSOR_VALID then
    Result := accessPayload(pCur, offset, amt, Pu8(pBuf), 0)
  else
    Result := accessPayloadChecked(pCur, offset, amt, pBuf);
end;

{ ---------------------------------------------------------------------------
  sqlite3BtreePutData — write into the data area of the row pCsr points at.
  btree.c lines 11430-11473.  The cursor must be open for writing on an
  INTKEY table.  The size of the data is not changed; writing past the end
  returns SQLITE_CORRUPT.
  --------------------------------------------------------------------------- }
function sqlite3BtreePutData(pCsr: PBtCursor; offset: u32; amt: u32;
                             z: Pointer): i32;
var
  rc: i32;
begin
  rc := restoreCursorPosition(pCsr);
  if rc <> SQLITE_OK then begin
    Result := rc;
    Exit;
  end;
  if pCsr^.eState <> CURSOR_VALID then begin
    Result := SQLITE_ABORT;
    Exit;
  end;
  { saveAllCursors cannot fail on an INTKEY table; ignore its return value. }
  saveAllCursors(pCsr^.pBt, pCsr^.pgnoRoot, pCsr);
  if (pCsr^.curFlags and BTCF_WriteFlag) = 0 then begin
    Result := SQLITE_READONLY;
    Exit;
  end;
  Result := accessPayload(pCsr, offset, amt, Pu8(z), 1);
end;

{ ---------------------------------------------------------------------------
  sqlite3BtreeIncrblobCursor — mark this cursor as an incremental blob
  cursor.  btree.c lines 11475-11481.
  --------------------------------------------------------------------------- }
procedure sqlite3BtreeIncrblobCursor(pCur: PBtCursor);
begin
  pCur^.curFlags := pCur^.curFlags or BTCF_Incrblob;
  pCur^.pBtree^.hasIncrblobCur := 1;
end;

{ ---------------------------------------------------------------------------
  sqlite3BtreePayloadFetch — return in-page payload pointer if available.
  Port of btree.c sqlite3BtreePayloadFetch (btree.c line ~5351).
  Returns pointer to page-local data if all `pAmt` bytes are on the leaf page;
  otherwise sets pAmt=0 and returns nil (caller uses sqlite3BtreePayload).
  --------------------------------------------------------------------------- }
function sqlite3BtreePayloadFetch(pCur: PBtCursor; out pAmt: u32): PAnsiChar;
var
  pPage: PMemPage;
begin
  pPage := pCur^.pPage;
  if pPage = nil then begin
    pAmt := 0; Result := nil; Exit;
  end;
  getCellInfo(pCur);
  { btree.c:fetchPayload — return pPayload directly for both table and
    index cursors.  btreeParseCellPtr / btreeParseCellPtrIndex already
    set pPayload past the cell prefix (size varint + optional rowid
    varint).  Adding nKey for index cursors as a previous Pascal-port
    quirk did was wrong: in index cells nKey == nPayload (length),
    not an offset, so the previous code skipped past the entire record
    and OP_Column read NULL on every index-eph row. }
  pAmt   := u32(pCur^.info.nLocal);
  Result := PAnsiChar(pCur^.info.pPayload);
end;

{ ---------------------------------------------------------------------------
  sqlite3BtreeMaxRecordSize — maximum record size visible via BtreePayload.
  --------------------------------------------------------------------------- }
function sqlite3BtreeMaxRecordSize(pCur: PBtCursor): u32;
begin
  getCellInfo(pCur);
  Result := u32(pCur^.info.nPayload);
end;

function sqlite3BtreeCursorIsValid(pCur: PBtCursor): i32;
begin
  if pCur = nil then Result := 0
  else Result := sqlite3BtreeCursorIsValidNN(pCur);
end;

{ ---------------------------------------------------------------------------
  moveToChild
  btree.c lines 5442-5473
  --------------------------------------------------------------------------- }
function moveToChild(pCur: PBtCursor; newPgno: Pgno): i32;
var
  rc: i32;
begin
  if pCur^.iPage >= (BTCURSOR_MAX_DEPTH - 1) then begin
    Result := SQLITE_CORRUPT_BKPT;
    Exit;
  end;
  pCur^.info.nSize := 0;
  pCur^.curFlags := pCur^.curFlags and (not (BTCF_ValidNKey or BTCF_ValidOvfl));
  pCur^.aiIdx[pCur^.iPage] := pCur^.ix;
  pCur^.apPage[pCur^.iPage] := pCur^.pPage;
  pCur^.ix := 0;
  Inc(pCur^.iPage);
  rc := getAndInitPage(pCur^.pBt, newPgno, pCur^.pPage, pCur^.curPagerFlags);
  if rc = SQLITE_OK then begin
    if (pCur^.pPage^.nCell < 1) or
       (pCur^.pPage^.intKey <> pCur^.curIntKey) then begin
      releasePage(pCur^.pPage);
      rc := SQLITE_CORRUPT_BKPT;
    end;
  end;
  if rc <> SQLITE_OK then begin
    Dec(pCur^.iPage);
    pCur^.pPage := pCur^.apPage[pCur^.iPage];
  end;
  Result := rc;
end;

{ ---------------------------------------------------------------------------
  moveToParent
  btree.c lines 5501-5526
  --------------------------------------------------------------------------- }
procedure moveToParent(pCur: PBtCursor);
var
  pLeaf: PMemPage;
begin
  pCur^.info.nSize := 0;
  pCur^.curFlags := pCur^.curFlags and (not (BTCF_ValidNKey or BTCF_ValidOvfl));
  pCur^.ix := pCur^.aiIdx[pCur^.iPage - 1];
  pLeaf := pCur^.pPage;
  Dec(pCur^.iPage);
  pCur^.pPage := pCur^.apPage[pCur^.iPage];
  releasePageNotNull(pLeaf);
end;

{ ---------------------------------------------------------------------------
  moveToRoot
  btree.c lines 5542-5665
  --------------------------------------------------------------------------- }
function moveToRoot(pCur: PBtCursor): i32;
var
  pRoot  : PMemPage;
  rc     : i32;
  subpage: Pgno;
label
  skip_init;
begin
  rc := SQLITE_OK;

  if pCur^.iPage >= 0 then begin
    if pCur^.iPage > 0 then begin
      { Release all pages except apPage[0] }
      releasePageNotNull(pCur^.pPage);
      while pCur^.iPage > 1 do begin
        Dec(pCur^.iPage);
        releasePageNotNull(pCur^.apPage[pCur^.iPage]);
      end;
      Dec(pCur^.iPage);
      pRoot := pCur^.apPage[0];
      pCur^.pPage := pRoot;
      goto skip_init;
    end;
    { iPage = 0: already at root, fall through to skip_init }
  end else if pCur^.pgnoRoot = 0 then begin
    pCur^.eState := CURSOR_INVALID;
    Result := SQLITE_EMPTY;
    Exit;
  end else begin
    if pCur^.eState >= CURSOR_REQUIRESEEK then begin
      if pCur^.eState = CURSOR_FAULT then begin
        Result := pCur^.skipNext;
        Exit;
      end;
      sqlite3BtreeClearCursor(pCur);
    end;
    rc := getAndInitPage(pCur^.pBt, pCur^.pgnoRoot, pCur^.pPage,
                         pCur^.curPagerFlags);
    if rc <> SQLITE_OK then begin
      pCur^.eState := CURSOR_INVALID;
      Result := rc;
      Exit;
    end;
    pCur^.iPage := 0;
    pCur^.curIntKey := pCur^.pPage^.intKey;
  end;

  pRoot := pCur^.pPage;

  if (pRoot^.isInit = 0) or
     ((pCur^.pKeyInfo = nil) <> (pRoot^.intKey <> 0)) then begin
    Result := CORRUPT_PAGE(pCur^.pPage);
    Exit;
  end;

skip_init:
  pCur^.ix := 0;
  pCur^.info.nSize := 0;
  pCur^.curFlags := pCur^.curFlags and
    (not (BTCF_AtLast or BTCF_ValidNKey or BTCF_ValidOvfl));

  if pRoot^.nCell > 0 then begin
    pCur^.eState := CURSOR_VALID;
  end else if pRoot^.leaf = 0 then begin
    if pRoot^.pgno <> 1 then begin
      Result := SQLITE_CORRUPT_BKPT;
      Exit;
    end;
    subpage := get4byte(pRoot^.aData + pRoot^.hdrOffset + 8);
    pCur^.eState := CURSOR_VALID;
    rc := moveToChild(pCur, subpage);
  end else begin
    pCur^.eState := CURSOR_INVALID;
    rc := SQLITE_EMPTY;
  end;
  Result := rc;
end;

{ ---------------------------------------------------------------------------
  moveToLeftmost / moveToRightmost
  btree.c lines 5667-5706
  --------------------------------------------------------------------------- }
function moveToLeftmost(pCur: PBtCursor): i32;
var
  pg   : Pgno;
  rc   : i32;
  pPage: PMemPage;
begin
  rc := SQLITE_OK;
  while (rc = SQLITE_OK) do begin
    pPage := pCur^.pPage;
    if pPage^.leaf <> 0 then break;
    pg := get4byte(findCell(pPage, pCur^.ix));
    rc := moveToChild(pCur, pg);
  end;
  Result := rc;
end;

function moveToRightmost(pCur: PBtCursor): i32;
var
  pg   : Pgno;
  rc   : i32;
  pPage: PMemPage;
begin
  rc := SQLITE_OK;
  while True do begin
    pPage := pCur^.pPage;
    if pPage^.leaf <> 0 then break;
    pg := get4byte(pPage^.aData + pPage^.hdrOffset + 8);
    pCur^.ix := pPage^.nCell;
    rc := moveToChild(pCur, pg);
    if rc <> SQLITE_OK then begin
      Result := rc;
      Exit;
    end;
  end;
  pCur^.ix := pPage^.nCell - 1;
  pCur^.info.nSize := 0;
  pCur^.curFlags := pCur^.curFlags and (not BTCF_ValidNKey);
  Result := SQLITE_OK;
end;

{ ---------------------------------------------------------------------------
  sqlite3BtreeFirst / sqlite3BtreeLast
  btree.c lines 5707-5766
  --------------------------------------------------------------------------- }
function sqlite3BtreeFirst(pCur: PBtCursor; pRes: Pi32): i32;
var
  rc: i32;
begin
  rc := moveToRoot(pCur);
  if rc = SQLITE_OK then begin
    pRes^ := 0;
    rc := moveToLeftmost(pCur);
  end else if rc = SQLITE_EMPTY then begin
    pRes^ := 1;
    rc := SQLITE_OK;
  end;
  Result := rc;
end;

function sqlite3BtreeLast(pCur: PBtCursor; pRes: Pi32): i32;
var
  rc: i32;
begin
  { Fast path: cursor is already at last entry }
  if (pCur^.eState = CURSOR_VALID) and
     ((pCur^.curFlags and BTCF_AtLast) <> 0) then begin
    pRes^ := 0;
    Result := SQLITE_OK;
    Exit;
  end;

  rc := moveToRoot(pCur);
  if rc = SQLITE_OK then begin
    pRes^ := 0;
    rc := moveToRightmost(pCur);
    if rc = SQLITE_OK then
      pCur^.curFlags := pCur^.curFlags or BTCF_AtLast
    else
      pCur^.curFlags := pCur^.curFlags and (not BTCF_AtLast);
  end else if rc = SQLITE_EMPTY then begin
    pRes^ := 1;
    rc := SQLITE_OK;
  end;
  Result := rc;
end;

{ ---------------------------------------------------------------------------
  sqlite3BtreeTableMoveto  (integer key binary search)
  btree.c lines 5793-5951
  --------------------------------------------------------------------------- }
function sqlite3BtreeTableMoveto(pCur: PBtCursor; intKey: i64;
                                  biasRight: i32; pRes: Pi32): i32;
var
  rc     : i32;
  lwr    : i32;
  upr    : i32;
  idx    : i32;
  c      : i32;
  chldPg : Pgno;
  pPage  : PMemPage;
  pCell  : Pu8;
  nCellKey: i64;
  rawKey : u64;
  { 12.2.candidate.4: cache hot pPage^ fields in locals so FPC does not
    re-deref through pPage every loop iteration.  Refreshed each outer
    iteration immediately after pPage := pCur^.pPage. }
  aData   : Pu8;
  aDataO  : Pu8;   { aDataOfst — used by findCellPastPtr inline }
  aCellI  : Pu8;   { aCellIdx  — used by findCellPastPtr inline }
  mskPage : u16;   { maskPage }
label
  moveto_table_next_layer, moveto_table_finish;
begin
  rc := SQLITE_OK;

  { Fast path: cursor already valid and key cached }
  if (pCur^.eState = CURSOR_VALID) and
     ((pCur^.curFlags and BTCF_ValidNKey) <> 0) then begin
    if pCur^.info.nKey = intKey then begin
      pRes^ := 0;
      Result := SQLITE_OK;
      Exit;
    end;
    if (pCur^.info.nKey < intKey) and
       ((pCur^.curFlags and BTCF_AtLast) <> 0) then begin
      pRes^ := -1;
      Result := SQLITE_OK;
      Exit;
    end;
  end;

  rc := moveToRoot(pCur);
  if rc <> SQLITE_OK then begin
    if rc = SQLITE_EMPTY then begin
      pRes^ := -1;
      Result := SQLITE_OK;
    end else begin
      Result := rc;
    end;
    Exit;
  end;

  c := 0;
  while True do begin
    pPage := pCur^.pPage;
    { Refresh cached locals — pPage may have changed via moveToChild. }
    aData   := pPage^.aData;
    aDataO  := pPage^.aDataOfst;
    aCellI  := pPage^.aCellIdx;
    mskPage := pPage^.maskPage;
    lwr := 0;
    upr := pPage^.nCell - 1;
    if biasRight <> 0 then
      idx := upr
    else
      idx := upr shr 1;

    while True do begin
      { Inlined findCellPastPtr(pPage, idx) using cached locals. }
      pCell := aDataO + (mskPage and u16(get2byteAligned(aCellI + 2*idx)));
      if pPage^.intKeyLeaf <> 0 then begin
        { Skip the payload length varint }
        while (pCell[0] and $80 <> 0) do begin
          if pCell >= pPage^.aDataEnd then begin
            Result := CORRUPT_PAGE(pPage);
            Exit;
          end;
          Inc(pCell);
        end;
        Inc(pCell);
      end;
      sqlite3GetVarint(pCell, rawKey);
      nCellKey := i64(rawKey);

      if nCellKey < intKey then begin
        lwr := idx + 1;
        if lwr > upr then begin c := -1; break; end;
      end else if nCellKey > intKey then begin
        upr := idx - 1;
        if lwr > upr then begin c := +1; break; end;
      end else begin
        pCur^.ix := u16(idx);
        if pPage^.leaf = 0 then begin
          lwr := idx;
          goto moveto_table_next_layer;
        end else begin
          pCur^.curFlags := pCur^.curFlags or BTCF_ValidNKey;
          pCur^.info.nKey := nCellKey;
          pCur^.info.nSize := 0;
          pRes^ := 0;
          Result := SQLITE_OK;
          Exit;
        end;
      end;
      idx := (lwr + upr) shr 1;
    end;

    { Binary search exhausted without exact match }
    if pPage^.leaf <> 0 then begin
      pCur^.ix := u16(idx);
      pRes^ := c;
      rc := SQLITE_OK;
      goto moveto_table_finish;
    end;

moveto_table_next_layer:
    if lwr >= pPage^.nCell then
      chldPg := get4byte(aData + pPage^.hdrOffset + 8)
    else
      { Inlined findCell(pPage, lwr) using cached locals. }
      chldPg := get4byte(aData + (mskPage and u16(get2byteAligned(aCellI + 2*lwr))));
    pCur^.ix := u16(lwr);
    rc := moveToChild(pCur, chldPg);
    if rc <> SQLITE_OK then begin
      pRes^ := c;
      Result := rc;
      Exit;
    end;
  end;

moveto_table_finish:
  pCur^.info.nSize := 0;
  pCur^.curFlags := pCur^.curFlags and (not BTCF_ValidOvfl);
  Result := rc;
end;

{ ---------------------------------------------------------------------------
  sqlite3VdbeRecordCompare / sqlite3VdbeFindCompare
  Source: vdbeaux.c sqlite3VdbeRecordCompareWithSkip / sqlite3VdbeRecordCompare
          / sqlite3VdbeFindCompare (lines 4733..5180).

  Step 6.IPK-IN.b minimum-viable port.  Handles the integer / NULL RHS
  cases that arise from rowid-keyed ephemeral btrees (IPK-IN literal-
  list materialisation, OP_SeekRowid via OP_IdxInsert).  String / blob
  / real RHS arms are stubbed as "neutral" (rc=0 → continue to default_rc),
  which is correct for empty / non-collation single-int-key indexes but
  insufficient for general index lookup.  Tracked under tasklist 6.10
  step 6.IPK-IN.b.full.

  Layout note: btree's slim TUnpackedRecord (pKeyInfo/aMem/nField:i32/
  default_rc:i32/eqSeen:u8) is what every caller in vdbe.pas writes
  (`rSeek: TUnpackedRecord` produced under btree's typedef).  No Mem
  layout is exposed to btree, so we mirror only the prefix needed for
  flags + integer value.
  --------------------------------------------------------------------------- }

type
  TBtMemView = packed record
    u_i:   i64;        { offset  0 — Mem.u (union: i64 / r) }
    z:     PAnsiChar;  { offset  8 — Mem.z }
    n:     i32;        { offset 16 — Mem.n }
    flags: u16;        { offset 20 — Mem.flags }
    enc:   u8;         { offset 22 — Mem.enc (used by collation hook) }
    { remainder unused by this comparator }
  end;
  PBtMemView = ^TBtMemView;

  { Opaque view of TCollSeq (vdbe.pas) — used only for the collation hook
    in sqlite3VdbeRecordCompare.  Layout matches TCollSeq exactly:
    zName(8) + enc(1) + pad(7) + pUser(8) + xCmp(8) + xDel(8) = 40 bytes. }
  TBtCollCmp = function(pUser: Pointer; nA: i32; pA: Pointer;
                        nB: i32; pB: Pointer): i32; cdecl;
  TBtCollView = packed record
    zName: PAnsiChar;        { offset 0 }
    enc:   u8;               { offset 8 }
    _pad:  array[0..6] of u8;{ offset 9..15 }
    pUser: Pointer;          { offset 16 }
    xCmp:  TBtCollCmp;       { offset 24 }
  end;
  PBtCollView = ^TBtCollView;

const
  BT_MEM_Null    = $0001;
  BT_MEM_Str     = $0002;
  BT_MEM_Int     = $0004;
  BT_MEM_Real    = $0008;
  BT_MEM_Blob    = $0010;
  BT_MEM_IntReal = $0020;
  BT_MEM_Zero    = $0400;
  { Stride between consecutive TMem cells in the aMem array.  Mirrors
    SizeOf(passqlite3vdbe.TMem) — vdbe.pas is not visible to btree.pas
    (would create a uses-cycle), so the size is hardcoded.  If TMem
    layout changes, update this constant. }
  BT_MEM_STRIDE  = 56;

function btreeSerialTypeLen(t: u32): u32; inline;
begin
  if t >= 12 then Result := (t - 12) shr 1
  else case t of
    0, 8, 9, 10, 11: Result := 0;
    1: Result := 1;
    2: Result := 2;
    3: Result := 3;
    4: Result := 4;
    5: Result := 6;
    6, 7: Result := 8;
    else Result := 0;
  end;
end;

{ Decode an IEEE-754 8-byte big-endian float from aKey.  Returns 1 when the
  bit pattern is a NaN (caller must treat as NULL), 0 otherwise.  Mirrors
  vdbeaux.c serialGet7. }
function btreeSerialGet7Real(buf: Pu8; out r: Double): i32;
var x: u64;
begin
  x := (u64(buf[0]) shl 56) or (u64(buf[1]) shl 48)
    or (u64(buf[2]) shl 40) or (u64(buf[3]) shl 32)
    or (u64(buf[4]) shl 24) or (u64(buf[5]) shl 16)
    or (u64(buf[6]) shl 8)  or  u64(buf[7]);
  Move(x, r, 8);
  if ((x and u64($7FF0000000000000)) = u64($7FF0000000000000))
     and ((x and u64($000FFFFFFFFFFFFF)) <> 0) then
    Result := 1
  else
    Result := 0;
end;

{ Local copy of sqlite3IntFloatCompare (vdbeaux.c:4551) — vdbe.pas's copy
  is unreachable from btree.pas without a uses-cycle. }
function btreeIntFloatCompare(i: i64; r: Double): i32;
var y: i64;
    di: Double;
begin
  { NaN → NULL → integer is greater }
  if (PUInt64(@r)^ and u64($7FF0000000000000)) = u64($7FF0000000000000) then begin
    if (PUInt64(@r)^ and u64($000FFFFFFFFFFFFF)) <> 0 then begin
      Result := 1;
      Exit;
    end;
  end;
  if r < -9223372036854775808.0 then begin Result := 1; Exit; end;
  if r >=  9223372036854775808.0 then begin Result := -1; Exit; end;
  y := i64(Trunc(r));
  if i < y then begin Result := -1; Exit; end;
  if i > y then begin Result := 1; Exit; end;
  di := i;
  if di < r then Result := -1
  else if di > r then Result := 1
  else Result := 0;
end;

{ Test whether an n-byte buffer is all 0x00. }
function btreeIsAllZero(p: Pu8; n: i32): Boolean;
var k: i32;
begin
  for k := 0 to n - 1 do
    if p[k] <> 0 then begin Result := False; Exit; end;
  Result := True;
end;

function btreeDecodeInt(serialType: u32; aKey: Pu8): i64;
var x: u64;
begin
  case serialType of
    0, 1: Result := i64(i8(aKey[0]));
    2:    Result := i64(i16((u16(aKey[0]) shl 8) or u16(aKey[1])));
    3: begin
      x := (u32(aKey[0]) shl 16) or (u32(aKey[1]) shl 8) or u32(aKey[2]);
      if (x and $800000) <> 0 then x := x or u64($FFFFFFFFFF000000);
      Result := i64(x);
    end;
    4: Result := i64(i32((u32(aKey[0]) shl 24) or (u32(aKey[1]) shl 16)
                       or (u32(aKey[2]) shl 8) or u32(aKey[3])));
    5: begin
      x := (u32(aKey[2]) shl 24) or (u32(aKey[3]) shl 16)
        or (u32(aKey[4]) shl 8) or u32(aKey[5]);
      x := x + u64(i64(i16((u16(aKey[0]) shl 8) or u16(aKey[1]))) shl 32);
      Result := i64(x);
    end;
    6: begin
      x := (u64(aKey[0]) shl 56) or (u64(aKey[1]) shl 48)
        or (u64(aKey[2]) shl 40) or (u64(aKey[3]) shl 32)
        or (u64(aKey[4]) shl 24) or (u64(aKey[5]) shl 16)
        or (u64(aKey[6]) shl 8)  or  u64(aKey[7]);
      Result := i64(x);
    end;
    8: Result := 0;
    9: Result := 1;
    else Result := i64(serialType - 8);
  end;
end;

function sqlite3VdbeRecordCompare(nKey: i32; pKey: Pointer;
                                  pIdxKey: PUnpackedRecord): i32;
const
  BT_KEYINFO_ORDER_DESC    = 1;
  BT_KEYINFO_ORDER_BIGNULL = 2;
var
  pKey1:       Pointer;
  nKey1:       i32;
  aKey1:       Pu8;
  szHdr1:      u32;
  idx1, d1:    u32;
  i, rc:       i32;
  serial_type: u32;
  pRhs:        PBtMemView;
  v1:          i64;
  vTmp32:      u32;
  rReal, rRhs: Double;
  nStr, nCmp:  i32;
  pSortFlags:  Pu8;
  sortFlag:    u8;
  descBit, nullSide: i32;
  pColl:       PBtCollView;
  collEnc, kiEnc: u8;
begin
  pKey1 := pKey;
  nKey1 := nKey;
  aKey1 := Pu8(pKey1);
  rc := 0;
  serial_type := 0;

  szHdr1 := aKey1[0];
  if szHdr1 < $80 then
    idx1 := 1
  else begin
    idx1 := sqlite3GetVarint32(aKey1, szHdr1);
  end;
  d1 := szHdr1;
  if d1 > u32(nKey1) then begin
    Result := 0;
    Exit;
  end;

  pRhs := PBtMemView(pIdxKey^.aMem);
  i := 0;
  while True do begin
    if aKey1[idx1] < $80 then
      serial_type := aKey1[idx1]
    else
      sqlite3GetVarint32(@aKey1[idx1], serial_type);

    if (pRhs^.flags and (BT_MEM_Int or BT_MEM_IntReal)) <> 0 then begin
      { RHS integer — vdbeaux.c:4786 }
      if serial_type >= 10 then begin
        if serial_type = 10 then rc := -1 else rc := 1;
      end else if serial_type = 0 then rc := -1
      else if serial_type = 7 then begin
        btreeSerialGet7Real(@aKey1[d1], rReal);
        rc := -btreeIntFloatCompare(pRhs^.u_i, rReal);
      end
      else begin
        v1 := btreeDecodeInt(serial_type, @aKey1[d1]);
        if v1 < pRhs^.u_i then rc := -1
        else if v1 > pRhs^.u_i then rc := 1
        else rc := 0;
      end;
    end else if (pRhs^.flags and BT_MEM_Real) <> 0 then begin
      { RHS real — vdbeaux.c:4810 }
      rRhs := PDouble(@pRhs^.u_i)^;
      if serial_type >= 10 then begin
        if serial_type = 10 then rc := -1 else rc := 1;
      end else if serial_type = 0 then rc := -1
      else if serial_type = 7 then begin
        if btreeSerialGet7Real(@aKey1[d1], rReal) <> 0 then rc := -1
        else if rReal < rRhs then rc := -1
        else if rReal > rRhs then rc := 1
        else rc := 0;
      end else begin
        v1 := btreeDecodeInt(serial_type, @aKey1[d1]);
        rc := btreeIntFloatCompare(v1, rRhs);
      end;
    end else if (pRhs^.flags and BT_MEM_Str) <> 0 then begin
      { RHS string — vdbeaux.c:4839.  serial_type already decoded above;
        the C arm uses the value computed by getVarint32() at the top of
        the loop and does not re-read it. }
      if serial_type < 12 then rc := -1
      else if (serial_type and 1) = 0 then rc := 1
      else begin
        nStr := i32((serial_type - 12) shr 1);
        if (d1 + u32(nStr)) > u32(nKey1) then begin
          { Corruption — match C return-0-without-eqSeen }
          Result := 0;
          Exit;
        end;
        { Collation-aware compare — vdbeaux.c:4839.  pKeyInfo->aColl[i]
          carries the collation pointer (NULL = BINARY).  TKeyInfo
          layout: aColl[FLEXARRAY] starts at offset 32 (SizeOf(TKeyInfo)),
          aColl[i] = PPointer(pKeyInfo + 32 + i*8).  Same-encoding fast
          path only; encoding-mismatch falls back to BINARY compare
          (vdbeCompareMemString transcoding arm not ported — default
          UTF-8 build never reaches it). }
        pColl := nil;
        if pIdxKey^.pKeyInfo <> nil then
        begin
          pColl := PBtCollView(PPointer(PByte(pIdxKey^.pKeyInfo)
                                        + 32 + i * 8)^);
          if pColl <> nil then
          begin
            kiEnc   := PByte(pIdxKey^.pKeyInfo)[4];  { TKeyInfo.enc @4 }
            collEnc := pColl^.enc;
            if (collEnc <> kiEnc) or (kiEnc <> pRhs^.enc)
               or (not Assigned(pColl^.xCmp)) then
              pColl := nil;
          end;
        end;
        if pColl <> nil then
        begin
          rc := pColl^.xCmp(pColl^.pUser,
                            nStr,    @aKey1[d1],
                            pRhs^.n, pRhs^.z);
        end else
        begin
          if nStr < pRhs^.n then nCmp := nStr else nCmp := pRhs^.n;
          if nCmp > 0 then
            rc := i32(CompareByte((@aKey1[d1])^, pRhs^.z^, nCmp))
          else
            rc := 0;
          if rc = 0 then rc := nStr - pRhs^.n;
        end;
      end;
    end else if (pRhs^.flags and BT_MEM_Blob) <> 0 then begin
      { RHS blob — vdbeaux.c:4872.  serial_type already decoded above. }
      if (serial_type < 12) or ((serial_type and 1) <> 0) then rc := -1
      else begin
        nStr := i32((serial_type - 12) shr 1);
        if (d1 + u32(nStr)) > u32(nKey1) then begin
          Result := 0;
          Exit;
        end;
        if (pRhs^.flags and BT_MEM_Zero) <> 0 then begin
          if not btreeIsAllZero(@aKey1[d1], nStr) then rc := 1
          else rc := nStr - i32(pRhs^.u_i);  { u.nZero shares u.i slot }
        end else begin
          if nStr < pRhs^.n then nCmp := nStr else nCmp := pRhs^.n;
          if nCmp > 0 then
            rc := i32(CompareByte((@aKey1[d1])^, pRhs^.z^, nCmp))
          else
            rc := 0;
          if rc = 0 then rc := nStr - pRhs^.n;
        end;
      end;
    end else if (pRhs^.flags and BT_MEM_Null) <> 0 then begin
      if (serial_type = 0) or (serial_type = 10) then rc := 0
      else if (serial_type = 7) then begin
        if btreeSerialGet7Real(@aKey1[d1], rReal) <> 0 then rc := 0
        else rc := 1;
      end else rc := 1;
    end else
      rc := 0;

    if rc <> 0 then begin
      { aSortFlags inversion — vdbeaux.c sqlite3VdbeRecordCompareWithSkip.
        pKeyInfo is opaque (Pointer) here; aSortFlags lives at offset 24
        in TKeyInfo (codegen.pas:1094). }
      if pIdxKey^.pKeyInfo <> nil then begin
        pSortFlags := Pu8(PPointer(PByte(pIdxKey^.pKeyInfo) + 24)^);
        if pSortFlags <> nil then begin
          sortFlag := pSortFlags[i];
          if sortFlag <> 0 then begin
            descBit  := i32(sortFlag) and BT_KEYINFO_ORDER_DESC;
            nullSide := 0;
            if (serial_type = 0)
               or ((pRhs^.flags and BT_MEM_Null) <> 0) then
              nullSide := 1;
            if ((sortFlag and BT_KEYINFO_ORDER_BIGNULL) = 0)
               or (descBit <> nullSide) then
              rc := -rc;
          end;
        end;
      end;
      Result := rc;
      Exit;
    end;

    Inc(i);
    if i = i32(pIdxKey^.nField) then break;
    { Step pRhs by the actual TMem stride (vdbe.pas TMem = 56 bytes), NOT
      by SizeOf(TBtMemView)=23 — the latter would land in the middle of
      the next Mem cell and read garbage flags, silently returning rc=0
      for every multi-key compare whose first key is equal. }
    pRhs := PBtMemView(PByte(pRhs) + BT_MEM_STRIDE);
    d1 := d1 + btreeSerialTypeLen(serial_type);
    if d1 > u32(nKey1) then break;
    if aKey1[idx1] < $80 then
      Inc(idx1)
    else begin
      vTmp32 := sqlite3GetVarint32(@aKey1[idx1], serial_type);
      Inc(idx1, vTmp32);
    end;
    if idx1 >= szHdr1 then begin
      Result := 0;
      Exit;
    end;
  end;

  pIdxKey^.eqSeen := 1;
  Result := pIdxKey^.default_rc;
end;

{ ---------------------------------------------------------------------------
  vdbeRecordCompareInt — specialised comparator for single-leading-integer
  keys.  Port of vdbeaux.c:4971..5058 (sqlite3VdbeRecordCompareInt).  Used
  via sqlite3VdbeFindCompare when the first key field is an integer.
  --------------------------------------------------------------------------- }
function vdbeRecordCompareInt(nKey1: i32; pKey1: Pointer;
                              pPKey2: PUnpackedRecord): i32;
var
  aKey:        Pu8;
  serial_type: i32;
  y:           u32;
  x:           u64;
  v, lhs:      i64;
  pRhs:        PBtMemView;
begin
  aKey := Pu8(pKey1);
  { *(const u8*)pKey1 & 0x3F  is the szHdr (header always single-byte here) }
  aKey := Pu8(PByte(pKey1) + (aKey[0] and $3F));
  serial_type := i32(Pu8(pKey1)[1]);
  case serial_type of
    1: { 1-byte signed int }
      lhs := i64(i8(aKey[0]));
    2: { 2-byte signed int }
      lhs := i64(i16((u16(aKey[0]) shl 8) or u16(aKey[1])));
    3: { 3-byte signed int }
      begin
        y := (u32(aKey[0]) shl 16) or (u32(aKey[1]) shl 8) or u32(aKey[2]);
        if (y and $00800000) <> 0 then y := y or $FF000000;
        lhs := i64(i32(y));
      end;
    4: { 4-byte signed int }
      begin
        y := (u32(aKey[0]) shl 24) or (u32(aKey[1]) shl 16)
          or (u32(aKey[2]) shl 8)  or  u32(aKey[3]);
        lhs := i64(i32(y));
      end;
    5: { 6-byte signed int }
      begin
        lhs := (i64((u32(aKey[2]) shl 24) or (u32(aKey[3]) shl 16)
                  or (u32(aKey[4]) shl 8)  or  u32(aKey[5])) and i64($FFFFFFFF))
             + (i64(i16((u16(aKey[0]) shl 8) or u16(aKey[1]))) shl 32);
      end;
    6: { 8-byte signed int }
      begin
        x := (u64(aKey[0]) shl 56) or (u64(aKey[1]) shl 48)
          or (u64(aKey[2]) shl 40) or (u64(aKey[3]) shl 32)
          or (u64(aKey[4]) shl 24) or (u64(aKey[5]) shl 16)
          or (u64(aKey[6]) shl 8)  or  u64(aKey[7]);
        lhs := i64(x);
      end;
    8: lhs := 0;
    9: lhs := 1;
  else
    { Cases 0/7 and >9: fall back to generic comparator (handles NULL,
      REAL, TEXT, BLOB at column 0). }
    Result := sqlite3VdbeRecordCompare(nKey1, pKey1, pPKey2);
    Exit;
  end;

  pRhs := PBtMemView(pPKey2^.aMem);
  v := pRhs^.u_i;  { pPKey2->u.i == pPKey2->aMem[0].u.i (asserted in C) }
  if v > lhs then
    Result := pPKey2^.r1
  else if v < lhs then
    Result := pPKey2^.r2
  else begin
    { First fields equal — fall back to generic for trailing-field compare
      (Pas merged WithSkip into the generic comparator; we lose only the
      bSkip=1 micro-optimisation, correctness is preserved because the
      first-int comparison will yield 0 again and the generic walks on). }
    if pPKey2^.nField > 1 then
      Result := sqlite3VdbeRecordCompare(nKey1, pKey1, pPKey2)
    else begin
      Result := pPKey2^.default_rc;
      pPKey2^.eqSeen := 1;
    end;
  end;
end;

{ ---------------------------------------------------------------------------
  vdbeRecordCompareString — specialised comparator for single-leading-BINARY
  string keys.  Port of vdbeaux.c:5066..5129 (sqlite3VdbeRecordCompareString).
  --------------------------------------------------------------------------- }
function vdbeRecordCompareString(nKey1: i32; pKey1: Pointer;
                                 pPKey2: PUnpackedRecord): i32;
var
  aKey1:       Pu8;
  serial_type: i32;
  res:         i32;
  nCmp, nStr: i32;
  szHdr:       i32;
  vTmp32:      u32;
  c:           i32;
begin
  aKey1 := Pu8(pKey1);
  serial_type := i32(i8(aKey1[1]));   { signed: negative => multibyte varint }

  { Inlined vrcs_restart loop: re-fetch the serial_type as an unsigned
    varint if the signed byte was negative; if the decoded type is still
    < 12 here it's a number/NULL (CORRUPT_DB caveat per C). }
  if (serial_type < 0) then begin
    sqlite3GetVarint32(@aKey1[1], vTmp32);
    serial_type := i32(vTmp32);
  end;

  if serial_type < 12 then begin
    res := pPKey2^.r1;  { (pKey1) is a number or NULL — sorts before strings }
  end
  else if (serial_type and 1) = 0 then begin
    res := pPKey2^.r2;  { (pKey1) is a blob — sorts after strings }
  end
  else begin
    szHdr := i32(aKey1[0]);
    nStr  := (serial_type - 12) div 2;
    if (szHdr + nStr) > nKey1 then begin
      pPKey2^.errCode := SQLITE_CORRUPT_BKPT;
      Result := 0;
      Exit;
    end;
    if pPKey2^.n < nStr then nCmp := pPKey2^.n else nCmp := nStr;
    if nCmp > 0 then
      c := CompareByte((@aKey1[szHdr])^, pPKey2^.u.z^, nCmp)
    else
      c := 0;
    if c > 0 then
      res := pPKey2^.r2
    else if c < 0 then
      res := pPKey2^.r1
    else begin
      res := nStr - pPKey2^.n;
      if res = 0 then begin
        if pPKey2^.nField > 1 then
          { No WithSkip in Pas — generic re-compares col 0 (same string,
            yields 0) then proceeds to trailing fields.  Correct, slightly
            slower than C's bSkip=1 path. }
          res := sqlite3VdbeRecordCompare(nKey1, pKey1, pPKey2)
        else begin
          res := pPKey2^.default_rc;
          pPKey2^.eqSeen := 1;
        end;
      end
      else if res > 0 then
        res := pPKey2^.r2
      else
        res := pPKey2^.r1;
    end;
  end;
  Result := res;
end;

function sqlite3VdbeFindCompare(pIdxKey: PUnpackedRecord): TRecordCompare;
const
  BT_KEYINFO_ORDER_DESC    = 1;
  BT_KEYINFO_ORDER_BIGNULL = 2;
var
  pKI:        PByte;
  nAllField:  u16;
  pSortFlags: Pu8;
  pAColl:     PPointer;
  pMem0:      PBtMemView;
  flags:      u16;
  sortFlag0:  u8;
begin
  pKI := PByte(pIdxKey^.pKeyInfo);
  if pKI = nil then begin
    Result := @sqlite3VdbeRecordCompare;
    Exit;
  end;
  { nAllField at offset 8 in TKeyInfo. }
  nAllField := PWord(pKI + 8)^;
  if nAllField <= 13 then begin
    pMem0 := PBtMemView(pIdxKey^.aMem);
    flags := pMem0^.flags;
    { aSortFlags Pu8 at offset 24 in TKeyInfo. }
    pSortFlags := Pu8(PPointer(pKI + 24)^);
    sortFlag0 := 0;
    if pSortFlags <> nil then sortFlag0 := pSortFlags[0];
    if sortFlag0 <> 0 then begin
      if (sortFlag0 and BT_KEYINFO_ORDER_BIGNULL) <> 0 then begin
        Result := @sqlite3VdbeRecordCompare;
        Exit;
      end;
      pIdxKey^.r1 :=  1;
      pIdxKey^.r2 := -1;
    end
    else begin
      pIdxKey^.r1 := -1;
      pIdxKey^.r2 :=  1;
    end;

    if (flags and BT_MEM_Int) <> 0 then begin
      pIdxKey^.u.i := pMem0^.u_i;
      Result := @vdbeRecordCompareInt;
      Exit;
    end;

    { aColl[0] lives at offset 32 (after TKeyInfo struct).  BINARY = nil. }
    pAColl := PPointer(pKI + 32);
    if ((flags and (BT_MEM_Real or BT_MEM_IntReal
                    or BT_MEM_Null or BT_MEM_Blob)) = 0)
       and (pAColl[0] = nil) then begin
      { flags & MEM_Str asserted by elimination. }
      pIdxKey^.u.z := pMem0^.z;
      pIdxKey^.n   := pMem0^.n;
      Result := @vdbeRecordCompareString;
      Exit;
    end;
  end;

  Result := @sqlite3VdbeRecordCompare;
end;

{ ---------------------------------------------------------------------------
  indexCellCompare helper (internal)
  btree.c lines 5955-5991
  --------------------------------------------------------------------------- }
function indexCellCompare(pPage: PMemPage; idx: i32;
                          pIdxKey: PUnpackedRecord;
                          xRecordCompare: TRecordCompare): i32;
var
  c    : i32;
  nCell: i32;
  pCell: Pu8;
begin
  pCell := findCellPastPtr(pPage, idx);
  nCell := pCell[0];
  if nCell <= pPage^.max1bytePayload then begin
    c := xRecordCompare(nCell, pCell + 1, pIdxKey);
  end else if pCell[1] and $80 = 0 then begin
    nCell := ((nCell and $7F) shl 7) + pCell[1];
    if nCell <= pPage^.maxLocal then
      c := xRecordCompare(nCell, pCell + 2, pIdxKey)
    else
      c := 99;
  end else begin
    c := 99;
  end;
  Result := c;
end;

{ ---------------------------------------------------------------------------
  cursorOnLastPage helper (internal)
  btree.c lines 5994-6001
  --------------------------------------------------------------------------- }
function cursorOnLastPage(pCur: PBtCursor): i32;
var
  i    : i32;
  pPage: PMemPage;
begin
  for i := 0 to pCur^.iPage - 1 do begin
    pPage := pCur^.apPage[i];
    if pCur^.aiIdx[i] < pPage^.nCell then begin
      Result := 0;
      Exit;
    end;
  end;
  Result := 1;
end;

{ ---------------------------------------------------------------------------
  sqlite3BtreeIndexMoveto  (index B-tree binary search)
  btree.c lines 6024-6255
  --------------------------------------------------------------------------- }
function sqlite3BtreeIndexMoveto(pCur: PBtCursor; pIdxKey: PUnpackedRecord;
                                  pRes: Pi32): i32;
var
  rc            : i32;
  xRecordCompare: TRecordCompare;
  lwr, upr, idx, c: i32;
  chldPg        : Pgno;
  pPage         : PMemPage;
  pCell         : Pu8;
  nCell         : i32;
  pCellKey      : Pointer;
  pCellBody     : Pu8;
  nOverrun      : i32;
  bOvfl         : Boolean;
  { 12.2.candidate.3: cache hot pPage^ fields in locals; refreshed each
    outer iteration immediately after pPage := pCur^.pPage. }
  aData   : Pu8;
  aDataO  : Pu8;
  aCellI  : Pu8;
  mskPage : u16;
label
  bypass_moveto_root, moveto_index_finish;
begin
  rc := SQLITE_OK;
  nOverrun := 18;

  if pIdxKey = nil then begin
    { Should not happen: IndexMoveto always gets a key }
    Result := SQLITE_MISUSE;
    Exit;
  end;

  xRecordCompare := sqlite3VdbeFindCompare(pIdxKey);
  if xRecordCompare = nil then begin
    { Phase 6 not yet ported: fall through with a stub that always says "equal" }
    pRes^ := 0;
    Result := SQLITE_OK;
    Exit;
  end;

  { Skip-to-root optimization — mirrors btree.c:6049..6083.
    Two cases:
      (1) cursor is at the *last cell* of the table and pIdxKey >= that
          cell — no movement required.
      (2) cursor is below root and the *first cell* of the current page
          is <= pIdxKey — start the search on the current page rather
          than walking back up to the root.
    The previous Pas port collapsed (1) into "compare against current ix"
    which was wrong: the seek key may sort *after* the current cell yet
    still appear later on the same page.  See tasklist 6.IPK-IN.f. }
  if (pCur^.eState = CURSOR_VALID) and (pCur^.pPage^.leaf <> 0) and
     (cursorOnLastPage(pCur) <> 0) then begin
    if pCur^.ix = u16(pCur^.pPage^.nCell - 1) then begin
      c := indexCellCompare(pCur^.pPage, pCur^.ix, pIdxKey, xRecordCompare);
      if c <= 0 then begin
        pRes^ := c;
        Result := SQLITE_OK;
        Exit;
      end;
    end;
    if pCur^.iPage > 0 then begin
      c := indexCellCompare(pCur^.pPage, 0, pIdxKey, xRecordCompare);
      if c <= 0 then begin
        pCur^.curFlags := pCur^.curFlags and (not (BTCF_ValidOvfl or BTCF_AtLast));
        if pCur^.pPage^.isInit = 0 then begin
          Result := SQLITE_CORRUPT_BKPT;
          Exit;
        end;
        goto bypass_moveto_root;
      end;
    end;
  end;

  rc := moveToRoot(pCur);
  if rc <> SQLITE_OK then begin
    if rc = SQLITE_EMPTY then begin
      pRes^ := -1;
      Result := SQLITE_OK;
    end else
      Result := rc;
    Exit;
  end;

bypass_moveto_root:
  c := 0;
  while True do begin
    pPage := pCur^.pPage;
    { Refresh cached locals — pPage may change when descending into a child. }
    aData   := pPage^.aData;
    aDataO  := pPage^.aDataOfst;
    aCellI  := pPage^.aCellIdx;
    mskPage := pPage^.maskPage;
    lwr := 0;
    upr := pPage^.nCell - 1;
    idx := upr shr 1;

    while True do begin
      { Inlined findCellPastPtr(pPage, idx) using cached locals. }
      pCell := aDataO + (mskPage and u16(get2byteAligned(aCellI + 2*idx)));
      nCell := pCell[0];
      bOvfl := False;
      if nCell <= pPage^.max1bytePayload then begin
        c := xRecordCompare(nCell, pCell + 1, pIdxKey);
      end else if pCell[1] and $80 = 0 then begin
        nCell := ((nCell and $7F) shl 7) + pCell[1];
        if nCell <= pPage^.maxLocal then
          c := xRecordCompare(nCell, pCell + 2, pIdxKey)
        else
          bOvfl := True;
      end else
        bOvfl := True;
      if bOvfl then begin
        { Overflow cell — need to fetch full key }
        pCellBody := pCell - pPage^.childPtrSize;
        pPage^.xParseCell(pPage, pCellBody, @pCur^.info);
        nCell := i32(pCur^.info.nKey);
        if (nCell < 2) or
           (u32(nCell) div pCur^.pBt^.usableSize > pCur^.pBt^.nPage) then begin
          rc := CORRUPT_PAGE(pPage);
          goto moveto_index_finish;
        end;
        pCellKey := sqlite3Malloc(u64(nCell) + u64(nOverrun));
        if pCellKey = nil then begin
          rc := SQLITE_NOMEM_BKPT;
          goto moveto_index_finish;
        end;
        pCur^.ix := u16(idx);
        rc := accessPayload(pCur, 0, u32(nCell), Pu8(pCellKey), 0);
        FillChar((Pu8(pCellKey) + nCell)^, nOverrun, 0);
        pCur^.curFlags := pCur^.curFlags and (not BTCF_ValidOvfl);
        if rc <> SQLITE_OK then begin
          sqlite3_free(pCellKey);
          goto moveto_index_finish;
        end;
        c := sqlite3VdbeRecordCompare(nCell, pCellKey, pIdxKey);
        sqlite3_free(pCellKey);
      end;

      if c < 0 then begin
        lwr := idx + 1;
      end else if c > 0 then begin
        upr := idx - 1;
      end else begin
        pRes^ := 0;
        rc := SQLITE_OK;
        pCur^.ix := u16(idx);
        goto moveto_index_finish;
      end;
      if lwr > upr then break;
      idx := (lwr + upr) shr 1;
    end;

    if pPage^.leaf <> 0 then begin
      pCur^.ix := u16(idx);
      pRes^ := c;
      rc := SQLITE_OK;
      goto moveto_index_finish;
    end;

    if lwr >= pPage^.nCell then
      chldPg := get4byte(aData + pPage^.hdrOffset + 8)
    else
      { Inlined findCell(pPage, lwr) using cached locals. }
      chldPg := get4byte(aData + (mskPage and u16(get2byteAligned(aCellI + 2*lwr))));

    pCur^.info.nSize := 0;
    pCur^.curFlags := pCur^.curFlags and (not (BTCF_ValidNKey or BTCF_ValidOvfl));
    if pCur^.iPage >= (BTCURSOR_MAX_DEPTH - 1) then begin
      rc := SQLITE_CORRUPT_BKPT;
      goto moveto_index_finish;
    end;
    pCur^.aiIdx[pCur^.iPage] := u16(lwr);
    pCur^.apPage[pCur^.iPage] := pCur^.pPage;
    pCur^.ix := 0;
    Inc(pCur^.iPage);
    rc := getAndInitPage(pCur^.pBt, chldPg, pCur^.pPage, pCur^.curPagerFlags);
    if rc = SQLITE_OK then begin
      if (pCur^.pPage^.nCell < 1) or
         (pCur^.pPage^.intKey <> pCur^.curIntKey) then begin
        releasePage(pCur^.pPage);
        rc := SQLITE_CORRUPT_BKPT;
      end;
    end;
    if rc <> SQLITE_OK then begin
      Dec(pCur^.iPage);
      pCur^.pPage := pCur^.apPage[pCur^.iPage];
      goto moveto_index_finish;
    end;
  end;

moveto_index_finish:
  pCur^.info.nSize := 0;
  pCur^.curFlags := pCur^.curFlags and (not BTCF_ValidOvfl);
  Result := rc;
end;

{ ---------------------------------------------------------------------------
  btreeMoveto  (used by btreeRestoreCursorPosition)
  btree.c lines 858-889
  --------------------------------------------------------------------------- }
function btreeMoveto(pCur: PBtCursor; pKey: Pointer; nKey: i64;
                     bias: i32; pRes: Pi32): i32;
begin
  if pKey <> nil then begin
    { Index cursor: delegate to vdbe.pas via hook (port of btree.c:858..889
      index-cursor arm, which calls sqlite3VdbeAllocUnpackedRecord +
      sqlite3VdbeRecordUnpack + sqlite3BtreeIndexMoveto). }
    if btreeMovetoIndexHook <> nil then
      Result := btreeMovetoIndexHook(pCur, pKey, nKey, pRes)
    else
      Result := SQLITE_INTERNAL;
  end else begin
    Result := sqlite3BtreeTableMoveto(pCur, nKey, bias, pRes);
  end;
end;

{ ---------------------------------------------------------------------------
  btreeNext / sqlite3BtreeNext
  btree.c lines 6315-6395
  --------------------------------------------------------------------------- }
function btreeNext(pCur: PBtCursor): i32;
var
  rc   : i32;
  idx  : i32;
  pPage: PMemPage;
begin
  if pCur^.eState <> CURSOR_VALID then begin
    rc := restoreCursorPosition(pCur);
    if rc <> SQLITE_OK then begin
      Result := rc;
      Exit;
    end;
    if pCur^.eState = CURSOR_INVALID then begin
      Result := SQLITE_DONE;
      Exit;
    end;
    if pCur^.eState = CURSOR_SKIPNEXT then begin
      pCur^.eState := CURSOR_VALID;
      if pCur^.skipNext > 0 then begin
        Result := SQLITE_OK;
        Exit;
      end;
    end;
  end;

  pPage := pCur^.pPage;
  idx := pCur^.ix + 1;
  pCur^.ix := u16(idx);

  if idx >= pPage^.nCell then begin
    if pPage^.leaf = 0 then begin
      { Interior page: descend to leftmost child of right-side subtree }
      rc := moveToChild(pCur,
        get4byte(pPage^.aData + pPage^.hdrOffset + 8));
      if rc <> SQLITE_OK then begin Result := rc; Exit; end;
      Result := moveToLeftmost(pCur);
      Exit;
    end;
    { Leaf page: walk up until we find an unvisited parent cell }
    repeat
      if pCur^.iPage = 0 then begin
        pCur^.eState := CURSOR_INVALID;
        Result := SQLITE_DONE;
        Exit;
      end;
      moveToParent(pCur);
      pPage := pCur^.pPage;
    until pCur^.ix < pPage^.nCell;
    if pPage^.intKey <> 0 then begin
      Result := sqlite3BtreeNext(pCur, 0);
      Exit;
    end else begin
      Result := SQLITE_OK;
      Exit;
    end;
  end;
  if pPage^.leaf <> 0 then
    Result := SQLITE_OK
  else
    Result := moveToLeftmost(pCur);
end;

function sqlite3BtreeNext(pCur: PBtCursor; flags: i32): i32;
var
  pPage: PMemPage;
begin
  pCur^.info.nSize := 0;
  pCur^.curFlags := pCur^.curFlags and (not (BTCF_ValidNKey or BTCF_ValidOvfl));
  if pCur^.eState <> CURSOR_VALID then begin
    Result := btreeNext(pCur);
    Exit;
  end;
  pPage := pCur^.pPage;
  if pCur^.ix + 1 >= pPage^.nCell then begin
    { Undo the pre-increment btreeNext will do }
    Result := btreeNext(pCur);
    Exit;
  end;
  Inc(pCur^.ix);
  if pPage^.leaf <> 0 then
    Result := SQLITE_OK
  else
    Result := moveToLeftmost(pCur);
end;

{ ---------------------------------------------------------------------------
  btreePrevious / sqlite3BtreePrevious
  btree.c lines 6409-6480
  --------------------------------------------------------------------------- }
function btreePrevious(pCur: PBtCursor): i32;
var
  rc   : i32;
  pPage: PMemPage;
begin
  if pCur^.eState <> CURSOR_VALID then begin
    rc := restoreCursorPosition(pCur);
    if rc <> SQLITE_OK then begin
      Result := rc;
      Exit;
    end;
    if pCur^.eState = CURSOR_INVALID then begin
      Result := SQLITE_DONE;
      Exit;
    end;
    if pCur^.eState = CURSOR_SKIPNEXT then begin
      pCur^.eState := CURSOR_VALID;
      if pCur^.skipNext < 0 then begin
        Result := SQLITE_OK;
        Exit;
      end;
    end;
  end;

  pPage := pCur^.pPage;
  if pPage^.leaf = 0 then begin
    { Interior page: move to rightmost of left child }
    rc := moveToChild(pCur, get4byte(findCell(pPage, pCur^.ix)));
    if rc <> SQLITE_OK then begin Result := rc; Exit; end;
    Result := moveToRightmost(pCur);
  end else begin
    { Leaf page: walk up until we find a parent cell to back up to }
    while pCur^.ix = 0 do begin
      if pCur^.iPage = 0 then begin
        pCur^.eState := CURSOR_INVALID;
        Result := SQLITE_DONE;
        Exit;
      end;
      moveToParent(pCur);
    end;
    pCur^.info.nSize := 0;
    pCur^.curFlags := pCur^.curFlags and (not BTCF_ValidOvfl);
    Dec(pCur^.ix);
    pPage := pCur^.pPage;
    if (pPage^.intKey <> 0) and (pPage^.leaf = 0) then
      Result := sqlite3BtreePrevious(pCur, 0)
    else
      Result := SQLITE_OK;
  end;
end;

function sqlite3BtreePrevious(pCur: PBtCursor; flags: i32): i32;
begin
  pCur^.curFlags := pCur^.curFlags and
    (not (BTCF_AtLast or BTCF_ValidOvfl or BTCF_ValidNKey));
  pCur^.info.nSize := 0;
  if (pCur^.eState <> CURSOR_VALID) or (pCur^.ix = 0) or
     (pCur^.pPage^.leaf = 0) then begin
    Result := btreePrevious(pCur);
    Exit;
  end;
  Dec(pCur^.ix);
  Result := SQLITE_OK;
end;

{ ===========================================================================
  Phase 4.3 — Insert path implementation
  btree.c functions: btreeSetHasContent, btreeGetHasContent, btreeClearHasContent,
  saveCursorsOnList, saveAllCursors, invalidateIncrblobCursors, btreeGetUnusedPage,
  allocateBtreePage, freePage2, freePage, clearCellOverflow, fillInCell,
  CellArray helpers, rebuildPage, pageInsertArray, pageFreeArray, editPage,
  balance_quick, copyNodeContent, balance_nonroot, balance_deeper,
  anotherValidCursor, balance, btreeOverwriteContent, btreeOverwriteOverflowCell,
  btreeOverwriteCell, sqlite3BtreeInsert
  =========================================================================== }

{ ---------------------------------------------------------------------------
  Inline helpers equivalent to C macros
  --------------------------------------------------------------------------- }

{ PENDING_BYTE_PAGE(pBt) = (PENDING_BYTE / pBt^.pageSize) + 1 }
function PENDING_BYTE_PAGE(pBt: PBtShared): Pgno; inline;
begin
  Result := Pgno(PENDING_BYTE div pBt^.pageSize) + 1;
end;

{ ISAUTOVACUUM — always 0 in this port (no auto-vacuum) }
function ISAUTOVACUUM(pBt: PBtShared): Boolean; inline;
begin
  Result := pBt^.autoVacuum <> 0;
end;

{ SQLITE_WITHIN(P,S,E) — is pointer P in [S..E) ? }
function SQLITE_WITHIN(P, S, E: Pointer): Boolean; inline;
begin
  Result := (PtrUInt(P) >= PtrUInt(S)) and (PtrUInt(P) < PtrUInt(E));
end;

{ SQLITE_OVERFLOW(P,S,E) — does [S..E) span across P? }
function SQLITE_OVERFLOW_CHK(P, S, E: Pointer): Boolean; inline;
begin
  Result := (PtrUInt(S) < PtrUInt(P)) and (PtrUInt(E) > PtrUInt(P));
end;

{ putVarint32: fast path — if v < 0x80 write 1 byte, else full varint }
function putVarint32(p: Pu8; v: u32): i32; inline;
begin
  if v < $80 then begin
    p[0] := u8(v);
    Result := 1;
  end else
    Result := sqlite3PutVarint(p, v);
end;

{ getVarint32: fast path — if first byte < 0x80 read 1 byte, else full }
function getVarint32(p: Pu8; out v: u32): u8; inline;
begin
  if p[0] < $80 then begin
    v := p[0];
    Result := 1;
  end else
    Result := sqlite3GetVarint32(p, v);
end;

{ sqlite3StackAllocRaw / sqlite3StackFree — just heap alloc (no VdbeStack) }
function sqlite3StackAllocRaw(db: Pointer; sz: u64): Pointer;
begin
  Result := sqlite3Malloc(i32(sz));
end;

procedure sqlite3StackFree(db: Pointer; p: Pointer);
begin
  sqlite3_free(p);
end;

{ sqlite3AbsInt32 — absolute value of i32 }
function sqlite3AbsInt32(x: i32): i32; inline;
begin
  if x < 0 then Result := -x else Result := x;
end;

{ sqlite3PagerRekey — change page number in the page cache }
procedure sqlite3PagerRekey(pPg: PDbPage; iNew: Pgno; flags: u16);
begin
  pPg^.flags := flags;
  sqlite3PcacheMove(pPg, iNew);
end;

{ ---------------------------------------------------------------------------
  Auto-vacuum / pointer-map core (btree.c:1036..1148)

  ptrmapPageno   — btree.c:1036..1048 — pointer-map page index for `pgno`.
  ptrmapPut      — btree.c:1060..1110 — write/refresh a ptrmap entry.
  ptrmapGet      — btree.c:1119..1148 — read a ptrmap entry.
  --------------------------------------------------------------------------- }

{ ptrmapPageno — btree.c:1036..1048.  Return the page number of the
  pointer-map page containing the entry for input page `pg`.  Returns 0
  for pg<2 (no ptrmap entry for the header page or page 0). }
function ptrmapPageno(pBt: PBtShared; pg: Pgno): Pgno;
var
  nPagesPerMapPage: i32;
  iPtrMap, ret: Pgno;
begin
  if pg < 2 then begin
    Result := 0;
    Exit;
  end;
  nPagesPerMapPage := i32(pBt^.usableSize div 5) + 1;
  iPtrMap := (pg - 2) div Pgno(nPagesPerMapPage);
  ret := iPtrMap * Pgno(nPagesPerMapPage) + 2;
  if ret = PENDING_BYTE_PAGE(pBt) then
    Inc(ret);
  Result := ret;
end;

{ PTRMAP_PTROFFSET — btree.c #define: 5*(key-ptrmap-2).  Returns -1 when
  `key` itself happens to be a ptrmap page (caller treats as corruption). }
function PTRMAP_PTROFFSET(iPtrmap, key: Pgno): i32; inline;
begin
  if key = iPtrmap then Result := -1
  else Result := i32((key - iPtrmap - 1)) * 5;
end;

{ ptrmapPut — btree.c:1060..1110 }
procedure ptrmapPut(pBt: PBtShared; key: Pgno; eType: u8; parent: Pgno;
                    pRC: Pi32);
var
  pDbPg  : PDbPage;       { btree.c:1061 — the pointer map page }
  pPtrmap: Pu8;            { btree.c:1062 — pointer map data }
  iPtrmap: Pgno;           { btree.c:1063 — pointer map page number }
  offset: i32;             { btree.c:1064 — offset in pointer map page }
  rc: i32;                 { btree.c:1065 — return code from subfunctions }
begin
  if pRC^ <> SQLITE_OK then Exit;

  Assert(pBt^.autoVacuum <> 0);
  if key = 0 then begin
    pRC^ := SQLITE_CORRUPT_BKPT;
    Exit;
  end;
  iPtrmap := ptrmapPageno(pBt, key);
  rc := sqlite3PagerGet(pBt^.pPager, iPtrmap, @pDbPg, 0);
  if rc <> SQLITE_OK then begin
    pRC^ := rc;
    Exit;
  end;
  if PChar(sqlite3PagerGetExtra(pDbPg))[0] <> #0 then begin
    { btree.c:1084..1090 — first byte of extra data is MemPage.isInit; if
      it is set, the page is also being used as a btree page. }
    pRC^ := SQLITE_CORRUPT_BKPT;
    sqlite3PagerUnref(pDbPg);
    Exit;
  end;
  offset := PTRMAP_PTROFFSET(iPtrmap, key);
  if offset < 0 then begin
    pRC^ := SQLITE_CORRUPT_BKPT;
    sqlite3PagerUnref(pDbPg);
    Exit;
  end;
  Assert(offset <= i32(pBt^.usableSize) - 5);
  pPtrmap := Pu8(sqlite3PagerGetData(pDbPg));

  if (eType <> pPtrmap[offset]) or
     (get4byte(@pPtrmap[offset+1]) <> parent) then
  begin
    rc := sqlite3PagerWrite(pDbPg);
    pRC^ := rc;
    if rc = SQLITE_OK then begin
      pPtrmap[offset] := eType;
      put4byte(@pPtrmap[offset+1], parent);
    end;
  end;

  sqlite3PagerUnref(pDbPg);
end;

{ ptrmapGet — btree.c:1119..1148 }
function ptrmapGet(pBt: PBtShared; key: Pgno; out pEType: u8;
                   out pPgno: Pgno): i32;
var
  pDbPg  : PDbPage;        { btree.c:1120 }
  iPtrmap: Pgno;           { btree.c:1121 (i32 in C, but holds a Pgno) }
  pPtrmap: Pu8;            { btree.c:1122 }
  offset : i32;            { btree.c:1123 }
  rc     : i32;
begin
  pEType := 0;
  pPgno  := 0;
  iPtrmap := ptrmapPageno(pBt, key);
  rc := sqlite3PagerGet(pBt^.pPager, iPtrmap, @pDbPg, 0);
  if rc <> 0 then begin
    Result := rc;
    Exit;
  end;
  pPtrmap := Pu8(sqlite3PagerGetData(pDbPg));

  offset := PTRMAP_PTROFFSET(iPtrmap, key);
  if offset < 0 then begin
    sqlite3PagerUnref(pDbPg);
    Result := SQLITE_CORRUPT_BKPT;
    Exit;
  end;
  Assert(offset <= i32(pBt^.usableSize) - 5);
  pEType := pPtrmap[offset];
  pPgno  := get4byte(@pPtrmap[offset+1]);

  sqlite3PagerUnref(pDbPg);
  if (pEType < 1) or (pEType > 5) then begin
    Result := SQLITE_CORRUPT_BKPT;
    Exit;
  end;
  Result := SQLITE_OK;
end;

{ ===========================================================================
  ptrmapPutOvflPtr — btree.c lines 1582-1597
  The cell pCell is currently part of page pSrc but will ultimately be part
  of pPage.  If pCell contains a pointer to an overflow page, insert an
  entry into the pointer-map for that overflow page.
  =========================================================================== }
procedure ptrmapPutOvflPtr(pPage: PMemPage; pSrc: PMemPage; pCell: Pu8;
                           pRC: Pi32);
var
  info: TCellInfo;
  ovfl: Pgno;
begin
  if pRC^ <> SQLITE_OK then Exit;
  Assert(pCell <> nil);
  pPage^.xParseCell(pPage, pCell, @info);
  if info.nLocal < info.nPayload then begin
    if SQLITE_OVERFLOW_CHK(pSrc^.aDataEnd, pCell, pCell + info.nLocal) then begin
      pRC^ := SQLITE_CORRUPT_BKPT;
      Exit;
    end;
    ovfl := sqlite3Get4byte(pCell + info.nSize - 4);
    ptrmapPut(pPage^.pBt, ovfl, PTRMAP_OVERFLOW1, pPage^.pgno, pRC);
  end;
end;

{ setChildPtrmaps — btree.c:3831..3860.
  Set the pointer-map entries for all children of page pPage.  Also, if
  pPage contains cells that point to overflow pages, set the pointer map
  entries for the overflow pages as well. }
function setChildPtrmaps(pPage: PMemPage): i32;
var
  i, nCell, rc: i32;
  pBt: PBtShared;
  pg: Pgno;
  pCell: Pu8;
  childPgno: Pgno;
begin
  pBt := pPage^.pBt;
  pg  := pPage^.pgno;

  if pPage^.isInit <> 0 then rc := SQLITE_OK
  else rc := btreeInitPage(pPage);
  if rc <> SQLITE_OK then begin
    Result := rc;
    Exit;
  end;
  nCell := pPage^.nCell;

  for i := 0 to nCell - 1 do begin
    pCell := findCell(pPage, i);

    ptrmapPutOvflPtr(pPage, pPage, pCell, @rc);

    if pPage^.leaf = 0 then begin
      childPgno := get4byte(pCell);
      ptrmapPut(pBt, childPgno, PTRMAP_BTREE, pg, @rc);
    end;
  end;

  if pPage^.leaf = 0 then begin
    childPgno := get4byte(@pPage^.aData[pPage^.hdrOffset + 8]);
    ptrmapPut(pBt, childPgno, PTRMAP_BTREE, pg, @rc);
  end;

  Result := rc;
end;

{ ===========================================================================
  modifyPagePointer / relocatePage — auto-vacuum page-relocation core
  btree.c lines 3862..4012

  modifyPagePointer: Somewhere on pPage is a pointer to page iFrom.  Modify
  this pointer so that it points to iTo.  Parameter eType describes the type
  of pointer to be modified (PTRMAP_BTREE / PTRMAP_OVERFLOW1 / PTRMAP_OVERFLOW2).

  relocatePage: Move the open database page pDbPage to location iFreePage in
  the database.  The pDbPage reference remains valid.

  Both are `static SQLITE_NOINLINE` in C; we mirror that by keeping them
  unit-local (no interface-section declaration).
  =========================================================================== }

{ modifyPagePointer — btree.c:3876..3928 }
function modifyPagePointer(pPage: PMemPage; iFrom, iTo: Pgno; eType: u8): i32;
var
  i, nCell, rc: i32;
  pCell: Pu8;
  info: TCellInfo;
begin
  { btree.c:3877..3878 — invariants }
  Assert(sqlite3PagerIswriteable(pPage^.pDbPage) <> 0);
  if eType = PTRMAP_OVERFLOW2 then begin
    { btree.c:3879..3884 — pointer always at first 4 bytes of overflow page }
    if get4byte(pPage^.aData) <> iFrom then begin
      Result := SQLITE_CORRUPT_BKPT;
      Exit;
    end;
    put4byte(pPage^.aData, iTo);
  end else begin
    { btree.c:3885..3925 — search cells for the pointer }
    if pPage^.isInit <> 0 then rc := SQLITE_OK
    else rc := btreeInitPage(pPage);
    if rc <> SQLITE_OK then begin
      Result := rc;
      Exit;
    end;
    nCell := pPage^.nCell;

    i := 0;
    while i < nCell do begin
      pCell := findCell(pPage, i);
      if eType = PTRMAP_OVERFLOW1 then begin
        { btree.c:3896..3907 }
        pPage^.xParseCell(pPage, pCell, @info);
        if info.nLocal < info.nPayload then begin
          if (pCell + info.nSize) > (pPage^.aData + pPage^.pBt^.usableSize) then begin
            Result := SQLITE_CORRUPT_BKPT;
            Exit;
          end;
          if iFrom = get4byte(pCell + info.nSize - 4) then begin
            put4byte(pCell + info.nSize - 4, iTo);
            Break;
          end;
        end;
      end else begin
        { btree.c:3908..3916 — PTRMAP_BTREE: pointer is first 4 bytes of cell }
        if (pCell + 4) > (pPage^.aData + pPage^.pBt^.usableSize) then begin
          Result := SQLITE_CORRUPT_BKPT;
          Exit;
        end;
        if get4byte(pCell) = iFrom then begin
          put4byte(pCell, iTo);
          Break;
        end;
      end;
      Inc(i);
    end;

    { btree.c:3919..3925 — pointer not in any cell; must be the rightmost-child
      pointer in the page header (PTRMAP_BTREE only). }
    if i = nCell then begin
      if (eType <> PTRMAP_BTREE) or
         (get4byte(pPage^.aData + pPage^.hdrOffset + 8) <> iFrom) then begin
        Result := SQLITE_CORRUPT_BKPT;
        Exit;
      end;
      put4byte(pPage^.aData + pPage^.hdrOffset + 8, iTo);
    end;
  end;
  Result := SQLITE_OK;
end;

{ relocatePage — btree.c:3940..4012 }
function relocatePage(pBt: PBtShared; pDbPage: PMemPage; eType: u8;
                      iPtrPage, iFreePage: Pgno; isCommit: i32): i32;
var
  pPtrPage: PMemPage;          { btree.c:3948 — page containing pointer to pDbPage }
  iDbPage: Pgno;
  pPgr: PPager;                { FPC: `pPager: PPager` collides; use pPgr }
  rc: i32;
  nextOvfl: Pgno;
begin
  iDbPage := pDbPage^.pgno;
  pPgr := pBt^.pPager;

  { btree.c:3953..3956 — invariants }
  Assert((eType = PTRMAP_OVERFLOW2) or (eType = PTRMAP_OVERFLOW1) or
         (eType = PTRMAP_BTREE) or (eType = PTRMAP_ROOTPAGE));
  Assert(pDbPage^.pBt = pBt);
  if iDbPage < 3 then begin
    Result := SQLITE_CORRUPT_BKPT;
    Exit;
  end;

  { btree.c:3959..3965 — move the page via pager }
  rc := sqlite3PagerMovepage(pPgr, pDbPage^.pDbPage, iFreePage, isCommit);
  if rc <> SQLITE_OK then begin
    Result := rc;
    Exit;
  end;
  pDbPage^.pgno := iFreePage;

  { btree.c:3968..3989 — fix ptrmap entries for pages reachable from pDbPage }
  if (eType = PTRMAP_BTREE) or (eType = PTRMAP_ROOTPAGE) then begin
    rc := setChildPtrmaps(pDbPage);
    if rc <> SQLITE_OK then begin
      Result := rc;
      Exit;
    end;
  end else begin
    nextOvfl := get4byte(pDbPage^.aData);
    if nextOvfl <> 0 then begin
      ptrmapPut(pBt, nextOvfl, PTRMAP_OVERFLOW2, iFreePage, @rc);
      if rc <> SQLITE_OK then begin
        Result := rc;
        Exit;
      end;
    end;
  end;

  { btree.c:3991..4010 — fix the database pointer on iPtrPage that pointed
    at iDbPage so it points at iFreePage; also update ptrmap for iPtrPage. }
  if eType <> PTRMAP_ROOTPAGE then begin
    rc := btreeGetPage(pBt, iPtrPage, pPtrPage, 0);
    if rc <> SQLITE_OK then begin
      Result := rc;
      Exit;
    end;
    rc := sqlite3PagerWrite(pPtrPage^.pDbPage);
    if rc <> SQLITE_OK then begin
      releasePage(pPtrPage);
      Result := rc;
      Exit;
    end;
    rc := modifyPagePointer(pPtrPage, iDbPage, iFreePage, eType);
    releasePage(pPtrPage);
    if rc = SQLITE_OK then
      ptrmapPut(pBt, iFreePage, eType, iPtrPage, @rc);
  end;
  Result := rc;
end;

{ ---------------------------------------------------------------------------
  btreeSetHasContent / btreeGetHasContent / btreeClearHasContent
  btree.c lines 651-685
  --------------------------------------------------------------------------- }

function btreeSetHasContent(pBt: PBtShared; pgno: Pgno): i32;
begin
  Result := SQLITE_OK;
  if pBt^.pHasContent = nil then begin
    pBt^.pHasContent := sqlite3BitvecCreate(pBt^.nPage);
    if pBt^.pHasContent = nil then begin
      Result := SQLITE_NOMEM_BKPT;
      Exit;
    end;
  end;
  if pgno <= sqlite3BitvecSize(pBt^.pHasContent) then
    Result := sqlite3BitvecSet(pBt^.pHasContent, pgno);
end;

function btreeGetHasContent(pBt: PBtShared; pgno: Pgno): Boolean;
var
  p: PBitvec;
begin
  p := pBt^.pHasContent;
  Result := (p <> nil) and
            ((pgno > sqlite3BitvecSize(p)) or
             (sqlite3BitvecTestNotNull(p, pgno) <> 0));
end;

procedure btreeClearHasContent(pBt: PBtShared);
begin
  sqlite3BitvecDestroy(pBt^.pHasContent);
  pBt^.pHasContent := nil;
end;

{ ---------------------------------------------------------------------------
  saveCursorsOnList / saveAllCursors
  btree.c lines 806-843
  --------------------------------------------------------------------------- }

function saveCursorsOnList(p: PBtCursor; iRoot: Pgno;
                            pExcept: PBtCursor): i32;
var
  rc: i32;
begin
  Result := SQLITE_OK;
  repeat
    if (p <> pExcept) and ((iRoot = 0) or (p^.pgnoRoot = iRoot)) then begin
      if (p^.eState = CURSOR_VALID) or (p^.eState = CURSOR_SKIPNEXT) then begin
        rc := saveCursorPosition(p);
        if rc <> SQLITE_OK then begin
          Result := rc;
          Exit;
        end;
      end else
        btreeReleaseAllCursorPages(p);
    end;
    p := p^.pNext;
  until p = nil;
end;

function saveAllCursors(pBt: PBtShared; iRoot: Pgno;
                         pExcept: PBtCursor): i32;
var
  p: PBtCursor;
begin
  p := pBt^.pCursor;
  while p <> nil do begin
    if (p <> pExcept) and ((iRoot = 0) or (p^.pgnoRoot = iRoot)) then
      Break;
    p := p^.pNext;
  end;
  if p <> nil then begin
    Result := saveCursorsOnList(p, iRoot, pExcept);
    Exit;
  end;
  if pExcept <> nil then
    pExcept^.curFlags := pExcept^.curFlags and (not BTCF_Multiple);
  Result := SQLITE_OK;
end;

{ invalidateIncrblobCursors — btree.c lines 591-609
  If argument isClearTable is true, set CURSOR_INVALID on every incrblob
  cursor open on any row within the table with root-page pgnoRoot.
  Otherwise, invalidate only those incrblob cursors open on the row with
  rowid iRow. }
procedure invalidateIncrblobCursors(p: PBtree; pgnoRoot: Pgno;
                                    iRow: i64; isClearTable: i32);
var
  pCur: PBtCursor;
begin
  Assert(p^.hasIncrblobCur <> 0);
  Assert(sqlite3BtreeHoldsMutex(p) <> 0);
  p^.hasIncrblobCur := 0;
  pCur := p^.pBt^.pCursor;
  while pCur <> nil do begin
    if (pCur^.curFlags and BTCF_Incrblob) <> 0 then begin
      p^.hasIncrblobCur := 1;
      if (pCur^.pgnoRoot = pgnoRoot)
         and ((isClearTable <> 0) or (pCur^.info.nKey = iRow)) then
        pCur^.eState := CURSOR_INVALID;
    end;
    pCur := pCur^.pNext;
  end;
end;

{ ---------------------------------------------------------------------------
  btreeGetUnusedPage
  btree.c lines 2449-2467
  --------------------------------------------------------------------------- }

function btreeGetUnusedPage(pBt: PBtShared; pgno: Pgno;
                             out ppPage: PMemPage; flags: i32): i32;
var
  rc: i32;
begin
  rc := btreeGetPage(pBt, pgno, ppPage, flags);
  if rc = SQLITE_OK then begin
    if sqlite3PcachePageRefcount(ppPage^.pDbPage) > 1 then begin
      releasePage(ppPage);
      ppPage := nil;
      Result := SQLITE_CORRUPT_BKPT;
      Exit;
    end;
    ppPage^.isInit := 0;
  end else
    ppPage := nil;
  Result := rc;
end;

{ ---------------------------------------------------------------------------
  allocateBtreePage
  btree.c lines 6499-6807
  --------------------------------------------------------------------------- }

function allocateBtreePage(pBt: PBtShared; out ppPage: PMemPage;
                            out pPgno: Pgno; nearby: Pgno; eMode: u8): i32;
var
  pPage1   : PMemPage;
  rc       : i32;
  n        : u32;
  k        : u32;
  pTrunk   : PMemPage;
  pPrevTrunk: PMemPage;
  mxPage   : Pgno;
  iTrunk   : Pgno;
  iPage    : Pgno;
  nSearch  : u32;
  closest  : u32;
  noContent: i32;
  bNoContent: i32;
  aData    : Pu8;
  i        : u32;
  dist, d2 : i32;
  iNewTrunk: Pgno;
  pNewTrunk: PMemPage;
  pPg      : PMemPage;
label
  end_allocate_page;
begin
  pTrunk    := nil;
  pPrevTrunk := nil;
  ppPage    := nil;
  pPgno     := 0;
  pPage1    := pBt^.pPage1;
  mxPage    := btreePagecount(pBt);
  n := sqlite3Get4byte(@pPage1^.aData[36]);
  if n >= mxPage then begin
    Result := SQLITE_CORRUPT_BKPT;
    Exit;
  end;

  rc := SQLITE_OK;
  if n > 0 then begin
    { Reuse a page from the freelist }
    nSearch := 0;
    rc := sqlite3PagerWrite(pPage1^.pDbPage);
    if rc <> SQLITE_OK then begin
      Result := rc;
      Exit;
    end;
    sqlite3Put4byte(@pPage1^.aData[36], n - 1);

    repeat
      pPrevTrunk := pTrunk;
      if pPrevTrunk <> nil then
        iTrunk := sqlite3Get4byte(@pPrevTrunk^.aData[0])
      else
        iTrunk := sqlite3Get4byte(@pPage1^.aData[32]);

      Inc(nSearch);
      if (iTrunk > mxPage) or (nSearch > n) then begin
        rc := SQLITE_CORRUPT_BKPT;
      end else
        rc := btreeGetUnusedPage(pBt, iTrunk, pTrunk, 0);

      if rc <> SQLITE_OK then begin
        pTrunk := nil;
        goto end_allocate_page;
      end;

      k := sqlite3Get4byte(@pTrunk^.aData[4]);
      if k = 0 then begin
        { Trunk has no leaves — use trunk page itself }
        rc := sqlite3PagerWrite(pTrunk^.pDbPage);
        if rc <> SQLITE_OK then
          goto end_allocate_page;
        pPgno := iTrunk;
        Move(pTrunk^.aData[0], pPage1^.aData[32], 4);
        ppPage := pTrunk;
        pTrunk := nil;
      end else if k > (pBt^.usableSize div 4 - 2) then begin
        rc := SQLITE_CORRUPT_BKPT;
        goto end_allocate_page;
      end else begin
        { Extract a leaf from trunk }
        aData := pTrunk^.aData;
        if nearby > 0 then begin
          closest := 0;
          if eMode = BTALLOC_LE then begin
            i := 0;
            while i < k do begin
              iPage := sqlite3Get4byte(@aData[8 + i * 4]);
              if iPage <= nearby then begin
                closest := i;
                Break;
              end;
              Inc(i);
            end;
          end else begin
            dist := sqlite3AbsInt32(i32(sqlite3Get4byte(@aData[8])) - i32(nearby));
            i := 1;
            while i < k do begin
              d2 := sqlite3AbsInt32(i32(sqlite3Get4byte(@aData[8 + i * 4])) - i32(nearby));
              if d2 < dist then begin
                closest := i;
                dist := d2;
              end;
              Inc(i);
            end;
          end;
        end else
          closest := 0;

        iPage := sqlite3Get4byte(@aData[8 + closest * 4]);
        if (iPage > mxPage) or (iPage < 2) then begin
          rc := SQLITE_CORRUPT_BKPT;
          goto end_allocate_page;
        end;
        pPgno := iPage;
        rc := sqlite3PagerWrite(pTrunk^.pDbPage);
        if rc <> SQLITE_OK then
          goto end_allocate_page;
        if closest < k - 1 then
          Move(aData[4 + k * 4], aData[8 + closest * 4], 4);
        sqlite3Put4byte(@aData[4], k - 1);
        if btreeGetHasContent(pBt, pPgno) then
          noContent := 0
        else
          noContent := PAGER_GET_NOCONTENT;
        rc := btreeGetUnusedPage(pBt, pPgno, ppPage, noContent);
        if rc = SQLITE_OK then begin
          rc := sqlite3PagerWrite(ppPage^.pDbPage);
          if rc <> SQLITE_OK then begin
            releasePage(ppPage);
            ppPage := nil;
          end;
        end;
      end;
      releasePage(pPrevTrunk);
      pPrevTrunk := nil;
    until True; { loop runs once when not searching; no searchList needed without autovacuum }
  end else begin
    { No free pages — extend the database }
    if pBt^.bDoTruncate <> 0 then
      bNoContent := 0
    else
      bNoContent := PAGER_GET_NOCONTENT;

    rc := sqlite3PagerWrite(pBt^.pPage1^.pDbPage);
    if rc <> SQLITE_OK then begin
      Result := rc;
      Exit;
    end;
    Inc(pBt^.nPage);
    if pBt^.nPage = PENDING_BYTE_PAGE(pBt) then
      Inc(pBt^.nPage);

    { btree.c:6764..6783 — if the newly-extended page is itself a
      pointer-map page, allocate two pages: the first becomes a fresh
      ptrmap page, the second is handed back to the caller. }
    if (pBt^.autoVacuum <> 0)
       and (ptrmapPageno(pBt, pBt^.nPage) = pBt^.nPage) then begin
      Assert(pBt^.nPage <> PENDING_BYTE_PAGE(pBt));
      pPg := nil;
      rc := btreeGetUnusedPage(pBt, pBt^.nPage, pPg, bNoContent);
      if rc = SQLITE_OK then begin
        rc := sqlite3PagerWrite(pPg^.pDbPage);
        releasePage(pPg);
      end;
      if rc <> SQLITE_OK then begin
        Result := rc;
        Exit;
      end;
      Inc(pBt^.nPage);
      if pBt^.nPage = PENDING_BYTE_PAGE(pBt) then
        Inc(pBt^.nPage);
    end;

    sqlite3Put4byte(@pBt^.pPage1^.aData[28], pBt^.nPage);
    pPgno := pBt^.nPage;
    rc := btreeGetUnusedPage(pBt, pPgno, ppPage, bNoContent);
    if rc <> SQLITE_OK then begin
      Result := rc;
      Exit;
    end;
    rc := sqlite3PagerWrite(ppPage^.pDbPage);
    if rc <> SQLITE_OK then begin
      releasePage(ppPage);
      ppPage := nil;
    end;
  end;

end_allocate_page:
  releasePage(pTrunk);
  releasePage(pPrevTrunk);
  Result := rc;
end;

{ ---------------------------------------------------------------------------
  freePage2 / freePage
  btree.c lines 6821-6959
  --------------------------------------------------------------------------- }

function freePage2(pBt: PBtShared; pMemPage: PMemPage; iPage: Pgno): i32;
var
  pTrunk  : PMemPage;
  iTrunk  : Pgno;
  pPage1  : PMemPage;
  pPage   : PMemPage;
  rc      : i32;
  nFree   : u32;
  nLeaf   : u32;
label
  freepage_out;
begin
  pTrunk := nil;
  pPage1 := pBt^.pPage1;
  pPage  := nil;
  rc     := SQLITE_OK;

  if (iPage < 2) or (iPage > pBt^.nPage) then begin
    Result := SQLITE_CORRUPT_BKPT;
    Exit;
  end;

  if pMemPage <> nil then begin
    pPage := pMemPage;
    sqlite3PagerRef(pPage^.pDbPage);
  end else
    pPage := btreePageLookup(pBt, iPage);

  { Increment free page count on page 1 }
  rc := sqlite3PagerWrite(pPage1^.pDbPage);
  if rc <> SQLITE_OK then goto freepage_out;
  nFree := sqlite3Get4byte(@pPage1^.aData[36]);
  sqlite3Put4byte(@pPage1^.aData[36], nFree + 1);

  if (pBt^.btsFlags and BTS_SECURE_DELETE) <> 0 then begin
    { Secure delete: zero the page }
    if (pPage = nil) then begin
      rc := btreeGetPage(pBt, iPage, pPage, 0);
      if rc <> SQLITE_OK then goto freepage_out;
    end;
    rc := sqlite3PagerWrite(pPage^.pDbPage);
    if rc <> SQLITE_OK then goto freepage_out;
    FillChar(pPage^.aData^, pBt^.pageSize, 0);
  end;

  { Auto-vacuum ptrmap update (no-op in this port) }
  if ISAUTOVACUUM(pBt) then begin
    ptrmapPut(pBt, iPage, PTRMAP_FREEPAGE, 0, @rc);
    if rc <> SQLITE_OK then goto freepage_out;
  end;

  { Add as leaf to existing trunk, or make a new trunk }
  if nFree <> 0 then begin
    iTrunk := sqlite3Get4byte(@pPage1^.aData[32]);
    if iTrunk > btreePagecount(pBt) then begin
      rc := SQLITE_CORRUPT_BKPT;
      goto freepage_out;
    end;
    rc := btreeGetPage(pBt, iTrunk, pTrunk, 0);
    if rc <> SQLITE_OK then goto freepage_out;
    nLeaf := sqlite3Get4byte(@pTrunk^.aData[4]);
    if nLeaf > (pBt^.usableSize div 4 - 2) then begin
      rc := SQLITE_CORRUPT_BKPT;
      goto freepage_out;
    end;
    if nLeaf < (pBt^.usableSize div 4 - 8) then begin
      { Room on trunk: add as leaf }
      rc := sqlite3PagerWrite(pTrunk^.pDbPage);
      if rc = SQLITE_OK then begin
        sqlite3Put4byte(@pTrunk^.aData[4], nLeaf + 1);
        sqlite3Put4byte(@pTrunk^.aData[8 + nLeaf * 4], iPage);
        if (pPage <> nil) and ((pBt^.btsFlags and BTS_SECURE_DELETE) = 0) then
          sqlite3PagerDontWrite(pPage^.pDbPage);
        rc := btreeSetHasContent(pBt, iPage);
      end;
      goto freepage_out;
    end;
  end else
    iTrunk := 0;

  { Make iPage the new trunk }
  if pPage = nil then begin
    rc := btreeGetPage(pBt, iPage, pPage, 0);
    if rc <> SQLITE_OK then goto freepage_out;
  end;
  rc := sqlite3PagerWrite(pPage^.pDbPage);
  if rc <> SQLITE_OK then goto freepage_out;
  sqlite3Put4byte(@pPage^.aData[0], iTrunk);
  sqlite3Put4byte(@pPage^.aData[4], 0);
  sqlite3Put4byte(@pPage1^.aData[32], iPage);

freepage_out:
  if pPage <> nil then
    pPage^.isInit := 0;
  releasePage(pPage);
  releasePage(pTrunk);
  Result := rc;
end;

procedure freePage(pPage: PMemPage; pRC: Pi32);
begin
  if pRC^ = SQLITE_OK then
    pRC^ := freePage2(pPage^.pBt, pPage, pPage^.pgno);
end;

{ ---------------------------------------------------------------------------
  clearCellOverflow — free overflow pages for a cell
  btree.c lines 6964-7030
  --------------------------------------------------------------------------- }

function clearCellOverflow(pPage: PMemPage; pCell: Pu8;
                            pInfo: PCellInfo): i32;
var
  pBt         : PBtShared;
  ovflPgno    : Pgno;
  rc          : i32;
  nOvfl       : i32;
  ovflPageSize: u32;
  iNext       : Pgno;
  pOvfl       : PMemPage;
begin
  pBt := pPage^.pBt;
  if PtrUInt(pCell + pInfo^.nSize) > PtrUInt(pPage^.aDataEnd) then begin
    Result := CORRUPT_PAGE(pPage);
    Exit;
  end;
  ovflPgno := sqlite3Get4byte(pCell + pInfo^.nSize - 4);
  ovflPageSize := pBt^.usableSize - 4;
  nOvfl := i32((u32(pInfo^.nPayload) - pInfo^.nLocal + ovflPageSize - 1)
               div ovflPageSize);
  Result := SQLITE_OK;
  while nOvfl > 0 do begin
    Dec(nOvfl);
    iNext := 0;
    pOvfl := nil;
    if (ovflPgno < 2) or (ovflPgno > btreePagecount(pBt)) then begin
      Result := SQLITE_CORRUPT_BKPT;
      Exit;
    end;
    if nOvfl > 0 then begin
      rc := getOverflowPage(pBt, ovflPgno, @pOvfl, @iNext);
      if rc <> SQLITE_OK then begin
        Result := rc;
        Exit;
      end;
    end;

    if pOvfl = nil then
      pOvfl := btreePageLookup(pBt, ovflPgno);
    if pOvfl <> nil then begin
      if sqlite3PcachePageRefcount(pOvfl^.pDbPage) <> 1 then
        rc := SQLITE_CORRUPT_BKPT
      else
        rc := freePage2(pBt, pOvfl, ovflPgno);
    end else
      rc := freePage2(pBt, nil, ovflPgno);

    if pOvfl <> nil then
      sqlite3PagerUnref(pOvfl^.pDbPage);
    if rc <> SQLITE_OK then begin
      Result := rc;
      Exit;
    end;
    ovflPgno := iNext;
  end;
end;

{ BTREE_CLEAR_CELL inline helper:
  parse cell, if overflow call clearCellOverflow, else rc = SQLITE_OK }
procedure BTREE_CLEAR_CELL(out rc: i32; pPage: PMemPage; pCell: Pu8;
                            out sInfo: TCellInfo);
begin
  pPage^.xParseCell(pPage, pCell, @sInfo);
  if sInfo.nLocal <> sInfo.nPayload then
    rc := clearCellOverflow(pPage, pCell, @sInfo)
  else
    rc := SQLITE_OK;
end;

{ ---------------------------------------------------------------------------
  fillInCell — fill cell buffer from a BtreePayload
  btree.c lines 7059-7242
  --------------------------------------------------------------------------- }

function fillInCell(pPage: PMemPage; pCell: Pu8;
                    const pX: PBtreePayload; out pnSize: i32): i32;
var
  nPayload   : i32;
  pSrc       : Pu8;
  nSrc, n    : i32;
  rc         : i32;
  mn         : i32;
  spaceLeft  : i32;
  pToRelease : PMemPage;
  pPrior     : Pu8;
  pPayload   : Pu8;
  pBt        : PBtShared;
  pgnoOvfl   : Pgno;
  nHeader    : i32;
  pOvfl      : PMemPage;
begin
  nHeader := pPage^.childPtrSize;
  if pPage^.intKey <> 0 then begin
    nPayload := pX^.nData + pX^.nZero;
    pSrc     := Pu8(pX^.pData);
    nSrc     := pX^.nData;
    nHeader  += putVarint32(pCell + nHeader, u32(nPayload));
    nHeader  += sqlite3PutVarint(pCell + nHeader, u64(pX^.nKey));
  end else begin
    nSrc     := i32(pX^.nKey);
    nPayload := nSrc;
    pSrc     := Pu8(pX^.pKey);
    nHeader  += putVarint32(pCell + nHeader, u32(nPayload));
  end;

  pPayload := pCell + nHeader;
  if nPayload <= i32(pPage^.maxLocal) then begin
    n := nHeader + nPayload;
    if n < 4 then begin
      n := 4;
      pPayload[nPayload] := 0;
    end;
    pnSize := n;
    Move(pSrc^, pPayload^, nSrc);
    FillChar((pPayload + nSrc)^, nPayload - nSrc, 0);
    Result := SQLITE_OK;
    Exit;
  end;

  { Payload spills onto overflow pages }
  mn        := i32(pPage^.minLocal);
  n         := mn + (nPayload - mn) mod i32(pPage^.pBt^.usableSize - 4);
  if n > i32(pPage^.maxLocal) then n := mn;
  spaceLeft := n;
  pnSize    := n + nHeader + 4;
  pPrior    := pCell + nHeader + n;
  pToRelease := nil;
  pgnoOvfl  := 0;
  pBt       := pPage^.pBt;

  while True do begin
    n := nPayload;
    if n > spaceLeft then n := spaceLeft;
    if nSrc >= n then
      Move(pSrc^, pPayload^, n)
    else if nSrc > 0 then begin
      n := nSrc;
      Move(pSrc^, pPayload^, n);
    end else
      FillChar(pPayload^, n, 0);
    Dec(nPayload, n);
    if nPayload <= 0 then Break;
    Inc(pPayload, n);
    Inc(pSrc, n);
    Dec(nSrc, n);
    Dec(spaceLeft, n);
    if spaceLeft = 0 then begin
      pOvfl  := nil;
      rc := allocateBtreePage(pBt, pOvfl, pgnoOvfl, pgnoOvfl, 0);
      if rc <> SQLITE_OK then begin
        releasePage(pToRelease);
        Result := rc;
        Exit;
      end;
      sqlite3Put4byte(pPrior, pgnoOvfl);
      releasePage(pToRelease);
      pToRelease := pOvfl;
      pPrior     := pOvfl^.aData;
      sqlite3Put4byte(pPrior, 0);
      pPayload   := pOvfl^.aData + 4;
      spaceLeft  := i32(pBt^.usableSize) - 4;
    end;
  end;
  releasePage(pToRelease);
  Result := SQLITE_OK;
end;

{ ---------------------------------------------------------------------------
  CellArray type (implementation-only; internal to balance routines)
  --------------------------------------------------------------------------- }

type
  PPu8 = ^Pu8;   { pointer to a Pu8 pointer }

  TCellArray = record
    nCell  : i32;                       { Number of cells }
    pRef   : PMemPage;                  { Reference page }
    apCell : PPu8;                      { Array of cell pointers }
    szCell : Pu16;                      { Array of cell sizes }
    apEnd  : array[0..NB*2-1] of Pu8;  { aDataEnd values }
    ixNx   : array[0..NB*2-1] of i32;  { Index boundary array }
  end;
  PCellArray = ^TCellArray;

{ ---------------------------------------------------------------------------
  populateCellCache / computeCellSize / cachedCellSize
  btree.c lines 7584-7614
  --------------------------------------------------------------------------- }

procedure populateCellCache(p: PCellArray; idx: i32; N: i32);
var
  pRef  : PMemPage;
  szCell: Pu16;
begin
  pRef   := p^.pRef;
  szCell := p^.szCell + idx;
  while N > 0 do begin
    if szCell^ = 0 then
      szCell^ := pRef^.xCellSize(pRef, (p^.apCell + idx)^);
    Inc(szCell);
    Inc(idx);
    Dec(N);
  end;
end;

function computeCellSize(p: PCellArray; N: i32): u16;
begin
  (p^.szCell + N)^ := p^.pRef^.xCellSize(p^.pRef, (p^.apCell + N)^);
  Result := (p^.szCell + N)^;
end;

function cachedCellSize(p: PCellArray; N: i32): u16; inline;
begin
  if (p^.szCell + N)^ <> 0 then
    Result := (p^.szCell + N)^
  else
    Result := computeCellSize(p, N);
end;

{ ---------------------------------------------------------------------------
  rebuildPage — rebuild page from cell array
  btree.c lines 7629-7696
  --------------------------------------------------------------------------- }

function rebuildPage(pCArray: PCellArray; iFirst: i32; nCell: i32;
                     pPg: PMemPage): i32;
var
  hdr        : i32;
  aData      : Pu8;
  usableSize : i32;
  pEnd       : Pu8;
  i, iEnd    : i32;
  pCellptr   : Pu8;
  pTmp       : Pu8;
  pData      : Pu8;
  k          : i32;
  pSrcEnd    : Pu8;
  pCell      : Pu8;
  sz         : u16;
  j          : u32;
begin
  hdr        := pPg^.hdrOffset;
  aData      := pPg^.aData;
  usableSize := i32(pPg^.pBt^.usableSize);
  pEnd       := aData + usableSize;
  i          := iFirst;
  iEnd       := i + nCell;
  pCellptr   := pPg^.aCellIdx;
  pTmp       := Pu8(sqlite3PagerTempSpace(pPg^.pBt^.pPager));

  j := get2byte(aData + hdr + 5);
  if j > u32(usableSize) then j := 0;
  Move((aData + j)^, (pTmp + j)^, usableSize - i32(j));

  { find starting apEnd bucket }
  k := 0;
  while pCArray^.ixNx[k] <= i do Inc(k);
  pSrcEnd := pCArray^.apEnd[k];

  pData := pEnd;
  while True do begin
    pCell := (pCArray^.apCell + i)^;
    sz    := (pCArray^.szCell + i)^;
    if SQLITE_WITHIN(pCell, aData + j, pEnd) then begin
      if PtrUInt(pCell + sz) > PtrUInt(pEnd) then begin
        Result := SQLITE_CORRUPT_BKPT;
        Exit;
      end;
      pCell := pTmp + (pCell - aData);
    end else if SQLITE_OVERFLOW_CHK(pEnd, pCell, pCell + sz) then begin
      Result := SQLITE_CORRUPT_BKPT;
      Exit;
    end;
    Dec(pData, sz);
    put2byte(pCellptr, i32(pData - aData));
    Inc(pCellptr, 2);
    if PtrUInt(pData) < PtrUInt(pCellptr) then begin
      Result := SQLITE_CORRUPT_BKPT;
      Exit;
    end;
    Move(pCell^, pData^, sz);
    Inc(i);
    if i >= iEnd then Break;
    if pCArray^.ixNx[k] <= i then begin
      Inc(k);
      pSrcEnd := pCArray^.apEnd[k];
    end;
  end;

  pPg^.nCell    := u16(nCell);
  pPg^.nOverflow := 0;
  put2byte(aData + hdr + 1, 0);
  put2byte(aData + hdr + 3, i32(pPg^.nCell));
  put2byte(aData + hdr + 5, i32(pData - aData));
  aData[hdr + 7] := 0;
  Result := SQLITE_OK;
end;

{ ---------------------------------------------------------------------------
  pageInsertArray — insert cells into page
  btree.c lines 7722-7777
  --------------------------------------------------------------------------- }

function pageInsertArray(pPg: PMemPage; pBegin: Pu8; var ppData: Pu8;
                          pCellptr: Pu8; iFirst: i32; nCell: i32;
                          pCArray: PCellArray): i32;
var
  i, iEnd, k : i32;
  aData, pEnd : Pu8;
  pData       : Pu8;
  sz, rc      : i32;
  pSlot       : Pu8;
  pCell       : Pu8;
begin
  i    := iFirst;
  aData := pPg^.aData;
  pData := ppData;
  iEnd := iFirst + nCell;
  if iEnd <= iFirst then begin
    Result := 0;
    Exit;
  end;
  k := 0;
  while pCArray^.ixNx[k] <= i do Inc(k);
  pEnd := pCArray^.apEnd[k];

  while True do begin
    sz    := i32((pCArray^.szCell + i)^);
    pCell := (pCArray^.apCell + i)^;
    if (aData[1] = 0) and (aData[2] = 0) then
      pSlot := nil
    else
      pSlot := pageFindSlot(pPg, sz, rc);
    if pSlot = nil then begin
      if (PtrUInt(pData) - PtrUInt(pBegin)) < PtrUInt(sz) then begin
        Result := 1;
        Exit;
      end;
      Dec(pData, sz);
      pSlot := pData;
    end;
    if SQLITE_OVERFLOW_CHK(pEnd, pCell, pCell + sz) then begin
      Result := 1;
      Exit;
    end;
    Move(pCell^, pSlot^, sz);
    put2byte(pCellptr, i32(pSlot - aData));
    Inc(pCellptr, 2);
    Inc(i);
    if i >= iEnd then Break;
    if pCArray^.ixNx[k] <= i then begin
      Inc(k);
      pEnd := pCArray^.apEnd[k];
    end;
  end;
  ppData := pData;
  Result := 0;
end;

{ ---------------------------------------------------------------------------
  pageFreeArray — add cells from array to page free list
  btree.c lines 7788-7844
  --------------------------------------------------------------------------- }

function pageFreeArray(pPg: PMemPage; iFirst: i32; nCell: i32;
                        pCArray: PCellArray): i32;
var
  aData, pEnd, pStart : Pu8;
  nRet, nFree         : i32;
  i, j, iEnd          : i32;
  pCell               : Pu8;
  sz, iAfter, iOfst   : i32;
  aOfst, aAfter       : array[0..9] of i32;
begin
  aData  := pPg^.aData;
  pEnd   := aData + pPg^.pBt^.usableSize;
  pStart := aData + pPg^.hdrOffset + 8 + pPg^.childPtrSize;
  nRet   := 0;
  nFree  := 0;
  iEnd   := iFirst + nCell;

  for i := iFirst to iEnd - 1 do begin
    pCell := (pCArray^.apCell + i)^;
    if SQLITE_WITHIN(pCell, pStart, pEnd) then begin
      sz    := i32((pCArray^.szCell + i)^);
      iOfst := i32(pCell - aData);
      iAfter := iOfst + sz;
      j := 0;
      while j < nFree do begin
        if aOfst[j] = iAfter then begin
          aOfst[j] := iOfst;
          Break;
        end else if aAfter[j] = iOfst then begin
          aAfter[j] := iAfter;
          Break;
        end;
        Inc(j);
      end;
      if j >= nFree then begin
        if nFree >= 10 then begin
          for j := 0 to nFree - 1 do
            freeSpace(pPg, aOfst[j], aAfter[j] - aOfst[j]);
          nFree := 0;
        end;
        aOfst[nFree]  := iOfst;
        aAfter[nFree] := iAfter;
        if PtrUInt(aData + iAfter) > PtrUInt(pEnd) then begin
          Result := 0;
          Exit;
        end;
        Inc(nFree);
      end;
      Inc(nRet);
    end;
  end;
  for j := 0 to nFree - 1 do
    freeSpace(pPg, aOfst[j], aAfter[j] - aOfst[j]);
  Result := nRet;
end;

{ ---------------------------------------------------------------------------
  editPage — edit page to new cell layout
  btree.c lines 7858-7965
  --------------------------------------------------------------------------- }

function editPage(pPg: PMemPage; iOld: i32; iNew: i32; nNew: i32;
                  pCArray: PCellArray): i32;
var
  aData               : Pu8;
  hdr                 : i32;
  pBegin              : Pu8;
  nCell               : i32;
  pData, pCellptr     : Pu8;
  i                   : i32;
  iOldEnd, iNewEnd    : i32;
  nShift, nTail, nAdd : i32;
  iCell               : i32;
label
  editpage_fail;
begin
  aData   := pPg^.aData;
  hdr     := pPg^.hdrOffset;
  pBegin  := pPg^.aCellIdx + nNew * 2;
  nCell   := i32(pPg^.nCell);
  iOldEnd := iOld + i32(pPg^.nCell) + i32(pPg^.nOverflow);
  iNewEnd := iNew + nNew;

  if iOld < iNew then begin
    nShift := pageFreeArray(pPg, iOld, iNew - iOld, pCArray);
    if nShift > nCell then begin
      Result := SQLITE_CORRUPT_BKPT;
      Exit;
    end;
    Move(pPg^.aCellIdx[nShift * 2], pPg^.aCellIdx[0], nCell * 2);
    Dec(nCell, nShift);
  end;
  if iNewEnd < iOldEnd then begin
    nTail := pageFreeArray(pPg, iNewEnd, iOldEnd - iNewEnd, pCArray);
    Dec(nCell, nTail);
  end;

  pData := aData + get2byte(aData + hdr + 5);
  if PtrUInt(pData) < PtrUInt(pBegin) then goto editpage_fail;

  { Add cells at start }
  if iNew < iOld then begin
    if iOld - iNew < nNew then
      nAdd := iOld - iNew
    else
      nAdd := nNew;
    pCellptr := pPg^.aCellIdx;
    Move(pCellptr[0], pCellptr[nAdd * 2], nCell * 2);
    if pageInsertArray(pPg, pBegin, pData, pCellptr,
                       iNew, nAdd, pCArray) <> 0 then
      goto editpage_fail;
    Inc(nCell, nAdd);
  end;

  { Add overflow cells }
  for i := 0 to i32(pPg^.nOverflow) - 1 do begin
    iCell := (iOld + i32(pPg^.aiOvfl[i])) - iNew;
    if (iCell >= 0) and (iCell < nNew) then begin
      pCellptr := pPg^.aCellIdx + iCell * 2;
      if nCell > iCell then
        Move(pCellptr[0], pCellptr[2], (nCell - iCell) * 2);
      Inc(nCell);
      cachedCellSize(pCArray, iCell + iNew);
      if pageInsertArray(pPg, pBegin, pData, pCellptr,
                         iCell + iNew, 1, pCArray) <> 0 then
        goto editpage_fail;
    end;
  end;

  { Append cells at end }
  pCellptr := pPg^.aCellIdx + nCell * 2;
  if pageInsertArray(pPg, pBegin, pData, pCellptr,
                     iNew + nCell, nNew - nCell, pCArray) <> 0 then
    goto editpage_fail;

  pPg^.nCell    := u16(nNew);
  pPg^.nOverflow := 0;
  put2byte(aData + hdr + 3, i32(pPg^.nCell));
  put2byte(aData + hdr + 5, i32(pData - aData));
  Result := SQLITE_OK;
  Exit;

editpage_fail:
  if nNew < 1 then begin
    Result := SQLITE_CORRUPT_BKPT;
    Exit;
  end;
  populateCellCache(pCArray, iNew, nNew);
  Result := rebuildPage(pCArray, iNew, nNew, pPg);
end;

{ ---------------------------------------------------------------------------
  balance_quick — fast balance for right-end insert
  btree.c lines 7992-8087
  --------------------------------------------------------------------------- }

function balance_quick(pParent: PMemPage; pPage: PMemPage;
                        pSpace: Pu8): i32;
var
  pBt    : PBtShared;
  pNew   : PMemPage;
  rc     : i32;
  pgnoNew: Pgno;
  pOut   : Pu8;
  pCell  : Pu8;
  szCell : u16;
  pStop  : Pu8;
  b      : TCellArray;
  bApCell: Pu8;
  bSzCell: u16;
begin
  pBt  := pPage^.pBt;
  pNew := nil;
  rc   := SQLITE_OK;

  if pPage^.nCell = 0 then begin
    Result := SQLITE_CORRUPT_BKPT;
    Exit;
  end;

  rc := allocateBtreePage(pBt, pNew, pgnoNew, 0, 0);
  if rc <> SQLITE_OK then begin
    Result := rc;
    Exit;
  end;

  pOut   := pSpace + 4;
  pCell  := pPage^.apOvfl[0];
  szCell := pPage^.xCellSize(pPage, pCell);

  zeroPage(pNew, PTF_INTKEY or PTF_LEAFDATA or PTF_LEAF);
  FillChar(b, SizeOf(b), 0);
  b.nCell := 1;
  b.pRef  := pPage;
  bApCell := pCell;
  bSzCell := szCell;
  b.apCell := @bApCell;
  b.szCell := @bSzCell;
  b.apEnd[0] := pPage^.aDataEnd;
  b.ixNx[0]  := 2;
  b.ixNx[NB*2-1] := $7fffffff;
  rc := rebuildPage(@b, 0, 1, pNew);
  if rc <> SQLITE_OK then begin
    releasePage(pNew);
    Result := rc;
    Exit;
  end;
  pNew^.nFree := i32(pBt^.usableSize) - i32(pNew^.cellOffset) - 2 - szCell;

  if ISAUTOVACUUM(pBt) then begin
    ptrmapPut(pBt, pgnoNew, PTRMAP_BTREE, pParent^.pgno, @rc);
    if szCell > pNew^.minLocal then
      ptrmapPutOvflPtr(pNew, pNew, pCell, @rc);
  end;

  { Build divider cell in pSpace }
  pCell := findCell(pPage, i32(pPage^.nCell) - 1);
  pStop := pCell + 9;
  while (pCell^ and $80 <> 0) and (PtrUInt(pCell) < PtrUInt(pStop)) do
    Inc(pCell);
  Inc(pCell);  { advance past terminal varint byte, matching C's post-increment semantics }
  pStop := pCell + 9;
  while True do begin
    pOut^ := pCell^;
    Inc(pOut);
    Inc(pCell);
    if (pOut[-1] and $80 = 0) or (PtrUInt(pCell) >= PtrUInt(pStop)) then
      Break;
  end;

  if rc = SQLITE_OK then begin
    rc := insertCell(pParent, i32(pParent^.nCell), pSpace,
                     i32(pOut - pSpace), nil, pPage^.pgno);
  end;
  put4byte(pParent^.aData + pParent^.hdrOffset + 8, pgnoNew);
  releasePage(pNew);
  Result := rc;
end;

{ ---------------------------------------------------------------------------
  copyNodeContent — copy a btree node from one page to another
  btree.c lines 8148-8188
  --------------------------------------------------------------------------- }

procedure copyNodeContent(pFrom: PMemPage; pTo: PMemPage; pRC: Pi32);
var
  pBt     : PBtShared;
  aFrom   : Pu8;
  aTo     : Pu8;
  iFromHdr: i32;
  iToHdr  : i32;
  rc      : i32;
  iData   : i32;
begin
  if pRC^ <> SQLITE_OK then Exit;
  pBt     := pFrom^.pBt;
  aFrom   := pFrom^.aData;
  aTo     := pTo^.aData;
  iFromHdr := i32(pFrom^.hdrOffset);
  if pTo^.pgno = 1 then iToHdr := 100 else iToHdr := 0;

  iData := get2byte(aFrom + iFromHdr + 5);
  Move((aFrom + iData)^, (aTo + iData)^, i32(pBt^.usableSize) - iData);
  Move((aFrom + iFromHdr)^, (aTo + iToHdr)^,
       i32(pFrom^.cellOffset) + 2 * i32(pFrom^.nCell));

  pTo^.isInit := 0;
  rc := btreeInitPage(pTo);
  if rc = SQLITE_OK then rc := btreeComputeFreeSpace(pTo);
  if rc <> SQLITE_OK then begin
    pRC^ := rc;
    Exit;
  end;

  if ISAUTOVACUUM(pBt) then
    pRC^ := setChildPtrmaps(pTo);
end;

{ ---------------------------------------------------------------------------
  balance_nonroot — general balance of non-root siblings
  btree.c lines 8230-9012
  --------------------------------------------------------------------------- }

function balance_nonroot(pParent: PMemPage; iParentIdx: i32;
                          aOvflSpace: Pu8; isRoot: i32; bBulk: i32): i32;
var
  pBt          : PBtShared;
  nMaxCells    : i32;
  nNew, nOld   : i32;
  i, j, k      : i32;
  nxDiv        : i32;
  rc           : i32;
  leafCorrection: u16;
  leafData     : i32;
  usableSpace  : i32;
  pageFlags    : i32;
  iSpace1      : i32;
  iOvflSpace   : i32;
  szScratch    : u64;
  apOld        : array[0..NB-1] of PMemPage;
  apNew        : array[0..NB+1] of PMemPage;
  pRight       : Pu8;
  apDiv        : array[0..NB-2] of Pu8;
  cntNew       : array[0..NB+1] of i32;
  cntOld       : array[0..NB+1] of i32;
  szNew        : array[0..NB+1] of i32;
  aSpace1      : Pu8;
  pg           : Pgno;
  abDone       : array[0..NB+1] of u8;
  aPgno        : array[0..NB+1] of Pgno;
  b            : TCellArray;
  pMem         : Pointer;
  pOld         : PMemPage;
  limit        : i32;
  aData        : Pu8;
  maskPage     : u16;
  piCell       : Pu8;
  piEnd        : Pu8;
  sz           : u16;
  pCell        : Pu8;
  pTemp        : Pu8;
  iOff         : i32;
  iNew, iOld2  : i32;
  iNew2, iPg   : i32;
  nNewCell     : i32;
  pNew         : PMemPage;
  pSrcEnd      : Pu8;
  r, d         : i32;
  szRight, szLeft: i32;
  szR, szD     : i32;
  iB           : i32;
  pgnoA, pgnoB, pgnoTemp: Pgno;
  fgA, fgB     : u16;
  cntOldNext   : i32;
  iOldIdx      : i32;
  key          : u32;
  info2        : TCellInfo;
label
  balance_cleanup;
begin
  FillChar(abDone, SizeOf(abDone), 0);
  FillChar(b, SizeOf(b) - SizeOf(b.ixNx[0]), 0);
  b.ixNx[NB*2-1] := $7fffffff;
  pBt := pParent^.pBt;
  rc  := SQLITE_OK;
  { btree.c:8238..8249 — these are explicitly initialised in the C
    reference; Pascal uninitialised stack locals would otherwise carry
    forward random bytes from a prior frame. }
  nMaxCells  := 0;
  nNew       := 0;
  iSpace1    := 0;
  iOvflSpace := 0;

  if aOvflSpace = nil then begin
    Result := SQLITE_NOMEM_BKPT;
    Exit;
  end;

  { Find sibling pages and locate divider cells }
  i := i32(pParent^.nOverflow) + i32(pParent^.nCell);
  if i < 2 then
    nxDiv := 0
  else begin
    if iParentIdx = 0 then
      nxDiv := 0
    else if iParentIdx = i then
      nxDiv := i - 2 + bBulk
    else
      nxDiv := iParentIdx - 1;
    i := 2 - bBulk;
  end;
  nOld := i + 1;

  if (i + nxDiv - i32(pParent^.nOverflow)) = i32(pParent^.nCell) then
    pRight := pParent^.aData + pParent^.hdrOffset + 8
  else
    pRight := findCell(pParent, i + nxDiv - i32(pParent^.nOverflow));
  pg := sqlite3Get4byte(pRight);

  while True do begin
    if rc = SQLITE_OK then
      rc := getAndInitPage(pBt, pg, apOld[i], 0);
    if rc <> SQLITE_OK then begin
      FillChar(apOld[0], (i+1) * SizeOf(PMemPage), 0);
      goto balance_cleanup;
    end;
    if apOld[i]^.nFree < 0 then begin
      rc := btreeComputeFreeSpace(apOld[i]);
      if rc <> SQLITE_OK then begin
        FillChar(apOld[0], i * SizeOf(PMemPage), 0);
        goto balance_cleanup;
      end;
    end;
    Inc(nMaxCells, i32(apOld[i]^.nCell) + 4); { +4 for overflow slots }
    if i = 0 then Break;
    Dec(i);

    if (i32(pParent^.nOverflow) > 0) and (i + nxDiv = i32(pParent^.aiOvfl[0])) then begin
      apDiv[i] := pParent^.apOvfl[0];
      pg       := sqlite3Get4byte(apDiv[i]);
      szNew[i] := i32(pParent^.xCellSize(pParent, apDiv[i]));
      pParent^.nOverflow := 0;
    end else begin
      apDiv[i] := findCell(pParent, i + nxDiv - i32(pParent^.nOverflow));
      pg       := sqlite3Get4byte(apDiv[i]);
      szNew[i] := i32(pParent^.xCellSize(pParent, apDiv[i]));
      if (pBt^.btsFlags and BTS_FAST_SECURE) <> 0 then begin
        iOff := i32(PtrUInt(apDiv[i]) - PtrUInt(pParent^.aData));
        if (iOff + szNew[i]) <= i32(pBt^.usableSize) then begin
          Move(apDiv[i]^, (aOvflSpace + iOff)^, szNew[i]);
          apDiv[i] := aOvflSpace + (PtrUInt(apDiv[i]) - PtrUInt(pParent^.aData));
        end;
      end;
      dropCell(pParent, i + nxDiv - i32(pParent^.nOverflow), szNew[i], @rc);
    end;
  end;

  nMaxCells := (nMaxCells + 3) and (not 3);

  { Allocate scratch memory }
  szScratch := u64(nMaxCells) * (SizeOf(Pointer) + SizeOf(u16)) + pBt^.pageSize;
  pMem := sqlite3StackAllocRaw(nil, szScratch);
  if pMem = nil then begin
    rc := SQLITE_NOMEM_BKPT;
    goto balance_cleanup;
  end;
  b.apCell := PPu8(pMem);
  b.szCell := Pu16(PByte(b.apCell) + nMaxCells * SizeOf(Pointer));
  aSpace1  := PByte(b.szCell) + nMaxCells * SizeOf(u16);
  iSpace1  := 0;

  { Load cell pointers from sibling pages }
  b.pRef       := apOld[0];
  leafCorrection := u16(b.pRef^.leaf * 4);
  leafData     := i32(b.pRef^.intKeyLeaf);
  b.nCell      := 0;
  for i := 0 to nOld - 1 do begin
    pOld     := apOld[i];
    limit    := i32(pOld^.nCell);
    aData    := pOld^.aData;
    maskPage := pOld^.maskPage;
    piCell   := aData + pOld^.cellOffset;

    if pOld^.aData[0] <> apOld[0]^.aData[0] then begin
      rc := CORRUPT_PAGE(pOld);
      goto balance_cleanup;
    end;

    FillChar((b.szCell + b.nCell)^, (limit + i32(pOld^.nOverflow)) * SizeOf(u16), 0);
    if pOld^.nOverflow > 0 then begin
      if limit < i32(pOld^.aiOvfl[0]) then begin
        rc := CORRUPT_PAGE(pOld);
        goto balance_cleanup;
      end;
      limit := i32(pOld^.aiOvfl[0]);
      for j := 0 to limit - 1 do begin
        (b.apCell + b.nCell)^ := aData + (maskPage and u16(get2byteAligned(piCell)));
        Inc(piCell, 2);
        Inc(b.nCell);
      end;
      for k := 0 to i32(pOld^.nOverflow) - 1 do begin
        (b.apCell + b.nCell)^ := pOld^.apOvfl[k];
        Inc(b.nCell);
      end;
    end;
    piEnd := aData + pOld^.cellOffset + 2 * i32(pOld^.nCell);
    while PtrUInt(piCell) < PtrUInt(piEnd) do begin
      (b.apCell + b.nCell)^ := aData + (maskPage and u16(get2byteAligned(piCell)));
      Inc(piCell, 2);
      Inc(b.nCell);
    end;

    cntOld[i] := b.nCell;
    if (i < nOld - 1) and (leafData = 0) then begin
      sz    := u16(szNew[i]);
      pTemp := aSpace1 + iSpace1;
      Inc(iSpace1, szNew[i]);
      Move(apDiv[i]^, pTemp^, szNew[i]);
      (b.apCell + b.nCell)^ := pTemp + leafCorrection;
      (b.szCell + b.nCell)^ := sz - leafCorrection;
      if pOld^.leaf = 0 then
        Move(pOld^.aData[8], (b.apCell + b.nCell)^^, 4)
      else begin
        while (b.szCell + b.nCell)^ < 4 do begin
          aSpace1[iSpace1] := 0;
          Inc(iSpace1);
          Inc((b.szCell + b.nCell)^);
        end;
      end;
      Inc(b.nCell);
    end;
  end;

  { Figure out page distribution }
  usableSpace := i32(pBt^.usableSize) - 12 + i32(leafCorrection);
  k := 0;
  for i := 0 to nOld - 1 do begin
    pOld := apOld[i];
    b.apEnd[k] := pOld^.aDataEnd;
    b.ixNx[k]  := cntOld[i];
    if (k > 0) and (b.ixNx[k] = b.ixNx[k-1]) then
      Dec(k);
    if leafData = 0 then begin
      Inc(k);
      b.apEnd[k] := pParent^.aDataEnd;
      b.ixNx[k]  := cntOld[i] + 1;
    end;
    Inc(k);
    szNew[i]  := usableSpace - i32(pOld^.nFree);
    for j := 0 to i32(pOld^.nOverflow) - 1 do
      Inc(szNew[i], 2 + i32(pOld^.xCellSize(pOld, pOld^.apOvfl[j])));
    cntNew[i] := cntOld[i];
  end;
  k := nOld;
  i := 0;
  while i < k do begin
    while szNew[i] > usableSpace do begin
      if i + 1 >= k then begin
        Inc(k);
        if k > NB + 2 then begin
          rc := SQLITE_CORRUPT_BKPT;
          goto balance_cleanup;
        end;
        szNew[k-1]  := 0;
        cntNew[k-1] := b.nCell;
      end;
      sz := 2 + i32(cachedCellSize(@b, cntNew[i] - 1));
      Dec(szNew[i], sz);
      if leafData = 0 then begin
        if cntNew[i] < b.nCell then
          sz := 2 + i32(cachedCellSize(@b, cntNew[i]))
        else
          sz := 0;
      end;
      Inc(szNew[i+1], sz);
      Dec(cntNew[i]);
    end;
    while cntNew[i] < b.nCell do begin
      sz := 2 + i32(cachedCellSize(@b, cntNew[i]));
      if szNew[i] + sz > usableSpace then Break;
      Inc(szNew[i], sz);
      Inc(cntNew[i]);
      if leafData = 0 then begin
        if cntNew[i] < b.nCell then
          sz := 2 + i32(cachedCellSize(@b, cntNew[i]))
        else
          sz := 0;
      end;
      Dec(szNew[i+1], sz);
    end;
    if cntNew[i] >= b.nCell then
      k := i + 1
    else if ((i > 0) and (cntNew[i] <= cntNew[i-1])) or
            ((i = 0) and (cntNew[i] <= 0)) then begin
      rc := SQLITE_CORRUPT_BKPT;
      goto balance_cleanup;
    end;
    Inc(i);
  end;

  { Rebalance right-biased packing }
  for i := k - 1 downto 1 do begin
    szRight := szNew[i];
    szLeft  := szNew[i-1];
    r := cntNew[i-1] - 1;
    d := r + 1 - leafData;
    cachedCellSize(@b, d);
    repeat
      szR := i32(cachedCellSize(@b, r));
      szD := i32((b.szCell + d)^);
      if ((szRight <> 0) and (bBulk <> 0)) or
         ((i = k-1) and (szRight + szD + 2 > szLeft - szR)) or
         ((i <> k-1) and (szRight + szD + 2 > szLeft - szR - 2)) then
        Break;
      Inc(szRight, szD + 2);
      Dec(szLeft, szR + 2);
      cntNew[i-1] := r;
      Dec(r);
      Dec(d);
    until r < 0;
    szNew[i]   := szRight;
    szNew[i-1] := szLeft;
    if ((i > 1) and (cntNew[i-1] <= cntNew[i-2])) or
       ((i <= 1) and (cntNew[i-1] <= 0)) then begin
      rc := SQLITE_CORRUPT_BKPT;
      goto balance_cleanup;
    end;
  end;

  { Allocate k new pages }
  pageFlags := i32(apOld[0]^.aData[0]);
  nNew := 0;
  for i := 0 to k - 1 do begin
    if i < nOld then begin
      pNew     := apOld[i];
      apNew[i] := pNew;
      apOld[i] := nil;
      rc := sqlite3PagerWrite(pNew^.pDbPage);
      Inc(nNew);
      if rc <> SQLITE_OK then goto balance_cleanup;
    end else begin
      if bBulk <> 0 then
        rc := allocateBtreePage(pBt, apNew[i], pg, 1, 0)
      else
        rc := allocateBtreePage(pBt, apNew[i], pg, pg, 0);
      if rc <> SQLITE_OK then goto balance_cleanup;
      zeroPage(apNew[i], pageFlags);
      Inc(nNew);
      cntOld[i] := b.nCell;
      if ISAUTOVACUUM(pBt) then begin
        ptrmapPut(pBt, apNew[i]^.pgno, PTRMAP_BTREE, pParent^.pgno, @rc);
        if rc <> SQLITE_OK then goto balance_cleanup;
      end;
    end;
    aPgno[i] := apNew[i]^.pgno;
  end;

  { Sort pages by page number (O(N^2), N<=5) }
  for i := 0 to nNew - 2 do begin
    iB := i;
    for j := i + 1 to nNew - 1 do
      if apNew[j]^.pgno < apNew[iB]^.pgno then iB := j;
    if iB <> i then begin
      pgnoA    := apNew[i]^.pgno;
      pgnoB    := apNew[iB]^.pgno;
      pgnoTemp := (PENDING_BYTE div pBt^.pageSize) + 1;
      fgA      := apNew[i]^.pDbPage^.flags;
      fgB      := apNew[iB]^.pDbPage^.flags;
      sqlite3PagerRekey(apNew[i]^.pDbPage, pgnoTemp, fgB);
      sqlite3PagerRekey(apNew[iB]^.pDbPage, pgnoA, fgA);
      sqlite3PagerRekey(apNew[i]^.pDbPage, pgnoB, fgB);
      apNew[i]^.pgno  := pgnoB;
      apNew[iB]^.pgno := pgnoA;
    end;
  end;

  put4byte(pRight, apNew[nNew-1]^.pgno);

  { Copy right-child pointer if interior pages changed count }
  if ((pageFlags and PTF_LEAF) = 0) and (nOld <> nNew) then begin
    if nNew > nOld then
      pOld := apNew[nOld-1]
    else
      pOld := apOld[nOld-1];
    Move(pOld^.aData[8], apNew[nNew-1]^.aData[8], 4);
  end;

  { Auto-vacuum pointer-map updates (no-op in this port) }

  { Insert divider cells into pParent }
  iOvflSpace := 0;
  for i := 0 to nNew - 2 do begin
    pCell    := (b.apCell + cntNew[i])^;
    sz       := i32((b.szCell + cntNew[i])^) + i32(leafCorrection);
    pTemp    := aOvflSpace + iOvflSpace;
    pNew     := apNew[i];
    if pNew^.leaf = 0 then
      Move(pCell^, pNew^.aData[8], 4)
    else if leafData <> 0 then begin
      { leaf-data: divider is key of last cell on this sibling }
      j     := cntNew[i] - 1;
      pNew^.xParseCell(pNew, (b.apCell + j)^, @info2);
      pCell := pTemp;
      sz    := 4 + sqlite3PutVarint(pCell + 4, u64(info2.nKey));
      pTemp := nil;
    end else begin
      Dec(pCell, 4);
      if (b.szCell + cntNew[i])^ = 4 then
        sz := i32(pParent^.xCellSize(pParent, pCell));
    end;
    Inc(iOvflSpace, sz);

    k := 0;
    while b.ixNx[k] <= cntNew[i] do Inc(k);
    pSrcEnd := b.apEnd[k];
    if SQLITE_OVERFLOW_CHK(pSrcEnd, pCell, pCell + sz) then begin
      rc := SQLITE_CORRUPT_BKPT;
      goto balance_cleanup;
    end;
    rc := insertCell(pParent, nxDiv + i, pCell, sz, pTemp, pNew^.pgno);
    if rc <> SQLITE_OK then goto balance_cleanup;
  end;

  { Update sibling pages (two-pass: down then up) }
  for i := 1 - nNew to nNew - 1 do begin
    if i < 0 then iPg := -i else iPg := i;
    if abDone[iPg] <> 0 then continue;
    if (i >= 0) or
       (cntOld[iPg-1] >= cntNew[iPg-1]) then begin
      if iPg = 0 then begin
        iNew2 := 0; iOld2 := 0;
        nNewCell := cntNew[0];
      end else begin
        if iPg < nOld then
          iOld2 := cntOld[iPg-1] + (1 - leafData)
        else
          iOld2 := b.nCell;
        iNew2    := cntNew[iPg-1] + (1 - leafData);
        nNewCell := cntNew[iPg] - iNew2;
      end;
      rc := editPage(apNew[iPg], iOld2, iNew2, nNewCell, @b);
      if rc <> SQLITE_OK then goto balance_cleanup;
      abDone[iPg]      := 1;
      apNew[iPg]^.nFree := usableSpace - szNew[iPg];
    end;
  end;

  { Balance-shallower: root page now empty }
  if (isRoot <> 0) and (pParent^.nCell = 0) and
     (i32(pParent^.hdrOffset) <= apNew[0]^.nFree) then begin
    rc := defragmentPage(apNew[0], -1);
    copyNodeContent(apNew[0], pParent, @rc);
    freePage(apNew[0], @rc);
  end else if ISAUTOVACUUM(pBt) and (leafCorrection = 0) then begin
    for i := 0 to nNew - 1 do begin
      key := sqlite3Get4byte(apNew[i]^.aData + 8);
      ptrmapPut(pBt, key, PTRMAP_BTREE, apNew[i]^.pgno, @rc);
    end;
  end;

  { Free old pages not reused }
  for i := nNew to nOld - 1 do
    freePage(apOld[i], @rc);

balance_cleanup:
  sqlite3StackFree(nil, pMem);
  for i := 0 to nOld - 1 do releasePage(apOld[i]);
  for i := 0 to nNew - 1 do releasePage(apNew[i]);
  Result := rc;
end;

{ ---------------------------------------------------------------------------
  balance_deeper — grow tree depth when root overflows
  btree.c lines 9034-9079
  --------------------------------------------------------------------------- }

function balance_deeper(pRoot: PMemPage; out ppChild: PMemPage): i32;
var
  rc        : i32;
  pChild    : PMemPage;
  pgnoChild : Pgno;
  pBt       : PBtShared;
begin
  pChild    := nil;
  pgnoChild := 0;
  pBt       := pRoot^.pBt;
  ppChild   := nil;

  rc := sqlite3PagerWrite(pRoot^.pDbPage);
  if rc = SQLITE_OK then begin
    rc := allocateBtreePage(pBt, pChild, pgnoChild, pRoot^.pgno, 0);
    copyNodeContent(pRoot, pChild, @rc);
    if ISAUTOVACUUM(pBt) then
      ptrmapPut(pBt, pgnoChild, PTRMAP_BTREE, pRoot^.pgno, @rc);
  end;
  if rc <> SQLITE_OK then begin
    releasePage(pChild);
    Result := rc;
    Exit;
  end;

  Move(pRoot^.aiOvfl[0], pChild^.aiOvfl[0],
       pRoot^.nOverflow * SizeOf(pRoot^.aiOvfl[0]));
  Move(pRoot^.apOvfl[0], pChild^.apOvfl[0],
       pRoot^.nOverflow * SizeOf(pRoot^.apOvfl[0]));
  pChild^.nOverflow := pRoot^.nOverflow;

  zeroPage(pRoot, i32(pChild^.aData[0]) and (not PTF_LEAF));
  sqlite3Put4byte(pRoot^.aData + pRoot^.hdrOffset + 8, pgnoChild);

  ppChild := pChild;
  Result  := SQLITE_OK;
end;

{ ---------------------------------------------------------------------------
  anotherValidCursor — detect other valid cursors on same page
  btree.c lines 9092-9103
  --------------------------------------------------------------------------- }

function anotherValidCursor(pCur: PBtCursor): i32;
var
  pOther: PBtCursor;
begin
  pOther := pCur^.pBt^.pCursor;
  while pOther <> nil do begin
    if (pOther <> pCur) and (pOther^.eState = CURSOR_VALID) and
       (pOther^.pPage = pCur^.pPage) then begin
      Result := CORRUPT_PAGE(pCur^.pPage);
      Exit;
    end;
    pOther := pOther^.pNext;
  end;
  Result := SQLITE_OK;
end;

{ ---------------------------------------------------------------------------
  balance — main balance dispatcher
  btree.c lines 9115-9244
  --------------------------------------------------------------------------- }

function balance(pCur: PBtCursor): i32;
var
  rc                  : i32;
  aBalanceQuickSpace  : array[0..12] of u8;
  pFree               : Pu8;
  iPage               : i32;
  pPage               : PMemPage;
  pParent             : PMemPage;
  iIdx                : i32;
  pSpace              : Pu8;
begin
  rc    := SQLITE_OK;
  pFree := nil;

  repeat
    pPage := pCur^.pPage;
    if (pPage^.nFree < 0) and (btreeComputeFreeSpace(pPage) <> SQLITE_OK) then
      Break;
    if (pPage^.nOverflow = 0) and
       (pPage^.nFree * 3 <= i32(pCur^.pBt^.usableSize) * 2) then
      Break
    else begin
      iPage := i32(pCur^.iPage);
      if iPage = 0 then begin
        if (pPage^.nOverflow <> 0) and
           (anotherValidCursor(pCur) = SQLITE_OK) then begin
          rc := balance_deeper(pPage, pCur^.apPage[1]);
          if rc = SQLITE_OK then begin
            pCur^.iPage     := 1;
            pCur^.ix        := 0;
            pCur^.aiIdx[0]  := 0;
            pCur^.apPage[0] := pPage;
            pCur^.pPage     := pCur^.apPage[1];
          end;
        end else
          Break;
      end else if sqlite3PcachePageRefcount(pPage^.pDbPage) > 1 then begin
        rc := CORRUPT_PAGE(pPage);
      end else begin
        pParent := pCur^.apPage[iPage - 1];
        iIdx    := i32(pCur^.aiIdx[iPage - 1]);
        rc := sqlite3PagerWrite(pParent^.pDbPage);
        if (rc = SQLITE_OK) and (pParent^.nFree < 0) then
          rc := btreeComputeFreeSpace(pParent);
        if rc = SQLITE_OK then begin
          if pPage^.intKeyLeaf <> 0 then begin
            if (pPage^.nOverflow = 1) and
               (i32(pPage^.aiOvfl[0]) = i32(pPage^.nCell)) and
               (pParent^.pgno <> 1) and
               (i32(pParent^.nCell) = iIdx) then begin
              rc := balance_quick(pParent, pPage, @aBalanceQuickSpace[0]);
            end else begin
              pSpace := Pu8(sqlite3PageMalloc(i32(pCur^.pBt^.pageSize)));
              rc     := balance_nonroot(pParent, iIdx, pSpace, ord(iPage = 1),
                                        i32(pCur^.hints) and BTREE_BULKLOAD);
              if pFree <> nil then
                sqlite3PageFree(pFree);
              pFree := pSpace;
            end;
          end else begin
            pSpace := Pu8(sqlite3PageMalloc(i32(pCur^.pBt^.pageSize)));
            rc     := balance_nonroot(pParent, iIdx, pSpace, ord(iPage = 1),
                                      i32(pCur^.hints) and BTREE_BULKLOAD);
            if pFree <> nil then
              sqlite3PageFree(pFree);
            pFree := pSpace;
          end;
        end;

        pPage^.nOverflow := 0;
        releasePage(pPage);
        Dec(pCur^.iPage);
        pCur^.pPage := pCur^.apPage[pCur^.iPage];
      end;
    end;
  until rc <> SQLITE_OK;

  if pFree <> nil then
    sqlite3PageFree(pFree);
  Result := rc;
end;

{ ---------------------------------------------------------------------------
  btreeOverwriteContent — overwrite cell content (no-realloc path)
  btree.c lines 9249-9286
  --------------------------------------------------------------------------- }

function btreeOverwriteContent(pPage: PMemPage; pDest: Pu8;
                                const pX: PBtreePayload;
                                iOffset: i32; iAmt: i32): i32;
var
  nData: i32;
  rc   : i32;
  i    : i32;
begin
  nData := pX^.nData - iOffset;
  if nData <= 0 then begin
    { Overwriting with zeros }
    i := 0;
    while (i < iAmt) and (pDest[i] = 0) do Inc(i);
    if i < iAmt then begin
      rc := sqlite3PagerWrite(pPage^.pDbPage);
      if rc <> SQLITE_OK then begin Result := rc; Exit; end;
      FillChar((pDest + i)^, iAmt - i, 0);
    end;
  end else begin
    if nData < iAmt then begin
      rc := btreeOverwriteContent(pPage, pDest + nData, pX,
                                   iOffset + nData, iAmt - nData);
      if rc <> SQLITE_OK then begin Result := rc; Exit; end;
      iAmt := nData;
    end;
    if CompareByte((pDest)^, (Pu8(pX^.pData) + iOffset)^, iAmt) <> 0 then begin
      rc := sqlite3PagerWrite(pPage^.pDbPage);
      if rc <> SQLITE_OK then begin Result := rc; Exit; end;
      Move((Pu8(pX^.pData) + iOffset)^, pDest^, iAmt);
    end;
  end;
  Result := SQLITE_OK;
end;

{ ---------------------------------------------------------------------------
  btreeOverwriteOverflowCell — overwrite cell with overflow pages
  btree.c lines 9293-9338
  --------------------------------------------------------------------------- }

function btreeOverwriteOverflowCell(pCur: PBtCursor;
                                     const pX: PBtreePayload): i32;
var
  iOffset     : i32;
  nTotal      : i32;
  rc          : i32;
  pPage       : PMemPage;
  pBt         : PBtShared;
  ovflPgno    : Pgno;
  ovflPageSize: u32;
begin
  nTotal  := pX^.nData + pX^.nZero;
  pPage   := pCur^.pPage;
  pBt     := pPage^.pBt;
  rc := btreeOverwriteContent(pPage, pCur^.info.pPayload, pX,
                               0, i32(pCur^.info.nLocal));
  if rc <> SQLITE_OK then begin Result := rc; Exit; end;

  iOffset     := i32(pCur^.info.nLocal);
  ovflPgno    := sqlite3Get4byte(pCur^.info.pPayload + iOffset);
  ovflPageSize := pBt^.usableSize - 4;
  repeat
    rc := btreeGetPage(pBt, ovflPgno, pPage, 0);
    if rc <> SQLITE_OK then begin Result := rc; Exit; end;
    if (sqlite3PcachePageRefcount(pPage^.pDbPage) <> 1) or
       (pPage^.isInit <> 0) then begin
      rc := CORRUPT_PAGE(pPage);
    end else begin
      if u32(iOffset) + ovflPageSize < u32(nTotal) then
        ovflPgno := sqlite3Get4byte(pPage^.aData)
      else
        ovflPageSize := u32(nTotal) - u32(iOffset);
      rc := btreeOverwriteContent(pPage, pPage^.aData + 4, pX,
                                   iOffset, i32(ovflPageSize));
    end;
    sqlite3PagerUnref(pPage^.pDbPage);
    if rc <> SQLITE_OK then begin Result := rc; Exit; end;
    Inc(iOffset, i32(ovflPageSize));
  until iOffset >= nTotal;
  Result := SQLITE_OK;
end;

{ ---------------------------------------------------------------------------
  btreeOverwriteCell — overwrite cell contents in place
  btree.c lines 9344-9361
  --------------------------------------------------------------------------- }

function btreeOverwriteCell(pCur: PBtCursor;
                             const pX: PBtreePayload): i32;
var
  nTotal: i32;
  pPage : PMemPage;
begin
  nTotal := pX^.nData + pX^.nZero;
  pPage  := pCur^.pPage;
  if (PtrUInt(pCur^.info.pPayload + pCur^.info.nLocal) >
      PtrUInt(pPage^.aDataEnd)) or
     (PtrUInt(pCur^.info.pPayload) <
      PtrUInt(pPage^.aData + pPage^.cellOffset)) then begin
    Result := CORRUPT_PAGE(pPage);
    Exit;
  end;
  if i32(pCur^.info.nLocal) = nTotal then
    Result := btreeOverwriteContent(pPage, pCur^.info.pPayload, pX,
                                     0, i32(pCur^.info.nLocal))
  else
    Result := btreeOverwriteOverflowCell(pCur, pX);
end;

{ ---------------------------------------------------------------------------
  sqlite3BtreeInsert — insert a row into the b-tree
  btree.c lines 9394-9695
  --------------------------------------------------------------------------- }

function sqlite3BtreeInsert(pCur: PBtCursor; const pX: PBtreePayload;
                              flags: i32; seekResult: i32): i32;
var
  rc      : i32;
  loc     : i32;
  szNew   : i32;
  idx     : i32;
  pPage   : PMemPage;
  p       : PBtree;
  oldCell : Pu8;
  newCell : Pu8;
  info    : TCellInfo;
  pKeyMem : Pointer;
  r2      : TUnpackedRecord;
  x2      : TBtreePayload;
label
  end_insert;
begin
  rc      := SQLITE_OK;
  loc     := seekResult;
  szNew   := 0;
  p       := pCur^.pBtree;
  newCell := nil;
  pKeyMem := nil;

  if (pCur^.curFlags and BTCF_Multiple) <> 0 then begin
    rc := saveAllCursors(p^.pBt, pCur^.pgnoRoot, pCur);
    if rc <> SQLITE_OK then begin Result := rc; Exit; end;
    if (loc <> 0) and (pCur^.iPage < 0) then begin
      Result := SQLITE_CORRUPT_BKPT;
      Exit;
    end;
  end;

  if pCur^.eState >= CURSOR_REQUIRESEEK then begin
    rc := moveToRoot(pCur);
    if (rc <> SQLITE_OK) and (rc <> SQLITE_EMPTY) then begin
      Result := rc;
      Exit;
    end;
  end;

  if pCur^.pKeyInfo = nil then begin
    { Table b-tree }
    if p^.hasIncrblobCur <> 0 then
      invalidateIncrblobCursors(p, pCur^.pgnoRoot, pX^.nKey, 0);

    if ((pCur^.curFlags and BTCF_ValidNKey) <> 0) and
       (pX^.nKey = pCur^.info.nKey) then begin
      if (pCur^.info.nSize <> 0) and
         (pCur^.info.nPayload = u32(pX^.nData + pX^.nZero)) then begin
        Result := btreeOverwriteCell(pCur, pX);
        Exit;
      end;
      loc := 0;
    end else if loc = 0 then begin
      rc := sqlite3BtreeTableMoveto(pCur, pX^.nKey,
               (flags and BTREE_APPEND) shr 3, @loc);
      if rc <> SQLITE_OK then begin Result := rc; Exit; end;
    end;
  end else begin
    { Index b-tree }
    if (loc = 0) and ((flags and BTREE_SAVEPOSITION) = 0) then begin
      if pX^.nMem <> 0 then begin
        r2.pKeyInfo   := pCur^.pKeyInfo;
        r2.aMem       := pX^.aMem;
        r2.nField     := i32(pX^.nMem);
        r2.default_rc := 0;
        r2.eqSeen     := 0;
        rc := sqlite3BtreeIndexMoveto(pCur, @r2, @loc);
      end else
        rc := btreeMoveto(pCur, pX^.pKey, pX^.nKey,
                          (flags and BTREE_APPEND) shr 3, @loc);
      if rc <> SQLITE_OK then begin Result := rc; Exit; end;
    end;
    if loc = 0 then begin
      getCellInfo(pCur);
      if pCur^.info.nKey = pX^.nKey then begin
        x2.pData := pX^.pKey;
        x2.nData := i32(pX^.nKey);
        x2.nZero := 0;
        x2.pKey  := nil;
        x2.nKey  := 0;
        x2.aMem  := nil;
        x2.nMem  := 0;
        Result := btreeOverwriteCell(pCur, @x2);
        Exit;
      end;
    end;
  end;

  pPage := pCur^.pPage;
  if pPage^.nFree < 0 then begin
    rc := btreeComputeFreeSpace(pPage);
    if rc <> SQLITE_OK then begin Result := rc; Exit; end;
  end;

  newCell := p^.pBt^.pTmpSpace;
  if (flags and BTREE_PREFORMAT) <> 0 then begin
    rc    := SQLITE_OK;
    szNew := p^.pBt^.nPreformatSize;
    if szNew < 4 then begin
      szNew       := 4;
      newCell[3]  := 0;
    end;
    { btree.c:9576..9584 — when the preformatted cell spills to overflow
      pages on an auto-vacuum database, record the PTRMAP_OVERFLOW1 entry
      for the first overflow page. }
    if ISAUTOVACUUM(p^.pBt) and (szNew > i32(pPage^.maxLocal)) then begin
      pPage^.xParseCell(pPage, newCell, @info);
      if info.nPayload <> info.nLocal then begin
        ptrmapPut(p^.pBt, get4byte(@newCell[szNew - 4]),
                  PTRMAP_OVERFLOW1, pPage^.pgno, @rc);
        if rc <> SQLITE_OK then goto end_insert;
      end;
    end;
  end else begin
    rc := fillInCell(pPage, newCell, pX, szNew);
    if rc <> SQLITE_OK then goto end_insert;
  end;

  idx := i32(pCur^.ix);
  pCur^.info.nSize := 0;

  if loc = 0 then begin
    { Overwrite existing cell }
    if idx >= i32(pPage^.nCell) then begin
      rc := CORRUPT_PAGE(pPage);
      goto end_insert;
    end;
    rc := sqlite3PagerWrite(pPage^.pDbPage);
    if rc <> SQLITE_OK then goto end_insert;
    oldCell := findCell(pPage, idx);
    if pPage^.leaf = 0 then
      Move(oldCell^, newCell^, 4);
    BTREE_CLEAR_CELL(rc, pPage, oldCell, info);
    invalidateOverflowCache(pCur);
    if (info.nSize = u16(szNew)) and (info.nLocal = info.nPayload) and
       (not ISAUTOVACUUM(p^.pBt) or (szNew < i32(pPage^.minLocal))) then begin
      if (PtrUInt(oldCell) <
          PtrUInt(pPage^.aData + pPage^.hdrOffset + 10)) then begin
        rc := CORRUPT_PAGE(pPage);
        goto end_insert;
      end;
      if PtrUInt(oldCell + szNew) > PtrUInt(pPage^.aDataEnd) then begin
        rc := CORRUPT_PAGE(pPage);
        goto end_insert;
      end;
      Move(newCell^, oldCell^, szNew);
      Result := SQLITE_OK;
      Exit;
    end;
    dropCell(pPage, idx, i32(info.nSize), @rc);
    if rc <> SQLITE_OK then goto end_insert;
  end else if (loc < 0) and (pPage^.nCell > 0) then begin
    Inc(pCur^.ix);
    idx := i32(pCur^.ix);
    pCur^.curFlags := pCur^.curFlags and
                      u8(not (BTCF_ValidNKey or BTCF_ValidOvfl));
  end;

  rc := insertCellFast(pPage, idx, newCell, szNew);

  if pPage^.nOverflow <> 0 then begin
    pCur^.curFlags := pCur^.curFlags and
                      u8(not (BTCF_ValidNKey or BTCF_ValidOvfl));
    rc := balance(pCur);
    pCur^.pPage^.nOverflow := 0;
    pCur^.eState := CURSOR_INVALID;
    if ((flags and BTREE_SAVEPOSITION) <> 0) and (rc = SQLITE_OK) then begin
      btreeReleaseAllCursorPages(pCur);
      if pCur^.pKeyInfo <> nil then begin
        pCur^.pKey := sqlite3Malloc(i32(pX^.nKey));
        if pCur^.pKey = nil then
          rc := SQLITE_NOMEM_BKPT
        else
          Move(pX^.pKey^, pCur^.pKey^, i32(pX^.nKey));
      end;
      pCur^.eState := CURSOR_REQUIRESEEK;
      pCur^.nKey   := pX^.nKey;
    end;
  end;

end_insert:
  Result := rc;
end;

{ ===========================================================================
  Phase 4.4 — Pager page-refcount bridge
  =========================================================================== }

{ btree.c ~2494: sqlite3PagerPageRefcount — wraps pcache refcount }
function sqlite3PagerPageRefcount(pPage: PDbPage): i32;
begin
  Result := i32(sqlite3PcachePageRefcount(pPage));
end;

{ ===========================================================================
  Phase 4.4 — B-tree mutex stubs (btmutex.c — SQLITE_OMIT_SHARED_CACHE path)
  Shared-cache is omitted for this port.  In the non-threadsafe, non-shared
  path the only thing sqlite3BtreeEnter does is copy p->db to p->pBt->db.
  =========================================================================== }

procedure sqlite3BtreeEnter(p: PBtree);
begin
  p^.pBt^.db := p^.db;
end;

procedure sqlite3BtreeLeave(p: PBtree);
begin
  { no-op in non-threadsafe, non-shared-cache build }
end;

function sqlite3BtreeHoldsMutex(p: PBtree): i32;
begin
  Result := 1;  { always true when shared-cache is omitted }
end;

procedure sqlite3BtreeEnterCursor(pCur: PBtCursor);
begin
  sqlite3BtreeEnter(pCur^.pBtree);
end;

procedure sqlite3BtreeLeaveCursor(pCur: PBtCursor);
begin
  sqlite3BtreeLeave(pCur^.pBtree);
end;

{ ===========================================================================
  Phase 4.4 — pageReinit callback
  btree.c lines 2478-2496
  Called by the pager when a page is pulled from the cache and must be
  re-initialised (e.g. after a rollback that cleared the page content).
  =========================================================================== }

procedure pageReinit(pData: PDbPage);
var
  pPage: PMemPage;
begin
  pPage := PMemPage(sqlite3PagerGetExtra(pData));
  if pPage^.isInit <> 0 then begin
    pPage^.isInit := 0;
    if sqlite3PagerPageRefcount(pData) > 1 then
      btreeInitPage(pPage);
  end;
end;

{ btree.c lines 2500-2506: busy-handler callback registered with pager.
  Mirrors sqlite3InvokeBusyHandler (main.c:1770) inline — passqlite3main
  cannot be referenced from here (main uses btree), but the BusyHandler
  record lives in passqlite3util which we already use. }
function btreeInvokeBusyHandler(pArg: Pointer): i32;
var
  pBt: PBtShared;
  p  : passqlite3util.PBusyHandler;
  rc : i32;
begin
  pBt := PBtShared(pArg);
  if pBt^.db = nil then begin Result := 0; Exit; end;
  p := @passqlite3util.PTsqlite3(pBt^.db)^.busyHandler;
  if (p = nil) or not Assigned(p^.xBusyHandler) or (p^.nBusy < 0) then
  begin
    Result := 0; Exit;
  end;
  rc := p^.xBusyHandler(p^.pBusyArg, p^.nBusy);
  if rc = 0 then
    p^.nBusy := -1
  else
    Inc(p^.nBusy);
  Result := rc;
end;

{ ===========================================================================
  lockBtree — read page 1 and initialise BtShared fields
  btree.c lines 3278-3501
  =========================================================================== }

const
  { SQLite database magic header (btree.c line ~140) }
  zMagicHeader: array[0..15] of u8 = (
    $53,$51,$4C,$69,$74,$65,$20,$66,$6F,$72,$6D,$61,$74,$20,$33,$00);
    { "SQLite format 3\0" }

function lockBtree(pBt: PBtShared): i32;
var
  pPage1  : PMemPage;
  rc      : i32;
  nPage   : u32;
  nPageFile: i32;
  pageSize : u32;
  usableSize: u32;
  page1   : Pu8;
  isOpen  : i32;
  label page1_init_failed;
begin
  nPageFile := 0;
  rc := sqlite3PagerSharedLock(pBt^.pPager);
  if rc <> SQLITE_OK then begin Result := rc; Exit; end;
  rc := btreeGetPage(pBt, 1, pPage1, 0);
  if rc <> SQLITE_OK then begin Result := rc; Exit; end;

  nPage := get4byte(Pu8(pPage1^.aData) + 28);
  sqlite3PagerPagecount(pBt^.pPager, @nPageFile);
  if (nPage = 0) or
     (CompareMem(Pu8(pPage1^.aData) + 24, Pu8(pPage1^.aData) + 92, 4) = False) then
    nPage := u32(nPageFile);

  if nPage > 0 then begin
    page1 := pPage1^.aData;
    rc := SQLITE_NOTADB;

    { EVIDENCE-OF: R-43737-39999 check magic header }
    if CompareMem(page1, @zMagicHeader[0], 16) = False then
      goto page1_init_failed;

    { version write/read check }
    if page1[18] > 2 then
      pBt^.btsFlags := pBt^.btsFlags or BTS_READ_ONLY;
    if page1[19] > 2 then
      goto page1_init_failed;

    { WAL mode check }
    if (page1[19] = 2) and ((pBt^.btsFlags and BTS_NO_WAL) = 0) then begin
      { WAL mode: open WAL and return; caller will call again }
      isOpen := 0;
      rc := sqlite3PagerOpenWal(pBt^.pPager, @isOpen);
      if rc <> SQLITE_OK then goto page1_init_failed;
      if isOpen = 0 then begin
        releasePageOne(pPage1);
        Result := SQLITE_OK;
        Exit;
      end;
      rc := SQLITE_NOTADB;
    end;

    { payload fraction bytes must be 64/32/32 }
    if (page1[21] <> 64) or (page1[22] <> 32) or (page1[23] <> 32) then
      goto page1_init_failed;

    pageSize    := (u32(page1[16]) shl 8) or (u32(page1[17]) shl 16);
    if ((pageSize - 1) and pageSize) <> 0 then goto page1_init_failed;
    if pageSize > SQLITE_MAX_PAGE_SIZE then goto page1_init_failed;
    if pageSize <= 256 then goto page1_init_failed;

    usableSize := pageSize - page1[20];
    if pageSize <> pBt^.pageSize then begin
      { page size mismatch: reconfigure and return OK; caller retries }
      releasePageOne(pPage1);
      pBt^.usableSize := usableSize;
      pBt^.pageSize   := pageSize;
      pBt^.btsFlags   := pBt^.btsFlags or BTS_PAGESIZE_FIXED;
      freeTempSpace(pBt);
      Result := sqlite3PagerSetPagesize(pBt^.pPager, @pBt^.pageSize,
                                        i32(pageSize) - i32(usableSize));
      Exit;
    end;
    if nPage > u32(nPageFile) then begin
      { nPage in header > actual file size → treat as corrupt }
      rc := SQLITE_CORRUPT_BKPT;
      goto page1_init_failed;
    end;
    if usableSize < 480 then goto page1_init_failed;

    pBt^.btsFlags   := pBt^.btsFlags or BTS_PAGESIZE_FIXED;
    pBt^.pageSize   := pageSize;
    pBt^.usableSize := usableSize;
    { autovacuum flags from header meta[4] / meta[7] }
    pBt^.autoVacuum := u8(get4byte(page1 + 36 + 4*4));
    pBt^.incrVacuum := u8(get4byte(page1 + 36 + 7*4));
  end;

  { Recompute page-size-dependent limits }
  pBt^.maxLocal        := u16((pBt^.usableSize - 12) * 64 div 255 - 23);
  pBt^.minLocal        := u16((pBt^.usableSize - 12) * 32 div 255 - 23);
  pBt^.maxLeaf         := u16(pBt^.usableSize - 35);
  pBt^.minLeaf         := pBt^.minLocal;
  if pBt^.maxLocal > 127 then
    pBt^.max1bytePayload := 127
  else
    pBt^.max1bytePayload := u8(pBt^.maxLocal);

  pBt^.pPage1 := pPage1;
  pBt^.nPage  := nPage;
  Result := SQLITE_OK;
  Exit;

page1_init_failed:
  releasePageOne(pPage1);
  pBt^.pPage1 := nil;
  Result := rc;
end;

{ ===========================================================================
  newDatabase — initialise an empty database (page 1 only)
  btree.c lines 3506-3552
  =========================================================================== }

function newDatabase(pBt: PBtShared): i32;
var
  pP1 : PMemPage;
  data: Pu8;
  rc  : i32;
begin
  if pBt^.nPage > 0 then begin Result := SQLITE_OK; Exit; end;
  pP1  := pBt^.pPage1;
  data := pP1^.aData;
  rc   := sqlite3PagerWrite(pP1^.pDbPage);
  if rc <> SQLITE_OK then begin Result := rc; Exit; end;

  Move(zMagicHeader[0], data^, 16);
  data[16] := u8((pBt^.pageSize shr 8) and $FF);
  data[17] := u8((pBt^.pageSize shr 16) and $FF);
  data[18] := 1;
  data[19] := 1;
  data[20] := u8(pBt^.pageSize - pBt^.usableSize);
  data[21] := 64;
  data[22] := 32;
  data[23] := 32;
  FillChar((data + 24)^, 100 - 24, 0);
  zeroPage(pP1, PTF_INTKEY or PTF_LEAF or PTF_LEAFDATA);
  pBt^.btsFlags := pBt^.btsFlags or BTS_PAGESIZE_FIXED;
  put4byte(data + 36 + 4*4, u32(pBt^.autoVacuum));
  put4byte(data + 36 + 7*4, u32(pBt^.incrVacuum));
  pBt^.nPage := 1;
  data[31] := 1;
  Result := SQLITE_OK;
end;

{ btree.c lines 4499-4505: update nPage from page 1 header }
procedure btreeSetNPage(pBt: PBtShared; pPage1: PMemPage);
var nPage: i32;
begin
  nPage := i32(get4byte(pPage1^.aData + 28));
  if nPage = 0 then
    sqlite3PagerPagecount(pBt^.pPager, @nPage);
  pBt^.nPage := u32(nPage);
end;

{ btree.c ~3553: sqlite3BtreeNewDb }
function sqlite3BtreeNewDb(p: PBtree): i32;
var rc: i32;
begin
  sqlite3BtreeEnter(p);
  p^.pBt^.nPage := 0;
  rc := newDatabase(p^.pBt);
  sqlite3BtreeLeave(p);
  Result := rc;
end;

{ ===========================================================================
  sqlite3BtreeOpen — open or create a B-tree database
  btree.c lines 2528-2917 (simplified: no shared-cache, single connection)
  =========================================================================== }

function sqlite3BtreeOpen(pVfs: Psqlite3_vfs; zFilename: PChar;
                          db: Psqlite3; ppBtree: PPBtree;
                          flags: i32; vfsFlags: i32): i32;
var
  pBt       : PBtShared;
  p         : PBtree;
  rc        : i32;
  zDbHdr    : array[0..99] of u8;
  nReserve  : i32;
  iPageSize : u32;
  label btree_open_out;
begin
  pBt := nil;
  rc  := SQLITE_OK;
  nReserve := -1;

  p := PBtree(sqlite3MallocZero(SizeOf(TBtree)));
  if p = nil then begin Result := SQLITE_NOMEM_BKPT; Exit; end;
  p^.inTrans := TRANS_NONE;
  p^.db      := db;

  pBt := PBtShared(sqlite3MallocZero(SizeOf(TBtShared)));
  if pBt = nil then begin rc := SQLITE_NOMEM_BKPT; goto btree_open_out; end;

  FillChar(zDbHdr[16], 8, 0);

  rc := sqlite3PagerOpen(pVfs, pBt^.pPager, zFilename,
                         SizeOf(TMemPage), flags, vfsFlags, @pageReinit);
  if rc = SQLITE_OK then begin
    rc := sqlite3PagerReadFileheader(pBt^.pPager, 100, @zDbHdr[0]);
  end;
  if rc <> SQLITE_OK then goto btree_open_out;

  pBt^.openFlags := u8(flags);
  pBt^.db        := db;
  sqlite3PagerSetBusyHandler(pBt^.pPager, @btreeInvokeBusyHandler, pBt);
  p^.pBt := pBt;

  if sqlite3PagerIsreadonly(pBt^.pPager) <> 0 then
    pBt^.btsFlags := pBt^.btsFlags or BTS_READ_ONLY;

  { Determine page size from header bytes 16-17.  btree.c:2703..2730 — only
    pin BTS_PAGESIZE_FIXED (and pull nReserve from byte 20) when the header
    carries a valid page size.  An empty/new DB (header zeros) must remain
    pageSize=0 / unfixed so VACUUM's later sqlite3BtreeSetPageSize(pTemp,...)
    is allowed to install the source's page size. }
  iPageSize := (u32(zDbHdr[16]) shl 8) or (u32(zDbHdr[17]) shl 16);
  if (iPageSize < 512) or (iPageSize > SQLITE_MAX_PAGE_SIZE)
     or (((iPageSize - 1) and iPageSize) <> 0) then begin
    iPageSize := 0;
    nReserve  := 0;
  end else begin
    nReserve := i32(zDbHdr[20]);
    pBt^.btsFlags := pBt^.btsFlags or BTS_PAGESIZE_FIXED;
  end;
  rc := sqlite3PagerSetPagesize(pBt^.pPager, @iPageSize, nReserve);
  if rc <> SQLITE_OK then goto btree_open_out;
  pBt^.pageSize   := iPageSize;
  pBt^.usableSize := iPageSize - u32(zDbHdr[20]);
  if pBt^.usableSize < 480 then pBt^.usableSize := iPageSize;

  { Compute local payload limits }
  pBt^.maxLocal := u16((pBt^.usableSize - 12) * 64 div 255 - 23);
  pBt^.minLocal := u16((pBt^.usableSize - 12) * 32 div 255 - 23);
  pBt^.maxLeaf  := u16(pBt^.usableSize - 35);
  pBt^.minLeaf  := pBt^.minLocal;
  if pBt^.maxLocal > 127 then
    pBt^.max1bytePayload := 127
  else
    pBt^.max1bytePayload := u8(pBt^.maxLocal);

  rc := allocateTempSpace(pBt);
  if rc <> SQLITE_OK then goto btree_open_out;

  ppBtree^ := p;
  Result := SQLITE_OK;
  Exit;

btree_open_out:
  if pBt <> nil then begin
    if pBt^.pPager <> nil then
      sqlite3PagerClose(pBt^.pPager, db);
    freeTempSpace(pBt);
    sqlite3_free(pBt);
  end;
  sqlite3_free(p);
  ppBtree^ := nil;
  Result := rc;
end;

{ ===========================================================================
  sqlite3BtreeClose
  btree.c lines 2917-2975 (simplified: no shared-cache)
  =========================================================================== }

function sqlite3BtreeClose(p: PBtree): i32;
var pBt: PBtShared;
begin
  pBt := p^.pBt;
  sqlite3BtreeEnter(p);
  sqlite3BtreeRollback(p, SQLITE_OK, 0);
  sqlite3BtreeLeave(p);
  { No shared-cache list removal needed }
  sqlite3PagerClose(pBt^.pPager, p^.db);
  if pBt^.xFreeSchema <> nil then
    pBt^.xFreeSchema(pBt^.pSchema);
  freeTempSpace(pBt);
  sqlite3_free(pBt);
  sqlite3_free(p);
  Result := SQLITE_OK;
end;

{ btree.c ~10557: sqlite3BtreePager }
function sqlite3BtreePager(p: PBtree): PPager;
begin
  Result := p^.pBt^.pPager;
end;

{ btree.c:11284 — sqlite3BtreeGetFilename.  Return the full pathname of
  the underlying database file.  nullIfTemp=1 mirrors C: temp/in-memory
  files report the empty string. }
function sqlite3BtreeGetFilename(p: PBtree): PAnsiChar;
begin
  Assert(p^.pBt^.pPager <> nil);
  Result := PAnsiChar(sqlite3PagerFilename(p^.pBt^.pPager, 1));
end;

{ ===========================================================================
  Phase 4.4 — Transaction lifecycle
  =========================================================================== }

{ btree.c lines 4467-4497: sqlite3BtreeTripAllCursors }
function sqlite3BtreeTripAllCursors(pBtree: PBtree;
                                    errCode: i32; writeOnly: i32): i32;
var
  p : PBtCursor;
  rc: i32;
begin
  rc := SQLITE_OK;
  if pBtree <> nil then begin
    sqlite3BtreeEnter(pBtree);
    p := pBtree^.pBt^.pCursor;
    while p <> nil do begin
      if (writeOnly <> 0) and ((p^.curFlags and BTCF_WriteFlag) = 0) then begin
        if (p^.eState = CURSOR_VALID) or (p^.eState = CURSOR_SKIPNEXT) then begin
          rc := saveCursorPosition(p);
          if rc <> SQLITE_OK then begin
            sqlite3BtreeTripAllCursors(pBtree, rc, 0);
            break;
          end;
        end;
      end else begin
        sqlite3BtreeClearCursor(p);
        p^.eState    := CURSOR_FAULT;
        p^.skipNext  := errCode;
      end;
      btreeReleaseAllCursorPages(p);
      p := p^.pNext;
    end;
    sqlite3BtreeLeave(pBtree);
  end;
  Result := rc;
end;

{ btree.c lines 4336-4371: btreeEndTransaction }
procedure btreeEndTransaction(p: PBtree);
var pBt: PBtShared;
begin
  pBt := p^.pBt;
  pBt^.bDoTruncate := 0;   { btree.c:4342 — clear at every txn end. }
  { No shared-cache table-lock lists to clear (SQLITE_OMIT_SHARED_CACHE) }
  if p^.inTrans <> TRANS_NONE then begin
    Dec(pBt^.nTransaction);
    if pBt^.nTransaction = 0 then
      pBt^.inTransaction := TRANS_NONE;
  end;
  p^.inTrans := TRANS_NONE;
  unlockBtreeIfUnused(pBt);
end;

{ btree.c lines 3594-3798: btreeBeginTrans (simplified: no shared-cache) }
function btreeBeginTrans(p: PBtree; wrflag: i32; pSchemaVersion: Pi32): i32;
var
  pBt    : PBtShared;
  pPgr   : PPager;
  rc     : i32;
  pPg1   : PMemPage;
  label trans_begun;
begin
  pBt    := p^.pBt;
  pPgr   := pBt^.pPager;
  rc     := SQLITE_OK;
  sqlite3BtreeEnter(p);

  if (p^.inTrans = TRANS_WRITE) or
     ((p^.inTrans = TRANS_READ) and (wrflag = 0)) then begin
    { already in requested mode }
    goto trans_begun;
  end;

  { btree.c:3621..3625 — write transactions are not possible on a
    read-only database; reads ARE allowed.  Bug 9.2.divbug.A: the
    previous Pas arm omitted the `wrflag` conjunct, so every read-only
    open also tripped SQLITE_READONLY on the first SELECT's
    OP_Transaction prologue. }
  if ((pBt^.btsFlags and BTS_READ_ONLY) <> 0) and (wrflag <> 0) then begin
    rc := SQLITE_READONLY;
    goto trans_begun;
  end;

  pBt^.btsFlags := pBt^.btsFlags and not BTS_INITIALLY_EMPTY;
  if pBt^.nPage = 0 then
    pBt^.btsFlags := pBt^.btsFlags or BTS_INITIALLY_EMPTY;

  repeat
    { Lock: read page 1 and init BtShared if not done yet }
    while (pBt^.pPage1 = nil) do begin
      rc := lockBtree(pBt);
      if rc <> SQLITE_OK then break;
    end;

    if rc = SQLITE_OK then begin
      if wrflag <> 0 then begin
        { btree.c:3709..3723 — second BTS_READ_ONLY gate AFTER lockBtree.
          lockBtree may have just set BTS_READ_ONLY after re-reading
          page 1 following a change-counter mismatch (test rdonly-1.6);
          without this post-lock check, sqlite3PagerBegin runs and the
          write succeeds against a now-readonly db (9.4.divbug.81). }
        if (pBt^.btsFlags and BTS_READ_ONLY) <> 0 then
          rc := SQLITE_READONLY
        else begin
          rc := sqlite3PagerBegin(pPgr, ord(wrflag > 1), 0);
          if rc = SQLITE_OK then
            rc := newDatabase(pBt);
        end;
      end;
    end;

    if rc <> SQLITE_OK then
      unlockBtreeIfUnused(pBt);
  { btree.c:3736..3737 — retry only while BUSY *and* no transaction was
    already open *and* the busy-handler asks us to try again.  The two
    latter conjuncts were previously dropped, so a BUSY with no busy
    handler installed spun forever (9.4.divbug.21). }
  until ((rc and $FF) <> SQLITE_BUSY) or
        (pBt^.inTransaction <> TRANS_NONE) or
        (btreeInvokeBusyHandler(pBt) = 0);

  if rc = SQLITE_OK then begin
    if p^.inTrans = TRANS_NONE then
      Inc(pBt^.nTransaction);
    if wrflag <> 0 then
      p^.inTrans := TRANS_WRITE
    else
      p^.inTrans := TRANS_READ;
    if p^.inTrans > pBt^.inTransaction then
      pBt^.inTransaction := p^.inTrans;
    if wrflag <> 0 then begin
      pPg1 := pBt^.pPage1;
      { Sync nPage in header with pBt^.nPage }
      if pBt^.nPage <> get4byte(pPg1^.aData + 28) then begin
        rc := sqlite3PagerWrite(pPg1^.pDbPage);
        if rc = SQLITE_OK then
          put4byte(pPg1^.aData + 28, pBt^.nPage);
      end;
    end;
  end;

trans_begun:
  if rc = SQLITE_OK then begin
    if pSchemaVersion <> nil then
      pSchemaVersion^ := i32(get4byte(pBt^.pPage1^.aData + 40));
    if wrflag <> 0 then begin
      { btree.c:3793 — make sure the pager has the correct number of open
        savepoints.  Previously this call passed 0 unconditionally, so the
        pager savepoint stack was never populated and ROLLBACK TO sN
        could not unwind.  Closes 6.10 step 15(c). }
      if (p^.db <> nil) and (PTsqlite3(p^.db)^.nSavepoint > 0) then
        rc := sqlite3PagerOpenSavepoint(pPgr, PTsqlite3(p^.db)^.nSavepoint)
      else
        rc := sqlite3PagerOpenSavepoint(pPgr, 0);
    end;
  end;
  sqlite3BtreeLeave(p);
  Result := rc;
end;

{ btree.c lines 3801-3812: sqlite3BtreeBeginTrans public wrapper }
function sqlite3BtreeBeginTrans(p: PBtree; wrflag: i32;
                                 pSchemaVersion: Pi32): i32;
begin
  if (p^.inTrans = TRANS_NONE) or
     ((p^.inTrans = TRANS_READ) and (wrflag <> 0)) then
    Result := btreeBeginTrans(p, wrflag, pSchemaVersion)
  else begin
    if pSchemaVersion <> nil then
      pSchemaVersion^ := i32(get4byte(p^.pBt^.pPage1^.aData + 40));
    if (wrflag <> 0) and (p^.db <> nil) then
      Result := sqlite3PagerOpenSavepoint(p^.pBt^.pPager,
                  PTsqlite3(p^.db)^.nSavepoint)
    else
      Result := SQLITE_OK;
  end;
end;

{ autoVacuumCommit — forward; implemented after PTRMAP_ISPAGE /
  incrVacuumStep / finalDbSize (all inline or below in same unit). }
function autoVacuumCommit(p: PBtree): i32; forward;

{ btree.c lines 4309-4328: sqlite3BtreeCommitPhaseOne }
function sqlite3BtreeCommitPhaseOne(p: PBtree; zSuperJrnl: PChar): i32;
var rc: i32;
begin
  rc := SQLITE_OK;
  if p^.inTrans = TRANS_WRITE then begin
    sqlite3BtreeEnter(p);
    if p^.pBt^.autoVacuum <> 0 then begin
      rc := autoVacuumCommit(p);
      if rc <> SQLITE_OK then begin
        sqlite3BtreeLeave(p);
        Result := rc;
        Exit;
      end;
    end;
    if p^.pBt^.bDoTruncate <> 0 then
      sqlite3PagerTruncateImage(p^.pBt^.pPager, p^.pBt^.nPage);
    rc := sqlite3PagerCommitPhaseOne(p^.pBt^.pPager, zSuperJrnl, 0);
    sqlite3BtreeLeave(p);
  end;
  Result := rc;
end;

{ btree.c lines 4398-4429: sqlite3BtreeCommitPhaseTwo }
function sqlite3BtreeCommitPhaseTwo(p: PBtree; bCleanup: i32): i32;
var rc: i32;
begin
  if p^.inTrans = TRANS_NONE then begin Result := SQLITE_OK; Exit; end;
  sqlite3BtreeEnter(p);
  if p^.inTrans = TRANS_WRITE then begin
    rc := sqlite3PagerCommitPhaseTwo(p^.pBt^.pPager);
    if (rc <> SQLITE_OK) and (bCleanup = 0) then begin
      sqlite3BtreeLeave(p);
      Result := rc;
      Exit;
    end;
    Dec(p^.iBDataVersion);   { compensate for pager DataVersion++ }
    p^.pBt^.inTransaction := TRANS_READ;
    btreeClearHasContent(p^.pBt);
  end;
  btreeEndTransaction(p);
  sqlite3BtreeLeave(p);
  Result := SQLITE_OK;
end;

{ btree.c lines 4430-4440: sqlite3BtreeCommit }
function sqlite3BtreeCommit(p: PBtree): i32;
var rc: i32;
begin
  sqlite3BtreeEnter(p);
  rc := sqlite3BtreeCommitPhaseOne(p, nil);
  if rc = SQLITE_OK then
    rc := sqlite3BtreeCommitPhaseTwo(p, 0);
  sqlite3BtreeLeave(p);
  Result := rc;
end;

{ btree.c lines 4518-4562: sqlite3BtreeRollback }
function sqlite3BtreeRollback(p: PBtree; tripCode: i32; writeOnly: i32): i32;
var
  rc    : i32;
  rc2   : i32;
  pBt   : PBtShared;
  pPg1  : PMemPage;
begin
  rc  := SQLITE_OK;
  pBt := p^.pBt;
  sqlite3BtreeEnter(p);
  if tripCode = SQLITE_OK then begin
    rc := saveAllCursors(pBt, 0, nil);
    if rc <> SQLITE_OK then writeOnly := 0;
  end else
    rc := SQLITE_OK;

  if tripCode <> SQLITE_OK then begin
    rc2 := sqlite3BtreeTripAllCursors(p, tripCode, writeOnly);
    if rc2 <> SQLITE_OK then rc := rc2;
  end;

  if p^.inTrans = TRANS_WRITE then begin
    rc2 := sqlite3PagerRollback(pBt^.pPager);
    if rc2 <> SQLITE_OK then rc := rc2;
    if btreeGetPage(pBt, 1, pPg1, 0) = SQLITE_OK then begin
      btreeSetNPage(pBt, pPg1);
      releasePageOne(pPg1);
    end;
    pBt^.inTransaction := TRANS_READ;
    btreeClearHasContent(pBt);
  end;
  btreeEndTransaction(p);
  sqlite3BtreeLeave(p);
  Result := rc;
end;

{ btree.c:4614 — sqlite3BtreeSavepoint.
  Release / rollback to the named statement-savepoint of a write txn.
  No-op for read-only / no-txn btrees. }
function sqlite3BtreeSavepoint(p: PBtree; op: i32; iSavepoint: i32): i32;
var
  rc  : i32;
  pBt : PBtShared;
  pP1 : PMemPage;
begin
  rc := SQLITE_OK;
  if (p <> nil) and (p^.inTrans = TRANS_WRITE) then begin
    pBt := p^.pBt;
    sqlite3BtreeEnter(p);
    if op = SAVEPOINT_ROLLBACK then
      rc := saveAllCursors(pBt, 0, nil);
    if rc = SQLITE_OK then
      rc := sqlite3PagerSavepoint(pBt^.pPager, op, iSavepoint);
    if rc = SQLITE_OK then begin
      if (iSavepoint < 0) and ((pBt^.btsFlags and BTS_INITIALLY_EMPTY) <> 0) then
        pBt^.nPage := 0;
      rc := newDatabase(pBt);
      pP1 := pBt^.pPage1;
      if pP1 <> nil then btreeSetNPage(pBt, pP1);
    end;
    sqlite3BtreeLeave(p);
  end;
  Result := rc;
end;

{ ===========================================================================
  Phase 4.4 — sqlite3BtreeDelete
  btree.c lines 9826-10024
  =========================================================================== }

function sqlite3BtreeDelete(pCur: PBtCursor; flags: u8): i32;
var
  p          : PBtree;
  pBt        : PBtShared;
  rc         : i32;
  pPage      : PMemPage;
  pCell      : Pu8;
  iCellIdx   : i32;
  iCellDepth : i32;
  info       : TCellInfo;
  bPreserve  : u8;
  pLeaf      : PMemPage;
  nCell      : i32;
  n          : Pgno;
  pTmp       : Pu8;
begin
  p   := pCur^.pBtree;
  pBt := p^.pBt;
  rc  := SQLITE_OK;

  if pCur^.eState <> CURSOR_VALID then begin
    if pCur^.eState >= CURSOR_REQUIRESEEK then begin
      rc := btreeRestoreCursorPosition(pCur);
      if (rc <> SQLITE_OK) or (pCur^.eState <> CURSOR_VALID) then begin
        Result := rc; Exit;
      end;
    end else begin
      Result := SQLITE_CORRUPT_BKPT; Exit;
    end;
  end;

  iCellDepth := i32(pCur^.iPage);
  iCellIdx   := i32(pCur^.ix);
  pPage      := pCur^.pPage;

  if i32(pPage^.nCell) <= iCellIdx then begin
    Result := CORRUPT_PAGE(pPage); Exit;
  end;
  pCell := findCell(pPage, iCellIdx);
  if pPage^.nFree < 0 then begin
    if btreeComputeFreeSpace(pPage) <> SQLITE_OK then begin
      Result := CORRUPT_PAGE(pPage); Exit;
    end;
  end;
  if PtrUInt(pCell) < PtrUInt(pPage^.aCellIdx + pPage^.nCell * 2) then begin
    Result := CORRUPT_PAGE(pPage); Exit;
  end;

  { Determine if cursor position must be preserved.
    btree.c:9885 — `bPreserve = (flags & BTREE_SAVEPOSITION)!=0;` is a
    *boolean* 0/1, NOT the raw masked bit.  The final arm tests
    `bPreserve > 1`, so on the saveCursorKey path bPreserve must stay 1;
    masking alone leaves it at BTREE_SAVEPOSITION (=2) and wrongly takes
    the CURSOR_SKIPNEXT arm even when a rebalance occurs (9.4.divbug.8). }
  bPreserve := u8(ord((flags and BTREE_SAVEPOSITION) <> 0));
  if bPreserve <> 0 then begin
    if (pPage^.leaf = 0) or
       (i32(pPage^.nFree) + i32(pPage^.xCellSize(pPage, pCell)) + 2 >
        i32(pBt^.usableSize) * 2 div 3) or
       (pPage^.nCell = 1) then begin
      rc := saveCursorKey(pCur);
      if rc <> SQLITE_OK then begin Result := rc; Exit; end;
    end else
      bPreserve := 2;
  end;

  { If internal node: move to predecessor (largest in left sub-tree) }
  if pPage^.leaf = 0 then begin
    rc := sqlite3BtreePrevious(pCur, 0);
    if rc <> SQLITE_OK then begin Result := rc; Exit; end;
  end;

  { Save other cursors on this table }
  if (pCur^.curFlags and BTCF_Multiple) <> 0 then begin
    rc := saveAllCursors(pBt, pCur^.pgnoRoot, pCur);
    if rc <> SQLITE_OK then begin Result := rc; Exit; end;
  end;

  { Invalidate incrblob cursors (no-op stub in this port) }
  if (pCur^.pKeyInfo = nil) and (p^.hasIncrblobCur <> 0) then
    invalidateIncrblobCursors(p, pCur^.pgnoRoot, pCur^.info.nKey, 0);

  { Make page writable, clear overflow pages, drop cell }
  rc := sqlite3PagerWrite(pPage^.pDbPage);
  if rc <> SQLITE_OK then begin Result := rc; Exit; end;

  BTREE_CLEAR_CELL(rc, pPage, pCell, info);
  if rc <> SQLITE_OK then begin Result := rc; Exit; end;

  dropCell(pPage, iCellIdx, i32(info.nSize), @rc);
  if rc <> SQLITE_OK then begin Result := rc; Exit; end;

  { If we deleted from an internal node, move the leaf predecessor cell up }
  if pPage^.leaf = 0 then begin
    pLeaf := pCur^.pPage;
    if pLeaf^.nFree < 0 then begin
      rc := btreeComputeFreeSpace(pLeaf);
      if rc <> SQLITE_OK then begin Result := rc; Exit; end;
    end;
    if iCellDepth < i32(pCur^.iPage) - 1 then
      n := pCur^.apPage[iCellDepth + 1]^.pgno
    else
      n := pCur^.pPage^.pgno;
    pCell := findCell(pLeaf, i32(pLeaf^.nCell) - 1);
    if PtrUInt(pCell) < PtrUInt(pLeaf^.aData + 4) then begin
      Result := CORRUPT_PAGE(pLeaf); Exit;
    end;
    nCell := i32(pLeaf^.xCellSize(pLeaf, pCell));
    pTmp  := pBt^.pTmpSpace;
    rc := sqlite3PagerWrite(pLeaf^.pDbPage);
    if rc = SQLITE_OK then
      rc := insertCell(pPage, iCellIdx, pCell - 4, nCell + 4, pTmp, n);
    dropCell(pLeaf, i32(pLeaf^.nCell) - 1, nCell, @rc);
    if rc <> SQLITE_OK then begin Result := rc; Exit; end;
  end;

  { Rebalance.  Skip if free space is < 2/3 of usable (balance is no-op). }
  if (i32(pCur^.pPage^.nFree) * 3) <= i32(pCur^.pBt^.usableSize) * 2 then
    rc := SQLITE_OK
  else
    rc := balance(pCur);

  if (rc = SQLITE_OK) and (i32(pCur^.iPage) > iCellDepth) then begin
    releasePageNotNull(pCur^.pPage);
    Dec(pCur^.iPage);
    while i32(pCur^.iPage) > iCellDepth do begin
      releasePage(pCur^.apPage[pCur^.iPage]);
      Dec(pCur^.iPage);
    end;
    pCur^.pPage := pCur^.apPage[pCur^.iPage];
    rc := balance(pCur);
  end;

  if rc = SQLITE_OK then begin
    if bPreserve > 1 then begin
      pCur^.eState := CURSOR_SKIPNEXT;
      if iCellIdx >= i32(pPage^.nCell) then begin
        pCur^.skipNext := -1;
        pCur^.ix       := u16(pPage^.nCell - 1);
      end else
        pCur^.skipNext := 1;
    end else begin
      rc := moveToRoot(pCur);
      if bPreserve <> 0 then begin
        btreeReleaseAllCursorPages(pCur);
        pCur^.eState := CURSOR_REQUIRESEEK;
      end;
      if rc = SQLITE_EMPTY then rc := SQLITE_OK;
    end;
  end;

  Result := rc;
end;

{ ===========================================================================
  Phase 4.5 — Schema / metadata helpers
  =========================================================================== }

{ btree.c lines 10228-10286: clearDatabasePage (recursive) }
function clearDatabasePage(pBt: PBtShared; pgno: Pgno;
                            freePageFlag: i32; pnChange: Pi64): i32;
var
  pPage : PMemPage;
  rc    : i32;
  pCell : Pu8;
  i     : i32;
  hdr   : i32;
  info  : TCellInfo;
  label cleardatabasepage_out;
begin
  pPage := nil;
  rc    := SQLITE_OK;

  if pgno > btreePagecount(pBt) then begin
    Result := SQLITE_CORRUPT_BKPT; Exit;
  end;
  rc := getAndInitPage(pBt, pgno, pPage, 0);
  if rc <> SQLITE_OK then begin Result := rc; Exit; end;

  { Verify refcount (not BTREE_SINGLE: single-file db has refcount check) }
  if (pBt^.openFlags and BTREE_SINGLE) = 0 then begin
    if sqlite3PagerPageRefcount(pPage^.pDbPage) <>
       i32(1 + ord(pgno = 1)) then begin
      rc := CORRUPT_PAGE(pPage);
      goto cleardatabasepage_out;
    end;
  end;

  hdr := pPage^.hdrOffset;
  for i := 0 to i32(pPage^.nCell) - 1 do begin
    pCell := findCell(pPage, i);
    if pPage^.leaf = 0 then begin
      rc := clearDatabasePage(pBt, get4byte(pCell), 1, pnChange);
      if rc <> SQLITE_OK then goto cleardatabasepage_out;
    end;
    BTREE_CLEAR_CELL(rc, pPage, pCell, info);
    if rc <> SQLITE_OK then goto cleardatabasepage_out;
  end;

  if pPage^.leaf = 0 then begin
    rc := clearDatabasePage(pBt, get4byte(pPage^.aData + hdr + 8), 1, pnChange);
    if rc <> SQLITE_OK then goto cleardatabasepage_out;
    if pPage^.intKey <> 0 then pnChange := nil;
  end;

  if pnChange <> nil then
    Inc(pnChange^, pPage^.nCell);

  if freePageFlag <> 0 then
    freePage(pPage, @rc)
  else begin
    rc := sqlite3PagerWrite(pPage^.pDbPage);
    if rc = SQLITE_OK then
      zeroPage(pPage, i32(pPage^.aData[hdr]) or PTF_LEAF);
  end;

cleardatabasepage_out:
  releasePage(pPage);
  Result := rc;
end;

{ btree.c lines 10263-10287: sqlite3BtreeClearTable }
function sqlite3BtreeClearTable(p: PBtree; iTable: i32; pnChange: Pi64): i32;
var
  rc : i32;
  pBt: PBtShared;
begin
  pBt := p^.pBt;
  sqlite3BtreeEnter(p);
  rc := saveAllCursors(pBt, Pgno(iTable), nil);
  if rc = SQLITE_OK then begin
    if p^.hasIncrblobCur <> 0 then
      invalidateIncrblobCursors(p, Pgno(iTable), 0, 1);
    rc := clearDatabasePage(pBt, Pgno(iTable), 0, pnChange);
  end;
  sqlite3BtreeLeave(p);
  Result := rc;
end;

{ btree.c lines 10289-10290: sqlite3BtreeClearTableOfCursor }
function sqlite3BtreeClearTableOfCursor(pCur: PBtCursor): i32;
begin
  Result := sqlite3BtreeClearTable(pCur^.pBtree, i32(pCur^.pgnoRoot), nil);
end;

{ btree.c lines 10325-10397: btreeDropTable (simplified: SQLITE_OMIT_AUTOVACUUM) }
function btreeDropTable(p: PBtree; iTable: Pgno; piMoved: Pi32): i32;
var
  pPage: PMemPage;
  pBt  : PBtShared;
  rc   : i32;
begin
  pPage := nil;
  pBt   := p^.pBt;
  rc    := SQLITE_OK;

  if iTable > btreePagecount(pBt) then begin
    Result := SQLITE_CORRUPT_BKPT; Exit;
  end;
  rc := sqlite3BtreeClearTable(p, i32(iTable), nil);
  if rc <> SQLITE_OK then begin Result := rc; Exit; end;

  rc := btreeGetPage(pBt, iTable, pPage, 0);
  if rc <> SQLITE_OK then begin Result := rc; Exit; end;

  piMoved^ := 0;
  { No autovacuum: just free the page }
  freePage(pPage, @rc);
  releasePage(pPage);
  Result := rc;
end;

{ btree.c lines 10398-10427: sqlite3BtreeDropTable public wrapper }
function sqlite3BtreeDropTable(p: PBtree; iTable: i32; piMoved: Pi32): i32;
var rc: i32;
begin
  sqlite3BtreeEnter(p);
  rc := btreeDropTable(p, Pgno(iTable), piMoved);
  sqlite3BtreeLeave(p);
  Result := rc;
end;

{ btree.c lines 10039-10182: btreeCreateTable.  Full port including the
  !SQLITE_OMIT_AUTOVACUUM arm — the new root-page must be relocated past
  any pointer-map / pending-byte page and recorded in the ptrmap and
  meta[4] (BTREE_LARGEST_ROOT_PAGE). }
function btreeCreateTable(p: PBtree; piTable: PPgno; createTabFlags: i32): i32;
var
  pBt      : PBtShared;
  pRoot    : PMemPage;
  pgnoRoot : Pgno;
  rc       : i32;
  ptfFlags : i32;
  pgnoMove : Pgno;
  pPageMove: PMemPage;
  eType    : u8;
  iPtrPage : Pgno;
begin
  pBt      := p^.pBt;
  pRoot    := nil;
  pgnoRoot := 0;
  rc := SQLITE_OK;

  if pBt^.autoVacuum <> 0 then begin
    { btree.c:10055..10153 — autovacuum root-page allocation. }
    invalidateAllOverflowCache(pBt);

    sqlite3BtreeGetMeta(p, BTREE_LARGEST_ROOT_PAGE, @pgnoRoot);
    if pgnoRoot > btreePagecount(pBt) then begin
      Result := SQLITE_CORRUPT_BKPT;
      Exit;
    end;
    Inc(pgnoRoot);

    { The new root-page may not be a pointer-map page or the pending-byte
      page. }
    while (pgnoRoot = ptrmapPageno(pBt, pgnoRoot)) or
          (pgnoRoot = PENDING_BYTE_PAGE(pBt)) do
      Inc(pgnoRoot);
    Assert(pgnoRoot >= 3);

    pPageMove := nil;
    pgnoMove  := 0;
    rc := allocateBtreePage(pBt, pPageMove, pgnoMove, pgnoRoot, BTALLOC_EXACT);
    if rc <> SQLITE_OK then begin Result := rc; Exit; end;

    if pgnoMove <> pgnoRoot then begin
      eType    := 0;
      iPtrPage := 0;

      rc := saveAllCursors(pBt, 0, nil);
      releasePage(pPageMove);
      if rc <> SQLITE_OK then begin Result := rc; Exit; end;

      rc := btreeGetPage(pBt, pgnoRoot, pRoot, 0);
      if rc <> SQLITE_OK then begin Result := rc; Exit; end;
      rc := ptrmapGet(pBt, pgnoRoot, eType, iPtrPage);
      if (eType = PTRMAP_ROOTPAGE) or (eType = PTRMAP_FREEPAGE) then
        rc := SQLITE_CORRUPT_BKPT;
      if rc <> SQLITE_OK then begin
        releasePage(pRoot);
        Result := rc;
        Exit;
      end;
      Assert(eType <> PTRMAP_ROOTPAGE);
      Assert(eType <> PTRMAP_FREEPAGE);
      rc := relocatePage(pBt, pRoot, eType, iPtrPage, pgnoMove, 0);
      releasePage(pRoot);
      if rc <> SQLITE_OK then begin Result := rc; Exit; end;
      rc := btreeGetPage(pBt, pgnoRoot, pRoot, 0);
      if rc <> SQLITE_OK then begin Result := rc; Exit; end;
      rc := sqlite3PagerWrite(pRoot^.pDbPage);
      if rc <> SQLITE_OK then begin
        releasePage(pRoot);
        Result := rc;
        Exit;
      end;
    end else
      pRoot := pPageMove;

    ptrmapPut(pBt, pgnoRoot, PTRMAP_ROOTPAGE, 0, @rc);
    if rc <> SQLITE_OK then begin
      releasePage(pRoot);
      Result := rc;
      Exit;
    end;

    rc := sqlite3BtreeUpdateMeta(p, 4, pgnoRoot);
    if rc <> SQLITE_OK then begin
      releasePage(pRoot);
      Result := rc;
      Exit;
    end;
  end else begin
    { No autovacuum: allocate page normally }
    rc := allocateBtreePage(pBt, pRoot, pgnoRoot, 1, 0);
    if rc <> SQLITE_OK then begin Result := rc; Exit; end;

    rc := sqlite3PagerWrite(pRoot^.pDbPage);
    if rc <> SQLITE_OK then begin
      releasePage(pRoot);
      Result := rc;
      Exit;
    end;
  end;

  if (createTabFlags and BTREE_INTKEY) <> 0 then
    ptfFlags := PTF_INTKEY or PTF_LEAFDATA or PTF_LEAF
  else
    ptfFlags := PTF_ZERODATA or PTF_LEAF;
  zeroPage(pRoot, ptfFlags);
  sqlite3PagerUnref(pRoot^.pDbPage);
  piTable^ := pgnoRoot;
  Result := SQLITE_OK;
end;

{ btree.c lines 10184-10188: sqlite3BtreeCreateTable public wrapper }
function sqlite3BtreeCreateTable(p: PBtree; piTable: PPgno; flags: i32): i32;
var rc: i32;
begin
  sqlite3BtreeEnter(p);
  rc := btreeCreateTable(p, piTable, flags);
  sqlite3BtreeLeave(p);
  Result := rc;
end;

{ btree.c lines 10427-10455: sqlite3BtreeGetMeta }
procedure sqlite3BtreeGetMeta(p: PBtree; idx: i32; pMeta: Pu32);
var pBt: PBtShared;
begin
  pBt := p^.pBt;
  sqlite3BtreeEnter(p);
  if idx = BTREE_DATA_VERSION then
    pMeta^ := sqlite3PagerDataVersion(pBt^.pPager) + p^.iBDataVersion
  else
    pMeta^ := get4byte(pBt^.pPage1^.aData + 36 + idx * 4);
  sqlite3BtreeLeave(p);
end;

{ btree.c lines 10457-10480: sqlite3BtreeUpdateMeta }
function sqlite3BtreeUpdateMeta(p: PBtree; idx: i32; iMeta: u32): i32;
var
  pBt : PBtShared;
  pP1 : Pu8;
  rc  : i32;
begin
  pBt := p^.pBt;
  sqlite3BtreeEnter(p);
  pP1 := pBt^.pPage1^.aData;
  rc := sqlite3PagerWrite(pBt^.pPage1^.pDbPage);
  if rc = SQLITE_OK then begin
    put4byte(pP1 + 36 + idx * 4, iMeta);
    if idx = BTREE_INCR_VACUUM then begin
      pBt^.incrVacuum := u8(iMeta and 1);
    end;
  end;
  sqlite3BtreeLeave(p);
  Result := rc;
end;

{ btree.c lines 10481-10555: sqlite3BtreeCount }
function sqlite3BtreeCount(db: Pointer; pCur: PBtCursor; pnEntry: Pi64): i32;
var
  nEntry: i64;
  rc    : i32;
  iIdx  : i32;
  pPage : PMemPage;
begin
  nEntry := 0;
  rc := moveToRoot(pCur);
  if rc = SQLITE_EMPTY then begin
    pnEntry^ := 0;
    Result := SQLITE_OK;
    Exit;
  end;

  while rc = SQLITE_OK do begin
    pPage := pCur^.pPage;
    if (pPage^.leaf <> 0) or (pPage^.intKey = 0) then
      Inc(nEntry, pPage^.nCell);

    if pPage^.leaf <> 0 then begin
      { leaf: walk back up until we find an unvisited interior cell }
      repeat
        if pCur^.iPage = 0 then begin
          pnEntry^ := nEntry;
          Result := moveToRoot(pCur);
          Exit;
        end;
        moveToParent(pCur);
      until pCur^.ix < pCur^.pPage^.nCell;
      Inc(pCur^.ix);
      pPage := pCur^.pPage;
    end;

    iIdx := i32(pCur^.ix);
    if iIdx = i32(pPage^.nCell) then
      rc := moveToChild(pCur, get4byte(pPage^.aData + pPage^.hdrOffset + 8))
    else
      rc := moveToChild(pCur, get4byte(findCell(pPage, iIdx)));
  end;

  Result := rc;
end;

{ btree.c:6275 — row count estimate from current page only }
function sqlite3BtreeRowCountEst(pCur: PBtCursor): i64;
var
  est: i64;
  j:   u8;
begin
  if pCur^.eState <> CURSOR_VALID then begin Result := 0; Exit; end;
  est := pCur^.pPage^.nCell;
  j := 0;
  while j < u8(pCur^.iPage) do begin
    est := est * (pCur^.apPage[j]^.nCell + 1);
    Inc(j);
  end;
  Result := est;
end;

{ btree.c — check if the b-tree table addressed by pCur is empty.
  Sets pRes^ to 1 if empty, 0 if it contains at least one row.
  Returns a SQLite error code. }
function sqlite3BtreeIsEmpty(pCur: PBtCursor; pRes: Pi32): i32;
begin
  Result := sqlite3BtreeFirst(pCur, pRes);
end;

{ btree.c:952 — return a fake cursor that is always CURSOR_VALID.
  Used by NullRow to give OP_Column something to call HasMoved on. }
var
  gFakeCursorState: u8 = CURSOR_VALID;

function sqlite3BtreeFakeValidCursor: PBtCursor;
begin
  { eState is the first field of TBtCursor (offset 0); we return a pointer
    to a static byte that holds CURSOR_VALID.  Callers only call
    sqlite3BtreeCursorHasMoved / sqlite3BtreeClearCursor on this. }
  Result := PBtCursor(@gFakeCursorState);
end;


{ btree.c:9712 — transfer a row from source to destination cursor.
  Used by OP_RowCell to efficiently copy a row from one B-tree to another.
  This function pre-formats the cell in pBt^.pTmpSpace and sets nPreformatSize. }
function sqlite3BtreeTransferRow(pDest, pSrc: PBtCursor; iKey: i64): i32;
var
  pBt: PBtShared;
  aOut: Pu8;
  aIn: Pu8;
  nIn: u32;
  nRem: u32;
  nOut: u32;
  rc: i32;
  pSrcPager: PPager;
  pPgnoOut: Pu8;
  ovflIn: Pgno;
  pPageIn: PDbPage;
  pPageOut: PMemPage;
  pNew: PMemPage;
  pgnoNew: Pgno;
  nCopy: i32;
begin
  pBt := pDest^.pBt;
  aOut := pBt^.pTmpSpace;
  rc := SQLITE_OK;
  pPageIn := nil;
  pPageOut := nil;

  getCellInfo(pSrc);
  
  { Write payload size varint }
  if pSrc^.info.nPayload < $80 then begin
    aOut^ := u8(pSrc^.info.nPayload);
    Inc(aOut);
  end else begin
    Inc(aOut, sqlite3PutVarint(aOut, u64(pSrc^.info.nPayload)));
  end;
  
  { Write rowid for table B-trees (not index B-trees) }
  if pDest^.pKeyInfo = nil then
    Inc(aOut, sqlite3PutVarint(aOut, u64(iKey)));
  
  nIn := pSrc^.info.nLocal;
  aIn := pSrc^.info.pPayload;
  
  { Corruption check }
  if Pu8(aIn + nIn) > pSrc^.pPage^.aDataEnd then begin
    Result := CORRUPT_PAGE(pSrc^.pPage);
    Exit;
  end;
  
  nRem := pSrc^.info.nPayload;
  
  { Simple case: all payload fits locally in destination }
  if (nIn = nRem) and (nIn < u32(pDest^.pPage^.maxLocal)) then begin
    Move(aIn^, aOut^, nIn);
    pBt^.nPreformatSize := i32(nIn) + i32(aOut - pBt^.pTmpSpace);
    Result := SQLITE_OK;
    Exit;
  end;
  
  { Complex case: overflow pages involved }
  pSrcPager := pSrc^.pBt^.pPager;
  pPgnoOut := nil;
  ovflIn := 0;
  
  nOut := u32(btreePayloadToLocal(pDest^.pPage, pSrc^.info.nPayload));
  pBt^.nPreformatSize := i32(nOut) + i32(aOut - pBt^.pTmpSpace);
  
  if nOut < u32(pSrc^.info.nPayload) then begin
    pPgnoOut := @aOut[nOut];
    Inc(pBt^.nPreformatSize, 4);
  end;
  
  if nRem > nIn then begin
    if Pu8(aIn + nIn + 4) > pSrc^.pPage^.aDataEnd then begin
      Result := CORRUPT_PAGE(pSrc^.pPage);
      Exit;
    end;
    ovflIn := get4byte(@pSrc^.info.pPayload[nIn]);
  end;
  
  { Main copy loop }
  while (nRem > 0) and (rc = SQLITE_OK) do begin
    Dec(nRem, nOut);
    
    { Copy data to output buffer }
    while (nOut > 0) and (rc = SQLITE_OK) do begin
      if nIn > 0 then begin
        nCopy := i32(sqlite3_min(i64(nOut), i64(nIn)));
        Move(aIn^, aOut^, nCopy);
        Dec(nOut, nCopy);
        Dec(nIn, nCopy);
        Inc(aOut, nCopy);
        Inc(aIn, nCopy);
      end;
      
      if nOut > 0 then begin
        sqlite3PagerUnref(pPageIn);
        pPageIn := nil;
        rc := sqlite3PagerGet(pSrcPager, ovflIn, PPDbPage(@pPageIn), PAGER_GET_READONLY);
        if rc = SQLITE_OK then begin
          aIn := sqlite3PagerGetData(pPageIn);
          ovflIn := get4byte(aIn);
          Inc(aIn, 4);
          nIn := pSrc^.pBt^.usableSize - 4;
        end;
      end;
    end;
    
    { Allocate overflow page if needed }
    if (rc = SQLITE_OK) and (nRem > 0) and (pPgnoOut <> nil) then begin
      rc := allocateBtreePage(pBt, pNew, pgnoNew, 0, 0);
      put4byte(pPgnoOut, pgnoNew);
      if ISAUTOVACUUM(pBt) and (pPageOut <> nil) then
        ptrmapPut(pBt, pgnoNew, PTRMAP_OVERFLOW2, pPageOut^.pgno, @rc);
      releasePage(pPageOut);
      pPageOut := pNew;
      if pPageOut <> nil then begin
        pPgnoOut := pPageOut^.aData;
        put4byte(pPgnoOut, 0);
        aOut := @pPgnoOut[4];
        nOut := u32(sqlite3_min(i64(pBt^.usableSize - 4), i64(nRem)));
      end;
    end;
  end;
  
  releasePage(pPageOut);
  sqlite3PagerUnref(pPageIn);
  Result := rc;
end;

{ ===========================================================================
  Phase 5.4 — Additional btree helpers
  =========================================================================== }

{ btree.c:2367 }
function sqlite3BtreeLastPage(p: PBtree): Pgno;
begin
  Result := btreePagecount(p^.pBt);
end;

{ btree.c:3151 }
function sqlite3BtreeMaxPageCount(p: PBtree; mxPage: Pgno): Pgno;
begin
  sqlite3BtreeEnter(p);
  Result := sqlite3PagerMaxPageCount(p^.pBt^.pPager, mxPage);
  sqlite3BtreeLeave(p);
end;

{ btree.c:11400 — shared-cache lock; no-op when SQLITE_OMIT_SHARED_CACHE }
function sqlite3BtreeLockTable(p: PBtree; iTab: i32; isWriteLock: u8): i32;
begin
  Result := SQLITE_OK;
  { shared-cache table locking not implemented in this port }
end;

{ btree.c:4928 }
procedure sqlite3BtreeCursorPin(pCur: PBtCursor);
begin
  pCur^.curFlags := pCur^.curFlags or BTCF_Pinned;
end;

{ btree.c:4932 }
procedure sqlite3BtreeCursorUnpin(pCur: PBtCursor);
begin
  pCur^.curFlags := pCur^.curFlags and not u8(BTCF_Pinned);
end;

{ ===========================================================================
  Phase 8.7 — accessors required by backup.c
  =========================================================================== }

{ btree.c:3236 }
function sqlite3BtreeGetPageSize(p: PBtree): i32;
begin
  Result := i32(p^.pBt^.pageSize);
end;

{ btree.c:3002 — sqlite3BtreeSetSpillSize. }
function sqlite3BtreeSetSpillSize(p: PBtree; mxPage: i32): i32;
var pBt: PBtShared;
begin
  pBt := p^.pBt;
  sqlite3BtreeEnter(p);
  Result := sqlite3PagerSetSpillsize(pBt^.pPager, mxPage);
  sqlite3BtreeLeave(p);
end;

{ btree.c:2986 — sqlite3BtreeSetCacheSize. }
procedure sqlite3BtreeSetCacheSize(p: PBtree; mxPage: i32);
var pBt: PBtShared;
begin
  pBt := p^.pBt;
  sqlite3BtreeEnter(p);
  sqlite3PagerSetCachesize(pBt^.pPager, mxPage);
  sqlite3BtreeLeave(p);
end;

{ btree.c:3185 — simplified: only honours the call when iFix is non-zero
  or BTS_PAGESIZE_FIXED is not yet set.  nReserve<0 means "leave unchanged". }
function sqlite3BtreeSetPageSize(p: PBtree; iPageSize: i32;
                                 nReserve: i32; iFix: i32): i32;
var
  pBt    : PBtShared;
  rc     : i32;
  uPgsz  : u32;
begin
  pBt := p^.pBt;
  rc  := SQLITE_OK;
  sqlite3BtreeEnter(p);
  if (pBt^.btsFlags and BTS_PAGESIZE_FIXED) <> 0 then begin
    sqlite3BtreeLeave(p);
    if i32(pBt^.pageSize) = iPageSize then Result := SQLITE_OK
    else                                  Result := SQLITE_READONLY;
    Exit;
  end;
  if nReserve < 0 then
    nReserve := i32(pBt^.pageSize - pBt^.usableSize);
  if (iPageSize >= 512) and (iPageSize <= SQLITE_MAX_PAGE_SIZE)
     and (((iPageSize - 1) and iPageSize) = 0) then
  begin
    uPgsz := u32(iPageSize);
    rc := sqlite3PagerSetPagesize(pBt^.pPager, @uPgsz, nReserve);
    pBt^.pageSize   := uPgsz;
    pBt^.usableSize := uPgsz - u32(nReserve);
  end;
  if iFix <> 0 then
    pBt^.btsFlags := pBt^.btsFlags or BTS_PAGESIZE_FIXED;
  sqlite3BtreeLeave(p);
  Result := rc;
end;

{ btree.c:3296 }
function sqlite3BtreeTxnState(p: PBtree): i32;
begin
  if p = nil then Result := SQLITE_TXN_NONE
  else            Result := i32(p^.inTrans);
end;

{ btree.c:3257 }
function sqlite3BtreeGetReserveNoMutex(p: PBtree): i32;
begin
  Result := i32(p^.pBt^.pageSize - p^.pBt^.usableSize);
end;

{ btree.c:3136 }
function sqlite3BtreeGetRequestedReserve(p: PBtree): i32;
var n1, n2: i32;
begin
  sqlite3BtreeEnter(p);
  n1 := i32(p^.pBt^.nReserveWanted);
  n2 := sqlite3BtreeGetReserveNoMutex(p);
  sqlite3BtreeLeave(p);
  if n1 > n2 then Result := n1 else Result := n2;
end;

{ btree.c:11544 }
procedure sqlite3BtreeClearCache(p: PBtree);
var pBt: PBtShared;
begin
  pBt := p^.pBt;
  if pBt^.inTransaction = TRANS_NONE then
    sqlite3PagerClearCache(pBt^.pPager);
end;

{ btree.c:7046 — set page-1 byte 18 (file-format-write) and byte 19
  (file-format-read).  Both are clamped to MIN(2,iVersion).  Implemented as
  a direct page-1 write so it works without an open transaction layer. }
function sqlite3BtreeSetVersion(p: PBtree; iVersion: i32): i32;
var
  pBt    : PBtShared;
  rc     : i32;
  pPage1 : PDbPage;
  zData  : Pu8;
begin
  pBt := p^.pBt;
  rc  := sqlite3PagerGet(pBt^.pPager, 1, @pPage1, 0);
  if rc <> SQLITE_OK then begin Result := rc; Exit; end;
  rc := sqlite3PagerWrite(pPage1);
  if rc = SQLITE_OK then begin
    zData := Pu8(sqlite3PagerGetData(pPage1));
    zData[18] := u8(iVersion);
    zData[19] := u8(iVersion);
  end;
  sqlite3PagerUnref(pPage1);
  Result := rc;
end;

{ btree.c:11365 }
function sqlite3BtreeSchema(p: PBtree; nBytes: i32;
                            xFree: TBtreeSchemaFree): Pointer;
var pBt: PBtShared;
begin
  pBt := p^.pBt;
  sqlite3BtreeEnter(p);
  if (pBt^.pSchema = nil) and (nBytes <> 0) then begin
    pBt^.pSchema := sqlite3MallocZero(csize_t(nBytes));
    pBt^.xFreeSchema := xFree;
  end;
  sqlite3BtreeLeave(p);
  Result := pBt^.pSchema;
end;

{ btree.c:11339 }
function sqlite3BtreeIsInBackup(p: PBtree): i32;
begin
  if p^.nBackup <> 0 then Result := 1 else Result := 0;
end;

{ btree.c:11538 }
function sqlite3HeaderSizeBtree: i32;
begin
  Result := i32(ROUND8(SizeOf(TMemPage)));
end;

{ btree.c:11555 — no shared-cache build → never sharable. }
function sqlite3BtreeSharable(p: PBtree): i32;
begin
  Result := i32(p^.sharable);
end;

{ btree.c:11564 — no shared-cache build → refcount is always 1. }
function sqlite3BtreeConnectionCount(p: PBtree): i32;
begin
  Result := p^.pBt^.nRef;
end;

{ btree.c:3177 }
function sqlite3BtreeSecureDelete(p: PBtree; newFlag: i32): i32;
var pBt: PBtShared;
begin
  if p = nil then begin Result := 0; Exit; end;
  sqlite3BtreeEnter(p);
  pBt := p^.pBt;
  if newFlag >= 0 then begin
    pBt^.btsFlags := pBt^.btsFlags and (not u16(BTS_FAST_SECURE));
    pBt^.btsFlags := pBt^.btsFlags or u16(BTS_SECURE_DELETE * newFlag);
  end;
  Result := i32((pBt^.btsFlags and BTS_FAST_SECURE) div BTS_SECURE_DELETE);
  sqlite3BtreeLeave(p);
end;

{ btree.c:3198 }
function sqlite3BtreeSetAutoVacuum(p: PBtree; autoVacuum: i32): i32;
var
  pBt: PBtShared;
  rc:  i32;
  av:  u8;
begin
  pBt := p^.pBt;
  rc  := SQLITE_OK;
  av  := u8(autoVacuum);
  sqlite3BtreeEnter(p);
  if ((pBt^.btsFlags and BTS_PAGESIZE_FIXED) <> 0)
     and (Ord(av <> 0) <> i32(pBt^.autoVacuum)) then
  begin
    rc := SQLITE_READONLY;
  end
  else begin
    if av <> 0 then pBt^.autoVacuum := 1 else pBt^.autoVacuum := 0;
    if av  = 2 then pBt^.incrVacuum := 1 else pBt^.incrVacuum := 0;
  end;
  sqlite3BtreeLeave(p);
  Result := rc;
end;

{ btree.c:3222 }
function sqlite3BtreeGetAutoVacuum(p: PBtree): i32;
var rc: i32;
begin
  sqlite3BtreeEnter(p);
  if p^.pBt^.autoVacuum = 0 then
    rc := BTREE_AUTOVACUUM_NONE
  else if p^.pBt^.incrVacuum = 0 then
    rc := BTREE_AUTOVACUUM_FULL
  else
    rc := BTREE_AUTOVACUUM_INCR;
  sqlite3BtreeLeave(p);
  Result := rc;
end;

{ PTRMAP_ISPAGE — btreeInt.h:628.  True iff `pg` is itself a ptrmap page. }
function PTRMAP_ISPAGE(pBt: PBtShared; pg: Pgno): Boolean; inline;
begin
  Result := ptrmapPageno(pBt, pg) = pg;
end;

{ incrVacuumStep — btree.c:4034..4128.
  Perform one step of an incremental vacuum.  Moves the page at `iLastPg`
  off the tail of the file if possible, freeing it for truncation.
  Returns SQLITE_DONE when there is no productive work; SQLITE_OK if more
  work remains; or an error code on failure.

  Cite: btree.c:4034..4128 (caller bCommit==1 means auto-vacuum-at-commit,
  bCommit==0 means PRAGMA incremental_vacuum). }
function incrVacuumStep(pBt: PBtShared; nFin: Pgno; iLastPg: Pgno;
                        bCommit: i32): i32;
var
  nFreeList: Pgno;          { btree.c:4035 }
  rc       : i32;
  eType    : u8;
  iPtrPage : Pgno;
  iFreePg  : Pgno;
  pFreePg  : PMemPage;
  pLastPg  : PMemPage;
  eMode    : u8;
  iNear    : Pgno;
  dbSize   : Pgno;
begin
  Assert(iLastPg > nFin);

  if (not PTRMAP_ISPAGE(pBt, iLastPg)) and
     (iLastPg <> PENDING_BYTE_PAGE(pBt)) then
  begin
    nFreeList := get4byte(@pBt^.pPage1^.aData[36]);
    if nFreeList = 0 then begin
      Result := SQLITE_DONE;
      Exit;
    end;

    rc := ptrmapGet(pBt, iLastPg, eType, iPtrPage);
    if rc <> SQLITE_OK then begin
      Result := rc;
      Exit;
    end;
    if eType = PTRMAP_ROOTPAGE then begin
      Result := SQLITE_CORRUPT_BKPT;
      Exit;
    end;

    if eType = PTRMAP_FREEPAGE then begin
      if bCommit = 0 then begin
        { btree.c:4058..4073 — remove the page from the free-list.  Not
          required when bCommit is non-zero (free-list is truncated to
          zero after this function returns in that case). }
        rc := allocateBtreePage(pBt, pFreePg, iFreePg, iLastPg,
                                BTALLOC_EXACT);
        if rc <> SQLITE_OK then begin
          Result := rc;
          Exit;
        end;
        Assert(iFreePg = iLastPg);
        releasePage(pFreePg);
      end;
    end else begin
      { btree.c:4074..4117 — relocate pLastPg to a free page near the
        beginning of the file. }
      eMode := BTALLOC_ANY;
      iNear := 0;

      rc := btreeGetPage(pBt, iLastPg, pLastPg, 0);
      if rc <> SQLITE_OK then begin
        Result := rc;
        Exit;
      end;

      { btree.c:4085..4095 — if bCommit, loop until a free page below
        nFin is found; otherwise the loop runs once. }
      if bCommit = 0 then begin
        eMode := BTALLOC_LE;
        iNear := nFin;
      end;
      repeat
        dbSize := btreePagecount(pBt);
        rc := allocateBtreePage(pBt, pFreePg, iFreePg, iNear, eMode);
        if rc <> SQLITE_OK then begin
          releasePage(pLastPg);
          Result := rc;
          Exit;
        end;
        releasePage(pFreePg);
        if iFreePg > dbSize then begin
          releasePage(pLastPg);
          Result := SQLITE_CORRUPT_BKPT;
          Exit;
        end;
      until (bCommit = 0) or (iFreePg <= nFin);
      Assert(iFreePg < iLastPg);

      rc := relocatePage(pBt, pLastPg, eType, iPtrPage, iFreePg, bCommit);
      releasePage(pLastPg);
      if rc <> SQLITE_OK then begin
        Result := rc;
        Exit;
      end;
    end;
  end;

  if bCommit = 0 then begin
    { btree.c:4120..4126 — step iLastPg back past PENDING_BYTE_PAGE and
      any ptrmap pages, then schedule truncation. }
    repeat
      Dec(iLastPg);
    until (iLastPg <> PENDING_BYTE_PAGE(pBt)) and
          (not PTRMAP_ISPAGE(pBt, iLastPg));
    pBt^.bDoTruncate := 1;
    pBt^.nPage := iLastPg;
  end;
  Result := SQLITE_OK;
end;

{ btree.c:4135 — given an auto-vacuum DB of nOrig pages with nFree free
  pages, return the expected size in pages following an auto-vacuum. }
function finalDbSize(pBt: PBtShared; nOrig: Pgno; nFree: Pgno): Pgno;
var
  nEntry  : i32;
  nPtrmap : Pgno;
  nFin    : Pgno;
begin
  nEntry := pBt^.usableSize div 5;
  nPtrmap := (nFree - nOrig + ptrmapPageno(pBt, nOrig) + Pgno(nEntry))
              div Pgno(nEntry);
  nFin := nOrig - nFree - nPtrmap;
  if (nOrig > PENDING_BYTE_PAGE(pBt)) and (nFin < PENDING_BYTE_PAGE(pBt)) then
    Dec(nFin);
  while PTRMAP_ISPAGE(pBt, nFin) or (nFin = PENDING_BYTE_PAGE(pBt)) do
    Dec(nFin);
  Result := nFin;
end;

{ btree.c lines 4194-4277: autoVacuumCommit (forward-declared earlier).
  Called from sqlite3BtreeCommitPhaseOne when pBt->autoVacuum is set.
  When !incrVacuum, computes how many trailing pages can be returned to
  the OS, runs incrVacuumStep over that range, updates the page-1
  header (size-after-truncate at offset 28, freelist trunk/count at
  offsets 32/36) and arms pBt^.bDoTruncate so commit-phase-one calls
  sqlite3PagerTruncateImage. }
type
  TxAutovacPagesProc = function(pArg: Pointer; zSchema: PAnsiChar;
                                nDbPage: u32; nFreePage: u32;
                                nBytePerPage: u32): u32; cdecl;

function autoVacuumCommit(p: PBtree): i32;
var
  rc    : i32;
  pPgr  : PPager;
  pBt   : PBtShared;
  db    : PTsqlite3;
  nFin  : Pgno;
  nFree : Pgno;
  nVac  : Pgno;
  iFree : Pgno;
  nOrig : Pgno;
  iDb   : i32;
  xCb   : TxAutovacPagesProc;
begin
  rc    := SQLITE_OK;
  pBt   := p^.pBt;
  pPgr  := pBt^.pPager;

  invalidateAllOverflowCache(pBt);
  Assert(pBt^.autoVacuum <> 0);
  if pBt^.incrVacuum = 0 then begin
    nOrig := btreePagecount(pBt);
    if PTRMAP_ISPAGE(pBt, nOrig) or (nOrig = PENDING_BYTE_PAGE(pBt)) then begin
      Result := SQLITE_CORRUPT_BKPT;
      Exit;
    end;

    nFree := get4byte(pBt^.pPage1^.aData + 36);
    db    := PTsqlite3(p^.db);
    if (db <> nil) and (db^.xAutovacPages <> nil) then begin
      iDb := 0;
      while iDb < db^.nDb do begin
        if PBtree(db^.aDb[iDb].pBt) = p then break;
        Inc(iDb);
      end;
      xCb := TxAutovacPagesProc(db^.xAutovacPages);
      nVac := Pgno(xCb(db^.pAutovacPagesArg,
                       db^.aDb[iDb].zDbSName,
                       u32(nOrig), u32(nFree), u32(pBt^.pageSize)));
      if nVac > nFree then nVac := nFree;
      if nVac = 0 then begin
        Result := SQLITE_OK;
        Exit;
      end;
    end else begin
      nVac := nFree;
    end;
    nFin := finalDbSize(pBt, nOrig, nVac);
    if nFin > nOrig then begin
      Result := SQLITE_CORRUPT_BKPT;
      Exit;
    end;
    if nFin < nOrig then
      rc := saveAllCursors(pBt, 0, nil);
    iFree := nOrig;
    while (iFree > nFin) and (rc = SQLITE_OK) do begin
      rc := incrVacuumStep(pBt, nFin, iFree, Ord(nVac = nFree));
      Dec(iFree);
    end;
    if ((rc = SQLITE_DONE) or (rc = SQLITE_OK)) and (nFree > 0) then begin
      rc := sqlite3PagerWrite(pBt^.pPage1^.pDbPage);
      if nVac = nFree then begin
        put4byte(pBt^.pPage1^.aData + 32, 0);
        put4byte(pBt^.pPage1^.aData + 36, 0);
      end;
      put4byte(pBt^.pPage1^.aData + 28, u32(nFin));
      pBt^.bDoTruncate := 1;
      pBt^.nPage := nFin;
    end;
    if rc <> SQLITE_OK then
      sqlite3PagerRollback(pPgr);
  end;

  Result := rc;
end;

{ btree.c:4161 — perform a single unit of work towards an incremental
  vacuum.  A write-transaction must be open.  Returns SQLITE_DONE if
  the vacuum is complete, SQLITE_OK if more work remains, or an error
  code.  Faithful 1:1 with btree.c:4161..4202. }
function sqlite3BtreeIncrVacuum(p: PBtree): i32;
var
  pBt   : PBtShared;
  rc    : i32;
  nOrig : Pgno;
  nFree : Pgno;
  nFin  : Pgno;
begin
  pBt := p^.pBt;
  sqlite3BtreeEnter(p);
  Assert((pBt^.inTransaction = TRANS_WRITE) and (p^.inTrans = TRANS_WRITE));
  if pBt^.autoVacuum = 0 then
    rc := SQLITE_DONE
  else
  begin
    nOrig := btreePagecount(pBt);
    nFree := get4byte(pBt^.pPage1^.aData + 36);
    nFin  := finalDbSize(pBt, nOrig, nFree);

    if (nOrig < nFin) or (nFree >= nOrig) then
      rc := SQLITE_CORRUPT_BKPT
    else if nFree > 0 then
    begin
      rc := saveAllCursors(pBt, 0, nil);
      if rc = SQLITE_OK then
      begin
        invalidateAllOverflowCache(pBt);
        rc := incrVacuumStep(pBt, nFin, nOrig, 0);
      end;
      if rc = SQLITE_OK then
      begin
        rc := sqlite3PagerWrite(pBt^.pPage1^.pDbPage);
        put4byte(pBt^.pPage1^.aData + 28, u32(pBt^.nPage));
      end;
    end
    else
      rc := SQLITE_DONE;
  end;
  sqlite3BtreeLeave(p);
  Result := rc;
end;

{ btree.c:3017 }
function sqlite3BtreeSetMmapLimit(p: PBtree; szMmap: i64): i32;
begin
  sqlite3BtreeEnter(p);
  sqlite3PagerSetMmapLimit(p^.pBt^.pPager, szMmap);
  sqlite3BtreeLeave(p);
  Result := SQLITE_OK;
end;

{ btree.c:3036 }
function sqlite3BtreeSetPagerFlags(p: PBtree; pgFlags: u32): i32;
begin
  sqlite3BtreeEnter(p);
  sqlite3PagerSetFlags(p^.pBt^.pPager, pgFlags);
  sqlite3BtreeLeave(p);
  Result := SQLITE_OK;
end;

{ btree.c:11382 — schema-lock probe.  No-shared-cache build:
  querySharedCacheTableLock is a stub that always returns SQLITE_OK, so the
  result is unconditionally SQLITE_OK after enter/leave bookkeeping. }
function sqlite3BtreeSchemaLocked(p: PBtree): i32;
begin
  sqlite3BtreeEnter(p);
  Result := SQLITE_OK;
  sqlite3BtreeLeave(p);
end;

{ btree.c:4583 }
function sqlite3BtreeBeginStmt(p: PBtree; iStatement: i32): i32;
var rc: i32;
begin
  sqlite3BtreeEnter(p);
  rc := sqlite3PagerOpenSavepoint(p^.pBt^.pPager, iStatement);
  sqlite3BtreeLeave(p);
  Result := rc;
end;

{ ============================================================================
  Phase 6.28 — sqlite3BtreeIntegrityCheck (btree.c:11126) and helpers
  (btree.c:10566..11100).  Faithful 1:1 port of the !SQLITE_OMIT_INTEGRITY_CHECK
  arm.  Differences from the C reference:
    * StrAccum static-buffer-then-grow strategy is replaced by libc-malloc
      sqlite3_str_new (Pascal port already lacks the C StrAccumInit shape).
    * `aCnt: Mem*` parameter is replaced by `aRowCnt: Pi64*` so this unit
      stays free of the vdbe.pas Mem layout dependency; the OP_IntegrityCk
      handler in vdbe.pas marshals the i64 array into Mem cells.
    * Optional progress / interrupt hook (`checkProgress`) is reduced to
      a no-op — db^.u1.isInterrupted and db^.xProgress live in the
      codegen-side sqlite3 layout that btree.pas treats as opaque.
    * SQLITE_CellSizeCk db^.flags save/restore arm is dropped (perf-only,
      not correctness).
  ============================================================================ }
type
  PIntegrityCk = ^TIntegrityCk;
  TIntegrityCk = record
    pBt     : PBtShared;     { The tree being checked }
    pPager  : PPager;        { Same as pBt^.pPager }
    aPgRef  : Pu8;           { 1 bit per page in db (cleared on init) }
    nCkPage : Pgno;          { Pages in the database; 0 for partial check }
    mxErr   : i32;           { Stop accumulating errors when this hits 0 }
    nErr    : i32;           { Number of messages written so far }
    rc      : i32;           { SQLITE_OK / SQLITE_NOMEM / SQLITE_INTERRUPT }
    nStep   : u32;           { Steps into the integrity_check process }
    zPfx    : PAnsiChar;     { Error-message prefix format }
    v0      : Pgno;          { First %u substitution in zPfx (root page) }
    v1      : Pgno;          { Second %u substitution in zPfx (current pg) }
    v2      : i32;           { Third %d substitution in zPfx (cell index) }
    errMsg  : PSqlite3Str;   { Accumulating libc-malloc'd error text }
    heap    : Pu32;          { Min-heap for cell-coverage analysis }
    db      : Psqlite3;      { Database connection (opaque here) }
    nRow    : i64;           { Rows visited in the current tree }
  end;

{ btree.c:10566 }
procedure checkOom(pCheck: PIntegrityCk);
begin
  pCheck^.rc := SQLITE_NOMEM;
  pCheck^.mxErr := 0;
  if pCheck^.nErr = 0 then Inc(pCheck^.nErr);
end;

{ btree.c:10576 — progress / interrupt hook.  Reduced to a no-op since
  db^ is opaque in this unit.  The check still terminates cleanly because
  callers honour mxErr; only progress callbacks and async interrupt are
  dropped. }
procedure checkProgress(pCheck: PIntegrityCk);
begin
  Inc(pCheck^.nStep);
end;

{ btree.c:10601 — checkAppendMsg.  Uses sqlite3_str_appendf (Pascal
  array-of-const variadic) instead of va_list. }
procedure checkAppendMsg(pCheck: PIntegrityCk; const zFormat: AnsiString;
                         const args: array of const);
var s: AnsiString;
begin
  checkProgress(pCheck);
  if pCheck^.mxErr = 0 then Exit;
  Dec(pCheck^.mxErr);
  Inc(pCheck^.nErr);
  if pCheck^.errMsg^.nChar <> 0 then
    sqlite3_str_append(pCheck^.errMsg, PAnsiChar(#10), 1);
  if pCheck^.zPfx <> nil then
    sqlite3_str_appendf(pCheck^.errMsg, pCheck^.zPfx,
                        [pCheck^.v0, pCheck^.v1, pCheck^.v2]);
  s := zFormat;
  sqlite3_str_appendf(pCheck^.errMsg, PAnsiChar(s), args);
  if pCheck^.errMsg^.accError = SQLITE_NOMEM then
    checkOom(pCheck);
end;

{ btree.c:10633 }
function getPageReferenced(pCheck: PIntegrityCk; iPg: Pgno): i32;
begin
  Assert(pCheck^.aPgRef <> nil);
  Assert(iPg <= pCheck^.nCkPage);
  Result := i32(pCheck^.aPgRef[iPg shr 3]) and (1 shl (iPg and 7));
end;

{ btree.c:10642 }
procedure setPageReferenced(pCheck: PIntegrityCk; iPg: Pgno);
begin
  Assert(pCheck^.aPgRef <> nil);
  Assert(iPg <= pCheck^.nCkPage);
  pCheck^.aPgRef[iPg shr 3] := pCheck^.aPgRef[iPg shr 3] or
                                u8(1 shl (iPg and 7));
end;

{ btree.c:10657 }
function checkRef(pCheck: PIntegrityCk; iPage: Pgno): i32;
begin
  if (iPage > pCheck^.nCkPage) or (iPage = 0) then begin
    checkAppendMsg(pCheck, 'invalid page number %u', [iPage]);
    Result := 1; Exit;
  end;
  if getPageReferenced(pCheck, iPage) <> 0 then begin
    checkAppendMsg(pCheck, '2nd reference to page %u', [iPage]);
    Result := 1; Exit;
  end;
  setPageReferenced(pCheck, iPage);
  Result := 0;
end;

{ btree.c:10676 — checkPtrmap.  Auto-vacuum is not productively wired in
  this port (autoVacuum is always 0), so this body is reachable only when
  upstream-faithful builds enable it.  Implementation matches C 1:1. }
procedure checkPtrmap(pCheck: PIntegrityCk; iChild: Pgno; eType: u8;
                      iParent: Pgno);
var rc: i32;
    ePtrmapType: u8;
    iPtrmapParent: Pgno;
begin
  rc := ptrmapGet(pCheck^.pBt, iChild, ePtrmapType, iPtrmapParent);
  if rc <> SQLITE_OK then begin
    if (rc = SQLITE_NOMEM) or (rc = SQLITE_IOERR_NOMEM) then checkOom(pCheck);
    checkAppendMsg(pCheck, 'Failed to read ptrmap key=%u', [iChild]);
    Exit;
  end;
  if (ePtrmapType <> eType) or (iPtrmapParent <> iParent) then
    checkAppendMsg(pCheck,
      'Bad ptr map entry key=%u expected=(%u,%u) got=(%u,%u)',
      [iChild, eType, iParent, ePtrmapType, iPtrmapParent]);
end;

{ btree.c:10705 — checkList: validate freelist or overflow chain. }
procedure checkList(pCheck: PIntegrityCk; isFreeList: i32; iPage: Pgno; nIn: u32);
var i: i32;
    expected: u32;
    nErrAtStart: i32;
    pOvflPage: PDbPage;
    pOvflData: Pu8;
    nLeaf: u32;
    iFreePage: Pgno;
begin
  expected := nIn;
  nErrAtStart := pCheck^.nErr;
  while (iPage <> 0) and (pCheck^.mxErr <> 0) do begin
    if checkRef(pCheck, iPage) <> 0 then break;
    Dec(nIn);
    if sqlite3PagerGet(pCheck^.pPager, iPage, @pOvflPage, 0) <> SQLITE_OK then
    begin
      checkAppendMsg(pCheck, 'failed to get page %u', [iPage]);
      break;
    end;
    pOvflData := Pu8(sqlite3PagerGetData(pOvflPage));
    if isFreeList <> 0 then begin
      nLeaf := u32(sqlite3Get4byte(@pOvflData[4]));
      if pCheck^.pBt^.autoVacuum <> 0 then
        checkPtrmap(pCheck, iPage, PTRMAP_FREEPAGE, 0);
      if nLeaf > pCheck^.pBt^.usableSize div 4 - 2 then begin
        checkAppendMsg(pCheck,
          'freelist leaf count too big on page %u', [iPage]);
        Dec(nIn);
      end else begin
        for i := 0 to i32(nLeaf) - 1 do begin
          iFreePage := sqlite3Get4byte(@pOvflData[8 + i * 4]);
          if pCheck^.pBt^.autoVacuum <> 0 then
            checkPtrmap(pCheck, iFreePage, PTRMAP_FREEPAGE, 0);
          checkRef(pCheck, iFreePage);
        end;
        nIn := nIn - nLeaf;
      end;
    end else begin
      { Overflow chain — auto-vacuum chains carry a ptrmap forward link. }
      if (pCheck^.pBt^.autoVacuum <> 0) and (nIn > 0) then begin
        i := i32(sqlite3Get4byte(pOvflData));
        checkPtrmap(pCheck, Pgno(i), PTRMAP_OVERFLOW2, iPage);
      end;
    end;
    iPage := sqlite3Get4byte(pOvflData);
    sqlite3PagerUnref(pOvflPage);
  end;
  if (nIn <> 0) and (nErrAtStart = pCheck^.nErr) then begin
    { btree.c:10768 — C computes `expected-N` with both as u32, so over-
      counting (N decremented past zero) wraps mod 2^32 and %u prints
      the wrapped 32-bit value (e.g. expected=2, N=u32(-1) → diff=3).
      FPC widens u32-u32 to 64 bits in array-of-const, so without an
      explicit mask we print 18446744069414584323 instead of 3
      (9.4.divbug.88.012 corrupt2-14.3/.5). }
    if isFreeList <> 0 then
      checkAppendMsg(pCheck, 'size is %u but should be %u',
                     [u32((expected - nIn) and $FFFFFFFF), expected])
    else
      checkAppendMsg(pCheck,
                     'overflow list length is %u but should be %u',
                     [u32((expected - nIn) and $FFFFFFFF), expected]);
  end;
end;

{ btree.c:10794 — min-heap insert.  aHeap[0] is the count, aHeap[1] the
  root.  Daughter nodes of aHeap[N] are aHeap[N*2] / aHeap[N*2+1]. }
procedure btreeHeapInsert(aHeap: Pu32; x: u32);
var i, j, t: u32;
begin
  Assert(aHeap <> nil);
  Inc(aHeap[0]); i := aHeap[0];
  aHeap[i] := x;
  j := i div 2;
  while (j > 0) and (aHeap[j] > aHeap[i]) do begin
    t := aHeap[j]; aHeap[j] := aHeap[i]; aHeap[i] := t;
    i := j; j := i div 2;
  end;
end;

{ btree.c:10806 — min-heap pull. }
function btreeHeapPull(aHeap: Pu32; pOut: Pu32): i32;
var i, j, x, t: u32;
begin
  x := aHeap[0];
  if x = 0 then begin Result := 0; Exit; end;
  pOut^ := aHeap[1];
  aHeap[1] := aHeap[x];
  aHeap[x] := $FFFFFFFF;
  Dec(aHeap[0]);
  i := 1; j := i * 2;
  while j <= aHeap[0] do begin
    if (j < aHeap[0]) and (aHeap[j] > aHeap[j + 1]) then Inc(j);
    if aHeap[i] < aHeap[j] then break;
    t := aHeap[i]; aHeap[i] := aHeap[j]; aHeap[j] := t;
    i := j; j := i * 2;
  end;
  Result := 1;
end;

{ btree.c:10840 — checkTreePage: walk a single tree page (table or
  index, leaf or interior).  Recurses into children, validates cell
  layout, integer-key ordering, overflow chains, and (via min-heap)
  cell coverage.  Returns the depth (root = 1, parent of root = 2,
  etc.; matching the C return value of `depth + 1`). }
function checkTreePage(pCheck: PIntegrityCk; iPage: Pgno;
                       piMinKey: Pi64; maxKey: i64): i32;
label end_of_check;
var pPage: PMemPage;
    i, rc, depth, d2: i32;
    iChildPg, nFrag, hdr, cellStart, nCell: i32;
    doCoverageCheck, keyCanBeEqual: i32;
    data, pCell, pCellIdx: Pu8;
    pBt: PBtShared;
    pc, usableSize, contentOffset, x, prev: u32;
    heap: Pu32;
    saved_zPfx: PAnsiChar;
    saved_v1: Pgno;
    saved_v2: i32;
    savedIsInit: u8;
    info: TCellInfo;
    nPage: u32;
    pgnoOvfl: Pgno;
    size: u32;
begin
  pPage := nil;
  depth := -1;
  doCoverageCheck := 1;
  keyCanBeEqual := 1;
  saved_zPfx := pCheck^.zPfx;
  saved_v1 := pCheck^.v1;
  saved_v2 := pCheck^.v2;
  savedIsInit := 0;
  heap := nil;
  prev := 0;
  checkProgress(pCheck);
  if pCheck^.mxErr = 0 then begin Result := 0; Exit; end;
  pBt := pCheck^.pBt;
  usableSize := pBt^.usableSize;
  if iPage = 0 then begin Result := 0; Exit; end;
  if checkRef(pCheck, iPage) <> 0 then begin Result := 0; Exit; end;
  pCheck^.zPfx := PAnsiChar('Tree %u page %u: ');
  pCheck^.v1 := iPage;
  rc := btreeGetPage(pBt, iPage, pPage, 0);
  if rc <> 0 then begin
    checkAppendMsg(pCheck,
      'unable to get the page. error code=%d', [rc]);
    if rc = SQLITE_IOERR_NOMEM then pCheck^.rc := SQLITE_NOMEM;
    goto end_of_check;
  end;

  { Force btreeInitPage to re-run so its corruption-detection arm
    fires regardless of any cached isInit. }
  savedIsInit := pPage^.isInit;
  pPage^.isInit := 0;
  rc := btreeInitPage(pPage);
  if rc <> 0 then begin
    Assert(rc = SQLITE_CORRUPT);
    checkAppendMsg(pCheck,
      'btreeInitPage() returns error code %d', [rc]);
    goto end_of_check;
  end;
  rc := btreeComputeFreeSpace(pPage);
  if rc <> 0 then begin
    Assert(rc = SQLITE_CORRUPT);
    checkAppendMsg(pCheck, 'free space corruption', []);
    goto end_of_check;
  end;
  data := pPage^.aData;
  hdr := pPage^.hdrOffset;

  pCheck^.zPfx := PAnsiChar('Tree %u page %u cell %u: ');
  contentOffset := u32(get2byte(@data[hdr + 5]));
  if contentOffset = 0 then contentOffset := 65536;
  Assert(contentOffset <= usableSize);

  { Cell count is the 2-byte int at offset hdr+3. }
  nCell := get2byte(@data[hdr + 3]);
  Assert(pPage^.nCell = nCell);
  if (pPage^.leaf <> 0) or (pPage^.intKey = 0) then
    pCheck^.nRow := pCheck^.nRow + nCell;

  { Cell-pointer array immediately follows the page header. }
  cellStart := hdr + 12 - 4 * pPage^.leaf;
  pCellIdx := @data[cellStart + 2 * (nCell - 1)];

  if pPage^.leaf = 0 then begin
    { Right-child page of an internal page. }
    iChildPg := i32(sqlite3Get4byte(@data[hdr + 8]));
    if pBt^.autoVacuum <> 0 then begin
      pCheck^.zPfx := PAnsiChar('Tree %u page %u right child: ');
      checkPtrmap(pCheck, Pgno(iChildPg), PTRMAP_BTREE, iPage);
    end;
    depth := checkTreePage(pCheck, Pgno(iChildPg), @maxKey, maxKey);
    keyCanBeEqual := 0;
  end else begin
    { Initialise the coverage-check heap for leaf pages. }
    heap := pCheck^.heap;
    heap[0] := 0;
  end;

  { Walk the cells in reverse to mirror C. }
  i := nCell - 1;
  while (i >= 0) and (pCheck^.mxErr <> 0) do begin
    pCheck^.v2 := i;
    pc := u32(get2byteAligned(pCellIdx));
    Dec(pCellIdx, 2);
    if (pc < contentOffset) or (pc > usableSize - 4) then begin
      checkAppendMsg(pCheck, 'Offset %u out of range %u..%u',
                     [pc, contentOffset, usableSize - 4]);
      doCoverageCheck := 0;
      Dec(i); continue;
    end;
    pCell := @data[pc];
    pPage^.xParseCell(pPage, pCell, @info);
    if pc + info.nSize > usableSize then begin
      checkAppendMsg(pCheck, 'Extends off end of page', []);
      doCoverageCheck := 0;
      Dec(i); continue;
    end;

    { Integer-PK out-of-order check. }
    if pPage^.intKey <> 0 then begin
      if (keyCanBeEqual <> 0) and (info.nKey > maxKey) then
        checkAppendMsg(pCheck, 'Rowid %lld out of order', [info.nKey])
      else if (keyCanBeEqual = 0) and (info.nKey >= maxKey) then
        checkAppendMsg(pCheck, 'Rowid %lld out of order', [info.nKey]);
      maxKey := info.nKey;
      keyCanBeEqual := 0;
    end;

    { Overflow-chain validation. }
    if info.nPayload > info.nLocal then begin
      Assert(pc + info.nSize - 4 <= usableSize);
      nPage := (info.nPayload - u32(info.nLocal) + usableSize - 5)
               div (usableSize - 4);
      pgnoOvfl := sqlite3Get4byte(@pCell[info.nSize - 4]);
      if pBt^.autoVacuum <> 0 then
        checkPtrmap(pCheck, pgnoOvfl, PTRMAP_OVERFLOW1, iPage);
      checkList(pCheck, 0, pgnoOvfl, nPage);
    end;

    if pPage^.leaf = 0 then begin
      iChildPg := i32(sqlite3Get4byte(pCell));
      if pBt^.autoVacuum <> 0 then
        checkPtrmap(pCheck, Pgno(iChildPg), PTRMAP_BTREE, iPage);
      d2 := checkTreePage(pCheck, Pgno(iChildPg), @maxKey, maxKey);
      keyCanBeEqual := 0;
      if d2 <> depth then begin
        checkAppendMsg(pCheck, 'Child page depth differs', []);
        depth := d2;
      end;
    end else begin
      btreeHeapInsert(heap, (pc shl 16) or (pc + info.nSize - 1));
    end;
    Dec(i);
  end;
  if piMinKey <> nil then piMinKey^ := maxKey;

  { Cell-coverage / fragmentation cross-check. }
  pCheck^.zPfx := nil;
  if (doCoverageCheck <> 0) and (pCheck^.mxErr > 0) then begin
    if pPage^.leaf = 0 then begin
      heap := pCheck^.heap;
      heap[0] := 0;
      i := nCell - 1;
      while i >= 0 do begin
        pc := u32(get2byteAligned(@data[cellStart + i * 2]));
        size := pPage^.xCellSize(pPage, @data[pc]);
        btreeHeapInsert(heap, (pc shl 16) or (pc + size - 1));
        Dec(i);
      end;
    end;
    Assert(heap <> nil);
    { Walk the freeblock chain (offset hdr+1 starts the chain). }
    i := get2byte(@data[hdr + 1]);
    while i > 0 do begin
      Assert(u32(i) <= usableSize - 4);
      size := u32(get2byte(@data[i + 2]));
      Assert(u32(i) + size <= usableSize);
      btreeHeapInsert(heap, (u32(i) shl 16) or (u32(i) + size - 1));
      i := get2byte(@data[i]);
      Assert(u32(i) <= usableSize - 4);
    end;
    nFrag := 0;
    prev := contentOffset - 1;
    while btreeHeapPull(heap, @x) <> 0 do begin
      if (prev and $FFFF) >= (x shr 16) then begin
        checkAppendMsg(pCheck, 'Multiple uses for byte %u of page %u',
                       [x shr 16, iPage]);
        break;
      end else begin
        nFrag := nFrag + i32((x shr 16) - (prev and $FFFF) - 1);
        prev := x;
      end;
    end;
    nFrag := nFrag + i32(usableSize - (prev and $FFFF) - 1);
    if (heap[0] = 0) and (nFrag <> data[hdr + 7]) then
      checkAppendMsg(pCheck,
        'Fragmentation of %u bytes reported as %u on page %u',
        [u32(nFrag), u32(data[hdr + 7]), iPage]);
  end;

end_of_check:
  if doCoverageCheck = 0 then
    if pPage <> nil then pPage^.isInit := savedIsInit;
  releasePage(pPage);
  pCheck^.zPfx := saved_zPfx;
  pCheck^.v1 := saved_v1;
  pCheck^.v2 := saved_v2;
  Result := depth + 1;
end;

{ btree.c:11126 — sqlite3BtreeIntegrityCheck.  Walks every root in
  aRoot[] and validates the resulting trees, freelist, and (for
  full / non-partial checks) the page-coverage map.  See module
  banner for the small set of port-specific deviations. }
function sqlite3BtreeIntegrityCheck(db: Psqlite3; p: PBtree;
                                    aRoot: PPgno; aRowCnt: Pi64;
                                    nRoot, mxErr: i32;
                                    pnErr: Pi32;
                                    pzOut: PPAnsiChar): i32;
label integrity_ck_cleanup;
var
  i: Pgno;
  k: i32;
  sCheck: TIntegrityCk;
  pBt: PBtShared;
  bPartial: i32;
  bCkFreelist: i32;
  notUsed: i64;
  mx, mxInHdr: Pgno;
begin
  Assert(nRoot > 0);
  bPartial := 0;
  bCkFreelist := 1;
  if aRoot[0] = 0 then begin
    Assert(nRoot > 1);
    bPartial := 1;
    if aRoot[1] <> 1 then bCkFreelist := 0;
  end;
  pBt := p^.pBt;
  sqlite3BtreeEnter(p);
  Assert((p^.inTrans > TRANS_NONE) and (pBt^.inTransaction > TRANS_NONE));

  FillChar(sCheck, SizeOf(sCheck), 0);
  sCheck.db      := db;
  sCheck.pBt     := pBt;
  sCheck.pPager  := pBt^.pPager;
  sCheck.nCkPage := btreePagecount(pBt);
  sCheck.mxErr   := mxErr;
  sCheck.errMsg  := sqlite3_str_new(nil);
  if sCheck.errMsg = nil then begin
    checkOom(@sCheck);
    goto integrity_ck_cleanup;
  end;
  if sCheck.nCkPage = 0 then goto integrity_ck_cleanup;

  sCheck.aPgRef := Pu8(sqlite3MallocZero64(u64(sCheck.nCkPage div 8) + 1));
  if sCheck.aPgRef = nil then begin
    checkOom(@sCheck);
    goto integrity_ck_cleanup;
  end;
  sCheck.heap := Pu32(sqlite3PageMalloc(pBt^.pageSize));
  if sCheck.heap = nil then begin
    checkOom(@sCheck);
    goto integrity_ck_cleanup;
  end;

  i := PENDING_BYTE_PAGE(pBt);
  if i <= sCheck.nCkPage then setPageReferenced(@sCheck, i);

  { Freelist integrity. }
  if bCkFreelist <> 0 then begin
    sCheck.zPfx := PAnsiChar('Freelist: ');
    checkList(@sCheck, 1,
              sqlite3Get4byte(@pBt^.pPage1^.aData[32]),
              u32(sqlite3Get4byte(@pBt^.pPage1^.aData[36])));
    sCheck.zPfx := nil;
  end;

  { Auto-vacuum cross-check on the rootpage list. }
  if (bPartial = 0) and (pBt^.autoVacuum <> 0) then begin
    mx := 0;
    for k := 0 to nRoot - 1 do
      if mx < aRoot[k] then mx := aRoot[k];
    mxInHdr := sqlite3Get4byte(@pBt^.pPage1^.aData[52]);
    if mx <> mxInHdr then
      checkAppendMsg(@sCheck,
        'max rootpage (%u) disagrees with header (%u)',
        [mx, mxInHdr]);
  end else if (bPartial = 0) and
              (sqlite3Get4byte(@pBt^.pPage1^.aData[64]) <> 0) then
    checkAppendMsg(@sCheck,
      'incremental_vacuum enabled with a max rootpage of zero', []);

  { Walk every listed tree. }
  for k := 0 to nRoot - 1 do begin
    if sCheck.mxErr = 0 then break;
    sCheck.nRow := 0;
    if aRoot[k] <> 0 then begin
      if (pBt^.autoVacuum <> 0) and (aRoot[k] > 1) and (bPartial = 0) then
        checkPtrmap(@sCheck, aRoot[k], PTRMAP_ROOTPAGE, 0);
      sCheck.v0 := aRoot[k];
      checkTreePage(@sCheck, aRoot[k], @notUsed, LARGEST_INT64);
    end;
    if aRowCnt <> nil then aRowCnt[k] := sCheck.nRow;
  end;

  { Page-coverage map (full check only). }
  if bPartial = 0 then begin
    i := 1;
    while (i <= sCheck.nCkPage) and (sCheck.mxErr <> 0) do begin
      if pBt^.autoVacuum = 0 then begin
        if getPageReferenced(@sCheck, i) = 0 then
          checkAppendMsg(@sCheck, 'Page %u: never used', [i]);
      end else begin
        { Auto-vacuum: pointer-map pages must be referenced exactly
          when PTRMAP_PAGENO(pBt, i) == i.  The Pascal port treats
          PTRMAP_PAGENO as approximate (per btree.pas:7340) so we
          fall back to the !autoVacuum check, which is conservative. }
        if getPageReferenced(@sCheck, i) = 0 then
          checkAppendMsg(@sCheck, 'Page %u: never used', [i]);
      end;
      Inc(i);
    end;
  end;

integrity_ck_cleanup:
  if sCheck.heap <> nil then sqlite3PageFree(sCheck.heap);
  if sCheck.aPgRef <> nil then sqlite3_free(sCheck.aPgRef);
  if pnErr <> nil then pnErr^ := sCheck.nErr;
  if pzOut <> nil then begin
    if sCheck.nErr = 0 then begin
      if sCheck.errMsg <> nil then sqlite3_str_reset(sCheck.errMsg);
      pzOut^ := nil;
    end else begin
      pzOut^ := sqlite3_str_finish(sCheck.errMsg);
      sCheck.errMsg := nil;
    end;
  end;
  if sCheck.errMsg <> nil then sqlite3_str_free(sCheck.errMsg);
  sqlite3BtreeLeave(p);
  Result := sCheck.rc;
end;

end.
