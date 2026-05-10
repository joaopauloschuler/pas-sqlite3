{
  SPDX-License-Identifier: blessing

  DiagCreateIdx — focused regression probe for CREATE INDEX runtime.

  Companion to DiagIndexing; verifies the in-memory VdbeSorter port
  closes the silent CREATE INDEX failure (Phase 6.10 step 26 follow-on).
}
{$I ../passqlite3.inc}
program DiagCreateIdx;
uses SysUtils, passqlite3types, passqlite3util, passqlite3vdbe,
     passqlite3codegen, passqlite3main;

var
  db:    PTsqlite3;
  pStmt: PVdbe;
  rc:    i32;
  pErr:  PAnsiChar;
begin
  db := nil;
  rc := sqlite3_open(':memory:', @db);
  if rc <> 0 then begin WriteLn('open failed rc=', rc); Halt(1); end;

  pErr := nil;
  rc := sqlite3_exec(db,
    PAnsiChar('CREATE TABLE t(a,b); INSERT INTO t VALUES(1,''x''),(2,''y''),(3,''z'');'),
    nil, nil, @pErr);
  if rc <> 0 then begin WriteLn('seed failed rc=', rc); Halt(1); end;

  pStmt := nil;
  rc := sqlite3_prepare_v2(db, PAnsiChar('CREATE INDEX ix ON t(a)'), -1, @pStmt, nil);
  if rc <> 0 then begin WriteLn('prep failed rc=', rc); Halt(1); end;
  rc := sqlite3_step(pStmt);
  sqlite3_finalize(pStmt);
  if rc <> SQLITE_DONE then begin
    WriteLn('FAIL CREATE INDEX step rc=', rc, ' err=',
            AnsiString(PAnsiChar(sqlite3_errmsg(db))));
    Halt(1);
  end;
  WriteLn('PASS CREATE INDEX');

  { Verify schema row materialised. }
  pStmt := nil;
  sqlite3_prepare_v2(db, PAnsiChar('SELECT name, tbl_name FROM sqlite_schema WHERE type=''index'''),
                    -1, @pStmt, nil);
  while sqlite3_step(pStmt) = SQLITE_ROW do
    WriteLn('schema row: ', AnsiString(PAnsiChar(sqlite3_column_text(pStmt, 0))),
            ' on ', AnsiString(PAnsiChar(sqlite3_column_text(pStmt, 1))));
  sqlite3_finalize(pStmt);

  { 10.1.bug.108 regression — UNIQUE INDEX with COLLATE NOCASE must
    enforce case-insensitive uniqueness both during refill from a
    pre-populated table and on subsequent inserts.  Pre-fix, the
    CreateIndex per-column loop dropped TK_COLLATE wrappers, so
    azColl[i] stayed BINARY and aiColumn[i] resolved to -1 (rowid). }
  pErr := nil;
  rc := sqlite3_exec(db,
    PAnsiChar('CREATE TABLE u(x); INSERT INTO u VALUES(''A''),(''a''),(''B'');'
              + 'CREATE UNIQUE INDEX iu ON u(x COLLATE NOCASE);'),
    nil, nil, @pErr);
  if (rc = SQLITE_CONSTRAINT) or (rc = SQLITE_CONSTRAINT_UNIQUE) then
    WriteLn('PASS NOCASE refill duplicate detected')
  else begin
    WriteLn('FAIL NOCASE refill duplicate undetected rc=', rc, ' err=',
            AnsiString(PAnsiChar(pErr)));
    Halt(1);
  end;
  pErr := nil;

  rc := sqlite3_exec(db,
    PAnsiChar('CREATE TABLE u2(x); CREATE UNIQUE INDEX iu2 ON u2(x COLLATE NOCASE);'
              + 'INSERT INTO u2 VALUES(''A''); INSERT INTO u2 VALUES(''a'');'),
    nil, nil, @pErr);
  if (rc = SQLITE_CONSTRAINT) or (rc = SQLITE_CONSTRAINT_UNIQUE) then
    WriteLn('PASS NOCASE post-create insert duplicate detected')
  else begin
    WriteLn('FAIL NOCASE post-create insert duplicate undetected rc=', rc);
    Halt(1);
  end;
  pErr := nil;

  sqlite3_close(db);
end.
