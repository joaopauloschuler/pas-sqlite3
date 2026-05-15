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
  passqlite3vdbe,
  TestVdbeCommon;

{ Build a VDBE that emits one row: r[1]=int, r[2]=double, r[3]=null, r[4]=text
  Uses ResultRow to yield a row, then Halt. }
function BuildOneRowVdbe(pDb: PTsqlite3): PVdbe;
var
  v: PVdbe;
  zStr: PAnsiChar;
begin
  zStr := 'hello';
  v := VdbeCreateMinReady(pDb, 6);
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
  md: TVdbeMinDb;
  v:  PVdbe;
  rc: i32;
begin
  WriteLn('T1: sqlite3_column_count / data_count');
  VdbeInitMinDb(md, nil);
  v := BuildOneRowVdbe(@md.db);
  if v = nil then begin VdbeCheck('T1 vdbe', False); Exit; end;

  VdbeCheck('T1 col_count=4', sqlite3_column_count(v) = 4);
  VdbeCheck('T1 data_count=0 before step', sqlite3_data_count(v) = 0);

  rc := sqlite3_step(v);
  VdbeCheck('T1 rc=ROW', rc = SQLITE_ROW);
  VdbeCheck('T1 data_count=4 after step', sqlite3_data_count(v) = 4);

  sqlite3_finalize(v);
end;

{ ===== T2: column_type / int / int64 / double ============================== }

procedure TestColumnNumeric;
var
  md: TVdbeMinDb;
  v:  PVdbe;
  rc: i32;
begin
  WriteLn('T2: column_type / int / int64 / double');
  VdbeInitMinDb(md, nil);
  v := BuildOneRowVdbe(@md.db);
  if v = nil then begin VdbeCheck('T2 vdbe', False); Exit; end;

  rc := sqlite3_step(v);
  VdbeCheck('T2 rc=ROW', rc = SQLITE_ROW);
  VdbeCheck('T2 col0 type=INTEGER', sqlite3_column_type(v, 0) = SQLITE_INTEGER);
  VdbeCheck('T2 col0 int=42',       sqlite3_column_int(v, 0) = 42);
  VdbeCheck('T2 col0 int64=42',     sqlite3_column_int64(v, 0) = 42);
  VdbeCheck('T2 col1 type=FLOAT',   sqlite3_column_type(v, 1) = SQLITE_FLOAT);
  VdbeCheck('T2 col1 double=314',   sqlite3_column_double(v, 1) = 314.0);
  VdbeCheck('T2 col2 type=NULL',    sqlite3_column_type(v, 2) = SQLITE_NULL);

  sqlite3_finalize(v);
end;

{ ===== T3: column_text ===================================================== }

procedure TestColumnText;
var
  md:  TVdbeMinDb;
  v:   PVdbe;
  rc:  i32;
  txt: PAnsiChar;
begin
  WriteLn('T3: column_text');
  VdbeInitMinDb(md, nil);
  v := BuildOneRowVdbe(@md.db);
  if v = nil then begin VdbeCheck('T3 vdbe', False); Exit; end;

  rc := sqlite3_step(v);
  VdbeCheck('T3 rc=ROW', rc = SQLITE_ROW);
  txt := sqlite3_column_text(v, 3);  { col 3 (0-based) = 'hello' }
  VdbeCheck('T3 col3 text<>nil', txt <> nil);
  if txt <> nil then
    VdbeCheck('T3 col3 text=hello', StrComp(txt, 'hello') = 0);

  sqlite3_finalize(v);
end;

{ ===== T4: column_blob / bytes ============================================= }

procedure TestColumnBlob;
var
  md:   TVdbeMinDb;
  v:    PVdbe;
  rc:   i32;
  blob: Pointer;
begin
  WriteLn('T4: column_blob / bytes');
  VdbeInitMinDb(md, nil);
  { Build a VDBE that stores blob data in r[1] }
  v := VdbeCreateMinReady(@md.db, 3);
  if v = nil then begin VdbeCheck('T4 vdbe', False); Exit; end;

  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp4(v, OP_Blob, 3, 1, 0, PAnsiChar('abc'), P4_STATIC);
  sqlite3VdbeAddOp2(v, OP_ResultRow, 1, 1);
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  sqlite3VdbeSetNumCols(v, 1);
  v^.eVdbeState := VDBE_READY_STATE;

  rc := sqlite3_step(v);
  VdbeCheck('T4 rc=ROW', rc = SQLITE_ROW);
  VdbeCheck('T4 col0 type=BLOB',  sqlite3_column_type(v, 0) = SQLITE_BLOB);
  VdbeCheck('T4 col0 bytes=3',    sqlite3_column_bytes(v, 0) = 3);
  blob := sqlite3_column_blob(v, 0);
  VdbeCheck('T4 col0 blob<>nil',  blob <> nil);
  if blob <> nil then
    VdbeCheck('T4 blob[0]=a', PAnsiChar(blob)[0] = 'a');

  sqlite3_finalize(v);
end;

{ ===== T5: sqlite3_reset and re-step ======================================= }

procedure TestReset;
var
  md:  TVdbeMinDb;
  v:   PVdbe;
  rc:  i32;
begin
  WriteLn('T5: sqlite3_reset → re-step same result');
  VdbeInitMinDb(md, nil);
  v := BuildOneRowVdbe(@md.db);
  if v = nil then begin VdbeCheck('T5 vdbe', False); Exit; end;

  rc := sqlite3_step(v);
  VdbeCheck('T5 first step=ROW', rc = SQLITE_ROW);
  VdbeCheck('T5 col0=42 first',  sqlite3_column_int(v, 0) = 42);

  sqlite3_reset(v);

  rc := sqlite3_step(v);
  VdbeCheck('T5 second step=ROW', rc = SQLITE_ROW);
  VdbeCheck('T5 col0=42 second',  sqlite3_column_int(v, 0) = 42);

  sqlite3_finalize(v);
end;

{ ===== T6: sqlite3_bind_int / double / null ================================ }

procedure TestBindNumeric;
var
  md:  TVdbeMinDb;
  v:   PVdbe;
  rc:  i32;
begin
  WriteLn('T6: sqlite3_bind_int / double / null → column reads');
  VdbeInitMinDb(md, nil);
  { Build VDBE with 3 variables, ResultRow them }
  v := VdbeCreateMinReady(@md.db, 5);
  if v = nil then begin VdbeCheck('T6 vdbe', False); Exit; end;

  { Allocate aVar array (3 params) }
  v^.nVar := 3;
  v^.aVar := PMem(sqlite3DbMallocZero(@md.db, 3 * SizeOf(TMem)));
  if v^.aVar = nil then begin VdbeCheck('T6 aVar', False); sqlite3_finalize(v); Exit; end;
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

  VdbeCheck('T6 bind_int',    sqlite3_bind_int(v, 1, 99) = SQLITE_OK);
  VdbeCheck('T6 bind_double', sqlite3_bind_double(v, 2, 2.71828) = SQLITE_OK);
  VdbeCheck('T6 bind_null',   sqlite3_bind_null(v, 3) = SQLITE_OK);

  rc := sqlite3_step(v);
  VdbeCheck('T6 rc=ROW',      rc = SQLITE_ROW);
  VdbeCheck('T6 col0=99',     sqlite3_column_int(v, 0) = 99);
  VdbeCheck('T6 col1≈2.718',  Abs(sqlite3_column_double(v, 1) - 2.71828) < 1e-5);
  VdbeCheck('T6 col2=NULL',   sqlite3_column_type(v, 2) = SQLITE_NULL);

  sqlite3_finalize(v);
end;

{ ===== T7: sqlite3_bind_text =============================================== }

procedure TestBindText;
var
  md:  TVdbeMinDb;
  v:   PVdbe;
  rc:  i32;
  txt: PAnsiChar;
begin
  WriteLn('T7: sqlite3_bind_text → column_text');
  VdbeInitMinDb(md, nil);
  v := VdbeCreateMinReady(@md.db, 3);
  if v = nil then begin VdbeCheck('T7 vdbe', False); Exit; end;

  v^.nVar := 1;
  v^.aVar := PMem(sqlite3DbMallocZero(@md.db, SizeOf(TMem)));
  if v^.aVar = nil then begin VdbeCheck('T7 aVar', False); sqlite3_finalize(v); Exit; end;
  v^.aVar^.flags := MEM_Null;

  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp2(v, OP_Variable, 1, 1);
  sqlite3VdbeAddOp2(v, OP_ResultRow, 1, 1);
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  sqlite3VdbeSetNumCols(v, 1);

  VdbeCheck('T7 bind_text', sqlite3_bind_text(v, 1, 'world', 5, SQLITE_STATIC) = SQLITE_OK);

  rc := sqlite3_step(v);
  VdbeCheck('T7 rc=ROW',    rc = SQLITE_ROW);
  txt := sqlite3_column_text(v, 0);
  VdbeCheck('T7 text<>nil', txt <> nil);
  if txt <> nil then
    VdbeCheck('T7 text=world', StrComp(txt, 'world') = 0);

  sqlite3_finalize(v);
end;

{ ===== T8: sqlite3_bind_blob =============================================== }

procedure TestBindBlob;
var
  md:    TVdbeMinDb;
  v:     PVdbe;
  rc:    i32;
  blob:  Pointer;
begin
  WriteLn('T8: sqlite3_bind_blob → column_blob / bytes');
  VdbeInitMinDb(md, nil);
  v := VdbeCreateMinReady(@md.db, 3);
  if v = nil then begin VdbeCheck('T8 vdbe', False); Exit; end;

  v^.nVar := 1;
  v^.aVar := PMem(sqlite3DbMallocZero(@md.db, SizeOf(TMem)));
  if v^.aVar = nil then begin VdbeCheck('T8 aVar', False); sqlite3_finalize(v); Exit; end;
  v^.aVar^.flags := MEM_Null;

  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp2(v, OP_Variable, 1, 1);
  sqlite3VdbeAddOp2(v, OP_ResultRow, 1, 1);
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  sqlite3VdbeSetNumCols(v, 1);

  VdbeCheck('T8 bind_blob', sqlite3_bind_blob(v, 1, PAnsiChar('xyz'), 3,
                                          SQLITE_STATIC) = SQLITE_OK);

  rc := sqlite3_step(v);
  VdbeCheck('T8 rc=ROW',   rc = SQLITE_ROW);
  VdbeCheck('T8 type=BLOB', sqlite3_column_type(v, 0) = SQLITE_BLOB);
  VdbeCheck('T8 bytes=3',  sqlite3_column_bytes(v, 0) = 3);
  blob := sqlite3_column_blob(v, 0);
  VdbeCheck('T8 blob<>nil', blob <> nil);
  if blob <> nil then
    VdbeCheck('T8 blob[1]=y', PAnsiChar(blob)[1] = 'y');

  sqlite3_finalize(v);
end;

{ ===== T9: sqlite3_bind_value ============================================== }

procedure TestBindValue;
var
  md:   TVdbeMinDb;
  v:    PVdbe;
  src:  TMem;
  rc:   i32;
begin
  WriteLn('T9: sqlite3_bind_value (copy integer 7)');
  VdbeInitMinDb(md, nil);
  v := VdbeCreateMinReady(@md.db, 3);
  if v = nil then begin VdbeCheck('T9 vdbe', False); Exit; end;

  v^.nVar := 1;
  v^.aVar := PMem(sqlite3DbMallocZero(@md.db, SizeOf(TMem)));
  if v^.aVar = nil then begin VdbeCheck('T9 aVar', False); sqlite3_finalize(v); Exit; end;
  v^.aVar^.flags := MEM_Null;

  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp2(v, OP_Variable, 1, 1);
  sqlite3VdbeAddOp2(v, OP_ResultRow, 1, 1);
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  sqlite3VdbeSetNumCols(v, 1);

  FillChar(src, SizeOf(src), 0);
  sqlite3VdbeMemSetInt64(@src, 7);

  VdbeCheck('T9 bind_value', sqlite3_bind_value(v, 1, @src) = SQLITE_OK);
  rc := sqlite3_step(v);
  VdbeCheck('T9 rc=ROW',   rc = SQLITE_ROW);
  VdbeCheck('T9 col=7',    sqlite3_column_int(v, 0) = 7);

  sqlite3_finalize(v);
end;

{ ===== T10: sqlite3_clear_bindings ========================================= }

procedure TestClearBindings;
var
  md:  TVdbeMinDb;
  v:   PVdbe;
  rc:  i32;
begin
  WriteLn('T10: sqlite3_clear_bindings → columns become NULL');
  VdbeInitMinDb(md, nil);
  v := VdbeCreateMinReady(@md.db, 3);
  if v = nil then begin VdbeCheck('T10 vdbe', False); Exit; end;

  v^.nVar := 1;
  v^.aVar := PMem(sqlite3DbMallocZero(@md.db, SizeOf(TMem)));
  if v^.aVar = nil then begin VdbeCheck('T10 aVar', False); sqlite3_finalize(v); Exit; end;
  v^.aVar^.flags := MEM_Null;

  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp2(v, OP_Variable, 1, 1);
  sqlite3VdbeAddOp2(v, OP_ResultRow, 1, 1);
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  sqlite3VdbeSetNumCols(v, 1);

  sqlite3_bind_int(v, 1, 55);
  VdbeCheck('T10 clear', sqlite3_clear_bindings(v) = SQLITE_OK);

  rc := sqlite3_step(v);
  VdbeCheck('T10 rc=ROW',      rc = SQLITE_ROW);
  VdbeCheck('T10 col=NULL', sqlite3_column_type(v, 0) = SQLITE_NULL);

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
  VdbeCheck('T11 type INT',  sqlite3_value_type(@m) = SQLITE_INTEGER);
  VdbeCheck('T11 int=123',   sqlite3_value_int(@m) = 123);
  VdbeCheck('T11 int64=123', sqlite3_value_int64(@m) = 123);

  sqlite3VdbeMemSetDouble(@m, 3.14);
  VdbeCheck('T11 type FLOAT', sqlite3_value_type(@m) = SQLITE_FLOAT);
  VdbeCheck('T11 double≈3.14', Abs(sqlite3_value_double(@m) - 3.14) < 1e-10);

  sqlite3VdbeMemSetNull(@m);
  VdbeCheck('T11 type NULL', sqlite3_value_type(@m) = SQLITE_NULL);

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
  VdbeCheck('T12 dup<>nil',   pDup <> nil);
  if pDup <> nil then begin
    VdbeCheck('T12 dup type=INT', sqlite3_value_type(pDup) = SQLITE_INTEGER);
    VdbeCheck('T12 dup val=42',   sqlite3_value_int(pDup) = 42);
    sqlite3_value_free(pDup);
    VdbeCheck('T12 freed',        True);
  end;
  sqlite3VdbeMemRelease(@orig);
end;

{ ===== T13: sqlite3_finalize returns SQLITE_OK ============================= }

procedure TestFinalize;
var
  md:  TVdbeMinDb;
  v:   PVdbe;
  rc:  i32;
begin
  WriteLn('T13: sqlite3_finalize returns SQLITE_OK');
  VdbeInitMinDb(md, nil);
  v := BuildOneRowVdbe(@md.db);
  if v = nil then begin VdbeCheck('T13 vdbe', False); Exit; end;

  sqlite3_step(v);
  rc := sqlite3_finalize(v);
  VdbeCheck('T13 finalize=OK', rc = SQLITE_OK);
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

  WriteLn(Format('Results: %d passed, %d failed', [gVdbePass, gVdbeFail]));
  if gVdbeFail > 0 then Halt(1);
end.
