#requires -Version 5.1
# Tests load function ASTs only: never execute the tray entry point or capture a desktop.
BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    $script:trayPath = Join-Path $root 'src\Tray-SessionRecovery.ps1'
    $tokens = $null; $errors = $null
    $script:trayAst = [System.Management.Automation.Language.Parser]::ParseFile($script:trayPath, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw ($errors | Out-String) }
    $names = @('Initialize-SRTrayNative','Initialize-SRTrayWorker','Start-SRTrayCapture','Complete-SRTrayCapture','Invoke-SRTraySnapshot','Request-SRTrayShutdown','Cancel-SRTrayShutdown','Get-SRTrayClock','Invoke-SRTrayEventPoll','Request-SRTraySuspend','Stop-SRTrayWorker')
    foreach ($name in $names) {
        $function = $script:trayAst.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
        . ([scriptblock]::Create($function.Extent.Text))
    }
    $moduleAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'src\SessionRecovery.psm1'), [ref]$tokens, [ref]$errors)
    foreach ($name in @('New-SREventSnapshotState','Reset-SREventSnapshotState','Add-SREventSnapshotSignal','Get-SREventSnapshotRequest','Complete-SREventSnapshotRequest')) {
        $function = $moduleAst.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
        . ([scriptblock]::Create($function.Extent.Text))
    }
    Add-Type -AssemblyName System.Windows.Forms
    Initialize-SRTrayNative
    function Show-SRTrayBalloon { param($Text, $Icon, $Timeout) }
    function Update-SRTrayStatus { }
    function Write-SRLog { param($Level, $Message) }
    function T { param($Key, $Default) return $Default }
    function Test-SRTrayEventSnapshots { return $script:eventCaptureEnabled }
    function Test-SRTrayHibernateGuard { return $true }
    function Invoke-SRTrayPowerCheckpoint { param($Source) }
}

Describe 'Tray native event boundaries' {
    It 'accepts only selected foreign top-level window notifications' {
        foreach ($kind in @(0x8001,0x8002,0x8003,0x800C)) {
            [SessionRecovery.TrayWindowEvents]::AcceptMetadata($kind,0,0,42,7,$true,$false) | Should -BeTrue
        }
        [SessionRecovery.TrayWindowEvents]::AcceptMetadata(0x8002,0,0,7,7,$true,$false) | Should -BeFalse
        [SessionRecovery.TrayWindowEvents]::AcceptMetadata(0x8002,-4,0,42,7,$true,$false) | Should -BeFalse
        [SessionRecovery.TrayWindowEvents]::AcceptMetadata(0x8002,0,1,42,7,$true,$false) | Should -BeFalse
        [SessionRecovery.TrayWindowEvents]::AcceptMetadata(0x800C,0,0,42,7,$false,$false) | Should -BeFalse
        [SessionRecovery.TrayWindowEvents]::AcceptMetadata(0x8000,0,0,42,7,$true,$false) | Should -BeFalse
    }
    It 'recognizes destroyed known top-level handles, but not unknown child handles' {
        [SessionRecovery.TrayWindowEvents]::AcceptMetadata(0x8001,0,0,0,7,$false,$true) | Should -BeTrue
        [SessionRecovery.TrayWindowEvents]::AcceptMetadata(0x8001,0,0,0,7,$false,$false) | Should -BeFalse
    }
    It 'deduplicates native query/end notifications and resets after cancellation' {
        $monitor = New-Object SessionRecovery.TrayPowerMonitor
        $script:requests = 0; $script:cancellations = 0
        $requested = [System.EventHandler]{ $script:requests++ }
        $cancelled = [System.EventHandler]{ $script:cancellations++ }
        try {
            $monitor.add_ShutdownRequested($requested)
            $monitor.add_ShutdownCancelled($cancelled)
            $monitor.SignalSessionEnd($true,$false)
            $monitor.SignalSessionEnd($false,$true)
            $script:requests | Should -Be 1
            $monitor.SignalSessionEnd($false,$false)
            $script:cancellations | Should -Be 1
            $monitor.SignalSessionEnd($true,$false)
            $script:requests | Should -Be 2
        } finally { $monitor.Dispose(); $monitor.Dispose() }
    }
    It 'dispatches suspend immediately through the owning WndProc and suppresses duplicate fallback' {
        $monitor = New-Object SessionRecovery.TrayPowerMonitor
        $script:suspends = 0
        $handler = [System.EventHandler]{ $script:suspends++ }
        try {
            $monitor.add_SuspendRequested($handler)
            $monitor.SignalPowerMode([Microsoft.Win32.PowerModes]::Suspend)
            $message = [System.Windows.Forms.Message]::Create($monitor.Handle,0x0218,[IntPtr]4,[IntPtr]::Zero)
            $wndProc = $monitor.GetType().GetMethod('WndProc',[Reflection.BindingFlags]'Instance,NonPublic')
            $arguments = [object[]]@($message)
            [void]$wndProc.Invoke($monitor,$arguments)
            $script:suspends | Should -Be 1
            $arguments[0].Result.ToInt64() | Should -Be 1
            $monitor.SignalPowerMode([Microsoft.Win32.PowerModes]::Suspend)
            $monitor.SignalNativeSuspend()
            $monitor.DrainSystemSignals()[1] | Should -BeFalse
            $script:suspends | Should -Be 1
            $monitor.SignalPowerMode([Microsoft.Win32.PowerModes]::Resume)
            $monitor.SignalNativeSuspend()
            $script:suspends | Should -Be 2
        } finally { $monitor.Dispose() }
    }
    It 'discards suspend fallback after resume or expiry and consumes fresh fallback once' {
        $monitor = New-Object SessionRecovery.TrayPowerMonitor
        try {
            $monitor.SignalPowerMode([Microsoft.Win32.PowerModes]::Suspend)
            $monitor.SignalPowerMode([Microsoft.Win32.PowerModes]::Resume)
            $monitor.DrainSystemSignals()[1] | Should -BeFalse
            $monitor.SignalPowerMode([Microsoft.Win32.PowerModes]::Suspend)
            $field = $monitor.GetType().GetField('suspendSignalAt',[Reflection.BindingFlags]'Instance,NonPublic')
            $field.SetValue($monitor,[long]0)
            $monitor.DrainSystemSignals()[1] | Should -BeFalse
            $monitor.SignalPowerMode([Microsoft.Win32.PowerModes]::Suspend)
            $monitor.DrainSystemSignals()[1] | Should -BeTrue
            $monitor.SignalPowerMode([Microsoft.Win32.PowerModes]::Suspend)
            $monitor.DrainSystemSignals()[1] | Should -BeFalse
        } finally { $monitor.Dispose() }
    }
    It 'can dispose an unstarted hook owner repeatedly' {
        $events = New-Object SessionRecovery.TrayWindowEvents
        $events.Dispose(); $events.Dispose()
        @($events.Drain())[0] | Should -Be 0
    }
}

Describe 'Immediate suspend request' {
    BeforeEach {
        $script:exiting = $false; $script:sessionEnding = $false
        $script:paused = $false; $script:eventCaptureEnabled = $true
        Mock Invoke-SRTrayPowerCheckpoint { }
        Mock Invoke-SRTraySnapshot { }
    }
    It 'dispatches the checkpoint immediately rather than queuing a timer flag' {
        Request-SRTraySuspend
        Should -Invoke Invoke-SRTrayPowerCheckpoint -Times 1 -Exactly -ParameterFilter { $Source -eq 'suspend' }
    }
    It 'dispatches an ordinary async capture when hibernate guard is disabled' {
        Mock Test-SRTrayHibernateGuard { return $false }
        Request-SRTraySuspend
        Should -Invoke Invoke-SRTraySnapshot -Times 1 -Exactly
        Should -Invoke Invoke-SRTrayPowerCheckpoint -Times 0 -Exactly
    }
    It 'respects event disable and pause' {
        $script:paused = $true
        Request-SRTraySuspend
        $script:paused = $false; $script:eventCaptureEnabled = $false
        Request-SRTraySuspend
        Should -Invoke Invoke-SRTrayPowerCheckpoint -Times 0 -Exactly
    }
}

Describe 'Nonblocking tray worker cleanup' {
    BeforeEach {
        $script:stopRequested = 0; $script:syncStop = 0; $script:disposed = 0
        $pipeline = [pscustomobject]@{}
        $pipeline | Add-Member ScriptMethod BeginStop { param($callback,$state) $script:stopRequested++ }
        $pipeline | Add-Member ScriptMethod Stop { $script:syncStop++; throw 'Synchronous Stop must not run.' }
        $pipeline | Add-Member ScriptMethod Dispose { $script:disposed++; throw 'Active pipeline must not be disposed.' }
        $script:snapshotRunspace = [pscustomobject]@{}
        $script:snapshotRunspace | Add-Member ScriptMethod Dispose { $script:disposed++ }
        $script:snapshotJob = [pscustomobject]@{ Pipeline = $pipeline; Handle = [pscustomobject]@{ IsCompleted = $false } }
        $script:snapshotBusy = $true
    }
    AfterEach { $script:snapshotJob = $null; $script:snapshotRunspace = $null; $script:snapshotBusy = $false }
    It 'uses BeginStop without synchronous disposal for both normal and shutdown exits' {
        foreach ($ending in @($false,$true)) {
            $script:sessionEnding = $ending
            Stop-SRTrayWorker
        }
        $script:stopRequested | Should -Be 2
        $script:syncStop | Should -Be 0
        $script:disposed | Should -Be 0
        $script:snapshotBusy | Should -BeTrue
        $script:snapshotJob | Should -Not -BeNullOrEmpty
    }
    It 'disposes the idle runspace when no active pipeline exists' {
        $script:snapshotJob = $null; $script:snapshotBusy = $false
        Stop-SRTrayWorker
        $script:disposed | Should -Be 1
        $script:snapshotRunspace | Should -BeNullOrEmpty
    }
}

Describe 'Tray shutdown dispatch' {
    BeforeEach {
        $script:eventState = New-SREventSnapshotState
        $script:sessionEnding = $false; $script:shutdownAttempted = $false
        $script:paused = $false; $script:eventCaptureEnabled = $true
        $script:snapshotBusy = $false; $script:exiting = $false
        Mock Start-SRTrayCapture { return $true }
    }
    It 'dispatches immediately once, without waiting for the poll timer' {
        Request-SRTrayShutdown
        Request-SRTrayShutdown
        Should -Invoke Start-SRTrayCapture -Times 1 -Exactly -ParameterFilter { $Operation -eq 'Shutdown' }
        $script:sessionEnding | Should -BeTrue
        $script:eventState.InFlight | Should -BeTrue
    }
    It 'does not queue a competing shutdown capture behind a busy worker' {
        $script:snapshotBusy = $true
        Request-SRTrayShutdown
        $script:snapshotBusy = $false
        Request-SRTrayShutdown
        Should -Invoke Start-SRTrayCapture -Times 0 -Exactly
        $script:eventState.SessionEnding | Should -BeFalse
    }
    It 'honors pause and event disable even in task monitor mode' {
        $script:ownsSnapshots = $false; $script:taskMode = $true
        $script:paused = $true
        Request-SRTrayShutdown
        Cancel-SRTrayShutdown
        $script:paused = $false; $script:eventCaptureEnabled = $false
        Request-SRTrayShutdown
        Should -Invoke Start-SRTrayCapture -Times 0 -Exactly
    }
    It 'allows event capture in task monitor mode' {
        $script:ownsSnapshots = $false; $script:taskMode = $true
        Request-SRTrayShutdown
        Should -Invoke Start-SRTrayCapture -Times 1 -Exactly
    }
    It 'cancellation permits a later shutdown and preserves active work' {
        Request-SRTrayShutdown
        Cancel-SRTrayShutdown
        $script:sessionEnding | Should -BeFalse
        $script:eventState.InFlight | Should -BeTrue
        Complete-SREventSnapshotRequest -State $script:eventState -NowMilliseconds (Get-SRTrayClock)
        Request-SRTrayShutdown
        Should -Invoke Start-SRTrayCapture -Times 2 -Exactly
    }
    It 'releases reservation when dispatch fails' {
        Mock Start-SRTrayCapture { return $false }
        Request-SRTrayShutdown
        $script:eventState.InFlight | Should -BeFalse
    }
}

Describe 'Tray poll policy integration' {
    BeforeEach {
        $script:eventState = New-SREventSnapshotState
        $script:sessionEnding = $false; $script:exiting = $false
        $script:snapshotBusy = $false; $script:snapshotJob = $null
        $script:paused = $false; $script:eventCaptureEnabled = $true
        $script:ownsSnapshots = $false; $script:taskMode = $true
        $script:powerWindow = $null
        $script:windowEvents = [pscustomobject]@{}
        $script:windowEvents | Add-Member -MemberType ScriptMethod -Name Drain -Value { return [long[]]@(1000,1100) }
        Mock Get-SRTrayClock { return [long]4000 }
        Mock Start-SRTrayCapture { return $true }
    }
    It 'dispatches debounced changes in task monitor mode' {
        Invoke-SRTrayEventPoll
        Should -Invoke Start-SRTrayCapture -Times 1 -Exactly -ParameterFilter { $Operation -eq 'Automatic' }
    }
    It 'retains one pending generation while busy and respects cooldown after release' {
        $script:snapshotBusy = $true
        Invoke-SRTrayEventPoll
        Invoke-SRTrayEventPoll
        $script:eventState.Pending | Should -BeTrue
        $script:eventState.Generation | Should -Be 1
        Should -Invoke Start-SRTrayCapture -Times 0 -Exactly
        $script:windowEvents = $null
        $script:snapshotBusy = $false
        $script:eventState.LastAttempt = [long]3000
        Invoke-SRTrayEventPoll
        Should -Invoke Start-SRTrayCapture -Times 0 -Exactly
        Mock Get-SRTrayClock { return [long]33000 }
        Invoke-SRTrayEventPoll
        Should -Invoke Start-SRTrayCapture -Times 1 -Exactly
    }
    It 'discards dirty notifications while disabled or paused' {
        $script:paused = $true
        Invoke-SRTrayEventPoll
        $script:eventState.Pending | Should -BeFalse
        $script:paused = $false; $script:eventCaptureEnabled = $false
        Invoke-SRTrayEventPoll
        $script:eventState.Pending | Should -BeFalse
        Should -Invoke Start-SRTrayCapture -Times 0 -Exactly
    }
    It 'blocks ordinary polling throughout session ending' {
        $script:sessionEnding = $true
        Invoke-SRTrayEventPoll
        Should -Invoke Start-SRTrayCapture -Times 0 -Exactly
        $script:eventState.Pending | Should -BeFalse
    }
    It 'does not force or dispatch an interval capture during the automatic cooldown' {
        $script:eventState.LastAttempt = [long]3000
        Invoke-SRTraySnapshot
        Should -Invoke Start-SRTrayCapture -Times 0 -Exactly
        Invoke-SRTraySnapshot -Manual
        Should -Invoke Start-SRTrayCapture -Times 1 -Exactly -ParameterFilter { $Operation -eq 'Manual' }
    }
}

Describe 'Persistent asynchronous tray capture worker' {
    BeforeAll {
        $script:fakeModule = Join-Path $TestDrive 'FakeSnapshot.psm1'
        @'
function Save-SRSnapshot {
    param([switch]$Force,[switch]$Shutdown)
    Start-Sleep -Milliseconds 150
    if ($global:FakeSnapshotNull) { return $null }
    if ($global:FakeSnapshotEmpty) { return '   ' }
    [pscustomobject]@{ Force = [bool]$Force; Shutdown = [bool]$Shutdown; Thread = [Threading.Thread]::CurrentThread.ManagedThreadId; Apartment = [string][Threading.Thread]::CurrentThread.ApartmentState }
}
Export-ModuleMember -Function Save-SRSnapshot
'@ | Set-Content -LiteralPath $script:fakeModule -Encoding UTF8
        Initialize-SRTrayWorker -ModulePath $script:fakeModule
    }
    BeforeEach {
        $script:exiting = $false; $script:sessionEnding = $false
        $script:snapshotBusy = $false; $script:snapshotJob = $null
        $script:eventState = New-SREventSnapshotState
        $script:snapshotFailures = 0
    }
    AfterEach {
        if ($null -ne $script:snapshotJob) {
            $script:snapshotJob.Pipeline.Stop(); $script:snapshotJob.Pipeline.Dispose()
            $script:snapshotJob = $null; $script:snapshotBusy = $false
        }
    }
    AfterAll { $script:snapshotRunspace.Dispose(); $script:snapshotRunspace = $null }
    It 'uses STA ReuseThread and serializes automatic/manual/shutdown pipelines' {
        $script:snapshotRunspace.ThreadOptions | Should -Be ([System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread)
        $threads = @()
        foreach ($operation in @('Automatic','Manual','Shutdown')) {
            $script:sessionEnding = $operation -eq 'Shutdown'
            Start-SRTrayCapture -Operation $operation | Should -BeTrue
            Start-SRTrayCapture -Operation Manual | Should -BeFalse
            $deadline = [datetime]::UtcNow.AddSeconds(5)
            while (-not $script:snapshotJob.Handle.IsCompleted -and [datetime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 20 }
            $script:snapshotJob.Handle.IsCompleted | Should -BeTrue
            $output = @($script:snapshotJob.Pipeline.EndInvoke($script:snapshotJob.Handle))
            $output[0].Force | Should -Be ($operation -eq 'Manual')
            $output[0].Shutdown | Should -Be ($operation -eq 'Shutdown')
            $output[0].Apartment | Should -Be 'STA'
            $threads += $output[0].Thread
            $script:snapshotJob.Pipeline.Dispose(); $script:snapshotJob = $null; $script:snapshotBusy = $false
        }
        @($threads | Select-Object -Unique).Count | Should -Be 1
    }
    It 'reports skipped rather than success when Save-SRSnapshot returns null or an empty path' {
        Mock Show-SRTrayBalloon { }
        foreach ($mode in @('FakeSnapshotNull','FakeSnapshotEmpty')) {
            $script:snapshotRunspace.SessionStateProxy.SetVariable($mode,$true)
            try {
                Start-SRTrayCapture -Operation Manual | Should -BeTrue
                $deadline = [datetime]::UtcNow.AddSeconds(5)
                while (-not $script:snapshotJob.Handle.IsCompleted -and [datetime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 20 }
                $script:snapshotJob.Handle.IsCompleted | Should -BeTrue
                Complete-SRTrayCapture
            } finally { $script:snapshotRunspace.SessionStateProxy.SetVariable($mode,$false) }
        }
        Should -Invoke Show-SRTrayBalloon -Times 2 -Exactly -ParameterFilter { $Text -eq 'The snapshot was skipped because another snapshot is running.' }
        Should -Invoke Show-SRTrayBalloon -Times 0 -Exactly -ParameterFilter { $Text -eq 'Snapshot saved. Your current windows and tabs are protected.' }
    }
    It 'does not EndInvoke an incomplete pipeline on the UI poll' {
        Start-SRTrayCapture -Operation Automatic | Should -BeTrue
        Complete-SRTrayCapture
        $script:snapshotBusy | Should -BeTrue
        $deadline = [datetime]::UtcNow.AddSeconds(5)
        while (-not $script:snapshotJob.Handle.IsCompleted -and [datetime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 20 }
        Complete-SRTrayCapture
        $script:snapshotBusy | Should -BeFalse
        $script:snapshotJob | Should -BeNullOrEmpty
    }
}
