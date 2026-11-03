unit mbHook;

// The hook: before a request is sent and after the response comes back,
// mailBoy can run a program the user names, hand it everything about the
// request as JSON on stdin, and read back JSON on stdout saying what to
// change. Protocol version 1. The contract is the text in mbHookHelp.
//
// This unit builds the input, runs the program through mbRunner, parses the
// output and applies it to a resolved request and a variable scope. It
// never picks a program by itself; Command empty means nothing runs.

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, contnrs, fpjson, jsonparser, base64,
  mbModel, mbVariables, mbRequestBuilder, mbRunner, mbResponse;

const
  HookProtocol = 1;
  HookStdOutExcerpt = 500;   // bytes of unparseable stdout kept for the report

type
  THookPhase = (hpBefore, hpAfter);

  THookContext = record
    CollectionFile: string;
    EnvironmentFile: string;
    Proxy: string;           // what curl will use, '' = none
  end;

  THookTest = class
  public
    Name: string;
    Passed: Boolean;
    Error: string;
  end;

  THookHeaderOp = class
  public
    Key: string;
    Value: string;
    Remove: Boolean;         // {"key": "X", "value": null}
  end;

  THookVarOp = class
  public
    Scope: string;           // session | environment | collection
    Name: string;
    Value: string;
    Unset: Boolean;
  end;

  THookResult = class
  private
    FConsole: TStringList;
    FTests: TFPObjectList;
    FHeaderOps: TFPObjectList;
    FVarOps: TFPObjectList;
    function GetTest(Index: Integer): THookTest;
    function GetHeaderOp(Index: Integer): THookHeaderOp;
    function GetVarOp(Index: Integer): THookVarOp;
  public
    Phase: THookPhase;
    Ran: Boolean;            // a program was started
    Ok: Boolean;             // ran, exited 0, output usable, no error object
    Command: string;
    ExitCode: Integer;
    ElapsedMs: Integer;
    TimedOut: Boolean;
    StdErr: string;          // complete, untrimmed
    StdOutExcerpt: string;   // first bytes of stdout when it was not JSON
    ErrorMessage: string;    // one line, what went wrong
    ErrorDetail: string;     // from the program's error object, if any
    // Parsed request changes (before phase only)
    HasMethod: Boolean;  Method: string;
    HasUrl: Boolean;     Url: string;
    HasBody: Boolean;    BodyMode: TBodyMode; BodyText: string; BodyFields: TKeyValueList; BodyFilePath: string;
    HeadersCleared: Boolean;   // "headers": null
    constructor Create;
    destructor Destroy; override;
    function TestCount: Integer;
    function HeaderOpCount: Integer;
    function VarOpCount: Integer;
    function FailedTestCount: Integer;
    property Console: TStringList read FConsole;
    property Tests[Index: Integer]: THookTest read GetTest;
    property HeaderOps[Index: Integer]: THookHeaderOp read GetHeaderOp;
    property VarOps[Index: Integer]: THookVarOp read GetVarOp;
  end;

  THookRunner = class
  public
    Command: string;         // path to an executable; '' = no hook
    TimeoutSec: Integer;     // default 30
    constructor Create;
    function Enabled: Boolean;
    // Runs the program for one phase and applies the result to AResolved
    // (before phase) and AScope. The caller frees the result.
    function RunBefore(AResolved: TResolvedRequest; AScope: TVariableScope;
      AReq: TRequest; const AContext: THookContext): THookResult;
    function RunAfter(AResolved: TResolvedRequest; AResponse: TResponse;
      AScope: TVariableScope; AReq: TRequest; const AContext: THookContext): THookResult;
  end;

// The pieces, exposed for tests.
function BuildHookInput(APhase: THookPhase; AResolved: TResolvedRequest; AResponse: TResponse;
  AScope: TVariableScope; AReq: TRequest; const AContext: THookContext): string;
// Fills AResult from the program's stdout. False (with ErrorMessage) on bad output.
function ParseHookOutput(const AJson: string; AResult: THookResult): Boolean;
// Applies header, method, url and body changes to a resolved request.
procedure ApplyRequestChanges(AResult: THookResult; AResolved: TResolvedRequest);
// Applies variable set/unset operations; unknown scopes are reported in AWarnings.
procedure ApplyVariableChanges(AResult: THookResult; AScope: TVariableScope; AWarnings: TStrings);
// The proxy curl would use for this URL, from the environment, or ''.
function ProxyForUrl(const AUrl: string): string;
function IsValidUtf8(const S: string): Boolean;
function HookPhaseName(APhase: THookPhase): string;

implementation

function HookPhaseName(APhase: THookPhase): string;
begin
  if APhase = hpBefore then Result := 'before' else Result := 'after';
end;

function IsValidUtf8(const S: string): Boolean;
var
  I, L, N, K: Integer;
  B: Byte;
begin
  I := 1;
  L := Length(S);
  while I <= L do
  begin
    B := Ord(S[I]);
    if B < $80 then
      N := 0
    else if (B and $E0) = $C0 then
    begin
      N := 1;
      if B < $C2 then Exit(False);           // overlong
    end
    else if (B and $F0) = $E0 then
      N := 2
    else if (B and $F8) = $F0 then
    begin
      N := 3;
      if B > $F4 then Exit(False);
    end
    else
      Exit(False);
    for K := 1 to N do
    begin
      if I + K > L then Exit(False);
      if (Ord(S[I + K]) and $C0) <> $80 then Exit(False);
    end;
    Inc(I, N + 1);
  end;
  Result := True;
end;

function ProxyForUrl(const AUrl: string): string;
var
  Https: Boolean;
begin
  Https := Pos('https://', LowerCase(AUrl)) = 1;
  Result := '';
  if Https then
  begin
    Result := GetEnvironmentVariable('https_proxy');
    if Result = '' then Result := GetEnvironmentVariable('HTTPS_PROXY');
  end
  else
    Result := GetEnvironmentVariable('http_proxy');
  if Result = '' then Result := GetEnvironmentVariable('all_proxy');
  if Result = '' then Result := GetEnvironmentVariable('ALL_PROXY');
end;

{ THookResult }

constructor THookResult.Create;
begin
  inherited Create;
  FConsole := TStringList.Create;
  FTests := TFPObjectList.Create(True);
  FHeaderOps := TFPObjectList.Create(True);
  FVarOps := TFPObjectList.Create(True);
  BodyFields := TKeyValueList.Create;
  ExitCode := -1;
end;

destructor THookResult.Destroy;
begin
  BodyFields.Free;
  FVarOps.Free;
  FHeaderOps.Free;
  FTests.Free;
  FConsole.Free;
  inherited Destroy;
end;

function THookResult.GetTest(Index: Integer): THookTest;
begin
  Result := THookTest(FTests[Index]);
end;

function THookResult.GetHeaderOp(Index: Integer): THookHeaderOp;
begin
  Result := THookHeaderOp(FHeaderOps[Index]);
end;

function THookResult.GetVarOp(Index: Integer): THookVarOp;
begin
  Result := THookVarOp(FVarOps[Index]);
end;

function THookResult.TestCount: Integer;
begin
  Result := FTests.Count;
end;

function THookResult.HeaderOpCount: Integer;
begin
  Result := FHeaderOps.Count;
end;

function THookResult.VarOpCount: Integer;
begin
  Result := FVarOps.Count;
end;

function THookResult.FailedTestCount: Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to FTests.Count - 1 do
    if not Tests[I].Passed then Inc(Result);
end;

{ ---- input ---- }

function KeyValuesToJson(AList: TKeyValueList; AIncludeFile: Boolean): TJSONArray;
var
  I: Integer;
  O: TJSONObject;
begin
  Result := TJSONArray.Create;
  for I := 0 to AList.Count - 1 do
  begin
    O := TJSONObject.Create;
    O.Add('key', AList[I].Key);
    O.Add('value', AList[I].Value);
    if AIncludeFile then
      O.Add('file', AList[I].IsFile);
    Result.Add(O);
  end;
end;

function BodyToJson(AResolved: TResolvedRequest): TJSONObject;
begin
  Result := TJSONObject.Create;
  case AResolved.BodyMode of
    bmRaw, bmGraphQL:
      begin
        Result.Add('mode', 'raw');
        Result.Add('raw', AResolved.BodyText);
      end;
    bmUrlEncoded:
      begin
        Result.Add('mode', 'urlencoded');
        Result.Add('raw', AResolved.BodyText);    // already k=v&k=v encoded
      end;
    bmFormData:
      begin
        Result.Add('mode', 'formdata');
        Result.Add('fields', KeyValuesToJson(AResolved.FormFields, True));
      end;
    bmFile:
      begin
        Result.Add('mode', 'file');
        Result.Add('path', AResolved.BodyFilePath);
      end;
  else
    Result.Add('mode', 'none');
  end;
end;

function AuthToJson(AResolved: TResolvedRequest): TJSONObject;
begin
  Result := TJSONObject.Create;
  case AResolved.AuthType of
    atBasic:
      begin
        Result.Add('type', 'basic');
        Result.Add('username', AResolved.AuthUser);
        Result.Add('password', AResolved.AuthPassword);
      end;
    atBearer:
      begin
        Result.Add('type', 'bearer');
        Result.Add('token', AResolved.BearerToken);
      end;
    atOther:
      Result.Add('type', 'unsupported');
  else
    Result.Add('type', 'none');
  end;
end;

function LayerToJson(AScope: TVariableScope; const ALayer: string): TJSONObject;
var
  L: TStringList;
  I: Integer;
begin
  Result := TJSONObject.Create;
  if AScope = nil then Exit;
  L := TStringList.Create;
  try
    AScope.CopyLayer(ALayer, L);
    for I := 0 to L.Count - 1 do
      Result.Add(L.Names[I], L.ValueFromIndex[I]);
  finally
    L.Free;
  end;
end;

// Script chain: collection first, then folders from the top down, then the request.
procedure ScriptChain(AReq: TRequest; APre: Boolean; AArr: TJSONArray);
var
  Chain: TFPList;
  Item: TCollectionItem;
  I: Integer;
  O: TJSONObject;
  Code, Source: string;
begin
  if AReq = nil then Exit;
  Chain := TFPList.Create;
  try
    Item := AReq;
    while Item <> nil do
    begin
      Chain.Insert(0, Item);
      Item := Item.Parent;
    end;
    for I := 0 to Chain.Count - 1 do
    begin
      Item := TCollectionItem(Chain[I]);
      if APre then Code := Item.PreRequestScript else Code := Item.TestScript;
      if Code = '' then Continue;
      if Item.Parent = nil then
        Source := 'collection'
      else if Item.IsFolder then
        Source := 'folder "' + Item.Path + '"'
      else
        Source := 'request "' + Item.Name + '"';
      O := TJSONObject.Create;
      O.Add('source', Source);
      O.Add('code', Code);
      AArr.Add(O);
    end;
  finally
    Chain.Free;
  end;
end;

function ResponseToJson(AResponse: TResponse): TJSONObject;
var
  H: TJSONArray;
  I: Integer;
  O: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('status', AResponse.StatusCode);
  Result.Add('statusText', AResponse.StatusText);
  Result.Add('httpVersion', AResponse.HttpVersion);
  H := TJSONArray.Create;
  for I := 0 to AResponse.Headers.Count - 1 do
  begin
    O := TJSONObject.Create;
    O.Add('key', AResponse.Headers.Names[I]);
    O.Add('value', AResponse.Headers.ValueFromIndex[I]);
    H.Add(O);
  end;
  Result.Add('headers', H);
  if IsValidUtf8(AResponse.Body) then
    Result.Add('body', AResponse.Body)
  else
  begin
    Result.Add('body', EncodeStringBase64(AResponse.Body));
    Result.Add('bodyEncoding', 'base64');
  end;
  Result.Add('elapsedMs', AResponse.ElapsedMs);
end;

function BuildHookInput(APhase: THookPhase; AResolved: TResolvedRequest; AResponse: TResponse;
  AScope: TVariableScope; AReq: TRequest; const AContext: THookContext): string;
var
  Root, R, V, S, C: TJSONObject;
  Pre, Tst: TJSONArray;
begin
  Root := TJSONObject.Create;
  try
    Root.Add('protocol', HookProtocol);
    Root.Add('phase', HookPhaseName(APhase));

    R := TJSONObject.Create;
    if AReq <> nil then
    begin
      R.Add('name', AReq.Name);
      R.Add('path', AReq.Path);
    end
    else
    begin
      R.Add('name', '');
      R.Add('path', '');
    end;
    R.Add('method', AResolved.Method);
    R.Add('url', AResolved.Url);
    R.Add('headers', KeyValuesToJson(AResolved.Headers, False));
    R.Add('body', BodyToJson(AResolved));
    R.Add('auth', AuthToJson(AResolved));
    Root.Add('request', R);

    if (APhase = hpAfter) and (AResponse <> nil) then
      Root.Add('response', ResponseToJson(AResponse))
    else
      Root.Add('response', TJSONNull.Create);

    V := TJSONObject.Create;
    V.Add('collection', LayerToJson(AScope, 'collection'));
    V.Add('environment', LayerToJson(AScope, 'environment'));
    V.Add('session', LayerToJson(AScope, 'session'));
    Root.Add('variables', V);

    S := TJSONObject.Create;
    Pre := TJSONArray.Create;
    Tst := TJSONArray.Create;
    ScriptChain(AReq, True, Pre);
    ScriptChain(AReq, False, Tst);
    S.Add('prerequest', Pre);
    S.Add('test', Tst);
    Root.Add('scripts', S);

    C := TJSONObject.Create;
    if AContext.CollectionFile <> '' then
      C.Add('collection', AContext.CollectionFile)
    else
      C.Add('collection', TJSONNull.Create);
    if AContext.EnvironmentFile <> '' then
      C.Add('environment', AContext.EnvironmentFile)
    else
      C.Add('environment', TJSONNull.Create);
    if AContext.Proxy <> '' then
      C.Add('proxy', AContext.Proxy)
    else
      C.Add('proxy', TJSONNull.Create);
    Root.Add('context', C);

    Result := Root.AsJSON;
  finally
    Root.Free;
  end;
end;

{ ---- output ---- }

function JStrOf(D: TJSONData; const Default: string = ''): string;
begin
  if (D = nil) or D.IsNull then
    Result := Default
  else if D.JSONType in [jtString, jtNumber, jtBoolean] then
    Result := D.AsString
  else
    Result := D.AsJSON;
end;

procedure ParseHeaders(D: TJSONData; AResult: THookResult);
var
  I: Integer;
  O: TJSONObject;
  Op: THookHeaderOp;
  V: TJSONData;
begin
  if D = nil then Exit;
  if D.IsNull then
  begin
    AResult.HeadersCleared := True;
    Exit;
  end;
  if D.JSONType <> jtArray then Exit;
  for I := 0 to TJSONArray(D).Count - 1 do
  begin
    if TJSONArray(D)[I].JSONType <> jtObject then Continue;
    O := TJSONObject(TJSONArray(D)[I]);
    if JStrOf(O.Find('key')) = '' then Continue;
    Op := THookHeaderOp.Create;
    Op.Key := JStrOf(O.Find('key'));
    V := O.Find('value');
    Op.Remove := (V = nil) or V.IsNull;
    if not Op.Remove then Op.Value := JStrOf(V);
    AResult.FHeaderOps.Add(Op);
  end;
end;

procedure ParseBody(D: TJSONData; AResult: THookResult);
var
  O: TJSONObject;
  Mode: string;
  F: TJSONData;
  I: Integer;
  FO: TJSONObject;
  KV: TKeyValue;
begin
  if (D = nil) then Exit;
  AResult.HasBody := True;
  AResult.BodyMode := bmNone;
  AResult.BodyText := '';
  AResult.BodyFields.Clear;
  if D.IsNull then Exit;
  if D.JSONType = jtString then
  begin
    // Shorthand: a bare string is a raw body.
    AResult.BodyMode := bmRaw;
    AResult.BodyText := D.AsString;
    Exit;
  end;
  if D.JSONType <> jtObject then Exit;
  O := TJSONObject(D);
  Mode := LowerCase(JStrOf(O.Find('mode'), 'raw'));
  if Mode = 'raw' then
  begin
    AResult.BodyMode := bmRaw;
    AResult.BodyText := JStrOf(O.Find('raw'));
  end
  else if Mode = 'urlencoded' then
  begin
    AResult.BodyMode := bmUrlEncoded;
    AResult.BodyText := JStrOf(O.Find('raw'));
  end
  else if Mode = 'formdata' then
  begin
    AResult.BodyMode := bmFormData;
    F := O.Find('fields');
    if (F <> nil) and (F.JSONType = jtArray) then
      for I := 0 to TJSONArray(F).Count - 1 do
        if TJSONArray(F)[I].JSONType = jtObject then
        begin
          FO := TJSONObject(TJSONArray(F)[I]);
          KV := TKeyValue.Create(JStrOf(FO.Find('key')), JStrOf(FO.Find('value')));
          KV.IsFile := (FO.Find('file') <> nil) and (FO.Find('file').JSONType = jtBoolean)
            and FO.Find('file').AsBoolean;
          AResult.BodyFields.Add(KV);
        end;
  end
  else if Mode = 'file' then
  begin
    AResult.BodyMode := bmFile;
    AResult.BodyFilePath := JStrOf(O.Find('path'));
  end
  else
    AResult.BodyMode := bmNone;
end;

procedure ParseVariables(D: TJSONData; AResult: THookResult);
var
  O: TJSONObject;

  procedure ReadList(const AKey: string; AUnset: Boolean);
  var
    A: TJSONData;
    E: TJSONObject;
    I: Integer;
    Op: THookVarOp;
  begin
    A := O.Find(AKey);
    if (A = nil) or (A.JSONType <> jtArray) then Exit;
    for I := 0 to TJSONArray(A).Count - 1 do
    begin
      if TJSONArray(A)[I].JSONType <> jtObject then Continue;
      E := TJSONObject(TJSONArray(A)[I]);
      if JStrOf(E.Find('name')) = '' then Continue;
      Op := THookVarOp.Create;
      Op.Scope := LowerCase(JStrOf(E.Find('scope'), 'session'));
      Op.Name := JStrOf(E.Find('name'));
      Op.Value := JStrOf(E.Find('value'));
      Op.Unset := AUnset;
      AResult.FVarOps.Add(Op);
    end;
  end;

begin
  if (D = nil) or (D.JSONType <> jtObject) then Exit;
  O := TJSONObject(D);
  ReadList('set', False);
  ReadList('unset', True);
end;

procedure ParseTests(D: TJSONData; AResult: THookResult);
var
  I: Integer;
  O: TJSONObject;
  T: THookTest;
  P: TJSONData;
begin
  if (D = nil) or (D.JSONType <> jtArray) then Exit;
  for I := 0 to TJSONArray(D).Count - 1 do
  begin
    if TJSONArray(D)[I].JSONType <> jtObject then Continue;
    O := TJSONObject(TJSONArray(D)[I]);
    T := THookTest.Create;
    T.Name := JStrOf(O.Find('name'), 'test ' + IntToStr(I + 1));
    P := O.Find('passed');
    T.Passed := (P <> nil) and (P.JSONType = jtBoolean) and P.AsBoolean;
    T.Error := JStrOf(O.Find('error'));
    AResult.FTests.Add(T);
  end;
end;

function ParseHookOutput(const AJson: string; AResult: THookResult): Boolean;
var
  Data: TJSONData;
  Root, R, E: TJSONObject;
  D: TJSONData;
  I: Integer;
begin
  Result := False;
  if Trim(AJson) = '' then
    Exit(True);                         // empty stdout means {}
  try
    Data := GetJSON(AJson);
  except
    on Ex: Exception do
    begin
      AResult.ErrorMessage := 'hook output is not valid JSON: ' + Ex.Message;
      AResult.StdOutExcerpt := Copy(AJson, 1, HookStdOutExcerpt);
      Exit;
    end;
  end;
  if Data = nil then Exit(True);
  try
    if Data.JSONType <> jtObject then
    begin
      AResult.ErrorMessage := 'hook output is not a JSON object';
      AResult.StdOutExcerpt := Copy(AJson, 1, HookStdOutExcerpt);
      Exit;
    end;
    Root := TJSONObject(Data);
    D := Root.Find('protocol');
    if (D <> nil) and not D.IsNull and ((D.JSONType <> jtNumber) or (D.AsInteger <> HookProtocol)) then
    begin
      AResult.ErrorMessage := Format('hook speaks protocol %s, mailBoy speaks %d', [JStrOf(D), HookProtocol]);
      Exit;
    end;
    D := Root.Find('request');
    if (D <> nil) and (D.JSONType = jtObject) then
    begin
      R := TJSONObject(D);
      D := R.Find('method');
      if (D <> nil) and not D.IsNull then
      begin
        AResult.HasMethod := True;
        AResult.Method := UpperCase(Trim(JStrOf(D)));
      end;
      D := R.Find('url');
      if (D <> nil) and not D.IsNull then
      begin
        AResult.HasUrl := True;
        AResult.Url := JStrOf(D);
      end;
      ParseHeaders(R.Find('headers'), AResult);
      ParseBody(R.Find('body'), AResult);
    end;
    ParseVariables(Root.Find('variables'), AResult);
    D := Root.Find('console');
    if (D <> nil) and (D.JSONType = jtArray) then
      for I := 0 to TJSONArray(D).Count - 1 do
        AResult.FConsole.Add(JStrOf(TJSONArray(D)[I]))
    else if (D <> nil) and (D.JSONType = jtString) then
      AResult.FConsole.Add(D.AsString);
    ParseTests(Root.Find('tests'), AResult);
    D := Root.Find('error');
    if (D <> nil) and not D.IsNull then
    begin
      if D.JSONType = jtObject then
      begin
        E := TJSONObject(D);
        AResult.ErrorMessage := JStrOf(E.Find('message'), 'hook reported an error');
        AResult.ErrorDetail := JStrOf(E.Find('detail'));
      end
      else
        AResult.ErrorMessage := JStrOf(D);
      Exit;                             // parsed fine, but the hook said no
    end;
    Result := True;
  finally
    Data.Free;
  end;
end;

{ ---- apply ---- }

procedure ApplyRequestChanges(AResult: THookResult; AResolved: TResolvedRequest);
var
  I, J: Integer;
  Op: THookHeaderOp;
  KV: TKeyValue;
begin
  if AResult.HasMethod and (AResult.Method <> '') then
    AResolved.Method := AResult.Method;
  if AResult.HasUrl and (AResult.Url <> '') then
    AResolved.Url := AResult.Url;
  if AResult.HeadersCleared then
    AResolved.Headers.Clear;
  for I := 0 to AResult.HeaderOpCount - 1 do
  begin
    Op := AResult.HeaderOps[I];
    // Replace every existing entry with that key (case-insensitive) by the
    // single new one, or remove them all.
    for J := AResolved.Headers.Count - 1 downto 0 do
      if SameText(AResolved.Headers[J].Key, Op.Key) then
        AResolved.Headers.Delete(J);
    if not Op.Remove then
      AResolved.Headers.Add(Op.Key, Op.Value);
  end;
  if AResult.HasBody then
  begin
    AResolved.BodyMode := AResult.BodyMode;
    AResolved.BodyText := AResult.BodyText;
    AResolved.BodyFilePath := AResult.BodyFilePath;
    AResolved.FormFields.Clear;
    for I := 0 to AResult.BodyFields.Count - 1 do
    begin
      KV := TKeyValue.Create(AResult.BodyFields[I].Key, AResult.BodyFields[I].Value);
      KV.IsFile := AResult.BodyFields[I].IsFile;
      AResolved.FormFields.Add(KV);
    end;
  end;
end;

procedure ApplyVariableChanges(AResult: THookResult; AScope: TVariableScope; AWarnings: TStrings);
var
  I: Integer;
  Op: THookVarOp;
  Done: Boolean;
begin
  if AScope = nil then Exit;
  for I := 0 to AResult.VarOpCount - 1 do
  begin
    Op := AResult.VarOps[I];
    if (Op.Scope <> 'session') and (Op.Scope <> 'environment') and (Op.Scope <> 'collection') then
    begin
      if AWarnings <> nil then
        AWarnings.Add(Format('hook: unknown variable scope "%s" for %s, ignored', [Op.Scope, Op.Name]));
      Continue;
    end;
    if not AScope.HasLayer(Op.Scope) then
    begin
      // No environment loaded, for instance. Session always exists.
      if AWarnings <> nil then
        AWarnings.Add(Format('hook: no %s scope is loaded, %s stored in session instead', [Op.Scope, Op.Name]));
      Op.Scope := 'session';
      if not AScope.HasLayer('session') then
        AScope.PushLayer('session', nil);
    end;
    if Op.Unset then
      Done := AScope.UnsetVariableIn(Op.Scope, Op.Name)
    else
      Done := AScope.SetVariableIn(Op.Scope, Op.Name, Op.Value);
    if (not Done) and (AWarnings <> nil) then
      AWarnings.Add('hook: could not set ' + Op.Name);
  end;
end;

{ THookRunner }

constructor THookRunner.Create;
begin
  inherited Create;
  TimeoutSec := 30;
end;

function THookRunner.Enabled: Boolean;
begin
  Result := Command <> '';
end;

function RunPhase(ARunner: THookRunner; APhase: THookPhase; AResolved: TResolvedRequest;
  AResponse: TResponse; AScope: TVariableScope; AReq: TRequest;
  const AContext: THookContext): THookResult;
var
  Input: string;
  Args: TStringList;
  P: TProcessResult;
begin
  Result := THookResult.Create;
  Result.Phase := APhase;
  Result.Command := ARunner.Command;
  if not ARunner.Enabled then Exit;
  Input := BuildHookInput(APhase, AResolved, AResponse, AScope, AReq, AContext);
  Args := TStringList.Create;
  try
    P := RunProcessWithStdin(ARunner.Command, Args, Input, ARunner.TimeoutSec * 1000);
    try
      Result.Ran := P.Started;
      Result.ExitCode := P.ExitCode;
      Result.ElapsedMs := P.ElapsedMs;
      Result.TimedOut := P.TimedOut;
      Result.StdErr := P.ErrorOutput;
      if not P.Started then
      begin
        Result.ErrorMessage := 'hook could not be started: ' + Trim(P.ErrorOutput);
        Exit;
      end;
      if P.TimedOut then
      begin
        Result.ErrorMessage := Format('hook killed after %d s', [ARunner.TimeoutSec]);
        Exit;
      end;
      if P.ExitCode <> 0 then
      begin
        Result.ErrorMessage := Format('hook exited with code %d', [P.ExitCode]);
        // Still parse: console lines printed before the failure are useful.
        ParseHookOutput(P.Output, Result);
        Result.ErrorMessage := Format('hook exited with code %d', [P.ExitCode]);
        Exit;
      end;
      if not ParseHookOutput(P.Output, Result) then
        Exit;
      Result.Ok := True;
    finally
      P.Free;
    end;
  finally
    Args.Free;
  end;
end;

function THookRunner.RunBefore(AResolved: TResolvedRequest; AScope: TVariableScope;
  AReq: TRequest; const AContext: THookContext): THookResult;
begin
  Result := RunPhase(Self, hpBefore, AResolved, nil, AScope, AReq, AContext);
  if Result.Ok then
  begin
    ApplyRequestChanges(Result, AResolved);
    ApplyVariableChanges(Result, AScope, AResolved.Warnings);
  end;
end;

function THookRunner.RunAfter(AResolved: TResolvedRequest; AResponse: TResponse;
  AScope: TVariableScope; AReq: TRequest; const AContext: THookContext): THookResult;
begin
  Result := RunPhase(Self, hpAfter, AResolved, AResponse, AScope, AReq, AContext);
  if Result.Ok then
    ApplyVariableChanges(Result, AScope, AResolved.Warnings);
end;

end.
