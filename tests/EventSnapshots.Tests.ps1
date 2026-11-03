#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# Synthetic event timestamps and fixture-only persistence: no OS event delivery.
BeforeDiscovery {
    $previousHome = $env:SESSIONRECOVERY_HOME
    try {
        $env:SESSIONRECOVERY_HOME = Join-Path ([System.IO.Path]::GetTempPath()) ('sr-event-discovery-' + [guid]::NewGuid().ToString('N'))
        Import-Module (Join-Path $PSScriptRoot '..\src\SessionRecovery.psm1') -Force
    } finally { $env:SESSIONRECOVERY_HOME = $previousHome }
}
BeforeAll {
    $script:eventPreviousHome = $env:SESSIONRECOVERY_HOME
    $env:SESSIONRECOVERY_HOME = Join-Path $TestDrive 'event-home'
    Import-Module (Join-Path $PSScriptRoot '..\src\SessionRecovery.psm1') -Force
}
AfterAll {
    Remove-Module SessionRecovery -Force -ErrorAction SilentlyContinue
    $env:SESSIONRECOVERY_HOME = $script:eventPreviousHome
}

Describe 'Event snapshot coordinator' {
    BeforeEach { $state = New-SREventSnapshotState }

    It 'waits for two seconds of quiet and consumes a generation once' {
        Add-SREventSnapshotSignal $state window 0
        Add-SREventSnapshotSignal $state display 1500
        Get-SREventSnapshotRequest $state 3499 | Should -BeNullOrEmpty
        $request = Get-SREventSnapshotRequest $state 3500
        $request.Reason | Should -Be 'event'
        $request.Shutdown | Should -BeFalse
        $request.Generation | Should -Be 1
        Get-SREventSnapshotRequest $state 9000 | Should -BeNullOrEmpty
        Complete-SREventSnapshotRequest $state 9000
        Get-SREventSnapshotRequest $state 40000 | Should -BeNullOrEmpty
    }

    It 'caps a continuous storm at ten seconds' {
        foreach ($time in 0,1000,2000,3000,4000,5000,6000,7000,8000,9000,9999) {
            Add-SREventSnapshotSignal $state window $time
            Get-SREventSnapshotRequest $state $time | Should -BeNullOrEmpty
        }
        (Get-SREventSnapshotRequest $state 10000).Reason | Should -Be 'event'
    }

    It 'keeps one pending generation during busy and measures cooldown from attempted save' {
        Add-SREventSnapshotSignal $state window 0
        (Get-SREventSnapshotRequest $state 2000).Generation | Should -Be 1
        foreach ($time in 3000,4000,5000) { Add-SREventSnapshotSignal $state resume $time }
        $state.Generation | Should -Be 2
        Get-SREventSnapshotRequest $state 100000 | Should -BeNullOrEmpty
        Complete-SREventSnapshotRequest $state 6000
        Get-SREventSnapshotRequest $state 31999 | Should -BeNullOrEmpty
        Get-SREventSnapshotRequest $state 32000 -Busy $true | Should -BeNullOrEmpty
        (Get-SREventSnapshotRequest $state 32000).Generation | Should -Be 2
        Complete-SREventSnapshotRequest $state 32000
        Get-SREventSnapshotRequest $state 64000 | Should -BeNullOrEmpty
    }

    It 'clears disabled and paused noise without resetting cooldown' {
        Add-SREventSnapshotSignal $state window 0
        $null = Get-SREventSnapshotRequest $state 2000
        Complete-SREventSnapshotRequest $state 2000
        Add-SREventSnapshotSignal $state window 3000
        Get-SREventSnapshotRequest $state 5000 -Enabled $false | Should -BeNullOrEmpty
        Get-SREventSnapshotRequest $state 40000 | Should -BeNullOrEmpty
        Add-SREventSnapshotSignal $state window 6000 -Paused $true
        Get-SREventSnapshotRequest $state 40000 | Should -BeNullOrEmpty
        Add-SREventSnapshotSignal $state window 7000
        Get-SREventSnapshotRequest $state 31999 | Should -BeNullOrEmpty
        (Get-SREventSnapshotRequest $state 32000).Reason | Should -Be 'event'
    }

    It 'deduplicates final signals, bypasses debounce and cooldown, and rearms on cancellation' {
        Add-SREventSnapshotSignal $state window 0
        $null = Get-SREventSnapshotRequest $state 2000
        Complete-SREventSnapshotRequest $state 2000
        Add-SREventSnapshotSignal $state session-ending 2001
        Add-SREventSnapshotSignal $state session-ending 2002
        $request = Get-SREventSnapshotRequest $state 2002
        $request.Shutdown | Should -BeTrue
        $request.Reason | Should -Be 'session-ending'
        Complete-SREventSnapshotRequest $state 2003
        Add-SREventSnapshotSignal $state session-ending 2004
        Add-SREventSnapshotSignal $state window 2004
        Get-SREventSnapshotRequest $state 40000 | Should -BeNullOrEmpty
        Add-SREventSnapshotSignal $state session-ending-cancelled 40001
        Add-SREventSnapshotSignal $state session-ending 40002
        (Get-SREventSnapshotRequest $state 40002).Shutdown | Should -BeTrue
    }

    It 'never competes with a busy save and cancels a deferred final request' {
        Add-SREventSnapshotSignal $state window 0
        $null = Get-SREventSnapshotRequest $state 2000
        Add-SREventSnapshotSignal $state session-ending 2001
        Get-SREventSnapshotRequest $state 2001 | Should -BeNullOrEmpty
        Complete-SREventSnapshotRequest $state 2002
        Get-SREventSnapshotRequest $state 2002 -Busy $true | Should -BeNullOrEmpty
        Add-SREventSnapshotSignal $state session-ending-cancelled 2003
        Get-SREventSnapshotRequest $state 2004 | Should -BeNullOrEmpty
        Add-SREventSnapshotSignal $state session-ending 2005
        (Get-SREventSnapshotRequest $state 2005).Shutdown | Should -BeTrue
    }

    It 'drops a paused final request and does not replay it when resumed' {
        Add-SREventSnapshotSignal $state session-ending 0 -Paused $true
        Get-SREventSnapshotRequest $state 1 | Should -BeNullOrEmpty
        Add-SREventSnapshotSignal $state session-ending 2
        Get-SREventSnapshotRequest $state 2 -Enabled $false | Should -BeNullOrEmpty
        Get-SREventSnapshotRequest $state 3 | Should -BeNullOrEmpty
        Add-SREventSnapshotSignal $state window 4
        (Get-SREventSnapshotRequest $state 2004).Reason | Should -Be 'event'
    }

    It 'reset discards noise but cannot release an active reservation' {
        Add-SREventSnapshotSignal $state window 0
        $null = Get-SREventSnapshotRequest $state 2000
        Add-SREventSnapshotSignal $state resume 3000
        Reset-SREventSnapshotState $state
        $state.InFlight | Should -BeTrue
        $state.Pending | Should -BeFalse
        Complete-SREventSnapshotRequest $state 4000
        Get-SREventSnapshotRequest $state 40000 | Should -BeNullOrEmpty
    }
}

Describe 'Shutdown snapshot persistence' {
    InModuleScope SessionRecovery {
        BeforeEach {
            $script:SRSnapshotDir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $script:fixtureConfig = [pscustomobject]@{
                captureThumbnails = $true; compressSnapshots = $false; encryptSnapshots = $false
                autoExportFolder = (Join-Path $TestDrive 'must-not-export')
            }
            Mock Get-SRConfig { $script:fixtureConfig }
            Mock Write-SRLog { }
            Mock New-SRSnapshot {
                [pscustomobject]@{
                    capturedAt = '2026-01-01T12:00:00.000Z'; stateHash = 'fixture'
                    stats = [pscustomobject]@{ apps=0; folders=0; browsers=0; tabs=0 }
                }
            }
            Mock New-SRThumbnailSet { throw 'Unexpected thumbnails' }
            Mock Invoke-SRRetention { throw 'Unexpected retention' }
            Mock Test-SRAutoSnapshotBlocked { throw 'Unexpected resource guard' }
            Mock Get-SRIdleSeconds { throw 'Unexpected idle guard' }
            Mock Test-SRFullscreenActive { throw 'Unexpected fullscreen guard' }
            Mock Start-Sleep { throw 'Unexpected wait' }
            Mock Copy-Item { throw 'Unexpected export' }
        }

        It 'publishes a forced final snapshot and skips optional work' {
            $path = Save-SRSnapshot -Shutdown
            Test-Path -LiteralPath $path | Should -BeTrue
            (Read-SRSnapshotFile -Path $path).stateHash | Should -Be 'fixture'
            Should -Invoke New-SRSnapshot -Times 1 -Exactly -ParameterFilter { $BudgetMilliseconds -eq 2000 -and $Reason -eq 'session-ending' }
            Should -Invoke New-SRThumbnailSet -Times 0
            Should -Invoke Invoke-SRRetention -Times 0
            Should -Invoke Copy-Item -Times 0
            Should -Invoke Start-Sleep -Times 0
            @(Get-ChildItem $script:SRSnapshotDir -Force -Filter '*.tmp').Count | Should -Be 0
        }

        It 'returns immediately on a held lock without capturing or sleeping' {
            New-Item -ItemType Directory $script:SRSnapshotDir -Force | Out-Null
            $held = [System.IO.File]::Open((Join-Path $script:SRSnapshotDir '.save.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
            try { Save-SRSnapshot -Shutdown | Should -BeNullOrEmpty } finally { $held.Dispose() }
            Should -Invoke New-SRSnapshot -Times 0
            Should -Invoke Start-Sleep -Times 0
        }

        It 'does not publish a partial snapshot on timeout and releases the lock' {
            Mock New-SRSnapshot { throw [System.TimeoutException]::new('synthetic timeout') }
            { Save-SRSnapshot -Shutdown } | Should -Throw '*synthetic timeout*'
            @(Get-ChildItem $script:SRSnapshotDir -Force -File).Count | Should -Be 0
            $probe = [System.IO.File]::Open((Join-Path $script:SRSnapshotDir '.save.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
            $probe.Dispose()
        }

        It 'preserves compressed payloads' {
            $script:fixtureConfig.compressSnapshots = $true
            $path = Save-SRSnapshot -Shutdown
            $path | Should -Match '\.json\.gz$'
            (Read-SRSnapshotFile -Path $path).stateHash | Should -Be 'fixture'
        }

        It 'preserves encryption after compression without publishing plaintext' {
            $script:fixtureConfig.compressSnapshots = $true
            $script:fixtureConfig.encryptSnapshots = $true
            Mock Protect-SRSnapshotBytes {
                $Bytes[0] | Should -Be 31
                $Bytes[1] | Should -Be 139
                return [byte[]]@(91,92,93)
            }
            $path = Save-SRSnapshot -Shutdown
            [System.IO.File]::ReadAllBytes($path) | Should -Be @(91,92,93)
            Should -Invoke Protect-SRSnapshotBytes -Times 1 -Exactly
        }

        It 'does not publish if encryption fails' {
            $script:fixtureConfig.encryptSnapshots = $true
            Mock Protect-SRSnapshotBytes { throw 'synthetic encryption failure' }
            { Save-SRSnapshot -Shutdown } | Should -Throw '*synthetic encryption failure*'
            @(Get-ChildItem $script:SRSnapshotDir -Force -File).Count | Should -Be 0
        }
    }
}

Describe 'Cooperative collection budget and privacy' {
    InModuleScope SessionRecovery {
        BeforeEach {
            Mock Get-SRSnapshotWindows { @() }
            Mock Get-SRProcessMap { @{} }
            Mock Get-SRConfig {
                [pscustomobject]@{
                    captureBrowserTabs=$true; captureMediaPlayers=$false; captureDevWorkspaces=$false
                    restoreVirtualDesktops=$false; excludeApps=@('secret*'); excludeFolders=@('C:\private*')
                    excludeUrls=@('*private*'); redactUrls=$true
                }
            }
            Mock Get-SRApplications {
                @([pscustomobject]@{name='secret-app'; exe='secret.exe'},
                  [pscustomobject]@{name='safe'; exe='safe.exe'; windows=@(); args=@('https://example.test/?token=secret')})
            }
            Mock Get-SRExplorerFolders { @('C:\private\data','C:\public') }
            Mock Get-SRBrowsers {
                @([pscustomobject]@{key='browser'; name='browser'; exe='browser.exe'; profiles=@(
                    [pscustomobject]@{tabs=@([pscustomobject]@{url='https://private.test'},
                        [pscustomobject]@{url='https://example.test/?token=secret'; title='fixture'})})})
            }
            Mock Get-SRLogonTime { [datetime]'2026-01-01' }
            Mock Get-SRRemoteSessions { @() }
            Mock Get-SRMonitors { @() }
            Mock Get-SRSystemProfile { $null }
            Mock Get-SRInstallationId { 'fixture-installation' }
        }

        It 'enforces the deadline at the exact boundary with a synthetic clock' {
            { Assert-SRSnapshotBudget -Clock ([pscustomobject]@{ElapsedMilliseconds=1999}) -BudgetMilliseconds 2000 } | Should -Not -Throw
            { Assert-SRSnapshotBudget -Clock ([pscustomobject]@{ElapsedMilliseconds=2000}) -BudgetMilliseconds 2000 } | Should -Throw '*time budget*'
            { Assert-SRSnapshotBudget -Clock ([pscustomobject]@{ElapsedMilliseconds=99999}) -BudgetMilliseconds 0 } | Should -Not -Throw
        }

        It 'checks between collectors and does not continue collecting after timeout' {
            Mock Assert-SRSnapshotBudget { throw [System.TimeoutException]::new('synthetic deadline') }
            { New-SRSnapshot -BudgetMilliseconds 2000 } | Should -Throw '*synthetic deadline*'
            Should -Invoke Get-SRSnapshotWindows -Times 1
            Should -Invoke Get-SRProcessMap -Times 0
            Should -Invoke Get-SRApplications -Times 0
            Should -Invoke Get-SRBrowsers -Times 0
        }

        It 'keeps exclusion and URL privacy rules in budgeted captures' {
            # Timing thresholds are tested above with a synthetic clock; do not
            # make this privacy assertion depend on CI machine speed.
            Mock Assert-SRSnapshotBudget { }
            $snapshot = New-SRSnapshot -BudgetMilliseconds 2000
            Should -Invoke Assert-SRSnapshotBudget -ParameterFilter { $BudgetMilliseconds -eq 2000 }
            @($snapshot.apps).Count | Should -Be 1
            $snapshot.apps[0].name | Should -Be 'safe'
            $snapshot.apps[0].args[0] | Should -Be 'https://example.test/'
            @($snapshot.explorer).Count | Should -Be 1
            $snapshot.explorer[0] | Should -Be 'C:\public'
            @($snapshot.browsers[0].profiles[0].tabs).Count | Should -Be 1
            $snapshot.browsers[0].profiles[0].tabs[0].url | Should -Be 'https://example.test/'
            $snapshot.stateHash | Should -Not -BeNullOrEmpty
        }
    }
}
