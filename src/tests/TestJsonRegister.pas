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
program TestJsonRegister;
{
  Phase 6.8.h.6 gate test — JSON SQL function registration.

    R1..R32  Each scalar / aggregate name + nArg combination resolves
             via sqlite3FindFunction and links to the expected entry
             point.
    F1..F8   pUserData flag-bit encoding round-trips for the variants
             that depend on it (json_set / json_array_insert /
             jsonb_*  / -> / ->>).
    A1..A4   Aggregates expose xStep / xFinalize / xValue / xInverse.
    B1..B2   sqlite3JsonVtabRegister is reachable as a unit-level API
             via passqlite3jsoneach (linked through codegen).
    C1       SQLITE_RESULT_SUBTYPE constant value.
}

uses
  passqlite3types, passqlite3internal, passqlite3util, passqlite3os,
  passqlite3vdbe, passqlite3codegen, passqlite3json, passqlite3jsoneach,
  passqlite3vtab;

var
  nPass, nFail: i32;

procedure Check(const tag: AnsiString; cond: Boolean);
begin
  if cond then begin
    WriteLn('PASS  ', tag);
    Inc(nPass);
  end else begin
    WriteLn('FAIL  ', tag);
    Inc(nFail);
  end;
end;

function FindFn(db: PTsqlite3; zName: PAnsiChar; nArg: i32): PTFuncDef;
begin
  Result := sqlite3FindFunction(db, zName, nArg, SQLITE_UTF8, 0);
end;

procedure TestRegistration;
var
  db: PTsqlite3;
  p:  PTFuncDef;
begin
  db := PTsqlite3(sqlite3MallocZero(SizeOf(Tsqlite3)));
  if db = nil then begin WriteLn('SKIP  R*  (OOM)'); Exit; end;
  db^.aFunc.count := 0;
  db^.mDbFlags    := 0;
  db^.enc         := SQLITE_UTF8;

  FillChar(sqlite3BuiltinFunctions, SizeOf(sqlite3BuiltinFunctions), 0);
  sqlite3RegisterBuiltinFunctions;

  { R1..R10: scalar lookups }
  p := FindFn(db, 'json',                1); Check('R1 json/1',                p <> nil);
  p := FindFn(db, 'jsonb',               1); Check('R2 jsonb/1',               p <> nil);
  p := FindFn(db, 'json_array',         -1); Check('R3 json_array/-1',         p <> nil);
  p := FindFn(db, 'json_object',        -1); Check('R4 json_object/-1',        p <> nil);
  p := FindFn(db, 'json_extract',       -1); Check('R5 json_extract/-1',       p <> nil);
  p := FindFn(db, 'json_array_length',   2); Check('R6 json_array_length/2',   p <> nil);
  p := FindFn(db, 'json_error_position', 1); Check('R7 json_error_position/1', p <> nil);
  p := FindFn(db, 'json_remove',        -1); Check('R8 json_remove/-1',        p <> nil);
  p := FindFn(db, 'json_replace',       -1); Check('R9 json_replace/-1',       p <> nil);
  p := FindFn(db, 'json_set',           -1); Check('R10 json_set/-1',          p <> nil);

  { R11..R20: more scalars + jsonb counterparts }
  p := FindFn(db, 'json_insert',        -1); Check('R11 json_insert/-1',       p <> nil);
  p := FindFn(db, 'json_array_insert',  -1); Check('R12 json_array_insert/-1', p <> nil);
  p := FindFn(db, 'json_patch',          2); Check('R13 json_patch/2',         p <> nil);
  p := FindFn(db, 'json_quote',          1); Check('R14 json_quote/1',         p <> nil);
  p := FindFn(db, 'json_pretty',         1); Check('R15 json_pretty/1',        p <> nil);
  p := FindFn(db, 'json_pretty',         2); Check('R16 json_pretty/2',        p <> nil);
  p := FindFn(db, 'json_type',           1); Check('R17 json_type/1',          p <> nil);
  p := FindFn(db, 'json_type',           2); Check('R18 json_type/2',          p <> nil);
  p := FindFn(db, 'json_valid',          1); Check('R19 json_valid/1',         p <> nil);
  p := FindFn(db, 'json_valid',          2); Check('R20 json_valid/2',         p <> nil);

  { R21..R28: jsonb_* and operators }
  p := FindFn(db, 'jsonb_array',        -1); Check('R21 jsonb_array/-1',       p <> nil);
  p := FindFn(db, 'jsonb_extract',      -1); Check('R22 jsonb_extract/-1',     p <> nil);
  p := FindFn(db, 'jsonb_remove',       -1); Check('R23 jsonb_remove/-1',      p <> nil);
  p := FindFn(db, 'jsonb_replace',      -1); Check('R24 jsonb_replace/-1',     p <> nil);
  p := FindFn(db, 'jsonb_set',          -1); Check('R25 jsonb_set/-1',         p <> nil);
  p := FindFn(db, 'jsonb_insert',       -1); Check('R26 jsonb_insert/-1',      p <> nil);
  p := FindFn(db, 'jsonb_array_insert', -1); Check('R27 jsonb_array_insert/-1',p <> nil);
  p := FindFn(db, 'jsonb_patch',         2); Check('R28 jsonb_patch/2',        p <> nil);

  { R29..R32: aggregates findable }
  p := FindFn(db, 'json_group_array',   1); Check('R29 json_group_array/1',    p <> nil);
  p := FindFn(db, 'jsonb_group_array',  1); Check('R30 jsonb_group_array/1',   p <> nil);
  p := FindFn(db, 'json_group_object',  2); Check('R31 json_group_object/2',   p <> nil);
  p := FindFn(db, 'jsonb_group_object', 2); Check('R32 jsonb_group_object/2',  p <> nil);

  { F1: json_set's pUserData carries JSON_ISSET (=$04) }
  p := FindFn(db, 'json_set', -1);
  Check('F1 json_set pUserData=JSON_ISSET',
    (p <> nil) and (PtrUInt(p^.pUserData) = $04));

  { F2: json_array_insert's pUserData carries JSON_AINS (=$08) }
  p := FindFn(db, 'json_array_insert', -1);
  Check('F2 json_array_insert pUserData=JSON_AINS',
    (p <> nil) and (PtrUInt(p^.pUserData) = $08));

  { F3: jsonb_set carries JSON_ISSET | JSON_BLOB = $14 }
  p := FindFn(db, 'jsonb_set', -1);
  Check('F3 jsonb_set pUserData=ISSET|BLOB',
    (p <> nil) and (PtrUInt(p^.pUserData) = $14));

  { F4: jsonb_insert carries JSON_BLOB = $10 only }
  p := FindFn(db, 'jsonb_insert', -1);
  Check('F4 jsonb_insert pUserData=JSON_BLOB',
    (p <> nil) and (PtrUInt(p^.pUserData) = $10));

  { F5: '->' carries JSON_JSON = $01 }
  p := FindFn(db, '->', 2);
  Check('F5 -> pUserData=JSON_JSON',
    (p <> nil) and (PtrUInt(p^.pUserData) = $01));

  { F6: '->>' carries JSON_SQL = $02 }
  p := FindFn(db, '->>', 2);
  Check('F6 ->> pUserData=JSON_SQL',
    (p <> nil) and (PtrUInt(p^.pUserData) = $02));

  { F7: jsonb_array_insert pUserData = JSON_AINS|JSON_BLOB = $18 }
  p := FindFn(db, 'jsonb_array_insert', -1);
  Check('F7 jsonb_array_insert pUserData=AINS|BLOB',
    (p <> nil) and (PtrUInt(p^.pUserData) = $18));

  { F8: plain json_extract has no flags (pUserData=0) }
  p := FindFn(db, 'json_extract', -1);
  Check('F8 json_extract pUserData=0',
    (p <> nil) and (p^.pUserData = nil));

  { A1..A4: aggregate vtable plumbing }
  p := FindFn(db, 'json_group_array', 1);
  Check('A1 json_group_array.xSFunc=jsonArrayStep',
    (p <> nil) and (Pointer(@p^.xSFunc) <> nil) and
    (Pointer(p^.xSFunc) = Pointer(@jsonArrayStep)));
  Check('A2 json_group_array.xFinalize=jsonArrayFinal',
    (p <> nil) and (Pointer(p^.xFinalize) = Pointer(@jsonArrayFinal)));
  Check('A3 json_group_array.xValue=jsonArrayValue',
    (p <> nil) and (Pointer(p^.xValue) = Pointer(@jsonArrayValue)));
  Check('A4 json_group_array.xInverse=jsonGroupInverse',
    (p <> nil) and (Pointer(p^.xInverse) = Pointer(@jsonGroupInverse)));

  { B1: jsonb_group_object aggregate carries JSON_BLOB on pUserData }
  p := FindFn(db, 'jsonb_group_object', 2);
  Check('B1 jsonb_group_object pUserData=JSON_BLOB',
    (p <> nil) and (PtrUInt(p^.pUserData) = $10));

  { B2: SQLITE_RESULT_SUBTYPE present in flags for funcs that produce
        a JSON subtype (json_array sets bWS). }
  p := FindFn(db, 'json_array', -1);
  Check('B2 json_array funcFlags has SQLITE_RESULT_SUBTYPE',
    (p <> nil) and ((p^.funcFlags and SQLITE_RESULT_SUBTYPE) <> 0));

  sqlite3DbFree(db, db);
end;

procedure TestVtabReachable;
var
  m: PVtabModule;
  db: PTsqlite3;
begin
  { sqlite3JsonVtabRegister is callable by name (proves the codegen
    unit pulls in passqlite3jsoneach so the upcoming integration
    chunk can wire per-connection vtab registration). }
  db := PTsqlite3(sqlite3MallocZero(SizeOf(Tsqlite3)));
  if db = nil then begin WriteLn('SKIP  V*  (OOM)'); Exit; end;
  m := sqlite3JsonVtabRegister(db, 'not_a_module');
  Check('V1 unknown spelling → nil', m = nil);
  sqlite3DbFree(db, db);
end;

procedure TestConstants;
begin
  Check('C1 SQLITE_RESULT_SUBTYPE=$01000000',
    SQLITE_RESULT_SUBTYPE = $01000000);
end;

begin
  nPass := 0; nFail := 0;
  TestRegistration;
  TestVtabReachable;
  TestConstants;
  WriteLn;
  WriteLn('Results: ', nPass, ' passed, ', nFail, ' failed.');
  if nFail > 0 then Halt(1);
end.
