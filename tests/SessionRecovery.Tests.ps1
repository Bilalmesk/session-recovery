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
    . (Join-Path $PSScriptRoot '..\src\InstallManifest.ps1')
    # Pester 5 and 6 run It blocks outside this scope, so publish the pure
    # manifest helpers globally just like the imported module's commands.
    foreach ($name in @('Test-SRManifestFileName', 'New-SRInstallManifest', 'Get-SRInstallManifest', 'Remove-SRInstallOwnedFiles')) {
        Set-Item -Path ("Function:\global:{0}" -f $name) -Value (Get-Item ("Function:\{0}" -f $name)).ScriptBlock
    }
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

    It 'keeps the program placeholder and unsigned-update keys in every language' {
        foreach ($language in @('en', 'ar', 'fr', 'es', 'de', 'pt', 'ru', 'zh', 'tr')) {
            $strings = Get-SRStrings -Language $language
            $strings['RstImportedConfirmText'] | Should -Match '\{0\}' -Because "$language must show the program list"
            $strings['UpdateUnsignedConfirmTitle'] | Should -Not -BeNullOrEmpty
            $strings['UpdateUnsignedConfirmText'] | Should -Match '\{0\}' -Because "$language must name the unsigned version"
        }
    }

    It 'exposes the 2.7 notes, privacy, kit and insights keys in every language' {
        foreach ($language in @('en', 'ar', 'fr', 'es', 'de', 'pt', 'ru', 'zh', 'tr')) {
            $strings = Get-SRStrings -Language $language
            foreach ($key in @('NavRecoveryKit', 'NoteDialogTitle', 'PrivacyScanTitle', 'KitExportTitle', 'KitImportTitle', 'DiagInsights', 'InsightsSummary')) {
                $strings[$key] | Should -Not -BeNullOrEmpty -Because "$language should translate '$key'"
            }
            $strings['InsightsSummary'] | Should -Match '\{7\}' -Because "$language must show storage size"
            $strings['KitImportedStatus'] | Should -Match '\{4\}' -Because "$language must show encrypted skips"
            $strings['PrivacyScanFound'] | Should -Match '\{0\}' -Because "$language must show the suggestion count"
        }
    }

    It 'exposes the 2.8 hibernate keys in every language' {
        foreach ($language in @('en', 'ar', 'fr', 'es', 'de', 'pt', 'ru', 'zh', 'tr')) {
            $strings = Get-SRStrings -Language $language
            foreach ($key in @('SetHibernateGuard', 'HibernateGuardHint', 'TrayHibernate', 'HibernateConfirmTitle', 'HibernateConfirmText', 'TrayHibernateSaving', 'HibernateFailed', 'SnapRowHibernate', 'DetailHibernateSuffix')) {
                $strings[$key] | Should -Not -BeNullOrEmpty -Because "$language should translate '$key'"
            }
            $strings['HibernateFailed'] | Should -Match '\{0\}' -Because "$language must show the failure detail"
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

    It 'writes through a hidden temp file and ignores partial leftovers' {
        $config = Get-SRConfig
        $config.compressSnapshots = $false
        $config.encryptSnapshots = $false
        Save-SRConfig -Config $config

        $dir = Get-SRSnapshotDirectory
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $partial = Join-Path $dir '.session-partial.json.tmp'
        [System.IO.File]::WriteAllText($partial, '{"capturedAt":"partial"}')
        @(Get-SRSnapshotFiles | Where-Object { $_.Name -eq '.session-partial.json.tmp' }).Count | Should -Be 0 -Because 'a partial write must never be listed as a snapshot'

        $path = Save-SRSnapshot -Force
        $path | Should -Not -BeNullOrEmpty
        Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
        @(Get-ChildItem -LiteralPath $dir -Filter '.*.tmp' -File -ErrorAction SilentlyContinue).Count | Should -Be 0 -Because 'the temp file is moved into place after a complete write'
    }

    It 'stamps locally created snapshots with this installation ID' {
        $config = Get-SRConfig
        $config.compressSnapshots = $false
        $config.encryptSnapshots = $false
        Save-SRConfig -Config $config
        $path = Save-SRSnapshot -Force
        $snapshot = Read-SRSnapshotFile -Path $path
        $snapshot.provenance.installationId | Should -Be (Get-SRInstallationId)
        Test-SRImportedSnapshot -Snapshot $snapshot | Should -BeFalse
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

# ---------------------------------------------------------------------------
# Restore hardening
# ---------------------------------------------------------------------------

Describe 'Restore executable filter' {
    It 'accepts ordinary .exe programs' {
        $exe = Join-Path $env:SystemRoot 'System32\notepad.exe'
        (Test-SRRestoreExecutable -Path $exe).Ok | Should -BeTrue
    }

    It 'rejects non-exe files' {
        $scriptPath = Join-Path $env:SR_TEST_HOME 'evil.ps1'
        Set-Content -LiteralPath $scriptPath -Value 'Write-Host pwned'
        (Test-SRRestoreExecutable -Path $scriptPath).Ok | Should -BeFalse

        $cmdPath = Join-Path $env:SR_TEST_HOME 'evil.cmd'
        Set-Content -LiteralPath $cmdPath -Value '@echo off'
        (Test-SRRestoreExecutable -Path $cmdPath).Ok | Should -BeFalse
    }

    It 'blocks script hosts, interpreters and system download tools even when they are real executables' {
        foreach ($name in @('mshta.exe', 'wscript.exe', 'cscript.exe', 'powershell.exe', 'cmd.exe', 'certutil.exe', 'bitsadmin.exe', 'certreq.exe', 'explorer.exe')) {
            $relative = if ($name -eq 'explorer.exe') { $name } else { 'System32\' + $name }
            $path = Join-Path $env:SystemRoot $relative
            if (-not (Test-Path -LiteralPath $path)) { continue }
            (Test-SRRestoreExecutable -Path $path).Ok | Should -BeFalse -Because "$name must never be replayed"
        }
    }

    It 'rejects programs on network shares and device paths' {
        foreach ($path in @('\\server\share\evil.exe', '//server/share/evil.exe', '\\?\C:\Windows\System32\notepad.exe', '\\.\C:\Windows\System32\notepad.exe')) {
            $result = Test-SRRestoreExecutable -Path $path
            $result.Ok | Should -BeFalse -Because "$path is not a local fixed-drive path"
            $result.Reason | Should -Match 'Network|device|local fixed'
        }
    }

    It 'rejects empty paths' {
        (Test-SRRestoreExecutable -Path '').Ok | Should -BeFalse
    }
}

Describe 'Restore argument filter' {
    It 'accepts URLs and existing paths' {
        $result = Test-SRRestoreArgumentList -Arguments @('https://example.com/a?b=c', $env:SystemRoot)
        $result.Ok | Should -BeTrue
        @($result.Arguments).Count | Should -Be 2
    }

    It 'rejects switches, control characters and missing paths' {
        (Test-SRRestoreArgumentList -Arguments @('-c')).Ok | Should -BeFalse
        (Test-SRRestoreArgumentList -Arguments @('/c')).Ok | Should -BeFalse
        (Test-SRRestoreArgumentList -Arguments @("bad`targ")).Ok | Should -BeFalse
        (Test-SRRestoreArgumentList -Arguments @('Z:\nowhere\missing.txt')).Ok | Should -BeFalse
    }

    It 'rejects arguments that point at network shares or device paths' {
        foreach ($argument in @('\\server\share\setup.cfg', '//server/share/setup.cfg', '\\?\C:\temp\payload.cmd')) {
            $result = Test-SRRestoreArgumentList -Arguments @($argument)
            $result.Ok | Should -BeFalse -Because "$argument must never be passed to a restored program"
            # The forward-slash UNC form is also caught by the switch filter.
            $result.Reason | Should -Match 'Unsafe argument|Unsafe command-line switch'
        }
    }

    It 'rejects more than eight arguments' {
        $arguments = @(1..9 | ForEach-Object { 'https://example.com/{0}' -f $_ })
        (Test-SRRestoreArgumentList -Arguments $arguments).Ok | Should -BeFalse
    }

    It 'applies the same filter to captured command lines' {
        @(Get-SRSafeArguments -CommandLine '"C:\App\app.exe" https://example.com').Count | Should -Be 1
        @(Get-SRSafeArguments -CommandLine '"C:\App\app.exe" -Run:evil').Count | Should -Be 0
    }
}

Describe 'Start-SRApplication hardening' {
    It 'refuses to run a non-exe program' {
        $cmdPath = Join-Path $env:SR_TEST_HOME 'evil-launch.cmd'
        Set-Content -LiteralPath $cmdPath -Value '@echo pwned > pwned.txt'
        $result = Start-SRApplication -App ([pscustomobject]@{ name = 'evil'; exe = $cmdPath })
        $result.Started | Should -BeFalse
        $result.Message | Should -Match 'Only .exe'
        Test-Path -LiteralPath (Join-Path $env:SR_TEST_HOME 'pwned.txt') | Should -BeFalse
    }

    It 'revalidates saved arguments before launching' {
        $exePath = Join-Path $env:SR_TEST_HOME 'safe.exe'
        Set-Content -LiteralPath $exePath -Value 'not a real executable'
        $result = Start-SRApplication -App ([pscustomobject]@{ name = 'safe'; exe = $exePath; args = @('-Run:evil') })
        $result.Started | Should -BeFalse
        $result.Message | Should -Match 'Unsafe|switch'
    }
}

Describe 'Imported snapshots' {
    It 'marks an imported file and exposes the marker' {
        $source = Join-Path $env:SR_TEST_HOME 'session-imported-marker.json'
        @'
{
  "capturedAt": "2026-10-20T10:00:00.0000000+02:00",
  "apps": [],
  "explorer": [],
  "browsers": []
}
'@ | Set-Content -LiteralPath $source
        $target = Import-SRSnapshotFile -Path $source
        $snapshot = Get-Content -LiteralPath $target -Raw | ConvertFrom-Json
        $snapshot.imported | Should -BeTrue
        [bool]$snapshot.PSObject.Properties['importedAt'] | Should -BeTrue
        $snapshot.importedFileHashAlgorithm | Should -Be 'SHA256'
        $snapshot.importedFileHash | Should -Be (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
        Test-SRImportedSnapshot -Snapshot $snapshot | Should -BeTrue
    }

    It 'treats a hand-dropped snapshot without provenance as untrusted' {
        $snapshot = [pscustomobject]@{
            capturedAt = '2026-10-20T10:00:00.0000000+02:00'
            apps       = @()
            explorer   = @()
            browsers   = @()
        }
        Test-SRImportedSnapshot -Snapshot $snapshot | Should -BeTrue
    }

    It 'treats a snapshot from another installation as untrusted' {
        $snapshot = [pscustomobject]@{
            capturedAt = '2026-10-20T10:00:00.0000000+02:00'
            provenance = [pscustomobject]@{
                format         = 1
                installationId = [guid]::NewGuid().ToString('D')
            }
            apps       = @()
            explorer   = @()
            browsers   = @()
        }
        Test-SRImportedSnapshot -Snapshot $snapshot | Should -BeTrue
    }

    It 'rejects application entries without an executable' {
        $source = Join-Path $env:SR_TEST_HOME 'session-bad-app.json'
        @'
{ "capturedAt": "2026-10-20T10:00:00+02:00", "apps": [ { "name": "Missing" } ], "explorer": [], "browsers": [] }
'@ | Set-Content -LiteralPath $source
        { Import-SRSnapshotFile -Path $source } | Should -Throw
    }

    It 'rejects empty application arguments' {
        $source = Join-Path $env:SR_TEST_HOME 'session-bad-args.json'
        @'
{ "capturedAt": "2026-10-20T10:00:00+02:00", "apps": [ { "name": "App", "exe": "C:\\App\\app.exe", "args": [""] } ], "explorer": [], "browsers": [] }
'@ | Set-Content -LiteralPath $source
        { Import-SRSnapshotFile -Path $source } | Should -Throw
    }
}

Describe 'Legacy snapshot adoption' {
    It 'adopts pre-provenance snapshots once when the installation ID is created' {
        $snapshotDir = Get-SRSnapshotDirectory
        # Simulate an upgrade from 2.6.0: a snapshot with no provenance, a
        # deliberately imported file, and a gzipped snapshot with none.
        $legacyPath = Join-Path $snapshotDir 'session-20261026-000000-000.json'
        @'
{ "capturedAt": "2026-10-26T00:00:00.0000000+02:00", "apps": [], "explorer": [], "browsers": [] }
'@ | Set-Content -LiteralPath $legacyPath
        $importedPath = Join-Path $snapshotDir 'session-20261026-000001-000.json'
        @'
{ "capturedAt": "2026-10-26T00:00:01.0000000+02:00", "imported": true, "apps": [], "explorer": [], "browsers": [] }
'@ | Set-Content -LiteralPath $importedPath
        $gzipPath = Join-Path $snapshotDir 'session-20261026-000002-000.json.gz'
        $gzipJson = '{ "capturedAt": "2026-10-26T00:00:02.0000000+02:00", "apps": [], "explorer": [], "browsers": [] }'
        $gzipBytes = [System.Text.Encoding]::UTF8.GetBytes($gzipJson)
        $gzipStream = New-Object System.IO.MemoryStream
        $gzipWriter = New-Object System.IO.Compression.GZipStream($gzipStream, [System.IO.Compression.CompressionMode]::Compress)
        $gzipWriter.Write($gzipBytes, 0, $gzipBytes.Length)
        $gzipWriter.Dispose()
        [System.IO.File]::WriteAllBytes($gzipPath, $gzipStream.ToArray())
        $gzipStream.Dispose()

        # A fresh installation ID must not exist for the adoption to run.
        $installIdPath = Join-Path $env:SESSIONRECOVERY_HOME 'installation.id'
        Remove-Item -LiteralPath $installIdPath -Force -ErrorAction SilentlyContinue
        & (Get-Module SessionRecovery) { $script:SRInstallationId = $null }

        $newId = Get-SRInstallationId
        $newId | Should -Match '^[0-9a-f-]{36}$'

        $legacy = Read-SRSnapshotFile -Path $legacyPath
        $legacy.provenance.installationId | Should -Be $newId
        Test-SRImportedSnapshot -Snapshot $legacy | Should -BeFalse

        # The imported marker survives the adoption.
        $imported = Read-SRSnapshotFile -Path $importedPath
        Test-SRImportedSnapshot -Snapshot $imported | Should -BeTrue

        # The gzip format survives the adoption.
        $adopted = Read-SRSnapshotFile -Path $gzipPath
        $adopted.provenance.installationId | Should -Be $newId
        $rewritten = [System.IO.File]::ReadAllBytes($gzipPath)
        $rewritten[0] | Should -Be 0x1F
        $rewritten[1] | Should -Be 0x8B
    }

    It 'does not adopt files dropped after the installation ID exists' {
        $snapshotDir = Get-SRSnapshotDirectory
        $droppedPath = Join-Path $snapshotDir 'session-20261027-000000-000.json'
        @'
{ "capturedAt": "2026-10-27T00:00:00.0000000+02:00", "apps": [], "explorer": [], "browsers": [] }
'@ | Set-Content -LiteralPath $droppedPath
        $dropped = Read-SRSnapshotFile -Path $droppedPath
        Test-SRImportedSnapshot -Snapshot $dropped | Should -BeTrue
    }
}

# ---------------------------------------------------------------------------
# Localized shutdown reasons
# ---------------------------------------------------------------------------

Describe 'Shutdown reason localization' {
    It 'formats a structured reason in French' {
        $strings = Get-SRStrings -Language 'fr'
        $shutdown = [pscustomobject]@{
            ReasonKey = 'ShutdownInitiated'
            ReasonArg = 'explorer.exe'
            Reason    = 'Shutdown initiated by explorer.exe'
        }
        $formatted = Format-SRShutdownReason -Shutdown $shutdown -Strings $strings
        # Compare against the table so this test file stays ASCII-only and
        # Windows PowerShell 5.1 reads it correctly without a BOM.
        $formatted | Should -Be ($strings['ShutdownInitiated'] -f 'explorer.exe')
        $formatted | Should -Not -Be ('Shutdown initiated by {0}' -f 'explorer.exe')
    }

    It 'falls back to the English reason when no key exists' {
        $shutdown = [pscustomobject]@{ ReasonKey = ''; ReasonArg = ''; Reason = 'Fallback reason' }
        Format-SRShutdownReason -Shutdown $shutdown -Strings (Get-SRStrings -Language 'fr') |
            Should -Be 'Fallback reason'
    }

    It 'is used by the restore prompt and Studio diagnostics' {
        $restoreText = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\src\Restore-Session.ps1') -Raw
        $studioText = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\src\Studio-SessionRecovery.ps1') -Raw
        $restoreText | Should -Match 'Format-SRShutdownReason'
        $studioText | Should -Match 'Format-SRShutdownReason'
    }
}

# ---------------------------------------------------------------------------
# Install manifest and uninstaller safety
# ---------------------------------------------------------------------------

Describe 'Install manifest and uninstaller safety' {
    It 'writes and reads leaf file names' {
        $dir = Join-Path $env:SR_TEST_HOME 'manifest-roundtrip'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $manifestPath = New-SRInstallManifest -InstallDirectory $dir -Files @('one.ps1', 'two.exe', 'one.ps1')
        Test-Path -LiteralPath $manifestPath | Should -BeTrue
        $manifest = Get-SRInstallManifest -InstallDirectory $dir
        $manifest | Should -Not -BeNullOrEmpty
        (@($manifest.Files) -join ',') | Should -Be 'one.ps1,two.exe'
    }

    It 'removes only installer-owned files' {
        $parent = Join-Path $env:SR_TEST_HOME 'manifest-removal'
        $dir = Join-Path $parent 'app'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'owned.ps1') -Value 'owned'
        Set-Content -LiteralPath (Join-Path $dir 'owned.exe') -Value 'owned'
        Set-Content -LiteralPath (Join-Path $dir 'user-notes.txt') -Value 'keep me'
        [void](New-SRInstallManifest -InstallDirectory $dir -Files @('owned.ps1', 'owned.exe'))
        $result = Remove-SRInstallOwnedFiles -InstallDirectory $dir
        $result.Ok | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $dir 'owned.ps1') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $dir 'owned.exe') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $dir 'user-notes.txt') | Should -BeTrue
        Test-Path -LiteralPath $dir | Should -BeTrue
    }

    It 'refuses to delete anything without a manifest' {
        $dir = Join-Path $env:SR_TEST_HOME 'manifest-missing'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'keep.txt') -Value 'keep'
        $result = Remove-SRInstallOwnedFiles -InstallDirectory $dir
        $result.Ok | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $dir 'keep.txt') | Should -BeTrue
    }

    It 'rejects path traversal in a tampered manifest' {
        $parent = Join-Path $env:SR_TEST_HOME 'manifest-tampered'
        $dir = Join-Path $parent 'app'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $outside = Join-Path $parent 'outside.txt'
        Set-Content -LiteralPath $outside -Value 'keep'
        @'
{ "product": "Session Recovery", "format": 1, "files": [ "..\\outside.txt" ] }
'@ | Set-Content -LiteralPath (Join-Path $dir 'install-manifest.json')
        Get-SRInstallManifest -InstallDirectory $dir | Should -BeNullOrEmpty
        $result = Remove-SRInstallOwnedFiles -InstallDirectory $dir
        $result.Ok | Should -BeFalse
        Test-Path -LiteralPath $outside | Should -BeTrue
    }

    It 'rejects rooted paths in a tampered manifest' {
        $dir = Join-Path $env:SR_TEST_HOME 'manifest-rooted'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $outside = Join-Path $env:SystemRoot 'win.ini'
        $json = [pscustomobject]@{ product = 'Session Recovery'; format = 1; files = @($outside) } | ConvertTo-Json
        Set-Content -LiteralPath (Join-Path $dir 'install-manifest.json') -Value $json
        Get-SRInstallManifest -InstallDirectory $dir | Should -BeNullOrEmpty
    }

    It 'has no cmd rmdir fallback anymore' {
        $text = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\Uninstall-SessionRecovery.ps1') -Raw
        $text | Should -Not -Match 'rmdir'
        $text | Should -Not -Match 'ComSpec'
        $text | Should -Match 'Remove-SRInstallOwnedFiles'
    }

    It 'has the installer write the manifest' {
        $text = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\Install-SessionRecovery.ps1') -Raw
        $text | Should -Match 'New-SRInstallManifest'
        $text | Should -Match 'InstallManifest\.ps1'
    }
}

# ---------------------------------------------------------------------------
# Update supply chain and restore UI checks
# ---------------------------------------------------------------------------

Describe 'Update supply chain' {
    It 'does not read or send GitHub tokens' {
        $text = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\src\SessionRecovery.psm1') -Raw
        $text | Should -Not -Match 'Get-SRGitHubToken'
        $text | Should -Not -Match 'Invoke-SRHiddenProcess'
        $text | Should -Not -Match 'Authorization'
    }

    It 'records whether the downloaded MSI was signed' {
        $text = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\src\SessionRecovery.psm1') -Raw
        $text | Should -Match 'Get-AuthenticodeSignature'
        $text | Should -Match 'Signed\s*=\s*\[bool\]\$signature\.Signed'
        $text | Should -Match 'SignatureStatus'
    }

    It 'reports an unsigned file as unsigned' {
        $path = Join-Path $env:SR_TEST_HOME 'unsigned-update.msi'
        Set-Content -LiteralPath $path -Value 'not a signed installer'
        $signature = Get-SRUpdateSignature -Path $path
        $signature.Signed | Should -BeFalse
        $signature.Status | Should -Not -BeNullOrEmpty
    }

    It 'shows unsigned status and defaults to No before installing' {
        $text = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\src\Studio-SessionRecovery.ps1') -Raw
        $text | Should -Match 'UpdateUnsignedConfirmTitle'
        $text | Should -Match 'UpdateUnsignedConfirmText'
        $text | Should -Match 'MessageBoxDefaultButton\]::Button2'
        $text | Should -Match 'UpdateUnsignedVerified'
    }
}

Describe 'Restore UI security' {
    It 'offers an explicit headless confirmation for imported snapshots' {
        $text = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\src\Restore-Session.ps1') -Raw
        $text | Should -Match '\[switch\]\$AllowImportedSnapshot'
        $text | Should -Match 'RstImportedHeadless'
        $text | Should -Match 'RstImportedConfirmText'
    }

    It 'keeps the program list placeholder in the English fallback' {
        $lines = @(Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\src\Restore-Session.ps1') |
            Where-Object { $_ -match "T 'RstImportedConfirmText'" })
        $lines.Count | Should -Be 1
        $lines[0] | Should -Match '\{0\}'
    }

    It 'lists the saved arguments in the untrusted-snapshot confirmation' {
        $text = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\src\Restore-Session.ps1') -Raw
        $text | Should -Match 'displayArguments'
        $text | Should -Match 'displayArguments -join'
    }

    It 'validates the executable path before touching the file system' {
        $text = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\src\SessionRecovery.psm1') -Raw
        $text | Should -Match 'function Test-SRLocalFixedPath'
        $text | Should -Match 'DriveType.*Fixed|DriveType\]::Fixed'
    }

    It 'quotes the Notepad config path correctly' {
        $lines = @(Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\src\Studio-SessionRecovery.ps1') | Where-Object { $_ -like '*notepad.exe*' })
        $lines.Count | Should -Be 1
        $lines[0].Contains('"{0}"') | Should -BeTrue
        $lines[0].Contains('\"') | Should -BeFalse
    }
}

# ---------------------------------------------------------------------------
# 2.7 recovery features
# ---------------------------------------------------------------------------

Describe '2.7 recovery features' {
    BeforeAll {
        Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

        function New-TestSnapshotFile {
            param(
                [Parameter(Mandatory = $true)][string]$Name,
                [Parameter(Mandatory = $true)][datetime]$CapturedAt,
                [object[]]$Apps = @(),
                [object[]]$Browsers = @()
            )
            $dir = Get-SRSnapshotDirectory
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            $snapshot = [ordered]@{
                capturedAt = $CapturedAt.ToString('o')
                apps       = @($Apps)
                explorer   = @()
                browsers   = @($Browsers)
            }
            $path = Join-Path $dir $Name
            $json = $snapshot | ConvertTo-Json -Depth 10
            [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))
            return $path
        }

        function New-TestZip {
            param(
                [Parameter(Mandatory = $true)][string]$Path,
                [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Entries
            )
            $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Create, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
            $archive = New-Object System.IO.Compression.ZipArchive($stream, [System.IO.Compression.ZipArchiveMode]::Create)
            try {
                foreach ($name in @($Entries.Keys)) {
                    $entry = $archive.CreateEntry([string]$name)
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Entries[$name])
                    $entryStream = $entry.Open()
                    try { $entryStream.Write($bytes, 0, $bytes.Length) } finally { $entryStream.Dispose() }
                }
            } finally {
                $archive.Dispose()
                $stream.Dispose()
            }
            return $Path
        }

        function Reset-TestRecoveryState {
            $config = Get-SRConfig
            $config.excludeApps = @()
            $config.excludeFolders = @()
            $config.excludeUrls = @()
            $config.snapshotNotes = @{}
            $config.pinnedSnapshots = @()
            $config.encryptSnapshots = $false
            $config.compressSnapshots = $false
            Save-SRConfig -Config $config
            $dir = Get-SRSnapshotDirectory
            if (Test-Path -LiteralPath $dir) {
                @(Get-ChildItem -LiteralPath $dir -Filter 'session-*' -File -ErrorAction SilentlyContinue) | Remove-Item -Force -ErrorAction SilentlyContinue
            } else {
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
            }
        }
    }

    BeforeEach { Reset-TestRecoveryState }

    AfterAll {
        try { Reset-TestRecoveryState } catch { }
    }

    Context 'Snapshot notes' {
        It 'stores, trims, caps and removes a snapshot note' {
            $path = Join-Path (Get-SRSnapshotDirectory) 'session-note-test.json'
            $saved = Set-SRSnapshotNote -Path $path -Note ('  ' + ('x' * 600) + '  ')
            $saved.Length | Should -Be 500
            (Get-SRSnapshotNote -Path $path).Length | Should -Be 500

            Set-SRSnapshotNote -Path $path -Note '  A short note  ' | Should -Be 'A short note'
            Get-SRSnapshotNote -Path $path | Should -Be 'A short note'

            Set-SRSnapshotNote -Path $path -Note '   ' | Should -Be ''
            Get-SRSnapshotNote -Path $path | Should -Be ''
            $notes = ConvertTo-SRNoteTable -Value (Get-SRConfig).snapshotNotes
            $notes.ContainsKey('session-note-test.json') | Should -BeFalse
        }

        It 'keys notes by file name even when given a full path' {
            $path = Join-Path (Join-Path $env:SR_TEST_HOME 'somewhere') 'session-note-leaf.json'
            Set-SRSnapshotNote -Path $path -Note 'leaf' | Out-Null
            $notes = ConvertTo-SRNoteTable -Value (Get-SRConfig).snapshotNotes
            $notes.ContainsKey('session-note-leaf.json') | Should -BeTrue
            $notes.ContainsKey($path) | Should -BeFalse
        }

        It 'ignores note keys that are not plain file names' {
            $table = ConvertTo-SRNoteTable -Value ([ordered]@{
                '../evil.json'          = 'bad'
                '..\evil.json'          = 'bad'
                'C:\Windows\evil.json'  = 'bad'
                'session-good.json'     = ' ok '
            })
            $table.Count | Should -Be 1
            $table.ContainsKey('session-good.json') | Should -BeTrue
            $table['session-good.json'] | Should -Be 'ok'
        }
    }

    Context 'Privacy scan' {
        It 'finds password managers and finance sites from names and URLs' {
            $report = Get-SRPrivacyFindings `
                -Apps @([pscustomobject]@{ name = '1Password'; exe = 'C:\Program Files\1Password\1Password.exe' }) `
                -Tabs @([pscustomobject]@{ title = 'Chase Online'; url = 'https://secure.chase.com/login' })
            $report.AppsScanned | Should -Be 1
            $report.TabsScanned | Should -Be 1
            $findings = @($report.Findings)
            $findings.Count | Should -Be 2

            $appFinding = $findings | Where-Object { $_.Pattern -eq '*1password*' } | Select-Object -First 1
            $appFinding.Kind | Should -Be 'app'
            $appFinding.ReasonKey | Should -Be 'PrivacyReasonPasswordManager'

            $urlFinding = $findings | Where-Object { $_.Pattern -eq '*secure.chase.com*' } | Select-Object -First 1
            $urlFinding.Kind | Should -Be 'url'
            $urlFinding.ReasonKey | Should -Be 'PrivacyReasonFinance'
        }

        It 'honors app and URL exclusions' {
            $report = Get-SRPrivacyFindings `
                -Apps @([pscustomobject]@{ name = '1Password'; exe = 'C:\Program Files\1Password\1Password.exe' }) `
                -Tabs @([pscustomobject]@{ title = 'Chase Online'; url = 'https://secure.chase.com/login' }) `
                -ExcludeApps '*1password*' `
                -ExcludeUrls '*chase.com*'
            @($report.Findings).Count | Should -Be 0
        }

        It 'ignores non-web tabs' {
            $report = Get-SRPrivacyFindings -Apps @() -Tabs @([pscustomobject]@{ title = 'Inbox'; url = 'mailto:someone@example.com' })
            @($report.Findings).Count | Should -Be 0
        }
    }

    Context 'Recovery kit' {
        It 'exports snapshots, notes and exclusions into a portable zip' {
            $first = New-TestSnapshotFile -Name 'session-20261001-090000-000.json' -CapturedAt ([datetime]::ParseExact('2026-10-01T09:00:00', 'yyyy-MM-ddTHH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)) `
                -Apps @([pscustomobject]@{ name = 'Alpha'; exe = 'C:\Apps\Alpha.exe' })
            [void](New-TestSnapshotFile -Name 'session-20261002-090000-000.json' -CapturedAt ([datetime]::ParseExact('2026-10-02T09:00:00', 'yyyy-MM-ddTHH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)))
            Set-SRSnapshotNote -Path $first -Note 'Demo note' | Out-Null

            $config = Get-SRConfig
            $config.excludeApps = @('*1password*')
            $config.excludeFolders = @('C:\Private')
            $config.excludeUrls = @('*bank*')
            Save-SRConfig -Config $config

            $kit = Join-Path $env:SR_TEST_HOME ('kit-' + [guid]::NewGuid().ToString('N') + '.srkit')
            $result = Export-SRRecoveryKit -Destination $kit -AppVersion '2.7.0'
            $result.SnapshotCount | Should -Be 2
            $result.NoteCount | Should -Be 1
            $result.ExclusionCount | Should -Be 3
            $result.EncryptedCount | Should -Be 0
            $result.Bytes | Should -BeGreaterThan 0

            $archive = [System.IO.Compression.ZipFile]::OpenRead($kit)
            try {
                $names = @($archive.Entries | ForEach-Object { ([string]$_.FullName).Replace('\', '/') })
            } finally {
                $archive.Dispose()
            }
            $names | Should -Contain 'manifest.json'
            $names | Should -Contain 'README.txt'
            $names | Should -Contain 'snapshots/session-20261001-090000-000.json'
            $names | Should -Contain 'snapshots/session-20261002-090000-000.json'
        }

        It 'round-trips a kit into a clean profile' {
            $first = New-TestSnapshotFile -Name 'session-20261003-090000-000.json' -CapturedAt ([datetime]::ParseExact('2026-10-03T09:00:00', 'yyyy-MM-ddTHH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)) `
                -Apps @([pscustomobject]@{ name = 'Beta'; exe = 'C:\Apps\Beta.exe' })
            Set-SRSnapshotNote -Path $first -Note 'Carry me' | Out-Null
            $config = Get-SRConfig
            $config.excludeApps = @('*1password*')
            $config.excludeFolders = @('C:\Private')
            $config.excludeUrls = @('*bank*')
            Save-SRConfig -Config $config

            $kit = Join-Path $env:SR_TEST_HOME ('kit-' + [guid]::NewGuid().ToString('N') + '.srkit')
            [void](Export-SRRecoveryKit -Destination $kit -AppVersion '2.7.0')

            $dir = Get-SRSnapshotDirectory
            @(Get-ChildItem -LiteralPath $dir -Filter 'session-*' -File) | Remove-Item -Force
            $config = Get-SRConfig
            $config.excludeApps = @()
            $config.excludeFolders = @()
            $config.excludeUrls = @()
            $config.snapshotNotes = @{}
            Save-SRConfig -Config $config

            $imported = Import-SRRecoveryKit -Path $kit
            $imported.Imported | Should -Be 1
            $imported.ExclusionsAdded | Should -Be 3
            $imported.NotesAdded | Should -Be 1
            $imported.EncryptedSkipped | Should -Be 0

            $config = Get-SRConfig
            @($config.excludeApps) | Should -Contain '*1password*'
            @($config.excludeFolders) | Should -Contain 'C:\Private'
            @($config.excludeUrls) | Should -Contain '*bank*'
            Get-SRSnapshotNote -Path (Join-Path $dir 'session-20261003-090000-000.json') | Should -Be 'Carry me'
            @(Get-ChildItem -LiteralPath $dir -Filter 'session-*' -File).Count | Should -Be 1
        }

        It 'rejects a kit whose entry paths escape the archive' {
            $manifest = [pscustomobject]@{
                kind      = 'SessionRecoveryRecoveryKit'
                format    = 1
                snapshots = @()
            } | ConvertTo-Json -Depth 6
            $kit = New-TestZip -Path (Join-Path $env:SR_TEST_HOME ('kit-' + [guid]::NewGuid().ToString('N') + '.srkit')) -Entries ([ordered]@{
                'manifest.json' = $manifest
                '../evil.json'  = '{}'
            })
            { Import-SRRecoveryKit -Path $kit } | Should -Throw '*unsafe path*'
        }

        It 'skips encrypted snapshots instead of copying them' {
            $name = 'session-20261001-090000-000.json'
            $manifest = [pscustomobject]@{
                kind       = 'SessionRecoveryRecoveryKit'
                format     = 1
                snapshots  = @([pscustomobject]@{ name = $name })
                notes      = @{}
                exclusions = [pscustomobject]@{ apps = @(); folders = @(); urls = @() }
            } | ConvertTo-Json -Depth 6
            $kit = New-TestZip -Path (Join-Path $env:SR_TEST_HOME ('kit-' + [guid]::NewGuid().ToString('N') + '.srkit')) -Entries ([ordered]@{
                'manifest.json'          = $manifest
                ('snapshots/' + $name)   = 'SRDP1-not-decryptable'
            })

            $result = Import-SRRecoveryKit -Path $kit
            $result.Imported | Should -Be 0
            $result.EncryptedSkipped | Should -Be 1
            $result.Skipped | Should -Be 1
            @(Get-ChildItem -LiteralPath (Get-SRSnapshotDirectory) -Filter 'session-*' -File).Count | Should -Be 0
        }
    }

    Context 'Recovery insights' {
        It 'counts captures, sites, pins, notes and imports locally' {
            $config = Get-SRConfig
            $config.pinnedSnapshots = @('session-a.json', 'session-b.json', '')
            $config.snapshotNotes = [ordered]@{ 'session-a.json' = 'first'; 'session-b.json' = 'second' }
            $entries = @(
                [pscustomobject]@{
                    Path       = Join-Path $env:SR_TEST_HOME 'session-a.json'
                    CapturedAt = [datetime]::ParseExact('2026-10-01T09:00:00', 'yyyy-MM-ddTHH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
                    Snapshot   = [pscustomobject]@{
                        apps     = @([pscustomobject]@{ name = 'Alpha' }, [pscustomobject]@{ name = 'Alpha' })
                        browsers = @([pscustomobject]@{
                            profiles = @([pscustomobject]@{
                                tabs = @(
                                    [pscustomobject]@{ url = 'https://example.com/a' },
                                    [pscustomobject]@{ url = 'https://news.example.com/b' }
                                )
                            })
                        })
                    }
                }
                [pscustomobject]@{
                    Path       = Join-Path $env:SR_TEST_HOME 'session-b.json'
                    CapturedAt = [datetime]::ParseExact('2026-10-03T09:00:00', 'yyyy-MM-ddTHH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
                    Snapshot   = [pscustomobject]@{
                        imported = $true
                        apps     = @([pscustomobject]@{ displayName = 'Beta' })
                        browsers = @([pscustomobject]@{
                            profiles = @([pscustomobject]@{
                                tabs = @([pscustomobject]@{ url = 'https://example.com/c' })
                            })
                        })
                    }
                }
            )

            $insights = Get-SRRecoveryInsights -Entries $entries -Config $config
            $insights.SnapshotCount | Should -Be 2
            $insights.SpanDays | Should -Be 2
            $insights.AppCaptures | Should -Be 3
            $insights.UniqueApps | Should -Be 2
            $insights.TabCaptures | Should -Be 3
            $insights.UniqueSites | Should -Be 2
            $insights.PinnedCount | Should -Be 2
            $insights.NoteCount | Should -Be 2
            $insights.ImportedCount | Should -Be 1
            $insights.TopApps[0].Name | Should -Be 'alpha'
            $insights.TopApps[0].Count | Should -Be 2
            $insights.TopSites[0].Name | Should -Be 'example.com'
            $insights.TopSites[0].Count | Should -Be 2
        }

        It 'returns an empty shape when there are no snapshots' {
            $insights = Get-SRRecoveryInsights -Entries @() -Config (Get-SRConfig)
            $insights.SnapshotCount | Should -Be 0
            $insights.UniqueApps | Should -Be 0
            $insights.UniqueSites | Should -Be 0
            $insights.TopApps.Count | Should -Be 0
            $insights.TopSites.Count | Should -Be 0
        }
    }

    Context 'Snapshot file reading' {
        It 'reads a snapshot saved with a UTF-8 BOM' {
            $path = Join-Path $env:SR_TEST_HOME 'bom-snapshot.json'
            $json = '{"capturedAt":"2026-10-01T09:00:00+00:00","apps":[],"explorer":[],"browsers":[]}'
            [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($true)))
            $snapshot = Read-SRSnapshotFile -Path $path
            $snapshot.capturedAt | Should -Be '2026-10-01T09:00:00+00:00'
        }
    }
}

# ---------------------------------------------------------------------------
# 2.8 hibernate checkpoints
# ---------------------------------------------------------------------------

Describe 'Hibernate checkpoints' {
    BeforeAll {
        function New-TestHibernateFile {
            param(
                [Parameter(Mandatory = $true)][string]$Name,
                [Parameter(Mandatory = $true)][datetime]$CapturedAt,
                [string]$Reason = 'hibernate'
            )
            $dir = Get-SRSnapshotDirectory
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            $snapshot = [ordered]@{
                capturedAt = $CapturedAt.ToString('o')
                apps       = @()
                explorer   = @()
                browsers   = @()
                reason     = $Reason
            }
            $path = Join-Path $dir $Name
            $json = $snapshot | ConvertTo-Json -Depth 5
            [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))
            (Get-Item -LiteralPath $path).LastWriteTime = $CapturedAt
            return $path
        }

        function Reset-TestHibernateState {
            $config = Get-SRConfig
            $config.pinnedSnapshots = @()
            $config.snapshotNotes = @{}
            $config.hibernateGuard = $true
            $config.keepHibernateCheckpoints = 3
            $config.encryptSnapshots = $false
            $config.compressSnapshots = $false
            $config.captureThumbnails = $false
            $config.autoExportFolder = ''
            Save-SRConfig -Config $config
            $dir = Get-SRSnapshotDirectory
            if (Test-Path -LiteralPath $dir) {
                @(Get-ChildItem -LiteralPath $dir -Filter 'session-*' -File -ErrorAction SilentlyContinue) | Remove-Item -Force -ErrorAction SilentlyContinue
            } else {
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
            }
        }
    }

    BeforeEach { Reset-TestHibernateState }

    AfterAll {
        try { Reset-TestHibernateState } catch { }
    }

    It 'saves a hibernate checkpoint, pins it and keeps the newest three' {
        $now = Get-Date
        [void](New-TestHibernateFile -Name 'session-hib-oldest.json' -CapturedAt $now.AddHours(-3))
        [void](New-TestHibernateFile -Name 'session-hib-middle.json' -CapturedAt $now.AddHours(-2))
        [void](New-TestHibernateFile -Name 'session-hib-newer.json' -CapturedAt $now.AddHours(-1))
        [void](New-TestHibernateFile -Name 'session-normal-pin.json' -CapturedAt $now.AddHours(-4) -Reason 'scheduled')

        $config = Get-SRConfig
        $config.pinnedSnapshots = @(
            'session-hib-oldest.json',
            'session-hib-middle.json',
            'session-hib-newer.json',
            'session-normal-pin.json'
        )
        Save-SRConfig -Config $config

        $path = Save-SRHibernateSnapshot -Force
        $path | Should -Not -BeNullOrEmpty
        (Read-SRSnapshotFile -Path $path).reason | Should -Be 'hibernate'

        $pins = @((Get-SRConfig).pinnedSnapshots)
        $pins -contains (Split-Path -Leaf $path) | Should -BeTrue
        $pins -contains 'session-hib-oldest.json' | Should -BeFalse -Because 'only the latest three checkpoints stay pinned'
        $pins -contains 'session-hib-middle.json' | Should -BeTrue
        $pins -contains 'session-hib-newer.json' | Should -BeTrue
        $pins -contains 'session-normal-pin.json' | Should -BeTrue -Because 'unrelated user pins must never be removed'
    }

    It 'skips an automatic checkpoint when the guard is off' {
        $config = Get-SRConfig
        $config.hibernateGuard = $false
        Save-SRConfig -Config $config
        $before = @(Get-SRSnapshotFiles).Count

        Save-SRHibernateSnapshot | Should -BeNullOrEmpty
        @(Get-SRSnapshotFiles).Count | Should -Be $before
    }

    It 'still checkpoints an explicit request when the guard is off' {
        $config = Get-SRConfig
        $config.hibernateGuard = $false
        Save-SRConfig -Config $config

        $path = Save-SRHibernateSnapshot -Force
        $path | Should -Not -BeNullOrEmpty
        (Read-SRSnapshotFile -Path $path).reason | Should -Be 'hibernate'
    }

    It 'does not save a checkpoint or hibernate under -WhatIf' {
        $before = @(Get-SRSnapshotFiles).Count
        Invoke-SRHibernate -WhatIf | Should -BeNullOrEmpty
        @(Get-SRSnapshotFiles).Count | Should -Be $before
    }
}
