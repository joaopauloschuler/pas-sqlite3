{
  SPDX-License-Identifier: blessing

  Faithful port of ../sqlite3/src/test_fs.c (920 lines in C).

  Three test virtual-table modules used by vtabH.test and fts4content.test:
    "fs"     — file-content reader keyed off a docid->path map table.
    "fsdir"  — eponymous read-only directory lister (cols dir, name).
    "fstree" — eponymous read-only recursive file-system tree reader
               (cols path, size, data).

  Public entry: Sqlitetestfs_Init(interp) — registers the Tcl command
  `register_fs_module DB`.
}
{$I passqlite3.inc}
unit TestModuleFs;

interface

uses
  ctypes,
  strings,
  sysutils,
  BaseUnix,
  Unix,
  PasTclBridge,
  passqlite3types,
  passqlite3util,
  passqlite3printf,
  passqlite3os,
  passqlite3vdbe,
  passqlite3vtab,
  passqlite3main;

function Sqlitetestfs_Init(interp: PTclInterp): cint; cdecl;

implementation

type
  PPSqlite3Vtab       = ^PSqlite3Vtab;
  PPSqlite3VtabCursor = ^PSqlite3VtabCursor;
  PPAnsiCharConst     = ^PAnsiChar;

  { test_fs.c:90..95 — struct fs_vtab. }
  Pfs_vtab = ^Tfs_vtab;
  Tfs_vtab = record
    base : Tsqlite3_vtab;
    db   : PTsqlite3;
    zDb  : PAnsiChar;               { Name of db containing zTbl }
    zTbl : PAnsiChar;              { Name of docid->file map table }
  end;

  { test_fs.c:98..104 — struct fs_cursor. }
  Pfs_cursor = ^Tfs_cursor;
  Tfs_cursor = record
    base   : Tsqlite3_vtab_cursor;
    pStmt  : PVdbe;
    zBuf   : PAnsiChar;
    nBuf   : cint;
    nAlloc : cint;
  end;

  { test_fs.c:109..113 — struct FsdirVtab. }
  PFsdirVtab = ^TFsdirVtab;
  TFsdirVtab = record
    base : Tsqlite3_vtab;
  end;

  { test_fs.c:115..121 — struct FsdirCsr. }
  PFsdirCsr = ^TFsdirCsr;
  TFsdirCsr = record
    base   : Tsqlite3_vtab_cursor;
    zDir   : PAnsiChar;            { Buffer containing directory scanned }
    pDir   : pDir;                 { Open directory }
    iRowid : sqlite3_int64;
    pEntry : pDirent;
  end;

  { test_fs.c:318..321 — struct FstreeVtab. }
  PFstreeVtab = ^TFstreeVtab;
  TFstreeVtab = record
    base : Tsqlite3_vtab;
    db   : PTsqlite3;
  end;

  { test_fs.c:323..327 — struct FstreeCsr. }
  PFstreeCsr = ^TFstreeCsr;
  TFstreeCsr = record
    base  : Tsqlite3_vtab_cursor;
    pStmt : PVdbe;                  { Statement to list paths }
    fd    : cint;                  { File descriptor open on current path }
  end;

var
  fsModule     : Tsqlite3_module;
  fsdirModule  : Tsqlite3_module;
  fstreeModule : Tsqlite3_module;

{*************************************************************************
** Start of fsdir implementation.
*}

{ test_fs.c:134..156 — fsdirConnect. }
function fsdirConnect(db: PTsqlite3; pAux: Pointer;
  argc: cint; argv: PPAnsiCharConst; ppVtab: PPSqlite3Vtab;
  pzErr: PPAnsiChar): cint; cdecl;
var
  pTab: PFsdirVtab;
begin
  if argc <> 3 then
  begin
    pzErr^ := sqlite3PfMprintf('wrong number of arguments', []);
    Result := SQLITE_ERROR;
    Exit;
  end;

  pTab := PFsdirVtab(sqlite3_malloc(SizeOf(TFsdirVtab)));
  if pTab = nil then begin Result := SQLITE_NOMEM; Exit; end;
  FillChar(pTab^, SizeOf(TFsdirVtab), 0);

  ppVtab^ := @pTab^.base;
  sqlite3_declare_vtab(db, PChar('CREATE TABLE xyz(dir, name);'));

  Result := SQLITE_OK;
end;

{ test_fs.c:161..164 — fsdirDisconnect. }
function fsdirDisconnect(pVtab: PSqlite3Vtab): cint; cdecl;
begin
  sqlite3_free(pVtab);
  Result := SQLITE_OK;
end;

{ test_fs.c:171..190 — fsdirBestIndex. }
function fsdirBestIndex(tab: PSqlite3Vtab; pIdxInfo: PSqlite3IndexInfo): cint; cdecl;
var
  ii    : cint;
  p     : PSqlite3IndexConstraint;
  pUsage: PSqlite3IndexConstraintUsage;
begin
  pIdxInfo^.estimatedCost := 1000000000.0;

  for ii := 0 to pIdxInfo^.nConstraint - 1 do
  begin
    p := pIdxInfo^.aConstraint;
    Inc(p, ii);
    if (p^.iColumn = 0) and (p^.usable <> 0)
       and (p^.op = SQLITE_INDEX_CONSTRAINT_EQ) then
    begin
      pUsage := pIdxInfo^.aConstraintUsage;
      Inc(pUsage, ii);
      pUsage^.omit := 1;
      pUsage^.argvIndex := 1;
      pIdxInfo^.idxNum := 1;
      pIdxInfo^.estimatedCost := 1.0;
      Break;
    end;
  end;

  Result := SQLITE_OK;
end;

{ test_fs.c:197..207 — fsdirOpen. }
function fsdirOpen(pVTab: PSqlite3Vtab; ppCursor: PPSqlite3VtabCursor): cint; cdecl;
var
  pCur: PFsdirCsr;
begin
  { Allocate an extra 256 bytes because it is undefined how big dirent.d_name
  ** is and we need enough space. }
  pCur := PFsdirCsr(sqlite3_malloc(SizeOf(TFsdirCsr) + 256));
  if pCur = nil then begin Result := SQLITE_NOMEM; Exit; end;
  FillChar(pCur^, SizeOf(TFsdirCsr), 0);
  ppCursor^ := @pCur^.base;
  Result := SQLITE_OK;
end;

{ test_fs.c:212..218 — fsdirClose. }
function fsdirClose(cur: PSqlite3VtabCursor): cint; cdecl;
var
  pCur: PFsdirCsr;
begin
  pCur := PFsdirCsr(cur);
  if pCur^.pDir <> nil then fpCloseDir(pCur^.pDir^);
  sqlite3_free(pCur^.zDir);
  sqlite3_free(pCur);
  Result := SQLITE_OK;
end;

{ test_fs.c:223..236 — fsdirNext. }
function fsdirNext(cur: PSqlite3VtabCursor): cint; cdecl;
var
  pCsr: PFsdirCsr;
begin
  pCsr := PFsdirCsr(cur);

  if pCsr^.pDir <> nil then
  begin
    pCsr^.pEntry := fpReadDir(pCsr^.pDir^);
    if pCsr^.pEntry = nil then
    begin
      fpCloseDir(pCsr^.pDir^);
      pCsr^.pDir := nil;
    end;
    Inc(pCsr^.iRowid);
  end;

  Result := SQLITE_OK;
end;

{ test_fs.c:241..270 — fsdirFilter. }
function fsdirFilter(pVtabCursor: PSqlite3VtabCursor;
  idxNum: cint; idxStr: PAnsiChar;
  argc: cint; argv: PPsqlite3_value): cint; cdecl;
var
  pCsr : PFsdirCsr;
  zDir : PAnsiChar;
  nDir : cint;
begin
  pCsr := PFsdirCsr(pVtabCursor);

  if (idxNum <> 1) or (argc <> 1) then
  begin
    Result := SQLITE_ERROR;
    Exit;
  end;

  pCsr^.iRowid := 0;
  sqlite3_free(pCsr^.zDir);
  if pCsr^.pDir <> nil then
  begin
    fpCloseDir(pCsr^.pDir^);
    pCsr^.pDir := nil;
  end;

  zDir := sqlite3_value_text(argv[0]);
  nDir := sqlite3_value_bytes(argv[0]);
  pCsr^.zDir := sqlite3_malloc(nDir + 1);
  if pCsr^.zDir = nil then begin Result := SQLITE_NOMEM; Exit; end;
  Move(zDir^, pCsr^.zDir^, nDir + 1);

  pCsr^.pDir := fpOpenDir(pCsr^.zDir);
  Result := fsdirNext(pVtabCursor);
end;

{ test_fs.c:275..278 — fsdirEof. }
function fsdirEof(cur: PSqlite3VtabCursor): cint; cdecl;
var
  pCsr: PFsdirCsr;
begin
  pCsr := PFsdirCsr(cur);
  if pCsr^.pDir = nil then Result := 1 else Result := 0;
end;

{ test_fs.c:283..299 — fsdirColumn. }
function fsdirColumn(cur: PSqlite3VtabCursor; ctx: Psqlite3_context;
  i: cint): cint; cdecl;
var
  pCsr: PFsdirCsr;
begin
  pCsr := PFsdirCsr(cur);
  case i of
    0: { dir }
      sqlite3_result_text(ctx, pCsr^.zDir, -1, SQLITE_STATIC);
    1: { name }
      sqlite3_result_text(ctx, @pCsr^.pEntry^.d_name[0], -1, SQLITE_TRANSIENT);
  else
    Assert(False);
  end;

  Result := SQLITE_OK;
end;

{ test_fs.c:304..308 — fsdirRowid. }
function fsdirRowid(cur: PSqlite3VtabCursor; pRowid: Pi64): cint; cdecl;
var
  pCsr: PFsdirCsr;
begin
  pCsr := PFsdirCsr(cur);
  pRowid^ := pCsr^.iRowid;
  Result := SQLITE_OK;
end;
{ End of fsdir implementation. }

{*************************************************************************
** Start of fstree implementation.
*}

{ test_fs.c:340..363 — fstreeConnect. }
function fstreeConnect(db: PTsqlite3; pAux: Pointer;
  argc: cint; argv: PPAnsiCharConst; ppVtab: PPSqlite3Vtab;
  pzErr: PPAnsiChar): cint; cdecl;
var
  pTab: PFstreeVtab;
begin
  if argc <> 3 then
  begin
    pzErr^ := sqlite3PfMprintf('wrong number of arguments', []);
    Result := SQLITE_ERROR;
    Exit;
  end;

  pTab := PFstreeVtab(sqlite3_malloc(SizeOf(TFstreeVtab)));
  if pTab = nil then begin Result := SQLITE_NOMEM; Exit; end;
  FillChar(pTab^, SizeOf(TFstreeVtab), 0);
  pTab^.db := db;

  ppVtab^ := @pTab^.base;
  sqlite3_declare_vtab(db, PChar('CREATE TABLE xyz(path, size, data);'));

  Result := SQLITE_OK;
end;

{ test_fs.c:368..371 — fstreeDisconnect. }
function fstreeDisconnect(pVtab: PSqlite3Vtab): cint; cdecl;
begin
  sqlite3_free(pVtab);
  Result := SQLITE_OK;
end;

{ test_fs.c:378..399 — fstreeBestIndex. }
function fstreeBestIndex(tab: PSqlite3Vtab; pIdxInfo: PSqlite3IndexInfo): cint; cdecl;
var
  ii    : cint;
  p     : PSqlite3IndexConstraint;
  pUsage: PSqlite3IndexConstraintUsage;
begin
  for ii := 0 to pIdxInfo^.nConstraint - 1 do
  begin
    p := pIdxInfo^.aConstraint;
    Inc(p, ii);
    if (p^.iColumn = 0) and (p^.usable <> 0) and (
          (p^.op = SQLITE_INDEX_CONSTRAINT_GLOB)
       or (p^.op = SQLITE_INDEX_CONSTRAINT_LIKE)
       or (p^.op = SQLITE_INDEX_CONSTRAINT_EQ)
    ) then
    begin
      pUsage := pIdxInfo^.aConstraintUsage;
      Inc(pUsage, ii);
      pIdxInfo^.idxNum := p^.op;
      pUsage^.argvIndex := 1;
      pIdxInfo^.estimatedCost := 100000.0;
      Result := SQLITE_OK;
      Exit;
    end;
  end;

  pIdxInfo^.estimatedCost := 1000000000.0;
  Result := SQLITE_OK;
end;

{ test_fs.c:406..414 — fstreeOpen. }
function fstreeOpen(pVTab: PSqlite3Vtab; ppCursor: PPSqlite3VtabCursor): cint; cdecl;
var
  pCur: PFstreeCsr;
begin
  pCur := PFstreeCsr(sqlite3_malloc(SizeOf(TFstreeCsr)));
  if pCur = nil then begin Result := SQLITE_NOMEM; Exit; end;
  FillChar(pCur^, SizeOf(TFstreeCsr), 0);
  pCur^.fd := -1;
  ppCursor^ := @pCur^.base;
  Result := SQLITE_OK;
end;

{ test_fs.c:416..421 — fstreeCloseFd. }
procedure fstreeCloseFd(pCsr: PFstreeCsr);
begin
  if pCsr^.fd >= 0 then
  begin
    fpClose(pCsr^.fd);
    pCsr^.fd := -1;
  end;
end;

{ test_fs.c:426..432 — fstreeClose. }
function fstreeClose(cur: PSqlite3VtabCursor): cint; cdecl;
var
  pCsr: PFstreeCsr;
begin
  pCsr := PFstreeCsr(cur);
  sqlite3_finalize(pCsr^.pStmt);
  fstreeCloseFd(pCsr);
  sqlite3_free(pCsr);
  Result := SQLITE_OK;
end;

{ test_fs.c:437..452 — fstreeNext. }
function fstreeNext(cur: PSqlite3VtabCursor): cint; cdecl;
var
  pCsr: PFstreeCsr;
  rc  : cint;
begin
  pCsr := PFstreeCsr(cur);

  fstreeCloseFd(pCsr);
  rc := sqlite3_step(pCsr^.pStmt);
  if rc <> SQLITE_ROW then
  begin
    rc := sqlite3_finalize(pCsr^.pStmt);
    pCsr^.pStmt := nil;
  end
  else
  begin
    rc := SQLITE_OK;
    pCsr^.fd := fpOpen(sqlite3_column_text(pCsr^.pStmt, 0), O_RDONLY);
  end;

  Result := rc;
end;

{ test_fs.c:457..540 — fstreeFilter. }
function fstreeFilter(pVtabCursor: PSqlite3VtabCursor;
  idxNum: cint; idxStr: PAnsiChar;
  argc: cint; argv: PPsqlite3_value): cint; cdecl;
const
  zSql: PAnsiChar =
    'WITH r(d) AS (' +
    '  SELECT CASE WHEN dir=?2 THEN ?3 ELSE dir END || ''/'' || name ' +
    '    FROM fsdir WHERE dir=?1 AND name NOT LIKE ''.%''' +
    '  UNION ALL' +
    '  SELECT dir || ''/'' || name FROM r, fsdir WHERE dir=d AND name NOT LIKE ''.%''' +
    ') SELECT d FROM r;';
var
  pCsr    : PFstreeCsr;
  pTab    : PFstreeVtab;
  rc      : cint;
  zRoot   : PAnsiChar;
  nRoot   : cint;
  zPrefix : PAnsiChar;
  nPrefix : cint;
  zDir    : PAnsiChar;
  nDir    : cint;
  aWild   : array[0..1] of AnsiChar;
  zQuery  : PAnsiChar;
  i       : cint;
begin
  pCsr := PFstreeCsr(pVtabCursor);
  pTab := PFstreeVtab(pCsr^.base.pVtab);
  aWild[0] := #0;
  aWild[1] := #0;

  zRoot := PChar('/');
  nRoot := 1;
  zPrefix := PChar('');
  nPrefix := 0;

  zDir := zRoot;
  nDir := nRoot;

  fstreeCloseFd(pCsr);
  sqlite3_finalize(pCsr^.pStmt);
  pCsr^.pStmt := nil;
  rc := sqlite3_prepare_v2(pTab^.db, zSql, -1, @pCsr^.pStmt, nil);
  if rc <> SQLITE_OK then begin Result := rc; Exit; end;

  if idxNum <> 0 then
  begin
    zQuery := sqlite3_value_text(argv[0]);
    case idxNum of
      SQLITE_INDEX_CONSTRAINT_GLOB:
        begin
          aWild[0] := '*';
          aWild[1] := '?';
        end;
      SQLITE_INDEX_CONSTRAINT_LIKE:
        begin
          aWild[0] := '_';
          aWild[1] := '%';
        end;
    end;

    if sqlite3_strnicmp(zQuery, zPrefix, nPrefix) = 0 then
    begin
      i := nPrefix;
      while zQuery[i] <> #0 do
      begin
        if (zQuery[i] = aWild[0]) or (zQuery[i] = aWild[1]) then Break;
        if zQuery[i] = '/' then nDir := i;
        Inc(i);
      end;
      zDir := zQuery;
    end;
  end;
  if nDir = 0 then nDir := 1;

  sqlite3_bind_text(pCsr^.pStmt, 1, zDir, nDir, SQLITE_TRANSIENT);
  sqlite3_bind_text(pCsr^.pStmt, 2, zRoot, nRoot, SQLITE_TRANSIENT);
  sqlite3_bind_text(pCsr^.pStmt, 3, zPrefix, nPrefix, SQLITE_TRANSIENT);

  Result := fstreeNext(pVtabCursor);
end;

{ test_fs.c:545..548 — fstreeEof. }
function fstreeEof(cur: PSqlite3VtabCursor): cint; cdecl;
var
  pCsr: PFstreeCsr;
begin
  pCsr := PFstreeCsr(cur);
  if pCsr^.pStmt = nil then Result := 1 else Result := 0;
end;

{ test_fs.c:553..579 — fstreeColumn. }
function fstreeColumn(cur: PSqlite3VtabCursor; ctx: Psqlite3_context;
  i: cint): cint; cdecl;
var
  pCsr  : PFstreeCsr;
  sBuf  : stat;
  nRead : cint;
  aBuf  : PAnsiChar;
begin
  pCsr := PFstreeCsr(cur);
  if i = 0 then       { path }
    sqlite3_result_value(ctx, sqlite3_column_value(pCsr^.pStmt, 0))
  else
  begin
    fpFStat(pCsr^.fd, sBuf);

    if fpS_ISREG(sBuf.st_mode) then
    begin
      if i = 1 then
        sqlite3_result_int64(ctx, sBuf.st_size)
      else
      begin
        aBuf := sqlite3_malloc(sBuf.st_mode + 1);
        if aBuf = nil then begin Result := SQLITE_NOMEM; Exit; end;
        nRead := fpRead(pCsr^.fd, aBuf^, sBuf.st_mode);
        if nRead <> sBuf.st_mode then
        begin
          Result := SQLITE_IOERR;
          Exit;
        end;
        sqlite3_result_blob(ctx, aBuf, nRead, SQLITE_TRANSIENT);
        sqlite3_free(aBuf);
      end;
    end;
  end;

  Result := SQLITE_OK;
end;

{ test_fs.c:584..587 — fstreeRowid. }
function fstreeRowid(cur: PSqlite3VtabCursor; pRowid: Pi64): cint; cdecl;
begin
  pRowid^ := 0;
  Result := SQLITE_OK;
end;
{ End of fstree implementation. }

{*************************************************************************
** Start of fs implementation.
*}

{ test_fs.c:606..637 — fsConnect. }
function fsConnect(db: PTsqlite3; pAux: Pointer;
  argc: cint; argv: PPAnsiCharConst; ppVtab: PPSqlite3Vtab;
  pzErr: PPAnsiChar): cint; cdecl;
var
  pVtab : Pfs_vtab;
  nByte : cint;
  zTbl  : PAnsiChar;
  zDb   : PAnsiChar;
begin
  zDb := argv[1];

  if argc <> 4 then
  begin
    pzErr^ := sqlite3PfMprintf('wrong number of arguments', []);
    Result := SQLITE_ERROR;
    Exit;
  end;
  zTbl := argv[3];

  nByte := SizeOf(Tfs_vtab) + cint(StrLen(zTbl)) + 1 + cint(StrLen(zDb)) + 1;
  pVtab := Pfs_vtab(sqlite3MallocZero(nByte));
  if pVtab = nil then begin Result := SQLITE_NOMEM; Exit; end;

  pVtab^.zTbl := PAnsiChar(pVtab) + SizeOf(Tfs_vtab);
  pVtab^.zDb := pVtab^.zTbl + StrLen(zTbl) + 1;
  pVtab^.db := db;
  Move(zTbl^, pVtab^.zTbl^, StrLen(zTbl));
  Move(zDb^, pVtab^.zDb^, StrLen(zDb));
  ppVtab^ := @pVtab^.base;
  sqlite3_declare_vtab(db, PChar('CREATE TABLE x(path TEXT, data TEXT)'));

  Result := SQLITE_OK;
end;

{ test_fs.c:641..644 — fsDisconnect. }
function fsDisconnect(pVtab: PSqlite3Vtab): cint; cdecl;
begin
  sqlite3_free(pVtab);
  Result := SQLITE_OK;
end;

{ test_fs.c:650..655 — fsOpen. }
function fsOpen(pVTab: PSqlite3Vtab; ppCursor: PPSqlite3VtabCursor): cint; cdecl;
var
  pCur: Pfs_cursor;
begin
  pCur := Pfs_cursor(sqlite3MallocZero(SizeOf(Tfs_cursor)));
  ppCursor^ := @pCur^.base;
  Result := SQLITE_OK;
end;

{ test_fs.c:660..666 — fsClose. }
function fsClose(cur: PSqlite3VtabCursor): cint; cdecl;
var
  pCur: Pfs_cursor;
begin
  pCur := Pfs_cursor(cur);
  sqlite3_finalize(pCur^.pStmt);
  sqlite3_free(pCur^.zBuf);
  sqlite3_free(pCur);
  Result := SQLITE_OK;
end;

{ test_fs.c:668..676 — fsNext. }
function fsNext(cur: PSqlite3VtabCursor): cint; cdecl;
var
  pCur: Pfs_cursor;
  rc  : cint;
begin
  pCur := Pfs_cursor(cur);
  rc := sqlite3_step(pCur^.pStmt);
  if (rc = SQLITE_ROW) or (rc = SQLITE_DONE) then rc := SQLITE_OK;
  Result := rc;
end;

{ test_fs.c:678..708 — fsFilter. }
function fsFilter(pVtabCursor: PSqlite3VtabCursor;
  idxNum: cint; idxStr: PAnsiChar;
  argc: cint; argv: PPsqlite3_value): cint; cdecl;
var
  rc    : cint;
  pCur  : Pfs_cursor;
  p     : Pfs_vtab;
  zStmt : PAnsiChar;
begin
  pCur := Pfs_cursor(pVtabCursor);
  p := Pfs_vtab(pVtabCursor^.pVtab);

  Assert( ((idxNum = 0) and (argc = 0)) or ((idxNum = 1) and (argc = 1)) );
  if idxNum = 1 then
  begin
    zStmt := sqlite3PfMprintf(
      'SELECT * FROM %Q.%Q WHERE rowid=?', [p^.zDb, p^.zTbl]);
    if zStmt = nil then begin Result := SQLITE_NOMEM; Exit; end;
    rc := sqlite3_prepare_v2(p^.db, zStmt, -1, @pCur^.pStmt, nil);
    sqlite3_free(zStmt);
    if rc = SQLITE_OK then
      sqlite3_bind_value(pCur^.pStmt, 1, argv[0]);
  end
  else
  begin
    zStmt := sqlite3PfMprintf('SELECT * FROM %Q.%Q', [p^.zDb, p^.zTbl]);
    if zStmt = nil then begin Result := SQLITE_NOMEM; Exit; end;
    rc := sqlite3_prepare_v2(p^.db, zStmt, -1, @pCur^.pStmt, nil);
    sqlite3_free(zStmt);
  end;

  if rc = SQLITE_OK then
    rc := fsNext(pVtabCursor);
  Result := rc;
end;

{ test_fs.c:710..749 — fsColumn. }
function fsColumn(cur: PSqlite3VtabCursor; ctx: Psqlite3_context;
  i: cint): cint; cdecl;
var
  pCur  : Pfs_cursor;
  zFile : PAnsiChar;
  sbuf  : stat;
  fd    : cint;
  n     : cint;
  nNew  : sqlite3_int64;
  zNew  : PAnsiChar;
begin
  pCur := Pfs_cursor(cur);

  Assert( (i = 0) or (i = 1) or (i = 2) );
  if i = 0 then
    sqlite3_result_value(ctx, sqlite3_column_value(pCur^.pStmt, 0))
  else
  begin
    zFile := sqlite3_column_text(pCur^.pStmt, 1);
    fd := fpOpen(zFile, O_RDONLY);
    if fd < 0 then begin Result := SQLITE_IOERR; Exit; end;
    fpFStat(fd, sbuf);

    if sbuf.st_size >= pCur^.nAlloc then
    begin
      nNew := sbuf.st_size * 2;
      if nNew < 1024 then nNew := 1024;

      zNew := sqlite3Realloc(pCur^.zBuf, nNew);
      if zNew = nil then
      begin
        fpClose(fd);
        Result := SQLITE_NOMEM;
        Exit;
      end;
      pCur^.zBuf := zNew;
      pCur^.nAlloc := nNew;
    end;

    n := cint(fpRead(fd, pCur^.zBuf^, sbuf.st_size));
    fpClose(fd);
    if n <> sbuf.st_size then begin Result := SQLITE_ERROR; Exit; end;
    pCur^.nBuf := sbuf.st_size;
    pCur^.zBuf[pCur^.nBuf] := #0;

    sqlite3_result_text(ctx, pCur^.zBuf, -1, SQLITE_TRANSIENT);
  end;
  Result := SQLITE_OK;
end;

{ test_fs.c:751..755 — fsRowid. }
function fsRowid(cur: PSqlite3VtabCursor; pRowid: Pi64): cint; cdecl;
var
  pCur: Pfs_cursor;
begin
  pCur := Pfs_cursor(cur);
  pRowid^ := sqlite3_column_int64(pCur^.pStmt, 0);
  Result := SQLITE_OK;
end;

{ test_fs.c:757..760 — fsEof. }
function fsEof(cur: PSqlite3VtabCursor): cint; cdecl;
var
  pCur: Pfs_cursor;
begin
  pCur := Pfs_cursor(cur);
  if sqlite3_data_count(pCur^.pStmt) = 0 then Result := 1 else Result := 0;
end;

{ test_fs.c:762..780 — fsBestIndex. }
function fsBestIndex(tab: PSqlite3Vtab; pIdxInfo: PSqlite3IndexInfo): cint; cdecl;
var
  ii    : cint;
  pCons : PSqlite3IndexConstraint;
  pUsage: PSqlite3IndexConstraintUsage;
begin
  for ii := 0 to pIdxInfo^.nConstraint - 1 do
  begin
    pCons := pIdxInfo^.aConstraint;
    Inc(pCons, ii);
    if (pCons^.iColumn < 0) and (pCons^.usable <> 0)
       and (pCons^.op = SQLITE_INDEX_CONSTRAINT_EQ) then
    begin
      pUsage := pIdxInfo^.aConstraintUsage;
      Inc(pUsage, ii);
      pUsage^.omit := 0;
      pUsage^.argvIndex := 1;
      pIdxInfo^.idxNum := 1;
      pIdxInfo^.estimatedCost := 1.0;
      Break;
    end;
  end;

  Result := SQLITE_OK;
end;

{ getDbPointer — recover the sqlite3* behind a `db` Tcl command, or decode a
  hex "%p" string.  Mirrors TestModuleEcho/test1.c getDbPointer.
  fts4content.test calls register_fs_module with a connection-pointer string. }
function getDbPointer(interp: PTclInterp; zA: PAnsiChar;
  ppDb: PPTsqlite3): cint;
var
  cmdInfo: TTclCmdInfo;
  z      : PAnsiChar;
  v      : QWord;
  c      : cint;
begin
  if Tcl_GetCommandInfo(interp, PChar(zA), @cmdInfo) <> 0 then
    ppDb^ := PPTsqlite3(cmdInfo.objClientData)^
  else
  begin
    z := zA;
    if (z <> nil) and (z[0] = '0') and (z[1] = 'x') then
      Inc(z, 2);
    v := 0;
    while (z <> nil) and (z^ <> #0) do
    begin
      c := Ord(z^);
      if (c >= Ord('0')) and (c <= Ord('9')) then
        v := (v shl 4) + QWord(c - Ord('0'))
      else if (c >= Ord('a')) and (c <= Ord('f')) then
        v := (v shl 4) + QWord(c - Ord('a') + 10)
      else if (c >= Ord('A')) and (c <= Ord('F')) then
        v := (v shl 4) + QWord(c - Ord('A') + 10)
      else
        Break;
      Inc(z);
    end;
    ppDb^ := PTsqlite3(PtrUInt(v));
  end;
  Result := TCL_OK;
end;

{ test_fs.c:878..896 — register_fs_module. }
function register_fs_module(clientData: TClientData; interp: PTclInterp;
  objc: cint; objv: PPTclObj): cint; cdecl;
var
  db: PTsqlite3;
begin
  if objc <> 2 then
  begin
    Tcl_WrongNumArgs(interp, 1, objv, PChar('DB'));
    Result := TCL_ERROR;
    Exit;
  end;
  if getDbPointer(interp, Tcl_GetString(objv[1]), @db) <> 0 then
  begin
    Result := TCL_ERROR;
    Exit;
  end;
  sqlite3_create_module(db, PChar('fs'), @fsModule, Pointer(interp));
  sqlite3_create_module(db, PChar('fsdir'), @fsdirModule, nil);
  sqlite3_create_module(db, PChar('fstree'), @fstreeModule, nil);
  Result := TCL_OK;
end;

{ test_fs.c:904..920 — Sqlitetestfs_Init. }
function Sqlitetestfs_Init(interp: PTclInterp): cint; cdecl;
begin
  Tcl_CreateObjCommand(interp, PChar('register_fs_module'),
    @register_fs_module, nil, nil);
  Result := TCL_OK;
end;

initialization
  { test_fs.c:786..812 — fsModule. }
  FillChar(fsModule, SizeOf(fsModule), 0);
  fsModule.iVersion    := 0;
  fsModule.xCreate     := @fsConnect;
  fsModule.xConnect    := @fsConnect;
  fsModule.xBestIndex  := @fsBestIndex;
  fsModule.xDisconnect := @fsDisconnect;
  fsModule.xDestroy    := @fsDisconnect;
  fsModule.xOpen       := @fsOpen;
  fsModule.xClose      := @fsClose;
  fsModule.xFilter     := @fsFilter;
  fsModule.xNext       := @fsNext;
  fsModule.xEof        := @fsEof;
  fsModule.xColumn     := @fsColumn;
  fsModule.xRowid      := @fsRowid;

  { test_fs.c:814..840 — fsdirModule. }
  FillChar(fsdirModule, SizeOf(fsdirModule), 0);
  fsdirModule.iVersion    := 0;
  fsdirModule.xCreate     := @fsdirConnect;
  fsdirModule.xConnect    := @fsdirConnect;
  fsdirModule.xBestIndex  := @fsdirBestIndex;
  fsdirModule.xDisconnect := @fsdirDisconnect;
  fsdirModule.xDestroy    := @fsdirDisconnect;
  fsdirModule.xOpen       := @fsdirOpen;
  fsdirModule.xClose      := @fsdirClose;
  fsdirModule.xFilter     := @fsdirFilter;
  fsdirModule.xNext       := @fsdirNext;
  fsdirModule.xEof        := @fsdirEof;
  fsdirModule.xColumn     := @fsdirColumn;
  fsdirModule.xRowid      := @fsdirRowid;

  { test_fs.c:842..868 — fstreeModule. }
  FillChar(fstreeModule, SizeOf(fstreeModule), 0);
  fstreeModule.iVersion    := 0;
  fstreeModule.xCreate     := @fstreeConnect;
  fstreeModule.xConnect    := @fstreeConnect;
  fstreeModule.xBestIndex  := @fstreeBestIndex;
  fstreeModule.xDisconnect := @fstreeDisconnect;
  fstreeModule.xDestroy    := @fstreeDisconnect;
  fstreeModule.xOpen       := @fstreeOpen;
  fstreeModule.xClose      := @fstreeClose;
  fstreeModule.xFilter     := @fstreeFilter;
  fstreeModule.xNext       := @fstreeNext;
  fstreeModule.xEof        := @fstreeEof;
  fstreeModule.xColumn     := @fstreeColumn;
  fstreeModule.xRowid      := @fstreeRowid;
end.
