#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# Pause visibility, shutdown history and the pure helpers that format them.
BeforeAll {
    $script:pvPreviousHome = $env:SESSIONRECOVERY_HOME
    $env:SESSIONRECOVERY_HOME = Join-Path $TestDrive 'pause-home'
    $script:pvRoot = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $script:pvRoot 'src\SessionRecovery.psm1') -Force

    function Import-PVFunction {
        param([string]$File, [string]$Name)
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:pvRoot $File), [ref]$tokens, [ref]$errors)
        $function = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name }, $true)
        if ($null -eq $function) { throw "Function $Name not found in $File" }
        . ([scriptblock]::Create($function.Extent.Text))
    }
    # Defined in the test scope on purpose: these are the app-script helpers.
    Import-PVFunction 'src\Tray-SessionRecovery.ps1' 'Get-SRTrayPausedNoticeText'
    Import-PVFunction 'src\Studio-SessionRecovery.ps1' 'Get-StudioPauseDetail'
    Import-PVFunction 'src\Restore-Session.ps1' 'Get-RSPausedNote'
    function T { param($Key, $Default) return $Default }
    function Format-StudioDate { param($Date, $Format) return ([datetime]$Date).ToString($Format, [System.Globalization.CultureInfo]::InvariantCulture) }
}
AfterAll {
    Remove-Module SessionRecovery -Force -ErrorAction SilentlyContinue
    $env:SESSIONRECOVERY_HOME = $script:pvPreviousHome
}

Describe 'Pause marker timestamp' {
    BeforeEach {
        InModuleScope SessionRecovery {
            $script:SRPausePath = Join-Path $TestDrive 'paused.json'
            Remove-Item -LiteralPath $script:SRPausePath -Force -ErrorAction SilentlyContinue
        }
    }
    It 'records when the pause started' {
        InModuleScope SessionRecovery {
            Set-SRSnapshotPause -Paused
            $pause = Get-SRSnapshotPause
            $pause.Paused | Should -BeTrue
            $pause.ResumeAt | Should -BeNullOrEmpty
            $pause.PausedAt | Should -Not -BeNullOrEmpty
            $pause.PausedAt.Kind | Should -Be ([System.DateTimeKind]::Local)
            ([datetime]::Now - $pause.PausedAt).TotalMinutes | Should -BeLessThan 2
        }
    }
    It 'keeps a timed pause and its start' {
        InModuleScope SessionRecovery {
            Set-SRSnapshotPause -Paused -ResumeAt ((Get-Date).AddHours(2))
            $pause = Get-SRSnapshotPause
            $pause.Paused | Should -BeTrue
            $pause.ResumeAt | Should -Not -BeNullOrEmpty
            $pause.PausedAt | Should -Not -BeNullOrEmpty
        }
    }
    It 'reports a null start for markers written by older versions' {
        InModuleScope SessionRecovery {
            Set-Content -LiteralPath $script:SRPausePath -Value '{"paused":true,"resumeAt":null}' -Encoding UTF8
            $pause = Get-SRSnapshotPause
            $pause.Paused | Should -BeTrue
            $pause.PausedAt | Should -BeNullOrEmpty
        }
    }
    It 'reports not paused when there is no marker' {
        InModuleScope SessionRecovery {
            $pause = Get-SRSnapshotPause
            $pause.Paused | Should -BeFalse
            $pause.PausedAt | Should -BeNullOrEmpty
        }
    }
}

Describe 'Shutdown history' {
    BeforeEach {
        InModuleScope SessionRecovery {
            $script:SRShutdownHistoryPath = Join-Path $TestDrive 'shutdown-history.json'
            $script:SRShutdownAttemptPath = Join-Path $TestDrive 'shutdown-attempt.json'
            Remove-Item -LiteralPath $script:SRShutdownHistoryPath, $script:SRShutdownAttemptPath -Force -ErrorAction SilentlyContinue
            Mock Write-SRLog { }
        }
    }
    It 'is empty before any shutdown is recorded' {
        InModuleScope SessionRecovery {
            $summary = Get-SRShutdownHistorySummary
            $summary.Total | Should -Be 0
            $summary.Saved | Should -Be 0
            $summary.NotSaved | Should -Be 0
        }
    }
    It 'counts saved and unsaved shutdowns' {
        InModuleScope SessionRecovery {
            Add-SRShutdownHistory -Completed $true -At '2026-01-01T10:00:00.0000000Z'
            Add-SRShutdownHistory -Completed $false -At '2026-01-02T10:00:00.0000000Z'
            Add-SRShutdownHistory -Completed $true -At '2026-01-03T10:00:00.0000000Z'
            $summary = Get-SRShutdownHistorySummary
            $summary.Total | Should -Be 3
            $summary.Saved | Should -Be 2
            $summary.NotSaved | Should -Be 1
            $summary.LastSaved | Should -BeTrue
            $summary.LastAt | Should -Match '2026-01-03'
        }
    }
    It 'keeps a single entry as an array' {
        InModuleScope SessionRecovery {
            Add-SRShutdownHistory -Completed $false -At '2026-01-01T10:00:00.0000000Z'
            @(Read-SRShutdownHistory).Count | Should -Be 1
            (Get-SRShutdownHistorySummary).LastSaved | Should -BeFalse
        }
    }
    It 'keeps only the newest entries up to the limit' {
        InModuleScope SessionRecovery {
            $limit = Get-SRShutdownHistoryLimit
            $limit | Should -Be 20
            for ($i = 1; $i -le ($limit + 5); $i++) {
                Add-SRShutdownHistory -Completed ($i % 2 -eq 0) -At ('2026-01-01T10:{0:D2}:00.0000000Z' -f $i)
            }
            $entries = @(Read-SRShutdownHistory)
            $entries.Count | Should -Be $limit
            $entries[0].at | Should -Match '10:06:00'
            $entries[$entries.Count - 1].at | Should -Match ('10:{0:D2}:00' -f ($limit + 5))
        }
    }
    It 'treats an unreadable file as empty and logs a warning' {
        InModuleScope SessionRecovery {
            Set-Content -LiteralPath $script:SRShutdownHistoryPath -Value '{ not json' -Encoding UTF8
            @(Read-SRShutdownHistory).Count | Should -Be 0
            Should -Invoke Write-SRLog -ParameterFilter { $Level -eq 'WARN' } -Times 1
            (Get-SRShutdownHistorySummary).Total | Should -Be 0
        }
    }
    It 'records a completed marker when the next start reads it' {
        InModuleScope SessionRecovery {
            Set-Content -LiteralPath $script:SRShutdownAttemptPath -Value '{"completed":true,"path":"C:\\x.json","at":"2026-02-01T08:00:00.0000000Z"}' -Encoding UTF8
            $result = Get-SRLastShutdownCapture
            $result.Completed | Should -BeTrue
            $summary = Get-SRShutdownHistorySummary
            $summary.Total | Should -Be 1
            $summary.Saved | Should -Be 1
            $summary.LastAt | Should -Match '2026-02-01'
        }
    }
    It 'records an incomplete marker as not saved' {
        InModuleScope SessionRecovery {
            Set-Content -LiteralPath $script:SRShutdownAttemptPath -Value '{"completed":false,"startedAt":"2026-02-02T08:00:00.0000000Z"}' -Encoding UTF8
            $result = Get-SRLastShutdownCapture
            $result.Completed | Should -BeFalse
            $summary = Get-SRShutdownHistorySummary
            $summary.Total | Should -Be 1
            $summary.NotSaved | Should -Be 1
            $summary.LastAt | Should -Match '2026-02-02'
        }
    }
    It 'records nothing when there is no marker' {
        InModuleScope SessionRecovery {
            Get-SRLastShutdownCapture | Should -BeNullOrEmpty
            (Get-SRShutdownHistorySummary).Total | Should -Be 0
        }
    }
}

Describe 'Diagnostics exposes pause and shutdown state' {
    It 'includes Paused, PausedAt, ResumeAt and ShutdownSnapshots' {
        InModuleScope SessionRecovery {
            $script:SRPausePath = Join-Path $TestDrive 'diag-paused.json'
            $script:SRShutdownHistoryPath = Join-Path $TestDrive 'diag-shutdown-history.json'
            Remove-Item -LiteralPath $script:SRPausePath, $script:SRShutdownHistoryPath -Force -ErrorAction SilentlyContinue
            Mock Write-SRLog { }
            Set-SRSnapshotPause -Paused
            Add-SRShutdownHistory -Completed $true -At '2026-03-01T08:00:00.0000000Z'
            $diagnostics = Get-SRDiagnostics
            $diagnostics.Paused | Should -BeTrue
            $diagnostics.PausedAt | Should -Not -BeNullOrEmpty
            $diagnostics.PSObject.Properties.Name | Should -Contain 'ResumeAt'
            $diagnostics.ShutdownSnapshots.Total | Should -Be 1
            $diagnostics.ShutdownSnapshots.Saved | Should -Be 1
            Set-SRSnapshotPause
            (Get-SRDiagnostics).Paused | Should -BeFalse
        }
    }
}

Describe 'Pause text helpers' {
    BeforeAll {
        $script:since = [datetime]'2026-04-05T09:30:00'
        $script:until = [datetime]'2026-04-05T17:45:00'
    }
    It 'tray notice is empty when not paused' {
        Get-SRTrayPausedNoticeText -Pause ([pscustomobject]@{ Paused = $false; PausedAt = $null }) | Should -Be ''
        Get-SRTrayPausedNoticeText -Pause $null | Should -Be ''
    }
    It 'tray notice names the start time or says it is unknown' {
        Get-SRTrayPausedNoticeText -Pause ([pscustomobject]@{ Paused = $true; PausedAt = $script:since }) | Should -Match '2026'
        Get-SRTrayPausedNoticeText -Pause ([pscustomobject]@{ Paused = $true; PausedAt = $null }) | Should -Match 'unknown time'
    }
    It 'studio detail is empty when not paused' {
        Get-StudioPauseDetail -Pause ([pscustomobject]@{ Paused = $false }) | Should -Be ''
    }
    It 'studio detail shows an automatic resume time for timed pauses' {
        $text = Get-StudioPauseDetail -Pause ([pscustomobject]@{ Paused = $true; PausedAt = $script:since; ResumeAt = $script:until })
        $text | Should -Match 'Apr 5, 09:30'
        $text | Should -Match 'resumes automatically at Apr 5, 17:45'
    }
    It 'studio detail says it stays paused when there is no resume time' {
        $text = Get-StudioPauseDetail -Pause ([pscustomobject]@{ Paused = $true; PausedAt = $script:since; ResumeAt = $null })
        $text | Should -Match 'stays paused'
    }
    It 'restore note is empty when running and informative when paused' {
        Mock Get-SRSnapshotPause { [pscustomobject]@{ Paused = $false; PausedAt = $null; ResumeAt = $null } }
        Get-RSPausedNote | Should -Be ''
        Mock Get-SRSnapshotPause { [pscustomobject]@{ Paused = $true; PausedAt = $script:since; ResumeAt = $null } }
        Get-RSPausedNote | Should -Match 'Apr 5, 09:30'
        Mock Get-SRSnapshotPause { [pscustomobject]@{ Paused = $true; PausedAt = $null; ResumeAt = $null } }
        Get-RSPausedNote | Should -Match 'paused'
    }
}

Describe 'Pause strings' {
    BeforeDiscovery {
        $script:pvKeys = @('BadgePaused','HeroPaused','HeroPausedLine','HeroPausedUntilLine','PausedSinceUnknown','TrayPausedAtStart','RstPausedShort','RstPausedShortUnknown','DiagPause','DiagPauseOn','DiagPauseOff','DiagShutdownSnapshots','DiagShutdownSnapshotsDetail','DiagShutdownSnapshotsNone')
        $script:pvLanguages = @('en','ar','fr','es','de','pt','ru','zh','tr')
    }
    It 'has every new key in <_>' -ForEach $script:pvLanguages {
        $strings = Get-SRStrings -Language $_
        foreach ($key in @('BadgePaused','HeroPaused','HeroPausedLine','HeroPausedUntilLine','PausedSinceUnknown','TrayPausedAtStart','RstPausedShort','RstPausedShortUnknown','DiagPause','DiagPauseOn','DiagPauseOff','DiagShutdownSnapshots','DiagShutdownSnapshotsDetail','DiagShutdownSnapshotsNone')) {
            $strings[$key] | Should -Not -BeNullOrEmpty -Because "$_ needs '$key'"
        }
    }
    It 'keeps format placeholders in <_>' -ForEach $script:pvLanguages {
        $strings = Get-SRStrings -Language $_
        $strings['HeroPausedLine'] | Should -Match '\{0\}'
        $strings['HeroPausedUntilLine'] | Should -Match '\{0\}'
        $strings['HeroPausedUntilLine'] | Should -Match '\{1\}'
        $strings['TrayPausedAtStart'] | Should -Match '\{0\}'
        $strings['RstPausedShort'] | Should -Match '\{0\}'
        $strings['DiagShutdownSnapshotsDetail'] | Should -Match '\{0\}'
        $strings['DiagShutdownSnapshotsDetail'] | Should -Match '\{1\}'
    }
}
