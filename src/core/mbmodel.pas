unit mbModel;

{ mailBoy core data model. Pure data, no behaviour beyond simple lookups.
  No LCL, no JSON. Filled by mbLoader, read by everything else. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, contnrs;

type
  { A key/value pair used for headers, query params, form fields, variables. }
  TKeyValue = class
  public
    Key: string;
    Value: string;
    Enabled: Boolean;
    Description: string;
    IsFile: Boolean;      // form-data file field; Value holds the path
    constructor Create; overload;
    constructor Create(const AKey, AValue: string); overload;
  end;

  TKeyValueList = class
  private
    FList: TFPObjectList;
    function GetCount: Integer;
    function GetItem(Index: Integer): TKeyValue;
  public
    constructor Create;
    destructor Destroy; override;
    function Add(const AKey, AValue: string): TKeyValue; overload;
    function Add(AItem: TKeyValue): TKeyValue; overload;
    procedure Clear;
    procedure Delete(Index: Integer);
    { Case-insensitive lookup of the LAST enabled entry with that key; nil if none. }
    function Find(const AKey: string): TKeyValue;
    function ValueOf(const AKey: string; const Default: string = ''): string;
    function IndexOfKey(const AKey: string): Integer;
    property Count: Integer read GetCount;
    property Items[Index: Integer]: TKeyValue read GetItem; default;
  end;

  TAuthType = (
    atInherit,   // request says nothing, use the parent's auth
    atNone,      // explicit "noauth"
    atBasic,
    atBearer,
    atOther      // loaded but unsupported in this version; see RawType
  );

  TAuth = class
  public
    AuthType: TAuthType;
    RawType: string;          // the "type" string as found in the file, e.g. 'oauth1'
    Params: TKeyValueList;    // normalised key/value params regardless of schema version
    constructor Create;
    destructor Destroy; override;
    function Param(const AName: string): string;
  end;

  TBodyMode = (bmNone, bmRaw, bmUrlEncoded, bmFormData, bmGraphQL, bmFile, bmUnknown);

  TBody = class
  public
    Mode: TBodyMode;
    RawMode: string;          // the "mode" string as found in the file
    Raw: string;              // raw body text (also GraphQL as serialised JSON)
    Language: string;         // raw body hint: json, xml, text, ...
    Params: TKeyValueList;    // urlencoded / formdata fields
    FilePath: string;         // mode = file
    constructor Create;
    destructor Destroy; override;
  end;

  TUrl = class
  public
    Raw: string;              // full URL as authored, may contain {{variables}}
    Query: TKeyValueList;     // query params (enabled flag honoured by the builder)
    PathVariables: TKeyValueList;  // ":id" style path variables
    constructor Create;
    destructor Destroy; override;
    { Raw without the query string and fragment. }
    function Base: string;
  end;

  TFolder = class;

  { Common base of folders and requests so a folder can hold a mixed list. }
  TCollectionItem = class
  public
    Name: string;
    Description: string;
    Parent: TFolder;
    // Collection script text, kept verbatim so the user can read what they are
    // migrating and a hook program can see it. mailBoy never runs it.
    PreRequestScript: string;
    TestScript: string;
    // Hook program attached to this item in the GUI for the session. Never
    // read from or written to a file: a collection file must not be able to
    // name a program to run.
    HookCommand: string;
    function HasScripts: Boolean;
    { The hook that applies to this item: its own, else the nearest ancestor's,
      else ''. ASource says where it came from: request, folder "<name>",
      collection, or '' when there is none. }
    function EffectiveHook(out ASource: string): string;
    { Folder path from the collection root, '/'-separated, excluding the
      collection itself and including this item's own name. }
    function Path: string;
    function IsFolder: Boolean; virtual;
  end;

  TRequest = class(TCollectionItem)
  public
    Method: string;
    Url: TUrl;
    Headers: TKeyValueList;
    Body: TBody;
    Auth: TAuth;
    constructor Create;
    destructor Destroy; override;
    { Walks up parents until an auth that is not atInherit is found. }
    function EffectiveAuth: TAuth;
  end;

  TFolder = class(TCollectionItem)
  private
    FItems: TFPObjectList;
    function GetCount: Integer;
    function GetItem(Index: Integer): TCollectionItem;
  public
    Auth: TAuth;
    constructor Create;
    destructor Destroy; override;
    function IsFolder: Boolean; override;
    function AddFolder(const AName: string): TFolder;
    function AddRequest(const AName: string): TRequest;
    { Collects every request below this folder, depth first, in file order. }
    procedure CollectRequests(AList: TFPList);
    property Count: Integer read GetCount;
    property Items[Index: Integer]: TCollectionItem read GetItem; default;
  end;

  TSchemaVersion = (svUnknown, svV1, svV20, svV21);

  TCollection = class(TFolder)
  public
    SchemaVersion: TSchemaVersion;
    Variables: TKeyValueList;
    SourceFile: string;
    constructor Create;
    destructor Destroy; override;
    { Finds requests whose name, or whose full Path, equals ANameOrPath
      (case-sensitive). Fills AMatches with TRequest; returns match count. }
    function FindRequests(const ANameOrPath: string; AMatches: TFPList): Integer;
    function RequestCount: Integer;
  end;

  TEnvironment = class
  public
    Name: string;
    Variables: TKeyValueList;
    SourceFile: string;
    constructor Create;
    destructor Destroy; override;
  end;

function SchemaVersionToString(V: TSchemaVersion): string;
function BodyModeToString(M: TBodyMode): string;
function AuthTypeToString(A: TAuthType): string;

implementation

{ TKeyValue }

constructor TKeyValue.Create;
begin
  inherited Create;
  Enabled := True;
end;

constructor TKeyValue.Create(const AKey, AValue: string);
begin
  Create;
  Key := AKey;
  Value := AValue;
end;

{ TKeyValueList }

constructor TKeyValueList.Create;
begin
  inherited Create;
  FList := TFPObjectList.Create(True);
end;

destructor TKeyValueList.Destroy;
begin
  FList.Free;
  inherited Destroy;
end;

function TKeyValueList.GetCount: Integer;
begin
  Result := FList.Count;
end;

function TKeyValueList.GetItem(Index: Integer): TKeyValue;
begin
  Result := TKeyValue(FList[Index]);
end;

function TKeyValueList.Add(const AKey, AValue: string): TKeyValue;
begin
  Result := TKeyValue.Create(AKey, AValue);
  FList.Add(Result);
end;

function TKeyValueList.Add(AItem: TKeyValue): TKeyValue;
begin
  FList.Add(AItem);
  Result := AItem;
end;

procedure TKeyValueList.Clear;
begin
  FList.Clear;
end;

procedure TKeyValueList.Delete(Index: Integer);
begin
  FList.Delete(Index);
end;

function TKeyValueList.IndexOfKey(const AKey: string): Integer;
var
  I: Integer;
begin
  Result := -1;
  for I := FList.Count - 1 downto 0 do
    if Items[I].Enabled and SameText(Items[I].Key, AKey) then
      Exit(I);
end;

function TKeyValueList.Find(const AKey: string): TKeyValue;
var
  I: Integer;
begin
  I := IndexOfKey(AKey);
  if I < 0 then
    Result := nil
  else
    Result := Items[I];
end;

function TKeyValueList.ValueOf(const AKey: string; const Default: string): string;
var
  KV: TKeyValue;
begin
  KV := Find(AKey);
  if KV = nil then
    Result := Default
  else
    Result := KV.Value;
end;

{ TAuth }

constructor TAuth.Create;
begin
  inherited Create;
  AuthType := atInherit;
  Params := TKeyValueList.Create;
end;

destructor TAuth.Destroy;
begin
  Params.Free;
  inherited Destroy;
end;

function TAuth.Param(const AName: string): string;
begin
  Result := Params.ValueOf(AName);
end;

{ TBody }

constructor TBody.Create;
begin
  inherited Create;
  Mode := bmNone;
  Params := TKeyValueList.Create;
end;

destructor TBody.Destroy;
begin
  Params.Free;
  inherited Destroy;
end;

{ TUrl }

constructor TUrl.Create;
begin
  inherited Create;
  Query := TKeyValueList.Create;
  PathVariables := TKeyValueList.Create;
end;

destructor TUrl.Destroy;
begin
  PathVariables.Free;
  Query.Free;
  inherited Destroy;
end;

function TUrl.Base: string;
var
  P: Integer;
begin
  Result := Raw;
  P := Pos('?', Result);
  if P > 0 then
    Result := Copy(Result, 1, P - 1);
  P := Pos('#', Result);
  if P > 0 then
    Result := Copy(Result, 1, P - 1);
end;

{ TCollectionItem }

function TCollectionItem.Path: string;
var
  Item: TCollectionItem;
begin
  Result := Name;
  Item := Parent;
  // Stop before the collection root: it is a TFolder with no parent.
  while (Item <> nil) and (Item.Parent <> nil) do
  begin
    Result := Item.Name + '/' + Result;
    Item := Item.Parent;
  end;
end;

function TCollectionItem.IsFolder: Boolean;
begin
  Result := False;
end;

function TCollectionItem.HasScripts: Boolean;
begin
  Result := (PreRequestScript <> '') or (TestScript <> '');
end;

function TCollectionItem.EffectiveHook(out ASource: string): string;
var
  Item: TCollectionItem;
begin
  Item := Self;
  while Item <> nil do
  begin
    if Item.HookCommand <> '' then
    begin
      Result := Item.HookCommand;
      if Item.Parent = nil then
        ASource := 'collection'
      else if Item.IsFolder then
        ASource := 'folder "' + Item.Name + '"'
      else
        ASource := 'request';
      Exit;
    end;
    Item := Item.Parent;
  end;
  Result := '';
  ASource := '';
end;

{ TRequest }

constructor TRequest.Create;
begin
  inherited Create;
  Method := 'GET';
  Url := TUrl.Create;
  Headers := TKeyValueList.Create;
  Body := TBody.Create;
  Auth := TAuth.Create;
end;

destructor TRequest.Destroy;
begin
  Auth.Free;
  Body.Free;
  Headers.Free;
  Url.Free;
  inherited Destroy;
end;

function TRequest.EffectiveAuth: TAuth;
var
  F: TFolder;
begin
  Result := Auth;
  F := Parent;
  while (Result.AuthType = atInherit) and (F <> nil) do
  begin
    Result := F.Auth;
    F := F.Parent;
  end;
end;

{ TFolder }

constructor TFolder.Create;
begin
  inherited Create;
  FItems := TFPObjectList.Create(True);
  Auth := TAuth.Create;
end;

destructor TFolder.Destroy;
begin
  Auth.Free;
  FItems.Free;
  inherited Destroy;
end;

function TFolder.IsFolder: Boolean;
begin
  Result := True;
end;

function TFolder.GetCount: Integer;
begin
  Result := FItems.Count;
end;

function TFolder.GetItem(Index: Integer): TCollectionItem;
begin
  Result := TCollectionItem(FItems[Index]);
end;

function TFolder.AddFolder(const AName: string): TFolder;
begin
  Result := TFolder.Create;
  Result.Name := AName;
  Result.Parent := Self;
  FItems.Add(Result);
end;

function TFolder.AddRequest(const AName: string): TRequest;
begin
  Result := TRequest.Create;
  Result.Name := AName;
  Result.Parent := Self;
  FItems.Add(Result);
end;

procedure TFolder.CollectRequests(AList: TFPList);
var
  I: Integer;
begin
  for I := 0 to Count - 1 do
    if Items[I].IsFolder then
      TFolder(Items[I]).CollectRequests(AList)
    else
      AList.Add(Items[I]);
end;

{ TCollection }

constructor TCollection.Create;
begin
  inherited Create;
  SchemaVersion := svUnknown;
  Variables := TKeyValueList.Create;
end;

destructor TCollection.Destroy;
begin
  Variables.Free;
  inherited Destroy;
end;

function TCollection.FindRequests(const ANameOrPath: string; AMatches: TFPList): Integer;
var
  All: TFPList;
  I: Integer;
  R: TRequest;
begin
  Result := 0;
  All := TFPList.Create;
  try
    CollectRequests(All);
    for I := 0 to All.Count - 1 do
    begin
      R := TRequest(All[I]);
      if (R.Name = ANameOrPath) or (R.Path = ANameOrPath) then
      begin
        AMatches.Add(R);
        Inc(Result);
      end;
    end;
  finally
    All.Free;
  end;
end;

function TCollection.RequestCount: Integer;
var
  All: TFPList;
begin
  All := TFPList.Create;
  try
    CollectRequests(All);
    Result := All.Count;
  finally
    All.Free;
  end;
end;

{ TEnvironment }

constructor TEnvironment.Create;
begin
  inherited Create;
  Variables := TKeyValueList.Create;
end;

destructor TEnvironment.Destroy;
begin
  Variables.Free;
  inherited Destroy;
end;

{ helpers }

function SchemaVersionToString(V: TSchemaVersion): string;
begin
  case V of
    svV1:  Result := 'v1';
    svV20: Result := 'v2.0.0';
    svV21: Result := 'v2.1.0';
  else
    Result := 'unknown';
  end;
end;

function BodyModeToString(M: TBodyMode): string;
begin
  case M of
    bmNone:       Result := 'none';
    bmRaw:        Result := 'raw';
    bmUrlEncoded: Result := 'urlencoded';
    bmFormData:   Result := 'formdata';
    bmGraphQL:    Result := 'graphql';
    bmFile:       Result := 'file';
  else
    Result := 'unknown';
  end;
end;

function AuthTypeToString(A: TAuthType): string;
begin
  case A of
    atInherit: Result := 'inherit';
    atNone:    Result := 'none';
    atBasic:   Result := 'basic';
    atBearer:  Result := 'bearer';
  else
    Result := 'other';
  end;
end;

end.
