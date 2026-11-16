@echo off
chcp 65001 > nul
:: Stop everything: LAN proxy + zapret. Stays off (sticky flags)
:: until start-all.bat is run again. Watchdog and boot tasks
:: respect the flags, so nothing will restart by itself.

setlocal EnableExtensions

net session >nul 2>&1
if not "%errorlevel%"=="0" (
    echo Requesting administrator rights...
    powershell -NoProfile -Command "Start-Process 'cmd.exe' -ArgumentList '/c \"\"%~f0\" elev\"' -Verb RunAs"
    exit /b
)

echo Stopping zapret LAN proxy and zapret...
type nul > "%~dp0proxy.disabled"
type nul > "%~dp0zapret.disabled"
schtasks /End /TN "zapret-proxy" >nul 2>&1
schtasks /End /TN "zapret-max" >nul 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0kill-proxy.ps1" >nul 2>&1
taskkill /IM winws.exe /F >nul 2>&1
if exist "%~dp0proxy.pid" del /f /q "%~dp0proxy.pid" >nul 2>&1

echo [OK] Everything stopped. It will NOT start again until start-all.bat
echo       is run (watchdog and boot tasks respect the stop flags).
pause
