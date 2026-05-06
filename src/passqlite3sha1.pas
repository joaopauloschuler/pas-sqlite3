{
  SPDX-License-Identifier: blessing

  Faithful port of ../sqlite3/ext/misc/sha1.c (419 lines in C).

  Implements the SQL functions sha1(X), sha1b(X), and sha1_query(SQL).
  The SHA1 hash engine (SHA1Transform / hash_init / hash_step /
  hash_finish) and the per-row "type-tagged" hash composer used by
  sha1_query are mirrored 1:1 from the C source so the produced
  hashes are byte-identical.

  Public entry: sqlite3ShaInit(db) — equivalent to sqlite3_sha_init() in C;
  safe to call multiple times.
}
{$I passqlite3.inc}
unit passqlite3sha1;

interface

uses
  passqlite3types,
  passqlite3util,
  passqlite3vdbe,
  passqlite3main;

function sqlite3ShaInit(db: PTsqlite3): i32;

implementation

uses
  SysUtils,
  passqlite3printf;

type
  { Mirrors `struct SHA1Context` (sha1.c:36..40). }
  TSHA1Context = record
    state: array[0..4] of u32;
    count: array[0..1] of u32;
    buffer: array[0..63] of Byte;
  end;
  PSHA1Context = ^TSHA1Context;

{ rotl/rotr — direct macro expansion of SHA_ROT/rol/ror (sha1.c:42..44).
  No mode switches; FPC `{$Q-}{$R-}` is on project-wide so the unsigned
  wrap that C relies on (e.g. `x << 32 - k`) behaves identically. }
function rol32(x: u32; k: Integer): u32; inline;
begin
  Result := (x shl k) or (x shr (32 - k));
end;

function ror32(x: u32; k: Integer): u32; inline;
begin
  Result := (x shr k) or (x shl (32 - k));
end;

{ Single 512-bit block transform.  Direct port of SHA1Transform
  (sha1.c:74..137).  The C source uses Rl0 (little-endian) or Rb0
  (big-endian) for the first 16 ops via a runtime byte-test on a
  static `int one`; FPC on x86_64 is little-endian, so we always take
  the Rl0 branch.  The rest (R1..R4) are endianness-agnostic.  All
  five operands a..e are kept in the qq[5] array so the carousel
  rotation in the Rxx macros maps cleanly. }
procedure SHA1Transform(state: PCardinal; buffer: PByte);
var
  qq: array[0..4] of u32;
  block: array[0..15] of u32;
  i: Integer;
  v, w, x, y, z, t: u32;
begin
  Move(buffer^, block[0], 64);
  Move(state^, qq[0], 5 * SizeOf(u32));

  { ---- Rl0 ops 0..15 — little-endian byte-swap of block[i] ---- }
  for i := 0 to 15 do
    block[i] := (ror32(block[i], 8) and u32($FF00FF00))
             or (rol32(block[i], 8) and u32($00FF00FF));

  { Run 80 ops as a carousel.  Each Rxx in C cycles the (v,w,x,y,z)
    arguments by one slot; we mirror that with explicit reads from qq[]
    by index and a per-iteration index modulo 5.  block[i mod 16] is
    refreshed in place exactly as `blk(i)` does (sha1.c:49..50). }
  v := qq[0]; w := qq[1]; x := qq[2]; y := qq[3]; z := qq[4];

  { ops 0..15 — Rl0 (uses block[i] as-is, already byte-swapped) }
  for i := 0 to 15 do
  begin
    z := z + ((w and (x xor y)) xor y) + block[i] + u32($5A827999) + rol32(v, 5);
    w := ror32(w, 2);
    { rotate (v,w,x,y,z) := (z,v,w,x,y) — matches the macro carousel }
    t := z; z := y; y := x; x := w; w := v; v := t;
  end;

  { ops 16..19 — R1 (same constant as Rl0 but uses blk(i) refresh) }
  for i := 16 to 19 do
  begin
    block[i and 15] := rol32(block[(i + 13) and 15] xor block[(i + 8) and 15]
                          xor block[(i + 2)  and 15] xor block[i and 15], 1);
    z := z + ((w and (x xor y)) xor y) + block[i and 15] + u32($5A827999) + rol32(v, 5);
    w := ror32(w, 2);
    t := z; z := y; y := x; x := w; w := v; v := t;
  end;

  { ops 20..39 — R2: f = (w xor x xor y), K = 0x6ED9EBA1 }
  for i := 20 to 39 do
  begin
    block[i and 15] := rol32(block[(i + 13) and 15] xor block[(i + 8) and 15]
                          xor block[(i + 2)  and 15] xor block[i and 15], 1);
    z := z + (w xor x xor y) + block[i and 15] + u32($6ED9EBA1) + rol32(v, 5);
    w := ror32(w, 2);
    t := z; z := y; y := x; x := w; w := v; v := t;
  end;

  { ops 40..59 — R3: f = (((w|x)&y) | (w&x)), K = 0x8F1BBCDC }
  for i := 40 to 59 do
  begin
    block[i and 15] := rol32(block[(i + 13) and 15] xor block[(i + 8) and 15]
                          xor block[(i + 2)  and 15] xor block[i and 15], 1);
    z := z + (((w or x) and y) or (w and x)) + block[i and 15] + u32($8F1BBCDC) + rol32(v, 5);
    w := ror32(w, 2);
    t := z; z := y; y := x; x := w; w := v; v := t;
  end;

  { ops 60..79 — R4: f = (w xor x xor y), K = 0xCA62C1D6 }
  for i := 60 to 79 do
  begin
    block[i and 15] := rol32(block[(i + 13) and 15] xor block[(i + 8) and 15]
                          xor block[(i + 2)  and 15] xor block[i and 15], 1);
    z := z + (w xor x xor y) + block[i and 15] + u32($CA62C1D6) + rol32(v, 5);
    w := ror32(w, 2);
    t := z; z := y; y := x; x := w; w := v; v := t;
  end;

  qq[0] := v; qq[1] := w; qq[2] := x; qq[3] := y; qq[4] := z;

  PCardinal(state)[0] := PCardinal(state)[0] + qq[0];
  PCardinal(state)[1] := PCardinal(state)[1] + qq[1];
  PCardinal(state)[2] := PCardinal(state)[2] + qq[2];
  PCardinal(state)[3] := PCardinal(state)[3] + qq[3];
  PCardinal(state)[4] := PCardinal(state)[4] + qq[4];
end;

{ Mirrors hash_init (sha1.c:141..149). }
procedure hashInit(p: PSHA1Context);
begin
  p^.state[0] := u32($67452301);
  p^.state[1] := u32($EFCDAB89);
  p^.state[2] := u32($98BADCFE);
  p^.state[3] := u32($10325476);
  p^.state[4] := u32($C3D2E1F0);
  p^.count[0] := 0;
  p^.count[1] := 0;
end;

{ Mirrors hash_step (sha1.c:151..175). }
procedure hashStep(p: PSHA1Context; data: PByte; len: u32);
var
  i, j, prev: u32;
begin
  prev := p^.count[0];
  p^.count[0] := p^.count[0] + (len shl 3);
  if p^.count[0] < prev then
    p^.count[1] := p^.count[1] + (len shr 29) + 1;
  j := (prev shr 3) and 63;
  if (j + len) > 63 then
  begin
    i := 64 - j;
    Move(data[0], p^.buffer[j], i);
    SHA1Transform(@p^.state[0], @p^.buffer[0]);
    while i + 63 < len do
    begin
      SHA1Transform(@p^.state[0], data + i);
      i := i + 64;
    end;
    j := 0;
  end
  else
    i := 0;
  if len > i then
    Move(data[i], p^.buffer[j], len - i);
end;

{ Mirrors hash_step_vformat (sha1.c:178..191).  Used to splice an
  ASCII-encoded length tag (S<n>:, T<n>:, B<n>:) into the running hash. }
procedure hashStepVFormat(p: PSHA1Context; tag: AnsiChar; n: i32);
var
  s: AnsiString;
  L: Integer;
begin
  s := tag + IntToStr(n) + ':';
  L := Length(s);
  if L > 49 then L := 49;
  hashStep(p, PByte(PAnsiChar(s)), u32(L));
end;

{ Mirrors hash_finish (sha1.c:197..228).  Pads, drains, then renders
  either a 20-byte binary digest or a 40-char lowercase hex string into
  zOut.  zOut must be at least 41 bytes. }
procedure hashFinish(p: PSHA1Context; zOut: PByte; bAsBinary: Integer);
const
  zEncode: array[0..15] of AnsiChar = '0123456789abcdef';
  zPad: AnsiChar = #$80;
  zZero: AnsiChar = #0;
var
  i: u32;
  finalcount: array[0..7] of Byte;
  digest: array[0..19] of Byte;
  cIdx: u32;
begin
  for i := 0 to 7 do
  begin
    if i >= 4 then cIdx := 0 else cIdx := 1;
    finalcount[i] := Byte((p^.count[cIdx] shr ((3 - (i and 3)) * 8)) and 255);
  end;
  hashStep(p, PByte(@zPad), 1);
  while (p^.count[0] and 504) <> 448 do
    hashStep(p, PByte(@zZero), 1);
  hashStep(p, @finalcount[0], 8);
  for i := 0 to 19 do
    digest[i] := Byte((p^.state[i shr 2] shr ((3 - (i and 3)) * 8)) and 255);
  if bAsBinary <> 0 then
    Move(digest[0], zOut[0], 20)
  else
  begin
    for i := 0 to 19 do
    begin
      zOut[i * 2]     := Byte(zEncode[(digest[i] shr 4) and $F]);
      zOut[i * 2 + 1] := Byte(zEncode[digest[i] and $F]);
    end;
    zOut[40] := 0;
  end;
end;

{ ---- SQL-function wrappers ---- }

{ sha1(X) / sha1b(X) — same body, eUserData=0 means hex, non-NULL means
  binary.  Mirrors sha1Func (sha1.c:244..274). }
procedure sha1Func(pCtx: Psqlite3_context; argc: i32; argv: PPMem); cdecl;
var
  cx: TSHA1Context;
  eType, nByte: i32;
  pData: Pointer;
  zOut: array[0..43] of Byte;
begin
  eType := sqlite3_value_type(argv[0]);
  if eType = SQLITE_NULL then Exit;
  nByte := sqlite3_value_bytes(argv[0]);
  hashInit(@cx);
  if eType = SQLITE_BLOB then
    pData := sqlite3_value_blob(argv[0])
  else
    pData := Pointer(sqlite3_value_text(argv[0]));
  if pData = nil then Exit;
  hashStep(@cx, PByte(pData), u32(nByte));
  if sqlite3_user_data(pCtx) <> nil then
  begin
    hashFinish(@cx, @zOut[0], 1);
    sqlite3_result_blob(pCtx, @zOut[0], 20, SQLITE_TRANSIENT);
  end
  else
  begin
    hashFinish(@cx, @zOut[0], 0);
    sqlite3_result_text(pCtx, PAnsiChar(@zOut[0]), 40, SQLITE_TRANSIENT);
  end;
end;

{ sha1_query(SQL) — mirrors sha1QueryFunc (sha1.c:288..389).  Composes
  the per-row type-tagged hash exactly as the C reference does so the
  result is byte-identical. }
procedure sha1QueryFunc(pCtx: Psqlite3_context; argc: i32; argv: PPMem); cdecl;
var
  db: PTsqlite3;
  zSql, zTail, z, zMsg: PAnsiChar;
  pStmt: Pointer;
  nCol, i, rc, n, n2: i32;
  cx: TSHA1Context;
  zOut: array[0..43] of Byte;
  v: i64;
  r: Double;
  u: u64;
  j: Integer;
  x: array[0..8] of Byte;
  z2: Pointer;
begin
  db := sqlite3_context_db_handle(pCtx);
  zSql := PAnsiChar(sqlite3_value_text(argv[0]));
  if zSql = nil then Exit;
  pStmt := nil;
  hashInit(@cx);
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
    if z = nil then z := '';
    n := i32(StrLen(z));
    hashStepVFormat(@cx, 'S', n);
    hashStep(@cx, PByte(z), u32(n));
    while sqlite3_step(PVdbe(pStmt)) = SQLITE_ROW do
    begin
      hashStep(@cx, PByte(PAnsiChar('R')), 1);
      for i := 0 to nCol - 1 do
      begin
        case sqlite3_column_type(PVdbe(pStmt), i) of
          SQLITE_NULL:
            hashStep(@cx, PByte(PAnsiChar('N')), 1);
          SQLITE_INTEGER:
            begin
              v := sqlite3_column_int64(PVdbe(pStmt), i);
              Move(v, u, 8);
              for j := 8 downto 1 do
              begin
                x[j] := u and $FF;
                u := u shr 8;
              end;
              x[0] := Ord('I');
              hashStep(@cx, @x[0], 9);
            end;
          SQLITE_FLOAT:
            begin
              r := sqlite3_column_double(PVdbe(pStmt), i);
              Move(r, u, 8);
              for j := 8 downto 1 do
              begin
                x[j] := u and $FF;
                u := u shr 8;
              end;
              x[0] := Ord('F');
              hashStep(@cx, @x[0], 9);
            end;
          SQLITE_TEXT:
            begin
              n2 := sqlite3_column_bytes(PVdbe(pStmt), i);
              z2 := Pointer(sqlite3_column_text(PVdbe(pStmt), i));
              hashStepVFormat(@cx, 'T', n2);
              hashStep(@cx, PByte(z2), u32(n2));
            end;
          SQLITE_BLOB:
            begin
              n2 := sqlite3_column_bytes(PVdbe(pStmt), i);
              z2 := sqlite3_column_blob(PVdbe(pStmt), i);
              hashStepVFormat(@cx, 'B', n2);
              hashStep(@cx, PByte(z2), u32(n2));
            end;
        end;
      end;
    end;
    sqlite3_finalize(PVdbe(pStmt));
    zSql := zTail;
    if zSql = nil then break;
  end;
  hashFinish(@cx, @zOut[0], 0);
  sqlite3_result_text(pCtx, PAnsiChar(@zOut[0]), 40, SQLITE_TRANSIENT);
end;

{ A non-NULL sentinel pointer used as the user-data of sha1b() to
  switch sha1Func into binary-output mode (mirrors sha1.c:401's
  `static int one = 1`). }
var
  Sha1OneSentinel: Integer = 1;

function sqlite3ShaInit(db: PTsqlite3): i32;
const
  FFlags = SQLITE_UTF8 or SQLITE_INNOCUOUS or SQLITE_DETERMINISTIC;
  QFlags = SQLITE_UTF8 or SQLITE_DIRECTONLY;
var
  rc: i32;
begin
  rc := sqlite3_create_function(db, 'sha1', 1, FFlags, nil,
                                @sha1Func, nil, nil);
  if rc = SQLITE_OK then
    rc := sqlite3_create_function(db, 'sha1b', 1, FFlags, @Sha1OneSentinel,
                                  @sha1Func, nil, nil);
  if rc = SQLITE_OK then
    rc := sqlite3_create_function(db, 'sha1_query', 1, QFlags, nil,
                                  @sha1QueryFunc, nil, nil);
  Result := rc;
end;

end.
