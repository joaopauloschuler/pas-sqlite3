{
  SPDX-License-Identifier: blessing

  Faithful port of ../sqlite3/ext/intck/sqlite3intck.c (~941 lines C).

  Provides the incremental integrity-check API:

    sqlite3_intck_open(db, zDb, &p)
    sqlite3_intck_step(p)
    sqlite3_intck_message(p)
    sqlite3_intck_unlock(p)
    sqlite3_intck_error(p, &zErr)
    sqlite3_intck_close(p)
    sqlite3_intck_test_sql(p, zObj)

  The intck object resembles PRAGMA integrity_check but is incremental:
  caller drives one step at a time, and may sqlite3_intck_unlock() to
  release the read transaction between steps.

  Pascal-port adaptations:
    * intckPrepareFmt / intckMprintf accept Pascal `array of const`
      instead of C va_list.
    * The C `%z` printf extension auto-frees the input pointer; the
      Pascal port keeps `%z` behaving like `%s` (no auto-free) and
      every C `%z`-chain has been rewritten to free the previous
      buffer explicitly with sqlite3_free().
}
{$I passqlite3.inc}
unit passqlite3intck;

interface

uses
  passqlite3types,
  passqlite3util,
  passqlite3printf,
  passqlite3os,
  passqlite3vdbe,
  passqlite3vtab,
  passqlite3main;

type
  PIntck = ^TIntck;
  PPIntck = ^PIntck;
  TIntck = record
    db:             PTsqlite3;
    zDb:            PAnsiChar;     { Pointer into trailing copy }
    zObj:           PAnsiChar;     { Current object. Or nil. }
    pCheck:         PVdbe;         { Current check statement }
    zKey:           PAnsiChar;
    nKeyVal:        i32;
    zMessage:       PAnsiChar;
    bCorruptSchema: i32;
    rc:             i32;           { Error code }
    zErr:           PAnsiChar;     { Error message }
    zTestSql:       PAnsiChar;     { Returned by sqlite3_intck_test_sql }
  end;

function sqlite3_intck_open(db: PTsqlite3; zDbArg: PAnsiChar;
                            ppOut: PPIntck): i32;
procedure sqlite3_intck_close(p: PIntck);
function sqlite3_intck_step(p: PIntck): i32;
function sqlite3_intck_message(p: PIntck): PAnsiChar;
function sqlite3_intck_unlock(p: PIntck): i32;
function sqlite3_intck_error(p: PIntck; pzErr: PPAnsiChar): i32;
function sqlite3_intck_test_sql(p: PIntck; zObj: PAnsiChar): PAnsiChar;

implementation

{ -----------------------------------------------------------------------
  Local helpers
  ----------------------------------------------------------------------- }

function strLenZ(s: PAnsiChar): SizeUInt;
var p: PAnsiChar;
begin
  if s = nil then begin Result := 0; Exit; end;
  p := s;
  while p^ <> #0 do Inc(p);
  Result := SizeUInt(p - s);
end;

{ Format with sqlite3PfMprintf semantics (caller frees). }
function pfFmt(fmt: PAnsiChar; const args: array of const): PAnsiChar;
begin
  Result := sqlite3PfMprintf(fmt, args);
end;

{ Save db error code + message into p->rc / p->zErr. }
procedure intckSaveErrmsg(p: PIntck);
begin
  p^.rc := sqlite3_errcode(p^.db);
  if p^.zErr <> nil then sqlite3_free(p^.zErr);
  p^.zErr := pfFmt('%s', [sqlite3_errmsg(p^.db)]);
end;

{ Prepare a statement using the intck error convention. }
function intckPrepare(p: PIntck; zSql: PAnsiChar): PVdbe;
var pRet: PVdbe;
begin
  pRet := nil;
  if p^.rc = SQLITE_OK then begin
    p^.rc := sqlite3_prepare_v2(p^.db, zSql, -1, @pRet, nil);
    if p^.rc <> SQLITE_OK then begin
      intckSaveErrmsg(p);
      pRet := nil;
    end;
  end;
  Result := pRet;
end;

{ Format-and-prepare. }
function intckPrepareFmt(p: PIntck; fmt: PAnsiChar;
  const args: array of const): PVdbe;
var
  zSql: PAnsiChar;
  pRet: PVdbe;
begin
  zSql := pfFmt(fmt, args);
  if (p^.rc = SQLITE_OK) and (zSql = nil) then
    p^.rc := SQLITE_NOMEM;
  pRet := intckPrepare(p, zSql);
  if zSql <> nil then sqlite3_free(zSql);
  Result := pRet;
end;

procedure intckFinalize(p: PIntck; pStmt: PVdbe);
var rc: i32;
begin
  rc := sqlite3_finalize(pStmt);
  if (p^.rc = SQLITE_OK) and (rc <> SQLITE_OK) then
    intckSaveErrmsg(p);
end;

function intckStep(p: PIntck; pStmt: PVdbe): i32;
begin
  if p^.rc <> 0 then begin Result := p^.rc; Exit; end;
  Result := sqlite3_step(pStmt);
end;

procedure intckExec(p: PIntck; zSql: PAnsiChar);
var pStmt: PVdbe;
begin
  pStmt := intckPrepare(p, zSql);
  intckStep(p, pStmt);
  intckFinalize(p, pStmt);
end;

{ printf wrapper using the intck error convention.
  Returns nil if p is in an error state. }
function intckMprintf(p: PIntck; fmt: PAnsiChar;
  const args: array of const): PAnsiChar;
var zRet: PAnsiChar;
begin
  zRet := pfFmt(fmt, args);
  if p^.rc = SQLITE_OK then begin
    if zRet = nil then p^.rc := SQLITE_NOMEM;
  end else begin
    if zRet <> nil then sqlite3_free(zRet);
    zRet := nil;
  end;
  Result := zRet;
end;

{ -----------------------------------------------------------------------
  intckSaveKey — capture the resume vector for the current pCheck.
  ----------------------------------------------------------------------- }

procedure intckSaveKey(p: PIntck);
var
  ii, jj:    i32;
  zSql:      PAnsiChar;
  zOld, zL2, zR2, zW2: PAnsiChar;
  pStmt:     PVdbe;
  pXinfo:    PVdbe;
  zDir:      PAnsiChar;
  zSep:      PAnsiChar;
  bLastIsDesc, bLastIsNull: i32;
  zLast:     PAnsiChar;
  zOp:       PAnsiChar;
  zLhs, zRhs, zWhere: PAnsiChar;
  zLhsSep, zRhsSep:   PAnsiChar;
  zAlias:    PAnsiChar;
begin
  zSql  := nil;
  pStmt := nil;
  zDir  := nil;
  pXinfo := intckPrepareFmt(p,
    'SELECT group_concat(desc, '''') FROM %Q.sqlite_schema s, ' +
    'pragma_index_xinfo(%Q, %Q) ' +
    'WHERE s.type=''index'' AND s.name=%Q',
    [p^.zDb, p^.zObj, p^.zDb, p^.zObj]);
  if (p^.rc = SQLITE_OK) and (sqlite3_step(pXinfo) = SQLITE_ROW) then
    zDir := PAnsiChar(sqlite3_column_text(pXinfo, 0));

  if zDir = nil then begin
    { Object is a table — easy path, no DESC nor NULL pieces. }
    zSep := 'SELECT ''('' || ';
    for ii := 0 to p^.nKeyVal - 1 do begin
      zOld := zSql;
      zSql := intckMprintf(p, '%s%squote(?)', [zOld, zSep]);
      if zOld <> nil then sqlite3_free(zOld);
      zSep := ' || '', '' || ';
    end;
    zOld := zSql;
    zSql := intckMprintf(p, '%s || '')''', [zOld]);
    if zOld <> nil then sqlite3_free(zOld);
  end else begin
    { Object is an index. }
    for ii := p^.nKeyVal downto 1 do begin
      bLastIsDesc := i32(Ord(zDir[ii-1] = '1'));
      bLastIsNull := i32(Ord(sqlite3_column_type(p^.pCheck, ii) = SQLITE_NULL));
      zLast := sqlite3_column_name(p^.pCheck, ii);
      zLhs := nil;
      zRhs := nil;
      zWhere := nil;

      if bLastIsNull <> 0 then begin
        if bLastIsDesc <> 0 then continue;
        zWhere := intckMprintf(p, '''%s IS NOT NULL''', [zLast]);
      end else begin
        if bLastIsDesc <> 0 then zOp := '<' else zOp := '>';
        zWhere := intckMprintf(p, '''%s %s '' || quote(?%d)',
          [zLast, zOp, ii]);
      end;

      if ii > 1 then begin
        zLhsSep := '';
        zRhsSep := '';
        for jj := 0 to ii - 2 do begin
          zAlias := sqlite3_column_name(p^.pCheck, jj+1);
          zL2 := zLhs;
          zLhs := intckMprintf(p, '%s%s%s', [zL2, zLhsSep, zAlias]);
          if zL2 <> nil then sqlite3_free(zL2);
          zR2 := zRhs;
          zRhs := intckMprintf(p, '%s%squote(?%d)', [zR2, zRhsSep, jj+1]);
          if zR2 <> nil then sqlite3_free(zR2);
          zLhsSep := ',';
          zRhsSep := ' || '','' || ';
        end;

        zW2 := zWhere;
        zWhere := intckMprintf(p,
          '''(%s) IS ('' || %s || '') AND '' || %s',
          [zLhs, zRhs, zW2]);
        if zLhs <> nil then sqlite3_free(zLhs);
        if zRhs <> nil then sqlite3_free(zRhs);
        if zW2 <> nil then sqlite3_free(zW2);
      end;
      zW2 := zWhere;
      zWhere := intckMprintf(p, '''WHERE '' || %s', [zW2]);
      if zW2 <> nil then sqlite3_free(zW2);

      if zSql = nil then zSep := 'VALUES'
                    else zSep := ',' + #10 + '      ';
      zOld := zSql;
      zSql := intckMprintf(p, '%s%s(quote( %s ) )',
        [zOld, zSep, zWhere]);
      if zOld <> nil then sqlite3_free(zOld);
      if zWhere <> nil then sqlite3_free(zWhere);
    end;

    zOld := zSql;
    zSql := intckMprintf(p,
      'WITH wc(q) AS (' + #10 + '%s' + #10 + ')' +
      'SELECT ''VALUES'' || group_concat(''('' || q || '')'', '','#10 +
      '      '') FROM wc',
      [zOld]);
    if zOld <> nil then sqlite3_free(zOld);
  end;

  pStmt := intckPrepare(p, zSql);
  if p^.rc = SQLITE_OK then begin
    for ii := 0 to p^.nKeyVal - 1 do
      sqlite3_bind_value(pStmt, ii+1,
        sqlite3_column_value(p^.pCheck, ii+1));
    if sqlite3_step(pStmt) = SQLITE_ROW then
      p^.zKey := intckMprintf(p, '%s',
        [PAnsiChar(sqlite3_column_text(pStmt, 0))]);
    intckFinalize(p, pStmt);
  end;

  if zSql <> nil then sqlite3_free(zSql);
  intckFinalize(p, pXinfo);
end;

{ -----------------------------------------------------------------------
  Find the next object (table or index) to check.
  ----------------------------------------------------------------------- }

procedure intckFindObject(p: PIntck);
var
  pStmt: PVdbe;
  zPrev: PAnsiChar;
  zCmp:  PAnsiChar;
begin
  zPrev := p^.zObj;
  p^.zObj := nil;

  if p^.zKey <> nil then zCmp := '>=' else zCmp := '>';
  pStmt := intckPrepareFmt(p,
    'WITH tables(table_name) AS (' +
    '  SELECT name' +
    '  FROM %Q.sqlite_schema WHERE (type=''table'' OR type=''index'') AND rootpage' +
    '  UNION ALL ' +
    '  SELECT ''sqlite_schema''' +
    ')' +
    'SELECT table_name FROM tables ' +
    'WHERE ?1 IS NULL OR table_name%s?1 ' +
    'ORDER BY 1',
    [p^.zDb, zCmp]);

  if p^.rc = SQLITE_OK then begin
    sqlite3_bind_text(pStmt, 1, zPrev, -1, SQLITE_TRANSIENT);
    if sqlite3_step(pStmt) = SQLITE_ROW then
      p^.zObj := intckMprintf(p, '%s',
        [PAnsiChar(sqlite3_column_text(pStmt, 0))]);
  end;
  intckFinalize(p, pStmt);

  { If this is a new object, ensure the previous key value is cleared. }
  if sqlite3_stricmp(p^.zObj, zPrev) <> 0 then begin
    if p^.zKey <> nil then sqlite3_free(p^.zKey);
    p^.zKey := nil;
  end;

  if zPrev <> nil then sqlite3_free(zPrev);
end;

{ -----------------------------------------------------------------------
  Tokeniser used by intckParseCreateIndex.
  ----------------------------------------------------------------------- }

function intckGetToken(z: PAnsiChar): i32;
var
  c: AnsiChar;
  iRet: i32;
begin
  c := z[0];
  iRet := 1;
  if (c = '''') or (c = '"') or (c = '`') then begin
    while z[iRet] <> #0 do begin
      if z[iRet] = c then begin
        Inc(iRet);
        if z[iRet] <> c then break;
      end;
      Inc(iRet);
    end;
  end
  else if c = '[' then begin
    while True do begin
      if z[iRet] = #0 then break;
      if z[iRet] = ']' then begin Inc(iRet); break; end;
      Inc(iRet);
    end;
  end
  else if ((c >= 'A') and (c <= 'Z')) or ((c >= 'a') and (c <= 'z')) then begin
    while ((z[iRet] >= 'A') and (z[iRet] <= 'Z'))
       or ((z[iRet] >= 'a') and (z[iRet] <= 'z')) do
      Inc(iRet);
  end;
  Result := iRet;
end;

function intckIsSpace(c: AnsiChar): Boolean; inline;
begin
  Result := (c = ' ') or (c = #9) or (c = #10) or (c = #13);
end;

{ Parse a CREATE INDEX text fragment (column expression iCol or WHERE clause).
  Mirrors intck.c:364..442. }
function intckParseCreateIndex(z: PAnsiChar; iCol: i32;
                               pnByte: PInteger): PAnsiChar;
var
  iOff:     i32;
  iThisCol: i32;
  iStart:   i32;
  nOpen:    i32;
  zRet:     PAnsiChar;
  nRet:     i32;
  iEndOfCol: i32;
  zToken:   PAnsiChar;
  nToken:   i32;
  iEnd:     i32;
  n:        i32;
begin
  iOff      := 0;
  iThisCol  := 0;
  iStart    := 0;
  zRet      := nil;
  nRet      := 0;
  iEndOfCol := 0;

  { Skip forward until the first "(" token. }
  while z[iOff] <> '(' do begin
    Inc(iOff, intckGetToken(@z[iOff]));
    if z[iOff] = #0 then begin Result := nil; Exit; end;
  end;

  nOpen  := 1;
  Inc(iOff);
  iStart := iOff;
  while z[iOff] <> #0 do begin
    zToken := @z[iOff];
    nToken := 0;

    if nOpen = 1 then begin
      if (z[iOff] = ',') or (z[iOff] = ')') then begin
        if iCol = iThisCol then begin
          if iEndOfCol <> 0 then iEnd := iEndOfCol else iEnd := iOff;
          nRet := iEnd - iStart;
          zRet := @z[iStart];
          break;
        end;
        iStart := iOff + 1;
        while intckIsSpace(z[iStart]) do Inc(iStart);
        Inc(iThisCol);
      end;
      if z[iOff] = ')' then break;
    end;
    if z[iOff] = '(' then Inc(nOpen);
    if z[iOff] = ')' then Dec(nOpen);
    nToken := intckGetToken(zToken);

    if ((nToken = 3) and (sqlite3_strnicmp(zToken, 'ASC', nToken) = 0))
       or ((nToken = 4) and (sqlite3_strnicmp(zToken, 'DESC', nToken) = 0)) then
      iEndOfCol := iOff
    else if not intckIsSpace(zToken[0]) then
      iEndOfCol := 0;

    Inc(iOff, nToken);
  end;

  { Look for trailing WHERE clause (iCol<0 path). }
  while (zRet = nil) and (z[iOff] <> #0) do begin
    n := intckGetToken(@z[iOff]);
    if (n = 5) and (sqlite3_strnicmp(@z[iOff], 'where', 5) = 0) then begin
      zRet := @z[iOff + 5];
      nRet := i32(strLenZ(zRet));
    end;
    Inc(iOff, n);
  end;

  { Trim whitespace. }
  if zRet <> nil then begin
    while intckIsSpace(zRet[0]) do begin
      Dec(nRet);
      Inc(zRet);
    end;
    while (nRet > 0) and intckIsSpace(zRet[nRet-1]) do Dec(nRet);
  end;

  pnByte^ := nRet;
  Result := zRet;
end;

{ SQL function wrapper: parse_create_index(<sql>, <icol>). }
procedure intckParseCreateIndexFunc(pCtx: Psqlite3_context;
  nVal: i32; apVal: PPsqlite3_value); cdecl;
var
  pVals: ^Psqlite3_value;
  zSql, zRes: PAnsiChar;
  idx, nRes: i32;
begin
  pVals := Pointer(apVal);
  zSql  := PAnsiChar(sqlite3_value_text(pVals^));
  Inc(pVals);
  idx   := sqlite3_value_int(pVals^);
  zRes := nil;
  nRes := 0;
  if zSql <> nil then
    zRes := intckParseCreateIndex(zSql, idx, @nRes);
  sqlite3_result_text(pCtx, zRes, nRes, SQLITE_TRANSIENT);
end;

{ -----------------------------------------------------------------------
  Helpers for building the per-object check SQL.
  ----------------------------------------------------------------------- }

function intckGetAutoIndex(p: PIntck): i32;
var
  bRet:  i32;
  pStmt: PVdbe;
begin
  bRet := 0;
  pStmt := intckPrepare(p, 'PRAGMA automatic_index');
  if intckStep(p, pStmt) = SQLITE_ROW then
    bRet := sqlite3_column_int(pStmt, 0);
  intckFinalize(p, pStmt);
  Result := bRet;
end;

function intckIsIndex(p: PIntck; zObj: PAnsiChar): i32;
var
  bRet:  i32;
  pStmt: PVdbe;
begin
  bRet := 0;
  pStmt := intckPrepareFmt(p,
    'SELECT 1 FROM %Q.sqlite_schema WHERE name=%Q AND type=''index''',
    [p^.zDb, zObj]);
  if (p^.rc = SQLITE_OK) and (sqlite3_step(pStmt) = SQLITE_ROW) then
    bRet := 1;
  intckFinalize(p, pStmt);
  Result := bRet;
end;

const
  zCommonCte: PAnsiChar =
    ', without_rowid(b) AS (' +
    '  SELECT EXISTS (' +
    '    SELECT 1 FROM tabname, pragma_index_list(tab, db) AS l' +
    '      WHERE origin=''pk'' ' +
    '      AND NOT EXISTS (SELECT 1 FROM sqlite_schema WHERE name=l.name)' +
    '  )' +
    ')' +
    ', idx_cols(idx_name, idx_ispk, col_name, col_expr, col_alias) AS (' +
    '  SELECT l.name, (l.origin==''pk'' AND w.b), i.name, COALESCE((' +
    '    SELECT parse_create_index(sql, i.seqno) FROM ' +
    '    sqlite_schema WHERE name = l.name' +
    '  ), format(''"%w"'', i.name) || '' COLLATE '' || quote(i.coll)),' +
    '  ''c'' || row_number() OVER ()' +
    '  FROM ' +
    '      tabname t,' +
    '      without_rowid w,' +
    '      pragma_index_list(t.tab, t.db) l,' +
    '      pragma_index_xinfo(l.name) i' +
    '      WHERE i.key' +
    '  UNION ALL' +
    '  SELECT '''', 1, ''_rowid_'', ''_rowid_'', ''r1'' FROM without_rowid WHERE b=0' +
    ')' +
    ', tabpk(db, tab, idx, o_pk, i_pk, q_pk, eq_pk, ps_pk, pk_pk, n_pk) AS (' +
    '    WITH pkfields(f, a) AS (' +
    '      SELECT i.col_name, i.col_alias FROM idx_cols i WHERE i.idx_ispk' +
    '    )' +
    '    SELECT t.db, t.tab, t.idx, ' +
    '           group_concat(a, '', ''), ' +
    '           group_concat(''i.''||quote(f), '', ''), ' +
    '           group_concat(''quote(o.''||a||'')'', '' || '''','''' || ''),  ' +
    '           format(''(%s)==(%s)'',' +
    '               group_concat(''o.''||a, '', ''), ' +
    '               group_concat(format(''"%w"'', f), '', '')' +
    '           ),' +
    '           group_concat(''%s'', '',''),' +
    '           group_concat(''quote(''||a||'')'', '', ''),  ' +
    '           count(*)' +
    '    FROM tabname t, pkfields' +
    ')' +
    ', idx(name, match_expr, partial, partial_alias, idx_ps, idx_idx) AS (' +
    '  SELECT idx_name,' +
    '    format(''(%s,%s) IS (%s,%s)'', ' +
    '           group_concat(i.col_expr, '', ''), i_pk,' +
    '           group_concat(''o.''||i.col_alias, '', ''), o_pk' +
    '    ), ' +
    '    parse_create_index(' +
    '        (SELECT sql FROM sqlite_schema WHERE name=idx_name), -1' +
    '    ),' +
    '    ''cond'' || row_number() OVER ()' +
    '    , group_concat(''%s'', '','')' +
    '    , group_concat(''quote(''||i.col_alias||'')'', '', '')' +
    '  FROM tabpk t, ' +
    '       without_rowid w,' +
    '       idx_cols i' +
    '  WHERE i.idx_ispk==0 ' +
    '  GROUP BY idx_name' +
    ')' +
    ', wrapper_with(s) AS (' +
    '  SELECT ''intck_wrapper AS (' + #10 + '  SELECT' + #10 + '    '' || (' +
    '      WITH f(a, b) AS (' +
    '        SELECT col_expr, col_alias FROM idx_cols' +
    '          UNION ALL ' +
    '        SELECT partial, partial_alias FROM idx WHERE partial IS NOT NULL' +
    '      )' +
    '      SELECT group_concat(format(''%s AS %s'', a, b), '','#10+'    '') FROM f' +
    '    )' +
    '    || format(''' + #10 + '  FROM %Q.%Q '', t.db, t.tab)' +
    '    || CASE WHEN t.idx IS NULL THEN ' +
    '        ''NOT INDEXED''' +
    '       ELSE' +
    '        format(''INDEXED BY %Q%s'', t.idx, '' WHERE ''||i.partial)' +
    '       END' +
    '    || '''#10+')''' +
    '    FROM tabname t LEFT JOIN idx i ON (i.name=t.idx)' +
    ')';

{ Build the SQL statement that validates one object. }
function intckCheckObjectSql(p: PIntck; zObj, zPrev: PAnsiChar;
                             pnKeyVal: PInteger): PAnsiChar;
var
  zRet:      PAnsiChar;
  pStmt:     PVdbe;
  bAutoIndex: i32;
  bIsIndex:  i32;
  zPrevArg:  PAnsiChar;
begin
  zRet  := nil;
  bAutoIndex := intckGetAutoIndex(p);
  if bAutoIndex <> 0 then intckExec(p, 'PRAGMA automatic_index = 0');

  bIsIndex := intckIsIndex(p, zObj);
  if bIsIndex <> 0 then begin
    if zPrev <> nil then zPrevArg := zPrev else zPrevArg := 'VALUES('''')';
    pStmt := intckPrepareFmt(p,
      'WITH tabname(db, tab, idx) AS (' +
      '  SELECT %Q, (SELECT tbl_name FROM %Q.sqlite_schema WHERE name=%Q), %Q ' +
      ')' +
      ', whereclause(w_c) AS (%s)' +
      '%s' +
      ', case_statement(c) AS (' +
      '  SELECT ' +
      '    ''CASE WHEN ('' || group_concat(col_alias, '', '') || '', 1) IS ('#10+'        '' ' +
      '    || ''      SELECT '' || group_concat(col_expr, '', '') || '', 1 FROM ''' +
      '    || format(''%%Q.%%Q NOT INDEXED WHERE %%s'#10+''', t.db, t.tab, p.eq_pk)' +
      '    || ''    )' + #10 + '  THEN NULL' + #10 + '    ''' +
      '    || ''ELSE format(''''surplus entry (''' +
      '    ||   group_concat(''%%s'', '','') || '','' || p.ps_pk' +
      '    || '') in index '' || t.idx || '''''', '' ' +
      '    ||   group_concat(''quote(''||i.col_alias||'')'', '', '') || '', '' || p.pk_pk' +
      '    || '')''' +
      '    || '''#10+'  END AS error_message''' +
      '  FROM tabname t, tabpk p, idx_cols i WHERE i.idx_name=t.idx' +
      ')' +
      ', thiskey(k, n) AS (' +
      '    SELECT group_concat(i.col_alias, '', '') || '', '' || p.o_pk, ' +
      '           count(*) + p.n_pk ' +
      '    FROM tabpk p, idx_cols i WHERE i.idx_name=p.idx' +
      ')' +
      ', main_select(m, n) AS (' +
      '  SELECT format(' +
      '      ''WITH %%s' + #10 + ''' ||' +
      '      '', idx_checker AS (' + #10 + ''' ||' +
      '      ''  SELECT %%s,' + #10 + ''' ||' +
      '      ''  %%s' + #10 + ''' || ' +
      '      ''  FROM intck_wrapper AS o' + #10 + ''' ||' +
      '      '')' + #10 + ''',' +
      '      ww.s, c, t.k' +
      '  ), t.n' +
      '  FROM case_statement, wrapper_with ww, thiskey t' +
      ')' +
      'SELECT m || ' +
      '    group_concat(''SELECT * FROM idx_checker '' || w_c, '' UNION ALL ''), n' +
      ' FROM ' +
      'main_select, whereclause ',
      [p^.zDb, p^.zDb, zObj, zObj, zPrevArg, zCommonCte]);
  end else begin
    pStmt := intckPrepareFmt(p,
      'WITH tabname(db, tab, idx, prev) AS (SELECT %Q, %Q, NULL, %Q)' +
      '%s' +
      ', expr(e, p) AS (' +
      '  SELECT format(''CASE WHEN EXISTS ' + #10 +
      '    (SELECT 1 FROM %%Q.%%Q AS i INDEXED BY %%Q WHERE %%s%%s)' + #10 +
      '    THEN NULL' + #10 +
      '    ELSE format(''''entry (%%s,%%s) missing from index %%s'''', %%s, %%s)' + #10 +
      '  END' + #10 + '''' +
      '    , t.db, t.tab, i.name, i.match_expr, '' AND ('' || partial || '')'',' +
      '      i.idx_ps, t.ps_pk, i.name, i.idx_idx, t.pk_pk),' +
      '    CASE WHEN partial IS NULL THEN NULL ELSE i.partial_alias END' +
      '  FROM tabpk t, idx i' +
      ')' +
      ', numbered(ii, cond, e) AS (' +
      '  SELECT 0, ''n.ii=0'', ''NULL''' +
      '    UNION ALL ' +
      '  SELECT row_number() OVER (),' +
      '      ''(n.ii=''||row_number() OVER ()||COALESCE('' AND ''||p||'')'', '')''), e' +
      '  FROM expr' +
      ')' +
      ', counter_with(w) AS (' +
      '    SELECT ''WITH intck_counter(ii) AS (' + #10 + '  '' || ' +
      '       group_concat(''SELECT ''||ii, '' UNION ALL' + #10 + '  '') ' +
      '    || ''' + #10 + ')'' FROM numbered' +
      ')' +
      ', case_statement(c) AS (' +
      '    SELECT ''CASE '' || ' +
      '    group_concat(format(''' + #10 + '  WHEN %%s THEN (%%s)'', cond, e), '''') ||' +
      '    '''#10+'END AS error_message''' +
      '    FROM numbered' +
      ')' +
      ', thiskey(k, n) AS (' +
      '    SELECT o_pk || '', ii'', n_pk+1 FROM tabpk' +
      ')' +
      ', whereclause(w_c) AS (' +
      '    SELECT CASE WHEN prev!='''' THEN ' +
      '    '''#10+'WHERE ('' || o_pk ||'', n.ii) > '' || prev' +
      '    ELSE ''''' +
      '    END' +
      '    FROM tabpk, tabname' +
      ')' +
      ', main_select(m, n) AS (' +
      '  SELECT format(' +
      '      ''%%s, %%s' + #10 + 'SELECT %%s,' + #10 + '%%s' + #10 +
      'FROM intck_wrapper AS o, intck_counter AS n%%s' + #10 + 'ORDER BY %%s'', ' +
      '      w, ww.s, c, thiskey.k, whereclause.w_c, t.o_pk' +
      '  ), thiskey.n' +
      '  FROM case_statement, tabpk t, counter_with, ' +
      '       wrapper_with ww, thiskey, whereclause' +
      ')' +
      'SELECT m, n FROM main_select',
      [p^.zDb, zObj, zPrev, zCommonCte]);
  end;

  while (p^.rc = SQLITE_OK) and (sqlite3_step(pStmt) = SQLITE_ROW) do begin
    if zRet <> nil then sqlite3_free(zRet);
    zRet := intckMprintf(p, '%s',
      [PAnsiChar(sqlite3_column_text(pStmt, 0))]);
    if pnKeyVal <> nil then
      pnKeyVal^ := sqlite3_column_int(pStmt, 1);
  end;
  intckFinalize(p, pStmt);

  if bAutoIndex <> 0 then intckExec(p, 'PRAGMA automatic_index = 1');
  Result := zRet;
end;

{ -----------------------------------------------------------------------
  Public API
  ----------------------------------------------------------------------- }

function sqlite3_intck_open(db: PTsqlite3; zDbArg: PAnsiChar;
                            ppOut: PPIntck): i32;
var
  pNew: PIntck;
  rc:   i32;
  zDb:  PAnsiChar;
  nDb:  i32;
  pAlloc: Pointer;
  pTrail: PAnsiChar;
begin
  rc := SQLITE_OK;
  if zDbArg <> nil then zDb := zDbArg else zDb := 'main';
  nDb := i32(strLenZ(zDb));
  pAlloc := sqlite3Malloc(i32(SizeOf(TIntck)) + nDb + 1);
  pNew := PIntck(pAlloc);
  if pNew = nil then begin
    rc := SQLITE_NOMEM;
  end else begin
    FillChar(pNew^, SizeOf(TIntck), 0);
    pNew^.db := db;
    pTrail := PAnsiChar(pNew) + SizeOf(TIntck);
    pNew^.zDb := pTrail;
    Move(zDb^, pTrail^, nDb + 1);
    rc := sqlite3_create_function(db, 'parse_create_index',
      2, SQLITE_UTF8, nil, @intckParseCreateIndexFunc, nil, nil);
    if rc <> SQLITE_OK then begin
      sqlite3_intck_close(pNew);
      pNew := nil;
    end;
  end;

  ppOut^ := pNew;
  Result := rc;
end;

procedure sqlite3_intck_close(p: PIntck);
begin
  if p = nil then Exit;
  if p^.pCheck <> nil then sqlite3_finalize(p^.pCheck);
  if p^.db <> nil then
    sqlite3_create_function(p^.db, 'parse_create_index', 1, SQLITE_UTF8,
      nil, nil, nil, nil);
  if p^.zObj <> nil then sqlite3_free(p^.zObj);
  if p^.zKey <> nil then sqlite3_free(p^.zKey);
  if p^.zTestSql <> nil then sqlite3_free(p^.zTestSql);
  if p^.zErr <> nil then sqlite3_free(p^.zErr);
  if p^.zMessage <> nil then sqlite3_free(p^.zMessage);
  sqlite3_free(p);
end;

function sqlite3_intck_step(p: PIntck): i32;
var zSql: PAnsiChar;
begin
  if p^.rc = SQLITE_OK then begin
    if p^.zMessage <> nil then begin
      sqlite3_free(p^.zMessage);
      p^.zMessage := nil;
    end;

    if p^.bCorruptSchema <> 0 then begin
      p^.rc := SQLITE_DONE;
    end else if p^.pCheck = nil then begin
      intckFindObject(p);
      if p^.rc = SQLITE_OK then begin
        if p^.zObj <> nil then begin
          zSql := intckCheckObjectSql(p, p^.zObj, p^.zKey, @p^.nKeyVal);
          p^.pCheck := intckPrepare(p, zSql);
          if zSql <> nil then sqlite3_free(zSql);
          if p^.zKey <> nil then sqlite3_free(p^.zKey);
          p^.zKey := nil;
        end else begin
          p^.rc := SQLITE_DONE;
        end;
      end else if p^.rc = SQLITE_CORRUPT then begin
        p^.rc := SQLITE_OK;
        p^.zMessage := intckMprintf(p, '%s',
          [PAnsiChar('corruption found while reading database schema')]);
        p^.bCorruptSchema := 1;
      end;
    end;

    if p^.pCheck <> nil then begin
      if sqlite3_step(p^.pCheck) = SQLITE_ROW then begin
        { Normal case, do nothing. }
      end else begin
        intckFinalize(p, p^.pCheck);
        p^.pCheck := nil;
        p^.nKeyVal := 0;
        if p^.rc = SQLITE_CORRUPT then begin
          p^.rc := SQLITE_OK;
          p^.zMessage := intckMprintf(p,
            'corruption found while scanning database object %s', [p^.zObj]);
        end;
      end;
    end;
  end;
  Result := p^.rc;
end;

function sqlite3_intck_message(p: PIntck): PAnsiChar;
begin
  if p^.zMessage <> nil then begin
    Result := p^.zMessage;
    Exit;
  end;
  if p^.pCheck <> nil then begin
    Result := PAnsiChar(sqlite3_column_text(p^.pCheck, 0));
    Exit;
  end;
  Result := nil;
end;

function sqlite3_intck_error(p: PIntck; pzErr: PPAnsiChar): i32;
begin
  if pzErr <> nil then pzErr^ := p^.zErr;
  if p^.rc = SQLITE_DONE then Result := SQLITE_OK
                          else Result := p^.rc;
end;

function sqlite3_intck_unlock(p: PIntck): i32;
begin
  if (p^.rc = SQLITE_OK) and (p^.pCheck <> nil) then begin
    intckSaveKey(p);
    intckFinalize(p, p^.pCheck);
    p^.pCheck := nil;
  end;
  Result := p^.rc;
end;

function sqlite3_intck_test_sql(p: PIntck; zObj: PAnsiChar): PAnsiChar;
begin
  if p^.zTestSql <> nil then sqlite3_free(p^.zTestSql);
  p^.zTestSql := nil;
  if zObj <> nil then begin
    p^.zTestSql := intckCheckObjectSql(p, zObj, nil, nil);
  end else if p^.zObj <> nil then begin
    p^.zTestSql := intckCheckObjectSql(p, p^.zObj, p^.zKey, nil);
  end;
  Result := p^.zTestSql;
end;

end.
