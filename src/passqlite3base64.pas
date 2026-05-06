{
  SPDX-License-Identifier: blessing

  Faithful port of ../sqlite3/ext/misc/base64.c (297 lines in C, RFC 4648).

  Implements the SQL function base64(X): encodes a BLOB to base64 text
  with B64_DARK_MAX (72-char) line breaks, or decodes base64 text back
  to a BLOB.  Whitespace is tolerated; non-base64 dark bytes terminate
  decoding.  Other input affinity types raise an error.

  Public entry: sqlite3Base64Init(db) — equivalent to
  sqlite3_base64_init() in C; safe to call multiple times.
}
{$I passqlite3.inc}
unit passqlite3base64;

interface

uses
  passqlite3types,
  passqlite3util,
  passqlite3vdbe,
  passqlite3main;

function sqlite3Base64Init(db: PTsqlite3): i32;

implementation

uses
  passqlite3os;

{ cdecl trampoline so the destructor pointer matches TxDelProc.  Direct
  `@base64FreeDel` is rejected because `external 'c'` propagates as
  `register` calling convention through @-of in FPC. }
procedure base64FreeDel(p: Pointer); cdecl;
begin
  sqlite3_free(p);
end;

const
  PC_         = $80;          { pad character marker }
  WS_         = $81;          { whitespace marker }
  ND_         = $82;          { non-digit / not above }
  PAD_CHAR    = AnsiChar('=');
  B64_DARK_MAX = 72;
  { SQLITE_LIMIT_LENGTH = 0 (sqliteInt.h); inlined here to avoid pulling
    passqlite3codegen as a dependency. }
  LIMIT_LENGTH_ID = 0;

  b64DigitValues: array[0..127] of Byte = (
    ND_,ND_,ND_,ND_, ND_,ND_,ND_,ND_, ND_,WS_,WS_,WS_, WS_,WS_,ND_,ND_,
    ND_,ND_,ND_,ND_, ND_,ND_,ND_,ND_, ND_,ND_,ND_,ND_, ND_,ND_,ND_,ND_,
    WS_,ND_,ND_,ND_, ND_,ND_,ND_,ND_, ND_,ND_,ND_,62,  ND_,ND_,ND_,63,
    52,53,54,55,     56,57,58,59,     60,61,ND_,ND_,   ND_,PC_,ND_,ND_,
    ND_, 0, 1, 2,     3, 4, 5, 6,      7, 8, 9,10,     11,12,13,14,
    15,16,17,18,     19,20,21,22,     23,24,25,ND_,   ND_,ND_,ND_,ND_,
    ND_,26,27,28,    29,30,31,32,     33,34,35,36,    37,38,39,40,
    41,42,43,44,     45,46,47,48,     49,50,51,ND_,   ND_,ND_,ND_,ND_
  );

  b64Numerals: array[0..63] of AnsiChar =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

{ Wrap of BX_DV_PROTO macro: dark bytes >=128 are encoded as PC_. }
function bxDvProto(c: Byte): Byte; inline;
begin
  if c < $80 then Result := b64DigitValues[c]
  else Result := $80;
end;

function isBxDigit(b: Byte): Boolean; inline;
begin
  Result := b < $80;
end;

{ toBase64 — encode pIn[0..nbIn) into pOut, returning the new tail
  pointer (just past the trailing NUL).  Mirrors base64.c:114..148. }
function toBase64(pIn: PByte; nbIn: i32; pOut: PAnsiChar): PAnsiChar;
var
  nCol, nbe: i32;
  qv: u64;
  nco: i32;
  ce: AnsiChar;
begin
  nCol := 0;
  while nbIn >= 3 do
  begin
    pOut[0] := b64Numerals[(pIn[0] shr 2) and $3F];
    pOut[1] := b64Numerals[((pIn[0] shl 4) or (pIn[1] shr 4)) and $3F];
    pOut[2] := b64Numerals[(((pIn[1] and $F) shl 2) or (pIn[2] shr 6)) and $3F];
    pOut[3] := b64Numerals[pIn[2] and $3F];
    Inc(pOut, 4);
    Dec(nbIn, 3);
    Inc(pIn, 3);
    Inc(nCol, 4);
    if (nCol >= B64_DARK_MAX) or (nbIn <= 0) then
    begin
      pOut^ := #10;
      Inc(pOut);
      nCol := 0;
    end;
  end;
  if nbIn > 0 then
  begin
    nco := nbIn + 1;
    qv := pIn^;
    Inc(pIn);
    nbe := 1;
    while nbe < 3 do
    begin
      qv := qv shl 8;
      if nbe < nbIn then
      begin
        qv := qv or pIn^;
        Inc(pIn);
      end;
      Inc(nbe);
    end;
    for nbe := 3 downto 0 do
    begin
      if nbe < nco then
        ce := b64Numerals[qv and $3F]
      else
        ce := PAD_CHAR;
      qv := qv shr 6;
      pOut[nbe] := ce;
    end;
    Inc(pOut, 4);
    pOut^ := #10;
    Inc(pOut);
  end;
  pOut^ := #0;
  Result := pOut;
end;

{ skipNonB64 — advance past characters that are not base64 numerals.
  Mirrors base64.c:151..155. }
function skipNonB64(s: PAnsiChar; nc: i32): PAnsiChar;
var
  c: AnsiChar;
begin
  while nc > 0 do
  begin
    c := s^;
    if c = #0 then Break;
    if isBxDigit(bxDvProto(Byte(c))) then Break;
    Inc(s);
    Dec(nc);
  end;
  Result := s;
end;

{ fromBase64 — decode pIn[0..ncIn) into pOut.  Returns the new pOut
  tail.  Mirrors base64.c:158..206. }
function fromBase64(pIn: PAnsiChar; ncIn: i32; pOut: PByte): PByte;
const
  nboi: array[0..4] of Shortint = (0, 0, 1, 2, 3);
var
  pUse: PAnsiChar;
  qv: u64;
  nti, nbo, nac: i32;
  c: AnsiChar;
  bdp: Byte;
begin
  if (ncIn > 0) and (pIn[ncIn - 1] = #10) then Dec(ncIn);
  while (ncIn > 0) and (pIn^ <> PAD_CHAR) do
  begin
    pUse := skipNonB64(pIn, ncIn);
    qv := 0;
    Dec(ncIn, pUse - pIn);
    pIn := pUse;
    if ncIn > 4 then nti := 4 else nti := ncIn;
    Dec(ncIn, nti);
    nbo := nboi[nti];
    if nbo = 0 then Break;
    nac := 0;
    while nac < 4 do
    begin
      if nac < nti then
      begin
        c := pIn^;
        Inc(pIn);
      end
      else
        c := b64Numerals[0];
      bdp := bxDvProto(Byte(c));
      case bdp of
        ND_:
          begin
            { dark non-digits act like pad and end the decode }
            ncIn := 0;
            nti := nac;
            bdp := 0;
            Dec(nbo);
          end;
        WS_:
          begin
            nti := nac;
            bdp := 0;
            Dec(nbo);
          end;
        PC_:
          begin
            bdp := 0;
            Dec(nbo);
          end;
      end;
      qv := (qv shl 6) or bdp;
      Inc(nac);
    end;
    case nbo of
      3:
        begin
          pOut[2] := Byte(qv and $FF);
          pOut[1] := Byte((qv shr 8) and $FF);
          pOut[0] := Byte((qv shr 16) and $FF);
        end;
      2:
        begin
          pOut[1] := Byte((qv shr 8) and $FF);
          pOut[0] := Byte((qv shr 16) and $FF);
        end;
      1:
        begin
          pOut[0] := Byte((qv shr 16) and $FF);
        end;
    end;
    if nbo > 0 then Inc(pOut, nbo);
  end;
  Result := pOut;
end;

{ base64(X) — SQL scalar (base64.c:209..269). }
procedure base64Func(pCtx: Psqlite3_context; argc: i32; argv: PPMem); cdecl;
label
  memFail;
var
  nb, nv, nc: i64;
  nvMax: i32;
  cBuf: PAnsiChar;
  bBuf: PByte;
  db: PTsqlite3;
begin
  nv := sqlite3_value_bytes(argv[0]);
  db := sqlite3_context_db_handle(pCtx);
  nvMax := sqlite3_limit(db, LIMIT_LENGTH_ID, -1);
  case sqlite3_value_type(argv[0]) of
    SQLITE_BLOB:
      begin
        nb := nv;
        nc := 4 * ((nv + 2) div 3);
        nc := nc + (nc + (B64_DARK_MAX - 1)) div B64_DARK_MAX + 1;
        if nvMax < nc then
        begin
          sqlite3_result_error(pCtx, 'blob expanded to base64 too big', -1);
          Exit;
        end;
        bBuf := PByte(sqlite3_value_blob(argv[0]));
        if bBuf = nil then
        begin
          if sqlite3_errcode(db) = SQLITE_NOMEM then goto memFail;
          sqlite3_result_text(pCtx, '', -1, SQLITE_STATIC);
          Exit;
        end;
        cBuf := PAnsiChar(sqlite3_malloc64(u64(nc)));
        if cBuf = nil then goto memFail;
        nc := i64(toBase64(bBuf, nb, cBuf) - cBuf);
        sqlite3_result_text(pCtx, cBuf, i32(nc), @base64FreeDel);
      end;
    SQLITE_TEXT:
      begin
        nc := nv;
        nb := 3 * ((nv + 3) div 4);
        if nvMax < nb then
        begin
          sqlite3_result_error(pCtx, 'blob from base64 may be too big', -1);
          Exit;
        end
        else if nb < 1 then
          nb := 1;
        cBuf := PAnsiChar(sqlite3_value_text(argv[0]));
        if cBuf = nil then
        begin
          if sqlite3_errcode(db) = SQLITE_NOMEM then goto memFail;
          sqlite3_result_zeroblob(pCtx, 0);
          Exit;
        end;
        bBuf := PByte(sqlite3_malloc64(u64(nb)));
        if bBuf = nil then goto memFail;
        nb := i64(fromBase64(cBuf, nc, bBuf) - bBuf);
        sqlite3_result_blob(pCtx, bBuf, i32(nb), @base64FreeDel);
      end;
  else
    sqlite3_result_error(pCtx, 'base64 accepts only blob or text', -1);
    Exit;
  end;
  Exit;
memFail:
  sqlite3_result_error(pCtx, 'base64 OOM', -1);
end;

function sqlite3Base64Init(db: PTsqlite3): i32;
const
  Flags = SQLITE_DETERMINISTIC or SQLITE_INNOCUOUS
       or SQLITE_DIRECTONLY or SQLITE_UTF8;
begin
  Result := sqlite3_create_function(db, 'base64', 1, Flags, nil,
                                    @base64Func, nil, nil);
end;

end.
