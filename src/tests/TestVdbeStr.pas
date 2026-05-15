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
program TestVdbeStr;
{
  Phase 5.4e gate test — VDBE string/blob opcodes.

    T1  OP_String (direct): store static string into register
    T2  OP_String8 (first-run): compute length, convert to OP_String
    T3  OP_Concat: 'Hello' || ' World' = 'Hello World'
    T4  OP_Concat: NULL || 'x' = NULL
    T5  OP_Concat: integer 42 || ' items' (stringify then concat)
    T6  OP_Blob: store static blob, check length and content

  Gate: T1–T6 all PASS.
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

{ ===== T1: OP_String (direct) ============================================== }

procedure TestStringDirect;
var
  md:   TVdbeMinDb;
  v:    PVdbe;
  rc:   i32;
  pOp:  PVdbeOp;
const
  SLiteral: PAnsiChar = 'hello';
begin
  WriteLn('T1: OP_String direct → r[1]="hello"');
  VdbeInitMinDb(md, nil);
  v := VdbeCreateMinRun(@md.db, 3);
  if v = nil then begin VdbeCheck('T1 vdbe', False); Exit; end;

  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  { add OP_String: p1=5(len), p2=1(out), p4.z=SLiteral }
  sqlite3VdbeAddOp4(v, OP_String, 5, 1, 0, SLiteral, P4_STATIC);
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  v^.eVdbeState := VDBE_RUN_STATE;

  rc := sqlite3VdbeExec(v);
  VdbeCheck('T1 rc', rc = SQLITE_DONE);
  VdbeCheck('T1 MEM_Str', (v^.aMem[1].flags and MEM_Str) <> 0);
  VdbeCheck('T1 n=5', v^.aMem[1].n = 5);
  VdbeCheck('T1 content', StrComp(v^.aMem[1].z, SLiteral) = 0);

  sqlite3VdbeDelete(v);
end;

{ ===== T2: OP_String8 (first-run length computation) ======================= }

procedure TestString8;
var
  md:   TVdbeMinDb;
  v:    PVdbe;
  rc:   i32;
const
  SHello: PAnsiChar = 'world!';
begin
  WriteLn('T2: OP_String8 → computes len → r[1]="world!"');
  VdbeInitMinDb(md, nil);
  v := VdbeCreateMinRun(@md.db, 3);
  if v = nil then begin VdbeCheck('T2 vdbe', False); Exit; end;

  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp4(v, OP_String8, 0, 1, 0, SHello, P4_STATIC);
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  v^.eVdbeState := VDBE_RUN_STATE;

  rc := sqlite3VdbeExec(v);
  VdbeCheck('T2 rc', rc = SQLITE_DONE);
  VdbeCheck('T2 MEM_Str', (v^.aMem[1].flags and MEM_Str) <> 0);
  VdbeCheck('T2 n=6', v^.aMem[1].n = 6);
  VdbeCheck('T2 content', StrComp(v^.aMem[1].z, SHello) = 0);

  sqlite3VdbeDelete(v);
end;

{ ===== T3: OP_Concat 'Hello' || ' World' =================================== }

procedure TestConcat;
var
  md:   TVdbeMinDb;
  v:    PVdbe;
  rc:   i32;
const
  SA: PAnsiChar = 'Hello';
  SB: PAnsiChar = ' World';
begin
  WriteLn('T3: OP_Concat "Hello" || " World" = "Hello World"');
  VdbeInitMinDb(md, nil);

  { r[1]=' World'(right=P1), r[2]='Hello'(left=P2), r[3]=concat(out=P3) }
  v := VdbeCreateMinRun(@md.db, 5);
  if v = nil then begin VdbeCheck('T3 vdbe', False); Exit; end;

  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp4(v, OP_String, 5, 1, 0, SA, P4_STATIC);   { r[1]="Hello" }
  sqlite3VdbeAddOp4(v, OP_String, 6, 2, 0, SB, P4_STATIC);   { r[2]=" World" }
  sqlite3VdbeAddOp3(v, OP_Concat, 2, 1, 3);  { r[3] = r[1] || r[2] }
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  v^.eVdbeState := VDBE_RUN_STATE;

  rc := sqlite3VdbeExec(v);
  VdbeCheck('T3 rc', rc = SQLITE_DONE);
  VdbeCheck('T3 MEM_Str', (v^.aMem[3].flags and MEM_Str) <> 0);
  VdbeCheck('T3 n=11', v^.aMem[3].n = 11);
  VdbeCheck('T3 content', StrLComp(v^.aMem[3].z, 'Hello World', 11) = 0);

  sqlite3VdbeDelete(v);
end;

{ ===== T4: OP_Concat NULL || 'x' = NULL ==================================== }

procedure TestConcatNull;
var
  md: TVdbeMinDb;
  v:  PVdbe;
  rc: i32;
const
  SX: PAnsiChar = 'x';
begin
  WriteLn('T4: OP_Concat NULL || "x" = NULL');
  VdbeInitMinDb(md, nil);
  v := VdbeCreateMinRun(@md.db, 4);
  if v = nil then begin VdbeCheck('T4 vdbe', False); Exit; end;

  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp4(v, OP_String, 1, 2, 0, SX, P4_STATIC);  { r[2]="x" }
  { r[1] stays NULL (zero-init MEM_Null) }
  sqlite3VdbeAddOp3(v, OP_Concat, 2, 1, 3);  { r[3] = r[1](NULL) || r[2] }
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  v^.aMem[1].flags := MEM_Null;
  v^.eVdbeState := VDBE_RUN_STATE;

  rc := sqlite3VdbeExec(v);
  VdbeCheck('T4 rc', rc = SQLITE_DONE);
  VdbeCheck('T4 NULL concat=NULL', (v^.aMem[3].flags and MEM_Null) <> 0);

  sqlite3VdbeDelete(v);
end;

{ ===== T5: OP_Concat with stringify: 42 || ' items' ======================== }

procedure TestConcatStringify;
var
  md:   TVdbeMinDb;
  v:    PVdbe;
  rc:   i32;
const
  SItems: PAnsiChar = ' items';
begin
  WriteLn('T5: OP_Concat 42(int) || " items" → "42 items"');
  VdbeInitMinDb(md, nil);
  { r[1]=42(int), r[2]=' items', r[3]=result }
  v := VdbeCreateMinRun(@md.db, 5);
  if v = nil then begin VdbeCheck('T5 vdbe', False); Exit; end;

  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp2(v, OP_Integer, 42, 1);                        { r[1]=42 int }
  sqlite3VdbeAddOp4(v, OP_String, 6, 2, 0, SItems, P4_STATIC);   { r[2]=" items" }
  sqlite3VdbeAddOp3(v, OP_Concat, 2, 1, 3);  { r[3] = r[1](42) || r[2] }
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  v^.eVdbeState := VDBE_RUN_STATE;

  rc := sqlite3VdbeExec(v);
  VdbeCheck('T5 rc', rc = SQLITE_DONE);
  VdbeCheck('T5 MEM_Str', (v^.aMem[3].flags and MEM_Str) <> 0);
  VdbeCheck('T5 n=8', v^.aMem[3].n = 8);
  VdbeCheck('T5 content', StrLComp(v^.aMem[3].z, '42 items', 8) = 0);

  sqlite3VdbeDelete(v);
end;

{ ===== T6: OP_Blob ========================================================= }

procedure TestBlob;
var
  md:   TVdbeMinDb;
  v:    PVdbe;
  rc:   i32;
const
  BlobData: array[0..3] of Byte = ($DE, $AD, $BE, $EF);
begin
  WriteLn('T6: OP_Blob 4-byte blob → r[1]');
  VdbeInitMinDb(md, nil);
  v := VdbeCreateMinRun(@md.db, 3);
  if v = nil then begin VdbeCheck('T6 vdbe', False); Exit; end;

  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp4(v, OP_Blob, 4, 1, 0, PAnsiChar(@BlobData[0]), P4_STATIC);
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  v^.eVdbeState := VDBE_RUN_STATE;

  rc := sqlite3VdbeExec(v);
  VdbeCheck('T6 rc', rc = SQLITE_DONE);
  VdbeCheck('T6 MEM_Blob', (v^.aMem[1].flags and MEM_Blob) <> 0);
  VdbeCheck('T6 n=4', v^.aMem[1].n = 4);
  VdbeCheck('T6 byte0=$DE', PByte(v^.aMem[1].z)[0] = $DE);
  VdbeCheck('T6 byte3=$EF', PByte(v^.aMem[1].z)[3] = $EF);

  sqlite3VdbeDelete(v);
end;

{ ===== main ================================================================= }

begin
  sqlite3OsInit;
  sqlite3PcacheInitialize;

  WriteLn('=== TestVdbeStr — Phase 5.4e gate test ===');
  WriteLn;

  TestStringDirect;  WriteLn;
  TestString8;       WriteLn;
  TestConcat;        WriteLn;
  TestConcatNull;    WriteLn;
  TestConcatStringify; WriteLn;
  TestBlob;          WriteLn;

  WriteLn(Format('Results: %d passed, %d failed', [gVdbePass, gVdbeFail]));
  if gVdbeFail > 0 then Halt(1);
end.
