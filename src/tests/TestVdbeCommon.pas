{
  SPDX-License-Identifier: blessing

  This work is dedicated to all human kind, and also to all non-human kinds.

  Faithful port of SQLite 3 (https://sqlite.org/) from C to Free Pascal.
}
{$I ../passqlite3.inc}
{
  TestVdbeCommon — shared VDBE micro-harness for the TestVdbe* probes.

  jscpd flagged a large clone cluster across the TestVdbe* family:
  every probe re-declared the same scaffold verbatim (~70-80L per
  pair) before running a few opcode-level tests:

    * gPass/gFail counters + Check(name, cond) PASS/FAIL writer.
    * const PARSE_SZ = 256.
    * TMinDb record (Tsqlite3 + parseArea byte-buffer).
    * InitMinDb(var md[, pBt]) — zero the record then set enc=UTF8 and
      aLimit slots 0/5; the pBt-aware variant additionally wires nDb,
      aDb and aDbStatic[0].pBt.
    * CreateMinVdbe(pDb, nMem) — allocate a Parse stub, call
      sqlite3VdbeCreate, then allocate aMem and pin eVdbeState +
      cacheCtr so VdbeExec can run.  Two flavours: RUN_STATE
      (Misc/Arith/Txn/Agg/Str) and READY_STATE (Api).
    * OpenEmptyBtree(pDb) — used by TestVdbeTxn for read/write
      OP_Transaction probes.

  Hoisted here verbatim so stdout stays byte-identical.  The pBt=nil
  arm of VdbeInitMinDb matches the no-pBt InitMinDb in
  Misc/Arith/Api/Agg/Str exactly: FillChar zeroes nDb and aDb, then
  enc + aLimit are written.  When pBt<>nil we additionally set nDb,
  aDb, aDbStatic[0].pBt — matching the TestVdbeTxn variant.

  TestVdbeRecord has a slightly different InitMinDb (writes the db
  pointer into parseArea, then CreateMinVdbe overwrites that slot
  with a fresh malloc) and CreateMinVdbe (allocates apCsr too).
  Keeping that probe on its own scaffold for now — the parseArea
  pre-write is a dead store but diverges textually and is out of
  scope for this dedup pass.

  Per-file Check identifiers are renamed `VdbeCheck`, counters
  `gVdbePass`/`gVdbeFail`, to avoid colliding with any local symbol.
}
unit TestVdbeCommon;

interface

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

const
  { Size of the parse-stub byte buffer.  256 covers every offset that
    sqlite3VdbeCreate + the limit-write at offset 156 touches. }
  PARSE_SZ = 256;

type
  TVdbeMinDb = record
    db:        Tsqlite3;
    parseArea: array[0..PARSE_SZ-1] of Byte;
  end;

var
  gVdbePass: i32 = 0;
  gVdbeFail: i32 = 0;

{ PASS/FAIL writer.  Identical body to the per-file `Check` proc
  every TestVdbe* program used to declare. }
procedure VdbeCheck(name: string; cond: Boolean);

{ Zero the TVdbeMinDb, set enc=UTF8 + aLimit slots 0/5.  When
  pBt<>nil also wire nDb=1, aDb=@aDbStatic, aDbStatic[0].pBt. }
procedure VdbeInitMinDb(var md: TVdbeMinDb; pBt: PBtree);

{ Allocate parse stub + VDBE + aMem, leaving eVdbeState=VDBE_RUN_STATE,
  cacheCtr=1.  Used by every TestVdbe* probe except TestVdbeApi which
  needs VDBE_READY_STATE — that one calls VdbeCreateMinReady. }
function VdbeCreateMinRun(pDb: PTsqlite3; nMem: i32): PVdbe;

{ Same as VdbeCreateMinRun but eVdbeState=VDBE_READY_STATE.  Used by
  TestVdbeApi only — its probes drive the sqlite3_step state machine
  which requires the READY entry state. }
function VdbeCreateMinReady(pDb: PTsqlite3; nMem: i32): PVdbe;

{ Open a fresh in-memory btree (no rows, no active transaction).
  Used by TestVdbeTxn's OP_Transaction probes. }
function VdbeOpenEmptyBtree(pDb: PTsqlite3): PBtree;

implementation

procedure VdbeCheck(name: string; cond: Boolean);
begin
  if cond then begin
    WriteLn('  PASS ', name);
    Inc(gVdbePass);
  end else begin
    WriteLn('  FAIL ', name);
    Inc(gVdbeFail);
  end;
end;

procedure VdbeInitMinDb(var md: TVdbeMinDb; pBt: PBtree);
begin
  FillChar(md, SizeOf(md), 0);
  md.db.enc       := SQLITE_UTF8;
  md.db.aLimit[5] := 250000000;
  md.db.aLimit[0] := 1000000000;
  if pBt <> nil then begin
    md.db.nDb              := 1;
    md.db.aDb              := @md.db.aDbStatic[0];
    md.db.aDbStatic[0].pBt := pBt;
  end;
end;

{ Internal: shared body for both Run/Ready variants. }
function CreateMin(pDb: PTsqlite3; nMem: i32; eState: u8): PVdbe;
var
  pParse: Pointer;
  v:      PVdbe;
  sz:     u64;
begin
  pParse := sqlite3DbMallocZero(pDb, PARSE_SZ);
  if pParse = nil then begin Result := nil; Exit; end;
  PPointer(pParse)^ := pDb;
  Pi32(PByte(pParse) + 156)^ := 250000000;

  v := sqlite3VdbeCreate(pParse);
  sqlite3DbFree(pDb, pParse);
  if v = nil then begin Result := nil; Exit; end;

  v^.nOp := 0;

  sz := u64(nMem) * SizeOf(TMem);
  v^.aMem    := PMem(sqlite3DbMallocZero(pDb, sz));
  v^.nMem    := nMem;
  v^.apCsr   := nil;
  v^.nCursor := 0;

  v^.eVdbeState         := eState;
  v^.minWriteFileFormat := 4;
  v^.pc                 := 0;
  v^.cacheCtr           := 1;

  Result := v;
end;

function VdbeCreateMinRun(pDb: PTsqlite3; nMem: i32): PVdbe;
begin
  Result := CreateMin(pDb, nMem, VDBE_RUN_STATE);
end;

function VdbeCreateMinReady(pDb: PTsqlite3; nMem: i32): PVdbe;
begin
  Result := CreateMin(pDb, nMem, VDBE_READY_STATE);
end;

function VdbeOpenEmptyBtree(pDb: PTsqlite3): PBtree;
var
  pBt: PBtree;
  rc:  i32;
begin
  Result := nil;
  rc := sqlite3BtreeOpen(sqlite3_vfs_find(nil), ':memory:', pDb, @pBt,
                         BTREE_OMIT_JOURNAL or BTREE_SINGLE,
                         SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE);
  if rc = SQLITE_OK then Result := pBt;
end;

end.
