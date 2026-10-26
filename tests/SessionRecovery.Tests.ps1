#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
    SessionRecovery.Tests.ps1
    Pester tests for the Session Recovery module. Everything here is hermetic:
    an isolated SESSIONRECOVERY_HOME keeps real user data out of the tests.

    Run:  Invoke-Pester -Path tests -Output Detailed
#>

# The temp home travels through the environment (not $script: variables) so
# the file behaves the same under Pester 5 and 6 scope rules.
$env:SR_TEST_HOME = Join-Path ([System.IO.Path]::GetTempPath()) ('sr-tests-' + [guid]::NewGuid().ToString('N'))

BeforeAll {
    $env:SESSIONRECOVERY_HOME = $env:SR_TEST_HOME
    New-Item -ItemType Directory -Path $env:SESSIONRECOVERY_HOME -Force | Out-Null

    $modulePath = Join-Path $PSScriptRoot '..\src\SessionRecovery.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop
    . (Join-Path $PSScriptRoot '..\src\Strings.ps1')
}

AfterAll {
    try {
        if (Get-Module SessionRecovery -ErrorAction SilentlyContinue) {
            Remove-Module SessionRecovery -Force -ErrorAction SilentlyContinue
        }
    } catch { }
    try { Remove-Item -LiteralPath $env:SR_TEST_HOME -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}

# ---------------------------------------------------------------------------
# Localization
# ---------------------------------------------------------------------------

Describe 'String tables' {
    It 'returns the master table for English' {
        $strings = Get-SRStrings -Language 'en'
        $strings.NavDashboard | Should -Be 'Dashboard'
    }

    It 'has every master key in every supported language' {
        $english = Get-SRStrings -Language 'en'
        foreach ($language in @('ar', 'fr', 'es', 'de', 'pt', 'ru', 'zh', 'tr')) {
            $strings = Get-SRStrings -Language $language
            foreach ($key in $english.Keys) {
                $strings[$key] | Should -Not -BeNullOrEmpty -Because "$language should translate '$key'"
            }
        }
    }

    It 'exposes the 2.6 privacy keys in every language' {
        foreach ($language in @('en', 'ar', 'fr', 'es', 'de', 'pt', 'ru', 'zh', 'tr')) {
            $strings = Get-SRStrings -Language $language
            $strings['SetEncrypt'] | Should -Not -BeNullOrEmpty
            $strings['EncryptHint'] | Should -Not -BeNullOrEmpty
            $strings['SetVDesk'] | Should -Not -BeNullOrEmpty
            $strings['VDeskHint'] | Should -Not -BeNullOrEmpty
        }
    }

    It 'falls back to English for unknown languages' {
        $strings = Get-SRStrings -Language 'xx'
        $strings.NavDashboard | Should -Be 'Dashboard'
    }

    It 'detects right-to-left languages' {
        Test-SRRtlLanguage -Language 'ar' | Should -BeTrue
        Test-SRRtlLanguage -Language 'he' | Should -BeTrue
        Test-SRRtlLanguage -Language 'en' | Should -BeFalse
        Test-SRRtlLanguage -Language 'fr' | Should -BeFalse
    }
}

# ---------------------------------------------------------------------------
# Pure helpers
# ---------------------------------------------------------------------------

Describe 'Redact-SRUrl' {
    It 'strips query strings and fragments' {
        Redact-SRUrl 'https://example.com/page?token=secret#frag' | Should -Be 'https://example.com/page'
    }

    It 'keeps clean URLs untouched' {
        Redact-SRUrl 'https://example.com/page' | Should -Be 'https://example.com/page'
    }

    It 'survives empty input' {
        Redact-SRUrl '' | Should -Be ''
    }
}

Describe 'ConvertFrom-SRFileUri' {
    It 'converts local drive file URIs' {
        ConvertFrom-SRFileUri 'file:///c%3A/Users/x' | Should -Be 'C:\Users\x'
    }

    It 'converts UNC file URIs' {
        ConvertFrom-SRFileUri 'file://server/share/folder' | Should -Be '\\server\share\folder'
    }

    It 'passes plain paths through' {
        ConvertFrom-SRFileUri 'C:\plain\path' | Should -Be 'C:\plain\path'
    }
}

Describe 'ConvertTo-SRVersion' {
    It 'parses release tags with a v prefix' {
        (ConvertTo-SRVersion 'v2.10.3') -as [version] | Should -Be '2.10.3'
    }

    It 'returns null for garbage' {
        ConvertTo-SRVersion 'not-a-version' | Should -BeNullOrEmpty
    }
}

Describe 'Test-SRPatternMatch' {
    It 'matches wildcards case-insensitively' {
        Test-SRPatternMatch -Patterns @('*game*') -Values @('MyGame.exe') | Should -BeTrue
    }

    It 'returns false when nothing matches' {
        Test-SRPatternMatch -Patterns @('steam.exe') -Values @('vlc.exe') | Should -BeFalse
    }
}

# ---------------------------------------------------------------------------
# Snapshot compare and restore preview
# ---------------------------------------------------------------------------

Describe 'Compare-SRSnapshot' {
    BeforeAll {
        $script:reference = [pscustomobject]@{
            apps          = @(
                [pscustomobject]@{ displayName = 'Code'; name = 'code'; exe = 'code.exe' },
                [pscustomobject]@{ displayName = 'VLC'; name = 'vlc'; exe = 'vlc.exe' }
            )
            explorer      = @('C:\Work')
            browsers      = @(
                [pscustomobject]@{ profiles = @(
                    [pscustomobject]@{ tabs = @(
                        [pscustomobject]@{ url = 'https://a.example/'; title = 'A' }
                    ) }
                ) }
            )
            devWorkspaces = @()
        }
        $script:difference = [pscustomobject]@{
            apps          = @(
                [pscustomobject]@{ displayName = 'Code'; name = 'code'; exe = 'code.exe' },
                [pscustomobject]@{ displayName = 'Notepad'; name = 'notepad'; exe = 'notepad.exe' }
            )
            explorer      = @('C:\Work', 'C:\Temp')
            browsers      = @(
                [pscustomobject]@{ profiles = @(
                    [pscustomobject]@{ tabs = @(
                        [pscustomobject]@{ url = 'https://a.example/'; title = 'A' },
                        [pscustomobject]@{ url = 'https://b.example/'; title = 'B' }
                    ) }
                ) }
            )
            devWorkspaces = @()
        }
    }

    It 'reports added and removed apps' {
        $diff = Compare-SRSnapshot -Reference $script:reference -Difference $script:difference
        $diff.AppsAdded | Should -Contain 'Notepad'
        $diff.AppsRemoved | Should -Contain 'VLC'
    }

    It 'reports added and removed folders' {
        $diff = Compare-SRSnapshot -Reference $script:reference -Difference $script:difference
        $diff.FoldersAdded | Should -Contain 'C:\Temp'
        $diff.FoldersRemoved | Should -BeNullOrEmpty
    }

    It 'reports added and removed tabs' {
        $diff = Compare-SRSnapshot -Reference $script:reference -Difference $script:difference
        $diff.TabsAdded | Should -Contain 'https://b.example/'
        $diff.TabsRemoved | Should -BeNullOrEmpty
    }

    It 'reports nothing for identical snapshots' {
        $diff = Compare-SRSnapshot -Reference $script:reference -Difference $script:reference
        $diff.AppsAdded | Should -BeNullOrEmpty
        $diff.AppsRemoved | Should -BeNullOrEmpty
        $diff.TabsAdded | Should -BeNullOrEmpty
    }
}

Describe 'Get-SRRestorePreview' {
    It 'classifies apps into running, will-start and missing' {
        # explorer.exe always exists and is always running on Windows.
        $runningExe = (Get-Process -Name explorer | Select-Object -First 1).Path
        $plan = [pscustomobject]@{
            apps     = @(
                [pscustomobject]@{ name = 'explorer'; exe = $runningExe },
                [pscustomobject]@{ name = 'calc-missing'; exe = 'Z:\nowhere\missing.exe' }
            )
            explorer = @()
            browsers = @()
        }
        $preview = Get-SRRestorePreview -Plan $plan
        $preview.Running | Should -Be 1
        $preview.Missing | Should -Be 1
        $preview.Rows | Where-Object { $_.Name -eq 'explorer' } | Select-Object -ExpandProperty State | Should -Be 'running'
    }
}

# ---------------------------------------------------------------------------
# Monitor mapping
# ---------------------------------------------------------------------------

Describe 'ConvertTo-SRScreenPlacement' {
    BeforeAll {
        # A single virtual screen standing in for "current" layout.
        $script:placement = [pscustomobject]@{ X = 2000; Y = 100; Width = 800; Height = 600; Maximized = $false }
    }

    It 'keeps coordinates when the monitor still exists' {
        $current = @(Get-SRMonitors)
        if ($current.Count -eq 0) { Set-ItResult -Skipped -Because 'no screen API available'; return }
        $snapshot = @([pscustomobject]@{ device = $current[0].device; x = $current[0].x; y = $current[0].y; width = $current[0].width; height = $current[0].height; primary = $true })
        $mapped = ConvertTo-SRScreenPlacement -Placement ([pscustomobject]@{ X = $current[0].x + 50; Y = $current[0].y + 50; Width = 400; Height = 300; Maximized = $false }) -SnapshotMonitors $snapshot
        $mapped.X | Should -Be ($current[0].x + 50)
    }

    It 'maps windows from a missing monitor onto the current layout' {
        $current = @(Get-SRMonitors)
        if ($current.Count -eq 0) { Set-ItResult -Skipped -Because 'no screen API available'; return }
        $target = @($current | Where-Object { $_.primary } | Select-Object -First 1)
        if ($target.Count -eq 0) { $target = @($current[0]) }
        $gone = [pscustomobject]@{ device = '\\.\DISPLAY_GONE'; x = 5000; y = 0; width = 1920; height = 1080; primary = $false }
        # Window centered on the missing monitor.
        $mapped = ConvertTo-SRScreenPlacement -Placement ([pscustomobject]@{ X = 5360; Y = 440; Width = 800; Height = 200; Maximized = $false }) -SnapshotMonitors @($gone)
        # Plain comparisons keep this working on every Pester major version.
        ($mapped.X -ge [int]$target[0].x) | Should -BeTrue
        ($mapped.X -le ([int]$target[0].x + [int]$target[0].width - 800)) | Should -BeTrue
        ($mapped.Y -ge [int]$target[0].y) | Should -BeTrue
    }
}

# ---------------------------------------------------------------------------
# Encryption and storage round-trip
# ---------------------------------------------------------------------------

Describe 'Snapshot storage round-trip' {
    It 'protects and unprotects bytes symmetrically' {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes('{"hello":"world"}')
        $protected = Protect-SRSnapshotBytes -Bytes $bytes
        [System.Text.Encoding]::ASCII.GetString($protected[0..4]) | Should -Be 'SRDP1'
        $plain = Unprotect-SRSnapshotBytes -Bytes $protected
        [System.Text.Encoding]::UTF8.GetString($plain) | Should -Be '{"hello":"world"}'
    }

    It 'writes and reads back an encrypted snapshot' {
        $config = Get-SRConfig
        $config.encryptSnapshots = $true
        $config.compressSnapshots = $true
        Save-SRConfig -Config $config

        $path = Save-SRSnapshot -Force
        $path | Should -Not -BeNullOrEmpty
        (Get-Item -LiteralPath $path).Length | Should -BeGreaterThan 5
        $raw = [System.IO.File]::ReadAllBytes($path)
        $header = [System.Text.Encoding]::ASCII.GetString($raw, 0, 5)
        $header | Should -Be 'SRDP1'
        $snapshot = Read-SRSnapshotFile -Path $path
        $snapshot.capturedAt | Should -Not -BeNullOrEmpty
        $null -ne ($snapshot.PSObject.Properties['stats']) | Should -BeTrue
    }

    It 'skips an unchanged snapshot when not forced' {
        $config = Get-SRConfig
        $config.encryptSnapshots = $false
        $config.compressSnapshots = $false
        Save-SRConfig -Config $config
        [void](Save-SRSnapshot -Force)
        $skipped = Save-SRSnapshot
        $skipped | Should -BeNullOrEmpty -Because 'nothing changed between the two captures'
    }

    It 'round-trips a gzip snapshot' {
        $config = Get-SRConfig
        $config.compressSnapshots = $true
        $config.encryptSnapshots = $false
        Save-SRConfig -Config $config
        $path = Save-SRSnapshot -Force
        $path | Should -Match '\.gz$'
        $snapshot = Read-SRSnapshotFile -Path $path
        $snapshot.capturedAt | Should -Not -BeNullOrEmpty
    }
}

Describe 'Retention removes thumbnails with snapshots' {
    It 'deletes old files and their thumbs folders' {
        # Start from an empty snapshot store: earlier round-trip tests leave
        # their own files behind in the same isolated home.
        $snapshotDir = Get-SRSnapshotDirectory
        if (Test-Path -LiteralPath $snapshotDir) {
            Remove-Item -LiteralPath $snapshotDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        New-Item -ItemType Directory -Path $snapshotDir -Force | Out-Null
        for ($index = 0; $index -lt 4; $index++) {
            $stamp = (Get-Date).AddDays(-10 - $index).ToString('yyyyMMdd-HHmmss-fff')
            $file = Join-Path $snapshotDir ("session-$stamp.json")
            Set-Content -LiteralPath $file -Value '{}' -Encoding UTF8
            (Get-Item -LiteralPath $file).LastWriteTime = (Get-Date).AddDays(-10 - $index)
            $thumbDir = Join-Path (Join-Path $snapshotDir 'thumbs') $stamp
            New-Item -ItemType Directory -Path $thumbDir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $thumbDir '01-app.jpg') -Value 'x'
        }
        Remove-OldSRSnapshots -Keep 1 -MaxAgeDays 0 -Pinned @()
        @(Get-ChildItem -LiteralPath $snapshotDir -Filter 'session-*.json*' -File).Count | Should -Be 1
        @(Get-ChildItem -LiteralPath (Join-Path $snapshotDir 'thumbs') -Directory -ErrorAction SilentlyContinue).Count | Should -Be 1
    }
}

Describe 'Import validation' {
    It 'rejects files that are not snapshots' {
        $badPath = Join-Path $env:SESSIONRECOVERY_HOME 'not-a-snapshot.json'
        Set-Content -LiteralPath $badPath -Value '{"foo":1}'
        { Import-SRSnapshotFile -Path $badPath } | Should -Throw
    }

    It 'accepts a well-formed snapshot file' {
        $goodPath = Join-Path $env:SESSIONRECOVERY_HOME 'session-import-test.json'
        @'
{
  "capturedAt": "2026-10-20T10:00:00.0000000+02:00",
  "apps": [],
  "explorer": [],
  "browsers": []
}
'@ | Set-Content -LiteralPath $goodPath
        $imported = Import-SRSnapshotFile -Path $goodPath
        $imported | Should -Not -BeNullOrEmpty
        (Split-Path -Leaf $imported) | Should -Match '^session-'
    }
}

Describe 'Snapshot state hash' {
    It 'is stable for equal content and changes when content changes' {
        $base = [pscustomobject]@{
            apps          = @([pscustomobject]@{ exe = 'a.exe'; windows = @() })
            explorer      = @('C:\x')
            browsers      = @()
            devWorkspaces = @()
        }
        $same = [pscustomobject]@{
            apps          = @([pscustomobject]@{ exe = 'a.exe'; windows = @() })
            explorer      = @('C:\x')
            browsers      = @()
            devWorkspaces = @()
        }
        $changed = [pscustomobject]@{
            apps          = @([pscustomobject]@{ exe = 'b.exe'; windows = @() })
            explorer      = @('C:\x')
            browsers      = @()
            devWorkspaces = @()
        }
        Get-SRSnapshotStateHash -Snapshot $base | Should -Be (Get-SRSnapshotStateHash -Snapshot $same)
        Get-SRSnapshotStateHash -Snapshot $base | Should -Not -Be (Get-SRSnapshotStateHash -Snapshot $changed)
    }
}

Describe 'Restore plan shape' {
    It 'carries dev workspaces, monitors and remote sessions' {
        $snapshot = [pscustomobject]@{
            apps          = @()
            explorer      = @()
            browsers      = @()
            devWorkspaces = @([pscustomobject]@{ kind = 'vscode'; tool = 'VS Code'; folders = @('C:\proj') })
            monitors      = @([pscustomobject]@{ device = '\\.\DISPLAY1'; x = 0; y = 0; width = 1920; height = 1080; primary = $true })
            remote        = @([pscustomobject]@{ kind = 'putty'; session = 'box'; title = 'box - PuTTY' })
        }
        $plan = New-SRRestorePlan -Snapshot $snapshot -All
        @($plan.dev).Count | Should -Be 1
        @($plan.monitors).Count | Should -Be 1
        @($plan.remote).Count | Should -Be 1
    }
}

Describe 'JetBrains launcher discovery' {
    It 'finds a launcher under the per-user Programs folder' {
        $oldLocal = $env:LOCALAPPDATA
        $oldProgramFiles = $env:ProgramFiles
        $fakeLocal = Join-Path $env:SR_TEST_HOME 'fake-local'
        $bin = Join-Path $fakeLocal 'Programs\IntelliJ IDEA\bin'
        New-Item -ItemType Directory -Path $bin -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $bin 'idea64.exe') -Value 'x'
        try {
            $env:LOCALAPPDATA = $fakeLocal
            $env:ProgramFiles = Join-Path $fakeLocal 'missing-program-files'
            Get-SRJetBrainsLauncher -Product 'IntelliJIdea2024.1' | Should -Be (Join-Path $bin 'idea64.exe')
        } finally {
            $env:LOCALAPPDATA = $oldLocal
            $env:ProgramFiles = $oldProgramFiles
        }
    }

    It 'returns null for an unknown product' {
        Get-SRJetBrainsLauncher -Product 'NotAnIde2024.1' | Should -BeNullOrEmpty
    }
}

Describe 'Installer payload' {
    It 'keeps the package per-user without conflicting MSI context properties' {
        $packagePath = Join-Path $PSScriptRoot '..\installer\Package.wxs'
        [xml]$xml = Get-Content -LiteralPath $packagePath -Raw
        $package = $xml.SelectSingleNode('//*[local-name()="Package"]')
        $package.Scope | Should -Be 'perUser'
        $propertyIds = @($xml.SelectNodes('//*[local-name()="Property"]') | ForEach-Object { $_.Id })
        $propertyIds | Should -Not -Contain 'ALLUSERS'
        $propertyIds | Should -Not -Contain 'MSIINSTALLPERUSER'
    }

    It 'removes every unversioned payload before installing the new copy' {
        # Windows Installer refuses to overwrite an unversioned file that it
        # considers modified, which left old UI strings in place after an
        # upgrade. Every non-versioned payload needs a RemoveFile entry that
        # runs before InstallFiles.
        $packagePath = Join-Path $PSScriptRoot '..\installer\Package.wxs'
        [xml]$xml = Get-Content -LiteralPath $packagePath -Raw
        $files = @($xml.SelectNodes('//*[local-name()="File"]') | Where-Object { (Split-Path $_.Source -Leaf) -ne 'SessionRecovery.exe' })
        $removals = @($xml.SelectNodes('//*[local-name()="RemoveFile" and @On="install"]') | ForEach-Object { $_.Name })
        $files.Count | Should -BeGreaterThan 0
        foreach ($file in $files) {
            $name = Split-Path $file.Source -Leaf
            $removals | Should -Contain $name -Because "$name must be replaced on upgrade"
        }
    }
}

Describe 'Office AutoRecover discovery' {
    It 'includes binary Excel .xlsb recovery files' {
        $oldRoaming = $env:APPDATA
        $oldLocal = $env:LOCALAPPDATA
        $fakeRoaming = Join-Path $env:SR_TEST_HOME 'fake-roaming'
        $excelDir = Join-Path $fakeRoaming 'Microsoft\Excel'
        New-Item -ItemType Directory -Path $excelDir -Force | Out-Null
        $recoveryFile = Join-Path $excelDir 'recovered.xlsb'
        Set-Content -LiteralPath $recoveryFile -Value 'x'
        try {
            $env:APPDATA = $fakeRoaming
            $env:LOCALAPPDATA = Join-Path $fakeRoaming 'missing-local'
            $files = @(Get-SROfficeRecoveryFiles)
            @($files | Where-Object { $_.file -eq $recoveryFile }).Count | Should -Be 1
        } finally {
            $env:APPDATA = $oldRoaming
            $env:LOCALAPPDATA = $oldLocal
        }
    }
}
