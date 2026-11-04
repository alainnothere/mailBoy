program mailboy_tests;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes, consoletestrunner,
  test_sanity, test_mbModel, test_mbLoader, test_mbResponse, test_mbVariables, test_mbRequestBuilder, test_mbRunner, test_mbExecutor, test_mbCli, test_mbHook, test_mbJsonFmt;

var
  App: TTestRunner;

begin
  App := TTestRunner.Create(nil);
  try
    App.Initialize;
    App.Title := 'mailBoy tests';
    App.Run;
  finally
    App.Free;
  end;
end.
