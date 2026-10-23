#requires -Version 5.1
<#
    Studio-SessionRecovery.ps1
    Session Recovery 2.1 control center.

    This script is normally launched by SessionRecovery.exe, the native GUI
    host. The host runs this file in-process on an STA thread, so there is no
    console window, no cmd.exe flash and no visible PowerShell host.
#>
[CmdletBinding()]
param(
    [ValidateSet('Dashboard', 'Snapshots', 'Exclusions', 'Settings', 'Diagnostics', 'About')]
    [string]$Page = 'Dashboard',
    [string]$RenderDir = ''
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$script:AppVersion = '2.1.0'
$script:ScriptDir = $PSScriptRoot
$script:AppDir = if ($env:SESSIONRECOVERY_HOST_EXE) { Split-Path -Parent $env:SESSIONRECOVERY_HOST_EXE } else { $PSScriptRoot }
$script:HostExe = $null
$script:IconPath = $null
$script:Config = $null
$script:Snapshots = @()
$script:SelectedSnapshotPath = $null
$script:Pages = [ordered]@{}
$script:NavButtons = @{}
$script:Ui = @{}
$script:UiReady = $false
$script:CurrentPage = 'Dashboard'
$script:SettingsLoaded = $false
$script:ExclusionCards = @()
$script:SnapshotRows = @()
$script:ToastTimer = $null
$script:SnapshotsDirty = $true
$script:DashboardDirty = $true
$script:ExclusionsDirty = $true
$script:DiagnosticsDirty = $true
$script:DiagnosticsLoading = $false
$script:PageLoaded = @{}
$script:LastSnapFlowWidth = 0
$script:SnapshotBuildTimer = $null
$script:SnapshotDetailsTimer = $null
$script:SnapshotBuildQueue = @()
$script:SnapshotBuildIndex = 0
$script:SnapshotBuildWidth = 0
$script:StudioJobs = @{}
$script:StudioTaskTimer = $null
$script:UpdateBusy = $false
$script:UpdateAction = ''
$script:AvailableUpdate = $null
$script:DownloadedUpdate = $null
$script:UpdateInstalling = $false

$script:P = @{
    Bg          = [System.Drawing.Color]::FromArgb(8, 12, 18)
    Sidebar     = [System.Drawing.Color]::FromArgb(11, 16, 24)
    Card        = [System.Drawing.Color]::FromArgb(18, 25, 36)
    CardAlt     = [System.Drawing.Color]::FromArgb(14, 20, 30)
    CardHover   = [System.Drawing.Color]::FromArgb(26, 36, 51)
    Border      = [System.Drawing.Color]::FromArgb(34, 45, 61)
    BorderSoft  = [System.Drawing.Color]::FromArgb(26, 35, 48)
    Text        = [System.Drawing.Color]::FromArgb(238, 244, 252)
    Muted       = [System.Drawing.Color]::FromArgb(130, 145, 165)
    Subtle      = [System.Drawing.Color]::FromArgb(96, 112, 133)
    Accent      = [System.Drawing.Color]::FromArgb(108, 99, 255)
    Accent2     = [System.Drawing.Color]::FromArgb(51, 181, 229)
    AccentSoft  = [System.Drawing.Color]::FromArgb(31, 31, 61)
    Green       = [System.Drawing.Color]::FromArgb(83, 221, 151)
    GreenSoft   = [System.Drawing.Color]::FromArgb(25, 51, 42)
    Amber       = [System.Drawing.Color]::FromArgb(244, 184, 96)
    AmberSoft   = [System.Drawing.Color]::FromArgb(56, 43, 25)
    Red         = [System.Drawing.Color]::FromArgb(255, 107, 129)
    RedSoft     = [System.Drawing.Color]::FromArgb(61, 29, 38)
    White       = [System.Drawing.Color]::White
}

$modulePath = Join-Path $PSScriptRoot 'SessionRecovery.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    $modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'src\SessionRecovery.psm1'
}
if (-not (Test-Path -LiteralPath $modulePath)) {
    [System.Windows.Forms.MessageBox]::Show('SessionRecovery.psm1 is missing. Reinstall Session Recovery.', 'Session Recovery', 'OK', 'Error') | Out-Null
    exit 2
}
Import-Module $modulePath -Force

$controlsPath = Join-Path $PSScriptRoot 'StudioControls.cs'
if (-not (Test-Path -LiteralPath $controlsPath)) {
    $controlsPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'src\StudioControls.cs'
}
if (-not (Test-Path -LiteralPath $controlsPath)) {
    [System.Windows.Forms.MessageBox]::Show('StudioControls.cs is missing. Reinstall Session Recovery.', 'Session Recovery', 'OK', 'Error') | Out-Null
    exit 2
}
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
if (-not ('SessionRecovery.Studio.StudioCard' -as [type])) {
    Add-Type -Path $controlsPath -ReferencedAssemblies 'System.Windows.Forms', 'System.Drawing'
}

$hostCandidates = @()
if ($env:SESSIONRECOVERY_HOST_EXE) { $hostCandidates += $env:SESSIONRECOVERY_HOST_EXE }
$hostCandidates += (Join-Path $PSScriptRoot 'SessionRecovery.exe')
$hostCandidates += (Join-Path (Split-Path $PSScriptRoot -Parent) 'dist\SessionRecovery.exe')
$script:HostExe = $hostCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

$iconCandidates = @(
    (Join-Path $PSScriptRoot 'SessionRecovery.ico'),
    (Join-Path (Split-Path $PSScriptRoot -Parent) 'assets\SessionRecovery.ico')
)
$script:IconPath = $iconCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

if ($script:HostExe) {
    try {
        $fileVersion = (Get-Item -LiteralPath $script:HostExe).VersionInfo.FileVersion
        if (-not [string]::IsNullOrWhiteSpace($fileVersion)) {
            $match = [regex]::Match($fileVersion, '^\d+\.\d+\.\d+')
            if ($match.Success) { $script:AppVersion = $match.Value } else { $script:AppVersion = $fileVersion }
        }
    } catch { }
}

$script:FontBody = New-Object System.Drawing.Font('Segoe UI', 9)
$script:FontBodySmall = New-Object System.Drawing.Font('Segoe UI', 8.25)
$script:FontSemibold = New-Object System.Drawing.Font('Segoe UI Semibold', 9.5)
$script:FontSemiboldLarge = New-Object System.Drawing.Font('Segoe UI Semibold', 12)
$script:FontTitle = New-Object System.Drawing.Font('Segoe UI Semibold', 19)
$script:FontHero = New-Object System.Drawing.Font('Segoe UI Semibold', 25)
$script:FontMono = New-Object System.Drawing.Font('Consolas', 8.25)

[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

# ---------------------------------------------------------------------------
# Small UI helpers
# ---------------------------------------------------------------------------

function New-StudioLabel {
    param(
        [string]$Text = '',
        [int]$X = 0,
        [int]$Y = 0,
        [int]$Width = 200,
        [int]$Height = 20,
        [System.Drawing.Font]$Font = $null,
        [System.Drawing.Color]$Color = [System.Drawing.Color]::Empty,
        [string]$Align = 'MiddleLeft',
        [bool]$AutoSize = $false
    )
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.Location = New-Object System.Drawing.Point($X, $Y)
    $label.Size = New-Object System.Drawing.Size($Width, $Height)
    $label.Font = if ($null -ne $Font) { $Font } else { $script:FontBody }
    $label.ForeColor = if (-not $Color.IsEmpty) { $Color } else { $script:P.Text }
    $label.BackColor = [System.Drawing.Color]::Transparent
    $label.TextAlign = [System.Drawing.ContentAlignment]$Align
    $label.AutoSize = $AutoSize
    return $label
}

function New-StudioCard {
    param(
        [int]$X = 0,
        [int]$Y = 0,
        [int]$Width = 300,
        [int]$Height = 120,
        [System.Drawing.Color]$Fill = [System.Drawing.Color]::Empty,
        [System.Drawing.Color]$Border = [System.Drawing.Color]::Empty,
        [int]$Radius = 14
    )
    $card = New-Object SessionRecovery.Studio.StudioCard
    $card.Location = New-Object System.Drawing.Point($X, $Y)
    $card.Size = New-Object System.Drawing.Size($Width, $Height)
    $card.FillColor = if (-not $Fill.IsEmpty) { $Fill } else { $script:P.Card }
    $card.BorderColor = if (-not $Border.IsEmpty) { $Border } else { $script:P.Border }
    $card.CanvasColor = $script:P.Bg
    $card.CornerRadius = $Radius
    return $card
}

function New-StudioButton {
    param(
        [string]$Text = '',
        [int]$X = 0,
        [int]$Y = 0,
        [int]$Width = 120,
        [int]$Height = 36,
        [switch]$Primary,
        [switch]$Danger,
        [string]$Glyph = ''
    )
    $button = New-Object SessionRecovery.Studio.StudioButton
    $button.Text = $Text
    $button.Location = New-Object System.Drawing.Point($X, $Y)
    $button.Size = New-Object System.Drawing.Size($Width, $Height)
    $button.CornerRadius = 9
    $button.Glyph = $Glyph
    if ($Primary) {
        $button.FillColor = $script:P.Accent
        $button.GradientEndColor = $script:P.Accent2
        $button.HoverColor = [System.Drawing.Color]::FromArgb(124, 117, 255)
        $button.PressedColor = [System.Drawing.Color]::FromArgb(84, 76, 214)
        $button.TextColor = $script:P.White
        $button.OutlineColor = [System.Drawing.Color]::Empty
    } elseif ($Danger) {
        $button.FillColor = $script:P.RedSoft
        $button.GradientEndColor = $script:P.RedSoft
        $button.HoverColor = [System.Drawing.Color]::FromArgb(84, 36, 49)
        $button.PressedColor = [System.Drawing.Color]::FromArgb(70, 30, 41)
        $button.TextColor = $script:P.Red
        $button.OutlineColor = [System.Drawing.Color]::FromArgb(92, 48, 62)
    } else {
        $button.FillColor = $script:P.CardAlt
        $button.GradientEndColor = [System.Drawing.Color]::Empty
        $button.HoverColor = $script:P.CardHover
        $button.PressedColor = [System.Drawing.Color]::FromArgb(22, 30, 43)
        $button.TextColor = $script:P.Text
        $button.OutlineColor = $script:P.Border
    }
    return $button
}

function New-StudioToggle {
    param([int]$X = 0, [int]$Y = 0, [bool]$Checked = $false)
    $toggle = New-Object SessionRecovery.Studio.StudioToggle
    $toggle.Location = New-Object System.Drawing.Point($X, $Y)
    $toggle.Checked = $Checked
    $toggle.OnColor = $script:P.Accent
    $toggle.OffColor = [System.Drawing.Color]::FromArgb(45, 55, 70)
    return $toggle
}

function New-StudioBadge {
    param(
        [string]$Text = '',
        [int]$Width = 100,
        [int]$Height = 24,
        [System.Drawing.Color]$Fill = [System.Drawing.Color]::Empty,
        [System.Drawing.Color]$TextColor = [System.Drawing.Color]::Empty
    )
    $badge = New-Object SessionRecovery.Studio.StudioBadge
    $badge.Text = $Text
    $badge.Size = New-Object System.Drawing.Size($Width, $Height)
    $badge.FillColor = if (-not $Fill.IsEmpty) { $Fill } else { $script:P.GreenSoft }
    $badge.TextColor = if (-not $TextColor.IsEmpty) { $TextColor } else { $script:P.Green }
    return $badge
}

function New-StudioTextBox {
    param([int]$X = 0, [int]$Y = 0, [int]$Width = 220, [int]$Height = 28)
    $box = New-Object System.Windows.Forms.TextBox
    $box.Location = New-Object System.Drawing.Point($X, $Y)
    $box.Size = New-Object System.Drawing.Size($Width, $Height)
    $box.BackColor = $script:P.CardAlt
    $box.ForeColor = $script:P.Text
    $box.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $box.Font = $script:FontBody
    return $box
}

function New-StudioCombo {
    param([int]$X = 0, [int]$Y = 0, [int]$Width = 200)
    $combo = New-Object SessionRecovery.Studio.StudioComboBox
    $combo.Location = New-Object System.Drawing.Point($X, $Y)
    $combo.Size = New-Object System.Drawing.Size($Width, 28)
    return $combo
}

function Set-StudioStatus {
    param([string]$Text, [System.Drawing.Color]$Color = [System.Drawing.Color]::Empty)
    if ($script:Ui.StatusLabel) {
        $script:Ui.StatusLabel.Text = $Text
        $script:Ui.StatusLabel.ForeColor = if (-not $Color.IsEmpty) { $Color } else { $script:P.Muted }
        $script:Ui.StatusLabel.Visible = -not [string]::IsNullOrWhiteSpace($Text)
    }
}

function Show-StudioToast {
    param([string]$Text, [System.Drawing.Color]$Color = [System.Drawing.Color]::Empty)
    if (-not $script:Ui.Toast) { return }
    $script:Ui.Toast.Text = $Text
    $script:Ui.Toast.ForeColor = if (-not $Color.IsEmpty) { $Color } else { $script:P.Green }
    $script:Ui.Toast.Visible = $true
    if ($null -eq $script:ToastTimer) {
        $script:ToastTimer = New-Object System.Windows.Forms.Timer
        $script:ToastTimer.Interval = 4200
        $script:ToastTimer.Add_Tick({
            $script:ToastTimer.Stop()
            if ($script:Ui.Toast) { $script:Ui.Toast.Visible = $false }
        })
    }
    $script:ToastTimer.Stop()
    $script:ToastTimer.Start()
}

function Format-StudioAge {
    param([datetime]$CapturedAt)
    $span = (Get-Date) - $CapturedAt
    if ($span.TotalSeconds -lt 45) { return 'just now' }
    if ($span.TotalMinutes -lt 60) { return ('{0} min ago' -f [Math]::Max(1, [int]$span.TotalMinutes)) }
    if ($span.TotalHours -lt 24) { return ('{0} hr ago' -f [Math]::Max(1, [int]$span.TotalHours)) }
    if ($span.TotalDays -lt 7) { return ('{0} day(s) ago' -f [Math]::Max(1, [int]$span.TotalDays)) }
    return $CapturedAt.ToString('MMM d, HH:mm')
}

function Format-StudioNext {
    $config = $script:Config
    if ($null -eq $config) { return 'waiting for settings' }
    $interval = [Math]::Max(1, [int]$config.snapshotIntervalMinutes)
    if ($script:Snapshots.Count -eq 0) { return 'within a few minutes' }
    $latest = $script:Snapshots[0].CapturedAt
    $next = $latest.AddMinutes($interval)
    $remaining = $next - (Get-Date)
    if ($remaining.TotalSeconds -le 0) { return 'any moment' }
    if ($remaining.TotalMinutes -lt 1) { return ('in {0} sec' -f [Math]::Max(1, [int]$remaining.TotalSeconds)) }
    return ('in {0} min' -f [Math]::Max(1, [int]$remaining.TotalMinutes))
}

function Format-StudioBytes {
    param([int64]$Bytes)
    if ($Bytes -lt 1024) { return ('{0} B' -f $Bytes) }
    if ($Bytes -lt 1048576) { return ('{0:N1} KB' -f ($Bytes / 1024.0)) }
    return ('{0:N1} MB' -f ($Bytes / 1048576.0))
}

function Enable-StudioDoubleBuffer {
    param($Control)
    if ($null -eq $Control) { return }
    try {
        $type = $Control.GetType()
        while ($null -ne $type) {
            $property = $type.GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'Instance,NonPublic')
            if ($null -ne $property) {
                $property.SetValue($Control, $true, $null)
                return
            }
            $type = $type.BaseType
        }
    } catch { }
}

function Stop-StudioWorker {
    param([string]$Name)
    if (-not $script:StudioJobs.ContainsKey($Name)) { return }
    $job = $script:StudioJobs[$Name]
    try { if ($null -ne $job.PowerShell) { $job.PowerShell.Stop(); $job.PowerShell.Dispose() } } catch { }
    try { if ($null -ne $job.Runspace) { $job.Runspace.Close(); $job.Runspace.Dispose() } } catch { }
    $script:StudioJobs.Remove($Name)
}

function Start-StudioWorker {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Script,
        [object[]]$Arguments = @()
    )
    Stop-StudioWorker -Name $Name
    $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = [System.Threading.ApartmentState]::MTA
    $runspace.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
    $runspace.Open()
    $powershell = [System.Management.Automation.PowerShell]::Create()
    $powershell.Runspace = $runspace
    [void]$powershell.AddScript([string]$Script)
    foreach ($argument in $Arguments) { [void]$powershell.AddArgument($argument) }
    $handle = $powershell.BeginInvoke()
    $script:StudioJobs[$Name] = [pscustomobject]@{
        PowerShell = $powershell
        Runspace   = $runspace
        Handle     = $handle
    }
}

function Complete-StudioWorker {
    param([string]$Name)
    if (-not $script:StudioJobs.ContainsKey($Name)) { return $null }
    $job = $script:StudioJobs[$Name]
    if (-not $job.Handle.IsCompleted) { return $null }
    $output = @()
    $errorText = ''
    try {
        $output = @($job.PowerShell.EndInvoke($job.Handle))
        if ($job.PowerShell.Streams.Error.Count -gt 0) {
            $errorText = (@($job.PowerShell.Streams.Error | ForEach-Object { $_.ToString() }) -join "`r`n")
        }
    } catch {
        $errorText = $_.Exception.Message
    } finally {
        try { $job.PowerShell.Dispose() } catch { }
        try { $job.Runspace.Close(); $job.Runspace.Dispose() } catch { }
        $script:StudioJobs.Remove($Name)
    }
    return [pscustomobject]@{ Output = $output; Error = $errorText }
}

function Update-StudioWorkers {
    $completed = @()
    foreach ($name in @($script:StudioJobs.Keys)) {
        $result = Complete-StudioWorker -Name $name
        if ($null -ne $result) { $completed += [pscustomobject]@{ Name = $name; Result = $result } }
    }
    foreach ($item in $completed) {
        switch ($item.Name) {
            'Diagnostics' { Complete-StudioDiagnosticsWorker -Result $item.Result }
            'Update' { Complete-StudioUpdateWorker -Result $item.Result }
        }
    }
}

function Get-StudioStats {
    param($Snapshot)
    if ($null -eq $Snapshot) {
        return [pscustomobject]@{ Apps = 0; Folders = 0; Browsers = 0; Tabs = 0 }
    }
    $apps = @($Snapshot.apps).Count
    $folders = @($Snapshot.explorer).Count
    $browsers = @($Snapshot.browsers).Count
    $tabs = 0
    foreach ($browser in @($Snapshot.browsers)) {
        foreach ($profile in @($browser.profiles)) {
            $tabs += @($profile.tabs).Count
        }
    }
    return [pscustomobject]@{ Apps = $apps; Folders = $folders; Browsers = $browsers; Tabs = $tabs }
}

function Get-StudioSnapshotBytes {
    param($Entry)
    if ($null -eq $Entry) { return 0 }
    try { return (Get-Item -LiteralPath $Entry.Path).Length } catch { return 0 }
}

function Open-StudioPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    try {
        if (Test-Path -LiteralPath $Path -PathType Container) {
            Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $Path) | Out-Null
        } else {
            Start-Process -FilePath $Path | Out-Null
        }
    } catch {
        Show-StudioToast ('Could not open: ' + $_.Exception.Message) $script:P.Red
    }
}

function Get-StudioTrayState {
    $tray = @()
    try {
        $tray = @(Get-CimInstance Win32_Process -Filter "Name='SessionRecovery.exe' OR Name='powershell.exe'" -ErrorAction SilentlyContinue | Where-Object {
            ($_.Name -eq 'SessionRecovery.exe' -and $_.CommandLine -and $_.CommandLine -match '(?i)--tray') -or
            ($_.Name -eq 'powershell.exe' -and $_.CommandLine -and $_.CommandLine -match '(?i)Tray-SessionRecovery\.ps1')
        })
    } catch { }
    $tasks = @()
    try {
        $tasks = @(Get-ScheduledTask -TaskName 'SessionRecovery-Snapshot' -ErrorAction SilentlyContinue)
    } catch { }
    $mode = 'Not running'
    if ($tasks.Count -gt 0) {
        $mode = if ($tray.Count -gt 0) { 'Scheduled tasks + tray' } else { 'Scheduled tasks' }
    } elseif ($tray.Count -gt 0) {
        $mode = 'Background tray'
    }
    return [pscustomobject]@{
        Running = ($tray.Count -gt 0)
        Tasks   = ($tasks.Count -gt 0)
        Mode    = $mode
        Count   = $tray.Count
    }
}

function Start-StudioBackground {
    if (-not $script:HostExe -or -not (Test-Path -LiteralPath $script:HostExe)) {
        Show-StudioToast 'SessionRecovery.exe is missing. Reinstall the app.' $script:P.Red
        return
    }
    $state = Get-StudioTrayState
    if ($state.Running) {
        Show-StudioToast 'The background app is already running.' $script:P.Green
        return
    }
    try {
        Start-Process -FilePath $script:HostExe -ArgumentList '--tray' -WorkingDirectory $script:ScriptDir | Out-Null
        Show-StudioToast 'Background protection started.' $script:P.Green
        Refresh-StudioSidebar
    } catch {
        Show-StudioToast ('Could not start background app: ' + $_.Exception.Message) $script:P.Red
    }
}

function Open-StudioRestore {
    param([string]$SnapshotPath = '')
    if (-not $script:HostExe -or -not (Test-Path -LiteralPath $script:HostExe)) {
        Show-StudioToast 'SessionRecovery.exe is missing. Reinstall the app.' $script:P.Red
        return
    }
    try {
        $arguments = '--restore-manual'
        if (-not [string]::IsNullOrWhiteSpace($SnapshotPath)) {
            $arguments += ' -SnapshotPath "' + $SnapshotPath.Replace('"', '""') + '"'
        }
        Start-Process -FilePath $script:HostExe -ArgumentList $arguments -WorkingDirectory $script:ScriptDir | Out-Null
        Show-StudioToast 'Restore studio opened.' $script:P.Green
    } catch {
        Show-StudioToast ('Could not open restore studio: ' + $_.Exception.Message) $script:P.Red
    }
}

function Invoke-StudioCapture {
    if (-not $script:HostExe -or -not (Test-Path -LiteralPath $script:HostExe)) {
        Show-StudioToast 'SessionRecovery.exe is missing. Reinstall the app.' $script:P.Red
        return
    }
    if ($script:Ui.CaptureButton) { $script:Ui.CaptureButton.Enabled = $false }
    Show-StudioToast 'Capturing your current session...' $script:P.Muted
    try {
        $process = Start-Process -FilePath $script:HostExe -ArgumentList '--snapshot' -WorkingDirectory $script:ScriptDir -PassThru
        $process.WaitForExit(30000) | Out-Null
        Refresh-StudioData
        if ($script:Snapshots.Count -gt 0) {
            Show-StudioToast ('Snapshot saved  •  ' + $script:Snapshots[0].CapturedAt.ToString('HH:mm:ss')) $script:P.Green
        } else {
            Show-StudioToast 'Snapshot finished, but no snapshot was found.' $script:P.Amber
        }
    } catch {
        Show-StudioToast ('Snapshot failed: ' + $_.Exception.Message) $script:P.Red
    } finally {
        if ($script:Ui.CaptureButton) { $script:Ui.CaptureButton.Enabled = $true }
    }
}

# ---------------------------------------------------------------------------
# Shortcuts and settings persistence
# ---------------------------------------------------------------------------

function Set-StudioShortcut {
    param([string]$Path, [string]$Arguments, [string]$Description)
    if (-not $script:HostExe -or -not (Test-Path -LiteralPath $script:HostExe)) { return $false }
    $shell = $null
    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($Path)
        $shortcut.TargetPath = $script:HostExe
        $shortcut.Arguments = $Arguments
        $shortcut.WorkingDirectory = $script:ScriptDir
        if ($script:IconPath) { $shortcut.IconLocation = $script:IconPath + ',0' }
        $shortcut.Description = $Description
        $shortcut.Save()
        return $true
    } catch {
        return $false
    } finally {
        if ($null -ne $shell) { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
    }
}

function Get-StudioStartupShortcutPath {
    return (Join-Path ([Environment]::GetFolderPath('Startup')) 'Session Recovery - Background.lnk')
}

function Get-StudioDesktopShortcutPath {
    return (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Session Recovery.lnk')
}

function Set-StudioStartWithWindows {
    param([bool]$Enabled)
    $path = Get-StudioStartupShortcutPath
    if (-not $Enabled) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Join-Path ([Environment]::GetFolderPath('Startup')) 'Session Recovery - Snapshot Watcher.lnk') -Force -ErrorAction SilentlyContinue
        return $true
    }
    return (Set-StudioShortcut -Path $path -Arguments '--tray' -Description 'Session Recovery: keeps snapshots while you are signed in.')
}

function Set-StudioDesktopShortcut {
    param([bool]$Enabled)
    $path = Get-StudioDesktopShortcutPath
    if (-not $Enabled) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Restore Session.lnk') -Force -ErrorAction SilentlyContinue
        return $true
    }
    $created = Set-StudioShortcut -Path $path -Arguments '' -Description 'Open Session Recovery.'
    if ($created) {
        Remove-Item -LiteralPath (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Restore Session.lnk') -Force -ErrorAction SilentlyContinue
    }
    return $created
}

function Refresh-StudioSidebar {
    if (-not $script:Ui.SidebarBadge) { return }
    $state = Get-StudioTrayState
    $latestAge = $null
    if ($script:Snapshots.Count -gt 0) {
        $latestAge = ((Get-Date) - $script:Snapshots[0].CapturedAt).TotalMinutes
    }
    $healthy = ($null -ne $latestAge -and $latestAge -le ([Math]::Max(1, [int]$script:Config.snapshotIntervalMinutes) * 2.5))
    if ($healthy) {
        $script:Ui.SidebarBadge.Text = 'PROTECTED'
        $script:Ui.SidebarBadge.FillColor = $script:P.GreenSoft
        $script:Ui.SidebarBadge.TextColor = $script:P.Green
    } else {
        $script:Ui.SidebarBadge.Text = 'ATTENTION'
        $script:Ui.SidebarBadge.FillColor = $script:P.AmberSoft
        $script:Ui.SidebarBadge.TextColor = $script:P.Amber
    }
    $script:Ui.SidebarStatus.Text = $state.Mode
    $script:Ui.SidebarDetail.Text = if ($state.Running) {
        'Tray app running'
    } elseif ($state.Tasks) {
        'Snapshots handled by Windows'
    } else {
        'Background app is not running'
    }
    if ($state.Running) {
        $script:Ui.TrayButton.Text = 'Background running'
        $script:Ui.TrayButton.Enabled = $false
    } else {
        $script:Ui.TrayButton.Text = 'Start background app'
        $script:Ui.TrayButton.Enabled = $true
    }
}

function Refresh-StudioData {
    $script:Config = Get-SRConfig
    $script:Snapshots = @(Get-SRSnapshots)
    $script:SnapshotsDirty = $true
    $script:DashboardDirty = $true
    $script:ExclusionsDirty = $true
    $script:DiagnosticsDirty = $true
    Refresh-StudioSidebar
    switch ($script:CurrentPage) {
        'Dashboard' { if ($script:PageLoaded.ContainsKey('Dashboard')) { Refresh-StudioDashboard } }
        'Snapshots' { if ($script:PageLoaded.ContainsKey('Snapshots')) { Refresh-StudioSnapshotRows } }
        'Exclusions' { if ($script:PageLoaded.ContainsKey('Exclusions')) { Refresh-StudioExclusions } }
        'Diagnostics' { if ($script:PageLoaded.ContainsKey('Diagnostics')) { Start-StudioDiagnosticsRefresh -Force } }
    }
}

# ---------------------------------------------------------------------------
# Main window
# ---------------------------------------------------------------------------

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Session Recovery'
$form.ClientSize = New-Object System.Drawing.Size(1160, 680)
$form.MinimumSize = New-Object System.Drawing.Size(1040, 700)
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.BackColor = $script:P.Bg
$form.ForeColor = $script:P.Text
Enable-StudioDoubleBuffer $form
$form.Font = $script:FontBody
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
$form.KeyPreview = $true
if ($script:IconPath) {
    try { $form.Icon = New-Object System.Drawing.Icon($script:IconPath) } catch { }
}

$accentBar = New-Object System.Windows.Forms.Panel
$accentBar.Dock = [System.Windows.Forms.DockStyle]::Top
$accentBar.Height = 3
$accentBar.BackColor = $script:P.Accent
$accentBar.Add_Paint({
    param($sender, $e)
    $rect = New-Object System.Drawing.Rectangle(0, 0, $sender.Width, $sender.Height)
    $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, $script:P.Accent, $script:P.Accent2, 0)
    try { $e.Graphics.FillRectangle($brush, $rect) } finally { $brush.Dispose() }
})
$form.Controls.Add($accentBar)

$sidebar = New-Object System.Windows.Forms.Panel
$sidebar.Dock = [System.Windows.Forms.DockStyle]::Left
$sidebar.Width = 236
$sidebar.BackColor = $script:P.Sidebar
$form.Controls.Add($sidebar)

$main = New-Object System.Windows.Forms.Panel
$main.Dock = [System.Windows.Forms.DockStyle]::Fill
$main.BackColor = $script:P.Bg
$form.Controls.Add($main)
$main.BringToFront()

$brandPic = New-Object System.Windows.Forms.PictureBox
$brandPic.Location = New-Object System.Drawing.Point(22, 24)
$brandPic.Size = New-Object System.Drawing.Size(38, 38)
$brandPic.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
$brandPic.BackColor = [System.Drawing.Color]::Transparent
if ($script:IconPath) {
    try { $brandPic.Image = (New-Object System.Drawing.Icon($script:IconPath)).ToBitmap() } catch { }
}
$sidebar.Controls.Add($brandPic)

$brandName = New-StudioLabel -Text 'Session' -X 70 -Y 23 -Width 150 -Height 24 -Font (New-Object System.Drawing.Font('Segoe UI Semibold', 13)) -Color $script:P.Text
$sidebar.Controls.Add($brandName)
$brandSub = New-StudioLabel -Text 'RECOVERY  /  STUDIO' -X 72 -Y 45 -Width 150 -Height 16 -Font $script:FontMono -Color $script:P.Subtle
$sidebar.Controls.Add($brandSub)

$navDefs = @(
    @{ Key = 'Dashboard'; Label = 'Dashboard'; Glyph = [char]0xE80F },
    @{ Key = 'Snapshots'; Label = 'Snapshots'; Glyph = [char]0xE81C },
    @{ Key = 'Exclusions'; Label = 'Exclusions'; Glyph = [char]0xE8B7 },
    @{ Key = 'Settings'; Label = 'Settings'; Glyph = [char]0xE713 },
    @{ Key = 'Diagnostics'; Label = 'Diagnostics'; Glyph = [char]0xE9D9 },
    @{ Key = 'About'; Label = 'About'; Glyph = [char]0xE946 }
)
$navIndex = 0
foreach ($nav in $navDefs) {
    $navButton = New-Object SessionRecovery.Studio.StudioNavButton
    $navButton.Text = $nav.Label
    $navButton.Glyph = [string]$nav.Glyph
    $navButton.Tag = $nav.Key
    $navButton.Location = New-Object System.Drawing.Point(14, (86 + ($navIndex * 46)))
    $navButton.Size = New-Object System.Drawing.Size(208, 40)
    $navButton.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $navButton.AccentColor = $script:P.Accent
    $navButton.SelectedFill = [System.Drawing.Color]::FromArgb(27, 38, 54)
    $navButton.HoverFill = [System.Drawing.Color]::FromArgb(20, 29, 42)
    $navButton.Add_Click({
        param($sender, $eventArgs)
        Show-StudioPage -Name ([string]$sender.Tag)
    })
    $sidebar.Controls.Add($navButton)
    $script:NavButtons[$nav.Key] = $navButton
    $navIndex++
}

$restoreSidebar = New-StudioButton -Text 'Restore a session' -X 14 -Y 0 -Width 208 -Height 40 -Primary -Glyph ([string][char]0xE777)
$restoreSidebar.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$restoreSidebar.Add_Click({ Open-StudioRestore })
$sidebar.Controls.Add($restoreSidebar)

$sidebarStatusCard = New-StudioCard -X 14 -Y 0 -Width 208 -Height 140 -Fill $script:P.CardAlt -Border $script:P.BorderSoft -Radius 12
$sidebarStatusCard.CanvasColor = $script:P.Sidebar
$sidebarStatusCard.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$sidebar.Controls.Add($sidebarStatusCard)

$sidebarBadge = New-StudioBadge -Text 'PROTECTED' -Width 88 -Height 22
$sidebarBadge.Location = New-Object System.Drawing.Point(14, 13)
$sidebarStatusCard.Controls.Add($sidebarBadge)
$script:Ui.SidebarBadge = $sidebarBadge

$sidebarTitle = New-StudioLabel -Text 'PROTECTION' -X 14 -Y 43 -Width 150 -Height 16 -Font $script:FontMono -Color $script:P.Subtle
$sidebarStatusCard.Controls.Add($sidebarTitle)
$sidebarStatus = New-StudioLabel -Text 'Checking...' -X 14 -Y 60 -Width 180 -Height 18 -Font $script:FontSemibold -Color $script:P.Text
$sidebarStatusCard.Controls.Add($sidebarStatus)
$script:Ui.SidebarStatus = $sidebarStatus
$sidebarDetail = New-StudioLabel -Text '' -X 14 -Y 78 -Width 180 -Height 16 -Font $script:FontBodySmall -Color $script:P.Muted
$sidebarStatusCard.Controls.Add($sidebarDetail)
$script:Ui.SidebarDetail = $sidebarDetail

$trayButton = New-StudioButton -Text 'Start background app' -X 14 -Y 98 -Width 180 -Height 30 -Glyph ''
$trayButton.Visible = $true
$trayButton.Add_Click({ Start-StudioBackground })
$sidebarStatusCard.Controls.Add($trayButton)
$script:Ui.TrayButton = $trayButton

$sidebarVersion = New-StudioLabel -Text ('STUDIO {0}  /  LOCAL ONLY' -f $script:AppVersion) -X 14 -Y 0 -Width 208 -Height 16 -Font $script:FontMono -Color $script:P.Subtle -Align 'MiddleCenter'
$sidebarVersion.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$sidebar.Controls.Add($sidebarVersion)
$script:Ui.SidebarVersion = $sidebarVersion

$header = New-Object System.Windows.Forms.Panel
$header.Location = New-Object System.Drawing.Point(0, 0)
$header.Size = New-Object System.Drawing.Size(984, 88)
$header.BackColor = $script:P.Bg
$main.Controls.Add($header)

$headerLine = New-Object System.Windows.Forms.Panel
$headerLine.Location = New-Object System.Drawing.Point(0, 87)
$headerLine.Size = New-Object System.Drawing.Size(984, 1)
$headerLine.BackColor = $script:P.BorderSoft
$headerLine.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$header.Controls.Add($headerLine)

$pageTitle = New-StudioLabel -Text 'Dashboard' -X 28 -Y 17 -Width 560 -Height 32 -Font $script:FontTitle -Color $script:P.Text
$header.Controls.Add($pageTitle)
$script:Ui.PageTitle = $pageTitle
$pageSubtitle = New-StudioLabel -Text 'Your session, exactly as you left it.' -X 30 -Y 47 -Width 600 -Height 20 -Font $script:FontBody -Color $script:P.Muted
$header.Controls.Add($pageSubtitle)
$script:Ui.PageSubtitle = $pageSubtitle
$toastLabel = New-StudioLabel -Text '' -X 30 -Y 66 -Width 560 -Height 16 -Font $script:FontBodySmall -Color $script:P.Green
$toastLabel.Visible = $false
$header.Controls.Add($toastLabel)
$script:Ui.Toast = $toastLabel

$localBadge = New-StudioBadge -Text 'LOCAL ONLY' -Width 100 -Height 26 -Fill $script:P.CardAlt -TextColor $script:P.Muted
$localBadge.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$header.Controls.Add($localBadge)
$script:Ui.LocalBadge = $localBadge

$refreshButton = New-StudioButton -Text '' -X 0 -Y 25 -Width 38 -Height 38 -Glyph ([string][char]0xE72C)
$refreshButton.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$refreshButton.Visible = $false
$refreshButton.Add_Click({ Refresh-StudioDiagnostics })
$header.Controls.Add($refreshButton)
$script:Ui.RefreshButton = $refreshButton

$captureButton = New-StudioButton -Text 'Capture now' -X 0 -Y 24 -Width 138 -Height 40 -Primary -Glyph ([string][char]0xE710)
$captureButton.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$captureButton.Add_Click({ Invoke-StudioCapture })
$header.Controls.Add($captureButton)
$script:Ui.CaptureButton = $captureButton

$pageHost = New-Object System.Windows.Forms.Panel
$pageHost.Location = New-Object System.Drawing.Point(0, 88)
$pageHost.Size = New-Object System.Drawing.Size(984, 692)
$pageHost.BackColor = $script:P.Bg
Enable-StudioDoubleBuffer $pageHost
$main.Controls.Add($pageHost)
$script:PageHost = $pageHost

function New-StudioPage {
    param([string]$Name)
    $page = New-Object System.Windows.Forms.Panel
    $page.Dock = [System.Windows.Forms.DockStyle]::Fill
    $page.BackColor = $script:P.Bg
    $page.Visible = $false
    $page.Size = $script:PageHost.ClientSize
    Enable-StudioDoubleBuffer $page
    $script:PageHost.Controls.Add($page)
    $script:Pages[$Name] = $page
    return $page
}

# ---------------------------------------------------------------------------
# Dashboard
# ---------------------------------------------------------------------------

$dashboard = New-StudioPage -Name 'Dashboard'
$hero = New-StudioCard -X 24 -Y 18 -Width 936 -Height 180
$hero.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$dashboard.Controls.Add($hero)

$heroBadge = New-StudioBadge -Text 'PROTECTED' -Width 98 -Height 24
$heroBadge.Location = New-Object System.Drawing.Point(22, 18)
$hero.Controls.Add($heroBadge)
$script:Ui.HeroBadge = $heroBadge

$heroTitle = New-StudioLabel -Text 'Your session is protected' -X 22 -Y 48 -Width 560 -Height 40 -Font $script:FontHero -Color $script:P.Text
$hero.Controls.Add($heroTitle)
$script:Ui.HeroTitle = $heroTitle
$heroSub = New-StudioLabel -Text 'Snapshots stay on this PC. Restore apps, folders and browser tabs from any saved moment.' -X 24 -Y 91 -Width 600 -Height 22 -Font $script:FontBody -Color $script:P.Muted
$hero.Controls.Add($heroSub)
$heroLast = New-StudioLabel -Text 'Last snapshot  •  checking' -X 24 -Y 123 -Width 620 -Height 18 -Font $script:FontBodySmall -Color $script:P.Muted
$hero.Controls.Add($heroLast)
$script:Ui.HeroLast = $heroLast
$heroNext = New-StudioLabel -Text 'Next automatic snapshot  •  checking' -X 24 -Y 143 -Width 620 -Height 18 -Font $script:FontBodySmall -Color $script:P.Subtle
$hero.Controls.Add($heroNext)
$script:Ui.HeroNext = $heroNext

$heroRestore = New-StudioButton -Text 'Restore latest' -X 24 -Y 166 -Width 132 -Height 0 -Glyph ([string][char]0xE777)
$heroRestore.Visible = $false
$hero.Controls.Add($heroRestore)

$heroRing = New-Object SessionRecovery.Studio.StudioRing
$heroRing.Size = New-Object System.Drawing.Size(132, 132)
$heroRing.Location = New-Object System.Drawing.Point(780, 27)
$heroRing.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$heroRing.Value = 100
$heroRing.CenterText = '--'
$heroRing.Caption = 'LAST SNAPSHOT'
$heroRing.ProgressColor = $script:P.Accent
$heroRing.ProgressEndColor = $script:P.Accent2
$heroRing.TrackColor = $script:P.Border
$hero.Controls.Add($heroRing)
$script:Ui.HeroRing = $heroRing

$statRow = New-Object System.Windows.Forms.Panel
$statRow.Location = New-Object System.Drawing.Point(24, 214)
$statRow.Size = New-Object System.Drawing.Size(936, 108)
$statRow.BackColor = $script:P.Bg
$statRow.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$dashboard.Controls.Add($statRow)

$statSnapshots = New-Object SessionRecovery.Studio.StudioStatCard
$statSnapshots.Title = 'Snapshots'
$statSnapshots.Value = '0'
$statSnapshots.Detail = 'Saved moments'
$statSnapshots.Glyph = [string][char]0xE81C
$statSnapshots.AccentColor = $script:P.Accent
$statSnapshots.Location = New-Object System.Drawing.Point(0, 0)
$statSnapshots.Size = New-Object System.Drawing.Size(224, 108)
$statRow.Controls.Add($statSnapshots)
$script:Ui.StatSnapshots = $statSnapshots

$statApps = New-Object SessionRecovery.Studio.StudioStatCard
$statApps.Title = 'Apps captured'
$statApps.Value = '0'
$statApps.Detail = 'In the latest snapshot'
$statApps.Glyph = [string][char]0xE8F1
$statApps.AccentColor = $script:P.Green
$statApps.Location = New-Object System.Drawing.Point(238, 0)
$statApps.Size = New-Object System.Drawing.Size(224, 108)
$statRow.Controls.Add($statApps)
$script:Ui.StatApps = $statApps

$statTabs = New-Object SessionRecovery.Studio.StudioStatCard
$statTabs.Title = 'Browser tabs'
$statTabs.Value = '0'
$statTabs.Detail = 'Across open browsers'
$statTabs.Glyph = [string][char]0xE774
$statTabs.AccentColor = $script:P.Accent2
$statTabs.Location = New-Object System.Drawing.Point(476, 0)
$statTabs.Size = New-Object System.Drawing.Size(224, 108)
$statRow.Controls.Add($statTabs)
$script:Ui.StatTabs = $statTabs

$statStorage = New-Object SessionRecovery.Studio.StudioStatCard
$statStorage.Title = 'Local storage'
$statStorage.Value = '0 B'
$statStorage.Detail = 'Snapshots on disk'
$statStorage.Glyph = [string][char]0xE7B8
$statStorage.AccentColor = $script:P.Amber
$statStorage.Location = New-Object System.Drawing.Point(714, 0)
$statStorage.Size = New-Object System.Drawing.Size(222, 108)
$statRow.Controls.Add($statStorage)
$script:Ui.StatStorage = $statStorage

$recentCard = New-StudioCard -X 24 -Y 342 -Width 620 -Height 240
$recentCard.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
$dashboard.Controls.Add($recentCard)
$recentHeading = New-StudioLabel -Text 'RECENT SNAPSHOTS' -X 18 -Y 15 -Width 240 -Height 18 -Font $script:FontMono -Color $script:P.Subtle
$recentCard.Controls.Add($recentHeading)
$recentViewAll = New-StudioButton -Text 'View timeline' -X 0 -Y 10 -Width 100 -Height 26 -Glyph ''
$recentViewAll.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$recentViewAll.Add_Click({ Show-StudioPage -Name 'Snapshots' })
$recentCard.Controls.Add($recentViewAll)
$recentFlow = New-Object System.Windows.Forms.FlowLayoutPanel
$recentFlow.Location = New-Object System.Drawing.Point(16, 42)
$recentFlow.Size = New-Object System.Drawing.Size(588, 190)
$recentFlow.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$recentFlow.FlowDirection = [System.Windows.Forms.FlowDirection]::TopDown
$recentFlow.WrapContents = $false
$recentFlow.AutoScroll = $false
$recentFlow.BackColor = $script:P.Card
$recentCard.Controls.Add($recentFlow)
$script:Ui.RecentFlow = $recentFlow
$recentSpark = New-Object SessionRecovery.Studio.StudioSparkline
$recentSpark.Location = New-Object System.Drawing.Point(16, 242)
$recentSpark.Size = New-Object System.Drawing.Size(588, 32)
$recentSpark.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$recentSpark.LineColor = $script:P.Accent
$recentSpark.FillColor = [System.Drawing.Color]::FromArgb(55, 45, 150)
$recentCard.Controls.Add($recentSpark)
$script:Ui.RecentSpark = $recentSpark
$recentEmpty = New-StudioLabel -Text 'No snapshots yet. Capture one to get started.' -X 18 -Y 54 -Width 400 -Height 30 -Font $script:FontBody -Color $script:P.Muted
$recentEmpty.Visible = $false
$recentCard.Controls.Add($recentEmpty)
$script:Ui.RecentEmpty = $recentEmpty

$quickCard = New-StudioCard -X 660 -Y 342 -Width 300 -Height 240
$quickCard.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
$dashboard.Controls.Add($quickCard)
$quickHeading = New-StudioLabel -Text 'QUICK ACTIONS' -X 18 -Y 15 -Width 200 -Height 18 -Font $script:FontMono -Color $script:P.Subtle
$quickCard.Controls.Add($quickHeading)
$quickCapture = New-StudioButton -Text 'Capture now' -X 16 -Y 44 -Width 268 -Height 34 -Primary -Glyph ([string][char]0xE710)
$quickCapture.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$quickCapture.Add_Click({ Invoke-StudioCapture })
$quickCard.Controls.Add($quickCapture)
$quickRestore = New-StudioButton -Text 'Restore latest snapshot' -X 16 -Y 86 -Width 268 -Height 34 -Glyph ([string][char]0xE777)
$quickRestore.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$quickRestore.Add_Click({
    if ($script:Snapshots.Count -gt 0) { Open-StudioRestore -SnapshotPath $script:Snapshots[0].Path }
    else { Show-StudioToast 'There is no snapshot to restore yet.' $script:P.Amber }
})
$quickCard.Controls.Add($quickRestore)
$script:Ui.QuickRestore = $quickRestore
$quickFolder = New-StudioButton -Text 'Open snapshots folder' -X 16 -Y 128 -Width 268 -Height 34 -Glyph ([string][char]0xE838)
$quickFolder.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$quickFolder.Add_Click({ Open-StudioPath (Get-SRSnapshotDirectory) })
$quickCard.Controls.Add($quickFolder)
$quickDiagnostics = New-StudioButton -Text 'Run diagnostics' -X 16 -Y 170 -Width 268 -Height 34 -Glyph ([string][char]0xE9D9)
$quickDiagnostics.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$quickDiagnostics.Add_Click({ Show-StudioPage -Name 'Diagnostics' })
$quickCard.Controls.Add($quickDiagnostics)

$dashboardHint = New-StudioLabel -Text 'Snapshots are local JSON files. Nothing leaves this device.' -X 24 -Y 660 -Width 600 -Height 18 -Font $script:FontBodySmall -Color $script:P.Subtle
$dashboardHint.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
$dashboardHint.Visible = $false
$dashboard.Controls.Add($dashboardHint)

function Refresh-StudioDashboard {
    if (-not $script:UiReady -and -not $script:Ui.StatSnapshots) { return }
    $latest = if ($script:Snapshots.Count -gt 0) { $script:Snapshots[0] } else { $null }
    $stats = Get-StudioStats -Snapshot $(if ($latest) { $latest.Snapshot } else { $null })
    $bytes = 0
    foreach ($entry in $script:Snapshots) { $bytes += Get-StudioSnapshotBytes -Entry $entry }
    if ($script:Ui.StatSnapshots) {
        $script:Ui.StatSnapshots.Value = [string]$script:Snapshots.Count
        $script:Ui.StatSnapshots.Detail = ('Retaining up to {0}' -f $script:Config.keepSnapshots)
        $script:Ui.StatApps.Value = [string]$stats.Apps
        $script:Ui.StatApps.Detail = if ($latest) { 'Captured ' + (Format-StudioAge -CapturedAt $latest.CapturedAt) } else { 'No snapshot yet' }
        $script:Ui.StatTabs.Value = [string]$stats.Tabs
        $script:Ui.StatTabs.Detail = if ($stats.Browsers -gt 0) { ('{0} browser(s) captured' -f $stats.Browsers) } else { 'No browser tabs captured' }
        $script:Ui.StatStorage.Value = Format-StudioBytes -Bytes $bytes
        $script:Ui.StatStorage.Detail = ('{0} folder(s) in latest' -f $stats.Folders)
    }
    if ($script:Ui.HeroRing) {
        $age = if ($latest) { ((Get-Date) - $latest.CapturedAt).TotalMinutes } else { 9999 }
        $interval = [Math]::Max(1, [int]$script:Config.snapshotIntervalMinutes)
        $health = 100
        if ($age -gt $interval * 2.5) { $health = 55 }
        if ($age -gt 24 * 60) { $health = 25 }
        if ($script:Snapshots.Count -eq 0) { $health = 0 }
        $script:Ui.HeroRing.Value = $health
        if ($latest) {
            $ageSpan = (Get-Date) - $latest.CapturedAt
            $ringText = if ($ageSpan.TotalMinutes -lt 60) { '{0}m' -f [Math]::Max(1, [int]$ageSpan.TotalMinutes) } elseif ($ageSpan.TotalHours -lt 24) { '{0}h' -f [int]$ageSpan.TotalHours } else { '{0}d' -f [int]$ageSpan.TotalDays }
            $script:Ui.HeroRing.CenterText = $ringText
            $script:Ui.HeroLast.Text = ('Last snapshot {0}  •  {1}  •  {2} app(s), {3} tab(s)' -f (Format-StudioAge -CapturedAt $latest.CapturedAt), $latest.CapturedAt.ToString('HH:mm:ss'), $stats.Apps, $stats.Tabs)
        } else {
            $script:Ui.HeroRing.CenterText = '--'
            $script:Ui.HeroLast.Text = 'No snapshot has been saved yet.'
        }
        $script:Ui.HeroNext.Text = 'Next automatic snapshot  •  ' + (Format-StudioNext)
        if ($health -ge 80) {
            $script:Ui.HeroBadge.Text = 'PROTECTED'
            $script:Ui.HeroBadge.FillColor = $script:P.GreenSoft
            $script:Ui.HeroBadge.TextColor = $script:P.Green
            $script:Ui.HeroTitle.Text = 'Your session is protected'
            $script:Ui.HeroRing.ProgressColor = $script:P.Green
            $script:Ui.HeroRing.ProgressEndColor = $script:P.Accent2
        } elseif ($health -ge 40) {
            $script:Ui.HeroBadge.Text = 'ATTENTION'
            $script:Ui.HeroBadge.FillColor = $script:P.AmberSoft
            $script:Ui.HeroBadge.TextColor = $script:P.Amber
            $script:Ui.HeroTitle.Text = 'Protection needs a nudge'
            $script:Ui.HeroRing.ProgressColor = $script:P.Amber
            $script:Ui.HeroRing.ProgressEndColor = $script:P.Amber
        } else {
            $script:Ui.HeroBadge.Text = 'NO SNAPSHOT'
            $script:Ui.HeroBadge.FillColor = $script:P.RedSoft
            $script:Ui.HeroBadge.TextColor = $script:P.Red
            $script:Ui.HeroTitle.Text = 'Nothing has been saved yet'
            $script:Ui.HeroRing.ProgressColor = $script:P.Red
            $script:Ui.HeroRing.ProgressEndColor = $script:P.Red
        }
    }
    if ($script:Ui.QuickRestore) { $script:Ui.QuickRestore.Enabled = ($script:Snapshots.Count -gt 0) }
    if ($script:Ui.RecentFlow) {
        $script:Ui.RecentFlow.SuspendLayout()
        try {
            $script:Ui.RecentFlow.Controls.Clear()
            $count = [Math]::Min(5, [Math]::Max(1, [int][Math]::Floor(($script:Ui.RecentFlow.Height - 8) / 52)))
            foreach ($entry in @($script:Snapshots | Select-Object -First $count)) {
                $row = New-StudioCard -X 0 -Y 0 -Width ([Math]::Max(200, $script:Ui.RecentFlow.ClientSize.Width - 6)) -Height 44 -Fill $script:P.CardAlt -Border $script:P.BorderSoft -Radius 9
                $row.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 6)
                $row.Tag = $entry.Path
                $statsRow = Get-StudioStats -Snapshot $entry.Snapshot
                $timeLabel = New-StudioLabel -Text $entry.CapturedAt.ToString('MMM d  •  HH:mm') -X 12 -Y 5 -Width 150 -Height 16 -Font $script:FontBodySmall -Color $script:P.Text
                $metaLabel = New-StudioLabel -Text ('{0} apps  •  {1} tabs  •  {2}' -f $statsRow.Apps, $statsRow.Tabs, (Format-StudioAge -CapturedAt $entry.CapturedAt)) -X 12 -Y 22 -Width 300 -Height 16 -Font $script:FontBodySmall -Color $script:P.Muted
                $restoreRow = New-StudioButton -Text 'Restore' -X ($row.Width - 78) -Y 9 -Width 66 -Height 26 -Glyph ''
                $restoreRow.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
                $restoreRow.Tag = $entry.Path
                $restoreRow.Add_Click({
                    param($sender, $eventArgs)
                    Open-StudioRestore -SnapshotPath ([string]$sender.Tag)
                })
                $selectHandler = {
                    param($sender, $eventArgs)
                    $path = if ($sender.Tag) { [string]$sender.Tag } else { $script:SelectedSnapshotPath }
                    $script:SelectedSnapshotPath = $path
                    Show-StudioPage -Name 'Snapshots'
                }
                $row.Add_Click($selectHandler)
                $timeLabel.Add_Click($selectHandler)
                $metaLabel.Add_Click($selectHandler)
                $row.Controls.Add($timeLabel)
                $row.Controls.Add($metaLabel)
                $row.Controls.Add($restoreRow)
                [void]$script:Ui.RecentFlow.Controls.Add($row)
            }
            $script:Ui.RecentEmpty.Visible = ($script:Snapshots.Count -eq 0)
        } finally {
            $script:Ui.RecentFlow.ResumeLayout()
        }
    }
    if ($script:Ui.RecentSpark) {
        $values = @()
        foreach ($entry in @($script:Snapshots | Select-Object -First 12)) {
            $values += [int](Get-StudioStats -Snapshot $entry.Snapshot).Tabs
        }
        [array]::Reverse($values)
        $script:Ui.RecentSpark.Values = [int[]]$values
    }
    $script:DashboardDirty = $false
}

# ---------------------------------------------------------------------------
# Snapshots timeline
# ---------------------------------------------------------------------------

$snapshotsPage = New-StudioPage -Name 'Snapshots'
$snapToolbar = New-StudioCard -X 24 -Y 14 -Width 936 -Height 64
$snapToolbar.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$snapshotsPage.Controls.Add($snapToolbar)

$snapSearch = New-StudioTextBox -X 16 -Y 18 -Width 230 -Height 28
$snapSearch.Text = 'Search snapshots'
$snapSearch.ForeColor = $script:P.Subtle
$snapSearch.Tag = 'placeholder'
$snapSearch.Add_GotFocus({
    if ($script:Ui.SnapSearch.Tag -eq 'placeholder') {
        $script:Ui.SnapSearch.Text = ''
        $script:Ui.SnapSearch.ForeColor = $script:P.Text
        $script:Ui.SnapSearch.Tag = ''
    }
})
$snapSearch.Add_LostFocus({
    if ([string]::IsNullOrWhiteSpace($script:Ui.SnapSearch.Text)) {
        $script:Ui.SnapSearch.Text = 'Search snapshots'
        $script:Ui.SnapSearch.ForeColor = $script:P.Subtle
        $script:Ui.SnapSearch.Tag = 'placeholder'
    }
})
$snapSearch.Add_TextChanged({
    if ($script:UiReady -and $script:Ui.SnapSearch.Tag -ne 'placeholder') {
        Refresh-StudioSnapshotRows
    }
})
$snapToolbar.Controls.Add($snapSearch)
$script:Ui.SnapSearch = $snapSearch

$snapFilter = New-StudioCombo -X 258 -Y 18 -Width 170
[void]$snapFilter.Items.Add('All snapshots')
[void]$snapFilter.Items.Add('Last hour')
[void]$snapFilter.Items.Add('Last 24 hours')
[void]$snapFilter.Items.Add('Last 7 days')
$snapFilter.SelectedIndex = 0
$snapFilter.Add_SelectedIndexChanged({
    if ($script:UiReady) { Refresh-StudioSnapshotRows }
})
$snapToolbar.Controls.Add($snapFilter)
$script:Ui.SnapFilter = $snapFilter

$snapCount = New-StudioLabel -Text '0 snapshots' -X 444 -Y 20 -Width 180 -Height 22 -Font $script:FontBodySmall -Color $script:P.Muted
$snapToolbar.Controls.Add($snapCount)
$script:Ui.SnapCount = $snapCount

$snapOpenFolder = New-StudioButton -Text 'Open folder' -X 662 -Y 16 -Width 116 -Height 32 -Glyph ''
$snapOpenFolder.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$snapOpenFolder.Add_Click({ Open-StudioPath (Get-SRSnapshotDirectory) })
$snapToolbar.Controls.Add($snapOpenFolder)

$snapRefresh = New-StudioButton -Text 'Refresh' -X 788 -Y 16 -Width 104 -Height 32 -Glyph ([string][char]0xE72C)
$snapRefresh.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$snapRefresh.Add_Click({
    Refresh-StudioData
    Refresh-StudioSnapshotRows
    Show-StudioToast 'Snapshot timeline refreshed.' $script:P.Muted
})
$snapToolbar.Controls.Add($snapRefresh)
$script:Ui.SnapRefresh = $snapRefresh
$script:Ui.SnapOpenFolder = $snapOpenFolder

$snapSplit = New-Object System.Windows.Forms.SplitContainer
$snapSplit.Location = New-Object System.Drawing.Point(24, 90)
$snapSplit.Size = New-Object System.Drawing.Size(936, 582)
$snapSplit.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$snapSplit.BackColor = $script:P.Bg
$snapSplit.SplitterWidth = 12
$snapSplit.Panel1MinSize = 380
$snapSplit.Panel2MinSize = 310
$snapSplit.FixedPanel = [System.Windows.Forms.FixedPanel]::Panel2
$snapSplit.SplitterDistance = 548
$snapshotsPage.Controls.Add($snapSplit)
$script:Ui.SnapSplit = $snapSplit

$snapListCard = New-StudioCard -X 0 -Y 0 -Width 536 -Height 580
$snapListCard.Dock = [System.Windows.Forms.DockStyle]::Fill
$snapListCard.CanvasColor = $script:P.Bg
$snapSplit.Panel1.Controls.Add($snapListCard)

$snapListHeading = New-StudioLabel -Text 'SNAPSHOT TIMELINE' -X 18 -Y 15 -Width 260 -Height 18 -Font $script:FontMono -Color $script:P.Subtle
$snapListCard.Controls.Add($snapListHeading)
$snapListHint = New-StudioLabel -Text 'Select a moment to preview it.' -X 18 -Y 31 -Width 260 -Height 16 -Font $script:FontBodySmall -Color $script:P.Subtle
$snapListCard.Controls.Add($snapListHint)

$snapFlow = New-Object System.Windows.Forms.FlowLayoutPanel
$snapFlow.Location = New-Object System.Drawing.Point(14, 54)
$snapFlow.Size = New-Object System.Drawing.Size(508, 510)
$snapFlow.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$snapFlow.FlowDirection = [System.Windows.Forms.FlowDirection]::TopDown
$snapFlow.WrapContents = $false
$snapFlow.AutoScroll = $true
$snapFlow.BackColor = $script:P.Card
$snapFlow.Padding = New-Object System.Windows.Forms.Padding(0)
$snapListCard.Controls.Add($snapFlow)
$script:Ui.SnapFlow = $snapFlow

$snapEmpty = New-StudioLabel -Text 'No snapshots match this view.' -X 18 -Y 60 -Width 400 -Height 30 -Font $script:FontBody -Color $script:P.Muted
$snapEmpty.Visible = $false
$snapListCard.Controls.Add($snapEmpty)
$script:Ui.SnapEmpty = $snapEmpty

$detailCard = New-StudioCard -X 0 -Y 0 -Width 376 -Height 580
$detailCard.Dock = [System.Windows.Forms.DockStyle]::Fill
$detailCard.CanvasColor = $script:P.Bg
$snapSplit.Panel2.Controls.Add($detailCard)
$script:Ui.DetailCard = $detailCard

$detailBadge = New-StudioBadge -Text 'NO SNAPSHOT' -Width 104 -Height 22 -Fill $script:P.CardAlt -TextColor $script:P.Muted
$detailBadge.Location = New-Object System.Drawing.Point(18, 16)
$detailCard.Controls.Add($detailBadge)
$script:Ui.DetailBadge = $detailBadge

$detailTitle = New-StudioLabel -Text 'Select a snapshot' -X 18 -Y 48 -Width 340 -Height 28 -Font $script:FontSemiboldLarge -Color $script:P.Text
$detailCard.Controls.Add($detailTitle)
$script:Ui.DetailTitle = $detailTitle
$detailMeta = New-StudioLabel -Text '' -X 18 -Y 77 -Width 340 -Height 18 -Font $script:FontBodySmall -Color $script:P.Muted
$detailCard.Controls.Add($detailMeta)
$script:Ui.DetailMeta = $detailMeta
$detailSummary = New-StudioLabel -Text 'Capture a moment, then select it here to inspect and restore it.' -X 18 -Y 99 -Width 340 -Height 34 -Font $script:FontBodySmall -Color $script:P.Subtle
$detailCard.Controls.Add($detailSummary)
$script:Ui.DetailSummary = $detailSummary

$detailText = New-StudioTextBox -X 18 -Y 138 -Width 340 -Height 350
$detailText.Multiline = $true
$detailText.ReadOnly = $true
$detailText.ScrollBars = [System.Windows.Forms.ScrollBars]::Both
$detailText.WordWrap = $false
$detailText.Font = $script:FontMono
$detailText.BackColor = $script:P.CardAlt
$detailText.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$detailCard.Controls.Add($detailText)
$script:Ui.DetailText = $detailText

$detailRestore = New-StudioButton -Text 'Restore selected' -X 18 -Y 500 -Width 148 -Height 36 -Primary -Glyph ([string][char]0xE777)
$detailRestore.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
$detailRestore.Enabled = $false
$detailRestore.Add_Click({
    if ($script:SelectedSnapshotPath) { Open-StudioRestore -SnapshotPath $script:SelectedSnapshotPath }
})
$detailCard.Controls.Add($detailRestore)
$script:Ui.DetailRestore = $detailRestore

$detailOpen = New-StudioButton -Text 'Open' -X 172 -Y 500 -Width 78 -Height 36
$detailOpen.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
$detailOpen.Enabled = $false
$detailOpen.Add_Click({
    if ($script:SelectedSnapshotPath) { Open-StudioPath (Split-Path -Parent $script:SelectedSnapshotPath) }
})
$detailCard.Controls.Add($detailOpen)
$script:Ui.DetailOpen = $detailOpen

$detailDelete = New-StudioButton -Text 'Delete' -X 256 -Y 500 -Width 80 -Height 36 -Danger
$detailDelete.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
$detailDelete.Enabled = $false
$detailDelete.Add_Click({
    if (-not $script:SelectedSnapshotPath) { return }
    $answer = [System.Windows.Forms.MessageBox]::Show(
        "Delete this snapshot?`r`n`r`nThis removes only the saved JSON file. It cannot be undone.",
        'Delete snapshot', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    try {
        Remove-Item -LiteralPath $script:SelectedSnapshotPath -Force -ErrorAction Stop
        $script:SelectedSnapshotPath = $null
        Refresh-StudioData
        Refresh-StudioSnapshotRows
        Show-StudioToast 'Snapshot deleted.' $script:P.Green
    } catch {
        Show-StudioToast ('Could not delete snapshot: ' + $_.Exception.Message) $script:P.Red
    }
})
$detailCard.Controls.Add($detailDelete)
$script:Ui.DetailDelete = $detailDelete

$detailCard.Add_Resize({
    $card = $script:Ui.DetailCard
    if (-not $card) { return }
    $script:Ui.DetailTitle.Width = $card.ClientSize.Width - 36
    $script:Ui.DetailMeta.Width = $card.ClientSize.Width - 36
    $script:Ui.DetailSummary.Width = $card.ClientSize.Width - 36
    $script:Ui.DetailText.Width = $card.ClientSize.Width - 36
    $script:Ui.DetailText.Height = [Math]::Max(120, $card.ClientSize.Height - 250)
    $script:Ui.DetailRestore.Top = $card.ClientSize.Height - 54
    $script:Ui.DetailOpen.Top = $card.ClientSize.Height - 54
    $script:Ui.DetailDelete.Top = $card.ClientSize.Height - 54
    $script:Ui.DetailDelete.Left = $card.ClientSize.Width - 92
    $script:Ui.DetailOpen.Left = $script:Ui.DetailDelete.Left - 84
    $script:Ui.DetailRestore.BringToFront()
    $script:Ui.DetailOpen.BringToFront()
    $script:Ui.DetailDelete.BringToFront()
})

function Get-StudioSelectedSnapshotEntry {
    if ([string]::IsNullOrWhiteSpace($script:SelectedSnapshotPath)) { return $null }
    foreach ($entry in $script:Snapshots) {
        if ($entry.Path -eq $script:SelectedSnapshotPath) { return $entry }
    }
    return $null
}

function Update-StudioSnapshotDetails {
    if (-not $script:Ui.DetailTitle) { return }
    $entry = Get-StudioSelectedSnapshotEntry
    if ($null -eq $entry) {
        $script:Ui.DetailBadge.Text = 'NO SNAPSHOT'
        $script:Ui.DetailBadge.FillColor = $script:P.CardAlt
        $script:Ui.DetailBadge.TextColor = $script:P.Muted
        $script:Ui.DetailTitle.Text = 'Select a snapshot'
        $script:Ui.DetailMeta.Text = ''
        $script:Ui.DetailSummary.Text = 'Capture a moment, then select it here to inspect and restore it.'
        $script:Ui.DetailText.Text = ''
        $script:Ui.DetailRestore.Enabled = $false
        $script:Ui.DetailOpen.Enabled = $false
        $script:Ui.DetailDelete.Enabled = $false
        return
    }

    $snapshot = $entry.Snapshot
    $stats = Get-StudioStats -Snapshot $snapshot
    $bytes = Get-StudioSnapshotBytes -Entry $entry
    $script:Ui.DetailBadge.Text = 'READY TO RESTORE'
    $script:Ui.DetailBadge.FillColor = $script:P.GreenSoft
    $script:Ui.DetailBadge.TextColor = $script:P.Green
    $script:Ui.DetailTitle.Text = $entry.CapturedAt.ToString('dddd, MMM d  •  HH:mm:ss')
    $script:Ui.DetailMeta.Text = ('{0}  •  {1}  •  {2} app(s)  •  {3} folder(s)' -f (Format-StudioAge -CapturedAt $entry.CapturedAt), (Format-StudioBytes -Bytes $bytes), $stats.Apps, $stats.Folders)
    $script:Ui.DetailSummary.Text = ('Captured {0} browser tab(s) across {1} browser(s). Nothing in this snapshot modifies files.' -f $stats.Tabs, $stats.Browsers)
    $script:Ui.DetailRestore.Enabled = $true
    $script:Ui.DetailOpen.Enabled = $true
    $script:Ui.DetailDelete.Enabled = $true

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('APPLICATIONS')
    if ($stats.Apps -eq 0) {
        $lines.Add('  (none captured)')
    } else {
        $count = 0
        foreach ($app in @($snapshot.apps)) {
            if ($count -ge 14) { $lines.Add('  ...'); break }
            $appName = [string]$app.displayName
            if ([string]::IsNullOrWhiteSpace($appName)) { $appName = [string]$app.name }
            if ([string]::IsNullOrWhiteSpace($appName)) { $appName = [string]$app.processName }
            if ([string]::IsNullOrWhiteSpace($appName)) { $appName = 'Application' }
            $appExe = [string]$app.exe
            if ([string]::IsNullOrWhiteSpace($appExe)) { $appExe = [string]$app.path }
            $lines.Add(('  {0}  {1}' -f $appName, $appExe))
            $count++
        }
    }
    $lines.Add('')
    $lines.Add('FOLDERS')
    if ($stats.Folders -eq 0) {
        $lines.Add('  (none captured)')
    } else {
        $count = 0
        foreach ($folder in @($snapshot.explorer)) {
            if ($count -ge 10) { $lines.Add('  ...'); break }
            $lines.Add('  ' + [string]$folder)
            $count++
        }
    }
    $lines.Add('')
    $lines.Add('BROWSER TABS')
    if ($stats.Browsers -eq 0) {
        $lines.Add('  (none captured)')
    } else {
        foreach ($browser in @($snapshot.browsers)) {
            $lines.Add(('  {0}' -f [string]$browser.name))
            foreach ($profile in @($browser.profiles)) {
                $approx = ''
                if ($profile.tabsApproximate) { $approx = '  [approximate]' }
                $lines.Add(('    {0}  ({1} tab(s)){2}' -f [string]$profile.displayName, @($profile.tabs).Count, $approx))
                $tabCount = 0
                foreach ($tab in @($profile.tabs)) {
                    if ($tabCount -ge 8) { $lines.Add('      ...'); break }
                    $title = [string]$tab.title
                    if ([string]::IsNullOrWhiteSpace($title)) { $title = [string]$tab.url }
                    $lines.Add(('      • {0}' -f $title))
                    if (-not [string]::IsNullOrWhiteSpace([string]$tab.url)) {
                        $lines.Add(('        {0}' -f [string]$tab.url))
                    }
                    $tabCount++
                }
            }
        }
    }
    $script:Ui.DetailText.Text = ($lines -join "`r`n")
    $script:Ui.DetailText.SelectionStart = 0
    $script:Ui.DetailText.SelectionLength = 0
}

function Select-StudioSnapshotRow {
    param([string]$Path, [switch]$Immediate)
    $script:SelectedSnapshotPath = $Path
    foreach ($row in $script:SnapshotRows) {
        if ($null -eq $row) { continue }
        $isSelected = ([string]$row.Tag -eq $Path)
        $row.Selected = $isSelected
        if ($isSelected) {
            $row.BorderColor = $script:P.Accent
        } else {
            $row.BorderColor = $script:P.BorderSoft
        }
    }
    if ($Immediate) {
        Update-StudioSnapshotDetails
        return
    }
    if ($null -eq $script:SnapshotDetailsTimer) {
        $script:SnapshotDetailsTimer = New-Object System.Windows.Forms.Timer
        $script:SnapshotDetailsTimer.Interval = 25
        $script:SnapshotDetailsTimer.Add_Tick({
            $script:SnapshotDetailsTimer.Stop()
            Update-StudioSnapshotDetails
        })
    }
    $script:SnapshotDetailsTimer.Stop()
    $script:SnapshotDetailsTimer.Start()
}

function New-StudioSnapshotRowControl {
    param(
        $Entry,
        [int]$Width,
        [scriptblock]$ClickHandler
    )
    $stats = Get-StudioStats -Snapshot $Entry.Snapshot
    $approx = $false
    foreach ($browser in @($Entry.Snapshot.browsers)) {
        foreach ($profile in @($browser.profiles)) {
            if ($profile.tabsApproximate) { $approx = $true }
        }
    }
    $row = New-Object SessionRecovery.Studio.StudioSnapshotRow
    $row.Location = New-Object System.Drawing.Point(0, 0)
    $row.Size = New-Object System.Drawing.Size($Width, 66)
    $row.FillColor = $script:P.CardAlt
    $row.BorderColor = $script:P.BorderSoft
    $row.CanvasColor = $script:P.Card
    $row.TextColor = $script:P.Text
    $row.MutedColor = $script:P.Muted
    $row.SubtleColor = $script:P.Subtle
    $row.AccentColor = $script:P.Accent
    $row.AmberColor = $script:P.Amber
    $row.AmberSoft = $script:P.AmberSoft
    $row.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 7)
    $row.Tag = $Entry.Path
    $row.TimeText = $Entry.CapturedAt.ToString('ddd  •  MMM d  •  HH:mm:ss')
    $row.MetaText = ('{0} app(s)  •  {1} tab(s)  •  {2}' -f $stats.Apps, $stats.Tabs, (Format-StudioBytes -Bytes (Get-StudioSnapshotBytes -Entry $Entry)))
    $row.AgeText = Format-StudioAge -CapturedAt $Entry.CapturedAt
    $row.Approximate = $approx
    $row.Selected = ([string]$row.Tag -eq [string]$script:SelectedSnapshotPath)
    $row.AccessibleName = ('{0}. {1}. {2}' -f $row.TimeText, $row.MetaText, $row.AgeText)
    $row.AccessibleDescription = 'Snapshot. Select to preview and restore.'
    $row.Add_Click($ClickHandler)
    return $row
}

function Add-StudioSnapshotBatch {
    param([int]$BatchSize = 8)
    if (-not $script:Ui.SnapFlow) { return }
    $total = $script:SnapshotBuildQueue.Count
    if ($script:SnapshotBuildIndex -ge $total) {
        if ($script:SnapshotBuildTimer) { $script:SnapshotBuildTimer.Stop() }
        return
    }
    $end = [Math]::Min($total, $script:SnapshotBuildIndex + $BatchSize)
    $firstBatch = ($script:SnapshotBuildIndex -eq 0)
    $flow = $script:Ui.SnapFlow
    $flow.SuspendLayout()
    try {
        for ($index = $script:SnapshotBuildIndex; $index -lt $end; $index++) {
            $row = New-StudioSnapshotRowControl -Entry $script:SnapshotBuildQueue[$index] -Width $script:SnapshotBuildWidth -ClickHandler $script:SnapshotClickHandler
            [void]$flow.Controls.Add($row)
            $script:SnapshotRows += $row
        }
        $script:SnapshotBuildIndex = $end
    } finally {
        $flow.ResumeLayout($true)
    }
    if ($firstBatch -or $script:SnapshotBuildIndex -ge $total) {
        Select-StudioSnapshotRow -Path $script:SelectedSnapshotPath
    }
    if ($script:SnapshotBuildIndex -lt $total) {
        if ($null -eq $script:SnapshotBuildTimer) {
            $script:SnapshotBuildTimer = New-Object System.Windows.Forms.Timer
            $script:SnapshotBuildTimer.Interval = 15
            $script:SnapshotBuildTimer.Add_Tick({ Add-StudioSnapshotBatch -BatchSize 8 })
        }
        if (-not $script:SnapshotBuildTimer.Enabled) { $script:SnapshotBuildTimer.Start() }
    } elseif ($script:SnapshotBuildTimer) {
        $script:SnapshotBuildTimer.Stop()
    }
}

function Refresh-StudioSnapshotRows {
    if (-not $script:Ui.SnapFlow) { return }
    if ($script:SnapshotLayoutTimer) { $script:SnapshotLayoutTimer.Stop() }
    if ($script:SnapshotBuildTimer) { $script:SnapshotBuildTimer.Stop() }
    if ($script:Snapshots.Count -eq 0) {
        $script:Snapshots = @(Get-SRSnapshots)
    }
    $script:LastSnapFlowWidth = [Math]::Max(300, $script:Ui.SnapFlow.ClientSize.Width - 22)

    $search = [string]$script:Ui.SnapSearch.Text
    if ($script:Ui.SnapSearch.Tag -eq 'placeholder') { $search = '' }
    $search = $search.Trim()
    $mode = [string]$script:Ui.SnapFilter.SelectedItem
    $cutoff = $null
    if ($mode -eq 'Last hour') { $cutoff = (Get-Date).AddHours(-1) }
    elseif ($mode -eq 'Last 24 hours') { $cutoff = (Get-Date).AddHours(-24) }
    elseif ($mode -eq 'Last 7 days') { $cutoff = (Get-Date).AddDays(-7) }

    $filtered = New-Object System.Collections.Generic.List[object]
    foreach ($entry in $script:Snapshots) {
        if ($null -ne $cutoff -and $entry.CapturedAt -lt $cutoff) { continue }
        if (-not [string]::IsNullOrWhiteSpace($search)) {
            $haystack = ($entry.Path + ' ' + $entry.CapturedAt.ToString('yyyy-MM-dd HH:mm') + ' ' + $entry.CapturedAt.ToString('dddd')).ToLowerInvariant()
            if (-not $haystack.Contains($search.ToLowerInvariant())) { continue }
        }
        $filtered.Add($entry)
    }

    $script:Ui.SnapFlow.SuspendLayout()
    try {
        foreach ($control in @($script:Ui.SnapFlow.Controls)) { $control.Dispose() }
        $script:Ui.SnapFlow.Controls.Clear()
        $script:SnapshotRows = @()
        $script:SnapshotBuildQueue = @($filtered.ToArray())
        $script:SnapshotBuildIndex = 0
        $script:SnapshotBuildWidth = [Math]::Max(300, $script:Ui.SnapFlow.ClientSize.Width - 22)
        $script:SnapshotClickHandler = {
            param($sender, $eventArgs)
            Select-StudioSnapshotRow -Path ([string]$sender.Tag)
        }
        if ($filtered.Count -eq 0) {
            $script:Ui.SnapEmpty.Visible = $true
            $script:Ui.SnapEmpty.Top = 70
        } else {
            $script:Ui.SnapEmpty.Visible = $false
        }
        $script:Ui.SnapCount.Text = if ($filtered.Count -eq 1) { '1 snapshot' } else { ('{0} snapshots' -f $filtered.Count) }
        $selected = Get-StudioSelectedSnapshotEntry
        if ($null -eq $selected -and $filtered.Count -gt 0) {
            $script:SelectedSnapshotPath = $filtered[0].Path
        }
    } finally {
        $script:Ui.SnapFlow.ResumeLayout($false)
    }
    $script:SnapshotsDirty = $false
    if ($filtered.Count -gt 0) {
        if ($null -eq $script:SnapshotBuildTimer) {
            $script:SnapshotBuildTimer = New-Object System.Windows.Forms.Timer
            $script:SnapshotBuildTimer.Interval = 15
            $script:SnapshotBuildTimer.Add_Tick({ Add-StudioSnapshotBatch -BatchSize 8 })
        }
        $script:SnapshotBuildTimer.Stop()
        $script:SnapshotBuildTimer.Start()
    }
}

# ---------------------------------------------------------------------------
# Exclusions
# ---------------------------------------------------------------------------

function Refresh-StudioExclusions {
    foreach ($card in $script:ExclusionCards) {
        if ($null -eq $card -or $null -eq $card.Tag) { continue }
        $context = $card.Tag
        $property = [string]$context.Property
        $propertyInfo = $script:Config.PSObject.Properties[$property]
        $items = if ($null -ne $propertyInfo) { @($propertyInfo.Value) } else { @() }
        $list = $context.List
        $list.BeginUpdate()
        try {
            $list.Items.Clear()
            foreach ($item in $items) {
                if (-not [string]::IsNullOrWhiteSpace([string]$item)) { [void]$list.Items.Add([string]$item) }
            }
        } finally {
            $list.EndUpdate()
        }
    }
    $script:ExclusionsDirty = $false
}

function Add-StudioExclusionValue {
    param($Context)
    $property = [string]$Context.Property
    $input = $Context.Input
    if ($input.Tag -eq 'placeholder') { return }
    $value = $input.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($value)) { return }
    $propertyInfo = $script:Config.PSObject.Properties[$property]
    $current = if ($null -ne $propertyInfo) { @($propertyInfo.Value) } else { @() }
    if ($current -notcontains $value) { $current += $value }
    if ($null -ne $propertyInfo) {
        $propertyInfo.Value = @($current)
    } else {
        $script:Config | Add-Member -NotePropertyName $property -NotePropertyValue @($current)
    }
    Save-SRConfig -Config $script:Config
    $input.Text = ''
    $input.ForeColor = $script:P.Text
    $input.Tag = ''
    Refresh-StudioExclusions
    Show-StudioToast 'Exclusion added.' $script:P.Green
}

function Remove-StudioExclusionValue {
    param($Context)
    $property = [string]$Context.Property
    $list = $Context.List
    if ($list.SelectedIndex -lt 0) { return }
    $value = [string]$list.SelectedItem
    $propertyInfo = $script:Config.PSObject.Properties[$property]
    $current = if ($null -ne $propertyInfo) { @($propertyInfo.Value) } else { @() }
    $current = @($current | Where-Object { [string]$_ -ne $value })
    if ($null -ne $propertyInfo) {
        $propertyInfo.Value = @($current)
    }
    Save-SRConfig -Config $script:Config
    Refresh-StudioExclusions
    Show-StudioToast 'Exclusion removed.' $script:P.Green
}

function New-StudioExclusionCard {
    param(
        [string]$Title,
        [string]$Description,
        [string]$PropertyName,
        [string]$Placeholder,
        [bool]$BrowseFolder = $false
    )
    $card = New-StudioCard -X 0 -Y 0 -Width 800 -Height 230 -Fill $script:P.Card -Border $script:P.BorderSoft -Radius 14
    $card.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 14)
    $titleLabel = New-StudioLabel -Text $Title -X 20 -Y 15 -Width 300 -Height 24 -Font $script:FontSemiboldLarge -Color $script:P.Text
    $card.Controls.Add($titleLabel)
    $descriptionLabel = New-StudioLabel -Text $Description -X 20 -Y 38 -Width ($card.Width - 40) -Height 18 -Font $script:FontBodySmall -Color $script:P.Muted
    $descriptionLabel.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $card.Controls.Add($descriptionLabel)

    $list = New-Object System.Windows.Forms.ListBox
    $list.Location = New-Object System.Drawing.Point(20, 63)
    $list.Size = New-Object System.Drawing.Size(($card.Width - 40), 82)
    $list.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $list.BackColor = $script:P.CardAlt
    $list.ForeColor = $script:P.Text
    $list.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $list.Font = $script:FontBody
    $list.IntegralHeight = $false
    $card.Controls.Add($list)

    $input = New-StudioTextBox -X 20 -Y 156 -Width 440 -Height 28
    $input.Text = $Placeholder
    $input.ForeColor = $script:P.Subtle
    $input.Tag = 'placeholder'
    $input.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $input.Add_GotFocus({
        param($sender, $eventArgs)
        if ($sender.Tag -eq 'placeholder') {
            $sender.Text = ''
            $sender.ForeColor = $script:P.Text
            $sender.Tag = ''
        }
    })
    $input.Add_LostFocus({
        param($sender, $eventArgs)
        if ([string]::IsNullOrWhiteSpace($sender.Text)) {
            $sender.Text = $script:ExclusionPlaceholders[$sender.AccessibleName]
            $sender.ForeColor = $script:P.Subtle
            $sender.Tag = 'placeholder'
        }
    })
    $input.AccessibleName = $PropertyName
    $card.Controls.Add($input)

    $add = New-StudioButton -Text 'Add' -X ($card.Width - 246) -Y 154 -Width 84 -Height 32 -Primary -Glyph ''
    $add.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
    $remove = New-StudioButton -Text 'Remove selected' -X ($card.Width - 154) -Y 154 -Width 132 -Height 32 -Danger
    $remove.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
    $card.Controls.Add($add)
    $card.Controls.Add($remove)

    $context = @{
        Property = $PropertyName
        List     = $list
        Input    = $input
    }
    $add.Tag = $context
    $remove.Tag = $context
    $add.Add_Click({
        param($sender, $eventArgs)
        Add-StudioExclusionValue -Context $sender.Tag
    })
    $remove.Add_Click({
        param($sender, $eventArgs)
        Remove-StudioExclusionValue -Context $sender.Tag
    })

    if ($BrowseFolder) {
        $browse = New-StudioButton -Text 'Browse...' -X ($card.Width - 350) -Y 154 -Width 86 -Height 32 -Glyph ''
        $browse.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
        $browse.Tag = $context
        $browse.Add_Click({
            param($sender, $eventArgs)
            $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
            $dialog.Description = 'Choose a folder to exclude from snapshots.'
            $dialog.ShowNewFolderButton = $false
            try {
                if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                    $sender.Tag.Input.Text = $dialog.SelectedPath
                    $sender.Tag.Input.ForeColor = $script:P.Text
                    $sender.Tag.Input.Tag = ''
                }
            } finally {
                $dialog.Dispose()
            }
        })
        $card.Controls.Add($browse)
        $input.Width = $card.Width - 370
    } else {
        $input.Width = $card.Width - 260
    }

    $card.Tag = $context
    $script:ExclusionCards += $card
    return $card
}

$script:ExclusionPlaceholders = @{
    excludeApps    = 'e.g. steam.exe or *game*'
    excludeFolders = 'e.g. C:\Projects\Private'
    excludeUrls    = 'e.g. *bank* or https://mail.example.com/*'
}

$exclusionsPage = New-StudioPage -Name 'Exclusions'
$exFlow = New-Object System.Windows.Forms.FlowLayoutPanel
$exFlow.Dock = [System.Windows.Forms.DockStyle]::Fill
$exFlow.Padding = New-Object System.Windows.Forms.Padding(24)
$exFlow.AutoScroll = $true
$exFlow.FlowDirection = [System.Windows.Forms.FlowDirection]::TopDown
$exFlow.WrapContents = $false
$exFlow.BackColor = $script:P.Bg
$exclusionsPage.Controls.Add($exFlow)
$script:Ui.ExclusionFlow = $exFlow

$exIntro = New-StudioLabel -Text 'Exclusions keep private or noisy windows out of every new snapshot. Changes apply immediately.' -X 0 -Y 0 -Width 800 -Height 22 -Font $script:FontBody -Color $script:P.Muted
$exIntro.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 12)
$exFlow.Controls.Add($exIntro)

$appCard = New-StudioExclusionCard -Title 'Applications' -Description 'Skip processes by name. Wildcards * and ? are supported.' -PropertyName 'excludeApps' -Placeholder 'e.g. steam.exe or *game*'
$exFlow.Controls.Add($appCard)
$folderCard = New-StudioExclusionCard -Title 'Folders' -Description 'Skip Explorer windows pointing at these folders or their children.' -PropertyName 'excludeFolders' -Placeholder 'e.g. C:\Projects\Private' -BrowseFolder $true
$exFlow.Controls.Add($folderCard)
$urlCard = New-StudioExclusionCard -Title 'URLs' -Description 'Skip matching browser tabs. Use a wildcard for broad patterns.' -PropertyName 'excludeUrls' -Placeholder 'e.g. *bank* or https://mail.example.com/*'
$exFlow.Controls.Add($urlCard)

$exFooter = New-StudioLabel -Text 'Exclusion rules are stored only in config.json on this PC.' -X 0 -Y 0 -Width 800 -Height 18 -Font $script:FontBodySmall -Color $script:P.Subtle
$exFooter.Margin = New-Object System.Windows.Forms.Padding(0, 2, 0, 0)
$exFlow.Controls.Add($exFooter)

function Layout-StudioExclusions {
    if (-not $script:Ui.ExclusionFlow) { return }
    $width = [Math]::Max(620, $script:Ui.ExclusionFlow.ClientSize.Width - 52)
    foreach ($card in $script:ExclusionCards) { $card.Width = $width }
    $exIntro.Width = $width
    $exFooter.Width = $width
}

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------

function New-StudioSettingsCard {
    param([string]$Title, [string]$Description, [int]$Height = 180)
    $card = New-StudioCard -X 0 -Y 0 -Width 800 -Height $Height -Fill $script:P.Card -Border $script:P.BorderSoft -Radius 14
    $card.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 14)
    $titleLabel = New-StudioLabel -Text $Title -X 20 -Y 15 -Width 360 -Height 24 -Font $script:FontSemiboldLarge -Color $script:P.Text
    $card.Controls.Add($titleLabel)
    $descriptionLabel = New-StudioLabel -Text $Description -X 20 -Y 38 -Width ($card.Width - 40) -Height 18 -Font $script:FontBodySmall -Color $script:P.Muted
    $descriptionLabel.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $card.Controls.Add($descriptionLabel)
    return $card
}

function New-StudioNumeric {
    param([int]$X, [int]$Y, [int]$Value, [int]$Min, [int]$Max, [int]$Width = 84)
    $numeric = New-Object System.Windows.Forms.NumericUpDown
    $numeric.Location = New-Object System.Drawing.Point($X, $Y)
    $numeric.Size = New-Object System.Drawing.Size($Width, 28)
    $numeric.Minimum = $Min
    $numeric.Maximum = $Max
    $numeric.Value = [Math]::Max($Min, [Math]::Min($Max, $Value))
    $numeric.BackColor = $script:P.CardAlt
    $numeric.ForeColor = $script:P.Text
    $numeric.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $numeric.Font = $script:FontBody
    return $numeric
}

$settingsPage = New-StudioPage -Name 'Settings'
$settingsFlow = New-Object System.Windows.Forms.FlowLayoutPanel
$settingsFlow.Location = New-Object System.Drawing.Point(0, 0)
$settingsFlow.Size = New-Object System.Drawing.Size(984, 622)
$settingsFlow.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$settingsFlow.Padding = New-Object System.Windows.Forms.Padding(24)
$settingsFlow.AutoScroll = $true
$settingsFlow.FlowDirection = [System.Windows.Forms.FlowDirection]::TopDown
$settingsFlow.WrapContents = $false
$settingsFlow.BackColor = $script:P.Bg
$settingsPage.Controls.Add($settingsFlow)
$script:Ui.SettingsFlow = $settingsFlow

$settingsBar = New-Object System.Windows.Forms.Panel
$settingsBar.Location = New-Object System.Drawing.Point(0, 622)
$settingsBar.Size = New-Object System.Drawing.Size(984, 70)
$settingsBar.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$settingsBar.BackColor = $script:P.Sidebar
$settingsPage.Controls.Add($settingsBar)
$settingsBarLine = New-Object System.Windows.Forms.Panel
$settingsBarLine.Dock = [System.Windows.Forms.DockStyle]::Top
$settingsBarLine.Height = 1
$settingsBarLine.BackColor = $script:P.BorderSoft
$settingsBar.Controls.Add($settingsBarLine)

$settingsStatus = New-StudioLabel -Text '' -X 24 -Y 24 -Width 460 -Height 20 -Font $script:FontBodySmall -Color $script:P.Muted
$settingsBar.Controls.Add($settingsStatus)
$script:Ui.StatusLabel = $settingsStatus

$settingsReset = New-StudioButton -Text 'Reset defaults' -X 650 -Y 16 -Width 130 -Height 38 -Glyph ''
$settingsReset.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$settingsReset.Add_Click({ Reset-StudioSettings })
$settingsBar.Controls.Add($settingsReset)
$script:Ui.SettingsReset = $settingsReset

$settingsSave = New-StudioButton -Text 'Save changes' -X 792 -Y 16 -Width 160 -Height 38 -Primary -Glyph ''
$settingsSave.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$settingsSave.Add_Click({ Save-StudioSettings })
$settingsBar.Controls.Add($settingsSave)
$script:Ui.SettingsSave = $settingsSave

$settingsCards = New-Object System.Collections.Generic.List[object]

# Card: snapshot rhythm
$rhythmCard = New-StudioSettingsCard -Title 'Snapshot rhythm' -Description 'How often your session is saved, and how much history stays on disk.' -Height 164
$settingsFlow.Controls.Add($rhythmCard)
$settingsCards.Add($rhythmCard)

$rhythmLabel1 = New-StudioLabel -Text 'SNAPSHOT EVERY' -X 20 -Y 70 -Width 160 -Height 16 -Font $script:FontMono -Color $script:P.Subtle
$rhythmCard.Controls.Add($rhythmLabel1)
$numInterval = New-StudioNumeric -X 20 -Y 90 -Value 3 -Min 1 -Max 240 -Width 84
$rhythmCard.Controls.Add($numInterval)
$rhythmUnit1 = New-StudioLabel -Text 'minutes' -X 110 -Y 94 -Width 80 -Height 20 -Font $script:FontBodySmall -Color $script:P.Muted
$rhythmCard.Controls.Add($rhythmUnit1)

$rhythmLabel2 = New-StudioLabel -Text 'KEEP' -X 270 -Y 70 -Width 160 -Height 16 -Font $script:FontMono -Color $script:P.Subtle
$rhythmCard.Controls.Add($rhythmLabel2)
$numKeep = New-StudioNumeric -X 270 -Y 90 -Value 48 -Min 1 -Max 1000 -Width 84
$rhythmCard.Controls.Add($numKeep)
$rhythmUnit2 = New-StudioLabel -Text 'snapshots' -X 360 -Y 94 -Width 100 -Height 20 -Font $script:FontBodySmall -Color $script:P.Muted
$rhythmCard.Controls.Add($rhythmUnit2)

$rhythmLabel3 = New-StudioLabel -Text 'DELETE OLDER THAN' -X 520 -Y 70 -Width 180 -Height 16 -Font $script:FontMono -Color $script:P.Subtle
$rhythmCard.Controls.Add($rhythmLabel3)
$numDays = New-StudioNumeric -X 520 -Y 90 -Value 0 -Min 0 -Max 3650 -Width 84
$rhythmCard.Controls.Add($numDays)
$rhythmUnit3 = New-StudioLabel -Text 'days' -X 610 -Y 94 -Width 80 -Height 20 -Font $script:FontBodySmall -Color $script:P.Muted
$rhythmCard.Controls.Add($rhythmUnit3)
$rhythmHint = New-StudioLabel -Text '0 days keeps history by count only. Snapshot files are tiny JSON documents.' -X 20 -Y 126 -Width 700 -Height 18 -Font $script:FontBodySmall -Color $script:P.Subtle
$rhythmCard.Controls.Add($rhythmHint)

# Card: restore behavior
$restoreCard = New-StudioSettingsCard -Title 'Restore behavior' -Description 'Choose how Session Recovery offers to reopen apps, folders and tabs.' -Height 206
$settingsFlow.Controls.Add($restoreCard)
$settingsCards.Add($restoreCard)

$promptLabel = New-StudioLabel -Text 'WHEN WINDOWS STARTS' -X 20 -Y 70 -Width 220 -Height 16 -Font $script:FontMono -Color $script:P.Subtle
$restoreCard.Controls.Add($promptLabel)
$comboPrompt = New-StudioCombo -X 20 -Y 90 -Width 210
[void]$comboPrompt.Items.Add('Always ask')
[void]$comboPrompt.Items.Add('Only after a crash')
[void]$comboPrompt.Items.Add('Never ask')
$comboPrompt.SelectedIndex = 1
$restoreCard.Controls.Add($comboPrompt)

$maxAgeLabel = New-StudioLabel -Text 'MAX RESTORE AGE' -X 290 -Y 70 -Width 180 -Height 16 -Font $script:FontMono -Color $script:P.Subtle
$restoreCard.Controls.Add($maxAgeLabel)
$numMaxAge = New-StudioNumeric -X 290 -Y 90 -Value 72 -Min 1 -Max 8760 -Width 90
$restoreCard.Controls.Add($numMaxAge)
$maxAgeUnit = New-StudioLabel -Text 'hours' -X 388 -Y 94 -Width 80 -Height 20 -Font $script:FontBodySmall -Color $script:P.Muted
$restoreCard.Controls.Add($maxAgeUnit)

$toggleRestoreBrowsers = New-StudioToggle -X 20 -Y 146 -Checked $true
$restoreCard.Controls.Add($toggleRestoreBrowsers)
$restoreBrowserLabel = New-StudioLabel -Text 'Reopen captured browser tabs' -X 76 -Y 150 -Width 320 -Height 20 -Font $script:FontBody -Color $script:P.Text
$restoreCard.Controls.Add($restoreBrowserLabel)

$tabModeLabel = New-StudioLabel -Text 'TAB RESTORE MODE' -X 440 -Y 132 -Width 180 -Height 16 -Font $script:FontMono -Color $script:P.Subtle
$restoreCard.Controls.Add($tabModeLabel)
$comboTabMode = New-StudioCombo -X 440 -Y 152 -Width 180
[void]$comboTabMode.Items.Add('Smart')
[void]$comboTabMode.Items.Add('Captured')
[void]$comboTabMode.Items.Add('Native')
[void]$comboTabMode.Items.Add('None')
$comboTabMode.SelectedIndex = 0
$restoreCard.Controls.Add($comboTabMode)

# Card: browser capture
$browserCard = New-StudioSettingsCard -Title 'Browser capture' -Description 'Chrome, Edge, Brave and other Chromium browsers use a safe live fallback when their session files are empty.' -Height 206
$settingsFlow.Controls.Add($browserCard)
$settingsCards.Add($browserCard)

$toggleCaptureBrowsers = New-StudioToggle -X 20 -Y 76 -Checked $true
$browserCard.Controls.Add($toggleCaptureBrowsers)
$captureBrowserLabel = New-StudioLabel -Text 'Capture browser tabs' -X 76 -Y 80 -Width 300 -Height 20 -Font $script:FontBody -Color $script:P.Text
$browserCard.Controls.Add($captureBrowserLabel)

$toggleApprox = New-StudioToggle -X 20 -Y 116 -Checked $true
$browserCard.Controls.Add($toggleApprox)
$approxLabel = New-StudioLabel -Text 'Use recent history when session files are empty' -X 76 -Y 120 -Width 420 -Height 20 -Font $script:FontBody -Color $script:P.Text
$browserCard.Controls.Add($approxLabel)
$approxHint = New-StudioLabel -Text 'This can include a few recently visited pages that are already closed. Tabs are marked approximate.' -X 76 -Y 140 -Width 440 -Height 32 -Font $script:FontBodySmall -Color $script:P.Subtle
$browserCard.Controls.Add($approxHint)

$lookbackLabel = New-StudioLabel -Text 'HISTORY LOOKBACK' -X 560 -Y 76 -Width 180 -Height 16 -Font $script:FontMono -Color $script:P.Subtle
$browserCard.Controls.Add($lookbackLabel)
$numLookback = New-StudioNumeric -X 560 -Y 96 -Value 24 -Min 1 -Max 168 -Width 90
$browserCard.Controls.Add($numLookback)
$lookbackUnit = New-StudioLabel -Text 'hours' -X 658 -Y 100 -Width 80 -Height 20 -Font $script:FontBodySmall -Color $script:P.Muted
$browserCard.Controls.Add($lookbackUnit)
$lookbackHint = New-StudioLabel -Text 'Only used when the exact session file cannot be read.' -X 560 -Y 128 -Width 260 -Height 32 -Font $script:FontBodySmall -Color $script:P.Subtle
$browserCard.Controls.Add($lookbackHint)

# Card: background and desktop
$backgroundCard = New-StudioSettingsCard -Title 'Background & desktop' -Description 'Keep Session Recovery close without leaving windows open.' -Height 240
$settingsFlow.Controls.Add($backgroundCard)
$settingsCards.Add($backgroundCard)

$toggleStartup = New-StudioToggle -X 20 -Y 76 -Checked $true
$backgroundCard.Controls.Add($toggleStartup)
$startupLabel = New-StudioLabel -Text 'Start the background app with Windows' -X 76 -Y 80 -Width 360 -Height 20 -Font $script:FontBody -Color $script:P.Text
$backgroundCard.Controls.Add($startupLabel)
$startupHint = New-StudioLabel -Text 'Creates a shortcut in your Startup folder. No scheduled task or admin rights required.' -X 76 -Y 100 -Width 360 -Height 18 -Font $script:FontBodySmall -Color $script:P.Subtle
$backgroundCard.Controls.Add($startupHint)

$toggleDesktop = New-StudioToggle -X 20 -Y 132 -Checked $true
$backgroundCard.Controls.Add($toggleDesktop)
$desktopLabel = New-StudioLabel -Text 'Show a Session Recovery icon on the desktop' -X 76 -Y 136 -Width 360 -Height 20 -Font $script:FontBody -Color $script:P.Text
$backgroundCard.Controls.Add($desktopLabel)

$toggleNotifications = New-StudioToggle -X 20 -Y 188 -Checked $true
$backgroundCard.Controls.Add($toggleNotifications)
$notificationsLabel = New-StudioLabel -Text 'Show snapshot notifications' -X 76 -Y 192 -Width 300 -Height 20 -Font $script:FontBody -Color $script:P.Text
$backgroundCard.Controls.Add($notificationsLabel)

$startNow = New-StudioButton -Text 'Start background now' -X 470 -Y 74 -Width 300 -Height 34 -Glyph ([string][char]0xE768)
$startNow.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$startNow.Add_Click({ Start-StudioBackground })
$backgroundCard.Controls.Add($startNow)
$openStartup = New-StudioButton -Text 'Open Startup folder' -X 470 -Y 116 -Width 300 -Height 34 -Glyph ([string][char]0xE838)
$openStartup.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$openStartup.Add_Click({ Open-StudioPath ([Environment]::GetFolderPath('Startup')) })
$backgroundCard.Controls.Add($openStartup)
$openDesktop = New-StudioButton -Text 'Open Desktop folder' -X 470 -Y 158 -Width 300 -Height 34 -Glyph ([string][char]0xE838)
$openDesktop.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$openDesktop.Add_Click({ Open-StudioPath ([Environment]::GetFolderPath('Desktop')) })
$backgroundCard.Controls.Add($openDesktop)

# Card: storage and privacy
$storageCard = New-StudioSettingsCard -Title 'Storage & privacy' -Description 'Everything Session Recovery saves stays in your local profile.' -Height 260
$settingsFlow.Controls.Add($storageCard)
$settingsCards.Add($storageCard)

$dataLabel = New-StudioLabel -Text 'DATA FOLDER' -X 20 -Y 70 -Width 160 -Height 16 -Font $script:FontMono -Color $script:P.Subtle
$storageCard.Controls.Add($dataLabel)
$dataPath = New-StudioLabel -Text '' -X 20 -Y 88 -Width 700 -Height 20 -Font $script:FontMono -Color $script:P.Muted
$storageCard.Controls.Add($dataPath)
$script:Ui.DataPath = $dataPath
$openData = New-StudioButton -Text 'Open data folder' -X 20 -Y 116 -Width 170 -Height 32 -Glyph ([string][char]0xE838)
$openData.Add_Click({ Open-StudioPath (Get-SRRoot) })
$storageCard.Controls.Add($openData)

$configLabel = New-StudioLabel -Text 'CONFIG FILE' -X 20 -Y 158 -Width 160 -Height 16 -Font $script:FontMono -Color $script:P.Subtle
$storageCard.Controls.Add($configLabel)
$configPath = New-StudioLabel -Text '' -X 20 -Y 176 -Width 700 -Height 20 -Font $script:FontMono -Color $script:P.Muted
$storageCard.Controls.Add($configPath)
$script:Ui.ConfigPath = $configPath
$openConfig = New-StudioButton -Text 'Open config' -X 20 -Y 204 -Width 140 -Height 32 -Glyph ''
$openConfig.Add_Click({
    $path = Get-SRConfigPath
    if (Test-Path -LiteralPath $path) { Start-Process -FilePath 'notepad.exe' -ArgumentList ('\"{0}\"' -f $path) | Out-Null }
})
$storageCard.Controls.Add($openConfig)
$openLogs = New-StudioButton -Text 'Open logs' -X 172 -Y 204 -Width 140 -Height 32 -Glyph ([string][char]0xE838)
$openLogs.Add_Click({ Open-StudioPath (Get-SRLogDirectory) })
$storageCard.Controls.Add($openLogs)

$settingsPage.Add_Resize({ Layout-StudioSettings })

function Load-StudioSettings {
    $script:Config = Get-SRConfig
    $numInterval.Value = [Math]::Max(1, [Math]::Min(240, [int]$script:Config.snapshotIntervalMinutes))
    $numKeep.Value = [Math]::Max(1, [Math]::Min(1000, [int]$script:Config.keepSnapshots))
    $numDays.Value = [Math]::Max(0, [Math]::Min(3650, [int]$script:Config.keepSnapshotDays))
    $numMaxAge.Value = [Math]::Max(1, [Math]::Min(8760, [int]$script:Config.maxRestoreAgeHours))
    $numLookback.Value = [Math]::Max(1, [Math]::Min(168, [int]$script:Config.tabHistoryLookbackHours))
    $promptMap = @('Always', 'CrashOnly', 'Never')
    $promptIndex = [array]::IndexOf($promptMap, [string]$script:Config.promptOnLogon)
    $comboPrompt.SelectedIndex = if ($promptIndex -ge 0) { $promptIndex } else { 1 }
    $tabMap = @('Smart', 'Captured', 'Native', 'None')
    $tabIndex = [array]::IndexOf($tabMap, [string]$script:Config.defaultTabMode)
    $comboTabMode.SelectedIndex = if ($tabIndex -ge 0) { $tabIndex } else { 0 }
    $toggleRestoreBrowsers.Checked = [bool]$script:Config.restoreBrowsers
    $toggleCaptureBrowsers.Checked = [bool]$script:Config.captureBrowserTabs
    $toggleApprox.Checked = [bool]$script:Config.captureApproximateTabs
    $toggleNotifications.Checked = [bool]$script:Config.showNotifications
    $toggleStartup.Checked = Test-Path -LiteralPath (Get-StudioStartupShortcutPath)
    $toggleDesktop.Checked = Test-Path -LiteralPath (Get-StudioDesktopShortcutPath)
    $script:Ui.DataPath.Text = Get-SRRoot
    $script:Ui.ConfigPath.Text = Get-SRConfigPath
    $script:SettingsLoaded = $true
    Set-StudioStatus '' $script:P.Muted
}

function Save-StudioSettings {
    try {
        $config = Get-SRConfig
        $config.snapshotIntervalMinutes = [int]$numInterval.Value
        $config.keepSnapshots = [int]$numKeep.Value
        $config.keepSnapshotDays = [int]$numDays.Value
        $config.maxRestoreAgeHours = [int]$numMaxAge.Value
        $config.tabHistoryLookbackHours = [int]$numLookback.Value
        $promptMap = @('Always', 'CrashOnly', 'Never')
        $config.promptOnLogon = $promptMap[[Math]::Max(0, $comboPrompt.SelectedIndex)]
        $tabMap = @('Smart', 'Captured', 'Native', 'None')
        $config.defaultTabMode = $tabMap[[Math]::Max(0, $comboTabMode.SelectedIndex)]
        $config.restoreBrowsers = [bool]$toggleRestoreBrowsers.Checked
        $config.captureBrowserTabs = [bool]$toggleCaptureBrowsers.Checked
        $config.captureApproximateTabs = [bool]$toggleApprox.Checked
        $config.showNotifications = [bool]$toggleNotifications.Checked
        $config.startWithWindows = [bool]$toggleStartup.Checked
        $config.desktopShortcut = [bool]$toggleDesktop.Checked
        Save-SRConfig -Config $config
        $script:Config = $config

        $startupOk = Set-StudioStartWithWindows -Enabled ([bool]$toggleStartup.Checked)
        $desktopOk = Set-StudioDesktopShortcut -Enabled ([bool]$toggleDesktop.Checked)
        if (-not $startupOk) {
            $config.startWithWindows = $false
            $toggleStartup.Checked = $false
            Set-StudioStatus 'Settings saved, but the Startup shortcut could not be created.' $script:P.Amber
        } elseif (-not $desktopOk) {
            $config.desktopShortcut = $false
            $toggleDesktop.Checked = $false
            Set-StudioStatus 'Settings saved, but the desktop shortcut could not be created.' $script:P.Amber
        } else {
            Set-StudioStatus 'Settings saved. Background protection will pick them up automatically.' $script:P.Green
        }
        Save-SRConfig -Config $config
        $script:Config = $config
        Refresh-StudioData
        Show-StudioToast 'Settings saved.' $script:P.Green
    } catch {
        Set-StudioStatus ('Could not save settings: ' + $_.Exception.Message) $script:P.Red
        Show-StudioToast ('Could not save settings: ' + $_.Exception.Message) $script:P.Red
    }
}

function Reset-StudioSettings {
    $answer = [System.Windows.Forms.MessageBox]::Show(
        'Reset all capture, restore, startup and storage settings? Your exclusion lists will be kept.',
        'Reset settings', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    try {
        $current = Get-SRConfig
        $defaults = Get-SRDefaultConfig
        $defaults.excludeApps = @($current.excludeApps)
        $defaults.excludeFolders = @($current.excludeFolders)
        $defaults.excludeUrls = @($current.excludeUrls)
        Save-SRConfig -Config $defaults
        $script:Config = Get-SRConfig
        $script:SettingsLoaded = $false
        Load-StudioSettings
        Save-StudioSettings
        Show-StudioToast 'Settings reset to defaults.' $script:P.Green
    } catch {
        Set-StudioStatus ('Could not reset settings: ' + $_.Exception.Message) $script:P.Red
    }
}

function Layout-StudioSettings {
    if (-not $script:Ui.SettingsFlow) { return }
    $flow = $script:Ui.SettingsFlow
    $flow.Width = $settingsPage.ClientSize.Width
    $flow.Height = [Math]::Max(160, $settingsPage.ClientSize.Height - 70)
    $settingsBar.Top = $settingsPage.ClientSize.Height - 70
    $settingsBar.Width = $settingsPage.ClientSize.Width
    $cardWidth = [Math]::Max(620, $flow.ClientSize.Width - 52)
    foreach ($card in $settingsCards) { $card.Width = $cardWidth }
    $settingsSave.Left = $settingsPage.ClientSize.Width - 184
    $settingsReset.Left = $settingsSave.Left - 142
    $settingsStatus.Width = [Math]::Max(200, $settingsReset.Left - 48)
}

# ---------------------------------------------------------------------------
# Diagnostics
# ---------------------------------------------------------------------------

$diagnosticsPage = New-StudioPage -Name 'Diagnostics'
$diagFlow = New-Object System.Windows.Forms.FlowLayoutPanel
$diagFlow.Dock = [System.Windows.Forms.DockStyle]::Fill
$diagFlow.Padding = New-Object System.Windows.Forms.Padding(24)
$diagFlow.AutoScroll = $true
$diagFlow.FlowDirection = [System.Windows.Forms.FlowDirection]::TopDown
$diagFlow.WrapContents = $false
$diagFlow.BackColor = $script:P.Bg
$diagnosticsPage.Controls.Add($diagFlow)
$script:Ui.DiagFlow = $diagFlow

$diagHealthCard = New-StudioSettingsCard -Title 'System health' -Description 'A local check of snapshots, background protection and browser capture.' -Height 160
$diagFlow.Controls.Add($diagHealthCard)
$diagHealthTitle = New-StudioLabel -Text 'Checking...' -X 20 -Y 70 -Width 500 -Height 30 -Font $script:FontTitle -Color $script:P.Text
$diagHealthCard.Controls.Add($diagHealthTitle)
$script:Ui.DiagHealthTitle = $diagHealthTitle
$diagHealthDetail = New-StudioLabel -Text 'Reading local status...' -X 20 -Y 108 -Width 520 -Height 32 -Font $script:FontBodySmall -Color $script:P.Muted
$diagHealthCard.Controls.Add($diagHealthDetail)
$script:Ui.DiagHealthDetail = $diagHealthDetail

$diagRing = New-Object SessionRecovery.Studio.StudioRing
$diagRing.Location = New-Object System.Drawing.Point(640, 20)
$diagRing.Size = New-Object System.Drawing.Size(124, 124)
$diagRing.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$diagRing.Value = 0
$diagRing.CenterText = '--'
$diagRing.Caption = 'HEALTH'
$diagRing.ProgressColor = $script:P.Green
$diagRing.ProgressEndColor = $script:P.Accent2
$diagRing.TrackColor = $script:P.Border
$diagHealthCard.Controls.Add($diagRing)
$script:Ui.DiagRing = $diagRing

$diagRefresh = New-StudioButton -Text 'Run checks' -X 430 -Y 70 -Width 160 -Height 34 -Glyph ([string][char]0xE72C)
$diagRefresh.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$diagRefresh.Add_Click({ Refresh-StudioDiagnostics })
$diagHealthCard.Controls.Add($diagRefresh)

$diagChecksCard = New-StudioSettingsCard -Title 'Checks' -Description 'No cloud services and no account. These checks run against this PC only.' -Height 202
$diagFlow.Controls.Add($diagChecksCard)
$diagCheckFlow = New-Object System.Windows.Forms.FlowLayoutPanel
$diagCheckFlow.Location = New-Object System.Drawing.Point(20, 60)
$diagCheckFlow.Size = New-Object System.Drawing.Size(760, 126)
$diagCheckFlow.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$diagCheckFlow.FlowDirection = [System.Windows.Forms.FlowDirection]::TopDown
$diagCheckFlow.WrapContents = $false
$diagCheckFlow.AutoScroll = $true
$diagCheckFlow.BackColor = $script:P.Card
$diagChecksCard.Controls.Add($diagCheckFlow)
$script:Ui.DiagCheckFlow = $diagCheckFlow
$script:DiagnosticRows = @()

$diagBrowserCard = New-StudioSettingsCard -Title 'Detected browsers' -Description 'Supported browsers found on this PC. Firefox uses its session store; Chromium browsers use session files plus the live fallback.' -Height 152
$diagFlow.Controls.Add($diagBrowserCard)
$diagBrowserLabel = New-StudioLabel -Text 'Checking...' -X 20 -Y 70 -Width 760 -Height 64 -Font $script:FontBodySmall -Color $script:P.Muted
$diagBrowserCard.Controls.Add($diagBrowserLabel)
$script:Ui.DiagBrowserLabel = $diagBrowserLabel

$diagLogCard = New-StudioSettingsCard -Title 'Activity log' -Description 'The most recent local log entries.' -Height 310
$diagFlow.Controls.Add($diagLogCard)
$diagLogText = New-StudioTextBox -X 20 -Y 62 -Width 760 -Height 180
$diagLogText.Multiline = $true
$diagLogText.ReadOnly = $true
$diagLogText.ScrollBars = [System.Windows.Forms.ScrollBars]::Both
$diagLogText.WordWrap = $false
$diagLogText.Font = $script:FontMono
$diagLogText.BackColor = $script:P.CardAlt
$diagLogText.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$diagLogCard.Controls.Add($diagLogText)
$script:Ui.DiagLogText = $diagLogText

$diagOpenLogs = New-StudioButton -Text 'Open logs' -X 20 -Y 252 -Width 124 -Height 32 -Glyph ([string][char]0xE838)
$diagOpenLogs.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
$diagOpenLogs.Add_Click({ Open-StudioPath (Get-SRLogDirectory) })
$diagLogCard.Controls.Add($diagOpenLogs)
$diagCopy = New-StudioButton -Text 'Copy report' -X 154 -Y 252 -Width 132 -Height 32 -Glyph ''
$diagCopy.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
$diagCopy.Add_Click({
    try {
        [System.Windows.Forms.Clipboard]::SetText([string]$script:DiagnosticsReport)
        Show-StudioToast 'Diagnostics report copied.' $script:P.Green
    } catch {
        Show-StudioToast ('Could not copy report: ' + $_.Exception.Message) $script:P.Red
    }
})
$diagLogCard.Controls.Add($diagCopy)

$diagnosticsPage.Add_Resize({ Layout-StudioDiagnostics })

function Add-StudioDiagnosticRow {
    param([bool]$Ok, [string]$Text, [string]$Detail = '')
    if (-not $script:Ui.DiagCheckFlow) { return }
    $row = New-Object System.Windows.Forms.Panel
    $row.Height = 24
    $row.Width = [Math]::Max(200, $script:Ui.DiagCheckFlow.ClientSize.Width - 8)
    $row.BackColor = $script:P.Card
    $row.Margin = New-Object System.Windows.Forms.Padding(0)
    $iconColor = if ($Ok) { $script:P.Green } else { $script:P.Amber }
    $icon = New-StudioLabel -Text $(if ($Ok) { [string][char]0xE73E } else { [string][char]0xE7BA }) -X 4 -Y 2 -Width 20 -Height 20 -Font (New-Object System.Drawing.Font('Segoe MDL2 Assets', 10)) -Color $iconColor -Align 'MiddleCenter'
    $row.Controls.Add($icon)
    $message = $Text
    if (-not [string]::IsNullOrWhiteSpace($Detail)) { $message += '  —  ' + $Detail }
    $label = New-StudioLabel -Text $message -X 28 -Y 2 -Width ($row.Width - 32) -Height 20 -Font $script:FontBodySmall -Color $script:P.Text
    $label.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $row.Controls.Add($label)
    [void]$script:Ui.DiagCheckFlow.Controls.Add($row)
    $script:DiagnosticRows += $row
}

function Render-StudioDiagnostics {
    param($Diag)
    if (-not $script:Ui.DiagHealthTitle) { return }
    try {
        $diag = $Diag
        if ($null -eq $diag) { throw 'Diagnostics returned no data.' }
        $script:Diagnostics = $diag
        $script:DiagnosticsDirty = $false
        $interval = [Math]::Max(1, [int]$script:Config.snapshotIntervalMinutes)
        $age = $null
        if ($null -ne $diag.LatestSnapshotAgeMinutes) { $age = [double]$diag.LatestSnapshotAgeMinutes }
        $score = 100
        if (-not $diag.ConfigValid) { $score -= 25 }
        if ([int]$diag.SnapshotCount -eq 0) { $score -= 30 }
        if ($null -ne $age -and $age -gt ($interval * 2.5)) { $score -= 20 }
        if ([string]$diag.ScheduleMode -eq 'Not running') { $score -= 20 }
        if (@($diag.Browsers).Count -eq 0) { $score -= 5 }
        $score = [Math]::Max(0, [Math]::Min(100, $score))
        $script:Ui.DiagRing.Value = $score
        $script:Ui.DiagRing.CenterText = [string]$score
        if ($score -ge 80) {
            $script:Ui.DiagRing.ProgressColor = $script:P.Green
            $script:Ui.DiagRing.ProgressEndColor = $script:P.Accent2
            $script:Ui.DiagHealthTitle.Text = 'Everything looks healthy'
            $script:Ui.DiagHealthTitle.ForeColor = $script:P.Text
        } elseif ($score -ge 50) {
            $script:Ui.DiagRing.ProgressColor = $script:P.Amber
            $script:Ui.DiagRing.ProgressEndColor = $script:P.Amber
            $script:Ui.DiagHealthTitle.Text = 'A little attention is needed'
            $script:Ui.DiagHealthTitle.ForeColor = $script:P.Amber
        } else {
            $script:Ui.DiagRing.ProgressColor = $script:P.Red
            $script:Ui.DiagRing.ProgressEndColor = $script:P.Red
            $script:Ui.DiagHealthTitle.Text = 'Protection needs attention'
            $script:Ui.DiagHealthTitle.ForeColor = $script:P.Red
        }
        $script:Ui.DiagHealthDetail.Text = ('{0} snapshot(s)  •  {1}  •  {2} browser(s) detected' -f $diag.SnapshotCount, [string]$diag.ScheduleMode, @($diag.Browsers).Count)

        foreach ($row in $script:DiagnosticRows) { $row.Dispose() }
        $script:DiagnosticRows = @()
        $script:Ui.DiagCheckFlow.Controls.Clear()

        if ($diag.ConfigValid) {
            Add-StudioDiagnosticRow -Ok $true -Text 'Configuration is valid' -Detail (Split-Path -Leaf ([string]$diag.ConfigPath))
        } else {
            Add-StudioDiagnosticRow -Ok $false -Text 'Configuration needs attention' -Detail ([string]$diag.ConfigError)
        }
        if ($null -eq $age) {
            Add-StudioDiagnosticRow -Ok $false -Text 'No snapshots saved yet' -Detail 'Use Capture now to make the first one.'
        } elseif ($age -le ($interval * 2.5)) {
            Add-StudioDiagnosticRow -Ok $true -Text 'Latest snapshot is fresh' -Detail (Format-StudioAge -CapturedAt ([datetime]$diag.LatestSnapshotAt))
        } else {
            Add-StudioDiagnosticRow -Ok $false -Text 'Latest snapshot is older than expected' -Detail (Format-StudioAge -CapturedAt ([datetime]$diag.LatestSnapshotAt))
        }
        if ([string]$diag.ScheduleMode -eq 'Not running') {
            Add-StudioDiagnosticRow -Ok $false -Text 'Background protection is not running' -Detail 'Start the background app from Settings.'
        } else {
            Add-StudioDiagnosticRow -Ok $true -Text 'Background protection is active' -Detail ([string]$diag.ScheduleMode)
        }
        if (@($diag.Browsers).Count -gt 0) {
            Add-StudioDiagnosticRow -Ok $true -Text 'Supported browsers detected' -Detail (@($diag.Browsers | ForEach-Object { $_.Name }) -join ', ')
        } else {
            Add-StudioDiagnosticRow -Ok $false -Text 'No supported browsers detected' -Detail 'Chrome, Edge, Brave or Firefox can be captured when installed.'
        }
        if (Test-Path -LiteralPath ([string]$diag.SnapshotDirectory)) {
            Add-StudioDiagnosticRow -Ok $true -Text 'Snapshot storage is writable' -Detail (Format-StudioBytes -Bytes ([int64]$diag.SnapshotBytes))
        } else {
            Add-StudioDiagnosticRow -Ok $false -Text 'Snapshot folder is missing' -Detail ([string]$diag.SnapshotDirectory)
        }

        $browsers = @($diag.Browsers)
        if ($browsers.Count -eq 0) {
            $script:Ui.DiagBrowserLabel.Text = 'No supported browsers were detected. Session Recovery will still capture apps and folders.'
        } else {
            $script:Ui.DiagBrowserLabel.Text = ($browsers | ForEach-Object { '{0}  —  {1}' -f $_.Name, $_.Exe }) -join "`r`n"
        }

        $logPath = [string]$diag.LogPath
        if (Test-Path -LiteralPath $logPath) {
            $log = @(Get-Content -LiteralPath $logPath -Tail 160 -ErrorAction SilentlyContinue)
            $script:Ui.DiagLogText.Text = ($log -join "`r`n")
        } else {
            $script:Ui.DiagLogText.Text = 'No log file yet. Once a snapshot or restore runs, activity appears here.'
        }
        $script:DiagnosticsReport = @(
            'Session Recovery diagnostics',
            'Generated: ' + $diag.GeneratedAt,
            'Health score: ' + $score,
            'Installed: ' + $diag.Installed,
            'Config valid: ' + $diag.ConfigValid,
            'Snapshot count: ' + $diag.SnapshotCount,
            'Latest snapshot age (min): ' + $diag.LatestSnapshotAgeMinutes,
            'Schedule mode: ' + $diag.ScheduleMode,
            'Browsers: ' + (($browsers | ForEach-Object { $_.Name }) -join ', '),
            'Log: ' + $diag.LogPath
        ) -join "`r`n"
        Layout-StudioDiagnostics
    } catch {
        $script:Ui.DiagHealthTitle.Text = 'Diagnostics could not run'
        $script:Ui.DiagHealthTitle.ForeColor = $script:P.Red
        $script:Ui.DiagHealthDetail.Text = $_.Exception.Message
        $script:Ui.DiagRing.Value = 0
        $script:Ui.DiagRing.CenterText = '!'
        $script:DiagnosticsDirty = $true
    }
}

function Start-StudioDiagnosticsRefresh {
    param([switch]$Force)
    if (-not $script:Ui.DiagHealthTitle) { return }
    if ($script:DiagnosticsLoading) { return }
    if (-not $Force -and -not $script:DiagnosticsDirty -and $null -ne $script:Diagnostics) { return }
    $script:DiagnosticsDirty = $true
    $script:DiagnosticsLoading = $true
    $script:Ui.DiagHealthTitle.Text = 'Checking local health...'
    $script:Ui.DiagHealthTitle.ForeColor = $script:P.Text
    $script:Ui.DiagHealthDetail.Text = 'Reading snapshots, tasks and browser information in the background.'
    $script:Ui.DiagRing.Value = 0
    $script:Ui.DiagRing.CenterText = '...'
    try {
        Start-StudioWorker -Name 'Diagnostics' -Script {
            param($modulePath)
            $ErrorActionPreference = 'Stop'
            Import-Module $modulePath -Force -ErrorAction Stop | Out-Null
            Get-SRDiagnostics | ConvertTo-Json -Depth 10 -Compress
        } -Arguments @($modulePath)
    } catch {
        $script:DiagnosticsLoading = $false
        $script:DiagnosticsDirty = $true
        $script:Ui.DiagHealthTitle.Text = 'Diagnostics could not start'
        $script:Ui.DiagHealthTitle.ForeColor = $script:P.Red
        $script:Ui.DiagHealthDetail.Text = $_.Exception.Message
    }
}

function Refresh-StudioDiagnostics {
    Start-StudioDiagnosticsRefresh -Force
}

function Complete-StudioDiagnosticsWorker {
    param($Result)
    $script:DiagnosticsLoading = $false
    if (-not [string]::IsNullOrWhiteSpace([string]$Result.Error)) {
        $script:DiagnosticsDirty = $true
        $script:Ui.DiagHealthTitle.Text = 'Diagnostics could not run'
        $script:Ui.DiagHealthTitle.ForeColor = $script:P.Red
        $script:Ui.DiagHealthDetail.Text = [string]$Result.Error
        $script:Ui.DiagRing.Value = 0
        $script:Ui.DiagRing.CenterText = '!'
        return
    }
    try {
        $json = [string](@($Result.Output) | Select-Object -Last 1)
        if ([string]::IsNullOrWhiteSpace($json)) { throw 'Diagnostics returned no data.' }
        $diag = $json | ConvertFrom-Json
        Render-StudioDiagnostics -Diag $diag
    } catch {
        $script:DiagnosticsDirty = $true
        $script:Ui.DiagHealthTitle.Text = 'Diagnostics could not run'
        $script:Ui.DiagHealthTitle.ForeColor = $script:P.Red
        $script:Ui.DiagHealthDetail.Text = $_.Exception.Message
        $script:Ui.DiagRing.Value = 0
        $script:Ui.DiagRing.CenterText = '!'
    }
}

function Layout-StudioDiagnostics {
    if (-not $script:Ui.DiagFlow) { return }
    $width = [Math]::Max(620, $script:Ui.DiagFlow.ClientSize.Width - 52)
    $diagHealthCard.Width = $width
    $diagChecksCard.Width = $width
    $diagBrowserCard.Width = $width
    $diagLogCard.Width = $width
    $diagHealthDetail.Width = [Math]::Max(240, $width - 230)
    $diagHealthTitle.Width = [Math]::Max(240, $width - 230)
    $diagRing.Left = $width - 150
    $diagRefresh.Left = $diagRing.Left - 176
    $diagCheckFlow.Width = [Math]::Max(200, $width - 40)
    $diagBrowserLabel.Width = [Math]::Max(200, $width - 40)
    $diagLogText.Width = [Math]::Max(200, $width - 40)
    $diagLogText.Height = [Math]::Max(100, $diagLogCard.Height - 130)
    $diagOpenLogs.Top = $diagLogCard.Height - 42
    $diagCopy.Top = $diagLogCard.Height - 42
    foreach ($row in $script:DiagnosticRows) {
        $row.Width = [Math]::Max(200, $diagCheckFlow.ClientSize.Width - 8)
    }
}

# ---------------------------------------------------------------------------
# About
# ---------------------------------------------------------------------------

$aboutPage = New-StudioPage -Name 'About'
$aboutFlow = New-Object System.Windows.Forms.FlowLayoutPanel
$aboutFlow.Dock = [System.Windows.Forms.DockStyle]::Fill
$aboutFlow.Padding = New-Object System.Windows.Forms.Padding(24)
$aboutFlow.AutoScroll = $true
$aboutFlow.FlowDirection = [System.Windows.Forms.FlowDirection]::TopDown
$aboutFlow.WrapContents = $false
$aboutFlow.BackColor = $script:P.Bg
$aboutPage.Controls.Add($aboutFlow)
$script:Ui.AboutFlow = $aboutFlow

$aboutHero = New-StudioCard -X 0 -Y 0 -Width 800 -Height 184 -Fill $script:P.Card -Border $script:P.BorderSoft -Radius 16
$aboutHero.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 14)
$aboutFlow.Controls.Add($aboutHero)

$aboutIcon = New-Object System.Windows.Forms.PictureBox
$aboutIcon.Location = New-Object System.Drawing.Point(24, 26)
$aboutIcon.Size = New-Object System.Drawing.Size(68, 68)
$aboutIcon.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
$aboutIcon.BackColor = [System.Drawing.Color]::Transparent
if ($script:IconPath) {
    try { $aboutIcon.Image = (New-Object System.Drawing.Icon($script:IconPath)).ToBitmap() } catch { }
}
$aboutHero.Controls.Add($aboutIcon)
$aboutName = New-StudioLabel -Text 'Session Recovery' -X 110 -Y 26 -Width 460 -Height 40 -Font (New-Object System.Drawing.Font('Segoe UI Semibold', 24)) -Color $script:P.Text
$aboutHero.Controls.Add($aboutName)
$aboutTagline = New-StudioLabel -Text 'Your session, exactly as you left it.' -X 112 -Y 67 -Width 460 -Height 20 -Font $script:FontBody -Color $script:P.Muted
$aboutHero.Controls.Add($aboutTagline)
$aboutVersion = New-StudioBadge -Text ('VERSION ' + $script:AppVersion) -Width 128 -Height 24 -Fill $script:P.AccentSoft -TextColor $script:P.Accent
$aboutVersion.Location = New-Object System.Drawing.Point(112, 98)
$aboutHero.Controls.Add($aboutVersion)
$aboutGithub = New-StudioButton -Text 'View on GitHub' -X 24 -Y 128 -Width 150 -Height 34 -Glyph ''
$aboutGithub.Add_Click({ Start-Process 'https://github.com/Bilalmesk/session-recovery' | Out-Null })
$aboutHero.Controls.Add($aboutGithub)
$aboutCopy = New-StudioButton -Text 'Copy diagnostics' -X 184 -Y 128 -Width 160 -Height 34 -Glyph ''
$aboutCopy.Add_Click({
    try {
        $report = if ($script:DiagnosticsReport) { [string]$script:DiagnosticsReport } else { 'Session Recovery ' + $script:AppVersion }
        [System.Windows.Forms.Clipboard]::SetText($report)
        Show-StudioToast 'Diagnostics report copied.' $script:P.Green
    } catch {
        Show-StudioToast ('Could not copy: ' + $_.Exception.Message) $script:P.Red
    }
})
$aboutHero.Controls.Add($aboutCopy)

$aboutLocal = New-StudioSettingsCard -Title 'Local by design' -Description 'No account, no cloud service and no telemetry.' -Height 160
$aboutFlow.Controls.Add($aboutLocal)
$aboutLocalText = New-StudioLabel -Text "Snapshots are plain JSON files in your Windows profile. Browser tabs are read locally, and restore opens apps and folders without rewriting files.`r`n`r`nThe background app keeps capturing while you work. Everything can be inspected, backed up or deleted from this Studio." -X 20 -Y 64 -Width 740 -Height 80 -Font $script:FontBody -Color $script:P.Muted
$aboutLocal.Controls.Add($aboutLocalText)

$aboutNew = New-StudioSettingsCard -Title 'What is new in 2.1' -Description 'Faster navigation, in-app updates and a quieter restore.' -Height 214
$aboutFlow.Controls.Add($aboutNew)
$aboutNewText = New-StudioLabel -Text "• Check, download and install updates from Application updates.`r`n• Faster page switching and an incrementally built snapshot timeline.`r`n• Shell and console windows are skipped during capture and restore.`r`n• Native SessionRecovery.exe host with no visible cmd or PowerShell window.`r`n• Chrome, Edge and Brave capture, previews, one-click restore and exclusions." -X 20 -Y 64 -Width 740 -Height 130 -Font $script:FontBody -Color $script:P.Muted
$aboutNew.Controls.Add($aboutNewText)

$aboutUpdates = New-StudioSettingsCard -Title 'Application updates' -Description 'Check the private GitHub release channel for a newer build.' -Height 218
$aboutFlow.Controls.Add($aboutUpdates)
$updateStatus = New-StudioLabel -Text ('You are running version {0}. Check for a newer build without leaving the Studio.' -f $script:AppVersion) -X 20 -Y 64 -Width 740 -Height 42 -Font $script:FontBody -Color $script:P.Muted
$aboutUpdates.Controls.Add($updateStatus)
$updateDetail = New-StudioLabel -Text '' -X 20 -Y 108 -Width 740 -Height 36 -Font $script:FontBodySmall -Color $script:P.Subtle
$aboutUpdates.Controls.Add($updateDetail)
$updateCheck = New-StudioButton -Text 'Check for updates' -X 20 -Y 156 -Width 172 -Height 34 -Glyph ([string][char]0xE895)
$aboutUpdates.Controls.Add($updateCheck)
$updateInstall = New-StudioButton -Text 'Download and install' -X 204 -Y 156 -Width 188 -Height 34 -Glyph ([string][char]0xE896)
$updateInstall.Visible = $false
$aboutUpdates.Controls.Add($updateInstall)
$updateRelease = New-StudioButton -Text 'Release notes' -X 404 -Y 156 -Width 146 -Height 34 -Glyph ([string][char]0xE8A7)
$updateRelease.Visible = $false
$aboutUpdates.Controls.Add($updateRelease)

$aboutData = New-StudioSettingsCard -Title 'Data & support' -Description 'Session Recovery is private and local. These are the only places it writes.' -Height 188
$aboutFlow.Controls.Add($aboutData)
$aboutDataText = New-StudioLabel -Text '' -X 20 -Y 64 -Width 740 -Height 74 -Font $script:FontMono -Color $script:P.Muted
$aboutData.Controls.Add($aboutDataText)
$aboutDataText.Text = ('DATA     {0}' -f (Get-SRRoot)) + "`r`n" + ('CONFIG   {0}' -f (Get-SRConfigPath)) + "`r`n" + ('SNAPSHOTS {0}' -f (Get-SRSnapshotDirectory))
$aboutDataOpen = New-StudioButton -Text 'Open data folder' -X 20 -Y 140 -Width 160 -Height 32 -Glyph ([string][char]0xE838)
$aboutDataOpen.Add_Click({ Open-StudioPath (Get-SRRoot) })
$aboutData.Controls.Add($aboutDataOpen)

$aboutFooter = New-StudioLabel -Text ('Session Recovery {0}  •  MIT licensed  •  made for Windows 10 and 11' -f $script:AppVersion) -X 0 -Y 0 -Width 800 -Height 18 -Font $script:FontBodySmall -Color $script:P.Subtle
$aboutFooter.Margin = New-Object System.Windows.Forms.Padding(0, 2, 0, 0)
$aboutFlow.Controls.Add($aboutFooter)
$aboutFlow.Controls.SetChildIndex($aboutUpdates, 1)

$script:Ui.UpdateStatus = $updateStatus
$script:Ui.UpdateDetail = $updateDetail
$script:Ui.UpdateCheck = $updateCheck
$script:Ui.UpdateInstall = $updateInstall
$script:Ui.UpdateRelease = $updateRelease

function Set-StudioUpdateStatus {
    param(
        [string]$Text,
        [System.Drawing.Color]$Color = $script:P.Muted,
        [string]$Detail = ''
    )
    $script:Ui.UpdateStatus.Text = $Text
    $script:Ui.UpdateStatus.ForeColor = $Color
    $script:Ui.UpdateDetail.Text = $Detail
}

function Start-StudioUpdateCheck {
    if ($script:UpdateBusy -or $script:UpdateInstalling) { return }
    $script:UpdateAction = 'check'
    $script:UpdateBusy = $true
    $script:AvailableUpdate = $null
    $script:DownloadedUpdate = $null
    $script:Ui.UpdateCheck.Enabled = $false
    $script:Ui.UpdateInstall.Visible = $false
    $script:Ui.UpdateRelease.Visible = $false
    Set-StudioUpdateStatus -Text 'Checking GitHub Releases...' -Color $script:P.Accent -Detail 'The check runs in the background and never uploads snapshots.'
    try {
        Start-StudioWorker -Name 'Update' -Script {
            param($modulePath, $currentVersion, $action, $payload)
            $ErrorActionPreference = 'Stop'
            Import-Module $modulePath -Force -ErrorAction Stop | Out-Null
            if ($action -eq 'check') {
                Get-SRUpdateInfo -CurrentVersion $currentVersion | ConvertTo-Json -Depth 8 -Compress
            } else {
                Save-SRUpdate -UpdateJson $payload | ConvertTo-Json -Depth 6 -Compress
            }
        } -Arguments @($modulePath, [string]$script:AppVersion, 'check', '')
    } catch {
        $script:UpdateBusy = $false
        $script:Ui.UpdateCheck.Enabled = $true
        Set-StudioUpdateStatus -Text 'Could not start the update check.' -Color $script:P.Red -Detail $_.Exception.Message
    }
}

function Start-StudioUpdateDownload {
    if ($script:UpdateBusy -or $script:UpdateInstalling) { return }
    if ($null -ne $script:DownloadedUpdate -and (Test-Path -LiteralPath $script:DownloadedUpdate.MsiPath -PathType Leaf)) {
        Confirm-StudioUpdateInstall
        return
    }
    if ($null -eq $script:AvailableUpdate) { return }
    $script:UpdateAction = 'download'
    $script:UpdateBusy = $true
    $script:Ui.UpdateCheck.Enabled = $false
    $script:Ui.UpdateInstall.Enabled = $false
    Set-StudioUpdateStatus -Text ('Downloading version {0}...' -f $script:AvailableUpdate.LatestVersion) -Color $script:P.Accent -Detail 'The MSI will be checked against the release SHA256 before installation.'
    try {
        $payload = $script:AvailableUpdate | ConvertTo-Json -Depth 8 -Compress
        Start-StudioWorker -Name 'Update' -Script {
            param($modulePath, $currentVersion, $action, $payload)
            $ErrorActionPreference = 'Stop'
            Import-Module $modulePath -Force -ErrorAction Stop | Out-Null
            if ($action -eq 'check') {
                Get-SRUpdateInfo -CurrentVersion $currentVersion | ConvertTo-Json -Depth 8 -Compress
            } else {
                Save-SRUpdate -UpdateJson $payload | ConvertTo-Json -Depth 6 -Compress
            }
        } -Arguments @($modulePath, [string]$script:AppVersion, 'download', $payload)
    } catch {
        $script:UpdateBusy = $false
        $script:Ui.UpdateCheck.Enabled = $true
        $script:Ui.UpdateInstall.Enabled = $true
        Set-StudioUpdateStatus -Text 'Could not start the update download.' -Color $script:P.Red -Detail $_.Exception.Message
    }
}

function Install-StudioUpdatePackage {
    param(
        [Parameter(Mandatory = $true)][string]$MsiPath,
        [string]$Version = ''
    )
    if (-not (Test-Path -LiteralPath $MsiPath -PathType Leaf)) {
        Set-StudioUpdateStatus -Text 'The downloaded update package is missing.' -Color $script:P.Red -Detail 'Check again to download a fresh copy.'
        return
    }
    $script:UpdateInstalling = $true
    $script:Ui.UpdateCheck.Enabled = $false
    $script:Ui.UpdateInstall.Enabled = $false
    Set-StudioUpdateStatus -Text ('Starting the Windows installer for {0}...' -f $Version) -Color $script:P.Accent -Detail 'The Studio will close while the update installs. Snapshots and settings are preserved.'
    [System.Windows.Forms.Application]::DoEvents()
    try {
        Start-SRUpdateInstall -MsiPath $MsiPath | Out-Null
        $form.Close()
    } catch {
        $script:UpdateInstalling = $false
        $script:Ui.UpdateCheck.Enabled = $true
        $script:Ui.UpdateInstall.Enabled = $true
        Set-StudioUpdateStatus -Text 'The update could not be started.' -Color $script:P.Red -Detail $_.Exception.Message
    }
}

function Confirm-StudioUpdateInstall {
    if ($null -eq $script:DownloadedUpdate) { return }
    $version = [string]$script:DownloadedUpdate.Version
    $answer = [System.Windows.Forms.MessageBox]::Show(
        ("Version {0} is downloaded and its SHA256 hash matches the release.`r`n`r`nInstall now? The Studio will close while the per-user MSI updates the app. Your snapshots, settings and exclusions are kept." -f $version),
        'Install Session Recovery update',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
        Install-StudioUpdatePackage -MsiPath $script:DownloadedUpdate.MsiPath -Version $version
    } else {
        Set-StudioUpdateStatus -Text ('Version {0} is ready to install.' -f $version) -Color $script:P.Green -Detail 'Click Install update when you are ready. The downloaded package stays in your profile.'
    }
}

function Complete-StudioUpdateWorker {
    param($Result)
    $script:UpdateBusy = $false
    $script:Ui.UpdateCheck.Enabled = $true
    $script:Ui.UpdateInstall.Enabled = $true
    $action = $script:UpdateAction

    $data = $null
    try {
        $json = [string](@($Result.Output) | Select-Object -Last 1)
        if (-not [string]::IsNullOrWhiteSpace($json)) { $data = $json | ConvertFrom-Json }
    } catch { }

    if ($null -eq $data) {
        $message = if (-not [string]::IsNullOrWhiteSpace([string]$Result.Error)) { [string]$Result.Error } else { 'The update service returned no result.' }
        Set-StudioUpdateStatus -Text 'Could not check for updates.' -Color $script:P.Red -Detail $message
        return
    }

    if ($action -eq 'check') {
        if (-not [bool]$data.Ok) {
            $hint = if ($data.PSObject.Properties['Hint'] -and -not [string]::IsNullOrWhiteSpace([string]$data.Hint)) { [string]$data.Hint } else { [string]$data.Error }
            Set-StudioUpdateStatus -Text 'Could not check for updates.' -Color $script:P.Red -Detail $hint
            return
        }
        if ([bool]$data.HasUpdate) {
            if ([string]::IsNullOrWhiteSpace([string]$data.MsiName) -or [string]::IsNullOrWhiteSpace([string]$data.ShaName)) {
                $script:AvailableUpdate = $data
                $script:Ui.UpdateRelease.Visible = $true
                Set-StudioUpdateStatus -Text ('Version {0} is available, but the release is incomplete.' -f $data.LatestVersion) -Color $script:P.Amber -Detail 'The release needs both a SessionRecovery MSI and a .msi.sha256 asset before the Studio can install it.'
                return
            }
            $script:AvailableUpdate = $data
            $script:Ui.UpdateInstall.Text = 'Download and install'
            $script:Ui.UpdateInstall.Visible = $true
            $script:Ui.UpdateRelease.Visible = $true
            Set-StudioUpdateStatus -Text ('Version {0} is available.' -f $data.LatestVersion) -Color $script:P.Green -Detail ([string]$data.Name)
        } else {
            Set-StudioUpdateStatus -Text 'You are up to date.' -Color $script:P.Green -Detail ('Version {0} is the latest release.' -f $data.LatestVersion)
        }
        return
    }

    if (-not [bool]$data.Ok) {
        Set-StudioUpdateStatus -Text 'The update download failed.' -Color $script:P.Red -Detail ([string]$data.Error)
        return
    }
    $script:DownloadedUpdate = $data
    $script:Ui.UpdateInstall.Text = 'Install update'
    $script:Ui.UpdateInstall.Visible = $true
    Set-StudioUpdateStatus -Text ('Version {0} is downloaded and verified.' -f $data.Version) -Color $script:P.Green -Detail 'SHA256 verified. The installer keeps your snapshots, settings and exclusions.'
    Confirm-StudioUpdateInstall
}

$updateCheck.Add_Click({ Start-StudioUpdateCheck })
$updateInstall.Add_Click({ Start-StudioUpdateDownload })
$updateRelease.Add_Click({
    if ($null -ne $script:AvailableUpdate -and -not [string]::IsNullOrWhiteSpace([string]$script:AvailableUpdate.ReleaseUrl)) {
        Start-Process ([string]$script:AvailableUpdate.ReleaseUrl) | Out-Null
    }
})

function Layout-StudioAbout {
    if (-not $script:Ui.AboutFlow) { return }
    $width = [Math]::Max(620, $script:Ui.AboutFlow.ClientSize.Width - 52)
    $aboutHero.Width = $width
    $aboutLocal.Width = $width
    $aboutNew.Width = $width
    $aboutUpdates.Width = $width
    $aboutData.Width = $width
    $aboutLocalText.Width = $width - 40
    $aboutNewText.Width = $width - 40
    $updateStatus.Width = $width - 40
    $updateDetail.Width = $width - 40
    $aboutDataText.Width = $width - 40
    $aboutFooter.Width = $width
}

# ---------------------------------------------------------------------------
# Layout and page switching
# ---------------------------------------------------------------------------

foreach ($bufferedControl in @($main, $sidebar, $header, $snapSplit, $snapFlow, $recentFlow, $settingsFlow, $exFlow, $diagFlow, $aboutFlow)) {
    Enable-StudioDoubleBuffer $bufferedControl
}

function Layout-StudioSidebar {
    $height = $sidebar.ClientSize.Height
    if ($height -le 100) { return }
    $restoreSidebar.Top = $height - 234
    $sidebarStatusCard.Top = $height - 182
    $sidebarVersion.Top = $height - 28
}

function Layout-StudioHeader {
    $width = $main.ClientSize.Width
    if ($width -le 100) { return }
    $header.Width = $width
    $headerLine.Width = $width
    $pageHost.Location = New-Object System.Drawing.Point(0, 88)
    $pageHost.Size = New-Object System.Drawing.Size($width, [Math]::Max(100, $main.ClientSize.Height - 88))
    $pageTitle.Width = [Math]::Max(300, $width - 360)
    $pageSubtitle.Width = [Math]::Max(280, $width - 380)
    $toastLabel.Width = [Math]::Max(280, $width - 380)
    $right = $width - 28
    if ($captureButton.Visible) {
        $captureButton.Left = $right - $captureButton.Width
        $right = $captureButton.Left - 16
    }
    if ($refreshButton.Visible) {
        $refreshButton.Left = $width - 28 - $refreshButton.Width
        $right = $refreshButton.Left - 16
    }
    $localBadge.Left = $right - $localBadge.Width
}

function Layout-StudioDashboard {
    if (-not $dashboard -or $dashboard.ClientSize.Width -lt 200) { return }
    $width = $dashboard.ClientSize.Width
    $height = $dashboard.ClientSize.Height
    $hero.Width = $width - 48
    $heroRing.Left = $hero.Width - 158
    $statRow.Width = $width - 48
    $cards = @($statSnapshots, $statApps, $statTabs, $statStorage)
    $gap = 14
    $cardWidth = [int][Math]::Floor(($statRow.Width - (3 * $gap)) / 4)
    $x = 0
    foreach ($card in $cards) {
        $card.Left = $x
        $card.Width = $cardWidth
        $x += $cardWidth + $gap
    }
    $lowerTop = 342
    $lowerHeight = [Math]::Max(200, $height - $lowerTop - 20)
    $quickWidth = 300
    $recentWidth = [Math]::Max(360, $width - 48 - $quickWidth - 16)
    $recentCard.Left = 24
    $recentCard.Top = $lowerTop
    $recentCard.Width = $recentWidth
    $recentCard.Height = $lowerHeight
    $quickCard.Left = $width - 24 - $quickWidth
    $quickCard.Top = $lowerTop
    $quickCard.Width = $quickWidth
    $quickCard.Height = $lowerHeight
    $recentViewAll.Left = $recentCard.Width - 118
    $recentFlow.Width = $recentCard.Width - 32
    $recentFlow.Height = [Math]::Max(72, $lowerHeight - 94)
    $recentSpark.Top = $lowerHeight - 42
    $recentSpark.Width = $recentCard.Width - 32
    foreach ($button in @($quickCapture, $quickRestore, $quickFolder, $quickDiagnostics)) {
        $button.Width = $quickCard.Width - 32
    }
    $quickRestore.Top = 86
    $quickFolder.Top = 128
    $quickDiagnostics.Top = 170
    $dashboardHint.Top = $height - 24
}

$script:SnapshotLayoutTimer = $null
function Layout-StudioSnapshots {
    if (-not $snapshotsPage -or $snapshotsPage.ClientSize.Width -lt 200) { return }
    $width = $snapshotsPage.ClientSize.Width
    $height = $snapshotsPage.ClientSize.Height
    $snapToolbar.Width = $width - 48
    $snapRefresh.Left = $snapToolbar.Width - 120
    $snapOpenFolder.Left = $snapRefresh.Left - 128
    $snapCount.Width = [Math]::Max(80, $snapOpenFolder.Left - 456)
    $snapSplit.Location = New-Object System.Drawing.Point(24, 90)
    $snapSplit.Size = New-Object System.Drawing.Size(($width - 48), [Math]::Max(260, $height - 110))
    $rowWidth = [Math]::Max(300, $snapFlow.ClientSize.Width - 22)
    if ($script:LastSnapFlowWidth -eq $rowWidth) { return }
    $script:LastSnapFlowWidth = $rowWidth
    if ($script:CurrentPage -eq 'Snapshots') {
        if ($null -eq $script:SnapshotLayoutTimer) {
            $script:SnapshotLayoutTimer = New-Object System.Windows.Forms.Timer
            $script:SnapshotLayoutTimer.Interval = 180
            $script:SnapshotLayoutTimer.Add_Tick({
                $script:SnapshotLayoutTimer.Stop()
                if ($script:CurrentPage -eq 'Snapshots') { Refresh-StudioSnapshotRows }
            })
        }
        $script:SnapshotLayoutTimer.Stop()
        $script:SnapshotLayoutTimer.Start()
    }
}

function Layout-StudioPage {
    param([string]$Name)
    switch ($Name) {
        'Dashboard' { Layout-StudioDashboard }
        'Snapshots' { Layout-StudioSnapshots }
        'Exclusions' { Layout-StudioExclusions }
        'Settings' { Layout-StudioSettings }
        'Diagnostics' { Layout-StudioDiagnostics }
        'About' { Layout-StudioAbout }
    }
}

function Layout-Studio {
    if (-not $script:UiReady) { return }
    $pageSize = $script:PageHost.ClientSize
    $current = $script:CurrentPage
    if ($script:Pages.Contains($current) -and $pageSize.Width -gt 0) {
        $script:Pages[$current].Size = $pageSize
    }
    Layout-StudioSidebar
    Layout-StudioHeader
    if ($script:Pages.Contains($current)) { Layout-StudioPage -Name $current }
}

function Show-StudioPage {
    param([string]$Name)
    if (-not $script:Pages.Contains($Name)) { $Name = 'Dashboard' }
    if ($Name -eq $script:CurrentPage -and $script:PageLoaded.ContainsKey($Name)) { return }

    $previous = $script:CurrentPage
    $script:CurrentPage = $Name
    $target = $script:Pages[$Name]
    $script:PageHost.SuspendLayout()
    try {
        if ($previous -ne $Name -and $script:Pages.Contains($previous)) {
            $script:Pages[$previous].Visible = $false
        }
        foreach ($key in @($script:NavButtons.Keys)) {
            $script:NavButtons[$key].Selected = ($key -eq $Name)
        }
        switch ($Name) {
            'Dashboard' {
                $pageTitle.Text = 'Dashboard'
                $pageSubtitle.Text = 'Your session, exactly as you left it.'
            }
            'Snapshots' {
                $pageTitle.Text = 'Snapshots'
                $pageSubtitle.Text = 'A timeline of everything Session Recovery has saved.'
            }
            'Exclusions' {
                $pageTitle.Text = 'Exclusions'
                $pageSubtitle.Text = 'Keep private or noisy windows out of your snapshots.'
            }
            'Settings' {
                $pageTitle.Text = 'Settings'
                $pageSubtitle.Text = 'Tune capture, restore, startup and storage.'
            }
            'Diagnostics' {
                $pageTitle.Text = 'Diagnostics'
                $pageSubtitle.Text = 'Local health checks and recent activity.'
            }
            'About' {
                $pageTitle.Text = 'About'
                $pageSubtitle.Text = 'Local, fast and private by design.'
            }
        }
        $captureButton.Visible = ($Name -eq 'Dashboard' -or $Name -eq 'Snapshots')
        $refreshButton.Visible = ($Name -eq 'Diagnostics')
        Layout-StudioHeader
        if ($script:PageHost.ClientSize.Width -gt 0) {
            $target.Size = $script:PageHost.ClientSize
        }
        $target.Visible = $true
        Layout-StudioPage -Name $Name
        $target.BringToFront()
    } finally {
        $script:PageHost.ResumeLayout($true)
        $script:PageHost.Invalidate()
    }

    $firstShow = -not $script:PageLoaded.ContainsKey($Name)
    switch ($Name) {
        'Dashboard' { if ($firstShow -or $script:DashboardDirty) { Refresh-StudioDashboard } }
        'Snapshots' { if ($firstShow -or $script:SnapshotsDirty) { Refresh-StudioSnapshotRows } }
        'Exclusions' { if ($firstShow -or $script:ExclusionsDirty) { Refresh-StudioExclusions } }
        'Settings' { if (-not $script:SettingsLoaded) { Load-StudioSettings } }
        'Diagnostics' { if ($firstShow -or $script:DiagnosticsDirty) { Start-StudioDiagnosticsRefresh } }
    }
    $script:PageLoaded[$Name] = $true
}

$form.Add_Resize({
    if ($script:UiReady) { Layout-Studio }
})
$form.Add_KeyDown({
    param($sender, $eventArgs)
    if ($eventArgs.Control -and $eventArgs.KeyCode -eq [System.Windows.Forms.Keys]::S -and $script:CurrentPage -eq 'Settings') {
        Save-StudioSettings
        $eventArgs.SuppressKeyPress = $true
    } elseif ($eventArgs.KeyCode -eq [System.Windows.Forms.Keys]::F5) {
        Refresh-StudioData
        if ($script:CurrentPage -eq 'Diagnostics') { Refresh-StudioDiagnostics }
        $eventArgs.SuppressKeyPress = $true
    } elseif ($eventArgs.Control) {
        $map = @{
            'D1' = 'Dashboard'; 'D2' = 'Snapshots'; 'D3' = 'Exclusions';
            'D4' = 'Settings'; 'D5' = 'Diagnostics'; 'D6' = 'About'
        }
        $keyName = [string]$eventArgs.KeyCode
        if ($map.ContainsKey($keyName)) {
            Show-StudioPage -Name $map[$keyName]
            $eventArgs.SuppressKeyPress = $true
        }
    }
})

$statusTimer = New-Object System.Windows.Forms.Timer
$statusTimer.Interval = 10000
$statusTimer.Add_Tick({
    if (-not $script:UiReady) { return }
    try {
        Refresh-StudioSidebar
        if ($script:CurrentPage -eq 'Dashboard') {
            $script:Ui.HeroNext.Text = 'Next automatic snapshot  •  ' + (Format-StudioNext)
        }
    } catch { }
})
$script:StatusTimer = $statusTimer

$studioTaskTimer = New-Object System.Windows.Forms.Timer
$studioTaskTimer.Interval = 200
$studioTaskTimer.Add_Tick({
    if (-not $script:UiReady) { return }
    Update-StudioWorkers
})
$script:StudioTaskTimer = $studioTaskTimer

$form.Add_Shown({
    $script:UiReady = $true
    Layout-Studio
    Refresh-StudioData
    Show-StudioPage -Name $Page
    $statusTimer.Start()
    $studioTaskTimer.Start()
})
$form.Add_FormClosing({
    try { $statusTimer.Stop(); $statusTimer.Dispose() } catch { }
    if ($script:StudioTaskTimer) { try { $script:StudioTaskTimer.Stop(); $script:StudioTaskTimer.Dispose() } catch { } }
    foreach ($workerName in @($script:StudioJobs.Keys)) { Stop-StudioWorker -Name $workerName }
    if ($script:SnapshotBuildTimer) { try { $script:SnapshotBuildTimer.Stop(); $script:SnapshotBuildTimer.Dispose() } catch { } }
    if ($script:SnapshotDetailsTimer) { try { $script:SnapshotDetailsTimer.Stop(); $script:SnapshotDetailsTimer.Dispose() } catch { } }
    if ($script:SnapshotLayoutTimer) { try { $script:SnapshotLayoutTimer.Stop(); $script:SnapshotLayoutTimer.Dispose() } catch { } }
    if ($script:ToastTimer) { try { $script:ToastTimer.Stop(); $script:ToastTimer.Dispose() } catch { } }
})

if (-not [string]::IsNullOrWhiteSpace($RenderDir)) {
    $script:RenderMode = $true
    $form.ShowInTaskbar = $false
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $form.Location = New-Object System.Drawing.Point(-4000, -4000)
    $form.Show()
    $script:UiReady = $true
    Layout-Studio
    Refresh-StudioData
    [System.Windows.Forms.Application]::DoEvents()
    if (-not (Test-Path -LiteralPath $RenderDir)) { New-Item -ItemType Directory -Path $RenderDir -Force | Out-Null }
    foreach ($renderPage in @('Dashboard', 'Snapshots', 'Exclusions', 'Settings', 'Diagnostics', 'About')) {
        Show-StudioPage -Name $renderPage
        for ($pump = 0; $pump -lt 12; $pump++) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 50
        }
        $bitmap = New-Object System.Drawing.Bitmap($form.ClientSize.Width, $form.ClientSize.Height)
        $rect = New-Object System.Drawing.Rectangle(0, 0, $bitmap.Width, $bitmap.Height)
        $form.DrawToBitmap($bitmap, $rect)
        $renderPath = Join-Path $RenderDir ($renderPage + '.png')
        $bitmap.Save($renderPath, [System.Drawing.Imaging.ImageFormat]::Png)
        $bitmap.Dispose()
    }
    $form.Close()
    $form.Dispose()
    return
}
[void]$form.ShowDialog()
$form.Dispose()
