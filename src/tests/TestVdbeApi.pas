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
program TestVdbeApi;
{
  Phase 5.5 gate test — vdbeapi.c public API.

    T1  sqlite3_column_count / data_count
    T2  sqlite3_column_type / int / int64 / double after SQLITE_ROW
    T3  sqlite3_column_text  after SQLITE_ROW
    T4  sqlite3_column_blob / bytes after SQLITE_ROW
    T5  sqlite3_reset → re-step, second row
    T6  sqlite3_bind_int / bind_double / bind_null → column reads
    T7  sqlite3_bind_text → column_text
    T8  sqlite3_bind_blob → column_blob / bytes
    T9  sqlite3_bind_value (copy integer)
    T10 sqlite3_clear_bindings → columns become NULL
    T11 sqlite3_value_type / int / double / text
    T12 sqlite3_value_dup / value_free
    T13 sqlite3_finalize returns SQLITE_OK

  Gate: T1–T13 all PASS.
}

uses
  SysUtils,
  passqlite3types,
  passqlite3os,
  passqlite3util,
  passqlite3pcache,
  passqlite3pager,
  passqlite3wal,
  passqlite3btree,
  passqlite3vdbe;

{ ===== helpers ============================================================== }

var
  gPass: i32 = 0;
  gFail: i32 = 0;

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

{ ===== Infrastructure ======================================================= }

const
  PARSE_SZ = 256;

type
  TMinDb = record
    db:        Tsqlite3;
    parseArea: array[0..PARSE_SZ-1] of Byte;
  end;

procedure InitMinDb(var md: TMinDb);
begin
  FillChar(md, SizeOf(md), 0);
  md.db.enc        := SQLITE_UTF8;
  md.db.nDb        := 0;
  md.db.aLimit[5]  := 250000000;
  md.db.aLimit[0]  := 1000000000;
end;

function CreateMinVdbe(pDb: PTsqlite3; nMem: i32): PVdbe;
var
  pParse: Pointer;
  v:      PVdbe;
  sz:     u64;
begin
  pParse := sqlite3DbMallocZero(pDb, PARSE_SZ);
  if pParse = nil then begin Result := nil; Exit; end;
  PPointer(pParse)^ := pDb;
  Pi32(PByte(pParse) + 156)^ := 250000000;

  v := sqlite3VdbeCreate(pParse);
  sqlite3DbFree(pDb, pParse);
  if v = nil then begin Result := nil; Exit; end;

  v^.nOp := 0;
  sz := u64(nMem) * SizeOf(TMem);
  v^.aMem  := PMem(sqlite3DbMallocZero(pDb, sz));
  v^.nMem  := nMem;
  v^.apCsr   := nil;
  v^.nCursor := 0;
  v^.eVdbeState         := VDBE_READY_STATE;
  v^.minWriteFileFormat := 4;
  v^.pc                 := 0;
  v^.cacheCtr           := 1;
  Result := v;
end;

{ Build a VDBE that emits one row: r[1]=int, r[2]=double, r[3]=null, r[4]=text
  Uses ResultRow to yield a row, then Halt. }
function BuildOneRowVdbe(pDb: PTsqlite3): PVdbe;
var
  v: PVdbe;
  zStr: PAnsiChar;
begin
  zStr := 'hello';
  v := CreateMinVdbe(pDb, 6);
  if v = nil then begin Result := nil; Exit; end;

  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp2(v, OP_Integer, 42, 1);            { r[1] = 42 }
  sqlite3VdbeAddOp2(v, OP_Integer, 314, 2);           { r[2] = 314 (becomes 314.0) }
  sqlite3VdbeAddOp2(v, OP_Cast, 2, SQLITE_AFF_REAL);  { r[2] = 314.0 }
  sqlite3VdbeAddOp2(v, OP_Null, 0, 3);                { r[3] = NULL }
  sqlite3VdbeAddOp4(v, OP_String, 5, 4, 0, zStr, P4_STATIC); { r[4]='hello' }
  sqlite3VdbeAddOp2(v, OP_ResultRow, 1, 4);            { yield r[1..4] }
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  sqlite3VdbeSetNumCols(v, 4);
  v^.pResultRow := nil;
  Result := v;
end;

{ ===== T1: column_count / data_count ======================================= }

procedure TestColumnCount;
var
  md: TMinDb;
  v:  PVdbe;
  rc: i32;
begin
  WriteLn('T1: sqlite3_column_count / data_count');
  InitMinDb(md);
  v := BuildOneRowVdbe(@md.db);
  if v = nil then begin Check('T1 vdbe', False); Exit; end;

  Check('T1 col_count=4', sqlite3_column_count(v) = 4);
  Check('T1 data_count=0 before step', sqlite3_data_count(v) = 0);

  rc := sqlite3_step(v);
  Check('T1 rc=ROW', rc = SQLITE_ROW);
  Check('T1 data_count=4 after step', sqlite3_data_count(v) = 4);

  sqlite3_finalize(v);
end;

{ ===== T2: column_type / int / int64 / double ============================== }

procedure TestColumnNumeric;
var
  md: TMinDb;
  v:  PVdbe;
  rc: i32;
begin
  WriteLn('T2: column_type / int / int64 / double');
  InitMinDb(md);
  v := BuildOneRowVdbe(@md.db);
  if v = nil then begin Check('T2 vdbe', False); Exit; end;

  rc := sqlite3_step(v);
  Check('T2 rc=ROW', rc = SQLITE_ROW);
  Check('T2 col0 type=INTEGER', sqlite3_column_type(v, 0) = SQLITE_INTEGER);
  Check('T2 col0 int=42',       sqlite3_column_int(v, 0) = 42);
  Check('T2 col0 int64=42',     sqlite3_column_int64(v, 0) = 42);
  Check('T2 col1 type=FLOAT',   sqlite3_column_type(v, 1) = SQLITE_FLOAT);
  Check('T2 col1 double=314',   sqlite3_column_double(v, 1) = 314.0);
  Check('T2 col2 type=NULL',    sqlite3_column_type(v, 2) = SQLITE_NULL);

  sqlite3_finalize(v);
end;

{ ===== T3: column_text ===================================================== }

procedure TestColumnText;
var
  md:  TMinDb;
  v:   PVdbe;
  rc:  i32;
  txt: PAnsiChar;
begin
  WriteLn('T3: column_text');
  InitMinDb(md);
  v := BuildOneRowVdbe(@md.db);
  if v = nil then begin Check('T3 vdbe', False); Exit; end;

  rc := sqlite3_step(v);
  Check('T3 rc=ROW', rc = SQLITE_ROW);
  txt := sqlite3_column_text(v, 3);  { col 3 (0-based) = 'hello' }
  Check('T3 col3 text<>nil', txt <> nil);
  if txt <> nil then
    Check('T3 col3 text=hello', StrComp(txt, 'hello') = 0);

  sqlite3_finalize(v);
end;

{ ===== T4: column_blob / bytes ============================================= }

procedure TestColumnBlob;
var
  md:   TMinDb;
  v:    PVdbe;
  rc:   i32;
  blob: Pointer;
begin
  WriteLn('T4: column_blob / bytes');
  InitMinDb(md);
  { Build a VDBE that stores blob data in r[1] }
  v := CreateMinVdbe(@md.db, 3);
  if v = nil then begin Check('T4 vdbe', False); Exit; end;

  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp4(v, OP_Blob, 3, 1, 0, PAnsiChar('abc'), P4_STATIC);
  sqlite3VdbeAddOp2(v, OP_ResultRow, 1, 1);
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  sqlite3VdbeSetNumCols(v, 1);
  v^.eVdbeState := VDBE_READY_STATE;

  rc := sqlite3_step(v);
  Check('T4 rc=ROW', rc = SQLITE_ROW);
  Check('T4 col0 type=BLOB',  sqlite3_column_type(v, 0) = SQLITE_BLOB);
  Check('T4 col0 bytes=3',    sqlite3_column_bytes(v, 0) = 3);
  blob := sqlite3_column_blob(v, 0);
  Check('T4 col0 blob<>nil',  blob <> nil);
  if blob <> nil then
    Check('T4 blob[0]=a', PAnsiChar(blob)[0] = 'a');

  sqlite3_finalize(v);
end;

{ ===== T5: sqlite3_reset and re-step ======================================= }

procedure TestReset;
var
  md:  TMinDb;
  v:   PVdbe;
  rc:  i32;
begin
  WriteLn('T5: sqlite3_reset → re-step same result');
  InitMinDb(md);
  v := BuildOneRowVdbe(@md.db);
  if v = nil then begin Check('T5 vdbe', False); Exit; end;

  rc := sqlite3_step(v);
  Check('T5 first step=ROW', rc = SQLITE_ROW);
  Check('T5 col0=42 first',  sqlite3_column_int(v, 0) = 42);

  sqlite3_reset(v);

  rc := sqlite3_step(v);
  Check('T5 second step=ROW', rc = SQLITE_ROW);
  Check('T5 col0=42 second',  sqlite3_column_int(v, 0) = 42);

  sqlite3_finalize(v);
end;

{ ===== T6: sqlite3_bind_int / double / null ================================ }

procedure TestBindNumeric;
var
  md:  TMinDb;
  v:   PVdbe;
  rc:  i32;
begin
  WriteLn('T6: sqlite3_bind_int / double / null → column reads');
  InitMinDb(md);
  { Build VDBE with 3 variables, ResultRow them }
  v := CreateMinVdbe(@md.db, 5);
  if v = nil then begin Check('T6 vdbe', False); Exit; end;

  { Allocate aVar array (3 params) }
  v^.nVar := 3;
  v^.aVar := PMem(sqlite3DbMallocZero(@md.db, 3 * SizeOf(TMem)));
  if v^.aVar = nil then begin Check('T6 aVar', False); sqlite3_finalize(v); Exit; end;
  (v^.aVar + 0)^.flags := MEM_Null;
  (v^.aVar + 1)^.flags := MEM_Null;
  (v^.aVar + 2)^.flags := MEM_Null;

  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  { OP_Variable p1=varno(1-based), p2=dest_reg }
  sqlite3VdbeAddOp2(v, OP_Variable, 1, 1);  { r[1] = var[1] }
  sqlite3VdbeAddOp2(v, OP_Variable, 2, 2);  { r[2] = var[2] }
  sqlite3VdbeAddOp2(v, OP_Variable, 3, 3);  { r[3] = var[3] }
  sqlite3VdbeAddOp2(v, OP_ResultRow, 1, 3);
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  sqlite3VdbeSetNumCols(v, 3);

  Check('T6 bind_int',    sqlite3_bind_int(v, 1, 99) = SQLITE_OK);
  Check('T6 bind_double', sqlite3_bind_double(v, 2, 2.71828) = SQLITE_OK);
  Check('T6 bind_null',   sqlite3_bind_null(v, 3) = SQLITE_OK);

  rc := sqlite3_step(v);
  Check('T6 rc=ROW',      rc = SQLITE_ROW);
  Check('T6 col0=99',     sqlite3_column_int(v, 0) = 99);
  Check('T6 col1≈2.718',  Abs(sqlite3_column_double(v, 1) - 2.71828) < 1e-5);
  Check('T6 col2=NULL',   sqlite3_column_type(v, 2) = SQLITE_NULL);

  sqlite3_finalize(v);
end;

{ ===== T7: sqlite3_bind_text =============================================== }

procedure TestBindText;
var
  md:  TMinDb;
  v:   PVdbe;
  rc:  i32;
  txt: PAnsiChar;
begin
  WriteLn('T7: sqlite3_bind_text → column_text');
  InitMinDb(md);
  v := CreateMinVdbe(@md.db, 3);
  if v = nil then begin Check('T7 vdbe', False); Exit; end;

  v^.nVar := 1;
  v^.aVar := PMem(sqlite3DbMallocZero(@md.db, SizeOf(TMem)));
  if v^.aVar = nil then begin Check('T7 aVar', False); sqlite3_finalize(v); Exit; end;
  v^.aVar^.flags := MEM_Null;

  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp2(v, OP_Variable, 1, 1);
  sqlite3VdbeAddOp2(v, OP_ResultRow, 1, 1);
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  sqlite3VdbeSetNumCols(v, 1);

  Check('T7 bind_text', sqlite3_bind_text(v, 1, 'world', 5, SQLITE_STATIC) = SQLITE_OK);

  rc := sqlite3_step(v);
  Check('T7 rc=ROW',    rc = SQLITE_ROW);
  txt := sqlite3_column_text(v, 0);
  Check('T7 text<>nil', txt <> nil);
  if txt <> nil then
    Check('T7 text=world', StrComp(txt, 'world') = 0);

  sqlite3_finalize(v);
end;

{ ===== T8: sqlite3_bind_blob =============================================== }

procedure TestBindBlob;
var
  md:    TMinDb;
  v:     PVdbe;
  rc:    i32;
  blob:  Pointer;
begin
  WriteLn('T8: sqlite3_bind_blob → column_blob / bytes');
  InitMinDb(md);
  v := CreateMinVdbe(@md.db, 3);
  if v = nil then begin Check('T8 vdbe', False); Exit; end;

  v^.nVar := 1;
  v^.aVar := PMem(sqlite3DbMallocZero(@md.db, SizeOf(TMem)));
  if v^.aVar = nil then begin Check('T8 aVar', False); sqlite3_finalize(v); Exit; end;
  v^.aVar^.flags := MEM_Null;

  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp2(v, OP_Variable, 1, 1);
  sqlite3VdbeAddOp2(v, OP_ResultRow, 1, 1);
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  sqlite3VdbeSetNumCols(v, 1);

  Check('T8 bind_blob', sqlite3_bind_blob(v, 1, PAnsiChar('xyz'), 3,
                                          SQLITE_STATIC) = SQLITE_OK);

  rc := sqlite3_step(v);
  Check('T8 rc=ROW',   rc = SQLITE_ROW);
  Check('T8 type=BLOB', sqlite3_column_type(v, 0) = SQLITE_BLOB);
  Check('T8 bytes=3',  sqlite3_column_bytes(v, 0) = 3);
  blob := sqlite3_column_blob(v, 0);
  Check('T8 blob<>nil', blob <> nil);
  if blob <> nil then
    Check('T8 blob[1]=y', PAnsiChar(blob)[1] = 'y');

  sqlite3_finalize(v);
end;

{ ===== T9: sqlite3_bind_value ============================================== }

procedure TestBindValue;
var
  md:   TMinDb;
  v:    PVdbe;
  src:  TMem;
  rc:   i32;
begin
  WriteLn('T9: sqlite3_bind_value (copy integer 7)');
  InitMinDb(md);
  v := CreateMinVdbe(@md.db, 3);
  if v = nil then begin Check('T9 vdbe', False); Exit; end;

  v^.nVar := 1;
  v^.aVar := PMem(sqlite3DbMallocZero(@md.db, SizeOf(TMem)));
  if v^.aVar = nil then begin Check('T9 aVar', False); sqlite3_finalize(v); Exit; end;
  v^.aVar^.flags := MEM_Null;

  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp2(v, OP_Variable, 1, 1);
  sqlite3VdbeAddOp2(v, OP_ResultRow, 1, 1);
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  sqlite3VdbeSetNumCols(v, 1);

  FillChar(src, SizeOf(src), 0);
  sqlite3VdbeMemSetInt64(@src, 7);

  Check('T9 bind_value', sqlite3_bind_value(v, 1, @src) = SQLITE_OK);
  rc := sqlite3_step(v);
  Check('T9 rc=ROW',   rc = SQLITE_ROW);
  Check('T9 col=7',    sqlite3_column_int(v, 0) = 7);

  sqlite3_finalize(v);
end;

{ ===== T10: sqlite3_clear_bindings ========================================= }

procedure TestClearBindings;
var
  md:  TMinDb;
  v:   PVdbe;
  rc:  i32;
begin
  WriteLn('T10: sqlite3_clear_bindings → columns become NULL');
  InitMinDb(md);
  v := CreateMinVdbe(@md.db, 3);
  if v = nil then begin Check('T10 vdbe', False); Exit; end;

  v^.nVar := 1;
  v^.aVar := PMem(sqlite3DbMallocZero(@md.db, SizeOf(TMem)));
  if v^.aVar = nil then begin Check('T10 aVar', False); sqlite3_finalize(v); Exit; end;
  v^.aVar^.flags := MEM_Null;

  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp2(v, OP_Variable, 1, 1);
  sqlite3VdbeAddOp2(v, OP_ResultRow, 1, 1);
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  sqlite3VdbeSetNumCols(v, 1);

  sqlite3_bind_int(v, 1, 55);
  Check('T10 clear', sqlite3_clear_bindings(v) = SQLITE_OK);

  rc := sqlite3_step(v);
  Check('T10 rc=ROW',      rc = SQLITE_ROW);
  Check('T10 col=NULL', sqlite3_column_type(v, 0) = SQLITE_NULL);

  sqlite3_finalize(v);
end;

{ ===== T11: sqlite3_value_type / int / double / text ======================= }

procedure TestValueAccessors;
var
  m: TMem;
begin
  WriteLn('T11: sqlite3_value_type / int / double / text on TMem');
  FillChar(m, SizeOf(m), 0);

  sqlite3VdbeMemSetInt64(@m, 123);
  Check('T11 type INT',  sqlite3_value_type(@m) = SQLITE_INTEGER);
  Check('T11 int=123',   sqlite3_value_int(@m) = 123);
  Check('T11 int64=123', sqlite3_value_int64(@m) = 123);

  sqlite3VdbeMemSetDouble(@m, 3.14);
  Check('T11 type FLOAT', sqlite3_value_type(@m) = SQLITE_FLOAT);
  Check('T11 double≈3.14', Abs(sqlite3_value_double(@m) - 3.14) < 1e-10);

  sqlite3VdbeMemSetNull(@m);
  Check('T11 type NULL', sqlite3_value_type(@m) = SQLITE_NULL);

  sqlite3VdbeMemRelease(@m);
end;

{ ===== T12: sqlite3_value_dup / value_free ================================= }

procedure TestValueDup;
var
  orig: TMem;
  pDup: Psqlite3_value;
begin
  WriteLn('T12: sqlite3_value_dup / value_free');
  FillChar(orig, SizeOf(orig), 0);
  sqlite3VdbeMemSetInt64(@orig, 42);

  pDup := sqlite3_value_dup(@orig);
  Check('T12 dup<>nil',   pDup <> nil);
  if pDup <> nil then begin
    Check('T12 dup type=INT', sqlite3_value_type(pDup) = SQLITE_INTEGER);
    Check('T12 dup val=42',   sqlite3_value_int(pDup) = 42);
    sqlite3_value_free(pDup);
    Check('T12 freed',        True);
  end;
  sqlite3VdbeMemRelease(@orig);
end;

{ ===== T13: sqlite3_finalize returns SQLITE_OK ============================= }

procedure TestFinalize;
var
  md:  TMinDb;
  v:   PVdbe;
  rc:  i32;
begin
  WriteLn('T13: sqlite3_finalize returns SQLITE_OK');
  InitMinDb(md);
  v := BuildOneRowVdbe(@md.db);
  if v = nil then begin Check('T13 vdbe', False); Exit; end;

  sqlite3_step(v);
  rc := sqlite3_finalize(v);
  Check('T13 finalize=OK', rc = SQLITE_OK);
end;

{ ===== main ================================================================= }

begin
  sqlite3OsInit;
  sqlite3PcacheInitialize;

  WriteLn('=== TestVdbeApi — Phase 5.5 gate test ===');
  WriteLn;

  TestColumnCount;   WriteLn;
  TestColumnNumeric; WriteLn;
  TestColumnText;    WriteLn;
  TestColumnBlob;    WriteLn;
  TestReset;         WriteLn;
  TestBindNumeric;   WriteLn;
  TestBindText;      WriteLn;
  TestBindBlob;      WriteLn;
  TestBindValue;     WriteLn;
  TestClearBindings; WriteLn;
  TestValueAccessors; WriteLn;
  TestValueDup;      WriteLn;
  TestFinalize;      WriteLn;

  WriteLn(Format('Results: %d passed, %d failed', [gPass, gFail]));
  if gFail > 0 then Halt(1);
end.
