param(
    [Parameter(Mandatory = $true)][string] $FfmpegPath,
    [Parameter(Mandatory = $true)][string] $LogPath
)

$ErrorActionPreference = 'Stop'
$ffmpegLog = Join-Path $LogPath 'studio-retimer.log'
$supervisorLog = Join-Path $LogPath 'supervisor.log'

while ($true) {
    Add-Content $supervisorLog "$(Get-Date -Format o) Starting Studio RTP packet retimer."
    $arguments = @(
        '-hide_banner', '-loglevel', 'warning',
        '-fflags', 'nobuffer', '-flags', 'low_delay',
        '-analyzeduration', '100000', '-probesize', '32768',
        '-rtsp_transport', 'tcp', '-i', 'rtsp://127.0.0.1:8554/studio_raw',
        '-map', '0:v:0', '-an',
        '-c:v', 'copy',
        '-bsf:v', 'setts=pts=N*3000:dts=N*3000:duration=3000:time_base=1/90000',
        '-muxdelay', '0', '-f', 'rtsp', '-rtsp_transport', 'tcp',
        'rtsp://127.0.0.1:8554/bambu'
    )
    $process = Start-Process $FfmpegPath -ArgumentList $arguments -RedirectStandardError $ffmpegLog -PassThru -WindowStyle Hidden
    $process.WaitForExit()
    Add-Content $supervisorLog "$(Get-Date -Format o) Studio RTP packet retimer exited with code $($process.ExitCode); restarting in 2 seconds."
    [Threading.Thread]::Sleep(2000)
}