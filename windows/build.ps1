param(
    [string]$Python = 'python',
    [string]$Iscc = 'ISCC.exe',
    [string]$WebViewBootstrapper,
    [switch]$SkipTests
)

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
$env:PYTHONIOENCODING = 'utf-8'

function Check-Exit([string]$Step) {
    if ($LASTEXITCODE -ne 0) { throw "$Step failed ($LASTEXITCODE)." }
}

$compiler = (Get-Command $Iscc -ErrorAction Stop).Source
$buildDir = Join-Path $PSScriptRoot 'build\release'
$distDir = Join-Path $PSScriptRoot 'dist'
New-Item -ItemType Directory -Force -Path $buildDir,$distDir | Out-Null
if (-not $WebViewBootstrapper) {
    $WebViewBootstrapper = Join-Path $buildDir 'MicrosoftEdgeWebview2Setup.exe'
    if (-not (Test-Path -LiteralPath $WebViewBootstrapper)) {
        Invoke-WebRequest -Uri 'https://go.microsoft.com/fwlink/p/?LinkId=2124703' -OutFile $WebViewBootstrapper
    }
}
$bootstrapper = (Resolve-Path -LiteralPath $WebViewBootstrapper).Path
$signature = Get-AuthenticodeSignature -LiteralPath $bootstrapper
if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(^|, )CN=Microsoft Corporation(,|$)') {
    throw 'The WebView2 bootstrapper does not have the expected Microsoft signature.'
}

& $Python -c 'import sys, struct; assert sys.version_info[:2] == (3, 12) and struct.calcsize("P") == 8 and sys.platform == "win32"'
Check-Exit 'CPython 3.12 x64 check'
if (-not $SkipTests) {
    & $Python -m pytest -q
    Check-Exit 'pytest'
}

$versionLines = & $Python -c 'import sys; sys.path.insert(0, "src"); from gaociyuan.version import MARKETING_VERSION, WINDOWS_BUILD; print(MARKETING_VERSION); print(WINDOWS_BUILD)'
Check-Exit 'Version check'
$version, $build = $versionLines
$resources = Join-Path (Split-Path $PSScriptRoot) 'Resources'
$icon = Join-Path $buildDir 'gaociyuan.ico'
$versionInfo = Join-Path $buildDir 'version.info'
& $Python -X utf8 'package_assets.py' $resources $icon $versionInfo
Check-Exit 'Windows resources'

$stage = Join-Path $buildDir 'stage'
$pyInstallerArgs = @(
    '-m', 'PyInstaller', '--noconfirm', '--clean', '--onedir', '--paths', 'src',
    '--distpath', $stage, '--workpath', (Join-Path $buildDir 'obj'), '--specpath', $buildDir,
    '--icon', $icon, '--version-file', $versionInfo,
    '--add-data', "$(Join-Path $PSScriptRoot 'src\gaociyuan\assets');gaociyuan_assets",
    '--add-data', "$(Join-Path $resources 'GaoCiYuanIcon.png');gaociyuan_brand",
    '--add-data', "$(Join-Path $resources 'Translations.tsv');gaociyuan_brand",
    '--add-data', "$(Join-Path $resources 'ProviderIcons');gaociyuan_brand\ProviderIcons",
    '--add-data', "$(Join-Path $resources 'PanelIcons\claude-native-white-flower.png');gaociyuan_brand\PanelIcons",
    '--collect-all', 'tzdata', '--collect-all', 'webview', '--collect-all', 'pythonnet',
    '--hidden-import', 'pystray._win32'
)
& $Python @pyInstallerArgs --name GaoCiYuan --windowed launch.py
Check-Exit 'Desktop package'
& $Python @pyInstallerArgs --name GaoCiYuan-cli --console launch_cli.py
Check-Exit 'CLI package'

& $compiler "/DAppVersion=$version" "/DAppBuild=$build" "/DStageDir=$stage" "/DOutputDir=$distDir" "/DAppIcon=$icon" "/DBootstrapper=$bootstrapper" 'installer.iss'
Check-Exit 'Installer'
$name = "GaoCiYuan-Windows-$version-build$build-x64-Setup.exe"
$package = Join-Path $distDir $name
$hash = (Get-FileHash -LiteralPath $package -Algorithm SHA256).Hash.ToLowerInvariant()
Set-Content -LiteralPath "$package.sha256" -Value "$hash  $name" -Encoding ascii
Get-Item -LiteralPath $package,"$package.sha256" | Select-Object FullName,Length
