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
program TestVdbeMisc;
{
  Phase 5.4h gate test — miscellaneous VDBE opcodes.

    T1  OP_Real: load float constant → r[1] = 3.14
    T2  OP_Not: !TRUE=0, !FALSE=1, !NULL=NULL
    T3  OP_BitNot: ~5 = -6, NULL→NULL
    T4  OP_And/Or: truth tables (F∧T=0, T∨N=1, N∧F=0, N∨N=NULL)
    T5  OP_IsNull / OP_NotNull jumps
    T6  OP_Cast: integer→text via SQLITE_AFF_TEXT
    T7  OP_Affinity: apply NUMERIC affinity to text "42"
    T8  OP_IsTrue: IS TRUE / IS FALSE / IS NOT TRUE
    T9  OP_ZeroOrNull: both non-NULL→0; one NULL→NULL
    T10 OP_HaltIfNull: non-NULL → falls through; NULL → halts
    T11 OP_Noop: no-op, execution continues
    T12 OP_MustBeInt: numeric string "7"→7; non-int→jump
    T13 OP_ClrSubtype / OP_GetSubtype / OP_SetSubtype

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

{ ===== T1: OP_Real ========================================================= }

procedure TestReal;
var
  md:  TVdbeMinDb;
  v:   PVdbe;
  rc:  i32;
  rValPtr: PDouble;
begin
  WriteLn('T1: OP_Real → r[1] = 3.14');
  VdbeInitMinDb(md, nil);
  { P4_REAL pointer is freed by VdbeDelete — must be heap-allocated }
  rValPtr := PDouble(sqlite3DbMallocZero(@md.db, SizeOf(Double)));
  if rValPtr = nil then begin VdbeCheck('T1 alloc', False); Exit; end;
  rValPtr^ := 3.14;

  v := VdbeCreateMinRun(@md.db, 3);
  if v = nil then begin VdbeCheck('T1 vdbe', False); sqlite3DbFree(@md.db, rValPtr); Exit; end;

  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp4(v, OP_Real, 0, 1, 0, PAnsiChar(rValPtr), P4_REAL);
  { rValPtr ownership transferred to the VDBE instruction — do not free separately }
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  v^.eVdbeState := VDBE_RUN_STATE;

  rc := sqlite3VdbeExec(v);
  VdbeCheck('T1 rc', rc = SQLITE_DONE);
  VdbeCheck('T1 MEM_Real', (v^.aMem[1].flags and MEM_Real) <> 0);
  VdbeCheck('T1 r=3.14', Abs(v^.aMem[1].u.r - 3.14) < 1e-10);

  sqlite3VdbeDelete(v);
end;

{ ===== T2: OP_Not ========================================================== }

procedure TestNot;
var
  md:  TVdbeMinDb;
  v:   PVdbe;
  rc:  i32;
begin
  WriteLn('T2: OP_Not: !1=0, !0=1, !NULL=NULL');
  VdbeInitMinDb(md, nil);
  { r[1]=1(true), r[2]=0(false), r[3]=NULL
    r[4]=!r[1], r[5]=!r[2], r[6]=!r[3] }
  v := VdbeCreateMinRun(@md.db, 8);
  if v = nil then begin VdbeCheck('T2 vdbe', False); Exit; end;

  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp2(v, OP_Integer, 1, 1);
  sqlite3VdbeAddOp2(v, OP_Integer, 0, 2);
  sqlite3VdbeAddOp2(v, OP_Null, 0, 3);
  sqlite3VdbeAddOp3(v, OP_Not, 1, 4, 0);
  sqlite3VdbeAddOp3(v, OP_Not, 2, 5, 0);
  sqlite3VdbeAddOp3(v, OP_Not, 3, 6, 0);
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  v^.eVdbeState := VDBE_RUN_STATE;

  rc := sqlite3VdbeExec(v);
  VdbeCheck('T2 rc', rc = SQLITE_DONE);
  VdbeCheck('T2 !1=0', v^.aMem[4].u.i = 0);
  VdbeCheck('T2 !0=1', v^.aMem[5].u.i = 1);
  VdbeCheck('T2 !NULL=NULL', (v^.aMem[6].flags and MEM_Null) <> 0);

  sqlite3VdbeDelete(v);
end;

{ ===== T3: OP_BitNot ======================================================= }

procedure TestBitNot;
var
  md:  TVdbeMinDb;
  v:   PVdbe;
  rc:  i32;
begin
  WriteLn('T3: OP_BitNot: ~5=-6, ~NULL=NULL');
  VdbeInitMinDb(md, nil);
  v := VdbeCreateMinRun(@md.db, 5);
  if v = nil then begin VdbeCheck('T3 vdbe', False); Exit; end;

  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp2(v, OP_Integer, 5, 1);
  sqlite3VdbeAddOp2(v, OP_Null, 0, 2);
  sqlite3VdbeAddOp3(v, OP_BitNot, 1, 3, 0);
  sqlite3VdbeAddOp3(v, OP_BitNot, 2, 4, 0);
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  v^.eVdbeState := VDBE_RUN_STATE;

  rc := sqlite3VdbeExec(v);
  VdbeCheck('T3 rc', rc = SQLITE_DONE);
  VdbeCheck('T3 ~5=-6', v^.aMem[3].u.i = -6);
  VdbeCheck('T3 ~NULL', (v^.aMem[4].flags and MEM_Null) <> 0);

  sqlite3VdbeDelete(v);
end;

{ ===== T4: OP_And / OP_Or ================================================== }

procedure TestAndOr;
var
  md:  TVdbeMinDb;
  v:   PVdbe;
  rc:  i32;
begin
  WriteLn('T4: OP_And/Or: F∧T=0, T∨N=1, N∧F=0');
  VdbeInitMinDb(md, nil);
  { r[1]=F(0), r[2]=T(1), r[3]=NULL
    r[4]=r[1] AND r[2]=0, r[5]=r[2] OR r[3]=1, r[6]=r[3] AND r[1]=0 }
  v := VdbeCreateMinRun(@md.db, 8);
  if v = nil then begin VdbeCheck('T4 vdbe', False); Exit; end;

  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp2(v, OP_Integer, 0, 1);
  sqlite3VdbeAddOp2(v, OP_Integer, 1, 2);
  sqlite3VdbeAddOp2(v, OP_Null, 0, 3);
  sqlite3VdbeAddOp3(v, OP_And, 1, 2, 4);  { r[4]=r[1] AND r[2]=F AND T=0 }
  sqlite3VdbeAddOp3(v, OP_Or,  2, 3, 5);  { r[5]=r[2] OR  r[3]=T OR  N=1 }
  sqlite3VdbeAddOp3(v, OP_And, 3, 1, 6);  { r[6]=r[3] AND r[1]=N AND F=0 }
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  v^.eVdbeState := VDBE_RUN_STATE;

  rc := sqlite3VdbeExec(v);
  VdbeCheck('T4 rc', rc = SQLITE_DONE);
  VdbeCheck('T4 F∧T=0', (v^.aMem[4].flags and MEM_Int) <> 0);
  VdbeCheck('T4 F∧T=0 val', v^.aMem[4].u.i = 0);
  VdbeCheck('T4 T∨N=1', v^.aMem[5].u.i = 1);
  VdbeCheck('T4 N∧F=0', v^.aMem[6].u.i = 0);

  sqlite3VdbeDelete(v);
end;

{ ===== T5: OP_IsNull / OP_NotNull ========================================== }

procedure TestNullJumps;
var
  md:  TVdbeMinDb;
  v:   PVdbe;
  rc:  i32;
begin
  WriteLn('T5: OP_IsNull / OP_NotNull conditional jumps');
  VdbeInitMinDb(md, nil);
  { r[1]=NULL, r[2]=42, r[3]=0(marker)
    OP_IsNull r[1] → jump to set r[3]=1
    OP_NotNull r[2] → jump to set r[3]=r[3]+1 }
  v := VdbeCreateMinRun(@md.db, 5);
  if v = nil then begin VdbeCheck('T5 vdbe', False); Exit; end;

  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);            { 0: jump to addr 1 }
  sqlite3VdbeAddOp2(v, OP_Null, 0, 1);            { 1: r[1]=NULL }
  sqlite3VdbeAddOp2(v, OP_Integer, 42, 2);        { 2: r[2]=42 }
  sqlite3VdbeAddOp2(v, OP_Integer, 0, 3);         { 3: r[3]=0 }
  sqlite3VdbeAddOp2(v, OP_IsNull, 1, 6);          { 4: if r[1]=NULL goto 6 }
  sqlite3VdbeAddOp2(v, OP_Integer, 99, 3);        { 5: r[3]=99 (should skip) }
  sqlite3VdbeAddOp2(v, OP_Integer, 1, 3);         { 6: r[3]=1 (taken) }
  sqlite3VdbeAddOp2(v, OP_NotNull, 2, 9);         { 7: if r[2]<>NULL goto 9 }
  sqlite3VdbeAddOp2(v, OP_Integer, 88, 3);        { 8: r[3]=88 (should skip) }
  sqlite3VdbeAddOp2(v, OP_AddImm, 3, 10);         { 9: r[3]+=10 → 11 }
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);            { 10 }
  v^.eVdbeState := VDBE_RUN_STATE;

  rc := sqlite3VdbeExec(v);
  VdbeCheck('T5 rc', rc = SQLITE_DONE);
  VdbeCheck('T5 r[3]=11', v^.aMem[3].u.i = 11);

  sqlite3VdbeDelete(v);
end;

{ ===== T6: OP_Cast ========================================================= }

procedure TestCast;
var
  md:  TVdbeMinDb;
  v:   PVdbe;
  rc:  i32;
begin
  WriteLn('T6: OP_Cast integer 42 → TEXT "42"');
  VdbeInitMinDb(md, nil);
  v := VdbeCreateMinRun(@md.db, 3);
  if v = nil then begin VdbeCheck('T6 vdbe', False); Exit; end;

  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp2(v, OP_Integer, 42, 1);
  { OP_Cast p1=reg, p2=affinity }
  sqlite3VdbeAddOp2(v, OP_Cast, 1, SQLITE_AFF_TEXT);
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  v^.eVdbeState := VDBE_RUN_STATE;

  rc := sqlite3VdbeExec(v);
  VdbeCheck('T6 rc', rc = SQLITE_DONE);
  VdbeCheck('T6 MEM_Str', (v^.aMem[1].flags and MEM_Str) <> 0);
  VdbeCheck('T6 "42"', StrLComp(v^.aMem[1].z, '42', 2) = 0);

  sqlite3VdbeDelete(v);
end;

{ ===== T7: OP_Affinity ===================================================== }

procedure TestAffinity;
var
  md:    TVdbeMinDb;
  v:     PVdbe;
  rc:    i32;
  zAff:  PAnsiChar;
begin
  WriteLn('T7: OP_Affinity: NUMERIC on "42" → integer 42');
  VdbeInitMinDb(md, nil);
  zAff := PAnsiChar('C');  { SQLITE_AFF_NUMERIC = ord('C') }
  v := VdbeCreateMinRun(@md.db, 3);
  if v = nil then begin VdbeCheck('T7 vdbe', False); Exit; end;

  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp4(v, OP_String, 2, 1, 0, PAnsiChar('42'), P4_STATIC);
  { OP_Affinity: p1=first_reg, p2=count, p4=affinity_string }
  sqlite3VdbeAddOp4(v, OP_Affinity, 1, 1, 0, zAff, P4_STATIC);
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  v^.eVdbeState := VDBE_RUN_STATE;

  rc := sqlite3VdbeExec(v);
  VdbeCheck('T7 rc', rc = SQLITE_DONE);
  VdbeCheck('T7 MEM_Int', (v^.aMem[1].flags and MEM_Int) <> 0);
  VdbeCheck('T7 val=42', v^.aMem[1].u.i = 42);

  sqlite3VdbeDelete(v);
end;

{ ===== T8: OP_IsTrue ======================================================= }

procedure TestIsTrue;
var
  md:  TVdbeMinDb;
  v:   PVdbe;
  rc:  i32;
begin
  WriteLn('T8: OP_IsTrue: IS TRUE, IS NOT TRUE');
  VdbeInitMinDb(md, nil);
  { r[1]=1(true), r[2]=0(false), r[3]=NULL
    r[4]=r[1] IS TRUE = 1
    r[5]=r[2] IS NOT TRUE = 1 (NOT TRUE → P3=0, P4=1)
    r[6]=r[3] IS TRUE = 0 (NULL→P3=0 XOR P4=0) }
  v := VdbeCreateMinRun(@md.db, 8);
  if v = nil then begin VdbeCheck('T8 vdbe', False); Exit; end;

  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp2(v, OP_Integer, 1, 1);
  sqlite3VdbeAddOp2(v, OP_Integer, 0, 2);
  sqlite3VdbeAddOp2(v, OP_Null, 0, 3);
  { OP_IsTrue p1=in, p2=out, p3=nullResult, p4=negate }
  { r[4] = r[1] IS TRUE: p3=0, p4=0 }
  sqlite3VdbeAddOp4(v, OP_IsTrue, 1, 4, 0, nil, P4_INT32);
  { r[5] = r[2] IS NOT TRUE: p3=0, p4=1 }
  sqlite3VdbeAddOp4(v, OP_IsTrue, 2, 5, 0, PAnsiChar(1), P4_INT32);
  { r[6] = r[3] IS TRUE: p3=0 (null→0), p4=0 }
  sqlite3VdbeAddOp4(v, OP_IsTrue, 3, 6, 0, nil, P4_INT32);
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  v^.eVdbeState := VDBE_RUN_STATE;

  rc := sqlite3VdbeExec(v);
  VdbeCheck('T8 rc', rc = SQLITE_DONE);
  VdbeCheck('T8 TRUE IS TRUE=1',     v^.aMem[4].u.i = 1);
  VdbeCheck('T8 FALSE IS NOT TRUE=1',v^.aMem[5].u.i = 1);
  VdbeCheck('T8 NULL IS TRUE=0',     v^.aMem[6].u.i = 0);

  sqlite3VdbeDelete(v);
end;

{ ===== T9: OP_ZeroOrNull =================================================== }

procedure TestZeroOrNull;
var
  md:  TVdbeMinDb;
  v:   PVdbe;
  rc:  i32;
begin
  WriteLn('T9: OP_ZeroOrNull: both non-NULL→0; one NULL→NULL');
  VdbeInitMinDb(md, nil);
  { r[1]=5, r[2]=NULL, r[3]=7
    r[4] = ZeroOrNull(r[1], r[3]) = 0  (both non-NULL)
    r[5] = ZeroOrNull(r[1], r[2]) = NULL  (r[2]=NULL) }
  v := VdbeCreateMinRun(@md.db, 7);
  if v = nil then begin VdbeCheck('T9 vdbe', False); Exit; end;

  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp2(v, OP_Integer, 5, 1);
  sqlite3VdbeAddOp2(v, OP_Null, 0, 2);
  sqlite3VdbeAddOp2(v, OP_Integer, 7, 3);
  { OP_ZeroOrNull p1=in1, p2=out, p3=in3 }
  sqlite3VdbeAddOp3(v, OP_ZeroOrNull, 1, 4, 3);  { r[4]=ZeroOrNull(r[1],r[3]) }
  sqlite3VdbeAddOp3(v, OP_ZeroOrNull, 1, 5, 2);  { r[5]=ZeroOrNull(r[1],r[2]) }
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  v^.eVdbeState := VDBE_RUN_STATE;

  rc := sqlite3VdbeExec(v);
  VdbeCheck('T9 rc', rc = SQLITE_DONE);
  VdbeCheck('T9 nonNULL=0', v^.aMem[4].u.i = 0);
  VdbeCheck('T9 oneNULL=NULL', (v^.aMem[5].flags and MEM_Null) <> 0);

  sqlite3VdbeDelete(v);
end;

{ ===== T10: OP_HaltIfNull ================================================== }

procedure TestHaltIfNull;
var
  md:  TVdbeMinDb;
  v:   PVdbe;
  rc:  i32;
begin
  WriteLn('T10: OP_HaltIfNull: non-NULL falls through; NULL halts');
  VdbeInitMinDb(md, nil);
  { r[1]=42: HaltIfNull should NOT halt; r[2] gets set to 99 }
  v := VdbeCreateMinRun(@md.db, 4);
  if v = nil then begin VdbeCheck('T10a vdbe', False); Exit; end;

  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp2(v, OP_Integer, 42, 1);
  sqlite3VdbeAddOp3(v, OP_HaltIfNull, 0, 0, 1);  { p3=r[1], p1=0=SQLITE_OK }
  sqlite3VdbeAddOp2(v, OP_Integer, 99, 2);         { should execute }
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  v^.eVdbeState := VDBE_RUN_STATE;

  rc := sqlite3VdbeExec(v);
  VdbeCheck('T10a rc', rc = SQLITE_DONE);
  VdbeCheck('T10a r[2]=99', v^.aMem[2].u.i = 99);
  sqlite3VdbeDelete(v);
  WriteLn;

  { r[1]=NULL: HaltIfNull SHOULD halt; r[2] should NOT get set }
  VdbeInitMinDb(md, nil);
  v := VdbeCreateMinRun(@md.db, 4);
  if v = nil then begin VdbeCheck('T10b vdbe', False); Exit; end;

  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp2(v, OP_Null, 0, 1);
  sqlite3VdbeAddOp3(v, OP_HaltIfNull, 0, 0, 1);  { NULL → halt }
  sqlite3VdbeAddOp2(v, OP_Integer, 99, 2);         { should NOT execute }
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  v^.eVdbeState := VDBE_RUN_STATE;

  rc := sqlite3VdbeExec(v);
  VdbeCheck('T10b rc=DONE', rc = SQLITE_DONE);
  VdbeCheck('T10b r[2]=0', v^.aMem[2].u.i = 0);  { not set → stays 0 }
  sqlite3VdbeDelete(v);
end;

{ ===== T11: OP_Noop ======================================================== }

procedure TestNoop;
var
  md:  TVdbeMinDb;
  v:   PVdbe;
  rc:  i32;
begin
  WriteLn('T11: OP_Noop → execution continues');
  VdbeInitMinDb(md, nil);
  v := VdbeCreateMinRun(@md.db, 3);
  if v = nil then begin VdbeCheck('T11 vdbe', False); Exit; end;

  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp2(v, OP_Integer, 77, 1);
  sqlite3VdbeAddOp2(v, OP_Noop, 0, 0);
  sqlite3VdbeAddOp2(v, OP_Noop, 0, 0);
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  v^.eVdbeState := VDBE_RUN_STATE;

  rc := sqlite3VdbeExec(v);
  VdbeCheck('T11 rc', rc = SQLITE_DONE);
  VdbeCheck('T11 r[1]=77', v^.aMem[1].u.i = 77);

  sqlite3VdbeDelete(v);
end;

{ ===== T12: OP_MustBeInt =================================================== }

procedure TestMustBeInt;
var
  md:  TVdbeMinDb;
  v:   PVdbe;
  rc:  i32;
begin
  WriteLn('T12: OP_MustBeInt: "7"→7; "x"→jump');
  VdbeInitMinDb(md, nil);
  { Part A: "7" coerces to 7 (no jump) }
  v := VdbeCreateMinRun(@md.db, 4);
  if v = nil then begin VdbeCheck('T12a vdbe', False); Exit; end;

  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp4(v, OP_String, 1, 1, 0, PAnsiChar('7'), P4_STATIC);
  sqlite3VdbeAddOp3(v, OP_MustBeInt, 1, 4, 0);   { p1=reg, p2=jump-addr=4 }
  sqlite3VdbeAddOp2(v, OP_Integer, 1, 2);          { marker: executed if no jump }
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);             { 4 }
  v^.eVdbeState := VDBE_RUN_STATE;

  rc := sqlite3VdbeExec(v);
  VdbeCheck('T12a rc', rc = SQLITE_DONE);
  VdbeCheck('T12a r[1]=7', v^.aMem[1].u.i = 7);
  VdbeCheck('T12a no-jump', v^.aMem[2].u.i = 1);
  sqlite3VdbeDelete(v);
  WriteLn;

  { Part B: "abc" can't be int → jump to addr 4 }
  VdbeInitMinDb(md, nil);
  v := VdbeCreateMinRun(@md.db, 4);
  if v = nil then begin VdbeCheck('T12b vdbe', False); Exit; end;

  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp4(v, OP_String, 3, 1, 0, PAnsiChar('abc'), P4_STATIC);
  sqlite3VdbeAddOp3(v, OP_MustBeInt, 1, 5, 0);   { p2=5: jump there }
  sqlite3VdbeAddOp2(v, OP_Integer, 1, 2);          { 3: should NOT execute }
  sqlite3VdbeAddOp2(v, OP_Goto, 0, 6);             { 4: skip }
  sqlite3VdbeAddOp2(v, OP_Integer, 42, 3);         { 5: jump target }
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);             { 6 }
  v^.eVdbeState := VDBE_RUN_STATE;

  rc := sqlite3VdbeExec(v);
  VdbeCheck('T12b rc', rc = SQLITE_DONE);
  VdbeCheck('T12b jumped', v^.aMem[3].u.i = 42);
  VdbeCheck('T12b skipped', v^.aMem[2].u.i = 0);
  sqlite3VdbeDelete(v);
end;

{ ===== T13: OP_ClrSubtype / OP_GetSubtype / OP_SetSubtype ================= }

procedure TestSubtype;
var
  md:  TVdbeMinDb;
  v:   PVdbe;
  rc:  i32;
begin
  WriteLn('T13: OP_SetSubtype/GetSubtype/ClrSubtype');
  VdbeInitMinDb(md, nil);
  { r[1]=any, set subtype=7 via r[2]=7
    r[3]=GetSubtype(r[1]) = 7
    ClrSubtype(r[1])
    r[4]=GetSubtype(r[1]) = NULL }
  v := VdbeCreateMinRun(@md.db, 6);
  if v = nil then begin VdbeCheck('T13 vdbe', False); Exit; end;

  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp2(v, OP_Integer, 42, 1);   { r[1]=42 }
  sqlite3VdbeAddOp2(v, OP_Integer, 7, 2);    { r[2]=7 (subtype value) }
  sqlite3VdbeAddOp3(v, OP_SetSubtype, 2, 1, 0);  { r[1].subtype = r[2] = 7 }
  sqlite3VdbeAddOp3(v, OP_GetSubtype, 1, 3, 0);  { r[3] = r[1].subtype = 7 }
  sqlite3VdbeAddOp2(v, OP_ClrSubtype, 1, 0);     { clear r[1].subtype }
  sqlite3VdbeAddOp3(v, OP_GetSubtype, 1, 4, 0);  { r[4] = r[1].subtype = NULL }
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  v^.eVdbeState := VDBE_RUN_STATE;

  rc := sqlite3VdbeExec(v);
  VdbeCheck('T13 rc', rc = SQLITE_DONE);
  VdbeCheck('T13 subtype=7', v^.aMem[3].u.i = 7);
  VdbeCheck('T13 cleared=NULL', (v^.aMem[4].flags and MEM_Null) <> 0);

  sqlite3VdbeDelete(v);
end;

{ ===== main ================================================================= }

begin
  sqlite3OsInit;
  sqlite3PcacheInitialize;

  WriteLn('=== TestVdbeMisc — Phase 5.4h gate test ===');
  WriteLn;

  TestReal;        WriteLn;
  TestNot;         WriteLn;
  TestBitNot;      WriteLn;
  TestAndOr;       WriteLn;
  TestNullJumps;   WriteLn;
  TestCast;        WriteLn;
  TestAffinity;    WriteLn;
  TestIsTrue;      WriteLn;
  TestZeroOrNull;  WriteLn;
  TestHaltIfNull;
  WriteLn;
  TestNoop;        WriteLn;
  TestMustBeInt;
  WriteLn;
  TestSubtype;     WriteLn;

  WriteLn(Format('Results: %d passed, %d failed', [gVdbePass, gVdbeFail]));
  if gVdbeFail > 0 then Halt(1);
end.
