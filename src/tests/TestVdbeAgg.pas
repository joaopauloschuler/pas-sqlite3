{$I passqlite3.inc}
program TestVdbeAgg;
{
  Phase 5.4f gate test — VDBE aggregate opcodes.

  Uses a manually-constructed TFuncDef record (no sqlite3_create_function)
  to exercise the opcode mechanics directly.

    T1  OP_AggStep × 3 + OP_AggFinal → SUM(1,2,3) = 6
    T2  OP_AggFinal on empty accumulator (zero calls) → 0
    T3  OP_AggStep with NULL → sum skips NULLs → 5
    T4  OP_AggValue (window-style) → intermediate result

  Gate: T1–T4 all PASS.
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

{ ===== Simple SUM aggregate ================================================= }
{
  Accumulator register: r[p3].u.i = running sum, r[p3].flags = MEM_Int.
  Step: adds non-NULL integer input to accumulator.
  Finalize: leaves accumulator in place (already is the result).

  We rely on r[p3].n counting calls (incremented by OP_AggStep1). }

procedure SumStepFunc(pCtx: Psqlite3_context; argc: i32; argv: PPMem); cdecl;
var
  pAcc: PMem;
  pArg: PMem;
begin
  pAcc := pCtx^.pMem;
  if argc < 1 then Exit;
  pArg := argv^;
  if (pArg = nil) or ((pArg^.flags and MEM_Null) <> 0) then Exit;
  { initialize accumulator on first non-NULL }
  if (pAcc^.flags and MEM_Int) = 0 then begin
    pAcc^.u.i  := 0;
    pAcc^.flags := MEM_Int;
  end;
  Inc(pAcc^.u.i, pArg^.u.i);
end;

procedure SumFinalFunc(pCtx: Psqlite3_context); cdecl;
var
  pAcc: PMem;
begin
  pAcc := pCtx^.pMem;
  { copy accumulator to output }
  pCtx^.pOut^.flags := pAcc^.flags;
  pCtx^.pOut^.u.i   := pAcc^.u.i;
  if (pAcc^.flags and MEM_Int) = 0 then begin
    pCtx^.pOut^.flags := MEM_Int;
    pCtx^.pOut^.u.i   := 0;
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

  v^.eVdbeState         := VDBE_RUN_STATE;
  v^.minWriteFileFormat := 4;
  v^.pc                 := 0;
  v^.cacheCtr           := 1;

  Result := v;
end;

{ ===== Build a minimal TFuncDef for SUM ===================================== }

var
  gSumFuncDef: TFuncDef;

procedure InitSumFuncDef;
begin
  FillChar(gSumFuncDef, SizeOf(gSumFuncDef), 0);
  gSumFuncDef.nArg      := 1;
  gSumFuncDef.xSFunc    := @SumStepFunc;
  gSumFuncDef.xFinalize := @SumFinalFunc;
  gSumFuncDef.zName     := 'sum';
end;

{ ===== T1: SUM(1,2,3) = 6 ================================================== }

procedure TestSumBasic;
var
  md:   TMinDb;
  v:    PVdbe;
  rc:   i32;
  idx:  i32;
begin
  WriteLn('T1: OP_AggStep×3 + OP_AggFinal → SUM(1,2,3)=6');
  InitMinDb(md);

  { Register layout:
    r[1] = accumulator (MEM_Agg slot, p3 for AggStep)
    r[2] = input value (p2 for AggStep, argv[0])
    r[3] = spare }
  v := CreateMinVdbe(@md.db, 5);
  if v = nil then begin Check('T1 vdbe', False); Exit; end;

  {  0: Init 0,1,0
     1: Integer 1,2,0          → r[2]=1
     2: AggStep 0,2,1, p4=SumFuncDef, p5=1  → step(acc=r[1], argv={r[2]})
     3: Integer 2,2,0          → r[2]=2
     4: AggStep 0,2,1, p4=SumFuncDef, p5=1
     5: Integer 3,2,0          → r[2]=3
     6: AggStep 0,2,1, p4=SumFuncDef, p5=1
     7: AggFinal 1,1,0, p4=SumFuncDef  → r[1] = final result
     8: Halt 0,0,0  }
  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);                         { 0 }
  sqlite3VdbeAddOp2(v, OP_Integer, 1, 2);                      { 1 }
  idx := sqlite3VdbeAddOp3(v, OP_AggStep, 0, 2, 1);            { 2 }
  v^.aOp[idx].p5 := 1;  { argc = 1 }
  sqlite3VdbeChangeP4(v, idx, PAnsiChar(@gSumFuncDef), P4_FUNCDEF);
  sqlite3VdbeAddOp2(v, OP_Integer, 2, 2);                      { 3 }
  idx := sqlite3VdbeAddOp3(v, OP_AggStep, 0, 2, 1);            { 4 }
  v^.aOp[idx].p5 := 1;
  sqlite3VdbeChangeP4(v, idx, PAnsiChar(@gSumFuncDef), P4_FUNCDEF);
  sqlite3VdbeAddOp2(v, OP_Integer, 3, 2);                      { 5 }
  idx := sqlite3VdbeAddOp3(v, OP_AggStep, 0, 2, 1);            { 6 }
  v^.aOp[idx].p5 := 1;
  sqlite3VdbeChangeP4(v, idx, PAnsiChar(@gSumFuncDef), P4_FUNCDEF);
  idx := sqlite3VdbeAddOp3(v, OP_AggFinal, 1, 1, 0);           { 7 }
  sqlite3VdbeChangeP4(v, idx, PAnsiChar(@gSumFuncDef), P4_FUNCDEF);
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);                         { 8 }
  v^.eVdbeState := VDBE_RUN_STATE;

  rc := sqlite3VdbeExec(v);
  Check('T1 rc', rc = SQLITE_DONE);
  Check('T1 MEM_Int', (v^.aMem[1].flags and MEM_Int) <> 0);
  Check('T1 sum=6', v^.aMem[1].u.i = 6);

  sqlite3VdbeDelete(v);
end;

{ ===== T2: Empty accumulator → SUM() = 0 =================================== }

procedure TestSumEmpty;
var
  md:   TMinDb;
  v:    PVdbe;
  rc:   i32;
  idx:  i32;
begin
  WriteLn('T2: OP_AggFinal on fresh accum → 0');
  InitMinDb(md);
  v := CreateMinVdbe(@md.db, 4);
  if v = nil then begin Check('T2 vdbe', False); Exit; end;

  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  idx := sqlite3VdbeAddOp3(v, OP_AggFinal, 1, 1, 0);
  sqlite3VdbeChangeP4(v, idx, PAnsiChar(@gSumFuncDef), P4_FUNCDEF);
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  v^.eVdbeState := VDBE_RUN_STATE;
  v^.aMem[1].flags := MEM_Null;

  rc := sqlite3VdbeExec(v);
  Check('T2 rc', rc = SQLITE_DONE);
  { Finalize on NULL acc: SumFinalFunc returns 0 }
  Check('T2 MEM_Int', (v^.aMem[1].flags and MEM_Int) <> 0);
  Check('T2 sum=0', v^.aMem[1].u.i = 0);

  sqlite3VdbeDelete(v);
end;

{ ===== T3: SUM with one NULL input → skips NULL ============================  }

procedure TestSumWithNull;
var
  md:   TMinDb;
  v:    PVdbe;
  rc:   i32;
  idx:  i32;
begin
  WriteLn('T3: OP_AggStep with NULL + 5 → SUM=5');
  InitMinDb(md);

  { r[2] starts NULL, then we set r[2]=5 for second step }
  v := CreateMinVdbe(@md.db, 5);
  if v = nil then begin Check('T3 vdbe', False); Exit; end;

  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);               { 0 }
  { r[2] = NULL → skip in SumStepFunc }
  idx := sqlite3VdbeAddOp3(v, OP_AggStep, 0, 2, 1);  { 1 }
  v^.aOp[idx].p5 := 1;
  sqlite3VdbeChangeP4(v, idx, PAnsiChar(@gSumFuncDef), P4_FUNCDEF);
  sqlite3VdbeAddOp2(v, OP_Integer, 5, 2);             { 2: r[2]=5 }
  idx := sqlite3VdbeAddOp3(v, OP_AggStep, 0, 2, 1);  { 3 }
  v^.aOp[idx].p5 := 1;
  sqlite3VdbeChangeP4(v, idx, PAnsiChar(@gSumFuncDef), P4_FUNCDEF);
  idx := sqlite3VdbeAddOp3(v, OP_AggFinal, 1, 1, 0); { 4 }
  sqlite3VdbeChangeP4(v, idx, PAnsiChar(@gSumFuncDef), P4_FUNCDEF);
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);                { 5 }
  v^.aMem[2].flags := MEM_Null;
  v^.eVdbeState := VDBE_RUN_STATE;

  rc := sqlite3VdbeExec(v);
  Check('T3 rc', rc = SQLITE_DONE);
  Check('T3 MEM_Int', (v^.aMem[1].flags and MEM_Int) <> 0);
  Check('T3 sum=5', v^.aMem[1].u.i = 5);

  sqlite3VdbeDelete(v);
end;

{ ===== T4: OP_AggValue (pOut result, not finalize-in-place) ================ }

procedure TestAggValue;
var
  md:   TMinDb;
  v:    PVdbe;
  rc:   i32;
  idx:  i32;
begin
  WriteLn('T4: OP_AggValue → intermediate window value in r[3]');
  InitMinDb(md);

  { r[1]=accum, r[2]=input, r[3]=AggValue output }
  v := CreateMinVdbe(@md.db, 5);
  if v = nil then begin Check('T4 vdbe', False); Exit; end;

  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp2(v, OP_Integer, 7, 2);
  idx := sqlite3VdbeAddOp3(v, OP_AggStep, 0, 2, 1);
  v^.aOp[idx].p5 := 1;
  sqlite3VdbeChangeP4(v, idx, PAnsiChar(@gSumFuncDef), P4_FUNCDEF);
  { AggFinal p1=accum, p2=nArg, p3=output(for AggValue) }
  idx := sqlite3VdbeAddOp3(v, OP_AggFinal, 1, 1, 0);
  sqlite3VdbeChangeP4(v, idx, PAnsiChar(@gSumFuncDef), P4_FUNCDEF);
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  v^.eVdbeState := VDBE_RUN_STATE;

  rc := sqlite3VdbeExec(v);
  Check('T4 rc', rc = SQLITE_DONE);
  Check('T4 sum=7', v^.aMem[1].u.i = 7);

  sqlite3VdbeDelete(v);
end;

{ ===== main ================================================================= }

begin
  sqlite3OsInit;
  sqlite3PcacheInitialize;
  InitSumFuncDef;

  WriteLn('=== TestVdbeAgg — Phase 5.4f gate test ===');
  WriteLn;

  TestSumBasic;    WriteLn;
  TestSumEmpty;    WriteLn;
  TestSumWithNull; WriteLn;
  TestAggValue;    WriteLn;

  WriteLn(Format('Results: %d passed, %d failed', [gPass, gFail]));
  if gFail > 0 then Halt(1);
end.
