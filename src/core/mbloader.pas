unit mbLoader;

{ Reads API collection and environment JSON files into the mbModel classes.
  Eats three schema generations: v1 (newman "requests" array), v2.0.0, v2.1.0.
  Anything it cannot use (scripts, unsupported auth) is reported as a warning,
  never dropped silently. Raises EMailBoyLoad on files it cannot read at all. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpjson, jsonparser, mbModel;

type
  EMailBoyLoad = class(Exception);

{ Parses a collection. AWarnings may be nil. The caller owns the result. }
function LoadCollectionFromString(const AJson: string; AWarnings: TStrings): TCollection;
function LoadCollectionFromFile(const AFileName: string; AWarnings: TStrings): TCollection;

{ Parses an environment file ("values" array). The caller owns the result. }
function LoadEnvironmentFromString(const AJson: string): TEnvironment;
function LoadEnvironmentFromFile(const AFileName: string): TEnvironment;

{ True if the JSON looks like an environment rather than a collection. }
function IsEnvironmentJson(const AJson: string): Boolean;

{ Writes an environment in the same shape the loader reads: {"name", "values":
  [{"key","value","enabled"}]}. The only file mailBoy ever writes, and only
  when the user names it. Raises EMailBoyLoad if the file cannot be written. }
function SaveEnvironmentToString(AEnv: TEnvironment): string;
procedure SaveEnvironmentToFile(AEnv: TEnvironment; const AFileName: string);

implementation

const
  UnnamedFolder = '(unnamed folder)';
  UnnamedRequest = '(unnamed request)';

{ ---- small fpjson helpers: tolerant of missing keys and wrong types ---- }

function JStr(Obj: TJSONObject; const Name: string; const Default: string = ''): string;
var
  D: TJSONData;
begin
  Result := Default;
  if Obj = nil then Exit;
  D := Obj.Find(Name);
  if (D = nil) or D.IsNull then Exit;
  case D.JSONType of
    jtString, jtNumber, jtBoolean: Result := D.AsString;
  else
    Result := Default;
  end;
end;

function JBool(Obj: TJSONObject; const Name: string; Default: Boolean): Boolean;
var
  D: TJSONData;
begin
  Result := Default;
  if Obj = nil then Exit;
  D := Obj.Find(Name);
  if (D = nil) or D.IsNull then Exit;
  if D.JSONType = jtBoolean then
    Result := D.AsBoolean
  else if D.JSONType = jtString then
    Result := SameText(D.AsString, 'true');
end;

function JObj(Obj: TJSONObject; const Name: string): TJSONObject;
var
  D: TJSONData;
begin
  Result := nil;
  if Obj = nil then Exit;
  D := Obj.Find(Name);
  if (D <> nil) and (D.JSONType = jtObject) then
    Result := TJSONObject(D);
end;

function JArr(Obj: TJSONObject; const Name: string): TJSONArray;
var
  D: TJSONData;
begin
  Result := nil;
  if Obj = nil then Exit;
  D := Obj.Find(Name);
  if (D <> nil) and (D.JSONType = jtArray) then
    Result := TJSONArray(D);
end;

function ParseJson(const AJson: string): TJSONData;
begin
  try
    Result := GetJSON(AJson);
  except
    on E: Exception do
      raise EMailBoyLoad.Create('Not valid JSON: ' + E.Message);
  end;
  if Result = nil then
    raise EMailBoyLoad.Create('Not valid JSON: empty document');
end;

function ReadFileToString(const AFileName: string): string;
var
  FS: TFileStream;
begin
  if not FileExists(AFileName) then
    raise EMailBoyLoad.Create('File not found: ' + AFileName);
  FS := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(Result, FS.Size);
    if FS.Size > 0 then
      FS.ReadBuffer(Result[1], FS.Size);
  finally
    FS.Free;
  end;
end;

// Reads "event": [{"listen": "prerequest"|"test", "script": {"exec": [...] | "..."}}]
// into the item's script fields. Lines are joined with LF, CR stripped.
procedure LoadEvents(Arr: TJSONArray; Item: TCollectionItem);
var
  I, J: Integer;
  Ev, Script: TJSONObject;
  Exec: TJSONData;
  Listen, Code: string;
begin
  if Arr = nil then Exit;
  for I := 0 to Arr.Count - 1 do
  begin
    if Arr[I].JSONType <> jtObject then Continue;
    Ev := TJSONObject(Arr[I]);
    Listen := LowerCase(JStr(Ev, 'listen'));
    Script := JObj(Ev, 'script');
    if Script = nil then Continue;
    Exec := Script.Find('exec');
    Code := '';
    if (Exec <> nil) and (Exec.JSONType = jtArray) then
    begin
      for J := 0 to TJSONArray(Exec).Count - 1 do
      begin
        if J > 0 then Code := Code + #10;
        if not TJSONArray(Exec)[J].IsNull then
          Code := Code + TJSONArray(Exec)[J].AsString;
      end;
    end
    else if (Exec <> nil) and (Exec.JSONType = jtString) then
      Code := Exec.AsString;
    Code := StringReplace(Code, #13, '', [rfReplaceAll]);
    if Trim(Code) = '' then Continue;
    if Listen = 'prerequest' then
      Item.PreRequestScript := Code
    else if Listen = 'test' then
      Item.TestScript := Code;
  end;
end;

procedure Warn(AWarnings: TStrings; const Msg: string);
begin
  if AWarnings <> nil then
    AWarnings.Add(Msg);
end;

{ "disabled": true  or  "enabled": false  both mean off. }
function ItemEnabled(Obj: TJSONObject): Boolean;
begin
  Result := JBool(Obj, 'enabled', True) and not JBool(Obj, 'disabled', False);
end;

{ Appends "key"/"value" objects from a JSON array to a TKeyValueList. }
procedure LoadKeyValueArray(Arr: TJSONArray; List: TKeyValueList);
var
  I: Integer;
  O: TJSONObject;
  KV: TKeyValue;
begin
  if Arr = nil then Exit;
  for I := 0 to Arr.Count - 1 do
  begin
    if Arr[I].JSONType <> jtObject then Continue;
    O := TJSONObject(Arr[I]);
    KV := TKeyValue.Create;
    KV.Key := JStr(O, 'key');
    if KV.Key = '' then
      KV.Key := JStr(O, 'id');   // old-style collection variables use "id"
    KV.Value := JStr(O, 'value');
    KV.Description := JStr(O, 'description');
    KV.Enabled := ItemEnabled(O);
    List.Add(KV);
  end;
end;

{ "Name: value\nOther: value" header blobs (v1 and some v2.0 files). }
procedure LoadHeaderString(const S: string; List: TKeyValueList);
var
  Lines: TStringList;
  I, P: Integer;
  Line: string;
begin
  Lines := TStringList.Create;
  try
    Lines.Text := S;
    for I := 0 to Lines.Count - 1 do
    begin
      Line := Trim(Lines[I]);
      if Line = '' then Continue;
      P := Pos(':', Line);
      if P = 0 then
        List.Add(Line, '')
      else
        List.Add(Trim(Copy(Line, 1, P - 1)), Trim(Copy(Line, P + 1, MaxInt)));
    end;
  finally
    Lines.Free;
  end;
end;

{ Splits "a=1&b=2&c" into the query list. Values are kept as written. }
procedure ParseQueryString(const Q: string; List: TKeyValueList);
var
  Parts: TStringList;
  I, P: Integer;
  Part: string;
begin
  if Q = '' then Exit;
  Parts := TStringList.Create;
  try
    Parts.Delimiter := '&';
    Parts.StrictDelimiter := True;
    Parts.DelimitedText := Q;
    for I := 0 to Parts.Count - 1 do
    begin
      Part := Parts[I];
      if Part = '' then Continue;
      P := Pos('=', Part);
      if P = 0 then
        List.Add(Part, '')
      else
        List.Add(Copy(Part, 1, P - 1), Copy(Part, P + 1, MaxInt));
    end;
  finally
    Parts.Free;
  end;
end;

{ Joins a JSON string-or-array ("host": ["a","b"] or "host": "a.b") with Sep. }
function JoinStringOrArray(D: TJSONData; const Sep: string): string;
var
  I: Integer;
begin
  Result := '';
  if (D = nil) or D.IsNull then Exit;
  if D.JSONType = jtArray then
  begin
    for I := 0 to TJSONArray(D).Count - 1 do
    begin
      if I > 0 then Result := Result + Sep;
      Result := Result + TJSONArray(D)[I].AsString;
    end;
  end
  else
    Result := D.AsString;
end;

{ Rebuilds a URL from protocol/host/port/path/query when "raw" is missing. }
function BuildRawUrl(U: TJSONObject): string;
var
  S: string;
  QArr: TJSONArray;
  I: Integer;
  QO: TJSONObject;
  First: Boolean;
begin
  Result := '';
  S := JStr(U, 'protocol');
  if S <> '' then Result := S + '://';
  Result := Result + JoinStringOrArray(U.Find('host'), '.');
  S := JStr(U, 'port');
  if S <> '' then Result := Result + ':' + S;
  S := JoinStringOrArray(U.Find('path'), '/');
  if S <> '' then
  begin
    if (S[1] <> '/') then Result := Result + '/';
    Result := Result + S;
  end;
  QArr := JArr(U, 'query');
  if (QArr <> nil) and (QArr.Count > 0) then
  begin
    First := True;
    for I := 0 to QArr.Count - 1 do
    begin
      if QArr[I].JSONType <> jtObject then Continue;
      QO := TJSONObject(QArr[I]);
      if not ItemEnabled(QO) then Continue;
      if First then Result := Result + '?' else Result := Result + '&';
      First := False;
      Result := Result + JStr(QO, 'key') + '=' + JStr(QO, 'value');
    end;
  end;
  S := JStr(U, 'hash');
  if S <> '' then Result := Result + '#' + S;
end;

procedure LoadUrl(D: TJSONData; Url: TUrl);
var
  U: TJSONObject;
  QArr: TJSONArray;
  P, H: Integer;
  QS: string;
begin
  if (D = nil) or D.IsNull then Exit;
  if D.JSONType = jtString then
    Url.Raw := D.AsString
  else if D.JSONType = jtObject then
  begin
    U := TJSONObject(D);
    Url.Raw := JStr(U, 'raw');
    if Url.Raw = '' then
      Url.Raw := BuildRawUrl(U);
    QArr := JArr(U, 'query');
    LoadKeyValueArray(QArr, Url.Query);
    LoadKeyValueArray(JArr(U, 'variable'), Url.PathVariables);
  end;
  // No structured query list: derive it from the raw string so there is
  // always exactly one place the builder has to look.
  if Url.Query.Count = 0 then
  begin
    P := Pos('?', Url.Raw);
    if P > 0 then
    begin
      QS := Copy(Url.Raw, P + 1, MaxInt);
      H := Pos('#', QS);
      if H > 0 then QS := Copy(QS, 1, H - 1);
      ParseQueryString(QS, Url.Query);
    end;
  end;
end;

// Auth params come as an object (v2.0: "basic": {"username": ...}) or as an
// array of key/value/type (v2.1: "basic": [{"key":"username", ...}]).
procedure LoadAuth(A: TJSONObject; Auth: TAuth; const Owner: string; AWarnings: TStrings);
var
  T: string;
  Params: TJSONData;
  O: TJSONObject;
  I: Integer;
begin
  if A = nil then
  begin
    Auth.AuthType := atInherit;
    Exit;
  end;
  T := LowerCase(JStr(A, 'type'));
  Auth.RawType := T;
  if (T = '') or (T = 'noauth') then
    Auth.AuthType := atNone
  else if T = 'basic' then
    Auth.AuthType := atBasic
  else if T = 'bearer' then
    Auth.AuthType := atBearer
  else if T = 'inherit' then
    Auth.AuthType := atInherit
  else
  begin
    Auth.AuthType := atOther;
    Warn(AWarnings, Format('%s: auth type "%s" is not supported in this version', [Owner, T]));
  end;
  Params := A.Find(T);
  if (Params = nil) or Params.IsNull then Exit;
  if Params.JSONType = jtArray then
    LoadKeyValueArray(TJSONArray(Params), Auth.Params)
  else if Params.JSONType = jtObject then
  begin
    O := TJSONObject(Params);
    for I := 0 to O.Count - 1 do
      if O.Items[I].JSONType in [jtString, jtNumber, jtBoolean] then
        Auth.Params.Add(O.Names[I], O.Items[I].AsString)
      else if not O.Items[I].IsNull then
        Auth.Params.Add(O.Names[I], O.Items[I].AsJSON);
  end;
end;

{ Form-data file fields may carry one path or an array of paths; each path
  becomes its own entry because curl takes one -F per file. }
procedure LoadFormData(Arr: TJSONArray; List: TKeyValueList);
var
  I, J: Integer;
  O: TJSONObject;
  KV: TKeyValue;
  Src: TJSONData;
  Key, Desc: string;
  En: Boolean;
begin
  if Arr = nil then Exit;
  for I := 0 to Arr.Count - 1 do
  begin
    if Arr[I].JSONType <> jtObject then Continue;
    O := TJSONObject(Arr[I]);
    Key := JStr(O, 'key');
    Desc := JStr(O, 'description');
    En := ItemEnabled(O);
    if SameText(JStr(O, 'type'), 'file') then
    begin
      Src := O.Find('src');
      if (Src <> nil) and (Src.JSONType = jtArray) then
      begin
        for J := 0 to TJSONArray(Src).Count - 1 do
        begin
          KV := TKeyValue.Create(Key, TJSONArray(Src)[J].AsString);
          KV.IsFile := True; KV.Enabled := En; KV.Description := Desc;
          List.Add(KV);
        end;
      end
      else
      begin
        KV := TKeyValue.Create(Key, JStr(O, 'src'));
        KV.IsFile := True; KV.Enabled := En; KV.Description := Desc;
        List.Add(KV);
      end;
    end
    else
    begin
      KV := TKeyValue.Create(Key, JStr(O, 'value'));
      KV.Enabled := En; KV.Description := Desc;
      List.Add(KV);
    end;
  end;
end;

procedure LoadBody(B: TJSONObject; Body: TBody);
var
  Mode: string;
  G, Opt, RawOpt: TJSONObject;
begin
  if B = nil then Exit;
  Mode := LowerCase(JStr(B, 'mode'));
  Body.RawMode := Mode;
  if Mode = '' then
    Body.Mode := bmNone
  else if Mode = 'raw' then
  begin
    Body.Mode := bmRaw;
    Body.Raw := JStr(B, 'raw');
    Opt := JObj(B, 'options');
    RawOpt := JObj(Opt, 'raw');
    Body.Language := JStr(RawOpt, 'language');
  end
  else if Mode = 'urlencoded' then
  begin
    Body.Mode := bmUrlEncoded;
    LoadKeyValueArray(JArr(B, 'urlencoded'), Body.Params);
  end
  else if Mode = 'formdata' then
  begin
    Body.Mode := bmFormData;
    LoadFormData(JArr(B, 'formdata'), Body.Params);
  end
  else if Mode = 'graphql' then
  begin
    // Exporters send GraphQL as a JSON document {"query": ..., "variables": ...}.
    Body.Mode := bmGraphQL;
    G := JObj(B, 'graphql');
    Body.Language := 'json';
    Body.Raw := '{"query":"' + StringToJSONString(JStr(G, 'query'), False) +
                '","variables":' + JStr(G, 'variables', '{}') + '}';
  end
  else if Mode = 'file' then
  begin
    Body.Mode := bmFile;
    Body.FilePath := JStr(JObj(B, 'file'), 'src');
  end
  else
    Body.Mode := bmUnknown;
end;

{ ---- v2.x ---- }

procedure LoadV2Request(Item: TJSONObject; Req: TRequest; AWarnings: TStrings);
var
  R: TJSONData;
  RO: TJSONObject;
  H: TJSONData;
begin
  R := Item.Find('request');
  if (R <> nil) and (R.JSONType = jtString) then
  begin
    // Shorthand: "request": "http://example.com/x" means a plain GET.
    Req.Url.Raw := R.AsString;
    LoadUrl(R, Req.Url);
  end
  else if (R <> nil) and (R.JSONType = jtObject) then
  begin
    RO := TJSONObject(R);
    Req.Method := UpperCase(JStr(RO, 'method', 'GET'));
    Req.Description := JStr(RO, 'description');
    LoadUrl(RO.Find('url'), Req.Url);
    H := RO.Find('header');
    if (H <> nil) and (H.JSONType = jtArray) then
      LoadKeyValueArray(TJSONArray(H), Req.Headers)
    else if (H <> nil) and (H.JSONType = jtString) then
      LoadHeaderString(H.AsString, Req.Headers);
    LoadBody(JObj(RO, 'body'), Req.Body);
    LoadAuth(JObj(RO, 'auth'), Req.Auth, 'Request "' + Req.Name + '"', AWarnings);
  end;
  LoadEvents(JArr(Item, 'event'), Req);
end;

procedure LoadV2Items(Arr: TJSONArray; Folder: TFolder; AWarnings: TStrings);
var
  I: Integer;
  Item: TJSONObject;
  Sub: TFolder;
  Req: TRequest;
  Name: string;
begin
  if Arr = nil then Exit;
  for I := 0 to Arr.Count - 1 do
  begin
    if Arr[I].JSONType <> jtObject then Continue;
    Item := TJSONObject(Arr[I]);
    if JArr(Item, 'item') <> nil then
    begin
      Name := JStr(Item, 'name');
      if Name = '' then Name := UnnamedFolder;
      Sub := Folder.AddFolder(Name);
      Sub.Description := JStr(Item, 'description');
      LoadAuth(JObj(Item, 'auth'), Sub.Auth, 'Folder "' + Name + '"', AWarnings);
      LoadEvents(JArr(Item, 'event'), Sub);
      LoadV2Items(JArr(Item, 'item'), Sub, AWarnings);
    end
    else
    begin
      Name := JStr(Item, 'name');
      if Name = '' then Name := UnnamedRequest;
      Req := Folder.AddRequest(Name);
      LoadV2Request(Item, Req, AWarnings);
    end;
  end;
end;

procedure LoadV2Collection(Root: TJSONObject; Coll: TCollection; AWarnings: TStrings);
var
  Info: TJSONObject;
  Schema: string;
begin
  Info := JObj(Root, 'info');
  Coll.Name := JStr(Info, 'name');
  if Coll.Name = '' then Coll.Name := JStr(Root, 'name', 'Collection');
  Coll.Description := JStr(Info, 'description');
  Schema := JStr(Info, 'schema');
  if Pos('v2.1', Schema) > 0 then
    Coll.SchemaVersion := svV21
  else if (Pos('v2.0', Schema) > 0) or (Pos('/v2/', Schema) > 0) then
    Coll.SchemaVersion := svV20
  else
    Coll.SchemaVersion := svV20;   // no schema URL: treat as the older v2 shape
  // Both spellings exist in the wild.
  LoadKeyValueArray(JArr(Root, 'variable'), Coll.Variables);
  LoadKeyValueArray(JArr(Root, 'variables'), Coll.Variables);
  LoadAuth(JObj(Root, 'auth'), Coll.Auth, 'Collection', AWarnings);
  LoadEvents(JArr(Root, 'event'), Coll);
  LoadV2Items(JArr(Root, 'item'), Coll, AWarnings);
end;

{ ---- v1 ---- }

procedure LoadV1Request(R: TJSONObject; Req: TRequest; AWarnings: TStrings);
var
  DataMode, RawData: string;
  Data: TJSONArray;
begin
  Req.Method := UpperCase(JStr(R, 'method', 'GET'));
  Req.Description := JStr(R, 'description');
  LoadUrl(R.Find('url'), Req.Url);
  LoadHeaderString(JStr(R, 'headers'), Req.Headers);
  DataMode := LowerCase(JStr(R, 'dataMode'));
  RawData := JStr(R, 'rawModeData');
  Data := JArr(R, 'data');
  Req.Body.RawMode := DataMode;
  if (DataMode = 'raw') or ((DataMode = '') and (RawData <> '')) then
  begin
    Req.Body.Mode := bmRaw;
    Req.Body.Raw := RawData;
  end
  else if DataMode = 'urlencoded' then
  begin
    Req.Body.Mode := bmUrlEncoded;
    LoadKeyValueArray(Data, Req.Body.Params);
  end
  else if (DataMode = 'params') or ((DataMode = '') and (Data <> nil) and (Data.Count > 0)) then
  begin
    Req.Body.Mode := bmFormData;
    LoadFormData(Data, Req.Body.Params);
  end
  else
    Req.Body.Mode := bmNone;
  LoadAuth(JObj(R, 'auth'), Req.Auth, 'Request "' + Req.Name + '"', AWarnings);
  Req.PreRequestScript := StringReplace(JStr(R, 'preRequestScript'), #13, '', [rfReplaceAll]);
  Req.TestScript := StringReplace(JStr(R, 'tests'), #13, '', [rfReplaceAll]);
end;

procedure LoadV1Collection(Root: TJSONObject; Coll: TCollection; AWarnings: TStrings);
var
  Requests, Folders, Order: TJSONArray;
  I, J: Integer;
  ById: TStringList;     // request id -> index into Requests
  Placed: array of Boolean;
  F: TJSONObject;
  Folder: TFolder;
  Req: TRequest;
  Name, Id: string;

  procedure PlaceRequest(const AId: string; Into: TFolder);
  var
    Idx: Integer;
    RO: TJSONObject;
  begin
    Idx := ById.IndexOf(AId);
    if Idx < 0 then Exit;
    Idx := PtrInt(ById.Objects[Idx]);
    if Placed[Idx] then Exit;
    Placed[Idx] := True;
    RO := TJSONObject(Requests[Idx]);
    Name := JStr(RO, 'name');
    if Name = '' then Name := UnnamedRequest;
    Req := Into.AddRequest(Name);
    LoadV1Request(RO, Req, AWarnings);
  end;

begin
  Coll.SchemaVersion := svV1;
  Coll.Name := JStr(Root, 'name', 'Collection');
  Coll.Description := JStr(Root, 'description');
  Requests := JArr(Root, 'requests');
  if Requests = nil then Exit;
  ById := TStringList.Create;
  try
    SetLength(Placed, Requests.Count);
    for I := 0 to Requests.Count - 1 do
    begin
      Placed[I] := False;
      if Requests[I].JSONType = jtObject then
        ById.AddObject(JStr(TJSONObject(Requests[I]), 'id'), TObject(PtrInt(I)));
    end;
    // Folders first, each listing its request ids in "order".
    Folders := JArr(Root, 'folders');
    if Folders <> nil then
      for I := 0 to Folders.Count - 1 do
      begin
        if Folders[I].JSONType <> jtObject then Continue;
        F := TJSONObject(Folders[I]);
        Name := JStr(F, 'name');
        if Name = '' then Name := UnnamedFolder;
        Folder := Coll.AddFolder(Name);
        Folder.Description := JStr(F, 'description');
        Order := JArr(F, 'order');
        if Order <> nil then
          for J := 0 to Order.Count - 1 do
            PlaceRequest(Order[J].AsString, Folder);
      end;
    // Root-level requests in the collection's own "order".
    Order := JArr(Root, 'order');
    if Order <> nil then
      for J := 0 to Order.Count - 1 do
        PlaceRequest(Order[J].AsString, Coll);
    // Anything not referenced by any order list still gets shown.
    for I := 0 to Requests.Count - 1 do
      if (not Placed[I]) and (Requests[I].JSONType = jtObject) then
      begin
        Id := JStr(TJSONObject(Requests[I]), 'id');
        if Id <> '' then
          PlaceRequest(Id, Coll)
        else
        begin
          Placed[I] := True;
          Req := Coll.AddRequest(JStr(TJSONObject(Requests[I]), 'name', UnnamedRequest));
          LoadV1Request(TJSONObject(Requests[I]), Req, AWarnings);
        end;
      end;
  finally
    ById.Free;
  end;
end;

{ ---- public ---- }

function LoadCollectionFromString(const AJson: string; AWarnings: TStrings): TCollection;
var
  Data: TJSONData;
  Root: TJSONObject;
begin
  Data := ParseJson(AJson);
  try
    if Data.JSONType <> jtObject then
      raise EMailBoyLoad.Create('Not a collection: top level is not a JSON object');
    Root := TJSONObject(Data);
    Result := TCollection.Create;
    try
      if (JArr(Root, 'item') <> nil) or (JObj(Root, 'info') <> nil) then
        LoadV2Collection(Root, Result, AWarnings)
      else if JArr(Root, 'requests') <> nil then
        LoadV1Collection(Root, Result, AWarnings)
      else if JArr(Root, 'values') <> nil then
        raise EMailBoyLoad.Create('This is an environment file, not a collection')
      else
        raise EMailBoyLoad.Create('Not a collection: no "item", "info" or "requests" found');
    except
      Result.Free;
      raise;
    end;
  finally
    Data.Free;
  end;
end;

function LoadCollectionFromFile(const AFileName: string; AWarnings: TStrings): TCollection;
begin
  Result := LoadCollectionFromString(ReadFileToString(AFileName), AWarnings);
  Result.SourceFile := AFileName;
end;

function LoadEnvironmentFromString(const AJson: string): TEnvironment;
var
  Data: TJSONData;
  Root: TJSONObject;
  Values: TJSONArray;
begin
  Data := ParseJson(AJson);
  try
    if Data.JSONType <> jtObject then
      raise EMailBoyLoad.Create('Not an environment: top level is not a JSON object');
    Root := TJSONObject(Data);
    Values := JArr(Root, 'values');
    if Values = nil then
      raise EMailBoyLoad.Create('Not an environment: no "values" array');
    Result := TEnvironment.Create;
    Result.Name := JStr(Root, 'name', 'Environment');
    LoadKeyValueArray(Values, Result.Variables);
  finally
    Data.Free;
  end;
end;

function LoadEnvironmentFromFile(const AFileName: string): TEnvironment;
begin
  Result := LoadEnvironmentFromString(ReadFileToString(AFileName));
  Result.SourceFile := AFileName;
end;

function SaveEnvironmentToString(AEnv: TEnvironment): string;
var
  Root, O: TJSONObject;
  Values: TJSONArray;
  I: Integer;
  KV: TKeyValue;
begin
  Root := TJSONObject.Create;
  try
    Root.Add('name', AEnv.Name);
    Values := TJSONArray.Create;
    Root.Add('values', Values);
    for I := 0 to AEnv.Variables.Count - 1 do
    begin
      KV := AEnv.Variables[I];
      if Trim(KV.Key) = '' then
        Continue;
      O := TJSONObject.Create;
      O.Add('key', KV.Key);
      O.Add('value', KV.Value);
      O.Add('enabled', KV.Enabled);
      Values.Add(O);
    end;
    Result := Root.FormatJSON([], 2) + LineEnding;
  finally
    Root.Free;
  end;
end;

procedure SaveEnvironmentToFile(AEnv: TEnvironment; const AFileName: string);
var
  FS: TFileStream;
  S: string;
begin
  S := SaveEnvironmentToString(AEnv);
  try
    FS := TFileStream.Create(AFileName, fmCreate);
    try
      if S <> '' then
        FS.WriteBuffer(S[1], Length(S));
    finally
      FS.Free;
    end;
  except
    on E: EStreamError do
      raise EMailBoyLoad.CreateFmt('Cannot write %s: %s', [AFileName, E.Message]);
    on E: EFCreateError do
      raise EMailBoyLoad.CreateFmt('Cannot write %s: %s', [AFileName, E.Message]);
  end;
  AEnv.SourceFile := AFileName;
end;

function IsEnvironmentJson(const AJson: string): Boolean;
var
  Data: TJSONData;
begin
  Result := False;
  try
    Data := GetJSON(AJson);
  except
    Exit;
  end;
  if Data = nil then Exit;
  try
    Result := (Data.JSONType = jtObject) and (JArr(TJSONObject(Data), 'values') <> nil)
      and (JArr(TJSONObject(Data), 'item') = nil);
  finally
    Data.Free;
  end;
end;

end.
