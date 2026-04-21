{$I ../passqlite3.inc}
program TestUtil;

{
  Phase 2 differential tests for passqlite3util.

  Tests:
    T1  Varint round-trip: encode with sqlite3PutVarint, decode with
        sqlite3GetVarint. Verify size and value at boundary values.
    T2  Big-endian accessors: sqlite3Get4byte / sqlite3Put4byte round-trip.
    T3  sqlite3StrICmp: case-insensitive comparison ordering.
    T4  sqlite3AtoF: parse "3.14", "1e100", "-0.0".
    T5  PRNG: reset and generate 32 bytes; verify non-zero output and
        reproducibility after save/restore state.
    T6  Hash table: insert 20 pairs, look up all, verify values.
    T7  Bitvec: create, set, test, clear bits.

  Prints PASS/FAIL per test.  Exits 0 if ALL PASS, 1 on first failure.
}

uses
  SysUtils,
  BaseUnix,
  UnixType,
  passqlite3types,
  passqlite3os,
  passqlite3util;

{ ------------------------------------------------------------------ helpers }

var
  gAllPass: Boolean = True;

procedure Fail(const test, msg: string);
begin
  WriteLn('FAIL [', test, ']: ', msg);
  gAllPass := False;
end;

procedure Pass(const test: string);
begin
  WriteLn('PASS [', test, ']');
end;

{ ------------------------------------------------------------------ T1: Varint }

procedure T1_Varint;
const
  { boundary values for varint encoding }
  values: array[0..11] of u64 = (
    0, 1, 127, 128, 16383, 16384, 2097151, 2097152,
    268435455, 268435456, u64($7FFFFFFFFFFFFFFF), u64($FFFFFFFFFFFFFFFF)
  );
  { expected encoded lengths }
  expected_len: array[0..11] of i32 = (
    1, 1, 1, 2, 2, 3, 3, 4, 4, 5, 9, 9
  );
var
  i:   i32;
  buf: array[0..9] of u8;
  v:   u64;
  n:   i32;
  nb:  u8;
  ok:  Boolean;
begin
  ok := True;
  for i := 0 to 11 do begin
    FillChar(buf, SizeOf(buf), 0);
    n := sqlite3PutVarint(@buf[0], values[i]);
    if n <> expected_len[i] then begin
      Fail('T1', Format('value %u: PutVarint returned %d, expected %d',
        [values[i], n, expected_len[i]]));
      ok := False;
      Continue;
    end;
    { decode }
    v := 0;
    if (buf[0] and $80) = 0 then begin
      v := buf[0];
      nb := 1;
    end else
      nb := sqlite3GetVarint(@buf[0], v);
    if v <> values[i] then begin
      Fail('T1', Format('value %u: GetVarint returned %u', [values[i], v]));
      ok := False;
    end;
    if nb <> u8(n) then begin
      Fail('T1', Format('value %u: GetVarint read %d bytes, PutVarint wrote %d',
        [values[i], nb, n]));
      ok := False;
    end;
  end;
  if ok then Pass('T1: Varint round-trip');
end;

{ ------------------------------------------------------------------ T2: Big-endian }

procedure T2_BigEndian;
const
  vals: array[0..4] of u32 = (0, 1, $FF, $12345678, $FFFFFFFF);
var
  i:         i32;
  buf:       array[0..3] of u8;
  v:         u32;
  ok:        Boolean;
  expected0: u8;
begin
  ok := True;
  for i := 0 to 4 do begin
    sqlite3Put4byte(@buf[0], vals[i]);
    v := sqlite3Get4byte(@buf[0]);
    if v <> vals[i] then begin
      Fail('T2', Format('Put/Get4byte round-trip failed for $%08X: got $%08X',
        [vals[i], v]));
      ok := False;
    end;
    { verify byte order: MSB first }
    if vals[i] > 0 then begin
      expected0 := u8(vals[i] shr 24);
      if buf[0] <> expected0 then begin
        Fail('T2', Format('Byte order wrong for $%08X: buf[0]=$%02X expected $%02X',
          [vals[i], buf[0], expected0]));
        ok := False;
      end;
    end;
  end;
  if ok then Pass('T2: Big-endian Put/Get4byte');
end;

{ ------------------------------------------------------------------ T3: StrICmp }

procedure T3_StrICmp;
var ok: Boolean;
begin
  ok := True;
  { Equal strings, different case }
  if sqlite3StrICmp('hello', 'HELLO') <> 0 then begin
    Fail('T3', '"hello" vs "HELLO" should be 0'); ok := False;
  end;
  if sqlite3StrICmp('', '') <> 0 then begin
    Fail('T3', 'empty vs empty should be 0'); ok := False;
  end;
  { Ordering }
  if sqlite3StrICmp('abc', 'abd') >= 0 then begin
    Fail('T3', '"abc" should be < "abd"'); ok := False;
  end;
  if sqlite3StrICmp('B', 'a') <= 0 then begin
    Fail('T3', '"B" should be > "a" (b > a)'); ok := False;
  end;
  if ok then Pass('T3: sqlite3StrICmp');
end;

{ ------------------------------------------------------------------ T4: AtoF }

procedure T4_AtoF;
var
  d:  Double;
  rc: i32;
  ok: Boolean;
begin
  ok := True;

  rc := sqlite3AtoF('3.14', d);
  if (rc = 0) or (Abs(d - 3.14) > 1e-10) then begin
    Fail('T4', Format('"3.14" -> rc=%d d=%g', [rc, d])); ok := False;
  end;

  rc := sqlite3AtoF('1e100', d);
  if (rc = 0) or (d < 1e99) then begin
    Fail('T4', Format('"1e100" -> rc=%d d=%g', [rc, d])); ok := False;
  end;

  rc := sqlite3AtoF('-0.0', d);
  if rc = 0 then begin
    Fail('T4', Format('"-0.0" -> rc=%d should be non-zero', [rc])); ok := False;
  end;

  if ok then Pass('T4: sqlite3AtoF');
end;

{ ------------------------------------------------------------------ T5: PRNG }

procedure T5_PRNG;
var
  buf1, buf2: array[0..31] of u8;
  i:   i32;
  ok:  Boolean;
begin
  ok := True;
  sqlite3_os_init;

  { Reset the PRNG by requesting 0 bytes }
  sqlite3_randomness(0, nil);

  { Generate 32 bytes }
  FillChar(buf1, SizeOf(buf1), 0);
  sqlite3_randomness(32, @buf1[0]);

  { Check not all zero }
  ok := False;
  for i := 0 to 31 do if buf1[i] <> 0 then begin ok := True; break; end;
  if not ok then begin
    Fail('T5', 'PRNG produced all-zero output'); Exit;
  end;

  { Save state, generate another 32, restore, generate again — should match }
  sqlite3PrngSaveState;
  FillChar(buf2, SizeOf(buf2), 0);
  sqlite3_randomness(32, @buf2[0]);
  sqlite3PrngRestoreState;
  FillChar(buf1, SizeOf(buf1), 0);
  sqlite3_randomness(32, @buf1[0]);

  for i := 0 to 31 do begin
    if buf1[i] <> buf2[i] then begin
      Fail('T5', Format('PRNG not deterministic after restore at byte %d', [i]));
      ok := False;
      break;
    end;
  end;

  if ok then Pass('T5: PRNG save/restore determinism');
end;

{ ------------------------------------------------------------------ T6: Hash }

procedure T6_Hash;
const
  N = 20;
var
  h:    THash;
  keys: array[0..N-1] of string;
  vals: array[0..N-1] of i32;
  i:    i32;
  p:    Pointer;
  ok:   Boolean;
begin
  ok := True;
  sqlite3HashInit(@h);

  for i := 0 to N-1 do begin
    keys[i] := Format('key_%d', [i]);
    vals[i] := i * 7 + 3;
    sqlite3HashInsert(@h, PChar(keys[i]), Pointer(PtrUInt(vals[i])));
  end;

  { Look up all }
  for i := 0 to N-1 do begin
    p := sqlite3HashFind(@h, PChar(keys[i]));
    if PtrUInt(p) <> PtrUInt(vals[i]) then begin
      Fail('T6', Format('key "%s": expected %d got %d',
        [keys[i], vals[i], PtrInt(p)]));
      ok := False;
    end;
  end;

  { Look up non-existent }
  p := sqlite3HashFind(@h, 'no_such_key');
  if p <> nil then begin
    Fail('T6', 'non-existent key should return nil'); ok := False;
  end;

  { Remove one }
  sqlite3HashInsert(@h, PChar(keys[5]), nil);
  p := sqlite3HashFind(@h, PChar(keys[5]));
  if p <> nil then begin
    Fail('T6', 'removed key should return nil'); ok := False;
  end;

  sqlite3HashClear(@h);
  if ok then Pass('T6: Hash table insert/find/remove');
end;

{ ------------------------------------------------------------------ T7: Bitvec }

procedure T7_Bitvec;
var
  bv:  PBitvec;
  buf: array[0..BITVEC_SZ-1] of u8;
  ok:  Boolean;
  rc:  i32;
begin
  ok := True;
  bv := sqlite3BitvecCreate(1000);
  if bv = nil then begin
    Fail('T7', 'sqlite3BitvecCreate returned nil'); Exit;
  end;

  { Set some bits }
  rc := sqlite3BitvecSet(bv, 1);
  if rc <> SQLITE_OK then begin Fail('T7', 'Set(1) failed'); ok := False; end;
  rc := sqlite3BitvecSet(bv, 500);
  if rc <> SQLITE_OK then begin Fail('T7', 'Set(500) failed'); ok := False; end;
  rc := sqlite3BitvecSet(bv, 1000);
  if rc <> SQLITE_OK then begin Fail('T7', 'Set(1000) failed'); ok := False; end;

  { Test set bits }
  if sqlite3BitvecTest(bv, 1) = 0 then begin Fail('T7', 'Test(1) should be 1'); ok := False; end;
  if sqlite3BitvecTest(bv, 500) = 0 then begin Fail('T7', 'Test(500) should be 1'); ok := False; end;
  if sqlite3BitvecTest(bv, 1000) = 0 then begin Fail('T7', 'Test(1000) should be 1'); ok := False; end;

  { Test clear bits }
  if sqlite3BitvecTest(bv, 2) <> 0 then begin Fail('T7', 'Test(2) should be 0'); ok := False; end;
  if sqlite3BitvecTest(bv, 999) <> 0 then begin Fail('T7', 'Test(999) should be 0'); ok := False; end;

  { Clear a bit }
  sqlite3BitvecClear(bv, 500, @buf[0]);
  if sqlite3BitvecTest(bv, 500) <> 0 then begin Fail('T7', 'Test(500) after clear should be 0'); ok := False; end;
  if sqlite3BitvecTest(bv, 1) = 0 then begin Fail('T7', 'Test(1) should still be 1 after clear(500)'); ok := False; end;

  { Test nil bitvec }
  if sqlite3BitvecTest(nil, 1) <> 0 then begin Fail('T7', 'Test(nil, 1) should be 0'); ok := False; end;

  { Size }
  if sqlite3BitvecSize(bv) <> 1000 then begin Fail('T7', 'Size should be 1000'); ok := False; end;

  sqlite3BitvecDestroy(bv);
  if ok then Pass('T7: Bitvec set/test/clear');
end;

{ ------------------------------------------------------------------ main }

begin
  sqlite3_os_init;

  T1_Varint;
  T2_BigEndian;
  T3_StrICmp;
  T4_AtoF;
  T5_PRNG;
  T6_Hash;
  T7_Bitvec;

  if gAllPass then
    WriteLn('ALL PASS')
  else begin
    WriteLn('SOME TESTS FAILED');
    Halt(1);
  end;
end.
