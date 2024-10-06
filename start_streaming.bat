@echo off
setlocal enabledelayedexpansion

:: Get the directory where the batch file is located
set "BASE_PATH=%~dp0"
set "BASE_PATH=%BASE_PATH:~0,-1%"  :: Remove the trailing backslash

:: Define paths relative to the batch file location
set NGINX_PATH=%BASE_PATH%\nginx
set BAMBU_SOURCE_PATH=%BASE_PATH%\bambu_source.exe
set FFMPEG_PATH=%BASE_PATH%\ffmpeg.exe
set URL_FILE=%BASE_PATH%\url.txt
set PID_PATH=%BASE_PATH%\pids
set LOG_PATH=%PID_PATH%\logs

:: Create directories to store PID and log files if they don't exist
if not exist "%PID_PATH%" mkdir "%PID_PATH%"
if not exist "%LOG_PATH%" mkdir "%LOG_PATH%"

:: Initialize variables
set "NGINX_PID="
set "BAMBU_SOURCE_PID="
set "FFMPEG_PID="
set "NGINX_START_TIME="
set "BAMBU_SOURCE_START_TIME="
set "FFMPEG_START_TIME="

:: Read the full URL parameter from url.txt using delayed expansion to avoid cutting on special characters
set "URL_PARAMETER="
for /f "delims=" %%a in (%URL_FILE%) do set "URL_PARAMETER=%%a"

:: Check if the URL_PARAMETER is empty
if "!URL_PARAMETER!"=="" (
    echo [ERROR] URL file "%URL_FILE%" is empty or not found. Please create the file and add the Bambu source parameter.
    pause
    exit /b
)

:: Start NGINX and capture its start time and PID
echo Starting NGINX server from %NGINX_PATH%...
cd /d %NGINX_PATH%
start "" nginx.exe
timeout /t 3 > nul

:: Capture NGINX PID using tasklist and filter out unwanted characters
for /f "tokens=2 delims=," %%a in ('tasklist /fi "imagename eq nginx.exe" /fo csv /nh') do (
    set "NGINX_PID=%%~a"
)

:: Validate captured NGINX PID
if "!NGINX_PID!"=="" (
    echo [ERROR] Failed to capture NGINX PID.
) else (
    :: Capture NGINX start time using WMIC
    for /f "tokens=2 delims==" %%a in ('wmic process where "processid=!NGINX_PID!" get creationdate /format:list ^| findstr "="') do (
        set "NGINX_START_TIME=%%a"
    )
)

:: Validate NGINX start time
if "!NGINX_START_TIME!"=="" (
    echo [ERROR] Failed to retrieve NGINX start time. Using default value.
    set "NGINX_START_TIME=Unknown"
)

echo NGINX started with PID !NGINX_PID! and start time !NGINX_START_TIME!
echo !NGINX_PID! > "%PID_PATH%\nginx_pid.txt"
echo !NGINX_START_TIME! > "%LOG_PATH%\nginx_start_time.txt"

:: Start Bambu Source and FFmpeg stream using URL from file
echo Starting Bambu Source and FFmpeg stream with URL: !URL_PARAMETER! ...
start "" cmd /c ""%BAMBU_SOURCE_PATH%" "!URL_PARAMETER!" | "%FFMPEG_PATH%" -fflags nobuffer -flags low_delay -analyzeduration 10 -probesize 3200 -f h264 -i pipe: -c:v copy -f flv rtmp://localhost/live/stream"

:: Wait for a moment to allow processes to start
timeout /t 5 > nul

:: Capture Bambu Source PID using tasklist and filter out unwanted characters
for /f "tokens=2 delims=," %%a in ('tasklist /fi "imagename eq bambu_source.exe" /fo csv /nh') do (
    set "BAMBU_SOURCE_PID=%%~a"
)

:: Validate captured Bambu Source PID
if "!BAMBU_SOURCE_PID!"=="" (
    echo [ERROR] Failed to capture Bambu Source PID.
) else (
    :: Capture Bambu Source start time using WMIC
    for /f "tokens=2 delims==" %%a in ('wmic process where "processid=!BAMBU_SOURCE_PID!" get creationdate /format:list ^| findstr "="') do (
        set "BAMBU_SOURCE_START_TIME=%%a"
    )
)

:: Validate Bambu Source start time
if "!BAMBU_SOURCE_START_TIME!"=="" (
    echo [ERROR] Failed to retrieve Bambu Source start time. Using default value.
    set "BAMBU_SOURCE_START_TIME=Unknown"
)

echo Bambu Source started with PID !BAMBU_SOURCE_PID! and start time !BAMBU_SOURCE_START_TIME!
echo !BAMBU_SOURCE_PID! > "%PID_PATH%\bambu_source_pid.txt"
echo !BAMBU_SOURCE_START_TIME! > "%LOG_PATH%\bambu_source_start_time.txt"

:: Capture FFmpeg PID using tasklist and filter out unwanted characters
for /f "tokens=2 delims=," %%a in ('tasklist /fi "imagename eq ffmpeg.exe" /fo csv /nh') do (
    set "FFMPEG_PID=%%~a"
)

:: Validate captured FFmpeg PID
if "!FFMPEG_PID!"=="" (
    echo [ERROR] Failed to capture FFmpeg PID.
) else (
    :: Capture FFmpeg start time using WMIC
    for /f "tokens=2 delims==" %%a in ('wmic process where "processid=!FFMPEG_PID!" get creationdate /format:list ^| findstr "="') do (
        set "FFMPEG_START_TIME=%%a"
    )
)

:: Validate FFmpeg start time
if "!FFMPEG_START_TIME!"=="" (
    echo [ERROR] Failed to retrieve FFmpeg start time. Using default value.
    set "FFMPEG_START_TIME=Unknown"
)

echo FFmpeg started with PID !FFMPEG_PID! and start time !FFMPEG_START_TIME!
echo !FFMPEG_PID! > "%PID_PATH%\ffmpeg_pid.txt"
echo !FFMPEG_START_TIME! > "%LOG_PATH%\ffmpeg_start_time.txt"

:: Output information
echo ====================================
echo = All services have been started!  =
echo ====================================
echo NGINX PID         : !NGINX_PID! - Start Time: !NGINX_START_TIME!
echo Bambu Source PID  : !BAMBU_SOURCE_PID! - Start Time: !BAMBU_SOURCE_START_TIME!
echo FFmpeg PID        : !FFMPEG_PID! - Start Time: !FFMPEG_START_TIME!
echo ====================================
echo.
echo Open VLC or another media player and use the URL: http://127.0.0.1:8090/hls/stream.m3u8 to view the stream.
echo.
echo Press any key to close this window.
pause > nul
