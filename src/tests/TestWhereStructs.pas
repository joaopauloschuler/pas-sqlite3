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
program TestWhereStructs;
{
  Phase 6.9-bis (step 11g.2.a) gate test — field-offset sentinel for the
  whereInt.h record skeletons in passqlite3codegen.pas.

  TestWhereBasic.pas already locks SizeOf() of every record.  This sentinel
  goes one level deeper: every documented field offset is checked, so any
  future drift (compiler change, accidental record-field reorder, missing
  pad, bitfield/union/flexarray miscount) trips a single PASS/FAIL line.

  All offsets verified against /home/bpsa/app/sqlite3/src/whereInt.h HEAD,
  GCC x86-64 layout (default packing), with SQLITE_DEBUG *off* in the
  Pascal port (Pascal does not own the C-side WhereTerm.iTerm).
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

procedure CheckOff(const name: string; got, want: PtrUInt);
begin
  if got = want then
  begin
    Inc(gPass);
    WriteLn('PASS  ', name);
  end else
  begin
    Inc(gFail);
    WriteLn('FAIL  ', name, '  got=', got, ' want=', want);
  end;
end;

{ FPC computes (PtrUInt(@rec.field) - PtrUInt(@rec)) at runtime. }
function OffOf(pField, pBase: Pointer): PtrUInt; inline;
begin
  Result := PtrUInt(pField) - PtrUInt(pBase);
end;

var
  mb: TWhereMemBlock;
  rj: TWhereRightJoin;
  il: TInLoop;
  wt: TWhereTerm;
  wc: TWhereClause;
  oi: TWhereOrInfo;
  ms: TWhereMaskSet;
  oc: TWhereOrCost;
  os: TWhereOrSet;
  wp: TWherePath;
  ws: TWhereScan;
  wlb: TWhereLoopBtree;
  wlv: TWhereLoopVtab;
  wl: TWhereLoop;
  lvl: TWhereLevel;
  bld: TWhereLoopBuilder;
  wi: TWhereInfo;

begin
  { --- TWhereMemBlock --- }
  CheckOff('WhereMemBlock.pNext@0', OffOf(@mb.pNext, @mb), 0);
  CheckOff('WhereMemBlock.sz@8',    OffOf(@mb.sz, @mb), 8);

  { --- TWhereRightJoin --- }
  CheckOff('WhereRightJoin.iMatch@0',     OffOf(@rj.iMatch, @rj),     0);
  CheckOff('WhereRightJoin.regBloom@4',   OffOf(@rj.regBloom, @rj),   4);
  CheckOff('WhereRightJoin.regReturn@8',  OffOf(@rj.regReturn, @rj),  8);
  CheckOff('WhereRightJoin.addrSubrtn@12',OffOf(@rj.addrSubrtn, @rj),12);
  CheckOff('WhereRightJoin.endSubrtn@16', OffOf(@rj.endSubrtn, @rj), 16);

  { --- TInLoop --- }
  CheckOff('InLoop.iCur@0',       OffOf(@il.iCur, @il),       0);
  CheckOff('InLoop.addrInTop@4',  OffOf(@il.addrInTop, @il),  4);
  CheckOff('InLoop.iBase@8',      OffOf(@il.iBase, @il),      8);
  CheckOff('InLoop.nPrefix@12',   OffOf(@il.nPrefix, @il),   12);
  CheckOff('InLoop.eEndLoopOp@16',OffOf(@il.eEndLoopOp, @il),16);

  { --- TWhereTerm --- }
  CheckOff('WhereTerm.pExpr@0',       OffOf(@wt.pExpr, @wt),       0);
  CheckOff('WhereTerm.pWC@8',         OffOf(@wt.pWC, @wt),         8);
  CheckOff('WhereTerm.truthProb@16',  OffOf(@wt.truthProb, @wt),  16);
  CheckOff('WhereTerm.wtFlags@18',    OffOf(@wt.wtFlags, @wt),    18);
  CheckOff('WhereTerm.eOperator@20',  OffOf(@wt.eOperator, @wt),  20);
  CheckOff('WhereTerm.nChild@22',     OffOf(@wt.nChild, @wt),     22);
  CheckOff('WhereTerm.eMatchOp@23',   OffOf(@wt.eMatchOp, @wt),   23);
  CheckOff('WhereTerm.iParent@24',    OffOf(@wt.iParent, @wt),    24);
  CheckOff('WhereTerm.leftCursor@28', OffOf(@wt.leftCursor, @wt), 28);
  CheckOff('WhereTerm.u@32',          OffOf(@wt.u, @wt),          32);
  CheckOff('WhereTerm.u.leftColumn@32', OffOf(@wt.u.leftColumn, @wt), 32);
  CheckOff('WhereTerm.u.iField@36',     OffOf(@wt.u.iField,     @wt), 36);
  CheckOff('WhereTerm.u.pOrInfo@32',    OffOf(@wt.u.pOrInfo,    @wt), 32);
  CheckOff('WhereTerm.u.pAndInfo@32',   OffOf(@wt.u.pAndInfo,   @wt), 32);
  CheckOff('WhereTerm.prereqRight@40',  OffOf(@wt.prereqRight,  @wt), 40);
  CheckOff('WhereTerm.prereqAll@48',    OffOf(@wt.prereqAll,    @wt), 48);

  { --- TWhereClause --- }
  CheckOff('WhereClause.pWInfo@0',  OffOf(@wc.pWInfo, @wc),  0);
  CheckOff('WhereClause.pOuter@8',  OffOf(@wc.pOuter, @wc),  8);
  CheckOff('WhereClause.op@16',     OffOf(@wc.op, @wc),     16);
  CheckOff('WhereClause.hasOr@17',  OffOf(@wc.hasOr, @wc),  17);
  CheckOff('WhereClause.nTerm@20',  OffOf(@wc.nTerm, @wc),  20);
  CheckOff('WhereClause.nSlot@24',  OffOf(@wc.nSlot, @wc),  24);
  CheckOff('WhereClause.nBase@28',  OffOf(@wc.nBase, @wc),  28);
  CheckOff('WhereClause.a@32',      OffOf(@wc.a, @wc),      32);
  CheckOff('WhereClause.aStatic@40',OffOf(@wc.aStatic[0], @wc), 40);

  { --- TWhereOrInfo: WhereClause inline + indexable Bitmask @ 488 --- }
  CheckOff('WhereOrInfo.wc@0',        OffOf(@oi.wc, @oi),         0);
  CheckOff('WhereOrInfo.indexable@488', OffOf(@oi.indexable, @oi), 488);

  { --- TWhereMaskSet --- }
  CheckOff('WhereMaskSet.bVarSelect@0', OffOf(@ms.bVarSelect, @ms), 0);
  CheckOff('WhereMaskSet.n@4',          OffOf(@ms.n, @ms),          4);
  CheckOff('WhereMaskSet.ix@8',         OffOf(@ms.ix[0], @ms),      8);

  { --- TWhereOrCost --- }
  CheckOff('WhereOrCost.prereq@0', OffOf(@oc.prereq, @oc), 0);
  CheckOff('WhereOrCost.rRun@8',   OffOf(@oc.rRun, @oc),   8);
  CheckOff('WhereOrCost.nOut@10',  OffOf(@oc.nOut, @oc),  10);

  { --- TWhereOrSet (n@0, then 6-byte pad, then a[3] @ 8) --- }
  CheckOff('WhereOrSet.n@0', OffOf(@os.n, @os),    0);
  CheckOff('WhereOrSet.a@8', OffOf(@os.a[0], @os), 8);

  { --- TWherePath --- }
  CheckOff('WherePath.maskLoop@0',  OffOf(@wp.maskLoop, @wp),  0);
  CheckOff('WherePath.revLoop@8',   OffOf(@wp.revLoop, @wp),   8);
  CheckOff('WherePath.nRow@16',     OffOf(@wp.nRow, @wp),     16);
  CheckOff('WherePath.rCost@18',    OffOf(@wp.rCost, @wp),    18);
  CheckOff('WherePath.rUnsort@20',  OffOf(@wp.rUnsort, @wp),  20);
  CheckOff('WherePath.isOrdered@22',OffOf(@wp.isOrdered, @wp),22);
  CheckOff('WherePath.aLoop@24',    OffOf(@wp.aLoop, @wp),    24);

  { --- TWhereScan --- }
  CheckOff('WhereScan.pOrigWC@0',   OffOf(@ws.pOrigWC, @ws),   0);
  CheckOff('WhereScan.pWC@8',       OffOf(@ws.pWC, @ws),       8);
  CheckOff('WhereScan.zCollName@16',OffOf(@ws.zCollName, @ws),16);
  CheckOff('WhereScan.pIdxExpr@24', OffOf(@ws.pIdxExpr, @ws), 24);
  CheckOff('WhereScan.k@32',        OffOf(@ws.k, @ws),        32);
  CheckOff('WhereScan.opMask@36',   OffOf(@ws.opMask, @ws),   36);
  CheckOff('WhereScan.idxaff@40',   OffOf(@ws.idxaff, @ws),   40);
  CheckOff('WhereScan.iEquiv@41',   OffOf(@ws.iEquiv, @ws),   41);
  CheckOff('WhereScan.nEquiv@42',   OffOf(@ws.nEquiv, @ws),   42);
  CheckOff('WhereScan.aiCur@44',    OffOf(@ws.aiCur[0], @ws), 44);
  CheckOff('WhereScan.aiColumn@88', OffOf(@ws.aiColumn[0], @ws), 88);

  { --- TWhereLoopBtree --- }
  CheckOff('WhereLoopBtree.nEq@0',          OffOf(@wlb.nEq, @wlb),          0);
  CheckOff('WhereLoopBtree.nBtm@2',         OffOf(@wlb.nBtm, @wlb),         2);
  CheckOff('WhereLoopBtree.nTop@4',         OffOf(@wlb.nTop, @wlb),         4);
  CheckOff('WhereLoopBtree.nDistinctCol@6', OffOf(@wlb.nDistinctCol, @wlb), 6);
  CheckOff('WhereLoopBtree.pIndex@8',       OffOf(@wlb.pIndex, @wlb),       8);
  CheckOff('WhereLoopBtree.pOrderBy@16',    OffOf(@wlb.pOrderBy, @wlb),    16);

  { --- TWhereLoopVtab (GCC packs 3 u32:1 bitfields into a single byte
        because the next field is i8 — verified empirically) --- }
  CheckOff('WhereLoopVtab.idxNum@0',     OffOf(@wlv.idxNum, @wlv),     0);
  CheckOff('WhereLoopVtab.bFlags@4',     OffOf(@wlv.bFlags, @wlv),     4);
  CheckOff('WhereLoopVtab.isOrdered@5',  OffOf(@wlv.isOrdered, @wlv),  5);
  CheckOff('WhereLoopVtab.omitMask@6',   OffOf(@wlv.omitMask, @wlv),   6);
  CheckOff('WhereLoopVtab.idxStr@8',     OffOf(@wlv.idxStr, @wlv),     8);
  CheckOff('WhereLoopVtab.mHandleIn@16', OffOf(@wlv.mHandleIn, @wlv), 16);

  { --- TWhereLoop --- }
  CheckOff('WhereLoop.prereq@0',   OffOf(@wl.prereq, @wl),    0);
  CheckOff('WhereLoop.maskSelf@8', OffOf(@wl.maskSelf, @wl),  8);
  CheckOff('WhereLoop.iTab@16',    OffOf(@wl.iTab, @wl),     16);
  CheckOff('WhereLoop.iSortIdx@17',OffOf(@wl.iSortIdx, @wl), 17);
  CheckOff('WhereLoop.rSetup@18',  OffOf(@wl.rSetup, @wl),   18);
  CheckOff('WhereLoop.rRun@20',    OffOf(@wl.rRun, @wl),     20);
  CheckOff('WhereLoop.nOut@22',    OffOf(@wl.nOut, @wl),     22);
  CheckOff('WhereLoop.u@24',       OffOf(@wl.u, @wl),        24);
  CheckOff('WhereLoop.wsFlags@48', OffOf(@wl.wsFlags, @wl),  48);
  CheckOff('WhereLoop.nLTerm@52',  OffOf(@wl.nLTerm, @wl),   52);
  CheckOff('WhereLoop.nSkip@54',   OffOf(@wl.nSkip, @wl),    54);
  CheckOff('WhereLoop.nLSlot@56',  OffOf(@wl.nLSlot, @wl),   56);
  CheckOff('WhereLoop.aLTerm@64',  OffOf(@wl.aLTerm, @wl),   64);
  CheckOff('WhereLoop.pNextLoop@72', OffOf(@wl.pNextLoop, @wl), 72);
  CheckOff('WhereLoop.aLTermSpace@80', OffOf(@wl.aLTermSpace[0], @wl), 80);

  { --- TWhereLevel --- }
  CheckOff('WhereLevel.iLeftJoin@0',  OffOf(@lvl.iLeftJoin, @lvl),   0);
  CheckOff('WhereLevel.iTabCur@4',    OffOf(@lvl.iTabCur, @lvl),     4);
  CheckOff('WhereLevel.iIdxCur@8',    OffOf(@lvl.iIdxCur, @lvl),     8);
  CheckOff('WhereLevel.addrBrk@12',   OffOf(@lvl.addrBrk, @lvl),    12);
  CheckOff('WhereLevel.addrHalt@16',  OffOf(@lvl.addrHalt, @lvl),   16);
  CheckOff('WhereLevel.addrNxt@20',   OffOf(@lvl.addrNxt, @lvl),    20);
  CheckOff('WhereLevel.addrSkip@24',  OffOf(@lvl.addrSkip, @lvl),   24);
  CheckOff('WhereLevel.addrCont@28',  OffOf(@lvl.addrCont, @lvl),   28);
  CheckOff('WhereLevel.addrFirst@32', OffOf(@lvl.addrFirst, @lvl),  32);
  CheckOff('WhereLevel.addrBody@36',  OffOf(@lvl.addrBody, @lvl),   36);
  CheckOff('WhereLevel.regBignull@40',OffOf(@lvl.regBignull, @lvl), 40);
  CheckOff('WhereLevel.addrBignull@44',OffOf(@lvl.addrBignull,@lvl),44);
  CheckOff('WhereLevel.iLikeRepCntr@48',OffOf(@lvl.iLikeRepCntr,@lvl),48);
  CheckOff('WhereLevel.addrLikeRep@52',OffOf(@lvl.addrLikeRep,@lvl),52);
  CheckOff('WhereLevel.regFilter@56', OffOf(@lvl.regFilter, @lvl),  56);
  CheckOff('WhereLevel.pRJ@64',       OffOf(@lvl.pRJ, @lvl),        64);
  CheckOff('WhereLevel.iFrom@72',     OffOf(@lvl.iFrom, @lvl),      72);
  CheckOff('WhereLevel.op@73',        OffOf(@lvl.op, @lvl),         73);
  CheckOff('WhereLevel.p3@74',        OffOf(@lvl.p3, @lvl),         74);
  CheckOff('WhereLevel.p5@75',        OffOf(@lvl.p5, @lvl),         75);
  CheckOff('WhereLevel.p1@76',        OffOf(@lvl.p1, @lvl),         76);
  CheckOff('WhereLevel.p2@80',        OffOf(@lvl.p2, @lvl),         80);
  CheckOff('WhereLevel.u@88',         OffOf(@lvl.u, @lvl),          88);
  CheckOff('WhereLevel.pWLoop@104',   OffOf(@lvl.pWLoop, @lvl),    104);
  CheckOff('WhereLevel.notReady@112', OffOf(@lvl.notReady, @lvl),  112);

  { --- TWhereLoopBuilder --- }
  CheckOff('WhereLoopBuilder.pWInfo@0',    OffOf(@bld.pWInfo, @bld),    0);
  CheckOff('WhereLoopBuilder.pWC@8',       OffOf(@bld.pWC, @bld),       8);
  CheckOff('WhereLoopBuilder.pNew@16',     OffOf(@bld.pNew, @bld),     16);
  CheckOff('WhereLoopBuilder.pOrSet@24',   OffOf(@bld.pOrSet, @bld),   24);
  CheckOff('WhereLoopBuilder.bldFlags1@32',OffOf(@bld.bldFlags1, @bld),32);
  CheckOff('WhereLoopBuilder.bldFlags2@33',OffOf(@bld.bldFlags2, @bld),33);
  CheckOff('WhereLoopBuilder.iPlanLimit@36',OffOf(@bld.iPlanLimit,@bld),36);

  { --- TWhereInfo --- }
  CheckOff('WhereInfo.pParse@0',         OffOf(@wi.pParse, @wi),          0);
  CheckOff('WhereInfo.pTabList@8',       OffOf(@wi.pTabList, @wi),        8);
  CheckOff('WhereInfo.pOrderBy@16',      OffOf(@wi.pOrderBy, @wi),       16);
  CheckOff('WhereInfo.pResultSet@24',    OffOf(@wi.pResultSet, @wi),     24);
  CheckOff('WhereInfo.pSelect@32',       OffOf(@wi.pSelect, @wi),        32);
  CheckOff('WhereInfo.aiCurOnePass@40',  OffOf(@wi.aiCurOnePass[0],@wi),40);
  CheckOff('WhereInfo.iContinue@48',     OffOf(@wi.iContinue, @wi),      48);
  CheckOff('WhereInfo.iBreak@52',        OffOf(@wi.iBreak, @wi),         52);
  CheckOff('WhereInfo.savedNQueryLoop@56',OffOf(@wi.savedNQueryLoop,@wi),56);
  CheckOff('WhereInfo.wctrlFlags@60',    OffOf(@wi.wctrlFlags, @wi),     60);
  CheckOff('WhereInfo.iLimit@62',        OffOf(@wi.iLimit, @wi),         62);
  CheckOff('WhereInfo.nLevel@64',        OffOf(@wi.nLevel, @wi),         64);
  CheckOff('WhereInfo.nOBSat@65',        OffOf(@wi.nOBSat, @wi),         65);
  CheckOff('WhereInfo.eOnePass@66',      OffOf(@wi.eOnePass, @wi),       66);
  CheckOff('WhereInfo.eDistinct@67',     OffOf(@wi.eDistinct, @wi),      67);
  CheckOff('WhereInfo.bitwiseFlags@68',  OffOf(@wi.bitwiseFlags, @wi),   68);
  CheckOff('WhereInfo.nRowOut@70',       OffOf(@wi.nRowOut, @wi),        70);
  CheckOff('WhereInfo.iTop@72',          OffOf(@wi.iTop, @wi),           72);
  CheckOff('WhereInfo.iEndWhere@76',     OffOf(@wi.iEndWhere, @wi),      76);
  CheckOff('WhereInfo.pLoops@80',        OffOf(@wi.pLoops, @wi),         80);
  CheckOff('WhereInfo.pMemToFree@88',    OffOf(@wi.pMemToFree, @wi),     88);
  CheckOff('WhereInfo.revMask@96',       OffOf(@wi.revMask, @wi),        96);
  CheckOff('WhereInfo.sWC@104',          OffOf(@wi.sWC, @wi),           104);
  CheckOff('WhereInfo.sMaskSet@592',     OffOf(@wi.sMaskSet, @wi),      592);

  WriteLn;
  WriteLn('Results: ', gPass, ' PASS, ', gFail, ' FAIL');
  if gFail > 0 then Halt(1);
end.
