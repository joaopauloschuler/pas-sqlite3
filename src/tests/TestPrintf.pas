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

begin
  WriteLn('=== TestPrintf — Phase 6.bis.4a printf engine ===');
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
  WriteLn;
  WriteLn('=== Total: ', gPass, ' pass, ', gFail, ' fail ===');
  if gFail > 0 then Halt(1);
end.
