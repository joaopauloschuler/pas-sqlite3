{$I passqlite3.inc}
program DiagSampleProg;
{
  Phase 8.10 gate — Public-API sample-program parity.

  Pascal transliterations of the canonical SQLite sample programs from
  https://www.sqlite.org/quickstart.html and https://www.sqlite.org/cintro.html
  are run through both the C reference (csqlite3 → upstream libsqlite3.so)
  and the Pascal port (passqlite3main).  Each sample produces a textual
  transcript (the same bytes the doc example would print to stdout).  The
  gate fails if any transcript diverges.

  Three samples:
    1. quickstart    — sqlite3_exec with a "col = val" callback.
    2. cintro_step   — prepare/step/column_text loop.
    3. bind_insert   — prepared INSERT with bind_int + bind_text, then
                       a quickstart-style read-back via sqlite3_exec.

  Both engines see :memory: only; no filesystem state crosses runs.
}

uses
  SysUtils,
  passqlite3types,
  passqlite3util,
  passqlite3os,
  passqlite3pcache,
  passqlite3pager,
  passqlite3wal,
  passqlite3btree,
  passqlite3vdbe,
  passqlite3codegen,
  passqlite3parser,
  passqlite3vtab,
  passqlite3main,
  csqlite3;

var
  passes: i32 = 0;
  fails:  i32 = 0;
  buf:    AnsiString;

procedure Check(const name: string; cond: Boolean);
begin
  if cond then begin
    Inc(passes); WriteLn('  PASS ', name);
  end else begin
    Inc(fails);  WriteLn('  FAIL ', name);
  end;
end;

{ ---------- shared callback (matches the quickstart.html sample) ---------- }

function QuickstartCallback(pArg: Pointer; nCol: i32;
  argv: PPAnsiChar; colv: PPAnsiChar): i32; cdecl;
var
  i: i32;
  pCol, pVal: PPAnsiChar;
  zCol, zVal: PAnsiChar;
  pBuf: ^AnsiString;
begin
  pBuf := pArg;
  pCol := colv;
  pVal := argv;
  for i := 0 to nCol - 1 do begin
    zCol := pCol^;
    zVal := pVal^;
    if zVal = nil then
      pBuf^ := pBuf^ + zCol + ' = NULL'#10
    else
      pBuf^ := pBuf^ + zCol + ' = ' + zVal + #10;
    Inc(pCol);
    Inc(pVal);
  end;
  pBuf^ := pBuf^ + #10;
  Result := 0;
end;

{ Same body — separate symbol because the C side uses a different cdecl
  callback signature (PPChar vs PPAnsiChar are layout-identical but
  compile-time distinct). }
function QuickstartCallbackC(pArg: Pointer; nCol: Int32;
  argv: PPChar; colv: PPChar): Int32; cdecl;
var
  i: Int32;
  pCol, pVal: PPChar;
  zCol, zVal: PChar;
  pBuf: ^AnsiString;
begin
  pBuf := pArg;
  pCol := colv;
  pVal := argv;
  for i := 0 to nCol - 1 do begin
    zCol := pCol^;
    zVal := pVal^;
    if zVal = nil then
      pBuf^ := pBuf^ + zCol + ' = NULL'#10
    else
      pBuf^ := pBuf^ + zCol + ' = ' + zVal + #10;
    Inc(pCol);
    Inc(pVal);
  end;
  pBuf^ := pBuf^ + #10;
  Result := 0;
end;

{ ---------------------------- Pascal-port runs --------------------------- }

procedure RunSample_Pas_Quickstart(out transcript: AnsiString);
var
  db: PTsqlite3;
  rc: i32;
  pErr: PAnsiChar;
begin
  transcript := '';
  rc := sqlite3_open(':memory:', @db);
  if rc <> SQLITE_OK then begin
    transcript := 'open failed';
    sqlite3_close(db);
    Exit;
  end;

  pErr := nil;
  rc := sqlite3_exec(db,
    'CREATE TABLE t(a INTEGER, b TEXT);'#10 +
    'INSERT INTO t VALUES(1,''one'');'#10 +
    'INSERT INTO t VALUES(2,''two'');'#10 +
    'INSERT INTO t VALUES(3,NULL);',
    nil, nil, @pErr);
  if rc <> SQLITE_OK then begin
    if pErr <> nil then begin
      transcript := transcript + 'setup error: ' + pErr + #10;
      sqlite3_free(pErr);
    end;
    sqlite3_close(db);
    Exit;
  end;

  rc := sqlite3_exec(db, 'SELECT a,b FROM t ORDER BY a;',
                     @QuickstartCallback, @transcript, @pErr);
  if rc <> SQLITE_OK then begin
    if pErr <> nil then begin
      transcript := transcript + 'select error: ' + pErr + #10;
      sqlite3_free(pErr);
    end;
  end;

  sqlite3_close(db);
end;

procedure RunSample_Pas_Step(out transcript: AnsiString);
var
  db: PTsqlite3;
  pStmt: Pointer;
  rc: i32;
  pErr: PAnsiChar;
  zCol0, zCol1: PAnsiChar;
  v0: i32;
begin
  transcript := '';
  rc := sqlite3_open(':memory:', @db);
  if rc <> SQLITE_OK then begin transcript := 'open'; sqlite3_close(db); Exit; end;
  pErr := nil;
  sqlite3_exec(db,
    'CREATE TABLE t(a INTEGER, b TEXT);'#10 +
    'INSERT INTO t VALUES(10,''ten'');'#10 +
    'INSERT INTO t VALUES(20,''twenty'');'#10 +
    'INSERT INTO t VALUES(30,''thirty'');',
    nil, nil, @pErr);
  if pErr <> nil then begin sqlite3_free(pErr); pErr := nil; end;

  rc := sqlite3_prepare_v2(db, 'SELECT a,b FROM t ORDER BY a;', -1, @pStmt, nil);
  if rc <> SQLITE_OK then begin sqlite3_close(db); Exit; end;
  while sqlite3_step(pStmt) = SQLITE_ROW do begin
    v0 := sqlite3_column_int(pStmt, 0);
    zCol0 := sqlite3_column_name(pStmt, 0);
    zCol1 := sqlite3_column_name(pStmt, 1);
    transcript := transcript + zCol0 + '=' + IntToStr(v0)
                  + ' ' + zCol1 + '='
                  + PAnsiChar(sqlite3_column_text(pStmt, 1)) + #10;
  end;
  sqlite3_finalize(pStmt);
  sqlite3_close(db);
end;

procedure RunSample_Pas_BindInsert(out transcript: AnsiString);
var
  db: PTsqlite3;
  pStmt: Pointer;
  rc, i: i32;
  pErr: PAnsiChar;
  names: array[0..2] of AnsiString;
const
  vals: array[0..2] of i32 = (101, 202, 303);
begin
  transcript := '';
  names[0] := 'alpha';
  names[1] := 'beta';
  names[2] := 'gamma';
  rc := sqlite3_open(':memory:', @db);
  if rc <> SQLITE_OK then begin sqlite3_close(db); Exit; end;
  pErr := nil;
  sqlite3_exec(db, 'CREATE TABLE t(a INTEGER, b TEXT);', nil, nil, @pErr);
  if pErr <> nil then begin sqlite3_free(pErr); pErr := nil; end;

  rc := sqlite3_prepare_v2(db, 'INSERT INTO t(a,b) VALUES(?1,?2);', -1, @pStmt, nil);
  if rc <> SQLITE_OK then begin sqlite3_close(db); Exit; end;
  for i := 0 to 2 do begin
    sqlite3_bind_int(pStmt, 1, vals[i]);
    sqlite3_bind_text(pStmt, 2, PAnsiChar(names[i]), -1, SQLITE_TRANSIENT);
    sqlite3_step(pStmt);
    sqlite3_reset(pStmt);
  end;
  sqlite3_finalize(pStmt);

  pErr := nil;
  sqlite3_exec(db, 'SELECT a,b FROM t ORDER BY a;',
               @QuickstartCallback, @transcript, @pErr);
  if pErr <> nil then sqlite3_free(pErr);
  sqlite3_close(db);
end;

{ ---------------------------- C-reference runs --------------------------- }

procedure RunSample_C_Quickstart(out transcript: AnsiString);
var
  db: Pcsq_db;
  rc: Int32;
  pErr: PChar;
begin
  transcript := '';
  rc := csq_open(':memory:', db);
  if rc <> SQLITE_OK then begin csq_close(db); Exit; end;
  pErr := nil;
  csq_exec(db,
    'CREATE TABLE t(a INTEGER, b TEXT);'#10 +
    'INSERT INTO t VALUES(1,''one'');'#10 +
    'INSERT INTO t VALUES(2,''two'');'#10 +
    'INSERT INTO t VALUES(3,NULL);',
    nil, nil, pErr);
  if pErr <> nil then begin csq_free(pErr); pErr := nil; end;
  csq_exec(db, 'SELECT a,b FROM t ORDER BY a;',
           @QuickstartCallbackC, @transcript, pErr);
  if pErr <> nil then csq_free(pErr);
  csq_close(db);
end;

procedure RunSample_C_Step(out transcript: AnsiString);
var
  db: Pcsq_db;
  pStmt: Pcsq_stmt;
  pTail: PChar;
  rc: Int32;
  pErr: PChar;
  v0: Int32;
begin
  transcript := '';
  rc := csq_open(':memory:', db);
  if rc <> SQLITE_OK then begin csq_close(db); Exit; end;
  pErr := nil;
  csq_exec(db,
    'CREATE TABLE t(a INTEGER, b TEXT);'#10 +
    'INSERT INTO t VALUES(10,''ten'');'#10 +
    'INSERT INTO t VALUES(20,''twenty'');'#10 +
    'INSERT INTO t VALUES(30,''thirty'');',
    nil, nil, pErr);
  if pErr <> nil then begin csq_free(pErr); pErr := nil; end;

  rc := csq_prepare_v2(db, 'SELECT a,b FROM t ORDER BY a;', -1, pStmt, pTail);
  if rc <> SQLITE_OK then begin csq_close(db); Exit; end;
  while csq_step(pStmt) = SQLITE_ROW do begin
    v0 := csq_column_int(pStmt, 0);
    transcript := transcript + csq_column_name(pStmt, 0) + '=' + IntToStr(v0)
                  + ' ' + csq_column_name(pStmt, 1) + '='
                  + csq_column_text(pStmt, 1) + #10;
  end;
  csq_finalize(pStmt);
  csq_close(db);
end;

procedure RunSample_C_BindInsert(out transcript: AnsiString);
var
  db: Pcsq_db;
  pStmt: Pcsq_stmt;
  pTail: PChar;
  rc, i: Int32;
  pErr: PChar;
  names: array[0..2] of AnsiString;
const
  vals: array[0..2] of Int32 = (101, 202, 303);
  C_TRANSIENT: Pointer = Pointer(-1);
begin
  transcript := '';
  names[0] := 'alpha';
  names[1] := 'beta';
  names[2] := 'gamma';
  rc := csq_open(':memory:', db);
  if rc <> SQLITE_OK then begin csq_close(db); Exit; end;
  pErr := nil;
  csq_exec(db, 'CREATE TABLE t(a INTEGER, b TEXT);', nil, nil, pErr);
  if pErr <> nil then begin csq_free(pErr); pErr := nil; end;

  rc := csq_prepare_v2(db, 'INSERT INTO t(a,b) VALUES(?1,?2);', -1, pStmt, pTail);
  if rc <> SQLITE_OK then begin csq_close(db); Exit; end;
  for i := 0 to 2 do begin
    csq_bind_int(pStmt, 1, vals[i]);
    csq_bind_text(pStmt, 2, PChar(names[i]), -1, C_TRANSIENT);
    csq_step(pStmt);
    csq_reset(pStmt);
  end;
  csq_finalize(pStmt);

  pErr := nil;
  csq_exec(db, 'SELECT a,b FROM t ORDER BY a;',
           @QuickstartCallbackC, @transcript, pErr);
  if pErr <> nil then csq_free(pErr);
  csq_close(db);
end;

{ ------------------------------ orchestrator ----------------------------- }

procedure CompareSample(const name: string;
                        const tPas, tC: AnsiString);
var
  i, n: i32;
  diverge: i32;
begin
  WriteLn('--- sample: ', name, ' ---');
  WriteLn('  Pas (', Length(tPas), ' bytes):');
  Write(tPas);
  WriteLn('  C   (', Length(tC), ' bytes):');
  Write(tC);
  Check(name + ' length match', Length(tPas) = Length(tC));
  if Length(tPas) = Length(tC) then begin
    diverge := -1;
    n := Length(tPas);
    for i := 1 to n do
      if tPas[i] <> tC[i] then begin diverge := i; Break; end;
    Check(name + ' bytes match', diverge = -1);
    if diverge <> -1 then
      WriteLn('    first diff at offset ', diverge,
              ' Pas=$', IntToHex(Ord(tPas[diverge]), 2),
              ' C=$',   IntToHex(Ord(tC[diverge]), 2));
  end;
end;

var
  tA1, tA2, tB1, tB2, tC1, tC2: AnsiString;
begin
  WriteLn('DiagSampleProg — Phase 8.10 sample-program parity');

  RunSample_Pas_Quickstart(tA1);
  RunSample_C_Quickstart  (tA2);
  CompareSample('quickstart', tA1, tA2);

  RunSample_Pas_Step(tB1);
  RunSample_C_Step  (tB2);
  CompareSample('cintro_step', tB1, tB2);

  RunSample_Pas_BindInsert(tC1);
  RunSample_C_BindInsert  (tC2);
  CompareSample('bind_insert', tC1, tC2);

  WriteLn;
  WriteLn('Results: ', passes, ' passed, ', fails, ' failed');
  if fails = 0 then Halt(0) else Halt(1);
end.
