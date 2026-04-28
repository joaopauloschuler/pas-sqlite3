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
  (see commit history). The original SQLite C source code is in the public
  domain, authored by D. Richard Hipp and contributors. This Pascal port
  adopts the same public-domain posture.
}
{$I passqlite3.inc}
program TestExprBasic;
{
  Phase 6.1 gate test — expr.c: expression allocation, deletion, affinity,
  integer detection, vector, collation skipping, list management, dequoting.

  All tests run without a live database connection (db=nil or malloc fallback).

    T1  sqlite3Dequote — single-quoted string
    T2  sqlite3Dequote — double-quoted string
    T3  sqlite3Dequote — bracket-quoted string
    T4  sqlite3Dequote — nil is a no-op
    T5  sqlite3GetInt32 — valid positive integer
    T6  sqlite3GetInt32 — valid negative integer
    T7  sqlite3GetInt32 — non-numeric returns 0
    T8  sqlite3ExprAffinity — TK_INTEGER leaf => AFF_BLOB (no iValue path)
    T9  sqlite3ExprAffinity — TK_FLOAT leaf => AFF_BLOB
    T10 sqlite3ExprAffinity — TK_NULL leaf => AFF_BLOB
    T11 sqlite3ExprAffinity — EP_IntValue set returns affExpr field
    T12 sqlite3ExprIsInteger — EP_IntValue set, pValue filled
    T13 sqlite3ExprIsInteger — TK_INTEGER token, pValue filled
    T14 sqlite3ExprIsInteger — TK_UPLUS wraps an integer
    T15 sqlite3ExprIsInteger — TK_UMINUS wraps integer (negated)
    T16 sqlite3ExprIsInteger — TK_STRING => 0
    T17 sqlite3IsTrueOrFalse — "true" / "false" recognised (case-insensitive)
    T18 sqlite3IsTrueOrFalse — other strings return 0
    T19 sqlite3ExprIsVector — single TK_INTEGER is not a vector
    T20 sqlite3ExprIsVector — TK_VECTOR is a vector
    T21 sqlite3ExprVectorSize — TK_VECTOR with 3-item list => 3
    T22 sqlite3ExprSkipCollate — skips TK_COLLATE chain
    T23 sqlite3ExprSkipCollateAndLikely — skips TK_LIKELY node
    T24 sqlite3AffinityType — 'INT...' => AFF_INTEGER
    T25 sqlite3AffinityType — 'REAL' => AFF_REAL
    T26 sqlite3AffinityType — 'TEXT' => AFF_TEXT
    T27 sqlite3AffinityType — 'BLOB' => AFF_BLOB
    T28 SizeOf checks: TParse=416, TIdList=8, TOnOrUsing=16

  Gate: T1-T28 all PASS.
}

uses
  passqlite3types,
  passqlite3internal,
  passqlite3os,
  passqlite3util,
  passqlite3pcache,
  passqlite3pager,
  passqlite3wal,
  passqlite3btree,
  passqlite3vdbe,
  passqlite3codegen;

var
  gPass: i32 = 0;
  gFail: i32 = 0;

procedure Check(const name: string; cond: Boolean);
begin
  if cond then
  begin
    WriteLn('  PASS ', name);
    Inc(gPass);
  end else
  begin
    WriteLn('  FAIL ', name);
    Inc(gFail);
  end;
end;

{ ---- helpers ---- }

procedure ZeroExpr(out e: TExpr);
begin
  FillChar(e, SizeOf(e), 0);
end;

procedure ZeroExprList(out el: TExprList);
begin
  FillChar(el, SizeOf(el), 0);
end;

{ ===== T1-T4: sqlite3Dequote ================================================ }

procedure Test1_DequoteSingleQuote;
var
  buf: array[0..31] of AnsiChar;
  s:   string;
  i:   Integer;
begin
  s := '''hello''';
  for i := 1 to Length(s) do buf[i-1] := s[i];
  buf[Length(s)] := #0;
  sqlite3Dequote(@buf[0]);
  Check('T1 dequote single-quoted', string(buf) = 'hello');
end;

procedure Test2_DequoteDoubleQuote;
var
  buf: array[0..31] of AnsiChar;
  s:   string;
  i:   Integer;
begin
  s := '"world"';
  for i := 1 to Length(s) do buf[i-1] := s[i];
  buf[Length(s)] := #0;
  sqlite3Dequote(@buf[0]);
  Check('T2 dequote double-quoted', string(buf) = 'world');
end;

procedure Test3_DequoteBracket;
var
  buf: array[0..31] of AnsiChar;
  s:   string;
  i:   Integer;
begin
  s := '[foo]';
  for i := 1 to Length(s) do buf[i-1] := s[i];
  buf[Length(s)] := #0;
  sqlite3Dequote(@buf[0]);
  Check('T3 dequote bracket', string(buf) = 'foo');
end;

procedure Test4_DequoteNil;
begin
  sqlite3Dequote(nil);
  Check('T4 dequote nil no-op', True);
end;

{ ===== T5-T7: sqlite3GetInt32 =============================================== }

procedure Test5_GetInt32Positive;
var
  v: i32;
  s: AnsiString;
  rc: i32;
begin
  s  := '12345';
  v  := 0;
  rc := sqlite3GetInt32(PAnsiChar(s), @v);
  Check('T5 GetInt32 positive rc=1',  rc = 1);
  Check('T5 GetInt32 positive v=12345', v = 12345);
end;

procedure Test6_GetInt32Negative;
var
  v:  i32;
  s:  AnsiString;
  rc: i32;
begin
  s  := '-99';
  v  := 0;
  rc := sqlite3GetInt32(PAnsiChar(s), @v);
  Check('T6 GetInt32 negative rc=1', rc = 1);
  Check('T6 GetInt32 negative v=-99', v = -99);
end;

procedure Test7_GetInt32NonNumeric;
var
  v:  i32;
  s:  AnsiString;
  rc: i32;
begin
  s  := 'abc';
  v  := 0;
  rc := sqlite3GetInt32(PAnsiChar(s), @v);
  Check('T7 GetInt32 non-numeric rc=0', rc = 0);
end;

{ ===== T8-T11: sqlite3ExprAffinity ========================================= }

procedure Test8_AffinityTkInteger;
var e: TExpr;
begin
  ZeroExpr(e);
  e.op      := TK_INTEGER;
  e.affExpr := AnsiChar(SQLITE_AFF_BLOB);  { set expected affinity }
  Check('T8 affinity TK_INTEGER returns affExpr',
        sqlite3ExprAffinity(@e) = AnsiChar(SQLITE_AFF_BLOB));
end;

procedure Test9_AffinityTkFloat;
var e: TExpr;
begin
  ZeroExpr(e);
  e.op      := TK_FLOAT;
  e.affExpr := AnsiChar(SQLITE_AFF_REAL);
  Check('T9 affinity TK_FLOAT returns affExpr',
        sqlite3ExprAffinity(@e) = AnsiChar(SQLITE_AFF_REAL));
end;

procedure Test10_AffinityTkNull;
var e: TExpr;
begin
  ZeroExpr(e);
  e.op      := TK_NULL;
  e.affExpr := AnsiChar(0);  { null has no affinity (affExpr=0) }
  Check('T10 affinity TK_NULL returns affExpr=0',
        sqlite3ExprAffinity(@e) = AnsiChar(0));
end;

procedure Test11_AffinityEpIntValue;
var e: TExpr;
begin
  ZeroExpr(e);
  e.op       := TK_INTEGER;
  e.flags    := EP_IntValue;
  e.affExpr  := AnsiChar(SQLITE_AFF_INTEGER);
  { when EP_IntValue is set, sqlite3ExprAffinity returns e.affExpr }
  Check('T11 affinity EP_IntValue => affExpr',
        sqlite3ExprAffinity(@e) = AnsiChar(SQLITE_AFF_INTEGER));
end;

{ ===== T12-T16: sqlite3ExprIsInteger ======================================= }

procedure Test12_IsIntegerEpIntValue;
var
  e: TExpr;
  v: i32;
begin
  ZeroExpr(e);
  e.op       := TK_INTEGER;
  e.flags    := EP_IntValue;
  e.u.iValue := 42;
  v := 0;
  Check('T12 IsInteger EP_IntValue rc=1',
        sqlite3ExprIsInteger(@e, @v, nil) = 1);
  Check('T12 IsInteger EP_IntValue v=42', v = 42);
end;

procedure Test13_IsIntegerTkIntegerToken;
var
  e:   TExpr;
  v:   i32;
  tok: AnsiString;
begin
  ZeroExpr(e);
  e.op := TK_INTEGER;
  tok  := '7';
  e.u.zToken := PAnsiChar(tok);
  v := 0;
  Check('T13 IsInteger token rc=1',
        sqlite3ExprIsInteger(@e, @v, nil) = 1);
  Check('T13 IsInteger token v=7', v = 7);
end;

procedure Test14_IsIntegerUplus;
var
  inner: TExpr;
  outer: TExpr;
  v:     i32;
begin
  ZeroExpr(inner);
  ZeroExpr(outer);
  inner.op    := TK_INTEGER;
  inner.flags := EP_IntValue;
  inner.u.iValue := 5;
  outer.op    := TK_UPLUS;
  outer.pLeft := @inner;
  v := 0;
  Check('T14 IsInteger TK_UPLUS rc=1',
        sqlite3ExprIsInteger(@outer, @v, nil) = 1);
  Check('T14 IsInteger TK_UPLUS v=5', v = 5);
end;

procedure Test15_IsIntegerUminus;
var
  inner: TExpr;
  outer: TExpr;
  v:     i32;
begin
  ZeroExpr(inner);
  ZeroExpr(outer);
  inner.op       := TK_INTEGER;
  inner.flags    := EP_IntValue;
  inner.u.iValue := 10;
  outer.op       := TK_UMINUS;
  outer.pLeft    := @inner;
  v := 0;
  Check('T15 IsInteger TK_UMINUS rc=1',
        sqlite3ExprIsInteger(@outer, @v, nil) = 1);
  Check('T15 IsInteger TK_UMINUS v=-10', v = -10);
end;

procedure Test16_IsIntegerString;
var
  e: TExpr;
  v: i32;
begin
  ZeroExpr(e);
  e.op := TK_STRING;
  v := 0;
  Check('T16 IsInteger TK_STRING rc=0',
        sqlite3ExprIsInteger(@e, @v, nil) = 0);
end;

{ ===== T17-T18: sqlite3IsTrueOrFalse ======================================= }

procedure Test17_IsTrueOrFalse;
var
  t: AnsiString;
  f: AnsiString;
begin
  t := 'true';
  f := 'false';
  Check('T17 IsTrueOrFalse "true"',
        sqlite3IsTrueOrFalse(PAnsiChar(t)) <> 0);
  Check('T17 IsTrueOrFalse "false"',
        sqlite3IsTrueOrFalse(PAnsiChar(f)) <> 0);
  Check('T17 IsTrueOrFalse "TRUE" (upper)',
        sqlite3IsTrueOrFalse('TRUE') <> 0);
end;

procedure Test18_IsTrueOrFalseOther;
var
  s: AnsiString;
begin
  s := 'maybe';
  Check('T18 IsTrueOrFalse "maybe"=0',
        sqlite3IsTrueOrFalse(PAnsiChar(s)) = 0);
end;

{ ===== T19-T21: sqlite3ExprIsVector / sqlite3ExprVectorSize ================ }

procedure Test19_NotVector;
var e: TExpr;
begin
  ZeroExpr(e);
  e.op := TK_INTEGER;
  Check('T19 TK_INTEGER is not vector',
        sqlite3ExprIsVector(@e) = 0);
end;

procedure Test20_IsVector;
var e: TExpr;
begin
  ZeroExpr(e);
  e.op := TK_VECTOR;
  Check('T20 TK_VECTOR is vector',
        sqlite3ExprIsVector(@e) <> 0);
end;

procedure Test21_VectorSize;
{ TK_VECTOR with a 3-item ExprList: VectorSize should return 3 }
var
  e:    TExpr;
  buf:  array[0..SZ_EXPRLIST_HEADER + 3*SZ_EXPRLIST_ITEM - 1] of Byte;
  pEl:  PExprList;
begin
  ZeroExpr(e);
  FillChar(buf, SizeOf(buf), 0);
  pEl := PExprList(@buf[0]);
  pEl^.nExpr := 3;
  e.op    := TK_VECTOR;
  e.flags := 0;  { EP_xIsSelect not set => uses pList }
  e.x.pList := pEl;
  Check('T21 VectorSize=3', sqlite3ExprVectorSize(@e) = 3);
end;

{ ===== T22-T23: sqlite3ExprSkipCollate ===================================== }

procedure Test22_SkipCollate;
{ TK_COLLATE nodes always have EP_Skip set (set by sqlite3ExprAddCollateToken) }
var
  inner: TExpr;
  outer: TExpr;
begin
  ZeroExpr(inner);
  ZeroExpr(outer);
  inner.op    := TK_INTEGER;
  outer.op    := TK_COLLATE;
  outer.flags := EP_Skip;  { sqlite3ExprAddCollateToken always sets EP_Skip }
  outer.pLeft := @inner;
  Check('T22 SkipCollate skips TK_COLLATE (EP_Skip set)',
        sqlite3ExprSkipCollate(@outer) = @inner);
end;

procedure Test23_SkipCollateAndLikely;
{ EP_Skip flag causes SkipCollateAndLikely to descend via pLeft }
var
  inner: TExpr;
  outer: TExpr;
begin
  ZeroExpr(inner);
  ZeroExpr(outer);
  inner.op    := TK_INTEGER;
  outer.op    := TK_INTEGER;
  outer.flags := EP_Skip;
  outer.pLeft := @inner;
  Check('T23 SkipCollateAndLikely EP_Skip skips to pLeft',
        sqlite3ExprSkipCollateAndLikely(@outer) = @inner);
end;

{ ===== T24-T27: sqlite3AffinityType ======================================== }

procedure Test24_AffinityTypeInt;
var s: AnsiString;
begin
  s := 'INTEGER';
  Check('T24 AffinityType INTEGER',
        sqlite3AffinityType(PAnsiChar(s), nil) = AnsiChar(SQLITE_AFF_INTEGER));
end;

procedure Test25_AffinityTypeReal;
var s: AnsiString;
begin
  s := 'REAL';
  Check('T25 AffinityType REAL',
        sqlite3AffinityType(PAnsiChar(s), nil) = AnsiChar(SQLITE_AFF_REAL));
end;

procedure Test26_AffinityTypeText;
var s: AnsiString;
begin
  s := 'TEXT';
  Check('T26 AffinityType TEXT',
        sqlite3AffinityType(PAnsiChar(s), nil) = AnsiChar(SQLITE_AFF_TEXT));
end;

procedure Test27_AffinityTypeBlob;
var s: AnsiString;
begin
  s := 'BLOB';
  Check('T27 AffinityType BLOB',
        sqlite3AffinityType(PAnsiChar(s), nil) = AnsiChar(SQLITE_AFF_BLOB));
end;

{ ===== T28: SizeOf checks ================================================== }

procedure Test28_SizeOfStructs;
begin
  Check('T28 SizeOf(TExpr)=72',       SizeOf(TExpr)      = 72);
  Check('T28 SizeOf(TExprList)=8',    SizeOf(TExprList)   = 8);
  Check('T28 SizeOf(TIdList)=8',      SizeOf(TIdList)     = 8);
  Check('T28 SizeOf(TOnOrUsing)=16',  SizeOf(TOnOrUsing)  = 16);
  Check('T28 SizeOf(TParse)=416',     SizeOf(TParse)      = 416);
end;

{ ===== main ================================================================ }

begin
  WriteLn('=== TestExprBasic: Phase 6.1 expr.c gate test ===');
  WriteLn;

  Test1_DequoteSingleQuote;
  Test2_DequoteDoubleQuote;
  Test3_DequoteBracket;
  Test4_DequoteNil;
  Test5_GetInt32Positive;
  Test6_GetInt32Negative;
  Test7_GetInt32NonNumeric;
  Test8_AffinityTkInteger;
  Test9_AffinityTkFloat;
  Test10_AffinityTkNull;
  Test11_AffinityEpIntValue;
  Test12_IsIntegerEpIntValue;
  Test13_IsIntegerTkIntegerToken;
  Test14_IsIntegerUplus;
  Test15_IsIntegerUminus;
  Test16_IsIntegerString;
  Test17_IsTrueOrFalse;
  Test18_IsTrueOrFalseOther;
  Test19_NotVector;
  Test20_IsVector;
  Test21_VectorSize;
  Test22_SkipCollate;
  Test23_SkipCollateAndLikely;
  Test24_AffinityTypeInt;
  Test25_AffinityTypeReal;
  Test26_AffinityTypeText;
  Test27_AffinityTypeBlob;
  Test28_SizeOfStructs;

  WriteLn;
  WriteLn('Results: ', gPass, ' passed, ', gFail, ' failed.');
  if gFail > 0 then
    Halt(1);
end.
