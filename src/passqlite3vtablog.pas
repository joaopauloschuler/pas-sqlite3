{
  SPDX-License-Identifier: blessing

  Faithful port of ../sqlite3/ext/misc/vtablog.c (720 lines in C).

  Diagnostic virtual table that traces every xConnect / xCreate /
  xDisconnect / xDestroy / xOpen / xClose / xFilter / xNext / xEof /
  xColumn / xRowid / xBestIndex / xUpdate / xBegin / xSync / xCommit /
  xRollback / xFindFunction / xRename / xSavepoint / xRelease /
  xRollbackTo / xShadowName / xIntegrity call to stdout.

  Usage:

      .load ./vtablog
      CREATE VIRTUAL TABLE temp.log USING vtablog(
         schema='CREATE TABLE x(a,b,c)',
         rows=25
      );

  CREATE VIRTUAL TABLE arguments are key=value pairs:

      schema=TEXT             CREATE TABLE statement defining the schema
      rows=N                  Row count (default 10)
      consume_order_by=N      Set orderByConsumed when ORDER BY matches

  Public entry: sqlite3VtablogRegister(db) — equivalent to
  sqlite3_vtablog_init() in C.
}
{$I passqlite3.inc}
unit passqlite3vtablog;

interface

uses
  SysUtils,
  passqlite3types,
  passqlite3util,
  passqlite3os,
  passqlite3printf,
  passqlite3vdbe,
  passqlite3vtab,
  passqlite3codegen,
  passqlite3main;

function sqlite3VtablogRegister(db: PTsqlite3): i32;

implementation

type
  PPSqlite3VtabCursor = ^PSqlite3VtabCursor;

  { vtablog.c:64..73 — vtablog_vtab. }
  PVtablogVtab = ^TVtablogVtab;
  TVtablogVtab = record
    base       : Tsqlite3_vtab;
    zDb        : PAnsiChar;
    zName      : PAnsiChar;
    nRow       : i32;
    nCursor    : i32;
    iConsumeOB : i32;
  end;

  { vtablog.c:79..84 — vtablog_cursor. }
  PVtablogCursor = ^TVtablogCursor;
  TVtablogCursor = record
    base    : Tsqlite3_vtab_cursor;
    iCursor : i32;
    iRowid  : i64;
  end;

var
  vtablogModule: Tsqlite3_module;

{ Thin printf — writes one preformatted line to stdout (no trailing
  newline; caller adds the line break, matching the C source which does
  the same). }
procedure vtPrint(const s: AnsiString); inline;
begin
  Write(Output, s);
end;

procedure vtPrintLn(const s: AnsiString); inline;
begin
  WriteLn(Output, s);
end;

{ vtablog.c:88..91 — vtablog_skip_whitespace. }
function vtSkipWhitespace(z: PAnsiChar): PAnsiChar;
begin
  while (z <> nil) and (z^ <> #0)
    and ((z^ = ' ') or (z^ = #9) or (z^ = #10) or (z^ = #11)
      or (z^ = #12) or (z^ = #13)) do
    Inc(z);
  Result := z;
end;

{ vtablog.c:94..98 — vtablog_trim_whitespace. }
procedure vtTrimWhitespace(z: PAnsiChar);
var
  n: SizeInt;
begin
  if z = nil then Exit;
  n := StrLen(z);
  while (n > 0) and ((z[n] = ' ') or (z[n] = #9) or (z[n] = #10)
    or (z[n] = #11) or (z[n] = #12) or (z[n] = #13)) do
    Dec(n);
  z[n] := #0;
end;

{ vtablog.c:101..114 — vtablog_dequote.  Removes matching outer quotes
  and squashes doubled-quote escapes. }
procedure vtDequote(z: PAnsiChar);
var
  cQuote: AnsiChar;
  i, j, n: SizeInt;
begin
  if z = nil then Exit;
  cQuote := z[0];
  if (cQuote <> '''') and (cQuote <> '"') then Exit;
  n := StrLen(z);
  if (n < 2) or (z[n - 1] <> cQuote) then Exit;
  i := 1; j := 0;
  while i < n - 1 do begin
    if (z[i] = cQuote) and (z[i + 1] = cQuote) then Inc(i);
    z[j] := z[i];
    Inc(j);
    Inc(i);
  end;
  z[j] := #0;
end;

{ vtablog.c:120..126 — vtablog_parameter.  If z starts with "TAG = ",
  returns a pointer just past the '='; otherwise nil. }
function vtParameter(zTag: PAnsiChar; nTag: i32; z: PAnsiChar): PAnsiChar;
begin
  z := vtSkipWhitespace(z);
  if StrLComp(zTag, z, nTag) <> 0 then begin Result := nil; Exit; end;
  z := vtSkipWhitespace(z + nTag);
  if z[0] <> '=' then begin Result := nil; Exit; end;
  Result := vtSkipWhitespace(z + 1);
end;

{ vtablog.c:132..153 — vtablog_string_parameter. }
function vtStringParameter(pzErr: PPAnsiChar; zParam: PAnsiChar;
  zArg: PAnsiChar; pzVal: PPAnsiChar): i32;
var
  zValue: PAnsiChar;
begin
  zValue := vtParameter(zParam, StrLen(zParam), zArg);
  if zValue = nil then begin Result := 0; Exit; end;
  if pzVal^ <> nil then begin
    pzErr^ := sqlite3MPrintf(nil, 'more than one ''%s'' parameter',
      [zParam]);
    Result := 1;
    Exit;
  end;
  pzVal^ := sqlite3MPrintf(nil, '%s', [zValue]);
  if pzVal^ = nil then begin
    pzErr^ := sqlite3MPrintf(nil, 'out of memory', []);
    Result := 1;
    Exit;
  end;
  vtTrimWhitespace(pzVal^);
  vtDequote(pzVal^);
  Result := 0;
end;

{ vtablog.c:191..262 — vtablogConnectCreate. }
function vtablogConnectCreate(db: PTsqlite3; pAux: Pointer;
  argc: i32; argv: PPAnsiChar; ppVtab: PPSqlite3Vtab;
  pzErr: PPAnsiChar; isCreate: i32): i32;
var
  pNew:       PVtablogVtab;
  i:          i32;
  rc:         i32;
  zSchema:    PAnsiChar;
  zNRow:      PAnsiChar;
  zConsumeOB: PAnsiChar;
  z:          PAnsiChar;
  pArgv:      ^PAnsiChar;
  zArgI:      PAnsiChar;
label
  endConnect;
begin
  pNew := nil;
  zSchema := nil;
  zNRow := nil;
  zConsumeOB := nil;
  rc := SQLITE_OK;
  pArgv := Pointer(argv);
  if isCreate <> 0 then z := 'xCreate' else z := 'xConnect';
  vtPrintLn(Format('%s.%s.%s():',
    [PAnsiChar(pArgv[1]), PAnsiChar(pArgv[2]), z]));
  vtPrintLn(Format('  argc=%d', [argc]));
  for i := 0 to argc - 1 do begin
    if pArgv[i] <> nil then
      vtPrintLn(Format('  argv[%d] = [%s]', [i, PAnsiChar(pArgv[i])]))
    else
      vtPrintLn(Format('  argv[%d] = NULL', [i]));
  end;

  for i := 3 to argc - 1 do begin
    zArgI := pArgv[i];
    if vtStringParameter(pzErr, 'schema', zArgI, @zSchema) <> 0 then begin
      rc := SQLITE_ERROR; goto endConnect;
    end;
    if vtStringParameter(pzErr, 'rows', zArgI, @zNRow) <> 0 then begin
      rc := SQLITE_ERROR; goto endConnect;
    end;
    if vtStringParameter(pzErr, 'consume_order_by', zArgI,
      @zConsumeOB) <> 0 then begin
      rc := SQLITE_ERROR; goto endConnect;
    end;
  end;
  if zSchema = nil then begin
    zSchema := sqlite3MPrintf(nil, '%s', ['CREATE TABLE x(a,b);']);
    if zSchema = nil then begin rc := SQLITE_NOMEM; goto endConnect; end;
  end;
  vtPrintLn(Format('  schema = ''%s''', [zSchema]));
  rc := sqlite3_declare_vtab(db, zSchema);
  if rc = SQLITE_OK then begin
    pNew := PVtablogVtab(sqlite3Malloc(SizeOf(TVtablogVtab)));
    ppVtab^ := PSqlite3Vtab(pNew);
    if pNew = nil then begin Result := SQLITE_NOMEM; Exit; end;
    FillChar(pNew^, SizeOf(TVtablogVtab), 0);
    pNew^.nRow := 10;
    if zNRow <> nil then pNew^.nRow := StrToIntDef(zNRow, 10);
    vtPrintLn(Format('  nrow = %d', [pNew^.nRow]));
    if zConsumeOB <> nil then
      pNew^.iConsumeOB := StrToIntDef(zConsumeOB, 0);
    if pNew^.iConsumeOB <> 0 then
      vtPrintLn(Format('  consume_order_by = %d', [pNew^.iConsumeOB]));
    pNew^.zDb   := sqlite3MPrintf(nil, '%s', [PAnsiChar(pArgv[1])]);
    pNew^.zName := sqlite3MPrintf(nil, '%s', [PAnsiChar(pArgv[2])]);
  end;

endConnect:
  sqlite3_free(zSchema);
  sqlite3_free(zNRow);
  sqlite3_free(zConsumeOB);
  Result := rc;
end;

{ vtablog.c:264..272 — vtablogCreate. }
function vtablogCreate(db: PTsqlite3; pAux: Pointer;
  argc: i32; argv: PPAnsiChar; ppVtab: PPSqlite3Vtab;
  pzErr: PPAnsiChar): i32; cdecl;
begin
  Result := vtablogConnectCreate(db, pAux, argc, argv, ppVtab, pzErr, 1);
end;

{ vtablog.c:273..281 — vtablogConnect. }
function vtablogConnect(db: PTsqlite3; pAux: Pointer;
  argc: i32; argv: PPAnsiChar; ppVtab: PPSqlite3Vtab;
  pzErr: PPAnsiChar): i32; cdecl;
begin
  Result := vtablogConnectCreate(db, pAux, argc, argv, ppVtab, pzErr, 0);
end;

{ vtablog.c:287..294 — vtablogDisconnect. }
function vtablogDisconnect(pVtab: PSqlite3Vtab): i32; cdecl;
var pTab: PVtablogVtab;
begin
  pTab := PVtablogVtab(pVtab);
  vtPrintLn(Format('%s.%s.xDisconnect()', [pTab^.zDb, pTab^.zName]));
  sqlite3_free(pTab^.zDb);
  sqlite3_free(pTab^.zName);
  sqlite3_free(pVtab);
  Result := SQLITE_OK;
end;

{ vtablog.c:299..306 — vtablogDestroy. }
function vtablogDestroy(pVtab: PSqlite3Vtab): i32; cdecl;
var pTab: PVtablogVtab;
begin
  pTab := PVtablogVtab(pVtab);
  vtPrintLn(Format('%s.%s.xDestroy()', [pTab^.zDb, pTab^.zName]));
  sqlite3_free(pTab^.zDb);
  sqlite3_free(pTab^.zName);
  sqlite3_free(pVtab);
  Result := SQLITE_OK;
end;

{ vtablog.c:311..322 — vtablogOpen. }
function vtablogOpen(p: PSqlite3Vtab;
  ppCursor: PPSqlite3VtabCursor): i32; cdecl;
var
  pTab: PVtablogVtab;
  pCur: PVtablogCursor;
begin
  pTab := PVtablogVtab(p);
  Inc(pTab^.nCursor);
  vtPrintLn(Format('%s.%s.xOpen(cursor=%d)',
    [pTab^.zDb, pTab^.zName, pTab^.nCursor]));
  pCur := PVtablogCursor(sqlite3Malloc(SizeOf(TVtablogCursor)));
  if pCur = nil then begin Result := SQLITE_NOMEM; Exit; end;
  FillChar(pCur^, SizeOf(TVtablogCursor), 0);
  pCur^.iCursor := pTab^.nCursor;
  ppCursor^ := PSqlite3VtabCursor(@pCur^.base);
  Result := SQLITE_OK;
end;

{ vtablog.c:327..333 — vtablogClose. }
function vtablogClose(cur: PSqlite3VtabCursor): i32; cdecl;
var
  pCur: PVtablogCursor;
  pTab: PVtablogVtab;
begin
  pCur := PVtablogCursor(cur);
  pTab := PVtablogVtab(cur^.pVtab);
  vtPrintLn(Format('%s.%s.xClose(cursor=%d)',
    [pTab^.zDb, pTab^.zName, pCur^.iCursor]));
  sqlite3_free(cur);
  Result := SQLITE_OK;
end;

{ vtablog.c:339..347 — vtablogNext. }
function vtablogNext(cur: PSqlite3VtabCursor): i32; cdecl;
var
  pCur: PVtablogCursor;
  pTab: PVtablogVtab;
begin
  pCur := PVtablogCursor(cur);
  pTab := PVtablogVtab(cur^.pVtab);
  vtPrintLn(Format('%s.%s.xNext(cursor=%d)  rowid %d -> %d',
    [pTab^.zDb, pTab^.zName, pCur^.iCursor,
     i32(pCur^.iRowid), i32(pCur^.iRowid + 1)]));
  Inc(pCur^.iRowid);
  Result := SQLITE_OK;
end;

{ vtablog.c:353..372 — vtablogColumn.  Synthetic value "ROWLETTER<rowid>"
  for column < 26, "{i}<rowid>" otherwise. }
function vtablogColumn(cur: PSqlite3VtabCursor;
  ctx: Psqlite3_context; i: i32): i32; cdecl;
const
  letters = 'abcdefghijklmnopqrstuvwyz';   { 25 letters - matches C source }
var
  pCur: PVtablogCursor;
  pTab: PVtablogVtab;
  zVal: AnsiString;
begin
  pCur := PVtablogCursor(cur);
  pTab := PVtablogVtab(cur^.pVtab);
  if i < 25 then
    zVal := Format('%s%d', [letters[i + 1], i32(pCur^.iRowid)])
  else if i < 26 then
    zVal := Format('%s%d', ['z', i32(pCur^.iRowid)])
  else
    zVal := Format('{%d}%d', [i, i32(pCur^.iRowid)]);
  vtPrintLn(Format('%s.%s.xColumn(cursor=%d, i=%d): [%s]',
    [pTab^.zDb, pTab^.zName, pCur^.iCursor, i, zVal]));
  sqlite3_result_text(ctx, PAnsiChar(zVal), -1, SQLITE_TRANSIENT);
  Result := SQLITE_OK;
end;

{ vtablog.c:378..385 — vtablogRowid. }
function vtablogRowid(cur: PSqlite3VtabCursor; pRowid: Pi64): i32; cdecl;
var
  pCur: PVtablogCursor;
  pTab: PVtablogVtab;
begin
  pCur := PVtablogCursor(cur);
  pTab := PVtablogVtab(cur^.pVtab);
  vtPrintLn(Format('%s.%s.xRowid(cursor=%d): %d',
    [pTab^.zDb, pTab^.zName, pCur^.iCursor, i32(pCur^.iRowid)]));
  pRowid^ := pCur^.iRowid;
  Result := SQLITE_OK;
end;

{ vtablog.c:391..398 — vtablogEof. }
function vtablogEof(cur: PSqlite3VtabCursor): i32; cdecl;
var
  pCur: PVtablogCursor;
  pTab: PVtablogVtab;
  rc:   i32;
begin
  pCur := PVtablogCursor(cur);
  pTab := PVtablogVtab(cur^.pVtab);
  if pCur^.iRowid >= pTab^.nRow then rc := 1 else rc := 0;
  vtPrintLn(Format('%s.%s.xEof(cursor=%d): %d',
    [pTab^.zDb, pTab^.zName, pCur^.iCursor, rc]));
  Result := rc;
end;

{ vtablog.c:403..459 — vtablogQuote.  Renders a value as an SQL literal
  to stdout (used by xBestIndex / xUpdate trace lines). }
procedure vtablogQuote(p: Psqlite3_value);
var
  i, n: i32;
  zb:   PByte;
  hexBuf: AnsiString;
  zText: PAnsiChar;
begin
  case sqlite3_value_type(p) of
    SQLITE_NULL: vtPrint('NULL');
    SQLITE_INTEGER: vtPrint(IntToStr(sqlite3_value_int64(p)));
    SQLITE_FLOAT: vtPrint(FloatToStr(sqlite3_value_double(p)));
    SQLITE_BLOB:
      begin
        n := sqlite3_value_bytes(p);
        zb := PByte(sqlite3_value_blob(p));
        hexBuf := 'x''';
        for i := 0 to n - 1 do begin
          hexBuf := hexBuf + LowerCase(IntToHex(zb[i], 2));
        end;
        hexBuf := hexBuf + '''';
        vtPrint(hexBuf);
      end;
    SQLITE_TEXT:
      begin
        zText := sqlite3_value_text(p);
        if zText = nil then begin vtPrint(''''''); Exit; end;
        vtPrint('''');
        i := 0;
        while zText[i] <> #0 do begin
          if zText[i] = '''' then vtPrint('''''')
          else vtPrint(zText[i]);
          Inc(i);
        end;
        vtPrint('''');
      end;
  end;
end;

{ vtablog.c:484..511 — vtablogOpName. }
function vtablogOpName(op: Byte): AnsiString;
begin
  case op of
    SQLITE_INDEX_CONSTRAINT_EQ:        Result := 'EQ';
    SQLITE_INDEX_CONSTRAINT_GT:        Result := 'GT';
    SQLITE_INDEX_CONSTRAINT_LE:        Result := 'LE';
    SQLITE_INDEX_CONSTRAINT_LT:        Result := 'LT';
    SQLITE_INDEX_CONSTRAINT_GE:        Result := 'GE';
    SQLITE_INDEX_CONSTRAINT_MATCH:     Result := 'MATCH';
    SQLITE_INDEX_CONSTRAINT_LIKE:      Result := 'LIKE';
    SQLITE_INDEX_CONSTRAINT_GLOB:      Result := 'GLOB';
    SQLITE_INDEX_CONSTRAINT_REGEXP:    Result := 'REGEXP';
    SQLITE_INDEX_CONSTRAINT_NE:        Result := 'NE';
    SQLITE_INDEX_CONSTRAINT_ISNOT:     Result := 'ISNOT';
    SQLITE_INDEX_CONSTRAINT_ISNOTNULL: Result := 'ISNOTNULL';
    SQLITE_INDEX_CONSTRAINT_ISNULL:    Result := 'ISNULL';
    SQLITE_INDEX_CONSTRAINT_IS:        Result := 'IS';
    SQLITE_INDEX_CONSTRAINT_LIMIT:     Result := 'LIMIT';
    SQLITE_INDEX_CONSTRAINT_OFFSET:    Result := 'OFFSET';
    SQLITE_INDEX_CONSTRAINT_FUNCTION:  Result := 'FUNCTION';
  else
    Result := IntToStr(op);
  end;
end;

{ vtablog.c:468..478 — vtablogFilter. }
function vtablogFilter(cur: PSqlite3VtabCursor;
  idxNum: i32; idxStr: PAnsiChar;
  argc: i32; argv: PPsqlite3_value): i32; cdecl;
var
  pCur: PVtablogCursor;
  pTab: PVtablogVtab;
begin
  pCur := PVtablogCursor(cur);
  pTab := PVtablogVtab(cur^.pVtab);
  vtPrintLn(Format('%s.%s.xFilter(cursor=%d):',
    [pTab^.zDb, pTab^.zName, pCur^.iCursor]));
  pCur^.iRowid := 0;
  Result := SQLITE_OK;
end;

{ vtablog.c:519..573 — vtablogBestIndex. }
function vtablogBestIndex(tab: PSqlite3Vtab;
  p: PSqlite3IndexInfo): i32; cdecl;
var
  pTab: PVtablogVtab;
  i:    i32;
  pVal: Psqlite3_value;
  rc:   i32;
  pC:   PSqlite3IndexConstraint;
  pOB:  PSqlite3IndexOrderBy;
  zColl: PAnsiChar;
  N:    i32;
begin
  pTab := PVtablogVtab(tab);
  vtPrintLn(Format('%s.%s.xBestIndex():', [pTab^.zDb, pTab^.zName]));
  vtPrintLn(Format('  colUsed: 0x%.16x', [p^.colUsed]));
  vtPrintLn(Format('  nConstraint: %d', [p^.nConstraint]));
  pC := p^.aConstraint;
  for i := 0 to p^.nConstraint - 1 do begin
    pVal := nil;
    rc := sqlite3_vtab_rhs_value(p, i, @pVal);
    zColl := sqlite3_vtab_collation(p, i);
    if zColl = nil then zColl := '';
    vtPrint(Format(
      '  constraint[%d]: col=%d termid=%d op=%s usabled=%d coll=%s rhs=',
      [i, pC^.iColumn, pC^.iTermOffset, vtablogOpName(pC^.op),
       pC^.usable, zColl]));
    if rc = SQLITE_OK then begin
      vtablogQuote(pVal);
      vtPrintLn('');
    end else
      vtPrintLn('N/A');
    Inc(pC);
  end;
  vtPrintLn(Format('  nOrderBy: %d', [p^.nOrderBy]));
  if p^.nOrderBy > 0 then begin
    pOB := p^.aOrderBy;
    for i := 0 to p^.nOrderBy - 1 do begin
      vtPrintLn(Format('  orderby[%d]: col=%d desc=%d',
        [i, pOB^.iColumn, pOB^.desc]));
      Inc(pOB);
    end;
    pOB := p^.aOrderBy;
    if pTab^.iConsumeOB <> 0 then begin
      N := pOB^.iColumn + 1;
      if ((pOB^.desc <> 0) and (N = -pTab^.iConsumeOB))
        or ((pOB^.desc = 0) and (N = pTab^.iConsumeOB)) then
        p^.orderByConsumed := 1;
    end;
  end;
  p^.estimatedCost := 500.0;
  p^.estimatedRows := 500;
  vtPrintLn(Format('  idxNum=%d', [p^.idxNum]));
  vtPrintLn('  idxStr=NULL');
  vtPrintLn(Format('  sqlite3_vtab_distinct()=%d',
    [sqlite3_vtab_distinct(p)]));
  vtPrintLn(Format('  orderByConsumed=%d', [p^.orderByConsumed]));
  vtPrintLn(Format('  estimatedCost=%g', [p^.estimatedCost]));
  vtPrintLn(Format('  estimatedRows=%d', [p^.estimatedRows]));
  Result := SQLITE_OK;
end;

{ vtablog.c:582..598 — vtablogUpdate. }
function vtablogUpdate(tab: PSqlite3Vtab; argc: i32;
  argv: PPsqlite3_value; pRowid: Pi64): i32; cdecl;
var
  pTab: PVtablogVtab;
  i:    i32;
begin
  pTab := PVtablogVtab(tab);
  vtPrintLn(Format('%s.%s.xUpdate():', [pTab^.zDb, pTab^.zName]));
  vtPrintLn(Format('  argc=%d', [argc]));
  for i := 0 to argc - 1 do begin
    vtPrint(Format('  argv[%d]=', [i]));
    vtablogQuote(argv[i]);
    vtPrintLn('');
  end;
  Result := SQLITE_OK;
end;

{ vtablog.c:600..634 — savepoint / commit / rollback / sync trace. }
function vtablogBegin(tab: PSqlite3Vtab): i32; cdecl;
var pTab: PVtablogVtab;
begin
  pTab := PVtablogVtab(tab);
  vtPrintLn(Format('%s.%s.xBegin()', [pTab^.zDb, pTab^.zName]));
  Result := SQLITE_OK;
end;

function vtablogSync(tab: PSqlite3Vtab): i32; cdecl;
var pTab: PVtablogVtab;
begin
  pTab := PVtablogVtab(tab);
  vtPrintLn(Format('%s.%s.xSync()', [pTab^.zDb, pTab^.zName]));
  Result := SQLITE_OK;
end;

function vtablogCommit(tab: PSqlite3Vtab): i32; cdecl;
var pTab: PVtablogVtab;
begin
  pTab := PVtablogVtab(tab);
  vtPrintLn(Format('%s.%s.xCommit()', [pTab^.zDb, pTab^.zName]));
  Result := SQLITE_OK;
end;

function vtablogRollback(tab: PSqlite3Vtab): i32; cdecl;
var pTab: PVtablogVtab;
begin
  pTab := PVtablogVtab(tab);
  vtPrintLn(Format('%s.%s.xRollback()', [pTab^.zDb, pTab^.zName]));
  Result := SQLITE_OK;
end;

function vtablogSavepoint(tab: PSqlite3Vtab; N: i32): i32; cdecl;
var pTab: PVtablogVtab;
begin
  pTab := PVtablogVtab(tab);
  vtPrintLn(Format('%s.%s.xSavepoint(%d)', [pTab^.zDb, pTab^.zName, N]));
  Result := SQLITE_OK;
end;

function vtablogRelease(tab: PSqlite3Vtab; N: i32): i32; cdecl;
var pTab: PVtablogVtab;
begin
  pTab := PVtablogVtab(tab);
  vtPrintLn(Format('%s.%s.xRelease(%d)', [pTab^.zDb, pTab^.zName, N]));
  Result := SQLITE_OK;
end;

function vtablogRollbackTo(tab: PSqlite3Vtab; N: i32): i32; cdecl;
var pTab: PVtablogVtab;
begin
  pTab := PVtablogVtab(tab);
  vtPrintLn(Format('%s.%s.xRollbackTo(%d)', [pTab^.zDb, pTab^.zName, N]));
  Result := SQLITE_OK;
end;

{ vtablog.c:636..647 — vtablogFindMethod. }
function vtablogFindMethod(tab: PSqlite3Vtab; nArg: i32;
  zName: PAnsiChar; pxFunc: PPointer; ppArg: PPointer): i32; cdecl;
var pTab: PVtablogVtab;
begin
  pTab := PVtablogVtab(tab);
  vtPrintLn(Format('%s.%s.xFindMethod(nArg=%d, zName=%s)',
    [pTab^.zDb, pTab^.zName, nArg, zName]));
  Result := SQLITE_OK;
end;

{ vtablog.c:648..654 — vtablogRename. }
function vtablogRename(tab: PSqlite3Vtab; zNew: PAnsiChar): i32; cdecl;
var pTab: PVtablogVtab;
begin
  pTab := PVtablogVtab(tab);
  vtPrintLn(Format('%s.%s.xRename(''%s'')',
    [pTab^.zDb, pTab^.zName, zNew]));
  sqlite3_free(pTab^.zName);
  pTab^.zName := sqlite3MPrintf(nil, '%s', [zNew]);
  Result := SQLITE_OK;
end;

{ vtablog.c:659..662 — vtablogShadowName.  Anything matching "*shadow*"
  is treated as a shadow table. }
function vtablogShadowName(zName: PAnsiChar): i32; cdecl;
begin
  vtPrintLn(Format('vtablog.xShadowName(''%s'')', [zName]));
  if sqlite3_strglob('*shadow*', zName) = 0 then
    Result := 1
  else
    Result := 0;
end;

{ vtablog.c:664..674 — vtablogIntegrity. }
function vtablogIntegrity(tab: PSqlite3Vtab; zSchema, zTabName: PAnsiChar;
  mFlags: i32; pzErr: PPAnsiChar): i32; cdecl;
var pTab: PVtablogVtab;
begin
  pTab := PVtablogVtab(tab);
  vtPrintLn(Format('%s.%s.xIntegrity(mFlags=0x%x)',
    [pTab^.zDb, pTab^.zName, mFlags]));
  Result := 0;
end;

function sqlite3VtablogRegister(db: PTsqlite3): i32;
begin
  Result := sqlite3_create_module(db, 'vtablog', @vtablogModule, nil);
end;

initialization
  FillChar(vtablogModule, SizeOf(vtablogModule), 0);
  vtablogModule.iVersion    := 4;
  vtablogModule.xCreate     := @vtablogCreate;
  vtablogModule.xConnect    := @vtablogConnect;
  vtablogModule.xBestIndex  := @vtablogBestIndex;
  vtablogModule.xDisconnect := @vtablogDisconnect;
  vtablogModule.xDestroy    := @vtablogDestroy;
  vtablogModule.xOpen       := @vtablogOpen;
  vtablogModule.xClose      := @vtablogClose;
  vtablogModule.xFilter     := @vtablogFilter;
  vtablogModule.xNext       := @vtablogNext;
  vtablogModule.xEof        := @vtablogEof;
  vtablogModule.xColumn     := @vtablogColumn;
  vtablogModule.xRowid      := @vtablogRowid;
  vtablogModule.xUpdate     := @vtablogUpdate;
  vtablogModule.xBegin      := @vtablogBegin;
  vtablogModule.xSync       := @vtablogSync;
  vtablogModule.xCommit     := @vtablogCommit;
  vtablogModule.xRollback   := @vtablogRollback;
  vtablogModule.xFindFunction := @vtablogFindMethod;
  vtablogModule.xRename     := @vtablogRename;
  vtablogModule.xSavepoint  := @vtablogSavepoint;
  vtablogModule.xRelease    := @vtablogRelease;
  vtablogModule.xRollbackTo := @vtablogRollbackTo;
  vtablogModule.xShadowName := @vtablogShadowName;
  vtablogModule.xIntegrity  := @vtablogIntegrity;
end.
