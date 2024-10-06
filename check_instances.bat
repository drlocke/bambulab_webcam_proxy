@echo off
setlocal enabledelayedexpansion

:: Get the directory where the batch file is located
set "BASE_PATH=%~dp0"
set "BASE_PATH=%BASE_PATH:~0,-1%"  :: Remove the trailing backslash
set PID_PATH=%BASE_PATH%\pids

:: Initialize variables for status
set "NGINX_STATUS=Not running"
set "BAMBU_SOURCE_STATUS=Not running"
set "FFMPEG_STATUS=Not running"

:: Function to check if a process is running based on its PID
set "PROCESS_NAME="
set "PROCESS_PID="

call :check_process "NGINX" "nginx_pid.txt" "nginx.exe"
call :check_process "Bambu Source" "bambu_source_pid.txt" "bambu_source.exe"
call :check_process "FFmpeg" "ffmpeg_pid.txt" "ffmpeg.exe"

:: Display status of services
echo ====================================
echo =   Streaming Services Status      =
echo ====================================
echo NGINX Status        : !NGINX_STATUS!
echo Bambu Source Status : !BAMBU_SOURCE_STATUS!
echo FFmpeg Status       : !FFMPEG_STATUS!
echo ====================================
pause > nul
exit /b

:check_process
set "PROCESS_NAME=%~1"
set "PID_FILE=%PID_PATH%\%~2"
set "PROCESS_EXE=%~3"

if exist "%PID_FILE%" (
    set /p PROCESS_PID=<"%PID_FILE%"
    
    :: Remove any unwanted characters around the PID
    set "PROCESS_PID=!PROCESS_PID:"=!"
    
    tasklist /fi "pid eq !PROCESS_PID!" | find /i "%PROCESS_EXE%" > nul 2>&1
    if !errorlevel! equ 0 (
        if "%PROCESS_NAME%"=="NGINX" set "NGINX_STATUS=Running (PID !PROCESS_PID!)"
        if "%PROCESS_NAME%"=="Bambu Source" set "BAMBU_SOURCE_STATUS=Running (PID !PROCESS_PID!)"
        if "%PROCESS_NAME%"=="FFmpeg" set "FFMPEG_STATUS=Running (PID !PROCESS_PID!)"
    ) else (
        if "%PROCESS_NAME%"=="NGINX" set "NGINX_STATUS=Not running (PID file found but process not active)"
        if "%PROCESS_NAME%"=="Bambu Source" set "BAMBU_SOURCE_STATUS=Not running (PID file found but process not active)"
        if "%PROCESS_NAME%"=="FFmpeg" set "FFMPEG_STATUS=Not running (PID file found but process not active)"
    )
) else (
    if "%PROCESS_NAME%"=="NGINX" set "NGINX_STATUS=Not running (No PID file)"
    if "%PROCESS_NAME%"=="Bambu Source" set "BAMBU_SOURCE_STATUS=Not running (No PID file)"
    if "%PROCESS_NAME%"=="FFmpeg" set "FFMPEG_STATUS=Not running (No PID file)"
)
exit /b
