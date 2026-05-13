{
  SPDX-License-Identifier: blessing

  This work is dedicated to all human kind, and also to all non-human kinds.

  Faithful port of SQLite 3 (https://sqlite.org/) from C to Free Pascal.
}
{$I ../passqlite3.inc}
{
  DiagCommon — shared harness for Diag* differential probes.

  The Diag* program family runs the same SQL through both the Pascal port
  (via passqlite3*) and the upstream C library (via csqlite3) and reports
  any divergence between the two.  Each program used to carry its own copy
  of the harness scaffolding; this unit hoists the common scaffolding so
  individual Diag programs reduce to a list of Probe calls plus a Halt at
  end.

  Currently exposes:
    ProbeOne(lbl, sql)            -- single-row probe.  Compares prepRc,
                                     stepRc, column-0 type, column-0 int64,
                                     column-0 text.  Matches the original
                                     PasRun1 / CRun1 / Probe shape used by
                                     DiagScalarFunc, DiagCast, DiagFunctions,
                                     DiagLikeGlob, DiagMoreFunc.
    ProbeRows(lbl, seed, sql)     -- seeded multi-row probe.  Optionally
                                     runs `seed` via sqlite3_exec, then
                                     prepares `sql` and concatenates every
                                     SQLITE_ROW as `[col0,col1,...]`
                                     joined with `;`.  Compares prepRc,
                                     stepRc, and the concatenated rows.
                                     Matches the original PasRunSeed /
                                     CRunSeed / Probe shape used by
                                     DiagWindow / DiagIndexing /
                                     DiagPredicates.
    ProbeSetupCheck(lbl, setup, check)
                                  -- single-row probe with a setup script.
                                     The Pas side splits `setup` on `;` and
                                     prepares/steps/finalises each statement
                                     individually (matches DiagOps/DiagPragma
                                     original semantics); the C side runs
                                     `setup` through csq_exec.  Then prepares
                                     `check`, compares prepRc, column-0 int,
                                     and column-0 text.  Used by DiagOps and
                                     DiagPragma.

  Future additions (intentionally not in v1):
    ProbeOneText(lbl, sql)        -- text-only variant for DiagPrintfFmt.
    ProbeOneNoInt(lbl, sql)       -- text + type variant for DiagArith.
}
unit DiagCommon;

interface

uses
  SysUtils,
  passqlite3types, passqlite3util, passqlite3vdbe,
  passqlite3codegen, passqlite3main, csqlite3;

var
  diverged: i32 = 0;

procedure ProbeOne(const lbl, sql: AnsiString);
procedure ProbeRows(const lbl, seed, sql: AnsiString);
procedure ProbeSetupCheck(const lbl, setup, check: AnsiString);

function DiagExitCode: Integer;

implementation

procedure PasRun1(const sql: AnsiString; out prepRc, stepRc: i32;
                  out asInt: Int64; out asText: AnsiString;
                  out colType: i32);
var
  db: PTsqlite3;
  pStmt: PVdbe;
  rcs: i32;
  zT: PAnsiChar;
begin
  prepRc := -1; stepRc := -1; asInt := 0; asText := ''; colType := -1;
  db := nil;
  if sqlite3_open(':memory:', @db) <> 0 then Exit;
  pStmt := nil;
  prepRc := sqlite3_prepare_v2(db, PAnsiChar(sql), -1, @pStmt, nil);
  if pStmt <> nil then begin
    rcs := sqlite3_step(pStmt);
    stepRc := rcs;
    if rcs = SQLITE_ROW then begin
      colType := sqlite3_column_type(pStmt, 0);
      asInt := sqlite3_column_int64(pStmt, 0);
      zT := PAnsiChar(sqlite3_column_text(pStmt, 0));
      if zT <> nil then asText := AnsiString(zT);
    end;
    sqlite3_finalize(pStmt);
  end;
  sqlite3_close(db);
end;

procedure CRun1(const sql: AnsiString; out prepRc, stepRc: i32;
                out asInt: Int64; out asText: AnsiString;
                out colType: i32);
var
  db: Pcsq_db;
  pStmt: Pcsq_stmt;
  pTail: PChar;
  rcs: Int32;
  zT: PChar;
begin
  prepRc := -1; stepRc := -1; asInt := 0; asText := ''; colType := -1;
  db := nil;
  if csq_open(':memory:', db) <> 0 then Exit;
  pStmt := nil; pTail := nil;
  prepRc := csq_prepare_v2(db, PAnsiChar(sql), -1, pStmt, pTail);
  if pStmt <> nil then begin
    rcs := csq_step(pStmt);
    stepRc := rcs;
    if rcs = SQLITE_ROW then begin
      colType := csq_column_type(pStmt, 0);
      asInt := csq_column_int64(pStmt, 0);
      zT := csq_column_text(pStmt, 0);
      if zT <> nil then asText := AnsiString(zT);
    end;
    csq_finalize(pStmt);
  end;
  csq_close(db);
end;

procedure ProbeOne(const lbl, sql: AnsiString);
var
  pPrep, pStep, pType, cPrep, cStep, cType: i32;
  pInt, cInt: Int64;
  pTxt, cTxt: AnsiString;
  ok: Boolean;
begin
  PasRun1(sql, pPrep, pStep, pInt, pTxt, pType);
  CRun1  (sql, cPrep, cStep, cInt, cTxt, cType);
  ok := (pPrep = cPrep) and (pStep = cStep) and (pType = cType)
        and (pInt = cInt) and (pTxt = cTxt);
  if ok then
    WriteLn('PASS    ', lbl)
  else
  begin
    Inc(diverged);
    WriteLn('DIVERGE ', lbl);
    WriteLn('   sql  =', sql);
    WriteLn('   Pas: prep=', pPrep, ' step=', pStep,
            ' type=', pType, ' int=', pInt, ' txt="', pTxt, '"');
    WriteLn('   C  : prep=', cPrep, ' step=', cStep,
            ' type=', cType, ' int=', cInt, ' txt="', cTxt, '"');
  end;
end;

procedure PasRunSeed(const seed, sql: AnsiString;
                     out prepRc, stepRc: i32;
                     out concat: AnsiString);
var
  db: PTsqlite3;
  pStmt: PVdbe;
  rcs, ncols, i: i32;
  zT: PAnsiChar;
  s: AnsiString;
begin
  prepRc := -1; stepRc := -1; concat := '';
  db := nil;
  if sqlite3_open(':memory:', @db) <> 0 then Exit;
  if seed <> '' then
    sqlite3_exec(db, PAnsiChar(seed), nil, nil, nil{%H-});
  pStmt := nil;
  prepRc := sqlite3_prepare_v2(db, PAnsiChar(sql), -1, @pStmt, nil);
  if pStmt <> nil then begin
    repeat
      rcs := sqlite3_step(pStmt);
      stepRc := rcs;
      if rcs = SQLITE_ROW then begin
        ncols := sqlite3_column_count(pStmt);
        s := '[';
        for i := 0 to ncols - 1 do begin
          if i > 0 then s := s + ',';
          zT := PAnsiChar(sqlite3_column_text(pStmt, i));
          if zT = nil then s := s + 'null'
          else s := s + AnsiString(zT);
        end;
        s := s + ']';
        if concat <> '' then concat := concat + ';';
        concat := concat + s;
      end;
    until rcs <> SQLITE_ROW;
    sqlite3_finalize(pStmt);
  end;
  sqlite3_close(db);
end;

procedure CRunSeed(const seed, sql: AnsiString;
                   out prepRc, stepRc: i32;
                   out concat: AnsiString);
var
  db: Pcsq_db;
  pStmt: Pcsq_stmt;
  pTail: PChar;
  rcs, ncols, i: Int32;
  zT: PChar;
  s: AnsiString;
  pErr: PChar;
begin
  prepRc := -1; stepRc := -1; concat := '';
  db := nil;
  if csq_open(':memory:', db) <> 0 then Exit;
  pErr := nil;
  if seed <> '' then
    csq_exec(db, PAnsiChar(seed), nil, nil, pErr);
  pStmt := nil; pTail := nil;
  prepRc := csq_prepare_v2(db, PAnsiChar(sql), -1, pStmt, pTail);
  if pStmt <> nil then begin
    repeat
      rcs := csq_step(pStmt);
      stepRc := rcs;
      if rcs = SQLITE_ROW then begin
        ncols := csq_column_count(pStmt);
        s := '[';
        for i := 0 to ncols - 1 do begin
          if i > 0 then s := s + ',';
          zT := csq_column_text(pStmt, i);
          if zT = nil then s := s + 'null'
          else s := s + AnsiString(zT);
        end;
        s := s + ']';
        if concat <> '' then concat := concat + ';';
        concat := concat + s;
      end;
    until rcs <> SQLITE_ROW;
    csq_finalize(pStmt);
  end;
  csq_close(db);
end;

procedure ProbeRows(const lbl, seed, sql: AnsiString);
var
  pPrep, pStep, cPrep, cStep: i32;
  pCat, cCat: AnsiString;
  ok: Boolean;
begin
  PasRunSeed(seed, sql, pPrep, pStep, pCat);
  CRunSeed  (seed, sql, cPrep, cStep, cCat);
  ok := (pPrep = cPrep) and (pStep = cStep) and (pCat = cCat);
  if ok then
    WriteLn('PASS    ', lbl)
  else
  begin
    Inc(diverged);
    WriteLn('DIVERGE ', lbl);
    WriteLn('   sql  =', sql);
    WriteLn('   Pas: prep=', pPrep, ' step=', pStep, ' rows="', pCat, '"');
    WriteLn('   C  : prep=', cPrep, ' step=', cStep, ' rows="', cCat, '"');
  end;
end;

procedure PasRunSetupCheck(const setup, check: AnsiString;
                           out checkPrep, val: i32; out txt: AnsiString);
var
  db: PTsqlite3;
  pStmt: PVdbe;
  rcs: i32;
  s, stmt2: AnsiString;
  p: i32;
  pTxt: PAnsiChar;
begin
  checkPrep := -1; val := -99999; txt := '';
  db := nil;
  if sqlite3_open(':memory:', @db) <> 0 then Exit;
  if setup <> '' then begin
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
  end;
  pStmt := nil;
  checkPrep := sqlite3_prepare_v2(db, PAnsiChar(check), -1, @pStmt, nil);
  if (checkPrep = 0) and (pStmt <> nil) then begin
    if sqlite3_step(pStmt) = SQLITE_ROW then begin
      val := sqlite3_column_int(pStmt, 0);
      pTxt := PAnsiChar(sqlite3_column_text(pStmt, 0));
      if pTxt <> nil then txt := AnsiString(pTxt);
    end;
    sqlite3_finalize(pStmt);
  end;
  sqlite3_close(db);
end;

procedure CRunSetupCheck(const setup, check: AnsiString;
                         out checkPrep, val: i32; out txt: AnsiString);
var
  db: Pcsq_db;
  pStmt: Pcsq_stmt;
  pTail, pErr: PChar;
  pTxt: PAnsiChar;
begin
  checkPrep := -1; val := -99999; txt := '';
  db := nil;
  if csq_open(':memory:', db) <> 0 then Exit;
  if setup <> '' then begin
    pErr := nil;
    csq_exec(db, PAnsiChar(setup), nil, nil, pErr);
  end;
  pStmt := nil; pTail := nil;
  checkPrep := csq_prepare_v2(db, PAnsiChar(check), -1, pStmt, pTail);
  if (checkPrep = 0) and (pStmt <> nil) then begin
    if csq_step(pStmt) = SQLITE_ROW then begin
      val := csq_column_int(pStmt, 0);
      pTxt := PAnsiChar(csq_column_text(pStmt, 0));
      if pTxt <> nil then txt := AnsiString(pTxt);
    end;
    csq_finalize(pStmt);
  end;
  csq_close(db);
end;

procedure ProbeSetupCheck(const lbl, setup, check: AnsiString);
var
  pPrep, pVal: i32;
  cPrep, cVal: i32;
  pTxt, cTxt: AnsiString;
  ok: Boolean;
begin
  PasRunSetupCheck(setup, check, pPrep, pVal, pTxt);
  CRunSetupCheck  (setup, check, cPrep, cVal, cTxt);
  ok := (pPrep = cPrep) and (pVal = cVal) and (pTxt = cTxt);
  if ok then
    WriteLn('PASS    ', lbl)
  else
  begin
    Inc(diverged);
    WriteLn('DIVERGE ', lbl);
    WriteLn('   check=', check);
    WriteLn('   Pas: prep=', pPrep, ' val=', pVal, ' txt="', pTxt, '"');
    WriteLn('   C  : prep=', cPrep, ' val=', cVal, ' txt="', cTxt, '"');
  end;
end;

function DiagExitCode: Integer;
begin
  if diverged > 0 then Result := 1 else Result := 0;
end;

end.
