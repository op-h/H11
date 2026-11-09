; H11 for Windows: one-file installer.
; Build:  "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" installer\H11.iss
; (after `flutter build windows --release`)

#define AppName "H11"
#define AppVersion "1.0.0"
#define Src "..\build\windows\x64\runner\Release"

[Setup]
AppId={{6B1E2C4A-9F3D-4E21-8C55-1A7B11000001}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=H11
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
DisableDirPage=yes
DisableReadyPage=yes
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir=..\build\installer
OutputBaseFilename=H11-Setup
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\H11.exe
UninstallDisplayName={#AppName}
WizardStyle=modern
Compression=lzma2/ultra64
SolidCompression=yes
CloseApplications=force
RestartApplications=no

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"
Name: "autostart"; Description: "Start H11 with Windows (keeps your phone in sync)"

[Files]
Source: "{#Src}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
; Visual C++ runtime next to the app, so nothing else needs installing.
Source: "{sys}\msvcp140.dll"; DestDir: "{app}"; Flags: external ignoreversion skipifsourcedoesntexist
Source: "{sys}\vcruntime140.dll"; DestDir: "{app}"; Flags: external ignoreversion skipifsourcedoesntexist
Source: "{sys}\vcruntime140_1.dll"; DestDir: "{app}"; Flags: external ignoreversion skipifsourcedoesntexist

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\H11.exe"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\H11.exe"; Tasks: desktopicon

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "H11"; ValueData: """{app}\H11.exe"" --hidden"; Tasks: autostart; Flags: uninsdeletevalue

[Run]
; Let the phone reach the computer on home/private networks only.
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""H11"""; Flags: runhidden waituntilterminated
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall add rule name=""H11"" dir=in action=allow program=""{app}\H11.exe"" profile=private enable=yes"; Flags: runhidden waituntilterminated
Filename: "{app}\H11.exe"; Description: "Open H11 now"; Flags: nowait postinstall skipifsilent runasoriginaluser

[UninstallRun]
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""H11"""; Flags: runhidden; RunOnceId: "fw"

[UninstallDelete]
Type: filesandordirs; Name: "{app}"
