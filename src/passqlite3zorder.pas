{
  SPDX-License-Identifier: blessing

  Faithful port of ../sqlite3/ext/misc/zorder.c (134 lines in C).

  SQL functions for z-order (Morton code) bit-interleaving:

    zorder(X0, X1, ..., XN)   Generate an N+1 dimension Morton code.
    unzorder(Z, N, K)         Extract the K-th of N dimensions from
                              Morton code Z.

  Public entry: sqlite3ZorderInit(db) — equivalent to
  sqlite3_zorder_init() in C; safe to call multiple times.
}
{$I passqlite3.inc}
unit passqlite3zorder;

interface

uses
  passqlite3types,
  passqlite3util,
  passqlite3vdbe,
  passqlite3main;

function sqlite3ZorderInit(db: PTsqlite3): i32;

implementation

uses
  SysUtils;

{ ordinal — render 1, 2, 3, ... as "1st", "2nd", "3rd", "4th", ...
  to mirror the printf %r conversion used by the C source for the
  zorder() overflow message.  The pas-sqlite3 sqlite3_mprintf cdecl
  entry has no varargs, so we build the message by hand. }
function ordinal(n: i32): AnsiString;
var d: i32;
begin
  d := n mod 100;
  if (d >= 11) and (d <= 13) then
  begin
    Result := IntToStr(n) + 'th';
    Exit;
  end;
  case n mod 10 of
    1: Result := IntToStr(n) + 'st';
    2: Result := IntToStr(n) + 'nd';
    3: Result := IntToStr(n) + 'rd';
  else
    Result := IntToStr(n) + 'th';
  end;
end;

{ zorderFunc (zorder.c:45..78).  Interleaves the low bits of up to 24
  signed-64-bit operands into a single 63-bit Morton code.  Bit i of
  the output comes from bit (i div argc) of operand (i mod argc). }
procedure zorderFunc(pCtx: Psqlite3_context; argc: i32; argv: PPMem); cdecl;
var
  z: i64;
  x: array[0..23] of i64;
  i, j: i32;
  msg: AnsiString;
  cmsg: PAnsiChar;
begin
  z := 0;
  if (argc < 2) or (argc > 24) then
  begin
    sqlite3_result_error(pCtx,
      'zorder() needs between 2 and 24 arguments4', -1);
    Exit;
  end;
  for i := 0 to argc - 1 do
    x[i] := sqlite3_value_int64(argv[i]);
  for i := 0 to 62 do
  begin
    j := i mod argc;
    z := z or ((x[j] and 1) shl i);
    x[j] := x[j] shr 1;
  end;
  sqlite3_result_int64(pCtx, z);
  for i := 0 to argc - 1 do
  begin
    if x[i] <> 0 then
    begin
      msg := Format('the %s argument to zorder() (%d) is too large '
                    + 'for a 64-bit %d-dimensional Morton code',
                    [ordinal(i + 1), sqlite3_value_int64(argv[i]), argc]);
      cmsg := PAnsiChar(msg);
      sqlite3_result_error(pCtx, cmsg, -1);
      Break;
    end;
  end;
end;

{ unzorderFunc (zorder.c:87..113).  Inverse of zorder; extracts the
  K-th dimension out of an N-dimensional Morton code Z. }
procedure unzorderFunc(pCtx: Psqlite3_context; argc: i32; argv: PPMem); cdecl;
var
  z, n, i, x: i64;
  j, k: i32;
begin
  z := sqlite3_value_int64(argv[0]);
  n := sqlite3_value_int64(argv[1]);
  if (n < 2) or (n > 24) then
  begin
    sqlite3_result_error(pCtx,
      'N argument to unzorder(Z,N,K) should be between 2 and 24', -1);
    Exit;
  end;
  i := sqlite3_value_int64(argv[2]);
  if (i < 0) or (i >= n) then
  begin
    sqlite3_result_error(pCtx,
      'K argument to unzorder(Z,N,K) should be between 0 and N-1', -1);
    Exit;
  end;
  x := 0;
  k := 0;
  j := i32(i);
  while j < 63 do
  begin
    x := x or (((z shr j) and 1) shl k);
    Inc(j, i32(n));
    Inc(k);
  end;
  sqlite3_result_int64(pCtx, x);
end;

function sqlite3ZorderInit(db: PTsqlite3): i32;
var rc: i32;
begin
  rc := sqlite3_create_function(db, 'zorder', -1, SQLITE_UTF8, nil,
                                @zorderFunc, nil, nil);
  if rc = SQLITE_OK then
    rc := sqlite3_create_function(db, 'unzorder', 3, SQLITE_UTF8, nil,
                                  @unzorderFunc, nil, nil);
  Result := rc;
end;

end.
