; Inno Setup script for the Universal Print Windows installer.
; Build: flutter build windows --release, then
;   ISCC.exe /DAppVersion=1.0.0 windows\installer\universal_print.iss
; Output: build\installer\universal_print-setup-<version>-x64.exe

#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif

#define AppName "Universal Print"
#define AppExe "universal_print.exe"
#define Release "..\..\build\windows\x64\runner\Release"

[Setup]
AppId={{6B3E9F2A-4C1D-4E8B-9A57-2F0D8C1E5B73}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=BDSoft
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
; Per-user install by default (no admin needed); admins can choose all users.
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\..\build\installer
OutputBaseFilename=universal_print-setup-{#AppVersion}-x64
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExe}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=force

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "{#Release}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
; The app keeps running in the background after its window is closed.
Filename: "{sys}\taskkill.exe"; Parameters: "/F /IM {#AppExe}"; Flags: runhidden; RunOnceId: "StopApp"

[Registry]
; Start-at-login entry written by the app (desktop_background.dart).
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueName: "UniversalPrint"; Flags: uninsdeletevalue dontcreatekey
