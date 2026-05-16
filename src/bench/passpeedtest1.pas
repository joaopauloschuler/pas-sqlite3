{$I ../passqlite3.inc}
program passpeedtest1;
{
  Phase 11.1 — speedtest1 harness skeleton (1:1 port of
  ../sqlite3/test/speedtest1.c lines 1..780 (state + helpers) and
  2964..end (main).

  The per-testset bodies (testset_main, _cte, _fp, _parsenumber, _star,
  _orm, _trigger, _debug1, _json, _rtree) are NOT ported here; each
  stub prints "not yet ported (Phase 11.x)" and exits non-zero so the
  next agent (11.2..11.5) can extend coverage one testset at a time.

  Output gate: bench/baseline/harness.txt captures
    ./bin/passpeedtest1 --testset main --size 1
  after wall-clock stripping; see bench/check_harness.sh.  When 11.2
  lands testset_main, that gate's expected output MUST be re-baselined
  to include the per-test lines.

  C citations (in this file's order of appearance):

    zHelp[]                 speedtest1.c:28..79
    HashContext / g         speedtest1.c:105..148
    isTemp                  speedtest1.c:152
    fatal_error             speedtest1.c:157
    HashInit/Update/Final   speedtest1.c:182..231
    hexDigitValue           speedtest1.c:241
    integerValue            speedtest1.c:257..299
    speedtest1_timestamp    speedtest1.c:302..321
    speedtest1_random       speedtest1.c:324..328
    swizzle                 speedtest1.c:333..341
    roundup_allones         speedtest1.c:345..349
    speedtest1_numbername   speedtest1.c:359..410
    begin_test/end_test     speedtest1.c:413..469
    speedtest1_final        speedtest1.c:472..492
    printSql                speedtest1.c:495..510
    shrink_memory           speedtest1.c:515..519
    speedtest1_exec         speedtest1.c:522..542
    speedtest1_once         speedtest1.c:548..583
    speedtest1_prepare      speedtest1.c:586..603
    speedtest1_run          speedtest1.c:606..682
    traceCallback           speedtest1.c:686..690
    randomFunc              speedtest1.c:695..701
    est_square_root         speedtest1.c:704..714
    main()                  speedtest1.c:2964..3477

  Skipped (gated):
    groupConcat shim        speedtest1.c:717..776   (SQLITE_VERSION_NUMBER<3005004 — modern engine has it)
    WASM helpers            speedtest1.c:3479..end
}

uses
  SysUtils,
  cTypes,
  passqlite3types,
  passqlite3util,
  passqlite3os,
  passqlite3pcache,
  passqlite3pager,
  passqlite3wal,
  passqlite3btree,
  passqlite3vdbe,
  passqlite3codegen,
  passqlite3parser,
  passqlite3vtab,
  passqlite3main,
  passqlite3printf;

{ ----------------------------- zHelp ------------------------------------ }

const
  zHelp: AnsiString =
    'Usage: %s [--options] DATABASE'#10 +
    'Options:'#10 +
    '  --autovacuum        Enable AUTOVACUUM mode'#10 +
    '  --big-transactions  Add BEGIN/END around all large tests'#10 +
    '  --cachesize N       Set PRAGMA cache_size=N. Note: N is pages, not bytes'#10 +
    '  --checkpoint        Run PRAGMA wal_checkpoint after each test case'#10 +
    '  --exclusive         Enable locking_mode=EXCLUSIVE'#10 +
    '  --explain           Like --sqlonly but with added EXPLAIN keywords'#10 +
    '  --fullfsync         Enable fullfsync=TRUE'#10 +
    '  --hard-heap-limit N The hard limit on the maximum heap size'#10 +
    '  --heap SZ MIN       Memory allocator uses SZ bytes & min allocation MIN'#10 +
    '  --incrvacuum        Enable incremenatal vacuum mode'#10 +
    '  --journal M         Set the journal_mode to M'#10 +
    '  --key KEY           Set the encryption key to KEY'#10 +
    '  --lookaside N SZ    Configure lookaside for N slots of SZ bytes each'#10 +
    '  --memdb             Use an in-memory database'#10 +
    '  --mmap SZ           MMAP the first SZ bytes of the database file'#10 +
    '  --multithread       Set multithreaded mode'#10 +
    '  --nomemstat         Disable memory statistics'#10 +
    '  --nomutex           Open db with SQLITE_OPEN_NOMUTEX'#10 +
    '  --nosync            Set PRAGMA synchronous=OFF'#10 +
    '  --notnull           Add NOT NULL constraints to table columns'#10 +
    '  --output FILE       Store SQL output in FILE'#10 +
    '  --pagesize N        Set the page size to N'#10 +
    '  --pcache N SZ       Configure N pages of pagecache each of size SZ bytes'#10 +
    '  --primarykey        Use PRIMARY KEY instead of UNIQUE where appropriate'#10 +
    '  --repeat N          Repeat each SELECT N times (default: 1)'#10 +
    '  --reprepare         Reprepare each statement upon every invocation'#10 +
    '  --reserve N         Reserve N bytes on each database page'#10 +
    '  --script FILE       Write an SQL script for the test into FILE'#10 +
    '  --serialized        Set serialized threading mode'#10 +
    '  --singlethread      Set single-threaded mode - disables all mutexing'#10 +
    '  --sqlonly           No-op.  Only show the SQL that would have been run.'#10 +
    '  --shrink-memory     Invoke sqlite3_db_release_memory() frequently.'#10 +
    '  --size N            Relative test size.  Default=100'#10 +
    '  --soft-heap-limit N The soft limit on the maximum heap size'#10 +
    '  --strict            Use STRICT table where appropriate'#10 +
    '  --stats             Show statistics at the end'#10 +
    '  --stmtscanstatus    Activate SQLITE_DBCONFIG_STMT_SCANSTATUS'#10 +
    '  --temp N            N from 0 to 9.  0: no temp table. 9: all temp tables'#10 +
    '  --testset T         Run test-set T (main, cte, rtree, orm, fp, json,'#10 +
    '                      star, app, debug).  Can be a comma-separated list'#10 +
    '                      of values, with /SCALE suffixes or macro "mix1"'#10 +
    '  --trace             Turn on SQL tracing'#10 +
    '  --threads N         Use up to N threads for sorting'#10 +
    '  --utf16be           Set text encoding to UTF-16BE'#10 +
    '  --utf16le           Set text encoding to UTF-16LE'#10 +
    '  --verify            Run additional verification steps'#10 +
    '  --vfs NAME          Use the given (preinstalled) VFS'#10 +
    '  --without-rowid     Use WITHOUT ROWID where appropriate'#10;

{ ----------------------------- HashContext ------------------------------ }

type
  THashContext = record
    isInit: Byte;
    i, j:   Byte;
    s:      array[0..255] of Byte;
    r:      array[0..31]  of Byte;
  end;

{ ----------------------------- Global g --------------------------------- }

type
  TGlobal = record
    db:              PTsqlite3;
    zDbName:         AnsiString;
    zVfs:            AnsiString;
    pStmt:           PVdbe;
    iStart:          i64;
    iTotal:          i64;
    bWithoutRowid:   Integer;
    bReprepare:      Integer;
    bSqlOnly:        Integer;
    bExplain:        Integer;
    bVerify:         Integer;
    bMemShrink:      Integer;
    eTemp:           Integer;
    szTest:          Integer;
    szBase:          Integer;
    nRepeat:         Integer;
    doCheckpoint:    Integer;
    nReserve:        Integer;
    stmtScanStatus:  Integer;
    doBigTransactions: Integer;
    zWR:             AnsiString;     { Might be WITHOUT ROWID }
    zNN:             AnsiString;     { Might be NOT NULL }
    zPK:             AnsiString;     { UNIQUE or PRIMARY KEY }
    x, y:            LongWord;       { LCG PRNG state }
    nResByte:        QWord;
    nResult:         Integer;
    zResult:         array[0..2999] of AnsiChar;
    pScript:         TextFile;
    pScriptOpen:     Boolean;
    hashFile:        TextFile;
    hashFileOpen:    Boolean;
    hashFileIsStdout: Boolean;
    hash:            THashContext;
  end;

var
  g: TGlobal;
  iTestNumber: Integer = 0;

const
  NAMEWIDTH = 60;
  zDots: AnsiString =
    '.......................................................................';

{ ----------------------------- isTemp ----------------------------------- }

function isTemp(N: Integer): PAnsiChar;
begin
  if g.eTemp >= N then
    Result := ' TEMP'
  else
    Result := '';
end;

{ ----------------------------- fatal_error ------------------------------ }

procedure fatal_error(const zMsg: AnsiString);
begin
  Write(StdErr, zMsg);
  Flush(StdErr);
  Halt(1);
end;

procedure fatal_error(const fmt: AnsiString; const args: array of const);
begin
  Write(StdErr, sqlite3FormatStr(PAnsiChar(fmt), args));
  Flush(StdErr);
  Halt(1);
end;

{ ----------------------------- Hash ------------------------------------- }
{ speedtest1.c:182..231 — RC4-based MD5-substitute used only when --verify
  is set.  Bit-for-bit identical to the C implementation. }

procedure HashInit;
var k: Integer;
begin
  g.hash.i := 0;
  g.hash.j := 0;
  for k := 0 to 255 do g.hash.s[k] := Byte(k);
end;

procedure HashUpdate(const aData: PByte; nData: LongWord);
var
  i, j, t: Byte;
  k: LongWord;
  c: Byte;
begin
  i := g.hash.i;
  j := g.hash.j;
  if g.hashFileOpen then begin
    for k := 0 to nData - 1 do begin
      c := (aData + k)^;
      Write(g.hashFile, AnsiChar(c));
    end;
  end;
  for k := 0 to nData - 1 do begin
    j := Byte(j + g.hash.s[i] + (aData + k)^);
    t := g.hash.s[j];
    g.hash.s[j] := g.hash.s[i];
    g.hash.s[i] := t;
    Inc(i);
  end;
  g.hash.i := i;
  g.hash.j := j;
end;

procedure HashFinal;
var
  k: LongWord;
  t, i, j: Byte;
begin
  i := g.hash.i;
  j := g.hash.j;
  for k := 0 to 31 do begin
    Inc(i);
    t := g.hash.s[i];
    j := Byte(j + t);
    g.hash.s[i] := g.hash.s[j];
    g.hash.s[j] := t;
    t := Byte(t + g.hash.s[i]);
    g.hash.r[k] := g.hash.s[t];
  end;
end;

{ ----------------------------- hexDigitValue ---------------------------- }

function hexDigitValue(c: AnsiChar): Integer;
begin
  if (c >= '0') and (c <= '9') then Result := Ord(c) - Ord('0')
  else if (c >= 'a') and (c <= 'f') then Result := Ord(c) - Ord('a') + 10
  else if (c >= 'A') and (c <= 'F') then Result := Ord(c) - Ord('A') + 10
  else Result := -1;
end;

{ ----------------------------- integerValue ----------------------------- }

function integerValue(zArg: PAnsiChar): Integer;
type
  TMult = record zSuffix: PAnsiChar; iMult: i64; end;
const
  aMult: array[0..8] of TMult = (
    (zSuffix: 'KiB'; iMult: 1024),
    (zSuffix: 'MiB'; iMult: 1024*1024),
    (zSuffix: 'GiB'; iMult: 1024*1024*1024),
    (zSuffix: 'KB';  iMult: 1000),
    (zSuffix: 'MB';  iMult: 1000000),
    (zSuffix: 'GB';  iMult: 1000000000),
    (zSuffix: 'K';   iMult: 1000),
    (zSuffix: 'M';   iMult: 1000000),
    (zSuffix: 'G';   iMult: 1000000000)
  );
var
  v: i64;
  i, x: Integer;
  isNeg: Boolean;
begin
  v := 0;
  isNeg := False;
  if zArg[0] = '-' then begin isNeg := True; Inc(zArg); end
  else if zArg[0] = '+' then Inc(zArg);
  if (zArg[0] = '0') and (zArg[1] = 'x') then begin
    Inc(zArg, 2);
    x := hexDigitValue(zArg[0]);
    while x >= 0 do begin
      v := (v shl 4) + x;
      Inc(zArg);
      x := hexDigitValue(zArg[0]);
    end;
  end else begin
    while (zArg[0] >= '0') and (zArg[0] <= '9') do begin
      v := v*10 + (Ord(zArg[0]) - Ord('0'));
      Inc(zArg);
    end;
  end;
  for i := 0 to High(aMult) do
    if sqlite3_stricmp(aMult[i].zSuffix, zArg) = 0 then begin
      v := v * aMult[i].iMult;
      Break;
    end;
  if v > $7fffffff then fatal_error('parameter too large - max 2147483648');
  if isNeg then Result := Integer(-v) else Result := Integer(v);
end;

{ ----------------------------- speedtest1_timestamp --------------------- }

function speedtest1_timestamp: i64;
var
  clockVfs: Psqlite3_vfs;
  t: i64;
  r: Double;
begin
  clockVfs := sqlite3_vfs_find(nil);
  if (clockVfs <> nil) and (clockVfs^.iVersion >= 2) and
     Assigned(clockVfs^.xCurrentTimeInt64) then begin
    clockVfs^.xCurrentTimeInt64(clockVfs, @t);
  end else begin
    clockVfs^.xCurrentTime(clockVfs, @r);
    t := i64(Trunc(r * 86400000.0));
  end;
  Result := t;
end;

{ ----------------------------- speedtest1_random ------------------------ }

function speedtest1_random: LongWord;
var b: LongWord;
begin
  { (g.x>>1) ^ ((1+~(g.x&1)) & 0xd0000001) }
  b := LongWord(1 + (not (g.x and 1))) and $d0000001;
  g.x := (g.x shr 1) xor b;
  g.y := g.y * 1103515245 + 12345;
  Result := g.x xor g.y;
end;

{ ----------------------------- swizzle / roundup_allones --------------- }

function swizzle(in_: LongWord; limit: LongWord): LongWord;
var out_: LongWord;
begin
  out_ := 0;
  while limit <> 0 do begin
    out_ := (out_ shl 1) or (in_ and 1);
    in_ := in_ shr 1;
    limit := limit shr 1;
  end;
  Result := out_;
end;

function roundup_allones(limit: LongWord): LongWord;
var m: LongWord;
begin
  m := 1;
  while m < limit do m := (m shl 1) + 1;
  Result := m;
end;

{ ----------------------------- speedtest1_numbername -------------------- }
{ speedtest1.c:359..410.  Output buffer is a Pascal AnsiString. }

const
  ones: array[0..19] of AnsiString = (
    'zero','one','two','three','four','five','six','seven','eight','nine',
    'ten','eleven','twelve','thirteen','fourteen','fifteen','sixteen',
    'seventeen','eighteen','nineteen');
  tens: array[0..9] of AnsiString = (
    '','ten','twenty','thirty','forty','fifty','sixty','seventy','eighty',
    'ninety');

function speedtest1_numbername(n: LongWord): AnsiString;
begin
  Result := '';
  if n >= 1000000000 then begin
    Result := speedtest1_numbername(n div 1000000000) + ' billion';
    n := n mod 1000000000;
  end;
  if n >= 1000000 then begin
    if Result <> '' then Result := Result + ' ';
    Result := Result + speedtest1_numbername(n div 1000000) + ' million';
    n := n mod 1000000;
  end;
  if n >= 1000 then begin
    if Result <> '' then Result := Result + ' ';
    Result := Result + speedtest1_numbername(n div 1000) + ' thousand';
    n := n mod 1000;
  end;
  if n >= 100 then begin
    if Result <> '' then Result := Result + ' ';
    Result := Result + ones[n div 100] + ' hundred';
    n := n mod 100;
  end;
  if n >= 20 then begin
    if Result <> '' then Result := Result + ' ';
    Result := Result + tens[n div 10];
    n := n mod 10;
  end;
  if n > 0 then begin
    if Result <> '' then Result := Result + ' ';
    Result := Result + ones[n];
  end;
  if Result = '' then Result := 'zero';
end;

{ Forward refs }
procedure speedtest1_exec(const zFormat: AnsiString); forward;
procedure speedtest1_exec(const zFormat: AnsiString; const args: array of const); forward;

{ ----------------------------- begin_test ------------------------------- }

procedure speedtest1_begin_test(iTestNum: Integer; const zTestName: AnsiString);
var
  n: Integer;
  zName: AnsiString;
begin
  iTestNumber := iTestNum;
  zName := zTestName;
  n := Length(zName);
  if n > NAMEWIDTH then begin
    SetLength(zName, NAMEWIDTH);
    n := NAMEWIDTH;
  end;
  if g.pScriptOpen then begin
    WriteLn(g.pScript, '-- begin test ', iTestNumber, ' ', zName);
  end;
  if g.bSqlOnly <> 0 then begin
    Write(Format('/* %4d - %s%s */'#10,
      [iTestNum, zName, Copy(zDots, 1, NAMEWIDTH - n)]));
  end else begin
    Write(Format('%4d - %s%s ',
      [iTestNum, zName, Copy(zDots, 1, NAMEWIDTH - n)]));
    Flush(Output);
  end;
  g.nResult := 0;
  g.iStart := speedtest1_timestamp;
  g.x := $ad131d0b;
  g.y := $44f9eac8;
end;

procedure speedtest1_begin_test(iTestNum: Integer; const fmt: AnsiString;
  const args: array of const);
begin
  speedtest1_begin_test(iTestNum, sqlite3FormatStr(PAnsiChar(fmt), args));
end;

{ ----------------------------- end_test --------------------------------- }

procedure speedtest1_end_test;
var iElapseTime: i64;
begin
  iElapseTime := speedtest1_timestamp - g.iStart;
  if g.doCheckpoint <> 0 then speedtest1_exec('PRAGMA wal_checkpoint;');
  Assert(iTestNumber > 0);
  if g.pScriptOpen then
    WriteLn(g.pScript, '-- end test ', iTestNumber);
  if g.bSqlOnly = 0 then begin
    Inc(g.iTotal, iElapseTime);
    WriteLn(Format('%4d.%.3ds', [Integer(iElapseTime div 1000),
                                  Integer(iElapseTime mod 1000)]));
  end;
  if g.pStmt <> nil then begin
    sqlite3_finalize(g.pStmt);
    g.pStmt := nil;
  end;
  iTestNumber := 0;
end;

{ ----------------------------- final ------------------------------------ }

procedure speedtest1_final;
var i: Integer; nlByte: Byte;
begin
  if g.bSqlOnly = 0 then begin
    WriteLn(Format('       TOTAL%s %4d.%.3ds',
      [Copy(zDots, 1, NAMEWIDTH - 5),
       Integer(g.iTotal div 1000), Integer(g.iTotal mod 1000)]));
  end;
  if g.bVerify <> 0 then begin
    Write(Format('Verification Hash: %d ', [g.nResByte]));
    nlByte := 10;
    HashUpdate(@nlByte, 1);
    HashFinal;
    for i := 0 to 23 do
      Write(LowerCase(IntToHex(g.hash.r[i], 2)));
    if g.hashFileOpen and (not g.hashFileIsStdout) then
      CloseFile(g.hashFile);
    WriteLn;
  end;
end;

{ ----------------------------- printSql --------------------------------- }

procedure printSql(const zSql: AnsiString);
var
  n: Integer;
  s: AnsiString;
begin
  s := zSql;
  n := Length(s);
  while (n > 0) and ((s[n] = ';') or (s[n] in [' ', #9, #10, #13])) do Dec(n);
  if g.bExplain <> 0 then Write('EXPLAIN ');
  WriteLn(Copy(s, 1, n), ';');
  { sqlite3_strglob shortcut: print the same statement twice for CREATE/DROP/ALTER
    so EXPLAIN-of-DDL has a runnable companion (speedtest1.c:500..509). }
  if (g.bExplain <> 0) and ((Pos('CREATE ', UpperCase(s)) = 1)
                         or (Pos('DROP ',   UpperCase(s)) = 1)
                         or (Pos('ALTER ',  UpperCase(s)) = 1)) then
    WriteLn(Copy(s, 1, n), ';');
end;

{ ----------------------------- shrink_memory ---------------------------- }

procedure speedtest1_shrink_memory;
begin
  if g.bMemShrink <> 0 then sqlite3_db_release_memory(g.db);
end;

{ ----------------------------- exec ------------------------------------- }

procedure speedtest1_exec(const zFormat: AnsiString);
var
  rc: i32;
  pErr: PAnsiChar;
begin
  if g.bSqlOnly <> 0 then begin
    printSql(zFormat);
  end else begin
    pErr := nil;
    if g.pScriptOpen then WriteLn(g.pScript, zFormat, ';');
    rc := sqlite3_exec(g.db, PAnsiChar(zFormat), nil, nil, @pErr);
    if pErr <> nil then begin
      fatal_error('SQL error: %s'#10'%s'#10, [pErr, PAnsiChar(zFormat)]);
    end;
    if rc <> SQLITE_OK then
      fatal_error('exec error: %s'#10, [sqlite3_errmsg(g.db)]);
  end;
  speedtest1_shrink_memory;
end;

procedure speedtest1_exec(const zFormat: AnsiString; const args: array of const);
begin
  speedtest1_exec(sqlite3FormatStr(PAnsiChar(zFormat), args));
end;

{ ----------------------------- once ------------------------------------- }

function speedtest1_once(const zFormat: AnsiString): AnsiString;
var
  pStmt: PVdbe;
  rc: i32;
  z: PAnsiChar;
begin
  Result := '';
  if g.bSqlOnly <> 0 then begin
    printSql(zFormat);
  end else begin
    rc := sqlite3_prepare_v2(g.db, PAnsiChar(zFormat), -1, @pStmt, nil);
    if rc <> SQLITE_OK then
      fatal_error('SQL error: %s'#10, [sqlite3_errmsg(g.db)]);
    if g.pScriptOpen then begin
      z := sqlite3_expanded_sql(pStmt);
      if z <> nil then WriteLn(g.pScript, z);
      sqlite3_free(z);
    end;
    if sqlite3_step(pStmt) = SQLITE_ROW then begin
      z := sqlite3_column_text(pStmt, 0);
      if z <> nil then Result := z;
    end;
    rc := sqlite3_reset(pStmt);
    if rc <> SQLITE_OK then
      fatal_error('%s'#10'Error code %d: %s'#10,
        [sqlite3_sql(pStmt), rc, sqlite3_errmsg(g.db)]);
    sqlite3_finalize(pStmt);
  end;
  speedtest1_shrink_memory;
end;

function speedtest1_once(const zFormat: AnsiString; const args: array of const): AnsiString;
begin
  Result := speedtest1_once(sqlite3FormatStr(PAnsiChar(zFormat), args));
end;

{ ----------------------------- prepare ---------------------------------- }

procedure speedtest1_prepare(const zFormat: AnsiString);
var
  rc: i32;
begin
  if g.bSqlOnly <> 0 then begin
    printSql(zFormat);
  end else begin
    if g.pStmt <> nil then sqlite3_finalize(g.pStmt);
    rc := sqlite3_prepare_v2(g.db, PAnsiChar(zFormat), -1, @g.pStmt, nil);
    if rc <> SQLITE_OK then
      fatal_error('SQL error: %s'#10, [sqlite3_errmsg(g.db)]);
  end;
end;

procedure speedtest1_prepare(const zFormat: AnsiString; const args: array of const);
begin
  speedtest1_prepare(sqlite3FormatStr(PAnsiChar(zFormat), args));
end;

{ ----------------------------- run -------------------------------------- }

procedure speedtest1_run;
var
  i, n, len, rc: Integer;
  eType: Integer;
  z: PAnsiChar;
  zExp: PAnsiChar;
  pNew: PVdbe;
  zPrefix: array[0..1] of Byte;
  nBlob, iBlob: Integer;
  aBlob: PByte;
  zChar: array[0..1] of Byte;
  hexLut: AnsiString;
begin
  if g.bSqlOnly <> 0 then Exit;
  Assert(g.pStmt <> nil);
  g.nResult := 0;
  hexLut := '0123456789abcdef';
  if g.pScriptOpen then begin
    zExp := sqlite3_expanded_sql(g.pStmt);
    if zExp <> nil then WriteLn(g.pScript, zExp);
    sqlite3_free(zExp);
  end;
  while sqlite3_step(g.pStmt) = SQLITE_ROW do begin
    n := sqlite3_column_count(g.pStmt);
    for i := 0 to n - 1 do begin
      z := sqlite3_column_text(g.pStmt, i);
      if z = nil then z := 'nil';
      len := StrLen(z);
      if g.bVerify <> 0 then begin
        eType := sqlite3_column_type(g.pStmt, i);
        zPrefix[0] := Ord(#10);
        case eType of
          0: zPrefix[1] := Ord('-');
          SQLITE_INTEGER: zPrefix[1] := Ord('I');
          SQLITE_FLOAT:   zPrefix[1] := Ord('F');
          SQLITE_TEXT:    zPrefix[1] := Ord('T');
          SQLITE_BLOB:    zPrefix[1] := Ord('B');
          SQLITE_NULL:    zPrefix[1] := Ord('N');
        else
          zPrefix[1] := Ord('?');
        end;
        if g.nResByte <> 0 then
          HashUpdate(@zPrefix[0], 2)
        else
          HashUpdate(@zPrefix[1], 1);
        if eType = SQLITE_FLOAT then begin
          Inc(g.nResByte, 2);
        end else if eType = SQLITE_BLOB then begin
          nBlob := sqlite3_column_bytes(g.pStmt, i);
          aBlob := sqlite3_column_blob(g.pStmt, i);
          for iBlob := 0 to nBlob - 1 do begin
            zChar[0] := Ord(hexLut[1 + ((aBlob + iBlob)^ shr 4)]);
            zChar[1] := Ord(hexLut[1 + ((aBlob + iBlob)^ and 15)]);
            HashUpdate(@zChar[0], 2);
          end;
          Inc(g.nResByte, nBlob*2 + 2);
        end else begin
          HashUpdate(PByte(z), len);
          Inc(g.nResByte, len + 2);
        end;
      end;
      if g.nResult + len < SizeOf(g.zResult) - 2 then begin
        if g.nResult > 0 then begin
          g.zResult[g.nResult] := ' ';
          Inc(g.nResult);
        end;
        Move(z^, g.zResult[g.nResult], len + 1);
        Inc(g.nResult, len);
      end;
    end;
  end;
  if g.bReprepare <> 0 then begin
    pNew := nil;
    sqlite3_prepare_v2(g.db, sqlite3_sql(g.pStmt), -1, @pNew, nil);
    rc := sqlite3_finalize(g.pStmt);
    if rc <> SQLITE_OK then
      fatal_error('%s'#10'Error code %d: %s'#10,
        [sqlite3_sql(pNew), rc, sqlite3_errmsg(g.db)]);
    g.pStmt := pNew;
  end else begin
    rc := sqlite3_reset(g.pStmt);
    if rc <> SQLITE_OK then
      fatal_error('%s'#10'Error code %d: %s'#10,
        [sqlite3_sql(g.pStmt), rc, sqlite3_errmsg(g.db)]);
  end;
  speedtest1_shrink_memory;
end;

{ ----------------------------- traceCallback ---------------------------- }

procedure traceCallback(NotUsed: Pointer; zSql: PAnsiChar); cdecl;
var n: Integer;
begin
  n := StrLen(zSql);
  while (n > 0) and ((zSql[n-1] = ';') or
        (zSql[n-1] in [' ', #9, #10, #13])) do Dec(n);
  Write(StdErr, Copy(AnsiString(zSql), 1, n), ';'#10);
end;

{ ----------------------------- randomFunc ------------------------------- }

procedure randomFunc(context: Psqlite3_context; NotUsed: i32; NotUsed2: Pointer); cdecl;
begin
  sqlite3_result_int64(context, i64(speedtest1_random));
end;

{ ----------------------------- est_square_root -------------------------- }

function est_square_root(x: Integer): Integer;
var y0, y1, n: Integer;
begin
  y0 := x div 2;
  for n := 0 to 9 do begin
    if y0 <= 0 then Break;
    y1 := (y0 + x div y0) div 2;
    if y1 = y0 then Break;
    y0 := y1;
  end;
  Result := y0;
end;

{ ====================== Test-set stubs (Phase 11.2..) ==================== }
{ Each emits a clear "not yet ported" diagnostic and aborts.  Later agents
  replace these bodies with 1:1 ports of testset_main / _cte / _fp etc.
  from speedtest1.c. }

procedure testset_not_yet(const zName: AnsiString; const zPhase: AnsiString);
begin
  Write(StdErr,
    'speedtest1: testset "', zName, '" not yet ported (', zPhase, ')'#10);
  Flush(StdErr);
  Halt(2);
end;

{ ----------------------------- testset_main ----------------------------- }
{ 1:1 port of ../sqlite3/test/speedtest1.c lines 781..1244. }

procedure testset_main;
var
  i, n, sz, maxb: Integer;
  x1, x2: LongWord;
  len: Integer;
  zNum: AnsiString;
begin
  len := 0;
  x1 := 0; x2 := 0;

  sz := g.szTest * 500;
  n  := sz;
  maxb := Integer(roundup_allones(LongWord(sz)));

  { ---- 100 ---- }
  speedtest1_begin_test(100, '%d INSERTs into table with no index', [n]);
  speedtest1_exec('BEGIN');
  speedtest1_exec('CREATE%s TABLE z1(a INTEGER %s, b INTEGER %s, c TEXT %s);',
                  [isTemp(9), PAnsiChar(g.zNN), PAnsiChar(g.zNN), PAnsiChar(g.zNN)]);
  speedtest1_prepare('INSERT INTO z1 VALUES(?1,?2,?3); --  %d times', [n]);
  for i := 1 to n do begin
    x1 := swizzle(LongWord(i), LongWord(maxb));
    zNum := speedtest1_numbername(x1);
    sqlite3_bind_int64(g.pStmt, 1, i64(x1));
    sqlite3_bind_int(g.pStmt, 2, i);
    sqlite3_bind_text(g.pStmt, 3, PAnsiChar(zNum), -1, SQLITE_STATIC);
    speedtest1_run;
  end;
  speedtest1_exec('COMMIT');
  speedtest1_end_test;

  { ---- 110 ---- }
  n := sz;
  speedtest1_begin_test(110, '%d ordered INSERTS with one index/PK', [n]);
  speedtest1_exec('BEGIN');
  speedtest1_exec(
    'CREATE%s TABLE z2(a INTEGER %s %s, b INTEGER %s, c TEXT %s) %s',
    [isTemp(5), PAnsiChar(g.zNN), PAnsiChar(g.zPK),
     PAnsiChar(g.zNN), PAnsiChar(g.zNN), PAnsiChar(g.zWR)]);
  speedtest1_prepare('INSERT INTO z2 VALUES(?1,?2,?3); -- %d times', [n]);
  for i := 1 to n do begin
    x1 := swizzle(LongWord(i), LongWord(maxb));
    zNum := speedtest1_numbername(x1);
    sqlite3_bind_int(g.pStmt, 1, i);
    sqlite3_bind_int64(g.pStmt, 2, i64(x1));
    sqlite3_bind_text(g.pStmt, 3, PAnsiChar(zNum), -1, SQLITE_STATIC);
    speedtest1_run;
  end;
  speedtest1_exec('COMMIT');
  speedtest1_end_test;

  { ---- 120 ---- }
  n := sz;
  speedtest1_begin_test(120, '%d unordered INSERTS with one index/PK', [n]);
  speedtest1_exec('BEGIN');
  speedtest1_exec(
    'CREATE%s TABLE t3(a INTEGER %s %s, b INTEGER %s, c TEXT %s) %s',
    [isTemp(3), PAnsiChar(g.zNN), PAnsiChar(g.zPK),
     PAnsiChar(g.zNN), PAnsiChar(g.zNN), PAnsiChar(g.zWR)]);
  speedtest1_prepare('INSERT INTO t3 VALUES(?1,?2,?3); -- %d times', [n]);
  for i := 1 to n do begin
    x1 := swizzle(LongWord(i), LongWord(maxb));
    zNum := speedtest1_numbername(x1);
    sqlite3_bind_int(g.pStmt, 2, i);
    sqlite3_bind_int64(g.pStmt, 1, i64(x1));
    sqlite3_bind_text(g.pStmt, 3, PAnsiChar(zNum), -1, SQLITE_STATIC);
    speedtest1_run;
  end;
  speedtest1_exec('COMMIT');
  speedtest1_end_test;

  { Note: speedtest1.c:847..850 group_concat shim for SQLITE_VERSION_NUMBER<3005004
    is omitted; modern engine has group_concat builtin. }

  { ---- 130 ---- }
  n := 25;
  speedtest1_begin_test(130, '%d SELECTS, numeric BETWEEN, unindexed', [n]);
  speedtest1_exec('BEGIN');
  speedtest1_prepare(
    'SELECT count(*), avg(b), sum(length(c)), group_concat(c) FROM z1'#10 +
    ' WHERE b BETWEEN ?1 AND ?2; -- %d times', [n]);
  for i := 1 to n do begin
    if ((i - 1) mod g.nRepeat) = 0 then begin
      x1 := speedtest1_random mod LongWord(maxb);
      x2 := (speedtest1_random mod 10) + LongWord(sz div 5000) + x1;
    end;
    sqlite3_bind_int(g.pStmt, 1, Integer(x1));
    sqlite3_bind_int(g.pStmt, 2, Integer(x2));
    speedtest1_run;
  end;
  speedtest1_exec('COMMIT');
  speedtest1_end_test;

  { ---- 140 ---- }
  n := 10;
  speedtest1_begin_test(140, '%d SELECTS, LIKE, unindexed', [n]);
  speedtest1_exec('BEGIN');
  speedtest1_prepare(
    'SELECT count(*), avg(b), sum(length(c)), group_concat(c) FROM z1'#10 +
    ' WHERE c LIKE ?1; -- %d times', [n]);
  for i := 1 to n do begin
    if ((i - 1) mod g.nRepeat) = 0 then begin
      x1 := speedtest1_random mod LongWord(maxb);
      zNum := '%' + speedtest1_numbername(LongWord(i)) + '%';
      len := Length(zNum);
    end;
    sqlite3_bind_text(g.pStmt, 1, PAnsiChar(zNum), len, SQLITE_STATIC);
    speedtest1_run;
  end;
  speedtest1_exec('COMMIT');
  speedtest1_end_test;

  { ---- 142 ---- }
  n := 10;
  speedtest1_begin_test(142, '%d SELECTS w/ORDER BY, unindexed', [n]);
  speedtest1_exec('BEGIN');
  speedtest1_prepare(
    'SELECT a, b, c FROM z1 WHERE c LIKE ?1'#10 +
    ' ORDER BY a; -- %d times', [n]);
  for i := 1 to n do begin
    if ((i - 1) mod g.nRepeat) = 0 then begin
      x1 := speedtest1_random mod LongWord(maxb);
      zNum := '%' + speedtest1_numbername(LongWord(i)) + '%';
      len := Length(zNum);
    end;
    sqlite3_bind_text(g.pStmt, 1, PAnsiChar(zNum), len, SQLITE_STATIC);
    speedtest1_run;
  end;
  speedtest1_exec('COMMIT');
  speedtest1_end_test;

  { ---- 145 ---- }
  n := 10;
  speedtest1_begin_test(145, '%d SELECTS w/ORDER BY and LIMIT, unindexed', [n]);
  speedtest1_exec('BEGIN');
  speedtest1_prepare(
    'SELECT a, b, c FROM z1 WHERE c LIKE ?1'#10 +
    ' ORDER BY a LIMIT 10; -- %d times', [n]);
  for i := 1 to n do begin
    if ((i - 1) mod g.nRepeat) = 0 then begin
      x1 := speedtest1_random mod LongWord(maxb);
      zNum := '%' + speedtest1_numbername(LongWord(i)) + '%';
      len := Length(zNum);
    end;
    sqlite3_bind_text(g.pStmt, 1, PAnsiChar(zNum), len, SQLITE_STATIC);
    speedtest1_run;
  end;
  speedtest1_exec('COMMIT');
  speedtest1_end_test;

  { ---- 150 ---- }
  speedtest1_begin_test(150, 'CREATE INDEX five times');
  speedtest1_exec('BEGIN;');
  speedtest1_exec('CREATE UNIQUE INDEX t1b ON z1(b);');
  speedtest1_exec('CREATE INDEX t1c ON z1(c);');
  speedtest1_exec('CREATE UNIQUE INDEX t2b ON z2(b);');
  speedtest1_exec('CREATE INDEX t2c ON z2(c DESC);');
  speedtest1_exec('CREATE INDEX t3bc ON t3(b,c);');
  speedtest1_exec('COMMIT;');
  speedtest1_end_test;

  { ---- 160 ---- }
  n := sz div 5;
  speedtest1_begin_test(160, '%d SELECTS, numeric BETWEEN, indexed', [n]);
  speedtest1_exec('BEGIN');
  speedtest1_prepare(
    'SELECT count(*), avg(b), sum(length(c)), group_concat(a) FROM z1'#10 +
    ' WHERE b BETWEEN ?1 AND ?2; -- %d times', [n]);
  for i := 1 to n do begin
    if ((i - 1) mod g.nRepeat) = 0 then begin
      x1 := speedtest1_random mod LongWord(maxb);
      x2 := (speedtest1_random mod 10) + LongWord(sz div 5000) + x1;
    end;
    sqlite3_bind_int(g.pStmt, 1, Integer(x1));
    sqlite3_bind_int(g.pStmt, 2, Integer(x2));
    speedtest1_run;
  end;
  speedtest1_exec('COMMIT');
  speedtest1_end_test;

  { ---- 161 ---- }
  n := sz div 5;
  speedtest1_begin_test(161, '%d SELECTS, numeric BETWEEN, PK', [n]);
  speedtest1_exec('BEGIN');
  speedtest1_prepare(
    'SELECT count(*), avg(b), sum(length(c)), group_concat(a) FROM z2'#10 +
    ' WHERE a BETWEEN ?1 AND ?2; -- %d times', [n]);
  for i := 1 to n do begin
    if ((i - 1) mod g.nRepeat) = 0 then begin
      x1 := speedtest1_random mod LongWord(maxb);
      x2 := (speedtest1_random mod 10) + LongWord(sz div 5000) + x1;
    end;
    sqlite3_bind_int(g.pStmt, 1, Integer(x1));
    sqlite3_bind_int(g.pStmt, 2, Integer(x2));
    speedtest1_run;
  end;
  speedtest1_exec('COMMIT');
  speedtest1_end_test;

  { ---- 170 ---- }
  n := sz div 5;
  speedtest1_begin_test(170, '%d SELECTS, text BETWEEN, indexed', [n]);
  speedtest1_exec('BEGIN');
  speedtest1_prepare(
    'SELECT count(*), avg(b), sum(length(c)), group_concat(a) FROM z1'#10 +
    ' WHERE c BETWEEN ?1 AND (?1||''~''); -- %d times', [n]);
  for i := 1 to n do begin
    if ((i - 1) mod g.nRepeat) = 0 then begin
      x1 := swizzle(LongWord(i), LongWord(maxb));
      zNum := speedtest1_numbername(x1);
      len := Length(zNum);
    end;
    sqlite3_bind_text(g.pStmt, 1, PAnsiChar(zNum), len, SQLITE_STATIC);
    speedtest1_run;
  end;
  speedtest1_exec('COMMIT');
  speedtest1_end_test;

  { ---- 180 ---- }
  n := sz;
  speedtest1_begin_test(180, '%d INSERTS with three indexes', [n]);
  speedtest1_exec('BEGIN');
  speedtest1_exec(
    'CREATE%s TABLE t4('#10 +
    '  a INTEGER %s %s,'#10 +
    '  b INTEGER %s,'#10 +
    '  c TEXT %s'#10 +
    ') %s',
    [isTemp(1), PAnsiChar(g.zNN), PAnsiChar(g.zPK),
     PAnsiChar(g.zNN), PAnsiChar(g.zNN), PAnsiChar(g.zWR)]);
  speedtest1_exec('CREATE INDEX t4b ON t4(b)');
  speedtest1_exec('CREATE INDEX t4c ON t4(c)');
  speedtest1_exec('INSERT INTO t4 SELECT * FROM z1');
  speedtest1_exec('COMMIT');
  speedtest1_end_test;

  { ---- 190 ---- }
  n := sz;
  speedtest1_begin_test(190, 'DELETE and REFILL one table', [n]);
  speedtest1_exec('DELETE FROM z2;');
  speedtest1_exec('INSERT INTO z2 SELECT * FROM z1;');
  speedtest1_end_test;

  { ---- 200 ---- }
  speedtest1_begin_test(200, 'VACUUM');
  speedtest1_exec('VACUUM');
  speedtest1_end_test;

  { ---- 210 ---- }
  speedtest1_begin_test(210, 'ALTER TABLE ADD COLUMN, and query');
  speedtest1_exec('ALTER TABLE z2 ADD COLUMN d INT DEFAULT 123');
  speedtest1_exec('SELECT sum(d) FROM z2');
  speedtest1_end_test;

  { ---- 230 ---- }
  n := sz div 5;
  speedtest1_begin_test(230, '%d UPDATES, numeric BETWEEN, indexed', [n]);
  speedtest1_exec('BEGIN');
  speedtest1_prepare(
    'UPDATE z2 SET d=b*2 WHERE b BETWEEN ?1 AND ?2; -- %d times', [n]);
  for i := 1 to n do begin
    x1 := speedtest1_random mod LongWord(maxb);
    x2 := (speedtest1_random mod 10) + LongWord(sz div 5000) + x1;
    sqlite3_bind_int(g.pStmt, 1, Integer(x1));
    sqlite3_bind_int(g.pStmt, 2, Integer(x2));
    speedtest1_run;
  end;
  speedtest1_exec('COMMIT');
  speedtest1_end_test;

  { ---- 240 ---- }
  n := sz;
  speedtest1_begin_test(240, '%d UPDATES of individual rows', [n]);
  speedtest1_exec('BEGIN');
  speedtest1_prepare('UPDATE z2 SET d=b*3 WHERE a=?1; -- %d times', [n]);
  for i := 1 to n do begin
    x1 := (speedtest1_random mod LongWord(sz)) + 1;
    sqlite3_bind_int(g.pStmt, 1, Integer(x1));
    speedtest1_run;
  end;
  speedtest1_exec('COMMIT');
  speedtest1_end_test;

  { ---- 250 ---- }
  speedtest1_begin_test(250, 'One big UPDATE of the whole %d-row table', [sz]);
  speedtest1_exec('UPDATE z2 SET d=b*4');
  speedtest1_end_test;

  { ---- 260 ---- }
  speedtest1_begin_test(260, 'Query added column after filling');
  speedtest1_exec('SELECT sum(d) FROM z2');
  speedtest1_end_test;

  { ---- 270 ---- }
  n := sz div 5;
  speedtest1_begin_test(270, '%d DELETEs, numeric BETWEEN, indexed', [n]);
  speedtest1_exec('BEGIN');
  speedtest1_prepare(
    'DELETE FROM z2 WHERE b BETWEEN ?1 AND ?2; -- %d times', [n]);
  for i := 1 to n do begin
    x1 := (speedtest1_random mod LongWord(maxb)) + 1;
    x2 := (speedtest1_random mod 10) + LongWord(sz div 5000) + x1;
    sqlite3_bind_int(g.pStmt, 1, Integer(x1));
    sqlite3_bind_int(g.pStmt, 2, Integer(x2));
    speedtest1_run;
  end;
  speedtest1_exec('COMMIT');
  speedtest1_end_test;

  { ---- 280 ---- }
  n := sz;
  speedtest1_begin_test(280, '%d DELETEs of individual rows', [n]);
  speedtest1_exec('BEGIN');
  speedtest1_prepare('DELETE FROM t3 WHERE a=?1; -- %d times', [n]);
  for i := 1 to n do begin
    x1 := (speedtest1_random mod LongWord(sz)) + 1;
    sqlite3_bind_int(g.pStmt, 1, Integer(x1));
    speedtest1_run;
  end;
  speedtest1_exec('COMMIT');
  speedtest1_end_test;

  { ---- 290 ---- }
  speedtest1_begin_test(290, 'Refill two %d-row tables using REPLACE', [sz]);
  speedtest1_exec('REPLACE INTO z2(a,b,c) SELECT a,b,c FROM z1');
  speedtest1_exec('REPLACE INTO t3(a,b,c) SELECT a,b,c FROM z1');
  speedtest1_end_test;

  { ---- 300 ---- }
  speedtest1_begin_test(300, 'Refill a %d-row table using (b&1)==(a&1)', [sz]);
  speedtest1_exec('DELETE FROM z2;');
  speedtest1_exec('INSERT INTO z2(a,b,c)'#10 +
                  ' SELECT a,b,c FROM z1  WHERE (b&1)==(a&1);');
  speedtest1_exec('INSERT INTO z2(a,b,c)'#10 +
                  ' SELECT a,b,c FROM z1  WHERE (b&1)<>(a&1);');
  speedtest1_end_test;

  { ---- 310 ---- }
  n := sz div 5;
  speedtest1_begin_test(310, '%d four-ways joins', [n]);
  speedtest1_exec('BEGIN');
  speedtest1_prepare(
    'SELECT z1.c FROM z1, z2, t3, t4'#10 +
    ' WHERE t4.a BETWEEN ?1 AND ?2'#10 +
    '   AND t3.a=t4.b'#10 +
    '   AND z2.a=t3.b'#10 +
    '   AND z1.c=z2.c;');
  for i := 1 to n do begin
    x1 := (speedtest1_random mod LongWord(sz)) + 1;
    x2 := (speedtest1_random mod 10) + x1 + 4;
    sqlite3_bind_int(g.pStmt, 1, Integer(x1));
    sqlite3_bind_int(g.pStmt, 2, Integer(x2));
    speedtest1_run;
  end;
  speedtest1_exec('COMMIT');
  speedtest1_end_test;

  { ---- 320 ---- }
  speedtest1_begin_test(320, 'subquery in result set', [n]);
  speedtest1_prepare(
    'SELECT sum(a), max(c),'#10 +
    '       avg((SELECT a FROM z2 WHERE 5+z2.b=z1.b) AND rowid<?1), max(c)'#10 +
    ' FROM z1 WHERE rowid<?1;');
  sqlite3_bind_int(g.pStmt, 1, est_square_root(g.szTest) * 50);
  speedtest1_run;
  speedtest1_end_test;

  { ---- 400 ---- }
  sz := g.szTest * 700;
  n  := sz;
  maxb := Integer(roundup_allones(LongWord(sz div 3)));
  speedtest1_begin_test(400, '%d REPLACE ops on an IPK', [n]);
  speedtest1_exec('BEGIN');
  speedtest1_exec('CREATE%s TABLE t5(a INTEGER PRIMARY KEY, b %s);',
                  [isTemp(9), PAnsiChar(g.zNN)]);
  speedtest1_prepare('REPLACE INTO t5 VALUES(?1,?2); --  %d times', [n]);
  for i := 1 to n do begin
    x1 := swizzle(LongWord(i), LongWord(maxb));
    zNum := speedtest1_numbername(LongWord(i));
    sqlite3_bind_int(g.pStmt, 1, Integer(x1));
    sqlite3_bind_text(g.pStmt, 2, PAnsiChar(zNum), -1, SQLITE_STATIC);
    speedtest1_run;
  end;
  speedtest1_exec('COMMIT');
  speedtest1_end_test;

  { ---- 410 ---- }
  speedtest1_begin_test(410, '%d SELECTS on an IPK', [n]);
  if g.doBigTransactions <> 0 then speedtest1_exec('BEGIN');
  speedtest1_prepare('SELECT b FROM t5 WHERE a=?1; --  %d times', [n]);
  for i := 1 to n do begin
    x1 := swizzle(LongWord(i), LongWord(maxb));
    sqlite3_bind_int(g.pStmt, 1, Integer(x1));
    speedtest1_run;
  end;
  if g.doBigTransactions <> 0 then speedtest1_exec('COMMIT');
  speedtest1_end_test;

  { ---- 500 ---- }
  sz := g.szTest * 700;
  n  := sz;
  maxb := Integer(roundup_allones(LongWord(sz div 3)));
  speedtest1_begin_test(500, '%d REPLACE on TEXT PK', [n]);
  speedtest1_exec('BEGIN');
  if sqlite3_libversion_number >= 3008002 then
    speedtest1_exec('CREATE%s TABLE t6(a TEXT PRIMARY KEY, b %s)%s;',
                    [isTemp(9), PAnsiChar(g.zNN), PAnsiChar('WITHOUT ROWID')])
  else
    speedtest1_exec('CREATE%s TABLE t6(a TEXT PRIMARY KEY, b %s)%s;',
                    [isTemp(9), PAnsiChar(g.zNN), PAnsiChar('')]);
  speedtest1_prepare('REPLACE INTO t6 VALUES(?1,?2); --  %d times', [n]);
  for i := 1 to n do begin
    x1 := swizzle(LongWord(i), LongWord(maxb));
    zNum := speedtest1_numbername(x1);
    sqlite3_bind_int(g.pStmt, 2, i);
    sqlite3_bind_text(g.pStmt, 1, PAnsiChar(zNum), -1, SQLITE_STATIC);
    speedtest1_run;
  end;
  speedtest1_exec('COMMIT');
  speedtest1_end_test;

  { ---- 510 ---- }
  speedtest1_begin_test(510, '%d SELECTS on a TEXT PK', [n]);
  if g.doBigTransactions <> 0 then speedtest1_exec('BEGIN');
  speedtest1_prepare('SELECT b FROM t6 WHERE a=?1; --  %d times', [n]);
  for i := 1 to n do begin
    x1 := swizzle(LongWord(i), LongWord(maxb));
    zNum := speedtest1_numbername(x1);
    sqlite3_bind_text(g.pStmt, 1, PAnsiChar(zNum), -1, SQLITE_STATIC);
    speedtest1_run;
  end;
  if g.doBigTransactions <> 0 then speedtest1_exec('COMMIT');
  speedtest1_end_test;

  { ---- 520 ---- }
  speedtest1_begin_test(520, '%d SELECT DISTINCT', [n]);
  speedtest1_exec('SELECT DISTINCT b FROM t5;');
  speedtest1_exec('SELECT DISTINCT b FROM t6;');
  speedtest1_end_test;

  { ---- 980 ---- }
  speedtest1_begin_test(980, 'PRAGMA integrity_check');
  speedtest1_exec('PRAGMA integrity_check');
  speedtest1_end_test;

  { ---- 990 ---- }
  speedtest1_begin_test(990, 'ANALYZE');
  speedtest1_exec('ANALYZE');
  speedtest1_end_test;
end;
procedure testset_cte;         begin testset_not_yet('cte',         'Phase 11.3'); end;
procedure testset_fp;          begin testset_not_yet('fp',          'Phase 11.3'); end;
procedure testset_parsenumber; begin testset_not_yet('parsenumber', 'Phase 11.3'); end;
procedure testset_star;        begin testset_not_yet('star',        'Phase 11.4'); end;
procedure testset_orm;         begin testset_not_yet('orm',         'Phase 11.4'); end;
procedure testset_trigger;     begin testset_not_yet('trigger',     'Phase 11.4'); end;
procedure testset_debug1;      begin testset_not_yet('debug1',      'Phase 11.5'); end;
procedure testset_json;        begin testset_not_yet('json',        'Phase 11.5'); end;
procedure testset_app;         begin testset_not_yet('app',         'Phase 11.5'); end;
procedure testset_rtree(a, b: Integer); begin testset_not_yet('rtree', 'Phase 11.5'); end;

{ =========================== main() ===================================== }

var
  doAutovac: Integer = 0;
  cacheSize: Integer = 0;
  doExclusive: Integer = 0;
  doFullFSync: Integer = 0;
  nHeap: Integer = 0;
  mnHeap: Integer = 0;
  doIncrvac: Integer = 0;
  zJMode: AnsiString = '';
  zKey: AnsiString = '';
  nHardHeapLmt: Integer = 0;
  nSoftHeapLmt: Integer = 0;
  nLook: Integer = -1;
  szLook: Integer = 0;
  noSync: Integer = 0;
  pageSize: Integer = 0;
  nPCache: Integer = 0;
  szPCache: Integer = 0;
  doPCache: Integer = 0;
  showStats: Integer = 0;
  nThread: Integer = 0;
  mmapSize: Integer = 0;
  memDb: Integer = 0;
  openFlags: Integer = SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE;
  zTSet: AnsiString = 'mix1';
  doTrace: Integer = 0;
  zEncoding: AnsiString = '';
  pHeap: Pointer = nil;
  pLook: Pointer = nil;
  pPCache: Pointer = nil;
  iCur, iHi: i32;
  i: Integer;
  rc: Integer;
  argc: Integer;

  zMix1Tests: AnsiString;
  z: AnsiString;
  zArg: PAnsiChar;
  k: Integer;
  zSep, zComma: Integer;
  zThisTest: AnsiString;
  rem: AnsiString;
  pVfs: Psqlite3_vfs;
  zVfsArg: PAnsiChar;
  zSql, zObj: AnsiString;

procedure ArgcCheck(N: Integer);
begin
  if i > argc - N then
    fatal_error('missing argument on %s'#10, [PAnsiChar(ParamStr(i))]);
end;

function GetArg(idx: Integer): AnsiString;
begin
  Result := ParamStr(idx);
end;

procedure PrintHelp;
var s: AnsiString;
begin
  s := sqlite3FormatStr(PAnsiChar(zHelp), [PAnsiChar(ParamStr(0))]);
  Write(s);
end;

begin
  zMix1Tests := 'main,orm/25,cte/20,json,fp/3,parsenumber/25,rtree/10,star,app';
  argc := ParamCount + 1;       { ParamStr(0)..ParamStr(argc-1) — matches C argv }

  { Display the version of SQLite being tested. }
  WriteLn(Format('-- Speedtest1 for SQLite %s %s',
    [sqlite3_libversion, Copy(AnsiString(sqlite3_sourceid), 1, 48)]));

  { Process command-line arguments. }
  g.zDbName := '';
  g.zVfs    := '';
  g.zWR     := '';
  g.zNN     := '';
  g.zPK     := 'UNIQUE';
  g.szTest  := 100;
  g.szBase  := 100;
  g.nRepeat := 1;

  i := 1;
  while i < argc do begin
    z := GetArg(i);
    if (Length(z) > 0) and (z[1] = '-') then begin
      while (Length(z) > 0) and (z[1] = '-') do Delete(z, 1, 1);
      if      z = 'autovacuum'       then doAutovac := 1
      else if z = 'big-transactions' then g.doBigTransactions := 1
      else if z = 'cachesize' then begin
        ArgcCheck(1); Inc(i); cacheSize := integerValue(PAnsiChar(GetArg(i)));
      end
      else if z = 'exclusive'  then doExclusive := 1
      else if z = 'fullfsync'  then doFullFSync := 1
      else if z = 'checkpoint' then g.doCheckpoint := 1
      else if z = 'explain'    then begin g.bSqlOnly := 1; g.bExplain := 1; end
      else if z = 'hard-heap-limit' then begin
        ArgcCheck(1); nHardHeapLmt := integerValue(PAnsiChar(GetArg(i+1))); Inc(i);
      end
      else if z = 'heap' then begin
        ArgcCheck(2);
        nHeap  := integerValue(PAnsiChar(GetArg(i+1)));
        mnHeap := integerValue(PAnsiChar(GetArg(i+2)));
        Inc(i, 2);
      end
      else if z = 'incrvacuum' then doIncrvac := 1
      else if z = 'journal' then begin ArgcCheck(1); Inc(i); zJMode := GetArg(i); end
      else if z = 'key'     then begin ArgcCheck(1); Inc(i); zKey   := GetArg(i); end
      else if z = 'lookaside' then begin
        ArgcCheck(2);
        nLook  := integerValue(PAnsiChar(GetArg(i+1)));
        szLook := integerValue(PAnsiChar(GetArg(i+2)));
        Inc(i, 2);
      end
      else if z = 'memdb'       then memDb := 1
      else if z = 'multithread' then sqlite3_config(SQLITE_CONFIG_MULTITHREAD, 0)
      else if z = 'nomemstat'   then sqlite3_config(SQLITE_CONFIG_MEMSTATUS, 0)
      else if z = 'mmap' then begin
        ArgcCheck(1); Inc(i); mmapSize := integerValue(PAnsiChar(GetArg(i)));
      end
      else if z = 'nomutex' then openFlags := openFlags or SQLITE_OPEN_NOMUTEX
      else if z = 'nosync'  then noSync := 1
      else if z = 'notnull' then g.zNN := 'NOT NULL'
      else if z = 'output'  then
        fatal_error('--output option not supported in skeleton harness (Phase 11.x)'#10)
      else if z = 'pagesize' then begin
        ArgcCheck(1); Inc(i); pageSize := integerValue(PAnsiChar(GetArg(i)));
      end
      else if z = 'pcache' then begin
        ArgcCheck(2);
        nPCache  := integerValue(PAnsiChar(GetArg(i+1)));
        szPCache := integerValue(PAnsiChar(GetArg(i+2)));
        doPCache := 1;
        Inc(i, 2);
      end
      else if z = 'primarykey' then g.zPK := 'PRIMARY KEY'
      else if z = 'repeat'    then begin ArgcCheck(1); Inc(i); g.nRepeat := integerValue(PAnsiChar(GetArg(i))); end
      else if z = 'reprepare' then g.bReprepare := 1
      else if z = 'serialized'   then sqlite3_config(SQLITE_CONFIG_SERIALIZED,   0)
      else if z = 'singlethread' then sqlite3_config(SQLITE_CONFIG_SINGLETHREAD, 0)
      else if z = 'script' then begin
        ArgcCheck(1); Inc(i);
        if g.pScriptOpen then CloseFile(g.pScript);
        AssignFile(g.pScript, GetArg(i));
        try Rewrite(g.pScript); g.pScriptOpen := True;
        except fatal_error('unable to open output file "%s"'#10, [PAnsiChar(GetArg(i))]); end;
      end
      else if z = 'sqlonly'       then g.bSqlOnly := 1
      else if z = 'shrink-memory' then g.bMemShrink := 1
      else if z = 'size' then begin
        ArgcCheck(1); Inc(i);
        g.szTest := integerValue(PAnsiChar(GetArg(i)));
        g.szBase := g.szTest;
      end
      else if z = 'soft-heap-limit' then begin
        ArgcCheck(1); nSoftHeapLmt := integerValue(PAnsiChar(GetArg(i+1))); Inc(i);
      end
      else if z = 'stats'   then showStats := 1
      else if z = 'temp' then begin
        ArgcCheck(1); Inc(i);
        if (Length(GetArg(i)) <> 1) or (GetArg(i)[1] < '0') or (GetArg(i)[1] > '9') then
          fatal_error('argument to --temp should be integer between 0 and 9'#10);
        g.eTemp := Ord(GetArg(i)[1]) - Ord('0');
      end
      else if z = 'testset'   then begin ArgcCheck(1); Inc(i); zTSet := GetArg(i); end
      else if z = 'trace'     then doTrace := 1
      else if z = 'threads'   then begin ArgcCheck(1); Inc(i); nThread := integerValue(PAnsiChar(GetArg(i))); end
      else if z = 'utf16le'   then zEncoding := 'utf16le'
      else if z = 'utf16be'   then zEncoding := 'utf16be'
      else if z = 'verify'    then begin g.bVerify := 1; HashInit; end
      else if z = 'vfs'       then begin ArgcCheck(1); Inc(i); g.zVfs := GetArg(i); end
      else if z = 'reserve'   then begin ArgcCheck(1); Inc(i); g.nReserve := StrToIntDef(GetArg(i), 0); end
      else if z = 'stmtscanstatus' then g.stmtScanStatus := 1
      else if z = 'without-rowid' then begin
        if Pos('WITHOUT', g.zWR) > 0 then  { no-op }
        else if Pos('STRICT', g.zWR) > 0 then g.zWR := 'WITHOUT ROWID,STRICT'
        else g.zWR := 'WITHOUT ROWID';
        g.zPK := 'PRIMARY KEY';
      end
      else if z = 'strict' then begin
        if Pos('STRICT', g.zWR) > 0 then  { no-op }
        else if Pos('WITHOUT', g.zWR) > 0 then g.zWR := 'WITHOUT ROWID,STRICT'
        else g.zWR := 'STRICT';
      end
      else if (z = 'help') or (z = '?') then begin
        PrintHelp;
        Halt(0);
      end
      else
        fatal_error('unknown option: %s'#10'Use "%s -?" for help'#10,
          [PAnsiChar(GetArg(i)), PAnsiChar(ParamStr(0))]);
    end else if g.zDbName = '' then
      g.zDbName := GetArg(i)
    else
      fatal_error('surplus argument: %s'#10'Use "%s -?" for help'#10,
        [PAnsiChar(GetArg(i)), PAnsiChar(ParamStr(0))]);
    Inc(i);
  end;

  { Heap / pcache / lookaside config arms — speedtest1.c:3216..3235.
    The Pas port doesn't expose pHeap / pPCache wiring through the
    sqlite3_config overloads yet; emit a soft note and proceed (this
    keeps the gate working for default invocations). }
  if (nHeap > 0) or (doPCache <> 0) then begin
    Write(StdErr,
      'speedtest1: --heap / --pcache config not wired in Phase 11.1 skeleton'#10);
  end;
  if nLook >= 0 then
    sqlite3_config(SQLITE_CONFIG_LOOKASIDE, i32(0), i32(0));

  sqlite3_initialize;

  if g.zDbName <> '' then begin
    pVfs := sqlite3_vfs_find(PAnsiChar(g.zVfs));
    if pVfs <> nil then
      pVfs^.xDelete(pVfs, PAnsiChar(g.zDbName), 1);
    { unix unlink for historical compat — best-effort, ignore failure. }
    DeleteFile(g.zDbName);
  end;

  { Open the database. }
  if g.zVfs = '' then zVfsArg := nil else zVfsArg := PAnsiChar(g.zVfs);
  if memDb <> 0 then
    rc := sqlite3_open_v2(':memory:', @g.db, openFlags, zVfsArg)
  else
    rc := sqlite3_open_v2(PAnsiChar(g.zDbName), @g.db, openFlags, zVfsArg);
  if rc <> SQLITE_OK then
    fatal_error('Cannot open database file: %s'#10, [PAnsiChar(g.zDbName)]);

  if (nLook > 0) and (szLook > 0) then begin
    rc := sqlite3_db_config_lookaside(g.db, SQLITE_DBCONFIG_LOOKASIDE,
            nil, szLook, nLook);
    if rc <> 0 then fatal_error('lookaside configuration failed: %d'#10, [rc]);
  end;
  if g.nReserve > 0 then
    sqlite3_file_control(g.db, nil, SQLITE_FCNTL_RESERVE_BYTES, @g.nReserve);
  if g.stmtScanStatus <> 0 then
    sqlite3_db_config_int(g.db, SQLITE_DBCONFIG_STMT_SCANSTATUS, 1, nil);

  { Set database connection options. }
  sqlite3_create_function(g.db, 'random', 0, SQLITE_UTF8, nil,
                          @randomFunc, nil, nil);
  if doTrace <> 0 then sqlite3_trace(g.db, @traceCallback, nil);
  if memDb > 0 then speedtest1_exec('PRAGMA temp_store=memory');
  if mmapSize > 0 then speedtest1_exec('PRAGMA mmap_size=%d', [mmapSize]);
  speedtest1_exec('PRAGMA threads=%d', [nThread]);
  if zKey <> ''      then speedtest1_exec('PRAGMA key(''%s'')', [PAnsiChar(zKey)]);
  if zEncoding <> '' then speedtest1_exec('PRAGMA encoding=%s', [PAnsiChar(zEncoding)]);
  if doAutovac <> 0 then speedtest1_exec('PRAGMA auto_vacuum=FULL')
  else if doIncrvac <> 0 then speedtest1_exec('PRAGMA auto_vacuum=INCREMENTAL');
  if pageSize  <> 0 then speedtest1_exec('PRAGMA page_size=%d', [pageSize]);
  if cacheSize <> 0 then speedtest1_exec('PRAGMA cache_size=%d', [cacheSize]);
  if noSync <> 0 then speedtest1_exec('PRAGMA synchronous=OFF')
  else if doFullFSync <> 0 then speedtest1_exec('PRAGMA fullfsync=ON');
  if doExclusive <> 0 then speedtest1_exec('PRAGMA locking_mode=EXCLUSIVE');
  if zJMode <> '' then speedtest1_exec('PRAGMA journal_mode=%s', [PAnsiChar(zJMode)]);
  if nHardHeapLmt > 0 then speedtest1_exec('PRAGMA hard_heap_limit=%d', [nHardHeapLmt]);
  if nSoftHeapLmt > 0 then speedtest1_exec('PRAGMA soft_heap_limit=%d', [nSoftHeapLmt]);
  if zJMode <> '' then speedtest1_exec('PRAGMA journal_mode=%s', [PAnsiChar(zJMode)]);

  if g.bExplain <> 0 then WriteLn('.explain'#10'.echo on');
  if zTSet = 'mix1' then zTSet := zMix1Tests;

  repeat
    zComma := Pos(',', zTSet);
    if zComma > 0 then begin
      zThisTest := Copy(zTSet, 1, zComma - 1);
      rem := Copy(zTSet, zComma + 1, MaxInt);
    end else begin
      zThisTest := zTSet;
      rem := '';
    end;
    zSep := Pos('/', zThisTest);
    if zSep > 0 then begin
      k := 1;
      while (zSep + k <= Length(zThisTest)) and
            (zThisTest[zSep + k] >= '0') and
            (zThisTest[zSep + k] <= '9') do Inc(k);
      if (k = 1) or (zSep + k <= Length(zThisTest)) then
        fatal_error('bad modifier on testset name: "%s"', [PAnsiChar(zThisTest)]);
      g.szTest := g.szBase * integerValue(PAnsiChar(Copy(zThisTest, zSep + 1, MaxInt))) div 100;
      if g.szTest <= 0 then g.szTest := 1;
      zThisTest := Copy(zThisTest, 1, zSep - 1);
    end else
      g.szTest := g.szBase;

    if (g.iTotal > 0) or (zComma = 0) then
      WriteLn('       Begin testset "', zThisTest, '"');

    if      zThisTest = 'main'        then testset_main
    else if zThisTest = 'debug1'      then testset_debug1
    else if zThisTest = 'orm'         then testset_orm
    else if zThisTest = 'cte'         then testset_cte
    else if zThisTest = 'star'        then testset_star
    else if zThisTest = 'app'         then testset_app
    else if zThisTest = 'fp'          then testset_fp
    else if zThisTest = 'json'        then testset_json
    else if zThisTest = 'trigger'     then testset_trigger
    else if zThisTest = 'parsenumber' then testset_parsenumber
    else if zThisTest = 'rtree'       then testset_rtree(6, 147)
    else
      fatal_error('unknown testset: "%s"'#10 +
                  'Choices: cte debug1 fp main orm rtree trigger'#10,
                  [PAnsiChar(zThisTest)]);

    zTSet := rem;
    if zTSet <> '' then begin
      speedtest1_begin_test(999, 'Reset the database');
      while True do begin
        zObj := speedtest1_once(
          'SELECT name FROM main.sqlite_master' +
          ' WHERE sql LIKE ''CREATE %TABLE%''');
        if zObj = '' then Break;
        zSql := Format('DROP TABLE main."%s"', [zObj]);
        speedtest1_exec(zSql);
      end;
      while True do begin
        zObj := speedtest1_once(
          'SELECT name FROM temp.sqlite_master' +
          ' WHERE sql LIKE ''CREATE %TABLE%''');
        if zObj = '' then Break;
        zSql := Format('DROP TABLE main."%s"', [zObj]);
        speedtest1_exec(zSql);
      end;
      speedtest1_end_test;
    end;
  until zTSet = '';

  speedtest1_final;

  if showStats <> 0 then begin
    sqlite3_db_status(g.db, SQLITE_DBSTATUS_LOOKASIDE_USED, @iCur, @iHi, 0);
    WriteLn(Format('-- Lookaside Slots Used:        %d (max %d)', [iCur, iHi]));
    sqlite3_db_status(g.db, SQLITE_DBSTATUS_LOOKASIDE_HIT,  @iCur, @iHi, 0);
    WriteLn(Format('-- Successful lookasides:       %d', [iHi]));
    sqlite3_db_status(g.db, SQLITE_DBSTATUS_LOOKASIDE_MISS_SIZE, @iCur, @iHi, 0);
    WriteLn(Format('-- Lookaside size faults:       %d', [iHi]));
    sqlite3_db_status(g.db, SQLITE_DBSTATUS_LOOKASIDE_MISS_FULL, @iCur, @iHi, 0);
    WriteLn(Format('-- Lookaside OOM faults:        %d', [iHi]));
    sqlite3_db_status(g.db, SQLITE_DBSTATUS_CACHE_USED, @iCur, @iHi, 0);
    WriteLn(Format('-- Pager Heap Usage:            %d bytes', [iCur]));
    sqlite3_db_status(g.db, SQLITE_DBSTATUS_CACHE_HIT,  @iCur, @iHi, 1);
    WriteLn(Format('-- Page cache hits:             %d', [iCur]));
    sqlite3_db_status(g.db, SQLITE_DBSTATUS_CACHE_MISS, @iCur, @iHi, 1);
    WriteLn(Format('-- Page cache misses:           %d', [iCur]));
    sqlite3_db_status(g.db, SQLITE_DBSTATUS_CACHE_WRITE,@iCur, @iHi, 1);
    WriteLn(Format('-- Page cache writes:           %d', [iCur]));
    sqlite3_db_status(g.db, SQLITE_DBSTATUS_SCHEMA_USED, @iCur, @iHi, 0);
    WriteLn(Format('-- Schema Heap Usage:           %d bytes', [iCur]));
    sqlite3_db_status(g.db, SQLITE_DBSTATUS_STMT_USED,   @iCur, @iHi, 0);
    WriteLn(Format('-- Statement Heap Usage:        %d bytes', [iCur]));
  end;

  sqlite3_close(g.db);

  if showStats <> 0 then begin
    sqlite3_status(SQLITE_STATUS_MEMORY_USED,  @iCur, @iHi, 0);
    WriteLn(Format('-- Memory Used (bytes):         %d (max %d)', [iCur, iHi]));
    sqlite3_status(SQLITE_STATUS_MALLOC_COUNT, @iCur, @iHi, 0);
    WriteLn(Format('-- Outstanding Allocations:     %d (max %d)', [iCur, iHi]));
    sqlite3_status(SQLITE_STATUS_PAGECACHE_OVERFLOW, @iCur, @iHi, 0);
    WriteLn(Format('-- Pcache Overflow Bytes:       %d (max %d)', [iCur, iHi]));
    sqlite3_status(SQLITE_STATUS_MALLOC_SIZE,  @iCur, @iHi, 0);
    WriteLn(Format('-- Largest Allocation:          %d bytes', [iHi]));
    sqlite3_status(SQLITE_STATUS_PAGECACHE_SIZE,@iCur, @iHi, 0);
    WriteLn(Format('-- Largest Pcache Allocation:   %d bytes', [iHi]));
  end;

  if g.pScriptOpen then CloseFile(g.pScript);
end.
