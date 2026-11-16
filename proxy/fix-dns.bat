@echo off
chcp 65001 > nul
:: Switch this PC to DNS-over-HTTPS (Google + Cloudflare) via Windows native DoH.
:: Needed because the provider hijacks plain DNS (all UDP 53 traffic, even
:: queries to 8.8.8.8, get fake NXDOMAIN answers for blocked sites).
:: Idempotent - safe to run any number of times.

setlocal EnableExtensions

net session >nul 2>&1
if not "%errorlevel%"=="0" (
    echo Requesting administrator rights...
    powershell -NoProfile -Command "Start-Process 'cmd.exe' -ArgumentList '/c \"\"%~f0\" elev\"' -Verb RunAs"
    exit /b
)

echo Setting DNS-over-HTTPS (Google + Cloudflare)...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0fix-dns.ps1"
echo.
pause
