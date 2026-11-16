@echo off
chcp 65001 > nul
:: Stop only zapret (DPI bypass). LAN proxy keeps running.
:: Sticky: zapret stays off until zapret-start.bat or start-all.bat.

setlocal EnableExtensions

net session >nul 2>&1
if not "%errorlevel%"=="0" (
    echo Requesting administrator rights...
    powershell -NoProfile -Command "Start-Process 'cmd.exe' -ArgumentList '/c \"\"%~f0\" elev\"' -Verb RunAs"
    exit /b
)

echo Stopping zapret...
type nul > "%~dp0zapret.disabled"
schtasks /End /TN "zapret-max" >nul 2>&1
taskkill /IM winws.exe /F >nul 2>&1
echo [OK] zapret stopped. Start it again with zapret-start.bat or start-all.bat
pause
