# 2009 November 04
#
# The author disclaims copyright to this source code.  In place of
# a legal notice, here is a blessing:
#
#    May you do good and not evil.
#    May you find forgiveness for yourself and forgive others.
#    May you share freely, never taking more than you give.
#
#***********************************************************************
#
# This file contains common code used the fts3 tests. At one point
# equivalent functionality was implemented in C code. But it is easier
# to use Tcl.
#
# pas-sqlite3 shim (9.4.divbug.61) — based verbatim on upstream
# test/fts3_common.tcl with the following minimal accommodations so it
# can be sourced under the Tcl-bridge harness that lacks the C-side
# test commands:
#
#   * sqlite3_fts3_may_be_corrupt — no-op proc.  Upstream is a TCL_CMD
#     in test1.c that toggles a fault-injection flag; with that flag
#     untoggleable from our bridge we simply accept-and-ignore so the
#     `ifcapable fts3 { sqlite3_fts3_may_be_corrupt 0 }` source-time
#     call doesn't blow up the file.
#
#   * read_fts3varint — pure-Tcl port of the C helper in
#     ../sqlite3/src/test_hexio.c:368.  Same algorithm (little-endian
#     7-bit varint, high-bit = continuation) so gobble_varint /
#     fts3_readleaf / fts3_terms / fts3_doclist all work without the
#     C-side test command.
#
#   * fts3_tokenizer_test — used only by fts3_integrity_check via the
#     `SELECT fts3_tokenizer_test('simple', $c)` SQL statement.  The
#     SQL function lives in ../sqlite3/ext/fts3/fts3_tokenizer.c which
#     pas-sqlite3 has not ported.  Tests that exercise this path
#     (currently only fts4merge.test integrity_check arms) will surface
#     "no such function: fts3_tokenizer_test" at runtime — that is a
#     known unported surface, tracked separately, not a regression
#     introduced by this shim.

#-------------------------------------------------------------------------
# INSTRUCTIONS  (verbatim from upstream)
#
#   fts3_build_db_1 N
#   fts3_build_db_2 N
#   fts3_integrity_check TBL
#   fts3_terms TBL WHERE
#   fts3_doclist TBL TERM WHERE
#

#-------------------------------------------------------------------------
# pas-sqlite3 shim: stub sqlite3_fts3_may_be_corrupt as no-op so the
# `ifcapable fts3 { sqlite3_fts3_may_be_corrupt 0 }` source-time toggle
# below can succeed without the C-side test command.
if {[info commands sqlite3_fts3_may_be_corrupt] eq ""} {
  proc sqlite3_fts3_may_be_corrupt {args} {}
}

ifcapable fts3 {
  sqlite3_fts3_may_be_corrupt 0
}

#-------------------------------------------------------------------------
# USAGE: fts3_build_db_1 SWITCHES N
#
# Build a sample FTS table in the database opened by database connection
# [db]. The name of the new table is "t1".
#
proc fts3_build_db_1 {args} {

  set default(-module) fts4

  set nArg [llength $args]
  if {($nArg%2)==0} {
    error "wrong # args: should be \"fts3_build_db_1 ?switches? n\""
  }

  set n [lindex $args [expr $nArg-1]]
  array set opts [array get default]
  array set opts [lrange $args 0 [expr $nArg-2]]
  foreach k [array names opts] {
    if {0==[info exists default($k)]} { error "unknown option: $k" }
  }

  if {$n > 10000} {error "n must be <= 10000"}
  db eval "CREATE VIRTUAL TABLE t1 USING $opts(-module) (x, y)"

  set xwords [list zero one two three four five six seven eight nine ten]
  set ywords [list alpha beta gamma delta epsilon zeta eta theta iota kappa]

  for {set i 0} {$i < $n} {incr i} {
    set x ""
    set y ""

    set x [list]
    lappend x [lindex $xwords [expr ($i / 1000) % 10]]
    lappend x [lindex $xwords [expr ($i / 100)  % 10]]
    lappend x [lindex $xwords [expr ($i / 10)   % 10]]
    lappend x [lindex $xwords [expr ($i / 1)   % 10]]

    set y [list]
    lappend y [lindex $ywords [expr ($i / 1000) % 10]]
    lappend y [lindex $ywords [expr ($i / 100)  % 10]]
    lappend y [lindex $ywords [expr ($i / 10)   % 10]]
    lappend y [lindex $ywords [expr ($i / 1)   % 10]]

    db eval { INSERT INTO t1(docid, x, y) VALUES($i, $x, $y) }
  }
}

#-------------------------------------------------------------------------
# USAGE: fts3_build_db_2 N ARGS
#
# Build a sample FTS table in the database opened by database connection
# [db]. The name of the new table is "t2".
#
proc fts3_build_db_2 {args} {

  set default(-module) fts4
  set default(-extra)   ""

  set nArg [llength $args]
  if {($nArg%2)==0} {
    error "wrong # args: should be \"fts3_build_db_1 ?switches? n\""
  }

  set n [lindex $args [expr $nArg-1]]
  array set opts [array get default]
  array set opts [lrange $args 0 [expr $nArg-2]]
  foreach k [array names opts] {
    if {0==[info exists default($k)]} { error "unknown option: $k" }
  }

  if {$n > 100000} {error "n must be <= 100000"}

  set sql "CREATE VIRTUAL TABLE t2 USING $opts(-module) (content"
  if {$opts(-extra) != ""} {
    append sql ", " $opts(-extra)
  }
  append sql ")"
  db eval $sql

  set chars [list a b c d e f g h  i j k l m n o p  q r s t u v w x  y z ""]

  for {set i 0} {$i < $n} {incr i} {
    set word ""
    set nChar [llength $chars]
    append word [lindex $chars [expr {($i / 1)   % $nChar}]]
    append word [lindex $chars [expr {($i / $nChar)  % $nChar}]]
    append word [lindex $chars [expr {($i / ($nChar*$nChar)) % $nChar}]]

    db eval { INSERT INTO t2(docid, content) VALUES($i, $word) }
  }
}

#-------------------------------------------------------------------------
# pas-sqlite3 shim: pure-Tcl port of read_fts3varint from upstream
# ../sqlite3/src/test_hexio.c:368.  Reads a little-endian 7-bit varint
# from BLOB (a Tcl byte-array), stores the decoded value into the
# caller's VARNAME, and returns the number of bytes consumed.
#
# C reference (test_hexio.c:338):
#   x = 0; y = 1;
#   while( (*q & 0x80) == 0x80 ){ x += y * (*q++ & 0x7f); y <<= 7; }
#   x += y * (*q++);
#
if {[info commands read_fts3varint] eq ""} {
  proc read_fts3varint {blob varname} {
    upvar $varname out
    set q [list]
    binary scan $blob c* q
    set x 0
    set y 1
    set i 0
    set n [llength $q]
    while {$i < $n} {
      set b [expr {[lindex $q $i] & 0xff}]
      incr i
      if {($b & 0x80) == 0x80} {
        set x [expr {$x + $y * ($b & 0x7f)}]
        set y [expr {$y << 7}]
      } else {
        set x [expr {$x + $y * $b}]
        break
      }
    }
    set out $x
    return $i
  }
}

#-------------------------------------------------------------------------
# USAGE: fts3_integrity_check TBL
#
# This proc is used to verify that the full-text index is consistent with
# the contents of the fts3 table.
#
# pas-sqlite3 note: relies on the `fts3_tokenizer_test('simple', $c)` SQL
# function which is provided by ../sqlite3/ext/fts3/fts3_tokenizer.c —
# that extension is NOT ported in pas-sqlite3, so callers will see
# "no such function: fts3_tokenizer_test" at runtime.  TODO: port the
# fts3_tokenizer_test SQL function (or shim a pure-Tcl 'simple'
# tokenizer here) once the rest of fts3 stabilises.
#
proc fts3_integrity_check {tbl} {

  fts3_read2 $tbl 1 A

  foreach zTerm [array names A] {
    foreach doclist $A($zTerm) {
      set docid 0
      while {[string length $doclist]>0} {
        set iCol 0
        set iPos 0
        set lPos [list]
        set lCol [list]

        incr docid [gobble_varint doclist]
        if {[info exists D($zTerm,$docid)]} {
          while {[set iDelta [gobble_varint doclist]] != 0} {}
          continue
        }
        set D($zTerm,$docid) 1

        while {[set iDelta [gobble_varint doclist]] > 0} {
          if {$iDelta == 1} {
            set iCol [gobble_varint doclist]
            set iPos 0
          } else {
            incr iPos $iDelta
            incr iPos -2
            set C($docid,$iCol,$iPos) $zTerm
          }
        }
      }
    }
  }

  foreach key [array names C] {
  }


  db eval "SELECT * FROM ${tbl}_content" E {
    set iCol 0
    set iDoc $E(docid)
    foreach col [lrange $E(*) 1 end] {
      set c $E($col)
      set sql {SELECT fts3_tokenizer_test('simple', $c)}

      foreach {pos term dummy} [db one $sql] {
        if {![info exists C($iDoc,$iCol,$pos)]} {
          set es "Error at docid=$iDoc col=$iCol pos=$pos. Index is missing"
          lappend errors $es
        } else {
          if {[string compare $C($iDoc,$iCol,$pos) $term]} {
            set    es "Error at docid=$iDoc col=$iCol pos=$pos. Index "
            append es "has \"$C($iDoc,$iCol,$pos)\", document has \"$term\""
            lappend errors $es
          }
          unset C($iDoc,$iCol,$pos)
        }
      }
      incr iCol
    }
  }

  foreach c [array names C] {
    lappend errors "Bad index entry: $c -> $C($c)"
  }

  if {[info exists errors]} { return [join $errors "\n"] }
  return "ok"
}

# USAGE: fts3_terms TBL WHERE
proc fts3_terms {tbl where} {
  fts3_read $tbl $where a
  return [lsort [array names a]]
}


# USAGE: fts3_doclist TBL TERM WHERE
proc fts3_doclist {tbl term where} {
  fts3_read $tbl $where a


  foreach doclist $a($term) {
    set docid 0

    while {[string length $doclist]>0} {
      set iCol 0
      set iPos 0
      set lPos [list]
      set lCol [list]
      incr docid [gobble_varint doclist]

      while {[set iDelta [gobble_varint doclist]] > 0} {
        if {$iDelta == 1} {
          lappend lCol [list $iCol $lPos]
          set iPos 0
          set lPos [list]
          set iCol [gobble_varint doclist]
        } else {
          incr iPos $iDelta
          incr iPos -2
          lappend lPos $iPos
        }
      }

      if {[llength $lPos]>0} {
        lappend lCol [list $iCol $lPos]
      }

      if {$where != "1" || [llength $lCol]>0} {
        set ret($docid) $lCol
      } else {
        unset -nocomplain ret($docid)
      }
    }
  }

  set lDoc [list]
  foreach docid [lsort -integer [array names ret]] {
    set lCol [list]
    set cols ""
    foreach col $ret($docid) {
      foreach {iCol lPos} $col {}
      append cols " $iCol\[[join $lPos { }]\]"
    }
    lappend lDoc "\[${docid}${cols}\]"
  }

  join $lDoc " "
}

###########################################################################

proc gobble_varint {varname} {
  upvar $varname blob
  set n [read_fts3varint $blob ret]
  set blob [string range $blob $n end]
  return $ret
}
proc gobble_string {varname nLength} {
  upvar $varname blob
  set ret [string range $blob 0 [expr $nLength-1]]
  set blob [string range $blob $nLength end]
  return $ret
}

# The argument is a blob of data representing an FTS3 segment leaf.
# Return a list consisting of alternating terms (strings) and doclists
# (blobs of data).
#
proc fts3_readleaf {blob} {
  set zPrev ""
  set terms [list]

  while {[string length $blob] > 0} {
    set nPrefix [gobble_varint blob]
    set nSuffix [gobble_varint blob]

    set zTerm [string range $zPrev 0 [expr $nPrefix-1]]
    append zTerm [gobble_string blob $nSuffix]
    set nDoclist [gobble_varint blob]
    set doclist [gobble_string blob $nDoclist]

    lappend terms $zTerm $doclist
    set zPrev $zTerm
  }

  return $terms
}

proc fts3_read2 {tbl where varname} {
  upvar $varname a
  array unset a
  db eval " SELECT start_block, leaves_end_block, root
            FROM ${tbl}_segdir WHERE $where
            ORDER BY level ASC, idx DESC
  " {
    set c 0
    binary scan $root c c
    if {$c==0} {
      foreach {t d} [fts3_readleaf $root] { lappend a($t) $d }
    } else {
      db eval " SELECT block
                FROM ${tbl}_segments
                WHERE blockid>=$start_block AND blockid<=$leaves_end_block
                ORDER BY blockid
      " {
        foreach {t d} [fts3_readleaf $block] { lappend a($t) $d }
      }
    }
  }
}

proc fts3_read {tbl where varname} {
  upvar $varname a
  array unset a
  db eval " SELECT start_block, leaves_end_block, root
            FROM ${tbl}_segdir WHERE $where
            ORDER BY level DESC, idx ASC
  " {
    if {$start_block == 0} {
      foreach {t d} [fts3_readleaf $root] { lappend a($t) $d }
    } else {
      db eval " SELECT block
                FROM ${tbl}_segments
                WHERE blockid>=$start_block AND blockid<$leaves_end_block
                ORDER BY blockid
      " {
        foreach {t d} [fts3_readleaf $block] { lappend a($t) $d }

      }
    }
  }
}

##########################################################################
