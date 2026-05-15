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
  passqlite3vdbe,
  TestVdbeCommon;

{ ===== T1: OP_Transaction read-only ======================================== }

procedure TestTxnRead;
var
  md:  TVdbeMinDb;
  pBt: PBtree;
  v:   PVdbe;
  rc:  i32;
begin
  WriteLn('T1: OP_Transaction p2=0 (read) → SQLITE_DONE');
  pBt := VdbeOpenEmptyBtree(nil);
  if pBt = nil then begin VdbeCheck('T1 open', False); Exit; end;
  VdbeInitMinDb(md, pBt);

  v := VdbeCreateMinRun(@md.db, 2);
  if v = nil then begin VdbeCheck('T1 vdbe', False); sqlite3BtreeClose(pBt); Exit; end;

  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp3(v, OP_Transaction, 0, 0, 0);  { p1=0(db), p2=0(read), p3=0 }
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  v^.eVdbeState := VDBE_RUN_STATE;

  rc := sqlite3VdbeExec(v);
  VdbeCheck('T1 rc=DONE', rc = SQLITE_DONE);

  sqlite3VdbeDelete(v);
  sqlite3BtreeClose(pBt);
end;

{ ===== T2: OP_Transaction write ============================================ }

procedure TestTxnWrite;
var
  md:  TVdbeMinDb;
  pBt: PBtree;
  v:   PVdbe;
  rc:  i32;
begin
  WriteLn('T2: OP_Transaction p2=1 (write) → SQLITE_DONE');
  pBt := VdbeOpenEmptyBtree(nil);
  if pBt = nil then begin VdbeCheck('T2 open', False); Exit; end;
  VdbeInitMinDb(md, pBt);

  v := VdbeCreateMinRun(@md.db, 2);
  if v = nil then begin VdbeCheck('T2 vdbe', False); sqlite3BtreeClose(pBt); Exit; end;

  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp3(v, OP_Transaction, 0, 1, 0);  { p1=0(db), p2=1(write), p3=0 }
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  v^.eVdbeState := VDBE_RUN_STATE;

  rc := sqlite3VdbeExec(v);
  VdbeCheck('T2 rc=DONE', rc = SQLITE_DONE);

  sqlite3VdbeDelete(v);
  sqlite3BtreeClose(pBt);
end;

{ ===== T3: OP_Savepoint BEGIN ============================================== }

procedure TestSavepointBegin;
var
  md:  TVdbeMinDb;
  v:   PVdbe;
  rc:  i32;
const
  SvptName: PAnsiChar = 'mysp';
begin
  WriteLn('T3: OP_Savepoint SAVEPOINT_BEGIN → creates savepoint, autoCommit→0');
  VdbeInitMinDb(md, nil);
  md.db.autoCommit := 1;  { start in autocommit mode }

  v := VdbeCreateMinRun(@md.db, 2);
  if v = nil then begin VdbeCheck('T3 vdbe', False); Exit; end;

  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  { OP_Savepoint: p1=SAVEPOINT_BEGIN(0), p4.z=name }
  sqlite3VdbeAddOp4(v, OP_Savepoint, SAVEPOINT_BEGIN, 0, 0, SvptName, P4_STATIC);
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  v^.eVdbeState := VDBE_RUN_STATE;

  rc := sqlite3VdbeExec(v);
  VdbeCheck('T3 rc=DONE',       rc = SQLITE_DONE);
  VdbeCheck('T3 pSavepoint<>0', md.db.pSavepoint <> nil);
  VdbeCheck('T3 autoCommit=0',  md.db.autoCommit = 0);
  VdbeCheck('T3 txnSavepoint=1', md.db.isTransactionSavepoint <> 0);

  sqlite3VdbeDelete(v);
end;

{ ===== T4: OP_AutoCommit commit =========================================== }

procedure TestAutoCommit;
var
  md:  TVdbeMinDb;
  v:   PVdbe;
  rc:  i32;
begin
  WriteLn('T4: OP_AutoCommit p1=1(commit) when autoCommit=0 → SQLITE_DONE');
  VdbeInitMinDb(md, nil);
  md.db.autoCommit := 0;  { simulate being inside a transaction }

  v := VdbeCreateMinRun(@md.db, 2);
  if v = nil then begin VdbeCheck('T4 vdbe', False); Exit; end;

  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  { OP_AutoCommit: p1=1(desiredAutoCommit), p2=0(not rollback) }
  sqlite3VdbeAddOp2(v, OP_AutoCommit, 1, 0);
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  v^.eVdbeState := VDBE_RUN_STATE;

  rc := sqlite3VdbeExec(v);
  VdbeCheck('T4 rc=DONE',      rc = SQLITE_DONE);
  VdbeCheck('T4 autoCommit=1', md.db.autoCommit = 1);

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

  WriteLn(Format('Results: %d passed, %d failed', [gVdbePass, gVdbeFail]));
  if gVdbeFail > 0 then Halt(1);
end.
