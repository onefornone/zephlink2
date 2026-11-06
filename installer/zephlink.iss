; Inno Setup script: turns the Windows build into one Zephlink-Setup.exe
; The build workflow runs this for you. You do not need Inno Setup yourself.

[Setup]
AppName=Zephlink
AppVersion=0.3.0
AppPublisher=Zephlink
DefaultDirName={autopf}\Zephlink
DefaultGroupName=Zephlink
OutputDir=..\build\installer
OutputBaseFilename=Zephlink-Setup
Compression=lzma
SolidCompression=yes
ArchitecturesInstallIn64BitMode=x64
; Installs for the current user only, so no administrator prompt. If you
; choose "all users" in the first window, the firewall task below also works.
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
CloseApplications=yes
RestartApplications=no
WizardStyle=modern

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Shortcuts:"
Name: "startup"; Description: "Start Zephlink when Windows starts (hidden in the tray)"; GroupDescription: "Background running:"
Name: "firewall"; Description: "Allow Zephlink through Windows Firewall so your phone can find this PC (needs administrator)"; GroupDescription: "Network:"; Check: IsAdminInstallMode

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion

[Icons]
Name: "{group}\Zephlink"; Filename: "{app}\zephlink.exe"
Name: "{autodesktop}\Zephlink"; Filename: "{app}\zephlink.exe"; Tasks: desktopicon
Name: "{userstartup}\Zephlink"; Filename: "{app}\zephlink.exe"; Parameters: "--minimized"; Tasks: startup

[Registry]
Root: HKA; Subkey: "Software\Classes\*\shell\Zephlink.Send"; ValueType: string; ValueName: ""; ValueData: "Send with Zephlink"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\*\shell\Zephlink.Send"; ValueType: string; ValueName: "Icon"; ValueData: """{app}\zephlink.exe"""
Root: HKA; Subkey: "Software\Classes\*\shell\Zephlink.Send\command"; ValueType: string; ValueName: ""; ValueData: """{app}\zephlink.exe"" --send ""%1"""

[Run]
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""Zephlink"""; Flags: runhidden; Tasks: firewall
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall add rule name=""Zephlink"" dir=in action=allow program=""{app}\zephlink.exe"" enable=yes profile=private,public"; Flags: runhidden; Tasks: firewall
Filename: "{app}\zephlink.exe"; Description: "Open Zephlink"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""Zephlink"""; Flags: runhidden; RunOnceId: "ZephlinkFirewall"
