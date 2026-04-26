{$I passqlite3.inc}
program TestVdbeVtabExec;
{
  Phase 6.bis.3a gate test — VDBE wiring of vtab opcodes (read path).

  Exercises the OP_VBegin / OP_VCreate / OP_VDestroy dispatch arms in
  sqlite3VdbeExec (passqlite3vdbe.pas) which previously returned a generic
  "virtual table not supported" error.  OP_VBegin is the only one we can
  drive end-to-end without a registered module + schema, so it gets the
  most coverage here; VCreate/VDestroy are sanity-checked for the
  module-not-found error path.

    T1   OP_VBegin with a valid VTable — xBegin fires once, rc=DONE
    T2   OP_VBegin with p4.pVtab=nil  — no-op (matches sqlite3VtabBegin)
    T3   OP_VBegin twice in same xact — xBegin fires once total
    T4   OP_VBegin where xBegin returns SQLITE_BUSY — propagates

  OP_VCreate / OP_VDestroy require a populated schema (sqlite3FindTable
  walks db.aDb[iDb].pSchema), so end-to-end coverage of those two arms
  must wait for Phase 8.x's CREATE VIRTUAL TABLE pipeline.  The dispatch
  arms in vdbe.pas are still exercised — just via the surface API gate
  in TestVtab once that pipeline is wired.
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
  passqlite3codegen,
  passqlite3parser,
  passqlite3vtab;

var
  gPass: i32 = 0;
  gFail: i32 = 0;

procedure Check(name: string; cond: Boolean);
begin
  if cond then begin WriteLn('  PASS ', name); Inc(gPass); end
  else        begin WriteLn('  FAIL ', name); Inc(gFail); end;
end;

procedure ExpectEq(got, want: i32; name: string);
begin
  Check(Format('%s (got %d, want %d)', [name, got, want]), got = want);
end;

{ ------------------------------------------------------------------
  Mock vtab module — same shape as TestVtab T35..T50 (6.bis.1d gate).
  ------------------------------------------------------------------ }
var
  gBeginCount: i32 = 0;
  gNextBeginRc: i32 = SQLITE_OK;

function MockXBegin(p: PSqlite3Vtab): i32; cdecl;
begin
  Inc(gBeginCount);
  Result := gNextBeginRc;
end;

function MockXSync(p: PSqlite3Vtab): i32; cdecl;
begin Result := SQLITE_OK; end;

function MockXCommit(p: PSqlite3Vtab): i32; cdecl;
begin Result := SQLITE_OK; end;

function MockXRollback(p: PSqlite3Vtab): i32; cdecl;
begin Result := SQLITE_OK; end;

function MockXDisconnect(p: PSqlite3Vtab): i32; cdecl;
begin
  if p <> nil then FreeMem(p);
  Result := SQLITE_OK;
end;

function MockXDestroy(p: PSqlite3Vtab): i32; cdecl;
begin
  if p <> nil then FreeMem(p);
  Result := SQLITE_OK;
end;

{ Build a free-standing VTable + sqlite3_vtab + module record.  The
  Tsqlite3 must already be valid (allocator initialized).  Caller owns
  freeing the VTable + module records on teardown. }
function MakeMockVTable(db: PTsqlite3; out pMod: PSqlite3Module): PVTable;
var
  pVtbl: PVTable;
  pV   : PSqlite3Vtab;
begin
  GetMem(pMod, SizeOf(Tsqlite3_module));
  FillChar(pMod^, SizeOf(Tsqlite3_module), 0);
  pMod^.iVersion    := 2;
  pMod^.xBegin      := @MockXBegin;
  pMod^.xSync       := @MockXSync;
  pMod^.xCommit     := @MockXCommit;
  pMod^.xRollback   := @MockXRollback;
  pMod^.xDisconnect := @MockXDisconnect;
  pMod^.xDestroy    := @MockXDestroy;

  GetMem(pV, SizeOf(Tsqlite3_vtab));
  FillChar(pV^, SizeOf(Tsqlite3_vtab), 0);
  pV^.pModule := pMod;

  GetMem(pVtbl, SizeOf(TVTable));
  FillChar(pVtbl^, SizeOf(TVTable), 0);
  pVtbl^.db    := db;
  pVtbl^.pVtab := pV;
  pVtbl^.nRef  := 1;

  Result := pVtbl;
end;

procedure FreeMockVTable(pVTbl: PVTable; pMod: PSqlite3Module);
begin
  if pVTbl <> nil then begin
    if pVTbl^.pVtab <> nil then FreeMem(pVTbl^.pVtab);
    FreeMem(pVTbl);
  end;
  if pMod <> nil then FreeMem(pMod);
end;

{ ---- Minimal Vdbe constructor (mirrors TestVdbeArith) ---- }
const
  PARSE_SZ = 256;

function CreateMinVdbe(pDb: PTsqlite3; nMem: i32): PVdbe;
var
  pParse: Pointer;
  v:      PVdbe;
begin
  pParse := sqlite3DbMallocZero(pDb, PARSE_SZ);
  if pParse = nil then begin Result := nil; Exit; end;
  PPointer(pParse)^ := pDb;
  Pi32(PByte(pParse) + 156)^ := 250000000;
  v := sqlite3VdbeCreate(pParse);
  sqlite3DbFree(pDb, pParse);
  if v = nil then begin Result := nil; Exit; end;
  v^.nOp := 0;
  v^.aMem := PMem(sqlite3DbMallocZero(pDb, u64(nMem) * SizeOf(TMem)));
  v^.nMem := nMem;
  v^.apCsr := nil;
  v^.nCursor := 0;
  v^.eVdbeState := VDBE_RUN_STATE;
  v^.minWriteFileFormat := 4;
  v^.pc := 0;
  v^.cacheCtr := 1;
  Result := v;
end;

procedure InitDb(out db: Tsqlite3);
begin
  FillChar(db, SizeOf(db), 0);
  db.enc := SQLITE_UTF8;
  db.aLimit[0] := 1000000000;
  db.aLimit[5] := 250000000;
end;

{ ===== T1: OP_VBegin with valid VTable ===== }
procedure T1;
var
  db: Tsqlite3;
  v:  PVdbe;
  pMod: PSqlite3Module;
  pVTbl: PVTable;
  rc, addr: i32;
begin
  WriteLn('T1: OP_VBegin valid VTable → xBegin fires');
  InitDb(db);
  gBeginCount := 0;
  gNextBeginRc := SQLITE_OK;
  pVTbl := MakeMockVTable(@db, pMod);

  v := CreateMinVdbe(@db, 4);
  if v = nil then begin Check('T1 vdbe', False); Exit; end;
  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  addr := sqlite3VdbeAddOp4(v, OP_VBegin, 0, 0, 0, PAnsiChar(pVTbl), P4_VTAB);
  if addr < 0 then ;  { suppress "unused" }
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  v^.eVdbeState := VDBE_RUN_STATE;

  rc := sqlite3VdbeExec(v);
  ExpectEq(rc, SQLITE_DONE, 'T1 rc=DONE');
  ExpectEq(gBeginCount, 1, 'T1 xBegin fired once');
  ExpectEq(db.nVTrans, 1, 'T1 nVTrans=1');

  if db.aVTrans <> nil then begin
    sqlite3DbFree(@db, db.aVTrans);
    db.aVTrans := nil;
    db.nVTrans := 0;
  end;
  sqlite3VdbeDelete(v);
  FreeMockVTable(pVTbl, pMod);
end;

{ ===== T2: OP_VBegin with nil VTable ===== }
procedure T2;
var
  db: Tsqlite3;
  v:  PVdbe;
  rc: i32;
begin
  WriteLn('T2: OP_VBegin nil VTable → no-op');
  InitDb(db);
  gBeginCount := 0;
  v := CreateMinVdbe(@db, 4);
  if v = nil then begin Check('T2 vdbe', False); Exit; end;
  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp4(v, OP_VBegin, 0, 0, 0, nil, P4_VTAB);
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  v^.eVdbeState := VDBE_RUN_STATE;
  rc := sqlite3VdbeExec(v);
  ExpectEq(rc, SQLITE_DONE, 'T2 rc=DONE');
  ExpectEq(gBeginCount, 0, 'T2 xBegin not fired');
  sqlite3VdbeDelete(v);
end;

{ ===== T3: OP_VBegin twice — xBegin idempotent within a transaction ===== }
procedure T3;
var
  db: Tsqlite3;
  v:  PVdbe;
  pMod: PSqlite3Module;
  pVTbl: PVTable;
  rc: i32;
begin
  WriteLn('T3: OP_VBegin twice → xBegin fires once');
  InitDb(db);
  gBeginCount := 0;
  gNextBeginRc := SQLITE_OK;
  pVTbl := MakeMockVTable(@db, pMod);

  v := CreateMinVdbe(@db, 4);
  if v = nil then begin Check('T3 vdbe', False); Exit; end;
  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp4(v, OP_VBegin, 0, 0, 0, PAnsiChar(pVTbl), P4_VTAB);
  sqlite3VdbeAddOp4(v, OP_VBegin, 0, 0, 0, PAnsiChar(pVTbl), P4_VTAB);
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  v^.eVdbeState := VDBE_RUN_STATE;
  rc := sqlite3VdbeExec(v);
  ExpectEq(rc, SQLITE_DONE, 'T3 rc=DONE');
  ExpectEq(gBeginCount, 1, 'T3 xBegin fired exactly once');
  ExpectEq(db.nVTrans, 1, 'T3 nVTrans=1 (one slot)');

  if db.aVTrans <> nil then begin
    sqlite3DbFree(@db, db.aVTrans);
    db.aVTrans := nil;
    db.nVTrans := 0;
  end;
  sqlite3VdbeDelete(v);
  FreeMockVTable(pVTbl, pMod);
end;

{ ===== T4: xBegin returns SQLITE_BUSY — error propagates ===== }
procedure T4;
var
  db: Tsqlite3;
  v:  PVdbe;
  pMod: PSqlite3Module;
  pVTbl: PVTable;
  rc: i32;
begin
  WriteLn('T4: OP_VBegin with xBegin→BUSY → error propagates');
  InitDb(db);
  gBeginCount := 0;
  gNextBeginRc := SQLITE_BUSY;
  pVTbl := MakeMockVTable(@db, pMod);

  v := CreateMinVdbe(@db, 4);
  if v = nil then begin Check('T4 vdbe', False); Exit; end;
  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp4(v, OP_VBegin, 0, 0, 0, PAnsiChar(pVTbl), P4_VTAB);
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  v^.eVdbeState := VDBE_RUN_STATE;
  rc := sqlite3VdbeExec(v);
  { abort_due_to_error rewrites the function return to SQLITE_ERROR; the
    original module rc is preserved on v^.rc for sqlite3_errcode(). }
  ExpectEq(rc, SQLITE_ERROR, 'T4 rc=ERROR (return value rewritten)');
  ExpectEq(v^.rc, SQLITE_BUSY, 'T4 v^.rc=BUSY (original preserved)');
  ExpectEq(gBeginCount, 1, 'T4 xBegin fired');

  if db.aVTrans <> nil then begin
    sqlite3DbFree(@db, db.aVTrans);
    db.aVTrans := nil;
    db.nVTrans := 0;
  end;
  sqlite3VdbeDelete(v);
  FreeMockVTable(pVTbl, pMod);
end;

begin
  sqlite3OsInit;
  sqlite3PcacheInitialize;

  WriteLn('=== TestVdbeVtabExec — Phase 6.bis.3a gate ===');
  WriteLn;

  T1; WriteLn;
  T2; WriteLn;
  T3; WriteLn;
  T4; WriteLn;

  WriteLn(Format('Results: %d passed, %d failed', [gPass, gFail]));
  if gFail > 0 then Halt(1);
end.
