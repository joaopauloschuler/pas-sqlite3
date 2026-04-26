{$I ../passqlite3.inc}
program TestDbpage;

{
  Phase 6.bis.2c gate — dbpage.c port (passqlite3dbpage).

  Exercises:
    * sqlite3DbpageRegister installs `sqlite_dbpage` in db^.aModule with
      the expected slot pointers (v2 layout, full xUpdate / xBegin /
      xSync / xRollbackTo wired).
    * dbpageBestIndex constraint dispatch — all four idxNum branches
      (0/1/2/3) and the SQLITE_CONSTRAINT failure path when schema= is
      mentioned but unusable.
    * dbpageOpen → cursor allocated zeroed with pgno=0.
    * dbpageNext / dbpageEof / dbpageRowid round-trip with manually-set
      cursor state.
    * dbpageClose tears down the cursor.

  Not exercised here (deferred to the end-to-end SQL gate):
    * xFilter / xColumn — require a live db with a real Btree
      open and a wired sqlite3_create_module → schema-resolution path.
    * xUpdate / xBegin / xSync / xRollbackTo — likewise need a live
      writable transaction context.
}

uses
  SysUtils,
  passqlite3types,
  passqlite3util,
  passqlite3os,
  passqlite3vdbe,
  passqlite3vtab,
  passqlite3main,
  passqlite3dbpage;

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
                      n: i32);
begin
  FillChar(info, SizeOf(info), 0);
  info.nConstraint      := n;
  info.aConstraint      := pCons;
  info.aConstraintUsage := pUse;
end;

procedure TestBestIndex(pVtab: PSqlite3Vtab);
var
  info:  Tsqlite3_index_info;
  cons:  array[0..1] of Tsqlite3_index_constraint;
  uses_: array[0..1] of Tsqlite3_index_constraint_usage;
  rc:    i32;
  fnBI:  TxBestIndex;
begin
  fnBI := TxBestIndex(dbpageModule.xBestIndex);
  Expect(@fnBI <> nil, 'B0 dbpageModule.xBestIndex non-nil');

  { B1 — no constraints → idxNum=0 (schema=main, full scan), cost=1e6. }
  WireIdxInfo(info, @cons[0], @uses_[0], 0);
  rc := fnBI(pVtab, @info);
  ExpectEq(rc, SQLITE_OK,        'B1 BestIndex empty constraints');
  ExpectEq(info.idxNum, 0,       'B1b idxNum=0 empty');
  Expect(info.estimatedCost > 1.0e5, 'B1c estimatedCost full-scan');

  { B2 — pgno=? only (column 0) → idxNum=1, argvIndex=1. }
  FillChar(cons, SizeOf(cons), 0);
  FillChar(uses_, SizeOf(uses_), 0);
  cons[0].iColumn := DBPAGE_COLUMN_PGNO;
  cons[0].op      := SQLITE_INDEX_CONSTRAINT_EQ;
  cons[0].usable  := 1;
  WireIdxInfo(info, @cons[0], @uses_[0], 1);
  rc := fnBI(pVtab, @info);
  ExpectEq(rc, SQLITE_OK,            'B2 pgno= only ok');
  ExpectEq(info.idxNum, 1,           'B2b idxNum=1');
  ExpectEq(uses_[0].argvIndex, 1,    'B2c usage.argvIndex=1');
  ExpectEq(uses_[0].omit,      1,    'B2d usage.omit=1');
  Expect(info.estimatedCost < 10.0,  'B2e cost dropped to ~1.0');
  ExpectEq(i32(info.idxFlags and SQLITE_INDEX_SCAN_UNIQUE),
           SQLITE_INDEX_SCAN_UNIQUE, 'B2f SCAN_UNIQUE flag set');

  { B3 — schema=? only (column 2, hidden) → idxNum=2. }
  FillChar(cons, SizeOf(cons), 0);
  FillChar(uses_, SizeOf(uses_), 0);
  cons[0].iColumn := DBPAGE_COLUMN_SCHEMA;
  cons[0].op      := SQLITE_INDEX_CONSTRAINT_EQ;
  cons[0].usable  := 1;
  WireIdxInfo(info, @cons[0], @uses_[0], 1);
  rc := fnBI(pVtab, @info);
  ExpectEq(rc, SQLITE_OK,            'B3 schema= only ok');
  ExpectEq(info.idxNum, 2,           'B3b idxNum=2');
  ExpectEq(uses_[0].argvIndex, 1,    'B3c schema usage.argvIndex=1');
  ExpectEq(uses_[0].omit,      1,    'B3d schema usage.omit=1');

  { B4 — schema= AND pgno= → idxNum=3, schema is argv[1], pgno is argv[2]. }
  FillChar(cons, SizeOf(cons), 0);
  FillChar(uses_, SizeOf(uses_), 0);
  cons[0].iColumn := DBPAGE_COLUMN_SCHEMA;
  cons[0].op      := SQLITE_INDEX_CONSTRAINT_EQ;
  cons[0].usable  := 1;
  cons[1].iColumn := DBPAGE_COLUMN_PGNO;
  cons[1].op      := SQLITE_INDEX_CONSTRAINT_EQ;
  cons[1].usable  := 1;
  WireIdxInfo(info, @cons[0], @uses_[0], 2);
  rc := fnBI(pVtab, @info);
  ExpectEq(rc, SQLITE_OK,            'B4 schema= + pgno= ok');
  ExpectEq(info.idxNum, 3,           'B4b idxNum=3');
  ExpectEq(uses_[0].argvIndex, 1,    'B4c schema usage.argvIndex=1');
  ExpectEq(uses_[1].argvIndex, 2,    'B4d pgno usage.argvIndex=2');

  { B5 — schema= mentioned but unusable → SQLITE_CONSTRAINT
    (faithful to dbpage.c:135..138 — schema must be honored). }
  FillChar(cons, SizeOf(cons), 0);
  FillChar(uses_, SizeOf(uses_), 0);
  cons[0].iColumn := DBPAGE_COLUMN_SCHEMA;
  cons[0].op      := SQLITE_INDEX_CONSTRAINT_EQ;
  cons[0].usable  := 0;
  WireIdxInfo(info, @cons[0], @uses_[0], 1);
  rc := fnBI(pVtab, @info);
  ExpectEq(rc, SQLITE_CONSTRAINT,    'B5 unusable schema= → CONSTRAINT');
end;

procedure TestCursorWalk(pVtab: PSqlite3Vtab);
var
  pCur:    PSqlite3VtabCursor;
  cur:     PDbpageCursor;
  fnOpen:  function(p: PSqlite3Vtab; ppCursor: PPSqlite3VtabCursor): i32; cdecl;
  fnClose: function(c: PSqlite3VtabCursor): i32; cdecl;
  fnNext:  function(c: PSqlite3VtabCursor): i32; cdecl;
  fnEof:   function(c: PSqlite3VtabCursor): i32; cdecl;
  fnRow:   function(c: PSqlite3VtabCursor; pR: Pi64): i32; cdecl;
  rc:      i32;
  rowid:   i64;
begin
  Pointer(fnOpen)  := dbpageModule.xOpen;
  Pointer(fnClose) := dbpageModule.xClose;
  Pointer(fnNext)  := dbpageModule.xNext;
  Pointer(fnEof)   := dbpageModule.xEof;
  Pointer(fnRow)   := dbpageModule.xRowid;

  pCur := nil;
  rc := fnOpen(pVtab, @pCur);
  ExpectEq(rc, SQLITE_OK, 'C1 xOpen ok');
  Expect(pCur <> nil,     'C1b cursor non-nil');

  cur := PDbpageCursor(pCur);
  ExpectEq(i32(cur^.pgno),   0, 'C1c initial pgno=0');
  ExpectEq(i32(cur^.mxPgno), 0, 'C1d initial mxPgno=0');
  Expect(cur^.pPage1 = nil,     'C1e initial pPage1 nil');
  Expect(cur^.base.pVtab = pVtab, 'C1f cursor base.pVtab back-pointer');

  { Walk the state machine: pretend xFilter set up a 3-page scan. }
  cur^.pgno   := 1;
  cur^.mxPgno := 3;

  ExpectEq(fnEof(pCur), 0, 'C2 not at eof at pgno=1');
  rowid := 0;
  rc := fnRow(pCur, @rowid);
  ExpectEq(rc, SQLITE_OK, 'C2b xRowid ok');
  ExpectEq(i32(rowid), 1, 'C2c rowid=1');

  rc := fnNext(pCur); ExpectEq(rc, SQLITE_OK, 'C3 xNext');
  ExpectEq(i32(cur^.pgno), 2, 'C3b pgno advanced to 2');
  ExpectEq(fnEof(pCur), 0,    'C3c not at eof at pgno=2');

  fnNext(pCur);
  ExpectEq(i32(cur^.pgno), 3, 'C4 pgno=3');
  ExpectEq(fnEof(pCur), 0,    'C4b pgno=3 still in range');

  fnNext(pCur);
  ExpectEq(i32(cur^.pgno), 4, 'C5 pgno past mxPgno');
  ExpectEq(fnEof(pCur), 1,    'C5b xEof reports done');

  rc := fnClose(pCur);
  ExpectEq(rc, SQLITE_OK, 'C6 xClose ok');
end;

var
  db:      PTsqlite3;
  rc:      i32;
  pMod:    PVtabModule;
  pMod2:   PVtabModule;
  fakeVt:  TDbpageTable;

begin
  gPass := 0; gFail := 0;
  WriteLn('TestDbpage — Phase 6.bis.2c gate');

  rc := sqlite3_open_v2(':memory:', @db,
          SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE, nil);
  ExpectEq(rc, SQLITE_OK, 'A1 open :memory:');

  { ---- Module registration ---- }
  pMod := sqlite3DbpageRegister(db);
  Expect(pMod <> nil,                       'A2 sqlite3DbpageRegister returns Module');
  Expect(pMod^.pModule = @dbpageModule,     'A2b registry slot points at dbpageModule');
  ExpectEq(pMod^.nRefModule, 1,             'A2c nRefModule=1');
  Expect(StrComp(pMod^.zName, 'sqlite_dbpage') = 0,
                                            'A2d name is "sqlite_dbpage"');

  pMod2 := sqlite3DbpageRegister(db);
  Expect(pMod2 <> nil,                      'A3 second register returns Module');

  { ---- Module slot layout ---- }
  ExpectEq(dbpageModule.iVersion, 2,           'M1 iVersion=2');
  Expect(dbpageModule.xCreate <> nil,          'M2 xCreate set (=xConnect)');
  Expect(dbpageModule.xConnect <> nil,         'M3 xConnect set');
  Expect(dbpageModule.xBestIndex <> nil,       'M4 xBestIndex set');
  Expect(PPointer(@dbpageModule.xDisconnect)^ <> nil, 'M5 xDisconnect set');
  Expect(PPointer(@dbpageModule.xDestroy)^    <> nil, 'M6 xDestroy set (=xDisconnect)');
  Expect(dbpageModule.xOpen <> nil,            'M7 xOpen set');
  Expect(dbpageModule.xClose <> nil,           'M8 xClose set');
  Expect(dbpageModule.xFilter <> nil,          'M9 xFilter set');
  Expect(dbpageModule.xNext <> nil,            'M10 xNext set');
  Expect(dbpageModule.xEof <> nil,             'M11 xEof set');
  Expect(dbpageModule.xColumn <> nil,          'M12 xColumn set');
  Expect(dbpageModule.xRowid <> nil,           'M13 xRowid set');
  Expect(dbpageModule.xUpdate <> nil,          'M14 xUpdate set (writable)');
  Expect(dbpageModule.xBegin <> nil,           'M15 xBegin set');
  Expect(dbpageModule.xSync <> nil,            'M16 xSync set');
  Expect(dbpageModule.xCommit = nil,           'M17 xCommit nil');
  Expect(dbpageModule.xRollback = nil,         'M18 xRollback nil');
  Expect(dbpageModule.xSavepoint = nil,        'M19 xSavepoint nil');
  Expect(dbpageModule.xRelease = nil,          'M20 xRelease nil');
  Expect(dbpageModule.xRollbackTo <> nil,      'M21 xRollbackTo set');

  { ---- xBestIndex via a fake DbpageTable (BestIndex never derefs pVtab). ---- }
  FillChar(fakeVt, SizeOf(fakeVt), 0);
  fakeVt.base.pModule := @dbpageModule;
  fakeVt.db := db;
  TestBestIndex(@fakeVt.base);

  { ---- Cursor state machine ---- }
  TestCursorWalk(@fakeVt.base);

  { ---- Constants pin ---- }
  ExpectEq(DBPAGE_COLUMN_PGNO,   0, 'K1 DBPAGE_COLUMN_PGNO');
  ExpectEq(DBPAGE_COLUMN_DATA,   1, 'K2 DBPAGE_COLUMN_DATA');
  ExpectEq(DBPAGE_COLUMN_SCHEMA, 2, 'K3 DBPAGE_COLUMN_SCHEMA');

  rc := sqlite3_drop_modules(db, nil);
  ExpectEq(rc, SQLITE_OK, 'Z1 drop_modules');

  rc := sqlite3_close_v2(db);
  ExpectEq(rc, SQLITE_OK, 'Z2 close_v2');

  WriteLn;
  WriteLn('TestDbpage: ', gPass, ' PASS, ', gFail, ' FAIL');
  if gFail <> 0 then Halt(1);
end.
