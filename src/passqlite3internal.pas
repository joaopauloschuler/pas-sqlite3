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
{$I passqlite3.inc}
unit passqlite3internal;

{
  Shared constants, bit-flags, and primitive-level typedefs from sqliteInt.h.

  Porting strategy (Phase 0.9 — progressive):
    This unit is NOT a full port of sqliteInt.h (~5.9 k lines) upfront.
    Instead it carries only what can be safely ported without forward-referencing
    types that belong to later phases (btreeInt.h, vdbeInt.h, whereInt.h, etc.).

    As each subsequent phase begins, the sqliteInt.h structs required by that
    phase are added here.  Module-local headers travel with their modules:
      btreeInt.h  → passqlite3btree.pas
      vdbeInt.h   → passqlite3vdbe.pas
      whereInt.h  → passqlite3codegen.pas

    Field order MUST match C bit-for-bit; tests will memcmp these records.
    Do NOT reorder for alignment or readability.
}

interface

uses passqlite3types;

// ---------------------------------------------------------------------------
// Boolean-like constants (SQLite uses int / u8, never C99 bool)
// ---------------------------------------------------------------------------

const
  SQLITE_TRUE  = 1;
  SQLITE_FALSE = 0;

// ---------------------------------------------------------------------------
// Thread-safety model (matches SQLITE_THREADSAFE=1 default)
// ---------------------------------------------------------------------------

const
  SQLITE_THREADSAFE = 1; { Serialized — full mutex on each API call }

// ---------------------------------------------------------------------------
// Default journal mode  (matches plain ./configure)
// ---------------------------------------------------------------------------

const
  SQLITE_DEFAULT_JOURNAL_SIZE_LIMIT = -1;

// ---------------------------------------------------------------------------
// Lookaside allocator sizes (from sqliteInt.h LOOKASIDE_SLOT_* area)
// ---------------------------------------------------------------------------

const
  SQLITE_DEFAULT_LOOKASIDE = 1200;  { slot size in bytes }
  SQLITE_DEFAULT_LOOKASIDE_COUNT = 40;

// ---------------------------------------------------------------------------
// Opcode names will be placed in passqlite3vdbe.pas (Phase 5).
// OP_* constants are generated from vdbe.c by tool/mkopcodeh.tcl into
// opcodes.h; they will be ported into src/generated/opcodes.pas in Phase 5
// following policy (A): freeze-and-port from the upstream build.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Minimum / maximum helper macros (as inline functions)
// ---------------------------------------------------------------------------

function sqlite3_min(a, b: i64): i64; inline;
function sqlite3_max(a, b: i64): i64; inline;

// ---------------------------------------------------------------------------
// AssertH — retains assert() semantics from the C source.
// In release builds ({$Q-} / {$R-} project-wide) this is a no-op-equivalent;
// in debug builds it logs file+line and halts on failure.
// ---------------------------------------------------------------------------

procedure AssertH(cond: Boolean; const msg: string);

implementation

function sqlite3_min(a, b: i64): i64; inline;
begin
  if a < b then Result := a else Result := b;
end;

function sqlite3_max(a, b: i64): i64; inline;
begin
  if a > b then Result := a else Result := b;
end;

procedure AssertH(cond: Boolean; const msg: string);
begin
  if not cond then
  begin
    WriteLn(ErrOutput, 'AssertH FAILED: ', msg);
    Halt(1);
  end;
end;

end.
