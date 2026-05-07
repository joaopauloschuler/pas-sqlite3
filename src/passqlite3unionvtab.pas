{
  SPDX-License-Identifier: blessing

  Faithful port of ../sqlite3/ext/misc/unionvtab.c (1383 lines in C).

  Provides two related virtual tables:

      CREATE VIRTUAL TABLE t USING unionvtab(<sql-statement>);
      CREATE VIRTUAL TABLE t USING swarmvtab(<sql-statement> [, <opt>...]);

  The <sql-statement> must yield one row per source table with columns
  (zDb, zTab, iMin, iMax) — and optionally a 5th "context" column for
  swarmvtab.  unionvtab reads source tables out of attached databases on
  the main connection; swarmvtab opens one db file per source on demand
  and recycles handles via a closable LRU bounded by maxopen=N.

  Public entry: sqlite3UnionvtabInit(db) — equivalent to
  sqlite3_unionvtab_init() in the C reference.

  Same caveat as the prior eponymous-vtab series (10.1.69 / 10.1.71 /
  10.1.83): the Pascal port's WhereBegin does not yet wire vtab
  xBestIndex constraint pushdown (codegen.pas:13938 / 28163), so a
  bare `SELECT … FROM ut WHERE rowid=?` falls through unfiltered;
  the module is faithful end-to-end and constraints flow once that
  lands.
}
{$I passqlite3.inc}
unit passqlite3unionvtab;

interface

uses
  SysUtils,
  passqlite3types,
  passqlite3util,
  passqlite3printf,
  passqlite3os,
  passqlite3vdbe,
  passqlite3vtab,
  passqlite3main;

function sqlite3UnionvtabInit(db: PTsqlite3): i32;

implementation

const
  SWARMVTAB_MAX_OPEN = 9;

  LARGEST_INT64_C  : i64 = $7FFFFFFFFFFFFFFF;
  SMALLEST_INT64_C : i64 = i64($8000000000000000);

type
  PPSqlite3VtabCursor = ^PSqlite3VtabCursor;

  PUnionSrc = ^TUnionSrc;
  TUnionSrc = record
    zDb           : PAnsiChar;       { Database containing source table }
    zTab          : PAnsiChar;       { Source table name }
    iMin          : i64;             { Minimum rowid }
    iMax          : i64;             { Maximum rowid }

    { swarmvtab only }
    zFile         : PAnsiChar;       { Database file containing zTab }
    zContext      : PAnsiChar;       { Context string, if any }
    nUser         : i32;             { Current number of users }
    db            : PTsqlite3;       { Per-source db handle (swarmvtab) }
    pNextClosable : PUnionSrc;       { Next in closable list }
  end;

  PUnionTab = ^TUnionTab;
  TUnionTab = record
    base          : Tsqlite3_vtab;
    db            : PTsqlite3;
    bSwarm        : i32;             { 1 for swarmvtab, 0 for unionvtab }
    iPK           : i32;             { INTEGER PRIMARY KEY column, or -1 }
    nSrc          : i32;
    aSrc          : PUnionSrc;       { Sorted by rowid range }

    { swarmvtab only }
    bHasContext   : i32;
    zSourceStr    : PAnsiChar;       { Expected unionSourceToStr() value }
    pNotFound     : PVdbe;           { UDF invoked when file absent on open }
    pOpenClose    : PVdbe;           { UDF invoked around open/close }
    pClosable     : PUnionSrc;       { First in closable list }
    nOpen         : i32;
    nMaxOpen      : i32;
  end;

  PUnionCsr = ^TUnionCsr;
  TUnionCsr = record
    base          : Tsqlite3_vtab_cursor;
    pStmt         : PVdbe;           { Statement driving the current scan }

    { swarmvtab only }
    iMaxRowid     : i64;             { Last rowid to visit }
    iTab          : i32;             { Index of current source }
  end;

var
  unionModule: Tsqlite3_module;

{ ---------------------------------------------------------------------------
  Helpers — small wrappers around alloc / strdup / prepare / finalize.
  --------------------------------------------------------------------------- }

function unionGetDb(pTab: PUnionTab; pSrc: PUnionSrc): PTsqlite3; inline;
begin
  if pTab^.bSwarm <> 0 then Result := pSrc^.db else Result := pTab^.db;
end;

function unionMalloc(var rc: i32; nByte: i64): Pointer;
begin
  if rc = SQLITE_OK then begin
    Result := sqlite3_malloc64(u64(nByte));
    if Result <> nil then
      FillChar(Result^, nByte, 0)
    else
      rc := SQLITE_NOMEM;
  end else
    Result := nil;
end;

function unionStrdup(var rc: i32; const zIn: PAnsiChar): PAnsiChar;
var
  nByte: i64;
begin
  Result := nil;
  if zIn = nil then Exit;
  if rc <> SQLITE_OK then Exit;
  nByte := StrLen(zIn) + 1;
  Result := PAnsiChar(unionMalloc(rc, nByte));
  if Result <> nil then
    Move(zIn^, Result^, nByte);
end;

{ unionvtab.c:202..238 — dequote in-place if first char is one of
  ' " ` [ . }
procedure unionDequote(z: PAnsiChar);
var
  q     : AnsiChar;
  iIn,
  iOut  : i32;
begin
  if z = nil then Exit;
  q := z[0];
  if (q = '[') or (q = '''') or (q = '"') or (q = '`') then begin
    iIn  := 1;
    iOut := 0;
    if q = '[' then q := ']';
    while z[iIn] <> #0 do begin
      if z[iIn] = q then begin
        if z[iIn + 1] <> q then begin
          Inc(iIn);
          Break;
        end else begin
          Inc(iIn, 2);
          z[iOut] := q;
          Inc(iOut);
        end;
      end else begin
        z[iOut] := z[iIn];
        Inc(iOut);
        Inc(iIn);
      end;
    end;
    z[iOut] := #0;
  end;
end;

function unionPrepare(var rc: i32; db: PTsqlite3;
  zSql: PAnsiChar; pzErr: PPAnsiChar): PVdbe;
var
  pRet: Pointer;
  rc2:  i32;
begin
  Result := nil;
  if rc <> SQLITE_OK then Exit;
  pRet := nil;
  rc2 := sqlite3_prepare_v2(db, zSql, -1, @pRet, nil);
  if rc2 <> SQLITE_OK then begin
    if pzErr <> nil then
      pzErr^ := sqlite3PfMprintf('sql error: %s',
        [sqlite3_errmsg(db)]);
    rc := rc2;
  end;
  Result := PVdbe(pRet);
end;

function unionPreparePrintf(var rc: i32; pzErr: PPAnsiChar;
  db: PTsqlite3; const fmt: AnsiString;
  const args: array of const): PVdbe;
var
  zSql: PAnsiChar;
begin
  Result := nil;
  zSql := sqlite3PfMprintf(PAnsiChar(fmt), args);
  if rc = SQLITE_OK then begin
    if zSql = nil then
      rc := SQLITE_NOMEM
    else
      Result := unionPrepare(rc, db, zSql, pzErr);
  end;
  sqlite3_free(zSql);
end;

procedure unionFinalize(var rc: i32; pStmt: PVdbe; pzErr: PPAnsiChar);
var
  db:  PTsqlite3;
  rc2: i32;
begin
  db := sqlite3_db_handle(pStmt);
  rc2 := sqlite3_finalize(pStmt);
  if rc = SQLITE_OK then begin
    rc := rc2;
    if (rc2 <> SQLITE_OK) and (pzErr <> nil) then
      pzErr^ := sqlite3PfMprintf('%s', [sqlite3_errmsg(db)]);
  end;
end;

{ unionvtab.c:432..459 — bind-and-step the openclose UDF, if any. }
function unionInvokeOpenClose(pTab: PUnionTab; pSrc: PUnionSrc;
  bClose: i32; pzErr: PPAnsiChar): i32;
var
  rc: i32;
begin
  rc := SQLITE_OK;
  if pTab^.pOpenClose <> nil then begin
    sqlite3_bind_text(pTab^.pOpenClose, 1, pSrc^.zFile, -1, nil);
    if pTab^.bHasContext <> 0 then
      sqlite3_bind_text(pTab^.pOpenClose, 2, pSrc^.zContext, -1, nil);
    sqlite3_bind_int(pTab^.pOpenClose, 2 + pTab^.bHasContext, bClose);
    sqlite3_step(pTab^.pOpenClose);
    rc := sqlite3_reset(pTab^.pOpenClose);
    if rc <> SQLITE_OK then begin
      if pzErr <> nil then
        pzErr^ := sqlite3PfMprintf('%s', [sqlite3_errmsg(pTab^.db)]);
    end;
  end;
  Result := rc;
end;

{ unionvtab.c:466..481 — close down to nMax sources (swarmvtab only). }
procedure unionCloseSources(pTab: PUnionTab; nMax: i32);
var
  pp: ^PUnionSrc;
  p:  PUnionSrc;
begin
  while (pTab^.pClosable <> nil) and (pTab^.nOpen > nMax) do begin
    pp := @pTab^.pClosable;
    while (pp^)^.pNextClosable <> nil do pp := @((pp^)^.pNextClosable);
    p := pp^;
    Assert(p^.db <> nil);
    sqlite3_close(p^.db);
    p^.db := nil;
    pp^ := nil;
    Dec(pTab^.nOpen);
    unionInvokeOpenClose(pTab, p, 1, nil);
  end;
end;

{ unionvtab.c:486..510 — xDisconnect / xDestroy. }
function unionDisconnect(pVtab: PSqlite3Vtab): i32; cdecl;
var
  pTab: PUnionTab;
  pSrc: PUnionSrc;
  i:    i32;
  hadDb: Boolean;
begin
  if pVtab <> nil then begin
    pTab := PUnionTab(pVtab);
    if pTab^.aSrc <> nil then begin
      pSrc := pTab^.aSrc;
      for i := 0 to pTab^.nSrc - 1 do begin
        hadDb := pSrc^.db <> nil;
        sqlite3_close(pSrc^.db);
        if hadDb then
          unionInvokeOpenClose(pTab, pSrc, 1, nil);
        sqlite3_free(pSrc^.zDb);
        sqlite3_free(pSrc^.zTab);
        sqlite3_free(pSrc^.zFile);
        sqlite3_free(pSrc^.zContext);
        Inc(pSrc);
      end;
    end;
    sqlite3_finalize(pTab^.pNotFound);
    sqlite3_finalize(pTab^.pOpenClose);
    sqlite3_free(pTab^.zSourceStr);
    sqlite3_free(pTab^.aSrc);
    sqlite3_free(pTab);
  end;
  Result := SQLITE_OK;
end;

{ unionvtab.c:518..540 — verify pSrc names a rowid table. }
function unionIsIntkeyTable(db: PTsqlite3; pSrc: PUnionSrc;
  pzErr: PPAnsiChar): i32;
var
  bPk:    i32;
  zType:  PAnsiChar;
  rc:     i32;
  zPfx,
  zSep:   PAnsiChar;
begin
  bPk := 0;
  zType := nil;
  sqlite3_table_column_metadata(db, pSrc^.zDb, pSrc^.zTab, '_rowid_',
    @zType, nil, nil, @bPk, nil);
  rc := sqlite3_errcode(db);
  if (rc = SQLITE_ERROR)
   or ((rc = SQLITE_OK) and ((bPk = 0) or (sqlite3_stricmp(PChar('integer'), PChar(zType)) <> 0))) then
  begin
    rc := SQLITE_ERROR;
    if pSrc^.zDb <> nil then begin zPfx := pSrc^.zDb; zSep := '.'; end
    else                       begin zPfx := ''; zSep := ''; end;
    pzErr^ := sqlite3PfMprintf('no such rowid table: %s%s%s',
      [zPfx, zSep, pSrc^.zTab]);
  end;
  Result := rc;
end;

{ unionvtab.c:558..585 — return canonical column-list signature. }
function unionSourceToStr(var rc: i32; pTab: PUnionTab;
  pSrc: PUnionSrc; pzErr: PPAnsiChar): PAnsiChar;
var
  db:    PTsqlite3;
  pStmt: PVdbe;
  z:     PAnsiChar;
begin
  Result := nil;
  if rc <> SQLITE_OK then Exit;
  db := unionGetDb(pTab, pSrc);
  rc := unionIsIntkeyTable(db, pSrc, pzErr);
  pStmt := unionPrepare(rc, db,
    'SELECT group_concat(quote(name) || ''.'' || quote(type)) '
    + 'FROM pragma_table_info(?, ?)', pzErr);
  if rc = SQLITE_OK then begin
    sqlite3_bind_text(pStmt, 1, pSrc^.zTab, -1, nil);
    sqlite3_bind_text(pStmt, 2, pSrc^.zDb, -1, nil);
    if sqlite3_step(pStmt) = SQLITE_ROW then begin
      z := sqlite3_column_text(pStmt, 0);
      Result := unionStrdup(rc, z);
    end;
    unionFinalize(rc, pStmt, pzErr);
  end;
end;

{ unionvtab.c:594..612 — verify all sources share schema. }
function unionSourceCheck(pTab: PUnionTab; pzErr: PPAnsiChar): i32;
var
  rc: i32;
  z0, z: PAnsiChar;
  i: i32;
  pSrc: PUnionSrc;
begin
  rc := SQLITE_OK;
  z0 := unionSourceToStr(rc, pTab, pTab^.aSrc, pzErr);
  for i := 1 to pTab^.nSrc - 1 do begin
    pSrc := pTab^.aSrc; Inc(pSrc, i);
    z := unionSourceToStr(rc, pTab, pSrc, pzErr);
    if (rc = SQLITE_OK) and (sqlite3_stricmp(PChar(z), PChar(z0)) <> 0) then
    begin
      pzErr^ := sqlite3PfMprintf('source table schema mismatch', []);
      rc := SQLITE_ERROR;
    end;
    sqlite3_free(z);
  end;
  sqlite3_free(z0);
  Result := rc;
end;

{ unionvtab.c:618..639 — open swarmvtab source db, retrying through the
  optional "missing" UDF. }
function unionOpenDatabaseInner(pTab: PUnionTab; pSrc: PUnionSrc;
  pzErr: PPAnsiChar): i32;
const
  openFlags = SQLITE_OPEN_READONLY or SQLITE_OPEN_URI;
var
  rc: i32;
begin
  rc := unionInvokeOpenClose(pTab, pSrc, 0, pzErr);
  if rc <> SQLITE_OK then begin Result := rc; Exit; end;
  rc := sqlite3_open_v2(pSrc^.zFile, @pSrc^.db, openFlags, nil);
  if rc = SQLITE_OK then begin Result := rc; Exit; end;
  if pTab^.pNotFound <> nil then begin
    sqlite3_close(pSrc^.db); pSrc^.db := nil;
    sqlite3_bind_text(pTab^.pNotFound, 1, pSrc^.zFile, -1, nil);
    if pTab^.bHasContext <> 0 then
      sqlite3_bind_text(pTab^.pNotFound, 2, pSrc^.zContext, -1, nil);
    sqlite3_step(pTab^.pNotFound);
    rc := sqlite3_reset(pTab^.pNotFound);
    if rc <> SQLITE_OK then begin
      pzErr^ := sqlite3PfMprintf('%s', [sqlite3_errmsg(pTab^.db)]);
      Result := rc; Exit;
    end;
    rc := sqlite3_open_v2(pSrc^.zFile, @pSrc^.db, openFlags, nil);
  end;
  if rc <> SQLITE_OK then
    pzErr^ := sqlite3PfMprintf('%s', [sqlite3_errmsg(pSrc^.db)]);
  Result := rc;
end;

{ unionvtab.c:660..691 — ensure source iSrc is open (swarmvtab). }
function unionOpenDatabase(pTab: PUnionTab; iSrc: i32;
  pzErr: PPAnsiChar): i32;
var
  rc:   i32;
  pSrc: PUnionSrc;
  z:    PAnsiChar;
begin
  rc := SQLITE_OK;
  pSrc := pTab^.aSrc; Inc(pSrc, iSrc);
  Assert((pTab^.bSwarm <> 0) and (iSrc < pTab^.nSrc));
  if pSrc^.db = nil then begin
    unionCloseSources(pTab, pTab^.nMaxOpen - 1);
    rc := unionOpenDatabaseInner(pTab, pSrc, pzErr);
    if rc = SQLITE_OK then begin
      z := unionSourceToStr(rc, pTab, pSrc, pzErr);
      if rc = SQLITE_OK then begin
        if pTab^.zSourceStr = nil then
          pTab^.zSourceStr := z
        else begin
          if sqlite3_stricmp(PChar(z), PChar(pTab^.zSourceStr)) <> 0 then
          begin
            pzErr^ := sqlite3PfMprintf('source table schema mismatch', []);
            rc := SQLITE_ERROR;
          end;
          sqlite3_free(z);
        end;
      end;
    end;
    if rc = SQLITE_OK then begin
      pSrc^.pNextClosable := pTab^.pClosable;
      pTab^.pClosable := pSrc;
      Inc(pTab^.nOpen);
    end else begin
      sqlite3_close(pSrc^.db); pSrc^.db := nil;
      unionInvokeOpenClose(pTab, pSrc, 1, nil);
    end;
  end;
  Result := rc;
end;

{ unionvtab.c:701..714 — increment refcount; remove from closable list. }
procedure unionIncrRefcount(pTab: PUnionTab; iTab: i32);
var
  pSrc: PUnionSrc;
  pp:   ^PUnionSrc;
begin
  if pTab^.bSwarm <> 0 then begin
    pSrc := pTab^.aSrc; Inc(pSrc, iTab);
    Assert((pSrc^.nUser >= 0) and (pSrc^.db <> nil));
    if pSrc^.nUser = 0 then begin
      pp := @pTab^.pClosable;
      while pp^ <> pSrc do pp := @((pp^)^.pNextClosable);
      pp^ := pSrc^.pNextClosable;
      pSrc^.pNextClosable := nil;
    end;
    Inc(pSrc^.nUser);
  end;
end;

{ unionvtab.c:723..739 — finalize cursor stmt, release refcount, recycle. }
function unionFinalizeCsrStmt(pCsr: PUnionCsr): i32;
var
  rc:   i32;
  pTab: PUnionTab;
  pSrc: PUnionSrc;
begin
  rc := SQLITE_OK;
  if pCsr^.pStmt <> nil then begin
    pTab := PUnionTab(pCsr^.base.pVtab);
    pSrc := pTab^.aSrc; Inc(pSrc, pCsr^.iTab);
    rc := sqlite3_finalize(pCsr^.pStmt);
    pCsr^.pStmt := nil;
    if pTab^.bSwarm <> 0 then begin
      Dec(pSrc^.nUser);
      Assert(pSrc^.nUser >= 0);
      if pSrc^.nUser = 0 then begin
        pSrc^.pNextClosable := pTab^.pClosable;
        pTab^.pClosable := pSrc;
      end;
      unionCloseSources(pTab, pTab^.nMaxOpen);
    end;
  end;
  Result := rc;
end;

function unionIsspace(c: AnsiChar): Boolean; inline;
begin
  Result := (c = ' ') or (c = #10) or (c = #13) or (c = #9);
end;

function unionIsidchar(c: AnsiChar): Boolean; inline;
begin
  Result := ((c >= 'a') and (c <= 'z'))
         or ((c >= 'A') and (c <= 'Z'))
         or ((c >= '0') and (c <= '9'));
end;

{ unionvtab.c:766..843 — parse swarmvtab options. }
procedure unionConfigureVtab(var rcInOut: i32; pTab: PUnionTab;
  pStmt: PVdbe; nArg: i32; azArg: PPAnsiChar;
  pzErr: PPAnsiChar);
var
  rc:    i32;
  i,
  nOpt,
  iParam: i32;
  zArg,
  zOpt,
  zVal:  PAnsiChar;
  zCtxArg: PAnsiChar;
  cur: PPAnsiChar;
begin
  rc := rcInOut;
  if rc = SQLITE_OK then
    if sqlite3_column_count(pStmt) > 4 then pTab^.bHasContext := 1
    else pTab^.bHasContext := 0;
  if pTab^.bHasContext <> 0 then zCtxArg := ',?' else zCtxArg := '';
  i := 0;
  cur := azArg;
  while (rc = SQLITE_OK) and (i < nArg) do begin
    zArg := unionStrdup(rc, cur^);
    if zArg <> nil then begin
      unionDequote(zArg);
      zOpt := zArg;
      while unionIsspace(zOpt^) do Inc(zOpt);
      zVal := zOpt;
      if zVal^ = ':' then Inc(zVal);
      while unionIsidchar(zVal^) do Inc(zVal);
      nOpt := i32(NativeUInt(zVal) - NativeUInt(zOpt));
      while unionIsspace(zVal^) do Inc(zVal);
      if zVal^ = '=' then begin
        zOpt[nOpt] := #0;
        Inc(zVal);
        while unionIsspace(zVal^) do Inc(zVal);
        zVal := unionStrdup(rc, zVal);
        if zVal <> nil then begin
          unionDequote(zVal);
          if zOpt[0] = ':' then begin
            iParam := sqlite3_bind_parameter_index(pStmt, zOpt);
            if iParam = 0 then begin
              pzErr^ := sqlite3PfMprintf(
                'swarmvtab: no such SQL parameter: %s', [zOpt]);
              rc := SQLITE_ERROR;
            end else
              rc := sqlite3_bind_text(pStmt, iParam, zVal, -1,
                passqlite3vdbe.SQLITE_TRANSIENT);
          end else if (nOpt = 7) and
            (sqlite3_strnicmp(zOpt, PAnsiChar('maxopen'), 7) = 0) then
          begin
            pTab^.nMaxOpen := StrToIntDef(StrPas(zVal), 0);
            if pTab^.nMaxOpen <= 0 then begin
              pzErr^ := sqlite3PfMprintf(
                'swarmvtab: illegal maxopen value', []);
              rc := SQLITE_ERROR;
            end;
          end else if (nOpt = 7) and
            (sqlite3_strnicmp(zOpt, PAnsiChar('missing'), 7) = 0) then
          begin
            if pTab^.pNotFound <> nil then begin
              pzErr^ := sqlite3PfMprintf(
                'swarmvtab: duplicate "missing" option', []);
              rc := SQLITE_ERROR;
            end else
              pTab^.pNotFound := unionPreparePrintf(rc, pzErr, pTab^.db,
                'SELECT "%w"(?%s)', [zVal, zCtxArg]);
          end else if (nOpt = 9) and
            (sqlite3_strnicmp(zOpt, PAnsiChar('openclose'), 9) = 0) then
          begin
            if pTab^.pOpenClose <> nil then begin
              pzErr^ := sqlite3PfMprintf(
                'swarmvtab: duplicate "openclose" option', []);
              rc := SQLITE_ERROR;
            end else
              pTab^.pOpenClose := unionPreparePrintf(rc, pzErr, pTab^.db,
                'SELECT "%w"(?,?%s)', [zVal, zCtxArg]);
          end else begin
            pzErr^ := sqlite3PfMprintf(
              'swarmvtab: unrecognized option: %s', [zOpt]);
            rc := SQLITE_ERROR;
          end;
          sqlite3_free(zVal);
        end;
      end else begin
        if (i = 0) and (nArg = 1) then
          pTab^.pNotFound := unionPreparePrintf(rc, pzErr, pTab^.db,
            'SELECT "%w"(?)', [zArg])
        else begin
          pzErr^ := sqlite3PfMprintf(
            'swarmvtab: parse error: %s', [cur^]);
          rc := SQLITE_ERROR;
        end;
      end;
      sqlite3_free(zArg);
    end;
    Inc(cur); Inc(i);
  end;
  rcInOut := rc;
end;

{ unionvtab.c:864..1006 — xConnect / xCreate.

  argv[0] = module name ("unionvtab" / "swarmvtab")
  argv[1] = database name (must be "temp")
  argv[2] = table name
  argv[3] = SQL statement
  argv[4..] = swarmvtab options (only valid when pAux != nil) }
function unionConnect(db: PTsqlite3; pAux: Pointer;
  argc: i32; argv: PPAnsiChar; ppVtab: PPSqlite3Vtab;
  pzErr: PPAnsiChar): i32; cdecl;
var
  pTab:    PUnionTab;
  rc:      i32;
  bSwarm:  i32;
  zVtab:   PAnsiChar;
  argvArr: PPAnsiChar;
  zArgIn:  PAnsiChar;
  zArg:    PAnsiChar;
  pStmt:   PVdbe;
  nAlloc:  i32;
  zDb,
  zTab,
  zContext,
  zDecl:   PAnsiChar;
  iMin,
  iMax:    i64;
  pSrc:    PUnionSrc;
  aNew:    PUnionSrc;
  nNew:    i32;
  tdb:     PTsqlite3;
  argv4:   PPAnsiChar;
begin
  pTab := nil;
  rc := SQLITE_OK;
  if pAux = nil then bSwarm := 0 else bSwarm := 1;
  if bSwarm <> 0 then zVtab := 'swarmvtab' else zVtab := 'unionvtab';
  argvArr := argv;

  if sqlite3_stricmp(PChar('temp'), PChar(argvArr[1])) <> 0 then begin
    pzErr^ := sqlite3PfMprintf(
      '%s tables must be created in TEMP schema', [zVtab]);
    rc := SQLITE_ERROR;
  end else if (argc < 4) or ((argc > 4) and (bSwarm = 0)) then begin
    pzErr^ := sqlite3PfMprintf('wrong number of arguments for %s', [zVtab]);
    rc := SQLITE_ERROR;
  end else begin
    nAlloc := 0;
    pStmt := nil;
    zArgIn := argvArr[3];
    zArg := unionStrdup(rc, zArgIn);
    unionDequote(zArg);
    pStmt := unionPreparePrintf(rc, pzErr, db,
      'SELECT * FROM (%z) ORDER BY 3', [zArg]);

    pTab := PUnionTab(unionMalloc(rc, SizeOf(TUnionTab)));
    if pTab <> nil then begin
      Assert(rc = SQLITE_OK);
      pTab^.db := db;
      pTab^.bSwarm := bSwarm;
      pTab^.nMaxOpen := SWARMVTAB_MAX_OPEN;
    end;

    if (bSwarm <> 0) and (pTab <> nil) then begin
      argv4 := argvArr; Inc(argv4, 4);
      unionConfigureVtab(rc, pTab, pStmt, argc - 4, argv4, pzErr);
    end;

    while (rc = SQLITE_OK) and (sqlite3_step(pStmt) = SQLITE_ROW) do begin
      zDb := sqlite3_column_text(pStmt, 0);
      zTab := sqlite3_column_text(pStmt, 1);
      iMin := sqlite3_column_int64(pStmt, 2);
      iMax := sqlite3_column_int64(pStmt, 3);

      if nAlloc <= pTab^.nSrc then begin
        if nAlloc <> 0 then nNew := nAlloc * 2 else nNew := 8;
        aNew := PUnionSrc(sqlite3_realloc64(pTab^.aSrc,
          u64(nNew) * SizeOf(TUnionSrc)));
        if aNew = nil then begin
          rc := SQLITE_NOMEM;
          Break;
        end;
        FillChar((PByte(aNew) + pTab^.nSrc * SizeOf(TUnionSrc))^,
          (nNew - pTab^.nSrc) * SizeOf(TUnionSrc), 0);
        pTab^.aSrc := aNew;
        nAlloc := nNew;
      end;

      pSrc := pTab^.aSrc; Inc(pSrc, pTab^.nSrc - 1 + 0);
      if (iMax < iMin)
       or ((pTab^.nSrc > 0) and (iMin <= (pTab^.aSrc + pTab^.nSrc - 1)^.iMax)) then
      begin
        pzErr^ := sqlite3PfMprintf('rowid range mismatch error', []);
        rc := SQLITE_ERROR;
      end;

      if rc = SQLITE_OK then begin
        pSrc := pTab^.aSrc; Inc(pSrc, pTab^.nSrc);
        Inc(pTab^.nSrc);
        pSrc^.zTab := unionStrdup(rc, zTab);
        pSrc^.iMin := iMin;
        pSrc^.iMax := iMax;
        if bSwarm <> 0 then
          pSrc^.zFile := unionStrdup(rc, zDb)
        else
          pSrc^.zDb := unionStrdup(rc, zDb);
        if pTab^.bHasContext <> 0 then begin
          zContext := sqlite3_column_text(pStmt, 4);
          pSrc^.zContext := unionStrdup(rc, zContext);
        end;
      end;
    end;
    unionFinalize(rc, pStmt, pzErr);
    pStmt := nil;

    if (rc = SQLITE_OK) and (pTab^.nSrc = 0) then begin
      pzErr^ := sqlite3PfMprintf('no source tables configured', []);
      rc := SQLITE_ERROR;
    end;

    if rc = SQLITE_OK then begin
      if bSwarm <> 0 then
        rc := unionOpenDatabase(pTab, 0, pzErr)
      else
        rc := unionSourceCheck(pTab, pzErr);
    end;

    if rc = SQLITE_OK then begin
      pSrc := pTab^.aSrc;
      tdb := unionGetDb(pTab, pSrc);
      pStmt := unionPreparePrintf(rc, pzErr, tdb, 'SELECT '
        + '''CREATE TABLE xyz('''
        + '    || group_concat(quote(name) || '' '' || type, '', '')'
        + '    || '')'','
        + 'max((cid+1) * (type=''INTEGER'' COLLATE nocase AND pk=1))-1 '
        + 'FROM pragma_table_info(%Q, ?)',
        [pSrc^.zTab, pSrc^.zDb]);
    end;
    if (rc = SQLITE_OK) and (pStmt <> nil) and
       (sqlite3_step(pStmt) = SQLITE_ROW) then
    begin
      zDecl := sqlite3_column_text(pStmt, 0);
      rc := sqlite3_declare_vtab(db, zDecl);
      pTab^.iPK := sqlite3_column_int(pStmt, 1);
    end;
    if pStmt <> nil then unionFinalize(rc, pStmt, pzErr);
  end;

  if rc <> SQLITE_OK then begin
    unionDisconnect(PSqlite3Vtab(pTab));
    pTab := nil;
  end;
  ppVtab^ := PSqlite3Vtab(pTab);
  Result := rc;
end;

{ unionvtab.c:1018..1023 — xOpen. }
function unionOpen(p: PSqlite3Vtab;
  ppCursor: PPSqlite3VtabCursor): i32; cdecl;
var
  pCsr: PUnionCsr;
  rc:   i32;
begin
  rc := SQLITE_OK;
  pCsr := PUnionCsr(unionMalloc(rc, SizeOf(TUnionCsr)));
  if pCsr <> nil then ppCursor^ := PSqlite3VtabCursor(@pCsr^.base);
  Result := rc;
end;

{ unionvtab.c:1029..1033 — xClose. }
function unionClose(cur: PSqlite3VtabCursor): i32; cdecl;
var
  pCsr: PUnionCsr;
begin
  pCsr := PUnionCsr(cur);
  unionFinalizeCsrStmt(pCsr);
  sqlite3_free(pCsr);
  Result := SQLITE_OK;
end;

{ unionvtab.c:1041..1067 — doUnionNext: step current stmt, on EOF advance to
  next swarmvtab source. }
function doUnionNext(pCsr: PUnionCsr): i32;
var
  rc:   i32;
  pTab: PUnionTab;
  pSrc: PUnionSrc;
  whereStr: AnsiString;
begin
  rc := SQLITE_OK;
  Assert(pCsr^.pStmt <> nil);
  if sqlite3_step(pCsr^.pStmt) <> SQLITE_ROW then begin
    pTab := PUnionTab(pCsr^.base.pVtab);
    rc := unionFinalizeCsrStmt(pCsr);
    if (rc = SQLITE_OK) and (pTab^.bSwarm <> 0) then begin
      Inc(pCsr^.iTab);
      if pCsr^.iTab < pTab^.nSrc then begin
        pSrc := pTab^.aSrc; Inc(pSrc, pCsr^.iTab);
        if pCsr^.iMaxRowid >= pSrc^.iMin then begin
          rc := unionOpenDatabase(pTab, pCsr^.iTab, @pTab^.base.zErrMsg);
          if pSrc^.iMax > pCsr^.iMaxRowid then
            whereStr := 'WHERE _rowid_ <='
          else
            whereStr := '-- ';
          pCsr^.pStmt := unionPreparePrintf(rc, @pTab^.base.zErrMsg,
            pSrc^.db, 'SELECT rowid, * FROM %Q %s %lld',
            [pSrc^.zTab, PAnsiChar(whereStr), pCsr^.iMaxRowid]);
          if rc = SQLITE_OK then begin
            Assert(pCsr^.pStmt <> nil);
            unionIncrRefcount(pTab, pCsr^.iTab);
            rc := SQLITE_ROW;
          end;
        end;
      end;
    end;
  end;
  Result := rc;
end;

{ unionvtab.c:1073..1079 — xNext. }
function unionNext(cur: PSqlite3VtabCursor): i32; cdecl;
var rc: i32;
begin
  repeat
    rc := doUnionNext(PUnionCsr(cur));
  until rc <> SQLITE_ROW;
  Result := rc;
end;

{ unionvtab.c:1085..1091 — xColumn. }
function unionColumn(cur: PSqlite3VtabCursor;
  ctx: Psqlite3_context; i: i32): i32; cdecl;
var pCsr: PUnionCsr;
begin
  pCsr := PUnionCsr(cur);
  sqlite3_result_value(ctx, sqlite3_column_value(pCsr^.pStmt, i + 1));
  Result := SQLITE_OK;
end;

{ unionvtab.c:1097..1101 — xRowid. }
function unionRowid(cur: PSqlite3VtabCursor; pRowid: Pi64): i32; cdecl;
var pCsr: PUnionCsr;
begin
  pCsr := PUnionCsr(cur);
  pRowid^ := sqlite3_column_int64(pCsr^.pStmt, 0);
  Result := SQLITE_OK;
end;

{ unionvtab.c:1107..1110 — xEof. }
function unionEof(cur: PSqlite3VtabCursor): i32; cdecl;
begin
  if PUnionCsr(cur)^.pStmt = nil then Result := 1 else Result := 0;
end;

{ unionvtab.c:1116..1213 — xFilter.  Compose a UNION ALL query touching only
  source tables whose rowid range overlaps [iMin..iMax], then prepare it. }
function unionFilter(pVtabCursor: PSqlite3VtabCursor;
  idxNum: i32; idxStr: PAnsiChar;
  argc: i32; argv: PPsqlite3_value): i32; cdecl;
var
  pTab:  PUnionTab;
  pCsr:  PUnionCsr;
  rc:    i32;
  i:     i32;
  zSql:  PAnsiChar;
  zNew:  PAnsiChar;
  bZero: i32;
  iMin,
  iMax:  i64;
  pSrc:  PUnionSrc;
  zPfx,
  zSep,
  zSfx,
  zJoin: PAnsiChar;
  zWhere: PAnsiChar;
  argvArr: PPsqlite3_value;
  db:    PTsqlite3;
begin
  pTab := PUnionTab(pVtabCursor^.pVtab);
  pCsr := PUnionCsr(pVtabCursor);
  rc := SQLITE_OK;
  zSql := nil;
  bZero := 0;
  iMin := SMALLEST_INT64_C;
  iMax := LARGEST_INT64_C;
  argvArr := argv;

  if idxNum = SQLITE_INDEX_CONSTRAINT_EQ then begin
    Assert(argc = 1);
    iMin := sqlite3_value_int64(argvArr[0]);
    iMax := iMin;
  end else begin
    if (idxNum and (SQLITE_INDEX_CONSTRAINT_LE or SQLITE_INDEX_CONSTRAINT_LT)) <> 0 then
    begin
      Assert(argc >= 1);
      iMax := sqlite3_value_int64(argvArr[0]);
      if (idxNum and SQLITE_INDEX_CONSTRAINT_LT) <> 0 then begin
        if iMax = SMALLEST_INT64_C then bZero := 1
        else Dec(iMax);
      end;
    end;
    if (idxNum and (SQLITE_INDEX_CONSTRAINT_GE or SQLITE_INDEX_CONSTRAINT_GT)) <> 0 then
    begin
      Assert(argc >= 1);
      iMin := sqlite3_value_int64(argvArr[argc - 1]);
      if (idxNum and SQLITE_INDEX_CONSTRAINT_GT) <> 0 then begin
        if iMin = LARGEST_INT64_C then bZero := 1
        else Inc(iMin);
      end;
    end;
  end;

  unionFinalizeCsrStmt(pCsr);
  if bZero <> 0 then begin Result := SQLITE_OK; Exit; end;

  for i := 0 to pTab^.nSrc - 1 do begin
    pSrc := pTab^.aSrc; Inc(pSrc, i);
    if (iMin > pSrc^.iMax) or (iMax < pSrc^.iMin) then Continue;

    if pSrc^.zDb <> nil then begin
      zPfx := ''''; zSep := pSrc^.zDb; zSfx := '''.';
    end else begin
      zPfx := ''; zSep := ''; zSfx := '';
    end;
    if zSql <> nil then zJoin := ' UNION ALL ' else zJoin := '';
    zNew := sqlite3PfMprintf('%z%sSELECT rowid, * FROM %s%q%s%Q',
      [zSql, zJoin, zPfx, zSep, zSfx, pSrc^.zTab]);
    zSql := zNew;
    if zSql = nil then begin rc := SQLITE_NOMEM; Break; end;

    if iMin = iMax then begin
      zNew := sqlite3PfMprintf('%z WHERE rowid=%lld', [zSql, iMin]);
      zSql := zNew;
    end else begin
      zWhere := 'WHERE';
      if (iMin <> SMALLEST_INT64_C) and (iMin > pSrc^.iMin) then begin
        zNew := sqlite3PfMprintf('%z WHERE rowid>=%lld', [zSql, iMin]);
        zSql := zNew;
        zWhere := 'AND';
      end;
      if (iMax <> LARGEST_INT64_C) and (iMax < pSrc^.iMax) then begin
        zNew := sqlite3PfMprintf('%z %s rowid<=%lld',
          [zSql, zWhere, iMax]);
        zSql := zNew;
      end;
    end;

    if pTab^.bSwarm <> 0 then begin
      pCsr^.iTab := i;
      pCsr^.iMaxRowid := iMax;
      rc := unionOpenDatabase(pTab, i, @pTab^.base.zErrMsg);
      Break;
    end;
  end;

  if zSql = nil then begin Result := rc; Exit; end;
  pSrc := pTab^.aSrc; Inc(pSrc, pCsr^.iTab);
  db := unionGetDb(pTab, pSrc);
  pCsr^.pStmt := unionPrepare(rc, db, zSql, @pTab^.base.zErrMsg);
  if pCsr^.pStmt <> nil then
    unionIncrRefcount(pTab, pCsr^.iTab);
  sqlite3_free(zSql);
  if rc <> SQLITE_OK then begin Result := rc; Exit; end;
  Result := unionNext(pVtabCursor);
end;

{ unionvtab.c:1232..1294 — xBestIndex. }
function unionBestIndex(tab: PSqlite3Vtab;
  pIdxInfo: PSqlite3IndexInfo): i32; cdecl;
var
  pTab: PUnionTab;
  iEq, iLt, iGt: i32;
  i:    i32;
  pC:   PSqlite3IndexConstraint;
  pUse: PSqlite3IndexConstraintUsage;
  iCons: i32;
  idxNum: i32;
  nRow:  i64;
begin
  pTab := PUnionTab(tab);
  iEq := -1; iLt := -1; iGt := -1;
  pC := pIdxInfo^.aConstraint;
  for i := 0 to pIdxInfo^.nConstraint - 1 do begin
    if (pC^.usable <> 0) and ((pC^.iColumn < 0) or (pC^.iColumn = pTab^.iPK)) then
    begin
      case pC^.op of
        SQLITE_INDEX_CONSTRAINT_EQ: iEq := i;
        SQLITE_INDEX_CONSTRAINT_LE,
        SQLITE_INDEX_CONSTRAINT_LT: iLt := i;
        SQLITE_INDEX_CONSTRAINT_GE,
        SQLITE_INDEX_CONSTRAINT_GT: iGt := i;
      end;
    end;
    Inc(pC);
  end;
  if iEq >= 0 then begin
    pIdxInfo^.estimatedRows := 1;
    pIdxInfo^.idxFlags := SQLITE_INDEX_SCAN_UNIQUE;
    pIdxInfo^.estimatedCost := 3.0;
    pIdxInfo^.idxNum := SQLITE_INDEX_CONSTRAINT_EQ;
    pUse := pIdxInfo^.aConstraintUsage; Inc(pUse, iEq);
    pUse^.argvIndex := 1;
    pUse^.omit := 1;
  end else begin
    iCons := 1;
    idxNum := 0;
    nRow := 1000000;
    if iLt >= 0 then begin
      nRow := nRow div 2;
      pUse := pIdxInfo^.aConstraintUsage; Inc(pUse, iLt);
      pUse^.argvIndex := iCons; Inc(iCons);
      pUse^.omit := 1;
      pC := pIdxInfo^.aConstraint; Inc(pC, iLt);
      idxNum := idxNum or pC^.op;
    end;
    if iGt >= 0 then begin
      nRow := nRow div 2;
      pUse := pIdxInfo^.aConstraintUsage; Inc(pUse, iGt);
      pUse^.argvIndex := iCons; Inc(iCons);
      pUse^.omit := 1;
      pC := pIdxInfo^.aConstraint; Inc(pC, iGt);
      idxNum := idxNum or pC^.op;
    end;
    pIdxInfo^.estimatedRows := nRow;
    pIdxInfo^.estimatedCost := 3.0 * nRow;
    pIdxInfo^.idxNum := idxNum;
  end;
  Result := SQLITE_OK;
end;

function sqlite3UnionvtabInit(db: PTsqlite3): i32;
var rc: i32;
begin
  rc := sqlite3_create_module(db, 'unionvtab', @unionModule, nil);
  if rc = SQLITE_OK then
    rc := sqlite3_create_module(db, 'swarmvtab', @unionModule, db);
  Result := rc;
end;

initialization
  FillChar(unionModule, SizeOf(unionModule), 0);
  unionModule.iVersion    := 0;
  unionModule.xCreate     := @unionConnect;
  unionModule.xConnect    := @unionConnect;
  unionModule.xBestIndex  := @unionBestIndex;
  unionModule.xDisconnect := @unionDisconnect;
  unionModule.xDestroy    := @unionDisconnect;
  unionModule.xOpen       := @unionOpen;
  unionModule.xClose      := @unionClose;
  unionModule.xFilter     := @unionFilter;
  unionModule.xNext       := @unionNext;
  unionModule.xEof        := @unionEof;
  unionModule.xColumn     := @unionColumn;
  unionModule.xRowid      := @unionRowid;
end.
