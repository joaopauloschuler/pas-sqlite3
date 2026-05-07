{
  SPDX-License-Identifier: blessing

  Faithful port of ../sqlite3/ext/misc/fossildelta.c (1109 lines in C).

  Implements the Fossil delta encoder used by RBU.  Three scalar SQL
  functions and one table-valued (eponymous) virtual table:

      delta_apply(X, D)        -- apply delta D to file X, return result
      delta_create(X, Y)       -- compute delta carrying X into Y
      delta_output_size(D)     -- output size from applying delta D
      SELECT * FROM delta_parse(D)
                               -- one row per delta opcode (SIZE / COPY /
                               --   INSERT / CHECKSUM / ERROR)

  Delta format documented at
      https://fossil-scm.org/fossil/doc/trunk/www/delta_format.wiki

  Public entry: sqlite3FossildeltaInit(db) — equivalent to
  sqlite3_fossildelta_init() in C.  Safe to call multiple times.
}
{$I passqlite3.inc}
unit passqlite3fossildelta;

interface

uses
  passqlite3types,
  passqlite3util,
  passqlite3os,
  passqlite3vdbe,
  passqlite3vtab,
  passqlite3main;

function sqlite3FossildeltaInit(db: PTsqlite3): i32;

implementation

const
  NHASH_BYTES = 16;

type
  { fossildelta.c:75..79 — rolling hash state.  z[] is a NHASH_BYTES-byte
    circular buffer; a/b are the 16-bit accumulators; i is the start
    index of the window in z[]. }
  PHash = ^THash;
  THash = record
    a, b: u16;
    i:    u16;
    z:    array[0..NHASH_BYTES - 1] of AnsiChar;
  end;

const
  zPutDigits: array[0..63] of AnsiChar =
    '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ_abcdefghijklmnopqrstuvwxyz~';

  { fossildelta.c:161..170 — base-64 reverse table (-1 for non-digits).
    Indexed by `0x7f & ch`. }
  zGetValue: array[0..127] of ShortInt = (
    -1, -1, -1, -1, -1, -1, -1, -1,   -1, -1, -1, -1, -1, -1, -1, -1,
    -1, -1, -1, -1, -1, -1, -1, -1,   -1, -1, -1, -1, -1, -1, -1, -1,
    -1, -1, -1, -1, -1, -1, -1, -1,   -1, -1, -1, -1, -1, -1, -1, -1,
     0,  1,  2,  3,  4,  5,  6,  7,    8,  9, -1, -1, -1, -1, -1, -1,
    -1, 10, 11, 12, 13, 14, 15, 16,   17, 18, 19, 20, 21, 22, 23, 24,
    25, 26, 27, 28, 29, 30, 31, 32,   33, 34, 35, -1, -1, -1, -1, 36,
    -1, 37, 38, 39, 40, 41, 42, 43,   44, 45, 46, 47, 48, 49, 50, 51,
    52, 53, 54, 55, 56, 57, 58, 59,   60, 61, 62, -1, -1, -1, 63, -1
  );

{ fossildelta.c:84..95 — initialise rolling hash from first NHASH_BYTES bytes
  of z[]. }
procedure hashInit(pHash: PHash; const z: PAnsiChar);
var
  a, b: u16;
  i:    Integer;
begin
  a := u16(Byte(z[0]));
  b := a;
  for i := 1 to NHASH_BYTES - 1 do
  begin
    a := u16(a + u16(Byte(z[i])));
    b := u16(b + a);
  end;
  Move(z^, pHash^.z[0], NHASH_BYTES);
  pHash^.a := a and $FFFF;
  pHash^.b := b and $FFFF;
  pHash^.i := 0;
end;

{ fossildelta.c:100..106 — advance the rolling hash by one byte. }
procedure hashNext(pHash: PHash; c: Integer); inline;
var
  old: u16;
begin
  old := u16(Byte(pHash^.z[pHash^.i]));
  pHash^.z[pHash^.i] := AnsiChar(Byte(c));
  pHash^.i := (pHash^.i + 1) and (NHASH_BYTES - 1);
  pHash^.a := u16(pHash^.a - old + u16(Byte(c)));
  pHash^.b := u16(pHash^.b - u16(NHASH_BYTES) * old + pHash^.a);
end;

{ fossildelta.c:111..113 — extract 32-bit hash. }
function hash32bit(pHash: PHash): u32; inline;
begin
  Result := (u32(pHash^.a) and $FFFF) or ((u32(pHash^.b) and $FFFF) shl 16);
end;

{ fossildelta.c:123..131 — one-shot hash on NHASH_BYTES bytes. }
function hashOnce(const z: PAnsiChar): u32;
var
  a, b: u16;
  i:    Integer;
begin
  a := u16(Byte(z[0]));
  b := a;
  for i := 1 to NHASH_BYTES - 1 do
  begin
    a := u16(a + u16(Byte(z[i])));
    b := u16(b + a);
  end;
  Result := u32(a) or (u32(b) shl 16);
end;

{ fossildelta.c:136..152 — write base-64 integer into *pz, advancing it. }
procedure putInt(v: u32; var pz: PAnsiChar);
var
  i, j: Integer;
  zBuf: array[0..19] of AnsiChar;
begin
  if v = 0 then
  begin
    pz^ := '0';
    Inc(pz);
    Exit;
  end;
  i := 0;
  while v > 0 do
  begin
    zBuf[i] := zPutDigits[v and $3F];
    v := v shr 6;
    Inc(i);
  end;
  for j := i - 1 downto 0 do
  begin
    pz^ := zBuf[j];
    Inc(pz);
  end;
end;

{ fossildelta.c:160..182 — read base-64 integer from *pz, advancing it
  and decrementing *pLen. }
function deltaGetInt(var pz: PAnsiChar; var pLen: Integer): u32;
var
  v:      u32;
  c:      ShortInt;
  z, zStart: PAnsiChar;
begin
  v := 0;
  z := pz;
  zStart := z;
  while True do
  begin
    c := zGetValue[$7F and Byte(z^)];
    Inc(z);
    if c < 0 then Break;
    v := (v shl 6) + u32(c);
  end;
  Dec(z);
  pLen := pLen - (z - zStart);
  pz := z;
  Result := v;
end;

{ fossildelta.c:187..191 — number of base-64 digits needed to represent v. }
function digitCount(v: Integer): Integer;
var
  i: Integer;
  x: u32;
begin
  i := 1;
  x := 64;
  while u32(v) >= x do
  begin
    Inc(i);
    x := x shl 6;
  end;
  Result := i;
end;

{ fossildelta.c:205..259 — 32-bit big-endian checksum (LE arm; on x86_64
  Linux byteOrderTest is true).  Pads the trailing 0..3 bytes with
  zeros (most-significant byte first). }
function checksum(const zIn: PAnsiChar; N: SizeUInt): u32;
var
  z:    PByte;
  sum, sum0, sum1, sum2: u32;
  rem:  SizeUInt;
begin
  z := PByte(zIn);
  sum := 0;
  sum0 := 0;
  sum1 := 0;
  sum2 := 0;
  rem := N;
  while rem >= 16 do
  begin
    sum0 := sum0 + u32(z[0]) + u32(z[4]) + u32(z[8])  + u32(z[12]);
    sum1 := sum1 + u32(z[1]) + u32(z[5]) + u32(z[9])  + u32(z[13]);
    sum2 := sum2 + u32(z[2]) + u32(z[6]) + u32(z[10]) + u32(z[14]);
    sum  := sum  + u32(z[3]) + u32(z[7]) + u32(z[11]) + u32(z[15]);
    Inc(z, 16);
    Dec(rem, 16);
  end;
  while rem >= 4 do
  begin
    sum0 := sum0 + u32(z[0]);
    sum1 := sum1 + u32(z[1]);
    sum2 := sum2 + u32(z[2]);
    sum  := sum  + u32(z[3]);
    Inc(z, 4);
    Dec(rem, 4);
  end;
  sum := sum + (sum2 shl 8) + (sum1 shl 16) + (sum0 shl 24);
  case (N and 3) of
    3: sum := sum + (u32(z[2]) shl 8)  + (u32(z[1]) shl 16) + (u32(z[0]) shl 24);
    2: sum := sum + (u32(z[1]) shl 16) + (u32(z[0]) shl 24);
    1: sum := sum + (u32(z[0]) shl 24);
  end;
  Result := sum;
end;

{ fossildelta.c:322..497 — delta_create.  zDelta must have at least
  lenOut+60 bytes of room.  Returns the number of bytes written
  (excluding any NUL terminator — caller may add one). }
function deltaCreate(const zSrc: PAnsiChar; lenSrc: u32;
  const zOut: PAnsiChar; lenOut: u32; zDelta: PAnsiChar): Integer;
var
  i, base:    Integer;
  zOrigDelta: PAnsiChar;
  zCur:       PAnsiChar;
  h:          THash;
  nHash:      Integer;
  landmark:   PInteger;
  collide:    PInteger;
  lastRead:   Integer;
  iSrc, iBlock: Integer;
  bestCnt, bestOfst, bestLitsz: u32;
  hv:         Integer;
  limit:      Integer;
  cnt, ofst, litsz: Integer;
  j, k, x, y, sz, limitX: Integer;
begin
  zOrigDelta := zDelta;
  zCur := zDelta;
  putInt(lenOut, zCur);
  zCur^ := #10;
  Inc(zCur);

  if lenSrc <= u32(NHASH_BYTES) then
  begin
    putInt(lenOut, zCur);
    zCur^ := ':';
    Inc(zCur);
    Move(zOut^, zCur^, lenOut);
    Inc(zCur, lenOut);
    putInt(checksum(zOut, lenOut), zCur);
    zCur^ := ';';
    Inc(zCur);
    Result := zCur - zOrigDelta;
    Exit;
  end;

  nHash := lenSrc div NHASH_BYTES;
  collide := PInteger(sqlite3_malloc64(u64(nHash) * 2 * SizeOf(Integer)));
  if collide = nil then
  begin
    Result := -1;
    Exit;
  end;
  FillChar(collide^, nHash * 2 * SizeOf(Integer), $FF); { -1 in two's complement }
  landmark := PInteger(PtrUInt(collide) + PtrUInt(nHash) * SizeOf(Integer));

  i := 0;
  while i < Integer(lenSrc) - NHASH_BYTES do
  begin
    hv := hashOnce(@zSrc[i]) mod u32(nHash);
    collide[i div NHASH_BYTES] := landmark[hv];
    landmark[hv] := i div NHASH_BYTES;
    Inc(i, NHASH_BYTES);
  end;

  base := 0;
  lastRead := -1;

  while base + NHASH_BYTES < Integer(lenOut) do
  begin
    bestCnt := 0;
    bestOfst := 0;
    bestLitsz := 0;
    hashInit(@h, @zOut[base]);
    i := 0;

    while True do
    begin
      hv := hash32bit(@h) mod u32(nHash);
      iBlock := landmark[hv];
      limit := 250;
      while (iBlock >= 0) and (limit > 0) do
      begin
        Dec(limit);
        iSrc := iBlock * NHASH_BYTES;
        y := base + i;
        if Integer(lenSrc) - iSrc <= Integer(lenOut) - y then
          limitX := Integer(lenSrc)
        else
          limitX := iSrc + (Integer(lenOut) - y);
        x := iSrc;
        while x < limitX do
        begin
          if zSrc[x] <> zOut[y] then Break;
          Inc(x);
          Inc(y);
        end;
        j := x - iSrc - 1;

        k := 1;
        while (k < iSrc) and (k <= i) do
        begin
          if zSrc[iSrc - k] <> zOut[base + i - k] then Break;
          Inc(k);
        end;
        Dec(k);

        ofst := iSrc - k;
        cnt := j + k + 1;
        litsz := i - k;
        sz := digitCount(i - k) + digitCount(cnt) + digitCount(ofst) + 3;
        if (cnt >= sz) and (u32(cnt) > bestCnt) then
        begin
          bestCnt := u32(cnt);
          bestOfst := u32(iSrc - k);
          bestLitsz := u32(litsz);
        end;

        iBlock := collide[iBlock];
      end;

      if bestCnt > 0 then
      begin
        if bestLitsz > 0 then
        begin
          putInt(bestLitsz, zCur);
          zCur^ := ':';
          Inc(zCur);
          Move(zOut[base], zCur^, bestLitsz);
          Inc(zCur, bestLitsz);
          base := base + Integer(bestLitsz);
        end;
        base := base + Integer(bestCnt);
        putInt(bestCnt, zCur);
        zCur^ := '@';
        Inc(zCur);
        putInt(bestOfst, zCur);
        zCur^ := ',';
        Inc(zCur);
        if Integer(bestOfst + bestCnt) - 1 > lastRead then
          lastRead := Integer(bestOfst + bestCnt) - 1;
        bestCnt := 0;
        Break;
      end;

      if base + i + NHASH_BYTES >= Integer(lenOut) then
      begin
        putInt(u32(Integer(lenOut) - base), zCur);
        zCur^ := ':';
        Inc(zCur);
        Move(zOut[base], zCur^, Integer(lenOut) - base);
        Inc(zCur, Integer(lenOut) - base);
        base := lenOut;
        Break;
      end;

      hashNext(@h, Byte(zOut[base + i + NHASH_BYTES]));
      Inc(i);
    end;
  end;

  if base < Integer(lenOut) then
  begin
    putInt(u32(Integer(lenOut) - base), zCur);
    zCur^ := ':';
    Inc(zCur);
    Move(zOut[base], zCur^, Integer(lenOut) - base);
    Inc(zCur, Integer(lenOut) - base);
  end;

  putInt(checksum(zOut, lenOut), zCur);
  zCur^ := ';';
  Inc(zCur);
  sqlite3_free(collide);
  Result := zCur - zOrigDelta;
end;

{ fossildelta.c:508..516 — return predicted output size from delta. }
function deltaOutputSize(const zDelta: PAnsiChar; lenDelta: Integer): Integer;
var
  size: u32;
  z:    PAnsiChar;
  n:    Integer;
begin
  z := zDelta;
  n := lenDelta;
  size := deltaGetInt(z, n);
  if z^ <> #10 then
  begin
    Result := -1;
    Exit;
  end;
  Result := Integer(size);
end;

{ fossildelta.c:539..623 — apply a delta. }
function deltaApply(const zSrc: PAnsiChar; lenSrc: Integer;
  const zDeltaIn: PAnsiChar; lenDeltaIn: Integer; zOut: PAnsiChar): Integer;
var
  limit, total: u64;
  cnt, ofst:    u32;
  zDelta:       PAnsiChar;
  lenDelta:     Integer;
  pOut:         PAnsiChar;
begin
  zDelta := zDeltaIn;
  lenDelta := lenDeltaIn;
  pOut := zOut;
  limit := deltaGetInt(zDelta, lenDelta);
  if zDelta^ <> #10 then
  begin
    Result := -1;
    Exit;
  end;
  Inc(zDelta);
  Dec(lenDelta);
  total := 0;
  while (zDelta^ <> #0) and (lenDelta > 0) do
  begin
    cnt := deltaGetInt(zDelta, lenDelta);
    case zDelta[0] of
      '@':
        begin
          Inc(zDelta);
          Dec(lenDelta);
          ofst := deltaGetInt(zDelta, lenDelta);
          if (lenDelta > 0) and (zDelta[0] <> ',') then
          begin
            Result := -1;
            Exit;
          end;
          Inc(zDelta);
          Dec(lenDelta);
          total := total + cnt;
          if total > limit then
          begin
            Result := -1;
            Exit;
          end;
          if u64(ofst) + u64(cnt) > u64(lenSrc) then
          begin
            Result := -1;
            Exit;
          end;
          Move(zSrc[ofst], pOut^, cnt);
          Inc(pOut, cnt);
        end;
      ':':
        begin
          Inc(zDelta);
          Dec(lenDelta);
          total := total + cnt;
          if total > limit then
          begin
            Result := -1;
            Exit;
          end;
          if Integer(cnt) > lenDelta then
          begin
            Result := -1;
            Exit;
          end;
          Move(zDelta^, pOut^, cnt);
          Inc(pOut, cnt);
          Inc(zDelta, cnt);
          Dec(lenDelta, cnt);
        end;
      ';':
        begin
          Inc(zDelta);
          Dec(lenDelta);
          pOut^ := #0;
          if total <> limit then
          begin
            Result := -1;
            Exit;
          end;
          Result := Integer(total);
          Exit;
        end;
    else
      Result := -1;
      Exit;
    end;
  end;
  Result := -1;
end;

{ fossildelta.c:630..658 — delta_create(X,Y) SQL function. }
procedure deltaCreateFunc(pCtx: Psqlite3_context; argc: i32;
  argv: PPMem); cdecl;
var
  aOrig, aNew, aOut: PAnsiChar;
  nOrig, nNew, nOut: i32;
begin
  if (sqlite3_value_type(argv[0]) = SQLITE_NULL) or
     (sqlite3_value_type(argv[1]) = SQLITE_NULL) then Exit;
  nOrig := sqlite3_value_bytes(argv[0]);
  aOrig := PAnsiChar(sqlite3_value_blob(argv[0]));
  nNew  := sqlite3_value_bytes(argv[1]);
  aNew  := PAnsiChar(sqlite3_value_blob(argv[1]));
  aOut := PAnsiChar(sqlite3_malloc64(u64(nNew) + 70));
  if aOut = nil then
  begin
    sqlite3_result_error_nomem(pCtx);
    Exit;
  end;
  nOut := deltaCreate(aOrig, u32(nOrig), aNew, u32(nNew), aOut);
  if nOut < 0 then
  begin
    sqlite3_free(aOut);
    sqlite3_result_error(pCtx, 'cannot create fossil delta', -1);
  end
  else
    sqlite3_result_blob(pCtx, aOut, nOut, SQLITE_DYNAMIC);
end;

{ fossildelta.c:665..700 — delta_apply(X,D) SQL function. }
procedure deltaApplyFunc(pCtx: Psqlite3_context; argc: i32;
  argv: PPMem); cdecl;
var
  aOrig, aDelta, aOut: PAnsiChar;
  nOrig, nDelta, nOut, nOut2: i32;
begin
  if (sqlite3_value_type(argv[0]) = SQLITE_NULL) or
     (sqlite3_value_type(argv[1]) = SQLITE_NULL) then Exit;
  nOrig  := sqlite3_value_bytes(argv[0]);
  aOrig  := PAnsiChar(sqlite3_value_blob(argv[0]));
  nDelta := sqlite3_value_bytes(argv[1]);
  aDelta := PAnsiChar(sqlite3_value_blob(argv[1]));

  nOut := deltaOutputSize(aDelta, nDelta);
  if nOut < 0 then
  begin
    sqlite3_result_error(pCtx, 'corrupt fossil delta', -1);
    Exit;
  end;
  aOut := PAnsiChar(sqlite3_malloc64(u64(nOut) + 1));
  if aOut = nil then
  begin
    sqlite3_result_error_nomem(pCtx);
    Exit;
  end;
  nOut2 := deltaApply(aOrig, nOrig, aDelta, nDelta, aOut);
  if nOut2 <> nOut then
  begin
    sqlite3_free(aOut);
    sqlite3_result_error(pCtx, 'corrupt fossil delta', -1);
  end
  else
    sqlite3_result_blob(pCtx, aOut, nOut, SQLITE_DYNAMIC);
end;

{ fossildelta.c:708..728 — delta_output_size(D) SQL function. }
procedure deltaOutputSizeFunc(pCtx: Psqlite3_context; argc: i32;
  argv: PPMem); cdecl;
var
  aDelta: PAnsiChar;
  nDelta: i32;
  nOut:   i32;
begin
  if sqlite3_value_type(argv[0]) = SQLITE_NULL then Exit;
  nDelta := sqlite3_value_bytes(argv[0]);
  aDelta := PAnsiChar(sqlite3_value_blob(argv[0]));
  nOut := deltaOutputSize(aDelta, nDelta);
  if nOut < 0 then
    sqlite3_result_error(pCtx, 'corrupt fossil delta', -1)
  else
    sqlite3_result_int(pCtx, nOut);
end;

{ ============================================================
  Table-valued function: delta_parse(D)
  Schema: CREATE TABLE delta_parse(op,a1,a2,delta HIDDEN);
  ============================================================ }

const
  DELTAPARSE_OP_SIZE     = 0;
  DELTAPARSE_OP_COPY     = 1;
  DELTAPARSE_OP_INSERT   = 2;
  DELTAPARSE_OP_CHECKSUM = 3;
  DELTAPARSE_OP_ERROR    = 4;
  DELTAPARSE_OP_EOF      = 5;

  DELTAPARSEVTAB_OP    = 0;
  DELTAPARSEVTAB_A1    = 1;
  DELTAPARSEVTAB_A2    = 2;
  DELTAPARSEVTAB_DELTA = 3;

  azOpName: array[0..5] of PAnsiChar = (
    'SIZE', 'COPY', 'INSERT', 'CHECKSUM', 'ERROR', 'EOF'
  );

type
  PPSqlite3VtabCursor = ^PSqlite3VtabCursor;

  PDeltaparseCursor = ^TDeltaparseCursor;
  TDeltaparseCursor = record
    base:    Tsqlite3_vtab_cursor;
    aDelta:  PAnsiChar;
    nDelta:  i32;
    iCursor: i32;
    eOp:     i32;
    a1, a2:  u32;
    iNext:   i32;
  end;

var
  deltaparsevtabModule: Tsqlite3_module;

{ fossildelta.c:804..830 — xConnect. }
function deltaparsevtabConnect(db: PTsqlite3; pAux: Pointer;
  argc: i32; argv: PPAnsiChar; ppVtab: PPSqlite3Vtab;
  pzErr: PPAnsiChar): i32; cdecl;
var
  pNew: PSqlite3Vtab;
  rc:   i32;
begin
  rc := sqlite3_declare_vtab(db, 'CREATE TABLE x(op,a1,a2,delta HIDDEN)');
  if rc = SQLITE_OK then
  begin
    pNew := PSqlite3Vtab(sqlite3Malloc(SizeOf(Tsqlite3_vtab)));
    ppVtab^ := pNew;
    if pNew = nil then begin Result := SQLITE_NOMEM; Exit; end;
    FillChar(pNew^, SizeOf(Tsqlite3_vtab), 0);
    sqlite3_vtab_config(db, SQLITE_VTAB_INNOCUOUS, 0);
  end;
  Result := rc;
end;

{ fossildelta.c:835..839 — xDisconnect. }
function deltaparsevtabDisconnect(p: PSqlite3Vtab): i32; cdecl;
begin
  sqlite3_free(p);
  Result := SQLITE_OK;
end;

{ fossildelta.c:844..851 — xOpen. }
function deltaparsevtabOpen(p: PSqlite3Vtab;
  ppCursor: PPSqlite3VtabCursor): i32; cdecl;
var
  pCur: PDeltaparseCursor;
begin
  pCur := PDeltaparseCursor(sqlite3Malloc(SizeOf(TDeltaparseCursor)));
  if pCur = nil then begin Result := SQLITE_NOMEM; Exit; end;
  FillChar(pCur^, SizeOf(TDeltaparseCursor), 0);
  ppCursor^ := PSqlite3VtabCursor(@pCur^.base);
  Result := SQLITE_OK;
end;

{ fossildelta.c:856..861 — xClose. }
function deltaparsevtabClose(cur: PSqlite3VtabCursor): i32; cdecl;
var
  pCur: PDeltaparseCursor;
begin
  pCur := PDeltaparseCursor(cur);
  sqlite3_free(pCur^.aDelta);
  sqlite3_free(pCur);
  Result := SQLITE_OK;
end;

{ fossildelta.c:867..916 — xNext.  Reads the next opcode from the delta
  buffer and updates eOp/a1/a2/iNext. }
function deltaparsevtabNext(cur: PSqlite3VtabCursor): i32; cdecl;
var
  pCur: PDeltaparseCursor;
  z:    PAnsiChar;
  i:    Integer;
begin
  pCur := PDeltaparseCursor(cur);
  i := 0;
  pCur^.iCursor := pCur^.iNext;
  if pCur^.iCursor >= pCur^.nDelta then
  begin
    pCur^.eOp := DELTAPARSE_OP_ERROR;
    pCur^.iNext := pCur^.nDelta;
    Result := SQLITE_OK;
    Exit;
  end;
  z := pCur^.aDelta + pCur^.iCursor;
  pCur^.a1 := deltaGetInt(z, i);
  case z[0] of
    '@':
      begin
        Inc(z);
        if pCur^.iNext >= pCur^.nDelta then
        begin
          pCur^.eOp := DELTAPARSE_OP_ERROR;
          pCur^.iNext := pCur^.nDelta;
        end
        else
        begin
          pCur^.a2 := deltaGetInt(z, i);
          pCur^.eOp := DELTAPARSE_OP_COPY;
          pCur^.iNext := i32((z + 1) - pCur^.aDelta);
        end;
      end;
    ':':
      begin
        Inc(z);
        pCur^.a2 := u32(z - pCur^.aDelta);
        pCur^.eOp := DELTAPARSE_OP_INSERT;
        pCur^.iNext := i32((z + pCur^.a1) - pCur^.aDelta);
      end;
    ';':
      begin
        pCur^.eOp := DELTAPARSE_OP_CHECKSUM;
        pCur^.iNext := pCur^.nDelta;
      end;
  else
    if pCur^.iNext = pCur^.nDelta then
      pCur^.eOp := DELTAPARSE_OP_EOF
    else
    begin
      pCur^.eOp := DELTAPARSE_OP_ERROR;
      pCur^.iNext := pCur^.nDelta;
    end;
  end;
  Result := SQLITE_OK;
end;

{ fossildelta.c:922..956 — xColumn. }
function deltaparsevtabColumn(cur: PSqlite3VtabCursor;
  ctx: Psqlite3_context; i: i32): i32; cdecl;
var
  pCur: PDeltaparseCursor;
begin
  pCur := PDeltaparseCursor(cur);
  case i of
    DELTAPARSEVTAB_OP:
      sqlite3_result_text(ctx, azOpName[pCur^.eOp], -1, SQLITE_STATIC);
    DELTAPARSEVTAB_A1:
      sqlite3_result_int(ctx, i32(pCur^.a1));
    DELTAPARSEVTAB_A2:
      begin
        if pCur^.eOp = DELTAPARSE_OP_COPY then
          sqlite3_result_int(ctx, i32(pCur^.a2))
        else if pCur^.eOp = DELTAPARSE_OP_INSERT then
        begin
          if pCur^.a2 + pCur^.a1 > u32(pCur^.nDelta) then
            sqlite3_result_zeroblob(ctx, i32(pCur^.a1))
          else
            sqlite3_result_blob(ctx, pCur^.aDelta + pCur^.a2,
              i32(pCur^.a1), SQLITE_TRANSIENT);
        end;
      end;
    DELTAPARSEVTAB_DELTA:
      sqlite3_result_blob(ctx, pCur^.aDelta, pCur^.nDelta, SQLITE_TRANSIENT);
  end;
  Result := SQLITE_OK;
end;

{ fossildelta.c:962..966 — xRowid. }
function deltaparsevtabRowid(cur: PSqlite3VtabCursor;
  pRowid: Pi64): i32; cdecl;
var pCur: PDeltaparseCursor;
begin
  pCur := PDeltaparseCursor(cur);
  pRowid^ := pCur^.iCursor;
  Result := SQLITE_OK;
end;

{ fossildelta.c:972..975 — xEof. }
function deltaparsevtabEof(cur: PSqlite3VtabCursor): i32; cdecl;
var pCur: PDeltaparseCursor;
begin
  pCur := PDeltaparseCursor(cur);
  if (pCur^.eOp = DELTAPARSE_OP_EOF) or (pCur^.iCursor >= pCur^.nDelta) then
    Result := 1
  else
    Result := 0;
end;

{ fossildelta.c:983..1019 — xFilter. }
function deltaparsevtabFilter(cur: PSqlite3VtabCursor;
  idxNum: i32; idxStr: PAnsiChar;
  argc: i32; argv: PPsqlite3_value): i32; cdecl;
var
  pCur: PDeltaparseCursor;
  a:    PAnsiChar;
  i:    Integer;
begin
  pCur := PDeltaparseCursor(cur);
  i := 0;
  pCur^.eOp := DELTAPARSE_OP_ERROR;
  if idxNum <> 1 then
  begin
    Result := SQLITE_OK;
    Exit;
  end;
  pCur^.nDelta := sqlite3_value_bytes(argv[0]);
  a := PAnsiChar(sqlite3_value_blob(argv[0]));
  if (pCur^.nDelta = 0) or (a = nil) then
  begin
    Result := SQLITE_OK;
    Exit;
  end;
  pCur^.aDelta := PAnsiChar(sqlite3_malloc64(u64(pCur^.nDelta) + 1));
  if pCur^.aDelta = nil then
  begin
    pCur^.nDelta := 0;
    Result := SQLITE_NOMEM;
    Exit;
  end;
  Move(a^, pCur^.aDelta^, pCur^.nDelta);
  pCur^.aDelta[pCur^.nDelta] := #0;
  a := pCur^.aDelta;
  pCur^.eOp := DELTAPARSE_OP_SIZE;
  pCur^.a1 := deltaGetInt(a, i);
  if a[0] <> #10 then
  begin
    pCur^.eOp := DELTAPARSE_OP_ERROR;
    pCur^.a1 := 0;
    pCur^.a2 := 0;
    pCur^.iNext := pCur^.nDelta;
    Result := SQLITE_OK;
    Exit;
  end;
  Inc(a);
  pCur^.iNext := i32(a - pCur^.aDelta);
  Result := SQLITE_OK;
end;

{ fossildelta.c:1027..1047 — xBestIndex.  Single EQ constraint on the
  hidden delta column → idxNum=1, plan cost 1; otherwise CONSTRAINT. }
function deltaparsevtabBestIndex(tab: PSqlite3Vtab;
  pIdxInfo: PSqlite3IndexInfo): i32; cdecl;
var
  i: Integer;
  c: PSqlite3IndexConstraint;
  u: PSqlite3IndexConstraintUsage;
begin
  for i := 0 to pIdxInfo^.nConstraint - 1 do
  begin
    c := @pIdxInfo^.aConstraint[i];
    if c^.iColumn <> DELTAPARSEVTAB_DELTA then Continue;
    if c^.usable = 0 then Continue;
    if c^.op <> SQLITE_INDEX_CONSTRAINT_EQ then Continue;
    u := @pIdxInfo^.aConstraintUsage[i];
    u^.argvIndex := 1;
    u^.omit := 1;
    pIdxInfo^.estimatedCost := 1.0;
    pIdxInfo^.estimatedRows := 10;
    pIdxInfo^.idxNum := 1;
    Result := SQLITE_OK;
    Exit;
  end;
  pIdxInfo^.idxNum := 0;
  pIdxInfo^.estimatedCost := 2147483647.0;
  pIdxInfo^.estimatedRows := 2147483647;
  Result := SQLITE_CONSTRAINT;
end;

function sqlite3FossildeltaInit(db: PTsqlite3): i32;
const
  Enc = SQLITE_UTF8 or SQLITE_INNOCUOUS;
var
  rc: i32;
begin
  rc := sqlite3_create_function(db, 'delta_create', 2, Enc, nil,
                                @deltaCreateFunc, nil, nil);
  if rc = SQLITE_OK then
    rc := sqlite3_create_function(db, 'delta_apply', 2, Enc, nil,
                                  @deltaApplyFunc, nil, nil);
  if rc = SQLITE_OK then
    rc := sqlite3_create_function(db, 'delta_output_size', 1, Enc, nil,
                                  @deltaOutputSizeFunc, nil, nil);
  if rc = SQLITE_OK then
    rc := sqlite3_create_module(db, 'delta_parse',
                                @deltaparsevtabModule, nil);
  Result := rc;
end;

initialization
  FillChar(deltaparsevtabModule, SizeOf(deltaparsevtabModule), 0);
  deltaparsevtabModule.iVersion    := 0;
  deltaparsevtabModule.xConnect    := @deltaparsevtabConnect;
  deltaparsevtabModule.xBestIndex  := @deltaparsevtabBestIndex;
  deltaparsevtabModule.xDisconnect := @deltaparsevtabDisconnect;
  deltaparsevtabModule.xOpen       := @deltaparsevtabOpen;
  deltaparsevtabModule.xClose      := @deltaparsevtabClose;
  deltaparsevtabModule.xFilter     := @deltaparsevtabFilter;
  deltaparsevtabModule.xNext       := @deltaparsevtabNext;
  deltaparsevtabModule.xEof        := @deltaparsevtabEof;
  deltaparsevtabModule.xColumn     := @deltaparsevtabColumn;
  deltaparsevtabModule.xRowid      := @deltaparsevtabRowid;
end.
