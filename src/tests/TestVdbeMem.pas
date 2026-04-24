{$I passqlite3.inc}
program TestVdbeMem;
{
  Phase 5.3 gate test — vdbemem.c: Mem value coercion and storage layer.

  Tests run without a real database file.  We allocate a minimal sqlite3-sized
  byte buffer on the heap and poke in the offset-verified fields that vdbemem
  helpers read (enc at offset 100, nFpDigit at 114, aLimit[0] at 136).

    T1  sqlite3VdbeMemSetNull — flags = MEM_Null
    T2  sqlite3VdbeMemSetInt64 — stores integer, flags = MEM_Int
    T3  sqlite3VdbeMemSetDouble — stores real, flags = MEM_Real
    T4  sqlite3VdbeMemSetDouble — NaN → NULL
    T5  sqlite3VdbeMemSetZeroBlob — flags = MEM_Blob|MEM_Zero, n=nByte
    T6  sqlite3VdbeMemSetStr — static string, MEM_Str|MEM_Static
    T7  sqlite3VdbeMemSetStr — blob (enc=0), MEM_Blob|MEM_Static
    T8  sqlite3VdbeMemIntegerify — real 3.7 → int 3
    T9  sqlite3VdbeMemIntegerify — real 3.0 → int 3 (exact)
    T10 sqlite3VdbeMemRealify — int 42 → real 42.0
    T11 sqlite3RealSameAsInt — 3.0 → true; 3.1 → false
    T12 sqlite3VdbeMemNumerify — string "123" → integer
    T13 sqlite3VdbeMemNumerify — string "1.5" → real
    T14 sqlite3VdbeMemCopy — independent copy, change original does not affect copy
    T15 sqlite3VdbeMemShallowCopy — shares static string pointer
    T16 sqlite3VdbeMemMove — src becomes NULL after move
    T17 sqlite3VdbeMemStringify — int 42 stringified with enc=SQLITE_UTF8
    T18 sqlite3VdbeMemTooBig — returns true when nByte > limit
    T19 sqlite3VdbeMemRelease — releases dynamic memory (no crash)
    T20 sqlite3ValueNew / sqlite3ValueFree — allocate and free a value
    T21 sqlite3VdbeMemSetStr — dynamic copy (xDel=SQLITE_TRANSIENT)
    T22 sqlite3VdbeIntValue — from MEM_Real 5.9 → 5
    T23 sqlite3VdbeRealValue — from MEM_Int 7 → 7.0

  Gate: T1-T23 all PASS.
}

uses
  SysUtils, Math,
  passqlite3types,
  passqlite3os,
  passqlite3util,
  passqlite3pcache,
  passqlite3pager,
  passqlite3wal,
  passqlite3btree,
  passqlite3vdbe;

{ ===== helpers ============================================================== }

var
  gPass: i32 = 0;
  gFail: i32 = 0;

procedure Check(name: string; cond: Boolean);
begin
  if cond then begin
    WriteLn('  PASS ', name);
    Inc(gPass);
  end else begin
    WriteLn('  FAIL ', name);
    Inc(gFail);
  end;
end;

{ Build a minimal mock sqlite3 block with required fields set.
  enc @ offset 100, nFpDigit @ 114, aLimit[0] @ 136 (SQLITE_LIMIT_LENGTH).
  The buffer is large enough for all vdbeDbXxx helpers. }
function MakeMockDb(enc: u8; limitLen: i32): Psqlite3;
const
  DB_BUF_SIZE = 512;
var
  buf: PByte;
begin
  buf := AllocMem(DB_BUF_SIZE);
  PByte(buf + 100)^ := enc;            { db->enc }
  PByte(buf + 114)^ := 15;             { db->nFpDigit (default 15) }
  Pi32(buf + 136)^  := limitLen;       { db->aLimit[SQLITE_LIMIT_LENGTH] }
  Result := Psqlite3(buf);
end;

procedure FreeMockDb(db: Psqlite3);
begin
  FreeMem(db);
end;

{ Initialise a TMem for use with a mock db (no real sqlite3 plumbing). }
procedure InitMem(var m: TMem; db: Psqlite3);
begin
  FillChar(m, SizeOf(m), 0);
  m.db := db;
end;

{ ===== T1: sqlite3VdbeMemSetNull ============================================ }
procedure TestSetNull;
var m: TMem; db: Psqlite3;
begin
  WriteLn('T1: sqlite3VdbeMemSetNull');
  db := MakeMockDb(SQLITE_UTF8, 1000000);
  InitMem(m, db);
  m.flags := MEM_Int;
  m.u.i   := 99;
  sqlite3VdbeMemSetNull(@m);
  Check('flags=MEM_Null',   (m.flags and MEM_Null) <> 0);
  Check('not MEM_Int',      (m.flags and MEM_Int)  = 0);
  FreeMockDb(db);
end;

{ ===== T2: sqlite3VdbeMemSetInt64 =========================================== }
procedure TestSetInt64;
var m: TMem; db: Psqlite3;
begin
  WriteLn('T2: sqlite3VdbeMemSetInt64');
  db := MakeMockDb(SQLITE_UTF8, 1000000);
  InitMem(m, db);
  sqlite3VdbeMemSetInt64(@m, 12345678);
  Check('flags=MEM_Int',  (m.flags and MEM_Int)  <> 0);
  Check('not MEM_Real',   (m.flags and MEM_Real) = 0);
  Check('value=12345678', m.u.i = 12345678);
  sqlite3VdbeMemSetInt64(@m, -1);
  Check('value=-1', m.u.i = -1);
  FreeMockDb(db);
end;

{ ===== T3-T4: sqlite3VdbeMemSetDouble ======================================= }
procedure TestSetDouble;
var m: TMem; db: Psqlite3;
begin
  WriteLn('T3: sqlite3VdbeMemSetDouble — normal value');
  db := MakeMockDb(SQLITE_UTF8, 1000000);
  InitMem(m, db);
  sqlite3VdbeMemSetDouble(@m, 3.14);
  Check('flags=MEM_Real',  (m.flags and MEM_Real) <> 0);
  Check('not MEM_Int',     (m.flags and MEM_Int)  = 0);
  Check('value≈3.14',      Abs(m.u.r - 3.14) < 1e-12);

  WriteLn('T4: sqlite3VdbeMemSetDouble — NaN → NULL');
  sqlite3VdbeMemSetDouble(@m, NaN);
  Check('NaN→MEM_Null',    (m.flags and MEM_Null) <> 0);
  Check('NaN→not MEM_Real',(m.flags and MEM_Real) = 0);
  FreeMockDb(db);
end;

{ ===== T5: sqlite3VdbeMemSetZeroBlob ======================================== }
procedure TestSetZeroBlob;
var m: TMem; db: Psqlite3;
begin
  WriteLn('T5: sqlite3VdbeMemSetZeroBlob');
  db := MakeMockDb(SQLITE_UTF8, 1000000);
  InitMem(m, db);
  sqlite3VdbeMemSetZeroBlob(@m, 64);
  Check('flags=MEM_Blob',  (m.flags and MEM_Blob) <> 0);
  Check('flags=MEM_Zero',  (m.flags and MEM_Zero) <> 0);
  Check('nZero=64',        m.u.nZero = 64);  { C stores count in u.nZero, not n }
  FreeMockDb(db);
end;

{ ===== T6-T7: sqlite3VdbeMemSetStr ========================================== }
procedure TestSetStr;
var m: TMem; db: Psqlite3;
    s: AnsiString;
begin
  WriteLn('T6: sqlite3VdbeMemSetStr — static string');
  db := MakeMockDb(SQLITE_UTF8, 1000000);
  InitMem(m, db);
  s := 'hello';
  sqlite3VdbeMemSetStr(@m, PAnsiChar(s), 5, SQLITE_UTF8, SQLITE_STATIC);
  Check('MEM_Str',     (m.flags and MEM_Str)    <> 0);
  Check('MEM_Static',  (m.flags and MEM_Static) <> 0);
  Check('n=5',         m.n = 5);

  WriteLn('T7: sqlite3VdbeMemSetStr — blob (enc=0)');
  InitMem(m, db);
  sqlite3VdbeMemSetStr(@m, PAnsiChar(s), 5, 0, SQLITE_STATIC);
  Check('MEM_Blob',    (m.flags and MEM_Blob)   <> 0);
  Check('not MEM_Str', (m.flags and MEM_Str)    = 0);
  FreeMockDb(db);
end;

{ ===== T8-T9: sqlite3VdbeMemIntegerify ====================================== }
procedure TestIntegerify;
var m: TMem; db: Psqlite3;
begin
  db := MakeMockDb(SQLITE_UTF8, 1000000);

  WriteLn('T8: sqlite3VdbeMemIntegerify — real 3.7 → 3');
  InitMem(m, db);
  sqlite3VdbeMemSetDouble(@m, 3.7);
  sqlite3VdbeMemIntegerify(@m);
  Check('flags=MEM_Int',  (m.flags and MEM_Int)  <> 0);
  Check('not MEM_Real',   (m.flags and MEM_Real) = 0);
  Check('value=3',        m.u.i = 3);

  WriteLn('T9: sqlite3VdbeMemIntegerify — real 3.0 → 3');
  InitMem(m, db);
  sqlite3VdbeMemSetDouble(@m, 3.0);
  sqlite3VdbeMemIntegerify(@m);
  Check('flags=MEM_Int',  (m.flags and MEM_Int)  <> 0);
  Check('value=3',        m.u.i = 3);

  FreeMockDb(db);
end;

{ ===== T11: sqlite3VdbeMemRealify =========================================== }
procedure TestRealify;
var m: TMem; db: Psqlite3;
begin
  WriteLn('T10: sqlite3VdbeMemRealify — int 42 → real');
  db := MakeMockDb(SQLITE_UTF8, 1000000);
  InitMem(m, db);
  sqlite3VdbeMemSetInt64(@m, 42);
  sqlite3VdbeMemRealify(@m);
  Check('flags=MEM_Real',  (m.flags and MEM_Real) <> 0);
  Check('value=42.0',      Abs(m.u.r - 42.0) < 1e-12);
  FreeMockDb(db);
end;

{ ===== T12: sqlite3RealSameAsInt =========================================== }
procedure TestRealSameAsInt;
begin
  WriteLn('T11: sqlite3RealSameAsInt');
  Check('3.0 same as int',   sqlite3RealSameAsInt(3.0,  3) <> 0);
  Check('3.1 not same',      sqlite3RealSameAsInt(3.1,  3) = 0);
  Check('0.0 same as 0',     sqlite3RealSameAsInt(0.0,  0) <> 0);
  Check('-1.0 same as -1',   sqlite3RealSameAsInt(-1.0,-1) <> 0);
end;

{ ===== T13-T14: sqlite3VdbeMemNumerify ====================================== }
procedure TestNumerify;
var m: TMem; db: Psqlite3;
    s: AnsiString;
begin
  db := MakeMockDb(SQLITE_UTF8, 1000000);

  WriteLn('T12: sqlite3VdbeMemNumerify — "123" → integer');
  InitMem(m, db);
  s := '123';
  sqlite3VdbeMemSetStr(@m, PAnsiChar(s), 3, SQLITE_UTF8, SQLITE_STATIC);
  sqlite3VdbeMemNumerify(@m);
  Check('"123"→MEM_Int',   (m.flags and MEM_Int)  <> 0);
  Check('"123"→value=123', m.u.i = 123);

  WriteLn('T13: sqlite3VdbeMemNumerify — "1.5" → real');
  InitMem(m, db);
  s := '1.5';
  sqlite3VdbeMemSetStr(@m, PAnsiChar(s), 3, SQLITE_UTF8, SQLITE_STATIC);
  sqlite3VdbeMemNumerify(@m);
  Check('"1.5"→MEM_Real',    (m.flags and MEM_Real) <> 0);
  Check('"1.5"→value≈1.5',   Abs(m.u.r - 1.5) < 1e-12);

  FreeMockDb(db);
end;

{ ===== T15: sqlite3VdbeMemCopy ============================================== }
procedure TestMemCopy;
var src, dst: TMem; db: Psqlite3;
begin
  WriteLn('T14: sqlite3VdbeMemCopy — independent copy');
  db := MakeMockDb(SQLITE_UTF8, 1000000);
  InitMem(src, db);
  InitMem(dst, db);
  sqlite3VdbeMemSetInt64(@src, 999);
  sqlite3VdbeMemCopy(@dst, @src);
  Check('dst MEM_Int',   (dst.flags and MEM_Int) <> 0);
  Check('dst value=999', dst.u.i = 999);
  { mutating src should not affect dst since dst is a copy }
  sqlite3VdbeMemSetInt64(@src, 0);
  Check('dst still 999', dst.u.i = 999);
  FreeMockDb(db);
end;

{ ===== T16: sqlite3VdbeMemShallowCopy ======================================= }
procedure TestShallowCopy;
var src, dst: TMem; db: Psqlite3;
    s: AnsiString;
begin
  WriteLn('T15: sqlite3VdbeMemShallowCopy — shares pointer');
  db := MakeMockDb(SQLITE_UTF8, 1000000);
  InitMem(src, db);
  InitMem(dst, db);
  s := 'static-str';
  sqlite3VdbeMemSetStr(@src, PAnsiChar(s), Length(s), SQLITE_UTF8, SQLITE_STATIC);
  sqlite3VdbeMemShallowCopy(@dst, @src, MEM_Static);
  Check('dst MEM_Str',    (dst.flags and MEM_Str)    <> 0);
  Check('dst MEM_Static', (dst.flags and MEM_Static) <> 0);
  Check('same pointer',   dst.z = src.z);
  FreeMockDb(db);
end;

{ ===== T17: sqlite3VdbeMemMove ============================================== }
procedure TestMemMove;
var src, dst: TMem; db: Psqlite3;
begin
  WriteLn('T16: sqlite3VdbeMemMove — src becomes NULL');
  db := MakeMockDb(SQLITE_UTF8, 1000000);
  InitMem(src, db);
  InitMem(dst, db);
  sqlite3VdbeMemSetInt64(@src, 777);
  sqlite3VdbeMemMove(@dst, @src);
  Check('dst MEM_Int',    (dst.flags and MEM_Int)  <> 0);
  Check('dst value=777',  dst.u.i = 777);
  Check('src is NULL',    (src.flags and MEM_Null) <> 0);
  FreeMockDb(db);
end;

{ ===== T18: sqlite3VdbeMemStringify ========================================= }
procedure TestStringify;
var m: TMem; db: Psqlite3;
begin
  WriteLn('T17: sqlite3VdbeMemStringify — int 42 → "42"');
  db := MakeMockDb(SQLITE_UTF8, 1000000);
  InitMem(m, db);
  sqlite3VdbeMemSetInt64(@m, 42);
  sqlite3VdbeMemStringify(@m, SQLITE_UTF8, 0);
  Check('MEM_Str after stringify', (m.flags and MEM_Str) <> 0);
  Check('still has MEM_Int',       (m.flags and MEM_Int) <> 0);
  Check('z not nil',               m.z <> nil);
  if m.z <> nil then
    Check('"42" in z', StrComp(m.z, '42') = 0);
  sqlite3VdbeMemRelease(@m);
  FreeMockDb(db);
end;

{ ===== T19: sqlite3VdbeMemTooBig ============================================ }
procedure TestTooBig;
var m: TMem; db: Psqlite3;
    s: AnsiString;
begin
  WriteLn('T18: sqlite3VdbeMemTooBig — exceeds limit');
  db := MakeMockDb(SQLITE_UTF8, 10);  { tiny limit=10 }
  { Set TMem fields directly: sqlite3VdbeMemSetStr itself rejects too-big
    strings (nullifies the Mem), so we set up the Mem manually to test TooBig. }
  s := 'this string is longer than 10 bytes';
  InitMem(m, db);
  m.flags := MEM_Str or MEM_Static;
  m.z     := PAnsiChar(s);
  m.n     := Length(s);
  Check('TooBig=true',  sqlite3VdbeMemTooBig(@m) <> 0);

  s := 'short';
  InitMem(m, db);
  m.flags := MEM_Str or MEM_Static;
  m.z     := PAnsiChar(s);
  m.n     := Length(s);
  Check('TooBig=false', sqlite3VdbeMemTooBig(@m) = 0);
  FreeMockDb(db);
end;

{ ===== T20: sqlite3VdbeMemRelease =========================================== }
procedure TestRelease;
var m: TMem; db: Psqlite3;
    s: AnsiString;
begin
  WriteLn('T19: sqlite3VdbeMemRelease — no crash on dynamic mem');
  db := MakeMockDb(SQLITE_UTF8, 1000000);
  InitMem(m, db);
  s := 'hello dynamic';
  { SQLITE_TRANSIENT causes a heap copy — Release must free it }
  sqlite3VdbeMemSetStr(@m, PAnsiChar(s), Length(s), SQLITE_UTF8, SQLITE_TRANSIENT);
  sqlite3VdbeMemRelease(@m);
  Check('flags=MEM_Null after release', (m.flags and MEM_Null) <> 0);
  FreeMockDb(db);
end;

{ ===== T21: sqlite3ValueNew / sqlite3ValueFree ============================== }
procedure TestValueNewFree;
var v: Psqlite3_value; db: Psqlite3;
begin
  WriteLn('T20: sqlite3ValueNew / sqlite3ValueFree');
  db := MakeMockDb(SQLITE_UTF8, 1000000);
  v := sqlite3ValueNew(db);
  Check('ValueNew not nil', v <> nil);
  if v <> nil then begin
    Check('initial MEM_Null', (PMem(v)^.flags and MEM_Null) <> 0);
    sqlite3ValueFree(v);
    Check('no crash after ValueFree', True);
  end;
  FreeMockDb(db);
end;

{ ===== T22: sqlite3VdbeMemSetStr TRANSIENT ================================== }
procedure TestSetStrTransient;
var m: TMem; db: Psqlite3;
    s: AnsiString;
begin
  WriteLn('T21: sqlite3VdbeMemSetStr — SQLITE_TRANSIENT makes a copy');
  db := MakeMockDb(SQLITE_UTF8, 1000000);
  InitMem(m, db);
  s := 'copy-me';
  sqlite3VdbeMemSetStr(@m, PAnsiChar(s), Length(s), SQLITE_UTF8, SQLITE_TRANSIENT);
  Check('MEM_Str',      (m.flags and MEM_Str)    <> 0);
  Check('not static',   (m.flags and MEM_Static) = 0);
  Check('z<>nil',       m.z <> nil);
  Check('different ptr', Pointer(m.z) <> Pointer(PAnsiChar(s)));
  if m.z <> nil then
    Check('content matches', StrComp(m.z, PAnsiChar(s)) = 0);
  sqlite3VdbeMemRelease(@m);
  FreeMockDb(db);
end;

{ ===== T22: sqlite3VdbeIntValue ============================================= }
procedure TestVdbeIntValue;
var m: TMem; db: Psqlite3;
begin
  WriteLn('T22: sqlite3VdbeIntValue — from MEM_Real 5.9 → 5');
  db := MakeMockDb(SQLITE_UTF8, 1000000);
  InitMem(m, db);
  sqlite3VdbeMemSetDouble(@m, 5.9);
  Check('VdbeIntValue=5', sqlite3VdbeIntValue(@m) = 5);

  sqlite3VdbeMemSetInt64(@m, -100);
  Check('VdbeIntValue=-100', sqlite3VdbeIntValue(@m) = -100);
  FreeMockDb(db);
end;

{ ===== T23: sqlite3VdbeRealValue ============================================ }
procedure TestVdbeRealValue;
var m: TMem; db: Psqlite3;
begin
  WriteLn('T23: sqlite3VdbeRealValue — from MEM_Int 7 → 7.0');
  db := MakeMockDb(SQLITE_UTF8, 1000000);
  InitMem(m, db);
  sqlite3VdbeMemSetInt64(@m, 7);
  Check('VdbeRealValue=7.0', Abs(sqlite3VdbeRealValue(@m) - 7.0) < 1e-12);

  sqlite3VdbeMemSetDouble(@m, 2.5);
  Check('VdbeRealValue=2.5', Abs(sqlite3VdbeRealValue(@m) - 2.5) < 1e-12);
  FreeMockDb(db);
end;

{ ===== main ================================================================= }
begin
  WriteLn('=== TestVdbeMem (Phase 5.3) ===');
  WriteLn;

  TestSetNull;
  TestSetInt64;
  TestSetDouble;
  TestSetZeroBlob;
  TestSetStr;
  TestIntegerify;
  TestRealify;
  TestRealSameAsInt;
  TestNumerify;
  TestMemCopy;
  TestShallowCopy;
  TestMemMove;
  TestStringify;
  TestTooBig;
  TestRelease;
  TestValueNewFree;
  TestSetStrTransient;
  TestVdbeIntValue;
  TestVdbeRealValue;

  WriteLn;
  WriteLn(Format('Results: %d PASS, %d FAIL', [gPass, gFail]));
  if gFail > 0 then Halt(1);
end.
