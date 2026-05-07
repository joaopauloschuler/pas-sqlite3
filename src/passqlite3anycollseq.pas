{
  SPDX-License-Identifier: blessing

  Faithful port of ../sqlite3/ext/misc/anycollseq.c (58 lines in C).

  Registers a sqlite3_collation_needed() callback that auto-creates a
  BINARY-equivalent collation for any unknown collation name.  Useful
  for loading schemas that reference user-defined collations that the
  current connection has not registered.

  Public entry: sqlite3AnycollseqInit(db).
}
{$I passqlite3.inc}
unit passqlite3anycollseq;

interface

uses
  passqlite3types,
  passqlite3util,
  passqlite3main;

function sqlite3AnycollseqInit(db: PTsqlite3): i32;

implementation

function anyCollFunc(NotUsed: Pointer;
                     nKey1: i32; pKey1: Pointer;
                     nKey2: i32; pKey2: Pointer): i32; cdecl;
var
  rc, n: i32;
  a, b: PByte;
  i: i32;
begin
  if nKey1 < nKey2 then n := nKey1 else n := nKey2;
  rc := 0;
  a := PByte(pKey1);
  b := PByte(pKey2);
  for i := 0 to n - 1 do
  begin
    if a[i] <> b[i] then
    begin
      if a[i] < b[i] then rc := -1 else rc := 1;
      Break;
    end;
  end;
  if rc = 0 then rc := nKey1 - nKey2;
  Result := rc;
end;

procedure anyCollNeeded(NotUsed: Pointer; db: PTsqlite3; eTextRep: i32;
                        zCollName: PAnsiChar); cdecl;
begin
  sqlite3_create_collation(db, zCollName, eTextRep, nil, @anyCollFunc);
end;

function sqlite3AnycollseqInit(db: PTsqlite3): i32;
begin
  Result := sqlite3_collation_needed(db, nil, @anyCollNeeded);
end;

end.
