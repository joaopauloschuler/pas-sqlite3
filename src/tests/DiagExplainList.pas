{ DiagExplainList — exercise sqlite3VdbeList by stepping an EXPLAIN
  prepared statement.  EXPLAIN emits 8 result columns: addr, opcode,
  p1, p2, p3, p4, p5, comment.  We compare the row-count and the first
  few opcode names against the C reference. }

program DiagExplainList;
{$mode objfpc}{$H+}
uses
  SysUtils,
  passqlite3types, passqlite3util, passqlite3vdbe,
  passqlite3codegen, passqlite3main, csqlite3;

var
  diverged: i32 = 0;

procedure RunOne(const lbl, sql: AnsiString);
var
  pasDb, cDb: Pointer;
  pasStmt, cStmt: Pointer;
  pasRows, cRows: Integer;
  pasFirstOp, cFirstOp: AnsiString;
  pTxt: PAnsiChar;
  pTail: PAnsiChar;
  rc: Integer;
begin
  pasDb := nil; cDb := nil;
  pasRows := 0; cRows := 0;
  pasFirstOp := ''; cFirstOp := '';

  if sqlite3_open(':memory:', @pasDb) = 0 then begin
    pasStmt := nil;
    if (sqlite3_prepare_v2(pasDb, PAnsiChar(sql), -1, @pasStmt, nil) = 0)
      and (pasStmt <> nil) then begin
      while True do begin
        rc := sqlite3_step(pasStmt);
        if rc <> SQLITE_ROW then break;
        Inc(pasRows);
        if pasRows = 1 then begin
          pTxt := PAnsiChar(sqlite3_column_text(pasStmt, 1));
          if pTxt <> nil then pasFirstOp := AnsiString(pTxt);
        end;
      end;
      sqlite3_finalize(pasStmt);
    end;
    sqlite3_close(pasDb);
  end;

  if csq_open(':memory:', cDb) = 0 then begin
    cStmt := nil; pTail := nil;
    if (csq_prepare_v2(cDb, PAnsiChar(sql), -1, cStmt, pTail) = 0)
      and (cStmt <> nil) then begin
      while True do begin
        rc := csq_step(cStmt);
        if rc <> SQLITE_ROW then break;
        Inc(cRows);
        if cRows = 1 then begin
          pTxt := PAnsiChar(csq_column_text(cStmt, 1));
          if pTxt <> nil then cFirstOp := AnsiString(pTxt);
        end;
      end;
      csq_finalize(cStmt);
    end;
    csq_close(cDb);
  end;

  if (pasRows = cRows) and (pasFirstOp = cFirstOp) then
    Writeln(Format('PASS    %-30s rows=%d first=%s', [lbl, cRows, cFirstOp]))
  else begin
    Inc(diverged);
    Writeln(Format('DIVERGE %s', [lbl]));
    Writeln(Format('   sql  =%s', [sql]));
    Writeln(Format('   Pas: rows=%d first=%s', [pasRows, pasFirstOp]));
    Writeln(Format('   C  : rows=%d first=%s', [cRows, cFirstOp]));
  end;
end;

begin
  { Trivial program — Init/Halt only. }
  RunOne('explain SELECT 1',     'EXPLAIN SELECT 1');
  RunOne('explain CREATE TABLE', 'EXPLAIN CREATE TABLE t(a, b)');
  Writeln('Total divergences: ', diverged);
  if diverged > 0 then Halt(1);
end.
