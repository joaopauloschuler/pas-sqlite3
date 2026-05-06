{
  SPDX-License-Identifier: blessing

  Faithful port of ../sqlite3/ext/misc/shathree.c (854 lines in C).

  Implements the SQL functions sha3(X[,SIZE]), sha3_agg(Y[,SIZE]),
  sha3_query(SQL[,SIZE]) per the upstream extension.  The Keccak-f[1600]
  permutation, byte-order handling, and SHA3 padding rules are mirrored
  1:1 from the C source so the produced hashes are byte-identical.

  Phase 10.1.52 — wiring into passqlite3shell so `.sha3sum` works.
  Public entry: sqlite3ShathreeInit(db) — equivalent to
  sqlite3_shathree_init() in C; safe to call multiple times.
}
{$I passqlite3.inc}
unit passqlite3shathree;

interface

uses
  passqlite3types,
  passqlite3util,
  passqlite3vdbe,
  passqlite3main;

function sqlite3ShathreeInit(db: PTsqlite3): i32;

implementation

uses
  SysUtils,
  passqlite3printf;

type
  { C uses a union { u64 s[25]; unsigned char x[1600]; } u — the 1600-byte
    sizing is required because SHA3Final stores the squeezed digest at
    u.x[nRate..2*nRate-1], which for sha3-224/256 spills past the 200-byte
    Keccak lane footprint.  Pascal lacks `union`, so we lay out a single
    1600-byte buffer and view the first 200 bytes as a u64 lane array via
    a `case` variant. }
  TSHA3State = packed record
    case Integer of
      0: (s: array[0..24] of u64);
      1: (x: array[0..1599] of Byte);
  end;
  PSHA3State = ^TSHA3State;

  TSHA3Context = record
    u: TSHA3State;              { 1600-bit Keccak state }
    nRate: u32;                 { bytes accepted per Keccak iteration }
    nLoaded: u32;               { input bytes loaded so far this cycle }
    ixMask: u32;                { byte-order mask (0 little, 7 big) }
    iSize: u32;                 { 224 / 256 / 384 / 512 }
  end;
  PSHA3Context = ^TSHA3Context;

const
  KeccakRC: array[0..23] of u64 = (
    u64($0000000000000001), u64($0000000000008082),
    u64($800000000000808a), u64($8000000080008000),
    u64($000000000000808b), u64($0000000080000001),
    u64($8000000080008081), u64($8000000000008009),
    u64($000000000000008a), u64($0000000000000088),
    u64($0000000080008009), u64($000000008000000a),
    u64($000000008000808b), u64($800000000000008b),
    u64($8000000000008089), u64($8000000000008003),
    u64($8000000000008002), u64($8000000000000080),
    u64($000000000000800a), u64($800000008000000a),
    u64($8000000080008081), u64($8000000000008080),
    u64($0000000080000001), u64($8000000080008008)
  );

function ROL64(a: u64; x: Integer): u64; inline;
begin
  Result := (a shl x) or (a shr (64 - x));
end;

{ Single Keccak-F[1600] permutation.  Direct line-for-line port of
  KeccakF1600Step (shathree.c:156..471) — the unrolled four-rounds-per-
  iteration body uses the same temporary names (a00..a44, b0..b4, c0..c4,
  d0..d4) as the C reference. }
procedure KeccakF1600Step(p: PSHA3Context);
var
  i: Integer;
  b0, b1, b2, b3, b4: u64;
  c0, c1, c2, c3, c4: u64;
  d0, d1, d2, d3, d4: u64;
  s: PSHA3State;
begin
  s := @p^.u;
  i := 0;
  while i < 24 do
  begin
    c0 := s^.s[0]  xor s^.s[5]  xor s^.s[10] xor s^.s[15] xor s^.s[20];
    c1 := s^.s[1]  xor s^.s[6]  xor s^.s[11] xor s^.s[16] xor s^.s[21];
    c2 := s^.s[2]  xor s^.s[7]  xor s^.s[12] xor s^.s[17] xor s^.s[22];
    c3 := s^.s[3]  xor s^.s[8]  xor s^.s[13] xor s^.s[18] xor s^.s[23];
    c4 := s^.s[4]  xor s^.s[9]  xor s^.s[14] xor s^.s[19] xor s^.s[24];
    d0 := c4 xor ROL64(c1, 1);
    d1 := c0 xor ROL64(c2, 1);
    d2 := c1 xor ROL64(c3, 1);
    d3 := c2 xor ROL64(c4, 1);
    d4 := c3 xor ROL64(c0, 1);

    b0 := s^.s[0]  xor d0;
    b1 := ROL64(s^.s[6]  xor d1, 44);
    b2 := ROL64(s^.s[12] xor d2, 43);
    b3 := ROL64(s^.s[18] xor d3, 21);
    b4 := ROL64(s^.s[24] xor d4, 14);
    s^.s[0]  := (b0 xor ((not b1) and b2)) xor KeccakRC[i];
    s^.s[6]  := b1 xor ((not b2) and b3);
    s^.s[12] := b2 xor ((not b3) and b4);
    s^.s[18] := b3 xor ((not b4) and b0);
    s^.s[24] := b4 xor ((not b0) and b1);

    b2 := ROL64(s^.s[10] xor d0, 3);
    b3 := ROL64(s^.s[16] xor d1, 45);
    b4 := ROL64(s^.s[22] xor d2, 61);
    b0 := ROL64(s^.s[3]  xor d3, 28);
    b1 := ROL64(s^.s[9]  xor d4, 20);
    s^.s[10] := b0 xor ((not b1) and b2);
    s^.s[16] := b1 xor ((not b2) and b3);
    s^.s[22] := b2 xor ((not b3) and b4);
    s^.s[3]  := b3 xor ((not b4) and b0);
    s^.s[9]  := b4 xor ((not b0) and b1);

    b4 := ROL64(s^.s[20] xor d0, 18);
    b0 := ROL64(s^.s[1]  xor d1, 1);
    b1 := ROL64(s^.s[7]  xor d2, 6);
    b2 := ROL64(s^.s[13] xor d3, 25);
    b3 := ROL64(s^.s[19] xor d4, 8);
    s^.s[20] := b0 xor ((not b1) and b2);
    s^.s[1]  := b1 xor ((not b2) and b3);
    s^.s[7]  := b2 xor ((not b3) and b4);
    s^.s[13] := b3 xor ((not b4) and b0);
    s^.s[19] := b4 xor ((not b0) and b1);

    b1 := ROL64(s^.s[5]  xor d0, 36);
    b2 := ROL64(s^.s[11] xor d1, 10);
    b3 := ROL64(s^.s[17] xor d2, 15);
    b4 := ROL64(s^.s[23] xor d3, 56);
    b0 := ROL64(s^.s[4]  xor d4, 27);
    s^.s[5]  := b0 xor ((not b1) and b2);
    s^.s[11] := b1 xor ((not b2) and b3);
    s^.s[17] := b2 xor ((not b3) and b4);
    s^.s[23] := b3 xor ((not b4) and b0);
    s^.s[4]  := b4 xor ((not b0) and b1);

    b3 := ROL64(s^.s[15] xor d0, 41);
    b4 := ROL64(s^.s[21] xor d1, 2);
    b0 := ROL64(s^.s[2]  xor d2, 62);
    b1 := ROL64(s^.s[8]  xor d3, 55);
    b2 := ROL64(s^.s[14] xor d4, 39);
    s^.s[15] := b0 xor ((not b1) and b2);
    s^.s[21] := b1 xor ((not b2) and b3);
    s^.s[2]  := b2 xor ((not b3) and b4);
    s^.s[8]  := b3 xor ((not b4) and b0);
    s^.s[14] := b4 xor ((not b0) and b1);

    { ---- Round i+1: lane permutation as in C (shathree.c:270..) ---- }
    c0 := s^.s[0]  xor s^.s[10] xor s^.s[20] xor s^.s[5]  xor s^.s[15];
    c1 := s^.s[6]  xor s^.s[16] xor s^.s[1]  xor s^.s[11] xor s^.s[21];
    c2 := s^.s[12] xor s^.s[22] xor s^.s[7]  xor s^.s[17] xor s^.s[2];
    c3 := s^.s[18] xor s^.s[3]  xor s^.s[13] xor s^.s[23] xor s^.s[8];
    c4 := s^.s[24] xor s^.s[9]  xor s^.s[19] xor s^.s[4]  xor s^.s[14];
    d0 := c4 xor ROL64(c1, 1);
    d1 := c0 xor ROL64(c2, 1);
    d2 := c1 xor ROL64(c3, 1);
    d3 := c2 xor ROL64(c4, 1);
    d4 := c3 xor ROL64(c0, 1);

    b0 := s^.s[0]  xor d0;
    b1 := ROL64(s^.s[16] xor d1, 44);
    b2 := ROL64(s^.s[7]  xor d2, 43);
    b3 := ROL64(s^.s[23] xor d3, 21);
    b4 := ROL64(s^.s[14] xor d4, 14);
    s^.s[0]  := (b0 xor ((not b1) and b2)) xor KeccakRC[i+1];
    s^.s[16] := b1 xor ((not b2) and b3);
    s^.s[7]  := b2 xor ((not b3) and b4);
    s^.s[23] := b3 xor ((not b4) and b0);
    s^.s[14] := b4 xor ((not b0) and b1);

    b2 := ROL64(s^.s[20] xor d0, 3);
    b3 := ROL64(s^.s[11] xor d1, 45);
    b4 := ROL64(s^.s[2]  xor d2, 61);
    b0 := ROL64(s^.s[18] xor d3, 28);
    b1 := ROL64(s^.s[9]  xor d4, 20);
    s^.s[20] := b0 xor ((not b1) and b2);
    s^.s[11] := b1 xor ((not b2) and b3);
    s^.s[2]  := b2 xor ((not b3) and b4);
    s^.s[18] := b3 xor ((not b4) and b0);
    s^.s[9]  := b4 xor ((not b0) and b1);

    b4 := ROL64(s^.s[15] xor d0, 18);
    b0 := ROL64(s^.s[6]  xor d1, 1);
    b1 := ROL64(s^.s[22] xor d2, 6);
    b2 := ROL64(s^.s[13] xor d3, 25);
    b3 := ROL64(s^.s[4]  xor d4, 8);
    s^.s[15] := b0 xor ((not b1) and b2);
    s^.s[6]  := b1 xor ((not b2) and b3);
    s^.s[22] := b2 xor ((not b3) and b4);
    s^.s[13] := b3 xor ((not b4) and b0);
    s^.s[4]  := b4 xor ((not b0) and b1);

    b1 := ROL64(s^.s[10] xor d0, 36);
    b2 := ROL64(s^.s[1]  xor d1, 10);
    b3 := ROL64(s^.s[17] xor d2, 15);
    b4 := ROL64(s^.s[8]  xor d3, 56);
    b0 := ROL64(s^.s[24] xor d4, 27);
    s^.s[10] := b0 xor ((not b1) and b2);
    s^.s[1]  := b1 xor ((not b2) and b3);
    s^.s[17] := b2 xor ((not b3) and b4);
    s^.s[8]  := b3 xor ((not b4) and b0);
    s^.s[24] := b4 xor ((not b0) and b1);

    b3 := ROL64(s^.s[5]  xor d0, 41);
    b4 := ROL64(s^.s[21] xor d1, 2);
    b0 := ROL64(s^.s[12] xor d2, 62);
    b1 := ROL64(s^.s[3]  xor d3, 55);
    b2 := ROL64(s^.s[19] xor d4, 39);
    s^.s[5]  := b0 xor ((not b1) and b2);
    s^.s[21] := b1 xor ((not b2) and b3);
    s^.s[12] := b2 xor ((not b3) and b4);
    s^.s[3]  := b3 xor ((not b4) and b0);
    s^.s[19] := b4 xor ((not b0) and b1);

    { ---- Round i+2 ---- }
    c0 := s^.s[0]  xor s^.s[20] xor s^.s[15] xor s^.s[10] xor s^.s[5];
    c1 := s^.s[16] xor s^.s[11] xor s^.s[6]  xor s^.s[1]  xor s^.s[21];
    c2 := s^.s[7]  xor s^.s[2]  xor s^.s[22] xor s^.s[17] xor s^.s[12];
    c3 := s^.s[23] xor s^.s[18] xor s^.s[13] xor s^.s[8]  xor s^.s[3];
    c4 := s^.s[14] xor s^.s[9]  xor s^.s[4]  xor s^.s[24] xor s^.s[19];
    d0 := c4 xor ROL64(c1, 1);
    d1 := c0 xor ROL64(c2, 1);
    d2 := c1 xor ROL64(c3, 1);
    d3 := c2 xor ROL64(c4, 1);
    d4 := c3 xor ROL64(c0, 1);

    b0 := s^.s[0]  xor d0;
    b1 := ROL64(s^.s[11] xor d1, 44);
    b2 := ROL64(s^.s[22] xor d2, 43);
    b3 := ROL64(s^.s[8]  xor d3, 21);
    b4 := ROL64(s^.s[19] xor d4, 14);
    s^.s[0]  := (b0 xor ((not b1) and b2)) xor KeccakRC[i+2];
    s^.s[11] := b1 xor ((not b2) and b3);
    s^.s[22] := b2 xor ((not b3) and b4);
    s^.s[8]  := b3 xor ((not b4) and b0);
    s^.s[19] := b4 xor ((not b0) and b1);

    b2 := ROL64(s^.s[15] xor d0, 3);
    b3 := ROL64(s^.s[1]  xor d1, 45);
    b4 := ROL64(s^.s[12] xor d2, 61);
    b0 := ROL64(s^.s[23] xor d3, 28);
    b1 := ROL64(s^.s[9]  xor d4, 20);
    s^.s[15] := b0 xor ((not b1) and b2);
    s^.s[1]  := b1 xor ((not b2) and b3);
    s^.s[12] := b2 xor ((not b3) and b4);
    s^.s[23] := b3 xor ((not b4) and b0);
    s^.s[9]  := b4 xor ((not b0) and b1);

    b4 := ROL64(s^.s[5]  xor d0, 18);
    b0 := ROL64(s^.s[16] xor d1, 1);
    b1 := ROL64(s^.s[2]  xor d2, 6);
    b2 := ROL64(s^.s[13] xor d3, 25);
    b3 := ROL64(s^.s[24] xor d4, 8);
    s^.s[5]  := b0 xor ((not b1) and b2);
    s^.s[16] := b1 xor ((not b2) and b3);
    s^.s[2]  := b2 xor ((not b3) and b4);
    s^.s[13] := b3 xor ((not b4) and b0);
    s^.s[24] := b4 xor ((not b0) and b1);

    b1 := ROL64(s^.s[20] xor d0, 36);
    b2 := ROL64(s^.s[6]  xor d1, 10);
    b3 := ROL64(s^.s[17] xor d2, 15);
    b4 := ROL64(s^.s[3]  xor d3, 56);
    b0 := ROL64(s^.s[14] xor d4, 27);
    s^.s[20] := b0 xor ((not b1) and b2);
    s^.s[6]  := b1 xor ((not b2) and b3);
    s^.s[17] := b2 xor ((not b3) and b4);
    s^.s[3]  := b3 xor ((not b4) and b0);
    s^.s[14] := b4 xor ((not b0) and b1);

    b3 := ROL64(s^.s[10] xor d0, 41);
    b4 := ROL64(s^.s[21] xor d1, 2);
    b0 := ROL64(s^.s[7]  xor d2, 62);
    b1 := ROL64(s^.s[18] xor d3, 55);
    b2 := ROL64(s^.s[4]  xor d4, 39);
    s^.s[10] := b0 xor ((not b1) and b2);
    s^.s[21] := b1 xor ((not b2) and b3);
    s^.s[7]  := b2 xor ((not b3) and b4);
    s^.s[18] := b3 xor ((not b4) and b0);
    s^.s[4]  := b4 xor ((not b0) and b1);

    { ---- Round i+3 ---- }
    c0 := s^.s[0]  xor s^.s[15] xor s^.s[5]  xor s^.s[20] xor s^.s[10];
    c1 := s^.s[11] xor s^.s[1]  xor s^.s[16] xor s^.s[6]  xor s^.s[21];
    c2 := s^.s[22] xor s^.s[12] xor s^.s[2]  xor s^.s[17] xor s^.s[7];
    c3 := s^.s[8]  xor s^.s[23] xor s^.s[13] xor s^.s[3]  xor s^.s[18];
    c4 := s^.s[19] xor s^.s[4]  xor s^.s[24] xor s^.s[14] xor s^.s[9];
    d0 := c4 xor ROL64(c1, 1);
    d1 := c0 xor ROL64(c2, 1);
    d2 := c1 xor ROL64(c3, 1);
    d3 := c2 xor ROL64(c4, 1);
    d4 := c3 xor ROL64(c0, 1);

    b0 := s^.s[0]  xor d0;
    b1 := ROL64(s^.s[1]  xor d1, 44);
    b2 := ROL64(s^.s[2]  xor d2, 43);
    b3 := ROL64(s^.s[3]  xor d3, 21);
    b4 := ROL64(s^.s[4]  xor d4, 14);
    s^.s[0] := (b0 xor ((not b1) and b2)) xor KeccakRC[i+3];
    s^.s[1] := b1 xor ((not b2) and b3);
    s^.s[2] := b2 xor ((not b3) and b4);
    s^.s[3] := b3 xor ((not b4) and b0);
    s^.s[4] := b4 xor ((not b0) and b1);

    b2 := ROL64(s^.s[5]  xor d0, 3);
    b3 := ROL64(s^.s[6]  xor d1, 45);
    b4 := ROL64(s^.s[7]  xor d2, 61);
    b0 := ROL64(s^.s[8]  xor d3, 28);
    b1 := ROL64(s^.s[9]  xor d4, 20);
    s^.s[5] := b0 xor ((not b1) and b2);
    s^.s[6] := b1 xor ((not b2) and b3);
    s^.s[7] := b2 xor ((not b3) and b4);
    s^.s[8] := b3 xor ((not b4) and b0);
    s^.s[9] := b4 xor ((not b0) and b1);

    b4 := ROL64(s^.s[10] xor d0, 18);
    b0 := ROL64(s^.s[11] xor d1, 1);
    b1 := ROL64(s^.s[12] xor d2, 6);
    b2 := ROL64(s^.s[13] xor d3, 25);
    b3 := ROL64(s^.s[14] xor d4, 8);
    s^.s[10] := b0 xor ((not b1) and b2);
    s^.s[11] := b1 xor ((not b2) and b3);
    s^.s[12] := b2 xor ((not b3) and b4);
    s^.s[13] := b3 xor ((not b4) and b0);
    s^.s[14] := b4 xor ((not b0) and b1);

    b1 := ROL64(s^.s[15] xor d0, 36);
    b2 := ROL64(s^.s[16] xor d1, 10);
    b3 := ROL64(s^.s[17] xor d2, 15);
    b4 := ROL64(s^.s[18] xor d3, 56);
    b0 := ROL64(s^.s[19] xor d4, 27);
    s^.s[15] := b0 xor ((not b1) and b2);
    s^.s[16] := b1 xor ((not b2) and b3);
    s^.s[17] := b2 xor ((not b3) and b4);
    s^.s[18] := b3 xor ((not b4) and b0);
    s^.s[19] := b4 xor ((not b0) and b1);

    b3 := ROL64(s^.s[20] xor d0, 41);
    b4 := ROL64(s^.s[21] xor d1, 2);
    b0 := ROL64(s^.s[22] xor d2, 62);
    b1 := ROL64(s^.s[23] xor d3, 55);
    b2 := ROL64(s^.s[24] xor d4, 39);
    s^.s[20] := b0 xor ((not b1) and b2);
    s^.s[21] := b1 xor ((not b2) and b3);
    s^.s[22] := b2 xor ((not b3) and b4);
    s^.s[23] := b3 xor ((not b4) and b0);
    s^.s[24] := b4 xor ((not b0) and b1);

    Inc(i, 4);
  end;
end;

procedure SHA3Init(p: PSHA3Context; iSize: Integer);
begin
  FillChar(p^, SizeOf(p^), 0);
  p^.iSize := iSize;
  if (iSize >= 128) and (iSize <= 512) then
    p^.nRate := (1600 - ((iSize + 31) and (not 31)) * 2) div 8
  else
    p^.nRate := (1600 - 2 * 256) div 8;
  { x86_64 is little-endian — the C code's compile-time SHA3_BYTEORDER==1234
    arm fixes ixMask=0; we hard-code the same. }
  p^.ixMask := 0;
end;

procedure SHA3Update(p: PSHA3Context; aData: PByte; nData: u32);
var
  i: u32;
  pBytes: PByte;
begin
  if (aData = nil) or (nData = 0) then Exit;
  i := 0;
  pBytes := PByte(@p^.u);
  { Fast path when nLoaded is 8-aligned: XOR a u64 at a time.  Mirrors
    shathree.c:516..525 (SHA3_BYTEORDER==1234 branch). }
  if (p^.nLoaded mod 8) = 0 then
  begin
    while i + 7 < nData do
    begin
      p^.u.s[p^.nLoaded div 8] := p^.u.s[p^.nLoaded div 8] xor PUInt64(@aData[i])^;
      Inc(p^.nLoaded, 8);
      Inc(i, 8);
      if p^.nLoaded >= p^.nRate then
      begin
        KeccakF1600Step(p);
        p^.nLoaded := 0;
      end;
    end;
  end;
  while i < nData do
  begin
    pBytes[p^.nLoaded] := pBytes[p^.nLoaded] xor aData[i];
    Inc(p^.nLoaded);
    Inc(i);
    if p^.nLoaded = p^.nRate then
    begin
      KeccakF1600Step(p);
      p^.nLoaded := 0;
    end;
  end;
end;

{ Pad and squeeze.  Returns a pointer to the (iSize/8)-byte digest stored
  at u.x[nRate..2*nRate-1].  Mirrors shathree.c:548..564. }
function SHA3Final(p: PSHA3Context): PByte;
var
  c1, c2, c3: Byte;
  i: u32;
  pBytes: PByte;
begin
  pBytes := PByte(@p^.u);
  if p^.nLoaded = p^.nRate - 1 then
  begin
    c1 := $86;
    SHA3Update(p, @c1, 1);
  end
  else
  begin
    c2 := $06;
    c3 := $80;
    SHA3Update(p, @c2, 1);
    p^.nLoaded := p^.nRate - 1;
    SHA3Update(p, @c3, 1);
  end;
  for i := 0 to p^.nRate - 1 do
    pBytes[i + p^.nRate] := pBytes[i xor p^.ixMask];
  Result := @pBytes[p^.nRate];
end;

{ ---- SQL-function wrappers ---- }

procedure sha3Func(pCtx: Psqlite3_context; argc: i32; argv: PPMem); cdecl;
var
  cx: TSHA3Context;
  eType: i32;
  nByte: i32;
  iSize: i32;
  pBlob: Pointer;
const
  zErrSize: PAnsiChar = 'SHA3 size should be one of: 224 256 384 512';
begin
  eType := sqlite3_value_type(argv[0]);
  if argc = 1 then iSize := 256
  else begin
    iSize := sqlite3_value_int(argv[1]);
    if (iSize <> 224) and (iSize <> 256) and (iSize <> 384) and (iSize <> 512) then
    begin sqlite3_result_error(pCtx, zErrSize, -1); Exit; end;
  end;
  if eType = SQLITE_NULL then Exit;
  nByte := sqlite3_value_bytes(argv[0]);
  SHA3Init(@cx, iSize);
  if eType = SQLITE_BLOB then
    pBlob := sqlite3_value_blob(argv[0])
  else
    pBlob := Pointer(sqlite3_value_text(argv[0]));
  SHA3Update(@cx, PByte(pBlob), u32(nByte));
  sqlite3_result_blob(pCtx, SHA3Final(@cx), iSize div 8, SQLITE_TRANSIENT);
end;

{ Append a sprintf-style header (e.g. 'T5:', 'B12:', 'S37:') of at most
  ~50 bytes to the running hash.  Used by sha3UpdateFromValue and
  sha3QueryFunc — mirrors sha3_step_vformat (shathree.c:609..622). }
procedure sha3StepLen(p: PSHA3Context; tag: AnsiChar; n: i32);
var
  zBuf: array[0..63] of AnsiChar;
  s: AnsiString;
  L: Integer;
begin
  s := tag + IntToStr(n) + ':';
  L := Length(s);
  if L > 63 then L := 63;
  Move(PAnsiChar(s)^, zBuf[0], L);
  SHA3Update(p, PByte(@zBuf[0]), L);
end;

procedure sha3UpdateFromValue(p: PSHA3Context; pVal: Psqlite3_value);
var
  v: i64;
  r: Double;
  u: u64;
  j: Integer;
  x: array[0..8] of Byte;
  n2: i32;
  z2: Pointer;
begin
  case sqlite3_value_type(pVal) of
    SQLITE_NULL:
      SHA3Update(p, PByte(PAnsiChar('N')), 1);
    SQLITE_INTEGER:
      begin
        v := sqlite3_value_int64(pVal);
        Move(v, u, 8);
        for j := 8 downto 1 do
        begin
          x[j] := u and $FF;
          u := u shr 8;
        end;
        x[0] := Ord('I');
        SHA3Update(p, @x[0], 9);
      end;
    SQLITE_FLOAT:
      begin
        r := sqlite3_value_double(pVal);
        Move(r, u, 8);
        for j := 8 downto 1 do
        begin
          x[j] := u and $FF;
          u := u shr 8;
        end;
        x[0] := Ord('F');
        SHA3Update(p, @x[0], 9);
      end;
    SQLITE_TEXT:
      begin
        n2 := sqlite3_value_bytes(pVal);
        z2 := Pointer(sqlite3_value_text(pVal));
        sha3StepLen(p, 'T', n2);
        SHA3Update(p, PByte(z2), u32(n2));
      end;
    SQLITE_BLOB:
      begin
        n2 := sqlite3_value_bytes(pVal);
        z2 := sqlite3_value_blob(pVal);
        sha3StepLen(p, 'B', n2);
        SHA3Update(p, PByte(z2), u32(n2));
      end;
  end;
end;

procedure sha3QueryFunc(pCtx: Psqlite3_context; argc: i32; argv: PPMem); cdecl;
var
  db: PTsqlite3;
  zSql: PAnsiChar;
  zTail: PAnsiChar;
  pStmt: Pointer;
  nCol, i, rc, n: i32;
  z: PAnsiChar;
  zMsg: PAnsiChar;
  cx: TSHA3Context;
  iSize: i32;
const
  zErrSize: PAnsiChar = 'SHA3 size should be one of: 224 256 384 512';
begin
  db := sqlite3_context_db_handle(pCtx);
  zSql := PAnsiChar(sqlite3_value_text(argv[0]));
  pStmt := nil;
  if argc = 1 then
    iSize := 256
  else
  begin
    iSize := sqlite3_value_int(argv[1]);
    if (iSize <> 224) and (iSize <> 256) and (iSize <> 384) and (iSize <> 512) then
    begin
      sqlite3_result_error(pCtx, zErrSize, -1);
      Exit;
    end;
  end;
  if zSql = nil then Exit;
  SHA3Init(@cx, iSize);
  while zSql^ <> #0 do
  begin
    zTail := nil;
    rc := sqlite3_prepare_v2(db, zSql, -1, @pStmt, @zTail);
    if rc <> SQLITE_OK then
    begin
      zMsg := PAnsiChar(sqlite3PfMprintf('error SQL statement [%s]: %s',
        [zSql, sqlite3_errmsg(db)]));
      sqlite3_finalize(PVdbe(pStmt));
      sqlite3_result_error(pCtx, zMsg, -1);
      Exit;
    end;
    if sqlite3_stmt_readonly(pStmt) = 0 then
    begin
      zMsg := PAnsiChar(sqlite3PfMprintf('non-query: [%s]',
        [sqlite3_sql(pStmt)]));
      sqlite3_finalize(PVdbe(pStmt));
      sqlite3_result_error(pCtx, zMsg, -1);
      Exit;
    end;
    nCol := sqlite3_column_count(pStmt);
    z := sqlite3_sql(pStmt);
    if z <> nil then
    begin
      n := i32(StrLen(z));
      sha3StepLen(@cx, 'S', n);
      SHA3Update(@cx, PByte(z), u32(n));
    end;
    while sqlite3_step(PVdbe(pStmt)) = SQLITE_ROW do
    begin
      SHA3Update(@cx, PByte(PAnsiChar('R')), 1);
      for i := 0 to nCol - 1 do
        sha3UpdateFromValue(@cx, sqlite3_column_value(PVdbe(pStmt), i));
    end;
    sqlite3_finalize(PVdbe(pStmt));
    zSql := zTail;
    if zSql = nil then break;
  end;
  sqlite3_result_blob(pCtx, SHA3Final(@cx), iSize div 8, SQLITE_TRANSIENT);
end;

procedure sha3AggStep(pCtx: Psqlite3_context; argc: i32; argv: PPMem); cdecl;
var
  p: PSHA3Context;
  sz: i32;
begin
  p := PSHA3Context(sqlite3_aggregate_context(pCtx, SizeOf(TSHA3Context)));
  if p = nil then Exit;
  if p^.nRate = 0 then
  begin
    sz := 256;
    if argc = 2 then
    begin
      sz := sqlite3_value_int(argv[1]);
      if (sz <> 224) and (sz <> 384) and (sz <> 512) then
        sz := 256;
    end;
    SHA3Init(p, sz);
  end;
  sha3UpdateFromValue(p, argv[0]);
end;

procedure sha3AggFinal(pCtx: Psqlite3_context); cdecl;
var
  p: PSHA3Context;
begin
  p := PSHA3Context(sqlite3_aggregate_context(pCtx, SizeOf(TSHA3Context)));
  if p = nil then Exit;
  if p^.iSize <> 0 then
    sqlite3_result_blob(pCtx, SHA3Final(p), p^.iSize div 8, SQLITE_TRANSIENT);
end;

function sqlite3ShathreeInit(db: PTsqlite3): i32;
const
  FFlags = SQLITE_UTF8 or SQLITE_INNOCUOUS or SQLITE_DETERMINISTIC;
  QFlags = SQLITE_UTF8 or SQLITE_DIRECTONLY;
var
  rc: i32;
begin
  rc := sqlite3_create_function(db, 'sha3', 1, FFlags, nil,
                                @sha3Func, nil, nil);
  if rc = SQLITE_OK then
    rc := sqlite3_create_function(db, 'sha3', 2, FFlags, nil,
                                  @sha3Func, nil, nil);
  if rc = SQLITE_OK then
    rc := sqlite3_create_function(db, 'sha3_agg', 1, FFlags, nil,
                                  nil, @sha3AggStep, @sha3AggFinal);
  if rc = SQLITE_OK then
    rc := sqlite3_create_function(db, 'sha3_agg', 2, FFlags, nil,
                                  nil, @sha3AggStep, @sha3AggFinal);
  if rc = SQLITE_OK then
    rc := sqlite3_create_function(db, 'sha3_query', 1, QFlags, nil,
                                  @sha3QueryFunc, nil, nil);
  if rc = SQLITE_OK then
    rc := sqlite3_create_function(db, 'sha3_query', 2, QFlags, nil,
                                  @sha3QueryFunc, nil, nil);
  Result := rc;
end;

end.
