program DiagVacuum;
{$mode objfpc}{$H+}
uses
  csqlite3,
  passqlite3main, passqlite3vdbe, passqlite3types,
  passqlite3util, passqlite3codegen,
  sysutils;

procedure DumpC(const sql: string);
var
  db: Pcsq_db;
  st: Pcsq_stmt;
  rc, n, i: integer;
  s: string;
  pTail: PChar;
begin
  if csq_open(PChar(':memory:'), db) <> 0 then exit;
  rc := csq_prepare_v2(db, PAnsiChar('EXPLAIN ' + sql), -1, st, pTail);
  if rc <> 0 then begin
    writeln('C prep fail rc=', rc, ' msg=', csq_errmsg(db));
    csq_close(db); exit;
  end;
  n := csq_column_count(st);
  writeln('C ', sql);
  while csq_step(st) = 100 do begin
    s := '';
    for i := 0 to n - 1 do begin
      if i > 0 then s := s + '|';
      s := s + StrPas(csq_column_text(st, i));
    end;
    writeln('  ', s);
  end;
  csq_finalize(st);
  csq_close(db);
end;

procedure DumpPas(const sql: string);
var
  db: PTsqlite3;
  st: PVdbe;
  rc, n, i: integer;
  s: string;
  pTail: PAnsiChar;
begin
  rc := sqlite3_open(':memory:', @db);
  if rc <> 0 then exit;
  rc := sqlite3_prepare_v2(db, PAnsiChar('EXPLAIN ' + sql), -1, @st, @pTail);
  if rc <> 0 then begin
    writeln('Pas prep fail rc=', rc, ' msg=', sqlite3_errmsg(db));
    sqlite3_close(db); exit;
  end;
  n := sqlite3_column_count(st);
  writeln('Pas ', sql);
  while sqlite3_step(st) = 100 do begin
    s := '';
    for i := 0 to n - 1 do begin
      if i > 0 then s := s + '|';
      s := s + StrPas(PChar(sqlite3_column_text(st, i)));
    end;
    writeln('  ', s);
  end;
  sqlite3_finalize(st);
  sqlite3_close(db);
end;

begin
  DumpC('VACUUM');
  DumpPas('VACUUM');
  writeln;
  DumpC('VACUUM INTO ''tmp.db''');
  DumpPas('VACUUM INTO ''tmp.db''');
end.
