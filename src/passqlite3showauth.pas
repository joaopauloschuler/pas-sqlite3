{
  SPDX-License-Identifier: blessing

  Faithful port of ../sqlite3/ext/misc/showauth.c (103 lines in C).

  Installs a debug authorizer callback that writes every authorization
  request to stdout in the canonical "AUTH: op,z1,z2,z3,z4" form and
  returns SQLITE_OK.  Used in shell tracing scenarios.

  Public entry: sqlite3ShowAuthInit(db) — equivalent to
  sqlite3_showauth_init() in C.  Safe to call multiple times; later
  calls just re-bind the authorizer to this callback.
}
{$I passqlite3.inc}
unit passqlite3showauth;

interface

uses
  SysUtils,
  passqlite3types,
  passqlite3util,
  passqlite3vdbe,
  passqlite3codegen;

function sqlite3ShowAuthInit(db: PTsqlite3): i32;

implementation

{ showauth.c:24..86 — authCallback.  Map the op code to its symbolic
  name, substitute "NULL" for nil string args, and print the canonical
  five-field record. }
function authCallback(pClientData: Pointer; op: i32;
  z1, z2, z3, z4: PAnsiChar): i32; cdecl;
var
  zOp:    PAnsiChar;
  buf:    AnsiString;
  s1, s2, s3, s4: PAnsiChar;
const
  { showauth.c uses a couple of action codes whose symbolic names
    collide with result-code constants in our port (SQLITE_DELETE,
    SQLITE_INSERT, SQLITE_PRAGMA, SQLITE_READ, SQLITE_SELECT,
    SQLITE_TRANSACTION, SQLITE_UPDATE, SQLITE_ATTACH, SQLITE_DETACH,
    SQLITE_ALTER_TABLE, SQLITE_REINDEX, SQLITE_ANALYZE,
    SQLITE_CREATE_VTABLE, SQLITE_DROP_VTABLE, SQLITE_FUNCTION,
    SQLITE_SAVEPOINT, SQLITE_RECURSIVE, SQLITE_COPY).  In passqlite3vdbe
    they wear an "_AUTH" suffix; SQLITE_COPY (0, deprecated) is local. }
  SQLITE_COPY_AUTH      = 0;
begin
  case op of
    SQLITE_CREATE_INDEX:        zOp := 'CREATE_INDEX';
    SQLITE_CREATE_TABLE:        zOp := 'CREATE_TABLE';
    SQLITE_CREATE_TEMP_INDEX:   zOp := 'CREATE_TEMP_INDEX';
    SQLITE_CREATE_TEMP_TABLE:   zOp := 'CREATE_TEMP_TABLE';
    SQLITE_CREATE_TEMP_TRIGGER: zOp := 'CREATE_TEMP_TRIGGER';
    SQLITE_CREATE_TEMP_VIEW:    zOp := 'CREATE_TEMP_VIEW';
    SQLITE_CREATE_TRIGGER:      zOp := 'CREATE_TRIGGER';
    SQLITE_CREATE_VIEW:         zOp := 'CREATE_VIEW';
    SQLITE_DELETE_AUTH:         zOp := 'DELETE';
    SQLITE_DROP_INDEX:          zOp := 'DROP_INDEX';
    SQLITE_DROP_TABLE:          zOp := 'DROP_TABLE';
    SQLITE_DROP_TEMP_INDEX:     zOp := 'DROP_TEMP_INDEX';
    SQLITE_DROP_TEMP_TABLE:     zOp := 'DROP_TEMP_TABLE';
    SQLITE_DROP_TEMP_TRIGGER:   zOp := 'DROP_TEMP_TRIGGER';
    SQLITE_DROP_TEMP_VIEW:      zOp := 'DROP_TEMP_VIEW';
    SQLITE_DROP_TRIGGER:        zOp := 'DROP_TRIGGER';
    SQLITE_DROP_VIEW:           zOp := 'DROP_VIEW';
    SQLITE_INSERT_AUTH:         zOp := 'INSERT';
    SQLITE_PRAGMA_AUTH:         zOp := 'PRAGMA';
    SQLITE_READ_AUTH:           zOp := 'READ';
    SQLITE_SELECT_AUTH:         zOp := 'SELECT';
    SQLITE_TRANSACTION_AUTH:    zOp := 'TRANSACTION';
    SQLITE_UPDATE_AUTH:         zOp := 'UPDATE';
    SQLITE_ATTACH_AUTH:         zOp := 'ATTACH';
    SQLITE_DETACH_AUTH:         zOp := 'DETACH';
    SQLITE_ALTER_TABLE_AUTH:    zOp := 'ALTER_TABLE';
    SQLITE_REINDEX_AUTH:        zOp := 'REINDEX';
    SQLITE_ANALYZE_AUTH:        zOp := 'ANALYZE';
    SQLITE_CREATE_VTABLE:       zOp := 'CREATE_VTABLE';
    SQLITE_DROP_VTABLE:         zOp := 'DROP_VTABLE';
    SQLITE_FUNCTION_AUTH:       zOp := 'FUNCTION';
    SQLITE_SAVEPOINT_AUTH:      zOp := 'SAVEPOINT';
    SQLITE_COPY_AUTH:           zOp := 'COPY';
    SQLITE_RECURSIVE_AUTH:      zOp := 'RECURSIVE';
  else begin
    buf := IntToStr(op);
    zOp := PAnsiChar(buf);
  end;
  end;

  if z1 = nil then s1 := 'NULL' else s1 := z1;
  if z2 = nil then s2 := 'NULL' else s2 := z2;
  if z3 = nil then s3 := 'NULL' else s3 := z3;
  if z4 = nil then s4 := 'NULL' else s4 := z4;

  WriteLn('AUTH: ', zOp, ',', s1, ',', s2, ',', s3, ',', s4);
  Result := SQLITE_OK;
end;

function sqlite3ShowAuthInit(db: PTsqlite3): i32;
begin
  Result := sqlite3_set_authorizer(db, @authCallback, nil);
end;

end.
