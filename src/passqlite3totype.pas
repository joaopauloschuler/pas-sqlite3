{
  SPDX-License-Identifier: blessing

  Faithful port of ../sqlite3/ext/misc/totype.c (528 lines in C).

  Implements the SQL functions tointeger(X) and toreal(X).

  - tointeger(X) returns X interpreted as a 64-bit signed integer if the
    conversion is lossless (integer/real with integer value, decimal text,
    or 8-byte little-endian BLOB), otherwise NULL.
  - toreal(X) returns X interpreted as IEEE-754 double if the conversion
    is lossless (integer that round-trips through double, real, decimal
    text without trailing junk, or 8-byte big-endian BLOB), otherwise
    NULL.

  Helpers (totypeIsspace, totypeIsdigit, totypeCompare2pow63,
  totypeAtoi64, totypeAtoF, totypeDoubleToInt) mirror the C source 1:1.

  The Pascal port targets x86-64 Linux exclusively (per README), so the
  endianness compile-time guards collapse to the little-endian arms.

  Public entry: sqlite3TotypeInit(db) — equivalent to sqlite3_totype_init()
  in C; safe to call multiple times.
}
{$I passqlite3.inc}
unit passqlite3totype;

interface

uses
  passqlite3types,
  passqlite3util,
  passqlite3vdbe,
  passqlite3main;

function sqlite3TotypeInit(db: PTsqlite3): i32;

implementation

const
  LARGEST_INT64  : i64 = i64($7FFFFFFFFFFFFFFF);
  SMALLEST_INT64 : i64 = i64($8000000000000000);

  { x86-64 Linux: little-endian. }
  TOTYPE_BIGENDIAN    = 0;
  TOTYPE_LITTLEENDIAN = 1;

{ Whitespace per C totypeIsspace (totype.c:70..72). }
function totypeIsspace(c: Byte): Boolean; inline;
begin
  Result := (c = Ord(' ')) or (c = 9) or (c = 10) or
            (c = 11) or (c = 12) or (c = 13);
end;

{ Digit per C totypeIsdigit (totype.c:77..79). }
function totypeIsdigit(c: Byte): Boolean; inline;
begin
  Result := (c >= Ord('0')) and (c <= Ord('9'));
end;

{ Compare 19-char string zNum (not necessarily NUL-terminated) against
  9223372036854775808.  Returns negative/zero/positive.  Last digit
  difference is preserved unscaled.  Mirrors totypeCompare2pow63
  (totype.c:95..107). }
function totypeCompare2pow63(zNum: PAnsiChar): i32;
const
  pow63: array[0..17] of AnsiChar = '922337203685477580';
var
  c, i: i32;
begin
  c := 0;
  i := 0;
  while (c = 0) and (i < 18) do
  begin
    c := (i32(Byte(zNum[i])) - i32(Byte(pow63[i]))) * 10;
    Inc(i);
  end;
  if c = 0 then
    c := i32(Byte(zNum[18])) - Ord('8');
  Result := c;
end;

{ Convert a (not necessarily NUL-terminated) numeric text run of `length`
  bytes into a 64-bit signed integer.

  Returns:
    0 — clean fit, *pNum holds the value.
    1 — overflow, non-numeric tail, empty input, or > 19 digits.
    2 — exactly 9223372036854775808 in positive form (caller can negate
        for SMALLEST_INT64).

  Mirrors totypeAtoi64 (totype.c:125..181). }
function totypeAtoi64(zNum: PAnsiChar; pNum: Pi64; length: i32): i32;
var
  u: u64;
  neg, i, c, nonNum: i32;
  zStart, zEnd, p: PAnsiChar;
begin
  u := 0;
  neg := 0;
  c := 0;
  nonNum := 0;
  p := zNum;
  zEnd := zNum + length;

  while (p < zEnd) and totypeIsspace(Byte(p^)) do Inc(p);
  if p < zEnd then
  begin
    if p^ = '-' then
    begin
      neg := 1;
      Inc(p);
    end
    else if p^ = '+' then
      Inc(p);
  end;
  zStart := p;
  while (p < zEnd) and (p^ = '0') do Inc(p);   { skip leading zeroes }

  i := 0;
  while (p + i < zEnd) do
  begin
    c := i32(Byte(p[i]));
    if (c < Ord('0')) or (c > Ord('9')) then Break;
    u := u * 10 + u64(c - Ord('0'));
    Inc(i);
  end;

  if u > u64(LARGEST_INT64) then
    pNum^ := SMALLEST_INT64
  else if neg <> 0 then
    pNum^ := -i64(u)
  else
    pNum^ := i64(u);

  if ((c <> 0) and (p + i < zEnd)) or ((i = 0) and (zStart = p))
       or (i > 19) or (nonNum <> 0) then
  begin
    Result := 1;
    Exit;
  end
  else if i < 19 then
  begin
    Result := 0;
    Exit;
  end
  else
  begin
    c := totypeCompare2pow63(p);
    if c < 0 then
      Result := 0
    else if c > 0 then
      Result := 1
    else
    begin
      { exactly 2^63: fits only if negative. }
      if neg <> 0 then Result := 0 else Result := 2;
    end;
  end;
end;

{ Parse a real number out of z[0..length-1] into pResult.  Returns True
  iff every byte was consumed (modulo leading/trailing whitespace), the
  significand had at least one digit, and the exponent (if any) was
  well-formed.  Mirrors totypeAtoF (totype.c:204..351). }
function totypeAtoF(z: PAnsiChar; pResult: PDouble; length: i32): Boolean;
label
  totype_atof_calc;
var
  zEnd, p: PAnsiChar;
  sign, d, esign, e, eValid, nDigits, nonNum: i32;
  s: i64;
  result_d, scale: Double;
begin
  p := z;
  zEnd := z + length;
  sign := 1;
  s := 0;
  d := 0;
  esign := 1;
  e := 0;
  eValid := 1;
  nDigits := 0;
  nonNum := 0;
  result_d := 0.0;

  pResult^ := 0.0;

  while (p < zEnd) and totypeIsspace(Byte(p^)) do Inc(p);
  if p >= zEnd then begin Result := False; Exit; end;

  if p^ = '-' then
  begin
    sign := -1;
    Inc(p);
  end
  else if p^ = '+' then
    Inc(p);

  while (p < zEnd) and (p^ = '0') do begin Inc(p); Inc(nDigits); end;

  while (p < zEnd) and totypeIsdigit(Byte(p^)) and
        (s < ((LARGEST_INT64 - 9) div 10)) do
  begin
    s := s * 10 + (i32(Byte(p^)) - Ord('0'));
    Inc(p); Inc(nDigits);
  end;

  while (p < zEnd) and totypeIsdigit(Byte(p^)) do
  begin
    Inc(p); Inc(nDigits); Inc(d);
  end;
  if p >= zEnd then goto totype_atof_calc;

  if p^ = '.' then
  begin
    Inc(p);
    while (p < zEnd) and totypeIsdigit(Byte(p^)) and
          (s < ((LARGEST_INT64 - 9) div 10)) do
    begin
      s := s * 10 + (i32(Byte(p^)) - Ord('0'));
      Inc(p); Inc(nDigits); Dec(d);
    end;
    while (p < zEnd) and totypeIsdigit(Byte(p^)) do
    begin
      Inc(p); Inc(nDigits);
    end;
  end;
  if p >= zEnd then goto totype_atof_calc;

  if (p^ = 'e') or (p^ = 'E') then
  begin
    Inc(p);
    eValid := 0;
    if p >= zEnd then goto totype_atof_calc;
    if p^ = '-' then
    begin
      esign := -1;
      Inc(p);
    end
    else if p^ = '+' then
      Inc(p);
    while (p < zEnd) and totypeIsdigit(Byte(p^)) do
    begin
      if e < 10000 then
        e := e * 10 + (i32(Byte(p^)) - Ord('0'))
      else
        e := 10000;
      Inc(p);
      eValid := 1;
    end;
  end;

  if (nDigits <> 0) and (eValid <> 0) then
    while (p < zEnd) and totypeIsspace(Byte(p^)) do Inc(p);

totype_atof_calc:
  e := (e * esign) + d;
  if e < 0 then
  begin
    esign := -1;
    e := -e;
  end
  else
    esign := 1;

  if s = 0 then
  begin
    if (sign < 0) and (nDigits <> 0) then
      result_d := -0.0
    else
      result_d := 0.0;
  end
  else
  begin
    if esign > 0 then
    begin
      while (s < (LARGEST_INT64 div 10)) and (e > 0) do
      begin
        Dec(e);
        s := s * 10;
      end;
    end
    else
    begin
      while ((s mod 10) = 0) and (e > 0) do
      begin
        Dec(e);
        s := s div 10;
      end;
    end;

    if sign < 0 then s := -s;

    if e <> 0 then
    begin
      scale := 1.0;
      if (e > 307) and (e < 342) then
      begin
        while (e mod 308) <> 0 do
        begin
          scale := scale * 1.0e+1;
          Dec(e);
        end;
        if esign < 0 then
        begin
          result_d := s / scale;
          result_d := result_d / 1.0e+308;
        end
        else
        begin
          result_d := s * scale;
          result_d := result_d * 1.0e+308;
        end;
      end
      else if e >= 342 then
      begin
        if esign < 0 then
          result_d := 0.0 * s
        else
          result_d := 1.0e+308 * 1.0e+308 * s; { Infinity }
      end
      else
      begin
        while (e mod 22) <> 0 do
        begin
          scale := scale * 1.0e+1;
          Dec(e);
        end;
        while e > 0 do
        begin
          scale := scale * 1.0e+22;
          Dec(e, 22);
        end;
        if esign < 0 then
          result_d := s / scale
        else
          result_d := s * scale;
      end;
    end
    else
      result_d := Double(s);
  end;

  pResult^ := result_d;
  Result := (p >= zEnd) and (nDigits > 0) and (eValid <> 0) and (nonNum = 0);
end;

{ Modified copy of internal sqlite3RealToI64 (totype.c:361..365): clamp
  to the nearest exactly-representable doubles bracketing INT64_MIN /
  INT64_MAX so a round-trip through (i64) cannot raise UBSAN. }
function totypeDoubleToInt(r: Double): i64;
begin
  if r < -9223372036854774784.0 then begin Result := 0; Exit; end;
  if r > +9223372036854774784.0 then begin Result := 0; Exit; end;
  Result := i64(Trunc(r));
end;

{ tointeger(X) — totype.c:372..431. }
procedure tointegerFunc(pCtx: Psqlite3_context; argc: i32; argv: PPMem); cdecl;
var
  rVal: Double;
  iVal: i64;
  zBlob: PByte;
  zStr: PAnsiChar;
  nBlob, nStr, i: i32;
  zBlobRev: array[0..7] of Byte;
begin
  case sqlite3_value_type(argv[0]) of
    SQLITE_FLOAT:
      begin
        rVal := sqlite3_value_double(argv[0]);
        iVal := totypeDoubleToInt(rVal);
        if rVal = Double(iVal) then
          sqlite3_result_int64(pCtx, iVal);
      end;
    SQLITE_INTEGER:
      sqlite3_result_int64(pCtx, sqlite3_value_int64(argv[0]));
    SQLITE_BLOB:
      begin
        zBlob := PByte(sqlite3_value_blob(argv[0]));
        if zBlob <> nil then
        begin
          nBlob := sqlite3_value_bytes(argv[0]);
          if nBlob = SizeOf(i64) then
          begin
            if TOTYPE_BIGENDIAN <> 0 then
            begin
              for i := 0 to SizeOf(i64) - 1 do
                zBlobRev[i] := zBlob[SizeOf(i64) - 1 - i];
              Move(zBlobRev[0], iVal, SizeOf(i64));
            end
            else
              Move(zBlob[0], iVal, SizeOf(i64));
            sqlite3_result_int64(pCtx, iVal);
          end;
        end;
      end;
    SQLITE_TEXT:
      begin
        zStr := PAnsiChar(sqlite3_value_text(argv[0]));
        if zStr <> nil then
        begin
          nStr := sqlite3_value_bytes(argv[0]);
          if (nStr <> 0) and (not totypeIsspace(Byte(zStr[0]))) then
          begin
            if totypeAtoi64(zStr, @iVal, nStr) = 0 then
              sqlite3_result_int64(pCtx, iVal);
          end;
        end;
      end;
  end;
end;

{ toreal(X) — totype.c:442..502. }
procedure torealFunc(pCtx: Psqlite3_context; argc: i32; argv: PPMem); cdecl;
var
  iVal: i64;
  rVal: Double;
  zBlob: PByte;
  zStr: PAnsiChar;
  nBlob, nStr, i: i32;
  zBlobRev: array[0..7] of Byte;
begin
  case sqlite3_value_type(argv[0]) of
    SQLITE_FLOAT:
      sqlite3_result_double(pCtx, sqlite3_value_double(argv[0]));
    SQLITE_INTEGER:
      begin
        iVal := sqlite3_value_int64(argv[0]);
        rVal := Double(iVal);
        if iVal = totypeDoubleToInt(rVal) then
          sqlite3_result_double(pCtx, rVal);
      end;
    SQLITE_BLOB:
      begin
        zBlob := PByte(sqlite3_value_blob(argv[0]));
        if zBlob <> nil then
        begin
          nBlob := sqlite3_value_bytes(argv[0]);
          if nBlob = SizeOf(Double) then
          begin
            { C source: if (TOTYPE_LITTLEENDIAN) reverse — i.e. the BLOB
              is *big*-endian, so swap on a little-endian host. }
            if TOTYPE_LITTLEENDIAN <> 0 then
            begin
              for i := 0 to SizeOf(Double) - 1 do
                zBlobRev[i] := zBlob[SizeOf(Double) - 1 - i];
              Move(zBlobRev[0], rVal, SizeOf(Double));
            end
            else
              Move(zBlob[0], rVal, SizeOf(Double));
            sqlite3_result_double(pCtx, rVal);
          end;
        end;
      end;
    SQLITE_TEXT:
      begin
        zStr := PAnsiChar(sqlite3_value_text(argv[0]));
        if zStr <> nil then
        begin
          nStr := sqlite3_value_bytes(argv[0]);
          if (nStr <> 0)
             and (not totypeIsspace(Byte(zStr[0])))
             and (not totypeIsspace(Byte(zStr[nStr - 1]))) then
          begin
            if totypeAtoF(zStr, @rVal, nStr) then
              sqlite3_result_double(pCtx, rVal);
          end;
        end;
      end;
  end;
end;

function sqlite3TotypeInit(db: PTsqlite3): i32;
const
  Flags = SQLITE_UTF8 or SQLITE_DETERMINISTIC or SQLITE_INNOCUOUS;
var
  rc: i32;
begin
  rc := sqlite3_create_function(db, 'tointeger', 1, Flags, nil,
                                @tointegerFunc, nil, nil);
  if rc = SQLITE_OK then
    rc := sqlite3_create_function(db, 'toreal', 1, Flags, nil,
                                  @torealFunc, nil, nil);
  Result := rc;
end;

end.
