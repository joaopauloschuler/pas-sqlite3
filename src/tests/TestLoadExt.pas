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
{$I ../passqlite3.inc}
program TestLoadExt;

{
  Phase 8.9 gate — exercise loadext.c shims.

  Build configuration sets SQLITE_OMIT_LOAD_EXTENSION, so:
    * sqlite3_load_extension          → SQLITE_ERROR + "extension loading
                                         is disabled" message
    * sqlite3_enable_load_extension   → toggles the SQLITE_LoadExtension
                                         flag bit (no actual loader)
    * sqlite3_auto_extension          → faithful list management
    * sqlite3_cancel_auto_extension   → faithful, returns 1 on hit / 0 miss
    * sqlite3_reset_auto_extension    → faithful, drains the list

  T1  load_extension(db=nil)                    -> SQLITE_MISUSE
  T2  load_extension(db, "foo.so", nil, &msg)   -> SQLITE_ERROR + msg set
  T3  enable_load_extension(db=nil)             -> SQLITE_MISUSE
  T4  enable_load_extension(db, 1)              -> SQLITE_OK, flag set
  T5  enable_load_extension(db, 0)              -> SQLITE_OK, flag cleared
  T6  auto_extension(nil)                       -> SQLITE_MISUSE
  T7  auto_extension(F1) twice (idempotent)     -> OK
  T8  auto_extension(F2) (distinct fn appended) -> OK
  T9  cancel_auto_extension(F1)                 -> 1 (hit)
  T10 cancel_auto_extension(F1) again           -> 0 (miss)
  T11 cancel_auto_extension(nil)                -> 0 (no-op)
  T12 reset_auto_extension; cancel(F2)          -> 0 (drained)
}

uses
  SysUtils,
  passqlite3types,
  passqlite3util,
  passqlite3os,
  passqlite3vdbe,
  passqlite3codegen,
  passqlite3main;

var
  gPass, gFail: i32;

procedure Expect(cond: Boolean; const msg: AnsiString);
begin
  if cond then begin Inc(gPass); WriteLn('  PASS ', msg); end
  else        begin Inc(gFail); WriteLn('  FAIL ', msg); end;
end;

procedure ExpectEq(a, b: i32; const msg: AnsiString);
begin
  Expect(a = b, msg + ' (got ' + IntToStr(a) + ', expected ' + IntToStr(b) + ')');
end;

procedure ExtFn1; cdecl; begin end;
procedure ExtFn2; cdecl; begin end;

var
  db        : PTsqlite3;
  rc        : i32;
  zErr      : PAnsiChar;
  msg       : AnsiString;
  flagBefore, flagAfter: u64;

begin
  gPass := 0; gFail := 0;
  WriteLn('TestLoadExt — Phase 8.9 loadext.c shims');

  db := nil;
  rc := sqlite3_open(':memory:', @db);
  ExpectEq(rc, SQLITE_OK, 'open(:memory:)');
  if (rc <> SQLITE_OK) or (db = nil) then begin
    WriteLn('  open failed — aborting'); Halt(1);
  end;

  { T1 }
  rc := sqlite3_load_extension(nil, 'foo.so', nil, nil);
  ExpectEq(rc, SQLITE_MISUSE, 'T1 load_extension(db=nil)');

  { T2 }
  zErr := nil;
  rc := sqlite3_load_extension(db, 'foo.so', nil, @zErr);
  ExpectEq(rc, SQLITE_ERROR, 'T2 load_extension rc');
  Expect(zErr <> nil, 'T2 zErr non-nil');
  if zErr <> nil then begin
    msg := AnsiString(zErr);
    Expect(msg = 'extension loading is disabled', 'T2 msg=' + msg);
    sqlite3_free(zErr);
  end;

  { T3 }
  rc := sqlite3_enable_load_extension(nil, 1);
  ExpectEq(rc, SQLITE_MISUSE, 'T3 enable_load_extension(db=nil)');

  { T4 / T5 }
  flagBefore := db^.flags;
  rc := sqlite3_enable_load_extension(db, 1);
  ExpectEq(rc, SQLITE_OK, 'T4 enable rc');
  flagAfter := db^.flags;
  Expect((flagAfter and u64($00010000)) <> 0, 'T4 SQLITE_LoadExtension bit set');

  rc := sqlite3_enable_load_extension(db, 0);
  ExpectEq(rc, SQLITE_OK, 'T5 enable(0) rc');
  Expect((db^.flags and u64($00010000)) = 0, 'T5 SQLITE_LoadExtension bit cleared');
  Expect(flagBefore = db^.flags, 'T5 round-trip preserves other flag bits');

  { T6 }
  rc := sqlite3_auto_extension(nil);
  ExpectEq(rc, SQLITE_MISUSE, 'T6 auto_extension(nil)');

  { Drain any prior state from the process-global list. }
  sqlite3_reset_auto_extension;

  { T7 }
  rc := sqlite3_auto_extension(@ExtFn1);
  ExpectEq(rc, SQLITE_OK, 'T7a auto_extension(ExtFn1) #1');
  rc := sqlite3_auto_extension(@ExtFn1);
  ExpectEq(rc, SQLITE_OK, 'T7b auto_extension(ExtFn1) #2 (idempotent OK)');

  { T8 }
  rc := sqlite3_auto_extension(@ExtFn2);
  ExpectEq(rc, SQLITE_OK, 'T8 auto_extension(ExtFn2)');

  { T9 }
  ExpectEq(sqlite3_cancel_auto_extension(@ExtFn1), 1, 'T9 cancel(ExtFn1) hit');

  { T10 }
  ExpectEq(sqlite3_cancel_auto_extension(@ExtFn1), 0, 'T10 cancel(ExtFn1) miss');

  { T11 }
  ExpectEq(sqlite3_cancel_auto_extension(nil), 0, 'T11 cancel(nil)');

  { T12 }
  sqlite3_reset_auto_extension;
  ExpectEq(sqlite3_cancel_auto_extension(@ExtFn2), 0, 'T12 cancel(ExtFn2) after reset');

  ExpectEq(sqlite3_close(db), SQLITE_OK, 'close');

  WriteLn;
  WriteLn('TestLoadExt summary: ', gPass, ' pass, ', gFail, ' fail');
  if gFail = 0 then Halt(0) else Halt(1);
end.
