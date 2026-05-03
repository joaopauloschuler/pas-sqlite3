{$I ../passqlite3.inc}
program DiagErrMsg16;
{ Differential probe for sqlite3_errmsg16 (main.c:2775). }
uses
  SysUtils,
  passqlite3types, passqlite3util, passqlite3vdbe, passqlite3codegen,
  passqlite3main, csqlite3;

function Utf16Compare(a, b: PWord): i32;
var
  i: i32;
begin
  i := 0;
  while True do begin
    if a[i] <> b[i] then begin Result := i32(a[i]) - i32(b[i]); Exit; end;
    if a[i] = 0 then begin Result := 0; Exit; end;
    Inc(i);
  end;
end;

function Utf16Show(p: PWord): AnsiString;
var
  i: i32;
begin
  Result := '';
  if p = nil then begin Result := '<nil>'; Exit; end;
  i := 0;
  while p[i] <> 0 do begin
    if (p[i] >= 32) and (p[i] < 127) then
      Result := Result + AnsiChar(Byte(p[i]))
    else
      Result := Result + '?';
    Inc(i);
  end;
end;

procedure CheckNullDb;
var
  zP, zC: PWord;
begin
  zP := PWord(sqlite3_errmsg16(nil));
  zC := PWord(csq_errmsg16(nil));
  if Utf16Compare(zP, zC) = 0 then
    WriteLn('PASS    nil db | "', Utf16Show(zP), '"')
  else
    WriteLn('DIVERGE nil db | Pas="', Utf16Show(zP), '" C="', Utf16Show(zC), '"');
end;

procedure CheckParse;
var
  pdb: PTsqlite3; cdb: Pcsq_db;
  pStmt: PVdbe; cStmt: Pcsq_stmt; cTail: PChar;
  zP, zC: PWord;
begin
  pdb := nil; cdb := nil;
  if sqlite3_open(':memory:', @pdb) <> 0 then Exit;
  if csq_open(PChar(':memory:'), cdb) <> 0 then Exit;
  pStmt := nil; cStmt := nil;
  sqlite3_prepare_v2(pdb, PAnsiChar('SLECT 1'), -1, @pStmt, nil);
  csq_prepare_v2(cdb, PAnsiChar('SLECT 1'), -1, cStmt, cTail);
  zP := PWord(sqlite3_errmsg16(pdb));
  zC := PWord(csq_errmsg16(cdb));
  if Utf16Compare(zP, zC) = 0 then
    WriteLn('PASS    parse error | "', Utf16Show(zP), '"')
  else
    WriteLn('DIVERGE parse error | Pas="', Utf16Show(zP), '" C="', Utf16Show(zC), '"');
  if pStmt <> nil then sqlite3_finalize(pStmt);
  if cStmt <> nil then csq_finalize(cStmt);
  sqlite3_close(pdb); csq_close(cdb);
end;

procedure CheckOk;
var
  pdb: PTsqlite3; cdb: Pcsq_db;
  zP, zC: PWord;
begin
  pdb := nil; cdb := nil;
  if sqlite3_open(':memory:', @pdb) <> 0 then Exit;
  if csq_open(PChar(':memory:'), cdb) <> 0 then Exit;
  zP := PWord(sqlite3_errmsg16(pdb));
  zC := PWord(csq_errmsg16(cdb));
  if Utf16Compare(zP, zC) = 0 then
    WriteLn('PASS    fresh db | "', Utf16Show(zP), '"')
  else
    WriteLn('DIVERGE fresh db | Pas="', Utf16Show(zP), '" C="', Utf16Show(zC), '"');
  sqlite3_close(pdb); csq_close(cdb);
end;

begin
  CheckNullDb;
  CheckOk;
  CheckParse;
end.
