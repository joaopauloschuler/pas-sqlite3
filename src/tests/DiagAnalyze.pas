{$I ../passqlite3.inc}
{
  DiagAnalyze — exploratory probe for ANALYZE / sqlite_stat1 parity.

  Validates that the StatAccum SQL function triplet (stat_init / stat_push
  / stat_get, analyze.c:401..923) lands productive sqlite_stat1 rows after
  ANALYZE.  Compares the resulting rows against the C oracle.
}
program DiagAnalyze;

uses
  SysUtils,
  passqlite3types, passqlite3util, passqlite3vdbe,
  passqlite3codegen, passqlite3main, csqlite3;

var
  diverged: i32 = 0;

function PasStat1(const setup: AnsiString): AnsiString;
var
  db: PTsqlite3;
  pStmt: PVdbe;
  s, stmt2: AnsiString;
  p, rcs: i32;
  z: PAnsiChar;
  out_: AnsiString;
begin
  out_ := '';
  db := nil;
  if sqlite3_open(':memory:', @db) <> 0 then begin Result := '?open'; Exit; end;
  s := setup;
  while s <> '' do begin
    p := Pos(';', s);
    if p = 0 then begin stmt2 := s; s := ''; end
    else begin stmt2 := Copy(s, 1, p - 1); s := Copy(s, p + 1, MaxInt); end;
    stmt2 := Trim(stmt2);
    if stmt2 = '' then continue;
    pStmt := nil;
    if (sqlite3_prepare_v2(db, PAnsiChar(stmt2), -1, @pStmt, nil) = 0)
      and (pStmt <> nil) then begin
      repeat rcs := sqlite3_step(pStmt) until rcs <> SQLITE_ROW;
      sqlite3_finalize(pStmt);
    end;
  end;
  pStmt := nil;
  if (sqlite3_prepare_v2(db,
        'SELECT tbl||"|"||idx||"|"||stat FROM sqlite_stat1 ORDER BY 1',
        -1, @pStmt, nil) = 0) and (pStmt <> nil) then begin
    while sqlite3_step(pStmt) = SQLITE_ROW do begin
      z := PAnsiChar(sqlite3_column_text(pStmt, 0));
      if z <> nil then begin
        if out_ <> '' then out_ := out_ + #10;
        out_ := out_ + AnsiString(z);
      end;
    end;
    sqlite3_finalize(pStmt);
  end;
  sqlite3_close(db);
  Result := out_;
end;

function CStat1(const setup: AnsiString): AnsiString;
var
  db: Pcsq_db;
  pStmt: Pcsq_stmt;
  pTail, pErr: PChar;
  z: PAnsiChar;
  out_: AnsiString;
begin
  out_ := ''; db := nil;
  if csq_open(':memory:', db) <> 0 then begin Result := '?open'; Exit; end;
  pErr := nil;
  csq_exec(db, PAnsiChar(setup), nil, nil, pErr);
  pStmt := nil; pTail := nil;
  if csq_prepare_v2(db,
        'SELECT tbl||"|"||idx||"|"||stat FROM sqlite_stat1 ORDER BY 1',
        -1, pStmt, pTail) = 0 then begin
    while csq_step(pStmt) = SQLITE_ROW do begin
      z := PAnsiChar(csq_column_text(pStmt, 0));
      if z <> nil then begin
        if out_ <> '' then out_ := out_ + #10;
        out_ := out_ + AnsiString(z);
      end;
    end;
    csq_finalize(pStmt);
  end;
  csq_close(db);
  Result := out_;
end;

procedure Probe(const lbl, setup: AnsiString);
var p, c: AnsiString;
begin
  p := PasStat1(setup);
  c := CStat1(setup);
  if p = c then
    WriteLn('PASS    ', lbl)
  else begin
    Inc(diverged);
    WriteLn('DIVERGE ', lbl);
    WriteLn('   Pas:'); WriteLn(p);
    WriteLn('   C  :'); WriteLn(c);
  end;
end;

begin
  Probe('single index, 6 rows, 3 distinct',
    'CREATE TABLE t(a,b);' +
    'CREATE INDEX i1 ON t(a);' +
    'INSERT INTO t VALUES(1,1),(2,2),(3,3),(1,4),(2,5),(1,6);' +
    'CREATE TABLE sqlite_stat1(tbl,idx,stat);' +
    'ANALYZE');

  Probe('two-col index, 4 rows',
    'CREATE TABLE u(x,y,z);' +
    'CREATE INDEX iu ON u(x,y);' +
    'INSERT INTO u VALUES(1,1,1),(1,2,2),(2,1,3),(2,2,4);' +
    'CREATE TABLE sqlite_stat1(tbl,idx,stat);' +
    'ANALYZE');

  Probe('unique index, 3 rows',
    'CREATE TABLE v(a INTEGER);' +
    'CREATE UNIQUE INDEX iv ON v(a);' +
    'INSERT INTO v VALUES(10),(20),(30);' +
    'CREATE TABLE sqlite_stat1(tbl,idx,stat);' +
    'ANALYZE');

  WriteLn;
  if diverged = 0 then WriteLn('DiagAnalyze: ALL PASS')
  else                 WriteLn('DiagAnalyze: ', diverged, ' divergences');
end.
