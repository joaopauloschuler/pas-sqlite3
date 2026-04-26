{$I ../passqlite3.inc}
program TestDbstat;

{
  Phase 6.bis.2d gate — dbstat.c port (passqlite3dbstat).

  Exercises:
    * sqlite3DbstatRegister installs `dbstat` in db^.aModule with the
      expected slot pointers (v1 layout — only read-side slots wired,
      xUpdate/xBegin/xSync/xRollbackTo all nil).
    * statBestIndex constraint dispatch — every combination of
      (schema/name/aggregate) idxNum bits (0x01/0x02/0x04), the
      ORDER BY name consumption (0x08), and the SQLITE_CONSTRAINT
      failure path when an EQ constraint on those hidden columns
      is unusable.
    * statOpen → cursor allocated zeroed with iDb propagated from the
      table; statClose tears it down.
    * Schema-column ordinal pin (12 columns total).

  Not exercised here (deferred to the end-to-end SQL gate 6.9):
    * xFilter / xNext page-walk — require a live db with a real
      Btree, sqlite3_prepare_v2 going through the parser, and a
      schema iterator that returns rootpage>0 entries.
    * xColumn data dispatch — needs a live VDBE op-dispatch context.
    * statDecodePage / statSizeAndOffset — exercised indirectly by
      the page-walk test above.
}

uses
  SysUtils,
  passqlite3types,
  passqlite3util,
  passqlite3os,
  passqlite3vdbe,
  passqlite3vtab,
  passqlite3main,
  passqlite3dbstat;

var
  gPass, gFail: i32;

procedure Expect(cond: Boolean; const msg: AnsiString);
begin
  if cond then begin Inc(gPass); WriteLn('  PASS ', msg); end
  else        begin Inc(gFail); WriteLn('  FAIL ', msg); end;
end;

procedure ExpectEq(a, b: i32; const msg: AnsiString);
begin
  Expect(a = b, msg + ' (got ' + IntToStr(a) + ', expected ' + IntToStr(b) + ')');
end;

procedure WireIdxInfo(var info: Tsqlite3_index_info;
                      pCons: PSqlite3IndexConstraint;
                      pUse:  PSqlite3IndexConstraintUsage;
                      n: i32;
                      pOrd:  PSqlite3IndexOrderBy = nil;
                      nOrd: i32 = 0);
begin
  FillChar(info, SizeOf(info), 0);
  info.nConstraint      := n;
  info.aConstraint      := pCons;
  info.aConstraintUsage := pUse;
  info.nOrderBy         := nOrd;
  info.aOrderBy         := pOrd;
end;

procedure TestBestIndex(pVtab: PSqlite3Vtab);
var
  info:  Tsqlite3_index_info;
  cons:  array[0..2] of Tsqlite3_index_constraint;
  uses_: array[0..2] of Tsqlite3_index_constraint_usage;
  ord:   array[0..1] of Tsqlite3_index_orderby;
  rc:    i32;
  fnBI:  TxBestIndex;
begin
  fnBI := TxBestIndex(dbstatModule.xBestIndex);
  Expect(@fnBI <> nil, 'B0 dbstatModule.xBestIndex non-nil');

  { B1 — no constraints → idxNum=0, cost=1.0, SCAN_HEX flag set. }
  WireIdxInfo(info, @cons[0], @uses_[0], 0);
  rc := fnBI(pVtab, @info);
  ExpectEq(rc, SQLITE_OK,        'B1 BestIndex empty');
  ExpectEq(info.idxNum, 0,       'B1b idxNum=0');
  Expect(info.estimatedCost = 1.0, 'B1c estimatedCost=1.0');
  ExpectEq(info.idxFlags and SQLITE_INDEX_SCAN_HEX,
           SQLITE_INDEX_SCAN_HEX, 'B1d SCAN_HEX flag set');

  { B2 — schema=? only → idxNum bit 0x01, schema usage.argvIndex=1 + omit=1. }
  FillChar(cons, SizeOf(cons), 0);
  FillChar(uses_, SizeOf(uses_), 0);
  cons[0].iColumn := DBSTAT_COLUMN_SCHEMA;
  cons[0].op      := SQLITE_INDEX_CONSTRAINT_EQ;
  cons[0].usable  := 1;
  WireIdxInfo(info, @cons[0], @uses_[0], 1);
  rc := fnBI(pVtab, @info);
  ExpectEq(rc, SQLITE_OK,            'B2 schema= ok');
  ExpectEq(info.idxNum and $01, $01, 'B2b idxNum bit 0x01 set');
  ExpectEq(uses_[0].argvIndex, 1,    'B2c schema argvIndex=1');
  ExpectEq(uses_[0].omit, 1,         'B2d schema omit=1');

  { B3 — name=? only → idxNum bit 0x02. }
  FillChar(cons, SizeOf(cons), 0);
  FillChar(uses_, SizeOf(uses_), 0);
  cons[0].iColumn := DBSTAT_COLUMN_NAME;
  cons[0].op      := SQLITE_INDEX_CONSTRAINT_EQ;
  cons[0].usable  := 1;
  WireIdxInfo(info, @cons[0], @uses_[0], 1);
  rc := fnBI(pVtab, @info);
  ExpectEq(rc, SQLITE_OK,            'B3 name= ok');
  ExpectEq(info.idxNum and $02, $02, 'B3b idxNum bit 0x02 set');
  ExpectEq(uses_[0].argvIndex, 1,    'B3c name argvIndex=1');
  ExpectEq(uses_[0].omit, 0,         'B3d name omit=0 (kept; no DBPAGE-style omit)');

  { B4 — aggregate=? only → idxNum bit 0x04. }
  FillChar(cons, SizeOf(cons), 0);
  FillChar(uses_, SizeOf(uses_), 0);
  cons[0].iColumn := DBSTAT_COLUMN_AGGREGATE;
  cons[0].op      := SQLITE_INDEX_CONSTRAINT_EQ;
  cons[0].usable  := 1;
  WireIdxInfo(info, @cons[0], @uses_[0], 1);
  rc := fnBI(pVtab, @info);
  ExpectEq(rc, SQLITE_OK,            'B4 aggregate= ok');
  ExpectEq(info.idxNum and $04, $04, 'B4b idxNum bit 0x04 set');
  ExpectEq(uses_[0].argvIndex, 1,    'B4c aggregate argvIndex=1');

  { B5 — all three combined → bits 0x07; argvIndex order schema=1, name=2, agg=3. }
  FillChar(cons, SizeOf(cons), 0);
  FillChar(uses_, SizeOf(uses_), 0);
  cons[0].iColumn := DBSTAT_COLUMN_SCHEMA;
  cons[0].op      := SQLITE_INDEX_CONSTRAINT_EQ;
  cons[0].usable  := 1;
  cons[1].iColumn := DBSTAT_COLUMN_NAME;
  cons[1].op      := SQLITE_INDEX_CONSTRAINT_EQ;
  cons[1].usable  := 1;
  cons[2].iColumn := DBSTAT_COLUMN_AGGREGATE;
  cons[2].op      := SQLITE_INDEX_CONSTRAINT_EQ;
  cons[2].usable  := 1;
  WireIdxInfo(info, @cons[0], @uses_[0], 3);
  rc := fnBI(pVtab, @info);
  ExpectEq(rc, SQLITE_OK,            'B5 all three ok');
  ExpectEq(info.idxNum and $07, $07, 'B5b bits 0x07 set');
  ExpectEq(uses_[0].argvIndex, 1,    'B5c schema argvIndex=1');
  ExpectEq(uses_[1].argvIndex, 2,    'B5d name argvIndex=2');
  ExpectEq(uses_[2].argvIndex, 3,    'B5e aggregate argvIndex=3');

  { B6 — ORDER BY name → bit 0x08 set, orderByConsumed=1. }
  FillChar(cons, SizeOf(cons), 0);
  FillChar(uses_, SizeOf(uses_), 0);
  FillChar(ord, SizeOf(ord), 0);
  ord[0].iColumn := 0;  { name }
  ord[0].desc    := 0;
  WireIdxInfo(info, @cons[0], @uses_[0], 0, @ord[0], 1);
  rc := fnBI(pVtab, @info);
  ExpectEq(rc, SQLITE_OK,            'B6 ORDER BY name ok');
  ExpectEq(info.idxNum and $08, $08, 'B6b idxNum bit 0x08 set');
  ExpectEq(info.orderByConsumed, 1,  'B6c orderByConsumed=1');

  { B7 — ORDER BY name, path → bit 0x08 set. }
  FillChar(ord, SizeOf(ord), 0);
  ord[0].iColumn := 0;  { name }
  ord[0].desc    := 0;
  ord[1].iColumn := 1;  { path }
  ord[1].desc    := 0;
  WireIdxInfo(info, @cons[0], @uses_[0], 0, @ord[0], 2);
  rc := fnBI(pVtab, @info);
  ExpectEq(rc, SQLITE_OK,            'B7 ORDER BY name,path ok');
  ExpectEq(info.idxNum and $08, $08, 'B7b idxNum bit 0x08 set');

  { B8 — ORDER BY name DESC → not consumed. }
  FillChar(ord, SizeOf(ord), 0);
  ord[0].iColumn := 0;
  ord[0].desc    := 1;
  WireIdxInfo(info, @cons[0], @uses_[0], 0, @ord[0], 1);
  rc := fnBI(pVtab, @info);
  ExpectEq(rc, SQLITE_OK,            'B8 ORDER BY name DESC ok');
  ExpectEq(info.idxNum and $08, 0,   'B8b idxNum bit 0x08 NOT set');
  ExpectEq(info.orderByConsumed, 0,  'B8c orderByConsumed=0');

  { B9 — schema=? unusable → SQLITE_CONSTRAINT (force right-most table). }
  FillChar(cons, SizeOf(cons), 0);
  FillChar(uses_, SizeOf(uses_), 0);
  cons[0].iColumn := DBSTAT_COLUMN_SCHEMA;
  cons[0].op      := SQLITE_INDEX_CONSTRAINT_EQ;
  cons[0].usable  := 0;
  WireIdxInfo(info, @cons[0], @uses_[0], 1);
  rc := fnBI(pVtab, @info);
  ExpectEq(rc, SQLITE_CONSTRAINT,    'B9 unusable schema= → CONSTRAINT');
end;

procedure TestCursorOpen(pVtab: PSqlite3Vtab);
var
  pCur:    PSqlite3VtabCursor;
  cur:     PStatCursor;
  fnOpen:  function(p: PSqlite3Vtab; ppCursor: PPSqlite3VtabCursor): i32; cdecl;
  fnClose: function(c: PSqlite3VtabCursor): i32; cdecl;
  fnEof:   function(c: PSqlite3VtabCursor): i32; cdecl;
  rc:      i32;
begin
  Pointer(fnOpen)  := dbstatModule.xOpen;
  Pointer(fnClose) := dbstatModule.xClose;
  Pointer(fnEof)   := dbstatModule.xEof;

  pCur := nil;
  rc := fnOpen(pVtab, @pCur);
  ExpectEq(rc, SQLITE_OK, 'C1 xOpen ok');
  Expect(pCur <> nil,     'C1b cursor non-nil');

  cur := PStatCursor(pCur);
  Expect(cur^.base.pVtab = pVtab, 'C1c cursor base.pVtab back-pointer');
  ExpectEq(cur^.iDb, PStatTable(pVtab)^.iDb,
           'C1d iDb propagated from table');
  ExpectEq(i32(cur^.iPage),    0,  'C1e iPage default 0');
  ExpectEq(i32(cur^.isEof),    0,  'C1f isEof default 0');
  ExpectEq(i32(cur^.isAgg),    0,  'C1g isAgg default 0');
  Expect(cur^.pStmt = nil,         'C1h pStmt nil');
  ExpectEq(fnEof(pCur), 0, 'C2 fresh cursor not at eof');
  rc := fnClose(pCur);
  ExpectEq(rc, SQLITE_OK,  'C3 xClose ok');
end;

var
  db:      PTsqlite3;
  rc:      i32;
  pMod, pMod2: PVtabModule;
  fakeVt:  TStatTable;

begin
  gPass := 0; gFail := 0;
  WriteLn('TestDbstat — Phase 6.bis.2d gate');

  rc := sqlite3_open_v2(':memory:', @db,
          SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE, nil);
  ExpectEq(rc, SQLITE_OK, 'A1 open :memory:');

  { ---- Module registration ---- }
  pMod := sqlite3DbstatRegister(db);
  Expect(pMod <> nil,                       'A2 sqlite3DbstatRegister returns Module');
  Expect(pMod^.pModule = @dbstatModule,     'A2b registry slot points at dbstatModule');
  ExpectEq(pMod^.nRefModule, 1,             'A2c nRefModule=1');
  Expect(StrComp(pMod^.zName, 'dbstat') = 0, 'A2d name is "dbstat"');

  pMod2 := sqlite3DbstatRegister(db);
  Expect(pMod2 <> nil,                      'A3 second register returns Module');

  { ---- Module slot layout (v1 — read-only). ---- }
  ExpectEq(dbstatModule.iVersion, 0,          'M1 iVersion=0 (v1)');
  Expect(dbstatModule.xCreate <> nil,         'M2 xCreate set (=xConnect)');
  Expect(dbstatModule.xConnect <> nil,        'M3 xConnect set');
  Expect(dbstatModule.xBestIndex <> nil,      'M4 xBestIndex set');
  Expect(PPointer(@dbstatModule.xDisconnect)^ <> nil, 'M5 xDisconnect set');
  Expect(PPointer(@dbstatModule.xDestroy)^    <> nil, 'M6 xDestroy set (=xDisconnect)');
  Expect(dbstatModule.xOpen <> nil,           'M7 xOpen set');
  Expect(dbstatModule.xClose <> nil,          'M8 xClose set');
  Expect(dbstatModule.xFilter <> nil,         'M9 xFilter set');
  Expect(dbstatModule.xNext <> nil,           'M10 xNext set');
  Expect(dbstatModule.xEof <> nil,            'M11 xEof set');
  Expect(dbstatModule.xColumn <> nil,         'M12 xColumn set');
  Expect(dbstatModule.xRowid <> nil,          'M13 xRowid set');
  Expect(dbstatModule.xUpdate    = nil,       'M14 xUpdate nil (read-only)');
  Expect(dbstatModule.xBegin     = nil,       'M15 xBegin nil');
  Expect(dbstatModule.xSync      = nil,       'M16 xSync nil');
  Expect(dbstatModule.xCommit    = nil,       'M17 xCommit nil');
  Expect(dbstatModule.xRollback  = nil,       'M18 xRollback nil');
  Expect(dbstatModule.xSavepoint = nil,       'M19 xSavepoint nil');
  Expect(dbstatModule.xRelease   = nil,       'M20 xRelease nil');
  Expect(dbstatModule.xRollbackTo= nil,       'M21 xRollbackTo nil');

  { ---- xBestIndex via a fake StatTable. ---- }
  FillChar(fakeVt, SizeOf(fakeVt), 0);
  fakeVt.base.pModule := @dbstatModule;
  fakeVt.db := db;
  fakeVt.iDb := 0;
  TestBestIndex(@fakeVt.base);

  { ---- Cursor open/close. ---- }
  TestCursorOpen(@fakeVt.base);

  { ---- Constants pin ---- }
  ExpectEq(DBSTAT_COLUMN_NAME,       0,  'K1 NAME column');
  ExpectEq(DBSTAT_COLUMN_PATH,       1,  'K2 PATH column');
  ExpectEq(DBSTAT_COLUMN_PAGENO,     2,  'K3 PAGENO column');
  ExpectEq(DBSTAT_COLUMN_PAGETYPE,   3,  'K4 PAGETYPE column');
  ExpectEq(DBSTAT_COLUMN_NCELL,      4,  'K5 NCELL column');
  ExpectEq(DBSTAT_COLUMN_PAYLOAD,    5,  'K6 PAYLOAD column');
  ExpectEq(DBSTAT_COLUMN_UNUSED,     6,  'K7 UNUSED column');
  ExpectEq(DBSTAT_COLUMN_MX_PAYLOAD, 7,  'K8 MX_PAYLOAD column');
  ExpectEq(DBSTAT_COLUMN_PGOFFSET,   8,  'K9 PGOFFSET column');
  ExpectEq(DBSTAT_COLUMN_PGSIZE,     9,  'K10 PGSIZE column');
  ExpectEq(DBSTAT_COLUMN_SCHEMA,    10,  'K11 SCHEMA column');
  ExpectEq(DBSTAT_COLUMN_AGGREGATE, 11,  'K12 AGGREGATE column');
  ExpectEq(STAT_PAGE_NEST,          32,  'K13 STAT_PAGE_NEST=32');
  ExpectEq(DBSTAT_PAGE_PADDING_BYTES, 256, 'K14 PAGE_PADDING_BYTES=256');

  rc := sqlite3_drop_modules(db, nil);
  ExpectEq(rc, SQLITE_OK, 'Z1 drop_modules');

  rc := sqlite3_close_v2(db);
  ExpectEq(rc, SQLITE_OK, 'Z2 close_v2');

  WriteLn;
  WriteLn('TestDbstat: ', gPass, ' PASS, ', gFail, ' FAIL');
  if gFail <> 0 then Halt(1);
end.
