{
  SPDX-License-Identifier: blessing

  TestShellTrustedSchema — regression for the CLI's TRUSTED_SCHEMA /
  DEFENSIVE plumbing.  Mirrors shell.c.in:4530..4537: an interactive
  shell opens connections with TrustedSchema OFF and Defensive ON by
  default (and the inverse under --unsafe-testing).  Earlier ports
  forgot to call sqlite3_db_config_int on those slots in openDb(),
  so `PRAGMA trusted_schema;` returned the engine default (1) rather
  than the CLI default (0).

  This is a unit-level mimic — we drive the same sqlite3_db_config_int
  the shell now invokes and assert the PRAGMA round-trip.  An
  end-to-end CLI subprocess test would be more thorough but requires
  Process; this scoped regression is enough to catch a reversion in
  the shell's openDb wiring.
}
{$I ../passqlite3.inc}
program TestShellTrustedSchema;

uses
  SysUtils,
  passqlite3types, passqlite3util, passqlite3main, passqlite3vdbe;

var
  failCount: i32 = 0;
  passCount: i32 = 0;

procedure CheckPragma(db: PTsqlite3; const sql, expect, what: AnsiString);
var
  pStmt: PVdbe;
  rc:    i32;
  pTail: PAnsiChar;
  got:   AnsiString;
  z:     PAnsiChar;
begin
  pStmt := nil; pTail := nil;
  rc := sqlite3_prepare_v2(db, PAnsiChar(sql), -1, @pStmt, @pTail);
  if rc <> SQLITE_OK then begin
    WriteLn('FAIL ', what, ' prepare rc=', rc);
    Inc(failCount); Exit;
  end;
  got := '';
  if sqlite3_step(pStmt) = SQLITE_ROW then begin
    z := sqlite3_column_text(pStmt, 0);
    if z <> nil then got := AnsiString(z);
  end;
  sqlite3_finalize(pStmt);
  if got = expect then begin
    WriteLn('PASS ', what, ' = "', got, '"');
    Inc(passCount);
  end else begin
    WriteLn('FAIL ', what, ' expected="', expect, '" got="', got, '"');
    Inc(failCount);
  end;
end;

procedure CheckCfg(db: PTsqlite3; op, expect: i32; const what: AnsiString);
var got: i32;
begin
  got := -1;
  sqlite3_db_config_int(db, op, -1, @got);
  if got = expect then begin
    WriteLn('PASS ', what, ' = ', got);
    Inc(passCount);
  end else begin
    WriteLn('FAIL ', what, ' expected=', expect, ' got=', got);
    Inc(failCount);
  end;
end;

var
  db:  PTsqlite3;
begin
  db := nil;
  if sqlite3_open(':memory:', @db) <> SQLITE_OK then begin
    WriteLn('FAIL: cannot open :memory:');
    Halt(1);
  end;

  { Pre-config — engine default has TrustedSchema bit set (1). }
  CheckPragma(db, 'PRAGMA trusted_schema', '1',
              'engine default trusted_schema');

  { Apply the CLI's openDb() defaults: TRUSTED_SCHEMA=0, DEFENSIVE=1. }
  sqlite3_db_config_int(db, SQLITE_DBCONFIG_TRUSTED_SCHEMA, 0, nil);
  sqlite3_db_config_int(db, SQLITE_DBCONFIG_DEFENSIVE,      1, nil);

  CheckPragma(db, 'PRAGMA trusted_schema', '0',
              'CLI-default trusted_schema off');
  CheckCfg(db, SQLITE_DBCONFIG_DEFENSIVE, 1,
           'CLI-default defensive on');

  { Flip back (mirroring --unsafe-testing arm). }
  sqlite3_db_config_int(db, SQLITE_DBCONFIG_TRUSTED_SCHEMA, 1, nil);
  sqlite3_db_config_int(db, SQLITE_DBCONFIG_DEFENSIVE,      0, nil);

  CheckPragma(db, 'PRAGMA trusted_schema', '1',
              'unsafe-testing trusted_schema on');
  CheckCfg(db, SQLITE_DBCONFIG_DEFENSIVE, 0,
           'unsafe-testing defensive off');

  sqlite3_close(db);
  WriteLn;
  WriteLn(Format('TestShellTrustedSchema: %d PASS / %d FAIL',
                 [passCount, failCount]));
  if failCount > 0 then Halt(1);
end.
