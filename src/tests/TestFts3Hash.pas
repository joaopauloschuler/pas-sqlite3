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
  (see commit history).
}
{$I ../passqlite3.inc}
program TestFts3Hash;

{
  Phase 6.40.1.b gate — fts3_hash.c port (passqlite3fts3).

  Self-contained data-structure test (no FTS vtab, no oracle needed).
  Exercises a FTS3_HASH_STRING table with copyKey=1:

    * sqlite3Fts3HashInit zeroes the header.
    * Insert ~20 distinct keys; each insert of a fresh key returns nil.
    * Find recovers every value (and the macro-style accessors agree).
    * Overwrite an existing key returns the OLD data, count unchanged.
    * Delete via insert-NULL returns the old data and drops the count;
      a subsequent Find returns nil.
    * Crossing 8 entries forces the 0->8 then 8->16 rehash; all keys must
      survive the rebuild.
    * Find of an absent key returns nil.
    * Clear empties the table and frees memory (re-init + reuse works).
}

uses
  ctypes,
  SysUtils,
  passqlite3types,
  passqlite3os,
  passqlite3fts3;

var
  g_fail: Integer = 0;

procedure Check(cond: Boolean; const msg: string);
begin
  if not cond then begin
    WriteLn('FAIL: ', msg);
    Inc(g_fail);
  end;
end;

{ Stable key/value storage so the raw pointers handed to the hash stay
  valid for the life of the test (copyKey copies keys, but data is the
  caller's pointer). }
const
  N = 20;
var
  keys: array[0..N-1] of AnsiString;
  vals: array[0..N-1] of Integer;     { value blocks; we hand &vals[i] }

function K(i: Integer): Pointer;
begin
  Result := PChar(keys[i]);
end;

function KLen(i: Integer): cint;
begin
  { FTS3_HASH_STRING: nKey counts the bytes including the NUL terminator
    is optional; we pass strlen+1 to match how the tokenizer registry keys
    its names.  Any consistent length works for a self-contained test. }
  Result := cint(Length(keys[i]) + 1);
end;

procedure Run;
var
  h: TFts3Hash;
  i, cnt: Integer;
  pOld, pFound: Pointer;
  e: PFts3HashElem;
begin
  for i := 0 to N-1 do begin
    keys[i] := 'token_' + IntToStr(i);
    vals[i] := 1000 + i;
  end;

  { ---- init ---- }
  sqlite3Fts3HashInit(@h, FTS3_HASH_STRING, 1);
  Check(fts3HashCount(@h) = 0, 'count 0 after init');
  Check(h.first = nil, 'first nil after init');
  Check(h.ht = nil, 'ht nil after init');
  Check(h.htsize = 0, 'htsize 0 after init');

  { ---- insert 20 fresh keys; forces 0->8 (at insert #8) and 8->16 ---- }
  for i := 0 to N-1 do begin
    pOld := sqlite3Fts3HashInsert(@h, K(i), KLen(i), @vals[i]);
    Check(pOld = nil, 'fresh insert returns nil for key ' + keys[i]);
  end;
  Check(fts3HashCount(@h) = N, 'count = 20 after 20 inserts');
  Check(h.htsize >= 16, 'htsize grew to >= 16 (rehash fired) actual=' + IntToStr(h.htsize));
  Check((h.htsize and (h.htsize - 1)) = 0, 'htsize is a power of two');

  { ---- find them all ---- }
  for i := 0 to N-1 do begin
    pFound := sqlite3Fts3HashFind(@h, K(i), KLen(i));
    Check(pFound = Pointer(@vals[i]), 'find recovers value for key ' + keys[i]);
  end;

  { ---- macro-style accessors agree on the linked list ---- }
  cnt := 0;
  e := fts3HashFirst(@h);
  while e <> nil do begin
    Check(fts3HashData(e) <> nil, 'list element has data');
    Check(fts3HashKey(e) <> nil, 'list element has key');
    Check(fts3HashKeysize(e) > 0, 'list element has nKey>0');
    Inc(cnt);
    e := fts3HashNext(e);
  end;
  Check(cnt = N, 'linked list has 20 elements, got ' + IntToStr(cnt));

  { ---- overwrite an existing key: returns OLD data, count unchanged ---- }
  pOld := sqlite3Fts3HashInsert(@h, K(5), KLen(5), @vals[6]);
  Check(pOld = Pointer(@vals[5]), 'overwrite returns old data');
  Check(fts3HashCount(@h) = N, 'count unchanged after overwrite');
  pFound := sqlite3Fts3HashFind(@h, K(5), KLen(5));
  Check(pFound = Pointer(@vals[6]), 'overwrite installed new data');
  { restore }
  sqlite3Fts3HashInsert(@h, K(5), KLen(5), @vals[5]);

  { ---- delete via insert-NULL: returns old data, drops count ---- }
  pOld := sqlite3Fts3HashInsert(@h, K(7), KLen(7), nil);
  Check(pOld = Pointer(@vals[7]), 'delete returns old data');
  Check(fts3HashCount(@h) = N-1, 'count drops after delete');
  pFound := sqlite3Fts3HashFind(@h, K(7), KLen(7));
  Check(pFound = nil, 'deleted key no longer found');

  { ---- absent key ---- }
  pFound := sqlite3Fts3HashFind(@h, PChar('does_not_exist'), cint(Length('does_not_exist') + 1));
  Check(pFound = nil, 'absent key returns nil');

  { deleting an absent key returns nil and changes nothing }
  pOld := sqlite3Fts3HashInsert(@h, PChar('does_not_exist'), cint(Length('does_not_exist') + 1), nil);
  Check(pOld = nil, 'delete of absent key returns nil');
  Check(fts3HashCount(@h) = N-1, 'count unchanged by no-op delete');

  { ---- clear ---- }
  sqlite3Fts3HashClear(@h);
  Check(fts3HashCount(@h) = 0, 'count 0 after clear');
  Check(h.first = nil, 'first nil after clear');
  Check(h.ht = nil, 'ht nil after clear');
  Check(h.htsize = 0, 'htsize 0 after clear');

  { ---- reuse after clear ---- }
  pOld := sqlite3Fts3HashInsert(@h, K(0), KLen(0), @vals[0]);
  Check(pOld = nil, 'reuse insert returns nil');
  pFound := sqlite3Fts3HashFind(@h, K(0), KLen(0));
  Check(pFound = Pointer(@vals[0]), 'reuse find works');
  sqlite3Fts3HashClear(@h);

  { ---- binary mode: zero-byte-tolerant keys, no copy ---- }
  sqlite3Fts3HashInit(@h, FTS3_HASH_BINARY, 0);
  pOld := sqlite3Fts3HashInsert(@h, @vals[0], SizeOf(Integer), @vals[1]);
  Check(pOld = nil, 'binary fresh insert returns nil');
  pFound := sqlite3Fts3HashFind(@h, @vals[0], SizeOf(Integer));
  Check(pFound = Pointer(@vals[1]), 'binary find works');
  sqlite3Fts3HashClear(@h);
end;

begin
  Run;
  if g_fail = 0 then begin
    WriteLn('TestFts3Hash: PASS');
    Halt(0);
  end else begin
    WriteLn('TestFts3Hash: FAIL (', g_fail, ' assertions)');
    Halt(1);
  end;
end.
