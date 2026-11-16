@echo off
chcp 65001 > nul
:: Start only zapret (MAX strategy). Proxy keeps running if it was running.

setlocal EnableExtensions

net session >nul 2>&1
if not "%errorlevel%"=="0" (
    echo Requesting administrator rights...
    powershell -NoProfile -Command "Start-Process 'cmd.exe' -ArgumentList '/c \"\"%~f0\" elev\"' -Verb RunAs"
    exit /b
)

if exist "%~dp0zapret.disabled" del /f /q "%~dp0zapret.disabled" >nul 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0zapret-boot.ps1"
echo [OK] zapret starting (general ^(MAX^).bat)
pause
