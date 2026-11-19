param(
    [switch]$SkipExeBuild,
    [switch]$TestBuild,
    [string]$OutputName = '',
    [switch]$KeepStaging
)

$ErrorActionPreference = 'Stop'
# Build a single-file installer (ZapretControlSetup.exe) with the whole
# portable app embedded as a compressed base64 payload.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File build-installer.ps1
#   powershell -ExecutionPolicy Bypass -File build-installer.ps1 -SkipExeBuild
#   powershell -ExecutionPolicy Bypass -File build-installer.ps1 -TestBuild   (no UAC)

$dir = $PSScriptRoot
$root = Split-Path -Parent $dir
$version = '1.12.12'
$module = Join-Path $dir 'tools\ps2exe\ps2exe.psd1'
$templatePath = Join-Path $dir 'installer\setup-template.ps1'
$icon = Join-Path $dir 'zapret.ico'

if (-not (Test-Path -LiteralPath $module)) { throw "ps2exe module not found: $module" }
if (-not (Test-Path -LiteralPath $templatePath)) { throw "template not found: $templatePath" }
if (-not (Test-Path -LiteralPath (Join-Path $dir 'uninstall.ps1'))) {
    throw 'uninstall.ps1 not found in proxy folder'
}

if (-not $SkipExeBuild) {
    Write-Output 'Building ZapretControl.exe...'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $dir 'build-exe.ps1')
    if ($LASTEXITCODE -ne 0) { throw "build-exe.ps1 failed with exit code $LASTEXITCODE" }
}
if (-not (Test-Path -LiteralPath (Join-Path $dir 'ZapretControl.exe'))) {
    throw 'ZapretControl.exe not found - run build-exe.ps1 first'
}

function Test-Excluded([string]$name, [string[]]$patterns) {
    foreach ($pattern in $patterns) {
        if ($name -like $pattern) { return $true }
    }
    return $false
}

function Copy-Filtered([string]$source, [string]$target, [string[]]$patterns) {
    if (-not (Test-Path -LiteralPath $source)) { return }
    if (-not (Test-Path -LiteralPath $target)) {
        New-Item -ItemType Directory -Path $target -Force | Out-Null
    }
    foreach ($item in Get-ChildItem -LiteralPath $source -Force) {
        if (Test-Excluded $item.Name $patterns) { continue }
        if ($item.PSIsContainer) {
            Copy-Filtered $item.FullName (Join-Path $target $item.Name) $patterns
        } else {
            Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $target $item.Name) -Force
        }
    }
}

$stage = Join-Path $env:TEMP ('zapret-installer-stage-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage -Force | Out-Null
$zip = Join-Path $env:TEMP ('zapret-payload-' + [Guid]::NewGuid().ToString('N') + '.zip')
$generated = Join-Path $env:TEMP ('zapret-setup-' + [Guid]::NewGuid().ToString('N') + '.ps1')

try {
    Write-Output 'Staging files...'
    # bin, lists and utils are shipped as-is (user data is preserved by the installer).
    Copy-Filtered (Join-Path $root 'bin') (Join-Path $stage 'bin') @('__pycache__', '*.pyc')
    Copy-Filtered (Join-Path $root 'lists') (Join-Path $stage 'lists') @(
        '*.tmp', '*.test-backup.txt')
    Copy-Filtered (Join-Path $root 'utils') (Join-Path $stage 'utils') @(
        '*.enabled', 'test results', '__pycache__', '*.pyc')

    foreach ($bat in Get-ChildItem -LiteralPath $root -Filter 'general*.bat' -File) {
        Copy-Item -LiteralPath $bat.FullName -Destination (Join-Path $stage $bat.Name) -Force
    }
    $service = Join-Path $root 'service.bat'
    if (Test-Path -LiteralPath $service) {
        Copy-Item -LiteralPath $service -Destination (Join-Path $stage 'service.bat') -Force
    }

    # proxy folder: scripts + built EXE, without logs and local state.
    Copy-Filtered $dir (Join-Path $stage 'proxy') @(
        '*.log', '*.pid', '*.disabled', '*.autostart', '*.pyc', '__pycache__',
        'connection-test.txt', 'ui-test.txt', 'self-test.txt', 'gui-startup-err.txt',
        'gui-settings.json', 'install-info.json', 'ZapretControl-test.exe',
        'ZapretControlSetup.exe', 'ZapretControlSetup-test.exe', 'ZAPRET CONTROL.lnk',
        'build-installer.ps1', 'installer', 'tools', 'zapret-strategy.txt'
    )

    # macOS-клиент поставляется отдельным релизом (macos-v*); Windows-установщик содержит только Windows-часть.
    $rootReadme = Join-Path $root 'README.md'
    if (Test-Path -LiteralPath $rootReadme) {
        Copy-Item -LiteralPath $rootReadme -Destination (Join-Path $stage 'README.md') -Force
    }

    # The uninstaller must always be present in the payload.
    Copy-Item -LiteralPath (Join-Path $dir 'uninstall.ps1') `
        -Destination (Join-Path $stage 'proxy\uninstall.ps1') -Force

    $files = @(Get-ChildItem -LiteralPath $stage -Recurse -File)
    $fileCount = $files.Count
    $sizeMb = [Math]::Round((($files | Measure-Object Length -Sum).Sum) / 1MB, 1)
    $strategyCount = @(Get-ChildItem -LiteralPath $stage -Filter 'general*.bat' -File).Count
    Write-Output "Payload: $fileCount files, $sizeMb MB, $strategyCount strategies"

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory(
        $stage, $zip, [IO.Compression.CompressionLevel]::Optimal, $false)
    $zipSize = [Math]::Round((Get-Item -LiteralPath $zip).Length / 1MB, 2)
    Write-Output "Compressed payload: $zipSize MB"

    $base64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($zip))
    $template = [IO.File]::ReadAllText($templatePath, [Text.Encoding]::UTF8)
    $scriptText = $template.Replace('__APP_VERSION__', $version).
        Replace('__FILES__', [string]$fileCount).
        Replace('__SIZE_MB__', [string]$sizeMb).
        Replace('__STRATEGIES__', [string]$strategyCount).
        Replace('__PAYLOAD_BASE64__', $base64)
    [IO.File]::WriteAllText($generated, $scriptText,
        (New-Object System.Text.UTF8Encoding($true)))

    Import-Module $module -Force
    $out = if ($OutputName) {
        if ([IO.Path]::IsPathRooted($OutputName)) { $OutputName }
        else { Join-Path $dir $OutputName }
    } elseif ($TestBuild) {
        Join-Path $dir 'ZapretControlSetup-test.exe'
    } else {
        Join-Path $dir 'ZapretControlSetup.exe'
    }

    $params = @{
        InputFile   = $generated
        OutputFile  = $out
        noConsole   = $true
        title       = 'ZAPRET CONTROL Setup'
        description = 'Установщик ZAPRET CONTROL: LAN-прокси и обход DPI'
        product     = 'ZAPRET CONTROL'
        company     = 'zapret-discord-youtube'
        version     = "$version.0"
    }
    if (Test-Path -LiteralPath $icon) { $params['iconFile'] = $icon }
    if (-not $TestBuild) { $params['requireAdmin'] = $true }

    Write-Output 'Compiling installer...'
    Invoke-ps2exe @params
    Write-Output ''
    Write-Output "[OK] Built: $out"
    Write-Output ("     Size: {0} MB" -f [Math]::Round((Get-Item -LiteralPath $out).Length / 1MB, 2))
} finally {
    if (-not $KeepStaging) {
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $generated -Force -ErrorAction SilentlyContinue
    } else {
        Write-Output "Staging kept: $stage"
        Write-Output "Zip kept:     $zip"
        Write-Output "Script kept:  $generated"
    }
}
