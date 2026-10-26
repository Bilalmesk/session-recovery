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
    [string]$Version = '2.6.0',
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

What's new in 2.6
-----------------
- Every page and dialog now fits long translations in all nine languages:
  long labels wrap or ellipsize, hint text wraps, badges size to their text,
  and the layout audit checks every page at normal and minimum window sizes.
- Snapshots can be sealed with DPAPI encryption using your Windows user key;
  gzip-compressed snapshots now follow the same retention rules.
- Virtual desktops are remembered per window and restored when the desktop
  still exists. Windows from unplugged monitors are mapped onto the current
  layout instead of being clamped off-screen.
- Dev workspace restore reopens VS Code, Cursor, JetBrains IDEs and Windows
  Terminal folders directly from the editors' own recent-project state.
- Crash facts show why Windows stopped (power loss, blue screen with stop
  code, or a clean restart), and Office AutoRecover files (.asd/.wbk/.xar/
  .xlsb) are listed after a crash.
- PuTTY sessions and Remote Desktop targets reconnect directly on restore;
  mpv reports exact playback positions through its IPC pipe.
- Launch ordering rules, per-app delays and waits, a restore preview,
  snapshot compare and a local control pipe.
- Pester tests, a nine-language UI audit, an MSI build and an installer smoke
  test run automatically on every pull request.
- Window thumbnails remain opt-in and skip excluded apps and browsers.
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
   The MSI is unsigned unless the release was built with signing credentials.
   If Windows SmartScreen appears, choose More info > Run anyway after
   checking the SHA256 below.
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

Nothing is uploaded. Snapshots are plain JSON by default; if you enable
encryption in Settings, the payload is sealed with DPAPI and only your
Windows user on this PC can read it. Excluded apps, folders and URLs never
reach the snapshot files.

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
