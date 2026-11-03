unit test_mbCli;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry, fpjson, jsonparser, mbRunner, mbCli;

type
  TCliTest = class(TTestCase)
  private
    FOpts: TCliOptions;
    FOut, FErr: TStringList;
    function Parse(const AArgs: array of string; out AError: string): Boolean;
    function RunCli(const AArgs: array of string): Integer;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestParseRun;
    procedure TestParseBarePathIsCollection;
    procedure TestParseErrors;
    procedure TestHelpAndVersion;
    procedure TestList;
    procedure TestRunText;
    procedure TestRunJson;
    procedure TestRunNotFound;
    procedure TestRunAmbiguous;
    procedure TestRunBadFiles;
    procedure TestRunTransportFailure;
    procedure TestRunNoTransport;
    procedure TestRunEnvAndVarPrecedence;
    procedure TestImportWarningsFilteredToRequest;
    procedure TestParseHookFlags;
    procedure TestListVerboseMarkers;
    procedure TestRunWithHookJson;
    procedure TestRunWithHookText;
    procedure TestRunHookBeforeFails;
    procedure TestRunHookGarbage;
    procedure TestRunHookAfterFails;
    procedure TestRunHookErrorJson;
  end;

implementation

const
  Nested = 'samples/collections/upstream-nested-folders.collection.json';
  Twitter = 'samples/collections/twitter-api-v2.collection.json';
  TwitterEnv = 'samples/collections/twitter-api-v2.environment.json';
  Canonical = 'samples/collections/upstream-collection-v2.collection.json';
  CliColl = 'tests/fixtures/cli/cli.collection.json';
  CliEnv = 'tests/fixtures/cli/cli.environment.json';

function FakeBin(const AName: string): string;
begin
  Result := IncludeTrailingPathDelimiter(GetCurrentDir) + 'tests' + PathDelim + 'fixtures' +
    PathDelim + 'fakebin' + PathDelim + AName;
end;

procedure TCliTest.SetUp;
begin
  FOpts.Vars := TStringList.Create;
  FOut := TStringList.Create;
  FErr := TStringList.Create;
  CurlPathOverride := FakeBin('fakehttp');
  WgetPathOverride := '/nonexistent/wget';
end;

procedure TCliTest.TearDown;
begin
  CurlPathOverride := '';
  WgetPathOverride := '';
  FErr.Free;
  FOut.Free;
  FOpts.Vars.Free;
end;

function TCliTest.Parse(const AArgs: array of string; out AError: string): Boolean;
var
  L: TStringList;
  I: Integer;
begin
  L := TStringList.Create;
  try
    for I := 0 to High(AArgs) do L.Add(AArgs[I]);
    FOpts.Vars.Clear;
    Result := ParseCliArgs(L, FOpts, AError);
  finally
    L.Free;
  end;
end;

function TCliTest.RunCli(const AArgs: array of string): Integer;
var
  Err: string;
begin
  Err := '';
  AssertTrue('parse: ' + Err, Parse(AArgs, Err));
  FOut.Clear;
  FErr.Clear;
  Result := RunCliWith(FOpts, FOut, FErr);
end;

procedure TCliTest.TestParseRun;
var
  Err: string;
begin
  AssertTrue(Parse(['--run', 'Pay/send', '--collection', 'c.json', '--env', 'e.json',
    '--var', 'a=1', '--var', 'b=x=y', '--json', '--timeout', '5', '--no-follow', '--insecure', '--verbose'], Err));
  AssertTrue(FOpts.Mode = cmRun);
  AssertEquals('Pay/send', FOpts.RequestName);
  AssertEquals('c.json', FOpts.CollectionFile);
  AssertEquals('e.json', FOpts.EnvFile);
  AssertEquals(2, FOpts.Vars.Count);
  AssertEquals('b=x=y', FOpts.Vars[1]);
  AssertTrue(FOpts.Json);
  AssertEquals(5, FOpts.TimeoutSec);
  AssertFalse(FOpts.Follow);
  AssertTrue(FOpts.Insecure);
  AssertTrue(FOpts.Verbose);
  // Defaults
  AssertTrue(Parse(['--run', 'x', '--collection', 'c.json'], Err));
  AssertEquals(-1, FOpts.TimeoutSec);
  AssertTrue(FOpts.Follow);
  AssertFalse(FOpts.Json);
end;

procedure TCliTest.TestParseBarePathIsCollection;
var
  Err: string;
begin
  AssertTrue(Parse(['--list', 'c.json'], Err));
  AssertTrue(FOpts.Mode = cmList);
  AssertEquals('c.json', FOpts.CollectionFile);
  AssertTrue(Parse(['c.json'], Err));
  AssertTrue('bare path alone is GUI mode, no CLI mode', FOpts.Mode = cmNone);
end;

procedure TCliTest.TestParseErrors;
var
  Err: string;
begin
  AssertFalse(Parse(['--run'], Err));
  AssertEquals('--run needs a value', Err);
  AssertFalse(Parse(['--run', 'x'], Err));
  AssertEquals('--collection <file> is required', Err);
  AssertFalse(Parse(['--list'], Err));
  AssertFalse(Parse(['--run', 'x', '--list', '--collection', 'c'], Err));
  AssertFalse(Parse(['--run', 'x', '--collection', 'c', '--var', 'novalue'], Err));
  AssertFalse(Parse(['--run', 'x', '--collection', 'c', '--var', '=v'], Err));
  AssertFalse(Parse(['--run', 'x', '--collection', 'c', '--timeout', 'soon'], Err));
  AssertFalse(Parse(['--run', 'x', '--collection', 'c', '--timeout', '-3'], Err));
  AssertFalse(Parse(['--bogus'], Err));
  AssertEquals('unknown option --bogus', Err);
  AssertFalse(Parse(['--run', 'x', '--collection', 'c', 'extra'], Err));
  AssertEquals('unexpected argument extra', Err);
end;

procedure TCliTest.TestHelpAndVersion;
begin
  AssertEquals(ExitOk, RunCli(['--help']));
  AssertTrue(Pos('Usage:', FOut.Text) > 0);
  AssertTrue('exit codes documented', Pos('Exit codes', FOut.Text) > 0);
  AssertEquals(ExitOk, RunCli(['--version']));
  AssertEquals('mailBoy ' + MailBoyVersion, FOut[0]);
end;

procedure TCliTest.TestList;
begin
  AssertEquals(ExitOk, RunCli(['--list', '--collection', Nested]));
  AssertEquals(6, FOut.Count);
  AssertEquals('F1/F1.R1', FOut[0]);
  AssertEquals('F2/F2.F3/F2.F3.R1', FOut[3]);
  AssertEquals('R1', FOut[5]);
  AssertEquals(0, FErr.Count);
end;

procedure TCliTest.TestRunText;
begin
  AssertEquals(ExitOk, RunCli(['--run', 'F1/F1.R1', '--collection', Nested]));
  AssertEquals('HTTP/1.1 200 OK', FOut[0]);
  AssertEquals(1, Pos('# ', FOut[1]));
  AssertTrue('timing line names the transport', Pos('fakehttp', FOut[1]) > 0);
  AssertEquals('', FOut[2]);
  AssertEquals('Content-Type: application/json', FOut[3]);
  AssertEquals('', FOut[6]);
  AssertEquals('{"status":200,"echo":"https://upstream-echo.com/get"}', FOut[7]);
  AssertEquals(8, FOut.Count);
  // Scripts are kept, not warned about, so a clean request has no warnings.
  AssertEquals(0, FErr.Count);
end;

procedure TCliTest.TestRunJson;
var
  D: TJSONData;
  O: TJSONObject;
begin
  AssertEquals(ExitOk, RunCli(['--run', 'F1/F1.R1', '--collection', Nested, '--json']));
  AssertEquals('warnings go into the JSON, not stderr', 0, FErr.Count);
  D := GetJSON(FOut.Text);
  try
    AssertTrue(D.JSONType = jtObject);
    O := TJSONObject(D);
    AssertEquals('F1/F1.R1', O.Get('request', ''));
    AssertEquals('ok', O.Get('outcome', ''));
    AssertEquals('GET', O.Get('method', ''));
    AssertEquals('https://upstream-echo.com/get', O.Get('url', ''));
    AssertEquals(200, O.Get('status', 0));
    AssertEquals('OK', O.Get('statusText', ''));
    AssertEquals('1.1', O.Get('httpVersion', ''));
    AssertTrue(O.Get('elapsedMs', -1) >= 0);
    AssertEquals(53, O.Get('size', 0));
    AssertEquals('application/json', TJSONObject(O.Find('headers')).Get('Content-Type', ''));
    AssertEquals('{"status":200,"echo":"https://upstream-echo.com/get"}', O.Get('body', ''));
    AssertEquals(0, TJSONArray(O.Find('warnings')).Count);
    AssertEquals(0, TJSONArray(O.Find('intermediateStatuses')).Count);
  finally
    D.Free;
  end;
end;

procedure TCliTest.TestRunNotFound;
begin
  AssertEquals(ExitNotFound, RunCli(['--run', 'nope', '--collection', Nested]));
  AssertEquals(0, FOut.Count);
  AssertEquals('request not found: nope', FErr[0]);
end;

procedure TCliTest.TestRunAmbiguous;
begin
  AssertEquals(ExitNotFound, RunCli(['--run', 'dup', '--collection', CliColl]));
  AssertTrue(Pos('ambiguous', FErr[0]) > 0);
  AssertEquals(3, FErr.Count);
  AssertEquals('  Payments/dup', FErr[1]);
  AssertEquals('  Refunds/dup', FErr[2]);
  AssertEquals('path form resolves it', ExitOk, RunCli(['--run', 'Refunds/dup', '--collection', CliColl]));
  AssertEquals('HTTP/1.1 500 Internal Server Error', FOut[0]);
  AssertEquals(ExitNotFound, RunCli(['--run', '201', '--collection', Canonical]));
end;

procedure TCliTest.TestRunBadFiles;
begin
  AssertEquals(ExitFile, RunCli(['--run', 'x', '--collection', 'missing.json']));
  AssertEquals(1, Pos('collection: File not found', FErr[0]));
  AssertEquals(ExitFile, RunCli(['--run', 'x', '--collection', TwitterEnv]));
  AssertTrue(Pos('environment file, not a collection', FErr[0]) > 0);
  AssertEquals(ExitFile, RunCli(['--run', 'R1', '--collection', Nested, '--env', Nested]));
  AssertEquals(1, Pos('environment: ', FErr[0]));
  AssertEquals(ExitFile, RunCli(['--run', 'x', '--collection', 'README.md']));
end;

procedure TCliTest.TestRunTransportFailure;
begin
  // The fake curl fails for URLs containing "fail".
  AssertEquals(ExitTransport, RunCli(['--run', 'ping', '--collection', CliColl, '--var', 'host=fail.test']));
  AssertEquals(0, FOut.Count);
  AssertTrue(Pos('Failed to connect', FErr.Text) > 0);
  AssertEquals(ExitTransport, RunCli(['--run', 'ping', '--collection', CliColl, '--var', 'host=fail.test', '--json']));
  AssertTrue('json carries the outcome', Pos('"outcome" : "transport-error"', FOut.Text) > 0);
end;

procedure TCliTest.TestRunNoTransport;
begin
  CurlPathOverride := '/nonexistent/curl';
  AssertEquals(ExitNoTransport, RunCli(['--run', 'F1/F1.R1', '--collection', Nested]));
  AssertTrue(Pos('neither curl nor wget', FErr.Text) > 0);
end;

procedure TCliTest.TestRunEnvAndVarPrecedence;

  function ArgsHeader: string;
  var
    D: TJSONData;
  begin
    D := GetJSON(FOut.Text);
    try
      Result := TJSONObject(TJSONObject(D).Find('headers')).Get('X-Args', '');
    finally
      D.Free;
    end;
  end;

begin
  // Collection variables alone.
  AssertEquals(ExitOk, RunCli(['--run', 'ping', '--collection', CliColl, '--json']));
  AssertTrue(ArgsHeader, Pos('|Authorization: Bearer COLLTOKEN|https://coll.test/status/200', ArgsHeader) > 0);
  // Environment overrides the collection.
  AssertEquals(ExitOk, RunCli(['--run', 'ping', '--collection', CliColl, '--env', CliEnv, '--json']));
  AssertTrue(ArgsHeader, Pos('|Authorization: Bearer ENVTOKEN|https://env.test/status/200', ArgsHeader) > 0);
  // --var overrides both, and an unrelated variable in the body is reported.
  AssertEquals(ExitOk, RunCli(['--run', 'Payments/send', '--collection', CliColl, '--env', CliEnv,
    '--var', 'host=var.test', '--json']));
  AssertTrue(ArgsHeader, Pos('|--data-binary|{"amount": {{amount}}}|https://var.test/status/201', ArgsHeader) > 0);
  AssertTrue(FOut.Text, Pos('unresolved variable {{amount}}', FOut.Text) > 0);
  AssertEquals(ExitOk, RunCli(['--run', 'Payments/send', '--collection', CliColl, '--var', 'amount=5', '--json']));
  AssertTrue(ArgsHeader, Pos('|--data-binary|{"amount": 5}|', ArgsHeader) > 0);
end;

procedure TCliTest.TestImportWarningsFilteredToRequest;
var
  I: Integer;
begin
  AssertEquals(ExitOk, RunCli(['--run', 'Tweet Lookup/Single Tweet', '--collection', Twitter]));
  // Twitter has dozens of import warnings; only Collection, the "Tweet Lookup"
  // folder and this request's own may appear, plus the path variable warning.
  for I := 0 to FErr.Count - 1 do
    AssertTrue(FErr[I],
      (Pos('warning: import: Collection', FErr[I]) = 1) or
      (Pos('warning: import: Folder "Tweet Lookup"', FErr[I]) = 1) or
      (Pos('warning: import: Request "Single Tweet"', FErr[I]) = 1) or
      (Pos('warning: path variable', FErr[I]) = 1));
  AssertTrue('some but few', (FErr.Count >= 1) and (FErr.Count <= 5));
end;

function HookFix(const AName: string): string;
begin
  Result := 'tests/fixtures/hooks/' + AName;
end;

procedure TCliTest.TestParseHookFlags;
var
  Err: string;
begin
  AssertTrue(Parse(['--run', 'x', '--collection', 'c', '--hook', '/h/sign.py', '--hook-timeout', '7'], Err));
  AssertEquals('/h/sign.py', FOpts.HookCommand);
  AssertEquals(7, FOpts.HookTimeoutSec);
  AssertTrue(Parse(['--run', 'x', '--collection', 'c'], Err));
  AssertEquals('', FOpts.HookCommand);
  AssertEquals(-1, FOpts.HookTimeoutSec);
  AssertFalse(Parse(['--run', 'x', '--collection', 'c', '--hook'], Err));
  AssertFalse(Parse(['--run', 'x', '--collection', 'c', '--hook-timeout', '0'], Err));
  AssertFalse(Parse(['--run', 'x', '--collection', 'c', '--hook-timeout', 'soon'], Err));
end;

procedure TCliTest.TestListVerboseMarkers;
begin
  AssertEquals(ExitOk, RunCli(['--list', '--collection', 'samples/collections/newman-v1-format.collection.json', '--verbose']));
  AssertEquals('A simple GET request [test]', FOut[0]);
  AssertEquals(ExitOk, RunCli(['--list', '--collection', CliColl, '--verbose']));
  AssertEquals('ping [test]', FOut[0]);
  AssertEquals('Payments/send', FOut[1]);
  AssertEquals(ExitOk, RunCli(['--list', '--collection', CliColl]));
  AssertEquals('ping', FOut[0]);
end;

procedure TCliTest.TestRunWithHookJson;
var
  D: TJSONData;
  O: TJSONObject;
begin
  AssertEquals(ExitOk, RunCli(['--run', 'ping', '--collection', CliColl, '--env', CliEnv,
    '--hook', HookFix('add_header.sh'), '--json']));
  AssertEquals(0, FErr.Count);
  D := GetJSON(FOut.Text);
  try
    O := TJSONObject(D);
    AssertEquals('ok', O.Get('outcome', ''));
    AssertTrue('hook header reached curl',
      Pos('|x-acme-signature: sig-1|', TJSONObject(O.Find('headers')).Get('X-Args', '')) > 0);
    AssertEquals(2, TJSONArray(O.Find('console')).Count);
    AssertEquals('signed it', TJSONArray(O.Find('console'))[0].AsString);
    AssertEquals(2, TJSONArray(O.Find('tests')).Count);
    AssertFalse(TJSONObject(TJSONArray(O.Find('tests'))[1]).Get('passed', True));
    AssertEquals('no token', TJSONObject(TJSONArray(O.Find('tests'))[1]).Get('error', ''));
    AssertTrue(O.Get('hookMs', -1) >= 0);
    AssertTrue('hookError null', O.Find('hookError').IsNull);
  finally
    D.Free;
  end;
end;

procedure TCliTest.TestRunWithHookText;
begin
  AssertEquals(ExitOk, RunCli(['--run', 'ping', '--collection', CliColl, '--hook', HookFix('add_header.sh')]));
  AssertEquals('HTTP/1.1 200 OK', FOut[0]);
  AssertEquals(4, FErr.Count);
  AssertEquals('hook: signed it', FErr[0]);
  AssertEquals('hook: after ran', FErr[1]);
  AssertEquals('hook: PASS status is 200', FErr[2]);
  AssertEquals('hook: FAIL has token: no token', FErr[3]);
end;

procedure TCliTest.TestRunHookBeforeFails;
begin
  AssertEquals(ExitHook, RunCli(['--run', 'ping', '--collection', CliColl, '--hook', HookFix('fail.sh')]));
  AssertEquals('nothing sent, nothing printed', 0, FOut.Count);
  AssertEquals('hook error, before "ping"', FErr[0]);
  AssertEquals(1, Pos('command: ', FErr[1]));
  AssertTrue(FErr[1], Pos('exit 1', FErr[1]) > 0);
  AssertEquals('error: hook exited with code 1', FErr[2]);
  AssertEquals('stderr:', FErr[3]);
  AssertEquals('  Traceback: boom', FErr[4]);
  AssertEquals('    key missing', FErr[5]);   // the script's own two spaces plus the report indent
  AssertEquals('request as it stood: GET https://coll.test/status/200, 0 header(s)', FErr[6]);
end;

procedure TCliTest.TestRunHookGarbage;
begin
  AssertEquals(ExitHook, RunCli(['--run', 'ping', '--collection', CliColl, '--hook', HookFix('garbage.sh')]));
  AssertTrue(FErr.Text, Pos('not valid JSON', FErr.Text) > 0);
  AssertTrue(FErr.Text, Pos('stdout was:'#10'  debug: starting', FErr.Text) > 0);
end;

procedure TCliTest.TestRunHookAfterFails;
begin
  AssertEquals(ExitHook, RunCli(['--run', 'ping', '--collection', CliColl, '--hook', HookFix('after_fails.sh')]));
  AssertEquals('response still delivered', 'HTTP/1.1 200 OK', FOut[0]);
  AssertEquals('hook error, after "ping"', FErr[0]);
  AssertTrue(FErr.Text, Pos('after phase exploded', FErr.Text) > 0);
end;

procedure TCliTest.TestRunHookErrorJson;
var
  D: TJSONData;
  E: TJSONObject;
begin
  AssertEquals(ExitHook, RunCli(['--run', 'ping', '--collection', CliColl, '--hook', HookFix('error_obj.sh'), '--json']));
  D := GetJSON(FOut.Text);
  try
    AssertEquals('hook-error', TJSONObject(D).Get('outcome', ''));
    E := TJSONObject(TJSONObject(D).Find('hookError'));
    AssertEquals('before', E.Get('phase', ''));
    AssertEquals('refusing to sign', E.Get('message', ''));
    AssertEquals('KEY_ID is empty', E.Get('detail', ''));
    AssertEquals(0, E.Get('exitCode', -1));
    AssertEquals('checked key', TJSONArray(TJSONObject(D).Find('console'))[0].AsString);
  finally
    D.Free;
  end;
end;

initialization
  RegisterTest(TCliTest);

end.
