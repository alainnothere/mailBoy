unit mbCli;

// Command-line front end. Everything here is testable in-process: the
// arguments come in as a list, the output goes to two string lists, and
// the exit code is the return value. mbCliBoot does the process-level
// plumbing.

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils;

const
  MailBoyVersion = '0.1.0';

  // Exit codes. HTTP status is data, not failure.
  ExitOk = 0;
  ExitTransport = 1;     // curl ran but could not reach the server, or timed out
  ExitFile = 2;          // bad arguments, missing or unparseable file, or a URL with undefined {{variables}}
  ExitNotFound = 3;      // request name not found or ambiguous
  ExitNoTransport = 4;   // neither curl nor wget on PATH
  ExitHook = 5;          // the hook program failed (before: nothing sent; after: response delivered)

type
  TCliMode = (cmNone, cmRun, cmList, cmHelp, cmVersion);

  TCliOptions = record
    Mode: TCliMode;
    RequestName: string;
    CollectionFile: string;
    EnvFile: string;
    Vars: TStringList;       // name=value overrides, caller owns
    Json: Boolean;
    TimeoutSec: Integer;     // -1 = default
    Follow: Boolean;
    Insecure: Boolean;
    Verbose: Boolean;        // print the curl command line to stderr
    HookCommand: string;     // path of the hook program, '' = none
    HookTimeoutSec: Integer; // -1 = default (30)
  end;

// True if the command line carries any option (ParamStr based). A bare
// file path alone opens the GUI; anything starting with "-" goes to the CLI.
function IsCliInvocation: Boolean;

// Parses AArgs (without the program name). Returns False with AError set on
// a bad command line. AOpts.Vars must be created by the caller.
function ParseCliArgs(AArgs: TStrings; var AOpts: TCliOptions; out AError: string): Boolean;

// Performs the work. Normal output goes to AOut, diagnostics to AErr.
function RunCliWith(const AOpts: TCliOptions; AOut, AErr: TStrings): Integer;

// Process-level entry: ParamStr -> parse -> run -> write to stdout/stderr.
function RunCliMain: Integer;

function CliUsage: string;

implementation

uses
  fpjson, mbModel, mbLoader, mbVariables, mbRequestBuilder, mbRunner, mbResponse,
  mbExecutor, mbHook;

function CliUsage: string;
begin
  Result :=
    'mailBoy ' + MailBoyVersion + ' - fires requests from API collection files through curl' + LineEnding +
    LineEnding +
    'Usage:' + LineEnding +
    '  mailBoy                                   open the GUI' + LineEnding +
    '  mailBoy <collection.json>                 open the GUI with that collection' + LineEnding +
    '  mailBoy --list --collection <file>        list request names, one per line' + LineEnding +
    '                                            (--verbose marks [pre] [test] scripts)' + LineEnding +
    '  mailBoy --run <request> --collection <file> [options]' + LineEnding +
    LineEnding +
    'Options for --run:' + LineEnding +
    '  --env <file>          environment file (variables override collection variables)' + LineEnding +
    '  --var name=value      override a variable; repeatable' + LineEnding +
    '  --json                print one JSON object instead of text' + LineEnding +
    '  --timeout <seconds>   curl --max-time (default 30, 0 = none)' + LineEnding +
    '  --no-follow           do not follow redirects' + LineEnding +
    '  --insecure            skip TLS certificate verification' + LineEnding +
    '  --verbose             print the curl command line to stderr' + LineEnding +
    '  --hook <program>      run this program before send and after the response,' + LineEnding +
    '                        JSON in on stdin, JSON out on stdout (see the ? in the GUI)' + LineEnding +
    '  --hook-timeout <sec>  kill the hook after this long (default 30)' + LineEnding +
    LineEnding +
    '<request> is the request name, or "Folder/Sub/name" when names collide.' + LineEnding +
    LineEnding +
    'Exit codes: 0 response received (any HTTP status), 1 transport failure or timeout,' + LineEnding +
    '  2 bad arguments or file, or a URL variable nobody defined, 3 request not found' + LineEnding +
    '  or ambiguous, 4 curl/wget not found,' + LineEnding +
    '  5 hook failed.';
end;

function IsCliInvocation: Boolean;
var
  I: Integer;
  S: string;
begin
  Result := False;
  for I := 1 to ParamCount do
  begin
    S := ParamStr(I);
    // Any option at all means the command line is for the CLI parser, so an
    // unknown option is reported as such instead of opening the GUI.
    if (S <> '') and (S[1] = '-') then
      Exit(True);
  end;
end;

function ParseCliArgs(AArgs: TStrings; var AOpts: TCliOptions; out AError: string): Boolean;
var
  I: Integer;
  A: string;

  function NeedValue(const Flag: string): Boolean;
  begin
    Result := I + 1 < AArgs.Count;
    if not Result then
      AError := Flag + ' needs a value';
  end;

begin
  Result := False;
  AError := '';
  AOpts.Mode := cmNone;
  AOpts.RequestName := '';
  AOpts.CollectionFile := '';
  AOpts.EnvFile := '';
  AOpts.Json := False;
  AOpts.TimeoutSec := -1;
  AOpts.Follow := True;
  AOpts.Insecure := False;
  AOpts.Verbose := False;
  AOpts.HookCommand := '';
  AOpts.HookTimeoutSec := -1;
  I := 0;
  while I < AArgs.Count do
  begin
    A := AArgs[I];
    if (A = '--help') or (A = '-h') then
      AOpts.Mode := cmHelp
    else if A = '--version' then
      AOpts.Mode := cmVersion
    else if A = '--list' then
    begin
      if AOpts.Mode = cmRun then begin AError := '--list and --run cannot be combined'; Exit; end;
      AOpts.Mode := cmList;
    end
    else if A = '--run' then
    begin
      if AOpts.Mode = cmList then begin AError := '--list and --run cannot be combined'; Exit; end;
      if not NeedValue(A) then Exit;
      Inc(I);
      AOpts.Mode := cmRun;
      AOpts.RequestName := AArgs[I];
    end
    else if A = '--collection' then
    begin
      if not NeedValue(A) then Exit;
      Inc(I);
      AOpts.CollectionFile := AArgs[I];
    end
    else if A = '--env' then
    begin
      if not NeedValue(A) then Exit;
      Inc(I);
      AOpts.EnvFile := AArgs[I];
    end
    else if A = '--var' then
    begin
      if not NeedValue(A) then Exit;
      Inc(I);
      if Pos('=', AArgs[I]) < 2 then
      begin
        AError := '--var expects name=value, got "' + AArgs[I] + '"';
        Exit;
      end;
      AOpts.Vars.Add(AArgs[I]);
    end
    else if A = '--json' then
      AOpts.Json := True
    else if A = '--timeout' then
    begin
      if not NeedValue(A) then Exit;
      Inc(I);
      if not TryStrToInt(AArgs[I], AOpts.TimeoutSec) or (AOpts.TimeoutSec < 0) then
      begin
        AError := '--timeout expects a whole number of seconds';
        Exit;
      end;
    end
    else if A = '--no-follow' then
      AOpts.Follow := False
    else if A = '--insecure' then
      AOpts.Insecure := True
    else if A = '--verbose' then
      AOpts.Verbose := True
    else if A = '--hook' then
    begin
      if not NeedValue(A) then Exit;
      Inc(I);
      AOpts.HookCommand := AArgs[I];
    end
    else if A = '--hook-timeout' then
    begin
      if not NeedValue(A) then Exit;
      Inc(I);
      if not TryStrToInt(AArgs[I], AOpts.HookTimeoutSec) or (AOpts.HookTimeoutSec <= 0) then
      begin
        AError := '--hook-timeout expects a positive number of seconds';
        Exit;
      end;
    end
    else if (A <> '') and (A[1] = '-') then
    begin
      AError := 'unknown option ' + A;
      Exit;
    end
    else if (AOpts.CollectionFile = '') and (AOpts.Mode in [cmNone, cmRun, cmList]) then
      // A bare path is the collection, same as the GUI's "mailBoy file.json".
      AOpts.CollectionFile := A
    else
    begin
      AError := 'unexpected argument ' + A;
      Exit;
    end;
    Inc(I);
  end;
  if (AOpts.Mode in [cmRun, cmList]) and (AOpts.CollectionFile = '') then
  begin
    AError := '--collection <file> is required';
    Exit;
  end;
  if (AOpts.Mode = cmRun) and (AOpts.RequestName = '') then
  begin
    AError := '--run needs a request name';
    Exit;
  end;
  Result := True;
end;

function HumanSize(Bytes: Int64): string;
begin
  if Bytes < 1024 then
    Result := IntToStr(Bytes) + ' B'
  else if Bytes < 1024 * 1024 then
    Result := Format('%.1f KB', [Bytes / 1024])
  else
    Result := Format('%.1f MB', [Bytes / (1024 * 1024)]);
end;

procedure WriteTextResult(R: TExecuteResult; AOut: TStrings);
var
  I: Integer;
begin
  AOut.Add(Trim(R.Response.StatusLine));
  AOut.Add(Format('# %d ms, %s, %s', [R.Response.ElapsedMs, HumanSize(R.Response.ContentLength),
    ExtractFileName(R.Executable)]));
  AOut.Add('');
  for I := 0 to R.Response.Headers.Count - 1 do
    AOut.Add(R.Response.Headers.Names[I] + ': ' + R.Response.Headers.ValueFromIndex[I]);
  AOut.Add('');
  AOut.Add(R.Response.Body);
end;

function HookErrorJson(const APhase: string; H: THookResult): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('phase', APhase);
  Result.Add('command', H.Command);
  Result.Add('exitCode', H.ExitCode);
  Result.Add('elapsedMs', H.ElapsedMs);
  Result.Add('timedOut', H.TimedOut);
  Result.Add('message', H.ErrorMessage);
  Result.Add('detail', H.ErrorDetail);
  Result.Add('stderr', H.StdErr);
  Result.Add('stdoutExcerpt', H.StdOutExcerpt);
end;

// console, tests, hookMs and hookError, only when a hook was configured.
procedure AddHookJson(R: TExecuteResult; O: TJSONObject);
var
  C, T: TJSONArray;
  I: Integer;
  TO_: TJSONObject;
  Failed: THookResult;
  Phase: string;
begin
  if (R.HookBefore = nil) and (R.HookAfter = nil) then Exit;
  C := TJSONArray.Create;
  if R.HookBefore <> nil then
    for I := 0 to R.HookBefore.Console.Count - 1 do C.Add(R.HookBefore.Console[I]);
  if R.HookAfter <> nil then
    for I := 0 to R.HookAfter.Console.Count - 1 do C.Add(R.HookAfter.Console[I]);
  O.Add('console', C);
  T := TJSONArray.Create;
  if R.HookAfter <> nil then
    for I := 0 to R.HookAfter.TestCount - 1 do
    begin
      TO_ := TJSONObject.Create;
      TO_.Add('name', R.HookAfter.Tests[I].Name);
      TO_.Add('passed', R.HookAfter.Tests[I].Passed);
      if R.HookAfter.Tests[I].Error = '' then
        TO_.Add('error', TJSONNull.Create)
      else
        TO_.Add('error', R.HookAfter.Tests[I].Error);
      T.Add(TO_);
    end;
  O.Add('tests', T);
  O.Add('hookMs', R.HookMs);
  Failed := nil;
  Phase := '';
  if (R.HookBefore <> nil) and not R.HookBefore.Ok then
  begin
    Failed := R.HookBefore; Phase := 'before';
  end
  else if (R.HookAfter <> nil) and not R.HookAfter.Ok then
  begin
    Failed := R.HookAfter; Phase := 'after';
  end;
  if Failed = nil then
    O.Add('hookError', TJSONNull.Create)
  else
    O.Add('hookError', HookErrorJson(Phase, Failed));
end;

// Text-mode report of a failed hook, pointing the finger: section 5 of the brief.
procedure WriteHookErrorText(const APhase: string; AReq: TRequest; R: TExecuteResult;
  H: THookResult; AErr: TStrings);
var
  Lines: TStringList;
  I: Integer;
begin
  AErr.Add(Format('hook error, %s "%s"', [APhase, AReq.Path]));
  AErr.Add(Format('command: %s   exit %d   %d ms', [H.Command, H.ExitCode, H.ElapsedMs]));
  if H.TimedOut then
    AErr.Add('killed: timed out');
  if H.ErrorMessage <> '' then
    AErr.Add('error: ' + H.ErrorMessage);
  if H.ErrorDetail <> '' then
    AErr.Add('detail: ' + H.ErrorDetail);
  Lines := TStringList.Create;
  try
    if H.Console.Count > 0 then
    begin
      AErr.Add('console:');
      for I := 0 to H.Console.Count - 1 do AErr.Add('  ' + H.Console[I]);
    end;
    if H.StdErr <> '' then
    begin
      AErr.Add('stderr:');
      Lines.Text := H.StdErr;
      for I := 0 to Lines.Count - 1 do AErr.Add('  ' + Lines[I]);
    end;
    if H.StdOutExcerpt <> '' then
    begin
      AErr.Add('stdout was:');
      Lines.Text := H.StdOutExcerpt;
      for I := 0 to Lines.Count - 1 do AErr.Add('  ' + Lines[I]);
    end;
  finally
    Lines.Free;
  end;
  if R.Resolved <> nil then
    AErr.Add(Format('request as it stood: %s %s, %d header(s)',
      [R.Resolved.Method, R.Resolved.Url, R.Resolved.Headers.Count]));
end;

// Console lines and test results of a successful hook phase, prefixed "hook: ".
procedure WriteHookText(H: THookResult; AErr: TStrings);
var
  I: Integer;
begin
  if H = nil then Exit;
  for I := 0 to H.Console.Count - 1 do
    AErr.Add('hook: ' + H.Console[I]);
  for I := 0 to H.TestCount - 1 do
    if H.Tests[I].Passed then
      AErr.Add('hook: PASS ' + H.Tests[I].Name)
    else if H.Tests[I].Error <> '' then
      AErr.Add('hook: FAIL ' + H.Tests[I].Name + ': ' + H.Tests[I].Error)
    else
      AErr.Add('hook: FAIL ' + H.Tests[I].Name);
end;

procedure WriteJsonResult(const AName: string; R: TExecuteResult; AOut: TStrings);
var
  O, H: TJSONObject;
  W, Inter: TJSONArray;
  I: Integer;
begin
  O := TJSONObject.Create;
  try
    O.Add('request', AName);
    O.Add('outcome', OutcomeToString(R.Outcome));
    if R.Resolved <> nil then
    begin
      O.Add('method', R.Resolved.Method);
      O.Add('url', R.Resolved.Url);
    end;
    if R.Executable <> '' then
      O.Add('transport', R.Executable);
    if R.Response <> nil then
    begin
      O.Add('status', R.Response.StatusCode);
      O.Add('statusText', R.Response.StatusText);
      O.Add('httpVersion', R.Response.HttpVersion);
      O.Add('elapsedMs', R.Response.ElapsedMs);
      O.Add('size', R.Response.ContentLength);
      Inter := TJSONArray.Create;
      for I := 0 to High(R.Response.IntermediateStatusCodes) do
        Inter.Add(R.Response.IntermediateStatusCodes[I]);
      O.Add('intermediateStatuses', Inter);
      H := TJSONObject.Create;
      for I := 0 to R.Response.Headers.Count - 1 do
        // Repeated headers are joined with ", " as HTTP itself allows.
        if H.IndexOfName(R.Response.Headers.Names[I]) >= 0 then
          H.Strings[R.Response.Headers.Names[I]] :=
            H.Strings[R.Response.Headers.Names[I]] + ', ' + R.Response.Headers.ValueFromIndex[I]
        else
          H.Add(R.Response.Headers.Names[I], R.Response.Headers.ValueFromIndex[I]);
      O.Add('headers', H);
      O.Add('body', R.Response.Body);
    end
    else
      O.Add('error', R.ErrorMessage);
    W := TJSONArray.Create;
    for I := 0 to R.Warnings.Count - 1 do
      W.Add(R.Warnings[I]);
    O.Add('warnings', W);
    AddHookJson(R, O);
    AOut.Add(O.FormatJSON);
  finally
    O.Free;
  end;
end;

// True if a loader warning names the request itself, one of its folders,
// or the collection as a whole.
function WarningConcerns(const AWarning: string; AReq: TRequest): Boolean;
var
  F: TFolder;
begin
  Result := (Pos('Request "' + AReq.Name + '"', AWarning) = 1) or (Pos('Collection', AWarning) = 1);
  F := AReq.Parent;
  while (not Result) and (F <> nil) and (F.Parent <> nil) do
  begin
    Result := Pos('Folder "' + F.Name + '"', AWarning) = 1;
    F := F.Parent;
  end;
end;

// " [pre] [test]" for a request that has, or inherits, scripts.
function ScriptMarkers(AReq: TRequest): string;
var
  Item: TCollectionItem;
  Pre, Tst: Boolean;
begin
  Pre := False;
  Tst := False;
  Item := AReq;
  while Item <> nil do
  begin
    if Item.PreRequestScript <> '' then Pre := True;
    if Item.TestScript <> '' then Tst := True;
    Item := Item.Parent;
  end;
  Result := '';
  if Pre then Result := Result + ' [pre]';
  if Tst then Result := Result + ' [test]';
end;

function RunCliWith(const AOpts: TCliOptions; AOut, AErr: TStrings): Integer;
var
  Coll: TCollection;
  Env: TEnvironment;
  Warnings: TStringList;
  Scope: TVariableScope;
  Matches: TFPList;
  All: TFPList;
  Exec: TRequestExecutor;
  R: TExecuteResult;
  I, P: Integer;
  Req: TRequest;
begin
  case AOpts.Mode of
    cmHelp:
      begin
        AOut.Add(CliUsage);
        Exit(ExitOk);
      end;
    cmVersion:
      begin
        AOut.Add('mailBoy ' + MailBoyVersion);
        Exit(ExitOk);
      end;
    cmNone:
      begin
        AErr.Add('nothing to do; see --help');
        Exit(ExitFile);
      end;
  end;

  Coll := nil;
  Env := nil;
  Scope := nil;
  Matches := nil;
  Warnings := TStringList.Create;
  try
    try
      Coll := LoadCollectionFromFile(AOpts.CollectionFile, Warnings);
    except
      on E: EMailBoyLoad do
      begin
        AErr.Add('collection: ' + E.Message);
        Exit(ExitFile);
      end;
    end;

    if AOpts.Mode = cmList then
    begin
      All := TFPList.Create;
      try
        Coll.CollectRequests(All);
        for I := 0 to All.Count - 1 do
          if AOpts.Verbose then
            AOut.Add(TRequest(All[I]).Path + ScriptMarkers(TRequest(All[I])))
          else
            AOut.Add(TRequest(All[I]).Path);
      finally
        All.Free;
      end;
      Exit(ExitOk);
    end;

    // cmRun
    if AOpts.EnvFile <> '' then
    try
      Env := LoadEnvironmentFromFile(AOpts.EnvFile);
    except
      on E: EMailBoyLoad do
      begin
        AErr.Add('environment: ' + E.Message);
        Exit(ExitFile);
      end;
    end;

    Matches := TFPList.Create;
    Coll.FindRequests(AOpts.RequestName, Matches);
    if Matches.Count = 0 then
    begin
      AErr.Add('request not found: ' + AOpts.RequestName);
      AErr.Add('use --list to see the available names');
      Exit(ExitNotFound);
    end;
    if Matches.Count > 1 then
    begin
      AErr.Add(Format('request name "%s" is ambiguous, use one of:', [AOpts.RequestName]));
      for I := 0 to Matches.Count - 1 do
        AErr.Add('  ' + TRequest(Matches[I]).Path);
      Exit(ExitNotFound);
    end;
    Req := TRequest(Matches[0]);

    Scope := TVariableScope.Create;
    Scope.PushLayer('collection', Coll.Variables);
    if Env <> nil then
      Scope.PushLayer('environment', Env.Variables);
    // The session layer always exists: --var goes there, and so does
    // anything a hook sets during this run.
    Scope.PushLayer('session', nil);
    for I := 0 to AOpts.Vars.Count - 1 do
    begin
      P := Pos('=', AOpts.Vars[I]);
      Scope.SetVariable(Copy(AOpts.Vars[I], 1, P - 1), Copy(AOpts.Vars[I], P + 1, MaxInt));
    end;

    Exec := TRequestExecutor.Create;
    try
      if AOpts.TimeoutSec >= 0 then
        Exec.Options.Build.TimeoutSec := AOpts.TimeoutSec;
      Exec.Options.Build.FollowRedirects := AOpts.Follow;
      Exec.Options.Build.Insecure := AOpts.Insecure;
      Exec.Hook.Command := AOpts.HookCommand;
      if AOpts.HookTimeoutSec > 0 then
        Exec.Hook.TimeoutSec := AOpts.HookTimeoutSec;
      Exec.Context.CollectionFile := ExpandFileName(AOpts.CollectionFile);
      if AOpts.EnvFile <> '' then
        Exec.Context.EnvironmentFile := ExpandFileName(AOpts.EnvFile);
      R := Exec.Execute(Req, Scope);
      try
        // Only import warnings about this request or its ancestors; the
        // rest of the collection is not being run.
        P := 0;
        for I := 0 to Warnings.Count - 1 do
          if WarningConcerns(Warnings[I], Req) then
          begin
            R.Warnings.Insert(P, 'import: ' + Warnings[I]);
            Inc(P);
          end;
        if AOpts.Verbose and (R.Args <> nil) then
          AErr.Add(ExtractFileName(R.Executable) + ' ' + ArgsToDisplayString(R.Args));
        if not AOpts.Json then
        begin
          for I := 0 to R.Warnings.Count - 1 do
            AErr.Add('warning: ' + R.Warnings[I]);
          if (R.HookBefore <> nil) and R.HookBefore.Ok then
            WriteHookText(R.HookBefore, AErr);
          if (R.HookAfter <> nil) and R.HookAfter.Ok then
            WriteHookText(R.HookAfter, AErr);
        end;

        case R.Outcome of
          eoOk:
            begin
              if AOpts.Json then WriteJsonResult(Req.Path, R, AOut) else WriteTextResult(R, AOut);
              Result := ExitOk;
              // The after hook failed: the response is delivered, the exit code says so.
              if (R.HookAfter <> nil) and not R.HookAfter.Ok then
              begin
                if not AOpts.Json then
                  WriteHookErrorText('after', Req, R, R.HookAfter, AErr);
                Result := ExitHook;
              end;
            end;
          eoHookError:
            begin
              if AOpts.Json then
                WriteJsonResult(Req.Path, R, AOut)
              else
                WriteHookErrorText('before', Req, R, R.HookBefore, AErr);
              Result := ExitHook;
            end;
          eoNoTransport:
            begin
              if AOpts.Json then WriteJsonResult(Req.Path, R, AOut) else AErr.Add(R.ErrorMessage);
              Result := ExitNoTransport;
            end;
          eoUnresolvedUrl:
            begin
              if AOpts.Json then
                WriteJsonResult(Req.Path, R, AOut)
              else
              begin
                AErr.Add(R.ErrorMessage);
                AErr.Add('Pass --env <file> with a definition, or --var name=value.');
              end;
              Result := ExitFile;
            end;
        else
          if AOpts.Json then WriteJsonResult(Req.Path, R, AOut) else AErr.Add(R.ErrorMessage);
          Result := ExitTransport;
        end;
      finally
        R.Free;
      end;
    finally
      Exec.Free;
    end;
  finally
    Matches.Free;
    Scope.Free;
    Env.Free;
    Coll.Free;
    Warnings.Free;
  end;
end;

function RunCliMain: Integer;
var
  Args, OutL, ErrL: TStringList;
  Opts: TCliOptions;
  Err: string;
  I: Integer;
begin
  Args := TStringList.Create;
  OutL := TStringList.Create;
  ErrL := TStringList.Create;
  Opts.Vars := TStringList.Create;
  try
    for I := 1 to ParamCount do
      Args.Add(ParamStr(I));
    if not ParseCliArgs(Args, Opts, Err) then
    begin
      WriteLn(StdErr, 'mailBoy: ', Err);
      WriteLn(StdErr, 'see --help');
      Exit(ExitFile);
    end;
    Result := RunCliWith(Opts, OutL, ErrL);
    for I := 0 to ErrL.Count - 1 do
      WriteLn(StdErr, ErrL[I]);
    // The body is the last entry and must come out byte-exact without an
    // added line ending, so an agent can hash or diff it.
    for I := 0 to OutL.Count - 2 do
      WriteLn(OutL[I]);
    if OutL.Count > 0 then
      Write(OutL[OutL.Count - 1]);
    if (OutL.Count > 0) and (Opts.Mode <> cmRun) then
      WriteLn;
    Flush(Output);
  finally
    Opts.Vars.Free;
    ErrL.Free;
    OutL.Free;
    Args.Free;
  end;
end;

end.
