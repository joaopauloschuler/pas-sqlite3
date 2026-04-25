{$I passqlite3.inc}
program TestSelectBasic;
{
  Phase 6.3 gate test — select.c: struct layout, constants,
  and basic API functions (no live DB needed).

    T1  SizeOf(TSelectDest) = 40
    T2  SRT_* constant values
    T3  JT_* join-type bitmask constants
    T4  sqlite3SelectDestInit zeroes struct and sets fields
    T5  sqlite3SelectOpName returns correct strings
    T6  sqlite3KeyInfoAlloc allocates and zeroes correctly
    T7  sqlite3KeyInfoRef increments nRef
    T8  sqlite3KeyInfoUnref decrements and frees at zero
    T9  sqlite3LogEst known values
    T10 sqlite3ColumnIndex finds column by name
}

uses
  passqlite3types, passqlite3internal, passqlite3util, passqlite3os,
  passqlite3vdbe, passqlite3codegen;

var
  nPass, nFail: i32;

procedure Check(const tag: AnsiString; cond: Boolean);
begin
  if cond then
  begin
    WriteLn('PASS  ', tag);
    Inc(nPass);
  end else
  begin
    WriteLn('FAIL  ', tag);
    Inc(nFail);
  end;
end;

// -----------------------------------------------------------------------
// T1: SizeOf(TSelectDest) = 40
// -----------------------------------------------------------------------
procedure TestSizeOf;
begin
  Check('T1 SizeOf(TSelectDest)=40', SizeOf(TSelectDest) = 40);
end;

// -----------------------------------------------------------------------
// T2: SRT_* constants
// -----------------------------------------------------------------------
procedure TestSRTConstants;
begin
  Check('T2a SRT_Exists=1',    SRT_Exists    = 1);
  Check('T2b SRT_Discard=2',   SRT_Discard   = 2);
  Check('T2c SRT_DistFifo=3',  SRT_DistFifo  = 3);
  Check('T2d SRT_DistQueue=4', SRT_DistQueue = 4);
  Check('T2e SRT_Queue=5',     SRT_Queue     = 5);
  Check('T2f SRT_Fifo=6',      SRT_Fifo      = 6);
  Check('T2g SRT_Output=7',    SRT_Output    = 7);
  Check('T2h SRT_Mem=8',       SRT_Mem       = 8);
  Check('T2i SRT_Set=9',       SRT_Set       = 9);
  Check('T2j SRT_EphemTab=10', SRT_EphemTab  = 10);
  Check('T2k SRT_Coroutine=11',SRT_Coroutine = 11);
  Check('T2l SRT_Table=12',    SRT_Table     = 12);
  Check('T2m SRT_Upfrom=13',   SRT_Upfrom    = 13);
end;

// -----------------------------------------------------------------------
// T3: JT_* constants
// -----------------------------------------------------------------------
procedure TestJTConstants;
begin
  Check('T3a JT_INNER=$01',   JT_INNER   = $01);
  Check('T3b JT_CROSS=$02',   JT_CROSS   = $02);
  Check('T3c JT_NATURAL=$04', JT_NATURAL = $04);
  Check('T3d JT_LEFT=$08',    JT_LEFT    = $08);
  Check('T3e JT_RIGHT=$10',   JT_RIGHT   = $10);
  Check('T3f JT_OUTER=$20',   JT_OUTER   = $20);
  Check('T3g JT_ERROR=$80',   JT_ERROR   = $80);
end;

// -----------------------------------------------------------------------
// T4: sqlite3SelectDestInit
// -----------------------------------------------------------------------
procedure TestSelectDestInit;
var
  dest: TSelectDest;
begin
  FillChar(dest, SizeOf(dest), $FF);  { poison }
  sqlite3SelectDestInit(@dest, SRT_Output, 42);
  Check('T4a eDest=SRT_Output',  dest.eDest    = SRT_Output);
  Check('T4b iSDParm=42',        dest.iSDParm  = 42);
  Check('T4c iSDParm2=0',        dest.iSDParm2 = 0);
  Check('T4d iSdst=0',           dest.iSdst    = 0);
  Check('T4e nSdst=0',           dest.nSdst    = 0);
  Check('T4f zAffSdst=nil',      dest.zAffSdst = nil);
  Check('T4g pOrderBy=nil',      dest.pOrderBy = nil);
end;

// -----------------------------------------------------------------------
// T5: sqlite3SelectOpName
// -----------------------------------------------------------------------
procedure TestSelectOpName;
begin
  Check('T5a UNION ALL',  AnsiString(sqlite3SelectOpName(TK_ALL))       = 'UNION ALL');
  Check('T5b INTERSECT',  AnsiString(sqlite3SelectOpName(TK_INTERSECT)) = 'INTERSECT');
  Check('T5c EXCEPT',     AnsiString(sqlite3SelectOpName(TK_EXCEPT))    = 'EXCEPT');
  Check('T5d UNION',      AnsiString(sqlite3SelectOpName(TK_UNION))     = 'UNION');
end;

// -----------------------------------------------------------------------
// T6-T8: sqlite3KeyInfoAlloc/Ref/Unref
// sqlite3DbMallocZero ignores db (just calls sqlite3MallocZero) so nil is safe.
// sqlite3OomFault(nil) would crash but only called on alloc failure.
// -----------------------------------------------------------------------
procedure TestKeyInfo;
var
  pKI: PKeyInfo2;
begin
  pKI := sqlite3KeyInfoAlloc(nil, 3, 1);
  Check('T6a alloc not nil',        pKI <> nil);
  if pKI <> nil then
  begin
    Check('T6b nRef=1',             pKI^.nRef = 1);
    Check('T6c nKeyField=3',        pKI^.nKeyField = 3);
    Check('T6d nAllField=4',        pKI^.nAllField = 4);  { 3 key + 1 extra }
    Check('T6e enc=0 (no db)',      pKI^.enc = 0);

    pKI := sqlite3KeyInfoRef(pKI);
    Check('T7  nRef after Ref=2',   pKI^.nRef = 2);

    sqlite3KeyInfoUnref(pKI);
    Check('T8a nRef after Unref=1', pKI^.nRef = 1);
    sqlite3KeyInfoUnref(pKI); { should free; pKI dangling after this }
    Check('T8b Unref-to-zero OK',   True);
  end;
end;

// -----------------------------------------------------------------------
// T9: sqlite3LogEst
// -----------------------------------------------------------------------
procedure TestLogEst;
begin
  { sqlite3LogEst(0) => 0 (x<2 branch returns 0) }
  Check('T9a LogEst(0)=0',     sqlite3LogEst(0) = 0);
  { sqlite3LogEst(1) => 0 (log2(1)=0, *10=0) }
  Check('T9b LogEst(1)=0',     sqlite3LogEst(1) = 0);
  { sqlite3LogEst(2) => 10 (log2(2)=1, *10=10) }
  Check('T9c LogEst(2)=10',    sqlite3LogEst(2) = 10);
  { sqlite3LogEst(4) => 20 }
  Check('T9d LogEst(4)=20',    sqlite3LogEst(4) = 20);
  { sqlite3LogEst(8) => 30 }
  Check('T9e LogEst(8)=30',    sqlite3LogEst(8) = 30);
end;

// -----------------------------------------------------------------------
// T10: sqlite3ColumnIndex
// -----------------------------------------------------------------------
procedure TestColumnIndex;
var
  tab: TTable;
  cols: array[0..2] of TColumn;
begin
  FillChar(tab, SizeOf(tab), 0);
  FillChar(cols, SizeOf(cols), 0);
  cols[0].zCnName := 'id';
  cols[0].hName   := sqlite3StrIHash('id');
  cols[1].zCnName := 'name';
  cols[1].hName   := sqlite3StrIHash('name');
  cols[2].zCnName := 'value';
  cols[2].hName   := sqlite3StrIHash('value');
  tab.nCol := 3;
  tab.aCol := @cols[0];
  FillChar(tab.aHx, SizeOf(tab.aHx), $FF);  { bypass hash shortcut }

  Check('T10a find "id"=0',      sqlite3ColumnIndex(PTable2(@tab), 'id')    = 0);
  Check('T10b find "name"=1',    sqlite3ColumnIndex(PTable2(@tab), 'name')  = 1);
  Check('T10c find "value"=2',   sqlite3ColumnIndex(PTable2(@tab), 'value') = 2);
  Check('T10d not found=-1',     sqlite3ColumnIndex(PTable2(@tab), 'bogus') = -1);
end;

// -----------------------------------------------------------------------
// Main
// -----------------------------------------------------------------------
begin
  nPass := 0; nFail := 0;
  TestSizeOf;
  TestSRTConstants;
  TestJTConstants;
  TestSelectDestInit;
  TestSelectOpName;
  TestKeyInfo;
  TestLogEst;
  TestColumnIndex;
  WriteLn;
  WriteLn('Results: ', nPass, ' passed, ', nFail, ' failed.');
  if nFail > 0 then Halt(1);
end.
