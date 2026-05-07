{
  SPDX-License-Identifier: blessing

  Faithful port of ../sqlite3/ext/misc/noop.c (90 lines in C).

  Implements a small family of identity SQL functions used for testing
  the function-flag plumbing (deterministic / innocuous / direct-only),
  plus a multitype_text helper that forces the TEXT representation
  while preserving any numeric copy.

    noop(X)            Default.  Deterministic.
    noop_i(X)          Deterministic + innocuous.
    noop_do(X)         Deterministic + direct-only.
    noop_nd(X)         Non-deterministic.
    multitype_text(X)  Returns X with the TEXT representation forced.

  Public entry: sqlite3NoopInit(db) — equivalent to sqlite3_noop_init()
  in C; safe to call multiple times.
}
{$I passqlite3.inc}
unit passqlite3noop;

interface

uses
  passqlite3types,
  passqlite3util,
  passqlite3vdbe,
  passqlite3main;

function sqlite3NoopInit(db: PTsqlite3): i32;

implementation

{ noop.c:32..39 — noop(X) returns its argument unchanged. }
procedure noopFunc(pCtx: Psqlite3_context; argc: i32; argv: PPMem); cdecl;
begin
  sqlite3_result_value(pCtx, argv[0]);
end;

{ noop.c:48..57 — multitype_text(X).  Coerces argv[0] to TEXT (which
  for numeric inputs adds a TEXT representation alongside the original
  numeric value), then echoes the now-multi-type value back. }
procedure multitypeTextFunc(pCtx: Psqlite3_context; argc: i32; argv: PPMem); cdecl;
begin
  sqlite3_value_text(argv[0]);
  sqlite3_result_value(pCtx, argv[0]);
end;

function sqlite3NoopInit(db: PTsqlite3): i32;
const
  FlagsDet  = SQLITE_UTF8 or SQLITE_DETERMINISTIC;
  FlagsI    = SQLITE_UTF8 or SQLITE_DETERMINISTIC or SQLITE_INNOCUOUS;
  FlagsDo   = SQLITE_UTF8 or SQLITE_DETERMINISTIC or SQLITE_DIRECTONLY;
  FlagsNd   = SQLITE_UTF8;
var
  rc: i32;
begin
  rc := sqlite3_create_function(db, 'noop', 1, FlagsDet, nil,
                                @noopFunc, nil, nil);
  if rc = SQLITE_OK then
    rc := sqlite3_create_function(db, 'noop_i', 1, FlagsI, nil,
                                  @noopFunc, nil, nil);
  if rc = SQLITE_OK then
    rc := sqlite3_create_function(db, 'noop_do', 1, FlagsDo, nil,
                                  @noopFunc, nil, nil);
  if rc = SQLITE_OK then
    rc := sqlite3_create_function(db, 'noop_nd', 1, FlagsNd, nil,
                                  @noopFunc, nil, nil);
  if rc = SQLITE_OK then
    rc := sqlite3_create_function(db, 'multitype_text', 1, FlagsNd, nil,
                                  @multitypeTextFunc, nil, nil);
  Result := rc;
end;

end.
