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
program TestVdbeArith;
{
  Phase 5.4d gate test — VDBE arithmetic / comparison opcodes.

    T1  OP_Add: 3 + 4 → 7
    T2  OP_Subtract: 10 - 3 → 7
    T3  OP_Multiply: 6 * 7 → 42
    T4  OP_Divide: 20 / 4 → 5; divide-by-zero → NULL
    T5  OP_Remainder: 17 % 5 → 2; divide-by-zero → NULL
    T6  OP_BitAnd / OP_BitOr: 12 & 10 = 8; 12 | 10 = 14
    T7  OP_ShiftLeft / OP_ShiftRight: 1 << 3 = 8; 16 >> 2 = 4
    T8  OP_AddImm: r[1] += 10 → 15
    T9  OP_Eq / OP_Ne (integer): jump taken / not taken
    T10 OP_Lt / OP_Le / OP_Gt / OP_Ge (integer)
    T11 NULL propagation in arithmetic
    T12 OP_Eq with NULL operands (SQLITE_NULLEQ)
    T13 Overflow → real: MaxInt64 + 1 → real

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

{ ===== T1: OP_Add ========================================================== }

procedure TestAdd;
var
  md: TVdbeMinDb;
  v:  PVdbe;
  rc: i32;
begin
  WriteLn('T1: OP_Add 3+4=7');
  VdbeInitMinDb(md, nil);
  v := VdbeCreateMinRun(@md.db, 4);
  if v = nil then begin VdbeCheck('T1 vdbe', False); Exit; end;
  { r[1]=3, r[2]=4, r[3]=r[1]+r[2] }
  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp2(v, OP_Integer, 3, 1);
  sqlite3VdbeAddOp2(v, OP_Integer, 4, 2);
  sqlite3VdbeAddOp3(v, OP_Add, 1, 2, 3);
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  v^.eVdbeState := VDBE_RUN_STATE;
  rc := sqlite3VdbeExec(v);
  VdbeCheck('T1 rc', rc = SQLITE_DONE);
  VdbeCheck('T1 result=7', (v^.aMem[3].flags and MEM_Int) <> 0);
  VdbeCheck('T1 value', v^.aMem[3].u.i = 7);
  sqlite3VdbeDelete(v);
end;

{ ===== T2: OP_Subtract ===================================================== }

procedure TestSubtract;
var
  md: TVdbeMinDb;
  v:  PVdbe;
  rc: i32;
begin
  WriteLn('T2: OP_Subtract 10-3=7');
  VdbeInitMinDb(md, nil);
  v := VdbeCreateMinRun(@md.db, 4);
  if v = nil then begin VdbeCheck('T2 vdbe', False); Exit; end;
  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp2(v, OP_Integer, 3, 1);
  sqlite3VdbeAddOp2(v, OP_Integer, 10, 2);
  sqlite3VdbeAddOp3(v, OP_Subtract, 1, 2, 3);  { r[3] = r[2] - r[1] }
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  v^.eVdbeState := VDBE_RUN_STATE;
  rc := sqlite3VdbeExec(v);
  VdbeCheck('T2 rc', rc = SQLITE_DONE);
  VdbeCheck('T2 result', v^.aMem[3].u.i = 7);
  sqlite3VdbeDelete(v);
end;

{ ===== T3: OP_Multiply ===================================================== }

procedure TestMultiply;
var
  md: TVdbeMinDb;
  v:  PVdbe;
  rc: i32;
begin
  WriteLn('T3: OP_Multiply 6*7=42');
  VdbeInitMinDb(md, nil);
  v := VdbeCreateMinRun(@md.db, 4);
  if v = nil then begin VdbeCheck('T3 vdbe', False); Exit; end;
  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp2(v, OP_Integer, 6, 1);
  sqlite3VdbeAddOp2(v, OP_Integer, 7, 2);
  sqlite3VdbeAddOp3(v, OP_Multiply, 1, 2, 3);
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  v^.eVdbeState := VDBE_RUN_STATE;
  rc := sqlite3VdbeExec(v);
  VdbeCheck('T3 rc', rc = SQLITE_DONE);
  VdbeCheck('T3 result=42', v^.aMem[3].u.i = 42);
  sqlite3VdbeDelete(v);
end;

{ ===== T4: OP_Divide ======================================================= }

procedure TestDivide;
var
  md: TVdbeMinDb;
  v:  PVdbe;
  rc: i32;
begin
  WriteLn('T4: OP_Divide 20/4=5; div-by-zero=NULL');
  VdbeInitMinDb(md, nil);

  { 20 / 4 = 5 }
  v := VdbeCreateMinRun(@md.db, 4);
  if v = nil then begin VdbeCheck('T4a vdbe', False); Exit; end;
  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp2(v, OP_Integer, 4, 1);
  sqlite3VdbeAddOp2(v, OP_Integer, 20, 2);
  sqlite3VdbeAddOp3(v, OP_Divide, 1, 2, 3);
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  v^.eVdbeState := VDBE_RUN_STATE;
  rc := sqlite3VdbeExec(v);
  VdbeCheck('T4a rc', rc = SQLITE_DONE);
  VdbeCheck('T4a result=5', v^.aMem[3].u.i = 5);
  sqlite3VdbeDelete(v);

  { divide by zero → NULL }
  v := VdbeCreateMinRun(@md.db, 4);
  if v = nil then begin VdbeCheck('T4b vdbe', False); Exit; end;
  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp2(v, OP_Integer, 0, 1);
  sqlite3VdbeAddOp2(v, OP_Integer, 20, 2);
  sqlite3VdbeAddOp3(v, OP_Divide, 1, 2, 3);
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  v^.eVdbeState := VDBE_RUN_STATE;
  rc := sqlite3VdbeExec(v);
  VdbeCheck('T4b rc', rc = SQLITE_DONE);
  VdbeCheck('T4b div-zero=NULL', (v^.aMem[3].flags and MEM_Null) <> 0);
  sqlite3VdbeDelete(v);
end;

{ ===== T5: OP_Remainder ==================================================== }

procedure TestRemainder;
var
  md: TVdbeMinDb;
  v:  PVdbe;
  rc: i32;
begin
  WriteLn('T5: OP_Remainder 17%5=2; mod-by-zero=NULL');
  VdbeInitMinDb(md, nil);

  { 17 % 5 = 2 }
  v := VdbeCreateMinRun(@md.db, 4);
  if v = nil then begin VdbeCheck('T5a vdbe', False); Exit; end;
  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp2(v, OP_Integer, 5, 1);
  sqlite3VdbeAddOp2(v, OP_Integer, 17, 2);
  sqlite3VdbeAddOp3(v, OP_Remainder, 1, 2, 3);
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  v^.eVdbeState := VDBE_RUN_STATE;
  rc := sqlite3VdbeExec(v);
  VdbeCheck('T5a rc', rc = SQLITE_DONE);
  VdbeCheck('T5a result=2', v^.aMem[3].u.i = 2);
  sqlite3VdbeDelete(v);

  { mod by zero → NULL }
  v := VdbeCreateMinRun(@md.db, 4);
  if v = nil then begin VdbeCheck('T5b vdbe', False); Exit; end;
  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp2(v, OP_Integer, 0, 1);
  sqlite3VdbeAddOp2(v, OP_Integer, 17, 2);
  sqlite3VdbeAddOp3(v, OP_Remainder, 1, 2, 3);
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  v^.eVdbeState := VDBE_RUN_STATE;
  rc := sqlite3VdbeExec(v);
  VdbeCheck('T5b rc', rc = SQLITE_DONE);
  VdbeCheck('T5b mod-zero=NULL', (v^.aMem[3].flags and MEM_Null) <> 0);
  sqlite3VdbeDelete(v);
end;

{ ===== T6: OP_BitAnd / OP_BitOr ============================================ }

procedure TestBitwise;
var
  md: TVdbeMinDb;
  v:  PVdbe;
  rc: i32;
begin
  WriteLn('T6: OP_BitAnd 12&10=8; OP_BitOr 12|10=14');
  VdbeInitMinDb(md, nil);

  { 12 & 10 = 8 }
  v := VdbeCreateMinRun(@md.db, 4);
  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp2(v, OP_Integer, 12, 1);
  sqlite3VdbeAddOp2(v, OP_Integer, 10, 2);
  sqlite3VdbeAddOp3(v, OP_BitAnd, 1, 2, 3);  { r[3] = r[2] & r[1] }
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  v^.eVdbeState := VDBE_RUN_STATE;
  rc := sqlite3VdbeExec(v);
  VdbeCheck('T6a rc', rc = SQLITE_DONE);
  VdbeCheck('T6a 12&10=8', v^.aMem[3].u.i = 8);
  sqlite3VdbeDelete(v);

  { 12 | 10 = 14 }
  v := VdbeCreateMinRun(@md.db, 4);
  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp2(v, OP_Integer, 12, 1);
  sqlite3VdbeAddOp2(v, OP_Integer, 10, 2);
  sqlite3VdbeAddOp3(v, OP_BitOr, 1, 2, 3);   { r[3] = r[2] | r[1] }
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  v^.eVdbeState := VDBE_RUN_STATE;
  rc := sqlite3VdbeExec(v);
  VdbeCheck('T6b rc', rc = SQLITE_DONE);
  VdbeCheck('T6b 12|10=14', v^.aMem[3].u.i = 14);
  sqlite3VdbeDelete(v);
end;

{ ===== T7: OP_ShiftLeft / OP_ShiftRight ==================================== }

procedure TestShift;
var
  md: TVdbeMinDb;
  v:  PVdbe;
  rc: i32;
begin
  WriteLn('T7: OP_ShiftLeft 1<<3=8; OP_ShiftRight 16>>2=4');
  VdbeInitMinDb(md, nil);

  { 1 << 3 = 8: r[1]=3 (shift amount), r[2]=1 (value to shift), r[3]=result }
  v := VdbeCreateMinRun(@md.db, 4);
  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp2(v, OP_Integer, 3, 1);
  sqlite3VdbeAddOp2(v, OP_Integer, 1, 2);
  sqlite3VdbeAddOp3(v, OP_ShiftLeft, 1, 2, 3);
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  v^.eVdbeState := VDBE_RUN_STATE;
  rc := sqlite3VdbeExec(v);
  VdbeCheck('T7a rc', rc = SQLITE_DONE);
  VdbeCheck('T7a 1<<3=8', v^.aMem[3].u.i = 8);
  sqlite3VdbeDelete(v);

  { 16 >> 2 = 4 }
  v := VdbeCreateMinRun(@md.db, 4);
  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp2(v, OP_Integer, 2, 1);
  sqlite3VdbeAddOp2(v, OP_Integer, 16, 2);
  sqlite3VdbeAddOp3(v, OP_ShiftRight, 1, 2, 3);
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  v^.eVdbeState := VDBE_RUN_STATE;
  rc := sqlite3VdbeExec(v);
  VdbeCheck('T7b rc', rc = SQLITE_DONE);
  VdbeCheck('T7b 16>>2=4', v^.aMem[3].u.i = 4);
  sqlite3VdbeDelete(v);
end;

{ ===== T8: OP_AddImm ======================================================= }

procedure TestAddImm;
var
  md: TVdbeMinDb;
  v:  PVdbe;
  rc: i32;
begin
  WriteLn('T8: OP_AddImm r[1]=5; AddImm(+10) → 15');
  VdbeInitMinDb(md, nil);
  v := VdbeCreateMinRun(@md.db, 3);
  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp2(v, OP_Integer, 5, 1);
  sqlite3VdbeAddOp2(v, OP_AddImm, 1, 10);
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  v^.eVdbeState := VDBE_RUN_STATE;
  rc := sqlite3VdbeExec(v);
  VdbeCheck('T8 rc', rc = SQLITE_DONE);
  VdbeCheck('T8 result=15', v^.aMem[1].u.i = 15);
  sqlite3VdbeDelete(v);
end;

{ ===== T9: OP_Eq / OP_Ne =================================================== }

procedure TestEqNe;
var
  md:  TVdbeMinDb;
  v:   PVdbe;
  rc:  i32;
begin
  WriteLn('T9: OP_Eq / OP_Ne jumps');
  VdbeInitMinDb(md, nil);

  { Eq: 5 == 5 → jump taken (r[3] set to 99 by jump target) }
  { prog: Init, Integer(5,1), Integer(5,3), Eq(1,jmp,3,p5=0), Integer(0,2), Halt
           jmp: Integer(99,2), Halt }
  v := VdbeCreateMinRun(@md.db, 5);
  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);      { 0 }
  sqlite3VdbeAddOp2(v, OP_Integer, 5, 1);   { 1: r[1]=5 }
  sqlite3VdbeAddOp2(v, OP_Integer, 5, 3);   { 2: r[3]=5 }
  sqlite3VdbeAddOp3(v, OP_Eq, 1, 6, 3);    { 3: if r[3]==r[1] goto 6 }
  sqlite3VdbeAddOp2(v, OP_Integer, 0, 2);   { 4: r[2]=0 (not-equal path) }
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);      { 5 }
  sqlite3VdbeAddOp2(v, OP_Integer, 99, 2);  { 6: r[2]=99 (equal path) }
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);      { 7 }
  v^.eVdbeState := VDBE_RUN_STATE;
  rc := sqlite3VdbeExec(v);
  VdbeCheck('T9a rc', rc = SQLITE_DONE);
  VdbeCheck('T9a Eq jump taken', v^.aMem[2].u.i = 99);
  sqlite3VdbeDelete(v);

  { Ne: 5 != 7 → jump taken }
  v := VdbeCreateMinRun(@md.db, 5);
  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp2(v, OP_Integer, 7, 1);
  sqlite3VdbeAddOp2(v, OP_Integer, 5, 3);
  sqlite3VdbeAddOp3(v, OP_Ne, 1, 6, 3);    { 3: if r[3]!=r[1] goto 6 }
  sqlite3VdbeAddOp2(v, OP_Integer, 0, 2);
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  sqlite3VdbeAddOp2(v, OP_Integer, 77, 2);
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  v^.eVdbeState := VDBE_RUN_STATE;
  rc := sqlite3VdbeExec(v);
  VdbeCheck('T9b rc', rc = SQLITE_DONE);
  VdbeCheck('T9b Ne jump taken', v^.aMem[2].u.i = 77);
  sqlite3VdbeDelete(v);

  { Eq: 5 == 7 → jump NOT taken }
  v := VdbeCreateMinRun(@md.db, 5);
  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp2(v, OP_Integer, 7, 1);
  sqlite3VdbeAddOp2(v, OP_Integer, 5, 3);
  sqlite3VdbeAddOp3(v, OP_Eq, 1, 6, 3);    { 3: if r[3]==r[1] goto 6 }
  sqlite3VdbeAddOp2(v, OP_Integer, 11, 2);  { 4: fall-through }
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  sqlite3VdbeAddOp2(v, OP_Integer, 22, 2);
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  v^.eVdbeState := VDBE_RUN_STATE;
  rc := sqlite3VdbeExec(v);
  VdbeCheck('T9c rc', rc = SQLITE_DONE);
  VdbeCheck('T9c Eq no-jump', v^.aMem[2].u.i = 11);
  sqlite3VdbeDelete(v);
end;

{ ===== T10: OP_Lt / OP_Le / OP_Gt / OP_Ge ================================= }

procedure TestRelational;
var
  md:  TVdbeMinDb;
  v:   PVdbe;
  rc:  i32;
begin
  WriteLn('T10: OP_Lt/Le/Gt/Ge jumps');
  VdbeInitMinDb(md, nil);

  { Lt: 3 < 7 → jump taken. r[1]=7(p1), r[3]=3(p3). Condition: r[3] < r[1] }
  v := VdbeCreateMinRun(@md.db, 5);
  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp2(v, OP_Integer, 7, 1);
  sqlite3VdbeAddOp2(v, OP_Integer, 3, 3);
  sqlite3VdbeAddOp3(v, OP_Lt, 1, 6, 3);    { if r[3]<r[1] goto 6 }
  sqlite3VdbeAddOp2(v, OP_Integer, 0, 2);
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  sqlite3VdbeAddOp2(v, OP_Integer, 1, 2);
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  v^.eVdbeState := VDBE_RUN_STATE;
  rc := sqlite3VdbeExec(v);
  VdbeCheck('T10a Lt 3<7 jump', v^.aMem[2].u.i = 1);
  sqlite3VdbeDelete(v);

  { Le: 7 <= 7 → jump taken }
  v := VdbeCreateMinRun(@md.db, 5);
  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp2(v, OP_Integer, 7, 1);
  sqlite3VdbeAddOp2(v, OP_Integer, 7, 3);
  sqlite3VdbeAddOp3(v, OP_Le, 1, 6, 3);
  sqlite3VdbeAddOp2(v, OP_Integer, 0, 2);
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  sqlite3VdbeAddOp2(v, OP_Integer, 1, 2);
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  v^.eVdbeState := VDBE_RUN_STATE;
  rc := sqlite3VdbeExec(v);
  VdbeCheck('T10b Le 7<=7 jump', v^.aMem[2].u.i = 1);
  sqlite3VdbeDelete(v);

  { Gt: 10 > 3 → jump taken. r[1]=3, r[3]=10 }
  v := VdbeCreateMinRun(@md.db, 5);
  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp2(v, OP_Integer, 3, 1);
  sqlite3VdbeAddOp2(v, OP_Integer, 10, 3);
  sqlite3VdbeAddOp3(v, OP_Gt, 1, 6, 3);
  sqlite3VdbeAddOp2(v, OP_Integer, 0, 2);
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  sqlite3VdbeAddOp2(v, OP_Integer, 1, 2);
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  v^.eVdbeState := VDBE_RUN_STATE;
  rc := sqlite3VdbeExec(v);
  VdbeCheck('T10c Gt 10>3 jump', v^.aMem[2].u.i = 1);
  sqlite3VdbeDelete(v);

  { Ge: 3 >= 5 → NOT taken }
  v := VdbeCreateMinRun(@md.db, 5);
  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp2(v, OP_Integer, 5, 1);
  sqlite3VdbeAddOp2(v, OP_Integer, 3, 3);
  sqlite3VdbeAddOp3(v, OP_Ge, 1, 6, 3);    { if r[3]>=r[1] goto 6 }
  sqlite3VdbeAddOp2(v, OP_Integer, 55, 2); { fall-through }
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  sqlite3VdbeAddOp2(v, OP_Integer, 66, 2);
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  v^.eVdbeState := VDBE_RUN_STATE;
  rc := sqlite3VdbeExec(v);
  VdbeCheck('T10d Ge 3>=5 no-jump', v^.aMem[2].u.i = 55);
  sqlite3VdbeDelete(v);
end;

{ ===== T11: NULL propagation in arithmetic ================================= }

procedure TestNullArith;
var
  md: TVdbeMinDb;
  v:  PVdbe;
  rc: i32;
begin
  WriteLn('T11: NULL + 5 → NULL');
  VdbeInitMinDb(md, nil);
  v := VdbeCreateMinRun(@md.db, 4);
  { r[1] stays NULL (zero-initialized), r[2]=5, r[3] = r[1]+r[2] }
  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp2(v, OP_Integer, 5, 2);
  sqlite3VdbeAddOp3(v, OP_Add, 1, 2, 3);
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  v^.aMem[1].flags := MEM_Null;
  v^.eVdbeState := VDBE_RUN_STATE;
  rc := sqlite3VdbeExec(v);
  VdbeCheck('T11 rc', rc = SQLITE_DONE);
  VdbeCheck('T11 NULL+5=NULL', (v^.aMem[3].flags and MEM_Null) <> 0);
  sqlite3VdbeDelete(v);
end;

{ ===== T12: OP_Eq with SQLITE_NULLEQ ======================================= }

procedure TestNullEq;
var
  md: TVdbeMinDb;
  v:  PVdbe;
  rc: i32;
begin
  WriteLn('T12: OP_Eq NULL==NULL with SQLITE_NULLEQ → jump taken');
  VdbeInitMinDb(md, nil);
  { r[1]=NULL, r[3]=NULL → Eq with NULLEQ should jump }
  v := VdbeCreateMinRun(@md.db, 5);
  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  { leave r[1] and r[3] as NULL (zero-initialized = MEM_Null=0... but flags=0) }
  sqlite3VdbeAddOp3(v, OP_Eq, 1, 5, 3);    { 1: if r[3]==r[1] goto 5, p5=NULLEQ }
  sqlite3VdbeAddOp2(v, OP_Integer, 0, 2);   { 2: fall-through }
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);      { 3 }
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);      { 4: padding }
  sqlite3VdbeAddOp2(v, OP_Integer, 1, 2);   { 5: jump target }
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);      { 6 }
  { Set NULLEQ flag on the Eq instruction (opcode at index 1) }
  v^.aOp[1].p5 := SQLITE_NULLEQ;
  v^.aMem[1].flags := MEM_Null;
  v^.aMem[3].flags := MEM_Null;
  v^.eVdbeState := VDBE_RUN_STATE;
  rc := sqlite3VdbeExec(v);
  VdbeCheck('T12 rc', rc = SQLITE_DONE);
  VdbeCheck('T12 NULL==NULL NULLEQ jump', v^.aMem[2].u.i = 1);
  sqlite3VdbeDelete(v);
end;

{ ===== T13: Overflow → real ================================================ }

procedure TestOverflow;
var
  md: TVdbeMinDb;
  v:  PVdbe;
  rc: i32;
begin
  WriteLn('T13: MaxInt64 + MaxInt64 → real');
  VdbeInitMinDb(md, nil);
  v := VdbeCreateMinRun(@md.db, 4);
  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  { Load MaxInt64 into r[1] and r[2] via Int64 literal }
  sqlite3VdbeAddOp4Int(v, OP_Int64, 0, 1, 0, 0);
  sqlite3VdbeAddOp4Int(v, OP_Int64, 0, 2, 0, 0);
  sqlite3VdbeAddOp3(v, OP_Add, 1, 2, 3);
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  { Manually set r[1] and r[2] to MaxInt64 }
  v^.aMem[1].flags := MEM_Int;
  v^.aMem[1].u.i   := High(i64);
  v^.aMem[2].flags := MEM_Int;
  v^.aMem[2].u.i   := High(i64);
  v^.nOp := 0;
  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp3(v, OP_Add, 1, 2, 3);
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  v^.eVdbeState := VDBE_RUN_STATE;
  v^.aMem[1].flags := MEM_Int;
  v^.aMem[1].u.i   := High(i64);
  v^.aMem[2].flags := MEM_Int;
  v^.aMem[2].u.i   := High(i64);
  rc := sqlite3VdbeExec(v);
  VdbeCheck('T13 rc', rc = SQLITE_DONE);
  VdbeCheck('T13 overflow→real', (v^.aMem[3].flags and MEM_Real) <> 0);
  sqlite3VdbeDelete(v);
end;

{ ===== main ================================================================= }

begin
  sqlite3OsInit;
  sqlite3PcacheInitialize;

  WriteLn('=== TestVdbeArith — Phase 5.4d gate test ===');
  WriteLn;

  TestAdd;           WriteLn;
  TestSubtract;      WriteLn;
  TestMultiply;      WriteLn;
  TestDivide;        WriteLn;
  TestRemainder;     WriteLn;
  TestBitwise;       WriteLn;
  TestShift;         WriteLn;
  TestAddImm;        WriteLn;
  TestEqNe;          WriteLn;
  TestRelational;    WriteLn;
  TestNullArith;     WriteLn;
  TestNullEq;        WriteLn;
  TestOverflow;      WriteLn;

  WriteLn(Format('Results: %d passed, %d failed', [gVdbePass, gVdbeFail]));
  if gVdbeFail > 0 then Halt(1);
end.
