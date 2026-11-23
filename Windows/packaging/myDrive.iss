#ifndef PayloadDir
  #error Set PayloadDir to the Windows publish directory.
#endif
#ifndef AppVersion
  #error Set AppVersion to the Windows project version.
#endif

[Setup]
AppId=myDrive.OseanStudio
AppName=myDrive
AppVersion={#AppVersion}
AppPublisher=Osean Studio
DefaultDirName={localappdata}\Programs\myDrive
DefaultGroupName=myDrive
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.19041
OutputBaseFilename=myDrive-Windows-x64-Setup
UninstallDisplayIcon={app}\myDrive.exe
CloseApplications=yes
RestartApplications=no
ChangesAssociations=yes
Compression=lzma2
SolidCompression=yes
WizardStyle=modern

[Files]
Source: "{#PayloadDir}\*"; DestDir: "{app}"; Excludes: "*.pdb"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\myDrive"; Filename: "{app}\myDrive.exe"; WorkingDir: "{app}"

[Registry]
Root: HKCU; Subkey: "Software\Classes\*\shell\myDrive.Send"; ValueType: string; ValueName: "MUIVerb"; ValueData: "Send with myDrive"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\*\shell\myDrive.Send"; ValueType: string; ValueName: "MultiSelectModel"; ValueData: "Single"
Root: HKCU; Subkey: "Software\Classes\*\shell\myDrive.Send\command"; ValueType: string; ValueData: """{app}\myDrive.exe"" --send-files ""%1"""
Root: HKCU; Subkey: "Software\Classes\Directory\shell\myDrive.Send"; ValueType: string; ValueName: "MUIVerb"; ValueData: "Send with myDrive"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Directory\shell\myDrive.Send"; ValueType: string; ValueName: "MultiSelectModel"; ValueData: "Single"
Root: HKCU; Subkey: "Software\Classes\Directory\shell\myDrive.Send\command"; ValueType: string; ValueData: """{app}\myDrive.exe"" --send-files ""%1"""

[Run]
Filename: "{app}\myDrive.exe"; WorkingDir: "{app}"; Description: "Launch myDrive"; Flags: nowait postinstall skipifsilent
