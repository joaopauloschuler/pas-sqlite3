{
  SPDX-License-Identifier: blessing

  Faithful port of ../sqlite3/ext/misc/pcachetrace.c (179 lines in C).

  Tracing layer over SQLITE_CONFIG_GETPCACHE2 / SQLITE_CONFIG_PCACHE2
  that logs every xCreate / xFetch / xUnpin / etc call on the registered
  FILE*.  Used by the shell's --pcachetrace option.

  Pascal-port note: the page cache method record fields use the
  default Pascal calling convention (matching pcache1Init etc., which
  the existing pcache1 module installs without cdecl).  All trampolines
  here therefore use the default convention as well.

  Public entries:
    sqlite3PcacheTraceActivate(out)   — sqlite3PcacheTraceActivate
    sqlite3PcacheTraceDeactivate      — sqlite3PcacheTraceDeactivate
}
{$I passqlite3.inc}
unit passqlite3pcachetrace;

interface

uses
  passqlite3types,
  passqlite3util;

function sqlite3PcacheTraceActivate(outFile: Pointer): i32;
function sqlite3PcacheTraceDeactivate: i32;

implementation

var
  { pcachetrace.c:29 — original (replaced) page cache methods. }
  pcacheBase:     Tsqlite3_pcache_methods2;
  { pcachetrace.c:30 — FILE* sink, nil disables tracing. }
  pcachetraceOut: Pointer = nil;

function fprintf(stream: Pointer; fmt: PAnsiChar): i32; cdecl; varargs;
  external 'c' name 'fprintf';

{ pcachetrace.c:33..43 — pcachetraceInit. }
function pcachetraceInit(pArg: Pointer): i32;
var nRes: i32;
begin
  if pcachetraceOut <> nil then
    fprintf(pcachetraceOut, 'PCACHETRACE: xInit(%p)'#10, pArg);
  nRes := pcacheBase.xInit(pArg);
  if pcachetraceOut <> nil then
    fprintf(pcachetraceOut, 'PCACHETRACE: xInit(%p) -> %d'#10, pArg, nRes);
  Result := nRes;
end;

{ pcachetrace.c:44..49 — pcachetraceShutdown. }
procedure pcachetraceShutdown(pArg: Pointer);
begin
  if pcachetraceOut <> nil then
    fprintf(pcachetraceOut, 'PCACHETRACE: xShutdown(%p)'#10, pArg);
  pcacheBase.xShutdown(pArg);
end;

{ pcachetrace.c:50..62 — pcachetraceCreate. }
function pcachetraceCreate(szPage, szExtra, bPurge: i32): Pointer;
var pRes: Pointer;
begin
  if pcachetraceOut <> nil then
    fprintf(pcachetraceOut, 'PCACHETRACE: xCreate(%d,%d,%d)'#10,
            szPage, szExtra, bPurge);
  pRes := pcacheBase.xCreate(szPage, szExtra, bPurge);
  if pcachetraceOut <> nil then
    fprintf(pcachetraceOut, 'PCACHETRACE: xCreate(%d,%d,%d) -> %p'#10,
            szPage, szExtra, bPurge, pRes);
  Result := pRes;
end;

{ pcachetrace.c:63..68 — pcachetraceCachesize. }
procedure pcachetraceCachesize(p: Pointer; nCachesize: i32);
begin
  if pcachetraceOut <> nil then
    fprintf(pcachetraceOut, 'PCACHETRACE: xCachesize(%p, %d)'#10,
            p, nCachesize);
  pcacheBase.xCachesize(p, nCachesize);
end;

{ pcachetrace.c:69..79 — pcachetracePagecount. }
function pcachetracePagecount(p: Pointer): i32;
var nRes: i32;
begin
  if pcachetraceOut <> nil then
    fprintf(pcachetraceOut, 'PCACHETRACE: xPagecount(%p)'#10, p);
  nRes := pcacheBase.xPagecount(p);
  if pcachetraceOut <> nil then
    fprintf(pcachetraceOut, 'PCACHETRACE: xPagecount(%p) -> %d'#10, p, nRes);
  Result := nRes;
end;

{ pcachetrace.c:80..95 — pcachetraceFetch. }
function pcachetraceFetch(p: Pointer; key: u32;
  crFg: i32): Psqlite3_pcache_page;
var pRes: Psqlite3_pcache_page;
begin
  if pcachetraceOut <> nil then
    fprintf(pcachetraceOut, 'PCACHETRACE: xFetch(%p,%u,%d)'#10,
            p, key, crFg);
  pRes := pcacheBase.xFetch(p, key, crFg);
  if pcachetraceOut <> nil then
    fprintf(pcachetraceOut, 'PCACHETRACE: xFetch(%p,%u,%d) -> %p'#10,
            p, key, crFg, pRes);
  Result := pRes;
end;

{ pcachetrace.c:96..106 — pcachetraceUnpin. }
procedure pcachetraceUnpin(p: Pointer; pPg: Psqlite3_pcache_page;
  bDiscard: i32);
begin
  if pcachetraceOut <> nil then
    fprintf(pcachetraceOut, 'PCACHETRACE: xUnpin(%p, %p, %d)'#10,
            p, pPg, bDiscard);
  pcacheBase.xUnpin(p, pPg, bDiscard);
end;

{ pcachetrace.c:107..118 — pcachetraceRekey. }
procedure pcachetraceRekey(p: Pointer; pPg: Psqlite3_pcache_page;
  oldKey, newKey: u32);
begin
  if pcachetraceOut <> nil then
    fprintf(pcachetraceOut, 'PCACHETRACE: xRekey(%p, %p, %u, %u)'#10,
            p, pPg, oldKey, newKey);
  pcacheBase.xRekey(p, pPg, oldKey, newKey);
end;

{ pcachetrace.c:119..124 — pcachetraceTruncate. }
procedure pcachetraceTruncate(p: Pointer; n: u32);
begin
  if pcachetraceOut <> nil then
    fprintf(pcachetraceOut, 'PCACHETRACE: xTruncate(%p, %u)'#10, p, n);
  pcacheBase.xTruncate(p, n);
end;

{ pcachetrace.c:125..130 — pcachetraceDestroy. }
procedure pcachetraceDestroy(p: Pointer);
begin
  if pcachetraceOut <> nil then
    fprintf(pcachetraceOut, 'PCACHETRACE: xDestroy(%p)'#10, p);
  pcacheBase.xDestroy(p);
end;

{ pcachetrace.c:131..136 — pcachetraceShrink. }
procedure pcachetraceShrink(p: Pointer);
begin
  if pcachetraceOut <> nil then
    fprintf(pcachetraceOut, 'PCACHETRACE: xShrink(%p)'#10, p);
  pcacheBase.xShrink(p);
end;

var
  { pcachetrace.c:139..153 — substitute pcache methods. }
  ersaztPcacheMethods: Tsqlite3_pcache_methods2;

{ pcachetrace.c:156..166 — sqlite3PcacheTraceActivate. }
function sqlite3PcacheTraceActivate(outFile: Pointer): i32;
var rc: i32;
begin
  rc := SQLITE_OK;
  if not Assigned(pcacheBase.xFetch) then begin
    rc := sqlite3_config(SQLITE_CONFIG_GETPCACHE2, @pcacheBase);
    if rc = SQLITE_OK then
      rc := sqlite3_config(SQLITE_CONFIG_PCACHE2, @ersaztPcacheMethods);
  end;
  pcachetraceOut := outFile;
  Result := rc;
end;

{ pcachetrace.c:169..179 — sqlite3PcacheTraceDeactivate. }
function sqlite3PcacheTraceDeactivate: i32;
var rc: i32;
begin
  rc := SQLITE_OK;
  if Assigned(pcacheBase.xFetch) then begin
    rc := sqlite3_config(SQLITE_CONFIG_PCACHE2, @pcacheBase);
    if rc = SQLITE_OK then
      FillChar(pcacheBase, SizeOf(pcacheBase), 0);
  end;
  pcachetraceOut := nil;
  Result := rc;
end;

initialization
  FillChar(pcacheBase,          SizeOf(pcacheBase),          0);
  FillChar(ersaztPcacheMethods, SizeOf(ersaztPcacheMethods), 0);
  { iVersion stays 0 to match the C source's initializer (which sets
    iVersion=0 / pArg=0 in the leading positions). }
  ersaztPcacheMethods.xInit      := @pcachetraceInit;
  ersaztPcacheMethods.xShutdown  := @pcachetraceShutdown;
  ersaztPcacheMethods.xCreate    := @pcachetraceCreate;
  ersaztPcacheMethods.xCachesize := @pcachetraceCachesize;
  ersaztPcacheMethods.xPagecount := @pcachetracePagecount;
  ersaztPcacheMethods.xFetch     := @pcachetraceFetch;
  ersaztPcacheMethods.xUnpin     := @pcachetraceUnpin;
  ersaztPcacheMethods.xRekey     := @pcachetraceRekey;
  ersaztPcacheMethods.xTruncate  := @pcachetraceTruncate;
  ersaztPcacheMethods.xDestroy   := @pcachetraceDestroy;
  ersaztPcacheMethods.xShrink    := @pcachetraceShrink;
end.
