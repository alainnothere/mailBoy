program mailboy_cli;

// Console-subsystem twin of mailboy for scripts and agents. On Linux the
// main binary handles --run itself; on Windows a GUI-subsystem executable
// has no console and the shell does not wait for it, so command-line use
// goes through this one. Same core, same mbCli unit, no LCL.

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  mbCli;

begin
  Halt(RunCliMain);
end.
