param(
    [switch]$TestBuild,
    [string]$OutputName = ''
)

$ErrorActionPreference = 'Stop'
# Build ZapretControl.exe from zapret-gui.ps1 using the bundled ps2exe module.
# Usage:
#   powershell -ExecutionPolicy Bypass -File build-exe.ps1
#   powershell -ExecutionPolicy Bypass -File build-exe.ps1 -TestBuild   (no UAC manifest)

$dir = $PSScriptRoot
$module = Join-Path $dir 'tools\ps2exe\ps2exe.psd1'
$script = Join-Path $dir 'zapret-gui.ps1'
$icon = Join-Path $dir 'zapret.ico'

if (-not (Test-Path -LiteralPath $module)) {
    throw "ps2exe module not found: $module"
}
if (-not (Test-Path -LiteralPath $script)) {
    throw "GUI script not found: $script"
}

# Extract the zapret icon once (from bin\winws.exe) so the EXE looks native.
if (-not (Test-Path -LiteralPath $icon)) {
    $winws = Join-Path (Split-Path -Parent $dir) 'bin\winws.exe'
    if (Test-Path -LiteralPath $winws) {
        Add-Type -AssemblyName System.Drawing
        $extracted = [System.Drawing.Icon]::ExtractAssociatedIcon($winws)
        $stream = [IO.File]::Create($icon)
        $extracted.Save($stream)
        $stream.Close()
        $extracted.Dispose()
    }
}

Import-Module $module -Force

$out = if ($OutputName) {
    if ([IO.Path]::IsPathRooted($OutputName)) { $OutputName }
    else { Join-Path $dir $OutputName }
} elseif ($TestBuild) {
    Join-Path $dir 'ZapretControl-test.exe'
} else {
    Join-Path $dir 'ZapretControl.exe'
}

$params = @{
    InputFile   = $script
    OutputFile  = $out
    noConsole   = $true
    title       = 'ZAPRET CONTROL'
    description = 'LAN proxy + zapret DPI bypass control panel'
    product     = 'ZAPRET CONTROL'
    company     = 'zapret-discord-youtube'
    version     = '1.12.2.0'
}
if (Test-Path -LiteralPath $icon) { $params['iconFile'] = $icon }
if (-not $TestBuild) { $params['requireAdmin'] = $true }

Invoke-ps2exe @params

Write-Output ''
Write-Output "[OK] Built: $out"
