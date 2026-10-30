@echo off
setlocal enabledelayedexpansion

rem Restarts WinNFSd through the scheduled task, so it keeps running as SYSTEM.
rem Double-click it, or let it self-elevate when UAC is required.

set "NFSD_DIR=C:\Users\10035\Desktop\winnfsd"
set "TASK_NAME=WinNFSd"

net session >nul 2>&1
if errorlevel 1 (
    echo [NFS] Requesting administrator rights...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

echo [NFS] Stopping WinNFSd...
schtasks /Query /TN "%TASK_NAME%" >nul 2>&1
if errorlevel 1 (
    taskkill /f /im WinNFSd.exe >nul 2>&1
) else (
    schtasks /End /TN "%TASK_NAME%" >nul 2>&1
    taskkill /f /im WinNFSd.exe >nul 2>&1
)

set /a n=0
:wait_stop
tasklist /fi "imagename eq WinNFSd.exe" 2>nul | find /i "WinNFSd.exe" >nul
if errorlevel 1 goto :stopped
set /a n+=1
if !n! geq 15 goto :stuck
ping -n 2 127.0.0.1 >nul
goto :wait_stop

:stuck
echo [NFS] Could not stop WinNFSd. Close it manually and retry.
pause
exit /b 1

:stopped
echo [NFS] Starting WinNFSd...
schtasks /Query /TN "%TASK_NAME%" >nul 2>&1
if errorlevel 1 (
    start "" "%NFSD_DIR%\start-nfsd.bat"
) else (
    schtasks /Run /TN "%TASK_NAME%" >nul
)

set /a n=0
:wait_start
netstat -ano | findstr /c:":2049" | findstr /i "LISTENING" >nul
if not errorlevel 1 goto :ok
set /a n+=1
if !n! geq 15 goto :failed
ping -n 2 127.0.0.1 >nul
goto :wait_start

:ok
echo [NFS] Restarted. Listening on TCP/UDP 111, 1058, 2049.
echo       Log: %NFSD_DIR%\winnfsd.log
echo.
echo       Note: an already mounted Mac volume goes stale after a restart,
echo       just unmount and run mount_nfs.sh again.
pause
exit /b 0

:failed
echo [NFS] Port 2049 is not listening. Check %NFSD_DIR%\winnfsd.log
pause
exit /b 1
