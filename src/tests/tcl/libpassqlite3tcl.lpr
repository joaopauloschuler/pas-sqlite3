library libpassqlite3tcl;

{
  Phase 9.4.2.b — Pascal-side Tcl loadable package.

  Builds to bin/libpassqlite3tcl.so.  `tclsh` loads this via
      load /path/to/libpassqlite3tcl.so Sqlite3
  which dlopen()s the .so and dlsym()s `Sqlite3_Init`.

  The explicit `name 'Sqlite3_Init'` clauses below pin the exported
  symbol to the exact case Tcl probes for (Tcl computes the init-proc
  name from the second `load` arg by capitalising the first letter and
  appending "_Init" — see Tcl_LoadObjCmd in generic/tclLoad.c).  FPC
  would otherwise emit the symbol in the case as declared, but being
  explicit here documents the contract and survives any future
  exports-name mangling toggles.
}

{$mode objfpc}{$H+}

uses
  ctypes,
  PasTclBridge,
  TestModuleMd5,
  TestModuleTclvar,
  TestModuleEcho,
  TestModuleTest1,
  TestModuleFunc,
  TestModuleMalloc,
  TestModuleIoerr,
  PasTclSqlite;

exports
  Sqlite3_Init     name 'Sqlite3_Init',
  Sqlite3_SafeInit name 'Sqlite3_SafeInit';

end.
