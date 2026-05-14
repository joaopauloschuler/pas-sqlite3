{
  SPDX-License-Identifier: blessing

  Faithful port of ../sqlite3/src/test_md5.c (444 lines in C).

  Implements the MD5 message-digest algorithm (Colin Plumb's public-domain
  implementation) and exposes it to the Tcl test harness:

    * `md5 TEXT`           — MD5 of TEXT, 32-hex-digit base-16.
    * `md5-10x8 TEXT`      — MD5 of TEXT, eight 5-digit base-10 groups.
    * `md5file FILENAME`   — MD5 of a file, base-16.
    * `md5file-10x8 FILE`  — MD5 of a file, base-10x8.
    * SQL aggregate `md5sum(...)` registered per-connection by Md5_Register.

  The four Tcl commands share two C functions (md5_cmd / md5file_cmd); the
  selected base-16 vs base-10x8 converter is passed as the command's
  clientData.  This port keeps the same shape: a TConverter function
  pointer is registered as clientData.

  Public entries:
    Md5_Init(interp)        — register the four Tcl commands.
    Md5_Register(db, ...)   — register the md5sum() SQL aggregate.
}
{$I passqlite3.inc}
unit TestModuleMd5;

interface

uses
  ctypes,
  SysUtils,
  PasTclBridge,
  passqlite3types,
  passqlite3util,
  passqlite3vdbe,
  passqlite3main;

function Md5_Init(interp: PTclInterp): cint; cdecl;
function Md5_Register(db: PTsqlite3; pzErrMsg: PPAnsiChar;
  pThunk: Pointer): cint; cdecl;

implementation

type
  TUint32Buf4  = array[0..3]  of u32;
  TUint32Buf16 = array[0..15] of u32;

  { test_md5.c:50..56 — struct MD5Context. }
  PMD5Context = ^TMD5Context;
  TMD5Context = record
    isInit : cint;
    buf    : TUint32Buf4;
    bits   : array[0..1] of u32;
    inbuf  : array[0..63] of Byte;
  end;

  { Converter signature: void (*)(unsigned char*, char*). }
  TConverter = procedure(digest: PByte; zBuf: PAnsiChar);

{ test_md5.c:61..69 — byteReverse.  Harmless on little-endian; we keep
  the faithful body anyway so big-endian builds are correct. }
procedure byteReverse(buf: PByte; longs: cuint);
var
  t: u32;
  p: PByte;
begin
  p := buf;
  repeat
    t := (u32((u32(p[3]) shl 8) or p[2]) shl 16) or
         (u32(p[1]) shl 8) or p[0];
    Pu32(p)^ := t;
    Inc(p, 4);
    Dec(longs);
  until longs = 0;
end;

{ The four core functions — test_md5.c:73..76. }
function F1(x, y, z: u32): u32; inline;
begin
  Result := z xor (x and (y xor z));
end;

function F2(x, y, z: u32): u32; inline;
begin
  Result := F1(z, x, y);
end;

function F3(x, y, z: u32): u32; inline;
begin
  Result := x xor y xor z;
end;

function F4(x, y, z: u32): u32; inline;
begin
  Result := y xor (x or (not z));
end;

{ test_md5.c:79..80 — MD5STEP.  w += f(x,y,z)+data; w = rotl(w,s); w += x. }
procedure MD5STEP1(var w: u32; x, y, z, data: u32; s: cint); inline;
begin
  w := w + F1(x, y, z) + data;
  w := (w shl s) or (w shr (32 - s));
  w := w + x;
end;

procedure MD5STEP2(var w: u32; x, y, z, data: u32; s: cint); inline;
begin
  w := w + F2(x, y, z) + data;
  w := (w shl s) or (w shr (32 - s));
  w := w + x;
end;

procedure MD5STEP3(var w: u32; x, y, z, data: u32; s: cint); inline;
begin
  w := w + F3(x, y, z) + data;
  w := (w shl s) or (w shr (32 - s));
  w := w + x;
end;

procedure MD5STEP4(var w: u32; x, y, z, data: u32; s: cint); inline;
begin
  w := w + F4(x, y, z) + data;
  w := (w shl s) or (w shr (32 - s));
  w := w + x;
end;

{ test_md5.c:87..167 — MD5Transform. }
procedure MD5Transform(var buf: TUint32Buf4; const inw: TUint32Buf16);
var
  a, b, c, d: u32;
begin
  a := buf[0];
  b := buf[1];
  c := buf[2];
  d := buf[3];

  MD5STEP1(a, b, c, d, inw[ 0] + u32($d76aa478),  7);
  MD5STEP1(d, a, b, c, inw[ 1] + u32($e8c7b756), 12);
  MD5STEP1(c, d, a, b, inw[ 2] + u32($242070db), 17);
  MD5STEP1(b, c, d, a, inw[ 3] + u32($c1bdceee), 22);
  MD5STEP1(a, b, c, d, inw[ 4] + u32($f57c0faf),  7);
  MD5STEP1(d, a, b, c, inw[ 5] + u32($4787c62a), 12);
  MD5STEP1(c, d, a, b, inw[ 6] + u32($a8304613), 17);
  MD5STEP1(b, c, d, a, inw[ 7] + u32($fd469501), 22);
  MD5STEP1(a, b, c, d, inw[ 8] + u32($698098d8),  7);
  MD5STEP1(d, a, b, c, inw[ 9] + u32($8b44f7af), 12);
  MD5STEP1(c, d, a, b, inw[10] + u32($ffff5bb1), 17);
  MD5STEP1(b, c, d, a, inw[11] + u32($895cd7be), 22);
  MD5STEP1(a, b, c, d, inw[12] + u32($6b901122),  7);
  MD5STEP1(d, a, b, c, inw[13] + u32($fd987193), 12);
  MD5STEP1(c, d, a, b, inw[14] + u32($a679438e), 17);
  MD5STEP1(b, c, d, a, inw[15] + u32($49b40821), 22);

  MD5STEP2(a, b, c, d, inw[ 1] + u32($f61e2562),  5);
  MD5STEP2(d, a, b, c, inw[ 6] + u32($c040b340),  9);
  MD5STEP2(c, d, a, b, inw[11] + u32($265e5a51), 14);
  MD5STEP2(b, c, d, a, inw[ 0] + u32($e9b6c7aa), 20);
  MD5STEP2(a, b, c, d, inw[ 5] + u32($d62f105d),  5);
  MD5STEP2(d, a, b, c, inw[10] + u32($02441453),  9);
  MD5STEP2(c, d, a, b, inw[15] + u32($d8a1e681), 14);
  MD5STEP2(b, c, d, a, inw[ 4] + u32($e7d3fbc8), 20);
  MD5STEP2(a, b, c, d, inw[ 9] + u32($21e1cde6),  5);
  MD5STEP2(d, a, b, c, inw[14] + u32($c33707d6),  9);
  MD5STEP2(c, d, a, b, inw[ 3] + u32($f4d50d87), 14);
  MD5STEP2(b, c, d, a, inw[ 8] + u32($455a14ed), 20);
  MD5STEP2(a, b, c, d, inw[13] + u32($a9e3e905),  5);
  MD5STEP2(d, a, b, c, inw[ 2] + u32($fcefa3f8),  9);
  MD5STEP2(c, d, a, b, inw[ 7] + u32($676f02d9), 14);
  MD5STEP2(b, c, d, a, inw[12] + u32($8d2a4c8a), 20);

  MD5STEP3(a, b, c, d, inw[ 5] + u32($fffa3942),  4);
  MD5STEP3(d, a, b, c, inw[ 8] + u32($8771f681), 11);
  MD5STEP3(c, d, a, b, inw[11] + u32($6d9d6122), 16);
  MD5STEP3(b, c, d, a, inw[14] + u32($fde5380c), 23);
  MD5STEP3(a, b, c, d, inw[ 1] + u32($a4beea44),  4);
  MD5STEP3(d, a, b, c, inw[ 4] + u32($4bdecfa9), 11);
  MD5STEP3(c, d, a, b, inw[ 7] + u32($f6bb4b60), 16);
  MD5STEP3(b, c, d, a, inw[10] + u32($bebfbc70), 23);
  MD5STEP3(a, b, c, d, inw[13] + u32($289b7ec6),  4);
  MD5STEP3(d, a, b, c, inw[ 0] + u32($eaa127fa), 11);
  MD5STEP3(c, d, a, b, inw[ 3] + u32($d4ef3085), 16);
  MD5STEP3(b, c, d, a, inw[ 6] + u32($04881d05), 23);
  MD5STEP3(a, b, c, d, inw[ 9] + u32($d9d4d039),  4);
  MD5STEP3(d, a, b, c, inw[12] + u32($e6db99e5), 11);
  MD5STEP3(c, d, a, b, inw[15] + u32($1fa27cf8), 16);
  MD5STEP3(b, c, d, a, inw[ 2] + u32($c4ac5665), 23);

  MD5STEP4(a, b, c, d, inw[ 0] + u32($f4292244),  6);
  MD5STEP4(d, a, b, c, inw[ 7] + u32($432aff97), 10);
  MD5STEP4(c, d, a, b, inw[14] + u32($ab9423a7), 15);
  MD5STEP4(b, c, d, a, inw[ 5] + u32($fc93a039), 21);
  MD5STEP4(a, b, c, d, inw[12] + u32($655b59c3),  6);
  MD5STEP4(d, a, b, c, inw[ 3] + u32($8f0ccc92), 10);
  MD5STEP4(c, d, a, b, inw[10] + u32($ffeff47d), 15);
  MD5STEP4(b, c, d, a, inw[ 1] + u32($85845dd1), 21);
  MD5STEP4(a, b, c, d, inw[ 8] + u32($6fa87e4f),  6);
  MD5STEP4(d, a, b, c, inw[15] + u32($fe2ce6e0), 10);
  MD5STEP4(c, d, a, b, inw[ 6] + u32($a3014314), 15);
  MD5STEP4(b, c, d, a, inw[13] + u32($4e0811a1), 21);
  MD5STEP4(a, b, c, d, inw[ 4] + u32($f7537e82),  6);
  MD5STEP4(d, a, b, c, inw[11] + u32($bd3af235), 10);
  MD5STEP4(c, d, a, b, inw[ 2] + u32($2ad7d2bb), 15);
  MD5STEP4(b, c, d, a, inw[ 9] + u32($eb86d391), 21);

  buf[0] := buf[0] + a;
  buf[1] := buf[1] + b;
  buf[2] := buf[2] + c;
  buf[3] := buf[3] + d;
end;

{ test_md5.c:173..181 — MD5Init. }
procedure MD5Init(ctx: PMD5Context);
begin
  ctx^.isInit  := 1;
  ctx^.buf[0]  := u32($67452301);
  ctx^.buf[1]  := u32($efcdab89);
  ctx^.buf[2]  := u32($98badcfe);
  ctx^.buf[3]  := u32($10325476);
  ctx^.bits[0] := 0;
  ctx^.bits[1] := 0;
end;

{ test_md5.c:187..230 — MD5Update. }
procedure MD5Update(ctx: PMD5Context; buf: PByte; len: cuint);
var
  t: u32;
  p: PByte;
begin
  { Update bitcount }
  t := ctx^.bits[0];
  ctx^.bits[0] := t + (u32(len) shl 3);
  if ctx^.bits[0] < t then
    Inc(ctx^.bits[1]);                { Carry from low to high }
  ctx^.bits[1] := ctx^.bits[1] + (len shr 29);

  t := (t shr 3) and $3f;             { Bytes already in shsInfo->data }

  { Handle any leading odd-sized chunks }
  if t <> 0 then
  begin
    p := @ctx^.inbuf[t];
    t := 64 - t;
    if len < t then
    begin
      Move(buf^, p^, len);
      Exit;
    end;
    Move(buf^, p^, t);
    byteReverse(@ctx^.inbuf[0], 16);
    MD5Transform(ctx^.buf, TUint32Buf16(Pointer(@ctx^.inbuf[0])^));
    Inc(buf, t);
    Dec(len, t);
  end;

  { Process data in 64-byte chunks }
  while len >= 64 do
  begin
    Move(buf^, ctx^.inbuf[0], 64);
    byteReverse(@ctx^.inbuf[0], 16);
    MD5Transform(ctx^.buf, TUint32Buf16(Pointer(@ctx^.inbuf[0])^));
    Inc(buf, 64);
    Dec(len, 64);
  end;

  { Handle any remaining bytes of data. }
  Move(buf^, ctx^.inbuf[0], len);
end;

{ test_md5.c:236..272 — MD5Final. }
procedure MD5Final(digest: PByte; ctx: PMD5Context);
var
  count: cuint;
  p:     PByte;
begin
  { Compute number of bytes mod 64 }
  count := (ctx^.bits[0] shr 3) and $3F;

  { Set the first char of padding to 0x80. }
  p := @ctx^.inbuf[count];
  p^ := $80;
  Inc(p);

  { Bytes of padding needed to make 64 bytes }
  count := 64 - 1 - count;

  { Pad out to 56 mod 64 }
  if count < 8 then
  begin
    { Two lots of padding:  Pad the first block to 64 bytes }
    FillChar(p^, count, 0);
    byteReverse(@ctx^.inbuf[0], 16);
    MD5Transform(ctx^.buf, TUint32Buf16(Pointer(@ctx^.inbuf[0])^));
    { Now fill the next block with 56 bytes }
    FillChar(ctx^.inbuf[0], 56, 0);
  end
  else
    { Pad block to 56 bytes }
    FillChar(p^, count - 8, 0);

  byteReverse(@ctx^.inbuf[0], 14);

  { Append length in bits and transform }
  Move(ctx^.bits[0], ctx^.inbuf[14 * 4], 8);

  MD5Transform(ctx^.buf, TUint32Buf16(Pointer(@ctx^.inbuf[0])^));
  byteReverse(@ctx^.buf[0], 4);
  Move(ctx^.buf[0], digest^, 16);
end;

{ test_md5.c:277..287 — MD5DigestToBase16. }
procedure MD5DigestToBase16(digest: PByte; zBuf: PAnsiChar);
const
  zEncode: array[0..15] of AnsiChar = '0123456789abcdef';
var
  i, j, a: cint;
begin
  j := 0;
  for i := 0 to 15 do
  begin
    a := digest[i];
    zBuf[j] := zEncode[(a shr 4) and $f];  Inc(j);
    zBuf[j] := zEncode[a and $f];          Inc(j);
  end;
  zBuf[j] := #0;
end;

{ test_md5.c:295..305 — MD5DigestToBase10x8. }
procedure MD5DigestToBase10x8(digest: PByte; zDigest: PAnsiChar);
var
  i, j: cint;
  x:    cuint;
  s:    string;
begin
  i := 0;
  j := 0;
  while i < 16 do
  begin
    x := cuint(digest[i]) * 256 + digest[i + 1];
    if i > 0 then
    begin
      zDigest[j] := '-';
      Inc(j);
    end;
    { %05u — five-digit zero-padded unsigned. }
    Str(x, s);
    while Length(s) < 5 do s := '0' + s;
    Move(s[1], zDigest[j], 5);
    Inc(j, 5);
    Inc(i, 2);
  end;
  zDigest[j] := #0;
end;

{ test_md5.c:311..334 — md5_cmd.  Hash argv[1], result via cd converter. }
function md5_cmd(cd: TClientData; interp: PTclInterp;
  argc: cint; argv: PPAnsiCharArr): cint; cdecl;
var
  ctx:       TMD5Context;
  digest:    array[0..15] of Byte;
  zBuf:      array[0..49] of AnsiChar;
  converter: TConverter;
  pArgv:     PPAnsiChar;
begin
  pArgv := PPAnsiChar(argv);
  if argc <> 2 then
  begin
    Tcl_AppendResult(interp, PChar('wrong # args: should be "'),
      pArgv[0], PChar(' TEXT"'), Pointer(nil));
    Result := TCL_ERROR;
    Exit;
  end;
  MD5Init(@ctx);
  MD5Update(@ctx, PByte(pArgv[1]), cuint(StrLen(pArgv[1])));
  MD5Final(@digest[0], @ctx);
  converter := TConverter(cd);
  converter(@digest[0], @zBuf[0]);
  Tcl_AppendResult(interp, PChar(@zBuf[0]), Pointer(nil));
  Result := TCL_OK;
end;

{ test_md5.c:340..387 — md5file_cmd.  Hash a file (optional OFFSET AMT). }
function md5file_cmd(cd: TClientData; interp: PTclInterp;
  argc: cint; argv: PPAnsiCharArr): cint; cdecl;
var
  fin:       File;
  ofst, amt: cint;
  ctx:       TMD5Context;
  converter: TConverter;
  digest:    array[0..15] of Byte;
  zBuf:      array[0..10239] of AnsiChar;
  pArgv:     PPAnsiChar;
  n, want:   cint;
  oldMode:   Byte;
begin
  pArgv := PPAnsiChar(argv);
  if (argc <> 2) and (argc <> 4) then
  begin
    Tcl_AppendResult(interp, PChar('wrong # args: should be "'),
      pArgv[0], PChar(' FILENAME [OFFSET AMT]"'), Pointer(nil));
    Result := TCL_ERROR;
    Exit;
  end;
  if argc = 4 then
  begin
    ofst := StrToIntDef(string(pArgv[2]), 0);
    amt  := StrToIntDef(string(pArgv[3]), 0);
  end
  else
  begin
    ofst := 0;
    amt  := 2147483647;
  end;
  oldMode := FileMode;
  FileMode := 0;
  {$I-}
  AssignFile(fin, string(pArgv[1]));
  Reset(fin, 1);
  {$I+}
  FileMode := oldMode;
  if IOResult <> 0 then
  begin
    Tcl_AppendResult(interp, PChar('unable to open file "'),
      pArgv[1], PChar('" for reading'), Pointer(nil));
    Result := TCL_ERROR;
    Exit;
  end;
  Seek(fin, ofst);
  MD5Init(@ctx);
  while amt > 0 do
  begin
    if SizeOf(zBuf) <= amt then want := SizeOf(zBuf) else want := amt;
    BlockRead(fin, zBuf[0], want, n);
    if n <= 0 then Break;
    MD5Update(@ctx, PByte(@zBuf[0]), cuint(n));
    Dec(amt, n);
  end;
  CloseFile(fin);
  MD5Final(@digest[0], @ctx);
  converter := TConverter(cd);
  converter(@digest[0], @zBuf[0]);
  Tcl_AppendResult(interp, PChar(@zBuf[0]), Pointer(nil));
  Result := TCL_OK;
end;

{ test_md5.c:393..403 — Md5_Init.  Register the four Tcl commands. }
function Md5_Init(interp: PTclInterp): cint; cdecl;
begin
  Tcl_CreateCommand(interp, PChar('md5'), @md5_cmd,
    TClientData(@MD5DigestToBase16), nil);
  Tcl_CreateCommand(interp, PChar('md5-10x8'), @md5_cmd,
    TClientData(@MD5DigestToBase10x8), nil);
  Tcl_CreateCommand(interp, PChar('md5file'), @md5file_cmd,
    TClientData(@MD5DigestToBase16), nil);
  Tcl_CreateCommand(interp, PChar('md5file-10x8'), @md5file_cmd,
    TClientData(@MD5DigestToBase10x8), nil);
  Result := TCL_OK;
end;

{ test_md5.c:409..423 — md5step.  The md5sum() aggregate step function. }
procedure md5step(context: Psqlite3_context; argc: cint;
  argv: PPsqlite3_value); cdecl;
var
  p:     PMD5Context;
  i:     cint;
  zData: PAnsiChar;
  apArg: PPsqlite3_value;
begin
  if argc < 1 then Exit;
  p := PMD5Context(sqlite3_aggregate_context(context, SizeOf(TMD5Context)));
  if p = nil then Exit;
  if p^.isInit = 0 then
    MD5Init(p);
  apArg := argv;
  for i := 0 to argc - 1 do
  begin
    zData := PAnsiChar(sqlite3_value_text(apArg[i]));
    if zData <> nil then
      MD5Update(p, PByte(zData), cuint(StrLen(zData)));
  end;
end;

{ test_md5.c:425..433 — md5finalize.  The md5sum() aggregate finalizer. }
procedure md5finalize(context: Psqlite3_context); cdecl;
var
  p:      PMD5Context;
  digest: array[0..15] of Byte;
  zBuf:   array[0..32] of AnsiChar;
begin
  p := PMD5Context(sqlite3_aggregate_context(context, SizeOf(TMD5Context)));
  MD5Final(@digest[0], p);
  MD5DigestToBase16(@digest[0], @zBuf[0]);
  sqlite3_result_text(context, @zBuf[0], -1, SQLITE_TRANSIENT);
end;

{ test_md5.c:434..443 — Md5_Register.  Registers the md5sum() SQL
  aggregate on the given connection and exercises sqlite3_overload_function. }
function Md5_Register(db: PTsqlite3; pzErrMsg: PPAnsiChar;
  pThunk: Pointer): cint; cdecl;
begin
  Result := sqlite3_create_function(db, PAnsiChar('md5sum'), -1, SQLITE_UTF8,
    nil, nil, @md5step, @md5finalize);
  sqlite3_overload_function(db, PAnsiChar('md5sum'), -1);
end;

end.
