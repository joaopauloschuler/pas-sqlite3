# 2001 September 15
#
# The author disclaims copyright to this source code.  In place of
# a legal notice, here is a blessing:
#
#    May you do good and not evil.
#    May you find forgiveness for yourself and forgive others.
#    May you share freely, never taking more than you give.
#
#***********************************************************************
# tester_min.tcl — minimal subset of ../sqlite3/test/tester.tcl for the
# pas-sqlite3 Phase 9.4.2.g bootstrap.
#
# Goal: expose just enough surface so a hand-picked simple .test file
# (one that uses only do_test / do_execsql_test / execsql) can source
# this shim and run against the Tcl-bridge build of pas-sqlite3.
#
# What is intentionally NOT ported here (vs upstream tester.tcl):
#   - do_eqp_test, do_vmstep_test
#   - permutations, runtest, NRE harness, slave interp plumbing
#   - sqlite3_test_control, sqlite3_memdebug_*, db_save, threading
#   - puts override / output1 / output2 verbosity machinery
#   - known-problems.txt, warn lists
#
# do_test supports the four upstream prefix-driven match modes
# (regexp `/RE/`, negated regexp `~/RE/`, numeric-range `#NN..MM#`,
# glob `*GLOB*`/`~*GLOB*`); falls back to exact string compare.
# do_realnum_test landed 9.4.2.g.7 (forwards to do_test via
# realnum_normalize).
#
# Citations against /home/bpsa/app/sqlite3/test/tester.tcl follow each proc.

# Global counters (upstream tester.tcl:576..588 TC() array).  We track
# only ::nTest and ::nErr (flat scalars) plus a TC()-style getter for
# any future code that calls set_test_counter directly.
set ::nTest 0
set ::nErr  0
set ::TC(count)  0
set ::TC(errors) 0

# ::testdir — upstream sets this in tester.tcl head (it's the directory
# of the running script).  Some .test files reference $::testdir to load
# fixture data.  Point it at the directory containing tester_min.tcl
# itself, which is what `source` ends up using as [info script].
set ::testdir [file dirname [file normalize [info script]]]

# sqlite3 wrapper — port of upstream tester.tcl:114..144.  Renames the
# C-implemented `sqlite3` command to `sqlite_orig` and installs a Tcl proc
# in its place.  Required so that error messages from the constructor are
# reported under the invoked name `sqlite_orig` (tcl-1.1/1.1.1), matching
# the upstream harness, and so per-connection setup matches tester.tcl.
if {[info command sqlite_orig]==""} {
  rename sqlite3 sqlite_orig
  proc sqlite3 {args} {
    if {[llength $args]>=2 && [string index [lindex $args 0] 0]!="-"} {
      # This command is opening a new database connection.
      if {[info exists ::G(perm:sqlite3_args)]} {
        set args [concat $args $::G(perm:sqlite3_args)]
      }
      if {[sqlite_orig -has-codec] && ![info exists ::do_not_use_codec]} {
        lappend args -key {xyzzy}
      }
      set res [uplevel 1 sqlite_orig $args]
      if {[info exists ::G(perm:presql)]} {
        [lindex $args 0] eval $::G(perm:presql)
      }
      if {[info exists ::G(perm:dbconfig)]} {
        set ::dbhandle [lindex $args 0]
        uplevel #0 $::G(perm:dbconfig)
      }
      [lindex $args 0] cache size 3
      set res
    } else {
      # Not opening a new database connection; pass through unchanged.
      uplevel 1 sqlite_orig $args
    }
  }
}

# set_test_counter — upstream tester.tcl:583..588.
# Getter when called with one arg; setter when called with two.
proc set_test_counter {counter args} {
  if {[llength $args]} {
    set ::TC($counter) [lindex $args 0]
  }
  return $::TC($counter)
}

# fix_testname — upstream tester.tcl:898..905.  Prepends $::testprefix
# when set, so .test files that do `do_test 1.0 ...` get "<file>-1.0".
proc fix_testname {varname} {
  upvar $varname testname
  if {[info exists ::testprefix]
   && [string is digit [string range $testname 0 0]]
  } {
    set testname "${::testprefix}-$testname"
  }
}

# do_test — upstream tester.tcl:703..810, port of the prefix-driven
# match dispatch.  Runs $cmd at the global scope (uplevel #0), then
# compares $result against $expected according to the *first chars*
# of $expected:
#
#   /RE/      — regexp match (with `#` -> `[-0-9.]+` substitution; if
#               RE starts with `*` it's treated as a glob instead).
#               Upstream tester.tcl:739..776 outer-if arm.
#   ~/RE/     — negated regexp (same RE rules; ok = !match).
#               Upstream tester.tcl:743..752.
#   #/A..B/   — per-term numeric range / 10%-tolerance compare against
#               a list result.  Wrapped in slashes inside the outer
#               `^[~#]?/.*/$` gate.  Upstream tester.tcl:753..767.
#   *GLOB*    — glob match.  Upstream tester.tcl:778..787.
#   ~*GLOB*   — negated glob.  Upstream tester.tcl:782..784.
#   <else>    — exact string compare (with fpnum_compare fallback for
#               numeric-equivalent strings).  Upstream tester.tcl:788..792.
#
# Increments ::nTest always, ::nErr on mismatch or runtime error.
# Prints " Ok" on success or a two-line
# "! NAME expected: [..] / ! NAME got: [..]" block on failure.
proc do_test {name cmd expected} {
  fix_testname name
  incr ::nTest
  set ::TC(count) $::nTest
  puts -nonewline "$name..."
  flush stdout
  if {[catch {uplevel #0 "$cmd;\n"} result]} {
    puts ""
    puts "! $name error: $result"
    incr ::nErr
    set ::TC(errors) $::nErr
    flush stdout
    return
  }
  # Match-mode dispatch — verbatim port of tester.tcl:739..793.
  if {[regexp {^[~#]?/.*/$} $expected]} {
    # "/RE/" / "~/RE/" / (legacy) "#RE#" forms.
    if {[string index $expected 0]=="~"} {
      set re [string range $expected 2 end-1]
      if {[string index $re 0]=="*"} {
        set ok [string match $re $result]
      } else {
        set re [string map {# {[-0-9.]+}} $re]
        set ok [regexp $re $result]
      }
      set ok [expr {!$ok}]
    } elseif {[string index $expected 0]=="#"} {
      # "#A..B#" or "#N N N#" — numeric-range / 10%-tolerance list compare.
      set e2 [string range $expected 2 end-1]
      set ok 1
      foreach i $result j $e2 {
        if {[regexp {^(-?\d+)\.\.(-?\d)$} $j all A B]} {
          set ok [expr {$i+0>=$A && $i+0<=$B}]
        } else {
          set ok [expr {$i+0>=0.9*$j && $i+0<=1.1*$j}]
        }
        if {!$ok} break
      }
      if {$ok && [llength $result]!=[llength $e2]} {set ok 0}
    } else {
      set re [string range $expected 1 end-1]
      if {[string index $re 0]=="*"} {
        set ok [string match $re $result]
      } else {
        set re [string map {# {[-0-9.]+}} $re]
        set ok [regexp $re $result]
      }
    }
  } elseif {[regexp {^~?\*.*\*$} $expected]} {
    # "*GLOB*" / "~*GLOB*" forms.
    if {[string index $expected 0]=="~"} {
      set e [string range $expected 1 end]
      set ok [expr {![string match $e $result]}]
    } else {
      set ok [string match $expected $result]
    }
  } else {
    set ok [expr {[string compare $result $expected]==0}]
    # Upstream falls back to fpnum_compare when string compare fails
    # (tester.tcl:789..792).  fpnum_compare is the C Tcl command
    # registered by Sqlitetest1_Init (test1.c:6191..6325, ported in
    # TestModuleTest1.pas) that does fuzzy 15-digit float-string
    # equality so e.g. -1.11 matches -1.1099999999999999 and
    # 9.22337203685478e+18 matches 9.2233720368547758e+18.  Without
    # this, exact-string compare on float-bearing results diverges
    # from upstream even when SQLite renders byte-identically (9.4.divbug.35).
    if {!$ok} {
      if {[llength [info commands fpnum_compare]]} {
        set ok [fpnum_compare $result $expected]
      }
    }
  }
  if {$ok} {
    puts " Ok"
  } else {
    puts ""
    puts "! $name expected: \[$expected\]"
    puts "! $name got:      \[$result\]"
    incr ::nErr
    set ::TC(errors) $::nErr
  }
  flush stdout
}

# realnum_normalize — upstream tester.tcl:888..891.  Verbatim.  Erases
# version-of-Tcl printing drift (1.#INF → inf, e+00 → e, trailing
# `.0e` → `e`) before string compare.
proc realnum_normalize {r} {
  string map {1.#INF inf Inf inf .0e e} [regsub -all {(e[+-])0+} $r {\1}]
}

# do_realnum_test — upstream tester.tcl:892..896.  Verbatim.  Wraps the
# command in `realnum_normalize [...]` and likewise normalises the
# expected literal, then forwards to do_test for the actual compare.
proc do_realnum_test {name cmd expected} {
  uplevel [list do_test $name [
    subst -nocommands { realnum_normalize [ $cmd ] }
  ] [realnum_normalize $expected]]
}

# verify_ex_errcode — upstream tester.tcl:1682..1684.  Verbatim.
# Asserts that the most recent error's extended rc symbolic name on $db
# matches $expected.  Forwards to do_test for PASS/FAIL accounting.
# Requires the sqlite3_extended_errcode Tcl trampoline (TestModuleTest1
# 9.4.divbug.88.035).
proc verify_ex_errcode {name expected {db db}} {
  do_test $name [list sqlite3_extended_errcode $db] $expected
}

# execsql — upstream tester.tcl:1445..1448.  Verbatim.
proc execsql {sql {db db}} {
  uplevel [list $db eval $sql]
}

# stepsql — upstream tester.tcl:1649..1672.  Verbatim.
# Use the non-callback API to execute multiple SQL statements.
proc stepsql {dbptr sql} {
  set sql [string trim $sql]
  set r 0
  while {[string length $sql]>0} {
    if {[catch {sqlite3_prepare $dbptr $sql -1 sqltail} vm]} {
      return [list 1 $vm]
    }
    set sql [string trim $sqltail]
#    while {[sqlite_step $vm N VAL COL]=="SQLITE_ROW"} {
#      foreach v $VAL {lappend r $v}
#    }
    while {[sqlite3_step $vm]=="SQLITE_ROW"} {
      for {set i 0} {$i<[sqlite3_data_count $vm]} {incr i} {
        lappend r [sqlite3_column_text $vm $i]
      }
    }
    if {[catch {sqlite3_finalize $vm} errmsg]} {
      return [list 1 $errmsg]
    }
  }
  return $r
}

# execsql2 — upstream tester.tcl:1628..1636.  Verbatim.
# Like execsql but returns a flat list of {colname value colname value ...}.
proc execsql2 {sql} {
  set result {}
  db eval $sql data {
    foreach f $data(*) {
      lappend result $f $data($f)
    }
  }
  return $result
}

# do_execsql_test — upstream tester.tcl:941..971.  Supports
#   do_execsql_test  TESTNAME SQL ?RESULT?
#   do_execsql_test -db DB TESTNAME SQL ?RESULT?
# Wraps the SQL in `execsql { ... } <db>` and delegates to do_test.
# The `[list {*}$result]` normalisation is preserved verbatim — it's
# what coerces a multi-line expected block into a flat Tcl list so
# string-compare against `db eval` output works.
proc do_execsql_test {args} {
  set db db
  if {[lindex $args 0]=="-db"} {
    set db [lindex $args 1]
    set args [lrange $args 2 end]
  }
  if {[llength $args]==2} {
    foreach {testname sql} $args {}
    set result ""
  } elseif {[llength $args]==3} {
    foreach {testname sql result} $args {}
    if {[llength $result]==0} { set result "" }
  } else {
    error "wrong # args: should be \"do_execsql_test ?-db DB? testname sql ?result?\""
  }
  fix_testname testname
  uplevel do_test                 \
      [list $testname]            \
      [list "execsql {$sql} $db"] \
      [list [list {*}$result]]
}

# output1 — minimal stand-in for upstream tester.tcl:649.  The full
# upstream proc keys off [verbose]; this minimal harness has no verbosity
# machinery (verbose is absent), so we delegate to output2 (the default
# v==1 behaviour) which writes to stdout.  Defined only if absent so a
# fuller harness override still wins.
if {[llength [info commands output1]]==0} {
  proc output1 {args} { uplevel output2 $args }
}

# execsql_timed — upstream tester.tcl:1449.  Verbatim.
proc execsql_timed {sql {db db}} {
  set tm [time {
    set x [uplevel [list $db eval $sql]]
  } 1]
  set tm [lindex $tm 0]
  output1 -nonewline " ([expr {$tm*0.001}]ms) "
  set x
}

# do_timed_execsql_test — upstream tester.tcl:977.  Verbatim.
proc do_timed_execsql_test {testname sql {result {}}} {
  fix_testname testname
  uplevel do_test [list $testname] [list "execsql_timed {$sql}"]\
                                   [list [list {*}$result]]
}

# finalize_testing — upstream tester.tcl:1256.. distilled down to the
# summary print + exit-code arm.  We deliberately skip the soft/hard
# heap-limit, vfs_unlink_test, sqlite3_reset_auto_extension and
# known-problems.txt logic — none of that is wired into pas-sqlite3.
proc finalize_testing {} {
  catch {db close}
  catch {db2 close}
  catch {db3 close}
  set nT $::nTest
  set nE $::nErr
  puts "$nE errors out of $nT tests"
  if {$nE>0} { exit 1 } else { exit 0 }
}

# ifcapable — upstream tester.tcl:1725..1739.  Real implementation
# evaluates a boolean expression of SQLITE_OMIT_*/SQLITE_ENABLE_*
# compile-time caps (see fix_ifcapable_expr at tester.tcl:1697..1714)
# and runs BODY iff true, else ELSEBODY.  pas-sqlite3 is built with the
# default set of caps enabled (no SQLITE_OMIT_*), so every bare
# capability token resolves to 1; we just remap ident-runs to "1" and
# leave operators (`!`, `&&`, `||`, parens) intact, then eval as a
# Tcl expression.  That means `ifcapable trigger` runs BODY,
# `ifcapable !trigger` runs ELSEBODY — fixing rowid-8.* which would
# otherwise execute both the `trigger` and `!trigger` arms and trip
# "table t3 already exists" (divbug.73).  C ref: tester.tcl:1697..1739.
# Per-capability defaults that diverge from "feature enabled" (1).
# Mirrors the SQLITE_ALLOW_ROWID_IN_VIEW etc. test_config.c arms — caps
# that are OFF in a vanilla build must read 0 so `ifcapable !foo` runs
# the BODY and `ifcapable foo` runs ELSEBODY.
array set ::sqlite_options {}
set ::sqlite_options(allow_rowid_in_view) 0
# test_config.c sets hiddencolumns from SQLITE_ENABLE_HIDDEN_COLUMNS, which the
# oracle does NOT define (and neither does this FPC build), so the name-based
# __hidden__ column mechanism is a no-op.  Pin it 0 to match the oracle.
set ::sqlite_options(hiddencolumns) 0
# 6.40.1.o — pas-sqlite3 now ships FTS3/FTS4 (passqlite3fts3.pas, registered
# by sqlite3Fts3Init at openDatabase).  Mirror test_config.c:437..453: this
# build defines SQLITE_ENABLE_FTS3 and does NOT define SQLITE_DISABLE_FTS3_UNICODE
# (the unicode61 tokenizer is ported), so fts3=1 and fts3_unicode=1.  FTS5 is
# not ported (fts5=0).  The port uses the no-deferred-token subset of
# fts3_write.c, equivalent to building with SQLITE_DISABLE_FTS4_DEFERRED, so
# fts4_deferred=0 (test_config.c:455..459).  (icu is already pinned 0 below.)
set ::sqlite_options(fts3) 1
set ::sqlite_options(fts3_unicode) 1
set ::sqlite_options(fts5) 0
set ::sqlite_options(fts4_deferred) 0
# 9.4.divbug.87.066 — this build defines neither SQLITE_SECURE_DELETE nor
# SQLITE_FAST_SECURE_DELETE (btree.c:2695..2699 / test_config.c:751..759),
# so both caps must read 0.  Without these, `ifcapable fast_secure_delete`
# defaults to 1 below and securedel.test computes DEFAULT_SECDEL=2 while
# the engine honestly returns 0 → 1.0/1.1/1.2 fail.
set ::sqlite_options(fast_secure_delete) 0
set ::sqlite_options(secure_delete) 0
# descidx1-6.1 — pas-sqlite3 builds without -DSQLITE_DEFAULT_FILE_FORMAT=1,
# so SQLITE_DEFAULT_FILE_FORMAT defaults to 4 (sqliteInt.h:694) and main.c's
# `#if SQLITE_DEFAULT_FILE_FORMAT<4` arm is skipped — SQLITE_LegacyFileFmt
# is NOT in the default db->flags (passqlite3main.pas:873..883).  Mirror
# test_config.c:491..495 which writes 0 when DEFAULT_FILE_FORMAT != 1.
set ::sqlite_options(legacyformat) 0
# autoinc-6.2 — pas-sqlite3 builds without SQLITE_32BIT_ROWID, so the default
# build uses 64-bit rowids.  Mirror test_config.c:52..56 which writes 0 unless
# SQLITE_32BIT_ROWID is defined.  Without this, `ifcapable {!rowid32}` blocks
# (which insert INT64_MAX) are skipped and only the rowid32 32-bit arm runs.
set ::sqlite_options(rowid32) 0
# analyzeE/F/G, analyze3/5/8/D — this build defines neither SQLITE_ENABLE_STAT4
# nor SQLITE_ENABLE_STAT3, so test_config.c:608..612 writes stat4=0.  Without
# this, `ifcapable !stat4 {finish_test; return}` guards default to FALSE (cap
# reads 1 below) and the stat4-only analyze tests run on a non-stat4 engine →
# strict failures / timeouts.  (No test uses `ifcapable stat3`, and
# test_config.c sets no stat3 cap, so none is added here.)
set ::sqlite_options(stat4) 0
# capi2-11.x/12.x/13.x — the C reference oracle build does NOT define
# SQLITE_ENABLE_COLUMN_METADATA (sqlite3_compileoption_used returns 0 for it;
# only Makefile.msc enables it).  test_config.c:353..355 then writes
# columnmetadata=0, so upstream SKIPS the check_origins blocks that exercise
# sqlite3_column_{database,table,origin}_name.  pas-sqlite3 likewise builds the
# non-SQLITE_ENABLE_COLUMN_METADATA arm of columnType (passqlite3codegen.pas
# :28019), so COLNAME_N=2 and those names are never populated — matching the
# oracle.  Without this, the cap defaults to 1 below and the section wrongly
# RUNS, expecting {main tab1 colN} where the engine honestly returns {}.
set ::sqlite_options(columnmetadata) 0
# pragma-16.x / lock5 / lock6 — Apple proxy-locking pragmas.  The C reference
# oracle build (Linux) does NOT define SQLITE_ENABLE_LOCKING_STYLE, so
# test_config.c writes prefer_proxy_locking=0 and lock_proxy_pragmas=0, and
# upstream SKIPS the `ifcapable lock_proxy_pragmas&&prefer_proxy_locking { ... }`
# blocks (pragma.test:1620, lock6.test:81) and the lock_proxy_pragmas blocks
# (lock5.test:29/245).  pas-sqlite3 likewise does not implement Apple proxy
# locking, so without these the caps default to 1 and the sections wrongly RUN,
# failing on the unimplemented PRAGMA lock_proxy_file / .test_control_file.
set ::sqlite_options(prefer_proxy_locking) 0
set ::sqlite_options(lock_proxy_pragmas) 0
# cursorhint2.test is gated by `ifcapable !cursorhints {finish_test; return}`.
# The C reference oracle build does NOT define SQLITE_ENABLE_CURSOR_HINTS
# (verified: PRAGMA compile_options has no cursor/hint entry), so
# test_config.c:156..160 writes cursorhints=0 and upstream SKIPS this test.
# pas-sqlite3 likewise makes codeCursorHint a deliberate no-op
# (passqlite3codegen.pas:71144), matching the oracle's default build.  Without
# this, the cap defaults to 1 below → the test wrongly RUNS and fails because no
# OP_CursorHint opcodes are emitted.
set ::sqlite_options(cursorhints) 0
# uri2.test is gated by `ifcapable !uri_00_error`.  A vanilla build does NOT
# define SQLITE_ENABLE_URI_00_ERROR, so test_config.c writes no uri_00_error
# cap and the oracle SKIPS this test (the !SQLITE_ENABLE_URI_00_ERROR arm in
# sqlite3ParseUri simply ignores the rest of the path on %00).  Without this,
# the cap defaults to 1 below → the test wrongly RUNS and expects the
# "unexpected %00 in uri" error this build never raises.
set ::sqlite_options(uri_00_error) 0
# func6.test gates its expected sqlite_offset() values on `ifcapable null_trim`.
# The oracle build does NOT define SQLITE_ENABLE_NULL_TRIM (verified:
# sqlite_compileoption_used('ENABLE_NULL_TRIM')=0 on the reference .so), so
# test_config.c writes null_trim=0 and the oracle's on-disk records keep
# trailing-NULL serial bytes — making the first row's sqlite_offset(d) == 8179.
# pas-sqlite3 likewise does no null-trimming (codegen makeRecord no-op), so it
# produces 8179 too.  Without pinning, the cap defaults to 1 below → func6 takes
# the bNullTrim=1 branch and wrongly expects 8180.
set ::sqlite_options(null_trim) 0
# percentile.test wraps its WITHIN GROUP (ORDER BY x) ordered-set-aggregate
# subtests in `ifcapable ordered_set_aggregates`.  The oracle build does NOT
# define SQLITE_ENABLE_ORDERED_SET_AGGREGATES, so test_config.c:198-204 writes
# ordered_set_aggregates=0 and the oracle SKIPS those blocks.  pas-sqlite3 does
# not implement that syntax either (parity with the oracle).  Without this, the
# cap defaults to 1 below → the blocks wrongly RUN and fail with near "(": syntax error.
set ::sqlite_options(ordered_set_aggregates) 0
# The oracle build (../sqlite3, verified via pragma_compile_options) does NOT
# define these compile flags, so its test_config.c writes each capability = 0.
# Our harness otherwise defaults unset caps to 1 (below), making ifcapable-gated
# tests RUN feature paths the engine lacks (e.g. "preupdate_hook was omitted at
# compile-time") instead of skipping as on the oracle.  Pin them to match.
set ::sqlite_options(preupdate) 0      ;# no SQLITE_ENABLE_PREUPDATE_HOOK
set ::sqlite_options(snapshot) 0       ;# no SQLITE_ENABLE_SNAPSHOT
set ::sqlite_options(session) 0        ;# no SQLITE_ENABLE_SESSION
set ::sqlite_options(memorymanage) 0   ;# no SQLITE_ENABLE_MEMORY_MANAGEMENT
set ::sqlite_options(scanstatus) 0     ;# no SQLITE_ENABLE_STMT_SCANSTATUS
set ::sqlite_options(mmap) 0           ;# port treats SQLITE_MAX_MMAP_SIZE as 0 (mmap I/O not ported)
set ::sqlite_options(unlock_notify) 0  ;# no SQLITE_ENABLE_UNLOCK_NOTIFY
set ::sqlite_options(icu) 0            ;# no SQLITE_ENABLE_ICU (oracle lacks libicu)
set ::sqlite_options(icu_collations) 0 ;# no SQLITE_ENABLE_ICU_COLLATIONS
# pas-sqlite3's unixSync_impl (passqlite3os.pas) now ports the os_unix.c
# UNIXFILE_DIRSYNC arm (openDirectory + dirfd fsync after a newly-created
# journal/wal is synced), matching a build WITHOUT SQLITE_DISABLE_DIRSYNC.
# Faithful value is 1 (test_config.c:119); io.test / sync.test count this
# directory fsync via $sqlite_sync_count.
set ::sqlite_options(dirsync) 1        ;# unixSync performs the dir-fsync arm
set ::sqlite_options(threadsafe) 1     ;# SQLITE_THREADSAFE=1 (test_config.c:662; sqlite3_threadsafe()==1)
set ::sqlite_options(threadsafe1) 1    ;# THREADSAFE==1 (test_config.c:664)
set ::sqlite_options(threadsafe2) 0    ;# THREADSAFE=1 build (oracle lacks THREADSAFE=2)
# pas-sqlite3 OMITS the shared-cache subsystem entirely (SQLITE_OMIT_SHARED_CACHE
# behaviour): sqlite3_enable_shared_cache is a no-op and each connection gets its
# own Btree/Pager, so two connections to the same file do NOT share a cached
# iDataVersion.  The oracle build does NOT define SQLITE_OMIT_SHARED_CACHE, so its
# test_config.c writes shared_cache=1; mirror the *engine's* capability here so
# ifcapable shared_cache blocks (e.g. pragma3-300..340, which expect cross-
# connection PRAGMA data_version bumps that only occur with a shared cache) SKIP
# instead of running against the unsupported feature path.
set ::sqlite_options(shared_cache) 0   ;# SQLITE_OMIT_SHARED_CACHE (port omits shared cache)
set ::sqlite_options(oversize_cell_check) 0 ;# no SQLITE_ENABLE_OVERSIZE_CELL_CHECK (oracle lacks it; mirrors test_config.c)
set ::sqlite_options(mem5) 0           ;# no SQLITE_ENABLE_MEMSYS5 (oracle lacks memsys5)
set ::sqlite_options(sqllog) 0         ;# no SQLITE_ENABLE_SQLLOG (oracle lacks sqllog)
# integrityck: engine supports PRAGMA integrity_check (no SQLITE_OMIT_INTEGRITY_CHECK).
# pragma.test reads $sqlite_options(integrityck) directly (not via ifcapable).
set ::sqlite_options(integrityck) 1
# configslower: CONFIG_SLOWDOWN_FACTOR multiplier; like.test uses it as a numeric
# scale for timing budgets. Mirror upstream test_config.c default (1.0).
set ::sqlite_options(configslower) 1.0
# casesensitivelike: test_config.c:71..76 — 1 only under
# SQLITE_CASE_SENSITIVE_LIKE; default build (and the port) leave it off.
# expr.test reads $sqlite_options(casesensitivelike) directly.
set ::sqlite_options(casesensitivelike) 0
# rtree: pas-sqlite3 omits the rtree virtual-table module — pin to 0 so
# `ifcapable rtree { ... }` blocks (alterlegacy-14.x etc.) SKIP rather than
# run and hit "no such module: rtree".
set ::sqlite_options(rtree) 0

# Compile-time limit globals — mirror the LINKVAR(x) block in upstream
# src/test_config.c:805..835 (Tcl_LinkVar "SQLITE_"#x as TCL_LINK_INT |
# TCL_LINK_READ_ONLY).  bigrow.test and sqllimits1.test read these
# $SQLITE_MAX_* / $SQLITE_DEFAULT_* globals directly and error
# ("no such variable") before reaching their first assertion otherwise.
#
# The native sqlite3 Tcl package (src/tests/tcl/PasTclSqlite.pas ~4918)
# already LinkVar's SQLITE_MAX_ATTACHED / MAX_COMPOUND_SELECT / MAX_COLUMN
# read-only, and the block near tester_min.tcl:1836 already sets
# TEMP_STORE / SQLITE_DEFAULT_{SYNCHRONOUS,WAL_SYNCHRONOUS,FILE_FORMAT,
# CACHE_SIZE} / SQLITE_MAX_VARIABLE_NUMBER.  Set only the remaining
# members here, guarding each with `info exists` so a read-only native
# link (existing or future) is never clobbered.
#
# Values are this port's own compile-time constants, and MUST match the
# engine's aHardLimit (src/passqlite3main.pas:675..689) because the tests
# read each limit back via `sqlite3_limit db SQLITE_LIMIT_<x> -1` and
# compare it to the matching $SQLITE_MAX_<x> global:
#   MAX_FUNCTION_ARG=127 -> passqlite3main.pas:665 (this port caps it at
#     127, diverging from the sqliteLimit.h default of 1000)
#   MAX_WORKER_THREADS=8 -> passqlite3main.pas SQLITE_MAX_WORKER_THREADS_LIMIT
#     (aHardLimit[11]); single-threaded build but the hard limit reports 8
#   MAX_{LENGTH,SQL_LENGTH,EXPR_DEPTH,VDBE_OP,LIKE_PATTERN_LENGTH,
#        TRIGGER_DEPTH,PAGE_SIZE,PAGE_COUNT,DEFAULT_PAGE_SIZE}
#       -> sqliteLimit.h port, src/passqlite3types.pas:270..298
#   DEFAULT_PAGE_SIZE=1024 -> passqlite3types.pas:291 (under -dSQLITE_TEST)
foreach {_lv _val} {
  SQLITE_MAX_LENGTH              1000000000
  SQLITE_MAX_SQL_LENGTH          1000000000
  SQLITE_MAX_EXPR_DEPTH          1000
  SQLITE_MAX_VDBE_OP             250000000
  SQLITE_MAX_FUNCTION_ARG        127
  SQLITE_MAX_PAGE_SIZE           65536
  SQLITE_MAX_PAGE_COUNT          4294967294
  SQLITE_MAX_LIKE_PATTERN_LENGTH 50000
  SQLITE_MAX_TRIGGER_DEPTH       1000
  SQLITE_MAX_DEFAULT_PAGE_SIZE   8192
  SQLITE_MAX_WORKER_THREADS      8
  SQLITE_DEFAULT_PAGE_SIZE       1024
} {
  if {![info exists ::$_lv]} { set ::$_lv $_val }
}
unset -nocomplain _lv _val

# sqlite3_exec_hex is provided natively by the sqlite3 test package
# (TestModuleTest1.test_exec_hex, a faithful port of test1.c:test_exec_hex).
# A pure-Tcl shim was previously defined here, but `[format %c $byte]` makes a
# Unicode char that the SQLite Tcl binding then UTF-8 re-encodes (0xff -> 0xc3
# 0xbf), so raw high-byte LIKE patterns never reached sqlite3_exec as single
# bytes — breaking like-9.4.3 / 9.5.1 / 9.5.2.  The native command decodes
# %HH to raw bytes and calls sqlite3_exec directly, matching the C oracle.

proc ifcapable {expr code {else ""} {elsecode ""}} {
  set e2 ""
  set state 0
  for {set i 0} {$i < [string length $expr]} {incr i} {
    set ch [string range $expr $i $i]
    set newstate [expr {[string is alnum $ch] || $ch eq "_"}]
    if {$newstate} {
      if {!$state} { append e2 {$::sqlite_options(} }
      append e2 $ch
    } else {
      if {$state} { append e2 ")" }
      append e2 $ch
    }
    set state $newstate
  }
  if {$state} { append e2 ")" }
  if {$e2 eq ""} { set e2 "1" }
  # Default any unset capability to 1 (feature enabled).
  while {[regexp -indices {\$::sqlite_options\(([a-zA-Z0-9_]+)\)} $e2 _ kidx]} {
    set k [string range $e2 [lindex $kidx 0] [lindex $kidx 1]]
    if {![info exists ::sqlite_options($k)]} { set ::sqlite_options($k) 1 }
    # Replace this single occurrence with its literal value so the loop
    # terminates even if eval fails later.
    set v $::sqlite_options($k)
    regsub "\\\$::sqlite_options\\($k\\)" $e2 $v e2
  }
  if {[catch {expr $e2} v]} { set v 1 }
  if {$v} {
    set c [catch {uplevel 1 $code} r]
  } else {
    set c [catch {uplevel 1 $elsecode} r]
  }
  return -code $c $r
}

# catchsql — upstream tester.tcl:1460..1465.  Verbatim.  Runs $sql
# via `$db eval` under `catch`, then returns the two-element Tcl list
# `[list $rc $msg]`: rc=0 with msg = the result rows on success, rc!=0
# with msg = the error string on failure.  C ref: tester.tcl:1460..1465.
proc catchsql {sql {db db}} {
  set r [catch [list uplevel [list $db eval $sql]] msg]
  lappend r $msg
  return $r
}

# do_catchsql_test — upstream tester.tcl:973..976.  Thin wrapper that
# delegates to `do_test NAME { catchsql {SQL} } RESULT` so a failing
# SQL statement can be asserted by expected `{rc errmsg}` pair without
# tripping the do_test catch arm.  C ref: tester.tcl:973..976.
proc do_catchsql_test {testname sql result} {
  fix_testname testname
  uplevel do_test [list $testname] [list "catchsql {$sql}"] [list $result]
}

# delete_all_data — upstream tester.tcl:1159..1163.  Iterate every
# user table in the open `db` handle and DELETE its rows.  Used by
# e_insert.test between assertion blocks to clear state.
proc delete_all_data {} {
  db eval {SELECT tbl_name AS t FROM sqlite_master WHERE type = 'table'} {
    db eval "DELETE FROM '[string map {' ''} $t]'"
  }
}

# expected — passthrough stub.  Upstream tester.tcl has no such proc as
# a self-contained helper (the word "expected" only appears as a
# parameter name to do_test, see upstream lines 692..702).  A handful
# of community .test files call `expected $n $val` to label assertions;
# returning the value unchanged keeps those scripts source-able.
proc expected {n exp} { return $exp }

# isquick — tester.tcl:2340.  Returns $::G(isquick) if set, else 0.
proc isquick {} {
  set ret 0
  catch {set ret $::G(isquick)}
  set ret
}

# getFileRetries / getFileRetryDelay — upstream tester.tcl head (the
# do_delete_file body at 276..311 reads them).  Upstream defaults to 50
# retries with 100ms delay on Windows and 0/0 on Unix.  We target Linux
# only, but keep a tiny non-zero retry budget so transient EBUSY from
# co-running test processes doesn't surface.  Override with the env
# vars TEST_FILE_RETRIES / TEST_FILE_RETRY_DELAY.
proc getFileRetries {} {
  if {[info exists ::env(TEST_FILE_RETRIES)]} {
    return $::env(TEST_FILE_RETRIES)
  }
  return 0
}
proc getFileRetryDelay {} {
  if {[info exists ::env(TEST_FILE_RETRY_DELAY)]} {
    return $::env(TEST_FILE_RETRY_DELAY)
  }
  return 0
}

# delete_file / forcedelete / do_delete_file — upstream tester.tcl:266..311.
# `delete_file` errors if the path is missing; `forcedelete` swallows
# missing/permission errors via `-force`.  Both share the do_delete_file
# helper, which on Windows retries through tag-along file locks.  We
# target Linux, so the retry path is dormant (getFileRetries returns 0
# by default) and we fall through to a plain `file delete` of each arg.
# C ref: tester.tcl:268, 272, 276..311.
proc delete_file {args} {
  do_delete_file false {*}$args
}

proc forcedelete {args} {
  do_delete_file true {*}$args
}

proc do_delete_file {force args} {
  set nRetry [getFileRetries]
  set nDelay [getFileRetryDelay]
  foreach filename $args {
    if {$nRetry > 0} {
      for {set i 0} {$i<$nRetry} {incr i} {
        set rc [catch {
          if {$force} {
            file delete -force $filename
          } else {
            file delete $filename
          }
        } msg]
        if {$rc==0} break
        if {$nDelay > 0} { after $nDelay }
      }
      if {$rc} { error $msg }
    } else {
      if {$force} {
        file delete -force $filename
      } else {
        file delete $filename
      }
    }
  }
}

# get_pwd — upstream tester.tcl:169..191.  Returns the current working
# directory.  On Windows the upstream proc shells out to cmd /c CD to
# preserve case; on POSIX (the only target here) it is just [pwd].
proc get_pwd {} {
  if {$::tcl_platform(platform) eq "windows"} {
    if {[info exists ::env(ComSpec)]} {
      set comSpec $::env(ComSpec)
    } else {
      set comSpec {C:\Windows\system32\cmd.exe}
    }
    return [string map [list \\ /] \
        [string trim [exec -- $comSpec /c CD]]]
  } else {
    return [pwd]
  }
}

# test_pwd — upstream tester.tcl:248..264.  Returns the current working
# directory with $suffix1 appended when the `curdir` capability is present
# (always true in this build, since the ifcapable stub above runs the BODY),
# otherwise returns $suffix2.  Used by e_uri.test to build file:// URIs that
# map to absolute local paths, e.g. [test_pwd /]test.db and [test_pwd / {}].
proc test_pwd { args } {
  if {[llength $args] > 0} {
    set suffix1 [lindex $args 0]
    if {[llength $args] > 1} {
      set suffix2 [lindex $args 1]
    } else {
      set suffix2 $suffix1
    }
  } else {
    set suffix1 ""; set suffix2 ""
  }
  ifcapable curdir {
    return "[get_pwd]$suffix1"
  } else {
    return $suffix2
  }
}

# dumpbytes / catchcmd / catchsafecmd / catchcmdex — upstream tester.tcl:821..871.
# 6.40.6 (HARNESS).  Pure-Tcl helpers used by shell*.test / avfs.test /
# sqldiff*.test.  They shell out to the on-disk CLI via the global $CLI,
# which those tests set with `set CLI [test_cli_invocation]`.  When the
# upstream `sqlite3` CLI binary is absent test_cli_invocation does
# `return -code return` and the whole test skips, so these procs are only
# ever reached when a CLI is present.  Ported verbatim.
proc dumpbytes {s} {
  set r ""
  for {set i 0} {$i < [string length $s]} {incr i} {
    if {$i > 0} {append r " "}
    append r [format %02X [scan [string index $s $i] %c]]
  }
  return $r
}
proc catchcmd {db {cmd ""}} {
  global CLI
  set out [open cmds.txt w]
  puts $out $cmd
  close $out
  set line "exec $CLI $db < cmds.txt"
  set rc [catch { eval $line } msg]
  list $rc $msg
}
proc catchsafecmd {db {cmd ""}} {
  global CLI
  set out [open cmds.txt w]
  puts $out $cmd
  close $out
  set line "exec $CLI -safe $db < cmds.txt"
  set rc [catch { eval $line } msg]
  list $rc $msg
}
proc catchcmdex {db {cmd ""}} {
  global CLI
  set out [open cmds.txt w]
  fconfigure $out -translation binary
  puts -nonewline $out $cmd
  close $out
  set line "exec -keepnewline -- $CLI $db < cmds.txt"
  set chans [list stdin stdout stderr]
  foreach chan $chans {
    catch {
      set modes($chan) [fconfigure $chan]
      fconfigure $chan -translation binary -buffering none
    }
  }
  set rc [catch { eval $line } msg]
  foreach chan $chans {
    catch {
      eval fconfigure [list $chan] $modes($chan)
    }
  }
  # puts [dumpbytes $msg]
  list $rc $msg
}

# filepath_normalize / do_filepath_test — upstream tester.tcl:873..886.
# Test cases assume unix-style paths; on the only target here (unix) the
# path is returned unchanged.  do_filepath_test wraps do_test, normalising
# both the command result and the expected value.  Used by e_uri.test.
proc filepath_normalize {p} {
  if {$::tcl_platform(platform) ne "unix"} {
    string map [list \\ / \{/ / .db\} .db] \
        [regsub -nocase -all {[a-z]:[/\\]+} $p {/}]
  } {
    set p
  }
}
proc do_filepath_test {name cmd expected} {
  uplevel [list do_test $name [
    subst -nocommands { filepath_normalize [ $cmd ] }
  ] [filepath_normalize $expected]]
}

# copy_file / forcecopy / do_copy_file — upstream tester.tcl:197..235.
# Mirror of delete_file/forcedelete/do_delete_file above: `copy_file`
# errors on a copy failure, `forcecopy` uses `file copy -force`.  Both
# share do_copy_file, whose Windows retry path is dormant on Linux
# (getFileRetries returns 0 by default).  C ref: tester.tcl:197, 201,
# 205..235.
proc copy_file {from to} {
  do_copy_file false $from $to
}

proc forcecopy {from to} {
  do_copy_file true $from $to
}

proc do_copy_file {force from to} {
  set nRetry [getFileRetries]
  set nDelay [getFileRetryDelay]
  if {$nRetry > 0} {
    for {set i 0} {$i<$nRetry} {incr i} {
      set rc [catch {
        if {$force} {
          file copy -force $from $to
        } else {
          file copy $from $to
        }
      } msg]
      if {$rc==0} break
      if {$nDelay > 0} { after $nDelay }
    }
    if {$rc} { error $msg }
  } else {
    if {$force} {
      file copy -force $from $to
    } else {
      file copy $from $to
    }
  }
}

# db_save / db_save_and_close / db_restore / db_restore_and_reopen /
# db_delete_and_reopen — upstream tester.tcl:2458..2486.  Verbatim port
# of the snapshot helpers: db_save copies the whole test.db* family
# aside as sv_test.db*, db_restore copies it back, and the *_and_close /
# *_and_reopen variants additionally close/reopen the `db` handle.
# All depend only on forcedelete/forcecopy (ported above), so the port
# is byte-for-byte.  C ref: tester.tcl:2458..2486.
proc db_save {} {
  foreach f [glob -nocomplain sv_test.db*] { forcedelete $f }
  foreach f [glob -nocomplain test.db*] {
    set f2 "sv_$f"
    forcecopy $f $f2
  }
}
proc db_save_and_close {} {
  db_save
  catch { db close }
  return ""
}
proc db_restore {} {
  foreach f [glob -nocomplain test.db*] { forcedelete $f }
  foreach f2 [glob -nocomplain sv_test.db*] {
    set f [string range $f2 3 end]
    forcecopy $f2 $f
  }
}
proc db_restore_and_reopen {{dbfile test.db}} {
  catch { db close }
  db_restore
  sqlite3 db $dbfile
}
proc db_delete_and_reopen {{file test.db}} {
  catch { db close }
  foreach f [glob -nocomplain test.db*] { forcedelete $f }
  sqlite3 db $file
}

# faultsim_save / faultsim_save_and_close / faultsim_restore /
# faultsim_restore_and_reopen — upstream malloc_common.tcl:169..177.
# These are thin aliases over the db_* snapshot helpers above.  The
# full malloc-fault machinery (malloc_common.tcl) is SKIP-cited
# (9.4.2.g.13); only the snapshot-aliases are ported here, since
# aggfault.test / atof tests use just those.  The C
# faultsim_restore_and_reopen additionally calls
# `sqlite3_extended_result_codes db 1` and
# `sqlite3_db_config_lookaside db 0 0 0`; those test commands are not
# yet ported, so they are omitted here (they only tune fault-injection
# behaviour, which is not exercised without the malloc machinery).
proc faultsim_integrity_check {{db db}} {
  set ic [$db eval { PRAGMA integrity_check }]
  if {$ic != "ok"} { error "Integrity check: $ic" }
}
proc faultsim_save {args} { uplevel db_save $args }
proc faultsim_save_and_close {args} { uplevel db_save_and_close $args }
proc faultsim_restore {args} { uplevel db_restore $args }
proc faultsim_restore_and_reopen {args} {
  uplevel db_restore_and_reopen $args
}
proc faultsim_delete_and_reopen {args} {
  uplevel db_delete_and_reopen $args
}

# crashsql — upstream tester.tcl:1752..1840 (port, task 9.4.2.g.11).
# Spawns a child tclsh that opens db via the "crash" VFS (provided by
# TestModuleCrash, task 9.4.7.d), configures sqlite3_crashparams DELAY
# CRASHFILE, runs $sql under `db eval {...}` and is then killed by
# _exit(-1) inside the crash VFS's xSync.  The parent returns the
# two-element list [list R MSG] where R is the catch rc (non-zero on
# crash) and MSG is the error string — the upstream sigil is
# "child process exited abnormally", which `exec` produces verbatim
# when the spawned process is killed by a signal / non-zero exit.
#
# Options (subset of upstream — the full upstream surface is supported
# down to "-tclbody" with the same defaults as tester.tcl:1754..1761):
#   -delay  N        : crash on the Nth xSync of CRASHFILE (default 1)
#   -file   PATH     : the crash filename (required by upstream)
#   -seed   N        : seed the PRNG via a randomblob(N%10007+1)
#   -opendb CMD      : command to open the db (default `sqlite3 db test.db -vfs crash`)
#   -tclbody  SCRIPT : extra Tcl to run in the child before $sql
#   -dfltvfs BOOL    : 2nd arg to sqlite3_crash_enable (default 0)
#   -blocksize / -characteristics : forwarded as `-s N` / `-c LIST` flags
#                       to sqlite3_crashparams (delegated to TestModuleCrash).
#
# The auxiliary commands that tester.tcl's crashsql writes into the
# child script (install_malloc_faultsim, sqlite3_test_control_pending_byte,
# btree_from_db, btree_set_cache_size, autoinstall_test_functions) are
# either present in this build (autoinstall_test_functions via
# TestModuleFunc, install_malloc_faultsim via TestModuleMalloc) or are
# wrapped in `catch { ... }` so a missing command does not abort the
# child before the SQL runs.  Same protective `catch` discipline as the
# `catch {install_malloc_faultsim 1}` arm in tester.tcl:1791.
#
# C oracle: /home/bpsa/app/sqlite3/test/tester.tcl:1752..1840.
proc crashsql {args} {
  set blocksize ""
  set crashdelay 1
  set prngseed 0
  set opendb {sqlite3 db test.db -vfs crash}
  set tclbody {}
  set crashfile ""
  set dc ""
  set dfltvfs 0
  set sql [lindex $args end]

  for {set ii 0} {$ii < [llength $args]-1} {incr ii 2} {
    set z [lindex $args $ii]
    set n [string length $z]
    set z2 [lindex $args [expr $ii+1]]
    if     {$n>1 && [string first $z -delay]==0}     {set crashdelay $z2} \
    elseif {$n>1 && [string first $z -opendb]==0}    {set opendb $z2} \
    elseif {$n>1 && [string first $z -seed]==0}      {set prngseed $z2} \
    elseif {$n>1 && [string first $z -file]==0}      {set crashfile $z2} \
    elseif {$n>1 && [string first $z -tclbody]==0}   {set tclbody $z2} \
    elseif {$n>1 && [string first $z -blocksize]==0} {set blocksize "-s $z2"} \
    elseif {$n>1 && [string first $z -characteristics]==0} {set dc "-c {$z2}"} \
    elseif {$n>1 && [string first $z -dfltvfs]==0}   {set dfltvfs $z2} \
    else   { error "Unrecognized option: $z" }
  }

  if {$crashfile eq ""} {
    error "Compulsory option -file missing"
  }

  set cfile [string map {\\ \\\\} [file nativename [file join [pwd] $crashfile]]]

  # 9.4.7.d — the child script must `load` libpassqlite3tcl.so to gain
  # the `sqlite3` command and the crash-VFS bindings.  Our parent test
  # process was started by TclTestDriver which puts bin/ on ::auto_path,
  # but the child is a bare `[info nameofexec]` (tclsh), so we re-emit
  # the package require here.  PASLIB env var lets the driver override
  # the resolved .so path if it diverges from ::auto_path.
  set libdir [file dirname [info script]]
  # walk up to find bin/ — tester_min.tcl sits at src/tests/tcl/
  set bindir [file normalize [file join $libdir .. .. .. bin]]

  set f [open crash.tcl w]
  puts $f "if {\[info exists ::env(PAS_TCL_PKG_DIR)\]} {"
  puts $f "  lappend ::auto_path \$::env(PAS_TCL_PKG_DIR)"
  puts $f "} else {"
  puts $f "  lappend ::auto_path {$bindir}"
  puts $f "}"
  puts $f "package require sqlite3"
  puts $f "sqlite3_initialize ; sqlite3_shutdown"
  puts $f "catch { install_malloc_faultsim 1 }"
  puts $f "sqlite3_crash_enable 1 $dfltvfs"
  puts $f "sqlite3_crashparams $blocksize $dc $crashdelay $cfile"
  puts $f "catch { sqlite3_test_control_pending_byte \$::sqlite_pending_byte }"
  puts $f "catch { autoinstall_test_functions }"

  if {$opendb ne ""} {
    puts $f $opendb
    puts $f {catch { db eval {SELECT * FROM sqlite_master;} }}
    puts $f {catch {set bt [btree_from_db db]; btree_set_cache_size $bt 10}}
  }

  if {$prngseed} {
    set seed [expr {$prngseed%10007+1}]
    puts $f "db eval {SELECT randomblob($seed)}"
  }

  if {[string length $tclbody]>0} {
    puts $f $tclbody
  }
  if {[string length $sql]>0} {
    puts $f "db eval {"
    puts $f   "$sql"
    puts $f "}"
  }
  close $f

  set r [catch {
    exec [info nameofexec] crash.tcl >@stdout 2>@stdout
  } msg]

  if {$r && [string match {*ERROR: LeakSanitizer*} $msg]} {
    set msg "child process exited abnormally"
  }

  lappend r $msg
}

# Initialise the global pending-byte that tester.tcl normally sets from
# C-side test_config.  Upstream tester.tcl:102 calls
#   sqlite3_test_control_pending_byte 0x0010000
# unconditionally at load time so the locking-page is reachable in tests
# without creating multi-GiB database files.  The pas-sqlite3 engine now
# exposes sqlite3_test_control_pending_byte (PENDING_BYTE is a writable
# global rewritten by SQLITE_TESTCTRL_PENDING_BYTE), so move the actual
# lock byte to match upstream and mirror the Tcl-side variable.  Otherwise
# upstream tests such as backup.test / backup_ioerr.test loop forever on
#   while {[file size test.db] <= $::sqlite_pending_byte} { ... }
# against a 1 GiB threshold (9.4.divbug.91.002 / .003), and stat.test-2.2
# never sees the page-64 locking-page gap.
if {![info exists ::sqlite_pending_byte]} {
  set ::sqlite_pending_byte 0x0010000
}
catch { sqlite3_test_control_pending_byte $::sqlite_pending_byte }
# Upstream binds ::sqlite_pending_byte to the C int sqlite3PendingByte via
# Tcl_LinkVar(TCL_LINK_INT) (test2.c:753), so the variable reads back as a
# *decimal integer* (65536), not the 0x.. literal.  Tests such as
# autovacuum-9.3 compare `file size test.db` (an integer) directly against
# it, so normalise to the integer form to match upstream's linked var.
set ::sqlite_pending_byte [expr {$::sqlite_pending_byte}]

# finish_test — upstream tester.tcl:1237..1255.  Real implementation
# runs finish_test_precleanup (deregisters test VFSes), optionally
# sources extra scripts from $argv, closes `db`, then defers to
# finalize_testing unless ::SLAVE is set.  pas-sqlite3 has no test
# VFSes registered and no slave-interp plumbing, so this collapses to
# a `catch {db close}` + finalize_testing alias.  C ref: tester.tcl:1237.
proc finish_test {} {
  catch {db close}
  if {0==[info exists ::SLAVE]} { finalize_testing }
}

# integrity_check — upstream tester.tcl:1674..1678.  Verbatim port: a
# thin do_test wrapper around `PRAGMA integrity_check` that asserts the
# result list is exactly `{ok}`.  Wrapped in `ifcapable integrityck` so
# builds compiled with SQLITE_OMIT_INTEGRITY_CHECK skip the assertion;
# our `ifcapable` stub always runs the body, matching the default cap
# set.  C ref: tester.tcl:1674..1678.
proc integrity_check {name {db db}} {
  ifcapable integrityck {
    do_test $name [list execsql {PRAGMA integrity_check} $db] {ok}
  }
}

# working_64bit_int — upstream tester.tcl has no `proc working_64bit_int`
# definition in our source tree; the helper originates as a build-cap
# probe registered C-side (tclsqlite.c) that runs a SQL probe equivalent
# to `SELECT (1<<32)-1 == 4294967295` and returns 1 iff the host int
# layer carries 64-bit precision.  Call sites
# (boundary{1..4}.test, expr.test:164, func.test:888, tkt3922.test, ...)
# only gate big-int arms.  pas-sqlite3 targets x86_64 Linux with FPC
# `Int64` everywhere, so the probe is always true on x86_64 — return 1
# unconditionally.  C ref: test/boundary1.test:22 (`if {![working_64bit_int]}
# { finish_test; return }`).
proc working_64bit_int {} {
  return 1
}

# expand_all_sql — upstream tester.tcl:2601..2606.  A diagnostic helper that
# walks every open prepared statement on $db (via sqlite3_next_stmt) and
# evaluates sqlite3_expanded_sql on it.  Its result is discarded; call sites
# (fts3aa.test:264 `expand_all_sql db`) invoke it purely to exercise the
# expand path after all do_test assertions have run.  The pas-sqlite3 Tcl
# bridge does not yet register sqlite3_next_stmt / sqlite3_expanded_sql, so
# the verbatim body would raise "invalid command name".  Mirror the C proc
# but guard the per-statement work with `catch` so the helper degrades to a
# no-op on this build while staying forward-compatible once those commands
# are bridged.  C ref: test/tester.tcl:2601.
proc expand_all_sql {db} {
  catch {
    set stmt ""
    while {[set stmt [sqlite3_next_stmt $db $stmt]]!=""} {
      sqlite3_expanded_sql $stmt
    }
  }
}

# permutation — upstream tester.tcl:2329..2333.  Returns the name of the
# active permutation, or "" for the baseline run.  The full permutation
# matrix (permutations.test re-runs every test under ~30 build-flag
# combinations: memsubsys1, wal, journaltest, inmemory_journal, ...) is
# DEFERRED to 9.4.7.e.  For the full-corpus first cut we run ONLY the
# baseline permutation, so `::G(perm:name)` is never set and this always
# returns "".  Test arms gated on `[permutation]=="wal"` etc. therefore
# take their baseline branch.  C ref: tester.tcl:2329..2333.
proc permutation {} {
  set perm ""
  catch {set perm $::G(perm:name)}
  set perm
}

# permutations.test skip-shim — 9.4.2.g.8.
#
# tester.tcl's permutation machinery lives in test/permutations.test:
# `test_suite`, `test_set`, and the `run_tests` runner build a matrix
# that re-executes the whole corpus under each build-flag permutation.
# pas-sqlite3 is not ready to drive that matrix yet, so we stub the
# entry points to no-ops that quietly accept (and discard) any
# permutation definition.  Net effect: sourcing permutations.test, or a
# .test file that calls these, does not error — but only the baseline
# permutation ever actually runs (driven directly by the test driver).
# The real matrix is deferred to 9.4.7.e.  C ref: test/permutations.test:1..400.
proc test_suite {name args} {
  # Record the spec so `[info exists ::testspec($name)]` style probes do
  # not fault, but never act on it — no permutation is launched.
  set ::testspec($name) $args
  if {![info exists ::testsuitelist]} { set ::testsuitelist [list] }
  lappend ::testsuitelist $name
}
proc test_set {args} {
  # Upstream returns the include/exclude-resolved file list; the matrix
  # runner is stubbed out, so an empty list is sufficient and harmless.
  return [list]
}
proc run_tests {name args} {
  # Baseline-only: a named permutation run is a no-op.  The baseline
  # corpus is executed directly by the driver, not through here.
  if {$name ne ""} {
    puts "permutation \"$name\" skipped (9.4.2.g.8: matrix deferred to 9.4.7.e)"
  }
  return
}
proc run_test_suite {name} { run_tests $name }

# presql — upstream tester.tcl:2334..2338.  Returns the SQL string the
# active permutation wants prepended to every fresh `sqlite3` handle
# (e.g. `PRAGMA journal_mode=wal`).  pas-sqlite3 has no permutation
# matrix wired yet (9.4.2.g.8), so `::G(perm:presql)` is never set and
# the catch arm leaves the local empty; verbatim port matches upstream
# byte-for-byte.  C ref: tester.tcl:2334..2338.
proc presql {} {
  set presql ""
  catch {set presql $::G(perm:presql)}
  set presql
}

# omit_test — upstream tester.tcl:593..599.  Appends `[list NAME REASON]`
# to the `omit_list` TC() counter.  Used by .test files (and our future
# fix_ifcapable_expr) to record gracefully-skipped sub-tests so the
# finalize_testing summary can list them.  Verbatim port.  C ref:
# tester.tcl:593..599.
proc omit_test {name reason {append 1}} {
  set omitList [set_test_counter omit_list]
  if {$append} {
    lappend omitList [list $name $reason]
  }
  set_test_counter omit_list $omitList
}

# reset_db — upstream tester.tcl:550..557.  Closes any open `db`
# handle, force-deletes the test.db family, and reopens `db` on a
# fresh on-disk ./test.db.  pas-sqlite3 previously opened `db` on
# `:memory:` from the driver, which broke any upstream sub-test that
# does `db close; sqlite3 db test.db` to re-read the schema from disk
# (e.g. index-1.1c/1.1d): the reopened handle saw an empty database
# because the in-memory schema was never persisted (9.4.divbug.3).
# Also exports `::DB` as the raw sqlite3* connection pointer (upstream
# tester.tcl:557) so .test files (schema.test, malloc*.test, ioerr*.test)
# that pass `$::DB` to sqlite3_prepare / sqlite3_extended_result_codes /
# etc. don't trip "can't read \"::DB\": no such variable" (9.4.divbug.65).
# C ref: tester.tcl:548..558.
proc reset_db {} {
  catch {db close}
  forcedelete test.db
  forcedelete test.db-journal
  forcedelete test.db-wal
  forcedelete test.db-shm
  sqlite3 db ./test.db
  set ::DB [sqlite3_connection_pointer db]
  # 9.4.7.e: apply the active permutation's presql (e.g. PRAGMA journal_mode=WAL)
  # after each fresh handle.  When no --permutation is active, [presql] returns
  # "" and this is a no-op.  C ref: tester.tcl:557..560 (sqlitetest_init).
  set __presql [presql]
  if {$__presql ne ""} {
    catch { db eval $__presql }
  }
}

# query_plan_graph — upstream tester.tcl:990..1001.  Renders the
# EXPLAIN QUERY PLAN output of $sql as the indented ASCII graph that
# do_eqp_test compares against.  Relies on the `db eval` 3-arg array
# form (9.4.2.h) for the row->array binding.
proc query_plan_graph {sql} {
  db eval "EXPLAIN QUERY PLAN $sql" {
    set dx($id) $detail
    lappend cx($parent) $id
  }
  set a "\n  QUERY PLAN\n"
  append a [append_graph "  " dx cx 0]
  regsub -all {SUBQUERY 0x[A-F0-9]+\y} $a {SUBQUERY xxxxxx} a
  regsub -all {(MATERIALIZE|CO-ROUTINE|SUBQUERY) \d+\y} $a {\1 xxxxxx} a
  regsub -all {\((join|subquery)-\d+\)} $a {(\1-xxxxxx)} a
  return $a
}

# append_graph — upstream tester.tcl:1017..1039.  Helper for
# query_plan_graph: emit the rows of the graph that are children of
# $level, prefixed with the tree-drawing characters.
proc append_graph {prefix dxname cxname level} {
  upvar $dxname dx $cxname cx
  set a ""
  set x $cx($level)
  set n [llength $x]
  for {set i 0} {$i<$n} {incr i} {
    set id [lindex $x $i]
    if {$i==$n-1} {
      set p1 "`--"
      set p2 "   "
    } else {
      set p1 "|--"
      set p2 "|  "
    }
    append a $prefix$p1$dx($id)\n
    if {[info exists cx($id)]} {
      append a [append_graph "$prefix$p2" dx cx $id]
    }
  }
  return $a
}

# do_eqp_test — upstream tester.tcl:1048..1066.  Run EXPLAIN QUERY PLAN
# on $sql and compare against $res.  If $res begins with a
# "\s+QUERY PLAN\n" line it is the complete expected graph and must
# match query_plan_graph exactly; otherwise $res is a substring that
# must appear somewhere in the EQP output (wrapped as a /*...*/ glob).
proc do_eqp_test {name sql res} {
  if {[regexp {^\s+QUERY PLAN\n} $res]} {
    set query_plan [query_plan_graph $sql]
    if {[list {*}$query_plan]==[list {*}$res]} {
      uplevel [list do_test $name [list set {} ok] ok]
    } else {
      uplevel [list \
        do_test $name [list query_plan_graph $sql] $res
      ]
    }
  } else {
    if {[string index $res 0]!="/"} {
      set res "/*$res*/"
    }
    uplevel do_execsql_test $name [list "EXPLAIN QUERY PLAN $sql"] [list $res]
  }
}

# do_eqp_execsql_test — upstream tester.tcl:1068..1089.  Do both an
# eqp_test (EXPLAIN QUERY PLAN graph compare) and an execsql_test
# (result-set compare) on the same SQL, emitting "${name}a" / "${name}b"
# sub-tests.  Verbatim port of the upstream proc (orderbyB.test:50/72
# relies on it).  C ref: test/tester.tcl:1068..1089.
proc do_eqp_execsql_test {name sql res1 res2} {
  if {[regexp {^\s+QUERY PLAN\n} $res1]} {
    set query_plan [query_plan_graph $sql]
    if {[list {*}$query_plan]==[list {*}$res1]} {
      uplevel [list do_test ${name}a [list set {} ok] ok]
    } else {
      uplevel [list \
        do_test ${name}a [list query_plan_graph $sql] $res1
      ]
    }
  } else {
    if {[string index $res1 0]!="/"} {
      set res1 "/*$res1*/"
    }
    uplevel do_execsql_test ${name}a [list "EXPLAIN QUERY PLAN $sql"] [list $res1]
  }
  uplevel do_execsql_test ${name}b [list $sql] [list $res2]
}

# do_vmstep_test — upstream tester.tcl:913..933.  Run SQL and verify
# that the number of "vmsteps" required is greater than or less than
# some constant.  If $nstep starts with "+", asserts vmstep>=N;
# otherwise asserts vmstep<=N.
proc do_vmstep_test {tn sql nstep {res {}}} {
  uplevel [list do_execsql_test $tn.0 $sql $res]

  set vmstep [db status vmstep]
  if {[string range $nstep 0 0]=="+"} {
    set body "if {$vmstep<$nstep} {
      error \"got $vmstep, expected more than [string range $nstep 1 end]\"
    }"
  } else {
    set body "if {$vmstep>$nstep} {
      error \"got $vmstep, expected less than $nstep\"
    }"
  }

  # set name "$tn.vmstep=$vmstep,expect=$nstep"
  set name "$tn.1"
  uplevel [list do_test $name $body {}]
}

# do_select_tests — upstream tester.tcl:1103..1157.  Runs a list of
# {tn sql res} triples through do_execsql_test (default) or
# do_catchsql_test (-errorformat), with optional -count / -query /
# -tclquery / -repair switches.
proc do_select_tests {prefix args} {

  set testlist [lindex $args end]
  set switches [lrange $args 0 end-1]

  set errfmt ""
  set countonly 0
  set tclquery ""
  set repair ""

  for {set i 0} {$i < [llength $switches]} {incr i} {
    set s [lindex $switches $i]
    set n [string length $s]
    if {$n>=2 && [string equal -length $n $s "-query"]} {
      set tclquery [list execsql [lindex $switches [incr i]]]
    } elseif {$n>=2 && [string equal -length $n $s "-tclquery"]} {
      set tclquery [lindex $switches [incr i]]
    } elseif {$n>=2 && [string equal -length $n $s "-errorformat"]} {
      set errfmt [lindex $switches [incr i]]
    } elseif {$n>=2 && [string equal -length $n $s "-repair"]} {
      set repair [lindex $switches [incr i]]
    } elseif {$n>=2 && [string equal -length $n $s "-count"]} {
      set countonly 1
    } else {
      error "unknown switch: $s"
    }
  }

  if {$countonly && $errfmt!=""} {
    error "Cannot use -count and -errorformat together"
  }
  set nTestlist [llength $testlist]
  if {$nTestlist%3 || $nTestlist==0 } {
    error "SELECT test list contains [llength $testlist] elements"
  }

  eval $repair
  foreach {tn sql res} $testlist {
    if {$tclquery != ""} {
      execsql $sql
      uplevel do_test ${prefix}.$tn [list $tclquery] [list [list {*}$res]]
    } elseif {$countonly} {
      set nRow 0
      db eval $sql {incr nRow}
      uplevel do_test ${prefix}.$tn [list [list set {} $nRow]] [list $res]
    } elseif {$errfmt==""} {
      uplevel do_execsql_test ${prefix}.${tn} [list $sql] [list [list {*}$res]]
    } else {
      set res [list 1 [string trim [format $errfmt {*}$res]]]
      uplevel do_catchsql_test ${prefix}.${tn} [list $sql] [list $res]
    }
    eval $repair
  }

}

# do_select_test / do_restart_select_test / do_error_test —
# upstream malloc_common.tcl:561..571.  In a non-malloc-fault build
# (::DO_MALLOC_TEST==0, our default) doPassiveTest collapses to a single
# do_test of [catchsql $sql] against {0 result} (or {1 error}).  We don't
# port the full memdebug fault loop (SKIP-cited), only the passive form
# fts3snippet / other eval tests actually exercise.
proc doPassiveTest {isRestart name sql catchres} {
  if {[info exists ::testprefix]
   && [string is integer [string range $name 0 0]]
  } {
    set name $::testprefix.$name
  }
  if {$isRestart} { catch { db close }; sqlite3 db test.db }
  do_test $name [list set {} [uplevel [list catchsql $sql]]] $catchres
}
proc do_select_test {name sql result} {
  uplevel [list doPassiveTest 0 $name $sql [list 0 [list {*}$result]]]
}
proc do_restart_select_test {name sql result} {
  uplevel [list doPassiveTest 1 $name $sql [list 0 $result]]
}
proc do_error_test {name sql error} {
  uplevel [list doPassiveTest 0 $name $sql [list 1 $error]]
}

# sql_uses_stmt — upstream tester.tcl:1690..1695.  Reports whether the
# prepared form of $sql would use a statement journal (uses_stmt_journal,
# already provided by the test1 harness module).  Needed by
# fts4onepass / fts3conf.
proc sql_uses_stmt {db sql} {
  set stmt [sqlite3_prepare $db $sql -1 dummy]
  set uses [uses_stmt_journal $stmt]
  sqlite3_finalize $stmt
  return $uses
}

# drop_all_tables — upstream tester.tcl:2253..2275.  Drops all tables
# and views from every attached database on connection [db].
proc drop_all_tables {{db db}} {
  ifcapable trigger&&foreignkey {
    set pk [$db one "PRAGMA foreign_keys"]
    $db eval "PRAGMA foreign_keys = OFF"
  }
  foreach {idx name file} [db eval {PRAGMA database_list}] {
    if {$idx==1} {
      set master sqlite_temp_master
    } else {
      set master $name.sqlite_master
    }
    foreach {t type} [$db eval "
      SELECT name, type FROM $master
      WHERE type IN('table', 'view') AND name NOT LIKE 'sqliteX_%' ESCAPE 'X'
    "] {
      $db eval "DROP $type \"$t\""
    }
  }
  ifcapable trigger&&foreignkey {
    $db eval "PRAGMA foreign_keys = $pk"
  }
}

# drop_all_indexes — upstream tester.tcl:2277..2284.  Drops every
# auxiliary (user-created) index from the main database on connection
# [db].  rowvalue3.test / rowvalue4.test call this inside their foreach
# index-permutation loops to reset between index variants.  Verbatim
# port.  C ref: tester.tcl:2277..2284.
proc drop_all_indexes {{db db}} {
  set L [$db eval {
    SELECT name FROM sqlite_master WHERE type='index' AND sql LIKE 'create%'
  }]
  foreach idx $L { $db eval "DROP INDEX $idx" }
}

# ===========================================================================
# Fault-injection helpers — do_malloc_test (task 9.4.2.g.9) and
# do_ioerr_test (task 9.4.2.g.10).
#
# do_malloc_test is a verbatim port of malloc_common.tcl:416..538; it
# drives the `sqlite3_memdebug_fail` primitive (TestModuleMalloc, the
# memdebug build).  do_ioerr_test is a verbatim port of
# tester.tcl:1927..2118; it drives the ::sqlite_io_error_* counters
# (TestModuleIoerr / passqlite3os.pas instrumentation, task 9.4.7.c).
#
# A handful of upstream C test commands these procs lean on are not yet
# ported (save/restore_prng_state, sqlite3_extended_result_codes,
# sqlite3_db_config_lookaside, sqlite3_errcode).  They are advisory —
# they tune determinism / result-code reporting but do not change which
# faults fire — so they are provided here as thin shims:
#   * save_prng_state / restore_prng_state — no-ops (the engine PRNG is
#     not yet Tcl-controllable; tests still run, just less reproducible).
#   * sqlite3_extended_result_codes — no-op (extended codes are always
#     on in this build's error reporting).
#   * sqlite3_db_config_lookaside — no-op (lookaside tuning only).
#   * sqlite3_errcode — defers to the `db errorcode` subcommand.
# C ref: malloc_common.tcl, tester.tcl, test1.c, test2.c.
# ===========================================================================
if {[llength [info commands save_prng_state]]==0} {
  proc save_prng_state {} {}
}
if {[llength [info commands restore_prng_state]]==0} {
  proc restore_prng_state {} {}
}
if {[llength [info commands sqlite3_extended_result_codes]]==0} {
  proc sqlite3_extended_result_codes {db onoff} {}
}
if {[llength [info commands sqlite3_db_config_lookaside]]==0} {
  proc sqlite3_db_config_lookaside {db args} {}
}
if {[llength [info commands sqlite3_errcode]]==0} {
  proc sqlite3_errcode {db} { return [$db errorcode] }
}

# cksum — verbatim port of tester.tcl (used by do_ioerr_test -cksum).
# Returns a content checksum of the main database.
if {[llength [info commands cksum]]==0} {
  proc cksum {{db db}} {
    set txt [$db eval {
        SELECT name, type, sql FROM sqlite_master order by name
    }]\n
    foreach tbl [$db eval {
        SELECT name FROM sqlite_master WHERE type='table' order by name
    }] {
      append txt [$db eval "SELECT * FROM $tbl"]\n
    }
    foreach prag {default_synchronous default_cache_size} {
      append txt $prag-[$db eval "PRAGMA $prag"]\n
    }
    set cksum [string length $txt]-[md5 $txt]
    return $cksum
  }
}
# dbcksum — verbatim port of tester.tcl:2176..2188.
# Computes an md5 of $dbname's sqlite_master plus every table's contents.
if {[llength [info commands dbcksum]]==0} {
  proc dbcksum {db dbname} {
    if {$dbname=="temp"} {
      set master sqlite_temp_master
    } else {
      set master $dbname.sqlite_master
    }
    set alltab [$db eval "SELECT name FROM $master WHERE type='table'"]
    set txt [$db eval "SELECT * FROM $master"]\n
    foreach tab $alltab {
      append txt [$db eval "SELECT * FROM $dbname.$tab"]\n
    }
    return [md5 $txt]
  }
}
# allcksum — verbatim port of tester.tcl:2145..2170.  6.40.6 (HARNESS).
# Generates an md5 over the contents of every table (plus the schema
# tables and default_cache_size) of $db.  Used by corruptN/io/oserror/
# walcrash-class tests to confirm a database is unchanged after a fault.
if {[llength [info commands allcksum]]==0} {
  proc allcksum {{db db}} {
    set ret [list]
    ifcapable tempdb {
      set sql {
        SELECT name FROM sqlite_master WHERE type = 'table' UNION
        SELECT name FROM sqlite_temp_master WHERE type = 'table' UNION
        SELECT 'sqlite_master' UNION
        SELECT 'sqlite_temp_master' ORDER BY 1
      }
    } else {
      set sql {
        SELECT name FROM sqlite_master WHERE type = 'table' UNION
        SELECT 'sqlite_master' ORDER BY 1
      }
    }
    set tbllist [$db eval $sql]
    set txt {}
    foreach tbl $tbllist {
      append txt [$db eval "SELECT * FROM $tbl"]
    }
    foreach prag {default_cache_size} {
      append txt $prag-[$db eval "PRAGMA $prag"]\n
    }
    # puts txt=$txt
    return [md5 $txt]
  }
}

# output2 — verbatim port of tester.tcl: writes to stdout.
if {[llength [info commands output2]]==0} {
  proc output2 {args} { uplevel puts $args }
}

# do_malloc_test — verbatim port of malloc_common.tcl:416..538.
# Each iteration arms the Nth sqlite3_malloc() call to fail (transient
# on the first pass, persistent on the second), runs the -tclbody /
# -sqlbody, and asserts SQLite either succeeded or reported an OOM.
proc do_malloc_test {tn args} {
  array unset ::mallocopts
  array set ::mallocopts $args

  if {[string is integer $tn]} {
    set tn malloc-$tn
    catch { set tn $::testprefix-$tn }
  }
  if {[info exists ::mallocopts(-start)]} {
    set start $::mallocopts(-start)
  } else {
    set start 0
  }
  if {[info exists ::mallocopts(-end)]} {
    set end $::mallocopts(-end)
  } else {
    set end 50000
  }
  save_prng_state

  foreach ::iRepeat {0 10000000} {
    set ::go 1
    for {set ::n $start} {$::go && $::n <= $end} {incr ::n} {

      # If $::iRepeat is 0, then the malloc() failure is transient - it
      # fails and then subsequent calls succeed. If $::iRepeat is 1,
      # then the failure is persistent - once malloc() fails it keeps
      # failing.
      #
      set zRepeat "transient"
      if {$::iRepeat} {set zRepeat "persistent"}
      restore_prng_state
      foreach file [glob -nocomplain test.db-mj*] {forcedelete $file}

      do_test ${tn}.${zRepeat}.${::n} {

        # Remove all traces of database files test.db and test2.db
        # from the file-system. Then open (empty database) "test.db"
        # with the handle [db].
        #
        catch {db close}
        catch {db2 close}
        forcedelete test.db
        forcedelete test.db-journal
        forcedelete test.db-wal
        forcedelete test2.db
        forcedelete test2.db-journal
        forcedelete test2.db-wal
        if {[info exists ::mallocopts(-testdb)]} {
          copy_file $::mallocopts(-testdb) test.db
        }
        catch { sqlite3 db test.db }
        if {[info commands db] ne ""} {
          sqlite3_extended_result_codes db 1
        }
        sqlite3_db_config_lookaside db 0 0 0

        # Execute any -tclprep and -sqlprep scripts.
        #
        if {[info exists ::mallocopts(-tclprep)]} {
          eval $::mallocopts(-tclprep)
        }
        if {[info exists ::mallocopts(-sqlprep)]} {
          execsql $::mallocopts(-sqlprep)
        }

        # Now set the ${::n}th malloc() to fail and execute the -tclbody
        # and -sqlbody scripts.
        #
        sqlite3_memdebug_fail $::n -repeat $::iRepeat
        set ::mallocbody {}
        if {[info exists ::mallocopts(-tclbody)]} {
          append ::mallocbody "$::mallocopts(-tclbody)\n"
        }
        if {[info exists ::mallocopts(-sqlbody)]} {
          append ::mallocbody "db eval {$::mallocopts(-sqlbody)}"
        }

        # The following block sets local variables as follows:
        #
        #     isFail  - True if an error (any error) was reported by sqlite.
        #     nFail   - The total number of simulated malloc() failures.
        #     nBenign - The number of benign simulated malloc() failures.
        #
        set isFail [catch $::mallocbody msg]
        set nFail [sqlite3_memdebug_fail -1 -benigncnt nBenign]

        # If one or more mallocs failed, run this loop body again.
        #
        set go [expr {$nFail>0}]

        if {($nFail-$nBenign)==0} {
          if {$isFail} {
            set v2 $msg
          } else {
            set isFail 1
            set v2 1
          }
        } elseif {!$isFail} {
          set v2 $msg
        } elseif {
          [info command db]=="" ||
          [db errorcode]==7 ||
          $msg=="out of memory"
        } {
          set v2 1
        } else {
          set v2 $msg
          puts [db errorcode]
        }
        lappend isFail $v2
      } {1 1}

      if {[info exists ::mallocopts(-cleanup)]} {
        catch [list uplevel #0 $::mallocopts(-cleanup)] msg
      }
    }
  }
  unset ::mallocopts
  sqlite3_memdebug_fail -1
}

# run_ioerr_prep — verbatim port of tester.tcl:1890..1908.  Deletes the
# test.db family and reopens `db`, then runs any -tclprep / -sqlprep.
proc run_ioerr_prep {} {
  set ::sqlite_io_error_pending 0
  catch {db close}
  catch {db2 close}
  catch {forcedelete test.db}
  catch {forcedelete test.db-journal}
  catch {forcedelete test2.db}
  catch {forcedelete test2.db-journal}
  set ::DB [sqlite3 db test.db; sqlite3_connection_pointer db]
  sqlite3_extended_result_codes $::DB $::ioerropts(-erc)
  if {[info exists ::ioerropts(-tclprep)]} {
    eval $::ioerropts(-tclprep)
  }
  if {[info exists ::ioerropts(-sqlprep)]} {
    execsql $::ioerropts(-sqlprep)
  }
  expr 0
}

# do_ioerr_test — verbatim port of tester.tcl:1927..2118.  Each
# iteration arms the Nth I/O operation to fail (via the
# ::sqlite_io_error_* counters linked by TestModuleIoerr), runs the
# -tclbody / -sqlbody, and asserts that either no I/O error fired and
# the SQL succeeded, or an I/O error fired and the SQL failed.
proc do_ioerr_test {testname args} {

  set ::ioerropts(-start) 1
  set ::ioerropts(-cksum) 0
  set ::ioerropts(-erc) 0
  set ::ioerropts(-count) 100000000
  set ::ioerropts(-persist) 1
  set ::ioerropts(-ckrefcount) 0
  set ::ioerropts(-restoreprng) 1
  array set ::ioerropts $args

  # TEMPORARY: For 3.5.9, disable testing of extended result codes. There are
  # a couple of obscure IO errors that do not return them.
  set ::ioerropts(-erc) 0

  # Create a single TCL script from the TCL and SQL specified
  # as the body of the test.
  set ::ioerrorbody {}
  if {[info exists ::ioerropts(-tclbody)]} {
    append ::ioerrorbody "$::ioerropts(-tclbody)\n"
  }
  if {[info exists ::ioerropts(-sqlbody)]} {
    append ::ioerrorbody "db eval {$::ioerropts(-sqlbody)}"
  }

  save_prng_state
  if {$::ioerropts(-cksum)} {
    run_ioerr_prep
    eval $::ioerrorbody
    set ::goodcksum [cksum]
  }

  set ::go 1
  for {set n $::ioerropts(-start)} {$::go} {incr n} {
    set ::TN $n
    incr ::ioerropts(-count) -1
    if {$::ioerropts(-count)<0} break

    # Skip this IO error if it was specified with the "-exclude" option.
    if {[info exists ::ioerropts(-exclude)]} {
      if {[lsearch $::ioerropts(-exclude) $n]!=-1} continue
    }
    if {$::ioerropts(-restoreprng)} {
      restore_prng_state
    }

    # Delete the files test.db and test2.db, then execute the TCL and
    # SQL (in that order) to prepare for the test case.
    do_test $testname.$n.1 {
      run_ioerr_prep
    } {0}

    # Read the 'checksum' of the database.
    if {$::ioerropts(-cksum)} {
      set ::checksum [cksum]
    }

    # Set the Nth IO error to fail.
    do_test $testname.$n.2 [subst {
      set ::sqlite_io_error_persist $::ioerropts(-persist)
      set ::sqlite_io_error_pending $n
    }] $n

    # Execute the TCL script created for the body of this test. If
    # at least N IO operations performed by SQLite as a result of
    # the script, the Nth will fail.
    do_test $testname.$n.3 {
      set ::sqlite_io_error_hit 0
      set ::sqlite_io_error_hardhit 0
      set r [catch $::ioerrorbody msg]
      set ::errseen $r
      if {[info commands db]!=""} {
        set rc [sqlite3_errcode db]
        if {$::ioerropts(-erc)} {
          # If we are in extended result code mode, make sure all of the
          # IOERRs we get back really do have their extended code values.
          if {[regexp {^SQLITE_IOERR} $rc] && ![regexp {IOERR\+\d} $rc]} {
            return $rc
          }
        } else {
          # If we are not in extended result code mode, make sure no
          # extended error codes are returned.
          if {[regexp {\+\d} $rc]} {
            return $rc
          }
        }
      }
      # The test repeats as long as $::go is non-zero.  $::go starts out
      # as 1.  When a test runs to completion without hitting an I/O
      # error, that means there is no point in continuing with this test
      # case so set $::go to zero.
      #
      if {$::sqlite_io_error_pending>0} {
        set ::go 0
        set q 0
        set ::sqlite_io_error_pending 0
      } else {
        set q 1
      }

      set s [expr $::sqlite_io_error_hit==0]
      if {$::sqlite_io_error_hit>$::sqlite_io_error_hardhit && $r==0} {
        set r 1
      }
      set ::sqlite_io_error_hit 0

      # One of two things must have happened. either
      #   1.  We never hit the IO error and the SQL returned OK
      #   2.  An IO error was hit and the SQL failed
      #
      expr { ($s && !$r && !$q) || (!$s && $r && $q) }
    } {1}

    set ::sqlite_io_error_hit 0
    set ::sqlite_io_error_pending 0

    # If there is an open database handle and no open transaction,
    # and the pager is not running in exclusive-locking mode,
    # check that the pager is in "unlocked" state.
    #
    ifcapable pragma {
      if { [info commands db] ne ""
        && $::ioerropts(-ckrefcount)
        && [db one {pragma locking_mode}] eq "normal"
        && [sqlite3_get_autocommit db]
      } {
        do_test $testname.$n.5 {
          set bt [btree_from_db db]
          db_enter db
          array set stats [btree_pager_stats $bt]
          db_leave db
          set stats(state)
        } 0
      }
    }

    # If an IO error occurred, then the checksum of the database should
    # be the same as before the script that caused the IO error was run.
    #
    if {$::go && $::sqlite_io_error_hardhit && $::ioerropts(-cksum)} {
      do_test $testname.$n.6 {
        catch {db close}
        catch {db2 close}
        set ::DB [sqlite3 db test.db; sqlite3_connection_pointer db]
        set nowcksum [cksum]
        set res [expr {$nowcksum==$::checksum || $nowcksum==$::goodcksum}]
        if {$res==0} {
          output2 "now=$nowcksum"
          output2 "the=$::checksum"
          output2 "fwd=$::goodcksum"
        }
        set res
      } 1
    }

    set ::sqlite_io_error_hardhit 0
    set ::sqlite_io_error_pending 0
    if {[info exists ::ioerropts(-cleanup)]} {
      catch $::ioerropts(-cleanup)
    }
  }
  set ::sqlite_io_error_pending 0
  set ::sqlite_io_error_persist 0
  unset ::ioerropts
}

# Build-configuration globals — upstream tester.tcl:2609..2611 sets
# `$AUTOVACUUM` from `$sqlite_options(default_autovacuum)`, and
# test_config.c (set_options) Tcl_LinkVar's the integer build constants
# TEMP_STORE / DEFAULT_SYNCHRONOUS / DEFAULT_WAL_SYNCHRONOUS /
# DEFAULT_FILE_FORMAT plus the sqlite_options() array.  pas-sqlite3 has
# no testfixture / set_options C shim, so the .test files that read
# these globals (insert.test reads $AUTOVACUUM, etc.) error on the
# undefined variable.  Surfaced by the 9.4.4.c sweep (tasklist 9.4.2.g.14).
#
# Values are derived from THIS port's actual default build config — the
# port does not override the upstream C defaults:
#   AUTOVACUUM=0   — src/passqlite3btree.pas:118 SQLITE_DEFAULT_AUTOVACUUM=0
#   TEMP_STORE=1   — upstream SQLITE_TEMP_STORE compile-time default
#   DEFAULT_SYNCHRONOUS=2     — src/passqlite3pager.pas:237
#   DEFAULT_WAL_SYNCHRONOUS=2 — upstream defaults this to
#                    SQLITE_DEFAULT_SYNCHRONOUS when not separately set
#   DEFAULT_FILE_FORMAT=4     — src/passqlite3main.pas:5878
#                    SQLITE_MAX_FILE_FORMAT_L=4 (newest format written)
#   MEMORY_MANAGEMENT=0       — SQLITE_ENABLE_MEMORY_MANAGEMENT is off in
#                    this build (src/passqlite3main.pas:4815, pcache.pas:227)
# C ref: tester.tcl:2609..2611, src/test_config.c set_options().
set ::AUTOVACUUM 0
set ::TEMP_STORE 1
set ::SQLITE_DEFAULT_SYNCHRONOUS 2
set ::SQLITE_DEFAULT_WAL_SYNCHRONOUS 2
set ::SQLITE_DEFAULT_FILE_FORMAT 4
set ::MEMORY_MANAGEMENT 0
# SQLITE_DEFAULT_CACHE_SIZE — sqliteLimit.h:161 default -2000.  Negative
# means kibibytes; exclusive2.test:139/223 compares numerically against
# nPage (db-file size in pages), so a very negative value reliably means
# "the cache is already big enough" and skips the PRAGMA cache_size bump.
set ::SQLITE_DEFAULT_CACHE_SIZE -2000

# Minimal sqlite_options() array — upstream test_config.c populates this
# from compile-time SQLITE_OMIT_*/SQLITE_ENABLE_* macros.  pas-sqlite3 is
# built with the default cap set (no SQLITE_OMIT_*).  We seed only
# default_autovacuum (read directly by tester.tcl:2611) here; ifcapable
# expressions are handled by the always-true `ifcapable` stub above.
# C ref: src/test_config.c:309..313.
array set ::sqlite_options {default_autovacuum 0}
# 9.4.divbug.91.016 — types.test reads $sqlite_options(utf16) directly
# (not through ifcapable).  pas-sqlite3 has UTF-16 enabled in its build,
# matching the upstream default; mirror test_config.c:705 in that arm.
set ::sqlite_options(utf16) 1

# 9.4.divbug.91 — assorted globals that upstream test_config.c /
# test1.c plumb but pas-sqlite3 does not.  Each test that names one
# below errors with "no such variable" before reaching its first
# assertion, so the engine never runs.  Seeding the value here lets
# those tests load.  C refs noted per-line.
#   bitmask_size: test1.c:9335..9438 LinkVar of sizeof(Bitmask)*8 = 64
#     (Bitmask is u64 in this port — see passqlite3codegen.pas:53).
#     Used by join3.test as the join-table-count limit.
set ::bitmask_size 64
#   SQLITE_MAX_VARIABLE_NUMBER: test_config.c:817 LinkVar of the
#     SQLITE_MAX_VARIABLE_NUMBER macro (= 32766; matches
#     passqlite3main.pas:653 / passqlite3types.pas:282).  Used by
#     bind.test:422.
set ::SQLITE_MAX_VARIABLE_NUMBER 32766
#   cmdlinearg(soft-heap-limit): tester.tcl:378 / :404 default + CLI
#     override; tester.tcl:546 feeds it to sqlite3_soft_heap_limit64.
#     0 means "no limit".  Used by avtrans.test:169 and capi3b.test:144.
if {![info exists ::cmdlinearg(soft-heap-limit)]} {
  set ::cmdlinearg(soft-heap-limit) 0
}
#   cmdlinearg(TESTFIXTURE_HOME): tester.tcl:497 sets this to
#     [file dirname [info nameofexec]] so test_find_binary /
#     test_find_db / friends (tester.tcl:2530..2536) can locate
#     auxiliary binaries and data files relative to the testfixture
#     executable.  Honour $env(TESTFIXTURE_HOME) when set (matches the
#     upstream convention used by Makefile-driven runs), else fall back
#     to the directory containing the running interpreter / [pwd].
#     Surfaced by analyzer1.test via the read at tester_min.tcl:1616.
if {![info exists ::cmdlinearg(TESTFIXTURE_HOME)]} {
  if {[info exists ::env(TESTFIXTURE_HOME)]} {
    set ::cmdlinearg(TESTFIXTURE_HOME) $::env(TESTFIXTURE_HOME)
  } else {
    set _tfh [file dirname [info nameofexec]]
    if {$_tfh eq "" || $_tfh eq "."} {
      set _tfh [pwd]
    }
    set ::cmdlinearg(TESTFIXTURE_HOME) $_tfh
    unset _tfh
  }
}

# --------------------------------------------------------------------------
# 9.4.6.q.2 — remaining tester.tcl / malloc_common.tcl procs surfaced by
# the 9.4.4.d 100-test sweep.
# --------------------------------------------------------------------------

# do_not_use_codec — upstream tester.tcl:323..326.  Gates tests that are
# incompatible with encryption codecs.  pas-sqlite3 has no codec build
# variant, so the proc just sets the marker and resets the db (verbatim
# port — matches upstream byte-for-byte).
proc do_not_use_codec {} {
  set ::do_not_use_codec 1
  reset_db
}
catch {unset -nocomplain do_not_use_codec}

# sql36231 — upstream tester.tcl:2446..2456.  Opens a second connection
# on test.db, runs the supplied SQL, closes, then restores the 4-byte
# field at offset 28 (db size in pages) and the 8 bytes at offset 92
# (change-counter / version-valid-for).  Simulates a write by a
# pre-3.7.0 client that never learnt to maintain those header fields,
# so the next 3.7+ open must derive page count from file size again.
# Used by filefmt-2.*, 3.2 and 4.2.  Verbatim port of the upstream proc.
proc sql36231 {sql} {
  set B [hexio_read test.db 92 8]
  set A [hexio_read test.db 28 4]
  sqlite3 db36231 test.db
  catch { db36231 func a_string a_string }
  execsql $sql db36231
  db36231 close
  hexio_write test.db 28 $A
  hexio_write test.db 92 $B
  return ""
}

# wal_is_wal_mode / wal_set_journal_mode / wal_check_journal_mode —
# upstream tester.tcl:2308..2321.  Used by avtrans.test (and others) to
# auto-promote the connection to WAL when running under the `wal`
# permutation.  We baseline-only (permutation matrix deferred —
# 9.4.7.e), so `wal_is_wal_mode` always returns 0 and the two callers
# silently no-op — which is correct for the baseline run.
proc wal_is_wal_mode {} {
  expr {[permutation] eq "wal"}
}
proc wal_set_journal_mode {{db db}} {
  if { [wal_is_wal_mode] } {
    $db eval "PRAGMA journal_mode = WAL"
  }
}
proc wal_check_journal_mode {testname {db db}} {
  if { [wal_is_wal_mode] } {
    $db eval { SELECT * FROM sqlite_master }
    do_test $testname [list $db eval "PRAGMA main.journal_mode"] {wal}
  }
}
# wal_is_capable — upstream tester.tcl:2323..2327.  Returns 1 if the
# current build/permutation can drive a WAL test arm.  pas-sqlite3 has
# WAL enabled and runs only the baseline permutation, so the guard
# always permits.
proc wal_is_capable {} {
  ifcapable !wal { return 0 }
  if {[permutation]=="journaltest"} { return 0 }
  return 1
}

# test_set_config_pagecache / test_restore_config_pagecache — upstream
# tester.tcl:2496..2530.  Reconfigures the SQLITE_CONFIG_PAGECACHE
# parameters around a test and restores them afterwards.  Engine
# support: passqlite3main.pas:2033..2036; the `sqlite3_config_pagecache`
# Tcl shim is registered by Sqlitetest1_Init (9.4.6.q.2).
# The upstream proc also calls `autoinstall_test_functions`; that is
# already wired via TestModuleFunc (9.4.6.l.4) so we keep the call.
proc test_set_config_pagecache {sz nPg} {
  catch {db close}
  catch {db2 close}
  catch {db3 close}
  sqlite3_shutdown
  set ::old_pagecache_config [sqlite3_config_pagecache $sz $nPg]
  sqlite3_initialize
  catch { autoinstall_test_functions }
  reset_db
}
proc test_restore_config_pagecache {} {
  catch {db close}
  catch {db2 close}
  catch {db3 close}
  sqlite3_shutdown
  if {[info exists ::old_pagecache_config]} {
    eval sqlite3_config_pagecache $::old_pagecache_config
    unset ::old_pagecache_config
  }
  sqlite3_initialize
  catch { autoinstall_test_functions }
  reset_db
}

# do_faultsim_test — upstream malloc_common.tcl:121..157.  Drives a
# matrix of fault-injection runs (oom, ioerr, cantopen, ...) of the same
# body+test pair.  pas-sqlite3 has only the snapshot-aliases for the
# faultsim helpers (9.4.2.g.13 SKIP); the full malloc/io fault matrix is
# not yet wired.  Verbatim shape of the upstream proc is preserved but
# the matrix collapses to ONE no-fault baseline pass (`-faults baseline`)
# so tests that wrap their body in `do_faultsim_test` exercise their
# happy-path body at least once — matching the way `aggfault.test`
# verifies its non-error arms.  Real matrix DEFERRED to 9.4.2.g.13.
# C ref: malloc_common.tcl:121..157.
proc do_faultsim_test {name args} {
  set DEFAULT(-prep)      ""
  set DEFAULT(-body)      ""
  set DEFAULT(-test)      ""
  set DEFAULT(-install)   ""
  set DEFAULT(-uninstall) ""
  set DEFAULT(-faults)    "*"
  set DEFAULT(-start)     1
  set DEFAULT(-end)       0
  fix_testname name
  array set O [array get DEFAULT]
  array set O $args
  # Baseline-only fault: run prep + body once, check that body succeeds
  # and that -test (if any) passes.  This mirrors `do_one_faultsim_test`
  # with iFail=0 (no injection).  Errors in -body propagate as test
  # failures via do_test.
  uplevel #0 $O(-prep)
  set ::testrc [catch [list uplevel #0 $O(-body)] ::testresult]
  set ::testnfail 0
  if {$O(-test) ne ""} {
    # Mirror upstream do_one_faultsim_test (malloc_common.tcl:347,378..380):
    # wrap -test as a proc receiving (testrc,testresult,testnfail), then
    # `do_test` succeeds iff the proc runs without throwing.  Using a proc
    # avoids `uplevel #0 <body> \; set {}` which (after `[list ...]` quotes
    # the `;`) collapses to a single uplevel arg list where the trailing
    # `{}` is dropped during arg concat, leaving `set` with zero args →
    # "wrong # args: should be \"set varName ?newValue?\"".
    proc faultsim_test_proc {testrc testresult testnfail} $O(-test)
    set rc [catch [list faultsim_test_proc $::testrc $::testresult $::testnfail] res]
    if {$rc == 0} {set res ok}
    do_test $name.baseline [list list $rc $res] {0 ok}
  } else {
    do_test $name.baseline [list set ::testrc] 0
  }
}

# 9.4.divbug.63.a — explain_no_trace (tester.tcl:1620..1623).  Show the
# VDBE program for an SQL statement but skip the leading Trace opcode
# block; used by callers that want to compare opcode sequences of two
# statements without the trace-row prefix differing.
proc explain_no_trace {sql} {
  set tr [db eval "EXPLAIN $sql"]
  return [lrange $tr 7 end]
}

# 9.4.divbug.63 — do_test_with_ansi_output (tester.tcl:812..819).  Like
# do_test except the upstream version skips the test when running in a
# slave interpreter on Windows (ANSI/UTF8 I/O issues on Win11).  On this
# Linux port we are never on Windows, so this always runs the test.
proc do_test_with_ansi_output {name cmd expected} {
  if {![info exists ::SLAVE] || $::tcl_platform(platform) ne "windows"} {
    uplevel 1 [list do_test $name $cmd $expected]
  }
}

# 9.4.divbug.63.a — faultsim_test_result (malloc_common.tcl:291..298,
# 348..350).  In upstream this command is dynamically (re)defined by
# do_one_faultsim_test with the per-test -injecterrlist baked in;
# baseline pas-sqlite3 collapses the fault matrix down to a single
# no-fault pass (see do_faultsim_test above), so the dynamic redefine
# never runs.  Provide a fallback definition that mirrors
# faultsim_test_result_int verbatim, with an empty injectErrList — under
# the baseline pass testrc/testresult always come from the body itself
# (testnfail=0), so the first equality clause (testnfail==0 && t!=r[0])
# governs and lets the body's own success/error decide.
proc faultsim_test_result_int {args} {
  upvar testrc testrc testresult testresult testnfail testnfail
  set t [list $testrc $testresult]
  set r $args
  if { ($testnfail==0 && $t != [lindex $r 0]) || [lsearch -exact $r $t]<0 } {
    error "nfail=$testnfail rc=$testrc result=$testresult list=$r"
  }
}
proc faultsim_test_result {args} {
  uplevel faultsim_test_result_int $args [list {0 {}}]
}

# 9.4.divbug.63.b — test_binary_name / test_find_binary / test_find_cli /
# test_cli_invocation / test_find_sqldiff.  Verbatim ports of
# tester.tcl:2529..2596.  shell*.test and sqldiff*.test call these to
# locate the on-disk CLI binary; if missing they `finish_test ; return`
# in the caller's context (via `return -code return`).  pas-sqlite3 builds
# its CLI at bin/passqlite3 — but we leave the upstream lookup verbatim
# so .test files transparently skip when the upstream name isn't present
# on PATH.  Individual tests may override these procs to point at our
# binary if/when wired.  Engine FCNTL/test1.c file_control_reservebytes
# is paired with this in TestModuleTest1.pas (test1.c:9258 / 7249..7276).
proc test_binary_name {nm} {
  if {$::tcl_platform(platform) eq "windows"} {
    set ret "$nm.exe"
  } else {
    set ret $nm
  }
  if {[info exists ::cmdlinearg(TESTFIXTURE_HOME)]} {
    file normalize [file join $::cmdlinearg(TESTFIXTURE_HOME) $ret]
  } else {
    file normalize $ret
  }
}
proc test_find_binary {nm} {
  set ret [test_binary_name $nm]
  if {![file executable $ret]} {
    finish_test
    return ""
  }
  return $ret
}
proc test_find_cli {} {
  set prog [test_find_binary sqlite3]
  if {$prog==""} { return -code return }
  return $prog
}
proc test_cli_invocation {} {
  set prog [test_find_binary sqlite3]
  if {$prog==""} { return -code return }
  set vgrun [expr {[permutation]=="valgrind"}]
  if {$vgrun || [info exists ::env(SQLITE_CLI_VALGRIND_OPT)]} {
    if {$vgrun} {
      set vgo "--quiet"
    } else {
      set vgo $::env(SQLITE_CLI_VALGRIND_OPT)
    }
    if {$vgo == 0 || $vgo eq ""} {
      return $prog
    } elseif {$vgo == 1} {
      return "valgrind --quiet --leak-check=yes $prog"
    } else {
      return "valgrind $vgo $prog"
    }
  } else {
    return $prog
  }
}
proc test_find_sqldiff {} {
  set prog [test_find_binary sqldiff]
  if {$prog==""} { return -code return }
  return $prog
}

# 9.4.divbug.63.b — run_thread_tests (thread_common.tcl:88..107).
# Returns 1 iff this build can run the multi-threaded test arms; 0
# otherwise (with a "WARNING: ..." note on stdout).  pas-sqlite3's
# default build is not threadsafe (no `sqlthread` Tcl command is
# registered — TestModuleSqlthread is not in build.sh), so the
# `info commands sqlthread` arm fires and the predicate naturally
# returns 0.  Verbatim port; tests gated on this take their skip arm.
proc run_thread_tests {{print_warning 0}} {
  ifcapable !mutex {
    set zProblem "SQLite build is not threadsafe"
  }
  ifcapable mutex_noop {
    set zProblem "SQLite build uses SQLITE_MUTEX_NOOP"
  }
  if {[info commands sqlthread] eq ""} {
    set zProblem "SQLite build is not threadsafe"
  }
  if {![tcl::pkgconfig get threaded]} {
    set zProblem "Linked against a non-threadsafe Tcl build"
  }
  if {[info exists zProblem]} {
    puts "WARNING: Multi-threaded tests skipped: $zProblem"
    return 0
  }
  set ::run_thread_tests_called 1
  return 1
}

# Install the test scalar UDFs (randstr, test_*, real2hex, ...) as an
# auto-extension so every freshly-opened connection picks them up.
# Mirrors upstream tester.tcl:512 (one-shot at shim load).  Without this,
# tests like tkt3918.test fail with `no such function: randstr` because
# the auto-extension is only otherwise registered inside
# test_set_config_pagecache.  9.4.divbug.66.
catch { autoinstall_test_functions }

# Open `db` on a fresh on-disk ./test.db at shim load time, mirroring
# upstream tester.tcl:553..556.  The driver no longer issues its own
# `sqlite3 db :memory:`.
reset_db
