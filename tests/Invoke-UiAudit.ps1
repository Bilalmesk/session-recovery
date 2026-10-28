#requires -Version 5.1
<#
    Invoke-UiAudit.ps1
    Renders the Studio in every supported language and fails when any page
    has overlapping, clipped or overflowing controls.

    The layout audit runs inside the app itself (SESSIONRECOVERY_RENDER_CHECK)
    and writes one .check.txt file per page. This wrapper only prepares an
    isolated profile, invokes the STA render pass, and scans the reports.

    Examples:
      .\tests\Invoke-UiAudit.ps1
      .\tests\Invoke-UiAudit.ps1 -Size 1024x661 -Scroll both
      .\tests\Invoke-UiAudit.ps1 -Languages en,fr,ar -Size 1160x680
#>
[CmdletBinding()]
param(
    [string[]]$Languages = @('en', 'ar', 'fr', 'es', 'de', 'pt', 'ru', 'zh', 'tr'),
    # Client area at the app's minimum outer size (1040x700).
    [string]$Size = '1024x661',
    [ValidateSet('top', 'bottom', 'both')]
    [string]$Scroll = 'both',
    [string]$OutputRoot = '',
    [int]$RenderMilliseconds = 900
)

$ErrorActionPreference = 'Stop'
# powershell.exe -File passes "en,fr" as one string, so accept both a real
# array and a comma-separated list.
$Languages = @($Languages | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($Languages.Count -eq 0) { throw 'At least one language is required.' }

$repo = Split-Path -Parent $PSScriptRoot
$studio = Join-Path $repo 'src\Studio-SessionRecovery.ps1'
if (-not (Test-Path -LiteralPath $studio)) {
    throw "Studio entry point not found: $studio"
}

if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('sr-ui-audit-' + [guid]::NewGuid().ToString('N'))
}
New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
$OutputRoot = (Resolve-Path -LiteralPath $OutputRoot).Path

$pages = @('Dashboard', 'Snapshots', 'Exclusions', 'RecoveryKit', 'Settings', 'Diagnostics', 'About')
$scrollModes = if ($Scroll -eq 'both') { @('top', 'bottom') } else { @($Scroll) }
$failures = New-Object System.Collections.Generic.List[string]
$runs = 0

foreach ($language in $Languages) {
    foreach ($scrollMode in $scrollModes) {
        $runs++
        $caseDir = Join-Path $OutputRoot ("{0}-{1}\{2}" -f $Size, $scrollMode, $language)
        $homeDir = Join-Path $caseDir 'home'
        $outDir = Join-Path $caseDir 'out'
        New-Item -ItemType Directory -Path $homeDir -Force | Out-Null
        Remove-Item -LiteralPath $outDir -Recurse -Force -ErrorAction SilentlyContinue

        [ordered]@{ language = $language } |
            ConvertTo-Json -Depth 4 |
            Set-Content -LiteralPath (Join-Path $homeDir 'config.json') -Encoding UTF8

        $env:SESSIONRECOVERY_HOME = $homeDir
        $env:SESSIONRECOVERY_RENDER_CHECK = '1'
        $env:SESSIONRECOVERY_RENDER_TREE = '1'
        $env:SESSIONRECOVERY_RENDER_MS = [string]$RenderMilliseconds
        $env:SESSIONRECOVERY_RENDER_SIZE = $Size
        $env:SESSIONRECOVERY_RENDER_SCROLL = $scrollMode

        Push-Location $repo
        try {
            & powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $studio -RenderDir $outDir *> (Join-Path $caseDir 'render.log')
            $renderExit = $LASTEXITCODE
        } finally {
            Pop-Location
        }

        if ($renderExit -ne 0) {
            $failures.Add("$language/$scrollMode`: renderer exited with code $renderExit")
            Write-Host ("FAIL {0,-3} {1,-6} renderer exit {2}" -f $language, $scrollMode, $renderExit)
            continue
        }

        $caseFailures = 0
        foreach ($page in $pages) {
            $checkPath = Join-Path $outDir ($page + '.check.txt')
            if (-not (Test-Path -LiteralPath $checkPath)) {
                $failures.Add("$language/$scrollMode/$page`: missing check report")
                $caseFailures++
                continue
            }
            $report = Get-Content -LiteralPath $checkPath -Raw
            if ($report -notmatch 'OK:') {
                $detail = ($report -replace '\r?\n', ' | ').Trim()
                $failures.Add("$language/$scrollMode/$page`: $detail")
                $caseFailures++
            }
        }

        if ($caseFailures -eq 0) {
            Write-Host ("OK   {0,-3} {1,-6} {2} pages" -f $language, $scrollMode, $pages.Count)
        } else {
            Write-Host ("FAIL {0,-3} {1,-6} {2} page(s)" -f $language, $scrollMode, $caseFailures)
        }
    }
}

Write-Host ''
Write-Host ("UI audit: {0} render pass(es), {1} failure(s). Output: {2}" -f $runs, $failures.Count, $OutputRoot)
if ($failures.Count -gt 0) {
    foreach ($failure in $failures) { Write-Host ("  - " + $failure) }
    exit 1
}
exit 0
