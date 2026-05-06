{
  SPDX-License-Identifier: blessing

  Faithful port of ../sqlite3/ext/misc/uint.c (92 lines in C).

  UINT collation: lexicographic byte order, except embedded runs of
  ASCII digits compare in numeric order with leading zeros ignored.

  Public entry: sqlite3UintInit(db) — equivalent to sqlite3_uint_init()
  in C; safe to call multiple times.
}
{$I passqlite3.inc}
unit passqlite3uint;

interface

uses
  passqlite3types,
  passqlite3util,
  passqlite3main;

function sqlite3UintInit(db: PTsqlite3): i32;

implementation

function isDigit(b: Byte): Boolean; inline;
begin
  Result := (b >= Ord('0')) and (b <= Ord('9'));
end;

{ uintCollFunc (uint.c:40..79).  Direct line-by-line port. }
function uintCollFunc(notUsed: Pointer;
  nKey1: i32; pKey1: Pointer;
  nKey2: i32; pKey2: Pointer): i32; cdecl;
var
  zA, zB: PByte;
  i, j, x, k, m: i32;
begin
  zA := PByte(pKey1);
  zB := PByte(pKey2);
  i := 0;
  j := 0;
  while (i < nKey1) and (j < nKey2) do
  begin
    x := i32(zA[i]) - i32(zB[j]);
    if isDigit(zA[i]) then
    begin
      if not isDigit(zB[j]) then
      begin
        Result := x;
        Exit;
      end;
      while (i < nKey1) and (zA[i] = Ord('0')) do Inc(i);
      while (j < nKey2) and (zB[j] = Ord('0')) do Inc(j);
      k := 0;
      while (i + k < nKey1) and isDigit(zA[i + k])
        and (j + k < nKey2) and isDigit(zB[j + k]) do
        Inc(k);
      if (i + k < nKey1) and isDigit(zA[i + k]) then
      begin
        Result := 1;
        Exit;
      end
      else if (j + k < nKey2) and isDigit(zB[j + k]) then
      begin
        Result := -1;
        Exit;
      end
      else
      begin
        x := 0;
        for m := 0 to k - 1 do
        begin
          if zA[i + m] <> zB[j + m] then
          begin
            x := i32(zA[i + m]) - i32(zB[j + m]);
            Break;
          end;
        end;
        if x <> 0 then
        begin
          Result := x;
          Exit;
        end;
        Inc(i, k);
        Inc(j, k);
      end;
    end
    else if x <> 0 then
    begin
      Result := x;
      Exit;
    end
    else
    begin
      Inc(i);
      Inc(j);
    end;
  end;
  Result := (nKey1 - i) - (nKey2 - j);
end;

function sqlite3UintInit(db: PTsqlite3): i32;
begin
  Result := sqlite3_create_collation(db, 'uint', SQLITE_UTF8, nil,
                                     @uintCollFunc);
end;

end.
