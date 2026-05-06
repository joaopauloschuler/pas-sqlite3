{
  SPDX-License-Identifier: blessing

  Faithful port of ../sqlite3/ext/misc/rot13.c (115 lines in C).

  Implements the SQL function rot13(X) and the rot13 collating sequence.
  rot13 maps ASCII letters by 13 positions (a..z and A..Z); other bytes
  pass through unchanged.

  Public entry: sqlite3RotInit(db) — equivalent to sqlite3_rot_init()
  in C; safe to call multiple times.
}
{$I passqlite3.inc}
unit passqlite3rot13;

interface

uses
  passqlite3types,
  passqlite3util,
  passqlite3vdbe,
  passqlite3main;

function sqlite3RotInit(db: PTsqlite3): i32;

implementation

uses
  passqlite3os;

{ Single-character ASCII rot13 (rot13.c:24..33). }
function rot13(c: Byte): Byte; inline;
begin
  if (c >= Ord('a')) and (c <= Ord('z')) then
  begin
    Inc(c, 13);
    if c > Ord('z') then Dec(c, 26);
  end
  else if (c >= Ord('A')) and (c <= Ord('Z')) then
  begin
    Inc(c, 13);
    if c > Ord('Z') then Dec(c, 26);
  end;
  Result := c;
end;

{ rot13(X) — SQL scalar (rot13.c:42..70). }
procedure rot13Func(pCtx: Psqlite3_context; argc: i32; argv: PPMem); cdecl;
var
  zIn, zOut: PByte;
  zToFree: PByte;
  zTemp: array[0..99] of Byte;
  nIn, i: i32;
begin
  if sqlite3_value_type(argv[0]) = SQLITE_NULL then Exit;
  zIn := PByte(sqlite3_value_text(argv[0]));
  nIn := sqlite3_value_bytes(argv[0]);
  zToFree := nil;
  if nIn < SizeOf(zTemp) - 1 then
    zOut := @zTemp[0]
  else
  begin
    zOut := PByte(sqlite3_malloc64(u64(nIn + 1)));
    zToFree := zOut;
    if zOut = nil then
    begin
      sqlite3_result_error_nomem(pCtx);
      Exit;
    end;
  end;
  for i := 0 to nIn - 1 do
    zOut[i] := rot13(zIn[i]);
  zOut[nIn] := 0;
  sqlite3_result_text(pCtx, PAnsiChar(zOut), nIn, SQLITE_TRANSIENT);
  if zToFree <> nil then sqlite3_free(zToFree);
end;

{ rot13 collation (rot13.c:81..94). }
function rot13CollFunc(notUsed: Pointer;
  nKey1: i32; pKey1: Pointer;
  nKey2: i32; pKey2: Pointer): i32; cdecl;
var
  zA, zB: PByte;
  i, x, n: i32;
begin
  zA := PByte(pKey1);
  zB := PByte(pKey2);
  if nKey1 < nKey2 then n := nKey1 else n := nKey2;
  for i := 0 to n - 1 do
  begin
    x := i32(rot13(zA[i])) - i32(rot13(zB[i]));
    if x <> 0 then
    begin
      Result := x;
      Exit;
    end;
  end;
  Result := nKey1 - nKey2;
end;

function sqlite3RotInit(db: PTsqlite3): i32;
const
  Flags = SQLITE_UTF8 or SQLITE_INNOCUOUS or SQLITE_DETERMINISTIC;
var
  rc: i32;
begin
  rc := sqlite3_create_function(db, 'rot13', 1, Flags, nil,
                                @rot13Func, nil, nil);
  if rc = SQLITE_OK then
    rc := sqlite3_create_collation(db, 'rot13', SQLITE_UTF8, nil,
                                   @rot13CollFunc);
  Result := rc;
end;

end.
