#requires -Version 7.2
<#
.SYNOPSIS
Starts the installed GUI with isolated application data on a non-input Win32 desktop.
.DESCRIPTION
No desktop switching, global keyboard input, or installed image changes. The optional
Explorer API probe adds and removes its own icon backed by an invisible window on the
calling desktop. That probe does not establish whether Explorer displayed the app icon.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Executable,
    [string]$ExpectedFileVersion,
    [switch]$ProbeExplorer,
    [switch]$RequireTrayMenuExit
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-TrayTest([bool]$Condition, [string]$Failure) {
    if (-not $Condition) { throw $Failure }
}

function Wait-TrayTest([scriptblock]$Check, [string]$Failure, [int]$TimeoutMs = 10000) {
    $deadline = [Diagnostics.Stopwatch]::StartNew()
    while ($deadline.ElapsedMilliseconds -lt $TimeoutMs) {
        $value = & $Check
        if ($value) { return $value }
        Start-Sleep -Milliseconds 100
    }
    throw $Failure
}

function Assert-SafeDirectory([string]$Path) {
    $directory = Get-Item -LiteralPath $Path -Force
    Assert-TrayTest ($directory.PSIsContainer -and -not ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint)) (
        "Expected a plain local directory at $Path."
    )
}

function Assert-NoReparsePoints([string]$Path) {
    Assert-SafeDirectory $Path
    foreach ($entry in Get-ChildItem -LiteralPath $Path -Force) {
        Assert-TrayTest (-not ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint)) "Cleanup stopped at $($entry.FullName)."
        if ($entry.PSIsContainer) { Assert-NoReparsePoints $entry.FullName }
    }
}

function Invoke-TrayApi([string]$Path, [switch]$Post) {
    $parameters = @{ Uri = "$baseUrl$Path"; Headers = @{ 'X-Gao-Token' = $token }; NoProxy = $true; TimeoutSec = 3 }
    if ($Post) {
        $parameters.Method = 'Post'
        $parameters.ContentType = 'application/json'
        $parameters.Body = '{}'
    }
    Invoke-RestMethod @parameters
}

function Find-MainWindow {
    $desktop.Windows($primary.Id) | Where-Object { $_.Title -eq $mainTitle } | Select-Object -First 1
}

function Find-TrayWindows {
    $desktop.Windows($primary.Id) | Where-Object { $_.Class -cmatch '^com\.gaoseries\.GaoCiYuan[0-9]+SystemTrayIcon$' }
}

function Find-QuitWindow {
    $desktop.Windows($primary.Id) | Where-Object { $_.Class -eq '#32770' -and $_.Title -eq $quitTitle -and $_.Visible } | Select-Object -First 1
}

function Invoke-WebViewExpression([uri]$Connection, [string]$Expression) {
    $socket = [Net.WebSockets.ClientWebSocket]::new()
    $timeout = [Threading.CancellationTokenSource]::new(5500)
    try {
        $socket.Options.Proxy = $null
        $null = $socket.ConnectAsync($Connection, $timeout.Token).GetAwaiter().GetResult()
        $command = @{ id = 1; method = 'Runtime.evaluate'; params = @{ expression = $Expression; returnByValue = $true } }
        $bytes = [Text.Encoding]::UTF8.GetBytes(($command | ConvertTo-Json -Depth 8 -Compress))
        $null = $socket.SendAsync([ArraySegment[byte]]::new($bytes), [Net.WebSockets.WebSocketMessageType]::Text, $true, $timeout.Token).GetAwaiter().GetResult()
        do {
            $data = [IO.MemoryStream]::new()
            try {
                $receive = [byte[]]::new(4096)
                do {
                    $frame = $socket.ReceiveAsync([ArraySegment[byte]]::new($receive), $timeout.Token).GetAwaiter().GetResult()
                    Assert-TrayTest ($frame.MessageType -eq [Net.WebSockets.WebSocketMessageType]::Text -and $data.Length -lt 100000) 'Invalid WebView2 DevTools response.'
                    $data.Write($receive, 0, $frame.Count)
                } while (-not $frame.EndOfMessage)
                $reply = [Text.Encoding]::UTF8.GetString($data.ToArray()) | ConvertFrom-Json -AsHashtable
            } finally { $data.Dispose() }
        } until ($reply['id'] -eq 1)
        Assert-TrayTest (-not $reply['error'] -and -not $reply['result']['exceptionDetails']) 'WebView2 rejected a fixture command.'
        return $reply['result']['result']['value']
    } finally { $socket.Dispose(); $timeout.Dispose() }
}

function Edit-FixtureDraft {
    $debugFile = Join-Path $scratch 'webview2\EBWebView\DevToolsActivePort'
    $localPort = Wait-TrayTest {
        if (Test-Path -LiteralPath $debugFile -PathType Leaf) {
            $line = Get-Content -LiteralPath $debugFile -TotalCount 1
            if ($line -match '^[1-9][0-9]{0,4}$' -and [int]$line -le 65535) { [int]$line }
        }
    } 'No WebView2 debugging endpoint appeared inside the isolated data directory.'
    $target = Wait-TrayTest {
        $pages = Invoke-RestMethod -Uri "http://127.0.0.1:$localPort/json/list" -TimeoutSec 3 -NoProxy
        $pages | Where-Object { $_.type -eq 'page' -and $_.url -like "$baseUrl/#*" } | Select-Object -First 1
    } 'No matching WebView2 main page at the isolated app origin.'
    $connection = [uri]$target.webSocketDebuggerUrl
    Assert-TrayTest ($connection.IsLoopback -and $connection.Port -eq $localPort -and $connection.Scheme -eq 'ws') 'Unexpected WebView2 debugging endpoint.'
    $alreadyDirty = Invoke-WebViewExpression $connection 'window.gaociyuanExitState().dirty'
    Assert-TrayTest (-not $alreadyDirty) 'The isolated draft was unexpectedly dirty before the input change.'
    $edited = Invoke-WebViewExpression $connection @'
(() => {
  const control = document.querySelector('[data-action="edit"][data-value="openai"]');
  if (!control) return false;
  control.click();
  const field = document.querySelector('#account-editor input[name="name"]');
  if (!field) return false;
  field.value = 'Synthetic tray draft';
  field.dispatchEvent(new Event('input', { bubbles: true }));
  return window.gaociyuanExitState().dirty;
})()
'@
    Assert-TrayTest ([bool]$edited) 'The normal account editor did not produce a dirty draft.'
    return $connection
}

Assert-TrayTest ($IsWindows -and [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture -eq [Runtime.InteropServices.Architecture]::X64) (
    'The tray smoke requires PowerShell 7 running as Windows x64.'
)
$resolved = (Resolve-Path -LiteralPath $Executable).ProviderPath
$app = Get-Item -LiteralPath $resolved
Assert-TrayTest (-not $app.PSIsContainer -and $app.Name -eq 'GaoCiYuan.exe') 'Pass the installed GaoCiYuan GUI executable.'
if ($ExpectedFileVersion) {
    Assert-TrayTest ($app.VersionInfo.FileVersion.Trim() -eq $ExpectedFileVersion) "Expected file version $ExpectedFileVersion."
}
if (-not ('GaoCiYuan.Smoke.TrayDesktop' -as [type])) {
    Add-Type -LiteralPath (Join-Path $PSScriptRoot 'TraySmokeNative.cs')
}
if ($ProbeExplorer) {
    $probe = [GaoCiYuan.Smoke.TrayDesktop]::ProbeShell()
    if ($probe.ExplorerFound) {
        Assert-TrayTest ($probe.Added -and $probe.Deleted -and -not $probe.BoundsAfterDelete) (
            "Explorer did not add and delete the hidden probe icon. $($probe | ConvertTo-Json -Compress)"
        )
        Write-Output "Explorer accepted NIM_ADD and NIM_DELETE for a hidden test window. Icon bounds available: $($probe.HasBounds)."
    } else {
        Write-Output 'Explorer was unavailable on the calling desktop. Actual Shell_NotifyIcon transport was not tested.'
    }
}

$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$build = [IO.Path]::GetFullPath((Join-Path $workspace 'build'))
Assert-SafeDirectory $workspace
if (-not (Test-Path -LiteralPath $build)) { New-Item -ItemType Directory -Path $build | Out-Null }
Assert-SafeDirectory $build
$scratch = [IO.Path]::GetFullPath((Join-Path $build ('tray-smoke-' + [Guid]::NewGuid().ToString('N'))))
Assert-TrayTest ((Split-Path -Parent $scratch) -eq $build -and -not (Test-Path -LiteralPath $scratch)) 'Expected a new tray smoke directory.'
New-Item -ItemType Directory -Path $scratch | Out-Null
$mainTitle = (ConvertFrom-Json '"\u641e\u8bcd\u5143"') + ' V' + $app.VersionInfo.ProductVersion
$quitTitle = ConvertFrom-Json '"\u9000\u51fa\u641e\u8bcd\u5143"'
$dirtyText = ConvertFrom-Json '"\u672a\u4fdd\u5b58"'
$desktop = $null
$primary = $null
$duplicate = $null
$token = $null
$baseUrl = $null

try {
    $desktop = [GaoCiYuan.Smoke.TrayDesktop]::new()
    $priorWebViewArgs = [Environment]::GetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS', 'Process')
    try {
        [Environment]::SetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS', '--remote-debugging-port=0 --remote-debugging-address=127.0.0.1', 'Process')
        $primary = $desktop.Launch($resolved, $scratch)
    } finally {
        [Environment]::SetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS', $priorWebViewArgs, 'Process')
    }
    $port = Wait-TrayTest {
        if ($primary.HasExited) { throw "The isolated GUI exited before opening a server (code $($primary.ExitCode))." }
        $ports = @([GaoCiYuan.Smoke.TrayDesktop]::LoopbackPorts($primary.Id))
        Assert-TrayTest ($ports.Count -le 1) 'More than one loopback listener belongs to the isolated GUI.'
        if ($ports.Count -eq 1) { $ports[0] }
    } 'The isolated GUI did not own a loopback listener.' 20000
    $baseUrl = "http://127.0.0.1:$port"
    $token = Wait-TrayTest {
        try {
            $page = (Invoke-WebRequest -Uri $baseUrl -TimeoutSec 3 -NoProxy).Content
            if ($page -match '<meta name="gao-token" content="([a-zA-Z0-9_-]+)">') { $Matches[1] }
        } catch {
            Write-Verbose $_.Exception.Message
        }
    } 'The isolated GUI did not provide a session token.'
    $native = Wait-TrayTest {
        $status = Invoke-TrayApi '/api/native'
        if ($status.desktop -and $status.ready) { $status }
    } 'The installed entry point did not initialize both native WebView2 surfaces.' 30000
    $state = Invoke-TrayApi '/api/state'
    Assert-TrayTest ([StringComparer]::OrdinalIgnoreCase.Equals([IO.Path]::GetFullPath($state.dataDir), $scratch)) (
        'The GUI did not use the isolated data directory.'
    )
    if (-not (Test-Path -LiteralPath (Join-Path $scratch 'library.json'))) {
        $null = Invoke-TrayApi '/api/library/create' -Post
    }
    $main = Wait-TrayTest {
        $window = Find-MainWindow
        if ($window -and $window.Visible) { $window }
    } 'The installed GUI did not show its main window on the isolated desktop.'
    Assert-TrayTest (-not [GaoCiYuan.Smoke.TrayDesktop]::OnCurrentDesktop($primary.Id)) 'An isolated GUI window appeared on the calling desktop.'

    $trayWindows = @(Wait-TrayTest { Find-TrayWindows } 'No native tray callback windows were created.')
    Assert-TrayTest ($trayWindows.Count -eq 2 -and @($trayWindows.Class | Sort-Object -Unique).Count -eq 1) (
        'Expected one pystray icon with one callback and one menu window.'
    )
    $shellIcons = @($trayWindows | Where-Object {
        $identity = [UInt64]([regex]::Match($_.Class, '[0-9]+(?=SystemTrayIcon$)').Value)
        [GaoCiYuan.Smoke.TrayDesktop]::ShellHasIcon($_.Handle, [uint32]($identity -band [UInt64]0xffffffffL))
    })
    Assert-TrayTest ($shellIcons.Count -le 1) 'Multiple Explorer notification-area entries were found.'
    Write-Output "One native tray callback/menu pair. Matching Explorer icon bounds: $($shellIcons.Count)."

    $duplicate = $desktop.Launch($resolved, $scratch)
    Assert-TrayTest ($duplicate.WaitForExit(12000)) 'A second normal launch did not exit.'
    Assert-TrayTest ($duplicate.ExitCode -eq 0) "A second normal launch returned exit code $($duplicate.ExitCode)."
    $duplicate.Dispose()
    $duplicate = $null
    $null = Wait-TrayTest {
        -not (Test-Path -LiteralPath (Join-Path $scratch '.desktop-route.json')) -and
        -not (Test-Path -LiteralPath (Join-Path $scratch '.desktop-route-reading.json'))
    } 'The original process did not consume the second launch activation.'
    Assert-TrayTest ((@(Find-TrayWindows).Count -eq 2) -and (@([GaoCiYuan.Smoke.TrayDesktop]::LoopbackPorts($primary.Id)) -join ',') -eq [string]$port) (
        'A second launch changed the tray window count or loopback binding.'
    )
    Write-Output 'A normal re-launch forwarded activation, exited, and left the original tray pair and port intact.'

    $registration = $native.PSObject.Properties['trayRegistered']
    if ($registration -and -not $registration.Value) {
        $connection = Edit-FixtureDraft
        [GaoCiYuan.Smoke.TrayDesktop]::CloseMain($main.Handle)
        $prompt = Wait-TrayTest { Find-QuitWindow } 'With no tray registration, WM_CLOSE did not request explicit confirmation for the dirty editor.'
        Assert-TrayTest ([GaoCiYuan.Smoke.TrayDesktop]::QuitPromptText($prompt.Handle).Contains($dirtyText)) 'The native quit dialog did not identify unsaved changes.'
        [GaoCiYuan.Smoke.TrayDesktop]::ChooseQuitPrompt($prompt.Handle, $false)
        $null = Wait-TrayTest { -not (Find-QuitWindow) } 'The native cancel action did not close the quit dialog.'
        $window = Find-MainWindow
        Assert-TrayTest ($window -and $window.Handle -eq $main.Handle -and $window.Visible -and -not $primary.HasExited) (
            'Cancelling the no-tray quit prompt did not preserve the main window.'
        )
        Assert-TrayTest ([bool](Invoke-WebViewExpression $connection 'window.gaociyuanExitState().dirty')) 'Cancellation lost the unsaved editor draft.'
        $null = Invoke-TrayApi '/api/state'
        Write-Output 'With no tray registration, WM_CLOSE requested safe quit. Cancel kept the same native window, draft, and listener.'

        $null = Invoke-TrayApi '/api/shutdown' -Post
        $prompt = Wait-TrayTest { Find-QuitWindow } 'The shutdown endpoint did not share the native safe-quit confirmation.'
        [GaoCiYuan.Smoke.TrayDesktop]::ChooseQuitPrompt($prompt.Handle, $true)
        Assert-TrayTest ($primary.WaitForExit(10000)) 'Confirmation did not finish the no-tray quit path.'
        Assert-TrayTest ($primary.ExitCode -eq 0) 'Safe quit returned an error.'
        $null = Wait-TrayTest {
            $activeListeners = @([GaoCiYuan.Smoke.TrayDesktop]::LoopbackPorts(-1))
            $port -notin $activeListeners -and $connection.Port -notin $activeListeners
        } 'Safe quit left the original listener or the isolated WebView2 debugging port running.'
        Assert-TrayTest ($desktop.Windows($primary.Id).Count -eq 0) 'The safe quit left native windows.'
        Assert-TrayTest (-not $RequireTrayMenuExit) 'There was no registered tray on the offscreen desktop, so popup exit could not run.'
        Write-Output 'The shutdown endpoint presented the same safe-quit confirmation. Confirm released the process, HWNDs, app port, and WebView2 fixture port.'
        return
    }

    [GaoCiYuan.Smoke.TrayDesktop]::CloseMain($main.Handle)
    $closeResult = Wait-TrayTest {
        if ($primary.HasExited) { 'exited' }
        else {
            $window = Find-MainWindow
            if ($window -and -not $window.Visible) { 'hidden' }
        }
    } 'WM_CLOSE neither hid nor exited the isolated app.'
    if ($closeResult -eq 'exited') {
        Assert-TrayTest ($shellIcons.Count -eq 0 -and $primary.ExitCode -eq 0) 'The app exited despite a registered tray or returned an error.'
        Assert-TrayTest (-not ([GaoCiYuan.Smoke.TrayDesktop]::LoopbackPorts(-1) -contains $port)) 'The fallback left the loopback port occupied.'
        Assert-TrayTest (-not $RequireTrayMenuExit) 'There was no registered tray on the offscreen desktop, so popup exit could not run.'
        Write-Output 'Native close used the no-tray exit fallback. Callback reopening and popup exit were not exercised.'
        return
    }

    $null = Invoke-TrayApi '/api/state'
    foreach ($window in $trayWindows) { [GaoCiYuan.Smoke.TrayDesktop]::OpenTrayDefault($window.Handle) }
    $null = Wait-TrayTest {
        $window = Find-MainWindow
        $window -and $window.Handle -eq $main.Handle -and $window.Visible
    } 'The native default tray callback did not reopen the same window.'
    Write-Output 'WM_CLOSE hid the main window, the server stayed live, and the native default tray callback restored its HWND.'

    [GaoCiYuan.Smoke.TrayDesktop]::CloseMain($main.Handle)
    $null = Wait-TrayTest { $window = Find-MainWindow; $window -and -not $window.Visible } 'The second WM_CLOSE did not hide the main window.'
    $duplicate = $desktop.Launch($resolved, $scratch)
    Assert-TrayTest ($duplicate.WaitForExit(12000)) 'A normal re-launch did not exit.'
    Assert-TrayTest ($duplicate.ExitCode -eq 0) "A normal re-launch returned exit code $($duplicate.ExitCode)."
    $null = Wait-TrayTest {
        $window = Find-MainWindow
        $window -and $window.Handle -eq $main.Handle -and $window.Visible
    } 'The second launch did not activate the original HWND.'
    Assert-TrayTest ((@(Find-TrayWindows).Count -eq 2) -and (@([GaoCiYuan.Smoke.TrayDesktop]::LoopbackPorts($primary.Id)) -join ',') -eq [string]$port) (
        'A second launch changed the tray window count or loopback binding.'
    )
    Write-Output 'The duplicate normal launch forwarded activation, exited, and left the original tray pair and port intact.'

    foreach ($window in $trayWindows) { [GaoCiYuan.Smoke.TrayDesktop]::OpenTrayMenu($window.Handle) }
    $popup = $null
    try {
        $popup = Wait-TrayTest {
            $desktop.Windows($primary.Id) | Where-Object { $_.Class -eq '#32768' -and $_.Visible } | Select-Object -First 1
        } 'The native tray popup could not be opened on the non-input desktop.' 1800
    } catch {
        Write-Verbose $_.Exception.Message
    }
    $menuExit = $false
    if ($popup) {
        [GaoCiYuan.Smoke.TrayDesktop]::SelectLastMenuItem($popup.Handle)
        $menuExit = $primary.WaitForExit(5000)
    }
    if (-not $menuExit) {
        Assert-TrayTest (-not $RequireTrayMenuExit) 'The native tray menu did not exit the process on the non-input desktop.'
        Write-Output 'Native menu selection was unavailable on the non-input desktop. Using the existing shutdown endpoint to verify teardown.'
        $null = Invoke-TrayApi '/api/shutdown' -Post
        Assert-TrayTest ($primary.WaitForExit(9000)) 'The isolated process did not exit after shutdown.'
    } else { Write-Output 'The native tray Exit menu ended the original process.' }
    Assert-TrayTest ($primary.ExitCode -eq 0) "The isolated process exited with code $($primary.ExitCode)."
    Assert-TrayTest (-not ([GaoCiYuan.Smoke.TrayDesktop]::LoopbackPorts(-1) -contains $port)) 'The original loopback port was still listening.'
    Assert-TrayTest ($desktop.Windows($primary.Id).Count -eq 0) 'The exited process left native windows.'
    Write-Output 'Teardown released the original process, native windows, and its exact loopback port.'
} finally {
    if ($primary -and -not $primary.HasExited -and $token) {
        try {
            $prompt = Find-QuitWindow
            if ($prompt) { [GaoCiYuan.Smoke.TrayDesktop]::ChooseQuitPrompt($prompt.Handle, $true) }
            else { $null = Invoke-TrayApi '/api/shutdown' -Post }
        } catch { Write-Verbose $_.Exception.Message }
    }
    foreach ($process in @($duplicate, $primary)) {
        if (-not $process) { continue }
        if (-not $process.WaitForExit(5000)) {
            $process.Kill($true)
            $null = $process.WaitForExit(5000)
        }
        $process.Dispose()
    }
    if ($desktop) { $desktop.Dispose() }
    Assert-TrayTest ((Split-Path -Parent $scratch) -eq $build -and (Split-Path -Leaf $scratch) -match '^tray-smoke-[0-9a-f]{32}$') (
        'Refusing to clean a path outside the isolated tray smoke directory.'
    )
    if (Test-Path -LiteralPath $scratch) {
        Assert-NoReparsePoints $scratch
        Remove-Item -LiteralPath $scratch -Recurse -Force
    }
}
