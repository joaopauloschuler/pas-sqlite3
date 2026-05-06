{
  SPDX-License-Identifier: blessing

  Faithful port of ../sqlite3/ext/misc/uuid.c (234 lines in C).

  Implements the SQL functions uuid(), uuid_str(X), and uuid_blob(X)
  per RFC-4122.  Helpers (HexToInt, BlobToStr, StrToBlob, InputToBlob)
  mirror the C source 1:1.

  Public entry: sqlite3UuidInit(db) — equivalent to sqlite3_uuid_init()
  in C; safe to call multiple times.
}
{$I passqlite3.inc}
unit passqlite3uuid;

interface

uses
  passqlite3types,
  passqlite3util,
  passqlite3vdbe,
  passqlite3main;

function sqlite3UuidInit(db: PTsqlite3): i32;

implementation

uses
  SysUtils;

{ Hex character (0-9 / a-f / A-F) → integer 0..15.  ASCII-only branch of
  sqlite3UuidHexToInt (uuid.c:76..85).  The arithmetic `h += 9*(1&(h>>6))`
  exploits the fact that ASCII digits have bit 6 clear ('0'=$30) while
  letters have bit 6 set ('a'=$61, 'A'=$41); shifting bit 6 down to bit 0
  yields 0 for digits, 1 for letters, so adding 9 maps 'a'..'f' (low
  nibble 1..6) to 10..15. }
function uuidHexToInt(h: i32): Byte; inline;
begin
  h := h + 9 * (1 and (h shr 6));
  Result := Byte(h and $F);
end;

function isHexDigit(c: AnsiChar): Boolean; inline;
begin
  Result := (c in ['0'..'9', 'a'..'f', 'A'..'F']);
end;

{ Convert a 16-byte BLOB into a 36-char canonical UUID (with NUL).
  zStr must be at least 37 bytes.  Mirrors sqlite3UuidBlobToStr
  (uuid.c:92..111).  The bitmask `k=0x550` (binary 0101_0101_0000)
  encodes which inter-byte gaps get a '-' separator: positions
  4, 6, 8, 10 (0-indexed bytes-emitted boundaries) — i.e. between
  bytes 4/5, 6/7, 8/9, 10/11.  k is right-shifted each iteration. }
procedure uuidBlobToStr(aBlob: PByte; zStr: PAnsiChar);
const
  zDigits: array[0..15] of AnsiChar = '0123456789abcdef';
var
  i, k: i32;
  x: Byte;
begin
  k := $550;
  for i := 0 to 15 do
  begin
    if (k and 1) <> 0 then
    begin
      zStr^ := '-';
      Inc(zStr);
    end;
    x := aBlob[i];
    zStr[0] := zDigits[(x shr 4) and $F];
    zStr[1] := zDigits[x and $F];
    Inc(zStr, 2);
    k := k shr 1;
  end;
  zStr^ := #0;
end;

{ Parse a (possibly braced, hyphen-decorated) UUID string into 16 bytes.
  Returns 0 on success, non-zero on failure.  Mirrors
  sqlite3UuidStrToBlob (uuid.c:118..136).  Hyphens are accepted at any
  inter-byte boundary, not just RFC-canonical positions, matching the
  liberal PostgreSQL-style input behaviour documented in the C source. }
function uuidStrToBlob(zStr: PAnsiChar; aBlob: PByte): i32;
var
  i: i32;
begin
  if zStr^ = '{' then Inc(zStr);
  for i := 0 to 15 do
  begin
    if zStr^ = '-' then Inc(zStr);
    if isHexDigit(zStr[0]) and isHexDigit(zStr[1]) then
    begin
      aBlob[i] := (uuidHexToInt(Ord(zStr[0])) shl 4)
                + uuidHexToInt(Ord(zStr[1]));
      Inc(zStr, 2);
    end
    else
    begin
      Result := 1;
      Exit;
    end;
  end;
  if zStr^ = '}' then Inc(zStr);
  if zStr^ <> #0 then Result := 1 else Result := 0;
end;

{ Render a value as a 16-byte UUID blob.  Returns nil on bad input.
  Mirrors sqlite3UuidInputToBlob (uuid.c:142..160). }
function uuidInputToBlob(pIn: Psqlite3_value; pBuf: PByte): PByte;
var
  z: PAnsiChar;
  n: i32;
begin
  case sqlite3_value_type(pIn) of
    SQLITE_TEXT:
      begin
        z := PAnsiChar(sqlite3_value_text(pIn));
        if (z = nil) or (uuidStrToBlob(z, pBuf) <> 0) then
          Result := nil
        else
          Result := pBuf;
      end;
    SQLITE_BLOB:
      begin
        n := sqlite3_value_bytes(pIn);
        if n = 16 then
          Result := PByte(sqlite3_value_blob(pIn))
        else
          Result := nil;
      end;
  else
    Result := nil;
  end;
end;

{ uuid() — generate v4 UUID.  Mirrors sqlite3UuidFunc (uuid.c:163..177). }
procedure uuidFunc(pCtx: Psqlite3_context; argc: i32; argv: PPMem); cdecl;
var
  aBlob: array[0..15] of Byte;
  zStr: array[0..36] of AnsiChar;
begin
  sqlite3_randomness(16, @aBlob[0]);
  { Set version (high nibble of byte 6) to 4 and variant (high two bits
    of byte 8) to 10b — i.e. RFC-4122 variant 1, version 4 random. }
  aBlob[6] := (aBlob[6] and $0F) + $40;
  aBlob[8] := (aBlob[8] and $3F) + $80;
  uuidBlobToStr(@aBlob[0], @zStr[0]);
  sqlite3_result_text(pCtx, PAnsiChar(@zStr[0]), 36, SQLITE_TRANSIENT);
end;

{ uuid_str(X) — canonicalise.  Mirrors sqlite3UuidStrFunc (uuid.c:180..193). }
procedure uuidStrFunc(pCtx: Psqlite3_context; argc: i32; argv: PPMem); cdecl;
var
  aBlob: array[0..15] of Byte;
  zStr: array[0..36] of AnsiChar;
  pBlob: PByte;
begin
  pBlob := uuidInputToBlob(argv[0], @aBlob[0]);
  if pBlob = nil then Exit;
  uuidBlobToStr(pBlob, @zStr[0]);
  sqlite3_result_text(pCtx, PAnsiChar(@zStr[0]), 36, SQLITE_TRANSIENT);
end;

{ uuid_blob(X) — emit as 16-byte BLOB.  Mirrors sqlite3UuidBlobFunc
  (uuid.c:196..207). }
procedure uuidBlobFunc(pCtx: Psqlite3_context; argc: i32; argv: PPMem); cdecl;
var
  aBlob: array[0..15] of Byte;
  pBlob: PByte;
begin
  pBlob := uuidInputToBlob(argv[0], @aBlob[0]);
  if pBlob = nil then Exit;
  sqlite3_result_blob(pCtx, pBlob, 16, SQLITE_TRANSIENT);
end;

function sqlite3UuidInit(db: PTsqlite3): i32;
const
  GFlags = SQLITE_UTF8 or SQLITE_INNOCUOUS;
  FFlags = SQLITE_UTF8 or SQLITE_INNOCUOUS or SQLITE_DETERMINISTIC;
var
  rc: i32;
begin
  rc := sqlite3_create_function(db, 'uuid', 0, GFlags, nil,
                                @uuidFunc, nil, nil);
  if rc = SQLITE_OK then
    rc := sqlite3_create_function(db, 'uuid_str', 1, FFlags, nil,
                                  @uuidStrFunc, nil, nil);
  if rc = SQLITE_OK then
    rc := sqlite3_create_function(db, 'uuid_blob', 1, FFlags, nil,
                                  @uuidBlobFunc, nil, nil);
  Result := rc;
end;

end.
