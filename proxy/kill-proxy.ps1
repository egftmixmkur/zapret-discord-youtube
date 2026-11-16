$ErrorActionPreference = 'SilentlyContinue'
# Kill all instances of zapret-proxy.py (by command line, not by pid file)
# and remove the stale pid file.

Get-CimInstance Win32_Process -Filter "Name='pythonw.exe' OR Name='python.exe'" |
    Where-Object { $_.CommandLine -like '*zapret-proxy.py*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }

Remove-Item -LiteralPath (Join-Path $PSScriptRoot 'proxy.pid') -Force
