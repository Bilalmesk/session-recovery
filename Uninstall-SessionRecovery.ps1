#requires -Version 5.1
<#
    Uninstall-SessionRecovery.ps1
    Removes Session Recovery shortcuts, scheduled tasks and program files.

    Saved snapshots are kept unless -RemoveData is used.

    Examples
      powershell -ExecutionPolicy Bypass -File Uninstall-SessionRecovery.ps1
      powershell -ExecutionPolicy Bypass -File Uninstall-SessionRecovery.ps1 -RemoveData
#>
[CmdletBinding()]
param(
    [string]$InstallDirectory = (Join-Path $env:LOCALAPPDATA 'SessionRecovery\app'),
    [switch]$RemoveData,
    [switch]$Elevated
)

$ErrorActionPreference = 'Stop'

$taskNames = @('SessionRecovery-Snapshot', 'SessionRecovery-RestorePrompt')
$dataRoot = Join-Path $env:LOCALAPPDATA 'SessionRecovery'

$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = (New-Object System.Security.Principal.WindowsPrincipal($identity)).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)

# Removing scheduled tasks requires administrator rights. Ask for elevation
# once if any of our tasks still exist.
if (-not $isAdmin -and -not $Elevated) {
    $remaining = @()
    foreach ($name in $taskNames) {
        $task = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
        if ($task) { $remaining += $name }
    }
    if ($remaining.Count -gt 0) {
        Write-Host 'Removing Session Recovery scheduled tasks requires administrator rights.'
        Write-Host 'A Windows UAC prompt will appear. Choose Yes to continue.'
        Write-Host ''
        $argumentList = @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"",
            '-InstallDirectory', "`"$InstallDirectory`"", '-Elevated'
        )
        if ($RemoveData) { $argumentList += '-RemoveData' }
        try {
            $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $argumentList -Verb RunAs -Wait -PassThru
            exit $process.ExitCode
        } catch {
            Write-Host 'Elevation was cancelled. Tasks will be left in place; everything else will be removed.' -ForegroundColor Yellow
        }
    }
}

Write-Host 'Uninstalling Session Recovery...'
Write-Host ''

# ---------------------------------------------------------------------------
# Stop the hidden watcher or tray app, if running
# ---------------------------------------------------------------------------

try {
    $backgroundProcesses = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | Where-Object {
        $_.CommandLine -and ($_.CommandLine -match '(?i)Watch-Session\.ps1|Tray-SessionRecovery\.ps1')
    })
    $backgroundProcesses += @(Get-CimInstance Win32_Process -Filter "Name='SessionRecovery.exe'" -ErrorAction SilentlyContinue | Where-Object {
        $_.CommandLine -and ($_.CommandLine -match '(?i)--tray')
    })
    foreach ($process in $backgroundProcesses) {
        try {
            Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction Stop
            Write-Host ("  Stopped background process {0}" -f $process.ProcessId)
        } catch { }
    }
} catch { }

# ---------------------------------------------------------------------------
# Scheduled tasks
# ---------------------------------------------------------------------------

foreach ($name in $taskNames) {
    try {
        $task = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
        if ($task) {
            Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction Stop
            Write-Host ("  Removed scheduled task: {0}" -f $name)
        }
    } catch {
        Write-Host ("  Could not remove scheduled task {0} (run as administrator): {1}" -f $name, $_.Exception.Message) -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------------------------
# Shortcuts
# ---------------------------------------------------------------------------

$startupDirectory = [Environment]::GetFolderPath('Startup')
foreach ($name in @('Session Recovery - Background.lnk', 'Session Recovery - Snapshot Watcher.lnk', 'Session Recovery - Restore Prompt.lnk')) {
    $path = Join-Path $startupDirectory $name
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        Write-Host ("  Removed Startup entry: {0}" -f $name)
    }
}

$startMenuFolder = Join-Path ([Environment]::GetFolderPath('Programs')) 'Session Recovery'
if (Test-Path -LiteralPath $startMenuFolder) {
    Remove-Item -LiteralPath $startMenuFolder -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host '  Removed Start Menu folder: Session Recovery'
}

$desktop = [Environment]::GetFolderPath('Desktop')
foreach ($name in @('Session Recovery.lnk', 'Restore Session.lnk')) {
    $desktopShortcut = Join-Path $desktop $name
    if (Test-Path -LiteralPath $desktopShortcut) {
        Remove-Item -LiteralPath $desktopShortcut -Force -ErrorAction SilentlyContinue
        Write-Host ("  Removed desktop shortcut: {0}" -f $name)
    }
}

# ---------------------------------------------------------------------------
# Program files and, optionally, saved data
# ---------------------------------------------------------------------------

function Remove-SRDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $true }
    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

$leftovers = New-Object System.Collections.Generic.List[string]
if (-not (Remove-SRDirectory -Path $InstallDirectory)) { $leftovers.Add($InstallDirectory) }
if ($RemoveData -and (Test-Path -LiteralPath $dataRoot)) {
    if (-not (Remove-SRDirectory -Path $dataRoot)) { $leftovers.Add($dataRoot) }
}

if ($leftovers.Count -gt 0) {
    # The running script can keep its folder locked. Delete it from a short
    # lived cmd.exe that runs after this process exits.
    $command = 'timeout /t 2 /nobreak >nul'
    foreach ($leftover in $leftovers) {
        $command += (' & rmdir /s /q "{0}"' -f $leftover)
    }
    Write-Host '  Scheduling removal of remaining files...'
    Start-Process -FilePath $env:ComSpec -ArgumentList '/c', $command -WindowStyle Hidden | Out-Null
} else {
    Write-Host '  Removed program files.'
}

if ($RemoveData) {
    Write-Host '  Removed saved snapshots, logs and configuration.'
} else {
    Write-Host ("  Saved snapshots were kept in {0}" -f $dataRoot)
}

Write-Host ''
Write-Host 'Session Recovery was uninstalled.' -ForegroundColor Green
exit 0
