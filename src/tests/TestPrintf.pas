{$I passqlite3.inc}
program TestPrintf;
{
  Phase 6.bis.4a gate — passqlite3printf engine.

  Exercises sqlite3FormatStr (the AnsiString core) directly and verifies
  every conversion specifier the SQLite codepaths use today, plus the
  heap wrappers (sqlite3PfMprintf, sqlite3MPrintf, sqlite3MAppendf,
  sqlite3PfSnprintf).
}

uses
  SysUtils,
  passqlite3types,
  passqlite3os,
  passqlite3util,
  passqlite3printf;

var
  gPass: i32 = 0;
  gFail: i32 = 0;

procedure CheckEq(name, got, want: AnsiString);
begin
  if got = want then begin
    WriteLn('  PASS ', name);
    Inc(gPass);
  end else begin
    WriteLn('  FAIL ', name, ' got="', got, '" want="', want, '"');
    Inc(gFail);
  end;
end;

procedure CheckTrue(name: AnsiString; cond: Boolean);
begin
  if cond then begin WriteLn('  PASS ', name); Inc(gPass); end
  else        begin WriteLn('  FAIL ', name); Inc(gFail); end;
end;

{ ------------ Test groups ------------ }

procedure TestBasics;
begin
  CheckEq('T1 literal',     sqlite3FormatStr('hello world', []), 'hello world');
  CheckEq('T2 %s',          sqlite3FormatStr('hello %s!', ['world']), 'hello world!');
  CheckEq('T3 %s nil',      sqlite3FormatStr('a%sb', [PAnsiChar(nil)]), 'ab');
  CheckEq('T4 %d',          sqlite3FormatStr('n=%d', [42]), 'n=42');
  CheckEq('T5 %d negative', sqlite3FormatStr('%d', [-7]), '-7');
end;

procedure TestWidthPrecision;
begin
  CheckEq('T6 %5d',    sqlite3FormatStr('%5d', [42]), '   42');
  CheckEq('T7 %-5d|',  sqlite3FormatStr('%-5d|', [42]), '42   |');
  CheckEq('T8 %05d',   sqlite3FormatStr('%05d', [42]), '00042');
  CheckEq('T9 %+d',    sqlite3FormatStr('%+d', [42]), '+42');
  CheckEq('T10 % d',   sqlite3FormatStr('% d', [42]), ' 42');
  CheckEq('T11 %5.3d', sqlite3FormatStr('%5.3d', [42]), '  042');
  CheckEq('T12 %.3s',  sqlite3FormatStr('%.3s', ['abcdef']), 'abc');
end;

procedure TestRadix;
begin
  CheckEq('T13 %u',  sqlite3FormatStr('%u', [Int64(4294967295)]), '4294967295');
  CheckEq('T14 %x',  sqlite3FormatStr('%x', [255]), 'ff');
  CheckEq('T15 %X',  sqlite3FormatStr('%X', [255]), 'FF');
  CheckEq('T16 %o',  sqlite3FormatStr('%o', [8]), '10');
end;

procedure TestI64;
begin
  CheckEq('T17 %lld', sqlite3FormatStr('%lld', [Int64(-9000000000)]),
          '-9000000000');
end;

procedure TestCharPercentMulti;
begin
  CheckEq('T18 %c',     sqlite3FormatStr('%c%c%c',
          [Ord('a'), Ord('b'), Ord('c')]), 'abc');
  CheckEq('T19 %%',     sqlite3FormatStr('100%%', []), '100%');
  CheckEq('T20 multi',  sqlite3FormatStr('%s=%d (%s)', ['x', 7, 'ok']),
          'x=7 (ok)');
end;

procedure TestSqlExtensions;
begin
  CheckEq('T21 %q simple',     sqlite3FormatStr('%q', ['it''s']), 'it''''s');
  CheckEq('T22 %Q wraps',      sqlite3FormatStr('%Q', ['hello']), '''hello''');
  CheckEq('T23 %Q nil → NULL', sqlite3FormatStr('%Q', [PAnsiChar(nil)]), 'NULL');
  CheckEq('T24 %w identifier', sqlite3FormatStr('%w', ['a"b']), 'a""b');
  CheckEq('T25 %z = %s',       sqlite3FormatStr('%z', ['xyz']), 'xyz');
  CheckEq('T29 %q no-op',      sqlite3FormatStr('%q', ['plain']), 'plain');
end;

type
  TTokenLocal = record
    z:    PAnsiChar;
    n:    u32;
    _pad: u32;
  end;

procedure TestToken;
var
  tok: TTokenLocal;
  tokSrc: AnsiString;
begin
  tokSrc  := 'CREATE_VIRTUAL';
  tok.z   := PAnsiChar(tokSrc);
  tok.n   := 6;
  tok._pad := 0;
  CheckEq('T26 %T 6-byte slice', sqlite3FormatStr('[%T]', [@tok]), '[CREATE]');

  tok.z := nil; tok.n := 0;
  CheckEq('T27 %T empty',        sqlite3FormatStr('[%T]', [@tok]), '[]');
end;

procedure TestUnknownConv;
begin
  CheckEq('T28 unknown %y', sqlite3FormatStr('a%yb', [42]), 'a%yb');
end;

procedure TestHeapWrappers;
var
  z, z2: PAnsiChar;
  buf: array[0..7] of AnsiChar;
begin
  z := sqlite3PfMprintf('answer=%d', [42]);
  CheckTrue('T30a non-nil', z <> nil);
  if z <> nil then begin
    CheckEq('T30b body', AnsiString(z), 'answer=42');
    sqlite3_free(z);
  end;

  z := sqlite3MPrintf(nil, '%s/%d', ['db', 7]);
  CheckTrue('T31a non-nil', z <> nil);
  if z <> nil then begin
    CheckEq('T31b body', AnsiString(z), 'db/7');
    sqlite3_free(z);
  end;

  sqlite3PfSnprintf(8, @buf[0], '0123456789', []);
  CheckEq('T32a 7+NUL', AnsiString(PAnsiChar(@buf[0])), '0123456');
  CheckTrue('T32b NUL', buf[7] = #0);

  z := sqlite3PfMprintf('start ', []);
  z2 := sqlite3MAppendf(nil, z, 'mid=%d end', [99]);
  { z is freed inside sqlite3MAppendf — do not access }
  CheckTrue('T33a non-nil', z2 <> nil);
  if z2 <> nil then begin
    CheckEq('T33b body', AnsiString(z2), 'start mid=99 end');
    sqlite3_free(z2);
  end;
end;

procedure TestSWidth;
begin
  CheckEq('T34 %10s right', sqlite3FormatStr('|%10s|', ['ab']), '|        ab|');
  CheckEq('T35 %-10s left', sqlite3FormatStr('|%-10s|', ['ab']), '|ab        |');
  CheckEq('T36 %*d',        sqlite3FormatStr('%*d', [6, 42]), '    42');
end;

procedure TestOrdinal;
begin
  { Phase 6.bis.4b.2a — %r (etORDINAL).  Mirrors printf.c:481..488. }
  CheckEq('T37 %r 1',   sqlite3FormatStr('%r', [1]),   '1st');
  CheckEq('T38 %r 2',   sqlite3FormatStr('%r', [2]),   '2nd');
  CheckEq('T39 %r 3',   sqlite3FormatStr('%r', [3]),   '3rd');
  CheckEq('T40 %r 4',   sqlite3FormatStr('%r', [4]),   '4th');
  CheckEq('T41 %r 0',   sqlite3FormatStr('%r', [0]),   '0th');
  { Teen exception: 11..13 are *th not *st/*nd/*rd. }
  CheckEq('T42 %r 11',  sqlite3FormatStr('%r', [11]),  '11th');
  CheckEq('T43 %r 12',  sqlite3FormatStr('%r', [12]),  '12th');
  CheckEq('T44 %r 13',  sqlite3FormatStr('%r', [13]),  '13th');
  CheckEq('T45 %r 14',  sqlite3FormatStr('%r', [14]),  '14th');
  { Decade resumption: 21st 22nd 23rd 24th, 101st 111th 112th 121st. }
  CheckEq('T46 %r 21',  sqlite3FormatStr('%r', [21]),  '21st');
  CheckEq('T47 %r 22',  sqlite3FormatStr('%r', [22]),  '22nd');
  CheckEq('T48 %r 23',  sqlite3FormatStr('%r', [23]),  '23rd');
  CheckEq('T49 %r 101', sqlite3FormatStr('%r', [101]), '101st');
  CheckEq('T50 %r 111', sqlite3FormatStr('%r', [111]), '111th');
  CheckEq('T51 %r 112', sqlite3FormatStr('%r', [112]), '112th');
  CheckEq('T52 %r 121', sqlite3FormatStr('%r', [121]), '121st');
  { Width pad — spaces, not zeros (suffix is text, not a digit). }
  CheckEq('T53 %6r',    sqlite3FormatStr('|%6r|', [21]), '|  21st|');
  CheckEq('T54 %-6r',   sqlite3FormatStr('|%-6r|', [21]), '|21st  |');
  { Negative ordinals — sign prefix preserved, suffix uses |value|. }
  CheckEq('T55 %r -1',  sqlite3FormatStr('%r', [-1]),  '-1st');
  CheckEq('T56 %r -11', sqlite3FormatStr('%r', [-11]), '-11th');
  { Diagnostic-message use site (the typical SQLite call pattern). }
  CheckEq('T57 message',
          sqlite3FormatStr('argument %r is invalid', [3]),
          'argument 3rd is invalid');
end;

{ Phase 6.bis.4b.2c — %f / %e / %E / %g / %G float conversions.  Each
  expected value below was produced by sqlite3_mprintf(fmt, val) running
  against the C reference build (libsqlite3.so) — these are *canonical*
  SQLite outputs, not libc snprintf outputs.  They differ from libc in a
  few places (notably "%.0f" of 2.5 → "3" via round-half-up vs libc's
  banker rounding "2"). }
procedure TestFloat;
begin
  CheckEq('T58 %f 3.14',         sqlite3FormatStr('%f', [3.14]),       '3.140000');
  CheckEq('T59 %f 0.0',          sqlite3FormatStr('%f', [0.0]),        '0.000000');
  CheckEq('T60 %f -3.14',        sqlite3FormatStr('%f', [-3.14]),      '-3.140000');
  CheckEq('T61 %.2f 3.14159',    sqlite3FormatStr('%.2f', [3.14159]),  '3.14');
  CheckEq('T62 %10.2f',          sqlite3FormatStr('%10.2f', [3.14]),   '      3.14');
  CheckEq('T63 %-10.2f',         sqlite3FormatStr('%-10.2f', [3.14]),  '3.14      ');
  CheckEq('T64 %010.2f',         sqlite3FormatStr('%010.2f', [3.14]),  '0000003.14');
  CheckEq('T65 %+.2f',           sqlite3FormatStr('%+.2f', [3.14]),    '+3.14');
  CheckEq('T66 %e 314.0',        sqlite3FormatStr('%e', [314.0]),      '3.140000e+02');
  CheckEq('T67 %E 314.0',        sqlite3FormatStr('%E', [314.0]),      '3.140000E+02');
  CheckEq('T68 %.2e 314.159',    sqlite3FormatStr('%.2e', [314.159]),  '3.14e+02');
  CheckEq('T69 %g 314.0',        sqlite3FormatStr('%g', [314.0]),      '314');
  CheckEq('T70 %g 0.0001',       sqlite3FormatStr('%g', [0.0001]),     '0.0001');
  CheckEq('T71 %g 0.00001',      sqlite3FormatStr('%g', [0.00001]),    '1e-05');
  CheckEq('T72 %g 1e10',         sqlite3FormatStr('%g', [1e10]),       '1e+10');
  CheckEq('T73 %.3g 314.159',    sqlite3FormatStr('%.3g', [314.159]),  '314');
  CheckEq('T74 %.6g 1.5',        sqlite3FormatStr('%.6g', [1.5]),      '1.5');
  CheckEq('T75 %f 0.1',          sqlite3FormatStr('%f', [0.1]),        '0.100000');
  CheckEq('T76 %f 1.5',          sqlite3FormatStr('%f', [1.5]),        '1.500000');
  { Round-half-up — SQLite-specific (libc does banker rounding here). }
  CheckEq('T77 %.0f 2.5 → 3',    sqlite3FormatStr('%.0f', [2.5]),      '3');
  CheckEq('T78 %.0f 1.5 → 2',    sqlite3FormatStr('%.0f', [1.5]),      '2');
  CheckEq('T79 %f -0.5',         sqlite3FormatStr('%f', [-0.5]),       '-0.500000');
  CheckEq('T80 %f 1e-10',        sqlite3FormatStr('%f', [1e-10]),      '0.000000');
  CheckEq('T81 %g 1e-5',         sqlite3FormatStr('%g', [1e-5]),       '1e-05');
  CheckEq('T82 %e 1.0',          sqlite3FormatStr('%e', [1.0]),        '1.000000e+00');
  CheckEq('T83 %e 1234567890.0', sqlite3FormatStr('%e', [1234567890.0]), '1.234568e+09');
  CheckEq('T84 %.20f 0.1',       sqlite3FormatStr('%.20f', [0.1]),     '0.10000000000000000000');
  CheckEq('T85 %g 1.0',          sqlite3FormatStr('%g', [1.0]),        '1');
  CheckEq('T86 %f 100.0',        sqlite3FormatStr('%f', [100.0]),      '100.000000');
  CheckEq('T87 %.4f 0.0',        sqlite3FormatStr('%.4f', [0.0]),      '0.0000');
  CheckEq('T88 %g 0.0',          sqlite3FormatStr('%g', [0.0]),        '0');
end;

type
  { Mirror of passqlite3printf.TSrcItemBlit (which mirrors codegen.TSrcItem).
    Same field layout — matches the 72-byte struct exactly so we can hand
    the test's address to %S without dragging passqlite3codegen into the
    test's uses clause. }
  TSrcItemTest = record
    zName:   PAnsiChar;
    zAlias:  PAnsiChar;
    pSTab:   Pointer;
    fg_jointype: Byte;
    fg_bits:     Byte;
    fg_bits2:    Byte;
    fg_bits3:    Byte;
    iCursor: i32;
    colUsed: u64;
    u1_nRow: u32;
    u1_pad:  u32;
    u2:      Pointer;
    u3:      Pointer;
    u4_ptr:  Pointer;
  end;

  TSelectTest = record
    op:         Byte;
    _pad0:      Byte;
    nSelectRow: i16;
    selFlags:   u32;
    iLimit:     i32;
    iOffset:    i32;
    selId:      u32;
    _pad1:      u32;
  end;

  TSubqueryTest = record
    pSelect:     Pointer;
    addrFillSub: i32;
    regReturn:   i32;
    regResult:   i32;
    _pad:        i32;
  end;

procedure TestSrcItem;
const
  SF_MultiValue = u32($0000400);
  SF_NestedFrom = u32($0000800);
var
  it: TSrcItemTest;
  sel: TSelectTest;
  subq: TSubqueryTest;
  zN, zA, zD: AnsiString;
begin
  zN := 'mytable'; zA := 'myalias'; zD := 'maindb';
  FillChar(it, SizeOf(it), 0);

  { T89 — zAlias takes priority over zName (no `!`). }
  it.zName  := PAnsiChar(zN);
  it.zAlias := PAnsiChar(zA);
  CheckEq('T89 %S zAlias-priority', sqlite3FormatStr('[%S]', [@it]), '[myalias]');

  { T90 — `!` (altform2) flips priority to zName. }
  CheckEq('T90 %!S forces zName', sqlite3FormatStr('[%!S]', [@it]), '[mytable]');

  { T91 — zName with database prefix (no fixedSchema, no isSubquery). }
  it.zAlias := nil;
  it.u4_ptr := PAnsiChar(zD);
  CheckEq('T91 %S db.tbl', sqlite3FormatStr('[%S]', [@it]), '[maindb.mytable]');

  { T92 — fixedSchema bit suppresses database prefix. }
  it.fg_bits3 := $01;  { fixedSchema }
  CheckEq('T92 %S fixedSchema no prefix', sqlite3FormatStr('[%S]', [@it]),
          '[mytable]');

  { T93 — isSubquery bit also suppresses database prefix.  u4_ptr in this
    case is logically pSubq, but printf only consults it when *no*
    suppression bits are set, so it doesn't matter what we point at. }
  it.fg_bits3 := 0;
  it.fg_bits  := $04;  { isSubquery }
  CheckEq('T93 %S isSubquery no prefix', sqlite3FormatStr('[%S]', [@it]),
          '[mytable]');

  { T94 — zAlias + zName + altform2 + database — `!` exposes the database
    prefix path because it falls into the zName branch. }
  it.fg_bits  := 0;
  it.zAlias   := PAnsiChar(zA);
  it.u4_ptr   := PAnsiChar(zD);
  CheckEq('T94 %!S db.tbl with alias', sqlite3FormatStr('[%!S]', [@it]),
          '[maindb.mytable]');

  { T95 — nil item pointer emits empty body. }
  CheckEq('T95 %S nil', sqlite3FormatStr('[%S]', [Pointer(nil)]), '[]');

  { T96 — width padding (right-align by default, left-align with `-`). }
  it.zAlias := PAnsiChar(zA); it.zName := nil; it.u4_ptr := nil;
  CheckEq('T96a %12S right-pad', sqlite3FormatStr('[%12S]', [@it]),
          '[     myalias]');
  CheckEq('T96b %-12S left-pad', sqlite3FormatStr('[%-12S]', [@it]),
          '[myalias     ]');

  { T97 — subquery descriptor (no zName, no zAlias, isSubquery). }
  FillChar(it, SizeOf(it), 0);
  FillChar(sel, SizeOf(sel), 0);
  FillChar(subq, SizeOf(subq), 0);
  sel.selId    := 7;
  sel.selFlags := 0;
  subq.pSelect := @sel;
  it.fg_bits   := $04;  { isSubquery }
  it.u4_ptr    := @subq;
  CheckEq('T97 %S subquery descriptor', sqlite3FormatStr('[%S]', [@it]),
          '[(subquery-7)]');

  { T98 — nested-FROM descriptor. }
  sel.selFlags := SF_NestedFrom;
  sel.selId    := 12;
  CheckEq('T98 %S join descriptor', sqlite3FormatStr('[%S]', [@it]),
          '[(join-12)]');

  { T99 — multi-value VALUES clause descriptor.  Reads u1.nRow, not selId. }
  sel.selFlags := SF_MultiValue;
  it.u1_nRow   := 5;
  CheckEq('T99 %S multi-value', sqlite3FormatStr('[%S]', [@it]),
          '[5-ROW VALUES CLAUSE]');

  { T100 — both zName and zAlias nil and isSubquery clear → empty body. }
  FillChar(it, SizeOf(it), 0);
  CheckEq('T100 %S empty', sqlite3FormatStr('[%S]', [@it]), '[]');
end;

begin
  WriteLn('=== TestPrintf — Phase 6.bis.4a/b printf engine ===');
  TestBasics;
  TestWidthPrecision;
  TestRadix;
  TestI64;
  TestCharPercentMulti;
  TestSqlExtensions;
  TestToken;
  TestUnknownConv;
  TestHeapWrappers;
  TestSWidth;
  TestOrdinal;
  TestFloat;
  TestSrcItem;
  WriteLn;
  WriteLn('=== Total: ', gPass, ' pass, ', gFail, ' fail ===');
  if gFail > 0 then Halt(1);
end.
