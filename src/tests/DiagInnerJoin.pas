{$I ../passqlite3.inc}
program DiagInnerJoin;
uses SysUtils, passqlite3types, passqlite3util, passqlite3vdbe,
     passqlite3codegen, passqlite3main, csqlite3;
procedure DumpPas(const sql: AnsiString);
var db: PTsqlite3; pStmt: PVdbe; pTail: PAnsiChar; rcs, i: i32;
    pop: PVdbeOp; nm: PAnsiChar;
begin
  WriteLn('=== Pas: ', sql);
  db := nil; if sqlite3_open(':memory:', @db) <> 0 then Exit;
  pStmt := nil; pTail := nil;
  if (sqlite3_prepare_v2(db,
       'CREATE TABLE t(a); CREATE TABLE u(b); '
     + 'INSERT INTO t VALUES(1); INSERT INTO u VALUES(1)',
       -1, @pStmt, @pTail) = 0) and (pStmt<>nil) then begin
    repeat rcs := sqlite3_step(pStmt) until rcs <> SQLITE_ROW;
    sqlite3_finalize(pStmt);
  end;
  // pTail may carry remaining stmts; loop until empty
  while (pTail <> nil) and (pTail^ <> #0) do begin
    pStmt := nil;
    if (sqlite3_prepare_v2(db, pTail, -1, @pStmt, @pTail) = 0) and (pStmt<>nil) then begin
      repeat rcs := sqlite3_step(pStmt) until rcs <> SQLITE_ROW;
      sqlite3_finalize(pStmt);
    end else break;
  end;
  pStmt := nil; pTail := nil;
  rcs := sqlite3_prepare_v2(db, PAnsiChar(sql), -1, @pStmt, @pTail);
  WriteLn('  prep rc=', rcs);
  if pStmt = nil then begin sqlite3_close(db); Exit; end;
  for i := 0 to pStmt^.nOp - 1 do begin
    pop := PVdbeOp(PtrUInt(pStmt^.aOp) + PtrUInt(i) * SizeOf(TVdbeOp));
    nm  := sqlite3OpcodeName(pop^.opcode);
    WriteLn('  [', i, '] ', AnsiString(nm),
            ' p1=', pop^.p1, ' p2=', pop^.p2, ' p3=', pop^.p3,
            ' p5=', pop^.p5);
  end;
  rcs := sqlite3_step(pStmt);
  WriteLn('  step rc=', rcs);
  if rcs = SQLITE_ROW then WriteLn('  val=', sqlite3_column_int(pStmt, 0));
  if (rcs <> SQLITE_ROW) and (rcs <> SQLITE_DONE) then
    WriteLn('  errmsg=', AnsiString(sqlite3_errmsg(db)));
  sqlite3_finalize(pStmt);
  sqlite3_close(db);
end;
procedure DumpC(const sql: AnsiString);
var db: Pcsq_db; pStmt: Pcsq_stmt; pTail, pErr: PAnsiChar; rcs: Int32;
    exp: AnsiString; n: Int32; txt: PAnsiChar;
begin
  WriteLn('=== C  : ', sql);
  db := nil; if csq_open(':memory:', db) <> 0 then Exit;
  pErr := nil;
  csq_exec(db,
    'CREATE TABLE t(a); CREATE TABLE u(b); '
  + 'INSERT INTO t VALUES(1); INSERT INTO u VALUES(1)', nil, nil, pErr);
  exp := 'EXPLAIN ' + sql;
  pStmt := nil; pTail := nil;
  rcs := csq_prepare_v2(db, PAnsiChar(exp), -1, pStmt, pTail);
  if pStmt = nil then begin WriteLn('  prepare rc=', rcs); csq_close(db); Exit; end;
  while csq_step(pStmt) = SQLITE_ROW do begin
    n := csq_column_int(pStmt, 0);
    txt := csq_column_text(pStmt, 1);
    WriteLn('  [', n, '] ', AnsiString(txt),
            ' p1=', csq_column_int(pStmt, 2),
            ' p2=', csq_column_int(pStmt, 3),
            ' p3=', csq_column_int(pStmt, 4),
            ' p5=', csq_column_int(pStmt, 6));
  end;
  csq_finalize(pStmt);
  csq_close(db);
end;
begin
  DumpPas('SELECT count(*) FROM t INNER JOIN u ON t.a=u.b');
  WriteLn;
  DumpC('SELECT count(*) FROM t INNER JOIN u ON t.a=u.b');
end.
