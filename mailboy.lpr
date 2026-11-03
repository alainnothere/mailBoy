program mailboy;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  mbCliBoot,  // must stay first: handles --run/--list and exits before the widgetset starts
  Interfaces, // LCL widgetset
  Forms,
  frmMain;

{$R *.res}

begin
  RequireDerivedFormResource := True;
  Application.Scaled := True;
  Application.Title := 'mailBoy';
  Application.Initialize;
  Application.CreateForm(TMainForm, MainForm);
  Application.Run;
end.
