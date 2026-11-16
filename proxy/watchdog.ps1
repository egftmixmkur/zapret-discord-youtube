$ErrorActionPreference = 'SilentlyContinue'
# zapret LAN watchdog - runs every 5 min from Task Scheduler (SYSTEM).
# Restarts the proxy (and zapret) only if they are enabled and unhealthy.
# Each run is logged to watchdog.log; the log is trimmed to the last 500 lines.

$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$logFile = Join-Path $dir 'watchdog.log'

function Write-Log([string]$message) {
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $message" |
        Out-File -FilePath $logFile -Append -Encoding UTF8
}

function Test-Port([int]$port) {
    return [bool](Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)
}

# Keep the heartbeat log small (it grows every 5 minutes forever otherwise).
if ((Test-Path $logFile) -and ((Get-Item $logFile).Length -gt 128KB)) {
    $tail = Get-Content -LiteralPath $logFile -Tail 500
    $tail | Set-Content -LiteralPath $logFile -Encoding UTF8
}

Write-Log 'watchdog run'

# ---- proxy health ----
if (-not (Test-Path (Join-Path $dir 'proxy.disabled'))) {
    $httpOk = Test-Port 8080
    $socksOk = Test-Port 1080
    if (-not $httpOk -or -not $socksOk) {
        Write-Log "proxy unhealthy (http=$httpOk socks=$socksOk) - restarting"
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dir 'kill-proxy.ps1') | Out-Null
        Start-Sleep -Seconds 1
        schtasks /Run /TN 'zapret-proxy' | Out-Null
        if ($LASTEXITCODE -ne 0) {
            # Task missing: start the script directly as a fallback.
            $pythonw = (Get-Command pythonw.exe -ErrorAction SilentlyContinue).Source
            if ($pythonw) {
                Start-Process -FilePath $pythonw `
                    -ArgumentList ('"' + (Join-Path $dir 'zapret-proxy.py') + '"') `
                    -WorkingDirectory $dir -WindowStyle Hidden
                Write-Log 'proxy task missing - started pythonw directly'
            } else {
                Write-Log 'proxy task missing and pythonw.exe not found'
            }
        }
    }
}

# ---- zapret health (only if autostart enabled and not disabled) ----
if ((Test-Path (Join-Path $dir 'zapret.autostart')) -and
    -not (Test-Path (Join-Path $dir 'zapret.disabled'))) {
    $winws = Get-Process -Name winws -ErrorAction SilentlyContinue
    if (-not $winws) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dir 'zapret-boot.ps1') | Out-Null
        Write-Log 'winws was dead - restarted'
    }
}
