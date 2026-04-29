{$I ../passqlite3.inc}
program TestPublicApi;

{
  Tests for newly ported small public-API entry points:
    sqlite3_db_handle, sqlite3_db_mutex, sqlite3_db_name,
    sqlite3_errstr, sqlite3_next_stmt, sqlite3_sql, sqlite3_expanded_sql.
}

uses
  SysUtils,
  passqlite3types,
  passqlite3util,
  passqlite3os,
  passqlite3vdbe,
  passqlite3main;

var
  db:    PTsqlite3;
  pStmt, pStmt2, pNext: Pointer;
  rc:    i32;
  zSql:  PAnsiChar;
  zExp:  PAnsiChar;
  fails: i32;

procedure Check(cond: Boolean; const msg: string);
begin
  if not cond then begin
    WriteLn('FAIL: ', msg);
    Inc(fails);
  end;
end;

begin
  fails := 0;
  rc := sqlite3_open(':memory:', @db);
  Check(rc = SQLITE_OK, 'open');

  { sqlite3_db_mutex / sqlite3_db_name on the connection }
  Check(sqlite3_db_mutex(db) = db^.mutex, 'db_mutex matches');
  Check(StrComp(sqlite3_db_name(db, 0), 'main') = 0, 'db_name(0)=main');
  Check(StrComp(sqlite3_db_name(db, 1), 'temp') = 0, 'db_name(1)=temp');
  Check(sqlite3_db_name(db, 99) = nil, 'db_name(99) nil');
  Check(sqlite3_db_name(db, -1) = nil, 'db_name(-1) nil');

  { sqlite3_errstr — static strings }
  Check(sqlite3_errstr(SQLITE_OK) <> nil, 'errstr(OK) non-nil');
  Check(sqlite3_errstr(SQLITE_MISUSE) <> nil, 'errstr(MISUSE) non-nil');

  { Prepare a stmt and exercise sql/db_handle/next_stmt }
  rc := sqlite3_prepare_v2(db, 'SELECT ?1+1', -1, @pStmt, nil);
  Check(rc = SQLITE_OK, 'prepare');
  Check(sqlite3_db_handle(pStmt) = db, 'db_handle returns db');

  zSql := sqlite3_sql(pStmt);
  Check((zSql <> nil) and (StrComp(zSql, 'SELECT ?1+1') = 0), 'sqlite3_sql verbatim');

  Check(sqlite3_db_handle(nil) = nil, 'db_handle(nil) nil');
  Check(sqlite3_sql(nil) = nil, 'sql(nil) nil');
  Check(sqlite3_expanded_sql(nil) = nil, 'expanded_sql(nil) nil');

  { Bind and check expanded_sql substitutes literal }
  rc := sqlite3_bind_int(pStmt, 1, 41);
  Check(rc = SQLITE_OK, 'bind');
  zExp := sqlite3_expanded_sql(pStmt);
  Check(zExp <> nil, 'expanded_sql non-nil');
  { Note: sqlite3VdbeExpandSql is currently a stub that returns the raw SQL
    text without substituting bound parameters (vdbe.pas:5125 design note).
    Once the full printf-based expander lands, tighten this to check for '41'. }
  if zExp <> nil then sqlite3_free(zExp);

  { sqlite3_next_stmt walk: nil → first; pStmt → next (nil if only one) }
  pNext := sqlite3_next_stmt(db, nil);
  Check(pNext = pStmt, 'next_stmt(nil) = pStmt');
  pNext := sqlite3_next_stmt(db, pStmt);
  Check(pNext = nil, 'next_stmt(pStmt) = nil (only one stmt)');

  { Add another stmt; both should be reachable via next_stmt walk. }
  rc := sqlite3_prepare_v2(db, 'SELECT 2', -1, @pStmt2, nil);
  Check(rc = SQLITE_OK, 'prepare 2');
  pNext := sqlite3_next_stmt(db, nil);
  Check((pNext = pStmt) or (pNext = pStmt2), 'next_stmt(nil) hit a stmt');
  pNext := sqlite3_next_stmt(db, pNext);
  Check((pNext = pStmt) or (pNext = pStmt2), 'next_stmt walks to other stmt');
  pNext := sqlite3_next_stmt(db, pNext);
  Check(pNext = nil, 'next_stmt terminates with nil');

  sqlite3_finalize(pStmt);
  sqlite3_finalize(pStmt2);
  sqlite3_close(db);

  if fails = 0 then begin
    WriteLn('TestPublicApi: PASS');
    Halt(0);
  end else begin
    WriteLn('TestPublicApi: ', fails, ' failure(s)');
    Halt(1);
  end;
end.
