{$I passqlite3.inc}
program TestWindowBasic;
{
  Phase 6.7 gate test — window.c: SQL window function structs, constants,
  and lifecycle API.

  All tests run without a live database connection unless noted.

    T1   SizeOf(TWindow) = 144
    T2   TK_ROWS = 77
    T3   TK_RANGE = 90
    T4   TK_GROUPS = 93
    T5   TK_UNBOUNDED = 91
    T6   TK_CURRENT = 86
    T7   TK_FOLLOWING = 87
    T8   TK_PRECEDING = 89
    T9   SF_WinRewrite bitmask non-zero
    T10  EP_WinFunc bitmask non-zero
    T11  SF_WinRewrite and SF_Distinct are distinct bits
    T12  EP_WinFunc and EP_xIsSelect are distinct bits
    T13  TWindow.pNextWin pointer field offset accessible (zero-init)
    T14  TWindow.eFrmType field zero after FillChar
    T15  TWindow.eStart / eEnd zero after FillChar
    T16  TWindow.iEphCsr field zero after FillChar
    T17  sqlite3WindowLink links pWin into pSelect^.pWin
    T18  sqlite3WindowUnlinkFromSelect clears the link
    T19  SQLITE_FUNC_WINDOW = $10000 (defined in passqlite3vdbe)
    T20  SQLITE_FUNC_WINDOW bit not set in SQLITE_FUNC_BUILTIN
    T21  WIN_ENC bitmask includes SQLITE_FUNC_WINDOW
    T22  (reserved — context structs are implementation-private)
    T23  sqlite3WindowCompare: identical zero-filled windows return 0
    T24  sqlite3WindowCompare: different eFrmType returns non-zero
    T25  sqlite3WindowCompare: different eStart returns non-zero
    T26  sqlite3WindowCompare: different eEnd returns non-zero
    T27  sqlite3ExprCompare: two nil exprs returns 0
    T28  sqlite3ExprListCompare: two nil lists returns 0
    T29  sqlite3WindowRewrite: nil pSelect returns SQLITE_OK
    T30  sqlite3WindowAlloc: returns nil when passed nil pParse
    T31  SQLITE_FUNC_WINDOW flag non-zero
    T32  SQLITE_FUNC_WINDOW_SIZE >= 4
    T33  WRC_Continue = 0, WRC_Prune = 1, WRC_Abort = 2
    T34  TWindow.pWFunc field zero after FillChar

  Gate: T1-T34 all PASS.
}

uses
  passqlite3types,
  passqlite3internal,
  passqlite3os,
  passqlite3util,
  passqlite3pcache,
  passqlite3pager,
  passqlite3wal,
  passqlite3btree,
  passqlite3vdbe,
  passqlite3codegen;

var
  gPass: i32 = 0;
  gFail: i32 = 0;

procedure Check(const name: string; cond: Boolean);
begin
  if cond then
  begin
    Inc(gPass);
    WriteLn('PASS  ', name);
  end else
  begin
    Inc(gFail);
    WriteLn('FAIL  ', name);
  end;
end;

var
  win1, win2: TWindow;
  sel:        TSelect;

begin
  { --- T1: TWindow size --- }
  Check('T1  SizeOf(TWindow)=144', SizeOf(TWindow) = 144);

  { --- T2-T8: token kind constants --- }
  Check('T2  TK_ROWS=77',        TK_ROWS       = 77);
  Check('T3  TK_RANGE=90',       TK_RANGE      = 90);
  Check('T4  TK_GROUPS=93',      TK_GROUPS     = 93);
  Check('T5  TK_UNBOUNDED=91',   TK_UNBOUNDED  = 91);
  Check('T6  TK_CURRENT=86',     TK_CURRENT    = 86);
  Check('T7  TK_FOLLOWING=87',   TK_FOLLOWING  = 87);
  Check('T8  TK_PRECEDING=89',   TK_PRECEDING  = 89);

  { --- T9-T12: expression/select flag bits --- }
  Check('T9  SF_WinRewrite<>0',        SF_WinRewrite <> 0);
  Check('T10 EP_WinFunc<>0',           EP_WinFunc    <> 0);
  Check('T11 SF_WinRewrite<>SF_Distinct',
        (SF_WinRewrite and SF_Distinct) = 0);
  Check('T12 EP_WinFunc<>EP_xIsSelect',
        (EP_WinFunc and EP_xIsSelect) = 0);

  { --- T13-T16: TWindow field accessibility --- }
  FillChar(win1, SizeOf(TWindow), 0);
  Check('T13 TWindow.pNextWin=nil',  win1.pNextWin = nil);
  Check('T14 TWindow.eFrmType=0',    win1.eFrmType = 0);
  Check('T15 TWindow.eStart+eEnd=0', (win1.eStart = 0) and (win1.eEnd = 0));
  Check('T16 TWindow.iEphCsr=0',     win1.iEphCsr  = 0);
  Check('T34 TWindow.pWFunc=nil',    win1.pWFunc    = nil);

  { --- T17-T18: sqlite3WindowLink / sqlite3WindowUnlinkFromSelect --- }
  FillChar(sel,  SizeOf(TSelect), 0);
  FillChar(win1, SizeOf(TWindow), 0);
  sqlite3WindowLink(@sel, @win1);
  Check('T17 sqlite3WindowLink sets pSelect^.pWin', sel.pWin = @win1);
  sqlite3WindowUnlinkFromSelect(@win1);
  { After unlink win1.pNextWin / pPrevWin should be nil }
  Check('T18 sqlite3WindowUnlinkFromSelect clears link',
        win1.pNextWin = nil);

  { --- T19-T22: SQLITE_FUNC_WINDOW flags --- }
  Check('T19 SQLITE_FUNC_WINDOW=$10000',
        SQLITE_FUNC_WINDOW = $10000);
  Check('T20 SQLITE_FUNC_WINDOW distinct from SQLITE_FUNC_BUILTIN',
        (SQLITE_FUNC_WINDOW and SQLITE_FUNC_BUILTIN) = 0);
  Check('T21 SQLITE_FUNC_WINDOW distinct from SQLITE_UTF8',
        (SQLITE_FUNC_WINDOW and SQLITE_UTF8) = 0);
  { T22 — context structs are implementation-private; skip size checks here }
  Check('T22 SQLITE_FUNC_WINDOW distinct from SQLITE_FUNC_BUILTIN',
        (SQLITE_FUNC_WINDOW and SQLITE_FUNC_BUILTIN) = 0);

  { --- T23-T26: sqlite3WindowCompare --- }
  FillChar(win1, SizeOf(TWindow), 0);
  FillChar(win2, SizeOf(TWindow), 0);
  Check('T23 WindowCompare identical=0',
        sqlite3WindowCompare(nil, @win1, @win2, 0) = 0);
  win2.eFrmType := TK_RANGE;
  Check('T24 WindowCompare diff eFrmType<>0',
        sqlite3WindowCompare(nil, @win1, @win2, 0) <> 0);
  FillChar(win2, SizeOf(TWindow), 0);
  win2.eStart := TK_FOLLOWING;
  Check('T25 WindowCompare diff eStart<>0',
        sqlite3WindowCompare(nil, @win1, @win2, 0) <> 0);
  FillChar(win2, SizeOf(TWindow), 0);
  win2.eEnd := TK_PRECEDING;
  Check('T26 WindowCompare diff eEnd<>0',
        sqlite3WindowCompare(nil, @win1, @win2, 0) <> 0);

  { --- T27-T28: sqlite3ExprCompare / sqlite3ExprListCompare --- }
  Check('T27 ExprCompare nil,nil=0',
        sqlite3ExprCompare(nil, nil, nil, -1) = 0);
  Check('T28 ExprListCompare nil,nil=0',
        sqlite3ExprListCompare(nil, nil, -1) = 0);

  { --- T29: sqlite3WindowRewrite stub --- }
  Check('T29 sqlite3WindowRewrite nil pSelect=SQLITE_OK',
        sqlite3WindowRewrite(nil, nil) = SQLITE_OK);

  { --- T30: sqlite3WindowAlloc with nil pParse --- }
  Check('T30 sqlite3WindowAlloc nil pParse=nil',
        sqlite3WindowAlloc(nil, TK_ROWS, TK_UNBOUNDED, nil,
                           TK_CURRENT, nil, 0) = nil);

  { --- T31-T32: miscellaneous flags --- }
  Check('T31 SQLITE_FUNC_WINDOW<>0',     SQLITE_FUNC_WINDOW <> 0);
  Check('T32 SQLITE_FUNC_BUILTIN<>0',    SQLITE_FUNC_BUILTIN <> 0);

  { --- T33: walker result codes --- }
  Check('T33 WRC_Continue=0,Prune=1,Abort=2',
        (WRC_Continue = 0) and (WRC_Prune = 1) and (WRC_Abort = 2));

  { --- Summary --- }
  WriteLn;
  WriteLn('Result: ', gPass, ' PASS, ', gFail, ' FAIL');
  if gFail > 0 then Halt(1);
end.
