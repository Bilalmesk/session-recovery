#requires -Version 5.1
<#
    Restore-Session.ps1
    Shows the restore prompt after an unexpected shutdown, or restores a
    snapshot on demand (Start Menu shortcut uses -Manual).

    Parameters
      -Manual       Always show the UI, even after a clean shutdown.
      -NoUI         Restore everything without showing a window.
      -DryRun       Print what would be restored and exit.
      -Force        Start apps even when they are already running.
      -SnapshotPath Use a specific snapshot JSON file.
      -TabMode      Smart (default), Captured, Native or None.
      -MaxAgeHours  Override the configured maximum snapshot age.
#>
[CmdletBinding()]
param(
    [switch]$Manual,
    [switch]$NoUI,
    [switch]$Force,
    [switch]$DryRun,
    [string]$SnapshotPath,
    [ValidateSet('Smart', 'Captured', 'Native', 'None')][string]$TabMode,
    [int]$MaxAgeHours = 0,
    [int]$StartupDelaySeconds = 0
)

$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'SessionRecovery.psm1'
Import-Module $modulePath -Force -ErrorAction Stop

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
        $Value
    )
    $item = New-Object System.Windows.Forms.ListViewItem($Name)
    [void]$item.SubItems.Add($Details)
    $item.Tag = [pscustomobject]@{ Kind = $Kind; Value = $Value }
    $item.Checked = $true
    [void]$List.Items.Add($item)
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
            $titles = @($app.windows | ForEach-Object { [string]$_.title } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            $details = 'Application'
            if ($titles.Count -gt 0) {
                $details = $titles[0]
                if ($titles.Count -gt 1) { $details += (' (+{0} more window(s))' -f ($titles.Count - 1)) }
            }
            Add-RSListItem -List $List -Kind 'app' -Name $name -Details $details -Value $app
        }

        foreach ($folder in @($Snapshot.explorer)) {
            if ([string]::IsNullOrWhiteSpace([string]$folder)) { continue }
            Add-RSListItem -List $List -Kind 'folder' -Name ([string]$folder) -Details 'File Explorer folder' -Value ([string]$folder)
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
            Add-RSListItem -List $List -Kind 'browser' -Name ([string]$browser.name) -Details $details -Value $browser
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
    if ($Manual) {
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

if ($DryRun) {
    $stats = Get-RSStats -Snapshot $entry.Snapshot
    Write-Output ('Snapshot: {0}' -f $entry.Path)
    Write-Output ('Captured: {0} ({1})' -f $entry.CapturedAt.ToString('g'), (Format-RSAge -CapturedAt $entry.CapturedAt))
    Write-Output ('Contents: {0} app(s), {1} folder(s), {2} browser(s), {3} tab(s)' -f $stats.Apps, $stats.Folders, $stats.Browsers, $stats.Tabs)
    Write-Output ('Tab mode: {0}' -f $TabMode)
    foreach ($app in @($planAll.apps)) { Write-Output ('APP    {0}  [{1}]' -f $app.name, $app.exe) }
    foreach ($folder in @($planAll.explorer)) { Write-Output ('FOLDER {0}' -f $folder) }
    foreach ($browser in @($planAll.browsers)) {
        foreach ($profile in @($browser.profiles)) {
            Write-Output ('TABS   {0} / {1}: {2}' -f $browser.name, $profile.displayName, @($profile.tabs).Count)
        }
    }
    exit 0
}

# ---------------------------------------------------------------------------
# Non-interactive restore
# ---------------------------------------------------------------------------

if ($NoUI -or -not [Environment]::UserInteractive) {
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

$script:rsSnapshotEntries = $snapshotEntries
$script:rsUpdating = $false

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Session Recovery'
$form.ClientSize = New-Object System.Drawing.Size(820, 650)
$form.MinimumSize = New-Object System.Drawing.Size(760, 560)
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$form.BackColor = [System.Drawing.Color]::White
$form.ShowInTaskbar = $true

$header = New-Object System.Windows.Forms.Panel
$header.Location = New-Object System.Drawing.Point(0, 0)
$header.Size = New-Object System.Drawing.Size(820, 92)
$header.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$header.BackColor = [System.Drawing.Color]::FromArgb(246, 248, 251)
$form.Controls.Add($header)

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Text = 'Restore your previous session'
$titleLabel.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 17)
$titleLabel.ForeColor = [System.Drawing.Color]::FromArgb(24, 30, 38)
$titleLabel.AutoSize = $true
$titleLabel.Location = New-Object System.Drawing.Point(20, 14)
$header.Controls.Add($titleLabel)

$subtitleLabel = New-Object System.Windows.Forms.Label
$subtitleLabel.Text = 'Select the windows and tabs you want to reopen.'
$subtitleLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$subtitleLabel.ForeColor = [System.Drawing.Color]::FromArgb(88, 96, 108)
$subtitleLabel.AutoSize = $true
$subtitleLabel.Location = New-Object System.Drawing.Point(22, 52)
$header.Controls.Add($subtitleLabel)

$content = New-Object System.Windows.Forms.Panel
$content.Location = New-Object System.Drawing.Point(0, 92)
$content.Size = New-Object System.Drawing.Size(820, 558)
$content.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($content)

$snapshotLabel = New-Object System.Windows.Forms.Label
$snapshotLabel.Text = 'Snapshot:'
$snapshotLabel.AutoSize = $true
$snapshotLabel.Location = New-Object System.Drawing.Point(20, 18)
$content.Controls.Add($snapshotLabel)

$snapshotCombo = New-Object System.Windows.Forms.ComboBox
$snapshotCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$snapshotCombo.Location = New-Object System.Drawing.Point(86, 14)
$snapshotCombo.Width = 540
$content.Controls.Add($snapshotCombo)

$ageLabel = New-Object System.Windows.Forms.Label
$ageLabel.AutoSize = $true
$ageLabel.ForeColor = [System.Drawing.Color]::FromArgb(88, 96, 108)
$ageLabel.Location = New-Object System.Drawing.Point(636, 18)
$content.Controls.Add($ageLabel)

$selectAll = New-Object System.Windows.Forms.CheckBox
$selectAll.Text = 'Select all'
$selectAll.Checked = $true
$selectAll.AutoSize = $true
$selectAll.Location = New-Object System.Drawing.Point(20, 48)
$content.Controls.Add($selectAll)

$list = New-Object System.Windows.Forms.ListView
$list.View = [System.Windows.Forms.View]::Details
$list.CheckBoxes = $true
$list.FullRowSelect = $true
$list.GridLines = $false
$list.HideSelection = $false
$list.MultiSelect = $true
$list.Location = New-Object System.Drawing.Point(20, 76)
$list.Size = New-Object System.Drawing.Size(780, 320)
$list.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
[void]$list.Columns.Add('Item', 300)
[void]$list.Columns.Add('Details', 455)
$content.Controls.Add($list)

$optionsPanel = New-Object System.Windows.Forms.Panel
$optionsPanel.Location = New-Object System.Drawing.Point(20, 408)
$optionsPanel.Size = New-Object System.Drawing.Size(780, 86)
$optionsPanel.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$content.Controls.Add($optionsPanel)

$tabModeLabel = New-Object System.Windows.Forms.Label
$tabModeLabel.Text = 'Browser tabs:'
$tabModeLabel.AutoSize = $true
$tabModeLabel.Location = New-Object System.Drawing.Point(0, 7)
$optionsPanel.Controls.Add($tabModeLabel)

$tabModeCombo = New-Object System.Windows.Forms.ComboBox
$tabModeCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$tabModeCombo.Location = New-Object System.Drawing.Point(94, 3)
$tabModeCombo.Width = 360
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
$optionsPanel.Controls.Add($tabModeCombo)

$forceCheck = New-Object System.Windows.Forms.CheckBox
$forceCheck.Text = 'Start applications even when they are already running'
$forceCheck.AutoSize = $true
$forceCheck.Location = New-Object System.Drawing.Point(0, 40)
$optionsPanel.Controls.Add($forceCheck)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = ''
$statusLabel.AutoSize = $false
$statusLabel.Size = New-Object System.Drawing.Size(500, 24)
$statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(88, 96, 108)
$statusLabel.Location = New-Object System.Drawing.Point(20, 516)
$statusLabel.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
$content.Controls.Add($statusLabel)

$skipButton = New-Object System.Windows.Forms.Button
$skipButton.Text = 'Skip'
$skipButton.Size = New-Object System.Drawing.Size(110, 32)
$skipButton.Location = New-Object System.Drawing.Point(550, 512)
$skipButton.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
$skipButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
$content.Controls.Add($skipButton)

$restoreButton = New-Object System.Windows.Forms.Button
$restoreButton.Text = 'Restore selected'
$restoreButton.Size = New-Object System.Drawing.Size(140, 32)
$restoreButton.Location = New-Object System.Drawing.Point(665, 512)
$restoreButton.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
$content.Controls.Add($restoreButton)

$form.AcceptButton = $restoreButton
$form.CancelButton = $skipButton

function Update-RSSelection {
    param([int]$Index)
    if ($Index -lt 0 -or $Index -ge $script:rsSnapshotEntries.Count) { return }
    $script:rsUpdating = $true
    try {
        $selected = $script:rsSnapshotEntries[$Index]
        Populate-RSList -List $list -Snapshot $selected.Snapshot
        $ageLabel.Text = Format-RSAge -CapturedAt $selected.CapturedAt
        $stats = Get-RSStats -Snapshot $selected.Snapshot
        $statusLabel.Text = ('{0} app(s), {1} folder(s), {2} browser(s), {3} tab(s) in this snapshot.' -f $stats.Apps, $stats.Folders, $stats.Browsers, $stats.Tabs)
        $selectAll.Checked = $true
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
})

$restoreButton.Add_Click({
    $entry = $script:rsSnapshotEntries[$snapshotCombo.SelectedIndex]
    $selectedApps = New-Object System.Collections.Generic.List[object]
    $selectedFolders = New-Object System.Collections.Generic.List[string]
    $selectedBrowsers = New-Object System.Collections.Generic.List[object]

    foreach ($item in $list.CheckedItems) {
        $tag = $item.Tag
        if ($null -eq $tag) { continue }
        switch ([string]$tag.Kind) {
            'app' { $selectedApps.Add($tag.Value) }
            'folder' { $selectedFolders.Add([string]$tag.Value) }
            'browser' { $selectedBrowsers.Add($tag.Value) }
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

    $plan = [pscustomobject]@{
        apps     = $selectedApps.ToArray()
        explorer = $selectedFolders.ToArray()
        browsers = $selectedBrowsers.ToArray()
        tabMode  = $mode
    }

    $restoreButton.Enabled = $false
    $skipButton.Enabled = $false
    $snapshotCombo.Enabled = $false
    $statusLabel.Text = 'Restoring...'
    [System.Windows.Forms.Application]::DoEvents()

    $results = @()
    $failure = $null
    try {
        Write-SRLog -Message ('Interactive restore started from {0} (tab mode {1}).' -f $entry.Path, $mode)
        $results = @(Invoke-SRRestore -Plan $plan -Force:$forceCheck.Checked)
        foreach ($result in $results) {
            $level = if ($result.Started) { 'INFO' } else { 'WARN' }
            Write-SRLog -Level $level -Message ([string]$result.Message)
        }
    } catch {
        $failure = $_.Exception.Message
        Write-SRLog -Level ERROR -Message "Interactive restore failed: $failure"
    }

    $form.Close()

    if ($failure) {
        Show-RSMessage -Text ("Restore failed:`r`n`r`n" + $failure) -Icon 'Error'
        return
    }

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($result in $results) {
        $prefix = if ($result.Started) { '[OK]   ' } else { '[SKIP] ' }
        $lines.Add($prefix + [string]$result.Message)
    }
    if ($lines.Count -eq 0) { $lines.Add('Nothing was restored.') }
    Show-RSMessage -Text ($lines -join "`r`n") -Icon 'Information'
})

$skipButton.Add_Click({
    Write-SRLog -Message 'Restore prompt was skipped by the user.'
    $form.Close()
})

Write-SRLog -Message ('Restore prompt shown for {0}.' -f $entry.Path)
[void]$form.ShowDialog()
$form.Dispose()
exit 0
