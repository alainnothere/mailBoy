unit mbJsonFmt;

{ Pretty-printing of JSON text for the editors. Core layer: no LCL, no fpjson.

  A formatter inside an HTTP client is a text-editor feature, not a data
  feature: it must never change a value. Every JSON library (fpjson, jq,
  Python, node) parses numbers and prints them back from the parsed value,
  so 1.0 becomes 1, or 1.0000000000000000E+000, or 1E+3, depending on whose
  idea of a number you got. This unit instead walks the text once with a
  strict JSON grammar and copies every string and number through verbatim,
  only replacing the whitespace between tokens. Invalid input is refused
  with a line:column message, nothing is "repaired". }

{$mode objfpc}{$H+}

interface

const
  // Bodies above this are shown raw; a TMemo on a multi-MB document is a
  // hang, not a feature.
  PrettyJsonMaxBytes = 512 * 1024;
  // Deeper than this is refused; it is either hostile or a mistake.
  PrettyJsonMaxDepth = 512;

{ True and APretty filled when AText is a valid JSON object or array (RFC 8259,
  a leading UTF-8 BOM tolerated). Anything else returns False with AError set,
  such as "line 3, column 7: expected , or closing bracket". }
function PrettyJson(const AText: string; out APretty: string; out AError: string): Boolean;

{ Whether AText looks like a JSON document worth trying: first non-blank
  character (after an optional BOM) opens an object or an array and it is
  under PrettyJsonMaxBytes. }
function LooksLikeJson(const AText: string): Boolean;

implementation

uses
  SysUtils, Math;

const
  Bom = #$EF#$BB#$BF;
  Ws = [' ', #9, #10, #13];   // the only whitespace JSON allows
  Indent = '  ';

type
  EJsonFmt = class(Exception);

function StartIndex(const S: string): Integer;
begin
  if (Length(S) >= 3) and (Copy(S, 1, 3) = Bom) then
    Result := 4
  else
    Result := 1;
end;

function LooksLikeJson(const AText: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  if Length(AText) > PrettyJsonMaxBytes then
    Exit;
  I := StartIndex(AText);
  while (I <= Length(AText)) and (AText[I] in Ws) do
    Inc(I);
  Result := (I <= Length(AText)) and (AText[I] in ['{', '[']);
end;

function PrettyJson(const AText: string; out APretty: string; out AError: string): Boolean;
var
  S: string;
  I: Integer;             // cursor, 1-based
  Res: TStringBuilder;

  procedure Fail(const Msg: string);
  var
    Line, Col, K: Integer;
  begin
    Line := 1;
    Col := 1;
    for K := 1 to Min(I, Length(S)) - 1 do
      if S[K] = #10 then
      begin
        Inc(Line);
        Col := 1;
      end
      else
        Inc(Col);
    raise EJsonFmt.CreateFmt('line %d, column %d: %s', [Line, Col, Msg]);
  end;

  function Peek: Char;
  begin
    if I <= Length(S) then
      Result := S[I]
    else
      Result := #0;
  end;

  function Describe(C: Char): string;
  begin
    if C = #0 then
      Result := 'end of input'
    else if C < ' ' then
      Result := 'control character #' + IntToStr(Ord(C))
    else
      Result := '"' + C + '"';
  end;

  procedure SkipWs;
  begin
    while (I <= Length(S)) and (S[I] in Ws) do
      Inc(I);
  end;

  procedure NewLine(ADepth: Integer);
  var
    D: Integer;
  begin
    Res.Append(LineEnding);
    for D := 1 to ADepth do
      Res.Append(Indent);
  end;

  { Validates a string token starting at the opening quote and copies it
    through untouched, escapes and all. }
  procedure ParseString;
  var
    Start, H: Integer;
    C: Char;
  begin
    Start := I;
    Inc(I); // opening quote
    while True do
    begin
      if I > Length(S) then
        Fail('unterminated string');
      C := S[I];
      if C = '"' then
        Break;
      if C < ' ' then
        Fail('control character in string, escape it as \u00' + IntToHex(Ord(C), 2));
      if C = '\' then
      begin
        Inc(I);
        if I > Length(S) then
          Fail('unterminated string');
        case S[I] of
          '"', '\', '/', 'b', 'f', 'n', 'r', 't': ;
          'u':
            for H := 1 to 4 do
            begin
              Inc(I);
              if (I > Length(S)) or not (S[I] in ['0'..'9', 'a'..'f', 'A'..'F']) then
                Fail('\u needs four hex digits');
            end;
        else
          Fail('invalid escape \' + S[I]);
        end;
      end;
      Inc(I);
    end;
    Inc(I); // closing quote
    Res.Append(Copy(S, Start, I - Start));
  end;

  { RFC 8259 number: -? (0 | [1-9][0-9]*) (.[0-9]+)? ([eE][+-]?[0-9]+)?
    Copied through verbatim: 1.0 stays 1.0, 1e3 stays 1e3, 2^70 stays itself. }
  procedure ParseNumber;
  var
    Start: Integer;

    procedure Digits(const What: string);
    begin
      if not (Peek in ['0'..'9']) then
        Fail(What);
      while Peek in ['0'..'9'] do
        Inc(I);
    end;

  begin
    Start := I;
    if Peek = '-' then
      Inc(I);
    if Peek = '0' then
    begin
      Inc(I);
      if Peek in ['0'..'9'] then
        Fail('leading zeros are not allowed');
    end
    else
      Digits('expected a digit');
    if Peek = '.' then
    begin
      Inc(I);
      Digits('expected a digit after the decimal point');
    end;
    if Peek in ['e', 'E'] then
    begin
      Inc(I);
      if Peek in ['+', '-'] then
        Inc(I);
      Digits('expected a digit in the exponent');
    end;
    Res.Append(Copy(S, Start, I - Start));
  end;

  procedure ParseLiteral(const Word: string);
  begin
    if Copy(S, I, Length(Word)) <> Word then
      Fail('unexpected ' + Describe(Peek));
    Inc(I, Length(Word));
    Res.Append(Word);
  end;

  procedure ParseValue(ADepth: Integer); forward;

  procedure ParseContainer(ADepth: Integer; const Close: Char);
  var
    First: Boolean;
  begin
    if ADepth > PrettyJsonMaxDepth then
      Fail('nested deeper than ' + IntToStr(PrettyJsonMaxDepth) + ' levels');
    Res.Append(S[I]);
    Inc(I);
    SkipWs;
    if Peek = Close then
    begin
      Res.Append(Close);
      Inc(I);
      Exit;
    end;
    First := True;
    while True do
    begin
      if not First then
      begin
        Res.Append(',');
        Inc(I);
        SkipWs;
      end;
      First := False;
      NewLine(ADepth);
      if Close = '}' then
      begin
        if Peek <> '"' then
          Fail('expected a quoted key, got ' + Describe(Peek));
        ParseString;
        SkipWs;
        if Peek <> ':' then
          Fail('expected : after key, got ' + Describe(Peek));
        Inc(I);
        Res.Append(': ');
        SkipWs;
      end;
      ParseValue(ADepth);
      SkipWs;
      if Peek = Close then
        Break;
      if Peek <> ',' then
        Fail('expected , or ' + Close + ', got ' + Describe(Peek));
    end;
    NewLine(ADepth - 1);
    Res.Append(Close);
    Inc(I);
  end;

  procedure ParseValue(ADepth: Integer);
  begin
    case Peek of
      '{': ParseContainer(ADepth + 1, '}');
      '[': ParseContainer(ADepth + 1, ']');
      '"': ParseString;
      '-', '0'..'9': ParseNumber;
      't': ParseLiteral('true');
      'f': ParseLiteral('false');
      'n': ParseLiteral('null');
    else
      Fail('unexpected ' + Describe(Peek));
    end;
  end;

begin
  Result := False;
  APretty := '';
  AError := '';
  if Length(AText) > PrettyJsonMaxBytes then
  begin
    AError := 'too large to format';
    Exit;
  end;
  if not LooksLikeJson(AText) then
  begin
    AError := 'not a JSON object or array';
    Exit;
  end;
  S := AText;
  I := StartIndex(S);
  Res := TStringBuilder.Create(Length(S) * 2);
  try
    try
      SkipWs;
      ParseValue(0);
      SkipWs;
      if I <= Length(S) then
        Fail('unexpected ' + Describe(Peek) + ' after the document');
      APretty := Res.ToString;
      Result := True;
    except
      on E: EJsonFmt do
        AError := E.Message;
    end;
  finally
    Res.Free;
  end;
end;

end.
