@echo off
chcp 65001 > nul
:: Install and start everything: LAN proxy + zapret (MAX strategy).
:: Safe to run any number of times (also acts as "restart").
:: Progress is logged to setup.log in this folder.
:: See README.md (Russian) in this folder.

setlocal EnableExtensions

:: ---- self-elevation (service.bat pattern, with trailing quote!) ----
net session >nul 2>&1
if not "%errorlevel%"=="0" (
    echo Requesting administrator rights...
    powershell -NoProfile -Command "Start-Process 'cmd.exe' -ArgumentList '/c \"\"%~f0\" elev\"' -Verb RunAs"
    exit /b
)

set "PDIR=%~dp0"
set "LOG=%PDIR%setup.log"
echo %date% %time%: start-all.bat: begin, user=%UserName% > "%LOG%"

:: ---- clear stop flags ----
if exist "%PDIR%proxy.disabled" del /f /q "%PDIR%proxy.disabled" >nul 2>&1
if exist "%PDIR%zapret.disabled" del /f /q "%PDIR%zapret.disabled" >nul 2>&1

:: ---- stop old proxy instances (by command line, reliable) ----
powershell -NoProfile -ExecutionPolicy Bypass -File "%PDIR%kill-proxy.ps1" >nul 2>&1
if exist "%PDIR%proxy.pid" del /f /q "%PDIR%proxy.pid" >nul 2>&1

:: ---- locate pythonw.exe ----
set "PYTHONW="
where pythonw >nul 2>&1 && for /f "delims=" %%P in ('where pythonw') do if not defined PYTHONW set "PYTHONW=%%~fP"
if not defined PYTHONW (
    where python >nul 2>&1 && for /f "delims=" %%P in ('where python') do if not defined PYTHONW set "PYTHONW=%%~fP"
)
if not defined PYTHONW if exist "%LocalAppData%\Programs\Python\Python313\pythonw.exe" set "PYTHONW=%LocalAppData%\Programs\Python\Python313\pythonw.exe"
if not defined PYTHONW if exist "%LocalAppData%\Programs\Python\Python312\pythonw.exe" set "PYTHONW=%LocalAppData%\Programs\Python\Python312\pythonw.exe"
if not defined PYTHONW (
    echo [ERROR] Python 3 not found. Install it from python.org
    echo         and select "Add python.exe to PATH" during setup.
    echo %date% %time%: ERROR: python not found >> "%LOG%"
    pause
    exit /b 1
)
:: python.exe -> pythonw.exe (no console window)
set "PYTHONW=%PYTHONW:python.exe=pythonw.exe%"
if not exist "%PYTHONW%" set "PYTHONW=%PYTHONW:pythonw.exe=python.exe%"
if not exist "%PYTHONW%" (
    echo [ERROR] Python executable not found: %PYTHONW%
    echo %date% %time%: ERROR: python missing: %PYTHONW% >> "%LOG%"
    pause
    exit /b 1
)
echo Using Python: %PYTHONW%
echo %date% %time%: python = %PYTHONW% >> "%LOG%"

:: ---- scheduled tasks (quoted paths via PowerShell, fallback to schtasks) ----
powershell -NoProfile -ExecutionPolicy Bypass -File "%PDIR%install-tasks.ps1" -Pythonw "%PYTHONW%"
if errorlevel 1 (
    echo [WARN] PowerShell task registration failed, falling back to schtasks...
    schtasks /Create /TN "zapret-proxy" /SC ONSTART /RU SYSTEM /RL HIGHEST /F /TR "%PYTHONW% %PDIR%zapret-proxy.py" >nul 2>&1
    schtasks /Create /TN "zapret-proxy-watchdog" /SC MINUTE /MO 5 /RU SYSTEM /RL HIGHEST /F /TR "powershell -NoProfile -ExecutionPolicy Bypass -File %PDIR%watchdog.ps1" >nul 2>&1
    schtasks /Create /TN "zapret-max" /SC ONSTART /RU SYSTEM /RL HIGHEST /F /TR "powershell -NoProfile -ExecutionPolicy Bypass -File %PDIR%zapret-boot.ps1" >nul 2>&1
)
echo %date% %time%: scheduled tasks registered rc=%errorlevel% >> "%LOG%"
:: zapret autostart flag: watchdog keeps winws alive
type nul > "%PDIR%zapret.autostart"

:: ---- firewall rules (LAN only, idempotent) ----
netsh advfirewall firewall delete rule name="zapret LAN proxy" >nul 2>&1
netsh advfirewall firewall delete rule name="zapret LAN proxy UDP" >nul 2>&1
netsh advfirewall firewall add rule name="zapret LAN proxy" dir=in action=allow protocol=TCP localport=8080,1080 remoteip=192.168.0.0/16,10.0.0.0/8,172.16.0.0/12 profile=any >nul 2>&1
echo %date% %time%: firewall rule TCP rc=%errorlevel% >> "%LOG%"
netsh advfirewall firewall add rule name="zapret LAN proxy UDP" dir=in action=allow protocol=UDP localport=31000-31999 remoteip=192.168.0.0/16,10.0.0.0/8,172.16.0.0/12 profile=any >nul 2>&1
echo %date% %time%: firewall rule UDP rc=%errorlevel% >> "%LOG%"

:: ---- clean broken hosts entries (old ZapretGUI Discord mappings) ----
powershell -NoProfile -ExecutionPolicy Bypass -File "%PDIR%fix-hosts.ps1"
echo %date% %time%: hosts cleanup rc=%errorlevel% >> "%LOG%"

:: ---- system DNS-over-HTTPS (provider hijacks plain DNS with fake NXDOMAIN) ----
powershell -NoProfile -ExecutionPolicy Bypass -File "%PDIR%fix-dns.ps1"
echo %date% %time%: dns fix rc=%errorlevel% >> "%LOG%"

:: ---- start everything ----
schtasks /Run /TN "zapret-proxy" >nul 2>&1
echo %date% %time%: run zapret-proxy rc=%errorlevel% >> "%LOG%"
schtasks /Run /TN "zapret-max" >nul 2>&1
echo %date% %time%: run zapret-max rc=%errorlevel% >> "%LOG%"
timeout /t 8 /nobreak >nul

:: ---- status ----
echo.
echo === zapret LAN setup: started ===
netstat -an -p tcp | findstr /C:":8080 " | findstr LISTENING >nul && echo   [OK] LAN proxy running :8080 (http) :1080 (socks5) || echo   [!] proxy NOT running, see proxy\proxy.log
tasklist | findstr winws >nul && echo   [OK] zapret (winws) running || echo   [!] zapret NOT running
echo %date% %time%: setup finished >> "%LOG%"
echo.
call "%PDIR%show-lan-ip.bat"
echo.
echo Control: stop-all.bat (stop everything), zapret-stop.bat (zapret only)
echo.
pause
