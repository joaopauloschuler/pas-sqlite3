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
{$I ../passqlite3.inc}
{
  DiagPragma — exploratory probe.  PRAGMA round-trips and introspection.
  Aims to surface PRAGMAs that silently no-op or return wrong values on
  the Pas side relative to libsqlite3.so.  Folds into 6.12
  (sqlite3Pragma full port) but adds a per-pragma regression gate so
  individual fixes can be tracked.
}
program DiagPragma;

uses
  SysUtils,
  passqlite3types, passqlite3util, passqlite3vdbe,
  passqlite3codegen, passqlite3main, csqlite3;

var
  diverged: i32 = 0;

function PasRun(const setup, check: AnsiString;
                out checkPrep, val: i32; out txt: AnsiString): i32;
var
  db: PTsqlite3;
  pStmt: PVdbe;
  rcs: i32;
  s, stmt2: AnsiString;
  p: i32;
  pTxt: PAnsiChar;
begin
  Result := 0;
  checkPrep := -1; val := -99999; txt := '';
  db := nil;
  if sqlite3_open(':memory:', @db) <> 0 then begin Result := -1; Exit; end;
  if setup <> '' then begin
    s := setup;
    while s <> '' do begin
      p := Pos(';', s);
      if p = 0 then begin stmt2 := s; s := ''; end
      else begin stmt2 := Copy(s, 1, p - 1); s := Copy(s, p + 1, MaxInt); end;
      stmt2 := Trim(stmt2);
      if stmt2 = '' then continue;
      pStmt := nil;
      if (sqlite3_prepare_v2(db, PAnsiChar(stmt2), -1, @pStmt, nil) = 0)
        and (pStmt <> nil) then begin
        repeat rcs := sqlite3_step(pStmt) until rcs <> SQLITE_ROW;
        sqlite3_finalize(pStmt);
      end;
    end;
  end;
  pStmt := nil;
  checkPrep := sqlite3_prepare_v2(db, PAnsiChar(check), -1, @pStmt, nil);
  if (checkPrep = 0) and (pStmt <> nil) then begin
    if sqlite3_step(pStmt) = SQLITE_ROW then begin
      val := sqlite3_column_int(pStmt, 0);
      pTxt := PAnsiChar(sqlite3_column_text(pStmt, 0));
      if pTxt <> nil then txt := AnsiString(pTxt);
    end;
    sqlite3_finalize(pStmt);
  end;
  sqlite3_close(db);
end;

function CRun(const setup, check: AnsiString;
              out checkPrep, val: i32; out txt: AnsiString): i32;
var
  db: Pcsq_db;
  pStmt: Pcsq_stmt;
  pTail, pErr: PChar;
  pTxt: PAnsiChar;
begin
  Result := 0;
  checkPrep := -1; val := -99999; txt := '';
  db := nil;
  if csq_open(':memory:', db) <> 0 then begin Result := -1; Exit; end;
  if setup <> '' then begin
    pErr := nil;
    csq_exec(db, PAnsiChar(setup), nil, nil, pErr);
  end;
  pStmt := nil; pTail := nil;
  checkPrep := csq_prepare_v2(db, PAnsiChar(check), -1, pStmt, pTail);
  if (checkPrep = 0) and (pStmt <> nil) then begin
    if csq_step(pStmt) = SQLITE_ROW then begin
      val := csq_column_int(pStmt, 0);
      pTxt := PAnsiChar(csq_column_text(pStmt, 0));
      if pTxt <> nil then txt := AnsiString(pTxt);
    end;
    csq_finalize(pStmt);
  end;
  csq_close(db);
end;

procedure Probe(const lbl, setup, check: AnsiString);
var
  pPrep, pVal: i32;
  cPrep, cVal: i32;
  pTxt, cTxt: AnsiString;
  ok: Boolean;
begin
  PasRun(setup, check, pPrep, pVal, pTxt);
  CRun  (setup, check, cPrep, cVal, cTxt);
  ok := (pPrep = cPrep) and (pVal = cVal) and (pTxt = cTxt);
  if ok then
    WriteLn('PASS    ', lbl)
  else
  begin
    Inc(diverged);
    WriteLn('DIVERGE ', lbl);
    WriteLn('   check=', check);
    WriteLn('   Pas: prep=', pPrep, ' val=', pVal, ' txt="', pTxt, '"');
    WriteLn('   C  : prep=', cPrep, ' val=', cVal, ' txt="', cTxt, '"');
  end;
end;

begin
  // ---- Boolean / scalar PRAGMAs (read default, then round-trip) ----
  Probe('foreign_keys default',          '', 'PRAGMA foreign_keys');
  Probe('foreign_keys=ON',               'PRAGMA foreign_keys=ON',   'PRAGMA foreign_keys');
  Probe('recursive_triggers default',    '', 'PRAGMA recursive_triggers');
  Probe('recursive_triggers=ON',         'PRAGMA recursive_triggers=ON', 'PRAGMA recursive_triggers');
  Probe('case_sensitive_like default',   '', 'PRAGMA case_sensitive_like');
  Probe('reverse_unordered_selects',     '', 'PRAGMA reverse_unordered_selects');
  Probe('defer_foreign_keys default',    '', 'PRAGMA defer_foreign_keys');
  Probe('defer_foreign_keys=1',          'PRAGMA defer_foreign_keys=1','PRAGMA defer_foreign_keys');
  Probe('writable_schema default',       '', 'PRAGMA writable_schema');
  Probe('legacy_alter_table default',    '', 'PRAGMA legacy_alter_table');
  Probe('legacy_file_format default',    '', 'PRAGMA legacy_file_format');
  Probe('cell_size_check default',       '', 'PRAGMA cell_size_check');
  Probe('automatic_index default',       '', 'PRAGMA automatic_index');
  Probe('count_changes default',         '', 'PRAGMA count_changes');
  Probe('full_column_names default',     '', 'PRAGMA full_column_names');
  Probe('short_column_names default',    '', 'PRAGMA short_column_names');
  Probe('checkpoint_fullfsync default',  '', 'PRAGMA checkpoint_fullfsync');
  Probe('fullfsync default',             '', 'PRAGMA fullfsync');
  Probe('ignore_check_constraints',      '', 'PRAGMA ignore_check_constraints');
  Probe('query_only default',            '', 'PRAGMA query_only');
  Probe('read_uncommitted default',      '', 'PRAGMA read_uncommitted');
  Probe('secure_delete default',         '', 'PRAGMA secure_delete');
  Probe('temp_store default',            '', 'PRAGMA temp_store');
  Probe('threads default',               '', 'PRAGMA threads');
  Probe('trusted_schema default',        '', 'PRAGMA trusted_schema');

  // ---- numeric / size PRAGMAs ----
  Probe('page_size default',             '', 'PRAGMA page_size');
  Probe('max_page_count',                '', 'PRAGMA max_page_count');
  Probe('cache_size default',            '', 'PRAGMA cache_size');
  Probe('cache_spill default',           '', 'PRAGMA cache_spill');
  Probe('mmap_size default',             '', 'PRAGMA mmap_size');
  Probe('soft_heap_limit',               '', 'PRAGMA soft_heap_limit');
  Probe('hard_heap_limit',               '', 'PRAGMA hard_heap_limit');
  Probe('busy_timeout default',          '', 'PRAGMA busy_timeout');
  Probe('analysis_limit default',        '', 'PRAGMA analysis_limit');
  Probe('wal_autocheckpoint default',    '', 'PRAGMA wal_autocheckpoint');
  Probe('journal_size_limit default',    '', 'PRAGMA journal_size_limit');

  // ---- string-valued PRAGMAs ----
  Probe('encoding default',              '', 'PRAGMA encoding');
  Probe('journal_mode default',          '', 'PRAGMA journal_mode');
  Probe('locking_mode default',          '', 'PRAGMA locking_mode');
  Probe('synchronous default',           '', 'PRAGMA synchronous');
  Probe('auto_vacuum default',           '', 'PRAGMA auto_vacuum');

  // ---- header / counter PRAGMAs ----
  Probe('user_version default',          '', 'PRAGMA user_version');
  Probe('user_version round-trip',       'PRAGMA user_version=42', 'PRAGMA user_version');
  Probe('application_id default',        '', 'PRAGMA application_id');
  Probe('application_id round-trip',     'PRAGMA application_id=1234567', 'PRAGMA application_id');
  Probe('schema_version default',        '', 'PRAGMA schema_version');
  Probe('data_version default',          '', 'PRAGMA data_version');
  Probe('freelist_count default',        '', 'PRAGMA freelist_count');

  // ---- introspection PRAGMAs (only first int / text col compared) ----
  Probe('table_info one row',
        'CREATE TABLE t(a INT, b TEXT)',
        'SELECT count(*) FROM pragma_table_info(''t'')');             // 2
  Probe('table_xinfo',
        'CREATE TABLE t(a INT, b TEXT)',
        'SELECT count(*) FROM pragma_table_xinfo(''t'')');            // 2
  Probe('index_list count',
        'CREATE TABLE t(a UNIQUE, b)',
        'SELECT count(*) FROM pragma_index_list(''t'')');             // 1
  Probe('foreign_key_list',
        'CREATE TABLE p(id INTEGER PRIMARY KEY); CREATE TABLE c(p REFERENCES p(id))',
        'SELECT count(*) FROM pragma_foreign_key_list(''c'')');       // 1
  Probe('database_list',
        '',
        'SELECT count(*) FROM pragma_database_list');                 // >=1
  Probe('collation_list',
        '',
        'SELECT count(*) FROM pragma_collation_list');                // 3 (BINARY,RTRIM,NOCASE)
  Probe('function_list',
        '',
        'SELECT count(*) >= 50 FROM pragma_function_list');           // many
  Probe('module_list',
        '',
        'SELECT count(*) >= 0 FROM pragma_module_list');              // 1 if any
  Probe('pragma_list',
        '',
        'SELECT count(*) >= 30 FROM pragma_pragma_list');             // many

  // ---- compile_options ----
  Probe('compile_options',
        '',
        'SELECT count(*) >= 1 FROM pragma_compile_options');

  // ---- integrity / quick check ----
  Probe('integrity_check ok',
        'CREATE TABLE t(a)',
        'PRAGMA integrity_check');                                    // "ok"
  Probe('quick_check ok',
        'CREATE TABLE t(a)',
        'PRAGMA quick_check');                                        // "ok"

  // ---- shrink / wal_checkpoint ----
  Probe('shrink_memory',
        '',
        'PRAGMA shrink_memory');

  WriteLn;
  WriteLn('Total divergences: ', diverged);
end.
