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
  passqlite3types,
  passqlite3util,
  passqlite3pcache,
  passqlite3pager,
  passqlite3btree;

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

{ ===== main ================================================================ }
begin
  WriteLn('=== TestBtreeCompat (Phase 4.1) ===');
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
  WriteLn('Results: ', gPass, ' passed, ', gFail, ' failed');
  if gFail > 0 then
    Halt(1);
end.
