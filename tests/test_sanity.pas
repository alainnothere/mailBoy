unit test_sanity;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry;

type
  TSanityTest = class(TTestCase)
  published
    procedure TestRunnerWorks;
    procedure TestFixturesPresent;
  end;

implementation

procedure TSanityTest.TestRunnerWorks;
begin
  AssertEquals('arithmetic still works', 4, 2 + 2);
end;

procedure TSanityTest.TestFixturesPresent;
var
  Dir: string;
begin
  // Tests are run from the repo root (see Makefile), fixtures live in samples/collections.
  Dir := IncludeTrailingPathDelimiter(GetCurrentDir) + 'samples' + PathDelim + 'collections';
  AssertTrue('fixture directory exists: ' + Dir, DirectoryExists(Dir));
  AssertTrue('v2.1 fixture exists', FileExists(Dir + PathDelim + 'codegen-basic.collection.json'));
end;

initialization
  RegisterTest(TSanityTest);

end.
