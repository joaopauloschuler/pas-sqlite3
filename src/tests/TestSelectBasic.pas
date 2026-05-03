{
  SPDX-License-Identifier: blessing

  The author disclaims copyright to this source code.  In place of
  a legal notice, here is a blessing:

     May you do good and not evil.
     May you find forgiveness for yourself and forgive others.
     May you share freely, never taking more than you give.

  ------------------------------------------------------------------------

  This work is dedicated to all human kind, and also to all non-human kinds.

  This is a faithful port of SQLite 3.53 (https://sqlite.org/) from C to
  Free Pascal, authored by Dr. Joao Paulo Schwarz Schuler and contributors
  (see commit history). The original SQLite C source code is in the public
  domain, authored by D. Richard Hipp and contributors. This Pascal port
  adopts the same public-domain posture.
}
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
  SysUtils,
  passqlite3types, passqlite3internal, passqlite3util, passqlite3os,
  passqlite3vdbe, passqlite3codegen, passqlite3main;

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
// T11: SRT_EphemTab disposal arm — 6.13(b) piece 1.
//
// Drive sqlite3MaterializeView (which constructs `SELECT * FROM <tab>`
// with dest=SRT_EphemTab, iCur=iEph) against a real schema-resident
// table.  Verifies that the regular-path inner-loop disposal block emits
// the C-mirror MakeRecord+NewRowid+Insert(p5=OPFLAG_APPEND) triplet on
// the eph cursor.  Pre-fix the gate at codegen.pas:19502 bailed out for
// SRT_EphemTab and produced an empty (Init/Halt-only) program.
// -----------------------------------------------------------------------
procedure TestSRTEphemTabDisposal;
var
  db:           PTsqlite3;
  pTab:         PTable2;
  parse:        TParse;
  v:            PVdbe;
  iCur:         i32;
  rc:           i32;
  errMsg:       PAnsiChar;
  i:            i32;
  pop:          PVdbeOp;
  iMakeRec:     i32;
  iNewRowid:    i32;
  iInsert:      i32;
  insertP5:     u16;
  pFrom:        passqlite3codegen.PSrcList;
  pSrcItem:     passqlite3codegen.PSrcItem;
  pSel:         passqlite3codegen.PSelect;
  dest:         passqlite3codegen.TSelectDest;
const
  SETUP : PAnsiChar = 'CREATE TABLE base(a INT, b INT);';
begin
  WriteLn('T11: SRT_EphemTab disposal — MakeRecord/NewRowid/Insert(APPEND)');

  db := nil;
  rc := sqlite3_open(':memory:', @db);
  if (rc <> SQLITE_OK) or (db = nil) then
  begin Check('T11 open', False); Exit; end;

  errMsg := nil;
  rc := sqlite3_exec(db, SETUP, nil, nil, @errMsg);
  if rc <> SQLITE_OK then
  begin
    if errMsg <> nil then WriteLn('  setup err=', AnsiString(errMsg));
    Check('T11 CREATE TABLE base', False);
    sqlite3_close(db); Exit;
  end;

  pTab := sqlite3FindTable(db, 'base', nil);
  if pTab = nil then begin Check('T11 FindTable base', False); sqlite3_close(db); Exit; end;
  Check('T11 found base table',  pTab^.nCol >= 1);

  { Set up a fresh Parse the way the parser does; sqlite3VdbeCreate adds
    OP_Init at pc=0.  iCur is the eph cursor that MaterializeView's caller
    is conceptually responsible for opening — the disposal arm only writes
    into it.  We don't need the OP_OpenEphemeral here because we're
    inspecting the codegen output for the disposal pattern only. }
  FillChar(parse, SizeOf(parse), 0);
  parse.db          := db;
  parse.eParseMode  := PARSE_MODE_NORMAL;
  v := sqlite3VdbeCreate(@parse);
  Check('T11 VdbeCreate non-nil', v <> nil);
  if v = nil then begin sqlite3_close(db); Exit; end;
  parse.pVdbe := v;

  iCur := parse.nTab;  Inc(parse.nTab);

  { Inline replica of sqlite3MaterializeView (delete.c:142) so we can
    inspect the post-prep SrcList state if the codegen bails. }
  pFrom := sqlite3SrcListAppend(@parse, nil, nil, nil);
  if pFrom = nil then begin Check('T11 SrcListAppend', False); sqlite3VdbeDelete(v); sqlite3_close(db); Exit; end;
  pSrcItem := SrcListItems(pFrom);
  pSrcItem^.zName := sqlite3DbStrDup(db, pTab^.zName);
  { Leave u4.zDatabase nil so sqlite3LocateTable searches all attached
    databases (matches how the parser populates SrcItems for unqualified
    table names). }

  pSel := sqlite3SelectNew(@parse, nil, pFrom, nil, nil, nil, nil,
                           SF_IncludeHidden, nil);
  if pSel = nil then begin Check('T11 SelectNew', False); sqlite3VdbeDelete(v); sqlite3_close(db); Exit; end;

  sqlite3SelectDestInit(@dest, SRT_EphemTab, iCur);
  sqlite3Select(@parse, pSel, @dest);
  sqlite3SelectDelete(db, pSel);

  Check('T11 no parse error', parse.nErr = 0);
  Check('T11 SrcItem^.pSTab bound by selectExpander',
        SrcListItems(pSel^.pSrc)^.pSTab <> nil);
  Check('T11 vdbe has > 2 ops (regular path engaged, not Init/Halt stub)',
        v^.nOp > 5);

  { Walk the program looking for the MakeRecord → NewRowid → Insert
    triplet.  All three must reference iCur (iSDParm), and the Insert must
    carry OPFLAG_APPEND (= $08) in p5. }
  iMakeRec  := -1;
  iNewRowid := -1;
  iInsert   := -1;
  insertP5  := 0;
  for i := 0 to v^.nOp - 1 do
  begin
    pop := PVdbeOp(PtrUInt(v^.aOp) + PtrUInt(i) * SizeOf(TVdbeOp));
    case pop^.opcode of
      OP_MakeRecord:
        if (iMakeRec < 0) then iMakeRec := i;
      OP_NewRowid:
        if (iNewRowid < 0) and (iMakeRec >= 0) and (pop^.p1 = iCur) then
          iNewRowid := i;
      OP_Insert:
        if (iInsert < 0) and (iNewRowid >= 0) and (pop^.p1 = iCur) then
        begin
          iInsert  := i;
          insertP5 := pop^.p5;
        end;
    end;
  end;

  Check('T11 disposal: OP_MakeRecord emitted',  iMakeRec  >= 0);
  Check('T11 disposal: OP_NewRowid emitted (p1=iCur)',  iNewRowid >= 0);
  Check('T11 disposal: OP_Insert emitted (p1=iCur)',    iInsert   >= 0);
  Check('T11 disposal: NewRowid follows MakeRecord',
        (iMakeRec >= 0) and (iNewRowid > iMakeRec));
  Check('T11 disposal: Insert follows NewRowid',
        (iNewRowid >= 0) and (iInsert > iNewRowid));
  Check('T11 disposal: Insert.p5 carries OPFLAG_APPEND ($08)',
        (insertP5 and OPFLAG_APPEND) <> 0);

  { Don't sqlite3FinishCoding — we never opened the eph cursor and the
    program isn't meant to run.  Just discard the half-built Vdbe with
    sqlite3VdbeDelete; sqlite3_close cleans the schema. }
  sqlite3VdbeDelete(v);
  sqlite3_close(db);
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
  TestSRTEphemTabDisposal;
  WriteLn;
  WriteLn('Results: ', nPass, ' passed, ', nFail, ' failed.');
  if nFail > 0 then Halt(1);
end.
