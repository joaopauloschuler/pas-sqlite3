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
program TestVdbeAux;
{
  Phase 5.2 gate test — vdbeaux.c: serial types and VDBE program assembly.

  Tests run without opening a file or database connection.  A minimal mock
  Parse + sqlite3 context (heap-allocated byte buffers, GCC-verified offsets)
  is used for the AddOp tests so we never link real SQLite internals.

    T1  sqlite3VdbeSerialTypeLen — all 13 special cases (types 0-12)
    T2  sqlite3VdbeSerialTypeLen — formula cases (types 13, 14, 127, 256)
    T3  sqlite3VdbeOneByteSerialTypeLen — spot-check u8 variant
    T4  sqlite3VdbeSerialGet — NULL (type 0)
    T5  sqlite3VdbeSerialGet — integer types 1-6 (big-endian round-trip)
    T6  sqlite3VdbeSerialGet — integer constants 8 (→0) and 9 (→1)
    T7  sqlite3VdbeSerialGet — float type 7 (IEEE 754 big-endian)
    T8  sqlite3VdbeSerialGet — blob (even serial type ≥ 13)
    T9  sqlite3VdbeSerialGet — string (odd serial type ≥ 13)
    T10 sqlite3VdbeSerialPut — round-trip integer (put then get)
    T11 sqlite3VdbeSerialPut — round-trip float
    T12 sqlite3VdbeSerialPut — round-trip blob
    T13 sqlite3VdbeSerialType — NULL → type 0
    T14 sqlite3VdbeSerialType — integer ranges → correct type codes
    T15 sqlite3VdbeSerialType — real → type 7
    T16 sqlite3VdbeSerialType — blob/string → formula
    T17 VDBE AddOp: build a 3-instruction program via mock Parse, verify Op[]

  Gate: T1-T17 all PASS.
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

{ ===== T1-T3: sqlite3VdbeSerialTypeLen ===================================== }

procedure TestSerialTypeLen;
const
  { SQLite file-format spec: stored bytes for types 0-12 }
  EXPECTED: array[0..12] of u32 = (0, 1, 2, 3, 4, 6, 8, 8, 0, 0, 0, 0, 0);
var
  i: i32;
begin
  WriteLn('T1: sqlite3VdbeSerialTypeLen special cases (0-12)');
  for i := 0 to 12 do
    Check(Format('SerialTypeLen(%d)=%d', [i, EXPECTED[i]]),
          sqlite3VdbeSerialTypeLen(u32(i)) = EXPECTED[i]);

  WriteLn('T2: sqlite3VdbeSerialTypeLen formula cases');
  { type 13 → (13-12) shr 1 = 0 (empty blob) }
  Check('SerialTypeLen(13)=0', sqlite3VdbeSerialTypeLen(13) = 0);
  { type 14 → (14-12) shr 1 = 1 }
  Check('SerialTypeLen(14)=1', sqlite3VdbeSerialTypeLen(14) = 1);
  { type 15 → (15-12) shr 1 = 1 (1-byte string) }
  Check('SerialTypeLen(15)=1', sqlite3VdbeSerialTypeLen(15) = 1);
  { type 20 → (20-12) shr 1 = 4 }
  Check('SerialTypeLen(20)=4', sqlite3VdbeSerialTypeLen(20) = 4);
  { type 127 → (127-12) shr 1 = 57 }
  Check('SerialTypeLen(127)=57', sqlite3VdbeSerialTypeLen(127) = 57);
  { type 256 → (256-12) shr 1 = 122 }
  Check('SerialTypeLen(256)=122', sqlite3VdbeSerialTypeLen(256) = 122);

  WriteLn('T3: sqlite3VdbeOneByteSerialTypeLen');
  Check('OneByte(0)=0',  sqlite3VdbeOneByteSerialTypeLen(0)  = 0);
  Check('OneByte(1)=1',  sqlite3VdbeOneByteSerialTypeLen(1)  = 1);
  Check('OneByte(6)=8',  sqlite3VdbeOneByteSerialTypeLen(6)  = 8);
  Check('OneByte(7)=8',  sqlite3VdbeOneByteSerialTypeLen(7)  = 8);
  { type 20 → (20-12) shr 1 = 4 }
  Check('OneByte(20)=4', sqlite3VdbeOneByteSerialTypeLen(20) = 4);
end;

{ ===== T4-T9: sqlite3VdbeSerialGet ========================================= }

procedure TestSerialGet;
var
  mem: TMem;
  buf: array[0..15] of u8;
  blobData: array[0..3] of u8;
begin
  FillChar(mem, SizeOf(mem), 0);
  FillChar(buf, SizeOf(buf), 0);

  { T4: NULL }
  WriteLn('T4: sqlite3VdbeSerialGet NULL (type 0)');
  sqlite3VdbeSerialGet(@buf[0], 0, @mem);
  Check('NULL: flags=MEM_Null', (mem.flags and MEM_Null) <> 0);
  Check('NULL: not MEM_Int',    (mem.flags and MEM_Int)  =  0);

  { T5: integer types 1-6 }
  WriteLn('T5: sqlite3VdbeSerialGet integers (types 1-6)');

  { type 1: 8-bit signed — value 42 }
  buf[0] := 42;
  sqlite3VdbeSerialGet(@buf[0], 1, @mem);
  Check('Int1: flags=MEM_Int', (mem.flags and MEM_Int) <> 0);
  Check('Int1: value=42',      mem.u.i = 42);

  { type 1: negative — value -1 = $FF as u8 }
  buf[0] := $FF;
  sqlite3VdbeSerialGet(@buf[0], 1, @mem);
  Check('Int1: value=-1', mem.u.i = -1);

  { type 2: 16-bit big-endian — $0102 = 258 }
  buf[0] := 1; buf[1] := 2;
  sqlite3VdbeSerialGet(@buf[0], 2, @mem);
  Check('Int2: value=258', mem.u.i = 258);

  { type 4: 32-bit big-endian — $00010000 = 65536 }
  buf[0] := 0; buf[1] := 1; buf[2] := 0; buf[3] := 0;
  sqlite3VdbeSerialGet(@buf[0], 4, @mem);
  Check('Int4: value=65536', mem.u.i = 65536);

  { type 6: 64-bit big-endian — value $0000000100000000 = 4294967296 }
  buf[0] := 0; buf[1] := 0; buf[2] := 0; buf[3] := 1;
  buf[4] := 0; buf[5] := 0; buf[6] := 0; buf[7] := 0;
  sqlite3VdbeSerialGet(@buf[0], 6, @mem);
  Check('Int6: value=4294967296', mem.u.i = 4294967296);

  { T6: integer constants 8 and 9 }
  WriteLn('T6: sqlite3VdbeSerialGet integer constants 8,9');
  sqlite3VdbeSerialGet(@buf[0], 8, @mem);
  Check('Const8: value=0', mem.u.i = 0);
  Check('Const8: MEM_Int', (mem.flags and MEM_Int) <> 0);

  sqlite3VdbeSerialGet(@buf[0], 9, @mem);
  Check('Const9: value=1', mem.u.i = 1);
  Check('Const9: MEM_Int', (mem.flags and MEM_Int) <> 0);

  { T7: float type 7 — IEEE 754 big-endian 1.0 = $3FF0000000000000 }
  WriteLn('T7: sqlite3VdbeSerialGet float (type 7)');
  buf[0] := $3F; buf[1] := $F0;
  buf[2] := 0;   buf[3] := 0;
  buf[4] := 0;   buf[5] := 0;
  buf[6] := 0;   buf[7] := 0;
  sqlite3VdbeSerialGet(@buf[0], 7, @mem);
  Check('Float7: MEM_Real', (mem.flags and MEM_Real) <> 0);
  Check('Float7: value=1.0', mem.u.r = 1.0);

  { T8: blob — serial type 14 = (14-12)/2 = 1 byte blob }
  WriteLn('T8: sqlite3VdbeSerialGet blob (type 14)');
  blobData[0] := $AB;
  sqlite3VdbeSerialGet(@blobData[0], 14, @mem);
  Check('Blob14: MEM_Blob',  (mem.flags and MEM_Blob) <> 0);
  Check('Blob14: MEM_Ephem', (mem.flags and MEM_Ephem) <> 0);
  Check('Blob14: n=1',       mem.n = 1);
  Check('Blob14: z points to buf', mem.z = PAnsiChar(@blobData[0]));

  { T9: string — serial type 15 = (15-12)/2 = 1 byte string (odd → text) }
  WriteLn('T9: sqlite3VdbeSerialGet string (type 15)');
  blobData[0] := Ord('A');
  sqlite3VdbeSerialGet(@blobData[0], 15, @mem);
  Check('Str15: MEM_Str',   (mem.flags and MEM_Str)  <> 0);
  Check('Str15: MEM_Ephem', (mem.flags and MEM_Ephem) <> 0);
  Check('Str15: n=1',       mem.n = 1);
end;

{ ===== T10-T12: sqlite3VdbeSerialPut round-trip ============================ }

procedure TestSerialPut;
var
  memIn, memOut: TMem;
  buf: array[0..15] of u8;
  blobSrc: array[0..3] of u8;
  written: u32;
  pLen: u32;
  stype: u32;
begin
  FillChar(memIn,  SizeOf(memIn),  0);
  FillChar(memOut, SizeOf(memOut), 0);
  FillChar(buf,    SizeOf(buf),    0);

  { T10: integer round-trip }
  WriteLn('T10: sqlite3VdbeSerialPut integer round-trip');
  memIn.u.i  := 12345;
  memIn.flags := MEM_Int;
  stype := sqlite3VdbeSerialType(@memIn, 4, @pLen);
  { 12345 fits in 16 bits → type 2, len 2 }
  Check('IntPut: type=2', stype = 2);
  written := sqlite3VdbeSerialPut(@buf[0], @memIn, stype);
  Check('IntPut: wrote 2 bytes', written = 2);
  sqlite3VdbeSerialGet(@buf[0], stype, @memOut);
  Check('IntPut: round-trip value', memOut.u.i = 12345);
  Check('IntPut: round-trip flags', (memOut.flags and MEM_Int) <> 0);

  { T11: float round-trip }
  WriteLn('T11: sqlite3VdbeSerialPut float round-trip');
  FillChar(memIn, SizeOf(memIn), 0);
  memIn.u.r  := 3.14159265358979;
  memIn.flags := MEM_Real;
  stype := sqlite3VdbeSerialType(@memIn, 4, @pLen);
  Check('FloatPut: type=7', stype = 7);
  written := sqlite3VdbeSerialPut(@buf[0], @memIn, stype);
  Check('FloatPut: wrote 8 bytes', written = 8);
  sqlite3VdbeSerialGet(@buf[0], stype, @memOut);
  Check('FloatPut: MEM_Real', (memOut.flags and MEM_Real) <> 0);
  Check('FloatPut: round-trip value', Abs(memOut.u.r - 3.14159265358979) < 1e-12);

  { T12: blob round-trip }
  WriteLn('T12: sqlite3VdbeSerialPut blob round-trip');
  FillChar(memIn, SizeOf(memIn), 0);
  blobSrc[0] := $DE; blobSrc[1] := $AD; blobSrc[2] := $BE; blobSrc[3] := $EF;
  memIn.z     := PAnsiChar(@blobSrc[0]);
  memIn.n     := 4;
  memIn.flags := MEM_Blob;
  stype := sqlite3VdbeSerialType(@memIn, 4, @pLen);
  { 4-byte blob: type = 4*2+12 = 20, len = 4 }
  Check('BlobPut: type=20', stype = 20);
  Check('BlobPut: pLen=4',  pLen  = 4);
  written := sqlite3VdbeSerialPut(@buf[0], @memIn, stype);
  Check('BlobPut: wrote 4 bytes', written = 4);
  sqlite3VdbeSerialGet(@buf[0], stype, @memOut);
  Check('BlobPut: MEM_Blob',  (memOut.flags and MEM_Blob) <> 0);
  Check('BlobPut: n=4',       memOut.n = 4);
  Check('BlobPut: byte[0]=$DE', u8(memOut.z[0]) = $DE);
  Check('BlobPut: byte[3]=$EF', u8(memOut.z[3]) = $EF);
end;

{ ===== T13-T16: sqlite3VdbeSerialType ====================================== }

procedure TestSerialType;
var
  mem: TMem;
  pLen: u32;
  stype: u32;
  blobSrc: array[0..9] of u8;
begin
  FillChar(mem, SizeOf(mem), 0);

  { T13: NULL }
  WriteLn('T13: sqlite3VdbeSerialType NULL');
  mem.flags := MEM_Null;
  stype := sqlite3VdbeSerialType(@mem, 4, @pLen);
  Check('SerialType NULL: type=0', stype = 0);
  Check('SerialType NULL: len=0',  pLen  = 0);

  { T14: integer ranges }
  WriteLn('T14: sqlite3VdbeSerialType integer ranges');
  mem.flags := MEM_Int;

  { constants 0,1 with file_format >= 4 → types 8,9 }
  mem.u.i := 0;
  stype := sqlite3VdbeSerialType(@mem, 4, @pLen);
  Check('SerialType i=0,ff=4: type=8', stype = 8);
  Check('SerialType i=0,ff=4: len=0',  pLen  = 0);

  mem.u.i := 1;
  stype := sqlite3VdbeSerialType(@mem, 4, @pLen);
  Check('SerialType i=1,ff=4: type=9', stype = 9);

  { 0 with file_format < 4 → type 1 }
  mem.u.i := 0;
  stype := sqlite3VdbeSerialType(@mem, 3, @pLen);
  Check('SerialType i=0,ff=3: type=1', stype = 1);
  Check('SerialType i=0,ff=3: len=1',  pLen  = 1);

  { 127 → fits in 1 byte (i8), type=1 }
  mem.u.i := 127;
  stype := sqlite3VdbeSerialType(@mem, 4, @pLen);
  Check('SerialType i=127: type=1', stype = 1);

  { 128 → needs 2 bytes, type=2 }
  mem.u.i := 128;
  stype := sqlite3VdbeSerialType(@mem, 4, @pLen);
  Check('SerialType i=128: type=2', stype = 2);

  { 32767 → type 2 }
  mem.u.i := 32767;
  stype := sqlite3VdbeSerialType(@mem, 4, @pLen);
  Check('SerialType i=32767: type=2', stype = 2);

  { 32768 → needs 3 bytes, type=3 }
  mem.u.i := 32768;
  stype := sqlite3VdbeSerialType(@mem, 4, @pLen);
  Check('SerialType i=32768: type=3', stype = 3);

  { 2147483647 → type 4 }
  mem.u.i := 2147483647;
  stype := sqlite3VdbeSerialType(@mem, 4, @pLen);
  Check('SerialType i=MaxInt32: type=4', stype = 4);

  { 2147483648 → type 5 (6 bytes) }
  mem.u.i := 2147483648;
  stype := sqlite3VdbeSerialType(@mem, 4, @pLen);
  Check('SerialType i=2^31: type=5', stype = 5);

  { $7FFFFFFFFFFF (max 6-byte) → type 5 }
  mem.u.i := i64($00007FFFFFFFFFFF);
  stype := sqlite3VdbeSerialType(@mem, 4, @pLen);
  Check('SerialType i=MAX_6BYTE: type=5', stype = 5);

  { $7FFFFFFFFFFF+1 = $0000800000000000 → type 6 (8 bytes) }
  mem.u.i := i64($0000800000000000);
  stype := sqlite3VdbeSerialType(@mem, 4, @pLen);
  Check('SerialType i=MAX_6BYTE+1: type=6', stype = 6);

  { T15: real → type 7 }
  WriteLn('T15: sqlite3VdbeSerialType real');
  mem.flags := MEM_Real;
  mem.u.r   := 2.718281828;
  stype := sqlite3VdbeSerialType(@mem, 4, @pLen);
  Check('SerialType real: type=7', stype = 7);
  Check('SerialType real: len=8',  pLen  = 8);

  { T16: blob / string → formula }
  WriteLn('T16: sqlite3VdbeSerialType blob/string formula');
  FillChar(blobSrc, SizeOf(blobSrc), $AB);
  mem.z     := PAnsiChar(@blobSrc[0]);

  { 0-byte blob → type 12 }
  mem.flags := MEM_Blob; mem.n := 0;
  stype := sqlite3VdbeSerialType(@mem, 4, @pLen);
  Check('SerialType blob0: type=12', stype = 12);
  Check('SerialType blob0: len=0',   pLen  = 0);

  { 1-byte blob → type 14 (even = blob) }
  mem.n := 1;
  stype := sqlite3VdbeSerialType(@mem, 4, @pLen);
  Check('SerialType blob1: type=14', stype = 14);
  Check('SerialType blob1: len=1',   pLen  = 1);

  { 1-byte string → type 15 (odd = string) }
  mem.flags := MEM_Str; mem.n := 1;
  stype := sqlite3VdbeSerialType(@mem, 4, @pLen);
  Check('SerialType str1: type=15', stype = 15);

  { 5-byte blob → type 22 }
  mem.flags := MEM_Blob; mem.n := 5;
  stype := sqlite3VdbeSerialType(@mem, 4, @pLen);
  Check('SerialType blob5: type=22', stype = 22);
  Check('SerialType blob5: len=5',   pLen  = 5);
end;

{ ===== T17: VDBE AddOp with mock Parse ===================================== }

{
  The Parse struct layout (GCC x86-64, SQLite 3.53.0):
    offset   0: Psqlite3 db       (8 bytes)
    offset   8: <other fields>
    offset  16: PVdbe pVdbe       (8 bytes)
    offset  24: <other fields>
    offset  31: u8 nTempReg
    offset  44: i32 nRangeReg
    offset  64: i32 szOpAlloc
    offset  72: i32 nLabel
    offset  76: i32 nLabelAlloc
    offset  80: Pi32 aLabel       (8 bytes)
    total used: at least 88 bytes → allocate 256

  The sqlite3 struct layout (GCC x86-64):
    offset 103: u8 mallocFailed
    offset 136: i32[13] aLimit    (aLimit[5]=SQLITE_LIMIT_VDBE_OP at offset 156)
    total used: at least 200 bytes → allocate 256
}

procedure TestAddOp;
const
  PARSE_SZ = 256;
  DB_SZ    = 256;
var
  parseBuf: array[0..PARSE_SZ-1] of Byte;
  dbBuf:    array[0..DB_SZ-1]    of Byte;
  pParse:   Pointer;
  pDb:      Pointer;
  v:        PVdbe;
  pOp:      PVdbeOp;
begin
  WriteLn('T17: sqlite3VdbeAddOp — mock Parse/sqlite3 program assembly');
  FillChar(parseBuf, SizeOf(parseBuf), 0);
  FillChar(dbBuf,    SizeOf(dbBuf),    0);

  pParse := @parseBuf[0];
  pDb    := @dbBuf[0];

  { Wire up Parse.db = pDb (Parse.db at offset 0) }
  PPointer(pParse)^ := pDb;

  { Set SQLITE_LIMIT_VDBE_OP (aLimit[5]) to a sane value (e.g. 250000000) }
  Pi32(PByte(pDb) + 156)^ := 250000000;

  { mallocFailed = 0 (already 0 from FillChar) }

  { Create the VDBE — sqlite3VdbeCreate adds one OP_Init automatically }
  v := sqlite3VdbeCreate(pParse);
  Check('VdbeCreate: not nil', v <> nil);
  if v = nil then Exit;

  Check('VdbeCreate: nOp=1 (OP_Init)',       v^.nOp = 1);
  Check('VdbeCreate: aOp[0]=OP_Init',        v^.aOp[0].opcode = OP_Init);
  Check('VdbeCreate: eVdbeState=INIT_STATE', v^.eVdbeState = VDBE_INIT_STATE);

  { Add OP_Goto 0, 99, 0 }
  sqlite3VdbeAddOp2(v, OP_Goto, 0, 99);
  Check('AddOp2: nOp=2', v^.nOp = 2);
  pOp := @v^.aOp[1];
  Check('AddOp2: opcode=OP_Goto',   pOp^.opcode = OP_Goto);
  Check('AddOp2: p1=0',             pOp^.p1     = 0);
  Check('AddOp2: p2=99',            pOp^.p2     = 99);
  Check('AddOp2: p3=0',             pOp^.p3     = 0);
  Check('AddOp2: p5=0',             pOp^.p5     = 0);
  Check('AddOp2: p4type=P4_NOTUSED',pOp^.p4type = P4_NOTUSED);

  { Add OP_Integer 42, 1, 0 }
  sqlite3VdbeAddOp3(v, OP_Integer, 42, 1, 0);
  Check('AddOp3: nOp=3', v^.nOp = 3);
  pOp := @v^.aOp[2];
  Check('AddOp3: opcode=OP_Integer', pOp^.opcode = OP_Integer);
  Check('AddOp3: p1=42',             pOp^.p1     = 42);
  Check('AddOp3: p2=1',              pOp^.p2     = 1);

  { AddOp4Int: OP_SeekGE with p4 int }
  sqlite3VdbeAddOp4Int(v, OP_SeekGE, 0, 10, 1, 5);
  Check('AddOp4Int: nOp=4', v^.nOp = 4);
  pOp := @v^.aOp[3];
  Check('AddOp4Int: opcode=OP_SeekGE', pOp^.opcode = OP_SeekGE);
  Check('AddOp4Int: p4type=P4_INT32',  pOp^.p4type = P4_INT32);
  Check('AddOp4Int: p4.i=5',           pOp^.p4.i   = 5);

  { VdbeCurrentAddr: should be 4 (index of next instruction) }
  Check('CurrentAddr=4', sqlite3VdbeCurrentAddr(v) = 4);

  { ChangeP2: modify p2 of instruction 1 (OP_Goto) }
  sqlite3VdbeChangeP2(v, 1, 200);
  Check('ChangeP2: aOp[1].p2=200', v^.aOp[1].p2 = 200);

  { GetOp: retrieve a specific op }
  pOp := sqlite3VdbeGetOp(v, 0);
  Check('GetOp(0)=OP_Init', pOp^.opcode = OP_Init);
  pOp := sqlite3VdbeGetOp(v, 2);
  Check('GetOp(2)=OP_Integer', pOp^.opcode = OP_Integer);

  { GetLastOp }
  pOp := sqlite3VdbeGetLastOp(v);
  Check('GetLastOp=OP_SeekGE', pOp^.opcode = OP_SeekGE);

  { Clean up }
  sqlite3VdbeDelete(v);
end;

{ ===== main ================================================================= }

begin
  WriteLn('=== TestVdbeAux — Phase 5.2 gate test ===');
  WriteLn;

  TestSerialTypeLen;
  WriteLn;
  TestSerialGet;
  WriteLn;
  TestSerialPut;
  WriteLn;
  TestSerialType;
  WriteLn;
  TestAddOp;
  WriteLn;

  WriteLn('=== Results: PASS=', gPass, ' FAIL=', gFail, ' ===');
  if gFail > 0 then Halt(1);
end.
