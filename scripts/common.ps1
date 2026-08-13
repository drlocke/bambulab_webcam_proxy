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

function Get-NodeToolchain {
    param(
        [string] $Root,
        [version] $MinimumVersion
    )

    $candidates = @()
    $systemNode = Get-Command node.exe -ErrorAction SilentlyContinue
    $systemNpm = Get-Command npm.cmd -ErrorAction SilentlyContinue
    if ($systemNode -and $systemNpm) {
        $candidates += [pscustomobject]@{ Node = $systemNode.Source; Npm = $systemNpm.Source }
    }

    $localNode = Join-Path $Root 'tools\node\node.exe'
    $localNpm = Join-Path $Root 'tools\node\npm.cmd'
    if ((Test-Path $localNode) -and (Test-Path $localNpm)) {
        $candidates += [pscustomobject]@{ Node = $localNode; Npm = $localNpm }
    }

    foreach ($candidate in $candidates) {
        try {
            $installedVersion = [version]((& $candidate.Node --version).TrimStart('v'))
            if ($installedVersion -ge $MinimumVersion) {
                return [pscustomobject]@{
                    Node = $candidate.Node
                    Npm = $candidate.Npm
                    Version = $installedVersion
                }
            }
        } catch {
            continue
        }
    }
    return $null
}