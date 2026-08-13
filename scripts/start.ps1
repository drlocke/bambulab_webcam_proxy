$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'common.ps1')
$config = Get-ProjectConfig $root
$runtimeDir = Join-Path $root 'runtime'
$logDir = Join-Path $runtimeDir 'logs'
$stateFile = Join-Path $runtimeDir 'state.json'
$nginx = $null
$supervisor = $null
$backend = $null
$sourceMode = 'managed'
$servicePort = 8787

if (Test-Path $stateFile) {
    $oldState = Get-Content $stateFile -Raw | ConvertFrom-Json
    if (Test-ProcessId $oldState.supervisorPid) {
        throw "The webcam proxy is already running (PID $($oldState.supervisorPid))."
    }
    Remove-Item $stateFile -Force
}

$requiredFiles = @(
    (Join-Path $root 'tools\mediamtx\mediamtx.exe'),
    (Join-Path $root 'tools\nginx\nginx.exe')
)
if ($config.DeploymentMode -eq 'Multi') {
    $requiredFiles += (Join-Path $config.CameraToolsPath 'bambu_source.exe'), (Join-Path $config.CameraToolsPath 'ffmpeg.exe')
} elseif ([string]::IsNullOrWhiteSpace($config.PrinterStreamUrl)) {
    $requiredFiles += (Join-Path $config.CameraToolsPath 'bambu_source.exe'), (Join-Path $config.CameraToolsPath 'ffmpeg.exe'), $config.CameraUrlFile
}
$missingFiles = $requiredFiles | Where-Object { -not (Test-Path $_) }
if ($missingFiles) {
    throw "Setup is incomplete. Run scripts\setup.ps1 first. Missing: $($missingFiles -join ', ')"
}
if ($config.DeploymentMode -eq 'Legacy' -and [string]::IsNullOrWhiteSpace($config.PrinterStreamUrl) -and (Get-Item $config.CameraUrlFile).Length -eq 0) {
    throw "Camera URL file is empty. Enable Virtual Camera in Bambu Studio once: '$($config.CameraUrlFile)'"
}

$ports = @($config.HttpPort, 8554, 8889, 9997)
if ($config.DeploymentMode -eq 'Multi') { $ports += $servicePort }
$busyPorts = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object LocalPort -In $ports
if ($busyPorts) {
    throw "Required TCP port(s) already in use: $(($busyPorts.LocalPort | Sort-Object -Unique) -join ', ')"
}

New-Item $logDir -ItemType Directory -Force | Out-Null
$mediaOut = Join-Path $logDir 'mediamtx.log'
$mediaErr = Join-Path $logDir 'mediamtx-error.log'
$nginxOut = Join-Path $logDir 'nginx.log'
$nginxErr = Join-Path $logDir 'nginx-error.log'

$studioFfmpeg = $null
if ($config.DeploymentMode -eq 'Multi') {
    $sourceMode = 'multi'
    Remove-Item Env:MTX_PATHS_BAMBU_SOURCE -ErrorAction SilentlyContinue
} elseif (-not [string]::IsNullOrWhiteSpace($config.PrinterStreamUrl)) {
    if ($config.PrinterStreamUrl -notmatch '^rts?ps?://') {
        throw 'PrinterStreamUrl must start with rtsp:// or rtsps://.'
    }
    $env:MTX_PATHS_BAMBU_SOURCE = $config.PrinterStreamUrl
    $sourceMode = 'printer-rtsp'
} else {
    Remove-Item Env:MTX_PATHS_BAMBU_SOURCE -ErrorAction SilentlyContinue
    $studioFfmpeg = Get-CimInstance Win32_Process -Filter "Name='ffmpeg.exe'" | Where-Object {
        $_.CommandLine -like '*rtp://127.0.0.1:1234*'
    } | Select-Object -First 1
    if ($studioFfmpeg) {
        $sourceMode = 'studio-rtp'
    }
}

$mediaConfig = if ($sourceMode -eq 'studio-rtp') { 'mediamtx-studio.yml' } else { 'mediamtx.yml' }
$media = Start-Process (Join-Path $root 'tools\mediamtx\mediamtx.exe') -ArgumentList ('"' + (Join-Path $root $mediaConfig) + '"') -WorkingDirectory $root -RedirectStandardOutput $mediaOut -RedirectStandardError $mediaErr -PassThru -WindowStyle Hidden
try {
    Wait-HttpReady 'http://127.0.0.1:9997/v3/config/global/get' | Out-Null

    if ($sourceMode -eq 'multi') {
        $backendConfigPath = Join-Path $runtimeDir 'server-config.json'
        $backendConfig = [ordered]@{
            port = $servicePort
            runtimeDirectory = $runtimeDir
            cameraToolsPath = $config.CameraToolsPath
            cameraUrlFile = if ($config.CameraUrlFile) { $config.CameraUrlFile } else { Join-Path $config.CameraToolsPath 'url.txt' }
            apiBaseUrl = $config.BambuApiBaseUrl
            region = $config.BambuRegion
            clientVersion = $config.BambuClientVersion
            networkVersion = $config.BambuNetworkVersion
            sessionSecret = $config.MultiSessionSecret
            secureCookies = [bool]$config.SecureCookies
        } | ConvertTo-Json
        [IO.File]::WriteAllText($backendConfigPath, $backendConfig, (New-Object Text.UTF8Encoding($false)))
        $backendOut = Join-Path $logDir 'server.log'
        $backendErr = Join-Path $logDir 'server-error.log'
        $node = (Get-Command node.exe -ErrorAction Stop).Source
        $backend = Start-Process $node -ArgumentList @((Join-Path $root 'server\server.js'), $backendConfigPath) -WorkingDirectory $root -RedirectStandardOutput $backendOut -RedirectStandardError $backendErr -PassThru -WindowStyle Hidden
        Wait-HttpReady "http://127.0.0.1:$servicePort/api/config" | Out-Null
    }

    $nginxDir = Join-Path $root 'nginx'
    $nginxExe = Join-Path $root 'tools\nginx\nginx.exe'
    $nginxPrefix = $nginxDir.Replace('\', '/') + '/'
    $nginxArgs = '-p "{0}" -c conf/nginx.conf' -f $nginxPrefix
    $nginxTest = Start-Process $nginxExe -ArgumentList "$nginxArgs -t" -WorkingDirectory $nginxDir -Wait -PassThru -WindowStyle Hidden
    if ($nginxTest.ExitCode -ne 0) { throw 'nginx configuration validation failed.' }
    $nginx = Start-Process $nginxExe -ArgumentList $nginxArgs -WorkingDirectory $nginxDir -RedirectStandardOutput $nginxOut -RedirectStandardError $nginxErr -PassThru -WindowStyle Hidden
    Wait-HttpReady "http://127.0.0.1:$($config.HttpPort)/health" | Out-Null

    if ($sourceMode -eq 'studio-rtp') {
        $supervisorArgs = @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + (Join-Path $PSScriptRoot 'studio-retimer.ps1') + '"'),
            '-FfmpegPath', ('"' + (Join-Path $config.CameraToolsPath 'ffmpeg.exe') + '"'),
            '-LogPath', ('"' + $logDir + '"')
        )
        $supervisor = Start-Process powershell.exe -ArgumentList $supervisorArgs -PassThru -WindowStyle Hidden
    } elseif ($sourceMode -eq 'managed') {
        $supervisorArgs = @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + (Join-Path $PSScriptRoot 'camera-supervisor.ps1') + '"'),
            '-CameraToolsPath', ('"' + $config.CameraToolsPath + '"'),
            '-CameraUrlFile', ('"' + $config.CameraUrlFile + '"'),
            '-StreamName', $config.StreamName,
            '-LogPath', ('"' + $logDir + '"')
        )
        $supervisor = Start-Process powershell.exe -ArgumentList $supervisorArgs -PassThru -WindowStyle Hidden
    }

    [ordered]@{
        startedAt = (Get-Date).ToString('o')
        sourceMode = $sourceMode
        mediaMtxPid = $media.Id
        nginxPid = $nginx.Id
        supervisorPid = $(if ($supervisor) { $supervisor.Id } else { 0 })
        backendPid = $(if ($backend) { $backend.Id } else { 0 })
    } | ConvertTo-Json | Set-Content $stateFile -Encoding ASCII

    [Threading.Thread]::Sleep(3000)
    if ($supervisor -and -not (Test-ProcessId $supervisor.Id)) { throw 'Camera supervisor exited during startup. Check runtime\logs.' }
} catch {
    if ($supervisor) { Stop-Process -Id $supervisor.Id -Force -ErrorAction SilentlyContinue }
    if ($backend) { Stop-Process -Id $backend.Id -Force -ErrorAction SilentlyContinue }
    if ($nginx) { Stop-Process -Id $nginx.Id -Force -ErrorAction SilentlyContinue }
    Stop-Process -Id $media.Id -Force -ErrorAction SilentlyContinue
    Remove-Item $stateFile -Force -ErrorAction SilentlyContinue
    throw
}

Write-Host "Webcam proxy started: http://127.0.0.1:$($config.HttpPort)/"