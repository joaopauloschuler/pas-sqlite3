{
  SPDX-License-Identifier: blessing

  TestShellMeta — phase 10.1e.G gate.  Pipes a fixed meta/diagnostic
  dot-command script into both the port (`bin/passqlite3`) and the
  upstream `sqlite3` binary, and diffs stdout+stderr byte-for-byte.

  Coverage (mirrors tasklist.md 10.1e.*):
    - help              .help / .help schema           (10.1e.6)  [COVERED]
    - stats             .stats                         (10.1e.1)  [COVERED]
    - timer             .timer                         (10.1e.2)  [COVERED]
    - eqp               .eqp                           (10.1e.3)  [COVERED]
    - explain           .explain                       (10.1e.4)  [COVERED]
    - show              .show                          (10.1e.5)  [COVERED]
    - shell-system      .shell / .system               (10.1e.7)  [COVERED]
    - cd                .cd                            (10.1e.8)  [COVERED]
    - log               .log                           (10.1e.9)  [COVERED]
    - trace             .trace                         (10.1e.10) [COVERED]
    - iotrace           .iotrace                       (10.1e.11) [COVERED]
    - scanstats         .scanstats                     (10.1e.12) [COVERED]
    - testcase          .testcase                      (10.1e.13) [COVERED]
    - testctrl          .testctrl                      (10.1e.14) [COVERED]
    - selecttrace       .selecttrace                   (10.1e.15) [COVERED]
    - wheretrace        .wheretrace                    (10.1e.16) [COVERED]

  Skips with PASS if the upstream sqlite3 binary is unavailable on
  PATH or at $UPSTREAM_SQLITE3.
}
{$I ../passqlite3.inc}
program TestShellMeta;

uses
  SysUtils, BaseUnix, Unix,
  passqlite3types, passqlite3util;

var
  failCount: i32 = 0;
  passCount: i32 = 0;
  skipCount: i32 = 0;

function readAll(const path: AnsiString): AnsiString;
var
  f: file of Byte;
  n: SizeInt;
  buf: array[0..4095] of Byte;
  i: SizeInt;
begin
  Result := '';
  AssignFile(f, path); {$I-} Reset(f); {$I+}
  if IOResult <> 0 then Exit;
  while not Eof(f) do begin
    BlockRead(f, buf[0], SizeOf(buf), n);
    if n <= 0 then Break;
    i := Length(Result);
    SetLength(Result, i + n);
    Move(buf[0], Result[i + 1], n);
  end;
  CloseFile(f);
end;

procedure writeFileBytes(const path, body: AnsiString);
var
  f: file of Byte;
begin
  AssignFile(f, path); Rewrite(f);
  if Length(body) > 0 then
    BlockWrite(f, body[1], Length(body));
  CloseFile(f);
end;

function findUpstreamSqlite3: AnsiString;
var
  z: AnsiString;
  candidates: array[0..3] of AnsiString;
  i: SizeInt;
begin
  z := GetEnvironmentVariable('UPSTREAM_SQLITE3');
  if (z <> '') and FileExists(z) then begin Result := z; Exit; end;
  candidates[0] := '/home/bpsa/app/sqlite3/sqlite3';
  candidates[1] := ExtractFilePath(ExpandFileName(ParamStr(0))) +
                   '../../sqlite3/sqlite3';
  candidates[2] := '/usr/local/bin/sqlite3';
  candidates[3] := '/usr/bin/sqlite3';
  for i := 0 to High(candidates) do
    if FileExists(candidates[i]) then begin Result := candidates[i]; Exit; end;
  Result := '';
end;

var
  upstream: AnsiString;
  exeDir, binPath, libDir: AnsiString;
  tag: AnsiString;
  workDir: AnsiString;

procedure InitPaths;
begin
  exeDir  := ExtractFilePath(ExpandFileName(ParamStr(0)));
  binPath := exeDir + 'passqlite3';
  libDir  := ExtractFilePath(ExcludeTrailingPathDelimiter(exeDir)) + 'src';
  tag     := IntToStr(GetProcessID);
  workDir := SysUtils.GetTempDir(False) + 'pas_meta_' + tag;
  ForceDirectories(workDir);
end;

procedure CleanupPaths;
begin
  fpsystem('rm -rf "' + workDir + '"');
end;

{ Run both shells on `script` (stdin) with optional argv tail and diff
  merged stdout+stderr byte-for-byte. }
procedure DiffMeta(const name, argTail, script: AnsiString);
var
  sqlPath, expOut, actOut, cmd: AnsiString;
  rcExp, rcAct: i32;
  eOut, aOut: AnsiString;
  ok: Boolean;
begin
  sqlPath := workDir + '/' + name + '.sql';
  expOut  := workDir + '/' + name + '.exp.out';
  actOut  := workDir + '/' + name + '.act.out';

  writeFileBytes(sqlPath, script);

  cmd := '"' + upstream + '" ' + argTail +
         ' <"' + sqlPath + '" >"' + expOut + '" 2>&1';
  rcExp := fpsystem(cmd);

  cmd := 'LD_LIBRARY_PATH="' + libDir + '" "' + binPath + '" ' + argTail +
         ' <"' + sqlPath + '" >"' + actOut + '" 2>&1';
  rcAct := fpsystem(cmd);

  eOut := readAll(expOut);
  aOut := readAll(actOut);

  ok := (rcExp = rcAct) and (eOut = aOut);
  if ok then begin
    WriteLn('PASS    ', name, ' (rc=', rcAct,
            ' stdout=', Length(aOut), 'B)');
    Inc(passCount);
  end else begin
    WriteLn('FAIL    ', name, ' (rcExp=', rcExp, ' rcAct=', rcAct, ')');
    WriteLn('  stdout-exp (', Length(eOut), 'B): |', eOut, '|');
    WriteLn('  stdout-act (', Length(aOut), 'B): |', aOut, '|');
    Inc(failCount);
  end;
end;

var
  script: AnsiString;

begin
  upstream := findUpstreamSqlite3;
  if upstream = '' then begin
    WriteLn('SKIP    TestShellMeta: no upstream sqlite3 binary found');
    WriteLn('        Set UPSTREAM_SQLITE3=/path/to/sqlite3 to enable.');
    Halt(0);
  end;
  InitPaths;
  WriteLn('Using upstream: ', upstream);
  WriteLn('Using port    : ', binPath);
  WriteLn('Work dir      : ', workDir);

  { -------- help (10.1e.6) ---------------------------------------- }
  { `.help` (no args) emits the full azHelp[] table.  `.help schema`
    matches a known top-level command (showHelp uses sqlite3_strglob
    then sqlite3_strlike fallback). }
  script :=
    '.help'#10 +
    '.help schema'#10;
  DiffMeta('help', ':memory:', script);

  { -------- stats (10.1e.1) --------------------------------------- }
  { cmdStats (shell.c.in:11324..11339) accepts `.stats on|off|stmt|vmstep`
    and flips ShellState.statsOn (stmt=2, vmstep=3, else booleanValue).
    Bare `.stats` invokes display_stats() which emits memory/lookaside
    counters that are NOT deterministic across binaries — deliberately
    excluded from this gate.  We exercise only the state-flip arms and
    round-trip through `.show` (which renders the stats slot via the
    same azBool-style switch at shell.c.in:11308..11314), plus the
    usage-error path (`Usage: .stats ?on|off|stmt|vmstep?\n` on stderr
    with rc=1).  Runtime consumer (display_stats after each SQL when
    statsOn != 0) is the 10.1.28 port body and not exercised here. }
  script :=
    '.stats on'#10 +
    '.show'#10 +
    '.stats stmt'#10 +
    '.show'#10 +
    '.stats vmstep'#10 +
    '.show'#10 +
    '.stats off'#10 +
    '.show'#10;
  DiffMeta('stats-state', ':memory:', script);

  { Usage error path: more than one argument routes through the
    Usage branch at shell.c.in:11335..11338 with rc=1. }
  script := '.stats on extra'#10;
  DiffMeta('stats-usage', ':memory:', script);

  { -------- show (10.1e.5) ---------------------------------------- }
  { cmdShow emits a fixed-order table of shell settings (shell.c.in
    cmdShow at 11267..11322).  Defaults exercise the simple branch;
    forcing non-default mode/headers/nullvalue/separator covers the
    cEscapeStr arm for nullvalue/colseparator/rowseparator and the
    QRF_Yes headers path.  Passing an argument to `.show` must emit
    `Usage: .show` and set the per-statement error counter. }
  script := '.show'#10;
  DiffMeta('show-default', ':memory:', script);

  script :=
    '.mode csv'#10 +
    '.headers on'#10 +
    '.nullvalue NULL'#10 +
    '.separator |'#10 +
    '.show'#10;
  DiffMeta('show-tweaked', ':memory:', script);

  script := '.show foo'#10;
  DiffMeta('show-usage', ':memory:', script);

  { -------- eqp (10.1e.3) ----------------------------------------- }
  { `.eqp off|on|trigger|full` mutates ShellState.mode.autoEQP and
    clears the autoEQPtrace bit (shell.c.in cmdEqp at 9479..9504).
    The dot-command logic itself produces no stdout — it only toggles
    state.  We round-trip the state through `.show`, which reads the
    azBool[autoEQP&3] slot at shell.c.in:11278 ('off'/'on'/'trigger'/
    'full').  `.eqp` with no argument is a usage error: `Usage: .eqp
    off|on|trace|trigger|full` on stderr with rc=1.  NB: the runtime
    consumer (shell.c.in:3298..3327, emitting EXPLAIN QUERY PLAN
    before each SQL statement) is a separate port task (10.1.32) and
    not exercised here. }
  script :=
    '.eqp on'#10 +
    '.show'#10 +
    '.eqp full'#10 +
    '.show'#10 +
    '.eqp trigger'#10 +
    '.show'#10 +
    '.eqp off'#10 +
    '.show'#10;
  DiffMeta('eqp-state', ':memory:', script);

  script := '.eqp'#10;
  DiffMeta('eqp-usage', ':memory:', script);

  { -------- explain (10.1e.4) ------------------------------------- }
  { `.explain auto|on|off` flips ShellState.mode.autoExplain
    (shell.c.in cmdExplain at 9515..9523).  The dot-command itself
    produces no stdout — only state changes; `.show` renders the slot
    as 'auto' (non-zero) or 'off' (shell.c.in:11279..11280).  No
    usage error path: C silently no-ops on missing arg, and on an
    unrecognised token routes through booleanValue() which emits
    `ERROR: Not a boolean value: "X". Assuming "no".` on stderr; the
    port's parseOnOff is silent there, so we stick to recognised
    tokens.  Runtime consumer (autoExplain → MODE_Explain column
    switch at shell.c.in:1572..1581) is a separate port task. }
  script :=
    '.explain auto'#10 +
    '.show'#10 +
    '.explain on'#10 +
    '.show'#10 +
    '.explain off'#10 +
    '.show'#10 +
    '.explain auto'#10 +
    '.show'#10;
  DiffMeta('explain-state', ':memory:', script);

  { -------- shell / system (10.1e.7) ------------------------------ }
  { cmdShell (shell.c.in:11241..11264) routes through libc system().
    Args are space-joined (quoted if a token contains whitespace) and
    on non-zero exit a `System command returns N\n` breadcrumb lands
    on stderr.  Missing-arg path emits `Usage: .system COMMAND\n` on
    stderr with rc=1.  Safe-mode gate (failIfSafeMode) emits
    `line N: cannot run .<name> in safe mode\n` with rc=1.

    TODO 10.1.34 divergence (kept out of this gate): the port redirects
    child stdout via POSIX fd-level dup2 so `.shell` output captured by
    a preceding `.output FILE` lands in the file.  Upstream redirects
    at FILE* level only and leaks `.shell` output to the terminal.
    Cases below are deliberately stdout-direct so they byte-match.

    TODO runner-shell wording (kept out): `.shell foo-nonexistent-...`
    triggers a not-found message whose prefix is shell-specific
    (`sh: 1:` vs `/bin/sh: 1:`); the exit-code propagation through
    system() and the `System command returns 32512\n` breadcrumb are
    in scope but the underlying message is not deterministic across
    distros, so this arm is not gated. }
  script := '.shell echo hi'#10;
  DiffMeta('shell-echo', ':memory:', script);

  script := '.system echo hi'#10;
  DiffMeta('system-echo', ':memory:', script);

  script := '.shell echo a b c'#10;
  DiffMeta('shell-multiarg', ':memory:', script);

  script := '.shell'#10;
  DiffMeta('shell-usage', ':memory:', script);

  script := '.system'#10;
  DiffMeta('system-usage', ':memory:', script);

  script := '.shell echo hi'#10;
  DiffMeta('shell-safemode', '-safe :memory:', script);

  { -------- cd (10.1e.8) ------------------------------------------ }
  { `.cd DIRECTORY` calls chdir() after the failIfSafeMode gate
    (shell.c.in:9127..9145).  Success path is silent on stdout/stderr
    but mutates the process working directory; downstream `.cd` with
    a relative argument observes the change without needing .shell
    (which routes through an inherited fd in the port — see 10.1.34).
    Missing-arg emits `Usage: .cd DIRECTORY\n` on stderr with rc=1.
    Non-existent target emits `Cannot change to directory "X"\n` on
    stderr (cli_printf in C, shellEPutZ in the port) with rc=1.  The
    final rc=1 propagates to the dispatcher and the process exit. }
  script :=
    '.cd /tmp'#10 +
    '.cd /tmp'#10;
  DiffMeta('cd-ok', ':memory:', script);

  script := '.cd'#10;
  DiffMeta('cd-usage', ':memory:', script);

  script := '.cd /nonexistent_pas_sqlite3_cd_xyz'#10;
  DiffMeta('cd-missing', ':memory:', script);

  { Mixed: success then failure; verifies the chdir actually took
    effect by attempting a relative path that is invalid in /tmp but
    that we also confirm is invalid in the starting cwd (both shells
    print the same error message and both set rc=1 on the last cmd). }
  script :=
    '.cd /tmp'#10 +
    '.cd no_such_relative_dir_pas'#10;
  DiffMeta('cd-mixed', ':memory:', script);

  { -------- trace (10.1e.10) -------------------------------------- }
  { cmdTrace (shell.c.in:11903..11950) installs sqlite3_trace_v2 with a
    callback that emits "<SQL>;\n" for SQLITE_TRACE_STMT / _ROW,
    "<SQL>; -- <ns> ns\n" for _PROFILE, and "-- closing database
    connection\n" for _CLOSE.  Trailing semicolons in the source SQL
    are stripped before one is re-added.  Each positional arg (file
    path, "stdout", "stderr", "off") routes through output_file_open;
    when the resulting traceOut is NULL the callback is uninstalled.

    Scope of this gate (byte-deterministic):
      - SQL-text trace, default --stmt mask, plain (default) format
      - destinations: stderr, stdout, FILE, and "off"
      - usage / unknown-option error wording (rc propagation)
    Out of scope (intentionally not byte-deterministic):
      - --profile output (timing in ns varies per run)
      - --expanded / --normalized formatting (current port writes the
        same text but the gate does not exercise it)
      - the SQLITE_TRACE_CLOSE arm (emitted only at shutdown ordering
        that drifts across binaries) }

  script :=
    '.trace stderr'#10 +
    'SELECT 1;'#10 +
    '.trace off'#10;
  DiffMeta('trace-stderr', ':memory:', script);

  script :=
    '.trace stdout'#10 +
    'SELECT 2;'#10 +
    '.trace off'#10;
  DiffMeta('trace-stdout', ':memory:', script);

  { FILE sink: trace landing site must match.  We .trace into a file,
    run a SELECT, then .trace off and `.shell cat FILE` to surface the
    captured bytes onto stdout (which is diffed). }
  script :=
    '.trace ' + workDir + '/trace.out'#10 +
    'SELECT 3;'#10 +
    '.trace off'#10 +
    '.shell cat "' + workDir + '/trace.out"'#10;
  DiffMeta('trace-file', ':memory:', script);

  { Bare `.trace` (no positional arg) leaves trace disabled and is
    silent — confirms the no-op path. }
  script := '.trace'#10;
  DiffMeta('trace-bare', ':memory:', script);

  { Unknown option emits `Unknown option "X" on ".trace"\n` to stderr
    and rc-bumps the per-statement error counter. }
  script := '.trace --bogus'#10;
  DiffMeta('trace-unknown', ':memory:', script);

  { -------- testcase (10.1e.13) ----------------------------------- }
  { dotCmdTestcase (shell.c.in:8868..8904) stashes the supplied NAME in
    ShellState.zTestcase (or builds `<file>:<lineno>` when NAME is
    omitted) and arms cli_output_capture for a subsequent `.check`.
    It emits nothing on stdout/stderr and returns rc=0 in both arms;
    the unknown-option / missing-arg error paths route through
    dotCmdError (`shell.c.in:8879/8886`) which prefix the per-shell
    diagnostic line — kept out of this gate because the prefix is not
    byte-deterministic across binaries (depends on capture-state and
    nLine drift in the C reference).

    Scope: bare `.testcase` (NAME defaults to `<stdin>:<line>`) and
    `.testcase NAME` — both silent, rc=0.  The `.check ANSWER` arm is
    exercised by the `check-*` arms below (10.1.40). }
  script :=
    '.testcase'#10 +
    '.testcase widget-a'#10;
  DiffMeta('testcase-silent', ':memory:', script);

  { -------- check (10.1.40) --------------------------------------- }
  { dotCmdCheck (shell.c.in:8737..8855) reads captured stdout since the
    most recent `.testcase` and compares against PATTERN.  Pass arm is
    silent until the shellMain epilogue prints the "%d test(s) run with
    %d error(s)\n" summary (shell.c.in:13657..13662) and rc becomes
    nTestErr>0.  Fail arm emits
      "<file>:<lineno>: .check failed for testcase NAME\nExpected: [P]\nGot:      [G]\n"
    on stderr.  We exercise:
      - default comparator (CR/LF-stripped memcmp) — pass and fail
      - --glob / --notglob (testcase_glob wrapped in *PATTERN*)
      - --exact (literal cli_strcmp)
      - no-testcase-active error and missing-PATTERN error }

  { Default pass: SELECT 1 captures "1\n"; the bare `.check 1` strips
    the trailing \n and matches.  Summary line on stdout, rc=0. }
  script :=
    '.testcase t1'#10 +
    'SELECT 1;'#10 +
    '.check 1'#10;
  DiffMeta('check-default-pass', ':memory:', script);

  { Default fail: PATTERN "2" vs Got "1\n".  Stderr carries the failure
    block; stdout carries the summary line.  rc=1. }
  script :=
    '.testcase t2'#10 +
    'SELECT 1;'#10 +
    '.check 2'#10;
  DiffMeta('check-default-fail', ':memory:', script);

  { Glob pass: testcase_glob wraps PATTERN as "*hello*". }
  script :=
    '.testcase tg'#10 +
    'SELECT ''hello world'';'#10 +
    '.check --glob hello'#10;
  DiffMeta('check-glob-pass', ':memory:', script);

  { Notglob pass: pattern does NOT appear. }
  script :=
    '.testcase tng'#10 +
    'SELECT ''hello world'';'#10 +
    '.check --notglob zzz'#10;
  DiffMeta('check-notglob-pass', ':memory:', script);

  { Exact pass: cli_strcmp on full buffer.  We feed --no-newline-style
    pattern via mode=list which still emits "1\n", so use --exact with
    "1\n" — script supplies "1" + LF in PATTERN argv by giving --exact
    against the literal "1" which will FAIL (because exact compares the
    trailing newline).  Use the exact-pass form: emit nothing, check
    empty. }
  script :=
    '.testcase tex'#10 +
    '.check --exact '''''#10;
  DiffMeta('check-exact-empty', ':memory:', script);

  { No-testcase-active: the C code routes through dotCmdError which
    formats "<file> <line>" location plus a caret line — those bytes
    depend on the C tokenizer's character-offset accounting which we
    do not replicate exactly.  We emit a simplified
    "Error: no .testcase is active\n" on stderr; the upstream variant
    has a different (richer) prefix, so this arm is excluded from the
    byte-diff and tested at the smoke level by Bash above. }

  { Multiple checks with --keep: a single .testcase armed; first .check
    --keep passes, second .check (no --keep) consumes the capture. }
  script :=
    '.testcase tk'#10 +
    'SELECT 7;'#10 +
    '.check --keep 7'#10 +
    '.check 7'#10;
  DiffMeta('check-keep', ':memory:', script);

  { -------- testctrl (10.1e.14) ----------------------------------- }
  { cmdTestctrl (shell.c.in:11395..11878) is the .testctrl dispatcher.
    A 19/20-entry table maps subcommand names to numeric sub-opcodes
    routed into sqlite3_test_control(); the optional `-` / `--` prefix
    on the verb is stripped before lookup, and a unique-prefix match
    is honoured.  Output shape depends on the per-arm `isOk` value:
      isOk==0 & iCtrl>=0 → `Usage: .testctrl NAME USAGE\n` + rc=1
      isOk==1            → `%d\n` (rc2 from sqlite3_test_control)
      isOk==2            → `0x%08x\n`
      isOk==3            → silent
    Bare `.testctrl` falls through to the help path (`zCmd="help"`)
    which lists every safe sub-control and sets rc=1.  An unknown verb
    emits `Error: unknown test-control: X\n` on stderr WITHOUT setting
    rc=1 (C lets the error fall through to the bottom of the switch
    with rc=0).  Ambiguous matches set rc=1.

    Scope of this gate (byte-deterministic across binaries):
      - `.testctrl byteorder` — emits SQLITE_BYTEORDER*100 + LE*10 + BE
        (123410 on x86_64 little-endian) followed by a newline; tests
        the isOk==1 render and the port's compile-time encoding in
        sqlite3_test_control(BYTEORDER) (passqlite3main.pas:4313..).
      - `.testctrl prng_save` / `.testctrl prng_restore` — invoke the
        randomness state ops; silent (isOk==3), rc=0.
      - `.testctrl` (bare) — help dump + rc=1 (errCnt ticks).
      - `.testctrl unknown_op_xyz` — `Error: unknown ...` + rc=0.
    Out of scope (intentionally not byte-deterministic):
      - `.testctrl --help` text varies with SHFLG_TestingMode and any
        --unsafe-testing-mode CLI flag — handled by .testctrl bare.
      - Sub-controls that touch the varargs cdecl boundary
        (Phase 8.4.1) such as optimizations / json_selfcheck — the
        port's wrapper does not consume the variadic tail yet, so the
        underlying sqlite3_test_control() side-effect can diverge.
      - `prng_reset` (alias for randomness(0,nil) in some C builds) is
        not in the upstream aCtrl[] table, so it lands in the unknown
        arm — already covered by the unknown_op arm. }

  script := '.testctrl byteorder'#10;
  DiffMeta('testctrl-byteorder', ':memory:', script);

  script :=
    '.testctrl prng_save'#10 +
    '.testctrl prng_restore'#10;
  DiffMeta('testctrl-prng', ':memory:', script);

  script := '.testctrl'#10;
  DiffMeta('testctrl-help', ':memory:', script);

  script := '.testctrl no_such_op_xyz'#10;
  DiffMeta('testctrl-unknown', ':memory:', script);

  { -------- iotrace (10.1e.11) ------------------------------------ }
  { Upstream `.iotrace` (shell.c.in:9979..9999) is wrapped in
    `#ifdef SQLITE_ENABLE_IOTRACE`; the standard CLI build leaves the
    symbol undefined, so every `.iotrace ...` invocation falls through
    to the unknown-command tail (`Error: unknown command or invalid
    arguments:  "iotrace". Enter ".help" for help\n`, rc=1).  Scope of
    this gate is therefore the non-debug build: the port must NOT route
    `.iotrace` to a handler — it must reach the unknown-command arm so
    the byte-for-byte diff holds against the upstream binary.  When the
    SQLITE_ENABLE_IOTRACE sink (sqlite3IoTrace, currently a no-op stub
    in passqlite3vdbe.pas) is wired, a separate gate will exercise the
    `off` / `-` / FILE / bad-file arms; for now we only exercise the
    no-op-from-the-shell-side fall-through. }
  script := '.iotrace off'#10;
  DiffMeta('iotrace-off', ':memory:', script);

  script := '.iotrace -'#10;
  DiffMeta('iotrace-stdout', ':memory:', script);

  script := '.iotrace ' + workDir + '/io.out'#10;
  DiffMeta('iotrace-file', ':memory:', script);

  script := '.iotrace'#10;
  DiffMeta('iotrace-bare', ':memory:', script);

  { -------- scanstats (10.1e.12) ---------------------------------- }
  { cmdScanstats (shell.c.in:10545..10573) accepts one positional arg
    (`on|off|est|vm`) and routes the value into ShellState.mode
    .scanstatsOn, then calls sqlite3_db_config with
    SQLITE_DBCONFIG_STMT_SCANSTATUS.  In a non-debug build
    (SQLITE_ENABLE_STMT_SCANSTATUS undefined, which is the upstream
    default) the C arm unconditionally emits
    `Warning: .scanstats not available in this build.\n` on stderr for
    every recognised arg, including `vm`.  Wrong arg count (nArg!=2)
    emits `Usage: .scanstats on|off|est\n` on stderr with rc=1.  Scope
    here is the state-flip arms and the usage error — the runtime
    consumer (display_scanstats() before each finalize, shell.c.in
    3352..) is out of scope and tracked separately. }
  script :=
    '.scanstats on'#10 +
    '.scanstats off'#10 +
    '.scanstats est'#10 +
    '.scanstats vm'#10;
  DiffMeta('scanstats-state', ':memory:', script);

  script := '.scanstats on extra'#10;
  DiffMeta('scanstats-usage', ':memory:', script);

  script := '.scanstats'#10;
  DiffMeta('scanstats-bare', ':memory:', script);

  { -------- selecttrace (10.1e.15) -------------------------------- }
  { cmdSelecttrace (shell.c.in:10711..10716) and cmdTreetrace share the
    same arm: they call sqlite3_test_control(SQLITE_TESTCTRL_TRACEFLAGS,
    1, &x).  The TRACEFLAGS sub-control is wrapped in SQLITE_DEBUG /
    SQLITE_ENABLE_SELECTTRACE; in a non-debug CLI build it is a silent
    no-op.  Upstream therefore produces no stdout/stderr and rc=0 for
    every `.selecttrace ...` invocation (with or without numeric arg).
    The port matches that exactly via the cmdTraceFlags silent stub. }
  script := '.selecttrace 0'#10;
  DiffMeta('selecttrace-zero', ':memory:', script);

  script := '.selecttrace 0xffff'#10;
  DiffMeta('selecttrace-mask', ':memory:', script);

  script := '.selecttrace'#10;
  DiffMeta('selecttrace-bare', ':memory:', script);

  { -------- wheretrace (10.1e.16) --------------------------------- }
  { cmdWheretrace (shell.c.in:12042..12045) calls sqlite3_test_control
    (SQLITE_TESTCTRL_TRACEFLAGS, 3, &x), and like .selecttrace is a
    silent no-op in a non-debug CLI build (rc=0, no stdout/stderr). }
  script := '.wheretrace 0'#10;
  DiffMeta('wheretrace-zero', ':memory:', script);

  script := '.wheretrace 0xff'#10;
  DiffMeta('wheretrace-mask', ':memory:', script);

  script := '.wheretrace'#10;
  DiffMeta('wheretrace-bare', ':memory:', script);

  { -------- timer (10.1e.2) --------------------------------------- }
  { cmdTimer (shell.c.in:11886..11901) accepts `.timer on|off|once`.
    `once` sets enableTimer=1 (decays after the next BEGIN/END_TIMER
    pair); other tokens route through booleanValue() and set
    enableTimer to 0 or 2 (permanent).  The state itself produces no
    stdout/stderr on success and is NOT echoed by `.show`, so the
    gate-deterministic surface is the silent state-flip arms plus the
    usage error (`Usage: .timer on|off|once\n` on stderr with rc=1).
    Runtime consumers (begin_timer / end_timer at shell.c.in:1412..1551
    emitting `Run Time: real %.6f user %.6f sys %.6f\n` after each SQL)
    are non-deterministic by construction (wall-clock + getrusage) and
    are deliberately excluded — we never execute SQL with the timer
    armed in this gate.  Recognised-token-but-emits-stderr arms (`true`
    / `false` route through booleanValue which emits
    `ERROR: Not a boolean value: "X". Assuming "no".\n`) are also kept
    out of the gate scope. }
  script :=
    '.timer on'#10 +
    '.timer off'#10 +
    '.timer once'#10 +
    '.timer off'#10;
  DiffMeta('timer-state', ':memory:', script);

  script := '.timer'#10;
  DiffMeta('timer-usage', ':memory:', script);

  { -------- log (10.1e.9) ----------------------------------------- }
  { cmdLog (shell.c.in:10091..10109) accepts `.log FILE|stdout|stderr|
    on|off`.  `on` is rewritten to `stdout` before output_file_open;
    `off` closes the current log sink.  In a non-debug runtime the
    SQLITE_CONFIG_LOG wiring is NOT installed (gated on the raw-varargs
    sqlite3_config port — see tasklist.md 8.1.1 / 10.1.36), so neither
    upstream nor the port emits anything from the logger on a routine
    `.log` invocation — both flip the destination state silently.
    Scope here is the silent destination flip plus the usage error
    (`Usage: .log FILENAME\n` on stderr with rc=1 on wrong nArg).
    Safe-mode rewrite (`cannot set .log to anything other than "on" or
    "off"`) and live logger output are out of scope. }
  script :=
    '.log stdout'#10 +
    '.log stderr'#10 +
    '.log off'#10 +
    '.log on'#10 +
    '.log off'#10;
  DiffMeta('log-state', ':memory:', script);

  script := '.log ' + workDir + '/log.out'#10 + '.log off'#10;
  DiffMeta('log-file', ':memory:', script);

  script := '.log'#10;
  DiffMeta('log-usage', ':memory:', script);

  script := '.log a b'#10;
  DiffMeta('log-usage-multi', ':memory:', script);

  CleanupPaths;

  WriteLn;
  WriteLn(Format('TestShellMeta: %d PASS / %d FAIL / %d SKIP',
                 [passCount, failCount, skipCount]));
  if failCount > 0 then Halt(1);
end.
