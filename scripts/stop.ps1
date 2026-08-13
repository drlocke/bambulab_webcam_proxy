$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$stateFile = Join-Path $root 'runtime\state.json'

if (-not (Test-Path $stateFile)) {
    Write-Host 'Webcam proxy is not running (no runtime state found).'
    exit 0
}

$state = Get-Content $stateFile -Raw | ConvertFrom-Json
foreach ($processId in @($state.supervisorPid, $state.nginxPid, $state.mediaMtxPid)) {
    if ($processId -and (Get-Process -Id $processId -ErrorAction SilentlyContinue)) {
        & taskkill.exe /PID $processId /T /F | Out-Null
    }
}
Remove-Item $stateFile -Force
Write-Host 'Webcam proxy stopped.'