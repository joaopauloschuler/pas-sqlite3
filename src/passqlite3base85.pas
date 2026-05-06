{
  SPDX-License-Identifier: blessing

  Faithful port of ../sqlite3/ext/misc/base85.c (454 lines in C).

  Implements the SQL function base85(X): encodes a BLOB to base85 text
  with B85_DARK_MAX (80-char) line breaks, or decodes base85 text back
  to a BLOB.  Also implements is_base85(t) which returns 1 iff t
  contains only base85 numerals or whitespace.

  Public entry: sqlite3Base85Init(db) — equivalent to
  sqlite3_base85_init() in C; safe to call multiple times.
}
{$I passqlite3.inc}
unit passqlite3base85;

interface

uses
  passqlite3types,
  passqlite3util,
  passqlite3vdbe,
  passqlite3main;

function sqlite3Base85Init(db: PTsqlite3): i32;

implementation

uses
  passqlite3os;

const
  B85_DARK_MAX = 80;
  LIMIT_LENGTH_ID = 0;

  b85_cOffset: array[0..4] of Byte = (0, Ord('#'), 0, Ord('*') - 4, 0);
  b85SepNL: array[0..1] of AnsiChar = (#10, #0);

procedure base85FreeDel(p: Pointer); cdecl;
begin
  sqlite3_free(p);
end;

{ B85_CLASS(c) — see base85.c:122. Values 1 and 3 are base85 numerals. }
function b85Class(c: Byte): Byte; inline;
var r: Byte;
begin
  r := 0;
  if c >= Ord('#') then Inc(r);
  if c >  Ord('&') then Inc(r);
  if c >= Ord('*') then Inc(r);
  if c >  Ord('z') then Inc(r);
  Result := r;
end;

function isB85(c: Byte): Boolean; inline;
begin
  Result := (b85Class(c) and 1) <> 0;
end;

function b85Dnos(c: Byte): Byte; inline;
begin
  Result := b85_cOffset[b85Class(c)];
end;

function base85Numeral(b: Byte): AnsiChar; inline;
begin
  if b < 4 then Result := AnsiChar(b + Ord('#'))
  else Result := AnsiChar(b - 4 + Ord('*'));
end;

function skipNonB85(s: PAnsiChar; nc: i32): PAnsiChar;
var c: AnsiChar;
begin
  while nc > 0 do
  begin
    c := s^;
    if c = #0 then Break;
    if isB85(Byte(c)) then Break;
    Inc(s);
    Dec(nc);
  end;
  Result := s;
end;

function putcs(pc: PAnsiChar; s: PAnsiChar): PAnsiChar;
var c: AnsiChar;
begin
  c := s^;
  while c <> #0 do
  begin
    pc^ := c;
    Inc(pc);
    Inc(s);
    c := s^;
  end;
  Result := pc;
end;

{ toBase85 — base85.c:170..208.  Encodes pIn[0..nbIn) into pOut.
  If pSep<>nil, appends pSep after every B85_DARK_MAX-aligned group and
  after the last group (used to splice newlines into long encodings). }
function toBase85(pIn: PByte; nbIn: i32; pOut: PAnsiChar; pSep: PAnsiChar): PAnsiChar;
var
  nCol, nco, nbe: i32;
  qbv, nqv: u64;
  dv: Byte;
begin
  nCol := 0;
  while nbIn >= 4 do
  begin
    nco := 5;
    qbv := (u64(pIn[0]) shl 24) or (u64(pIn[1]) shl 16) or
           (u64(pIn[2]) shl 8) or u64(pIn[3]);
    while nco > 0 do
    begin
      nqv := qbv div 85;
      dv := Byte(qbv - 85 * nqv);
      qbv := nqv;
      Dec(nco);
      pOut[nco] := base85Numeral(dv);
    end;
    Dec(nbIn, 4);
    Inc(pIn, 4);
    Inc(pOut, 5);
    if pSep <> nil then
    begin
      Inc(nCol, 5);
      if nCol >= B85_DARK_MAX then
      begin
        pOut := putcs(pOut, pSep);
        nCol := 0;
      end;
    end;
  end;
  if nbIn > 0 then
  begin
    nco := nbIn + 1;
    qbv := pIn^;
    Inc(pIn);
    nbe := 1;
    while nbe < nbIn do
    begin
      qbv := (qbv shl 8) or pIn^;
      Inc(pIn);
      Inc(nbe);
    end;
    Inc(nCol, nco);
    while nco > 0 do
    begin
      dv := Byte(qbv mod 85);
      qbv := qbv div 85;
      Dec(nco);
      pOut[nco] := base85Numeral(dv);
    end;
    Inc(pOut, nbIn + 1);
  end;
  if (pSep <> nil) and (nCol > 0) then
    pOut := putcs(pOut, pSep);
  pOut^ := #0;
  Result := pOut;
end;

{ fromBase85 — base85.c:211..250. }
function fromBase85(pIn: PAnsiChar; ncIn: i32; pOut: PByte): PByte;
const
  nboi: array[0..5] of Shortint = (0, 0, 1, 2, 3, 4);
var
  pUse: PAnsiChar;
  qv: u64;
  nti, nbo: i32;
  c: AnsiChar;
  cdo: Byte;
begin
  if (ncIn > 0) and (pIn[ncIn - 1] = #10) then Dec(ncIn);
  while ncIn > 0 do
  begin
    pUse := skipNonB85(pIn, ncIn);
    qv := 0;
    Dec(ncIn, pUse - pIn);
    pIn := pUse;
    if ncIn > 5 then nti := 5 else nti := ncIn;
    nbo := nboi[nti];
    if nbo = 0 then Break;
    while nti > 0 do
    begin
      c := pIn^;
      Inc(pIn);
      cdo := b85Dnos(Byte(c));
      Dec(ncIn);
      if cdo = 0 then Break;
      qv := 85 * qv + (Byte(c) - cdo);
      Dec(nti);
    end;
    Dec(nbo, nti);
    case nbo of
      4:
        begin
          pOut[0] := Byte((qv shr 24) and $FF);
          pOut[1] := Byte((qv shr 16) and $FF);
          pOut[2] := Byte((qv shr 8) and $FF);
          pOut[3] := Byte(qv and $FF);
        end;
      3:
        begin
          pOut[0] := Byte((qv shr 16) and $FF);
          pOut[1] := Byte((qv shr 8) and $FF);
          pOut[2] := Byte(qv and $FF);
        end;
      2:
        begin
          pOut[0] := Byte((qv shr 8) and $FF);
          pOut[1] := Byte(qv and $FF);
        end;
      1:
        begin
          pOut[0] := Byte(qv and $FF);
        end;
    end;
    if nbo > 0 then Inc(pOut, nbo);
  end;
  Result := pOut;
end;

function isSpaceByte(c: Byte): Boolean; inline;
begin
  { Mirrors C isspace(): space, \t, \n, \v, \f, \r. }
  Result := (c = $20) or ((c >= 9) and (c <= 13));
end;

function allBase85(p: PAnsiChar; len: i32): i32;
var c: AnsiChar;
begin
  while len > 0 do
  begin
    c := p^;
    if c = #0 then Break;
    if (not isB85(Byte(c))) and (not isSpaceByte(Byte(c))) then
    begin
      Result := 0;
      Exit;
    end;
    Inc(p);
    Dec(len);
  end;
  Result := 1;
end;

procedure isBase85Func(pCtx: Psqlite3_context; na: i32; av: PPMem); cdecl;
var rv: i32;
begin
  case sqlite3_value_type(av[0]) of
    SQLITE_TEXT:
      begin
        rv := allBase85(PAnsiChar(sqlite3_value_text(av[0])),
                        sqlite3_value_bytes(av[0]));
        sqlite3_result_int(pCtx, rv);
      end;
    SQLITE_NULL:
      sqlite3_result_null(pCtx);
  else
    sqlite3_result_error(pCtx, 'is_base85 accepts only text or NULL', -1);
  end;
end;

procedure base85Func(pCtx: Psqlite3_context; na: i32; av: PPMem); cdecl;
label memFail;
var
  nb, nc, nv: i64;
  nvMax: i32;
  cBuf: PAnsiChar;
  bBuf: PByte;
  db: PTsqlite3;
  pTail: PAnsiChar;
begin
  nv := sqlite3_value_bytes(av[0]);
  db := sqlite3_context_db_handle(pCtx);
  nvMax := sqlite3_limit(db, LIMIT_LENGTH_ID, -1);
  case sqlite3_value_type(av[0]) of
    SQLITE_BLOB:
      begin
        nb := nv;
        { ulongs    tail   newlines  tailenc+nul }
        nc := 5 * (nv div 4) + (nv mod 4) + (nv div 64) + 1 + 2;
        if nvMax < nc then
        begin
          sqlite3_result_error(pCtx, 'blob expanded to base85 too big', -1);
          Exit;
        end;
        bBuf := PByte(sqlite3_value_blob(av[0]));
        if bBuf = nil then
        begin
          if sqlite3_errcode(db) = SQLITE_NOMEM then goto memFail;
          sqlite3_result_text(pCtx, '', -1, SQLITE_STATIC);
          Exit;
        end;
        cBuf := PAnsiChar(sqlite3_malloc64(u64(nc)));
        if cBuf = nil then goto memFail;
        pTail := toBase85(bBuf, nb, cBuf, @b85SepNL[0]);
        nc := pTail - cBuf;
        sqlite3_result_text(pCtx, cBuf, i32(nc), @base85FreeDel);
      end;
    SQLITE_TEXT:
      begin
        nc := nv;
        nb := 4 * (nv div 5) + (nv mod 5);
        if nvMax < nb then
        begin
          sqlite3_result_error(pCtx, 'blob from base85 may be too big', -1);
          Exit;
        end
        else if nb < 1 then
          nb := 1;
        cBuf := PAnsiChar(sqlite3_value_text(av[0]));
        if cBuf = nil then
        begin
          if sqlite3_errcode(db) = SQLITE_NOMEM then goto memFail;
          sqlite3_result_zeroblob(pCtx, 0);
          Exit;
        end;
        bBuf := PByte(sqlite3_malloc64(u64(nb)));
        if bBuf = nil then goto memFail;
        nb := i64(fromBase85(cBuf, nc, bBuf) - bBuf);
        sqlite3_result_blob(pCtx, bBuf, i32(nb), @base85FreeDel);
      end;
  else
    sqlite3_result_error(pCtx, 'base85 accepts only blob or text.', -1);
    Exit;
  end;
  Exit;
memFail:
  sqlite3_result_error(pCtx, 'base85 OOM', -1);
end;

function sqlite3Base85Init(db: PTsqlite3): i32;
var rc: i32;
begin
  rc := sqlite3_create_function(db, 'is_base85', 1,
          SQLITE_DETERMINISTIC or SQLITE_INNOCUOUS or SQLITE_UTF8,
          nil, @isBase85Func, nil, nil);
  if rc <> SQLITE_OK then begin Result := rc; Exit; end;
  Result := sqlite3_create_function(db, 'base85', 1,
          SQLITE_DETERMINISTIC or SQLITE_INNOCUOUS or
          SQLITE_DIRECTONLY or SQLITE_UTF8,
          nil, @base85Func, nil, nil);
end;

end.
