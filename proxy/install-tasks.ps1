param(
    [string]$Pythonw = ''
)

$ErrorActionPreference = 'Stop'
# Register the three scheduled tasks used by the LAN setup.
# PowerShell cmdlets are used instead of "schtasks /TR" so that paths with
# spaces are quoted correctly. Idempotent: existing tasks are replaced.

$dir = $PSScriptRoot
$root = Split-Path -Parent $dir

function Find-Pythonw {
    if ($Pythonw -and (Test-Path -LiteralPath $Pythonw)) { return $Pythonw }
    foreach ($name in 'pythonw.exe', 'python.exe') {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd) {
            $path = $cmd.Source
            if ($name -eq 'python.exe') {
                $candidate = $path -replace 'python\.exe$', 'pythonw.exe'
                if (Test-Path -LiteralPath $candidate) { return $candidate }
            }
            return $path
        }
    }
    foreach ($ver in '313', '312', '311', '310') {
        $candidate = Join-Path $env:LocalAppData "Programs\Python\Python$ver\pythonw.exe"
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return $null
}

$pythonw = Find-Pythonw
if (-not $pythonw) { throw 'Python 3 not found (pythonw.exe/python.exe)' }
if (-not (Test-Path (Join-Path $dir 'zapret-proxy.py'))) {
    throw "zapret-proxy.py not found in $dir"
}

$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' `
    -LogonType ServiceAccount -RunLevel Highest

$proxyAction = New-ScheduledTaskAction -Execute $pythonw `
    -Argument ('"' + (Join-Path $dir 'zapret-proxy.py') + '"') `
    -WorkingDirectory $dir
$proxyTrigger = New-ScheduledTaskTrigger -AtStartup
$proxySettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries -StartWhenAvailable `
    -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero)
Register-ScheduledTask -TaskName 'zapret-proxy' -Action $proxyAction `
    -Trigger $proxyTrigger -Principal $principal -Settings $proxySettings `
    -Description 'zapret LAN proxy (HTTP/SOCKS5)' -Force | Out-Null
Write-Output '[OK] task zapret-proxy'

$watchdogAction = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument ('-NoProfile -ExecutionPolicy Bypass -File "' +
        (Join-Path $dir 'watchdog.ps1') + '"') `
    -WorkingDirectory $dir
$watchdogTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes 5) `
    -RepetitionDuration ([TimeSpan]::FromDays(3650))
$watchdogSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
Register-ScheduledTask -TaskName 'zapret-proxy-watchdog' -Action $watchdogAction `
    -Trigger $watchdogTrigger -Principal $principal -Settings $watchdogSettings `
    -Description 'zapret LAN proxy watchdog (every 5 minutes)' -Force | Out-Null
Write-Output '[OK] task zapret-proxy-watchdog'

$bootAction = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument ('-NoProfile -ExecutionPolicy Bypass -File "' +
        (Join-Path $dir 'zapret-boot.ps1') + '"') `
    -WorkingDirectory $dir
$bootTrigger = New-ScheduledTaskTrigger -AtStartup
$bootSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
Register-ScheduledTask -TaskName 'zapret-max' -Action $bootAction `
    -Trigger $bootTrigger -Principal $principal -Settings $bootSettings `
    -Description 'zapret DPI bypass autostart (selected strategy)' -Force | Out-Null
Write-Output '[OK] task zapret-max'

Write-Output "Python: $pythonw"
