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
program TestFts3Write;

{
  Phase 6.40.1.j gate — the FTS3 segment writer/reader/merge core
  (fts3_write.c).  Most of the file is the segment b-tree engine, which
  cannot be SQL-driven until the fts3/fts4 vtab module lands (6.40.1.k).
  This gate exercises the SELF-CONTAINED primitives that are reachable by
  direct Pascal calls without a live virtual table:

    * The FTS3 varint codecs (sqlite3Fts3PutVarint / GetVarint / GetVarintU /
      GetVarint32 / GetVarintBounded / VarintLen and the fts3GetVarint32
      macro).  These differ from the engine's core varint (max 10 not 9
      bytes) and underpin every byte of the on-disk segment format, so a
      round-trip + byte-exact-vs-C check is the highest-value gate here.

  Expected byte encodings were derived from the C semantics in
  fts3.c:331..442 (the do/while 7-bit little-endian continuation form).

  Exit 0 = PASS.
}

uses
  ctypes,
  SysUtils,
  passqlite3types,
  passqlite3fts3;

var
  nFail: cint = 0;

procedure Check(cond: Boolean; const msg: string);
begin
  if not cond then begin
    WriteLn('FAIL: ', msg);
    Inc(nFail);
  end;
end;

{ Reference encoder mirroring fts3.c:331 sqlite3Fts3PutVarint, used to
  cross-check the ported one byte-for-byte. }
function RefPutVarint(p: PByte; v: UInt64): cint;
var
  q: PByte;
begin
  q := p;
  repeat
    q^ := Byte((v and $7f) or $80);
    Inc(q);
    v := v shr 7;
  until v = 0;
  PByte(PtrUInt(q) - 1)^ := PByte(PtrUInt(q) - 1)^ and $7f;
  Result := cint(PtrUInt(q) - PtrUInt(p));
end;

{ Round-trip one value through PutVarint -> GetVarint(U) and check the
  encoding matches the reference encoder + the decode is exact. }
procedure RoundTrip(v: UInt64; const label_: string);
var
  a, b: array[0..15] of Byte;
  nA, nB, nDec: cint;
  out64: UInt64;
  outS: Int64;
begin
  FillChar(a, SizeOf(a), 0);
  FillChar(b, SizeOf(b), 0);
  nA := sqlite3Fts3PutVarint(PChar(@a[0]), Int64(v));
  nB := RefPutVarint(@b[0], v);
  Check(nA = nB, label_ + ': put length matches ref ('
        + IntToStr(nA) + ' vs ' + IntToStr(nB) + ')');
  Check(CompareByte(a, b, nA) = 0, label_ + ': put bytes match ref');
  Check((nA >= 1) and (nA <= 10), label_ + ': put length in [1,10]');

  out64 := 0;
  nDec := sqlite3Fts3GetVarintU(PChar(@a[0]), @out64);
  Check(nDec = nA, label_ + ': GetVarintU length round-trips');
  Check(out64 = v, label_ + ': GetVarintU value round-trips');

  outS := 0;
  nDec := sqlite3Fts3GetVarint(PChar(@a[0]), @outS);
  Check(nDec = nA, label_ + ': GetVarint length round-trips');
  Check(UInt64(outS) = v, label_ + ': GetVarint value round-trips (bit-exact)');

  Check(sqlite3Fts3VarintLen(v) = nA, label_ + ': VarintLen matches put length');
end;

{ Check GetVarint32 truncates correctly for 32-bit values. }
procedure RoundTrip32(v: cuint; const label_: string);
var
  a: array[0..15] of Byte;
  nA, nDec, outI: cint;
begin
  FillChar(a, SizeOf(a), 0);
  nA := sqlite3Fts3PutVarint(PChar(@a[0]), Int64(UInt64(v)));
  outI := 0;
  nDec := sqlite3Fts3GetVarint32(PChar(@a[0]), @outI);
  Check(nDec = nA, label_ + ': GetVarint32 length');
  Check(cuint(outI) = v, label_ + ': GetVarint32 value');
end;

procedure TestSingleValues;
begin
  RoundTrip(0, 'v=0');
  RoundTrip(1, 'v=1');
  RoundTrip($7f, 'v=127 (1-byte max)');
  RoundTrip($80, 'v=128 (2-byte min)');
  RoundTrip(300, 'v=300');
  RoundTrip($3fff, 'v=16383 (2-byte max)');
  RoundTrip($4000, 'v=16384 (3-byte min)');
  RoundTrip($1fffff, 'v=3-byte max');
  RoundTrip($200000, 'v=4-byte min');
  RoundTrip($0fffffff, 'v=4-byte max');
  RoundTrip($10000000, 'v=5-byte min');
  RoundTrip($ffffffff, 'v=2^32-1');
  RoundTrip(UInt64($100000000), 'v=2^32');
  RoundTrip(UInt64($7fffffffffffffff), 'v=2^63-1');
  RoundTrip(UInt64($8000000000000000), 'v=2^63');
  RoundTrip(UInt64($ffffffffffffffff), 'v=2^64-1 (10-byte max)');
end;

procedure Test32Truncation;
var
  a: array[0..15] of Byte;
  outI: cint;
begin
  FillChar(a, SizeOf(a), 0);
  sqlite3Fts3PutVarint(PChar(@a[0]), Int64(UInt64($ffffffff)));
  outI := 0;
  sqlite3Fts3GetVarint32(PChar(@a[0]), @outI);
  Check(cuint(outI) = cuint($7fffffff),
    '32:UINT_MAX truncates to 0x7fffffff (C non-negative contract)');
end;

procedure Test32;
begin
  RoundTrip32(0, '32:0');
  RoundTrip32(127, '32:127');
  RoundTrip32(128, '32:128');
  RoundTrip32(16384, '32:16384');
  RoundTrip32($0fffffff, '32:4-byte max');
  RoundTrip32($10000000, '32:5-byte');
  RoundTrip32($7fffffff, '32:INT_MAX');
  { fts3.c:411 — GetVarint32 is documented to truncate to a NON-NEGATIVE
    32-bit integer (it masks the result to 31 bits: *pi = a | ((*ptr&7)<<28)).
    So feeding 0xffffffff (10-byte encoding) yields 0x7fffffff, not 0xffffffff.
    This matches the C assert( 0==(a & 0x80000000) ). }
  Test32Truncation;
end;

{ A multi-value buffer (the doclist/segment encoding pattern): write a
  sequence of varints back-to-back, then read them all back and check
  both the values and the cumulative offsets. }
procedure TestMultiValueBuffer;
const
  vals: array[0..6] of UInt64 = (
    5, 0, 1, 300, $ffffffff, UInt64($123456789a), 2);
var
  buf: array[0..127] of Byte;
  off, i, n: cint;
  offs: array[0..6] of cint;
  v: UInt64;
begin
  FillChar(buf, SizeOf(buf), 0);
  off := 0;
  for i := 0 to High(vals) do begin
    offs[i] := off;
    off := off + sqlite3Fts3PutVarint(PChar(@buf[off]), Int64(vals[i]));
  end;
  { Read them all back. }
  for i := 0 to High(vals) do begin
    v := 0;
    n := sqlite3Fts3GetVarintU(PChar(@buf[offs[i]]), @v);
    Check(v = vals[i], 'multibuf value[' + IntToStr(i) + ']');
    if i < High(vals) then
      Check(offs[i] + n = offs[i+1],
        'multibuf offset advances correctly at [' + IntToStr(i) + ']');
  end;
end;

{ The fts3GetVarint32 macro (fts3Int.h:609): single-byte fast path when the
  high bit is clear, slow path otherwise.  Both must agree with the codec. }
procedure TestGetVarint32Macro;
var
  a: array[0..15] of Byte;
  nMac, nFn, outMac, outFn: cint;
  testvals: array[0..4] of cuint;
  i: cint;
begin
  testvals[0] := 0;
  testvals[1] := 127;       { high bit clear -> fast path }
  testvals[2] := 128;       { 2 bytes -> slow path }
  testvals[3] := 100000;
  testvals[4] := $7fffffff;
  for i := 0 to High(testvals) do begin
    FillChar(a, SizeOf(a), 0);
    sqlite3Fts3PutVarint(PChar(@a[0]), Int64(UInt64(testvals[i])));
    outMac := 0; outFn := 0;
    nMac := fts3GetVarint32(PChar(@a[0]), @outMac);
    nFn := sqlite3Fts3GetVarint32(PChar(@a[0]), @outFn);
    Check(outMac = outFn, 'macro vs fn value[' + IntToStr(i) + ']');
    Check(nMac = nFn, 'macro vs fn length[' + IntToStr(i) + ']');
    Check(cuint(outMac) = testvals[i], 'macro value[' + IntToStr(i) + ']');
  end;
end;

{ GetVarintBounded must stop reading at pEnd and treat missing bytes as 0
  (fts3.c:387).  Within bounds it must equal the unbounded decoder. }
procedure TestBounded;
var
  a: array[0..15] of Byte;
  n: cint;
  outB: Int64;
begin
  FillChar(a, SizeOf(a), 0);
  n := sqlite3Fts3PutVarint(PChar(@a[0]), Int64($123456));
  outB := 0;
  { full buffer available }
  Check(sqlite3Fts3GetVarintBounded(PChar(@a[0]), PChar(@a[n]), @outB) = n,
    'bounded: length when fully in bounds');
  Check(outB = $123456, 'bounded: value when fully in bounds');
end;

begin
  TestSingleValues;
  Test32;
  TestMultiValueBuffer;
  TestGetVarint32Macro;
  TestBounded;

  if nFail = 0 then begin
    WriteLn('TestFts3Write: PASS');
    Halt(0);
  end else begin
    WriteLn('TestFts3Write: FAIL (', nFail, ' checks failed)');
    Halt(1);
  end;
end.
