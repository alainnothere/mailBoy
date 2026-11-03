unit test_mbExecutor;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry, mbModel, mbVariables, mbRequestBuilder,
  mbRunner, mbResponse, mbExecutor;

type
  TExecutorTest = class(TTestCase)
  private
    FExec: TRequestExecutor;
    FReq: TRequest;
    FScope: TVariableScope;
    FHookLog: TStringList;
    procedure OnBefore(AResolved: TResolvedRequest; AScope: TVariableScope);
    procedure OnAfter(AResolved: TResolvedRequest; AResponse: TResponse; AScope: TVariableScope);
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestOkResponseWithArgsPassedThrough;
    procedure TestHttpErrorStatusIsStillOk;
    procedure TestTransportError;
    procedure TestTimeout;
    procedure TestNoTransport;
    procedure TestLaunchFailed;
    procedure TestHooksRunAndCanChangeThings;
    procedure TestWarningsCollected;
    procedure TestUnresolvedUrlIsNotSent;
    procedure TestHookCanResolveUrl;
    procedure TestWgetToCurlOutput;
    procedure TestNilRequest;
    procedure TestNoHookConfigured;
    procedure TestHookBeforeAddsHeaderToArgv;
    procedure TestHookAfterSetsVariableForNextRequest;
    procedure TestHookBeforeFailureAbortsSend;
    procedure TestHookAfterFailureStillDeliversResponse;
    procedure TestHookTimeout;
    procedure TestHookRewritesRequest;
  end;

implementation

function FakeBin(const AName: string): string;
begin
  Result := IncludeTrailingPathDelimiter(GetCurrentDir) + 'tests' + PathDelim + 'fixtures' +
    PathDelim + 'fakebin' + PathDelim + AName;
end;

procedure TExecutorTest.SetUp;
begin
  CurlPathOverride := FakeBin('fakehttp');
  WgetPathOverride := FakeBin('fakewget');
  FExec := TRequestExecutor.Create;
  FReq := TRequest.Create;
  FReq.Method := 'GET';
  FReq.Url.Raw := 'https://{{host}}/status/200';
  FScope := TVariableScope.Create;
  FScope.SetVariable('host', 'example.test');
  FHookLog := TStringList.Create;
end;

procedure TExecutorTest.TearDown;
begin
  CurlPathOverride := '';
  WgetPathOverride := '';
  FHookLog.Free;
  FScope.Free;
  FReq.Free;
  FExec.Free;
end;

procedure TExecutorTest.OnBefore(AResolved: TResolvedRequest; AScope: TVariableScope);
begin
  FHookLog.Add('before:' + AResolved.Url);
  AResolved.Headers.Add('X-Hook', 'yes');
end;

procedure TExecutorTest.OnAfter(AResolved: TResolvedRequest; AResponse: TResponse; AScope: TVariableScope);
begin
  FHookLog.Add('after:' + IntToStr(AResponse.StatusCode));
  AScope.SetVariable('captured', AResponse.HeaderValue('X-Token'));
end;

procedure TExecutorTest.TestOkResponseWithArgsPassedThrough;
var
  R: TExecuteResult;
begin
  R := FExec.Execute(FReq, FScope);
  try
    AssertTrue(OutcomeToString(R.Outcome), R.Succeeded);
    AssertTrue(R.Transport = trCurl);
    AssertEquals(FakeBin('fakehttp'), R.Executable);
    AssertEquals(200, R.Response.StatusCode);
    AssertEquals('OK', R.Response.StatusText);
    AssertEquals('application/json', R.Response.ContentType);
    AssertEquals('{"status":200,"echo":"https://example.test/status/200"}', R.Response.Body);
    AssertTrue('argv reached the process', Pos('|-X|GET|', R.Response.HeaderValue('X-Args')) > 0);
    AssertTrue('url resolved and last', Pos('|https://example.test/status/200', R.Response.HeaderValue('X-Args')) > 0);
    AssertEquals('https://example.test/status/200', R.Args[R.Args.Count - 1]);
    AssertTrue(R.Process.ElapsedMs >= 0);
    AssertEquals(0, R.Warnings.Count);
  finally
    R.Free;
  end;
end;

procedure TExecutorTest.TestHttpErrorStatusIsStillOk;
var
  R: TExecuteResult;
begin
  FReq.Url.Raw := 'https://h/status/500';
  R := FExec.Execute(FReq, nil);
  try
    AssertTrue(R.Outcome = eoOk);
    AssertEquals(500, R.Response.StatusCode);
    AssertFalse(R.Response.IsSuccess);
  finally
    R.Free;
  end;
end;

procedure TExecutorTest.TestTransportError;
var
  R: TExecuteResult;
begin
  FReq.Url.Raw := 'https://fail.test/';
  R := FExec.Execute(FReq, nil);
  try
    AssertTrue(R.Outcome = eoTransportError);
    AssertNull(R.Response);
    AssertEquals(7, R.Process.ExitCode);
    AssertEquals('curl: (7) Failed to connect to host', R.ErrorMessage);
  finally
    R.Free;
  end;
end;

procedure TExecutorTest.TestTimeout;
var
  R: TExecuteResult;
begin
  FReq.Url.Raw := 'https://timeout.test/';
  FExec.Options.KillAfterMs := 300;
  R := FExec.Execute(FReq, nil);
  try
    AssertTrue(OutcomeToString(R.Outcome), R.Outcome = eoTimeout);
    AssertTrue(R.Process.TimedOut);
    AssertTrue(R.Process.ElapsedMs < 3000);
    AssertNull(R.Response);
  finally
    R.Free;
  end;
end;

procedure TExecutorTest.TestNoTransport;
var
  R: TExecuteResult;
begin
  CurlPathOverride := '/nonexistent/curl';
  WgetPathOverride := '/nonexistent/wget';
  R := FExec.Execute(FReq, FScope);
  try
    AssertTrue(R.Outcome = eoNoTransport);
    AssertNull(R.Process);
    AssertNotNull('request still resolved for display', R.Resolved);
    AssertTrue(R.ErrorMessage <> '');
  finally
    R.Free;
  end;
end;

procedure TExecutorTest.TestLaunchFailed;
var
  R: TExecuteResult;
begin
  // Exists but is not executable: a plain text fixture.
  CurlPathOverride := IncludeTrailingPathDelimiter(GetCurrentDir) + 'README.md';
  R := FExec.Execute(FReq, FScope);
  try
    // Depending on the platform the exec failure surfaces either before the
    // fork (Started = False) or as a non-zero exit of the child. Both must end
    // as a failure with no response and a message.
    AssertTrue(OutcomeToString(R.Outcome), R.Outcome in [eoLaunchFailed, eoTransportError]);
    AssertNotNull(R.Process);
    AssertNull(R.Response);
    AssertFalse(R.Succeeded);
    AssertTrue(R.ErrorMessage <> '');
  finally
    R.Free;
  end;
end;

procedure TExecutorTest.TestHooksRunAndCanChangeThings;
var
  R: TExecuteResult;
begin
  FExec.BeforeSend := @OnBefore;
  FExec.AfterResponse := @OnAfter;
  R := FExec.Execute(FReq, FScope);
  try
    AssertTrue(R.Succeeded);
    AssertEquals(2, FHookLog.Count);
    AssertEquals('before:https://example.test/status/200', FHookLog[0]);
    AssertEquals('after:200', FHookLog[1]);
    AssertTrue('header added by hook was sent', Pos('|X-Hook: yes|', R.Response.HeaderValue('X-Args')) > 0);
    AssertEquals('tok-200', FScope.Resolve('{{captured}}'));
  finally
    R.Free;
  end;
  // A transport failure must not fire the after hook.
  FHookLog.Clear;
  FReq.Url.Raw := 'https://fail.test/';
  R := FExec.Execute(FReq, FScope);
  try
    AssertEquals(1, FHookLog.Count);
    AssertEquals(1, Pos('before:', FHookLog[0]));
  finally
    R.Free;
  end;
end;

procedure TExecutorTest.TestWarningsCollected;
var
  R: TExecuteResult;
begin
  FReq.Url.Raw := 'https://{{host}}/status/201';
  FReq.Headers.Add('X-Probe', '{{nowhere}} {{nowhere}} {{other}}');
  FReq.Auth.AuthType := atOther;
  FReq.Auth.RawType := 'oauth1';
  R := FExec.Execute(FReq, FScope);
  try
    AssertTrue(R.Succeeded);
    AssertEquals(201, R.Response.StatusCode);
    AssertEquals(3, R.Warnings.Count);
    AssertTrue(Pos('oauth1', R.Warnings[0]) > 0);
    AssertEquals('unresolved variable {{nowhere}}', R.Warnings[1]);
    AssertEquals('unresolved variable {{other}}', R.Warnings[2]);
  finally
    R.Free;
  end;
end;

procedure TExecutorTest.TestUnresolvedUrlIsNotSent;
var
  R: TExecuteResult;
begin
  FReq.Url.Raw := 'https://{{nowhere}}/x/{{nowhere}}/{{other}}';
  R := FExec.Execute(FReq, FScope);
  try
    AssertFalse(R.Succeeded);
    AssertTrue('outcome', R.Outcome = eoUnresolvedUrl);
    AssertEquals('unresolved-url', OutcomeToString(R.Outcome));
    AssertNull('nothing ran', R.Process);
    AssertNull('no argv built', R.Args);
    AssertTrue('names listed once each', Pos('{{nowhere}}, {{other}}', R.ErrorMessage) > 0);
    AssertTrue('says nothing was sent', Pos('Nothing was sent', R.ErrorMessage) > 0);
  finally
    R.Free;
  end;
end;

// A before hook that fills in the URL is still allowed to; the check runs after it.
procedure TExecutorTest.TestHookCanResolveUrl;
var
  R: TExecuteResult;
begin
  FReq.Url.Raw := 'https://{{nowhere}}/status/200';
  FExec.Hook.Command := FakeBin('..' + PathDelim + 'hooks' + PathDelim + 'rewrite.sh');
  R := FExec.Execute(FReq, FScope);
  try
    AssertTrue('outcome ' + OutcomeToString(R.Outcome) + ' ' + R.ErrorMessage, R.Outcome <> eoUnresolvedUrl);
  finally
    R.Free;
  end;
end;

procedure TExecutorTest.TestWgetToCurlOutput;
const
  Err = '--2026-11-03 10:00:00--  https://h/x'#10 +
        'Resolving h... 1.2.3.4'#10 +
        'HTTP request sent, awaiting response... '#10 +
        '  HTTP/1.1 301 Moved'#10 +
        '  Location: https://h/y'#10 +
        'Location: https://h/y [following]'#10 +
        '  HTTP/1.1 200 OK'#10 +
        '  Content-Type: text/plain'#10 +
        '  Content-Length: 5'#10 +
        'Length: 5 [text/plain]'#10 +
        'Saving to: STDOUT'#10;
var
  Raw: string;
  Resp: TResponse;
begin
  Raw := WgetToCurlOutput(Err, 'hello');
  Resp := ParseCurlOutput(Raw, 1);
  try
    AssertFalse(Resp.ParseErrorMessage, Resp.ParseError);
    AssertEquals(200, Resp.StatusCode);
    AssertEquals(1, Resp.RedirectCount);
    AssertEquals('text/plain', Resp.ContentType);
    AssertEquals('hello', Resp.Body);
  finally
    Resp.Free;
  end;
  AssertEquals('', WgetToCurlOutput('no headers here', 'body'));
end;

procedure TExecutorTest.TestNilRequest;
var
  R: TExecuteResult;
begin
  R := FExec.Execute(nil, nil);
  try
    AssertFalse(R.Succeeded);
    AssertNull(R.Resolved);
  finally
    R.Free;
  end;
end;

function HookPath(const AName: string): string;
begin
  Result := IncludeTrailingPathDelimiter(GetCurrentDir) + 'tests' + PathDelim + 'fixtures' +
    PathDelim + 'hooks' + PathDelim + AName;
end;

procedure TExecutorTest.TestNoHookConfigured;
var
  R: TExecuteResult;
begin
  R := FExec.Execute(FReq, FScope);
  try
    AssertTrue(R.Succeeded);
    AssertNull('no before hook result', R.HookBefore);
    AssertNull('no after hook result', R.HookAfter);
    AssertFalse(R.HookFailed);
    AssertEquals(0, R.HookMs);
  finally
    R.Free;
  end;
end;

procedure TExecutorTest.TestHookBeforeAddsHeaderToArgv;
var
  R: TExecuteResult;
  I: Integer;
  Found: Boolean;
begin
  FExec.Hook.Command := HookPath('add_header.sh');
  FExec.Context.CollectionFile := '/abs/c.json';
  R := FExec.Execute(FReq, FScope);
  try
    AssertTrue(OutcomeToString(R.Outcome) + ' ' + R.ErrorMessage, R.Succeeded);
    AssertNotNull(R.HookBefore);
    AssertTrue(R.HookBefore.Ok);
    Found := False;
    for I := 0 to R.Args.Count - 1 do
      if R.Args[I] = 'x-acme-signature: sig-1' then Found := True;
    AssertTrue('hook header is in the curl argv', Found);
    AssertTrue('and reached the process', Pos('|x-acme-signature: sig-1|', R.Response.HeaderValue('X-Args')) > 0);
    AssertNotNull(R.HookAfter);
    AssertTrue(R.HookAfter.Ok);
    AssertEquals(2, R.HookAfter.TestCount);
    AssertFalse(R.HookFailed);
    AssertTrue(R.HookMs >= 0);
  finally
    R.Free;
  end;
end;

procedure TExecutorTest.TestHookAfterSetsVariableForNextRequest;
var
  R: TExecuteResult;
begin
  FExec.Hook.Command := HookPath('add_header.sh');
  FScope.PushLayer('session', nil);
  R := FExec.Execute(FReq, FScope);
  try
    AssertTrue(R.Succeeded);
  finally
    R.Free;
  end;
  FReq.Url.Query.Add('t', '{{token}}');
  R := FExec.Execute(FReq, FScope);
  try
    AssertTrue(R.Succeeded);
    AssertEquals('https://example.test/status/200?t=tok123', R.Resolved.Url);
  finally
    R.Free;
  end;
end;

procedure TExecutorTest.TestHookBeforeFailureAbortsSend;
var
  R: TExecuteResult;
begin
  FExec.Hook.Command := HookPath('fail.sh');
  R := FExec.Execute(FReq, FScope);
  try
    AssertTrue(OutcomeToString(R.Outcome), R.Outcome = eoHookError);
    AssertNull('nothing was sent', R.Process);
    AssertNull(R.Response);
    AssertTrue(R.HookFailed);
    AssertEquals('hook error, before "' + FReq.Path + '": hook exited with code 1', R.ErrorMessage);
    AssertTrue('stderr kept', Pos('Traceback: boom', R.HookBefore.StdErr) = 1);
    AssertNull(R.HookAfter);
  finally
    R.Free;
  end;
end;

procedure TExecutorTest.TestHookAfterFailureStillDeliversResponse;
var
  R: TExecuteResult;
begin
  FExec.Hook.Command := HookPath('after_fails.sh');
  R := FExec.Execute(FReq, FScope);
  try
    AssertTrue('response delivered', R.Succeeded);
    AssertEquals(200, R.Response.StatusCode);
    AssertTrue(R.HookBefore.Ok);
    AssertFalse(R.HookAfter.Ok);
    AssertEquals(3, R.HookAfter.ExitCode);
    AssertTrue(R.HookFailed);
    AssertEquals('hook error, after "' + FReq.Path + '": hook exited with code 3', R.ErrorMessage);
    AssertEquals('after phase exploded'#10, R.HookAfter.StdErr);
  finally
    R.Free;
  end;
end;

procedure TExecutorTest.TestHookTimeout;
var
  R: TExecuteResult;
begin
  FExec.Hook.Command := HookPath('sleep.sh');
  FExec.Hook.TimeoutSec := 1;
  R := FExec.Execute(FReq, FScope);
  try
    AssertTrue(R.Outcome = eoHookError);
    AssertTrue(R.HookBefore.TimedOut);
    AssertTrue(Pos('killed after 1 s', R.ErrorMessage) > 0);
  finally
    R.Free;
  end;
end;

procedure TExecutorTest.TestHookRewritesRequest;
var
  R: TExecuteResult;
begin
  FExec.Hook.Command := HookPath('rewrite.sh');
  FReq.Headers.Add('X-Old', '1');
  R := FExec.Execute(FReq, FScope);
  try
    AssertTrue(OutcomeToString(R.Outcome) + ' ' + R.ErrorMessage, R.Succeeded);
    AssertEquals('PUT', R.Resolved.Method);
    AssertEquals('https://changed.test/x', R.Args[R.Args.Count - 1]);
    AssertEquals('headers cleared', 0, R.Resolved.Headers.Count);
    AssertTrue(Pos('|--data-binary|changed|', R.Response.HeaderValue('X-Args')) > 0);
    // environment layer missing -> session fallback warning; unknown scope warning
    AssertTrue(R.Warnings.Text, R.Warnings.Count >= 2);
    AssertEquals('1', FScope.Resolve('{{e}}'));
  finally
    R.Free;
  end;
end;

initialization
  RegisterTest(TExecutorTest);

end.
