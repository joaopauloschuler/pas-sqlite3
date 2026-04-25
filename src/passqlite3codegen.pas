{$I passqlite3.inc}
unit passqlite3codegen;

{
  Phase 6 — SQL → VDBE code generator port for SQLite 3.53.0.

  This unit contains:
    walker.c  — AST walker framework (Phase 6.1)

  All struct sizes and field offsets verified against GCC x86-64 layout
  with -DSQLITE_DEBUG -DSQLITE_ENABLE_EXPLAIN_COMMENTS -DSQLITE_THREADSAFE=1.

  IMPORTANT (FPC rules): All forward-referenced record types MUST be declared
  in the same `type` block.  Multiple `type` blocks are used only for constants
  or helper function declarations that do not forward-reference record types.
}

interface

uses
  passqlite3types, passqlite3internal, passqlite3util, passqlite3os,
  passqlite3vdbe;

// ---------------------------------------------------------------------------
// Bitmask (u64 — column-usage mask in FROM clause items)
// ---------------------------------------------------------------------------

type
  Bitmask = u64;

// ---------------------------------------------------------------------------
// Constants from sqliteInt.h needed by Phase 6
// ---------------------------------------------------------------------------

const
  WRC_Continue = 0;
  WRC_Prune    = 1;
  WRC_Abort    = 2;

  EP_OuterON   = u32($000001);
  EP_InnerON   = u32($000002);
  EP_Distinct  = u32($000004);
  EP_HasFunc   = u32($000008);
  EP_Agg       = u32($000010);
  EP_FixedCol  = u32($000020);
  EP_VarSelect = u32($000040);
  EP_DblQuoted = u32($000080);
  EP_InfixFunc = u32($000100);
  EP_Collate   = u32($000200);
  EP_Commuted  = u32($000400);
  EP_IntValue  = u32($000800);
  EP_xIsSelect = u32($001000);
  EP_Skip      = u32($002000);
  EP_Reduced   = u32($004000);
  EP_Win       = u32($008000);
  EP_TokenOnly = u32($010000);
  EP_FullSize  = u32($020000);
  EP_IfNullRow = u32($040000);
  EP_Unlikely  = u32($080000);
  EP_ConstFunc = u32($100000);
  EP_CanBeNull = u32($200000);
  EP_Subquery  = u32($400000);
  EP_Leaf      = u32($800000);
  EP_WinFunc   = u32($1000000);
  EP_Subrtn    = u32($2000000);
  EP_Quoted    = u32($4000000);
  EP_Static    = u32($8000000);
  EP_IsTrue    = u32($10000000);
  EP_IsFalse   = u32($20000000);
  EP_FromDDL   = u32($40000000);
  EP_SubtArg   = u32($80000000);
  EP_Propagate : u32 = EP_Collate or EP_Subquery or EP_HasFunc;

  KEYINFO_ORDER_DESC    = 1;
  KEYINFO_ORDER_BIGNULL = 2;

  ENAME_NAME  = 0;
  ENAME_SPAN  = 1;
  ENAME_TAB   = 2;
  ENAME_ROWID = 3;

  SF_Distinct      = u32($0000001);
  SF_All           = u32($0000002);
  SF_Resolved      = u32($0000004);
  SF_Aggregate     = u32($0000008);
  SF_HasAgg        = u32($0000010);
  SF_ClonedRhsIn   = u32($0000020);
  SF_Expanded      = u32($0000040);
  SF_HasTypeInfo   = u32($0000080);
  SF_Compound      = u32($0000100);
  SF_Values        = u32($0000200);
  SF_MultiValue    = u32($0000400);
  SF_NestedFrom    = u32($0000800);
  SF_MinMaxAgg     = u32($0001000);
  SF_Recursive     = u32($0002000);
  SF_FixedLimit    = u32($0004000);
  SF_Converted     = u32($0010000);
  SF_IncludeHidden = u32($0020000);
  SF_ComplexResult = u32($0040000);
  SF_WhereBegin    = u32($0080000);
  SF_WinRewrite    = u32($0100000);
  SF_View          = u32($0200000);
  SF_UFSrcCheck    = u32($0800000);
  SF_PushDown      = u32($1000000);
  SF_MultiPart     = u32($2000000);
  SF_CopyCte       = u32($4000000);
  SF_OrderByReqd   = u32($8000000);
  SF_UpdateFrom    = u32($10000000);
  SF_Correlated    = u32($20000000);
  SF_OnToWhere     = u32($40000000);

  NC_AllowAgg  = i32($000001);
  NC_PartIdx   = i32($000002);
  NC_IsCheck   = i32($000004);
  NC_GenCol    = i32($000008);
  NC_HasAgg    = i32($000010);
  NC_IdxExpr   = i32($000020);
  NC_SelfRef   = i32($00002E);
  NC_Subquery  = i32($000040);
  NC_UEList    = i32($000080);
  NC_UAggInfo  = i32($000100);
  NC_UUpsert   = i32($000200);
  NC_UBaseReg  = i32($000400);
  NC_MinMaxAgg = i32($001000);
  NC_AllowWin  = i32($004000);
  NC_HasWin    = i32($008000);
  NC_IsDDL     = i32($010000);
  NC_InAggFunc = i32($020000);
  NC_FromDDL   = i32($040000);
  NC_NoSelect  = i32($080000);
  NC_Where     = i32($100000);
  NC_OrderAgg  = i32($8000000);

  PARSE_MODE_NORMAL       = 0;
  PARSE_MODE_DECLARE_VTAB = 1;
  PARSE_MODE_RENAME       = 2;
  PARSE_MODE_UNMAP        = 3;

  PARSE_EPARSE_MODE_OFFSET = 300;  { byte offset of Parse.eParseMode }

  SRCITEM_FG_NOT_INDEXED     = u8($01);
  SRCITEM_FG_IS_INDEXED_BY   = u8($02);
  SRCITEM_FG_IS_SUBQUERY     = u8($04);
  SRCITEM_FG_IS_TABFUNC      = u8($08);
  SRCITEM_FG_IS_CORRELATED   = u8($10);
  SRCITEM_FG_IS_MATERIALIZED = u8($20);
  SRCITEM_FG_VIA_COROUTINE   = u8($40);
  SRCITEM_FG_IS_RECURSIVE    = u8($80);

// ---------------------------------------------------------------------------
// All Phase 6 record types in ONE type block (FPC requirement for forward refs)
//
// Verified sizes (C debug build x86-64):
//   TToken=16  TExpr=72  TExprListItem=24  TExprList=8
//   TSelect=120  TSubquery=24  TSrcItem=72  TSrcList=8
//   TWindow=144  TWalker=48  TNameContext=56  TAggInfo=72
//   TUpsert=88  TOnOrUsing=16
// ---------------------------------------------------------------------------

type
  { --- forward pointers --- }
  PExpr        = ^TExpr;
  PPExpr       = ^PExpr;
  PExprList    = ^TExprList;
  PSelect      = ^TSelect;
  PWindow      = ^TWindow;
  PPWindow     = ^PWindow;
  PAggInfo     = ^TAggInfo;
  PAggInfoCol  = ^TAggInfoCol;
  PAggInfoFunc = ^TAggInfoFunc;
  PSrcItem     = ^TSrcItem;
  PSrcList     = ^TSrcList;
  PSubquery    = ^TSubquery;
  PNameContext = ^TNameContext;
  PUpsert      = ^TUpsert;
  PWalker      = ^TWalker;
  PDbFixer     = ^TDbFixer;
  PToken       = ^TToken;
  PWith        = ^TWith;
  PExprListItem = ^TExprListItem;

  { Opaque stubs deferred to later phases }
  PTable2   = Pointer;   { Table  — Phase 6.5 }
  PIndex2   = Pointer;   { Index  — Phase 6.5 }
  PFuncDef2 = Pointer;   { FuncDef — Phase 6.6 }
  PIdList   = Pointer;   { IdList — Phase 6.4 }
  PCteUse   = Pointer;   { CteUse — Phase 6.5 }

  { --- TToken (sizeof=16) --- }
  TToken = record
    z:    PAnsiChar;
    n:    u32;
    _pad: u32;
  end;

  { --- TAggInfoCol, TAggInfoFunc, TAggInfo (sizeof=72) --- }
  TAggInfoCol = record
    pTab:          PTable2;
    pCExpr:        PExpr;
    iTable:        i32;
    iColumn:       i32;
    iSorterColumn: i32;
    _pad:          i32;
  end;

  TAggInfoFunc = record
    pFExpr:      PExpr;
    pFunc:       PFuncDef2;
    iDistinct:   i32;
    iDistAddr:   i32;
    iOBTab:      i32;
    bOBPayload:  u8;
    bOBUnique:   u8;
    bUseSubtype: u8;
    _pad:        u8;
    _pad2:       i32;
  end;

  TAggInfo = record
    directMode:     u8;
    useSortingIdx:  u8;
    _pad:           u16;
    nSortingColumn: u32;
    sortingIdx:     i32;
    sortingIdxPTab: i32;
    iFirstReg:      i32;
    _pad2:          i32;
    pGroupBy:       PExprList;
    aCol:           PAggInfoCol;
    nColumn:        i32;
    nAccumulator:   i32;
    aFunc:          PAggInfoFunc;
    nFunc:          i32;
    selId:          u32;
    pSelectDbg:     PSelect;     { SQLITE_DEBUG only — at offset 64 }
  end;

  { --- TExpr (sizeof=72) --- }
  TExprU = record
    case Integer of
      0: (zToken: PAnsiChar);
      1: (iValue: i32; _pad: u32);
  end;

  TExprX = record
    case Integer of
      0: (pList:   PExprList);
      1: (pSelect: PSelect);
  end;

  TExprYSub = record
    iAddr:     i32;
    regReturn: i32;
  end;

  TExprY = record
    case Integer of
      0: (pTab: PTable2);
      1: (pWin: PWindow);
      2: (nReg: i32; _pad: u32);
      3: (sub:  TExprYSub);
  end;

  TExprW = record
    case Integer of
      0: (iJoin: i32);
      1: (iOfst: i32);
  end;

  TExpr = record
    op:       u8;
    affExpr:  AnsiChar;
    op2:      u8;
    vvaFlags: u8;          { SQLITE_DEBUG verification flags }
    flags:    u32;
    u:        TExprU;
    pLeft:    PExpr;
    pRight:   PExpr;
    x:        TExprX;
    nHeight:  i32;
    iTable:   i32;
    iColumn:  i16;
    iAgg:     i16;
    w:        TExprW;
    pAggInfo: PAggInfo;
    y:        TExprY;
  end;

  { --- TExprListItem (sizeof=24), TExprList (sizeof=8) --- }
  TExprListItemFg = record
    sortFlags: u8;
    eBits:     u8;   { eEName(1:0), done(2), reusable(3), bSorterRef(4),
                       bNulls(5), bUsed(6), bUsingTerm(7) }
    eBits2:    u8;   { bNoExpand(0) }
    _pad:      u8;
  end;

  TExprListItemUX = record
    iOrderByCol: u16;
    iAlias:      u16;
  end;

  TExprListItemU = record
    case Integer of
      0: (x:             TExprListItemUX);
      1: (iConstExprReg: i32);
  end;

  TExprListItem = record
    pExpr:  PExpr;
    zEName: PAnsiChar;
    fg:     TExprListItemFg;
    u:      TExprListItemU;
  end;

  TExprList = record
    nExpr:  i32;
    nAlloc: i32;
    { a[FLEXARRAY] follows }
  end;

  { --- TSelect (sizeof=120) --- }
  TSelect = record
    op:         u8;
    _pad0:      u8;
    nSelectRow: i16;
    selFlags:   u32;
    iLimit:     i32;
    iOffset:    i32;
    selId:      u32;
    _pad1:      u32;
    pEList:     PExprList;
    pSrc:       PSrcList;
    pWhere:     PExpr;
    pGroupBy:   PExprList;
    pHaving:    PExpr;
    pOrderBy:   PExprList;
    pPrior:     PSelect;
    pNext:      PSelect;
    pLimit:     PExpr;
    pWith:      PWith;
    pWin:       PWindow;
    pWinDefn:   PWindow;
  end;

  { --- TSubquery (sizeof=24) --- }
  TSubquery = record
    pSelect:     PSelect;
    addrFillSub: i32;
    regReturn:   i32;
    regResult:   i32;
    _pad:        i32;
  end;

  { --- TSrcItemFg (4 bytes; bit layout verified) --- }
  TSrcItemFg = record
    jointype: u8;
    fgBits:   u8;   { notIndexed(0)..isRecursive(7) }
    fgBits2:  u8;   { fromDDL(0)..rowidUsed(7) }
    fgBits3:  u8;   { fixedSchema(0), hadSchema(1), fromExists(2) }
  end;

  { --- TSrcItem (sizeof=72) --- }
  TSrcItemU1 = record
    case Integer of
      0: (zIndexedBy: PAnsiChar);
      1: (pFuncArg:   PExprList);
      2: (nRow:       u32; _pad: u32);
  end;

  TSrcItemU2 = record
    case Integer of
      0: (pIBIndex: PIndex2);
      1: (pCteUse:  PCteUse);
  end;

  TSrcItemU3 = record
    case Integer of
      0: (pOn:    PExpr);
      1: (pUsing: PIdList);
  end;

  TSrcItemU4 = record
    case Integer of
      0: (pSchema:   PSchema);
      1: (zDatabase: PAnsiChar);
      2: (pSubq:     PSubquery);
  end;

  TSrcItem = record
    zName:   PAnsiChar;
    zAlias:  PAnsiChar;
    pSTab:   PTable2;
    fg:      TSrcItemFg;
    iCursor: i32;
    colUsed: Bitmask;
    u1:      TSrcItemU1;
    u2:      TSrcItemU2;
    u3:      TSrcItemU3;
    u4:      TSrcItemU4;
  end;

  { --- TSrcList (sizeof=8; a[FLEXARRAY] follows) --- }
  TSrcList = record
    nSrc:   i32;
    nAlloc: u32;
  end;

  { --- TOnOrUsing (sizeof=16) --- }
  TOnOrUsing = record
    pOn:    PExpr;
    pUsing: PIdList;
  end;

  { --- TWindow (sizeof=144; all offsets verified) --- }
  TWindow = record
    zName:          PAnsiChar;
    zBase:          PAnsiChar;
    pPartition:     PExprList;
    pOrderBy:       PExprList;
    eFrmType:       u8;
    eStart:         u8;
    eEnd:           u8;
    bImplicitFrame: u8;
    eExclude:       u8;
    _pad0:          u8;
    _pad1:          u16;      { total 3 bytes pad → aligns pStart to offset 40 }
    pStart:         PExpr;
    pEnd:           PExpr;
    ppThis:         PPWindow;
    pNextWin:       PWindow;
    pFilter:        PExpr;
    pWFunc:         PFuncDef2;
    iEphCsr:        i32;
    regAccum:       i32;
    regResult:      i32;
    csrApp:         i32;
    regApp:         i32;
    regPart:        i32;
    pOwner:         PExpr;    { offset 112 }
    nBufferCol:     i32;
    iArgCol:        i32;
    regOne:         i32;
    regStartRowid:  i32;
    regEndRowid:    i32;
    bExprArgs:      u8;
    _pad2:          u8;
    _pad3:          u16;      { pad to 144 bytes total (8-byte aligned) }
  end;

  { --- TNameContext (sizeof=56) --- }
  TNameContextUNC = record
    case Integer of
      0: (pEList:   PExprList);
      1: (pAggInfo: PAggInfo);
      2: (pUpsert:  PUpsert);
      3: (iBaseReg: i32; _pad: u32);
  end;

  TNameContext = record
    pParse:        PParse;
    pSrcList:      PSrcList;
    uNC:           TNameContextUNC;
    pNext:         PNameContext;
    nRef:          i32;
    nNcErr:        i32;
    ncFlags:       i32;
    nNestedSelect: u32;      { offset 44 — immediately follows ncFlags }
    pWinSelect:    PSelect;  { offset 48 }
  end;

  { --- TUpsert (sizeof=88; key offsets: pNextUpsert@32, isDoUpdate@40,
                 pToFree@48) --- }
  TUpsert = record
    pUpsertTarget:      PExprList;
    pUpsertTargetWhere: PExpr;
    pUpsertSet:         PExprList;
    pUpsertWhere:       PExpr;
    pNextUpsert:        PUpsert;    { offset 32 }
    isDoUpdate:         u8;         { offset 40 }
    isDup:              u8;
    _pad0:              u16;
    _pad1:              u32;
    pToFree:            Pointer;    { offset 48 }
    pUpsertIdx:         Pointer;    { offset 56 }
    pUpsertCols:        PIdList;    { offset 64 }
    regData:            i32;
    iDataCur:           i32;
    iIdxCur:            i32;
    _pad2:              i32;
  end;

  { --- TWalker (sizeof=48) --- }
  TExprCallback    = function(pWalker: PWalker; pExpr: PExpr): i32; cdecl;
  TSelectCallback  = function(pWalker: PWalker; pSel: PSelect): i32; cdecl;
  TSelectCallback2 = procedure(pWalker: PWalker; pSel: PSelect); cdecl;

  TWalkerU = record
    case Integer of
      0: (ptr:      Pointer);
      1: (n:        i32; _n_pad:  i32);
      2: (iCur:     i32; _ic_pad: i32);
      3: (sz:       i32; _sz_pad: i32);
      4: (pNC:      PNameContext);
      5: (pSrcList: PSrcList);
      6: (pGroupBy: PExprList);
      7: (pSelect:  PSelect);
  end;

  TWalker = record
    pParse:           PParse;
    xExprCallback:    TExprCallback;
    xSelectCallback:  TSelectCallback;
    xSelectCallback2: TSelectCallback2;
    walkerDepth:      i32;
    eCode:            u16;
    mWFlags:          u16;
    u:                TWalkerU;
  end;

  { --- TDbFixer (partial stub) --- }
  TDbFixer = record
    pParse: PParse;
    w:      TWalker;
    _rest:  array[0..47] of u8;
  end;

  { --- TWith (opaque stub — full in Phase 6.5) --- }
  TWith = record
    nCte: i32;
    _rest: array[0..63] of u8;
  end;

// ---------------------------------------------------------------------------
// Flexible-array accessor helpers (outside type block)
// ---------------------------------------------------------------------------

function ExprListItems(p: PExprList): PExprListItem; inline;
function SrcListItems(p: PSrcList): PSrcItem; inline;

// ---------------------------------------------------------------------------
// Phase 6.1 public API — walker.c
// ---------------------------------------------------------------------------

function  sqlite3WalkExprNN(pWalker: PWalker; pExpr: PExpr): i32;
function  sqlite3WalkExpr(pWalker: PWalker; pExpr: PExpr): i32;
function  sqlite3WalkExprList(pWalker: PWalker; p: PExprList): i32;
procedure sqlite3WalkWinDefnDummyCallback(pWalker: PWalker; p: PSelect); cdecl;
function  sqlite3WalkSelectExpr(pWalker: PWalker; p: PSelect): i32;
function  sqlite3WalkSelectFrom(pWalker: PWalker; p: PSelect): i32;
function  sqlite3WalkSelect(pWalker: PWalker; p: PSelect): i32;
function  sqlite3WalkerDepthIncrease(pWalker: PWalker; pSel: PSelect): i32; cdecl;
procedure sqlite3WalkerDepthDecrease(pWalker: PWalker; pSel: PSelect); cdecl;
function  sqlite3ExprWalkNoop(pWalker: PWalker; pExpr: PExpr): i32; cdecl;
function  sqlite3SelectWalkNoop(pWalker: PWalker; pSel: PSelect): i32; cdecl;
procedure sqlite3SelectPopWith(pWalker: PWalker; pSel: PSelect); cdecl;

// ---------------------------------------------------------------------------
// Inline helpers (macro equivalents)
// ---------------------------------------------------------------------------

function ExprHasProperty(pExpr: PExpr; prop: u32): Boolean; inline;
function ExprHasAllProperty(pExpr: PExpr; prop: u32): Boolean; inline;
function ExprUseXSelect(pExpr: PExpr): Boolean; inline;
function ExprUseXList(pExpr: PExpr): Boolean; inline;
function ParseGetEParseMode(pParse: Pointer): u8; inline;
function SrcItemIsSubquery(const fg: TSrcItemFg): Boolean; inline;
function SrcItemIsTabFunc(const fg: TSrcItemFg): Boolean; inline;

implementation

function ExprListItems(p: PExprList): PExprListItem; inline;
begin
  Result := PExprListItem(PByte(p) + SizeOf(TExprList));
end;

function SrcListItems(p: PSrcList): PSrcItem; inline;
begin
  Result := PSrcItem(PByte(p) + SizeOf(TSrcList));
end;

function ExprHasProperty(pExpr: PExpr; prop: u32): Boolean; inline;
begin
  Result := (pExpr^.flags and prop) <> 0;
end;

function ExprHasAllProperty(pExpr: PExpr; prop: u32): Boolean; inline;
begin
  Result := (pExpr^.flags and prop) = prop;
end;

function ExprUseXSelect(pExpr: PExpr): Boolean; inline;
begin
  Result := (pExpr^.flags and EP_xIsSelect) <> 0;
end;

function ExprUseXList(pExpr: PExpr): Boolean; inline;
begin
  Result := (pExpr^.flags and EP_xIsSelect) = 0;
end;

function ParseGetEParseMode(pParse: Pointer): u8; inline;
begin
  if pParse = nil then
    Result := 0
  else
    Result := Pu8(pParse)[PARSE_EPARSE_MODE_OFFSET];
end;

function SrcItemIsSubquery(const fg: TSrcItemFg): Boolean; inline;
begin
  Result := (fg.fgBits and SRCITEM_FG_IS_SUBQUERY) <> 0;
end;

function SrcItemIsTabFunc(const fg: TSrcItemFg): Boolean; inline;
begin
  Result := (fg.fgBits and SRCITEM_FG_IS_TABFUNC) <> 0;
end;

// ---------------------------------------------------------------------------
// Phase 6.1 — walker.c port (SQLite 3.53.0)
// ---------------------------------------------------------------------------

function walkWindowList(pWalker: PWalker; pList: PWindow;
                        bOneOnly: Boolean): i32;
var
  pWin: PWindow;
  rc: i32;
begin
  pWin := pList;
  while pWin <> nil do
  begin
    rc := sqlite3WalkExprList(pWalker, pWin^.pOrderBy);
    if rc <> WRC_Continue then begin Result := WRC_Abort; Exit; end;
    rc := sqlite3WalkExprList(pWalker, pWin^.pPartition);
    if rc <> WRC_Continue then begin Result := WRC_Abort; Exit; end;
    rc := sqlite3WalkExpr(pWalker, pWin^.pFilter);
    if rc <> WRC_Continue then begin Result := WRC_Abort; Exit; end;
    rc := sqlite3WalkExpr(pWalker, pWin^.pStart);
    if rc <> WRC_Continue then begin Result := WRC_Abort; Exit; end;
    rc := sqlite3WalkExpr(pWalker, pWin^.pEnd);
    if rc <> WRC_Continue then begin Result := WRC_Abort; Exit; end;
    if bOneOnly then Break;
    pWin := pWin^.pNextWin;
  end;
  Result := WRC_Continue;
end;

function sqlite3WalkExprNN(pWalker: PWalker; pExpr: PExpr): i32;
var
  rc: i32;
begin
  while True do
  begin
    rc := pWalker^.xExprCallback(pWalker, pExpr);
    if rc <> 0 then begin Result := rc and WRC_Abort; Exit; end;

    if not ExprHasProperty(pExpr, EP_TokenOnly or EP_Leaf) then
    begin
      if (pExpr^.pLeft <> nil) and
         (sqlite3WalkExprNN(pWalker, pExpr^.pLeft) = WRC_Abort) then
      begin Result := WRC_Abort; Exit; end;

      if pExpr^.pRight <> nil then
      begin
        pExpr := pExpr^.pRight;
        Continue;
      end
      else if ExprUseXSelect(pExpr) then
      begin
        if sqlite3WalkSelect(pWalker, pExpr^.x.pSelect) = WRC_Abort then
        begin Result := WRC_Abort; Exit; end;
      end
      else
      begin
        if (pExpr^.x.pList <> nil) and
           (sqlite3WalkExprList(pWalker, pExpr^.x.pList) = WRC_Abort) then
        begin Result := WRC_Abort; Exit; end;

        if ExprHasProperty(pExpr, EP_WinFunc) then
        begin
          if walkWindowList(pWalker, pExpr^.y.pWin, True) = WRC_Abort then
          begin Result := WRC_Abort; Exit; end;
        end;
      end;
    end;
    Break;
  end;
  Result := WRC_Continue;
end;

function sqlite3WalkExpr(pWalker: PWalker; pExpr: PExpr): i32;
begin
  if pExpr <> nil then
    Result := sqlite3WalkExprNN(pWalker, pExpr)
  else
    Result := WRC_Continue;
end;

function sqlite3WalkExprList(pWalker: PWalker; p: PExprList): i32;
var
  i: i32;
  pItem: PExprListItem;
begin
  if p <> nil then
  begin
    i := p^.nExpr;
    pItem := ExprListItems(p);
    while i > 0 do
    begin
      if sqlite3WalkExpr(pWalker, pItem^.pExpr) = WRC_Abort then
      begin Result := WRC_Abort; Exit; end;
      Inc(pItem);
      Dec(i);
    end;
  end;
  Result := WRC_Continue;
end;

procedure sqlite3WalkWinDefnDummyCallback(pWalker: PWalker; p: PSelect); cdecl;
begin
end;

function sqlite3WalkSelectExpr(pWalker: PWalker; p: PSelect): i32;
var
  pParse: Pointer;
begin
  if sqlite3WalkExprList(pWalker, p^.pEList)   = WRC_Abort then begin Result := WRC_Abort; Exit; end;
  if sqlite3WalkExpr    (pWalker, p^.pWhere)   = WRC_Abort then begin Result := WRC_Abort; Exit; end;
  if sqlite3WalkExprList(pWalker, p^.pGroupBy) = WRC_Abort then begin Result := WRC_Abort; Exit; end;
  if sqlite3WalkExpr    (pWalker, p^.pHaving)  = WRC_Abort then begin Result := WRC_Abort; Exit; end;
  if sqlite3WalkExprList(pWalker, p^.pOrderBy) = WRC_Abort then begin Result := WRC_Abort; Exit; end;
  if sqlite3WalkExpr    (pWalker, p^.pLimit)   = WRC_Abort then begin Result := WRC_Abort; Exit; end;

  if p^.pWinDefn <> nil then
  begin
    pParse := pWalker^.pParse;
    if (Pointer(pWalker^.xSelectCallback2) = Pointer(@sqlite3WalkWinDefnDummyCallback))
       or ((pParse <> nil) and (ParseGetEParseMode(pParse) >= PARSE_MODE_RENAME))
       or (Pointer(pWalker^.xSelectCallback2) = Pointer(@sqlite3SelectPopWith))
    then
    begin
      if walkWindowList(pWalker, p^.pWinDefn, False) = WRC_Abort then
      begin Result := WRC_Abort; Exit; end;
    end;
  end;

  Result := WRC_Continue;
end;

function sqlite3WalkSelectFrom(pWalker: PWalker; p: PSelect): i32;
var
  pSrc: PSrcList;
  i: i32;
  pItem: PSrcItem;
begin
  pSrc := p^.pSrc;
  if pSrc <> nil then
  begin
    i := pSrc^.nSrc;
    pItem := SrcListItems(pSrc);
    while i > 0 do
    begin
      if SrcItemIsSubquery(pItem^.fg) then
      begin
        if sqlite3WalkSelect(pWalker, pItem^.u4.pSubq^.pSelect) = WRC_Abort then
        begin Result := WRC_Abort; Exit; end;
      end;
      if SrcItemIsTabFunc(pItem^.fg) then
      begin
        if sqlite3WalkExprList(pWalker, pItem^.u1.pFuncArg) = WRC_Abort then
        begin Result := WRC_Abort; Exit; end;
      end;
      Inc(pItem);
      Dec(i);
    end;
  end;
  Result := WRC_Continue;
end;

function sqlite3WalkSelect(pWalker: PWalker; p: PSelect): i32;
var
  rc: i32;
begin
  if p = nil then begin Result := WRC_Continue; Exit; end;
  if not Assigned(pWalker^.xSelectCallback) then begin Result := WRC_Continue; Exit; end;

  repeat
    rc := pWalker^.xSelectCallback(pWalker, p);
    if rc <> 0 then begin Result := rc and WRC_Abort; Exit; end;

    if sqlite3WalkSelectExpr(pWalker, p) = WRC_Abort then begin Result := WRC_Abort; Exit; end;
    if sqlite3WalkSelectFrom(pWalker, p) = WRC_Abort then begin Result := WRC_Abort; Exit; end;

    if Assigned(pWalker^.xSelectCallback2) then
      pWalker^.xSelectCallback2(pWalker, p);

    p := p^.pPrior;
  until p = nil;

  Result := WRC_Continue;
end;

function sqlite3WalkerDepthIncrease(pWalker: PWalker; pSel: PSelect): i32; cdecl;
begin
  Inc(pWalker^.walkerDepth);
  Result := WRC_Continue;
end;

procedure sqlite3WalkerDepthDecrease(pWalker: PWalker; pSel: PSelect); cdecl;
begin
  Dec(pWalker^.walkerDepth);
end;

function sqlite3ExprWalkNoop(pWalker: PWalker; pExpr: PExpr): i32; cdecl;
begin
  Result := WRC_Continue;
end;

function sqlite3SelectWalkNoop(pWalker: PWalker; pSel: PSelect): i32; cdecl;
begin
  Result := WRC_Continue;
end;

procedure sqlite3SelectPopWith(pWalker: PWalker; pSel: PSelect); cdecl;
begin
  { Phase 6.3 stub }
end;

end.
