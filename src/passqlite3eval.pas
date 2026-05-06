{
  SPDX-License-Identifier: blessing

  Faithful port of ../sqlite3/ext/misc/eval.c (125 lines in C).

  Implements the SQL functions eval(X) and eval(X,Y).  X is SQL text to
  run recursively; Y is a separator (default single space) used to join
  the resulting cells/rows.

  Public entry: sqlite3EvalInit(db) — equivalent to sqlite3_eval_init()
  in C; safe to call multiple times.
}
{$I passqlite3.inc}
unit passqlite3eval;

interface

uses
  passqlite3types,
  passqlite3util,
  passqlite3vdbe,
  passqlite3main;

function sqlite3EvalInit(db: PTsqlite3): i32;

implementation

uses
  passqlite3os;

function strlen(s: PAnsiChar): SizeUInt;
var p: PAnsiChar;
begin
  if s = nil then begin Result := 0; Exit; end;
  p := s;
  while p^ <> #0 do Inc(p);
  Result := SizeUInt(p - s);
end;

procedure evalFreeDel(p: Pointer); cdecl;
begin
  sqlite3_free(p);
end;

type
  TEvalResult = record
    z:      PAnsiChar;
    zSep:   PAnsiChar;
    szSep:  i32;
    nAlloc: i64;
    nUsed:  i64;
  end;
  PEvalResult = ^TEvalResult;

function evalCallback(pCtx: Pointer; argc: i32;
                      argv: PPAnsiChar; colnames: PPAnsiChar): i32; cdecl;
var
  p: PEvalResult;
  i: i32;
  z, zNew: PAnsiChar;
  sz: SizeUInt;
begin
  p := PEvalResult(pCtx);
  if argv = nil then
  begin
    Result := 0;
    Exit;
  end;
  for i := 0 to argc - 1 do
  begin
    if argv[i] <> nil then z := argv[i] else z := '';
    sz := strlen(z);
    if i64(sz) + p^.nUsed + p^.szSep + 1 > p^.nAlloc then
    begin
      p^.nAlloc := p^.nAlloc * 2 + i64(sz) + p^.szSep + 1;
      if p^.nAlloc <= $7FFFFFFF then
        zNew := PAnsiChar(sqlite3_realloc64(p^.z, u64(p^.nAlloc)))
      else
        zNew := nil;
      if zNew = nil then
      begin
        sqlite3_free(p^.z);
        FillChar(p^, SizeOf(p^), 0);
        Result := 1;
        Exit;
      end;
      p^.z := zNew;
    end;
    if p^.nUsed > 0 then
    begin
      Move(p^.zSep^, (p^.z + p^.nUsed)^, p^.szSep);
      Inc(p^.nUsed, p^.szSep);
    end;
    if sz > 0 then
      Move(z^, (p^.z + p^.nUsed)^, sz);
    Inc(p^.nUsed, i64(sz));
  end;
  Result := 0;
end;

procedure sqlEvalFunc(pCtx: Psqlite3_context; argc: i32; argv: PPMem); cdecl;
var
  zSql: PAnsiChar;
  db: PTsqlite3;
  zErr: PAnsiChar;
  rc: i32;
  x: TEvalResult;
begin
  FillChar(x, SizeOf(x), 0);
  x.zSep := ' ';
  zErr := nil;
  zSql := PAnsiChar(sqlite3_value_text(argv[0]));
  if zSql = nil then Exit;
  if argc > 1 then
  begin
    x.zSep := PAnsiChar(sqlite3_value_text(argv[1]));
    if x.zSep = nil then Exit;
  end;
  x.szSep := i32(strlen(x.zSep));
  db := sqlite3_context_db_handle(pCtx);
  rc := sqlite3_exec(db, zSql, @evalCallback, @x, @zErr);
  if rc <> SQLITE_OK then
  begin
    sqlite3_result_error(pCtx, zErr, -1);
    sqlite3_free(zErr);
  end
  else if x.zSep = nil then
  begin
    sqlite3_result_error_nomem(pCtx);
    sqlite3_free(x.z);
  end
  else
    sqlite3_result_text(pCtx, x.z, i32(x.nUsed), @evalFreeDel);
end;

function sqlite3EvalInit(db: PTsqlite3): i32;
var rc: i32;
begin
  rc := sqlite3_create_function(db, 'eval', 1,
          SQLITE_UTF8 or SQLITE_DIRECTONLY, nil,
          @sqlEvalFunc, nil, nil);
  if rc = SQLITE_OK then
    rc := sqlite3_create_function(db, 'eval', 2,
            SQLITE_UTF8 or SQLITE_DIRECTONLY, nil,
            @sqlEvalFunc, nil, nil);
  Result := rc;
end;

end.
