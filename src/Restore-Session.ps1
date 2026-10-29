#requires -Version 5.1
<#
    Restore-Session.ps1
    Shows the restore prompt after an unexpected shutdown, or restores a
    snapshot on demand (Start Menu shortcut uses -Manual).

    Parameters
      -Manual          Always show the UI, even after a clean shutdown.
      -NoUI            Restore everything without showing a window.
      -DryRun          Print what would be restored and exit.
      -Force           Start apps even when they are already running.
      -SnapshotPath    Use a specific snapshot JSON file.
      -AllowImportedSnapshot  Confirm headless restore of an imported snapshot.
      -TabMode         Smart (default), Captured, Native or None.
      -MaxAgeHours     Override the configured maximum snapshot age.
      -ListSnapshots   Print saved snapshots and exit.
      -IncludeApps     Only restore apps matching these wildcard patterns.
      -IncludeFolders  Only restore folders matching these wildcard patterns.
      -IncludeBrowsers Only restore browsers matching these wildcard patterns.
      -ExcludeApps     Skip apps matching these wildcard patterns.
      -ExcludeFolders  Skip folders matching these wildcard patterns.
      -ExcludeBrowsers Skip browsers matching these wildcard patterns.

    Include/exclude filters apply to -NoUI and -DryRun. Interactive restores
    use the checkboxes in the restore window.

    -RenderScreenshot <path> renders the restore window off-screen to a PNG
    and exits. It exists so the window can be verified without a live user.
#>
[CmdletBinding()]
param(
    [switch]$Manual,
    [switch]$NoUI,
    [switch]$Force,
    [switch]$DryRun,
    [string]$SnapshotPath,
    [switch]$AllowImportedSnapshot,
    [ValidateSet('Smart', 'Captured', 'Native', 'None')][string]$TabMode,
    [int]$MaxAgeHours = 0,
    [int]$StartupDelaySeconds = 0,
    [switch]$ListSnapshots,
    [string[]]$IncludeApps,
    [string[]]$IncludeFolders,
    [string[]]$IncludeBrowsers,
    [string[]]$ExcludeApps,
    [string[]]$ExcludeFolders,
    [string[]]$ExcludeBrowsers,
    [string]$RenderScreenshot
)

$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'SessionRecovery.psm1'
Import-Module $modulePath -Force -ErrorAction Stop
. (Join-Path $PSScriptRoot 'Strings.ps1')
try {
    $restoreLanguage = 'en'
    $restoreConfig = Get-SRConfig
    $restoreLanguageProperty = $restoreConfig.PSObject.Properties['language']
    if ($null -ne $restoreLanguageProperty -and -not [string]::IsNullOrWhiteSpace([string]$restoreLanguageProperty.Value)) {
        $restoreLanguage = [string]$restoreLanguageProperty.Value
    }
} catch { $restoreLanguage = 'en' }
$script:RestoreStrings = Get-SRStrings -Language $restoreLanguage
function T {
    param([Parameter(Mandatory = $true)][string]$Key, [string]$Default = '')
    if ($script:RestoreStrings -and $script:RestoreStrings.ContainsKey($Key) -and -not [string]::IsNullOrWhiteSpace([string]$script:RestoreStrings[$Key])) {
        return [string]$script:RestoreStrings[$Key]
    }
    return $Default
}
Hide-SRConsoleWindow

# Pre-2.0 tasks launch this script directly with Windows PowerShell. Hand the
# logon prompt to the native host so the long-lived restore window never keeps
# a PowerShell/conhost process around. Calls with explicit options still run
# in-process for scripts and diagnostics.
if ($PSBoundParameters.Count -eq 0 -and [string]::IsNullOrWhiteSpace($env:SESSIONRECOVERY_HOST)) {
    $nativeHost = @(
        (Join-Path $PSScriptRoot 'SessionRecovery.exe'),
        (Join-Path (Split-Path $PSScriptRoot -Parent) 'dist\SessionRecovery.exe'),
        (Join-Path $env:LOCALAPPDATA 'SessionRecovery\app\SessionRecovery.exe')
    ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if ($nativeHost) {
        try {
            Write-SRLog -Message 'Legacy restore invocation handed to the native host.'
            Start-Process -FilePath $nativeHost -ArgumentList '--restore-prompt' | Out-Null
            exit 0
        } catch {
            Write-SRLog -Level WARN -Message ('Could not hand restore to the native host: ' + $_.Exception.Message)
        }
    }
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Format-RSAge {
    param([datetime]$CapturedAt)
    $delta = (Get-Date) - $CapturedAt
    if ($delta.TotalMinutes -lt 1) { return 'just now' }
    if ($delta.TotalMinutes -lt 60) { return ('{0:N0} minute(s) ago' -f $delta.TotalMinutes) }
    if ($delta.TotalHours -lt 24) { return ('{0:N0} hour(s) ago' -f $delta.TotalHours) }
    return ('{0:N0} day(s) ago' -f $delta.TotalDays)
}

function Get-RSStats {
    param($Snapshot)
    $tabs = 0
    foreach ($browser in @($Snapshot.browsers)) {
        foreach ($profile in @($browser.profiles)) {
            $tabs += @($profile.tabs).Count
        }
    }
    return [pscustomobject]@{
        Apps     = @($Snapshot.apps).Count
        Folders  = @($Snapshot.explorer).Count
        Browsers = @($Snapshot.browsers).Count
        Tabs     = $tabs
    }
}

function Format-RSSnapshotLabel {
    param($Entry)
    $stats = Get-RSStats -Snapshot $Entry.Snapshot
    return ('{0}  -  {1} app(s), {2} folder(s), {3} browser(s), {4} tab(s)' -f
        $Entry.CapturedAt.ToString('g'), $stats.Apps, $stats.Folders, $stats.Browsers, $stats.Tabs)
}

function Get-RSPlanStats {
    param($Plan)
    $tabs = 0
    foreach ($browser in @($Plan.browsers)) {
        foreach ($profile in @($browser.profiles)) {
            $tabs += @($profile.tabs).Count
        }
    }
    return [pscustomobject]@{
        Apps     = @($Plan.apps).Count
        Folders  = @($Plan.explorer).Count
        Browsers = @($Plan.browsers).Count
        Tabs     = $tabs
    }
}

function Expand-RSPatternList {
    param([string[]]$Patterns)
    $expanded = New-Object System.Collections.Generic.List[string]
    foreach ($pattern in @($Patterns)) {
        foreach ($part in ([string]$pattern -split ',')) {
            $trimmed = $part.Trim()
            if (-not [string]::IsNullOrWhiteSpace($trimmed)) { $expanded.Add($trimmed) }
        }
    }
    return $expanded.ToArray()
}

function Select-RSPlan {
    param(
        $Plan,
        [string[]]$IncludeApps,
        [string[]]$IncludeFolders,
        [string[]]$IncludeBrowsers,
        [string[]]$ExcludeApps,
        [string[]]$ExcludeFolders,
        [string[]]$ExcludeBrowsers
    )

    # PowerShell -File passes "A,B" as one string, so accept comma-separated
    # patterns as well as a real array when the script is called directly.
    $IncludeApps = @(Expand-RSPatternList -Patterns $IncludeApps)
    $IncludeFolders = @(Expand-RSPatternList -Patterns $IncludeFolders)
    $IncludeBrowsers = @(Expand-RSPatternList -Patterns $IncludeBrowsers)
    $ExcludeApps = @(Expand-RSPatternList -Patterns $ExcludeApps)
    $ExcludeFolders = @(Expand-RSPatternList -Patterns $ExcludeFolders)
    $ExcludeBrowsers = @(Expand-RSPatternList -Patterns $ExcludeBrowsers)

    $apps = @($Plan.apps)
    if ($IncludeApps -and @($IncludeApps).Count -gt 0) {
        $apps = @($apps | Where-Object {
            $leaf = ''
            if (-not [string]::IsNullOrWhiteSpace([string]$_.exe)) {
                $leaf = [System.IO.Path]::GetFileNameWithoutExtension([string]$_.exe)
            }
            Test-SRPatternMatch -Patterns $IncludeApps -Values @([string]$_.name, [string]$_.exe, $leaf)
        })
    }
    if ($ExcludeApps -and @($ExcludeApps).Count -gt 0) {
        $apps = @($apps | Where-Object {
            $leaf = ''
            if (-not [string]::IsNullOrWhiteSpace([string]$_.exe)) {
                $leaf = [System.IO.Path]::GetFileNameWithoutExtension([string]$_.exe)
            }
            -not (Test-SRPatternMatch -Patterns $ExcludeApps -Values @([string]$_.name, [string]$_.exe, $leaf))
        })
    }

    $folders = @($Plan.explorer)
    if ($IncludeFolders -and @($IncludeFolders).Count -gt 0) {
        $folders = @($folders | Where-Object {
            Test-SRPatternMatch -Patterns $IncludeFolders -Values @([string]$_)
        })
    }
    if ($ExcludeFolders -and @($ExcludeFolders).Count -gt 0) {
        $folders = @($folders | Where-Object {
            -not (Test-SRPatternMatch -Patterns $ExcludeFolders -Values @([string]$_))
        })
    }

    $browsers = @($Plan.browsers)
    if ($IncludeBrowsers -and @($IncludeBrowsers).Count -gt 0) {
        $browsers = @($browsers | Where-Object {
            Test-SRPatternMatch -Patterns $IncludeBrowsers -Values @([string]$_.key, [string]$_.name)
        })
    }
    if ($ExcludeBrowsers -and @($ExcludeBrowsers).Count -gt 0) {
        $browsers = @($browsers | Where-Object {
            -not (Test-SRPatternMatch -Patterns $ExcludeBrowsers -Values @([string]$_.key, [string]$_.name))
        })
    }

    $dev = @()
    try { $dev = @($Plan.dev) } catch { }
    $monitors = $null
    try { $monitors = @($Plan.monitors) } catch { }
    $remote = @()
    try { $remote = @($Plan.remote) } catch { }

    return [pscustomobject]@{
        apps     = $apps
        explorer = $folders
        browsers = $browsers
        tabMode  = $Plan.tabMode
        dev      = $dev
        monitors = $monitors
        remote   = $remote
    }
}

function Show-RSMessage {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [string]$Title = 'Session Recovery',
        [string]$Icon = 'Information'
    )
    try {
        [void][System.Windows.Forms.MessageBox]::Show($Text, $Title, [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]$Icon)
    } catch {
        Write-Host $Text
    }
}

function Add-RSListItem {
    param(
        [Parameter(Mandatory = $true)]$List,
        [Parameter(Mandatory = $true)][string]$Kind,
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Details,
        $Value,
        [string]$IconPath,
        [int]$IconIndex = -1
    )
    $item = New-Object System.Windows.Forms.ListViewItem($Name)
    [void]$item.SubItems.Add($Details)
    $item.Tag = [pscustomobject]@{ Kind = $Kind; Value = $Value }
    $item.Checked = $true
    if ($IconIndex -lt 0) {
        $IconIndex = Get-RSImageIndex -Path $IconPath
    }
    if ($IconIndex -ge 0 -and $null -ne $script:rsRowImages) {
        $item.ImageIndex = $IconIndex
    }
    [void]$List.Items.Add($item)
}

function New-RSFolderIconBitmap {
    $bitmap = New-Object System.Drawing.Bitmap(20, 20)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    # Accent colour comes from the active Studio theme when it is loaded.
    $folderColor = [System.Drawing.Color]::FromArgb(41, 79, 130)
    if ($null -ne $script:rsP -and $script:rsP.ContainsKey('Accent')) { $folderColor = [System.Drawing.Color]$script:rsP.Accent }
    $darkBrush = New-Object System.Drawing.SolidBrush($folderColor)
    $lightBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(226, 234, 244))
    $pen = New-Object System.Drawing.Pen($folderColor, 1)
    try {
        $graphics.Clear([System.Drawing.Color]::Transparent)
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $graphics.FillRectangle($darkBrush, 2, 5, 16, 12)
        $graphics.FillRectangle($darkBrush, 3, 3, 7, 4)
        $graphics.FillRectangle($lightBrush, 3, 7, 14, 9)
        $graphics.DrawLine($pen, 3, 7, 17, 7)
    } finally {
        $darkBrush.Dispose()
        $lightBrush.Dispose()
        $pen.Dispose()
        $graphics.Dispose()
    }
    return $bitmap
}

function Get-RSImageIndex {
    param([string]$Path)
    if ($null -eq $script:rsRowImages) { return -1 }
    if ([string]::IsNullOrWhiteSpace($Path)) { return 0 }
    $key = $Path.ToLowerInvariant()
    if ($script:rsIconCache.ContainsKey($key)) { return [int]$script:rsIconCache[$key] }

    $index = 0
    try {
        if (Test-Path -LiteralPath $Path) {
            $icon = [System.Drawing.Icon]::ExtractAssociatedIcon($Path)
            if ($null -ne $icon) {
                $source = $icon.ToBitmap()
                $scaled = New-Object System.Drawing.Bitmap(20, 20)
                $graphics = [System.Drawing.Graphics]::FromImage($scaled)
                try {
                    $graphics.Clear([System.Drawing.Color]::Transparent)
                    $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                    $graphics.DrawImage($source, 0, 0, 20, 20)
                    $index = $script:rsRowImages.Images.Add($scaled)
                } finally {
                    $graphics.Dispose()
                    $source.Dispose()
                    $icon.Dispose()
                }
            }
        }
    } catch {
        $index = 0
    }
    $script:rsIconCache[$key] = $index
    return $index
}

function Format-RSMediaClock {
    param([double]$Seconds)
    if ($Seconds -lt 0) { return '' }
    $total = [int][Math]::Floor($Seconds)
    $hours = [int][Math]::Floor($total / 3600)
    $minutes = [int][Math]::Floor(($total % 3600) / 60)
    $seconds = $total % 60
    if ($hours -gt 0) { return ('{0}:{1:00}:{2:00}' -f $hours, $minutes, $seconds) }
    return ('{0}:{1:00}' -f $minutes, $seconds)
}

function Populate-RSList {
    param(
        [Parameter(Mandatory = $true)]$List,
        [Parameter(Mandatory = $true)]$Snapshot
    )

    $List.BeginUpdate()
    try {
        $List.Items.Clear()

        foreach ($app in @($Snapshot.apps)) {
            if ($null -eq $app) { continue }
            $name = [string]$app.name
            if ([string]::IsNullOrWhiteSpace($name)) { $name = Split-Path -Leaf ([string]$app.exe) }
            $mediaProperty = $app.PSObject.Properties['media']
            if ($null -ne $mediaProperty -and $null -ne $mediaProperty.Value) {
                $media = $mediaProperty.Value
                $mediaTitle = Split-Path -Leaf ([string]$media.file)
                $clock = Format-RSMediaClock -Seconds ([double]$media.positionSeconds)
                $details = ('Playing {0} at {1}' -f $mediaTitle, $clock)
                Add-RSListItem -List $List -Kind 'app' -Name $name -Details $details -Value $app -IconPath ([string]$app.exe)
                continue
            }
            $titles = @($app.windows | ForEach-Object { [string]$_.title } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            $details = 'Application'
            if ($titles.Count -gt 0) {
                $details = $titles[0]
                if ($titles.Count -gt 1) { $details += (' (+{0} more window(s))' -f ($titles.Count - 1)) }
            }
            Add-RSListItem -List $List -Kind 'app' -Name $name -Details $details -Value $app -IconPath ([string]$app.exe)
        }

        foreach ($folder in @($Snapshot.explorer)) {
            if ([string]::IsNullOrWhiteSpace([string]$folder)) { continue }
            Add-RSListItem -List $List -Kind 'folder' -Name ([string]$folder) -Details 'File Explorer folder' -Value ([string]$folder) -IconIndex 1
        }

        foreach ($browser in @($Snapshot.browsers)) {
            if ($null -eq $browser) { continue }
            $profileParts = New-Object System.Collections.Generic.List[string]
            foreach ($profile in @($browser.profiles)) {
                $profileName = [string]$profile.displayName
                if ([string]::IsNullOrWhiteSpace($profileName)) { $profileName = [string]$profile.directory }
                $profileParts.Add(('{0}: {1} tab(s)' -f $profileName, @($profile.tabs).Count))
            }
            $details = ('{0} window(s)' -f @($browser.windows).Count)
            if ($profileParts.Count -gt 0) { $details += '; ' + ($profileParts -join '; ') }
            Add-RSListItem -List $List -Kind 'browser' -Name ([string]$browser.name) -Details $details -Value $browser -IconPath ([string]$browser.exe)
        }

        # Remote sessions: PuTTY and Remote Desktop targets captured open.
        $remoteProperty = $Snapshot.PSObject.Properties['remote']
        if ($null -ne $remoteProperty) {
            foreach ($session in @($remoteProperty.Value)) {
                if ($null -eq $session) { continue }
                if ([string]$session.kind -eq 'putty') {
                    Add-RSListItem -List $List -Kind 'remote' -Name ('PuTTY: ' + [string]$session.session) -Details 'SSH session (reconnects with -load)' -Value $session -IconIndex 0
                } elseif ([string]$session.kind -eq 'rdp') {
                    Add-RSListItem -List $List -Kind 'remote' -Name ('Remote Desktop: ' + [string]$session.target) -Details 'Remote Desktop window' -Value $session -IconIndex 0
                }
            }
        }
    } finally {
        $List.EndUpdate()
    }
}

# ---------------------------------------------------------------------------
# Select the snapshot
# ---------------------------------------------------------------------------

$config = Get-SRConfig
if (-not $PSBoundParameters.ContainsKey('TabMode')) {
    $TabMode = [string]$config.defaultTabMode
    if ([string]::IsNullOrWhiteSpace($TabMode)) { $TabMode = 'Smart' }
}
if ($MaxAgeHours -le 0) { $MaxAgeHours = [int]$config.maxRestoreAgeHours }
if ($MaxAgeHours -le 0) { $MaxAgeHours = 72 }

$logonTime = Get-SRLogonTime
$now = Get-Date
$snapshotEntries = New-Object System.Collections.Generic.List[object]

if (-not [string]::IsNullOrWhiteSpace($SnapshotPath)) {
    $snapshot = Get-SRSnapshotByPath -Path $SnapshotPath
    $capturedAt = [DateTimeOffset]::Parse([string]$snapshot.capturedAt, [System.Globalization.CultureInfo]::InvariantCulture).LocalDateTime
    $snapshotEntries.Add([pscustomobject]@{
        Path       = (Resolve-Path -LiteralPath $SnapshotPath).Path
        CapturedAt = $capturedAt
        Snapshot   = $snapshot
    })
} else {
    $allSnapshots = @(Get-SRSnapshots)
    if ($Manual -or $ListSnapshots) {
        foreach ($entry in $allSnapshots) { $snapshotEntries.Add($entry) }
    } else {
        $cutoff = $now.AddHours(-1 * [Math]::Abs($MaxAgeHours))
        foreach ($entry in $allSnapshots) {
            if ($entry.CapturedAt -ge $logonTime.AddSeconds(-2)) { continue }
            if ($entry.CapturedAt -lt $cutoff) { continue }
            $snapshotEntries.Add($entry)
        }
    }
}

if ($ListSnapshots) {
    if ($snapshotEntries.Count -eq 0) {
        Write-Output 'No snapshots found.'
        exit 0
    }
    foreach ($entry in $snapshotEntries) {
        $stats = Get-RSStats -Snapshot $entry.Snapshot
        Write-Output ([pscustomobject]@{
            CapturedAt = $entry.CapturedAt
            AgeMinutes = [Math]::Round(((Get-Date) - $entry.CapturedAt).TotalMinutes, 1)
            Apps       = $stats.Apps
            Folders    = $stats.Folders
            Browsers   = $stats.Browsers
            Tabs       = $stats.Tabs
            Path       = $entry.Path
        })
    }
    exit 0
}

if ($snapshotEntries.Count -eq 0) {
    $message = if ($Manual) {
        'No saved sessions were found. A snapshot is taken automatically every few minutes while the tool is installed.'
    } else {
        'No recent saved session was available to restore.'
    }
    Write-SRLog -Level WARN -Message $message
    if ($Manual -and -not $NoUI -and -not $DryRun) {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        Show-RSMessage -Text $message -Icon 'Information'
    } elseif ($DryRun) {
        Write-Output $message
    }
    exit 0
}

# ---------------------------------------------------------------------------
# Decide whether this logon should prompt at all
# ---------------------------------------------------------------------------

if (-not $Manual -and -not $NoUI -and -not $DryRun) {
    $promptMode = [string]$config.promptOnLogon
    if ($promptMode -eq 'Never') {
        Write-SRLog -Message 'Restore prompt skipped because promptOnLogon is Never.'
        exit 0
    }
    if ($promptMode -eq 'CrashOnly') {
        $crashed = Test-SRUnexpectedShutdown
        if ($crashed -eq $false) {
            Write-SRLog -Message 'Restore prompt skipped: the last shutdown was clean.'
            exit 0
        }
        if ($null -eq $crashed) {
            Write-SRLog -Level WARN -Message 'Could not determine the last shutdown type; showing the restore prompt.'
        }
    }
}

$entry = $snapshotEntries[0]

# Honor the optional master switch for browser restore. Removing the browser
# entries here keeps the preview, the interactive list and the plan consistent.
$restoreBrowsers = $true
$restoreBrowsersProperty = $config.PSObject.Properties['restoreBrowsers']
if ($null -ne $restoreBrowsersProperty) {
    $restoreBrowsers = [bool]$restoreBrowsersProperty.Value
}
if (-not $restoreBrowsers) {
    foreach ($snapshotEntry in $snapshotEntries) {
        $browsersProperty = $snapshotEntry.Snapshot.PSObject.Properties['browsers']
        if ($null -ne $browsersProperty) {
            $snapshotEntry.Snapshot.browsers = @()
        }
    }
}

$planAll = New-SRRestorePlan -Snapshot $entry.Snapshot -All -TabMode $TabMode

$hasFilters = [bool]($IncludeApps -or $IncludeFolders -or $IncludeBrowsers -or
    $ExcludeApps -or $ExcludeFolders -or $ExcludeBrowsers)
if ($hasFilters) {
    if (-not $NoUI -and -not $DryRun) {
        Write-Warning 'Include/exclude filters apply to -NoUI and -DryRun. The restore window uses its checkboxes instead.'
    }
    $planAll = Select-RSPlan -Plan $planAll `
        -IncludeApps $IncludeApps -IncludeFolders $IncludeFolders -IncludeBrowsers $IncludeBrowsers `
        -ExcludeApps $ExcludeApps -ExcludeFolders $ExcludeFolders -ExcludeBrowsers $ExcludeBrowsers
}

if ($DryRun) {
    $stats = Get-RSPlanStats -Plan $planAll
    Write-Output ('Snapshot: {0}' -f $entry.Path)
    if (Test-SRImportedSnapshot -Snapshot $entry.Snapshot) { Write-Output 'Imported: yes' }
    Write-Output ('Captured: {0} ({1})' -f $entry.CapturedAt.ToString('g'), (Format-RSAge -CapturedAt $entry.CapturedAt))
    Write-Output ('Contents: {0} app(s), {1} folder(s), {2} browser(s), {3} tab(s)' -f $stats.Apps, $stats.Folders, $stats.Browsers, $stats.Tabs)
    Write-Output ('Tab mode: {0}' -f $TabMode)
    try {
        $preview = Get-SRRestorePreview -Plan $planAll
        Write-Output ('Preview: {0} already running, {1} will start, {2} missing' -f $preview.Running, $preview.WillStart, $preview.Missing)
    } catch { }
    foreach ($app in @($planAll.apps)) { Write-Output ('APP    {0}  [{1}]' -f $app.name, $app.exe) }
    foreach ($folder in @($planAll.explorer)) { Write-Output ('FOLDER {0}' -f $folder) }
    foreach ($browser in @($planAll.browsers)) {
        foreach ($profile in @($browser.profiles)) {
            Write-Output ('TABS   {0} / {1}: {2}' -f $browser.name, $profile.displayName, @($profile.tabs).Count)
        }
    }
    foreach ($workspace in @($planAll.dev)) {
        if ($null -eq $workspace) { continue }
        foreach ($folder in @($workspace.folders)) { Write-Output ('DEV    {0}: {1}' -f $workspace.tool, $folder) }
    }
    foreach ($session in @($planAll.remote)) {
        if ($null -eq $session) { continue }
        if ([string]$session.kind -eq 'putty') { Write-Output ('REMOTE PuTTY {0}' -f $session.session) }
        elseif ([string]$session.kind -eq 'rdp') { Write-Output ('REMOTE RDP   {0}' -f $session.target) }
    }
    exit 0
}

# ---------------------------------------------------------------------------
# Non-interactive restore
# ---------------------------------------------------------------------------

if ($NoUI -or -not [Environment]::UserInteractive) {
    if (@($planAll.apps).Count -eq 0 -and @($planAll.explorer).Count -eq 0 -and @($planAll.browsers).Count -eq 0) {
        $emptyMessage = 'No items matched the include/exclude filters or browser settings.'
        Write-SRLog -Level WARN -Message $emptyMessage
        Write-Output $emptyMessage
        exit 0
    }
    if ((Test-SRImportedSnapshot -Snapshot $entry.Snapshot) -and -not $AllowImportedSnapshot) {
        $message = (T 'RstImportedHeadless' 'This imported snapshot needs interactive confirmation. Run the restore without -NoUI to review its programs, or pass -AllowImportedSnapshot to confirm.')
        Write-SRLog -Level WARN -Message $message
        Write-Error $message
        exit 1
    }
    if (Test-SRImportedSnapshot -Snapshot $entry.Snapshot) {
        # The caller explicitly confirmed. Log every program and whether the
        # restore-time validator will accept it, so an unattended launch of an
        # imported file stays auditable.
        foreach ($app in @($planAll.apps)) {
            $check = Test-SRRestoreExecutable -Path ([string]$app.exe)
            $level = if ($check.Ok) { 'INFO' } else { 'WARN' }
            $detail = if ($check.Ok) { 'allowed' } else { [string]$check.Reason }
            Write-SRLog -Level $level -Message ('Imported snapshot program {0}: {1}' -f [string]$app.exe, $detail)
        }
    }
    Write-SRLog -Message ('Non-interactive restore started from {0} (tab mode {1}).' -f $entry.Path, $TabMode)
    try {
        $results = Invoke-SRRestore -Plan $planAll -Force:$Force
        foreach ($result in @($results)) {
            $level = if ($result.Started) { 'INFO' } else { 'WARN' }
            Write-SRLog -Level $level -Message ([string]$result.Message)
            Write-Output ([string]$result.Message)
        }
    } catch {
        Write-SRLog -Level ERROR -Message "Non-interactive restore failed: $($_.Exception.Message)"
        Write-Error "Restore failed: $($_.Exception.Message)"
        exit 1
    }
    exit 0
}

# ---------------------------------------------------------------------------
# Restore UI
# ---------------------------------------------------------------------------

if ($StartupDelaySeconds -gt 0) {
    # Started from the Startup folder: give Explorer and startup apps a moment
    # to settle before showing the prompt.
    Start-Sleep -Seconds $StartupDelaySeconds
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# The restore window uses the same controls and colour themes as the Studio,
# so it follows the theme chosen in Settings and looks like part of the app.
$controlsPath = Join-Path $PSScriptRoot 'StudioControls.cs'
if (-not (Test-Path -LiteralPath $controlsPath)) {
    $controlsPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'src\StudioControls.cs'
}
$themePath = Join-Path $PSScriptRoot 'StudioTheme.ps1'
if (-not (Test-Path -LiteralPath $themePath)) {
    $themePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'src\StudioTheme.ps1'
}
if (-not (Test-Path -LiteralPath $controlsPath) -or -not (Test-Path -LiteralPath $themePath)) {
    Show-RSMessage -Text 'StudioControls.cs or StudioTheme.ps1 is missing. Reinstall Session Recovery.' -Icon 'Error'
    exit 2
}
if (-not ('SessionRecovery.Studio.StudioProgress' -as [type])) {
    Add-Type -Path $controlsPath -ReferencedAssemblies 'System.Windows.Forms', 'System.Drawing'
}
. $themePath

# Dark scroll bars and check boxes for the native list view.
if (-not ('SessionRecovery.RestoreNative' -as [type])) {
    try {
        Add-Type -Namespace SessionRecovery -Name RestoreNative -MemberDefinition '[System.Runtime.InteropServices.DllImport("uxtheme.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)] public static extern int SetWindowTheme(System.IntPtr hWnd, string pszSubAppName, string pszSubIdList);'
    } catch { }
}

$rsThemeName = 'Aurora'
try {
    $rsThemeProperty = $config.PSObject.Properties['theme']
    if ($null -ne $rsThemeProperty -and -not [string]::IsNullOrWhiteSpace([string]$rsThemeProperty.Value)) {
        $rsThemeName = [string]$rsThemeProperty.Value
    }
} catch { }
$rsThemeKey = Resolve-StudioThemeKey -Theme $rsThemeName
$script:rsP = Get-StudioPalette -Theme $rsThemeKey
$rsThemeDark = $true
try { $rsThemeDark = [bool]((Get-StudioThemeCatalog)[$rsThemeKey].Dark) } catch { }

$script:rsFontBody = New-Object System.Drawing.Font('Segoe UI', 9)
$script:rsFontSmall = New-Object System.Drawing.Font('Segoe UI', 8.25)
$script:rsFontSemibold = New-Object System.Drawing.Font('Segoe UI Semibold', 9.5)
$script:rsFontMono = New-Object System.Drawing.Font('Consolas', 8.25)

function New-RSLabel {
    param(
        [string]$Text = '',
        [int]$X = 0,
        [int]$Y = 0,
        [int]$Width = 200,
        [int]$Height = 20,
        $Font = $null,
        $Color = $null,
        [string]$Align = 'MiddleLeft'
    )
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.Location = New-Object System.Drawing.Point($X, $Y)
    $label.Size = New-Object System.Drawing.Size($Width, $Height)
    $label.Font = if ($null -ne $Font) { $Font } else { $script:rsFontBody }
    $label.ForeColor = if ($null -ne $Color) { $Color } else { $script:rsP.Text }
    $label.BackColor = [System.Drawing.Color]::Transparent
    $label.TextAlign = [System.Drawing.ContentAlignment]$Align
    $label.AutoSize = $false
    $label.AutoEllipsis = $true
    $label.UseMnemonic = $false
    return $label
}

function New-RSCard {
    param(
        [int]$X = 0,
        [int]$Y = 0,
        [int]$Width = 300,
        [int]$Height = 120,
        $Fill = $null,
        $Border = $null,
        $Canvas = $null,
        [int]$Radius = 14
    )
    $card = New-Object SessionRecovery.Studio.StudioCard
    $card.Location = New-Object System.Drawing.Point($X, $Y)
    $card.Size = New-Object System.Drawing.Size($Width, $Height)
    $card.FillColor = if ($null -ne $Fill) { $Fill } else { $script:rsP.Card }
    $card.BorderColor = if ($null -ne $Border) { $Border } else { $script:rsP.Border }
    $card.CanvasColor = if ($null -ne $Canvas) { $Canvas } else { $script:rsP.Bg }
    $card.CornerRadius = $Radius
    return $card
}

function New-RSButton {
    param(
        [string]$Text = '',
        [int]$Width = 120,
        [int]$Height = 40,
        [switch]$Primary,
        [string]$Glyph = ''
    )
    $button = New-Object SessionRecovery.Studio.StudioButton
    $button.Text = $Text
    $button.Size = New-Object System.Drawing.Size($Width, $Height)
    $button.CornerRadius = 9
    $button.Glyph = $Glyph
    $button.DisabledFillColor = $script:rsP.DisabledFill
    $button.DisabledTextColor = $script:rsP.DisabledText
    if ($Primary) {
        $button.FillColor = $script:rsP.Accent
        $button.GradientEndColor = $script:rsP.Accent2
        $button.HoverColor = $script:rsP.AccentHover
        $button.PressedColor = $script:rsP.AccentPressed
        $button.TextColor = $script:rsP.AccentText
        $button.OutlineColor = [System.Drawing.Color]::Empty
    } else {
        $button.FillColor = $script:rsP.CardAlt
        $button.GradientEndColor = [System.Drawing.Color]::Empty
        $button.HoverColor = $script:rsP.CardHover
        $button.PressedColor = $script:rsP.Pressed
        $button.TextColor = $script:rsP.Text
        $button.OutlineColor = $script:rsP.Border
    }
    return $button
}

function New-RSToggle {
    param([int]$X = 0, [int]$Y = 0, [bool]$Checked = $false)
    $toggle = New-Object SessionRecovery.Studio.StudioToggle
    $toggle.Location = New-Object System.Drawing.Point($X, $Y)
    $toggle.Checked = $Checked
    $toggle.OnColor = $script:rsP.Accent
    $toggle.OffColor = $script:rsP.ToggleOff
    return $toggle
}

function New-RSCombo {
    param([int]$X = 0, [int]$Y = 0, [int]$Width = 200)
    $combo = New-Object SessionRecovery.Studio.StudioComboBox
    $combo.Location = New-Object System.Drawing.Point($X, $Y)
    $combo.Size = New-Object System.Drawing.Size($Width, 28)
    $combo.BackColor = $script:rsP.CardAlt
    $combo.ForeColor = $script:rsP.Text
    $combo.SelectionBackColor = $script:rsP.ComboSelection
    return $combo
}

function New-RSRule {
    param([int]$X, [int]$Y, [int]$Width)
    $rule = New-Object System.Windows.Forms.Panel
    $rule.Location = New-Object System.Drawing.Point($X, $Y)
    $rule.Size = New-Object System.Drawing.Size($Width, 1)
    $rule.BackColor = $script:rsP.BorderSoft
    return $rule
}

$script:rsSnapshotEntries = $snapshotEntries
$script:rsUpdating = $false
$script:rsRestoring = $false

# A plain-language crash reason replaces guesswork in the header.
$rsCrash = $false
$rsCrashText = ''
try {
    $shutdownInfo = Get-SRLastShutdownReason
    if ([string]$shutdownInfo.Kind -eq 'crash' -and -not [string]::IsNullOrWhiteSpace([string]$shutdownInfo.Reason)) {
        $rsCrash = $true
        $reasonText = Format-SRShutdownReason -Shutdown $shutdownInfo -Strings $script:RestoreStrings
        $rsCrashText = ((T 'RstShutdownReason' 'Windows stopped unexpectedly: {0}') -f $reasonText)
    }
} catch { }

$rsVersion = ''
try {
    $rsHostExe = @(
        (Join-Path $PSScriptRoot 'SessionRecovery.exe'),
        (Join-Path (Split-Path $PSScriptRoot -Parent) 'dist\SessionRecovery.exe')
    ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if ($rsHostExe) {
        $rsVersionMatch = [regex]::Match([string](Get-Item -LiteralPath $rsHostExe).VersionInfo.FileVersion, '^\d+\.\d+\.\d+')
        if ($rsVersionMatch.Success) { $rsVersion = $rsVersionMatch.Value }
    }
} catch { }

$anchorTL = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left
$anchorTLR = $anchorTL -bor [System.Windows.Forms.AnchorStyles]::Right
$anchorTR = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$anchorBL = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
$anchorBLR = $anchorBL -bor [System.Windows.Forms.AnchorStyles]::Right
$anchorBR = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
$anchorAll = $anchorTLR -bor [System.Windows.Forms.AnchorStyles]::Bottom

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Session Recovery'
$form.ClientSize = New-Object System.Drawing.Size(1020, 700)
$form.MinimumSize = New-Object System.Drawing.Size(940, 640)
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.Font = $script:rsFontBody
$form.BackColor = $script:rsP.Bg
$form.ShowInTaskbar = $true

$iconPath = Join-Path $PSScriptRoot 'SessionRecovery.ico'
if (-not (Test-Path -LiteralPath $iconPath)) {
    $fallbackIconPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'assets\SessionRecovery.ico'
    if (Test-Path -LiteralPath $fallbackIconPath) { $iconPath = $fallbackIconPath } else { $iconPath = $null }
}
$brandImage = $null
if ($iconPath) {
    try {
        $form.Icon = New-Object System.Drawing.Icon($iconPath)
        $brandImage = $form.Icon.ToBitmap()
    } catch {
        $form.Icon = $null
    }
}

# Right-to-left languages get correctly shaped, right-aligned text. Layout
# mirroring is intentionally not used: it scrambles custom-painted controls.
try {
    if (Test-SRRtlLanguage -Language $restoreLanguage) {
        $form.RightToLeft = [System.Windows.Forms.RightToLeft]::Yes
    }
} catch { }

# ---- Sidebar (same structure as the Studio sidebar) ------------------------

$sidebar = New-Object System.Windows.Forms.Panel
$sidebar.Location = New-Object System.Drawing.Point(0, 0)
$sidebar.Size = New-Object System.Drawing.Size(236, 700)
$sidebar.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
$sidebar.BackColor = $script:rsP.Sidebar
$form.Controls.Add($sidebar)

$brandPic = New-Object System.Windows.Forms.PictureBox
$brandPic.Location = New-Object System.Drawing.Point(22, 24)
$brandPic.Size = New-Object System.Drawing.Size(38, 38)
$brandPic.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
$brandPic.BackColor = [System.Drawing.Color]::Transparent
if ($brandImage) { $brandPic.Image = $brandImage } else { $brandPic.Visible = $false }
$sidebar.Controls.Add($brandPic)

$brandName = New-RSLabel -Text (T 'BrandSession' 'Session') -X 70 -Y 23 -Width 150 -Height 24 -Font (New-Object System.Drawing.Font('Segoe UI Semibold', 13))
$sidebar.Controls.Add($brandName)
$brandSub = New-RSLabel -Text (T 'BrandRecoveryRestore' 'RECOVERY  /  RESTORE') -X 72 -Y 45 -Width 162 -Height 16 -Font $script:rsFontMono -Color $script:rsP.Subtle
$sidebar.Controls.Add($brandSub)

$sideCard = New-RSCard -X 14 -Y 84 -Width 208 -Height 206 -Fill $script:rsP.CardAlt -Border $script:rsP.BorderSoft -Canvas $script:rsP.Sidebar -Radius 12
$sidebar.Controls.Add($sideCard)

$sideBadge = New-Object SessionRecovery.Studio.StudioBadge
$sideBadge.Size = New-Object System.Drawing.Size(120, 22)
$sideBadge.Location = New-Object System.Drawing.Point(14, 13)
$sideCard.Controls.Add($sideBadge)
if ($rsCrash) {
    $sideBadge.FillColor = $script:rsP.AmberSoft
    $sideBadge.TextColor = $script:rsP.Amber
    $sideBadge.Text = (T 'BadgeAttention' 'ATTENTION')
} else {
    $sideBadge.FillColor = $script:rsP.GreenSoft
    $sideBadge.TextColor = $script:rsP.Green
    $sideBadge.Text = (T 'BadgeReady' 'READY TO RESTORE')
}

$sideTitle = New-RSLabel -Text 'CAPTURED' -X 14 -Y 44 -Width 180 -Height 16 -Font $script:rsFontMono -Color $script:rsP.Subtle
$sideCard.Controls.Add($sideTitle)
$ageLabel = New-RSLabel -Text '' -X 14 -Y 61 -Width 182 -Height 24 -Font (New-Object System.Drawing.Font('Segoe UI Semibold', 11)) -Color $script:rsP.Text
$sideCard.Controls.Add($ageLabel)
$sideCard.Controls.Add((New-RSRule -X 14 -Y 94 -Width 180))

$statTexts = @(
    (T 'RstApps' 'Applications'),
    (T 'RstFolders' 'Folders'),
    (T 'RstBrowsers' 'Browsers'),
    (T 'RstBrowserTabs' 'Browser tabs')
)
$statValueLabels = @()
for ($statIndex = 0; $statIndex -lt $statTexts.Count; $statIndex++) {
    $statY = 104 + (24 * $statIndex)
    $sideCard.Controls.Add((New-RSLabel -Text $statTexts[$statIndex] -X 14 -Y $statY -Width 120 -Height 20 -Font $script:rsFontSmall -Color $script:rsP.Muted))
    $valueLabel = New-RSLabel -Text '0' -X 136 -Y $statY -Width 58 -Height 20 -Font $script:rsFontSemibold -Color $script:rsP.Text -Align 'MiddleRight'
    $sideCard.Controls.Add($valueLabel)
    $statValueLabels += $valueLabel
}
$statApps = $statValueLabels[0]
$statFolders = $statValueLabels[1]
$statBrowsers = $statValueLabels[2]
$statTabs = $statValueLabels[3]

$sideVersionText = (T 'BadgeLocalOnly' 'LOCAL ONLY')
if (-not [string]::IsNullOrWhiteSpace($rsVersion)) { $sideVersionText = ('RESTORE {0}  /  {1}' -f $rsVersion, $sideVersionText) }
$sideVersion = New-RSLabel -Text $sideVersionText -X 14 -Y 664 -Width 208 -Height 16 -Font $script:rsFontMono -Color $script:rsP.Subtle -Align 'MiddleCenter'
$sideVersion.Anchor = $anchorBLR
$sidebar.Controls.Add($sideVersion)

# ---- Main area ------------------------------------------------------------

$main = New-Object System.Windows.Forms.Panel
$main.Location = New-Object System.Drawing.Point(236, 0)
$main.Size = New-Object System.Drawing.Size(784, 700)
$main.Anchor = $anchorAll
$main.BackColor = $script:rsP.Bg
$form.Controls.Add($main)

$titleLabel = New-RSLabel -Text (T 'RstTitle' 'Restore your previous session') -X 32 -Y 22 -Width 720 -Height 36 -Font (New-Object System.Drawing.Font('Segoe UI Semibold', 19))
$titleLabel.Anchor = $anchorTLR
$main.Controls.Add($titleLabel)

$subtitleLabel = New-RSLabel -Text (T 'RstSubtitle' 'Choose what to reopen. Everything stays on this PC.') -X 34 -Y 60 -Width 718 -Height 20 -Font (New-Object System.Drawing.Font('Segoe UI', 9.5)) -Color $script:rsP.Muted
if ($rsCrash) {
    $subtitleLabel.Text = $rsCrashText
    $subtitleLabel.ForeColor = $script:rsP.Red
}
$subtitleLabel.Anchor = $anchorTLR
$main.Controls.Add($subtitleLabel)

$snapshotCard = New-RSCard -X 32 -Y 94 -Width 720 -Height 78
$snapshotCard.Anchor = $anchorTLR
$main.Controls.Add($snapshotCard)
$snapshotCard.Controls.Add((New-RSLabel -Text 'SNAPSHOT' -X 18 -Y 11 -Width 200 -Height 16 -Font $script:rsFontMono -Color $script:rsP.Subtle))

$snapshotCombo = New-RSCombo -X 18 -Y 34 -Width 684
$snapshotCombo.Anchor = $anchorTLR
$snapshotCard.Controls.Add($snapshotCombo)

$listCard = New-RSCard -X 32 -Y 186 -Width 720 -Height 320
$listCard.Anchor = $anchorAll
$main.Controls.Add($listCard)

$listHeading = New-RSLabel -Text (T 'RstItems' 'ITEMS TO REOPEN') -X 18 -Y 14 -Width 400 -Height 18 -Font $script:rsFontMono -Color $script:rsP.Subtle
$listCard.Controls.Add($listHeading)

$selectAll = New-RSToggle -X 656 -Y 9 -Checked $true
$selectAll.Anchor = $anchorTR
$listCard.Controls.Add($selectAll)
$selectAllLabel = New-RSLabel -Text (T 'RstSelectAll' 'Select all') -X 536 -Y 11 -Width 114 -Height 22 -Font $script:rsFontBody -Color $script:rsP.Text -Align 'MiddleRight'
$selectAllLabel.Anchor = $anchorTR
$listCard.Controls.Add($selectAllLabel)

$listRule = New-RSRule -X 18 -Y 44 -Width 684
$listRule.Anchor = $anchorTLR
$listCard.Controls.Add($listRule)

$itemHeader = New-RSLabel -Text 'ITEM' -X 18 -Y 52 -Width 160 -Height 16 -Font $script:rsFontMono -Color $script:rsP.Subtle
$listCard.Controls.Add($itemHeader)
$detailsHeader = New-RSLabel -Text (T 'RstDetails' 'DETAILS') -X 270 -Y 52 -Width 200 -Height 16 -Font $script:rsFontMono -Color $script:rsP.Subtle
$listCard.Controls.Add($detailsHeader)

$list = New-Object System.Windows.Forms.ListView
$list.View = [System.Windows.Forms.View]::Details
$list.CheckBoxes = $true
$list.FullRowSelect = $true
$list.GridLines = $false
$list.HeaderStyle = [System.Windows.Forms.ColumnHeaderStyle]::None
$list.HideSelection = $false
$list.MultiSelect = $true
$list.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$list.BackColor = $script:rsP.Card
$list.ForeColor = $script:rsP.Text
$list.Font = New-Object System.Drawing.Font('Segoe UI', 9.25)
$list.Location = New-Object System.Drawing.Point(18, 74)
$list.Size = New-Object System.Drawing.Size(684, 232)
$list.Anchor = $anchorAll
$rowImages = New-Object System.Windows.Forms.ImageList
$rowImages.ImageSize = New-Object System.Drawing.Size(20, 20)
$rowImages.ColorDepth = [System.Windows.Forms.ColorDepth]::Depth32Bit
$rowImages.TransparentColor = [System.Drawing.Color]::Transparent
[void]$rowImages.Images.Add((New-Object System.Drawing.Bitmap(20, 20)))
[void]$rowImages.Images.Add((New-RSFolderIconBitmap))
$list.SmallImageList = $rowImages
$script:rsRowImages = $rowImages
$script:rsIconCache = @{}
[void]$list.Columns.Add('Item', 250)
[void]$list.Columns.Add('Details', 420)
$list.Add_Resize({
    if ($list.Columns.Count -lt 2) { return }
    $available = [Math]::Max(300, $list.ClientSize.Width)
    $first = [int]($available * 0.36)
    $list.Columns[0].Width = $first
    $list.Columns[1].Width = [Math]::Max(140, $available - $first - 4)
    $detailsHeader.Left = $list.Left + $first
})
$list.Add_HandleCreated({
    try {
        $themeName = if ($rsThemeDark) { 'DarkMode_Explorer' } else { 'Explorer' }
        [void][SessionRecovery.RestoreNative]::SetWindowTheme($list.Handle, $themeName, $null)
    } catch { }
})
$listCard.Controls.Add($list)

$optionsCard = New-RSCard -X 32 -Y 520 -Width 720 -Height 100
$optionsCard.Anchor = $anchorBLR
$main.Controls.Add($optionsCard)

$optionsHeading = New-RSLabel -Text (T 'RstOptions' 'RESTORE OPTIONS') -X 18 -Y 12 -Width 400 -Height 18 -Font $script:rsFontMono -Color $script:rsP.Subtle
$optionsCard.Controls.Add($optionsHeading)

$tabModeLabel = New-RSLabel -Text (T 'RstBrowserTabs' 'Browser tabs') -X 18 -Y 40 -Width 110 -Height 24 -Font $script:rsFontBody -Color $script:rsP.Text
$optionsCard.Controls.Add($tabModeLabel)

$tabModeCombo = New-RSCombo -X 134 -Y 38 -Width 420
[void]$tabModeCombo.Items.Add('Smart - reopen captured tabs when available')
[void]$tabModeCombo.Items.Add('Captured tabs - reopen the exact tabs')
[void]$tabModeCombo.Items.Add('Browser session - use the browser''s own restore')
[void]$tabModeCombo.Items.Add('Do not reopen browsers or tabs')
switch ($TabMode) {
    'Captured' { $tabModeCombo.SelectedIndex = 1 }
    'Native' { $tabModeCombo.SelectedIndex = 2 }
    'None' { $tabModeCombo.SelectedIndex = 3 }
    default { $tabModeCombo.SelectedIndex = 0 }
}
$optionsCard.Controls.Add($tabModeCombo)

$forceCheck = New-RSToggle -X 14 -Y 66
$optionsCard.Controls.Add($forceCheck)
$forceLabel = New-RSLabel -Text (T 'RstStartAnyway' 'Start applications even when they are already running') -X 66 -Y 68 -Width 630 -Height 22 -Font $script:rsFontBody -Color $script:rsP.Text
$forceLabel.Anchor = $anchorTLR
$optionsCard.Controls.Add($forceLabel)

# ---- Footer: status, progress and actions --------------------------------

$statusLabel = New-RSLabel -Text '' -X 34 -Y 636 -Width 420 -Height 22 -Font $script:rsFontMono -Color $script:rsP.Muted
$statusLabel.Anchor = $anchorBL
$main.Controls.Add($statusLabel)

$progressBar = New-Object SessionRecovery.Studio.StudioProgress
$progressBar.Location = New-Object System.Drawing.Point(34, 664)
$progressBar.Size = New-Object System.Drawing.Size(420, 6)
$progressBar.Anchor = $anchorBL
$progressBar.TrackColor = $script:rsP.Border
$progressBar.FillColor = $script:rsP.Accent
$progressBar.FillEndColor = $script:rsP.Accent2
$progressBar.Visible = $false
$main.Controls.Add($progressBar)

$skipButton = New-RSButton -Text 'Skip' -Width 110 -Height 40
$skipButton.Location = New-Object System.Drawing.Point(460, 636)
$skipButton.Anchor = $anchorBR
$skipButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
$main.Controls.Add($skipButton)

$restoreButton = New-RSButton -Text (T 'RstRestoreSelected' 'Restore selected') -Width 170 -Height 40 -Primary -Glyph ([string][char]0xE777)
$restoreButton.Location = New-Object System.Drawing.Point(582, 636)
$restoreButton.Anchor = $anchorBR
$main.Controls.Add($restoreButton)

$form.AcceptButton = $restoreButton
$form.CancelButton = $skipButton
$form.Add_FormClosing({
    param($sender, $eventArgs)
    # The restore loop is synchronous but pumps messages from its progress
    # callback. Do not let the window be disposed underneath that loop.
    if ($script:rsRestoring) { $eventArgs.Cancel = $true }
})

function Update-RSSelection {
    param([int]$Index)
    if ($Index -lt 0 -or $Index -ge $script:rsSnapshotEntries.Count) { return }
    $script:rsUpdating = $true
    try {
        $selected = $script:rsSnapshotEntries[$Index]
        Populate-RSList -List $list -Snapshot $selected.Snapshot
        $ageLabel.Text = Format-RSAge -CapturedAt $selected.CapturedAt
        $stats = Get-RSStats -Snapshot $selected.Snapshot
        $statApps.Text = [string]$stats.Apps
        $statFolders.Text = [string]$stats.Folders
        $statBrowsers.Text = [string]$stats.Browsers
        $statTabs.Text = [string]$stats.Tabs
        $statusLabel.Text = ''
        $selectAll.Checked = $true
        # Restore preview: what is already running versus what would start.
        try {
            $preview = Get-SRRestorePreview -Plan (New-SRRestorePlan -Snapshot $selected.Snapshot -All -TabMode 'Smart')
            if ($preview.Running -gt 0) {
                $statusLabel.Text = ('{0} running, {1} to start' -f $preview.Running, $preview.WillStart)
            }
        } catch { }
    } finally {
        $script:rsUpdating = $false
    }
}

$script:rsUpdating = $true
foreach ($item in $script:rsSnapshotEntries) {
    [void]$snapshotCombo.Items.Add((Format-RSSnapshotLabel -Entry $item))
}
$snapshotCombo.SelectedIndex = 0
$script:rsUpdating = $false
Update-RSSelection -Index 0

$snapshotCombo.Add_SelectedIndexChanged({
    if (-not $script:rsUpdating) { Update-RSSelection -Index $snapshotCombo.SelectedIndex }
})

$selectAll.Add_CheckedChanged({
    if ($script:rsUpdating) { return }
    foreach ($item in $list.Items) { $item.Checked = $selectAll.Checked }
})

$form.Add_Shown({
    $form.Activate()
    $form.BringToFront()
    if ($restoreButton.Enabled) { [void]$restoreButton.Select() }
})

$restoreButton.Add_Click({
    $entry = $script:rsSnapshotEntries[$snapshotCombo.SelectedIndex]
    $selectedApps = New-Object System.Collections.Generic.List[object]
    $selectedFolders = New-Object System.Collections.Generic.List[string]
    $selectedBrowsers = New-Object System.Collections.Generic.List[object]
    $selectedRemote = New-Object System.Collections.Generic.List[object]

    foreach ($item in $list.CheckedItems) {
        $tag = $item.Tag
        if ($null -eq $tag) { continue }
        switch ([string]$tag.Kind) {
            'app' { $selectedApps.Add($tag.Value) }
            'folder' { $selectedFolders.Add([string]$tag.Value) }
            'browser' { $selectedBrowsers.Add($tag.Value) }
            'remote' { $selectedRemote.Add($tag.Value) }
        }
    }

    $mode = switch ($tabModeCombo.SelectedIndex) {
        1 { 'Captured' }
        2 { 'Native' }
        3 { 'None' }
        default { 'Smart' }
    }

    if ($selectedApps.Count -eq 0 -and $selectedFolders.Count -eq 0 -and
        $selectedBrowsers.Count -eq 0 -and $mode -eq 'None') {
        [void][System.Windows.Forms.MessageBox]::Show('Nothing is selected.', 'Session Recovery', 'OK', 'Information')
        return
    }

    # A snapshot is trusted only when its provenance carries this install's
    # ID. Imported files, hand-dropped files and files from another install
    # all fail that check, so show the exact program list before any process
    # starts.
    if (Test-SRImportedSnapshot -Snapshot $entry.Snapshot) {
        # Arguments are part of what the user is approving: a program with an
        # unexpected file must be visible in the list, not just its name and
        # path.
        $programLines = @($selectedApps | ForEach-Object {
            $line = '{0}  —  {1}' -f [string]$_.name, [string]$_.exe
            $argumentProperty = $_.PSObject.Properties['args']
            if ($null -ne $argumentProperty -and $null -ne $argumentProperty.Value) {
                $displayArguments = @(@($argumentProperty.Value) |
                    ForEach-Object { [string]$_ } |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                if ($displayArguments.Count -gt 0) {
                    $line = '{0}  —  {1}' -f $line, ($displayArguments -join ' ')
                }
            }
            $line
        })
        $programText = if ($programLines.Count -gt 0) {
            $programLines -join "`r`n"
        } else {
            (T 'RstImportedNoApps' 'No applications are selected.')
        }
        $confirmText = ((T 'RstImportedConfirmText' "This snapshot was not created by this installation (for example, it was imported from another PC). These programs will start:`r`n`r`n{0}`r`n`r`nOnly .exe programs on local fixed drives with safe arguments are launched. No program from a network share will run. Continue?") -f $programText)
        $confirmTitle = (T 'RstImportedConfirmTitle' 'Imported snapshot')
        $answer = [System.Windows.Forms.MessageBox]::Show(
            $confirmText,
            $confirmTitle,
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning,
            [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    }

    $plan = [pscustomobject]@{
        apps     = $selectedApps.ToArray()
        explorer = $selectedFolders.ToArray()
        browsers = $selectedBrowsers.ToArray()
        tabMode  = $mode
        dev      = @($entry.Snapshot.devWorkspaces)
        monitors = @($entry.Snapshot.monitors)
        remote   = $selectedRemote.ToArray()
    }

    $script:rsRestoring = $true
    $restoreButton.Enabled = $false
    $skipButton.Enabled = $false
    $snapshotCombo.Enabled = $false
    $selectAll.Enabled = $false
    $tabModeCombo.Enabled = $false
    $forceCheck.Enabled = $false
    $statusLabel.Text = (T 'RstPreparing' 'Preparing to restore...')
    $progressBar.Value = 0
    $progressBar.Visible = $true
    [System.Windows.Forms.Application]::DoEvents()

    $progressCallback = {
        param([int]$Step, [int]$StepTotal, [string]$Label)
        $statusLabel.Text = ('Restoring {0} of {1}: {2}' -f $Step, $StepTotal, $Label)
        if ($StepTotal -gt 0) {
            $progressBar.Value = [Math]::Min(100, [int](100 * $Step / $StepTotal))
        }
        [System.Windows.Forms.Application]::DoEvents()
    }

    $results = @()
    $failure = $null
    try {
        Write-SRLog -Message ('Interactive restore started from {0} (tab mode {1}).' -f $entry.Path, $mode)
        $results = @(Invoke-SRRestore -Plan $plan -Force:$forceCheck.Checked -Progress $progressCallback)
        foreach ($result in $results) {
            $level = if ($result.Started) { 'INFO' } else { 'WARN' }
            Write-SRLog -Level $level -Message ([string]$result.Message)
        }
    } catch {
        $failure = $_.Exception.Message
        Write-SRLog -Level ERROR -Message "Interactive restore failed: $failure"
    } finally {
        $script:rsRestoring = $false
    }

    # After a crash, point straight at the AutoRecover files Office kept.
    try {
        $shutdown = Get-SRLastShutdownReason
        if ([string]$shutdown.Kind -eq 'crash') {
            foreach ($officeFile in @(Get-SROfficeRecoveryFiles)) {
                $results += [pscustomobject]@{
                    Target  = ([string]$officeFile.file)
                    Started = $false
                    Message = ((T 'RstOfficeHint' 'Office left this AutoRecover file behind. Open it to recover unsaved work.') + '  [' + [string]$officeFile.app + ']')
                }
            }
        }
    } catch { }

    # Replace the checklist with the outcome of each item. The window stays
    # open so the summary is readable for as long as the user wants.
    $progressBar.Visible = $false
    $listHeading.Text = (T 'RstResults' 'RESTORE RESULTS')
    $selectAll.Visible = $false
    $selectAllLabel.Visible = $false
    $list.CheckBoxes = $false
    $list.BeginUpdate()
    try {
        $list.Items.Clear()
        foreach ($result in $results) {
            $target = [string]$result.Target
            if ([string]::IsNullOrWhiteSpace($target)) {
                $target = if ($null -ne $result.App) { [string]$result.App.name } else { 'Item' }
            }
            $mark = if ($result.Started) { [string][char]0x2713 } else { [string][char]0x2013 }
            $item = New-Object System.Windows.Forms.ListViewItem(('{0}  {1}' -f $mark, $target))
            [void]$item.SubItems.Add([string]$result.Message)
            $iconIndex = 0
            if ($null -ne $result.App -and -not [string]::IsNullOrWhiteSpace([string]$result.App.exe)) {
                $iconIndex = Get-RSImageIndex -Path ([string]$result.App.exe)
            }
            if ($iconIndex -ge 0 -and $null -ne $script:rsRowImages) { $item.ImageIndex = $iconIndex }
            [void]$list.Items.Add($item)
        }
        if ($results.Count -eq 0) {
            $item = New-Object System.Windows.Forms.ListViewItem('Nothing was restored.')
            [void]$item.SubItems.Add('No results were reported.')
            [void]$list.Items.Add($item)
        }
    } finally {
        $list.EndUpdate()
    }

    $started = @($results | Where-Object { $_.Started }).Count
    if ($failure) {
        $statusLabel.Text = ('Restore failed: {0}' -f $failure)
    } else {
        $statusLabel.Text = ('Restore finished  •  {0} started, {1} skipped' -f $started, ($results.Count - $started))
    }
    $skipButton.Text = 'Close'
    $skipButton.Enabled = $true
    $restoreButton.Visible = $false
    if (-not $failure) {
        $sideBadge.FillColor = $script:rsP.GreenSoft
        $sideBadge.TextColor = $script:rsP.Green
        $sideBadge.Text = (T 'BadgeRestored' 'RESTORED')
    }
})

$skipButton.Add_Click({
    Write-SRLog -Message 'Restore prompt was skipped by the user.'
    $form.Close()
})

if (-not [string]::IsNullOrWhiteSpace($RenderScreenshot)) {
    # Off-screen render for visual verification without a live user.
    $form.ShowInTaskbar = $false
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $form.Location = New-Object System.Drawing.Point(-4000, -4000)
    $form.Show()
    for ($pump = 0; $pump -lt 12; $pump++) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 40
    }
    $bitmap = New-Object System.Drawing.Bitmap($form.ClientSize.Width, $form.ClientSize.Height)
    $rect = New-Object System.Drawing.Rectangle(0, 0, $bitmap.Width, $bitmap.Height)
    $form.DrawToBitmap($bitmap, $rect)
    $bitmap.Save($RenderScreenshot, [System.Drawing.Imaging.ImageFormat]::Png)
    $bitmap.Dispose()
    $form.Close()
    $form.Dispose()
    exit 0
}

Write-SRLog -Message ('Restore prompt shown for {0}.' -f $entry.Path)
[void]$form.ShowDialog()
$form.Dispose()
exit 0
