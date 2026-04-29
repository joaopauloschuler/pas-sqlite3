{ DiagStrAccum — Phase 8.5.1 differential gate for sqlite3_str_* API.
  Compares Pas's sqlite3_str_* against the C reference (csq_str_*).
  Run with: LD_LIBRARY_PATH=$PWD/src bin/DiagStrAccum }
{$I passqlite3.inc}
program DiagStrAccum;

uses
  SysUtils,
  passqlite3types,
  passqlite3os,
  passqlite3util,
  passqlite3printf,
  csqlite3;

var
  diverged: Int32 = 0;
  passed:   Int32 = 0;

procedure Check(const tag: AnsiString; condition: Boolean;
                const got, want: AnsiString);
begin
  if condition then begin
    Inc(passed);
    WriteLn('PASS    ', tag);
  end else begin
    Inc(diverged);
    WriteLn('DIVERGE ', tag);
    WriteLn('   got =', got);
    WriteLn('   want=', want);
  end;
end;

function PasBuild: AnsiString;
var
  p:  PSqlite3Str;
  z:  PAnsiChar;
begin
  p := sqlite3_str_new(nil);
  sqlite3_str_appendall(p, 'hello');
  sqlite3_str_appendchar(p, 1, ' ');
  sqlite3_str_append(p, 'world!!', 5);    { "world" only }
  sqlite3_str_appendf(p, ' [%d/%s]', [42, PAnsiChar('answer')]);
  z := sqlite3_str_finish(p);
  if z = nil then Result := '<nil>' else Result := AnsiString(z);
  if z <> nil then sqlite3_free(z);
end;

function CBuild: AnsiString;
var
  p:  Pcsq_str;
  z:  PChar;
begin
  p := csq_str_new(nil);
  csq_str_appendall(p, 'hello');
  csq_str_appendchar(p, 1, ' ');
  csq_str_append(p, 'world!!', 5);
  csq_str_append(p, ' [42/answer]', Length(' [42/answer]'));   { skip varargs }
  z := csq_str_finish(p);
  if z = nil then Result := '<nil>' else Result := AnsiString(z);
  if z <> nil then csq_free(z);
end;

procedure TestBasic;
var pasS, cS: AnsiString;
begin
  pasS := PasBuild;
  cS   := CBuild;
  Check('basic build (hello world [42/answer])', pasS = cS, pasS, cS);
end;

procedure TestLength;
var
  pasP: PSqlite3Str; cP: Pcsq_str;
  pl, cl: Int32;
begin
  pasP := sqlite3_str_new(nil);
  cP   := csq_str_new(nil);
  sqlite3_str_appendall(pasP, 'abcde');
  csq_str_appendall(cP, 'abcde');
  pl := sqlite3_str_length(pasP);
  cl := csq_str_length(cP);
  Check('length after appendall(5)', pl = cl,
        IntToStr(pl), IntToStr(cl));
  sqlite3_free(sqlite3_str_finish(pasP));
  csq_free(csq_str_finish(cP));
end;

procedure TestTruncate;
var
  pasP: PSqlite3Str;
  pasS: AnsiString;
  pz: PAnsiChar;
begin
  { The Debian-packaged libsqlite3 used at link time does not export
    sqlite3_str_truncate, so this test exercises the Pas implementation
    against the expected string instead of differential against C. }
  pasP := sqlite3_str_new(nil);
  sqlite3_str_appendall(pasP, 'one two three');
  sqlite3_str_truncate(pasP, 7);
  pz := sqlite3_str_value(pasP);
  if pz = nil then pasS := '<nil>' else pasS := AnsiString(pz);
  Check('truncate(7) -> "one two"', pasS = 'one two', pasS, 'one two');
  sqlite3_free(sqlite3_str_finish(pasP));
end;

procedure TestReset;
var
  pasP: PSqlite3Str; cP: Pcsq_str;
  pl, cl: Int32;
begin
  pasP := sqlite3_str_new(nil);
  cP   := csq_str_new(nil);
  sqlite3_str_appendall(pasP, 'discard me');
  csq_str_appendall(cP, 'discard me');
  sqlite3_str_reset(pasP);
  csq_str_reset(cP);
  pl := sqlite3_str_length(pasP);
  cl := csq_str_length(cP);
  Check('length after reset', (pl = 0) and (cl = 0),
        IntToStr(pl), IntToStr(cl));
  sqlite3_str_appendall(pasP, 'after');
  csq_str_appendall(cP, 'after');
  Check('reuse after reset',
        sqlite3_str_length(pasP) = csq_str_length(cP),
        IntToStr(sqlite3_str_length(pasP)),
        IntToStr(csq_str_length(cP)));
  sqlite3_free(sqlite3_str_finish(pasP));
  csq_free(csq_str_finish(cP));
end;

procedure TestEmptyValue;
var
  pasP: PSqlite3Str; cP: Pcsq_str;
  pz, cz: PAnsiChar;
begin
  pasP := sqlite3_str_new(nil);
  cP   := csq_str_new(nil);
  pz := sqlite3_str_value(pasP);
  cz := csq_str_value(cP);
  Check('empty value is nil',
        (pz = nil) and (cz = nil),
        IntToStr(PtrInt(pz)), IntToStr(PtrInt(cz)));
  sqlite3_str_free(pasP);
  { csq_str_free not in our binding; use finish to dispose }
  csq_free(csq_str_finish(cP));
end;

procedure TestErrcode;
var
  pasE, cE: Int32;
begin
  pasE := sqlite3_str_errcode(nil);
  cE   := csq_str_errcode(nil);
  Check('errcode(nil) == NOMEM',
        (pasE = SQLITE_NOMEM) and (cE = SQLITE_NOMEM),
        IntToStr(pasE), IntToStr(cE));
end;

procedure TestLargeAppend;
var
  pasP: PSqlite3Str; cP: Pcsq_str;
  i: Int32;
  pl, cl: Int32;
begin
  pasP := sqlite3_str_new(nil);
  cP   := csq_str_new(nil);
  for i := 1 to 1000 do begin
    sqlite3_str_appendall(pasP, 'abcdefghij');
    csq_str_appendall(cP, 'abcdefghij');
  end;
  pl := sqlite3_str_length(pasP);
  cl := csq_str_length(cP);
  Check('large append (10000 chars)',
        (pl = 10000) and (cl = 10000),
        IntToStr(pl), IntToStr(cl));
  sqlite3_free(sqlite3_str_finish(pasP));
  csq_free(csq_str_finish(cP));
end;

begin
  TestBasic;
  TestLength;
  TestTruncate;
  TestReset;
  TestEmptyValue;
  TestErrcode;
  TestLargeAppend;
  WriteLn;
  WriteLn('Total: ', passed, ' PASS / ', diverged, ' DIVERGE');
  if diverged = 0 then Halt(0) else Halt(1);
end.
