{$I passqlite3.inc}
program DebugT5;
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

const PARSE_SZ = 256;
type TMinDb = record
  db:        Tsqlite3;
  parseArea: array[0..PARSE_SZ-1] of Byte;
end;

procedure InitMinDb(var md: TMinDb; pBt: PBtree);
begin
  FillChar(md, SizeOf(md), 0);
  md.db.enc := SQLITE_UTF8;
  md.db.nDb := 1;
  md.db.aDb := @md.db.aDbStatic[0];
  md.db.aDbStatic[0].pBt := pBt;
  PPointer(@md.parseArea[0])^ := @md.db;
  md.db.aLimit[5] := 250000000;
  md.db.aLimit[0] := 1000000000;
end;

function CreateMinVdbe(pDb: PTsqlite3; nMem, nCsr: i32): PVdbe;
var pParse: Pointer; v: PVdbe; sz: u64;
begin
  pParse := sqlite3DbMallocZero(pDb, PARSE_SZ);
  PPointer(pParse)^ := pDb;
  Pi32(PByte(pParse) + 156)^ := 250000000;
  v := sqlite3VdbeCreate(pParse);
  sqlite3DbFree(pDb, pParse);
  v^.nOp := 0;
  sz := u64(nMem) * SizeOf(TMem);
  v^.aMem := PMem(sqlite3DbMallocZero(pDb, sz));
  v^.nMem := nMem;
  sz := u64(nCsr) * SizeOf(PVdbeCursor);
  v^.apCsr := PPVdbeCursor(sqlite3DbMallocZero(pDb, sz));
  v^.nCursor := nCsr;
  v^.eVdbeState := VDBE_RUN_STATE;
  v^.minWriteFileFormat := 4;
  v^.pc := 0;
  Result := v;
end;

var
  md: TMinDb;
  pBt: PBtree;
  v: PVdbe;
  pgno: u32;
  rc: i32;
  m: PMem;
begin
  sqlite3OsInit;
  sqlite3PcacheInitialize;

  rc := sqlite3BtreeOpen(sqlite3_vfs_find(nil), ':memory:', nil, @pBt,
    BTREE_OMIT_JOURNAL or BTREE_SINGLE, SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE);
  WriteLn('Open rc=', rc);
  InitMinDb(md, pBt);
  rc := sqlite3BtreeBeginTrans(pBt, 1, nil);
  WriteLn('BeginTrans rc=', rc);
  rc := sqlite3BtreeCreateTable(pBt, @pgno, BTREE_INTKEY or BTREE_LEAFDATA);
  WriteLn('CreateTable rc=', rc, ' pgno=', pgno);

  v := CreateMinVdbe(@md.db, 5, 1);

  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp4Int(v, OP_OpenWrite, 0, i32(pgno), 0, 1);
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
  WriteLn('Exec rc=', rc);

  m := @v^.aMem[4];
  WriteLn('r[4].flags=', m^.flags, ' u.i=', m^.u.i);
  if (m^.flags and MEM_Blob) <> 0 then WriteLn(' --> MEM_Blob n=', m^.n);
  if (m^.flags and MEM_Int) <> 0 then WriteLn(' --> MEM_Int val=', m^.u.i);
  if (m^.flags and MEM_Null) <> 0 then WriteLn(' --> MEM_Null');
  if (m^.flags and MEM_Str) <> 0 then WriteLn(' --> MEM_Str n=', m^.n);

  { Check r[2] (the record blob) }
  m := @v^.aMem[2];
  WriteLn('r[2] (record blob) flags=', m^.flags, ' n=', m^.n);
  if m^.n > 0 then begin
    WriteLn('bytes: ', IntToHex(PByte(m^.z)[0], 2), ' ',
                       IntToHex(PByte(m^.z)[1], 2), ' ',
                       IntToHex(PByte(m^.z)[2], 2));
  end;

  sqlite3VdbeDelete(v);
  sqlite3BtreeClose(pBt);
end.
