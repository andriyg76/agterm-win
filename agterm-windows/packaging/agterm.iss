; agterm-win's per-user installer, compiled by scripts/release.ps1 from a stage.ps1 folder:
;   ISCC /DAppVersion=0.44.0.1 /DStage=... /DOutput=... /DZmxRev=... [/DSign /Sagterm=...] agterm.iss
; Silent install for winget and the Store: /VERYSILENT /SUPPRESSMSGBOXES /NORESTART

#ifndef AppVersion
  #error pass /DAppVersion
#endif

[Setup]
AppId={{33086B3F-821D-4FAF-9EC9-F6490E82190B}
AppName=agterm
AppVersion={#AppVersion}
AppVerName=agterm {#AppVersion}
AppPublisherURL=https://github.com/andriyg76/agterm-win
DefaultDirName={autopf}\agterm
PrivilegesRequired=lowest
DisableDirPage=yes
DisableProgramGroupPage=yes
; ConPTY
MinVersion=10.0.17763
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#Output}
OutputBaseFilename=agterm-win-{#AppVersion}-x64-setup
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
VersionInfoProductName=agterm
VersionInfoVersion={#AppVersion}
VersionInfoProductVersion={#AppVersion}
SetupIconFile=..\Resources\agterm.ico
UninstallDisplayIcon={app}\agterm-win.exe
; windows close for the upgrade; the zmx daemons behind their sessions are not in the filter and keep running
CloseApplications=yes
CloseApplicationsFilter=agterm-win.exe
RestartApplications=no
; agtermctl is on the user PATH, so open shells hear about it
ChangesEnvironment=yes
#ifdef Sign
SignTool=agterm
SignedUninstaller=yes
#endif

[Files]
Source: "{#Stage}\*"; DestDir: "{app}"; Excludes: "\zmx"; Flags: recursesubdirs ignoreversion
; a running daemon holds its zmx.exe open, so a revision's folder is written once and never replaced
Source: "{#Stage}\zmx\{#ZmxRev}\*"; DestDir: "{app}\zmx\{#ZmxRev}"; Flags: onlyifdoesntexist
Source: "{#Stage}\zmx\current"; DestDir: "{app}\zmx"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\agterm"; Filename: "{app}\agterm-win.exe"

[Run]
; downloaded by PrepareToInstall rather than bundled, so the installer carries no Microsoft binary
Filename: "{tmp}\MicrosoftEdgeWebview2Setup.exe"; Parameters: "/silent /install"; Check: NeedsWebView2; \
  StatusMsg: "Installing the WebView2 runtime..."
Filename: "{app}\agterm-win.exe"; Description: "Launch agterm"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
Type: filesandordirs; Name: "{app}\zmx"

[Code]
const
  WebView2Client = 'Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}';

function WebView2Installed(Root: Integer; Key: String): Boolean;
var
  Version: String;
begin
  Result := RegQueryStringValue(Root, Key, 'pv', Version) and (Version <> '') and (Version <> '0.0.0.0');
end;

function NeedsWebView2: Boolean;
begin
  Result := not (WebView2Installed(HKLM, 'SOFTWARE\WOW6432Node\' + WebView2Client)
    or WebView2Installed(HKCU, 'Software\' + WebView2Client));
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  if NeedsWebView2 then
  try
    DownloadTemporaryFile('https://go.microsoft.com/fwlink/p/?LinkId=2124703', 'MicrosoftEdgeWebview2Setup.exe', '', nil);
  except
    Result := 'agterm needs the Microsoft Edge WebView2 runtime, and downloading its installer failed: ' + GetExceptionMessage;
  end;
end;

// {app} goes on the user PATH so agtermctl runs from any shell, not only agterm's own sessions
function PathHas(Path, Dir: String): Boolean;
begin
  Result := Pos(';' + Uppercase(Dir) + ';', ';' + Uppercase(Path) + ';') > 0;
end;

procedure AddToUserPath(Dir: String);
var
  Path: String;
begin
  if not RegQueryStringValue(HKCU, 'Environment', 'Path', Path) then Path := '';
  if PathHas(Path, Dir) then Exit;
  if (Path <> '') and (Path[Length(Path)] <> ';') then Path := Path + ';';
  RegWriteExpandStringValue(HKCU, 'Environment', 'Path', Path + Dir);
end;

procedure RemoveFromUserPath(Dir: String);
var
  Path: String;
begin
  if not RegQueryStringValue(HKCU, 'Environment', 'Path', Path) or not PathHas(Path, Dir) then Exit;
  Path := ';' + Path + ';';
  StringChangeEx(Path, ';' + Dir + ';', ';', True);
  RegWriteExpandStringValue(HKCU, 'Environment', 'Path', Copy(Path, 2, Length(Path) - 2));
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usPostUninstall then RemoveFromUserPath(ExpandConstant('{app}'));
end;

// earlier zmx revisions go once no daemon runs them; a folder a daemon still holds stays for the next upgrade
procedure CurStepChanged(CurStep: TSetupStep);
var
  Found: TFindRec;
  Root: String;
begin
  if CurStep <> ssPostInstall then Exit;
  AddToUserPath(ExpandConstant('{app}'));
  Root := ExpandConstant('{app}\zmx\');
  if FindFirst(Root + '*', Found) then
  try
    repeat
      if (Found.Attributes and FILE_ATTRIBUTE_DIRECTORY <> 0) and (Found.Name <> '.') and (Found.Name <> '..')
        and (Found.Name <> '{#ZmxRev}') then
        DelTree(Root + Found.Name, True, True, True);
    until not FindNext(Found);
  finally
    FindClose(Found);
  end;
end;
