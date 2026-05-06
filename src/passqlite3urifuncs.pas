{
  SPDX-License-Identifier: blessing

  Faithful port of ../sqlite3/ext/misc/urifuncs.c (209 lines in C).

  Implements SQL wrappers for the URI / filename C-API:
    sqlite3_db_filename(SCHEMA)
    sqlite3_uri_parameter(SCHEMA, NAME)
    sqlite3_uri_boolean(SCHEMA, NAME, DEFAULT)
    sqlite3_uri_int64(SCHEMA, NAME, DEFAULT)
    sqlite3_uri_key(SCHEMA, N)
    sqlite3_filename_database(SCHEMA)
    sqlite3_filename_journal(SCHEMA)
    sqlite3_filename_wal(SCHEMA)

  Public entry: sqlite3UrifuncsInit(db) — equivalent to
  sqlite3_urifuncs_init() in C; safe to call multiple times.
}
{$I passqlite3.inc}
unit passqlite3urifuncs;

interface

uses
  passqlite3types,
  passqlite3util,
  passqlite3vdbe,
  passqlite3main;

function sqlite3UrifuncsInit(db: PTsqlite3): i32;

implementation

uses
  passqlite3os;

procedure funcDbFilename(pCtx: Psqlite3_context; argc: i32; argv: PPMem); cdecl;
var
  zSchema, zFile: PAnsiChar;
  db: PTsqlite3;
begin
  zSchema := PAnsiChar(sqlite3_value_text(argv[0]));
  db := sqlite3_context_db_handle(pCtx);
  zFile := sqlite3_db_filename(db, zSchema);
  sqlite3_result_text(pCtx, zFile, -1, SQLITE_TRANSIENT);
end;

procedure funcUriParameter(pCtx: Psqlite3_context; argc: i32; argv: PPMem); cdecl;
var
  zSchema, zName, zFile, zRes: PAnsiChar;
  db: PTsqlite3;
begin
  zSchema := PAnsiChar(sqlite3_value_text(argv[0]));
  db := sqlite3_context_db_handle(pCtx);
  zName := PAnsiChar(sqlite3_value_text(argv[1]));
  zFile := sqlite3_db_filename(db, zSchema);
  zRes := sqlite3_uri_parameter(zFile, zName);
  sqlite3_result_text(pCtx, zRes, -1, SQLITE_TRANSIENT);
end;

procedure funcUriBoolean(pCtx: Psqlite3_context; argc: i32; argv: PPMem); cdecl;
var
  zSchema, zName, zFile: PAnsiChar;
  db: PTsqlite3;
  iDflt, iRes: i32;
begin
  zSchema := PAnsiChar(sqlite3_value_text(argv[0]));
  db := sqlite3_context_db_handle(pCtx);
  zName := PAnsiChar(sqlite3_value_text(argv[1]));
  zFile := sqlite3_db_filename(db, zSchema);
  iDflt := sqlite3_value_int(argv[2]);
  iRes := sqlite3_uri_boolean(zFile, zName, iDflt);
  sqlite3_result_int(pCtx, iRes);
end;

procedure funcUriKey(pCtx: Psqlite3_context; argc: i32; argv: PPMem); cdecl;
var
  zSchema, zFile, zRes: PAnsiChar;
  db: PTsqlite3;
  N: i32;
begin
  zSchema := PAnsiChar(sqlite3_value_text(argv[0]));
  db := sqlite3_context_db_handle(pCtx);
  N := sqlite3_value_int(argv[1]);
  zFile := sqlite3_db_filename(db, zSchema);
  zRes := sqlite3_uri_key(zFile, N);
  sqlite3_result_text(pCtx, zRes, -1, SQLITE_TRANSIENT);
end;

procedure funcUriInt64(pCtx: Psqlite3_context; argc: i32; argv: PPMem); cdecl;
var
  zSchema, zName, zFile: PAnsiChar;
  db: PTsqlite3;
  iDflt, iRes: i64;
begin
  zSchema := PAnsiChar(sqlite3_value_text(argv[0]));
  db := sqlite3_context_db_handle(pCtx);
  zName := PAnsiChar(sqlite3_value_text(argv[1]));
  zFile := sqlite3_db_filename(db, zSchema);
  iDflt := sqlite3_value_int64(argv[2]);
  iRes := sqlite3_uri_int64(zFile, zName, iDflt);
  sqlite3_result_int64(pCtx, iRes);
end;

procedure funcFilenameDatabase(pCtx: Psqlite3_context; argc: i32; argv: PPMem); cdecl;
var
  zSchema, zFile, zRes: PAnsiChar;
  db: PTsqlite3;
begin
  zSchema := PAnsiChar(sqlite3_value_text(argv[0]));
  db := sqlite3_context_db_handle(pCtx);
  zFile := sqlite3_db_filename(db, zSchema);
  if zFile <> nil then zRes := sqlite3_filename_database(zFile)
  else zRes := nil;
  sqlite3_result_text(pCtx, zRes, -1, SQLITE_TRANSIENT);
end;

procedure funcFilenameJournal(pCtx: Psqlite3_context; argc: i32; argv: PPMem); cdecl;
var
  zSchema, zFile, zRes: PAnsiChar;
  db: PTsqlite3;
begin
  zSchema := PAnsiChar(sqlite3_value_text(argv[0]));
  db := sqlite3_context_db_handle(pCtx);
  zFile := sqlite3_db_filename(db, zSchema);
  if zFile <> nil then zRes := sqlite3_filename_journal(zFile)
  else zRes := nil;
  sqlite3_result_text(pCtx, zRes, -1, SQLITE_TRANSIENT);
end;

procedure funcFilenameWal(pCtx: Psqlite3_context; argc: i32; argv: PPMem); cdecl;
var
  zSchema, zFile, zRes: PAnsiChar;
  db: PTsqlite3;
begin
  zSchema := PAnsiChar(sqlite3_value_text(argv[0]));
  db := sqlite3_context_db_handle(pCtx);
  zFile := sqlite3_db_filename(db, zSchema);
  if zFile <> nil then zRes := sqlite3_filename_wal(zFile)
  else zRes := nil;
  sqlite3_result_text(pCtx, zRes, -1, SQLITE_TRANSIENT);
end;

function sqlite3UrifuncsInit(db: PTsqlite3): i32;
type
  TFuncRow = record
    zName: PAnsiChar;
    nArg:  i32;
    xFunc: Pointer;
  end;
const
  aFunc: array[0..7] of TFuncRow = (
    (zName: 'sqlite3_db_filename';       nArg: 1; xFunc: @funcDbFilename),
    (zName: 'sqlite3_uri_parameter';     nArg: 2; xFunc: @funcUriParameter),
    (zName: 'sqlite3_uri_boolean';       nArg: 3; xFunc: @funcUriBoolean),
    (zName: 'sqlite3_uri_int64';         nArg: 3; xFunc: @funcUriInt64),
    (zName: 'sqlite3_uri_key';           nArg: 2; xFunc: @funcUriKey),
    (zName: 'sqlite3_filename_database'; nArg: 1; xFunc: @funcFilenameDatabase),
    (zName: 'sqlite3_filename_journal';  nArg: 1; xFunc: @funcFilenameJournal),
    (zName: 'sqlite3_filename_wal';      nArg: 1; xFunc: @funcFilenameWal)
  );
var
  rc: i32;
  i: i32;
begin
  rc := SQLITE_OK;
  i := 0;
  while (rc = SQLITE_OK) and (i <= High(aFunc)) do
  begin
    rc := sqlite3_create_function(db, aFunc[i].zName, aFunc[i].nArg,
                                  SQLITE_UTF8, nil,
                                  aFunc[i].xFunc, nil, nil);
    Inc(i);
  end;
  Result := rc;
end;

end.
