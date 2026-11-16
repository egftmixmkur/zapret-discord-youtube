param(
    [switch]$Quiet,
    [switch]$KeepFiles,
    [switch]$KeepSystem,
    [switch]$KeepRegistry,
    [switch]$KeepShortcuts
)

$ErrorActionPreference = 'Continue'
$AppName = 'ZAPRET CONTROL'
$dir = $PSScriptRoot
$root = Split-Path -Parent $dir
$logFile = Join-Path $env:TEMP 'zapret-uninstall.log'

function Write-UninstallLog([string]$text) {
    try {
        $line = '{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $text
        Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
    } catch { }
}

Write-UninstallLog "uninstall start: dir=$dir root=$root quiet=$Quiet"

$isAdmin = ([Security.Principal.WindowsPrincipal] `
        [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin -and -not $Quiet) {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    foreach ($pair in @(
            @('Quiet', $Quiet), @('KeepFiles', $KeepFiles), @('KeepSystem', $KeepSystem),
            @('KeepRegistry', $KeepRegistry), @('KeepShortcuts', $KeepShortcuts))) {
        if ($pair[1]) { $argList += ('-' + $pair[0]) }
    }
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList
    } catch {
        [Windows.Forms.MessageBox]::Show(
            'Для удаления нужны права администратора.', $AppName, 'OK', 'Error') | Out-Null
    }
    exit
}

# Удаляем папку программы только если это действительно установка,
# а не рабочая копия проекта (иначе можно случайно снести исходники).
$marker = Join-Path $dir 'install-info.json'
if (-not $KeepFiles -and -not (Test-Path -LiteralPath $marker)) {
    $KeepFiles = $true
    Write-UninstallLog 'no install-info.json -> KeepFiles forced'
}

if (-not $Quiet) {
    Add-Type -AssemblyName System.Windows.Forms
    $message = "Удалить $AppName?`r`n`r`nПапка: $root`r`n`r`n" +
        'Будут остановлены процессы, удалены задачи планировщика, правила' +
        "брандмауэра и ярлыки.`r`n"
    if ($KeepFiles) {
        $message += "`r`nФайлы программы останутся на месте (папка не помечена как установка)."
    } else {
        $message += "`r`nФайлы программы будут удалены."
    }
    $answer = [Windows.Forms.MessageBox]::Show($message, "Удаление $AppName",
        [Windows.Forms.MessageBoxButtons]::YesNo,
        [Windows.Forms.MessageBoxIcon]::Warning)
    if ($answer -ne [Windows.Forms.DialogResult]::Yes) {
        exit 0
    }
}

# ---- процессы ----
foreach ($name in 'ZapretControl', 'winws') {
    Get-Process -Name $name -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
}
Get-CimInstance Win32_Process -Filter "Name='python.exe' OR Name='pythonw.exe'" `
    -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -like '*zapret-proxy.py*' } |
    ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }
Write-UninstallLog 'processes stopped'

# ---- задачи планировщика ----
if (-not $KeepSystem) {
    foreach ($task in 'zapret-proxy', 'zapret-proxy-watchdog', 'zapret-max') {
        try {
            Unregister-ScheduledTask -TaskName $task -Confirm:$false `
                -ErrorAction Stop
            Write-UninstallLog "task removed: $task"
        } catch { }
    }
    try {
        Get-NetFirewallRule -DisplayName 'zapret LAN proxy*' -ErrorAction Stop |
            Remove-NetFirewallRule -ErrorAction SilentlyContinue
        Write-UninstallLog 'firewall rules removed'
    } catch { }
}

# ---- ярлыки ----
if (-not $KeepShortcuts) {
    $desktopDirs = @(
        [Environment]::GetFolderPath('Desktop'),
        (Join-Path $env:PUBLIC 'Desktop'),
        (Join-Path $env:USERPROFILE 'Desktop')
    ) | Where-Object { $_ } | Select-Object -Unique
    foreach ($desktop in $desktopDirs) {
        Remove-Item -LiteralPath (Join-Path $desktop 'ZAPRET CONTROL.lnk') `
            -Force -ErrorAction SilentlyContinue
    }
    $menuDirs = @(
        (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\ZAPRET CONTROL'),
        (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\ZAPRET CONTROL')
    )
    foreach ($menu in $menuDirs) {
        Remove-Item -LiteralPath $menu -Recurse -Force -ErrorAction SilentlyContinue
    }
    foreach ($menu in @(
            (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'),
            (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'))) {
        Remove-Item -LiteralPath (Join-Path $menu 'ZAPRET CONTROL.lnk') `
            -Force -ErrorAction SilentlyContinue
    }
    Write-UninstallLog 'shortcuts removed'
}

# ---- запись в «Установка и удаление программ» ----
if (-not $KeepRegistry) {
    Remove-Item -LiteralPath 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\ZapretControl' `
        -Recurse -Force -ErrorAction SilentlyContinue
    Write-UninstallLog 'registry entry removed'
}

# ---- файлы ----
if (-not $KeepFiles) {
    # Скрипт лежит внутри удаляемой папки, поэтому удаляем с задержкой.
    $cmd = 'timeout /t 2 /nobreak >nul & rmdir /s /q "' + $root + '"'
    try {
        Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', $cmd) `
            -WindowStyle Hidden | Out-Null
        Write-UninstallLog "folder removal scheduled: $root"
    } catch {
        Write-UninstallLog "folder removal failed: $($_.Exception.Message)"
    }
}

if (-not $Quiet) {
    [Windows.Forms.MessageBox]::Show(
        "$AppName удалён." + $(if ($KeepFiles) { "`r`nФайлы остались в: $root" } else { '' }),
        $AppName, 'OK', 'Information') | Out-Null
}

Write-UninstallLog 'uninstall done'
exit 0
