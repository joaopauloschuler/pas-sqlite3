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
program TestVdbeTxn;
{
  Phase 5.4g gate test — VDBE transaction-control opcodes.

    T1  OP_Transaction p2=0 (read)  on in-memory btree → SQLITE_DONE
    T2  OP_Transaction p2=1 (write) on in-memory btree → SQLITE_DONE
    T3  OP_Savepoint SAVEPOINT_BEGIN: creates savepoint in db list;
        db->autoCommit switches to 0, isTransactionSavepoint=1
    T4  OP_AutoCommit p1=1 when autoCommit=0 → SQLITE_DONE, autoCommit→1

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

{ ===== Infrastructure ======================================================= }

const
  PARSE_SZ = 256;

type
  TMinDb = record
    db:        Tsqlite3;
    parseArea: array[0..PARSE_SZ-1] of Byte;
  end;

procedure InitMinDb(var md: TMinDb; pBt: PBtree);
begin
  FillChar(md, SizeOf(md), 0);
  md.db.enc       := SQLITE_UTF8;
  md.db.nDb       := 1;
  md.db.aDb       := @md.db.aDbStatic[0];
  md.db.aDbStatic[0].pBt := pBt;
  md.db.aLimit[5] := 250000000;
  md.db.aLimit[0] := 1000000000;
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

{ Open a fresh in-memory btree (no rows, no active transaction). }
function OpenEmptyBtree(pDb: PTsqlite3): PBtree;
var
  pBt: PBtree;
  rc:  i32;
begin
  Result := nil;
  rc := sqlite3BtreeOpen(sqlite3_vfs_find(nil), ':memory:', pDb, @pBt,
                         BTREE_OMIT_JOURNAL or BTREE_SINGLE,
                         SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE);
  if rc = SQLITE_OK then Result := pBt;
end;

{ ===== T1: OP_Transaction read-only ======================================== }

procedure TestTxnRead;
var
  md:  TMinDb;
  pBt: PBtree;
  v:   PVdbe;
  rc:  i32;
begin
  WriteLn('T1: OP_Transaction p2=0 (read) → SQLITE_DONE');
  pBt := OpenEmptyBtree(nil);
  if pBt = nil then begin Check('T1 open', False); Exit; end;
  InitMinDb(md, pBt);

  v := CreateMinVdbe(@md.db, 2);
  if v = nil then begin Check('T1 vdbe', False); sqlite3BtreeClose(pBt); Exit; end;

  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp3(v, OP_Transaction, 0, 0, 0);  { p1=0(db), p2=0(read), p3=0 }
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  v^.eVdbeState := VDBE_RUN_STATE;

  rc := sqlite3VdbeExec(v);
  Check('T1 rc=DONE', rc = SQLITE_DONE);

  sqlite3VdbeDelete(v);
  sqlite3BtreeClose(pBt);
end;

{ ===== T2: OP_Transaction write ============================================ }

procedure TestTxnWrite;
var
  md:  TMinDb;
  pBt: PBtree;
  v:   PVdbe;
  rc:  i32;
begin
  WriteLn('T2: OP_Transaction p2=1 (write) → SQLITE_DONE');
  pBt := OpenEmptyBtree(nil);
  if pBt = nil then begin Check('T2 open', False); Exit; end;
  InitMinDb(md, pBt);

  v := CreateMinVdbe(@md.db, 2);
  if v = nil then begin Check('T2 vdbe', False); sqlite3BtreeClose(pBt); Exit; end;

  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp3(v, OP_Transaction, 0, 1, 0);  { p1=0(db), p2=1(write), p3=0 }
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  v^.eVdbeState := VDBE_RUN_STATE;

  rc := sqlite3VdbeExec(v);
  Check('T2 rc=DONE', rc = SQLITE_DONE);

  sqlite3VdbeDelete(v);
  sqlite3BtreeClose(pBt);
end;

{ ===== T3: OP_Savepoint BEGIN ============================================== }

procedure TestSavepointBegin;
var
  md:  TMinDb;
  v:   PVdbe;
  rc:  i32;
const
  SvptName: PAnsiChar = 'mysp';
begin
  WriteLn('T3: OP_Savepoint SAVEPOINT_BEGIN → creates savepoint, autoCommit→0');
  InitMinDb(md, nil);
  md.db.autoCommit := 1;  { start in autocommit mode }

  v := CreateMinVdbe(@md.db, 2);
  if v = nil then begin Check('T3 vdbe', False); Exit; end;

  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  { OP_Savepoint: p1=SAVEPOINT_BEGIN(0), p4.z=name }
  sqlite3VdbeAddOp4(v, OP_Savepoint, SAVEPOINT_BEGIN, 0, 0, SvptName, P4_STATIC);
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  v^.eVdbeState := VDBE_RUN_STATE;

  rc := sqlite3VdbeExec(v);
  Check('T3 rc=DONE',       rc = SQLITE_DONE);
  Check('T3 pSavepoint<>0', md.db.pSavepoint <> nil);
  Check('T3 autoCommit=0',  md.db.autoCommit = 0);
  Check('T3 txnSavepoint=1', md.db.isTransactionSavepoint <> 0);

  sqlite3VdbeDelete(v);
end;

{ ===== T4: OP_AutoCommit commit =========================================== }

procedure TestAutoCommit;
var
  md:  TMinDb;
  v:   PVdbe;
  rc:  i32;
begin
  WriteLn('T4: OP_AutoCommit p1=1(commit) when autoCommit=0 → SQLITE_DONE');
  InitMinDb(md, nil);
  md.db.autoCommit := 0;  { simulate being inside a transaction }

  v := CreateMinVdbe(@md.db, 2);
  if v = nil then begin Check('T4 vdbe', False); Exit; end;

  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  { OP_AutoCommit: p1=1(desiredAutoCommit), p2=0(not rollback) }
  sqlite3VdbeAddOp2(v, OP_AutoCommit, 1, 0);
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  v^.eVdbeState := VDBE_RUN_STATE;

  rc := sqlite3VdbeExec(v);
  Check('T4 rc=DONE',      rc = SQLITE_DONE);
  Check('T4 autoCommit=1', md.db.autoCommit = 1);

  sqlite3VdbeDelete(v);
end;

{ ===== main ================================================================= }

begin
  sqlite3OsInit;
  sqlite3PcacheInitialize;

  WriteLn('=== TestVdbeTxn — Phase 5.4g gate test ===');
  WriteLn;

  TestTxnRead;     WriteLn;
  TestTxnWrite;    WriteLn;
  TestSavepointBegin; WriteLn;
  TestAutoCommit;  WriteLn;

  WriteLn(Format('Results: %d passed, %d failed', [gPass, gFail]));
  if gFail > 0 then Halt(1);
end.
