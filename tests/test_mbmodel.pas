unit test_mbModel;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry, mbModel;

type
  TModelTest = class(TTestCase)
  published
    procedure TestKeyValueListFindIsCaseInsensitiveAndLastWins;
    procedure TestKeyValueListSkipsDisabled;
    procedure TestUrlBaseStripsQueryAndFragment;
    procedure TestPathExcludesCollectionRoot;
    procedure TestEffectiveAuthWalksUp;
    procedure TestEffectiveHookNearestWins;
    procedure TestFindRequestsByNameAndPath;
    procedure TestCollectRequestsIsDepthFirstInOrder;
  end;

implementation

procedure TModelTest.TestKeyValueListFindIsCaseInsensitiveAndLastWins;
var
  L: TKeyValueList;
begin
  L := TKeyValueList.Create;
  try
    L.Add('Content-Type', 'text/plain');
    L.Add('content-type', 'application/json');
    AssertEquals('application/json', L.ValueOf('CONTENT-TYPE'));
    AssertEquals('dflt', L.ValueOf('missing', 'dflt'));
    AssertNull(L.Find('missing'));
    AssertEquals(2, L.Count);
  finally
    L.Free;
  end;
end;

procedure TModelTest.TestKeyValueListSkipsDisabled;
var
  L: TKeyValueList;
begin
  L := TKeyValueList.Create;
  try
    L.Add('a', '1');
    L.Add('a', '2').Enabled := False;
    AssertEquals('1', L.ValueOf('a'));
  finally
    L.Free;
  end;
end;

procedure TModelTest.TestUrlBaseStripsQueryAndFragment;
var
  U: TUrl;
begin
  U := TUrl.Create;
  try
    U.Raw := 'https://x.example/a/b?c=1&d=2#frag';
    AssertEquals('https://x.example/a/b', U.Base);
    U.Raw := 'https://x.example/a#frag';
    AssertEquals('https://x.example/a', U.Base);
    U.Raw := 'https://x.example/a';
    AssertEquals('https://x.example/a', U.Base);
  finally
    U.Free;
  end;
end;

procedure TModelTest.TestPathExcludesCollectionRoot;
var
  C: TCollection;
  F, G: TFolder;
  R: TRequest;
begin
  C := TCollection.Create;
  try
    C.Name := 'Coll';
    F := C.AddFolder('Payments');
    G := F.AddFolder('Cards');
    R := G.AddRequest('sendTransaction');
    AssertEquals('Payments/Cards/sendTransaction', R.Path);
    AssertEquals('Payments/Cards', G.Path);
    AssertEquals('Payments', F.Path);
    AssertEquals('Coll', C.Path);
    R := C.AddRequest('root');
    AssertEquals('root', R.Path);
  finally
    C.Free;
  end;
end;

procedure TModelTest.TestEffectiveAuthWalksUp;
var
  C: TCollection;
  F: TFolder;
  R: TRequest;
begin
  C := TCollection.Create;
  try
    C.Auth.AuthType := atBearer;
    C.Auth.Params.Add('token', 'T');
    F := C.AddFolder('F');
    R := F.AddRequest('R');
    AssertTrue('inherits from collection', R.EffectiveAuth = C.Auth);
    AssertEquals('T', R.EffectiveAuth.Param('token'));
    F.Auth.AuthType := atNone;
    AssertTrue('folder wins over collection', R.EffectiveAuth = F.Auth);
    R.Auth.AuthType := atBasic;
    AssertTrue('request wins over folder', R.EffectiveAuth = R.Auth);
  finally
    C.Free;
  end;
end;

procedure TModelTest.TestEffectiveHookNearestWins;
var
  C: TCollection;
  F, G: TFolder;
  R: TRequest;
  Src: string;
begin
  C := TCollection.Create;
  try
    F := C.AddFolder('Payments');
    G := F.AddFolder('Cards');
    R := G.AddRequest('charge');
    AssertEquals('none by default', '', R.EffectiveHook(Src));
    AssertEquals('', Src);
    C.HookCommand := '/h/coll';
    AssertEquals('/h/coll', R.EffectiveHook(Src));
    AssertEquals('collection', Src);
    F.HookCommand := '/h/pay';
    AssertEquals('/h/pay', R.EffectiveHook(Src));
    AssertEquals('folder "Payments"', Src);
    G.HookCommand := '/h/cards';
    AssertEquals('nearest folder wins', '/h/cards', R.EffectiveHook(Src));
    AssertEquals('folder "Cards"', Src);
    R.HookCommand := '/h/req';
    AssertEquals('request wins over folder', '/h/req', R.EffectiveHook(Src));
    AssertEquals('request', Src);
    R.HookCommand := '';
    G.HookCommand := '';
    AssertEquals('clearing falls back up the chain', '/h/pay', R.EffectiveHook(Src));
    AssertEquals('folder applies to itself too', '/h/pay', F.EffectiveHook(Src));
    AssertEquals('folder "Payments"', Src);
  finally
    C.Free;
  end;
end;

procedure TModelTest.TestFindRequestsByNameAndPath;
var
  C: TCollection;
  M: TFPList;
begin
  C := TCollection.Create;
  M := TFPList.Create;
  try
    C.AddFolder('A').AddRequest('dup');
    C.AddFolder('B').AddRequest('dup');
    C.AddRequest('solo');
    AssertEquals(2, C.FindRequests('dup', M));
    M.Clear;
    AssertEquals(1, C.FindRequests('B/dup', M));
    AssertEquals('B/dup', TRequest(M[0]).Path);
    M.Clear;
    AssertEquals(1, C.FindRequests('solo', M));
    M.Clear;
    AssertEquals(0, C.FindRequests('nope', M));
    AssertEquals(3, C.RequestCount);
  finally
    M.Free;
    C.Free;
  end;
end;

procedure TModelTest.TestCollectRequestsIsDepthFirstInOrder;
var
  C: TCollection;
  F: TFolder;
  L: TFPList;
begin
  C := TCollection.Create;
  L := TFPList.Create;
  try
    C.AddRequest('r0');
    F := C.AddFolder('f');
    F.AddRequest('r1');
    F.AddFolder('g').AddRequest('r2');
    C.AddRequest('r3');
    C.CollectRequests(L);
    AssertEquals(4, L.Count);
    AssertEquals('r0', TRequest(L[0]).Name);
    AssertEquals('r1', TRequest(L[1]).Name);
    AssertEquals('r2', TRequest(L[2]).Name);
    AssertEquals('r3', TRequest(L[3]).Name);
  finally
    L.Free;
    C.Free;
  end;
end;

initialization
  RegisterTest(TModelTest);

end.
