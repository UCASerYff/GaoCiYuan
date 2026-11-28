#define ProductName "搞词元"
#define ProductId "com.gaoseries.GaoCiYuan"
#define AppExe "GaoCiYuan.exe"
#define EdgeRuntimeKey "Software\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}"

[Setup]
AppId={#ProductId}
AppName={#ProductName}
AppVersion={#AppVersion}
AppVerName={#ProductName} V{#AppVersion}
AppPublisher=GaoSeries
AppPublisherURL=https://github.com/UCASerYff/GaoCiYuan
AppMutex=Local\com.gaoseries.GaoCiYuan.desktop
DefaultDirName={localappdata}\Programs\GaoSeries\GaoCiYuan
DefaultGroupName={#ProductName}
DisableProgramGroupPage=yes
UninstallDisplayIcon={app}\{#AppExe}
PrivilegesRequired=lowest
SetupArchitecture=x64
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.19041
CloseApplications=no
SetupIconFile={#AppIcon}
WizardStyle=modern
Compression=lzma2
SolidCompression=yes
OutputDir={#OutputDir}
OutputBaseFilename=GaoCiYuan-Windows-{#AppVersion}-build{#AppBuild}-x64-Setup
VersionInfoVersion={#AppVersion}.{#AppBuild}.0
VersionInfoDescription={#ProductName} Windows x64 安装程序
VersionInfoProductName={#ProductName}

[Languages]
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[InstallDelete]
; Files shipped by previous builds before the WebView2 x64-only packaging.
Type: files; Name: "{app}\_internal\webview\lib\WebBrowserInterop.x64.dll"
Type: files; Name: "{app}\_internal\webview\lib\WebBrowserInterop.x86.dll"
Type: files; Name: "{app}\_internal\webview\lib\pywebview-android.jar"
Type: files; Name: "{app}\_internal\webview\lib\runtimes\win-arm64\native\WebView2Loader.dll"
Type: files; Name: "{app}\_internal\webview\lib\runtimes\win-x86\native\WebView2Loader.dll"
Type: files; Name: "{app}\_internal\clr_loader\ffi\dlls\x86\ClrLoader.dll"
Type: files; Name: "{app}\_internal\webview\platforms\cef.py"
Type: files; Name: "{app}\_internal\webview\platforms\cocoa.py"
Type: files; Name: "{app}\_internal\webview\platforms\gtk.py"
Type: files; Name: "{app}\_internal\webview\platforms\mshtml.py"
Type: files; Name: "{app}\_internal\webview\platforms\qt.py"
Type: files; Name: "{app}\_internal\webview\platforms\android\__init__.py"
Type: files; Name: "{app}\_internal\webview\platforms\android\app.py"
Type: files; Name: "{app}\_internal\webview\platforms\android\base.py"
Type: files; Name: "{app}\_internal\webview\platforms\android\event.py"
Type: files; Name: "{app}\_internal\webview\platforms\android\jclass\__init__.py"
Type: files; Name: "{app}\_internal\webview\platforms\android\jclass\app.py"
Type: files; Name: "{app}\_internal\webview\platforms\android\jclass\content.py"
Type: files; Name: "{app}\_internal\webview\platforms\android\jclass\net.py"
Type: files; Name: "{app}\_internal\webview\platforms\android\jclass\os.py"
Type: files; Name: "{app}\_internal\webview\platforms\android\jclass\view.py"
Type: files; Name: "{app}\_internal\webview\platforms\android\jclass\webkit.py"
Type: files; Name: "{app}\_internal\webview\platforms\android\jinterface\__init__.py"
Type: files; Name: "{app}\_internal\webview\platforms\android\jinterface\pywebview.py"
Type: files; Name: "{app}\_internal\webview\platforms\android\jinterface\view.py"
Type: files; Name: "{app}\_internal\webview\platforms\android\jinterface\webkit.py"

[Files]
Source: "{#StageDir}\GaoCiYuan\{#AppExe}"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#StageDir}\GaoCiYuan\_internal\*"; DestDir: "{app}\_internal"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#StageDir}\GaoCiYuan-cli\GaoCiYuan-cli.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#Bootstrapper}"; DestName: "WebView2Bootstrapper.exe"; Flags: dontcopy

[Icons]
Name: "{autoprograms}\{#ProductName}"; Filename: "{app}\{#AppExe}"; IconFilename: "{app}\{#AppExe}"; IconIndex: 0; AppUserModelID: "{#ProductId}"

[Registry]
Root: HKCU; Subkey: "Software\Classes\gaociyuan"; ValueType: string; ValueData: "URL:GaoCiYuan"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\gaociyuan"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\gaociyuan\DefaultIcon"; ValueType: string; ValueData: "{app}\{#AppExe},0"
Root: HKCU; Subkey: "Software\Classes\gaociyuan\shell\open\command"; ValueType: string; ValueData: """{app}\{#AppExe}"" ""%1"""

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#ProductName}}"; Flags: nowait postinstall skipifsilent

[Code]
function IsInstalledInHive(RootKey: Integer): Boolean;
var
  Version: String;
begin
  Result := RegQueryStringValue(RootKey, '{#EdgeRuntimeKey}', 'pv', Version) and (Version <> '') and (Version <> '0.0.0.0');
end;

function HasWebView2(): Boolean;
begin
  Result := IsInstalledInHive(HKLM32) or IsInstalledInHive(HKCU32) or IsInstalledInHive(HKLM64) or IsInstalledInHive(HKCU64);
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ResultCode: Integer;
begin
  Result := '';
  if HasWebView2() then Exit;
  ExtractTemporaryFile('WebView2Bootstrapper.exe');
  if (not Exec(ExpandConstant('{tmp}\WebView2Bootstrapper.exe'), '/silent /install', '', SW_HIDE, ewWaitUntilTerminated, ResultCode)) or
     (ResultCode <> 0) or (not HasWebView2()) then
  begin
    if ActiveLanguage() = 'chinesesimplified' then
      Result := 'Microsoft Edge WebView2 运行时安装失败。请检查网络，或从 Microsoft 安装运行时后重试。'
    else
      Result := 'Microsoft Edge WebView2 Runtime installation failed. Check your connection or install the runtime from Microsoft and retry.';
  end;
end;
