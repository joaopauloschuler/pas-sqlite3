{
  SPDX-License-Identifier: blessing

  Faithful port of ../sqlite3/ext/misc/compress.c (131 lines in C).

  Implements the SQL functions compress(X) / uncompress(X) backed by zlib.
  Output of compress(X) is a BLOB that begins with a 1..5 byte
  variable-length integer carrying the original size, followed by the
  zlib-format payload.  uncompress() inverts the framing.

  Public entry: sqlite3CompressInit(db) — equivalent to
  sqlite3_compress_init() in C; safe to call multiple times.
}
{$I passqlite3.inc}
unit passqlite3compress;

interface

uses
  passqlite3types,
  passqlite3util,
  passqlite3vdbe,
  passqlite3main;

function sqlite3CompressInit(db: PTsqlite3): i32;

implementation

uses
  ctypes,
  passqlite3os;  { sqlite3_malloc64 / sqlite3_free externals }

{ libz uLong is `unsigned long` (Linux x86-64 = 64-bit). }
function zlib_compress(dest: Pointer; destLen: pculong;
  source: Pointer; sourceLen: culong): i32; cdecl;
  external 'z' name 'compress';

function zlib_uncompress(dest: Pointer; destLen: pculong;
  source: Pointer; sourceLen: culong): i32; cdecl;
  external 'z' name 'uncompress';

const
  Z_OK_RC = 0;

{ compress(X) — compress.c:46..73.  Frame = 1..5 byte big-endian
  base-128 integer (high bit set on the last byte) + zlib payload. }
procedure compressFunc(pCtx: Psqlite3_context; argc: i32; argv: PPMem); cdecl;
var
  pIn, pOut: PByte;
  nIn: u32;
  nOut: culong;
  x: array[0..7] of Byte;
  rc, i, j: i32;
begin
  if argc <> 1 then Exit;
  pIn := PByte(sqlite3_value_blob(argv[0]));
  nIn := u32(sqlite3_value_bytes(argv[0]));
  nOut := culong(13 + nIn + (nIn + 999) div 1000);
  pOut := PByte(sqlite3_malloc64(u64(nOut + 5)));
  if pOut = nil then
  begin
    sqlite3_result_error_nomem(pCtx);
    Exit;
  end;
  for i := 4 downto 0 do
    x[i] := Byte((nIn shr (7 * (4 - i))) and $7F);
  i := 0;
  while (i < 4) and (x[i] = 0) do Inc(i);
  j := 0;
  while i <= 4 do
  begin
    pOut[j] := x[i];
    Inc(i); Inc(j);
  end;
  pOut[j - 1] := pOut[j - 1] or $80;
  rc := zlib_compress(@pOut[j], @nOut, pIn, culong(nIn));
  if rc = Z_OK_RC then
    sqlite3_result_blob(pCtx, pOut, i32(nOut) + j, SQLITE_TRANSIENT);
  sqlite3_free(pOut);
end;

{ uncompress(X) — compress.c:81..107. }
procedure uncompressFunc(pCtx: Psqlite3_context; argc: i32; argv: PPMem); cdecl;
var
  pIn, pOut: PByte;
  nIn: u32;
  nOut: culong;
  rc: i32;
  i: u32;
begin
  if argc <> 1 then Exit;
  pIn := PByte(sqlite3_value_blob(argv[0]));
  nIn := u32(sqlite3_value_bytes(argv[0]));
  nOut := 0;
  i := 0;
  while (i < nIn) and (i < 5) do
  begin
    nOut := (nOut shl 7) or culong(pIn[i] and $7F);
    if (pIn[i] and $80) <> 0 then
    begin
      Inc(i);
      Break;
    end;
    Inc(i);
  end;
  pOut := PByte(sqlite3_malloc64(u64(nOut + 1)));
  if pOut = nil then
  begin
    sqlite3_result_error_nomem(pCtx);
    Exit;
  end;
  rc := zlib_uncompress(pOut, @nOut, @pIn[i], culong(nIn - i));
  if rc = Z_OK_RC then
    sqlite3_result_blob(pCtx, pOut, i32(nOut), SQLITE_TRANSIENT);
  sqlite3_free(pOut);
end;

function sqlite3CompressInit(db: PTsqlite3): i32;
const
  Flags = SQLITE_UTF8 or SQLITE_INNOCUOUS;
var
  rc: i32;
begin
  rc := sqlite3_create_function(db, 'compress', 1, Flags, nil,
                                @compressFunc, nil, nil);
  if rc = SQLITE_OK then
    rc := sqlite3_create_function(db, 'uncompress', 1,
            Flags or SQLITE_DETERMINISTIC, nil,
            @uncompressFunc, nil, nil);
  Result := rc;
end;

end.
