#requires -Version 5.1
<#
    Diagnostics.ps1
    Prints a health report for Session Recovery.

    Examples
      powershell -NoProfile -ExecutionPolicy Bypass -File .\Diagnostics.ps1
      powershell -NoProfile -ExecutionPolicy Bypass -File .\Diagnostics.ps1 -Json
      powershell -NoProfile -ExecutionPolicy Bypass -File .\Diagnostics.ps1 -ReportPath "$env:TEMP\session-recovery-report.txt"
#>
[CmdletBinding()]
param(
    [switch]$Json,
    [string]$ReportPath
)

$ErrorActionPreference = 'Stop'
$modulePath = Join-Path $PSScriptRoot 'SessionRecovery.psm1'
Import-Module $modulePath -Force -ErrorAction Stop

try {
    $diagnostics = Get-SRDiagnostics

    if ($Json) {
        $text = $diagnostics | ConvertTo-Json -Depth 8
    } else {
        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add('Session Recovery diagnostics')
        $lines.Add(('Generated: {0}' -f ([datetime]$diagnostics.GeneratedAt).ToString('g')))
        $lines.Add(('PowerShell: {0}' -f $diagnostics.PowerShellVersion))
        $lines.Add(('Windows: {0}' -f $diagnostics.OSVersion))
        $lines.Add('')

        $lines.Add(('Installed: {0}' -f $diagnostics.Installed))
        $lines.Add(('Data folder: {0}' -f $diagnostics.Root))
        $lines.Add(('Snapshot folder: {0}' -f $diagnostics.SnapshotDirectory))
        $lines.Add(('Snapshots: {0} ({1:N1} MB)' -f $diagnostics.SnapshotCount, ($diagnostics.SnapshotBytes / 1MB)))
        if ($diagnostics.LatestSnapshot) {
            $lines.Add(('Latest snapshot: {0} ({1:N1} minutes ago)' -f ([datetime]$diagnostics.LatestSnapshotAt).ToString('g'), $diagnostics.LatestSnapshotAgeMinutes))
            $lines.Add(('Latest file: {0}' -f $diagnostics.LatestSnapshot))
        } else {
            $lines.Add('Latest snapshot: none')
            $lines.Add('WARNING: no snapshot files were found.')
        }

        $lines.Add('')
        $lines.Add(('Config: {0}' -f $diagnostics.ConfigPath))
        $lines.Add(('Config valid: {0}' -f $diagnostics.ConfigValid))
        if (-not $diagnostics.ConfigValid) {
            $lines.Add(('Config error: {0}' -f $diagnostics.ConfigError))
        }
        $lines.Add(('Schedule mode: {0}' -f $diagnostics.ScheduleMode))
        $lines.Add(('Watcher processes: {0}' -f (($diagnostics.WatcherPids -join ', '))))
        $lines.Add(('Tray processes: {0}' -f (($diagnostics.TrayPids -join ', '))))
        if (@($diagnostics.ScheduledTasks).Count -gt 0) {
            foreach ($task in @($diagnostics.ScheduledTasks)) {
                $activeText = if ($task.Active) { 'active' } else { 'inactive' }
                $lines.Add(('Scheduled task: {0} ({1}, {2})' -f $task.Name, $task.State, $activeText))
            }
        } else {
            $lines.Add('Scheduled tasks: none')
        }

        $lines.Add('')
        $lines.Add(('Interval: {0} minute(s)' -f $diagnostics.Settings.IntervalMinutes))
        $lines.Add(('Retention: {0} snapshots, {1} day(s)' -f $diagnostics.Settings.KeepSnapshots, $diagnostics.Settings.KeepSnapshotDays))
        $lines.Add(('Prompt on logon: {0}' -f $diagnostics.Settings.PromptOnLogon))
        $lines.Add(('Maximum restore age: {0} hour(s)' -f $diagnostics.Settings.MaxRestoreAgeHours))
        $lines.Add(('Default tab mode: {0}' -f $diagnostics.Settings.DefaultTabMode))
        $lines.Add(('Restore browsers: {0}' -f $diagnostics.Settings.RestoreBrowsers))
        $lines.Add(('Excluded apps: {0}' -f (@($diagnostics.Settings.ExcludeApps) -join ', ')))
        $lines.Add(('Excluded folders: {0}' -f (@($diagnostics.Settings.ExcludeFolders) -join ', ')))
        $lines.Add(('Excluded URLs: {0}' -f (@($diagnostics.Settings.ExcludeUrls) -join ', ')))

        $lines.Add('')
        if (@($diagnostics.Browsers).Count -gt 0) {
            foreach ($browser in @($diagnostics.Browsers)) {
                $lines.Add(('Browser: {0} [{1}]' -f $browser.Name, $browser.Exe))
            }
        } else {
            $lines.Add('Browsers: none detected')
        }

        $lines.Add('')
        $lines.Add(('Log: {0}' -f $diagnostics.LogPath))
        if (@($diagnostics.RecentLog).Count -gt 0) {
            $lines.Add('Recent log lines:')
            foreach ($line in @($diagnostics.RecentLog)) { $lines.Add(('  ' + $line)) }
        } else {
            $lines.Add('Recent log lines: none')
        }

        if (-not $diagnostics.ConfigValid) {
            $lines.Add('')
            $lines.Add('WARNING: config.json is not valid JSON; defaults are being used.')
        }
        if ($diagnostics.SnapshotCount -eq 0) {
            $lines.Add('WARNING: no snapshots exist yet. Run Save-Session.ps1 and check the log.')
        } elseif ($diagnostics.LatestSnapshotAgeMinutes -gt ($diagnostics.Settings.IntervalMinutes * 2 + 5)) {
            $lines.Add('WARNING: the latest snapshot is older than expected.')
        }
        if ($diagnostics.ScheduleMode -eq 'Not running') {
            $lines.Add('WARNING: no scheduled task, tray app or watcher process was detected.')
        }

        $text = $lines -join [Environment]::NewLine
    }

    if (-not [string]::IsNullOrWhiteSpace($ReportPath)) {
        $parent = Split-Path -Parent $ReportPath
        if ($parent -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        [System.IO.File]::WriteAllText($ReportPath, $text, (New-Object System.Text.UTF8Encoding($false)))
        Write-Host ("Diagnostics report written to {0}" -f $ReportPath)
    }

    Write-Output $text
} catch {
    Write-Error ("Diagnostics failed: " + $_.Exception.Message)
    exit 1
}

exit 0
