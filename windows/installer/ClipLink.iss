; The ClipLink installer (Inno Setup 6). Built by ..\publish.ps1:
;   ISCC.exe /DAppVersion=1.0.0 /DSourceDir=<published app folder> /DOutputDir=<folder> ClipLink.iss
;
; Per-user by default (no administrator prompt, installs under
; %LOCALAPPDATA%\Programs\ClipLink); the setup offers "all users" too.
; Settings, pairings and history live in %APPDATA% / %LOCALAPPDATA% and are
; kept when ClipLink is updated or removed.

#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
#ifndef SourceDir
  #error SourceDir (the published app folder) is required
#endif
#ifndef OutputDir
  #define OutputDir "..\dist"
#endif

[Setup]
; Never change: it's how updates find the installed copy.
AppId={{3F6A9B1C-7D24-4E85-A0C3-5B2E9D7F4A16}
AppName=ClipLink
AppVersion={#AppVersion}
AppPublisher=ClipLink
AppPublisherURL=https://github.com/Colour1205/ClipLink
DefaultDirName={autopf}\ClipLink
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
OutputDir={#OutputDir}
OutputBaseFilename=ClipLink-Setup-{#AppVersion}
SetupIconFile=..\ClipLink.ico
UninstallDisplayIcon={app}\ClipLink.exe
UninstallDisplayName=ClipLink
WizardStyle=modern
Compression=lzma2/ultra64
SolidCompression=yes
; ClipLink lives in the tray and doesn't answer a close request: it is asked
; to quit by hand (--quit, see [Code]).
CloseApplications=no

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\ClipLink"; Filename: "{app}\ClipLink.exe"
Name: "{autodesktop}\ClipLink"; Filename: "{app}\ClipLink.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\ClipLink.exe"; Description: "Start ClipLink"; Flags: nowait postinstall skipifsilent

[UninstallRun]
; Takes "Share to ClipLink" out of File Explorer.
Filename: "{app}\ClipLink.exe"; Parameters: "--unregister"; Flags: runhidden; RunOnceId: "UnregisterShare"

[Code]
// Asks a running ClipLink to quit and gives it a moment to let go of its
// files: they can't be replaced or removed while it runs.
procedure QuitRunningClipLink;
var
  Exe: String;
  ResultCode: Integer;
begin
  Exe := ExpandConstant('{app}\ClipLink.exe');
  if FileExists(Exe) then
  begin
    Exec(Exe, '--quit', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
    Sleep(1500);
  end;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  QuitRunningClipLink;
  Result := '';
end;

// "Start ClipLink when I sign in" (Settings) is a Run entry the app made. It's
// only removed when it starts this installed copy: it may well point at another
// ClipLink.exe (a build run from a folder), which isn't ours to switch off.
procedure RemoveSignInEntry;
var
  Command: String;
begin
  if RegQueryStringValue(HKEY_CURRENT_USER, 'Software\Microsoft\Windows\CurrentVersion\Run', 'ClipLink', Command) then
    if Pos(Lowercase(ExpandConstant('{app}\ClipLink.exe')), Lowercase(Command)) > 0 then
      RegDeleteValue(HKEY_CURRENT_USER, 'Software\Microsoft\Windows\CurrentVersion\Run', 'ClipLink');
end;

procedure CurrentUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
    QuitRunningClipLink;
  if CurUninstallStep = usPostUninstall then
    RemoveSignInEntry;
end;
