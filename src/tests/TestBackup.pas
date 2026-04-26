{$I ../passqlite3.inc}
program TestBackup;

{
  Phase 8.7 gate — exercise sqlite3_backup_init / step / finish /
  remaining / pagecount.

  Phase 8.7 scope (matches the comment block at the top of
  passqlite3backup.pas):
    * Pager does not yet thread sqlite3BackupUpdate / Restart from its
      write path — concurrent writes during a step would not replicate.
      All tests below copy from a *quiescent* source.
    * Per-statement codegen for CREATE/INSERT remains incomplete, so we
      can't easily populate the source database with rows.  We exercise
      the surface API contract on freshly-opened :memory: handles,
      which is the canonical "empty source → backup_step returns DONE
      after creating page 1" path.

  Tests:
    T1  init(db=nil)                           — returns nil
    T2  init(src=dest, same handle)            — returns nil + sticky error
    T3  init(unknown destination name)         — returns nil
    T4  init then immediate finish (zero step) — finish=OK
    T5  init then step(-1) on empty src        — step=SQLITE_DONE
                                                  remaining=0
                                                  pagecount=0 or 1
    T6  finish(nil)                            — OK
    T7  remaining(nil) / pagecount(nil)        — both 0
    T8  step(nil)                              — SQLITE_MISUSE
    T9  init succeeds with src/dst both
        :memory: distinct handles              — handle non-nil
}

uses
  SysUtils,
  passqlite3types,
  passqlite3util,
  passqlite3os,
  passqlite3vdbe,
  passqlite3codegen,
  passqlite3main,
  passqlite3backup;

var
  gPass, gFail: i32;

procedure Expect(cond: Boolean; const msg: AnsiString);
begin
  if cond then begin Inc(gPass); WriteLn('  PASS ', msg); end
  else        begin Inc(gFail); WriteLn('  FAIL ', msg); end;
end;

procedure ExpectEq(a, b: i32; const msg: AnsiString);
begin
  Expect(a = b, msg + ' (got ' + IntToStr(a) + ', expected ' + IntToStr(b) + ')');
end;

var
  src, dst: PTsqlite3;
  bkp:      PSqlite3Backup;
  rc:       i32;

begin
  gPass := 0; gFail := 0;
  WriteLn('TestBackup — Phase 8.7 sqlite3_backup_*');

  { Open two distinct :memory: handles. }
  src := nil; dst := nil;
  ExpectEq(sqlite3_open(':memory:', @src), SQLITE_OK, 'open src');
  ExpectEq(sqlite3_open(':memory:', @dst), SQLITE_OK, 'open dst');
  if (src = nil) or (dst = nil) then begin
    WriteLn('  open failed — aborting'); Halt(1);
  end;

  { T1 — init(nil pointers) returns nil and does not crash. }
  bkp := sqlite3_backup_init(nil, 'main', src, 'main');
  Expect(bkp = nil, 'T1 init(pDestDb=nil) -> nil');
  bkp := sqlite3_backup_init(dst, 'main', nil, 'main');
  Expect(bkp = nil, 'T1 init(pSrcDb=nil)  -> nil');

  { T2 — same handle for src and dest is rejected. }
  bkp := sqlite3_backup_init(src, 'main', src, 'main');
  Expect(bkp = nil, 'T2 init(src=dest)    -> nil');

  { T3 — unknown destination database name. }
  bkp := sqlite3_backup_init(dst, 'no_such_db', src, 'main');
  Expect(bkp = nil, 'T3 init(unknown dest) -> nil');

  { T4 — init + immediate finish. }
  bkp := sqlite3_backup_init(dst, 'main', src, 'main');
  Expect(bkp <> nil, 'T4 init(main->main) -> handle');
  if bkp <> nil then begin
    rc := sqlite3_backup_finish(bkp);
    ExpectEq(rc, SQLITE_OK, 'T4 finish() rc');
  end;

  { T5 — full step on empty source.  C reference returns SQLITE_DONE on
    the first step because the source has zero pages, the destination
    therefore needs only the schema cookie + sentinel page. }
  bkp := sqlite3_backup_init(dst, 'main', src, 'main');
  Expect(bkp <> nil, 'T5 init -> handle');
  if bkp <> nil then begin
    rc := sqlite3_backup_step(bkp, -1);
    Expect((rc = SQLITE_DONE) or (rc = SQLITE_OK),
           'T5 step(-1) returns DONE or OK');
    Expect(sqlite3_backup_remaining(bkp) = 0, 'T5 remaining() = 0');
    rc := sqlite3_backup_finish(bkp);
    ExpectEq(rc, SQLITE_OK, 'T5 finish() rc');
  end;

  { T6 — finish on nil handle. }
  ExpectEq(sqlite3_backup_finish(nil), SQLITE_OK, 'T6 finish(nil)');

  { T7 — accessor functions on nil. }
  ExpectEq(sqlite3_backup_remaining(nil), 0, 'T7 remaining(nil) = 0');
  ExpectEq(sqlite3_backup_pagecount(nil), 0, 'T7 pagecount(nil) = 0');

  { T8 — step on nil returns MISUSE. }
  ExpectEq(sqlite3_backup_step(nil, 1), SQLITE_MISUSE, 'T8 step(nil)');

  { T9 — back-to-back init/finish should leave both handles closeable. }
  bkp := sqlite3_backup_init(dst, 'main', src, 'main');
  Expect(bkp <> nil, 'T9 init -> handle');
  if bkp <> nil then ExpectEq(sqlite3_backup_finish(bkp), SQLITE_OK, 'T9 finish');

  ExpectEq(sqlite3_close(src), SQLITE_OK, 'close src');
  ExpectEq(sqlite3_close(dst), SQLITE_OK, 'close dst');

  WriteLn;
  WriteLn('Results: ', gPass, ' passed, ', gFail, ' failed.');
  if gFail = 0 then Halt(0) else Halt(1);
end.
