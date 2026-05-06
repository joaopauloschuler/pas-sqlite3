{
  SPDX-License-Identifier: blessing

  Faithful port of ../sqlite3/ext/misc/nextchar.c (314 lines in C).

  Implements next_char(A, T, F [, W [, C]]) — given a prefix A, a
  table-and-column reference T.F (each a token possibly bracketed or a
  parenthesised subquery), an optional WHERE-clause fragment W, and an
  optional collation name C, return a string composed of every distinct
  next-character that, when appended to A, still occurs as a prefix of
  some row in T.F.

  Public entry: sqlite3NextcharInit(db).
}
{$I passqlite3.inc}
unit passqlite3nextchar;

interface

uses
  passqlite3types,
  passqlite3util,
  passqlite3vdbe,
  passqlite3main;

function sqlite3NextcharInit(db: PTsqlite3): i32;

implementation

uses
  passqlite3os,     { sqlite3_malloc64 / sqlite3_free }
  passqlite3printf; { sqlite3PfMprintf }

{ Local realloc — sqlite3_realloc64 is not exported in this build, so use
  GetMem/Move/FreeMem-style growth via sqlite3_malloc64 + memcpy.  The
  C source uses sqlite3_realloc64 but the resize semantics are only the
  growth direction. }
function nc_realloc(p: Pointer; oldBytes, newBytes: SizeUInt): Pointer;
var n: PtrUInt;
begin
  Result := sqlite3_malloc64(u64(newBytes));
  if (Result <> nil) and (p <> nil) and (oldBytes > 0) then
  begin
    n := oldBytes;
    if n > newBytes then n := newBytes;
    Move(p^, Result^, n);
  end;
  if p <> nil then sqlite3_free(p);
end;

type
  PNextCharContext = ^TNextCharContext;
  TNextCharContext = record
    db: PTsqlite3;
    pStmt: PVdbe;
    zPrefix: PByte;
    nPrefix: i32;
    nAlloc: i32;
    nUsed: i32;
    aResult: PCardinal;
    mallocFailed: i32;
    otherError: i32;
  end;

procedure nextCharAppend(p: PNextCharContext; c: Cardinal);
var
  i: i32;
  aNew: PCardinal;
  n: i32;
  oldBytes: SizeUInt;
begin
  for i := 0 to p^.nUsed - 1 do
    if PCardinal(PtrUInt(p^.aResult) + PtrUInt(i) * SizeOf(Cardinal))^ = c then
      Exit;
  if p^.nUsed + 1 > p^.nAlloc then
  begin
    n := p^.nAlloc * 2 + 30;
    oldBytes := SizeUInt(p^.nAlloc) * SizeOf(Cardinal);
    aNew := PCardinal(nc_realloc(p^.aResult, oldBytes,
                                 SizeUInt(n) * SizeOf(Cardinal)));
    if aNew = nil then
    begin
      p^.mallocFailed := 1;
      Exit;
    end;
    p^.aResult := aNew;
    p^.nAlloc := n;
  end;
  PCardinal(PtrUInt(p^.aResult) + PtrUInt(p^.nUsed) * SizeOf(Cardinal))^ := c;
  Inc(p^.nUsed);
end;

{ Encode a code point as UTF-8.  Returns the byte count. }
function writeUtf8(z: PByte; c: Cardinal): i32;
begin
  if c < $80 then
  begin
    z[0] := Byte(c and $FF);
    Result := 1; Exit;
  end;
  if c < $800 then
  begin
    z[0] := $C0 + Byte((c shr 6) and $1F);
    z[1] := $80 + Byte(c and $3F);
    Result := 2; Exit;
  end;
  if c < $10000 then
  begin
    z[0] := $E0 + Byte((c shr 12) and $0F);
    z[1] := $80 + Byte((c shr 6) and $3F);
    z[2] := $80 + Byte(c and $3F);
    Result := 3; Exit;
  end;
  z[0] := $F0 + Byte((c shr 18) and $07);
  z[1] := $80 + Byte((c shr 12) and $3F);
  z[2] := $80 + Byte((c shr 6) and $3F);
  z[3] := $80 + Byte(c and $3F);
  Result := 4;
end;

const
  validBits: array[0..63] of Byte = (
    $00, $01, $02, $03, $04, $05, $06, $07,
    $08, $09, $0a, $0b, $0c, $0d, $0e, $0f,
    $10, $11, $12, $13, $14, $15, $16, $17,
    $18, $19, $1a, $1b, $1c, $1d, $1e, $1f,
    $00, $01, $02, $03, $04, $05, $06, $07,
    $08, $09, $0a, $0b, $0c, $0d, $0e, $0f,
    $00, $01, $02, $03, $04, $05, $06, $07,
    $00, $01, $02, $03, $00, $01, $00, $00
  );

function readUtf8(z: PByte; out cOut: Cardinal): i32;
var
  c: Cardinal;
  n: i32;
begin
  c := z[0];
  if c < $C0 then
  begin
    cOut := c;
    Result := 1;
    Exit;
  end;
  n := 1;
  c := validBits[c - $C0];
  while (z[n] and $C0) = $80 do
  begin
    c := (c shl 6) + ($3F and z[n]);
    Inc(n);
  end;
  if (c < $80) or ((c and $FFFFF800) = $D800) or
     ((c and $FFFFFFFE) = $FFFE) then
    c := $FFFD;
  cOut := c;
  Result := n;
end;

procedure findNextChars(p: PNextCharContext);
var
  cPrev: Cardinal;
  zPrev: array[0..7] of Byte;
  n, rc: i32;
  zOut: PByte;
  cNext: Cardinal;
begin
  cPrev := 0;
  while True do
  begin
    sqlite3_bind_text(p^.pStmt, 1, PAnsiChar(p^.zPrefix), p^.nPrefix,
                      SQLITE_STATIC);
    n := writeUtf8(@zPrev[0], cPrev + 1);
    sqlite3_bind_text(p^.pStmt, 2, PAnsiChar(@zPrev[0]), n, SQLITE_STATIC);
    rc := sqlite3_step(p^.pStmt);
    if rc = SQLITE_DONE then
    begin
      sqlite3_reset(p^.pStmt);
      Exit;
    end
    else if rc <> SQLITE_ROW then
    begin
      p^.otherError := rc;
      Exit;
    end
    else
    begin
      zOut := PByte(sqlite3_column_text(p^.pStmt, 0));
      n := readUtf8(zOut + p^.nPrefix, cNext);
      sqlite3_reset(p^.pStmt);
      nextCharAppend(p, cNext);
      cPrev := cNext;
      if p^.mallocFailed <> 0 then Exit;
    end;
  end;
end;

procedure nextCharFunc(pCtx: Psqlite3_context; argc: i32;
                       argv: PPMem); cdecl;
var
  c: TNextCharContext;
  zTable, zField, zWhere, zCollName: PAnsiChar;
  zWhereClause, zColl, zSql: PAnsiChar;
  whereOwned, collOwned: Boolean;
  rc, i, n: i32;
  pRes: PByte;
  errMsg: PAnsiChar;
begin
  FillChar(c, SizeOf(c), 0);
  c.db := sqlite3_context_db_handle(pCtx);
  c.zPrefix := PByte(sqlite3_value_text(argv[0]));
  c.nPrefix := sqlite3_value_bytes(argv[0]);
  zTable := PAnsiChar(sqlite3_value_text(argv[1]));
  zField := PAnsiChar(sqlite3_value_text(argv[2]));
  if (zTable = nil) or (zField = nil) or (c.zPrefix = nil) then Exit;

  zWhereClause := nil;
  whereOwned := False;
  if argc >= 4 then
  begin
    zWhere := PAnsiChar(sqlite3_value_text(argv[3]));
    if (zWhere <> nil) and (zWhere[0] <> #0) then
    begin
      zWhereClause := sqlite3PfMprintf('AND (%s)', [zWhere]);
      if zWhereClause = nil then
      begin
        sqlite3_result_error_nomem(pCtx);
        Exit;
      end;
      whereOwned := True;
    end;
  end;
  if zWhereClause = nil then zWhereClause := PAnsiChar('');

  zColl := nil;
  collOwned := False;
  if argc >= 5 then
  begin
    zCollName := PAnsiChar(sqlite3_value_text(argv[4]));
    if (zCollName <> nil) and (zCollName[0] <> #0) then
    begin
      zColl := sqlite3PfMprintf('collate "%w"', [zCollName]);
      if zColl = nil then
      begin
        sqlite3_result_error_nomem(pCtx);
        if whereOwned then sqlite3_free(zWhereClause);
        Exit;
      end;
      collOwned := True;
    end;
  end;
  if zColl = nil then zColl := PAnsiChar('');

  zSql := sqlite3PfMprintf(
    'SELECT %s FROM %s' +
    ' WHERE %s>=(?1 || ?2) %s' +
    '   AND %s<=(?1 || char(1114111)) %s' +
    '   %s' +
    ' ORDER BY 1 %s ASC LIMIT 1',
    [zField, zTable, zField, zColl, zField, zColl, zWhereClause, zColl]);
  if whereOwned then sqlite3_free(zWhereClause);
  if collOwned then sqlite3_free(zColl);
  if zSql = nil then
  begin
    sqlite3_result_error_nomem(pCtx);
    Exit;
  end;

  rc := sqlite3_prepare_v2(c.db, zSql, -1, @c.pStmt, nil);
  sqlite3_free(zSql);
  if rc <> 0 then
  begin
    errMsg := sqlite3_errmsg(c.db);
    sqlite3_result_error(pCtx, errMsg, -1);
    Exit;
  end;
  findNextChars(@c);
  if c.mallocFailed <> 0 then
    sqlite3_result_error_nomem(pCtx)
  else
  begin
    pRes := PByte(sqlite3_malloc64(u64(c.nUsed) * 4 + 1));
    if pRes = nil then
      sqlite3_result_error_nomem(pCtx)
    else
    begin
      n := 0;
      for i := 0 to c.nUsed - 1 do
        Inc(n, writeUtf8(pRes + n,
          PCardinal(PtrUInt(c.aResult) + PtrUInt(i) * SizeOf(Cardinal))^));
      pRes[n] := 0;
      sqlite3_result_text(pCtx, PAnsiChar(pRes), n, SQLITE_TRANSIENT);
      sqlite3_free(pRes);
    end;
  end;
  sqlite3_finalize(c.pStmt);
  if c.aResult <> nil then sqlite3_free(c.aResult);
end;

function sqlite3NextcharInit(db: PTsqlite3): i32;
const
  Flags = SQLITE_UTF8 or SQLITE_INNOCUOUS;
var rc: i32;
begin
  rc := sqlite3_create_function(db, 'next_char', 3, Flags, nil,
                                @nextCharFunc, nil, nil);
  if rc = SQLITE_OK then
    rc := sqlite3_create_function(db, 'next_char', 4, Flags, nil,
                                  @nextCharFunc, nil, nil);
  if rc = SQLITE_OK then
    rc := sqlite3_create_function(db, 'next_char', 5, Flags, nil,
                                  @nextCharFunc, nil, nil);
  Result := rc;
end;

end.
