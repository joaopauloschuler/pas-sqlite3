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
{$I ../passqlite3.inc}
program TestCarray;

{
  Phase 6.bis.2b gate — carray.c port (passqlite3carray).

  Exercises:
    * sqlite3CarrayRegister installs `carray` in db^.aModule with the
      expected slot pointers.
    * carrayModule iVersion=0 and the v1-only callback layout (no
      xCreate / xDestroy / xUpdate / xSavepoint / ...).
    * carrayBestIndex constraint dispatch — all four idxNum branches
      (0/1/2/3) and the SQLITE_CONSTRAINT failure paths for under-
      constrained 2-arg and 3-arg invocations.
    * carrayOpen → allocates a cursor with iRowid=0, iCnt=0, pPtr=nil.
    * carrayNext / carrayEof / carrayRowid state-machine round-trip
      with manually-set cursor state.
    * carrayClose tears down the cursor.

  Not exercised here (carry-overs from 6.bis.2a):
    * xColumn → requires a real Tsqlite3_context for sqlite3_result_*;
      the column-extraction logic IS reachable but waiting on a
      VDBE-driven gate test (deferred to 6.bis.2 wiring sub-phase).
    * xFilter idxNum=1 — sqlite3_value_pointer is still a stub returning
      nil, so the bind-pointer path is structurally complete but inert.
}

uses
  SysUtils,
  passqlite3types,
  passqlite3util,
  passqlite3os,
  passqlite3vdbe,
  passqlite3vtab,
  passqlite3main,
  passqlite3carray;

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

{ Build a Tsqlite3_index_info populated from |cons| / |uses_| arrays.
  Caller fills the constraint slots, we wire the input/output arrays. }
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
  cons:  array[0..2] of Tsqlite3_index_constraint;
  uses_: array[0..2] of Tsqlite3_index_constraint_usage;
  rc:    i32;
  fnBI:  TxBestIndex;
begin
  fnBI := TxBestIndex(carrayModule.xBestIndex);
  Expect(@fnBI <> nil, 'B0 carrayModule.xBestIndex non-nil');

  { B1 — no constraints → idxNum=0, full-scan cost. }
  WireIdxInfo(info, @cons[0], @uses_[0], 0);
  rc := fnBI(pVtab, @info);
  ExpectEq(rc, SQLITE_OK, 'B1 BestIndex empty constraints');
  ExpectEq(info.idxNum, 0, 'B1b idxNum=0 empty');
  Expect(info.estimatedCost > 1.0e9, 'B1c estimatedCost full-scan');

  { B2 — pointer= only (column 1) → idxNum=1, argvIndex=1, omit=1. }
  FillChar(cons, SizeOf(cons), 0);
  FillChar(uses_, SizeOf(uses_), 0);
  cons[0].iColumn := CARRAY_COLUMN_POINTER;
  cons[0].op      := SQLITE_INDEX_CONSTRAINT_EQ;
  cons[0].usable  := 1;
  WireIdxInfo(info, @cons[0], @uses_[0], 1);
  rc := fnBI(pVtab, @info);
  ExpectEq(rc, SQLITE_OK,            'B2 pointer= only ok');
  ExpectEq(info.idxNum, 1,           'B2b idxNum=1');
  ExpectEq(uses_[0].argvIndex, 1,    'B2c usage.argvIndex=1');
  ExpectEq(uses_[0].omit,      1,    'B2d usage.omit=1');

  { B3 — pointer= and count= → idxNum=2. }
  FillChar(uses_, SizeOf(uses_), 0);
  cons[1].iColumn := CARRAY_COLUMN_COUNT;
  cons[1].op      := SQLITE_INDEX_CONSTRAINT_EQ;
  cons[1].usable  := 1;
  WireIdxInfo(info, @cons[0], @uses_[0], 2);
  rc := fnBI(pVtab, @info);
  ExpectEq(rc, SQLITE_OK,            'B3 pointer= + count= ok');
  ExpectEq(info.idxNum, 2,           'B3b idxNum=2');
  ExpectEq(uses_[1].argvIndex, 2,    'B3c count usage.argvIndex=2');

  { B4 — pointer=, count=, ctype= → idxNum=3. }
  FillChar(uses_, SizeOf(uses_), 0);
  cons[2].iColumn := CARRAY_COLUMN_CTYPE;
  cons[2].op      := SQLITE_INDEX_CONSTRAINT_EQ;
  cons[2].usable  := 1;
  WireIdxInfo(info, @cons[0], @uses_[0], 3);
  rc := fnBI(pVtab, @info);
  ExpectEq(rc, SQLITE_OK,            'B4 pointer= + count= + ctype= ok');
  ExpectEq(info.idxNum, 3,           'B4b idxNum=3');
  ExpectEq(uses_[2].argvIndex, 3,    'B4c ctype usage.argvIndex=3');

  { B5 — pointer= + count= mentioned but NOT usable → SQLITE_CONSTRAINT
    (faithful: 2-arg carray() needs both args known). }
  FillChar(uses_, SizeOf(uses_), 0);
  cons[1].usable := 0;          { count= present but unusable }
  WireIdxInfo(info, @cons[0], @uses_[0], 2);
  rc := fnBI(pVtab, @info);
  ExpectEq(rc, SQLITE_CONSTRAINT, 'B5 pointer=, unusable count → CONSTRAINT');

  { B6 — pointer= + count= usable, but ctype= mentioned & unusable →
    3-arg carray() with unknown ctype → SQLITE_CONSTRAINT. }
  FillChar(uses_, SizeOf(uses_), 0);
  cons[1].usable := 1;
  cons[2].usable := 0;          { ctype= present but unusable }
  WireIdxInfo(info, @cons[0], @uses_[0], 3);
  rc := fnBI(pVtab, @info);
  ExpectEq(rc, SQLITE_CONSTRAINT, 'B6 pointer=,count=, unusable ctype → CONSTRAINT');
end;

procedure TestCursorWalk(pVtab: PSqlite3Vtab);
var
  pCur:    PSqlite3VtabCursor;
  cur:     PCarrayCursor;
  fnOpen:  function(p: PSqlite3Vtab; ppCursor: PPSqlite3VtabCursor): i32; cdecl;
  fnClose: function(c: PSqlite3VtabCursor): i32; cdecl;
  fnNext:  function(c: PSqlite3VtabCursor): i32; cdecl;
  fnEof:   function(c: PSqlite3VtabCursor): i32; cdecl;
  fnRow:   function(c: PSqlite3VtabCursor; pR: Pi64): i32; cdecl;
  rc:      i32;
  rowid:   i64;
begin
  Pointer(fnOpen)  := carrayModule.xOpen;
  Pointer(fnClose) := carrayModule.xClose;
  Pointer(fnNext)  := carrayModule.xNext;
  Pointer(fnEof)   := carrayModule.xEof;
  Pointer(fnRow)   := carrayModule.xRowid;

  pCur := nil;
  rc := fnOpen(pVtab, @pCur);
  ExpectEq(rc, SQLITE_OK, 'C1 xOpen ok');
  Expect(pCur <> nil,     'C1b cursor non-nil');

  cur := PCarrayCursor(pCur);
  ExpectEq(i32(cur^.iRowid), 0, 'C1c initial iRowid=0');
  ExpectEq(i32(cur^.iCnt),   0, 'C1d initial iCnt=0');
  Expect(cur^.pPtr = nil,       'C1e initial pPtr nil');

  { Manually drive the state machine: pretend xFilter set up a 3-element
    array.  Walk via xNext / xEof / xRowid. }
  cur^.iRowid := 1;
  cur^.iCnt   := 3;
  cur^.eType  := CARRAY_INT32;

  ExpectEq(fnEof(pCur), 0, 'C2 not at eof at row 1');
  rowid := 0;
  rc := fnRow(pCur, @rowid);
  ExpectEq(rc, SQLITE_OK, 'C2b xRowid ok');
  ExpectEq(i32(rowid), 1, 'C2c rowid=1');

  rc := fnNext(pCur); ExpectEq(rc, SQLITE_OK, 'C3 xNext');
  ExpectEq(i32(cur^.iRowid), 2, 'C3b iRowid advanced to 2');
  ExpectEq(fnEof(pCur), 0,      'C3c not at eof at row 2');

  fnNext(pCur);
  ExpectEq(i32(cur^.iRowid), 3, 'C4 iRowid=3');
  ExpectEq(fnEof(pCur), 0,      'C4b row 3 still in range (iCnt=3)');

  fnNext(pCur);
  ExpectEq(i32(cur^.iRowid), 4, 'C5 iRowid past iCnt');
  ExpectEq(fnEof(pCur), 1,      'C5b xEof reports done');

  rc := fnClose(pCur);
  ExpectEq(rc, SQLITE_OK, 'C6 xClose ok');
end;

{ Smoke: drive sqlite3_carray_bind / _v2 against a real prepared stmt.
  We bind to a SELECT ?1 statement (slot 1 exists) and verify the bind
  returns SQLITE_OK + the destructor fires on finalize.  Element data
  is owned by the test; we use SQLITE_STATIC so no copy is made. }
var
  gDestroyHits: i32;

procedure CntDestroy(p: Pointer); cdecl;
begin
  Inc(gDestroyHits);
end;

procedure TestCarrayBind(db: PTsqlite3);
var
  pStmt: PVdbe;
  rc:    i32;
  data:  array[0..3] of i32;
  ownedBuf: PInt32;
begin
  data[0] := 11; data[1] := 22; data[2] := 33; data[3] := 44;

  { D1 — bad mFlags (out of range) → SQLITE_ERROR. }
  pStmt := nil;
  rc := sqlite3_prepare_v2(db, 'SELECT ?1', -1, @pStmt, nil);
  ExpectEq(rc, SQLITE_OK, 'D1a prepare SELECT ?1');
  rc := sqlite3_carray_bind(pStmt, 1, @data[0], 4, 99, nil);
  ExpectEq(rc, SQLITE_ERROR, 'D1b bind bad mFlags');

  { D2 — happy path with SQLITE_STATIC: bind succeeds, no destructor fires. }
  rc := sqlite3_carray_bind(pStmt, 1, @data[0], 4, CARRAY_INT32, SQLITE_STATIC);
  ExpectEq(rc, SQLITE_OK, 'D2 bind static');
  rc := sqlite3_finalize(pStmt);
  ExpectEq(rc, SQLITE_OK, 'D2b finalize');

  { D3 — _v2 with caller-supplied destructor: destructor must fire on finalize.
    We allocate a malloc'd buffer; the destructor frees it and increments
    gDestroyHits.  pDestroy = the buffer itself (single-arg form). }
  pStmt := nil;
  rc := sqlite3_prepare_v2(db, 'SELECT ?1', -1, @pStmt, nil);
  ExpectEq(rc, SQLITE_OK, 'D3a prepare');
  ownedBuf := PInt32(sqlite3_malloc64(4 * SizeOf(i32)));
  ownedBuf[0] := 100; ownedBuf[1] := 200; ownedBuf[2] := 300; ownedBuf[3] := 400;
  gDestroyHits := 0;
  rc := sqlite3_carray_bind_v2(pStmt, 1, ownedBuf, 4, CARRAY_INT32,
                               @CntDestroy, ownedBuf);
  ExpectEq(rc, SQLITE_OK, 'D3b bind v2 with destructor');
  rc := sqlite3_finalize(pStmt);
  ExpectEq(rc, SQLITE_OK, 'D3c finalize');
  ExpectEq(gDestroyHits, 1, 'D3d destructor fired exactly once');
  sqlite3_free(ownedBuf);
end;

var
  db:      PTsqlite3;
  rc:      i32;
  pMod:    PVtabModule;
  pMod2:   PVtabModule;
  fakeVt:  Tsqlite3_vtab;

begin
  gPass := 0; gFail := 0;
  WriteLn('TestCarray — Phase 6.bis.2b gate');

  rc := sqlite3_open_v2(':memory:', @db,
          SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE, nil);
  ExpectEq(rc, SQLITE_OK, 'A1 open :memory:');

  { ---- Module registration ---- }
  pMod := sqlite3CarrayRegister(db);
  Expect(pMod <> nil,                    'A2 sqlite3CarrayRegister returns Module');
  Expect(pMod^.pModule = @carrayModule,  'A2b registry slot points at carrayModule');
  ExpectEq(pMod^.nRefModule, 1,          'A2c nRefModule=1');
  Expect(StrComp(pMod^.zName, 'carray') = 0, 'A2d name is "carray"');

  { Re-registering does not crash and yields a fresh slot. }
  pMod2 := sqlite3CarrayRegister(db);
  Expect(pMod2 <> nil,                   'A3 second register returns Module');

  { ---- Module slot layout ---- }
  ExpectEq(carrayModule.iVersion, 0, 'M1 iVersion=0');
  Expect(carrayModule.xCreate = nil,           'M2 xCreate nil (eponymous-only)');
  Expect(carrayModule.xConnect <> nil,         'M3 xConnect set');
  Expect(carrayModule.xBestIndex <> nil,       'M4 xBestIndex set');
  Expect(PPointer(@carrayModule.xDisconnect)^ <> nil, 'M5 xDisconnect set');
  Expect(PPointer(@carrayModule.xDestroy)^    = nil,  'M6 xDestroy nil (eponymous-only)');
  Expect(carrayModule.xOpen <> nil,            'M7 xOpen set');
  Expect(carrayModule.xClose <> nil,           'M8 xClose set');
  Expect(carrayModule.xFilter <> nil,          'M9 xFilter set');
  Expect(carrayModule.xNext <> nil,            'M10 xNext set');
  Expect(carrayModule.xEof <> nil,             'M11 xEof set');
  Expect(carrayModule.xColumn <> nil,          'M12 xColumn set');
  Expect(carrayModule.xRowid <> nil,           'M13 xRowid set');
  Expect(carrayModule.xUpdate = nil,           'M14 xUpdate nil (read-only)');
  Expect(carrayModule.xSavepoint = nil,        'M15 xSavepoint nil');

  { ---- xBestIndex via a fake sqlite3_vtab (BestIndex never derefs pVtab). ---- }
  FillChar(fakeVt, SizeOf(fakeVt), 0);
  fakeVt.pModule := @carrayModule;
  TestBestIndex(@fakeVt);

  { ---- Cursor state machine ---- }
  TestCursorWalk(@fakeVt);

  { ---- Constants pin ---- }
  ExpectEq(CARRAY_INT32,        0, 'K1 CARRAY_INT32');
  ExpectEq(CARRAY_INT64,        1, 'K2 CARRAY_INT64');
  ExpectEq(CARRAY_DOUBLE,       2, 'K3 CARRAY_DOUBLE');
  ExpectEq(CARRAY_TEXT,         3, 'K4 CARRAY_TEXT');
  ExpectEq(CARRAY_BLOB,         4, 'K5 CARRAY_BLOB');
  ExpectEq(SQLITE_CARRAY_INT32, 0, 'K6 SQLITE_CARRAY_INT32');
  ExpectEq(SQLITE_CARRAY_BLOB,  4, 'K7 SQLITE_CARRAY_BLOB');
  ExpectEq(CARRAY_COLUMN_VALUE,   0, 'K8  COLUMN_VALUE');
  ExpectEq(CARRAY_COLUMN_POINTER, 1, 'K9  COLUMN_POINTER');
  ExpectEq(CARRAY_COLUMN_COUNT,   2, 'K10 COLUMN_COUNT');
  ExpectEq(CARRAY_COLUMN_CTYPE,   3, 'K11 COLUMN_CTYPE');

  { ---- sqlite3_carray_bind smoke (carray.c:435..549). ---- }
  TestCarrayBind(db);

  { Drop registry before close so we exit clean. }
  rc := sqlite3_drop_modules(db, nil);
  ExpectEq(rc, SQLITE_OK, 'Z1 drop_modules');

  rc := sqlite3_close_v2(db);
  ExpectEq(rc, SQLITE_OK, 'Z2 close_v2');

  WriteLn;
  WriteLn('TestCarray: ', gPass, ' PASS, ', gFail, ' FAIL');
  if gFail <> 0 then Halt(1);
end.
