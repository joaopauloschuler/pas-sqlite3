{
  SPDX-License-Identifier: blessing

  Faithful port of ../sqlite3/ext/misc/decimal.c (952 lines in C).

  Routines for arbitrary-precision decimal math.  Provides:

    decimal(X) / decimal(X, N)         -> exact decimal text
    decimal_exp(X) / decimal_exp(X,N)  -> '%+#e'-style exponential text
    decimal_cmp(X, Y)                  -> -1 / 0 / +1 ordering
    decimal_add(X, Y)                  -> arbitrary-precision sum
    decimal_sub(X, Y)                  -> arbitrary-precision difference
    decimal_mul(X, Y)                  -> arbitrary-precision product
    decimal_pow2(N)                    -> exact decimal of 2**N
    decimal_sum(Y)                     -> aggregate / window sum
    decimal collation                  -> sort text in numeric order

  Public entry: sqlite3DecimalInit(db) — equivalent to
  sqlite3_decimal_init() in C; safe to call multiple times.
}
{$I passqlite3.inc}
unit passqlite3decimal;

interface

uses
  passqlite3types,
  passqlite3util,
  passqlite3os,
  passqlite3vdbe,
  passqlite3main;

function sqlite3DecimalInit(db: PTsqlite3): i32;

implementation

uses
  SysUtils;

const
  SQLITE_DECIMAL_MAX_DIGIT = 10000000;

type
  PDecimal = ^TDecimal;
  TDecimal = record
    sign:   Byte;     { 0 for positive, 1 for negative }
    oom:    Byte;     { True if an OOM is encountered }
    isNull: Byte;     { True if holds a NULL rather than a number }
    isInit: Byte;     { True upon initialisation }
    nDigit: i32;      { Total number of digits }
    nFrac:  i32;      { Number of digits to the right of the decimal point }
    a:      PShortInt; { Array of digits.  Most significant first. }
  end;

procedure decimalClear(p: PDecimal); inline;
begin
  sqlite3_free(p^.a);
end;

procedure decimalFree(p: PDecimal);
begin
  if p <> nil then
  begin
    decimalClear(p);
    sqlite3_free(p);
  end;
end;

function IsSpace(c: AnsiChar): Boolean; inline;
begin
  Result := (c = ' ') or (c = #9) or (c = #10) or (c = #11) or (c = #12) or (c = #13);
end;

{ decimalNewFromText — port of decimal.c:71..180. }
function decimalNewFromText(zIn: PAnsiChar; n: i32): PDecimal;
var
  p: PDecimal;
  i, j, neg, iExp: i32;
  c: AnsiChar;
  a2: PShortInt;
begin
  p := nil;
  iExp := 0;
  if zIn = nil then begin Result := nil; Exit; end;
  p := PDecimal(sqlite3_malloc64(SizeOf(TDecimal)));
  if p = nil then begin Result := nil; Exit; end;
  p^.sign := 0;
  p^.oom := 0;
  p^.isInit := 1;
  p^.isNull := 0;
  p^.nDigit := 0;
  p^.nFrac := 0;
  p^.a := PShortInt(sqlite3_malloc64(u64(n) + 1));
  if p^.a = nil then
  begin
    sqlite3_free(p);
    Result := nil;
    Exit;
  end;
  i := 0;
  while (i < n) and IsSpace(zIn[i]) do Inc(i);
  if (i < n) and (zIn[i] = '-') then
  begin
    p^.sign := 1;
    Inc(i);
  end
  else if (i < n) and (zIn[i] = '+') then
    Inc(i);
  while (i < n) and (zIn[i] = '0') do Inc(i);
  while i < n do
  begin
    c := zIn[i];
    if (c >= '0') and (c <= '9') then
    begin
      p^.a[p^.nDigit] := ShortInt(Ord(c) - Ord('0'));
      Inc(p^.nDigit);
    end
    else if c = '.' then
    begin
      p^.nFrac := p^.nDigit + 1;
    end
    else if (c = 'e') or (c = 'E') then
    begin
      j := i + 1;
      neg := 0;
      if j >= n then Break;
      if zIn[j] = '-' then
      begin
        neg := 1;
        Inc(j);
      end
      else if zIn[j] = '+' then
        Inc(j);
      while (j < n) and (iExp < 1000000) do
      begin
        if (zIn[j] >= '0') and (zIn[j] <= '9') then
          iExp := iExp * 10 + (Ord(zIn[j]) - Ord('0'));
        Inc(j);
      end;
      if neg <> 0 then iExp := -iExp;
      Break;
    end;
    Inc(i);
  end;
  if p^.nFrac <> 0 then
    p^.nFrac := p^.nDigit - (p^.nFrac - 1);
  if iExp > 0 then
  begin
    if p^.nFrac > 0 then
    begin
      if iExp <= p^.nFrac then
      begin
        p^.nFrac := p^.nFrac - iExp;
        iExp := 0;
      end
      else
      begin
        iExp := iExp - p^.nFrac;
        p^.nFrac := 0;
      end;
    end;
    if iExp > 0 then
    begin
      a2 := PShortInt(sqlite3_realloc64(p^.a, u64(p^.nDigit) + u64(iExp) + 1));
      if a2 = nil then
      begin
        sqlite3_free(p^.a);
        sqlite3_free(p);
        Result := nil;
        Exit;
      end;
      p^.a := a2;
      FillChar((p^.a + p^.nDigit)^, iExp, 0);
      p^.nDigit := p^.nDigit + iExp;
    end;
  end
  else if iExp < 0 then
  begin
    iExp := -iExp;
    j := p^.nDigit - p^.nFrac - 1; { reuse j as nExtra }
    if j <> 0 then
    begin
      if j >= iExp then
      begin
        p^.nFrac := p^.nFrac + iExp;
        iExp := 0;
      end
      else
      begin
        iExp := iExp - j;
        p^.nFrac := p^.nDigit - 1;
      end;
    end;
    if iExp > 0 then
    begin
      a2 := PShortInt(sqlite3_realloc64(p^.a, u64(p^.nDigit) + u64(iExp) + 1));
      if a2 = nil then
      begin
        sqlite3_free(p^.a);
        sqlite3_free(p);
        Result := nil;
        Exit;
      end;
      p^.a := a2;
      Move(p^.a^, (p^.a + iExp)^, p^.nDigit);
      FillChar(p^.a^, iExp, 0);
      p^.nDigit := p^.nDigit + iExp;
      p^.nFrac := p^.nFrac + iExp;
    end;
  end;
  if p^.sign <> 0 then
  begin
    i := 0;
    while (i < p^.nDigit) and (p^.a[i] = 0) do Inc(i);
    if i >= p^.nDigit then p^.sign := 0;
  end;
  if p^.nDigit > SQLITE_DECIMAL_MAX_DIGIT then
  begin
    sqlite3_free(p^.a);
    sqlite3_free(p);
    Result := nil;
    Exit;
  end;
  Result := p;
end;

{ Forward declarations. }
function decimalFromDouble(r: Double): PDecimal; forward;

{ decimal_new — port of decimal.c:196..247. }
function decimalNew(pCtx: Psqlite3_context; pIn: Psqlite3_value;
                    bTextOnly: i32): PDecimal;
var
  p: PDecimal;
  eType, n: i32;
  zIn: PAnsiChar;
  x: PByte;
  i: u32;
  v: u64;
  r: Double;
begin
  p := nil;
  eType := sqlite3_value_type(pIn);
  if (bTextOnly <> 0) and ((eType = SQLITE_FLOAT) or (eType = SQLITE_BLOB)) then
    eType := SQLITE_TEXT;
  case eType of
    SQLITE_TEXT, SQLITE_INTEGER:
      begin
        zIn := PAnsiChar(sqlite3_value_text(pIn));
        n := sqlite3_value_bytes(pIn);
        p := decimalNewFromText(zIn, n);
        if p = nil then
        begin
          if pCtx <> nil then sqlite3_result_error_nomem(pCtx);
          Result := nil;
          Exit;
        end;
      end;
    SQLITE_FLOAT:
      p := decimalFromDouble(sqlite3_value_double(pIn));
    SQLITE_BLOB:
      begin
        if sqlite3_value_bytes(pIn) <> SizeOf(r) then
        begin
          Result := nil;
          Exit;
        end;
        x := PByte(sqlite3_value_blob(pIn));
        v := 0;
        for i := 0 to SizeOf(r) - 1 do
          v := (v shl 8) or x[i];
        Move(v, r, SizeOf(r));
        p := decimalFromDouble(r);
      end;
    SQLITE_NULL: ;
  end;
  Result := p;
end;

{ decimal_result — port of decimal.c:252..300. }
procedure decimalResult(pCtx: Psqlite3_context; p: PDecimal);
var
  z: PAnsiChar;
  i, j, n: i32;
begin
  if (p = nil) or (p^.oom <> 0) then
  begin
    sqlite3_result_error_nomem(pCtx);
    Exit;
  end;
  if p^.isNull <> 0 then
  begin
    sqlite3_result_null(pCtx);
    Exit;
  end;
  z := PAnsiChar(sqlite3_malloc64(u64(p^.nDigit) + 4));
  if z = nil then
  begin
    sqlite3_result_error_nomem(pCtx);
    Exit;
  end;
  i := 0;
  if (p^.nDigit = 0) or ((p^.nDigit = 1) and (p^.a[0] = 0)) then
    p^.sign := 0;
  if p^.sign <> 0 then
  begin
    z[0] := '-';
    i := 1;
  end;
  n := p^.nDigit - p^.nFrac;
  if n <= 0 then
  begin
    z[i] := '0';
    Inc(i);
  end;
  j := 0;
  while (n > 1) and (p^.a[j] = 0) do
  begin
    Inc(j);
    Dec(n);
  end;
  while n > 0 do
  begin
    z[i] := AnsiChar(p^.a[j] + Ord('0'));
    Inc(i);
    Inc(j);
    Dec(n);
  end;
  if p^.nFrac <> 0 then
  begin
    z[i] := '.';
    Inc(i);
    repeat
      z[i] := AnsiChar(p^.a[j] + Ord('0'));
      Inc(i);
      Inc(j);
    until j >= p^.nDigit;
  end;
  z[i] := #0;
  sqlite3_result_text(pCtx, z, i, SQLITE_DYNAMIC);
end;

{ decimal_round — port of decimal.c:305..326. }
procedure decimalRound(p: PDecimal; N: i32);
var
  i, nZero: i32;
begin
  if N < 1 then Exit;
  if p = nil then Exit;
  if p^.nDigit <= N then Exit;
  nZero := 0;
  while (nZero < p^.nDigit) and (p^.a[nZero] = 0) do Inc(nZero);
  N := N + nZero;
  if p^.nDigit <= N then Exit;
  if p^.a[N] > 4 then
  begin
    Inc(p^.a[N - 1]);
    i := N - 1;
    while (i > 0) and (p^.a[i] > 9) do
    begin
      p^.a[i] := 0;
      Inc(p^.a[i - 1]);
      Dec(i);
    end;
    if p^.a[0] > 9 then
    begin
      p^.a[0] := 1;
      Dec(p^.nFrac);
    end;
  end;
  FillChar((p^.a + N)^, p^.nDigit - N, 0);
end;

{ decimal_result_sci — port of decimal.c:333..388. }
procedure decimalResultSci(pCtx: Psqlite3_context; p: PDecimal; N: i32);
var
  z: PAnsiChar;
  i, nZero, nDigit, nFrac, exp: i32;
  zero: ShortInt;
  a: PShortInt;
  expStr: AnsiString;
  expSign: AnsiChar;
  absExp: i32;
begin
  if (p = nil) or (p^.oom <> 0) then
  begin
    sqlite3_result_error_nomem(pCtx);
    Exit;
  end;
  if p^.isNull <> 0 then
  begin
    sqlite3_result_null(pCtx);
    Exit;
  end;
  if N < 1 then N := 0;
  nDigit := p^.nDigit;
  while (nDigit > N) and (p^.a[nDigit - 1] = 0) do Dec(nDigit);
  nZero := 0;
  while (nZero < nDigit) and (p^.a[nZero] = 0) do Inc(nZero);
  nFrac := p^.nFrac + (nDigit - p^.nDigit);
  nDigit := nDigit - nZero;
  z := PAnsiChar(sqlite3_malloc64(u64(nDigit) + 20));
  if z = nil then
  begin
    sqlite3_result_error_nomem(pCtx);
    Exit;
  end;
  if nDigit = 0 then
  begin
    zero := 0;
    a := @zero;
    nDigit := 1;
    nFrac := 0;
  end
  else
    a := @p^.a[nZero];
  if (p^.sign <> 0) and (nDigit > 0) then
    z[0] := '-'
  else
    z[0] := '+';
  z[1] := AnsiChar(a[0] + Ord('0'));
  z[2] := '.';
  if nDigit = 1 then
  begin
    z[3] := '0';
    i := 4;
  end
  else
  begin
    for i := 1 to nDigit - 1 do
      z[2 + i] := AnsiChar(a[i] + Ord('0'));
    i := nDigit + 2;
  end;
  exp := nDigit - nFrac - 1;
  { Format e%+03d (sign always present, exponent zero-padded to >=3 digits). }
  if exp < 0 then
  begin
    expSign := '-';
    absExp := -exp;
  end
  else
  begin
    expSign := '+';
    absExp := exp;
  end;
  expStr := 'e' + expSign;
  if absExp < 10 then
    expStr := expStr + '0' + IntToStr(absExp)
  else if absExp < 100 then
    expStr := expStr + IntToStr(absExp)
  else
    expStr := expStr + IntToStr(absExp);
  Move(expStr[1], z[i], Length(expStr));
  z[i + Length(expStr)] := #0;
  sqlite3_result_text(pCtx, z, -1, SQLITE_DYNAMIC);
end;

{ decimal_cmp — port of decimal.c:401..431. }
function decimalCmp(pA, pB: PDecimal): i32;
var
  nASig, nBSig, rc, n: i32;
  pTemp: PDecimal;
begin
  while (pA^.nFrac > 0) and (pA^.a[pA^.nDigit - 1] = 0) do
  begin
    Dec(pA^.nDigit);
    Dec(pA^.nFrac);
  end;
  while (pB^.nFrac > 0) and (pB^.a[pB^.nDigit - 1] = 0) do
  begin
    Dec(pB^.nDigit);
    Dec(pB^.nFrac);
  end;
  if pA^.sign <> pB^.sign then
  begin
    if pA^.sign <> 0 then Result := -1 else Result := +1;
    Exit;
  end;
  if pA^.sign <> 0 then
  begin
    pTemp := pA;
    pA := pB;
    pB := pTemp;
  end;
  nASig := pA^.nDigit - pA^.nFrac;
  nBSig := pB^.nDigit - pB^.nFrac;
  if nASig <> nBSig then
  begin
    Result := nASig - nBSig;
    Exit;
  end;
  n := pA^.nDigit;
  if n > pB^.nDigit then n := pB^.nDigit;
  rc := CompareByte(pA^.a^, pB^.a^, n);
  if rc = 0 then
    rc := pA^.nDigit - pB^.nDigit;
  Result := rc;
end;

{ SQL: decimal_cmp(X, Y).  decimal.c:439..459. }
procedure decimalCmpFunc(pCtx: Psqlite3_context; argc: i32;
                         argv: PPMem); cdecl;
var
  pA, pB: PDecimal;
  rc: i32;
begin
  pA := nil; pB := nil;
  pA := decimalNew(pCtx, argv[0], 1);
  if (pA = nil) or (pA^.isNull <> 0) then
  begin
    decimalFree(pA);
    decimalFree(pB);
    Exit;
  end;
  pB := decimalNew(pCtx, argv[1], 1);
  if (pB = nil) or (pB^.isNull <> 0) then
  begin
    decimalFree(pA);
    decimalFree(pB);
    Exit;
  end;
  rc := decimalCmp(pA, pB);
  if rc < 0 then rc := -1
  else if rc > 0 then rc := +1;
  sqlite3_result_int(pCtx, rc);
  decimalFree(pA);
  decimalFree(pB);
end;

{ decimal_expand — port of decimal.c:465..490. }
procedure decimalExpand(p: PDecimal; nDigit, nFrac: i32);
var
  nAddSig, nAddFrac: i32;
  a: PShortInt;
begin
  if p = nil then Exit;
  nAddFrac := nFrac - p^.nFrac;
  nAddSig := (nDigit - p^.nDigit) - nAddFrac;
  if (nAddFrac = 0) and (nAddSig = 0) then Exit;
  if nDigit + 1 > SQLITE_DECIMAL_MAX_DIGIT then
  begin
    p^.oom := 1;
    Exit;
  end;
  a := PShortInt(sqlite3_realloc64(p^.a, u64(nDigit) + 1));
  if a = nil then
  begin
    p^.oom := 1;
    Exit;
  end;
  p^.a := a;
  if nAddSig <> 0 then
  begin
    Move(p^.a^, (p^.a + nAddSig)^, p^.nDigit);
    FillChar(p^.a^, nAddSig, 0);
    p^.nDigit := p^.nDigit + nAddSig;
  end;
  if nAddFrac <> 0 then
  begin
    FillChar((p^.a + p^.nDigit)^, nAddFrac, 0);
    p^.nDigit := p^.nDigit + nAddFrac;
    p^.nFrac := p^.nFrac + nAddFrac;
  end;
end;

{ decimal_add — port of decimal.c:497..560. }
procedure decimalAdd(pA, pB: PDecimal);
var
  nSig, nFrac, nDigit, i, rc, x, carry, borrow: i32;
  aA, aB: PShortInt;
begin
  if pA = nil then Exit;
  if (pA^.oom <> 0) or (pB = nil) or (pB^.oom <> 0) then
  begin
    pA^.oom := 1;
    Exit;
  end;
  if (pA^.isNull <> 0) or (pB^.isNull <> 0) then
  begin
    pA^.isNull := 1;
    Exit;
  end;
  nSig := pA^.nDigit - pA^.nFrac;
  if (nSig <> 0) and (pA^.a[0] = 0) then Dec(nSig);
  if nSig < pB^.nDigit - pB^.nFrac then
    nSig := pB^.nDigit - pB^.nFrac;
  nFrac := pA^.nFrac;
  if nFrac < pB^.nFrac then nFrac := pB^.nFrac;
  nDigit := nSig + nFrac + 1;
  decimalExpand(pA, nDigit, nFrac);
  decimalExpand(pB, nDigit, nFrac);
  if (pA^.oom <> 0) or (pB^.oom <> 0) then
  begin
    pA^.oom := 1;
  end
  else
  begin
    if pA^.sign = pB^.sign then
    begin
      carry := 0;
      for i := nDigit - 1 downto 0 do
      begin
        x := pA^.a[i] + pB^.a[i] + carry;
        if x >= 10 then
        begin
          carry := 1;
          pA^.a[i] := ShortInt(x - 10);
        end
        else
        begin
          carry := 0;
          pA^.a[i] := ShortInt(x);
        end;
      end;
    end
    else
    begin
      borrow := 0;
      rc := CompareByte(pA^.a^, pB^.a^, nDigit);
      if rc < 0 then
      begin
        aA := pB^.a;
        aB := pA^.a;
        pA^.sign := 1 - pA^.sign;
      end
      else
      begin
        aA := pA^.a;
        aB := pB^.a;
      end;
      for i := nDigit - 1 downto 0 do
      begin
        x := aA[i] - aB[i] - borrow;
        if x < 0 then
        begin
          pA^.a[i] := ShortInt(x + 10);
          borrow := 1;
        end
        else
        begin
          pA^.a[i] := ShortInt(x);
          borrow := 0;
        end;
      end;
    end;
  end;
end;

{ decimalMul — port of decimal.c:570..618. }
procedure decimalMul(pA, pB: PDecimal);
var
  acc: PShortInt;
  i, j, k, minFrac, x, carry: i32;
  f: ShortInt;
  sumDigit: i64;
begin
  acc := nil;
  if (pA = nil) or (pA^.oom <> 0) or (pA^.isNull <> 0)
   or (pB = nil) or (pB^.oom <> 0) or (pB^.isNull <> 0) then
  begin
    sqlite3_free(acc);
    Exit;
  end;
  sumDigit := pA^.nDigit;
  sumDigit := sumDigit + pB^.nDigit;
  sumDigit := sumDigit + 2;
  if sumDigit > SQLITE_DECIMAL_MAX_DIGIT then
  begin
    pA^.oom := 1;
    Exit;
  end;
  acc := PShortInt(sqlite3_malloc64(u64(sumDigit)));
  if acc = nil then
  begin
    pA^.oom := 1;
    Exit;
  end;
  FillChar(acc^, pA^.nDigit + pB^.nDigit + 2, 0);
  minFrac := pA^.nFrac;
  if pB^.nFrac < minFrac then minFrac := pB^.nFrac;
  for i := pA^.nDigit - 1 downto 0 do
  begin
    f := pA^.a[i];
    carry := 0;
    j := pB^.nDigit - 1;
    k := i + j + 3;
    while j >= 0 do
    begin
      x := acc[k] + f * pB^.a[j] + carry;
      acc[k] := ShortInt(x mod 10);
      carry := x div 10;
      Dec(j);
      Dec(k);
    end;
    x := acc[k] + carry;
    acc[k] := ShortInt(x mod 10);
    Inc(acc[k - 1], x div 10);
  end;
  sqlite3_free(pA^.a);
  pA^.a := acc;
  acc := nil;
  pA^.nDigit := pA^.nDigit + pB^.nDigit + 2;
  pA^.nFrac := pA^.nFrac + pB^.nFrac;
  pA^.sign := pA^.sign xor pB^.sign;
  while (pA^.nFrac > minFrac) and (pA^.a[pA^.nDigit - 1] = 0) do
  begin
    Dec(pA^.nFrac);
    Dec(pA^.nDigit);
  end;
  sqlite3_free(acc);
end;

{ decimalPow2 — port of decimal.c:623..653. }
function decimalPow2(N: i32): PDecimal;
var
  pA, pX: PDecimal;
begin
  pA := nil; pX := nil;
  if (N < -20000) or (N > 20000) then
  begin
    Result := nil;
    Exit;
  end;
  pA := decimalNewFromText('1.0', 3);
  if (pA = nil) or (pA^.oom <> 0) then
  begin
    decimalFree(pA);
    Result := nil;
    Exit;
  end;
  if N = 0 then begin Result := pA; Exit; end;
  if N > 0 then
    pX := decimalNewFromText('2.0', 3)
  else
  begin
    N := -N;
    pX := decimalNewFromText('0.5', 3);
  end;
  if (pX = nil) or (pX^.oom <> 0) then
  begin
    decimalFree(pA);
    decimalFree(pX);
    Result := nil;
    Exit;
  end;
  while True do
  begin
    if (N and 1) <> 0 then
    begin
      decimalMul(pA, pX);
      if pA^.oom <> 0 then
      begin
        decimalFree(pA);
        decimalFree(pX);
        Result := nil;
        Exit;
      end;
    end;
    N := N shr 1;
    if N = 0 then Break;
    decimalMul(pX, pX);
  end;
  decimalFree(pX);
  Result := pA;
end;

{ decimalFromDouble — port of decimal.c:658..701. }
function decimalFromDouble(r: Double): PDecimal;
var
  m, a: i64;
  e, isNeg: i32;
  pA, pX: PDecimal;
  zNum: array[0..99] of AnsiChar;
  s: AnsiString;
begin
  if r < 0.0 then
  begin
    isNeg := 1;
    r := -r;
  end
  else
    isNeg := 0;
  Move(r, a, SizeOf(a));
  if (a = 0) or (a = i64($8000000000000000)) then
  begin
    e := 0;
    m := 0;
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
    e := e - 1075;
    if e > 971 then
    begin
      Result := nil;  { NaN or Infinity }
      Exit;
    end;
  end;
  s := IntToStr(m);
  Move(s[1], zNum[0], Length(s));
  zNum[Length(s)] := #0;
  pA := decimalNewFromText(@zNum[0], Length(s));
  pX := decimalPow2(e);
  decimalMul(pA, pX);
  decimalFree(pX);
  Result := pA;
end;

{ SQL: decimal(X) / decimal_exp(X).  decimal.c:716..737. }
procedure decimalFunc(pCtx: Psqlite3_context; argc: i32;
                      argv: PPMem); cdecl;
var
  p: PDecimal;
  N: i32;
begin
  p := decimalNew(pCtx, argv[0], 0);
  if argc = 2 then
  begin
    N := sqlite3_value_int(argv[1]);
    if N > 0 then decimalRound(p, N);
  end
  else
    N := 0;
  if p <> nil then
  begin
    if sqlite3_user_data(pCtx) <> nil then
      decimalResultSci(pCtx, p, N)
    else
      decimalResult(pCtx, p);
    decimalFree(p);
  end;
end;

{ Collation: decimal.  decimal.c:742..761. }
function decimalCollFunc(notUsed: Pointer;
                         nKey1: i32; pKey1: Pointer;
                         nKey2: i32; pKey2: Pointer): i32; cdecl;
var
  pA, pB: PDecimal;
  rc: i32;
begin
  pA := decimalNewFromText(PAnsiChar(pKey1), nKey1);
  pB := decimalNewFromText(PAnsiChar(pKey2), nKey2);
  if (pA = nil) or (pB = nil) then
    rc := 0
  else
    rc := decimalCmp(pA, pB);
  decimalFree(pA);
  decimalFree(pB);
  Result := rc;
end;

{ SQL: decimal_add(X, Y).  decimal.c:770..781. }
procedure decimalAddFunc(pCtx: Psqlite3_context; argc: i32;
                         argv: PPMem); cdecl;
var
  pA, pB: PDecimal;
begin
  pA := decimalNew(pCtx, argv[0], 1);
  pB := decimalNew(pCtx, argv[1], 1);
  decimalAdd(pA, pB);
  decimalResult(pCtx, pA);
  decimalFree(pA);
  decimalFree(pB);
end;

{ SQL: decimal_sub(X, Y).  decimal.c:783..798. }
procedure decimalSubFunc(pCtx: Psqlite3_context; argc: i32;
                         argv: PPMem); cdecl;
var
  pA, pB: PDecimal;
begin
  pA := decimalNew(pCtx, argv[0], 1);
  pB := decimalNew(pCtx, argv[1], 1);
  if pB <> nil then
  begin
    pB^.sign := 1 - pB^.sign;
    decimalAdd(pA, pB);
    decimalResult(pCtx, pA);
  end;
  decimalFree(pA);
  decimalFree(pB);
end;

{ Aggregate: decimal_sum(X) — step.  decimal.c:805..830. }
procedure decimalSumStep(pCtx: Psqlite3_context; argc: i32;
                         argv: PPMem); cdecl;
var
  p: PDecimal;
  pArg: PDecimal;
begin
  p := PDecimal(sqlite3_aggregate_context(pCtx, SizeOf(TDecimal)));
  if p = nil then Exit;
  if p^.isInit = 0 then
  begin
    p^.isInit := 1;
    p^.a := PShortInt(sqlite3_malloc64(2));
    if p^.a = nil then
      p^.oom := 1
    else
      p^.a[0] := 0;
    p^.nDigit := 1;
    p^.nFrac := 0;
  end;
  if sqlite3_value_type(argv[0]) = SQLITE_NULL then Exit;
  pArg := decimalNew(pCtx, argv[0], 1);
  decimalAdd(p, pArg);
  decimalFree(pArg);
end;

{ Aggregate: decimal_sum(X) — inverse.  decimal.c:831..846. }
procedure decimalSumInverse(pCtx: Psqlite3_context; argc: i32;
                            argv: PPMem); cdecl;
var
  p: PDecimal;
  pArg: PDecimal;
begin
  p := PDecimal(sqlite3_aggregate_context(pCtx, SizeOf(TDecimal)));
  if p = nil then Exit;
  if sqlite3_value_type(argv[0]) = SQLITE_NULL then Exit;
  pArg := decimalNew(pCtx, argv[0], 1);
  if pArg <> nil then pArg^.sign := 1 - pArg^.sign;
  decimalAdd(p, pArg);
  decimalFree(pArg);
end;

procedure decimalSumValue(pCtx: Psqlite3_context); cdecl;
var
  p: PDecimal;
begin
  p := PDecimal(sqlite3_aggregate_context(pCtx, 0));
  if p = nil then Exit;
  decimalResult(pCtx, p);
end;

procedure decimalSumFinalize(pCtx: Psqlite3_context); cdecl;
var
  p: PDecimal;
begin
  p := PDecimal(sqlite3_aggregate_context(pCtx, 0));
  if p = nil then Exit;
  decimalResult(pCtx, p);
  decimalClear(p);
end;

{ SQL: decimal_mul(X, Y).  decimal.c:864..886. }
procedure decimalMulFunc(pCtx: Psqlite3_context; argc: i32;
                         argv: PPMem); cdecl;
var
  pA, pB: PDecimal;
begin
  pA := decimalNew(pCtx, argv[0], 1);
  pB := decimalNew(pCtx, argv[1], 1);
  if (pA = nil) or (pA^.oom <> 0) or (pA^.isNull <> 0)
   or (pB = nil) or (pB^.oom <> 0) or (pB^.isNull <> 0) then
  begin
    decimalFree(pA);
    decimalFree(pB);
    Exit;
  end;
  decimalMul(pA, pB);
  if pA^.oom <> 0 then
  begin
    decimalFree(pA);
    decimalFree(pB);
    Exit;
  end;
  decimalResult(pCtx, pA);
  decimalFree(pA);
  decimalFree(pB);
end;

{ SQL: decimal_pow2(N).  decimal.c:893..904. }
procedure decimalPow2Func(pCtx: Psqlite3_context; argc: i32;
                          argv: PPMem); cdecl;
var
  pA: PDecimal;
begin
  if sqlite3_value_type(argv[0]) = SQLITE_INTEGER then
  begin
    pA := decimalPow2(sqlite3_value_int(argv[0]));
    decimalResultSci(pCtx, pA, 0);
    decimalFree(pA);
  end;
end;

{ Registration table mirroring aFunc[] in decimal.c:920..930. }
type
  TDecimalReg = record
    zName: PAnsiChar;
    nArg:  i32;
    iArg:  i32;
  end;

const
  aDecFunc: array[0..8] of TDecimalReg = (
    (zName: 'decimal';      nArg: 1; iArg: 0),
    (zName: 'decimal';      nArg: 2; iArg: 0),
    (zName: 'decimal_exp';  nArg: 1; iArg: 1),
    (zName: 'decimal_exp';  nArg: 2; iArg: 1),
    (zName: 'decimal_cmp';  nArg: 2; iArg: 0),
    (zName: 'decimal_add';  nArg: 2; iArg: 0),
    (zName: 'decimal_sub';  nArg: 2; iArg: 0),
    (zName: 'decimal_mul';  nArg: 2; iArg: 0),
    (zName: 'decimal_pow2'; nArg: 1; iArg: 0)
  );

function sqlite3DecimalInit(db: PTsqlite3): i32;
const
  Flags = SQLITE_UTF8 or SQLITE_INNOCUOUS or SQLITE_DETERMINISTIC;
var
  rc, i: i32;
  xFunc: Pointer;
  pUser: Pointer;
begin
  rc := SQLITE_OK;
  for i := 0 to High(aDecFunc) do
  begin
    case i of
      0..3: xFunc := @decimalFunc;
      4:    xFunc := @decimalCmpFunc;
      5:    xFunc := @decimalAddFunc;
      6:    xFunc := @decimalSubFunc;
      7:    xFunc := @decimalMulFunc;
      8:    xFunc := @decimalPow2Func;
    else
      xFunc := nil;
    end;
    if aDecFunc[i].iArg <> 0 then pUser := db else pUser := nil;
    rc := sqlite3_create_function(db, aDecFunc[i].zName, aDecFunc[i].nArg,
              Flags, pUser, xFunc, nil, nil);
    if rc <> SQLITE_OK then Break;
  end;
  if rc = SQLITE_OK then
    rc := sqlite3_create_window_function(db, 'decimal_sum', 1, Flags, nil,
              @decimalSumStep, @decimalSumFinalize,
              @decimalSumValue, @decimalSumInverse, nil);
  if rc = SQLITE_OK then
    rc := sqlite3_create_collation(db, 'decimal', SQLITE_UTF8, nil,
              @decimalCollFunc);
  Result := rc;
end;

end.
