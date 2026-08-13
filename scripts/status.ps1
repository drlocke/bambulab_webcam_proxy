$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'common.ps1')
$config = Get-ProjectConfig $root
$stateFile = Join-Path $root 'runtime\state.json'

if (-not (Test-Path $stateFile)) {
    Write-Host 'Status: stopped'
    exit 1
}

$state = Get-Content $stateFile -Raw | ConvertFrom-Json
$sourceHealthy = $state.sourceMode -in @('printer-rtsp', 'multi') -or (Test-ProcessId $state.supervisorPid)
$backendHealthy = $state.sourceMode -ne 'multi' -or (Test-ProcessId $state.backendPid)
$processesHealthy = (Test-ProcessId $state.mediaMtxPid) -and (Test-ProcessId $state.nginxPid) -and $sourceHealthy -and $backendHealthy
$streamReady = $false
try {
    $paths = Invoke-RestMethod 'http://127.0.0.1:9997/v3/paths/list' -TimeoutSec 2
        if ($state.sourceMode -eq 'multi') {
            $streamReady = $null -ne ($paths.items | Where-Object { $_.ready })
        } else {
            $streamReady = $null -ne ($paths.items | Where-Object { $_.name -eq $config.StreamName -and $_.ready })
        }
} catch {}

Write-Host "Status: $(if ($processesHealthy) { 'running' } else { 'degraded' })"
Write-Host "Source: $($state.sourceMode)"
Write-Host "Stream: $(if ($streamReady) { 'ready' } elseif ($state.sourceMode -eq 'multi') { 'no active streams' } else { 'waiting for camera' })"
Write-Host "Player: http://127.0.0.1:$($config.HttpPort)/"
if (-not $processesHealthy) { exit 1 }