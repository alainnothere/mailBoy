unit test_mbJsonFmt;

{ The formatter has one job: change whitespace between tokens and nothing
  else. These tests feed it every number spelling, escape and structural
  mistake that real servers and real fingers produce. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry, mbJsonFmt;

type
  TJsonFmtTest = class(TTestCase)
  private
    function Pretty(const Src: string): string;          // asserts success
    function Refused(const Src: string): string;         // asserts failure, returns error
    function Lines(const S: string): Integer;
    procedure AssertContains(const Msg, Needle, Hay: string);
  published
    // shape
    procedure TestObjectIsIndented;
    procedure TestArrayOfScalars;
    procedure TestEmptyContainersStayInline;
    procedure TestNestedEmpties;
    procedure TestLeadingAndTrailingWhitespace;
    procedure TestCrLfAndTabsBetweenTokens;
    procedure TestUtf8Bom;
    procedure TestIdempotent;
    procedure TestKeyOrderAndDuplicateKeys;
    // values are sacred
    procedure TestNumbersVerbatim;
    procedure TestNegativeZeroAndTinyExponent;
    procedure TestHugeIntegerVerbatim;
    procedure TestStringEscapesVerbatim;
    procedure TestStringWithStructuralCharacters;
    procedure TestUtf8BytesPassThrough;
    procedure TestStringLooksLikeNumber;
    // refused: numbers
    procedure TestLeadingZeroRefused;
    procedure TestTrailingDotRefused;
    procedure TestLeadingDotRefused;
    procedure TestPlusSignRefused;
    procedure TestBareExponentRefused;
    procedure TestHexNaNInfinityRefused;
    // refused: strings
    procedure TestUnterminatedStringRefused;
    procedure TestBadEscapeRefused;
    procedure TestShortUnicodeEscapeRefused;
    procedure TestRawNewlineInStringRefused;
    procedure TestSingleQuotesRefused;
    // refused: structure
    procedure TestTrailingCommaRefused;
    procedure TestMissingCommaRefused;
    procedure TestMissingColonRefused;
    procedure TestUnquotedKeyRefused;
    procedure TestNumericKeyRefused;
    procedure TestUnterminatedObjectRefused;
    procedure TestMismatchedBracketsRefused;
    procedure TestTrailingGarbageRefused;
    procedure TestTwoDocumentsRefused;
    procedure TestCommentsRefused;
    procedure TestMisspelledLiteralRefused;
    procedure TestCapitalisedLiteralRefused;
    procedure TestFormFeedWhitespaceRefused;
    procedure TestNulByteRefused;
    // refused: policy
    procedure TestScalarRootRefused;
    procedure TestEmptyRefused;
    procedure TestHtmlRefused;
    procedure TestTooLargeRefused;
    procedure TestTooDeepRefused;
    procedure TestDeepButAllowed;
    // diagnostics
    procedure TestErrorHasLineAndColumn;
  end;

implementation

function TJsonFmtTest.Pretty(const Src: string): string;
var
  E: string;
begin
  AssertTrue('should format: ' + Src + ' -> ' + E, PrettyJson(Src, Result, E));
  AssertEquals('no error on success', '', E);
end;

function TJsonFmtTest.Refused(const Src: string): string;
var
  P: string;
begin
  AssertFalse('should refuse: ' + Src, PrettyJson(Src, P, Result));
  AssertEquals('no output on refusal', '', P);
  AssertTrue('error set', Result <> '');
end;

function TJsonFmtTest.Lines(const S: string): Integer;
begin
  Result := 1 + (Length(S) - Length(StringReplace(S, LineEnding, '', [rfReplaceAll]))) div Length(LineEnding);
end;

procedure TJsonFmtTest.AssertContains(const Msg, Needle, Hay: string);
begin
  AssertTrue(Msg + ' | expected <' + Needle + '> in <' + Hay + '>', Pos(Needle, Hay) > 0);
end;

{ ---- shape ---- }

procedure TJsonFmtTest.TestObjectIsIndented;
var
  P: string;
begin
  P := Pretty('{"a":1,"b":{"c":[1,2]}}');
  AssertEquals('exact',
    '{' + LineEnding +
    '  "a": 1,' + LineEnding +
    '  "b": {' + LineEnding +
    '    "c": [' + LineEnding +
    '      1,' + LineEnding +
    '      2' + LineEnding +
    '    ]' + LineEnding +
    '  }' + LineEnding +
    '}', P);
end;

procedure TJsonFmtTest.TestArrayOfScalars;
begin
  AssertEquals('exact',
    '[' + LineEnding + '  true,' + LineEnding + '  false,' + LineEnding +
    '  null,' + LineEnding + '  "s",' + LineEnding + '  0' + LineEnding + ']',
    Pretty('[true,false,null,"s",0]'));
end;

procedure TJsonFmtTest.TestEmptyContainersStayInline;
var
  P: string;
begin
  P := Pretty('{"a":{},"b":[ ],"c":{ ' + #13#10 + ' }}');
  AssertContains('empty object', '"a": {},', P);
  AssertContains('empty array with space', '"b": [],', P);
  AssertContains('empty object with newline', '"c": {}', P);
  AssertEquals('top level empties', '{}', Pretty('{}'));
  AssertEquals('top level empties', '[]', Pretty('[ ]'));
end;

procedure TJsonFmtTest.TestNestedEmpties;
begin
  AssertEquals('exact',
    '[' + LineEnding + '  {},' + LineEnding + '  [],' + LineEnding +
    '  [' + LineEnding + '    {}' + LineEnding + '  ]' + LineEnding + ']',
    Pretty('[{},[],[{}]]'));
end;

procedure TJsonFmtTest.TestLeadingAndTrailingWhitespace;
begin
  AssertEquals('trimmed', '{' + LineEnding + '  "a": 1' + LineEnding + '}',
    Pretty(#13#10'   {"a":1}'#10#10'  '));
end;

procedure TJsonFmtTest.TestCrLfAndTabsBetweenTokens;
begin
  AssertEquals('normalised', '{' + LineEnding + '  "a": [' + LineEnding + '    1' + LineEnding + '  ]' + LineEnding + '}',
    Pretty('{'#13#10#9'"a"'#9':'#13#10'['#13#10#9#9'1'#13#10']'#13#10'}'));
end;

procedure TJsonFmtTest.TestUtf8Bom;
var
  P: string;
begin
  P := Pretty(#$EF#$BB#$BF'{"a":1}');
  AssertEquals('bom dropped, formatted', '{' + LineEnding + '  "a": 1' + LineEnding + '}', P);
  AssertTrue('looks like json with bom', LooksLikeJson(#$EF#$BB#$BF'  [1]'));
end;

procedure TJsonFmtTest.TestIdempotent;
var
  P1, P2: string;
begin
  P1 := Pretty('{"a":[1.0,2e5,{"b":null,"c":"x\\ny"}],"d":{},"e":"é"}');
  P2 := Pretty(P1);
  AssertEquals('stable', P1, P2);
end;

procedure TJsonFmtTest.TestKeyOrderAndDuplicateKeys;
var
  P: string;
begin
  P := Pretty('{"zebra":1,"apple":2,"zebra":3}');
  AssertTrue('zebra first', Pos('zebra', P) < Pos('apple', P));
  AssertEquals('both zebras kept', 4, Lines(P) - 1);   // 3 members + braces
  AssertContains('second zebra', '"zebra": 3', P);
end;

{ ---- values are sacred ---- }

procedure TJsonFmtTest.TestNumbersVerbatim;
var
  P: string;
begin
  P := Pretty('{"a":1.0,"b":1e3,"c":1E+3,"d":-0.50,"e":0,"f":100,"g":1.5e-10,"h":-7,"i":0.0}');
  AssertContains('1.0', '"a": 1.0,', P);
  AssertContains('1e3', '"b": 1e3,', P);
  AssertContains('1E+3', '"c": 1E+3,', P);
  AssertContains('-0.50', '"d": -0.50,', P);
  AssertContains('0', '"e": 0,', P);
  AssertContains('100', '"f": 100,', P);
  AssertContains('1.5e-10', '"g": 1.5e-10,', P);
  AssertContains('-7', '"h": -7,', P);
  AssertContains('0.0', '"i": 0.0', P);
end;

procedure TJsonFmtTest.TestNegativeZeroAndTinyExponent;
var
  P: string;
begin
  P := Pretty('[-0,-0.0,1e-400,1e400,0e0]');
  AssertContains('-0', '  -0,', P);
  AssertContains('-0.0', '  -0.0,', P);
  AssertContains('underflow literal kept', '  1e-400,', P);
  AssertContains('overflow literal kept', '  1e400,', P);
  AssertContains('0e0', '  0e0', P);
end;

procedure TJsonFmtTest.TestHugeIntegerVerbatim;
const
  Big = '123456789012345678901234567890123456789';
begin
  AssertContains('big int kept', '"id": ' + Big, Pretty('{"id":' + Big + '}'));
  AssertContains('big negative kept', '"id": -' + Big, Pretty('{"id":-' + Big + '}'));
  AssertContains('long fraction kept', '0.10000000000000000555111512312578270211815834045410156250',
    Pretty('[0.10000000000000000555111512312578270211815834045410156250]'));
end;

procedure TJsonFmtTest.TestStringEscapesVerbatim;
const
  // "\" \\ \/ \b \f \n \r \t é 😀" -- every escape JSON has
  Src = '{"s":"\" \\ \/ \b \f \n \r \t é 😀"}';
begin
  AssertContains('escapes untouched', '"s": "\" \\ \/ \b \f \n \r \t é 😀"', Pretty(Src));
end;

procedure TJsonFmtTest.TestStringWithStructuralCharacters;
var
  P: string;
begin
  P := Pretty('{"s":"a{b}[c],:\"d\" , : {{ ]]"}');
  AssertContains('string untouched', '"s": "a{b}[c],:\"d\" , : {{ ]]"', P);
  AssertEquals('one member, three lines', 3, Lines(P));
end;

procedure TJsonFmtTest.TestUtf8BytesPassThrough;
const
  // é as raw UTF-8 (C3 A9), a 4-byte emoji (F0 9F 98 80), and a key in Japanese
  Src = '{"caf'#$C3#$A9'":"'#$F0#$9F#$98#$80'","'#$E6#$97#$A5#$E6#$9C#$AC'":1}';
var
  P: string;
begin
  P := Pretty(Src);
  AssertContains('key bytes', '"caf'#$C3#$A9'": "'#$F0#$9F#$98#$80'"', P);
  AssertContains('cjk key', '"'#$E6#$97#$A5#$E6#$9C#$AC'": 1', P);
end;

procedure TJsonFmtTest.TestStringLooksLikeNumber;
begin
  AssertContains('kept as string', '"v": "01.50e+3"', Pretty('{"v":"01.50e+3"}'));
end;

{ ---- refused: numbers ---- }

procedure TJsonFmtTest.TestLeadingZeroRefused;
begin
  AssertContains('msg', 'leading zeros', Refused('[01]'));
  Refused('{"a":007}');
  Refused('[-012]');
end;

procedure TJsonFmtTest.TestTrailingDotRefused;
begin
  AssertContains('msg', 'decimal point', Refused('[1.]'));
  Refused('{"a":1.}');
end;

procedure TJsonFmtTest.TestLeadingDotRefused;
begin
  Refused('[.5]');
  Refused('[-.5]');
end;

procedure TJsonFmtTest.TestPlusSignRefused;
begin
  Refused('[+1]');
end;

procedure TJsonFmtTest.TestBareExponentRefused;
begin
  AssertContains('msg', 'exponent', Refused('[1e]'));
  Refused('[1e+]');
  Refused('[1E-]');
end;

procedure TJsonFmtTest.TestHexNaNInfinityRefused;
begin
  Refused('[0x10]');
  Refused('[NaN]');
  Refused('[Infinity]');
  Refused('[-Infinity]');
end;

{ ---- refused: strings ---- }

procedure TJsonFmtTest.TestUnterminatedStringRefused;
begin
  AssertContains('msg', 'unterminated string', Refused('{"a":"abc}'));
  AssertContains('msg', 'unterminated string', Refused('{"a":"abc\"}'));
  AssertContains('msg', 'unterminated string', Refused('["x\'));
end;

procedure TJsonFmtTest.TestBadEscapeRefused;
begin
  AssertContains('msg', 'invalid escape \x', Refused('["\x41"]'));
  Refused('["\a"]');
  Refused('["\''"]');   // \' is not JSON
end;

procedure TJsonFmtTest.TestShortUnicodeEscapeRefused;
begin
  AssertContains('msg', 'four hex digits', Refused('["\u12"]'));
  Refused('["\u12G4"]');
  Refused('["\u"]');
end;

procedure TJsonFmtTest.TestRawNewlineInStringRefused;
begin
  AssertContains('msg', 'control character', Refused('{"a":"line1'#10'line2"}'));
  Refused('{"a":"tab'#9'here"}');
end;

procedure TJsonFmtTest.TestSingleQuotesRefused;
begin
  Refused('{''a'':1}');
  Refused('{"a":''b''}');
end;

{ ---- refused: structure ---- }

procedure TJsonFmtTest.TestTrailingCommaRefused;
begin
  AssertContains('msg', 'expected a quoted key', Refused('{"a":1,}'));
  Refused('[1,2,]');
  Refused('[,]');
  Refused('{,}');
end;

procedure TJsonFmtTest.TestMissingCommaRefused;
begin
  AssertContains('msg', 'expected , or }', Refused('{"a":1 "b":2}'));
  AssertContains('msg', 'expected , or ]', Refused('[1 2]'));
end;

procedure TJsonFmtTest.TestMissingColonRefused;
begin
  AssertContains('msg', 'expected : after key', Refused('{"a" 1}'));
  Refused('{"a"}');
end;

procedure TJsonFmtTest.TestUnquotedKeyRefused;
begin
  AssertContains('msg', 'expected a quoted key', Refused('{a:1}'));
end;

procedure TJsonFmtTest.TestNumericKeyRefused;
begin
  Refused('{1:2}');
  Refused('{true:1}');
  Refused('{null:1}');
end;

procedure TJsonFmtTest.TestUnterminatedObjectRefused;
begin
  AssertContains('msg', 'end of input', Refused('{"a":1'));
  AssertContains('msg', 'end of input', Refused('{"a":'));
  AssertContains('msg', 'end of input', Refused('['));
  Refused('{"a":{"b":[1,2}');
end;

procedure TJsonFmtTest.TestMismatchedBracketsRefused;
begin
  Refused('{"a":1]');
  Refused('[1,2}');
  Refused('[{]}');
end;

procedure TJsonFmtTest.TestTrailingGarbageRefused;
begin
  AssertContains('msg', 'after the document', Refused('{"a":1} x'));
  Refused('{"a":1}}');
  Refused('[1]]');
end;

procedure TJsonFmtTest.TestTwoDocumentsRefused;
begin
  Refused('{"a":1}{"b":2}');
  Refused('{"a":1}'#10'{"b":2}');   // NDJSON is not JSON
  Refused('[1][2]');
end;

procedure TJsonFmtTest.TestCommentsRefused;
begin
  Refused('{"a":1 /* c */}');
  Refused('{"a":1 // c'#10'}');
  Refused('// top'#10'{"a":1}');
end;

procedure TJsonFmtTest.TestMisspelledLiteralRefused;
begin
  Refused('[tru]');
  Refused('[truee]');
  Refused('[nul]');
  Refused('[fals]');
  Refused('[nulll]');
end;

procedure TJsonFmtTest.TestCapitalisedLiteralRefused;
begin
  Refused('[True]');
  Refused('[NULL]');
  Refused('[FALSE]');
  Refused('[undefined]');
end;

procedure TJsonFmtTest.TestFormFeedWhitespaceRefused;
begin
  Refused('{'#12'"a":1}');            // form feed is not JSON whitespace
  Refused('{"a":'#$C2#$A0'1}');       // NBSP neither
  Refused('{"a":1'#11'}');            // vertical tab neither
end;

procedure TJsonFmtTest.TestNulByteRefused;
begin
  Refused('{"a":1}'#0);
  Refused('{"a":'#0'1}');
  AssertContains('msg', 'control character', Refused('{"a":"x'#0'y"}'));
end;

{ ---- refused: policy ---- }

procedure TJsonFmtTest.TestScalarRootRefused;
begin
  AssertContains('msg', 'not a JSON object or array', Refused('42'));
  Refused('"hi"');
  Refused('true');
  Refused('null');
end;

procedure TJsonFmtTest.TestEmptyRefused;
begin
  Refused('');
  Refused('   ');
  Refused(#13#10#9);
  Refused(#$EF#$BB#$BF);
end;

procedure TJsonFmtTest.TestHtmlRefused;
begin
  Refused('<html><body>404</body></html>');
  Refused('<!DOCTYPE html>');
end;

procedure TJsonFmtTest.TestTooLargeRefused;
var
  Big: string;
begin
  Big := '[' + StringOfChar('1', PrettyJsonMaxBytes) + ']';
  AssertFalse('not worth trying', LooksLikeJson(Big));
  AssertEquals('msg', 'too large to format', Refused(Big));
end;

procedure TJsonFmtTest.TestTooDeepRefused;
var
  Src: string;
begin
  Src := StringOfChar('[', PrettyJsonMaxDepth + 1) + StringOfChar(']', PrettyJsonMaxDepth + 1);
  AssertContains('msg', 'nested deeper than', Refused(Src));
end;

procedure TJsonFmtTest.TestDeepButAllowed;
var
  Src, P: string;
begin
  Src := StringOfChar('[', PrettyJsonMaxDepth) + StringOfChar(']', PrettyJsonMaxDepth);
  P := Pretty(Src);
  AssertEquals('innermost is inline empty', 1, (Length(P) - Length(StringReplace(P, '[]', '', [rfReplaceAll]))) div 2);
end;

{ ---- diagnostics ---- }

procedure TJsonFmtTest.TestErrorHasLineAndColumn;
var
  E: string;
begin
  E := Refused('{'#10'  "a": 1,'#10'  "b": tru'#10'}');
  AssertContains('line', 'line 3', E);
  AssertContains('column', 'column 8', E);
  E := Refused('{"a":1 "b":2}');
  AssertContains('line 1', 'line 1', E);
  AssertContains('column 8', 'column 8', E);
end;

initialization
  RegisterTest(TJsonFmtTest);

end.
