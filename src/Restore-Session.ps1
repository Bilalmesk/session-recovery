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
    if ($delta.TotalMinutes -lt 1) { return (T 'JustNow' 'just now') }
    if ($delta.TotalMinutes -lt 60) { return ((T 'MinutesAgo' '{0} min ago') -f [int]$delta.TotalMinutes) }
    if ($delta.TotalHours -lt 24) { return ((T 'HoursAgo' '{0} hr ago') -f [int]$delta.TotalHours) }
    return ((T 'DaysAgo' '{0} day(s) ago') -f [int]$delta.TotalDays)
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
    $meta = (T 'RstSnapshotMeta' '{0} app(s), {1} folder(s), {2} browser(s), {3} tab(s)') -f
        $stats.Apps, $stats.Folders, $stats.Browsers, $stats.Tabs
    return ('{0}  -  {1}' -f $Entry.CapturedAt.ToString('g'), $meta)
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
    $item.Tag = [pscustomobject]@{ Kind = $Kind; Value = $Value; Checked = $true }
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
    $folderAccent = if ($null -ne $script:P -and $script:P.ContainsKey('Accent')) { $script:P.Accent } else { [System.Drawing.Color]::FromArgb(41, 79, 130) }
    $folderFace = if ($null -ne $script:P -and $script:P.ContainsKey('AccentSoft')) { $script:P.AccentSoft } else { [System.Drawing.Color]::FromArgb(226, 234, 244) }
    $darkBrush = New-Object System.Drawing.SolidBrush($folderAccent)
    $lightBrush = New-Object System.Drawing.SolidBrush($folderFace)
    $pen = New-Object System.Drawing.Pen($folderAccent, 1)
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

# ---------------------------------------------------------------------------
# Shared Studio controls and theme
# ---------------------------------------------------------------------------

$controlsPath = Join-Path $PSScriptRoot 'StudioControls.cs'
if (-not (Test-Path -LiteralPath $controlsPath)) {
    $controlsPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'src\StudioControls.cs'
}
if (-not (Test-Path -LiteralPath $controlsPath)) {
    [System.Windows.Forms.MessageBox]::Show('StudioControls.cs is missing. Reinstall Session Recovery.', 'Session Recovery', 'OK', 'Error') | Out-Null
    exit 2
}
if (-not ('SessionRecovery.Studio.StudioCard' -as [type])) {
    Add-Type -Path $controlsPath -ReferencedAssemblies 'System.Windows.Forms', 'System.Drawing'
}
. (Join-Path $PSScriptRoot 'StudioTheme.ps1')

if (-not ('SRRestoreThemeNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class SRRestoreThemeNative
{
    [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)]
    public static extern int SetWindowTheme(IntPtr hWnd, string subAppName, string subIdList);
}
'@
}

$restoreTheme = 'Aurora'
try {
    $themeConfig = Get-SRConfig
    $themeProperty = $themeConfig.PSObject.Properties['theme']
    if ($null -ne $themeProperty -and -not [string]::IsNullOrWhiteSpace([string]$themeProperty.Value)) {
        $restoreTheme = [string]$themeProperty.Value
    }
} catch { }
$script:ThemeKey = Resolve-StudioThemeKey -Theme $restoreTheme
$script:P = Get-StudioPalette -Theme $script:ThemeKey

$script:FontBody = New-Object System.Drawing.Font('Segoe UI', 9)
$script:FontBodySmall = New-Object System.Drawing.Font('Segoe UI', 8.25)
$script:FontSemibold = New-Object System.Drawing.Font('Segoe UI Semibold', 9.5)
$script:FontSemiboldLarge = New-Object System.Drawing.Font('Segoe UI Semibold', 12)
$script:FontTitle = New-Object System.Drawing.Font('Segoe UI Semibold', 19)
$script:FontMono = New-Object System.Drawing.Font('Consolas', 8.25)
$script:FontMonoSmall = New-Object System.Drawing.Font('Consolas', 7.5)

$script:AppVersion = '2.8.0'
$hostCandidates = @()
if ($env:SESSIONRECOVERY_HOST_EXE) { $hostCandidates += $env:SESSIONRECOVERY_HOST_EXE }
$hostCandidates += (Join-Path $PSScriptRoot 'SessionRecovery.exe')
$hostCandidates += (Join-Path (Split-Path $PSScriptRoot -Parent) 'dist\SessionRecovery.exe')
$restoreHostExe = $hostCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if ($restoreHostExe) {
    try {
        $fileVersion = (Get-Item -LiteralPath $restoreHostExe).VersionInfo.FileVersion
        if (-not [string]::IsNullOrWhiteSpace($fileVersion)) {
            $versionMatch = [regex]::Match($fileVersion, '^\d+\.\d+\.\d+')
            if ($versionMatch.Success) { $script:AppVersion = $versionMatch.Value }
        }
    } catch { }
}

$iconPath = Join-Path $PSScriptRoot 'SessionRecovery.ico'
if (-not (Test-Path -LiteralPath $iconPath)) {
    $fallbackIconPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'assets\SessionRecovery.ico'
    if (Test-Path -LiteralPath $fallbackIconPath) { $iconPath = $fallbackIconPath } else { $iconPath = $null }
}

function Enable-RSDoubleBuffer {
    param($Control)
    if ($null -eq $Control) { return }
    try {
        $property = $Control.GetType().GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'Instance,NonPublic')
        if ($null -ne $property) { $property.SetValue($Control, $true, $null) }
    } catch { }
}

function New-StudioLabel {
    param(
        [string]$Text = '',
        [int]$X = 0,
        [int]$Y = 0,
        [int]$Width = 200,
        [int]$Height = 20,
        [System.Drawing.Font]$Font = $null,
        [System.Drawing.Color]$Color = [System.Drawing.Color]::Empty,
        [string]$Align = 'MiddleLeft',
        [bool]$AutoSize = $false
    )
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.Location = New-Object System.Drawing.Point($X, $Y)
    $label.Size = New-Object System.Drawing.Size($Width, $Height)
    $label.Font = if ($null -ne $Font) { $Font } else { $script:FontBody }
    $label.ForeColor = if (-not $Color.IsEmpty) { $Color } else { $script:P.Text }
    $label.BackColor = [System.Drawing.Color]::Transparent
    $label.TextAlign = [System.Drawing.ContentAlignment]$Align
    $label.AutoSize = $AutoSize
    $label.UseMnemonic = $false
    if (-not $AutoSize -and $Height -le 24) {
        $label.AutoEllipsis = $true
    } elseif (-not $AutoSize -and $Align -eq 'MiddleLeft') {
        $label.TextAlign = [System.Drawing.ContentAlignment]::TopLeft
    }
    return $label
}

function New-StudioCard {
    param(
        [int]$X = 0,
        [int]$Y = 0,
        [int]$Width = 300,
        [int]$Height = 120,
        [System.Drawing.Color]$Fill = [System.Drawing.Color]::Empty,
        [System.Drawing.Color]$Border = [System.Drawing.Color]::Empty,
        [int]$Radius = 14
    )
    $card = New-Object SessionRecovery.Studio.StudioCard
    $card.Location = New-Object System.Drawing.Point($X, $Y)
    $card.Size = New-Object System.Drawing.Size($Width, $Height)
    $card.FillColor = if (-not $Fill.IsEmpty) { $Fill } else { $script:P.Card }
    $card.BorderColor = if (-not $Border.IsEmpty) { $Border } else { $script:P.Border }
    $card.CanvasColor = $script:P.Bg
    $card.CornerRadius = $Radius
    return $card
}

function New-StudioButton {
    param(
        [string]$Text = '',
        [int]$X = 0,
        [int]$Y = 0,
        [int]$Width = 120,
        [int]$Height = 36,
        [switch]$Primary,
        [switch]$Danger,
        [string]$Glyph = ''
    )
    $button = New-Object SessionRecovery.Studio.StudioButton
    $button.Text = $Text
    $button.Location = New-Object System.Drawing.Point($X, $Y)
    $button.Size = New-Object System.Drawing.Size($Width, $Height)
    $button.CornerRadius = 9
    $button.Glyph = $Glyph
    $button.DisabledFillColor = $script:P.DisabledFill
    $button.DisabledTextColor = $script:P.DisabledText
    if ($Primary) {
        $button.FillColor = $script:P.Accent
        $button.GradientEndColor = $script:P.Accent2
        $button.HoverColor = $script:P.AccentHover
        $button.PressedColor = $script:P.AccentPressed
        $button.TextColor = if ($script:P.ContainsKey('AccentText')) { $script:P.AccentText } else { $script:P.White }
        $button.OutlineColor = [System.Drawing.Color]::Empty
    } elseif ($Danger) {
        $button.FillColor = $script:P.RedSoft
        $button.GradientEndColor = $script:P.RedSoft
        $button.HoverColor = $script:P.DangerHover
        $button.PressedColor = $script:P.DangerPressed
        $button.TextColor = $script:P.Red
        $button.OutlineColor = $script:P.DangerOutline
    } else {
        $button.FillColor = $script:P.CardAlt
        $button.GradientEndColor = [System.Drawing.Color]::Empty
        $button.HoverColor = $script:P.CardHover
        $button.PressedColor = $script:P.Pressed
        $button.TextColor = $script:P.Text
        $button.OutlineColor = $script:P.Border
    }
    return $button
}

function New-StudioToggle {
    param([int]$X = 0, [int]$Y = 0, [bool]$Checked = $false)
    $toggle = New-Object SessionRecovery.Studio.StudioToggle
    $toggle.Location = New-Object System.Drawing.Point($X, $Y)
    $toggle.Checked = $Checked
    $toggle.OnColor = $script:P.Accent
    $toggle.OffColor = $script:P.ToggleOff
    $toggle.ThumbColor = $script:P.White
    return $toggle
}

function New-StudioBadge {
    param(
        [string]$Text = '',
        [int]$Width = 100,
        [int]$Height = 24,
        [System.Drawing.Color]$Fill = [System.Drawing.Color]::Empty,
        [System.Drawing.Color]$TextColor = [System.Drawing.Color]::Empty
    )
    $badge = New-Object SessionRecovery.Studio.StudioBadge
    $badge.Text = $Text
    $badge.Size = New-Object System.Drawing.Size($Width, $Height)
    $badge.FillColor = if (-not $Fill.IsEmpty) { $Fill } else { $script:P.GreenSoft }
    $badge.TextColor = if (-not $TextColor.IsEmpty) { $TextColor } else { $script:P.Green }
    return $badge
}

function New-StudioCombo {
    param([int]$X = 0, [int]$Y = 0, [int]$Width = 200)
    $combo = New-Object SessionRecovery.Studio.StudioComboBox
    $combo.Location = New-Object System.Drawing.Point($X, $Y)
    $combo.Size = New-Object System.Drawing.Size($Width, 28)
    $combo.BackColor = $script:P.CardAlt
    $combo.ForeColor = $script:P.Text
    $combo.SelectionBackColor = $script:P.ComboSelection
    $combo.BorderColor = $script:P.Border
    return $combo
}

$script:rsSnapshotEntries = $snapshotEntries
$script:rsUpdating = $false
$script:rsRestoring = $false
$script:rsShowChecks = $true
$script:rsHoverIndex = -1
$script:rsRtl = $false
try { $script:rsRtl = Test-SRRtlLanguage -Language $restoreLanguage } catch { }

# ---------------------------------------------------------------------------
# Main window
# ---------------------------------------------------------------------------

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Session Recovery'
$form.ClientSize = New-Object System.Drawing.Size(1160, 680)
$form.MinimumSize = New-Object System.Drawing.Size(1040, 700)
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.BackColor = $script:P.Bg
$form.ForeColor = $script:P.Text
$form.Font = $script:FontBody
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
$form.ShowInTaskbar = $true
Enable-RSDoubleBuffer $form
if ($iconPath) {
    try { $form.Icon = New-Object System.Drawing.Icon($iconPath) } catch { }
}

$accentBar = New-Object System.Windows.Forms.Panel
$accentBar.Dock = [System.Windows.Forms.DockStyle]::Top
$accentBar.Height = 3
$accentBar.BackColor = $script:P.Accent
$accentBar.Add_Paint({
    param($sender, $e)
    $rect = New-Object System.Drawing.Rectangle(0, 0, $sender.Width, $sender.Height)
    $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, $script:P.Accent, $script:P.Accent2, 0)
    try { $e.Graphics.FillRectangle($brush, $rect) } finally { $brush.Dispose() }
})
$form.Controls.Add($accentBar)

$sidebar = New-Object System.Windows.Forms.Panel
$sidebar.Dock = [System.Windows.Forms.DockStyle]::Left
$sidebar.Width = 236
$sidebar.BackColor = $script:P.Sidebar
$form.Controls.Add($sidebar)

$main = New-Object System.Windows.Forms.Panel
$main.Dock = [System.Windows.Forms.DockStyle]::Fill
$main.BackColor = $script:P.Bg
$form.Controls.Add($main)
$main.BringToFront()

$brandPic = New-Object System.Windows.Forms.PictureBox
$brandPic.Location = New-Object System.Drawing.Point(22, 24)
$brandPic.Size = New-Object System.Drawing.Size(38, 38)
$brandPic.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
$brandPic.BackColor = [System.Drawing.Color]::Transparent
if ($iconPath) {
    try { $brandPic.Image = (New-Object System.Drawing.Icon($iconPath)).ToBitmap() } catch { }
}
$sidebar.Controls.Add($brandPic)

$brandName = New-StudioLabel -Text 'Session' -X 70 -Y 23 -Width 150 -Height 24 -Font (New-Object System.Drawing.Font('Segoe UI Semibold', 13)) -Color $script:P.Text
$sidebar.Controls.Add($brandName)
$brandSubText = (T 'BrandRecoveryRestore' 'RECOVERY  /  RESTORE')
$brandSub = New-StudioLabel -Text $brandSubText -X 72 -Y 45 -Width 152 -Height 16 -Font $script:FontMono -Color $script:P.Subtle
if ([System.Windows.Forms.TextRenderer]::MeasureText($brandSubText, $script:FontMono).Width -gt 148) {
    $brandParts = @($brandSubText -split '\s*/\s*' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($brandParts.Count -eq 2) {
        $brandSub.Text = $brandParts[0] + "`r`n" + $brandParts[1]
        $brandSub.Height = 30
        $brandSub.TextAlign = [System.Drawing.ContentAlignment]::TopLeft
    }
}
if ($script:rsRtl) {
    $brandName.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
    $brandSub.TextAlign = [System.Drawing.ContentAlignment]::TopRight
}
$sidebar.Controls.Add($brandSub)

$sidebarHint = New-StudioLabel -Text (T 'DashboardHint' 'Snapshots are local JSON files. Nothing leaves this device.') -X 22 -Y 92 -Width 192 -Height 76 -Font $script:FontBodySmall -Color $script:P.Muted
$sidebar.Controls.Add($sidebarHint)

$sidebarFooter = New-Object System.Windows.Forms.Panel
$sidebarFooter.Dock = [System.Windows.Forms.DockStyle]::Bottom
$sidebarFooter.Height = 224
$sidebarFooter.BackColor = $script:P.Sidebar
$sidebar.Controls.Add($sidebarFooter)

$sidebarStatusCard = New-StudioCard -X 14 -Y 8 -Width 208 -Height 170 -Fill $script:P.CardAlt -Border $script:P.BorderSoft -Radius 12
$sidebarStatusCard.CanvasColor = $script:P.Sidebar
$sidebarFooter.Controls.Add($sidebarStatusCard)

$sidebarBadge = New-StudioBadge -Text (T 'RstBadge' 'RESTORE') -Width 100 -Height 22 -Fill $script:P.AccentSoft -TextColor $script:P.Accent
$sidebarBadge.Location = New-Object System.Drawing.Point(14, 13)
if ($script:rsRtl) {
    $sidebarBadge.Left = $sidebarStatusCard.ClientSize.Width - 14 - $sidebarBadge.Width
}
$sidebarStatusCard.Controls.Add($sidebarBadge)

$sidebarTitle = New-StudioLabel -Text (T 'RstSnapshotLabel' 'SNAPSHOT') -X 14 -Y 43 -Width 180 -Height 16 -Font $script:FontMono -Color $script:P.Subtle
$sidebarStatusCard.Controls.Add($sidebarTitle)
$sidebarStatus = New-StudioLabel -Text '' -X 14 -Y 60 -Width 180 -Height 20 -Font $script:FontSemibold -Color $script:P.Text
$sidebarStatusCard.Controls.Add($sidebarStatus)
$sidebarDetail = New-StudioLabel -Text '' -X 14 -Y 84 -Width 180 -Height 40 -Font $script:FontBodySmall -Color $script:P.Muted
$sidebarStatusCard.Controls.Add($sidebarDetail)
$sidebarLocal = New-StudioLabel -Text (T 'BadgeLocalOnly' 'LOCAL ONLY') -X 14 -Y 138 -Width 180 -Height 16 -Font $script:FontMono -Color $script:P.Subtle
$sidebarStatusCard.Controls.Add($sidebarLocal)

$sidebarVersion = New-StudioLabel -Text ((T 'RstVersion' 'RESTORE {0}') -f $script:AppVersion) -X 14 -Y 192 -Width 208 -Height 16 -Font $script:FontMono -Color $script:P.Subtle -Align 'MiddleCenter'
$sidebarFooter.Controls.Add($sidebarVersion)

# ---------------------------------------------------------------------------
# Header, content and footer
# ---------------------------------------------------------------------------

$header = New-Object System.Windows.Forms.Panel
$header.Dock = [System.Windows.Forms.DockStyle]::Top
$header.Height = 84
$header.BackColor = $script:P.Bg
$main.Controls.Add($header)

$headerLine = New-Object System.Windows.Forms.Panel
$headerLine.Dock = [System.Windows.Forms.DockStyle]::Bottom
$headerLine.Height = 1
$headerLine.BackColor = $script:P.BorderSoft
$header.Controls.Add($headerLine)

$titleLabel = New-StudioLabel -Text (T 'RstTitle' 'Restore your previous session') -X 28 -Y 16 -Width 760 -Height 34 -Font $script:FontTitle -Color $script:P.Text
$titleLabel.AutoEllipsis = $true
$titleLabel.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$header.Controls.Add($titleLabel)

$subtitleLabel = New-StudioLabel -Text (T 'RstSubtitle' 'Choose what to reopen. Everything stays on this PC.') -X 30 -Y 50 -Width 760 -Height 20 -Font $script:FontBody -Color $script:P.Muted
try {
    # A plain-language crash reason replaces guesswork in the header.
    $shutdownInfo = Get-SRLastShutdownReason
    if ([string]$shutdownInfo.Kind -eq 'crash' -and -not [string]::IsNullOrWhiteSpace([string]$shutdownInfo.Reason)) {
        $reasonText = Format-SRShutdownReason -Shutdown $shutdownInfo -Strings $script:RestoreStrings
        $subtitleLabel.Text = ((T 'RstShutdownReason' 'Windows stopped unexpectedly: {0}') -f $reasonText)
        $subtitleLabel.ForeColor = $script:P.Red
    }
} catch { }
$subtitleLabel.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$header.Controls.Add($subtitleLabel)

$localBadge = New-StudioBadge -Text (T 'BadgeLocalOnly' 'LOCAL ONLY') -Width 100 -Height 24 -Fill $script:P.CardAlt -TextColor $script:P.Muted
$localBadge.Location = New-Object System.Drawing.Point(($header.Width - $localBadge.Width - 28), 20)
$localBadge.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$header.Controls.Add($localBadge)

$footer = New-Object System.Windows.Forms.Panel
$footer.Dock = [System.Windows.Forms.DockStyle]::Bottom
$footer.Height = 64
$footer.BackColor = $script:P.Bg
$main.Controls.Add($footer)

$footerLine = New-Object System.Windows.Forms.Panel
$footerLine.Dock = [System.Windows.Forms.DockStyle]::Top
$footerLine.Height = 1
$footerLine.BackColor = $script:P.BorderSoft
$footer.Controls.Add($footerLine)

$content = New-Object System.Windows.Forms.Panel
$content.Dock = [System.Windows.Forms.DockStyle]::Fill
$content.BackColor = $script:P.Bg
$main.Controls.Add($content)
$content.BringToFront()

$progressBar = New-Object SessionRecovery.Studio.StudioProgress
$progressBar.Location = New-Object System.Drawing.Point(24, 11)
$progressBar.Size = New-Object System.Drawing.Size(582, 8)
$progressBar.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$progressBar.TrackColor = $script:P.Border
$progressBar.ProgressColor = $script:P.Accent
$progressBar.ProgressEndColor = $script:P.Accent2
$progressBar.Visible = $false
$footer.Controls.Add($progressBar)

$statusLabel = New-StudioLabel -Text '' -X 24 -Y 26 -Width 582 -Height 20 -Font $script:FontMono -Color $script:P.Muted
$statusLabel.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$footer.Controls.Add($statusLabel)

$skipButton = New-StudioButton -Text (T 'RstSkip' 'Skip') -X 0 -Y 12 -Width 110 -Height 40
$skipButton.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
$skipButton.Location = New-Object System.Drawing.Point(($footer.Width - 110 - 12 - 200 - 24), 12)
$skipButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
$footer.Controls.Add($skipButton)

$restoreButton = New-StudioButton -Text (T 'RstRestoreSelected' 'Restore selected') -X 0 -Y 12 -Width 200 -Height 40 -Primary
$restoreButton.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
$restoreButton.Location = New-Object System.Drawing.Point(($footer.Width - 200 - 24), 12)
$footer.Controls.Add($restoreButton)

$script:rsFooterSummary = $null
$script:rsFooterPreview = $null

function Update-RSFooterStatus {
    # The footer sits inside the content column, so the status area is much
    # narrower than the window. Wrap the summary when it cannot fit.
    $available = [Math]::Max(220, $footer.ClientSize.Width - 382)
    $statusLabel.Width = $available
    if ($null -eq $script:rsFooterSummary) {
        $statusLabel.Location = New-Object System.Drawing.Point(24, 26)
        $statusLabel.Size = New-Object System.Drawing.Size($available, 20)
        $statusLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
        return
    }
    $single = $script:rsFooterSummary
    if (-not [string]::IsNullOrWhiteSpace($script:rsFooterPreview)) {
        $single += '  |  ' + $script:rsFooterPreview
    }
    $fits = [System.Windows.Forms.TextRenderer]::MeasureText($single, $script:FontMono).Width -le ($available - 8)
    if ($fits -or [string]::IsNullOrWhiteSpace($script:rsFooterPreview)) {
        $statusLabel.Location = New-Object System.Drawing.Point(24, 26)
        $statusLabel.Size = New-Object System.Drawing.Size($available, 20)
        $statusLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
        $statusLabel.Text = $single
    } else {
        $statusLabel.Location = New-Object System.Drawing.Point(24, 12)
        $statusLabel.Size = New-Object System.Drawing.Size($available, 40)
        $statusLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
        $statusLabel.Text = $script:rsFooterSummary + "`r`n" + $script:rsFooterPreview
    }
}

$footer.Add_Resize({
    param($sender, $e)
    # Keep the status line clear of the Skip and Restore buttons.
    $available = [Math]::Max(220, $sender.ClientSize.Width - 382)
    $progressBar.Width = $available
    Update-RSFooterStatus
})

# ---------------------------------------------------------------------------
# Snapshot picker
# ---------------------------------------------------------------------------

$snapshotCard = New-StudioCard -X 24 -Y 18 -Width 876 -Height 72
$snapshotCard.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$content.Controls.Add($snapshotCard)

$snapshotLabel = New-StudioLabel -Text (T 'RstSnapshotLabel' 'SNAPSHOT') -X 18 -Y 10 -Width 140 -Height 16 -Font $script:FontMono -Color $script:P.Subtle
if ($script:rsRtl) {
    $snapshotLabel.Left = $snapshotCard.ClientSize.Width - 18 - $snapshotLabel.Width
}
$snapshotCard.Controls.Add($snapshotLabel)

$snapshotCombo = New-StudioCombo -X 18 -Y 30 -Width 650
$snapshotCombo.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$snapshotCombo.Font = New-Object System.Drawing.Font('Segoe UI', 9.25)
$snapshotCard.Controls.Add($snapshotCombo)

$ageLabel = New-StudioLabel -Text '' -X 686 -Y 34 -Width 170 -Height 20 -Font $script:FontMono -Color $script:P.Muted -Align 'MiddleRight'
$ageLabel.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$snapshotCard.Controls.Add($ageLabel)

$snapshotCard.Add_Resize({
    param($sender, $e)
    $available = [Math]::Max(220, $sender.ClientSize.Width - 36 - 186)
    $snapshotCombo.Width = $available
    $ageLabel.Left = $sender.ClientSize.Width - 18 - $ageLabel.Width
    if ($script:rsRtl) {
        $snapshotLabel.Left = $sender.ClientSize.Width - 18 - $snapshotLabel.Width
    }
})

# ---------------------------------------------------------------------------
# Item list
# ---------------------------------------------------------------------------

$listCard = New-StudioCard -X 24 -Y 104 -Width 876 -Height 295
$listCard.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$content.Controls.Add($listCard)

$listHeading = New-StudioLabel -Text (T 'RstItems' 'ITEMS TO REOPEN') -X 18 -Y 12 -Width 360 -Height 18 -Font $script:FontMono -Color $script:P.Subtle
if ($script:rsRtl) {
    $listHeading.Left = $listCard.ClientSize.Width - 18 - $listHeading.Width
}
$listCard.Controls.Add($listHeading)

$selectAllLabel = New-StudioLabel -Text (T 'RstSelectAll' 'Select all') -X 0 -Y 12 -Width 120 -Height 22 -Font $script:FontBody -Color $script:P.Muted -Align 'MiddleRight'
$selectAllLabel.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$selectAllLabel.Location = New-Object System.Drawing.Point(($listCard.Width - 18 - 46 - 8 - 120), 12)
$listCard.Controls.Add($selectAllLabel)

$selectAll = New-StudioToggle -X 0 -Y 12 -Checked $true
$selectAll.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$selectAll.Location = New-Object System.Drawing.Point(($listCard.Width - 18 - 46), 11)
$listCard.Controls.Add($selectAll)
if ($script:rsRtl) {
    $selectAll.Left = 18
    $selectAllLabel.Left = $selectAll.Left + $selectAll.Width + 8
}

$listRule = New-Object System.Windows.Forms.Panel
$listRule.Location = New-Object System.Drawing.Point(18, 40)
$listRule.Size = New-Object System.Drawing.Size(840, 1)
$listRule.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$listRule.BackColor = $script:P.BorderSoft
$listCard.Controls.Add($listRule)

$itemHeader = New-StudioLabel -Text (T 'RstItem' 'ITEM') -X 18 -Y 48 -Width 200 -Height 16 -Font $script:FontMonoSmall -Color $script:P.Subtle
$listCard.Controls.Add($itemHeader)

$detailsHeader = New-StudioLabel -Text (T 'RstDetails' 'DETAILS') -X 306 -Y 48 -Width 200 -Height 16 -Font $script:FontMonoSmall -Color $script:P.Subtle
$listCard.Controls.Add($detailsHeader)

$list = New-Object System.Windows.Forms.ListView
$list.View = [System.Windows.Forms.View]::Details
$list.CheckBoxes = $false
$list.OwnerDraw = $true
$list.FullRowSelect = $true
$list.GridLines = $false
$list.HeaderStyle = [System.Windows.Forms.ColumnHeaderStyle]::None
$list.HideSelection = $false
$list.MultiSelect = $true
$list.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$list.BackColor = $script:P.Card
$list.ForeColor = $script:P.Text
$list.Font = New-Object System.Drawing.Font('Segoe UI', 9.25)
$list.Location = New-Object System.Drawing.Point(18, 68)
$list.Size = New-Object System.Drawing.Size(840, 211)
$list.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
Enable-RSDoubleBuffer $list

$rowImages = New-Object System.Windows.Forms.ImageList
$rowImages.ImageSize = New-Object System.Drawing.Size(20, 20)
$rowImages.ColorDepth = [System.Windows.Forms.ColorDepth]::Depth32Bit
$rowImages.TransparentColor = [System.Drawing.Color]::Transparent
[void]$rowImages.Images.Add((New-Object System.Drawing.Bitmap(20, 20)))
[void]$rowImages.Images.Add((New-RSFolderIconBitmap))
$list.SmallImageList = $rowImages
$script:rsRowImages = $rowImages
$script:rsIconCache = @{}
[void]$list.Columns.Add('Item', 320)
[void]$list.Columns.Add('Details', 500)
$listCard.Controls.Add($list)

function Update-RSListHeaderPositions {
    if ($list.Columns.Count -lt 2) { return }
    $first = $list.Columns[0].Width
    if ($script:rsRtl) {
        $itemRight = $list.Left + $first - 4
        if ($script:rsShowChecks) { $itemRight -= 28 }
        $itemHeader.Left = $itemRight - $itemHeader.Width
        $detailsHeader.Left = $list.Left + $list.ClientSize.Width - 4 - $detailsHeader.Width
    } else {
        $itemHeader.Left = $list.Left
        $detailsHeader.Left = $list.Left + $first
    }
}
Update-RSListHeaderPositions

$listCard.Add_Resize({
    param($sender, $e)
    $snapshotHeight = [Math]::Max(80, $sender.ClientSize.Height - 82)
    $list.Height = $snapshotHeight
    $listRule.Width = [Math]::Max(200, $sender.ClientSize.Width - 36)
    if ($script:rsRtl) {
        $selectAll.Left = 18
        $selectAllLabel.Left = $selectAll.Left + $selectAll.Width + 8
        $listHeading.Left = $sender.ClientSize.Width - 18 - $listHeading.Width
    } else {
        $selectAll.Left = $sender.ClientSize.Width - 18 - $selectAll.Width
        $selectAllLabel.Left = $selectAll.Left - 8 - $selectAllLabel.Width
    }
})

$list.Add_Resize({
    if ($list.Columns.Count -lt 2) { return }
    $available = [Math]::Max(300, $list.ClientSize.Width)
    $first = [int]($available * 0.36)
    $list.Columns[0].Width = $first
    $list.Columns[1].Width = [Math]::Max(140, $available - $first - 4)
    Update-RSListHeaderPositions
})

function Test-RSRowSelected {
    param($ItemState)
    return (($ItemState -band [System.Windows.Forms.ListViewItemStates]::Selected) -ne 0)
}

function Get-RSRowBackground {
    param($Item, $ItemState)
    if (Test-RSRowSelected -ItemState $ItemState) { return $script:P.ComboSelection }
    if ($null -ne $Item -and $Item.Index -eq $script:rsHoverIndex) { return $script:P.CardHover }
    return $script:P.Card
}

function Draw-RSCheckGlyph {
    param(
        [System.Drawing.Graphics]$Graphics,
        [System.Drawing.Rectangle]$Bounds,
        [bool]$Checked
    )
    $size = 15
    $rect = New-Object System.Drawing.Rectangle($Bounds.Left, ($Bounds.Top + [int](($Bounds.Height - $size) / 2)), $size, $size)
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $radius = 4
    $diameter = $radius * 2
    $path.AddArc($rect.X, $rect.Y, $diameter, $diameter, 180, 90)
    $path.AddArc($rect.Right - $diameter, $rect.Y, $diameter, $diameter, 270, 90)
    $path.AddArc($rect.Right - $diameter, $rect.Bottom - $diameter, $diameter, $diameter, 0, 90)
    $path.AddArc($rect.X, $rect.Bottom - $diameter, $diameter, $diameter, 90, 90)
    $path.CloseFigure()
    try {
        if ($Checked) {
            $fill = New-Object System.Drawing.SolidBrush($script:P.Accent)
            $Graphics.FillPath($fill, $path)
            $fill.Dispose()
            $markColor = if ($script:P.ContainsKey('AccentText')) { $script:P.AccentText } else { $script:P.White }
            $pen = New-Object System.Drawing.Pen($markColor, 1.8)
            $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
            $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
            try {
                $points = [System.Drawing.Point[]]@(
                    (New-Object System.Drawing.Point(($rect.Left + 4), ($rect.Top + 7))),
                    (New-Object System.Drawing.Point(($rect.Left + 6), ($rect.Top + 10))),
                    (New-Object System.Drawing.Point(($rect.Left + 11), ($rect.Top + 4)))
                )
                $Graphics.DrawLines($pen, $points)
            } finally { $pen.Dispose() }
        } else {
            $pen = New-Object System.Drawing.Pen($script:P.Subtle, 1.2)
            try { $Graphics.DrawPath($pen, $path) } finally { $pen.Dispose() }
        }
    } finally {
        $path.Dispose()
    }
}

$list.Add_DrawColumnHeader({ param($sender, $e) $e.DrawDefault = $true })
$list.Add_DrawItem({
    param($sender, $e)
    $e.DrawDefault = $false
    $background = Get-RSRowBackground -Item $e.Item -ItemState $e.State
    $rowWidth = $sender.ClientSize.Width
    $rowBounds = New-Object System.Drawing.Rectangle(0, $e.Bounds.Top, $rowWidth, $e.Bounds.Height)
    $brush = New-Object System.Drawing.SolidBrush($background)
    try { $e.Graphics.FillRectangle($brush, $rowBounds) } finally { $brush.Dispose() }

    $flags = [System.Windows.Forms.TextFormatFlags]::SingleLine -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor [System.Windows.Forms.TextFormatFlags]::EndEllipsis -bor [System.Windows.Forms.TextFormatFlags]::NoPrefix
    if ($script:rsRtl) {
        $flags = $flags -bor [System.Windows.Forms.TextFormatFlags]::Right -bor [System.Windows.Forms.TextFormatFlags]::RightToLeft
    }

    $firstWidth = if ($sender.Columns.Count -gt 0) { $sender.Columns[0].Width } else { [int]($rowWidth * 0.36) }
    if ($script:rsRtl) {
        # Mirror the checkbox and icon slots so they stay next to the name.
        $rightEdge = $firstWidth
        if ($script:rsShowChecks) {
            $checkBounds = New-Object System.Drawing.Rectangle(($firstWidth - 22), $rowBounds.Top, 15, $rowBounds.Height)
            $isChecked = $false
            if ($null -ne $e.Item.Tag) {
                $checkedProperty = $e.Item.Tag.PSObject.Properties['Checked']
                if ($null -ne $checkedProperty) { $isChecked = [bool]$checkedProperty.Value }
            }
            Draw-RSCheckGlyph -Graphics $e.Graphics -Bounds $checkBounds -Checked $isChecked
            $rightEdge -= 28
        }
        if ($null -ne $e.Item.ImageList -and $e.Item.ImageIndex -ge 0) {
            try {
                $image = $e.Item.ImageList.Images[$e.Item.ImageIndex]
                if ($null -ne $image) {
                    $imageTop = $rowBounds.Top + [int](($rowBounds.Height - 20) / 2)
                    $e.Graphics.DrawImage($image, ($rightEdge - 24), $imageTop, 20, 20)
                }
            } catch { }
            $rightEdge -= 26
        }
        $titleRect = New-Object System.Drawing.Rectangle(($rowBounds.Left + 4), $rowBounds.Top, [Math]::Max(20, $rightEdge - $rowBounds.Left - 8), $rowBounds.Height)
        [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, [string]$e.Item.Text, $sender.Font, $titleRect, $script:P.Text, $flags)
    } else {
        $left = $rowBounds.Left
        if ($script:rsShowChecks) {
            $checkBounds = New-Object System.Drawing.Rectangle(($left + 7), $rowBounds.Top, 15, $rowBounds.Height)
            $isChecked = $false
            if ($null -ne $e.Item.Tag) {
                $checkedProperty = $e.Item.Tag.PSObject.Properties['Checked']
                if ($null -ne $checkedProperty) { $isChecked = [bool]$checkedProperty.Value }
            }
            Draw-RSCheckGlyph -Graphics $e.Graphics -Bounds $checkBounds -Checked $isChecked
            $left += 28
        }
        if ($null -ne $e.Item.ImageList -and $e.Item.ImageIndex -ge 0) {
            try {
                $image = $e.Item.ImageList.Images[$e.Item.ImageIndex]
                if ($null -ne $image) {
                    $imageTop = $rowBounds.Top + [int](($rowBounds.Height - 20) / 2)
                    $e.Graphics.DrawImage($image, ($left + 2), $imageTop, 20, 20)
                }
            } catch { }
        }
        $left += 26
        $titleRect = New-Object System.Drawing.Rectangle($left, $rowBounds.Top, [Math]::Max(20, $firstWidth - $left - 4), $rowBounds.Height)
        [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, [string]$e.Item.Text, $sender.Font, $titleRect, $script:P.Text, $flags)
    }

    if ($e.Item.SubItems.Count -gt 1) {
        $detailsLeft = $firstWidth + 4
        $detailsRect = New-Object System.Drawing.Rectangle($detailsLeft, $rowBounds.Top, [Math]::Max(20, $rowWidth - $detailsLeft - 4), $rowBounds.Height)
        [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, [string]$e.Item.SubItems[1].Text, $script:FontBodySmall, $detailsRect, $script:P.Muted, $flags)
    }
})

$list.Add_MouseMove({
    param($sender, $e)
    $item = $sender.GetItemAt($e.X, $e.Y)
    $index = if ($null -ne $item) { $item.Index } else { -1 }
    if ($index -ne $script:rsHoverIndex) {
        $script:rsHoverIndex = $index
        $sender.Invalidate()
    }
})
$list.Add_MouseLeave({
    param($sender, $e)
    if ($script:rsHoverIndex -ne -1) {
        $script:rsHoverIndex = -1
        $sender.Invalidate()
    }
})
$list.Add_MouseDown({
    param($sender, $e)
    if (-not $script:rsShowChecks -or $e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
    $item = $sender.GetItemAt($e.X, $e.Y)
    if ($null -eq $item -or $null -eq $item.Tag) { return }
    $bounds = $item.GetBounds([System.Windows.Forms.ItemBoundsPortion]::Entire)
    if ($e.X -ge ($bounds.Left + 4) -and $e.X -le ($bounds.Left + 28)) {
        $checkedProperty = $item.Tag.PSObject.Properties['Checked']
        if ($null -eq $checkedProperty) { return }
        $item.Tag.Checked = -not [bool]$checkedProperty.Value
        $sender.Invalidate()
        Update-RSSelectAllState
    }
})
$list.Add_KeyDown({
    param($sender, $e)
    if (-not $script:rsShowChecks -or $e.KeyCode -ne [System.Windows.Forms.Keys]::Space) { return }
    $changed = $false
    foreach ($item in @($sender.SelectedItems)) {
        if ($null -eq $item.Tag) { continue }
        $checkedProperty = $item.Tag.PSObject.Properties['Checked']
        if ($null -eq $checkedProperty) { continue }
        $item.Tag.Checked = -not [bool]$checkedProperty.Value
        $changed = $true
    }
    if ($changed) {
        $sender.Invalidate()
        Update-RSSelectAllState
        $e.Handled = $true
        $e.SuppressKeyPress = $true
    }
})

if ($script:ThemeKey -notin @('Daylight', 'Solar')) {
    try { [void][SRRestoreThemeNative]::SetWindowTheme($list.Handle, 'DarkMode_Explorer', $null) } catch { }
}

# ---------------------------------------------------------------------------
# Restore options
# ---------------------------------------------------------------------------

$optionsCard = New-StudioCard -X 24 -Y 0 -Width 876 -Height 96
$optionsCard.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$optionsCard.Location = New-Object System.Drawing.Point(24, 415)
$content.Controls.Add($optionsCard)

$optionsHeading = New-StudioLabel -Text (T 'RstOptions' 'RESTORE OPTIONS') -X 18 -Y 8 -Width 300 -Height 16 -Font $script:FontMono -Color $script:P.Subtle
if ($script:rsRtl) {
    $optionsHeading.Left = $optionsCard.ClientSize.Width - 18 - $optionsHeading.Width
}
$optionsCard.Controls.Add($optionsHeading)

$tabModeLabel = New-StudioLabel -Text (T 'RstBrowserTabs' 'Browser tabs') -X 18 -Y 33 -Width 160 -Height 20 -Font $script:FontBody -Color $script:P.Text
$optionsCard.Controls.Add($tabModeLabel)

$tabModeCombo = New-StudioCombo -X 186 -Y 29 -Width 380
$tabModeCombo.Font = $script:FontBody
[void]$tabModeCombo.Items.Add((T 'RstTabModeSmart' 'Smart - reopen captured tabs when available'))
[void]$tabModeCombo.Items.Add((T 'RstTabModeCaptured' 'Captured tabs - reopen the exact tabs'))
[void]$tabModeCombo.Items.Add((T 'RstTabModeNative' 'Browser session - use the browser''s own restore'))
[void]$tabModeCombo.Items.Add((T 'RstTabModeNone' 'Do not reopen browsers or tabs'))
switch ($TabMode) {
    'Captured' { $tabModeCombo.SelectedIndex = 1 }
    'Native' { $tabModeCombo.SelectedIndex = 2 }
    'None' { $tabModeCombo.SelectedIndex = 3 }
    default { $tabModeCombo.SelectedIndex = 0 }
}
$optionsCard.Controls.Add($tabModeCombo)

$forceCheck = New-StudioToggle -X 18 -Y 64 -Checked $false
$optionsCard.Controls.Add($forceCheck)

$forceLabel = New-StudioLabel -Text (T 'RstStartAnyway' 'Start applications even when they are already running') -X 72 -Y 64 -Width 790 -Height 24 -Font $script:FontBody -Color $script:P.Text
$forceLabel.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$optionsCard.Controls.Add($forceLabel)

if ($script:rsRtl) {
    $tabModeLabel.Left = $optionsCard.ClientSize.Width - 18 - $tabModeLabel.Width
    $tabModeLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
    $tabModeCombo.Left = $tabModeLabel.Left - 8 - $tabModeCombo.Width
    $forceCheck.Left = $optionsCard.ClientSize.Width - 18 - $forceCheck.Width
    $forceLabel.Left = 18
    $forceLabel.Width = [Math]::Max(200, $forceCheck.Left - 8 - 18)
}

$optionsCard.Add_Resize({
    param($sender, $e)
    if ($script:rsRtl) {
        $optionsHeading.Left = $sender.ClientSize.Width - 18 - $optionsHeading.Width
        $tabModeLabel.Left = $sender.ClientSize.Width - 18 - $tabModeLabel.Width
        $tabModeCombo.Left = $tabModeLabel.Left - 8 - $tabModeCombo.Width
        $forceCheck.Left = $sender.ClientSize.Width - 18 - $forceCheck.Width
        $forceLabel.Left = 18
        $forceLabel.Width = [Math]::Max(200, $forceCheck.Left - 8 - 18)
    } else {
        $optionsHeading.Left = 18
        $tabModeLabel.Left = 18
        $tabModeCombo.Left = 186
        $forceCheck.Left = 18
        $forceLabel.Left = 72
        $forceLabel.Width = [Math]::Max(200, $sender.ClientSize.Width - 72 - 18)
    }
})

$selectAllLabel.Add_Click({ if ($selectAll.Enabled) { $selectAll.Checked = -not $selectAll.Checked } })
$forceLabel.Add_Click({ if ($forceCheck.Enabled) { $forceCheck.Checked = -not $forceCheck.Checked } })

# Keep the bottom cards in place when the window is resized.
$content.Add_Resize({
    param($sender, $e)
    $snapshotCard.Width = [Math]::Max(400, $sender.ClientSize.Width - 48)
    $listCard.Width = [Math]::Max(400, $sender.ClientSize.Width - 48)
    $optionsCard.Width = [Math]::Max(400, $sender.ClientSize.Width - 48)
    $optionsCard.Left = 24
    $optionsCard.Top = $sender.ClientSize.Height - 18 - $optionsCard.Height
    $listCard.Height = [Math]::Max(120, $optionsCard.Top - 16 - $listCard.Top)
    $list.Height = [Math]::Max(60, $listCard.ClientSize.Height - 82)
    $listRule.Width = [Math]::Max(200, $listCard.ClientSize.Width - 36)
    $selectAll.Left = $listCard.ClientSize.Width - 18 - $selectAll.Width
    $selectAllLabel.Left = $selectAll.Left - 8 - $selectAllLabel.Width
})

$form.AcceptButton = $restoreButton
$form.CancelButton = $skipButton
$form.Add_FormClosing({
    param($sender, $eventArgs)
    # The restore loop is synchronous but pumps messages from its progress
    # callback. Do not let the window be disposed underneath that loop.
    if ($script:rsRestoring) { $eventArgs.Cancel = $true }
})

# Right-to-left languages get correctly shaped, right-aligned text. Layout
# mirroring is intentionally not used: it scrambles custom-painted controls.
try {
    if (Test-SRRtlLanguage -Language $restoreLanguage) {
        $form.RightToLeft = [System.Windows.Forms.RightToLeft]::Yes
    }
} catch { }

function Update-RSSelectAllState {
    if (-not $script:rsShowChecks) { return }
    $items = @($list.Items)
    $all = $items.Count -gt 0
    if ($all) {
        foreach ($item in $items) {
            if ($null -ne $item.Tag) {
                $checkedProperty = $item.Tag.PSObject.Properties['Checked']
                if ($null -eq $checkedProperty -or -not [bool]$checkedProperty.Value) {
                    $all = $false
                    break
                }
            }
        }
    }
    $script:rsUpdating = $true
    try { $selectAll.Checked = $all } finally { $script:rsUpdating = $false }
}

function Update-RSSelection {
    param([int]$Index)
    if ($Index -lt 0 -or $Index -ge $script:rsSnapshotEntries.Count) { return }
    $script:rsUpdating = $true
    try {
        $selected = $script:rsSnapshotEntries[$Index]
        Populate-RSList -List $list -Snapshot $selected.Snapshot
        $ageText = Format-RSAge -CapturedAt $selected.CapturedAt
        $ageLabel.Text = $ageText
        $sidebarStatus.Text = $ageText
        $stats = Get-RSStats -Snapshot $selected.Snapshot
        $sidebarDetail.Text = ('{0} {1}  /  {2} {3}' -f $stats.Apps, (T 'RstApps' 'Applications'), $stats.Folders, (T 'RstFolders' 'Folders')) + "`r`n" +
            ('{0} {1}  /  {2} {3}' -f $stats.Browsers, (T 'RstBrowserTabs' 'Browser tabs'), $stats.Tabs, (T 'StatTabs' 'Tabs'))
        $script:rsFooterSummary = ('{0} {1}  /  {2} {3}  /  {4} {5}  /  {6} {7}' -f
            $stats.Apps, (T 'RstApps' 'Applications'), $stats.Folders, (T 'RstFolders' 'Folders'),
            $stats.Browsers, (T 'RstBrowserTabs' 'Browser tabs'), $stats.Tabs, (T 'StatTabs' 'Tabs'))
        $script:rsFooterPreview = $null
        $selectAll.Checked = $true
        # Restore preview: what is already running versus what would start.
        try {
            $preview = Get-SRRestorePreview -Plan (New-SRRestorePlan -Snapshot $selected.Snapshot -All -TabMode 'Smart')
            if ($preview.Running -gt 0) {
                $script:rsFooterPreview = ((T 'RstPreview' '{0} running, {1} to start') -f $preview.Running, $preview.WillStart)
            }
        } catch { }
        Update-RSFooterStatus
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
    if ($script:rsUpdating -or -not $script:rsShowChecks) { return }
    foreach ($item in $list.Items) {
        if ($null -eq $item.Tag) { continue }
        $checkedProperty = $item.Tag.PSObject.Properties['Checked']
        if ($null -ne $checkedProperty) { $item.Tag.Checked = $selectAll.Checked }
    }
    $list.Invalidate()
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

    foreach ($item in $list.Items) {
        $tag = $item.Tag
        if ($null -eq $tag) { continue }
        $checkedProperty = $tag.PSObject.Properties['Checked']
        if ($null -eq $checkedProperty -or -not [bool]$checkedProperty.Value) { continue }
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
        [void][System.Windows.Forms.MessageBox]::Show((T 'RstNothingSelected' 'Nothing is selected.'), 'Session Recovery', 'OK', 'Information')
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
            $line = '{0}  -  {1}' -f [string]$_.name, [string]$_.exe
            $argumentProperty = $_.PSObject.Properties['args']
            if ($null -ne $argumentProperty -and $null -ne $argumentProperty.Value) {
                $displayArguments = @(@($argumentProperty.Value) |
                    ForEach-Object { [string]$_ } |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                if ($displayArguments.Count -gt 0) {
                    $line = '{0}  -  {1}' -f $line, ($displayArguments -join ' ')
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
    $selectAllLabel.Enabled = $false
    $tabModeCombo.Enabled = $false
    $forceCheck.Enabled = $false
    $forceLabel.Enabled = $false
    $script:rsFooterSummary = $null
    $statusLabel.Text = (T 'RstPreparing' 'Preparing to restore...')
    $progressBar.Value = 0
    $progressBar.Visible = $true
    [System.Windows.Forms.Application]::DoEvents()

    $progressCallback = {
        param([int]$Step, [int]$StepTotal, [string]$Label)
        $statusLabel.Text = ((T 'RstRestoringItem' 'Restoring {0} of {1}: {2}') -f $Step, $StepTotal, $Label)
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
    $script:rsShowChecks = $false
    $list.CheckBoxes = $false
    Update-RSListHeaderPositions
    $list.BeginUpdate()
    try {
        $list.Items.Clear()
        foreach ($result in $results) {
            $target = [string]$result.Target
            if ([string]::IsNullOrWhiteSpace($target)) {
                $target = if ($null -ne $result.App) { [string]$result.App.name } else { (T 'RstItemName' 'Item') }
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
            $item = New-Object System.Windows.Forms.ListViewItem((T 'RstNothingRestored' 'Nothing was restored.'))
            [void]$item.SubItems.Add((T 'RstNoResults' 'No results were reported.'))
            [void]$list.Items.Add($item)
        }
    } finally {
        $list.EndUpdate()
    }
    $list.Invalidate()

    $started = @($results | Where-Object { $_.Started }).Count
    $script:rsFooterSummary = $null
    if ($failure) {
        $statusLabel.Text = ((T 'RstFailed' 'Restore failed: {0}') -f $failure)
        $statusLabel.ForeColor = $script:P.Red
    } else {
        $statusLabel.Text = ((T 'RstFinished' 'Restore finished  -  {0} started, {1} skipped') -f $started, ($results.Count - $started))
        $statusLabel.ForeColor = $script:P.Green
    }
    $sidebarStatus.Text = if ($failure) { (T 'RstFailedShort' 'Restore failed') } else { (T 'RstFinishedShort' 'Restore finished') }
    $skipButton.Text = (T 'RstClose' 'Close')
    $skipButton.Enabled = $true
    $restoreButton.Visible = $false
})

$skipButton.Add_Click({
    Write-SRLog -Message 'Restore prompt was skipped by the user.'
    $form.Close()
})

if (-not [string]::IsNullOrWhiteSpace($RenderScreenshot)) {
    # Visible-window capture for visual verification without a live user.
    # DrawToBitmap cannot compose the nested StudioCard backgrounds; PrintWindow can.
    if (-not ('SRPrintWindowNative' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class SRPrintWindowNative
{
    [DllImport("user32.dll")]
    public static extern bool PrintWindow(IntPtr hwnd, IntPtr hdcBlt, uint nFlags);
    [DllImport("user32.dll")]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
}
'@
    }
    $renderSize = $form.ClientSize
    if (-not [string]::IsNullOrWhiteSpace($env:SESSIONRECOVERY_RENDER_SIZE)) {
        $parts = $env:SESSIONRECOVERY_RENDER_SIZE -split 'x'
        if ($parts.Count -eq 2) {
            $renderSize = New-Object System.Drawing.Size([int]$parts[0], [int]$parts[1])
        }
    }
    $form.ShowInTaskbar = $false
    $form.MinimumSize = [System.Drawing.Size]::Empty
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $form.ClientSize = $renderSize
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $form.Location = New-Object System.Drawing.Point(80, 80)
    $form.Show()
    $form.Activate()
    [void][SRPrintWindowNative]::SetWindowPos($form.Handle, [IntPtr]::Zero, 80, 80, 0, 0, 0x0001 -bor 0x0040)
    for ($pump = 0; $pump -lt 20; $pump++) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 40
    }
    $bitmap = New-Object System.Drawing.Bitmap($form.Width, $form.Height)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        # DWM occasionally returns an all-black surface on the first attempt.
        for ($attempt = 1; $attempt -le 4; $attempt++) {
            $graphics.Clear([System.Drawing.Color]::Black)
            $hdc = $graphics.GetHdc()
            try { [void][SRPrintWindowNative]::PrintWindow($form.Handle, $hdc, 2) } finally { $graphics.ReleaseHdc($hdc) }
            $probe = $bitmap.GetPixel([int]($bitmap.Width / 2), 1)
            if (($probe.R + $probe.G + $probe.B) -gt 0) { break }
            for ($pump = 0; $pump -lt 10; $pump++) {
                [System.Windows.Forms.Application]::DoEvents()
                Start-Sleep -Milliseconds 60
            }
        }
    } finally {
        $graphics.Dispose()
    }
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
