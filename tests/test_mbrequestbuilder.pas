unit test_mbRequestBuilder;

// Request builder tests: given a model request, assert the exact argv.
// No network. Model objects are mostly built by hand; two tests use fixtures
// from samples/collections loaded through mbLoader.

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry, mbModel, mbVariables, mbLoader,
  mbRequestBuilder;

type
  TRequestBuilderTest = class(TTestCase)
  private
    FRequest: TRequest;
    FScope: TVariableScope;
    FResolved: TResolvedRequest;
    FArgs: TStringList;
    FWarnings: TStringList;
    procedure AssertArgs(const AExpected: array of string; AActual: TStringList);
    procedure SetVar(const AName, AValue: string);
    { Resolves FRequest with FScope and builds curl args with AOptions into FResolved / FArgs. }
    procedure Build(const AOptions: TBuildOptions);
    procedure BuildDefault;
    function WarningsContaining(const S: string): Integer;
    function LoadFixture(const AName: string): TCollection;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestDefaultBuildOptions;
    procedure TestBasicGetWithQueryAndVariable;
    procedure TestQueryDisabledOmittedAndEmptyValue;
    procedure TestQueryEmptyKeySkippedAndFragmentDropped;
    procedure TestPathVariableReplaced;
    procedure TestPathVariableMissingWarns;
    procedure TestHeadersDuplicatesDisabledEmpty;
    procedure TestRawJsonAddsContentType;
    procedure TestRawExistingContentTypeWins;
    procedure TestRawLanguages;
    procedure TestRawEmptyBodySendsNoDataFlag;
    procedure TestUrlEncodedEncoding;
    procedure TestFormData;
    procedure TestFileBody;
    procedure TestBasicAuth;
    procedure TestBearerAuth;
    procedure TestBearerWithExplicitAuthorizationHeader;
    procedure TestInheritedBearerFromTwitterFixture;
    procedure TestOAuth1Warning;
    procedure TestUnresolvedVariables;
    procedure TestNilScopeLeavesPlaceholders;
    procedure TestHeadMethod;
    procedure TestOptionsNoFollowNoTimeout;
    procedure TestOptionsInsecure;
    procedure TestGraphQLFixture;
    procedure TestUnknownBodyModeWarns;
    procedure TestWgetShape;
    procedure TestWgetFormDataWarning;
    procedure TestPercentEncode;
    procedure TestArgsToDisplayString;
  end;

implementation

const
  FixtureDir = 'samples' + PathDelim + 'collections' + PathDelim;

procedure TRequestBuilderTest.SetUp;
begin
  FRequest := TRequest.Create;
  FScope := TVariableScope.Create;
  FResolved := nil;
  FArgs := nil;
  FWarnings := TStringList.Create;
end;

procedure TRequestBuilderTest.TearDown;
begin
  FWarnings.Free;
  FArgs.Free;
  FResolved.Free;
  FScope.Free;
  FRequest.Free;
end;

procedure TRequestBuilderTest.AssertArgs(const AExpected: array of string; AActual: TStringList);
var
  I, N: Integer;
  Same: Boolean;
  Msg: string;
begin
  N := Length(AExpected);
  Same := AActual.Count = N;
  if Same then
    for I := 0 to N - 1 do
      if AActual[I] <> AExpected[I] then
      begin
        Same := False;
        Break;
      end;
  if Same then Exit;
  Msg := LineEnding + 'argv mismatch' + LineEnding
    + '  expected (' + IntToStr(N) + '):' + LineEnding;
  for I := 0 to N - 1 do
    Msg := Msg + '    [' + IntToStr(I) + '] ' + AExpected[I] + LineEnding;
  Msg := Msg + '  actual (' + IntToStr(AActual.Count) + '):' + LineEnding;
  for I := 0 to AActual.Count - 1 do
  begin
    Msg := Msg + '    [' + IntToStr(I) + '] ' + AActual[I];
    if (I >= N) or (AActual[I] <> AExpected[I]) then
      Msg := Msg + '   <-- differs';
    Msg := Msg + LineEnding;
  end;
  Fail(Msg);
end;

procedure TRequestBuilderTest.SetVar(const AName, AValue: string);
begin
  FScope.SetVariable(AName, AValue);
end;

procedure TRequestBuilderTest.Build(const AOptions: TBuildOptions);
begin
  FreeAndNil(FArgs);
  FreeAndNil(FResolved);
  FResolved := ResolveRequest(FRequest, FScope);
  FArgs := BuildCurlArgs(FResolved, AOptions);
end;

procedure TRequestBuilderTest.BuildDefault;
begin
  Build(DefaultBuildOptions);
end;

function TRequestBuilderTest.WarningsContaining(const S: string): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to FResolved.Warnings.Count - 1 do
    if Pos(S, FResolved.Warnings[I]) > 0 then Inc(Result);
end;

function TRequestBuilderTest.LoadFixture(const AName: string): TCollection;
begin
  Result := LoadCollectionFromFile(FixtureDir + AName, FWarnings);
end;

{ ---- tests ---- }

procedure TRequestBuilderTest.TestDefaultBuildOptions;
var
  O: TBuildOptions;
begin
  O := DefaultBuildOptions;
  AssertEquals(30, O.TimeoutSec);
  AssertTrue(O.FollowRedirects);
  AssertFalse(O.Insecure);
  AssertEquals(10, O.MaxRedirects);
end;

procedure TRequestBuilderTest.TestBasicGetWithQueryAndVariable;
begin
  SetVar('baseUrl', 'https://api.example.com');
  SetVar('page', '2');
  FRequest.Method := 'GET';
  FRequest.Url.Raw := '{{baseUrl}}/users?page={{page}}&sort=name';
  FRequest.Url.Query.Add('page', '{{page}}');
  FRequest.Url.Query.Add('sort', 'name');
  BuildDefault;
  AssertArgs(['-s', '-S', '-i', '-L', '--max-redirs', '10', '--max-time', '30',
    '-X', 'GET', 'https://api.example.com/users?page=2&sort=name'], FArgs);
  AssertEquals(0, FResolved.Unresolved.Count);
  AssertEquals(0, FResolved.Warnings.Count);
end;

procedure TRequestBuilderTest.TestQueryDisabledOmittedAndEmptyValue;
begin
  FRequest.Url.Raw := 'https://h/x?a=1&b=2&c';
  FRequest.Url.Query.Add('a', '1');
  FRequest.Url.Query.Add('b', '2').Enabled := False;
  FRequest.Url.Query.Add('c', '');
  BuildDefault;
  AssertEquals('https://h/x?a=1&c=', FResolved.Url);
  AssertEquals('https://h/x?a=1&c=', FArgs[FArgs.Count - 1]);
end;

procedure TRequestBuilderTest.TestQueryEmptyKeySkippedAndFragmentDropped;
begin
  FRequest.Url.Raw := 'https://h/x?=1&t=a%3Ab#frag';
  FRequest.Url.Query.Add('', '1');
  FRequest.Url.Query.Add('t', 'a%3Ab');
  BuildDefault;
  // the pre-encoded value is passed through untouched, the fragment is gone
  AssertEquals('https://h/x?t=a%3Ab', FResolved.Url);
end;

procedure TRequestBuilderTest.TestPathVariableReplaced;
begin
  SetVar('tweetId', '1234567890');
  FRequest.Url.Raw := 'https://api.twitter.com/2/tweets/:id/likes/:idx';
  FRequest.Url.PathVariables.Add('id', '{{tweetId}}');
  FRequest.Url.PathVariables.Add('idx', '7');
  BuildDefault;
  // ":id" must not eat the prefix of ":idx"
  AssertEquals('https://api.twitter.com/2/tweets/1234567890/likes/7', FResolved.Url);
  AssertEquals(0, FResolved.Warnings.Count);
end;

procedure TRequestBuilderTest.TestPathVariableMissingWarns;
begin
  FRequest.Url.Raw := 'https://h/users/:id';
  FRequest.Url.PathVariables.Add('id', '');
  BuildDefault;
  AssertEquals('https://h/users/:id', FResolved.Url);
  AssertEquals(1, FResolved.Warnings.Count);
  AssertEquals('path variable id has no value', FResolved.Warnings[0]);
end;

procedure TRequestBuilderTest.TestHeadersDuplicatesDisabledEmpty;
begin
  SetVar('tok', 'T1');
  FRequest.Url.Raw := 'https://h/';
  FRequest.Headers.Add('X-Dup', 'one');
  FRequest.Headers.Add('X-Dup', 'two');
  FRequest.Headers.Add('X-Off', 'gone').Enabled := False;
  FRequest.Headers.Add('X-Empty', '');
  FRequest.Headers.Add('', 'no key');
  FRequest.Headers.Add('X-Var', '{{tok}}');
  BuildDefault;
  AssertEquals(4, FResolved.Headers.Count);
  AssertArgs(['-s', '-S', '-i', '-L', '--max-redirs', '10', '--max-time', '30',
    '-X', 'GET',
    '-H', 'X-Dup: one',
    '-H', 'X-Dup: two',
    '-H', 'X-Empty;',
    '-H', 'X-Var: T1',
    'https://h/'], FArgs);
end;

procedure TRequestBuilderTest.TestRawJsonAddsContentType;
begin
  FRequest.Method := 'POST';
  FRequest.Url.Raw := 'https://h/p';
  FRequest.Body.Mode := bmRaw;
  FRequest.Body.Language := 'json';
  FRequest.Body.Raw := '{"a": 1,' + LineEnding + ' "b": "{{v}}"}';
  SetVar('v', 'x');
  BuildDefault;
  AssertArgs(['-s', '-S', '-i', '-L', '--max-redirs', '10', '--max-time', '30',
    '-X', 'POST',
    '-H', 'Content-Type: application/json',
    '--data-binary', '{"a": 1,' + LineEnding + ' "b": "x"}',
    'https://h/p'], FArgs);
end;

procedure TRequestBuilderTest.TestRawExistingContentTypeWins;
begin
  FRequest.Method := 'POST';
  FRequest.Url.Raw := 'https://h/p';
  FRequest.Headers.Add('content-type', 'application/vnd.api+json');
  FRequest.Body.Mode := bmRaw;
  FRequest.Body.Language := 'json';
  FRequest.Body.Raw := '{}';
  BuildDefault;
  AssertEquals(1, FResolved.Headers.Count);
  AssertArgs(['-s', '-S', '-i', '-L', '--max-redirs', '10', '--max-time', '30',
    '-X', 'POST',
    '-H', 'content-type: application/vnd.api+json',
    '--data-binary', '{}',
    'https://h/p'], FArgs);
end;

procedure TRequestBuilderTest.TestRawLanguages;

  procedure Check(const ALang, AExpected: string);
  begin
    FRequest.Body.Language := ALang;
    BuildDefault;
    if AExpected = '' then
      AssertEquals(ALang + ': no header', 0, FResolved.Headers.Count)
    else
    begin
      AssertEquals(ALang + ': one header', 1, FResolved.Headers.Count);
      AssertEquals(ALang, AExpected, FResolved.Headers.ValueOf('Content-Type'));
    end;
  end;

begin
  FRequest.Method := 'POST';
  FRequest.Url.Raw := 'https://h/p';
  FRequest.Body.Mode := bmRaw;
  FRequest.Body.Raw := 'x';
  Check('xml', 'application/xml');
  Check('text', 'text/plain');
  Check('javascript', 'application/javascript');
  Check('html', 'text/html');
  Check('JSON', 'application/json');
  Check('', '');
  Check('yaml', '');
end;

procedure TRequestBuilderTest.TestRawEmptyBodySendsNoDataFlag;
begin
  FRequest.Method := 'POST';
  FRequest.Url.Raw := 'https://h/p';
  FRequest.Body.Mode := bmRaw;
  FRequest.Body.Raw := '';
  BuildDefault;
  AssertArgs(['-s', '-S', '-i', '-L', '--max-redirs', '10', '--max-time', '30',
    '-X', 'POST', 'https://h/p'], FArgs);
end;

procedure TRequestBuilderTest.TestUrlEncodedEncoding;
begin
  SetVar('who', 'J&J');
  FRequest.Method := 'POST';
  FRequest.Url.Raw := 'https://h/p';
  FRequest.Body.Mode := bmUrlEncoded;
  FRequest.Body.Params.Add('a b', 'c d');
  FRequest.Body.Params.Add('amp', 'x&y=z');
  FRequest.Body.Params.Add('uni', 'caf' + #$C3#$A9);        // "café" as UTF-8 bytes
  FRequest.Body.Params.Add('keep', 'A-z_0.9~');
  FRequest.Body.Params.Add('off', 'no').Enabled := False;
  FRequest.Body.Params.Add('v', '{{who}}');
  BuildDefault;
  AssertEquals('a%20b=c%20d&amp=x%26y%3Dz&uni=caf%C3%A9&keep=A-z_0.9~&v=J%26J', FResolved.BodyText);
  AssertArgs(['-s', '-S', '-i', '-L', '--max-redirs', '10', '--max-time', '30',
    '-X', 'POST',
    '-H', 'Content-Type: application/x-www-form-urlencoded',
    '--data-binary', 'a%20b=c%20d&amp=x%26y%3Dz&uni=caf%C3%A9&keep=A-z_0.9~&v=J%26J',
    'https://h/p'], FArgs);
end;

procedure TRequestBuilderTest.TestFormData;
var
  KV: TKeyValue;
begin
  SetVar('dir', '/tmp/up');
  FRequest.Method := 'POST';
  FRequest.Url.Raw := 'https://h/upload';
  FRequest.Body.Mode := bmFormData;
  FRequest.Body.Params.Add('name', 'Bob');
  FRequest.Body.Params.Add('note', '@not-a-file');
  FRequest.Body.Params.Add('off', 'x').Enabled := False;
  KV := FRequest.Body.Params.Add('doc', '{{dir}}/a.pdf');
  KV.IsFile := True;
  BuildDefault;
  AssertEquals(3, FResolved.FormFields.Count);
  AssertTrue('IsFile preserved', FResolved.FormFields[2].IsFile);
  AssertFalse('text field', FResolved.FormFields[0].IsFile);
  AssertEquals('no Content-Type for multipart, curl sets the boundary', 0, FResolved.Headers.Count);
  AssertArgs(['-s', '-S', '-i', '-L', '--max-redirs', '10', '--max-time', '30',
    '-X', 'POST',
    '--form-string', 'name=Bob',
    '--form-string', 'note=@not-a-file',
    '-F', 'doc=@/tmp/up/a.pdf',
    'https://h/upload'], FArgs);
end;

procedure TRequestBuilderTest.TestFileBody;
begin
  SetVar('f', '/data/body.bin');
  FRequest.Method := 'PUT';
  FRequest.Url.Raw := 'https://h/blob';
  FRequest.Body.Mode := bmFile;
  FRequest.Body.FilePath := '{{f}}';
  BuildDefault;
  AssertEquals('/data/body.bin', FResolved.BodyFilePath);
  AssertArgs(['-s', '-S', '-i', '-L', '--max-redirs', '10', '--max-time', '30',
    '-X', 'PUT', '--data-binary', '@/data/body.bin', 'https://h/blob'], FArgs);
end;

procedure TRequestBuilderTest.TestBasicAuth;
begin
  SetVar('pw', 's3cret');
  FRequest.Url.Raw := 'https://h/';
  FRequest.Auth.AuthType := atBasic;
  FRequest.Auth.Params.Add('username', 'alice');
  FRequest.Auth.Params.Add('password', '{{pw}}');
  BuildDefault;
  AssertTrue(FResolved.AuthType = atBasic);
  AssertEquals('alice', FResolved.AuthUser);
  AssertEquals('s3cret', FResolved.AuthPassword);
  AssertArgs(['-s', '-S', '-i', '-L', '--max-redirs', '10', '--max-time', '30',
    '-X', 'GET', '-u', 'alice:s3cret', 'https://h/'], FArgs);
end;

procedure TRequestBuilderTest.TestBearerAuth;
begin
  SetVar('t', 'XYZ');
  FRequest.Url.Raw := 'https://h/';
  FRequest.Headers.Add('Accept', 'application/json');
  FRequest.Auth.AuthType := atBearer;
  FRequest.Auth.Params.Add('token', '{{t}}');
  BuildDefault;
  AssertEquals('XYZ', FResolved.BearerToken);
  AssertArgs(['-s', '-S', '-i', '-L', '--max-redirs', '10', '--max-time', '30',
    '-X', 'GET',
    '-H', 'Accept: application/json',
    '-H', 'Authorization: Bearer XYZ',
    'https://h/'], FArgs);
end;

procedure TRequestBuilderTest.TestBearerWithExplicitAuthorizationHeader;
begin
  FRequest.Url.Raw := 'https://h/';
  FRequest.Headers.Add('authorization', 'Bearer explicit');
  FRequest.Auth.AuthType := atBearer;
  FRequest.Auth.Params.Add('token', 'fromauth');
  BuildDefault;
  AssertArgs(['-s', '-S', '-i', '-L', '--max-redirs', '10', '--max-time', '30',
    '-X', 'GET',
    '-H', 'authorization: Bearer explicit',
    'https://h/'], FArgs);
  AssertEquals(1, FResolved.Warnings.Count);
  AssertEquals(1, WarningsContaining('Authorization header'));
end;

procedure TRequestBuilderTest.TestInheritedBearerFromTwitterFixture;
var
  C: TCollection;
  M: TFPList;
  R: TResolvedRequest;
  Args: TStringList;
begin
  C := LoadFixture('twitter-api-v2.collection.json');
  M := TFPList.Create;
  try
    AssertEquals(1, C.FindRequests('Tweet Lookup/Single Tweet', M));
    SetVar('bearer_token', 'XYZ');
    R := ResolveRequest(TRequest(M[0]), FScope);
    try
      AssertTrue(R.AuthType = atBearer);
      AssertEquals('XYZ', R.BearerToken);
      Args := BuildCurlArgs(R, DefaultBuildOptions);
      try
        // every query param is disabled and the :id path variable is empty
        AssertArgs(['-s', '-S', '-i', '-L', '--max-redirs', '10', '--max-time', '30',
          '-X', 'GET',
          '-H', 'Authorization: Bearer XYZ',
          'https://api.twitter.com/2/tweets/:id'], Args);
      finally
        Args.Free;
      end;
      AssertEquals(1, R.Warnings.Count);
      AssertEquals('path variable id has no value', R.Warnings[0]);
      AssertEquals(0, R.Unresolved.Count);
    finally
      R.Free;
    end;
  finally
    M.Free;
    C.Free;
  end;
end;

procedure TRequestBuilderTest.TestOAuth1Warning;
begin
  FRequest.Url.Raw := 'https://h/';
  FRequest.Auth.AuthType := atOther;
  FRequest.Auth.RawType := 'oauth1';
  FRequest.Auth.Params.Add('consumerKey', 'k');
  BuildDefault;
  AssertTrue(FResolved.AuthType = atOther);
  AssertArgs(['-s', '-S', '-i', '-L', '--max-redirs', '10', '--max-time', '30',
    '-X', 'GET', 'https://h/'], FArgs);
  AssertEquals(1, FResolved.Warnings.Count);
  AssertEquals('auth type oauth1 not supported, request sent without it', FResolved.Warnings[0]);
end;

procedure TRequestBuilderTest.TestUnresolvedVariables;
begin
  SetVar('known', 'K');
  FRequest.Method := 'POST';
  FRequest.Url.Raw := '{{host}}/{{known}}/{{path}}';
  FRequest.Headers.Add('X-{{hk}}', '{{host}}');
  FRequest.Body.Mode := bmRaw;
  FRequest.Body.Raw := '{{body}} and {{host}}';
  FRequest.Auth.AuthType := atBearer;
  FRequest.Auth.Params.Add('token', '{{tok}}');
  BuildDefault;
  AssertEquals('{{host}}/K/{{path}}', FResolved.Url);
  AssertEquals('{{host}}/K/{{path}}', FArgs[FArgs.Count - 1]);
  AssertEquals('host,path,hk,body,tok', FResolved.Unresolved.CommaText);
end;

procedure TRequestBuilderTest.TestNilScopeLeavesPlaceholders;
var
  R: TResolvedRequest;
begin
  FRequest.Url.Raw := '{{a}}/x';
  FRequest.Headers.Add('H', '{{a}} {{b}}');
  R := ResolveRequest(FRequest, nil);
  try
    AssertEquals('{{a}}/x', R.Url);
    AssertEquals('{{a}} {{b}}', R.Headers[0].Value);
    AssertEquals('a,b', R.Unresolved.CommaText);
  finally
    R.Free;
  end;
end;

procedure TRequestBuilderTest.TestHeadMethod;
begin
  FRequest.Method := 'head';
  FRequest.Url.Raw := 'https://h/';
  BuildDefault;
  AssertEquals('HEAD', FResolved.Method);
  AssertArgs(['-s', '-S', '-L', '--max-redirs', '10', '--max-time', '30',
    '-I', 'https://h/'], FArgs);
end;

procedure TRequestBuilderTest.TestOptionsNoFollowNoTimeout;
var
  O: TBuildOptions;
begin
  FRequest.Url.Raw := 'https://h/';
  O := DefaultBuildOptions;
  O.FollowRedirects := False;
  O.TimeoutSec := 0;
  Build(O);
  AssertArgs(['-s', '-S', '-i', '-X', 'GET', 'https://h/'], FArgs);
end;

procedure TRequestBuilderTest.TestOptionsInsecure;
var
  O: TBuildOptions;
begin
  FRequest.Method := 'DELETE';
  FRequest.Url.Raw := 'https://h/';
  O := DefaultBuildOptions;
  O.Insecure := True;
  O.MaxRedirects := 3;
  O.TimeoutSec := 5;
  Build(O);
  AssertArgs(['-s', '-S', '-i', '-L', '--max-redirs', '3', '--max-time', '5', '-k',
    '-X', 'DELETE', 'https://h/'], FArgs);
end;

procedure TRequestBuilderTest.TestGraphQLFixture;
var
  C: TCollection;
  M: TFPList;
  R: TResolvedRequest;
  Args: TStringList;
begin
  C := LoadFixture('codegen-basic.collection.json');
  M := TFPList.Create;
  try
    AssertEquals(1, C.FindRequests('POST graphql body(json) with raw', M));
    R := ResolveRequest(TRequest(M[0]), FScope);
    try
      AssertTrue(R.BodyMode = bmGraphQL);
      Args := BuildCurlArgs(R, DefaultBuildOptions);
      try
        AssertArgs(['-s', '-S', '-i', '-L', '--max-redirs', '10', '--max-time', '30',
          '-X', 'POST',
          '-H', 'Content-Type: application/json',
          '--data-binary', TRequest(M[0]).Body.Raw,
          'https://upstream-echo.com/post'], Args);
        AssertEquals(1, Pos('{"query":"', Args[Args.Count - 2]));
        AssertTrue('query inside document', Pos('findScenes', Args[Args.Count - 2]) > 0);
        AssertTrue('variables inside document', Pos('"variables":{', Args[Args.Count - 2]) > 0);
      finally
        Args.Free;
      end;
      AssertEquals(0, R.Warnings.Count);
    finally
      R.Free;
    end;
  finally
    M.Free;
    C.Free;
  end;
end;

procedure TRequestBuilderTest.TestUnknownBodyModeWarns;
begin
  FRequest.Method := 'POST';
  FRequest.Url.Raw := 'https://h/';
  FRequest.Body.Mode := bmUnknown;
  FRequest.Body.RawMode := 'carrier-pigeon';
  BuildDefault;
  AssertArgs(['-s', '-S', '-i', '-L', '--max-redirs', '10', '--max-time', '30',
    '-X', 'POST', 'https://h/'], FArgs);
  AssertEquals(1, WarningsContaining('carrier-pigeon'));
end;

procedure TRequestBuilderTest.TestWgetShape;
var
  O: TBuildOptions;
begin
  FRequest.Method := 'POST';
  FRequest.Url.Raw := 'https://h/p';
  FRequest.Headers.Add('X-A', '1');
  FRequest.Headers.Add('X-Empty', '');
  FRequest.Body.Mode := bmRaw;
  FRequest.Body.Language := 'json';
  FRequest.Body.Raw := '{"k":1}';
  FRequest.Auth.AuthType := atBearer;
  FRequest.Auth.Params.Add('token', 'T');
  O := DefaultBuildOptions;
  O.Insecure := True;
  FResolved := ResolveRequest(FRequest, FScope);
  FArgs := BuildWgetArgs(FResolved, O);
  AssertArgs(['-S', '-O', '-', '--max-redirect=10', '--timeout=30', '--no-check-certificate',
    '--method=POST',
    '--header=X-A: 1',
    '--header=X-Empty:',
    '--header=Content-Type: application/json',
    '--header=Authorization: Bearer T',
    '--body-data={"k":1}',
    'https://h/p'], FArgs);
  AssertEquals(0, FResolved.Warnings.Count);
end;

procedure TRequestBuilderTest.TestWgetFormDataWarning;
var
  O: TBuildOptions;
begin
  FRequest.Method := 'POST';
  FRequest.Url.Raw := 'https://h/up';
  FRequest.Body.Mode := bmFormData;
  FRequest.Body.Params.Add('a', 'b');
  FRequest.Auth.AuthType := atBasic;
  FRequest.Auth.Params.Add('username', 'u');
  FRequest.Auth.Params.Add('password', 'p');
  O := DefaultBuildOptions;
  O.FollowRedirects := False;
  O.TimeoutSec := 0;
  FResolved := ResolveRequest(FRequest, FScope);
  FArgs := BuildWgetArgs(FResolved, O);
  AssertArgs(['-S', '-O', '-', '--max-redirect=0', '--method=POST',
    '--auth-no-challenge', '--user=u', '--password=p',
    'https://h/up'], FArgs);
  AssertEquals(1, FResolved.Warnings.Count);
  AssertEquals(1, WarningsContaining('form-data'));
end;

procedure TRequestBuilderTest.TestPercentEncode;
begin
  AssertEquals('', PercentEncode(''));
  AssertEquals('ABCxyz019-._~', PercentEncode('ABCxyz019-._~'));
  AssertEquals('a%20b', PercentEncode('a b'));
  AssertEquals('%26%3D%2B%2F%3F%23%25', PercentEncode('&=+/?#%'));
  AssertEquals('caf%C3%A9', PercentEncode('caf' + #$C3#$A9));
  AssertEquals('%00%7F', PercentEncode(#0#127));
end;

procedure TRequestBuilderTest.TestArgsToDisplayString;
var
  L: TStringList;
begin
  L := TStringList.Create;
  try
    AssertEquals('', ArgsToDisplayString(L));
    L.Add('-H');
    L.Add('Accept: text/plain');
    L.Add('');
    L.Add('it''s');
    L.Add('https://h/a?b=c%20d&e=f');
    L.Add('@/tmp/x.bin');
    AssertEquals('-H ''Accept: text/plain'' '''' ''it''\''''s'' ''https://h/a?b=c%20d&e=f'' @/tmp/x.bin',
      ArgsToDisplayString(L));
  finally
    L.Free;
  end;
end;

initialization
  RegisterTest(TRequestBuilderTest);

end.
