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
    $darkBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(41, 79, 130))
    $lightBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(226, 234, 244))
    $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(41, 79, 130), 1)
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

if (-not ('SRCardPanel' -as [type]) -or -not ('SRButton' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

public class SRCardPanel : Panel
{
    private Color _borderColor;
    private Color _fillColor;
    private int _cornerRadius;

    public Color BorderColor
    {
        get { return _borderColor; }
        set { _borderColor = value; Invalidate(); }
    }

    public Color FillColor
    {
        get { return _fillColor; }
        set { _fillColor = value; Invalidate(); }
    }

    public int CornerRadius
    {
        get { return _cornerRadius; }
        set { _cornerRadius = value; Invalidate(); }
    }

    public SRCardPanel()
    {
        _borderColor = Color.FromArgb(224, 229, 233);
        _fillColor = Color.White;
        _cornerRadius = 8;
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.UserPaint, true);
        BackColor = Color.FromArgb(244, 246, 248);
        Padding = new Padding(1);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        e.Graphics.Clear(BackColor);
        Rectangle rect = new Rectangle(0, 0, Width - 1, Height - 1);
        using (GraphicsPath path = CreateRoundRect(rect, _cornerRadius))
        using (SolidBrush brush = new SolidBrush(_fillColor))
        using (Pen pen = new Pen(_borderColor))
        {
            e.Graphics.FillPath(brush, path);
            e.Graphics.DrawPath(pen, path);
        }
    }

    private static GraphicsPath CreateRoundRect(Rectangle rect, int radius)
    {
        GraphicsPath path = new GraphicsPath();
        int diameter = radius * 2;
        if (diameter > rect.Width) { diameter = rect.Width; }
        if (diameter > rect.Height) { diameter = rect.Height; }
        if (diameter <= 0)
        {
            path.AddRectangle(rect);
            return path;
        }
        path.AddArc(rect.X, rect.Y, diameter, diameter, 180, 90);
        path.AddArc(rect.Right - diameter, rect.Y, diameter, diameter, 270, 90);
        path.AddArc(rect.Right - diameter, rect.Bottom - diameter, diameter, diameter, 0, 90);
        path.AddArc(rect.X, rect.Bottom - diameter, diameter, diameter, 90, 90);
        path.CloseFigure();
        return path;
    }
}

public class SRButton : Button
{
    private bool _hover;
    private bool _pressed;
    private Color _fillColor;
    private Color _hoverColor;
    private Color _pressedColor;
    private Color _outlineColor;
    private int _cornerRadius;

    public Color FillColor
    {
        get { return _fillColor; }
        set { _fillColor = value; Invalidate(); }
    }

    public Color HoverColor
    {
        get { return _hoverColor; }
        set { _hoverColor = value; Invalidate(); }
    }

    public Color PressedColor
    {
        get { return _pressedColor; }
        set { _pressedColor = value; Invalidate(); }
    }

    public Color OutlineColor
    {
        get { return _outlineColor; }
        set { _outlineColor = value; Invalidate(); }
    }

    public int CornerRadius
    {
        get { return _cornerRadius; }
        set { _cornerRadius = value; Invalidate(); }
    }

    public SRButton()
    {
        _fillColor = Color.FromArgb(41, 79, 130);
        _hoverColor = Color.FromArgb(34, 69, 115);
        _pressedColor = Color.FromArgb(27, 56, 93);
        _outlineColor = Color.Empty;
        _cornerRadius = 6;
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.UserPaint, true);
        FlatStyle = FlatStyle.Flat;
        FlatAppearance.BorderSize = 0;
        Cursor = Cursors.Hand;
        Font = new Font("Segoe UI Semibold", 9.25f, FontStyle.Regular, GraphicsUnit.Point);
        UseVisualStyleBackColor = false;
        ForeColor = Color.White;
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        Color parentColor = Parent != null ? Parent.BackColor : Color.White;
        e.Graphics.Clear(parentColor);
        Color fill = !Enabled ? Color.FromArgb(244, 246, 248) : (_pressed ? _pressedColor : (_hover ? _hoverColor : _fillColor));
        Rectangle rect = new Rectangle(0, 0, Width - 1, Height - 1);
        using (GraphicsPath path = CreateRoundRect(rect, _cornerRadius))
        using (SolidBrush brush = new SolidBrush(fill))
        {
            e.Graphics.FillPath(brush, path);
            if (!_outlineColor.IsEmpty)
            {
                using (Pen pen = new Pen(_outlineColor))
                {
                    e.Graphics.DrawPath(pen, path);
                }
            }
        }
        Color textColor = Enabled ? ForeColor : Color.FromArgb(139, 148, 158);
        TextRenderer.DrawText(e.Graphics, Text, Font, rect, textColor, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis);
        if (Focused)
        {
            ControlPaint.DrawFocusRectangle(e.Graphics, Rectangle.Inflate(rect, -4, -4), textColor, fill);
        }
    }

    protected override void OnMouseEnter(EventArgs e)
    {
        _hover = true;
        Invalidate();
        base.OnMouseEnter(e);
    }

    protected override void OnMouseLeave(EventArgs e)
    {
        _hover = false;
        _pressed = false;
        Invalidate();
        base.OnMouseLeave(e);
    }

    protected override void OnMouseDown(MouseEventArgs e)
    {
        if (e.Button == MouseButtons.Left) { _pressed = true; Invalidate(); }
        base.OnMouseDown(e);
    }

    protected override void OnMouseUp(MouseEventArgs e)
    {
        _pressed = false;
        Invalidate();
        base.OnMouseUp(e);
    }

    protected override void OnEnabledChanged(EventArgs e)
    {
        Invalidate();
        base.OnEnabledChanged(e);
    }

    private static GraphicsPath CreateRoundRect(Rectangle rect, int radius)
    {
        GraphicsPath path = new GraphicsPath();
        int diameter = radius * 2;
        if (diameter > rect.Width) { diameter = rect.Width; }
        if (diameter > rect.Height) { diameter = rect.Height; }
        if (diameter <= 0)
        {
            path.AddRectangle(rect);
            return path;
        }
        path.AddArc(rect.X, rect.Y, diameter, diameter, 180, 90);
        path.AddArc(rect.Right - diameter, rect.Y, diameter, diameter, 270, 90);
        path.AddArc(rect.Right - diameter, rect.Bottom - diameter, diameter, diameter, 0, 90);
        path.AddArc(rect.X, rect.Bottom - diameter, diameter, diameter, 90, 90);
        path.CloseFigure();
        return path;
    }
}
'@ -ReferencedAssemblies 'System.Windows.Forms', 'System.Drawing'
}

$script:rsSnapshotEntries = $snapshotEntries
$script:rsUpdating = $false
$script:rsRestoring = $false

$rsInk = [System.Drawing.Color]::FromArgb(32, 37, 43)
$rsMuted = [System.Drawing.Color]::FromArgb(91, 101, 112)
$rsLine = [System.Drawing.Color]::FromArgb(224, 229, 233)
$rsSoft = [System.Drawing.Color]::FromArgb(244, 246, 248)
$rsAccent = [System.Drawing.Color]::FromArgb(41, 79, 130)
$rsAccentHover = [System.Drawing.Color]::FromArgb(34, 69, 115)
$rsAccentPressed = [System.Drawing.Color]::FromArgb(27, 56, 93)
$rsWhite = [System.Drawing.Color]::White

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Session Recovery'
$form.ClientSize = New-Object System.Drawing.Size(900, 700)
$form.MinimumSize = New-Object System.Drawing.Size(820, 640)
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$form.BackColor = $rsWhite
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

$accentBar = New-Object System.Windows.Forms.Panel
$accentBar.Location = New-Object System.Drawing.Point(0, 0)
$accentBar.Size = New-Object System.Drawing.Size(900, 4)
$accentBar.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$accentBar.BackColor = $rsAccent
$form.Controls.Add($accentBar)

$header = New-Object System.Windows.Forms.Panel
$header.Location = New-Object System.Drawing.Point(0, 4)
$header.Size = New-Object System.Drawing.Size(900, 120)
$header.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$header.BackColor = $rsWhite
$header.Add_Paint({
    param($sender, $e)
    $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(224, 229, 233))
    try {
        $e.Graphics.DrawLine($pen, 0, $sender.Height - 1, $sender.Width, $sender.Height - 1)
    } finally {
        $pen.Dispose()
    }
})
$form.Controls.Add($header)

$brandLogo = New-Object System.Windows.Forms.PictureBox
$brandLogo.Location = New-Object System.Drawing.Point(34, 18)
$brandLogo.Size = New-Object System.Drawing.Size(36, 36)
$brandLogo.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
$brandLogo.BackColor = $rsWhite
if ($brandImage) { $brandLogo.Image = $brandImage } else { $brandLogo.Visible = $false }
$header.Controls.Add($brandLogo)

$brandName = New-Object System.Windows.Forms.Label
$brandName.Text = 'SESSION RECOVERY'
$brandName.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10.5)
$brandName.ForeColor = $rsInk
$brandName.AutoSize = $true
$brandName.Location = New-Object System.Drawing.Point(80, 18)
$header.Controls.Add($brandName)

$brandMeta = New-Object System.Windows.Forms.Label
$brandMeta.Text = 'LOCAL SNAPSHOTS  /  V2.6.1'
$brandMeta.Font = New-Object System.Drawing.Font('Consolas', 7.5)
$brandMeta.ForeColor = $rsMuted
$brandMeta.AutoSize = $true
$brandMeta.Location = New-Object System.Drawing.Point(82, 39)
$header.Controls.Add($brandMeta)

$privacyLabel = New-Object System.Windows.Forms.Label
$privacyLabel.Text = 'LOCAL ONLY  /  NO CLOUD'
$privacyLabel.Font = New-Object System.Drawing.Font('Consolas', 8)
$privacyLabel.ForeColor = $rsMuted
$privacyLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
$privacyLabel.AutoSize = $false
$privacyLabel.Size = New-Object System.Drawing.Size(260, 24)
$privacyLabel.Location = New-Object System.Drawing.Point(606, 26)
$privacyLabel.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$header.Controls.Add($privacyLabel)

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Text = (T 'RstTitle' 'Restore your previous session')
$titleLabel.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 20)
$titleLabel.ForeColor = $rsInk
$titleLabel.AutoSize = $false
$titleLabel.Size = New-Object System.Drawing.Size(830, 36)
$titleLabel.AutoEllipsis = $true
$titleLabel.Location = New-Object System.Drawing.Point(34, 62)
$titleLabel.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$header.Controls.Add($titleLabel)

$subtitleLabel = New-Object System.Windows.Forms.Label
$subtitleLabel.Text = (T 'RstSubtitle' 'Choose what to reopen. Everything stays on this PC.')
try {
    # A plain-language crash reason replaces guesswork in the header.
    $shutdownInfo = Get-SRLastShutdownReason
    if ([string]$shutdownInfo.Kind -eq 'crash' -and -not [string]::IsNullOrWhiteSpace([string]$shutdownInfo.Reason)) {
        $reasonText = Format-SRShutdownReason -Shutdown $shutdownInfo -Strings $script:RestoreStrings
        $subtitleLabel.Text = ((T 'RstShutdownReason' 'Windows stopped unexpectedly: {0}') -f $reasonText)
        $subtitleLabel.ForeColor = [System.Drawing.Color]::FromArgb(176, 48, 66)
    }
} catch { }
$subtitleLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
$subtitleLabel.ForeColor = $rsMuted
# Long crash reasons in any language must ellipsize inside the header band
# instead of running over the snapshot card below it.
$subtitleLabel.AutoSize = $false
$subtitleLabel.Size = New-Object System.Drawing.Size(830, 20)
$subtitleLabel.AutoEllipsis = $true
$subtitleLabel.Location = New-Object System.Drawing.Point(36, 97)
$subtitleLabel.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$header.Controls.Add($subtitleLabel)

# Right-to-left languages get correctly shaped, right-aligned text. Layout
# mirroring is intentionally not used: it scrambles custom-painted controls.
try {
    if (Test-SRRtlLanguage -Language $restoreLanguage) {
        $form.RightToLeft = [System.Windows.Forms.RightToLeft]::Yes
    }
} catch { }

$content = New-Object System.Windows.Forms.Panel
$content.Location = New-Object System.Drawing.Point(0, 124)
$content.Size = New-Object System.Drawing.Size(900, 576)
$content.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$content.BackColor = $rsSoft
$form.Controls.Add($content)

$snapshotCard = New-Object SRCardPanel
$snapshotCard.Location = New-Object System.Drawing.Point(32, 18)
$snapshotCard.Size = New-Object System.Drawing.Size(836, 68)
$snapshotCard.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$content.Controls.Add($snapshotCard)

$snapshotLabel = New-Object System.Windows.Forms.Label
$snapshotLabel.Text = 'SNAPSHOT'
$snapshotLabel.Font = New-Object System.Drawing.Font('Consolas', 7.5)
$snapshotLabel.ForeColor = $rsMuted
$snapshotLabel.BackColor = $rsWhite
$snapshotLabel.AutoSize = $true
$snapshotLabel.Location = New-Object System.Drawing.Point(18, 11)
$snapshotCard.Controls.Add($snapshotLabel)

$snapshotCombo = New-Object System.Windows.Forms.ComboBox
$snapshotCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$snapshotCombo.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$snapshotCombo.IntegralHeight = $false
$snapshotCombo.Font = New-Object System.Drawing.Font('Segoe UI', 9.25)
$snapshotCombo.ForeColor = $rsInk
$snapshotCombo.BackColor = $rsWhite
$snapshotCombo.Location = New-Object System.Drawing.Point(18, 30)
$snapshotCombo.Size = New-Object System.Drawing.Size(600, 26)
$snapshotCard.Controls.Add($snapshotCombo)

$ageLabel = New-Object System.Windows.Forms.Label
$ageLabel.Text = ''
$ageLabel.Font = New-Object System.Drawing.Font('Consolas', 8.25)
$ageLabel.ForeColor = $rsMuted
$ageLabel.BackColor = $rsWhite
$ageLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
$ageLabel.AutoSize = $false
$ageLabel.Size = New-Object System.Drawing.Size(180, 24)
$ageLabel.AutoEllipsis = $true
$ageLabel.Location = New-Object System.Drawing.Point(636, 32)
$ageLabel.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$snapshotCard.Controls.Add($ageLabel)

$listCard = New-Object SRCardPanel
$listCard.Location = New-Object System.Drawing.Point(32, 98)
$listCard.Size = New-Object System.Drawing.Size(836, 300)
$listCard.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$content.Controls.Add($listCard)

$listHeading = New-Object System.Windows.Forms.Label
$listHeading.Text = (T 'RstItems' 'ITEMS TO REOPEN')
$listHeading.Font = New-Object System.Drawing.Font('Consolas', 7.5)
$listHeading.ForeColor = $rsMuted
$listHeading.BackColor = $rsWhite
$listHeading.AutoSize = $true
$listHeading.Location = New-Object System.Drawing.Point(18, 12)
$listCard.Controls.Add($listHeading)

$selectAll = New-Object System.Windows.Forms.CheckBox
$selectAll.Text = (T 'RstSelectAll' 'Select all')
$selectAll.Checked = $true
$selectAll.AutoSize = $false
$selectAll.Size = New-Object System.Drawing.Size(94, 22)
$selectAll.Location = New-Object System.Drawing.Point(724, 8)
$selectAll.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$selectAll.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$selectAll.ForeColor = $rsInk
$selectAll.BackColor = $rsWhite
$listCard.Controls.Add($selectAll)

$listRule = New-Object System.Windows.Forms.Panel
$listRule.Location = New-Object System.Drawing.Point(18, 38)
$listRule.Size = New-Object System.Drawing.Size(800, 1)
$listRule.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$listRule.BackColor = $rsLine
$listCard.Controls.Add($listRule)

$itemHeader = New-Object System.Windows.Forms.Label
$itemHeader.Text = 'ITEM'
$itemHeader.Font = New-Object System.Drawing.Font('Consolas', 7.5)
$itemHeader.ForeColor = $rsMuted
$itemHeader.BackColor = $rsWhite
$itemHeader.AutoSize = $true
$itemHeader.Location = New-Object System.Drawing.Point(18, 46)
$listCard.Controls.Add($itemHeader)

$detailsHeader = New-Object System.Windows.Forms.Label
$detailsHeader.Text = (T 'RstDetails' 'DETAILS')
$detailsHeader.Font = New-Object System.Drawing.Font('Consolas', 7.5)
$detailsHeader.ForeColor = $rsMuted
$detailsHeader.BackColor = $rsWhite
$detailsHeader.AutoSize = $true
$detailsHeader.Location = New-Object System.Drawing.Point(306, 46)
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
$list.BackColor = $rsWhite
$list.ForeColor = $rsInk
$list.Font = New-Object System.Drawing.Font('Segoe UI', 9.25)
$list.Location = New-Object System.Drawing.Point(18, 66)
$list.Size = New-Object System.Drawing.Size(800, 220)
$list.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$rowImages = New-Object System.Windows.Forms.ImageList
$rowImages.ImageSize = New-Object System.Drawing.Size(20, 20)
$rowImages.ColorDepth = [System.Windows.Forms.ColorDepth]::Depth32Bit
$rowImages.TransparentColor = [System.Drawing.Color]::Transparent
[void]$rowImages.Images.Add((New-Object System.Drawing.Bitmap(20, 20)))
[void]$rowImages.Images.Add((New-RSFolderIconBitmap))
$list.SmallImageList = $rowImages
$script:rsRowImages = $rowImages
$script:rsIconCache = @{}
[void]$list.Columns.Add('Item', 288)
[void]$list.Columns.Add('Details', 500)
$list.Add_Resize({
    if ($list.Columns.Count -lt 2) { return }
    $available = [Math]::Max(300, $list.ClientSize.Width)
    $first = [int]($available * 0.36)
    $list.Columns[0].Width = $first
    $list.Columns[1].Width = [Math]::Max(140, $available - $first - 4)
    $detailsHeader.Left = $list.Left + $first
})
$listCard.Controls.Add($list)

$optionsCard = New-Object SRCardPanel
$optionsCard.Location = New-Object System.Drawing.Point(32, 410)
$optionsCard.Size = New-Object System.Drawing.Size(836, 88)
$optionsCard.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$content.Controls.Add($optionsCard)

$optionsHeading = New-Object System.Windows.Forms.Label
$optionsHeading.Text = (T 'RstOptions' 'RESTORE OPTIONS')
$optionsHeading.Font = New-Object System.Drawing.Font('Consolas', 7.5)
$optionsHeading.ForeColor = $rsMuted
$optionsHeading.BackColor = $rsWhite
$optionsHeading.AutoSize = $true
$optionsHeading.Location = New-Object System.Drawing.Point(18, 10)
$optionsCard.Controls.Add($optionsHeading)

$tabModeLabel = New-Object System.Windows.Forms.Label
$tabModeLabel.Text = (T 'RstBrowserTabs' 'Browser tabs')
$tabModeLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$tabModeLabel.ForeColor = $rsInk
$tabModeLabel.BackColor = $rsWhite
$tabModeLabel.AutoSize = $true
$tabModeLabel.Location = New-Object System.Drawing.Point(18, 37)
$optionsCard.Controls.Add($tabModeLabel)

$tabModeCombo = New-Object System.Windows.Forms.ComboBox
$tabModeCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$tabModeCombo.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$tabModeCombo.IntegralHeight = $false
$tabModeCombo.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$tabModeCombo.ForeColor = $rsInk
$tabModeCombo.BackColor = $rsWhite
$tabModeCombo.Location = New-Object System.Drawing.Point(116, 33)
$tabModeCombo.Size = New-Object System.Drawing.Size(410, 26)
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

$forceCheck = New-Object System.Windows.Forms.CheckBox
$forceCheck.Text = (T 'RstStartAnyway' 'Start applications even when they are already running')
$forceCheck.AutoSize = $true
$forceCheck.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$forceCheck.ForeColor = $rsInk
$forceCheck.BackColor = $rsWhite
$forceCheck.Location = New-Object System.Drawing.Point(18, 61)
$optionsCard.Controls.Add($forceCheck)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = ''
$statusLabel.AutoSize = $false
$statusLabel.Size = New-Object System.Drawing.Size(540, 30)
$statusLabel.AutoEllipsis = $true
$statusLabel.Font = New-Object System.Drawing.Font('Consolas', 8.5)
$statusLabel.ForeColor = $rsMuted
$statusLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$statusLabel.Location = New-Object System.Drawing.Point(34, 510)
$statusLabel.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
$content.Controls.Add($statusLabel)

$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Location = New-Object System.Drawing.Point(34, 501)
$progressBar.Size = New-Object System.Drawing.Size(520, 7)
$progressBar.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
$progressBar.Minimum = 0
$progressBar.Maximum = 100
$progressBar.Visible = $false
$content.Controls.Add($progressBar)

$skipButton = New-Object SRButton
$skipButton.Text = 'Skip'
$skipButton.Size = New-Object System.Drawing.Size(110, 40)
$skipButton.Location = New-Object System.Drawing.Point(586, 506)
$skipButton.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
$skipButton.FillColor = $rsWhite
$skipButton.HoverColor = $rsSoft
$skipButton.PressedColor = $rsLine
$skipButton.OutlineColor = $rsLine
$skipButton.ForeColor = $rsInk
$skipButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
$content.Controls.Add($skipButton)

$restoreButton = New-Object SRButton
$restoreButton.Text = (T 'RstRestoreSelected' 'Restore selected')
$restoreButton.Size = New-Object System.Drawing.Size(160, 40)
$restoreButton.Location = New-Object System.Drawing.Point(708, 506)
$restoreButton.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
$restoreButton.FillColor = $rsAccent
$restoreButton.HoverColor = $rsAccentHover
$restoreButton.PressedColor = $rsAccentPressed
$restoreButton.OutlineColor = $rsAccent
$restoreButton.ForeColor = $rsWhite
$content.Controls.Add($restoreButton)

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
        $statusLabel.Text = ('{0} apps  /  {1} folders  /  {2} browsers  /  {3} tabs' -f $stats.Apps, $stats.Folders, $stats.Browsers, $stats.Tabs)
        $selectAll.Checked = $true
        # Restore preview: what is already running versus what would start.
        try {
            $preview = Get-SRRestorePreview -Plan (New-SRRestorePlan -Snapshot $selected.Snapshot -All -TabMode 'Smart')
            if ($preview.Running -gt 0) {
                $statusLabel.Text += ('  |  {0} running, {1} to start' -f $preview.Running, $preview.WillStart)
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
        $programLines = @($selectedApps | ForEach-Object { '{0}  —  {1}' -f [string]$_.name, [string]$_.exe })
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
