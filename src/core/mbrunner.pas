unit mbRunner;

{ mbRunner: finds external executables (curl, wget) on PATH and runs them
  with TProcess, capturing stdout and stderr completely and measuring wall
  time. Knows nothing about HTTP or the data model.

  Boring Pascal: TProcess with poUsePipes, both pipes drained in a loop
  while the process runs, so large output on either pipe cannot deadlock. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Process, Pipes;

type
  TTransport = (trCurl, trWget, trNone);

  TProcessResult = class
  public
    ExitCode: Integer;      // process exit status; -1 if it never started
    Output: string;         // stdout, byte-exact
    ErrorOutput: string;    // stderr, byte-exact; launch error text if not Started
    ElapsedMs: Integer;     // wall time from start attempt to exit
    Executable: string;     // full path actually run
    Started: Boolean;       // False if the executable could not be launched
    TimedOut: Boolean;      // True if ATimeoutMs elapsed and the process was killed
  end;

var
  { Empty = search PATH. If set, FindExecutable('curl') / ('wget') returns the
    override when that file exists and '' when it does not: an explicit but
    wrong override fails loudly instead of silently using another binary.
    Tests point these at fake scripts. }
  CurlPathOverride: string = '';
  WgetPathOverride: string = '';

{ Full path of AName on PATH (Windows: also tries AName + '.exe'), or ''. }
function FindExecutable(const AName: string): string;

{ curl first, wget second; APath receives the full path or ''. }
function DetectTransport(out APath: string): TTransport;

{ Run AExe with AArgs as separate parameters. Caller frees the result.
  ATimeoutMs > 0: kill the process after that many milliseconds and set
  TimedOut. Never raises: launch failures are reported via Started = False. }
function RunProcess(const AExe: string; AArgs: TStrings;
  ATimeoutMs: Integer = 0): TProcessResult;

{ Same as RunProcess, but writes AStdin to the process's stdin and closes it
  before draining output. }
function RunProcessWithStdin(const AExe: string; AArgs: TStrings;
  const AStdin: string; ATimeoutMs: Integer = 0): TProcessResult;

{ One argument quoted the way CreateProcess children (the C runtime,
  CommandLineToArgvW) take it apart again: wrapped in double quotes when it
  has a space, tab, quote or is empty; an inner quote becomes \"; backslashes
  right before a quote, or at the end of a quoted argument, are doubled.
  FPC 3.2.2's TProcess on Windows does none of this: it leaves an argument
  that contains a quote unquoted, so a JSON body reaches curl as several
  arguments and curl reports each piece as a malformed URL. Pure function,
  tested on every platform, used on Windows. }
function WindowsQuoteArgument(const A: string): string;

{ The whole command line: the executable and every argument, each quoted
  with WindowsQuoteArgument, joined by single spaces. }
function WindowsCommandLine(const AExe: string; AArgs: TStrings): string;

implementation

const
  ChunkSize = 64 * 1024;
  IdleSleepMs = 2;
  StdinChunkSize = 16 * 1024;

function SearchPath(const AName: string): string;
var
  PathVar: string;
begin
  PathVar := GetEnvironmentVariable('PATH');
  Result := ExeSearch(AName, PathVar);
  {$IFDEF WINDOWS}
  if (Result = '') and (ExtractFileExt(AName) = '') then
    Result := ExeSearch(AName + '.exe', PathVar);
  {$ENDIF}
  if (Result <> '') and not FileExists(Result) then
    Result := '';
end;

function FindExecutable(const AName: string): string;
var
  Override: string;
begin
  Override := '';
  if SameText(AName, 'curl') then
    Override := CurlPathOverride
  else if SameText(AName, 'wget') then
    Override := WgetPathOverride;
  if Override <> '' then
  begin
    if FileExists(Override) then
      Result := ExpandFileName(Override)
    else
      Result := '';
    Exit;
  end;
  Result := SearchPath(AName);
end;

function DetectTransport(out APath: string): TTransport;
begin
  APath := FindExecutable('curl');
  if APath <> '' then
    Exit(trCurl);
  APath := FindExecutable('wget');
  if APath <> '' then
    Exit(trWget);
  Result := trNone;
end;

{ Append everything currently readable on AStream to ABuf.
  Returns True if any bytes were read. }
function Drain(AStream: TInputPipeStream; ABuf: TMemoryStream): Boolean;
var
  Avail, Got: LongInt;
  Chunk: array[0..ChunkSize - 1] of Byte;
begin
  Result := False;
  if AStream = nil then
    Exit;
  Chunk[0] := 0;
  Avail := AStream.NumBytesAvailable;
  while Avail > 0 do
  begin
    if Avail > ChunkSize then
      Avail := ChunkSize;
    Got := AStream.Read(Chunk[0], Avail);
    if Got <= 0 then
      Break;
    ABuf.WriteBuffer(Chunk[0], Got);
    Result := True;
    Avail := AStream.NumBytesAvailable;
  end;
end;

function StreamToString(AStream: TMemoryStream): string;
begin
  Result := '';
  SetLength(Result, AStream.Size);
  if AStream.Size > 0 then
    Move(AStream.Memory^, Result[1], AStream.Size);
end;

function WindowsQuoteArgument(const A: string): string;
var
  I, Backslashes, J: Integer;
  NeedsQuotes: Boolean;
begin
  NeedsQuotes := A = '';
  for I := 1 to Length(A) do
    if A[I] in [' ', #9, #10, #13, '"'] then
    begin
      NeedsQuotes := True;
      Break;
    end;
  if not NeedsQuotes then
    Exit(A);
  Result := '"';
  Backslashes := 0;
  for I := 1 to Length(A) do
  begin
    if A[I] = '\' then
    begin
      Inc(Backslashes);
      Continue;
    end;
    if A[I] = '"' then
    begin
      // Backslashes before a quote are doubled, then the quote is escaped.
      for J := 1 to Backslashes * 2 + 1 do
        Result := Result + '\';
      Result := Result + '"';
    end
    else
    begin
      for J := 1 to Backslashes do
        Result := Result + '\';
      Result := Result + A[I];
    end;
    Backslashes := 0;
  end;
  // Backslashes before the closing quote are doubled so the quote survives.
  for J := 1 to Backslashes * 2 do
    Result := Result + '\';
  Result := Result + '"';
end;

function WindowsCommandLine(const AExe: string; AArgs: TStrings): string;
var
  I: Integer;
begin
  Result := WindowsQuoteArgument(AExe);
  if AArgs <> nil then
    for I := 0 to AArgs.Count - 1 do
      Result := Result + ' ' + WindowsQuoteArgument(AArgs[I]);
end;

function RunInternal(const AExe: string; AArgs: TStrings;
  const AStdin: string; AHasStdin: Boolean; ATimeoutMs: Integer): TProcessResult;
var
  P: TProcess;
  OutBuf, ErrBuf: TMemoryStream;
  T0: QWord;
  StdinPos, StdinLen, ToWrite, Written: Integer;
  Busy: Boolean;
  {$IFDEF UNIX}
  I: Integer;
  {$ENDIF}
begin
  Result := TProcessResult.Create;
  Result.ExitCode := -1;
  Result.Executable := AExe;
  Result.Started := False;
  Result.TimedOut := False;
  Result.ElapsedMs := 0;

  T0 := GetTickCount64;
  P := TProcess.Create(nil);
  OutBuf := TMemoryStream.Create;
  ErrBuf := TMemoryStream.Create;
  try
    {$IFDEF WINDOWS}
    { Hand CreateProcess the command line ourselves (see WindowsQuoteArgument).
      ApplicationName names the exact file; the command line is used verbatim. }
    P.ApplicationName := AExe;
    P.CommandLine := WindowsCommandLine(AExe, AArgs);
    {$ELSE}
    P.Executable := AExe;
    if AArgs <> nil then
      P.Parameters.Assign(AArgs);
    {$ENDIF}
    {$IFDEF UNIX}
    { FPC 3.2.2 TProcess on Unix builds argv from PChar(Parameters[i]); an
      empty string becomes a nil entry and silently truncates argv there.
      Refuse loudly instead of running the wrong command. }
    for I := 0 to P.Parameters.Count - 1 do
      if P.Parameters[I] = '' then
      begin
        Result.ErrorOutput := Format('mbRunner: argument %d is empty; ' +
          'TProcess on this platform cannot pass empty arguments', [I + 1]);
        Result.ElapsedMs := Integer(GetTickCount64 - T0);
        Exit;
      end;
    {$ENDIF}
    P.Options := [poUsePipes {$IFDEF WINDOWS}, poNoConsole{$ENDIF}];
    P.ShowWindow := swoHIDE;
    try
      P.Execute;
      Result.Started := True;
    except
      on E: Exception do
      begin
        Result.ErrorOutput := E.Message;
        Result.ElapsedMs := Integer(GetTickCount64 - T0);
        Exit;
      end;
    end;

    { Feed stdin in chunks while draining both output pipes, so a child that
      echoes stdin to stdout cannot block us on a full pipe. Then close stdin
      so the child sees EOF. }
    StdinPos := 0;
    StdinLen := Length(AStdin);
    if AHasStdin then
    begin
      while (StdinPos < StdinLen) and P.Running do
      begin
        ToWrite := StdinLen - StdinPos;
        if ToWrite > StdinChunkSize then
          ToWrite := StdinChunkSize;
        Written := P.Input.Write(AStdin[StdinPos + 1], ToWrite);
        if Written <= 0 then
          Break;
        Inc(StdinPos, Written);
        Drain(P.Output, OutBuf);
        Drain(P.Stderr, ErrBuf);
      end;
    end;
    P.CloseInput;

    while P.Running do
    begin
      Busy := Drain(P.Output, OutBuf);
      if Drain(P.Stderr, ErrBuf) then
        Busy := True;
      if (ATimeoutMs > 0) and (Integer(GetTickCount64 - T0) >= ATimeoutMs) then
      begin
        Result.TimedOut := True;
        P.Terminate(-1);
        Break;
      end;
      if not Busy then
        Sleep(IdleSleepMs);
    end;

    { The child may have exited with bytes still buffered in the pipes. }
    Drain(P.Output, OutBuf);
    Drain(P.Stderr, ErrBuf);

    if Result.TimedOut then
    begin
      P.WaitOnExit;
      Result.ExitCode := -1;
    end
    else
      Result.ExitCode := P.ExitCode;
    Result.ElapsedMs := Integer(GetTickCount64 - T0);
    Result.Output := StreamToString(OutBuf);
    Result.ErrorOutput := StreamToString(ErrBuf);
  finally
    ErrBuf.Free;
    OutBuf.Free;
    P.Free;
  end;
end;

function RunProcess(const AExe: string; AArgs: TStrings;
  ATimeoutMs: Integer): TProcessResult;
begin
  Result := RunInternal(AExe, AArgs, '', False, ATimeoutMs);
end;

function RunProcessWithStdin(const AExe: string; AArgs: TStrings;
  const AStdin: string; ATimeoutMs: Integer): TProcessResult;
begin
  Result := RunInternal(AExe, AArgs, AStdin, True, ATimeoutMs);
end;

end.
