unit test_mbRunner;

{ Runner tests against fake curl/wget shell scripts in tests/fixtures/fakebin.
  No real network, no real curl. Tests run with the repo root as cwd. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry, mbRunner;

type
  TRunnerTest = class(TTestCase)
  private
    FArgs: TStringList;
    function FakeBin(const AName: string): string;
    function RunFake(ATimeoutMs: Integer = 10000): TProcessResult;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestFindExecutableFindsSh;
    procedure TestFindExecutableMissing;
    procedure TestFindExecutableOverride;
    procedure TestFindExecutableOverrideMissingFile;
    procedure TestDetectTransportCurl;
    procedure TestDetectTransportWget;
    procedure TestDetectTransportNone;
    procedure TestArgumentsVerbatim;
    procedure TestEmptyArgumentRefused;
    procedure TestExitCodePropagated;
    procedure TestStderrSeparate;
    procedure TestBigOutputNoDeadlock;
    procedure TestBinaryOutput;
    procedure TestTimeout;
    procedure TestMissingExecutable;
    procedure TestStdinLarge;
    procedure TestElapsedNonNegative;
    procedure TestWindowsQuoting;
  end;

implementation

const
  FakeBinDir = 'tests' + PathDelim + 'fixtures' + PathDelim + 'fakebin' + PathDelim;

procedure TRunnerTest.SetUp;
begin
  FArgs := TStringList.Create;
  CurlPathOverride := '';
  WgetPathOverride := '';
end;

procedure TRunnerTest.TearDown;
begin
  FArgs.Free;
  CurlPathOverride := '';
  WgetPathOverride := '';
end;

function TRunnerTest.FakeBin(const AName: string): string;
begin
  Result := IncludeTrailingPathDelimiter(GetCurrentDir) + FakeBinDir + AName;
end;

function TRunnerTest.RunFake(ATimeoutMs: Integer): TProcessResult;
begin
  Result := RunProcess(FakeBin('fakecurl'), FArgs, ATimeoutMs);
end;

procedure TRunnerTest.TestFindExecutableFindsSh;
var
  P: string;
begin
  {$IFDEF UNIX}
  P := FindExecutable('sh');
  AssertTrue('sh found on PATH: ' + P, P <> '');
  AssertTrue('absolute path', P[1] = PathDelim);
  AssertTrue('file exists', FileExists(P));
  {$ENDIF}
end;

procedure TRunnerTest.TestFindExecutableMissing;
begin
  AssertEquals('', FindExecutable('definitely-not-a-program-xyz'));
end;

procedure TRunnerTest.TestFindExecutableOverride;
begin
  CurlPathOverride := FakeBin('fakecurl');
  AssertEquals(FakeBin('fakecurl'), FindExecutable('curl'));
  WgetPathOverride := FakeBin('fakewget');
  AssertEquals(FakeBin('fakewget'), FindExecutable('wget'));
end;

procedure TRunnerTest.TestFindExecutableOverrideMissingFile;
begin
  // An explicit override that points nowhere yields '', not a PATH fallback.
  CurlPathOverride := FakeBin('does-not-exist');
  AssertEquals('', FindExecutable('curl'));
end;

procedure TRunnerTest.TestDetectTransportCurl;
var
  P: string;
begin
  CurlPathOverride := FakeBin('fakecurl');
  WgetPathOverride := FakeBin('fakewget');
  AssertTrue(DetectTransport(P) = trCurl);
  AssertEquals(FakeBin('fakecurl'), P);
end;

procedure TRunnerTest.TestDetectTransportWget;
var
  P: string;
  T: TTransport;
begin
  CurlPathOverride := FakeBin('does-not-exist');
  WgetPathOverride := FakeBin('fakewget');
  T := DetectTransport(P);
  AssertTrue('trWget', T = trWget);
  AssertEquals(FakeBin('fakewget'), P);
end;

procedure TRunnerTest.TestDetectTransportNone;
var
  P: string;
begin
  CurlPathOverride := FakeBin('does-not-exist');
  WgetPathOverride := FakeBin('does-not-exist-either');
  AssertTrue('trNone', DetectTransport(P) = trNone);
  AssertEquals('', P);
end;

procedure TRunnerTest.TestArgumentsVerbatim;
var
  R: TProcessResult;
  Expected: string;
begin
  FArgs.Add('plain');
  FArgs.Add('with space');
  FArgs.Add('"quoted"');
  FArgs.Add('it''s');
  FArgs.Add('{{braces}}');
  FArgs.Add('a&b');
  FArgs.Add('*');
  FArgs.Add('ünïcödé ✓');
  FArgs.Add('$HOME');
  R := RunFake;
  try
    AssertTrue('started', R.Started);
    AssertEquals(0, R.ExitCode);
    Expected :=
      'ARG:plain'#10 +
      'ARG:with space'#10 +
      'ARG:"quoted"'#10 +
      'ARG:it''s'#10 +
      'ARG:{{braces}}'#10 +
      'ARG:a&b'#10 +
      'ARG:*'#10 +
      'ARG:ünïcödé ✓'#10 +
      'ARG:$HOME'#10 +
      'STDIN:';
    AssertEquals(Expected, R.Output);
    AssertEquals(FakeBin('fakecurl'), R.Executable);
  finally
    R.Free;
  end;
end;

procedure TRunnerTest.TestEmptyArgumentRefused;
var
  R: TProcessResult;
begin
  // FPC 3.2.2 TProcess (Unix) truncates argv at an empty parameter. The
  // runner must refuse instead of silently running a shorter command.
  {$IFDEF UNIX}
  FArgs.Add('a');
  FArgs.Add('');
  FArgs.Add('b');
  R := RunFake;
  try
    AssertFalse('started', R.Started);
    AssertEquals(-1, R.ExitCode);
    AssertTrue(Pos('argument 2', R.ErrorOutput) > 0);
    AssertEquals('', R.Output);
  finally
    R.Free;
  end;
  {$ENDIF}
end;

procedure TRunnerTest.TestExitCodePropagated;
var
  R: TProcessResult;
begin
  FArgs.Add('--exit');
  FArgs.Add('42');
  R := RunFake;
  try
    AssertTrue(R.Started);
    AssertEquals(42, R.ExitCode);
    AssertFalse(R.TimedOut);
  finally
    R.Free;
  end;
end;

procedure TRunnerTest.TestStderrSeparate;
var
  R: TProcessResult;
begin
  FArgs.Add('--stderr');
  R := RunFake;
  try
    AssertEquals('to stderr'#10, R.ErrorOutput);
    AssertEquals('ARG:--stderr'#10'STDIN:', R.Output);
  finally
    R.Free;
  end;
end;

procedure TRunnerTest.TestBigOutputNoDeadlock;
var
  R: TProcessResult;
  Prefix, Suffix: string;
begin
  FArgs.Add('--big');
  R := RunFake(60000);
  try
    AssertTrue('started', R.Started);
    AssertFalse('timed out', R.TimedOut);
    AssertEquals(0, R.ExitCode);
    Prefix := 'ARG:--big'#10;
    Suffix := 'STDIN:';
    AssertEquals('stdout length', 2 * 1024 * 1024 + Length(Prefix) + Length(Suffix),
      Length(R.Output));
    AssertEquals('stderr length', 200 * 1024, Length(R.ErrorOutput));
    AssertEquals(Prefix, Copy(R.Output, 1, Length(Prefix)));
    AssertEquals(Suffix, Copy(R.Output, Length(R.Output) - Length(Suffix) + 1, Length(Suffix)));
    AssertEquals('x', R.Output[Length(Prefix) + 1]);
    AssertEquals('x', R.Output[Length(R.Output) - Length(Suffix)]);
    AssertEquals('y', R.ErrorOutput[1]);
    AssertEquals('y', R.ErrorOutput[Length(R.ErrorOutput)]);
    AssertTrue('finished in under 10 s', R.ElapsedMs < 10000);
  finally
    R.Free;
  end;
end;

procedure TRunnerTest.TestBinaryOutput;
var
  R: TProcessResult;
begin
  FArgs.Add('--binary');
  R := RunFake;
  try
    AssertEquals('ARG:--binary'#10#0#1#255#10#13'STDIN:', R.Output);
    AssertTrue(Pos(#0#1#255#10#13, R.Output) > 0);
  finally
    R.Free;
  end;
end;

procedure TRunnerTest.TestTimeout;
var
  R: TProcessResult;
begin
  FArgs.Add('--sleep');
  R := RunFake(500);
  try
    AssertTrue('started', R.Started);
    AssertTrue('timed out', R.TimedOut);
    AssertTrue('elapsed >= 500: ' + IntToStr(R.ElapsedMs), R.ElapsedMs >= 500);
    AssertTrue('elapsed < 2000: ' + IntToStr(R.ElapsedMs), R.ElapsedMs < 2000);
    AssertEquals('ARG:--sleep'#10, R.Output);
  finally
    R.Free;
  end;
end;

procedure TRunnerTest.TestMissingExecutable;
var
  R: TProcessResult;
begin
  FArgs.Add('x');
  R := RunProcess(FakeBin('no-such-program'), FArgs);
  try
    AssertFalse('started', R.Started);
    AssertEquals(-1, R.ExitCode);
    AssertTrue('error text', R.ErrorOutput <> '');
    AssertEquals('', R.Output);
    AssertFalse(R.TimedOut);
  finally
    R.Free;
  end;
end;

procedure TRunnerTest.TestStdinLarge;
var
  R: TProcessResult;
  Data: string;
  I: Integer;
  P: Integer;
begin
  Data := '';
  SetLength(Data, 1024 * 1024);
  for I := 1 to Length(Data) do
    Data[I] := Chr(Ord('A') + (I mod 26));
  Data[1] := #0;
  Data[Length(Data)] := #255;
  FArgs.Add('in');
  R := RunProcessWithStdin(FakeBin('fakecurl'), FArgs, Data, 60000);
  try
    AssertTrue('started', R.Started);
    AssertFalse('timed out', R.TimedOut);
    AssertEquals(0, R.ExitCode);
    P := Pos('STDIN:', R.Output);
    AssertEquals('ARG:in'#10'STDIN:', Copy(R.Output, 1, P + 5));
    AssertEquals('stdin length', Length(Data), Length(R.Output) - (P + 5));
    AssertTrue('stdin byte-exact', Copy(R.Output, P + 6, Length(Data)) = Data);
  finally
    R.Free;
  end;
end;

procedure TRunnerTest.TestElapsedNonNegative;
var
  R: TProcessResult;
begin
  R := RunFake;
  try
    AssertTrue(R.ElapsedMs >= 0);
  finally
    R.Free;
  end;
  R := RunProcess(FakeBin('no-such-program'), nil);
  try
    AssertTrue(R.ElapsedMs >= 0);
  finally
    R.Free;
  end;
end;

procedure TRunnerTest.TestWindowsQuoting;
var
  Args: TStringList;
begin
  AssertEquals('plain', WindowsQuoteArgument('plain'));
  AssertEquals('-H', WindowsQuoteArgument('-H'));
  AssertEquals('https://h/x?a=1&b=2', WindowsQuoteArgument('https://h/x?a=1&b=2'));
  AssertEquals('"with space"', WindowsQuoteArgument('with space'));
  AssertEquals('""', WindowsQuoteArgument(''));
  AssertEquals('"Content-Type: application/json"', WindowsQuoteArgument('Content-Type: application/json'));
  // The case that broke the first Windows send: a JSON body.
  AssertEquals('"{\"tracking\": {\"amount\": 1}}"', WindowsQuoteArgument('{"tracking": {"amount": 1}}'));
  AssertEquals('"line1' + #10 + 'line2"', WindowsQuoteArgument('line1' + #10 + 'line2'));
  // Backslashes only matter next to a quote.
  AssertEquals('C:\dir\file.txt', WindowsQuoteArgument('C:\dir\file.txt'));
  AssertEquals('"C:\my dir\\"', WindowsQuoteArgument('C:\my dir\'));
  AssertEquals('"a\\\"b"', WindowsQuoteArgument('a\"b'));
  AssertEquals('"a\\\\\"b"', WindowsQuoteArgument('a\\"b'));
  Args := TStringList.Create;
  try
    Args.Add('-X');
    Args.Add('POST');
    Args.Add('--data-binary');
    Args.Add('{"a": "b"}');
    AssertEquals('"C:\Program Files\curl\curl.exe" -X POST --data-binary "{\"a\": \"b\"}"',
      WindowsCommandLine('C:\Program Files\curl\curl.exe', Args));
  finally
    Args.Free;
  end;
end;

initialization
  RegisterTest(TRunnerTest);

end.
