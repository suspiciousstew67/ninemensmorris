; Inno Setup Script for Nine Men's Morris
; This script creates a Windows installer for the Flutter desktop app
; Version is read from pubspec.yaml automatically

#define MyAppName "Nine Men's Morris"
#define MyAppVersion GetEnv("VERSION")
#if MyAppVersion == ""
  #define MyAppVersion "0.1.0"
#endif
#define MyAppPublisher "Nine Men's Morris Team"
#define MyAppExeName "clean_nine_mens_morris_flutter.exe"

#ifndef BuildArch
  #define BuildArch "x64"
#endif

#if BuildArch == "x64"
  #define AllowedArchs "x64 arm64"
#else
  #define AllowedArchs "arm64"
#endif

[Setup]
AppId={{B8F3C4E5-2D9A-4F6B-8C3E-1A5B7D9F0E2C}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
AllowNoIcons=yes
OutputDir=.
OutputBaseFilename=NineMensMorris-Setup-{#BuildArch}
Compression=lzma
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest
ArchitecturesAllowed={#AllowedArchs}
ArchitecturesInstallIn64BitMode={#AllowedArchs}

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "..\build\windows\{#BuildArch}\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\{cm:UninstallProgram,{#MyAppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Flags: nowait postinstall skipifsilent; Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"

[Code]
var
  DownloadPage: TDownloadWizardPage;

function OnDownloadProgress(const Url, FileName: String; const Progress, ProgressMax: Int64): Boolean;
begin
  if ProgressMax <> 0 then
    Log(Format('  %d of %d bytes done.', [Progress, ProgressMax]))
  else
    Log(Format('  %d bytes done.', [Progress]));
  Result := True;
end;

procedure InitializeWizard;
begin
  DownloadPage := CreateDownloadPage(SetupMessage(msgWizardPreparing), SetupMessage(msgPreparingDesc), @OnDownloadProgress);
end;

function VCRedistNeedsInstall: Boolean;
var
  RegKey: String;
  Installed: Cardinal;
begin
  Result := True;
  
  #if BuildArch == "x64"
    RegKey := 'SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64';
  #else
    RegKey := 'SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\arm64';
  #endif

  if RegQueryDWordValue(HKLM, RegKey, 'Installed', Installed) and (Installed = 1) then
  begin
    Result := False;
  end;
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var
  Url: String;
  FileName: String;
  ResultCode: Integer;
begin
  Result := True;

  if (CurPageID = wpReady) and VCRedistNeedsInstall then
  begin
    #if BuildArch == "x64"
      Url := 'https://aka.ms/vs/17/release/vc_redist.x64.exe';
      FileName := 'vc_redist.x64.exe';
    #else
      Url := 'https://aka.ms/vs/17/release/vc_redist.arm64.exe';
      FileName := 'vc_redist.arm64.exe';
    #endif

    DownloadPage.Clear;
    DownloadPage.Add(Url, FileName, '');
    DownloadPage.Show;
    try
      try
        DownloadPage.Download;
        Result := True;
      except
        SuppressibleMsgBox(AddPeriod(GetExceptionMessage), mbCriticalError, MB_OK, IDOK);
        Result := False;
      end;
    finally
      DownloadPage.Hide;
    end;

    if Result then
    begin
      Exec(ExpandConstant('{tmp}\') + FileName, '/install /passive /norestart', '', SW_SHOW, ewWaitUntilTerminated, ResultCode);
    end;
  end;
end;
