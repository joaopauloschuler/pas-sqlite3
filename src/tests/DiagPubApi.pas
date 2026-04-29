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
  progressCalls: i32 = 0;

function ProgressCb(p: Pointer): i32; cdecl;
begin
  Inc(progressCalls);
  Result := 0;
end;

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
  zType, zColl: PAnsiChar;
  nn, pk, ai, mrc: i32;
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

  { progress_handler — set, verify db fields, then clear. }
  sqlite3_progress_handler(db, 50, @ProgressCb, Pointer(PtrUInt($BEEF)));
  Check('progress nProgressOps=50', db^.nProgressOps = 50);
  Check('progress xProgress set', db^.xProgress = @ProgressCb);
  Check('progress pProgressArg set',
        db^.pProgressArg = Pointer(PtrUInt($BEEF)));
  sqlite3_progress_handler(db, 0, nil, nil);
  Check('progress cleared (nOps=0)', db^.xProgress = nil);
  Check('progress nProgressOps=0', db^.nProgressOps = 0);
  Check('progress pProgressArg=nil', db^.pProgressArg = nil);
  sqlite3_progress_handler(nil, 1, @ProgressCb, nil);  { nil-db no-op }

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

  { Phase 8.3.2 — sqlite3_value_numeric_type / _encoding. }
  pStmt := nil;
  rcs := sqlite3_prepare_v2(db, 'SELECT ''42''', -1, @pStmt, nil);
  Check('prepare ''42''', rcs = SQLITE_OK);
  rcs := sqlite3_step(pStmt);
  Check('step text 42 -> ROW', rcs = SQLITE_ROW);
  Check('value_type text = TEXT',
        sqlite3_value_type(sqlite3_column_value(pStmt, 0)) = SQLITE_TEXT);
  Check('value_numeric_type text(''42'') = INTEGER',
        sqlite3_value_numeric_type(sqlite3_column_value(pStmt, 0))
          = SQLITE_INTEGER);
  Check('value_encoding = UTF8',
        sqlite3_value_encoding(sqlite3_column_value(pStmt, 0)) = SQLITE_UTF8);
  Check('value_encoding(nil) = UTF8',
        sqlite3_value_encoding(nil) = SQLITE_UTF8);
  sqlite3_finalize(pStmt);

  { Phase 8.3.1 — sqlite3_bind_zeroblob / _zeroblob64. }
  Check('bind_zeroblob(nil) = MISUSE',
        sqlite3_bind_zeroblob(nil, 1, 8) = SQLITE_MISUSE);
  Check('bind_zeroblob64(nil) = MISUSE',
        sqlite3_bind_zeroblob64(nil, 1, 8) = SQLITE_MISUSE);
  pStmt := nil;
  rcs := sqlite3_prepare_v2(db, 'SELECT 1', -1, @pStmt, nil);
  Check('bind_zeroblob no-params = RANGE',
        sqlite3_bind_zeroblob(pStmt, 1, 8) = SQLITE_RANGE);
  Check('bind_zeroblob64 over-LENGTH = TOOBIG',
        sqlite3_bind_zeroblob64(pStmt, 1, u64(2) shl 40) = SQLITE_TOOBIG);
  sqlite3_finalize(pStmt);

  { Host-parameter round-trip — verifies sqlite3VdbeMakeReady aVar/nVar
    propagation (vdbeaux.c:2714/2737-2738).  Single `?`, indexed `?N`,
    and named `:`/`@`/`$` forms all flow through OP_Variable. }
  pStmt := nil;
  rcs := sqlite3_prepare_v2(db, 'SELECT ?', -1, @pStmt, nil);
  Check('prep SELECT ?', rcs = SQLITE_OK);
  Check('bind_parameter_count(SELECT ?) = 1',
        sqlite3_bind_parameter_count(pStmt) = 1);
  Check('bind_int rc=OK', sqlite3_bind_int(pStmt, 1, 42) = SQLITE_OK);
  Check('step ROW',       sqlite3_step(pStmt) = SQLITE_ROW);
  Check('column_int = 42', sqlite3_column_int(pStmt, 0) = 42);
  sqlite3_finalize(pStmt);

  pStmt := nil;
  rcs := sqlite3_prepare_v2(db, 'SELECT :a + :b', -1, @pStmt, nil);
  Check('prep SELECT :a + :b', rcs = SQLITE_OK);
  Check('bind_parameter_count(:a,:b) = 2',
        sqlite3_bind_parameter_count(pStmt) = 2);
  sqlite3_bind_int(pStmt, 1, 3);
  sqlite3_bind_int(pStmt, 2, 4);
  Check('step :a+:b ROW', sqlite3_step(pStmt) = SQLITE_ROW);
  Check('column_int(:a+:b) = 7', sqlite3_column_int(pStmt, 0) = 7);
  { Phase 8.3.1 — sqlite3_bind_parameter_name / _index round-trip. }
  Check('parameter_name(:a)',
        StrComp(sqlite3_bind_parameter_name(pStmt, 1), ':a') = 0);
  Check('parameter_name(:b)',
        StrComp(sqlite3_bind_parameter_name(pStmt, 2), ':b') = 0);
  Check('parameter_name(out-of-range)',
        sqlite3_bind_parameter_name(pStmt, 3) = nil);
  Check('parameter_index(:a) = 1',
        sqlite3_bind_parameter_index(pStmt, ':a') = 1);
  Check('parameter_index(:b) = 2',
        sqlite3_bind_parameter_index(pStmt, ':b') = 2);
  Check('parameter_index(:zzz) = 0 (absent)',
        sqlite3_bind_parameter_index(pStmt, ':zzz') = 0);
  Check('parameter_name(nil stmt) = nil',
        sqlite3_bind_parameter_name(nil, 1) = nil);
  Check('parameter_index(nil stmt) = 0',
        sqlite3_bind_parameter_index(nil, ':a') = 0);
  sqlite3_finalize(pStmt);

  { De-duplication: ":x + :x" should resolve to 1 wildcard slot. }
  pStmt := nil;
  rcs := sqlite3_prepare_v2(db, 'SELECT :x + :x', -1, @pStmt, nil);
  Check('prep SELECT :x + :x', rcs = SQLITE_OK);
  Check('bind_parameter_count(:x dedup) = 1',
        sqlite3_bind_parameter_count(pStmt) = 1);
  Check('parameter_index(:x dedup) = 1',
        sqlite3_bind_parameter_index(pStmt, ':x') = 1);
  Check('parameter_name(:x dedup)',
        StrComp(sqlite3_bind_parameter_name(pStmt, 1), ':x') = 0);
  sqlite3_bind_int(pStmt, 1, 5);
  Check('step :x+:x ROW', sqlite3_step(pStmt) = SQLITE_ROW);
  Check('column_int(:x+:x) = 10', sqlite3_column_int(pStmt, 0) = 10);
  sqlite3_finalize(pStmt);

  { ?N anonymous wildcards: name should be NULL. }
  pStmt := nil;
  rcs := sqlite3_prepare_v2(db, 'SELECT ?, ?', -1, @pStmt, nil);
  Check('prep SELECT ?, ?', rcs = SQLITE_OK);
  Check('parameter_name(?) = nil',
        sqlite3_bind_parameter_name(pStmt, 1) = nil);
  sqlite3_finalize(pStmt);

  { Phase 8.3.2 — sqlite3_value_bytes16 / sqlite3_column_bytes16.
    For an N-char ASCII text source, the UTF-16 byte count is 2*N.  The
    helper converts in place via valueToText, so a follow-up
    sqlite3_value_bytes (UTF-8) reflects the new in-memory encoding. }
  pStmt := nil;
  rcs := sqlite3_prepare_v2(db, 'SELECT ''hi''', -1, @pStmt, nil);
  Check('prep SELECT ''hi''', rcs = SQLITE_OK);
  rcs := sqlite3_step(pStmt);
  Check('step ''hi'' ROW', rcs = SQLITE_ROW);
  Check('column_bytes(''hi'') = 2',
        sqlite3_column_bytes(pStmt, 0) = 2);
  Check('column_bytes16(''hi'') = 4',
        sqlite3_column_bytes16(pStmt, 0) = 4);
  Check('value_bytes16 on column = 4',
        sqlite3_value_bytes16(sqlite3_column_value(pStmt, 0)) = 4);
  sqlite3_finalize(pStmt);

  { Phase 8.4.1 — sqlite3_autovacuum_pages.  Setter only; verify the
    callback / arg / destructor slots populate, then clear via nil/nil. }
  Check('autovacuum_pages set = OK',
        sqlite3_autovacuum_pages(db, nil, Pointer(PtrUInt($DEAD)), nil)
          = SQLITE_OK);
  Check('autovacuum_pages pArg stored',
        db^.pAutovacPagesArg = Pointer(PtrUInt($DEAD)));
  Check('autovacuum_pages clear = OK',
        sqlite3_autovacuum_pages(db, nil, nil, nil) = SQLITE_OK);
  Check('autovacuum_pages pArg cleared',
        db^.pAutovacPagesArg = nil);
  Check('autovacuum_pages(nil db) = MISUSE',
        sqlite3_autovacuum_pages(nil, nil, nil, nil) = SQLITE_MISUSE);

  { Phase 8.4.1 — sqlite3_overload_function.  Registering an unknown
    name installs a stub; calling it via SQL yields a runtime error
    "unable to use function NAME ...". }
  Check('overload_function ok',
        sqlite3_overload_function(db, 'my_overload', 1) = SQLITE_OK);
  pStmt := nil;
  rcs := sqlite3_prepare_v2(db, 'SELECT my_overload(1)', -1, @pStmt, nil);
  Check('prep SELECT my_overload(1)', rcs = SQLITE_OK);
  rcs := sqlite3_step(pStmt);
  Check('step my_overload -> ERROR', rcs = SQLITE_ERROR);
  sqlite3_finalize(pStmt);
  Check('overload_function(nil db) = MISUSE',
        sqlite3_overload_function(nil, 'x', 1) = SQLITE_MISUSE);
  Check('overload_function(nil name) = MISUSE',
        sqlite3_overload_function(db, nil, 1) = SQLITE_MISUSE);
  Check('overload_function(nArg=-3) = MISUSE',
        sqlite3_overload_function(db, 'x', -3) = SQLITE_MISUSE);

  { Phase 8.1.1 — sqlite3_db_release_memory / sqlite3_db_cacheflush. }
  Check('db_release_memory = OK',  sqlite3_db_release_memory(db)   = SQLITE_OK);
  Check('db_release_memory(nil) = MISUSE',
        sqlite3_db_release_memory(nil)  = SQLITE_MISUSE);
  Check('db_cacheflush = OK',      sqlite3_db_cacheflush(db)       = SQLITE_OK);
  Check('db_cacheflush(nil) = MISUSE',
        sqlite3_db_cacheflush(nil)      = SQLITE_MISUSE);

  { Phase 8.4.1 — sqlite3_table_column_metadata.  Create a table with
    a known schema, then inspect column metadata.  The Pas port has no
    on-disk schema reload, but in-process pTab is populated by
    CREATE TABLE so the lookup goes through sqlite3FindTable. }
  begin
    Check('exec CREATE TABLE',
          sqlite3_exec(db,
            'CREATE TABLE tcm(' +
              'a INTEGER PRIMARY KEY AUTOINCREMENT, ' +
              'b TEXT NOT NULL COLLATE NOCASE, ' +
              'c REAL)',
            nil, nil, nil) = SQLITE_OK);
    zType := nil; zColl := nil; nn := -1; pk := -1; ai := -1;
      mrc := sqlite3_table_column_metadata(db, nil,
               'tcm', 'a', @zType, @zColl, @nn, @pk, @ai);
      Check('metadata a OK', mrc = SQLITE_OK);
      Check('metadata a type=INTEGER',
            (zType <> nil) and (StrComp(zType, 'INTEGER') = 0));
      Check('metadata a coll=BINARY',
            (zColl <> nil) and (StrComp(zColl, 'BINARY') = 0));
      Check('metadata a primarykey=1', pk = 1);
      Check('metadata a autoinc=1',    ai = 1);

      zType := nil; zColl := nil; nn := -1; pk := -1; ai := -1;
      mrc := sqlite3_table_column_metadata(db, nil,
               'tcm', 'b', @zType, @zColl, @nn, @pk, @ai);
      Check('metadata b OK', mrc = SQLITE_OK);
      Check('metadata b type=TEXT',
            (zType <> nil) and (StrComp(zType, 'TEXT') = 0));
      Check('metadata b coll=NOCASE',
            (zColl <> nil) and (StrComp(zColl, 'NOCASE') = 0));
      Check('metadata b notnull=1', nn = 1);
      Check('metadata b primarykey=0', pk = 0);
      Check('metadata b autoinc=0',    ai = 0);

      zType := nil;
      mrc := sqlite3_table_column_metadata(db, nil,
               'tcm', 'rowid', @zType, nil, nil, @pk, nil);
      Check('metadata rowid OK', mrc = SQLITE_OK);
      Check('metadata rowid type=INTEGER',
            (zType <> nil) and (StrComp(zType, 'INTEGER') = 0));
      Check('metadata rowid pk=1', pk = 1);

      mrc := sqlite3_table_column_metadata(db, nil,
               'tcm', 'nosuch', nil, nil, nil, nil, nil);
      Check('metadata nosuch col = ERROR', mrc = SQLITE_ERROR);

      mrc := sqlite3_table_column_metadata(db, nil,
               'nosuch_tbl', nil, nil, nil, nil, nil, nil);
      Check('metadata nosuch tbl = ERROR', mrc = SQLITE_ERROR);

      mrc := sqlite3_table_column_metadata(nil, nil,
               'tcm', 'a', nil, nil, nil, nil, nil);
      Check('metadata(nil db) = MISUSE', mrc = SQLITE_MISUSE);

      mrc := sqlite3_table_column_metadata(db, nil,
               nil, nil, nil, nil, nil, nil, nil);
      Check('metadata(nil tbl) = MISUSE', mrc = SQLITE_MISUSE);
  end;

  rc := sqlite3_close(db);
  Check('close', rc = SQLITE_OK);

  Writeln;
  Writeln('Results: ', pass, ' passed, ', fail, ' failed');
  if fail <> 0 then Halt(1);
end.
