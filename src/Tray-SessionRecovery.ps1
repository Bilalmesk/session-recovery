#requires -Version 5.1
<#
    Tray-SessionRecovery.ps1
    Keeps Session Recovery running in the notification area.

    The tray app owns the snapshot timer when Windows Task Scheduler is not
    being used. If a scheduled snapshot task or another watcher is already
    running, it stays in monitor-only mode so snapshots are never duplicated.

    Usage:
      powershell.exe -NoProfile -ExecutionPolicy Bypass -File Tray-SessionRecovery.ps1
      powershell.exe -NoProfile -ExecutionPolicy Bypass -File Tray-SessionRecovery.ps1 -MonitorOnly
#>
[CmdletBinding()]
param(
    [switch]$MonitorOnly,
    [int]$FirstSnapshotDelaySeconds = 10
)

$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'SessionRecovery.psm1'
Import-Module $modulePath -Force -ErrorAction Stop
. (Join-Path $PSScriptRoot 'Strings.ps1')
try {
    $trayLanguage = 'en'
    $trayConfig = Get-SRConfig
    $trayLanguageProperty = $trayConfig.PSObject.Properties['language']
    if ($null -ne $trayLanguageProperty -and -not [string]::IsNullOrWhiteSpace([string]$trayLanguageProperty.Value)) {
        $trayLanguage = [string]$trayLanguageProperty.Value
    }
} catch { $trayLanguage = 'en' }
$script:TrayLang = $trayLanguage
$script:TrayStrings = Get-SRStrings -Language $trayLanguage
function T {
    param([Parameter(Mandatory = $true)][string]$Key, [string]$Default = '')
    if ($script:TrayStrings -and $script:TrayStrings.ContainsKey($Key) -and -not [string]::IsNullOrWhiteSpace([string]$script:TrayStrings[$Key])) {
        return [string]$script:TrayStrings[$Key]
    }
    return $Default
}
try { Write-SRLog -Message 'Tray app booting.' } catch { }
try {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    if ($principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Repair-SRLegacyTasks | Out-Null
    }
} catch { }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

$script:ink = [System.Drawing.Color]::FromArgb(32, 37, 43)
$script:muted = [System.Drawing.Color]::FromArgb(91, 101, 112)
$script:line = [System.Drawing.Color]::FromArgb(224, 229, 233)
$script:soft = [System.Drawing.Color]::FromArgb(244, 246, 248)
$script:accent = [System.Drawing.Color]::FromArgb(41, 79, 130)
$script:white = [System.Drawing.Color]::White

$script:trayMutex = $null
$script:snapshotMutex = $null
$script:notify = $null
$script:menu = $null
$script:snapshotTimer = $null
$script:firstTimer = $null
$script:healthTimer = $null
$script:resumeTimer = $null
$script:appContext = $null
$script:installRoot = $PSScriptRoot
$script:exiting = $false
$script:paused = $false
$script:resumeAt = $null
$script:updatingPauseMenu = $false
$script:snapshotBusy = $false
$script:ownsSnapshots = $false
$script:taskMode = $false
$script:watcherMode = $false
$script:snapshotFailures = 0
$script:intervalMinutes = 3
$script:hostExe = Join-Path $PSScriptRoot 'SessionRecovery.exe'
if (-not (Test-Path -LiteralPath $script:hostExe)) {
    $candidate = Join-Path (Split-Path $PSScriptRoot -Parent) 'dist\SessionRecovery.exe'
    if (Test-Path -LiteralPath $candidate) { $script:hostExe = $candidate }
}

function Test-SRTrayEventSnapshots {
    try {
        $config = Get-SRConfig
        $property = $config.PSObject.Properties['eventSnapshots']
        if ($null -ne $property) { return [bool]$property.Value }
    } catch { }
    return $true
}

function Get-SRTrayIntervalMinutes {
    try {
        $config = Get-SRConfig
        $configured = [int]$config.snapshotIntervalMinutes
        if ($configured -ge 1) { return $configured }
    } catch { }
    return 3
}

function Test-SRScheduledSnapshotTask {
    try {
        $task = Get-ScheduledTask -TaskName 'SessionRecovery-Snapshot' -ErrorAction SilentlyContinue
        if ($null -eq $task) { return $false }
        return ([string]$task.State -ne 'Disabled')
    } catch {
        return $false
    }
}

function Get-SRLastSnapshotInfo {
    try {
        $file = Get-ChildItem -LiteralPath (Get-SRSnapshotDirectory) -Filter 'session-*.json' -File -ErrorAction SilentlyContinue |
            Sort-Object -Property LastWriteTime -Descending |
            Select-Object -First 1
        if ($null -eq $file) { return $null }
        return [pscustomobject]@{
            Path       = $file.FullName
            CapturedAt = $file.LastWriteTime
        }
    } catch {
        return $null
    }
}

function Format-SRTrayAge {
    param([datetime]$CapturedAt)
    $delta = (Get-Date) - $CapturedAt
    if ($delta.TotalMinutes -lt 1) { return 'just now' }
    if ($delta.TotalMinutes -lt 60) { return ('{0:N0} min ago' -f $delta.TotalMinutes) }
    if ($delta.TotalHours -lt 24) { return ('{0:N0} hr ago' -f $delta.TotalHours) }
    return ('{0:N0} day(s) ago' -f $delta.TotalDays)
}

function Get-SRTrayModeText {
    if ($script:paused) {
        if ($null -ne $script:resumeAt) { return ((T 'ModePausedUntil' 'paused until {0}') -f $script:resumeAt.ToString('HH:mm')) }
        return (T 'ModePaused' 'paused')
    }
    if ($script:ownsSnapshots) { return ((T 'ModeEveryMin' 'every {0} min') -f $script:intervalMinutes) }
    if ($script:taskMode) { return (T 'ModeTask' 'scheduled task') }
    if ($script:watcherMode) { return (T 'ModeWatcher' 'watcher active') }
    return (T 'ModeManual' 'manual')
}

function Update-SRTraySettings {
    $newInterval = Get-SRTrayIntervalMinutes
    if ($newInterval -ne $script:intervalMinutes) {
        $script:intervalMinutes = $newInterval
        if ($script:ownsSnapshots -and -not $script:paused) {
            Start-SRTraySnapshotTimer
        }
    }
}

function Update-SRTrayStatus {
    if ($null -eq $script:notify) { return }
    $modeText = Get-SRTrayModeText
    $tooltip = 'Session Recovery - ' + $modeText
    if ($tooltip.Length -gt 63) { $tooltip = $tooltip.Substring(0, 63) }
    $script:notify.Text = $tooltip

    if ($null -ne $script:statusLabel) {
        $script:statusLabel.Text = ((T 'BackgroundStatus' 'Background status: {0}') -f $modeText)
    }

    $last = Get-SRLastSnapshotInfo
    if ($null -ne $script:lastLabel) {
        if ($null -eq $last) {
            $script:lastLabel.Text = (T 'LastSnapshotNone' 'Last snapshot: none yet')
        } else {
            $script:lastLabel.Text = ((T 'LastSnapshotInfo' 'Last snapshot: {0} ({1})') -f $last.CapturedAt.ToString('MMM d, HH:mm'), (Format-SRTrayAge -CapturedAt $last.CapturedAt))
        }
    }

    if ($null -ne $script:pauseItem) {
        $script:pauseItem.Enabled = [bool]$script:ownsSnapshots
        # Setting Checked programmatically raises CheckedChanged. Suppress the
        # handler so a timed pause is not cancelled by its own status update.
        $script:updatingPauseMenu = $true
        try {
            $script:pauseItem.Checked = [bool]$script:paused
        } finally {
            $script:updatingPauseMenu = $false
        }
        $script:pauseItem.Text = if ($script:paused) { (T 'TrayResume' 'Resume snapshots') } else { (T 'TrayPause' 'Pause snapshots') }
    }
    if ($null -ne $script:pauseHourItem) {
        $script:pauseHourItem.Enabled = ([bool]$script:ownsSnapshots -and -not $script:paused)
    }
}

function Show-SRTrayBalloon {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [string]$Title = 'Session Recovery',
        [System.Windows.Forms.ToolTipIcon]$Icon = [System.Windows.Forms.ToolTipIcon]::Info,
        [int]$Timeout = 3000,
        [switch]$Force
    )
    if (-not $Force) {
        try {
            $config = Get-SRConfig
            if (-not [bool]$config.showNotifications) { return }
        } catch { }
    }
    if ($null -eq $script:notify -or -not $script:notify.Visible) { return }
    try {
        $script:notify.BalloonTipTitle = $Title
        $script:notify.BalloonTipText = $Text
        $script:notify.BalloonTipIcon = $Icon
        $script:notify.ShowBalloonTip($Timeout)
    } catch { }
}

function Start-SRTraySnapshotTimer {
    if (-not $script:ownsSnapshots -or $script:paused -or $script:exiting) { return }
    if ($null -eq $script:snapshotTimer) { return }
    $script:snapshotTimer.Stop()
    $script:snapshotTimer.Interval = [Math]::Max(60000, ($script:intervalMinutes * 60000))
    $script:snapshotTimer.Start()
}

function Stop-SRTrayTimers {
    if ($null -ne $script:snapshotTimer) {
        try { $script:snapshotTimer.Stop() } catch { }
    }
    if ($null -ne $script:firstTimer) {
        try { $script:firstTimer.Stop() } catch { }
    }
}

function Invoke-SRTraySnapshot {
    param([switch]$Manual)
    if ($script:snapshotBusy) {
        if ($Manual) { Show-SRTrayBalloon -Text (T 'TrayBalloonBusy' 'A snapshot is already in progress.') -Icon Information }
        return
    }

    $script:snapshotBusy = $true
    try {
        $path = Save-SRSnapshot -Force
        if ($path) {
            $script:snapshotFailures = 0
            if ($Manual) {
                Show-SRTrayBalloon -Text (T 'TrayBalloonSaved' 'Snapshot saved. Your current windows and tabs are protected.') -Icon Information
            }
        } elseif ($Manual) {
            Show-SRTrayBalloon -Text (T 'TrayBalloonSkip' 'The snapshot was skipped because another snapshot is running.') -Icon Warning
        }
    } catch {
        $script:snapshotFailures++
        try { Write-SRLog -Level ERROR -Message "Tray snapshot failed: $($_.Exception.Message)" } catch { }
        if ($Manual -or $script:snapshotFailures -eq 1) {
            Show-SRTrayBalloon -Text ((T 'TrayBalloonFail' 'Snapshot failed: {0}') -f $_.Exception.Message) -Icon Error -Timeout 5000
        }
    } finally {
        $script:snapshotBusy = $false
        Update-SRTrayStatus
    }
}

function Start-SRTrayFirstSnapshot {
    if (-not $script:ownsSnapshots -or $script:paused -or $script:exiting) { return }
    if ($null -eq $script:firstTimer) { return }
    $script:firstTimer.Stop()
    $script:firstTimer.Interval = [Math]::Max(1000, ($FirstSnapshotDelaySeconds * 1000))
    $script:firstTimer.Start()
}

function Resume-SRTraySnapshots {
    $script:paused = $false
    $script:resumeAt = $null
    if ($script:resumeTimer) { $script:resumeTimer.Stop() }
    Update-SRTrayStatus
    if ($script:ownsSnapshots -and -not $script:exiting) {
        Start-SRTrayFirstSnapshot
        Show-SRTrayBalloon -Text (T 'TrayResumed' 'Snapshots resumed.')
    }
}

function Open-SRDataFolder {
    try {
        $root = Get-SRRoot
        if (-not (Test-Path -LiteralPath $root)) { New-Item -ItemType Directory -Path $root -Force | Out-Null }
        Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $root) | Out-Null
    } catch {
        Show-SRTrayBalloon -Text ('Could not open the data folder: ' + $_.Exception.Message) -Icon Error
    }
}

function Open-SRSnapshotsFolder {
    try {
        $folder = Get-SRSnapshotDirectory
        if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
        Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $folder) | Out-Null
    } catch {
        Show-SRTrayBalloon -Text ('Could not open the snapshots folder: ' + $_.Exception.Message) -Icon Error
    }
}

function Start-SRStudio {
    param([string]$Mode = '--studio')
    try {
        if (-not (Test-Path -LiteralPath $script:hostExe)) { throw 'SessionRecovery.exe is missing.' }
        Start-Process -FilePath $script:hostExe -ArgumentList $Mode -WorkingDirectory $PSScriptRoot -WindowStyle Normal | Out-Null
    } catch {
        Show-SRTrayBalloon -Text ('Could not open Session Recovery: ' + $_.Exception.Message) -Icon Error
    }
}

function Open-SRSettingsFile {
    Start-SRStudio -Mode '--settings'
}

function Start-SRRestoreWindow {
    Start-SRStudio -Mode '--restore-manual'
}

function Start-SRDiagnosticsWindow {
    Start-SRStudio -Mode '--diagnostics'
}

function Exit-SRTray {
    if ($script:exiting) { return }
    $script:exiting = $true
    Stop-SRTrayTimers
    if ($null -ne $script:hotkeyTimer) {
        try { $script:hotkeyTimer.Stop(); $script:hotkeyTimer.Dispose() } catch { }
        $script:hotkeyTimer = $null
    }
    if ($null -ne $script:healthTimer) {
        try { $script:healthTimer.Stop(); $script:healthTimer.Dispose() } catch { }
        $script:healthTimer = $null
    }
    if ($null -ne $script:resumeTimer) {
        try { $script:resumeTimer.Stop(); $script:resumeTimer.Dispose() } catch { }
        $script:resumeTimer = $null
    }
    try {
        if ($null -ne $script:notify) {
            $script:notify.Visible = $false
            $script:notify.Dispose()
            $script:notify = $null
        }
    } catch { }
    try {
        if ($null -ne $script:appContext) { $script:appContext.ExitThread() }
        else { [System.Windows.Forms.Application]::Exit() }
    } catch { }
}

# ---------------------------------------------------------------------------
# Single-instance and snapshot ownership
# ---------------------------------------------------------------------------

try {
    $script:trayMutex = New-Object System.Threading.Mutex($false, 'Local\SessionRecoveryTray')
    $haveTrayMutex = $false
    try {
        $haveTrayMutex = $script:trayMutex.WaitOne(0)
    } catch [System.Threading.AbandonedMutexException] {
        $haveTrayMutex = $true
    }
    if (-not $haveTrayMutex) { exit 0 }
} catch {
    $script:trayMutex = $null
}

$script:intervalMinutes = Get-SRTrayIntervalMinutes
$script:taskMode = Test-SRScheduledSnapshotTask
try { Write-SRLog -Message ('Tray mode check: interval {0}, task mode {1}, monitor-only {2}.' -f $script:intervalMinutes, $script:taskMode, $MonitorOnly) } catch { }

if (-not $MonitorOnly -and -not $script:taskMode) {
    try {
        $script:snapshotMutex = New-Object System.Threading.Mutex($false, 'Local\SessionRecoveryWatcher')
        $acquired = $false
        try {
            $acquired = $script:snapshotMutex.WaitOne(0)
        } catch [System.Threading.AbandonedMutexException] {
            $acquired = $true
        }
        if ($acquired) {
            $script:ownsSnapshots = $true
        } else {
            $script:watcherMode = $true
            try { $script:snapshotMutex.Dispose() } catch { }
            $script:snapshotMutex = $null
        }
    } catch {
        # If the mutex cannot be created, fall back to monitor-only rather
        # than risk two snapshot loops.
        $script:snapshotMutex = $null
        $script:watcherMode = $true
    }
}

# ---------------------------------------------------------------------------
# Tray icon and menu
# ---------------------------------------------------------------------------

$iconPath = Join-Path $PSScriptRoot 'SessionRecovery.ico'
if (-not (Test-Path -LiteralPath $iconPath)) {
    $fallback = Join-Path (Split-Path $PSScriptRoot -Parent) 'assets\SessionRecovery.ico'
    if (Test-Path -LiteralPath $fallback) { $iconPath = $fallback } else { $iconPath = $null }
}

$trayIcon = $null
if ($iconPath) {
    try { $trayIcon = New-Object System.Drawing.Icon($iconPath) } catch { $trayIcon = $null }
}

$script:notify = New-Object System.Windows.Forms.NotifyIcon
$script:notify.Text = 'Session Recovery'
$script:notify.Visible = $true
if ($null -ne $trayIcon) { $script:notify.Icon = $trayIcon }

$script:menu = New-Object System.Windows.Forms.ContextMenuStrip
$script:menu.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$script:menu.BackColor = $script:white
$script:menu.ForeColor = $script:ink
$script:menu.ShowImageMargin = $false
$script:menu.ShowCheckMargin = $true
$script:menu.Padding = New-Object System.Windows.Forms.Padding(4, 6, 4, 6)
$script:menu.RenderMode = [System.Windows.Forms.ToolStripRenderMode]::Professional
$script:notify.ContextMenuStrip = $script:menu

$headerLabel = New-Object System.Windows.Forms.ToolStripLabel('SESSION RECOVERY')
$headerLabel.AutoSize = $false
$headerLabel.Width = 268
$headerLabel.Height = 24
$headerLabel.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9.5)
$headerLabel.ForeColor = $script:accent
$headerLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$headerLabel.Padding = New-Object System.Windows.Forms.Padding(2, 2, 2, 0)
[void]$script:menu.Items.Add($headerLabel)

$script:statusLabel = New-Object System.Windows.Forms.ToolStripLabel
$script:statusLabel.AutoSize = $false
$script:statusLabel.Width = 268
$script:statusLabel.Height = 19
$script:statusLabel.Font = New-Object System.Drawing.Font('Segoe UI', 8.25)
$script:statusLabel.ForeColor = $script:muted
$script:statusLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$script:statusLabel.Padding = New-Object System.Windows.Forms.Padding(2, 0, 2, 0)
[void]$script:menu.Items.Add($script:statusLabel)

$script:lastLabel = New-Object System.Windows.Forms.ToolStripLabel
$script:lastLabel.AutoSize = $false
$script:lastLabel.Width = 268
$script:lastLabel.Height = 19
$script:lastLabel.Font = New-Object System.Drawing.Font('Consolas', 7.75)
$script:lastLabel.ForeColor = $script:muted
$script:lastLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$script:lastLabel.Padding = New-Object System.Windows.Forms.Padding(2, 0, 2, 2)
[void]$script:menu.Items.Add($script:lastLabel)

[void]$script:menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$studioItem = New-Object System.Windows.Forms.ToolStripMenuItem((T 'TrayOpen' 'Open Session Recovery'))
$studioItem.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9)
[void]$studioItem.Add_Click({ Start-SRStudio })
[void]$script:menu.Items.Add($studioItem)

$restoreItem = New-Object System.Windows.Forms.ToolStripMenuItem((T 'TrayRestore' 'Restore last session...'))
$restoreItem.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9)
[void]$restoreItem.Add_Click({ Start-SRRestoreWindow })
[void]$script:menu.Items.Add($restoreItem)

$snapshotItem = New-Object System.Windows.Forms.ToolStripMenuItem((T 'TraySnapshotNow' 'Take snapshot now'))
[void]$snapshotItem.Add_Click({ Invoke-SRTraySnapshot -Manual })
[void]$script:menu.Items.Add($snapshotItem)

# Named workspaces: manually saved sessions that restore in one click.
$workspaceMenu = New-Object System.Windows.Forms.ToolStripMenuItem((T 'TrayWorkspaces' 'Workspaces'))
[void]$workspaceMenu.Add_DropDownOpening({
    $workspaceMenu.DropDownItems.Clear()
    $saveItem = New-Object System.Windows.Forms.ToolStripMenuItem((T 'TraySaveWorkspace' 'Save current session as...'))
    [void]$saveItem.Add_Click({
        $name = ''
        try {
            Add-Type -AssemblyName Microsoft.VisualBasic
            $name = [Microsoft.VisualBasic.Interaction]::InputBox((T 'TrayWorkspacePrompt' 'Name this workspace'), 'Session Recovery', '')
        } catch { return }
        if ([string]::IsNullOrWhiteSpace($name)) { return }
        try {
            [void](Save-SRSnapshot -Force)
            [void](Save-SRWorkspace -Name $name)
            Show-SRTrayBalloon -Text ((T 'TrayWorkspaceSaved' 'Workspace "{0}" saved.') -f $name) -Icon Information
        } catch {
            Show-SRTrayBalloon -Text ((T 'TrayWorkspaceFail' 'Could not save the workspace: {0}') -f $_.Exception.Message) -Icon Error
        }
    })
    [void]$workspaceMenu.DropDownItems.Add($saveItem)
    $saved = @(Get-SRWorkspaces)
    if ($saved.Count -gt 0) {
        [void]$workspaceMenu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
        foreach ($workspace in $saved) {
            $item = New-Object System.Windows.Forms.ToolStripMenuItem($workspace.Name)
            $item.Tag = $workspace.Path
            [void]$item.Add_Click({
                param($sender, $eventArgs)
                Start-SRStudio -Mode ('--restore-manual -SnapshotPath "' + ([string]$sender.Tag).Replace('"', '""') + '"')
            })
            [void]$workspaceMenu.DropDownItems.Add($item)
        }
    }
})
[void]$script:menu.Items.Add($workspaceMenu)

$script:pauseItem = New-Object System.Windows.Forms.ToolStripMenuItem((T 'TrayPause' 'Pause snapshots'))
$script:pauseItem.CheckOnClick = $true
[void]$script:pauseItem.Add_CheckedChanged({
    if ($script:updatingPauseMenu) { return }
    $script:paused = [bool]$script:pauseItem.Checked
    if ($script:paused) {
        Stop-SRTrayTimers
        $script:resumeAt = $null
        if ($script:resumeTimer) { $script:resumeTimer.Stop() }
        Update-SRTrayStatus
    } else {
        # Unchecking Pause also cancels a timed pause and its resume timer.
        Resume-SRTraySnapshots
    }
})
[void]$script:menu.Items.Add($script:pauseItem)

$script:pauseHourItem = New-Object System.Windows.Forms.ToolStripMenuItem((T 'TrayPauseHour' 'Pause for 1 hour'))
[void]$script:pauseHourItem.Add_Click({
    if (-not $script:ownsSnapshots) { return }
    $script:paused = $true
    Stop-SRTrayTimers
    $script:resumeAt = (Get-Date).AddHours(1)
    if ($null -eq $script:resumeTimer) {
        $script:resumeTimer = New-Object System.Windows.Forms.Timer
        [void]$script:resumeTimer.Add_Tick({
            $script:resumeTimer.Stop()
            Resume-SRTraySnapshots
        })
    }
    $remaining = [int]($script:resumeAt - (Get-Date)).TotalMilliseconds
    $script:resumeTimer.Interval = [Math]::Max(1000, $remaining)
    $script:resumeTimer.Stop()
    $script:resumeTimer.Start()
    Update-SRTrayStatus
    Show-SRTrayBalloon -Text ((T 'TrayPausedUntil' 'Snapshots paused until {0}. They resume automatically.') -f $script:resumeAt.ToString('HH:mm'))
})
[void]$script:menu.Items.Add($script:pauseHourItem)

[void]$script:menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$folderItem = New-Object System.Windows.Forms.ToolStripMenuItem((T 'TrayOpenFolder' 'Open snapshots folder'))
[void]$folderItem.Add_Click({ Open-SRSnapshotsFolder })
[void]$script:menu.Items.Add($folderItem)

$settingsItem = New-Object System.Windows.Forms.ToolStripMenuItem((T 'TraySettings' 'Settings'))
[void]$settingsItem.Add_Click({ Open-SRSettingsFile })
[void]$script:menu.Items.Add($settingsItem)

$diagnosticsItem = New-Object System.Windows.Forms.ToolStripMenuItem((T 'TrayDiagnostics' 'Run diagnostics'))
[void]$diagnosticsItem.Add_Click({ Start-SRDiagnosticsWindow })
[void]$script:menu.Items.Add($diagnosticsItem)

[void]$script:menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$exitItem = New-Object System.Windows.Forms.ToolStripMenuItem((T 'TrayExit' 'Exit Session Recovery'))
[void]$exitItem.Add_Click({ Exit-SRTray })
[void]$script:menu.Items.Add($exitItem)

[void]$script:menu.Add_Opening({
    Update-SRTraySettings
    Update-SRTrayStatus
})
$script:notify.Add_MouseClick({
    param($sender, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Start-SRStudio }
})

# ---------------------------------------------------------------------------
# Timers and power events
# ---------------------------------------------------------------------------

$script:snapshotTimer = New-Object System.Windows.Forms.Timer
$script:snapshotTimer.Interval = [Math]::Max(60000, ($script:intervalMinutes * 60000))
[void]$script:snapshotTimer.Add_Tick({
    Update-SRTraySettings
    if ($script:paused -or -not $script:ownsSnapshots) { return }
    Invoke-SRTraySnapshot
    Start-SRTraySnapshotTimer
})

$script:firstTimer = New-Object System.Windows.Forms.Timer
$script:firstTimer.Interval = [Math]::Max(1000, ($FirstSnapshotDelaySeconds * 1000))
[void]$script:firstTimer.Add_Tick({
    $script:firstTimer.Stop()
    if ($script:paused -or -not $script:ownsSnapshots) { return }
    Invoke-SRTraySnapshot
    Start-SRTraySnapshotTimer
})

# Exit quietly if the installed files disappear (for example, the MSI was
# uninstalled while the tray app was still running).
$script:healthTimer = New-Object System.Windows.Forms.Timer
$script:healthTimer.Interval = 10000
[void]$script:healthTimer.Add_Tick({
    if ($script:exiting) { return }
    $trayScript = Join-Path $script:installRoot 'Tray-SessionRecovery.ps1'
    $module = Join-Path $script:installRoot 'SessionRecovery.psm1'
    if (-not (Test-Path -LiteralPath $trayScript) -or -not (Test-Path -LiteralPath $module) -or -not (Test-Path -LiteralPath $script:hostExe)) {
        Exit-SRTray
    }
})
$script:healthTimer.Start()

# Global capture hotkey Ctrl+Alt+S. RegisterHotKey needs its own message
# window, so this polls the async key state instead: simple and reliable in
# a PowerShell host. The latch makes the combination fire once per press.
try {
    if (-not ('SessionRecovery.Tray.HotkeyPoll' -as [type])) {
        Add-Type -Namespace SessionRecovery.Tray -Name HotkeyPoll -MemberDefinition '[DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);'
    }
    $script:hotkeyAvailable = $true
} catch { $script:hotkeyAvailable = $false }
$script:hotkeyLatch = $false
$script:hotkeyTimer = New-Object System.Windows.Forms.Timer
$script:hotkeyTimer.Interval = 250
[void]$script:hotkeyTimer.Add_Tick({
    if (-not $script:hotkeyAvailable -or $script:exiting) { return }
    $pressed = $false
    try {
        $ctrl = ([SessionRecovery.Tray.HotkeyPoll]::GetAsyncKeyState(0x11) -band 0x8000) -ne 0
        $alt = ([SessionRecovery.Tray.HotkeyPoll]::GetAsyncKeyState(0x12) -band 0x8000) -ne 0
        $s = ([SessionRecovery.Tray.HotkeyPoll]::GetAsyncKeyState(0x53) -band 0x8000) -ne 0
        $pressed = ($ctrl -and $alt -and $s)
    } catch { }
    if ($pressed -and -not $script:hotkeyLatch) {
        $script:hotkeyLatch = $true
        $enabled = $true
        try {
            $hotkeyConfig = Get-SRConfig
            $hotkeyProperty = $hotkeyConfig.PSObject.Properties['captureHotkey']
            if ($null -ne $hotkeyProperty) { $enabled = [bool]$hotkeyProperty.Value }
        } catch { }
        if ($enabled -and -not $script:paused) {
            Invoke-SRTraySnapshot -Manual
        }
    } elseif (-not $pressed) {
        $script:hotkeyLatch = $false
    }
})
$script:hotkeyTimer.Start()

# Low battery: capture once when the charge first drops to the low band.
$script:batteryTimer = New-Object System.Windows.Forms.Timer
$script:batteryTimer.Interval = 60000
$script:batteryLowSeen = $false
[void]$script:batteryTimer.Add_Tick({
    if ($script:exiting) { return }
    try {
        $power = [System.Windows.Forms.SystemInformation]::PowerStatus
        if ($power.PowerLineStatus -eq [System.Windows.Forms.PowerLineStatus]::Online) {
            $script:batteryLowSeen = $false
            return
        }
        $low = ($power.BatteryChargeStatus -band [System.Windows.Forms.BatteryChargeStatus]::Low) -ne 0
        $critical = ($power.BatteryChargeStatus -band [System.Windows.Forms.BatteryChargeStatus]::Critical) -ne 0
        if (($low -or $critical) -and -not $script:batteryLowSeen) {
            $script:batteryLowSeen = $true
            if ((Test-SRTrayEventSnapshots) -and $script:ownsSnapshots -and -not $script:paused) {
                Invoke-SRTraySnapshot
            }
        }
        if (-not $low -and -not $critical -and [double]$power.BatteryLifePercent -gt 0.35) {
            $script:batteryLowSeen = $false
        }
    } catch { }
})
$script:batteryTimer.Start()

try {
    [Microsoft.Win32.SystemEvents]::PowerModeChanged += {
        param($sender, $e)
        if ($e.Mode -eq [Microsoft.Win32.PowerModes]::Resume) {
            # A resume is a likely crash moment on laptops: capture once the
            # desktop is back, then let the timer continue.
            if ((Test-SRTrayEventSnapshots) -and $script:ownsSnapshots -and -not $script:paused) {
                Stop-SRTrayTimers
                $script:firstTimer.Interval = 15000
                $script:firstTimer.Start()
            }
        }
        if ($e.Mode -eq [Microsoft.Win32.PowerModes]::Suspend) {
            # Capture right before sleep: this is the snapshot that matters
            # when the battery dies or the machine never wakes up.
            if ((Test-SRTrayEventSnapshots) -and $script:ownsSnapshots -and -not $script:paused) {
                Invoke-SRTraySnapshot
            }
        }
    }
} catch { }

try {
    [Microsoft.Win32.SystemEvents]::SessionSwitch += {
        param($sender, $e)
        if ($e.Reason -eq [Microsoft.Win32.SessionSwitchReason]::SessionLock) {
            # Locking is the most reliable 'walked away / end of session'
            # signal Windows gives without admin rights.
            if ((Test-SRTrayEventSnapshots) -and -not $script:paused) {
                Invoke-SRTraySnapshot
            }
        }
    }
} catch { }

try {
    [Microsoft.Win32.SystemEvents]::SessionEnding += {
        param($sender, $e)
        Exit-SRTray
    }
} catch { }

try {
    Write-SRLog -Message ('Tray app started (owns snapshots: {0}, scheduled task: {1}, monitor-only: {2}).' -f $script:ownsSnapshots, $script:taskMode, $MonitorOnly)
} catch { }

Update-SRTrayStatus
if ($script:ownsSnapshots) {
    Start-SRTrayFirstSnapshot
    Show-SRTrayBalloon -Text (T 'TrayStarted' 'Session Recovery is running in the background. Double-click the tray icon to restore a session.')
} else {
    Show-SRTrayBalloon -Text ((T 'TrayStarted' 'Session Recovery is running in the background. Double-click the tray icon to restore a session.') + ' [' + (Get-SRTrayModeText) + ']')
}

$script:appContext = New-Object System.Windows.Forms.ApplicationContext
try {
    [System.Windows.Forms.Application]::Run($script:appContext)
} finally {
    try {
        if ($null -ne $script:snapshotMutex) {
            try { [void]$script:snapshotMutex.ReleaseMutex() } catch { }
            $script:snapshotMutex.Dispose()
        }
    } catch { }
    try {
        if ($null -ne $script:trayMutex) {
            try { [void]$script:trayMutex.ReleaseMutex() } catch { }
            $script:trayMutex.Dispose()
        }
    } catch { }
    try {
        if ($null -ne $script:notify) { $script:notify.Dispose() }
    } catch { }
    try { if ($null -ne $trayIcon) { $trayIcon.Dispose() } } catch { }
    try { Write-SRLog -Message 'Tray app stopped.' } catch { }
}
