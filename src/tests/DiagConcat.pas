{$I ../passqlite3.inc}
program DiagConcat;
uses SysUtils, passqlite3types, passqlite3util, passqlite3vdbe,
     passqlite3codegen, passqlite3main, csqlite3;

procedure TestExpr(const sql: AnsiString);
var
  db: PTsqlite3;
  cdb: Pcsq_db;
  pStmt: PVdbe;
  pcStmt: Pcsq_stmt;
  pTail, pcTail: PAnsiChar;
  rcs: i32;
  pasV, cV: AnsiString;
  txt: PAnsiChar;
begin
  db := nil; pStmt := nil; pTail := nil;
  if sqlite3_open(':memory:', @db) = 0 then begin
    if (sqlite3_prepare_v2(db, PAnsiChar(sql), -1, @pStmt, @pTail) = 0)
       and (pStmt <> nil) then begin
      rcs := sqlite3_step(pStmt);
      if rcs = SQLITE_ROW then begin
        txt := sqlite3_column_text(pStmt, 0);
        if txt = nil then pasV := '<NULL>' else pasV := AnsiString(txt);
      end else pasV := '<no row rc=' + IntToStr(rcs) + '>';
      sqlite3_finalize(pStmt);
    end else pasV := '<prep fail>';
    sqlite3_close(db);
  end else pasV := '<open fail>';

  cdb := nil; pcStmt := nil; pcTail := nil;
  if csq_open(':memory:', cdb) = 0 then begin
    if (csq_prepare_v2(cdb, PAnsiChar(sql), -1, pcStmt, pcTail) = 0)
       and (pcStmt <> nil) then begin
      rcs := csq_step(pcStmt);
      if rcs = SQLITE_ROW then begin
        txt := csq_column_text(pcStmt, 0);
        if txt = nil then cV := '<NULL>' else cV := AnsiString(txt);
      end else cV := '<no row rc=' + IntToStr(rcs) + '>';
      csq_finalize(pcStmt);
    end else cV := '<prep fail>';
    csq_close(cdb);
  end else cV := '<open fail>';

  WriteLn(sql, ' | pas=[', pasV, '] c=[', cV, '] ',
          BoolToStr(pasV = cV, 'PASS', 'FAIL'));
end;

begin
  TestExpr('SELECT concat(''a'',''b'',''c'')');
  TestExpr('SELECT concat(''x'',NULL,''y'')');
  TestExpr('SELECT concat_ws('','',1,2,3)');
  TestExpr('SELECT concat_ws(''-'',''a'',NULL,''b'')');
  TestExpr('SELECT concat_ws(NULL,''a'',''b'')');
  TestExpr('SELECT concat()');
end.
