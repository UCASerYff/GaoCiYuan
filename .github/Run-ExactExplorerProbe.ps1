[CmdletBinding()]
param([string]$Executable)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted') {
    throw 'This probe may only run on a disposable GitHub-hosted runner.'
}

$repo = Split-Path -Parent $PSScriptRoot
$windows = Join-Path $repo 'windows'
$evidence = Join-Path $windows 'build/explorer-evidence'
$null = New-Item -ItemType Directory -Path $evidence -Force

function Assert-Probe([bool]$Condition, [string]$Failure) {
    if (-not $Condition) { throw $Failure }
}

function Wait-Probe([scriptblock]$Test, [string]$Failure, [int]$Seconds = 12) {
    $deadline = [Diagnostics.Stopwatch]::StartNew()
    do {
        $result = & $Test
        if ($result) { return $result }
        Start-Sleep -Milliseconds 160
    } while ($deadline.Elapsed.TotalSeconds -lt $Seconds)
    throw $Failure
}

function Confirm-Digest([string]$File, [string]$Digest) {
    $value = (Get-FileHash -Algorithm SHA256 -LiteralPath $File).Hash.ToLowerInvariant()
    Assert-Probe ($value -ceq $Digest) "Unexpected SHA-256 for $File."
    return $value
}

if (-not $Executable) {
    $name = 'GaoCiYuan-Windows-4.15-build3-x64-Setup.exe'
    $installer = Join-Path $windows "build/exact-4.15.3/$name"
    $digest = Confirm-Digest $installer 'f6740ad5b58bbf834de8032ac506777c4d09d33c2ed8c81f3cfc47046b58bd00'
    $sidecar = (Get-Content -LiteralPath "$installer.sha256" -Raw).Trim() -split '\s+', 2
    Assert-Probe ($sidecar.Count -eq 2 -and $sidecar[0] -ceq $digest -and $sidecar[1] -ceq $name) 'The installer sidecar differs from the known candidate.'
    $original = Join-Path $windows 'smoke-installed.ps1'
    $generated = Join-Path $windows 'smoke-installed-explorer.generated.ps1'
    $smoke = Get-Content -LiteralPath $original -Encoding utf8 -Raw
    $hook = '    \$app = \$null\r?\n(?=    Invoke-OwnedUninstaller)'
    $matchesFound = [regex]::Matches($smoke, $hook)
    Assert-Probe ($matchesFound.Count -eq 1) 'Could not find the unique installation smoke cleanup boundary.'
    $marker = $matchesFound[0]
    $env:GAOCIYUAN_EXPLORER_PROBE = $PSCommandPath
    try {
        $smoke.Insert($marker.Index + $marker.Length, '    & $env:GAOCIYUAN_EXPLORER_PROBE -Executable $appExe' + "`n") |
            Set-Content -LiteralPath $generated -Encoding utf8
        & $generated -InstallerPath $installer -HeadlessServerOnly -Verbose
    } finally {
        if (Test-Path -LiteralPath $generated -PathType Leaf) { Remove-Item -LiteralPath $generated -Force }
    }
    return
}

$mainDigest = Confirm-Digest $Executable '770cb598a3ce2912c84591699d5b704390b6902fd2392809c6fcaff3f7963f9b'
Add-Type -LiteralPath (Join-Path $windows 'tests/TraySmokeNative.cs')
Add-Type -LiteralPath (Join-Path $PSScriptRoot 'ExplorerProbeNative.cs')
$n = [GaoCiYuan.Smoke.ExplorerProbeNative]
$t = [GaoCiYuan.Smoke.TrayDesktop]
$session = [Diagnostics.Process]::GetCurrentProcess().SessionId
$initialShell = $n::Taskbar()
$result = [ordered]@{
    executableSha256 = $mainDigest
    version = (Get-Item -LiteralPath $Executable).VersionInfo.FileVersion
    windowsBuild = [Environment]::OSVersion.Version.ToString()
    runnerSession = $session
    shellTaskbarFound = $initialShell -ne [IntPtr]::Zero
}

function Get-TrayCallbacks {
    $n::Windows($app.Id) | Where-Object { $_.Class -cmatch '^com\.gaoseries\.GaoCiYuan[0-9]+SystemTrayIcon$' } | ForEach-Object {
        $classId = [uint32]([UInt64]([regex]::Match($_.Class, '[0-9]+(?=SystemTrayIcon$)').Value) -band 0xffffffffL)
        # The pinned pystray data structure has a uID field. This exact package supplies
        # hID instead, leaving the serialized uID at zero for both its add and delete calls.
        $uid = [uint32]0
        $rect = [GaoCiYuan.Smoke.ExplorerProbeNative+Rectangle]::new()
        $status = $n::NotifyStatus($_.Handle, $uid, [ref]$rect)
        $classBounds = [GaoCiYuan.Smoke.ExplorerProbeNative+Rectangle]::new()
        $classStatus = $n::NotifyStatus($_.Handle, $classId, [ref]$classBounds)
        [PSCustomObject]@{
            Window = $_.Handle; Id = $uid; Status = ('0x{0:X8}' -f $status); Bounds = $rect
            ClassId = $classId; ClassIdStatus = ('0x{0:X8}' -f $classStatus)
        }
    }
}

function Find-TrayRegistration {
    $matches = @(Get-TrayCallbacks | Where-Object {
        $_.Status -ceq '0x00000000' -and $_.Bounds.Right -gt $_.Bounds.Left -and $_.Bounds.Bottom -gt $_.Bounds.Top
    })
    Assert-Probe ($matches.Count -le 1) 'Explorer reported duplicate notifications for the exact packaged process.'
    if ($matches.Count -eq 1) { return $matches[0] }
}

function Open-NotificationOverflow([IntPtr]$ShellWindow) {
    try {
        Add-Type -AssemblyName UIAutomationClient
        Add-Type -AssemblyName UIAutomationTypes
        $shellElement = [Windows.Automation.AutomationElement]::FromHandle($ShellWindow)
        $button = [Windows.Automation.PropertyCondition]::new(
            [Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::Button)
        $controls = $shellElement.FindAll([Windows.Automation.TreeScope]::Descendants, $button)
        $candidates = @($controls | Where-Object {
            $_.Current.Name -match '(?i)hidden icons|notification overflow' -or
            $_.Current.AutomationId -match '(?i)Chevron|Overflow'
        })
        $result['overflowCandidates'] = @($candidates | ForEach-Object {
            @{ name = $_.Current.Name; id = $_.Current.AutomationId }
        })
        $target = $candidates | Where-Object { $_.Current.IsEnabled -and -not $_.Current.IsOffscreen } | Select-Object -First 1
        if (-not $target) { return $false }
        $invoker = $null
        if ($target.TryGetCurrentPattern([Windows.Automation.InvokePattern]::Pattern, [ref]$invoker)) {
            $invoker.Invoke()
            return $true
        }
        $expander = $null
        if ($target.TryGetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern, [ref]$expander)) {
            $expander.Expand()
            return $true
        }
        return $false
    } catch {
        $result['overflowError'] = $_.Exception.Message
        return $false
    }
}

function Add-Bounds($Bounds) {
    [ordered]@{
        left = $Bounds.Left; top = $Bounds.Top
        width = $Bounds.Right - $Bounds.Left; height = $Bounds.Bottom - $Bounds.Top
    }
}

function Write-NotificationCrop($Bounds, [string]$Name) {
    try {
        Add-Type -AssemblyName System.Drawing.Common
        $size = [Drawing.Size]::new($Bounds.width, $Bounds.height)
        Assert-Probe ($size.Width -lt 128 -and $size.Height -lt 128) 'The notification bounds are not an icon-sized rectangle.'
        $image = [Drawing.Bitmap]::new($size.Width, $size.Height)
        try {
            $graphics = [Drawing.Graphics]::FromImage($image)
            try { $graphics.CopyFromScreen($Bounds.left, $Bounds.top, 0, 0, $size) }
            finally { $graphics.Dispose() }
            $image.Save((Join-Path $evidence "$Name.png"), [Drawing.Imaging.ImageFormat]::Png)
        } finally { $image.Dispose() }
        return $true
    } catch {
        Write-Verbose "The hosted desktop did not allow an icon-sized crop: $($_.Exception.Message)"
        return $false
    }
}

function Find-MainWindow {
    $n::Windows($app.Id) | Where-Object { $_.Title -ceq '搞词元 V4.15' } | Select-Object -First 1
}

function Quit-OwnedEndpoint {
    Invoke-RestMethod -Uri "$base/api/shutdown" -Method Post -ContentType 'application/json' -Body '{}' `
        -Headers @{ 'X-Gao-Token' = $token } -NoProxy -TimeoutSec 4 | Out-Null
}

$app = $null
$token = $null
$base = $null
try {
    if ($session -eq 0 -or -not $result.shellTaskbarFound) {
        $result.explorer = 'unavailable in the hosted job session'
        throw 'The hosted job has no accessible Explorer taskbar in an interactive session.'
    }

    $shell = Get-Process -Id ($n::Owner($initialShell))
    $expectedShellPath = Join-Path $env:WINDIR 'explorer.exe'
    Assert-Probe ($shell.SessionId -eq $session -and $shell.Path -ieq $expectedShellPath) 'The initial shell is not the hosted session Windows Explorer.'
    $result.sampleTransport = $t::ProbeShell()
    $scratch = Join-Path $env:RUNNER_TEMP ('gaociyuan-app-explorer-' + [Guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $scratch
    $app = Start-Process -FilePath $Executable -PassThru -ArgumentList @('--data-dir', ('"{0}"' -f $scratch), '--no-refresh')
    $port = Wait-Probe {
        if ($app.HasExited) { throw "The exact packaged GUI exited ($($app.ExitCode))." }
        $ports = @($t::LoopbackPorts($app.Id))
        Assert-Probe ($ports.Count -le 1) 'An unexpected second loopback listener was found.'
        if ($ports.Count -eq 1) { $ports[0] }
    } 'The packaged GUI did not own a loopback port.' 20
    $base = "http://127.0.0.1:$port"
    $token = Wait-Probe {
        try {
            $html = (Invoke-WebRequest -Uri $base -NoProxy -TimeoutSec 3).Content
            if ($html -match '<meta name="gao-token" content="([a-zA-Z0-9_-]+)">') { $Matches[1] }
        } catch { Write-Verbose 'Waiting for the fixture server.' }
    } 'The isolated GUI did not provide its loopback token.'
    $state = Invoke-RestMethod -Uri "$base/api/state" -Headers @{ 'X-Gao-Token' = $token } -NoProxy -TimeoutSec 4
    Assert-Probe ($state.dataDir -ieq $scratch) 'The GUI did not use the new runner profile.'
    $main = Wait-Probe { $win = Find-MainWindow; if ($win -and $win.Visible) { $win } } 'The actual main window did not appear.' 30
    $dpi = $n::Dpi($main.Handle)
    $result.windowDpi = $dpi
    $result.shellDpi = $n::Dpi($initialShell)
    foreach ($kind in 0, 1) {
        $expected = $n::ExpectedIcon($dpi, $kind -eq 0)
        $measurement = Wait-Probe {
            $actual = $n::NativeIcon($main.Handle, $kind)
            if (($actual -join ',') -ceq ($expected -join ',')) { [PSCustomObject]@{ Pixels = $actual } }
        } "WM_GETICON did not return the exact 32-bit native frame at requested DPI (kind $kind)."
        $result[('windowIcon' + $kind)] = $measurement.Pixels
    }

    $native = Wait-Probe {
        $status = Invoke-RestMethod -Uri "$base/api/native" -Headers @{ 'X-Gao-Token' = $token } -NoProxy -TimeoutSec 4
        if ($status.ready -and @(Get-TrayCallbacks).Count -eq 2) { $status }
    } 'The installed application did not initialize its ready WebView and tray callbacks.'
    $result.nativeReady = $native.ready
    $result.nativeTrayRegistered = $native.trayRegistered
    $result.callbacksBeforeOverflow = @(Get-TrayCallbacks | Select-Object @{n='Window';e={$_.Window.ToInt64()}},Id,Status,ClassId,ClassIdStatus)
    Assert-Probe ($native.trayRegistered) 'The actual packaged app reported no successful Shell_NotifyIcon registration.'
    $tray = Find-TrayRegistration
    if (-not $tray) {
        $result.overflowInvoked = Open-NotificationOverflow $initialShell
        $tray = Wait-Probe { Find-TrayRegistration } 'Explorer did not locate the actual app notification icon, including its overflow.' 5
    }
    $result.initialTrayBounds = Add-Bounds $tray.Bounds
    $result.initialTrayCropSaved = Write-NotificationCrop $result.initialTrayBounds 'tray-before-restart'
    $result.initialExplorerId = $shell.Id
    $t::CloseMain($main.Handle)
    $null = Wait-Probe { $win = Find-MainWindow; $win -and -not $win.Visible } 'Close did not leave the application running in its real tray.'
    $t::OpenTrayDefault($tray.Window)
    $null = Wait-Probe {
        $win = Find-MainWindow
        $win -and $win.Visible -and $win.Handle -eq $main.Handle
    } 'The callback of the real tray item did not reopen the same main HWND.'
    $result.reopenedSameWindow = $true

    # Restart only the exact validated Explorer owned by this disposable GitHub job session.
    $shell.Kill()
    Assert-Probe ($shell.WaitForExit(12000)) 'The disposable Explorer process did not stop.'
    $awaitNewShell = {
        $current = $n::Taskbar()
        if ($current -ne [IntPtr]::Zero -and $n::Owner($current) -ne $shell.Id) { $current }
    }
    try {
        $newShell = Wait-Probe $awaitNewShell 'Waiting for automatic restart of the disposable shell.' 8
    } catch {
        # Run only after the previous exact shell exited, and only on the hosted desktop.
        Start-Process -FilePath $expectedShellPath -WindowStyle Hidden
        $newShell = Wait-Probe $awaitNewShell 'Hosted Explorer did not recreate its taskbar; no broadcast recovery claim.' 20
    }
    $newShellProcess = Get-Process -Id ($n::Owner($newShell))
    Assert-Probe ($newShellProcess.SessionId -eq $session -and $newShellProcess.Path -ieq $expectedShellPath) 'The restarted shell is not the hosted Windows Explorer.'
    $result.callbacksAfterRestart = @(Get-TrayCallbacks | Select-Object @{n='Window';e={$_.Window.ToInt64()}},Id,Status,ClassId,ClassIdStatus)
    $restored = Find-TrayRegistration
    if (-not $restored) {
        $result.overflowInvokedAfterRestart = Open-NotificationOverflow $newShell
        $restored = Wait-Probe { Find-TrayRegistration } 'The exact application notification was not found after actual Explorer restart.'
    }
    Assert-Probe ($restored.Id -eq $tray.Id -and $restored.Window -eq $tray.Window -and -not $app.HasExited) 'Recovery changed the app callback identity or process.'
    $result.recreatedExplorerId = $newShellProcess.Id
    $result.restoredTrayBounds = Add-Bounds $restored.Bounds
    $result.restoredTrayCropSaved = Write-NotificationCrop $result.restoredTrayBounds 'tray-after-restart'

    $t::OpenTrayMenu($tray.Window)
    try {
        $popup = Wait-Probe {
            $n::Windows($app.Id) | Where-Object { $_.Class -eq '#32768' -and $_.Visible } | Select-Object -First 1
        } 'The exact app tray menu was not observable.' 3
        $t::SelectLastMenuItem($popup.Handle)
        $result.exitedByMenu = $app.WaitForExit(5000)
    } catch { $result.exitedByMenu = $false }
    if (-not $result.exitedByMenu) {
        Quit-OwnedEndpoint
        Assert-Probe ($app.WaitForExit(10000)) 'The app did not close from its safe shutdown endpoint.'
    }
    Assert-Probe ($app.ExitCode -eq 0) 'The exact packaged GUI returned an exit error.'
    $null = Wait-Probe {
        -not $n::NotifyBounds($tray.Window, $tray.Id) -and
        $n::Windows($app.Id).Count -eq 0 -and
        $port -notin @($t::LoopbackPorts(-1))
    } 'The exact tray item, native window or loopback port was left alive after exit.'
    $result.teardown = 'Explorer item, app HWNDs, process and loopback port removed'
    Assert-Probe ($result.exitedByMenu) 'The session verified safe shutdown but could not activate the native tray Exit menu.'
} finally {
    if ($app -and -not $app.HasExited) {
        if ($token) { try { Quit-OwnedEndpoint } catch { Write-Verbose 'The app endpoint was already closed.' } }
        if (-not $app.WaitForExit(5000)) { $app.Kill($true); $null = $app.WaitForExit(5000) }
    }
    if ($app) { $app.Dispose() }
    $result | ConvertTo-Json -Depth 6 | Tee-Object -FilePath (Join-Path $evidence 'exact-explorer.json')
}
