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

{ ------------------------------------------------------------------
  Phase 6.bis.3b — read-path mock cursor + module callbacks.
  Mock vtab serves a fixed 3-row table; OP_VOpen / VFilter / VColumn /
  VNext / Rowid / VRename / VUpdate are exercised via T5..T11.
  ------------------------------------------------------------------ }
type
  TMockVtabCursor = record
    base : Tsqlite3_vtab_cursor;  { must be first }
    iRow : i64;                   { 0..2 = row index, 3 = EOF }
  end;
  PMockVtabCursor = ^TMockVtabCursor;

var
  gOpenCount:    i32 = 0;
  gCloseCount:   i32 = 0;
  gFilterCount:  i32 = 0;
  gNextCount:    i32 = 0;
  gColumnCount:  i32 = 0;
  gRowidCount:   i32 = 0;
  gRenameCount:  i32 = 0;
  gUpdateCount:  i32 = 0;
  gLastFilterIdx: i32 = -1;
  gLastRenameTo: AnsiString = '';
  gLastUpdateNArg: i32 = 0;

function MockXOpen(pVtab: PSqlite3Vtab; ppCursor: PPSqlite3VtabCursor): i32; cdecl;
var pCur: PMockVtabCursor;
begin
  Inc(gOpenCount);
  GetMem(pCur, SizeOf(TMockVtabCursor));
  FillChar(pCur^, SizeOf(TMockVtabCursor), 0);
  ppCursor^ := PSqlite3VtabCursor(pCur);
  Result := SQLITE_OK;
end;

function MockXClose(pCur: PSqlite3VtabCursor): i32; cdecl;
begin
  Inc(gCloseCount);
  if pCur <> nil then FreeMem(pCur);
  Result := SQLITE_OK;
end;

function MockXFilter(pCur: PSqlite3VtabCursor; idxNum: i32; idxStr: PAnsiChar;
                     argc: i32; argv: PPMem): i32; cdecl;
begin
  Inc(gFilterCount);
  gLastFilterIdx := idxNum;
  PMockVtabCursor(pCur)^.iRow := 0;
  Result := SQLITE_OK;
end;

function MockXNext(pCur: PSqlite3VtabCursor): i32; cdecl;
begin
  Inc(gNextCount);
  Inc(PMockVtabCursor(pCur)^.iRow);
  Result := SQLITE_OK;
end;

function MockXEof(pCur: PSqlite3VtabCursor): i32; cdecl;
begin
  if PMockVtabCursor(pCur)^.iRow >= 3 then Result := 1 else Result := 0;
end;

function MockXColumn(pCur: PSqlite3VtabCursor; pCtx: Psqlite3_context;
                     iCol: i32): i32; cdecl;
begin
  Inc(gColumnCount);
  { Return iRow*100 + iCol — easy to verify }
  sqlite3_result_int64(pCtx, PMockVtabCursor(pCur)^.iRow * 100 + iCol);
  Result := SQLITE_OK;
end;

function MockXRowid(pCur: PSqlite3VtabCursor; pRowid: Pi64): i32; cdecl;
begin
  Inc(gRowidCount);
  pRowid^ := PMockVtabCursor(pCur)^.iRow + 1000;
  Result := SQLITE_OK;
end;

function MockXRename(pVtab: PSqlite3Vtab; zNew: PAnsiChar): i32; cdecl;
begin
  Inc(gRenameCount);
  if zNew <> nil then gLastRenameTo := AnsiString(zNew) else gLastRenameTo := '';
  Result := SQLITE_OK;
end;

function MockXUpdate(pVtab: PSqlite3Vtab; argc: i32; argv: PPMem;
                     pRowid: Pi64): i32; cdecl;
begin
  Inc(gUpdateCount);
  gLastUpdateNArg := argc;
  pRowid^ := 9999;
  Result := SQLITE_OK;
end;

{ Build a richer mock module with the read-path callbacks wired up. }
function MakeReadVTable(db: PTsqlite3; out pMod: PSqlite3Module): PVTable;
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
  pMod^.xOpen       := @MockXOpen;
  pMod^.xClose      := @MockXClose;
  pMod^.xFilter     := @MockXFilter;
  pMod^.xNext       := @MockXNext;
  pMod^.xEof        := @MockXEof;
  pMod^.xColumn     := @MockXColumn;
  pMod^.xRowid      := @MockXRowid;
  pMod^.xRename     := @MockXRename;
  pMod^.xUpdate     := @MockXUpdate;

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

procedure ResetCounts;
begin
  gOpenCount := 0; gCloseCount := 0; gFilterCount := 0; gNextCount := 0;
  gColumnCount := 0; gRowidCount := 0; gRenameCount := 0; gUpdateCount := 0;
  gLastFilterIdx := -1; gLastRenameTo := ''; gLastUpdateNArg := 0;
end;

{ Helper: build a Vdbe with N cursor slots. }
function CreateMinVdbeC(pDb: PTsqlite3; nMem, nCursor: i32): PVdbe;
var v: PVdbe;
begin
  v := CreateMinVdbe(pDb, nMem);
  if v = nil then begin Result := nil; Exit; end;
  if nCursor > 0 then begin
    v^.apCsr := PPVdbeCursor(sqlite3DbMallocZero(pDb,
                  u64(nCursor) * SizeOf(PVdbeCursor)));
    v^.nCursor := nCursor;
  end;
  Result := v;
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

{ ===== T5: OP_VOpen — xOpen fires, allocateCursor populates slot ===== }
procedure T5;
var
  db: Tsqlite3;
  v:  PVdbe;
  pMod: PSqlite3Module;
  pVTbl: PVTable;
  rc: i32;
begin
  WriteLn('T5: OP_VOpen → xOpen fires, vtab cursor allocated');
  InitDb(db);
  ResetCounts;
  pVTbl := MakeReadVTable(@db, pMod);
  v := CreateMinVdbeC(@db, 4, 1);
  if v = nil then begin Check('T5 vdbe', False); Exit; end;
  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp4(v, OP_VOpen, 0, 0, 0, PAnsiChar(pVTbl), P4_VTAB);
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  v^.eVdbeState := VDBE_RUN_STATE;
  rc := sqlite3VdbeExec(v);
  ExpectEq(rc, SQLITE_DONE, 'T5 rc=DONE');
  ExpectEq(gOpenCount, 1, 'T5 xOpen fired');
  { After OP_Halt, sqlite3VdbeHalt's closeAllCursors-equivalent loop fires
    the CURTYPE_VTAB cleanup branch (xClose + nRef--) and nils out the slot,
    so the cursor pointer is no longer valid post-exec — only the side-
    effect counters and the slot-cleared invariant can be asserted. }
  Check('T5 vtab cursor slot cleared by VdbeHalt', v^.apCsr[0] = nil);
  ExpectEq(gCloseCount, 1, 'T5 xClose fired via VdbeHalt close-all-cursors');
  ExpectEq(pVTbl^.pVtab^.nRef, 0, 'T5 nRef decremented to 0 after Halt');
  sqlite3VdbeDelete(v);
  FreeMockVTable(pVTbl, pMod);
end;

{ ===== T6: OP_VOpen idempotent — second OP_VOpen on same cursor ===== }
procedure T6;
var
  db: Tsqlite3;
  v:  PVdbe;
  pMod: PSqlite3Module;
  pVTbl: PVTable;
  rc: i32;
begin
  WriteLn('T6: OP_VOpen twice on same vtab → xOpen fires once');
  InitDb(db);
  ResetCounts;
  pVTbl := MakeReadVTable(@db, pMod);
  v := CreateMinVdbeC(@db, 4, 1);
  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp4(v, OP_VOpen, 0, 0, 0, PAnsiChar(pVTbl), P4_VTAB);
  sqlite3VdbeAddOp4(v, OP_VOpen, 0, 0, 0, PAnsiChar(pVTbl), P4_VTAB);
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  v^.eVdbeState := VDBE_RUN_STATE;
  rc := sqlite3VdbeExec(v);
  ExpectEq(rc, SQLITE_DONE, 'T6 rc=DONE');
  ExpectEq(gOpenCount, 1, 'T6 xOpen fired exactly once');
  sqlite3VdbeDelete(v);
  FreeMockVTable(pVTbl, pMod);
end;

{ ===== T7: OP_VFilter + xEof + OP_VNext walk through 3 rows ===== }
procedure T7;
var
  db: Tsqlite3;
  v:  PVdbe;
  pMod: PSqlite3Module;
  pVTbl: PVTable;
  rc: i32;
  addrFilter, addrNext, addrHalt: i32;
begin
  WriteLn('T7: OP_VFilter + OP_VNext walk 3-row result');
  InitDb(db);
  ResetCounts;
  pVTbl := MakeReadVTable(@db, pMod);
  v := CreateMinVdbeC(@db, 8, 1);
  { aMem[2] = idxNum (Int), aMem[3] = argc (Int 0) — VFilter reads p3 / p3+1 }
  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp2(v, OP_Integer, 0, 2);   { reg2 = idxNum=0 }
  sqlite3VdbeAddOp2(v, OP_Integer, 0, 3);   { reg3 = argc=0 }
  sqlite3VdbeAddOp4(v, OP_VOpen,   0, 0, 0, PAnsiChar(pVTbl), P4_VTAB);
  addrFilter := sqlite3VdbeAddOp4(v, OP_VFilter, 0, 0, 2, nil, P4_NOTUSED);
  if addrFilter < 0 then ;
  addrNext := sqlite3VdbeAddOp2(v, OP_VNext,  0, 0);
  addrHalt := sqlite3VdbeAddOp2(v, OP_Halt,   0, 0);
  { Patch: VFilter jumps to addrHalt on empty; VNext jumps back to addrNext on data }
  v^.aOp[addrFilter].p2 := addrHalt;
  v^.aOp[addrNext].p2   := addrNext;  { stay in loop while xEof=0 }
  v^.eVdbeState := VDBE_RUN_STATE;
  rc := sqlite3VdbeExec(v);
  ExpectEq(rc, SQLITE_DONE, 'T7 rc=DONE');
  ExpectEq(gFilterCount, 1, 'T7 xFilter fired once');
  ExpectEq(gNextCount, 3, 'T7 xNext fired 3 times (rows 1→2→3=eof)');
  sqlite3VdbeDelete(v);
  FreeMockVTable(pVTbl, pMod);
end;

{ ===== T8: OP_VColumn — xColumn populates result register ===== }
procedure T8;
var
  db: Tsqlite3;
  v:  PVdbe;
  pMod: PSqlite3Module;
  pVTbl: PVTable;
  rc: i32;
begin
  WriteLn('T8: OP_VColumn → xColumn fills register');
  InitDb(db);
  ResetCounts;
  pVTbl := MakeReadVTable(@db, pMod);
  v := CreateMinVdbeC(@db, 8, 1);
  sqlite3VdbeAddOp2(v, OP_Init,    0, 1);
  sqlite3VdbeAddOp2(v, OP_Integer, 0, 2);   { idxNum=0 }
  sqlite3VdbeAddOp2(v, OP_Integer, 0, 3);   { argc=0 }
  sqlite3VdbeAddOp4(v, OP_VOpen,   0, 0, 0, PAnsiChar(pVTbl), P4_VTAB);
  sqlite3VdbeAddOp4(v, OP_VFilter, 0, 99, 2, nil, P4_NOTUSED);  { p2 patched below }
  sqlite3VdbeAddOp3(v, OP_VColumn, 0, 7, 5);  { col 7 → reg 5 }
  sqlite3VdbeAddOp2(v, OP_Halt,    0, 0);
  v^.aOp[4].p2 := v^.nOp - 1;  { VFilter empty → halt }
  v^.eVdbeState := VDBE_RUN_STATE;
  rc := sqlite3VdbeExec(v);
  ExpectEq(rc, SQLITE_DONE, 'T8 rc=DONE');
  ExpectEq(gColumnCount, 1, 'T8 xColumn fired once');
  ExpectEq(i32(v^.aMem[5].u.i), 7, 'T8 reg5 = iRow*100 + iCol = 0*100+7');
  sqlite3VdbeDelete(v);
  FreeMockVTable(pVTbl, pMod);
end;

{ ===== T9: OP_Rowid CURTYPE_VTAB → xRowid ===== }
procedure T9;
var
  db: Tsqlite3;
  v:  PVdbe;
  pMod: PSqlite3Module;
  pVTbl: PVTable;
  rc: i32;
begin
  WriteLn('T9: OP_Rowid on vtab cursor → xRowid');
  InitDb(db);
  ResetCounts;
  pVTbl := MakeReadVTable(@db, pMod);
  v := CreateMinVdbeC(@db, 8, 1);
  sqlite3VdbeAddOp2(v, OP_Init,    0, 1);
  sqlite3VdbeAddOp2(v, OP_Integer, 0, 2);
  sqlite3VdbeAddOp2(v, OP_Integer, 0, 3);
  sqlite3VdbeAddOp4(v, OP_VOpen,   0, 0, 0, PAnsiChar(pVTbl), P4_VTAB);
  sqlite3VdbeAddOp4(v, OP_VFilter, 0, 99, 2, nil, P4_NOTUSED);
  sqlite3VdbeAddOp2(v, OP_Rowid,   0, 6);
  sqlite3VdbeAddOp2(v, OP_Halt,    0, 0);
  v^.aOp[4].p2 := v^.nOp - 1;
  v^.eVdbeState := VDBE_RUN_STATE;
  rc := sqlite3VdbeExec(v);
  ExpectEq(rc, SQLITE_DONE, 'T9 rc=DONE');
  ExpectEq(gRowidCount, 1, 'T9 xRowid fired');
  ExpectEq(i32(v^.aMem[6].u.i), 1000, 'T9 reg6 = iRow+1000 = 0+1000');
  sqlite3VdbeDelete(v);
  FreeMockVTable(pVTbl, pMod);
end;

{ ===== T10: OP_VRename — xRename fires with name from register ===== }
procedure T10;
var
  db: Tsqlite3;
  v:  PVdbe;
  pMod: PSqlite3Module;
  pVTbl: PVTable;
  rc: i32;
begin
  WriteLn('T10: OP_VRename → xRename fires with new name');
  InitDb(db);
  ResetCounts;
  pVTbl := MakeReadVTable(@db, pMod);
  v := CreateMinVdbeC(@db, 4, 0);
  sqlite3VdbeAddOp2(v, OP_Init,    0, 1);
  sqlite3VdbeAddOp4(v, OP_String8, 0, 1, 0, PAnsiChar('newName'), P4_STATIC);
  sqlite3VdbeAddOp4(v, OP_VRename, 1, 0, 0, PAnsiChar(pVTbl), P4_VTAB);
  sqlite3VdbeAddOp2(v, OP_Halt,    0, 0);
  v^.eVdbeState := VDBE_RUN_STATE;
  rc := sqlite3VdbeExec(v);
  ExpectEq(rc, SQLITE_DONE, 'T10 rc=DONE');
  ExpectEq(gRenameCount, 1, 'T10 xRename fired');
  Check('T10 rename arg = newName', gLastRenameTo = 'newName');
  sqlite3VdbeDelete(v);
  FreeMockVTable(pVTbl, pMod);
end;

{ ===== T11: OP_VUpdate — xUpdate fires with argc args ===== }
procedure T11;
var
  db: Tsqlite3;
  v:  PVdbe;
  pMod: PSqlite3Module;
  pVTbl: PVTable;
  rc: i32;
begin
  WriteLn('T11: OP_VUpdate → xUpdate fires');
  InitDb(db);
  ResetCounts;
  pVTbl := MakeReadVTable(@db, pMod);
  v := CreateMinVdbeC(@db, 8, 0);
  { p1=1 (set lastRowid), p2=3 args, p3=2 (start register), p5=OE_Abort }
  sqlite3VdbeAddOp2(v, OP_Init,    0, 1);
  sqlite3VdbeAddOp2(v, OP_Null,    0, 2);    { argv[0]=NULL (no delete) }
  sqlite3VdbeAddOp2(v, OP_Null,    0, 3);    { argv[1]=NULL (auto rowid) }
  sqlite3VdbeAddOp2(v, OP_Integer, 42, 4);   { argv[2]=42 }
  sqlite3VdbeAddOp4(v, OP_VUpdate, 1, 3, 2, PAnsiChar(pVTbl), P4_VTAB);
  v^.aOp[v^.nOp - 1].p5 := OE_Abort;
  sqlite3VdbeAddOp2(v, OP_Halt,    0, 0);
  v^.eVdbeState := VDBE_RUN_STATE;
  rc := sqlite3VdbeExec(v);
  ExpectEq(rc, SQLITE_DONE, 'T11 rc=DONE');
  ExpectEq(gUpdateCount, 1, 'T11 xUpdate fired');
  ExpectEq(gLastUpdateNArg, 3, 'T11 argc=3');
  ExpectEq(i64(db.lastRowid), 9999, 'T11 lastRowid set');
  sqlite3VdbeDelete(v);
  FreeMockVTable(pVTbl, pMod);
end;

{ ===== T12: OP_VCheck — xIntegrity fires; error string lands in register ===== }
{ Phase 6.bis.3d gate.  Builds a fake Table blob with eTabType=VTAB,
  zName, and u.vtab.p pointing at a VTable + module whose xIntegrity
  toggles between (a) success+no-error, (b) success+error string, and
  (c) error rc. }

const
  TAB_BLOB_SZ        = 256;
  TEST_TAB_OFF_eTabType = 63;
  TEST_TAB_OFF_uVtab    = 64;
  TEST_VTAB_OFF_p       = 16;

var
  gIntegrityCount: i32 = 0;
  gLastIntegrityFlags: i32 = 0;
  gLastIntegrityZSchema: AnsiString = '';
  gLastIntegrityZTab: AnsiString = '';
  gNextIntegrityRc: i32 = SQLITE_OK;
  gNextIntegrityErr: AnsiString = '';

function MockXIntegrity(pVtab: PSqlite3Vtab; zSchema, zTabName: PAnsiChar;
                        mFlags: i32; pzErr: PPAnsiChar): i32; cdecl;
var n: i32; z: PAnsiChar;
begin
  Inc(gIntegrityCount);
  gLastIntegrityFlags := mFlags;
  if zSchema <> nil then gLastIntegrityZSchema := AnsiString(zSchema)
  else                   gLastIntegrityZSchema := '';
  if zTabName <> nil then gLastIntegrityZTab := AnsiString(zTabName)
  else                    gLastIntegrityZTab := '';
  if (gNextIntegrityErr <> '') and (pzErr <> nil) then begin
    n := Length(gNextIntegrityErr);
    z := PAnsiChar(sqlite3_malloc(n + 1));
    Move(PAnsiChar(gNextIntegrityErr)^, z^, n);
    (z + n)^ := #0;
    pzErr^ := z;
  end;
  Result := gNextIntegrityRc;
end;

function MakeIntegrityVTable(db: PTsqlite3; out pMod: PSqlite3Module;
                             out pTabBlob: Pointer): PVTable;
var
  pVtbl: PVTable;
  pV   : PSqlite3Vtab;
  pp   : PPointer;
begin
  GetMem(pMod, SizeOf(Tsqlite3_module));
  FillChar(pMod^, SizeOf(Tsqlite3_module), 0);
  pMod^.iVersion    := 4;
  pMod^.xDisconnect := @MockXDisconnect;
  pMod^.xDestroy    := @MockXDestroy;
  pMod^.xIntegrity  := @MockXIntegrity;

  GetMem(pV, SizeOf(Tsqlite3_vtab));
  FillChar(pV^, SizeOf(Tsqlite3_vtab), 0);
  pV^.pModule := pMod;

  GetMem(pVtbl, SizeOf(TVTable));
  FillChar(pVtbl^, SizeOf(TVTable), 0);
  pVtbl^.db    := db;
  pVtbl^.pVtab := pV;
  pVtbl^.nRef  := 1;

  { Synthetic Table*: zName at offset 0, eTabType at 63, u.vtab.p at 80 }
  GetMem(pTabBlob, TAB_BLOB_SZ);
  FillChar(pTabBlob^, TAB_BLOB_SZ, 0);
  PPAnsiChar(pTabBlob)^ := PAnsiChar('myvtab');
  (PByte(pTabBlob) + TEST_TAB_OFF_eTabType)^ := 1;  { TABTYP_VTAB }
  pp := PPointer(PByte(pTabBlob) + TEST_TAB_OFF_uVtab + TEST_VTAB_OFF_p);
  pp^ := pVtbl;
  Result := pVtbl;
end;

procedure FreeIntegrityVTable(pVTbl: PVTable; pMod: PSqlite3Module;
                              pTabBlob: Pointer);
begin
  if pVTbl <> nil then begin
    if pVTbl^.pVtab <> nil then FreeMem(pVTbl^.pVtab);
    FreeMem(pVTbl);
  end;
  if pMod <> nil then FreeMem(pMod);
  if pTabBlob <> nil then FreeMem(pTabBlob);
end;

procedure T12;
var
  db: Tsqlite3;
  v:  PVdbe;
  pMod: PSqlite3Module;
  pVTbl: PVTable;
  pTabBlob: Pointer;
  aDbArr: array[0..0] of TDb;
  rc: i32;
begin
  WriteLn('T12: OP_VCheck → xIntegrity fires; clean + dirty + rc paths');
  InitDb(db);
  FillChar(aDbArr, SizeOf(aDbArr), 0);
  aDbArr[0].zDbSName := PAnsiChar('main');
  db.aDb := @aDbArr[0];
  db.nDb := 1;

  pVTbl := MakeIntegrityVTable(@db, pMod, pTabBlob);

  { ----- (a) clean run: rc=OK, no error string → register stays NULL ----- }
  gIntegrityCount := 0;
  gNextIntegrityRc := SQLITE_OK;
  gNextIntegrityErr := '';
  v := CreateMinVdbe(@db, 4);
  if v = nil then begin Check('T12 vdbe', False); Exit; end;
  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp4(v, OP_VCheck, 0, 2, 7, PAnsiChar(pTabBlob), P4_TABLEREF);
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  v^.eVdbeState := VDBE_RUN_STATE;
  rc := sqlite3VdbeExec(v);
  ExpectEq(rc, SQLITE_DONE, 'T12a rc=DONE');
  ExpectEq(gIntegrityCount, 1, 'T12a xIntegrity fired');
  ExpectEq(gLastIntegrityFlags, 7, 'T12a flags=p3');
  Check('T12a zSchema=main', gLastIntegrityZSchema = 'main');
  Check('T12a zTabName=myvtab', gLastIntegrityZTab = 'myvtab');
  Check('T12a reg2 is NULL on clean run', (v^.aMem[2].flags and MEM_Null) <> 0);
  sqlite3VdbeDelete(v);

  { ----- (b) dirty run: rc=OK, but xIntegrity emits an error string ----- }
  gIntegrityCount := 0;
  gNextIntegrityRc := SQLITE_OK;
  gNextIntegrityErr := 'corruption detected';
  v := CreateMinVdbe(@db, 4);
  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp4(v, OP_VCheck, 0, 2, 0, PAnsiChar(pTabBlob), P4_TABLEREF);
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  v^.eVdbeState := VDBE_RUN_STATE;
  rc := sqlite3VdbeExec(v);
  ExpectEq(rc, SQLITE_DONE, 'T12b rc=DONE');
  ExpectEq(gIntegrityCount, 1, 'T12b xIntegrity fired');
  Check('T12b reg2 is text', (v^.aMem[2].flags and MEM_Str) <> 0);
  Check('T12b reg2 = error string',
        StrComp(v^.aMem[2].z, PAnsiChar('corruption detected')) = 0);
  sqlite3VdbeDelete(v);

  { ----- (c) error rc: xIntegrity returns nonzero → abort ----- }
  gIntegrityCount := 0;
  gNextIntegrityRc := SQLITE_CORRUPT;
  gNextIntegrityErr := 'bad page';
  v := CreateMinVdbe(@db, 4);
  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp4(v, OP_VCheck, 0, 2, 0, PAnsiChar(pTabBlob), P4_TABLEREF);
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  v^.eVdbeState := VDBE_RUN_STATE;
  rc := sqlite3VdbeExec(v);
  ExpectEq(rc, SQLITE_ERROR, 'T12c rc=ERROR (return rewritten)');
  ExpectEq(v^.rc, SQLITE_CORRUPT, 'T12c v^.rc=CORRUPT (preserved)');
  ExpectEq(gIntegrityCount, 1, 'T12c xIntegrity fired');
  sqlite3VdbeDelete(v);

  { ----- (d) Table* with no attached VTable → register stays NULL ----- }
  PPointer(PByte(pTabBlob) + TEST_TAB_OFF_uVtab + TEST_VTAB_OFF_p)^ := nil;
  gIntegrityCount := 0;
  v := CreateMinVdbe(@db, 4);
  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp4(v, OP_VCheck, 0, 2, 0, PAnsiChar(pTabBlob), P4_TABLEREF);
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  v^.eVdbeState := VDBE_RUN_STATE;
  rc := sqlite3VdbeExec(v);
  ExpectEq(rc, SQLITE_DONE, 'T12d rc=DONE on no-VTable');
  ExpectEq(gIntegrityCount, 0, 'T12d xIntegrity NOT fired');
  Check('T12d reg2 is NULL', (v^.aMem[2].flags and MEM_Null) <> 0);
  sqlite3VdbeDelete(v);

  FreeIntegrityVTable(pVTbl, pMod, pTabBlob);
  db.aDb := nil;
  db.nDb := 0;
end;

begin
  sqlite3OsInit;
  sqlite3PcacheInitialize;

  WriteLn('=== TestVdbeVtabExec — Phase 6.bis.3a/3b/3d gate ===');
  WriteLn;

  T1; WriteLn;
  T2; WriteLn;
  T3; WriteLn;
  T4; WriteLn;
  T5; WriteLn;
  T6; WriteLn;
  T7; WriteLn;
  T8; WriteLn;
  T9; WriteLn;
  T10; WriteLn;
  T11; WriteLn;
  T12; WriteLn;

  WriteLn(Format('Results: %d passed, %d failed', [gPass, gFail]));
  if gFail > 0 then Halt(1);
end.
