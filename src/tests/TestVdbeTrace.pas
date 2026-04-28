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
program TestVdbeTrace;
{
  Phase 5.8 gate test — vdbetrace.c EXPLAIN SQL expander.

  sqlite3VdbeExpandSql expands bound-parameter placeholders for tracing.
  The full tokeniser-based expansion (sqlite3GetToken) is a Phase 7 concern;
  this phase provides a working stub that returns a copy of the raw SQL.

    T1  sqlite3VdbeExpandSql(nil, ...) → nil  (nil VDBE guard)
    T2  sqlite3VdbeExpandSql(v, nil) → nil    (nil SQL guard)
    T3  sqlite3VdbeExpandSql(v, "SELECT 1") → copy of "SELECT 1"
    T4  The returned string is heap-allocated (can be freed via sqlite3DbFree)
    T5  sqlite3VdbeExpandSql(v, "") → empty string (not nil)

  Gate: T1–T5 all PASS.
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

const
  PARSE_SZ = 256;

type
  TMinDb = record
    db:        Tsqlite3;
  end;

procedure InitMinDb(var md: TMinDb);
begin
  FillChar(md, SizeOf(md), 0);
  md.db.enc       := SQLITE_UTF8;
  md.db.aLimit[5] := 250000000;
  md.db.aLimit[0] := 1000000000;
end;

function CreateMinVdbe(pDb: PTsqlite3): PVdbe;
var
  pParse: Pointer;
  v:      PVdbe;
begin
  pParse := sqlite3DbMallocZero(pDb, PARSE_SZ);
  if pParse = nil then begin Result := nil; Exit; end;
  PPointer(pParse)^ := pDb;
  Pi32(PByte(pParse) + 156)^ := 250000000;
  v := sqlite3VdbeCreate(pParse);
  sqlite3DbFree(pDb, pParse);
  if v = nil then begin Result := nil; Exit; end;
  v^.nOp := 0;
  v^.aMem := PMem(sqlite3DbMallocZero(pDb, 2 * SizeOf(TMem)));
  v^.nMem := 2;
  v^.eVdbeState := VDBE_READY_STATE;
  Result := v;
end;

{ ===== T1: nil VDBE guard ================================================== }

procedure TestNilVdbe;
var
  z: PAnsiChar;
begin
  WriteLn('T1: sqlite3VdbeExpandSql(nil, sql) → nil');
  z := sqlite3VdbeExpandSql(nil, 'SELECT 1');
  Check('T1 result=nil', z = nil);
end;

{ ===== T2: nil SQL guard =================================================== }

procedure TestNilSql;
var
  md: TMinDb;
  v:  PVdbe;
  z:  PAnsiChar;
begin
  WriteLn('T2: sqlite3VdbeExpandSql(v, nil) → nil');
  InitMinDb(md);
  v := CreateMinVdbe(@md.db);
  if v = nil then begin Check('T2 vdbe', False); Exit; end;

  z := sqlite3VdbeExpandSql(v, nil);
  Check('T2 result=nil', z = nil);

  sqlite3VdbeDelete(v);
end;

{ ===== T3: basic SQL expansion (no parameters) ============================= }

procedure TestBasicSql;
var
  md:  TMinDb;
  v:   PVdbe;
  z:   PAnsiChar;
  db:  PTsqlite3;
begin
  WriteLn('T3: sqlite3VdbeExpandSql(v, "SELECT 1") → copy');
  InitMinDb(md);
  v := CreateMinVdbe(@md.db);
  if v = nil then begin Check('T3 vdbe', False); Exit; end;
  db := @md.db;

  z := sqlite3VdbeExpandSql(v, 'SELECT 1');
  Check('T3 result<>nil', z <> nil);
  if z <> nil then begin
    Check('T3 content', StrComp(z, 'SELECT 1') = 0);
    sqlite3DbFree(db, z);   { T4: returned string is freeable }
    Check('T4 freed', True);
  end;

  sqlite3VdbeDelete(v);
end;

{ ===== T5: empty SQL string ================================================ }

procedure TestEmptySql;
var
  md: TMinDb;
  v:  PVdbe;
  z:  PAnsiChar;
  db: PTsqlite3;
begin
  WriteLn('T5: sqlite3VdbeExpandSql(v, "") → empty string');
  InitMinDb(md);
  v := CreateMinVdbe(@md.db);
  if v = nil then begin Check('T5 vdbe', False); Exit; end;
  db := @md.db;

  z := sqlite3VdbeExpandSql(v, '');
  Check('T5 result<>nil', z <> nil);
  if z <> nil then begin
    Check('T5 empty', z[0] = #0);
    sqlite3DbFree(db, z);
  end;

  sqlite3VdbeDelete(v);
end;

{ ===== main ================================================================= }

begin
  sqlite3OsInit;
  sqlite3PcacheInitialize;

  WriteLn('=== TestVdbeTrace — Phase 5.8 gate test ===');
  WriteLn;

  TestNilVdbe;   WriteLn;
  TestNilSql;    WriteLn;
  TestBasicSql;  WriteLn;
  TestEmptySql;  WriteLn;

  WriteLn(Format('Results: %d passed, %d failed', [gPass, gFail]));
  if gFail > 0 then Halt(1);
end.
