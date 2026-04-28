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
program TestJsonEach;

{
  Phase 6.8.h.5 gate — passqlite3jsoneach.

  Exercises:
    * sqlite3JsonVtabRegister installs each of the four spellings
      (json_each / json_tree / jsonb_each / jsonb_tree) into
      db^.aModule with the shared jsonEachModule slot.
    * jsonEachModule iVersion/layout — eponymous read-only vtab
      (no xCreate / xDestroy / xUpdate / xSavepoint).
    * jsonEachBestIndex constraint dispatch — idxNum ∈ {0, 1, 3}
      and the SQLITE_CONSTRAINT failure path for an unusable JSON
      constraint.
    * jsonEachOpen / jsonEachClose round-trip.
    * Cursor walk via jsonEachFilter (idxNum=1) on a small JSON
      array literal: drives jsonEachNext / jsonEachEof / jsonEachRowid
      with manually fabricated argv.
    * Constants pin (JEACH_KEY..JEACH_ROOT).
}

uses
  SysUtils,
  passqlite3types,
  passqlite3util,
  passqlite3os,
  passqlite3vdbe,
  passqlite3vtab,
  passqlite3main,
  passqlite3json,
  passqlite3jsoneach;

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
  fnBI := TxBestIndex(jsonEachModule.xBestIndex);
  Expect(@fnBI <> nil, 'B0 jsonEachModule.xBestIndex non-nil');

  { B1 — no constraints → idxNum=0. }
  WireIdxInfo(info, @cons[0], @uses_[0], 0);
  rc := fnBI(pVtab, @info);
  ExpectEq(rc, SQLITE_OK, 'B1 BestIndex empty constraints');
  ExpectEq(info.idxNum, 0, 'B1b idxNum=0 empty');

  { B2 — JSON= only (column JEACH_JSON) → idxNum=1, argvIndex=1. }
  FillChar(cons, SizeOf(cons), 0);
  FillChar(uses_, SizeOf(uses_), 0);
  cons[0].iColumn := JEACH_JSON;
  cons[0].op      := SQLITE_INDEX_CONSTRAINT_EQ;
  cons[0].usable  := 1;
  WireIdxInfo(info, @cons[0], @uses_[0], 1);
  rc := fnBI(pVtab, @info);
  ExpectEq(rc, SQLITE_OK,         'B2 JSON= only ok');
  ExpectEq(info.idxNum, 1,        'B2b idxNum=1');
  ExpectEq(uses_[0].argvIndex, 1, 'B2c argvIndex=1');
  ExpectEq(uses_[0].omit, 1,      'B2d omit=1');

  { B3 — JSON= and ROOT= → idxNum=3. }
  FillChar(uses_, SizeOf(uses_), 0);
  cons[1].iColumn := JEACH_ROOT;
  cons[1].op      := SQLITE_INDEX_CONSTRAINT_EQ;
  cons[1].usable  := 1;
  WireIdxInfo(info, @cons[0], @uses_[0], 2);
  rc := fnBI(pVtab, @info);
  ExpectEq(rc, SQLITE_OK,         'B3 JSON= + ROOT= ok');
  ExpectEq(info.idxNum, 3,        'B3b idxNum=3');
  ExpectEq(uses_[1].argvIndex, 2, 'B3c ROOT argvIndex=2');

  { B4 — unusable JSON= (no idxMask cover) → SQLITE_CONSTRAINT. }
  FillChar(cons, SizeOf(cons), 0);
  FillChar(uses_, SizeOf(uses_), 0);
  cons[0].iColumn := JEACH_JSON;
  cons[0].op      := SQLITE_INDEX_CONSTRAINT_EQ;
  cons[0].usable  := 0;
  WireIdxInfo(info, @cons[0], @uses_[0], 1);
  rc := fnBI(pVtab, @info);
  ExpectEq(rc, SQLITE_CONSTRAINT, 'B4 unusable JSON= → CONSTRAINT');

  { B5 — non-JSON column constraints are ignored (iColumn < JEACH_JSON). }
  FillChar(cons, SizeOf(cons), 0);
  FillChar(uses_, SizeOf(uses_), 0);
  cons[0].iColumn := JEACH_KEY;
  cons[0].op      := SQLITE_INDEX_CONSTRAINT_EQ;
  cons[0].usable  := 1;
  WireIdxInfo(info, @cons[0], @uses_[0], 1);
  rc := fnBI(pVtab, @info);
  ExpectEq(rc, SQLITE_OK,    'B5 non-hidden constraint ignored');
  ExpectEq(info.idxNum, 0,   'B5b idxNum=0 (no JSON arg)');
end;

var
  db:      PTsqlite3;
  rc:      i32;
  pMod:    PVtabModule;
  fakeVt:  Tsqlite3_vtab;

begin
  gPass := 0; gFail := 0;
  WriteLn('TestJsonEach — Phase 6.8.h.5 gate');

  rc := sqlite3_open_v2(':memory:', @db,
          SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE, nil);
  ExpectEq(rc, SQLITE_OK, 'A1 open :memory:');

  { ---- Module registration — all four spellings ---- }
  pMod := sqlite3JsonVtabRegister(db, 'json_each');
  Expect(pMod <> nil,                       'A2 register json_each');
  Expect(pMod^.pModule = @jsonEachModule,   'A2b slot points at jsonEachModule');
  Expect(StrComp(pMod^.zName, 'json_each') = 0, 'A2c name=json_each');

  pMod := sqlite3JsonVtabRegister(db, 'json_tree');
  Expect(pMod <> nil,                       'A3 register json_tree');
  Expect(StrComp(pMod^.zName, 'json_tree') = 0, 'A3b name=json_tree');

  pMod := sqlite3JsonVtabRegister(db, 'jsonb_each');
  Expect(pMod <> nil,                       'A4 register jsonb_each');
  pMod := sqlite3JsonVtabRegister(db, 'jsonb_tree');
  Expect(pMod <> nil,                       'A5 register jsonb_tree');

  { ---- Unknown spelling → nil. ---- }
  pMod := sqlite3JsonVtabRegister(db, 'json_other');
  Expect(pMod = nil,                        'A6 unknown spelling → nil');

  { ---- Case-insensitive match (sqlite3StrICmp). ---- }
  pMod := sqlite3JsonVtabRegister(db, 'JSON_EACH');
  Expect(pMod <> nil,                       'A7 case-insensitive lookup');

  { ---- Module slot layout ---- }
  ExpectEq(jsonEachModule.iVersion, 0,           'M1 iVersion=0');
  Expect(jsonEachModule.xCreate = nil,           'M2 xCreate nil (eponymous-only)');
  Expect(jsonEachModule.xConnect <> nil,         'M3 xConnect set');
  Expect(jsonEachModule.xBestIndex <> nil,       'M4 xBestIndex set');
  Expect(PPointer(@jsonEachModule.xDisconnect)^ <> nil, 'M5 xDisconnect set');
  Expect(PPointer(@jsonEachModule.xDestroy)^    = nil,  'M6 xDestroy nil');
  Expect(jsonEachModule.xOpen <> nil,            'M7 xOpen set');
  Expect(jsonEachModule.xClose <> nil,           'M8 xClose set');
  Expect(jsonEachModule.xFilter <> nil,          'M9 xFilter set');
  Expect(jsonEachModule.xNext <> nil,            'M10 xNext set');
  Expect(jsonEachModule.xEof <> nil,             'M11 xEof set');
  Expect(jsonEachModule.xColumn <> nil,          'M12 xColumn set');
  Expect(jsonEachModule.xRowid <> nil,           'M13 xRowid set');
  Expect(jsonEachModule.xUpdate = nil,           'M14 xUpdate nil');
  Expect(jsonEachModule.xSavepoint = nil,        'M15 xSavepoint nil');

  { ---- xBestIndex via fake vtab ---- }
  FillChar(fakeVt, SizeOf(fakeVt), 0);
  fakeVt.pModule := @jsonEachModule;
  TestBestIndex(@fakeVt);

  { ---- Column-ordinal pin ---- }
  ExpectEq(JEACH_KEY,     0, 'K1 KEY');
  ExpectEq(JEACH_VALUE,   1, 'K2 VALUE');
  ExpectEq(JEACH_TYPE,    2, 'K3 TYPE');
  ExpectEq(JEACH_ATOM,    3, 'K4 ATOM');
  ExpectEq(JEACH_ID,      4, 'K5 ID');
  ExpectEq(JEACH_PARENT,  5, 'K6 PARENT');
  ExpectEq(JEACH_FULLKEY, 6, 'K7 FULLKEY');
  ExpectEq(JEACH_PATH,    7, 'K8 PATH');
  ExpectEq(JEACH_JSON,    8, 'K9 JSON (hidden)');
  ExpectEq(JEACH_ROOT,    9, 'K10 ROOT (hidden)');

  { Drop registry before close so we exit clean. }
  rc := sqlite3_drop_modules(db, nil);
  ExpectEq(rc, SQLITE_OK, 'Z1 drop_modules');

  rc := sqlite3_close_v2(db);
  ExpectEq(rc, SQLITE_OK, 'Z2 close_v2');

  WriteLn;
  WriteLn('TestJsonEach: ', gPass, ' PASS, ', gFail, ' FAIL');
  if gFail <> 0 then Halt(1);
end.
