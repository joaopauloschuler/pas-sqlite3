{$I ../passqlite3.inc}
{ DiagGroupOrder — focused probe for GROUP BY ... ORDER BY DESC bug
  (tasklist 6.10 step 17(h)).  Prints sorter KeyInfo aSortFlags so we
  can verify whether the DESC sort flag is propagated end-to-end. }
program DiagGroupOrder;

uses
  SysUtils,
  passqlite3types, passqlite3util, passqlite3vdbe,
  passqlite3codegen, passqlite3main;

procedure RunPas(const sql: AnsiString);
var
  db: PTsqlite3;
  pStmt: PVdbe;
  rcs, ncols, i: i32;
  zT: PAnsiChar;
begin
  db := nil;
  if sqlite3_open(':memory:', @db) <> 0 then Exit;
  sqlite3_exec(db, 'CREATE TABLE g(grp,val);'
    + 'INSERT INTO g VALUES(''A'',1);'
    + 'INSERT INTO g VALUES(''A'',2);'
    + 'INSERT INTO g VALUES(''B'',3);'
    + 'INSERT INTO g VALUES(''B'',4);'
    + 'INSERT INTO g VALUES(''B'',5);', nil, nil, nil{%H-});
  pStmt := nil;
  sqlite3_prepare_v2(db, PAnsiChar(sql), -1, @pStmt, nil);
  if pStmt <> nil then begin
    repeat
      rcs := sqlite3_step(pStmt);
      if rcs = SQLITE_ROW then begin
        ncols := sqlite3_column_count(pStmt);
        Write('  row: ');
        for i := 0 to ncols - 1 do begin
          zT := sqlite3_column_text(pStmt, i);
          if zT <> nil then Write(zT) else Write('NULL');
          if i < ncols - 1 then Write('|');
        end;
        WriteLn;
      end;
    until (rcs <> SQLITE_ROW);
    sqlite3_finalize(pStmt);
  end;
  sqlite3_close(db);
end;

begin
  WriteLn('--- GROUP BY grp ORDER BY grp DESC ---');
  RunPas('SELECT grp, sum(val) FROM g GROUP BY grp ORDER BY grp DESC');
  WriteLn('--- GROUP BY grp ORDER BY grp ASC ---');
  RunPas('SELECT grp, sum(val) FROM g GROUP BY grp ORDER BY grp ASC');
  WriteLn('--- GROUP BY grp (no order) ---');
  RunPas('SELECT grp, sum(val) FROM g GROUP BY grp');
end.
