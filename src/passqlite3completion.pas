{
  SPDX-License-Identifier: blessing

  Faithful port of ../sqlite3/ext/misc/completion.c (522 lines in C).

  Eponymous-only virtual table that returns suggested completions for a
  partial SQL input.  Schema:

      CREATE TABLE x(
         candidate TEXT,
         prefix    TEXT HIDDEN,
         wholeline TEXT HIDDEN,
         phase     INT  HIDDEN
      );

  Suggested usage:

      SELECT DISTINCT candidate COLLATE nocase
        FROM completion($prefix, $wholeline)
       ORDER BY 1;

  Public entry: sqlite3CompletionVtabInit(db) — equivalent to
  sqlite3_completion_init() in C.
}
{$I passqlite3.inc}
unit passqlite3completion;

interface

uses
  passqlite3types,
  passqlite3util,
  passqlite3os,
  passqlite3printf,
  passqlite3vdbe,
  passqlite3vtab,
  passqlite3parser,
  passqlite3main;

function sqlite3CompletionVtabInit(db: PTsqlite3): i32;

implementation

const
  { completion.c:79..90 — phase enum.  COMPLETION_TABLES also includes
    views and triggers; COMPLETION_COLUMNS uses pragma_table_xinfo
    against every table in every attached database. }
  COMPLETION_FIRST_PHASE = 1;
  COMPLETION_KEYWORDS    = 1;
  COMPLETION_DATABASES   = 7;
  COMPLETION_TABLES      = 8;
  COMPLETION_COLUMNS     = 9;
  COMPLETION_EOF         = 11;

  { completion.c:121..124 — column ordinals.  Visible column 0; hidden
    columns 1..3.  PHASE is for debugging only. }
  COMPLETION_COLUMN_CANDIDATE = 0;
  COMPLETION_COLUMN_PREFIX    = 1;
  COMPLETION_COLUMN_WHOLELINE = 2;
  COMPLETION_COLUMN_PHASE     = 3;

type
  PPSqlite3VtabCursor = ^PSqlite3VtabCursor;

  { completion.c:52..56 — completion_vtab.  First field MUST be
    Tsqlite3_vtab. }
  PCompletionVtab = ^TCompletionVtab;
  TCompletionVtab = record
    base : Tsqlite3_vtab;
    db   : PTsqlite3;
  end;

  { completion.c:62..75 — completion_cursor. }
  PCompletionCursor = ^TCompletionCursor;
  TCompletionCursor = record
    base        : Tsqlite3_vtab_cursor;
    db          : PTsqlite3;
    nPrefix     : i32;
    nLine       : i32;
    zPrefix     : PAnsiChar;
    zLine       : PAnsiChar;
    zCurrentRow : PAnsiChar;
    szRow       : i32;
    pStmt       : PVdbe;
    iRowid      : i64;
    ePhase      : i32;
    j           : i32;
  end;

var
  completionModule: Tsqlite3_module;

{ Local IsAlnum — completion.c:45 macro.  ASCII-only check; matches C
  isalnum((unsigned char)X) on the typical 7-bit-ASCII path. }
function isAlnumChar(c: AnsiChar): Boolean; inline;
begin
  Result := ((c >= 'A') and (c <= 'Z'))
         or ((c >= 'a') and (c <= 'z'))
         or ((c >= '0') and (c <= '9'));
end;

{ completion.c:105..142 — completionConnect.  Declares the result
  schema, marks the module SQLITE_VTAB_INNOCUOUS, allocates the
  completion_vtab with db captured. }
function completionConnect(db: PTsqlite3; pAux: Pointer;
  argc: i32; argv: PPAnsiChar; ppVtab: PPSqlite3Vtab;
  pzErr: PPAnsiChar): i32; cdecl;
var
  pNew: PCompletionVtab;
  rc:   i32;
begin
  sqlite3_vtab_config(db, SQLITE_VTAB_INNOCUOUS, 0);
  rc := sqlite3_declare_vtab(db,
    'CREATE TABLE x('
    + '  candidate TEXT,'
    + '  prefix TEXT HIDDEN,'
    + '  wholeline TEXT HIDDEN,'
    + '  phase INT HIDDEN'
    + ')');
  if rc = SQLITE_OK then begin
    pNew := PCompletionVtab(sqlite3Malloc(SizeOf(TCompletionVtab)));
    ppVtab^ := PSqlite3Vtab(pNew);
    if pNew = nil then begin Result := SQLITE_NOMEM; Exit; end;
    FillChar(pNew^, SizeOf(TCompletionVtab), 0);
    pNew^.db := db;
  end;
  Result := rc;
end;

{ completion.c:147..150 — completionDisconnect. }
function completionDisconnect(p: PSqlite3Vtab): i32; cdecl;
begin
  sqlite3_free(p);
  Result := SQLITE_OK;
end;

{ completion.c:155..163 — completionOpen. }
function completionOpen(p: PSqlite3Vtab;
  ppCursor: PPSqlite3VtabCursor): i32; cdecl;
var
  pCur: PCompletionCursor;
begin
  pCur := PCompletionCursor(sqlite3Malloc(SizeOf(TCompletionCursor)));
  if pCur = nil then begin Result := SQLITE_NOMEM; Exit; end;
  FillChar(pCur^, SizeOf(TCompletionCursor), 0);
  pCur^.db := PCompletionVtab(p)^.db;
  ppCursor^ := PSqlite3VtabCursor(@pCur^.base);
  Result := SQLITE_OK;
end;

{ completion.c:168..173 — completionCursorReset.  Free zPrefix/zLine,
  finalize pStmt, clear j; ePhase / iRowid are left to xFilter. }
procedure completionCursorReset(pCur: PCompletionCursor);
begin
  sqlite3_free(pCur^.zPrefix); pCur^.zPrefix := nil; pCur^.nPrefix := 0;
  sqlite3_free(pCur^.zLine);   pCur^.zLine := nil;   pCur^.nLine := 0;
  if pCur^.pStmt <> nil then begin
    sqlite3_finalize(pCur^.pStmt);
    pCur^.pStmt := nil;
  end;
  pCur^.j := 0;
end;

{ completion.c:178..182 — completionClose. }
function completionClose(cur: PSqlite3VtabCursor): i32; cdecl;
begin
  completionCursorReset(PCompletionCursor(cur));
  sqlite3_free(cur);
  Result := SQLITE_OK;
end;

{ completion.c:198..312 — completionNext.  State-machine over phases:
    KEYWORDS -> DATABASES -> TABLES -> COLUMNS -> EOF.
  KEYWORDS uses sqlite3_keyword_count / _name; DATABASES walks
  PRAGMA database_list; TABLES UNIONs sqlite_schema across every
  attached database; COLUMNS UNIONs pragma_table_xinfo joined with
  sqlite_schema across every attached database.  Filter rows whose
  prefix matches sqlite3_strnicmp(zPrefix, zCurrentRow, nPrefix). }
function completionNext(cur: PSqlite3VtabCursor): i32; cdecl;
var
  pCur:       PCompletionCursor;
  eNextPhase: i32;
  iCol:       i32;
  rc:         i32;
  pS2:        PVdbe;
  pStr:       PSqlite3Str;
  zSql:       PAnsiChar;
  zSep:       PAnsiChar;
  zDb:        PAnsiChar;
  pzKwName:   PAnsiChar;
  nKwName:    i32;
  matched:    Boolean;
begin
  pCur := PCompletionCursor(cur);
  Inc(pCur^.iRowid);
  while pCur^.ePhase <> COMPLETION_EOF do begin
    eNextPhase := 0;
    iCol := -1;
    case pCur^.ePhase of
      COMPLETION_KEYWORDS:
        begin
          if pCur^.j >= sqlite3_keyword_count then begin
            pCur^.zCurrentRow := nil;
            pCur^.ePhase := COMPLETION_DATABASES;
          end else begin
            sqlite3_keyword_name(pCur^.j, pzKwName, nKwName);
            pCur^.zCurrentRow := pzKwName;
            pCur^.szRow := nKwName;
            Inc(pCur^.j);
          end;
          iCol := -1;
        end;

      COMPLETION_DATABASES:
        begin
          if pCur^.pStmt = nil then begin
            sqlite3_prepare_v2(pCur^.db, 'PRAGMA database_list', -1,
                               PPointer(@pCur^.pStmt), nil);
          end;
          iCol := 1;
          eNextPhase := COMPLETION_TABLES;
        end;

      COMPLETION_TABLES:
        begin
          if pCur^.pStmt = nil then begin
            pS2 := nil;
            pStr := sqlite3_str_new(pCur^.db);
            zSep := '';
            sqlite3_prepare_v2(pCur^.db, 'PRAGMA database_list', -1,
                               PPointer(@pS2), nil);
            while sqlite3_step(pS2) = SQLITE_ROW do begin
              zDb := sqlite3_column_text(pS2, 1);
              sqlite3_str_appendf(pStr,
                '%sSELECT name FROM "%w".sqlite_schema',
                [zSep, zDb]);
              zSep := ' UNION ';
            end;
            rc := sqlite3_finalize(pS2);
            zSql := sqlite3_str_finish(pStr);
            if zSql = nil then begin Result := SQLITE_NOMEM; Exit; end;
            if rc = SQLITE_OK then begin
              sqlite3_prepare_v2(pCur^.db, zSql, -1,
                                 PPointer(@pCur^.pStmt), nil);
            end;
            sqlite3_free(zSql);
            if rc <> SQLITE_OK then begin Result := rc; Exit; end;
          end;
          iCol := 0;
          eNextPhase := COMPLETION_COLUMNS;
        end;

      COMPLETION_COLUMNS:
        begin
          if pCur^.pStmt = nil then begin
            pS2 := nil;
            pStr := sqlite3_str_new(pCur^.db);
            zSep := '';
            sqlite3_prepare_v2(pCur^.db, 'PRAGMA database_list', -1,
                               PPointer(@pS2), nil);
            while sqlite3_step(pS2) = SQLITE_ROW do begin
              zDb := sqlite3_column_text(pS2, 1);
              sqlite3_str_appendf(pStr,
                '%sSELECT pti.name FROM "%w".sqlite_schema AS sm'
                + ' JOIN pragma_table_xinfo(sm.name,%Q) AS pti'
                + ' WHERE sm.type=''table''',
                [zSep, zDb, zDb]);
              zSep := ' UNION ';
            end;
            rc := sqlite3_finalize(pS2);
            zSql := sqlite3_str_finish(pStr);
            if zSql = nil then begin Result := SQLITE_NOMEM; Exit; end;
            if rc = SQLITE_OK then begin
              sqlite3_prepare_v2(pCur^.db, zSql, -1,
                                 PPointer(@pCur^.pStmt), nil);
            end;
            sqlite3_free(zSql);
            if rc <> SQLITE_OK then begin Result := rc; Exit; end;
          end;
          iCol := 0;
          eNextPhase := COMPLETION_EOF;
        end;
    else
      iCol := -1;
    end;

    if iCol < 0 then begin
      { Phase pre-set zCurrentRow (KEYWORDS path).  If the row was
        cleared (end of phase), continue to the next iteration. }
      if pCur^.zCurrentRow = nil then Continue;
    end else begin
      if sqlite3_step(pCur^.pStmt) = SQLITE_ROW then begin
        pCur^.zCurrentRow := sqlite3_column_text(pCur^.pStmt, iCol);
        pCur^.szRow := sqlite3_column_bytes(pCur^.pStmt, iCol);
      end else begin
        rc := sqlite3_finalize(pCur^.pStmt);
        pCur^.pStmt := nil;
        pCur^.ePhase := eNextPhase;
        if rc <> SQLITE_OK then begin Result := rc; Exit; end;
        Continue;
      end;
    end;

    { Apply the prefix filter — empty prefix passes every row. }
    if pCur^.nPrefix = 0 then Break;
    matched := (pCur^.nPrefix <= pCur^.szRow)
           and (sqlite3_strnicmp(pCur^.zPrefix, pCur^.zCurrentRow,
                                 pCur^.nPrefix) = 0);
    if matched then Break;
  end;

  Result := SQLITE_OK;
end;

{ completion.c:318..343 — completionColumn. }
function completionColumn(cur: PSqlite3VtabCursor;
  ctx: Psqlite3_context; i: i32): i32; cdecl;
var
  pCur: PCompletionCursor;
begin
  pCur := PCompletionCursor(cur);
  case i of
    COMPLETION_COLUMN_CANDIDATE:
      sqlite3_result_text(ctx, pCur^.zCurrentRow, pCur^.szRow,
                          SQLITE_TRANSIENT);
    COMPLETION_COLUMN_PREFIX:
      sqlite3_result_text(ctx, pCur^.zPrefix, -1, SQLITE_TRANSIENT);
    COMPLETION_COLUMN_WHOLELINE:
      sqlite3_result_text(ctx, pCur^.zLine, -1, SQLITE_TRANSIENT);
    COMPLETION_COLUMN_PHASE:
      sqlite3_result_int(ctx, pCur^.ePhase);
  end;
  Result := SQLITE_OK;
end;

{ completion.c:349..353 — completionRowid.  Same as the iRowid counter. }
function completionRowid(cur: PSqlite3VtabCursor; pRowid: Pi64): i32; cdecl;
begin
  pRowid^ := PCompletionCursor(cur)^.iRowid;
  Result := SQLITE_OK;
end;

{ completion.c:359..362 — completionEof.  EOF when ePhase has advanced
  past the last phase. }
function completionEof(cur: PSqlite3VtabCursor): i32; cdecl;
begin
  if PCompletionCursor(cur)^.ePhase >= COMPLETION_EOF then
    Result := 1
  else
    Result := 0;
end;

{ completion.c:370..412 — completionFilter.  Bind prefix from argv[0]
  if idxNum&1; bind wholeline from argv[1] if idxNum&2.  When wholeline
  is set but prefix is not, derive the prefix from the trailing
  identifier characters of the line. }
function completionFilter(cur: PSqlite3VtabCursor;
  idxNum: i32; idxStr: PAnsiChar;
  argc: i32; argv: PPsqlite3_value): i32; cdecl;
var
  pCur:  PCompletionCursor;
  iArg:  i32;
  pArgv: ^Psqlite3_value;
  pVal:  Psqlite3_value;
  zText: PAnsiChar;
  i, n:  i32;
begin
  pCur := PCompletionCursor(cur);
  iArg := 0;
  completionCursorReset(pCur);
  pArgv := Pointer(argv);
  if (idxNum and 1) <> 0 then begin
    pVal := pArgv^;
    pCur^.nPrefix := sqlite3_value_bytes(pVal);
    if pCur^.nPrefix > 0 then begin
      zText := sqlite3_value_text(pVal);
      pCur^.zPrefix := sqlite3StrDup(PChar(zText));
      if pCur^.zPrefix = nil then begin Result := SQLITE_NOMEM; Exit; end;
      n := 0;
      while pCur^.zPrefix[n] <> #0 do Inc(n);
      pCur^.nPrefix := n;
    end;
    iArg := 1;
    Inc(pArgv);
  end;
  if (idxNum and 2) <> 0 then begin
    pVal := pArgv^;
    pCur^.nLine := sqlite3_value_bytes(pVal);
    if pCur^.nLine > 0 then begin
      zText := sqlite3_value_text(pVal);
      pCur^.zLine := sqlite3StrDup(PChar(zText));
      if pCur^.zLine = nil then begin Result := SQLITE_NOMEM; Exit; end;
      n := 0;
      while pCur^.zLine[n] <> #0 do Inc(n);
      pCur^.nLine := n;
    end;
  end;
  if (pCur^.zLine <> nil) and (pCur^.zPrefix = nil) then begin
    i := pCur^.nLine;
    while (i > 0)
      and (isAlnumChar(pCur^.zLine[i - 1]) or (pCur^.zLine[i - 1] = '_')) do
      Dec(i);
    pCur^.nPrefix := pCur^.nLine - i;
    if pCur^.nPrefix > 0 then begin
      pCur^.zPrefix := PAnsiChar(sqlite3Malloc(u64(pCur^.nPrefix + 1)));
      if pCur^.zPrefix = nil then begin Result := SQLITE_NOMEM; Exit; end;
      Move((pCur^.zLine + i)^, pCur^.zPrefix^, pCur^.nPrefix);
      pCur^.zPrefix[pCur^.nPrefix] := #0;
    end;
  end;
  pCur^.iRowid := 0;
  pCur^.ePhase := COMPLETION_FIRST_PHASE;
  Result := completionNext(cur);
end;

{ completion.c:424..463 — completionBestIndex.  Bit 0 of idxNum signals
  prefix=, bit 1 signals wholeline=.  Argv ordering matches the order
  the constraints were assigned. }
function completionBestIndex(tab: PSqlite3Vtab;
  pIdxInfo: PSqlite3IndexInfo): i32; cdecl;
var
  i:            i32;
  idxNum:       i32;
  prefixIdx:    i32;
  wholelineIdx: i32;
  nArg:         i32;
  pConstraint:  PSqlite3IndexConstraint;
begin
  idxNum := 0;
  prefixIdx := -1;
  wholelineIdx := -1;
  nArg := 0;
  pConstraint := pIdxInfo^.aConstraint;
  for i := 0 to pIdxInfo^.nConstraint - 1 do begin
    if (pConstraint^.usable <> 0)
      and (pConstraint^.op = SQLITE_INDEX_CONSTRAINT_EQ) then begin
      case pConstraint^.iColumn of
        COMPLETION_COLUMN_PREFIX:
          begin
            prefixIdx := i;
            idxNum := idxNum or 1;
          end;
        COMPLETION_COLUMN_WHOLELINE:
          begin
            wholelineIdx := i;
            idxNum := idxNum or 2;
          end;
      end;
    end;
    Inc(pConstraint);
  end;
  if prefixIdx >= 0 then begin
    Inc(nArg);
    pIdxInfo^.aConstraintUsage[prefixIdx].argvIndex := nArg;
    pIdxInfo^.aConstraintUsage[prefixIdx].omit := 1;
  end;
  if wholelineIdx >= 0 then begin
    Inc(nArg);
    pIdxInfo^.aConstraintUsage[wholelineIdx].argvIndex := nArg;
    pIdxInfo^.aConstraintUsage[wholelineIdx].omit := 1;
  end;
  pIdxInfo^.idxNum := idxNum;
  pIdxInfo^.estimatedCost := Double(5000) - 1000.0 * nArg;
  pIdxInfo^.estimatedRows := 500 - 100 * nArg;
  Result := SQLITE_OK;
end;

function sqlite3CompletionVtabInit(db: PTsqlite3): i32;
begin
  Result := sqlite3_create_module(db, 'completion',
    @completionModule, nil);
end;

initialization
  FillChar(completionModule, SizeOf(completionModule), 0);
  completionModule.iVersion    := 0;
  { xCreate intentionally nil — eponymous-only. }
  completionModule.xConnect    := @completionConnect;
  completionModule.xBestIndex  := @completionBestIndex;
  completionModule.xDisconnect := @completionDisconnect;
  completionModule.xOpen       := @completionOpen;
  completionModule.xClose      := @completionClose;
  completionModule.xFilter     := @completionFilter;
  completionModule.xNext       := @completionNext;
  completionModule.xEof        := @completionEof;
  completionModule.xColumn     := @completionColumn;
  completionModule.xRowid      := @completionRowid;
end.
