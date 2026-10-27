#requires -Version 5.1
<#
    Invoke-InstallerSmoke.ps1
    Installs the built MSI, verifies the shipped payload against the working
    tree, renders the installed Studio at the minimum window size, then
    uninstalls and confirms cleanup.

    The MSI is per-user, so this runs without elevation. Use it locally and in
    CI after the build job has produced the MSI artifact.

    Example:
      .\tests\Invoke-InstallerSmoke.ps1 -MsiPath .\dist\SessionRecovery-2.6.1.msi
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$MsiPath,
    [string]$SourceRoot = '',
    [string]$Language = 'fr',
    [string]$Size = '1024x661',
    [string]$OutputRoot = ''
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($SourceRoot)) { $SourceRoot = Split-Path -Parent $PSScriptRoot }
$SourceRoot = (Resolve-Path -LiteralPath $SourceRoot).Path
$MsiPath = (Resolve-Path -LiteralPath $MsiPath).Path
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('sr-installer-smoke-' + [guid]::NewGuid().ToString('N'))
}
New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
$OutputRoot = (Resolve-Path -LiteralPath $OutputRoot).Path
$installLog = Join-Path $OutputRoot 'install.log'
$uninstallLog = Join-Path $OutputRoot 'uninstall.log'
$appDir = Join-Path $env:LOCALAPPDATA 'SessionRecovery\app'
$pages = @('Dashboard', 'Snapshots', 'Exclusions', 'Settings', 'Diagnostics', 'About')
$failures = New-Object System.Collections.Generic.List[string]

function Get-MsiProperty {
    param($Database, [string]$Name)
    $view = $Database.OpenView("SELECT Value FROM Property WHERE Property='$Name'")
    try {
        # Suppress COM return values so the function emits only the string.
        [void]$view.Execute()
        $record = $view.Fetch()
        if ($null -eq $record) { return $null }
        return [string]$record.StringData(1)
    } finally {
        [void]$view.Close()
    }
}

function Invoke-MsiExec {
    param([string[]]$Arguments, [string]$LogPath)
    $all = @($Arguments) + @('/qn', '/norestart', '/l*v', ('"' + $LogPath + '"'))
    $process = Start-Process -FilePath msiexec.exe -ArgumentList $all -Wait -PassThru
    return $process.ExitCode
}

Write-Host ("MSI: {0}" -f $MsiPath)
$installer = New-Object -ComObject WindowsInstaller.Installer
$database = $installer.OpenDatabase($MsiPath, 0)
$productCode = Get-MsiProperty -Database $database -Name 'ProductCode'
$productVersion = Get-MsiProperty -Database $database -Name 'ProductVersion'
Write-Host ("ProductCode: {0}  Version: {1}" -f $productCode, $productVersion)

# Remove a previous copy so this test covers a clean install too. 1605 means
# the product was not installed, which is fine.
$beforeExit = Invoke-MsiExec -Arguments @('/x', $productCode) -LogPath (Join-Path $OutputRoot 'uninstall-before.log')
if ($beforeExit -notin @(0, 1605)) {
    throw "Could not remove a previous installation (exit $beforeExit)."
}

$installExit = Invoke-MsiExec -Arguments @('/i', ('"' + $MsiPath + '"')) -LogPath $installLog
if ($installExit -ne 0) {
    throw "MSI install failed with exit code $installExit. See $installLog"
}
Write-Host 'Install succeeded.'

# Verify every source-controlled payload byte-for-byte. The native launcher is
# built from source and is not present in a checkout unless the build job ran,
# so it is checked separately when available.
$expected = @(
    @{ Name = 'SessionRecovery.psm1'; Source = 'src\SessionRecovery.psm1' },
    @{ Name = 'Save-Session.ps1'; Source = 'src\Save-Session.ps1' },
    @{ Name = 'Restore-Session.ps1'; Source = 'src\Restore-Session.ps1' },
    @{ Name = 'Tray-SessionRecovery.ps1'; Source = 'src\Tray-SessionRecovery.ps1' },
    @{ Name = 'Watch-Session.ps1'; Source = 'src\Watch-Session.ps1' },
    @{ Name = 'Diagnostics.ps1'; Source = 'src\Diagnostics.ps1' },
    @{ Name = 'RunHidden.vbs'; Source = 'src\RunHidden.vbs' },
    @{ Name = 'Studio-SessionRecovery.ps1'; Source = 'src\Studio-SessionRecovery.ps1' },
    @{ Name = 'Strings.ps1'; Source = 'src\Strings.ps1' },
    @{ Name = 'StudioControls.cs'; Source = 'src\StudioControls.cs' },
    @{ Name = 'Control-SessionRecovery.ps1'; Source = 'src\Control-SessionRecovery.ps1' },
    @{ Name = 'SessionRecovery.ico'; Source = 'assets\SessionRecovery.ico' },
    @{ Name = 'README.md'; Source = 'README.md' }
)

foreach ($item in $expected) {
    $sourcePath = Join-Path $SourceRoot $item.Source
    $installedPath = Join-Path $appDir $item.Name
    if (-not (Test-Path -LiteralPath $sourcePath)) {
        $failures.Add("Missing source file: $($item.Source)")
        continue
    }
    if (-not (Test-Path -LiteralPath $installedPath)) {
        $failures.Add("Missing installed file: $($item.Name)")
        continue
    }
    $sourceHash = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash
    $installedHash = (Get-FileHash -LiteralPath $installedPath -Algorithm SHA256).Hash
    if ($sourceHash -ne $installedHash) {
        $failures.Add("Installed file does not match source: $($item.Name)")
    }
}

$exePath = Join-Path $appDir 'SessionRecovery.exe'
if (-not (Test-Path -LiteralPath $exePath)) {
    $failures.Add('Missing installed file: SessionRecovery.exe')
} else {
    $installedVersion = (Get-Item -LiteralPath $exePath).VersionInfo.ProductVersion
    if ($installedVersion -notlike "$productVersion*") {
        $failures.Add("Launcher version $installedVersion does not match MSI version $productVersion")
    }
    $distExe = Join-Path $SourceRoot 'dist\SessionRecovery.exe'
    if (Test-Path -LiteralPath $distExe) {
        $distHash = (Get-FileHash -LiteralPath $distExe -Algorithm SHA256).Hash
        $installedHash = (Get-FileHash -LiteralPath $exePath -Algorithm SHA256).Hash
        if ($distHash -ne $installedHash) {
            $failures.Add('Installed launcher does not match dist\SessionRecovery.exe')
        }
    }
}

if ($failures.Count -eq 0) { Write-Host 'Installed payload matches the working tree.' }

# Render the installed app, not the source tree, at the smallest supported
# window size. This catches packaging mistakes and stale UI files.
$renderRoot = Join-Path $OutputRoot 'render'
$homeDir = Join-Path $renderRoot 'home'
$outDir = Join-Path $renderRoot 'out'
New-Item -ItemType Directory -Path $homeDir -Force | Out-Null
[ordered]@{ language = $Language } |
    ConvertTo-Json -Depth 4 |
    Set-Content -LiteralPath (Join-Path $homeDir 'config.json') -Encoding UTF8
$env:SESSIONRECOVERY_HOME = $homeDir
$env:SESSIONRECOVERY_RENDER_CHECK = '1'
$env:SESSIONRECOVERY_RENDER_TREE = '1'
$env:SESSIONRECOVERY_RENDER_MS = '1100'
$env:SESSIONRECOVERY_RENDER_SIZE = $Size
$env:SESSIONRECOVERY_RENDER_SCROLL = 'bottom'
# Run from the repo root. Starting the installed app with its own folder as
# the working directory can keep that directory locked after the renderer
# exits, which makes the uninstaller leave an empty app folder behind.
Push-Location $SourceRoot
try {
    & powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File (Join-Path $appDir 'Studio-SessionRecovery.ps1') -RenderDir $outDir *> (Join-Path $renderRoot 'render.log')
    $renderExit = $LASTEXITCODE
} finally {
    Pop-Location
}
if ($renderExit -ne 0) {
    $failures.Add("Installed app renderer exited with code $renderExit")
} else {
    foreach ($page in $pages) {
        $checkPath = Join-Path $outDir ($page + '.check.txt')
        if (-not (Test-Path -LiteralPath $checkPath)) {
            $failures.Add("Missing installed-app check report: $page")
            continue
        }
        $report = Get-Content -LiteralPath $checkPath -Raw
        if ($report -notmatch 'OK:') {
            $detail = ($report -replace '\r?\n', ' | ').Trim()
            $failures.Add("Installed app layout issue on $page`: $detail")
        }
    }
}

# Always try to uninstall, even after a payload failure, so CI runners are not
# left with a registered product.
$uninstallExit = Invoke-MsiExec -Arguments @('/x', $productCode) -LogPath $uninstallLog
if ($uninstallExit -ne 0) {
    $failures.Add("MSI uninstall failed with exit code $uninstallExit")
} else {
    # Windows Installer can release the last directory handle a moment after
    # msiexec exits, so give it a short grace period before failing cleanup.
    $deadline = (Get-Date).AddSeconds(15)
    while ((Test-Path -LiteralPath $appDir) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
    }
    if (Test-Path -LiteralPath $appDir) {
        $failures.Add("Uninstall left the application folder behind: $appDir")
    } else {
        Write-Host 'Uninstall removed the application folder.'
    }
}

if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host ("Installer smoke test failed with {0} issue(s):" -f $failures.Count)
    foreach ($failure in $failures) { Write-Host ("  - " + $failure) }
    Write-Host ("Logs: {0}" -f $OutputRoot)
    exit 1
}

Write-Host 'Installer smoke test passed.'
exit 0
