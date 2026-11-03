unit test_mbVariables;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry, mbModel, mbVariables;

type
  TVariablesTest = class(TTestCase)
  private
    FScope: TVariableScope;
    FUnresolved: TStringList;
    FColl, FEnv: TKeyValueList;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestSimpleSubstitution;
    procedure TestPrecedenceTopLayerWins;
    procedure TestOverrideViaSetVariable;
    procedure TestUnresolvedStaysLiteralAndIsReported;
    procedure TestNestedValues;
    procedure TestSelfReferenceDoesNotHang;
    procedure TestDisabledVariablesIgnored;
    procedure TestNamesAreCaseSensitive;
    procedure TestJsonBracesAreNotPlaceholders;
    procedure TestUnterminatedBraces;
    procedure TestFindPlaceholders;
    procedure TestDynamicVariables;
    procedure TestEmptyValueIsAValue;
    procedure TestPlaceholderValueCountsAsUndefined;
    procedure TestCollectCollectionPlaceholders;
    procedure TestNewEnvironmentFromCollection;
  end;

implementation

procedure TVariablesTest.SetUp;
begin
  FScope := TVariableScope.Create;
  FUnresolved := TStringList.Create;
  FColl := TKeyValueList.Create;
  FEnv := TKeyValueList.Create;
  FColl.Add('baseUrl', 'https://coll.example');
  FColl.Add('path', '/v1');
  FColl.Add('onlyInColl', 'C');
  FEnv.Add('baseUrl', 'https://env.example');
  FEnv.Add('token', 'abc123');
  FEnv.Add('full', '{{baseUrl}}{{path}}/users');
  FScope.PushLayer('collection', FColl);
  FScope.PushLayer('environment', FEnv);
end;

procedure TVariablesTest.TearDown;
begin
  FEnv.Free;
  FColl.Free;
  FUnresolved.Free;
  FScope.Free;
end;

procedure TVariablesTest.TestSimpleSubstitution;
begin
  AssertEquals('Bearer abc123', FScope.Resolve('Bearer {{token}}', FUnresolved));
  AssertEquals(0, FUnresolved.Count);
  AssertEquals('no placeholders', FScope.Resolve('no placeholders', FUnresolved));
  AssertEquals('', FScope.Resolve('', FUnresolved));
end;

procedure TVariablesTest.TestPrecedenceTopLayerWins;
begin
  AssertEquals('https://env.example/v1', FScope.Resolve('{{baseUrl}}{{path}}'));
  AssertEquals('C', FScope.Resolve('{{onlyInColl}}'));
end;

procedure TVariablesTest.TestOverrideViaSetVariable;
begin
  FScope.SetVariable('token', 'override');
  FScope.SetVariable('fresh', 'new');
  AssertEquals('override new', FScope.Resolve('{{token}} {{fresh}}'));
  AssertEquals('environment layer untouched', 'abc123', FEnv.ValueOf('token'));
end;

procedure TVariablesTest.TestUnresolvedStaysLiteralAndIsReported;
begin
  AssertEquals('https://env.example/{{missing}}/x/{{also}}',
    FScope.Resolve('{{baseUrl}}/{{missing}}/x/{{also}}', FUnresolved));
  AssertEquals(2, FUnresolved.Count);
  AssertEquals('missing', FUnresolved[0]);
  AssertEquals('also', FUnresolved[1]);
  FUnresolved.Clear;
  FScope.Resolve('{{missing}} {{missing}}', FUnresolved);
  AssertEquals('reported once', 1, FUnresolved.Count);
end;

procedure TVariablesTest.TestNestedValues;
begin
  AssertEquals('https://env.example/v1/users', FScope.Resolve('{{full}}', FUnresolved));
  AssertEquals(0, FUnresolved.Count);
end;

procedure TVariablesTest.TestSelfReferenceDoesNotHang;
begin
  FScope.SetVariable('loop', 'x{{loop}}');
  FScope.SetVariable('a', '{{b}}');
  FScope.SetVariable('b', '{{a}}');
  // Must terminate; exact output is bounded by MaxDepth, so only check it returns.
  AssertTrue(Length(FScope.Resolve('{{loop}}')) > 0);
  AssertTrue(Length(FScope.Resolve('{{a}}')) > 0);
end;

procedure TVariablesTest.TestDisabledVariablesIgnored;
var
  L: TKeyValueList;
  S: TVariableScope;
begin
  L := TKeyValueList.Create;
  S := TVariableScope.Create;
  try
    L.Add('on', '1');
    L.Add('off', '2').Enabled := False;
    S.PushLayer('x', L);
    AssertEquals('1 {{off}}', S.Resolve('{{on}} {{off}}'));
  finally
    S.Free;
    L.Free;
  end;
end;

procedure TVariablesTest.TestNamesAreCaseSensitive;
begin
  AssertEquals('{{Token}}', FScope.Resolve('{{Token}}', FUnresolved));
  AssertEquals(1, FUnresolved.Count);
end;

procedure TVariablesTest.TestJsonBracesAreNotPlaceholders;
const
  Body = '{"a": {"b": {{token}}}, "c": {{"d": 1}}}';
begin
  // {{token}} resolves; the "{{" before "d" is not a placeholder because its
  // supposed name would contain a brace pair.
  AssertEquals('{"a": {"b": abc123}, "c": {{"d": 1}}}', FScope.Resolve(Body, FUnresolved));
  AssertEquals(0, FUnresolved.Count);
end;

procedure TVariablesTest.TestUnterminatedBraces;
begin
  AssertEquals('{{token', FScope.Resolve('{{token', FUnresolved));
  AssertEquals('abc123 {{', FScope.Resolve('{{token}} {{', FUnresolved));
  AssertEquals(0, FUnresolved.Count);
end;

procedure TVariablesTest.TestFindPlaceholders;
var
  Names: TStringList;
begin
  Names := TStringList.Create;
  try
    TVariableScope.FindPlaceholders('{{a}}/{{b}}/{{a}}/{{$guid}} {{', Names);
    AssertEquals(3, Names.Count);
    AssertEquals('a', Names[0]);
    AssertEquals('b', Names[1]);
    AssertEquals('$guid', Names[2]);
  finally
    Names.Free;
  end;
end;

procedure TVariablesTest.TestDynamicVariables;
var
  S: string;
begin
  S := FScope.Resolve('{{$guid}}', FUnresolved);
  AssertEquals(36, Length(S));
  AssertEquals('-', S[9]);
  S := FScope.Resolve('{{$timestamp}}', FUnresolved);
  AssertTrue('timestamp is numeric and recent', StrToInt64(S) > 1700000000);
  S := FScope.Resolve('{{$randomInt}}', FUnresolved);
  AssertTrue('randomInt in range', (StrToInt(S) >= 0) and (StrToInt(S) <= 1000));
  AssertEquals(0, FUnresolved.Count);
  AssertEquals('{{$unknownDynamic}}', FScope.Resolve('{{$unknownDynamic}}', FUnresolved));
  AssertEquals(1, FUnresolved.Count);
end;

procedure TVariablesTest.TestEmptyValueIsAValue;
begin
  FScope.SetVariable('empty', '');
  AssertEquals('[]', FScope.Resolve('[{{empty}}]', FUnresolved));
  AssertEquals(0, FUnresolved.Count);
end;


procedure TVariablesTest.TestPlaceholderValueCountsAsUndefined;
begin
  FEnv.Add('host', PlaceholderValue('host'));
  FEnv.Add('token', 'real');
  FScope.PushLayer('environment', FEnv);
  AssertEquals('https://{{host}}/x?t=real', FScope.Resolve('https://{{host}}/x?t={{token}}', FUnresolved));
  AssertEquals(1, FUnresolved.Count);
  AssertEquals('host', FUnresolved[0]);
  AssertTrue(IsPlaceholderValue('host', 'put the host value here'));
  AssertFalse('other names do not match', IsPlaceholderValue('port', 'put the host value here'));
  AssertFalse(IsPlaceholderValue('host', ''));
end;

procedure TVariablesTest.TestCollectCollectionPlaceholders;
var
  C: TCollection;
  F: TFolder;
  R: TRequest;
  Names: TStringList;
begin
  C := TCollection.Create;
  Names := TStringList.Create;
  try
    C.Variables.Add('base', 'https://{{host}}:{{port}}');
    C.Auth.Params.Add('token', '{{token}}');
    F := C.AddFolder('F');
    F.Auth.Params.Add('username', '{{user}}');
    R := F.AddRequest('R');
    R.Url.Raw := '{{base}}/v1/{{$guid}}/{{host}}';
    R.Url.Query.Add('q', '{{q}}');
    R.Url.PathVariables.Add('id', '{{id}}');
    R.Headers.Add('X-{{hk}}', '{{hv}}');
    R.Body.Raw := '{"a": {{amount}}, "b": "{{amount}}"}';
    R.Body.Params.Add('f', '{{formval}}');
    R.Body.FilePath := '{{dir}}/x.bin';
    R.Auth.Params.Add('password', '{{pw}}');
    CollectCollectionPlaceholders(C, Names);
    AssertEquals('host,port,token,user,base,q,id,hk,hv,amount,formval,dir,pw', Names.CommaText);
  finally
    Names.Free;
    C.Free;
  end;
end;

procedure TVariablesTest.TestNewEnvironmentFromCollection;
var
  C: TCollection;
  R: TRequest;
  E: TEnvironment;
begin
  C := TCollection.Create;
  try
    C.Name := 'Shop';
    C.Variables.Add('host', 'shop.test');
    R := C.AddRequest('R');
    R.Url.Raw := 'https://{{host}}/{{path}}';
    E := NewEnvironmentFromCollection(C);
    try
      AssertEquals('Shop environment', E.Name);
      AssertEquals(2, E.Variables.Count);
      AssertEquals('host', E.Variables[0].Key);
      AssertEquals('collection value carried over', 'shop.test', E.Variables[0].Value);
      AssertEquals('path', E.Variables[1].Key);
      AssertEquals('put the path value here', E.Variables[1].Value);
      AssertTrue(E.Variables[1].Enabled);
    finally
      E.Free;
    end;
    E := NewEnvironmentFromCollection(nil);
    try
      AssertEquals(0, E.Variables.Count);
    finally
      E.Free;
    end;
  finally
    C.Free;
  end;
end;

initialization
  RegisterTest(TVariablesTest);

end.
