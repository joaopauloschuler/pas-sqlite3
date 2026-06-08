{
  SPDX-License-Identifier: blessing

  The author disclaims copyright to this source code.  In place of
  a legal notice, here is a blessing:

     May you do good and not evil.
     May you find forgiveness for yourself and forgive others.
     May you share freely, never taking more than you give.

  ------------------------------------------------------------------------

  This work is dedicated to all human kind, and also to all non-human kinds.

  This is a faithful port of SQLite 3.53 (https://sqlite.org/) from C to
  Free Pascal, authored by Dr. Joao Paulo Schwarz Schuler and contributors
  (see commit history).
}
{$I passqlite3.inc}

{
  Faithful port of ext/fts5/fts5_varint.c (FTS5 varint serialization).

  This is the first, dependency-free foundation layer of the FTS5 port
  (tasklist 9.4.divbug.68.a.1).  It depends on nothing else and is proven
  byte-for-byte identical to the C via src/tests/TestFts5Varint.pas.

  Exposes the four public entry points plus the static helper:
    sqlite3Fts5GetVarint32 (fts5_varint.c:24)
    sqlite3Fts5GetVarint   (fts5_varint.c:102)
    fts5PutVarint64        (fts5_varint.c:296, static)
    sqlite3Fts5PutVarint   (fts5_varint.c:321)
    sqlite3Fts5GetVarintLen(fts5_varint.c:335)

  32-bit intermediates use DWord with explicit truncation on shifts to
  reproduce the C 'u32' wraparound exactly.
}
unit passqlite3fts5varint;

interface

uses
  ctypes;

{ Read a 32-bit varint from p; store value in v^; return bytes consumed (1..9). }
function sqlite3Fts5GetVarint32(p: PByte; v: PCardinal): cint;

{ Read a 64-bit varint from p; store value in v^; return bytes consumed (1..9). }
function sqlite3Fts5GetVarint(p: PByte; v: PQWord): Byte;

{ Write 64-bit varint v to p (1..9 bytes); return bytes written. }
function sqlite3Fts5PutVarint(p: PByte; v: QWord): cint;

{ Number of bytes a 32-bit value (assumed >= 1<<7) would occupy as a varint. }
function sqlite3Fts5GetVarintLen(iVal: Cardinal): cint;

implementation

const
  SLOT_2_0   = DWord($001fc07f);  { (0x7f<<14) | 0x7f }
  SLOT_4_2_0 = DWord($f01fc07f);  { (0xf<<28) | SLOT_2_0 }

{ fts5_varint.c:102 — sqlite3Fts5GetVarint. }
function sqlite3Fts5GetVarint(p: PByte; v: PQWord): Byte;
var
  a, b, s: DWord;
begin
  a := p[0];
  if (a and $80) = 0 then begin v^ := a; Result := 1; Exit; end;

  b := p[1];
  if (b and $80) = 0 then begin
    a := a and $7f; a := DWord(a shl 7); a := a or b; v^ := a; Result := 2; Exit;
  end;

  a := DWord(a shl 14); a := a or p[2];
  if (a and $80) = 0 then begin
    a := a and SLOT_2_0; b := b and $7f; b := DWord(b shl 7); a := a or b;
    v^ := a; Result := 3; Exit;
  end;

  a := a and SLOT_2_0;
  b := DWord(b shl 14); b := b or p[3];
  if (b and $80) = 0 then begin
    b := b and SLOT_2_0; a := DWord(a shl 7); a := a or b; v^ := a; Result := 4; Exit;
  end;

  b := b and SLOT_2_0;
  s := a;
  a := DWord(a shl 14); a := a or p[4];
  if (a and $80) = 0 then begin
    b := DWord(b shl 7); a := a or b; s := s shr 18;
    v^ := (QWord(s) shl 32) or a; Result := 5; Exit;
  end;

  s := DWord(s shl 7); s := s or b;
  b := DWord(b shl 14); b := b or p[5];
  if (b and $80) = 0 then begin
    a := a and SLOT_2_0; a := DWord(a shl 7); a := a or b; s := s shr 18;
    v^ := (QWord(s) shl 32) or a; Result := 6; Exit;
  end;

  a := DWord(a shl 14); a := a or p[6];
  if (a and $80) = 0 then begin
    a := a and SLOT_4_2_0; b := b and SLOT_2_0; b := DWord(b shl 7); a := a or b;
    s := s shr 11; v^ := (QWord(s) shl 32) or a; Result := 7; Exit;
  end;

  a := a and SLOT_2_0;
  b := DWord(b shl 14); b := b or p[7];
  if (b and $80) = 0 then begin
    b := b and SLOT_4_2_0; a := DWord(a shl 7); a := a or b; s := s shr 4;
    v^ := (QWord(s) shl 32) or a; Result := 8; Exit;
  end;

  a := DWord(a shl 15); a := a or p[8];
  b := b and SLOT_2_0; b := DWord(b shl 8); a := a or b;
  s := DWord(s shl 4);
  b := p[4];              { C: b = p[-4] after the final p++ leaves p at offset 8 }
  b := b and $7f; b := b shr 3; s := s or b;
  v^ := (QWord(s) shl 32) or a;
  Result := 9;
end;

{ fts5_varint.c:24 — sqlite3Fts5GetVarint32. }
function sqlite3Fts5GetVarint32(p: PByte; v: PCardinal): cint;
var
  a, b: DWord;
  v64: QWord;
  n: Byte;
begin
  a := p[0];
  if (a and $80) = 0 then begin v^ := a; Result := 1; Exit; end;

  b := p[1];
  if (b and $80) = 0 then begin
    a := a and $7f; a := DWord(a shl 7); v^ := a or b; Result := 2; Exit;
  end;

  a := DWord(a shl 14); a := a or p[2];
  if (a and $80) = 0 then begin
    a := a and DWord((($7f shl 14) or $7f));
    b := b and $7f; b := DWord(b shl 7); v^ := a or b; Result := 3; Exit;
  end;

  { Rare 4..9 byte case: delegate to the 64-bit reader starting at p[0]
    (C does p -= 2 from the +2 position). }
  n := sqlite3Fts5GetVarint(p, @v64);
  v^ := Cardinal(v64) and $7FFFFFFF;
  Result := n;
end;

{ fts5_varint.c:296 — fts5PutVarint64 (static helper). }
function fts5PutVarint64(p: PByte; v: QWord): cint;
var
  i, j, n: cint;
  buf: array[0..9] of Byte;
begin
  if (v and (QWord($ff000000) shl 32)) <> 0 then begin
    p[8] := Byte(v); v := v shr 8;
    for i := 7 downto 0 do begin
      p[i] := Byte((v and $7f) or $80); v := v shr 7;
    end;
    Result := 9; Exit;
  end;
  n := 0;
  repeat
    buf[n] := Byte((v and $7f) or $80); Inc(n); v := v shr 7;
  until v = 0;
  buf[0] := buf[0] and $7f;
  i := 0; j := n - 1;
  while j >= 0 do begin
    p[i] := buf[j]; Dec(j); Inc(i);
  end;
  Result := n;
end;

{ fts5_varint.c:321 — sqlite3Fts5PutVarint. }
function sqlite3Fts5PutVarint(p: PByte; v: QWord): cint;
begin
  if v <= $7f then begin
    p[0] := Byte(v and $7f); Result := 1; Exit;
  end;
  if v <= $3fff then begin
    p[0] := Byte(((v shr 7) and $7f) or $80);
    p[1] := Byte(v and $7f);
    Result := 2; Exit;
  end;
  Result := fts5PutVarint64(p, v);
end;

{ fts5_varint.c:335 — sqlite3Fts5GetVarintLen. }
function sqlite3Fts5GetVarintLen(iVal: Cardinal): cint;
begin
  if iVal < (1 shl 14) then Result := 2
  else if iVal < (1 shl 21) then Result := 3
  else if iVal < (1 shl 28) then Result := 4
  else Result := 5;
end;

end.
