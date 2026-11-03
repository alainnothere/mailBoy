unit mbCliBoot;

// Listed FIRST in the program's uses clause, before Interfaces. On Linux the
// GTK widgetset opens the display while the Interfaces unit initialises,
// which happens before the main program body runs, so a headless --run on a
// machine without a display would die there. This unit's initialisation
// runs earlier and ends the process before that can happen.

{$mode objfpc}{$H+}

interface

implementation

uses
  SysUtils, mbCli;

initialization
  if IsCliInvocation then
    Halt(RunCliMain);

end.
