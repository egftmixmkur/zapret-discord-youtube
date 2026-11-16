@echo off
chcp 65001 > nul
:: Show LAN IP and ready-to-use proxy addresses

setlocal EnableExtensions
set "LAN_IP="
for /f "delims=" %%A in ('powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0get-lan-ip.ps1"') do set "LAN_IP=%%A"
if not defined LAN_IP set "LAN_IP=UNKNOWN"

echo   This PC LAN IP : %LAN_IP%
echo   HTTP proxy     : %LAN_IP%:8080
echo   SOCKS5 proxy   : %LAN_IP%:1080
