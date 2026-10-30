@echo off
setlocal

rem Registers WinNFSd as a boot-time task running with full rights (as SYSTEM).
rem Usage: right-click -> "Run as administrator"
rem        install-autostart.bat             install
rem        install-autostart.bat /uninstall  remove

set "NFSD_DIR=C:\Users\10035\Desktop\winnfsd"
set "TASK_NAME=WinNFSd"

net session >nul 2>&1
if errorlevel 1 goto :need_admin

if /i "%~1"=="/uninstall" goto :uninstall

schtasks /Create /TN "%TASK_NAME%" /TR "\"%NFSD_DIR%\start-nfsd.bat\"" /SC ONSTART /RU SYSTEM /F
if errorlevel 1 goto :create_failed

rem NFS v3 needs three ports: 111 portmapper, 1058 mountd, 2049 nfs.
netsh advfirewall firewall delete rule name="WinNFSd TCP" >nul 2>&1
netsh advfirewall firewall delete rule name="WinNFSd UDP" >nul 2>&1
netsh advfirewall firewall add rule name="WinNFSd TCP" dir=in action=allow protocol=TCP localport=111,1058,2049 >nul
netsh advfirewall firewall add rule name="WinNFSd UDP" dir=in action=allow protocol=UDP localport=111,1058,2049 >nul

echo [NFS] Task "%TASK_NAME%" created. It runs as SYSTEM at every boot, no UAC prompt.
echo        Start now : schtasks /Run /TN "%TASK_NAME%"
echo        Stop      : schtasks /End /TN "%TASK_NAME%"
echo        Uninstall : install-autostart.bat /uninstall
echo        Log file  : %NFSD_DIR%\winnfsd.log (start/exit lines only, never locked)
goto :done

:uninstall
schtasks /End /TN "%TASK_NAME%" >nul 2>&1
schtasks /Delete /TN "%TASK_NAME%" /F >nul 2>&1
netsh advfirewall firewall delete rule name="WinNFSd TCP" >nul 2>&1
netsh advfirewall firewall delete rule name="WinNFSd UDP" >nul 2>&1
taskkill /f /im WinNFSd.exe >nul 2>&1
echo [NFS] Autostart removed.
goto :done

:need_admin
echo [NFS] Please right-click this file and choose "Run as administrator".
goto :done

:create_failed
echo [NFS] Failed to create the scheduled task.

:done
echo.
pause
exit /b 0
