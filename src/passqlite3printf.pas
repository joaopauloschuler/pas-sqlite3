{$I passqlite3.inc}
unit passqlite3printf;

{
  Phase 6.bis.4a/b — printf core (port of sqlite3/src/printf.c).

  Lands the printf machinery referenced as a recurring blocker by Phase
  6.bis.1c..f and 6.bis.2a..d.  Public surface:

    * sqlite3_mprintf(fmt, ...)        — heap (libc-malloc) result
    * sqlite3_vmprintf(fmt, va_list)   — same, va_list-based
    * sqlite3_snprintf(n, buf, fmt, ...) and _vsnprintf — stack buffer
    * sqlite3MPrintf(db, fmt, ...)     — sqlite3DbMalloc-backed result
    * sqlite3VMPrintf(db, fmt, va_list)
    * sqlite3MAppendf(db, zOld, fmt, ...) — concat helper

  Conversions implemented:

    %s   string                          (FLAG_STRING, infinite precision)
    %z   string + free after consumption (treated as %s; caller-side free)
    %d   signed decimal (i32)
    %lld signed decimal (i64) — also  %ld
    %u   unsigned decimal (u32)
    %x   lower-case hex
    %X   upper-case hex
    %o   octal
    %c   single ASCII character (i32)
    %p   pointer (lower-case hex, 0x-prefixed)
    %%   literal '%'
    %q   SQL string escape (single quotes doubled)
    %Q   SQL string escape, wrapped in single quotes; nil → "NULL"
    %w   SQL identifier escape (double quotes doubled)
    %T   pointer to TToken — emits .n bytes from .z
    %S   pointer to TSrcItem — emits zAlias / zName / subquery-descriptor
         (etSRCITEM, printf.c:975..1008).  The `!` flag (altform2)
         suppresses the zAlias-takes-priority rule.
    %r   English ordinal suffix on signed integer (etORDINAL,
         printf.c:481..488).
    %f   fixed-point float        (etFLOAT,   printf.c:528..738)
    %e %E exponential             (etEXP)
    %g %G generic / shortest      (etGENERIC; defers to etFLOAT/etEXP
         depending on magnitude).  Backed by the FpDecode / Fp2Convert10
         mini-port from util.c (see PowerOfTen / Multiply128 below).

  Width / precision / left-align / zero-pad / +/space / `#` (alt-form) /
  `!` (alt-form-2: 20-digit precision instead of 16) flags supported for
  integer, string and float conversions.

  All conversions referenced by the C reference's printf.c are now
  ported; %S landed in 6.bis.4b.2b once Phase 7 stabilised TSrcItem.

  Allocation contract:

    * sqlite3_mprintf / _vmprintf / sqlite3_snprintf return libc-allocated
      memory (sqlite3Malloc) and the caller releases via sqlite3_free.

    * sqlite3MPrintf / sqlite3VMPrintf return sqlite3DbMalloc memory and
      the caller releases via sqlite3DbFree.  When db = nil they fall back
      to libc allocation (matches the C reference's
      `db ? sqlite3DbMallocSize(...) : malloc`).

  Both return nil on OOM; the caller already handles that path
  (sqlite3OomFault / SQLITE_NOMEM).
}

interface

uses
  passqlite3types,
  passqlite3util;

{ Heap (libc) variants — Pascal-side variadic; the cdecl one-arg stubs in
  passqlite3util are kept untouched (they front the libc vasprintf path
  used by external callers).  These names use the `Pf` suffix so there
  is no clash with passqlite3util when both units are imported. }
function sqlite3PfMprintf(fmt: PAnsiChar;
  const args: array of const): PAnsiChar;
function sqlite3PfSnprintf(n: i32; zBuf: PAnsiChar; fmt: PAnsiChar;
  const args: array of const): PAnsiChar;

{ Connection-aware variants — sqlite3DbMalloc-backed.  pass nil db to fall
  back to libc malloc. }
function sqlite3MPrintf(db: Psqlite3db; fmt: PAnsiChar;
  const args: array of const): PAnsiChar;
function sqlite3VMPrintf(db: Psqlite3db; fmt: PAnsiChar;
  const args: array of const): PAnsiChar;

{ Append fmt-formatted text to zOld (which is freed); returns the
  combined string allocated via sqlite3DbMalloc.  Mirrors
  printf.c:sqlite3MAppendf. }
function sqlite3MAppendf(db: Psqlite3db; zOld: PAnsiChar; fmt: PAnsiChar;
  const args: array of const): PAnsiChar;

{ Core renderer: format `fmt` against `args`, return result as AnsiString.
  Used by every public entry above plus internal callers that prefer to
  stay in Pascal-string land. }
function sqlite3FormatStr(fmt: PAnsiChar;
  const args: array of const): AnsiString;

implementation

uses
  SysUtils;

{ ============================================================
  Internal accumulator — grow-on-demand AnsiString builder.  Avoids the
  inherent quadratic cost of repeated concat by sizing in chunks.
  ============================================================ }
type
  TAccum = record
    buf:   AnsiString; { Pascal-managed; may be empty }
    used:  PtrInt;     { count of bytes actually written (1..Length(buf)) }
  end;

procedure accumInit(out a: TAccum);
begin
  SetLength(a.buf, 64);
  a.used := 0;
end;

procedure accumGrow(var a: TAccum; need: PtrInt);
var newCap: PtrInt;
begin
  newCap := Length(a.buf);
  if newCap < 64 then newCap := 64;
  while newCap - a.used < need do newCap := newCap * 2;
  if newCap <> Length(a.buf) then SetLength(a.buf, newCap);
end;

procedure accumPutChar(var a: TAccum; c: AnsiChar); inline;
begin
  if a.used >= Length(a.buf) then accumGrow(a, 1);
  a.buf[a.used + 1] := c;
  Inc(a.used);
end;

procedure accumPut(var a: TAccum; const s: AnsiString); inline;
var n: PtrInt;
begin
  n := Length(s);
  if n = 0 then Exit;
  if a.used + n > Length(a.buf) then accumGrow(a, n);
  Move(PAnsiChar(s)^, a.buf[a.used + 1], n);
  Inc(a.used, n);
end;

procedure accumPutPC(var a: TAccum; z: PAnsiChar; n: PtrInt); inline;
begin
  if (z = nil) or (n <= 0) then Exit;
  if a.used + n > Length(a.buf) then accumGrow(a, n);
  Move(z^, a.buf[a.used + 1], n);
  Inc(a.used, n);
end;

function accumFinish(var a: TAccum): AnsiString; inline;
begin
  SetLength(a.buf, a.used);
  Result := a.buf;
end;

{ ============================================================
  Conversion helpers
  ============================================================ }

{ Render an unsigned 64-bit value into base 8/10/16 (lower or upper).
  Returns the digits string (no sign, no prefix). }
function renderUint(v: u64; base: u8; upper: Boolean): AnsiString;
const
  lo: array[0..15] of AnsiChar = '0123456789abcdef';
  hi: array[0..15] of AnsiChar = '0123456789ABCDEF';
var
  buf: array[0..31] of AnsiChar;
  i: i32;
begin
  if v = 0 then begin Result := '0'; Exit; end;
  i := 32;
  while v > 0 do begin
    Dec(i);
    if upper then buf[i] := hi[v mod base]
    else          buf[i] := lo[v mod base];
    v := v div base;
  end;
  SetString(Result, @buf[i], 32 - i);
end;

{ Apply width/precision/flags to a base value-string and append to a. }
procedure emitField(var a: TAccum; const body: AnsiString;
  const prefix: AnsiString;
  width, prec: i32; leftAlign, zeroPad: Boolean;
  isString: Boolean);
var
  total, padN: i32;
  use: AnsiString;
  pre: AnsiString;
begin
  use := body;
  if (prec >= 0) and isString and (Length(use) > prec) then
    SetLength(use, prec);
  if (prec > Length(use)) and (not isString) then begin
    { numeric precision: pad with leading zeros }
    while Length(use) < prec do use := '0' + use;
    zeroPad := False;
  end;
  pre := prefix;
  total := Length(pre) + Length(use);
  if width > total then padN := width - total else padN := 0;
  if leftAlign then begin
    accumPut(a, pre);
    accumPut(a, use);
    while padN > 0 do begin accumPutChar(a, ' '); Dec(padN); end;
  end else if zeroPad and (not isString) then begin
    accumPut(a, pre);
    while padN > 0 do begin accumPutChar(a, '0'); Dec(padN); end;
    accumPut(a, use);
  end else begin
    while padN > 0 do begin accumPutChar(a, ' '); Dec(padN); end;
    accumPut(a, pre);
    accumPut(a, use);
  end;
end;

{ Pull the iCh-th argument as i64 — handles all integer-shaped TVarRec
  variants. }
function argAsI64(const v: TVarRec): i64;
begin
  case v.VType of
    vtInteger:  Result := v.VInteger;
    vtInt64:    Result := v.VInt64^;
    vtQWord:    Result := i64(v.VQWord^);
    vtBoolean:  if v.VBoolean then Result := 1 else Result := 0;
    vtChar:     Result := Ord(v.VChar);
    vtWideChar: Result := Ord(v.VWideChar);
    vtPointer:  Result := PtrInt(v.VPointer);
    vtObject:   Result := PtrInt(v.VObject);
    vtClass:    Result := PtrInt(Pointer(v.VClass));
  else
    Result := 0;
  end;
end;

function argAsPointer(const v: TVarRec): Pointer;
begin
  case v.VType of
    vtPointer:    Result := v.VPointer;
    vtPChar:      Result := v.VPChar;
    vtAnsiString: Result := v.VAnsiString;
    vtString:     Result := v.VString;
    vtObject:     Result := v.VObject;
    vtClass:      Result := Pointer(v.VClass);
    vtInteger:    Result := Pointer(PtrInt(v.VInteger));
    vtInt64:      Result := Pointer(PtrInt(v.VInt64^));
  else
    Result := nil;
  end;
end;

function argAsStr(const v: TVarRec; out wasNil: Boolean): AnsiString;
var p: PAnsiChar;
begin
  wasNil := False;
  case v.VType of
    vtPChar:      begin
                    p := v.VPChar;
                    if p = nil then begin wasNil := True; Result := ''; end
                    else            Result := AnsiString(p);
                  end;
    vtAnsiString: if v.VAnsiString = nil then
                  begin wasNil := True; Result := ''; end
                  else Result := AnsiString(v.VAnsiString);
    vtString:     if v.VString = nil then begin wasNil := True; Result := ''; end
                  else Result := v.VString^;
    vtChar:       Result := v.VChar;
    vtPointer:    if v.VPointer = nil then begin wasNil := True; Result := ''; end
                  else Result := AnsiString(PAnsiChar(v.VPointer));
    vtWideString: Result := AnsiString(WideString(v.VWideString));
    vtUnicodeString: Result := AnsiString(UnicodeString(v.VUnicodeString));
  else
    Result := '';
    wasNil := True;
  end;
end;

{ %q: double every single-quote.  Output has no surrounding quotes. }
function escQ(const s: AnsiString): AnsiString;
var i, n: PtrInt; r: AnsiString;
begin
  n := 0;
  for i := 1 to Length(s) do if s[i] = '''' then Inc(n);
  if n = 0 then begin Result := s; Exit; end;
  SetLength(r, Length(s) + n);
  n := 0;
  for i := 1 to Length(s) do begin
    Inc(n); r[n] := s[i];
    if s[i] = '''' then begin Inc(n); r[n] := ''''; end;
  end;
  Result := r;
end;

{ %w: double every double-quote. }
function escW(const s: AnsiString): AnsiString;
var i, n: PtrInt; r: AnsiString;
begin
  n := 0;
  for i := 1 to Length(s) do if s[i] = '"' then Inc(n);
  if n = 0 then begin Result := s; Exit; end;
  SetLength(r, Length(s) + n);
  n := 0;
  for i := 1 to Length(s) do begin
    Inc(n); r[n] := s[i];
    if s[i] = '"' then begin Inc(n); r[n] := '"'; end;
  end;
  Result := r;
end;

{ %T body: pointer to TToken — emit .n bytes starting at .z.  Layout is
  passqlite3codegen.TToken { z: PAnsiChar; n: u32; _pad: u32 }, but we
  treat it via raw Pointer to avoid the cyclic dependency on codegen. }
type
  TTokenBlit = record
    z: PAnsiChar;
    n: u32;
  end;
  PTokenBlit = ^TTokenBlit;

function emitToken(p: Pointer): AnsiString;
var t: PTokenBlit;
begin
  if p = nil then begin Result := ''; Exit; end;
  t := PTokenBlit(p);
  if (t^.z = nil) or (t^.n = 0) then begin Result := ''; Exit; end;
  SetString(Result, t^.z, t^.n);
end;

{ %S body: pointer to TSrcItem (passqlite3codegen).  Layout mirrored
  locally — same rationale as TTokenBlit (no cyclic dep on codegen).
  Field offsets verified against passqlite3codegen.TSrcItem (sizeof=72).

  fg bit assignment (LSB-first within each byte, matches sqliteInt.h
  bit-field declaration order):
    fgBits  bit 2 = isSubquery
    fgBits3 bit 0 = fixedSchema
  See passqlite3codegen.TSrcItemFg for the full enumeration.

  u4 is a union — we read it as a raw pointer; the C-side selector is
  fg.fixedSchema / fg.isSubquery (see comment block at sqliteInt.h:3346).

  TSubquery / TSelect blits read just the fields the conversion needs:
  pSelect, then selFlags / selId / u1.nRow.  Layout from
  passqlite3codegen.TSelect (selFlags at offset 4, selId at offset 16). }
type
  TSrcItemBlit = record
    zName:   PAnsiChar;        { offset  0 }
    zAlias:  PAnsiChar;        { offset  8 }
    pSTab:   Pointer;          { offset 16 }
    fg_jointype: u8;           { offset 24 }
    fg_bits:     u8;           { offset 25 }
    fg_bits2:    u8;           { offset 26 }
    fg_bits3:    u8;           { offset 27 }
    iCursor: i32;              { offset 28 }
    colUsed: u64;              { offset 32 }
    u1_nRow: u32;              { offset 40 — first 4 bytes of the u1 union }
    u1_pad:  u32;              { offset 44 }
    u2:      Pointer;          { offset 48 }
    u3:      Pointer;          { offset 56 }
    u4_ptr:  Pointer;          { offset 64 — zDatabase or pSubq }
  end;
  PSrcItemBlit = ^TSrcItemBlit;

  TSubqueryBlit = record
    pSelect: Pointer;          { offset 0 }
  end;
  PSubqueryBlit = ^TSubqueryBlit;

  TSelectBlit = record
    op:         u8;            { offset  0 }
    _pad0:      u8;
    nSelectRow: i16;
    selFlags:   u32;           { offset  4 }
    iLimit:     i32;
    iOffset:    i32;
    selId:      u32;           { offset 16 }
  end;
  PSelectBlit = ^TSelectBlit;

const
  SF_MultiValueLocal = u32($0000400);
  SF_NestedFromLocal = u32($0000800);
  FG_IS_SUBQUERY     = u8($04);  { fgBits  bit 2 }
  FG_FIXED_SCHEMA    = u8($01);  { fgBits3 bit 0 }

function emitSrcItem(p: Pointer; flagAlt2: Boolean): AnsiString;
var
  it: PSrcItemBlit;
  zStr: AnsiString;
  pSel: PSelectBlit;
  pSubq: PSubqueryBlit;
  isSubquery, fixedSchema: Boolean;
begin
  Result := '';
  if p = nil then Exit;
  it := PSrcItemBlit(p);

  isSubquery  := (it^.fg_bits  and FG_IS_SUBQUERY) <> 0;
  fixedSchema := (it^.fg_bits3 and FG_FIXED_SCHEMA) <> 0;

  { printf.c:980..1005 — the four-way cascade. }
  if (it^.zAlias <> nil) and (not flagAlt2) then begin
    Result := AnsiString(it^.zAlias);
  end else if it^.zName <> nil then begin
    if (not fixedSchema) and (not isSubquery) and (it^.u4_ptr <> nil) then begin
      Result := AnsiString(PAnsiChar(it^.u4_ptr)) + '.';
    end;
    Result := Result + AnsiString(it^.zName);
  end else if it^.zAlias <> nil then begin
    Result := AnsiString(it^.zAlias);
  end else if isSubquery then begin
    { tag-20240424-1: ALWAYS path in the C reference.  pSubq is non-nil
      when isSubquery is set; pSel is non-nil per assert(). }
    pSubq := PSubqueryBlit(it^.u4_ptr);
    if (pSubq = nil) or (pSubq^.pSelect = nil) then Exit;
    pSel := PSelectBlit(pSubq^.pSelect);
    if (pSel^.selFlags and SF_NestedFromLocal) <> 0 then begin
      Result := '(join-' + renderUint(pSel^.selId, 10, False) + ')';
    end else if (pSel^.selFlags and SF_MultiValueLocal) <> 0 then begin
      Result := renderUint(it^.u1_nRow, 10, False) + '-ROW VALUES CLAUSE';
    end else begin
      Result := '(subquery-' + renderUint(pSel^.selId, 10, False) + ')';
    end;
  end;
end;

{ ============================================================
  Floating-point decode — port of util.c:1380 sqlite3FpDecode plus
  its dependencies (Multiply128/Multiply160, powerOfTen, pwr10to2,
  pwr2to10, countLeadingZeros, Fp2Convert10).  Bit-faithful to the
  C reference so .dump output stays byte-identical with the C build.

  Skipped: the iRound==17 round-trip optimization that uses
  sqlite3Fp10Convert2 to find the shortest representation for
  "%!.17g" / altform2.  When iRound==17 we always emit the full
  17-digit decode — slightly more digits in rare edge cases but
  never wrong (decode itself is faithful).  Wire later if a callsite
  needs %!.17g exactness.
  ============================================================ }

const
  SQLITE_U64_DIGITS  = 20;
  POWERSOF10_FIRST   = -348;
  POWERSOF10_LAST    = 347;

type
  TFpDecode = record
    n:         i32;     { Significant digits in the decode }
    iDP:       i32;     { Location of the decimal point }
    z:         PAnsiChar; { Start of significant digits }
    zBuf:      array[0..SQLITE_U64_DIGITS] of AnsiChar;
    sign:      AnsiChar;  { '+' or '-' }
    isSpecial: u8;        { 1 = Inf, 2 = NaN }
  end;

{ 64x64 -> 128 unsigned multiply.  Returns the high 64 bits; writes
  low 64 bits to lo.  Pure-Pascal version (matches the non-intrinsic
  fallback in util.c). }
function multiply128(a, b: u64; out lo: u64): u64;
var
  a0, a1, b0, b1, a0b0, a1b1, a0b1, a1b0, t: u64;
begin
  a0   := u64(u32(a));
  a1   := a shr 32;
  b0   := u64(u32(b));
  b1   := b shr 32;
  a0b0 := a0 * b0;
  a1b1 := a1 * b1;
  a0b1 := a0 * b1;
  a1b0 := a1 * b0;
  t    := (a0b0 shr 32) + u64(u32(a0b1)) + u64(u32(a1b0));
  lo   := (a0b0 and u64($ffffffff)) or (t shl 32);
  Result := a1b1 + (a0b1 shr 32) + (a1b0 shr 32) + (t shr 32);
end;

{ 96x64 -> 160 unsigned multiply (a is 64-bit hi + 32-bit aLo making 96).
  Returns the upper 64 bits of A*B, writes the middle 32 bits to pLo. }
function multiply160(a: u64; aLo: u32; b: u64; out pLo: u32): u64;
var
  x0, x1, x2, y0, y1: u64;
  x2y1, x2y0, x1y1, x1y0, x0y1, x0y0: u64;
  r1, r2, r3, r4: u64;
begin
  x2   := a shr 32;
  x1   := a and u64($ffffffff);
  x0   := aLo;
  y1   := b shr 32;
  y0   := b and u64($ffffffff);
  x2y1 := x2 * y1;
  r4   := x2y1 shr 32;
  x2y0 := x2 * y0;
  x1y1 := x1 * y1;
  r3   := (x2y1 and u64($ffffffff)) + (x2y0 shr 32) + (x1y1 shr 32);
  x1y0 := x1 * y0;
  x0y1 := x0 * y1;
  r2   := (x2y0 and u64($ffffffff)) + (x1y1 and u64($ffffffff)) +
          (x1y0 shr 32) + (x0y1 shr 32);
  x0y0 := x0 * y0;
  r1   := (x1y0 and u64($ffffffff)) + (x0y1 and u64($ffffffff)) +
          (x0y0 shr 32);
  r2   := r2 + (r1 shr 32);
  r3   := r3 + (r2 shr 32);
  pLo  := u32(r2 and u64($ffffffff));
  Result := (r4 shl 32) + r3;
end;

{ floor(log2(pow(10, p))) and floor(log10(pow(2, y))) — the integer
  ratio approximations from util.c:721..722.  Use SarLongint to get
  arithmetic right shift on negative inputs (FPC's `shr` is logical
  on signed types; we want C's signed-arithmetic-shift behaviour
  to match the C reference). }
function pwr10to2(p: i32): i32; inline;
begin
  Result := SarLongint(p * 108853, 15);
end;

function pwr2to10(p: i32): i32; inline;
begin
  Result := SarLongint(p * 78913, 18);
end;

{ 64-bit count-leading-zeros — pure-Pascal fallback. }
function countLeadingZeros(m: u64): i32;
var n: i32;
begin
  n := 0;
  if m <= u64($00000000ffffffff) then begin n := n + 32; m := m shl 32; end;
  if m <= u64($0000ffffffffffff) then begin n := n + 16; m := m shl 16; end;
  if m <= u64($00ffffffffffffff) then begin n := n + 8;  m := m shl 8;  end;
  if m <= u64($0fffffffffffffff) then begin n := n + 4;  m := m shl 4;  end;
  if m <= u64($3fffffffffffffff) then begin n := n + 2;  m := m shl 2;  end;
  if m <= u64($7fffffffffffffff) then begin n := n + 1;            end;
  Result := n;
end;

{ powerOfTen: for any p in [-348..347] return the integer part of
  pow(10,p) * pow(2, 63 - pow10to2(p)).  See util.c:580..701. }
function powerOfTen(p: i32; out lo: u32): u64;
const
  aBase: array[0..26] of u64 = (
    u64($8000000000000000), u64($a000000000000000), u64($c800000000000000),
    u64($fa00000000000000), u64($9c40000000000000), u64($c350000000000000),
    u64($f424000000000000), u64($9896800000000000), u64($bebc200000000000),
    u64($ee6b280000000000), u64($9502f90000000000), u64($ba43b74000000000),
    u64($e8d4a51000000000), u64($9184e72a00000000), u64($b5e620f480000000),
    u64($e35fa931a0000000), u64($8e1bc9bf04000000), u64($b1a2bc2ec5000000),
    u64($de0b6b3a76400000), u64($8ac7230489e80000), u64($ad78ebc5ac620000),
    u64($d8d726b7177a8000), u64($878678326eac9000), u64($a968163f0a57b400),
    u64($d3c21bcecceda100), u64($84595161401484a0), u64($a56fa5b99019a5c8)
  );
  aScale: array[0..25] of u64 = (
    u64($8049a4ac0c5811ae), u64($cf42894a5dce35ea), u64($a76c582338ed2621),
    u64($873e4f75e2224e68), u64($da7f5bf590966848), u64($b080392cc4349dec),
    u64($8e938662882af53e), u64($e65829b3046b0afa), u64($ba121a4650e4ddeb),
    u64($964e858c91ba2655), u64($f2d56790ab41c2a2), u64($c428d05aa4751e4c),
    u64($9e74d1b791e07e48), u64($cccccccccccccccc), u64($cecb8f27f4200f3a),
    u64($a70c3c40a64e6c51), u64($86f0ac99b4e8dafd), u64($da01ee641a708de9),
    u64($b01ae745b101e9e4), u64($8e41ade9fbebc27d), u64($e5d3ef282a242e81),
    u64($b9a74a0637ce2ee1), u64($95f83d0a1fb69cd9), u64($f24a01a73cf2dccf),
    u64($c3b8358109e84f07), u64($9e19db92b4e31ba9)
  );
  aScaleLo: array[0..25] of u32 = (
    $205b896d, $52064cad, $af2af2b8, $5a7744a7, $af39a475, $bd8d794e,
    $547eb47b, $0cb4a5a3, $92f34d62, $3a6a07f9, $fae27299, $aa97e14c,
    $775ea265, $cccccccc, $00000000, $999090b6, $69a028bb, $e80e6f48,
    $5ec05dd0, $14588f14, $8f1668c9, $6d953e2c, $4abdaf10, $bc633b39,
    $0a862f81, $6c07a2c2
  );
var
  g, n: i32;
  s, x: u64;
  lo32: u32;
begin
  if p < 0 then begin
    if p = -1 then begin
      lo := aScaleLo[13];
      Result := aScale[13];
      Exit;
    end;
    g := p div 27;
    n := p mod 27;
    if n <> 0 then begin
      Dec(g);
      n := n + 27;
    end;
  end else if p < 27 then begin
    lo := 0;
    Result := aBase[p];
    Exit;
  end else begin
    g := p div 27;
    n := p mod 27;
  end;
  s := aScale[g + 13];
  if n = 0 then begin
    lo := aScaleLo[g + 13];
    Result := s;
    Exit;
  end;
  x := multiply160(s, aScaleLo[g + 13], aBase[n], lo32);
  if (u64($8000000000000000) and x) = 0 then begin
    x    := (x shl 1) or ((u64(lo32) shr 31) and 1);
    lo32 := (lo32 shl 1) or 1;
  end;
  lo := lo32;
  Result := x;
end;

{ Given m and e (m*pow(2,e)), produce d and p such that
  m*pow(2,e) ≈ d*pow(10,p), with d having n significant digits. }
procedure fp2Convert10(m: u64; e, n: i32; out pD: u64; out pP: i32);
var
  p: i32;
  h, d1: u64;
  d2: u32;
  shft: i32;
begin
  p := n - 1 - pwr2to10(e + 63);
  h := multiply128(m, powerOfTen(p, d2), d1);
  shft := -(e + pwr10to2(p) + 2);
  if n = 18 then begin
    h := h shr shft;
    pD := (h + ((h shl 1) and 2)) shr 1;
  end else begin
    pD := h shr (shft + 1);
  end;
  pP := -p;
end;

{ Convert IEEE754 double r into the FpDecode form.  Mirror of
  util.c:1380 sqlite3FpDecode (modulo iRound==17 round-trip
  optimization noted above). }
procedure fpDecode(out p: TFpDecode; r: Double; iRound, mxRound: i32);
var
  i, n, nn, j: i32;
  v: u64;
  e, exp: i32;
  raw: array[0..7] of Byte;
  z: PAnsiChar;
begin
  p.isSpecial := 0;
  p.n := 0;
  p.iDP := 0;
  p.z := nil;

  if r < 0.0 then begin p.sign := '-'; r := -r; end
  else if r = 0.0 then begin
    p.sign := '+';
    p.n := 1;
    p.iDP := 1;
    p.zBuf[0] := '0';
    p.zBuf[1] := #0;
    p.z := @p.zBuf[0];
    Exit;
  end else
    p.sign := '+';

  Move(r, raw, 8);
  Move(raw, v, 8);

  e := i32((v shr 52) and $7ff);
  if e = $7ff then begin
    if v <> u64($7ff0000000000000) then p.isSpecial := 2
    else                                p.isSpecial := 1;
    p.n := 0;
    p.iDP := 0;
    p.z := @p.zBuf[0];
    Exit;
  end;
  v := v and u64($000fffffffffffff);
  if e = 0 then begin
    nn := countLeadingZeros(v);
    v  := v shl nn;
    e  := -1074 - nn;
  end else begin
    v := (v shl 11) or u64($8000000000000000);
    e := e - 1086;
  end;

  if (iRound <= 0) or (iRound >= 18) then nn := 18 else nn := iRound + 1;
  fp2Convert10(v, e, nn, v, exp);

  { Extract significant digits, right-to-left into zBuf. }
  i := SQLITE_U64_DIGITS;
  while v >= 10 do begin
    Dec(i, 2);
    p.zBuf[i]     := AnsiChar(Byte(((v mod 100) div 10) + Ord('0')));
    p.zBuf[i + 1] := AnsiChar(Byte((v mod 10) + Ord('0')));
    v := v div 100;
  end;
  if v <> 0 then begin
    Dec(i);
    p.zBuf[i] := AnsiChar(Byte(v + Ord('0')));
  end;
  n := SQLITE_U64_DIGITS - i;
  p.iDP := n + exp;
  if iRound <= 0 then begin
    iRound := p.iDP - iRound;
    if (iRound = 0) and (p.zBuf[i] >= '5') then begin
      iRound := 1;
      Dec(i);
      p.zBuf[i] := '0';
      Inc(n);
      Inc(p.iDP);
    end;
  end;
  z := @p.zBuf[i];
  if (iRound > 0) and ((iRound < n) or (n > mxRound)) then begin
    if iRound > mxRound then iRound := mxRound;
    { iRound==17 round-trip optimization deliberately skipped — see
      header comment.  Falls through to the generic rounding rule. }
    n := iRound;
    if z[iRound] >= '5' then begin
      j := iRound - 1;
      while True do begin
        z[j] := AnsiChar(Byte(Ord(z[j]) + 1));
        if z[j] <= '9' then Break;
        z[j] := '0';
        if j = 0 then begin
          Dec(i);
          z := @p.zBuf[i];
          z[0] := '1';
          Inc(n);
          Inc(p.iDP);
          Break;
        end else
          Dec(j);
      end;
    end;
  end;
  { Strip trailing zeros from the digit run. }
  while (n > 0) and (z[n - 1] = '0') do Dec(n);
  { Guarantee at least one digit even if everything rounded to zero. }
  if n = 0 then begin
    z[0] := '0';
    n := 1;
  end;
  p.n := n;
  p.z := z;
end;

{ Render a TFpDecode + flags into an AnsiString without sign prefix.
  Caller stitches the prefix on via emitField.  charSet is 'e' or 'E'
  for the exponent letter when xtype = etEXP.  isFloat = True for %f
  (etFLOAT), False = %e/%E (etEXP).  isGeneric = True = %g/%G. }
procedure renderFloat(var dec: TFpDecode;
  isFloat, isGeneric: Boolean; eChar: AnsiChar;
  precision: i32; flagAlt, flagAlt2: Boolean;
  out body: AnsiString; out usePrefix: Boolean);
var
  flag_rtz, flag_dp: Boolean;
  exp, e2, j, nn: i32;
  buf: AnsiString;
  procedure Put(c: AnsiChar); inline;
  begin buf := buf + c; end;
  procedure PutN(c: AnsiChar; k: i32); inline;
  var i: i32;
  begin for i := 1 to k do buf := buf + c; end;
  procedure PutS(z: PAnsiChar; m: i32); inline;
  var i: i32;
  begin for i := 0 to m - 1 do buf := buf + z[i]; end;
  procedure ResolveExpRender;
  var ex: i32;
  begin
    ex := exp;
    Put(eChar);
    if ex < 0 then begin Put('-'); ex := -ex; end
    else            Put('+');
    if ex >= 100 then begin Put(AnsiChar(Byte((ex div 100) + Ord('0')))); ex := ex mod 100; end;
    Put(AnsiChar(Byte((ex div 10) + Ord('0'))));
    Put(AnsiChar(Byte((ex mod 10) + Ord('0'))));
  end;
begin
  buf := '';
  usePrefix := True;
  exp := dec.iDP - 1;

  if isGeneric then begin
    if precision <= 0 then precision := 1;
    precision := precision - 1;
    flag_rtz := not flagAlt;
    if (exp < -4) or (exp > precision) then begin
      isGeneric := False; isFloat := False;
      { etEXP }
    end else begin
      precision := precision - exp;
      isGeneric := False; isFloat := True;
    end;
  end else
    flag_rtz := flagAlt2;

  if isFloat then e2 := dec.iDP - 1
  else            e2 := 0;

  flag_dp := (precision > 0) or flagAlt or flagAlt2;

  { Digits prior to the decimal point. }
  j := 0;
  if e2 < 0 then
    Put('0')
  else begin
    j := e2 + 1;
    if j > dec.n then j := dec.n;
    PutS(dec.z, j);
    e2 := e2 - j;
    if e2 >= 0 then begin
      PutN('0', e2 + 1);
      e2 := -1;
    end;
  end;

  if flag_dp then Put('.');

  if (e2 < -1) and (precision > 0) then begin
    nn := -1 - e2;
    if nn > precision then nn := precision;
    PutN('0', nn);
    precision := precision - nn;
  end;

  if precision > 0 then begin
    nn := dec.n - j;
    if nn > precision then nn := precision;
    if nn > 0 then begin
      PutS(@dec.z[j], nn);
      precision := precision - nn;
    end;
    if (precision > 0) and (not flag_rtz) then PutN('0', precision);
  end;

  { Trim trailing zeros (and the decimal point) when flag_rtz. }
  if flag_rtz and flag_dp then begin
    while (Length(buf) > 0) and (buf[Length(buf)] = '0') do
      SetLength(buf, Length(buf) - 1);
    if (Length(buf) > 0) and (buf[Length(buf)] = '.') then begin
      if flagAlt2 then buf := buf + '0'
      else SetLength(buf, Length(buf) - 1);
    end;
  end;

  { etEXP suffix. }
  if not isFloat then ResolveExpRender;

  body := buf;
end;

{ ============================================================
  Core engine — sqlite3FormatStr.
  ============================================================ }

function sqlite3FormatStr(fmt: PAnsiChar;
  const args: array of const): AnsiString;
var
  a:           TAccum;
  p:           PAnsiChar;
  ch:          AnsiChar;
  argIdx:      i32;
  width, prec: i32;
  leftAlign:   Boolean;
  zeroPad:     Boolean;
  plusFlag:    Boolean;
  spaceFlag:   Boolean;
  altFlag:     Boolean;
  altForm2:    Boolean;
  longCount:   i32;
  iv:          i64;
  uv:          u64;
  dv:          Double;
  fpDec:       TFpDecode;
  fEChar:      AnsiChar;
  fIsFloat,
  fIsGeneric:  Boolean;
  fIRound,
  fMxRound:    i32;
  fNeedSign:   Boolean;
  fSpecial:    Boolean;
  isNeg:       Boolean;
  body:        AnsiString;
  prefix:      AnsiString;
  s:           AnsiString;
  wasNil:      Boolean;
  argMissing:  Boolean;

  procedure NextArgI64(out v: i64);
  begin
    if (argIdx > High(args)) then begin v := 0; argMissing := True; Exit; end;
    v := argAsI64(args[argIdx]);
    Inc(argIdx);
  end;

  procedure NextArgStr(out v: AnsiString; out nilArg: Boolean);
  begin
    nilArg := False;
    if (argIdx > High(args)) then begin v := ''; argMissing := True; Exit; end;
    v := argAsStr(args[argIdx], nilArg);
    Inc(argIdx);
  end;

  procedure NextArgPtr(out v: Pointer);
  begin
    if (argIdx > High(args)) then begin v := nil; argMissing := True; Exit; end;
    v := argAsPointer(args[argIdx]);
    Inc(argIdx);
  end;

  procedure NextArgDouble(out v: Double);
  var vr: TVarRec;
  begin
    if (argIdx > High(args)) then begin v := 0.0; argMissing := True; Exit; end;
    vr := args[argIdx];
    Inc(argIdx);
    case vr.VType of
      vtExtended:    v := vr.VExtended^;
      vtCurrency:    v := vr.VCurrency^;
      vtInteger:     v := vr.VInteger;
      vtInt64:       v := vr.VInt64^;
      vtQWord:       v := vr.VQWord^;
    else
      v := 0.0;
    end;
  end;

begin
  accumInit(a);
  if fmt = nil then begin Result := ''; Exit; end;
  p := fmt;
  argIdx := 0;
  argMissing := False;

  while p^ <> #0 do begin
    ch := p^;
    if ch <> '%' then begin
      accumPutChar(a, ch);
      Inc(p);
      Continue;
    end;
    Inc(p); { past '%' }

    leftAlign := False; zeroPad := False; plusFlag := False;
    spaceFlag := False; altFlag := False; altForm2 := False;
    while True do begin
      case p^ of
        '-': leftAlign := True;
        '0': zeroPad   := True;
        '+': plusFlag  := True;
        ' ': spaceFlag := True;
        '#': altFlag   := True;
        '!': altForm2  := True;
      else
        Break;
      end;
      Inc(p);
    end;

    { width }
    width := 0;
    if p^ = '*' then begin
      NextArgI64(iv);
      if iv < 0 then begin leftAlign := True; iv := -iv; end;
      width := i32(iv);
      Inc(p);
    end else begin
      while (p^ >= '0') and (p^ <= '9') do begin
        width := width * 10 + (Ord(p^) - Ord('0'));
        Inc(p);
      end;
    end;

    { precision }
    prec := -1;
    if p^ = '.' then begin
      Inc(p);
      prec := 0;
      if p^ = '*' then begin
        NextArgI64(iv);
        prec := i32(iv);
        Inc(p);
      end else begin
        while (p^ >= '0') and (p^ <= '9') do begin
          prec := prec * 10 + (Ord(p^) - Ord('0'));
          Inc(p);
        end;
      end;
    end;

    { length modifiers }
    longCount := 0;
    while (p^ = 'l') do begin
      Inc(longCount); Inc(p);
    end;
    if (p^ = 'h') or (p^ = 'j') or (p^ = 't') then Inc(p);
    if (p^ = 'L') then Inc(p);

    case p^ of
      '%':
        begin
          accumPutChar(a, '%');
          Inc(p);
        end;
      'd', 'i':
        begin
          NextArgI64(iv);
          isNeg := iv < 0;
          if isNeg then uv := u64(-iv) else uv := u64(iv);
          body := renderUint(uv, 10, False);
          if isNeg then prefix := '-'
          else if plusFlag then prefix := '+'
          else if spaceFlag then prefix := ' '
          else prefix := '';
          emitField(a, body, prefix, width, prec, leftAlign, zeroPad, False);
          Inc(p);
        end;
      'u':
        begin
          NextArgI64(iv);
          uv := u64(iv);
          body := renderUint(uv, 10, False);
          emitField(a, body, '', width, prec, leftAlign, zeroPad, False);
          Inc(p);
        end;
      'x':
        begin
          NextArgI64(iv);
          uv := u64(iv);
          body := renderUint(uv, 16, False);
          if altFlag and (uv <> 0) then prefix := '0x' else prefix := '';
          emitField(a, body, prefix, width, prec, leftAlign, zeroPad, False);
          Inc(p);
        end;
      'X':
        begin
          NextArgI64(iv);
          uv := u64(iv);
          body := renderUint(uv, 16, True);
          if altFlag and (uv <> 0) then prefix := '0X' else prefix := '';
          emitField(a, body, prefix, width, prec, leftAlign, zeroPad, False);
          Inc(p);
        end;
      'o':
        begin
          NextArgI64(iv);
          uv := u64(iv);
          body := renderUint(uv, 8, False);
          if altFlag and (Length(body) > 0) and (body[1] <> '0') then
            prefix := '0' else prefix := '';
          emitField(a, body, prefix, width, prec, leftAlign, zeroPad, False);
          Inc(p);
        end;
      'c':
        begin
          NextArgI64(iv);
          body := AnsiChar(Byte(iv));
          emitField(a, body, '', width, -1, leftAlign, False, True);
          Inc(p);
        end;
      'p':
        begin
          NextArgPtr(Pointer(uv));
          { uv now holds pointer bits }
          body := renderUint(u64(PtrUInt(Pointer(uv))), 16, False);
          emitField(a, body, '0x', width, prec, leftAlign, zeroPad, False);
          Inc(p);
        end;
      's', 'z':
        begin
          NextArgStr(s, wasNil);
          if wasNil then s := '';
          emitField(a, s, '', width, prec, leftAlign, False, True);
          Inc(p);
        end;
      'q':
        begin
          NextArgStr(s, wasNil);
          if wasNil then s := '';
          body := escQ(s);
          emitField(a, body, '', width, prec, leftAlign, False, True);
          Inc(p);
        end;
      'Q':
        begin
          NextArgStr(s, wasNil);
          if wasNil then begin
            { %Q with nil → "NULL" without quotes }
            emitField(a, 'NULL', '', width, prec, leftAlign, False, True);
          end else begin
            body := '''' + escQ(s) + '''';
            emitField(a, body, '', width, prec, leftAlign, False, True);
          end;
          Inc(p);
        end;
      'w':
        begin
          NextArgStr(s, wasNil);
          if wasNil then s := '';
          body := escW(s);
          emitField(a, body, '', width, prec, leftAlign, False, True);
          Inc(p);
        end;
      'T':
        begin
          NextArgPtr(Pointer(uv));
          body := emitToken(Pointer(uv));
          emitField(a, body, '', width, prec, leftAlign, False, True);
          Inc(p);
        end;
      'S':
        begin
          { etSRCITEM — printf.c:975..1008.  Pointer to TSrcItem; emits
            zAlias, zName (with optional database prefix), or a synthetic
            subquery descriptor.  The `!` flag (altForm2) suppresses the
            zAlias-takes-priority rule so callers can force the underlying
            zName to be shown even when an alias is set. }
          NextArgPtr(Pointer(uv));
          body := emitSrcItem(Pointer(uv), altForm2);
          emitField(a, body, '', width, prec, leftAlign, False, True);
          Inc(p);
        end;
      'r':
        begin
          { etORDINAL — printf.c:481..488.  Render the integer in decimal,
            tack on the two-letter English ordinal suffix.  Suffix selection:
              x := abs(value) mod 10
              if x>=4 OR (abs(value)/10) mod 10 == 1 then x := 0  ('th')
              else x in {1,2,3} → 'st','nd','rd' }
          NextArgI64(iv);
          isNeg := iv < 0;
          if isNeg then uv := u64(-iv) else uv := u64(iv);
          body := renderUint(uv, 10, False);
          if isNeg then prefix := '-'
          else if plusFlag then prefix := '+'
          else if spaceFlag then prefix := ' '
          else prefix := '';
          { Append the ordinal suffix to the digit body so width applies
            to the combined text.  The C reference prepends the suffix
            into the same reverse buffer used for digits, so the output
            ordering is identical. }
          if ((uv mod 10) >= 4) or (((uv div 10) mod 10) = 1) then
            body := body + 'th'
          else case uv mod 10 of
            1: body := body + 'st';
            2: body := body + 'nd';
            3: body := body + 'rd';
          else
            body := body + 'th';
          end;
          { Treat as string for width/pad purposes — the suffix is literal
            text, not a digit, so numeric zero-pad would produce nonsense
            like "0021st".  Spaces-only padding matches the typical use
            sites (diagnostic messages like "argument %r ..."). }
          emitField(a, body, prefix, width, -1, leftAlign, False, True);
          Inc(p);
        end;
      'f', 'e', 'E', 'g', 'G':
        begin
          { etFLOAT / etEXP / etGENERIC — printf.c:528..738. }
          NextArgDouble(dv);
          fIsFloat   := (p^ = 'f');
          fIsGeneric := (p^ = 'g') or (p^ = 'G');
          if (p^ = 'E') or (p^ = 'G') then fEChar := 'E' else fEChar := 'e';

          if prec < 0 then prec := 6;
          if fIsFloat then        fIRound := -prec
          else if fIsGeneric then begin
            if prec = 0 then prec := 1;
            fIRound := prec;
          end else
            fIRound := prec + 1;
          if altForm2 then fMxRound := 20 else fMxRound := 16;

          fpDecode(fpDec, dv, fIRound, fMxRound);
          fSpecial := False;
          prefix := '';
          if fpDec.isSpecial = 2 then begin
            { NaN — zero-pad turns it into "null" per the C reference. }
            if zeroPad then body := 'null' else body := 'NaN';
            fSpecial := True;
          end else if fpDec.isSpecial = 1 then begin
            if zeroPad then begin
              { With zeropad, fall through to the regular renderer using
                a synthetic "9 * 10^1000" so the output is dominated by
                zero padding to the requested width — matches printf.c
                line 561..564. }
              fpDec.zBuf[0] := '9';
              fpDec.iDP := 1000;
              fpDec.n := 1;
              fpDec.z := @fpDec.zBuf[0];
            end else begin
              if fpDec.sign = '-' then begin
                body := '-Inf';
              end else if plusFlag then begin
                body := '+Inf';
              end else if spaceFlag then begin
                body := ' Inf';
              end else
                body := 'Inf';
              fSpecial := True;
            end;
          end;

          if not fSpecial then begin
            { Sign handling.  The "#" flag suppresses '-' on a value
              that displays as zero under %f (printf.c:579..597). }
            if fpDec.sign = '-' then begin
              if altFlag and (not plusFlag) and fIsFloat
                 and (not fIsGeneric) and (fpDec.iDP <= fIRound) then
                prefix := ''
              else
                prefix := '-';
            end else if plusFlag then prefix := '+'
            else if spaceFlag then prefix := ' '
            else prefix := '';

            renderFloat(fpDec, fIsFloat, fIsGeneric, fEChar, prec,
                        altFlag, altForm2, body, fNeedSign);
          end;

          { Width / pad.  emitField with isString=False handles zero-pad
            (after prefix) and space-pad correctly. }
          emitField(a, body, prefix, width, -1, leftAlign, zeroPad, False);
          Inc(p);
        end;
    else
      { Unknown conversion — emit verbatim, keep going. }
      accumPutChar(a, '%');
      if p^ <> #0 then begin accumPutChar(a, p^); Inc(p); end;
    end;
  end;

  Result := accumFinish(a);
end;

{ ============================================================
  Allocation wrappers
  ============================================================ }

function strDupLibc(const s: AnsiString): PAnsiChar;
var n: PtrInt; r: PAnsiChar;
begin
  n := Length(s);
  r := PAnsiChar(sqlite3Malloc(n + 1));
  if r = nil then begin Result := nil; Exit; end;
  if n > 0 then Move(PAnsiChar(s)^, r^, n);
  r[n] := #0;
  Result := r;
end;

function strDupDb(db: Psqlite3db; const s: AnsiString): PAnsiChar;
var n: PtrInt; r: PAnsiChar;
begin
  if db = nil then begin Result := strDupLibc(s); Exit; end;
  n := Length(s);
  r := PAnsiChar(sqlite3DbMalloc(db, n + 1));
  if r = nil then begin Result := nil; Exit; end;
  if n > 0 then Move(PAnsiChar(s)^, r^, n);
  r[n] := #0;
  Result := r;
end;

{ ============================================================
  Public entry points
  ============================================================ }

function sqlite3PfMprintf(fmt: PAnsiChar;
  const args: array of const): PAnsiChar;
begin
  Result := strDupLibc(sqlite3FormatStr(fmt, args));
end;

function sqlite3PfSnprintf(n: i32; zBuf: PAnsiChar; fmt: PAnsiChar;
  const args: array of const): PAnsiChar;
var s: AnsiString; copy: i32;
begin
  Result := zBuf;
  if (zBuf = nil) or (n <= 0) then Exit;
  s := sqlite3FormatStr(fmt, args);
  copy := Length(s);
  if copy > n - 1 then copy := n - 1;
  if copy > 0 then Move(PAnsiChar(s)^, zBuf^, copy);
  zBuf[copy] := #0;
end;

function sqlite3MPrintf(db: Psqlite3db; fmt: PAnsiChar;
  const args: array of const): PAnsiChar;
begin
  Result := strDupDb(db, sqlite3FormatStr(fmt, args));
end;

function sqlite3VMPrintf(db: Psqlite3db; fmt: PAnsiChar;
  const args: array of const): PAnsiChar;
begin
  Result := strDupDb(db, sqlite3FormatStr(fmt, args));
end;

function sqlite3MAppendf(db: Psqlite3db; zOld: PAnsiChar; fmt: PAnsiChar;
  const args: array of const): PAnsiChar;
var s, base: AnsiString;
begin
  if zOld <> nil then base := AnsiString(zOld) else base := '';
  s := base + sqlite3FormatStr(fmt, args);
  if zOld <> nil then sqlite3DbFree(db, zOld);
  Result := strDupDb(db, s);
end;

end.
