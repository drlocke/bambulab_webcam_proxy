@echo off
setlocal enabledelayedexpansion

:: Get the directory where the batch file is located
set "BASE_PATH=%~dp0"
set "BASE_PATH=%BASE_PATH:~0,-1%"  :: Remove the trailing backslash
set PID_PATH=%BASE_PATH%\pids
set LOG_PATH=%PID_PATH%\logs

:: Function to read PID and Start Time, stop the process, and clean up files
set "PROCESS_NAME="
set "PROCESS_PID="
set "PROCESS_START_TIME="

call :stop_process "FFmpeg" "ffmpeg_pid.txt" "ffmpeg_start_time.txt"
call :stop_process "Bambu Source" "bambu_source_pid.txt" "bambu_source_start_time.txt"
call :stop_process "NGINX" "nginx_pid.txt" "nginx_start_time.txt"

echo.
echo.
echo ## All specified streaming services have been stopped ##
echo.
echo Press any key to close this window.
pause > nul
exit /b

:stop_process
set "PROCESS_NAME=%~1"
set "PID_FILE=%PID_PATH%\%~2"
set "START_TIME_FILE=%LOG_PATH%\%~3"

:: Check if PID file exists
if exist "%PID_FILE%" (
    set /p PROCESS_PID=<"%PID_FILE%"
    set /p PROCESS_START_TIME=<"%START_TIME_FILE%"
    
    :: Remove any unwanted characters from the PID and Start Time
    set "PROCESS_PID=!PROCESS_PID:"=!"
    set "PROCESS_START_TIME=!PROCESS_START_TIME:"=!"
    
    :: Check if the process is actually running
    tasklist /fi "pid eq !PROCESS_PID!" 2>nul | find /i "!PROCESS_PID!" >nul
    if !errorlevel! equ 0 (
        :: Process is running, attempt to stop it
        echo Stopping %PROCESS_NAME% instance with PID !PROCESS_PID! and Start Time !PROCESS_START_TIME!...
        taskkill /pid !PROCESS_PID! /f > nul 2>&1
        if !errorlevel! equ 0 (
            echo Successfully stopped %PROCESS_NAME% with PID !PROCESS_PID!.
        ) else (
            echo Failed to stop %PROCESS_NAME% with PID !PROCESS_PID!. It may not be running.
        )
    ) else (
        echo %PROCESS_NAME% is not running, but PID file exists.
    )
    
    :: Delete PID and Start Time files
    echo Removing PID and start time files for %PROCESS_NAME%...
    del "%PID_FILE%" > nul 2>&1
    del "%START_TIME_FILE%" > nul 2>&1
    echo Removed files for %PROCESS_NAME%.
) else (
    echo No %PROCESS_NAME% PID file found. %PROCESS_NAME% might not be running or was started manually.
)
exit /b
