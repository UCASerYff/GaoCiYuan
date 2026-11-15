$ErrorActionPreference = "Stop"
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $true
}
Set-Location $PSScriptRoot

function Assert-LastExit($step) {
    if ($LASTEXITCODE -ne 0) {
        throw "$step failed with exit code $LASTEXITCODE"
    }
}

python -m pip install --disable-pip-version-check -r requirements-dev.txt
Assert-LastExit "pip install"
python -m pytest -q
Assert-LastExit "pytest"

$assetDir = Join-Path $PSScriptRoot "src\gaociyuan\assets"
if (-not (Test-Path (Join-Path $assetDir "index.html"))) {
    throw "UI assets were not found at $assetDir"
}
$assets = "{0};gaociyuan_assets" -f $assetDir

python -m PyInstaller --noconfirm --clean --name GaoCiYuan-cli --console --onefile --paths src --add-data $assets --collect-all tzdata --distpath dist --workpath build/cli --specpath build/cli launch.py
Assert-LastExit "PyInstaller cli"
python -m PyInstaller --noconfirm --clean --name GaoCiYuan --windowed --onefile --paths src --add-data $assets --collect-all tzdata --distpath dist --workpath build/gui --specpath build/gui launch.py
Assert-LastExit "PyInstaller windowed"

$zip = Join-Path $PSScriptRoot "dist\GaoCiYuan-Windows-4.13.zip"
if (Test-Path $zip) { Remove-Item $zip }
Compress-Archive -Path @(
    (Join-Path $PSScriptRoot "dist\GaoCiYuan.exe"),
    (Join-Path $PSScriptRoot "dist\GaoCiYuan-cli.exe")
) -DestinationPath $zip
Get-ChildItem dist | ForEach-Object { Write-Output ("{0}`t{1}" -f $_.Name, $_.Length) }
