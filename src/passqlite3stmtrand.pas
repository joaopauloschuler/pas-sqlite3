{
  SPDX-License-Identifier: blessing

  Faithful port of ../sqlite3/ext/misc/stmtrand.c (97 lines in C).

  Implements stmtrand(SEED) and stmtrand() — pseudo-random integer
  generator that yields a repeatable sequence per prepared statement
  (the seed is consumed by the first call only; subsequent calls reuse
  the cached PRNG state stored via sqlite3_set_auxdata).

  Public entry: sqlite3StmtrandInit(db).
}
{$I passqlite3.inc}
unit passqlite3stmtrand;

interface

uses
  passqlite3types,
  passqlite3util,
  passqlite3vdbe,
  passqlite3main;

function sqlite3StmtrandInit(db: PTsqlite3): i32;

implementation

uses
  passqlite3os; { sqlite3_malloc64 / sqlite3_free }

const
  STMTRAND_KEY = -4418371;

type
  PStmtrand = ^TStmtrand;
  TStmtrand = record
    x, y: u32;
  end;

procedure stmtrandFreeCb(p: Pointer); cdecl;
begin
  sqlite3_free(p);
end;

procedure stmtrandFunc(pCtx: Psqlite3_context; argc: i32; argv: PPMem); cdecl;
var
  p: PStmtrand;
  seed: u32;
begin
  p := PStmtrand(sqlite3_get_auxdata(pCtx, STMTRAND_KEY));
  if p = nil then
  begin
    p := PStmtrand(sqlite3_malloc64(SizeOf(TStmtrand)));
    if p = nil then
    begin
      sqlite3_result_error_nomem(pCtx);
      Exit;
    end;
    if argc >= 1 then
      seed := u32(sqlite3_value_int(argv[0]))
    else
      seed := 0;
    p^.x := seed or 1;
    p^.y := seed;
    sqlite3_set_auxdata(pCtx, STMTRAND_KEY, p, @stmtrandFreeCb);
    p := PStmtrand(sqlite3_get_auxdata(pCtx, STMTRAND_KEY));
    if p = nil then
    begin
      sqlite3_result_error_nomem(pCtx);
      Exit;
    end;
  end;
  { p->x = (p->x>>1) ^ ((1+~(p->x&1)) & 0xd0000001); }
  p^.x := (p^.x shr 1) xor (((1 + (not (p^.x and 1))) and u32($d0000001)));
  p^.y := p^.y * u32(1103515245) + u32(12345);
  sqlite3_result_int(pCtx, i32((p^.x xor p^.y) and u32($7fffffff)));
end;

function sqlite3StmtrandInit(db: PTsqlite3): i32;
var rc: i32;
begin
  rc := sqlite3_create_function(db, 'stmtrand', 1, SQLITE_UTF8, nil,
                                @stmtrandFunc, nil, nil);
  if rc = SQLITE_OK then
    rc := sqlite3_create_function(db, 'stmtrand', 0, SQLITE_UTF8, nil,
                                  @stmtrandFunc, nil, nil);
  Result := rc;
end;

end.
