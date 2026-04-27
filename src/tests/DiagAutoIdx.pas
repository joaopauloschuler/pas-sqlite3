{$I ../passqlite3.inc}
{
  DiagAutoIdx — diagnostic probe for the SELECT IPK alias u parity
  divergence (tasklist 6.10 step 6).  Dumps sqlite_schema rows + the
  EXPLAIN of `SELECT p FROM u` for the Pascal port; compare with
  the C reference to confirm whether sqlite_autoindex_u_1 is being
  registered + materialised on disk.

  Build: fpc -O3 -Fusrc -Fisrc -FEbin -Flsrc -k-lm \
              src/tests/DiagAutoIdx.pas
  Run:   LD_LIBRARY_PATH=$PWD/src bin/DiagAutoIdx
}
program DiagAutoIdx;

uses
  SysUtils,
  passqlite3types, passqlite3util, passqlite3vdbe,
  passqlite3codegen, passqlite3main;

var
  db: PTsqlite3;
  rc: i32;

procedure RunDdl(const sql: AnsiString);
var
  pStmt: PVdbe;
  pTail: PAnsiChar;
  rcs:   i32;
begin
  pStmt := nil; pTail := nil;
  rcs := sqlite3_prepare_v2(db, PAnsiChar(sql), -1, @pStmt, @pTail);
  if pStmt <> nil then begin
    repeat rcs := sqlite3_step(pStmt) until rcs <> SQLITE_ROW;
    sqlite3_finalize(pStmt);
  end;
end;

procedure DumpRows(const sql: AnsiString);
var
  pStmt: PVdbe;
  pTail: PAnsiChar;
  rcs, i, nCol: i32;
  txt: PAnsiChar;
  line: AnsiString;
begin
  WriteLn('--- ', sql);
  pStmt := nil; pTail := nil;
  rcs := sqlite3_prepare_v2(db, PAnsiChar(sql), -1, @pStmt, @pTail);
  if pStmt = nil then begin WriteLn('  prepare rc=', rcs); Exit; end;
  while True do begin
    rcs := sqlite3_step(pStmt);
    if rcs <> SQLITE_ROW then break;
    nCol := sqlite3_column_count(pStmt);
    line := '';
    for i := 0 to nCol - 1 do begin
      txt := sqlite3_column_text(pStmt, i);
      if txt <> nil then line := line + AnsiString(txt) else line := line + '<NULL>';
      if i < nCol - 1 then line := line + ' | ';
    end;
    WriteLn('  ', line);
  end;
  sqlite3_finalize(pStmt);
end;

procedure DumpBytecode(const sql: AnsiString);
var
  pStmt: PVdbe;
  pTail: PAnsiChar;
  rcs, i: i32;
  pop: PVdbeOp;
  nm:  PAnsiChar;
begin
  WriteLn('=== EXPLAIN ', sql);
  pStmt := nil; pTail := nil;
  rcs := sqlite3_prepare_v2(db, PAnsiChar(sql), -1, @pStmt, @pTail);
  if pStmt = nil then begin WriteLn('  prepare rc=', rcs); Exit; end;
  for i := 0 to pStmt^.nOp - 1 do begin
    pop := PVdbeOp(PtrUInt(pStmt^.aOp) + PtrUInt(i) * SizeOf(TVdbeOp));
    nm  := sqlite3OpcodeName(pop^.opcode);
    WriteLn('  [', i, '] ', AnsiString(nm),
            ' p1=', pop^.p1, ' p2=', pop^.p2, ' p3=', pop^.p3,
            ' p5=', pop^.p5);
  end;
  sqlite3_finalize(pStmt);
end;

begin
  db := nil;
  rc := sqlite3_open(':memory:', @db);
  if rc <> 0 then Halt(1);

  RunDdl('CREATE TABLE t(a,b,c)');
  RunDdl('CREATE TABLE s(x,y,z)');
  RunDdl('CREATE TABLE u(p PRIMARY KEY, q)');

  DumpRows('SELECT name, type, tbl_name, rootpage FROM sqlite_schema');
  DumpBytecode('SELECT p FROM u');

  sqlite3_close(db);
end.
