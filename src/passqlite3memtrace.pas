{
  SPDX-License-Identifier: blessing

  Faithful port of ../sqlite3/ext/misc/memtrace.c (108 lines in C).

  Tracing layer over SQLITE_CONFIG_GETMALLOC / SQLITE_CONFIG_MALLOC
  that logs every allocate / free / resize on the registered FILE*.
  Used by the shell's --memtrace option.

  Pascal-port note: the Pascal port currently routes most allocations
  directly to the C runtime's sqlite3_malloc rather than through
  sqlite3GlobalConfig.m, so activating this trace layer instruments only
  callers that route through the global config's xMalloc/xFree/xRealloc
  vector.  The activate / deactivate API is faithful to the C source.

  Public entries:
    sqlite3MemTraceActivate(out)   — equivalent to sqlite3MemTraceActivate
    sqlite3MemTraceDeactivate      — equivalent to sqlite3MemTraceDeactivate
}
{$I passqlite3.inc}
unit passqlite3memtrace;

interface

uses
  passqlite3types,
  passqlite3util;

function sqlite3MemTraceActivate(outFile: Pointer): i32;
function sqlite3MemTraceDeactivate: i32;

implementation

var
  { memtrace.c:29 — original (replaced) memory allocation routines. }
  memtraceBase: Tsqlite3_mem_methods;
  { memtrace.c:30 — the FILE* sink, or nil to disable tracing. }
  memtraceOut:  Pointer = nil;

{ Trampoline into libc fprintf via the FILE* that the caller passed.
  The shell uses stderr / stdout / a regular fopen()'d file; we treat
  the FILE pointer opaquely.  String built up beforehand to keep the
  cdecl variadic call simple. }
function fprintf(stream: Pointer; fmt: PAnsiChar): i32; cdecl; varargs;
  external 'c' name 'fprintf';

{ memtrace.c:33..39 — memtraceMalloc. }
function memtraceMalloc(n: i32): Pointer; cdecl;
begin
  if memtraceOut <> nil then
    fprintf(memtraceOut, 'MEMTRACE: allocate %d bytes'#10,
            memtraceBase.xRoundup(n));
  Result := memtraceBase.xMalloc(n);
end;

{ memtrace.c:40..46 — memtraceFree. }
procedure memtraceFree(p: Pointer); cdecl;
begin
  if p = nil then Exit;
  if memtraceOut <> nil then
    fprintf(memtraceOut, 'MEMTRACE: free %d bytes'#10, memtraceBase.xSize(p));
  memtraceBase.xFree(p);
end;

{ memtrace.c:47..58 — memtraceRealloc. }
function memtraceRealloc(p: Pointer; n: i32): Pointer; cdecl;
begin
  if p = nil then begin Result := memtraceMalloc(n); Exit; end;
  if n = 0 then begin memtraceFree(p); Result := nil; Exit; end;
  if memtraceOut <> nil then
    fprintf(memtraceOut, 'MEMTRACE: resize %d -> %d bytes'#10,
            memtraceBase.xSize(p), memtraceBase.xRoundup(n));
  Result := memtraceBase.xRealloc(p, n);
end;

{ memtrace.c:59..61 — memtraceSize. }
function memtraceSize(p: Pointer): i32; cdecl;
begin
  Result := memtraceBase.xSize(p);
end;

{ memtrace.c:62..64 — memtraceRoundup. }
function memtraceRoundup(n: i32): i32; cdecl;
begin
  Result := memtraceBase.xRoundup(n);
end;

{ memtrace.c:65..67 — memtraceInit. }
function memtraceInit(p: Pointer): i32; cdecl;
begin
  Result := memtraceBase.xInit(p);
end;

{ memtrace.c:68..70 — memtraceShutdown. }
procedure memtraceShutdown(p: Pointer); cdecl;
begin
  memtraceBase.xShutdown(p);
end;

var
  { memtrace.c:73..82 — substitute methods table. }
  ersaztMethods: Tsqlite3_mem_methods;

{ memtrace.c:85..95 — sqlite3MemTraceActivate. }
function sqlite3MemTraceActivate(outFile: Pointer): i32;
var rc: i32;
begin
  rc := SQLITE_OK;
  if not Assigned(memtraceBase.xMalloc) then begin
    rc := sqlite3_config(SQLITE_CONFIG_GETMALLOC, @memtraceBase);
    if rc = SQLITE_OK then
      rc := sqlite3_config(SQLITE_CONFIG_MALLOC, @ersaztMethods);
  end;
  memtraceOut := outFile;
  Result := rc;
end;

{ memtrace.c:98..108 — sqlite3MemTraceDeactivate. }
function sqlite3MemTraceDeactivate: i32;
var rc: i32;
begin
  rc := SQLITE_OK;
  if Assigned(memtraceBase.xMalloc) then begin
    rc := sqlite3_config(SQLITE_CONFIG_MALLOC, @memtraceBase);
    if rc = SQLITE_OK then
      FillChar(memtraceBase, SizeOf(memtraceBase), 0);
  end;
  memtraceOut := nil;
  Result := rc;
end;

initialization
  FillChar(memtraceBase,  SizeOf(memtraceBase), 0);
  FillChar(ersaztMethods, SizeOf(ersaztMethods), 0);
  ersaztMethods.xMalloc   := @memtraceMalloc;
  ersaztMethods.xFree     := @memtraceFree;
  ersaztMethods.xRealloc  := @memtraceRealloc;
  ersaztMethods.xSize     := @memtraceSize;
  ersaztMethods.xRoundup  := @memtraceRoundup;
  ersaztMethods.xInit     := @memtraceInit;
  ersaztMethods.xShutdown := @memtraceShutdown;
  ersaztMethods.pAppData  := nil;
end.
