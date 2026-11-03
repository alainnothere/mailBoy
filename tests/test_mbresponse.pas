unit test_mbResponse;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry, mbResponse;

type
  TResponseTest = class(TTestCase)
  private
    function LoadFixture(const Name: string): string;
    function ParseFixture(const Name: string): TResponse;
  published
    procedure TestSimple200Json;
    procedure TestNotFound404Html;
    procedure TestRedirectChain;
    procedure TestProxyConnectIsNotAHop;
    procedure TestProxyConnectWithRedirect;
    procedure TestHttp2NoStatusText;
    procedure TestNoContent204;
    procedure TestDuplicateSetCookie;
    procedure TestBareLfLineEndings;
    procedure TestBodyWithFakeStatusLine;
    procedure TestContinue100Then200;
    procedure TestBinaryBodyWithNul;
    procedure TestFoldedHeader;
    procedure TestGarbageInput;
    procedure TestEmptyInput;
    procedure TestHeaderBlockWithoutBlankLine;
    procedure TestMalformedStatusLine;
    procedure TestElapsedAndExitCode;
  end;

implementation

function TResponseTest.LoadFixture(const Name: string): string;
var
  Path: string;
  FS: TFileStream;
begin
  // Tests run from the repo root (see Makefile).
  Path := IncludeTrailingPathDelimiter(GetCurrentDir) + 'tests' + PathDelim +
    'fixtures' + PathDelim + 'curl' + PathDelim + Name + '.txt';
  AssertTrue('fixture exists: ' + Path, FileExists(Path));
  FS := TFileStream.Create(Path, fmOpenRead or fmShareDenyWrite);
  try
    Result := '';
    SetLength(Result, FS.Size);
    if FS.Size > 0 then
      FS.ReadBuffer(Result[1], FS.Size);
  finally
    FS.Free;
  end;
end;

function TResponseTest.ParseFixture(const Name: string): TResponse;
begin
  Result := ParseCurlOutput(LoadFixture(Name), 0);
end;

procedure TResponseTest.TestSimple200Json;
var
  R: TResponse;
begin
  R := ParseFixture('simple_200_json');
  try
    AssertFalse('no parse error', R.ParseError);
    AssertEquals('status code', 200, R.StatusCode);
    AssertEquals('status text', 'OK', R.StatusText);
    AssertEquals('http version', '1.1', R.HttpVersion);
    AssertEquals('status line', 'HTTP/1.1 200 OK', R.StatusLine);
    AssertTrue('is success', R.IsSuccess);
    AssertEquals('header count', 5, R.Headers.Count);
    AssertEquals('headers keep order', 'Date', R.Headers.Names[0]);
    AssertEquals('content type', 'application/json; charset=utf-8', R.ContentType);
    AssertEquals('case-insensitive lookup', 'nginx/1.24.0', R.HeaderValue('SERVER'));
    AssertEquals('missing header is empty', '', R.HeaderValue('X-Nope'));
    AssertFalse('HasHeader missing', R.HasHeader('X-Nope'));
    AssertTrue('HasHeader present', R.HasHeader('x-request-id'));
    AssertEquals('body', '{"id":1,"name":"mailBoy"}' + #10, R.Body);
    AssertEquals('content length', 26, R.ContentLength);
    AssertEquals('no redirects', 0, R.RedirectCount);
    AssertEquals('no intermediates', 0, Length(R.IntermediateStatusCodes));
  finally
    R.Free;
  end;
end;

procedure TResponseTest.TestNotFound404Html;
var
  R: TResponse;
begin
  R := ParseFixture('not_found_404_html');
  try
    AssertEquals('status code', 404, R.StatusCode);
    AssertEquals('status text', 'Not Found', R.StatusText);
    AssertEquals('http version', '1.0', R.HttpVersion);
    AssertFalse('not success', R.IsSuccess);
    AssertEquals('content type', 'text/html', R.ContentType);
    AssertEquals('body', '<html><body><h1>404 Not Found</h1><p>No such page.</p></body></html>', R.Body);
    AssertEquals('content length', 68, R.ContentLength);
  finally
    R.Free;
  end;
end;

procedure TResponseTest.TestProxyConnectIsNotAHop;
var
  R: TResponse;
begin
  R := ParseFixture('proxy_connect_200');
  try
    AssertFalse('no parse error', R.ParseError);
    AssertEquals('final status', 200, R.StatusCode);
    AssertEquals('http/2 final', '2', R.HttpVersion);
    AssertEquals('tunnel reply is not an intermediate', 0, Length(R.IntermediateStatusCodes));
    AssertEquals('no redirects', 0, R.RedirectCount);
    AssertEquals('content type', 'application/json; charset=utf-8', R.ContentType);
    AssertEquals('body', '{"args": {}}' + #13#10, R.Body);
  finally
    R.Free;
  end;
end;

procedure TResponseTest.TestProxyConnectWithRedirect;
var
  R: TResponse;
begin
  // Each hop through the proxy gets its own CONNECT reply; only the 301 counts.
  R := ParseFixture('proxy_connect_redirect');
  try
    AssertFalse('no parse error', R.ParseError);
    AssertEquals('final status', 200, R.StatusCode);
    AssertEquals('one intermediate', 1, Length(R.IntermediateStatusCodes));
    AssertEquals('intermediate is 301', 301, R.IntermediateStatusCodes[0]);
    AssertEquals('redirect count', 1, R.RedirectCount);
    AssertEquals('final header', 'yes', R.HeaderValue('x-final'));
    AssertEquals('body', 'landed' + #13#10, R.Body);
  finally
    R.Free;
  end;
end;

procedure TResponseTest.TestRedirectChain;
var
  R: TResponse;
begin
  R := ParseFixture('redirect_301_200');
  try
    AssertFalse('no parse error', R.ParseError);
    AssertEquals('final status', 200, R.StatusCode);
    AssertEquals('final text', 'OK', R.StatusText);
    AssertEquals('redirect count', 1, R.RedirectCount);
    AssertEquals('one intermediate', 1, Length(R.IntermediateStatusCodes));
    AssertEquals('intermediate is 301', 301, R.IntermediateStatusCodes[0]);
    AssertEquals('headers are from final block', 3, R.Headers.Count);
    AssertEquals('final block header', 'yes', R.HeaderValue('X-Final'));
    AssertEquals('redirect header not carried over', '', R.HeaderValue('Location'));
    AssertEquals('content type from final', 'text/plain', R.ContentType);
    AssertEquals('body', 'landed' + #13#10, R.Body);
    AssertEquals('content length', 8, R.ContentLength);
  finally
    R.Free;
  end;
end;

procedure TResponseTest.TestHttp2NoStatusText;
var
  R: TResponse;
begin
  R := ParseFixture('http2_no_text');
  try
    AssertFalse('no parse error', R.ParseError);
    AssertEquals('status code', 200, R.StatusCode);
    AssertEquals('empty status text', '', R.StatusText);
    AssertEquals('http version', '2', R.HttpVersion);
    AssertEquals('lowercase h2 header found', 'cloudflare', R.HeaderValue('Server'));
    AssertEquals('content type', 'application/json', R.ContentType);
    AssertEquals('body', '{"status":"up"}' + #13#10, R.Body);
  finally
    R.Free;
  end;
end;

procedure TResponseTest.TestNoContent204;
var
  R: TResponse;
begin
  R := ParseFixture('no_content_204');
  try
    AssertEquals('status code', 204, R.StatusCode);
    AssertEquals('status text', 'No Content', R.StatusText);
    AssertEquals('http version', '2.0', R.HttpVersion);
    AssertTrue('is success', R.IsSuccess);
    AssertEquals('empty body', '', R.Body);
    AssertEquals('zero length', 0, R.ContentLength);
    AssertEquals('no content type', '', R.ContentType);
    AssertEquals('rate limit header', '99', R.HeaderValue('x-rate-limit'));
  finally
    R.Free;
  end;
end;

procedure TResponseTest.TestDuplicateSetCookie;
var
  R: TResponse;
  All: TStringArray;
begin
  R := ParseFixture('duplicate_set_cookie');
  try
    AssertEquals('all headers kept', 5, R.Headers.Count);
    All := R.HeaderValues('Set-Cookie');
    AssertEquals('three cookies', 3, Length(All));
    AssertEquals('first cookie', 'session=abc123; Path=/; HttpOnly', All[0]);
    AssertEquals('second cookie', 'theme=dark; Path=/', All[1]);
    AssertEquals('third cookie (lowercase name matched)', 'lang=en; Max-Age=3600', All[2]);
    AssertEquals('HeaderValue returns last', 'lang=en; Max-Age=3600', R.HeaderValue('SET-COOKIE'));
    AssertEquals('no match gives empty array', 0, Length(R.HeaderValues('Cookie')));
    AssertEquals('body', 'ok', R.Body);
  finally
    R.Free;
  end;
end;

procedure TResponseTest.TestBareLfLineEndings;
var
  R: TResponse;
begin
  R := ParseFixture('bare_lf');
  try
    AssertFalse('no parse error', R.ParseError);
    AssertEquals('status code', 200, R.StatusCode);
    AssertEquals('status text', 'OK', R.StatusText);
    AssertEquals('header count', 2, R.Headers.Count);
    AssertEquals('content type', 'text/plain', R.ContentType);
    AssertEquals('body with inner LF kept', 'hello' + #10 + 'world', R.Body);
    AssertEquals('content length', 11, R.ContentLength);
  finally
    R.Free;
  end;
end;

procedure TResponseTest.TestBodyWithFakeStatusLine;
var
  R: TResponse;
begin
  R := ParseFixture('body_with_fake_status');
  try
    AssertEquals('status code is the real one', 200, R.StatusCode);
    AssertEquals('no intermediates', 0, Length(R.IntermediateStatusCodes));
    AssertEquals('body kept intact',
      'log follows:' + #13#10 + 'HTTP/1.1 500 x' + #13#10 + 'not a real header' + #13#10, R.Body);
    AssertEquals('content length', 49, R.ContentLength);
    AssertEquals('header count', 2, R.Headers.Count);
  finally
    R.Free;
  end;
end;

procedure TResponseTest.TestContinue100Then200;
var
  R: TResponse;
begin
  R := ParseFixture('continue_100_200');
  try
    AssertEquals('final status', 201, R.StatusCode);
    AssertEquals('final text', 'Created', R.StatusText);
    AssertEquals('one intermediate', 1, Length(R.IntermediateStatusCodes));
    AssertEquals('intermediate is 100', 100, R.IntermediateStatusCodes[0]);
    AssertEquals('100 is not a redirect', 0, R.RedirectCount);
    AssertEquals('location', '/items/42', R.HeaderValue('Location'));
    AssertEquals('body', '{"id":42}', R.Body);
  finally
    R.Free;
  end;
end;

procedure TResponseTest.TestBinaryBodyWithNul;
var
  R: TResponse;
  Expected: string;
begin
  R := ParseFixture('binary_nul');
  try
    AssertEquals('status code', 200, R.StatusCode);
    AssertEquals('content type', 'application/octet-stream', R.ContentType);
    Expected := 'AB' + #0 + 'CD' + #255 + #13#10;
    AssertEquals('content length', 8, R.ContentLength);
    AssertTrue('body byte-exact', R.Body = Expected);
    AssertEquals('NUL at position 3', 0, Ord(R.Body[3]));
    AssertEquals('0xFF at position 6', 255, Ord(R.Body[6]));
  finally
    R.Free;
  end;
end;

procedure TResponseTest.TestFoldedHeader;
var
  R: TResponse;
begin
  R := ParseFixture('folded_header');
  try
    AssertFalse('no parse error', R.ParseError);
    AssertEquals('folded lines joined', 'first part, second part third part', R.HeaderValue('X-Long'));
    AssertEquals('header count', 2, R.Headers.Count);
    AssertEquals('content type', 'text/plain', R.ContentType);
    AssertEquals('body', 'body', R.Body);
  finally
    R.Free;
  end;
end;

procedure TResponseTest.TestGarbageInput;
var
  R: TResponse;
  Raw: string;
begin
  Raw := LoadFixture('garbage');
  R := ParseCurlOutput(Raw, 12);
  try
    AssertTrue('parse error flagged', R.ParseError);
    AssertTrue('has a message', R.ParseErrorMessage <> '');
    AssertEquals('status code zero', 0, R.StatusCode);
    AssertEquals('status text empty', '', R.StatusText);
    AssertFalse('not success', R.IsSuccess);
    AssertEquals('no headers', 0, R.Headers.Count);
    AssertEquals('whole input in body', Raw, R.Body);
    AssertEquals('elapsed carried', 12, R.ElapsedMs);
  finally
    R.Free;
  end;
end;

procedure TResponseTest.TestEmptyInput;
var
  R: TResponse;
begin
  R := ParseCurlOutput('', 0);
  try
    AssertTrue('parse error flagged', R.ParseError);
    AssertEquals('status code zero', 0, R.StatusCode);
    AssertEquals('empty body', '', R.Body);
  finally
    R.Free;
  end;
end;

procedure TResponseTest.TestHeaderBlockWithoutBlankLine;
var
  R: TResponse;
begin
  // Connection dropped after headers: no terminating blank line, no body.
  R := ParseCurlOutput('HTTP/1.1 502 Bad Gateway' + #13#10 + 'Server: proxy' + #13#10, 0);
  try
    AssertFalse('no parse error', R.ParseError);
    AssertEquals('status code', 502, R.StatusCode);
    AssertEquals('status text', 'Bad Gateway', R.StatusText);
    AssertEquals('server header', 'proxy', R.HeaderValue('server'));
    AssertEquals('empty body', '', R.Body);
  finally
    R.Free;
  end;
end;

procedure TResponseTest.TestMalformedStatusLine;
var
  R: TResponse;
begin
  R := ParseCurlOutput('HTTP/1.1 OK' + #13#10 + #13#10 + 'x', 0);
  try
    AssertTrue('parse error flagged', R.ParseError);
    AssertEquals('status code zero', 0, R.StatusCode);
    AssertEquals('whole input in body', 'HTTP/1.1 OK' + #13#10 + #13#10 + 'x', R.Body);
  finally
    R.Free;
  end;
end;

procedure TResponseTest.TestElapsedAndExitCode;
var
  R: TResponse;
begin
  R := ParseCurlOutput('HTTP/1.1 200 OK' + #13#10 + #13#10, 143, 0);
  try
    AssertEquals('elapsed', 143, R.ElapsedMs);
    AssertEquals('exit code', 0, R.CurlExitCode);
  finally
    R.Free;
  end;
  R := ParseCurlOutput('', 5000, 28);
  try
    AssertEquals('exit code timeout', 28, R.CurlExitCode);
    AssertTrue('parse error on empty output', R.ParseError);
  finally
    R.Free;
  end;
end;

initialization
  RegisterTest(TResponseTest);

end.
