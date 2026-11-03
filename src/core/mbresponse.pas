unit mbResponse;

{ Parses the raw stdout of `curl -i -s` into status, headers and body.
  Core layer: no LCL, no fpjson, no global state. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils;

type
  TIntegerArray = array of Integer;

  TResponse = class
  private
    FStatusLine: string;
    FStatusCode: Integer;
    FStatusText: string;
    FHttpVersion: string;
    FHeaders: TStringList;
    FBody: string;
    FElapsedMs: Integer;
    FCurlExitCode: Integer;
    FIntermediateStatusCodes: TIntegerArray;
    FParseError: Boolean;
    FParseErrorMessage: string;
    function GetContentLength: Int64;
    function GetContentType: string;
    function GetIsSuccess: Boolean;
    function GetRedirectCount: Integer;
  public
    constructor Create;
    destructor Destroy; override;
    { Case-insensitive lookup. Returns the LAST header with that name, '' if none. }
    function HeaderValue(const Name: string): string;
    { Case-insensitive lookup. All values with that name, in order of appearance. }
    function HeaderValues(const Name: string): TStringArray;
    function HasHeader(const Name: string): Boolean;

    property StatusLine: string read FStatusLine;
    property StatusCode: Integer read FStatusCode;
    property StatusText: string read FStatusText;
    property HttpVersion: string read FHttpVersion;
    { One 'Name=Value' entry per header line of the final block, order and
      duplicates preserved, values trimmed. }
    property Headers: TStringList read FHeaders;
    property Body: string read FBody;
    property ElapsedMs: Integer read FElapsedMs write FElapsedMs;
    property CurlExitCode: Integer read FCurlExitCode write FCurlExitCode;
    property ContentLength: Int64 read GetContentLength;
    property ContentType: string read GetContentType;
    property IsSuccess: Boolean read GetIsSuccess;
    { Status codes of the header blocks that preceded the final one
      (redirects, 100 Continue), in order. }
    property IntermediateStatusCodes: TIntegerArray read FIntermediateStatusCodes;
    property RedirectCount: Integer read GetRedirectCount;
    property ParseError: Boolean read FParseError;
    property ParseErrorMessage: string read FParseErrorMessage;
  end;

{ Parses Raw (what curl -i wrote to stdout). Never raises; on input that is
  not an HTTP response, StatusCode is 0, Body holds all of Raw and ParseError
  is set. The caller frees the result. }
function ParseCurlOutput(const Raw: string; ElapsedMs: Integer): TResponse;
function ParseCurlOutput(const Raw: string; ElapsedMs: Integer; CurlExitCode: Integer): TResponse;

implementation

{ ---- TResponse ---------------------------------------------------------- }

constructor TResponse.Create;
begin
  inherited Create;
  FHeaders := TStringList.Create;
  FHeaders.CaseSensitive := False;
  FHeaders.Duplicates := dupAccept;
  SetLength(FIntermediateStatusCodes, 0);
end;

destructor TResponse.Destroy;
begin
  FHeaders.Free;
  inherited Destroy;
end;

function TResponse.GetContentLength: Int64;
begin
  Result := Length(FBody);
end;

function TResponse.GetContentType: string;
begin
  Result := HeaderValue('Content-Type');
end;

function TResponse.GetIsSuccess: Boolean;
begin
  Result := (FStatusCode >= 200) and (FStatusCode <= 299);
end;

function TResponse.GetRedirectCount: Integer;
var
  I: Integer;
begin
  // 100 Continue blocks are intermediate but not redirects.
  Result := 0;
  for I := 0 to High(FIntermediateStatusCodes) do
    if (FIntermediateStatusCodes[I] >= 300) and (FIntermediateStatusCodes[I] <= 399) then
      Inc(Result);
end;

function TResponse.HeaderValue(const Name: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := FHeaders.Count - 1 downto 0 do
    if SameText(FHeaders.Names[I], Name) then
    begin
      Result := FHeaders.ValueFromIndex[I];
      Exit;
    end;
end;

function TResponse.HeaderValues(const Name: string): TStringArray;
var
  I, N: Integer;
begin
  Result := nil;
  N := 0;
  for I := 0 to FHeaders.Count - 1 do
    if SameText(FHeaders.Names[I], Name) then
    begin
      SetLength(Result, N + 1);
      Result[N] := FHeaders.ValueFromIndex[I];
      Inc(N);
    end;
end;

function TResponse.HasHeader(const Name: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 0 to FHeaders.Count - 1 do
    if SameText(FHeaders.Names[I], Name) then
      Exit(True);
end;

{ ---- parsing helpers ---------------------------------------------------- }

{ Reads one line starting at P (1-based), strips CRLF or LF, advances P past
  the terminator. At end of input returns '' and leaves P > Length(S). }
function ReadLine(const S: string; var P: Integer): string;
var
  Start, L: Integer;
begin
  L := Length(S);
  Start := P;
  while (P <= L) and (S[P] <> #10) do
    Inc(P);
  Result := Copy(S, Start, P - Start);
  if (Result <> '') and (Result[Length(Result)] = #13) then
    SetLength(Result, Length(Result) - 1);
  if P <= L then
    Inc(P); // skip the LF
end;

{ True when the text at P looks like a status line: 'HTTP/', one or more
  digits or dots, a space, exactly three digits, then a space or end of line. }
function IsStatusLineAt(const S: string; P: Integer): Boolean;
var
  L: Integer;
begin
  Result := False;
  L := Length(S);
  if Copy(S, P, 5) <> 'HTTP/' then
    Exit;
  P := P + 5;
  if (P > L) or not (S[P] in ['0'..'9', '.']) then
    Exit;
  while (P <= L) and (S[P] in ['0'..'9', '.']) do
    Inc(P);
  if (P > L) or (S[P] <> ' ') then
    Exit;
  Inc(P);
  if P + 2 > L then
    Exit;
  if not ((S[P] in ['0'..'9']) and (S[P + 1] in ['0'..'9']) and (S[P + 2] in ['0'..'9'])) then
    Exit;
  P := P + 3;
  Result := (P > L) or (S[P] in [' ', #13, #10]);
end;

procedure SplitStatusLine(const Line: string; out Version: string;
  out Code: Integer; out Text: string);
var
  Rest: string;
  SpacePos: Integer;
begin
  // Line already passed IsStatusLineAt, so the split below cannot fail.
  Rest := Copy(Line, 6, MaxInt);
  SpacePos := Pos(' ', Rest);
  Version := Copy(Rest, 1, SpacePos - 1);
  Rest := Copy(Rest, SpacePos + 1, MaxInt);
  Code := StrToIntDef(Copy(Rest, 1, 3), 0);
  Text := Trim(Copy(Rest, 4, MaxInt));
end;

{ Parses one header block starting at P: status line, header lines, blank
  line. Leaves P at the first byte after the blank line (or past the end).
  Headers go into List as Name=Value. }
procedure ParseHeaderBlock(const S: string; var P: Integer; List: TStringList;
  out StatusLine: string);
var
  Line, Name, Value: string;
  ColonPos: Integer;
begin
  StatusLine := ReadLine(S, P);
  List.Clear;
  while P <= Length(S) do
  begin
    Line := ReadLine(S, P);
    if Line = '' then
      Break; // end of header block
    if (Line[1] in [' ', #9]) and (List.Count > 0) then
    begin
      // Obsolete folding: continuation of the previous header's value.
      List[List.Count - 1] := List[List.Count - 1] + ' ' + Trim(Line);
      Continue;
    end;
    ColonPos := Pos(':', Line);
    if ColonPos = 0 then
    begin
      // Malformed line without a colon: keep it as a name with empty value.
      List.Add(Trim(Line) + '=');
      Continue;
    end;
    Name := Trim(Copy(Line, 1, ColonPos - 1));
    Value := Trim(Copy(Line, ColonPos + 1, MaxInt));
    List.Add(Name + '=' + Value);
  end;
end;

{ ---- public ------------------------------------------------------------- }

function ParseCurlOutput(const Raw: string; ElapsedMs: Integer; CurlExitCode: Integer): TResponse;
var
  P, N: Integer;
  StatusLine, Version, Text: string;
  Code: Integer;
begin
  Result := TResponse.Create;
  Result.FElapsedMs := ElapsedMs;
  Result.FCurlExitCode := CurlExitCode;

  if not IsStatusLineAt(Raw, 1) then
  begin
    Result.FParseError := True;
    if Raw = '' then
      Result.FParseErrorMessage := 'empty response'
    else
      Result.FParseErrorMessage := 'response does not start with an HTTP status line';
    Result.FBody := Raw;
    Exit;
  end;

  P := 1;
  repeat
    ParseHeaderBlock(Raw, P, Result.FHeaders, StatusLine);
    SplitStatusLine(StatusLine, Version, Code, Text);
    // Another status line right after the blank line means this block was
    // an intermediate response (redirect or 100 Continue). Only blocks that
    // start exactly here count; the body is never scanned.
    if (P <= Length(Raw)) and IsStatusLineAt(Raw, P) then
    begin
      // curl behind an HTTP proxy prints the CONNECT tunnel reply first:
      // "HTTP/1.1 200 Connection established". It is not a hop.
      if not SameText(Text, 'Connection established') then
      begin
        N := Length(Result.FIntermediateStatusCodes);
        SetLength(Result.FIntermediateStatusCodes, N + 1);
        Result.FIntermediateStatusCodes[N] := Code;
      end;
    end
    else
      Break;
  until False;

  Result.FStatusLine := StatusLine;
  Result.FHttpVersion := Version;
  Result.FStatusCode := Code;
  Result.FStatusText := Text;
  Result.FBody := Copy(Raw, P, MaxInt); // byte-exact, never trimmed
end;

function ParseCurlOutput(const Raw: string; ElapsedMs: Integer): TResponse;
begin
  Result := ParseCurlOutput(Raw, ElapsedMs, 0);
end;

end.
