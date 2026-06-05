#!/bin/bash
# Usage: ./run_one_tcl.sh <testname-without-.test>
# Runs a single upstream tcl test against the pas lib, prints failing subtests.
T="$1"
BIN="$(pwd)/bin"
TCLDIR="$(pwd)/src/tests/tcl"
TESTF="$(pwd)/../sqlite3/test/${T}.test"
TMP=$(mktemp -d)
cat > "$TMP/run.tcl" <<TCL
lappend ::auto_path {$BIN}
if {[catch {package require sqlite3}]} { load {$BIN/libpassqlite3tcl.so} Sqlite3; package require sqlite3 }
cd {$TMP}
set ::testdir {$TCLDIR}
source \$::testdir/tester_min.tcl
set ::pas_shim_dir {$TCLDIR}
rename source __orig_source
proc source {path args} {
  set tail [file tail \$path]
  if {\$tail eq "tester.tcl"} { return [uplevel 1 [list __orig_source \$::pas_shim_dir/tester_min.tcl]] }
  if {\$tail eq "permutations.test"} { return [uplevel 1 [list __orig_source \$::pas_shim_dir/permutations.test]] }
  return [uplevel 1 __orig_source [list \$path] \$args]
}
set ::argv0 {$TESTF}
set ::argv {}; set ::argc 0
__orig_source {$TESTF}
TCL
cd "$TMP"
timeout 90 tclsh "$TMP/run.tcl" 2>&1
cd - >/dev/null
rm -rf "$TMP"
