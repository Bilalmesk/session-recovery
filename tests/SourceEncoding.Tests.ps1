#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# Windows PowerShell 5.1 reads a script without a UTF-8 BOM as ANSI, so any
# non-ASCII character (bullets, accents, dashes) turns into mojibake.
BeforeDiscovery {
    $script:encRoot = Split-Path $PSScriptRoot -Parent
    $script:encFiles = @(
        Get-ChildItem -LiteralPath $script:encRoot -Recurse -File |
            Where-Object { $_.Extension -in '.ps1', '.psm1' -and $_.FullName -notmatch '[\\/](\.git|node_modules)[\\/]' } |
            ForEach-Object { @{ Path = $_.FullName; Name = $_.FullName.Substring($script:encRoot.Length + 1) } }
    )
}
Describe 'PowerShell source encoding' {
    It '<Name> has a UTF-8 BOM when it contains non-ASCII text' -ForEach $script:encFiles {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        $nonAscii = @($bytes | Where-Object { $_ -gt 127 }).Count -gt 0
        if ($nonAscii) { $hasBom | Should -BeTrue -Because 'Windows PowerShell 5.1 would read the file as ANSI' }
    }
}
