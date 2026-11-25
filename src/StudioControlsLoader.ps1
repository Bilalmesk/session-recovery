#requires -Version 5.1
<#
    StudioControlsLoader.ps1
    Loads the compiled WinForms controls shared by the Studio and restore UI.

    Add-Type recompiles StudioControls.cs on every launch, which costs about a
    second. Compile it once into a hash-keyed DLL and load that afterwards; an
    app update changes the source hash and gets a fresh cache entry.
#>

function Import-StudioControls {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ('SessionRecovery.Studio.StudioCard' -as [type]) { return }

    $cacheRoot = Join-Path (Get-SRRoot) 'cache'
    $cacheDll = $null
    try {
        $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash
        $cacheDll = Join-Path $cacheRoot ('StudioControls-' + $hash.Substring(0, 16) + '.dll')
        if (Test-Path -LiteralPath $cacheDll) {
            try {
                Add-Type -Path $cacheDll -ErrorAction Stop
                return
            } catch {
                try { Remove-Item -LiteralPath $cacheDll -Force -ErrorAction SilentlyContinue } catch { }
            }
        }

        New-Item -ItemType Directory -Path $cacheRoot -Force -ErrorAction Stop | Out-Null
        $tempDll = Join-Path $cacheRoot ('StudioControls-' + $hash.Substring(0, 16) + '-' + [guid]::NewGuid().ToString('N') + '.dll')
        try {
            Add-Type -Path $Path -OutputAssembly $tempDll -ReferencedAssemblies 'System.Windows.Forms', 'System.Drawing' -ErrorAction Stop
            if (-not (Test-Path -LiteralPath $cacheDll)) {
                try { Move-Item -LiteralPath $tempDll -Destination $cacheDll -Force -ErrorAction Stop } catch {
                    if (-not (Test-Path -LiteralPath $cacheDll)) { throw }
                }
            }
            if (Test-Path -LiteralPath $cacheDll) {
                Add-Type -Path $cacheDll -ErrorAction Stop
                return
            }
        } finally {
            if (Test-Path -LiteralPath $tempDll) { Remove-Item -LiteralPath $tempDll -Force -ErrorAction SilentlyContinue }
        }
    } catch {
        # Cache directories can be read-only, locked by antivirus, or hold a
        # DLL from another architecture. The source compile still works.
    }

    Add-Type -Path $Path -ReferencedAssemblies 'System.Windows.Forms', 'System.Drawing' -ErrorAction Stop
}
