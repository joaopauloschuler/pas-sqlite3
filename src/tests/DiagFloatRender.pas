{$I ../passqlite3.inc}
{
  DiagFloatRender — differential probe of column_text() formatting for
  REAL values.  Targets Phase 6.10 step 10(b): vdbeMemRenderNum routed
  through sqlite3FpDecode + altform2 round-trip optimisation must
  produce the shortest decimal that still round-trips, matching C.
}
program DiagFloatRender;

uses
  SysUtils,
  passqlite3types, passqlite3util, passqlite3vdbe,
  passqlite3main, csqlite3;

procedure ProbeOne(const sql: AnsiString);
var
  pasDb:          PTsqlite3;
  cDb:            Pcsq_db;
  pasS:           PVdbe;
  cS:             Pcsq_stmt;
  pasTxt, cTxt:   PAnsiChar;
  pasA, cA:       AnsiString;
  rc: i32;
  pTail: PChar;
begin
  pasDb := nil;
  if sqlite3_open(':memory:', @pasDb) <> 0 then begin WriteLn('open pas fail'); Exit; end;
  cDb := nil;
  if csq_open(':memory:', cDb) <> 0 then begin WriteLn('open c fail'); Exit; end;
  pasS := nil; cS := nil; pTail := nil;
  rc := sqlite3_prepare_v2(pasDb, PAnsiChar(sql), -1, @pasS, nil);
  if rc <> 0 then begin WriteLn('pas prepare rc=', rc, ' sql=', sql); end;
  rc := csq_prepare_v2(cDb, PAnsiChar(sql), -1, cS, pTail);
  if rc <> 0 then begin WriteLn('c prepare rc=', rc, ' sql=', sql); end;
  pasA := ''; cA := '';
  if sqlite3_step(pasS) = 100 then begin
    pasTxt := sqlite3_column_text(pasS, 0);
    if pasTxt <> nil then pasA := AnsiString(pasTxt);
  end;
  if csq_step(cS) = 100 then begin
    cTxt := csq_column_text(cS, 0);
    if cTxt <> nil then cA := AnsiString(cTxt);
  end;
  if pasA = cA then
    WriteLn('OK   ', sql, ' = ', pasA)
  else
    WriteLn('DIFF ', sql, ' pas="', pasA, '" c="', cA, '"');
  sqlite3_finalize(pasS); csq_finalize(cS);
  sqlite3_close(pasDb); csq_close(cDb);
end;

begin
  ProbeOne('SELECT round(3.14159, 2)');
  ProbeOne('SELECT 49.47');
  ProbeOne('SELECT 0.1');
  ProbeOne('SELECT 1.0');
  ProbeOne('SELECT 1e100');
  ProbeOne('SELECT 1.23456789012345e-5');
  ProbeOne('SELECT 3.14');
  ProbeOne('SELECT round(2.5)');
  ProbeOne('SELECT 0.00001');
  ProbeOne('SELECT -0.5');
  ProbeOne('SELECT 1e308');
end.
