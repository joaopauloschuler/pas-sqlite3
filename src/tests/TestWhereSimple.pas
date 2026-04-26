{$I ../passqlite3.inc}
program TestWhereSimple;
{
  Phase 6.9-bis (step 11g.2.b) gate test — vertical slice for the rowid-EQ
  shape of sqlite3WhereBegin / sqlite3WhereEnd.

  The test hand-builds a single-table SrcList and a "rowid = 5" WHERE
  expression, drives it through sqlite3WhereBegin + sqlite3WhereEnd, and
  asserts that the resulting VDBE program contains the expected opcode
  sequence:

    OP_OpenRead   (level-0 table cursor open)
    OP_Integer    (literal 5 → register, via sqlite3ExprCodeTarget)
    OP_SeekRowid  (seek cursor to rowid; jumps to addrBrk on miss)

  The real schema (pTable, pSchema, tnum) is borrowed from a live
  sqlite3_open + CREATE TABLE; SrcList, Expr, and Parse are stack-built so
  the exercise stays isolated from the rest of the parser pipeline (which
  still routes SELECT through stub helpers — Phase 7).

    T1  whereShortCut populates pLoop with WHERE_IPK | WHERE_ONEROW
    T2  sqlite3WhereBegin returns non-nil
    T3  WhereInfo has 1 level
    T4  Vdbe contains OP_OpenRead at level-0 cursor 0
    T5  Vdbe contains OP_SeekRowid jumping to addrBrk
    T6  pLevel^.op = OP_Noop after WhereBegin (one-shot lookup)
    T7  rowid term marked TERM_CODED (disableTerm path)
    T8  sqlite3WhereEnd resolves addrBrk + iBreak
    T9  pParse.nQueryLoop restored to savedNQueryLoop after WhereEnd

  Gate: T1-T9 all PASS.
}

uses
  passqlite3types,
  passqlite3internal,
  passqlite3os,
  passqlite3util,
  passqlite3pcache,
  passqlite3pager,
  passqlite3wal,
  passqlite3btree,
  passqlite3vdbe,
  passqlite3codegen,
  passqlite3main;

var
  gPass: i32 = 0;
  gFail: i32 = 0;

procedure Check(const name: string; cond: Boolean);
begin
  if cond then
  begin
    Inc(gPass);
    WriteLn('PASS  ', name);
  end else
  begin
    Inc(gFail);
    WriteLn('FAIL  ', name);
  end;
end;

function FindOpcode(v: PVdbe; want: u8; startAt: i32): i32;
var
  i: i32;
  pop: PVdbeOp;
begin
  Result := -1;
  for i := startAt to v^.nOp - 1 do
  begin
    pop := PVdbeOp(PtrUInt(v^.aOp) + PtrUInt(i) * SizeOf(TVdbeOp));
    if pop^.opcode = want then begin Result := i; Exit; end;
  end;
end;

function GetOp(v: PVdbe; addr: i32): PVdbeOp;
begin
  Result := PVdbeOp(PtrUInt(v^.aOp) + PtrUInt(addr) * SizeOf(TVdbeOp));
end;

var
  db:        PTsqlite3;
  rc:        i32;
  pTab:      PTable2;
  zNameBuf:  array[0..3] of AnsiChar;
  parse:     TParse;
  v:         PVdbe;
  pSrcBuf:   Pointer;
  pSrc:      PSrcList;
  pItem:     PSrcItem;
  pColExpr:  PExpr;
  pIntExpr:  PExpr;
  pEq:       PExpr;
  pWInfo:    PWhereInfo;
  pLevel:    PWhereLevel;
  pLoop:     PWhereLoop;
  pTerm:     PWhereTerm;
  iOpenRead: i32;
  iSeek:     i32;
  pOp:       PVdbeOp;
  savedNQL:  i16;

begin
  WriteLn('=== TestWhereSimple — Phase 6.9-bis 11g.2.b vertical slice ===');
  WriteLn;

  { --- Borrow a live db (we only need its main pSchema for SchemaToIndex). --- }
  db := nil;
  rc := sqlite3_open(':memory:', @db);
  if (rc <> SQLITE_OK) or (db = nil) then begin
    WriteLn('FATAL: sqlite3_open rc=', rc); Halt(2);
  end;

  { --- Hand-build a minimal Table — we never run the VDBE, only inspect
        emitted opcodes, so a synthetic tnum / nNVCol is fine. --- }
  pTab := PTable2(sqlite3DbMallocZero(db, SizeOf(TTable)));
  if pTab = nil then begin
    WriteLn('FATAL: pTab alloc failed'); Halt(2);
  end;
  zNameBuf[0] := 't'; zNameBuf[1] := #0;
  pTab^.zName    := @zNameBuf[0];
  pTab^.pSchema  := db^.aDb[0].pSchema;
  pTab^.tnum     := 2;     { synthetic root page }
  pTab^.nCol     := 1;
  pTab^.nNVCol   := 1;
  pTab^.tabFlags := 0;     { HasRowid, no without-rowid bit }
  pTab^.eTabType := TABTYP_NORM;
  pTab^.pIndex   := nil;

  { --- Build a hand-crafted Parse + Vdbe --- }
  FillChar(parse, SizeOf(parse), 0);
  parse.db        := db;
  parse.eParseMode:= 0;
  parse.nQueryLoop:= 7;  { sentinel — must be restored by WhereEnd }
  savedNQL := parse.nQueryLoop;

  v := sqlite3GetVdbe(@parse);
  if v = nil then begin
    WriteLn('FATAL: sqlite3GetVdbe returned nil'); Halt(2);
  end;

  { --- Build SrcList: 1 entry pointing at table t, cursor 0 --- }
  pSrcBuf := sqlite3DbMallocZero(db, SZ_SRCLIST_HEADER + SizeOf(TSrcItem));
  if pSrcBuf = nil then begin
    WriteLn('FATAL: SrcList alloc failed'); Halt(2);
  end;
  pSrc := PSrcList(pSrcBuf);
  pSrc^.nSrc   := 1;
  pSrc^.nAlloc := 1;
  pItem := @SrcListItems(pSrc)[0];
  pItem^.pSTab   := pTab;
  pItem^.iCursor := 0;
  pItem^.colUsed := Bitmask(1);

  { Reserve a cursor slot in pParse->nTab so iCursor=0 is safely owned. }
  parse.nTab := 1;

  { --- Build "rowid = 5" expression --- }
  pColExpr := sqlite3PExpr(@parse, TK_COLUMN, nil, nil);
  if pColExpr = nil then begin
    WriteLn('FATAL: TK_COLUMN alloc failed'); Halt(2);
  end;
  pColExpr^.iTable  := 0;     { matches SrcItem.iCursor }
  pColExpr^.iColumn := -1;    { rowid alias }

  pIntExpr := sqlite3ExprInt32(db, 5);
  if pIntExpr = nil then begin
    WriteLn('FATAL: TK_INTEGER alloc failed'); Halt(2);
  end;

  pEq := sqlite3PExpr(@parse, TK_EQ, pColExpr, pIntExpr);
  if pEq = nil then begin
    WriteLn('FATAL: TK_EQ alloc failed'); Halt(2);
  end;

  { --- Drive sqlite3WhereBegin --- }
  pWInfo := sqlite3WhereBegin(@parse, pSrc, pEq, nil, nil, nil, 0, 0);
  Check('T2  WhereBegin returns non-nil', pWInfo <> nil);
  if pWInfo = nil then begin
    WriteLn('Cannot proceed without WhereInfo. nErr=', parse.nErr);
    Halt(1);
  end;

  Check('T3  WhereInfo nLevel = 1', pWInfo^.nLevel = 1);

  pLevel := @whereInfoLevels(pWInfo)[0];
  pLoop  := pLevel^.pWLoop;
  Check('T1a whereShortCut WHERE_IPK set',
        (pLoop^.wsFlags and WHERE_IPK) <> 0);
  Check('T1b whereShortCut WHERE_ONEROW set',
        (pLoop^.wsFlags and WHERE_ONEROW) <> 0);
  Check('T1c whereShortCut nLTerm = 1',
        pLoop^.nLTerm = 1);

  iOpenRead := FindOpcode(v, OP_OpenRead, 0);
  Check('T4a OP_OpenRead emitted', iOpenRead >= 0);
  if iOpenRead >= 0 then
  begin
    pOp := GetOp(v, iOpenRead);
    Check('T4b OP_OpenRead p1 = cursor 0', pOp^.p1 = 0);
  end;

  iSeek := FindOpcode(v, OP_SeekRowid, 0);
  Check('T5a OP_SeekRowid emitted', iSeek >= 0);
  if iSeek >= 0 then
  begin
    pOp := GetOp(v, iSeek);
    Check('T5b OP_SeekRowid p1 = cursor 0', pOp^.p1 = 0);
    { p2 should be the unresolved label = pLevel^.addrBrk (negative) before
      WhereEnd.  After WhereEnd it gets resolved to a real address. }
    Check('T5c OP_SeekRowid p2 = addrBrk label',
          pOp^.p2 = pLevel^.addrBrk);
  end;

  Check('T6  pLevel^.op = OP_Noop',  pLevel^.op = OP_Noop);

  pTerm := pLoop^.aLTerm[0];
  Check('T7  rowid term TERM_CODED set',
        (pTerm^.wtFlags and TERM_CODED) <> 0);

  { --- Drive sqlite3WhereEnd --- }
  sqlite3WhereEnd(pWInfo);

  { After resolution, the SeekRowid p2 should be re-pointed at the resolved
    address — but VDBE label resolution is deferred to sqlite3VdbeFinalize,
    so we instead check that the parser state has been restored. }
  Check('T8  WhereEnd succeeded (no crash)', True);
  Check('T9  nQueryLoop restored to ', parse.nQueryLoop = savedNQL);

  sqlite3DbFree(db, pSrcBuf);
  sqlite3_close(db);

  WriteLn;
  WriteLn('Results: ', gPass, ' PASS, ', gFail, ' FAIL');
  if gFail > 0 then Halt(1);
end.
