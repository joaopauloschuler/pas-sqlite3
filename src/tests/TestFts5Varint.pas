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
{$I ../passqlite3.inc}
program TestFts5Varint;

{
  Phase 9.4.divbug.68.a.1 gate — ext/fts5/fts5_varint.c port
  (passqlite3fts5varint).

  Self-contained, no oracle/db needed.  Two modes:

   * default      : round-trip + boundary self-checks (Put/Get/Get32/Len
                    agreement across boundary values and a 20000-step LCG
                    stream).  Prints PASS/FAIL and Halt(0/1).
   * arg "dump"   : emit the exact same line format as /tmp/fts5varint_ref.c
                    (the verbatim-C reference harness) so the streams can be
                    byte-diffed for parity evidence.

  The boundary values and LCG (multiplier 6364136223846793005,
  addend 1442695040888963407, seed 0x1234567890abcdef) are identical to
  the C harness so the two value streams match exactly.
}

uses
  ctypes,
  SysUtils,
  passqlite3fts5varint;

const
  Boundaries: array[0..19] of QWord = (
    0, 1, $7f, $80, $3fff, $4000, $1fffff, $200000, $fffffff, $10000000,
    QWord($7fffffff), QWord($80000000), QWord($ffffffff), QWord($100000000),
    QWord($ffffffffff), QWord($1000000000),
    QWord($7fffffffffffffff), QWord($8000000000000000),
    QWord($fffffffffffeffff), QWord($ffffffffffffffff));

var
  nVal: Integer = 0;
  Vals: array[0..30000] of QWord;
  g_fail: Integer = 0;

procedure BuildStream;
var
  i: Integer;
  x: QWord;
begin
  nVal := 0;
  for i := Low(Boundaries) to High(Boundaries) do begin
    Vals[nVal] := Boundaries[i]; Inc(nVal);
  end;
  x := QWord($1234567890abcdef);
  for i := 0 to 19999 do begin
    x := x * QWord(6364136223846793005) + QWord(1442695040888963407);
    Vals[nVal] := x; Inc(nVal);
  end;
end;

procedure Check(cond: Boolean; const msg: string);
begin
  if not cond then begin
    WriteLn('FAIL: ', msg);
    Inc(g_fail);
  end;
end;

procedure RunDump;
var
  i, k, n, gn, ln: cint;
  p: array[0..11] of Byte;
  g: QWord;
  g32, v32: Cardinal;
  line: string;
begin
  BuildStream;
  for i := 0 to nVal - 1 do begin
    n := sqlite3Fts5PutVarint(@p[0], Vals[i]);
    line := 'P ' + IntToStr(n);
    for k := 0 to n - 1 do line := line + ' ' + LowerCase(IntToHex(p[k], 2));
    WriteLn(line);
    gn := sqlite3Fts5GetVarint(@p[0], @g);
    WriteLn('G ', gn, ' ', g);
  end;
  for i := 0 to nVal - 1 do begin
    v32 := Cardinal(Vals[i] and $ffffffff);
    if v32 < 128 then v32 := v32 or $100;
    sqlite3Fts5PutVarint(@p[0], QWord(v32));
    gn := sqlite3Fts5GetVarint32(@p[0], @g32);
    ln := sqlite3Fts5GetVarintLen(v32);
    WriteLn('V ', gn, ' ', g32, ' L ', ln);
  end;
end;

procedure RunSelfCheck;
var
  i, n, gn: cint;
  p: array[0..11] of Byte;
  g, v: QWord;
  g32, v32, expLen: Cardinal;
begin
  BuildStream;
  for i := 0 to nVal - 1 do begin
    v := Vals[i];
    n := sqlite3Fts5PutVarint(@p[0], v);
    Check((n >= 1) and (n <= 9), 'put length in range');
    gn := sqlite3Fts5GetVarint(@p[0], @g);
    Check(gn = n, 'get length == put length');
    Check(g = v, 'round-trip value ' + IntToStr(i));

    { GetVarint32 must agree with the low 31 bits the C masks off. }
    v32 := Cardinal(v and $ffffffff);
    if v32 < 128 then v32 := v32 or $100;
    sqlite3Fts5PutVarint(@p[0], QWord(v32));
    sqlite3Fts5GetVarint32(@p[0], @g32);
    Check(g32 = (v32 and $7FFFFFFF), 'get32 masks to low 31 bits');

    { GetVarintLen must equal the actual put length for >=128 values. }
    expLen := sqlite3Fts5PutVarint(@p[0], QWord(v32));
    if v32 < (1 shl 14) then
      Check(sqlite3Fts5GetVarintLen(v32) = 2, 'len==2 boundary')
    else
      Check(Cardinal(sqlite3Fts5GetVarintLen(v32)) = expLen, 'len==put length');
  end;
end;

begin
  if (ParamCount >= 1) and (ParamStr(1) = 'dump') then begin
    RunDump;
    Halt(0);
  end;
  RunSelfCheck;
  if g_fail = 0 then begin
    WriteLn('TestFts5Varint: PASS');
    Halt(0);
  end else begin
    WriteLn('TestFts5Varint: FAIL (', g_fail, ' assertions)');
    Halt(1);
  end;
end.
