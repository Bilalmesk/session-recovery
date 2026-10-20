#requires -Version 5.1
<#
    Save-Session.ps1
    Takes a non-interactive snapshot of the current desktop session.

    This script is normally started by the SessionRecovery-Snapshot scheduled
    task through RunHidden.vbs, so it must never require user input.
#>
[CmdletBinding()]
param(
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'SessionRecovery.psm1'
$exitCode = 0

try {
    Import-Module $modulePath -Force -ErrorAction Stop

    $path = Save-SRSnapshot
    if (-not $Quiet) {
        if ($path) {
            Write-Host "Snapshot saved: $path"
        } else {
            Write-Host 'Snapshot skipped (another snapshot is still running).'
        }
    }
} catch {
    $exitCode = 1
    $message = "Snapshot script failed: $($_.Exception.Message)"
    try {
        if (Get-Command Write-SRLog -ErrorAction SilentlyContinue) {
            Write-SRLog -Level ERROR -Message $message
        }
    } catch { }
    if (-not $Quiet) {
        Write-Error $message
    }
}

exit $exitCode
