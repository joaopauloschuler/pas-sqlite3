{$I passqlite3.inc}
program TestVdbeRecord;
{
  Phase 5.4c gate test — VDBE record I/O opcodes.

  All tests use an in-memory btree kept in a write transaction so that both
  OP_OpenRead and OP_OpenWrite work without a real sqlite3 connection.

    T1  OP_Count — 5 pre-inserted rows → exact count 5
    T2  OP_Rowid — first row after OP_Rewind → rowid 1
    T3  OP_NewRowid — empty table → rowid 1
    T4  OP_Insert × 3 + OP_Count → count 3
    T5  OP_MakeRecord + OP_Insert + OP_Column → integer 42 roundtrip
    T6  OP_Insert + OP_Rewind + OP_Delete + OP_Count → count 0

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
  md.db.enc            := SQLITE_UTF8;
  md.db.nDb            := 1;
  md.db.aDb            := @md.db.aDbStatic[0];
  md.db.aDbStatic[0].pBt := pBt;
  PPointer(@md.parseArea[0])^ := @md.db;
  md.db.aLimit[5]  := 250000000;   { SQLITE_LIMIT_WORKER_THREADS }
  md.db.aLimit[0]  := 1000000000;  { SQLITE_LIMIT_LENGTH }
end;

function CreateMinVdbe(pDb: PTsqlite3; nMem: i32; nCsr: i32): PVdbe;
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

  sz := u64(nCsr) * SizeOf(PVdbeCursor);
  v^.apCsr   := PPVdbeCursor(sqlite3DbMallocZero(pDb, sz));
  v^.nCursor := nCsr;

  v^.eVdbeState         := VDBE_RUN_STATE;
  v^.minWriteFileFormat := 4;
  v^.pc                 := 0;
  v^.cacheCtr           := 1;  { must not equal CACHE_STALE=0 }

  Result := v;
end;

{ Open an in-memory btree + write transaction + create table.
  Leaves the btree in a write transaction so the VDBE can do writes. }
function OpenWriteBtree(pDb: PTsqlite3; out pgno: u32): PBtree;
var
  pBt: PBtree;
  rc:  i32;
begin
  Result := nil;
  rc := sqlite3BtreeOpen(sqlite3_vfs_find(nil), ':memory:', pDb, @pBt,
                         BTREE_OMIT_JOURNAL or BTREE_SINGLE,
                         SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE);
  if rc <> SQLITE_OK then Exit;

  rc := sqlite3BtreeBeginTrans(pBt, 1, nil);  { write }
  if rc <> SQLITE_OK then begin sqlite3BtreeClose(pBt); Exit; end;

  rc := sqlite3BtreeCreateTable(pBt, @pgno, BTREE_INTKEY or BTREE_LEAFDATA);
  if rc <> SQLITE_OK then begin sqlite3BtreeClose(pBt); Exit; end;

  Result := pBt;
end;

{ Pre-insert N integer-key empty rows into pBt (already in write tx). }
function InsertEmptyRows(pBt: PBtree; pgno: u32; N: i32): Boolean;
var
  cur:  TBtCursor;
  p:    TBtreePayload;
  iKey: i64;
  rc:   i32;
begin
  Result := False;
  FillChar(cur, SizeOf(cur), 0);
  rc := sqlite3BtreeCursor(pBt, pgno, 1, nil, @cur);
  if rc <> SQLITE_OK then Exit;

  FillChar(p, SizeOf(p), 0);
  for iKey := 1 to N do begin
    p.nKey  := iKey;
    p.pData := nil;
    p.nData := 0;
    p.nZero := 0;
    rc := sqlite3BtreeInsert(@cur, @p, 0, 0);
    if rc <> SQLITE_OK then begin
      sqlite3BtreeCloseCursor(@cur);
      Exit;
    end;
  end;

  sqlite3BtreeCloseCursor(@cur);
  Result := True;
end;

{ ===== T1: OP_Count on 5 pre-inserted rows ================================= }

procedure TestCount;
var
  md:   TMinDb;
  pBt:  PBtree;
  v:    PVdbe;
  pgno: u32;
  rc:   i32;
begin
  WriteLn('T1: OP_Count → 5 rows');

  pBt := OpenWriteBtree(nil, pgno);
  if pBt = nil then begin Check('T1 open', False); Exit; end;
  InitMinDb(md, pBt);

  if not InsertEmptyRows(pBt, pgno, 5) then begin
    Check('T1 insert rows', False); sqlite3BtreeClose(pBt); Exit;
  end;

  v := CreateMinVdbe(@md.db, 3 {nMem: r[0]=cursor,r[1]=count,r[2]=spare}, 1);
  if v = nil then begin Check('T1 vdbe', False); sqlite3BtreeClose(pBt); Exit; end;

  { 0: OP_Init  0,1,0
    1: OP_OpenRead 0 pgno 0
    2: OP_Count   0 1 0    ← r[1] = exact count
    3: OP_Halt   0 0 0  }
  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp4Int(v, OP_OpenRead, 0, i32(pgno), 0, 0);
  sqlite3VdbeAddOp3(v, OP_Count, 0, 1, 0);   { P2=out reg, P3=0 exact }
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  v^.eVdbeState := VDBE_RUN_STATE;

  rc := sqlite3VdbeExec(v);
  Check('T1 rc=SQLITE_DONE', rc = SQLITE_DONE);
  Check('T1 count=5', v^.aMem[1].u.i = 5);

  sqlite3VdbeDelete(v);
  sqlite3BtreeClose(pBt);
end;

{ ===== T2: OP_Rowid after OP_Rewind ======================================== }

procedure TestRowid;
var
  md:   TMinDb;
  pBt:  PBtree;
  v:    PVdbe;
  pgno: u32;
  rc:   i32;
begin
  WriteLn('T2: OP_Rowid → first row rowid=1');

  pBt := OpenWriteBtree(nil, pgno);
  if pBt = nil then begin Check('T2 open', False); Exit; end;
  InitMinDb(md, pBt);

  if not InsertEmptyRows(pBt, pgno, 3) then begin
    Check('T2 insert', False); sqlite3BtreeClose(pBt); Exit;
  end;

  v := CreateMinVdbe(@md.db, 3, 1);
  if v = nil then begin Check('T2 vdbe', False); sqlite3BtreeClose(pBt); Exit; end;

  { 0: OP_Init   0,1,0
    1: OP_OpenRead 0 pgno 0
    2: OP_Rewind  0 5 0    ← jump to 5 if empty
    3: OP_Rowid   0 1 0    ← r[1] = rowid of current row
    4: OP_Halt    0 0 0
    5: OP_Halt    0 0 0    ← empty (shouldn't reach) }
  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp4Int(v, OP_OpenRead, 0, i32(pgno), 0, 0);
  sqlite3VdbeAddOp3(v, OP_Rewind, 0, 5, 0);
  sqlite3VdbeAddOp3(v, OP_Rowid, 0, 1, 0);
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  v^.eVdbeState := VDBE_RUN_STATE;

  rc := sqlite3VdbeExec(v);
  Check('T2 rc=SQLITE_DONE', rc = SQLITE_DONE);
  Check('T2 rowid=1', v^.aMem[1].u.i = 1);

  sqlite3VdbeDelete(v);
  sqlite3BtreeClose(pBt);
end;

{ ===== T3: OP_NewRowid on empty table → 1 ================================== }

procedure TestNewRowid;
var
  md:   TMinDb;
  pBt:  PBtree;
  v:    PVdbe;
  pgno: u32;
  rc:   i32;
begin
  WriteLn('T3: OP_NewRowid on empty table → rowid 1');

  pBt := OpenWriteBtree(nil, pgno);
  if pBt = nil then begin Check('T3 open', False); Exit; end;
  InitMinDb(md, pBt);

  v := CreateMinVdbe(@md.db, 3, 1);
  if v = nil then begin Check('T3 vdbe', False); sqlite3BtreeClose(pBt); Exit; end;

  { 0: OP_Init      0,1,0
    1: OP_OpenWrite  0 pgno 0 {P4=0 fields}
    2: OP_NewRowid   0 1 0    ← r[1] = new rowid
    3: OP_Halt       0 0 0  }
  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp4Int(v, OP_OpenWrite, 0, i32(pgno), 0, 0);
  sqlite3VdbeAddOp3(v, OP_NewRowid, 0, 1, 0);
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  v^.eVdbeState := VDBE_RUN_STATE;

  rc := sqlite3VdbeExec(v);
  Check('T3 rc=SQLITE_DONE', rc = SQLITE_DONE);
  Check('T3 newrowid=1', v^.aMem[1].u.i = 1);

  sqlite3VdbeDelete(v);
  sqlite3BtreeClose(pBt);
end;

{ ===== T4: OP_Insert × 3 + OP_Count → 3 ==================================== }

procedure TestInsertCount;
var
  md:   TMinDb;
  pBt:  PBtree;
  v:    PVdbe;
  pgno: u32;
  rc:   i32;
begin
  WriteLn('T4: OP_Insert × 3 then OP_Count → 3');

  pBt := OpenWriteBtree(nil, pgno);
  if pBt = nil then begin Check('T4 open', False); Exit; end;
  InitMinDb(md, pBt);

  { nMem: r[0]=cursor slot, r[1]=empty blob (data), r[2]=rowid key, r[3]=count }
  v := CreateMinVdbe(@md.db, 4, 1);
  if v = nil then begin Check('T4 vdbe', False); sqlite3BtreeClose(pBt); Exit; end;

  { r[1] stays as empty/null mem — nData=0 means no record data
    We pre-zero aMem so flags=0 (MEM_Null-ish), n=0, z=nil → nData=0 fine }
  v^.aMem[1].flags := MEM_Blob;
  v^.aMem[1].n     := 0;
  v^.aMem[1].z     := nil;

  { 0:  OP_Init      0,1,0
    1:  OP_OpenWrite  0 pgno 0 {P4=0 fields}
    2:  OP_Integer    1 2 0     ← r[2] = 1
    3:  OP_Insert     0 1 2
    4:  OP_Integer    2 2 0     ← r[2] = 2
    5:  OP_Insert     0 1 2
    6:  OP_Integer    3 2 0     ← r[2] = 3
    7:  OP_Insert     0 1 2
    8:  OP_Count      0 3 0     ← r[3] = count
    9:  OP_Halt       0 0 0  }
  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp4Int(v, OP_OpenWrite, 0, i32(pgno), 0, 0);
  sqlite3VdbeAddOp2(v, OP_Integer, 1, 2);
  sqlite3VdbeAddOp3(v, OP_Insert, 0, 1, 2);
  sqlite3VdbeAddOp2(v, OP_Integer, 2, 2);
  sqlite3VdbeAddOp3(v, OP_Insert, 0, 1, 2);
  sqlite3VdbeAddOp2(v, OP_Integer, 3, 2);
  sqlite3VdbeAddOp3(v, OP_Insert, 0, 1, 2);
  sqlite3VdbeAddOp3(v, OP_Count, 0, 3, 0);
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  v^.eVdbeState := VDBE_RUN_STATE;

  rc := sqlite3VdbeExec(v);
  Check('T4 rc=SQLITE_DONE', rc = SQLITE_DONE);
  Check('T4 count=3', v^.aMem[3].u.i = 3);

  sqlite3VdbeDelete(v);
  sqlite3BtreeClose(pBt);
end;

{ ===== T5: OP_MakeRecord + OP_Insert + OP_Column roundtrip ================= }

procedure TestMakeRecordColumn;
var
  md:   TMinDb;
  pBt:  PBtree;
  v:    PVdbe;
  pgno: u32;
  rc:   i32;
begin
  WriteLn('T5: OP_MakeRecord(42) + OP_Insert + OP_Column → 42');

  pBt := OpenWriteBtree(nil, pgno);
  if pBt = nil then begin Check('T5 open', False); Exit; end;
  InitMinDb(md, pBt);

  { nMem: r[0]=cursor, r[1]=input(42), r[2]=record blob, r[3]=rowid, r[4]=col0 }
  v := CreateMinVdbe(@md.db, 5, 1);
  if v = nil then begin Check('T5 vdbe', False); sqlite3BtreeClose(pBt); Exit; end;

  { 0:  OP_Init       0,1,0
    1:  OP_OpenWrite   0 pgno 0 {P4_INT32=1 field}
    2:  OP_Integer     42 1 0       ← r[1] = 42
    3:  OP_MakeRecord  1 1 2        ← r[2] = record([r[1]])
    4:  OP_NewRowid    0 3 0        ← r[3] = new rowid
    5:  OP_Insert      0 2 3        ← insert r[2] at r[3]
    6:  OP_Rewind      0 9 0        ← if empty goto 9
    7:  OP_Column      0 0 4        ← r[4] = col 0 of current row
    8:  OP_Halt        0 0 0
    9:  OP_Halt        0 0 0        ← empty (shouldn't happen) }
  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp4Int(v, OP_OpenWrite, 0, i32(pgno), 0, 1);  { 1 field }
  sqlite3VdbeAddOp2(v, OP_Integer, 42, 1);
  sqlite3VdbeAddOp3(v, OP_MakeRecord, 1, 1, 2);
  sqlite3VdbeAddOp3(v, OP_NewRowid, 0, 3, 0);
  sqlite3VdbeAddOp3(v, OP_Insert, 0, 2, 3);
  sqlite3VdbeAddOp3(v, OP_Rewind, 0, 9, 0);
  sqlite3VdbeAddOp3(v, OP_Column, 0, 0, 4);
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  v^.eVdbeState := VDBE_RUN_STATE;

  rc := sqlite3VdbeExec(v);
  Check('T5 rc=SQLITE_DONE', rc = SQLITE_DONE);
  Check('T5 col0=42', (v^.aMem[4].flags and MEM_Int) <> 0);
  Check('T5 col0 value', v^.aMem[4].u.i = 42);

  sqlite3VdbeDelete(v);
  sqlite3BtreeClose(pBt);
end;

{ ===== T6: OP_Insert + OP_Rewind + OP_Delete + OP_Count → 0 ================ }

procedure TestInsertDelete;
var
  md:   TMinDb;
  pBt:  PBtree;
  v:    PVdbe;
  pgno: u32;
  rc:   i32;
begin
  WriteLn('T6: OP_Insert + OP_Delete → count=0');

  pBt := OpenWriteBtree(nil, pgno);
  if pBt = nil then begin Check('T6 open', False); Exit; end;
  InitMinDb(md, pBt);

  { nMem: r[0]=cursor, r[1]=blob(empty), r[2]=rowid, r[3]=count }
  v := CreateMinVdbe(@md.db, 4, 1);
  if v = nil then begin Check('T6 vdbe', False); sqlite3BtreeClose(pBt); Exit; end;

  v^.aMem[1].flags := MEM_Blob;
  v^.aMem[1].n     := 0;
  v^.aMem[1].z     := nil;

  { 0:  OP_Init       0,1,0
    1:  OP_OpenWrite   0 pgno 0 {0 fields}
    2:  OP_Integer     99 2 0      ← r[2] = 99
    3:  OP_Insert      0 1 2       ← insert empty row at rowid 99
    4:  OP_Rewind      0 8 0       ← rewind; empty→goto 8
    5:  OP_Delete      0 0 0       ← delete current row
    6:  OP_Count       0 3 0       ← r[3] = count (should be 0)
    7:  OP_Halt        0 0 0
    8:  OP_Halt        0 0 0       ← empty branch (shouldn't happen) }
  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp4Int(v, OP_OpenWrite, 0, i32(pgno), 0, 0);
  sqlite3VdbeAddOp2(v, OP_Integer, 99, 2);
  sqlite3VdbeAddOp3(v, OP_Insert, 0, 1, 2);
  sqlite3VdbeAddOp3(v, OP_Rewind, 0, 8, 0);
  sqlite3VdbeAddOp2(v, OP_Delete, 0, 0);
  sqlite3VdbeAddOp3(v, OP_Count, 0, 3, 0);
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  v^.eVdbeState := VDBE_RUN_STATE;

  rc := sqlite3VdbeExec(v);
  Check('T6 rc=SQLITE_DONE', rc = SQLITE_DONE);
  Check('T6 count=0', v^.aMem[3].u.i = 0);

  sqlite3VdbeDelete(v);
  sqlite3BtreeClose(pBt);
end;

{ ===== main ================================================================= }

begin
  sqlite3OsInit;
  sqlite3PcacheInitialize;

  WriteLn('=== TestVdbeRecord — Phase 5.4c gate test ===');
  WriteLn;

  TestCount;
  WriteLn;
  TestRowid;
  WriteLn;
  TestNewRowid;
  WriteLn;
  TestInsertCount;
  WriteLn;
  TestMakeRecordColumn;
  WriteLn;
  TestInsertDelete;
  WriteLn;

  WriteLn(Format('Results: %d passed, %d failed', [gPass, gFail]));
  if gFail > 0 then Halt(1);
end.
