Set-StrictMode -Version Latest

function Get-ProjectConfig {
    param([string] $Root)

    $config = Import-PowerShellDataFile (Join-Path $Root 'config.psd1')
    $localConfigPath = Join-Path $Root 'config.local.psd1'
    if (Test-Path $localConfigPath) {
        $localConfig = Import-PowerShellDataFile $localConfigPath
        foreach ($key in $localConfig.Keys) {
            $config[$key] = $localConfig[$key]
        }
    }
    if ([string]::IsNullOrWhiteSpace($config.CameraToolsPath)) {
        $config.CameraToolsPath = Join-Path $env:APPDATA 'BambuStudio\cameratools'
    }
    if ([string]::IsNullOrWhiteSpace($config.CameraUrlFile)) {
        $config.CameraUrlFile = Join-Path $config.CameraToolsPath 'url.txt'
    }
    return $config
}

function Wait-HttpReady {
    param(
        [string] $Uri,
        [int] $TimeoutSeconds = 15
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        try {
            return Invoke-RestMethod -Uri $Uri -TimeoutSec 2
        } catch {
            if ((Get-Date) -ge $deadline) {
                throw "Timed out waiting for $Uri"
            }
            [Threading.Thread]::Sleep(250)
        }
    } while ($true)
}

function Test-ProcessId {
    param([int] $ProcessId)

    return $null -ne (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)
}