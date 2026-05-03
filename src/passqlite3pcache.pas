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
unit passqlite3pcache;
{
  Phase 3.A -- Page cache port for SQLite 3.53.0.
  Source: pcache.c (~936 lines) + pcache1_g.c (~1278 lines).
  Upstream commit: SQLite 3.53.0 (see ../sqlite3/).
  Porting conventions: follow passqlite3os.pas + passqlite3util.pas.
}

interface

uses
  passqlite3types, passqlite3internal, passqlite3os, passqlite3util,
  BaseUnix, UnixType, SysUtils;

{ ============================================================
  pcache.h types: PgHdr, PCache
  All types in one block to allow forward pointer resolution.
  ============================================================ }
type
  PPgHdr  = ^PgHdr;
  PPCache = ^PCache;

  { PgHdr -- per-page header (pcache.h). Field order MUST match C exactly. }
  PgHdr = record
    pPage:      Psqlite3_pcache_page; { sqlite3_pcache_page handle }
    pData:      Pointer;              { Page data }
    pExtra:     Pointer;              { Extra content (MemPage in btree) }
    pCache:     PPCache;              { Cache that owns this page }
    pDirty:     PPgHdr;               { Transient sorted dirty list }
    pPager:     Pointer;              { Pager owning this page }
    pgno:       Pgno;                 { Page number }
    flags:      u16;                  { PGHDR_* flags }
    { Private fields }
    nRef:       i64;                  { Reference count }
    pDirtyNext: PPgHdr;               { Next in dirty list (LRU newer) }
    pDirtyPrev: PPgHdr;               { Previous in dirty list (LRU older) }
  end;

  TXStress = function(pArg: Pointer; pPage: PPgHdr): i32;

  { PCache -- complete page cache instance (pcache.c struct PCache).
    Field order MUST match C. }
  PCache = record
    pDirty:     PPgHdr;    { Dirty pages list head (newest) }
    pDirtyTail: PPgHdr;    { Dirty pages list tail (oldest) }
    pSynced:    PPgHdr;    { Last synced page in dirty list }
    nRefSum:    i64;       { Sum of ref counts }
    szCache:    i32;       { Configured cache size }
    szSpill:    i32;       { Spill threshold }
    szPage:     i32;       { Size of every page }
    szExtra:    i32;       { Size of extra space per page }
    bPurgeable: u8;        { True if pages are on backing store }
    eCreate:    u8;        { eCreate value for xFetch() }
    xStress:    TXStress;  { Call to try to make a page clean }
    pStress:    Pointer;   { Argument to xStress }
    pCache:     Pointer;   { Pluggable cache module (sqlite3_pcache*) }
  end;

const
  PGHDR_CLEAN       = $001;
  PGHDR_DIRTY       = $002;
  PGHDR_WRITEABLE   = $004;
  PGHDR_NEED_SYNC   = $008;
  PGHDR_DONT_WRITE  = $010;
  PGHDR_MMAP        = $020;
  PGHDR_WAL_APPEND  = $040;

  PCACHE_DIRTYLIST_REMOVE = 1;
  PCACHE_DIRTYLIST_ADD    = 2;
  PCACHE_DIRTYLIST_FRONT  = 3;

{ ============================================================
  pcache.c -- generic page cache public interface
  ============================================================ }
function  sqlite3PcacheInitialize: i32;
procedure sqlite3PcacheShutdown;
function  sqlite3PcacheSize: i32;
function  sqlite3PcacheOpen(szPage: i32; szExtra: i32; bPurgeable: i32;
            xStress: TXStress; pStress: Pointer; p: PPCache): i32;
function  sqlite3PcacheSetPageSize(pCache: PPCache; szPage: i32): i32;
function  sqlite3PcacheFetch(pCache: PPCache; pgno: Pgno;
            createFlag: i32): Psqlite3_pcache_page;
function  sqlite3PcacheFetchStress(pCache: PPCache; pgno: Pgno;
            ppPage: PPsqlite3_pcache_page): i32;
function  sqlite3PcacheFetchFinish(pCache: PPCache; pgno: Pgno;
            pPage: Psqlite3_pcache_page): PPgHdr;
procedure sqlite3PcacheRelease(p: PPgHdr);
procedure sqlite3PcacheDrop(p: PPgHdr);
procedure sqlite3PcacheMakeDirty(p: PPgHdr);
procedure sqlite3PcacheMakeClean(p: PPgHdr);
procedure sqlite3PcacheCleanAll(pCache: PPCache);
procedure sqlite3PcacheClearWritable(pCache: PPCache);
procedure sqlite3PcacheClearSyncFlags(pCache: PPCache);
procedure sqlite3PcacheMove(p: PPgHdr; newPgno: Pgno);
procedure sqlite3PcacheTruncate(pCache: PPCache; pgno: Pgno);
procedure sqlite3PcacheClose(pCache: PPCache);
procedure sqlite3PcacheClear(pCache: PPCache);
function  sqlite3PcacheDirtyList(pCache: PPCache): PPgHdr;
function  sqlite3PcacheRefCount(pCache: PPCache): i64;
procedure sqlite3PcacheRef(p: PPgHdr);
function  sqlite3PcachePageRefcount(p: PPgHdr): i64;
function  sqlite3PcachePagecount(pCache: PPCache): i32;
procedure sqlite3PcacheSetCachesize(pCache: PPCache; mxPage: i32);
function  sqlite3PcacheSetSpillsize(p: PPCache; mxPage: i32): i32;
procedure sqlite3PcacheShrink(pCache: PPCache);
function  sqlite3HeaderSizePcache: i32;
function  sqlite3PCachePercentDirty(pCache: PPCache): i32;
{ pcache.c:712 — return non-zero if the cache contains any dirty pages. }
function  sqlite3PCacheIsDirty(pCache: PPCache): i32;

{ ============================================================
  pcache1_g.c -- default LRU backend public interface
  ============================================================ }
procedure sqlite3PCacheBufferSetup(pBuf: Pointer; sz: i32; n: i32);
procedure sqlite3PCacheSetDefault;
function  sqlite3Pcache1MutexActual: Psqlite3_mutex;
function  sqlite3PageMalloc(sz: i32): Pointer;
procedure sqlite3PageFree(p: Pointer);
function  sqlite3HeaderSizePcache1: i32;

implementation

{ ============================================================
  pcache1_g private types
  ============================================================ }
type
  PPgHdr1  = ^PgHdr1;
  PPPgHdr1 = ^PPgHdr1;   { C: PgHdr1 ** }
  PPGroup  = ^PGroup;
  PPCache1 = ^PCache1;
  PPgFreeslot = ^PgFreeslot;

  PgHdr1 = record
    page:        sqlite3_pcache_page; { Base class -- MUST be first (offset 0) }
    iKey:        u32;                 { Page number (hash key) }
    isBulkLocal: u16;                 { From bulk local storage }
    isAnchor:    u16;                 { This is the PGroup.lru anchor }
    pNext:       PPgHdr1;             { Next in hash chain }
    pCache:      PPCache1;            { Owning cache }
    pLruNext:    PPgHdr1;             { Next in LRU circular list }
    pLruPrev:    PPgHdr1;             { Prev in LRU circular list }
  end;

  PGroup = record
    mutex:      Psqlite3_mutex;  { SQLITE_MUTEX_STATIC_LRU or nil }
    nMaxPage:   u32;             { Sum of nMax for purgeable caches }
    nMinPage:   u32;             { Sum of nMin }
    mxPinned:   u32;             { nMaxPage + 10 - nMinPage }
    nPurgeable: u32;             { Number of purgeable pages allocated }
    lru:        PgHdr1;          { The LRU list anchor (isAnchor=1) }
  end;

  PCache1 = record
    pGroup:          PPGroup;    { PGroup this cache belongs to }
    pnPurgeable:     ^u32;       { -> pGroup->nPurgeable or nPurgeableDummy }
    szPage:          i32;
    szExtra:         i32;
    szAlloc:         i32;        { szPage + szExtra + ROUND8(sizeof(PgHdr1)) }
    bPurgeable:      i32;
    nMin:            u32;
    nMax:            u32;
    n90pct:          u32;        { nMax * 9 / 10 }
    iMaxKey:         u32;
    nPurgeableDummy: u32;        { pnPurgeable points here when not used }
    nRecyclable:     u32;
    nPage:           u32;
    nHash:           u32;
    apHash:          PPPgHdr1;   { Hash table array }
    pFree:           PPgHdr1;    { Free local pages }
    pBulk:           Pointer;    { Bulk allocation }
  end;

  PgFreeslot = record
    pNext: PPgFreeslot;
  end;

  PCacheGlobal = record
    grp:            PGroup;
    isInit:         i32;
    separateCache:  i32;
    nInitPage:      i32;
    szSlot:         i32;
    nSlot:          i32;
    nReserve:       i32;
    pStart:         Pointer;
    pEnd:           Pointer;
    mutex:          Psqlite3_mutex;
    pFree:          PPgFreeslot;
    nFreeSlot:      i32;
    bUnderPressure: i32;
  end;

var
  pcache1_g: PCacheGlobal;

{ ============================================================
  pcache1_g inline helpers
  ============================================================ }

function PAGE_IS_PINNED(p: PPgHdr1): Boolean; inline;
begin Result := p^.pLruNext = nil; end;

function PAGE_IS_UNPINNED(p: PPgHdr1): Boolean; inline;
begin Result := p^.pLruNext <> nil; end;

{ Since !SQLITE_ENABLE_MEMORY_MANAGEMENT && SQLITE_THREADSAFE=1,
  PCACHE1_MIGHT_USE_GROUP_MUTEX = 0; the group mutex is always nil.
  These are no-ops. }
procedure pcache1EnterMutex({%H-}pGroup: PPGroup); inline;
begin end;

procedure pcache1LeaveMutex({%H-}pGroup: PPGroup); inline;
begin end;

{ ============================================================
  pcache1_g forward declarations
  ============================================================ }
function  pcache1InitBulk(pCache: PPCache1): i32; forward;
function  pcache1Alloc(nByte: i32): Pointer; forward;
procedure pcache1Free(p: Pointer); forward;
function  pcache1AllocPage(pCache: PPCache1; benignMalloc: i32): PPgHdr1; forward;
procedure pcache1FreePage(p: PPgHdr1); forward;
procedure pcache1ResizeHash(p: PPCache1); forward;
function  pcache1PinPage(pPage: PPgHdr1): PPgHdr1; forward;
procedure pcache1RemoveFromHash(pPage: PPgHdr1; freeFlag: i32); forward;
procedure pcache1EnforceMaxPage(pCache: PPCache1); forward;
procedure pcache1TruncateUnsafe(pCache: PPCache1; iLimit: u32); forward;
function  pcache1UnderMemoryPressure(pCache: PPCache1): i32; forward;
function  pcache1FetchStage2(pCache: PPCache1; iKey: u32; createFlag: i32): PPgHdr1; forward;
function  pcache1FetchNoMutex(p: Pointer; iKey: u32; createFlag: i32): PPgHdr1; forward;
procedure pcache1Destroy(p: Pointer); forward;

{ ============================================================
  pcache.c private helpers
  ============================================================ }

procedure pcacheManageDirtyList(pPage: PPgHdr; addRemove: u8);
var p: PPCache;
begin
  p := pPage^.pCache;
  if (addRemove and PCACHE_DIRTYLIST_REMOVE) <> 0 then begin
    if p^.pSynced = pPage then
      p^.pSynced := pPage^.pDirtyPrev;
    if pPage^.pDirtyNext <> nil then
      pPage^.pDirtyNext^.pDirtyPrev := pPage^.pDirtyPrev
    else
      p^.pDirtyTail := pPage^.pDirtyPrev;
    if pPage^.pDirtyPrev <> nil then
      pPage^.pDirtyPrev^.pDirtyNext := pPage^.pDirtyNext
    else begin
      p^.pDirty := pPage^.pDirtyNext;
      if p^.pDirty = nil then
        p^.eCreate := 2;
    end;
  end;
  if (addRemove and PCACHE_DIRTYLIST_ADD) <> 0 then begin
    pPage^.pDirtyPrev := nil;
    pPage^.pDirtyNext := p^.pDirty;
    if pPage^.pDirtyNext <> nil then
      pPage^.pDirtyNext^.pDirtyPrev := pPage
    else begin
      p^.pDirtyTail := pPage;
      if p^.bPurgeable <> 0 then
        p^.eCreate := 1;
    end;
    p^.pDirty := pPage;
    if (p^.pSynced = nil) and ((pPage^.flags and PGHDR_NEED_SYNC) = 0) then
      p^.pSynced := pPage;
  end;
end;

procedure pcacheUnpin(p: PPgHdr);
begin
  if p^.pCache^.bPurgeable <> 0 then
    sqlite3GlobalConfig.pcache2.xUnpin(p^.pCache^.pCache, p^.pPage, 0);
end;

function numberOfCachePages(p: PPCache): i32;
var n: i64;
begin
  if p^.szCache >= 0 then
    Result := p^.szCache
  else begin
    n := ((-1024 * i64(p^.szCache)) div (p^.szPage + p^.szExtra));
    if n > 1000000000 then n := 1000000000;
    Result := i32(n);
  end;
end;

{ ============================================================
  pcache.c: pcacheFetchFinishWithInit (forward declared implicitly
  via call in sqlite3PcacheFetchFinish defined after)
  ============================================================ }
function pcacheFetchFinishWithInit(pCache: PPCache; pgno: Pgno;
  pPage: Psqlite3_pcache_page): PPgHdr; forward;

{ ============================================================
  pcache.c public functions
  ============================================================ }

function sqlite3PcacheInitialize: i32;
begin
  if not Assigned(sqlite3GlobalConfig.pcache2.xInit) then
    sqlite3PCacheSetDefault;
  Result := sqlite3GlobalConfig.pcache2.xInit(sqlite3GlobalConfig.pcache2.pArg);
end;

procedure sqlite3PcacheShutdown;
begin
  if Assigned(sqlite3GlobalConfig.pcache2.xShutdown) then
    sqlite3GlobalConfig.pcache2.xShutdown(sqlite3GlobalConfig.pcache2.pArg);
end;

function sqlite3PcacheSize: i32;
begin
  Result := SizeOf(PCache);
end;

function sqlite3PcacheOpen(szPage: i32; szExtra: i32; bPurgeable: i32;
  xStress: TXStress; pStress: Pointer; p: PPCache): i32;
begin
  FillChar(p^, SizeOf(PCache), 0);
  p^.szPage      := 1;
  p^.szExtra     := szExtra;
  p^.bPurgeable  := u8(bPurgeable);
  p^.eCreate     := 2;
  p^.xStress     := xStress;
  p^.pStress     := pStress;
  p^.szCache     := 100;
  p^.szSpill     := 1;
  Result := sqlite3PcacheSetPageSize(p, szPage);
end;

function sqlite3PcacheSetPageSize(pCache: PPCache; szPage: i32): i32;
var pNew: Pointer;
begin
  if pCache^.szPage <> 0 then begin
    pNew := sqlite3GlobalConfig.pcache2.xCreate(
              szPage,
              pCache^.szExtra + ROUND8(SizeOf(PgHdr)),
              pCache^.bPurgeable);
    if pNew = nil then begin Result := SQLITE_NOMEM_BKPT; Exit; end;
    sqlite3GlobalConfig.pcache2.xCachesize(pNew, numberOfCachePages(pCache));
    if pCache^.pCache <> nil then
      sqlite3GlobalConfig.pcache2.xDestroy(pCache^.pCache);
    pCache^.pCache := pNew;
    pCache^.szPage := szPage;
  end;
  Result := SQLITE_OK;
end;

function sqlite3PcacheFetch(pCache: PPCache; pgno: Pgno;
  createFlag: i32): Psqlite3_pcache_page;
var eCreate: i32;
begin
  eCreate := createFlag and pCache^.eCreate;
  Result := sqlite3GlobalConfig.pcache2.xFetch(pCache^.pCache, pgno, eCreate);
end;

function sqlite3PcacheFetchStress(pCache: PPCache; pgno: Pgno;
  ppPage: PPsqlite3_pcache_page): i32;
var
  pPg: PPgHdr;
  rc:  i32;
begin
  if pCache^.eCreate = 2 then begin Result := 0; Exit; end;
  if sqlite3PcachePagecount(pCache) > pCache^.szSpill then begin
    pPg := pCache^.pSynced;
    while (pPg <> nil) and
          ((pPg^.nRef <> 0) or ((pPg^.flags and PGHDR_NEED_SYNC) <> 0)) do
      pPg := pPg^.pDirtyPrev;
    pCache^.pSynced := pPg;
    if pPg = nil then begin
      pPg := pCache^.pDirtyTail;
      while (pPg <> nil) and (pPg^.nRef <> 0) do
        pPg := pPg^.pDirtyPrev;
    end;
    if pPg <> nil then begin
      rc := pCache^.xStress(pCache^.pStress, pPg);
      if (rc <> SQLITE_OK) and (rc <> SQLITE_BUSY) then begin
        Result := rc; Exit;
      end;
    end;
  end;
  ppPage^ := sqlite3GlobalConfig.pcache2.xFetch(pCache^.pCache, pgno, 2);
  if ppPage^ = nil then
    Result := SQLITE_NOMEM_BKPT
  else
    Result := SQLITE_OK;
end;

function pcacheFetchFinishWithInit(pCache: PPCache; pgno: Pgno;
  pPage: Psqlite3_pcache_page): PPgHdr;
var
  { Renamed from pgHdr to pHdr to avoid Pascal case-insensitive shadowing of
    the PgHdr record type: SizeOf(PgHdr) in a scope with local 'pgHdr: PPgHdr'
    evaluates to SizeOf(PPgHdr)=8 instead of SizeOf(PgHdr record)=80. }
  pHdr: PPgHdr;
begin
  pHdr := PPgHdr(pPage^.pExtra);
  { Zero entire PgHdr struct, then set required fields.
    C reference only clears pDirty (memset(&p->pDirty,0,sizeof(p->pDirty)));
    we clear the whole struct for safety — it is the same cost. }
  FillChar(pHdr^, SizeOf(PgHdr), 0);
  pHdr^.pPage  := pPage;
  pHdr^.pData  := pPage^.pBuf;
  pHdr^.pExtra := Pointer(pHdr + 1);  { C: (void*)&pHdr[1] }
  { Zero first 8 bytes of user-extra area.  C reference has a latent overflow
    when szExtra=0 (pExtra points exactly past the allocation); guard it here.
    In production use szExtra is always sizeof(MemPage) >> 8, so the guard
    never fires on a real pager — only on bare-cache unit tests. }
  if pCache^.szExtra >= 8 then
    FillChar((pHdr + 1)^, 8, 0);
  pHdr^.pCache := pCache;
  pHdr^.pgno   := pgno;
  pHdr^.flags  := PGHDR_CLEAN;
  Result := sqlite3PcacheFetchFinish(pCache, pgno, pPage);
end;

function sqlite3PcacheFetchFinish(pCache: PPCache; pgno: Pgno;
  pPage: Psqlite3_pcache_page): PPgHdr;
{ local renamed to pHdr (not pgHdr) for the same SizeOf-shadowing reason
  as in pcacheFetchFinishWithInit above — no SizeOf call here, but keep
  the convention consistent. }
var pHdr: PPgHdr;
begin
  pHdr := PPgHdr(pPage^.pExtra);
  if pHdr^.pPage = nil then begin
    Result := pcacheFetchFinishWithInit(pCache, pgno, pPage); Exit;
  end;
  Inc(pCache^.nRefSum);
  Inc(pHdr^.nRef);
  Result := pHdr;
end;

procedure sqlite3PcacheRelease(p: PPgHdr);
begin
  Dec(p^.pCache^.nRefSum);
  Dec(p^.nRef);
  if p^.nRef = 0 then begin
    if (p^.flags and PGHDR_CLEAN) <> 0 then
      pcacheUnpin(p)
    else
      pcacheManageDirtyList(p, PCACHE_DIRTYLIST_FRONT);
  end;
end;

procedure sqlite3PcacheRef(p: PPgHdr);
begin
  Inc(p^.nRef);
  Inc(p^.pCache^.nRefSum);
end;

procedure sqlite3PcacheDrop(p: PPgHdr);
begin
  if (p^.flags and PGHDR_DIRTY) <> 0 then
    pcacheManageDirtyList(p, PCACHE_DIRTYLIST_REMOVE);
  Dec(p^.pCache^.nRefSum);
  sqlite3GlobalConfig.pcache2.xUnpin(p^.pCache^.pCache, p^.pPage, 1);
end;

procedure sqlite3PcacheMakeDirty(p: PPgHdr);
begin
  if (p^.flags and (PGHDR_CLEAN or PGHDR_DONT_WRITE)) <> 0 then begin
    p^.flags := p^.flags and not PGHDR_DONT_WRITE;
    if (p^.flags and PGHDR_CLEAN) <> 0 then begin
      p^.flags := p^.flags xor (PGHDR_DIRTY or PGHDR_CLEAN);
      pcacheManageDirtyList(p, PCACHE_DIRTYLIST_ADD);
    end;
  end;
end;

procedure sqlite3PcacheMakeClean(p: PPgHdr);
begin
  pcacheManageDirtyList(p, PCACHE_DIRTYLIST_REMOVE);
  p^.flags := p^.flags and not (PGHDR_DIRTY or PGHDR_NEED_SYNC or PGHDR_WRITEABLE);
  p^.flags := p^.flags or PGHDR_CLEAN;
  if p^.nRef = 0 then
    pcacheUnpin(p);
end;

procedure sqlite3PcacheCleanAll(pCache: PPCache);
var p: PPgHdr;
begin
  p := pCache^.pDirty;
  while p <> nil do begin
    sqlite3PcacheMakeClean(p);
    p := pCache^.pDirty;
  end;
end;

procedure sqlite3PcacheClearWritable(pCache: PPCache);
var p: PPgHdr;
begin
  p := pCache^.pDirty;
  while p <> nil do begin
    p^.flags := p^.flags and not (PGHDR_NEED_SYNC or PGHDR_WRITEABLE);
    p := p^.pDirtyNext;
  end;
  pCache^.pSynced := pCache^.pDirtyTail;
end;

procedure sqlite3PcacheClearSyncFlags(pCache: PPCache);
var p: PPgHdr;
begin
  p := pCache^.pDirty;
  while p <> nil do begin
    p^.flags := p^.flags and not PGHDR_NEED_SYNC;
    p := p^.pDirtyNext;
  end;
  pCache^.pSynced := pCache^.pDirtyTail;
end;

procedure sqlite3PcacheMove(p: PPgHdr; newPgno: Pgno);
var
  pCache: PPCache;
  pOther: Psqlite3_pcache_page;
  pXPage: PPgHdr;
begin
  pCache := p^.pCache;
  pOther := sqlite3GlobalConfig.pcache2.xFetch(pCache^.pCache, newPgno, 0);
  if pOther <> nil then begin
    pXPage := PPgHdr(pOther^.pExtra);
    Inc(pXPage^.nRef);
    Inc(pCache^.nRefSum);
    sqlite3PcacheDrop(pXPage);
  end;
  sqlite3GlobalConfig.pcache2.xRekey(pCache^.pCache, p^.pPage, p^.pgno, newPgno);
  p^.pgno := newPgno;
  if ((p^.flags and PGHDR_DIRTY) <> 0) and ((p^.flags and PGHDR_NEED_SYNC) <> 0) then
    pcacheManageDirtyList(p, PCACHE_DIRTYLIST_FRONT);
end;

procedure sqlite3PcacheTruncate(pCache: PPCache; pgno: Pgno);
var
  p, pNext: PPgHdr;
  pPage1:   Psqlite3_pcache_page;
begin
  if pCache^.pCache <> nil then begin
    p := pCache^.pDirty;
    while p <> nil do begin
      pNext := p^.pDirtyNext;
      if p^.pgno > pgno then
        sqlite3PcacheMakeClean(p);
      p := pNext;
    end;
    if (pgno = 0) and (pCache^.nRefSum <> 0) then begin
      pPage1 := sqlite3GlobalConfig.pcache2.xFetch(pCache^.pCache, 1, 0);
      if pPage1 <> nil then begin
        FillChar(pPage1^.pBuf^, pCache^.szPage, 0);
        pgno := 1;
      end;
    end;
    sqlite3GlobalConfig.pcache2.xTruncate(pCache^.pCache, pgno + 1);
  end;
end;

procedure sqlite3PcacheClose(pCache: PPCache);
begin
  sqlite3GlobalConfig.pcache2.xDestroy(pCache^.pCache);
end;

procedure sqlite3PcacheClear(pCache: PPCache);
begin
  sqlite3PcacheTruncate(pCache, 0);
end;

function pcacheMergeDirtyList(pA: PPgHdr; pB: PPgHdr): PPgHdr;
var
  res:   PgHdr;
  pTail: PPgHdr;
begin
  FillChar(res, SizeOf(PgHdr), 0);
  pTail := @res;
  repeat
    if pA^.pgno < pB^.pgno then begin
      pTail^.pDirty := pA;
      pTail := pA;
      pA := pA^.pDirty;
      if pA = nil then begin pTail^.pDirty := pB; Break; end;
    end else begin
      pTail^.pDirty := pB;
      pTail := pB;
      pB := pB^.pDirty;
      if pB = nil then begin pTail^.pDirty := pA; Break; end;
    end;
  until False;
  Result := res.pDirty;
end;

const N_SORT_BUCKET = 32;

function pcacheSortDirtyList(pIn: PPgHdr): PPgHdr;
var
  a: array[0..N_SORT_BUCKET - 1] of PPgHdr;
  p: PPgHdr;
  i: i32;
begin
  FillChar(a, SizeOf(a), 0);
  while pIn <> nil do begin
    p   := pIn;
    pIn := p^.pDirty;
    p^.pDirty := nil;
    i := 0;
    while i < N_SORT_BUCKET - 1 do begin
      if a[i] = nil then begin a[i] := p; Break; end
      else begin p := pcacheMergeDirtyList(a[i], p); a[i] := nil; end;
      Inc(i);
    end;
    if i = N_SORT_BUCKET - 1 then
      a[i] := pcacheMergeDirtyList(a[i], p);
  end;
  p := a[0];
  for i := 1 to N_SORT_BUCKET - 1 do begin
    if a[i] = nil then Continue;
    if p <> nil then p := pcacheMergeDirtyList(p, a[i]) else p := a[i];
  end;
  Result := p;
end;

function sqlite3PcacheDirtyList(pCache: PPCache): PPgHdr;
var p: PPgHdr;
begin
  p := pCache^.pDirty;
  while p <> nil do begin
    p^.pDirty := p^.pDirtyNext;
    p := p^.pDirtyNext;
  end;
  Result := pcacheSortDirtyList(pCache^.pDirty);
end;

function sqlite3PcacheRefCount(pCache: PPCache): i64;
begin Result := pCache^.nRefSum; end;

function sqlite3PcachePageRefcount(p: PPgHdr): i64;
begin Result := p^.nRef; end;

function sqlite3PcachePagecount(pCache: PPCache): i32;
begin
  Result := sqlite3GlobalConfig.pcache2.xPagecount(pCache^.pCache);
end;

procedure sqlite3PcacheSetCachesize(pCache: PPCache; mxPage: i32);
begin
  pCache^.szCache := mxPage;
  sqlite3GlobalConfig.pcache2.xCachesize(pCache^.pCache,
                                         numberOfCachePages(pCache));
end;

function sqlite3PcacheSetSpillsize(p: PPCache; mxPage: i32): i32;
var res: i32;
begin
  if mxPage <> 0 then begin
    if mxPage < 0 then
      mxPage := i32((-1024 * i64(mxPage)) div (p^.szPage + p^.szExtra));
    p^.szSpill := mxPage;
  end;
  res := numberOfCachePages(p);
  if res < p^.szSpill then res := p^.szSpill;
  Result := res;
end;

procedure sqlite3PcacheShrink(pCache: PPCache);
begin
  sqlite3GlobalConfig.pcache2.xShrink(pCache^.pCache);
end;

function sqlite3HeaderSizePcache: i32;
begin Result := ROUND8(SizeOf(PgHdr)); end;

function sqlite3PCachePercentDirty(pCache: PPCache): i32;
var
  pDirty: PPgHdr;
  nDirty, nCache: i32;
begin
  nDirty := 0;
  nCache := numberOfCachePages(pCache);
  pDirty := pCache^.pDirty;
  while pDirty <> nil do begin
    Inc(nDirty);
    pDirty := pDirty^.pDirtyNext;
  end;
  if nCache <> 0 then
    Result := i32((i64(nDirty) * 100) div nCache)
  else
    Result := 0;
end;

{ pcache.c:712 — sqlite3PCacheIsDirty.
  Return 1 if any page in the cache is dirty, else 0. }
function sqlite3PCacheIsDirty(pCache: PPCache): i32;
begin
  if pCache^.pDirty <> nil then Result := 1 else Result := 0;
end;

{ ============================================================
  pcache1_g.c implementation
  ============================================================ }

procedure sqlite3PCacheBufferSetup(pBuf: Pointer; sz: i32; n: i32);
var p: PPgFreeslot;
begin
  if pcache1_g.isInit <> 0 then begin
    if pBuf = nil then begin sz := 0; n := 0; end;
    if n = 0 then sz := 0;
    sz := ROUNDDOWN8(sz);
    pcache1_g.szSlot    := sz;
    pcache1_g.nSlot     := n;
    pcache1_g.nFreeSlot := n;
    if n > 90 then pcache1_g.nReserve := 10
    else pcache1_g.nReserve := n div 10 + 1;
    pcache1_g.pStart := pBuf;
    pcache1_g.pFree  := nil;
    pcache1_g.bUnderPressure := 0;
    while n > 0 do begin
      p := PPgFreeslot(pBuf);
      p^.pNext := pcache1_g.pFree;
      pcache1_g.pFree := p;
      pBuf := PByte(pBuf) + sz;
      Dec(n);
    end;
    pcache1_g.pEnd := pBuf;
  end;
end;

function pcache1InitBulk(pCache: PPCache1): i32;
var
  szBulk: i64;
  zBulk:  PByte;
  nBulk:  i32;
  pX:     PPgHdr1;
begin
  Result := 0;
  if pcache1_g.nInitPage = 0 then Exit;
  if pCache^.nMax < 3 then Exit;
  sqlite3BeginBenignMalloc;
  if pcache1_g.nInitPage > 0 then
    szBulk := i64(pCache^.szAlloc) * pcache1_g.nInitPage
  else
    szBulk := -1024 * i64(pcache1_g.nInitPage);
  if szBulk > i64(pCache^.szAlloc) * pCache^.nMax then
    szBulk := i64(pCache^.szAlloc) * pCache^.nMax;
  zBulk := PByte(sqlite3Malloc(i32(szBulk)));
  pCache^.pBulk := zBulk;
  sqlite3EndBenignMalloc;
  if zBulk <> nil then begin
    nBulk := sqlite3MallocSize(zBulk) div pCache^.szAlloc;
    while nBulk > 0 do begin
      pX := PPgHdr1(zBulk + pCache^.szPage);
      pX^.page.pBuf    := zBulk;
      pX^.page.pExtra  := PByte(pX) + ROUND8(SizeOf(PgHdr1));
      pX^.isBulkLocal  := 1;
      pX^.isAnchor     := 0;
      pX^.pNext        := pCache^.pFree;
      pX^.pLruPrev     := nil;
      pCache^.pFree    := pX;
      zBulk := zBulk + pCache^.szAlloc;
      Dec(nBulk);
    end;
  end;
  if pCache^.pFree <> nil then Result := 1 else Result := 0;
end;

function pcache1Alloc(nByte: i32): Pointer;
var p: Pointer;
begin
  p := nil;
  if (pcache1_g.szSlot > 0) and (nByte <= pcache1_g.szSlot) then begin
    sqlite3_mutex_enter(pcache1_g.mutex);
    p := pcache1_g.pFree;
    if p <> nil then begin
      pcache1_g.pFree := pcache1_g.pFree^.pNext;
      Dec(pcache1_g.nFreeSlot);
      if pcache1_g.nFreeSlot < pcache1_g.nReserve then
        pcache1_g.bUnderPressure := 1
      else
        pcache1_g.bUnderPressure := 0;
      sqlite3StatusHighwater(SQLITE_STATUS_PAGECACHE_SIZE, nByte);
      sqlite3StatusUp(SQLITE_STATUS_PAGECACHE_USED, 1);
    end;
    sqlite3_mutex_leave(pcache1_g.mutex);
  end;
  if p = nil then begin
    p := sqlite3Malloc(nByte);
    if p <> nil then begin
      if pcache1_g.mutex <> nil then sqlite3_mutex_enter(pcache1_g.mutex);
      sqlite3StatusHighwater(SQLITE_STATUS_PAGECACHE_SIZE, nByte);
      sqlite3StatusUp(SQLITE_STATUS_PAGECACHE_OVERFLOW, sqlite3MallocSize(p));
      if pcache1_g.mutex <> nil then sqlite3_mutex_leave(pcache1_g.mutex);
    end;
  end;
  Result := p;
end;

procedure pcache1Free(p: Pointer);
var
  pSlot: PPgFreeslot;
  nFreed: i32;
begin
  if p = nil then Exit;
  if SQLITE_WITHIN(p, pcache1_g.pStart, pcache1_g.pEnd) then begin
    sqlite3_mutex_enter(pcache1_g.mutex);
    sqlite3StatusDown(SQLITE_STATUS_PAGECACHE_USED, 1);
    pSlot := PPgFreeslot(p);
    pSlot^.pNext := pcache1_g.pFree;
    pcache1_g.pFree := pSlot;
    Inc(pcache1_g.nFreeSlot);
    if pcache1_g.nFreeSlot < pcache1_g.nReserve then
      pcache1_g.bUnderPressure := 1
    else
      pcache1_g.bUnderPressure := 0;
    sqlite3_mutex_leave(pcache1_g.mutex);
  end else begin
    nFreed := sqlite3MallocSize(p);
    if pcache1_g.mutex <> nil then sqlite3_mutex_enter(pcache1_g.mutex);
    sqlite3StatusDown(SQLITE_STATUS_PAGECACHE_OVERFLOW, nFreed);
    if pcache1_g.mutex <> nil then sqlite3_mutex_leave(pcache1_g.mutex);
    sqlite3_free(p);
  end;
end;

function pcache1UnderMemoryPressure(pCache: PPCache1): i32;
begin
  if (pcache1_g.nSlot <> 0) and
     ((pCache^.szPage + pCache^.szExtra) <= pcache1_g.szSlot) then
    Result := pcache1_g.bUnderPressure
  else
    Result := sqlite3HeapNearlyFull;
end;

function pcache1AllocPage(pCache: PPCache1; benignMalloc: i32): PPgHdr1;
var
  pPg: Pointer;
  p:   PPgHdr1;
begin
  p := nil;
  if (pCache^.pFree <> nil) or
     ((pCache^.nPage = 0) and (pcache1InitBulk(pCache) <> 0)) then begin
    p := pCache^.pFree;
    pCache^.pFree := p^.pNext;
    p^.pNext := nil;
  end else begin
    if benignMalloc <> 0 then sqlite3BeginBenignMalloc;
    pPg := pcache1Alloc(pCache^.szAlloc);
    if benignMalloc <> 0 then sqlite3EndBenignMalloc;
    if pPg = nil then begin Result := nil; Exit; end;
    p := PPgHdr1(PByte(pPg) + pCache^.szPage);
    p^.page.pBuf   := pPg;
    p^.page.pExtra := PByte(p) + ROUND8(SizeOf(PgHdr1));
    p^.isBulkLocal := 0;
    p^.isAnchor    := 0;
    p^.pLruPrev    := nil;
  end;
  Inc(pCache^.pnPurgeable^);
  Result := p;
end;

procedure pcache1FreePage(p: PPgHdr1);
var pCache: PPCache1;
begin
  pCache := p^.pCache;
  if p^.isBulkLocal <> 0 then begin
    p^.pNext := pCache^.pFree;
    pCache^.pFree := p;
  end else
    pcache1Free(p^.page.pBuf);
  Dec(pCache^.pnPurgeable^);
end;

function sqlite3PageMalloc(sz: i32): Pointer;
begin Result := pcache1Alloc(sz); end;

procedure sqlite3PageFree(p: Pointer);
begin pcache1Free(p); end;

procedure pcache1ResizeHash(p: PPCache1);
var
  apNew: PPPgHdr1;
  nNew:  u64;
  i:     u32;
  pPage, pNext: PPgHdr1;
  h:     u32;
begin
  nNew := 2 * u64(p^.nHash);
  if nNew < 256 then nNew := 256;
  pcache1LeaveMutex(p^.pGroup);
  if p^.nHash <> 0 then sqlite3BeginBenignMalloc;
  apNew := PPPgHdr1(sqlite3MallocZero(csize_t(nNew) * SizeOf(PPgHdr1)));
  if p^.nHash <> 0 then sqlite3EndBenignMalloc;
  pcache1EnterMutex(p^.pGroup);
  if apNew <> nil then begin
    { Guard: when nHash=0 the old array is nil; skip rehash loop (in C,
      for(i=0;i<nHash;i++) naturally skips; in Pascal u32 0-1=$FFFFFFFF). }
    if p^.nHash > 0 then begin
      for i := 0 to p^.nHash - 1 do begin
        pNext := p^.apHash[i];
        pPage := pNext;
        while pPage <> nil do begin
          h     := u32(u64(pPage^.iKey) mod nNew);
          pNext := pPage^.pNext;
          pPage^.pNext := apNew[h];
          apNew[h] := pPage;
          pPage := pNext;
        end;
      end;
      sqlite3_free(p^.apHash);
    end;
    p^.apHash := apNew;
    p^.nHash  := u32(nNew);
  end;
end;

function pcache1PinPage(pPage: PPgHdr1): PPgHdr1;
begin
  pPage^.pLruPrev^.pLruNext := pPage^.pLruNext;
  pPage^.pLruNext^.pLruPrev := pPage^.pLruPrev;
  pPage^.pLruNext := nil;
  Dec(pPage^.pCache^.nRecyclable);
  Result := pPage;
end;

procedure pcache1RemoveFromHash(pPage: PPgHdr1; freeFlag: i32);
var
  h:      u32;
  pCache: PPCache1;
  pp:     PPPgHdr1;
begin
  pCache := pPage^.pCache;
  h := pPage^.iKey mod pCache^.nHash;
  pp := @pCache^.apHash[h];
  while pp^ <> pPage do pp := @pp^^.pNext;
  pp^ := pp^^.pNext;
  Dec(pCache^.nPage);
  if freeFlag <> 0 then pcache1FreePage(pPage);
end;

procedure pcache1EnforceMaxPage(pCache: PPCache1);
var
  pGroup: PPGroup;
  p:      PPgHdr1;
begin
  pGroup := pCache^.pGroup;
  while (pGroup^.nPurgeable > pGroup^.nMaxPage) and
        (pGroup^.lru.pLruPrev^.isAnchor = 0) do begin
    p := pGroup^.lru.pLruPrev;
    pcache1PinPage(p);
    pcache1RemoveFromHash(p, 1);
  end;
  if (pCache^.nPage = 0) and (pCache^.pBulk <> nil) then begin
    sqlite3_free(pCache^.pBulk);
    pCache^.pBulk := nil;
    pCache^.pFree := nil;
  end;
end;

procedure pcache1TruncateUnsafe(pCache: PPCache1; iLimit: u32);
var
  h, iStop: u32;
  pp:       PPPgHdr1;
  pPage:    PPgHdr1;
begin
  if pCache^.iMaxKey - iLimit < pCache^.nHash then begin
    h     := iLimit mod pCache^.nHash;
    iStop := pCache^.iMaxKey mod pCache^.nHash;
  end else begin
    h     := pCache^.nHash div 2;
    iStop := h - 1;
  end;
  while True do begin
    pp    := @pCache^.apHash[h];
    pPage := pp^;
    while pPage <> nil do begin
      if pPage^.iKey >= iLimit then begin
        Dec(pCache^.nPage);
        pp^ := pPage^.pNext;
        if PAGE_IS_UNPINNED(pPage) then pcache1PinPage(pPage);
        pcache1FreePage(pPage);
        pPage := pp^;
      end else begin
        pp    := @pPage^.pNext;
        pPage := pp^;
      end;
    end;
    if h = iStop then Break;
    h := (h + 1) mod pCache^.nHash;
  end;
end;

function pcache1Init({%H-}NotUsed: Pointer): i32;
begin
  FillChar(pcache1_g, SizeOf(pcache1_g), 0);
  { Determine mode-1 (separateCache=1) vs mode-2 (separateCache=0).
    SQLITE_THREADSAFE=1, no SQLITE_ENABLE_MEMORY_MANAGEMENT.
    separateCache = (pPage==nil) || (bCoreMutex>0)
    Default config has pPage=nil => separateCache=1 (mode-1). }
  if (sqlite3GlobalConfig.pPage = nil) or (sqlite3GlobalConfig.bCoreMutex > 0) then
    pcache1_g.separateCache := 1
  else
    pcache1_g.separateCache := 0;
  if sqlite3GlobalConfig.bCoreMutex <> 0 then begin
    pcache1_g.grp.mutex := sqlite3MutexAlloc(SQLITE_MUTEX_STATIC_LRU);
    pcache1_g.mutex     := sqlite3MutexAlloc(SQLITE_MUTEX_STATIC_PMEM);
  end;
  if (pcache1_g.separateCache <> 0) and
     (sqlite3GlobalConfig.nPage <> 0) and
     (sqlite3GlobalConfig.pPage = nil) then
    pcache1_g.nInitPage := sqlite3GlobalConfig.nPage
  else
    pcache1_g.nInitPage := 0;
  pcache1_g.grp.mxPinned := 10;
  pcache1_g.isInit := 1;
  { Publish the pcache mutex to the util layer (sqlite3_status needs it) }
  gPcache1Mutex := pcache1_g.mutex;
  Result := SQLITE_OK;
end;

procedure pcache1Shutdown({%H-}NotUsed: Pointer);
begin
  FillChar(pcache1_g, SizeOf(pcache1_g), 0);
end;

function pcache1Create(szPage: i32; szExtra: i32; bPurgeable: i32): Pointer;
var
  pCache: PPCache1;
  { Local named pGrp (not pGroup) to avoid Pascal case-insensitive shadowing of
    the PGroup record type: SizeOf(PGroup) inside a scope with a local 'pGroup'
    variable would evaluate to SizeOf(PPGroup)=8 instead of SizeOf(PGroup)=80. }
  pGrp:   PPGroup;
  sz:     i64;
begin
  sz := SizeOf(PCache1) + SizeOf(PGroup) * pcache1_g.separateCache;
  pCache := PPCache1(sqlite3MallocZero(csize_t(sz)));
  if pCache <> nil then begin
    if pcache1_g.separateCache <> 0 then begin
      pGrp := PPGroup(PByte(pCache) + SizeOf(PCache1));
      pGrp^.mxPinned := 10;
    end else
      pGrp := @pcache1_g.grp;
    pcache1EnterMutex(pGrp);
    if pGrp^.lru.isAnchor = 0 then begin
      pGrp^.lru.isAnchor := 1;
      pGrp^.lru.pLruPrev := @pGrp^.lru;
      pGrp^.lru.pLruNext := @pGrp^.lru;
    end;
    pCache^.pGroup     := pGrp;
    pCache^.szPage     := szPage;
    pCache^.szExtra    := szExtra;
    pCache^.szAlloc    := szPage + szExtra + ROUND8(SizeOf(PgHdr1));
    pCache^.bPurgeable := i32(bPurgeable <> 0);
    pcache1ResizeHash(pCache);
    if bPurgeable <> 0 then begin
      pCache^.nMin := 10;
      Inc(pGrp^.nMinPage, pCache^.nMin);
      pGrp^.mxPinned := pGrp^.nMaxPage + 10 - pGrp^.nMinPage;
      pCache^.pnPurgeable := @pGrp^.nPurgeable;
    end else
      pCache^.pnPurgeable := @pCache^.nPurgeableDummy;
    pcache1LeaveMutex(pGrp);
    if pCache^.nHash = 0 then begin
      pcache1Destroy(Pointer(pCache));
      pCache := nil;
    end;
  end;
  Result := Pointer(pCache);
end;

procedure pcache1Cachesize(p: Pointer; nMax: i32);
var
  pCache: PPCache1;
  pGroup: PPGroup;
  n:      u32;
begin
  pCache := PPCache1(p);
  if pCache^.bPurgeable <> 0 then begin
    pGroup := pCache^.pGroup;
    pcache1EnterMutex(pGroup);
    if nMax < 0 then n := 0 else n := u32(nMax);
    if n > $7FFF0000 - pGroup^.nMaxPage + pCache^.nMax then
      n := $7FFF0000 - pGroup^.nMaxPage + pCache^.nMax;
    pGroup^.nMaxPage := pGroup^.nMaxPage - pCache^.nMax + n;
    pGroup^.mxPinned := pGroup^.nMaxPage + 10 - pGroup^.nMinPage;
    pCache^.nMax   := n;
    pCache^.n90pct := pCache^.nMax * 9 div 10;
    pcache1EnforceMaxPage(pCache);
    pcache1LeaveMutex(pGroup);
  end;
end;

procedure pcache1Shrink(p: Pointer);
var
  pCache:       PPCache1;
  pGroup:       PPGroup;
  savedMaxPage: u32;
begin
  pCache := PPCache1(p);
  if pCache^.bPurgeable <> 0 then begin
    pGroup := pCache^.pGroup;
    pcache1EnterMutex(pGroup);
    savedMaxPage := pGroup^.nMaxPage;
    pGroup^.nMaxPage := 0;
    pcache1EnforceMaxPage(pCache);
    pGroup^.nMaxPage := savedMaxPage;
    pcache1LeaveMutex(pGroup);
  end;
end;

function pcache1Pagecount(p: Pointer): i32;
var
  pCache: PPCache1;
  n:      i32;
begin
  pCache := PPCache1(p);
  pcache1EnterMutex(pCache^.pGroup);
  n := i32(pCache^.nPage);
  pcache1LeaveMutex(pCache^.pGroup);
  Result := n;
end;

function pcache1FetchStage2(pCache: PPCache1; iKey: u32; createFlag: i32): PPgHdr1;
var
  nPinned: u32;
  pGroup:  PPGroup;
  pPage:   PPgHdr1;
  pOther:  PPCache1;
  h:       u32;
begin
  Result := nil;
  pGroup := pCache^.pGroup;
  pPage  := nil;
  nPinned := pCache^.nPage - pCache^.nRecyclable;
  if createFlag = 1 then begin
    if (nPinned >= pGroup^.mxPinned) or
       (nPinned >= pCache^.n90pct) or
       ((pcache1UnderMemoryPressure(pCache) <> 0) and
        (pCache^.nRecyclable < nPinned)) then Exit;
  end;
  if pCache^.nPage >= pCache^.nHash then pcache1ResizeHash(pCache);
  if pCache^.nHash = 0 then Exit;
  { Step 4: Try to recycle a page from LRU }
  if (pCache^.bPurgeable <> 0) and
     (pGroup^.lru.pLruPrev^.isAnchor = 0) and
     ((pCache^.nPage + 1 >= pCache^.nMax) or
      (pcache1UnderMemoryPressure(pCache) <> 0)) then begin
    pPage  := pGroup^.lru.pLruPrev;
    pcache1RemoveFromHash(pPage, 0);
    pcache1PinPage(pPage);
    pOther := pPage^.pCache;
    if pOther^.szAlloc <> pCache^.szAlloc then begin
      pcache1FreePage(pPage);
      pPage := nil;
    end else
      pGroup^.nPurgeable := u32(i32(pGroup^.nPurgeable) -
                                (pOther^.bPurgeable - pCache^.bPurgeable));
  end;
  { Step 5: Allocate new page if no recycled page }
  if pPage = nil then
    pPage := pcache1AllocPage(pCache, i32(createFlag = 1));
  if pPage <> nil then begin
    h := iKey mod pCache^.nHash;
    Inc(pCache^.nPage);
    pPage^.iKey    := iKey;
    pPage^.pNext   := pCache^.apHash[h];
    pPage^.pCache  := pCache;
    pPage^.pLruNext := nil;
    PPointer(pPage^.page.pExtra)^ := nil;
    pCache^.apHash[h] := pPage;
    if iKey > pCache^.iMaxKey then pCache^.iMaxKey := iKey;
  end;
  Result := pPage;
end;

function pcache1FetchNoMutex(p: Pointer; iKey: u32; createFlag: i32): PPgHdr1;
var
  pCache: PPCache1;
  pPage:  PPgHdr1;
begin
  pCache := PPCache1(p);
  pPage  := pCache^.apHash[iKey mod pCache^.nHash];
  while (pPage <> nil) and (pPage^.iKey <> iKey) do
    pPage := pPage^.pNext;
  if pPage <> nil then begin
    if PAGE_IS_UNPINNED(pPage) then Result := pcache1PinPage(pPage)
    else Result := pPage;
  end else if createFlag <> 0 then
    Result := pcache1FetchStage2(pCache, iKey, createFlag)
  else
    Result := nil;
end;

function pcache1Fetch(p: Pointer; iKey: u32; createFlag: i32): Psqlite3_pcache_page;
begin
  Result := Psqlite3_pcache_page(pcache1FetchNoMutex(p, iKey, createFlag));
end;

procedure pcache1Unpin(p: Pointer; pPg: Psqlite3_pcache_page; reuseUnlikely: i32);
var
  pCache:  PPCache1;
  pPage:   PPgHdr1;
  pGroup:  PPGroup;
  ppFirst: PPPgHdr1;
begin
  pCache := PPCache1(p);
  pPage  := PPgHdr1(pPg);
  pGroup := pCache^.pGroup;
  pcache1EnterMutex(pGroup);
  if (reuseUnlikely <> 0) or (pGroup^.nPurgeable > pGroup^.nMaxPage) then
    pcache1RemoveFromHash(pPage, 1)
  else begin
    ppFirst := @pGroup^.lru.pLruNext;
    pPage^.pLruPrev := @pGroup^.lru;
    pPage^.pLruNext := ppFirst^;
    ppFirst^^.pLruPrev := pPage;
    ppFirst^ := pPage;
    Inc(pCache^.nRecyclable);
  end;
  pcache1LeaveMutex(pCache^.pGroup);
end;

procedure pcache1Rekey(p: Pointer; pPg: Psqlite3_pcache_page; iOld: u32; iNew: u32);
var
  pCache:     PPCache1;
  pPage:      PPgHdr1;
  pp:         PPPgHdr1;
  hOld, hNew: u32;
begin
  pCache := PPCache1(p);
  pPage  := PPgHdr1(pPg);
  pcache1EnterMutex(pCache^.pGroup);
  hOld := iOld mod pCache^.nHash;
  pp   := @pCache^.apHash[hOld];
  while pp^ <> pPage do pp := @pp^^.pNext;
  pp^ := pPage^.pNext;
  hNew := iNew mod pCache^.nHash;
  pPage^.iKey  := iNew;
  pPage^.pNext := pCache^.apHash[hNew];
  pCache^.apHash[hNew] := pPage;
  if iNew > pCache^.iMaxKey then pCache^.iMaxKey := iNew;
  pcache1LeaveMutex(pCache^.pGroup);
end;

procedure pcache1Truncate(p: Pointer; iLimit: u32);
var pCache: PPCache1;
begin
  pCache := PPCache1(p);
  pcache1EnterMutex(pCache^.pGroup);
  if iLimit <= pCache^.iMaxKey then begin
    pcache1TruncateUnsafe(pCache, iLimit);
    pCache^.iMaxKey := iLimit - 1;
  end;
  pcache1LeaveMutex(pCache^.pGroup);
end;

procedure pcache1Destroy(p: Pointer);
var
  pCache: PPCache1;
  pGroup: PPGroup;
begin
  pCache := PPCache1(p);
  pGroup := pCache^.pGroup;
  pcache1EnterMutex(pGroup);
  if pCache^.nPage > 0 then pcache1TruncateUnsafe(pCache, 0);
  pGroup^.nMaxPage := pGroup^.nMaxPage - pCache^.nMax;
  pGroup^.nMinPage := pGroup^.nMinPage - pCache^.nMin;
  pGroup^.mxPinned := pGroup^.nMaxPage + 10 - pGroup^.nMinPage;
  pcache1EnforceMaxPage(pCache);
  pcache1LeaveMutex(pGroup);
  sqlite3_free(pCache^.pBulk);
  sqlite3_free(pCache^.apHash);
  sqlite3_free(pCache);
end;

procedure sqlite3PCacheSetDefault;
var m: Tsqlite3_pcache_methods2;
begin
  FillChar(m, SizeOf(m), 0);
  m.iVersion   := 1;
  m.xInit      := @pcache1Init;
  m.xShutdown  := @pcache1Shutdown;
  m.xCreate    := @pcache1Create;
  m.xCachesize := @pcache1Cachesize;
  m.xPagecount := @pcache1Pagecount;
  m.xFetch     := @pcache1Fetch;
  m.xUnpin     := @pcache1Unpin;
  m.xRekey     := @pcache1Rekey;
  m.xTruncate  := @pcache1Truncate;
  m.xDestroy   := @pcache1Destroy;
  m.xShrink    := @pcache1Shrink;
  sqlite3_config(SQLITE_CONFIG_PCACHE2, @m);
end;

function sqlite3HeaderSizePcache1: i32;
begin Result := ROUND8(SizeOf(PgHdr1)); end;

function sqlite3Pcache1MutexActual: Psqlite3_mutex;
begin Result := pcache1_g.mutex; end;

end.
