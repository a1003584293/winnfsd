@echo off
setlocal

rem WinNFSd launcher - used by the boot task and for manual starts.
rem WinNFSd's own output is NOT redirected: otherwise this cmd.exe would hold
rem winnfsd.log open for the whole run and the file could not be deleted.
rem Only short start/exit lines are appended, each opening and closing the file.

set "NFSD_DIR=C:\Users\10035\Desktop\winnfsd"
set "NFSD_EXE=%NFSD_DIR%\WinNFSd.exe"
set "NFSD_EXPORTS=%NFSD_DIR%\exports.txt"
set "NFSD_LOG=%NFSD_DIR%\winnfsd.log"

cd /d "%NFSD_DIR%"

tasklist /fi "imagename eq WinNFSd.exe" 2>nul | find /i "WinNFSd.exe" >nul
if not errorlevel 1 (
    echo [NFS] WinNFSd is already running.
    exit /b 0
)

if not exist "%NFSD_EXE%" (
    echo [NFS] Not found: "%NFSD_EXE%"
    exit /b 1
)
if not exist "%NFSD_EXPORTS%" (
    echo [NFS] Not found: "%NFSD_EXPORTS%"
    exit /b 1
)

>>"%NFSD_LOG%" echo ===== started %date% %time% =====

echo [NFS] Starting WinNFSd.
"%NFSD_EXE%" -id 501 20 -addr 0.0.0.0 -log off -pathFile "%NFSD_EXPORTS%"
set "RC=%errorlevel%"

>>"%NFSD_LOG%" echo ===== exited  %date% %time% code %RC% =====
echo [NFS] WinNFSd exited with code %RC%.
exit /b %RC%
