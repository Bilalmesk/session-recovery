#requires -Version 5.1
<#
    Build-Launcher.ps1
    Compiles the tiny native Windows GUI host that runs the Session Recovery
    PowerShell UI in-process. The resulting SessionRecovery.exe has no console
    subsystem, so double-clicking it never opens cmd.exe or powershell.exe.
#>
[CmdletBinding()]
param(
    [string]$OutputPath,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$source = Join-Path $root 'src\SessionRecoveryLauncher.cs'
$manifest = Join-Path $root 'src\SessionRecoveryLauncher.manifest'
$icon = Join-Path $root 'assets\SessionRecovery.ico'

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $root 'dist\SessionRecovery.exe'
}

if (-not (Test-Path -LiteralPath $source)) { throw "Launcher source not found: $source" }
if (-not (Test-Path -LiteralPath $manifest)) { throw "Launcher manifest not found: $manifest" }
if (-not (Test-Path -LiteralPath $icon)) { throw "Launcher icon not found: $icon" }

$cscCandidates = @(
    (Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
    (Join-Path $env:SystemRoot 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
)
$csc = $cscCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $csc) { throw '.NET Framework C# compiler (csc.exe) was not found.' }

$automation = [System.Management.Automation.PSObject].Assembly.Location
if ([string]::IsNullOrWhiteSpace($automation) -or -not (Test-Path -LiteralPath $automation)) {
    throw 'PowerShell System.Management.Automation.dll was not found.'
}

$outputDirectory = Split-Path -Parent $OutputPath
if (-not (Test-Path -LiteralPath $outputDirectory)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}

if ((Test-Path -LiteralPath $OutputPath) -and -not $Force) {
    $outputTime = (Get-Item -LiteralPath $OutputPath).LastWriteTimeUtc
    $sourceTime = (Get-Item -LiteralPath $source).LastWriteTimeUtc
    $manifestTime = (Get-Item -LiteralPath $manifest).LastWriteTimeUtc
    if ($outputTime -ge $sourceTime -and $outputTime -ge $manifestTime) {
        Write-Host ("Launcher is up to date: {0}" -f $OutputPath)
        return
    }
}

$arguments = @(
    '/nologo',
    '/target:winexe',
    '/platform:anycpu',
    '/optimize+',
    ('/out:"{0}"' -f $OutputPath),
    ('/win32icon:"{0}"' -f $icon),
    ('/win32manifest:"{0}"' -f $manifest),
    '/reference:System.dll',
    '/reference:System.Core.dll',
    '/reference:System.Windows.Forms.dll',
    '/reference:System.Drawing.dll',
    ('/reference:"{0}"' -f $automation),
    ('"{0}"' -f $source)
)

Write-Host 'Building native Session Recovery host...'
& $csc @arguments
if ($LASTEXITCODE -ne 0) {
    throw "Launcher build failed with exit code $LASTEXITCODE."
}
if (-not (Test-Path -LiteralPath $OutputPath)) {
    throw "Launcher build completed but the output was not found: $OutputPath"
}

$item = Get-Item -LiteralPath $OutputPath
Write-Host ("Launcher: {0} ({1:N0} bytes)" -f $item.FullName, $item.Length)
