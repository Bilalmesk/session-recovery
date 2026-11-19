#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# Regression guard for issue #5: the Studio and restore window use fixed
# 96-DPI pixel layouts, so they must opt their thread out of per-monitor DPI
# awareness before any form exists or the UI is garbled on 4K at 250%.
BeforeAll {
    $script:srcRoot = Join-Path (Split-Path $PSScriptRoot -Parent) 'src'
    $script:themeText = [System.IO.File]::ReadAllText((Join-Path $script:srcRoot 'StudioTheme.ps1'))
}
Describe 'High-DPI window layout' {
    It 'StudioTheme.ps1 defines Set-StudioWindowDpiUnaware with an opt-out' {
        $script:themeText | Should -Match 'function Set-StudioWindowDpiUnaware'
        $script:themeText | Should -Match 'SetThreadDpiAwarenessContext'
        $script:themeText | Should -Match 'SESSIONRECOVERY_DPI'
    }
    It '<Name> opts out of DPI awareness before creating its first form' -ForEach @(
        @{ Name = 'Studio-SessionRecovery.ps1' }
        @{ Name = 'Restore-Session.ps1' }
    ) {
        $text = [System.IO.File]::ReadAllText((Join-Path $script:srcRoot $Name))
        $call = $text.IndexOf('Set-StudioWindowDpiUnaware')
        $firstForm = $text.IndexOf('New-Object System.Windows.Forms.Form')
        $call | Should -BeGreaterThan -1
        $firstForm | Should -BeGreaterThan -1
        $call | Should -BeLessThan $firstForm
    }
    It 'the helper runs and returns a boolean on any platform' {
        . (Join-Path $script:srcRoot 'StudioTheme.ps1')
        (Set-StudioWindowDpiUnaware) | Should -BeOfType [bool]
    }
}
