{
  SPDX-License-Identifier: blessing

  Faithful port of ../sqlite3/ext/misc/ieee754.c (361 lines in C).

  Implements SQL functions for the exact display and input of IEEE-754
  binary64 floating-point numbers:

    ieee754(X)               -> 'ieee754(M,E)'
    ieee754(M, E)            -> M * pow(2, E)
    ieee754_mantissa(X)      -> M (signed)
    ieee754_exponent(X)      -> E (signed)
    ieee754_to_blob(X)       -> 8-byte big-endian blob
    ieee754_from_blob(B)     -> double from 8-byte big-endian blob
    ieee754_to_int(X)        -> int64 with the same bit pattern
    ieee754_from_int(N)      -> double with the same bit pattern
    ieee754_inc(R, N)        -> R bumped by N quanta

  Public entry: sqlite3IeeeInit(db) — equivalent to sqlite3_ieee_init()
  in C; safe to call multiple times.
}
{$I passqlite3.inc}
unit passqlite3ieee754;

interface

uses
  passqlite3types,
  passqlite3util,
  passqlite3vdbe,
  passqlite3main;

function sqlite3IeeeInit(db: PTsqlite3): i32;

implementation

uses
  SysUtils,
  passqlite3printf;

type
  { Type-pun helper for memcpy(&i, &r, 8) and friends.  Replaces the
    unaligned memcpy() shuffle the C source uses (ieee754.c:113, 123,
    132, 152, 212, 236, 253, 274, 289, 319, 321). }
  TBits64 = record
    case Byte of
      0: (r: Double);
      1: (i: i64);
      2: (u: u64);
  end;

{ The C build stores `iAux` as a per-row member of a static const
  struct array, then passes `&aFunc[i].iAux` as the function's user
  data so the dispatcher in ieee754func can branch on
  *(int*)sqlite3_user_data(context).  FPC has no equivalent
  initialised-record-array-element-pointer construct, so we keep three
  module-level integers (one per dispatch branch) and pass their
  addresses.  Mirrors ieee754.c:154..165 (the `switch` in ieee754func)
  and ieee754.c:340..342 (the registration table). }
var
  ieeeAux0: i32 = 0;  { ieee754(X) / ieee754(M,E)            -> formatted text / double }
  ieeeAux1: i32 = 1;  { ieee754_mantissa(X)                  -> int64 }
  ieeeAux2: i32 = 2;  { ieee754_exponent(X)                  -> int    }

{ ieee754func — direct port of ieee754func (ieee754.c:102..215).

  The single-argument form unpacks a binary64 into (M, E) such that
  X == M * 2^E with M an integer and the trailing zero bits of M
  shifted out.  The two-argument form composes a binary64 from (M, E).
  All bit-level shuffles mirror the C source.  Subnormals: when the
  IEEE biased exponent field is 0 the implicit leading bit is 0, and
  the C source signals this by left-shifting the mantissa once (so the
  m/e pair still satisfies X = M*2^(E-1075)). }
procedure ieee754func(pCtx: Psqlite3_context; argc: i32; argv: PPMem); cdecl;
var
  m, a: i64;
  r: Double;
  e: i32;
  isNeg: i32;
  zResult: AnsiString;
  bits: TBits64;
  pX: PByte;
  i: u32;
  v: u64;
  ee: i64;
  pAux: ^i32;
begin
  if argc = 1 then
  begin
    if (sqlite3_value_type(argv[0]) = SQLITE_BLOB)
       and (sqlite3_value_bytes(argv[0]) = SizeOf(Double)) then
    begin
      pX := PByte(sqlite3_value_blob(argv[0]));
      v := 0;
      for i := 0 to SizeOf(Double) - 1 do
        v := (v shl 8) or pX[i];
      bits.u := v;
      r := bits.r;
    end
    else
      r := sqlite3_value_double(argv[0]);
    if r < 0.0 then
    begin
      isNeg := 1;
      r := -r;
    end
    else
      isNeg := 0;
    bits.r := r;
    a := bits.i;
    if a = 0 then
    begin
      e := 0;
      m := 0;
    end
    else if u64(a) = u64($8000000000000000) then
    begin
      { Negative zero, after the unary negation above.  C falls into the
        sentinel branch with e=-1996 and m=-1; we keep the same magic
        numbers so the formatted output matches byte-for-byte. }
      e := -1996;
      m := -1;
    end
    else
    begin
      e := i32(a shr 52);
      m := a and ((i64(1) shl 52) - 1);
      if e = 0 then
        m := m shl 1
      else
        m := m or (i64(1) shl 52);
      while (e < 1075) and (m > 0) and ((m and 1) = 0) do
      begin
        m := m shr 1;
        Inc(e);
      end;
      if isNeg <> 0 then m := -m;
    end;
    pAux := sqlite3_user_data(pCtx);
    case pAux^ of
      0:
        begin
          { C uses sqlite3_snprintf("ieee754(%lld,%d)", m, e-1075).
            The Pascal port's sqlite3_snprintf has no varargs, so we
            build the same text via SysUtils.Format and pass through
            sqlite3_result_text with SQLITE_TRANSIENT so the buffer is
            copied before the string goes out of scope. }
          zResult := Format('ieee754(%d,%d)', [m, e - 1075]);
          sqlite3_result_text(pCtx, PAnsiChar(zResult), -1,
                              SQLITE_TRANSIENT);
        end;
      1:
        sqlite3_result_int64(pCtx, m);
      2:
        sqlite3_result_int(pCtx, e - 1075);
    end;
  end
  else
  begin
    isNeg := 0;
    m := sqlite3_value_int64(argv[0]);
    ee := sqlite3_value_int64(argv[1]);

    { Limit the range of e — Ticket 22dea1cfdb9151e4 (2021-03-02).
      Without this cap the shift loops below can iterate effectively
      forever on extreme inputs. }
    if ee > 10000 then
      ee := 10000
    else if ee < -10000 then
      ee := -10000;

    if m < 0 then
    begin
      if m < i64(-9223372036854775807) then Exit;
      isNeg := 1;
      m := -m;
    end
    else if (m = 0) and (ee > -1000) and (ee < 1000) then
    begin
      sqlite3_result_double(pCtx, 0.0);
      Exit;
    end;
    while ((m shr 32) and $ffe00000) <> 0 do
    begin
      m := m shr 1;
      Inc(ee);
    end;
    while (m <> 0) and (((m shr 32) and $fff00000) = 0) do
    begin
      m := m shl 1;
      Dec(ee);
    end;
    ee := ee + 1075;
    if ee <= 0 then
    begin
      { Subnormal. }
      if 1 - ee >= 64 then
        m := 0
      else
        m := m shr (1 - ee);
      ee := 0;
    end
    else if ee > $7ff then
      ee := $7ff;
    a := m and ((i64(1) shl 52) - 1);
    a := a or (ee shl 52);
    if isNeg <> 0 then a := i64(u64(a) or (u64(1) shl 63));
    bits.i := a;
    r := bits.r;
    sqlite3_result_double(pCtx, r);
  end;
end;

{ ieee754_from_blob — port of ieee754func_from_blob (ieee754.c:220..239).
  An 8-byte BLOB is interpreted as a big-endian binary64 and returned
  as a double. }
procedure ieee754func_from_blob(pCtx: Psqlite3_context; argc: i32;
                                argv: PPMem); cdecl;
var
  bits: TBits64;
  pX: PByte;
  i: u32;
  v: u64;
begin
  if (sqlite3_value_type(argv[0]) = SQLITE_BLOB)
     and (sqlite3_value_bytes(argv[0]) = SizeOf(Double)) then
  begin
    pX := PByte(sqlite3_value_blob(argv[0]));
    v := 0;
    for i := 0 to SizeOf(Double) - 1 do
      v := (v shl 8) or pX[i];
    bits.u := v;
    sqlite3_result_double(pCtx, bits.r);
  end;
end;

{ ieee754_to_blob — port of ieee754func_to_blob (ieee754.c:240..260).
  Emits the 8 bytes of a binary64 in big-endian order. }
procedure ieee754func_to_blob(pCtx: Psqlite3_context; argc: i32;
                              argv: PPMem); cdecl;
var
  bits: TBits64;
  a: array[0..SizeOf(Double) - 1] of Byte;
  v: u64;
  i: u32;
  vt: i32;
begin
  vt := sqlite3_value_type(argv[0]);
  if (vt = SQLITE_FLOAT) or (vt = SQLITE_INTEGER) then
  begin
    bits.r := sqlite3_value_double(argv[0]);
    v := bits.u;
    for i := 1 to SizeOf(Double) do
    begin
      a[SizeOf(Double) - i] := Byte(v and $ff);
      v := v shr 8;
    end;
    sqlite3_result_blob(pCtx, @a[0], SizeOf(Double), SQLITE_TRANSIENT);
  end;
end;

{ ieee754_from_int — port of ieee754func_from_int (ieee754.c:267..279).
  Re-interprets the bit pattern of a 64-bit integer as a binary64.
  No numeric conversion takes place. }
procedure ieee754func_from_int(pCtx: Psqlite3_context; argc: i32;
                               argv: PPMem); cdecl;
var
  bits: TBits64;
begin
  if sqlite3_value_type(argv[0]) = SQLITE_INTEGER then
  begin
    bits.i := sqlite3_value_int64(argv[0]);
    sqlite3_result_double(pCtx, bits.r);
  end;
end;

{ ieee754_to_int — port of ieee754func_to_int (ieee754.c:280..292).
  Re-interprets the bit pattern of a binary64 as a 64-bit integer. }
procedure ieee754func_to_int(pCtx: Psqlite3_context; argc: i32;
                             argv: PPMem); cdecl;
var
  bits: TBits64;
begin
  if sqlite3_value_type(argv[0]) = SQLITE_FLOAT then
  begin
    bits.r := sqlite3_value_double(argv[0]);
    sqlite3_result_int64(pCtx, bits.i);
  end;
end;

{ ieee754_inc(R, N) — port of ieee754inc (ieee754.c:307..323).
  Adds N to the integer interpretation of R's bits and returns the
  resulting double.  Walks the binary64 grid by N quanta. }
procedure ieee754inc(pCtx: Psqlite3_context; argc: i32;
                     argv: PPMem); cdecl;
var
  bits: TBits64;
  N: i64;
  m1, m2: u64;
begin
  bits.r := sqlite3_value_double(argv[0]);
  N := sqlite3_value_int64(argv[1]);
  m1 := bits.u;
  m2 := m1 + u64(N);
  bits.u := m2;
  sqlite3_result_double(pCtx, bits.r);
end;

function sqlite3IeeeInit(db: PTsqlite3): i32;
const
  Flags = SQLITE_UTF8 or SQLITE_INNOCUOUS;
var
  rc: i32;
begin
  rc := sqlite3_create_function(db, 'ieee754', 1, Flags, @ieeeAux0,
                                @ieee754func, nil, nil);
  if rc = SQLITE_OK then
    rc := sqlite3_create_function(db, 'ieee754', 2, Flags, @ieeeAux0,
                                  @ieee754func, nil, nil);
  if rc = SQLITE_OK then
    rc := sqlite3_create_function(db, 'ieee754_mantissa', 1, Flags,
                                  @ieeeAux1, @ieee754func, nil, nil);
  if rc = SQLITE_OK then
    rc := sqlite3_create_function(db, 'ieee754_exponent', 1, Flags,
                                  @ieeeAux2, @ieee754func, nil, nil);
  if rc = SQLITE_OK then
    rc := sqlite3_create_function(db, 'ieee754_to_blob', 1, Flags, nil,
                                  @ieee754func_to_blob, nil, nil);
  if rc = SQLITE_OK then
    rc := sqlite3_create_function(db, 'ieee754_from_blob', 1, Flags, nil,
                                  @ieee754func_from_blob, nil, nil);
  if rc = SQLITE_OK then
    rc := sqlite3_create_function(db, 'ieee754_to_int', 1, Flags, nil,
                                  @ieee754func_to_int, nil, nil);
  if rc = SQLITE_OK then
    rc := sqlite3_create_function(db, 'ieee754_from_int', 1, Flags, nil,
                                  @ieee754func_from_int, nil, nil);
  if rc = SQLITE_OK then
    rc := sqlite3_create_function(db, 'ieee754_inc', 2, Flags, nil,
                                  @ieee754inc, nil, nil);
  Result := rc;
end;

end.
