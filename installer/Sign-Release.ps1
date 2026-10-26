#requires -Version 5.1
<#
    Sign-Release.ps1
    Signs the built MSI and host executable so Windows stops showing the
    SmartScreen warning. Two providers are supported; both read everything
    from environment variables so no secret is ever committed.

    1) Azure Trusted Signing (recommended, no certificate to buy):
         Set AZURE_TRUSTED_SIGNING_ENDPOINT  - e.g. https://eus.codesigning.azure.net
         Set AZURE_TRUSTED_SIGNING_ACCOUNT   - your account name
         Set AZURE_TRUSTED_SIGNING_PROFILE   - your certificate profile
       Authentication uses DefaultAzureCredential (az login, or the
       AZURE_CLIENT_ID / AZURE_TENANT_ID / AZURE_CLIENT_SECRET set for CI).

    2) A code-signing certificate file:
         Set SIGNING_PFX_PATH     - path or URL to the .pfx
         Set SIGNING_PFX_PASSWORD - the PFX password
         (Azure Trusted Signing is preferred: certificates need a hardware
          token or a key vault to satisfy CA rules.)

    Usage:
      powershell -File .\installer\Sign-Release.ps1 -Path .\dist\SessionRecovery-2.6.0.msi
      powershell -File .\installer\Sign-Release.ps1 -Path .\dist\SessionRecovery-*.msi

    Exit codes: 0 signed, 1 failure, 2 no signing configuration found.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][SupportsWildcards()][string[]]$Path,
    [string]$TimestampServer = 'http://timestamp.digicert.com'
)

$ErrorActionPreference = 'Stop'

function Find-SignTool {
    $candidates = @()
    $windowsKits = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
    if (Test-Path -LiteralPath $windowsKits) {
        # Newest kit first.
        foreach ($kit in @(Get-ChildItem -LiteralPath $windowsKits -Directory -ErrorAction SilentlyContinue | Sort-Object -Property Name -Descending)) {
            $candidates += (Join-Path $kit.FullName 'x64\signtool.exe')
            $candidates += (Join-Path $kit.FullName 'x86\signtool.exe')
        }
    }
    foreach ($found in (Get-Command signtool.exe -ErrorAction SilentlyContinue)) { $candidates += $found.Source }
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
    }
    throw 'signtool.exe was not found. Install the Windows SDK (Signing Tools feature).'
}

$files = @($Path | ForEach-Object { Get-Item -Path $_ -ErrorAction SilentlyContinue })
if ($files.Count -eq 0) { throw 'No files matched the signing path.' }

$useTrustedSigning = -not [string]::IsNullOrWhiteSpace($env:AZURE_TRUSTED_SIGNING_ENDPOINT) -and
    -not [string]::IsNullOrWhiteSpace($env:AZURE_TRUSTED_SIGNING_ACCOUNT) -and
    -not [string]::IsNullOrWhiteSpace($env:AZURE_TRUSTED_SIGNING_PROFILE)
$usePfx = -not [string]::IsNullOrWhiteSpace($env:SIGNING_PFX_PATH) -and
    -not [string]::IsNullOrWhiteSpace($env:SIGNING_PFX_PASSWORD)

if (-not $useTrustedSigning -and -not $usePfx) {
    Write-Output 'No signing configuration found (AZURE_TRUSTED_SIGNING_* or SIGNING_PFX_*). Nothing was signed.'
    exit 2
}

$signTool = Find-SignTool
Write-Output ("Using signtool: {0}" -f $signTool)

foreach ($file in $files) {
    Write-Output ("Signing {0}" -f $file.FullName)
    if ($useTrustedSigning) {
        # The dmdf metadata file tells the Trusted Signing dlib which account
        # and profile to use. Authentication runs through
        # DefaultAzureCredential (az login or AZURE_* service principal).
        $metadata = @{
            Endpoint = $env:AZURE_TRUSTED_SIGNING_ENDPOINT
            CodeSigningAccountName = $env:AZURE_TRUSTED_SIGNING_ACCOUNT
            CertificateProfileName = $env:AZURE_TRUSTED_SIGNING_PROFILE
        } | ConvertTo-Json -Compress
        $metadataPath = Join-Path $env:TEMP 'trusted-signing.json'
        Set-Content -LiteralPath $metadataPath -Value $metadata -Encoding UTF8
        & $signTool sign /fd SHA256 /td SHA256 /tr $TimestampServer `
            /dlib "Microsoft.Trusted.Signing.Client.dll" `
            /dmdf $metadataPath `
            $file.FullName
        if ($LASTEXITCODE -ne 0) { throw ("Trusted Signing failed for {0}" -f $file.Name) }
    } else {
        & $signTool sign /fd SHA256 /td SHA256 /tr $TimestampServer /f $env:SIGNING_PFX_PATH /p $env:SIGNING_PFX_PASSWORD $file.FullName
        if ($LASTEXITCODE -ne 0) { throw ("PFX signing failed for {0}" -f $file.Name) }
    }
}

Write-Output ('Signed {0} file(s).' -f $files.Count)
exit 0
