{
  SPDX-License-Identifier: blessing

  Faithful port of ../sqlite3/ext/misc/qpvtab.c (462 lines in C).

  Eponymous virtual table that returns information about how the query
  planner called the xBestIndex method.  Intended for testing /
  debugging only.  Schema:

      CREATE TABLE qpvtab(
        vn     TEXT,           -- Name of an sqlite3_index_info field
        ix     INTEGER,        -- Array index or value
        cn     TEXT,            -- Column name
        op     INTEGER,        -- operator
        ux     BOOLEAN,        -- "usable" field
        rhs    TEXT,           -- sqlite3_vtab_rhs_value()
        a, b, c, d, e,         -- Extra columns to attach constraints to
        flags  INTEGER HIDDEN  -- control flags
      );

  Public entry: sqlite3QpvtabInit(db) — equivalent to
  sqlite3_qpvtab_init() in C.
}
{$I passqlite3.inc}
unit passqlite3qpvtab;

interface

uses
  passqlite3types,
  passqlite3util,
  passqlite3os,
  passqlite3printf,
  passqlite3vdbe,
  passqlite3vtab,
  passqlite3main;

function sqlite3QpvtabInit(db: PTsqlite3): i32;

implementation

const
  { qpvtab.c:141..153 — column ordinals. }
  QPVTAB_VN    = 0;
  QPVTAB_IX    = 1;
  QPVTAB_CN    = 2;
  QPVTAB_OP    = 3;
  QPVTAB_UX    = 4;
  QPVTAB_RHS   = 5;
  QPVTAB_A     = 6;
  QPVTAB_B     = 7;
  QPVTAB_C     = 8;
  QPVTAB_D     = 9;
  QPVTAB_E     = 10;
  QPVTAB_FLAGS = 11;
  QPVTAB_NONE  = 12;

  { qpvtab.c:104..114 — names of columns indexed 0..11; QPVTAB_NONE
    points at the empty string sentinel. }
  azColname: array[0..12] of PAnsiChar = (
    'vn', 'ix', 'cn', 'op', 'ux', 'rhs',
    'a', 'b', 'c', 'd', 'e', 'flags',
    ''
  );

type
  PPSqlite3VtabCursor = ^PSqlite3VtabCursor;

  { qpvtab.c:83..86 — qpvtab_vtab.  First field MUST be Tsqlite3_vtab. }
  PQpvtabVtab = ^TQpvtabVtab;
  TQpvtabVtab = record
    base : Tsqlite3_vtab;
  end;

  { qpvtab.c:92..99 — qpvtab_cursor. }
  PQpvtabCursor = ^TQpvtabCursor;
  TQpvtabCursor = record
    base   : Tsqlite3_vtab_cursor;
    iRowid : i64;
    zData  : PAnsiChar;
    nData  : i32;
    flags  : i32;
  end;

var
  qpvtabModule: Tsqlite3_module;

{ qpvtab.c:120..161 — qpvtabConnect. }
function qpvtabConnect(db: PTsqlite3; pAux: Pointer;
  argc: i32; argv: PPAnsiChar; ppVtab: PPSqlite3Vtab;
  pzErr: PPAnsiChar): i32; cdecl;
var
  pNew: PQpvtabVtab;
  rc:   i32;
begin
  rc := sqlite3_declare_vtab(db,
         'CREATE TABLE x(' +
         ' vn TEXT,' +
         ' ix INT,' +
         ' cn TEXT,' +
         ' op INT,' +
         ' ux BOOLEAN,' +
         ' rhs TEXT,' +
         ' a, b, c, d, e,' +
         ' flags INT HIDDEN)');
  if rc = SQLITE_OK then begin
    pNew := PQpvtabVtab(sqlite3Malloc(SizeOf(TQpvtabVtab)));
    ppVtab^ := PSqlite3Vtab(pNew);
    if pNew = nil then begin Result := SQLITE_NOMEM; Exit; end;
    FillChar(pNew^, SizeOf(TQpvtabVtab), 0);
  end;
  Result := rc;
end;

{ qpvtab.c:166..170 — qpvtabDisconnect. }
function qpvtabDisconnect(p: PSqlite3Vtab): i32; cdecl;
begin
  sqlite3_free(p);
  Result := SQLITE_OK;
end;

{ qpvtab.c:175..182 — qpvtabOpen. }
function qpvtabOpen(p: PSqlite3Vtab;
  ppCursor: PPSqlite3VtabCursor): i32; cdecl;
var pCur: PQpvtabCursor;
begin
  pCur := PQpvtabCursor(sqlite3Malloc(SizeOf(TQpvtabCursor)));
  if pCur = nil then begin Result := SQLITE_NOMEM; Exit; end;
  FillChar(pCur^, SizeOf(TQpvtabCursor), 0);
  ppCursor^ := PSqlite3VtabCursor(@pCur^.base);
  Result := SQLITE_OK;
end;

{ qpvtab.c:187..191 — qpvtabClose. }
function qpvtabClose(cur: PSqlite3VtabCursor): i32; cdecl;
begin
  sqlite3_free(cur);
  Result := SQLITE_OK;
end;

{ Walk a NUL-terminated buffer until c or 0; returns nil if c not found.
  Mirrors strchr() semantics used in the qpvtab cursor scan. }
function qpvStrchr(z: PAnsiChar; c: AnsiChar): PAnsiChar;
begin
  while z^ <> #0 do begin
    if z^ = c then begin Result := z; Exit; end;
    Inc(z);
  end;
  Result := nil;
end;

{ qpvtab.c:197..206 — qpvtabNext. }
function qpvtabNext(cur: PSqlite3VtabCursor): i32; cdecl;
var
  pCur: PQpvtabCursor;
  z, zEnd: PAnsiChar;
begin
  pCur := PQpvtabCursor(cur);
  if pCur^.iRowid < pCur^.nData then begin
    z := pCur^.zData + pCur^.iRowid;
    zEnd := qpvStrchr(z, #10);
    if zEnd <> nil then Inc(zEnd);
    pCur^.iRowid := i32(zEnd - pCur^.zData);
  end;
  Result := SQLITE_OK;
end;

{ Local atoi — qpvtab.c uses libc atoi which stops at first non-digit. }
function qpvAtoi(z: PAnsiChar): i32;
var
  v:    i32;
  neg:  Boolean;
begin
  v := 0;
  neg := False;
  while (z^ = ' ') or (z^ = #9) do Inc(z);
  if z^ = '-' then begin neg := True; Inc(z); end
  else if z^ = '+' then Inc(z);
  while (z^ >= '0') and (z^ <= '9') do begin
    v := v * 10 + (Ord(z^) - Ord('0'));
    Inc(z);
  end;
  if neg then v := -v;
  Result := v;
end;

{ qpvtab.c:212..247 — qpvtabColumn. }
function qpvtabColumn(cur: PSqlite3VtabCursor;
  ctx: Psqlite3_context; i: i32): i32; cdecl;
var
  pCur: PQpvtabCursor;
  z, zEnd: PAnsiChar;
  j: i32;
  c: AnsiChar;
  sep: AnsiChar;
begin
  pCur := PQpvtabCursor(cur);
  if (i >= QPVTAB_VN) and (i <= QPVTAB_RHS) and (pCur^.iRowid < pCur^.nData) then begin
    z := pCur^.zData + pCur^.iRowid;
    zEnd := nil;
    j := QPVTAB_VN;
    while True do begin
      if j = QPVTAB_RHS then sep := #10 else sep := ',';
      zEnd := qpvStrchr(z, sep);
      if (j = i) or (zEnd = nil) then Break;
      z := zEnd + 1;
      Inc(j);
    end;
    if zEnd = z then begin
      sqlite3_result_null(ctx);
    end else if (i = QPVTAB_IX) or (i = QPVTAB_OP) or (i = QPVTAB_UX) then begin
      sqlite3_result_int(ctx, qpvAtoi(z));
    end else begin
      sqlite3_result_text64(ctx, z, u64(zEnd - z), SQLITE_TRANSIENT, SQLITE_UTF8);
    end;
  end else if (i >= QPVTAB_A) and (i <= QPVTAB_E) then begin
    if (pCur^.flags and $001) <> 0 then begin
      sqlite3_result_int(ctx, i - QPVTAB_A + 1);
    end else begin
      c := AnsiChar(Ord('a') + i - QPVTAB_A);
      sqlite3_result_text64(ctx, @c, 1, SQLITE_TRANSIENT, SQLITE_UTF8);
    end;
  end else if i = QPVTAB_FLAGS then begin
    sqlite3_result_int(ctx, pCur^.flags);
  end;
  Result := SQLITE_OK;
end;

{ qpvtab.c:253..257 — qpvtabRowid. }
function qpvtabRowid(cur: PSqlite3VtabCursor; pRowid: Pi64): i32; cdecl;
var pCur: PQpvtabCursor;
begin
  pCur := PQpvtabCursor(cur);
  pRowid^ := pCur^.iRowid;
  Result := SQLITE_OK;
end;

{ qpvtab.c:263..266 — qpvtabEof. }
function qpvtabEof(cur: PSqlite3VtabCursor): i32; cdecl;
var pCur: PQpvtabCursor;
begin
  pCur := PQpvtabCursor(cur);
  if pCur^.iRowid >= pCur^.nData then Result := 1 else Result := 0;
end;

{ qpvtab.c:274..285 — qpvtabFilter. }
function qpvtabFilter(cur: PSqlite3VtabCursor;
  idxNum: i32; idxStr: PAnsiChar;
  argc: i32; argv: PPsqlite3_value): i32; cdecl;
var
  pCur: PQpvtabCursor;
  n:    SizeInt;
  z:    PAnsiChar;
begin
  pCur := PQpvtabCursor(cur);
  pCur^.iRowid := 0;
  pCur^.zData  := idxStr;
  if idxStr = nil then begin
    pCur^.nData := 0;
  end else begin
    n := 0;
    z := idxStr;
    while z^ <> #0 do begin Inc(n); Inc(z); end;
    pCur^.nData := i32(n);
  end;
  pCur^.flags := idxNum;
  Result := SQLITE_OK;
end;

{ qpvtab.c:289..330 — qpvtabStrAppendValue. }
procedure qpvtabStrAppendValue(pStr: PSqlite3Str; pVal: Psqlite3_value);
var
  i, n: i32;
  a:    PAnsiChar;
  pb:   PByte;
  c:    AnsiChar;
begin
  case sqlite3_value_type(pVal) of
    SQLITE_NULL:
      sqlite3_str_appendf(pStr, 'NULL', []);
    SQLITE_INTEGER:
      sqlite3_str_appendf(pStr, '%lld', [sqlite3_value_int64(pVal)]);
    SQLITE_FLOAT:
      sqlite3_str_appendf(pStr, '%!f', [sqlite3_value_double(pVal)]);
    SQLITE_TEXT:
      begin
        a := PAnsiChar(sqlite3_value_text(pVal));
        n := sqlite3_value_bytes(pVal);
        sqlite3_str_append(pStr, '''', 1);
        for i := 0 to n - 1 do begin
          c := a[i];
          if c = #10 then c := ' ';
          sqlite3_str_append(pStr, @c, 1);
          if c = '''' then sqlite3_str_append(pStr, @c, 1);
        end;
        sqlite3_str_append(pStr, '''', 1);
      end;
    SQLITE_BLOB:
      begin
        pb := PByte(sqlite3_value_blob(pVal));
        n := sqlite3_value_bytes(pVal);
        sqlite3_str_append(pStr, 'x''', 2);
        for i := 0 to n - 1 do
          sqlite3_str_appendf(pStr, '%02x', [i32(pb[i])]);
        sqlite3_str_append(pStr, '''', 1);
      end;
  end;
end;

{ qpvtab.c:338..412 — qpvtabBestIndex. }
function qpvtabBestIndex(tab: PSqlite3Vtab;
  pIdxInfo: PSqlite3IndexInfo): i32; cdecl;
var
  pStr: PSqlite3Str;
  i, k, rc: i32;
  iCol, op: i32;
  pVal: Psqlite3_value;
  pCons: PSqlite3IndexConstraint;
  pUse:  PSqlite3IndexConstraintUsage;
  pOrd:  PSqlite3IndexOrderBy;
  zNm:   PAnsiChar;
begin
  pStr := sqlite3_str_new(nil);
  k := 0;
  sqlite3_str_appendf(pStr, 'nConstraint,%d,,,,'#10, [pIdxInfo^.nConstraint]);
  for i := 0 to pIdxInfo^.nConstraint - 1 do begin
    pCons := pIdxInfo^.aConstraint;
    Inc(pCons, i);
    iCol := pCons^.iColumn;
    op   := pCons^.op;
    if (iCol = QPVTAB_FLAGS) and (pCons^.usable <> 0) then begin
      pVal := nil;
      rc := sqlite3_vtab_rhs_value(pIdxInfo, i, @pVal);
      if (rc = SQLITE_OK) and (pVal <> nil) then begin
        pIdxInfo^.idxNum := sqlite3_value_int(pVal);
        if (pIdxInfo^.idxNum and $002) <> 0 then
          pIdxInfo^.orderByConsumed := 1;
      end;
    end;
    if (op = SQLITE_INDEX_CONSTRAINT_LIMIT)
    or (op = SQLITE_INDEX_CONSTRAINT_OFFSET) then
      iCol := QPVTAB_NONE;
    if (iCol >= 0) and (iCol <= QPVTAB_NONE) then
      zNm := azColname[iCol]
    else
      zNm := '';
    sqlite3_str_appendf(pStr, 'aConstraint,%d,%s,%d,%d,',
      [i, zNm, op, i32(pCons^.usable)]);
    pVal := nil;
    rc := sqlite3_vtab_rhs_value(pIdxInfo, i, @pVal);
    if (rc = SQLITE_OK) and (pVal <> nil) then
      qpvtabStrAppendValue(pStr, pVal);
    sqlite3_str_append(pStr, #10, 1);
  end;
  for i := 0 to pIdxInfo^.nConstraint - 1 do begin
    pCons := pIdxInfo^.aConstraint;
    Inc(pCons, i);
    iCol := pCons^.iColumn;
    op   := pCons^.op;
    if (op = SQLITE_INDEX_CONSTRAINT_LIMIT)
    or (op = SQLITE_INDEX_CONSTRAINT_OFFSET) then
      iCol := QPVTAB_NONE;
    if (iCol >= QPVTAB_A) and (pCons^.usable <> 0) then begin
      pUse := pIdxInfo^.aConstraintUsage;
      Inc(pUse, i);
      Inc(k);
      pUse^.argvIndex := k;
      if (iCol <= QPVTAB_FLAGS) or ((pIdxInfo^.idxNum and $004) <> 0) then
        pUse^.omit := 1;
    end;
  end;
  sqlite3_str_appendf(pStr, 'nOrderBy,%d,,,,'#10, [pIdxInfo^.nOrderBy]);
  for i := 0 to pIdxInfo^.nOrderBy - 1 do begin
    pOrd := pIdxInfo^.aOrderBy;
    Inc(pOrd, i);
    iCol := pOrd^.iColumn;
    if iCol >= 0 then zNm := azColname[iCol] else zNm := 'rowid';
    sqlite3_str_appendf(pStr, 'aOrderBy,%d,%s,%d,,'#10,
      [i, zNm, i32(pOrd^.desc)]);
  end;
  sqlite3_str_appendf(pStr, 'sqlite3_vtab_distinct,%d,,,,'#10,
    [sqlite3_vtab_distinct(pIdxInfo)]);
  sqlite3_str_appendf(pStr, 'idxFlags,%d,,,,'#10, [pIdxInfo^.idxFlags]);
  sqlite3_str_appendf(pStr, 'colUsed,%d,,,,'#10, [i32(pIdxInfo^.colUsed)]);
  pIdxInfo^.estimatedCost := 10.0;
  pIdxInfo^.estimatedRows := 10;
  sqlite3_str_appendf(pStr, 'idxNum,%d,,,,'#10, [pIdxInfo^.idxNum]);
  sqlite3_str_appendf(pStr, 'orderByConsumed,%d,,,,'#10,
    [pIdxInfo^.orderByConsumed]);
  pIdxInfo^.idxStr := sqlite3_str_finish(pStr);
  pIdxInfo^.needToFreeIdxStr := 1;
  Result := SQLITE_OK;
end;

function sqlite3QpvtabInit(db: PTsqlite3): i32;
begin
  Result := sqlite3_create_module(db, 'qpvtab', @qpvtabModule, nil);
end;

initialization
  FillChar(qpvtabModule, SizeOf(qpvtabModule), 0);
  qpvtabModule.iVersion    := 0;
  qpvtabModule.xConnect    := @qpvtabConnect;
  qpvtabModule.xBestIndex  := @qpvtabBestIndex;
  qpvtabModule.xDisconnect := @qpvtabDisconnect;
  qpvtabModule.xOpen       := @qpvtabOpen;
  qpvtabModule.xClose      := @qpvtabClose;
  qpvtabModule.xFilter     := @qpvtabFilter;
  qpvtabModule.xNext       := @qpvtabNext;
  qpvtabModule.xEof        := @qpvtabEof;
  qpvtabModule.xColumn     := @qpvtabColumn;
  qpvtabModule.xRowid      := @qpvtabRowid;
end.
