unit mbExecutor;

// Runs one request end to end: resolve variables, build argv, run curl (or
// wget), parse the response. Owns the two lifecycle hooks. Version 1 attaches
// nothing to the hooks; response capture and later a script engine plug in
// here without touching anything else.

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, mbModel, mbVariables, mbRequestBuilder, mbRunner, mbResponse, mbHook;

type
  TExecuteOutcome = (
    eoOk,             // a response came back (any HTTP status)
    eoNoTransport,    // neither curl nor wget found
    eoLaunchFailed,   // transport found but could not be started
    eoTransportError, // curl/wget ran and reported a failure (DNS, refused, TLS)
    eoTimeout,        // killed after the time limit
    eoBadResponse,    // output could not be parsed as HTTP
    eoHookError,      // the before-send hook failed; nothing was sent
    eoUnresolvedUrl   // the URL still had {{variables}} after resolution and the hook; nothing was sent
  );

  TExecuteOptions = record
    Build: TBuildOptions;
    Transport: TTransport;     // trNone = detect (curl first, then wget)
    KillAfterMs: Integer;      // hard kill, 0 = derive from Build.TimeoutSec
  end;

  TExecuteResult = class
  public
    Outcome: TExecuteOutcome;
    ErrorMessage: string;
    Transport: TTransport;
    Executable: string;
    Resolved: TResolvedRequest;   // nil only if the request itself was nil
    Args: TStringList;            // argv actually used (exe not included)
    Process: TProcessResult;      // nil if nothing was run
    Response: TResponse;          // nil unless Outcome = eoOk
    Warnings: TStringList;        // resolution warnings + unresolved variables
    HookBefore: THookResult;      // nil when no hook is configured
    HookAfter: THookResult;       // nil when no hook ran after (no hook, or send failed)
    constructor Create;
    destructor Destroy; override;
    function Succeeded: Boolean;
    // True if a hook ran and failed in either phase.
    function HookFailed: Boolean;
    function HookMs: Integer;
  end;

  TBeforeSendHook = procedure(AResolved: TResolvedRequest; AScope: TVariableScope) of object;
  TAfterResponseHook = procedure(AResolved: TResolvedRequest; AResponse: TResponse;
    AScope: TVariableScope) of object;

  TRequestExecutor = class
  private
    FBeforeSend: TBeforeSendHook;
    FAfterResponse: TAfterResponseHook;
  public
    Options: TExecuteOptions;
    Hook: THookRunner;            // owned; set Hook.Command to enable
    Context: THookContext;        // files handed to the hook; Proxy is filled per request if empty
    constructor Create;
    destructor Destroy; override;
    // AScope may be nil. The caller frees the result.
    function Execute(ARequest: TRequest; AScope: TVariableScope): TExecuteResult;
    property BeforeSend: TBeforeSendHook read FBeforeSend write FBeforeSend;
    property AfterResponse: TAfterResponseHook read FAfterResponse write FAfterResponse;
  end;

function DefaultExecuteOptions: TExecuteOptions;
function OutcomeToString(O: TExecuteOutcome): string;

// The distinct {{names}} still present in S, in order. '' when there are none.
function UnresolvedNamesIn(const S: string): string;

// wget -S writes the status line and headers to stderr, indented by two
// spaces, and the body to stdout. This rebuilds the curl -i shape so one
// parser serves both transports.
function WgetToCurlOutput(const AStdErr, AStdOut: string): string;

implementation

function DefaultExecuteOptions: TExecuteOptions;
begin
  Result.Build := DefaultBuildOptions;
  Result.Transport := trNone;
  Result.KillAfterMs := 0;
end;

function OutcomeToString(O: TExecuteOutcome): string;
begin
  case O of
    eoOk:             Result := 'ok';
    eoNoTransport:    Result := 'no-transport';
    eoLaunchFailed:   Result := 'launch-failed';
    eoTransportError: Result := 'transport-error';
    eoTimeout:        Result := 'timeout';
    eoHookError:      Result := 'hook-error';
    eoUnresolvedUrl:  Result := 'unresolved-url';
  else
    Result := 'bad-response';
  end;
end;

function UnresolvedNamesIn(const S: string): string;
var
  P, Q: Integer;
  Name: string;
begin
  Result := '';
  P := Pos('{{', S);
  while P > 0 do
  begin
    Q := Pos('}}', S, P + 2);
    if Q = 0 then
      Break;
    Name := '{{' + Copy(S, P + 2, Q - P - 2) + '}}';
    if Pos(Name, Result) = 0 then
    begin
      if Result <> '' then Result := Result + ', ';
      Result := Result + Name;
    end;
    P := Pos('{{', S, Q + 2);
  end;
end;

function WgetToCurlOutput(const AStdErr, AStdOut: string): string;
var
  Lines: TStringList;
  I: Integer;
  L: string;
  InBlock: Boolean;
begin
  Result := '';
  Lines := TStringList.Create;
  try
    Lines.Text := AStdErr;
    InBlock := False;
    for I := 0 to Lines.Count - 1 do
    begin
      L := Lines[I];
      if (Length(L) > 2) and (L[1] = ' ') and (L[2] = ' ') then
      begin
        L := Copy(L, 3, MaxInt);
        if Pos('HTTP/', L) = 1 then
        begin
          if Result <> '' then Result := Result + #13#10;   // close previous block (redirect)
          InBlock := True;
        end;
        if InBlock then Result := Result + L + #13#10;
      end
      else if InBlock and (Trim(L) = '') then
        Continue
      else if InBlock then
        InBlock := False;   // progress noise after the header block
    end;
    if Result <> '' then
      Result := Result + #13#10 + AStdOut;
  finally
    Lines.Free;
  end;
end;

{ TExecuteResult }

constructor TExecuteResult.Create;
begin
  inherited Create;
  Warnings := TStringList.Create;
  Transport := trNone;
end;

destructor TExecuteResult.Destroy;
begin
  HookAfter.Free;
  HookBefore.Free;
  Response.Free;
  Process.Free;
  Args.Free;
  Resolved.Free;
  Warnings.Free;
  inherited Destroy;
end;

function TExecuteResult.Succeeded: Boolean;
begin
  Result := (Outcome = eoOk) and (Response <> nil);
end;

function TExecuteResult.HookFailed: Boolean;
begin
  Result := ((HookBefore <> nil) and HookBefore.Ran and not HookBefore.Ok) or
            ((HookAfter <> nil) and HookAfter.Ran and not HookAfter.Ok) or
            ((HookBefore <> nil) and (HookBefore.ErrorMessage <> ''));
end;

function TExecuteResult.HookMs: Integer;
begin
  Result := 0;
  if HookBefore <> nil then Inc(Result, HookBefore.ElapsedMs);
  if HookAfter <> nil then Inc(Result, HookAfter.ElapsedMs);
end;

{ TRequestExecutor }

constructor TRequestExecutor.Create;
begin
  inherited Create;
  Options := DefaultExecuteOptions;
  Hook := THookRunner.Create;
end;

destructor TRequestExecutor.Destroy;
begin
  Hook.Free;
  inherited Destroy;
end;

function HookErrorText(const APhase: string; AReq: TRequest; H: THookResult): string;
begin
  Result := Format('hook error, %s "%s": %s', [APhase, AReq.Path, H.ErrorMessage]);
  if H.ErrorDetail <> '' then
    Result := Result + ' (' + H.ErrorDetail + ')';
end;

function TRequestExecutor.Execute(ARequest: TRequest; AScope: TVariableScope): TExecuteResult;
var
  Path, Raw: string;
  I, KillMs: Integer;
begin
  Result := TExecuteResult.Create;
  if ARequest = nil then
  begin
    Result.Outcome := eoBadResponse;
    Result.ErrorMessage := 'no request';
    Exit;
  end;

  Result.Resolved := ResolveRequest(ARequest, AScope);

  if Hook.Enabled then
  begin
    if Context.Proxy = '' then
      Context.Proxy := ProxyForUrl(Result.Resolved.Url);
    Result.HookBefore := Hook.RunBefore(Result.Resolved, AScope, ARequest, Context);
    if not Result.HookBefore.Ok then
    begin
      Result.Outcome := eoHookError;
      Result.ErrorMessage := HookErrorText('before', ARequest, Result.HookBefore);
      Result.Warnings.AddStrings(Result.Resolved.Warnings);
      Exit;
    end;
  end;
  if Assigned(FBeforeSend) then
    FBeforeSend(Result.Resolved, AScope);

  // Transport
  Result.Transport := Options.Transport;
  if Result.Transport = trNone then
    Result.Transport := DetectTransport(Path)
  else if Result.Transport = trCurl then
    Path := FindExecutable('curl')
  else
    Path := FindExecutable('wget');
  if (Result.Transport = trNone) or (Path = '') then
  begin
    Result.Outcome := eoNoTransport;
    Result.Transport := trNone;
    Result.ErrorMessage := 'neither curl nor wget was found on PATH';
    Exit;
  end;
  Result.Executable := Path;

  // curl cannot do anything useful with a literal {{host}}; it fails with three
  // lines about braces and port numbers that point nowhere. Say what happened.
  if Pos('{{', Result.Resolved.Url) > 0 then
  begin
    Result.Outcome := eoUnresolvedUrl;
    Result.ErrorMessage := 'URL still contains ' + UnresolvedNamesIn(Result.Resolved.Url) +
      ': not defined in any loaded environment, in the collection, or by a hook, ' +
      'or still holding its "put the ... value here" placeholder. Nothing was sent.';
    Result.Warnings.AddStrings(Result.Resolved.Warnings);
    Exit;
  end;

  if Result.Transport = trCurl then
    Result.Args := BuildCurlArgs(Result.Resolved, Options.Build)
  else
    Result.Args := BuildWgetArgs(Result.Resolved, Options.Build);

  // Warnings are gathered after building because the builders add some.
  Result.Warnings.AddStrings(Result.Resolved.Warnings);
  for I := 0 to Result.Resolved.Unresolved.Count - 1 do
    Result.Warnings.Add('unresolved variable {{' + Result.Resolved.Unresolved[I] + '}}');

  KillMs := Options.KillAfterMs;
  if (KillMs = 0) and (Options.Build.TimeoutSec > 0) then
    KillMs := (Options.Build.TimeoutSec + 5) * 1000;   // curl enforces its own limit first

  Result.Process := RunProcess(Path, Result.Args, KillMs);

  if not Result.Process.Started then
  begin
    Result.Outcome := eoLaunchFailed;
    Result.ErrorMessage := Result.Process.ErrorOutput;
    Exit;
  end;
  if Result.Process.TimedOut then
  begin
    Result.Outcome := eoTimeout;
    Result.ErrorMessage := Format('no response after %d ms', [Result.Process.ElapsedMs]);
    Exit;
  end;

  if Result.Transport = trCurl then
    Raw := Result.Process.Output
  else
    Raw := WgetToCurlOutput(Result.Process.ErrorOutput, Result.Process.Output);

  // curl: non-zero exit is a transport failure (HTTP errors still exit 0).
  // wget: exit 8 means "server returned an error" and the response is intact.
  if (Result.Process.ExitCode <> 0) and
     not ((Result.Transport = trWget) and (Result.Process.ExitCode = 8) and (Raw <> '')) then
  begin
    Result.Outcome := eoTransportError;
    Result.ErrorMessage := Trim(Result.Process.ErrorOutput);
    if Result.ErrorMessage = '' then
      Result.ErrorMessage := Format('%s exited with code %d', [ExtractFileName(Path), Result.Process.ExitCode]);
    Exit;
  end;

  Result.Response := ParseCurlOutput(Raw, Result.Process.ElapsedMs, Result.Process.ExitCode);
  if Result.Response.ParseError then
  begin
    Result.Outcome := eoBadResponse;
    Result.ErrorMessage := Result.Response.ParseErrorMessage;
    FreeAndNil(Result.Response);
    Exit;
  end;

  Result.Outcome := eoOk;
  if Hook.Enabled then
  begin
    I := Result.Resolved.Warnings.Count;
    Result.HookAfter := Hook.RunAfter(Result.Resolved, Result.Response, AScope, ARequest, Context);
    // Warnings the after hook added (variable scope fallbacks) are new.
    while I < Result.Resolved.Warnings.Count do
    begin
      Result.Warnings.Add(Result.Resolved.Warnings[I]);
      Inc(I);
    end;
    if not Result.HookAfter.Ok then
      Result.ErrorMessage := HookErrorText('after', ARequest, Result.HookAfter);
  end;
  if Assigned(FAfterResponse) then
    FAfterResponse(Result.Resolved, Result.Response, AScope);
end;

end.
