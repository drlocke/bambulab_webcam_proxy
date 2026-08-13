param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Legacy', 'Multi')]
    [string] $Mode,
    [string] $Region = '',
    [string] $PrinterStreamUrl = '',
    [switch] $SecureCookies
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$localConfigPath = Join-Path $root 'config.local.psd1'
$settings = [ordered]@{}

if (Test-Path $localConfigPath) {
    $existing = Import-PowerShellDataFile $localConfigPath
    foreach ($key in $existing.Keys) { $settings[$key] = $existing[$key] }
}

$settings.DeploymentMode = $Mode
if ($PrinterStreamUrl) { $settings.PrinterStreamUrl = $PrinterStreamUrl }

if ($Mode -eq 'Multi') {
    if (-not $Region -and $settings.Contains('BambuRegion')) { $Region = $settings.BambuRegion }
    if (-not $Region) { throw 'Multi mode requires -Region (for example: us, eu, or cn).' }
    $settings.BambuRegion = $Region
    $settings.SecureCookies = [bool]$SecureCookies
    if (-not $settings.Contains('MultiSessionSecret') -or [string]::IsNullOrWhiteSpace($settings.MultiSessionSecret)) {
        $bytes = New-Object byte[] 48
        [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
        $settings.MultiSessionSecret = [Convert]::ToBase64String($bytes)
    }
}

function Format-DataValue($value) {
    if ($value -is [bool]) { return $(if ($value) { '$true' } else { '$false' }) }
    return "'$($value.ToString().Replace("'", "''"))'"
}

$lines = @('@{')
foreach ($entry in $settings.GetEnumerator()) {
    $lines += "    $($entry.Key) = $(Format-DataValue $entry.Value)"
}
$lines += '}'
[IO.File]::WriteAllLines($localConfigPath, $lines, (New-Object Text.UTF8Encoding($false)))
Write-Host "Configured $Mode deployment mode in config.local.psd1."