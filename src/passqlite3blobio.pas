{
  SPDX-License-Identifier: blessing

  Faithful port of ../sqlite3/ext/misc/blobio.c (152 lines in C).

  Implements the SQL functions
    readblob(SCHEMA, TABLE, COLUMN, ROWID, OFFSET, N)
    writeblob(SCHEMA, TABLE, COLUMN, ROWID, OFFSET, NEWDATA)
  using the incremental BLOB I/O API (sqlite3_blob_open / read / write
  / close).

  Public entry: sqlite3BlobioInit(db).
}
{$I passqlite3.inc}
unit passqlite3blobio;

interface

uses
  passqlite3types,
  passqlite3util,
  passqlite3vdbe,
  passqlite3main;

function sqlite3BlobioInit(db: PTsqlite3): i32;

implementation

uses
  passqlite3os; { sqlite3_malloc64 / sqlite3_free }

procedure blobioFreeCb(p: Pointer); cdecl;
begin
  sqlite3_free(p);
end;

procedure readblobFunc(pCtx: Psqlite3_context; argc: i32; argv: PPMem); cdecl;
var
  pBlob: Psqlite3_blob;
  zSchema, zTable, zColumn: PAnsiChar;
  iRowid: i64;
  iOfst, nData, rc: i32;
  aData: PByte;
  db: PTsqlite3;
begin
  pBlob := nil;
  zSchema := PAnsiChar(sqlite3_value_text(argv[0]));
  zTable := PAnsiChar(sqlite3_value_text(argv[1]));
  if zTable = nil then
  begin
    sqlite3_result_error(pCtx, 'bad table name', -1);
    Exit;
  end;
  zColumn := PAnsiChar(sqlite3_value_text(argv[2]));
  if zColumn = nil then
  begin
    sqlite3_result_error(pCtx, 'bad column name', -1);
    Exit;
  end;
  iRowid := sqlite3_value_int64(argv[3]);
  iOfst := sqlite3_value_int(argv[4]);
  nData := sqlite3_value_int(argv[5]);
  if nData <= 0 then Exit;
  aData := PByte(sqlite3_malloc64(u64(nData) + 1));
  if aData = nil then
  begin
    sqlite3_result_error_nomem(pCtx);
    Exit;
  end;
  db := sqlite3_context_db_handle(pCtx);
  rc := sqlite3_blob_open(db, zSchema, zTable, zColumn, iRowid, 0, pBlob);
  if rc <> 0 then
  begin
    sqlite3_free(aData);
    sqlite3_result_error(pCtx, 'cannot open BLOB pointer', -1);
    Exit;
  end;
  rc := sqlite3_blob_read(pBlob, aData, nData, iOfst);
  sqlite3_blob_close(pBlob);
  if rc <> 0 then
  begin
    sqlite3_free(aData);
    sqlite3_result_error(pCtx, 'BLOB read failed', -1);
  end
  else
  begin
    sqlite3_result_blob(pCtx, aData, nData, @blobioFreeCb);
  end;
end;

procedure writeblobFunc(pCtx: Psqlite3_context; argc: i32; argv: PPMem); cdecl;
var
  pBlob: Psqlite3_blob;
  zSchema, zTable, zColumn: PAnsiChar;
  iRowid: i64;
  iOfst, nData, rc: i32;
  aData: Pointer;
  db: PTsqlite3;
begin
  pBlob := nil;
  zSchema := PAnsiChar(sqlite3_value_text(argv[0]));
  zTable := PAnsiChar(sqlite3_value_text(argv[1]));
  if zTable = nil then
  begin
    sqlite3_result_error(pCtx, 'bad table name', -1);
    Exit;
  end;
  zColumn := PAnsiChar(sqlite3_value_text(argv[2]));
  if zColumn = nil then
  begin
    sqlite3_result_error(pCtx, 'bad column name', -1);
    Exit;
  end;
  iRowid := sqlite3_value_int64(argv[3]);
  iOfst := sqlite3_value_int(argv[4]);
  if sqlite3_value_type(argv[5]) <> SQLITE_BLOB then
  begin
    sqlite3_result_error(pCtx, '6th argument must be a BLOB', -1);
    Exit;
  end;
  nData := sqlite3_value_bytes(argv[5]);
  aData := sqlite3_value_blob(argv[5]);
  db := sqlite3_context_db_handle(pCtx);
  rc := sqlite3_blob_open(db, zSchema, zTable, zColumn, iRowid, 1, pBlob);
  if rc <> 0 then
  begin
    sqlite3_result_error(pCtx, 'cannot open BLOB pointer', -1);
    Exit;
  end;
  rc := sqlite3_blob_write(pBlob, aData, nData, iOfst);
  sqlite3_blob_close(pBlob);
  if rc <> 0 then
    sqlite3_result_error(pCtx, 'BLOB write failed', -1);
end;

function sqlite3BlobioInit(db: PTsqlite3): i32;
var rc: i32;
begin
  rc := sqlite3_create_function(db, 'readblob', 6, SQLITE_UTF8, nil,
                                @readblobFunc, nil, nil);
  if rc = SQLITE_OK then
    rc := sqlite3_create_function(db, 'writeblob', 6, SQLITE_UTF8, nil,
                                  @writeblobFunc, nil, nil);
  Result := rc;
end;

end.
