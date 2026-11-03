unit mbRequestBuilder;

// Turns a TRequest plus a TVariableScope into a flattened, fully resolved
// TResolvedRequest, and that into a curl (or wget) argument vector.
// Never a shell command string: always one argument per list entry, the
// executable itself not included. No LCL, no JSON, no process.

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, mbModel, mbVariables;

type
  TResolvedRequest = class
  public
    Method: string;
    Url: string;                  // final URL including the query string
    Headers: TKeyValueList;       // enabled only, variables resolved
    BodyMode: TBodyMode;
    BodyText: string;             // raw / graphql / urlencoded (already encoded)
    FormFields: TKeyValueList;    // formdata only, enabled only, IsFile preserved
    BodyFilePath: string;         // mode = file
    AuthType: TAuthType;
    AuthUser: string;
    AuthPassword: string;
    BearerToken: string;
    Unresolved: TStringList;      // distinct variable names nobody could resolve
    Warnings: TStringList;
    constructor Create;
    destructor Destroy; override;
    { Case-insensitive: is there an enabled header with that name? }
    function HasHeader(const AName: string): Boolean;
  end;

  TBuildOptions = record
    TimeoutSec: Integer;          // 0 = no limit
    FollowRedirects: Boolean;
    Insecure: Boolean;            // skip TLS verification
    MaxRedirects: Integer;
  end;

function DefaultBuildOptions: TBuildOptions;

{ AScope may be nil: no substitution, every placeholder is reported unresolved.
  The caller owns the result. }
function ResolveRequest(ARequest: TRequest; AScope: TVariableScope): TResolvedRequest;

{ One argument per entry, curl executable not included. The caller frees.
  May append to AResolved.Warnings. }
function BuildCurlArgs(AResolved: TResolvedRequest; AOptions: TBuildOptions): TStringList;

{ Fallback transport. Same observable behaviour where wget allows it;
  formdata cannot be expressed and is dropped with a warning. The caller frees. }
function BuildWgetArgs(AResolved: TResolvedRequest; AOptions: TBuildOptions): TStringList;

{ RFC 3986 percent-encoding; unreserved A-Z a-z 0-9 - . _ ~ are kept. }
function PercentEncode(const S: string): string;

{ Single-line shell-quoted rendering for showing the user. Display only, never executed. }
function ArgsToDisplayString(Args: TStrings): string;

implementation

{ TResolvedRequest }

constructor TResolvedRequest.Create;
begin
  inherited Create;
  Method := 'GET';
  BodyMode := bmNone;
  AuthType := atNone;
  Headers := TKeyValueList.Create;
  FormFields := TKeyValueList.Create;
  Unresolved := TStringList.Create;
  Warnings := TStringList.Create;
end;

destructor TResolvedRequest.Destroy;
begin
  Warnings.Free;
  Unresolved.Free;
  FormFields.Free;
  Headers.Free;
  inherited Destroy;
end;

function TResolvedRequest.HasHeader(const AName: string): Boolean;
begin
  Result := Headers.Find(AName) <> nil;
end;

{ options }

function DefaultBuildOptions: TBuildOptions;
begin
  Result.TimeoutSec := 30;
  Result.FollowRedirects := True;
  Result.Insecure := False;
  Result.MaxRedirects := 10;
end;

{ helpers }

function PercentEncode(const S: string): string;
const
  Hex = '0123456789ABCDEF';
var
  I: Integer;
  C: Char;
begin
  Result := '';
  for I := 1 to Length(S) do
  begin
    C := S[I];
    if C in ['A'..'Z', 'a'..'z', '0'..'9', '-', '.', '_', '~'] then
      Result := Result + C
    else
      Result := Result + '%' + Hex[(Ord(C) shr 4) + 1] + Hex[(Ord(C) and 15) + 1];
  end;
end;

function ArgsToDisplayString(Args: TStrings): string;
var
  I, J: Integer;
  A: string;
  Plain: Boolean;
begin
  Result := '';
  for I := 0 to Args.Count - 1 do
  begin
    A := Args[I];
    Plain := A <> '';
    for J := 1 to Length(A) do
      if not (A[J] in ['A'..'Z', 'a'..'z', '0'..'9', '_', '.', '/', ':', '=', '@', '%', '-']) then
      begin
        Plain := False;
        Break;
      end;
    if not Plain then
      A := '''' + StringReplace(A, '''', '''\''''', [rfReplaceAll]) + '''';
    if I > 0 then
      Result := Result + ' ';
    Result := Result + A;
  end;
end;

// Resolves S against AScope, collecting unresolved names into R.Unresolved.
// With no scope nothing is substituted and every placeholder counts as unresolved.
function Res(const S: string; AScope: TVariableScope; R: TResolvedRequest): string;
var
  Names: TStringList;
  I: Integer;
begin
  if AScope <> nil then
    Exit(AScope.Resolve(S, R.Unresolved));
  Result := S;
  if Pos('{{', S) = 0 then Exit;
  Names := TStringList.Create;
  try
    TVariableScope.FindPlaceholders(S, Names);
    for I := 0 to Names.Count - 1 do
      if R.Unresolved.IndexOf(Names[I]) < 0 then
        R.Unresolved.Add(Names[I]);
  finally
    Names.Free;
  end;
end;

// Replaces the path segment ":Name" in Url. The segment must start after a '/'
// and end at the end of the string or before '/', '?' or '#'.
function ReplacePathVariable(const Url, Name, Value: string): string;
var
  P, After: Integer;
  Needle: string;
begin
  Result := Url;
  Needle := '/:' + Name;
  P := Pos(Needle, Result);
  while P > 0 do
  begin
    After := P + Length(Needle);
    if (After > Length(Result)) or (Result[After] in ['/', '?', '#']) then
    begin
      Result := Copy(Result, 1, P) + Value + Copy(Result, After, MaxInt);
      P := Pos(Needle, Result, P + 1 + Length(Value));
    end
    else
      P := Pos(Needle, Result, P + 1);
  end;
end;

function PathVariablePresent(const Url, Name: string): Boolean;
var
  P, After: Integer;
  Needle: string;
begin
  Result := False;
  Needle := '/:' + Name;
  P := Pos(Needle, Url);
  while P > 0 do
  begin
    After := P + Length(Needle);
    if (After > Length(Url)) or (Url[After] in ['/', '?', '#']) then
      Exit(True);
    P := Pos(Needle, Url, P + 1);
  end;
end;

function ContentTypeForLanguage(const ALanguage: string): string;
var
  L: string;
begin
  L := LowerCase(Trim(ALanguage));
  if L = 'json' then
    Result := 'application/json'
  else if L = 'xml' then
    Result := 'application/xml'
  else if L = 'text' then
    Result := 'text/plain'
  else if L = 'javascript' then
    Result := 'application/javascript'
  else if L = 'html' then
    Result := 'text/html'
  else
    Result := '';
end;

{ ResolveRequest }

procedure ResolveUrl(ARequest: TRequest; AScope: TVariableScope; R: TResolvedRequest);
var
  I: Integer;
  Url, Key, Value, Query: string;
  KV: TKeyValue;
begin
  Url := Res(ARequest.Url.Base, AScope, R);
  for I := 0 to ARequest.Url.PathVariables.Count - 1 do
  begin
    KV := ARequest.Url.PathVariables[I];
    if (KV.Key = '') or (not PathVariablePresent(Url, KV.Key)) then
      Continue;
    Value := Res(KV.Value, AScope, R);
    if Value = '' then
      R.Warnings.Add('path variable ' + KV.Key + ' has no value')
    else
      Url := ReplacePathVariable(Url, KV.Key, Value);
  end;
  Query := '';
  for I := 0 to ARequest.Url.Query.Count - 1 do
  begin
    KV := ARequest.Url.Query[I];
    if not KV.Enabled then Continue;
    Key := Res(KV.Key, AScope, R);
    if Key = '' then Continue;
    Value := Res(KV.Value, AScope, R);
    if Query <> '' then
      Query := Query + '&';
    Query := Query + Key + '=' + Value;
  end;
  if Query <> '' then
    Url := Url + '?' + Query;
  R.Url := Url;
end;

procedure ResolveHeaders(ARequest: TRequest; AScope: TVariableScope; R: TResolvedRequest);
var
  I: Integer;
  KV: TKeyValue;
  Key: string;
begin
  for I := 0 to ARequest.Headers.Count - 1 do
  begin
    KV := ARequest.Headers[I];
    if not KV.Enabled then Continue;
    Key := Res(KV.Key, AScope, R);
    if Key = '' then Continue;
    R.Headers.Add(Key, Res(KV.Value, AScope, R));
  end;
end;

procedure AddContentTypeIfAbsent(R: TResolvedRequest; const AType: string);
begin
  if (AType <> '') and (not R.HasHeader('Content-Type')) then
    R.Headers.Add('Content-Type', AType);
end;

procedure ResolveBody(ARequest: TRequest; AScope: TVariableScope; R: TResolvedRequest);
var
  I: Integer;
  B: TBody;
  KV, F: TKeyValue;
begin
  B := ARequest.Body;
  R.BodyMode := B.Mode;
  case B.Mode of
    bmRaw:
      begin
        R.BodyText := Res(B.Raw, AScope, R);
        AddContentTypeIfAbsent(R, ContentTypeForLanguage(B.Language));
      end;
    bmGraphQL:
      begin
        R.BodyText := Res(B.Raw, AScope, R);
        AddContentTypeIfAbsent(R, 'application/json');
      end;
    bmUrlEncoded:
      begin
        R.BodyText := '';
        for I := 0 to B.Params.Count - 1 do
        begin
          KV := B.Params[I];
          if not KV.Enabled then Continue;
          if R.BodyText <> '' then
            R.BodyText := R.BodyText + '&';
          R.BodyText := R.BodyText
            + PercentEncode(Res(KV.Key, AScope, R)) + '='
            + PercentEncode(Res(KV.Value, AScope, R));
        end;
        AddContentTypeIfAbsent(R, 'application/x-www-form-urlencoded');
      end;
    bmFormData:
      for I := 0 to B.Params.Count - 1 do
      begin
        KV := B.Params[I];
        if not KV.Enabled then Continue;
        F := R.FormFields.Add(Res(KV.Key, AScope, R), Res(KV.Value, AScope, R));
        F.IsFile := KV.IsFile;
        F.Description := KV.Description;
      end;
    bmFile:
      R.BodyFilePath := Res(B.FilePath, AScope, R);
    bmUnknown:
      R.Warnings.Add('body mode "' + B.RawMode + '" not supported, request sent without a body');
  end;
end;

procedure ResolveAuth(ARequest: TRequest; AScope: TVariableScope; R: TResolvedRequest);
var
  A: TAuth;
begin
  A := ARequest.EffectiveAuth;
  R.AuthType := A.AuthType;
  case A.AuthType of
    atBasic:
      begin
        R.AuthUser := Res(A.Param('username'), AScope, R);
        R.AuthPassword := Res(A.Param('password'), AScope, R);
      end;
    atBearer:
      R.BearerToken := Res(A.Param('token'), AScope, R);
    atOther:
      R.Warnings.Add('auth type ' + A.RawType + ' not supported, request sent without it');
  end;
end;

function ResolveRequest(ARequest: TRequest; AScope: TVariableScope): TResolvedRequest;
begin
  Result := TResolvedRequest.Create;
  try
    Result.Method := UpperCase(Trim(ARequest.Method));
    if Result.Method = '' then
      Result.Method := 'GET';
    ResolveUrl(ARequest, AScope, Result);
    ResolveHeaders(ARequest, AScope, Result);
    ResolveBody(ARequest, AScope, Result);
    ResolveAuth(ARequest, AScope, Result);
  except
    Result.Free;
    raise;
  end;
end;

{ curl }

function HeaderArg(KV: TKeyValue): string;
begin
  // curl: "Name;" sends a header with an empty value, "Name:" would remove it.
  if KV.Value = '' then
    Result := KV.Key + ';'
  else
    Result := KV.Key + ': ' + KV.Value;
end;

function BuildCurlArgs(AResolved: TResolvedRequest; AOptions: TBuildOptions): TStringList;
var
  I: Integer;
  IsHead: Boolean;
  F: TKeyValue;
begin
  Result := TStringList.Create;
  try
    IsHead := AResolved.Method = 'HEAD';
    Result.Add('-s');
    Result.Add('-S');
    if not IsHead then
      Result.Add('-i');
    if AOptions.FollowRedirects then
    begin
      Result.Add('-L');
      Result.Add('--max-redirs');
      Result.Add(IntToStr(AOptions.MaxRedirects));
    end;
    if AOptions.TimeoutSec > 0 then
    begin
      Result.Add('--max-time');
      Result.Add(IntToStr(AOptions.TimeoutSec));
    end;
    if AOptions.Insecure then
      Result.Add('-k');
    if IsHead then
      Result.Add('-I')
    else
    begin
      Result.Add('-X');
      Result.Add(AResolved.Method);
    end;
    for I := 0 to AResolved.Headers.Count - 1 do
    begin
      Result.Add('-H');
      Result.Add(HeaderArg(AResolved.Headers[I]));
    end;
    case AResolved.AuthType of
      atBasic:
        begin
          Result.Add('-u');
          Result.Add(AResolved.AuthUser + ':' + AResolved.AuthPassword);
        end;
      atBearer:
        if AResolved.HasHeader('Authorization') then
          AResolved.Warnings.Add('bearer auth ignored: request already carries an Authorization header')
        else
        begin
          Result.Add('-H');
          Result.Add('Authorization: Bearer ' + AResolved.BearerToken);
        end;
    end;
    case AResolved.BodyMode of
      bmRaw, bmGraphQL, bmUrlEncoded:
        // An empty body sends nothing: TProcess on Unix cannot pass an empty
        // argument (it truncates argv there), and curl sends no body anyway.
        if AResolved.BodyText <> '' then
        begin
          Result.Add('--data-binary');
          Result.Add(AResolved.BodyText);
        end;
      bmFormData:
        for I := 0 to AResolved.FormFields.Count - 1 do
        begin
          F := AResolved.FormFields[I];
          if F.IsFile then
          begin
            Result.Add('-F');
            Result.Add(F.Key + '=@' + F.Value);
          end
          else
          begin
            // --form-string never interprets a leading '@' or '<' in the value.
            Result.Add('--form-string');
            Result.Add(F.Key + '=' + F.Value);
          end;
        end;
      bmFile:
        begin
          Result.Add('--data-binary');
          Result.Add('@' + AResolved.BodyFilePath);
        end;
    end;
    Result.Add(AResolved.Url);
  except
    Result.Free;
    raise;
  end;
end;

{ wget }

function BuildWgetArgs(AResolved: TResolvedRequest; AOptions: TBuildOptions): TStringList;
var
  I: Integer;
  KV: TKeyValue;
begin
  Result := TStringList.Create;
  try
    Result.Add('-S');                 // server response headers (to stderr)
    Result.Add('-O');
    Result.Add('-');
    if AOptions.FollowRedirects then
      Result.Add('--max-redirect=' + IntToStr(AOptions.MaxRedirects))
    else
      Result.Add('--max-redirect=0');
    if AOptions.TimeoutSec > 0 then
      Result.Add('--timeout=' + IntToStr(AOptions.TimeoutSec));
    if AOptions.Insecure then
      Result.Add('--no-check-certificate');
    Result.Add('--method=' + AResolved.Method);
    for I := 0 to AResolved.Headers.Count - 1 do
    begin
      KV := AResolved.Headers[I];
      if KV.Value = '' then
        Result.Add('--header=' + KV.Key + ':')
      else
        Result.Add('--header=' + KV.Key + ': ' + KV.Value);
    end;
    case AResolved.AuthType of
      atBasic:
        begin
          // wget only sends credentials after a 401 unless told otherwise.
          Result.Add('--auth-no-challenge');
          Result.Add('--user=' + AResolved.AuthUser);
          Result.Add('--password=' + AResolved.AuthPassword);
        end;
      atBearer:
        if AResolved.HasHeader('Authorization') then
          AResolved.Warnings.Add('bearer auth ignored: request already carries an Authorization header')
        else
          Result.Add('--header=Authorization: Bearer ' + AResolved.BearerToken);
    end;
    case AResolved.BodyMode of
      bmRaw, bmGraphQL, bmUrlEncoded:
        Result.Add('--body-data=' + AResolved.BodyText);
      bmFormData:
        AResolved.Warnings.Add('wget cannot send multipart form-data, request sent without a body');
      bmFile:
        Result.Add('--body-file=' + AResolved.BodyFilePath);
    end;
    Result.Add(AResolved.Url);
  except
    Result.Free;
    raise;
  end;
end;

end.
