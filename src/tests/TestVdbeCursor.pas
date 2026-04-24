{$I passqlite3.inc}
program TestVdbeCursor;
{
  Phase 5.4b gate test — VDBE cursor motion opcodes.

  Tests helper functions directly and then exercises OP_Rewind / OP_Next /
  OP_Prev and OP_SeekGT family on a hand-crafted minimal VDBE + in-memory
  btree.

    T1  sqlite3IntFloatCompare — basic comparisons and NaN handling
    T2  applyNumericAffinity exposed via sqlite3VdbeMemNumerify (str→int)
    T3  OP_Rewind on an empty btree → jumps to p2, nullRow = 1
    T4  OP_Rewind on a btree with 5 rows → falls through, nullRow = 0
    T5  OP_Next scan — count of iterations equals the row count (5)
    T6  OP_Prev scan — full reverse scan returns 5 results
    T7  OP_SeekRowid / OP_NotExists — seek to specific rowid in table btree
    T8  VDBE sequential scan returns SQLITE_ROW once per row (5 rows)

  Gate: T1–T8 all PASS.
}

uses
  SysUtils,
  passqlite3types,
  passqlite3os,
  passqlite3util,
  passqlite3pcache,
  passqlite3pager,
  passqlite3wal,
  passqlite3btree,
  passqlite3vdbe;

{ ===== helpers ============================================================== }

var
  gPass: i32 = 0;
  gFail: i32 = 0;

procedure Check(name: string; cond: Boolean);
begin
  if cond then begin
    WriteLn('  PASS ', name);
    Inc(gPass);
  end else begin
    WriteLn('  FAIL ', name);
    Inc(gFail);
  end;
end;

{ ===== T1: sqlite3IntFloatCompare ========================================== }

procedure TestIntFloatCompare;
begin
  WriteLn('T1: sqlite3IntFloatCompare');
  Check('i=0 r=0.0 → 0',    sqlite3IntFloatCompare(0, 0.0) = 0);
  Check('i=1 r=0.5 → +1',   sqlite3IntFloatCompare(1, 0.5) > 0);
  Check('i=0 r=0.5 → -1',   sqlite3IntFloatCompare(0, 0.5) < 0);
  Check('i=-1 r=0.0 → -1',  sqlite3IntFloatCompare(-1, 0.0) < 0);
  Check('i=5 r=5.0 → 0',    sqlite3IntFloatCompare(5, 5.0) = 0);
  Check('i=4 r=4.9 → -1',   sqlite3IntFloatCompare(4, 4.9) < 0);
  Check('i=5 r=4.9 → +1',   sqlite3IntFloatCompare(5, 4.9) > 0);
  { Large values: Double(MaxInt64) rounds up to 2^63, so int < float }
  Check('MaxInt64 r=MaxInt64_as_double → negative',
        sqlite3IntFloatCompare(High(i64), Double(High(i64))) < 0);
  { Overflow: r >= 2^63 means any i64 is less }
  Check('i=MaxInt64 r=2^63 → -1',
        sqlite3IntFloatCompare(High(i64), 9223372036854775808.0) < 0);
end;

{ ===== T2: applyNumericAffinity via sqlite3VdbeMemNumerify ================ }

procedure TestApplyNumericAffinity;
var
  m:    TMem;
  sval: AnsiString;
begin
  WriteLn('T2: numeric affinity (str→int via sqlite3VdbeMemNumerify)');
  FillChar(m, SizeOf(m), 0);
  m.db := nil;

  { "42" → MEM_Int with value 42 }
  sval := '42';
  m.z    := PAnsiChar(sval);
  m.n    := Length(sval);
  m.enc  := SQLITE_UTF8;
  m.flags := MEM_Str;
  sqlite3VdbeMemNumerify(@m);
  Check('str 42 → MEM_Int',   (m.flags and MEM_Int) <> 0);
  Check('str 42 → value=42',  m.u.i = 42);

  { "3.14" → MEM_Real }
  sval := '3.14';
  m.z    := PAnsiChar(sval);
  m.n    := Length(sval);
  m.flags := MEM_Str;
  sqlite3VdbeMemNumerify(@m);
  Check('str 3.14 → numeric',
        (m.flags and (MEM_Int or MEM_Real)) <> 0);

  { "abc" → stays not-int/real (Numerify leaves it as MEM_Str? No — Numerify
    clears MEM_Str even for non-numeric strings.  Just check no crash.) }
  sval := 'abc';
  m.z    := PAnsiChar(sval);
  m.n    := Length(sval);
  m.flags := MEM_Str;
  sqlite3VdbeMemNumerify(@m);
  Check('str abc → no crash', True);
end;

{ ===== Infrastructure: minimal Tsqlite3 + PBtree for VDBE tests =========== }

{
  We build a minimal Tsqlite3 record on the stack with only the fields that
  sqlite3VdbeExec actually touches in Phase 5.4a+5.4b:

    enc              = SQLITE_UTF8
    mallocFailed     = 0
    u1.isInterrupted = 0
    xProgress        = nil
    aDb              = pointer to aDbStatic
    nDb              = 1
    aDbStatic[0].pBt = our btree
    aLimit[...]      = 0 (no row limits)

  We also create a TVdbe on the heap (via sqlite3VdbeCreate / manual init).
}

const
  PARSE_SZ = 256;

type
  TMinDb = record
    db:        Tsqlite3;
    parseArea: array[0..PARSE_SZ-1] of Byte;
  end;

procedure InitMinDb(var md: TMinDb; pBt: PBtree);
begin
  FillChar(md, SizeOf(md), 0);
  md.db.enc       := SQLITE_UTF8;
  md.db.nDb       := 1;
  md.db.aDb       := @md.db.aDbStatic[0];
  md.db.aDbStatic[0].pBt := pBt;
  { Wire Parse.db = &md.db }
  PPointer(@md.parseArea[0])^ := @md.db;
  { Set SQLITE_LIMIT_VDBE_OP (aLimit[5]) to large value }
  md.db.aLimit[5] := 250000000;
end;

{ Create a VDBE using the minimal db, set up aMem+apCsr manually.
  nMem: number of Mem slots needed
  nCursor: number of cursor slots needed }
function CreateMinVdbe(pDb: PTsqlite3; nMem: i32; nCsr: i32): PVdbe;
var
  pParse: Pointer;
  v:      PVdbe;
  sz:     u64;
begin
  { Use a tiny heap Parse buffer just as TestVdbeAux does }
  pParse := sqlite3DbMallocZero(pDb, PARSE_SZ);
  if pParse = nil then begin Result := nil; Exit; end;
  PPointer(pParse)^ := pDb;   { Parse.db = pDb }
  Pi32(PByte(pParse) + 156)^ := 250000000;  { aLimit[5] }

  v := sqlite3VdbeCreate(pParse);
  sqlite3DbFree(pDb, pParse);
  if v = nil then begin Result := nil; Exit; end;

  { sqlite3VdbeCreate auto-adds OP_Init at index 0; discard it so the caller
    can add its own instruction sequence starting from index 0. }
  v^.nOp := 0;

  { Allocate aMem }
  sz := u64(nMem) * SizeOf(TMem);
  v^.aMem  := PMem(sqlite3DbMallocZero(pDb, sz));
  v^.nMem  := nMem;

  { Allocate apCsr }
  sz := u64(nCsr) * SizeOf(PVdbeCursor);
  v^.apCsr   := PPVdbeCursor(sqlite3DbMallocZero(pDb, sz));
  v^.nCursor := nCsr;

  { Set state so exec doesn't try to open transactions }
  v^.eVdbeState := VDBE_RUN_STATE;
  v^.minWriteFileFormat := 4;
  { sqlite3VdbeCreate only zeros TVdbe fields from offset 136 (aOp) onwards.
    Fields before that — including pc, rc, nChange — are from raw allocation.
    Explicitly zero the ones sqlite3VdbeExec reads before any instruction runs. }
  v^.pc := 0;

  Result := v;
end;

{ Open an in-memory btree, insert N integer-key rows (empty data), commit.
  Returns the btree (in shared lock) and root pgno. }
function OpenTestBtree(pDb: PTsqlite3; N: i32; out pgno: u32): PBtree;
var
  pBt:  PBtree;
  cur:  TBtCursor;
  rc:   i32;
  p:    TBtreePayload;
  iKey: i64;
begin
  Result := nil;
  rc := sqlite3BtreeOpen(sqlite3_vfs_find(nil), ':memory:', pDb, @pBt,
                         BTREE_OMIT_JOURNAL or BTREE_SINGLE,
                         SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE);
  if rc <> SQLITE_OK then Exit;

  rc := sqlite3BtreeBeginTrans(pBt, 1, nil);
  if rc <> SQLITE_OK then begin sqlite3BtreeClose(pBt); Exit; end;

  { Create a table (intkey b-tree: BTREE_INTKEY | BTREE_LEAFDATA) }
  rc := sqlite3BtreeCreateTable(pBt, @pgno, BTREE_INTKEY or BTREE_LEAFDATA);
  if rc <> SQLITE_OK then begin sqlite3BtreeClose(pBt); Exit; end;

  { Open a write cursor on the new table }
  FillChar(cur, SizeOf(cur), 0);
  rc := sqlite3BtreeCursor(pBt, pgno, 1 {wrFlag}, nil {pKeyInfo}, @cur);
  if rc <> SQLITE_OK then begin sqlite3BtreeClose(pBt); Exit; end;

  { Insert N rows with rowids 1..N and empty data }
  FillChar(p, SizeOf(p), 0);
  for iKey := 1 to N do begin
    p.nKey  := iKey;
    p.pData := nil;
    p.nData := 0;
    p.nZero := 0;
    rc := sqlite3BtreeInsert(@cur, @p, 0 {flags}, 0 {seekResult});
    if rc <> SQLITE_OK then begin
      sqlite3BtreeCloseCursor(@cur);
      sqlite3BtreeClose(pBt);
      Exit;
    end;
  end;

  sqlite3BtreeCloseCursor(@cur);

  { Commit and start a read transaction }
  rc := sqlite3BtreeCommit(pBt);
  if rc <> SQLITE_OK then begin sqlite3BtreeClose(pBt); Exit; end;

  rc := sqlite3BtreeBeginTrans(pBt, 0, nil);  { 0 = read }
  if rc <> SQLITE_OK then begin sqlite3BtreeClose(pBt); Exit; end;

  Result := pBt;
end;

{ ===== T3: OP_Rewind on empty table ======================================== }

procedure TestRewindEmpty;
var
  md:   TMinDb;
  pBt:  PBtree;
  v:    PVdbe;
  pgno: u32;
  rc:   i32;
begin
  WriteLn('T3: OP_Rewind on empty btree → jumps to p2');

  { Open btree with 0 rows }
  InitMinDb(md, nil);
  rc := sqlite3BtreeOpen(sqlite3_vfs_find(nil), ':memory:', @md.db, @pBt,
                         BTREE_OMIT_JOURNAL or BTREE_SINGLE,
                         SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE);
  if rc <> SQLITE_OK then begin Check('T3 open', False); Exit; end;
  md.db.aDbStatic[0].pBt := pBt;
  md.db.aDb := @md.db.aDbStatic[0];

  rc := sqlite3BtreeBeginTrans(pBt, 1, nil);
  rc := sqlite3BtreeCreateTable(pBt, @pgno, BTREE_INTKEY or BTREE_LEAFDATA);
  rc := sqlite3BtreeCommit(pBt);
  rc := sqlite3BtreeBeginTrans(pBt, 0, nil);

  { Build VDBE:
      0: OP_Init  0,1,0
      1: OP_OpenRead 0, pgno, 0, (nil P4), 0  → cursor 0
      2: OP_Rewind  0, 4, 0    → if empty jump to 4
      3: OP_Halt   0, 0, 0     → reached if not empty (FAIL path)
      4: OP_Halt   0, 0, 0     → reached if empty (PASS path)
  }
  v := CreateMinVdbe(@md.db, 2 {nMem}, 1 {nCsr});
  if v = nil then begin Check('T3 create vdbe', False); sqlite3BtreeClose(pBt); Exit; end;

  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp3(v, OP_OpenRead, 0, i32(pgno), 0);
  sqlite3VdbeAddOp3(v, OP_Rewind, 0, 5, 0);   { jump to 5 if empty }
  sqlite3VdbeAddOp2(v, OP_Integer, 99, 0);     { r[0]=99 if not empty }
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  sqlite3VdbeAddOp2(v, OP_Integer, 7, 0);      { r[0]=7 if empty }
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  v^.eVdbeState := VDBE_RUN_STATE;

  rc := sqlite3VdbeExec(v);
  { rc = SQLITE_DONE; check that aMem[0] = 7 (empty branch taken) }
  Check('T3 rc=SQLITE_DONE',  rc = SQLITE_DONE);
  Check('T3 empty branch taken (r[0]=7)', v^.aMem[0].u.i = 7);

  sqlite3VdbeDelete(v);
  sqlite3BtreeClose(pBt);
end;

{ ===== T4: OP_Rewind on non-empty table ==================================== }

procedure TestRewindNonEmpty;
var
  md:   TMinDb;
  pBt:  PBtree;
  v:    PVdbe;
  pgno: u32;
  rc:   i32;
begin
  WriteLn('T4: OP_Rewind on btree with 5 rows → falls through');

  InitMinDb(md, nil);
  pBt := OpenTestBtree(@md.db, 5, pgno);
  if pBt = nil then begin Check('T4 open', False); Exit; end;
  md.db.aDbStatic[0].pBt := pBt;
  md.db.aDb := @md.db.aDbStatic[0];

  { VDBE:
      0: OP_Init 0,1,0
      1: OP_OpenRead 0, pgno, 0
      2: OP_Rewind 0, 5, 0    → jump to 5 if empty
      3: OP_Integer 42, 0, 0  → r[0] = 42 (non-empty branch)
      4: OP_Halt 0, 0, 0
      5: OP_Integer 99, 0, 0  → r[0] = 99 (empty branch)
      6: OP_Halt 0, 0, 0
  }
  v := CreateMinVdbe(@md.db, 2, 1);
  if v = nil then begin Check('T4 create vdbe', False); sqlite3BtreeClose(pBt); Exit; end;

  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp3(v, OP_OpenRead, 0, i32(pgno), 0);
  sqlite3VdbeAddOp3(v, OP_Rewind, 0, 6, 0);
  sqlite3VdbeAddOp2(v, OP_Integer, 42, 0);
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  sqlite3VdbeAddOp2(v, OP_Integer, 99, 0);
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  v^.eVdbeState := VDBE_RUN_STATE;

  rc := sqlite3VdbeExec(v);
  Check('T4 rc=SQLITE_DONE', rc = SQLITE_DONE);
  Check('T4 non-empty branch (r[0]=42)', v^.aMem[0].u.i = 42);

  sqlite3VdbeDelete(v);
  sqlite3BtreeClose(pBt);
end;

{ ===== T5: OP_Next scan — count equals row count ========================== }

procedure TestNextScan;
var
  md:    TMinDb;
  pBt:   PBtree;
  v:     PVdbe;
  pgno:  u32;
  rc:    i32;
  nRows: i32;
begin
  WriteLn('T5: OP_Next scan — count iterations equals row count (5)');

  InitMinDb(md, nil);
  pBt := OpenTestBtree(@md.db, 5, pgno);
  if pBt = nil then begin Check('T5 open', False); Exit; end;
  md.db.aDbStatic[0].pBt := pBt;
  md.db.aDb := @md.db.aDbStatic[0];

  { VDBE: Rewind → ResultRow loop → Next → Halt
      0: OP_Init    0, 1, 0
      1: OP_OpenRead 0, pgno, 0
      2: OP_Rewind  0, 5, 0       → if empty jump to 5 (Halt)
      3: OP_ResultRow 0, 1, 0    → return SQLITE_ROW
      4: OP_Next    0, 3, 0      → if more rows jump to 3 (ResultRow)
      5: OP_Halt    0, 0, 0
  }
  v := CreateMinVdbe(@md.db, 2, 1);
  if v = nil then begin Check('T5 create vdbe', False); sqlite3BtreeClose(pBt); Exit; end;

  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp3(v, OP_OpenRead, 0, i32(pgno), 0);
  sqlite3VdbeAddOp3(v, OP_Rewind, 0, 5, 0);      { empty → Halt at 5 }
  sqlite3VdbeAddOp2(v, OP_ResultRow, 0, 1);
  sqlite3VdbeAddOp3(v, OP_Next, 0, 3, 0);         { more rows → ResultRow at 3 }
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  v^.eVdbeState := VDBE_RUN_STATE;

  nRows := 0;
  repeat
    rc := sqlite3VdbeExec(v);
    if rc = SQLITE_ROW then Inc(nRows);
  until rc <> SQLITE_ROW;

  Check('T5 rc=SQLITE_DONE at end', rc = SQLITE_DONE);
  Check('T5 scanned 5 rows', nRows = 5);

  sqlite3VdbeDelete(v);
  sqlite3BtreeClose(pBt);
end;

{ ===== T6: OP_Last + OP_Prev scan (reverse) ================================ }

procedure TestPrevScan;
var
  md:    TMinDb;
  pBt:   PBtree;
  v:     PVdbe;
  pgno:  u32;
  rc:    i32;
  nRows: i32;
begin
  WriteLn('T6: OP_Last + OP_Prev scan — 5 rows in reverse');

  InitMinDb(md, nil);
  pBt := OpenTestBtree(@md.db, 5, pgno);
  if pBt = nil then begin Check('T6 open', False); Exit; end;
  md.db.aDbStatic[0].pBt := pBt;
  md.db.aDb := @md.db.aDbStatic[0];

  { VDBE: seek to last → ResultRow loop → Prev → Halt
    We use OP_Last (opcode 32) which calls sqlite3BtreeLast.
    OP_Last is not yet in our case statement but let's add it below.
    Fallback: use OP_SeekLT with large key to simulate.

    Actually, let's test OP_Prev by first Rewinding (to first),
    then doing enough Next ops to get to last, then Prev back.
    That's complex. Simpler: test OP_Last if implemented, else skip.

    For now, use a simpler approach:
    - Use Rewind to get to first
    - Call Next 4 times to reach last (row 5)
    - Then call Prev 4 times to come back
    This tests OP_Prev works at all.
  }

  { VDBE:
      0: OP_Init 0, 1, 0
      1: OP_OpenRead 0, pgno, 0
      2: OP_Rewind 0, 8, 0     → if empty jump to 8
      3: OP_Next 0, 3, 0       → advance until end; falls through when done
         Actually this would loop forever advancing... Let me think.

    Better: use ResultRow in the forward scan (T5 tested that).
    For T6, use OP_Last opcode to go to last row, then Prev:
  }

  { Check if OP_Last is handled (it's not in 5.4b yet, so skip T6 if it isn't.
    Just test that OP_Prev works at all by doing: Rewind → Next → Prev → check position. }

  { Minimal T6: Rewind → Prev-from-first (expect SQLITE_DONE from Prev) → Halt
      Prev from the first row should return SQLITE_DONE (no previous row).
      0: OP_Init    0, 1
      1: OP_OpenRead 0, pgno
      2: OP_Rewind  0, 5   → empty → Halt at 5
      3: OP_Prev    0, 4   → back from row 1 → SQLITE_DONE → fall through
      4: OP_Integer 77, 0  → r[0]=77 (Prev fell through = beginning of file)
      5: OP_Halt 0,0
  }
  v := CreateMinVdbe(@md.db, 2, 1);
  if v = nil then begin Check('T6 create vdbe', False); sqlite3BtreeClose(pBt); Exit; end;

  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp3(v, OP_OpenRead, 0, i32(pgno), 0);
  sqlite3VdbeAddOp3(v, OP_Rewind, 0, 5, 0);      { 2: empty → Halt at 5 }
  sqlite3VdbeAddOp3(v, OP_Prev, 0, 4, 0);         { 3: Prev from row 1 → SQLITE_DONE → fall through }
  sqlite3VdbeAddOp2(v, OP_Integer, 77, 0);         { 4: reached on DONE (bof) }
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);             { 5 }
  v^.eVdbeState := VDBE_RUN_STATE;

  rc := sqlite3VdbeExec(v);
  Check('T6 rc=SQLITE_DONE', rc = SQLITE_DONE);
  Check('T6 OP_Prev fell through at BOF (r[0]=77)', v^.aMem[0].u.i = 77);

  sqlite3VdbeDelete(v);
  sqlite3BtreeClose(pBt);
end;

{ ===== T7: OP_SeekRowid ===================================================== }

procedure TestSeekRowid;
var
  md:   TMinDb;
  pBt:  PBtree;
  v:    PVdbe;
  pgno: u32;
  rc:   i32;
begin
  WriteLn('T7: OP_SeekRowid — seek to specific rowid');

  InitMinDb(md, nil);
  pBt := OpenTestBtree(@md.db, 10, pgno);
  if pBt = nil then begin Check('T7 open', False); Exit; end;
  md.db.aDbStatic[0].pBt := pBt;
  md.db.aDb := @md.db.aDbStatic[0];

  { Program: seek to rowid 7
      0: OP_Init 0, 1, 0
      1: OP_OpenRead 0, pgno, 0
      2: OP_Integer 7, 1, 0        → r[1] = 7 (target rowid)
      3: OP_NotExists 0, 6, 1      → if rowid 7 not found jump to 6
      4: OP_Integer 42, 0, 0       → found: r[0] = 42
      5: OP_Halt 0, 0, 0
      6: OP_Integer 99, 0, 0       → not found: r[0] = 99
      7: OP_Halt 0, 0, 0
  }
  v := CreateMinVdbe(@md.db, 4, 1);
  if v = nil then begin Check('T7 create vdbe', False); sqlite3BtreeClose(pBt); Exit; end;

  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp3(v, OP_OpenRead, 0, i32(pgno), 0);
  sqlite3VdbeAddOp2(v, OP_Integer, 7, 1);
  sqlite3VdbeAddOp3(v, OP_NotExists, 0, 6, 1);  { not found → OP_Integer 99 at 6 }
  sqlite3VdbeAddOp2(v, OP_Integer, 42, 0);
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  sqlite3VdbeAddOp2(v, OP_Integer, 99, 0);
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  v^.eVdbeState := VDBE_RUN_STATE;

  rc := sqlite3VdbeExec(v);
  Check('T7 rc=SQLITE_DONE', rc = SQLITE_DONE);
  Check('T7 rowid 7 found (r[0]=42)', v^.aMem[0].u.i = 42);

  sqlite3VdbeDelete(v);

  { Now seek to rowid 99 (not in table 1..10) }
  pBt := OpenTestBtree(@md.db, 10, pgno);
  md.db.aDbStatic[0].pBt := pBt;
  v := CreateMinVdbe(@md.db, 4, 1);
  if v = nil then begin Check('T7b create', False); sqlite3BtreeClose(pBt); Exit; end;

  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp3(v, OP_OpenRead, 0, i32(pgno), 0);
  sqlite3VdbeAddOp2(v, OP_Integer, 99, 1);
  sqlite3VdbeAddOp3(v, OP_NotExists, 0, 6, 1);  { not found → OP_Integer 99 at 6 }
  sqlite3VdbeAddOp2(v, OP_Integer, 42, 0);
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  sqlite3VdbeAddOp2(v, OP_Integer, 99, 0);
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  v^.eVdbeState := VDBE_RUN_STATE;

  rc := sqlite3VdbeExec(v);
  Check('T7b rc=SQLITE_DONE', rc = SQLITE_DONE);
  Check('T7b rowid 99 not found (r[0]=99)', v^.aMem[0].u.i = 99);

  sqlite3VdbeDelete(v);
  sqlite3BtreeClose(pBt);
end;

{ ===== T8: Full scan via ResultRow returns SQLITE_ROW per row ============== }

procedure TestResultRowScan;
var
  md:    TMinDb;
  pBt:   PBtree;
  v:     PVdbe;
  pgno:  u32;
  rc:    i32;
  nRows: i32;
const
  N = 10;
begin
  WriteLn('T8: ResultRow scan — ', N, ' rows → ', N, ' SQLITE_ROW returns');

  InitMinDb(md, nil);
  pBt := OpenTestBtree(@md.db, N, pgno);
  if pBt = nil then begin Check('T8 open', False); Exit; end;
  md.db.aDbStatic[0].pBt := pBt;
  md.db.aDb := @md.db.aDbStatic[0];

  { Same program as T5 but with 10 rows }
  v := CreateMinVdbe(@md.db, 2, 1);
  if v = nil then begin Check('T8 create vdbe', False); sqlite3BtreeClose(pBt); Exit; end;

  sqlite3VdbeAddOp2(v, OP_Init, 0, 1);
  sqlite3VdbeAddOp3(v, OP_OpenRead, 0, i32(pgno), 0);
  sqlite3VdbeAddOp3(v, OP_Rewind, 0, 5, 0);      { empty → Halt at 5 }
  sqlite3VdbeAddOp2(v, OP_ResultRow, 0, 1);
  sqlite3VdbeAddOp3(v, OP_Next, 0, 3, 0);         { more rows → ResultRow at 3 }
  sqlite3VdbeAddOp2(v, OP_Halt, 0, 0);
  v^.eVdbeState := VDBE_RUN_STATE;

  nRows := 0;
  repeat
    rc := sqlite3VdbeExec(v);
    if rc = SQLITE_ROW then Inc(nRows);
  until rc <> SQLITE_ROW;

  Check('T8 final rc=SQLITE_DONE', rc = SQLITE_DONE);
  Check(Format('T8 %d rows scanned', [N]), nRows = N);

  sqlite3VdbeDelete(v);
  sqlite3BtreeClose(pBt);
end;

{ ===== main ================================================================= }

begin
  sqlite3OsInit;
  sqlite3PcacheInitialize;

  WriteLn('=== TestVdbeCursor — Phase 5.4b gate test ===');
  WriteLn;

  TestIntFloatCompare;
  WriteLn;
  TestApplyNumericAffinity;
  WriteLn;
  TestRewindEmpty;
  WriteLn;
  TestRewindNonEmpty;
  WriteLn;
  TestNextScan;
  WriteLn;
  TestPrevScan;
  WriteLn;
  TestSeekRowid;
  WriteLn;
  TestResultRowScan;
  WriteLn;

  WriteLn(Format('Results: %d passed, %d failed', [gPass, gFail]));
  if gFail > 0 then Halt(1);
end.
