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
program TestFts3DescUpdate;

{
  Phase 6.40.1.o.1 repro gate — the FTS3 order=desc doclist READ path.

  An UPDATE that changes the docid (rowid) of a row in an order=desc fts4
  table walks the descending doclist reader: fts3SegReaderFirstDocid /
  fts3SegReaderNextDocid (pending-hash arm) and the reverse poslist reader
  fts3ReversePoslist / fts3GetReverseVarint.

  Symptoms before the fix (bug 6.40.1.o.1):
    * Outside a transaction (data flushed to %_segments blob): the reverse
      varint/poslist scan decodes a bad length -> "database disk image is
      malformed".
    * Inside a transaction (data still in the in-memory pending hash, no
      terminator): the reverse scan runs off the end -> infinite loop = HANG.

  Root cause: fts3ReversePoslist's final byte-skip loop ported the C
  post-increment `while( *p++ & 0x80 );` as a Pascal pre-test loop that did
  NOT advance past the terminating byte -> the returned poslist start (and
  thus the computed *pnList length) was one byte short.

  This program drives the minimal repro through the live fts4 vtab in BOTH
  arms (no-txn and in-txn) and verifies the result + integrity_check.

  Exit 0 = PASS.
}

uses
  ctypes,
  SysUtils,
  passqlite3types,
  passqlite3util,
  passqlite3os,
  passqlite3vdbe,
  passqlite3main,
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

function ExecRc(db: PTsqlite3; const zSql: string): cint;
var
  zErr: PAnsiChar;
begin
  zErr := nil;
  Result := sqlite3_exec(db, PAnsiChar(zSql), nil, nil, @zErr);
  if (Result <> SQLITE_OK) and (zErr <> nil) then
    WriteLn('   exec err (rc=', Result, '): ', zErr);
  if zErr <> nil then sqlite3_free(zErr);
end;

procedure ExecOK(db: PTsqlite3; const zSql: string; const what: string);
begin
  Check(ExecRc(db, zSql) = SQLITE_OK, what);
end;

{ Return the comma-joined list of integer column-0 values in row order. }
function QueryRowids(db: PTsqlite3; const zSql: string): string;
var
  pStmt: Pointer;
  rc: cint;
begin
  Result := '';
  pStmt := nil;
  rc := sqlite3_prepare_v2(db, PAnsiChar(zSql), -1, @pStmt, nil);
  if rc <> SQLITE_OK then begin
    WriteLn('   prepare err: ', sqlite3_errmsg(db), '  sql=', zSql);
    Result := 'ERR'; Exit;
  end;
  while sqlite3_step(pStmt) = SQLITE_ROW do begin
    if Result <> '' then Result := Result + ',';
    Result := Result + IntToStr(sqlite3_column_int64(pStmt, 0));
  end;
  sqlite3_finalize(pStmt);
end;

function QueryText(db: PTsqlite3; const zSql: string): string;
var
  pStmt: Pointer;
  rc: cint;
  z: PAnsiChar;
begin
  Result := '';
  pStmt := nil;
  rc := sqlite3_prepare_v2(db, PAnsiChar(zSql), -1, @pStmt, nil);
  if rc <> SQLITE_OK then begin Result := 'ERR'; Exit; end;
  if sqlite3_step(pStmt) = SQLITE_ROW then begin
    z := sqlite3_column_text(pStmt, 0);
    if z <> nil then Result := StrPas(z);
  end;
  sqlite3_finalize(pStmt);
end;

{ Populate an order=desc fts4 table with two rows sharing a term so the
  doclist for that term holds two docid entries (the minimum the reverse
  reader iterates over). }
procedure Populate(db: PTsqlite3);
begin
  ExecOK(db, 'INSERT INTO t(docid, content) VALUES(1, ''one two three'')', 'ins 1');
  ExecOK(db, 'INSERT INTO t(docid, content) VALUES(2, ''two four five'')', 'ins 2');
  ExecOK(db, 'INSERT INTO t(docid, content) VALUES(3, ''two six seven'')', 'ins 3');
end;

procedure RunArm(const zPath: string; inTxn: Boolean);
var
  db: PTsqlite3;
  rc: cint;
  got, ic, label_: string;
begin
  if inTxn then label_ := 'in-txn' else label_ := 'no-txn';
  if (zPath <> ':memory:') and FileExists(zPath) then DeleteFile(zPath);

  db := nil;
  rc := sqlite3_open(PAnsiChar(zPath), @db);
  Check(rc = SQLITE_OK, label_ + ': open');

  ExecOK(db, 'CREATE VIRTUAL TABLE t USING fts4(content, order=desc)',
         label_ + ': create order=desc');
  Populate(db);

  { Read the descending doclist for "two" BEFORE the update. order=desc means
    rows come back highest docid first. }
  got := QueryRowids(db, 'SELECT docid FROM t WHERE t MATCH ''two''');
  Check(got = '3,2,1', label_ + ': pre-update MATCH two desc, got [' + got + ']');

  { The docid-changing UPDATE — this is the operation that triggers the
    reverse doclist read of the descending segment/pending doclist. }
  if inTxn then ExecOK(db, 'BEGIN', label_ + ': begin');
  ExecOK(db, 'UPDATE t SET docid = 5 WHERE docid = 2', label_ + ': update docid 2->5');

  { In the in-txn arm the doclist for "two" is still in the pending hash;
    in the no-txn arm (inTxn=False) the prior inserts were auto-committed and
    flushed to %_segments. Either way this MATCH walks the descending reader
    and must NOT hang or return CORRUPT. }
  got := QueryRowids(db, 'SELECT docid FROM t WHERE t MATCH ''two''');
  Check(got = '5,3,1', label_ + ': post-update MATCH two desc, got [' + got + ']');

  if inTxn then ExecOK(db, 'COMMIT', label_ + ': commit');

  ic := QueryText(db, 'PRAGMA integrity_check');
  Check(ic = 'ok', label_ + ': integrity_check = [' + ic + ']');

  { Re-read after commit to be sure the on-disk descending doclist reads
    cleanly too. }
  got := QueryRowids(db, 'SELECT docid FROM t WHERE t MATCH ''two''');
  Check(got = '5,3,1', label_ + ': final MATCH two desc, got [' + got + ']');

  sqlite3_close(db);
  if (zPath <> ':memory:') and FileExists(zPath) then DeleteFile(zPath);
end;

begin
  { no-txn arm: file DB so the pre-update inserts get flushed to %_segments
    (the CORRUPT arm of the bug). }
  RunArm('/tmp/test_fts3_desc_update.db', False);

  { in-txn arm: the inserts and the update all live in the pending hash
    (the HANG arm of the bug). A file DB is fine; the BEGIN keeps it pending. }
  RunArm('/tmp/test_fts3_desc_update_txn.db', True);

  if g_fail = 0 then begin
    WriteLn('TestFts3DescUpdate: PASS');
    Halt(0);
  end else begin
    WriteLn('TestFts3DescUpdate: FAIL (', g_fail, ' checks)');
    Halt(1);
  end;
end.
