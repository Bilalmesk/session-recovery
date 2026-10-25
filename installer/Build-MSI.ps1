#requires -Version 5.1
<#
    Build-MSI.ps1
    Builds the per-user Session Recovery MSI with WiX.

    Prerequisites
      .NET SDK 6 or newer. NuGet restore downloads the WiX SDK and UI extension.

    Examples
      powershell -NoProfile -ExecutionPolicy Bypass -File .\installer\Build-MSI.ps1
      powershell -NoProfile -ExecutionPolicy Bypass -File .\installer\Build-MSI.ps1 -Version 2.2.1
#>
[CmdletBinding()]
param(
    [ValidatePattern('^\d+\.\d+\.\d+(\.\d+)?$')]
    [string]$Version = '2.4.0',
    [switch]$NoRestore
)

$ErrorActionPreference = 'Stop'

$root = Split-Path $PSScriptRoot -Parent
$project = Join-Path $PSScriptRoot 'SessionRecovery.Installer.wixproj'
$dist = Join-Path $root 'dist'

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw '.NET SDK not found. Install .NET SDK 6 or newer, then run this script again.'
}
if (-not (Test-Path -LiteralPath $project)) {
    throw "Installer project not found: $project"
}

if (-not (Test-Path -LiteralPath $dist)) {
    New-Item -ItemType Directory -Path $dist -Force | Out-Null
}

# The native host is generated, so always make sure the MSI picks up a fresh
# binary before WiX compiles the package.
$launcherBuilder = Join-Path $PSScriptRoot 'Build-Launcher.ps1'
if (-not (Test-Path -LiteralPath $launcherBuilder)) {
    throw "Launcher build script not found: $launcherBuilder"
}
& $launcherBuilder -Force
if ($LASTEXITCODE -ne 0) {
    throw "Launcher build failed with exit code $LASTEXITCODE."
}

$buildArgs = @(
    'build', $project,
    '-c', 'Release',
    ('-p:ProductVersion={0}' -f $Version)
)
if ($NoRestore) { $buildArgs += '--no-restore' }

Write-Host ("Building Session Recovery {0} MSI..." -f $Version)
& dotnet @buildArgs
if ($LASTEXITCODE -ne 0) {
    throw "MSI build failed with exit code $LASTEXITCODE."
}

$msi = Join-Path $dist ("SessionRecovery-{0}.msi" -f $Version)
if (-not (Test-Path -LiteralPath $msi)) {
    throw "Build completed but the expected MSI was not found: $msi"
}

$hash = Get-FileHash -LiteralPath $msi -Algorithm SHA256
$hashFile = "$msi.sha256"
("{0}  {1}" -f $hash.Hash, (Split-Path $msi -Leaf)) | Set-Content -LiteralPath $hashFile -Encoding ASCII

$releaseReadme = Join-Path $dist ("SessionRecovery-{0}-README.txt" -f $Version)
$releaseText = @"
Session Recovery {0}
====================

Reopen the apps, File Explorer folders and browser tabs that were open before
a crash, power cut or unexpected restart.

What's new in 2.4
-----------------
- Nine languages: English, Arabic (with right-to-left layout), French,
  Spanish, German, Portuguese, Russian, Chinese and Turkish. Pick the
  language in Settings > Appearance; the whole UI switches instantly.
- Smart capture: automatic snapshots pause while the PC is idle or a
  fullscreen app or game is in front. Manual captures always run.
- Global hotkey: Ctrl+Alt+S takes a snapshot from anywhere while the
  background app is running.
- Snapshots now show what changed since the previous one: applications
  opened or closed, and browser tab movement.
- Optional auto-backup folder: every new snapshot is copied to a folder
  you choose (for example a OneDrive folder), keeping the latest ten.
- Media restore beyond VLC: MPC-HC, MPC-BE, mpv, PotPlayer and Windows
  Media Player reopen the file that was playing, resuming where supported.
- Browser detection covers Vivaldi, Chromium, Opera, Opera GX, Waterfox
  and LibreWolf, including installs outside the usual folders.
- Fourteen studio themes with audited text contrast, faster animated
  Diagnostics checks with a hang watchdog, and completely silent
  automatic snapshots: no popups, no sounds.

Install
-------
1. Download both files from the GitHub Releases page:
     SessionRecovery-{0}.msi
     SessionRecovery-{0}.msi.sha256
2. Run the MSI. The Custom Setup page lets you choose the install folder and
   keep or clear the optional Desktop shortcut. The default install is for the
   current user in:
     %LOCALAPPDATA%\SessionRecovery\app
   No administrator rights are required.
   The MSI is not code-signed. If Windows SmartScreen appears, choose
   More info > Run anyway after checking the SHA256 below.
3. A Session Recovery desktop icon opens the Studio. The background app starts
   after the next sign-in; you can also open Start Menu > Session Recovery >
   Run in Background.
4. Left-click the tray icon to open the Studio, or right-click it for the menu
   (restore, snapshot now, pause, folders, settings, diagnostics, exit).

Verify the download (optional)
------------------------------
In PowerShell, from the download folder:

  Get-FileHash .\SessionRecovery-{0}.msi -Algorithm SHA256

Expected SHA256:
  {1}

Your data
---------
Snapshots, logs and settings are stored locally in:
  %LOCALAPPDATA%\SessionRecovery

Nothing is uploaded. Snapshots are not encrypted.

Uninstall
---------
Use Settings > Apps > Installed apps > Session Recovery, or Start Menu >
Session Recovery > Uninstall Session Recovery. Your snapshots and settings
are kept. Delete the data folder above to remove them.

More information
----------------
The full README and source are in the GitHub repository:
  https://github.com/Bilalmesk/session-recovery
"@ -f $Version, $hash.Hash
Set-Content -LiteralPath $releaseReadme -Value $releaseText -Encoding ASCII

Write-Host ''
Write-Host ("MSI:    {0}" -f $msi)
Write-Host ("SHA256: {0}" -f $hash.Hash)
Write-Host ("Hash:   {0}" -f $hashFile)
Write-Host ("Readme: {0}" -f $releaseReadme)
exit 0
