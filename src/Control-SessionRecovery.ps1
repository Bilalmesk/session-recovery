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
      powershell ... -Command workspaces
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('snapshot', 'pause', 'resume', 'status', 'restore-latest', 'workspace-save', 'workspace-restore', 'workspaces')]
    [string]$Command,
    [string]$Name = ''
)

$ErrorActionPreference = 'Stop'
$modulePath = Join-Path $PSScriptRoot 'SessionRecovery.psm1'
Import-Module $modulePath -Force -ErrorAction Stop

$pipeCommands = @('snapshot', 'pause', 'resume', 'restore-latest', 'workspace-save', 'workspace-restore')
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
    }
    'workspaces' {
        $saved = @(Get-SRWorkspaces)
        if ($saved.Count -eq 0) {
            Write-Output 'No named workspaces have been saved yet.'
        } else {
            foreach ($workspace in $saved) {
                Write-Output ('{0}  -  saved {1:yyyy-MM-dd HH:mm}' -f $workspace.Name, $workspace.At)
            }
        }
    }
}

exit $exitCode
