{$I passqlite3.inc}
program DiagPubApi;
{
  Smoke test for the Phase 8.1.1 / 8.4.1 public-API additions:
    sqlite3_libversion / _libversion_number / _sourceid / _threadsafe
    sqlite3_changes / _changes64 / _total_changes / _total_changes64
    sqlite3_last_insert_rowid / _set_last_insert_rowid
    sqlite3_get_autocommit / _db_readonly
    sqlite3_errcode / _extended_errcode / _extended_result_codes
    sqlite3_interrupt / _is_interrupted
    sqlite3_sleep, _release_memory, _memory_highwater, _msize, _system_errno
}
uses
  SysUtils,
  passqlite3types,
  passqlite3util,
  passqlite3os,
  passqlite3pcache,
  passqlite3pager,
  passqlite3wal,
  passqlite3btree,
  passqlite3vdbe,
  passqlite3codegen,
  passqlite3parser,
  passqlite3vtab,
  passqlite3main;

var
  pass: i32 = 0;
  fail: i32 = 0;

procedure Check(name: string; cond: Boolean);
begin
  if cond then begin
    Inc(pass); Writeln('  PASS ', name);
  end else begin
    Inc(fail); Writeln('  FAIL ', name);
  end;
end;

var
  db: PTsqlite3;
  rc: i32;
  highwater: i64;
begin
  Check('libversion_number = 3053000',
        sqlite3_libversion_number = 3053000);
  Check('libversion non-nil',
        sqlite3_libversion <> nil);
  Check('sourceid non-nil',
        sqlite3_sourceid <> nil);
  Check('threadsafe = 1', sqlite3_threadsafe = 1);
  Check('sleep(1) returns >= 0', sqlite3_sleep(1) >= 0);
  Check('release_memory(0) = 0', sqlite3_release_memory(0) = 0);
  highwater := sqlite3_memory_highwater(0);
  Check('memory_highwater >= 0', highwater >= 0);
  Check('msize(nil) = 0', sqlite3_msize(nil) = 0);

  { Connection-level. }
  rc := sqlite3_open(':memory:', @db);
  Check('open :memory:', rc = SQLITE_OK);

  Check('autocommit=1 fresh', sqlite3_get_autocommit(db) = 1);
  Check('errcode=OK fresh', sqlite3_errcode(db) = SQLITE_OK);
  Check('extended_errcode=OK', sqlite3_extended_errcode(db) = SQLITE_OK);
  Check('system_errno=0', sqlite3_system_errno(db) = 0);
  Check('changes=0 fresh', sqlite3_changes(db) = 0);
  Check('total_changes=0 fresh', sqlite3_total_changes(db) = 0);
  Check('last_insert_rowid=0 fresh', sqlite3_last_insert_rowid(db) = 0);
  Check('is_interrupted=0', sqlite3_is_interrupted(db) = 0);
  sqlite3_interrupt(db);
  Check('is_interrupted=1 after interrupt',
        sqlite3_is_interrupted(db) = 1);
  db^.u1.isInterrupted := 0;

  sqlite3_set_last_insert_rowid(db, 1234);
  Check('set_last_insert_rowid stores',
        sqlite3_last_insert_rowid(db) = 1234);

  rc := sqlite3_extended_result_codes(db, 1);
  Check('extended_result_codes(on)', rc = SQLITE_OK);
  rc := sqlite3_extended_result_codes(db, 0);
  Check('extended_result_codes(off)', rc = SQLITE_OK);

  Check('db_readonly main = 0', sqlite3_db_readonly(db, 'main') = 0);
  Check('db_readonly nil = 0', sqlite3_db_readonly(db, nil) = 0);
  Check('db_readonly bogus = -1',
        sqlite3_db_readonly(db, 'no_such_db') = -1);

  { Misuse / nil paths. }
  Check('errcode(nil) = NOMEM', sqlite3_errcode(nil) = SQLITE_NOMEM);
  Check('changes(nil) = 0', sqlite3_changes(nil) = 0);
  Check('autocommit(nil) = 0', sqlite3_get_autocommit(nil) = 0);

  rc := sqlite3_close(db);
  Check('close', rc = SQLITE_OK);

  Writeln;
  Writeln('Results: ', pass, ' passed, ', fail, ' failed');
  if fail <> 0 then Halt(1);
end.
