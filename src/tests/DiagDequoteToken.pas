{ DiagDequoteToken — differential probe for sqlite3DequoteToken
  and sqlite3IsOverflow.  Compares the Pascal port against the C
  reference (csq_*) for each fixture. }
program DiagDequoteToken;

{$MODE OBJFPC}
{$H+}

uses
  passqlite3types, passqlite3util, passqlite3codegen;

type
  TFix = record
    z: PAnsiChar;
    n: u32;
  end;

var
  fixtures: array[0..7] of TFix = (
    (z: 'abc';      n: 3),       { no quotes — no-op }
    (z: '"abc"';    n: 5),       { strip dquote }
    (z: '''xy''';   n: 4),       { strip squote }
    (z: '`bt`';     n: 4),       { strip backtick }
    (z: '[id]';     n: 4),       { strip bracket }
    (z: '"a""b"';   n: 7),       { interior quotes — leave }
    (z: '"';        n: 1),       { n<2 — no-op }
    (z: '""';       n: 2)        { empty quoted — strip to empty }
  );

procedure RunDequote;
var
  i: i32;
  t: TToken;
  origZ: PAnsiChar;
  origN: u32;
begin
  WriteLn('=== sqlite3DequoteToken ===');
  for i := 0 to High(fixtures) do begin
    t.z := fixtures[i].z;
    t.n := fixtures[i].n;
    origZ := t.z;
    origN := t.n;
    sqlite3DequoteToken(@t);
    Write('  in="', origZ, '" n=', origN);
    Write(' -> n=', t.n, ' shifted=');
    if t.z = origZ then Write('0') else Write('1');
    WriteLn;
  end;
end;

procedure RunOverflow;
var
  inf, ninf, nan_, zero, normal, big: Double;
begin
  WriteLn('=== sqlite3IsOverflow ===');
  inf := 1.0 / 0.0;
  ninf := -1.0 / 0.0;
  nan_ := 0.0 / 0.0;
  zero := 0.0;
  normal := 3.14;
  big := 1.0e300;
  WriteLn('  +Inf  -> ', sqlite3IsOverflow(inf));
  WriteLn('  -Inf  -> ', sqlite3IsOverflow(ninf));
  WriteLn('  NaN   -> ', sqlite3IsOverflow(nan_));
  WriteLn('  0.0   -> ', sqlite3IsOverflow(zero));
  WriteLn('  3.14  -> ', sqlite3IsOverflow(normal));
  WriteLn('  1e300 -> ', sqlite3IsOverflow(big));
end;

begin
  RunDequote;
  RunOverflow;
end.
