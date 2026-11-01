#requires -Version 5.1
<#
    Control-SessionRecovery.ps1
    Command-line API for Session Recovery: trigger snapshots and restores
    from scripts, shortcuts and other tools.

    Commands reach the running tray app through the SessionRecoveryControl
    named pipe. When no tray app is listening, snapshot/status still run
    locally so scripts keep working on a clean boot.

    Examples
      powershell -NoProfile -ExecutionPolicy Bypass -File Control-SessionRecovery.ps1 -Command snapshot
      powershell ... -Command status
      powershell ... -Command restore-latest
      powershell ... -Command workspace-save -Name Work
      powershell ... -Command workspace-restore -Name Work
      powershell ... -Command workspace-delete -Name Work
      powershell ... -Command workspaces
      powershell ... -Command undo-restore
      powershell ... -Command storage-health
      powershell ... -Command storage-cleanup
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('snapshot', 'pause', 'resume', 'status', 'restore-latest', 'undo-restore', 'workspace-save', 'workspace-restore', 'workspace-delete', 'workspaces', 'storage-health', 'storage-cleanup')]
    [string]$Command,
    [string]$Name = ''
)

$ErrorActionPreference = 'Stop'
$modulePath = Join-Path $PSScriptRoot 'SessionRecovery.psm1'
Import-Module $modulePath -Force -ErrorAction Stop

$pipeCommands = @('snapshot', 'pause', 'resume', 'restore-latest', 'undo-restore', 'workspace-save', 'workspace-restore', 'workspace-delete')
$exitCode = 0

if ($pipeCommands -contains $Command) {
    $reached = $false
    try {
        $reply = Send-SRControl -Command $Command -Name $Name -TimeoutMilliseconds 2500
        Write-Output ('Accepted by the running tray app: {0}' -f $Command)
        $reached = $true
    } catch {
        # No tray app is listening. Snapshot can still run locally.
        if ($Command -eq 'snapshot') {
            try {
                $path = Save-SRSnapshot -Force
                if ($path) {
                    Write-Output ('Snapshot saved: {0}' -f $path)
                    $reached = $true
                } else {
                    Write-Output 'Snapshot skipped (idle, fullscreen or another capture running).'
                    $reached = $true
                }
            } catch {
                Write-Error ('Snapshot failed: {0}' -f $_.Exception.Message)
                $exitCode = 1
                $reached = $true
            }
        }
        if (-not $reached) {
            Write-Output ('The Session Recovery tray app is not running, so "{0}" could not be delivered.' -f $Command)
            Write-Output 'Start it with: SessionRecovery.exe --tray'
            $exitCode = 2
        }
    }
    if ($exitCode -eq 0 -and $reached) { exit 0 }
    exit $exitCode
}

switch ($Command) {
    'status' {
        $diag = Get-SRDiagnostics
        Write-Output ('Session Recovery status')
        Write-Output ('  Snapshots:       {0} ({1:N1} MB)' -f $diag.SnapshotCount, ($diag.SnapshotBytes / 1MB))
        if ($null -ne $diag.LatestSnapshotAgeMinutes) {
            Write-Output ('  Latest snapshot: {0} minute(s) ago' -f $diag.LatestSnapshotAgeMinutes)
        } else {
            Write-Output ('  Latest snapshot: none yet')
        }
        Write-Output ('  Background:      {0}' -f $diag.ScheduleMode)
        Write-Output ('  Config valid:    {0}' -f $diag.ConfigValid)
        Write-Output ('  Data folder:     {0}' -f $diag.Root)
        $checkpoint = Get-SRRestoreCheckpoint
        if ($null -ne $checkpoint) {
            Write-Output ('  Safety snapshot: {0}' -f $checkpoint.SnapshotName)
        }
        Write-Output ('  Workspaces:      {0}' -f @(Get-SRWorkspaces).Count)
    }
    'workspaces' {
        $saved = @(Get-SRWorkspaces)
        if ($saved.Count -eq 0) {
            Write-Output 'No named workspaces have been saved yet.'
        } else {
            foreach ($workspace in $saved) {
                Write-Output ('{0}  -  saved {1:yyyy-MM-dd HH:mm}  -  {2} app(s), {3} folder(s), {4} tab(s)' -f $workspace.Name, $workspace.At, $workspace.Apps, $workspace.Folders, $workspace.Tabs)
            }
        }
    }
    'storage-health' {
        $health = Get-SRStorageHealth
        Write-Output 'Session Recovery storage health'
        Write-Output ('  Snapshots:        {0} ({1:N1} MB)' -f $health.SnapshotCount, ($health.SnapshotBytes / 1MB))
        Write-Output ('  Unreadable:       {0}' -f $health.UnreadableCount)
        Write-Output ('  Orphan thumbnails:{0}' -f $health.OrphanedCount)
        Write-Output ('  Temp files:       {0}' -f $health.TempCount)
        Write-Output ('  Reclaimable:      {0:N1} KB' -f ($health.ReclaimableBytes / 1KB))
        foreach ($item in @($health.UnreadableSnapshots)) { Write-Output ('    unreadable: {0}' -f $item.Path) }
        foreach ($item in @($health.OrphanedThumbnails)) { Write-Output ('    orphan:     {0}' -f $item.Path) }
        foreach ($item in @($health.TempFiles)) { Write-Output ('    temp:       {0}' -f $item.Path) }
    }
    'storage-cleanup' {
        $result = Invoke-SRStorageCleanup
        Write-Output ('Cleanup finished: {0} removed, {1} quarantined, {2} old snapshot(s) retired by retention, {3:N1} KB freed.' -f $result.RemovedCount, $result.QuarantinedCount, $result.RetentionRemoved, ($result.BytesFreed / 1KB))
    }
}

exit $exitCode
