unit frmEnvEdit;

// The environment editor: a name and a grid of On / Key / Value rows.
// Edits land on the TEnvironment object in memory when OK is pressed.
// Nothing here touches a file; "Save as…" on the main form does that.

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, StdCtrls, Grids, mbModel, mbVariables;

type

  { TEnvEditForm }

  TEnvEditForm = class(TForm)
    btnCancel: TButton;
    btnOK: TButton;
    edName: TEdit;
    gridVars: TStringGrid;
    lblName: TLabel;
    lblHint: TLabel;
    procedure btnOKClick(Sender: TObject);
    procedure gridVarsPrepareCanvas(Sender: TObject; aCol, aRow: Integer; aState: TGridDrawState);
  private
    FEnv: TEnvironment;
    procedure FillFrom(AEnv: TEnvironment);
    procedure WriteBack(AEnv: TEnvironment);
  public
    { Opens the editor on AEnv. True if the user pressed OK, in which case
      AEnv now carries the edited name and variables. }
    class function Edit(AOwner: TComponent; AEnv: TEnvironment): Boolean;
  end;

implementation

{$R *.lfm}

uses
  Graphics;

const
  CHECKED = '1';
  UNCHECKED = '0';

class function TEnvEditForm.Edit(AOwner: TComponent; AEnv: TEnvironment): Boolean;
var
  F: TEnvEditForm;
begin
  F := TEnvEditForm.Create(AOwner);
  try
    F.FEnv := AEnv;
    F.FillFrom(AEnv);
    Result := F.ShowModal = mrOK;
  finally
    F.Free;
  end;
end;

procedure TEnvEditForm.FillFrom(AEnv: TEnvironment);
var
  I, Row: Integer;
  KV: TKeyValue;
begin
  edName.Text := AEnv.Name;
  gridVars.BeginUpdate;
  try
    // One blank row at the end so the user can add an entry.
    gridVars.RowCount := gridVars.FixedRows + AEnv.Variables.Count + 1;
    for I := 0 to AEnv.Variables.Count - 1 do
    begin
      KV := AEnv.Variables[I];
      Row := gridVars.FixedRows + I;
      if KV.Enabled then
        gridVars.Cells[0, Row] := CHECKED
      else
        gridVars.Cells[0, Row] := UNCHECKED;
      gridVars.Cells[1, Row] := KV.Key;
      gridVars.Cells[2, Row] := KV.Value;
    end;
    gridVars.Cells[0, gridVars.RowCount - 1] := CHECKED;
  finally
    gridVars.EndUpdate;
  end;
end;

procedure TEnvEditForm.WriteBack(AEnv: TEnvironment);
var
  Row: Integer;
  KV: TKeyValue;
begin
  AEnv.Name := Trim(edName.Text);
  AEnv.Variables.Clear;
  for Row := gridVars.FixedRows to gridVars.RowCount - 1 do
  begin
    if Trim(gridVars.Cells[1, Row]) = '' then
      Continue;
    KV := AEnv.Variables.Add(Trim(gridVars.Cells[1, Row]), gridVars.Cells[2, Row]);
    KV.Enabled := gridVars.Cells[0, Row] <> UNCHECKED;
  end;
end;

procedure TEnvEditForm.btnOKClick(Sender: TObject);
begin
  // Commit a cell still being edited before reading the grid.
  gridVars.EditorMode := False;
  WriteBack(FEnv);
  ModalResult := mrOK;
end;

// A value still holding its "put the X value here" placeholder is shown in
// red: it counts as undefined until the user replaces it.
procedure TEnvEditForm.gridVarsPrepareCanvas(Sender: TObject; aCol, aRow: Integer;
  aState: TGridDrawState);
begin
  if (aCol = 2) and (aRow >= gridVars.FixedRows) and
     IsPlaceholderValue(Trim(gridVars.Cells[1, aRow]), gridVars.Cells[2, aRow]) then
    gridVars.Canvas.Font.Color := clRed;
end;

end.
