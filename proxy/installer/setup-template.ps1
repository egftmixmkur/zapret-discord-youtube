param(
    [string]$InstallDir = '',
    [switch]$Silent,
    [switch]$NoDesktop,
    [switch]$NoStartMenu,
    [switch]$NoAutostart,
    [switch]$NoLaunch,
    [switch]$NoRegistry,
    [switch]$NoUninstaller,
    [switch]$NoElevate,
    [switch]$StartNow
)

$ErrorActionPreference = 'Stop'
$AppName = 'ZAPRET CONTROL'
$AppVersion = '__APP_VERSION__'
$PayloadFiles = __FILES__
$PayloadSizeMb = __SIZE_MB__
$PayloadStrategies = __STRATEGIES__
$PayloadBase64 = '__PAYLOAD_BASE64__'
$LogFile = Join-Path $env:TEMP 'zapret-install.log'
$script:Installing = $false
$script:WantDesktop = -not $NoDesktop
$script:WantStartMenu = -not $NoStartMenu
$script:WantAutostart = -not $NoAutostart
$script:WantStartAll = [bool]$StartNow

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Write-InstallLog([string]$text) {
    try {
        $line = '{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $text
        Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    } catch { }
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = (New-Object Security.Principal.WindowsPrincipal $identity).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin -and -not $Silent -and -not $NoElevate) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($InstallDir) { $argList += @('-InstallDir', "`"$InstallDir`"") }
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList
    } catch { }
    exit
}

function Get-DefaultInstallDir {
    try {
        $key = Get-ItemProperty `
            'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\ZapretControl' `
            -ErrorAction Stop
        if ($key.InstallLocation -and (Test-Path -LiteralPath $key.InstallLocation)) {
            return [string]$key.InstallLocation
        }
    } catch { }
    return (Join-Path $env:ProgramFiles 'ZapretControl')
}

function Test-InstallPath([string]$path) {
    if (-not $path) { return 'Укажите папку установки.' }
    try { $full = [IO.Path]::GetFullPath($path) } catch { return 'Некорректный путь.' }
    if ($full -match '^[A-Za-z]:\\?$') { return 'Нельзя устанавливать в корень диска.' }
    $win = [IO.Path]::GetFullPath($env:windir).TrimEnd('\').ToLower()
    if ($full.TrimEnd('\').ToLower().StartsWith($win)) {
        return 'Нельзя устанавливать в папку Windows.'
    }
    if ($full.TrimEnd('\').ToLower() -eq $env:USERPROFILE.TrimEnd('\').ToLower()) {
        return 'Выберите отдельную папку, а не профиль пользователя.'
    }
    return ''
}

function Find-Python {
    foreach ($name in 'pythonw.exe', 'python.exe') {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
    }
    foreach ($ver in '313', '312', '311', '310') {
        $candidate = Join-Path $env:LocalAppData "Programs\Python\Python$ver\pythonw.exe"
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return $null
}

function Stop-RunningComponents {
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
}

function Expand-Payload([string]$stage) {
    $zip = Join-Path $env:TEMP ('zapret-payload-{0}.zip' -f [Guid]::NewGuid().ToString('N'))
    try {
        [IO.File]::WriteAllBytes($zip, [Convert]::FromBase64String($PayloadBase64))
        [IO.Compression.ZipFile]::ExtractToDirectory($zip, $stage)
    } finally {
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
    }
}

function Copy-Tree([string]$source, [string]$target) {
    $prefix = $source.TrimEnd('\').Length + 1
    Get-ChildItem -LiteralPath $source -Recurse -File -Force | ForEach-Object {
        $rel = $_.FullName.Substring($prefix)
        $dst = Join-Path $target $rel
        $parent = Split-Path -Parent $dst
        if (-not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        Copy-Item -LiteralPath $_.FullName -Destination $dst -Force
    }
}

function New-AppShortcut([string]$path, [string]$targetPath, [string]$workDir,
    [string]$icon, [string]$description, [string]$arguments = '') {
    $shell = New-Object -ComObject WScript.Shell
    $link = $shell.CreateShortcut($path)
    $link.TargetPath = $targetPath
    $link.WorkingDirectory = $workDir
    if ($icon) { $link.IconLocation = $icon }
    if ($description) { $link.Description = $description }
    if ($arguments) { $link.Arguments = $arguments }
    $link.WindowStyle = 1
    $link.Save()
}

function Get-DesktopPath {
    $path = [Environment]::GetFolderPath('Desktop')
    if ($path -and (Test-Path -LiteralPath $path)) { return $path }
    return (Join-Path $env:USERPROFILE 'Desktop')
}

function Invoke-Install([string]$target, [scriptblock]$ui) {
    $script:Installing = $true
    $stage = Join-Path $env:TEMP ('zapret-stage-{0}' -f [Guid]::NewGuid().ToString('N'))
    $keep = Join-Path $env:TEMP ('zapret-keep-{0}' -f [Guid]::NewGuid().ToString('N'))
    $keepList = @(
        'proxy\zapret-strategy.txt',
        'proxy\gui-settings.json',
        'proxy\proxy.disabled',
        'proxy\zapret.disabled',
        'proxy\zapret.autostart',
        'proxy\proxy.pid',
        'lists\ipset-all.txt',
        'lists\ipset-all.txt.backup',
        'lists\ipset-exclude-user.txt',
        'utils\game_filter.enabled',
        'utils\check_updates.enabled'
    )
    try {
        & $ui 5 'Остановка запущенных компонентов…'
        Write-InstallLog 'stopping running components'
        Stop-RunningComponents

        & $ui 15 'Распаковка файлов…'
        Write-InstallLog "extracting payload to $stage"
        Expand-Payload $stage

        # Сохраняем пользовательские настройки, чтобы обновление их не затёрло.
        foreach ($rel in $keepList) {
            $src = Join-Path $target $rel
            if (Test-Path -LiteralPath $src) {
                $dst = Join-Path $keep $rel
                $parent = Split-Path -Parent $dst
                if (-not (Test-Path -LiteralPath $parent)) {
                    New-Item -ItemType Directory -Path $parent -Force | Out-Null
                }
                Copy-Item -LiteralPath $src -Destination $dst -Force -Recurse
            }
        }
        if (Test-Path -LiteralPath (Join-Path $target 'utils\test results')) {
            $keepResults = Join-Path $keep 'utils\test results'
            $keepResultsParent = Split-Path -Parent $keepResults
            if (-not (Test-Path -LiteralPath $keepResultsParent)) {
                New-Item -ItemType Directory -Path $keepResultsParent -Force | Out-Null
            }
            Copy-Item -LiteralPath (Join-Path $target 'utils\test results') `
                -Destination $keepResults -Recurse -Force
        }

        & $ui 35 'Копирование файлов…'
        Write-InstallLog "copying files to $target"
        if (-not (Test-Path -LiteralPath $target)) {
            New-Item -ItemType Directory -Path $target -Force | Out-Null
        }
        Copy-Tree $stage $target
        if (Test-Path -LiteralPath $keep) {
            Copy-Tree $keep $target
        }

        # Проверяем, что на месте все ключевые компоненты zapret и GUI.
        & $ui 60 'Проверка компонентов…'
        $required = @(
            'bin\winws.exe',
            'bin\WinDivert64.sys',
            'bin\WinDivert.dll',
            'bin\cygwin1.dll',
            'service.bat',
            'proxy\ZapretControl.exe',
            'proxy\zapret-gui.ps1',
            'proxy\zapret-proxy.py'
        )
        foreach ($rel in $required) {
            if (-not (Test-Path -LiteralPath (Join-Path $target $rel))) {
                throw "В установщике нет обязательного файла: $rel"
            }
        }
        $strategies = @(Get-ChildItem -LiteralPath $target -Filter 'general*.bat' -File)
        if ($strategies.Count -eq 0) {
            throw 'В установщике нет файлов стратегий general*.bat'
        }
        Write-InstallLog "components ok, strategies=$($strategies.Count)"

        $appExe = Join-Path $target 'proxy\ZapretControl.exe'
        $appDir = Join-Path $target 'proxy'
        $icon = Join-Path $appDir 'zapret.ico'

        & $ui 70 'Создание ярлыков…'
        if ($script:WantDesktop) {
            $desktop = Get-DesktopPath
            New-AppShortcut -path (Join-Path $desktop 'ZAPRET CONTROL.lnk') `
                -targetPath $appExe -workDir $appDir -icon $icon `
                -description 'ZAPRET CONTROL — LAN-прокси и обход DPI'
            Write-InstallLog 'desktop shortcut created'
        }
        if ($script:WantStartMenu) {
            $menu = Join-Path $env:ProgramData `
                'Microsoft\Windows\Start Menu\Programs\ZAPRET CONTROL'
            if (-not (Test-Path -LiteralPath $menu)) {
                New-Item -ItemType Directory -Path $menu -Force | Out-Null
            }
            New-AppShortcut -path (Join-Path $menu 'ZAPRET CONTROL.lnk') `
                -targetPath $appExe -workDir $appDir -icon $icon `
                -description 'ZAPRET CONTROL — LAN-прокси и обход DPI'
            $uninstaller = Join-Path $appDir 'uninstall.ps1'
            if (Test-Path -LiteralPath $uninstaller) {
                $psArgs = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' +
                    $uninstaller + '"'
                New-AppShortcut -path (Join-Path $menu 'Удалить ZAPRET CONTROL.lnk') `
                    -targetPath 'powershell.exe' -workDir $appDir -icon $icon `
                    -description 'Удаление ZAPRET CONTROL' -arguments $psArgs
            }
            Write-InstallLog 'start menu shortcuts created'
        }

        & $ui 80 'Регистрация в системе…'
        if (-not $NoRegistry -and $isAdmin) {
            try {
                $key = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\ZapretControl'
                if (-not (Test-Path -LiteralPath $key)) {
                    New-Item -Path $key -Force | Out-Null
                }
                $sizeKb = 0
                try {
                    $sizeKb = [int]((Get-ChildItem -LiteralPath $target -Recurse -File |
                        Measure-Object Length -Sum).Sum / 1KB)
                } catch { }
                $uninstallString = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' +
                    (Join-Path $appDir 'uninstall.ps1') + '"'
                $props = @{
                    DisplayName          = $AppName
                    DisplayVersion       = $AppVersion
                    Publisher            = 'zapret-discord-youtube'
                    DisplayIcon          = "$appExe,0"
                    InstallLocation      = $target
                    InstallDate          = (Get-Date).ToString('yyyyMMdd')
                    UninstallString      = $uninstallString
                    QuietUninstallString = $uninstallString + ' -Quiet'
                    EstimatedSize        = $sizeKb
                    NoModify             = 1
                    NoRepair             = 1
                }
                foreach ($name in $props.Keys) {
                    Set-ItemProperty -Path $key -Name $name -Value $props[$name]
                }
                Write-InstallLog 'registry entry written'
            } catch {
                Write-InstallLog "registry failed: $($_.Exception.Message)"
            }
        }

        & $ui 90 'Настройка автозапуска…'
        if ($script:WantAutostart) {
            $tasksScript = Join-Path $appDir 'install-tasks.ps1'
            if ((Test-Path -LiteralPath $tasksScript) -and $isAdmin) {
                try {
                    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass `
                        -File $tasksScript 2>&1
                    Write-InstallLog ('install-tasks: ' + ($output -join ' | '))
                } catch {
                    Write-InstallLog "install-tasks failed: $($_.Exception.Message)"
                }
            } else {
                Write-InstallLog 'install-tasks skipped (no admin or script missing)'
            }
        }

        if ($script:WantStartAll) {
            & $ui 95 'Запуск прокси и zapret…'
            $startBat = Join-Path $appDir 'start-all.bat'
            if ((Test-Path -LiteralPath $startBat) -and $isAdmin -and (Find-Python)) {
                try {
                    $empty = Join-Path $env:TEMP 'zapret-empty-stdin.txt'
                    $outLog = Join-Path $env:TEMP 'zapret-startall.out.txt'
                    $errLog = Join-Path $env:TEMP 'zapret-startall.err.txt'
                    Set-Content -LiteralPath $empty -Value '' -Encoding ASCII
                    $proc = Start-Process -FilePath 'cmd.exe' `
                        -ArgumentList @('/c', "`"$startBat`"") `
                        -WorkingDirectory $appDir -WindowStyle Hidden -PassThru -Wait `
                        -RedirectStandardInput $empty `
                        -RedirectStandardOutput $outLog `
                        -RedirectStandardError $errLog
                    Write-InstallLog "start-all exit=$($proc.ExitCode)"
                    Remove-Item -LiteralPath $empty -Force -ErrorAction SilentlyContinue
                } catch {
                    Write-InstallLog "start-all failed: $($_.Exception.Message)"
                }
            } else {
                Write-InstallLog 'start-all skipped (no admin, no python or missing bat)'
            }
        }

        if (-not $NoUninstaller) {
            $installedUninstaller = Join-Path $appDir 'uninstall.ps1'
            if (-not (Test-Path -LiteralPath $installedUninstaller)) {
                Write-InstallLog 'warning: uninstall.ps1 missing in payload'
            }
        }

        try {
            $info = [ordered]@{
                Version   = $AppVersion
                InstallDir = $target
                Installed = (Get-Date).ToString('s')
                Desktop   = $script:WantDesktop
                StartMenu = $script:WantStartMenu
                Autostart = $script:WantAutostart
                Python    = (Find-Python)
            }
            ($info | ConvertTo-Json) | Set-Content -LiteralPath `
                (Join-Path $appDir 'install-info.json') -Encoding UTF8
        } catch { }

        & $ui 100 'Установка завершена.'
        Write-InstallLog 'install completed'
    } finally {
        $script:Installing = $false
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $keep -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------- silent mode
if ($Silent) {
    if (-not $InstallDir) { $InstallDir = Get-DefaultInstallDir }
    $problem = Test-InstallPath $InstallDir
    if ($problem) {
        Write-InstallLog "ERROR: $problem"
        exit 2
    }
    $InstallDir = [IO.Path]::GetFullPath($InstallDir)
    try {
        Invoke-Install $InstallDir { param($percent, $text) }
        Write-InstallLog "silent install ok: $InstallDir"
        exit 0
    } catch {
        Write-InstallLog "silent install failed: $($_.Exception.Message)"
        exit 1
    }
}

# ---------------------------------------------------------------------- UI
[Windows.Forms.Application]::EnableVisualStyles()
[Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

if (-not $InstallDir) { $InstallDir = Get-DefaultInstallDir }
$InstallDir = [IO.Path]::GetFullPath($InstallDir)

$accent = [Drawing.Color]::FromArgb(88, 101, 242)
$bg = [Drawing.Color]::FromArgb(247, 248, 251)
$muted = [Drawing.Color]::FromArgb(108, 117, 140)
$textColor = [Drawing.Color]::FromArgb(28, 32, 44)

$form = New-Object System.Windows.Forms.Form
$form.Text = "Установка $AppName"
$form.Size = New-Object System.Drawing.Size(680, 560)
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
$form.MaximizeBox = $false
$form.MinimizeBox = $false
$form.BackColor = $bg
$form.ForeColor = $textColor
$form.Font = New-Object System.Drawing.Font -ArgumentList @('Segoe UI', 9.5)

$header = New-Object System.Windows.Forms.Panel
$header.Dock = [System.Windows.Forms.DockStyle]::Top
$header.Height = 78
$header.BackColor = $accent
$form.Controls.Add($header)

$title = New-Object System.Windows.Forms.Label
$title.Text = $AppName
$title.Font = New-Object System.Drawing.Font -ArgumentList @('Segoe UI', 17, [System.Drawing.FontStyle]::Bold)
$title.ForeColor = [Drawing.Color]::White
$title.AutoSize = $true
$title.Location = New-Object System.Drawing.Point -ArgumentList @(24, 12)
$header.Controls.Add($title)

$subtitle = New-Object System.Windows.Forms.Label
$subtitle.Text = 'Установка: LAN-прокси, обход DPI и панель управления'
$subtitle.Font = New-Object System.Drawing.Font -ArgumentList @('Segoe UI', 9.5)
$subtitle.ForeColor = [Drawing.Color]::FromArgb(225, 228, 255)
$subtitle.AutoSize = $true
$subtitle.Location = New-Object System.Drawing.Point -ArgumentList @(26, 46)
$header.Controls.Add($subtitle)

$versionLabel = New-Object System.Windows.Forms.Label
$versionLabel.Text = "v$AppVersion"
$versionLabel.Font = New-Object System.Drawing.Font -ArgumentList @('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$versionLabel.ForeColor = [Drawing.Color]::FromArgb(225, 228, 255)
$versionLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
$versionLabel.Size = New-Object System.Drawing.Size -ArgumentList @(90, 24)
$versionLabel.Location = New-Object System.Drawing.Point -ArgumentList @(554, 16)
$header.Controls.Add($versionLabel)

$pathLabel = New-Object System.Windows.Forms.Label
$pathLabel.Text = 'Папка установки:'
$pathLabel.AutoSize = $true
$pathLabel.Location = New-Object System.Drawing.Point -ArgumentList @(24, 96)
$form.Controls.Add($pathLabel)

$pathBox = New-Object System.Windows.Forms.TextBox
$pathBox.Text = $InstallDir
$pathBox.Location = New-Object System.Drawing.Point -ArgumentList @(24, 118)
$pathBox.Size = New-Object System.Drawing.Size -ArgumentList @(498, 26)
$pathBox.Font = New-Object System.Drawing.Font -ArgumentList @('Segoe UI', 9.5)
$form.Controls.Add($pathBox)

$browseButton = New-Object System.Windows.Forms.Button
$browseButton.Text = 'Обзор…'
$browseButton.Location = New-Object System.Drawing.Point -ArgumentList @(532, 116)
$browseButton.Size = New-Object System.Drawing.Size -ArgumentList @(108, 30)
$browseButton.FlatStyle = [System.Windows.Forms.FlatStyle]::System
$browseButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = 'Выберите папку установки'
    $dialog.SelectedPath = $pathBox.Text
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $pathBox.Text = $dialog.SelectedPath
    }
})
$form.Controls.Add($browseButton)

$group = New-Object System.Windows.Forms.GroupBox
$group.Text = 'Ярлыки и автозапуск'
$group.Location = New-Object System.Drawing.Point -ArgumentList @(24, 160)
$group.Size = New-Object System.Drawing.Size -ArgumentList @(616, 172)
$form.Controls.Add($group)

$chkDesktop = New-Object System.Windows.Forms.CheckBox
$chkDesktop.Text = 'Ярлык на рабочем столе'
$chkDesktop.Checked = $true
$chkDesktop.AutoSize = $true
$chkDesktop.Location = New-Object System.Drawing.Point -ArgumentList @(18, 26)
$group.Controls.Add($chkDesktop)

$chkStart = New-Object System.Windows.Forms.CheckBox
$chkStart.Text = 'Ярлык в меню «Пуск» (с кнопкой удаления)'
$chkStart.Checked = $true
$chkStart.AutoSize = $true
$chkStart.Location = New-Object System.Drawing.Point -ArgumentList @(18, 54)
$group.Controls.Add($chkStart)

$chkTasks = New-Object System.Windows.Forms.CheckBox
$chkTasks.Text = 'Автозапуск при входе в Windows (задачи планировщика)'
$chkTasks.Checked = $true
$chkTasks.AutoSize = $true
$chkTasks.Location = New-Object System.Drawing.Point -ArgumentList @(18, 82)
$group.Controls.Add($chkTasks)

$chkLaunch = New-Object System.Windows.Forms.CheckBox
$chkLaunch.Text = 'Запустить ZAPRET CONTROL после установки'
$chkLaunch.Checked = $true
$chkLaunch.AutoSize = $true
$chkLaunch.Location = New-Object System.Drawing.Point -ArgumentList @(18, 110)
$group.Controls.Add($chkLaunch)

$chkStartAll = New-Object System.Windows.Forms.CheckBox
$chkStartAll.Text = 'Запустить прокси и zapret сразу после установки'
$chkStartAll.Checked = $true
$chkStartAll.AutoSize = $true
$chkStartAll.Location = New-Object System.Drawing.Point -ArgumentList @(18, 138)
$group.Controls.Add($chkStartAll)

$python = Find-Python
$pythonText = if ($python) { "Python 3: найден ($python)" } else { 'Python 3: НЕ найден — прокси не запустится' }
$infoLabel = New-Object System.Windows.Forms.Label
$infoLabel.Text = "Файлов: $PayloadFiles ($PayloadSizeMb МБ): zapret (winws.exe, WinDivert," +
    " $PayloadStrategies стратегии), LAN-прокси и панель управления.`r`n" + $pythonText
$infoLabel.ForeColor = if ($python) { $muted } else { [Drawing.Color]::FromArgb(190, 60, 60) }
$infoLabel.Location = New-Object System.Drawing.Point -ArgumentList @(24, 338)
$infoLabel.Size = New-Object System.Drawing.Size -ArgumentList @(616, 54)
$form.Controls.Add($infoLabel)

$progress = New-Object System.Windows.Forms.ProgressBar
$progress.Location = New-Object System.Drawing.Point -ArgumentList @(24, 398)
$progress.Size = New-Object System.Drawing.Size -ArgumentList @(616, 10)
$progress.Minimum = 0
$progress.Maximum = 100
$form.Controls.Add($progress)

$status = New-Object System.Windows.Forms.Label
$status.Text = 'Готов к установке.'
$status.ForeColor = $muted
$status.Location = New-Object System.Drawing.Point -ArgumentList @(24, 414)
$status.Size = New-Object System.Drawing.Size -ArgumentList @(616, 22)
$form.Controls.Add($status)

$installButton = New-Object System.Windows.Forms.Button
$installButton.Text = 'Установить'
$installButton.Location = New-Object System.Drawing.Point -ArgumentList @(430, 448)
$installButton.Size = New-Object System.Drawing.Size -ArgumentList @(120, 38)
$installButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$installButton.FlatAppearance.BorderSize = 0
$installButton.BackColor = $accent
$installButton.ForeColor = [Drawing.Color]::White
$installButton.Font = New-Object System.Drawing.Font -ArgumentList @('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$installButton.Cursor = [System.Windows.Forms.Cursors]::Hand
$installButton.UseVisualStyleBackColor = $false
$form.Controls.Add($installButton)

$cancelButton = New-Object System.Windows.Forms.Button
$cancelButton.Text = 'Отмена'
$cancelButton.Location = New-Object System.Drawing.Point -ArgumentList @(560, 448)
$cancelButton.Size = New-Object System.Drawing.Size -ArgumentList @(80, 38)
$cancelButton.FlatStyle = [System.Windows.Forms.FlatStyle]::System
$cancelButton.Add_Click({ $form.Close() })
$form.Controls.Add($cancelButton)

$note = New-Object System.Windows.Forms.Label
$note.Text = 'Нужны права администратора: задачи планировщика, брандмауэр и общие папки.'
$note.ForeColor = $muted
$note.Font = New-Object System.Drawing.Font -ArgumentList @('Segoe UI', 8.5)
$note.Location = New-Object System.Drawing.Point -ArgumentList @(24, 454)
$note.Size = New-Object System.Drawing.Size -ArgumentList @(392, 30)
$form.Controls.Add($note)

$form.AcceptButton = $installButton
$form.CancelButton = $cancelButton

$updateUi = {
    param([int]$percent, [string]$text)
    $progress.Value = [Math]::Min(100, [Math]::Max(0, $percent))
    $status.Text = $text
    [Windows.Forms.Application]::DoEvents()
}

$installButton.Add_Click({
    $problem = Test-InstallPath $pathBox.Text
    if ($problem) {
        [Windows.Forms.MessageBox]::Show($problem, $AppName, 'OK', 'Warning') | Out-Null
        return
    }
    $target = [IO.Path]::GetFullPath($pathBox.Text)
    $script:WantDesktop = [bool]$chkDesktop.Checked
    $script:WantStartMenu = [bool]$chkStart.Checked
    $script:WantAutostart = [bool]$chkTasks.Checked
    $script:WantStartAll = [bool]$chkStartAll.Checked
    $installButton.Enabled = $false
    $cancelButton.Enabled = $false
    $browseButton.Enabled = $false
    $pathBox.Enabled = $false
    $group.Enabled = $false
    try {
        Invoke-Install $target $updateUi
        $status.Text = "Установлено в $target"
        [Windows.Forms.MessageBox]::Show(
            "$AppName установлен.`r`n`r`nПапка: $target" +
            $(if ($chkDesktop.Checked) { "`r`nЯрлык: рабочий стол" } else { '' }) +
            $(if ($chkTasks.Checked) { "`r`nАвтозапуск: задачи планировщика" } else { '' }) +
            $(if ($chkStartAll.Checked -and $python) { "`r`nПрокси и zapret запущены" } else { '' }),
            $AppName, 'OK', 'Information') | Out-Null
        if ($chkLaunch.Checked) {
            $exe = Join-Path $target 'proxy\ZapretControl.exe'
            if (Test-Path -LiteralPath $exe) {
                Start-Process -FilePath $exe -WorkingDirectory (Join-Path $target 'proxy')
            }
        }
        $form.Close()
    } catch {
        Write-InstallLog "install failed: $($_.Exception.Message)"
        $status.Text = 'Ошибка установки.'
        [Windows.Forms.MessageBox]::Show(
            "Не удалось установить:`r`n$($_.Exception.Message)`r`n`r`nЖурнал: $LogFile",
            $AppName, 'OK', 'Error') | Out-Null
        $installButton.Enabled = $true
        $cancelButton.Enabled = $true
        $browseButton.Enabled = $true
        $pathBox.Enabled = $true
        $group.Enabled = $true
    }
})

$form.Add_FormClosing({
    param($sender, $e)
    if ($script:Installing) { $e.Cancel = $true }
})

[void]$form.ShowDialog()
