#requires -Version 5.1
<#
    Watch-Session.ps1
    Runs hidden and takes a session snapshot every few minutes for as long as
    the user is logged on. Used instead of a scheduled task when the tool is
    installed without administrator rights.

    Usage:
      powershell.exe -NoProfile -ExecutionPolicy Bypass -File Watch-Session.ps1
      powershell.exe -NoProfile -ExecutionPolicy Bypass -File Watch-Session.ps1 -Once
#>
[CmdletBinding()]
param(
    [switch]$Once
)

$ErrorActionPreference = 'Continue'

$modulePath = Join-Path $PSScriptRoot 'SessionRecovery.psm1'
$mutex = $null

try {
    if (-not $Once) {
        try {
            $mutex = New-Object System.Threading.Mutex($false, 'Local\SessionRecoveryWatcher')
            $acquired = $false
            try {
                $acquired = $mutex.WaitOne(0)
            } catch [System.Threading.AbandonedMutexException] {
                $acquired = $true
            }
            if (-not $acquired) {
                # Another watcher is already running in this session.
                exit 0
            }
        } catch {
            $mutex = $null
        }
    }

    Import-Module $modulePath -Force -ErrorAction Stop

    while ($true) {
        try {
            [void](Save-SRSnapshot)
        } catch {
            try { Write-SRLog -Level ERROR -Message "Watcher snapshot failed: $($_.Exception.Message)" } catch { }
        }

        if ($Once) { break }

        $minutes = 3
        try {
            $config = Get-SRConfig
            $configured = [int]$config.snapshotIntervalMinutes
            if ($configured -ge 1) { $minutes = $configured }
        } catch { }
        Start-Sleep -Seconds ([Math]::Max(30, $minutes * 60))
    }
} catch {
    try {
        if (Get-Command Write-SRLog -ErrorAction SilentlyContinue) {
            Write-SRLog -Level ERROR -Message "Watcher stopped: $($_.Exception.Message)"
        }
    } catch { }
    exit 1
} finally {
    if ($null -ne $mutex) {
        try { [void]$mutex.ReleaseMutex() } catch { }
        try { $mutex.Dispose() } catch { }
    }
}

exit 0
