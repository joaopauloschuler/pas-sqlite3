{$I ../passqlite3.inc}
program DiagErrMsg;
uses
  SysUtils,
  passqlite3types, passqlite3util, passqlite3vdbe, passqlite3codegen,
  passqlite3main, csqlite3;

procedure One(const lbl, sql: AnsiString; const setup: AnsiString = '');
var
  pdb: PTsqlite3; pStmt: PVdbe;
  cdb: Pcsq_db; cStmt: Pcsq_stmt; cTail: PChar; cErr: PChar;
  pRc, cRc, pStep, cStep: i32;
  pMsg, cMsg: AnsiString;
  zP, zC: PAnsiChar;
begin
  pdb := nil; cdb := nil;
  if sqlite3_open(':memory:', @pdb) <> 0 then Exit;
  if csq_open(PChar(':memory:'), cdb) <> 0 then Exit;
  if setup <> '' then begin
    sqlite3_exec(pdb, PAnsiChar(setup), nil, nil, nil);
    csq_exec(cdb, PAnsiChar(setup), nil, nil, cErr);
  end;
  pStmt := nil; cStmt := nil;
  pRc := sqlite3_prepare_v2(pdb, PAnsiChar(sql), -1, @pStmt, nil);
  cRc := csq_prepare_v2(cdb, PAnsiChar(sql), -1, cStmt, cTail);
  pStep := -1; cStep := -1;
  if pStmt <> nil then begin pStep := sqlite3_step(pStmt); sqlite3_finalize(pStmt); end;
  if cStmt <> nil then begin cStep := csq_step(cStmt); csq_finalize(cStmt); end;
  zP := sqlite3_errmsg(pdb); zC := csq_errmsg(cdb);
  pMsg := ''; cMsg := '';
  if zP <> nil then pMsg := AnsiString(zP);
  if zC <> nil then cMsg := AnsiString(zC);
  if pMsg = cMsg then
    WriteLn('PASS    ', lbl, ' | both = "', pMsg, '"')
  else
    WriteLn('DIVERGE ', lbl, ' | sql=[', sql, ']  pRc=', pRc, ' pStep=', pStep, ' cRc=', cRc, ' cStep=', cStep, sLineBreak,
            '         Pas="', pMsg, '"', sLineBreak,
            '         C  ="', cMsg, '"');
  sqlite3_close(pdb); csq_close(cdb);
end;

begin
  One('parse syntax', 'SLECT 1');
  One('unknown col', 'SELECT z FROM t', 'CREATE TABLE t(a,b)');
  One('unknown tbl', 'SELECT * FROM nonesuch');
  One('div0', 'SELECT 1/0');
  One('overflow', 'SELECT 9223372036854775807 + 1');
  One('sum overflow', 'SELECT sum(a) FROM t', 'CREATE TABLE t(a INTEGER); INSERT INTO t VALUES(9223372036854775807); INSERT INTO t VALUES(1)');
  One('cast bad', 'SELECT CAST(''abc'' AS INTEGER)');
  One('like 3 args', 'SELECT ''a'' LIKE ''b'' ESCAPE ''abc''');
  One('open fail', 'SELECT sum');
  One('group concat dup sep', 'SELECT group_concat(a, ''x'', ''y'') FROM t');
end.
