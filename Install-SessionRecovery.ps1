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
    a hidden watcher process takes the periodic snapshots instead.

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

# Stop an older watcher from a previous installation so it cannot keep
# running alongside the new task/watcher.
try {
    $oldWatchers = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | Where-Object {
        $_.CommandLine -and ($_.CommandLine -match '(?i)Watch-Session\.ps1')
    })
    foreach ($watcher in $oldWatchers) {
        try { Stop-Process -Id ([int]$watcher.ProcessId) -Force -ErrorAction Stop } catch { }
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
    'Watch-Session.ps1',
    'Diagnostics.ps1',
    'RunHidden.vbs'
)

foreach ($file in $moduleFiles) {
    $path = Join-Path $sourceDirectory $file
    if (-not (Test-Path -LiteralPath $path)) { throw "Missing source file: $path" }
}
$uninstallerSource = Join-Path $sourceRoot 'Uninstall-SessionRecovery.ps1'
if (-not (Test-Path -LiteralPath $uninstallerSource)) { throw "Missing source file: $uninstallerSource" }

Write-Step "Installing to $InstallDirectory"
if (-not (Test-Path -LiteralPath $InstallDirectory)) {
    New-Item -ItemType Directory -Path $InstallDirectory -Force | Out-Null
}

foreach ($file in $moduleFiles) {
    $destination = Join-Path $InstallDirectory $file
    Copy-Item -LiteralPath (Join-Path $sourceDirectory $file) -Destination $destination -Force
    Unblock-File -LiteralPath $destination -ErrorAction SilentlyContinue
}
Copy-Item -LiteralPath $uninstallerSource -Destination (Join-Path $InstallDirectory 'Uninstall-SessionRecovery.ps1') -Force
Unblock-File -LiteralPath (Join-Path $InstallDirectory 'Uninstall-SessionRecovery.ps1') -ErrorAction SilentlyContinue
Write-Step "Copied program files."

$readmeSource = Join-Path $sourceRoot 'README.md'
if (Test-Path -LiteralPath $readmeSource) {
    Copy-Item -LiteralPath $readmeSource -Destination (Join-Path $InstallDirectory 'README.md') -Force
}

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
$wscriptPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
$runHiddenPath = Join-Path $InstallDirectory 'RunHidden.vbs'

$startMenuFolder = Join-Path ([Environment]::GetFolderPath('Programs')) 'Session Recovery'
if (-not (Test-Path -LiteralPath $startMenuFolder)) {
    New-Item -ItemType Directory -Path $startMenuFolder -Force | Out-Null
}

$manualArguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Manual' -f (Join-Path $InstallDirectory 'Restore-Session.ps1')
New-SRShortcut -Path (Join-Path $startMenuFolder 'Restore Session.lnk') `
    -TargetPath $powershellPath -Arguments $manualArguments -WorkingDirectory $InstallDirectory `
    -IconLocation "$env:SystemRoot\System32\shell32.dll,167" `
    -Description 'Reopen the windows and tabs from a saved session.'
Write-Step "Created Start Menu shortcut: Restore Session"

$snapshotArguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Quiet' -f (Join-Path $InstallDirectory 'Save-Session.ps1')
New-SRShortcut -Path (Join-Path $startMenuFolder 'Take Snapshot Now.lnk') `
    -TargetPath $powershellPath -Arguments $snapshotArguments -WorkingDirectory $InstallDirectory `
    -IconLocation "$env:SystemRoot\System32\shell32.dll,137" `
    -Description 'Save a snapshot of the current windows and tabs right now.'

$diagnosticsArguments = '-NoProfile -ExecutionPolicy Bypass -NoExit -File "{0}"' -f (Join-Path $InstallDirectory 'Diagnostics.ps1')
New-SRShortcut -Path (Join-Path $startMenuFolder 'Run Diagnostics.lnk') `
    -TargetPath $powershellPath -Arguments $diagnosticsArguments -WorkingDirectory $InstallDirectory `
    -IconLocation "$env:SystemRoot\System32\shell32.dll,221" `
    -Description 'Show a Session Recovery health report.'
Write-Step "Created Start Menu shortcut: Run Diagnostics"

$uninstallArguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $InstallDirectory 'Uninstall-SessionRecovery.ps1')
New-SRShortcut -Path (Join-Path $startMenuFolder 'Uninstall Session Recovery.lnk') `
    -TargetPath $powershellPath -Arguments $uninstallArguments -WorkingDirectory $InstallDirectory `
    -IconLocation "$env:SystemRoot\System32\shell32.dll,131" `
    -Description 'Remove Session Recovery.'

if (-not $NoDesktopShortcut) {
    $desktop = [Environment]::GetFolderPath('Desktop')
    New-SRShortcut -Path (Join-Path $desktop 'Restore Session.lnk') `
        -TargetPath $powershellPath -Arguments $manualArguments -WorkingDirectory $InstallDirectory `
        -IconLocation "$env:SystemRoot\System32\shell32.dll,167" `
        -Description 'Reopen the windows and tabs from a saved session.'
    Write-Step "Created desktop shortcut: Restore Session"
}

# ---------------------------------------------------------------------------
# Snapshot mechanism: scheduled tasks, or Startup folder watcher
# ---------------------------------------------------------------------------

$startupDirectory = [Environment]::GetFolderPath('Startup')
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

    $snapshotAction = New-ScheduledTaskAction -Execute $wscriptPath `
        -Argument ('"{0}" save' -f $runHiddenPath) -WorkingDirectory $InstallDirectory
    $restoreAction = New-ScheduledTaskAction -Execute $powershellPath `
        -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f (Join-Path $InstallDirectory 'Restore-Session.ps1')) `
        -WorkingDirectory $InstallDirectory

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
        Write-Host 'Falling back to Startup folder shortcuts (hidden watcher process).' -ForegroundColor Yellow
        $useTasks = $false
    }
}

if ($tasksReady) {
    Remove-Item -LiteralPath $startupWatcherPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $startupRestorePath -Force -ErrorAction SilentlyContinue
} else {
    Unregister-SRTasks

    New-SRShortcut -Path $startupWatcherPath -TargetPath $wscriptPath `
        -Arguments ('"{0}" watch' -f $runHiddenPath) -WorkingDirectory $InstallDirectory `
        -Description 'Session Recovery: keeps taking snapshots while you are logged on.'
    New-SRShortcut -Path $startupRestorePath -TargetPath $wscriptPath `
        -Arguments ('"{0}" restore' -f $runHiddenPath) -WorkingDirectory $InstallDirectory `
        -Description 'Session Recovery: shows the restore prompt after logon.'
    Write-Step 'Created Startup folder entries: snapshot watcher and restore prompt.'
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
} else {
    Write-Host  '  Snapshots      : hidden watcher started from the Startup folder at logon'
    Write-Host  '  Restore prompt : Startup folder entry at logon'
}
Write-Host  '  Manual restore : Start Menu > Session Recovery > Restore Session'
Write-Host  '  Diagnostics    : Start Menu > Session Recovery > Run Diagnostics'
Write-Host  '  Uninstall      : Start Menu > Session Recovery > Uninstall Session Recovery'
Write-Host ''
Write-Host 'Snapshots are taken automatically from now on. To undo everything, run the uninstaller.'
exit 0
