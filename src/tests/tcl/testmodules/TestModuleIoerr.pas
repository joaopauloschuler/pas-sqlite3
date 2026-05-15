{
  SPDX-License-Identifier: blessing

  Port of the I/O-error injection counter wiring from
  ../sqlite3/src/test2.c:700..751 (task 9.4.7.c).

  The actual fault-injection machinery lives in passqlite3os.pas: the
  unix VFS read/write/sync/truncate methods are instrumented with
  {$ifdef SQLITE_TEST}-gated SimulateIOError / SimulateDiskfullError
  helpers, a faithful port of the SQLITE_TEST block in os_common.h.
  Those helpers consult a handful of global counters.

  This module's only job is the test2.c Tcl wiring: Tcl_LinkVar the
  counters into the interpreter as `sqlite_io_error_pending`,
  `sqlite_io_error_persist`, `sqlite_io_error_hit`,
  `sqlite_io_error_hardhit`, `sqlite_diskfull_pending` and
  `sqlite_diskfull` — the exact names malloc_common.tcl's
  ioerr_injectstart / do_ioerr_test drive.

  The whole unit is gated on {$ifdef SQLITE_TEST}: in a non-test build
  Sqlitetest2_Init is a no-op and the counters do not exist, so the
  default engine build is byte-for-byte unaffected.

  C ref: ../sqlite3/src/test2.c, ../sqlite3/src/os_common.h.
}
{$I passqlite3.inc}
unit TestModuleIoerr;

interface

uses
  ctypes,
  PasTclBridge;

{ test2.c:683 — Sqlitetest2_Init: register the test2 Tcl commands and
  link the I/O-error counters.  We currently only need the counter
  linkage, so that is all this stub does. }
function Sqlitetest2_Init(interp: PTclInterp): cint; cdecl;

implementation

{$ifdef SQLITE_TEST}
uses
  passqlite3os;
{$endif}

function Sqlitetest2_Init(interp: PTclInterp): cint; cdecl;
begin
{$ifdef SQLITE_TEST}
  { test2.c:740..751 — expose the injection counters to Tcl. }
  Tcl_LinkVar(interp, 'sqlite_io_error_pending',
    @sqlite3_io_error_pending, TCL_LINK_INT);
  Tcl_LinkVar(interp, 'sqlite_io_error_persist',
    @sqlite3_io_error_persist, TCL_LINK_INT);
  Tcl_LinkVar(interp, 'sqlite_io_error_hit',
    @sqlite3_io_error_hit, TCL_LINK_INT);
  Tcl_LinkVar(interp, 'sqlite_io_error_hardhit',
    @sqlite3_io_error_hardhit, TCL_LINK_INT);
  Tcl_LinkVar(interp, 'sqlite_io_error_benign',
    @sqlite3_io_error_benign, TCL_LINK_INT);
  Tcl_LinkVar(interp, 'sqlite_diskfull_pending',
    @sqlite3_diskfull_pending, TCL_LINK_INT);
  Tcl_LinkVar(interp, 'sqlite_diskfull',
    @sqlite3_diskfull, TCL_LINK_INT);
{$endif}
  Result := TCL_OK;
end;

end.
