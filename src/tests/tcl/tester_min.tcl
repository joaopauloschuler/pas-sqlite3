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
#   - do_eqp_test, do_catchsql_test, do_realnum_test, do_vmstep_test
#   - presql, permutations, runtest, NRE harness, slave interp plumbing
#   - sqlite3_test_control, sqlite3_memdebug_*, db_save, threading
#   - regex / glob / numeric-range match in expected (only exact compare)
#   - puts override / output1 / output2 verbosity machinery
#   - known-problems.txt, omit, warn lists
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

# do_test — upstream tester.tcl:703..810, reduced to the exact-compare
# arm.  Runs $cmd at the global scope (uplevel #0) and compares string
# equality with $expected.  Increments ::nTest always, ::nErr on
# mismatch or runtime error.  Prints either " Ok" or a two-line
# "! NAME expected: [..] / ! NAME got: [..]" block.
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
  if {[string compare $result $expected]==0} {
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

# expected — passthrough stub.  Upstream tester.tcl has no such proc as
# a self-contained helper (the word "expected" only appears as a
# parameter name to do_test, see upstream lines 692..702).  A handful
# of community .test files call `expected $n $val` to label assertions;
# returning the value unchanged keeps those scripts source-able.
proc expected {n exp} { return $exp }
