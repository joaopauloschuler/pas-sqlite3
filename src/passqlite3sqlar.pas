{
  SPDX-License-Identifier: blessing

  Faithful port of ../sqlite3/ext/misc/sqlar.c (126 lines in C).

  Implements the SQL functions sqlar_compress(X) and sqlar_uncompress(X,SZ)
  used by the shell tool's built-in sqlar archive support.  Output uses the
  zlib framed format (2-byte ident header + 4-byte trailing checksum); SZ
  carries the original size out-of-band (typically the corresponding row's
  size column in the sqlar archive schema).

  Public entry: sqlite3SqlarInit(db) — equivalent to sqlite3_sqlar_init()
  in C; safe to call multiple times.
}
{$I passqlite3.inc}
unit passqlite3sqlar;

interface

uses
  passqlite3types,
  passqlite3util,
  passqlite3vdbe,
  passqlite3main;

function sqlite3SqlarInit(db: PTsqlite3): i32;

implementation

uses
  ctypes,
  passqlite3os;

function zlib_compress(dest: Pointer; destLen: pculong;
  source: Pointer; sourceLen: culong): i32; cdecl;
  external 'z' name 'compress';

function zlib_uncompress(dest: Pointer; destLen: pculong;
  source: Pointer; sourceLen: culong): i32; cdecl;
  external 'z' name 'uncompress';

function zlib_compressBound(sourceLen: culong): culong; cdecl;
  external 'z' name 'compressBound';

const
  Z_OK_RC = 0;

{ sqlar_compress(X) — sqlar.c:39..65.  If X is a BLOB whose zlib
  compression yields a smaller blob, return the compressed blob;
  otherwise return X unchanged. }
procedure sqlarCompressFunc(pCtx: Psqlite3_context; argc: i32; argv: PPMem); cdecl;
var
  pData, pOut: Pointer;
  nData: culong;
  nOut: culong;
  rc: i32;
begin
  if argc <> 1 then Exit;
  if sqlite3_value_type(argv[0]) = SQLITE_BLOB then
  begin
    pData := sqlite3_value_blob(argv[0]);
    nData := culong(sqlite3_value_bytes(argv[0]));
    nOut := zlib_compressBound(nData);
    pOut := sqlite3_malloc64(u64(nOut));
    if pOut = nil then
    begin
      sqlite3_result_error_nomem(pCtx);
      Exit;
    end;
    rc := zlib_compress(pOut, @nOut, pData, nData);
    if rc <> Z_OK_RC then
      sqlite3_result_error(pCtx, 'error in compress()', -1)
    else if nOut < nData then
      sqlite3_result_blob(pCtx, pOut, i32(nOut), SQLITE_TRANSIENT)
    else
      sqlite3_result_value(pCtx, argv[0]);
    sqlite3_free(pOut);
  end
  else
    sqlite3_result_value(pCtx, argv[0]);
end;

{ sqlar_uncompress(X,SZ) — sqlar.c:73..99. }
procedure sqlarUncompressFunc(pCtx: Psqlite3_context; argc: i32; argv: PPMem); cdecl;
var
  nData: culong;
  sz: i64;
  szf: culong;
  pData, pOut: Pointer;
  rc: i32;
begin
  if argc <> 2 then Exit;
  sz := sqlite3_value_int64(argv[1]);
  nData := culong(sqlite3_value_bytes(argv[0]));
  if (sz <= 0) or (i64(nData) = sz) then
  begin
    sqlite3_result_value(pCtx, argv[0]);
    Exit;
  end;
  szf := culong(sz);
  pData := sqlite3_value_blob(argv[0]);
  pOut := sqlite3_malloc64(u64(sz));
  if pOut = nil then
  begin
    sqlite3_result_error_nomem(pCtx);
    Exit;
  end;
  rc := zlib_uncompress(pOut, @szf, pData, nData);
  if rc <> Z_OK_RC then
    sqlite3_result_error(pCtx, 'error in uncompress()', -1)
  else
    sqlite3_result_blob(pCtx, pOut, i32(szf), SQLITE_TRANSIENT);
  sqlite3_free(pOut);
end;

function sqlite3SqlarInit(db: PTsqlite3): i32;
const
  Flags = SQLITE_UTF8 or SQLITE_INNOCUOUS;
var
  rc: i32;
begin
  rc := sqlite3_create_function(db, 'sqlar_compress', 1, Flags, nil,
                                @sqlarCompressFunc, nil, nil);
  if rc = SQLITE_OK then
    rc := sqlite3_create_function(db, 'sqlar_uncompress', 2, Flags, nil,
                                  @sqlarUncompressFunc, nil, nil);
  Result := rc;
end;

end.
