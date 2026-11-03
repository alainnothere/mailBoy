unit frmMain;

{ mailBoy main window. Wires LCL widgets to the core units and holds no
  logic of its own beyond that. The collection is read-only: the editor
  widgets may be changed, but changes are never written back to the model
  or to disk. At Send time a temporary TRequest is built from the widgets
  (BuildRequestFromEditor), executed, and freed. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, contnrs, Forms, Controls, Graphics, Dialogs, StdCtrls,
  ExtCtrls, ComCtrls, Grids, Spin, Menus, LCLType,
  mbModel, mbLoader, mbVariables, mbRequestBuilder, mbRunner, mbExecutor,
  mbResponse, mbHook, mbHookHelp, frmEnvEdit;

type

  { TMainForm }

  TMainForm = class(TForm)
    btnOpenCollection: TButton;
    btnOpenEnvironment: TButton;
    btnEnvNew: TButton;
    btnEnvEdit: TButton;
    btnEnvSave: TButton;
    btnHookBrowse: TButton;
    btnHookHelp: TButton;
    btnSend: TButton;
    cbBodyMode: TComboBox;
    cbEnvironment: TComboBox;
    cbMethod: TComboBox;
    dlgOpen: TOpenDialog;
    dlgHook: TOpenDialog;
    dlgSaveEnv: TSaveDialog;
    edHook: TEdit;
    edUrl: TEdit;
    gridBodyFields: TStringGrid;
    gridHeaders: TStringGrid;
    gridParams: TStringGrid;
    gridRespHeaders: TStringGrid;
    lblBodyMode: TLabel;
    lblElapsed: TLabel;
    lblEnvironment: TLabel;
    lblHook: TLabel;
    lblHookSec: TLabel;
    lblSize: TLabel;
    lblStatus: TLabel;
    memoAuth: TMemo;
    memoBody: TMemo;
    memoConsole: TMemo;
    memoCurl: TMemo;
    memoRespBody: TMemo;
    memoScript: TMemo;
    memoWarnings: TMemo;
    miClearAllHooks: TMenuItem;
    miClearHook: TMenuItem;
    miSetHook: TMenuItem;
    pcRequest: TPageControl;
    pcResponse: TPageControl;
    pnlBodyTop: TPanel;
    pnlRequest: TPanel;
    pnlRequestLine: TPanel;
    pnlResponse: TPanel;
    pnlRight: TPanel;
    pnlStatus: TPanel;
    pnlTop: TPanel;
    pmTree: TPopupMenu;
    spinHookTimeout: TSpinEdit;
    splLeft: TSplitter;
    splRight: TSplitter;
    StatusBar: TStatusBar;
    tsAuth: TTabSheet;
    tsBody: TTabSheet;
    tsConsole: TTabSheet;
    tsCurl: TTabSheet;
    tsHeaders: TTabSheet;
    tsParams: TTabSheet;
    tsRespBody: TTabSheet;
    tsRespHeaders: TTabSheet;
    tsScript: TTabSheet;
    tsWarnings: TTabSheet;
    tvCollection: TTreeView;
    procedure btnOpenCollectionClick(Sender: TObject);
    procedure btnOpenEnvironmentClick(Sender: TObject);
    procedure btnHookBrowseClick(Sender: TObject);
    procedure btnHookHelpClick(Sender: TObject);
    procedure btnEnvNewClick(Sender: TObject);
    procedure btnEnvEditClick(Sender: TObject);
    procedure btnEnvSaveClick(Sender: TObject);
    procedure btnSendClick(Sender: TObject);
    procedure cbBodyModeChange(Sender: TObject);
    procedure cbEnvironmentChange(Sender: TObject);
    procedure edHookChange(Sender: TObject);
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure FormDropFiles(Sender: TObject; const FileNames: array of string);
    procedure FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure miClearAllHooksClick(Sender: TObject);
    procedure miClearHookClick(Sender: TObject);
    procedure miSetHookClick(Sender: TObject);
    procedure pmTreePopup(Sender: TObject);
    procedure tvCollectionSelectionChanged(Sender: TObject);
  private
    FCollection: TCollection;        // owned; nil until a file is opened
    FEnvironments: TFPObjectList;    // owned TEnvironment objects
    FSelected: TRequest;             // request behind the editor, or nil
    FTransport: TTransport;
    FTransportPath: string;
    FLoadWarnings: TStringList;      // loader warnings of the current collection
    FHookSource: string;             // where the hook of the last send came from
    procedure LoadCollection(const AFileName: string);
    procedure LoadEnvironment(const AFileName: string);
    procedure AddEnvironment(AEnv: TEnvironment);
    procedure RefreshEnvironmentCaption;
    procedure OpenJsonFile(const AFileName: string);
    procedure RebuildTree;
    procedure AddFolderNodes(AParent: TTreeNode; AFolder: TFolder);
    function NodeCaption(AItem: TCollectionItem): string;
    procedure RefreshNodeCaptions;
    function SelectedItem: TCollectionItem;
    { The hook for ARequest: its own or an ancestor's, else the toolbar field.
      ASource is request, folder "<name>", collection, toolbar, or ''. }
    function ResolveHook(ARequest: TRequest; out ASource: string): string;
    procedure FillEditor(ARequest: TRequest);
    procedure ClearEditor;
    procedure SetEditorEnabled(AEnabled: Boolean);
    procedure FillGrid(AGrid: TStringGrid; AList: TKeyValueList);
    procedure GridToList(AGrid: TStringGrid; AList: TKeyValueList; AFileColumn: Boolean);
    procedure ShowBodyWidgets;
    function SelectedEnvironment: TEnvironment;
    function BuildScope: TVariableScope;
    function TransportName: string;
    procedure RefreshCurlPreview;
    procedure ShowResult(AResult: TExecuteResult);
    procedure ShowConsole(AResult: TExecuteResult);
    procedure AddHookBlock(AHook: THookResult);
    procedure FillScriptChain(ARequest: TRequest);
    function HookTimeoutSec: Integer;
    procedure ClearResponse;
    procedure SetWarnings(ALoad, ASend: TStrings);
    procedure UpdateStatusBar(const AMessage: string);
    procedure AutoSend(Data: PtrInt);
  public
    { Builds a new TRequest from the current widget contents. The caller frees it.
      The URL base comes from the edit, the query from the Params grid. }
    function BuildRequestFromEditor: TRequest;
  end;

var
  MainForm: TMainForm;

implementation

{$R *.lfm}

const
  CHECKED = '1';
  UNCHECKED = '0';
  // Index = Ord(TBodyMode); must match cbBodyMode.Items in the .lfm.
  BODY_MODE_COUNT = 7;

function MonoFontName: string;
begin
  {$IFDEF WINDOWS}
  Result := 'Consolas';
  {$ELSE}
  Result := 'Monospace';
  {$ENDIF}
end;

function FormatSize(ABytes: Int64): string;
begin
  if ABytes < 1024 then
    Result := IntToStr(ABytes) + ' B'
  else if ABytes < 1024 * 1024 then
    Result := FormatFloat('0.0', ABytes / 1024) + ' KB'
  else
    Result := FormatFloat('0.0', ABytes / (1024 * 1024)) + ' MB';
end;

{ TMainForm }

procedure TMainForm.FormCreate(Sender: TObject);
var
  Mono: string;
begin
  FCollection := nil;
  FSelected := nil;
  FEnvironments := TFPObjectList.Create(True);
  FLoadWarnings := TStringList.Create;

  Mono := MonoFontName;
  memoBody.Font.Name := Mono;
  memoCurl.Font.Name := Mono;
  memoRespBody.Font.Name := Mono;
  memoAuth.Font.Name := Mono;
  memoScript.Font.Name := Mono;
  memoConsole.Font.Name := Mono;

  cbEnvironment.Items.Clear;
  cbEnvironment.Items.Add('(none)');
  cbEnvironment.ItemIndex := 0;

  FTransport := DetectTransport(FTransportPath);
  ClearEditor;
  ClearResponse;
  UpdateStatusBar('');

  // mailBoy <file.json> opens the GUI with that file loaded.
  if (ParamCount >= 1) and (LowerCase(ExtractFileExt(ParamStr(1))) = '.json') then
    OpenJsonFile(ParamStr(1));

  // Test aid, harmless in normal use: MAILBOY_AUTOSEND=<request name> selects
  // that request after loading and clicks Send once the form is up. It lets a
  // headless screenshot test exercise the send path without a window manager.
  // MAILBOY_HOOK=<path> prefills the hook field for the same purpose.
  if GetEnvironmentVariable('MAILBOY_AUTOSEND') <> '' then
  begin
    edHook.Text := GetEnvironmentVariable('MAILBOY_HOOK');
    Application.QueueAsyncCall(@AutoSend, 0);
  end;
end;

procedure TMainForm.FormDestroy(Sender: TObject);
begin
  tvCollection.Items.Clear;
  FSelected := nil;
  FreeAndNil(FCollection);
  FreeAndNil(FEnvironments);
  FreeAndNil(FLoadWarnings);
end;

procedure TMainForm.FormDropFiles(Sender: TObject; const FileNames: array of string);
var
  I: Integer;
begin
  for I := Low(FileNames) to High(FileNames) do
    OpenJsonFile(FileNames[I]);
end;

procedure TMainForm.FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if ((Key = VK_RETURN) and (ssCtrl in Shift)) or (Key = VK_F5) then
  begin
    Key := 0;
    if btnSend.Enabled then
      btnSendClick(btnSend);
  end
  else if (Key = Ord('O')) and (ssCtrl in Shift) then
  begin
    Key := 0;
    btnOpenCollectionClick(btnOpenCollection);
  end;
end;

procedure TMainForm.btnOpenCollectionClick(Sender: TObject);
begin
  dlgOpen.Title := 'Open collection';
  if dlgOpen.Execute then
    LoadCollection(dlgOpen.FileName);
end;

procedure TMainForm.btnOpenEnvironmentClick(Sender: TObject);
begin
  dlgOpen.Title := 'Open environment';
  if dlgOpen.Execute then
    LoadEnvironment(dlgOpen.FileName);
end;

// The toolbar hook is the fallback; the Script tab shows what will run.
procedure TMainForm.edHookChange(Sender: TObject);
begin
  if FSelected <> nil then
    FillScriptChain(FSelected);
end;

procedure TMainForm.btnHookBrowseClick(Sender: TObject);
begin
  if Trim(edHook.Text) <> '' then
    dlgHook.InitialDir := ExtractFileDir(Trim(edHook.Text));
  if dlgHook.Execute then
    edHook.Text := dlgHook.FileName;
end;

function TMainForm.HookTimeoutSec: Integer;
begin
  Result := spinHookTimeout.Value;
  if Result <= 0 then
    Result := 30;
end;

procedure TMainForm.cbEnvironmentChange(Sender: TObject);
begin
  RefreshCurlPreview;
end;

procedure TMainForm.cbBodyModeChange(Sender: TObject);
begin
  ShowBodyWidgets;
end;

procedure TMainForm.tvCollectionSelectionChanged(Sender: TObject);
var
  Node: TTreeNode;
begin
  Node := tvCollection.Selected;
  if (Node <> nil) and (Node.Data <> nil) and
     not TCollectionItem(Node.Data).IsFolder then
    FillEditor(TRequest(Node.Data))
  else
    ClearEditor;
end;

{ Loading }

procedure TMainForm.OpenJsonFile(const AFileName: string);
var
  JsonText: string;
  FS: TFileStream;
begin
  JsonText := '';
  try
    FS := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyWrite);
    try
      SetLength(JsonText, FS.Size);
      if FS.Size > 0 then
        FS.ReadBuffer(JsonText[1], FS.Size);
    finally
      FS.Free;
    end;
  except
    on E: Exception do
    begin
      MessageDlg('mailBoy', 'Cannot read ' + AFileName + LineEnding + E.Message,
        mtError, [mbOK], 0);
      Exit;
    end;
  end;
  if IsEnvironmentJson(JsonText) then
    LoadEnvironment(AFileName)
  else
    LoadCollection(AFileName);
end;

procedure TMainForm.LoadCollection(const AFileName: string);
var
  NewCollection: TCollection;
  Warnings: TStringList;
begin
  Warnings := TStringList.Create;
  try
    try
      NewCollection := LoadCollectionFromFile(AFileName, Warnings);
    except
      on E: EMailBoyLoad do
      begin
        MessageDlg('mailBoy', 'Cannot load collection' + LineEnding + AFileName +
          LineEnding + LineEnding + E.Message, mtError, [mbOK], 0);
        Exit;
      end;
    end;
    // Only now is the old collection replaced: a bad file keeps the old one.
    ClearEditor;
    tvCollection.Items.Clear;
    FreeAndNil(FCollection);
    FCollection := NewCollection;
    FLoadWarnings.Assign(Warnings);
    RebuildTree;
    SetWarnings(FLoadWarnings, nil);
    UpdateStatusBar('');
  finally
    Warnings.Free;
  end;
end;

procedure TMainForm.LoadEnvironment(const AFileName: string);
var
  Env: TEnvironment;
begin
  try
    Env := LoadEnvironmentFromFile(AFileName);
  except
    on E: EMailBoyLoad do
    begin
      MessageDlg('mailBoy', 'Cannot load environment' + LineEnding + AFileName +
        LineEnding + LineEnding + E.Message, mtError, [mbOK], 0);
      Exit;
    end;
  end;
  if Env.Name = '' then
    Env.Name := ExtractFileName(AFileName);
  AddEnvironment(Env);
end;

// Takes ownership of AEnv, lists it and selects it.
procedure TMainForm.AddEnvironment(AEnv: TEnvironment);
begin
  FEnvironments.Add(AEnv);
  cbEnvironment.Items.Add(AEnv.Name);
  cbEnvironment.ItemIndex := cbEnvironment.Items.Count - 1;
  cbEnvironmentChange(nil);
end;

procedure TMainForm.RefreshEnvironmentCaption;
var
  Env: TEnvironment;
begin
  Env := SelectedEnvironment;
  if Env = nil then
    Exit;
  if Env.Name = '' then
    Env.Name := 'environment';
  cbEnvironment.Items[cbEnvironment.ItemIndex] := Env.Name;
end;

{ Environment editing. Everything stays in memory until Save…, which writes
  the one file mailBoy ever writes, and only where the user points it. }

procedure TMainForm.btnEnvNewClick(Sender: TObject);
var
  Env: TEnvironment;
begin
  if FCollection = nil then
  begin
    MessageDlg('mailBoy', 'Open a collection first: the new environment gets one row ' +
      'per variable the collection uses.', mtInformation, [mbOK], 0);
    Exit;
  end;
  Env := NewEnvironmentFromCollection(FCollection);
  if Env.Variables.Count = 0 then
    Env.Variables.Add('', '');
  if not TEnvEditForm.Edit(Self, Env) then
  begin
    Env.Free;
    Exit;
  end;
  AddEnvironment(Env);
  UpdateStatusBar('New environment "' + Env.Name + '" (in memory, use Save… to keep it)');
end;

procedure TMainForm.btnEnvEditClick(Sender: TObject);
var
  Env: TEnvironment;
begin
  Env := SelectedEnvironment;
  if Env = nil then
  begin
    MessageDlg('mailBoy', 'Pick an environment first, or press New….', mtInformation, [mbOK], 0);
    Exit;
  end;
  if TEnvEditForm.Edit(Self, Env) then
  begin
    RefreshEnvironmentCaption;
    cbEnvironmentChange(nil);
    UpdateStatusBar('Environment "' + Env.Name + '" edited (in memory, use Save… to keep it)');
  end;
end;

procedure TMainForm.btnEnvSaveClick(Sender: TObject);
var
  Env: TEnvironment;
  EnvName: string;
begin
  Env := SelectedEnvironment;
  if Env = nil then
  begin
    MessageDlg('mailBoy', 'Pick an environment first, or press New….', mtInformation, [mbOK], 0);
    Exit;
  end;
  if Env.SourceFile <> '' then
  begin
    dlgSaveEnv.InitialDir := ExtractFileDir(Env.SourceFile);
    dlgSaveEnv.FileName := Env.SourceFile;
  end
  else
  begin
    if FCollection <> nil then
      dlgSaveEnv.InitialDir := ExtractFileDir(FCollection.SourceFile);
    EnvName := Trim(Env.Name);
    if EnvName = '' then
      EnvName := 'environment';
    dlgSaveEnv.FileName := EnvName + '.environment.json';
  end;
  if not dlgSaveEnv.Execute then
    Exit;
  try
    SaveEnvironmentToFile(Env, dlgSaveEnv.FileName);
  except
    on E: EMailBoyLoad do
    begin
      MessageDlg('mailBoy', E.Message, mtError, [mbOK], 0);
      Exit;
    end;
  end;
  UpdateStatusBar('Saved ' + dlgSaveEnv.FileName);
end;

// The hook contract, baked into the binary as mbHookHelp.HookHelpText.
procedure TMainForm.btnHookHelpClick(Sender: TObject);
var
  F: TForm;
  M: TMemo;
begin
  F := TForm.Create(Self);
  try
    F.Caption := 'The hook';
    F.Width := 860;
    F.Height := 640;
    F.Position := poOwnerFormCenter;
    M := TMemo.Create(F);
    M.Parent := F;
    M.Align := alClient;
    M.ReadOnly := True;
    M.ScrollBars := ssAutoBoth;
    M.WordWrap := False;
    M.Font.Name := 'Monospace';
    M.Text := HookHelpText;
    M.SelStart := 0;
    F.ShowModal;
  finally
    F.Free;
  end;
end;

function TMainForm.SelectedEnvironment: TEnvironment;
var
  I: Integer;
begin
  // Item 0 is '(none)'; environments follow in the order they were loaded.
  I := cbEnvironment.ItemIndex - 1;
  if (I >= 0) and (I < FEnvironments.Count) then
    Result := TEnvironment(FEnvironments[I])
  else
    Result := nil;
end;

{ Tree }

procedure TMainForm.RebuildTree;
var
  Root: TTreeNode;
begin
  tvCollection.BeginUpdate;
  try
    tvCollection.Items.Clear;
    if FCollection = nil then
      Exit;
    Root := tvCollection.Items.Add(nil, FCollection.Name);
    Root.Data := FCollection;
    AddFolderNodes(Root, FCollection);
    Root.Expand(False);
  finally
    tvCollection.EndUpdate;
  end;
end;

procedure TMainForm.AddFolderNodes(AParent: TTreeNode; AFolder: TFolder);
var
  I: Integer;
  Item: TCollectionItem;
  Node: TTreeNode;
begin
  for I := 0 to AFolder.Count - 1 do
  begin
    Item := AFolder[I];
    Node := tvCollection.Items.AddChild(AParent, NodeCaption(Item));
    Node.Data := Item;
    if Item.IsFolder then
      AddFolderNodes(Node, TFolder(Item));
  end;
end;

// " [s]" marks requests that carry scripts to migrate into a hook,
// " [h]" marks any node that has a hook of its own attached in this session.
function TMainForm.NodeCaption(AItem: TCollectionItem): string;
begin
  if AItem.Parent = nil then
    Result := AItem.Name
  else if AItem.IsFolder then
    Result := AItem.Name
  else
  begin
    Result := TRequest(AItem).Method + '  ' + AItem.Name;
    if AItem.HasScripts then
      Result := Result + ' [s]';
  end;
  if AItem.HookCommand <> '' then
    Result := Result + ' [h]';
end;

procedure TMainForm.RefreshNodeCaptions;
var
  Node: TTreeNode;
begin
  tvCollection.BeginUpdate;
  try
    Node := tvCollection.Items.GetFirstNode;
    while Node <> nil do
    begin
      if Node.Data <> nil then
        Node.Text := NodeCaption(TCollectionItem(Node.Data));
      Node := Node.GetNext;
    end;
  finally
    tvCollection.EndUpdate;
  end;
end;

function TMainForm.SelectedItem: TCollectionItem;
begin
  if (tvCollection.Selected <> nil) and (tvCollection.Selected.Data <> nil) then
    Result := TCollectionItem(tvCollection.Selected.Data)
  else
    Result := nil;
end;

function TMainForm.ResolveHook(ARequest: TRequest; out ASource: string): string;
begin
  Result := '';
  ASource := '';
  if ARequest <> nil then
    Result := ARequest.EffectiveHook(ASource);
  if (Result = '') and (Trim(edHook.Text) <> '') then
  begin
    Result := Trim(edHook.Text);
    ASource := 'toolbar';
  end;
end;

{ Per-node hooks. Stored on the model objects for the session only; a
  collection file can never set them (see mbModel.TCollectionItem.HookCommand). }

procedure TMainForm.pmTreePopup(Sender: TObject);
var
  Item: TCollectionItem;
begin
  Item := SelectedItem;
  miSetHook.Enabled := Item <> nil;
  miClearHook.Enabled := (Item <> nil) and (Item.HookCommand <> '');
  miClearAllHooks.Enabled := FCollection <> nil;
end;

procedure TMainForm.miSetHookClick(Sender: TObject);
var
  Item: TCollectionItem;
begin
  Item := SelectedItem;
  if Item = nil then
    Exit;
  if Item.HookCommand <> '' then
    dlgHook.InitialDir := ExtractFileDir(Item.HookCommand)
  else if Trim(edHook.Text) <> '' then
    dlgHook.InitialDir := ExtractFileDir(Trim(edHook.Text));
  if not dlgHook.Execute then
    Exit;
  Item.HookCommand := dlgHook.FileName;
  RefreshNodeCaptions;
  if FSelected <> nil then
    FillScriptChain(FSelected);
end;

procedure TMainForm.miClearHookClick(Sender: TObject);
var
  Item: TCollectionItem;
begin
  Item := SelectedItem;
  if Item = nil then
    Exit;
  Item.HookCommand := '';
  RefreshNodeCaptions;
  if FSelected <> nil then
    FillScriptChain(FSelected);
end;

procedure TMainForm.miClearAllHooksClick(Sender: TObject);

  procedure ClearBelow(AFolder: TFolder);
  var
    I: Integer;
  begin
    AFolder.HookCommand := '';
    for I := 0 to AFolder.Count - 1 do
      if AFolder[I].IsFolder then
        ClearBelow(TFolder(AFolder[I]))
      else
        AFolder[I].HookCommand := '';
  end;

begin
  if FCollection = nil then
    Exit;
  ClearBelow(FCollection);
  RefreshNodeCaptions;
  if FSelected <> nil then
    FillScriptChain(FSelected);
end;

{ Editor }

procedure TMainForm.FillGrid(AGrid: TStringGrid; AList: TKeyValueList);
var
  I, Row: Integer;
  KV: TKeyValue;
  FileCol: Boolean;
begin
  FileCol := AGrid.Columns.Count > 3;
  AGrid.BeginUpdate;
  try
    // One blank row at the end so the user can add an entry.
    AGrid.RowCount := AGrid.FixedRows + AList.Count + 1;
    for I := 0 to AList.Count - 1 do
    begin
      KV := AList[I];
      Row := AGrid.FixedRows + I;
      if KV.Enabled then
        AGrid.Cells[0, Row] := CHECKED
      else
        AGrid.Cells[0, Row] := UNCHECKED;
      AGrid.Cells[1, Row] := KV.Key;
      AGrid.Cells[2, Row] := KV.Value;
      if FileCol then
      begin
        if KV.IsFile then
          AGrid.Cells[3, Row] := CHECKED
        else
          AGrid.Cells[3, Row] := UNCHECKED;
      end;
    end;
    Row := AGrid.RowCount - 1;
    AGrid.Cells[0, Row] := CHECKED;
    AGrid.Cells[1, Row] := '';
    AGrid.Cells[2, Row] := '';
    if FileCol then
      AGrid.Cells[3, Row] := UNCHECKED;
  finally
    AGrid.EndUpdate;
  end;
end;

procedure TMainForm.GridToList(AGrid: TStringGrid; AList: TKeyValueList;
  AFileColumn: Boolean);
var
  Row: Integer;
  KV: TKeyValue;
begin
  AList.Clear;
  for Row := AGrid.FixedRows to AGrid.RowCount - 1 do
  begin
    if Trim(AGrid.Cells[1, Row]) = '' then
      Continue;
    KV := AList.Add(AGrid.Cells[1, Row], AGrid.Cells[2, Row]);
    KV.Enabled := AGrid.Cells[0, Row] = CHECKED;
    if AFileColumn and (AGrid.Columns.Count > 3) then
      KV.IsFile := AGrid.Cells[3, Row] = CHECKED;
  end;
end;

procedure TMainForm.ShowBodyWidgets;
var
  Mode: TBodyMode;
begin
  if (cbBodyMode.ItemIndex >= 0) and (cbBodyMode.ItemIndex < BODY_MODE_COUNT) then
    Mode := TBodyMode(cbBodyMode.ItemIndex)
  else
    Mode := bmNone;
  gridBodyFields.Visible := Mode in [bmUrlEncoded, bmFormData];
  memoBody.Visible := not gridBodyFields.Visible;
  gridBodyFields.Columns[3].Visible := Mode = bmFormData;
end;

procedure TMainForm.FillEditor(ARequest: TRequest);
var
  Auth: TAuth;
  I: Integer;
begin
  FSelected := ARequest;
  SetEditorEnabled(True);

  cbMethod.Text := ARequest.Method;
  edUrl.Text := ARequest.Url.Raw;
  FillGrid(gridParams, ARequest.Url.Query);
  FillGrid(gridHeaders, ARequest.Headers);

  cbBodyMode.ItemIndex := Ord(ARequest.Body.Mode);
  FillGrid(gridBodyFields, ARequest.Body.Params);
  case ARequest.Body.Mode of
    bmFile: memoBody.Text := ARequest.Body.FilePath;
    bmNone: memoBody.Text := '';
  else
    memoBody.Text := ARequest.Body.Raw;
  end;
  ShowBodyWidgets;

  Auth := ARequest.EffectiveAuth;
  memoAuth.Lines.BeginUpdate;
  try
    memoAuth.Lines.Clear;
    case Auth.AuthType of
      atInherit, atNone:
        memoAuth.Lines.Add('No auth');
      atBasic, atBearer:
      begin
        memoAuth.Lines.Add('Type: ' + AuthTypeToString(Auth.AuthType));
        for I := 0 to Auth.Params.Count - 1 do
          memoAuth.Lines.Add(Auth.Params[I].Key + ' = ' + Auth.Params[I].Value);
      end;
    else
      memoAuth.Lines.Add(Auth.RawType +
        ' is not supported in this version, the request is sent without it');
    end;
    if Auth <> ARequest.Auth then
      memoAuth.Lines.Add('(inherited from a parent folder or the collection)');
  finally
    memoAuth.Lines.EndUpdate;
  end;

  FillScriptChain(ARequest);
  RefreshCurlPreview;
end;

procedure TMainForm.FillScriptChain(ARequest: TRequest);
var
  Chain: TFPList;
  Item: TCollectionItem;
  I, Count: Integer;
  HookCmd, HookSrc: string;

  function SourceName(AItem: TCollectionItem): string;
  begin
    if AItem.Parent = nil then
      Result := 'collection'
    else if AItem.IsFolder then
      Result := 'folder ' + AItem.Name
    else
      Result := 'request ' + AItem.Name;
  end;

begin
  memoScript.Lines.BeginUpdate;
  try
    memoScript.Lines.Clear;
    HookCmd := ResolveHook(ARequest, HookSrc);
    if HookCmd = '' then
      memoScript.Lines.Add('// hook: none')
    else
      memoScript.Lines.Add('// hook: ' + HookCmd + ' (from ' + HookSrc + ')');
    memoScript.Lines.Add('');
    Count := 0;
    Chain := TFPList.Create;
    try
      // Collection first, then folders from the top down, then the request.
      Item := ARequest;
      while Item <> nil do
      begin
        Chain.Insert(0, Item);
        Item := Item.Parent;
      end;
      for I := 0 to Chain.Count - 1 do
      begin
        Item := TCollectionItem(Chain[I]);
        if Item.PreRequestScript = '' then
          Continue;
        if Count > 0 then
          memoScript.Lines.Add('');
        memoScript.Lines.Add('// pre-request: ' + SourceName(Item));
        memoScript.Lines.Add(Item.PreRequestScript);
        Inc(Count);
      end;
      for I := 0 to Chain.Count - 1 do
      begin
        Item := TCollectionItem(Chain[I]);
        if Item.TestScript = '' then
          Continue;
        if Count > 0 then
          memoScript.Lines.Add('');
        memoScript.Lines.Add('// test: ' + SourceName(Item));
        memoScript.Lines.Add(Item.TestScript);
        Inc(Count);
      end;
    finally
      Chain.Free;
    end;
    if Count = 0 then
      memoScript.Lines.Add('(no scripts on this request)');
  finally
    memoScript.Lines.EndUpdate;
  end;
end;

procedure TMainForm.ClearEditor;
begin
  FSelected := nil;
  cbMethod.Text := '';
  edUrl.Text := '';
  gridParams.RowCount := gridParams.FixedRows;
  gridHeaders.RowCount := gridHeaders.FixedRows;
  gridBodyFields.RowCount := gridBodyFields.FixedRows;
  cbBodyMode.ItemIndex := 0;
  memoBody.Text := '';
  memoAuth.Text := '';
  memoCurl.Text := '';
  memoScript.Text := '';
  ShowBodyWidgets;
  SetEditorEnabled(False);
end;

procedure TMainForm.SetEditorEnabled(AEnabled: Boolean);
begin
  cbMethod.Enabled := AEnabled;
  edUrl.Enabled := AEnabled;
  btnSend.Enabled := AEnabled;
  pcRequest.Enabled := AEnabled;
end;

function TMainForm.BuildRequestFromEditor: TRequest;
var
  Src: TAuth;
  KV: TKeyValue;
  I: Integer;
  Mode: TBodyMode;
begin
  Result := TRequest.Create;
  if FSelected <> nil then
  begin
    Result.Name := FSelected.Name;
    Result.Description := FSelected.Description;
  end;
  Result.Method := UpperCase(Trim(cbMethod.Text));
  if Result.Method = '' then
    Result.Method := 'GET';
  Result.Url.Raw := Trim(edUrl.Text);
  GridToList(gridParams, Result.Url.Query, False);
  GridToList(gridHeaders, Result.Headers, False);

  if (cbBodyMode.ItemIndex >= 0) and (cbBodyMode.ItemIndex < BODY_MODE_COUNT) then
    Mode := TBodyMode(cbBodyMode.ItemIndex)
  else
    Mode := bmNone;
  Result.Body.Mode := Mode;
  Result.Body.RawMode := BodyModeToString(Mode);
  case Mode of
    bmRaw, bmGraphQL:
    begin
      Result.Body.Raw := memoBody.Text;
      if FSelected <> nil then
        Result.Body.Language := FSelected.Body.Language;
    end;
    bmUrlEncoded:
      GridToList(gridBodyFields, Result.Body.Params, False);
    bmFormData:
      GridToList(gridBodyFields, Result.Body.Params, True);
    bmFile:
      Result.Body.FilePath := Trim(memoBody.Text);
  end;

  // Auth is not editable in v1: copy the effective auth of the selected request.
  if FSelected <> nil then
  begin
    Src := FSelected.EffectiveAuth;
    Result.Auth.AuthType := Src.AuthType;
    Result.Auth.RawType := Src.RawType;
    for I := 0 to Src.Params.Count - 1 do
    begin
      KV := Result.Auth.Params.Add(Src.Params[I].Key, Src.Params[I].Value);
      KV.Enabled := Src.Params[I].Enabled;
      KV.Description := Src.Params[I].Description;
    end;
  end;
end;

function TMainForm.BuildScope: TVariableScope;
var
  Env: TEnvironment;
begin
  Result := TVariableScope.Create;
  if FCollection <> nil then
    Result.PushLayer('collection', FCollection.Variables);
  Env := SelectedEnvironment;
  if Env <> nil then
    Result.PushLayer('environment', Env.Variables);
end;

function TMainForm.TransportName: string;
begin
  if FTransport = trWget then
    Result := 'wget'
  else
    Result := 'curl';
end;

procedure TMainForm.RefreshCurlPreview;
var
  Req: TRequest;
  Scope: TVariableScope;
  Resolved: TResolvedRequest;
  Args: TStringList;
begin
  if FSelected = nil then
  begin
    memoCurl.Text := '';
    Exit;
  end;
  Req := BuildRequestFromEditor;
  Scope := BuildScope;
  try
    Resolved := ResolveRequest(Req, Scope);
    try
      if FTransport = trWget then
        Args := BuildWgetArgs(Resolved, DefaultBuildOptions)
      else
        Args := BuildCurlArgs(Resolved, DefaultBuildOptions);
      try
        memoCurl.Text := TransportName + ' ' + ArgsToDisplayString(Args);
      finally
        Args.Free;
      end;
    finally
      Resolved.Free;
    end;
  finally
    Scope.Free;
    Req.Free;
  end;
end;

{ Send }

procedure TMainForm.btnSendClick(Sender: TObject);
var
  Req: TRequest;
  Scope: TVariableScope;
  Executor: TRequestExecutor;
  Res: TExecuteResult;
begin
  if FSelected = nil then
    Exit;
  btnSend.Enabled := False;
  UpdateStatusBar('Sending…');
  lblStatus.Caption := 'Sending…';
  lblStatus.Font.Color := clGray;
  // Synchronous on purpose (v1): one repaint so the user sees the state change.
  Application.ProcessMessages;
  memoConsole.Text := '';
  tsConsole.Caption := 'Console';
  Req := BuildRequestFromEditor;
  Scope := BuildScope;
  Executor := TRequestExecutor.Create;
  try
    Executor.Options := DefaultExecuteOptions;
    Executor.Hook.Command := ResolveHook(FSelected, FHookSource);
    Executor.Hook.TimeoutSec := HookTimeoutSec;
    if FCollection <> nil then
      Executor.Context.CollectionFile := FCollection.SourceFile
    else
      Executor.Context.CollectionFile := '';
    if SelectedEnvironment <> nil then
      Executor.Context.EnvironmentFile := SelectedEnvironment.SourceFile
    else
      Executor.Context.EnvironmentFile := '';
    Executor.Context.Proxy := '';   // the executor fills it per request
    Res := Executor.Execute(Req, Scope);
    try
      ShowResult(Res);
    finally
      Res.Free;
    end;
  finally
    Executor.Free;
    Scope.Free;
    Req.Free;
    UpdateStatusBar('');
    btnSend.Enabled := FSelected <> nil;
  end;
end;

procedure TMainForm.ClearResponse;
begin
  lblStatus.Caption := 'No response yet';
  lblStatus.Font.Color := clGray;
  lblElapsed.Caption := '';
  lblSize.Caption := '';
  memoRespBody.Text := '';
  gridRespHeaders.RowCount := gridRespHeaders.FixedRows;
  memoConsole.Text := '';
  tsConsole.Caption := 'Console';
  SetWarnings(FLoadWarnings, nil);
end;

procedure TMainForm.ShowResult(AResult: TExecuteResult);
var
  Resp: TResponse;
  I, Row: Integer;
  Code: Integer;
begin
  if AResult.Args <> nil then
    memoCurl.Text := TransportName + ' ' + ArgsToDisplayString(AResult.Args);

  if AResult.Outcome = eoOk then
  begin
    Resp := AResult.Response;
    Code := Resp.StatusCode;
    lblStatus.Caption := IntToStr(Code) + ' ' + Resp.StatusText;
    if (Code >= 200) and (Code < 300) then
      lblStatus.Font.Color := clGreen
    else if (Code >= 300) and (Code < 400) then
      lblStatus.Font.Color := TColor($0080FF)   // orange: BGR
    else if Code >= 400 then
      lblStatus.Font.Color := clRed
    else
      lblStatus.Font.Color := clGray;
    if AResult.HookMs > 0 then
      lblElapsed.Caption := 'hook ' + IntToStr(AResult.HookMs) + ' ms · ' +
        IntToStr(Resp.ElapsedMs) + ' ms'
    else
      lblElapsed.Caption := IntToStr(Resp.ElapsedMs) + ' ms';
    lblSize.Caption := FormatSize(Length(Resp.Body));
    memoRespBody.Text := Resp.Body;
    gridRespHeaders.BeginUpdate;
    try
      gridRespHeaders.RowCount := gridRespHeaders.FixedRows + Resp.Headers.Count;
      for I := 0 to Resp.Headers.Count - 1 do
      begin
        Row := gridRespHeaders.FixedRows + I;
        gridRespHeaders.Cells[0, Row] := Resp.Headers.Names[I];
        gridRespHeaders.Cells[1, Row] := Resp.Headers.ValueFromIndex[I];
      end;
    finally
      gridRespHeaders.EndUpdate;
    end;
  end
  else
  begin
    if AResult.Outcome = eoHookError then
      lblStatus.Caption := 'hook error'
    else if AResult.Outcome = eoUnresolvedUrl then
      lblStatus.Caption := 'URL not resolved'
    else
      lblStatus.Caption := OutcomeToString(AResult.Outcome);
    lblStatus.Font.Color := clRed;
    lblElapsed.Caption := '';
    if AResult.HookMs > 0 then
      lblElapsed.Caption := 'hook ' + IntToStr(AResult.HookMs) + ' ms';
    if (AResult.Process <> nil) then
    begin
      if lblElapsed.Caption <> '' then
        lblElapsed.Caption := lblElapsed.Caption + ' · ';
      lblElapsed.Caption := lblElapsed.Caption + IntToStr(AResult.Process.ElapsedMs) + ' ms';
    end;
    lblSize.Caption := '';
    memoRespBody.Text := AResult.ErrorMessage;
    if AResult.Outcome = eoUnresolvedUrl then
      memoRespBody.Lines.Add('Open an environment that defines it (Open environment…), ' +
        'pick it in the Environment box, or edit the URL.');
    gridRespHeaders.RowCount := gridRespHeaders.FixedRows;
  end;
  SetWarnings(FLoadWarnings, AResult.Warnings);
  ShowConsole(AResult);
  // A failed before hook means nothing was sent: the Console is the response.
  if AResult.Outcome = eoHookError then
    pcResponse.ActivePage := tsConsole;
end;

procedure TMainForm.AddHookBlock(AHook: THookResult);
var
  Lines: TStringList;
  I: Integer;
begin
  if AHook = nil then
    Exit;
  if not AHook.Ran and (AHook.ErrorMessage = '') then
    Exit;
  if AHook.Ran then
    memoConsole.Lines.Add('hook ' + HookPhaseName(AHook.Phase) + ' (from ' + FHookSource + '): ' +
      AHook.Command + '  exit ' + IntToStr(AHook.ExitCode) + '  ' + IntToStr(AHook.ElapsedMs) + ' ms')
  else
    memoConsole.Lines.Add('hook ' + HookPhaseName(AHook.Phase) + ' (from ' + FHookSource + '): ' +
      AHook.Command + '  did not start');
  for I := 0 to AHook.Console.Count - 1 do
    memoConsole.Lines.Add('  ' + AHook.Console[I]);
  for I := 0 to AHook.TestCount - 1 do
  begin
    if AHook.Tests[I].Passed then
      memoConsole.Lines.Add('  PASS ' + AHook.Tests[I].Name)
    else
      memoConsole.Lines.Add('  FAIL ' + AHook.Tests[I].Name + ': ' + AHook.Tests[I].Error);
  end;
  if AHook.Ok then
    Exit;
  Lines := TStringList.Create;
  try
    memoConsole.Lines.Add('  ERROR: ' + AHook.ErrorMessage);
    if AHook.ErrorDetail <> '' then
      memoConsole.Lines.Add('  ' + AHook.ErrorDetail);
    if Trim(AHook.StdErr) <> '' then
    begin
      Lines.Text := AHook.StdErr;
      for I := 0 to Lines.Count - 1 do
        memoConsole.Lines.Add('  ' + Lines[I]);
    end;
    if AHook.StdOutExcerpt <> '' then
    begin
      memoConsole.Lines.Add('  stdout was:');
      Lines.Text := AHook.StdOutExcerpt;
      for I := 0 to Lines.Count - 1 do
        memoConsole.Lines.Add('  ' + Lines[I]);
    end;
  finally
    Lines.Free;
  end;
end;

procedure TMainForm.ShowConsole(AResult: TExecuteResult);
var
  Failed: Boolean;
begin
  memoConsole.Lines.BeginUpdate;
  try
    memoConsole.Lines.Clear;
    AddHookBlock(AResult.HookBefore);
    if AResult.Resolved <> nil then
      memoConsole.Lines.Add('request: ' + AResult.Resolved.Method + ' ' +
        AResult.Resolved.Url + ', ' + IntToStr(AResult.Resolved.Headers.Count) + ' headers');
    AddHookBlock(AResult.HookAfter);
  finally
    memoConsole.Lines.EndUpdate;
  end;
  Failed := AResult.HookFailed or
    ((AResult.HookBefore <> nil) and (AResult.HookBefore.FailedTestCount > 0)) or
    ((AResult.HookAfter <> nil) and (AResult.HookAfter.FailedTestCount > 0));
  if Failed then
    tsConsole.Caption := 'Console (!)'
  else
    tsConsole.Caption := 'Console';
end;

procedure TMainForm.SetWarnings(ALoad, ASend: TStrings);
var
  Count: Integer;
begin
  memoWarnings.Lines.BeginUpdate;
  try
    memoWarnings.Lines.Clear;
    Count := 0;
    if (ALoad <> nil) and (ALoad.Count > 0) then
    begin
      memoWarnings.Lines.Add('-- Collection --');
      memoWarnings.Lines.AddStrings(ALoad);
      Inc(Count, ALoad.Count);
    end;
    if (ASend <> nil) and (ASend.Count > 0) then
    begin
      if Count > 0 then
        memoWarnings.Lines.Add('');
      memoWarnings.Lines.Add('-- Last send --');
      memoWarnings.Lines.AddStrings(ASend);
      Inc(Count, ASend.Count);
    end;
  finally
    memoWarnings.Lines.EndUpdate;
  end;
  if Count > 0 then
    tsWarnings.Caption := 'Warnings (' + IntToStr(Count) + ')'
  else
    tsWarnings.Caption := 'Warnings';
end;

procedure TMainForm.UpdateStatusBar(const AMessage: string);
begin
  if AMessage <> '' then
    StatusBar.Panels[0].Text := AMessage
  else if FCollection <> nil then
    StatusBar.Panels[0].Text := FCollection.SourceFile
  else
    StatusBar.Panels[0].Text := 'No collection loaded';
  if FTransport = trNone then
    StatusBar.Panels[1].Text := 'curl/wget not found'
  else
    StatusBar.Panels[1].Text := FTransportPath;
end;

procedure TMainForm.AutoSend(Data: PtrInt);
var
  Wanted: string;
  Node: TTreeNode;
begin
  Wanted := GetEnvironmentVariable('MAILBOY_AUTOSEND');
  Node := tvCollection.Items.GetFirstNode;
  while Node <> nil do
  begin
    if (Node.Data <> nil) and not TCollectionItem(Node.Data).IsFolder and
       ((TCollectionItem(Node.Data).Name = Wanted) or
        (TCollectionItem(Node.Data).Path = Wanted)) then
    begin
      tvCollection.Selected := Node;
      tvCollectionSelectionChanged(tvCollection);
      if btnSend.Enabled then
        btnSendClick(btnSend);
      Exit;
    end;
    Node := Node.GetNext;
  end;
end;

end.
