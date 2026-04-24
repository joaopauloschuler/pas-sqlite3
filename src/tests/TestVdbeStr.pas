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

{ ===== T1: OP_String (direct) ============================================== }

procedure TestStringDirect;
var
  md:   TMinDb;
  v:    PVdbe;
  rc:   i32;
  pOp:  PVdbeOp;
const
  SLiteral: PAnsiChar = 'hello';
begin
  WriteLn('T1: OP_String direct → r[1]="hello"');
  InitMinDb(md);
  v := CreateMinVdbe(@md.db, 3);
  if v = nil then begin Check('T1 vdbe', False); Exit; end;

  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  { add OP_String: p1=5(len), p2=1(out), p4.z=SLiteral }
  sqlite3VdbeAddOp4(v, OP_String, 5, 1, 0, SLiteral, P4_STATIC);
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  v^.eVdbeState := VDBE_RUN_STATE;

  rc := sqlite3VdbeExec(v);
  Check('T1 rc', rc = SQLITE_DONE);
  Check('T1 MEM_Str', (v^.aMem[1].flags and MEM_Str) <> 0);
  Check('T1 n=5', v^.aMem[1].n = 5);
  Check('T1 content', StrComp(v^.aMem[1].z, SLiteral) = 0);

  sqlite3VdbeDelete(v);
end;

{ ===== T2: OP_String8 (first-run length computation) ======================= }

procedure TestString8;
var
  md:   TMinDb;
  v:    PVdbe;
  rc:   i32;
const
  SHello: PAnsiChar = 'world!';
begin
  WriteLn('T2: OP_String8 → computes len → r[1]="world!"');
  InitMinDb(md);
  v := CreateMinVdbe(@md.db, 3);
  if v = nil then begin Check('T2 vdbe', False); Exit; end;

  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp4(v, OP_String8, 0, 1, 0, SHello, P4_STATIC);
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  v^.eVdbeState := VDBE_RUN_STATE;

  rc := sqlite3VdbeExec(v);
  Check('T2 rc', rc = SQLITE_DONE);
  Check('T2 MEM_Str', (v^.aMem[1].flags and MEM_Str) <> 0);
  Check('T2 n=6', v^.aMem[1].n = 6);
  Check('T2 content', StrComp(v^.aMem[1].z, SHello) = 0);

  sqlite3VdbeDelete(v);
end;

{ ===== T3: OP_Concat 'Hello' || ' World' =================================== }

procedure TestConcat;
var
  md:   TMinDb;
  v:    PVdbe;
  rc:   i32;
const
  SA: PAnsiChar = 'Hello';
  SB: PAnsiChar = ' World';
begin
  WriteLn('T3: OP_Concat "Hello" || " World" = "Hello World"');
  InitMinDb(md);

  { r[1]=' World'(right=P1), r[2]='Hello'(left=P2), r[3]=concat(out=P3) }
  v := CreateMinVdbe(@md.db, 5);
  if v = nil then begin Check('T3 vdbe', False); Exit; end;

  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp4(v, OP_String, 5, 1, 0, SA, P4_STATIC);   { r[1]="Hello" }
  sqlite3VdbeAddOp4(v, OP_String, 6, 2, 0, SB, P4_STATIC);   { r[2]=" World" }
  sqlite3VdbeAddOp3(v, OP_Concat, 2, 1, 3);  { r[3] = r[1] || r[2] }
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  v^.eVdbeState := VDBE_RUN_STATE;

  rc := sqlite3VdbeExec(v);
  Check('T3 rc', rc = SQLITE_DONE);
  Check('T3 MEM_Str', (v^.aMem[3].flags and MEM_Str) <> 0);
  Check('T3 n=11', v^.aMem[3].n = 11);
  Check('T3 content', StrLComp(v^.aMem[3].z, 'Hello World', 11) = 0);

  sqlite3VdbeDelete(v);
end;

{ ===== T4: OP_Concat NULL || 'x' = NULL ==================================== }

procedure TestConcatNull;
var
  md: TMinDb;
  v:  PVdbe;
  rc: i32;
const
  SX: PAnsiChar = 'x';
begin
  WriteLn('T4: OP_Concat NULL || "x" = NULL');
  InitMinDb(md);
  v := CreateMinVdbe(@md.db, 4);
  if v = nil then begin Check('T4 vdbe', False); Exit; end;

  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp4(v, OP_String, 1, 2, 0, SX, P4_STATIC);  { r[2]="x" }
  { r[1] stays NULL (zero-init MEM_Null) }
  sqlite3VdbeAddOp3(v, OP_Concat, 2, 1, 3);  { r[3] = r[1](NULL) || r[2] }
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  v^.aMem[1].flags := MEM_Null;
  v^.eVdbeState := VDBE_RUN_STATE;

  rc := sqlite3VdbeExec(v);
  Check('T4 rc', rc = SQLITE_DONE);
  Check('T4 NULL concat=NULL', (v^.aMem[3].flags and MEM_Null) <> 0);

  sqlite3VdbeDelete(v);
end;

{ ===== T5: OP_Concat with stringify: 42 || ' items' ======================== }

procedure TestConcatStringify;
var
  md:   TMinDb;
  v:    PVdbe;
  rc:   i32;
const
  SItems: PAnsiChar = ' items';
begin
  WriteLn('T5: OP_Concat 42(int) || " items" → "42 items"');
  InitMinDb(md);
  { r[1]=42(int), r[2]=' items', r[3]=result }
  v := CreateMinVdbe(@md.db, 5);
  if v = nil then begin Check('T5 vdbe', False); Exit; end;

  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp2(v, OP_Integer, 42, 1);                        { r[1]=42 int }
  sqlite3VdbeAddOp4(v, OP_String, 6, 2, 0, SItems, P4_STATIC);   { r[2]=" items" }
  sqlite3VdbeAddOp3(v, OP_Concat, 2, 1, 3);  { r[3] = r[1](42) || r[2] }
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  v^.eVdbeState := VDBE_RUN_STATE;

  rc := sqlite3VdbeExec(v);
  Check('T5 rc', rc = SQLITE_DONE);
  Check('T5 MEM_Str', (v^.aMem[3].flags and MEM_Str) <> 0);
  Check('T5 n=8', v^.aMem[3].n = 8);
  Check('T5 content', StrLComp(v^.aMem[3].z, '42 items', 8) = 0);

  sqlite3VdbeDelete(v);
end;

{ ===== T6: OP_Blob ========================================================= }

procedure TestBlob;
var
  md:   TMinDb;
  v:    PVdbe;
  rc:   i32;
const
  BlobData: array[0..3] of Byte = ($DE, $AD, $BE, $EF);
begin
  WriteLn('T6: OP_Blob 4-byte blob → r[1]');
  InitMinDb(md);
  v := CreateMinVdbe(@md.db, 3);
  if v = nil then begin Check('T6 vdbe', False); Exit; end;

  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp4(v, OP_Blob, 4, 1, 0, PAnsiChar(@BlobData[0]), P4_STATIC);
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  v^.eVdbeState := VDBE_RUN_STATE;

  rc := sqlite3VdbeExec(v);
  Check('T6 rc', rc = SQLITE_DONE);
  Check('T6 MEM_Blob', (v^.aMem[1].flags and MEM_Blob) <> 0);
  Check('T6 n=4', v^.aMem[1].n = 4);
  Check('T6 byte0=$DE', PByte(v^.aMem[1].z)[0] = $DE);
  Check('T6 byte3=$EF', PByte(v^.aMem[1].z)[3] = $EF);

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

  WriteLn(Format('Results: %d passed, %d failed', [gPass, gFail]));
  if gFail > 0 then Halt(1);
end.
