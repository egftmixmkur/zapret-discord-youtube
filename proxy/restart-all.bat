@echo off
chcp 65001 > nul
:: Restart everything: stop-all.bat then start-all.bat.
:: Both scripts request elevation themselves; <nul skips their pauses.
setlocal EnableExtensions

echo Restarting zapret LAN proxy and zapret...
call "%~dp0stop-all.bat" <nul
call "%~dp0start-all.bat" <nul

echo.
echo [OK] Restart complete.
pause
