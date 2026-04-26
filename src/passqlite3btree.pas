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
procedure btreeParseCellPtrNoPayload(pPage: PMemPage; pCell: Pu8; pInfo: PCellInfo);
procedure btreeParseCellPtr(pPage: PMemPage; pCell: Pu8; pInfo: PCellInfo);
procedure btreeParseCellPtrIndex(pPage: PMemPage; pCell: Pu8; pInfo: PCellInfo);
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
function  freeSpace(pPage: PMemPage; iStart: i32; iSize: i32): i32;
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
  { UnpackedRecord — ported from vdbeInt.h (exposed here for btree + vdbe) }
  TUnpackedRecord = record
    pKeyInfo  : PKeyInfo;
    aMem      : Pointer;    { Psqlite3_value array; Pointer here to avoid circular dep }
    nField    : i32;
    default_rc: i32;
    eqSeen    : u8;
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

{ ===========================================================================
  Phase 4.2 — payload access
  =========================================================================== }
function  sqlite3BtreePayload(pCur: PBtCursor; offset: u32; amt: u32;
                               pBuf: Pointer): i32;
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
{ btree.c:3185 — set page size + reserved-bytes; iFix locks pageSize. }
function  sqlite3BtreeSetPageSize(p: PBtree; iPageSize: i32;
                                  nReserve: i32; iFix: i32): i32;
{ btree.c:3296 — current Btree transaction state (TRANS_NONE/READ/WRITE). }
function  sqlite3BtreeTxnState(p: PBtree): i32;
{ btree.c:3257 — number of bytes of unused space at the end of every page. }
function  sqlite3BtreeGetReserveNoMutex(p: PBtree): i32;
{ btree.c:7046 — set the database file format version (1 or 2 = WAL). }
function  sqlite3BtreeSetVersion(p: PBtree; iVersion: i32): i32;

implementation

uses
  BaseUnix, UnixType, passqlite3internal;

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
procedure btreeParseCellPtrNoPayload(pPage: PMemPage; pCell: Pu8; pInfo: PCellInfo);
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
procedure btreeParseCellPtr(pPage: PMemPage; pCell: Pu8; pInfo: PCellInfo);
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
procedure btreeParseCellPtrIndex(pPage: PMemPage; pCell: Pu8; pInfo: PCellInfo);
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
function freeSpace(pPage: PMemPage; iStart: i32; iSize: i32): i32;
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

{ ===========================================================================
  ptrmapPutOvflPtr stub  (autovacuum, Phase 4.5)
  =========================================================================== }
procedure ptrmapPutOvflPtr(pPage: PMemPage; pSrc: PMemPage; pCell: Pu8; pRC: Pi32);
begin
  { Autovacuum pointer-map stub — full implementation in Phase 4.5 }
end;

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
        rc := sqlite3PagerGet(pBt^.pPager, nextPage, @pDbPg,
                              i32(eOp = 0));
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
  sqlite3BtreePayloadFetch — return in-page payload pointer if available.
  Port of btree.c sqlite3BtreePayloadFetch (btree.c line ~5351).
  Returns pointer to page-local data if all `pAmt` bytes are on the leaf page;
  otherwise sets pAmt=0 and returns nil (caller uses sqlite3BtreePayload).
  --------------------------------------------------------------------------- }
function sqlite3BtreePayloadFetch(pCur: PBtCursor; out pAmt: u32): PAnsiChar;
var
  pPage:    PMemPage;
  nKey:     u32;
  nLocal:   u32;
begin
  pPage := pCur^.pPage;
  if pPage = nil then begin
    pAmt := 0; Result := nil; Exit;
  end;
  getCellInfo(pCur);
  nKey   := u32(pCur^.info.nKey);
  nLocal := u32(pCur^.info.nLocal);
  { For table leaves the payload starts after the key varint }
  pAmt := nLocal;
  if pPage^.intKey <> 0 then
    Result := PAnsiChar(pCur^.info.pPayload)
  else
    Result := PAnsiChar(pCur^.info.pPayload) + nKey;
  { If nLocal < the requested amount the caller must call BtreePayload }
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
    lwr := 0;
    upr := pPage^.nCell - 1;
    if biasRight <> 0 then
      idx := upr
    else
      idx := upr shr 1;

    while True do begin
      pCell := findCellPastPtr(pPage, idx);
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
      chldPg := get4byte(pPage^.aData + pPage^.hdrOffset + 8)
    else
      chldPg := get4byte(findCell(pPage, lwr));
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
  VDBE stubs (Phase 6 will provide real implementations)
  --------------------------------------------------------------------------- }
function sqlite3VdbeFindCompare(pIdxKey: PUnpackedRecord): TRecordCompare;
begin
  Result := nil;
end;

function sqlite3VdbeRecordCompare(nKey: i32; pKey: Pointer;
                                  pIdxKey: PUnpackedRecord): i32;
begin
  Result := 0;
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

  { Skip-to-root optimization (simplified) }
  if (pCur^.eState = CURSOR_VALID) and (pCur^.pPage^.leaf <> 0) and
     (cursorOnLastPage(pCur) <> 0) then begin
    c := indexCellCompare(pCur^.pPage, pCur^.ix, pIdxKey, xRecordCompare);
    if c <= 0 then begin
      pRes^ := c;
      Result := SQLITE_OK;
      Exit;
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
    lwr := 0;
    upr := pPage^.nCell - 1;
    idx := upr shr 1;

    while True do begin
      pCell := findCellPastPtr(pPage, idx);
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
      chldPg := get4byte(pPage^.aData + pPage^.hdrOffset + 8)
    else
      chldPg := get4byte(findCell(pPage, lwr));

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
    { Index cursor: would need sqlite3VdbeAllocUnpackedRecord (Phase 6) }
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
  Auto-vacuum stubs — ISAUTOVACUUM is always false in this port
  --------------------------------------------------------------------------- }

procedure ptrmapPut(pBt: PBtShared; key: Pgno; eType: u8; parent: Pgno;
                    pRC: Pi32);
begin
  { auto-vacuum not supported in this port }
end;

function ptrmapGet(pBt: PBtShared; key: Pgno; out pEType: u8;
                   out pPgno: Pgno): i32;
begin
  pEType := 0;
  pPgno  := 0;
  Result := SQLITE_OK;
end;

function setChildPtrmaps(pPage: PMemPage): i32;
begin
  Result := SQLITE_OK;
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

{ invalidateIncrblobCursors — stub (SQLITE_OMIT_INCRBLOB) }
procedure invalidateIncrblobCursors(p: PBtree; pgnoRoot: Pgno;
                                    iRow: i64; isClearTable: i32);
begin
  { Incrblob not supported in this port }
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
  n         := mn + (nPayload - mn) mod i32(pBt^.usableSize - 4);
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
    szNew := p^.pBt^.nPreformatSize;
    if szNew < 4 then begin
      szNew       := 4;
      newCell[3]  := 0;
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

{ btree.c lines 2500-2506: busy-handler callback registered with pager }
function btreeInvokeBusyHandler(pArg: Pointer): i32;
begin
  { Without a real db->busyHandler we simply return 0 (do not retry). }
  Result := 0;
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

  { Determine page size from header bytes 16-17 }
  iPageSize := (u32(zDbHdr[16]) shl 8) or (u32(zDbHdr[17]) shl 16);
  if ((iPageSize - 1) and iPageSize) <> 0 then iPageSize := 0;
  if (iPageSize > SQLITE_MAX_PAGE_SIZE) or (iPageSize <= 256) then
    iPageSize := 0;
  if iPageSize = 0 then iPageSize := SQLITE_DEFAULT_PAGE_SIZE;

  nReserve := i32(zDbHdr[20]);
  pBt^.btsFlags := pBt^.btsFlags or BTS_PAGESIZE_FIXED;
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

  if (pBt^.btsFlags and BTS_READ_ONLY) <> 0 then begin
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
        rc := sqlite3PagerBegin(pPgr, ord(wrflag > 1), 0);
        if rc = SQLITE_OK then
          rc := newDatabase(pBt);
      end;
    end;

    if rc <> SQLITE_OK then
      unlockBtreeIfUnused(pBt);
  until (rc and $FF) <> SQLITE_BUSY;

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
    if wrflag <> 0 then
      rc := sqlite3PagerOpenSavepoint(pPgr, 0);
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
    Result := SQLITE_OK;
  end;
end;

{ btree.c lines 4309-4328: sqlite3BtreeCommitPhaseOne }
function sqlite3BtreeCommitPhaseOne(p: PBtree; zSuperJrnl: PChar): i32;
var rc: i32;
begin
  rc := SQLITE_OK;
  if p^.inTrans = TRANS_WRITE then begin
    sqlite3BtreeEnter(p);
    { no autovacuum in this port }
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

  { Determine if cursor position must be preserved }
  bPreserve := flags and BTREE_SAVEPOSITION;
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

{ btree.c lines 10039-10182: btreeCreateTable (simplified: SQLITE_OMIT_AUTOVACUUM) }
function btreeCreateTable(p: PBtree; piTable: PPgno; createTabFlags: i32): i32;
var
  pBt     : PBtShared;
  pRoot   : PMemPage;
  pgnoRoot: Pgno;
  rc      : i32;
  ptfFlags: i32;
begin
  pBt     := p^.pBt;
  pRoot   := nil;
  pgnoRoot := 0;
  rc := SQLITE_OK;

  { No autovacuum: allocate page normally }
  rc := allocateBtreePage(pBt, pRoot, pgnoRoot, 1, 0);
  if rc <> SQLITE_OK then begin Result := rc; Exit; end;

  rc := sqlite3PagerWrite(pRoot^.pDbPage);
  if rc <> SQLITE_OK then begin
    releasePage(pRoot);
    Result := rc;
    Exit;
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

end.
