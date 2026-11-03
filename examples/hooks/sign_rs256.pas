program sign_rs256;
// sign_rs256.pas: mailBoy pre-request hook that signs the request with RS256.
// What it does: reads the hook input from stdin, builds the acme-widgets-v2 JWT
// payload (path, body hash, timestamp, expiry), signs it with the PEM key in the
// SIGNING_KEY collection variable, returns headers x-acme-signature and x-acme-client.
// What it needs: Free Pascal 3.2 to build (make examples -> bin/sign_rs256), and
// openssl on PATH at run time: hashing and RSA signing run openssl as a child
// process, the key goes through a temp file with mode 0600 that is deleted after.
// Collection variables SIGNING_KEY, CLIENT_ID and KEY_ID must be set.
// How to run: mailboy --run X --collection C --hook ./bin/sign_rs256
{$mode objfpc}{$H+}
uses
  Classes, SysUtils, fpjson, jsonparser, Process, base64;

// Reads a pipe stream to its end. Bytes, not text: the output may be a binary signature.
function ReadToEnd(AStream: TStream): string;
var
  Buf: array[0..65535] of Byte;
  N: LongInt;
  Chunk: string;
begin
  Result := '';
  repeat
    N := AStream.Read(Buf, SizeOf(Buf));
    if N > 0 then
    begin
      SetString(Chunk, PChar(@Buf[0]), N);
      Result := Result + Chunk;
    end;
  until N <= 0;
end;

function ReadAllStdIn: string;
var
  S: THandleStream;
begin
  S := THandleStream.Create(StdInputHandle);
  try
    Result := ReadToEnd(S);
  finally
    S.Free;
  end;
end;

// Runs openssl with AArgs, feeds it AStdIn, returns its stdout. Stops the program on failure.
function RunOpenSsl(const AArgs: array of string; const AStdIn: string): string;
var
  P: TProcess;
  I: Integer;
begin
  P := TProcess.Create(nil);
  try
    P.Executable := 'openssl';
    for I := Low(AArgs) to High(AArgs) do
      P.Parameters.Add(AArgs[I]);
    P.Options := [poUsePipes, poStderrToOutPut];
    P.Execute;
    if AStdIn <> '' then
      P.Input.Write(AStdIn[1], Length(AStdIn));
    P.CloseInput;
    Result := ReadToEnd(P.Output);
    P.WaitOnExit;
    if P.ExitStatus <> 0 then
    begin
      WriteLn(StdErr, 'openssl ', AArgs[0], ' failed: ', Trim(Result));
      Halt(1);
    end;
  finally
    P.Free;
  end;
end;

function Base64Url(const ABytes: string): string;
begin
  Result := EncodeStringBase64(ABytes);
  Result := StringReplace(Result, '+', '-', [rfReplaceAll]);
  Result := StringReplace(Result, '/', '_', [rfReplaceAll]);
  Result := TrimRight(StringReplace(Result, '=', ' ', [rfReplaceAll]));
end;

function VarOf(AVars: TJSONObject; const AName: string): string;
var
  D: TJSONData;
begin
  Result := '';
  D := nil;
  if AVars <> nil then D := AVars.Find(AName);
  if (D <> nil) and (D.JSONType = jtString) then Result := D.AsString;
  if Result = '' then WriteLn(StdErr, 'empty variable: ', AName);
end;

var
  Root, Header, Payload, Output, Variables, Request: TJSONObject;
  SigningKey, ClientId, KeyId, Url, HostAndPath, Path, Body, BodyHash: string;
  Ts, SigningInput, Signature, KeyFile, Jwt: string;
  UtcNow: TDateTime;
  Exp: Int64;
  D: TJSONData;
  KeyHandle: THandle;
begin
  TJSONData.CompressedJSON := True;
  // 1. Read all of stdin and parse it. Only the before phase does any work.
  Root := TJSONObject(GetJSON(ReadAllStdIn));
  try
    if Root.Get('phase', '') <> 'before' then
    begin
      WriteLn('{}');
      Halt(0);
    end;
    // 2. The collection variables, naming every one that is empty.
    Variables := nil;
    D := Root.FindPath('variables.collection');
    if (D <> nil) and (D.JSONType = jtObject) then Variables := TJSONObject(D);
    SigningKey := VarOf(Variables, 'SIGNING_KEY');
    ClientId := VarOf(Variables, 'CLIENT_ID');
    KeyId := VarOf(Variables, 'KEY_ID');
    if (SigningKey = '') or (ClientId = '') or (KeyId = '') then Halt(1);
    // 3. Path after the host, body hash, timestamps.
    Request := Root.Objects['request'];
    Url := Request.Get('url', '');
    HostAndPath := Url;
    if Pos('://', Url) > 0 then HostAndPath := Copy(Url, Pos('://', Url) + 3, MaxInt);
    Path := '';
    if Pos('/', HostAndPath) > 0 then Path := Copy(HostAndPath, Pos('/', HostAndPath), MaxInt);
    Body := '';
    D := Root.FindPath('request.body.raw');
    if (D <> nil) and (D.JSONType = jtString) then Body := D.AsString;
    BodyHash := Copy(RunOpenSsl(['dgst', '-sha256', '-r'], Body), 1, 64);
    UtcNow := Now + GetLocalTimeOffset / MinsPerDay;
    Ts := FormatDateTime('yyyy"-"mm"-"dd"T"hh":"nn":"ss"."zzz"Z"', UtcNow);
    Exp := Trunc((UtcNow - UnixDateDelta) * SecsPerDay) + 180;
    // 4. Header and payload, base64url, sign with RS256, base64url the signature.
    Header := TJSONObject.Create(['alg', 'RS256', 'typ', 'JWT']);
    Payload := TJSONObject.Create(['ver', 'acme-widgets-v2', 'clientId', ClientId, 'keyId', KeyId,
      'path', Path, 'bodyAlg', 'sha256', 'ts', Ts, 'bodyHash', BodyHash, 'exp', Exp]);
    try
      SigningInput := Base64Url(Header.AsJSON) + '.' + Base64Url(Payload.AsJSON);
    finally
      Payload.Free;
      Header.Free;
    end;
    KeyFile := GetTempFileName('', 'mbkey');
    KeyHandle := FileCreate(KeyFile, fmOpenWrite, &600);
    if KeyHandle = THandle(-1) then
    begin
      WriteLn(StdErr, 'cannot create temp key file ', KeyFile);
      Halt(1);
    end;
    try
      SigningKey := SigningKey + LineEnding;
      FileWrite(KeyHandle, SigningKey[1], Length(SigningKey));
      FileClose(KeyHandle);
      Signature := RunOpenSsl(['dgst', '-sha256', '-sign', KeyFile], SigningInput);
    finally
      DeleteFile(KeyFile);
    end;
    Jwt := SigningInput + '.' + Base64Url(Signature);
    // 5. The output: two headers and one console line.
    Output := TJSONObject.Create(['protocol', 1,
      'request', TJSONObject.Create(['headers', TJSONArray.Create([
        TJSONObject.Create(['key', 'x-acme-signature', 'value', Jwt]),
        TJSONObject.Create(['key', 'x-acme-client', 'value', ClientId])])]),
      'console', TJSONArray.Create(['signed ' + Path + ' with key ' + KeyId])]);
    try
      WriteLn(Output.AsJSON);
    finally
      Output.Free;
    end;
  finally
    Root.Free;
  end;
end.
