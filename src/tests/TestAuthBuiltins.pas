{$I passqlite3.inc}
program TestAuthBuiltins;
{
  Phase 6.6 gate test — auth.c, callback.c, func.c, date.c, fkey.c stubs.

    T1  Auth action constants (SQLITE_CREATE_INDEX .. SQLITE_RECURSIVE_AUTH)
    T2  SQLITE_FUNC_* flag constants
    T3  SizeOf(TCollSeq) = 40
    T4  SizeOf(TFuncDestructor) = 24
    T5  SizeOf(TFuncDefHash) = 184  (23 * 8)
    T6  SQLITE_FUNC_HASH_SZ = 23
    T7  sqlite3RegisterBuiltinFunctions populates sqlite3BuiltinFunctions
    T8  sqlite3FindFunction finds 'abs'
    T9  sqlite3FindFunction finds 'length'
    T10 sqlite3FindFunction finds 'typeof'
    T11 sqlite3FindFunction finds 'date'
    T12 sqlite3FindFunction finds 'count' aggregate
    T13 SQLITE_DENY=1, SQLITE_IGNORE=2
    T14 SQLITE_REAL=2 (alias for SQLITE_FLOAT)
    T15 SQLITE_DETERMINISTIC, SQLITE_DIRECTONLY, SQLITE_SUBTYPE, SQLITE_INNOCUOUS values
}

uses
  passqlite3types, passqlite3internal, passqlite3util, passqlite3os,
  passqlite3vdbe, passqlite3codegen;

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

// -----------------------------------------------------------------------
// T1: Auth action constants
// -----------------------------------------------------------------------
procedure TestAuthConstants;
begin
  Check('T1a SQLITE_CREATE_INDEX=1',       SQLITE_CREATE_INDEX      = 1);
  Check('T1b SQLITE_CREATE_TABLE=2',       SQLITE_CREATE_TABLE      = 2);
  Check('T1c SQLITE_CREATE_TEMP_INDEX=3',  SQLITE_CREATE_TEMP_INDEX = 3);
  Check('T1d SQLITE_DELETE_AUTH=9',        SQLITE_DELETE_AUTH       = 9);
  Check('T1e SQLITE_INSERT_AUTH=18',       SQLITE_INSERT_AUTH       = 18);
  Check('T1f SQLITE_SELECT_AUTH=21',       SQLITE_SELECT_AUTH       = 21);
  Check('T1g SQLITE_UPDATE_AUTH=23',       SQLITE_UPDATE_AUTH       = 23);
  Check('T1h SQLITE_ATTACH_AUTH=24',       SQLITE_ATTACH_AUTH       = 24);
  Check('T1i SQLITE_DETACH_AUTH=25',       SQLITE_DETACH_AUTH       = 25);
  Check('T1j SQLITE_FUNCTION_AUTH=31',     SQLITE_FUNCTION_AUTH     = 31);
  Check('T1k SQLITE_RECURSIVE_AUTH=33',    SQLITE_RECURSIVE_AUTH    = 33);
end;

// -----------------------------------------------------------------------
// T2: SQLITE_FUNC_* flag constants
// -----------------------------------------------------------------------
procedure TestFuncFlags;
begin
  Check('T2a SQLITE_FUNC_ENCMASK=$0003',   SQLITE_FUNC_ENCMASK  = $0003);
  Check('T2b SQLITE_FUNC_LIKE=$0004',      SQLITE_FUNC_LIKE     = $0004);
  Check('T2c SQLITE_FUNC_CONSTANT=$0800',  SQLITE_FUNC_CONSTANT = $0800);
  Check('T2d SQLITE_FUNC_BUILTIN=$800000', SQLITE_FUNC_BUILTIN  = $00800000);
  Check('T2e SQLITE_FUNC_HASH_SZ=23',      SQLITE_FUNC_HASH_SZ  = 23);
end;

// -----------------------------------------------------------------------
// T3-T6: Struct layout verification
// -----------------------------------------------------------------------
procedure TestLayouts;
begin
  Check('T3 SizeOf(TCollSeq)=40',       SizeOf(TCollSeq)        = 40);
  Check('T4 SizeOf(TFuncDestructor)=24',SizeOf(TFuncDestructor)  = 24);
  Check('T5 SizeOf(TFuncDefHash)=184',  SizeOf(TFuncDefHash)     = 184);
  Check('T6 SQLITE_FUNC_HASH_SZ=23',    SQLITE_FUNC_HASH_SZ      = 23);
end;

// -----------------------------------------------------------------------
// T7-T12: Built-in function registration
// -----------------------------------------------------------------------
procedure TestBuiltins;
var
  db: PTsqlite3;
  p:  PTFuncDef;
  i:  i32;
  found: Boolean;
begin
  { Allocate a minimal db stub — just enough for FindFunction }
  db := PTsqlite3(sqlite3MallocZero(SizeOf(Tsqlite3)));
  if db = nil then begin
    WriteLn('SKIP  T7-T12 (OOM)');
    Exit;
  end;
  db^.aFunc.count := 0;
  db^.mDbFlags    := 0;
  db^.enc         := SQLITE_UTF8;

  { Register built-ins into the global table }
  sqlite3RegisterBuiltinFunctions;
  sqlite3RegisterDateTimeFunctions;

  { T7: at least one slot in sqlite3BuiltinFunctions should be non-nil }
  found := False;
  for i := 0 to SQLITE_FUNC_HASH_SZ - 1 do
    if sqlite3BuiltinFunctions.a[i] <> nil then begin found := True; Break; end;
  Check('T7 sqlite3BuiltinFunctions non-empty', found);

  { T8: abs }
  p := sqlite3FindFunction(db, 'abs', 1, SQLITE_UTF8, 0);
  Check('T8 FindFunction "abs" found', p <> nil);
  if p <> nil then
    Check('T8b abs.nArg=1', p^.nArg = 1);

  { T9: length }
  p := sqlite3FindFunction(db, 'length', 1, SQLITE_UTF8, 0);
  Check('T9 FindFunction "length" found', p <> nil);

  { T10: typeof }
  p := sqlite3FindFunction(db, 'typeof', 1, SQLITE_UTF8, 0);
  Check('T10 FindFunction "typeof" found', p <> nil);

  { T11: date (registered by sqlite3RegisterDateTimeFunctions) }
  p := sqlite3FindFunction(db, 'date', 1, SQLITE_UTF8, 0);
  Check('T11 FindFunction "date" found', p <> nil);

  { T12: count aggregate (nArg=0) }
  p := sqlite3FindFunction(db, 'count', 0, SQLITE_UTF8, 0);
  Check('T12 FindFunction "count" found', p <> nil);

  sqlite3DbFree(db, db);
end;

// -----------------------------------------------------------------------
// T13-T15: Misc constants
// -----------------------------------------------------------------------
procedure TestMiscConstants;
begin
  Check('T13a SQLITE_DENY=1',              SQLITE_DENY          = 1);
  Check('T13b SQLITE_IGNORE=2',            SQLITE_IGNORE        = 2);
  Check('T14 SQLITE_REAL=2',               SQLITE_REAL          = 2);
  Check('T15a SQLITE_DETERMINISTIC=$800',  SQLITE_DETERMINISTIC = $000000800);
  Check('T15b SQLITE_DIRECTONLY=$80000',   SQLITE_DIRECTONLY    = $000080000);
  Check('T15c SQLITE_SUBTYPE=$100000',     SQLITE_SUBTYPE       = $000100000);
  Check('T15d SQLITE_INNOCUOUS=$200000',   SQLITE_INNOCUOUS     = $000200000);
end;

// -----------------------------------------------------------------------
// Main
// -----------------------------------------------------------------------
begin
  nPass := 0; nFail := 0;
  TestAuthConstants;
  TestFuncFlags;
  TestLayouts;
  TestBuiltins;
  TestMiscConstants;
  WriteLn;
  WriteLn('Results: ', nPass, ' passed, ', nFail, ' failed.');
  if nFail > 0 then Halt(1);
end.
