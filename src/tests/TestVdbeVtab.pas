{$I passqlite3.inc}
program TestVdbeVtab;
{
  Phase 5.9 gate test — vdbevtab.c bytecode virtual-table stub.

  SQLITE_ENABLE_BYTECODE_VTAB is not set in our target configuration.
  sqlite3VdbeBytecodeVtabInit is therefore a no-op that returns SQLITE_OK.

    T1  sqlite3VdbeBytecodeVtabInit(@db) → SQLITE_OK
    T2  sqlite3VdbeBytecodeVtabInit(nil) → SQLITE_OK  (no crash on nil db)

  Gate: T1–T2 all PASS.
}

uses
  SysUtils,
  passqlite3types,
  passqlite3os,
  passqlite3util,
  passqlite3pcache,
  passqlite3pager,
  passqlite3wal,
  passqlite3btree,
  passqlite3vdbe;

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

{ ===== T1: normal db pointer ================================================ }

procedure TestWithDb;
var
  db: Tsqlite3;
  rc: i32;
begin
  WriteLn('T1: sqlite3VdbeBytecodeVtabInit(@db) → SQLITE_OK');
  FillChar(db, SizeOf(db), 0);
  db.enc := SQLITE_UTF8;
  rc := sqlite3VdbeBytecodeVtabInit(@db);
  Check('T1 rc=OK', rc = SQLITE_OK);
end;

{ ===== T2: nil db — must not crash ========================================= }

procedure TestWithNilDb;
var
  rc: i32;
begin
  WriteLn('T2: sqlite3VdbeBytecodeVtabInit(nil) → SQLITE_OK');
  rc := sqlite3VdbeBytecodeVtabInit(nil);
  Check('T2 rc=OK', rc = SQLITE_OK);
end;

{ ===== main ================================================================= }

begin
  sqlite3OsInit;
  sqlite3PcacheInitialize;

  WriteLn('=== TestVdbeVtab — Phase 5.9 gate test ===');
  WriteLn;

  TestWithDb;   WriteLn;
  TestWithNilDb; WriteLn;

  WriteLn(Format('Results: %d passed, %d failed', [gPass, gFail]));
  if gFail > 0 then Halt(1);
end.
