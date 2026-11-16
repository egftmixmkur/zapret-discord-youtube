@echo off
chcp 65001 > nul
:: Full removal of the LAN setup added by start-all.bat:
:: scheduled tasks, firewall rules, stop flags, processes.
:: Files in this folder are kept.

setlocal EnableExtensions

net session >nul 2>&1
if not "%errorlevel%"=="0" (
    echo Requesting administrator rights...
    powershell -NoProfile -Command "Start-Process 'cmd.exe' -ArgumentList '/c \"\"%~f0\" elev\"' -Verb RunAs"
    exit /b
)

echo Removing zapret LAN setup...

schtasks /End /TN "zapret-proxy" >nul 2>&1
schtasks /Delete /TN "zapret-proxy" /F >nul 2>&1
schtasks /End /TN "zapret-proxy-watchdog" >nul 2>&1
schtasks /Delete /TN "zapret-proxy-watchdog" /F >nul 2>&1
schtasks /End /TN "zapret-max" >nul 2>&1
schtasks /Delete /TN "zapret-max" /F >nul 2>&1
echo [OK] Scheduled tasks removed

netsh advfirewall firewall delete rule name="zapret LAN proxy" >nul 2>&1
netsh advfirewall firewall delete rule name="zapret LAN proxy UDP" >nul 2>&1
echo [OK] Firewall rules removed

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0kill-proxy.ps1" >nul 2>&1
taskkill /IM winws.exe /F >nul 2>&1
del /f /q "%~dp0proxy.disabled" "%~dp0zapret.disabled" "%~dp0zapret.autostart" "%~dp0proxy.pid" >nul 2>&1
echo [OK] Processes stopped

echo Done. To use it again, run start-all.bat
pause
