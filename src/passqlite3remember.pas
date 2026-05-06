{
  SPDX-License-Identifier: blessing

  Faithful port of ../sqlite3/ext/misc/remember.c (72 lines in C).

  Implements the SQL function remember(V, PTR) — returns the integer V
  while writing it through to the i64 pointed to by PTR (a "carray"-
  tagged sqlite3_value_pointer).  Mirrors rememberFunc one-for-one.

  Public entry: sqlite3RememberInit(db).
}
{$I passqlite3.inc}
unit passqlite3remember;

interface

uses
  passqlite3types,
  passqlite3util,
  passqlite3vdbe,
  passqlite3main;

function sqlite3RememberInit(db: PTsqlite3): i32;

implementation

procedure rememberFunc(pCtx: Psqlite3_context; argc: i32; argv: PPMem); cdecl;
var
  v: i64;
  ptr: ^i64;
begin
  v := sqlite3_value_int64(argv[0]);
  ptr := sqlite3_value_pointer(argv[1], 'carray');
  if ptr <> nil then ptr^ := v;
  sqlite3_result_int64(pCtx, v);
end;

function sqlite3RememberInit(db: PTsqlite3): i32;
begin
  Result := sqlite3_create_function(db, 'remember', 2, SQLITE_UTF8, nil,
                                    @rememberFunc, nil, nil);
end;

end.
