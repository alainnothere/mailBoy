unit test_mbLoader;

{ Loader tests against the 17 public fixtures in samples/collections.
  Expected numbers were computed independently from the JSON. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry, mbModel, mbLoader;

type
  TLoaderTest = class(TTestCase)
  private
    FWarnings: TStringList;
    procedure AssertNoHooks(const AName: string; AFolder: TFolder);
    function Fixture(const AName: string): string;
    function Load(const AName: string): TCollection;
    function FirstRequest(C: TCollection): TRequest;
    function RequestByPath(C: TCollection; const APath: string): TRequest;
    function WarningsContaining(const S: string): Integer;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestAllFixturesLoad;
    procedure TestCodegenBasic;
    procedure TestCodegenBasicGraphQL;
    procedure TestCodegenFormDataText;
    procedure TestCodegenFormDataFiles;
    procedure TestCodegenQueryParams;
    procedure TestCodegenSameNameHeaders;
    procedure TestCodegenUnsupportedMethods;
    procedure TestNewmanV20;
    procedure TestNewmanV1;
    procedure TestNestedFolders;
    procedure TestNestedNoName;
    procedure TestCanonicalV2;
    procedure TestAuthDigestUnsupportedWarning;
    procedure TestAuthHawk;
    procedure TestAuthOAuth1;
    procedure TestTwitter;
    procedure TestTwitterEnvironment;
    procedure TestEnvironmentRejectedAsCollection;
    procedure TestGarbageRaises;
    procedure TestMissingFileRaises;
    procedure TestIsEnvironmentJson;
    procedure TestSaveEnvironmentRoundTrip;
    procedure TestSaveEnvironmentToFile;
  end;

implementation

const
  FixtureDir = 'samples' + PathDelim + 'collections' + PathDelim;

procedure TLoaderTest.SetUp;
begin
  FWarnings := TStringList.Create;
end;

procedure TLoaderTest.TearDown;
begin
  FWarnings.Free;
end;

{ A collection file must never be able to name a hook program. }
procedure TLoaderTest.AssertNoHooks(const AName: string; AFolder: TFolder);
var
  I: Integer;
begin
  AssertEquals(AName + ': no hook on ' + AFolder.Name, '', AFolder.HookCommand);
  for I := 0 to AFolder.Count - 1 do
    if AFolder[I].IsFolder then
      AssertNoHooks(AName, TFolder(AFolder[I]))
    else
      AssertEquals(AName + ': no hook on ' + AFolder[I].Name, '', AFolder[I].HookCommand);
end;

function TLoaderTest.Fixture(const AName: string): string;
begin
  Result := FixtureDir + AName;
end;

function TLoaderTest.Load(const AName: string): TCollection;
begin
  Result := LoadCollectionFromFile(Fixture(AName), FWarnings);
end;

function TLoaderTest.FirstRequest(C: TCollection): TRequest;
var
  L: TFPList;
begin
  L := TFPList.Create;
  try
    C.CollectRequests(L);
    AssertTrue('collection has requests', L.Count > 0);
    Result := TRequest(L[0]);
  finally
    L.Free;
  end;
end;

function TLoaderTest.RequestByPath(C: TCollection; const APath: string): TRequest;
var
  M: TFPList;
begin
  M := TFPList.Create;
  try
    AssertEquals('exactly one match for ' + APath, 1, C.FindRequests(APath, M));
    Result := TRequest(M[0]);
  finally
    M.Free;
  end;
end;

function TLoaderTest.WarningsContaining(const S: string): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to FWarnings.Count - 1 do
    if Pos(S, FWarnings[I]) > 0 then Inc(Result);
end;

procedure TLoaderTest.TestAllFixturesLoad;
var
  SR: TSearchRec;
  C: TCollection;
  N: Integer;
begin
  N := 0;
  if FindFirst(FixtureDir + '*.collection.json', faAnyFile, SR) = 0 then
  try
    repeat
      C := LoadCollectionFromFile(FixtureDir + SR.Name, FWarnings);
      try
        AssertTrue(SR.Name + ': has a name', C.Name <> '');
        AssertTrue(SR.Name + ': has requests', C.RequestCount > 0);
        AssertTrue(SR.Name + ': schema detected', C.SchemaVersion <> svUnknown);
        AssertNoHooks(SR.Name, C);
      finally
        C.Free;
      end;
      Inc(N);
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
  AssertEquals('number of collection fixtures', 17, N);
end;

procedure TLoaderTest.TestCodegenBasic;
var
  C: TCollection;
  R: TRequest;
begin
  C := Load('codegen-basic.collection.json');
  try
    AssertEquals('Basic Collection', C.Name);
    AssertTrue(C.SchemaVersion = svV21);
    AssertEquals(14, C.RequestCount);
    AssertEquals(0, C.Count - C.RequestCount);  // no folders: items = requests
    R := RequestByPath(C, 'POST json with raw');
    AssertEquals('POST', R.Method);
    AssertTrue(R.Body.Mode = bmRaw);
    AssertTrue('raw body has content', Length(R.Body.Raw) > 0);
    AssertFalse('empty exec arrays are not scripts', R.HasScripts);
    R := RequestByPath(C, 'DELETE Request');
    AssertEquals('DELETE', R.Method);
    AssertTrue(R.Body.Mode = bmNone);
    // Scripts are kept, not warned about; this file's are all empty strings.
    AssertEquals(0, WarningsContaining('script'));
    AssertFalse(C.HasScripts);
  finally
    C.Free;
  end;
end;

procedure TLoaderTest.TestCodegenBasicGraphQL;
var
  C: TCollection;
  R: TRequest;
begin
  C := Load('codegen-basic.collection.json');
  try
    R := RequestByPath(C, 'POST graphql body(json) with raw');
    AssertTrue(R.Body.Mode = bmGraphQL);
    AssertEquals('json', R.Body.Language);
    AssertEquals(1, Pos('{"query":"', R.Body.Raw));
    AssertTrue('variables embedded', Pos('"variables":{', R.Body.Raw) > 0);
    AssertTrue('query text escaped into JSON', Pos('findScenes', R.Body.Raw) > 0);
  finally
    C.Free;
  end;
end;

procedure TLoaderTest.TestCodegenFormDataText;
var
  C: TCollection;
  R: TRequest;
  KV: TKeyValue;
begin
  C := Load('codegen-formdata.collection.json');
  try
    R := FirstRequest(C);
    AssertTrue(R.Body.Mode = bmFormData);
    AssertEquals(6, R.Body.Params.Count);
    AssertEquals('''a''', R.Body.Params.ValueOf('pl'));
    AssertEquals('!@#$%&*()^_+=`~', R.Body.Params.ValueOf('Special'));
    KV := R.Body.Params[4];
    AssertEquals('Not Select', KV.Key);
    AssertFalse('disabled field kept but off', KV.Enabled);
    AssertFalse(KV.IsFile);
  finally
    C.Free;
  end;
end;

procedure TLoaderTest.TestCodegenFormDataFiles;
var
  C: TCollection;
  R: TRequest;
  I, Files: Integer;
begin
  C := Load('codegen-formdata-file.collection.json');
  try
    AssertEquals(2, C.RequestCount);
    R := RequestByPath(C, 'Single/multiple file upload via form-data');
    AssertTrue(R.Body.Mode = bmFormData);
    Files := 0;
    for I := 0 to R.Body.Params.Count - 1 do
      if R.Body.Params[I].IsFile then Inc(Files);
    // "single file" (1) + "multiple files" (array of 2) = 3 file entries
    AssertEquals(3, Files);
    AssertTrue('array src split into separate entries',
      (R.Body.Params.IndexOfKey('multiple files') >= 0));
  finally
    C.Free;
  end;
end;

procedure TLoaderTest.TestCodegenQueryParams;
var
  C: TCollection;
  R: TRequest;
begin
  C := Load('codegen-query-params.collection.json');
  try
    R := FirstRequest(C);
    AssertEquals(1, R.Url.Query.Count);
    AssertEquals('query', R.Url.Query[0].Key);
    AssertEquals('urn%3Ali%3Afoo%3A62324', R.Url.Query[0].Value);
    // This fixture's own "raw" is malformed (no '?'); the structured query
    // array is what we trust, and raw is kept verbatim.
    AssertEquals('https://upstream-echo.com/query=urn%3Ali%3Afoo%3A62324', R.Url.Raw);
  finally
    C.Free;
  end;
end;

procedure TLoaderTest.TestCodegenSameNameHeaders;
var
  C: TCollection;
  R: TRequest;
begin
  C := Load('codegen-same-name-headers.collection.json');
  try
    R := FirstRequest(C);
    AssertEquals(2, R.Headers.Count);
    AssertEquals('key', R.Headers[0].Key);
    AssertEquals('value1', R.Headers[0].Value);
    AssertEquals('value2', R.Headers[1].Value);
    AssertEquals('https://upstream-echo.com/get', R.Url.Raw);
  finally
    C.Free;
  end;
end;

procedure TLoaderTest.TestCodegenUnsupportedMethods;
var
  C: TCollection;
begin
  C := Load('codegen-unsupported-methods.collection.json');
  try
    AssertEquals(7, C.RequestCount);
    AssertEquals('LINK', RequestByPath(C, 'LINK request').Method);
    AssertEquals('COPY', RequestByPath(C, 'COPY Request').Method);
  finally
    C.Free;
  end;
end;

procedure TLoaderTest.TestNewmanV20;
var
  C: TCollection;
  R: TRequest;
begin
  C := Load('newman-sample.collection.json');
  try
    AssertTrue(C.SchemaVersion = svV20);
    AssertEquals('Sample Upstream Collection', C.Name);
    AssertEquals(3, C.RequestCount);
    R := RequestByPath(C, 'A simple POST request with JSON body');
    AssertEquals('POST', R.Method);
    AssertTrue(R.Body.Mode = bmRaw);
    AssertEquals('application/json', R.Headers.ValueOf('Content-Type'));
  finally
    C.Free;
  end;
end;

procedure TLoaderTest.TestNewmanV1;
var
  C: TCollection;
  R: TRequest;
begin
  C := Load('newman-v1-format.collection.json');
  try
    AssertTrue(C.SchemaVersion = svV1);
    AssertEquals('Sample Upstream Collection', C.Name);
    AssertEquals(3, C.RequestCount);
    // "order" puts the GET first, then the plain POST, then the JSON POST.
    AssertEquals('A simple GET request', TRequest(C[0]).Name);
    AssertEquals('A simple POST request', TRequest(C[1]).Name);
    AssertEquals('A simple POST request with JSON body', TRequest(C[2]).Name);
    R := TRequest(C[0]);
    AssertEquals('GET', R.Method);
    AssertEquals('https://upstream-echo.com/get?source=newman-sample-github-collection', R.Url.Raw);
    AssertEquals(1, R.Url.Query.Count);
    AssertEquals('source', R.Url.Query[0].Key);
    AssertEquals('newman-sample-github-collection', R.Url.Query[0].Value);
    AssertTrue(R.Body.Mode = bmNone);
    R := TRequest(C[2]);
    AssertEquals('application/json', R.Headers.ValueOf('Content-Type'));
    AssertTrue(R.Body.Mode = bmRaw);
    AssertEquals(1, Pos('{"text":', R.Body.Raw));
    AssertEquals(0, WarningsContaining('script'));
    R := TRequest(C[0]);
    AssertEquals('tests[''response code is 200''] = (responseCode.code === 200);', R.TestScript);
    AssertEquals('', R.PreRequestScript);
    AssertTrue(R.HasScripts);
  finally
    C.Free;
  end;
end;

procedure TLoaderTest.TestNestedFolders;
var
  C: TCollection;
  R: TRequest;
begin
  C := Load('upstream-nested-folders.collection.json');
  try
    AssertEquals('multi-level-folders-v2', C.Name);
    AssertEquals(6, C.RequestCount);
    R := RequestByPath(C, 'F1/F1.R1');
    AssertEquals('F1.R1', R.Name);
    AssertEquals('exec lines joined with LF', 1, Pos('tests["Status code is 200"] = responseCode.code === 200;'#10, R.TestScript));
    AssertEquals('', R.PreRequestScript);
    AssertFalse('folder has none', R.Parent.HasScripts);
    AssertTrue('parent is a folder named F1', (R.Parent <> nil) and (R.Parent.Name = 'F1'));
    R := RequestByPath(C, 'R1');
    AssertTrue('root request parent is the collection', R.Parent = C);
  finally
    C.Free;
  end;
end;

procedure TLoaderTest.TestNestedNoName;
var
  C: TCollection;
  R: TRequest;
begin
  C := Load('upstream-nested-no-name.collection.json');
  try
    AssertEquals(6, C.RequestCount);
    R := FirstRequest(C);
    AssertEquals('(unnamed request)', R.Name);
    AssertEquals('(unnamed folder)', R.Parent.Name);
    AssertEquals('https://upstream-echo.com/get', R.Url.Raw);
    AssertTrue('name placeholder when info has no name', C.Name <> '');
  finally
    C.Free;
  end;
end;

procedure TLoaderTest.TestCanonicalV2;
var
  C: TCollection;
  R: TRequest;
  M: TFPList;
begin
  C := Load('upstream-collection-v2.collection.json');
  try
    AssertEquals('HTTP Status Messages', C.Name);
    AssertEquals(7, C.RequestCount);
    AssertEquals(5, C.Variables.Count);
    AssertEquals('hello-world', C.Variables.ValueOf('var-1'));   // "id"-style variables
    // Two root requests share the name "200 ok": one shorthand string, one object.
    M := TFPList.Create;
    try
      AssertEquals(2, C.FindRequests('200 ok', M));
      R := TRequest(M[0]);
      AssertEquals('GET', R.Method);
      AssertEquals('http://echo.getupstream.com/status/200', R.Url.Raw);
      R := TRequest(M[1]);
      AssertEquals('POST', R.Method);
      AssertTrue(R.Body.Mode = bmUrlEncoded);
      AssertEquals('mate', R.Body.Params.ValueOf('yo'));
    finally
      M.Free;
    end;
    // Two requests named "201" in the same folder: a path lookup finds both.
    M := TFPList.Create;
    try
      AssertEquals(2, C.FindRequests('This is a folder/201', M));
      // First one: header given as a "Name: value\n..." string.
      R := TRequest(M[0]);
      AssertEquals('PUT', R.Method);
      AssertEquals('application/json', R.Headers.ValueOf('Content-Type'));
      AssertTrue('Hawk header line parsed', Pos('Hawk id=', R.Headers.ValueOf('Authorization')) = 1);
      AssertTrue(R.Auth.AuthType = atInherit);
      // Second one: basic auth in the v2.0 object form.
      R := TRequest(M[1]);
      AssertTrue(R.Auth.AuthType = atBasic);
      AssertEquals('yosam', R.Auth.Param('username'));
      AssertEquals('asdhjajsd', R.Auth.Param('password'));
    finally
      M.Free;
    end;
    // Shorthand URL with userinfo, port, query and a {{variable}} in the fragment.
    R := RequestByPath(C, 'This is a folder/400 bad request');
    AssertEquals(3, R.Url.Query.Count);
    AssertEquals('string', R.Url.Query.ValueOf('query'));
    AssertEquals('abcd', R.Url.Query[2].Key);
    AssertEquals('http://shamasis:pass@echo.getupstream.com:9443/status/400/', R.Url.Base);
    // URL object with no "raw": rebuilt from parts.
    R := RequestByPath(C, 'This is a folder/my-folder-2/This is a blank/gg not found');
    AssertEquals('https://sub.example.com.:8443/path/to/document', R.Url.Raw);
    R := RequestByPath(C, 'This is a folder/my-folder-2/Solo Folder/404 not found');
    AssertTrue(R.Auth.AuthType = atOther);
    AssertEquals('hawk', R.Auth.RawType);
  finally
    C.Free;
  end;
end;

procedure TLoaderTest.TestAuthDigestUnsupportedWarning;
var
  C: TCollection;
  R: TRequest;
begin
  C := Load('upstream-auth-digest.collection.json');
  try
    AssertEquals(2, C.RequestCount);
    R := RequestByPath(C, 'Auth: Digest/DigestAuth Request');
    AssertTrue('explicit noauth', R.Auth.AuthType = atNone);
    R := RequestByPath(C, 'Auth: Digest/DigestAuth Success');
    AssertTrue(R.Auth.AuthType = atOther);
    AssertEquals('digest', R.Auth.RawType);
    AssertEquals('upstream', R.Auth.Param('username'));
    AssertEquals('{{echo_digest_realm}}', R.Auth.Param('realm'));
    AssertEquals(1, WarningsContaining('auth type "digest" is not supported'));
  finally
    C.Free;
  end;
end;

procedure TLoaderTest.TestAuthHawk;
var
  C: TCollection;
  R: TRequest;
begin
  C := Load('upstream-auth-hawk.collection.json');
  try
    R := FirstRequest(C);
    AssertTrue(R.Auth.AuthType = atOther);
    AssertEquals('hawk', R.Auth.RawType);
    AssertEquals('dh37fgj492je', R.Auth.Param('authId'));
    AssertEquals('sha256', R.Auth.Param('algorithm'));
  finally
    C.Free;
  end;
end;

procedure TLoaderTest.TestAuthOAuth1;
var
  C: TCollection;
  R: TRequest;
begin
  C := Load('upstream-auth-oauth1.collection.json');
  try
    R := FirstRequest(C);
    AssertTrue(R.Auth.AuthType = atOther);
    AssertEquals('oauth1', R.Auth.RawType);
    AssertEquals('RKCGzna7bv9YD57c', R.Auth.Param('consumerKey'));
    AssertEquals('HMAC-SHA1', R.Auth.Param('signatureMethod'));
  finally
    C.Free;
  end;
end;

procedure TLoaderTest.TestTwitter;
var
  C: TCollection;
  R: TRequest;
begin
  C := Load('twitter-api-v2.collection.json');
  try
    AssertEquals('Twitter API v2', C.Name);
    AssertTrue(C.SchemaVersion = svV21);
    AssertEquals(56, C.RequestCount);
    AssertEquals(5, C.Variables.Count);
    AssertTrue(C.Auth.AuthType = atBearer);
    AssertEquals('{{bearer_token}}', C.Auth.Param('token'));
    R := RequestByPath(C, 'Tweet Lookup/Single Tweet');
    AssertEquals('https://api.twitter.com/2/tweets/:id', R.Url.Raw);
    AssertEquals(1, R.Url.PathVariables.Count);
    AssertEquals('id', R.Url.PathVariables[0].Key);
    AssertTrue('query params loaded', R.Url.Query.Count >= 3);
    AssertFalse('disabled query param kept off', R.Url.Query[0].Enabled);
    AssertTrue('inherits bearer from collection', R.EffectiveAuth = C.Auth);
    R := RequestByPath(C, 'Manage Tweets/Create a Tweet');
    AssertEquals('POST', R.Method);
    AssertTrue(R.Auth.AuthType = atOther);
    AssertEquals('oauth1', R.Auth.RawType);
    AssertEquals('{{consumer_key}}', R.Auth.Param('consumerKey'));   // v2.1 array form
    AssertTrue(R.Body.Mode = bmRaw);
    AssertEquals('json', R.Body.Language);
  finally
    C.Free;
  end;
end;

procedure TLoaderTest.TestTwitterEnvironment;
var
  E: TEnvironment;
begin
  E := LoadEnvironmentFromFile(Fixture('twitter-api-v2.environment.json'));
  try
    AssertEquals(5, E.Variables.Count);
    AssertEquals('consumer_key', E.Variables[0].Key);
    AssertEquals('Your consumer key', E.Variables.ValueOf('consumer_key'));
    AssertTrue(E.Variables[0].Enabled);
    AssertTrue(E.Name <> '');
  finally
    E.Free;
  end;
end;

procedure TLoaderTest.TestEnvironmentRejectedAsCollection;
var
  C: TCollection;
begin
  C := nil;
  try
    try
      C := Load('twitter-api-v2.environment.json');
      Fail('environment file must not load as a collection');
    except
      on E: EMailBoyLoad do
        AssertTrue(Pos('environment', E.Message) > 0);
    end;
  finally
    C.Free;
  end;
end;

procedure TLoaderTest.TestGarbageRaises;
begin
  try
    LoadCollectionFromString('this is not json', nil).Free;
    Fail('garbage must raise');
  except
    on E: EMailBoyLoad do ;
  end;
  try
    LoadCollectionFromString('[1,2,3]', nil).Free;
    Fail('array must raise');
  except
    on E: EMailBoyLoad do ;
  end;
  try
    LoadCollectionFromString('{"hello": "world"}', nil).Free;
    Fail('unrelated object must raise');
  except
    on E: EMailBoyLoad do ;
  end;
end;

procedure TLoaderTest.TestMissingFileRaises;
begin
  try
    LoadCollectionFromFile('does-not-exist.json', nil).Free;
    Fail('missing file must raise');
  except
    on E: EMailBoyLoad do
      AssertTrue(Pos('not found', E.Message) > 0);
  end;
end;

procedure TLoaderTest.TestIsEnvironmentJson;
begin
  AssertTrue(IsEnvironmentJson('{"name":"x","values":[]}'));
  AssertFalse(IsEnvironmentJson('{"info":{},"item":[]}'));
  AssertFalse(IsEnvironmentJson('garbage'));
end;


procedure TLoaderTest.TestSaveEnvironmentRoundTrip;
var
  E, Back: TEnvironment;
  Json: string;
begin
  E := TEnvironment.Create;
  try
    E.Name := 'dev "quoted"';
    E.Variables.Add('host', 'h.test');
    E.Variables.Add('token', 'a=b&c');
    E.Variables.Add('off', 'x').Enabled := False;
    E.Variables.Add('', 'no key, dropped');
    Json := SaveEnvironmentToString(E);
    AssertTrue('is an environment', IsEnvironmentJson(Json));
    AssertTrue('ends with a newline', Json[Length(Json)] = #10);
    Back := LoadEnvironmentFromString(Json);
    try
      AssertEquals('dev "quoted"', Back.Name);
      AssertEquals(3, Back.Variables.Count);
      AssertEquals('h.test', Back.Variables.ValueOf('host'));
      AssertEquals('a=b&c', Back.Variables.ValueOf('token'));
      AssertEquals('off', Back.Variables[2].Key);
      AssertFalse(Back.Variables[2].Enabled);
    finally
      Back.Free;
    end;
  finally
    E.Free;
  end;
end;

procedure TLoaderTest.TestSaveEnvironmentToFile;
var
  E, Back: TEnvironment;
  FileName: string;
begin
  FileName := IncludeTrailingPathDelimiter(GetTempDir) + 'mailboy_env_test.json';
  E := TEnvironment.Create;
  try
    E.Name := 'tmp';
    E.Variables.Add('k', 'v');
    SaveEnvironmentToFile(E, FileName);
    AssertEquals('SourceFile set', FileName, E.SourceFile);
    Back := LoadEnvironmentFromFile(FileName);
    try
      AssertEquals('tmp', Back.Name);
      AssertEquals('v', Back.Variables.ValueOf('k'));
    finally
      Back.Free;
    end;
    DeleteFile(FileName);
    try
      SaveEnvironmentToFile(E, PathDelim + 'nonexistent-dir-mailboy' + PathDelim + 'x.json');
      Fail('expected EMailBoyLoad');
    except
      on EMailBoyLoad do ;
    end;
  finally
    E.Free;
  end;
end;

initialization
  RegisterTest(TLoaderTest);

end.
