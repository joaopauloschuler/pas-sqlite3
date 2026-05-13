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
  DiagCommon;

begin
  // ---- Boolean / scalar PRAGMAs (read default, then round-trip) ----
  ProbeSetupCheck('foreign_keys default',          '', 'PRAGMA foreign_keys');
  ProbeSetupCheck('foreign_keys=ON',               'PRAGMA foreign_keys=ON',   'PRAGMA foreign_keys');
  ProbeSetupCheck('recursive_triggers default',    '', 'PRAGMA recursive_triggers');
  ProbeSetupCheck('recursive_triggers=ON',         'PRAGMA recursive_triggers=ON', 'PRAGMA recursive_triggers');
  ProbeSetupCheck('case_sensitive_like default',   '', 'PRAGMA case_sensitive_like');
  ProbeSetupCheck('reverse_unordered_selects',     '', 'PRAGMA reverse_unordered_selects');
  ProbeSetupCheck('defer_foreign_keys default',    '', 'PRAGMA defer_foreign_keys');
  ProbeSetupCheck('defer_foreign_keys=1',          'PRAGMA defer_foreign_keys=1','PRAGMA defer_foreign_keys');
  ProbeSetupCheck('writable_schema default',       '', 'PRAGMA writable_schema');
  ProbeSetupCheck('legacy_alter_table default',    '', 'PRAGMA legacy_alter_table');
  ProbeSetupCheck('legacy_file_format default',    '', 'PRAGMA legacy_file_format');
  ProbeSetupCheck('cell_size_check default',       '', 'PRAGMA cell_size_check');
  ProbeSetupCheck('automatic_index default',       '', 'PRAGMA automatic_index');
  ProbeSetupCheck('count_changes default',         '', 'PRAGMA count_changes');
  ProbeSetupCheck('full_column_names default',     '', 'PRAGMA full_column_names');
  ProbeSetupCheck('short_column_names default',    '', 'PRAGMA short_column_names');
  ProbeSetupCheck('checkpoint_fullfsync default',  '', 'PRAGMA checkpoint_fullfsync');
  ProbeSetupCheck('fullfsync default',             '', 'PRAGMA fullfsync');
  ProbeSetupCheck('ignore_check_constraints',      '', 'PRAGMA ignore_check_constraints');
  ProbeSetupCheck('query_only default',            '', 'PRAGMA query_only');
  ProbeSetupCheck('read_uncommitted default',      '', 'PRAGMA read_uncommitted');
  ProbeSetupCheck('secure_delete default',         '', 'PRAGMA secure_delete');
  ProbeSetupCheck('temp_store default',            '', 'PRAGMA temp_store');
  ProbeSetupCheck('threads default',               '', 'PRAGMA threads');
  ProbeSetupCheck('trusted_schema default',        '', 'PRAGMA trusted_schema');

  // ---- numeric / size PRAGMAs ----
  ProbeSetupCheck('page_size default',             '', 'PRAGMA page_size');
  ProbeSetupCheck('page_count fresh',              '', 'PRAGMA page_count');
  ProbeSetupCheck('max_page_count',                '', 'PRAGMA max_page_count');
  ProbeSetupCheck('cache_size default',            '', 'PRAGMA cache_size');
  ProbeSetupCheck('cache_spill default',           '', 'PRAGMA cache_spill');
  ProbeSetupCheck('mmap_size default',             '', 'PRAGMA mmap_size');
  ProbeSetupCheck('soft_heap_limit',               '', 'PRAGMA soft_heap_limit');
  ProbeSetupCheck('hard_heap_limit',               '', 'PRAGMA hard_heap_limit');
  ProbeSetupCheck('busy_timeout default',          '', 'PRAGMA busy_timeout');
  ProbeSetupCheck('analysis_limit default',        '', 'PRAGMA analysis_limit');
  ProbeSetupCheck('wal_autocheckpoint default',    '', 'PRAGMA wal_autocheckpoint');
  ProbeSetupCheck('journal_size_limit default',    '', 'PRAGMA journal_size_limit');

  // ---- string-valued PRAGMAs ----
  ProbeSetupCheck('encoding default',              '', 'PRAGMA encoding');
  ProbeSetupCheck('journal_mode default',          '', 'PRAGMA journal_mode');
  ProbeSetupCheck('locking_mode default',          '', 'PRAGMA locking_mode');
  ProbeSetupCheck('synchronous default',           '', 'PRAGMA synchronous');
  ProbeSetupCheck('auto_vacuum default',           '', 'PRAGMA auto_vacuum');

  // ---- header / counter PRAGMAs ----
  ProbeSetupCheck('user_version default',          '', 'PRAGMA user_version');
  ProbeSetupCheck('user_version round-trip',       'PRAGMA user_version=42', 'PRAGMA user_version');
  ProbeSetupCheck('application_id default',        '', 'PRAGMA application_id');
  ProbeSetupCheck('application_id round-trip',     'PRAGMA application_id=1234567', 'PRAGMA application_id');
  ProbeSetupCheck('schema_version default',        '', 'PRAGMA schema_version');
  ProbeSetupCheck('data_version default',          '', 'PRAGMA data_version');
  ProbeSetupCheck('freelist_count default',        '', 'PRAGMA freelist_count');

  // ---- introspection PRAGMAs (only first int / text col compared) ----
  ProbeSetupCheck('table_info one row',
        'CREATE TABLE t(a INT, b TEXT)',
        'SELECT count(*) FROM pragma_table_info(''t'')');             // 2
  ProbeSetupCheck('table_xinfo',
        'CREATE TABLE t(a INT, b TEXT)',
        'SELECT count(*) FROM pragma_table_xinfo(''t'')');            // 2
  ProbeSetupCheck('index_list count',
        'CREATE TABLE t(a UNIQUE, b)',
        'SELECT count(*) FROM pragma_index_list(''t'')');             // 1
  ProbeSetupCheck('foreign_key_list',
        'CREATE TABLE p(id INTEGER PRIMARY KEY); CREATE TABLE c(p REFERENCES p(id))',
        'SELECT count(*) FROM pragma_foreign_key_list(''c'')');       // 1
  ProbeSetupCheck('database_list',
        '',
        'SELECT count(*) FROM pragma_database_list');                 // >=1
  ProbeSetupCheck('collation_list',
        '',
        'SELECT count(*) FROM pragma_collation_list');                // 3 (BINARY,RTRIM,NOCASE)
  ProbeSetupCheck('function_list',
        '',
        'SELECT count(*) >= 50 FROM pragma_function_list');           // many
  ProbeSetupCheck('module_list',
        '',
        'SELECT count(*) >= 0 FROM pragma_module_list');              // 1 if any
  ProbeSetupCheck('pragma_list',
        '',
        'SELECT count(*) >= 30 FROM pragma_pragma_list');             // many

  // ---- compile_options ----
  ProbeSetupCheck('compile_options',
        '',
        'SELECT count(*) >= 1 FROM pragma_compile_options');

  // ---- integrity / quick check ----
  ProbeSetupCheck('integrity_check ok',
        'CREATE TABLE t(a)',
        'PRAGMA integrity_check');                                    // "ok"
  ProbeSetupCheck('quick_check ok',
        'CREATE TABLE t(a)',
        'PRAGMA quick_check');                                        // "ok"

  // ---- shrink / wal_checkpoint ----
  ProbeSetupCheck('shrink_memory',
        '',
        'PRAGMA shrink_memory');

  WriteLn;
  WriteLn('Total divergences: ', diverged);
end.
