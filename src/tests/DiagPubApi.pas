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
  rcs: i32;
  pStmt: Pointer;
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

  { txn_state — fresh connection has no transaction on any attached db. }
  Check('txn_state main = NONE',
        sqlite3_txn_state(db, 'main') = 0);
  Check('txn_state nil(any) = NONE',
        sqlite3_txn_state(db, nil) = 0);
  Check('txn_state bogus = -1',
        sqlite3_txn_state(db, 'no_such_db') = -1);
  Check('txn_state(nil db) = -1',
        sqlite3_txn_state(nil, nil) = -1);

  { error_offset — no error pending → -1. }
  Check('error_offset fresh = -1',
        sqlite3_error_offset(db) = -1);
  Check('error_offset(nil) = -1',
        sqlite3_error_offset(nil) = -1);

  { sqlite3_limit — get current, set, reread, clamp behaviour. }
  Check('limit LENGTH default = 1e9',
        sqlite3_limit(db, 0, -1) = 1000000000);
  Check('limit LENGTH set 50000',
        sqlite3_limit(db, 0, 50000) = 1000000000);
  Check('limit LENGTH read back',
        sqlite3_limit(db, 0, -1) = 50000);
  { LENGTH floor at 100. }
  Check('limit LENGTH floor=100',
        sqlite3_limit(db, 0, 1) = 50000);
  Check('limit LENGTH read after floor',
        sqlite3_limit(db, 0, -1) = 100);
  { Out-of-range limitId. }
  Check('limit bogus id = -1',
        sqlite3_limit(db, 999, -1) = -1);
  Check('limit nil db = -1',
        sqlite3_limit(nil, 0, -1) = -1);
  { Hard-cap: passing huge value clamps to aHardLimit. }
  Check('limit LENGTH clamp big',
        sqlite3_limit(db, 0, $7FFFFFFF) = 100);
  Check('limit LENGTH clamped read',
        sqlite3_limit(db, 0, -1) = 1000000000);

  { soft/hard heap-limit accessors return prior value, store new. }
  Check('soft_heap_limit64 init = 0',
        sqlite3_soft_heap_limit64(-1) = 0);
  Check('soft_heap_limit64 set 1MB',
        sqlite3_soft_heap_limit64(1 shl 20) = 0);
  Check('soft_heap_limit64 read back',
        sqlite3_soft_heap_limit64(-1) = (1 shl 20));
  Check('hard_heap_limit64 init = 0',
        sqlite3_hard_heap_limit64(-1) = 0);
  Check('hard_heap_limit64 set 2MB',
        sqlite3_hard_heap_limit64(2 shl 20) = 0);
  sqlite3_soft_heap_limit(0);
  Check('soft_heap_limit(0) clears',
        sqlite3_soft_heap_limit64(-1) = 0);

  { Misuse / nil paths. }
  Check('errcode(nil) = NOMEM', sqlite3_errcode(nil) = SQLITE_NOMEM);
  Check('changes(nil) = 0', sqlite3_changes(nil) = 0);
  Check('autocommit(nil) = 0', sqlite3_get_autocommit(nil) = 0);

  { Phase 8.2.1 — sqlite3_stmt_busy / _readonly. }
  Check('stmt_busy(nil) = 0',     sqlite3_stmt_busy(nil) = 0);
  Check('stmt_readonly(nil) = 1', sqlite3_stmt_readonly(nil) = 1);
  pStmt := nil;
  rcs := sqlite3_prepare_v2(db, 'SELECT 1', -1, @pStmt, nil);
  Check('prepare SELECT 1', rcs = SQLITE_OK);
  Check('stmt_readonly(SELECT 1) = 1', sqlite3_stmt_readonly(pStmt) = 1);
  Check('stmt_busy fresh = 0',         sqlite3_stmt_busy(pStmt) = 0);
  rcs := sqlite3_step(pStmt);
  Check('step -> ROW',                 rcs = SQLITE_ROW);
  Check('stmt_busy mid-run = 1',       sqlite3_stmt_busy(pStmt) = 1);
  rcs := sqlite3_step(pStmt);
  Check('step -> DONE',                rcs = SQLITE_DONE);
  Check('stmt_busy after DONE = 0',    sqlite3_stmt_busy(pStmt) = 0);
  sqlite3_finalize(pStmt);

  { Phase 8.1.1 — sqlite3_db_release_memory / sqlite3_db_cacheflush. }
  Check('db_release_memory = OK',  sqlite3_db_release_memory(db)   = SQLITE_OK);
  Check('db_release_memory(nil) = MISUSE',
        sqlite3_db_release_memory(nil)  = SQLITE_MISUSE);
  Check('db_cacheflush = OK',      sqlite3_db_cacheflush(db)       = SQLITE_OK);
  Check('db_cacheflush(nil) = MISUSE',
        sqlite3_db_cacheflush(nil)      = SQLITE_MISUSE);

  rc := sqlite3_close(db);
  Check('close', rc = SQLITE_OK);

  Writeln;
  Writeln('Results: ', pass, ' passed, ', fail, ' failed');
  if fail <> 0 then Halt(1);
end.
