#requires -Version 5.1
<#
    InstallManifest.ps1
    Shared helpers for the script installer and the uninstaller.

    The manifest lists only leaf file names that the installer created in the
    program folder. The uninstaller requires a valid manifest before it
    removes anything, so a mistyped or malicious -InstallDirectory can never
    turn into a recursive delete of an unrelated folder.
#>

function Test-SRManifestFileName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    if ($Name -eq '.' -or $Name -eq '..') { return $false }
    if ($Name.IndexOfAny([char[]]@('\', '/')) -ge 0) { return $false }
    if ([System.IO.Path]::IsPathRooted($Name)) { return $false }
    if ($Name -match '[\x00-\x1F:*?"<>|]') { return $false }
    return $true
}

function New-SRInstallManifest {
    param(
        [Parameter(Mandatory = $true)][string]$InstallDirectory,
        [Parameter(Mandatory = $true)][string[]]$Files
    )
    if (-not (Test-Path -LiteralPath $InstallDirectory -PathType Container)) {
        throw "Install directory not found: $InstallDirectory"
    }
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($file in @($Files)) {
        $name = [string]$file
        if (-not (Test-SRManifestFileName -Name $name)) {
            throw ("Unsafe file name in install manifest: {0}" -f [string]$file)
        }
        if (-not $names.Contains($name)) { $names.Add($name) }
    }
    if ($names.Count -eq 0) { throw 'The install manifest needs at least one file.' }

    $manifest = [pscustomobject]@{
        product = 'Session Recovery'
        format  = 1
        files   = @($names)
    }
    $manifestPath = Join-Path $InstallDirectory 'install-manifest.json'
    $json = $manifest | ConvertTo-Json -Depth 4
    [System.IO.File]::WriteAllText($manifestPath, $json, (New-Object System.Text.UTF8Encoding($false)))
    return $manifestPath
}

function Get-SRInstallManifest {
    param([Parameter(Mandatory = $true)][string]$InstallDirectory)
    if (-not (Test-Path -LiteralPath $InstallDirectory -PathType Container)) { return $null }
    $manifestPath = Join-Path $InstallDirectory 'install-manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { return $null }

    $manifest = $null
    try {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop | ConvertFrom-Json
    } catch {
        return $null
    }
    if ($null -eq $manifest) { return $null }
    if ([string]$manifest.product -ne 'Session Recovery') { return $null }
    $format = 0
    if (-not [int]::TryParse([string]$manifest.format, [ref]$format) -or $format -ne 1) { return $null }

    $names = New-Object System.Collections.Generic.List[string]
    foreach ($file in @($manifest.files)) {
        $name = [string]$file
        # A tampered manifest must fail closed. Never accept paths, wildcards
        # or traversal segments that would escape the program folder.
        if (-not (Test-SRManifestFileName -Name $name)) { return $null }
        if (-not $names.Contains($name)) { $names.Add($name) }
    }
    if ($names.Count -eq 0) { return $null }

    return [pscustomobject]@{
        Path  = $manifestPath
        Files = @($names)
    }
}

function Remove-SRInstallOwnedFiles {
    param([Parameter(Mandatory = $true)][string]$InstallDirectory)
    $result = [pscustomobject]@{
        Ok        = $false
        Removed   = @()
        Leftovers = @()
        Error     = ''
    }
    if (-not (Test-Path -LiteralPath $InstallDirectory -PathType Container)) {
        $result.Ok = $true
        return $result
    }

    $manifest = Get-SRInstallManifest -InstallDirectory $InstallDirectory
    if ($null -eq $manifest) {
        $result.Error = 'No valid install manifest was found, so program files were not removed.'
        return $result
    }

    $removed = New-Object System.Collections.Generic.List[string]
    $leftover = New-Object System.Collections.Generic.List[string]
    foreach ($name in @($manifest.Files)) {
        $path = Join-Path $InstallDirectory $name
        if (-not (Test-Path -LiteralPath $path)) { continue }
        try {
            Remove-Item -LiteralPath $path -Force -ErrorAction Stop
            $removed.Add($name)
        } catch {
            $leftover.Add($name)
        }
    }

    # The manifest itself is not listed in its own file array.
    try {
        Remove-Item -LiteralPath $manifest.Path -Force -ErrorAction Stop
    } catch {
        $leftover.Add('install-manifest.json')
    }

    # Remove the folder only when it is empty. Never recurse: files that were
    # not installed by us (or that are locked) stay in place.
    if ($leftover.Count -eq 0) {
        try {
            if (@(Get-ChildItem -LiteralPath $InstallDirectory -Force -ErrorAction Stop).Count -eq 0) {
                Remove-Item -LiteralPath $InstallDirectory -Force -ErrorAction Stop
            }
        } catch { }
    }

    $result.Removed = @($removed)
    $result.Leftovers = @($leftover)
    if ($leftover.Count -gt 0) {
        $result.Error = 'Some installer-owned files could not be removed (they may be in use).'
    } else {
        $result.Ok = $true
    }
    return $result
}
