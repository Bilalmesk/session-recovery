#requires -Version 5.1
<#
    Install-SessionRecovery.ps1
    Installs Session Recovery for the current user.

    What it does
      1. Copies the program files to %LOCALAPPDATA%\SessionRecovery\app.
      2. Writes a default config.json under %LOCALAPPDATA%\SessionRecovery.
      3. Creates Start Menu and desktop shortcuts.
      4. Registers scheduled tasks (at logon + every few minutes), or falls
         back to Startup folder shortcuts when -NoTasks is used.
      5. Takes an initial snapshot.

    Scheduled tasks require administrator rights, so the installer asks for
    elevation once. Use -NoTasks to install without a UAC prompt; in that mode
    the native background tray app takes the periodic snapshots instead.

    Examples
      powershell -ExecutionPolicy Bypass -File Install-SessionRecovery.ps1
      powershell -ExecutionPolicy Bypass -File Install-SessionRecovery.ps1 -NoTasks
      powershell -ExecutionPolicy Bypass -File Install-SessionRecovery.ps1 -IntervalMinutes 5
      powershell -ExecutionPolicy Bypass -File Install-SessionRecovery.ps1 -KeepSnapshotDays 30
#>
[CmdletBinding()]
param(
    [string]$InstallDirectory = (Join-Path $env:LOCALAPPDATA 'SessionRecovery\app'),
    [int]$IntervalMinutes = 3,
    [int]$KeepSnapshots = 48,
    [int]$KeepSnapshotDays = 0,
    [ValidateSet('CrashOnly', 'Always', 'Never')][string]$PromptOnLogon = 'CrashOnly',
    [ValidateSet('Smart', 'Captured', 'Native', 'None')][string]$DefaultTabMode = 'Smart',
    [switch]$NoTasks,
    [switch]$NoDesktopShortcut,
    [switch]$NoInitialSnapshot,
    [switch]$Elevated
)

$ErrorActionPreference = 'Stop'

$taskNames = @('SessionRecovery-Snapshot', 'SessionRecovery-RestorePrompt')
$dataRoot = Join-Path $env:LOCALAPPDATA 'SessionRecovery'
$installerPath = $PSCommandPath

$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$currentUser = $identity.Name
$isAdmin = (New-Object System.Security.Principal.WindowsPrincipal($identity)).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)

function Write-Step {
    param([string]$Text)
    Write-Host ("  " + $Text)
}

function New-SRShortcut {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$TargetPath,
        [string]$Arguments = '',
        [string]$WorkingDirectory = '',
        [string]$IconLocation = '',
        [string]$Description = ''
    )
    $shell = New-Object -ComObject WScript.Shell
    try {
        $shortcut = $shell.CreateShortcut($Path)
        $shortcut.TargetPath = $TargetPath
        if ($Arguments) { $shortcut.Arguments = $Arguments }
        if ($WorkingDirectory) { $shortcut.WorkingDirectory = $WorkingDirectory }
        if ($IconLocation) { $shortcut.IconLocation = $IconLocation }
        if ($Description) { $shortcut.Description = $Description }
        $shortcut.Save()
    } finally {
        try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) } catch { }
    }
}

# ---------------------------------------------------------------------------
# Elevation for scheduled tasks
# ---------------------------------------------------------------------------

$useTasks = -not $NoTasks

if ($useTasks -and -not $isAdmin -and -not $Elevated) {
    Write-Host 'Session Recovery installation'
    Write-Host ''
    Write-Host 'Scheduled tasks are part of this installation and require administrator rights.'
    Write-Host 'A Windows UAC prompt will appear. Choose Yes to continue, or press Ctrl+C and'
    Write-Host 're-run this script with -NoTasks to install without administrator rights.'
    Write-Host ''

    $argumentList = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$installerPath`"",
        '-InstallDirectory', "`"$InstallDirectory`"",
        '-IntervalMinutes', $IntervalMinutes,
        '-KeepSnapshots', $KeepSnapshots,
        '-KeepSnapshotDays', $KeepSnapshotDays,
        '-PromptOnLogon', $PromptOnLogon,
        '-DefaultTabMode', $DefaultTabMode,
        '-Elevated'
    )
    if ($NoDesktopShortcut) { $argumentList += '-NoDesktopShortcut' }
    if ($NoInitialSnapshot) { $argumentList += '-NoInitialSnapshot' }

    try {
        $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $argumentList -Verb RunAs -Wait -PassThru
        exit $process.ExitCode
    } catch {
        Write-Host ''
        Write-Host 'The elevated installation was cancelled or blocked.' -ForegroundColor Yellow
        Write-Host 'Re-run this script with -NoTasks to install without scheduled tasks.'
        exit 1
    }
}

Write-Host 'Session Recovery installation'
Write-Host ''

# Stop an older watcher or tray app from a previous installation so it cannot
# keep running alongside the new task/watcher.
try {
    $oldBackground = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | Where-Object {
        $_.CommandLine -and ($_.CommandLine -match '(?i)Watch-Session\.ps1|Tray-SessionRecovery\.ps1')
    })
    $oldBackground += @(Get-CimInstance Win32_Process -Filter "Name='SessionRecovery.exe'" -ErrorAction SilentlyContinue | Where-Object {
        $_.CommandLine -and ($_.CommandLine -match '(?i)--tray')
    })
    foreach ($process in $oldBackground) {
        try { Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction Stop } catch { }
    }
} catch { }

# ---------------------------------------------------------------------------
# Copy program files
# ---------------------------------------------------------------------------

$sourceRoot = $PSScriptRoot
$sourceDirectory = Join-Path $sourceRoot 'src'
if (-not (Test-Path -LiteralPath $sourceDirectory)) {
    throw "Source folder not found: $sourceDirectory. Run this script from the session-recovery folder."
}

$moduleFiles = @(
    'SessionRecovery.psm1',
    'Save-Session.ps1',
    'Restore-Session.ps1',
    'Tray-SessionRecovery.ps1',
    'Watch-Session.ps1',
    'Diagnostics.ps1',
    'RunHidden.vbs',
    'Studio-SessionRecovery.ps1',
    'Strings.ps1',
    'StudioTheme.ps1',
    'Control-SessionRecovery.ps1',
    'StudioControls.cs',
    'StudioTheme.ps1',
    'InstallManifest.ps1'
)

foreach ($file in $moduleFiles) {
    $path = Join-Path $sourceDirectory $file
    if (-not (Test-Path -LiteralPath $path)) { throw "Missing source file: $path" }
}
$hostSource = Join-Path $sourceRoot 'dist\SessionRecovery.exe'
if (-not (Test-Path -LiteralPath $hostSource)) {
    $launcherBuilder = Join-Path $sourceRoot 'installer\Build-Launcher.ps1'
    if (-not (Test-Path -LiteralPath $launcherBuilder)) { throw "Missing launcher build script: $launcherBuilder" }
    & $launcherBuilder -Force
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $hostSource)) { throw "Could not build $hostSource" }
}
$uninstallerSource = Join-Path $sourceRoot 'Uninstall-SessionRecovery.ps1'
if (-not (Test-Path -LiteralPath $uninstallerSource)) { throw "Missing source file: $uninstallerSource" }
$brandIconSource = Join-Path $sourceRoot 'assets\SessionRecovery.ico'
if (-not (Test-Path -LiteralPath $brandIconSource)) { throw "Missing brand asset: $brandIconSource" }

Write-Step "Installing to $InstallDirectory"
if (-not (Test-Path -LiteralPath $InstallDirectory)) {
    New-Item -ItemType Directory -Path $InstallDirectory -Force | Out-Null
}

foreach ($file in $moduleFiles) {
    $destination = Join-Path $InstallDirectory $file
    Copy-Item -LiteralPath (Join-Path $sourceDirectory $file) -Destination $destination -Force
    Unblock-File -LiteralPath $destination -ErrorAction SilentlyContinue
}
Copy-Item -LiteralPath $hostSource -Destination (Join-Path $InstallDirectory 'SessionRecovery.exe') -Force
Unblock-File -LiteralPath (Join-Path $InstallDirectory 'SessionRecovery.exe') -ErrorAction SilentlyContinue
Copy-Item -LiteralPath $uninstallerSource -Destination (Join-Path $InstallDirectory 'Uninstall-SessionRecovery.ps1') -Force
Unblock-File -LiteralPath (Join-Path $InstallDirectory 'Uninstall-SessionRecovery.ps1') -ErrorAction SilentlyContinue
Copy-Item -LiteralPath $brandIconSource -Destination (Join-Path $InstallDirectory 'SessionRecovery.ico') -Force
Unblock-File -LiteralPath (Join-Path $InstallDirectory 'SessionRecovery.ico') -ErrorAction SilentlyContinue
Write-Step "Copied program files."

$readmeSource = Join-Path $sourceRoot 'README.md'
if (Test-Path -LiteralPath $readmeSource) {
    Copy-Item -LiteralPath $readmeSource -Destination (Join-Path $InstallDirectory 'README.md') -Force
}

# The manifest is the uninstaller's proof of ownership. It contains leaf file
# names only, never paths, so uninstall cannot be pointed at another folder.
$manifestHelper = Join-Path $sourceDirectory 'InstallManifest.ps1'
. $manifestHelper
$manifestFiles = @($moduleFiles) + @('SessionRecovery.exe', 'Uninstall-SessionRecovery.ps1', 'SessionRecovery.ico')
if (Test-Path -LiteralPath (Join-Path $InstallDirectory 'README.md')) { $manifestFiles += 'README.md' }
[void](New-SRInstallManifest -InstallDirectory $InstallDirectory -Files $manifestFiles)
Write-Step 'Wrote install manifest.'

foreach ($directory in @($dataRoot, (Join-Path $dataRoot 'snapshots'), (Join-Path $dataRoot 'logs'))) {
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
}

# ---------------------------------------------------------------------------
# Configuration and initial snapshot
# ---------------------------------------------------------------------------

$previousHome = $env:SESSIONRECOVERY_HOME
$modulePath = Join-Path $InstallDirectory 'SessionRecovery.psm1'
try {
    $env:SESSIONRECOVERY_HOME = $null
    Remove-Module SessionRecovery -Force -ErrorAction SilentlyContinue
    Import-Module $modulePath -Force -ErrorAction Stop

    $config = Get-SRConfig
    $config.snapshotIntervalMinutes = [Math]::Max(1, $IntervalMinutes)
    $config.keepSnapshots = [Math]::Max(1, $KeepSnapshots)
    $config.keepSnapshotDays = [Math]::Max(0, $KeepSnapshotDays)
    $config.promptOnLogon = $PromptOnLogon
    $config.defaultTabMode = $DefaultTabMode
    Save-SRConfig -Config $config
    Write-Step "Wrote configuration to $(Get-SRConfigPath)."

    if (-not $NoInitialSnapshot) {
        $snapshotPath = Save-SRSnapshot
        if ($snapshotPath) { Write-Step "Saved initial snapshot: $snapshotPath" }
    }
} finally {
    if ($null -ne $previousHome -and $previousHome -ne '') {
        $env:SESSIONRECOVERY_HOME = $previousHome
    } else {
        Remove-Item Env:\SESSIONRECOVERY_HOME -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# Shortcuts
# ---------------------------------------------------------------------------

$powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$hostPath = Join-Path $InstallDirectory 'SessionRecovery.exe'
$brandIconPath = Join-Path $InstallDirectory 'SessionRecovery.ico'

$startMenuFolder = Join-Path ([Environment]::GetFolderPath('Programs')) 'Session Recovery'
if (-not (Test-Path -LiteralPath $startMenuFolder)) {
    New-Item -ItemType Directory -Path $startMenuFolder -Force | Out-Null
}

New-SRShortcut -Path (Join-Path $startMenuFolder 'Session Recovery.lnk') `
    -TargetPath $hostPath -WorkingDirectory $InstallDirectory `
    -IconLocation "$brandIconPath,0" `
    -Description 'Open the Session Recovery Studio.'
Write-Step "Created Start Menu shortcut: Session Recovery"

New-SRShortcut -Path (Join-Path $startMenuFolder 'Restore Session.lnk') `
    -TargetPath $hostPath -Arguments '--restore-manual' -WorkingDirectory $InstallDirectory `
    -IconLocation "$brandIconPath,0" `
    -Description 'Reopen the windows and tabs from a saved session.'
Write-Step "Created Start Menu shortcut: Restore Session"

New-SRShortcut -Path (Join-Path $startMenuFolder 'Take Snapshot Now.lnk') `
    -TargetPath $hostPath -Arguments '--snapshot' -WorkingDirectory $InstallDirectory `
    -IconLocation "$brandIconPath,0" `
    -Description 'Save a snapshot of the current windows and tabs right now.'
Write-Step "Created Start Menu shortcut: Take Snapshot Now"

New-SRShortcut -Path (Join-Path $startMenuFolder 'Run in Background.lnk') `
    -TargetPath $hostPath -Arguments '--tray' -WorkingDirectory $InstallDirectory `
    -IconLocation "$brandIconPath,0" `
    -Description 'Start the Session Recovery notification-area app.'
Write-Step "Created Start Menu shortcut: Run in Background"

New-SRShortcut -Path (Join-Path $startMenuFolder 'Run Diagnostics.lnk') `
    -TargetPath $hostPath -Arguments '--diagnostics' -WorkingDirectory $InstallDirectory `
    -IconLocation "$brandIconPath,0" `
    -Description 'Show a Session Recovery health report.'
Write-Step "Created Start Menu shortcut: Run Diagnostics"

$uninstallArguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $InstallDirectory 'Uninstall-SessionRecovery.ps1')
New-SRShortcut -Path (Join-Path $startMenuFolder 'Uninstall Session Recovery.lnk') `
    -TargetPath $powershellPath -Arguments $uninstallArguments -WorkingDirectory $InstallDirectory `
    -IconLocation "$brandIconPath,0" `
    -Description 'Remove Session Recovery.'

$desktop = [Environment]::GetFolderPath('Desktop')
$legacyDesktopShortcut = Join-Path $desktop 'Restore Session.lnk'
if (Test-Path -LiteralPath $legacyDesktopShortcut) {
    Remove-Item -LiteralPath $legacyDesktopShortcut -Force -ErrorAction SilentlyContinue
}
if (-not $NoDesktopShortcut) {
    New-SRShortcut -Path (Join-Path $desktop 'Session Recovery.lnk') `
        -TargetPath $hostPath -WorkingDirectory $InstallDirectory `
        -IconLocation "$brandIconPath,0" `
        -Description 'Open the Session Recovery Studio.'
    Write-Step "Created desktop shortcut: Session Recovery"
} else {
    Remove-Item -LiteralPath (Join-Path $desktop 'Session Recovery.lnk') -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# Snapshot mechanism: scheduled tasks, or the Startup folder tray app
# ---------------------------------------------------------------------------

$startupDirectory = [Environment]::GetFolderPath('Startup')
$startupBackgroundPath = Join-Path $startupDirectory 'Session Recovery - Background.lnk'
$startupWatcherPath = Join-Path $startupDirectory 'Session Recovery - Snapshot Watcher.lnk'
$startupRestorePath = Join-Path $startupDirectory 'Session Recovery - Restore Prompt.lnk'

function Unregister-SRTasks {
    foreach ($name in $taskNames) {
        try {
            $task = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
            if ($task) {
                Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction Stop
                Write-Step "Removed scheduled task: $name"
            }
        } catch {
            Write-Step "Could not remove scheduled task $name (administrator rights may be required)."
        }
    }
}

function Register-SRTasks {
    param([int]$Minutes)

    $snapshotAction = New-ScheduledTaskAction -Execute $hostPath `
        -Argument '--snapshot-quiet' -WorkingDirectory $InstallDirectory
    $restoreAction = New-ScheduledTaskAction -Execute $hostPath `
        -Argument '--restore-prompt' -WorkingDirectory $InstallDirectory

    $logonTrigger = New-ScheduledTaskTrigger -AtLogOn -User $currentUser
    $repeatTrigger = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(1)) `
        -RepetitionInterval (New-TimeSpan -Minutes ([Math]::Max(1, $Minutes)))

    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
    $principal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType Interactive -RunLevel Limited

    Register-ScheduledTask -TaskName 'SessionRecovery-Snapshot' -Action $snapshotAction `
        -Trigger @($logonTrigger, $repeatTrigger) -Settings $settings -Principal $principal `
        -Description 'Session Recovery: snapshot the desktop at logon and every few minutes.' -Force | Out-Null

    $restoreTrigger = New-ScheduledTaskTrigger -AtLogOn -User $currentUser
    try { $restoreTrigger.Delay = 'PT25S' } catch { }

    Register-ScheduledTask -TaskName 'SessionRecovery-RestorePrompt' -Action $restoreAction `
        -Trigger $restoreTrigger -Settings $settings -Principal $principal `
        -Description 'Session Recovery: prompt to restore after an unexpected shutdown.' -Force | Out-Null
}

$tasksReady = $false
if ($useTasks) {
    try {
        Register-SRTasks -Minutes $IntervalMinutes
        $tasksReady = $true
        Write-Step 'Registered scheduled tasks: SessionRecovery-Snapshot, SessionRecovery-RestorePrompt'
    } catch {
        Write-Host ''
        Write-Host ("Could not register scheduled tasks: " + $_.Exception.Message) -ForegroundColor Yellow
        Write-Host 'Falling back to the Startup folder tray app.' -ForegroundColor Yellow
        $useTasks = $false
    }
}

if ($tasksReady) {
    Remove-Item -LiteralPath $startupWatcherPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $startupBackgroundPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $startupRestorePath -Force -ErrorAction SilentlyContinue

    New-SRShortcut -Path $startupBackgroundPath -TargetPath $hostPath `
        -Arguments '--tray-monitor' -WorkingDirectory $InstallDirectory `
        -IconLocation "$brandIconPath,0" `
        -Description 'Session Recovery: background status and controls. Snapshots run as a scheduled task.'
    Write-Step 'Created Startup folder entry: background tray (scheduled-task mode).'
} else {
    Unregister-SRTasks

    Remove-Item -LiteralPath $startupWatcherPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $startupBackgroundPath -Force -ErrorAction SilentlyContinue

    New-SRShortcut -Path $startupBackgroundPath -TargetPath $hostPath `
        -Arguments '--tray' -WorkingDirectory $InstallDirectory `
        -IconLocation "$brandIconPath,0" `
        -Description 'Session Recovery: keeps taking snapshots while you are logged on.'
    New-SRShortcut -Path $startupRestorePath -TargetPath $hostPath `
        -Arguments '--restore-prompt' -WorkingDirectory $InstallDirectory `
        -IconLocation "$brandIconPath,0" `
        -Description 'Session Recovery: shows the restore prompt after logon.'
    Write-Step 'Created Startup folder entries: background tray and restore prompt.'
}

# Start the tray now so the notification-area icon is available immediately.
# Do not start it from an elevated installer: the Startup shortcut will use a
# normal user token after the next sign-in.
if (-not $isAdmin) {
    try {
        $trayMode = if ($tasksReady) { '--tray-monitor' } else { '--tray' }
        Start-Process -FilePath $hostPath -ArgumentList $trayMode -WorkingDirectory $InstallDirectory | Out-Null
        Write-Step 'Started the background tray app.'
    } catch { }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host 'Session Recovery is installed.' -ForegroundColor Green
Write-Host ''
Write-Host ("  Program folder : {0}" -f $InstallDirectory)
Write-Host ("  Data folder    : {0}" -f $dataRoot)
if ($tasksReady) {
    Write-Host ("  Snapshots      : scheduled task SessionRecovery-Snapshot every {0} minute(s) and at logon" -f [Math]::Max(1, $IntervalMinutes))
    Write-Host  '  Restore prompt : scheduled task SessionRecovery-RestorePrompt at logon'
    Write-Host  '  Tray           : background status and controls from the Startup folder'
} else {
    Write-Host  '  Snapshots      : background tray app from the Startup folder, every few minutes'
    Write-Host  '  Restore prompt : Startup folder entry at logon'
    Write-Host  '  Tray           : notification-area icon while the background app is running'
}
Write-Host  '  Tray menu      : Restore, snapshot now, pause, folders, diagnostics, exit'
Write-Host  '  Manual restore : Start Menu > Session Recovery > Restore Session'
Write-Host  '  Diagnostics    : Start Menu > Session Recovery > Run Diagnostics'
Write-Host  '  Uninstall      : Start Menu > Session Recovery > Uninstall Session Recovery'
Write-Host ''
Write-Host 'Snapshots are taken automatically from now on. To undo everything, run the uninstaller.'
exit 0
