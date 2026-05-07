{
  SPDX-License-Identifier: blessing

  Faithful port of ../sqlite3/ext/misc/dbdump.c (~724 lines in C).

  Implements sqlite3_db_dump(db, zSchema, zTable, xCallback, pArg):
  serialise an open SQLite database connection into UTF-8 text SQL
  statements that can be replayed to recreate the database byte-for-
  byte (ROWIDs preserved for tables that need them).  Output is fed
  to xCallback() in chunks (signature compatible with C `fputs`).

  Public entry: sqlite3_db_dump — exact signature mirror.
}
{$I passqlite3.inc}
unit passqlite3dbdump;

interface

uses
  passqlite3types,
  passqlite3util,
  passqlite3main;

type
  TDbDumpCallback = function(z: PAnsiChar; pArg: Pointer): i32; cdecl;

function sqlite3_db_dump(db: PTsqlite3;
                        zSchema: PAnsiChar;
                        zTable: PAnsiChar;
                        xCallback: TDbDumpCallback;
                        pArg: Pointer): i32; cdecl;

implementation

uses
  SysUtils,
  passqlite3os,
  passqlite3vdbe,
  passqlite3parser,
  passqlite3codegen,
  passqlite3printf;

type
  PDState = ^TDState;
  TDState = record
    db             : PTsqlite3;
    nErr           : i32;
    rc             : i32;
    writableSchema : i32;
    xCallback      : TDbDumpCallback;
    pArg           : Pointer;
  end;

  PDText = ^TDText;
  TDText = record
    z      : PAnsiChar;
    n      : i64;
    nAlloc : i64;
  end;

  PPAnsiCharArr = ^TPAnsiCharArr;
  TPAnsiCharArr = array[0..(High(PtrInt) div SizeOf(PAnsiChar)) - 1] of PAnsiChar;

{ dbdump.c:78 — initialize a DText. }
procedure initText(p: PDText); inline;
begin
  p^.z := nil;
  p^.n := 0;
  p^.nAlloc := 0;
end;

{ dbdump.c:81 — destroy a DText. }
procedure freeText(p: PDText); inline;
begin
  sqlite3_free(p^.z);
  initText(p);
end;

{ Same as C's strlen but capped at 0x3fffffff (matches dbdump.c:97). }
function clampedStrlen(z: PAnsiChar): i32; inline;
var n: PtrUInt;
begin
  if z = nil then begin Result := 0; Exit; end;
  n := StrLen(z) and $3fffffff;
  Result := i32(n);
end;

{ dbdump.c:94 — append zAppend to p, optionally surrounded by `quote` and
  with embedded `quote` chars doubled. }
procedure appendText(p: PDText; zAppend: PAnsiChar; quote: AnsiChar);
var
  len, nAppend, i: i32;
  zNew, zCsr: PAnsiChar;
begin
  nAppend := clampedStrlen(zAppend);
  len := nAppend + p^.n + 1;
  if quote <> #0 then begin
    Inc(len, 2);
    for i := 0 to nAppend - 1 do
      if zAppend[i] = quote then Inc(len);
  end;

  if p^.n + len >= p^.nAlloc then begin
    p^.nAlloc := p^.nAlloc * 2 + len + 20;
    zNew := PAnsiChar(sqlite3_realloc64(p^.z, u64(p^.nAlloc)));
    if zNew = nil then begin
      freeText(p);
      Exit;
    end;
    p^.z := zNew;
  end;

  if quote <> #0 then begin
    zCsr := p^.z + p^.n;
    zCsr^ := quote; Inc(zCsr);
    for i := 0 to nAppend - 1 do begin
      zCsr^ := zAppend[i]; Inc(zCsr);
      if zAppend[i] = quote then begin
        zCsr^ := quote; Inc(zCsr);
      end;
    end;
    zCsr^ := quote; Inc(zCsr);
    p^.n := i64(zCsr - p^.z);
    zCsr^ := #0;
  end else begin
    if nAppend > 0 then
      Move(zAppend^, (p^.z + p^.n)^, nAppend);
    Inc(p^.n, nAppend);
    p^.z[p^.n] := #0;
  end;
end;

{ dbdump.c:143 — return '"' if zName needs SQL quoting, else 0. }
function quoteChar(zName: PAnsiChar): AnsiChar;
var
  i: i32;
  c: AnsiChar;
begin
  if zName = nil then begin Result := #0; Exit; end;
  c := zName[0];
  if not (((c >= 'a') and (c <= 'z')) or ((c >= 'A') and (c <= 'Z'))
          or (c = '_')) then begin
    Result := '"'; Exit;
  end;
  i := 0;
  while zName[i] <> #0 do begin
    c := zName[i];
    if not (((c >= 'a') and (c <= 'z')) or ((c >= 'A') and (c <= 'Z'))
            or ((c >= '0') and (c <= '9')) or (c = '_')) then begin
      Result := '"'; Exit;
    end;
    Inc(i);
  end;
  if sqlite3_keyword_check(zName, i) <> 0 then
    Result := '"'
  else
    Result := #0;
end;

{ dbdump.c:156 — release a column-name array allocated by tableColumnList. }
procedure freeColumnList(azCol: PPAnsiCharArr);
var i: i32;
begin
  if azCol = nil then Exit;
  i := 1;
  while azCol^[i] <> nil do begin
    sqlite3_free(azCol^[i]);
    Inc(i);
  end;
  { azCol[0] is a static rowid alias, not malloc'd — see tableColumnList. }
  sqlite3_free(azCol);
end;

{ Module-level static names used by tableColumnList for the rowid alias.
  The C source uses string literals; in Pascal we materialise constants
  pointed at by PAnsiChar so they survive past the function. }
const
  cRowidName    : PAnsiChar = 'rowid';
  cRowidNameUS  : PAnsiChar = '_rowid_';
  cRowidNameOID : PAnsiChar = 'oid';

{ dbdump.c:178 — return list of column names for table zTab.  Caller
  frees via freeColumnList.  azCol[0] is the rowid alias name (or nil). }
function tableColumnList(p: PDState; zTab: PAnsiChar): PPAnsiCharArr;
label
  col_oom;
var
  azCol: PPAnsiCharArr;
  azNew: PPAnsiCharArr;
  pStmt: PVdbe;
  zSql:  PAnsiChar;
  nCol, nAlloc: i64;
  nPK, isIPK, preserveRowid, rc, i, j: i32;
  zRowid: array[0..2] of PAnsiChar;
  zColText: PAnsiChar;
  zType: PAnsiChar;
begin
  azCol := nil;
  pStmt := nil;
  nCol := 0;
  nAlloc := 0;
  nPK := 0;
  isIPK := 0;
  preserveRowid := 1;

  zSql := sqlite3PfMprintf('PRAGMA table_info=%Q', [zTab]);
  if zSql = nil then begin Result := nil; Exit; end;
  rc := sqlite3_prepare_v2(p^.db, zSql, -1, @pStmt, nil);
  sqlite3_free(zSql);
  if rc <> 0 then begin Result := nil; Exit; end;

  while sqlite3_step(pStmt) = SQLITE_ROW do begin
    if nCol >= nAlloc - 2 then begin
      nAlloc := nAlloc * 2 + nCol + 10;
      azNew := PPAnsiCharArr(sqlite3_realloc64(azCol,
                              u64(nAlloc * SizeOf(PAnsiChar))));
      if azNew = nil then goto col_oom;
      azCol := azNew;
      azCol^[0] := nil;
    end;
    Inc(nCol);
    zColText := PAnsiChar(sqlite3_column_text(pStmt, 1));
    azCol^[nCol] := sqlite3PfMprintf('%s', [zColText]);
    if azCol^[nCol] = nil then goto col_oom;
    if sqlite3_column_int(pStmt, 5) <> 0 then begin
      Inc(nPK);
      zType := PAnsiChar(sqlite3_column_text(pStmt, 2));
      if (nPK = 1) and (sqlite3_stricmp(zType, 'INTEGER') = 0) then
        isIPK := 1
      else
        isIPK := 0;
    end;
  end;
  sqlite3_finalize(pStmt);
  pStmt := nil;
  if azCol = nil then begin Result := nil; Exit; end;
  azCol^[nCol + 1] := nil;

  if isIPK <> 0 then begin
    zSql := sqlite3PfMprintf('SELECT 1 FROM pragma_index_list(%Q)' +
                             ' WHERE origin=''pk''', [zTab]);
    if zSql = nil then goto col_oom;
    rc := sqlite3_prepare_v2(p^.db, zSql, -1, @pStmt, nil);
    sqlite3_free(zSql);
    if rc <> 0 then begin
      freeColumnList(azCol);
      Result := nil; Exit;
    end;
    rc := sqlite3_step(pStmt);
    sqlite3_finalize(pStmt);
    pStmt := nil;
    if rc = SQLITE_ROW then preserveRowid := 1 else preserveRowid := 0;
  end;

  if preserveRowid <> 0 then begin
    zRowid[0] := cRowidName;
    zRowid[1] := cRowidNameUS;
    zRowid[2] := cRowidNameOID;
    for j := 0 to 2 do begin
      i := 1;
      while i <= nCol do begin
        if sqlite3_stricmp(zRowid[j], azCol^[i]) = 0 then break;
        Inc(i);
      end;
      if i > nCol then begin
        rc := sqlite3_table_column_metadata(p^.db, nil, zTab, zRowid[j],
                                            nil, nil, nil, nil, nil);
        if rc = SQLITE_OK then azCol^[0] := zRowid[j];
        break;
      end;
    end;
  end;

  Result := azCol;
  Exit;

col_oom:
  sqlite3_finalize(pStmt);
  freeColumnList(azCol);
  Inc(p^.nErr);
  p^.rc := SQLITE_NOMEM;
  Result := nil;
end;

{ dbdump.c:282 — emit sqlite3_mprintf-formatted text to xCallback. }
procedure outputFormatted(p: PDState; zFormat: PAnsiChar;
                          const args: array of const);
var z: PAnsiChar;
begin
  z := sqlite3PfMprintf(zFormat, args);
  p^.xCallback(z, p^.pArg);
  sqlite3_free(z);
end;

{ dbdump.c:299 — return a string not present in z[].  Tries zA / zB
  first; otherwise composes "(zA<u>)" into zBuf. }
function unusedString(z, zA, zB, zBuf: PAnsiChar): PAnsiChar;
var
  i: u32;
  zTmp: AnsiString;
  k: i32;
begin
  if StrPos(z, zA) = nil then begin Result := zA; Exit; end;
  if StrPos(z, zB) = nil then begin Result := zB; Exit; end;
  i := 0;
  repeat
    zTmp := Format('(%s%u)', [AnsiString(zA), i]);
    if Length(zTmp) > 19 then SetLength(zTmp, 19);
    for k := 1 to Length(zTmp) do zBuf[k - 1] := zTmp[k];
    zBuf[Length(zTmp)] := #0;
    Inc(i);
  until StrPos(z, zBuf) = nil;
  Result := zBuf;
end;

{ dbdump.c:319 — output an SQL string literal with embedded \n / \r
  escaped via replace() so end-of-line translation cannot corrupt the
  dump. }
procedure outputQuotedEscapedString(p: PDState; z: PAnsiChar);
var
  i, nNL, nCR: i32;
  c: AnsiChar;
  zNL, zCR: PAnsiChar;
  zBuf1, zBuf2: array[0..19] of AnsiChar;
begin
  i := 0;
  while True do begin
    c := z[i];
    if (c = #0) or (c = '''') or (c = #10) or (c = #13) then break;
    Inc(i);
  end;
  if c = #0 then begin
    outputFormatted(p, '''%s''', [z]);
    Exit;
  end;

  zNL := nil;
  zCR := nil;
  nNL := 0;
  nCR := 0;
  i := 0;
  while z[i] <> #0 do begin
    if z[i] = #10 then Inc(nNL);
    if z[i] = #13 then Inc(nCR);
    Inc(i);
  end;
  if nNL <> 0 then begin
    p^.xCallback('replace(', p^.pArg);
    zNL := unusedString(z, '\n', '\012', @zBuf1[0]);
  end;
  if nCR <> 0 then begin
    p^.xCallback('replace(', p^.pArg);
    zCR := unusedString(z, '\r', '\015', @zBuf2[0]);
  end;
  p^.xCallback('''', p^.pArg);

  while z^ <> #0 do begin
    i := 0;
    while True do begin
      c := z[i];
      if (c = #0) or (c = #10) or (c = #13) or (c = '''') then break;
      Inc(i);
    end;
    if c = '''' then Inc(i);
    if i > 0 then begin
      outputFormatted(p, '%.*s', [i, z]);
      Inc(z, i);
    end;
    if c = '''' then begin
      p^.xCallback('''', p^.pArg);
      Continue;
    end;
    if c = #0 then break;
    Inc(z);
    if c = #10 then begin
      p^.xCallback(zNL, p^.pArg);
      Continue;
    end;
    p^.xCallback(zCR, p^.pArg);
  end;

  p^.xCallback('''', p^.pArg);
  if nCR <> 0 then outputFormatted(p, ',''%s'',char(13))', [zCR]);
  if nNL <> 0 then outputFormatted(p, ',''%s'',char(10))', [zNL]);
end;

{ dbdump.c:381 — sqlite3_exec callback used for dumping schema rows.
  Each row carries (name, type, sql) for one schema object; the callback
  emits the appropriate CREATE statement plus, for tables, the INSERT
  statements that reproduce its rows. }
function dumpCallback(pArg: Pointer; nArg: i32;
                      azArg: PPAnsiChar;
                      azCol: PPAnsiChar): i32; cdecl;
var
  rc, i, nCol, nByte, j: i32;
  zTable, zType, zSql: PAnsiChar;
  p: PDState;
  pStmt: PVdbe;
  sSelect, sTable: TDText;
  azTCol: PPAnsiCharArr;
  azArr: PPAnsiCharArr;
  r: Double;
  ur: u64;
  a: PByte;
  zWord: array[0..2] of AnsiChar;
  hex: array[0..15] of AnsiChar;
const
  hexChars: PAnsiChar = '0123456789abcdef';
begin
  Result := 0;
  p := PDState(pArg);
  azArr := PPAnsiCharArr(azArg);
  if azCol = nil then begin end;  { unused }
  if nArg <> 3 then begin Result := 1; Exit; end;
  zTable := azArr^[0];
  zType  := azArr^[1];
  zSql   := azArr^[2];

  if StrComp(zTable, 'sqlite_sequence') = 0 then begin
    p^.xCallback('DELETE FROM sqlite_sequence;'#10, p^.pArg);
  end else if sqlite3_strglob('sqlite_stat?', zTable) = 0 then begin
    p^.xCallback('ANALYZE sqlite_schema;'#10, p^.pArg);
  end else if StrLComp(zTable, 'sqlite_', 7) = 0 then begin
    Exit;
  end else if StrLComp(zSql, 'CREATE VIRTUAL TABLE', 20) = 0 then begin
    if p^.writableSchema = 0 then begin
      p^.xCallback('PRAGMA writable_schema=ON;'#10, p^.pArg);
      p^.writableSchema := 1;
    end;
    outputFormatted(p,
      'INSERT INTO sqlite_schema(type,name,tbl_name,rootpage,sql)' +
      'VALUES(''table'',''%q'',''%q'',0,''%q'');',
      [zTable, zTable, zSql]);
    Exit;
  end else begin
    if sqlite3_strglob('CREATE TABLE [''"]*', zSql) = 0 then begin
      p^.xCallback('CREATE TABLE IF NOT EXISTS ', p^.pArg);
      p^.xCallback(zSql + 13, p^.pArg);
    end else begin
      p^.xCallback(zSql, p^.pArg);
    end;
    p^.xCallback(';'#10, p^.pArg);
  end;

  if StrComp(zType, 'table') <> 0 then Exit;

  azTCol := tableColumnList(p, zTable);
  if azTCol = nil then Exit;

  initText(@sTable);
  appendText(@sTable, 'INSERT INTO ', #0);
  appendText(@sTable, zTable, quoteChar(zTable));

  if azTCol^[0] <> nil then begin
    appendText(@sTable, '(', #0);
    appendText(@sTable, azTCol^[0], #0);
    i := 1;
    while azTCol^[i] <> nil do begin
      appendText(@sTable, ',', #0);
      appendText(@sTable, azTCol^[i], quoteChar(azTCol^[i]));
      Inc(i);
    end;
    appendText(@sTable, ')', #0);
  end;
  appendText(@sTable, ' VALUES(', #0);

  initText(@sSelect);
  appendText(@sSelect, 'SELECT ', #0);
  if azTCol^[0] <> nil then begin
    appendText(@sSelect, azTCol^[0], #0);
    appendText(@sSelect, ',', #0);
  end;
  i := 1;
  while azTCol^[i] <> nil do begin
    appendText(@sSelect, azTCol^[i], quoteChar(azTCol^[i]));
    if azTCol^[i + 1] <> nil then
      appendText(@sSelect, ',', #0);
    Inc(i);
  end;
  nCol := i;
  if azTCol^[0] = nil then Dec(nCol);
  freeColumnList(azTCol);
  appendText(@sSelect, ' FROM ', #0);
  appendText(@sSelect, zTable, quoteChar(zTable));

  rc := sqlite3_prepare_v2(p^.db, sSelect.z, -1, @pStmt, nil);
  if rc <> SQLITE_OK then begin
    Inc(p^.nErr);
    if p^.rc = SQLITE_OK then p^.rc := rc;
  end else begin
    while sqlite3_step(pStmt) = SQLITE_ROW do begin
      p^.xCallback(sTable.z, p^.pArg);
      for i := 0 to nCol - 1 do begin
        if i <> 0 then p^.xCallback(',', p^.pArg);
        case sqlite3_column_type(pStmt, i) of
          SQLITE_INTEGER:
            outputFormatted(p, '%lld', [sqlite3_column_int64(pStmt, i)]);
          SQLITE_FLOAT: begin
            r := sqlite3_column_double(pStmt, i);
            Move(r, ur, SizeOf(r));
            if ur = u64($7ff0000000000000) then
              p^.xCallback('1e999', p^.pArg)
            else if ur = u64($fff0000000000000) then
              p^.xCallback('-1e999', p^.pArg)
            else
              outputFormatted(p, '%!.20g', [r]);
          end;
          SQLITE_NULL:
            p^.xCallback('NULL', p^.pArg);
          SQLITE_TEXT:
            outputQuotedEscapedString(p,
                                      PAnsiChar(sqlite3_column_text(pStmt, i)));
          SQLITE_BLOB: begin
            nByte := sqlite3_column_bytes(pStmt, i);
            a := PByte(sqlite3_column_blob(pStmt, i));
            p^.xCallback('x''', p^.pArg);
            { hexChars is read-only; use PAnsiChar arithmetic. }
            for j := 0 to 15 do hex[j] := hexChars[j];
            for j := 0 to nByte - 1 do begin
              zWord[0] := hex[(a[j] shr 4) and 15];
              zWord[1] := hex[a[j] and 15];
              zWord[2] := #0;
              p^.xCallback(@zWord[0], p^.pArg);
            end;
            p^.xCallback('''', p^.pArg);
          end;
        end;
      end;
      p^.xCallback(');'#10, p^.pArg);
    end;
  end;
  sqlite3_finalize(pStmt);
  freeText(@sTable);
  freeText(@sSelect);
end;

{ dbdump.c:546 — run a SELECT and emit each row's column-0 text (followed
  by ',', col-1, col-2, ...) plus a ';' terminator.  Single-column
  results that contain "--" get the ';' on its own line so the comment
  doesn't swallow it. }
procedure outputSqlFromQuery(p: PDState; zSelect: PAnsiChar;
                             const args: array of const);
var
  pSelect: PVdbe;
  rc, nResult, i: i32;
  z: PAnsiChar;
  zSql: PAnsiChar;
begin
  zSql := sqlite3PfMprintf(zSelect, args);
  if zSql = nil then begin
    p^.rc := SQLITE_NOMEM;
    Inc(p^.nErr);
    Exit;
  end;
  rc := sqlite3_prepare_v2(p^.db, zSql, -1, @pSelect, nil);
  sqlite3_free(zSql);
  if (rc <> SQLITE_OK) or (pSelect = nil) then begin
    outputFormatted(p, '/**** ERROR: (%d) %s *****/'#10,
                    [rc, sqlite3_errmsg(p^.db)]);
    Inc(p^.nErr);
    Exit;
  end;
  rc := sqlite3_step(pSelect);
  nResult := sqlite3_column_count(pSelect);
  while rc = SQLITE_ROW do begin
    z := PAnsiChar(sqlite3_column_text(pSelect, 0));
    p^.xCallback(z, p^.pArg);
    for i := 1 to nResult - 1 do begin
      p^.xCallback(',', p^.pArg);
      p^.xCallback(PAnsiChar(sqlite3_column_text(pSelect, i)), p^.pArg);
    end;
    if z = nil then z := '';
    while (z[0] <> #0) and ((z[0] <> '-') or (z[1] <> '-')) do Inc(z);
    if z[0] <> #0 then
      p^.xCallback(#10';'#10, p^.pArg)
    else
      p^.xCallback(';'#10, p^.pArg);
    rc := sqlite3_step(pSelect);
  end;
  rc := sqlite3_finalize(pSelect);
  if rc <> SQLITE_OK then begin
    outputFormatted(p, '/**** ERROR: (%d) %s *****/'#10,
                    [rc, sqlite3_errmsg(p^.db)]);
    if (rc and $ff) <> SQLITE_CORRUPT then Inc(p^.nErr);
  end;
end;

{ dbdump.c:607 — sqlite3_exec wrapper that routes schema rows through
  dumpCallback.  zErr is captured into the output stream as a comment. }
procedure runSchemaDumpQuery(p: PDState; zQuery: PAnsiChar;
                             const args: array of const);
var
  zErr, z: PAnsiChar;
begin
  zErr := nil;
  z := sqlite3PfMprintf(zQuery, args);
  sqlite3_exec(p^.db, z, @dumpCallback, p, @zErr);
  sqlite3_free(z);
  if zErr <> nil then begin
    outputFormatted(p, '/****** %s ******/'#10, [zErr]);
    sqlite3_free(zErr);
    Inc(p^.nErr);
  end;
end;

{ dbdump.c:632 — public entry point. }
function sqlite3_db_dump(db: PTsqlite3;
                        zSchema: PAnsiChar;
                        zTable: PAnsiChar;
                        xCallback: TDbDumpCallback;
                        pArg: Pointer): i32; cdecl;
var
  x: TDState;
begin
  FillChar(x, SizeOf(x), 0);
  x.rc := sqlite3_exec(db, 'BEGIN', nil, nil, nil);
  if x.rc <> 0 then begin Result := x.rc; Exit; end;
  x.db := db;
  x.xCallback := xCallback;
  x.pArg := pArg;
  xCallback('PRAGMA foreign_keys=OFF;'#10'BEGIN TRANSACTION;'#10, pArg);
  if zTable = nil then begin
    runSchemaDumpQuery(@x,
      'SELECT name, type, sql FROM "%w".sqlite_schema ' +
      'WHERE sql NOT NULL AND type==''table'' AND name!=''sqlite_sequence''',
      [zSchema]);
    runSchemaDumpQuery(@x,
      'SELECT name, type, sql FROM "%w".sqlite_schema ' +
      'WHERE name==''sqlite_sequence''',
      [zSchema]);
    outputSqlFromQuery(@x,
      'SELECT sql FROM sqlite_schema ' +
      'WHERE sql NOT NULL AND type IN (''index'',''trigger'',''view'')',
      []);
  end else begin
    runSchemaDumpQuery(@x,
      'SELECT name, type, sql FROM "%w".sqlite_schema ' +
      'WHERE tbl_name=%Q COLLATE nocase AND type==''table''' +
      '  AND sql NOT NULL',
      [zSchema, zTable]);
    outputSqlFromQuery(@x,
      'SELECT sql FROM "%w".sqlite_schema ' +
      'WHERE sql NOT NULL' +
      '  AND type IN (''index'',''trigger'',''view'')' +
      '  AND tbl_name=%Q COLLATE nocase',
      [zSchema, zTable]);
  end;
  if x.writableSchema <> 0 then
    xCallback('PRAGMA writable_schema=OFF;'#10, pArg);
  if x.nErr <> 0 then
    xCallback('ROLLBACK; -- due to errors'#10, pArg)
  else
    xCallback('COMMIT;'#10, pArg);
  sqlite3_exec(db, 'COMMIT', nil, nil, nil);
  Result := x.rc;
end;

end.
