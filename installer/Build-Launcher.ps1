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
    # The release version to stamp into the exe. The Studio's update check
    # compares the installed exe's version against the latest release, so a
    # launcher that keeps a stale hardcoded version re-offers the same
    # update after every install.
    [string]$Version = '',
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
    $outputTimeOk = ($outputTime -ge $sourceTime -and $outputTime -ge $manifestTime)
    $versionOk = $true
    if (-not [string]::IsNullOrWhiteSpace($Version)) {
        $outputVersion = (Get-Item -LiteralPath $OutputPath).VersionInfo.FileVersion
        $versionOk = ($outputVersion -eq $Version)
    }
    if ($outputTimeOk -and $versionOk) {
        Write-Host ("Launcher is up to date: {0}" -f $OutputPath)
        return
    }
}

# Stamp the requested version into a temporary copy of the source. The
# AssemblyVersion attributes in the tracked source stay a safe fallback.
$compileSource = $source
if (-not [string]::IsNullOrWhiteSpace($Version)) {
    $sourceText = Get-Content -LiteralPath $source -Raw
    $stamped = $sourceText -replace 'AssemblyVersion\("[0-9.]+"\)', ('AssemblyVersion("{0}.0")' -f $Version)
    $stamped = $stamped -replace 'AssemblyFileVersion\("[0-9.]+"\)', ('AssemblyFileVersion("{0}.0")' -f $Version)
    if ($stamped -ne $sourceText) {
        $compileSource = Join-Path $env:TEMP ('SessionRecoveryLauncher-{0}.cs' -f [guid]::NewGuid().ToString('N'))
        Set-Content -LiteralPath $compileSource -Value $stamped -Encoding UTF8
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
    ('"{0}"' -f $compileSource)
)

Write-Host 'Building native Session Recovery host...'
try {
    & $csc @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Launcher build failed with exit code $LASTEXITCODE."
    }
} finally {
    if ($compileSource -ne $source -and (Test-Path -LiteralPath $compileSource)) {
        Remove-Item -LiteralPath $compileSource -Force -ErrorAction SilentlyContinue
    }
}
if (-not (Test-Path -LiteralPath $OutputPath)) {
    throw "Launcher build completed but the output was not found: $OutputPath"
}

$item = Get-Item -LiteralPath $OutputPath
Write-Host ("Launcher: {0} ({1:N0} bytes)" -f $item.FullName, $item.Length)
