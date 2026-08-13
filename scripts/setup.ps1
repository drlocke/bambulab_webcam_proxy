param(
    [switch] $SkipWebBuild,
    [ValidateSet('Legacy', 'Multi')][string] $Mode = ''
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'common.ps1')
$config = Get-ProjectConfig $root

if ($Mode) {
    Write-Host "Requested deployment mode: $Mode"
    if ($config.DeploymentMode -ne $Mode) {
        Write-Warning "Set DeploymentMode = '$Mode' in config.local.psd1 before starting the proxy."
    }
}

if ($config.DeploymentMode -notin @('Legacy', 'Multi')) {
    throw "DeploymentMode must be 'Legacy' or 'Multi'."
}
if ($config.DeploymentMode -eq 'Multi' -and -not (Get-Command node.exe -ErrorAction SilentlyContinue)) {
    throw 'Node.js 22.12 or newer is required for Multi deployment mode.'
}

if ($config.DeploymentMode -eq 'Multi' -or [string]::IsNullOrWhiteSpace($config.PrinterStreamUrl)) {
    $requiredCameraTools = @('bambu_source.exe', 'ffmpeg.exe', 'BambuSource.dll', 'live555.dll', 'agora_rtc_sdk.dll', 'libaosl.dll', 'libagora-ffmpeg.dll', 'libagora-soundtouch.dll')
    $missingCameraTools = $requiredCameraTools | Where-Object { -not (Test-Path (Join-Path $config.CameraToolsPath $_)) }
    if ($missingCameraTools) {
        throw "Bambu Studio CameraTools is incomplete at '$($config.CameraToolsPath)'. Open Bambu Studio and install/enable Virtual Camera first. Missing: $($missingCameraTools -join ', ')"
    }
}

$mediaDir = Join-Path $root 'tools\mediamtx'
$mediaExe = Join-Path $mediaDir 'mediamtx.exe'
if (-not (Test-Path $mediaExe)) {
    $version = $config.MediaMTXVersion
    $archiveName = "mediamtx_v${version}_windows_amd64.zip"
    $archive = Join-Path $env:TEMP $archiveName
    $downloadUrl = "https://github.com/bluenviron/mediamtx/releases/download/v$version/$archiveName"

    Write-Host "Downloading MediaMTX v$version..."
    Invoke-WebRequest -Uri $downloadUrl -OutFile $archive
    $actualHash = (Get-FileHash $archive -Algorithm SHA256).Hash
    if ($actualHash -ne $config.MediaMTXSha256) {
        Remove-Item $archive -Force
        throw "MediaMTX archive checksum mismatch. Expected $($config.MediaMTXSha256), got $actualHash."
    }

    New-Item $mediaDir -ItemType Directory -Force | Out-Null
    $extractDir = Join-Path $env:TEMP "bambu-mediamtx-$version"
    Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue
    Expand-Archive $archive $extractDir
    Copy-Item (Join-Path $extractDir 'mediamtx.exe') $mediaExe
    Copy-Item (Join-Path $extractDir 'LICENSE') (Join-Path $mediaDir 'LICENSE')
}

$nginxToolDir = Join-Path $root 'tools\nginx'
$nginxExe = Join-Path $nginxToolDir 'nginx.exe'
if (-not (Test-Path $nginxExe)) {
    $version = $config.NginxVersion
    $archiveName = "nginx-$version.zip"
    $archive = Join-Path $env:TEMP $archiveName
    $downloadUrl = "https://nginx.org/download/$archiveName"

    Write-Host "Downloading nginx v$version..."
    Invoke-WebRequest -Uri $downloadUrl -OutFile $archive
    $actualHash = (Get-FileHash $archive -Algorithm SHA256).Hash
    if ($actualHash -ne $config.NginxSha256) {
        Remove-Item $archive -Force
        throw "nginx archive checksum mismatch. Expected $($config.NginxSha256), got $actualHash."
    }

    New-Item $nginxToolDir -ItemType Directory -Force | Out-Null
    $extractDir = Join-Path $env:TEMP "bambu-nginx-$version"
    Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue
    Expand-Archive $archive $extractDir
    Copy-Item (Join-Path $extractDir "nginx-$version\nginx.exe") $nginxExe
}

if (-not $SkipWebBuild) {
    if (-not (Get-Command npm.cmd -ErrorAction SilentlyContinue)) {
        throw 'Node.js/npm is required to build the React example.'
    }
    Push-Location (Join-Path $root 'web')
    try {
        if (Test-Path 'package-lock.json') {
            & npm.cmd ci
        } else {
            & npm.cmd install
        }
        if ($LASTEXITCODE -ne 0) { throw 'npm dependency installation failed.' }
        & npm.cmd run build
        if ($LASTEXITCODE -ne 0) { throw 'React example build failed.' }
    } finally {
        Pop-Location
    }
}

Write-Host 'Setup complete.'