{
  SPDX-License-Identifier: blessing

  Faithful port of ../sqlite3/ext/misc/templatevtab.c (269 lines in C).

  Eponymous-only read-only virtual table that exposes 10 fixed rows with
  two columns named "a" and "b".  Used as a baseline / sanity test for
  the vtab plumbing — its value is in the shape, not the data:

      SELECT rowid, a, b FROM templatevtab;
      -- rowid 1..10; a = 1000+rowid; b = 2000+rowid

  Public entry: sqlite3TemplateVtabInit(db) — equivalent to
  sqlite3_templatevtab_init() in C.
}
{$I passqlite3.inc}
unit passqlite3templatevtab;

interface

uses
  passqlite3types,
  passqlite3util,
  passqlite3os,
  passqlite3vdbe,
  passqlite3vtab,
  passqlite3main;

function sqlite3TemplateVtabInit(db: PTsqlite3): i32;

implementation

type
  PPSqlite3VtabCursor = ^PSqlite3VtabCursor;

  { templatevtab.c:67..72 — templatevtab_cursor.  First field MUST be
    Tsqlite3_vtab_cursor. }
  PTemplatevtabCursor = ^TTemplatevtabCursor;
  TTemplatevtabCursor = record
    base   : Tsqlite3_vtab_cursor;
    iRowid : i64;
  end;

const
  TEMPLATEVTAB_A = 0;
  TEMPLATEVTAB_B = 1;

var
  templatevtabModule: Tsqlite3_module;

{ templatevtab.c:87..110 — xConnect. }
function templatevtabConnect(db: PTsqlite3; pAux: Pointer;
  argc: i32; argv: PPAnsiChar; ppVtab: PPSqlite3Vtab;
  pzErr: PPAnsiChar): i32; cdecl;
var
  pNew: PSqlite3Vtab;
  rc:   i32;
begin
  rc := sqlite3_declare_vtab(db, 'CREATE TABLE x(a,b)');
  if rc <> SQLITE_OK then begin Result := rc; Exit; end;
  pNew := PSqlite3Vtab(sqlite3Malloc(SizeOf(Tsqlite3_vtab)));
  ppVtab^ := pNew;
  if pNew = nil then begin Result := SQLITE_NOMEM; Exit; end;
  FillChar(pNew^, SizeOf(Tsqlite3_vtab), 0);
  Result := SQLITE_OK;
end;

{ templatevtab.c:115..119 — xDisconnect. }
function templatevtabDisconnect(p: PSqlite3Vtab): i32; cdecl;
begin
  sqlite3_free(p);
  Result := SQLITE_OK;
end;

{ templatevtab.c:124..131 — xOpen. }
function templatevtabOpen(p: PSqlite3Vtab;
  ppCursor: PPSqlite3VtabCursor): i32; cdecl;
var pCur: PTemplatevtabCursor;
begin
  pCur := PTemplatevtabCursor(sqlite3Malloc(SizeOf(TTemplatevtabCursor)));
  if pCur = nil then begin Result := SQLITE_NOMEM; Exit; end;
  FillChar(pCur^, SizeOf(TTemplatevtabCursor), 0);
  ppCursor^ := PSqlite3VtabCursor(@pCur^.base);
  Result := SQLITE_OK;
end;

{ templatevtab.c:136..140 — xClose. }
function templatevtabClose(cur: PSqlite3VtabCursor): i32; cdecl;
begin
  sqlite3_free(cur);
  Result := SQLITE_OK;
end;

{ templatevtab.c:146..150 — xNext. }
function templatevtabNext(cur: PSqlite3VtabCursor): i32; cdecl;
var pCur: PTemplatevtabCursor;
begin
  pCur := PTemplatevtabCursor(cur);
  Inc(pCur^.iRowid);
  Result := SQLITE_OK;
end;

{ templatevtab.c:156..172 — xColumn.  Two columns: a = 1000+rowid,
  b = 2000+rowid. }
function templatevtabColumn(cur: PSqlite3VtabCursor;
  ctx: Psqlite3_context; i: i32): i32; cdecl;
var pCur: PTemplatevtabCursor;
begin
  pCur := PTemplatevtabCursor(cur);
  case i of
    TEMPLATEVTAB_A: sqlite3_result_int(ctx, i32(1000 + pCur^.iRowid));
  else
    { TEMPLATEVTAB_B (default) }
    sqlite3_result_int(ctx, i32(2000 + pCur^.iRowid));
  end;
  Result := SQLITE_OK;
end;

{ templatevtab.c:178..182 — xRowid. }
function templatevtabRowid(cur: PSqlite3VtabCursor; pRowid: Pi64): i32; cdecl;
var pCur: PTemplatevtabCursor;
begin
  pCur := PTemplatevtabCursor(cur);
  pRowid^ := pCur^.iRowid;
  Result := SQLITE_OK;
end;

{ templatevtab.c:188..191 — xEof.  Iteration covers rowids 1..10. }
function templatevtabEof(cur: PSqlite3VtabCursor): i32; cdecl;
var pCur: PTemplatevtabCursor;
begin
  pCur := PTemplatevtabCursor(cur);
  if pCur^.iRowid >= 10 then Result := 1 else Result := 0;
end;

{ templatevtab.c:199..207 — xFilter.  Always rewinds to rowid 1. }
function templatevtabFilter(cur: PSqlite3VtabCursor;
  idxNum: i32; idxStr: PAnsiChar;
  argc: i32; argv: PPsqlite3_value): i32; cdecl;
var pCur: PTemplatevtabCursor;
begin
  pCur := PTemplatevtabCursor(cur);
  pCur^.iRowid := 1;
  Result := SQLITE_OK;
end;

{ templatevtab.c:215..222 — xBestIndex.  Constant cost; no constraint
  selectivity is honoured (the table is too small to bother). }
function templatevtabBestIndex(tab: PSqlite3Vtab;
  pIdxInfo: PSqlite3IndexInfo): i32; cdecl;
begin
  pIdxInfo^.estimatedCost := 10.0;
  pIdxInfo^.estimatedRows := 10;
  Result := SQLITE_OK;
end;

function sqlite3TemplateVtabInit(db: PTsqlite3): i32;
begin
  Result := sqlite3_create_module(db, 'templatevtab',
    @templatevtabModule, nil);
end;

initialization
  FillChar(templatevtabModule, SizeOf(templatevtabModule), 0);
  templatevtabModule.iVersion    := 0;
  { xCreate intentionally left nil — eponymous-only. }
  templatevtabModule.xConnect    := @templatevtabConnect;
  templatevtabModule.xBestIndex  := @templatevtabBestIndex;
  templatevtabModule.xDisconnect := @templatevtabDisconnect;
  templatevtabModule.xOpen       := @templatevtabOpen;
  templatevtabModule.xClose      := @templatevtabClose;
  templatevtabModule.xFilter     := @templatevtabFilter;
  templatevtabModule.xNext       := @templatevtabNext;
  templatevtabModule.xEof        := @templatevtabEof;
  templatevtabModule.xColumn     := @templatevtabColumn;
  templatevtabModule.xRowid      := @templatevtabRowid;
end.
