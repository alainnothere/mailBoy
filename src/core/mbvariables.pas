unit mbVariables;

// Variable scopes and {{name}} substitution.
// Layers are pushed lowest priority first: collection, then environment,
// then command-line / session overrides. Lookup walks from the top down.
// Unresolved names stay literal and are reported, never silently blanked.

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, DateUtils, mbModel;

type
  TVariableScope = class
  private
    FLayers: TStringList;     // each object is a TStringList of name=value
    FLayerNames: TStringList;
    function TopLayer: TStringList;
    function NewLayer(const AName: string): TStringList;
  public
    constructor Create;
    destructor Destroy; override;
    { Copies the ENABLED entries of AVars into a new top layer. }
    procedure PushLayer(const AName: string; AVars: TKeyValueList);
    { Sets a variable in the top layer (creates a "session" layer if empty).
      Used for --var overrides and, later, response capture. }
    procedure SetVariable(const AName, AValue: string);
    function Lookup(const AName: string; out AValue: string): Boolean;
    function HasLayer(const ALayer: string): Boolean;
    function LayerName(Index: Integer): string;
    // Set or remove a variable in a named layer. False if no such layer.
    function SetVariableIn(const ALayer, AName, AValue: string): Boolean;
    function UnsetVariableIn(const ALayer, AName: string): Boolean;
    // Appends the layer's name=value pairs to ADest (empty if no such layer).
    procedure CopyLayer(const ALayer: string; ADest: TStrings);
    // Replaces every {{name}} in S. Values may themselves contain {{...}} and
    // are resolved recursively up to a fixed depth. Names that cannot be
    // resolved are left as written and appended to AUnresolved (may be nil).
    function Resolve(const S: string; AUnresolved: TStrings = nil): string;
    function LayerCount: Integer;
    // Every distinct {{name}} present in S, in order of first appearance.
    class procedure FindPlaceholders(const S: string; ANames: TStrings);
  end;

{ Built-in dynamic variables, the three people actually use. }
function DynamicVariable(const AName: string; out AValue: string): Boolean;

{ Every distinct {{name}} used anywhere in the collection (URLs, query, path
  variables, headers, bodies, auth, variable values), in order of first
  appearance, dynamic {{$...}} names excluded. }
procedure CollectCollectionPlaceholders(ACollection: TCollection; ANames: TStrings);

{ The value a generated environment carries for a name nobody has filled in
  yet. A variable still holding its placeholder counts as undefined when
  resolving, so a forgotten one is reported instead of sent. }
function PlaceholderValue(const AName: string): string;
function IsPlaceholderValue(const AName, AValue: string): Boolean;

{ A new environment with one row per placeholder the collection uses: the
  collection's own value where it defines one, PlaceholderValue otherwise.
  The caller owns the result. }
function NewEnvironmentFromCollection(ACollection: TCollection): TEnvironment;

implementation

const
  MaxDepth = 10;

// What may appear between {{ and }} for it to count as a variable name.
function IsValidName(const AName: string): Boolean;
var
  I: Integer;
begin
  Result := AName <> '';
  for I := 1 to Length(AName) do
    if not (AName[I] in ['A'..'Z', 'a'..'z', '0'..'9', '_', '.', '-', '$']) then
      Exit(False);
end;

function DynamicVariable(const AName: string; out AValue: string): Boolean;
var
  G: TGUID;
begin
  Result := True;
  if AName = '$guid' then
  begin
    CreateGUID(G);
    AValue := LowerCase(Copy(GUIDToString(G), 2, 36));
  end
  else if AName = '$timestamp' then
    AValue := IntToStr(DateTimeToUnix(Now))
  else if AName = '$randomInt' then
    AValue := IntToStr(Random(1001))
  else
    Result := False;
end;

{ TVariableScope }

constructor TVariableScope.Create;
begin
  inherited Create;
  FLayers := TStringList.Create;
  FLayers.OwnsObjects := True;
  FLayerNames := TStringList.Create;
end;

destructor TVariableScope.Destroy;
begin
  FLayerNames.Free;
  FLayers.Free;
  inherited Destroy;
end;

function TVariableScope.NewLayer(const AName: string): TStringList;
begin
  Result := TStringList.Create;
  Result.CaseSensitive := True;      // variable names are case-sensitive
  Result.NameValueSeparator := '=';
  FLayers.AddObject(AName, Result);
end;

function TVariableScope.TopLayer: TStringList;
begin
  if FLayers.Count = 0 then
    Result := NewLayer('session')
  else
    Result := TStringList(FLayers.Objects[FLayers.Count - 1]);
end;

procedure TVariableScope.PushLayer(const AName: string; AVars: TKeyValueList);
var
  L: TStringList;
  I: Integer;
begin
  L := NewLayer(AName);
  if AVars = nil then Exit;
  for I := 0 to AVars.Count - 1 do
    if AVars[I].Enabled and (AVars[I].Key <> '') then
      L.Values[AVars[I].Key] := AVars[I].Value;
end;

procedure TVariableScope.SetVariable(const AName, AValue: string);
begin
  TopLayer.Values[AName] := AValue;
end;

function TVariableScope.Lookup(const AName: string; out AValue: string): Boolean;
var
  I, Idx: Integer;
  L: TStringList;
begin
  for I := FLayers.Count - 1 downto 0 do
  begin
    L := TStringList(FLayers.Objects[I]);
    Idx := L.IndexOfName(AName);
    if Idx >= 0 then
    begin
      AValue := L.ValueFromIndex[Idx];
      Exit(True);
    end;
  end;
  Result := DynamicVariable(AName, AValue);
end;

function TVariableScope.HasLayer(const ALayer: string): Boolean;
begin
  Result := FLayers.IndexOf(ALayer) >= 0;
end;

function TVariableScope.LayerName(Index: Integer): string;
begin
  Result := FLayers[Index];
end;

function TVariableScope.SetVariableIn(const ALayer, AName, AValue: string): Boolean;
var
  I: Integer;
begin
  I := FLayers.IndexOf(ALayer);
  Result := I >= 0;
  if Result then
    TStringList(FLayers.Objects[I]).Values[AName] := AValue;
end;

function TVariableScope.UnsetVariableIn(const ALayer, AName: string): Boolean;
var
  I, J: Integer;
  L: TStringList;
begin
  I := FLayers.IndexOf(ALayer);
  Result := I >= 0;
  if not Result then Exit;
  L := TStringList(FLayers.Objects[I]);
  J := L.IndexOfName(AName);
  if J >= 0 then
    L.Delete(J);
end;

procedure TVariableScope.CopyLayer(const ALayer: string; ADest: TStrings);
var
  I: Integer;
begin
  I := FLayers.IndexOf(ALayer);
  if I >= 0 then
    ADest.AddStrings(TStringList(FLayers.Objects[I]));
end;

function TVariableScope.LayerCount: Integer;
begin
  Result := FLayers.Count;
end;

function PlaceholderValue(const AName: string): string;
begin
  Result := 'put the ' + AName + ' value here';
end;

function IsPlaceholderValue(const AName, AValue: string): Boolean;
begin
  Result := AValue = PlaceholderValue(AName);
end;

procedure CollectCollectionPlaceholders(ACollection: TCollection; ANames: TStrings);
var
  Found: TStringList;
  I: Integer;

  procedure Scan(const S: string);
  begin
    if Pos('{{', S) > 0 then
      TVariableScope.FindPlaceholders(S, Found);
  end;

  procedure ScanList(L: TKeyValueList);
  var
    J: Integer;
  begin
    if L = nil then Exit;
    for J := 0 to L.Count - 1 do
    begin
      Scan(L[J].Key);
      Scan(L[J].Value);
    end;
  end;

  procedure ScanAuth(A: TAuth);
  begin
    if A <> nil then
      ScanList(A.Params);
  end;

  procedure ScanFolder(F: TFolder);
  var
    J: Integer;
    R: TRequest;
  begin
    ScanAuth(F.Auth);
    for J := 0 to F.Count - 1 do
      if F[J].IsFolder then
        ScanFolder(TFolder(F[J]))
      else
      begin
        R := TRequest(F[J]);
        Scan(R.Url.Raw);
        ScanList(R.Url.Query);
        ScanList(R.Url.PathVariables);
        ScanList(R.Headers);
        Scan(R.Body.Raw);
        ScanList(R.Body.Params);
        Scan(R.Body.FilePath);
        ScanAuth(R.Auth);
      end;
  end;

begin
  if ACollection = nil then Exit;
  Found := TStringList.Create;
  try
    ScanList(ACollection.Variables);
    ScanFolder(ACollection);
    for I := 0 to Found.Count - 1 do
      if (Found[I] <> '') and (Found[I][1] <> '$') and (ANames.IndexOf(Found[I]) < 0) then
        ANames.Add(Found[I]);
  finally
    Found.Free;
  end;
end;

function NewEnvironmentFromCollection(ACollection: TCollection): TEnvironment;
var
  Names: TStringList;
  I: Integer;
  KV: TKeyValue;
begin
  Result := TEnvironment.Create;
  if ACollection = nil then Exit;
  Result.Name := ACollection.Name + ' environment';
  Names := TStringList.Create;
  try
    CollectCollectionPlaceholders(ACollection, Names);
    for I := 0 to Names.Count - 1 do
    begin
      KV := ACollection.Variables.Find(Names[I]);
      if KV <> nil then
        Result.Variables.Add(Names[I], KV.Value)
      else
        Result.Variables.Add(Names[I], PlaceholderValue(Names[I]));
    end;
  finally
    Names.Free;
  end;
end;

class procedure TVariableScope.FindPlaceholders(const S: string; ANames: TStrings);
var
  P, Q: Integer;
  Name: string;
begin
  P := Pos('{{', S);
  while P > 0 do
  begin
    Q := Pos('}}', S, P + 2);
    if Q = 0 then Exit;
    Name := Copy(S, P + 2, Q - P - 2);
    if IsValidName(Name) then
    begin
      if ANames.IndexOf(Name) < 0 then
        ANames.Add(Name);
      P := Pos('{{', S, Q + 2);
    end
    else
      P := Pos('{{', S, P + 1);
  end;
end;

function TVariableScope.Resolve(const S: string; AUnresolved: TStrings): string;
var
  Depth, P, Q: Integer;
  Name, Value, Rest: string;
  Changed: Boolean;
begin
  Result := S;
  Depth := 0;
  repeat
    Changed := False;
    P := Pos('{{', Result);
    Rest := '';
    while P > 0 do
    begin
      Q := Pos('}}', Result, P + 2);
      if Q = 0 then Break;
      Name := Copy(Result, P + 2, Q - P - 2);
      if not IsValidName(Name) then
      begin
        // "{{" that is not a placeholder, e.g. JSON "{{" in a body. Skip one brace.
        P := Pos('{{', Result, P + 1);
        Continue;
      end;
      if Lookup(Name, Value) and not IsPlaceholderValue(Name, Value) then
      begin
        Result := Copy(Result, 1, P - 1) + Value + Copy(Result, Q + 2, MaxInt);
        Changed := True;
        // Continue scanning after the inserted value; nested names are
        // handled on the next pass so a value equal to its own placeholder
        // cannot loop forever.
        P := Pos('{{', Result, P + Length(Value));
      end
      else
      begin
        if (AUnresolved <> nil) and (AUnresolved.IndexOf(Name) < 0) and (Depth = 0) then
          AUnresolved.Add(Name);
        P := Pos('{{', Result, Q + 2);
      end;
    end;
    Inc(Depth);
  until (not Changed) or (Depth >= MaxDepth);
  // Names introduced by substitution that still cannot resolve.
  if (AUnresolved <> nil) and (Depth > 1) then
  begin
    Rest := Result;
    P := Pos('{{', Rest);
    while P > 0 do
    begin
      Q := Pos('}}', Rest, P + 2);
      if Q = 0 then Break;
      Name := Copy(Rest, P + 2, Q - P - 2);
      if IsValidName(Name) and (not Lookup(Name, Value)) and (AUnresolved.IndexOf(Name) < 0) then
        AUnresolved.Add(Name);
      P := Pos('{{', Rest, P + 1);
    end;
  end;
end;

end.
