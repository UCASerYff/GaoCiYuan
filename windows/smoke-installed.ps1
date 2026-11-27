[CmdletBinding()]
param(
    [string]$InstallerPath = (Join-Path $PSScriptRoot 'dist\GaoCiYuan-Windows-4.13-build5-x64-Setup.exe'),
    [string]$PreviousInstallerPath,
    [switch]$HeadlessServerOnly,
    [switch]$KeepArtifacts
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$expectedVersion = '4.13+5'
$expectedFileVersion = '4.13.5.0'
$previousVersion = '4.13+4'
$previousFileVersion = '4.13.4.0'
$productName = ConvertFrom-Json '"\u641e\u8bcd\u5143"'
$fileConnection = ConvertFrom-Json '"\u81ea\u52a8\u8bfb\u53d6\u5feb\u7167\u6587\u4ef6"'
$localConnection = ConvertFrom-Json '"\u672c\u673a\u8f6f\u4ef6\u81ea\u52a8\u8bfb\u53d6"'
$protocolKey = 'Software\Classes\gaociyuan'
$uninstallKey = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\com.gaoseries.GaoCiYuan_is1'
$edgeKey = 'Software\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
$registryViews = @([Microsoft.Win32.RegistryView]::Registry64, [Microsoft.Win32.RegistryView]::Registry32)
$currentUser = [Microsoft.Win32.RegistryHive]::CurrentUser
$localMachine = [Microsoft.Win32.RegistryHive]::LocalMachine
$utf8 = [Text.UTF8Encoding]::new($false)

function Assert-Test([bool]$Condition, [string]$Failure) {
    if (-not $Condition) { throw $Failure }
}

function Get-RegistryKey([Microsoft.Win32.RegistryHive]$Hive, [Microsoft.Win32.RegistryView]$View, [string]$Path) {
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($Hive, $View)
    try { return $base.OpenSubKey($Path) }
    finally { $base.Close() }
}

function Test-RegistryKey([Microsoft.Win32.RegistryHive]$Hive, [Microsoft.Win32.RegistryView]$View, [string]$Path) {
    $key = Get-RegistryKey $Hive $View $Path
    if (-not $key) { return $false }
    $key.Close()
    return $true
}

function Get-RegistryValue([Microsoft.Win32.RegistryHive]$Hive, [Microsoft.Win32.RegistryView]$View, [string]$Path, [string]$Value) {
    $key = Get-RegistryKey $Hive $View $Path
    if (-not $key) { return $null }
    try { return $key.GetValue($Value) }
    finally { $key.Close() }
}

function Assert-LocalDirectory([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force
    Assert-Test ($item.PSIsContainer -and -not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) "Expected a plain local directory at $Path."
}

function Assert-SafeTree([string]$Path) {
    Assert-LocalDirectory $Path
    foreach ($child in Get-ChildItem -LiteralPath $Path -Force) {
        Assert-Test (-not ($child.Attributes -band [IO.FileAttributes]::ReparsePoint)) "Cleanup stopped at the reparse point $($child.FullName)."
        if ($child.PSIsContainer) { Assert-SafeTree $child.FullName }
    }
}

function Write-Json([string]$Path, $Value) {
    [IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $Value -Depth 15 -Compress), $utf8)
}

function Read-Json([string]$Path) {
    Get-Content -LiteralPath $Path -Encoding UTF8 -Raw | ConvertFrom-Json
}

function Assert-InstalledCliHelp([string]$Executable, [string]$DataDirectory) {
    $start = [Diagnostics.ProcessStartInfo]::new($Executable)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false, $true)
    $start.StandardErrorEncoding = $start.StandardOutputEncoding
    $start.ArgumentList.Add('--data-dir')
    $start.ArgumentList.Add($DataDirectory)
    $process = [Diagnostics.Process]::Start($start)
    try {
        $output = $process.StandardOutput.ReadToEndAsync()
        $errors = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(10000)) {
            $process.Kill()
            throw 'The installed CLI timed out while printing command help.'
        }
        $helpText = $output.GetAwaiter().GetResult()
        $errorText = $errors.GetAwaiter().GetResult()
        $description = ConvertFrom-Json '"\u641e\u8bcd\u5143 Windows \u7248"'
        Assert-Test ($process.ExitCode -eq 0 -and $helpText -match 'usage:' -and $helpText.Contains($description) -and -not $errorText) (
            "The installed CLI did not return UTF-8 command help. Exit code $($process.ExitCode). $errorText"
        )
    } finally {
        $process.Dispose()
    }
}

function Assert-InstalledShortcut([string]$ShortcutFile, [string]$ExpectedTarget) {
    Assert-Test (Test-Path -LiteralPath $ShortcutFile -PathType Leaf) "The Start menu shortcut is missing at '$ShortcutFile'."
    $item = Get-Item -LiteralPath $ShortcutFile
    Write-Verbose "Start menu shortcut '$($item.FullName)' has $($item.Length) bytes."
    if (-not ('GaoCiYuan.Smoke.InstalledShellLink' -as [type])) {
        Add-Type -LiteralPath (Join-Path $PSScriptRoot 'tests\InstalledShellLink.cs')
    }
    Write-Verbose "Windows ANSI code page is $([GaoCiYuan.Smoke.InstalledShellLink]::GetACP())."

    # The Unicode persistence API reads the existing file directly, including its Chinese filename.
    $link = [GaoCiYuan.Smoke.InstalledShellLink]::Read($item.FullName)
    $properties = ConvertTo-Json -InputObject $link -Compress
    Write-Verbose "Read persisted shortcut properties $properties"
    # Only spaces and tabs separate arguments. An explicit empty argument ("") still counts.
    if ($link.Arguments -cnotmatch '\A[ \t]*\z') {
        throw "The Start menu shortcut has unexpected launch arguments. $properties"
    }
    # Every available target representation must resolve to the installed file.
    $targets = @($link.TargetPath, $link.RawTargetPath, $link.ItemTargetPath | Where-Object { $_ })
    $diagnostic = "Expected '$ExpectedTarget'. Persisted properties $properties"
    Assert-Test ($targets.Count -gt 0) "The Start menu shortcut has no file target. $diagnostic"
    $expectedPath = [GaoCiYuan.Smoke.InstalledShellLink]::ResolveFile($ExpectedTarget)
    foreach ($target in $targets) {
        Assert-Test ([IO.Path]::IsPathFullyQualified($target)) "The Start menu shortcut has a non-absolute target. $diagnostic"
        try { $actualPath = [GaoCiYuan.Smoke.InstalledShellLink]::ResolveFile($target) }
        catch { throw "Could not resolve the Start menu shortcut target. $diagnostic $($_.Exception.Message)" }
        Assert-Test ([string]::Equals($actualPath, $expectedPath, [StringComparison]::Ordinal)) (
            "The Start menu shortcut targets a different file. $diagnostic Resolved to '$actualPath' and '$expectedPath'."
        )
    }
}

function Assert-X64Pe([string]$Path) {
    $reader = [IO.BinaryReader]::new([IO.File]::OpenRead($Path))
    try {
        Assert-Test ($reader.ReadUInt16() -eq 0x5A4D) "Missing MZ header in $Path."
        $reader.BaseStream.Position = 0x3C
        $reader.BaseStream.Position = $reader.ReadUInt32()
        Assert-Test ($reader.ReadUInt32() -eq 0x4550) "Missing PE header in $Path."
        Assert-Test ($reader.ReadUInt16() -eq 0x8664) "Expected AMD64 machine metadata in $Path."
    } finally { $reader.Close() }
}

function Confirm-Installer([string]$Path, [string]$FileVersion) {
    $resolved = (Resolve-Path -LiteralPath $Path).ProviderPath
    $hashPath = "$resolved.sha256"
    Assert-Test (Test-Path -LiteralPath $hashPath -PathType Leaf) "The matching SHA-256 file is required for '$resolved'."
    $expectedHash = ((Get-Content -LiteralPath $hashPath -Raw).Trim() -split '\s+')[0]
    Assert-Test ($expectedHash -match '^[0-9A-Fa-f]{64}$' -and
        (Get-FileHash -LiteralPath $resolved -Algorithm SHA256).Hash -eq $expectedHash) "Installer SHA-256 mismatch for '$resolved'."
    Assert-X64Pe $resolved
    Assert-Test ((Get-Item -LiteralPath $resolved).VersionInfo.FileVersion.Trim() -eq $FileVersion) "Expected installer version $FileVersion at '$resolved'."
    return $resolved
}

function Invoke-QuietProcess([string]$Path, [string[]]$Arguments, [int]$TimeoutMs) {
    $process = Start-Process -FilePath $Path -ArgumentList $Arguments -WindowStyle Hidden -PassThru
    try {
        if (-not $process.WaitForExit($TimeoutMs)) {
            $process.Kill()
            throw "$(Split-Path -Leaf $Path) did not exit within $TimeoutMs ms."
        }
        Assert-Test ($process.ExitCode -eq 0) "$(Split-Path -Leaf $Path) exited with code $($process.ExitCode)."
    } finally { $process.Dispose() }
}

function Write-FixtureCredential([string]$Path, [string]$Secret) {
    $bytes = [Security.Cryptography.ProtectedData]::Protect(
        $utf8.GetBytes($Secret), $null, [Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    [IO.File]::WriteAllBytes($Path, $bytes)
}

function Read-FixtureCredential([string]$Path) {
    $bytes = [Security.Cryptography.ProtectedData]::Unprotect(
        [IO.File]::ReadAllBytes($Path), $null, [Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    return $utf8.GetString($bytes)
}

function Invoke-AppApi([string]$Path, [hashtable]$Payload) {
    $options = @{ Uri = $baseURL + $Path; Headers = $sessionHeader; TimeoutSec = 5; NoProxy = $true }
    if ($PSBoundParameters.ContainsKey('Payload')) {
        $options.Method = 'Post'
        $options.ContentType = 'application/json; charset=utf-8'
        $options.Body = $utf8.GetBytes((ConvertTo-Json -InputObject $Payload -Depth 12 -Compress))
    }
    return Invoke-RestMethod @options
}

function Get-RegistrationPath {
    foreach ($view in $registryViews) {
        $registered = Get-RegistryValue $currentUser $view $uninstallKey 'InstallLocation'
        if ($registered) { return [IO.Path]::GetFullPath([string]$registered).TrimEnd('\') }
    }
    return $null
}

function Stop-SmokeApp {
    if (-not $app) { return }
    if (-not $app.HasExited -and $sessionHeader) {
        try { Invoke-AppApi '/api/shutdown' @{} | Out-Null }
        catch { Write-Verbose 'The isolated app shutdown request was unavailable.' }
    }
    if (-not $app.WaitForExit(10000)) {
        foreach ($process in Get-Process -Name 'GaoCiYuan','GaoCiYuan-cli' -ErrorAction SilentlyContinue) {
            if ($process.Path -and [string]::Equals($process.Path, $launchExe, [StringComparison]::OrdinalIgnoreCase)) {
                Stop-Process -Id $process.Id -ErrorAction Stop
            }
        }
        Assert-Test ($app.WaitForExit(5000)) 'The isolated desktop executable did not exit.'
    }
    $app.Dispose()
}

function Invoke-OwnedUninstaller {
    $registered = Get-RegistrationPath
    if (-not $registered) { return }
    Assert-Test ([string]::Equals($registered, $installDir, [StringComparison]::OrdinalIgnoreCase)) (
        'The installed application belongs to another location. Skipping uninstall.'
    )
    $uninstaller = Join-Path $installDir 'unins000.exe'
    Assert-Test (Test-Path -LiteralPath $uninstaller -PathType Leaf) 'The isolated Inno uninstaller is missing.'
    Invoke-QuietProcess $uninstaller @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', ('/LOG="{0}"' -f $uninstallLog)) 55000
}

Assert-Test ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) 'Run the installer smoke on Windows.'
Assert-Test ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq [Runtime.InteropServices.Architecture]::X64) (
    'Run the release smoke on a native Windows x64 host.'
)
$installerPath = Confirm-Installer $InstallerPath $expectedFileVersion
$previousInstaller = if ($PreviousInstallerPath) { Confirm-Installer $PreviousInstallerPath $previousFileVersion }

$normalInstall = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'Programs\GaoSeries\GaoCiYuan'
$shortcutPaths = @(
    Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::Programs)) "$productName.lnk"
    Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonPrograms)) "$productName.lnk"
)
Assert-Test (-not (Test-Path -LiteralPath $normalInstall)) 'A normal GaoCiYuan installation path already exists.'
Assert-Test (-not (Get-Process -Name 'GaoCiYuan','GaoCiYuan-cli' -ErrorAction SilentlyContinue)) 'GaoCiYuan is already running.'
foreach ($shortcut in $shortcutPaths) {
    Assert-Test (-not (Test-Path -LiteralPath $shortcut)) "A GaoCiYuan Start menu shortcut already exists at $shortcut."
}
$runtimePresent = $false
foreach ($hive in @($currentUser, $localMachine)) {
    foreach ($view in $registryViews) {
        Assert-Test (-not (Test-RegistryKey $hive $view $protocolKey)) 'A gaociyuan protocol registration already exists.'
        Assert-Test (-not (Test-RegistryKey $hive $view $uninstallKey)) 'A GaoCiYuan uninstall registration already exists.'
        $runtimeVersion = Get-RegistryValue $hive $view $edgeKey 'pv'
        if ($runtimeVersion -and $runtimeVersion -ne '0.0.0.0') { $runtimePresent = $true }
    }
}
Assert-Test $runtimePresent 'Install the Microsoft Edge WebView2 runtime before running this isolated smoke.'
if (-not ('System.Security.Cryptography.ProtectedData' -as [type])) { Add-Type -AssemblyName System.Security }

$buildRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'build'))
Assert-LocalDirectory $PSScriptRoot
if (-not (Test-Path -LiteralPath $buildRoot)) { New-Item -ItemType Directory -Path $buildRoot | Out-Null }
Assert-LocalDirectory $buildRoot
$runRoot = [IO.Path]::GetFullPath((Join-Path $buildRoot ('smoke-' + [Guid]::NewGuid().ToString('N'))))
Assert-Test ((Split-Path -Parent $runRoot) -eq $buildRoot -and -not (Test-Path -LiteralPath $runRoot)) (
    'Smoke state must be a fresh direct child of the Windows build directory.'
)
$installDir = Join-Path $runRoot 'Fresh Install'
$dataDir = Join-Path $runRoot 'Synthetic Data'
$installLog = Join-Path $runRoot 'install.log'
$previousInstallLog = Join-Path $runRoot 'install-previous.log'
$uninstallLog = Join-Path $runRoot 'uninstall.log'
$appExe = Join-Path $installDir 'GaoCiYuan.exe'
$cliExe = Join-Path $installDir 'GaoCiYuan-cli.exe'
$launchExe = if ($HeadlessServerOnly) { $cliExe } else { $appExe }
$credentialDir = Join-Path $dataDir 'credentials'
$libraryFile = Join-Path $dataDir 'library.json'
$alertsFile = Join-Path $dataDir 'alerts.json'
$settingsFile = Join-Path $dataDir 'settings.json'
$grokFile = Join-Path $dataDir 'grokbot-usage.json'
$agentID, $grokID, $llmID = 1..3 | ForEach-Object { [Guid]::NewGuid().ToString('N') }
$keptSecret = 'isolated-agent-' + [Guid]::NewGuid().ToString('N')
$removedSecret = 'isolated-llm-' + [Guid]::NewGuid().ToString('N')
$keptCredential = Join-Path $credentialDir "$agentID.dpapi"
$removedCredential = Join-Path $credentialDir "$llmID.dpapi"
$app = $null
$sessionHeader = $null
$baseURL = $null
$completed = $false

try {
    New-Item -ItemType Directory -Path $runRoot | Out-Null
    New-Item -ItemType Directory -Path $dataDir,$credentialDir | Out-Null
    Write-FixtureCredential $keptCredential $keptSecret
    Write-FixtureCredential $removedCredential $removedSecret
    $originalHash = (Get-FileHash -LiteralPath $keptCredential -Algorithm SHA256).Hash
    $now = [DateTime]::UtcNow
    $oldSnapshot = @{
        observedAt = $now.AddMinutes(-3).ToString('yyyy-MM-ddTHH:mm:ssZ'); source = 'Isolated old snapshot'
        quotas = @(@{ id = 'fixture-window'; title = 'Fixture quota'; usedPercent = 27; windowSeconds = 18000
                     resetsAt = $now.AddHours(2).ToString('yyyy-MM-ddTHH:mm:ssZ') })
    }
    Write-Json $libraryFile @{
        schema = 1; refreshMinutes = 5; warningThreshold = 20; autoRefresh = $true
        storeFixture = @{ value = 'kept' }; station = @{ removed = $true }
        accounts = @(
            @{ id = $agentID; provider = 'cursor'; kind = 'Agent'; name = 'Isolated preserved agent'
               connection = $fileConnection; enabled = $false; accountFixture = 'kept'; snapshot = $oldSnapshot
               history = @($oldSnapshot) }
            @{ id = $grokID; provider = 'grok'; kind = 'Agent'; name = 'Isolated Grok Bot'; connection = $localConnection }
            @{ id = $llmID; provider = 'openai'; kind = 'LLM'; name = 'Isolated obsolete LLM'; connection = $fileConnection }
        )
    }
    Write-Json $alertsFile @{ failures = @{ $agentID = 2 } }
    Write-Json $settingsFile @{ appearance = 'dark'; panelDock = 'left'; panelTwoColumns = $true }
    $report = @{
        schema = 1; source = 'grok-bot-usage-report'; plan = 'Fixture'
        weeklyPercentUsed = 19.3; sharedWithOtherApps = $true
        capturedAt = $now.ToString('yyyy-MM-ddTHH:mm:ssZ')
        resetsAt = $now.AddDays(2).ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
    Write-Json $grokFile $report

    $installerArguments = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', ('/DIR="{0}"' -f $installDir))
    $upgradeHashes = @{}
    if ($previousInstaller) {
        Invoke-QuietProcess $previousInstaller ($installerArguments + ('/LOG="{0}"' -f $previousInstallLog)) 55000
        Assert-Test ((Get-RegistrationPath) -eq $installDir) 'The previous installer registered the wrong location.'
        $previousState = & $cliExe --data-dir $dataDir --inspect
        Assert-Test ($LASTEXITCODE -eq 0 -and $previousState -ccontains "version=$previousVersion" -and
            $previousState -ccontains 'status=ready' -and $previousState -ccontains 'accounts=2') 'The previous build did not open the isolated library.'
        foreach ($file in @($libraryFile, $alertsFile, $settingsFile, $keptCredential, $grokFile)) {
            $upgradeHashes[$file] = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
        }
    }
    Invoke-QuietProcess $installerPath ($installerArguments + ('/LOG="{0}"' -f $installLog)) 55000
    foreach ($file in $upgradeHashes.Keys) {
        Assert-Test ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -eq $upgradeHashes[$file]) 'Upgrade changed the isolated user data.'
    }
    Assert-LocalDirectory $installDir
    Assert-Test ([string]::Equals((Get-RegistrationPath), $installDir, [StringComparison]::OrdinalIgnoreCase)) 'The installer registered the wrong location.'
    $view = [Microsoft.Win32.RegistryView]::Registry64
    Assert-Test ((Get-RegistryValue $currentUser $view $protocolKey 'URL Protocol') -ceq '') 'The protocol marker is missing.'
    $command = Get-RegistryValue $currentUser $view "$protocolKey\shell\open\command" ''
    Assert-Test ($command -ceq ('"{0}" "%1"' -f $appExe)) 'The deep-link executable and argument must both be quoted.'
    Assert-X64Pe $appExe
    Assert-X64Pe $cliExe
    Write-Verbose "Installed AMD64 executable at '$appExe'."
    Assert-InstalledShortcut -ShortcutFile $shortcutPaths[0] -ExpectedTarget $appExe
    foreach ($path in @($appExe, $cliExe)) {
        Assert-Test ((Get-Item -LiteralPath $path).VersionInfo.FileVersion.Trim() -eq $expectedFileVersion) "Wrong file version for $path."
    }
    $cliVersion = & $cliExe --version
    Assert-Test ($LASTEXITCODE -eq 0 -and "$cliVersion".Trim() -ceq $expectedVersion) 'The installed CLI version is incorrect.'
    Assert-InstalledCliHelp $cliExe $dataDir

    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    try { $port = $listener.LocalEndpoint.Port }
    finally { $listener.Stop() }
    $baseURL = "http://127.0.0.1:$port"
    $startup = @('--data-dir', ('"{0}"' -f $dataDir), '--no-refresh', '--port', [string]$port, 'gaociyuan://analytics')
    if ($HeadlessServerOnly) { $startup += @('--serve', '--no-browser') }
    else { $startup += '--desktop-hidden' }
    $app = Start-Process -FilePath $launchExe -WindowStyle Hidden -PassThru -ArgumentList $startup

    $deadline = [DateTime]::UtcNow.AddSeconds(45)
    $isReady = $false
    do {
        Assert-Test (-not $app.HasExited) 'The isolated host exited during startup.'
        try {
            $html = (Invoke-WebRequest -Uri "$baseURL/" -NoProxy -UseBasicParsing -TimeoutSec 2).Content
            $token = [regex]::Match($html, '<meta name="gao-token" content="([A-Za-z0-9_-]+)">')
            if ($token.Success) {
                $sessionHeader = @{ 'X-Gao-Token' = $token.Groups[1].Value }
                $native = Invoke-AppApi '/api/native'
                if ($HeadlessServerOnly) { $isReady = -not $native.desktop -and -not $native.trayRegistered }
                else { $isReady = $native.desktop -and $native.ready -and $native.cliPath -eq $cliExe -and -not $native.trayRegistered }
            }
        } catch { Write-Verbose 'Waiting for the isolated GaoCiYuan host.' }
        if (-not $isReady) { Start-Sleep -Milliseconds 250 }
    } while (-not $isReady -and [DateTime]::UtcNow -lt $deadline)
    Assert-Test $isReady 'The installed application did not become ready.'
    $state = Invoke-AppApi '/api/state'
    Assert-Test ($state.version -eq $expectedVersion -and $state.dataDir -eq $dataDir -and
        $state.credentialBackend -eq 'windows' -and $state.status -eq 'ready') 'The app did not open the isolated Windows library.'
    Assert-Test ($state.settings.appearance -eq 'dark' -and $state.settings.panelDock -eq 'left' -and
        $state.settings.panelTwoColumns) 'Existing appearance and panel settings were lost.'
    $discovery = Invoke-AppApi '/api/discovery'
    Assert-Test (-not $discovery.completed -and @($discovery.observations).Count -eq 0) 'Host discovery ran against the isolated profile.'

    $migrated = Read-Json $libraryFile
    $kept = @($migrated.accounts | Where-Object { $_.id -eq $agentID })
    Assert-Test ($migrated.accounts.Count -eq 2 -and $kept.Count -eq 1 -and $kept[0].accountFixture -eq 'kept' -and
        $migrated.storeFixture.value -eq 'kept' -and -not $migrated.PSObject.Properties['station']) 'The old Windows library did not migrate as expected.'
    Assert-Test ($kept[0].snapshot.quotas[0].usedPercent -eq 27 -and $kept[0].history.Count -eq 1 -and
        [DateTimeOffset]$kept[0].history[0].observedAt -eq [DateTimeOffset]$oldSnapshot.observedAt) 'The existing Agent snapshot and history did not survive migration.'
    $preservedCredential = Invoke-AppApi "/api/credentials/status?id=$agentID"
    Assert-Test ($preservedCredential.hasCredential -and (Read-FixtureCredential $keptCredential) -ceq $keptSecret -and
        (Get-FileHash -LiteralPath $keptCredential -Algorithm SHA256).Hash -eq $originalHash -and
        -not (Test-Path -LiteralPath $removedCredential)) 'Agent DPAPI preservation or obsolete LLM credential removal failed.'
    Assert-Test ((Read-Json $alertsFile).failures.PSObject.Properties[$agentID].Value -eq 2) 'The existing Agent alert counter was lost.'
    $newSecret = 'isolated-app-write-' + [Guid]::NewGuid().ToString('N')
    $written = Invoke-AppApi '/api/credentials/set' @{ id = $grokID; secret = $newSecret }
    $newProtected = Join-Path $credentialDir "$grokID.dpapi"
    Assert-Test ($written.ok -and (Read-FixtureCredential $newProtected) -ceq $newSecret -and
        -not (Get-Content -LiteralPath $libraryFile -Encoding UTF8 -Raw).Contains($newSecret)) 'The installed app did not store the synthetic credential solely under DPAPI.'

    $auto = Invoke-AppApi '/api/refresh-due' @{}
    $batch = Invoke-AppApi '/api/accounts/refresh-all' @{}
    Assert-Test ($state.grokReads -eq 0 -and $auto.state.grokReads -eq 0 -and $batch.state.grokReads -eq 0) 'An automatic or bulk refresh read the Grok Bot file.'
    $manual = Invoke-AppApi '/api/grokbot/read' @{ id = $grokID }
    $grok = @($manual.state.accounts | Where-Object { $_.id -eq $grokID })[0]
    Assert-Test ($manual.ok -and $manual.result.grokReads -eq 1 -and
        [Math]::Abs($grok.ring.remainingPercent - 80.7) -lt .001 -and @($grok.history).Count -eq 0 -and $null -eq $grok.snapshot) (
        'The Grok Bot manual reading, remaining quota ring or history isolation is incorrect.'
    )
    $panel = Invoke-AppApi '/api/panel'
    Assert-Test (@($panel.rail | Where-Object { $_.id -eq $grokID }).Count -eq 1) 'The Grok Bot is missing from the floating rail.'
    $report.source = 'invalid-fixture'
    Write-Json $grokFile $report
    $invalid = Invoke-AppApi '/api/grokbot/read' @{ id = $grokID }
    $preserved = @($invalid.state.accounts | Where-Object { $_.id -eq $grokID })[0]
    Assert-Test ($invalid.result.grokReads -eq 2 -and
        [Math]::Abs($preserved.ring.remainingPercent - 80.7) -lt .001) 'An invalid Grok Bot report replaced the previous good reading.'

    $dark = Invoke-AppApi '/api/settings' @{ appearance = 'dark'; panelFloating = $true }
    $light = Invoke-AppApi '/api/settings' @{ appearance = 'light'; panelFloating = $false }
    Assert-Test ($dark.state.settings.appearance -eq 'dark' -and $dark.state.settings.panelFloating -and
        $light.state.settings.appearance -eq 'light' -and -not $light.state.settings.panelFloating) 'Theme and floating-window options did not persist.'

    $dataHashes = @{}
    foreach ($file in @($libraryFile, $alertsFile, $keptCredential, $newProtected, $grokFile, $settingsFile)) {
        $dataHashes[$file] = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
    }
    Stop-SmokeApp
    $app = $null
    Invoke-OwnedUninstaller
    Assert-Test (-not (Test-Path -LiteralPath $appExe) -and -not (Test-Path -LiteralPath $cliExe)) 'Uninstall left application files.'
    foreach ($view in $registryViews) {
        Assert-Test (-not (Test-RegistryKey $currentUser $view $protocolKey)) 'Uninstall left the gaociyuan protocol.'
        Assert-Test (-not (Test-RegistryKey $currentUser $view $uninstallKey)) 'Uninstall left the product registration.'
    }
    Assert-Test (-not (Test-Path -LiteralPath $shortcutPaths[0])) 'Uninstall left the Start menu shortcut.'
    foreach ($file in $dataHashes.Keys) {
        Assert-Test ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -eq $dataHashes[$file]) 'Uninstall changed the isolated user data.'
    }
    $completed = $true
    $surface = if ($HeadlessServerOnly) { 'loopback server' } else { 'hidden main and floating WebView2' }
    Write-Output "Installed smoke passed for $expectedVersion ($surface). Installer, native and CLI PE files are AMD64."
    if ($previousInstaller) { Write-Output "In-place upgrade from $previousVersion and unchanged user data verified." }
} finally {
    if (-not $completed) {
        try { Stop-SmokeApp } catch { Write-Warning $_.Exception.Message }
        try { Invoke-OwnedUninstaller } catch { Write-Warning $_.Exception.Message }
    }
    if ($completed -and -not $KeepArtifacts) {
        Assert-LocalDirectory $buildRoot
        Assert-Test ((Split-Path -Parent $runRoot) -eq $buildRoot -and (Split-Path -Leaf $runRoot) -match '^smoke-[0-9a-f]{32}$') (
            'Refusing to clean a path outside the isolated smoke directory.'
        )
        Assert-SafeTree $runRoot
        for ($attempt = 1; $attempt -le 10 -and (Test-Path -LiteralPath $runRoot); $attempt++) {
            try { Remove-Item -LiteralPath $runRoot -Force -Recurse }
            catch [IO.IOException] {
                if ($attempt -eq 10) { throw }
                Start-Sleep -Milliseconds 400
            }
        }
    } else {
        Write-Output "Synthetic smoke artifacts at $runRoot"
    }
}
