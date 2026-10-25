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
    [string]$Version = '2.5.0',
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

What's new in 2.5
-----------------
- Window thumbnails (opt-in): each snapshot can store a small JPEG of every
  window, so the timeline shows what your screen actually looked like.
  Excluded apps are never captured. Off by default for privacy.
- Dev workspace restore: folders open in VS Code, Cursor and JetBrains IDEs
  are captured from the editors' own state files and reopened on restore;
  Windows Terminal directories reopen with wt.exe -d.
- Crash facts: the restore window and Diagnostics now show why Windows
  stopped (power loss, blue screen with stop code, or a clean restart),
  read from the System event log.
- Office AutoRecover awareness: after a crash the restore window lists the
  .asd/.wbk/.xar files Office kept, pointing straight at recoverable work.
- Named workspaces: save the current session as "Work" or "Study" from the
  tray and restore it later in one click.
- Event-driven snapshots: extra captures on lock, sleep/resume and when the
  battery runs low (all optional).
- Change detection: identical moments are skipped, so retention covers more
  real changes; snapshots can optionally be gzip-compressed.
- URL redaction: query strings and fragments are stripped from captured
  URLs by default, keeping tokens out of the snapshot files.
- Nine languages, fourteen themes, media restore beyond VLC, broader
  browser detection and silent automatic snapshots carry over from 2.4.
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
