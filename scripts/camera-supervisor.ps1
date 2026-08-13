param(
    [Parameter(Mandatory = $true)][string] $CameraToolsPath,
    [Parameter(Mandatory = $true)][string] $CameraUrlFile,
    [Parameter(Mandatory = $true)][string] $StreamName,
    [Parameter(Mandatory = $true)][string] $LogPath
)

$ErrorActionPreference = 'Stop'
$sourceExe = Join-Path $CameraToolsPath 'bambu_source.exe'
$ffmpegExe = Join-Path $CameraToolsPath 'ffmpeg.exe'
$sourceLog = Join-Path $LogPath 'camera-source.log'
$ffmpegLog = Join-Path $LogPath 'ffmpeg.log'
$cameraPath = $CameraUrlFile.Replace('\', '/')
$cameraUri = "bambu:///camera/$cameraPath"

while ($true) {
    $command = '""{0}" "{1}" 2>>"{2}" | "{3}" -hide_banner -loglevel warning -fflags nobuffer -flags low_delay -use_wallclock_as_timestamps 1 -analyzeduration 100000 -probesize 32768 -f h264 -i pipe:0 -an -c:v copy -f rtsp -rtsp_transport tcp "rtsp://127.0.0.1:8554/{4}" 2>>"{5}""' -f $sourceExe, $cameraUri, $sourceLog, $ffmpegExe, $StreamName, $ffmpegLog
    Add-Content (Join-Path $LogPath 'supervisor.log') "$(Get-Date -Format o) Starting camera pipeline."
    $process = Start-Process $env:ComSpec -ArgumentList '/d', '/s', '/c', $command -PassThru -WindowStyle Hidden
    $process.WaitForExit()
    Add-Content (Join-Path $LogPath 'supervisor.log') "$(Get-Date -Format o) Pipeline exited with code $($process.ExitCode); restarting in 2 seconds."
    [Threading.Thread]::Sleep(2000)
}