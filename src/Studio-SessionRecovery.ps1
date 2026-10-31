#requires -Version 5.1
<#
    Studio-SessionRecovery.ps1
    Session Recovery 2.2 control center.

    This script is normally launched by SessionRecovery.exe, the native GUI
    host. The host runs this file in-process on an STA thread, so there is no
    console window, no cmd.exe flash and no visible PowerShell host.
#>
[CmdletBinding()]
param(
    [ValidateSet('Dashboard', 'Snapshots', 'Exclusions', 'RecoveryKit', 'Settings', 'Diagnostics', 'About')]
    [string]$Page = 'Dashboard',
    [string]$RenderDir = ''
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$script:AppVersion = '2.8.1'
$script:ScriptDir = $PSScriptRoot
$script:AppDir = if ($env:SESSIONRECOVERY_HOST_EXE) { Split-Path -Parent $env:SESSIONRECOVERY_HOST_EXE } else { $PSScriptRoot }
$script:HostExe = $null
$script:IconPath = $null
$script:Config = $null
$script:Snapshots = @()
$script:SelectedSnapshotPath = $null
$script:Pages = [ordered]@{}
$script:NavButtons = @{}
$script:Ui = @{}
$script:UiReady = $false
# Render mode is used by the layout audit. Set it before the first sidebar
# refresh so audit runs are deterministic and always exercise the longest
# status text (no background app and no scheduled task) on any machine.
$script:RenderMode = -not [string]::IsNullOrWhiteSpace($RenderDir)
$script:CurrentPage = 'Dashboard'
$script:SettingsLoaded = $false
$script:ExclusionCards = @()
$script:LocalizedCombos = New-Object System.Collections.ArrayList
$script:SnapshotRows = @()
$script:ToastTimer = $null
$script:SnapshotsDirty = $true
$script:DashboardDirty = $true
$script:ExclusionsDirty = $true
$script:SnapshotNotes = @{}
$script:PrivacyFindings = @()
$script:PrivacyMap = @{}
$script:PrivacyScanLoading = $false
$script:KitBusy = $false
$script:DiagnosticsDirty = $true
$script:DiagnosticsLoading = $false
$script:DiagLoadingTimer = $null
$script:DiagPhase = 0
$script:DiagStartedAt = [datetime]::MinValue
$script:SharedWorkerRunspace = $null
$script:PageLoaded = @{}
$script:LastSnapFlowWidth = 0
$script:SnapshotBuildTimer = $null
$script:SnapshotDetailsTimer = $null
$script:SnapshotBuildQueue = @()
$script:SnapshotBuildIndex = 0
$script:SnapshotBuildWidth = 0
$script:StudioJobs = @{}
$script:StudioTaskTimer = $null
$script:UpdateBusy = $false
$script:UpdateAction = ''
$script:AvailableUpdate = $null
$script:DownloadedUpdate = $null
$script:UpdateInstalling = $false
$script:CaptureBusy = $false
$script:CapturePollTimer = $null
$script:CaptureState = $null

$modulePath = Join-Path $PSScriptRoot 'SessionRecovery.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    $modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'src\SessionRecovery.psm1'
}
if (-not (Test-Path -LiteralPath $modulePath)) {
    [System.Windows.Forms.MessageBox]::Show('SessionRecovery.psm1 is missing. Reinstall Session Recovery.', 'Session Recovery', 'OK', 'Error') | Out-Null
    exit 2
}
Import-Module $modulePath -Force

$controlsPath = Join-Path $PSScriptRoot 'StudioControls.cs'
if (-not (Test-Path -LiteralPath $controlsPath)) {
    $controlsPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'src\StudioControls.cs'
}
if (-not (Test-Path -LiteralPath $controlsPath)) {
    [System.Windows.Forms.MessageBox]::Show('StudioControls.cs is missing. Reinstall Session Recovery.', 'Session Recovery', 'OK', 'Error') | Out-Null
    exit 2
}
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
if (-not ('SessionRecovery.Studio.StudioCard' -as [type])) {
    Add-Type -Path $controlsPath -ReferencedAssemblies 'System.Windows.Forms', 'System.Drawing'
}

$hostCandidates = @()
if ($env:SESSIONRECOVERY_HOST_EXE) { $hostCandidates += $env:SESSIONRECOVERY_HOST_EXE }
$hostCandidates += (Join-Path $PSScriptRoot 'SessionRecovery.exe')
$hostCandidates += (Join-Path (Split-Path $PSScriptRoot -Parent) 'dist\SessionRecovery.exe')
$script:HostExe = $hostCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

$iconCandidates = @(
    (Join-Path $PSScriptRoot 'SessionRecovery.ico'),
    (Join-Path (Split-Path $PSScriptRoot -Parent) 'assets\SessionRecovery.ico')
)
$script:IconPath = $iconCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

if ($script:HostExe) {
    try {
        $fileVersion = (Get-Item -LiteralPath $script:HostExe).VersionInfo.FileVersion
        if (-not [string]::IsNullOrWhiteSpace($fileVersion)) {
            $match = [regex]::Match($fileVersion, '^\d+\.\d+\.\d+')
            if ($match.Success) { $script:AppVersion = $match.Value } else { $script:AppVersion = $fileVersion }
        }
    } catch { }
}

. (Join-Path $PSScriptRoot 'StudioTheme.ps1')

$studioTheme = 'Aurora'
try {
    $themeConfig = Get-SRConfig
    $themeProperty = $themeConfig.PSObject.Properties['theme']
    if ($null -ne $themeProperty -and -not [string]::IsNullOrWhiteSpace([string]$themeProperty.Value)) {
        $studioTheme = [string]$themeProperty.Value
    }
} catch { }
$script:ThemeKey = Resolve-StudioThemeKey -Theme $studioTheme
$script:ThemeList = @(Get-StudioThemeList)
$script:P = Get-StudioPalette -Theme $script:ThemeKey

# ---------------------------------------------------------------------------
# Localization
# ---------------------------------------------------------------------------

$stringsPath = Join-Path $PSScriptRoot 'Strings.ps1'
if (-not (Test-Path -LiteralPath $stringsPath)) {
    $stringsPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'src\Strings.ps1'
}
. $stringsPath

function Set-StudioLanguage {
    param([string]$Language)
    $script:Lang = 'en'
    try {
        if (-not [string]::IsNullOrWhiteSpace($Language)) { $script:Lang = ([string]$Language).ToLowerInvariant() }
    } catch { }
    $script:L = Get-SRStrings -Language $script:Lang
    $script:DateCulture = switch ($script:Lang) {
        'ar' { 'ar-EG' }
        'fr' { 'fr-FR' }
        'es' { 'es-ES' }
        'de' { 'de-DE' }
        'pt' { 'pt-PT' }
        'ru' { 'ru-RU' }
        'zh' { 'zh-CN' }
        'tr' { 'tr-TR' }
        default { 'en-US' }
    }
}

function Format-StudioDate {
    # Dates follow the selected UI language, not the Windows display language.
    param([datetime]$Date, [string]$Format)
    try {
        return $Date.ToString($Format, [System.Globalization.CultureInfo]::GetCultureInfo($script:DateCulture))
    } catch {
        return $Date.ToString($Format)
    }
}

function T {
    param([Parameter(Mandatory = $true)][string]$Key, [string]$Default = '')
    if ($script:L -and $script:L.ContainsKey($Key) -and -not [string]::IsNullOrWhiteSpace([string]$script:L[$Key])) {
        return [string]$script:L[$Key]
    }
    return $Default
}

function Localize-StudioString {
    # Translate one already-built English string when a translated key exists.
    param([string]$Text)
    if ($script:Lang -eq 'en' -or [string]::IsNullOrWhiteSpace($Text)) { return $Text }
    if ($script:L.ReverseLookup -and $script:L.ReverseLookup.ContainsKey($Text)) {
        return [string]$script:L.ReverseLookup[$Text]
    }
    return $Text
}

function Localize-StudioTexts {
    # One pass over the whole tree. The original English text is remembered on
    # each control, so switching fr -> de -> ar always starts from the English
    # source instead of trying to translate an already translated string.
    param($Control)
    if ($null -eq $Control) { return }
    $typeName = $Control.GetType().FullName
    $isTextBox = ($typeName -eq 'System.Windows.Forms.TextBox')
    if (-not $isTextBox) {
        $textProperty = $Control.PSObject.Properties['Text']
        if ($null -ne $textProperty) {
            $text = [string]$Control.Text
            $originProperty = $Control.PSObject.Properties['SROriginalText']
            if ($null -eq $originProperty) {
                $original = $text
                if (-not [string]::IsNullOrWhiteSpace($original)) {
                    $Control | Add-Member -NotePropertyName 'SROriginalText' -NotePropertyValue $original -Force
                }
            } else {
                $original = [string]$originProperty.Value
            }
            if (-not [string]::IsNullOrWhiteSpace($original)) {
                if ($script:Lang -eq 'en') {
                    if ($text -ne $original) { $Control.Text = $original }
                } elseif ($script:L.ReverseLookup.ContainsKey($original)) {
                    $translated = [string]$script:L.ReverseLookup[$original]
                    if ($text -ne $translated) { $Control.Text = $translated }
                }
            }
        }
    }
    # StudioRing paints its caption itself, so it is not covered by the Text
    # walk above. Remember the English caption and re-apply it on each
    # language change, including the dashboard and diagnostics rings.
    if ($typeName -eq 'SessionRecovery.Studio.StudioRing') {
        $captionProperty = $Control.PSObject.Properties['Caption']
        if ($null -ne $captionProperty) {
            $caption = [string]$captionProperty.Value
            $originProperty = $Control.PSObject.Properties['SROriginalCaption']
            if ($null -eq $originProperty) {
                $originalCaption = $caption
                if (-not [string]::IsNullOrWhiteSpace($originalCaption)) {
                    $Control | Add-Member -NotePropertyName 'SROriginalCaption' -NotePropertyValue $originalCaption -Force
                }
            } else {
                $originalCaption = [string]$originProperty.Value
            }
            if (-not [string]::IsNullOrWhiteSpace($originalCaption)) {
                if ($script:Lang -eq 'en') {
                    if ($caption -ne $originalCaption) { $Control.Caption = $originalCaption }
                } elseif ($script:L.ReverseLookup.ContainsKey($originalCaption)) {
                    $translatedCaption = [string]$script:L.ReverseLookup[$originalCaption]
                    if ($caption -ne $translatedCaption) { $Control.Caption = $translatedCaption }
                }
            }
        }
    }
    foreach ($child in @($Control.Controls)) { Localize-StudioTexts -Control $child }
}

function Set-StudioLocalizedCombo {
    # ComboBox items are not part of the control tree walk. Remember the key
    # list so a live language change can rebuild the visible labels without
    # touching the selected index (which is what settings actually save).
    param($Combo, [string[]]$Keys, [string[]]$Defaults)
    if ($null -eq $Combo) { return }
    if ($null -eq $script:LocalizedCombos) { $script:LocalizedCombos = New-Object System.Collections.ArrayList }
    $entry = @{ Combo = $Combo; Keys = @($Keys); Defaults = @($Defaults) }
    [void]$script:LocalizedCombos.Add($entry)
    $selected = $Combo.SelectedIndex
    $Combo.BeginUpdate()
    try {
        $Combo.Items.Clear()
        for ($index = 0; $index -lt $Keys.Count; $index++) {
            $fallback = if ($index -lt $Defaults.Count) { [string]$Defaults[$index] } else { '' }
            [void]$Combo.Items.Add((T $Keys[$index] $fallback))
        }
        if ($selected -ge 0 -and $selected -lt $Combo.Items.Count) { $Combo.SelectedIndex = $selected }
    } finally {
        $Combo.EndUpdate()
    }
}

function Update-StudioLocalizedCombos {
    foreach ($entry in @($script:LocalizedCombos)) {
        if ($null -eq $entry -or $null -eq $entry.Combo) { continue }
        $combo = $entry.Combo
        $selected = $combo.SelectedIndex
        $combo.BeginUpdate()
        try {
            $combo.Items.Clear()
            for ($index = 0; $index -lt $entry.Keys.Count; $index++) {
                $fallback = if ($index -lt $entry.Defaults.Count) { [string]$entry.Defaults[$index] } else { '' }
                [void]$combo.Items.Add((T ([string]$entry.Keys[$index]) $fallback))
            }
            if ($selected -ge 0 -and $selected -lt $combo.Items.Count) { $combo.SelectedIndex = $selected }
        } finally {
            $combo.EndUpdate()
        }
    }
}

function Update-StudioPlaceholders {
    # TextBox placeholders are not translated by the tree walk because the box
    # may contain user input. Only rebuild the visible placeholder when the
    # placeholder tag is still active.
    if ($script:Ui -and $script:Ui.SnapSearch -and $script:Ui.SnapSearch.Tag -eq 'placeholder') {
        $script:Ui.SnapSearch.Text = (T 'SearchPlaceholder' 'Search apps, folders, tabs')
    }
    $script:ExclusionPlaceholders = @{
        excludeApps    = (T 'ExclAppPlaceholder' 'e.g. steam.exe or *game*')
        excludeFolders = (T 'ExclFolderPlaceholder' 'e.g. C:\Projects\Private')
        excludeUrls    = (T 'ExclUrlPlaceholder' 'e.g. *bank* or https://mail.example.com/*')
    }
    foreach ($card in @($script:ExclusionCards)) {
        if ($null -eq $card) { continue }
        $context = $card.Tag
        if ($null -eq $context -or $null -eq $context.Input) { continue }
        if ($context.Input.Tag -eq 'placeholder') {
            $context.Input.Text = [string]$script:ExclusionPlaceholders[[string]$context.Input.AccessibleName]
        }
    }
}

function Initialize-StudioLanguage {
    param([string]$Language, $Root)
    Set-StudioLanguage -Language $Language
    # Reverse map for the tree walk: English source text -> translation.
    $reverse = @{}
    $english = Get-SRStrings -Language 'en'
    foreach ($key in @($english.Keys)) {
        $translated = [string]$script:L[$key]
        $source = [string]$english[$key]
        if (-not [string]::IsNullOrWhiteSpace($source) -and -not [string]::IsNullOrWhiteSpace($translated)) {
            $reverse[$source] = $translated
        }
    }
    $script:L.ReverseLookup = $reverse
    if ($null -ne $Root) {
        try {
            # Arabic/Hebrew characters are shaped correctly by GDI even when
            # the control reads left-to-right. Do NOT switch the form to
            # RightToLeft: the window is a collection of fixed-position,
            # custom-painted LTR cards, and WinForms only mirrors the stock
            # labels and buttons. That split alignment pushed translated text
            # across neighbouring controls and clipped it at the opposite
            # edge, and it also reordered the split panels. Keeping every
            # control on the LTR layout grid preserves the design and still
            # renders connected Arabic script correctly.
            $Root.RightToLeft = [System.Windows.Forms.RightToLeft]::No
            $Root.RightToLeftLayout = $false
        } catch { }
        Localize-StudioTexts -Control $Root
    }
    Update-StudioLocalizedCombos
    Update-StudioPlaceholders
}

$studioLanguage = 'en'
try {
    $languageConfig = Get-SRConfig
    $languageProperty = $languageConfig.PSObject.Properties['language']
    if ($null -ne $languageProperty -and -not [string]::IsNullOrWhiteSpace([string]$languageProperty.Value)) {
        $studioLanguage = [string]$languageProperty.Value
    }
} catch { }
Set-StudioLanguage -Language $studioLanguage
$script:LanguageList = @(Get-SRLanguageList)

$script:FontBody = New-Object System.Drawing.Font('Segoe UI', 9)
$script:FontBodySmall = New-Object System.Drawing.Font('Segoe UI', 8.25)
$script:FontSemibold = New-Object System.Drawing.Font('Segoe UI Semibold', 9.5)
$script:FontSemiboldLarge = New-Object System.Drawing.Font('Segoe UI Semibold', 12)
$script:FontTitle = New-Object System.Drawing.Font('Segoe UI Semibold', 19)
$script:FontHero = New-Object System.Drawing.Font('Segoe UI Semibold', 25)
$script:FontMono = New-Object System.Drawing.Font('Consolas', 8.25)

[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

# ---------------------------------------------------------------------------
# Small UI helpers
# ---------------------------------------------------------------------------

function Set-StudioVerticalStack {
    # Stacks cards at an explicit Y position. FlowLayoutPanel depends on its
    # child collection order, and WinForms can silently reverse that order when
    # pages are hidden, shown and relaid out. Positioning each card ourselves
    # keeps the intended reading order stable on every Windows version.
    # Returns the card width so callers can size the text inside each card.
    param(
        $Panel,
        [object[]]$Cards,
        [int]$Padding = 24,
        [int]$BottomPadding = 24,
        [int]$MinWidth = 200
    )
    if ($null -eq $Panel -or $null -eq $Cards) { return 0 }

    $contentHeight = $Padding
    $gaps = @()
    $index = 0
    foreach ($card in $Cards) {
        if ($null -eq $card) { continue }
        $gap = if ($null -ne $card.Margin) { [Math]::Max(0, $card.Margin.Bottom) } else { 14 }
        $gaps += $gap
        $contentHeight += $card.Height + $gap
        $index++
    }
    if ($gaps.Count -gt 0) { $contentHeight = $contentHeight - $gaps[$gaps.Count - 1] + $BottomPadding }

    # Setting the virtual size first makes WinForms add the scrollbar (if one
    # is needed) before the width is measured, so cards never slide under it.
    $Panel.AutoScrollMinSize = New-Object System.Drawing.Size(0, [Math]::Max(0, $contentHeight))
    $Panel.PerformLayout()
    $available = [Math]::Max($MinWidth, $Panel.ClientSize.Width - ($Padding * 2))

    $top = $Padding
    $gapIndex = 0
    foreach ($card in $Cards) {
        if ($null -eq $card) { continue }
        $card.SetBounds($Padding, $top, $available, $card.Height)
        $top += $card.Height
        if ($gapIndex -lt $gaps.Count) { $top += $gaps[$gapIndex] }
        $gapIndex++
    }

    return $available
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
    # '&' is part of normal text here (for example "Data & support"), not a
    # keyboard mnemonic. Without this the ampersand disappeared and the next
    # character was underlined.
    $label.UseMnemonic = $false
    # Single-line labels ellipsize instead of wrapping: translated strings are
    # much longer than English (German, Russian, Arabic) and a wrapped second
    # line used to run underneath the next control. Taller labels are hints
    # that are meant to wrap, so anchor their text at the top instead of
    # centring it in the middle of the reserved box.
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
        # Accent gradients are bright in several themes; AccentText picks the
        # readable side (dark or white) per theme.
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

function New-StudioTextBox {
    param([int]$X = 0, [int]$Y = 0, [int]$Width = 220, [int]$Height = 28)
    $box = New-Object System.Windows.Forms.TextBox
    $box.Location = New-Object System.Drawing.Point($X, $Y)
    $box.Size = New-Object System.Drawing.Size($Width, $Height)
    $box.BackColor = $script:P.CardAlt
    $box.ForeColor = $script:P.Text
    $box.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $box.Font = $script:FontBody
    return $box
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

function Set-StudioStatus {
    param([string]$Text, [System.Drawing.Color]$Color = [System.Drawing.Color]::Empty)
    if ($script:Ui.StatusLabel) {
        $script:Ui.StatusLabel.Text = $Text
        $script:Ui.StatusLabel.ForeColor = if (-not $Color.IsEmpty) { $Color } else { $script:P.Muted }
        $script:Ui.StatusLabel.Visible = -not [string]::IsNullOrWhiteSpace($Text)
    }
}

function Show-StudioToast {
    param([string]$Text, [System.Drawing.Color]$Color = [System.Drawing.Color]::Empty)
    if (-not $script:Ui.Toast) { return }
    $script:Ui.Toast.Text = [string](Localize-StudioString $Text)
    $script:Ui.Toast.ForeColor = if (-not $Color.IsEmpty) { $Color } else { $script:P.Green }
    $script:Ui.Toast.Visible = $true
    if ($null -eq $script:ToastTimer) {
        $script:ToastTimer = New-Object System.Windows.Forms.Timer
        $script:ToastTimer.Interval = 4200
        $script:ToastTimer.Add_Tick({
            $script:ToastTimer.Stop()
            if ($script:Ui.Toast) { $script:Ui.Toast.Visible = $false }
        })
    }
    $script:ToastTimer.Stop()
    $script:ToastTimer.Start()
}

function Format-StudioAge {
    param([datetime]$CapturedAt)
    $span = (Get-Date) - $CapturedAt
    if ($span.TotalSeconds -lt 45) { return (T 'JustNow' 'just now') }
    if ($span.TotalMinutes -lt 60) { return ((T 'MinutesAgo' '{0} min ago') -f [Math]::Max(1, [int]$span.TotalMinutes)) }
    if ($span.TotalHours -lt 24) { return ((T 'HoursAgo' '{0} hr ago') -f [Math]::Max(1, [int]$span.TotalHours)) }
    if ($span.TotalDays -lt 7) { return ((T 'DaysAgo' '{0} day(s) ago') -f [Math]::Max(1, [int]$span.TotalDays)) }
    return Format-StudioDate -Date $CapturedAt -Format 'MMM d, HH:mm'
}

function Format-StudioNext {
    $config = $script:Config
    if ($null -eq $config) { return 'waiting for settings' }
    $interval = [Math]::Max(1, [int]$config.snapshotIntervalMinutes)
    if ($script:Snapshots.Count -eq 0) { return (T 'WithinFew' 'within a few minutes') }
    $latest = $script:Snapshots[0].CapturedAt
    $next = $latest.AddMinutes($interval)
    $remaining = $next - (Get-Date)
    if ($remaining.TotalSeconds -le 0) { return (T 'AnyMoment' 'any moment') }
    if ($remaining.TotalMinutes -lt 1) { return ((T 'InSeconds' 'in {0} sec') -f [Math]::Max(1, [int]$remaining.TotalSeconds)) }
    return ((T 'InMinutes' 'in {0} min') -f [Math]::Max(1, [int]$remaining.TotalMinutes))
}

function Format-StudioBytes {
    param([int64]$Bytes)
    if ($Bytes -lt 1024) { return ('{0} B' -f $Bytes) }
    if ($Bytes -lt 1048576) { return ('{0:N1} KB' -f ($Bytes / 1024.0)) }
    return ('{0:N1} MB' -f ($Bytes / 1048576.0))
}

function Enable-StudioDoubleBuffer {
    param($Control)
    if ($null -eq $Control) { return }
    try {
        $type = $Control.GetType()
        while ($null -ne $type) {
            $property = $type.GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'Instance,NonPublic')
            if ($null -ne $property) {
                $property.SetValue($Control, $true, $null)
                return
            }
            $type = $type.BaseType
        }
    } catch { }
}

function Enable-StudioDoubleBufferTree {
    # The custom controls opt in via SetStyle; plain panels and flow layouts
    # do not, and they are what flickers when pages switch or resize.
    param($Control)
    if ($null -eq $Control) { return }
    Enable-StudioDoubleBuffer -Control $Control
    foreach ($child in @($Control.Controls)) {
        Enable-StudioDoubleBufferTree -Control $child
    }
}

function Stop-StudioWorker {
    param([string]$Name)
    if (-not $script:StudioJobs.ContainsKey($Name)) { return }
    $job = $script:StudioJobs[$Name]
    try { if ($null -ne $job.PowerShell) { $job.PowerShell.Stop(); $job.PowerShell.Dispose() } } catch { }
    if ($job.OwnRunspace) {
        try { if ($null -ne $job.Runspace) { $job.Runspace.Close(); $job.Runspace.Dispose() } } catch { }
    }
    $script:StudioJobs.Remove($Name)
}

function Start-StudioWorker {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Script,
        [object[]]$Arguments = @(),
        # Run in a persistent shared runspace. The first job pays the module
        # import; later jobs reuse the warm runspace and start immediately.
        [switch]$SharedRunspace
    )
    Stop-StudioWorker -Name $Name
    $runspace = $null
    $ownRunspace = $true
    if ($SharedRunspace) {
        if ($null -eq $script:SharedWorkerRunspace) {
            $script:SharedWorkerRunspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
            $script:SharedWorkerRunspace.ApartmentState = [System.Threading.ApartmentState]::MTA
            $script:SharedWorkerRunspace.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
            $script:SharedWorkerRunspace.Open()
        }
        $runspace = $script:SharedWorkerRunspace
        $ownRunspace = $false
    } else {
        $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
        $runspace.ApartmentState = [System.Threading.ApartmentState]::MTA
        $runspace.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
        $runspace.Open()
    }
    $powershell = [System.Management.Automation.PowerShell]::Create()
    $powershell.Runspace = $runspace
    [void]$powershell.AddScript([string]$Script)
    foreach ($argument in $Arguments) { [void]$powershell.AddArgument($argument) }
    $handle = $powershell.BeginInvoke()
    $script:StudioJobs[$Name] = [pscustomobject]@{
        PowerShell  = $powershell
        Runspace    = $runspace
        Handle      = $handle
        OwnRunspace = $ownRunspace
    }
}

function Complete-StudioWorker {
    param([string]$Name)
    if (-not $script:StudioJobs.ContainsKey($Name)) { return $null }
    $job = $script:StudioJobs[$Name]
    if (-not $job.Handle.IsCompleted) { return $null }
    $output = @()
    $errorText = ''
    try {
        $output = @($job.PowerShell.EndInvoke($job.Handle))
        if ($job.PowerShell.Streams.Error.Count -gt 0) {
            $errorText = (@($job.PowerShell.Streams.Error | ForEach-Object { $_.ToString() }) -join "`r`n")
        }
    } catch {
        $errorText = $_.Exception.Message
    } finally {
        try { $job.PowerShell.Dispose() } catch { }
        if ($job.OwnRunspace) {
            try { $job.Runspace.Close(); $job.Runspace.Dispose() } catch { }
        }
        $script:StudioJobs.Remove($Name)
    }
    return [pscustomobject]@{ Output = $output; Error = $errorText }
}

function Update-StudioWorkers {
    $completed = @()
    foreach ($name in @($script:StudioJobs.Keys)) {
        $result = Complete-StudioWorker -Name $name
        if ($null -ne $result) { $completed += [pscustomobject]@{ Name = $name; Result = $result } }
    }
    foreach ($item in $completed) {
        switch ($item.Name) {
            'Diagnostics' { Complete-StudioDiagnosticsWorker -Result $item.Result }
            'Update' { Complete-StudioUpdateWorker -Result $item.Result }
            'PrivacyScan' { Complete-StudioPrivacyScanWorker -Result $item.Result }
        }
    }
}

function Get-StudioStats {
    param($Snapshot)
    if ($null -eq $Snapshot) {
        return [pscustomobject]@{ Apps = 0; Folders = 0; Browsers = 0; Tabs = 0 }
    }
    $apps = @($Snapshot.apps).Count
    $folders = @($Snapshot.explorer).Count
    $browsers = @($Snapshot.browsers).Count
    $tabs = 0
    foreach ($browser in @($Snapshot.browsers)) {
        foreach ($profile in @($browser.profiles)) {
            $tabs += @($profile.tabs).Count
        }
    }
    return [pscustomobject]@{ Apps = $apps; Folders = $folders; Browsers = $browsers; Tabs = $tabs }
}

function Get-StudioSnapshotBytes {
    param($Entry)
    if ($null -eq $Entry) { return 0 }
    try { return (Get-Item -LiteralPath $Entry.Path).Length } catch { return 0 }
}

function Open-StudioPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    try {
        if (Test-Path -LiteralPath $Path -PathType Container) {
            Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $Path) | Out-Null
        } else {
            Start-Process -FilePath $Path | Out-Null
        }
    } catch {
        Show-StudioToast ('Could not open: ' + $_.Exception.Message) $script:P.Red
    }
}

$script:TrayStateCache = $null
$script:TrayStateCacheAt = [datetime]::MinValue

function Format-StudioPath {
    # Keep long profile paths readable in the Settings card. The buttons still
    # open the real path; the label shows a stable, short form so the layout
    # audit does not depend on how deep the checkout or isolated home is.
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $display = $Path
    foreach ($pair in @(
        @{ Root = [Environment]::GetFolderPath('LocalApplicationData'); Token = '%LOCALAPPDATA%' },
        @{ Root = [Environment]::GetFolderPath('UserProfile'); Token = '%USERPROFILE%' }
    )) {
        $root = [string]$pair.Root
        if (-not [string]::IsNullOrWhiteSpace($root) -and
            $display.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
            $display = $pair.Token + $display.Substring($root.Length)
            break
        }
    }
    if ($display.Length -gt 90) {
        $display = $display.Substring(0, 42) + [char]0x2026 + $display.Substring($display.Length - 45)
    }
    return $display
}

# Map the English background-status mode to the current language. The state
# object itself keeps English values so diagnostics JSON stays stable.
function Get-StudioModeText {
    param([string]$Mode)
    switch ($Mode) {
        'Scheduled tasks + tray' { return (T 'ModeScheduledTray' 'Scheduled tasks + tray') }
        'Scheduled tasks' { return (T 'ModeScheduled' 'Scheduled tasks') }
        'Background tray' { return (T 'ModeTrayOnly' 'Background tray') }
        'Startup watcher' { return (T 'ModeStartupWatcher' 'Startup watcher') }
        'Not running' { return (T 'ModeNotRunning' 'Not running') }
        default { return $Mode }
    }
}

function Get-StudioTrayState {
    param([switch]$Force)
    $now = Get-Date
    if (-not $Force -and $null -ne $script:TrayStateCache -and ($now - $script:TrayStateCacheAt).TotalSeconds -lt 30) {
        return $script:TrayStateCache
    }
    if ($script:RenderMode) {
        # The render audit must not depend on whether the build machine has
        # Session Recovery tasks registered. "Not running" is the longest
        # sidebar status across all nine languages.
        $state = [pscustomobject]@{
            Running     = $false
            Tasks       = $false
            Mode        = 'Not running'
            Count       = 0
            TaskState   = ''
            TaskEnabled = $false
        }
        $script:TrayStateCache = $state
        $script:TrayStateCacheAt = $now
        return $state
    }

    $trayPids = @()
    $nativeProcesses = @(Get-Process -Name 'SessionRecovery' -ErrorAction SilentlyContinue)
    if ($nativeProcesses.Count -gt 0) {
        try {
            $trayPids = @(Get-CimInstance Win32_Process -Filter "Name='SessionRecovery.exe'" -ErrorAction SilentlyContinue | Where-Object {
                $_.CommandLine -and ($_.CommandLine -match '(?i)--tray')
            } | ForEach-Object { [int]$_.ProcessId })
        } catch { }
    }

    $tasks = @(Get-SRScheduledTaskStatus -TaskName 'SessionRecovery-Snapshot')
    $activeTasks = @($tasks | Where-Object { $_.Active })
    $mode = 'Not running'
    if ($activeTasks.Count -gt 0) {
        $mode = if ($trayPids.Count -gt 0) { 'Scheduled tasks + tray' } else { 'Scheduled tasks' }
    } elseif ($trayPids.Count -gt 0) {
        $mode = 'Background tray'
    }
    $state = [pscustomobject]@{
        Running     = ($trayPids.Count -gt 0)
        Tasks       = ($activeTasks.Count -gt 0)
        Mode        = $mode
        Count       = $trayPids.Count
        TaskState   = if ($tasks.Count -gt 0) { [string]$tasks[0].State } else { '' }
        TaskEnabled = if ($tasks.Count -gt 0) { [bool]$tasks[0].Enabled } else { $false }
    }
    $script:TrayStateCache = $state
    $script:TrayStateCacheAt = $now
    return $state
}

function Start-StudioBackground {
    if (-not $script:HostExe -or -not (Test-Path -LiteralPath $script:HostExe)) {
        Show-StudioToast (T 'ToastAppMissing' 'SessionRecovery.exe is missing. Reinstall the app.') $script:P.Red
        return
    }
    $state = Get-StudioTrayState -Force
    if ($state.Running) {
        Show-StudioToast (T 'ToastAlreadyRunning' 'The background app is already running.') $script:P.Green
        return
    }
    $taskWasActive = [bool]$state.Tasks
    try {
        Start-Process -FilePath $script:HostExe -ArgumentList '--tray' -WorkingDirectory $script:ScriptDir | Out-Null
        if ($taskWasActive) {
            Show-StudioToast (T 'ToastTrayStarted' 'Tray controls started. Windows task protection is already active.') $script:P.Green
        } else {
            Show-StudioToast (T 'ToastBackgroundStarted' 'Background protection started.') $script:P.Green
        }
        $script:TrayStateCache = [pscustomobject]@{
            Running     = $true
            Tasks       = $taskWasActive
            Mode        = if ($taskWasActive) { 'Scheduled tasks + tray' } else { 'Background tray' }
            Count       = 1
            TaskState   = [string]$state.TaskState
            TaskEnabled = [bool]$state.TaskEnabled
        }
        $script:TrayStateCacheAt = Get-Date
        Refresh-StudioSidebar
    } catch {
        Show-StudioToast ('Could not start background app: ' + $_.Exception.Message) $script:P.Red
    }
}

function Open-StudioRestore {
    param([string]$SnapshotPath = '')
    if (-not $script:HostExe -or -not (Test-Path -LiteralPath $script:HostExe)) {
        Show-StudioToast (T 'ToastAppMissing' 'SessionRecovery.exe is missing. Reinstall the app.') $script:P.Red
        return
    }
    try {
        $arguments = '--restore-manual'
        if (-not [string]::IsNullOrWhiteSpace($SnapshotPath)) {
            $arguments += ' -SnapshotPath "' + $SnapshotPath.Replace('"', '""') + '"'
        }
        Start-Process -FilePath $script:HostExe -ArgumentList $arguments -WorkingDirectory $script:ScriptDir | Out-Null
        Show-StudioToast (T 'ToastOpenStudio' 'Restore studio opened.') $script:P.Green
    } catch {
        Show-StudioToast ('Could not open restore studio: ' + $_.Exception.Message) $script:P.Red
    }
}

function Reset-StudioCaptureButtons {
    $script:CaptureBusy = $false
    if ($script:Ui.CaptureButton) {
        $script:Ui.CaptureButton.Enabled = $true
        $script:Ui.CaptureButton.Text = (T 'BtnCaptureNow' 'Capture now')
    }
    if ($script:Ui.QuickCapture) {
        $script:Ui.QuickCapture.Enabled = $true
        $script:Ui.QuickCapture.Text = (T 'BtnCaptureNow' 'Capture now')
    }
}

function Complete-StudioCapture {
    param([bool]$Succeeded, [string]$Message = '')
    $script:CaptureState = $null
    Reset-StudioCaptureButtons
    if ($Succeeded) {
        Refresh-StudioData
        if ($script:Snapshots.Count -gt 0) {
            Show-StudioToast ((T 'ToastSavedAt' 'Snapshot saved  •  {0}') -f (Format-StudioDate -Date $script:Snapshots[0].CapturedAt -Format 'HH:mm:ss')) $script:P.Green
        } else {
            Show-StudioToast (T 'ToastSaved' 'Snapshot saved.') $script:P.Green
        }
    } else {
        Show-StudioToast (Localize-StudioString $Message) $script:P.Amber
    }
}

function Invoke-StudioCapture {
    if (-not $script:HostExe -or -not (Test-Path -LiteralPath $script:HostExe)) {
        Show-StudioToast (T 'ToastAppMissing' 'SessionRecovery.exe is missing. Reinstall the app.') $script:P.Red
        return
    }
    if ($script:CaptureBusy) { return }

    # The snapshot runs in its own process; the Studio polls for the new file
    # so the window never freezes while capture is working.
    $script:CaptureBusy = $true
    # The Studio shows its own progress and result toast; the quiet host mode
    # avoids a second notification and sound for the same manual capture.
    foreach ($button in @($script:Ui.CaptureButton, $script:Ui.QuickCapture)) {
        if ($null -ne $button) {
            $button.Enabled = $false
            $button.Text = (T 'BtnCapturing' 'Capturing...')
        }
    }
    Show-StudioToast (T 'ToastCapturing' 'Capturing your current session...') $script:P.Muted

    $before = [datetime]::MinValue
    try {
        $newest = Get-ChildItem -LiteralPath (Get-SRSnapshotDirectory) -Filter 'session-*.json*' -File -ErrorAction SilentlyContinue |
            Sort-Object -Property LastWriteTime -Descending | Select-Object -First 1
        if ($newest) { $before = $newest.LastWriteTime }
    } catch { }

    $captureProcess = $null
    try {
        # The Studio shows its own progress and result toast; the quiet host mode
        # avoids a second notification and sound for the same manual capture.
        $captureProcess = Start-Process -FilePath $script:HostExe -ArgumentList '--snapshot-studio' -WorkingDirectory $script:ScriptDir -PassThru -ErrorAction Stop
    } catch {
        Complete-StudioCapture -Succeeded $false -Message ('Snapshot failed: ' + $_.Exception.Message)
        return
    }

    $script:CaptureState = @{
        Before    = $before
        StartedAt = Get-Date
        Process   = $captureProcess
    }
    if ($null -eq $script:CapturePollTimer) {
        $script:CapturePollTimer = New-Object System.Windows.Forms.Timer
        $script:CapturePollTimer.Interval = 400
        $script:CapturePollTimer.Add_Tick({
            $state = $script:CaptureState
            if ($null -eq $state) {
                if ($script:CapturePollTimer) { $script:CapturePollTimer.Stop() }
                return
            }
            $processExited = $true
            if ($null -ne $state.Process) {
                try {
                    $state.Process.Refresh()
                    $processExited = [bool]$state.Process.HasExited
                } catch {
                    $processExited = $true
                }
            }
            if ($processExited) {
                # Wait for the capture process to exit before reading the file,
                # so a partially written snapshot can never enter the timeline.
                $newest = Get-ChildItem -LiteralPath (Get-SRSnapshotDirectory) -Filter 'session-*.json*' -File -ErrorAction SilentlyContinue |
                    Sort-Object -Property LastWriteTime -Descending | Select-Object -First 1
                if ($null -ne $newest -and $newest.LastWriteTime -gt $state.Before) {
                    $script:CapturePollTimer.Stop()
                    Complete-StudioCapture -Succeeded $true
                    return
                }
                if ($null -ne $state.Process) {
                    $exitCode = $null
                    try { $exitCode = [int]$state.Process.ExitCode } catch { }
                    $script:CapturePollTimer.Stop()
                    if ($exitCode -eq 0) {
                        Complete-StudioCapture -Succeeded $false -Message 'Snapshot was skipped because another capture is still running.'
                    } else {
                        Complete-StudioCapture -Succeeded $false -Message ('Snapshot failed (exit code {0}). Check Diagnostics for details.' -f $exitCode)
                    }
                    return
                }
            }
            if (((Get-Date) - $state.StartedAt).TotalSeconds -gt 30) {
                $script:CapturePollTimer.Stop()
                Complete-StudioCapture -Succeeded $false -Message 'The snapshot did not finish within 30 seconds.'
            }
        })
    }
    $script:CapturePollTimer.Stop()
    $script:CapturePollTimer.Start()
}

# ---------------------------------------------------------------------------
# Shortcuts and settings persistence
# ---------------------------------------------------------------------------

function Set-StudioShortcut {
    param([string]$Path, [string]$Arguments, [string]$Description)
    if (-not $script:HostExe -or -not (Test-Path -LiteralPath $script:HostExe)) { return $false }
    $shell = $null
    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($Path)
        $shortcut.TargetPath = $script:HostExe
        $shortcut.Arguments = $Arguments
        $shortcut.WorkingDirectory = $script:ScriptDir
        if ($script:IconPath) { $shortcut.IconLocation = $script:IconPath + ',0' }
        $shortcut.Description = $Description
        $shortcut.Save()
        return $true
    } catch {
        return $false
    } finally {
        if ($null -ne $shell) { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
    }
}

function Get-StudioStartupShortcutPath {
    return (Join-Path ([Environment]::GetFolderPath('Startup')) 'Session Recovery - Background.lnk')
}

function Get-StudioDesktopShortcutPath {
    return (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Session Recovery.lnk')
}

function Set-StudioStartWithWindows {
    param([bool]$Enabled)
    $path = Get-StudioStartupShortcutPath
    if (-not $Enabled) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Join-Path ([Environment]::GetFolderPath('Startup')) 'Session Recovery - Snapshot Watcher.lnk') -Force -ErrorAction SilentlyContinue
        return $true
    }
    return (Set-StudioShortcut -Path $path -Arguments '--tray' -Description 'Session Recovery: keeps snapshots while you are signed in.')
}

function Set-StudioDesktopShortcut {
    param([bool]$Enabled)
    $path = Get-StudioDesktopShortcutPath
    if (-not $Enabled) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Restore Session.lnk') -Force -ErrorAction SilentlyContinue
        return $true
    }
    $created = Set-StudioShortcut -Path $path -Arguments '' -Description 'Open Session Recovery.'
    if ($created) {
        Remove-Item -LiteralPath (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Restore Session.lnk') -Force -ErrorAction SilentlyContinue
    }
    return $created
}

function Refresh-StudioSidebar {
    param([switch]$Force)
    if (-not $script:Ui.SidebarBadge) { return }
    $state = Get-StudioTrayState -Force:$Force
    $latestAge = $null
    if ($script:Snapshots.Count -gt 0) {
        $latestAge = ((Get-Date) - $script:Snapshots[0].CapturedAt).TotalMinutes
    }
    $healthy = ($null -ne $latestAge -and $latestAge -le ([Math]::Max(1, [int]$script:Config.snapshotIntervalMinutes) * 2.5))
    if ($healthy) {
        $script:Ui.SidebarBadge.Text = (T 'BadgeProtected' 'PROTECTED')
        $script:Ui.SidebarBadge.FillColor = $script:P.GreenSoft
        $script:Ui.SidebarBadge.TextColor = $script:P.Green
    } else {
        $script:Ui.SidebarBadge.Text = (T 'BadgeAttention' 'ATTENTION')
        $script:Ui.SidebarBadge.FillColor = $script:P.AmberSoft
        $script:Ui.SidebarBadge.TextColor = $script:P.Amber
    }
    $script:Ui.SidebarStatus.Text = Get-StudioModeText -Mode ([string]$state.Mode)
    $script:Ui.SidebarDetail.Text = if ($state.Running -and $state.Tasks) {
        (T 'StatusTaskTray' 'Task + tray controls active')
    } elseif ($state.Running) {
        (T 'StatusTray' 'Tray app running')
    } elseif ($state.Tasks) {
        (T 'StatusTask' 'Windows task is active')
    } else {
        (T 'StatusNone' 'Background app is not running')
    }
    if ($state.Running) {
        $script:Ui.TrayButton.Text = (T 'BtnBackgroundRunning' 'Background running')
        $script:Ui.TrayButton.Enabled = $false
    } elseif ($state.Tasks) {
        $script:Ui.TrayButton.Text = (T 'BtnStartTray' 'Start tray controls')
        $script:Ui.TrayButton.Enabled = $true
    } else {
        $script:Ui.TrayButton.Text = (T 'BtnStartBackground' 'Start background app')
        $script:Ui.TrayButton.Enabled = $true
    }
}

function Refresh-StudioData {
    $script:Config = Get-SRConfig
    $script:Snapshots = @(Get-SRSnapshots)
    $script:SnapshotsDirty = $true
    $script:DashboardDirty = $true
    $script:ExclusionsDirty = $true
    $script:DiagnosticsDirty = $true
    Refresh-StudioSidebar -Force
    switch ($script:CurrentPage) {
        'Dashboard' { if ($script:PageLoaded.ContainsKey('Dashboard')) { Refresh-StudioDashboard } }
        'Snapshots' { if ($script:PageLoaded.ContainsKey('Snapshots')) { Refresh-StudioSnapshotRows } }
        'Exclusions' { if ($script:PageLoaded.ContainsKey('Exclusions')) { Refresh-StudioExclusions } }
        'RecoveryKit' { if ($script:PageLoaded.ContainsKey('RecoveryKit')) { Update-StudioKitSummary } }
        'Diagnostics' { if ($script:PageLoaded.ContainsKey('Diagnostics')) { Start-StudioDiagnosticsRefresh -Force } }
    }
}

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
Enable-StudioDoubleBuffer $form
$form.Font = $script:FontBody
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
$form.KeyPreview = $true
if ($script:IconPath) {
    try { $form.Icon = New-Object System.Drawing.Icon($script:IconPath) } catch { }
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
if ($script:IconPath) {
    try { $brandPic.Image = (New-Object System.Drawing.Icon($script:IconPath)).ToBitmap() } catch { }
}
$sidebar.Controls.Add($brandPic)

$brandName = New-StudioLabel -Text 'Session' -X 70 -Y 23 -Width 150 -Height 24 -Font (New-Object System.Drawing.Font('Segoe UI Semibold', 13)) -Color $script:P.Text
$sidebar.Controls.Add($brandName)
$brandSub = New-StudioLabel -Text (T 'BrandRecoveryStudio' 'RECOVERY  /  STUDIO') -X 72 -Y 45 -Width 162 -Height 16 -Font $script:FontMono -Color $script:P.Subtle
$sidebar.Controls.Add($brandSub)

$navDefs = @(
    @{ Key = 'Dashboard'; Label = 'Dashboard'; Glyph = [char]0xE80F },
    @{ Key = 'Snapshots'; Label = 'Snapshots'; Glyph = [char]0xE81C },
    @{ Key = 'Exclusions'; Label = 'Exclusions'; Glyph = [char]0xE8B7 },
    @{ Key = 'RecoveryKit'; Label = 'Recovery Kit'; Glyph = [char]0xE7B8 },
    @{ Key = 'Settings'; Label = 'Settings'; Glyph = [char]0xE713 },
    @{ Key = 'Diagnostics'; Label = 'Diagnostics'; Glyph = [char]0xE9D9 },
    @{ Key = 'About'; Label = 'About'; Glyph = [char]0xE946 }
)
$navIndex = 0
foreach ($nav in $navDefs) {
    $navButton = New-Object SessionRecovery.Studio.StudioNavButton
    $navButton.Text = $nav.Label
    $navButton.Glyph = [string]$nav.Glyph
    $navButton.Tag = $nav.Key
    # Eight entries must still clear the bottom restore button at the minimum
    # window height (client 661 px). 78 + 7*40 ends at 398 px.
    $navButton.Location = New-Object System.Drawing.Point(14, (78 + ($navIndex * 40)))
    $navButton.Size = New-Object System.Drawing.Size(208, 40)
    $navButton.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $navButton.AccentColor = $script:P.Accent
    $navButton.SelectedFill = $script:P.NavSelected
    $navButton.HoverFill = $script:P.NavHover
    $navButton.TextColor = $script:P.Muted
    $navButton.SelectedTextColor = $script:P.Text
    $navButton.Add_Click({
        param($sender, $eventArgs)
        Show-StudioPage -Name ([string]$sender.Tag)
    })
    $sidebar.Controls.Add($navButton)
    $script:NavButtons[$nav.Key] = $navButton
    $navIndex++
}

$restoreSidebar = New-StudioButton -Text 'Restore a session' -X 14 -Y 0 -Width 208 -Height 40 -Primary -Glyph ([string][char]0xE777)
$restoreSidebar.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$restoreSidebar.Add_Click({ Open-StudioRestore })
$sidebar.Controls.Add($restoreSidebar)

$sidebarStatusCard = New-StudioCard -X 14 -Y 0 -Width 208 -Height 156 -Fill $script:P.CardAlt -Border $script:P.BorderSoft -Radius 12
$sidebarStatusCard.CanvasColor = $script:P.Sidebar
$sidebarStatusCard.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$sidebar.Controls.Add($sidebarStatusCard)

$sidebarBadge = New-StudioBadge -Text 'PROTECTED' -Width 88 -Height 22
$sidebarBadge.Location = New-Object System.Drawing.Point(14, 13)
$sidebarStatusCard.Controls.Add($sidebarBadge)
$script:Ui.SidebarBadge = $sidebarBadge

$sidebarTitle = New-StudioLabel -Text 'PROTECTION' -X 14 -Y 43 -Width 150 -Height 16 -Font $script:FontMono -Color $script:P.Subtle
$sidebarStatusCard.Controls.Add($sidebarTitle)
$sidebarStatus = New-StudioLabel -Text 'Checking...' -X 14 -Y 60 -Width 200 -Height 18 -Font $script:FontSemibold -Color $script:P.Text
$sidebarStatusCard.Controls.Add($sidebarStatus)
$script:Ui.SidebarStatus = $sidebarStatus
# French, Spanish, Portuguese and Russian need two lines at this width.
$sidebarDetail = New-StudioLabel -Text '' -X 14 -Y 78 -Width 180 -Height 30 -Font $script:FontBodySmall -Color $script:P.Muted
$sidebarStatusCard.Controls.Add($sidebarDetail)
$script:Ui.SidebarDetail = $sidebarDetail

$trayButton = New-StudioButton -Text 'Start background app' -X 14 -Y 114 -Width 180 -Height 30 -Glyph ''
$trayButton.Visible = $true
$trayButton.Add_Click({ Start-StudioBackground })
$sidebarStatusCard.Controls.Add($trayButton)
$script:Ui.TrayButton = $trayButton

$sidebarVersion = New-StudioLabel -Text ('STUDIO {0}  /  {1}' -f $script:AppVersion, (T 'BadgeLocalOnly' 'LOCAL ONLY')) -X 14 -Y 0 -Width 208 -Height 16 -Font $script:FontMono -Color $script:P.Subtle -Align 'MiddleCenter'
$sidebarVersion.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$sidebar.Controls.Add($sidebarVersion)
$script:Ui.SidebarVersion = $sidebarVersion

$header = New-Object System.Windows.Forms.Panel
$header.Location = New-Object System.Drawing.Point(0, 0)
$header.Size = New-Object System.Drawing.Size(984, 88)
$header.BackColor = $script:P.Bg
$main.Controls.Add($header)

$headerLine = New-Object System.Windows.Forms.Panel
$headerLine.Location = New-Object System.Drawing.Point(0, 87)
$headerLine.Size = New-Object System.Drawing.Size(984, 1)
$headerLine.BackColor = $script:P.BorderSoft
$headerLine.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$header.Controls.Add($headerLine)

$pageTitle = New-StudioLabel -Text 'Dashboard' -X 28 -Y 17 -Width 560 -Height 32 -Font $script:FontTitle -Color $script:P.Text
$pageTitle.AutoEllipsis = $true
$header.Controls.Add($pageTitle)
$script:Ui.PageTitle = $pageTitle
$pageSubtitle = New-StudioLabel -Text 'Your session, exactly as you left it.' -X 30 -Y 47 -Width 600 -Height 20 -Font $script:FontBody -Color $script:P.Muted
$header.Controls.Add($pageSubtitle)
$script:Ui.PageSubtitle = $pageSubtitle
$toastLabel = New-StudioLabel -Text '' -X 30 -Y 66 -Width 560 -Height 16 -Font $script:FontBodySmall -Color $script:P.Green
$toastLabel.Visible = $false
$header.Controls.Add($toastLabel)
$script:Ui.Toast = $toastLabel

$localBadge = New-StudioBadge -Text 'LOCAL ONLY' -Width 100 -Height 26 -Fill $script:P.CardAlt -TextColor $script:P.Muted
$localBadge.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$header.Controls.Add($localBadge)
$script:Ui.LocalBadge = $localBadge

$refreshButton = New-StudioButton -Text '' -X 0 -Y 25 -Width 38 -Height 38 -Glyph ([string][char]0xE72C)
$refreshButton.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$refreshButton.Visible = $false
$refreshButton.Add_Click({ Refresh-StudioDiagnostics })
$header.Controls.Add($refreshButton)
$script:Ui.RefreshButton = $refreshButton

$captureButton = New-StudioButton -Text 'Capture now' -X 0 -Y 24 -Width 184 -Height 40 -Primary -Glyph ([string][char]0xE710)
$captureButton.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$captureButton.Add_Click({ Invoke-StudioCapture })
$header.Controls.Add($captureButton)
$script:Ui.CaptureButton = $captureButton

$pageHost = New-Object System.Windows.Forms.Panel
$pageHost.Location = New-Object System.Drawing.Point(0, 88)
$pageHost.Size = New-Object System.Drawing.Size(984, 692)
$pageHost.BackColor = $script:P.Bg
Enable-StudioDoubleBuffer $pageHost
$main.Controls.Add($pageHost)
$script:PageHost = $pageHost

function New-StudioPage {
    param([string]$Name)
    $page = New-Object System.Windows.Forms.Panel
    $page.Dock = [System.Windows.Forms.DockStyle]::Fill
    $page.BackColor = $script:P.Bg
    $page.Visible = $false
    $page.Size = $script:PageHost.ClientSize
    Enable-StudioDoubleBuffer $page
    $script:PageHost.Controls.Add($page)
    $script:Pages[$Name] = $page
    return $page
}

# ---------------------------------------------------------------------------
# Dashboard
# ---------------------------------------------------------------------------

$dashboard = New-StudioPage -Name 'Dashboard'
$hero = New-StudioCard -X 24 -Y 18 -Width 936 -Height 180
$hero.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$dashboard.Controls.Add($hero)

$heroBadge = New-StudioBadge -Text 'PROTECTED' -Width 98 -Height 24
$heroBadge.Location = New-Object System.Drawing.Point(22, 18)
$hero.Controls.Add($heroBadge)
$script:Ui.HeroBadge = $heroBadge

$heroTitle = New-StudioLabel -Text 'Your session is protected' -X 22 -Y 48 -Width 560 -Height 40 -Font $script:FontHero -Color $script:P.Text
$hero.Controls.Add($heroTitle)
$script:Ui.HeroTitle = $heroTitle
$heroSub = New-StudioLabel -Text (T 'HeroSubLine' 'Snapshots stay on this PC. Restore apps, folders and browser tabs from any saved moment.') -X 24 -Y 91 -Width 600 -Height 36 -Font $script:FontBody -Color $script:P.Muted
$hero.Controls.Add($heroSub)
$heroLast = New-StudioLabel -Text (T 'HeroLastChecking' 'Last snapshot  •  checking') -X 24 -Y 128 -Width 620 -Height 18 -Font $script:FontBodySmall -Color $script:P.Muted
$heroLast.AutoEllipsis = $true
$hero.Controls.Add($heroLast)
$script:Ui.HeroLast = $heroLast
$heroNext = New-StudioLabel -Text (T 'HeroNextChecking' 'Next automatic snapshot  •  checking') -X 24 -Y 148 -Width 620 -Height 18 -Font $script:FontBodySmall -Color $script:P.Subtle
$hero.Controls.Add($heroNext)
$script:Ui.HeroNext = $heroNext

$heroRestore = New-StudioButton -Text 'Restore latest' -X 24 -Y 166 -Width 132 -Height 0 -Glyph ([string][char]0xE777)
$heroRestore.Visible = $false
$hero.Controls.Add($heroRestore)

$heroRing = New-Object SessionRecovery.Studio.StudioRing
$heroRing.Size = New-Object System.Drawing.Size(132, 132)
$heroRing.Location = New-Object System.Drawing.Point(780, 27)
$heroRing.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$heroRing.Value = 100
$heroRing.CenterText = '--'
$heroRing.Caption = 'LAST SNAPSHOT'
$heroRing.ProgressColor = $script:P.Accent
$heroRing.ProgressEndColor = $script:P.Accent2
$heroRing.TrackColor = $script:P.Border
$heroRing.CenterTextColor = $script:P.Text
$heroRing.CaptionColor = $script:P.Subtle
$hero.Controls.Add($heroRing)
$script:Ui.HeroRing = $heroRing

$statRow = New-Object System.Windows.Forms.Panel
$statRow.Location = New-Object System.Drawing.Point(24, 214)
$statRow.Size = New-Object System.Drawing.Size(936, 124)
$statRow.BackColor = $script:P.Bg
$statRow.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$dashboard.Controls.Add($statRow)

$statSnapshots = New-Object SessionRecovery.Studio.StudioStatCard
$statSnapshots.Title = (T 'StatSnapshots' 'SNAPSHOTS')
$statSnapshots.Value = '0'
$statSnapshots.Detail = (T 'StatDetailMoments' 'Saved moments')
$statSnapshots.Glyph = [string][char]0xE81C
$statSnapshots.AccentColor = $script:P.Accent
$statSnapshots.TitleColor = $script:P.Muted
$statSnapshots.ValueColor = $script:P.Text
$statSnapshots.DetailColor = $script:P.Subtle
$statSnapshots.FillColor = $script:P.Card
$statSnapshots.BorderColor = $script:P.BorderSoft
$statSnapshots.CanvasColor = $script:P.Bg
$statSnapshots.Location = New-Object System.Drawing.Point(0, 0)
$statSnapshots.Size = New-Object System.Drawing.Size(224, 124)
$statRow.Controls.Add($statSnapshots)
$script:Ui.StatSnapshots = $statSnapshots

$statApps = New-Object SessionRecovery.Studio.StudioStatCard
$statApps.Title = (T 'StatAppsCaptured' 'APPS CAPTURED')
$statApps.Value = '0'
$statApps.Detail = (T 'StatDetailLatest' 'In the latest snapshot')
$statApps.Glyph = [string][char]0xE8F1
$statApps.AccentColor = $script:P.Green
$statApps.TitleColor = $script:P.Muted
$statApps.ValueColor = $script:P.Text
$statApps.DetailColor = $script:P.Subtle
$statApps.FillColor = $script:P.Card
$statApps.BorderColor = $script:P.BorderSoft
$statApps.CanvasColor = $script:P.Bg
$statApps.Location = New-Object System.Drawing.Point(238, 0)
$statApps.Size = New-Object System.Drawing.Size(224, 124)
$statRow.Controls.Add($statApps)
$script:Ui.StatApps = $statApps

$statTabs = New-Object SessionRecovery.Studio.StudioStatCard
$statTabs.Title = (T 'StatBrowserTabs' 'BROWSER TABS')
$statTabs.Value = '0'
$statTabs.Detail = 'Across open browsers'
$statTabs.Glyph = [string][char]0xE774
$statTabs.AccentColor = $script:P.Accent2
$statTabs.TitleColor = $script:P.Muted
$statTabs.ValueColor = $script:P.Text
$statTabs.DetailColor = $script:P.Subtle
$statTabs.FillColor = $script:P.Card
$statTabs.BorderColor = $script:P.BorderSoft
$statTabs.CanvasColor = $script:P.Bg
$statTabs.Location = New-Object System.Drawing.Point(476, 0)
$statTabs.Size = New-Object System.Drawing.Size(224, 124)
$statRow.Controls.Add($statTabs)
$script:Ui.StatTabs = $statTabs

$statStorage = New-Object SessionRecovery.Studio.StudioStatCard
$statStorage.Title = (T 'StatLocalStorage' 'LOCAL STORAGE')
$statStorage.Value = '0 B'
$statStorage.Detail = 'Snapshots on disk'
$statStorage.Glyph = [string][char]0xE7B8
$statStorage.AccentColor = $script:P.Amber
$statStorage.TitleColor = $script:P.Muted
$statStorage.ValueColor = $script:P.Text
$statStorage.DetailColor = $script:P.Subtle
$statStorage.FillColor = $script:P.Card
$statStorage.BorderColor = $script:P.BorderSoft
$statStorage.CanvasColor = $script:P.Bg
$statStorage.Location = New-Object System.Drawing.Point(714, 0)
$statStorage.Size = New-Object System.Drawing.Size(224, 124)
$statRow.Controls.Add($statStorage)
$script:Ui.StatStorage = $statStorage

$recentCard = New-StudioCard -X 24 -Y 342 -Width 620 -Height 240
$recentCard.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
$dashboard.Controls.Add($recentCard)
$recentHeading = New-StudioLabel -Text (T 'RecentSnapshots' 'RECENT SNAPSHOTS') -X 18 -Y 15 -Width 240 -Height 18 -Font $script:FontMono -Color $script:P.Subtle
$recentCard.Controls.Add($recentHeading)
$recentViewAll = New-StudioButton -Text (T 'BtnViewTimeline' 'View timeline') -X 0 -Y 10 -Width 160 -Height 26 -Glyph ''
$recentViewAll.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$recentViewAll.Add_Click({ Show-StudioPage -Name 'Snapshots' })
$recentCard.Controls.Add($recentViewAll)
$recentFlow = New-Object System.Windows.Forms.FlowLayoutPanel
$recentFlow.Location = New-Object System.Drawing.Point(16, 42)
$recentFlow.Size = New-Object System.Drawing.Size(588, 190)
$recentFlow.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$recentFlow.FlowDirection = [System.Windows.Forms.FlowDirection]::TopDown
$recentFlow.WrapContents = $false
$recentFlow.AutoScroll = $false
$recentFlow.BackColor = $script:P.Card
$recentCard.Controls.Add($recentFlow)
$script:Ui.RecentFlow = $recentFlow
$recentSpark = New-Object SessionRecovery.Studio.StudioSparkline
$recentSpark.Location = New-Object System.Drawing.Point(16, 242)
$recentSpark.Size = New-Object System.Drawing.Size(588, 32)
$recentSpark.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$recentSpark.LineColor = $script:P.Accent
$recentSpark.FillColor = $script:P.SparkFill
$recentCard.Controls.Add($recentSpark)
$script:Ui.RecentSpark = $recentSpark
$recentEmpty = New-StudioLabel -Text (T 'NoSnapshotsYet' 'No snapshots yet. Capture one to get started.') -X 18 -Y 54 -Width 400 -Height 30 -Font $script:FontBody -Color $script:P.Muted
$recentEmpty.Visible = $false
$recentCard.Controls.Add($recentEmpty)
$script:Ui.RecentEmpty = $recentEmpty

$quickCard = New-StudioCard -X 660 -Y 342 -Width 300 -Height 240
$quickCard.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
$dashboard.Controls.Add($quickCard)
$quickHeading = New-StudioLabel -Text (T 'QuickActions' 'QUICK ACTIONS') -X 18 -Y 15 -Width 200 -Height 18 -Font $script:FontMono -Color $script:P.Subtle
$quickCard.Controls.Add($quickHeading)
$quickCapture = New-StudioButton -Text 'Capture now' -X 16 -Y 44 -Width 268 -Height 34 -Primary -Glyph ([string][char]0xE710)
$quickCapture.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$quickCapture.Add_Click({ Invoke-StudioCapture })
$quickCard.Controls.Add($quickCapture)
$script:Ui.QuickCapture = $quickCapture
$quickRestore = New-StudioButton -Text (T 'BtnRestoreLatestSession' 'Restore latest snapshot') -X 16 -Y 86 -Width 268 -Height 34 -Glyph ([string][char]0xE777)
$quickRestore.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$quickRestore.Add_Click({
    if ($script:Snapshots.Count -gt 0) { Open-StudioRestore -SnapshotPath $script:Snapshots[0].Path }
    else { Show-StudioToast (T 'ToastNoSnapshot' 'There is no snapshot to restore yet.') $script:P.Amber }
})
$quickCard.Controls.Add($quickRestore)
$script:Ui.QuickRestore = $quickRestore
$quickFolder = New-StudioButton -Text (T 'BtnOpenSnapshotsFolder' 'Open snapshots folder') -X 16 -Y 128 -Width 268 -Height 34 -Glyph ([string][char]0xE838)
$quickFolder.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$quickFolder.Add_Click({ Open-StudioPath (Get-SRSnapshotDirectory) })
$quickCard.Controls.Add($quickFolder)
$quickDiagnostics = New-StudioButton -Text (T 'BtnRunDiagnostics' 'Run diagnostics') -X 16 -Y 170 -Width 268 -Height 34 -Glyph ([string][char]0xE9D9)
$quickDiagnostics.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$quickDiagnostics.Add_Click({ Show-StudioPage -Name 'Diagnostics' })
$quickCard.Controls.Add($quickDiagnostics)

$dashboardHint = New-StudioLabel -Text (T 'DashboardHint' 'Snapshots are local JSON files. Nothing leaves this device.') -X 24 -Y 660 -Width 600 -Height 18 -Font $script:FontBodySmall -Color $script:P.Subtle
$dashboardHint.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
$dashboardHint.Visible = $false
$dashboard.Controls.Add($dashboardHint)

function Refresh-StudioDashboard {
    if (-not $script:UiReady -and -not $script:Ui.StatSnapshots) { return }
    $latest = if ($script:Snapshots.Count -gt 0) { $script:Snapshots[0] } else { $null }
    $stats = Get-StudioStats -Snapshot $(if ($latest) { $latest.Snapshot } else { $null })
    $bytes = 0
    foreach ($entry in $script:Snapshots) { $bytes += Get-StudioSnapshotBytes -Entry $entry }
    if ($script:Ui.StatSnapshots) {
        $script:Ui.StatSnapshots.Title = (T 'StatSnapshots' 'SNAPSHOTS')
        $script:Ui.StatSnapshots.Value = [string]$script:Snapshots.Count
        $script:Ui.StatSnapshots.Detail = (T 'StatDetailRetaining' 'Retaining up to {0}') -f $script:Config.keepSnapshots
        $script:Ui.StatApps.Title = (T 'StatAppsCaptured' 'APPS CAPTURED')
        $script:Ui.StatApps.Value = [string]$stats.Apps
        $script:Ui.StatApps.Detail = if ($latest) { (T 'StatDetailCaptured' 'Captured {0}') -f (Format-StudioAge -CapturedAt $latest.CapturedAt) } else { (T 'StatDetailNoSnapshot' 'No snapshot yet') }
        $script:Ui.StatTabs.Title = (T 'StatBrowserTabs' 'BROWSER TABS')
        $script:Ui.StatTabs.Value = [string]$stats.Tabs
        $script:Ui.StatTabs.Detail = if ($stats.Browsers -gt 0) { (T 'StatDetailBrowsers' '{0} browser(s) captured') -f $stats.Browsers } else { (T 'StatDetailNoBrowsers' 'No browser tabs captured') }
        $script:Ui.StatStorage.Title = (T 'StatLocalStorage' 'LOCAL STORAGE')
        $script:Ui.StatStorage.Value = Format-StudioBytes -Bytes $bytes
        $script:Ui.StatStorage.Detail = (T 'StatDetailFolders' '{0} folder(s) in latest') -f $stats.Folders
    }
    if ($script:Ui.HeroRing) {
        $age = if ($latest) { ((Get-Date) - $latest.CapturedAt).TotalMinutes } else { 9999 }
        $interval = [Math]::Max(1, [int]$script:Config.snapshotIntervalMinutes)
        $health = 100
        if ($age -gt $interval * 2.5) { $health = 55 }
        if ($age -gt 24 * 60) { $health = 25 }
        if ($script:Snapshots.Count -eq 0) { $health = 0 }
        $script:Ui.HeroRing.Value = $health
        if ($latest) {
            $ageSpan = (Get-Date) - $latest.CapturedAt
            $ringText = if ($ageSpan.TotalMinutes -lt 60) { '{0}m' -f [Math]::Max(1, [int]$ageSpan.TotalMinutes) } elseif ($ageSpan.TotalHours -lt 24) { '{0}h' -f [int]$ageSpan.TotalHours } else { '{0}d' -f [int]$ageSpan.TotalDays }
            $script:Ui.HeroRing.CenterText = $ringText
            $script:Ui.HeroLast.Text = ((T 'HeroLastLine' 'Last snapshot {0}  •  {1}  •  {2} app(s), {3} tab(s)') -f (Format-StudioAge -CapturedAt $latest.CapturedAt), (Format-StudioDate -Date $latest.CapturedAt -Format 'HH:mm:ss'), $stats.Apps, $stats.Tabs)
        } else {
            $script:Ui.HeroRing.CenterText = '--'
            $script:Ui.HeroLast.Text = (T 'NoSnapshotSaved' 'No snapshot has been saved yet.')
        }
        $script:Ui.HeroNext.Text = ((T 'NextSnapshot' 'Next automatic snapshot') + '  •  ' + (Format-StudioNext))
        if ($health -ge 80) {
            $script:Ui.HeroBadge.Text = (T 'BadgeProtected' 'PROTECTED')
            $script:Ui.HeroBadge.FillColor = $script:P.GreenSoft
            $script:Ui.HeroBadge.TextColor = $script:P.Green
            $script:Ui.HeroTitle.Text = (T 'HeroProtected' 'Your session is protected')
            $script:Ui.HeroRing.ProgressColor = $script:P.Green
            $script:Ui.HeroRing.ProgressEndColor = $script:P.Accent2
        } elseif ($health -ge 40) {
            $script:Ui.HeroBadge.Text = (T 'BadgeAttention' 'ATTENTION')
            $script:Ui.HeroBadge.FillColor = $script:P.AmberSoft
            $script:Ui.HeroBadge.TextColor = $script:P.Amber
            $script:Ui.HeroTitle.Text = (T 'AttentionNeeded' 'A little attention is needed')
            $script:Ui.HeroRing.ProgressColor = $script:P.Amber
            $script:Ui.HeroRing.ProgressEndColor = $script:P.Amber
        } else {
            $script:Ui.HeroBadge.Text = (T 'BadgeAttention' 'ATTENTION')
            $script:Ui.HeroBadge.FillColor = $script:P.RedSoft
            $script:Ui.HeroBadge.TextColor = $script:P.Red
            $script:Ui.HeroTitle.Text = (T 'HeroNothing' 'Nothing has been saved yet')
            $script:Ui.HeroRing.ProgressColor = $script:P.Red
            $script:Ui.HeroRing.ProgressEndColor = $script:P.Red
        }
    }
    if ($script:Ui.QuickRestore) { $script:Ui.QuickRestore.Enabled = ($script:Snapshots.Count -gt 0) }
    if ($script:Ui.RecentFlow) {
        $script:Ui.RecentFlow.SuspendLayout()
        try {
            $script:Ui.RecentFlow.Controls.Clear()
            $count = [Math]::Min(5, [Math]::Max(1, [int][Math]::Floor(($script:Ui.RecentFlow.Height - 8) / 52)))
            foreach ($entry in @($script:Snapshots | Select-Object -First $count)) {
                $row = New-StudioCard -X 0 -Y 0 -Width ([Math]::Max(200, $script:Ui.RecentFlow.ClientSize.Width - 6)) -Height 44 -Fill $script:P.CardAlt -Border $script:P.BorderSoft -Radius 9
                $row.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 6)
                $row.Tag = $entry.Path
                $statsRow = Get-StudioStats -Snapshot $entry.Snapshot
                $timeLabel = New-StudioLabel -Text (Format-StudioDate -Date $entry.CapturedAt -Format 'MMM d  •  HH:mm') -X 12 -Y 5 -Width 150 -Height 16 -Font $script:FontBodySmall -Color $script:P.Text
                $metaLabel = New-StudioLabel -Text ((T 'RowMetaAppsTabs' '{0} apps  •  {1} tabs  •  {2}') -f $statsRow.Apps, $statsRow.Tabs, (Format-StudioAge -CapturedAt $entry.CapturedAt)) -X 12 -Y 22 -Width ([Math]::Max(120, $row.Width - 156)) -Height 16 -Font $script:FontBodySmall -Color $script:P.Muted
                $metaLabel.AutoEllipsis = $true
                $restoreRow = New-StudioButton -Text (T 'BtnRestore' 'Restore') -X ($row.Width - 136) -Y 9 -Width 124 -Height 26 -Glyph ''
                $restoreRow.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
                $restoreRow.Tag = $entry.Path
                $restoreRow.Add_Click({
                    param($sender, $eventArgs)
                    Open-StudioRestore -SnapshotPath ([string]$sender.Tag)
                })
                $selectHandler = {
                    param($sender, $eventArgs)
                    $path = if ($sender.Tag) { [string]$sender.Tag } else { $script:SelectedSnapshotPath }
                    $script:SelectedSnapshotPath = $path
                    Show-StudioPage -Name 'Snapshots'
                }
                $row.Add_Click($selectHandler)
                $timeLabel.Add_Click($selectHandler)
                $metaLabel.Add_Click($selectHandler)
                $row.Controls.Add($timeLabel)
                $row.Controls.Add($metaLabel)
                $row.Controls.Add($restoreRow)
                [void]$script:Ui.RecentFlow.Controls.Add($row)
            }
            $script:Ui.RecentEmpty.Visible = ($script:Snapshots.Count -eq 0)
        } finally {
            $script:Ui.RecentFlow.ResumeLayout()
        }
    }
    if ($script:Ui.RecentSpark) {
        $values = @()
        foreach ($entry in @($script:Snapshots | Select-Object -First 12)) {
            $values += [int](Get-StudioStats -Snapshot $entry.Snapshot).Tabs
        }
        [array]::Reverse($values)
        $script:Ui.RecentSpark.Values = [int[]]$values
    }
    $script:DashboardDirty = $false
}

# ---------------------------------------------------------------------------
# Snapshots timeline
# ---------------------------------------------------------------------------

$snapshotsPage = New-StudioPage -Name 'Snapshots'
$snapToolbar = New-StudioCard -X 24 -Y 14 -Width 936 -Height 64
$snapToolbar.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$snapshotsPage.Controls.Add($snapToolbar)

$snapSearch = New-StudioTextBox -X 16 -Y 18 -Width 230 -Height 28
$snapSearch.Text = (T 'SearchPlaceholder' 'Search apps, folders, tabs')
$snapSearch.ForeColor = $script:P.Subtle
$snapSearch.Tag = 'placeholder'
$snapSearch.Add_GotFocus({
    if ($script:Ui.SnapSearch.Tag -eq 'placeholder') {
        $script:Ui.SnapSearch.Text = ''
        $script:Ui.SnapSearch.ForeColor = $script:P.Text
        $script:Ui.SnapSearch.Tag = ''
    }
})
$snapSearch.Add_LostFocus({
    if ([string]::IsNullOrWhiteSpace($script:Ui.SnapSearch.Text)) {
        $script:Ui.SnapSearch.Text = (T 'SearchPlaceholder' 'Search apps, folders, tabs')
        $script:Ui.SnapSearch.ForeColor = $script:P.Subtle
        $script:Ui.SnapSearch.Tag = 'placeholder'
    }
})
$snapSearch.Add_TextChanged({
    if ($script:UiReady -and $script:Ui.SnapSearch.Tag -ne 'placeholder') {
        Refresh-StudioSnapshotRows
    }
})
$snapToolbar.Controls.Add($snapSearch)
$script:Ui.SnapSearch = $snapSearch

$snapFilter = New-StudioCombo -X 258 -Y 18 -Width 170
Set-StudioLocalizedCombo -Combo $snapFilter -Keys @('FilterAll', 'FilterHour', 'Filter24', 'Filter7') -Defaults @('All snapshots', 'Last hour', 'Last 24 hours', 'Last 7 days')
$snapFilter.SelectedIndex = 0
$snapFilter.Add_SelectedIndexChanged({
    if ($script:UiReady) { Refresh-StudioSnapshotRows }
})
$snapToolbar.Controls.Add($snapFilter)
$script:Ui.SnapFilter = $snapFilter

$snapCount = New-StudioLabel -Text ((T 'SnapCount' '{0} snapshots') -f 0) -X 444 -Y 20 -Width 180 -Height 22 -Font $script:FontBodySmall -Color $script:P.Muted
$snapCount.AutoEllipsis = $true
$snapToolbar.Controls.Add($snapCount)
$script:Ui.SnapCount = $snapCount

$snapOpenFolder = New-StudioButton -Text (T 'BtnOpenFolder' 'Open folder') -X 662 -Y 16 -Width 116 -Height 32 -Glyph ''
$snapOpenFolder.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$snapOpenFolder.Add_Click({ Open-StudioPath (Get-SRSnapshotDirectory) })
$snapToolbar.Controls.Add($snapOpenFolder)

$snapRefresh = New-StudioButton -Text (T 'BtnRefresh' 'Refresh') -X 788 -Y 16 -Width 128 -Height 32 -Glyph ([string][char]0xE72C)
$snapRefresh.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$snapRefresh.Add_Click({
    Refresh-StudioData
    Refresh-StudioSnapshotRows
    Show-StudioToast (T 'ToastTimeline' 'Snapshot timeline refreshed.') $script:P.Muted
})
$snapToolbar.Controls.Add($snapRefresh)
$script:Ui.SnapRefresh = $snapRefresh
$script:Ui.SnapOpenFolder = $snapOpenFolder

$snapSplit = New-Object System.Windows.Forms.SplitContainer
$snapSplit.Location = New-Object System.Drawing.Point(24, 90)
$snapSplit.Size = New-Object System.Drawing.Size(936, 582)
$snapSplit.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$snapSplit.BackColor = $script:P.Bg
$snapSplit.SplitterWidth = 12
$snapSplit.Panel1MinSize = 320
$snapSplit.Panel2MinSize = 376
$snapSplit.FixedPanel = [System.Windows.Forms.FixedPanel]::Panel2
$snapSplit.SplitterDistance = 548
$snapshotsPage.Controls.Add($snapSplit)
$script:Ui.SnapSplit = $snapSplit

$snapListCard = New-StudioCard -X 0 -Y 0 -Width 536 -Height 580
$snapListCard.Dock = [System.Windows.Forms.DockStyle]::Fill
$snapListCard.CanvasColor = $script:P.Bg
$snapSplit.Panel1.Controls.Add($snapListCard)

$snapListHeading = New-StudioLabel -Text (T 'SnapTimeline' 'SNAPSHOT TIMELINE') -X 18 -Y 15 -Width 260 -Height 18 -Font $script:FontMono -Color $script:P.Subtle
$snapListCard.Controls.Add($snapListHeading)
$snapListHint = New-StudioLabel -Text (T 'SelectMoment' 'Select a moment to preview it.') -X 18 -Y 31 -Width 260 -Height 16 -Font $script:FontBodySmall -Color $script:P.Subtle
$snapListCard.Controls.Add($snapListHint)

$snapExport = New-StudioButton -Text (T 'BtnExport' 'Export') -X 0 -Y 10 -Width 120 -Height 28 -Glyph ([string][char]0xE72D)
$snapExport.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$snapExport.Enabled = $false
$snapExport.Add_Click({
    if (-not $script:SelectedSnapshotPath) { return }
    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Title = (T 'ExportSnapshotTitle' 'Export snapshot')
    $dialog.Filter = (T 'SnapJsonFilter' 'Snapshot JSON (*.json)|*.json')
    $dialog.FileName = Split-Path -Leaf $script:SelectedSnapshotPath
    try {
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            [void](Export-SRSnapshotFile -Path $script:SelectedSnapshotPath -Destination $dialog.FileName)
            Show-StudioToast ('Snapshot exported to ' + $dialog.FileName) $script:P.Green
        }
    } catch {
        Show-StudioToast ('Could not export: ' + $_.Exception.Message) $script:P.Red
    } finally {
        $dialog.Dispose()
    }
})
$snapListCard.Controls.Add($snapExport)
$script:Ui.SnapExport = $snapExport

$snapImport = New-StudioButton -Text (T 'BtnImport' 'Import') -X 0 -Y 10 -Width 120 -Height 28 -Glyph ([string][char]0xE896)
$snapImport.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$snapImport.Add_Click({
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = (T 'ImportSnapshotTitle' 'Import snapshot')
    $dialog.Filter = (T 'SnapJsonFilter' 'Snapshot JSON (*.json)|*.json')
    try {
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $path = Import-SRSnapshotFile -Path $dialog.FileName
            Refresh-StudioData
            Refresh-StudioSnapshotRows
            $script:SelectedSnapshotPath = $path
            Select-StudioSnapshotRow -Path $path -Immediate
            Show-StudioToast ('Snapshot imported: ' + (Split-Path -Leaf $path)) $script:P.Green
        }
    } catch {
        Show-StudioToast ('Could not import: ' + $_.Exception.Message) $script:P.Red
    } finally {
        $dialog.Dispose()
    }
})
$snapListCard.Controls.Add($snapImport)
$script:Ui.SnapImport = $snapImport

$snapFlow = New-Object System.Windows.Forms.FlowLayoutPanel
$snapFlow.Location = New-Object System.Drawing.Point(14, 54)
$snapFlow.Size = New-Object System.Drawing.Size(508, 510)
$snapFlow.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$snapFlow.FlowDirection = [System.Windows.Forms.FlowDirection]::TopDown
$snapFlow.WrapContents = $false
$snapFlow.AutoScroll = $true
$snapFlow.BackColor = $script:P.Card
$snapFlow.Padding = New-Object System.Windows.Forms.Padding(0)
$snapListCard.Controls.Add($snapFlow)
$script:Ui.SnapFlow = $snapFlow

$snapEmpty = New-StudioLabel -Text (T 'NoSnapshotsMatch' 'No snapshots match this view.') -X 18 -Y 60 -Width 400 -Height 30 -Font $script:FontBody -Color $script:P.Muted
$snapEmpty.Visible = $false
$snapListCard.Controls.Add($snapEmpty)
$script:Ui.SnapEmpty = $snapEmpty

$detailCard = New-StudioCard -X 0 -Y 0 -Width 376 -Height 580
$detailCard.Dock = [System.Windows.Forms.DockStyle]::Fill
$detailCard.CanvasColor = $script:P.Bg
$snapSplit.Panel2.Controls.Add($detailCard)
$script:Ui.DetailCard = $detailCard

$detailBadge = New-StudioBadge -Text (T 'BadgeNoSnapshot' 'NO SNAPSHOT') -Width 104 -Height 22 -Fill $script:P.CardAlt -TextColor $script:P.Muted
$detailBadge.Location = New-Object System.Drawing.Point(18, 16)
$detailCard.Controls.Add($detailBadge)
$script:Ui.DetailBadge = $detailBadge

$detailPin = New-StudioButton -Text (T 'BtnPin' 'Pin') -X 0 -Y 13 -Width 118 -Height 28 -Glyph ([string][char]0xE840)
$detailPin.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$detailPin.Enabled = $false
$detailPin.Add_Click({ Toggle-StudioSnapshotPin })
$detailCard.Controls.Add($detailPin)
$script:Ui.DetailPin = $detailPin

$detailNote = New-StudioButton -Text (T 'BtnNote' 'Note') -X 0 -Y 13 -Width 92 -Height 28 -Glyph ''
$detailNote.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$detailNote.Enabled = $false
$detailNote.Add_Click({ Show-StudioSnapshotNoteDialog })
$detailCard.Controls.Add($detailNote)
$script:Ui.DetailNote = $detailNote

$detailTitle = New-StudioLabel -Text (T 'SelectSnapshot' 'Select a snapshot') -X 18 -Y 48 -Width 340 -Height 28 -Font $script:FontSemiboldLarge -Color $script:P.Text
$detailTitle.AutoEllipsis = $true
$detailCard.Controls.Add($detailTitle)
$script:Ui.DetailTitle = $detailTitle
$detailMeta = New-StudioLabel -Text '' -X 18 -Y 77 -Width 340 -Height 18 -Font $script:FontBodySmall -Color $script:P.Muted
$detailCard.Controls.Add($detailMeta)
$script:Ui.DetailMeta = $detailMeta
$detailSummary = New-StudioLabel -Text (T 'CaptureMomentHint' 'Capture a moment, then select it here to inspect and restore it.') -X 18 -Y 99 -Width 340 -Height 34 -Font $script:FontBodySmall -Color $script:P.Subtle
$detailCard.Controls.Add($detailSummary)
$script:Ui.DetailSummary = $detailSummary

# Optional window thumbnails: one strip of small previews above the text,
# filled only when the snapshot was captured with thumbnails enabled.
$detailThumbs = New-Object System.Windows.Forms.FlowLayoutPanel
$detailThumbs.Location = New-Object System.Drawing.Point(18, 134)
$detailThumbs.Size = New-Object System.Drawing.Size(340, 0)
$detailThumbs.Margin = New-Object System.Windows.Forms.Padding(0)
$detailThumbs.Padding = New-Object System.Windows.Forms.Padding(0)
$detailThumbs.BackColor = $script:P.Card
$detailThumbs.AutoScroll = $false
$detailThumbs.WrapContents = $true
$detailThumbs.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$detailCard.Controls.Add($detailThumbs)
$script:Ui.DetailThumbs = $detailThumbs

$detailText = New-StudioTextBox -X 18 -Y 138 -Width 340 -Height 350
$detailText.Multiline = $true
$detailText.ReadOnly = $true
# ReadOnly switches the TextBox back to the system color, so the theme
# background must be applied after ReadOnly or the box renders white.
$detailText.BackColor = $script:P.CardAlt
$detailText.ScrollBars = [System.Windows.Forms.ScrollBars]::Both
$detailText.WordWrap = $false
$detailText.Font = $script:FontMono
$detailText.BackColor = $script:P.CardAlt
$detailText.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$detailCard.Controls.Add($detailText)
$script:Ui.DetailText = $detailText

$detailRestore = New-StudioButton -Text (T 'BtnRestoreSelected' 'Restore selected') -X 18 -Y 500 -Width 174 -Height 36 -Primary -Glyph ''

$detailRestore.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
$detailRestore.Enabled = $false
$detailRestore.Add_Click({
    if ($script:SelectedSnapshotPath) { Open-StudioRestore -SnapshotPath $script:SelectedSnapshotPath }
})
$detailCard.Controls.Add($detailRestore)
$script:Ui.DetailRestore = $detailRestore

$detailOpen = New-StudioButton -Text (T 'BtnOpen' 'Open') -X 172 -Y 500 -Width 78 -Height 36
$detailOpen.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
$detailOpen.Enabled = $false
$detailOpen.Add_Click({
    if ($script:SelectedSnapshotPath) { Open-StudioPath (Split-Path -Parent $script:SelectedSnapshotPath) }
})
$detailCard.Controls.Add($detailOpen)
$script:Ui.DetailOpen = $detailOpen

$detailDelete = New-StudioButton -Text (T 'BtnDelete' 'Delete') -X 256 -Y 500 -Width 80 -Height 36 -Danger
$detailDelete.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
$detailDelete.Enabled = $false
$detailDelete.Add_Click({
    if (-not $script:SelectedSnapshotPath) { return }
    $answer = [System.Windows.Forms.MessageBox]::Show(
        (T 'ConfirmDeleteSnapshotText' "Delete this snapshot?`r`n`r`nThis removes only the saved JSON file. It cannot be undone."),
        (T 'ConfirmDeleteSnapshotTitle' 'Delete snapshot'), [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    $path = $script:SelectedSnapshotPath
    try {
        $wasPinned = Test-SRSnapshotPinned -Path $path
        Remove-Item -LiteralPath $path -Force -ErrorAction Stop
        if ($wasPinned) {
            try { [void](Set-SRSnapshotPinned -Path $path -Pinned $false) } catch { }
        }
        try { [void](Set-SRSnapshotNote -Path $path -Note '') } catch { }
        $script:SelectedSnapshotPath = $null
        Refresh-StudioData
        Refresh-StudioSnapshotRows
        Show-StudioToast (T 'ToastSnapshotDeleted' 'Snapshot deleted.') $script:P.Green
    } catch {
        Show-StudioToast ((T 'ToastDeleteFailed' 'Could not delete snapshot: {0}') -f $_.Exception.Message) $script:P.Red
    }
})
$detailCard.Controls.Add($detailDelete)
$script:Ui.DetailDelete = $detailDelete

$detailCard.Add_Resize({
    $card = $script:Ui.DetailCard
    if (-not $card) { return }
    $script:Ui.DetailTitle.Width = $card.ClientSize.Width - 36
    $script:Ui.DetailMeta.Width = $card.ClientSize.Width - 36
    $script:Ui.DetailSummary.Width = $card.ClientSize.Width - 36
    $script:Ui.DetailText.Width = $card.ClientSize.Width - 36
    $thumbsExtra = 0
    try { $thumbsExtra = [int]$script:DetailThumbsHeight } catch { }
    if ($script:Ui.DetailText.Top -lt (138 + $thumbsExtra)) { $script:Ui.DetailText.Top = 138 + $thumbsExtra + 6 }
    $script:Ui.DetailText.Height = [Math]::Max(120, $card.ClientSize.Height - $script:Ui.DetailText.Top - 62)
    $script:Ui.DetailPin.Left = $card.ClientSize.Width - 18 - $script:Ui.DetailPin.Width
    $script:Ui.DetailNote.Left = $script:Ui.DetailPin.Left - 8 - $script:Ui.DetailNote.Width
    $script:Ui.DetailRestore.Top = $card.ClientSize.Height - 54
    $script:Ui.DetailOpen.Top = $card.ClientSize.Height - 54
    $script:Ui.DetailDelete.Top = $card.ClientSize.Height - 54
    $script:Ui.DetailDelete.Left = $card.ClientSize.Width - 92
    $script:Ui.DetailOpen.Left = $script:Ui.DetailDelete.Left - 84
    $script:Ui.DetailRestore.Width = [Math]::Max(148, $script:Ui.DetailOpen.Left - 26)
    $script:Ui.DetailRestore.BringToFront()
    $script:Ui.DetailOpen.BringToFront()
    $script:Ui.DetailDelete.BringToFront()
})

function Get-StudioSelectedSnapshotEntry {
    if ([string]::IsNullOrWhiteSpace($script:SelectedSnapshotPath)) { return $null }
    foreach ($entry in $script:Snapshots) {
        if ($entry.Path -eq $script:SelectedSnapshotPath) { return $entry }
    }
    return $null
}

function Toggle-StudioSnapshotPin {
    if (-not $script:SelectedSnapshotPath) { return }
    try {
        $isPinned = Test-SRSnapshotPinned -Path $script:SelectedSnapshotPath
        [void](Set-SRSnapshotPinned -Path $script:SelectedSnapshotPath -Pinned (-not $isPinned))
        $script:Config = Get-SRConfig
        Refresh-StudioSnapshotRows
        Update-StudioSnapshotDetails
        if ($isPinned) {
            Show-StudioToast (T 'ToastSnapshotUnpinned' 'Snapshot unpinned. Retention may delete it again.') $script:P.Muted
        } else {
            Show-StudioToast (T 'ToastSnapshotPinned' 'Snapshot pinned. Automatic cleanup will keep it.') $script:P.Green
        }
    } catch {
        Show-StudioToast ((T 'ToastPinFailed' 'Could not update the pin: {0}') -f $_.Exception.Message) $script:P.Red
    }
}

function Show-StudioSnapshotNoteDialog {
    $entry = Get-StudioSelectedSnapshotEntry
    if ($null -eq $entry) { return }
    $existing = ''
    try { $existing = [string](Get-SRSnapshotNote -Path $entry.Path) } catch { $existing = '' }

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = (T 'NoteDialogTitle' 'Snapshot note')
    $dialog.ClientSize = New-Object System.Drawing.Size(440, 262)
    $dialog.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.ShowInTaskbar = $false
    $dialog.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $dialog.BackColor = $script:P.Bg
    $dialog.ForeColor = $script:P.Text
    $dialog.Font = $script:FontBody
    try { if ($script:IconPath) { $dialog.Icon = New-Object System.Drawing.Icon($script:IconPath) } } catch { }

    $hint = New-StudioLabel -Text (T 'NoteDialogHint' 'Notes stay in config.json on this PC. They are included in a Recovery Kit and can be searched.') -X 18 -Y 14 -Width 404 -Height 34 -Font $script:FontBodySmall -Color $script:P.Muted
    $dialog.Controls.Add($hint)
    $box = New-StudioTextBox -X 18 -Y 54 -Width 404 -Height 118
    $box.Multiline = $true
    $box.AcceptsReturn = $true
    $box.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $box.MaxLength = 500
    $box.Text = $existing
    $dialog.Controls.Add($box)

    $context = [pscustomobject]@{ Path = [string]$entry.Path; Box = $box }
    $save = New-StudioButton -Text (T 'BtnSaveNote' 'Save note') -X 18 -Y 210 -Width 136 -Height 34 -Primary
    $save.Tag = $context
    $save.Add_Click({
        param($sender, $eventArgs)
        $state = $sender.Tag
        try {
            [void](Set-SRSnapshotNote -Path $state.Path -Note ([string]$state.Box.Text))
            $script:Config = Get-SRConfig
            Refresh-StudioSnapshotRows
            Update-StudioSnapshotDetails
            Show-StudioToast (T 'ToastNoteSaved' 'Note saved.') $script:P.Green
            $sender.FindForm().Close()
        } catch {
            Show-StudioToast ((T 'ToastNoteFailed' 'Could not save the note: {0}') -f $_.Exception.Message) $script:P.Red
        }
    })
    $dialog.Controls.Add($save)
    $remove = New-StudioButton -Text (T 'BtnRemoveNote' 'Remove note') -X 166 -Y 210 -Width 136 -Height 34 -Danger
    $remove.Tag = $context
    $remove.Visible = -not [string]::IsNullOrWhiteSpace($existing)
    $remove.Add_Click({
        param($sender, $eventArgs)
        $state = $sender.Tag
        try {
            [void](Set-SRSnapshotNote -Path $state.Path -Note '')
            $script:Config = Get-SRConfig
            Refresh-StudioSnapshotRows
            Update-StudioSnapshotDetails
            Show-StudioToast (T 'ToastNoteRemoved' 'Note removed.') $script:P.Green
            $sender.FindForm().Close()
        } catch {
            Show-StudioToast ((T 'ToastNoteFailed' 'Could not save the note: {0}') -f $_.Exception.Message) $script:P.Red
        }
    })
    $dialog.Controls.Add($remove)
    $cancel = New-StudioButton -Text (T 'BtnCancel' 'Cancel') -X 314 -Y 210 -Width 108 -Height 34 -Glyph ''
    $cancel.Add_Click({ param($sender, $eventArgs) $sender.FindForm().Close() })
    $dialog.Controls.Add($cancel)
    $dialog.AcceptButton = $save
    $dialog.CancelButton = $cancel
    $dialog.Add_Shown({ param($sender, $eventArgs) $sender.ActiveControl = $sender.Controls[1]; $sender.Controls[1].Focus() })
    try { [void]$dialog.ShowDialog($form) } finally { $dialog.Dispose() }
}

function Update-StudioSnapshotDetails {
    if (-not $script:Ui.DetailTitle) { return }
    $entry = Get-StudioSelectedSnapshotEntry
    if ($null -eq $entry) {
        if ($script:Ui.DetailThumbs) { $script:Ui.DetailThumbs.Controls.Clear(); $script:Ui.DetailThumbs.Height = 0 }
        $script:DetailThumbsHeight = 0
        if ($script:Ui.DetailText) { $script:Ui.DetailText.Top = 138 }
        # Keep the text box inside the card: a thumbnail strip raises the top,
        # so the height must shrink with it (the resize handler only sees
        # card-size changes, not content changes).
        if ($script:Ui.DetailText -and $script:Ui.DetailCard) {
            $script:Ui.DetailText.Height = [Math]::Max(120, $script:Ui.DetailCard.ClientSize.Height - $script:Ui.DetailText.Top - 62)
        }
        $script:Ui.DetailBadge.Text = (T 'BadgeNoSnapshot' 'NO SNAPSHOT')
        $script:Ui.DetailBadge.FillColor = $script:P.CardAlt
        $script:Ui.DetailBadge.TextColor = $script:P.Muted
        $script:Ui.DetailTitle.Text = (T 'SelectSnapshot' 'Select a snapshot')
        $script:Ui.DetailMeta.Text = ''
        $script:Ui.DetailSummary.Text = (T 'CaptureMomentHint' 'Capture a moment, then select it here to inspect and restore it.')
        $script:Ui.DetailText.Text = ''
        $script:Ui.DetailRestore.Enabled = $false
        $script:Ui.DetailOpen.Enabled = $false
        $script:Ui.DetailDelete.Enabled = $false
        if ($script:Ui.DetailPin) {
            $script:Ui.DetailPin.Enabled = $false
            $script:Ui.DetailPin.Text = (T 'BtnPin' 'Pin')
        }
        if ($script:Ui.DetailNote) { $script:Ui.DetailNote.Enabled = $false }
        if ($script:Ui.SnapExport) { $script:Ui.SnapExport.Enabled = $false }
        return
    }

    $snapshot = $entry.Snapshot
    $stats = Get-StudioStats -Snapshot $snapshot

    # Window thumbnails (only present when captured with the opt-in setting).
    $thumbHeight = 0
    if ($script:Ui.DetailThumbs) {
        $script:Ui.DetailThumbs.SuspendLayout()
        $script:Ui.DetailThumbs.Controls.Clear()
        $thumbPaths = @()
        foreach ($app in @($snapshot.apps)) {
            $thumbProperty = $app.PSObject.Properties['thumb']
            if ($null -ne $thumbProperty -and -not [string]::IsNullOrWhiteSpace([string]$thumbProperty.Value)) { $thumbPaths += [string]$thumbProperty.Value }
        }
        foreach ($browser in @($snapshot.browsers)) {
            $thumbProperty = $browser.PSObject.Properties['thumb']
            if ($null -ne $thumbProperty -and -not [string]::IsNullOrWhiteSpace([string]$thumbProperty.Value)) { $thumbPaths += [string]$thumbProperty.Value }
        }
        $snapshotRoot = Get-SRSnapshotDirectory
        $shown = 0
        foreach ($relative in (@($thumbPaths | Select-Object -First 12))) {
            $thumbFile = Join-Path $snapshotRoot ($relative -replace '/', '\')
            if (-not (Test-Path -LiteralPath $thumbFile)) { continue }
            try {
                $box = New-Object System.Windows.Forms.PictureBox
                $box.Size = New-Object System.Drawing.Size(106, 62)
                $box.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
                $box.BackColor = $script:P.CardAlt
                $box.Margin = New-Object System.Windows.Forms.Padding(1)
                $box.Image = [System.Drawing.Image]::FromFile($thumbFile)
                $script:Ui.DetailThumbs.Controls.Add($box)
                $shown++
            } catch { }
        }
        $perRow = [Math]::Max(1, [int][Math]::Floor(($script:Ui.DetailThumbs.ClientSize.Width) / 108))
        $rows = [Math]::Ceiling($shown / $perRow)
        $thumbHeight = [int]($rows * 64)
        if ($shown -eq 0) { $thumbHeight = 0 }
        $script:Ui.DetailThumbs.Height = $thumbHeight
        $script:Ui.DetailThumbs.ResumeLayout()
    }
    $script:DetailThumbsHeight = $thumbHeight
    if ($script:Ui.DetailText) {
        $script:Ui.DetailText.Top = 138 + $thumbHeight + 6
        if ($script:Ui.DetailCard) {
            # Shrink with the thumbnail strip so the text never runs under
            # the Restore/Open/Delete buttons at the bottom of the card.
            $script:Ui.DetailText.Height = [Math]::Max(120, $script:Ui.DetailCard.ClientSize.Height - $script:Ui.DetailText.Top - 62)
        }
    }

    $bytes = Get-StudioSnapshotBytes -Entry $entry
    $isPinned = ($script:SnapshotPinnedNames -and $script:SnapshotPinnedNames.Contains((Split-Path -Leaf $entry.Path)))
    $script:Ui.DetailBadge.Text = if ($isPinned) { (T 'BadgePinned' 'PINNED') } else { (T 'BadgeReady' 'READY TO RESTORE') }
    $script:Ui.DetailBadge.FillColor = if ($isPinned) { $script:P.AccentSoft } else { $script:P.GreenSoft }
    $script:Ui.DetailBadge.TextColor = if ($isPinned) { $script:P.Accent } else { $script:P.Green }
    $script:Ui.DetailTitle.Text = Format-StudioDate -Date $entry.CapturedAt -Format 'dddd, MMM d  •  HH:mm:ss'
    $pinnedText = if ($isPinned) { (T 'DetailPinnedSuffix' '  •  pinned') } else { '' }
    try {
        $reasonProperty = $entry.Snapshot.PSObject.Properties['reason']
        if ($null -ne $reasonProperty -and [string]$reasonProperty.Value -eq 'hibernate') {
            $pinnedText += (T 'DetailHibernateSuffix' '  •  hibernate checkpoint')
        }
    } catch { }
    $script:Ui.DetailMeta.Text = ((T 'DetailMetaAppsTabs' '{0}  •  {1}  •  {2} app(s)  •  {3} folder(s){4}') -f (Format-StudioAge -CapturedAt $entry.CapturedAt), (Format-StudioBytes -Bytes $bytes), $stats.Apps, $stats.Folders, $pinnedText)
    $script:Ui.DetailSummary.Text = ((T 'DetailSummaryCaptured' 'Captured {0} browser tab(s) across {1} browser(s). Nothing in this snapshot modifies files.') -f $stats.Tabs, $stats.Browsers)
    $script:Ui.DetailRestore.Enabled = $true
    $script:Ui.DetailOpen.Enabled = $true
    $script:Ui.DetailDelete.Enabled = $true
    if ($script:Ui.DetailPin) {
        $script:Ui.DetailPin.Enabled = $true
        $script:Ui.DetailPin.Text = if ($isPinned) { (T 'BtnUnpin' 'Unpin') } else { (T 'BtnPin' 'Pin') }
    }
    if ($script:Ui.DetailNote) { $script:Ui.DetailNote.Enabled = $true }
    if ($script:Ui.SnapExport) { $script:Ui.SnapExport.Enabled = $true }

    $lines = New-Object System.Collections.Generic.List[string]
    try {
        $noteTable = ConvertTo-SRNoteTable -Value $script:Config.snapshotNotes
        $noteLeaf = Split-Path -Leaf $entry.Path
        if ($noteTable.ContainsKey($noteLeaf)) {
            $lines.Add((T 'DetailNote' 'NOTE'))
            foreach ($noteLine in ([string]$noteTable[$noteLeaf] -split "`r?`n")) {
                $lines.Add('  ' + $noteLine)
            }
            $lines.Add('')
        }
    } catch { }

    # What changed vs the previous snapshot: new/closed apps and tab movement.
    try {
        $previousEntry = @($script:Snapshots | Where-Object { $_.CapturedAt -lt $entry.CapturedAt } | Select-Object -First 1)
        if ($previousEntry.Count -gt 0) {
            $previous = $previousEntry[0].Snapshot
            $nameOf = {
                param($App)
                $n = [string]$App.displayName
                if ([string]::IsNullOrWhiteSpace($n)) { $n = [string]$App.name }
                if ([string]::IsNullOrWhiteSpace($n)) { $n = [string]$App.exe }
                return $n.ToLowerInvariant()
            }
            $current = @($snapshot.apps | ForEach-Object { & $nameOf $_ })
            $before = @($previous.apps | ForEach-Object { & $nameOf $_ })
            $newApps = @($current | Where-Object { $_ -and ($before -notcontains $_) })
            $closedApps = @($before | Where-Object { $_ -and ($current -notcontains $_) })
            $prevStats = Get-StudioStats -Snapshot $previous
            $tabDelta = $stats.Tabs - $prevStats.Tabs
            if ($newApps.Count -eq 0 -and $closedApps.Count -eq 0 -and $tabDelta -eq 0) {
                $lines.Add((T 'WhatsChanged' 'WHAT CHANGED'))
                $lines.Add('  ' + (T 'DiffNone' 'No changes since the previous snapshot.'))
                $lines.Add('')
            } else {
                $lines.Add((T 'WhatsChanged' 'WHAT CHANGED'))
                if ($newApps.Count -gt 0) {
                    $lines.Add(('+ ' + ((T 'DiffNewApps' 'New: {0}') -f ($newApps -join ', '))))
                }
                if ($closedApps.Count -gt 0) {
                    $lines.Add(('- ' + ((T 'DiffClosedApps' 'Closed: {0}') -f ($closedApps -join ', '))))
                }
                if ($tabDelta -ne 0) {
                    $lines.Add(('~ ' + ((T 'DiffTabs' 'Tabs: {0}') -f $tabDelta)))
                }
                $lines.Add('')
            }
        }
    } catch { }

    $mediaApps = @($snapshot.apps | Where-Object {
        $prop = $_.PSObject.Properties['media']
        $null -ne $prop -and $null -ne $prop.Value
    })
    if ($mediaApps.Count -gt 0) {
        $lines.Add((T 'DetailPlaying' 'PLAYING'))
        foreach ($mediaApp in $mediaApps) {
            $media = $mediaApp.media
            $clock = ''
            try {
                $total = [int][Math]::Floor([double]$media.positionSeconds)
                $hours = [int][Math]::Floor($total / 3600)
                $minutes = [int][Math]::Floor(($total % 3600) / 60)
                $seconds = $total % 60
                if ($hours -gt 0) { $clock = ('{0}:{1:00}:{2:00}' -f $hours, $minutes, $seconds) }
                else { $clock = ('{0}:{1:00}' -f $minutes, $seconds) }
            } catch { }
            $mark = if ($media.estimated) { '~' } else { '' }
            $lines.Add(((T 'DetailPlayingLine' '  {0}  {1}  at {2}{3}') -f ([string]$mediaApp.name), (Split-Path -Leaf ([string]$media.file)), $mark, $clock))
        }
        $lines.Add('')
    }
    $lines.Add((T 'DetailApplications' 'APPLICATIONS'))
    if ($stats.Apps -eq 0) {
        $lines.Add((T 'DetailNoneCaptured' '  (none captured)'))
    } else {
        $count = 0
        foreach ($app in @($snapshot.apps)) {
            if ($count -ge 14) { $lines.Add('  ...'); break }
            $appName = [string]$app.displayName
            if ([string]::IsNullOrWhiteSpace($appName)) { $appName = [string]$app.name }
            if ([string]::IsNullOrWhiteSpace($appName)) { $appName = [string]$app.processName }
            if ([string]::IsNullOrWhiteSpace($appName)) { $appName = (T 'DetailApplicationFallback' 'Application') }
            $appExe = [string]$app.exe
            if ([string]::IsNullOrWhiteSpace($appExe)) { $appExe = [string]$app.path }
            $lines.Add(('  {0}  {1}' -f $appName, $appExe))
            $count++
        }
    }
    $lines.Add('')
    $lines.Add((T 'DetailFolders' 'FOLDERS'))
    if ($stats.Folders -eq 0) {
        $lines.Add((T 'DetailNoneCaptured' '  (none captured)'))
    } else {
        $count = 0
        foreach ($folder in @($snapshot.explorer)) {
            if ($count -ge 10) { $lines.Add('  ...'); break }
            $lines.Add('  ' + [string]$folder)
            $count++
        }
    }
    $lines.Add('')
    $lines.Add((T 'DetailBrowserTabs' 'BROWSER TABS'))
    if ($stats.Browsers -eq 0) {
        $lines.Add((T 'DetailNoneCaptured' '  (none captured)'))
    } else {
        foreach ($browser in @($snapshot.browsers)) {
            $lines.Add(('  {0}' -f [string]$browser.name))
            foreach ($profile in @($browser.profiles)) {
                $approx = ''
                if ($profile.tabsApproximate) { $approx = '  ' + (T 'DetailApproximate' '[approximate]') }
                $lines.Add(('    {0}  ({1} tab(s)){2}' -f [string]$profile.displayName, @($profile.tabs).Count, $approx))
                $tabCount = 0
                foreach ($tab in @($profile.tabs)) {
                    if ($tabCount -ge 8) { $lines.Add('      ...'); break }
                    $title = [string]$tab.title
                    if ([string]::IsNullOrWhiteSpace($title)) { $title = [string]$tab.url }
                    $lines.Add(('      • {0}' -f $title))
                    if (-not [string]::IsNullOrWhiteSpace([string]$tab.url)) {
                        $lines.Add(('        {0}' -f [string]$tab.url))
                    }
                    $tabCount++
                }
            }
        }
    }
    $script:Ui.DetailText.Text = ($lines -join "`r`n")
    $script:Ui.DetailText.SelectionStart = 0
    $script:Ui.DetailText.SelectionLength = 0
}

function Select-StudioSnapshotRow {
    param([string]$Path, [switch]$Immediate)
    $script:SelectedSnapshotPath = $Path
    foreach ($row in $script:SnapshotRows) {
        if ($null -eq $row) { continue }
        $isSelected = ([string]$row.Tag -eq $Path)
        $row.Selected = $isSelected
        if ($isSelected) {
            $row.BorderColor = $script:P.Accent
        } else {
            $row.BorderColor = $script:P.BorderSoft
        }
    }
    if ($Immediate) {
        Update-StudioSnapshotDetails
        return
    }
    if ($null -eq $script:SnapshotDetailsTimer) {
        $script:SnapshotDetailsTimer = New-Object System.Windows.Forms.Timer
        $script:SnapshotDetailsTimer.Interval = 25
        $script:SnapshotDetailsTimer.Add_Tick({
            $script:SnapshotDetailsTimer.Stop()
            Update-StudioSnapshotDetails
        })
    }
    $script:SnapshotDetailsTimer.Stop()
    $script:SnapshotDetailsTimer.Start()
}

function New-StudioSnapshotRowControl {
    param(
        $Entry,
        [int]$Width,
        [scriptblock]$ClickHandler
    )
    $stats = Get-StudioStats -Snapshot $Entry.Snapshot
    $approx = $false
    foreach ($browser in @($Entry.Snapshot.browsers)) {
        foreach ($profile in @($browser.profiles)) {
            if ($profile.tabsApproximate) { $approx = $true }
        }
    }
    $row = New-Object SessionRecovery.Studio.StudioSnapshotRow
    $row.Location = New-Object System.Drawing.Point(0, 0)
    $row.Size = New-Object System.Drawing.Size($Width, 66)
    $row.FillColor = $script:P.CardAlt
    $row.BorderColor = $script:P.BorderSoft
    $row.CanvasColor = $script:P.Card
    $row.TextColor = $script:P.Text
    $row.MutedColor = $script:P.Muted
    $row.SubtleColor = $script:P.Subtle
    $row.AccentColor = $script:P.Accent
    $row.AmberColor = $script:P.Amber
    $row.AmberSoft = $script:P.AmberSoft
    $row.PinnedSoft = $script:P.AccentSoft
    $row.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 7)
    $row.Tag = $Entry.Path
    $row.TimeText = Format-StudioDate -Date $Entry.CapturedAt -Format 'ddd  •  MMM d  •  HH:mm:ss'
    $row.MetaText = ((T 'SnapRowMeta' '{0} app(s)  •  {1} tab(s)  •  {2}') -f $stats.Apps, $stats.Tabs, (Format-StudioBytes -Bytes (Get-StudioSnapshotBytes -Entry $Entry)))
    try {
        $reasonProperty = $Entry.Snapshot.PSObject.Properties['reason']
        if ($null -ne $reasonProperty -and [string]$reasonProperty.Value -eq 'hibernate') {
            $row.MetaText += '  •  ' + (T 'SnapRowHibernate' 'hibernate')
        }
    } catch { }
    if ($script:SnapshotNotes -and $script:SnapshotNotes.ContainsKey((Split-Path -Leaf $Entry.Path))) {
        $row.MetaText += '  •  ' + (T 'SnapRowNote' 'note')
    }
    $row.AgeText = Format-StudioAge -CapturedAt $Entry.CapturedAt
    $row.Approximate = $approx
    $row.ApproxLabel = (T 'BadgeApprox' 'APPROX')
    $row.PinnedLabel = (T 'BadgePinned' 'PINNED')
    $row.Pinned = ($null -ne $script:SnapshotPinnedNames -and $script:SnapshotPinnedNames.Contains((Split-Path -Leaf $Entry.Path)))
    $row.Selected = ([string]$row.Tag -eq [string]$script:SelectedSnapshotPath)
    $row.AccessibleName = ('{0}. {1}. {2}.' -f $row.TimeText, $row.MetaText, $row.AgeText)
    $row.AccessibleDescription = (T 'SnapRowAccessibleDesc' 'Snapshot. Select to preview and restore.')
    $row.Add_Click($ClickHandler)
    return $row
}

function Add-StudioSnapshotBatch {
    param([int]$BatchSize = 8)
    if (-not $script:Ui.SnapFlow) { return }
    $total = $script:SnapshotBuildQueue.Count
    if ($script:SnapshotBuildIndex -ge $total) {
        if ($script:SnapshotBuildTimer) { $script:SnapshotBuildTimer.Stop() }
        return
    }
    $end = [Math]::Min($total, $script:SnapshotBuildIndex + $BatchSize)
    $firstBatch = ($script:SnapshotBuildIndex -eq 0)
    $flow = $script:Ui.SnapFlow
    $flow.SuspendLayout()
    try {
        for ($index = $script:SnapshotBuildIndex; $index -lt $end; $index++) {
            $row = New-StudioSnapshotRowControl -Entry $script:SnapshotBuildQueue[$index] -Width $script:SnapshotBuildWidth -ClickHandler $script:SnapshotClickHandler
            [void]$flow.Controls.Add($row)
            $script:SnapshotRows += $row
        }
        $script:SnapshotBuildIndex = $end
    } finally {
        $flow.ResumeLayout($true)
    }
    if ($firstBatch -or $script:SnapshotBuildIndex -ge $total) {
        Select-StudioSnapshotRow -Path $script:SelectedSnapshotPath
    }
    if ($script:SnapshotBuildIndex -lt $total) {
        if ($null -eq $script:SnapshotBuildTimer) {
            $script:SnapshotBuildTimer = New-Object System.Windows.Forms.Timer
            $script:SnapshotBuildTimer.Interval = 15
            $script:SnapshotBuildTimer.Add_Tick({ Add-StudioSnapshotBatch -BatchSize 8 })
        }
        if (-not $script:SnapshotBuildTimer.Enabled) { $script:SnapshotBuildTimer.Start() }
    } elseif ($script:SnapshotBuildTimer) {
        $script:SnapshotBuildTimer.Stop()
    }
}

function Test-StudioSnapshotContent {
    param($Entry, [string]$Needle)
    # Search covers the capture date and file name as before, plus everything
    # the snapshot recorded: application names and paths, Explorer folders,
    # browser names, tab titles and URLs.
    $haystack = ($Entry.Path + ' ' + (Format-StudioDate -Date $Entry.CapturedAt -Format 'yyyy-MM-dd HH:mm') + ' ' + (Format-StudioDate -Date $Entry.CapturedAt -Format 'dddd')).ToLowerInvariant()
    if ($haystack.Contains($Needle)) { return $true }
    if ($script:SnapshotNotes -and $script:SnapshotNotes.ContainsKey((Split-Path -Leaf $Entry.Path))) {
        if (([string]$script:SnapshotNotes[(Split-Path -Leaf $Entry.Path)]).ToLowerInvariant().Contains($Needle)) { return $true }
    }

    $snapshot = $Entry.Snapshot
    if ($null -eq $snapshot) { return $false }

    foreach ($app in @($snapshot.apps)) {
        if ($null -eq $app) { continue }
        if (([string]$app.name).ToLowerInvariant().Contains($Needle)) { return $true }
        if (([string]$app.exe).ToLowerInvariant().Contains($Needle)) { return $true }
    }
    foreach ($folder in @($snapshot.explorer)) {
        if (([string]$folder).ToLowerInvariant().Contains($Needle)) { return $true }
    }
    foreach ($browser in @($snapshot.browsers)) {
        if ($null -eq $browser) { continue }
        if (([string]$browser.name).ToLowerInvariant().Contains($Needle)) { return $true }
        foreach ($profile in @($browser.profiles)) {
            if ($null -eq $profile) { continue }
            if (([string]$profile.displayName).ToLowerInvariant().Contains($Needle)) { return $true }
            foreach ($tab in @($profile.tabs)) {
                if ($null -eq $tab) { continue }
                if (([string]$tab.title).ToLowerInvariant().Contains($Needle)) { return $true }
                if (([string]$tab.url).ToLowerInvariant().Contains($Needle)) { return $true }
            }
        }
    }
    return $false
}

function Refresh-StudioSnapshotRows {
    if (-not $script:Ui.SnapFlow) { return }
    if ($script:SnapshotLayoutTimer) { $script:SnapshotLayoutTimer.Stop() }
    if ($script:SnapshotBuildTimer) { $script:SnapshotBuildTimer.Stop() }
    if ($script:Snapshots.Count -eq 0) {
        $script:Snapshots = @(Get-SRSnapshots)
    }
    $script:LastSnapFlowWidth = [Math]::Max(300, $script:Ui.SnapFlow.ClientSize.Width - 22)

    $search = [string]$script:Ui.SnapSearch.Text
    if ($script:Ui.SnapSearch.Tag -eq 'placeholder') { $search = '' }
    $search = $search.Trim()
    $mode = [string]$script:Ui.SnapFilter.SelectedItem
    # The cutoff is derived from the selected index, not the display text, so
    # translated filter labels keep working.
    $cutoff = $null
    if ($script:Ui.SnapFilter.SelectedIndex -eq 1) { $cutoff = (Get-Date).AddHours(-1) }
    elseif ($script:Ui.SnapFilter.SelectedIndex -eq 2) { $cutoff = (Get-Date).AddHours(-24) }
    elseif ($script:Ui.SnapFilter.SelectedIndex -eq 3) { $cutoff = (Get-Date).AddDays(-7) }

    $script:SnapshotPinnedNames = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    try {
        foreach ($pinned in @($script:Config.pinnedSnapshots)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$pinned)) { [void]$script:SnapshotPinnedNames.Add([string]$pinned) }
        }
    } catch { }
    $script:SnapshotNotes = ConvertTo-SRNoteTable -Value $script:Config.snapshotNotes

    $needle = ''
    if (-not [string]::IsNullOrWhiteSpace($search)) { $needle = $search.ToLowerInvariant() }

    $filtered = New-Object System.Collections.Generic.List[object]
    foreach ($entry in $script:Snapshots) {
        if ($null -ne $cutoff -and $entry.CapturedAt -lt $cutoff) { continue }
        if ($needle -ne '' -and -not (Test-StudioSnapshotContent -Entry $entry -Needle $needle)) { continue }
        $filtered.Add($entry)
    }

    $script:Ui.SnapFlow.SuspendLayout()
    try {
        foreach ($control in @($script:Ui.SnapFlow.Controls)) { $control.Dispose() }
        $script:Ui.SnapFlow.Controls.Clear()
        $script:SnapshotRows = @()
        $script:SnapshotBuildQueue = @($filtered.ToArray())
        $script:SnapshotBuildIndex = 0
        $script:SnapshotBuildWidth = [Math]::Max(300, $script:Ui.SnapFlow.ClientSize.Width - 22)
        $script:SnapshotClickHandler = {
            param($sender, $eventArgs)
            Select-StudioSnapshotRow -Path ([string]$sender.Tag)
        }
        if ($filtered.Count -eq 0) {
            $script:Ui.SnapEmpty.Visible = $true
            $script:Ui.SnapEmpty.Top = 70
        } else {
            $script:Ui.SnapEmpty.Visible = $false
        }
        $script:Ui.SnapCount.Text = if ($filtered.Count -eq 1) { T 'SnapCountOne' '1 snapshot' } else { (T 'SnapCount' '{0} snapshots') -f $filtered.Count }
        $selected = Get-StudioSelectedSnapshotEntry
        if ($null -eq $selected -and $filtered.Count -gt 0) {
            $script:SelectedSnapshotPath = $filtered[0].Path
        }
    } finally {
        $script:Ui.SnapFlow.ResumeLayout($false)
    }
    $script:SnapshotsDirty = $false
    if ($filtered.Count -gt 0) {
        if ($null -eq $script:SnapshotBuildTimer) {
            $script:SnapshotBuildTimer = New-Object System.Windows.Forms.Timer
            $script:SnapshotBuildTimer.Interval = 15
            $script:SnapshotBuildTimer.Add_Tick({ Add-StudioSnapshotBatch -BatchSize 8 })
        }
        $script:SnapshotBuildTimer.Stop()
        $script:SnapshotBuildTimer.Start()
    }
}

# ---------------------------------------------------------------------------
# Exclusions
# ---------------------------------------------------------------------------

function Refresh-StudioExclusions {
    foreach ($card in $script:ExclusionCards) {
        if ($null -eq $card -or $null -eq $card.Tag) { continue }
        $context = $card.Tag
        $property = [string]$context.Property
        $propertyInfo = $script:Config.PSObject.Properties[$property]
        $items = if ($null -ne $propertyInfo) { @($propertyInfo.Value) } else { @() }
        $list = $context.List
        $list.BeginUpdate()
        try {
            $list.Items.Clear()
            foreach ($item in $items) {
                if (-not [string]::IsNullOrWhiteSpace([string]$item)) { [void]$list.Items.Add([string]$item) }
            }
        } finally {
            $list.EndUpdate()
        }
    }
    $script:ExclusionsDirty = $false
}

function Add-StudioExclusionValue {
    param($Context)
    $property = [string]$Context.Property
    $input = $Context.Input
    if ($input.Tag -eq 'placeholder') { return }
    $value = $input.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($value)) { return }
    $propertyInfo = $script:Config.PSObject.Properties[$property]
    $current = if ($null -ne $propertyInfo) { @($propertyInfo.Value) } else { @() }
    if ($current -notcontains $value) { $current += $value }
    if ($null -ne $propertyInfo) {
        $propertyInfo.Value = @($current)
    } else {
        $script:Config | Add-Member -NotePropertyName $property -NotePropertyValue @($current)
    }
    Save-SRConfig -Config $script:Config
    $input.Text = ''

    $input.ForeColor = $script:P.Text
    $input.Tag = ''
    Refresh-StudioExclusions
    Show-StudioToast (T 'ToastExclusionAdded' 'Exclusion added.') $script:P.Green
}

function Remove-StudioExclusionValue {
    param($Context)
    $property = [string]$Context.Property
    $list = $Context.List
    if ($list.SelectedIndex -lt 0) { return }
    $value = [string]$list.SelectedItem
    $propertyInfo = $script:Config.PSObject.Properties[$property]
    $current = if ($null -ne $propertyInfo) { @($propertyInfo.Value) } else { @() }
    $current = @($current | Where-Object { [string]$_ -ne $value })
    if ($null -ne $propertyInfo) {
        $propertyInfo.Value = @($current)
    }
    Save-SRConfig -Config $script:Config
    Refresh-StudioExclusions
    Show-StudioToast (T 'ToastExclusionRemoved' 'Exclusion removed.') $script:P.Green
}

function New-StudioExclusionCard {
    param(
        [string]$Title,
        [string]$Description,
        [string]$PropertyName,
        [string]$Placeholder,
        [bool]$BrowseFolder = $false
    )
    $card = New-StudioCard -X 0 -Y 0 -Width 800 -Height 230 -Fill $script:P.Card -Border $script:P.BorderSoft -Radius 14
    $card.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 14)
    $titleLabel = New-StudioLabel -Text $Title -X 20 -Y 15 -Width 300 -Height 24 -Font $script:FontSemiboldLarge -Color $script:P.Text
    $card.Controls.Add($titleLabel)
    $descriptionLabel = New-StudioLabel -Text $Description -X 20 -Y 38 -Width ($card.Width - 40) -Height 18 -Font $script:FontBodySmall -Color $script:P.Muted
    $descriptionLabel.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $card.Controls.Add($descriptionLabel)

    $list = New-Object System.Windows.Forms.ListBox
    $list.Location = New-Object System.Drawing.Point(20, 63)
    $list.Size = New-Object System.Drawing.Size(($card.Width - 40), 82)
    $list.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $list.BackColor = $script:P.CardAlt
    $list.ForeColor = $script:P.Text
    $list.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $list.Font = $script:FontBody
    $list.IntegralHeight = $false
    $card.Controls.Add($list)

    $input = New-StudioTextBox -X 20 -Y 156 -Width 440 -Height 28
    $input.Text = $Placeholder
    $input.ForeColor = $script:P.Subtle
    $input.Tag = 'placeholder'
    # Left-anchored only: a right-anchored input stretched with the card on
    # resize and ran underneath the Add/Remove buttons.
    $input.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left
    $input.Add_GotFocus({
        param($sender, $eventArgs)
        if ($sender.Tag -eq 'placeholder') {
            $sender.Text = ''
            $sender.ForeColor = $script:P.Text
            $sender.Tag = ''
        }
    })
    $input.Add_LostFocus({
        param($sender, $eventArgs)
        if ([string]::IsNullOrWhiteSpace($sender.Text)) {
            $sender.Text = $script:ExclusionPlaceholders[$sender.AccessibleName]
            $sender.ForeColor = $script:P.Subtle
            $sender.Tag = 'placeholder'
        }
    })
    $input.AccessibleName = $PropertyName
    $card.Controls.Add($input)

    $add = New-StudioButton -Text 'Add' -X ($card.Width - 246) -Y 154 -Width 84 -Height 32 -Primary -Glyph ''
    $add.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
    $remove = New-StudioButton -Text 'Remove selected' -X ($card.Width - 154) -Y 154 -Width 132 -Height 32 -Danger
    $remove.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
    $card.Controls.Add($add)
    $card.Controls.Add($remove)

    $context = @{
        Property = $PropertyName
        List     = $list
        Input    = $input
        HasBrowse = [bool]$BrowseFolder
    }
    $add.Tag = $context
    $remove.Tag = $context
    $add.Add_Click({
        param($sender, $eventArgs)
        Add-StudioExclusionValue -Context $sender.Tag
    })
    $remove.Add_Click({
        param($sender, $eventArgs)
        Remove-StudioExclusionValue -Context $sender.Tag
    })

    if ($BrowseFolder) {
        $browse = New-StudioButton -Text 'Browse...' -X ($card.Width - 368) -Y 154 -Width 104 -Height 32 -Glyph ''
        $browse.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
        $browse.Tag = $context
        $browse.Add_Click({
            param($sender, $eventArgs)
            $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
            $dialog.Description = 'Choose a folder to exclude from snapshots.'
            $dialog.ShowNewFolderButton = $false
            try {
                if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                    $sender.Tag.Input.Text = $dialog.SelectedPath
                    $sender.Tag.Input.ForeColor = $script:P.Text
                    $sender.Tag.Input.Tag = ''
                }
            } finally {
                $dialog.Dispose()
            }
        })
        $card.Controls.Add($browse)
        $input.Width = $card.Width - 398
    } else {
        $input.Width = $card.Width - 260
    }

    $card.Tag = $context
    $script:ExclusionCards += $card
    return $card
}

function Render-StudioPrivacyFindings {
    if (-not $script:Ui.PrivacyList) { return }
    $list = $script:Ui.PrivacyList
    $list.BeginUpdate()
    try {
        $list.Items.Clear()
        $script:PrivacyMap = @{}
        if (@($script:PrivacyFindings).Count -eq 0) {
            [void]$list.Items.Add((T 'PrivacyScanEmpty' 'No sensitive apps or sites are currently captured.'))
            if ($script:Ui.PrivacyExcludeSelected) { $script:Ui.PrivacyExcludeSelected.Enabled = $false }
            if ($script:Ui.PrivacyExcludeAll) { $script:Ui.PrivacyExcludeAll.Enabled = $false }
            if ($script:Ui.PrivacyStatus) {
                $script:Ui.PrivacyStatus.Text = if ($script:PrivacyScanLoading) { (T 'BtnScanning' 'Scanning...') } else { (T 'PrivacyScanEmpty' 'No sensitive apps or sites are currently captured.') }
                $script:Ui.PrivacyStatus.ForeColor = $script:P.Muted
            }
        } else {
            $suffix = 0
            foreach ($finding in @($script:PrivacyFindings)) {
                if ($null -eq $finding) { continue }
                $kind = if ([string]$finding.Kind -eq 'app') { (T 'PrivacyKindApp' 'App') } else { (T 'PrivacyKindSite' 'Site') }
                $reason = T ([string]$finding.ReasonKey) ([string]$finding.Reason)
                $display = '{0}  •  {1}  •  {2}' -f $kind, $reason, [string]$finding.Label
                if ([int]$finding.MatchCount -gt 1) { $display += ('  ({0})' -f [int]$finding.MatchCount) }
                if ($script:PrivacyMap.ContainsKey($display)) { $suffix++; $display += ('  #{0}' -f $suffix) }
                $script:PrivacyMap[$display] = $finding
                [void]$list.Items.Add($display)
            }
            if ($script:Ui.PrivacyExcludeSelected) { $script:Ui.PrivacyExcludeSelected.Enabled = $true }
            if ($script:Ui.PrivacyExcludeAll) { $script:Ui.PrivacyExcludeAll.Enabled = $true }
            if ($script:Ui.PrivacyStatus) {
                $script:Ui.PrivacyStatus.Text = ((T 'PrivacyScanFound' '{0} suggestion(s) found.') -f @($script:PrivacyFindings).Count)
                $script:Ui.PrivacyStatus.ForeColor = $script:P.Amber
            }
        }
    } finally {
        $list.EndUpdate()
    }
}

function Add-StudioPrivacyExclusions {
    param([object[]]$Findings = @())
    $selected = @($Findings | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_.Pattern) })
    if ($selected.Count -eq 0) { return }
    $config = Get-SRConfig
    $apps = @($config.excludeApps | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    $urls = @($config.excludeUrls | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    $added = 0
    $applied = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($finding in $selected) {
        $pattern = [string]$finding.Pattern
        if ($pattern.Length -gt 512 -or [regex]::IsMatch($pattern, '[\x00-\x1F]')) { continue }
        if ([string]$finding.Kind -eq 'app') {
            if ($apps -notcontains $pattern) { $apps += $pattern; $added++ }
        } else {
            if ($urls -notcontains $pattern) { $urls += $pattern; $added++ }
        }
        [void]$applied.Add($pattern)
    }
    if ($added -eq 0) {
        Show-StudioToast (T 'ToastPrivacyNone' 'Those exclusions are already in place.') $script:P.Muted
        return
    }
    $config.excludeApps = @($apps)
    $config.excludeUrls = @($urls)
    Save-SRConfig -Config $config
    $script:Config = Get-SRConfig
    $script:PrivacyFindings = @($script:PrivacyFindings | Where-Object { -not $applied.Contains([string]$_.Pattern) })
    Refresh-StudioExclusions
    Render-StudioPrivacyFindings
    Show-StudioToast ((T 'ToastPrivacyAdded' 'Added {0} exclusion(s).') -f $added) $script:P.Green
}

function Start-StudioPrivacyScan {
    if ($script:PrivacyScanLoading) { return }
    $script:PrivacyScanLoading = $true
    $script:PrivacyFindings = @()
    $script:PrivacyMap = @{}
    if ($script:Ui.PrivacyScan) { $script:Ui.PrivacyScan.Enabled = $false }
    if ($script:Ui.PrivacyExcludeSelected) { $script:Ui.PrivacyExcludeSelected.Enabled = $false }
    if ($script:Ui.PrivacyExcludeAll) { $script:Ui.PrivacyExcludeAll.Enabled = $false }
    if ($script:Ui.PrivacyStatus) {
        $script:Ui.PrivacyStatus.Text = (T 'BtnScanning' 'Scanning...')
        $script:Ui.PrivacyStatus.ForeColor = $script:P.Accent
    }
    if ($script:Ui.PrivacyList) {
        $script:Ui.PrivacyList.Items.Clear()
        [void]$script:Ui.PrivacyList.Items.Add((T 'BtnScanning' 'Scanning...'))
    }
    try {
        Start-StudioWorker -Name 'PrivacyScan' -SharedRunspace -Script {
            param($modulePath)
            $ErrorActionPreference = 'Stop'
            if (-not (Get-Module -Name SessionRecovery -ErrorAction SilentlyContinue)) {
                Import-Module $modulePath -Force -ErrorAction Stop | Out-Null
            }
            Get-SRPrivacyFindings | ConvertTo-Json -Depth 8 -Compress
        } -Arguments @($modulePath)
    } catch {
        $script:PrivacyScanLoading = $false
        if ($script:Ui.PrivacyScan) { $script:Ui.PrivacyScan.Enabled = $true }
        if ($script:Ui.PrivacyStatus) {
            $script:Ui.PrivacyStatus.Text = ((T 'ToastPrivacyFailed' 'Privacy scan failed: {0}') -f $_.Exception.Message)
            $script:Ui.PrivacyStatus.ForeColor = $script:P.Red
        }
        Render-StudioPrivacyFindings
    }
}

function Complete-StudioPrivacyScanWorker {
    param($Result)
    $script:PrivacyScanLoading = $false
    if ($script:Ui.PrivacyScan) { $script:Ui.PrivacyScan.Enabled = $true }
    if (-not [string]::IsNullOrWhiteSpace([string]$Result.Error)) {
        if ($script:Ui.PrivacyStatus) {
            $script:Ui.PrivacyStatus.Text = ((T 'ToastPrivacyFailed' 'Privacy scan failed: {0}') -f [string]$Result.Error)
            $script:Ui.PrivacyStatus.ForeColor = $script:P.Red
        }
        $script:PrivacyFindings = @()
        Render-StudioPrivacyFindings
        return
    }
    try {
        $json = [string](@($Result.Output) | Select-Object -Last 1)
        if ([string]::IsNullOrWhiteSpace($json)) { throw 'The privacy scan returned no data.' }
        $report = $json | ConvertFrom-Json
        $script:PrivacyFindings = @($report.Findings)
        Render-StudioPrivacyFindings
        if (@($script:PrivacyFindings).Count -eq 0) {
            Show-StudioToast (T 'ToastPrivacyNone' 'No sensitive windows or tabs were found.') $script:P.Green
        }
    } catch {
        $script:PrivacyFindings = @()
        Render-StudioPrivacyFindings
        if ($script:Ui.PrivacyStatus) {
            $script:Ui.PrivacyStatus.Text = ((T 'ToastPrivacyFailed' 'Privacy scan failed: {0}') -f $_.Exception.Message)
            $script:Ui.PrivacyStatus.ForeColor = $script:P.Red
        }
    }
}

$script:ExclusionPlaceholders = @{
    excludeApps    = (T 'ExclAppPlaceholder' 'e.g. steam.exe or *game*')
    excludeFolders = (T 'ExclFolderPlaceholder' 'e.g. C:\Projects\Private')
    excludeUrls    = (T 'ExclUrlPlaceholder' 'e.g. *bank* or https://mail.example.com/*')
}

$exclusionsPage = New-StudioPage -Name 'Exclusions'
$exFlow = New-Object System.Windows.Forms.FlowLayoutPanel
$exFlow.Dock = [System.Windows.Forms.DockStyle]::Fill
$exFlow.Padding = New-Object System.Windows.Forms.Padding(24)
$exFlow.AutoScroll = $true
$exFlow.FlowDirection = [System.Windows.Forms.FlowDirection]::TopDown
$exFlow.WrapContents = $false
$exFlow.BackColor = $script:P.Bg
$exclusionsPage.Controls.Add($exFlow)
$script:Ui.ExclusionFlow = $exFlow

$exIntro = New-StudioLabel -Text (T 'ExclIntro' 'Exclusions keep private or noisy windows out of every new snapshot. Changes apply immediately.') -X 0 -Y 0 -Width 800 -Height 22 -Font $script:FontBody -Color $script:P.Muted
$exIntro.AutoEllipsis = $true
$exIntro.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 12)
$exFlow.Controls.Add($exIntro)

# ---------------------------------------------------------------------------
# Privacy scan (lives on Exclusions so suggestions are one click from the
# rules they modify)
# ---------------------------------------------------------------------------

$script:PrivacyCard = New-StudioCard -X 0 -Y 0 -Width 800 -Height 288 -Fill $script:P.Card -Border $script:P.BorderSoft -Radius 14
$script:PrivacyCard.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 14)
$privacyTitle = New-StudioLabel -Text (T 'PrivacyScanTitle' 'Privacy scan') -X 20 -Y 15 -Width 360 -Height 24 -Font $script:FontSemiboldLarge -Color $script:P.Text
$script:PrivacyCard.Controls.Add($privacyTitle)
$privacyDesc = New-StudioLabel -Text (T 'PrivacyScanDesc' 'Checks app names and browser tab URLs for sensitive categories, then suggests exclusions. Screenshots and page content are never inspected.') -X 20 -Y 40 -Width 760 -Height 34 -Font $script:FontBodySmall -Color $script:P.Muted
$privacyDesc.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$script:PrivacyCard.Controls.Add($privacyDesc)

$privacyScan = New-StudioButton -Text (T 'BtnPrivacyScan' 'Scan now') -X 0 -Y 10 -Width 128 -Height 28 -Glyph ([string][char]0xE721)
$privacyScan.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$privacyScan.Add_Click({ Start-StudioPrivacyScan })
$script:PrivacyCard.Controls.Add($privacyScan)
$script:Ui.PrivacyScan = $privacyScan

$privacyList = New-Object System.Windows.Forms.ListBox
$privacyList.Location = New-Object System.Drawing.Point(20, 80)
$privacyList.Size = New-Object System.Drawing.Size(760, 110)
$privacyList.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$privacyList.BackColor = $script:P.CardAlt
$privacyList.ForeColor = $script:P.Text
$privacyList.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$privacyList.Font = $script:FontBody
$privacyList.IntegralHeight = $false
$privacyList.SelectionMode = [System.Windows.Forms.SelectionMode]::One
$script:PrivacyCard.Controls.Add($privacyList)
$script:Ui.PrivacyList = $privacyList

$privacyStatus = New-StudioLabel -Text (T 'PrivacyScanIdle' 'Run a scan to look for sensitive apps and sites in current windows and tabs.') -X 20 -Y 198 -Width 760 -Height 34 -Font $script:FontBodySmall -Color $script:P.Muted
$privacyStatus.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$script:PrivacyCard.Controls.Add($privacyStatus)
$script:Ui.PrivacyStatus = $privacyStatus

$privacyExcludeSelected = New-StudioButton -Text (T 'BtnExcludeSelected' 'Exclude selected') -X 0 -Y 244 -Width 196 -Height 32 -Glyph ''
$privacyExcludeSelected.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
$privacyExcludeSelected.Enabled = $false
$privacyExcludeSelected.Add_Click({
    $finding = $null
    if ($script:Ui.PrivacyList -and $script:Ui.PrivacyList.SelectedIndex -ge 0) {
        $finding = $script:PrivacyMap[[string]$script:Ui.PrivacyList.SelectedItem]
    }
    if ($null -ne $finding) { Add-StudioPrivacyExclusions -Findings @($finding) }
})
$script:PrivacyCard.Controls.Add($privacyExcludeSelected)
$script:Ui.PrivacyExcludeSelected = $privacyExcludeSelected

$privacyExcludeAll = New-StudioButton -Text (T 'BtnExcludeAll' 'Exclude all') -X 0 -Y 244 -Width 156 -Height 32 -Glyph ''
$privacyExcludeAll.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
$privacyExcludeAll.Enabled = $false
$privacyExcludeAll.Add_Click({
    Add-StudioPrivacyExclusions -Findings @($script:PrivacyFindings)
})
$script:PrivacyCard.Controls.Add($privacyExcludeAll)
$script:Ui.PrivacyExcludeAll = $privacyExcludeAll

$script:PrivacyCard.Add_Resize({
    $script:Ui.PrivacyScan.Left = $script:PrivacyCard.ClientSize.Width - 20 - $script:Ui.PrivacyScan.Width
    $right = $script:PrivacyCard.ClientSize.Width - 20
    $script:Ui.PrivacyExcludeSelected.Left = $right - $script:Ui.PrivacyExcludeSelected.Width
    $right = $script:Ui.PrivacyExcludeSelected.Left - 10
    $script:Ui.PrivacyExcludeAll.Left = $right - $script:Ui.PrivacyExcludeAll.Width
    $script:Ui.PrivacyStatus.Width = [Math]::Max(200, $script:PrivacyCard.ClientSize.Width - 40)
    $script:Ui.PrivacyList.Width = [Math]::Max(220, $script:PrivacyCard.ClientSize.Width - 40)
    $script:Ui.PrivacyList.Height = [Math]::Max(96, $script:PrivacyCard.ClientSize.Height - 178)
})
$exFlow.Controls.Add($script:PrivacyCard)

$appCard = New-StudioExclusionCard -Title (T 'ExclApps' 'Applications') -Description (T 'ExclAppsDesc' 'Skip processes by name. Wildcards * and ? are supported.') -PropertyName 'excludeApps' -Placeholder $script:ExclusionPlaceholders['excludeApps']
$exFlow.Controls.Add($appCard)
$folderCard = New-StudioExclusionCard -Title (T 'ExclFolders' 'Folders') -Description (T 'ExclFoldersDesc' 'Skip Explorer windows pointing at these folders or their children.') -PropertyName 'excludeFolders' -Placeholder $script:ExclusionPlaceholders['excludeFolders'] -BrowseFolder $true
$exFlow.Controls.Add($folderCard)
$urlCard = New-StudioExclusionCard -Title (T 'ExclUrls' 'URLs') -Description (T 'ExclUrlsDesc' 'Skip matching browser tabs. Use a wildcard for broad patterns.') -PropertyName 'excludeUrls' -Placeholder $script:ExclusionPlaceholders['excludeUrls']
$exFlow.Controls.Add($urlCard)

$exFooter = New-StudioLabel -Text (T 'ExclFooterNote' 'Exclusion rules are stored only in config.json on this PC.') -X 0 -Y 0 -Width 800 -Height 18 -Font $script:FontBodySmall -Color $script:P.Subtle
$exFooter.AutoEllipsis = $true
$exFooter.Margin = New-Object System.Windows.Forms.Padding(0, 2, 0, 0)
$exFlow.Controls.Add($exFooter)

function Layout-StudioExclusions {
    if (-not $script:Ui.ExclusionFlow) { return }
    $width = [Math]::Max(620, $script:Ui.ExclusionFlow.ClientSize.Width - 52)
    foreach ($card in $script:ExclusionCards) {
        $card.Width = $width
        # The input is left-anchored, so resize it here to stop short of the
        # right-anchored action buttons.
        $context = $card.Tag
        if ($null -ne $context -and $null -ne $context.Input) {
            # Left margin (20) + button zone (264, or 386 with Browse) + gap.
            $clearance = $(if ($context.HasBrowse) { 398 } else { 276 })
            $context.Input.Width = [Math]::Max(300, $width - $clearance)
        }
    }
    if ($null -ne $script:PrivacyCard) { $script:PrivacyCard.Width = $width }
    $exIntro.Width = $width
    $exFooter.Width = $width
}

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------

function New-StudioSettingsCard {
    param([string]$Title, [string]$Description, [int]$Height = 180, [switch]$WrapDescription)
    $card = New-StudioCard -X 0 -Y 0 -Width 800 -Height $Height -Fill $script:P.Card -Border $script:P.BorderSoft -Radius 14
    $card.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 14)
    $titleLabel = New-StudioLabel -Text $Title -X 20 -Y 15 -Width 360 -Height 24 -Font $script:FontSemiboldLarge -Color $script:P.Text
    $card.Controls.Add($titleLabel)
    $descriptionHeight = if ($WrapDescription) { 32 } else { 18 }
    $descriptionLabel = New-StudioLabel -Text $Description -X 20 -Y 38 -Width ($card.Width - 40) -Height $descriptionHeight -Font $script:FontBodySmall -Color $script:P.Muted
    $descriptionLabel.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $card.Controls.Add($descriptionLabel)
    return $card
}

function New-StudioNumeric {
    param([int]$X, [int]$Y, [int]$Value, [int]$Min, [int]$Max, [int]$Width = 84)
    $numeric = New-Object System.Windows.Forms.NumericUpDown
    $numeric.Location = New-Object System.Drawing.Point($X, $Y)
    $numeric.Size = New-Object System.Drawing.Size($Width, 28)
    $numeric.Minimum = $Min
    $numeric.Maximum = $Max
    $numeric.Value = [Math]::Max($Min, [Math]::Min($Max, $Value))
    $numeric.BackColor = $script:P.CardAlt
    $numeric.ForeColor = $script:P.Text
    $numeric.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $numeric.Font = $script:FontBody
    return $numeric
}

$settingsPage = New-StudioPage -Name 'Settings'
$settingsFlow = New-Object System.Windows.Forms.Panel
$settingsFlow.Location = New-Object System.Drawing.Point(0, 0)
$settingsFlow.Size = New-Object System.Drawing.Size(984, 622)
$settingsFlow.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$settingsFlow.Padding = New-Object System.Windows.Forms.Padding(24)
$settingsFlow.AutoScroll = $true
$settingsFlow.BackColor = $script:P.Bg
$settingsPage.Controls.Add($settingsFlow)
$script:Ui.SettingsFlow = $settingsFlow

$settingsBar = New-Object System.Windows.Forms.Panel
$settingsBar.Location = New-Object System.Drawing.Point(0, 622)
$settingsBar.Size = New-Object System.Drawing.Size(984, 70)
$settingsBar.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$settingsBar.BackColor = $script:P.Sidebar
$settingsPage.Controls.Add($settingsBar)
$settingsBarLine = New-Object System.Windows.Forms.Panel
$settingsBarLine.Dock = [System.Windows.Forms.DockStyle]::Top
$settingsBarLine.Height = 1
$settingsBarLine.BackColor = $script:P.BorderSoft
$settingsBar.Controls.Add($settingsBarLine)

$settingsStatus = New-StudioLabel -Text '' -X 24 -Y 24 -Width 460 -Height 20 -Font $script:FontBodySmall -Color $script:P.Muted
$settingsBar.Controls.Add($settingsStatus)
$script:Ui.StatusLabel = $settingsStatus

$settingsReset = New-StudioButton -Text 'Reset defaults' -X 650 -Y 16 -Width 138 -Height 38 -Glyph ''
$settingsReset.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$settingsReset.Add_Click({ Reset-StudioSettings })
$settingsBar.Controls.Add($settingsReset)
$script:Ui.SettingsReset = $settingsReset

$settingsSave = New-StudioButton -Text 'Save changes' -X 792 -Y 16 -Width 160 -Height 38 -Primary -Glyph ''
$settingsSave.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$settingsSave.Add_Click({ Save-StudioSettings })
$settingsBar.Controls.Add($settingsSave)
$script:Ui.SettingsSave = $settingsSave

$settingsCards = New-Object System.Collections.Generic.List[object]

# Card: snapshot rhythm
$rhythmCard = New-StudioSettingsCard -Title 'Snapshot rhythm' -Description 'How often your session is saved, and how much history stays on disk.' -Height 164
$settingsFlow.Controls.Add($rhythmCard)
$settingsCards.Add($rhythmCard)

$rhythmLabel1 = New-StudioLabel -Text 'SNAPSHOT EVERY' -X 20 -Y 70 -Width 160 -Height 16 -Font $script:FontMono -Color $script:P.Subtle
$rhythmCard.Controls.Add($rhythmLabel1)
$numInterval = New-StudioNumeric -X 20 -Y 90 -Value 3 -Min 1 -Max 240 -Width 84
$rhythmCard.Controls.Add($numInterval)
$rhythmUnit1 = New-StudioLabel -Text 'minutes' -X 110 -Y 94 -Width 80 -Height 20 -Font $script:FontBodySmall -Color $script:P.Muted
$rhythmCard.Controls.Add($rhythmUnit1)

$rhythmLabel2 = New-StudioLabel -Text 'KEEP' -X 270 -Y 70 -Width 160 -Height 16 -Font $script:FontMono -Color $script:P.Subtle
$rhythmCard.Controls.Add($rhythmLabel2)
$numKeep = New-StudioNumeric -X 270 -Y 90 -Value 48 -Min 1 -Max 1000 -Width 84
$rhythmCard.Controls.Add($numKeep)
$rhythmUnit2 = New-StudioLabel -Text 'snapshots' -X 360 -Y 94 -Width 150 -Height 20 -Font $script:FontBodySmall -Color $script:P.Muted
$rhythmCard.Controls.Add($rhythmUnit2)

$rhythmLabel3 = New-StudioLabel -Text 'DELETE OLDER THAN' -X 520 -Y 70 -Width 180 -Height 16 -Font $script:FontMono -Color $script:P.Subtle
$rhythmCard.Controls.Add($rhythmLabel3)
$numDays = New-StudioNumeric -X 520 -Y 90 -Value 0 -Min 0 -Max 3650 -Width 84
$rhythmCard.Controls.Add($numDays)
$rhythmUnit3 = New-StudioLabel -Text 'days' -X 610 -Y 94 -Width 80 -Height 20 -Font $script:FontBodySmall -Color $script:P.Muted
$rhythmCard.Controls.Add($rhythmUnit3)
$rhythmHint = New-StudioLabel -Text ((T 'SetRhythmHint' '{0} days keeps history by count only. Snapshot files are tiny JSON documents.') -f 0) -X 20 -Y 126 -Width 700 -Height 18 -Font $script:FontBodySmall -Color $script:P.Subtle
$rhythmCard.Controls.Add($rhythmHint)
$numDays.Add_ValueChanged({
    if (-not $script:SettingsLoaded) { return }
    $rhythmHint.Text = (T 'SetRhythmHint' '{0} days keeps history by count only. Snapshot files are tiny JSON documents.') -f [int]$numDays.Value
})

# Card: restore behavior
$restoreCard = New-StudioSettingsCard -Title 'Restore behavior' -Description 'Choose how Session Recovery offers to reopen apps, folders and tabs.' -Height 206
$settingsFlow.Controls.Add($restoreCard)
$settingsCards.Add($restoreCard)

$promptLabel = New-StudioLabel -Text 'WHEN WINDOWS STARTS' -X 20 -Y 70 -Width 220 -Height 16 -Font $script:FontMono -Color $script:P.Subtle
$restoreCard.Controls.Add($promptLabel)
$comboPrompt = New-StudioCombo -X 20 -Y 90 -Width 210
Set-StudioLocalizedCombo -Combo $comboPrompt -Keys @('PromptAlways', 'PromptCrashOnly', 'PromptNever') -Defaults @('Always ask', 'Only after a crash', 'Never ask')
$comboPrompt.SelectedIndex = 1
$restoreCard.Controls.Add($comboPrompt)

$maxAgeLabel = New-StudioLabel -Text 'MAX RESTORE AGE' -X 290 -Y 70 -Width 180 -Height 16 -Font $script:FontMono -Color $script:P.Subtle
$restoreCard.Controls.Add($maxAgeLabel)
$numMaxAge = New-StudioNumeric -X 290 -Y 90 -Value 72 -Min 1 -Max 8760 -Width 90
$restoreCard.Controls.Add($numMaxAge)
$maxAgeUnit = New-StudioLabel -Text 'hours' -X 388 -Y 94 -Width 80 -Height 20 -Font $script:FontBodySmall -Color $script:P.Muted
$restoreCard.Controls.Add($maxAgeUnit)

$toggleRestoreBrowsers = New-StudioToggle -X 20 -Y 146 -Checked $true
$restoreCard.Controls.Add($toggleRestoreBrowsers)
$restoreBrowserLabel = New-StudioLabel -Text 'Reopen captured browser tabs' -X 76 -Y 150 -Width 320 -Height 20 -Font $script:FontBody -Color $script:P.Text
$restoreCard.Controls.Add($restoreBrowserLabel)

$tabModeLabel = New-StudioLabel -Text 'TAB RESTORE MODE' -X 430 -Y 132 -Width 260 -Height 16 -Font $script:FontMono -Color $script:P.Subtle
$restoreCard.Controls.Add($tabModeLabel)
$comboTabMode = New-StudioCombo -X 440 -Y 152 -Width 180
Set-StudioLocalizedCombo -Combo $comboTabMode -Keys @('TabModeSmart', 'TabModeCaptured', 'TabModeNative', 'TabModeNone') -Defaults @('Smart', 'Captured', 'Native', 'None')
$comboTabMode.SelectedIndex = 0
$restoreCard.Controls.Add($comboTabMode)

# Card: browser capture
$browserCard = New-StudioSettingsCard -Title 'Browser capture' -Description 'Chrome, Edge, Brave and other Chromium browsers use a safe live fallback when their session files are empty.' -Height 264 -WrapDescription
$settingsFlow.Controls.Add($browserCard)
$settingsCards.Add($browserCard)

$toggleCaptureBrowsers = New-StudioToggle -X 20 -Y 76 -Checked $true
$browserCard.Controls.Add($toggleCaptureBrowsers)
$captureBrowserLabel = New-StudioLabel -Text 'Capture browser tabs' -X 76 -Y 80 -Width 300 -Height 20 -Font $script:FontBody -Color $script:P.Text
$browserCard.Controls.Add($captureBrowserLabel)

$toggleApprox = New-StudioToggle -X 20 -Y 116 -Checked $true
$browserCard.Controls.Add($toggleApprox)
$approxLabel = New-StudioLabel -Text 'Use recent history when session files are empty' -X 76 -Y 120 -Width 420 -Height 20 -Font $script:FontBody -Color $script:P.Text
$browserCard.Controls.Add($approxLabel)
$approxHint = New-StudioLabel -Text 'This can include a few recently visited pages that are already closed. Tabs are marked approximate.' -X 76 -Y 140 -Width 440 -Height 32 -Font $script:FontBodySmall -Color $script:P.Subtle
$browserCard.Controls.Add($approxHint)

$toggleRedact = New-StudioToggle -X 20 -Y 198 -Checked $true
$browserCard.Controls.Add($toggleRedact)
$redactLabel = New-StudioLabel -Text 'Strip query strings from captured URLs' -X 76 -Y 202 -Width 420 -Height 20 -Font $script:FontBody -Color $script:P.Text
$browserCard.Controls.Add($redactLabel)
$redactHint = New-StudioLabel -Text 'Tokens and search terms in ?query strings never reach the snapshot files.' -X 76 -Y 222 -Width 440 -Height 18 -Font $script:FontBodySmall -Color $script:P.Subtle
$browserCard.Controls.Add($redactHint)

$lookbackLabel = New-StudioLabel -Text 'HISTORY LOOKBACK' -X 560 -Y 76 -Width 180 -Height 16 -Font $script:FontMono -Color $script:P.Subtle
$browserCard.Controls.Add($lookbackLabel)
$numLookback = New-StudioNumeric -X 560 -Y 96 -Value 24 -Min 1 -Max 168 -Width 90
$browserCard.Controls.Add($numLookback)
$lookbackUnit = New-StudioLabel -Text 'hours' -X 658 -Y 100 -Width 80 -Height 20 -Font $script:FontBodySmall -Color $script:P.Muted
$browserCard.Controls.Add($lookbackUnit)
$lookbackHint = New-StudioLabel -Text 'Only used when the exact session file cannot be read.' -X 560 -Y 128 -Width 260 -Height 32 -Font $script:FontBodySmall -Color $script:P.Subtle
$browserCard.Controls.Add($lookbackHint)

# Card: media playback
$mediaCard = New-StudioSettingsCard -Title 'Media playback' -Description 'Remember what a media player was playing, and where.' -Height 164
$settingsFlow.Controls.Add($mediaCard)
$settingsCards.Add($mediaCard)

$toggleMedia = New-StudioToggle -X 20 -Y 76 -Checked $true
$mediaCard.Controls.Add($toggleMedia)
$mediaLabel = New-StudioLabel -Text 'Capture the playing video and its position' -X 76 -Y 80 -Width 380 -Height 20 -Font $script:FontBody -Color $script:P.Text
$mediaCard.Controls.Add($mediaLabel)
$mediaHint = New-StudioLabel -Text 'VLC, MPC-HC, MPC-BE, mpv, PotPlayer and Windows Media Player are supported: restore reopens the same file, near the moment it was playing when it can. Positions between snapshots are estimated, so restore lands at most one interval early.' -X 76 -Y 100 -Width 580 -Height 48 -Font $script:FontBodySmall -Color $script:P.Subtle
$mediaCard.Controls.Add($mediaHint)

# Card: background and desktop
$backgroundCard = New-StudioSettingsCard -Title 'Background & desktop' -Description 'Keep Session Recovery close without leaving windows open.' -Height 250
$settingsFlow.Controls.Add($backgroundCard)
$settingsCards.Add($backgroundCard)

$toggleStartup = New-StudioToggle -X 20 -Y 76 -Checked $true
$backgroundCard.Controls.Add($toggleStartup)
$startupLabel = New-StudioLabel -Text 'Start the background app with Windows' -X 76 -Y 80 -Width 360 -Height 20 -Font $script:FontBody -Color $script:P.Text
$backgroundCard.Controls.Add($startupLabel)
$startupHint = New-StudioLabel -Text 'Creates a shortcut in your Startup folder. No scheduled task or admin rights required.' -X 76 -Y 100 -Width 360 -Height 18 -Font $script:FontBodySmall -Color $script:P.Subtle
$backgroundCard.Controls.Add($startupHint)

$toggleDesktop = New-StudioToggle -X 20 -Y 132 -Checked $true
$backgroundCard.Controls.Add($toggleDesktop)
$desktopLabel = New-StudioLabel -Text 'Show a Session Recovery icon on the desktop' -X 76 -Y 136 -Width 360 -Height 20 -Font $script:FontBody -Color $script:P.Text
$backgroundCard.Controls.Add($desktopLabel)

$toggleNotifications = New-StudioToggle -X 20 -Y 188 -Checked $true
$backgroundCard.Controls.Add($toggleNotifications)
$notificationsLabel = New-StudioLabel -Text 'Show tray notifications' -X 76 -Y 192 -Width 300 -Height 20 -Font $script:FontBody -Color $script:P.Text
$backgroundCard.Controls.Add($notificationsLabel)
$notificationsHint = New-StudioLabel -Text 'Automatic snapshots stay silent. Manual tray actions and errors can still notify.' -X 76 -Y 212 -Width 420 -Height 18 -Font $script:FontBodySmall -Color $script:P.Subtle
$backgroundCard.Controls.Add($notificationsHint)

$startNow = New-StudioButton -Text 'Start background now' -X 470 -Y 74 -Width 300 -Height 34 -Glyph ([string][char]0xE768)
$startNow.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$startNow.Add_Click({ Start-StudioBackground })
$backgroundCard.Controls.Add($startNow)
$openStartup = New-StudioButton -Text 'Open Startup folder' -X 470 -Y 116 -Width 300 -Height 34 -Glyph ([string][char]0xE838)
$openStartup.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$openStartup.Add_Click({ Open-StudioPath ([Environment]::GetFolderPath('Startup')) })
$backgroundCard.Controls.Add($openStartup)
$openDesktop = New-StudioButton -Text 'Open Desktop folder' -X 470 -Y 158 -Width 300 -Height 34 -Glyph ([string][char]0xE838)
$openDesktop.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$openDesktop.Add_Click({ Open-StudioPath ([Environment]::GetFolderPath('Desktop')) })
$backgroundCard.Controls.Add($openDesktop)

# Card: appearance
$appearanceCard = New-StudioSettingsCard -Title 'Appearance' -Description 'Choose how the Studio looks and speaks.' -Height 250
$settingsFlow.Controls.Add($appearanceCard)
$settingsCards.Add($appearanceCard)

$themeLabel = New-StudioLabel -Text 'STUDIO THEME' -X 20 -Y 70 -Width 180 -Height 16 -Font $script:FontMono -Color $script:P.Subtle
$appearanceCard.Controls.Add($themeLabel)
$comboTheme = New-StudioCombo -X 20 -Y 90 -Width 220
$themeKeys = @($script:ThemeList | ForEach-Object { 'Theme' + [string]$_.Key + 'Label' })
$themeLabels = @($script:ThemeList | ForEach-Object { [string]$_.Label })
Set-StudioLocalizedCombo -Combo $comboTheme -Keys $themeKeys -Defaults $themeLabels
$comboTheme.SelectedIndex = 0
$appearanceCard.Controls.Add($comboTheme)
$themeHint = New-StudioLabel -Text '' -X 270 -Y 84 -Width 500 -Height 38 -Font $script:FontBodySmall -Color $script:P.Muted
$appearanceCard.Controls.Add($themeHint)
$script:Ui.ThemeHint = $themeHint
$comboTheme.Add_SelectedIndexChanged({
    if (-not $script:SettingsLoaded) { return }
    $index = $comboTheme.SelectedIndex
    if ($index -ge 0 -and $index -lt $script:ThemeList.Count) {
        $themeHint.Text = (Get-StudioThemeDescription $script:ThemeList[$index]) + "`r`n" + (T 'ThemeHintIdle' 'Save to apply instantly, without reopening the Studio.')
    }
})

$languageLabel = New-StudioLabel -Text 'LANGUAGE' -X 20 -Y 140 -Width 180 -Height 16 -Font $script:FontMono -Color $script:P.Subtle
$appearanceCard.Controls.Add($languageLabel)
$comboLanguage = New-StudioCombo -X 20 -Y 160 -Width 220
foreach ($languageEntry in $script:LanguageList) { [void]$comboLanguage.Items.Add([string]$languageEntry.Label) }
$comboLanguage.SelectedIndex = 0
$appearanceCard.Controls.Add($comboLanguage)
$script:Ui.ComboLanguage = $comboLanguage
$languageHint = New-StudioLabel -Text 'English, Arabic, French, Spanish, German, Portuguese, Russian, Chinese and Turkish.' -X 270 -Y 154 -Width 500 -Height 38 -Font $script:FontBodySmall -Color $script:P.Muted
$appearanceCard.Controls.Add($languageHint)

# Card: smart capture
$smartCard = New-StudioSettingsCard -Title 'Smart capture' -Description 'Skip snapshots nobody needs, and capture from anywhere.' -Height 438
$settingsFlow.Controls.Add($smartCard)
$settingsCards.Add($smartCard)

$toggleIdle = New-StudioToggle -X 20 -Y 76 -Checked $true
$smartCard.Controls.Add($toggleIdle)
$idleLabel = New-StudioLabel -Text 'Pause while the PC is idle' -X 76 -Y 80 -Width 380 -Height 20 -Font $script:FontBody -Color $script:P.Text
$smartCard.Controls.Add($idleLabel)
$idleHint = New-StudioLabel -Text 'No snapshot runs after 15 minutes without keyboard or mouse activity.' -X 76 -Y 100 -Width 430 -Height 18 -Font $script:FontBodySmall -Color $script:P.Subtle
$smartCard.Controls.Add($idleHint)

$toggleFullscreen = New-StudioToggle -X 20 -Y 132 -Checked $true
$smartCard.Controls.Add($toggleFullscreen)
$fullscreenLabel = New-StudioLabel -Text 'Pause during fullscreen apps and games' -X 76 -Y 136 -Width 380 -Height 20 -Font $script:FontBody -Color $script:P.Text
$smartCard.Controls.Add($fullscreenLabel)

$toggleHotkey = New-StudioToggle -X 20 -Y 188 -Checked $true
$smartCard.Controls.Add($toggleHotkey)
$hotkeyLabel = New-StudioLabel -Text 'Ctrl+Alt+S captures a snapshot anywhere' -X 76 -Y 192 -Width 380 -Height 20 -Font $script:FontBody -Color $script:P.Text
$smartCard.Controls.Add($hotkeyLabel)
$hotkeyHint = New-StudioLabel -Text 'Works while the background app is running. Takes effect after saving.' -X 76 -Y 214 -Width 500 -Height 34 -Font $script:FontBodySmall -Color $script:P.Subtle
$smartCard.Controls.Add($hotkeyHint)

$toggleEvents = New-StudioToggle -X 20 -Y 244 -Checked $true
$smartCard.Controls.Add($toggleEvents)
$eventsLabel = New-StudioLabel -Text 'Capture on lock, sleep and low battery' -X 76 -Y 254 -Width 420 -Height 20 -Font $script:FontBody -Color $script:P.Text
$smartCard.Controls.Add($eventsLabel)

$toggleHibernate = New-StudioToggle -X 20 -Y 300 -Checked $true
$smartCard.Controls.Add($toggleHibernate)
$hibernateLabel = New-StudioLabel -Text 'Checkpoint before sleep or hibernate' -X 76 -Y 304 -Width 420 -Height 20 -Font $script:FontBody -Color $script:P.Text
$smartCard.Controls.Add($hibernateLabel)
$hibernateHint = New-StudioLabel -Text 'Saves and pins a snapshot before Windows suspends, keeping the latest three. Automatic pinning only; unsaved work is still not captured.' -X 76 -Y 324 -Width 620 -Height 34 -Font $script:FontBodySmall -Color $script:P.Subtle
$smartCard.Controls.Add($hibernateHint)

$toggleDev = New-StudioToggle -X 20 -Y 356 -Checked $true
$smartCard.Controls.Add($toggleDev)
$devLabel = New-StudioLabel -Text 'Capture dev workspaces (VS Code, Cursor, JetBrains, Windows Terminal)' -X 76 -Y 360 -Width 660 -Height 20 -Font $script:FontBody -Color $script:P.Text
$smartCard.Controls.Add($devLabel)
$devHint = New-StudioLabel -Text 'Reads the editors'' own recent-files state so restore can reopen the same folders.' -X 76 -Y 380 -Width 560 -Height 34 -Font $script:FontBodySmall -Color $script:P.Subtle
$smartCard.Controls.Add($devHint)

# Card: storage and privacy
$storageCard = New-StudioSettingsCard -Title 'Storage & privacy' -Description 'Everything Session Recovery saves stays in your local profile.' -Height 660
$settingsFlow.Controls.Add($storageCard)
$settingsCards.Add($storageCard)

$dataLabel = New-StudioLabel -Text 'DATA FOLDER' -X 20 -Y 70 -Width 160 -Height 16 -Font $script:FontMono -Color $script:P.Subtle
$storageCard.Controls.Add($dataLabel)
$dataPath = New-StudioLabel -Text '' -X 20 -Y 88 -Width 700 -Height 20 -Font $script:FontMono -Color $script:P.Muted
$storageCard.Controls.Add($dataPath)
$script:Ui.DataPath = $dataPath
$openData = New-StudioButton -Text 'Open data folder' -X 20 -Y 116 -Width 230 -Height 32 -Glyph ([string][char]0xE838)
$openData.Add_Click({ Open-StudioPath (Get-SRRoot) })
$storageCard.Controls.Add($openData)

$autoExportLabel = New-StudioLabel -Text 'AUTO-BACKUP FOLDER' -X 20 -Y 160 -Width 220 -Height 16 -Font $script:FontMono -Color $script:P.Subtle
$storageCard.Controls.Add($autoExportLabel)
$autoExportBox = New-StudioTextBox -X 20 -Y 178 -Width 560 -Height 28
$storageCard.Controls.Add($autoExportBox)
$script:Ui.AutoExportBox = $autoExportBox
$autoExportBrowse = New-StudioButton -Text 'Browse...' -X 592 -Y 177 -Width 110 -Height 30 -Glyph ''
$autoExportBrowse.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = 'Choose the auto-backup folder'
    if ($dialog.ShowDialog([System.Windows.Forms.Form]::ActiveForm) -eq [System.Windows.Forms.DialogResult]::OK) {
        $script:Ui.AutoExportBox.Text = $dialog.SelectedPath
    }
})
$storageCard.Controls.Add($autoExportBrowse)
$autoExportHint = New-StudioLabel -Text 'Each new snapshot is copied here as plain JSON (latest ten kept). Leave empty to turn off. Great for a synced folder.' -X 20 -Y 210 -Width 680 -Height 48 -Font $script:FontBodySmall -Color $script:P.Subtle
$storageCard.Controls.Add($autoExportHint)

$configLabel = New-StudioLabel -Text 'CONFIG FILE' -X 20 -Y 266 -Width 160 -Height 16 -Font $script:FontMono -Color $script:P.Subtle
$storageCard.Controls.Add($configLabel)
$configPath = New-StudioLabel -Text '' -X 20 -Y 284 -Width 700 -Height 20 -Font $script:FontMono -Color $script:P.Muted
$storageCard.Controls.Add($configPath)
$script:Ui.ConfigPath = $configPath
$openConfig = New-StudioButton -Text 'Open config' -X 20 -Y 312 -Width 170 -Height 32 -Glyph ''
$openConfig.Add_Click({
    $path = Get-SRConfigPath
    if (Test-Path -LiteralPath $path) { Start-Process -FilePath 'notepad.exe' -ArgumentList ('"{0}"' -f $path) | Out-Null }
})
$storageCard.Controls.Add($openConfig)
$openLogs = New-StudioButton -Text 'Open logs' -X 206 -Y 312 -Width 170 -Height 32 -Glyph ([string][char]0xE838)
$openLogs.Add_Click({ Open-StudioPath (Get-SRLogDirectory) })
$storageCard.Controls.Add($openLogs)

$toggleThumbs = New-StudioToggle -X 20 -Y 358 -Checked $false
$storageCard.Controls.Add($toggleThumbs)
$thumbsLabel = New-StudioLabel -Text 'Capture window thumbnails' -X 76 -Y 362 -Width 420 -Height 20 -Font $script:FontBody -Color $script:P.Text
$storageCard.Controls.Add($thumbsLabel)
$thumbsHint = New-StudioLabel -Text 'Stores a small JPEG of each window next to the snapshot. Off by default; excluded apps are never captured.' -X 76 -Y 382 -Width 560 -Height 42 -Font $script:FontBodySmall -Color $script:P.Subtle
$storageCard.Controls.Add($thumbsHint)

$toggleCompress = New-StudioToggle -X 20 -Y 432 -Checked $false
$storageCard.Controls.Add($toggleCompress)
$compressLabel = New-StudioLabel -Text 'Gzip snapshot files (smaller disk use)' -X 76 -Y 436 -Width 420 -Height 20 -Font $script:FontBody -Color $script:P.Text
$storageCard.Controls.Add($compressLabel)
$compressHint = New-StudioLabel -Text 'Unchanged moments are skipped automatically, so snapshots cover more real changes.' -X 76 -Y 456 -Width 560 -Height 42 -Font $script:FontBodySmall -Color $script:P.Subtle
$storageCard.Controls.Add($compressHint)

$toggleEncrypt = New-StudioToggle -X 20 -Y 506 -Checked $false
$storageCard.Controls.Add($toggleEncrypt)
$encryptLabel = New-StudioLabel -Text 'Encrypt snapshot files (DPAPI)' -X 76 -Y 510 -Width 420 -Height 20 -Font $script:FontBody -Color $script:P.Text
$storageCard.Controls.Add($encryptLabel)
$encryptHint = New-StudioLabel -Text 'Snapshots are sealed with your Windows user key. Encrypted exports only restore on this PC and user.' -X 76 -Y 530 -Width 560 -Height 48 -Font $script:FontBodySmall -Color $script:P.Subtle
$storageCard.Controls.Add($encryptHint)

$toggleVDesk = New-StudioToggle -X 20 -Y 588 -Checked $true
$storageCard.Controls.Add($toggleVDesk)
$vdeskLabel = New-StudioLabel -Text 'Remember virtual desktops' -X 76 -Y 592 -Width 420 -Height 20 -Font $script:FontBody -Color $script:P.Text
$storageCard.Controls.Add($vdeskLabel)
$vdeskHint = New-StudioLabel -Text 'Each window remembers which Windows desktop it was on, and restore moves it back when that desktop still exists.' -X 76 -Y 612 -Width 560 -Height 42 -Font $script:FontBodySmall -Color $script:P.Subtle
$storageCard.Controls.Add($vdeskHint)

$settingsPage.Add_Resize({ Layout-StudioSettings })

function Load-StudioSettings {
    $script:Config = Get-SRConfig
    $numInterval.Value = [Math]::Max(1, [Math]::Min(240, [int]$script:Config.snapshotIntervalMinutes))
    $numKeep.Value = [Math]::Max(1, [Math]::Min(1000, [int]$script:Config.keepSnapshots))
    $numDays.Value = [Math]::Max(0, [Math]::Min(3650, [int]$script:Config.keepSnapshotDays))
    $numMaxAge.Value = [Math]::Max(1, [Math]::Min(8760, [int]$script:Config.maxRestoreAgeHours))
    $numLookback.Value = [Math]::Max(1, [Math]::Min(168, [int]$script:Config.tabHistoryLookbackHours))
    $promptMap = @('Always', 'CrashOnly', 'Never')
    $promptIndex = [array]::IndexOf($promptMap, [string]$script:Config.promptOnLogon)
    $comboPrompt.SelectedIndex = if ($promptIndex -ge 0) { $promptIndex } else { 1 }
    $tabMap = @('Smart', 'Captured', 'Native', 'None')
    $tabIndex = [array]::IndexOf($tabMap, [string]$script:Config.defaultTabMode)
    $comboTabMode.SelectedIndex = if ($tabIndex -ge 0) { $tabIndex } else { 0 }
    $savedThemeKey = Resolve-StudioThemeKey -Theme ([string]$script:Config.theme)
    $themeIndex = 0
    for ($index = 0; $index -lt $script:ThemeList.Count; $index++) {
        if ([string]::Equals([string]$script:ThemeList[$index].Key, $savedThemeKey, [System.StringComparison]::OrdinalIgnoreCase)) {
            $themeIndex = $index
            break
        }
    }
    $comboTheme.SelectedIndex = $themeIndex
    $themeHint.Text = (Get-StudioThemeDescription $script:ThemeList[$themeIndex]) + "`r`n" + (T 'ThemeHintIdle' 'Save to apply instantly, without reopening the Studio.')
    $langIndex = 0
    for ($index = 0; $index -lt $script:LanguageList.Count; $index++) {
        if ([string]::Equals([string]$script:LanguageList[$index].Key, [string]$script:Config.language, [System.StringComparison]::OrdinalIgnoreCase)) {
            $langIndex = $index
            break
        }
    }
    $comboLanguage.SelectedIndex = $langIndex
    $idleProperty = $script:Config.PSObject.Properties['pauseWhenIdleMinutes']
    $toggleIdle.Checked = if ($null -ne $idleProperty) { ([int]$idleProperty.Value) -gt 0 } else { $true }
    $fullscreenProperty = $script:Config.PSObject.Properties['pauseOnFullscreen']
    $toggleFullscreen.Checked = if ($null -ne $fullscreenProperty) { [bool]$fullscreenProperty.Value } else { $true }
    $hotkeyProperty = $script:Config.PSObject.Properties['captureHotkey']
    $toggleHotkey.Checked = if ($null -ne $hotkeyProperty) { [bool]$hotkeyProperty.Value } else { $true }
    $autoExportProperty = $script:Config.PSObject.Properties['autoExportFolder']
    if ($null -ne $script:Ui.AutoExportBox) {
        $script:Ui.AutoExportBox.Text = if ($null -ne $autoExportProperty) { [string]$autoExportProperty.Value } else { '' }
    }
    $toggleRestoreBrowsers.Checked = [bool]$script:Config.restoreBrowsers
    $toggleCaptureBrowsers.Checked = [bool]$script:Config.captureBrowserTabs
    $toggleApprox.Checked = [bool]$script:Config.captureApproximateTabs
    $redactProperty = $script:Config.PSObject.Properties['redactUrls']
    $toggleRedact.Checked = if ($null -ne $redactProperty) { [bool]$redactProperty.Value } else { $true }
    $eventsProperty = $script:Config.PSObject.Properties['eventSnapshots']
    $toggleEvents.Checked = if ($null -ne $eventsProperty) { [bool]$eventsProperty.Value } else { $true }
    $hibernateProperty = $script:Config.PSObject.Properties['hibernateGuard']
    $toggleHibernate.Checked = if ($null -ne $hibernateProperty) { [bool]$hibernateProperty.Value } else { $true }
    $devProperty = $script:Config.PSObject.Properties['captureDevWorkspaces']
    $toggleDev.Checked = if ($null -ne $devProperty) { [bool]$devProperty.Value } else { $true }
    $thumbsSettingProperty = $script:Config.PSObject.Properties['captureThumbnails']
    $toggleThumbs.Checked = if ($null -ne $thumbsSettingProperty) { [bool]$thumbsSettingProperty.Value } else { $false }
    $compressSettingProperty = $script:Config.PSObject.Properties['compressSnapshots']
    $toggleCompress.Checked = if ($null -ne $compressSettingProperty) { [bool]$compressSettingProperty.Value } else { $false }
    $encryptSettingProperty = $script:Config.PSObject.Properties['encryptSnapshots']
    $toggleEncrypt.Checked = if ($null -ne $encryptSettingProperty) { [bool]$encryptSettingProperty.Value } else { $false }
    $vdeskSettingProperty = $script:Config.PSObject.Properties['restoreVirtualDesktops']
    $toggleVDesk.Checked = if ($null -ne $vdeskSettingProperty) { [bool]$vdeskSettingProperty.Value } else { $true }
    $mediaToggleProperty = $script:Config.PSObject.Properties['captureMediaPlayers']
    $toggleMedia.Checked = if ($null -ne $mediaToggleProperty) { [bool]$mediaToggleProperty.Value } else { $true }
    $toggleNotifications.Checked = [bool]$script:Config.showNotifications
    $toggleStartup.Checked = Test-Path -LiteralPath (Get-StudioStartupShortcutPath)
    $toggleDesktop.Checked = Test-Path -LiteralPath (Get-StudioDesktopShortcutPath)
    $script:Ui.DataPath.Text = Format-StudioPath (Get-SRRoot)
    $script:Ui.ConfigPath.Text = Format-StudioPath (Get-SRConfigPath)
    $script:SettingsLoaded = $true
    Set-StudioStatus '' $script:P.Muted
}

function Save-StudioSettings {
    try {
        $config = Get-SRConfig
        $config.snapshotIntervalMinutes = [int]$numInterval.Value
        $config.keepSnapshots = [int]$numKeep.Value
        $config.keepSnapshotDays = [int]$numDays.Value
        $config.maxRestoreAgeHours = [int]$numMaxAge.Value
        $config.tabHistoryLookbackHours = [int]$numLookback.Value
        $promptMap = @('Always', 'CrashOnly', 'Never')
        $config.promptOnLogon = $promptMap[[Math]::Max(0, $comboPrompt.SelectedIndex)]
        $tabMap = @('Smart', 'Captured', 'Native', 'None')
        $config.defaultTabMode = $tabMap[[Math]::Max(0, $comboTabMode.SelectedIndex)]
        $themeIndex = [Math]::Max(0, [Math]::Min(($script:ThemeList.Count - 1), $comboTheme.SelectedIndex))
        $selectedThemeKey = [string]$script:ThemeList[$themeIndex].Key
        $config.theme = $selectedThemeKey
        $langIndex = [Math]::Max(0, [Math]::Min(($script:LanguageList.Count - 1), $comboLanguage.SelectedIndex))
        $selectedLanguage = [string]$script:LanguageList[$langIndex].Key
        $languageChanged = ($selectedLanguage -ne $script:Lang)
        $config.language = $selectedLanguage
        $config.pauseWhenIdleMinutes = if ($toggleIdle.Checked) { 15 } else { 0 }
        $config.pauseOnFullscreen = [bool]$toggleFullscreen.Checked
        $config.captureHotkey = [bool]$toggleHotkey.Checked
        if ($null -ne $script:Ui.AutoExportBox) {
            $exportPath = $script:Ui.AutoExportBox.Text.Trim()
            if (-not [string]::IsNullOrWhiteSpace($exportPath) -and -not (Test-Path -LiteralPath $exportPath)) {
                try { New-Item -ItemType Directory -Path $exportPath -Force | Out-Null } catch { }
            }
            $config.autoExportFolder = $exportPath
        }
        $config.restoreBrowsers = [bool]$toggleRestoreBrowsers.Checked
        $config.captureBrowserTabs = [bool]$toggleCaptureBrowsers.Checked
        $config.captureApproximateTabs = [bool]$toggleApprox.Checked
        $config.redactUrls = [bool]$toggleRedact.Checked
        $config.eventSnapshots = [bool]$toggleEvents.Checked
        $config.hibernateGuard = [bool]$toggleHibernate.Checked
        $config.captureDevWorkspaces = [bool]$toggleDev.Checked
        $config.captureThumbnails = [bool]$toggleThumbs.Checked
        $config.compressSnapshots = [bool]$toggleCompress.Checked
        $config.encryptSnapshots = [bool]$toggleEncrypt.Checked
        $config.restoreVirtualDesktops = [bool]$toggleVDesk.Checked
        $config.captureMediaPlayers = [bool]$toggleMedia.Checked
        $config.showNotifications = [bool]$toggleNotifications.Checked
        $config.startWithWindows = [bool]$toggleStartup.Checked
        $config.desktopShortcut = [bool]$toggleDesktop.Checked
        Save-SRConfig -Config $config
        $script:Config = $config

        $themeChanged = ($selectedThemeKey -ne $script:ThemeKey)
        if ($themeChanged) {
            [void](Apply-StudioTheme -Theme $selectedThemeKey -Root $form)
        }
        if ($languageChanged) {
            # Re-localize the whole UI live: rebuild the reverse lookup from
            # English to the new language, mirror the layout for RTL, and
            # refresh the dynamic labels.
            Initialize-StudioLanguage -Language $selectedLanguage -Root $form
            Refresh-StudioData
            Show-StudioPage -Name $script:CurrentPage -Force
        }
        if ($null -ne $script:Ui.ThemeHint) {
            $script:Ui.ThemeHint.Text = (Get-StudioThemeDescription $script:ThemeList[$themeIndex]) + "`r`n" + (T 'ThemeHintSaved' 'Theme applied. Choose another and save to switch.')
        }

        $startupOk = Set-StudioStartWithWindows -Enabled ([bool]$toggleStartup.Checked)
        $desktopOk = Set-StudioDesktopShortcut -Enabled ([bool]$toggleDesktop.Checked)
        if (-not $startupOk) {
            $config.startWithWindows = $false
            $toggleStartup.Checked = $false
            Set-StudioStatus (T 'StatusSavedStartupFail' 'Settings saved, but the Startup shortcut could not be created.') $script:P.Amber
        } elseif (-not $desktopOk) {
            $config.desktopShortcut = $false
            $toggleDesktop.Checked = $false
            Set-StudioStatus (T 'StatusSavedDesktopFail' 'Settings saved, but the desktop shortcut could not be created.') $script:P.Amber
        } elseif ($themeChanged) {
            Set-StudioStatus (T 'StatusSavedTheme' 'Settings saved. The new theme is applied.') $script:P.Green
        } else {
            Set-StudioStatus (T 'StatusSaved' 'Settings saved. Background protection will pick them up automatically.') $script:P.Green
        }
        Save-SRConfig -Config $config
        $script:Config = $config
        Refresh-StudioData
        if ($themeChanged) {
            Show-StudioToast (T 'ToastThemeApplied' 'Settings saved. Theme applied.') $script:P.Green
        } else {
            Show-StudioToast (T 'ToastSettingsSaved' 'Settings saved.') $script:P.Green
        }
    } catch {
        $message = (T 'SaveSettingsFail' 'Could not save settings: {0}') -f $_.Exception.Message
        Set-StudioStatus $message $script:P.Red
        Show-StudioToast $message $script:P.Red
    }
}

function Reset-StudioSettings {
    $answer = [System.Windows.Forms.MessageBox]::Show(
        (T 'ConfirmResetText' 'Reset all capture, restore, startup and storage settings? Your exclusion lists will be kept.'),
        (T 'ConfirmResetTitle' 'Reset settings'), [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    try {
        $current = Get-SRConfig
        $defaults = Get-SRDefaultConfig
        $defaults.excludeApps = @($current.excludeApps)
        $defaults.excludeFolders = @($current.excludeFolders)
        $defaults.excludeUrls = @($current.excludeUrls)
        Save-SRConfig -Config $defaults
        $script:Config = Get-SRConfig
        $script:SettingsLoaded = $false
        Load-StudioSettings
        Save-StudioSettings
        Show-StudioToast (T 'ToastSettingsReset' 'Settings reset to defaults.') $script:P.Green
    } catch {
        Set-StudioStatus ((T 'ResetSettingsFail' 'Could not reset settings: {0}') -f $_.Exception.Message) $script:P.Red
    }
}

function Layout-StudioSettings {
    if (-not $script:Ui.SettingsFlow) { return }
    $flow = $script:Ui.SettingsFlow
    $flow.Width = $settingsPage.ClientSize.Width
    $flow.Height = [Math]::Max(160, $settingsPage.ClientSize.Height - 70)
    # Bottom padding keeps scrolled cards from sliding under the fixed
    # Save/Reset bar, which would cover the last rows of a card.
    $flow.Padding = New-Object System.Windows.Forms.Padding(24, 24, 24, 82)
    $settingsBar.Top = $settingsPage.ClientSize.Height - 70
    $settingsBar.Width = $settingsPage.ClientSize.Width
    [void](Set-StudioVerticalStack -Panel $flow -Cards $settingsCards -Padding 24 -BottomPadding 82 -MinWidth 620)
    $settingsSave.Left = $settingsPage.ClientSize.Width - 184
    $settingsReset.Left = $settingsSave.Left - 150
    $settingsStatus.Width = [Math]::Max(200, $settingsReset.Left - 48)
}

# ---------------------------------------------------------------------------
# Diagnostics
# ---------------------------------------------------------------------------

$diagnosticsPage = New-StudioPage -Name 'Diagnostics'
$diagFlow = New-Object System.Windows.Forms.Panel
$diagFlow.Dock = [System.Windows.Forms.DockStyle]::Fill
$diagFlow.Padding = New-Object System.Windows.Forms.Padding(24)
$diagFlow.AutoScroll = $true
$diagFlow.BackColor = $script:P.Bg
$diagnosticsPage.Controls.Add($diagFlow)
$script:Ui.DiagFlow = $diagFlow

$diagHealthCard = New-StudioSettingsCard -Title (T 'DiagSystemHealth' 'System health') -Description (T 'DiagSysDesc' 'A local check of snapshots, background protection and browser capture.') -Height 180 -WrapDescription
$diagFlow.Controls.Add($diagHealthCard)
# Long localized headlines wrap to a second line instead of running under the
# Run checks button; the detail line follows beneath them.
$diagHealthTitle = New-StudioLabel -Text (T 'CheckingWord' 'Checking...') -X 20 -Y 60 -Width 500 -Height 64 -Font (New-Object System.Drawing.Font('Segoe UI Semibold', 16)) -Color $script:P.Text
$diagHealthCard.Controls.Add($diagHealthTitle)
$script:Ui.DiagHealthTitle = $diagHealthTitle
$diagHealthDetail = New-StudioLabel -Text (T 'ReadingStatus' 'Reading local status...') -X 20 -Y 122 -Width 520 -Height 34 -Font $script:FontBodySmall -Color $script:P.Muted
$diagHealthCard.Controls.Add($diagHealthDetail)
$script:Ui.DiagHealthDetail = $diagHealthDetail

$diagRing = New-Object SessionRecovery.Studio.StudioRing
$diagRing.Location = New-Object System.Drawing.Point(640, 20)
$diagRing.Size = New-Object System.Drawing.Size(124, 124)
$diagRing.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$diagRing.Value = 0
$diagRing.CenterText = '--'
$diagRing.Caption = 'HEALTH'
$diagRing.ProgressColor = $script:P.Green
$diagRing.ProgressEndColor = $script:P.Accent2
$diagRing.TrackColor = $script:P.Border
$diagRing.CenterTextColor = $script:P.Text
$diagRing.CaptionColor = $script:P.Subtle
$diagHealthCard.Controls.Add($diagRing)
$script:Ui.DiagRing = $diagRing

$diagRefresh = New-StudioButton -Text (T 'BtnRunChecks' 'Run checks') -X 430 -Y 140 -Width 204 -Height 34 -Glyph ([string][char]0xE72C)
$diagRefresh.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$diagRefresh.Add_Click({ Refresh-StudioDiagnostics })
$diagHealthCard.Controls.Add($diagRefresh)
$script:Ui.DiagRefresh = $diagRefresh

$diagChecksCard = New-StudioSettingsCard -Title (T 'DiagChecks' 'Checks') -Description (T 'DiagChecksDesc' 'No cloud services and no account. These checks run against this PC only.') -Height 230
$diagFlow.Controls.Add($diagChecksCard)
$diagCheckFlow = New-Object System.Windows.Forms.FlowLayoutPanel
$diagCheckFlow.Location = New-Object System.Drawing.Point(20, 60)
$diagCheckFlow.Size = New-Object System.Drawing.Size(760, 154)
$diagCheckFlow.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$diagCheckFlow.FlowDirection = [System.Windows.Forms.FlowDirection]::TopDown
$diagCheckFlow.WrapContents = $false
$diagCheckFlow.AutoScroll = $true
$diagCheckFlow.BackColor = $script:P.Card
$diagChecksCard.Controls.Add($diagCheckFlow)
$script:Ui.DiagCheckFlow = $diagCheckFlow
$script:DiagnosticRows = @()

$diagInsightsCard = New-StudioSettingsCard -Title (T 'DiagInsights' 'Recovery insights') -Description (T 'DiagInsightsDesc' 'What your local snapshots contain. Nothing leaves this PC.') -Height 248 -WrapDescription
$diagFlow.Controls.Add($diagInsightsCard)
$diagInsightSummary = New-StudioLabel -Text (T 'InsightsLoading' 'Reading snapshots...') -X 20 -Y 72 -Width 760 -Height 38 -Font $script:FontBodySmall -Color $script:P.Text
$diagInsightsCard.Controls.Add($diagInsightSummary)
$script:Ui.InsightSummary = $diagInsightSummary
$diagTopAppsTitle = New-StudioLabel -Text (T 'InsightsTopApps' 'MOST CAPTURED APPS') -X 20 -Y 118 -Width 360 -Height 18 -Font $script:FontMono -Color $script:P.Subtle
$diagInsightsCard.Controls.Add($diagTopAppsTitle)
$diagTopApps = New-StudioLabel -Text '' -X 20 -Y 140 -Width 360 -Height 80 -Font $script:FontBodySmall -Color $script:P.Text
$diagInsightsCard.Controls.Add($diagTopApps)
$script:Ui.InsightTopApps = $diagTopApps
$diagTopSitesTitle = New-StudioLabel -Text (T 'InsightsTopSites' 'MOST CAPTURED SITES') -X 400 -Y 118 -Width 360 -Height 18 -Font $script:FontMono -Color $script:P.Subtle
$diagInsightsCard.Controls.Add($diagTopSitesTitle)
$diagTopSites = New-StudioLabel -Text '' -X 400 -Y 140 -Width 360 -Height 80 -Font $script:FontBodySmall -Color $script:P.Text
$diagInsightsCard.Controls.Add($diagTopSites)
$script:Ui.InsightTopSites = $diagTopSites

function Update-StudioInsights {
    if (-not $script:Ui.InsightSummary) { return }
    try {
        $insights = Get-SRRecoveryInsights -Entries $script:Snapshots -Config $script:Config
        if ([int]$insights.SnapshotCount -eq 0) {
            $script:Ui.InsightSummary.Text = (T 'InsightsNone' 'No snapshots yet. Capture one to start building local insights.')
            $script:Ui.InsightSummary.ForeColor = $script:P.Muted
            $script:Ui.InsightTopApps.Text = '—'
            $script:Ui.InsightTopSites.Text = '—'
            return
        }
        $script:Ui.InsightSummary.Text = ((T 'InsightsSummary' '{0} snapshot(s) over {1} day(s)  •  {2} app(s)  •  {3} site(s)  •  {4} pinned  •  {5} with notes  •  {6} imported  •  {7}') -f
            [int]$insights.SnapshotCount, [double]$insights.SpanDays, [int]$insights.UniqueApps, [int]$insights.UniqueSites,
            [int]$insights.PinnedCount, [int]$insights.NoteCount, [int]$insights.ImportedCount, (Format-StudioBytes -Bytes ([int64]$insights.StorageBytes)))
        $script:Ui.InsightSummary.ForeColor = $script:P.Text
        $appLines = @($insights.TopApps | ForEach-Object { '{0}  ({1})' -f $_.Name, $_.Count })
        $script:Ui.InsightTopApps.Text = if ($appLines.Count -eq 0) { (T 'InsightsNoApps' 'No applications captured yet.') } else { $appLines -join "`r`n" }
        $siteLines = @($insights.TopSites | ForEach-Object { '{0}  ({1})' -f $_.Name, $_.Count })
        $script:Ui.InsightTopSites.Text = if ($siteLines.Count -eq 0) { (T 'InsightsNoSites' 'No browser sites captured yet.') } else { $siteLines -join "`r`n" }
    } catch {
        $script:Ui.InsightSummary.Text = [string]$_.Exception.Message
        $script:Ui.InsightSummary.ForeColor = $script:P.Red
    }
}

$diagBrowserCard = New-StudioSettingsCard -Title (T 'DiagBrowsers' 'Detected browsers') -Description (T 'DiagBrowsersDesc' 'Supported browsers found on this PC.') -Height 152
$diagFlow.Controls.Add($diagBrowserCard)
$diagBrowserLabel = New-StudioLabel -Text (T 'CheckingWord' 'Checking...') -X 20 -Y 70 -Width 760 -Height 64 -Font $script:FontBodySmall -Color $script:P.Muted
$diagBrowserCard.Controls.Add($diagBrowserLabel)
$script:Ui.DiagBrowserLabel = $diagBrowserLabel

$diagLogCard = New-StudioSettingsCard -Title (T 'DiagActivityLog' 'Activity log') -Description (T 'DiagLogDesc' 'The most recent local log entries.') -Height 310
$diagFlow.Controls.Add($diagLogCard)
$diagLogText = New-StudioTextBox -X 20 -Y 62 -Width 760 -Height 180
$diagLogText.Multiline = $true
$diagLogText.ReadOnly = $true
$diagLogText.ScrollBars = [System.Windows.Forms.ScrollBars]::Both
$diagLogText.WordWrap = $false
$diagLogText.Font = $script:FontMono
$diagLogText.BackColor = $script:P.CardAlt
$diagLogText.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$diagLogCard.Controls.Add($diagLogText)
$script:Ui.DiagLogText = $diagLogText

$diagOpenLogs = New-StudioButton -Text (T 'BtnOpenLogs' 'Open logs') -X 20 -Y 252 -Width 170 -Height 32 -Glyph ([string][char]0xE838)
$diagOpenLogs.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
$diagOpenLogs.Add_Click({ Open-StudioPath (Get-SRLogDirectory) })
$diagLogCard.Controls.Add($diagOpenLogs)
$diagCopy = New-StudioButton -Text (T 'BtnCopyReport' 'Copy report') -X 200 -Y 252 -Width 132 -Height 32 -Glyph ''
$diagCopy.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
$diagCopy.Add_Click({
    try {
        [System.Windows.Forms.Clipboard]::SetText([string]$script:DiagnosticsReport)
        Show-StudioToast (T 'ToastReportCopied' 'Diagnostics report copied.') $script:P.Green
    } catch {
        Show-StudioToast ((T 'CopyReportFail' 'Could not copy report: {0}') -f $_.Exception.Message) $script:P.Red
    }
})
$diagLogCard.Controls.Add($diagCopy)

$diagnosticsPage.Add_Resize({ Layout-StudioDiagnostics })

function Update-StudioDiagnosticRowLayout {
    # Long details, especially absolute paths, wrap onto a second line instead
    # of being ellipsized. This keeps every diagnostics check fully readable
    # at the minimum window size in every language.
    param($Row)
    if ($null -eq $Row -or $Row.Controls.Count -lt 2) { return }
    $message = [string]$Row.Tag
    $label = $Row.Controls[1]
    $available = [Math]::Max(80, $Row.Width - 32)
    $singleLine = [System.Windows.Forms.TextFormatFlags]::SingleLine -bor [System.Windows.Forms.TextFormatFlags]::NoPadding
    $wordBreak = [System.Windows.Forms.TextFormatFlags]::WordBreak -bor [System.Windows.Forms.TextFormatFlags]::NoPadding
    $oneLine = [System.Windows.Forms.TextRenderer]::MeasureText($message, $label.Font, (New-Object System.Drawing.Size([int]::MaxValue, 20)), $singleLine)
    if ($oneLine.Width -le $available) {
        $Row.Height = 24
        $label.AutoEllipsis = $true
        $label.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
        $label.SetBounds(28, 2, $available, 20)
    } else {
        $measured = [System.Windows.Forms.TextRenderer]::MeasureText($message, $label.Font, (New-Object System.Drawing.Size($available, [int]::MaxValue)), $wordBreak)
        $Row.Height = [Math]::Max(40, $measured.Height + 6)
        $label.AutoEllipsis = $false
        $label.TextAlign = [System.Drawing.ContentAlignment]::TopLeft
        $label.SetBounds(28, 3, $available, $Row.Height - 5)
    }
}

function Add-StudioDiagnosticRow {
    param([bool]$Ok, [string]$Text, [string]$Detail = '')
    if (-not $script:Ui.DiagCheckFlow) { return }
    $row = New-Object System.Windows.Forms.Panel
    $row.Height = 24
    $row.Width = [Math]::Max(200, $script:Ui.DiagCheckFlow.ClientSize.Width - 8)
    $row.BackColor = $script:P.Card
    $row.Margin = New-Object System.Windows.Forms.Padding(0)
    $iconColor = if ($Ok) { $script:P.Green } else { $script:P.Amber }
    $icon = New-StudioLabel -Text $(if ($Ok) { [string][char]0xE73E } else { [string][char]0xE7BA }) -X 4 -Y 2 -Width 20 -Height 20 -Font (New-Object System.Drawing.Font('Segoe MDL2 Assets', 10)) -Color $iconColor -Align 'MiddleCenter'
    # The glyph is a single icon, not text. AutoEllipsis would turn it into
    # a tiny "..." at this width.
    $icon.AutoEllipsis = $false
    $row.Controls.Add($icon)
    $message = $Text
    if (-not [string]::IsNullOrWhiteSpace($Detail)) { $message += '  —  ' + $Detail }
    $label = New-StudioLabel -Text $message -X 28 -Y 2 -Width ($row.Width - 32) -Height 20 -Font $script:FontBodySmall -Color $script:P.Text
    $label.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $row.Controls.Add($label)
    $row.Tag = $message
    Update-StudioDiagnosticRowLayout -Row $row
    [void]$script:Ui.DiagCheckFlow.Controls.Add($row)
    $script:DiagnosticRows += $row
}

function Show-StudioDiagnosticsLoading {
    if (-not $script:Ui.DiagCheckFlow) { return }
    foreach ($row in $script:DiagnosticRows) { $row.Dispose() }
    $script:DiagnosticRows = @()
    $script:Ui.DiagCheckFlow.Controls.Clear()
    $messages = @(
        (T 'DiagLoadConfig' 'Reading local configuration...'),
        (T 'DiagLoadSnapshots' 'Checking snapshots and background protection...'),
        (T 'DiagLoadBrowsers' 'Detecting supported browsers...')
    )
    foreach ($message in $messages) {
        $row = New-Object System.Windows.Forms.Panel
        $row.Height = 24
        $row.Width = [Math]::Max(200, $script:Ui.DiagCheckFlow.ClientSize.Width - 8)
        $row.BackColor = $script:P.Card
        $row.Margin = New-Object System.Windows.Forms.Padding(0)
        $icon = New-StudioLabel -Text ([string][char]0xE823) -X 4 -Y 2 -Width 20 -Height 20 -Font (New-Object System.Drawing.Font('Segoe MDL2 Assets', 10)) -Color $script:P.Subtle -Align 'MiddleCenter'
        $row.Controls.Add($icon)
        $label = New-StudioLabel -Text $message -X 28 -Y 2 -Width ($row.Width - 32) -Height 20 -Font $script:FontBodySmall -Color $script:P.Muted
        $label.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
        $row.Controls.Add($label)
        [void]$script:Ui.DiagCheckFlow.Controls.Add($row)
        $script:DiagnosticRows += $row
    }
    $script:Ui.DiagBrowserLabel.Text = (T 'BrowsersChecking' 'Checking installed browsers...')
    $script:Ui.DiagLogText.Text = (T 'LogReading' 'Reading recent activity...')
}

function Render-StudioDiagnostics {
    param($Diag)
    if (-not $script:Ui.DiagHealthTitle) { return }
    try {
        $diag = $Diag
        if ($null -eq $diag) { throw 'Diagnostics returned no data.' }
        $script:Diagnostics = $diag
        $script:DiagnosticsDirty = $false
        $interval = [Math]::Max(1, [int]$script:Config.snapshotIntervalMinutes)
        $age = $null
        if ($null -ne $diag.LatestSnapshotAgeMinutes) { $age = [double]$diag.LatestSnapshotAgeMinutes }
        $score = 100
        if (-not $diag.ConfigValid) { $score -= 25 }
        if ([int]$diag.SnapshotCount -eq 0) { $score -= 30 }
        if ($null -ne $age -and $age -gt ($interval * 2.5)) { $score -= 20 }
        if ([string]$diag.ScheduleMode -eq 'Not running') { $score -= 20 }
        if (@($diag.Browsers).Count -eq 0) { $score -= 5 }
        $score = [Math]::Max(0, [Math]::Min(100, $score))
        $script:Ui.DiagRing.Value = $score
        $script:Ui.DiagRing.CenterText = [string]$score
        if ($score -ge 80) {
            $script:Ui.DiagRing.ProgressColor = $script:P.Green
            $script:Ui.DiagRing.ProgressEndColor = $script:P.Accent2
            $script:Ui.DiagHealthTitle.Text = (T 'Healthy' 'Everything looks healthy')
            $script:Ui.DiagHealthTitle.ForeColor = $script:P.Text
        } elseif ($score -ge 50) {
            $script:Ui.DiagRing.ProgressColor = $script:P.Amber
            $script:Ui.DiagRing.ProgressEndColor = $script:P.Amber
            $script:Ui.DiagHealthTitle.Text = (T 'AttentionNeeded' 'A little attention is needed')
            $script:Ui.DiagHealthTitle.ForeColor = $script:P.Amber
        } else {
            $script:Ui.DiagRing.ProgressColor = $script:P.Red
            $script:Ui.DiagRing.ProgressEndColor = $script:P.Red
            $script:Ui.DiagHealthTitle.Text = (T 'ProtectionAttention' 'Protection needs attention')
            $script:Ui.DiagHealthTitle.ForeColor = $script:P.Red
        }
        $script:Ui.DiagHealthDetail.Text = ((T 'DiagSummary' '{0} snapshot(s)  •  {1}  •  {2} browser(s) detected') -f $diag.SnapshotCount, (Get-StudioModeText ([string]$diag.ScheduleMode)), @($diag.Browsers).Count)

        foreach ($row in $script:DiagnosticRows) { $row.Dispose() }
        $script:DiagnosticRows = @()
        $script:Ui.DiagCheckFlow.Controls.Clear()

        if ($diag.ConfigValid) {
            Add-StudioDiagnosticRow -Ok $true -Text (T 'CheckConfigOk' 'Configuration is valid') -Detail (Split-Path -Leaf ([string]$diag.ConfigPath))
        } else {
            Add-StudioDiagnosticRow -Ok $false -Text (T 'CheckConfigBad' 'Configuration needs attention') -Detail ([string]$diag.ConfigError)
        }
        if ($null -eq $age) {
            Add-StudioDiagnosticRow -Ok $false -Text (T 'NoSnapshotSaved' 'No snapshot has been saved yet.') -Detail (T 'CaptureMomentHint' 'Use Capture now to make the first one.')
        } elseif ($age -le ($interval * 2.5)) {
            Add-StudioDiagnosticRow -Ok $true -Text (T 'CheckFresh' 'Latest snapshot is fresh') -Detail (Format-StudioAge -CapturedAt ([datetime]$diag.LatestSnapshotAt))
        } else {
            Add-StudioDiagnosticRow -Ok $false -Text (T 'CheckStale' 'Latest snapshot is older than expected') -Detail (Format-StudioAge -CapturedAt ([datetime]$diag.LatestSnapshotAt))
        }
        if ([string]$diag.ScheduleMode -eq 'Not running') {
            $disabledTask = @($diag.ScheduledTasks | Where-Object { -not [bool]$_.Enabled }).Count -gt 0
            $detail = if ($disabledTask) {
                (T 'CheckBgTaskDisabled' 'The Windows task is disabled. Enable it or start the background app.')
            } else {
                (T 'CheckBgStartHint' 'Start the background app from Settings.')
            }
            Add-StudioDiagnosticRow -Ok $false -Text (T 'CheckBgNone' 'Background protection is not running') -Detail $detail
        } else {
            Add-StudioDiagnosticRow -Ok $true -Text (T 'CheckBgOk' 'Background protection is active') -Detail (Get-StudioModeText ([string]$diag.ScheduleMode))
        }
        if (@($diag.Browsers).Count -gt 0) {
            Add-StudioDiagnosticRow -Ok $true -Text (T 'CheckBrowsersOk' 'Supported browsers detected') -Detail (@($diag.Browsers | ForEach-Object { $_.Name }) -join ', ')
        } else {
            Add-StudioDiagnosticRow -Ok $false -Text (T 'CheckBrowsersNone' 'No supported browsers detected') -Detail (T 'NoBrowsersDetected' 'Chrome, Edge, Brave or Firefox can be captured when installed.')
        }
        if (Test-Path -LiteralPath ([string]$diag.SnapshotDirectory)) {
            Add-StudioDiagnosticRow -Ok $true -Text (T 'CheckStorageOk' 'Snapshot storage is writable') -Detail (Format-StudioBytes -Bytes ([int64]$diag.SnapshotBytes))
        } else {
            Add-StudioDiagnosticRow -Ok $false -Text (T 'CheckStorageNone' 'Snapshot folder is missing') -Detail ([string]$diag.SnapshotDirectory)
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$diag.ShutdownReason) -or -not [string]::IsNullOrWhiteSpace([string]$diag.ShutdownReasonKey)) {
            $ok = ([string]$diag.ShutdownKind -ne 'crash')
            $shutdownInfo = [pscustomobject]@{
                Reason    = [string]$diag.ShutdownReason
                ReasonKey = [string]$diag.ShutdownReasonKey
                ReasonArg = [string]$diag.ShutdownReasonArg
            }
            $reasonText = Format-SRShutdownReason -Shutdown $shutdownInfo -Strings $script:L
            if (-not [string]::IsNullOrWhiteSpace($reasonText)) {
                Add-StudioDiagnosticRow -Ok $ok -Text ((T 'DiagShutdown' 'Last shutdown') + ': ' + $reasonText) -Detail (Format-StudioAge -CapturedAt ([datetime]$diag.ShutdownAt))
            }
        }

        $browsers = @($diag.Browsers)
        if ($browsers.Count -eq 0) {
            $script:Ui.DiagBrowserLabel.Text = (T 'NoBrowsersDetected' 'No supported browsers were detected. Session Recovery will still capture apps and folders.')
        } else {
            $script:Ui.DiagBrowserLabel.Text = ($browsers | ForEach-Object { '{0}  —  {1}' -f $_.Name, $_.Exe }) -join "`r`n"
        }

        $logPath = [string]$diag.LogPath
        if (Test-Path -LiteralPath $logPath) {
            $log = @(Get-Content -LiteralPath $logPath -Tail 160 -ErrorAction SilentlyContinue)
            $script:Ui.DiagLogText.Text = ($log -join "`r`n")
        } else {
            $script:Ui.DiagLogText.Text = (T 'NoLogYet' 'No log file yet. Once a snapshot or restore runs, activity appears here.')
        }
        $script:DiagnosticsReport = @(
            'Session Recovery diagnostics',
            'Generated: ' + $diag.GeneratedAt,
            'Health score: ' + $score,
            'Installed: ' + $diag.Installed,
            'Config valid: ' + $diag.ConfigValid,
            'Snapshot count: ' + $diag.SnapshotCount,
            'Latest snapshot age (min): ' + $diag.LatestSnapshotAgeMinutes,
            'Schedule mode: ' + $diag.ScheduleMode,
            'Scheduled tasks: ' + ((@($diag.ScheduledTasks) | ForEach-Object { '{0} ({1})' -f $_.Name, $_.State }) -join ', '),
            'Browsers: ' + (($browsers | ForEach-Object { $_.Name }) -join ', '),
            'Log: ' + $diag.LogPath
        ) -join "`r`n"
        Update-StudioInsights
        Layout-StudioDiagnostics
    } catch {
        $script:Ui.DiagHealthTitle.Text = (T 'DiagFailed' 'Diagnostics could not run')
        $script:Ui.DiagHealthTitle.ForeColor = $script:P.Red
        $script:Ui.DiagHealthDetail.Text = $_.Exception.Message
        $script:Ui.DiagRing.Value = 0
        $script:Ui.DiagRing.CenterText = '!'
        $script:DiagnosticsDirty = $true
    }
}

function Stop-StudioDiagnosticsLoading {
    if ($script:DiagLoadingTimer) {
        try { $script:DiagLoadingTimer.Stop() } catch { }
    }
    if ($script:Ui.DiagRefresh) { $script:Ui.DiagRefresh.Enabled = $true }
}

function Start-StudioDiagnosticsRefresh {
    param([switch]$Force)
    if (-not $script:Ui.DiagHealthTitle) { return }
    if ($script:DiagnosticsLoading) { return }
    if (-not $Force -and -not $script:DiagnosticsDirty -and $null -ne $script:Diagnostics) { return }
    $script:DiagnosticsDirty = $true
    $script:DiagnosticsLoading = $true
    $script:DiagStartedAt = Get-Date
    $script:DiagTitleBase = (T 'CheckingHealth' 'Checking local health')
    $script:Ui.DiagHealthTitle.Text = $script:DiagTitleBase
    $script:Ui.DiagHealthTitle.ForeColor = $script:P.Text
    $script:Ui.DiagHealthDetail.Text = (T 'ReadingChecks' 'Reading snapshots, tasks and browser information in the background.')
    $script:Ui.DiagRing.Value = 8
    $script:Ui.DiagRing.CenterText = '...'
    if ($script:Ui.DiagRefresh) { $script:Ui.DiagRefresh.Enabled = $false }
    Show-StudioDiagnosticsLoading

    # Keep the wait visibly alive: sweep the health ring and cycle the dots,
    # and never let a stuck check freeze the page forever.
    if ($null -eq $script:DiagLoadingTimer) {
        $script:DiagPhase = 0
        $script:DiagLoadingTimer = New-Object System.Windows.Forms.Timer
        $script:DiagLoadingTimer.Interval = 110
        $script:DiagLoadingTimer.Add_Tick({
            $script:DiagPhase = ($script:DiagPhase + 1) % 1000
            if ($script:Ui.DiagRing) {
                $script:Ui.DiagRing.Value = (8 + ($script:DiagPhase * 7) % 92)
            }
            if ($script:Ui.DiagHealthTitle -and $script:DiagnosticsLoading) {
                $dots = '.' * ((($script:DiagPhase / 4) % 3) + 1)
                $script:Ui.DiagHealthTitle.Text = $script:DiagTitleBase + $dots
            }
            if (((Get-Date) - $script:DiagStartedAt).TotalSeconds -gt 30) {
                Stop-StudioWorker -Name 'Diagnostics'
                $script:DiagnosticsLoading = $false
                Stop-StudioDiagnosticsLoading
                $script:DiagnosticsDirty = $true
                $script:Ui.DiagHealthTitle.Text = (T 'SlowChecks' 'Checks are taking longer than expected')
                $script:Ui.DiagHealthTitle.ForeColor = $script:P.Amber
                $script:Ui.DiagHealthDetail.Text = (T 'SlowChecksHint' 'The background check did not finish within 30 seconds. Choose Run checks to try again.')
                $script:Ui.DiagRing.Value = 0
                $script:Ui.DiagRing.CenterText = '!'
            }
        })
    }
    $script:DiagLoadingTimer.Stop()
    $script:DiagLoadingTimer.Start()

    try {
        Start-StudioWorker -Name 'Diagnostics' -SharedRunspace -Script {
            param($modulePath)
            $ErrorActionPreference = 'Stop'
            # The shared runspace stays warm, so only the very first check
            # pays for importing the module.
            if (-not (Get-Module -Name SessionRecovery -ErrorAction SilentlyContinue)) {
                Import-Module $modulePath -Force -ErrorAction Stop | Out-Null
            }
            Get-SRDiagnostics | ConvertTo-Json -Depth 10 -Compress
        } -Arguments @($modulePath)
    } catch {
        $script:DiagnosticsLoading = $false
        Stop-StudioDiagnosticsLoading
        $script:DiagnosticsDirty = $true
        $script:Ui.DiagHealthTitle.Text = (T 'DiagStartFailed' 'Diagnostics could not start')
        $script:Ui.DiagHealthTitle.ForeColor = $script:P.Red
        $script:Ui.DiagHealthDetail.Text = $_.Exception.Message
    }
}

function Refresh-StudioDiagnostics {
    Start-StudioDiagnosticsRefresh -Force
}

function Complete-StudioDiagnosticsWorker {
    param($Result)
    $script:DiagnosticsLoading = $false
    Stop-StudioDiagnosticsLoading
    if (-not [string]::IsNullOrWhiteSpace([string]$Result.Error)) {
        $script:DiagnosticsDirty = $true
        $script:Ui.DiagHealthTitle.Text = (T 'DiagFailed' 'Diagnostics could not run')
        $script:Ui.DiagHealthTitle.ForeColor = $script:P.Red
        $script:Ui.DiagHealthDetail.Text = [string]$Result.Error
        $script:Ui.DiagRing.Value = 0
        $script:Ui.DiagRing.CenterText = '!'
        return
    }
    try {
        $json = [string](@($Result.Output) | Select-Object -Last 1)
        if ([string]::IsNullOrWhiteSpace($json)) { throw 'Diagnostics returned no data.' }
        $diag = $json | ConvertFrom-Json
        Render-StudioDiagnostics -Diag $diag
    } catch {
        $script:DiagnosticsDirty = $true
        $script:Ui.DiagHealthTitle.Text = (T 'DiagFailed' 'Diagnostics could not run')
        $script:Ui.DiagHealthTitle.ForeColor = $script:P.Red
        $script:Ui.DiagHealthDetail.Text = $_.Exception.Message
        $script:Ui.DiagRing.Value = 0
        $script:Ui.DiagRing.CenterText = '!'
    }
}

function Layout-StudioDiagnostics {
    if (-not $script:Ui.DiagFlow) { return }
    $width = Set-StudioVerticalStack -Panel $script:Ui.DiagFlow -Cards @($diagHealthCard, $diagChecksCard, $diagInsightsCard, $diagBrowserCard, $diagLogCard) -Padding 24 -BottomPadding 24 -MinWidth 620
    # Ring at the right edge, with the Run checks button beneath it. The
    # headline and description may use the full width beside the ring, so
    # every translated headline still fits on one line. The detail summary
    # shares the button band and stops before it.
    $diagRing.Left = $width - $diagRing.Width - 26
    $diagRing.Top = [Math]::Max(12, [int](($diagHealthCard.Height - $diagRing.Height) / 2))
    $diagRefresh.Left = $diagRing.Left - $diagRefresh.Width - 16
    $diagRefresh.Top = 140
    $textWidth = [Math]::Max(200, $diagRefresh.Left - 40)
    $fullTextWidth = [Math]::Max(200, $diagRing.Left - 40)
    $diagHealthTitle.Width = $fullTextWidth
    $diagHealthDetail.Width = $textWidth
    # The health card's static description is anchored left/right by the
    # card helper; detach the right anchor so the ring's width is genuinely
    # reserved.
    $healthDescription = $null
    foreach ($child in @($diagHealthCard.Controls)) {
        if ($child -is [System.Windows.Forms.Label] -and (($child.Anchor -band [System.Windows.Forms.AnchorStyles]::Right) -eq [System.Windows.Forms.AnchorStyles]::Right)) {
            $healthDescription = $child
            break
        }
    }
    if ($null -ne $healthDescription) {
        $healthDescription.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left
        $healthDescription.Width = $fullTextWidth
    }
    $diagHealthTitle.Top = 76
    $diagHealthDetail.Top = 140
    $insightWidth = [Math]::Max(200, $width - 40)
    $halfWidth = [Math]::Max(180, [int](($insightWidth - 16) / 2))
    $diagInsightSummary.Width = $insightWidth
    $diagTopAppsTitle.Width = $halfWidth
    $diagTopApps.Width = $halfWidth
    $diagTopSitesTitle.Left = 20 + $halfWidth + 16
    $diagTopSitesTitle.Width = $halfWidth
    $diagTopSites.Left = $diagTopSitesTitle.Left
    $diagTopSites.Width = $halfWidth
    $diagCheckFlow.Width = [Math]::Max(200, $width - 40)
    $diagBrowserLabel.Width = [Math]::Max(200, $width - 40)
    $diagLogText.Width = [Math]::Max(200, $width - 40)
    $diagLogText.Height = [Math]::Max(100, $diagLogCard.Height - 130)
    $diagOpenLogs.Top = $diagLogCard.Height - 42
    $diagCopy.Top = $diagLogCard.Height - 42
    foreach ($row in $script:DiagnosticRows) {
        $row.Width = [Math]::Max(200, $diagCheckFlow.ClientSize.Width - 8)
        Update-StudioDiagnosticRowLayout -Row $row
    }
}

# ---------------------------------------------------------------------------
# Recovery Kit
# ---------------------------------------------------------------------------

function Update-StudioKitSummary {
    if (-not $script:Ui.KitSummary) { return }
    try {
        $notes = ConvertTo-SRNoteTable -Value $script:Config.snapshotNotes
        $noteCount = 0
        $bytes = [int64]0
        foreach ($entry in @($script:Snapshots)) {
            if ($null -eq $entry) { continue }
            if ($notes.ContainsKey((Split-Path -Leaf $entry.Path))) { $noteCount++ }
            try { $bytes += (Get-Item -LiteralPath $entry.Path).Length } catch { }
        }
        $rules = @($script:Config.excludeApps).Count + @($script:Config.excludeFolders).Count + @($script:Config.excludeUrls).Count
        $script:Ui.KitSummary.Text = ((T 'KitSummary' '{0} snapshot(s)  •  {1} note(s)  •  {2} exclusion rule(s)  •  {3}') -f @($script:Snapshots).Count, $noteCount, $rules, (Format-StudioBytes -Bytes $bytes))
        $script:Ui.KitSummary.ForeColor = $script:P.Text
    } catch {
        $script:Ui.KitSummary.Text = [string]$_.Exception.Message
        $script:Ui.KitSummary.ForeColor = $script:P.Red
    }
}

function Export-StudioRecoveryKit {
    if ($script:KitBusy) { return }
    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Title = (T 'KitExportDialogTitle' 'Export recovery kit')
    $dialog.Filter = (T 'KitFilter' 'Session Recovery kit (*.srkit)|*.srkit')
    $dialog.FileName = ('session-recovery-{0}.srkit' -f (Get-Date -Format 'yyyyMMdd-HHmm'))
    try {
        if ($dialog.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) { return }
        $script:KitBusy = $true
        [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::WaitCursor
        $result = Export-SRRecoveryKit -Destination $dialog.FileName -AppVersion $script:AppVersion
        Update-StudioKitSummary
        if ($script:Ui.KitImportStatus) {
            $script:Ui.KitImportStatus.Text = ((T 'KitExportedStatus' 'Exported {0} snapshot(s), {1} note(s) and {2} exclusion rule(s) to {3}.') -f $result.SnapshotCount, $result.NoteCount, $result.ExclusionCount, (Split-Path -Leaf $result.Path))
            $script:Ui.KitImportStatus.ForeColor = $script:P.Green
        }
        Show-StudioToast ((T 'ToastKitExported' 'Recovery kit saved to {0}.') -f (Split-Path -Leaf $result.Path)) $script:P.Green
    } catch {
        if ($script:Ui.KitImportStatus) {
            $script:Ui.KitImportStatus.Text = ((T 'ToastKitFailed' 'Recovery kit failed: {0}') -f $_.Exception.Message)
            $script:Ui.KitImportStatus.ForeColor = $script:P.Red
        }
        Show-StudioToast ((T 'ToastKitFailed' 'Recovery kit failed: {0}') -f $_.Exception.Message) $script:P.Red
    } finally {
        [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::Default
        $script:KitBusy = $false
        $dialog.Dispose()
    }
}

function Import-StudioRecoveryKit {
    if ($script:KitBusy) { return }
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = (T 'KitImportDialogTitle' 'Import recovery kit')
    $dialog.Filter = (T 'KitFilter' 'Session Recovery kit (*.srkit)|*.srkit')
    try {
        if ($dialog.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) { return }
        $script:KitBusy = $true
        [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::WaitCursor
        $result = Import-SRRecoveryKit -Path $dialog.FileName
        Refresh-StudioData
        $message = (T 'KitImportedStatus' 'Imported {0} snapshot(s), {1} note(s) and {2} exclusion rule(s). Skipped {3}, encrypted {4}.') -f $result.Imported, $result.NotesAdded, $result.ExclusionsAdded, $result.Skipped, $result.EncryptedSkipped
        if ($script:Ui.KitImportStatus) {
            $script:Ui.KitImportStatus.Text = $message
            $script:Ui.KitImportStatus.ForeColor = $script:P.Green
        }
        Show-StudioToast ((T 'ToastKitImported' 'Imported {0} snapshot(s) into this profile.') -f $result.Imported) $script:P.Green
    } catch {
        if ($script:Ui.KitImportStatus) {
            $script:Ui.KitImportStatus.Text = ((T 'ToastKitFailed' 'Recovery kit failed: {0}') -f $_.Exception.Message)
            $script:Ui.KitImportStatus.ForeColor = $script:P.Red
        }
        Show-StudioToast ((T 'ToastKitFailed' 'Recovery kit failed: {0}') -f $_.Exception.Message) $script:P.Red
    } finally {
        [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::Default
        $script:KitBusy = $false
        $dialog.Dispose()
    }
}

$recoveryKitPage = New-StudioPage -Name 'RecoveryKit'
$kitFlow = New-Object System.Windows.Forms.Panel
$kitFlow.Dock = [System.Windows.Forms.DockStyle]::Fill
$kitFlow.Padding = New-Object System.Windows.Forms.Padding(24)
$kitFlow.AutoScroll = $true
$kitFlow.BackColor = $script:P.Bg
$recoveryKitPage.Controls.Add($kitFlow)
$script:Ui.KitFlow = $kitFlow

$kitIntro = New-StudioLabel -Text (T 'KitIntro' 'Move snapshots, notes and exclusion rules between PCs with one portable file. Kits are processed locally.') -X 0 -Y 0 -Width 800 -Height 22 -Font $script:FontBody -Color $script:P.Muted
$kitIntro.AutoEllipsis = $true
$kitIntro.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 12)
$kitFlow.Controls.Add($kitIntro)

$kitExportCard = New-StudioSettingsCard -Title (T 'KitExportTitle' 'Create a kit') -Description (T 'KitExportDesc' 'Bundles every snapshot, snapshot note and exclusion rule into one .srkit file.') -Height 212 -WrapDescription
$kitFlow.Controls.Add($kitExportCard)
$kitSummary = New-StudioLabel -Text (T 'InsightsLoading' 'Reading snapshots...') -X 20 -Y 76 -Width 760 -Height 20 -Font $script:FontBodySmall -Color $script:P.Text
$kitExportCard.Controls.Add($kitSummary)
$script:Ui.KitSummary = $kitSummary
$kitWarning = New-StudioLabel -Text (T 'KitWarning' 'Kits are plaintext unless snapshot encryption is enabled. Encrypted snapshots can only be read on the Windows account that created them, so the importer skips them.') -X 20 -Y 102 -Width 760 -Height 44 -Font $script:FontBodySmall -Color $script:P.Amber
$kitWarning.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$kitExportCard.Controls.Add($kitWarning)
$kitExport = New-StudioButton -Text (T 'BtnKitExport' 'Export kit') -X 0 -Y 160 -Width 176 -Height 34 -Primary -Glyph ([string][char]0xE896)
$kitExport.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
$kitExport.Add_Click({ Export-StudioRecoveryKit })
$kitExportCard.Controls.Add($kitExport)
$script:Ui.KitExport = $kitExport

$kitImportCard = New-StudioSettingsCard -Title (T 'KitImportTitle' 'Restore from a kit') -Description (T 'KitImportDesc' 'Merges kit contents into this profile. Existing settings and snapshots are never overwritten.') -Height 212 -WrapDescription
$kitFlow.Controls.Add($kitImportCard)
$kitImportHint = New-StudioLabel -Text (T 'KitImportHint' 'Imported snapshots are marked as untrusted and ask before they open programs.') -X 20 -Y 76 -Width 760 -Height 34 -Font $script:FontBodySmall -Color $script:P.Muted
$kitImportHint.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$kitImportCard.Controls.Add($kitImportHint)
$kitImportStatus = New-StudioLabel -Text (T 'KitImportStatusIdle' 'No kit has been imported in this session.') -X 20 -Y 116 -Width 760 -Height 36 -Font $script:FontBodySmall -Color $script:P.Muted
$kitImportStatus.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$kitImportCard.Controls.Add($kitImportStatus)
$script:Ui.KitImportStatus = $kitImportStatus
$kitImport = New-StudioButton -Text (T 'BtnKitImport' 'Import kit') -X 0 -Y 160 -Width 176 -Height 34 -Glyph ([string][char]0xE8B5)
$kitImport.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
$kitImport.Add_Click({ Import-StudioRecoveryKit })
$kitImportCard.Controls.Add($kitImport)
$script:Ui.KitImport = $kitImport

$kitFooter = New-StudioLabel -Text (T 'KitFooter' 'A kit never includes settings, logs, screenshots or browser page content.') -X 0 -Y 0 -Width 800 -Height 18 -Font $script:FontBodySmall -Color $script:P.Subtle
$kitFooter.AutoEllipsis = $true
$kitFooter.Margin = New-Object System.Windows.Forms.Padding(0, 2, 0, 0)
$kitFlow.Controls.Add($kitFooter)

function Layout-StudioRecoveryKit {
    if (-not $script:Ui.KitFlow) { return }
    $width = Set-StudioVerticalStack -Panel $script:Ui.KitFlow -Cards @($kitExportCard, $kitImportCard) -Padding 24 -BottomPadding 48 -MinWidth 620
    $kitIntro.Left = 24
    $kitIntro.Top = 0
    $kitIntro.Width = $width
    $kitFooter.Left = 24
    $kitFooter.Top = $kitImportCard.Bottom + 8
    $kitFooter.Width = $width
    $kitSummary.Width = [Math]::Max(200, $width - 40)
    $kitWarning.Width = [Math]::Max(200, $width - 40)
    $kitImportHint.Width = [Math]::Max(200, $width - 40)
    $kitImportStatus.Width = [Math]::Max(200, $width - 40)
    $kitExport.Left = [Math]::Max(20, $width - 20 - $kitExport.Width)
    $kitImport.Left = [Math]::Max(20, $width - 20 - $kitImport.Width)
}

# ---------------------------------------------------------------------------
# About
# ---------------------------------------------------------------------------

$aboutPage = New-StudioPage -Name 'About'
$aboutFlow = New-Object System.Windows.Forms.Panel
$aboutFlow.Dock = [System.Windows.Forms.DockStyle]::Fill
$aboutFlow.Padding = New-Object System.Windows.Forms.Padding(24)
$aboutFlow.AutoScroll = $true
$aboutFlow.BackColor = $script:P.Bg
$aboutPage.Controls.Add($aboutFlow)
$script:Ui.AboutFlow = $aboutFlow

$aboutHero = New-StudioCard -X 0 -Y 0 -Width 800 -Height 184 -Fill $script:P.Card -Border $script:P.BorderSoft -Radius 16
$aboutHero.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 14)
$aboutFlow.Controls.Add($aboutHero)

$aboutIcon = New-Object System.Windows.Forms.PictureBox
$aboutIcon.Location = New-Object System.Drawing.Point(24, 26)
$aboutIcon.Size = New-Object System.Drawing.Size(68, 68)
$aboutIcon.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
$aboutIcon.BackColor = [System.Drawing.Color]::Transparent
if ($script:IconPath) {
    try { $aboutIcon.Image = (New-Object System.Drawing.Icon($script:IconPath)).ToBitmap() } catch { }
}
$aboutHero.Controls.Add($aboutIcon)
$aboutName = New-StudioLabel -Text 'Session Recovery' -X 110 -Y 26 -Width 460 -Height 40 -Font (New-Object System.Drawing.Font('Segoe UI Semibold', 24)) -Color $script:P.Text
$aboutHero.Controls.Add($aboutName)
$aboutTagline = New-StudioLabel -Text (T 'SubDashboard' 'Your session, exactly as you left it.') -X 112 -Y 67 -Width 460 -Height 20 -Font $script:FontBody -Color $script:P.Muted
$aboutHero.Controls.Add($aboutTagline)
$aboutVersion = New-StudioBadge -Text ((T 'AboutVersionLabel' 'VERSION') + ' ' + $script:AppVersion) -Width 128 -Height 24 -Fill $script:P.AccentSoft -TextColor $script:P.Accent
$aboutVersion.Location = New-Object System.Drawing.Point(112, 98)
$aboutHero.Controls.Add($aboutVersion)
$aboutGithub = New-StudioButton -Text (T 'BtnViewGithub' 'View on GitHub') -X 24 -Y 128 -Width 150 -Height 34 -Glyph ''
$aboutGithub.Add_Click({ Start-Process 'https://github.com/Bilalmesk/session-recovery' | Out-Null })
$aboutHero.Controls.Add($aboutGithub)
$aboutCopy = New-StudioButton -Text (T 'BtnCopyDiagnostics' 'Copy diagnostics') -X 184 -Y 128 -Width 180 -Height 34 -Glyph ''
$aboutCopy.Add_Click({
    try {
        $report = if ($script:DiagnosticsReport) { [string]$script:DiagnosticsReport } else { 'Session Recovery ' + $script:AppVersion }
        [System.Windows.Forms.Clipboard]::SetText($report)
        Show-StudioToast (T 'ToastReportCopied' 'Diagnostics report copied.') $script:P.Green
    } catch {
        Show-StudioToast ((T 'UpdateCopyFail' 'Could not copy: {0}') -f $_.Exception.Message) $script:P.Red
    }
})
$aboutHero.Controls.Add($aboutCopy)

$aboutLocal = New-StudioSettingsCard -Title (T 'AboutLocalTitle' 'Local by design') -Description (T 'AboutLocalDesc' 'No account, no cloud service and no telemetry.') -Height 180
$aboutFlow.Controls.Add($aboutLocal)
$aboutLocalText = New-StudioLabel -Text (T 'AboutLocalText' "Snapshots are plain JSON files in your Windows profile. Browser tabs are read locally, and restore opens apps and folders without rewriting files.`r`n`r`nThe background app keeps capturing while you work. Everything can be inspected, backed up or deleted from this Studio.") -X 20 -Y 64 -Width 740 -Height 100 -Font $script:FontBody -Color $script:P.Muted
$aboutLocal.Controls.Add($aboutLocalText)

$aboutNew = New-StudioSettingsCard -Title ((T 'WhatsNewTitle' 'What is new in {0}') -f $script:AppVersion) -Description (T 'WhatsNewDesc' 'Fixed text layout in every language, and closed privacy gaps.') -Height 260
$aboutFlow.Controls.Add($aboutNew)
$aboutNewText = New-StudioLabel -Text (T 'AboutWhatsNewText' "• Text no longer runs into other controls: labels ellipsize and badges resize in all nine languages.`r`n• Snapshots can be sealed with DPAPI encryption; gzip files now respect retention.`r`n• Virtual desktops are remembered per window and restored when possible.`r`n• Windows from unplugged monitors are mapped onto the current layout, not clamped.`r`n• PuTTY sessions and Remote Desktop targets reconnect directly on restore.`r`n• mpv reports exact playback positions through its IPC pipe.`r`n• Launch ordering rules, a restore preview, snapshot compare and a control pipe.`r`n• Pester tests and GitHub Actions CI build and verify every change.") -X 20 -Y 64 -Width 740 -Height 170 -Font $script:FontBody -Color $script:P.Muted
$aboutNew.Controls.Add($aboutNewText)

$aboutUpdates = New-StudioSettingsCard -Title (T 'SetUpdates' 'Application updates') -Description (T 'SetUpdatesDesc' 'Check the public GitHub releases page for a newer build.') -Height 240
$aboutFlow.Controls.Add($aboutUpdates)
$updateStatus = New-StudioLabel -Text ((T 'AboutVersionLine' 'You are running version {0}. Check for a newer build without leaving the Studio.') -f $script:AppVersion) -X 20 -Y 64 -Width 740 -Height 58 -Font $script:FontBody -Color $script:P.Muted
$aboutUpdates.Controls.Add($updateStatus)
$updateDetail = New-StudioLabel -Text '' -X 20 -Y 126 -Width 740 -Height 38 -Font $script:FontBodySmall -Color $script:P.Subtle
$aboutUpdates.Controls.Add($updateDetail)
$updateCheck = New-StudioButton -Text (T 'BtnCheckUpdates' 'Check for updates') -X 20 -Y 178 -Width 190 -Height 34 -Glyph ''
$aboutUpdates.Controls.Add($updateCheck)
$updateInstall = New-StudioButton -Text (T 'BtnDownloadInstall' 'Download and install') -X 226 -Y 178 -Width 200 -Height 34 -Glyph ''
$updateInstall.Visible = $false
$aboutUpdates.Controls.Add($updateInstall)
$updateRelease = New-StudioButton -Text (T 'BtnReleaseNotes' 'Release notes') -X 442 -Y 178 -Width 156 -Height 34 -Glyph ''
$updateRelease.Visible = $false
$aboutUpdates.Controls.Add($updateRelease)

$aboutData = New-StudioSettingsCard -Title (T 'AboutDataTitle' 'Data & support') -Description (T 'AboutDataDesc' 'Session Recovery is private and local. These are the only places it writes.') -Height 210
$aboutFlow.Controls.Add($aboutData)
$aboutDataText = New-StudioLabel -Text '' -X 20 -Y 64 -Width 740 -Height 84 -Font $script:FontMono -Color $script:P.Muted
$aboutData.Controls.Add($aboutDataText)
$aboutDataText.Text = ((T 'AboutDataLabelData' 'DATA') + '     ' + (Get-SRRoot)) + "`r`n" + ((T 'AboutDataLabelConfig' 'CONFIG') + '   ' + (Get-SRConfigPath)) + "`r`n" + ((T 'AboutDataLabelSnapshots' 'SNAPSHOTS') + ' ' + (Get-SRSnapshotDirectory))
$aboutDataOpen = New-StudioButton -Text (T 'BtnOpenData' 'Open data folder') -X 20 -Y 158 -Width 220 -Height 32 -Glyph ([string][char]0xE838)
$aboutDataOpen.Add_Click({ Open-StudioPath (Get-SRRoot) })
$aboutData.Controls.Add($aboutDataOpen)

$aboutFooter = New-StudioLabel -Text ((T 'AboutFooterNote' 'Session Recovery {0}  •  MIT licensed  •  made for Windows 10 and 11') -f $script:AppVersion) -X 0 -Y 0 -Width 800 -Height 18 -Font $script:FontBodySmall -Color $script:P.Subtle
$aboutFooter.Margin = New-Object System.Windows.Forms.Padding(0, 2, 0, 0)
$aboutFlow.Controls.Add($aboutFooter)

$script:Ui.UpdateStatus = $updateStatus
$script:Ui.UpdateDetail = $updateDetail
$script:Ui.UpdateCheck = $updateCheck
$script:Ui.UpdateInstall = $updateInstall
$script:Ui.UpdateRelease = $updateRelease

function Set-StudioUpdateStatus {
    param(
        [string]$Text,
        [System.Drawing.Color]$Color = $script:P.Muted,
        [string]$Detail = ''
    )
    $script:Ui.UpdateStatus.Text = $Text
    $script:Ui.UpdateStatus.ForeColor = $Color
    $script:Ui.UpdateDetail.Text = $Detail
}

function Start-StudioUpdateCheck {
    if ($script:UpdateBusy -or $script:UpdateInstalling) { return }
    $script:UpdateAction = 'check'
    $script:UpdateBusy = $true
    $script:AvailableUpdate = $null
    $script:DownloadedUpdate = $null
    $script:Ui.UpdateCheck.Enabled = $false
    $script:Ui.UpdateInstall.Visible = $false
    $script:Ui.UpdateRelease.Visible = $false
    Set-StudioUpdateStatus -Text (T 'UpdateChecking' 'Checking GitHub Releases...') -Color $script:P.Accent -Detail (T 'UpdateCheckDetail' 'The check runs in the background and never uploads snapshots.')
    try {
        Start-StudioWorker -Name 'Update' -Script {
            param($modulePath, $currentVersion, $action, $payload)
            $ErrorActionPreference = 'Stop'
            Import-Module $modulePath -Force -ErrorAction Stop | Out-Null
            if ($action -eq 'check') {
                Get-SRUpdateInfo -CurrentVersion $currentVersion | ConvertTo-Json -Depth 8 -Compress
            } else {
                Save-SRUpdate -UpdateJson $payload | ConvertTo-Json -Depth 6 -Compress
            }
        } -Arguments @($modulePath, [string]$script:AppVersion, 'check', '')
    } catch {
        $script:UpdateBusy = $false
        $script:Ui.UpdateCheck.Enabled = $true
        Set-StudioUpdateStatus -Text (T 'UpdateCheckStartFail' 'Could not start the update check.') -Color $script:P.Red -Detail $_.Exception.Message
    }
}

function Start-StudioUpdateDownload {
    if ($script:UpdateBusy -or $script:UpdateInstalling) { return }
    if ($null -ne $script:DownloadedUpdate -and (Test-Path -LiteralPath $script:DownloadedUpdate.MsiPath -PathType Leaf)) {
        Confirm-StudioUpdateInstall
        return
    }
    if ($null -eq $script:AvailableUpdate) { return }
    $script:UpdateAction = 'download'
    $script:UpdateBusy = $true
    $script:Ui.UpdateCheck.Enabled = $false
    $script:Ui.UpdateInstall.Enabled = $false
    Set-StudioUpdateStatus -Text ((T 'UpdateDownloading' 'Downloading version {0}...') -f $script:AvailableUpdate.LatestVersion) -Color $script:P.Accent -Detail (T 'UpdateDownloadDetail' 'The MSI will be checked against the release SHA256 before installation.')
    try {
        $payload = $script:AvailableUpdate | ConvertTo-Json -Depth 8 -Compress
        Start-StudioWorker -Name 'Update' -Script {
            param($modulePath, $currentVersion, $action, $payload)
            $ErrorActionPreference = 'Stop'
            Import-Module $modulePath -Force -ErrorAction Stop | Out-Null
            if ($action -eq 'check') {
                Get-SRUpdateInfo -CurrentVersion $currentVersion | ConvertTo-Json -Depth 8 -Compress
            } else {
                Save-SRUpdate -UpdateJson $payload | ConvertTo-Json -Depth 6 -Compress
            }
        } -Arguments @($modulePath, [string]$script:AppVersion, 'download', $payload)
    } catch {
        $script:UpdateBusy = $false
        $script:Ui.UpdateCheck.Enabled = $true
        $script:Ui.UpdateInstall.Enabled = $true
        Set-StudioUpdateStatus -Text (T 'UpdateDownloadStartFail' 'Could not start the update download.') -Color $script:P.Red -Detail $_.Exception.Message
    }
}

function Install-StudioUpdatePackage {
    param(
        [Parameter(Mandatory = $true)][string]$MsiPath,
        [string]$Version = ''
    )
    if (-not (Test-Path -LiteralPath $MsiPath -PathType Leaf)) {
        Set-StudioUpdateStatus -Text (T 'UpdatePackageMissing' 'The downloaded update package is missing.') -Color $script:P.Red -Detail (T 'UpdateCheckAgain' 'Check again to download a fresh copy.')
        return
    }
    $script:UpdateInstalling = $true
    $script:Ui.UpdateCheck.Enabled = $false
    $script:Ui.UpdateInstall.Enabled = $false
    Set-StudioUpdateStatus -Text ((T 'UpdateInstalling' 'Starting the Windows installer for {0}...') -f $Version) -Color $script:P.Accent -Detail (T 'UpdateInstallDetail' 'The Studio will close while the update installs. Snapshots and settings are preserved.')
    [System.Windows.Forms.Application]::DoEvents()
    try {
        Start-SRUpdateInstall -MsiPath $MsiPath | Out-Null
        $form.Close()
    } catch {
        $script:UpdateInstalling = $false
        $script:Ui.UpdateCheck.Enabled = $true
        $script:Ui.UpdateInstall.Enabled = $true
        Set-StudioUpdateStatus -Text (T 'UpdateInstallFail' 'The update could not be started.') -Color $script:P.Red -Detail $_.Exception.Message
    }
}

function Confirm-StudioUpdateInstall {
    if ($null -eq $script:DownloadedUpdate) { return }
    $version = [string]$script:DownloadedUpdate.Version
    $signed = $false
    $signedProperty = $script:DownloadedUpdate.PSObject.Properties['Signed']
    if ($null -ne $signedProperty) {
        try { $signed = [bool]$signedProperty.Value } catch { $signed = $false }
    }
    if ($signed) {
        $text = ((T 'UpdateConfirmText' "Version {0} is downloaded and its SHA256 hash matches the release.`r`n`r`nInstall now? The Studio will close while the per-user MSI updates the app. Your snapshots, settings and exclusions are kept.") -f $version)
        $title = (T 'UpdateConfirmTitle' 'Install Session Recovery update')
        $icon = [System.Windows.Forms.MessageBoxIcon]::Question
        $defaultButton = [System.Windows.Forms.MessageBoxDefaultButton]::Button1
    } else {
        # The hash comes from the same release as the MSI, so it proves only
        # that the download is intact. Make the missing signature explicit and
        # default to No instead of silently installing the file.
        $text = ((T 'UpdateUnsignedConfirmText' "UNSIGNED UPDATE. Version {0} is downloaded and its SHA256 hash matches the release, but the MSI is not digitally signed. Windows cannot verify who published or built this file.`r`n`r`nInstall it only if you trust this GitHub repository and the network you downloaded it from. Install now?") -f $version)
        $title = (T 'UpdateUnsignedConfirmTitle' 'Install unsigned update?')
        $icon = [System.Windows.Forms.MessageBoxIcon]::Warning
        $defaultButton = [System.Windows.Forms.MessageBoxDefaultButton]::Button2
    }
    $answer = [System.Windows.Forms.MessageBox]::Show(
        $text,
        $title,
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        $icon,
        $defaultButton)
    if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
        Install-StudioUpdatePackage -MsiPath $script:DownloadedUpdate.MsiPath -Version $version
    } else {
        $detailKey = if ($signed) { 'UpdateReadyDetail' } else { 'UpdateUnsignedReadyDetail' }
        $detailDefault = if ($signed) {
            'Click Install update when you are ready. The downloaded package stays in your profile.'
        } else {
            'The unsigned package was not installed. You can delete it from your profile or install it later after reviewing the warning.'
        }
        Set-StudioUpdateStatus -Text ((T 'UpdateReady' 'Version {0} is ready to install.') -f $version) -Color $(if ($signed) { $script:P.Green } else { $script:P.Amber }) -Detail (T $detailKey $detailDefault)
    }
}

function Complete-StudioUpdateWorker {
    param($Result)
    $script:UpdateBusy = $false
    $script:Ui.UpdateCheck.Enabled = $true
    $script:Ui.UpdateInstall.Enabled = $true
    $action = $script:UpdateAction

    $data = $null
    try {
        $json = [string](@($Result.Output) | Select-Object -Last 1)
        if (-not [string]::IsNullOrWhiteSpace($json)) { $data = $json | ConvertFrom-Json }
    } catch { }

    if ($null -eq $data) {
        $message = if (-not [string]::IsNullOrWhiteSpace([string]$Result.Error)) { [string]$Result.Error } else { (T 'UpdateNoResult' 'The update service returned no result.') }
        Set-StudioUpdateStatus -Text (T 'UpdateCheckFail' 'Could not check for updates.') -Color $script:P.Red -Detail $message
        return
    }

    if ($action -eq 'check') {
        if (-not [bool]$data.Ok) {
            $hint = if ($data.PSObject.Properties['Hint'] -and -not [string]::IsNullOrWhiteSpace([string]$data.Hint)) { [string]$data.Hint } else { [string]$data.Error }
            Set-StudioUpdateStatus -Text (T 'UpdateCheckFail' 'Could not check for updates.') -Color $script:P.Red -Detail $hint
            return
        }
        if ([bool]$data.HasUpdate) {
            if ([string]::IsNullOrWhiteSpace([string]$data.MsiName) -or [string]::IsNullOrWhiteSpace([string]$data.ShaName)) {
                $script:AvailableUpdate = $data
                $script:Ui.UpdateRelease.Visible = $true
                Set-StudioUpdateStatus -Text ((T 'UpdateIncomplete' 'Version {0} is available, but the release is incomplete.') -f $data.LatestVersion) -Color $script:P.Amber -Detail (T 'UpdateIncompleteDetail' 'The release needs both a SessionRecovery MSI and a .msi.sha256 asset before the Studio can install it.')
                return
            }
            $script:AvailableUpdate = $data
            $script:Ui.UpdateInstall.Text = (T 'BtnDownloadInstall' 'Download and install')
            $script:Ui.UpdateInstall.Visible = $true
            $script:Ui.UpdateRelease.Visible = $true
            Set-StudioUpdateStatus -Text ((T 'UpdateAvailable' 'Version {0} is available.') -f $data.LatestVersion) -Color $script:P.Green -Detail ([string]$data.Name)
        } else {
            Set-StudioUpdateStatus -Text (T 'UpdateUpToDate' 'You are up to date.') -Color $script:P.Green -Detail ((T 'UpdateLatest' 'Version {0} is the latest release.') -f $data.LatestVersion)
        }
        return
    }

    if (-not [bool]$data.Ok) {
        Set-StudioUpdateStatus -Text (T 'UpdateDownloadFail' 'The update download failed.') -Color $script:P.Red -Detail ([string]$data.Error)
        return
    }
    $script:DownloadedUpdate = $data
    $signed = $false
    $signedProperty = $data.PSObject.Properties['Signed']
    if ($null -ne $signedProperty) {
        try { $signed = [bool]$signedProperty.Value } catch { $signed = $false }
    }
    $script:Ui.UpdateInstall.Text = (T 'UpdateInstallButton' 'Install update')
    $script:Ui.UpdateInstall.Visible = $true
    if ($signed) {
        Set-StudioUpdateStatus -Text ((T 'UpdateVerified' 'Version {0} is downloaded and verified.') -f $data.Version) -Color $script:P.Green -Detail (T 'UpdateVerifiedDetail' 'SHA256 verified. The installer keeps your snapshots, settings and exclusions.')
    } else {
        Set-StudioUpdateStatus -Text ((T 'UpdateUnsignedVerified' 'Version {0} is downloaded, but the MSI is unsigned.') -f $data.Version) -Color $script:P.Amber -Detail (T 'UpdateUnsignedVerifiedDetail' 'SHA256 matches the release, but Windows cannot verify who published this file. The install confirmation explains the risk.')
    }
    Confirm-StudioUpdateInstall
}

$updateCheck.Add_Click({ Start-StudioUpdateCheck })
$updateInstall.Add_Click({ Start-StudioUpdateDownload })
$updateRelease.Add_Click({
    if ($null -ne $script:AvailableUpdate -and -not [string]::IsNullOrWhiteSpace([string]$script:AvailableUpdate.ReleaseUrl)) {
        Start-Process ([string]$script:AvailableUpdate.ReleaseUrl) | Out-Null
    }
})

function Layout-StudioAbout {
    if (-not $script:Ui.AboutFlow) { return }
    $width = Set-StudioVerticalStack -Panel $script:Ui.AboutFlow -Cards @($aboutHero, $aboutUpdates, $aboutLocal, $aboutNew, $aboutData, $aboutFooter) -Padding 24 -BottomPadding 24 -MinWidth 620
    $aboutLocalText.Width = $width - 40
    $aboutNewText.Width = $width - 40
    $updateStatus.Width = $width - 40
    $updateDetail.Width = $width - 40
    $aboutDataText.Width = $width - 40
    $aboutFooter.Width = $width
}

# ---------------------------------------------------------------------------
# Layout and page switching
# ---------------------------------------------------------------------------

foreach ($bufferedControl in @($main, $sidebar, $header, $snapSplit, $snapFlow, $recentFlow, $settingsFlow, $exFlow, $diagFlow, $aboutFlow)) {
    Enable-StudioDoubleBuffer $bufferedControl
}

function Layout-StudioSidebar {
    $height = $sidebar.ClientSize.Height
    if ($height -le 100) { return }
    $restoreSidebar.Top = $height - 250
    $sidebarStatusCard.Top = $height - 198
    $sidebarVersion.Top = $height - 28
}

function Layout-StudioHeader {
    $width = $main.ClientSize.Width
    if ($width -le 100) { return }
    $header.Width = $width
    $headerLine.Width = $width
    $pageHost.Location = New-Object System.Drawing.Point(0, 88)
    $pageHost.Size = New-Object System.Drawing.Size($width, [Math]::Max(100, $main.ClientSize.Height - 88))
    $pageTitle.Width = [Math]::Max(300, $width - 360)
    $pageSubtitle.Width = [Math]::Max(280, $width - 380)
    $toastLabel.Width = [Math]::Max(280, $width - 380)
    $right = $width - 28
    if ($captureButton.Visible) {
        $captureButton.Left = $right - $captureButton.Width
        $right = $captureButton.Left - 16
    }
    if ($refreshButton.Visible) {
        $refreshButton.Left = $width - 28 - $refreshButton.Width
        $right = $refreshButton.Left - 16
    }
    $localBadge.Left = $right - $localBadge.Width
    # The page title must stop before the status badge. Its old fixed width
    # let long translated headers (and the wider RTL badge labels) share the
    # same pixels even when the visible text was short.
    $pageTitle.Width = [Math]::Max(300, $localBadge.Left - 44)
}

function Layout-StudioDashboard {
    if (-not $dashboard -or $dashboard.ClientSize.Width -lt 200) { return }
    $width = $dashboard.ClientSize.Width
    $height = $dashboard.ClientSize.Height
    $hero.Width = $width - 48
    $heroRing.Left = $hero.Width - 158
    # Long translations wrap onto a second line, then stop before the ring.
    $heroSub.Width = [Math]::Max(240, $hero.Width - 220)
    $heroSub.Height = 36
    $heroLast.Width = [Math]::Max(240, $hero.Width - 200)
    $heroNext.Width = [Math]::Max(240, $hero.Width - 200)
    $statRow.Width = $width - 48
    $cards = @($statSnapshots, $statApps, $statTabs, $statStorage)
    $gap = 14
    $cardWidth = [int][Math]::Floor(($statRow.Width - (3 * $gap)) / 4)
    $x = 0
    foreach ($card in $cards) {
        $card.Left = $x
        $card.Width = $cardWidth
        $x += $cardWidth + $gap
    }
    $lowerTop = 342
    $lowerHeight = [Math]::Max(200, $height - $lowerTop - 20)
    $quickWidth = 300
    $recentWidth = [Math]::Max(360, $width - 48 - $quickWidth - 16)
    $recentCard.Left = 24
    $recentCard.Top = $lowerTop
    $recentCard.Width = $recentWidth
    $recentCard.Height = $lowerHeight
    $quickCard.Left = $width - 24 - $quickWidth
    $quickCard.Top = $lowerTop
    $quickCard.Width = $quickWidth
    $quickCard.Height = $lowerHeight
    $recentViewAll.Left = $recentCard.Width - 178
    # Keep the heading box clear of the right-aligned button at the minimum
    # window size; the longest translation still fits comfortably.
    $recentHeading.Width = [Math]::Max(120, $recentViewAll.Left - 18 - 12)
    $recentFlow.Width = $recentCard.Width - 32
    $recentFlow.Height = [Math]::Max(72, $lowerHeight - 94)
    $recentSpark.Top = $lowerHeight - 42
    $recentSpark.Width = $recentCard.Width - 32
    foreach ($button in @($quickCapture, $quickRestore, $quickFolder, $quickDiagnostics)) {
        $button.Width = $quickCard.Width - 32
    }
    $quickRestore.Top = 86
    $quickFolder.Top = 128
    $quickDiagnostics.Top = 170
    $dashboardHint.Top = $height - 24
}

$script:SnapshotLayoutTimer = $null
function Layout-StudioSnapshots {
    if (-not $snapshotsPage -or $snapshotsPage.ClientSize.Width -lt 200) { return }
    $width = $snapshotsPage.ClientSize.Width
    $height = $snapshotsPage.ClientSize.Height
    $snapToolbar.Width = $width - 48
    # Right-align the toolbar actions first, then give the search/filter the
    # room that is left. The snapshot count is the first thing to go when the
    # window is too narrow for all five controls.
    $right = $snapToolbar.Width - 28
    $snapRefresh.Left = $right - $snapRefresh.Width
    $right = $snapRefresh.Left - 12
    $snapOpenFolder.Left = $right - $snapOpenFolder.Width
    $right = $snapOpenFolder.Left - 12
    $available = $right - 16
    if ($available -ge 540) {
        $searchWidth = 230
        $filterWidth = 170
    } else {
        $searchWidth = 190
        $filterWidth = 150
    }
    $snapSearch.Width = $searchWidth
    $snapFilter.Left = 16 + $searchWidth + 12
    $snapFilter.Width = $filterWidth
    $snapCount.Left = $snapFilter.Left + $filterWidth + 12
    $countWidth = $right - $snapCount.Left
    $snapCount.Visible = ($countWidth -ge 96)
    $snapCount.Width = [Math]::Max(80, $countWidth)
    $snapSplit.Location = New-Object System.Drawing.Point(24, 90)
    $snapSplit.Size = New-Object System.Drawing.Size(($width - 48), [Math]::Max(260, $height - 110))
    # On very narrow splits two labelled buttons leave no room for the
    # timeline heading. Keep the glyph buttons and free the header room.
    $listWidth = [Math]::Max(320, $snapSplit.Panel1.ClientSize.Width)
    $compactList = $listWidth -lt 440
    if ($compactList) {
        $snapExport.Text = ''
        $snapExport.Width = 44
        $snapImport.Text = ''
        $snapImport.Width = 44
    } else {
        $snapExport.Text = (T 'BtnExport' 'Export')
        $snapExport.Width = 120
        $snapImport.Text = (T 'BtnImport' 'Import')
        $snapImport.Width = 120
    }
    $snapExport.Left = $listWidth - 18 - $snapExport.Width
    $snapImport.Left = $snapExport.Left - 12 - $snapImport.Width
    $headingRoom = [Math]::Max(80, $snapImport.Left - 26)
    $snapListHeading.Width = [Math]::Min(260, $headingRoom)
    $snapListHint.Width = [Math]::Min(260, $headingRoom)
    $rowWidth = [Math]::Max(300, $snapFlow.ClientSize.Width - 22)
    # The empty-state text belongs to the list panel. Keep it inside the
    # splitter at the minimum window size instead of letting it run under the
    # detail card.
    if ($script:Ui.SnapEmpty) { $script:Ui.SnapEmpty.Width = [Math]::Max(160, $listWidth - 36) }
    if ($script:LastSnapFlowWidth -eq $rowWidth) { return }
    $script:LastSnapFlowWidth = $rowWidth
    if ($script:CurrentPage -eq 'Snapshots') {
        if ($null -eq $script:SnapshotLayoutTimer) {
            $script:SnapshotLayoutTimer = New-Object System.Windows.Forms.Timer
            $script:SnapshotLayoutTimer.Interval = 180
            $script:SnapshotLayoutTimer.Add_Tick({
                $script:SnapshotLayoutTimer.Stop()
                if ($script:CurrentPage -eq 'Snapshots') { Refresh-StudioSnapshotRows }
            })
        }
        $script:SnapshotLayoutTimer.Stop()
        $script:SnapshotLayoutTimer.Start()
    }
}

function Layout-StudioPage {
    param([string]$Name)
    switch ($Name) {
        'Dashboard' { Layout-StudioDashboard }
        'Snapshots' { Layout-StudioSnapshots }
        'Exclusions' { Layout-StudioExclusions }
        'RecoveryKit' { Layout-StudioRecoveryKit }
        'Settings' { Layout-StudioSettings }
        'Diagnostics' { Layout-StudioDiagnostics }
        'About' { Layout-StudioAbout }
    }
}

function Layout-Studio {
    if (-not $script:UiReady) { return }
    $pageSize = $script:PageHost.ClientSize
    $current = $script:CurrentPage
    if ($script:Pages.Contains($current) -and $pageSize.Width -gt 0) {
        $script:Pages[$current].Size = $pageSize
    }
    Layout-StudioSidebar
    Layout-StudioHeader
    if ($script:Pages.Contains($current)) { Layout-StudioPage -Name $current }
}

function Show-StudioPage {
    param([string]$Name, [switch]$Force)
    if (-not $script:Pages.Contains($Name)) { $Name = 'Dashboard' }
    if (-not $Force -and $Name -eq $script:CurrentPage -and $script:PageLoaded.ContainsKey($Name)) { return }

    $previous = $script:CurrentPage
    $script:CurrentPage = $Name
    $target = $script:Pages[$Name]
    $script:PageHost.SuspendLayout()
    try {
        if ($previous -ne $Name -and $script:Pages.Contains($previous)) {
            $script:Pages[$previous].Visible = $false
        }
        foreach ($key in @($script:NavButtons.Keys)) {
            $script:NavButtons[$key].Selected = ($key -eq $Name)
        }
        switch ($Name) {
            'Dashboard' {
                $pageTitle.Text = 'Dashboard'
                $pageSubtitle.Text = 'Your session, exactly as you left it.'
            }
            'Snapshots' {
                $pageTitle.Text = 'Snapshots'
                $pageSubtitle.Text = 'A timeline of everything Session Recovery has saved.'
            }
            'Exclusions' {
                $pageTitle.Text = 'Exclusions'
                $pageSubtitle.Text = 'Keep private or noisy windows out of your snapshots.'
            }
            'RecoveryKit' {
                $pageTitle.Text = 'Recovery Kit'
                $pageSubtitle.Text = 'Move snapshots, notes and exclusion rules between PCs.'
            }
            'Settings' {
                $pageTitle.Text = 'Settings'
                $pageSubtitle.Text = 'Tune capture, restore, startup and storage.'
            }
            'Diagnostics' {
                $pageTitle.Text = 'Diagnostics'
                $pageSubtitle.Text = 'Local health checks and recent activity.'
            }
            'About' {
                $pageTitle.Text = 'About'
                $pageSubtitle.Text = 'Local, fast and private by design.'
            }
        }
        $captureButton.Visible = ($Name -eq 'Dashboard' -or $Name -eq 'Snapshots')
        $refreshButton.Visible = ($Name -eq 'Diagnostics')
        Layout-StudioHeader
        $pageTitle.Text = [string](Localize-StudioString $pageTitle.Text)
        $pageSubtitle.Text = [string](Localize-StudioString $pageSubtitle.Text)
        if ($script:PageHost.ClientSize.Width -gt 0) {
            $target.Size = $script:PageHost.ClientSize
        }
        $target.Visible = $true
        Layout-StudioPage -Name $Name
        $target.BringToFront()
    } finally {
        $script:PageHost.ResumeLayout($true)
        $script:PageHost.Invalidate()
    }

    $firstShow = -not $script:PageLoaded.ContainsKey($Name)
    switch ($Name) {
        'Dashboard' { if ($firstShow -or $script:DashboardDirty) { Refresh-StudioDashboard } }
        'Snapshots' { if ($firstShow -or $script:SnapshotsDirty) { Refresh-StudioSnapshotRows } }
        'Exclusions' { if ($firstShow -or $script:ExclusionsDirty) { Refresh-StudioExclusions } }
        'RecoveryKit' { if ($firstShow) { Update-StudioKitSummary } }
        'Settings' { if (-not $script:SettingsLoaded) { Load-StudioSettings } }
        'Diagnostics' { if ($firstShow -or $script:DiagnosticsDirty) { Start-StudioDiagnosticsRefresh } }
    }
    if ($firstShow) {
        # WinForms can scroll a fresh AutoScroll panel to the last control
        # that was added or focused. Reset after the page's own loading code so
        # the first card is always the one users see when they open the page.
        foreach ($scrollFlow in @($script:Ui.SettingsFlow, $script:Ui.DiagFlow, $script:Ui.AboutFlow, $script:Ui.KitFlow)) {
            if ($null -ne $scrollFlow) {
                $scrollFlow.AutoScrollPosition = New-Object System.Drawing.Point(0, 0)
            }
        }
    }
    $script:PageLoaded[$Name] = $true
}

function Test-StudioLayout {
    # Deterministic layout audit for the render mode: overlapping visible text
    # controls, and fixed-height labels whose text would wrap or clip instead
    # of ellipsizing. Catches the "long translation runs into the next
    # control" class of bug in every language without human review.
    param($Root, [string]$Page, [string]$ReportPath)
    $issues = New-Object System.Collections.Generic.List[string]
    $textual = New-Object System.Collections.Generic.List[object]
    $textTypeNames = @(
        'System.Windows.Forms.Label', 'System.Windows.Forms.Button', 'System.Windows.Forms.CheckBox',
        'System.Windows.Forms.TextBox', 'System.Windows.Forms.NumericUpDown', 'System.Windows.Forms.ComboBox',
        'SessionRecovery.Studio.StudioBadge', 'SessionRecovery.Studio.StudioButton',
        'SessionRecovery.Studio.StudioToggle', 'SessionRecovery.Studio.StudioNavButton',
        'SessionRecovery.Studio.StudioStatCard', 'SessionRecovery.Studio.StudioRing'
    )

    $stack = New-Object System.Collections.Stack
    $stack.Push($Root)
    $parents = @{}
    while ($stack.Count -gt 0) {
        $current = $stack.Pop()
        foreach ($child in @($current.Controls)) {
            if ($null -eq $child) { continue }
            $parents[$child] = $current
            if ($child.Visible) { $stack.Push($child) }
        }
        $typeName = $current.GetType().FullName
        if ($textTypeNames -contains $typeName) {
            $text = ''
            try { $text = [string]$current.Text } catch { }
            if (-not [string]::IsNullOrWhiteSpace($text) -or $typeName -like '*TextBox*' -or $typeName -like '*NumericUpDown*' -or $typeName -like '*ComboBox*' -or $typeName -like '*StatCard*' -or $typeName -like '*Ring*') {
                $screenRect = $current.RectangleToScreen($current.ClientRectangle)
                $formRect = $Root.RectangleToClient($screenRect)
                # Controls scrolled out of an AutoScroll panel are clipped by
                # the panel and not visible; auditing them reports phantom
                # overlaps with neighbouring pages and bars.
                $scrollClipped = $false
                $walk = $current
                while ($parents.ContainsKey($walk)) {
                    $ancestor = $parents[$walk]
                    try {
                        if ($ancestor.AutoScroll) {
                            $ancestorRect = $Root.RectangleToClient($ancestor.RectangleToScreen($ancestor.ClientRectangle))
                            if ($formRect.Bottom -gt ($ancestorRect.Bottom + 4) -or $formRect.Right -gt ($ancestorRect.Right + 4) -or
                                $formRect.Top -lt ($ancestorRect.Top - 4) -or $formRect.Left -lt ($ancestorRect.Left - 4)) {
                                $scrollClipped = $true
                                break
                            }
                        }
                    } catch { }
                    $walk = $ancestor
                }
                if (-not $scrollClipped) {
                    $textual.Add([pscustomobject]@{
                        Control = $current
                        Type    = $typeName
                        Text    = $text
                        Rect    = $formRect
                    })
                }
            }
        }
    }

    for ($outer = 0; $outer -lt $textual.Count; $outer++) {
        for ($inner = $outer + 1; $inner -lt $textual.Count; $inner++) {
            $a = $textual[$outer]
            $b = $textual[$inner]
            # Skip ancestor/descendant pairs (a label inside a button-hosting
            # panel is normal containment, not overlap).
            $walk = $a.Control
            $contained = $false
            while ($null -ne $walk) {
                if ($walk -eq $b.Control) { $contained = $true; break }
                if ($parents.ContainsKey($walk)) { $walk = $parents[$walk] } else { break }
            }
            if (-not $contained) {
                $walk = $b.Control
                while ($null -ne $walk) {
                    if ($walk -eq $a.Control) { $contained = $true; break }
                    if ($parents.ContainsKey($walk)) { $walk = $parents[$walk] } else { break }
                }
            }
            if ($contained) { continue }
            $r1 = $a.Rect; $r2 = $b.Rect
            $overlapWidth = [Math]::Min($r1.Right, $r2.Right) - [Math]::Max($r1.X, $r2.X)
            $overlapHeight = [Math]::Min($r1.Bottom, $r2.Bottom) - [Math]::Max($r1.Y, $r2.Y)
            if ($overlapWidth -gt 2 -and $overlapHeight -gt 2) {
                $issues.Add(('OVERLAP  [{0}] "{1}" {2}  <->  [{3}] "{4}" {5}' -f $a.Type, ($a.Text -replace "`r`n", ' '), $r1, $b.Type, ($b.Text -replace "`r`n", ' '), $r2))
            }
        }
    }

    $singleLine = [System.Windows.Forms.TextFormatFlags]::SingleLine -bor [System.Windows.Forms.TextFormatFlags]::NoPadding
    $wordBreak = [System.Windows.Forms.TextFormatFlags]::WordBreak -bor [System.Windows.Forms.TextFormatFlags]::NoPadding
    foreach ($entry in $textual) {
        if ([string]::IsNullOrWhiteSpace($entry.Text) -and $entry.Type -notin @('SessionRecovery.Studio.StudioStatCard', 'SessionRecovery.Studio.StudioRing')) { continue }
        $control = $entry.Control
        $flatText = ($entry.Text -replace "`r`n", ' ')
        try {
            if ($entry.Type -eq 'System.Windows.Forms.Label') {
                if ($control.AutoSize) { continue }
                $lineHeight = [System.Windows.Forms.TextRenderer]::MeasureText('Ag', $control.Font, (New-Object System.Drawing.Size([int]::MaxValue, [int]::MaxValue)), $singleLine).Height
                if ($control.Height -le ($lineHeight + 8)) {
                    $measured = [System.Windows.Forms.TextRenderer]::MeasureText($entry.Text, $control.Font, (New-Object System.Drawing.Size([int]::MaxValue, $control.ClientSize.Height)), $singleLine)
                    if ($measured.Width -gt ($control.ClientSize.Width + 2)) {
                        $hint = if ($control.AutoEllipsis) { 'ellipsized' } else { 'no ellipsis' }
                        $issues.Add(('TRUNCATED [{0}] "{1}" needs {2}px, box {3}px wide ({4})' -f $entry.Type, $flatText, $measured.Width, $control.ClientSize.Width, $hint))
                    }
                } else {
                    # MeasureText includes internal leading; large single-line
                    # titles measure a few pixels taller than they render. Scale
                    # the tolerance with the font so only real clipping reports.
                    $measured = [System.Windows.Forms.TextRenderer]::MeasureText($entry.Text, $control.Font, (New-Object System.Drawing.Size([Math]::Max(1, $control.ClientSize.Width), [int]::MaxValue)), $wordBreak)
                    $tolerance = 3 + [int]($control.Font.Size * 0.25)
                    if ($measured.Height -gt ($control.ClientSize.Height + $tolerance)) {
                        $issues.Add(('CLIPPED   [{0}] "{1}" needs {2}px height, box {3}px' -f $entry.Type, $flatText, $measured.Height, $control.ClientSize.Height))
                    }
                }
            } elseif ($entry.Type -eq 'SessionRecovery.Studio.StudioButton' -or $entry.Type -eq 'System.Windows.Forms.Button' -or $entry.Type -eq 'SessionRecovery.Studio.StudioNavButton') {
                $glyphRoom = 0
                if ($entry.Type -eq 'SessionRecovery.Studio.StudioButton') {
                    if (-not [string]::IsNullOrEmpty([string]$control.Glyph)) { $glyphRoom = 34 }
                } elseif ($entry.Type -eq 'SessionRecovery.Studio.StudioNavButton') {
                    $glyphRoom = 46
                } else {
                    $glyphRoom = 8
                }
                $available = $control.Width - $glyphRoom - 6
                if ($available -gt 0) {
                    $measured = [System.Windows.Forms.TextRenderer]::MeasureText($entry.Text, $control.Font, (New-Object System.Drawing.Size([int]::MaxValue, $control.ClientSize.Height)), $singleLine)
                    if ($measured.Width -gt ($available + 2)) {
                        $issues.Add(('BUTTON    [{0}] "{1}" needs {2}px, available {3}px in {4}px button' -f $entry.Type, $flatText, $measured.Width, $available, $control.Width))
                    }
                }
            } elseif ($entry.Type -eq 'SessionRecovery.Studio.StudioRing') {
                # Ring captions are painted, not labels. They wrap onto two
                # lines, so audit the real caption rectangle in every language.
                $caption = [string]$control.Caption
                if ([string]::IsNullOrWhiteSpace($caption)) { continue }
                $ringSize = [Math]::Min($control.Width, $control.Height)
                $captionWidth = [Math]::Max(1, $ringSize - [int]$control.Thickness - 4)
                $captionFont = New-Object System.Drawing.Font('Segoe UI', 7.5)
                $upper = $caption.ToUpperInvariant()
                $measured = [System.Windows.Forms.TextRenderer]::MeasureText($upper, $captionFont, (New-Object System.Drawing.Size($captionWidth, [int]::MaxValue)), $wordBreak)
                $single = [System.Windows.Forms.TextRenderer]::MeasureText($upper, $captionFont, (New-Object System.Drawing.Size([int]::MaxValue, 18)), $singleLine)
                if ($measured.Height -gt 32) {
                    $issues.Add(('RING      [{0}] "{1}" needs {2}px height, box 30px' -f $entry.Type, $upper, $measured.Height))
                } elseif (($single.Width -gt ($captionWidth + 2)) -and ($upper -notmatch '\s')) {
                    $issues.Add(('RING      [{0}] "{1}" needs {2}px wide, box {3}px' -f $entry.Type, $upper, $single.Width, $captionWidth))
                }
            } elseif ($entry.Type -eq 'SessionRecovery.Studio.StudioStatCard') {
                # StudioStatCard paints its own title/value/detail strings.
                # Titles and details wrap onto a second line, so verify the
                # real paint rectangles fit instead of letting long
                # translations disappear behind an ellipsis.
                $checks = @(
                    @{ Name = 'title'; Text = [string]$control.Title; Font = (New-Object System.Drawing.Font('Segoe UI', 8)); Width = [Math]::Max(1, $control.Width - 70); Height = 30; Wrap = $true; Upper = $true },
                    @{ Name = 'value'; Text = [string]$control.Value; Font = (New-Object System.Drawing.Font('Segoe UI Semibold', 20)); Width = [Math]::Max(1, $control.Width - 72); Height = 34; Wrap = $false; Upper = $false },
                    @{ Name = 'detail'; Text = [string]$control.Detail; Font = (New-Object System.Drawing.Font('Segoe UI', 8.25)); Width = [Math]::Max(1, $control.Width - 36); Height = 36; Wrap = $true; Upper = $false }
                )
                foreach ($check in $checks) {
                    if ([string]::IsNullOrWhiteSpace($check.Text)) { continue }
                    $text = if ($check.Upper) { $check.Text.ToUpperInvariant() } else { $check.Text }
                    if ($check.Wrap) {
                        $measured = [System.Windows.Forms.TextRenderer]::MeasureText($text, $check.Font, (New-Object System.Drawing.Size($check.Width, [int]::MaxValue)), $wordBreak)
                        $single = [System.Windows.Forms.TextRenderer]::MeasureText($text, $check.Font, (New-Object System.Drawing.Size([int]::MaxValue, 18)), $singleLine)
                        if ($measured.Height -gt ($check.Height + 2)) {
                            $issues.Add(('STATCARD  [{0}] {1} "{2}" needs {3}px height, box {4}px' -f $entry.Type, $check.Name, ($text -replace "`r`n", ' '), $measured.Height, $check.Height))
                        } elseif (($single.Width -gt ($check.Width + 2)) -and ($text -notmatch '\s')) {
                            # A single word cannot wrap; report the horizontal overflow.
                            $issues.Add(('STATCARD  [{0}] {1} "{2}" needs {3}px wide, box {4}px' -f $entry.Type, $check.Name, ($text -replace "`r`n", ' '), $single.Width, $check.Width))
                        }
                    } else {
                        $measured = [System.Windows.Forms.TextRenderer]::MeasureText($text, $check.Font, (New-Object System.Drawing.Size([int]::MaxValue, $check.Height)), $singleLine)
                        if ($measured.Width -gt ($check.Width + 2)) {
                            $issues.Add(('STATCARD  [{0}] {1} "{2}" needs {3}px wide, box {4}px' -f $entry.Type, $check.Name, ($text -replace "`r`n", ' '), $measured.Width, $check.Width))
                        }
                    }
                }
            }
        } catch { }
    }

    $lines = @()
    $lines += ('Studio layout audit: {0}  ({1} controls checked)' -f $Page, $textual.Count)
    if ($issues.Count -eq 0) {
        $lines += 'OK: no overlapping controls, no clipped labels.'
    } else {
        $lines += ('{0} issue(s):' -f $issues.Count)
        $lines += $issues
    }
    [System.IO.File]::WriteAllLines($ReportPath, $lines)
    Write-Output ($lines -join "`r`n")
}

function Wait-StudioRenderPump {
    param(
        [int]$Milliseconds = 350,
        [scriptblock]$Until = $null,
        [int]$TimeoutMilliseconds = 9000
    )
    $elapsed = 0
    while ($elapsed -lt [Math]::Max(0, $Milliseconds)) {
        [System.Windows.Forms.Application]::DoEvents()
        try { Update-StudioWorkers } catch { }
        Start-Sleep -Milliseconds 40
        $elapsed += 40
    }
    if ($null -ne $Until) {
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        while ($watch.ElapsedMilliseconds -lt $TimeoutMilliseconds) {
            [System.Windows.Forms.Application]::DoEvents()
            try { Update-StudioWorkers } catch { }
            $done = $false
            try { $done = [bool](& $Until) } catch { $done = $true }
            if ($done) { break }
            Start-Sleep -Milliseconds 40
        }
    }
}

$form.Add_ResizeBegin({
    if ($script:UiReady -and -not $script:RenderMode) {
        $script:FormResizing = $true
        $form.SuspendLayout()
    }
})
$form.Add_ResizeEnd({
    if ($script:FormResizing) {
        $script:FormResizing = $false
        try { $form.ResumeLayout($true) } catch { }
        Layout-Studio
        $form.Invalidate($true)
    }
})
$form.Add_Resize({
    if ($script:UiReady -and -not $script:FormResizing) { Layout-Studio }
})
$form.Add_KeyDown({
    param($sender, $eventArgs)
    if ($eventArgs.Control -and $eventArgs.KeyCode -eq [System.Windows.Forms.Keys]::S -and $script:CurrentPage -eq 'Settings') {
        Save-StudioSettings
        $eventArgs.SuppressKeyPress = $true
    } elseif ($eventArgs.KeyCode -eq [System.Windows.Forms.Keys]::F5) {
        Refresh-StudioData
        if ($script:CurrentPage -eq 'Diagnostics') { Refresh-StudioDiagnostics }
        $eventArgs.SuppressKeyPress = $true
    } elseif ($eventArgs.Control) {
        $map = @{
            'D1' = 'Dashboard'; 'D2' = 'Snapshots'; 'D3' = 'Exclusions';
            'D4' = 'Settings'; 'D5' = 'Diagnostics'; 'D6' = 'About'; 'D7' = 'RecoveryKit'
        }
        $keyName = [string]$eventArgs.KeyCode
        if ($map.ContainsKey($keyName)) {
            Show-StudioPage -Name $map[$keyName]
            $eventArgs.SuppressKeyPress = $true
        }
    }
})

$statusTimer = New-Object System.Windows.Forms.Timer
$statusTimer.Interval = 10000
$statusTimer.Add_Tick({
    if (-not $script:UiReady) { return }
    try {
        Refresh-StudioSidebar
        if ($script:CurrentPage -eq 'Dashboard') {
            $script:Ui.HeroNext.Text = ((T 'NextSnapshot' 'Next automatic snapshot') + '  •  ' + (Format-StudioNext))
        }
    } catch { }
})
$script:StatusTimer = $statusTimer

$studioTaskTimer = New-Object System.Windows.Forms.Timer
$studioTaskTimer.Interval = 200
$studioTaskTimer.Add_Tick({
    if (-not $script:UiReady) { return }
    Update-StudioWorkers
})
$script:StudioTaskTimer = $studioTaskTimer

$form.Add_Shown({
    $script:UiReady = $true
    Layout-Studio
    Refresh-StudioData
    Show-StudioPage -Name $Page
    $statusTimer.Start()
    $studioTaskTimer.Start()
})
$form.Add_FormClosing({
    try { $statusTimer.Stop(); $statusTimer.Dispose() } catch { }
    if ($script:StudioTaskTimer) { try { $script:StudioTaskTimer.Stop(); $script:StudioTaskTimer.Dispose() } catch { } }
    foreach ($workerName in @($script:StudioJobs.Keys)) { Stop-StudioWorker -Name $workerName }
    if ($script:DiagLoadingTimer) { try { $script:DiagLoadingTimer.Stop(); $script:DiagLoadingTimer.Dispose() } catch { } }
    if ($script:SharedWorkerRunspace) {
        try { $script:SharedWorkerRunspace.Close(); $script:SharedWorkerRunspace.Dispose() } catch { }
        $script:SharedWorkerRunspace = $null
    }
    if ($script:SnapshotBuildTimer) { try { $script:SnapshotBuildTimer.Stop(); $script:SnapshotBuildTimer.Dispose() } catch { } }
    if ($script:SnapshotDetailsTimer) { try { $script:SnapshotDetailsTimer.Stop(); $script:SnapshotDetailsTimer.Dispose() } catch { } }
    if ($script:SnapshotLayoutTimer) { try { $script:SnapshotLayoutTimer.Stop(); $script:SnapshotLayoutTimer.Dispose() } catch { } }
    if ($script:ToastTimer) { try { $script:ToastTimer.Stop(); $script:ToastTimer.Dispose() } catch { } }
    if ($script:CapturePollTimer) { try { $script:CapturePollTimer.Stop(); $script:CapturePollTimer.Dispose() } catch { } }
})

# One pass over the finished tree removes flicker from the panels that do not
# opt into double buffering themselves.
Enable-StudioDoubleBufferTree -Control $form

# Translate the built UI once and mirror it for right-to-left languages.
Initialize-StudioLanguage -Language $studioLanguage -Root $form

if (-not [string]::IsNullOrWhiteSpace($RenderDir)) {
    $script:RenderMode = $true
    $form.ShowInTaskbar = $false
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $form.Location = New-Object System.Drawing.Point(-4000, -4000)
    # Optional render-time client size (WxH) for layout testing at other
    # window sizes, for example a maximized 1366x768 screen.
    if (-not [string]::IsNullOrWhiteSpace($env:SESSIONRECOVERY_RENDER_SIZE)) {
        try {
            $parts = ([string]$env:SESSIONRECOVERY_RENDER_SIZE).Split('x')
            $form.ClientSize = New-Object System.Drawing.Size([int]$parts[0], [int]$parts[1])
        } catch { }
    }
    $form.Show()
    $script:UiReady = $true
    Layout-Studio
    Refresh-StudioData
    # Optional: exercise the live theme switch used by the Settings page.
    if (-not [string]::IsNullOrWhiteSpace($env:SESSIONRECOVERY_RENDER_THEME)) {
        [void](Apply-StudioTheme -Theme ([string]$env:SESSIONRECOVERY_RENDER_THEME) -Root $form)
    }
    [System.Windows.Forms.Application]::DoEvents()
    if (-not (Test-Path -LiteralPath $RenderDir)) { New-Item -ItemType Directory -Path $RenderDir -Force | Out-Null }
    # Longer waits let background workers (diagnostics) finish before the
    # page is captured. Default keeps the old ~600 ms behaviour.
    $renderWaitMs = 600
    try {
        if (-not [string]::IsNullOrWhiteSpace($env:SESSIONRECOVERY_RENDER_MS)) {
            $renderWaitMs = [Math]::Max(100, [int]$env:SESSIONRECOVERY_RENDER_MS)
        }
    } catch { }
    foreach ($renderPage in @('Dashboard', 'Snapshots', 'Exclusions', 'RecoveryKit', 'Settings', 'Diagnostics', 'About')) {
        Show-StudioPage -Name $renderPage
        # The diagnostics page fills in from a background worker. Pump the
        # worker queue and wait for the loaded state so the audit covers the
        # real labels, not the temporary "Checking..." placeholders.
        if ($renderPage -eq 'Diagnostics') {
            Wait-StudioRenderPump -Milliseconds $renderWaitMs -Until { -not $script:DiagnosticsLoading } -TimeoutMilliseconds 20000
        } else {
            Wait-StudioRenderPump -Milliseconds $renderWaitMs
        }
        # Optional: audit the lower half of long pages. The default capture
        # only shows the first cards, so Settings/About/Diagnostics are also
        # rendered scrolled to the bottom into a separate output folder.
        if ([string]$env:SESSIONRECOVERY_RENDER_SCROLL -eq 'bottom') {
            $scrollFlow = switch ($renderPage) {
                'Settings' { $script:Ui.SettingsFlow }
                'RecoveryKit' { $script:Ui.KitFlow }
                'Diagnostics' { $script:Ui.DiagFlow }
                'About' { $script:Ui.AboutFlow }
                default { $null }
            }
            if ($null -ne $scrollFlow) {
                # Scroll by a large offset and let WinForms clamp to the real
                # maximum, then repeat after pending layout so a late resize
                # cannot leave the capture short of the true bottom.
                for ($attempt = 0; $attempt -lt 3; $attempt++) {
                    $scrollFlow.AutoScrollPosition = New-Object System.Drawing.Point(0, 1000000)
                    [System.Windows.Forms.Application]::DoEvents()
                    Start-Sleep -Milliseconds 80
                    [System.Windows.Forms.Application]::DoEvents()
                }
            }
        }
        $bitmap = New-Object System.Drawing.Bitmap($form.ClientSize.Width, $form.ClientSize.Height)
        $rect = New-Object System.Drawing.Rectangle(0, 0, $bitmap.Width, $bitmap.Height)
        $form.DrawToBitmap($bitmap, $rect)
        $renderPath = Join-Path $RenderDir ($renderPage + '.png')
        $bitmap.Save($renderPath, [System.Drawing.Imaging.ImageFormat]::Png)
        $bitmap.Dispose()
        if (-not [string]::IsNullOrWhiteSpace($env:SESSIONRECOVERY_RENDER_CHECK)) {
            # Deterministic layout audit: overlapping visible text controls,
            # truncated labels/buttons and wrapped text that no longer fits.
            $reportPath = Join-Path $RenderDir ($renderPage + '.check.txt')
            Test-StudioLayout -Root $form -Page $renderPage -ReportPath $reportPath
        }
        if (-not [string]::IsNullOrWhiteSpace($env:SESSIONRECOVERY_RENDER_TREE)) {
            $treePath = Join-Path $RenderDir ($renderPage + '.tree.txt')
            $treeLines = New-Object System.Collections.Generic.List[string]
            $treeStack = New-Object System.Collections.Stack
            $treeStack.Push(@($form, 0))
            while ($treeStack.Count -gt 0) {
                $item = $treeStack.Pop()
                $node = $item[0]
                $depth = [int]$item[1]
                try {
                    $screenRect = $node.RectangleToScreen($node.ClientRectangle)
                    $localRect = $form.RectangleToClient($screenRect)
                } catch { $localRect = New-Object System.Drawing.Rectangle(0, 0, 0, 0) }
                $nodeText = ''
                $textProperty = $node.PSObject.Properties['Text']
                if ($null -ne $textProperty) { $nodeText = ([string]$textProperty.Value -replace "`r`n", ' ') }
                $treeLines.Add(('{0}{1} visible={2} bounds={3} text="{4}"' -f ('  ' * $depth), $node.GetType().FullName, $node.Visible, $localRect, $nodeText))
                foreach ($child in @($node.Controls)) {
                    if ($null -ne $child) { $treeStack.Push(@($child, $depth + 1)) }
                }
            }
            [System.IO.File]::WriteAllLines($treePath, $treeLines)
        }
    }
    $form.Close()
    $form.Dispose()
    return
}
[void]$form.ShowDialog()
$form.Dispose()
