{
  SPDX-License-Identifier: blessing

  Faithful port of ../sqlite3/ext/misc/closure.c (971 lines in C).

  Provides the `transitive_closure` virtual table, a parameterised reader that
  computes the transitive closure of a parent/child relation living in a real
  user table.

      CREATE VIRTUAL TABLE x USING transitive_closure(
        tablename=<tablename>,      -- T
        idcolumn=<columnname>,      -- X
        parentcolumn=<columnname>   -- P
      );

  The defaults established at CREATE time may be overridden per-query through
  hidden constraint columns (tablename, idcolumn, parentcolumn) in the WHERE
  clause; the root=$root term is required to produce any rows.

  Public entry: sqlite3ClosureInit(db) — equivalent to sqlite3_closure_init().
}
{$I passqlite3.inc}
unit passqlite3closure;

interface

uses
  passqlite3types,
  passqlite3util,
  passqlite3printf,
  passqlite3os,
  passqlite3vdbe,
  passqlite3vtab,
  passqlite3main;

function sqlite3ClosureInit(db: PTsqlite3): i32;

implementation

type
  PPSqlite3VtabCursor = ^PSqlite3VtabCursor;

  PClosureAvl = ^TClosureAvl;
  TClosureAvl = record
    id          : i64;          { Id of this entry in the table }
    iGeneration : i32;          { Which generation is this entry part of }
    pList       : PClosureAvl;  { A linked list of nodes (queue) }
    pBefore     : PClosureAvl;  { Other elements less than id }
    pAfter      : PClosureAvl;  { Other elements greater than id }
    pUp         : PClosureAvl;  { Parent element }
    height      : SmallInt;     { Height of this node.  Leaf == 1 }
    imbalance   : SmallInt;     { Height difference between pBefore/pAfter }
  end;
  PPClosureAvl = ^PClosureAvl;

  TClosureAvlDestroy = procedure(p: PClosureAvl);

  PClosureVtab = ^TClosureVtab;
  TClosureVtab = record
    base          : Tsqlite3_vtab;
    zDb           : PAnsiChar;
    zSelf         : PAnsiChar;
    zTableName    : PAnsiChar;
    zIdColumn     : PAnsiChar;
    zParentColumn : PAnsiChar;
    db            : PTsqlite3;
    nCursor       : i32;
  end;

  PClosureCursor = ^TClosureCursor;
  TClosureCursor = record
    base          : Tsqlite3_vtab_cursor;
    pVtab         : PClosureVtab;
    zTableName    : PAnsiChar;
    zIdColumn     : PAnsiChar;
    zParentColumn : PAnsiChar;
    pCurrent      : PClosureAvl;
    pClosure      : PClosureAvl;
  end;

  TClosureQueue = record
    pFirst : PClosureAvl;
    pLast  : PClosureAvl;
  end;
  PClosureQueue = ^TClosureQueue;

const
  CLOSURE_COL_ID           = 0;
  CLOSURE_COL_DEPTH        = 1;
  CLOSURE_COL_ROOT         = 2;
  CLOSURE_COL_TABLENAME    = 3;
  CLOSURE_COL_IDCOLUMN     = 4;
  CLOSURE_COL_PARENTCOLUMN = 5;

var
  closureModule: Tsqlite3_module;

{ ---------------------------------------------------------------------------
  AVL Tree implementation (closure.c:182..350)
  --------------------------------------------------------------------------- }

procedure closureAvlRecomputeHeight(p: PClosureAvl);
var hBefore, hAfter: SmallInt;
begin
  if p^.pBefore <> nil then hBefore := p^.pBefore^.height else hBefore := 0;
  if p^.pAfter  <> nil then hAfter  := p^.pAfter^.height  else hAfter  := 0;
  p^.imbalance := hBefore - hAfter;
  if hBefore > hAfter then p^.height := hBefore + 1
                      else p^.height := hAfter + 1;
end;

function closureAvlRotateBefore(pP: PClosureAvl): PClosureAvl;
var pB, pY: PClosureAvl;
begin
  pB := pP^.pBefore;
  pY := pB^.pAfter;
  pB^.pUp     := pP^.pUp;
  pB^.pAfter  := pP;
  pP^.pUp     := pB;
  pP^.pBefore := pY;
  if pY <> nil then pY^.pUp := pP;
  closureAvlRecomputeHeight(pP);
  closureAvlRecomputeHeight(pB);
  Result := pB;
end;

function closureAvlRotateAfter(pP: PClosureAvl): PClosureAvl;
var pA, pY: PClosureAvl;
begin
  pA := pP^.pAfter;
  pY := pA^.pBefore;
  pA^.pUp     := pP^.pUp;
  pA^.pBefore := pP;
  pP^.pUp     := pA;
  pP^.pAfter  := pY;
  if pY <> nil then pY^.pUp := pP;
  closureAvlRecomputeHeight(pP);
  closureAvlRecomputeHeight(pA);
  Result := pA;
end;

{ Return a pointer to the pBefore or pAfter pointer in the parent of p that
  points to p.  If p is the root node, return pp. }
function closureAvlFromPtr(p: PClosureAvl; pp: PPClosureAvl): PPClosureAvl;
var pUp: PClosureAvl;
begin
  pUp := p^.pUp;
  if pUp = nil then begin Result := pp; Exit; end;
  if pUp^.pAfter = p then Result := @pUp^.pAfter
                     else Result := @pUp^.pBefore;
end;

function closureAvlBalance(p: PClosureAvl): PClosureAvl;
var
  pTop: PClosureAvl;
  pp: PPClosureAvl;
  pB, pA: PClosureAvl;
begin
  pTop := p;
  while p <> nil do begin
    closureAvlRecomputeHeight(p);
    if p^.imbalance >= 2 then begin
      pB := p^.pBefore;
      if pB^.imbalance < 0 then p^.pBefore := closureAvlRotateAfter(pB);
      pp := closureAvlFromPtr(p, @p);
      p  := closureAvlRotateBefore(p);
      pp^ := p;
    end else if p^.imbalance <= (-2) then begin
      pA := p^.pAfter;
      if pA^.imbalance > 0 then p^.pAfter := closureAvlRotateBefore(pA);
      pp := closureAvlFromPtr(p, @p);
      p  := closureAvlRotateAfter(p);
      pp^ := p;
    end;
    pTop := p;
    p := p^.pUp;
  end;
  Result := pTop;
end;

function closureAvlSearch(p: PClosureAvl; id: i64): PClosureAvl;
begin
  while (p <> nil) and (id <> p^.id) do begin
    if id < p^.id then p := p^.pBefore
                  else p := p^.pAfter;
  end;
  Result := p;
end;

function closureAvlFirst(p: PClosureAvl): PClosureAvl;
begin
  if p <> nil then
    while p^.pBefore <> nil do p := p^.pBefore;
  Result := p;
end;

{ Return the node with the next larger key after p. }
function closureAvlNext(p: PClosureAvl): PClosureAvl;
var pPrev: PClosureAvl;
begin
  pPrev := nil;
  while (p <> nil) and (p^.pAfter = pPrev) do begin
    pPrev := p;
    p := p^.pUp;
  end;
  if (p <> nil) and (pPrev = nil) then
    p := closureAvlFirst(p^.pAfter);
  Result := p;
end;

{ Insert pNew.  Returns nil on success.  If the key is not unique, leave pNew
  unchanged and return a pointer to the existing node with the same key. }
function closureAvlInsert(ppHead: PPClosureAvl; pNew: PClosureAvl): PClosureAvl;
var p: PClosureAvl;
begin
  p := ppHead^;
  if p = nil then begin
    p := pNew;
    pNew^.pUp := nil;
  end else begin
    while p <> nil do begin
      if pNew^.id < p^.id then begin
        if p^.pBefore <> nil then
          p := p^.pBefore
        else begin
          p^.pBefore := pNew;
          pNew^.pUp  := p;
          break;
        end;
      end else if pNew^.id > p^.id then begin
        if p^.pAfter <> nil then
          p := p^.pAfter
        else begin
          p^.pAfter := pNew;
          pNew^.pUp := p;
          break;
        end;
      end else begin
        Result := p;
        Exit;
      end;
    end;
  end;
  pNew^.pBefore   := nil;
  pNew^.pAfter    := nil;
  pNew^.height    := 1;
  pNew^.imbalance := 0;
  ppHead^ := closureAvlBalance(p);
  Result := nil;
end;

procedure closureAvlDestroy(p: PClosureAvl; xDestroy: TClosureAvlDestroy);
begin
  if p <> nil then begin
    closureAvlDestroy(p^.pBefore, xDestroy);
    closureAvlDestroy(p^.pAfter,  xDestroy);
    xDestroy(p);
  end;
end;

{ ---------------------------------------------------------------------------
  Queue (closure.c:389..409)
  --------------------------------------------------------------------------- }

procedure queuePush(pQueue: PClosureQueue; pNode: PClosureAvl);
begin
  pNode^.pList := nil;
  if pQueue^.pLast <> nil then
    pQueue^.pLast^.pList := pNode
  else
    pQueue^.pFirst := pNode;
  pQueue^.pLast := pNode;
end;

function queuePull(pQueue: PClosureQueue): PClosureAvl;
var p: PClosureAvl;
begin
  p := pQueue^.pFirst;
  if p <> nil then begin
    pQueue^.pFirst := p^.pList;
    if pQueue^.pFirst = nil then pQueue^.pLast := nil;
  end;
  Result := p;
end;

{ ---------------------------------------------------------------------------
  Helpers (closure.c:424..494)
  --------------------------------------------------------------------------- }

{ Convert SQL quoted string into unquoted; allocate via sqlite3_malloc. }
function closureDequote(zIn: PAnsiChar): PAnsiChar;
var
  nIn: i64;
  zOut: PAnsiChar;
  q: AnsiChar;
  iIn, iOut: i32;
begin
  nIn := StrLen(zIn);
  zOut := PAnsiChar(sqlite3Malloc(i32(nIn + 1)));
  if zOut = nil then begin Result := nil; Exit; end;
  q := zIn[0];
  if (q <> '[') and (q <> '''') and (q <> '"') and (q <> '`') then begin
    Move(zIn^, zOut^, nIn + 1);
  end else begin
    if q = '[' then q := ']';
    iOut := 0;
    iIn := 1;
    while iIn < nIn do begin
      if zIn[iIn] = q then Inc(iIn);
      zOut[iOut] := zIn[iIn];
      Inc(iOut);
      Inc(iIn);
    end;
    zOut[iOut] := #0;
  end;
  Result := zOut;
end;

procedure closureFree(p: PClosureVtab);
begin
  if p <> nil then begin
    sqlite3_free(p^.zDb);
    sqlite3_free(p^.zSelf);
    sqlite3_free(p^.zTableName);
    sqlite3_free(p^.zIdColumn);
    sqlite3_free(p^.zParentColumn);
    FillChar(p^, SizeOf(p^), 0);
    sqlite3_free(p);
  end;
end;

function closureDisconnect(pVtab: PSqlite3Vtab): i32; cdecl;
begin
  closureFree(PClosureVtab(pVtab));
  Result := SQLITE_OK;
end;

{ Check for "KEY = VALUE".  Return ptr to first char of VALUE or nil. }
function closureValueOfKey(zKey, zStr: PAnsiChar): PAnsiChar;
var
  nKey, nStr, i: i32;
begin
  nKey := i32(StrLen(zKey));
  nStr := i32(StrLen(zStr));
  if nStr < nKey + 1 then begin Result := nil; Exit; end;
  if CompareByte(zStr^, zKey^, nKey) <> 0 then begin Result := nil; Exit; end;
  i := nKey;
  while (i < nStr) and (zStr[i] in [' ', #9, #10, #11, #12, #13]) do Inc(i);
  if (i >= nStr) or (zStr[i] <> '=') then begin Result := nil; Exit; end;
  Inc(i);
  while (i < nStr) and (zStr[i] in [' ', #9, #10, #11, #12, #13]) do Inc(i);
  Result := zStr + i;
end;

{ ---------------------------------------------------------------------------
  Module callbacks (closure.c:504..917)
  --------------------------------------------------------------------------- }

function closureConnect(db: PTsqlite3; pAux: Pointer;
  argc: i32; argv: PPAnsiChar; ppVtab: PPSqlite3Vtab;
  pzErr: PPAnsiChar): i32; cdecl;
label
  ErrorExit;
var
  rc: i32;
  pNew: PClosureVtab;
  pArgs: ^PAnsiChar;
  zDb, zVal, zArg: PAnsiChar;
  i: i32;
begin
  ppVtab^ := nil;
  pNew := PClosureVtab(sqlite3Malloc(SizeOf(TClosureVtab)));
  if pNew = nil then begin Result := SQLITE_NOMEM; Exit; end;
  rc := SQLITE_NOMEM;
  FillChar(pNew^, SizeOf(TClosureVtab), 0);
  pNew^.db := db;

  pArgs := argv;
  zDb := pArgs[1];
  pNew^.zDb := sqlite3PfMprintf('%s', [zDb]);
  if pNew^.zDb = nil then goto ErrorExit;
  pNew^.zSelf := sqlite3PfMprintf('%s', [pArgs[2]]);
  if pNew^.zSelf = nil then goto ErrorExit;

  i := 3;
  while i < argc do begin
    zArg := pArgs[i];
    zVal := closureValueOfKey('tablename', zArg);
    if zVal <> nil then begin
      sqlite3_free(pNew^.zTableName);
      pNew^.zTableName := closureDequote(zVal);
      if pNew^.zTableName = nil then goto ErrorExit;
      Inc(i);
      Continue;
    end;
    zVal := closureValueOfKey('idcolumn', zArg);
    if zVal <> nil then begin
      sqlite3_free(pNew^.zIdColumn);
      pNew^.zIdColumn := closureDequote(zVal);
      if pNew^.zIdColumn = nil then goto ErrorExit;
      Inc(i);
      Continue;
    end;
    zVal := closureValueOfKey('parentcolumn', zArg);
    if zVal <> nil then begin
      sqlite3_free(pNew^.zParentColumn);
      pNew^.zParentColumn := closureDequote(zVal);
      if pNew^.zParentColumn = nil then goto ErrorExit;
      Inc(i);
      Continue;
    end;
    pzErr^ := sqlite3PfMprintf('unrecognized argument: [%s]'#10, [zArg]);
    closureFree(pNew);
    ppVtab^ := nil;
    Result := SQLITE_ERROR;
    Exit;
  end;

  rc := sqlite3_declare_vtab(db,
    'CREATE TABLE x(id,depth,root HIDDEN,tablename HIDDEN,' +
    'idcolumn HIDDEN,parentcolumn HIDDEN)');
  if rc <> SQLITE_OK then begin
    closureFree(pNew);
    Result := rc;
    Exit;
  end;
  ppVtab^ := PSqlite3Vtab(pNew);
  Result := rc;
  Exit;

ErrorExit:
  closureFree(pNew);
  Result := rc;
end;

function closureOpen(pVtab: PSqlite3Vtab;
  ppCursor: PPSqlite3VtabCursor): i32; cdecl;
var
  p: PClosureVtab;
  pCur: PClosureCursor;
begin
  p := PClosureVtab(pVtab);
  pCur := PClosureCursor(sqlite3Malloc(SizeOf(TClosureCursor)));
  if pCur = nil then begin Result := SQLITE_NOMEM; Exit; end;
  FillChar(pCur^, SizeOf(TClosureCursor), 0);
  pCur^.pVtab := p;
  ppCursor^ := PSqlite3VtabCursor(@pCur^.base);
  Inc(p^.nCursor);
  Result := SQLITE_OK;
end;

procedure closureMemFree(p: PClosureAvl);
begin
  sqlite3_free(p);
end;

procedure closureClearCursor(pCur: PClosureCursor);
begin
  closureAvlDestroy(pCur^.pClosure, @closureMemFree);
  sqlite3_free(pCur^.zTableName);
  sqlite3_free(pCur^.zIdColumn);
  sqlite3_free(pCur^.zParentColumn);
  pCur^.zTableName    := nil;
  pCur^.zIdColumn     := nil;
  pCur^.zParentColumn := nil;
  pCur^.pCurrent  := nil;
  pCur^.pClosure  := nil;
end;

function closureClose(cur: PSqlite3VtabCursor): i32; cdecl;
var pCur: PClosureCursor;
begin
  pCur := PClosureCursor(cur);
  closureClearCursor(pCur);
  Dec(pCur^.pVtab^.nCursor);
  sqlite3_free(pCur);
  Result := SQLITE_OK;
end;

function closureNext(cur: PSqlite3VtabCursor): i32; cdecl;
var pCur: PClosureCursor;
begin
  pCur := PClosureCursor(cur);
  pCur^.pCurrent := closureAvlNext(pCur^.pCurrent);
  Result := SQLITE_OK;
end;

function closureInsertNode(pQueue: PClosureQueue; pCur: PClosureCursor;
  id: i64; iGeneration: i32): i32;
var pNew: PClosureAvl;
begin
  pNew := PClosureAvl(sqlite3Malloc(SizeOf(TClosureAvl)));
  if pNew = nil then begin Result := SQLITE_NOMEM; Exit; end;
  FillChar(pNew^, SizeOf(TClosureAvl), 0);
  pNew^.id := id;
  pNew^.iGeneration := iGeneration;
  closureAvlInsert(@pCur^.pClosure, pNew);
  queuePush(pQueue, pNew);
  Result := SQLITE_OK;
end;

function closureFilter(pVtabCursor: PSqlite3VtabCursor;
  idxNum: i32; idxStr: PAnsiChar;
  argc: i32; argv: PPsqlite3_value): i32; cdecl;
var
  pCur:   PClosureCursor;
  pVtab:  PClosureVtab;
  iRoot:  i64;
  mxGen:  i32;
  zSql:   PAnsiChar;
  pStmt:  Pointer;
  pAvl:   PClosureAvl;
  rc:     i32;
  zTableName, zIdColumn, zParentColumn: PAnsiChar;
  sQueue: TClosureQueue;
  pArgs:  PPsqlite3_value;
  iArg:   i32;
  iNew:   i64;
begin
  pCur  := PClosureCursor(pVtabCursor);
  pVtab := pCur^.pVtab;
  mxGen := 999999999;
  rc := SQLITE_OK;
  zTableName    := pVtab^.zTableName;
  zIdColumn     := pVtab^.zIdColumn;
  zParentColumn := pVtab^.zParentColumn;

  closureClearCursor(pCur);
  FillChar(sQueue, SizeOf(sQueue), 0);
  if (idxNum and 1) = 0 then begin
    { No root=$root in WHERE — return empty set. }
    Result := SQLITE_OK;
    Exit;
  end;
  pArgs := argv;
  iRoot := sqlite3_value_int64(pArgs[0]);
  if (idxNum and $0000F0) <> 0 then begin
    iArg := (idxNum shr 4) and $0F;
    mxGen := sqlite3_value_int(pArgs[iArg]);
    if (idxNum and $00002) <> 0 then Dec(mxGen);
  end;
  if (idxNum and $000F00) <> 0 then begin
    iArg := (idxNum shr 8) and $0F;
    zTableName := PAnsiChar(sqlite3_value_text(pArgs[iArg]));
    pCur^.zTableName := sqlite3PfMprintf('%s', [zTableName]);
  end;
  if (idxNum and $00F000) <> 0 then begin
    iArg := (idxNum shr 12) and $0F;
    zIdColumn := PAnsiChar(sqlite3_value_text(pArgs[iArg]));
    pCur^.zIdColumn := sqlite3PfMprintf('%s', [zIdColumn]);
  end;
  if (idxNum and $0F0000) <> 0 then begin
    iArg := (idxNum shr 16) and $0F;
    zParentColumn := PAnsiChar(sqlite3_value_text(pArgs[iArg]));
    pCur^.zParentColumn := sqlite3PfMprintf('%s', [zParentColumn]);
  end;

  zSql := sqlite3PfMprintf(
    'SELECT "%w"."%w" FROM "%w" WHERE "%w"."%w"=?1',
    [zTableName, zIdColumn, zTableName, zTableName, zParentColumn]);
  if zSql = nil then begin Result := SQLITE_NOMEM; Exit; end;
  pStmt := nil;
  rc := sqlite3_prepare_v2(pVtab^.db, zSql, -1, @pStmt, nil);
  sqlite3_free(zSql);
  if rc <> SQLITE_OK then begin
    sqlite3_free(pVtab^.base.zErrMsg);
    pVtab^.base.zErrMsg := sqlite3PfMprintf('%s', [sqlite3_errmsg(pVtab^.db)]);
    Result := rc;
    Exit;
  end;

  if rc = SQLITE_OK then
    rc := closureInsertNode(@sQueue, pCur, iRoot, 0);

  pAvl := queuePull(@sQueue);
  while pAvl <> nil do begin
    if pAvl^.iGeneration < mxGen then begin
      sqlite3_bind_int64(PVdbe(pStmt), 1, pAvl^.id);
      while (rc = SQLITE_OK) and (sqlite3_step(PVdbe(pStmt)) = SQLITE_ROW) do begin
        if sqlite3_column_type(PVdbe(pStmt), 0) = SQLITE_INTEGER then begin
          iNew := sqlite3_column_int64(PVdbe(pStmt), 0);
          if closureAvlSearch(pCur^.pClosure, iNew) = nil then
            rc := closureInsertNode(@sQueue, pCur, iNew, pAvl^.iGeneration + 1);
        end;
      end;
      sqlite3_reset(PVdbe(pStmt));
    end;
    pAvl := queuePull(@sQueue);
  end;
  sqlite3_finalize(PVdbe(pStmt));
  if rc = SQLITE_OK then
    pCur^.pCurrent := closureAvlFirst(pCur^.pClosure);
  Result := rc;
end;

function closureColumn(cur: PSqlite3VtabCursor;
  ctx: Psqlite3_context; i: i32): i32; cdecl;
var
  pCur: PClosureCursor;
  z: PAnsiChar;
begin
  pCur := PClosureCursor(cur);
  case i of
    CLOSURE_COL_ID:
      sqlite3_result_int64(ctx, pCur^.pCurrent^.id);
    CLOSURE_COL_DEPTH:
      sqlite3_result_int(ctx, pCur^.pCurrent^.iGeneration);
    CLOSURE_COL_ROOT:
      sqlite3_result_null(ctx);
    CLOSURE_COL_TABLENAME:
      begin
        if pCur^.zTableName <> nil then z := pCur^.zTableName
        else z := pCur^.pVtab^.zTableName;
        sqlite3_result_text(ctx, z, -1, SQLITE_TRANSIENT);
      end;
    CLOSURE_COL_IDCOLUMN:
      begin
        if pCur^.zIdColumn <> nil then z := pCur^.zIdColumn
        else z := pCur^.pVtab^.zIdColumn;
        sqlite3_result_text(ctx, z, -1, SQLITE_TRANSIENT);
      end;
    CLOSURE_COL_PARENTCOLUMN:
      begin
        if pCur^.zParentColumn <> nil then z := pCur^.zParentColumn
        else z := pCur^.pVtab^.zParentColumn;
        sqlite3_result_text(ctx, z, -1, SQLITE_TRANSIENT);
      end;
  end;
  Result := SQLITE_OK;
end;

function closureRowid(cur: PSqlite3VtabCursor; pRowid: Pi64): i32; cdecl;
var pCur: PClosureCursor;
begin
  pCur := PClosureCursor(cur);
  pRowid^ := pCur^.pCurrent^.id;
  Result := SQLITE_OK;
end;

function closureEof(cur: PSqlite3VtabCursor): i32; cdecl;
var pCur: PClosureCursor;
begin
  pCur := PClosureCursor(cur);
  if pCur^.pCurrent = nil then Result := 1 else Result := 0;
end;

{ closure.c:827..918 — bit-packed plan encoding.  See header comment for the
  format of idxNum (root flag, depth-LT bit, and four 4-bit argv-index slots). }
function closureBestIndex(pTab: PSqlite3Vtab;
  pIdxInfo: PSqlite3IndexInfo): i32; cdecl;
var
  iPlan, i, idx: i32;
  pConstraint: PSqlite3IndexConstraint;
  pUsage: PSqlite3IndexConstraintUsage;
  pVtab: PClosureVtab;
  rCost: Double;
begin
  iPlan := 0;
  idx := 1;
  pVtab := PClosureVtab(pTab);
  rCost := 10000000.0;

  pConstraint := pIdxInfo^.aConstraint;
  for i := 0 to pIdxInfo^.nConstraint - 1 do begin
    pUsage := @pIdxInfo^.aConstraintUsage[i];
    if pConstraint^.usable <> 0 then begin
      if ((iPlan and 1) = 0)
         and (pConstraint^.iColumn = CLOSURE_COL_ROOT)
         and (pConstraint^.op = SQLITE_INDEX_CONSTRAINT_EQ) then
      begin
        iPlan := iPlan or 1;
        pUsage^.argvIndex := 1;
        pUsage^.omit := 1;
        rCost := rCost / 100.0;
      end;
      if ((iPlan and $0000F0) = 0)
         and (pConstraint^.iColumn = CLOSURE_COL_DEPTH)
         and ((pConstraint^.op = SQLITE_INDEX_CONSTRAINT_LT)
              or (pConstraint^.op = SQLITE_INDEX_CONSTRAINT_LE)
              or (pConstraint^.op = SQLITE_INDEX_CONSTRAINT_EQ)) then
      begin
        iPlan := iPlan or (idx shl 4);
        Inc(idx);
        pUsage^.argvIndex := idx;
        if pConstraint^.op = SQLITE_INDEX_CONSTRAINT_LT then
          iPlan := iPlan or $000002;
        rCost := rCost / 5.0;
      end;
      if ((iPlan and $000F00) = 0)
         and (pConstraint^.iColumn = CLOSURE_COL_TABLENAME)
         and (pConstraint^.op = SQLITE_INDEX_CONSTRAINT_EQ) then
      begin
        iPlan := iPlan or (idx shl 8);
        Inc(idx);
        pUsage^.argvIndex := idx;
        pUsage^.omit := 1;
        rCost := rCost / 5.0;
      end;
      if ((iPlan and $00F000) = 0)
         and (pConstraint^.iColumn = CLOSURE_COL_IDCOLUMN)
         and (pConstraint^.op = SQLITE_INDEX_CONSTRAINT_EQ) then
      begin
        iPlan := iPlan or (idx shl 12);
        Inc(idx);
        pUsage^.argvIndex := idx;
        pUsage^.omit := 1;
      end;
      if ((iPlan and $0F0000) = 0)
         and (pConstraint^.iColumn = CLOSURE_COL_PARENTCOLUMN)
         and (pConstraint^.op = SQLITE_INDEX_CONSTRAINT_EQ) then
      begin
        iPlan := iPlan or (idx shl 16);
        Inc(idx);
        pUsage^.argvIndex := idx;
        pUsage^.omit := 1;
      end;
    end;
    Inc(pConstraint);
  end;
  if ((pVtab^.zTableName    = nil) and ((iPlan and $000F00) = 0))
   or ((pVtab^.zIdColumn     = nil) and ((iPlan and $00F000) = 0))
   or ((pVtab^.zParentColumn = nil) and ((iPlan and $0F0000) = 0)) then
  begin
    { All of tablename/idcolumn/parentcolumn must come from CREATE or WHERE. }
    iPlan := 0;
  end;
  if (iPlan and 1) = 0 then begin
    rCost := rCost * 1e30;
    for i := 0 to pIdxInfo^.nConstraint - 1 do
      pIdxInfo^.aConstraintUsage[i].argvIndex := 0;
    iPlan := 0;
  end;
  pIdxInfo^.idxNum := iPlan;
  if (pIdxInfo^.nOrderBy = 1)
   and (pIdxInfo^.aOrderBy[0].iColumn = CLOSURE_COL_ID)
   and (pIdxInfo^.aOrderBy[0].desc = 0) then
    pIdxInfo^.orderByConsumed := 1;
  pIdxInfo^.estimatedCost := rCost;
  Result := SQLITE_OK;
end;

function sqlite3ClosureInit(db: PTsqlite3): i32;
begin
  Result := sqlite3_create_module(db, 'transitive_closure',
    @closureModule, nil);
end;

initialization
  FillChar(closureModule, SizeOf(closureModule), 0);
  closureModule.iVersion    := 0;
  closureModule.xCreate     := @closureConnect;
  closureModule.xConnect    := @closureConnect;
  closureModule.xBestIndex  := @closureBestIndex;
  closureModule.xDisconnect := @closureDisconnect;
  closureModule.xDestroy    := @closureDisconnect;
  closureModule.xOpen       := @closureOpen;
  closureModule.xClose      := @closureClose;
  closureModule.xFilter     := @closureFilter;
  closureModule.xNext       := @closureNext;
  closureModule.xEof        := @closureEof;
  closureModule.xColumn     := @closureColumn;
  closureModule.xRowid      := @closureRowid;
end.
