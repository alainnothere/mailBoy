unit test_mbHook;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry, fpjson, jsonparser, base64,
  mbModel, mbVariables, mbRequestBuilder, mbResponse, mbHook;

type
  THookTestCase = class(TTestCase)
  private
    FReq: TRequest;
    FColl: TCollection;
    FScope: TVariableScope;
    FResolved: TResolvedRequest;
    FCtx: THookContext;
    function Hook(const AName: string): string;
    function Input(APhase: THookPhase; AResponse: TResponse): TJSONObject;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestInputBefore;
    procedure TestInputAfterWithTextBody;
    procedure TestInputAfterWithBinaryBody;
    procedure TestInputScriptsChain;
    procedure TestInputContext;
    procedure TestInputFormData;
    procedure TestParseEmptyIsNoop;
    procedure TestParseAllKeys;
    procedure TestParseErrors;
    procedure TestApplyHeaderMerge;
    procedure TestApplyReplacements;
    procedure TestApplyVariables;
    procedure TestIsValidUtf8;
    procedure TestRunBeforeAddsHeaders;
    procedure TestRunAfterSetsVariableAndTests;
    procedure TestRunFail;
    procedure TestRunGarbage;
    procedure TestRunErrorObject;
    procedure TestRunTimeout;
    procedure TestRunWrongProtocol;
    procedure TestRunBigStderr;
    procedure TestRunMissingCommand;
    procedure TestDisabledRunnerDoesNothing;
  end;

implementation

function THookTestCase.Hook(const AName: string): string;
begin
  Result := IncludeTrailingPathDelimiter(GetCurrentDir) + 'tests' + PathDelim + 'fixtures' +
    PathDelim + 'hooks' + PathDelim + AName;
end;

procedure THookTestCase.SetUp;
var
  F: TFolder;
begin
  FColl := TCollection.Create;
  FColl.Name := 'Coll';
  FColl.PreRequestScript := 'coll pre';
  F := FColl.AddFolder('Widgets');
  F.TestScript := 'folder test';
  FReq := F.AddRequest('Create widget');
  FReq.Method := 'POST';
  FReq.Url.Raw := 'https://api.example.test/v2/widgets/42';
  FReq.Headers.Add('Content-Type', 'application/json');
  FReq.Body.Mode := bmRaw;
  FReq.Body.Raw := '{"name":"x"}';
  FReq.PreRequestScript := 'req pre';
  FReq.TestScript := 'req test';
  FReq.Auth.AuthType := atBearer;
  FReq.Auth.Params.Add('token', 'T');
  FScope := TVariableScope.Create;
  FScope.PushLayer('collection', nil);
  FScope.SetVariableIn('collection', 'CLIENT_ID', 'abc');
  FScope.PushLayer('environment', nil);
  FScope.SetVariableIn('environment', 'baseUrl', 'https://api.example.test');
  FScope.PushLayer('session', nil);
  FScope.SetVariableIn('session', 'gone', 'x');
  FResolved := ResolveRequest(FReq, FScope);
  FCtx.CollectionFile := '/abs/c.json';
  FCtx.EnvironmentFile := '';
  FCtx.Proxy := '';
end;

procedure THookTestCase.TearDown;
begin
  FResolved.Free;
  FScope.Free;
  FColl.Free;
end;

function THookTestCase.Input(APhase: THookPhase; AResponse: TResponse): TJSONObject;
var
  D: TJSONData;
begin
  D := GetJSON(BuildHookInput(APhase, FResolved, AResponse, FScope, FReq, FCtx));
  AssertTrue('input is an object', D.JSONType = jtObject);
  Result := TJSONObject(D);
end;

procedure THookTestCase.TestInputBefore;
var
  O, R: TJSONObject;
begin
  O := Input(hpBefore, nil);
  try
    AssertEquals(1, O.Get('protocol', 0));
    AssertEquals('before', O.Get('phase', ''));
    AssertTrue('response null', O.Find('response').IsNull);
    R := TJSONObject(O.Find('request'));
    AssertEquals('Create widget', R.Get('name', ''));
    AssertEquals('Widgets/Create widget', R.Get('path', ''));
    AssertEquals('POST', R.Get('method', ''));
    AssertEquals('https://api.example.test/v2/widgets/42', R.Get('url', ''));
    AssertEquals(1, TJSONArray(R.Find('headers')).Count);
    AssertEquals('Content-Type', TJSONObject(TJSONArray(R.Find('headers'))[0]).Get('key', ''));
    AssertEquals('raw', TJSONObject(R.Find('body')).Get('mode', ''));
    AssertEquals('{"name":"x"}', TJSONObject(R.Find('body')).Get('raw', ''));
    AssertEquals('bearer', TJSONObject(R.Find('auth')).Get('type', ''));
    AssertEquals('T', TJSONObject(R.Find('auth')).Get('token', ''));
    AssertEquals('abc', TJSONObject(TJSONObject(O.Find('variables')).Find('collection')).Get('CLIENT_ID', ''));
    AssertEquals('https://api.example.test', TJSONObject(TJSONObject(O.Find('variables')).Find('environment')).Get('baseUrl', ''));
    AssertEquals('x', TJSONObject(TJSONObject(O.Find('variables')).Find('session')).Get('gone', ''));
  finally
    O.Free;
  end;
end;

procedure THookTestCase.TestInputAfterWithTextBody;
var
  Resp: TResponse;
  O, R: TJSONObject;
begin
  Resp := ParseCurlOutput('HTTP/1.1 201 Created'#13#10'Set-Cookie: a=1'#13#10'Set-Cookie: b=2'#13#10#13#10'{"id":7}', 42);
  O := Input(hpAfter, Resp);
  try
    AssertEquals('after', O.Get('phase', ''));
    R := TJSONObject(O.Find('response'));
    AssertEquals(201, R.Get('status', 0));
    AssertEquals('Created', R.Get('statusText', ''));
    AssertEquals(2, TJSONArray(R.Find('headers')).Count);
    AssertEquals('{"id":7}', R.Get('body', ''));
    AssertNull('no encoding for text', R.Find('bodyEncoding'));
    AssertEquals(42, R.Get('elapsedMs', 0));
  finally
    O.Free;
    Resp.Free;
  end;
end;

procedure THookTestCase.TestInputAfterWithBinaryBody;
var
  Resp: TResponse;
  O, R: TJSONObject;
begin
  Resp := ParseCurlOutput('HTTP/1.1 200 OK'#13#10#13#10'AB'#0#255'CD', 1);
  O := Input(hpAfter, Resp);
  try
    R := TJSONObject(O.Find('response'));
    AssertEquals('base64', R.Get('bodyEncoding', ''));
    AssertEquals('AB'#0#255'CD', DecodeStringBase64(R.Get('body', '')));
  finally
    O.Free;
    Resp.Free;
  end;
end;

procedure THookTestCase.TestInputScriptsChain;
var
  O: TJSONObject;
  Pre, Tst: TJSONArray;
begin
  O := Input(hpBefore, nil);
  try
    Pre := TJSONArray(TJSONObject(O.Find('scripts')).Find('prerequest'));
    Tst := TJSONArray(TJSONObject(O.Find('scripts')).Find('test'));
    AssertEquals(2, Pre.Count);
    AssertEquals('collection', TJSONObject(Pre[0]).Get('source', ''));
    AssertEquals('coll pre', TJSONObject(Pre[0]).Get('code', ''));
    AssertEquals('request "Create widget"', TJSONObject(Pre[1]).Get('source', ''));
    AssertEquals(2, Tst.Count);
    AssertEquals('folder "Widgets"', TJSONObject(Tst[0]).Get('source', ''));
    AssertEquals('req test', TJSONObject(Tst[1]).Get('code', ''));
  finally
    O.Free;
  end;
end;

procedure THookTestCase.TestInputContext;
var
  O, C: TJSONObject;
begin
  O := Input(hpBefore, nil);
  try
    C := TJSONObject(O.Find('context'));
    AssertEquals('/abs/c.json', C.Get('collection', ''));
    AssertTrue('environment null', C.Find('environment').IsNull);
    AssertTrue('proxy null', C.Find('proxy').IsNull);
  finally
    O.Free;
  end;
  FCtx.Proxy := 'http://proxy.test:3128';
  FCtx.EnvironmentFile := '/abs/e.json';
  O := Input(hpBefore, nil);
  try
    C := TJSONObject(O.Find('context'));
    AssertEquals('http://proxy.test:3128', C.Get('proxy', ''));
    AssertEquals('/abs/e.json', C.Get('environment', ''));
  finally
    O.Free;
  end;
end;

procedure THookTestCase.TestInputFormData;
var
  O, B: TJSONObject;
  KV: TKeyValue;
begin
  FResolved.BodyMode := bmFormData;
  FResolved.FormFields.Add('name', 'x');
  KV := FResolved.FormFields.Add('upload', '/tmp/f.bin');
  KV.IsFile := True;
  O := Input(hpBefore, nil);
  try
    B := TJSONObject(TJSONObject(O.Find('request')).Find('body'));
    AssertEquals('formdata', B.Get('mode', ''));
    AssertEquals(2, TJSONArray(B.Find('fields')).Count);
    AssertTrue(TJSONObject(TJSONArray(B.Find('fields'))[1]).Get('file', False));
  finally
    O.Free;
  end;
end;

procedure THookTestCase.TestParseEmptyIsNoop;
var
  R: THookResult;
begin
  R := THookResult.Create;
  try
    AssertTrue(ParseHookOutput('', R));
    AssertTrue(ParseHookOutput('   '#10, R));
    AssertTrue(ParseHookOutput('{}', R));
    AssertFalse(R.HasMethod); AssertFalse(R.HasUrl); AssertFalse(R.HasBody);
    AssertEquals(0, R.HeaderOpCount + R.VarOpCount + R.TestCount + R.Console.Count);
    AssertTrue('unknown keys ignored', ParseHookOutput('{"protocol":1,"bogus":{"a":1},"request":{"zzz":1}}', R));
  finally
    R.Free;
  end;
end;

procedure THookTestCase.TestParseAllKeys;
const
  Doc = '{"protocol":1,"request":{"method":"delete","url":"https://u/","headers":[{"key":"A","value":"1"},{"key":"B","value":null},{"key":"","value":"x"}],' +
        '"body":{"mode":"formdata","fields":[{"key":"f","value":"/p","file":true},{"key":"t","value":"v"}]}},' +
        '"variables":{"set":[{"scope":"session","name":"s","value":"1"},{"name":"d","value":"2"}],"unset":[{"scope":"collection","name":"c"}]},' +
        '"console":["one","two"],"tests":[{"name":"t1","passed":true},{"name":"t2","passed":false,"error":"bad"}],"error":null}';
var
  R: THookResult;
begin
  R := THookResult.Create;
  try
    AssertTrue(R.ErrorMessage, ParseHookOutput(Doc, R));
    AssertTrue(R.HasMethod); AssertEquals('DELETE', R.Method);
    AssertTrue(R.HasUrl); AssertEquals('https://u/', R.Url);
    AssertEquals('empty key skipped', 2, R.HeaderOpCount);
    AssertEquals('A', R.HeaderOps[0].Key); AssertFalse(R.HeaderOps[0].Remove);
    AssertEquals('B', R.HeaderOps[1].Key); AssertTrue(R.HeaderOps[1].Remove);
    AssertTrue(R.HasBody); AssertTrue(R.BodyMode = bmFormData);
    AssertEquals(2, R.BodyFields.Count); AssertTrue(R.BodyFields[0].IsFile); AssertFalse(R.BodyFields[1].IsFile);
    AssertEquals(3, R.VarOpCount);
    AssertEquals('session', R.VarOps[1].Scope);   // scope defaults to session
    AssertTrue(R.VarOps[2].Unset);
    AssertEquals(2, R.Console.Count); AssertEquals('two', R.Console[1]);
    AssertEquals(2, R.TestCount); AssertEquals(1, R.FailedTestCount);
    AssertEquals('bad', R.Tests[1].Error);
  finally
    R.Free;
  end;
  // Shorthand body and headers: null
  R := THookResult.Create;
  try
    AssertTrue(ParseHookOutput('{"request":{"body":"plain text","headers":null}}', R));
    AssertTrue(R.HasBody); AssertTrue(R.BodyMode = bmRaw); AssertEquals('plain text', R.BodyText);
    AssertTrue(R.HeadersCleared);
  finally
    R.Free;
  end;
end;

procedure THookTestCase.TestParseErrors;
var
  R: THookResult;
begin
  R := THookResult.Create;
  try
    AssertFalse(ParseHookOutput('debug line'#10'{"a":1}', R));
    AssertTrue(R.ErrorMessage, Pos('not valid JSON', R.ErrorMessage) > 0);
    AssertEquals('debug line'#10'{"a":1}', R.StdOutExcerpt);
  finally
    R.Free;
  end;
  R := THookResult.Create;
  try
    AssertFalse(ParseHookOutput('[1,2]', R));
    AssertTrue(Pos('not a JSON object', R.ErrorMessage) > 0);
  finally
    R.Free;
  end;
  R := THookResult.Create;
  try
    AssertFalse(ParseHookOutput('{"protocol":2}', R));
    AssertEquals('hook speaks protocol 2, mailBoy speaks 1', R.ErrorMessage);
  finally
    R.Free;
  end;
  R := THookResult.Create;
  try
    AssertFalse(ParseHookOutput('{"console":["a"],"error":{"message":"no","detail":"why"}}', R));
    AssertEquals('no', R.ErrorMessage);
    AssertEquals('why', R.ErrorDetail);
    AssertEquals('console kept on error', 1, R.Console.Count);
  finally
    R.Free;
  end;
  R := THookResult.Create;
  try
    AssertFalse(ParseHookOutput('{"error":"plain string"}', R));
    AssertEquals('plain string', R.ErrorMessage);
  finally
    R.Free;
  end;
end;

procedure THookTestCase.TestApplyHeaderMerge;
var
  R: THookResult;
begin
  FResolved.Headers.Add('X-Dup', '1');
  FResolved.Headers.Add('x-dup', '2');
  R := THookResult.Create;
  try
    ParseHookOutput('{"request":{"headers":[{"key":"content-type","value":"text/csv"},{"key":"X-DUP","value":"3"},{"key":"New","value":"n"},{"key":"Absent","value":null}]}}', R);
    ApplyRequestChanges(R, FResolved);
    AssertEquals(3, FResolved.Headers.Count);
    AssertEquals('text/csv', FResolved.Headers.ValueOf('Content-Type'));
    AssertEquals('both duplicates replaced by one', 1, FResolved.Headers.IndexOfKey('x-dup'));
    AssertEquals('3', FResolved.Headers.ValueOf('X-Dup'));
    AssertEquals('n', FResolved.Headers.ValueOf('New'));
    AssertEquals('replaced header keeps the hook spelling', 'content-type', FResolved.Headers[0].Key);
  finally
    R.Free;
  end;
  R := THookResult.Create;
  try
    ParseHookOutput('{"request":{"headers":[{"key":"New","value":null}]}}', R);
    ApplyRequestChanges(R, FResolved);
    AssertEquals(2, FResolved.Headers.Count);
    AssertNull(FResolved.Headers.Find('New'));
  finally
    R.Free;
  end;
end;

procedure THookTestCase.TestApplyReplacements;
var
  R: THookResult;
begin
  R := THookResult.Create;
  try
    ParseHookOutput('{"request":{"method":"put","url":"https://changed.test/x","headers":null,"body":{"mode":"urlencoded","raw":"a=1"}}}', R);
    ApplyRequestChanges(R, FResolved);
    AssertEquals('PUT', FResolved.Method);
    AssertEquals('https://changed.test/x', FResolved.Url);
    AssertEquals(0, FResolved.Headers.Count);
    AssertTrue(FResolved.BodyMode = bmUrlEncoded);
    AssertEquals('a=1', FResolved.BodyText);
  finally
    R.Free;
  end;
  R := THookResult.Create;
  try
    ParseHookOutput('{"request":{"body":{"mode":"none"}}}', R);
    ApplyRequestChanges(R, FResolved);
    AssertTrue(FResolved.BodyMode = bmNone);
    AssertEquals('', FResolved.BodyText);
  finally
    R.Free;
  end;
end;

procedure THookTestCase.TestApplyVariables;
var
  R: THookResult;
  W: TStringList;
  V: string;
begin
  R := THookResult.Create;
  W := TStringList.Create;
  try
    ParseHookOutput('{"variables":{"set":[{"scope":"session","name":"s","value":"1"},{"scope":"environment","name":"e","value":"2"},' +
      '{"scope":"collection","name":"CLIENT_ID","value":"new"},{"scope":"mars","name":"m","value":"3"}],"unset":[{"scope":"session","name":"gone"}]}}', R);
    ApplyVariableChanges(R, FScope, W);
    AssertEquals('1', FScope.Resolve('{{s}}'));
    AssertEquals('2', FScope.Resolve('{{e}}'));
    AssertEquals('new', FScope.Resolve('{{CLIENT_ID}}'));
    AssertFalse('gone was unset', FScope.Lookup('gone', V));
    AssertEquals(1, W.Count);
    AssertTrue(W[0], Pos('unknown variable scope "mars"', W[0]) > 0);
  finally
    W.Free;
    R.Free;
  end;
  // No environment loaded: falls back to session with a warning.
  FScope.Free;
  FScope := TVariableScope.Create;
  FScope.PushLayer('collection', nil);
  FScope.PushLayer('session', nil);
  R := THookResult.Create;
  W := TStringList.Create;
  try
    ParseHookOutput('{"variables":{"set":[{"scope":"environment","name":"e","value":"2"}]}}', R);
    ApplyVariableChanges(R, FScope, W);
    AssertEquals('2', FScope.Resolve('{{e}}'));
    AssertEquals(1, W.Count);
    AssertTrue(W[0], Pos('no environment scope is loaded', W[0]) > 0);
  finally
    W.Free;
    R.Free;
  end;
end;

procedure THookTestCase.TestIsValidUtf8;
begin
  AssertTrue(IsValidUtf8(''));
  AssertTrue(IsValidUtf8('plain ascii'));
  AssertTrue(IsValidUtf8('caf'#$C3#$A9));
  AssertTrue(IsValidUtf8(#$E2#$82#$AC));          // euro sign
  AssertTrue(IsValidUtf8(#$F0#$9F#$98#$80));      // emoji
  AssertFalse(IsValidUtf8(#$C3));                 // truncated
  AssertFalse(IsValidUtf8(#$FF));
  AssertFalse(IsValidUtf8('a'#$80'b'));           // stray continuation
  AssertFalse(IsValidUtf8(#$C0#$AF));             // overlong
  AssertFalse(IsValidUtf8('x'#0'y') = False);     // NUL is valid UTF-8
end;

procedure THookTestCase.TestRunBeforeAddsHeaders;
var
  H: THookRunner;
  R: THookResult;
begin
  H := THookRunner.Create;
  try
    H.Command := Hook('add_header.sh');
    R := H.RunBefore(FResolved, FScope, FReq, FCtx);
    try
      AssertTrue(R.ErrorMessage, R.Ok);
      AssertTrue(R.Ran);
      AssertEquals(0, R.ExitCode);
      AssertTrue(R.Phase = hpBefore);
      AssertEquals('sig-1', FResolved.Headers.ValueOf('x-acme-signature'));
      AssertEquals('application/x-signed', FResolved.Headers.ValueOf('Content-Type'));
      AssertEquals(2, FResolved.Headers.Count);
      AssertEquals('yes', FScope.Resolve('{{signed}}'));
      AssertEquals(1, R.Console.Count);
      AssertEquals('signed it', R.Console[0]);
      AssertTrue(R.ElapsedMs >= 0);
    finally
      R.Free;
    end;
  finally
    H.Free;
  end;
end;

procedure THookTestCase.TestRunAfterSetsVariableAndTests;
var
  H: THookRunner;
  R: THookResult;
  Resp: TResponse;
begin
  H := THookRunner.Create;
  Resp := ParseCurlOutput('HTTP/1.1 200 OK'#13#10#13#10'{}', 1);
  try
    H.Command := Hook('add_header.sh');
    R := H.RunAfter(FResolved, Resp, FScope, FReq, FCtx);
    try
      AssertTrue(R.ErrorMessage, R.Ok);
      AssertTrue(R.Phase = hpAfter);
      AssertEquals('tok123', FScope.Resolve('{{token}}'));
      AssertEquals(2, R.TestCount);
      AssertEquals(1, R.FailedTestCount);
      AssertEquals('no token', R.Tests[1].Error);
      AssertEquals('request untouched in after phase', 1, FResolved.Headers.Count);
    finally
      R.Free;
    end;
  finally
    Resp.Free;
    H.Free;
  end;
end;

procedure THookTestCase.TestRunFail;
var
  H: THookRunner;
  R: THookResult;
begin
  H := THookRunner.Create;
  try
    H.Command := Hook('fail.sh');
    R := H.RunBefore(FResolved, FScope, FReq, FCtx);
    try
      AssertFalse(R.Ok);
      AssertTrue(R.Ran);
      AssertEquals(1, R.ExitCode);
      AssertEquals('hook exited with code 1', R.ErrorMessage);
      AssertEquals('Traceback: boom'#10'  key missing'#10, R.StdErr);
      AssertEquals('nothing applied', 1, FResolved.Headers.Count);
    finally
      R.Free;
    end;
  finally
    H.Free;
  end;
end;

procedure THookTestCase.TestRunGarbage;
var
  H: THookRunner;
  R: THookResult;
begin
  H := THookRunner.Create;
  try
    H.Command := Hook('garbage.sh');
    R := H.RunBefore(FResolved, FScope, FReq, FCtx);
    try
      AssertFalse(R.Ok);
      AssertEquals(0, R.ExitCode);
      AssertTrue(R.ErrorMessage, Pos('not valid JSON', R.ErrorMessage) > 0);
      AssertEquals('debug line kept for the report', 1, Pos('debug: starting', R.StdOutExcerpt));
    finally
      R.Free;
    end;
  finally
    H.Free;
  end;
end;

procedure THookTestCase.TestRunErrorObject;
var
  H: THookRunner;
  R: THookResult;
begin
  H := THookRunner.Create;
  try
    H.Command := Hook('error_obj.sh');
    R := H.RunBefore(FResolved, FScope, FReq, FCtx);
    try
      AssertFalse(R.Ok);
      AssertEquals(0, R.ExitCode);
      AssertEquals('refusing to sign', R.ErrorMessage);
      AssertEquals('KEY_ID is empty', R.ErrorDetail);
      AssertEquals('checked key', R.Console[0]);
    finally
      R.Free;
    end;
  finally
    H.Free;
  end;
end;

procedure THookTestCase.TestRunTimeout;
var
  H: THookRunner;
  R: THookResult;
begin
  H := THookRunner.Create;
  try
    H.Command := Hook('sleep.sh');
    H.TimeoutSec := 1;
    R := H.RunBefore(FResolved, FScope, FReq, FCtx);
    try
      AssertFalse(R.Ok);
      AssertTrue(R.TimedOut);
      AssertEquals('hook killed after 1 s', R.ErrorMessage);
      AssertTrue(R.ElapsedMs < 3000);
    finally
      R.Free;
    end;
  finally
    H.Free;
  end;
end;

procedure THookTestCase.TestRunWrongProtocol;
var
  H: THookRunner;
  R: THookResult;
begin
  H := THookRunner.Create;
  try
    H.Command := Hook('wrong_protocol.sh');
    R := H.RunBefore(FResolved, FScope, FReq, FCtx);
    try
      AssertFalse(R.Ok);
      AssertEquals('hook speaks protocol 2, mailBoy speaks 1', R.ErrorMessage);
    finally
      R.Free;
    end;
  finally
    H.Free;
  end;
end;

procedure THookTestCase.TestRunBigStderr;
var
  H: THookRunner;
  R: THookResult;
begin
  H := THookRunner.Create;
  try
    H.Command := Hook('big_stderr.sh');
    H.TimeoutSec := 20;
    R := H.RunBefore(FResolved, FScope, FReq, FCtx);
    try
      AssertTrue(R.ErrorMessage, R.Ok);
      AssertEquals(1048576, Length(R.StdErr));
      AssertEquals('survived', R.Console[0]);
    finally
      R.Free;
    end;
  finally
    H.Free;
  end;
end;

procedure THookTestCase.TestRunMissingCommand;
var
  H: THookRunner;
  R: THookResult;
begin
  H := THookRunner.Create;
  try
    H.Command := '/nonexistent/hook';
    R := H.RunBefore(FResolved, FScope, FReq, FCtx);
    try
      AssertFalse(R.Ok);
      AssertTrue(R.ErrorMessage <> '');
    finally
      R.Free;
    end;
  finally
    H.Free;
  end;
end;

procedure THookTestCase.TestDisabledRunnerDoesNothing;
var
  H: THookRunner;
  R: THookResult;
begin
  H := THookRunner.Create;
  try
    AssertFalse(H.Enabled);
    R := H.RunBefore(FResolved, FScope, FReq, FCtx);
    try
      AssertFalse(R.Ran);
      AssertFalse(R.Ok);
      AssertEquals('', R.ErrorMessage);
    finally
      R.Free;
    end;
  finally
    H.Free;
  end;
end;

initialization
  RegisterTest(THookTestCase);

end.
