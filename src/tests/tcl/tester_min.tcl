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
    # (tester.tcl:789..792); we don't have that helper ported, so the
    # exact-compare result stands.
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

# execsql — upstream tester.tcl:1445..1448.  Verbatim.
proc execsql {sql {db db}} {
  uplevel [list $db eval $sql]
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
# compile-time caps (see fix_ifcapable_expr) and runs BODY iff true,
# else ELSEBODY.  pas-sqlite3 is built with the default set of caps
# enabled (no SQLITE_OMIT_*), so for our smoke sweeps every expression
# evaluates true — we unconditionally uplevel BODY and ignore both EXPR
# and ELSEBODY.  Real cap-probe wiring lives behind 9.4.6.a / 9.4.2.g.1
# follow-up.  C ref: tester.tcl:1725..1739.
proc ifcapable {expr code {else ""} {elsecode ""}} {
  set c [catch {uplevel 1 $code} r]
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

# expected — passthrough stub.  Upstream tester.tcl has no such proc as
# a self-contained helper (the word "expected" only appears as a
# parameter name to do_test, see upstream lines 692..702).  A handful
# of community .test files call `expected $n $val` to label assertions;
# returning the value unchanged keeps those scripts source-able.
proc expected {n exp} { return $exp }

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
proc faultsim_save {args} { uplevel db_save $args }
proc faultsim_save_and_close {args} { uplevel db_save_and_close $args }
proc faultsim_restore {args} { uplevel db_restore $args }
proc faultsim_restore_and_reopen {args} {
  uplevel db_restore_and_reopen $args
}
proc faultsim_delete_and_reopen {args} {
  uplevel db_delete_and_reopen $args
}

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
# C ref: tester.tcl:548..558.
proc reset_db {} {
  catch {db close}
  forcedelete test.db
  forcedelete test.db-journal
  forcedelete test.db-wal
  forcedelete test.db-shm
  sqlite3 db ./test.db
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

# Open `db` on a fresh on-disk ./test.db at shim load time, mirroring
# upstream tester.tcl:553..556.  The driver no longer issues its own
# `sqlite3 db :memory:`.
reset_db
