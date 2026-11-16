$ErrorActionPreference = 'SilentlyContinue'
# Start zapret with the selected strategy.
# The strategy is stored in proxy\zapret-strategy.txt (set by the GUI or
# manually); the default is general (MAX).bat.
# Used by: boot task "zapret-max", watchdog.ps1, zapret-start.bat.
# Respects the stop flag zapret.disabled and skips if already running.

$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $dir

if (Test-Path (Join-Path $dir 'zapret.disabled')) { exit 0 }
if (Get-Process -Name winws -ErrorAction SilentlyContinue) { exit 0 }

$bat = Join-Path $root 'general (MAX).bat'
$strategyFile = Join-Path $dir 'zapret-strategy.txt'
if (Test-Path $strategyFile) {
    $name = (Get-Content -LiteralPath $strategyFile -Raw).Trim()
    if ($name -and $name -match '^[^\\/:*?"<>|]+\.bat$') {
        $candidate = Join-Path $root $name
        if (Test-Path $candidate) { $bat = $candidate }
    }
}

if (-not (Test-Path $bat)) { exit 1 }

Start-Process -FilePath 'cmd.exe' -ArgumentList "/c `"$bat`"" -WindowStyle Minimized

# Give winws a moment to appear so callers can report success.
$timer = [Diagnostics.Stopwatch]::StartNew()
while ($timer.ElapsedMilliseconds -lt 8000) {
    if (Get-Process -Name winws -ErrorAction SilentlyContinue) { exit 0 }
    Start-Sleep -Milliseconds 250
}
exit 2
