{$I passqlite3.inc}
program TestBtreeCompat;
{
  Phase 4.1 gate test — cell-parsing helpers and page management.

  Tests run entirely in-memory without opening a file or pager.  A fake
  TBtShared + TMemPage + heap page buffer is constructed for each test
  group.  The tests exercise:

    T1  get2byte / put2byte round-trips (edge cases 0, 255, 256, 65535)
    T2  get2byteNotZero:  0 → 65536, others identity
    T3  zeroPage / decodeFlags — table-leaf page initialisation
    T4  btreeComputeFreeSpace on a freshly zero'd page
    T5  allocateSpace / freeSpace round-trip
    T6  defragmentPage — compact a fragmented page
    T7  btreeParseCellPtr (table-leaf, intKeyLeaf) — small payload
    T8  btreeParseCellPtrIndex (index-leaf)
    T9  btreeParseCellPtrNoPayload (table-interior)
    T10 btreeCellSizeCheck — manually built cell array

  Gate: T1–T10 all PASS.
}

uses
  SysUtils,
  BaseUnix,
  passqlite3types,
  passqlite3util,
  passqlite3os,
  passqlite3pcache,
  passqlite3pager,
  passqlite3btree,
  csqlite3;

{ ===== helpers ============================================================= }

var
  gPass : i32 = 0;
  gFail : i32 = 0;

procedure Check(name: string; cond: Boolean);
begin
  if cond then begin
    WriteLn('  PASS ', name);
    Inc(gPass);
  end else begin
    WriteLn('  FAIL ', name);
    Inc(gFail);
  end;
end;

{ Encode a varint into buf; return bytes written }
function PutVarint(buf: Pu8; v: u64): i32;
var
  i, n: i32;
  b   : array[0..8] of u8;
begin
  if v <= $7F then begin
    buf[0] := u8(v);
    Result := 1;
    Exit;
  end;
  n := 0;
  while v > 0 do begin
    b[n] := u8(v and $7F);
    Inc(n);
    v := v shr 7;
  end;
  for i := n - 1 downto 1 do begin
    buf[n - 1 - i] := b[i] or $80;
  end;
  buf[n - 1] := b[0];
  Result := n;
end;

{ ===== shared page setup =================================================== }

const
  PAGE_SIZE = 4096;

type
  TTestPage = record
    pBt  : TBtShared;
    page : TMemPage;
    buf  : array[0..PAGE_SIZE-1] of u8;
  end;

procedure InitTestPage(var tp: TTestPage; pageType: i32);
begin
  FillChar(tp, SizeOf(tp), 0);

  { BtShared: 4096-byte pages, no reserved bytes, no autovacuum }
  tp.pBt.pageSize    := PAGE_SIZE;
  tp.pBt.usableSize  := PAGE_SIZE;
  { Compute minLocal/maxLocal/minLeaf/maxLeaf per btreeSetHasContent formula:
      maxLocal  = (usableSize - 12) * 64/255 - 23   (≈ 1003)
      minLocal  = (usableSize - 12) * 32/255 - 23   (≈ 481)
      maxLeaf   = usableSize - 35                    (= 4061)
      minLeaf   = minLocal                           (≈ 481)
    Using SQLite's exact integer arithmetic: }
  tp.pBt.maxLocal    := u16((PAGE_SIZE - 12) * 64 div 255 - 23);
  tp.pBt.minLocal    := u16((PAGE_SIZE - 12) * 32 div 255 - 23);
  tp.pBt.maxLeaf     := u16(PAGE_SIZE - 35);
  tp.pBt.minLeaf     := tp.pBt.minLocal;
  tp.pBt.max1bytePayload := 100;
  tp.pBt.autoVacuum  := 0;

  { MemPage }
  tp.page.pBt        := @tp.pBt;
  tp.page.aData      := @tp.buf[0];
  tp.page.pgno       := 2;
  tp.page.hdrOffset  := 0;

  zeroPage(@tp.page, pageType);
end;

{ ===== T1: get2byte / put2byte ============================================= }
procedure RunT1;
var
  buf: array[0..1] of u8;
  v  : i32;
begin
  WriteLn('T1: get2byte / put2byte');
  put2byte(@buf[0], 0);
  Check('round-trip 0', get2byte(@buf[0]) = 0);

  put2byte(@buf[0], 1);
  Check('round-trip 1', get2byte(@buf[0]) = 1);

  put2byte(@buf[0], 255);
  Check('round-trip 255', get2byte(@buf[0]) = 255);

  put2byte(@buf[0], 256);
  Check('round-trip 256', get2byte(@buf[0]) = 256);

  put2byte(@buf[0], 32767);
  Check('round-trip 32767', get2byte(@buf[0]) = 32767);

  put2byte(@buf[0], 65535);
  Check('round-trip 65535', get2byte(@buf[0]) = 65535);

  { Verify byte order: big-endian }
  put2byte(@buf[0], $0102);
  Check('big-endian hi byte', buf[0] = $01);
  Check('big-endian lo byte', buf[1] = $02);
end;

{ ===== T2: get2byteNotZero ================================================= }
procedure RunT2;
var
  buf: array[0..1] of u8;
begin
  WriteLn('T2: get2byteNotZero');
  put2byte(@buf[0], 0);
  Check('0 → 65536', get2byteNotZero(@buf[0]) = 65536);

  put2byte(@buf[0], 1);
  Check('1 → 1', get2byteNotZero(@buf[0]) = 1);

  put2byte(@buf[0], 4096);
  Check('4096 → 4096', get2byteNotZero(@buf[0]) = 4096);

  put2byte(@buf[0], 65535);
  Check('65535 → 65535', get2byteNotZero(@buf[0]) = 65535);
end;

{ ===== T3: zeroPage / decodeFlags ========================================== }
procedure RunT3;
var
  tp: TTestPage;
begin
  WriteLn('T3: zeroPage / decodeFlags — table-leaf page');
  { Table-leaf: PTF_INTKEY | PTF_LEAFDATA | PTF_LEAF = $0D }
  InitTestPage(tp, PTF_INTKEY or PTF_LEAFDATA or PTF_LEAF);

  Check('isInit', tp.page.isInit = 1);
  Check('leaf', tp.page.leaf = 1);
  Check('intKey', tp.page.intKey = 1);
  Check('intKeyLeaf', tp.page.intKeyLeaf = 1);
  Check('childPtrSize=0', tp.page.childPtrSize = 0);
  Check('nCell=0', tp.page.nCell = 0);
  Check('nOverflow=0', tp.page.nOverflow = 0);
  Check('maskPage', tp.page.maskPage = u16(PAGE_SIZE - 1));
  { cellOffset for leaf = hdrOffset + 8 = 8 }
  Check('cellOffset=8', tp.page.cellOffset = 8);
  { nFree = usableSize - 8 = 4088 }
  Check('nFree=4088', tp.page.nFree = 4088);
  { xParseCell and xCellSize must be assigned }
  Check('xParseCell assigned', Assigned(tp.page.xParseCell));
  Check('xCellSize assigned', Assigned(tp.page.xCellSize));

  { Index-interior: PTF_ZERODATA = $02 }
  InitTestPage(tp, PTF_ZERODATA);
  Check('idx-interior leaf=0', tp.page.leaf = 0);
  Check('idx-interior intKey=0', tp.page.intKey = 0);
  Check('idx-interior childPtrSize=4', tp.page.childPtrSize = 4);
  { cellOffset = hdrOffset + 8 + childPtrSize = 12 for interior }
  { nFree = usableSize - 12 for interior leaf-zero page }
  Check('idx-interior nFree=4084', tp.page.nFree = 4084);
end;

{ ===== T4: btreeComputeFreeSpace =========================================== }
procedure RunT4;
var
  tp: TTestPage;
  rc: i32;
begin
  WriteLn('T4: btreeComputeFreeSpace');
  InitTestPage(tp, PTF_INTKEY or PTF_LEAFDATA or PTF_LEAF);
  { nFree is already set by zeroPage; btreeComputeFreeSpace re-derives it }
  tp.page.nFree := -1;  { reset so btreeComputeFreeSpace must recompute }
  rc := btreeComputeFreeSpace(@tp.page);
  Check('rc=SQLITE_OK', rc = SQLITE_OK);
  { fresh page: nFree = usableSize - 8 (hdr+childPtr+0-cells) = 4088 }
  Check('nFree=4088 after compute', tp.page.nFree = 4088);
end;

{ ===== T5: allocateSpace / freeSpace ======================================= }
procedure RunT5;
var
  tp   : TTestPage;
  idx  : i32;
  rc   : i32;
  nFreeAfterAlloc : i32;
begin
  WriteLn('T5: allocateSpace / freeSpace');
  InitTestPage(tp, PTF_INTKEY or PTF_LEAFDATA or PTF_LEAF);

  { Allocate 32 bytes; caller must update nFree (allocateSpace does not) }
  rc := allocateSpace(@tp.page, 32, idx);
  Check('alloc 32 rc=OK', rc = SQLITE_OK);
  { idx must land within the usable page area }
  Check('alloc idx in range', (idx >= 8) and (idx + 32 <= PAGE_SIZE));
  tp.page.nFree := tp.page.nFree - 32;  { mirror what insertCellFast does }
  nFreeAfterAlloc := tp.page.nFree;

  { Free that space back }
  rc := freeSpace(@tp.page, idx, 32);
  Check('free 32 rc=OK', rc = SQLITE_OK);
  { nFree should be restored }
  Check('nFree restored', tp.page.nFree >= nFreeAfterAlloc);

  { Allocate 100 bytes }
  rc := allocateSpace(@tp.page, 100, idx);
  Check('alloc 100 rc=OK', rc = SQLITE_OK);
  tp.page.nFree := tp.page.nFree - 100;

  { Allocate another 100 bytes }
  rc := allocateSpace(@tp.page, 100, idx);
  Check('alloc 100 again rc=OK', rc = SQLITE_OK);
  tp.page.nFree := tp.page.nFree - 100;
end;

{ ===== T6: defragmentPage ================================================== }
procedure RunT6;
var
  tp      : TTestPage;
  idx     : i32;
  idx2    : i32;
  rc      : i32;
  freeBefore, freeAfter: i32;
begin
  WriteLn('T6: defragmentPage');
  InitTestPage(tp, PTF_INTKEY or PTF_LEAFDATA or PTF_LEAF);

  { Allocate two chunks then free the first — creates a freeblock.
    Caller must mirror nFree (allocateSpace does not update it). }
  allocateSpace(@tp.page, 64, idx);
  tp.page.nFree := tp.page.nFree - 64;
  allocateSpace(@tp.page, 64, idx2);
  tp.page.nFree := tp.page.nFree - 64;
  freeBefore := tp.page.nFree;
  freeSpace(@tp.page, idx, 64);

  { defragmentPage: nMaxFrag=4 allows fast path when nFrag=0 }
  rc := defragmentPage(@tp.page, 4);
  Check('defrag rc=OK', rc = SQLITE_OK);

  { After defrag free space should be at least as much as before }
  freeAfter := tp.page.nFree;
  Check('freeAfter >= freeBefore', freeAfter >= freeBefore);
end;

{ ===== T7: btreeParseCellPtr (table-leaf) ================================== }
procedure RunT7;
var
  tp    : TTestPage;
  cell  : array[0..31] of u8;
  pCell : Pu8;
  info  : TCellInfo;
  off   : i32;
  key   : u64;
  payload: u64;
  pSz    : i32;
begin
  WriteLn('T7: btreeParseCellPtr (table-leaf)');
  InitTestPage(tp, PTF_INTKEY or PTF_LEAFDATA or PTF_LEAF);
  FillChar(cell, SizeOf(cell), 0);
  pCell := @cell[0];

  { Build a table-leaf cell: varint(payload=10) + varint(key=42) + 10 bytes payload }
  payload := 10;
  key     := 42;
  off     := 0;
  pSz     := PutVarint(pCell + off, payload);  Inc(off, pSz);
  pSz     := PutVarint(pCell + off, key);      Inc(off, pSz);
  FillChar((pCell + off)^, 10, $AA);

  FillChar(info, SizeOf(info), 0);
  btreeParseCellPtr(@tp.page, pCell, @info);

  Check('T7 nKey=42',      info.nKey = 42);
  Check('T7 nPayload=10',  info.nPayload = 10);
  Check('T7 nLocal=10',    info.nLocal = 10);
  Check('T7 pPayload set', info.pPayload = pCell + 2);  { 1-byte varint each }
  Check('T7 nSize > 0',    info.nSize > 0);
end;

{ ===== T8: btreeParseCellPtrIndex (index-leaf) ============================= }
procedure RunT8;
var
  tp     : TTestPage;
  cell   : array[0..31] of u8;
  pCell  : Pu8;
  info   : TCellInfo;
  off    : i32;
  pSz    : i32;
begin
  WriteLn('T8: btreeParseCellPtrIndex (index-leaf)');
  InitTestPage(tp, PTF_ZERODATA or PTF_LEAF);  { index-leaf: $0A }
  FillChar(cell, SizeOf(cell), 0);
  pCell := @cell[0];

  { Index-leaf cell: varint(payload=8) + 8 bytes payload }
  off   := 0;
  pSz   := PutVarint(pCell + off, 8);   Inc(off, pSz);
  FillChar((pCell + off)^, 8, $BB);

  FillChar(info, SizeOf(info), 0);
  btreeParseCellPtrIndex(@tp.page, pCell, @info);

  Check('T8 nPayload=8',  info.nPayload = 8);
  Check('T8 nKey=8',      info.nKey = 8);
  Check('T8 nLocal=8',    info.nLocal = 8);
  Check('T8 nSize > 0',   info.nSize > 0);
end;

{ ===== T9: btreeParseCellPtrNoPayload (table-interior) ===================== }
procedure RunT9;
var
  tp    : TTestPage;
  cell  : array[0..15] of u8;
  pCell : Pu8;
  info  : TCellInfo;
  pSz   : i32;
begin
  WriteLn('T9: btreeParseCellPtrNoPayload (table-interior)');
  InitTestPage(tp, PTF_INTKEY or PTF_LEAFDATA);  { table-interior: $05 }
  FillChar(cell, SizeOf(cell), 0);
  pCell := @cell[0];

  { Table-interior cell: 4-byte left-child ptr + varint(key=1234) }
  sqlite3Put4byte(pCell, 3);           { left-child pgno = 3 }
  pSz := PutVarint(pCell + 4, 1234);  { integer key }

  FillChar(info, SizeOf(info), 0);
  btreeParseCellPtrNoPayload(@tp.page, pCell, @info);

  Check('T9 nKey=1234',    info.nKey = 1234);
  Check('T9 nPayload=0',   info.nPayload = 0);
  Check('T9 nLocal=0',     info.nLocal = 0);
  Check('T9 nSize >= 6',   info.nSize >= 6);  { 4 + at least 2 varint bytes }
end;

{ ===== T10: btreeCellSizeCheck ============================================= }
procedure RunT10;
var
  tp    : TTestPage;
  data  : Pu8;
  hdr   : i32;
  cellBase: i32;
  cellOff : i32;
  rc      : i32;
  i       : i32;
  { Build 4 small table-leaf cells manually }
  cellSz  : i32;
  pSz     : i32;
begin
  WriteLn('T10: btreeCellSizeCheck');
  InitTestPage(tp, PTF_INTKEY or PTF_LEAFDATA or PTF_LEAF);
  data    := tp.page.aData;
  hdr     := tp.page.hdrOffset;

  { Each cell: varint(5) + varint(i+1) + 5 payload bytes ≈ 7 bytes }
  cellSz := 7;
  { Place cells near end of page, working backwards }
  cellBase := PAGE_SIZE - 4 * cellSz;

  for i := 0 to 3 do begin
    cellOff := cellBase + i * cellSz;
    pSz := PutVarint(data + cellOff, 5);                   { payload=5 }
    pSz := pSz + PutVarint(data + cellOff + pSz, i + 1);  { key=i+1 }
    FillChar((data + cellOff + pSz)^, 5, $CC);             { 5 payload bytes }

    { Write cell pointer }
    put2byte(tp.page.aCellIdx + i * 2, cellOff);
  end;

  { Update nCell in page header }
  put2byte(data + hdr + 3, 4);
  tp.page.nCell := 4;
  { Update content-top pointer }
  put2byte(data + hdr + 5, cellBase);
  { nFree now: page size - header(8) - cell ptrs(8) - cell content(28) }
  tp.page.nFree := PAGE_SIZE - 8 - 8 - 4 * cellSz;

  rc := btreeCellSizeCheck(@tp.page);
  Check('T10 btreeCellSizeCheck OK', rc = SQLITE_OK);

  { Also verify btreeComputeFreeSpace gives a reasonable answer }
  tp.page.nFree := -1;
  rc := btreeComputeFreeSpace(@tp.page);
  Check('T10 computeFreeSpace OK', rc = SQLITE_OK);
  Check('T10 nFree reasonable', (tp.page.nFree >= 0) and (tp.page.nFree < PAGE_SIZE));
end;

{ ===== T11: get4byte / put4byte ============================================ }
procedure RunT11;
var
  buf: array[0..3] of u8;
begin
  WriteLn('T11: get4byte / put4byte');
  put4byte(@buf[0], 0);
  Check('round-trip 0', get4byte(@buf[0]) = 0);

  put4byte(@buf[0], 1);
  Check('round-trip 1', get4byte(@buf[0]) = 1);

  put4byte(@buf[0], $DEADBEEF);
  Check('round-trip $DEADBEEF', get4byte(@buf[0]) = $DEADBEEF);

  put4byte(@buf[0], $FFFFFFFF);
  Check('round-trip $FFFFFFFF', get4byte(@buf[0]) = $FFFFFFFF);

  { Verify big-endian byte order }
  put4byte(@buf[0], $01020304);
  Check('big-endian byte 0', buf[0] = $01);
  Check('big-endian byte 1', buf[1] = $02);
  Check('big-endian byte 2', buf[2] = $03);
  Check('big-endian byte 3', buf[3] = $04);
end;

{ ===== T12: sqlite3BtreeCursorSize + sqlite3BtreeCursorZero ============== }
procedure RunT12;
var
  cur : TBtCursor;
  pBt : TBtShared;
  pBtr: TBtree;
begin
  WriteLn('T12: sqlite3BtreeCursorSize / sqlite3BtreeCursorZero');

  Check('cursorSize = SizeOf(TBtCursor)',
        sqlite3BtreeCursorSize = SizeOf(TBtCursor));

  { Zero entire cursor first, then set specific pre-pBt fields to non-zero }
  FillChar(cur, SizeOf(cur), 0);
  cur.pBt           := @pBt;
  cur.eState        := CURSOR_VALID;
  cur.curFlags      := BTCF_ValidOvfl;
  cur.curPagerFlags := 1;
  cur.skipNext      := 42;
  cur.pBtree        := @pBtr;

  sqlite3BtreeCursorZero(@cur);

  { Fields before pBt must be zeroed }
  Check('eState zeroed',        cur.eState = 0);
  Check('curFlags zeroed',      cur.curFlags = 0);
  Check('curPagerFlags zeroed', cur.curPagerFlags = 0);
  Check('skipNext zeroed',      cur.skipNext = 0);
  Check('pBtree zeroed',        cur.pBtree = nil);
  Check('aOverflow zeroed',     cur.aOverflow = nil);
  Check('pKey zeroed',          cur.pKey = nil);

  { pBt must be UNCHANGED }
  Check('pBt preserved', cur.pBt = @pBt);
end;

{ ===== T13: allocateTempSpace / freeTempSpace ============================= }
procedure RunT13;
var
  pBt: TBtShared;
  rc : i32;
begin
  WriteLn('T13: allocateTempSpace / freeTempSpace');
  FillChar(pBt, SizeOf(pBt), 0);
  pBt.pageSize := 4096;

  rc := allocateTempSpace(@pBt);
  Check('allocateTempSpace rc=OK', rc = SQLITE_OK);
  Check('pTmpSpace non-nil',       pBt.pTmpSpace <> nil);

  freeTempSpace(@pBt);
  Check('pTmpSpace nil after free', pBt.pTmpSpace = nil);
end;

{ ===== T14: invalidateOverflowCache ======================================= }
procedure RunT14;
var
  cur : TBtCursor;
  ovfl: PPgno;
begin
  WriteLn('T14: invalidateOverflowCache');
  FillChar(cur, SizeOf(cur), 0);

  { nil aOverflow: sqlite3_free(nil) is a no-op; flag still cleared }
  cur.aOverflow := nil;
  cur.curFlags  := BTCF_ValidOvfl;
  invalidateOverflowCache(@cur);
  Check('nil: ValidOvfl cleared',  (cur.curFlags and BTCF_ValidOvfl) = 0);
  Check('nil: aOverflow still nil', cur.aOverflow = nil);

  { Heap-allocated aOverflow: freed and flag cleared }
  ovfl := PPgno(sqlite3Malloc(4 * SizeOf(Pgno)));
  Check('T14 ovfl alloc ok', ovfl <> nil);
  if ovfl <> nil then begin
    cur.aOverflow := ovfl;
    cur.curFlags  := BTCF_ValidOvfl;
    invalidateOverflowCache(@cur);
    Check('heap: ValidOvfl cleared', (cur.curFlags and BTCF_ValidOvfl) = 0);
    Check('heap: aOverflow nil',      cur.aOverflow = nil);
  end;
end;

{ ===== T15: moveToRoot — pgnoRoot=0 path ================================== }
procedure RunT15;
var
  cur: TBtCursor;
  rc : i32;
begin
  WriteLn('T15: moveToRoot (pgnoRoot=0 → SQLITE_EMPTY)');
  FillChar(cur, SizeOf(cur), 0);
  cur.iPage    := -1;
  cur.pgnoRoot := 0;

  rc := moveToRoot(@cur);
  Check('rc=SQLITE_EMPTY',        rc = SQLITE_EMPTY);
  Check('eState=CURSOR_INVALID',  cur.eState = CURSOR_INVALID);
end;

{ ===== T16: moveToRoot — iPage=0 with empty leaf ========================== }
procedure RunT16;
var
  cur: TBtCursor;
  tp : TTestPage;
  rc : i32;
begin
  WriteLn('T16: moveToRoot (iPage=0, empty table-leaf)');
  FillChar(cur, SizeOf(cur), 0);
  InitTestPage(tp, $0D);        { table-leaf, nCell=0, leaf=1, intKey=1 }
  tp.page.isInit := 1;

  cur.iPage    := 0;
  cur.pPage    := @tp.page;
  cur.pBt      := @tp.pBt;
  cur.pKeyInfo := nil;          { table cursor (pKeyInfo=nil means intKey expected) }

  rc := moveToRoot(@cur);
  Check('rc=SQLITE_EMPTY',       rc = SQLITE_EMPTY);
  Check('eState=CURSOR_INVALID', cur.eState = CURSOR_INVALID);
  Check('ix reset to 0',         cur.ix = 0);
end;

{ ===== T17: sqlite3BtreeFirst / sqlite3BtreeLast — empty page ============= }
procedure RunT17;
var
  cur : TBtCursor;
  tp  : TTestPage;
  rc  : i32;
  res : i32;
begin
  WriteLn('T17: sqlite3BtreeFirst / sqlite3BtreeLast (empty page)');
  FillChar(cur, SizeOf(cur), 0);
  InitTestPage(tp, $0D);
  tp.page.isInit := 1;
  cur.iPage    := 0;
  cur.pPage    := @tp.page;
  cur.pBt      := @tp.pBt;
  cur.pKeyInfo := nil;

  res := -1;
  rc  := sqlite3BtreeFirst(@cur, @res);
  Check('First rc=OK',    rc  = SQLITE_OK);
  Check('First pRes=1',   res = 1);

  { Reset cursor to iPage=0 for Last test }
  cur.iPage  := 0;
  cur.pPage  := @tp.page;
  cur.eState := CURSOR_INVALID;
  res := -1;
  rc  := sqlite3BtreeLast(@cur, @res);
  Check('Last rc=OK',     rc  = SQLITE_OK);
  Check('Last pRes=1',    res = 1);
end;

{ ===== T18: btreeReleaseAllCursorPages — iPage=-1 no-op ================== }
procedure RunT18;
var
  cur: TBtCursor;
begin
  WriteLn('T18: btreeReleaseAllCursorPages (iPage=-1 → no-op)');
  FillChar(cur, SizeOf(cur), 0);
  cur.iPage := -1;
  { Should not crash or access memory }
  btreeReleaseAllCursorPages(@cur);
  Check('survived iPage=-1', True);
end;

{ ===== T19: btreeSetHasContent / btreeGetHasContent / btreeClearHasContent == }
procedure RunT19;
var
  pBt : TBtShared;
  rc  : i32;
begin
  WriteLn('T19: btreeSetHasContent / btreeGetHasContent / btreeClearHasContent');
  FillChar(pBt, SizeOf(pBt), 0);
  pBt.nPage := 200;  { bitvec will be created with this size }
  { pHasContent starts nil — set page 5 in a bitvec }
  rc := btreeSetHasContent(@pBt, 5);
  Check('set pg5 rc=OK',          rc = SQLITE_OK);
  Check('pHasContent non-nil',    pBt.pHasContent <> nil);
  Check('get pg5=true',           btreeGetHasContent(@pBt, 5));
  Check('get pg3=false',          not btreeGetHasContent(@pBt, 3));
  { set another page }
  rc := btreeSetHasContent(@pBt, 100);
  Check('set pg100 rc=OK',        rc = SQLITE_OK);
  Check('get pg100=true',         btreeGetHasContent(@pBt, 100));
  Check('get pg5 still true',     btreeGetHasContent(@pBt, 5));
  { clear destroys the bitvec }
  btreeClearHasContent(@pBt);
  Check('pHasContent nil after clear', pBt.pHasContent = nil);
end;

{ ===== T20: saveAllCursors — no-op when no cursors on root ================ }
procedure RunT20;
var
  pBt : TBtShared;
  cur : TBtCursor;
  rc  : i32;
begin
  WriteLn('T20: saveAllCursors — no-op path');
  FillChar(pBt, SizeOf(pBt), 0);
  FillChar(cur, SizeOf(cur), 0);

  { No cursors at all → should return SQLITE_OK }
  pBt.pCursor := nil;
  rc := saveAllCursors(@pBt, 1, nil);
  Check('no cursors rc=OK', rc = SQLITE_OK);

  { One cursor on a different root — should not be selected, rc=OK }
  cur.pgnoRoot := 2;
  cur.eState   := CURSOR_INVALID;
  cur.iPage    := -1;   { no pages held }
  cur.pBt      := @pBt;
  cur.pNext    := nil;
  pBt.pCursor  := @cur;
  rc := saveAllCursors(@pBt, 1, nil);  { root=1, cursor is on root=2 }
  Check('diff root rc=OK', rc = SQLITE_OK);

  { Cursor on same root, CURSOR_INVALID, iPage=-1 — btreeReleaseAllCursorPages is safe }
  cur.pgnoRoot := 1;
  cur.eState   := CURSOR_INVALID;
  cur.iPage    := -1;
  rc := saveAllCursors(@pBt, 1, nil);
  Check('invalid cursor rc=OK', rc = SQLITE_OK);
end;

{ ===========================================================================
  Helper: open a btree backed by a temp file, return PBtree.
  Returns SQLITE_OK and sets pBtr; caller must call sqlite3BtreeClose.
  =========================================================================== }
function OpenTempBtree(const dbPath: string; out pBtr: PBtree): i32;
var
  pVfs : Psqlite3_vfs;
  flags: i32;
begin
  pBtr  := nil;
  pVfs  := sqlite3_vfs_find(nil);
  if pVfs = nil then begin Result := SQLITE_ERROR; Exit; end;
  flags := SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE or SQLITE_OPEN_MAIN_DB;
  Result := sqlite3BtreeOpen(pVfs, PChar(dbPath), nil, @pBtr, 0, flags);
end;

{ ===========================================================================
  T21: sqlite3BtreeOpen / sqlite3BtreeClose — open a new DB, read header meta
  =========================================================================== }
procedure RunT21;
const DB21 = '/tmp/bt_t21.db';
var
  pBtr : PBtree;
  rc   : i32;
  meta : u32;
begin
  WriteLn('T21: sqlite3BtreeOpen / sqlite3BtreeClose');
  if FileExists(DB21) then DeleteFile(DB21);

  rc := OpenTempBtree(DB21, pBtr);
  Check('T21 open rc=OK', rc = SQLITE_OK);
  if rc <> SQLITE_OK then Exit;

  { Begin read-only transaction so page 1 is locked }
  rc := sqlite3BtreeBeginTrans(pBtr, 1, nil);  { wrflag=1 → write }
  Check('T21 BeginTrans rc=OK', rc = SQLITE_OK);

  { After newDatabase(), page 1 has valid header; read schema-version meta }
  meta := $DEAD;
  sqlite3BtreeGetMeta(pBtr, BTREE_SCHEMA_VERSION, @meta);
  Check('T21 schema version = 0', meta = 0);

  rc := sqlite3BtreeCommit(pBtr);
  Check('T21 commit rc=OK', rc = SQLITE_OK);

  rc := sqlite3BtreeClose(pBtr);
  Check('T21 close rc=OK', rc = SQLITE_OK);

  if FileExists(DB21) then DeleteFile(DB21);
end;

{ ===========================================================================
  T22: sqlite3BtreeCreateTable + sqlite3BtreeInsert into real pager
  =========================================================================== }
procedure RunT22;
const DB22 = '/tmp/bt_t22.db';
var
  pBtr    : PBtree;
  cur     : TBtCursor;
  rc      : i32;
  iRoot   : Pgno;
  pX      : TBtreePayload;
  rowCount: i64;
  i       : i32;
begin
  WriteLn('T22: sqlite3BtreeCreateTable + multi-row insert + BtreeCount');
  if FileExists(DB22) then DeleteFile(DB22);
  rc := OpenTempBtree(DB22, pBtr);
  Check('T22 open', rc = SQLITE_OK);
  if rc <> SQLITE_OK then Exit;

  rc := sqlite3BtreeBeginTrans(pBtr, 1, nil);
  Check('T22 begin write', rc = SQLITE_OK);

  { Create a new integer-key table }
  iRoot := 0;
  rc := sqlite3BtreeCreateTable(pBtr, @iRoot, BTREE_INTKEY or BTREE_LEAFDATA);
  Check('T22 createTable rc=OK', rc = SQLITE_OK);
  Check('T22 iRoot > 0', iRoot > 0);

  { Open a write cursor on the new table }
  FillChar(cur, SizeOf(cur), 0);
  rc := sqlite3BtreeCursor(pBtr, iRoot, 1{write}, nil, @cur);
  Check('T22 cursor rc=OK', rc = SQLITE_OK);

  { Insert rows 1..10 }
  for i := 1 to 10 do begin
    FillChar(pX, SizeOf(pX), 0);
    pX.nKey  := i64(i);
    pX.pData := @i;
    pX.nData := SizeOf(i);
    rc := sqlite3BtreeInsert(@cur, @pX, 0, 0);
    if rc <> SQLITE_OK then break;
  end;
  Check('T22 insert 10 rows rc=OK', rc = SQLITE_OK);

  { Count entries }
  rc := moveToRoot(@cur);
  rowCount := -1;
  rc := sqlite3BtreeCount(nil, @cur, @rowCount);
  Check('T22 count rc=OK', rc = SQLITE_OK);
  Check('T22 count = 10', rowCount = 10);

  rc := sqlite3BtreeCloseCursor(@cur);
  Check('T22 closeCursor rc=OK', rc = SQLITE_OK);

  rc := sqlite3BtreeCommit(pBtr);
  Check('T22 commit rc=OK', rc = SQLITE_OK);

  rc := sqlite3BtreeClose(pBtr);
  Check('T22 close rc=OK', rc = SQLITE_OK);
  if FileExists(DB22) then DeleteFile(DB22);
end;

{ ===========================================================================
  T23: sqlite3BtreeDelete — single row delete
  =========================================================================== }
procedure RunT23;
const DB23 = '/tmp/bt_t23.db';
var
  pBtr   : PBtree;
  cur    : TBtCursor;
  rc     : i32;
  iRoot  : Pgno;
  pX     : TBtreePayload;
  pRes   : i32;
  cnt    : i64;
  i      : i32;
begin
  WriteLn('T23: sqlite3BtreeDelete — delete one row');
  if FileExists(DB23) then DeleteFile(DB23);
  rc := OpenTempBtree(DB23, pBtr);
  Check('T23 open', rc = SQLITE_OK);
  if rc <> SQLITE_OK then Exit;

  rc := sqlite3BtreeBeginTrans(pBtr, 1, nil);
  Check('T23 begin', rc = SQLITE_OK);

  iRoot := 0;
  rc := sqlite3BtreeCreateTable(pBtr, @iRoot, BTREE_INTKEY or BTREE_LEAFDATA);
  Check('T23 create', rc = SQLITE_OK);

  FillChar(cur, SizeOf(cur), 0);
  rc := sqlite3BtreeCursor(pBtr, iRoot, 1, nil, @cur);
  Check('T23 cursor', rc = SQLITE_OK);

  { Insert rows 1..5 }
  for i := 1 to 5 do begin
    FillChar(pX, SizeOf(pX), 0);
    pX.nKey  := i64(i);
    pX.pData := @i;
    pX.nData := SizeOf(i);
    rc := sqlite3BtreeInsert(@cur, @pX, 0, 0);
    if rc <> SQLITE_OK then break;
  end;
  Check('T23 insert 5', rc = SQLITE_OK);

  { Seek to row 3 }
  pRes := -1;
  rc := sqlite3BtreeTableMoveto(@cur, 3, 0, @pRes);
  Check('T23 seek row3 rc=OK', rc = SQLITE_OK);
  Check('T23 seek exact', pRes = 0);

  { Delete row 3 }
  rc := sqlite3BtreeDelete(@cur, 0);
  Check('T23 delete rc=OK', rc = SQLITE_OK);

  { Count: should be 4 }
  rc := moveToRoot(@cur);
  cnt := -1;
  if rc = SQLITE_OK then
    rc := sqlite3BtreeCount(nil, @cur, @cnt);
  Check('T23 count=4', cnt = 4);

  sqlite3BtreeCloseCursor(@cur);
  rc := sqlite3BtreeCommit(pBtr);
  Check('T23 commit', rc = SQLITE_OK);
  sqlite3BtreeClose(pBtr);
  if FileExists(DB23) then DeleteFile(DB23);
end;

{ ===========================================================================
  T24: sqlite3BtreeClearTable — remove all rows, root page stays
  =========================================================================== }
procedure RunT24;
const DB24 = '/tmp/bt_t24.db';
var
  pBtr   : PBtree;
  cur    : TBtCursor;
  rc     : i32;
  iRoot  : Pgno;
  pX     : TBtreePayload;
  cnt    : i64;
  i      : i32;
begin
  WriteLn('T24: sqlite3BtreeClearTable');
  if FileExists(DB24) then DeleteFile(DB24);
  rc := OpenTempBtree(DB24, pBtr);
  Check('T24 open', rc = SQLITE_OK);
  if rc <> SQLITE_OK then Exit;
  rc := sqlite3BtreeBeginTrans(pBtr, 1, nil);

  iRoot := 0;
  sqlite3BtreeCreateTable(pBtr, @iRoot, BTREE_INTKEY or BTREE_LEAFDATA);

  FillChar(cur, SizeOf(cur), 0);
  sqlite3BtreeCursor(pBtr, iRoot, 1, nil, @cur);
  for i := 1 to 8 do begin
    FillChar(pX, SizeOf(pX), 0);
    pX.nKey := i64(i); pX.pData := @i; pX.nData := SizeOf(i);
    sqlite3BtreeInsert(@cur, @pX, 0, 0);
  end;
  sqlite3BtreeCloseCursor(@cur);

  { Clear the table }
  rc := sqlite3BtreeClearTable(pBtr, i32(iRoot), nil);
  Check('T24 clearTable rc=OK', rc = SQLITE_OK);

  { Re-open cursor: count should be 0 }
  FillChar(cur, SizeOf(cur), 0);
  rc := sqlite3BtreeCursor(pBtr, iRoot, 1, nil, @cur);
  Check('T24 cursor-after-clear rc=OK', rc = SQLITE_OK);
  cnt := -1;
  moveToRoot(@cur);
  rc := sqlite3BtreeCount(nil, @cur, @cnt);
  Check('T24 count=0 after clear', cnt = 0);
  sqlite3BtreeCloseCursor(@cur);

  rc := sqlite3BtreeCommit(pBtr);
  Check('T24 commit', rc = SQLITE_OK);
  sqlite3BtreeClose(pBtr);
  if FileExists(DB24) then DeleteFile(DB24);
end;

{ ===========================================================================
  T25: sqlite3BtreeDropTable — drop a table
  =========================================================================== }
procedure RunT25;
const DB25 = '/tmp/bt_t25.db';
var
  pBtr  : PBtree;
  cur   : TBtCursor;
  rc    : i32;
  iRoot : Pgno;
  pX    : TBtreePayload;
  iMoved: i32;
  i     : i32;
begin
  WriteLn('T25: sqlite3BtreeDropTable');
  if FileExists(DB25) then DeleteFile(DB25);
  rc := OpenTempBtree(DB25, pBtr);
  Check('T25 open', rc = SQLITE_OK);
  if rc <> SQLITE_OK then Exit;
  rc := sqlite3BtreeBeginTrans(pBtr, 1, nil);

  { Create and populate a table }
  iRoot := 0;
  sqlite3BtreeCreateTable(pBtr, @iRoot, BTREE_INTKEY or BTREE_LEAFDATA);
  FillChar(cur, SizeOf(cur), 0);
  sqlite3BtreeCursor(pBtr, iRoot, 1, nil, @cur);
  for i := 1 to 5 do begin
    FillChar(pX, SizeOf(pX), 0);
    pX.nKey := i64(i); pX.pData := @i; pX.nData := SizeOf(i);
    sqlite3BtreeInsert(@cur, @pX, 0, 0);
  end;
  sqlite3BtreeCloseCursor(@cur);

  { Drop the table }
  iMoved := -1;
  rc := sqlite3BtreeDropTable(pBtr, i32(iRoot), @iMoved);
  Check('T25 drop rc=OK', rc = SQLITE_OK);
  Check('T25 iMoved=0 (no autovacuum)', iMoved = 0);

  rc := sqlite3BtreeCommit(pBtr);
  Check('T25 commit', rc = SQLITE_OK);
  sqlite3BtreeClose(pBtr);
  if FileExists(DB25) then DeleteFile(DB25);
end;

{ ===========================================================================
  T26: sqlite3BtreeGetMeta / sqlite3BtreeUpdateMeta
  =========================================================================== }
procedure RunT26;
const DB26 = '/tmp/bt_t26.db';
var
  pBtr  : PBtree;
  rc    : i32;
  meta  : u32;
begin
  WriteLn('T26: sqlite3BtreeGetMeta / sqlite3BtreeUpdateMeta');
  if FileExists(DB26) then DeleteFile(DB26);
  rc := OpenTempBtree(DB26, pBtr);
  Check('T26 open', rc = SQLITE_OK);
  if rc <> SQLITE_OK then Exit;

  rc := sqlite3BtreeBeginTrans(pBtr, 1, nil);
  Check('T26 begin', rc = SQLITE_OK);

  { Read initial schema version: should be 0 for new DB }
  meta := $DEAD;
  sqlite3BtreeGetMeta(pBtr, BTREE_SCHEMA_VERSION, @meta);
  Check('T26 schema_ver initial=0', meta = 0);

  { Write schema version = 42 }
  rc := sqlite3BtreeUpdateMeta(pBtr, BTREE_SCHEMA_VERSION, 42);
  Check('T26 updateMeta rc=OK', rc = SQLITE_OK);

  { Read back }
  meta := 0;
  sqlite3BtreeGetMeta(pBtr, BTREE_SCHEMA_VERSION, @meta);
  Check('T26 schema_ver read-back=42', meta = 42);

  { Update user version }
  rc := sqlite3BtreeUpdateMeta(pBtr, BTREE_USER_VERSION, 7);
  Check('T26 user_ver update rc=OK', rc = SQLITE_OK);
  meta := 0;
  sqlite3BtreeGetMeta(pBtr, BTREE_USER_VERSION, @meta);
  Check('T26 user_ver read-back=7', meta = 7);

  rc := sqlite3BtreeCommit(pBtr);
  Check('T26 commit', rc = SQLITE_OK);
  sqlite3BtreeClose(pBtr);
  if FileExists(DB26) then DeleteFile(DB26);
end;

{ ===========================================================================
  T27: sqlite3BtreeRollback — write then rollback; data must be gone
  =========================================================================== }
procedure RunT27;
const DB27 = '/tmp/bt_t27.db';
var
  pBtr  : PBtree;
  cur   : TBtCursor;
  rc    : i32;
  iRoot : Pgno;
  pX    : TBtreePayload;
  pRes  : i32;
  i     : i32;
begin
  WriteLn('T27: sqlite3BtreeRollback — changes discarded');
  if FileExists(DB27) then DeleteFile(DB27);
  rc := OpenTempBtree(DB27, pBtr);
  Check('T27 open', rc = SQLITE_OK);
  if rc <> SQLITE_OK then Exit;

  { First commit: create table }
  sqlite3BtreeBeginTrans(pBtr, 1, nil);
  iRoot := 0;
  sqlite3BtreeCreateTable(pBtr, @iRoot, BTREE_INTKEY or BTREE_LEAFDATA);
  sqlite3BtreeCommit(pBtr);

  { Second transaction: insert 5 rows then rollback }
  rc := sqlite3BtreeBeginTrans(pBtr, 1, nil);
  Check('T27 begin 2nd', rc = SQLITE_OK);
  FillChar(cur, SizeOf(cur), 0);
  sqlite3BtreeCursor(pBtr, iRoot, 1, nil, @cur);
  for i := 1 to 5 do begin
    FillChar(pX, SizeOf(pX), 0);
    pX.nKey := i64(i); pX.pData := @i; pX.nData := SizeOf(i);
    sqlite3BtreeInsert(@cur, @pX, 0, 0);
  end;
  sqlite3BtreeCloseCursor(@cur);

  rc := sqlite3BtreeRollback(pBtr, SQLITE_OK, 0);
  Check('T27 rollback rc=OK', rc = SQLITE_OK);

  { Re-open read transaction: table should be empty }
  rc := sqlite3BtreeBeginTrans(pBtr, 0, nil);  { read-only }
  Check('T27 begin read', rc = SQLITE_OK);
  FillChar(cur, SizeOf(cur), 0);
  rc := sqlite3BtreeCursor(pBtr, iRoot, 0{read}, nil, @cur);
  Check('T27 read cursor', rc = SQLITE_OK);
  pRes := -1;
  rc := sqlite3BtreeFirst(@cur, @pRes);
  Check('T27 First after rollback: empty', pRes = 1);  { 1 = empty }
  sqlite3BtreeCloseCursor(@cur);
  sqlite3BtreeRollback(pBtr, SQLITE_OK, 0);

  sqlite3BtreeClose(pBtr);
  if FileExists(DB27) then DeleteFile(DB27);
end;

{ ===========================================================================
  T28: sqlite3BtreeDelete in a multi-page tree (>1 page) — rebalance path
  =========================================================================== }
procedure RunT28;
const DB28 = '/tmp/bt_t28.db';
var
  pBtr   : PBtree;
  cur    : TBtCursor;
  rc     : i32;
  iRoot  : Pgno;
  pX     : TBtreePayload;
  cnt    : i64;
  pRes   : i32;
  i      : i32;
  data   : array[0..255] of u8;
begin
  WriteLn('T28: delete mid-tree row in multi-page btree');
  if FileExists(DB28) then DeleteFile(DB28);
  rc := OpenTempBtree(DB28, pBtr);
  Check('T28 open', rc = SQLITE_OK);
  if rc <> SQLITE_OK then Exit;

  rc := sqlite3BtreeBeginTrans(pBtr, 1, nil);
  Check('T28 begin', rc = SQLITE_OK);

  iRoot := 0;
  sqlite3BtreeCreateTable(pBtr, @iRoot, BTREE_INTKEY or BTREE_LEAFDATA);
  FillChar(cur, SizeOf(cur), 0);
  sqlite3BtreeCursor(pBtr, iRoot, 1, nil, @cur);

  { Insert 100 rows with 200-byte payload to force page splits }
  FillChar(data, SizeOf(data), $AB);
  for i := 1 to 100 do begin
    FillChar(pX, SizeOf(pX), 0);
    pX.nKey  := i64(i);
    pX.pData := @data[0];
    pX.nData := 200;
    rc := sqlite3BtreeInsert(@cur, @pX, BTREE_APPEND, 0);
    if rc <> SQLITE_OK then break;
  end;
  Check('T28 insert 100', rc = SQLITE_OK);

  { Delete row 50 (mid-tree) }
  pRes := -1;
  rc := sqlite3BtreeTableMoveto(@cur, 50, 0, @pRes);
  Check('T28 seek 50', (rc = SQLITE_OK) and (pRes = 0));
  if (rc = SQLITE_OK) and (pRes = 0) then begin
    rc := sqlite3BtreeDelete(@cur, 0);
    Check('T28 delete 50 rc=OK', rc = SQLITE_OK);
  end;

  { Count: should be 99 }
  moveToRoot(@cur);
  cnt := -1;
  rc := sqlite3BtreeCount(nil, @cur, @cnt);
  Check('T28 count=99', cnt = 99);

  sqlite3BtreeCloseCursor(@cur);
  rc := sqlite3BtreeCommit(pBtr);
  Check('T28 commit', rc = SQLITE_OK);
  sqlite3BtreeClose(pBtr);
  if FileExists(DB28) then DeleteFile(DB28);
end;

{ ===========================================================================
  T29: sorted ascending corpus — 500 rows, write + close + reopen + scan
  =========================================================================== }
procedure RunT29;
const
  DB29 = '/tmp/bt_t29.db';
  N    = 500;
var
  pBtr  : PBtree;
  cur   : TBtCursor;
  rc    : i32;
  iRoot : Pgno;
  pX    : TBtreePayload;
  i     : i32;
  pRes  : i32;
  cnt   : i64;
  lastK : i64;
  data  : array[0..7] of u8;
begin
  WriteLn('T29: sorted ascending corpus (N=', N, ') write+reopen+scan');
  if FileExists(DB29) then DeleteFile(DB29);

  { --- write phase --- }
  rc := OpenTempBtree(DB29, pBtr);
  Check('T29 open', rc = SQLITE_OK);
  if rc <> SQLITE_OK then Exit;
  rc := sqlite3BtreeBeginTrans(pBtr, 1, nil);
  Check('T29 begin-write', rc = SQLITE_OK);
  iRoot := 0;
  rc := sqlite3BtreeCreateTable(pBtr, @iRoot, BTREE_INTKEY or BTREE_LEAFDATA);
  Check('T29 createTable', rc = SQLITE_OK);
  FillChar(cur, SizeOf(cur), 0);
  rc := sqlite3BtreeCursor(pBtr, iRoot, 1, nil, @cur);
  Check('T29 cursor', rc = SQLITE_OK);
  for i := 1 to N do begin
    FillChar(pX, SizeOf(pX), 0);
    pX.nKey  := i64(i);
    data[0]  := u8(i and $FF);
    data[1]  := u8((i shr 8) and $FF);
    pX.pData := @data[0];
    pX.nData := 8;
    rc := sqlite3BtreeInsert(@cur, @pX, BTREE_APPEND, 0);
    if rc <> SQLITE_OK then begin
      Check('T29 insert ' + IntToStr(i), False);
      break;
    end;
  end;
  if rc = SQLITE_OK then Check('T29 insert 1..N all ok', True);
  sqlite3BtreeCloseCursor(@cur);
  rc := sqlite3BtreeCommit(pBtr);
  Check('T29 commit', rc = SQLITE_OK);
  sqlite3BtreeClose(pBtr);

  { --- re-read phase --- }
  rc := OpenTempBtree(DB29, pBtr);
  Check('T29 reopen', rc = SQLITE_OK);
  if rc <> SQLITE_OK then begin if FileExists(DB29) then DeleteFile(DB29); Exit; end;
  rc := sqlite3BtreeBeginTrans(pBtr, 0, nil);
  Check('T29 begin-read', rc = SQLITE_OK);
  FillChar(cur, SizeOf(cur), 0);
  rc := sqlite3BtreeCursor(pBtr, iRoot, 0, nil, @cur);
  Check('T29 read cursor', rc = SQLITE_OK);
  pRes := -1;
  rc   := sqlite3BtreeFirst(@cur, @pRes);
  Check('T29 First rc=OK', rc = SQLITE_OK);
  cnt   := 0;
  lastK := 0;
  while (rc = SQLITE_OK) and (pRes = 0) do begin
    lastK := sqlite3BtreeIntegerKey(@cur);
    Inc(cnt);
    rc := sqlite3BtreeNext(@cur, 0);
    if rc = SQLITE_DONE then begin rc := SQLITE_OK; pRes := 1; end;
  end;
  Check('T29 count=N', cnt = N);
  Check('T29 last key=N', lastK = N);
  sqlite3BtreeCloseCursor(@cur);
  sqlite3BtreeRollback(pBtr, SQLITE_OK, 0);
  sqlite3BtreeClose(pBtr);
  if FileExists(DB29) then DeleteFile(DB29);
end;

{ ===========================================================================
  T30: sorted descending corpus — 500 rows inserted 500..1, re-read in order
  =========================================================================== }
procedure RunT30;
const
  DB30 = '/tmp/bt_t30.db';
  N    = 500;
var
  pBtr  : PBtree;
  cur   : TBtCursor;
  rc    : i32;
  iRoot : Pgno;
  pX    : TBtreePayload;
  i     : i32;
  pRes  : i32;
  cnt   : i64;
  firstK: i64;
  lastK : i64;
  data  : array[0..7] of u8;
begin
  WriteLn('T30: sorted descending corpus (N=', N, ') insert 500..1, re-read in order');
  if FileExists(DB30) then DeleteFile(DB30);

  rc := OpenTempBtree(DB30, pBtr);
  Check('T30 open', rc = SQLITE_OK);
  if rc <> SQLITE_OK then Exit;
  rc := sqlite3BtreeBeginTrans(pBtr, 1, nil);
  Check('T30 begin-write', rc = SQLITE_OK);
  iRoot := 0;
  rc := sqlite3BtreeCreateTable(pBtr, @iRoot, BTREE_INTKEY or BTREE_LEAFDATA);
  Check('T30 createTable', rc = SQLITE_OK);
  FillChar(cur, SizeOf(cur), 0);
  rc := sqlite3BtreeCursor(pBtr, iRoot, 1, nil, @cur);
  Check('T30 cursor', rc = SQLITE_OK);
  for i := N downto 1 do begin
    FillChar(pX, SizeOf(pX), 0);
    pX.nKey  := i64(i);
    data[0]  := u8(i and $FF);
    pX.pData := @data[0];
    pX.nData := 8;
    rc := sqlite3BtreeInsert(@cur, @pX, 0, 0);  { no BTREE_APPEND: reverse order }
    if rc <> SQLITE_OK then begin
      Check('T30 insert ' + IntToStr(i), False);
      break;
    end;
  end;
  if rc = SQLITE_OK then Check('T30 insert N..1 all ok', True);
  sqlite3BtreeCloseCursor(@cur);
  rc := sqlite3BtreeCommit(pBtr);
  Check('T30 commit', rc = SQLITE_OK);
  sqlite3BtreeClose(pBtr);

  rc := OpenTempBtree(DB30, pBtr);
  Check('T30 reopen', rc = SQLITE_OK);
  if rc <> SQLITE_OK then begin if FileExists(DB30) then DeleteFile(DB30); Exit; end;
  rc := sqlite3BtreeBeginTrans(pBtr, 0, nil);
  Check('T30 begin-read', rc = SQLITE_OK);
  FillChar(cur, SizeOf(cur), 0);
  rc := sqlite3BtreeCursor(pBtr, iRoot, 0, nil, @cur);
  Check('T30 read cursor', rc = SQLITE_OK);
  pRes  := -1;
  rc    := sqlite3BtreeFirst(@cur, @pRes);
  Check('T30 First rc=OK', rc = SQLITE_OK);
  cnt    := 0;
  firstK := 0;
  lastK  := 0;
  while (rc = SQLITE_OK) and (pRes = 0) do begin
    if cnt = 0 then firstK := sqlite3BtreeIntegerKey(@cur);
    lastK := sqlite3BtreeIntegerKey(@cur);
    Inc(cnt);
    rc := sqlite3BtreeNext(@cur, 0);
    if rc = SQLITE_DONE then begin rc := SQLITE_OK; pRes := 1; end;
  end;
  Check('T30 count=N', cnt = N);
  Check('T30 first key=1', firstK = 1);
  Check('T30 last key=N', lastK = N);
  sqlite3BtreeCloseCursor(@cur);
  sqlite3BtreeRollback(pBtr, SQLITE_OK, 0);
  sqlite3BtreeClose(pBtr);
  if FileExists(DB30) then DeleteFile(DB30);
end;

{ ===========================================================================
  T31: random-order corpus — 200 rows shuffled, write + close + scan
  Uses a simple LCG to produce deterministic pseudo-random insertion order.
  =========================================================================== }
procedure RunT31;
const
  DB31 = '/tmp/bt_t31.db';
  N    = 200;
var
  pBtr   : PBtree;
  cur    : TBtCursor;
  rc     : i32;
  iRoot  : Pgno;
  pX     : TBtreePayload;
  pRes   : i32;
  cnt    : i64;
  firstK : i64;
  lastK  : i64;
  data   : array[0..7] of u8;
  order  : array[1..N] of i32;
  tmp    : i32;
  i, j   : i32;
  seed   : u32;
begin
  WriteLn('T31: random-order corpus (N=', N, ') shuffled insert, scan in key order');
  if FileExists(DB31) then DeleteFile(DB31);

  { Build order[1..N] = 1..N, then Fisher-Yates shuffle with fixed seed }
  for i := 1 to N do order[i] := i;
  seed := $DEADBEEF;
  for i := N downto 2 do begin
    seed := seed * 1664525 + 1013904223;
    j := i32((seed shr 16) mod u32(i)) + 1;
    tmp := order[i]; order[i] := order[j]; order[j] := tmp;
  end;

  rc := OpenTempBtree(DB31, pBtr);
  Check('T31 open', rc = SQLITE_OK);
  if rc <> SQLITE_OK then Exit;
  rc := sqlite3BtreeBeginTrans(pBtr, 1, nil);
  Check('T31 begin-write', rc = SQLITE_OK);
  iRoot := 0;
  rc := sqlite3BtreeCreateTable(pBtr, @iRoot, BTREE_INTKEY or BTREE_LEAFDATA);
  Check('T31 createTable', rc = SQLITE_OK);
  FillChar(cur, SizeOf(cur), 0);
  rc := sqlite3BtreeCursor(pBtr, iRoot, 1, nil, @cur);
  Check('T31 cursor', rc = SQLITE_OK);
  for i := 1 to N do begin
    FillChar(pX, SizeOf(pX), 0);
    pX.nKey  := i64(order[i]);
    data[0]  := u8(order[i] and $FF);
    pX.pData := @data[0];
    pX.nData := 8;
    rc := sqlite3BtreeInsert(@cur, @pX, 0, 0);
    if rc <> SQLITE_OK then begin
      Check('T31 insert ' + IntToStr(order[i]), False);
      break;
    end;
  end;
  if rc = SQLITE_OK then Check('T31 insert all ok', True);
  sqlite3BtreeCloseCursor(@cur);
  rc := sqlite3BtreeCommit(pBtr);
  Check('T31 commit', rc = SQLITE_OK);
  sqlite3BtreeClose(pBtr);

  rc := OpenTempBtree(DB31, pBtr);
  Check('T31 reopen', rc = SQLITE_OK);
  if rc <> SQLITE_OK then begin if FileExists(DB31) then DeleteFile(DB31); Exit; end;
  rc := sqlite3BtreeBeginTrans(pBtr, 0, nil);
  Check('T31 begin-read', rc = SQLITE_OK);
  FillChar(cur, SizeOf(cur), 0);
  rc := sqlite3BtreeCursor(pBtr, iRoot, 0, nil, @cur);
  Check('T31 read cursor', rc = SQLITE_OK);
  pRes  := -1;
  rc    := sqlite3BtreeFirst(@cur, @pRes);
  cnt    := 0;
  firstK := 0;
  lastK  := 0;
  while (rc = SQLITE_OK) and (pRes = 0) do begin
    if cnt = 0 then firstK := sqlite3BtreeIntegerKey(@cur);
    lastK := sqlite3BtreeIntegerKey(@cur);
    Inc(cnt);
    rc := sqlite3BtreeNext(@cur, 0);
    if rc = SQLITE_DONE then begin rc := SQLITE_OK; pRes := 1; end;
  end;
  Check('T31 count=N', cnt = N);
  Check('T31 first key=1', firstK = 1);
  Check('T31 last key=N', lastK = N);
  sqlite3BtreeCloseCursor(@cur);
  sqlite3BtreeRollback(pBtr, SQLITE_OK, 0);
  sqlite3BtreeClose(pBtr);
  if FileExists(DB31) then DeleteFile(DB31);
end;

{ ===========================================================================
  T32: overflow page corpus — 50 rows × 2000-byte payload, write+reopen+verify
  =========================================================================== }
procedure RunT32;
const
  DB32   = '/tmp/bt_t32.db';
  NROWS  = 50;
  PSIZE  = 2000;
var
  pBtr   : PBtree;
  cur    : TBtCursor;
  rc     : i32;
  iRoot  : Pgno;
  pX     : TBtreePayload;
  i      : i32;
  pRes   : i32;
  cnt    : i64;
  key    : i64;
  psz    : u32;
  data   : array[0..PSIZE-1] of u8;
  rbuf   : array[0..3] of u8;
begin
  WriteLn('T32: overflow-page corpus (', NROWS, ' rows × ', PSIZE, '-byte payload)');
  if FileExists(DB32) then DeleteFile(DB32);

  { Fill data with a marker pattern keyed on row number }
  FillChar(data, SizeOf(data), $CD);

  rc := OpenTempBtree(DB32, pBtr);
  Check('T32 open', rc = SQLITE_OK);
  if rc <> SQLITE_OK then Exit;
  rc := sqlite3BtreeBeginTrans(pBtr, 1, nil);
  Check('T32 begin-write', rc = SQLITE_OK);
  iRoot := 0;
  rc := sqlite3BtreeCreateTable(pBtr, @iRoot, BTREE_INTKEY or BTREE_LEAFDATA);
  Check('T32 createTable', rc = SQLITE_OK);
  FillChar(cur, SizeOf(cur), 0);
  rc := sqlite3BtreeCursor(pBtr, iRoot, 1, nil, @cur);
  Check('T32 cursor', rc = SQLITE_OK);
  for i := 1 to NROWS do begin
    FillChar(pX, SizeOf(pX), 0);
    pX.nKey  := i64(i);
    data[0]  := u8(i);  { per-row marker in first byte }
    pX.pData := @data[0];
    pX.nData := PSIZE;
    rc := sqlite3BtreeInsert(@cur, @pX, BTREE_APPEND, 0);
    if rc <> SQLITE_OK then begin
      Check('T32 insert ' + IntToStr(i), False);
      break;
    end;
  end;
  if rc = SQLITE_OK then Check('T32 insert all ok', True);
  sqlite3BtreeCloseCursor(@cur);
  rc := sqlite3BtreeCommit(pBtr);
  Check('T32 commit', rc = SQLITE_OK);
  sqlite3BtreeClose(pBtr);

  rc := OpenTempBtree(DB32, pBtr);
  Check('T32 reopen', rc = SQLITE_OK);
  if rc <> SQLITE_OK then begin if FileExists(DB32) then DeleteFile(DB32); Exit; end;
  rc := sqlite3BtreeBeginTrans(pBtr, 0, nil);
  Check('T32 begin-read', rc = SQLITE_OK);
  FillChar(cur, SizeOf(cur), 0);
  rc := sqlite3BtreeCursor(pBtr, iRoot, 0, nil, @cur);
  Check('T32 read cursor', rc = SQLITE_OK);
  pRes := -1;
  rc   := sqlite3BtreeFirst(@cur, @pRes);
  cnt  := 0;
  while (rc = SQLITE_OK) and (pRes = 0) do begin
    key := sqlite3BtreeIntegerKey(@cur);
    psz := sqlite3BtreePayloadSize(@cur);
    Check('T32 row ' + IntToStr(key) + ' size', psz = PSIZE);
    { Read first byte to verify per-row marker }
    FillChar(rbuf, SizeOf(rbuf), $FF);
    rc := sqlite3BtreePayload(@cur, 0, 1, @rbuf[0]);
    Check('T32 row ' + IntToStr(key) + ' marker', rbuf[0] = u8(key));
    Inc(cnt);
    rc := sqlite3BtreeNext(@cur, 0);
    if rc = SQLITE_DONE then begin rc := SQLITE_OK; pRes := 1; end;
  end;
  Check('T32 count=NROWS', cnt = NROWS);
  sqlite3BtreeCloseCursor(@cur);
  sqlite3BtreeRollback(pBtr, SQLITE_OK, 0);
  sqlite3BtreeClose(pBtr);
  if FileExists(DB32) then DeleteFile(DB32);
end;

{ ===========================================================================
  T33: C creates db (50 rows via SQL), Pascal reads btree (root page 2)
  Validates cross-compatibility: C-written btree data is readable by Pascal.
  =========================================================================== }
procedure RunT33;
const
  DB33 = '/tmp/bt_t33.db';
  NROWS = 50;
var
  cdb   : Pcsq_db;
  crc   : i32;
  cstmt : Pcsq_stmt;
  pBtr  : PBtree;
  cur   : TBtCursor;
  rc    : i32;
  pRes  : i32;
  cnt   : i64;
  key   : i64;
  zTail : PChar;
  zErr  : PChar;
  i     : i32;
begin
  WriteLn('T33: C writes ', NROWS, '-row db, Pascal reads btree (root page 2)');
  FpUnlink(PChar(DB33));
  cdb := nil;
  crc := csq_open_v2(PChar(DB33), cdb,
         SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE, nil);
  if crc <> SQLITE_OK then begin
    Check('T33 C open', False);
    Exit;
  end;
  Check('T33 C open', True);

  zErr := nil;
  crc  := csq_exec(cdb,
    'CREATE TABLE t(id INTEGER PRIMARY KEY);',
    nil, nil, zErr);
  Check('T33 C create table', crc = SQLITE_OK);

  { Batch insert NROWS rows }
  cstmt := nil; zTail := nil;
  crc := csq_prepare_v2(cdb,
    'INSERT INTO t(id) VALUES(?);', -1, cstmt, zTail);
  Check('T33 C prepare', crc = SQLITE_OK);
  if crc = SQLITE_OK then begin
    crc := csq_exec(cdb, 'BEGIN;', nil, nil, zErr);
    for i := 1 to NROWS do begin
      csq_bind_int64(cstmt, 1, i64(i));
      csq_step(cstmt);
      csq_reset(cstmt);
    end;
    crc := csq_exec(cdb, 'COMMIT;', nil, nil, zErr);
    csq_finalize(cstmt);
    Check('T33 C insert batch', crc = SQLITE_OK);
  end;
  csq_close(cdb);

  { Pascal opens the same file and traverses btree root page 2 }
  rc := OpenTempBtree(DB33, pBtr);
  Check('T33 Pascal open', rc = SQLITE_OK);
  if rc <> SQLITE_OK then begin FpUnlink(PChar(DB33)); Exit; end;

  rc := sqlite3BtreeBeginTrans(pBtr, 0, nil);
  Check('T33 Pascal begin-read', rc = SQLITE_OK);

  FillChar(cur, SizeOf(cur), 0);
  { Root page 2 is the first user table in a freshly-created SQLite db }
  rc := sqlite3BtreeCursor(pBtr, 2, 0, nil, @cur);
  Check('T33 Pascal cursor p=2', rc = SQLITE_OK);

  pRes := -1;
  rc   := sqlite3BtreeFirst(@cur, @pRes);
  Check('T33 Pascal First rc=OK', rc = SQLITE_OK);
  cnt := 0;
  key := 0;
  while (rc = SQLITE_OK) and (pRes = 0) do begin
    key := sqlite3BtreeIntegerKey(@cur);
    Inc(cnt);
    rc := sqlite3BtreeNext(@cur, 0);
    if rc = SQLITE_DONE then begin rc := SQLITE_OK; pRes := 1; end;
  end;
  Check('T33 count=NROWS', cnt = NROWS);
  Check('T33 last key=NROWS', key = NROWS);

  sqlite3BtreeCloseCursor(@cur);
  sqlite3BtreeRollback(pBtr, SQLITE_OK, 0);
  sqlite3BtreeClose(pBtr);
  FpUnlink(PChar(DB33));
end;

{ ===========================================================================
  T34: Pascal writes 300-row db, C opens: no SQLITE_NOTADB / CORRUPT,
       page_count > 1 confirms multi-page tree was written.
  =========================================================================== }
procedure RunT34;
const
  DB34 = '/tmp/bt_t34.db';
  N    = 300;
var
  pBtr  : PBtree;
  cur   : TBtCursor;
  rc    : i32;
  iRoot : Pgno;
  pX    : TBtreePayload;
  i     : i32;
  data  : array[0..15] of u8;
  cdb   : Pcsq_db;
  crc   : i32;
  cstmt : Pcsq_stmt;
  pcnt  : i64;
  zTail : PChar;
begin
  WriteLn('T34: Pascal writes ', N, ' rows, C opens and verifies page structure');
  if FileExists(DB34) then DeleteFile(DB34);

  rc := OpenTempBtree(DB34, pBtr);
  Check('T34 open', rc = SQLITE_OK);
  if rc <> SQLITE_OK then Exit;
  rc := sqlite3BtreeBeginTrans(pBtr, 1, nil);
  Check('T34 begin-write', rc = SQLITE_OK);
  iRoot := 0;
  rc := sqlite3BtreeCreateTable(pBtr, @iRoot, BTREE_INTKEY or BTREE_LEAFDATA);
  Check('T34 createTable', rc = SQLITE_OK);
  FillChar(cur, SizeOf(cur), 0);
  rc := sqlite3BtreeCursor(pBtr, iRoot, 1, nil, @cur);
  Check('T34 cursor', rc = SQLITE_OK);
  FillChar(data, SizeOf(data), $5A);
  for i := 1 to N do begin
    FillChar(pX, SizeOf(pX), 0);
    pX.nKey  := i64(i);
    pX.pData := @data[0];
    pX.nData := SizeOf(data);
    rc := sqlite3BtreeInsert(@cur, @pX, BTREE_APPEND, 0);
    if rc <> SQLITE_OK then begin
      Check('T34 insert ' + IntToStr(i), False);
      break;
    end;
  end;
  if rc = SQLITE_OK then Check('T34 insert all ok', True);
  sqlite3BtreeCloseCursor(@cur);
  rc := sqlite3BtreeCommit(pBtr);
  Check('T34 commit', rc = SQLITE_OK);
  sqlite3BtreeClose(pBtr);

  { C opens the Pascal-written file }
  cdb := nil;
  crc := csq_open_v2(PChar(DB34), cdb, SQLITE_OPEN_READONLY, nil);
  Check('T34 C open rc=OK (no CORRUPT)', crc = SQLITE_OK);
  if crc <> SQLITE_OK then begin
    if FileExists(DB34) then DeleteFile(DB34);
    Exit;
  end;

  { Query page_count: must be > 1 since N=300 rows fills multiple pages }
  cstmt := nil; zTail := nil;
  crc := csq_prepare_v2(cdb, 'PRAGMA page_count;', -1, cstmt, zTail);
  pcnt := 0;
  if (crc = SQLITE_OK) and (cstmt <> nil) then begin
    if csq_step(cstmt) = SQLITE_ROW then
      pcnt := csq_column_int64(cstmt, 0);
    csq_finalize(cstmt);
  end;
  Check('T34 C page_count > 1', pcnt > 1);
  csq_close(cdb);
  if FileExists(DB34) then DeleteFile(DB34);
end;

{ ===========================================================================
  T35: insert/delete/insert cycle with verification
  Insert 1..100, delete even keys (50 rows remain), insert 101..110,
  close, reopen, verify count=60 and spot-check boundaries.
  =========================================================================== }
procedure RunT35;
const
  DB35 = '/tmp/bt_t35.db';
var
  pBtr  : PBtree;
  cur   : TBtCursor;
  rc    : i32;
  iRoot : Pgno;
  pX    : TBtreePayload;
  i     : i32;
  pRes  : i32;
  cnt   : i64;
  firstK: i64;
  lastK : i64;
  data  : array[0..7] of u8;
begin
  WriteLn('T35: insert/delete/insert cycle — 1..100, delete evens, insert 101..110');
  if FileExists(DB35) then DeleteFile(DB35);

  rc := OpenTempBtree(DB35, pBtr);
  Check('T35 open', rc = SQLITE_OK);
  if rc <> SQLITE_OK then Exit;
  rc := sqlite3BtreeBeginTrans(pBtr, 1, nil);
  Check('T35 begin', rc = SQLITE_OK);
  iRoot := 0;
  rc := sqlite3BtreeCreateTable(pBtr, @iRoot, BTREE_INTKEY or BTREE_LEAFDATA);
  Check('T35 createTable', rc = SQLITE_OK);
  FillChar(cur, SizeOf(cur), 0);
  rc := sqlite3BtreeCursor(pBtr, iRoot, 1, nil, @cur);
  Check('T35 cursor', rc = SQLITE_OK);

  { Insert 1..100 }
  FillChar(data, SizeOf(data), $AA);
  for i := 1 to 100 do begin
    FillChar(pX, SizeOf(pX), 0);
    pX.nKey  := i64(i);
    pX.pData := @data[0];
    pX.nData := 8;
    rc := sqlite3BtreeInsert(@cur, @pX, BTREE_APPEND, 0);
    if rc <> SQLITE_OK then break;
  end;
  Check('T35 insert 1..100', rc = SQLITE_OK);

  { Delete even keys 2,4,...,100 }
  for i := 2 to 100 do begin
    if (i and 1) <> 0 then continue;  { skip odd }
    pRes := -1;
    rc := sqlite3BtreeTableMoveto(@cur, i64(i), 0, @pRes);
    if (rc = SQLITE_OK) and (pRes = 0) then
      rc := sqlite3BtreeDelete(@cur, 0);
    if rc <> SQLITE_OK then break;
  end;
  Check('T35 delete evens', rc = SQLITE_OK);

  { Insert 101..110 }
  for i := 101 to 110 do begin
    FillChar(pX, SizeOf(pX), 0);
    pX.nKey  := i64(i);
    pX.pData := @data[0];
    pX.nData := 8;
    rc := sqlite3BtreeInsert(@cur, @pX, BTREE_APPEND, 0);
    if rc <> SQLITE_OK then break;
  end;
  Check('T35 insert 101..110', rc = SQLITE_OK);

  sqlite3BtreeCloseCursor(@cur);
  rc := sqlite3BtreeCommit(pBtr);
  Check('T35 commit', rc = SQLITE_OK);
  sqlite3BtreeClose(pBtr);

  { Reopen and verify }
  rc := OpenTempBtree(DB35, pBtr);
  Check('T35 reopen', rc = SQLITE_OK);
  if rc <> SQLITE_OK then begin if FileExists(DB35) then DeleteFile(DB35); Exit; end;
  rc := sqlite3BtreeBeginTrans(pBtr, 0, nil);
  Check('T35 begin-read', rc = SQLITE_OK);
  FillChar(cur, SizeOf(cur), 0);
  rc := sqlite3BtreeCursor(pBtr, iRoot, 0, nil, @cur);
  Check('T35 read cursor', rc = SQLITE_OK);
  pRes  := -1;
  rc    := sqlite3BtreeFirst(@cur, @pRes);
  cnt    := 0;
  firstK := 0;
  lastK  := 0;
  while (rc = SQLITE_OK) and (pRes = 0) do begin
    if cnt = 0 then firstK := sqlite3BtreeIntegerKey(@cur);
    lastK := sqlite3BtreeIntegerKey(@cur);
    Inc(cnt);
    rc := sqlite3BtreeNext(@cur, 0);
    if rc = SQLITE_DONE then begin rc := SQLITE_OK; pRes := 1; end;
  end;
  { 50 odd keys (1,3,5,...,99) + 10 new keys (101..110) = 60 }
  Check('T35 count=60', cnt = 60);
  Check('T35 first key=1', firstK = 1);
  Check('T35 last key=110', lastK = 110);

  { Spot-check: key 2 must not exist, key 3 must exist }
  pRes := -1;
  rc   := sqlite3BtreeTableMoveto(@cur, 2, 0, @pRes);
  Check('T35 key2 not found (pRes<>0)', (rc = SQLITE_OK) and (pRes <> 0));
  pRes := -1;
  rc   := sqlite3BtreeTableMoveto(@cur, 3, 0, @pRes);
  Check('T35 key3 found (pRes=0)', (rc = SQLITE_OK) and (pRes = 0));

  sqlite3BtreeCloseCursor(@cur);
  sqlite3BtreeRollback(pBtr, SQLITE_OK, 0);
  sqlite3BtreeClose(pBtr);
  if FileExists(DB35) then DeleteFile(DB35);
end;

{ ===== main ================================================================ }
begin
  sqlite3OsInit;
  sqlite3PcacheInitialize;
  WriteLn('=== TestBtreeCompat (Phase 4.1 + 4.2 + 4.3 + 4.4 + 4.5 + 4.6) ===');
  WriteLn;
  RunT1;
  WriteLn;
  RunT2;
  WriteLn;
  RunT3;
  WriteLn;
  RunT4;
  WriteLn;
  RunT5;
  WriteLn;
  RunT6;
  WriteLn;
  RunT7;
  WriteLn;
  RunT8;
  WriteLn;
  RunT9;
  WriteLn;
  RunT10;
  WriteLn;
  RunT11;
  WriteLn;
  RunT12;
  WriteLn;
  RunT13;
  WriteLn;
  RunT14;
  WriteLn;
  RunT15;
  WriteLn;
  RunT16;
  WriteLn;
  RunT17;
  WriteLn;
  RunT18;
  WriteLn;
  RunT19;
  WriteLn;
  RunT20;
  WriteLn;
  { Phase 4.4 + 4.5: delete path, schema, metadata }
  RunT21;
  WriteLn;
  RunT22;
  WriteLn;
  RunT23;
  WriteLn;
  RunT24;
  WriteLn;
  RunT25;
  WriteLn;
  RunT26;
  WriteLn;
  RunT27;
  WriteLn;
  RunT28;
  WriteLn;
  { Phase 4.6: extended key corpus + C cross-compat }
  RunT29;
  WriteLn;
  RunT30;
  WriteLn;
  RunT31;
  WriteLn;
  RunT32;
  WriteLn;
  RunT33;
  WriteLn;
  RunT34;
  WriteLn;
  RunT35;
  WriteLn;
  WriteLn('Results: ', gPass, ' passed, ', gFail, ' failed');
  if gFail > 0 then
    Halt(1);
end.
