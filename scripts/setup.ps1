param(
    [switch] $SkipWebBuild,
    [ValidateSet('Legacy', 'Multi')][string] $Mode = '',
    [ValidatePattern('^/(?:[^/]+(?:/[^/]+)*)?/?$')]
    [string] $BasePath = ''
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'common.ps1')
$config = Get-ProjectConfig $root
$defaultConfig = Import-PowerShellDataFile (Join-Path $root 'config.psd1')
$localConfigPath = Join-Path $root 'config.local.psd1'
$localConfig = if (Test-Path $localConfigPath) { Import-PowerShellDataFile $localConfigPath } else { @{} }

if ($BasePath) {
    $config.BasePath = if ($BasePath -eq '/') { '/' } else { '/' + $BasePath.Trim('/') + '/' }
} elseif ($localConfig.ContainsKey('BasePath') -and $localConfig.BasePath -ne $defaultConfig.BasePath) {
    Write-Warning "config.local.psd1 overrides BasePath from '$($defaultConfig.BasePath)' to '$($localConfig.BasePath)'."
}

if ($Mode) {
    Write-Host "Requested deployment mode: $Mode"
    if ($config.DeploymentMode -ne $Mode) {
        Write-Warning "Set DeploymentMode = '$Mode' in config.local.psd1 before starting the proxy."
    }
}

if ($config.DeploymentMode -notin @('Legacy', 'Multi')) {
    throw "DeploymentMode must be 'Legacy' or 'Multi'."
}

$requiredNodeVersion = [version]$config.NodeVersion
$nodeToolchain = Get-NodeToolchain -Root $root -ExactVersion $requiredNodeVersion
if (-not $nodeToolchain) {
    $version = $config.NodeVersion
    $archiveName = "node-v$version-win-x64.zip"
    $archive = Join-Path $env:TEMP $archiveName
    $downloadUrl = "https://nodejs.org/dist/v$version/$archiveName"

    Write-Host "Downloading Node.js v$version..."
    Invoke-WebRequest -Uri $downloadUrl -OutFile $archive
    $actualHash = (Get-FileHash $archive -Algorithm SHA256).Hash
    if ($actualHash -ne $config.NodeSha256) {
        Remove-Item $archive -Force
        throw "Node.js archive checksum mismatch. Expected $($config.NodeSha256), got $actualHash."
    }

    $nodeDir = Join-Path $root 'tools\node'
    $extractDir = Join-Path $env:TEMP "bambu-node-$version"
    Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $nodeDir -Recurse -Force -ErrorAction SilentlyContinue
    Expand-Archive $archive $extractDir
    New-Item (Split-Path $nodeDir -Parent) -ItemType Directory -Force | Out-Null
    Move-Item (Join-Path $extractDir "node-v$version-win-x64") $nodeDir
    Remove-Item $archive, $extractDir -Recurse -Force -ErrorAction SilentlyContinue

    $env:PATH = "$nodeDir;$env:PATH"
    $nodeToolchain = Get-NodeToolchain -Root $root -ExactVersion $requiredNodeVersion
    if (-not $nodeToolchain) {
        throw "The downloaded Node.js v$version toolchain could not be started."
    }
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
    $webBasePath = if ([string]::IsNullOrWhiteSpace($config.BasePath)) { '/' } else { $config.BasePath }
    Write-Host "Building web application for public base path '$webBasePath'..."
    Push-Location (Join-Path $root 'web')
    $previousBasePath = $env:VITE_BASE_PATH
    $previousPath = $env:PATH
    try {
        $env:VITE_BASE_PATH = $webBasePath
        $env:PATH = "$(Split-Path $nodeToolchain.Node -Parent);$previousPath"
        if (Test-Path 'package-lock.json') {
            & $nodeToolchain.Npm ci
        } else {
            & $nodeToolchain.Npm install
        }
        if ($LASTEXITCODE -ne 0) { throw 'npm dependency installation failed.' }
        & $nodeToolchain.Npm run build
        if ($LASTEXITCODE -ne 0) { throw 'React example build failed.' }

        $builtIndex = [IO.File]::ReadAllText((Join-Path $root 'nginx\html\index.html'))
        $expectedAssetPrefix = if ($webBasePath -eq '/') { '/assets/' } else { "${webBasePath}assets/" }
        if (-not $builtIndex.Contains($expectedAssetPrefix)) {
            throw "Web build validation failed: index.html does not reference '$expectedAssetPrefix'."
        }
    } finally {
        $env:VITE_BASE_PATH = $previousBasePath
        $env:PATH = $previousPath
        Pop-Location
    }
}

Write-Host 'Setup complete.'