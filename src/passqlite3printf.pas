{$I passqlite3.inc}
unit passqlite3printf;

{
  Phase 6.bis.4a — printf core (port of sqlite3/src/printf.c, slimmed slice).

  Lands the long-awaited printf machinery referenced as a recurring blocker
  by Phase 6.bis.1c..f and 6.bis.2a..d.  Scope of this slice:

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

  Width / precision / left-align / zero-pad / +/space sign flags supported
  for the integer and string conversions.  Floating-point (%f, %e, %g) and
  the unusual SQLite extras (%S = SrcItem, %r = ordinal) are intentionally
  deferred — they are unused by current call sites.  When a future slice
  needs them, this unit adds them; signatures stay stable.

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
  longCount:   i32;
  iv:          i64;
  uv:          u64;
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
    spaceFlag := False; altFlag := False;
    while True do begin
      case p^ of
        '-': leftAlign := True;
        '0': zeroPad   := True;
        '+': plusFlag  := True;
        ' ': spaceFlag := True;
        '#': altFlag   := True;
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
