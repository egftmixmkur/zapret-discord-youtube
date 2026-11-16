param(
    [string]$Source = '',
    [string]$Target = '',
    [switch]$Restart
)

$ErrorActionPreference = 'Stop'
# Replace the running ZapretControl.exe with a freshly built copy.
# The running EXE is locked, so this script must run elevated (the GUI itself
# requires administrator rights anyway). Used after build-exe.ps1 -OutputName.

$dir = $PSScriptRoot
if (-not $Source) { $Source = Join-Path $dir 'ZapretControl.new.exe' }
if (-not $Target) { $Target = Join-Path $dir 'ZapretControl.exe' }

if (-not (Test-Path -LiteralPath $Source)) {
    throw "Не найден новый файл: $Source"
}

Get-Process -Name 'ZapretControl' -ErrorAction SilentlyContinue |
    Stop-Process -Force -ErrorAction SilentlyContinue

$copied = $false
for ($i = 0; $i -lt 40; $i++) {
    try {
        Copy-Item -LiteralPath $Source -Destination $Target -Force -ErrorAction Stop
        $copied = $true
        break
    } catch {
        Start-Sleep -Milliseconds 250
    }
}
if (-not $copied) {
    throw "Не удалось заменить $Target (файл занят?). Закройте ZapretControl и повторите."
}

Remove-Item -LiteralPath $Source -Force -ErrorAction SilentlyContinue
$item = Get-Item -LiteralPath $Target
Write-Host "[OK] Обновлено: $Target ($($item.Length) байт)"

if ($Restart) {
    Start-Process -FilePath $Target -WorkingDirectory $dir
    Write-Host '[OK] ZapretControl запущен.'
}
