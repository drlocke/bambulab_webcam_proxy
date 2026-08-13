param([switch] $Logs)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'common.ps1')
$config = Get-ProjectConfig $root
$stateFile = Join-Path $root 'runtime\state.json'
$logDir = Join-Path $root 'runtime\logs'

function Get-ComponentStatus {
    param(
        [string] $Name,
        [int] $ProcessId,
        [string[]] $ExpectedProcessNames,
        [bool] $Required
    )

    if (-not $Required) {
        return [pscustomobject]@{ Name = $Name; ProcessId = 0; Status = 'not used'; Healthy = $true }
    }

    $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if (-not $process) {
        return [pscustomobject]@{ Name = $Name; ProcessId = $ProcessId; Status = 'stopped'; Healthy = $false }
    }
    if ($process.ProcessName -notin $ExpectedProcessNames) {
        return [pscustomobject]@{ Name = $Name; ProcessId = $ProcessId; Status = "PID belongs to $($process.ProcessName)"; Healthy = $false }
    }
    return [pscustomobject]@{ Name = $Name; ProcessId = $ProcessId; Status = 'running'; Healthy = $true }
}

function Test-Endpoint {
    param([string] $Uri)

    try {
        Invoke-RestMethod $Uri -TimeoutSec 2 | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Show-RecentErrors {
    param([string[]] $Paths)

    $shown = $false
    foreach ($path in $Paths) {
        if ((Test-Path $path) -and (Get-Item $path).Length -gt 0) {
            if (-not $shown) {
                Write-Host ''
                Write-Host 'Recent diagnostic output:'
                $shown = $true
            }
            $displayPath = $path
            if ($path.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
                $displayPath = $path.Substring($root.Length).TrimStart('\')
            }
            Write-Host "--- $displayPath ---"
            Get-Content $path -Tail 8
        }
    }
    if (-not $shown) {
        Write-Host ''
        Write-Host 'No error output has been recorded.'
    }
}

function Get-ErrorLogPaths {
    param([string] $SourceMode)

    $paths = @(
        (Join-Path $logDir 'mediamtx-error.log'),
        (Join-Path $logDir 'nginx-test-error.log'),
        (Join-Path $logDir 'nginx-error.log')
    )
    if ($SourceMode -eq 'multi') {
        $paths += Join-Path $logDir 'server-error.log'
        $streamLogDir = Join-Path $root 'runtime\streams'
        if (Test-Path $streamLogDir) {
            $paths += Get-ChildItem $streamLogDir -Recurse -File |
                Where-Object { $_.Name -in @('camera-source.log', 'ffmpeg.log') } |
                Sort-Object LastWriteTime -Descending |
                Select-Object -First 6 -ExpandProperty FullName
        }
    } elseif ($SourceMode -eq 'managed') {
        $paths += (Join-Path $logDir 'supervisor.log'), (Join-Path $logDir 'camera-source.log'), (Join-Path $logDir 'ffmpeg.log')
    } elseif ($SourceMode -eq 'studio-rtp') {
        $paths += (Join-Path $logDir 'studio-retimer.log'), (Join-Path $logDir 'studio-transcoder.log')
    } elseif ([string]::IsNullOrWhiteSpace($SourceMode)) {
        $paths += (Join-Path $logDir 'server-error.log'), (Join-Path $logDir 'supervisor.log'), (Join-Path $logDir 'camera-source.log'), (Join-Path $logDir 'ffmpeg.log'), (Join-Path $logDir 'studio-retimer.log'), (Join-Path $logDir 'studio-transcoder.log')
    }
    return $paths
}

if (-not (Test-Path $stateFile)) {
    Write-Host 'Status: stopped'
    Write-Host "Logs:   $logDir"
    if ($Logs) {
        Show-RecentErrors (Get-ErrorLogPaths '')
    }
    exit 1
}

$state = Get-Content $stateFile -Raw | ConvertFrom-Json
$components = @(
    (Get-ComponentStatus 'MediaMTX' $state.mediaMtxPid @('mediamtx') $true),
    (Get-ComponentStatus 'nginx' $state.nginxPid @('nginx') $true),
    (Get-ComponentStatus 'Node backend' $state.backendPid @('node') ($state.sourceMode -eq 'multi')),
    (Get-ComponentStatus 'Camera supervisor' $state.supervisorPid @('powershell', 'pwsh') ($state.sourceMode -in @('managed', 'studio-rtp')))
)
$processesHealthy = $null -eq ($components | Where-Object { -not $_.Healthy } | Select-Object -First 1)
$webHealthy = Test-Endpoint "http://127.0.0.1:$($config.HttpPort)/health"
$mediaHealthy = $false
$backendHealthy = $state.sourceMode -ne 'multi'
$streamReady = $false
try {
    $paths = Invoke-RestMethod 'http://127.0.0.1:9997/v3/paths/list' -TimeoutSec 2
    $mediaHealthy = $true
    if ($state.sourceMode -eq 'multi') {
        $streamReady = $null -ne ($paths.items | Where-Object { $_.ready } | Select-Object -First 1)
    } else {
        $streamReady = $null -ne ($paths.items | Where-Object { $_.name -eq $config.StreamName -and $_.ready } | Select-Object -First 1)
    }
} catch {}
if ($state.sourceMode -eq 'multi') {
    $backendHealthy = Test-Endpoint 'http://127.0.0.1:8787/api/config'
}

$serviceHealthy = $processesHealthy -and $webHealthy -and $mediaHealthy -and $backendHealthy
$startedAt = [datetime]::Parse($state.startedAt)
$uptime = (Get-Date) - $startedAt
$uptimeText = '{0}d {1:00}h {2:00}m {3:00}s' -f [math]::Floor($uptime.TotalDays), $uptime.Hours, $uptime.Minutes, $uptime.Seconds
$basePath = if ([string]::IsNullOrWhiteSpace($config.BasePath) -or $config.BasePath -eq '/') { '/' } else { '/' + $config.BasePath.Trim('/') + '/' }

Write-Host "Status:  $(if ($serviceHealthy) { 'running' } else { 'degraded' })"
Write-Host "Started: $($startedAt.ToString('yyyy-MM-dd HH:mm:ss')) ($uptimeText)"
Write-Host "Source:  $($state.sourceMode)"
Write-Host "Stream:  $(if ($streamReady) { 'ready' } elseif ($state.sourceMode -eq 'multi') { 'no active streams' } else { 'waiting for camera' })"
Write-Host "Player:  http://127.0.0.1:$($config.HttpPort)$basePath"
Write-Host "Logs:    $logDir"
Write-Host ''
Write-Host 'Components:'
foreach ($component in $components) {
    $pidText = if ($component.ProcessId) { "PID $($component.ProcessId)" } else { '-' }
    Write-Host ('  {0,-19} {1,-12} {2}' -f $component.Name, $pidText, $component.Status)
}
Write-Host ''
Write-Host 'Endpoints:'
Write-Host ('  {0,-19} {1}' -f 'Web /health', $(if ($webHealthy) { 'reachable' } else { 'unreachable' }))
Write-Host ('  {0,-19} {1}' -f 'MediaMTX API', $(if ($mediaHealthy) { 'reachable' } else { 'unreachable' }))
if ($state.sourceMode -eq 'multi') {
    Write-Host ('  {0,-19} {1}' -f 'Backend API', $(if ($backendHealthy) { 'reachable' } else { 'unreachable' }))
}

if (-not $serviceHealthy -or $Logs) {
    Show-RecentErrors (Get-ErrorLogPaths $state.sourceMode)
}

if (-not $serviceHealthy) { exit 1 }