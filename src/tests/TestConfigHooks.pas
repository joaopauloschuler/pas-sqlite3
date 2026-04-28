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
program TestConfigHooks;

{
  Phase 8.4 gate — exercise sqlite3_config / sqlite3_db_config /
  sqlite3_busy_handler / sqlite3_busy_timeout / sqlite3_commit_hook /
  sqlite3_rollback_hook / sqlite3_update_hook / sqlite3_trace_v2.

  Each hook is verified to install (returns prior pArg) and to record
  its callback in db^.  Db_config flag toggles round-trip via the
  pRes out-parameter.
}

uses
  SysUtils,
  passqlite3types,
  passqlite3util,
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

{ Dummy callbacks. }
function DummyBusy(p: Pointer; n: i32): i32; cdecl;
begin Result := 0; end;

function DummyCommit(p: Pointer): i32; cdecl;
begin Result := 0; end;

procedure DummyRollback(p: Pointer); cdecl;
begin end;

procedure DummyUpdate(p: Pointer; op: i32;
  zDb, zTbl: PAnsiChar; rowid: i64); cdecl;
begin end;

function DummyTrace(n: u32; p, x, y: Pointer): i32; cdecl;
begin Result := 0; end;

var
  db:  PTsqlite3;
  rc:  i32;
  pOld: Pointer;
  outFlag: i32;
  marker: array[0..3] of Byte;

begin
  gPass := 0; gFail := 0;
  WriteLn('TestConfigHooks — Phase 8.4 gate');

  rc := sqlite3_open_v2(':memory:', @db,
          SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE, nil);
  ExpectEq(rc, SQLITE_OK, 'T1 open :memory:');

  { ---------------- busy_handler / busy_timeout ---------------- }
  rc := sqlite3_busy_handler(db, @DummyBusy, @marker);
  ExpectEq(rc, SQLITE_OK, 'T2 busy_handler ok');
  Expect(db^.busyHandler.pBusyArg = @marker, 'T2b busyHandler.pBusyArg installed');

  rc := sqlite3_busy_timeout(db, 5000);
  ExpectEq(rc, SQLITE_OK, 'T3 busy_timeout(5000)');
  ExpectEq(db^.busyTimeout, 5000, 'T3b busyTimeout recorded');
  Expect(db^.busyHandler.xBusyHandler <> nil, 'T3c default busy callback installed');

  rc := sqlite3_busy_timeout(db, 0);
  ExpectEq(rc, SQLITE_OK, 'T4 busy_timeout(0)');
  Expect(db^.busyHandler.xBusyHandler = nil, 'T4b busy callback cleared');
  ExpectEq(db^.busyTimeout, 0, 'T4c busyTimeout zeroed');

  { MISUSE on nil db. }
  rc := sqlite3_busy_handler(nil, @DummyBusy, nil);
  ExpectEq(rc, SQLITE_MISUSE, 'T5 busy_handler(nil) MISUSE');

  { ---------------- commit / rollback / update hooks ---------------- }
  pOld := sqlite3_commit_hook(db, @DummyCommit, @marker);
  Expect(pOld = nil, 'T6 commit_hook first call returns nil');
  Expect(db^.pCommitArg = @marker, 'T6b pCommitArg installed');
  pOld := sqlite3_commit_hook(db, nil, nil);
  Expect(pOld = @marker, 'T6c commit_hook returns prior pArg');

  pOld := sqlite3_rollback_hook(db, @DummyRollback, @marker);
  Expect(pOld = nil, 'T7 rollback_hook first call returns nil');
  Expect(db^.pRollbackArg = @marker, 'T7b pRollbackArg installed');

  pOld := sqlite3_update_hook(db, @DummyUpdate, @marker);
  Expect(pOld = nil, 'T8 update_hook first call returns nil');
  Expect(db^.pUpdateArg = @marker, 'T8b pUpdateArg installed');

  { ---------------- trace_v2 ---------------- }
  rc := sqlite3_trace_v2(db, SQLITE_TRACE_STMT or SQLITE_TRACE_PROFILE,
                         @DummyTrace, @marker);
  ExpectEq(rc, SQLITE_OK, 'T9 trace_v2 ok');
  ExpectEq(db^.mTrace, SQLITE_TRACE_STMT or SQLITE_TRACE_PROFILE, 'T9b mTrace mask');
  Expect(db^.trace.xV2 <> nil, 'T9c trace.xV2 installed');

  { mTrace=0 implies xTrace=nil and full clear. }
  rc := sqlite3_trace_v2(db, 0, @DummyTrace, nil);
  ExpectEq(rc, SQLITE_OK, 'T10 trace_v2(mTrace=0)');
  ExpectEq(db^.mTrace, 0, 'T10b mTrace cleared');
  Expect(db^.trace.xV2 = nil, 'T10c trace.xV2 cleared');

  { ---------------- db_config — flag toggles ---------------- }
  outFlag := -1;
  rc := sqlite3_db_config_int(db, SQLITE_DBCONFIG_ENABLE_FKEY, 1, @outFlag);
  ExpectEq(rc, SQLITE_OK, 'T11 db_config ENABLE_FKEY=1');
  ExpectEq(outFlag, 1, 'T11b out=1');
  Expect((db^.flags and SQLITE_ForeignKeys) <> 0, 'T11c ForeignKeys flag set');

  outFlag := -1;
  rc := sqlite3_db_config_int(db, SQLITE_DBCONFIG_ENABLE_FKEY, 0, @outFlag);
  ExpectEq(rc, SQLITE_OK, 'T12 db_config ENABLE_FKEY=0');
  ExpectEq(outFlag, 0, 'T12b out=0');
  Expect((db^.flags and SQLITE_ForeignKeys) = 0, 'T12c ForeignKeys flag cleared');

  { Probe-only: onoff < 0 leaves flag untouched but reports current state. }
  rc := sqlite3_db_config_int(db, SQLITE_DBCONFIG_ENABLE_TRIGGER, 1, nil);
  ExpectEq(rc, SQLITE_OK, 'T13 db_config ENABLE_TRIGGER=1 (no out)');
  outFlag := -1;
  rc := sqlite3_db_config_int(db, SQLITE_DBCONFIG_ENABLE_TRIGGER, -1, @outFlag);
  ExpectEq(rc, SQLITE_OK, 'T14 db_config ENABLE_TRIGGER probe');
  ExpectEq(outFlag, 1, 'T14b probe reports 1');

  { Unknown op → SQLITE_ERROR. }
  rc := sqlite3_db_config_int(db, 9999, 0, nil);
  ExpectEq(rc, SQLITE_ERROR, 'T15 db_config unknown op → ERROR');

  { ---------------- db_config FP_DIGITS ---------------- }
  outFlag := -1;
  rc := sqlite3_db_config_int(db, SQLITE_DBCONFIG_FP_DIGITS, 12, @outFlag);
  ExpectEq(rc, SQLITE_OK, 'T16 db_config FP_DIGITS=12');
  ExpectEq(outFlag, 12, 'T16b FP_DIGITS read back');
  ExpectEq(db^.nFpDigit, 12, 'T16c db^.nFpDigit set');

  { ---------------- db_config MAINDBNAME ---------------- }
  rc := sqlite3_db_config_text(db, SQLITE_DBCONFIG_MAINDBNAME, 'altname');
  ExpectEq(rc, SQLITE_OK, 'T17 db_config MAINDBNAME');
  Expect(StrComp(db^.aDb[0].zDbSName, 'altname') = 0, 'T17b zDbSName updated');

  { ---------------- db_config LOOKASIDE ---------------- }
  rc := sqlite3_db_config_lookaside(db, SQLITE_DBCONFIG_LOOKASIDE, nil, 64, 16);
  ExpectEq(rc, SQLITE_OK, 'T18 db_config LOOKASIDE(64,16)');
  ExpectEq(i32(db^.lookaside.sz), 64, 'T18b sz=64');
  ExpectEq(i32(db^.lookaside.nSlot), 16, 'T18c nSlot=16');

  rc := sqlite3_db_config_lookaside(db, SQLITE_DBCONFIG_LOOKASIDE, nil, 0, 0);
  ExpectEq(rc, SQLITE_OK, 'T19 db_config LOOKASIDE(0,0) disables');
  ExpectEq(i32(db^.lookaside.sz), 0, 'T19b sz=0');
  ExpectEq(i32(db^.lookaside.bDisable), 1, 'T19c bDisable=1');

  { ---------------- sqlite3_config (int shape) ---------------- }
  { sqlite3_open now eagerly wires sqlite3_initialize (sub-progress
    16(a) — required for built-in function lookup on the codegen
    path), so isInit=1 here.  sqlite3_config requires isInit=0; close
    the connection and shutdown to reset, mirroring the real SQLite
    requirement. }
  rc := sqlite3_close_v2(db);
  ExpectEq(rc, SQLITE_OK, 'T19d close_v2 before shutdown');
  sqlite3_shutdown;
  db := nil;
  rc := sqlite3_config(SQLITE_CONFIG_URI, 1);
  ExpectEq(rc, SQLITE_OK, 'T20 sqlite3_config(URI=1)');
  ExpectEq(sqlite3GlobalConfig.bOpenUri, 1, 'T20b bOpenUri=1');
  rc := sqlite3_config(SQLITE_CONFIG_URI, 0);
  ExpectEq(rc, SQLITE_OK, 'T21 sqlite3_config(URI=0)');

  rc := sqlite3_config(SQLITE_CONFIG_SINGLETHREAD, 0);
  ExpectEq(rc, SQLITE_OK, 'T22 sqlite3_config(SINGLETHREAD)');
  ExpectEq(sqlite3GlobalConfig.bCoreMutex, 0, 'T22b bCoreMutex=0');
  rc := sqlite3_config(SQLITE_CONFIG_SERIALIZED, 0);
  ExpectEq(rc, SQLITE_OK, 'T23 sqlite3_config(SERIALIZED)');
  ExpectEq(sqlite3GlobalConfig.bCoreMutex, 1, 'T23b bCoreMutex=1');
  ExpectEq(sqlite3GlobalConfig.bFullMutex, 1, 'T23c bFullMutex=1');

  rc := sqlite3_config(9999, 0);
  ExpectEq(rc, SQLITE_MISUSE, 'T24 sqlite3_config unknown op → MISUSE');

  { db already closed before shutdown; T25 was the explicit close. }

  WriteLn;
  WriteLn('Result: ', gPass, ' passed, ', gFail, ' failed');
  if gFail > 0 then Halt(1);
end.
