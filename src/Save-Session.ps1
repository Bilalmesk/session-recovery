#requires -Version 5.1
<#
    Save-Session.ps1
    Takes a non-interactive snapshot of the current desktop session.

    This script is normally started by the SessionRecovery-Snapshot scheduled
    task through RunHidden.vbs, so it must never require user input.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$Quiet,
    [switch]$Force,
    [switch]$Hibernate
)

$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'SessionRecovery.psm1'
$exitCode = 0

try {
    Import-Module $modulePath -Force -ErrorAction Stop

    if ($Hibernate) {
        # User-triggered hibernation always saves a pinned checkpoint first.
        # -WhatIf stops before both the checkpoint and the power request.
        $path = Invoke-SRHibernate -WhatIf:$WhatIfPreference
        if (-not $Quiet) {
            if ($path) {
                Write-Host "Recovery checkpoint saved: $path"
                Write-Host 'Hibernating...'
            } else {
                Write-Host 'Hibernate request skipped.'
            }
        }
    } else {
        $path = Save-SRSnapshot -Force:$Force
        if (-not $Quiet) {
            if ($path) {
                Write-Host "Snapshot saved: $path"
            } else {
                Write-Host 'Snapshot skipped (another snapshot is still running).'
            }
        }
    }
} catch {
    $exitCode = 1
    $action = if ($Hibernate) { 'Hibernate' } else { 'Snapshot' }
    $message = "$action script failed: $($_.Exception.Message)"
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
