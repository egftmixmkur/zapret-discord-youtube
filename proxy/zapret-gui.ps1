param(
    [switch]$SelfTest,
    [switch]$UiTest
)

# ZAPRET CONTROL - графический пульт для LAN-прокси и тестов zapret.
# Запускается как ZapretControl.exe (собран из этого скрипта) или напрямую
# через powershell -ExecutionPolicy Bypass -File zapret-gui.ps1.
# Только Windows PowerShell 5.1+, WinForms, без внешних зависимостей.

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# В скомпилированном EXE $PSScriptRoot пустой - берём папку самого EXE.
$baseDir = $PSScriptRoot
if (-not $baseDir) {
    try {
        $baseDir = Split-Path -Parent ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
    } catch {
        $baseDir = (Get-Location).Path
    }
}
if (-not $baseDir) { $baseDir = (Get-Location).Path }
$script:ProxyDir   = $baseDir
$script:RootDir    = Split-Path -Parent $baseDir
$script:UtilsDir   = Join-Path $script:RootDir 'utils'
$script:ResultsDir = Join-Path $script:UtilsDir 'test results'
$script:ListsDir   = Join-Path $script:RootDir 'lists'
$script:BindDir    = Join-Path $script:RootDir 'bin'
$script:MacDir     = Join-Path $script:RootDir 'macos'
$script:MacClientScript = Join-Path $script:MacDir 'zapret-proxy.command'
$script:AppVersion = '1.12.12'
$script:UpdateRepo = 'egftmixmkur/zapret-discord-youtube'
$script:StrategyFile = Join-Path $script:ProxyDir 'zapret-strategy.txt'
$script:TestScript = Join-Path $script:UtilsDir 'test zapret.ps1'
$script:CurrentLog = ''
$script:CachedLanIp = ''
$script:CachedLanIpAt = [DateTime]::MinValue
$script:CachedTasks = $null
$script:CachedTasksAt = [DateTime]::MinValue
$script:CachedHealth = $null
$script:CachedHealthAt = [DateTime]::MinValue
$script:HealthFetched = $false
$script:ConnScript = Join-Path $script:ProxyDir 'test-connection.ps1'
$script:ConnOut = Join-Path $script:ProxyDir 'connection-test.txt'
$script:ConnRunning = $false
$script:ConnProc = $null
$script:ConnStarted = [DateTime]::MinValue
$script:LastConnSummary = ''
$script:TestWasRunning = $false
$script:LastResultStamp = ''

$script:TestChartData = $null

$script:TestChart = $null

$script:OverviewChart = $null

function Test-Admin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $p = New-Object Security.Principal.WindowsPrincipal($id)
        return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}
$script:IsAdmin = Test-Admin

function Color([string]$hex) {
    return [System.Drawing.ColorTranslator]::FromHtml($hex)
}

$script:Theme = @{
    Bg          = '#070b12'
    BgDeep      = '#04070c'
    Surface     = '#101827'
    Surface2    = '#162236'
    Surface3    = '#1d2d46'
    SurfaceHi   = '#243755'
    Border      = '#22324a'
    BorderLight = '#355070'
    Shadow      = '#020407'
    Text        = '#eef5ff'
    Muted       = '#91a4bf'
    Green       = '#34d399'
    GreenDark   = '#15935f'
    Red         = '#fb7185'
    RedDark     = '#b63b52'
    Yellow      = '#fbbf24'
    YellowDark  = '#9a7010'
    Blue        = '#60a5fa'
    BlueDark    = '#2f63b8'
    Cyan        = '#22d3ee'
    CyanDark    = '#0f8799'
    Accent      = '#8b5cf6'
    AccentDark  = '#5b35b8'
    White       = '#ffffff'
    Glow        = '#1d4ed8'
}

# --------------------------------------------------------------------------
#  Данные и действия
# --------------------------------------------------------------------------

function Get-PortOpen([int]$port) {
    foreach ($addr in @('127.0.0.1', '::1')) {
        $client = $null
        try {
            $client = New-Object System.Net.Sockets.TcpClient
            $iar = $client.BeginConnect($addr, $port, $null, $null)
            if ($iar.AsyncWaitHandle.WaitOne(350) -and $client.Connected) {
                $client.EndConnect($iar)
                return $true
            }
        } catch {
        } finally {
            if ($client) { $client.Close() }
        }
    }
    return $false
}

function Get-ProxyHealth([switch]$Force) {
    $now = Get-Date
    if (-not $Force -and $script:HealthFetched -and
        ($now - $script:CachedHealthAt).TotalSeconds -lt 20) {
        return $script:CachedHealth
    }
    $health = $null
    try {
        $health = Invoke-RestMethod -Uri 'http://127.0.0.1:8080/health' `
            -TimeoutSec 1 -UseBasicParsing -ErrorAction Stop
    } catch { }
    $script:CachedHealth = $health
    $script:CachedHealthAt = $now
    $script:HealthFetched = $true
    return $health
}

function Get-LanIp {
    $now = Get-Date
    if ($script:CachedLanIp -and ($now - $script:CachedLanIpAt).TotalSeconds -lt 60) {
        return $script:CachedLanIp
    }
    # Без запуска дочернего PowerShell: это заметно быстрее и не блокирует UI.
    $ip = ''
    try {
        $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop |
            Sort-Object RouteMetric | Select-Object -First 1
        $ip = (Get-NetIPAddress -InterfaceIndex $route.InterfaceIndex `
            -AddressFamily IPv4 -ErrorAction Stop |
            Select-Object -First 1).IPAddress
    } catch { }
    if (-not $ip) {
        try {
            $ip = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
                Where-Object { $_.IPAddress -notlike '169.254*' -and $_.IPAddress -ne '127.0.0.1' } |
                Select-Object -First 1 -ExpandProperty IPAddress
        } catch { }
    }
    if (-not $ip) { $ip = 'не определён' }
    $script:CachedLanIp = $ip
    $script:CachedLanIpAt = $now
    return $ip
}

function Get-StrategyFiles {
    return @(Get-ChildItem -LiteralPath $script:RootDir -Filter 'general*.bat' -File |
        Sort-Object { [Regex]::Replace($_.Name, '(\d+)', { $args[0].Value.PadLeft(8, '0') }) })
}

function Get-SelectedStrategy {
    $default = 'general (MAX).bat'
    if (Test-Path -LiteralPath $script:StrategyFile) {
        $name = (Get-Content -LiteralPath $script:StrategyFile -Raw).Trim()
        if ($name -and (Test-Path -LiteralPath (Join-Path $script:RootDir $name))) {
            return $name
        }
    }
    return $default
}

function Set-SelectedStrategy([string]$name) {
    if (-not $name) { return }
    Set-Content -LiteralPath $script:StrategyFile -Value $name -Encoding UTF8
}

function Get-TaskStatus {
    $now = Get-Date
    if ($script:CachedTasks -and ($now - $script:CachedTasksAt).TotalSeconds -lt 20) {
        return $script:CachedTasks
    }
    $result = @{}
    foreach ($name in @('zapret-proxy', 'zapret-proxy-watchdog', 'zapret-max')) {
        $state = 'missing'
        try {
            $task = Get-ScheduledTask -TaskName $name -ErrorAction Stop
            $state = [string]$task.State
        } catch { }
        $result[$name] = $state
    }
    $script:CachedTasks = $result
    $script:CachedTasksAt = $now
    return $result
}

function Get-IpsetStatus {
    $file = Join-Path $script:ListsDir 'ipset-all.txt'
    if (-not (Test-Path -LiteralPath $file)) { return 'none' }
    $raw = [IO.File]::ReadAllText($file)
    if ([string]::IsNullOrWhiteSpace($raw)) { return 'any' }
    if ($raw -match '203\.0\.113\.113/32') { return 'none' }
    return 'loaded'
}

function Set-IpsetMode([string]$mode) {
    $file = Join-Path $script:ListsDir 'ipset-all.txt'
    $backup = "$file.backup"
    # Резервную копию делаем только с реального списка, иначе режимы
    # any/none затрут её пустышкой и восстановить список будет нечем.
    $snapshot = {
        if ((Get-IpsetStatus) -eq 'loaded') {
            Copy-Item -LiteralPath $file -Destination $backup -Force
        }
    }
    switch ($mode) {
        'any' {
            & $snapshot
            Set-Content -LiteralPath $file -Value '' -Encoding UTF8
        }
        'none' {
            & $snapshot
            Set-Content -LiteralPath $file -Value '203.0.113.113/32' -Encoding ASCII
        }
        'loaded' {
            if (-not (Test-Path -LiteralPath $backup)) {
                throw 'Нет резервной копии списка. Сначала обновите ipset.'
            }
            Copy-Item -LiteralPath $backup -Destination $file -Force
        }
    }
}

function Read-GameFilter {
    $file = Join-Path $script:UtilsDir 'game_filter.enabled'
    $cfg = @{ mode = 'disabled'; tcp = '1024-65535'; udp = '1024-65535' }
    if (Test-Path -LiteralPath $file) {
        foreach ($line in Get-Content -LiteralPath $file) {
            if ($line -match '^\s*([^=]+)=(.*)$') {
                $key = $matches[1].Trim().ToLower()
                $val = $matches[2].Trim()
                if ($key -eq 'mode') { $cfg.mode = $val.ToLower() }
                elseif ($key -eq 'tcp') { $cfg.tcp = $val }
                elseif ($key -eq 'udp') { $cfg.udp = $val }
            }
        }
    }
    return $cfg
}

function Test-PortRange([string]$value) {
    if (-not $value) { return $false }
    foreach ($part in $value -split ',') {
        $part = $part.Trim()
        if ($part -notmatch '^([1-9][0-9]{0,4})(?:-([1-9][0-9]{0,4}))?$') { return $false }
        $a = [int]$matches[1]
        $b = if ($matches[2]) { [int]$matches[2] } else { $a }
        if ($a -gt 65535 -or $b -gt 65535 -or $a -gt $b) { return $false }
    }
    return $true
}

function Write-GameFilter([string]$mode, [string]$tcp, [string]$udp) {
    if (-not (Test-PortRange $tcp)) { throw "Неверный диапазон TCP: $tcp" }
    if (-not (Test-PortRange $udp)) { throw "Неверный диапазон UDP: $udp" }
    $file = Join-Path $script:UtilsDir 'game_filter.enabled'
    @("mode=$mode", "tcp=$tcp", "udp=$udp") |
        Set-Content -LiteralPath $file -Encoding ASCII
}

function Get-LatestResultFile {
    if (-not (Test-Path -LiteralPath $script:ResultsDir)) { return $null }
    return Get-ChildItem -LiteralPath $script:ResultsDir -Filter 'test_results_*.txt' -File |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

function Get-BestFromResultFile($file) {
    if (-not $file) { return '' }
    try {
        $match = Select-String -LiteralPath $file.FullName `
            -Pattern '^\s*Best strategy:\s*(.+?)\s*$' -ErrorAction Stop |
            Select-Object -Last 1
        if ($match) { return $match.Matches[0].Groups[1].Value.Trim() }
    } catch { }
    return ''
}

function Get-TestAnalytics($file) {
    $result = [pscustomobject]@{
        Items = @()
        Best  = ''
        Date  = $null
        Path  = ''
    }
    if (-not $file) { return $result }
    $result.Date = $file.LastWriteTime
    $result.Path = $file.FullName
    $result.Best = Get-BestFromResultFile $file
    $items = New-Object System.Collections.Generic.List[object]
    try {
        foreach ($line in Get-Content -LiteralPath $file.FullName -ErrorAction Stop) {
            if ($line -match '^\s*(.+?)\s*:\s*OK:\s*(\d+)\s*,\s*FAIL:\s*(\d+)\s*,\s*UNSUP:\s*(\d+)\s*,\s*BLOCKED:\s*(\d+)\s*$') {
                $ok = [int]$matches[2]
                $fail = [int]$matches[3]
                $unsup = [int]$matches[4]
                $blocked = [int]$matches[5]
                $total = [int]($ok + $fail + $unsup + $blocked)
                $score = [int]($ok - $fail)
                $items.Add([pscustomobject]@{
                    Name    = ([string]$matches[1]).Trim()
                    OK      = $ok
                    FAIL    = $fail
                    UNSUP   = $unsup
                    BLOCKED = $blocked
                    Total   = $total
                    Score   = $score
                })
            }
        }
    } catch { }
    $sorted = @($items.ToArray() | Sort-Object @{Expression={[int]$_.Score};Descending=$true}, @{Expression={[int]$_.OK};Descending=$true})
    $result.Items = $sorted
    return $result
}

function Update-TestCharts {
    try {
        $file = Get-LatestResultFile
        $stamp = if ($file) { $file.LastWriteTime.ToString('o') + '|' + $file.Length } else { '' }
        $script:LastResultStamp = $stamp
        $script:TestChartData = Get-TestAnalytics $file
        if ($script:TestChart) { $script:TestChart.Invalidate() }
        if ($script:OverviewChart) { $script:OverviewChart.Invalidate() }
    } catch { }
}

function Draw-ResultsChart {
    param($sender, $e, $data, [int]$maxItems = 10, [bool]$compact = $false)
    $g = $null
    $bg = $null; $fontTitle = $null; $fontSmall = $null; $brushText = $null; $brushMuted = $null
    try {
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
        $rect = $sender.ClientRectangle

        $bg = New-Object System.Drawing.SolidBrush((Color $script:Theme.Surface))
        $g.FillRectangle($bg, $rect)

        $isCompact = [bool]$compact
        $maxItemsN = [int]$maxItems
        $padL = [int]($(if ($isCompact) { 10 } else { 14 }))
        $padR = [int]($(if ($isCompact) { 10 } else { 14 }))
        $padT = [int]($(if ($isCompact) { 10 } else { 12 }))
        $padB = [int]($(if ($isCompact) { 10 } else { 28 }))

        $rw = [int]$rect.Width
        $rh = [int]$rect.Height
        $innerW = [int][Math]::Max(40, ($rw - $padL - $padR))
        $innerH = [int][Math]::Max(20, ($rh - $padT - $padB))

        $titleSize = [double]($(if ($isCompact) { 8.5 } else { 9.5 }))
        $smallSize = [double]($(if ($isCompact) { 7.5 } else { 8.25 }))
        $fontTitle = New-Object System.Drawing.Font('Segoe UI Semibold', $titleSize)
        $fontSmall = New-Object System.Drawing.Font('Segoe UI', $smallSize)
        $brushText = New-Object System.Drawing.SolidBrush((Color $script:Theme.Text))
        $brushMuted = New-Object System.Drawing.SolidBrush((Color $script:Theme.Muted))

        $items = @()
        $best = ''
        if ($null -ne $data -and $null -ne $data.Items) {
            $rawItems = @($data.Items)
            if ($maxItemsN -gt 0 -and $rawItems.Count -gt $maxItemsN) {
                $items = @($rawItems | Select-Object -First $maxItemsN)
            } else {
                $items = $rawItems
            }
            $best = [string]$data.Best
        }
        $count = [int]@($items).Count

        if ($count -le 0) {
            $msg = 'График: нет данных — запустите тесты стратегий (вкладка «Тесты»)'
            $sf = New-Object System.Drawing.StringFormat
            try {
                $sf.Alignment = [System.Drawing.StringAlignment]::Center
                $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
                $msgRect = New-Object System.Drawing.RectangleF([single]0, [single]0, [single]$rw, [single]$rh)
                $g.DrawString($msg, $fontTitle, $brushMuted, $msgRect, $sf)
            } finally {
                $sf.Dispose()
            }
        } else {
            $maxTotal = 1
            foreach ($it in $items) {
                $tv = [int]$it.Total
                if ($tv -gt $maxTotal) { $maxTotal = $tv }
            }
            $maxTotal = [int][Math]::Max(1, $maxTotal)

            $title = 'График результатов (топ стратегий)'
            $g.DrawString($title, $fontTitle, $brushText, [single]$padL, [single]($padT - 2))

            $y = [int]($padT + 22)
            $rowMin = [int]($(if ($isCompact) { 16 } else { 20 }))
            $rowMax = [int]($(if ($isCompact) { 22 } else { 28 }))
            $availRowsH = [int][Math]::Max(1, ($innerH - 24))
            $rowFit = [int][Math]::Floor([double]$availRowsH / [double][Math]::Max(1, $count))
            $rowH = [int][Math]::Max($rowMin, [Math]::Min($rowMax, $rowFit))

            $labelRatio = [double]0.34
            $labelW = [int][Math]::Min([int][Math]::Max(120, [int]([double]$innerW * $labelRatio)), 260)
            $barX = [int]($padL + $labelW + 8)
            $rightExtra = [int]($(if ($isCompact) { 0 } else { 80 }))
            $barW = [int][Math]::Max(40, ($rw - $barX - $padR - $rightExtra))
            $barH = [int][Math]::Max(8, ($rowH - 8))

            foreach ($it in $items) {
                $limitY = [int]($rh - $padB + 6)
                if (([int]$y + [int]$rowH - 4) -gt $limitY) { break }

                $name = [string]$it.Name
                $disp = [IO.Path]::GetFileNameWithoutExtension($name)
                if ([string]::IsNullOrEmpty($disp)) { $disp = $name }
                if ($disp.Length -gt 26) { $disp = $disp.Substring(0, 23) + '...' }
                $bestName = [IO.Path]::GetFileNameWithoutExtension($best)
                $isBest = (($best -ne '') -and (($name -eq $best) -or ($disp -eq $bestName)))

                $nameColor = if ($isBest) { (Color $script:Theme.Green) } else { (Color $script:Theme.Text) }
                $nameBrush = New-Object System.Drawing.SolidBrush($nameColor)
                try {
                    $g.DrawString($disp, $fontSmall, $nameBrush, [single]$padL, [single]($y + 1))
                } finally {
                    $nameBrush.Dispose()
                }

                $bx = [int]$barX
                $by = [int]($y + [int][Math]::Floor(([double]$rowH - [double]$barH) / 2.0))
                $track = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(40, 255, 255, 255))
                try {
                    $g.FillRectangle($track, $bx, $by, $barW, $barH)
                } finally {
                    $track.Dispose()
                }

                $segs = @(
                    @{ v = [int]$it.OK;      c = $script:Theme.Green },
                    @{ v = [int]$it.FAIL;    c = $script:Theme.Red },
                    @{ v = [int]$it.BLOCKED; c = $script:Theme.Yellow },
                    @{ v = [int]$it.UNSUP;   c = $script:Theme.Muted }
                )
                $cx = [int]$bx
                foreach ($seg in $segs) {
                    $sv = [int]$seg.v
                    if ($sv -le 0) { continue }
                    $wseg = [int][Math]::Round(([double]$sv * [double]$barW) / [double]$maxTotal)
                    if ($wseg -le 0) { continue }
                    $maxX = [int]($bx + $barW)
                    $endX = [int]($cx + $wseg)
                    if ($endX -gt $maxX) { $wseg = [int]($maxX - $cx) }
                    if ($wseg -le 0) { continue }
                    $b2 = New-Object System.Drawing.SolidBrush((Color $seg.c))
                    try {
                        $g.FillRectangle($b2, $cx, $by, $wseg, $barH)
                    } finally {
                        $b2.Dispose()
                    }
                    $cx = [int]($cx + $wseg)
                }
                $pbr = New-Object System.Drawing.Pen((Color $script:Theme.BorderLight), 1)
                try {
                    $g.DrawRectangle($pbr, $bx, $by, $barW, $barH)
                } finally {
                    $pbr.Dispose()
                }

                $summary = ('OK {0}  FAIL {1}  BLK {2}' -f [int]$it.OK, [int]$it.FAIL, [int]$it.BLOCKED)
                $g.DrawString($summary, $fontSmall, $brushMuted, [single]($barX + $barW + 6), [single]($y + 1))
                $y = [int]($y + $rowH)
            }

            $ly = [int]($rh - $padB + 6)
            $lx = [int]$padL
            $legend = @(
                @{ t = 'OK'; c = $script:Theme.Green },
                @{ t = 'FAIL'; c = $script:Theme.Red },
                @{ t = 'BLOCKED'; c = $script:Theme.Yellow },
                @{ t = 'UNSUP'; c = $script:Theme.Muted }
            )
            foreach ($le in $legend) {
                $lb = New-Object System.Drawing.SolidBrush((Color $le.c))
                try {
                    $g.FillRectangle($lb, $lx, ($ly + 2), 10, 10)
                } finally {
                    $lb.Dispose()
                }
                $g.DrawString([string]$le.t, $fontSmall, $brushMuted, [single]($lx + 14), [single]$ly)
                $lx = [int]($lx + 80)
            }
            if ($null -ne $data.Date) {
                try {
                    $ds = ([datetime]$data.Date).ToString('dd.MM HH:mm')
                    $sz = $g.MeasureString($ds, $fontSmall)
                    $rightX = [single]([double]$rw - [double]$padR - [double]$sz.Width)
                    $g.DrawString($ds, $fontSmall, $brushMuted, $rightX, [single]$ly)
                } catch { }
            }
        }
    } catch {
        try {
            if ($g -and $e -and $sender) {
                $ef = New-Object System.Drawing.Font('Segoe UI', 8.5)
                $eb = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(230, 255, 120, 120))
                try {
                    $msg = 'Ошибка отрисовки графика: ' + $_.Exception.Message
                    $g.DrawString($msg, $ef, $eb, [single]10, [single]10)
                } finally {
                    $eb.Dispose(); $ef.Dispose()
                }
            }
        } catch { }
    } finally {
        if ($null -ne $brushMuted) { try { $brushMuted.Dispose() } catch { } }
        if ($null -ne $brushText) { try { $brushText.Dispose() } catch { } }
        if ($null -ne $fontSmall) { try { $fontSmall.Dispose() } catch { } }
        if ($null -ne $fontTitle) { try { $fontTitle.Dispose() } catch { } }
        if ($null -ne $bg) { try { $bg.Dispose() } catch { } }
    }
}

function Get-StrategyInfo([string]$name) {
    $file = Join-Path $script:RootDir $name
    if (-not (Test-Path -LiteralPath $file)) {
        return [pscustomobject]@{ Text = "Файл не найден: $name"; Techniques = @(); Comment = '' }
    }
    $raw = Get-Content -LiteralPath $file -Raw
    $item = Get-Item -LiteralPath $file

    $comments = New-Object System.Collections.Generic.List[string]
    foreach ($line in Get-Content -LiteralPath $file) {
        if ($line -match '^\s*::\s*(.+?)\s*$') {
            [void]$comments.Add($matches[1])
        } elseif ($line -match '^\s*rem\s+(.+?)\s*$') {
            [void]$comments.Add($matches[1])
        } elseif ($comments.Count -gt 0) {
            break
        }
    }
    $comment = (@($comments | Where-Object {
        $_ -notmatch '^\d{4,5}\s*-' -and $_ -notmatch '^https?://'
    } | Select-Object -First 3) -join ' ')

    $techniques = @([regex]::Matches($raw, '--dpi-desync=([a-z,]+)') |
        ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    $fooling = @([regex]::Matches($raw, '--dpi-desync-fooling=([a-z,]+)') |
        ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    $split = @([regex]::Matches($raw, '--dpi-desync-split-pos=([0-9a-z,]+)') |
        ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    $repeats = @([regex]::Matches($raw, '--dpi-desync-repeats=(\d+)') |
        ForEach-Object { [int]$_.Groups[1].Value })
    $rules = ([regex]::Matches($raw, '--new')).Count + 1

    $coverage = @()
    if ($raw -match '--filter-udp=443') { $coverage += 'QUIC/UDP' }
    if ($raw -match 'discord') { $coverage += 'Discord' }
    if ($raw -match 'google|youtube') { $coverage += 'Google/YouTube' }
    if ($raw -match 'GameFilter') { $coverage += 'игры' }
    if ($coverage.Count -eq 0) { $coverage += 'общий трафик' }

    $lines = @()
    if ((Get-SelectedStrategy) -eq $name) { $lines += 'СТАТУС: выбрана для запуска' }
    $lines += "Файл: $name  ($([math]::Round($item.Length / 1KB, 1)) КБ)"
    if ($comment) { $lines += "Описание: $comment" }
    if ($techniques.Count) { $lines += "Техники: $($techniques -join ', ')" }
    if ($fooling.Count) { $lines += "Маскировка: $($fooling -join ', ')" }
    if ($split.Count) { $lines += "Split pos: $($split -join ', ')" }
    if ($repeats.Count) {
        $lines += "Повторы fake: до $(($repeats | Measure-Object -Maximum).Maximum)"
    }
    $lines += "Правил: $rules; покрытие: $($coverage -join ', ')"

    return [pscustomobject]@{
        Text       = ($lines -join "`r`n")
        Techniques = $techniques
        Comment    = $comment
    }
}

function Reset-FirewallCache {
    $script:CachedFirewall = $null
    $script:CachedFirewallAt = [DateTime]::MinValue
}

function Get-FirewallSummary {
    $now = Get-Date
    if ($script:CachedFirewall -and
        ($now - $script:CachedFirewallAt).TotalSeconds -lt 20) {
        return $script:CachedFirewall
    }
    $text = 'нет доступа (нужен админ)'
    try {
        $rules = @(Get-NetFirewallRule -DisplayName 'zapret LAN proxy*' -ErrorAction Stop)
        if ($rules.Count -eq 0) {
            $text = 'правила не найдены'
        } else {
            $enabled = @($rules | Where-Object { $_.Enabled -eq 'True' }).Count
            $text = "$($rules.Count) правил, включено $enabled"
        }
    } catch { }
    $script:CachedFirewall = $text
    $script:CachedFirewallAt = $now
    return $text
}

function Get-LogTail([string]$path, [int]$lines = 400) {
    if (-not (Test-Path -LiteralPath $path)) { return "(файл не найден: $path)" }
    try {
        return (Get-Content -LiteralPath $path -Tail $lines -ErrorAction Stop) -join "`r`n"
    } catch {
        return "(не удалось прочитать: $($_.Exception.Message))"
    }
}

function Invoke-VisibleBat([string]$batPath, [switch]$Wait) {
    if (-not (Test-Path -LiteralPath $batPath)) {
        [Windows.Forms.MessageBox]::Show("Файл не найден:`n$batPath", 'ZAPRET CONTROL',
            'OK', 'Warning') | Out-Null
        return
    }
    $args = @('/c', "`"$batPath`"")
    if ($Wait) {
        Start-Process -FilePath 'cmd.exe' -ArgumentList $args `
            -WorkingDirectory (Split-Path -Parent $batPath) -Wait
    } else {
        Start-Process -FilePath 'cmd.exe' -ArgumentList $args `
            -WorkingDirectory (Split-Path -Parent $batPath)
    }
}

function Start-ZapretStrategy([string]$name) {
    if (-not $name) { return }
    $bat = Join-Path $script:RootDir $name
    if (-not (Test-Path -LiteralPath $bat)) {
        [Windows.Forms.MessageBox]::Show("Стратегия не найдена: $name", 'ZAPRET CONTROL',
            'OK', 'Warning') | Out-Null
        return
    }
    $service = Get-Service -Name 'zapret' -ErrorAction SilentlyContinue
    if ($service -and $service.Status -eq 'Running') {
        [Windows.Forms.MessageBox]::Show(
            "Служба 'zapret' запущена. Сначала удалите службу через service.bat,`n" +
            'иначе автозапуск и отдельная стратегия будут конфликтовать.',
            'ZAPRET CONTROL', 'OK', 'Warning') | Out-Null
        return
    }
    Remove-Item -LiteralPath (Join-Path $script:ProxyDir 'zapret.disabled') -Force -ErrorAction SilentlyContinue
    Get-Process -Name 'winws' -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 500
    Set-SelectedStrategy $name
    Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', "`"$bat`"") `
        -WorkingDirectory $script:RootDir -WindowStyle Hidden
    Start-Sleep -Seconds 2
    Update-Status
}

function Stop-ZapretNow {
    Set-Content -LiteralPath (Join-Path $script:ProxyDir 'zapret.disabled') -Value '' -Encoding ASCII
    $service = Get-Service -Name 'zapret' -ErrorAction SilentlyContinue
    if ($service -and $service.Status -eq 'Running') {
        Stop-Service -Name 'zapret' -Force -ErrorAction SilentlyContinue
    }
    Get-Process -Name 'winws' -ErrorAction SilentlyContinue | Stop-Process -Force
    Update-Status
}


function Test-ZapretBypassRunning {
    $winws = @(Get-Process -Name 'winws' -ErrorAction SilentlyContinue)
    if ($winws.Count -gt 0) { return $true }
    $svc = Get-Service -Name 'zapret' -ErrorAction SilentlyContinue
    return ($svc -and $svc.Status -eq 'Running')
}

function Toggle-ZapretBypass {
    try {
        if (Test-ZapretBypassRunning) {
            Stop-ZapretNow
            try { if ($script:TrayIcon) { $script:TrayIcon.ShowBalloonTip(3000, 'ZAPRET CONTROL', 'Обход (zapret) выключен.', [System.Windows.Forms.ToolTipIcon]::Info) } } catch { }
        } else {
            $s = Get-SelectedStrategy
            if (-not $s) {
                [Windows.Forms.MessageBox]::Show('Стратегия не выбрана. Откройте вкладку «Zapret» и выберите стратегию.', 'Обход', 'OK', 'Warning') | Out-Null
                return
            }
            Start-ZapretStrategy $s
            try { if ($script:TrayIcon) { $script:TrayIcon.ShowBalloonTip(3000, 'ZAPRET CONTROL', "Обход включён: $s", [System.Windows.Forms.ToolTipIcon]::Info) } } catch { }
        }
    } catch {
        try { [Windows.Forms.MessageBox]::Show("Не удалось переключить обход:`n$($_.Exception.Message)", 'Обход', 'OK', 'Warning') | Out-Null } catch { }
    }
    try { Update-Status } catch { }
    try { Update-BypassUiState } catch { }
}

function Update-BypassUiState {
    $on = Test-ZapretBypassRunning
    $label = if ($on) { 'Обход: ВКЛ (Ctrl+Alt+Z)' } else { 'Обход: ВЫКЛ (Ctrl+Alt+Z)' }
    try { if ($script:TrayToggleBypass) { $script:TrayToggleBypass.Text = $label } } catch { }
    try {
        if ($script:TrayIcon) {
            $state = if ($on) { 'обход ВКЛ' } else { 'обход ВЫКЛ' }
            $txt = "ZAPRET CONTROL — $state"
            if ($txt.Length -gt 63) { $txt = $txt.Substring(0,63) }
            $script:TrayIcon.Text = $txt
        }
    } catch { }
}
function Restart-ProxyNow {
    Remove-Item -LiteralPath (Join-Path $script:ProxyDir 'proxy.disabled') -Force -ErrorAction SilentlyContinue
    & powershell.exe -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $script:ProxyDir 'kill-proxy.ps1') | Out-Null
    Start-Sleep -Seconds 1
    $tasks = Get-TaskStatus
    if ($tasks['zapret-proxy'] -eq 'missing') {
        Invoke-VisibleBat (Join-Path $script:ProxyDir 'start-all.bat')
        return
    }
    schtasks /Run /TN 'zapret-proxy' | Out-Null
    Start-Sleep -Seconds 2
    Update-Status
}

function Install-Autostart {
    $pythonw = (Get-Command pythonw.exe -ErrorAction SilentlyContinue).Source
    if (-not $pythonw) { $pythonw = (Get-Command python.exe -ErrorAction SilentlyContinue).Source }
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $script:ProxyDir 'install-tasks.ps1') -Pythonw $pythonw 2>&1
    Set-Content -LiteralPath (Join-Path $script:ProxyDir 'zapret.autostart') -Value '' -Encoding ASCII
    $script:CachedTasks = $null
    [Windows.Forms.MessageBox]::Show(($out | Out-String), 'Автозапуск',
        'OK', 'Information') | Out-Null
    Update-Status
}

function Update-IpsetList {
    $url = 'https://raw.githubusercontent.com/Flowseal/zapret-discord-youtube/refs/heads/main/.service/ipset-service.txt'
    $file = Join-Path $script:ListsDir 'ipset-all.txt'
    $tmp = Join-Path $env:TEMP 'zapret_ipset_download.txt'
    try {
        Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing -TimeoutSec 30
        if (-not (Test-Path -LiteralPath $tmp) -or (Get-Item -LiteralPath $tmp).Length -lt 100) {
            throw 'сервер вернул пустой список'
        }
        # Сначала качаем во временный файл, чтобы сбой сети не стёр рабочий список.
        Copy-Item -LiteralPath $tmp -Destination $file -Force
        Copy-Item -LiteralPath $file -Destination "$file.backup" -Force
        [Windows.Forms.MessageBox]::Show('Список ipset обновлён.', 'IPSet',
            'OK', 'Information') | Out-Null
    } catch {
        [Windows.Forms.MessageBox]::Show("Не удалось обновить ipset:`n$($_.Exception.Message)",
            'IPSet', 'OK', 'Error') | Out-Null
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
    Update-IpsetStatus
}

function Update-HostsFile {
    $url = 'https://raw.githubusercontent.com/Flowseal/zapret-discord-youtube/refs/heads/main/.service/hosts'
    $tmp = Join-Path $env:TEMP 'zapret_hosts.txt'
    $hosts = Join-Path $env:windir 'System32\drivers\etc\hosts'
    try {
        Invoke-WebRequest -Uri ($url + '?t=' + (Get-Random)) -OutFile $tmp `
            -UseBasicParsing -TimeoutSec 30
        $lines = @(Get-Content -LiteralPath $tmp)
        if ($lines.Count -eq 0) { throw 'пустой файл hosts' }
        $current = if (Test-Path -LiteralPath $hosts) { Get-Content -LiteralPath $hosts -Raw } else { '' }
        if ($current.Contains($lines[0]) -and $current.Contains($lines[-1])) {
            [Windows.Forms.MessageBox]::Show('Файл hosts уже актуален.', 'Hosts',
                'OK', 'Information') | Out-Null
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        } else {
            Start-Process -FilePath 'notepad.exe' -ArgumentList "`"$tmp`""
            Start-Process -FilePath 'explorer.exe' -ArgumentList "/select,`"$hosts`""
            [Windows.Forms.MessageBox]::Show(
                "Скачан новый hosts: $tmp`n`nОткройте hosts и перенесите нужные строки вручную.",
                'Hosts', 'OK', 'Information') | Out-Null
        }
    } catch {
        [Windows.Forms.MessageBox]::Show("Не удалось обновить hosts:`n$($_.Exception.Message)",
            'Hosts', 'OK', 'Error') | Out-Null
    }
}

function Clear-DiscordCache {
    $answer = [Windows.Forms.MessageBox]::Show(
        'Закрыть Discord и очистить кэш (Cache, Code Cache, GPUCache)?',
        'Очистка кэша Discord', 'YesNo', 'Question')
    if ($answer -ne 'Yes') { return }
    $items = @(
        @{ Proc = 'Discord.exe';            Dir = Join-Path $env:APPDATA 'discord' },
        @{ Proc = 'DiscordPTB.exe';         Dir = Join-Path $env:APPDATA 'discordptb' },
        @{ Proc = 'DiscordCanary.exe';      Dir = Join-Path $env:APPDATA 'discordcanary' },
        @{ Proc = 'DiscordDevelopment.exe'; Dir = Join-Path $env:APPDATA 'discorddevelopment' }
    )
    $found = $false
    foreach ($item in $items) {
        if (-not (Test-Path -LiteralPath $item.Dir)) { continue }
        $found = $true
        Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($item.Proc)) `
            -ErrorAction SilentlyContinue | Stop-Process -Force
        foreach ($sub in @('Cache', 'Code Cache', 'GPUCache')) {
            $path = Join-Path $item.Dir $sub
            if (Test-Path -LiteralPath $path) {
                Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
    if ($found) {
        [Windows.Forms.MessageBox]::Show('Кэш Discord очищен.', 'Готово',
            'OK', 'Information') | Out-Null
    } else {
        [Windows.Forms.MessageBox]::Show('Установки Discord не найдены.', 'Готово',
            'OK', 'Warning') | Out-Null
    }
}

function Get-TestRunning {
    try {
        $procs = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction Stop
        return [bool]($procs | Where-Object { $_.CommandLine -like '*test zapret.ps1*' })
    } catch { return $false }
}

function Start-TestProcess([string[]]$extraArgs, [switch]$KeepOpen) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass')
    if ($KeepOpen) { $argList += '-NoExit' }
    $argList += @('-File', "`"$($script:TestScript)`"")
    $argList += $extraArgs
    $startParams = @{
        FilePath         = 'powershell.exe'
        ArgumentList     = $argList
        WorkingDirectory = $script:RootDir
    }
    if (-not $script:IsAdmin) { $startParams['Verb'] = 'RunAs' }
    Start-Process @startParams
}

function Test-Preflight {
    if (-not (Test-Path -LiteralPath $script:TestScript)) {
        [Windows.Forms.MessageBox]::Show('Не найден utils\test zapret.ps1', 'Тесты',
            'OK', 'Error') | Out-Null
        return $false
    }
    if (-not $script:IsAdmin) {
        [Windows.Forms.MessageBox]::Show('Тесты требуют прав администратора.', 'Тесты',
            'OK', 'Warning') | Out-Null
        return $false
    }
    if (Get-TestRunning) {
        [Windows.Forms.MessageBox]::Show('Тесты уже выполняются в другом окне.', 'Тесты',
            'OK', 'Warning') | Out-Null
        return $false
    }
    return $true
}

function Start-TestRun([string]$type, [switch]$Interactive) {
    if (-not (Test-Preflight)) { return }
    if ($Interactive) {
        Start-TestProcess -KeepOpen
    } else {
        Start-TestProcess -extraArgs @('-TestType', $type, '-Mode', 'all', '-NoPause')
    }
    $script:TestStatusLabel.Text = 'Тесты запущены в отдельном окне PowerShell...'
}

function Start-AutoSelect([switch]$Fast) {
    if (-not (Test-Preflight)) { return }
    $testType = if ($Fast) { 'standard' } else { 'dpi' }
    $kind = if ($Fast) { 'быстрые HTTP-тесты' } else { 'DPI-тесты' }
    $eta = if ($Fast) { 'обычно 1-5 минут' } else { 'может занять 10-30 минут' }
    $answer = [Windows.Forms.MessageBox]::Show(
        "Авто-подбор запустит $kind для всех стратегий (general*.bat).`r`n`r`n" +
        "Во время тестов zapret будет остановлен, ipset временно переключится`r`n" +
        "в режим 'any', затем всё восстановится. Время: $eta.`r`n`r`n" +
        "Лучшая стратегия будет сохранена и запущена автоматически. Продолжить?",
        'Авто-подбор стратегии', 'YesNo', 'Question')
    if ($answer -ne 'Yes') { return }
    Start-TestProcess -extraArgs @('-TestType', $testType, '-Mode', 'all', '-NoPause', '-AutoApply')
    $script:TestStatusLabel.Text = "Авто-подбор: идут $kind, лучшая стратегия применится автоматически..."
    if ($script:ZpCurrent) { $script:ZpCurrent.Text = 'Авто-подбор выполняется...' }
}

function Apply-BestFromResult {
    $file = Get-LatestResultFile
    if (-not $file) {
        [Windows.Forms.MessageBox]::Show('Результатов тестов пока нет. Запустите тесты.',
            'Авто-подбор', 'OK', 'Information') | Out-Null
        return
    }
    $name = Get-BestFromResultFile $file
    if (-not $name) {
        [Windows.Forms.MessageBox]::Show(
            "В файле $($file.Name) нет строки 'Best strategy'.",
            'Авто-подбор', 'OK', 'Warning') | Out-Null
        return
    }
    if (-not (Test-Path -LiteralPath (Join-Path $script:RootDir $name))) {
        [Windows.Forms.MessageBox]::Show("Файл стратегии не найден: $name",
            'Авто-подбор', 'OK', 'Warning') | Out-Null
        return
    }
    Set-SelectedStrategy $name
    $answer = [Windows.Forms.MessageBox]::Show(
        "Лучшая стратегия по последнему тесту:`r`n$name`r`n`r`nЗапустить её сейчас?",
        'Авто-подбор', 'YesNo', 'Question')
    if ($answer -eq 'Yes') { Start-ZapretStrategy $name }
    Update-Status
}

# --------------------------------------------------------------------------
#  Дополнительные действия: проверка соединения, задачи, брандмауэр, отчёты
# --------------------------------------------------------------------------

function Start-ConnectionTest {
    if ($script:ConnRunning) {
        [Windows.Forms.MessageBox]::Show('Проверка уже выполняется.', 'Соединение',
            'OK', 'Information') | Out-Null
        return
    }
    if (-not (Test-Path -LiteralPath $script:ConnScript)) {
        [Windows.Forms.MessageBox]::Show("Не найден файл:`n$($script:ConnScript)",
            'Соединение', 'OK', 'Warning') | Out-Null
        return
    }
    $script:ConnRunning = $true
    $script:ConnStarted = Get-Date
    $script:LastConnSummary = ''
    Remove-Item -LiteralPath $script:ConnOut -Force -ErrorAction SilentlyContinue
    if ($script:ConnBox) { $script:ConnBox.Text = 'Проверка соединения... (обычно 5-20 секунд)' }
    $argList = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', "`"$($script:ConnScript)`"",
        '-HttpPort', '8080', '-SocksPort', '1080',
        '-OutFile', "`"$($script:ConnOut)`""
    )
    try {
        $script:ConnProc = Start-Process -FilePath 'powershell.exe' `
            -ArgumentList $argList -WindowStyle Hidden -PassThru
        if ($script:ConnTimer) { $script:ConnTimer.Start() }
    } catch {
        $script:ConnRunning = $false
        if ($script:ConnBox) { $script:ConnBox.Text = "Ошибка запуска: $($_.Exception.Message)" }
    }
}

function Show-ConnectionTest {
    Switch-Tab 'proxy'
    Start-ConnectionTest
}

function Invoke-AllTasks([string]$action) {
    if (-not $script:IsAdmin) {
        [Windows.Forms.MessageBox]::Show('Нужны права администратора. Запустите ZapretControl.exe и подтвердите UAC.',
            'Задачи', 'OK', 'Warning') | Out-Null
        return
    }
    $failed = @()
    foreach ($name in @('zapret-proxy', 'zapret-proxy-watchdog', 'zapret-max')) {
        $out = & schtasks /$action /TN $name 2>&1
        if ($LASTEXITCODE -ne 0) { $failed += $name }
    }
    $script:CachedTasks = $null
    Start-Sleep -Milliseconds 800
    Update-Status
    if ($failed.Count -gt 0) {
        [Windows.Forms.MessageBox]::Show("Не удалось выполнить $action для:`n$($failed -join "`n")",
            'Задачи', 'OK', 'Warning') | Out-Null
    }
}

function Add-FirewallRules {
    if (-not $script:IsAdmin) {
        [Windows.Forms.MessageBox]::Show('Нужны права администратора.', 'Брандмауэр',
            'OK', 'Warning') | Out-Null
        return
    }
    & netsh advfirewall firewall delete rule 'name=zapret LAN proxy' | Out-Null
    & netsh advfirewall firewall delete rule 'name=zapret LAN proxy UDP' | Out-Null
    & netsh advfirewall firewall add rule 'name=zapret LAN proxy' dir=in action=allow `
        protocol=TCP 'localport=8080,1080' `
        'remoteip=192.168.0.0/16,10.0.0.0/8,172.16.0.0/12' profile=any | Out-Null
    $tcpRc = $LASTEXITCODE
    & netsh advfirewall firewall add rule 'name=zapret LAN proxy UDP' dir=in action=allow `
        protocol=UDP 'localport=31000-31999' `
        'remoteip=192.168.0.0/16,10.0.0.0/8,172.16.0.0/12' profile=any | Out-Null
    $udpRc = $LASTEXITCODE
    Reset-FirewallCache
    Update-Status
    if ($tcpRc -eq 0 -and $udpRc -eq 0) {
        [Windows.Forms.MessageBox]::Show('Правила брандмауэра созданы/обновлены.',
            'Брандмауэр', 'OK', 'Information') | Out-Null
    } else {
        [Windows.Forms.MessageBox]::Show("netsh вернул ошибку (TCP=$tcpRc, UDP=$udpRc).",
            'Брандмауэр', 'OK', 'Warning') | Out-Null
    }
}

function Remove-FirewallRules {
    if (-not $script:IsAdmin) {
        [Windows.Forms.MessageBox]::Show('Нужны права администратора.', 'Брандмауэр',
            'OK', 'Warning') | Out-Null
        return
    }
    $answer = [Windows.Forms.MessageBox]::Show(
        'Удалить правила брандмауэра zapret LAN proxy?', 'Брандмауэр', 'YesNo', 'Question')
    if ($answer -ne 'Yes') { return }
    & netsh advfirewall firewall delete rule 'name=zapret LAN proxy' | Out-Null
    & netsh advfirewall firewall delete rule 'name=zapret LAN proxy UDP' | Out-Null
    Reset-FirewallCache
    Update-Status
}

function Stop-TestRun {
    $procs = @()
    try {
        $procs = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction Stop |
            Where-Object { $_.CommandLine -like '*test zapret.ps1*' })
    } catch { }
    if ($procs.Count -eq 0) {
        [Windows.Forms.MessageBox]::Show('Запущенных тестов не найдено.', 'Тесты',
            'OK', 'Information') | Out-Null
        return
    }
    $answer = [Windows.Forms.MessageBox]::Show(
        "Остановить тесты? Будет завершено процессов: $($procs.Count).",
        'Тесты', 'YesNo', 'Question')
    if ($answer -ne 'Yes') { return }
    foreach ($proc in $procs) {
        Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
    }
    $script:TestWasRunning = $false
    $script:TestStatusLabel.Text = 'Тесты остановлены пользователем.'
}

function Save-DiagReport {
    if ($script:DiagBox.TextLength -eq 0) { Run-Diagnostics }
    $file = Join-Path $script:ProxyDir `
        ("diagnostics-{0}.txt" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    try {
        Set-Content -LiteralPath $file -Value $script:DiagBox.Text -Encoding UTF8
        [Windows.Forms.MessageBox]::Show("Отчёт сохранён:`n$file", 'Диагностика',
            'OK', 'Information') | Out-Null
    } catch {
        [Windows.Forms.MessageBox]::Show("Не удалось сохранить отчёт:`n$($_.Exception.Message)",
            'Диагностика', 'OK', 'Error') | Out-Null
    }
}

function Get-InstalledZapretControlVersion {
    $candidates = @(
        (Join-Path ${env:ProgramFiles} 'ZapretControl\proxy\ZapretControl.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'ZapretControl\proxy\ZapretControl.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\ZapretControl\proxy\ZapretControl.exe'),
        (Join-Path $script:ProxyDir 'ZapretControl.exe')
    ) | Where-Object { $_ -and $_ -ne '' } | Select-Object -Unique
    foreach ($p in $candidates) {
        try {
            if (Test-Path -LiteralPath $p) {
                $v = [string](Get-Item -LiteralPath $p -ErrorAction Stop).VersionInfo.FileVersion
                if ($v) { return $v.Trim() }
            }
        } catch { }
    }
    return [string]$script:AppVersion
}

function Get-NormalizedVersion([string]$v) {
    if (-not $v) { return [version]'0.0.0.0' }
    $s = $v.Trim()
    if ($s.StartsWith('v') -or $s.StartsWith('V')) { $s = $s.Substring(1) }
    $s = ($s -split '[-+]')[0]
    $s = [regex]::Replace($s, '[^0-9\.]', '')
    $parts = @($s.Split('.') | Where-Object { $_ -ne '' })
    if ($parts.Count -eq 0) { return [version]'0.0.0.0' }
    while ($parts.Count -lt 4) { $parts += '0' }
    if ($parts.Count -gt 4) { $parts = $parts[0..3] }
    try { return [version]([string]::Join('.', $parts)) } catch { return [version]'0.0.0.0' }
}

function Get-LatestZapretControlRelease {
    $api = "https://api.github.com/repos/$($script:UpdateRepo)/releases"
    $resp = Invoke-RestMethod -Uri $api -Headers @{ 'User-Agent' = "ZapretControl/$($script:AppVersion)"; 'Accept' = 'application/vnd.github+json' } -TimeoutSec 12 -UseBasicParsing -ErrorAction Stop
    $release = $null
    foreach ($r in @($resp)) {
        if ($r.draft -or $r.prerelease) { continue }
        $tag = [string]$r.tag_name
        if ($tag -match '^v\d') { $release = $r; break }
    }
    if (-not $release) { throw 'Не найден подходящий релиз Windows (v*).' }
    $setup = $null
    $exe = $null
    foreach ($a in @($release.assets)) {
        $name = [string]$a.name
        $url = [string]$a.browser_download_url
        if ($name -ieq 'ZapretControlSetup.exe') { $setup = $url }
        elseif ($name -ieq 'ZapretControl.exe') { $exe = $url }
    }
    $tag = [string]$release.tag_name
    $ver = $tag
    if ($ver.StartsWith('v') -or $ver.StartsWith('V')) { $ver = $ver.Substring(1) }
    return [pscustomobject]@{
        Tag         = $tag
        Version     = $ver
        Name        = [string]$release.name
        Url         = [string]$release.html_url
        SetupUrl    = $setup
        ExeUrl      = $exe
        Body        = [string]$release.body
        PublishedAt = $release.published_at
    }
}

function Start-ZapretControlSelfUpdate([string]$setupUrl) {
    if (-not $setupUrl) { throw 'В релизе нет файла ZapretControlSetup.exe.' }
    $tempSetup = Join-Path $env:TEMP ("ZapretControlSetup-update-{0}.exe" -f [Guid]::NewGuid().ToString('N'))
    try { Add-Diag "Скачивание установщика: $setupUrl" $script:Theme.Muted } catch { }
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    Invoke-WebRequest -Uri $setupUrl -OutFile $tempSetup -UseBasicParsing -TimeoutSec 300
    if (-not (Test-Path -LiteralPath $tempSetup) -or (Get-Item -LiteralPath $tempSetup).Length -lt 100000) {
        throw 'Скачанный установщик повреждён или пуст.'
    }
    $psPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $updateScript = Join-Path $env:TEMP ("zapret-selfupdate-{0}.ps1" -f [Guid]::NewGuid().ToString('N'))
    $scriptContent = @'
$ErrorActionPreference = 'SilentlyContinue'
Start-Sleep -Seconds 2
Get-Process -Name 'ZapretControl' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Get-CimInstance Win32_Process -Filter "Name='python.exe' OR Name='pythonw.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -like '*zapret-proxy.py*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
$svc = Get-Service -Name 'WinDivert' -ErrorAction SilentlyContinue
if ($svc) { try { Stop-Service -Name 'WinDivert' -Force -ErrorAction SilentlyContinue } catch { }; try { sc.exe stop WinDivert | Out-Null } catch { } }
Start-Sleep -Seconds 2
$p = Start-Process -FilePath '__SETUP__' -ArgumentList '-Silent' -Wait -PassThru
Start-Sleep -Seconds 1
Remove-Item -LiteralPath '__SETUP__' -Force -ErrorAction SilentlyContinue
$installed = Join-Path $env:ProgramFiles 'ZapretControl\proxy\ZapretControl.exe'
if (Test-Path -LiteralPath $installed) {
    Start-Process -FilePath $installed -WorkingDirectory (Split-Path -Parent $installed)
}
Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction SilentlyContinue
'@
    $scriptContent = $scriptContent.Replace('__SETUP__', $tempSetup.Replace("'", "''"))
    [IO.File]::WriteAllText($updateScript, $scriptContent, [System.Text.UTF8Encoding]::new($false))
    Start-Process -FilePath $psPath -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File', $updateScript) -WindowStyle Hidden
    try { Add-Diag 'Установщик обновления запущен. Приложение будет закрыто для замены файлов.' $script:Theme.Yellow } catch { }
    $script:ReallyExit = $true
    try { Save-GuiSettings } catch { }
    try { $form.Close() } catch { [Environment]::Exit(0) }
}

function Invoke-AppUpdateCheck([bool]$silent = $false, [bool]$autoInstall = $false) {
    $current = [string](Get-InstalledZapretControlVersion)
    $currentN = Get-NormalizedVersion $current
    try { Add-Diag "Проверка обновлений ZAPRET CONTROL (текущая: $current, репозиторий: $($script:UpdateRepo))..." $script:Theme.Muted } catch { }
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    $release = $null
    try {
        $release = Get-LatestZapretControlRelease
    } catch {
        $msg = $_.Exception.Message
        try { Add-Diag "Не удалось проверить обновления: $msg" $script:Theme.Red } catch { }
        if (-not $silent) {
            [Windows.Forms.MessageBox]::Show(
                "Не удалось проверить обновления:`n$msg`n`nПроверьте подключение к интернету и доступ к GitHub.",
                'Обновления ZAPRET CONTROL', 'OK', 'Warning') | Out-Null
        }
        return
    }
    $latestN = Get-NormalizedVersion $release.Version
    try { Add-Diag "Актуальная версия на GitHub: $($release.Tag)" $script:Theme.Cyan } catch { }
    if ($latestN -le $currentN) {
        try { Add-Diag "Установлена последняя версия ($current)." $script:Theme.Green } catch { }
        if (-not $silent) {
            [Windows.Forms.MessageBox]::Show(
                "У вас установлена последняя версия: $current`n`nРелиз: $($release.Name)`n$($release.Url)",
                'Обновления ZAPRET CONTROL', 'OK', 'Information') | Out-Null
        }
        return
    }

    try { Add-Diag "Доступно обновление: $($release.Tag) (установлено: $current)" $script:Theme.Yellow } catch { }
    $notes = [string]$release.Body
    if ($notes.Length -gt 700) { $notes = $notes.Substring(0, 700) + '...' }

    if ($autoInstall) {
        try {
            if ($script:TrayIcon) {
                $script:TrayIcon.ShowBalloonTip(8000, 'ZAPRET CONTROL', "Найдено обновление $($release.Tag). Автоматическая загрузка и установка...", [System.Windows.Forms.ToolTipIcon]::Info)
            }
        } catch { }
        try {
            if (-not $release.SetupUrl) { try { Start-Process $release.Url } catch { }; return }
            Start-ZapretControlSelfUpdate -setupUrl $release.SetupUrl
        } catch {
            $em = $_.Exception.Message
            try { Add-Diag "Ошибка автообновления: $em" $script:Theme.Red } catch { }
            if (-not $silent) {
                $open = [Windows.Forms.MessageBox]::Show(
                    "Не удалось установить обновление автоматически:`n$em`n`nОткрыть страницу релиза?",
                    'Обновления ZAPRET CONTROL', [Windows.Forms.MessageBoxButtons]::YesNo, [Windows.Forms.MessageBoxIcon]::Warning)
                if ($open -eq [Windows.Forms.DialogResult]::Yes) { try { Start-Process $release.Url } catch { } }
            }
        }
        return
    }

    $prompt = "Доступна новая версия: $($release.Tag)`nУстановлена: $current`n`n$notes`n`nСкачать и установить сейчас?"
    $answer = [Windows.Forms.MessageBox]::Show($prompt, 'Обновление ZAPRET CONTROL',
        [Windows.Forms.MessageBoxButtons]::YesNoCancel, [Windows.Forms.MessageBoxIcon]::Information)

    if ($answer -eq [Windows.Forms.DialogResult]::Yes) {
        try {
            if (-not $release.SetupUrl) {
                Start-Process $release.Url
                [Windows.Forms.MessageBox]::Show(
                    "В релизе не найден установщик. Открыта страница релиза:`n$($release.Url)",
                    'Обновления ZAPRET CONTROL', 'OK', 'Information') | Out-Null
                return
            }
            Start-ZapretControlSelfUpdate -setupUrl $release.SetupUrl
        } catch {
            $em = $_.Exception.Message
            try { Add-Diag "Ошибка автообновления: $em" $script:Theme.Red } catch { }
            $open = [Windows.Forms.MessageBox]::Show(
                "Не удалось установить обновление автоматически:`n$em`n`nОткрыть страницу релиза?",
                'Обновления ZAPRET CONTROL', [Windows.Forms.MessageBoxButtons]::YesNo, [Windows.Forms.MessageBoxIcon]::Warning)
            if ($open -eq [Windows.Forms.DialogResult]::Yes) { try { Start-Process $release.Url } catch { } }
        }
    } elseif ($answer -eq [Windows.Forms.DialogResult]::Cancel) {
        $open = [Windows.Forms.MessageBox]::Show("Открыть страницу релиза $($release.Tag)?",
            'Обновления ZAPRET CONTROL', [Windows.Forms.MessageBoxButtons]::YesNo, [Windows.Forms.MessageBoxIcon]::Question)
        if ($open -eq [Windows.Forms.DialogResult]::Yes) { try { Start-Process $release.Url } catch { } }
    }
}

function Start-AppUpdateCheckAsync {
    try {
        if ($script:AppUpdateCheckRunning) { return }
        $script:AppUpdateCheckRunning = $true
        $psPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $resultFile = Join-Path $env:TEMP ("zapret-app-update-{0}.json" -f [Guid]::NewGuid().ToString('N'))
        $worker = Join-Path $env:TEMP ("zapret-app-update-{0}.ps1" -f [Guid]::NewGuid().ToString('N'))
        $repo = $script:UpdateRepo
        $cur = [string](Get-InstalledZapretControlVersion)
        $workerBody = @'
$ErrorActionPreference = 'Stop'
try {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    $api = 'https://api.github.com/repos/__REPO__/releases'
    $resp = Invoke-RestMethod -Uri $api -Headers @{ 'User-Agent' = 'ZapretControl/__CUR__'; 'Accept' = 'application/vnd.github+json' } -TimeoutSec 12 -UseBasicParsing
    $release = $null
    foreach ($r in @($resp)) {
        if ($r.draft -or $r.prerelease) { continue }
        $tag = [string]$r.tag_name
        if ($tag -match '^v\d') { $release = $r; break }
    }
    if (-not $release) { throw 'no release' }
    $setup = $null; $exe = $null
    foreach ($a in @($release.assets)) {
        $name = [string]$a.name; $url = [string]$a.browser_download_url
        if ($name -ieq 'ZapretControlSetup.exe') { $setup = $url }
        elseif ($name -ieq 'ZapretControl.exe') { $exe = $url }
    }
    $tag = [string]$release.tag_name; $ver = $tag
    if ($ver.StartsWith('v') -or $ver.StartsWith('V')) { $ver = $ver.Substring(1) }
    $out = [ordered]@{ ok = $true; tag = $tag; version = $ver; name = [string]$release.name; url = [string]$release.html_url; setup = $setup; exe = $exe; body = [string]$release.body }
    ($out | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath '__RESULT__' -Encoding UTF8
} catch {
    $out = [ordered]@{ ok = $false; error = $_.Exception.Message }
    ($out | ConvertTo-Json) | Set-Content -LiteralPath '__RESULT__' -Encoding UTF8
} finally {
    Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction SilentlyContinue
}
'@
    $workerBody = $workerBody.Replace('__REPO__', $repo).Replace('__CUR__', $cur.Replace("'", "''")).Replace('__RESULT__', $resultFile.Replace("'", "''"))
    [IO.File]::WriteAllText($worker, $workerBody, [System.Text.UTF8Encoding]::new($false))
    [void](Start-Process -FilePath $psPath -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',$worker) -WindowStyle Hidden)
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 1000
    $deadline = (Get-Date).AddSeconds(20)
    $state = @{ ResultFile = $resultFile; Deadline = $deadline }
    $timer.Add_Tick({
        $done = $false
        try {
            if (Test-Path -LiteralPath $state.ResultFile) {
                $raw = Get-Content -LiteralPath $state.ResultFile -Raw -ErrorAction Stop
                if ($raw -and $raw.Trim().Length -gt 0) { $done = $true }
            }
        } catch { }
        if (-not $done -and (Get-Date) -lt $state.Deadline) { return }
        try { $timer.Stop() } catch { }
        try { $timer.Dispose() } catch { }
        $script:AppUpdateCheckRunning = $false
        if (-not $done) { try { Remove-Item -LiteralPath $state.ResultFile -Force -ErrorAction SilentlyContinue } catch { }; return }
        try {
            $raw = Get-Content -LiteralPath $state.ResultFile -Raw -ErrorAction Stop
            Remove-Item -LiteralPath $state.ResultFile -Force -ErrorAction SilentlyContinue
            $obj = $raw | ConvertFrom-Json
            if (-not $obj.ok) { return }
            $current = [string](Get-InstalledZapretControlVersion)
            $currentN = Get-NormalizedVersion $current
            $latestN = Get-NormalizedVersion ([string]$obj.version)
            if ($latestN -le $currentN) { try { Update-UpdatesTabFromObject -obj $obj } catch { }; return }
            $script:LatestAppUpdate = $obj
            try { Update-UpdatesTabFromObject -obj $obj } catch { }
            try { Add-Diag "Доступно обновление ZAPRET CONTROL: $($obj.tag) (установлено: $current). Автоматическая установка..." $script:Theme.Yellow } catch { }
            try { if ($script:TrayIcon) { $script:TrayIcon.ShowBalloonTip(8000, 'ZAPRET CONTROL', "Найдено обновление $($obj.tag). Скачивание и установка автоматически...", [System.Windows.Forms.ToolTipIcon]::Info) } } catch { }
            try {
                if ($obj.setup) {
                    Start-ZapretControlSelfUpdate -setupUrl ([string]$obj.setup)
                } elseif ($obj.url) {
                    try { Start-Process ([string]$obj.url) } catch { }
                }
            } catch {
                $em = $_.Exception.Message
                try { Add-Diag "Ошибка автообновления: $em" $script:Theme.Red } catch { }
            }
        } catch { }
    }.GetNewClosure())
    $timer.Start()
    } catch {
        $script:AppUpdateCheckRunning = $false
    }
}


function Update-UpdatesTabFromObject([object]$obj) {
    if (-not $script:UpdStatusLabel) { return }
    try {
        $current = [string](Get-InstalledZapretControlVersion)
        $script:UpdCurrentLabel.Text = "Установлено: $current"
        if ($null -eq $obj) {
            $script:UpdLatestLabel.Text = 'Актуальная версия: не проверялась'
            $script:UpdStatusLabel.Text = 'Нажмите «Проверить обновления», чтобы узнать актуальную версию.'
            $script:UpdStatusLabel.ForeColor = Color $script:Theme.Muted
            return
        }
        $script:UpdLatestLabel.Text = "Актуальная версия: $($obj.tag)"
        $curN = Get-NormalizedVersion $current
        $newN = Get-NormalizedVersion ([string]$obj.version)
        if ($newN -le $curN) {
            $script:UpdStatusLabel.Text = '✓ Установлена последняя версия'
            $script:UpdStatusLabel.ForeColor = Color $script:Theme.Green
        } else {
            $script:UpdStatusLabel.Text = "Доступно обновление $($obj.tag) — можно скачать и установить"
            $script:UpdStatusLabel.ForeColor = Color $script:Theme.Yellow
        }
        $notes = [string]$obj.body
        if (-not $notes) { $notes = 'Описание релиза отсутствует.' }
        $script:UpdNotes.Text = "Релиз: $($obj.name)`r`nСтраница: $($obj.url)`r`n`r`n$notes"
    } catch { }
}

function Start-UpdatesTabCheckAsync {
    if ($script:UpdCheckRunning) { return }
    $script:UpdCheckRunning = $true
    try {
        $script:UpdStatusLabel.Text = 'Проверка обновлений на GitHub...'
        $script:UpdStatusLabel.ForeColor = Color $script:Theme.Cyan
    } catch { }
    try {
        $psPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $resultFile = Join-Path $env:TEMP ("zapret-upd-tab-{0}.json" -f [Guid]::NewGuid().ToString('N'))
        $worker = Join-Path $env:TEMP ("zapret-upd-tab-{0}.ps1" -f [Guid]::NewGuid().ToString('N'))
        $repo = $script:UpdateRepo
        $cur = [string](Get-InstalledZapretControlVersion)
        $workerBody = @'
$ErrorActionPreference = 'Stop'
try {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    $resp = Invoke-RestMethod -Uri 'https://api.github.com/repos/__REPO__/releases' -Headers @{ 'User-Agent' = 'ZapretControl/__CUR__'; 'Accept' = 'application/vnd.github+json' } -TimeoutSec 12 -UseBasicParsing
    $release = $null
    foreach ($r in @($resp)) {
        if ($r.draft -or $r.prerelease) { continue }
        if ([string]$r.tag_name -match '^v\d') { $release = $r; break }
    }
    if (-not $release) { throw 'no release' }
    $setup = $null; $exe = $null
    foreach ($a in @($release.assets)) {
        $n = [string]$a.name; $u = [string]$a.browser_download_url
        if ($n -ieq 'ZapretControlSetup.exe') { $setup = $u }
        elseif ($n -ieq 'ZapretControl.exe') { $exe = $u }
    }
    $tag = [string]$release.tag_name; $ver = $tag
    if ($ver.StartsWith('v') -or $ver.StartsWith('V')) { $ver = $ver.Substring(1) }
    $out = [ordered]@{ ok = $true; tag = $tag; version = $ver; name = [string]$release.name; url = [string]$release.html_url; setup = $setup; exe = $exe; body = [string]$release.body }
    ($out | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath '__RESULT__' -Encoding UTF8
} catch {
    $out = [ordered]@{ ok = $false; error = $_.Exception.Message }
    ($out | ConvertTo-Json) | Set-Content -LiteralPath '__RESULT__' -Encoding UTF8
} finally {
    Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction SilentlyContinue
}
'@
        $workerBody = $workerBody.Replace('__REPO__', $repo).Replace('__CUR__', $cur.Replace("'", "''")).Replace('__RESULT__', $resultFile.Replace("'", "''"))
        [IO.File]::WriteAllText($worker, $workerBody, [System.Text.UTF8Encoding]::new($false))
        [void](Start-Process -FilePath $psPath -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $worker) -WindowStyle Hidden)
        $timer = New-Object System.Windows.Forms.Timer
        $timer.Interval = 1000
        $deadline = (Get-Date).AddSeconds(20)
        $state = @{ ResultFile = $resultFile; Deadline = $deadline }
        $timer.Add_Tick({
            $done = $false
            try {
                if (Test-Path -LiteralPath $state.ResultFile) {
                    $rawTmp = Get-Content -LiteralPath $state.ResultFile -Raw -ErrorAction Stop
                    if ($rawTmp -and $rawTmp.Trim().Length -gt 0) { $done = $true }
                }
            } catch { }
            if (-not $done -and (Get-Date) -lt $state.Deadline) { return }
            try { $timer.Stop() } catch { }
            try { $timer.Dispose() } catch { }
            $script:UpdCheckRunning = $false
            if (-not $done) {
                try { $script:UpdStatusLabel.Text = 'Не удалось получить ответ от GitHub (таймаут).' } catch { }
                return
            }
            try {
                $raw2 = Get-Content -LiteralPath $state.ResultFile -Raw -ErrorAction Stop
                Remove-Item -LiteralPath $state.ResultFile -Force -ErrorAction SilentlyContinue
                $obj = $raw2 | ConvertFrom-Json
                if (-not $obj.ok) {
                    $script:UpdStatusLabel.Text = "Ошибка проверки: $($obj.error)"
                    $script:UpdStatusLabel.ForeColor = Color $script:Theme.Red
                    return
                }
                $script:LatestAppUpdate = $obj
                Update-UpdatesTabFromObject -obj $obj
            } catch {
                try { $script:UpdStatusLabel.Text = "Ошибка проверки: $($_.Exception.Message)" } catch { }
            }
        }.GetNewClosure())
        $timer.Start()
    } catch {
        $script:UpdCheckRunning = $false
        try { $script:UpdStatusLabel.Text = "Ошибка проверки: $($_.Exception.Message)" } catch { }
    }
}

function Start-UpdatesTabInstall {
    $obj = $script:LatestAppUpdate
    if (-not $obj) {
        try {
            $rel = Get-LatestZapretControlRelease
            $obj = [pscustomobject]@{
                tag = $rel.Tag; version = $rel.Version; name = $rel.Name; url = $rel.Url
                setup = $rel.SetupUrl; exe = $rel.ExeUrl; body = $rel.Body
            }
            $script:LatestAppUpdate = $obj
            Update-UpdatesTabFromObject -obj $obj
        } catch {
            [Windows.Forms.MessageBox]::Show(
                "Сначала проверьте обновления.`n`n$($_.Exception.Message)",
                'Обновления ZAPRET CONTROL', 'OK', 'Information') | Out-Null
            return
        }
    }
    if (-not $obj.setup) {
        try { Start-Process ([string]$obj.url) } catch { }
        return
    }
    try {
        $script:UpdStatusLabel.Text = "Скачивание и установка $($obj.tag)..."
        $script:UpdStatusLabel.ForeColor = Color $script:Theme.Yellow
        Start-ZapretControlSelfUpdate -setupUrl ([string]$obj.setup)
    } catch {
        $em = $_.Exception.Message
        try { $script:UpdStatusLabel.Text = "Ошибка установки: $em" } catch { }
        $open = [Windows.Forms.MessageBox]::Show(
            "Не удалось установить обновление автоматически:`n$em`n`nОткрыть страницу релиза?",
            'Обновления ZAPRET CONTROL', [Windows.Forms.MessageBoxButtons]::YesNo,
            [Windows.Forms.MessageBoxIcon]::Warning)
        if ($open -eq [Windows.Forms.DialogResult]::Yes) { try { Start-Process ([string]$obj.url) } catch { } }
    }
}

function Copy-DiagReport {
    if ($script:DiagBox.TextLength -eq 0) { Run-Diagnostics }
    try {
        [Windows.Forms.Clipboard]::SetText($script:DiagBox.Text)
        [Windows.Forms.MessageBox]::Show('Отчёт скопирован в буфер обмена.', 'Диагностика',
            'OK', 'Information') | Out-Null
    } catch {
        [Windows.Forms.MessageBox]::Show("Не удалось скопировать:`n$($_.Exception.Message)",
            'Диагностика', 'OK', 'Error') | Out-Null
    }
}

# --------------------------------------------------------------------------
#  Самопроверка (запускается с -SelfTest, без открытия окна)
# --------------------------------------------------------------------------

if ($SelfTest) {
    $script:SelfTestLines = New-Object System.Collections.Generic.List[string]
    function Check([string]$name, [bool]$ok, [string]$detail = '') {
        if ($ok) {
            [void]$script:SelfTestLines.Add("[OK]   $name $detail")
        } else {
            [void]$script:SelfTestLines.Add("[FAIL] $name $detail")
            $script:SelfTestFail++
        }
    }
    $script:SelfTestFail = 0
    [void]$script:SelfTestLines.Add('ZAPRET CONTROL self-test')
    Check 'proxy folder' (Test-Path -LiteralPath $script:ProxyDir) $script:ProxyDir
    Check 'root folder' (Test-Path -LiteralPath $script:RootDir) $script:RootDir
    Check 'utils/test zapret.ps1' (Test-Path -LiteralPath $script:TestScript)
    Check 'test-connection.ps1' (Test-Path -LiteralPath $script:ConnScript)
    Check 'restart-all.bat' (Test-Path -LiteralPath (Join-Path $script:ProxyDir 'restart-all.bat'))
    Check 'python' ([bool]((Get-Command pythonw.exe -ErrorAction SilentlyContinue) -or
        (Get-Command python.exe -ErrorAction SilentlyContinue)))
    $strategies = Get-StrategyFiles
    Check 'strategies found' ($strategies.Count -gt 0) "count=$($strategies.Count)"
    Check 'selected strategy exists' (Test-Path -LiteralPath (Join-Path $script:RootDir (Get-SelectedStrategy)))
    Check 'ipset status' ([bool](Get-IpsetStatus)) (Get-IpsetStatus)
    Check 'proxy port 8080' (Get-PortOpen 8080)
    Check 'socks port 1080' (Get-PortOpen 1080)
    Check 'firewall rules' ((Get-FirewallSummary) -notmatch 'не найдены|нет доступа') (Get-FirewallSummary)
    $health = Get-ProxyHealth -Force
    Check 'proxy /health' ([bool]$health) $(if ($health) { "v$($health.version) uptime=$($health.uptime)s" } else { 'нет ответа (v1.3?)' })
    Check 'lan ip' ([bool](Get-LanIp)) (Get-LanIp)
    [void]$script:SelfTestLines.Add("Done. failures=$($script:SelfTestFail)")
    $script:SelfTestLines | Set-Content -LiteralPath `
        (Join-Path $script:ProxyDir 'self-test.txt') -Encoding UTF8
    [Environment]::Exit([int]$script:SelfTestFail)
}

# --------------------------------------------------------------------------
#  UI helpers
# --------------------------------------------------------------------------

[Windows.Forms.Application]::EnableVisualStyles()
[Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

function New-UILabel {
    param(
        $Parent, [string]$Text, [int]$X, [int]$Y,
        [int]$W = 0, [int]$H = 0, [int]$Size = 10,
        [string]$Color = '#e6edf3', [bool]$Bold = $false,
        [string]$Align = 'MiddleLeft'
    )
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.ForeColor = Color $Color
    $label.BackColor = [System.Drawing.Color]::Transparent
    $style = if ($Bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
    $label.Font = New-Object System.Drawing.Font -ArgumentList @('Segoe UI', $Size, $style)
    $label.TextAlign = $Align
    if ($W -gt 0) {
        $label.AutoSize = $false
        $label.Location = New-Object System.Drawing.Point -ArgumentList @($X, $Y)
        $label.Size = New-Object System.Drawing.Size -ArgumentList @($W, $H)
    } else {
        $label.AutoSize = $true
        $label.Location = New-Object System.Drawing.Point -ArgumentList @($X, $Y)
    }
    $Parent.Controls.Add($label)
    return $label
}

function New-UIButton {
    param(
        $Parent, [string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H,
        [string]$Back = '#5b7cfa', [scriptblock]$OnClick = $null,
        [string]$Fore = '#ffffff'
    )
    $button = New-Object System.Windows.Forms.Button
    $button.Text = $Text
    $button.Location = New-Object System.Drawing.Point -ArgumentList @($X, $Y)
    $button.Size = New-Object System.Drawing.Size -ArgumentList @($W, $H)
    $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $button.FlatAppearance.BorderSize = 1
    $base = Color $Back
    $button.BackColor = $base
    $button.ForeColor = Color $Fore
    $r = [Math]::Min(255, $base.R + 22); $g = [Math]::Min(255, $base.G + 22); $b = [Math]::Min(255, $base.B + 22)
    $r2 = [Math]::Max(0, $base.R - 18); $g2 = [Math]::Max(0, $base.G - 18); $b2 = [Math]::Max(0, $base.B - 18)
    $rb = [Math]::Min(255, $base.R + 40); $gb = [Math]::Min(255, $base.G + 40); $bb = [Math]::Min(255, $base.B + 40)
    $button.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb($r, $g, $b)
    $button.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb($r2, $g2, $b2)
    $button.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb($rb, $gb, $bb)
    $button.Font = New-Object System.Drawing.Font -ArgumentList @('Segoe UI Semibold', 9.5)
    $button.Cursor = [System.Windows.Forms.Cursors]::Hand
    $button.UseVisualStyleBackColor = $false
    if ($OnClick) { $button.Add_Click($OnClick) }
    $Parent.Controls.Add($button)
    return $button
}

function New-UICard {
    param($Parent, [int]$X, [int]$Y, [int]$W, [int]$H, [string]$Title = '')
    $panel = New-Object System.Windows.Forms.Panel
    $panel.Location = New-Object System.Drawing.Point -ArgumentList @($X, $Y)
    $panel.Size = New-Object System.Drawing.Size -ArgumentList @($W, $H)
    $panel.BackColor = Color $script:Theme.Surface
    $panel.Padding = New-Object System.Windows.Forms.Padding -ArgumentList @(1, 1, 1, 1)
    $panel.Add_Paint({
        param($sender, $e)
        try {
            $rect = $sender.ClientRectangle
            $w = [int]$rect.Width
            $h = [int]$rect.Height
            if ($w -le 2 -or $h -le 2) { return }
            $e.Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            # soft fill
            $fillRect = New-Object System.Drawing.Rectangle(1, 1, [int][Math]::Max(1, ($w - 2)), [int][Math]::Max(1, ($h - 2)))
            $fb = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
                $fillRect, (Color $script:Theme.Surface), (Color $script:Theme.BgDeep),
                [System.Drawing.Drawing2D.LinearGradientMode]::Vertical)
            try { $e.Graphics.FillRectangle($fb, $fillRect) } finally { $fb.Dispose() }
            # top accent stripe
            $stripe = New-Object System.Drawing.Rectangle(1, 1, [int][Math]::Max(1, ($w - 2)), 3)
            $sb = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
                $stripe, (Color $script:Theme.Accent), (Color $script:Theme.Cyan),
                [System.Drawing.Drawing2D.LinearGradientMode]::Horizontal)
            try { $e.Graphics.FillRectangle($sb, $stripe) } finally { $sb.Dispose() }
            # border
            $top = Color $script:Theme.BorderLight
            $bot = Color $script:Theme.Border
            $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
                $rect, $top, $bot, [System.Drawing.Drawing2D.LinearGradientMode]::Vertical)
            try {
                $pen = New-Object System.Drawing.Pen($brush, 1)
                try {
                    $r = New-Object System.Drawing.Rectangle(0, 0, [int][Math]::Max(1, ($w - 1)), [int][Math]::Max(1, ($h - 1)))
                    $e.Graphics.DrawRectangle($pen, $r)
                } finally { $pen.Dispose() }
            } finally { $brush.Dispose() }
        } catch { }
    })
    $Parent.Controls.Add($panel)
    if ($Title) {
        [void](New-UILabel -Parent $panel -Text $Title.ToUpper() -X 16 -Y 12 `
            -W ($W - 32) -H 20 -Size 8.5 -Color $script:Theme.Muted -Bold $true)
    }
    return $panel
}

function New-UITextBox {
    param($Parent, [string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H,
        [bool]$Multiline = $false, [bool]$ReadOnly = $false)
    $box = New-Object System.Windows.Forms.TextBox
    $box.Text = $Text
    $box.Location = New-Object System.Drawing.Point -ArgumentList @($X, $Y)
    $box.Size = New-Object System.Drawing.Size -ArgumentList @($W, $H)
    $box.BackColor = Color $script:Theme.Surface2
    $box.ForeColor = Color $script:Theme.Text
    $box.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $box.Font = New-Object System.Drawing.Font -ArgumentList @('Segoe UI', 9.5)
    $box.Multiline = $Multiline
    $box.ReadOnly = $ReadOnly
    if ($Multiline) { $box.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical }
    $Parent.Controls.Add($box)
    return $box
}

function New-UICheckBox {
    param($Parent, [string]$Text, [int]$X, [int]$Y, [int]$W = 0, [bool]$Checked = $false)
    $box = New-Object System.Windows.Forms.CheckBox
    $box.Text = $Text
    $box.Location = New-Object System.Drawing.Point -ArgumentList @($X, $Y)
    if ($W -gt 0) { $box.Size = New-Object System.Drawing.Size -ArgumentList @($W, 24) }
    else { $box.AutoSize = $true }
    $box.ForeColor = Color $script:Theme.Text
    $box.BackColor = [System.Drawing.Color]::Transparent
    $box.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $box.Font = New-Object System.Drawing.Font -ArgumentList @('Segoe UI', 9.5)
    $box.Checked = $Checked
    $Parent.Controls.Add($box)
    return $box
}

function New-UICombo {
    param($Parent, [string[]]$Items, [int]$X, [int]$Y, [int]$W, [int]$H = 26)
    $combo = New-Object System.Windows.Forms.ComboBox
    $combo.Location = New-Object System.Drawing.Point -ArgumentList @($X, $Y)
    $combo.Size = New-Object System.Drawing.Size -ArgumentList @($W, $H)
    $combo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $combo.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $combo.BackColor = Color $script:Theme.Surface2
    $combo.ForeColor = Color $script:Theme.Text
    $combo.Font = New-Object System.Drawing.Font -ArgumentList @('Segoe UI', 9.5)
    [void]$combo.Items.AddRange([object[]]$Items)
    if ($combo.Items.Count -gt 0) { $combo.SelectedIndex = 0 }
    $Parent.Controls.Add($combo)
    return $combo
}

function Set-Pill {
    param($Label, [string]$Text, [string]$State)
    $Label.Text = $Text
    $Label.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    switch ($State) {
        'ok'   { $Label.BackColor = Color $script:Theme.GreenDark; $Label.ForeColor = Color $script:Theme.White }
        'warn' { $Label.BackColor = Color $script:Theme.YellowDark; $Label.ForeColor = Color $script:Theme.White }
        'off'  { $Label.BackColor = Color $script:Theme.RedDark; $Label.ForeColor = Color $script:Theme.White }
        default { $Label.BackColor = Color $script:Theme.Surface3; $Label.ForeColor = Color $script:Theme.White }
    }
}

# --------------------------------------------------------------------------
#  Настройки окна (размер, позиция, вкладка, трей)
# --------------------------------------------------------------------------

$script:SettingsFile = Join-Path $script:ProxyDir 'gui-settings.json'
$script:Settings = [pscustomobject]@{
    Width          = 1120
    Height         = 760
    Left           = -1
    Top            = -1
    Tab            = 'overview'
    MinimizeToTray = $false
    AutoCheckAppUpdates = $true
    HotkeyToggleZapret  = $true
}
$script:CurrentTab = 'overview'

function Test-SaneGeometry([int]$width, [int]$height, [int]$left, [int]$top) {
    if ($width -lt 800 -or $width -gt 20000) { return $false }
    if ($height -lt 500 -or $height -gt 20000) { return $false }
    if ($left -lt 0 -or $top -lt 0) { return $false }
    if ($left -gt 20000 -or $top -gt 20000) { return $false }
    return (Test-OnScreen $left $top)
}

function Read-GuiSettings {
    if (-not (Test-Path -LiteralPath $script:SettingsFile)) { return }
    try {
        $obj = Get-Content -LiteralPath $script:SettingsFile -Raw -ErrorAction Stop |
            ConvertFrom-Json
        if ($obj.Tab) { $script:Settings.Tab = [string]$obj.Tab }
        $script:Settings.MinimizeToTray = [bool]$obj.MinimizeToTray
        if ($null -ne $obj.AutoCheckAppUpdates) { $script:Settings.AutoCheckAppUpdates = [bool]$obj.AutoCheckAppUpdates } else { $script:Settings.AutoCheckAppUpdates = $true }
        if ($null -ne $obj.HotkeyToggleZapret) { $script:Settings.HotkeyToggleZapret = [bool]$obj.HotkeyToggleZapret } else { $script:Settings.HotkeyToggleZapret = $true }


        $width = if ($null -ne $obj.Width) { [int]$obj.Width } else { 0 }
        $height = if ($null -ne $obj.Height) { [int]$obj.Height } else { 0 }
        $left = if ($null -ne $obj.Left) { [int]$obj.Left } else { -1 }
        $top = if ($null -ne $obj.Top) { [int]$obj.Top } else { -1 }

        if ($width -ge 800 -and $width -le 20000) { $script:Settings.Width = $width }
        if ($height -ge 500 -and $height -le 20000) { $script:Settings.Height = $height }
        if (Test-SaneGeometry $width $height $left $top) {
            $script:Settings.Left = $left
            $script:Settings.Top = $top
        } else {
            $script:Settings.Left = -1
            $script:Settings.Top = -1
        }

        # Битые размеры (например, сохранённые у свёрнутого окна) — чиним файл.
        $badSize = ($width -lt 800 -or $width -gt 20000 -or
            $height -lt 500 -or $height -gt 20000)
        $badPos = ($script:Settings.Left -lt 0 -or $script:Settings.Top -lt 0)
        if (-not $UiTest -and ($badSize -or $badPos)) {
            $repair = [ordered]@{
                Width          = [int]$script:Settings.Width
                Height         = [int]$script:Settings.Height
                Left           = [int]$script:Settings.Left
                Top            = [int]$script:Settings.Top
                Tab            = $script:Settings.Tab
                MinimizeToTray = [bool]$script:Settings.MinimizeToTray
                AutoCheckAppUpdates = [bool]$script:Settings.AutoCheckAppUpdates
                HotkeyToggleZapret  = [bool]$script:Settings.HotkeyToggleZapret
            }
            ($repair | ConvertTo-Json) |
                Set-Content -LiteralPath $script:SettingsFile -Encoding UTF8
        }
    } catch { }
}

function Save-GuiSettings {
    if ($UiTest) { return }
    try {
        $data = [ordered]@{
            Width          = [int]$script:Settings.Width
            Height         = [int]$script:Settings.Height
            Left           = [int]$script:Settings.Left
            Top            = [int]$script:Settings.Top
            Tab            = $script:CurrentTab
            MinimizeToTray = [bool]$script:Settings.MinimizeToTray
            AutoCheckAppUpdates = [bool]$script:Settings.AutoCheckAppUpdates
            HotkeyToggleZapret  = [bool]$script:Settings.HotkeyToggleZapret
        }
        # У свёрнутого/скрытого окна Width/Left бессмысленны (160x28, -32000),
        # поэтому берём RestoreBounds, а при сомнительных значениях — не пишем их.
        $bounds = $null
        try {
            if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Normal) {
                $bounds = $form.Bounds
            } else {
                $restore = $form.RestoreBounds
                if ($restore -and $restore.Width -gt 0 -and $restore.Height -gt 0) {
                    $bounds = $restore
                }
            }
        } catch { }
        if ($bounds -and (Test-SaneGeometry $bounds.Width $bounds.Height $bounds.Left $bounds.Top)) {
            $data.Width = [int]$bounds.Width
            $data.Height = [int]$bounds.Height
            $data.Left = [int]$bounds.Left
            $data.Top = [int]$bounds.Top
            $script:Settings.Width = [int]$bounds.Width
            $script:Settings.Height = [int]$bounds.Height
            $script:Settings.Left = [int]$bounds.Left
            $script:Settings.Top = [int]$bounds.Top
        }
        ($data | ConvertTo-Json) |
            Set-Content -LiteralPath $script:SettingsFile -Encoding UTF8
    } catch { }
}

function Test-OnScreen([int]$x, [int]$y) {
    try {
        foreach ($screen in [System.Windows.Forms.Screen]::AllScreens) {
            $area = $screen.WorkingArea
            if ($x -ge $area.Left -and $y -ge $area.Top -and
                $x -lt $area.Right -and $y -lt $area.Bottom) {
                return $true
            }
        }
    } catch { }
    return $false
}

Read-GuiSettings

# --------------------------------------------------------------------------
#  Форма
# --------------------------------------------------------------------------

$form = New-Object System.Windows.Forms.Form
$form.Text = 'ZAPRET CONTROL - LAN proxy и тесты'
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.Size = New-Object System.Drawing.Size -ArgumentList @(1120, 760)
$form.MinimumSize = New-Object System.Drawing.Size -ArgumentList @(1080, 660)
if (-not $UiTest) {
    $form.Size = New-Object System.Drawing.Size -ArgumentList @(
        [Math]::Max(1080, [int]$script:Settings.Width),
        [Math]::Max(660, [int]$script:Settings.Height))
    if ($script:Settings.Left -ge 0 -and $script:Settings.Top -ge 0 -and
        (Test-OnScreen ([int]$script:Settings.Left) ([int]$script:Settings.Top))) {
        $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
        $form.Location = New-Object System.Drawing.Point -ArgumentList @(
            [int]$script:Settings.Left, [int]$script:Settings.Top)
    }
}
$form.BackColor = Color $script:Theme.Bg
$form.ForeColor = Color $script:Theme.Text
$form.Font = New-Object System.Drawing.Font -ArgumentList @('Segoe UI', 9.5)
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
try {
    $iconPath = Join-Path $script:BindDir 'winws.exe'
    if (Test-Path -LiteralPath $iconPath) {
        $form.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($iconPath)
    }
} catch { }

# --- header ---
$header = New-Object System.Windows.Forms.Panel
$header.Dock = [System.Windows.Forms.DockStyle]::Top
$header.Height = 98
$header.BackColor = Color $script:Theme.Surface
$header.Add_Paint({
    param($sender, $e)
    try {
        $rect = $sender.ClientRectangle
        $w = [int]$rect.Width
        $h = [int]$rect.Height
        if ($w -le 0 -or $h -le 0) { return }
        $c1 = [System.Drawing.Color]::FromArgb(255, 18, 30, 50)
        $c2 = [System.Drawing.Color]::FromArgb(255, 7, 11, 18)
        $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
            $rect, $c1, $c2, [System.Drawing.Drawing2D.LinearGradientMode]::Horizontal)
        try { $e.Graphics.FillRectangle($brush, $rect) } finally { $brush.Dispose() }
        # accent glow strip at bottom
        $accentRect = New-Object System.Drawing.Rectangle(0, [int][Math]::Max(0, ($h - 3)), $w, 3)
        $ab = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
            $accentRect, (Color $script:Theme.Accent), (Color $script:Theme.Cyan),
            [System.Drawing.Drawing2D.LinearGradientMode]::Horizontal)
        try { $e.Graphics.FillRectangle($ab, $accentRect) } finally { $ab.Dispose() }
        $line = New-Object System.Drawing.Pen((Color $script:Theme.BorderLight), 1)
        try { $e.Graphics.DrawLine($line, 0, [int]($h - 1), $w, [int]($h - 1)) } finally { $line.Dispose() }
    } catch { }
})
$form.Controls.Add($header)

$accent = New-Object System.Windows.Forms.Panel
$accent.Dock = [System.Windows.Forms.DockStyle]::Left
$accent.Width = 5
$accent.BackColor = [System.Drawing.Color]::Transparent
$accent.Add_Paint({
    param($sender, $e)
    try {
        $rect = $sender.ClientRectangle
        if ([int]$rect.Width -le 0 -or [int]$rect.Height -le 0) { return }
        $b = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
            $rect, (Color $script:Theme.Green), (Color $script:Theme.Accent),
            [System.Drawing.Drawing2D.LinearGradientMode]::Vertical)
        try { $e.Graphics.FillRectangle($b, $rect) } finally { $b.Dispose() }
    } catch { }
})
$header.Controls.Add($accent)

[void](New-UILabel -Parent $header -Text 'ZAPRET CONTROL' -X 28 -Y 14 -W 460 -H 40 `
    -Size 22 -Color $script:Theme.White -Bold $true)
[void](New-UILabel -Parent $header -Text 'LAN-прокси · DPI-обход · тесты стратегий · автообновление' `
    -X 30 -Y 54 -W 600 -H 24 -Size 10.5 -Color $script:Theme.Cyan)

$script:PillAdmin = New-UILabel -Parent $header -Text 'АДМИН: ...' -X 840 -Y 26 -W 110 -H 30 `
    -Size 9 -Color $script:Theme.White -Bold $true -Align 'MiddleCenter'
$script:PillAdmin.BackColor = Color $script:Theme.Surface3
$script:PillZapret = New-UILabel -Parent $header -Text 'ZAPRET: ...' -X 958 -Y 26 -W 120 -H 30 `
    -Size 9 -Color $script:Theme.White -Bold $true -Align 'MiddleCenter'
$script:PillZapret.BackColor = Color $script:Theme.Surface3
$script:PillProxy = New-UILabel -Parent $header -Text 'ПРОКСИ: ...' -X 840 -Y 60 -W 110 -H 24 `
    -Size 8.5 -Color $script:Theme.White -Bold $true -Align 'MiddleCenter'
$script:PillProxy.BackColor = Color $script:Theme.Surface3
$script:PillTasks = New-UILabel -Parent $header -Text 'АВТОЗАПУСК: ...' -X 958 -Y 60 -W 120 -H 24 `
    -Size 8.5 -Color $script:Theme.White -Bold $true -Align 'MiddleCenter'
$script:PillTasks.BackColor = Color $script:Theme.Surface3

# Индикаторы прижимаем к правому краю при изменении размера окна.
foreach ($pill in @($script:PillAdmin, $script:PillZapret, $script:PillProxy, $script:PillTasks)) {
    $pill.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor
        [System.Windows.Forms.AnchorStyles]::Right
}

# --- sidebar ---
$sidebar = New-Object System.Windows.Forms.Panel
$sidebar.Dock = [System.Windows.Forms.DockStyle]::Left
$sidebar.Width = 214
$sidebar.BackColor = Color $script:Theme.Surface
$sidebar.Add_Paint({
    param($sender, $e)
    try {
        $rect = $sender.ClientRectangle
        $w = [int]$rect.Width
        $h = [int]$rect.Height
        if ($w -le 0 -or $h -le 0) { return }
        $c1 = [System.Drawing.Color]::FromArgb(255, 10, 16, 28)
        $c2 = [System.Drawing.Color]::FromArgb(255, 16, 24, 39)
        $b = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
            $rect, $c1, $c2, [System.Drawing.Drawing2D.LinearGradientMode]::Vertical)
        try { $e.Graphics.FillRectangle($b, $rect) } finally { $b.Dispose() }
        $pen = New-Object System.Drawing.Pen((Color $script:Theme.BorderLight), 1)
        try { $e.Graphics.DrawLine($pen, [int]($w - 1), 0, [int]($w - 1), $h) } finally { $pen.Dispose() }
    } catch { }
})
$form.Controls.Add($sidebar)

$navNames = @(
    @{ Key = 'overview'; Text = '  ◆  Обзор' },
    @{ Key = 'proxy';    Text = '  ◈  Прокси' },
    @{ Key = 'zapret';   Text = '  ◉  Zapret' },
    @{ Key = 'tests';    Text = '  ◇  Тесты' },
    @{ Key = 'updates';  Text = '  ⇩  Обновления' },
    @{ Key = 'logs';     Text = '  ▤  Журналы' },
    @{ Key = 'tools';    Text = '  ✦  Инструменты' }
)
$script:NavButtons = @{}
$script:NavAccents = @{}
$navY = 24
foreach ($nav in $navNames) {
    $key = $nav.Key
    $accentBar = New-Object System.Windows.Forms.Panel
    $accentBar.Location = New-Object System.Drawing.Point -ArgumentList @(8, ($navY + 6))
    $accentBar.Size = New-Object System.Drawing.Size -ArgumentList @(4, 30)
    $accentBar.BackColor = [System.Drawing.Color]::Transparent
    $accentBar.Visible = $false
    $sidebar.Controls.Add($accentBar)
    $script:NavAccents[$key] = $accentBar
    $button = New-UIButton -Parent $sidebar -Text $nav.Text -X 18 -Y $navY -W 182 -H 42 `
        -Back $script:Theme.Surface -Fore $script:Theme.Muted -OnClick {
            Switch-Tab $key
        }.GetNewClosure()
    $button.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $button.Padding = New-Object System.Windows.Forms.Padding -ArgumentList @(12, 0, 0, 0)
    $button.FlatAppearance.BorderSize = 0
    $script:NavButtons[$key] = $button
    $navY += 52
}

$sideVerCard = New-UICard -Parent $sidebar -X 14 -Y 504 -W 186 -H 66
[void](New-UILabel -Parent $sideVerCard -Text 'ZAPRET CONTROL' -X 12 -Y 10 -W 160 -H 18 `
    -Size 8 -Color $script:Theme.Accent -Bold $true)
[void](New-UILabel -Parent $sideVerCard -Text 'Версия 1.12.12' -X 12 -Y 30 -W 160 -H 22 `
    -Size 10.5 -Color $script:Theme.White -Bold $true)

# --- status bar ---
$statusBar = New-Object System.Windows.Forms.Panel
$statusBar.Dock = [System.Windows.Forms.DockStyle]::Bottom
$statusBar.Height = 32
$statusBar.BackColor = Color $script:Theme.Surface2
$statusBar.Add_Paint({
    param($sender, $e)
    try {
        $rect = $sender.ClientRectangle
        $w = [int]$rect.Width
        $h = [int]$rect.Height
        if ($w -le 0 -or $h -le 0) { return }
        $b = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
            $rect, (Color $script:Theme.Surface2), (Color $script:Theme.BgDeep),
            [System.Drawing.Drawing2D.LinearGradientMode]::Horizontal)
        try { $e.Graphics.FillRectangle($b, $rect) } finally { $b.Dispose() }
        $pen = New-Object System.Drawing.Pen((Color $script:Theme.BorderLight), 1)
        try { $e.Graphics.DrawLine($pen, 0, 0, $w, 0) } finally { $pen.Dispose() }
    } catch { }
})
$form.Controls.Add($statusBar)
$script:StatusAdmin = New-UILabel -Parent $statusBar -Text 'Админ: ...' -X 12 -Y 5 -W 140 -H 20 `
    -Size 8.5 -Color $script:Theme.Muted
$script:StatusPython = New-UILabel -Parent $statusBar -Text 'Python: ...' -X 145 -Y 5 -W 230 -H 20 `
    -Size 8.5 -Color $script:Theme.Muted
$script:StatusTests = New-UILabel -Parent $statusBar -Text 'Тесты: нет' -X 338 -Y 5 -W 180 -H 20 `
    -Size 8.5 -Color $script:Theme.Muted
$script:StatusPath = New-UILabel -Parent $statusBar -Text $script:RootDir -X 526 -Y 5 -W 360 -H 20 `
    -Size 8.5 -Color $script:Theme.Muted -Align 'MiddleRight'

# --- content ---
$content = New-Object System.Windows.Forms.Panel
$content.Dock = [System.Windows.Forms.DockStyle]::Fill
$content.BackColor = Color $script:Theme.Bg
$form.Controls.Add($content)

$script:Tabs = @{}
foreach ($key in @('overview', 'proxy', 'zapret', 'tests', 'updates', 'logs', 'tools')) {
    $panel = New-Object System.Windows.Forms.Panel
    $panel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $panel.BackColor = Color $script:Theme.Bg
    $panel.Visible = $false
    $content.Controls.Add($panel)
    $script:Tabs[$key] = $panel
}

function Switch-Tab([string]$key) {
    $script:CurrentTab = $key
    foreach ($k in $script:Tabs.Keys) {
        $script:Tabs[$k].Visible = ($k -eq $key)
        if ($script:NavButtons.ContainsKey($k)) {
            if ($k -eq $key) {
                $script:NavButtons[$k].BackColor = Color $script:Theme.SurfaceHi
                $script:NavButtons[$k].ForeColor = Color $script:Theme.White
                $script:NavButtons[$k].FlatAppearance.BorderSize = 1
                $script:NavButtons[$k].FlatAppearance.BorderColor = Color $script:Theme.Accent
            } else {
                $script:NavButtons[$k].BackColor = Color $script:Theme.Surface
                $script:NavButtons[$k].ForeColor = Color $script:Theme.Muted
                $script:NavButtons[$k].FlatAppearance.BorderSize = 0
                $script:NavButtons[$k].FlatAppearance.BorderColor = Color $script:Theme.Surface
            }
        }
        if ($script:NavAccents -and $script:NavAccents.ContainsKey($k)) {
            $script:NavAccents[$k].Visible = ($k -eq $key)
            $script:NavAccents[$k].BackColor = Color $script:Theme.Accent
        }
    }
    if ($key -eq 'logs') { Update-LogView }
    if ($key -eq 'tests') { Update-LatestResult; try { if ($script:TestChart) { $script:TestChart.Invalidate() } } catch { } }
    if ($key -eq 'zapret') { Update-IpsetStatus; Load-GameFilterUI }
    if ($key -eq 'updates') { try { Update-UpdatesTabFromObject -obj $script:LatestAppUpdate } catch { } }
}

# --------------------------------------------------------------------------
#  Обзор
# --------------------------------------------------------------------------

$ov = $script:Tabs['overview']

$cardTable = New-Object System.Windows.Forms.TableLayoutPanel
$cardTable.Dock = [System.Windows.Forms.DockStyle]::Top
$cardTable.Height = 142
$cardTable.ColumnCount = 4
$cardTable.RowCount = 1
$cardTable.Padding = New-Object System.Windows.Forms.Padding -ArgumentList @(8, 8, 8, 0)
for ($i = 0; $i -lt 4; $i++) {
    [void]$cardTable.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle(
        [System.Windows.Forms.SizeType]::Percent, 25)))
}
[void]$cardTable.RowStyles.Add((New-Object System.Windows.Forms.RowStyle(
    [System.Windows.Forms.SizeType]::Percent, 100)))
$ov.Controls.Add($cardTable)

$cardSpecs = @(
    @{ Key = 'proxy';  Title = 'ПРОКСИ' },
    @{ Key = 'zapret'; Title = 'ZAPRET' },
    @{ Key = 'strategy'; Title = 'СТРАТЕГИЯ' },
    @{ Key = 'tasks';  Title = 'АВТОЗАПУСК' }
)
$script:OvValues = @{}
$script:OvDetails = @{}
foreach ($spec in $cardSpecs) {
    $card = New-UICard -Parent $cardTable -X 0 -Y 0 -W 240 -H 120 -Title $spec.Title
    $card.Dock = [System.Windows.Forms.DockStyle]::Fill
    $card.Margin = New-Object System.Windows.Forms.Padding -ArgumentList @(6, 0, 6, 0)
    $value = New-UILabel -Parent $card -Text '—' -X 16 -Y 38 -W 208 -H 34 `
        -Size 17 -Color $script:Theme.Text -Bold $true
    $detail = New-UILabel -Parent $card -Text '' -X 16 -Y 76 -W 208 -H 30 `
        -Size 8.5 -Color $script:Theme.Muted
    $script:OvValues[$spec.Key] = $value
    $script:OvDetails[$spec.Key] = $detail
}

$quick = New-Object System.Windows.Forms.FlowLayoutPanel
$quick.Dock = [System.Windows.Forms.DockStyle]::Top
$quick.Height = 108
$quick.Padding = New-Object System.Windows.Forms.Padding -ArgumentList @(14, 8, 14, 0)
$quick.WrapContents = $true
$ov.Controls.Add($quick)

[void](New-UIButton -Parent $quick -Text 'Запустить всё' -X 0 -Y 0 -W 150 -H 40 `
    -Back $script:Theme.Green -OnClick { Invoke-VisibleBat (Join-Path $script:ProxyDir 'start-all.bat') })
[void](New-UIButton -Parent $quick -Text 'Остановить всё' -X 0 -Y 0 -W 150 -H 40 `
    -Back $script:Theme.Red -OnClick { Invoke-VisibleBat (Join-Path $script:ProxyDir 'stop-all.bat') })
[void](New-UIButton -Parent $quick -Text 'Перезапустить' -X 0 -Y 0 -W 150 -H 40 `
    -Back $script:Theme.Blue -OnClick { Invoke-VisibleBat (Join-Path $script:ProxyDir 'restart-all.bat') })
[void](New-UIButton -Parent $quick -Text 'Показать адрес' -X 0 -Y 0 -W 150 -H 40 `
    -Back $script:Theme.Surface3 -OnClick {
        $ip = Get-LanIp
        $text = "HTTP-прокси:  $ip`:8080`r`nSOCKS5:       $ip`:1080"
        [Windows.Forms.Clipboard]::SetText("$ip`:8080`r`n$ip`:1080")
        [Windows.Forms.MessageBox]::Show("$text`n`nСкопировано в буфер обмена.", 'Адрес прокси',
            'OK', 'Information') | Out-Null
    })
[void](New-UIButton -Parent $quick -Text 'Открыть proxy.log' -X 0 -Y 0 -W 170 -H 40 `
    -Back $script:Theme.Surface3 -OnClick {
        Start-Process -FilePath 'notepad.exe' -ArgumentList "`"$(Join-Path $script:ProxyDir 'proxy.log')`""
    })
[void](New-UIButton -Parent $quick -Text 'Проверить соединение' -X 0 -Y 0 -W 190 -H 40 `
    -Back $script:Theme.Cyan -Fore $script:Theme.Bg -OnClick { Show-ConnectionTest })
[void](New-UIButton -Parent $quick -Text 'Вкл/Выкл обход (Ctrl+Alt+Z)' -X 0 -Y 0 -W 230 -H 40 `
    -Back $script:Theme.Accent -OnClick { Toggle-ZapretBypass })

$ovInfo = New-UICard -Parent $ov -X 14 -Y 218 -W 850 -H 190 -Title 'СОСТОЯНИЕ И ПОДСКАЗКА'
$ovInfo.Dock = [System.Windows.Forms.DockStyle]::Fill
$ovInfo.Margin = New-Object System.Windows.Forms.Padding -ArgumentList @(14, 8, 14, 14)
$script:OvSummary = New-UILabel -Parent $ovInfo -Text '' -X 16 -Y 40 -W 800 -H 60 `
    -Size 9.5 -Color $script:Theme.Cyan
$script:OvInfoText = New-UILabel -Parent $ovInfo -Text '' -X 16 -Y 108 -W 420 -H 180 `
    -Size 9.5 -Color $script:Theme.Text
$script:OvInfoText.Text = @(
    '1. Нажмите «Запустить всё» — установятся задачи автозапуска, правила брандмауэра,',
    '   включится LAN-прокси и zapret (выбранная стратегия).',
    '2. На телефоне/ТВ укажите HTTP-прокси: IP этого ПК, порт 8080 (или SOCKS5 :1080).',
    '3. Если сайт не открывается — откройте «Тесты» и запустите DPI-тесты, затем выберите',
    '   лучшую стратегию на вкладке «Zapret».',
    '4. Для Mac: автономный клиент в папке macos\ (локальный режим) или LAN через этот ПК.',
    '5. Все журналы и диагностика — на вкладках «Журналы» и «Инструменты».'
) -join "`r`n"

$script:OverviewChart = New-Object System.Windows.Forms.Panel
$script:OverviewChart.Location = New-Object System.Drawing.Point -ArgumentList @(450, 108)
$script:OverviewChart.Size = New-Object System.Drawing.Size -ArgumentList @(380, 200)
$script:OverviewChart.BackColor = Color $script:Theme.Surface
$script:OverviewChart.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor
    [System.Windows.Forms.AnchorStyles]::Left -bor
    [System.Windows.Forms.AnchorStyles]::Right -bor
    [System.Windows.Forms.AnchorStyles]::Bottom
$script:OverviewChart.Add_Paint({
    param($sender, $e)
    try { Draw-ResultsChart -sender $sender -e $e -data $script:TestChartData -maxItems 6 -compact $true } catch { }
})
$ovInfo.Controls.Add($script:OverviewChart)

# Порядок докинга: Fill (0) прокладывается последним, затем верхние панели
# снизу вверх (больший индекс = выше на экране).
$ov.Controls.SetChildIndex($ovInfo, 0)
$ov.Controls.SetChildIndex($quick, 1)
$ov.Controls.SetChildIndex($cardTable, 2)

# --------------------------------------------------------------------------
#  Прокси
# --------------------------------------------------------------------------

$px = $script:Tabs['proxy']
$pxTable = New-Object System.Windows.Forms.TableLayoutPanel
$pxTable.Dock = [System.Windows.Forms.DockStyle]::Fill
$pxTable.ColumnCount = 2
$pxTable.RowCount = 1
$pxTable.Padding = New-Object System.Windows.Forms.Padding -ArgumentList @(10, 10, 10, 10)
[void]$pxTable.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle(
    [System.Windows.Forms.SizeType]::Percent, 50)))
[void]$pxTable.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle(
    [System.Windows.Forms.SizeType]::Percent, 50)))
[void]$pxTable.RowStyles.Add((New-Object System.Windows.Forms.RowStyle(
    [System.Windows.Forms.SizeType]::Percent, 100)))
$px.Controls.Add($pxTable)

$pxLeft = New-UICard -Parent $pxTable -X 0 -Y 0 -W 400 -H 500 -Title 'ПОДКЛЮЧЕНИЕ УСТРОЙСТВ'
$pxLeft.Dock = [System.Windows.Forms.DockStyle]::Fill
$pxLeft.Margin = New-Object System.Windows.Forms.Padding -ArgumentList @(6, 0, 6, 0)
$script:PxLan = New-UILabel -Parent $pxLeft -Text 'LAN IP: ...' -X 16 -Y 42 -W 380 -H 26 `
    -Size 12 -Color $script:Theme.Cyan -Bold $true
$script:PxHttp = New-UILabel -Parent $pxLeft -Text 'HTTP: ...' -X 16 -Y 84 -W 380 -H 24 `
    -Size 11 -Color $script:Theme.Text
$script:PxSocks = New-UILabel -Parent $pxLeft -Text 'SOCKS5: ...' -X 16 -Y 112 -W 380 -H 24 `
    -Size 11 -Color $script:Theme.Text
[void](New-UIButton -Parent $pxLeft -Text 'Копировать адреса' -X 16 -Y 152 -W 118 -H 36 `
    -Back $script:Theme.Blue -OnClick {
        $ip = Get-LanIp
        [Windows.Forms.Clipboard]::SetText("$ip`:8080`r`n$ip`:1080")
        [Windows.Forms.MessageBox]::Show('Адреса скопированы в буфер обмена.', 'Прокси',
            'OK', 'Information') | Out-Null
    })
[void](New-UIButton -Parent $pxLeft -Text 'Показать IP' -X 142 -Y 152 -W 108 -H 36 `
    -Back $script:Theme.Surface3 -OnClick {
        Invoke-VisibleBat (Join-Path $script:ProxyDir 'show-lan-ip.bat')
    })
[void](New-UIButton -Parent $pxLeft -Text 'Проверить' -X 258 -Y 152 -W 126 -H 36 `
    -Back $script:Theme.Cyan -Fore $script:Theme.Bg -OnClick { Start-ConnectionTest })

$script:PxHealth = New-UILabel -Parent $pxLeft -Text 'Health: ...' -X 16 -Y 198 -W 368 -H 62 `
    -Size 9 -Color $script:Theme.Muted
[void](New-UILabel -Parent $pxLeft -Text 'ПРОВЕРКА СОЕДИНЕНИЯ' -X 16 -Y 266 -W 300 -H 18 `
    -Size 8.5 -Color $script:Theme.Muted -Bold $true)
$script:ConnBox = New-UITextBox -Parent $pxLeft -Text '' -X 16 -Y 288 -W 368 -H 154 `
    -Multiline $true -ReadOnly $true
$script:ConnBox.Font = New-Object System.Drawing.Font -ArgumentList @('Consolas', 8.5)
$script:ConnBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
$script:PxHint = New-UILabel -Parent $pxLeft -Text '' -X 16 -Y 450 -W 368 -H 72 `
    -Size 8.5 -Color $script:Theme.Muted
$script:PxHint.Text = @(
    'Android/iOS: Wi-Fi → Прокси → Вручную → HTTP :8080.',
    'Windows: системный прокси или SOCKS5 :1080.',
    'macOS: клиент в папке macos\ (локальный режим без Windows) — см. Инструменты.',
    'DoH уже встроен в прокси — на устройстве не нужен.'
) -join "`r`n"

$pxRight = New-UICard -Parent $pxTable -X 0 -Y 0 -W 400 -H 500 -Title 'УПРАВЛЕНИЕ'
$pxRight.Dock = [System.Windows.Forms.DockStyle]::Fill
$pxRight.Margin = New-Object System.Windows.Forms.Padding -ArgumentList @(6, 0, 6, 0)
[void](New-UIButton -Parent $pxRight -Text 'Запустить всё' -X 16 -Y 42 -W 170 -H 38 `
    -Back $script:Theme.Green -OnClick { Invoke-VisibleBat (Join-Path $script:ProxyDir 'start-all.bat') })
[void](New-UIButton -Parent $pxRight -Text 'Остановить всё' -X 196 -Y 42 -W 170 -H 38 `
    -Back $script:Theme.Red -OnClick { Invoke-VisibleBat (Join-Path $script:ProxyDir 'stop-all.bat') })
[void](New-UIButton -Parent $pxRight -Text 'Перезапустить прокси' -X 16 -Y 88 -W 170 -H 38 `
    -Back $script:Theme.Blue -OnClick { Restart-ProxyNow })
[void](New-UIButton -Parent $pxRight -Text 'Перезапустить всё' -X 196 -Y 88 -W 170 -H 38 `
    -Back $script:Theme.Surface3 -OnClick { Invoke-VisibleBat (Join-Path $script:ProxyDir 'restart-all.bat') })
[void](New-UIButton -Parent $pxRight -Text 'Включить zapret' -X 16 -Y 134 -W 170 -H 38 `
    -Back $script:Theme.Surface3 -OnClick { Invoke-VisibleBat (Join-Path $script:ProxyDir 'zapret-start.bat') })
[void](New-UIButton -Parent $pxRight -Text 'Выключить zapret' -X 196 -Y 134 -W 170 -H 38 `
    -Back $script:Theme.Surface3 -OnClick { Invoke-VisibleBat (Join-Path $script:ProxyDir 'zapret-stop.bat') })

$script:PxTasks = New-UILabel -Parent $pxRight -Text 'Задачи: ...' -X 16 -Y 184 -W 368 -H 36 `
    -Size 9 -Color $script:Theme.Muted

[void](New-UIButton -Parent $pxRight -Text 'Проверить' -X 16 -Y 224 -W 112 -H 34 `
    -Back $script:Theme.Surface3 -OnClick {
        $script:CachedTasks = $null
        Update-Status
    })
[void](New-UIButton -Parent $pxRight -Text 'Запустить' -X 136 -Y 224 -W 112 -H 34 `
    -Back $script:Theme.Green -OnClick { Invoke-AllTasks 'Run' })
[void](New-UIButton -Parent $pxRight -Text 'Остановить' -X 256 -Y 224 -W 128 -H 34 `
    -Back $script:Theme.Red -OnClick { Invoke-AllTasks 'End' })

[void](New-UIButton -Parent $pxRight -Text 'Установить / обновить автозапуск' -X 16 -Y 268 -W 350 -H 36 `
    -Back $script:Theme.Blue -OnClick { Install-Autostart })
[void](New-UIButton -Parent $pxRight -Text 'Удалить задачи автозапуска' -X 16 -Y 310 -W 350 -H 36 `
    -Back $script:Theme.Surface3 -OnClick {
        $answer = [Windows.Forms.MessageBox]::Show(
            'Удалить задачи zapret-proxy, zapret-proxy-watchdog и zapret-max?',
            'Автозапуск', 'YesNo', 'Question')
        if ($answer -eq 'Yes') {
            foreach ($task in @('zapret-proxy', 'zapret-proxy-watchdog', 'zapret-max')) {
                schtasks /End /TN $task | Out-Null
                schtasks /Delete /TN $task /F | Out-Null
            }
            $script:CachedTasks = $null
            Update-Status
        }
    })
[void](New-UIButton -Parent $pxRight -Text 'Починить DNS (DoH)' -X 16 -Y 352 -W 170 -H 36 `
    -Back $script:Theme.Surface3 -OnClick { Invoke-VisibleBat (Join-Path $script:ProxyDir 'fix-dns.bat') })
[void](New-UIButton -Parent $pxRight -Text 'Почистить hosts' -X 196 -Y 352 -W 170 -H 36 `
    -Back $script:Theme.Surface3 -OnClick {
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $script:ProxyDir 'fix-hosts.ps1') 2>&1
        [Windows.Forms.MessageBox]::Show(($out | Out-String), 'Hosts', 'OK', 'Information') | Out-Null
    })
[void](New-UIButton -Parent $pxRight -Text 'Открыть журнал' -X 16 -Y 398 -W 170 -H 36 `
    -Back $script:Theme.Surface3 -OnClick {
        Start-Process -FilePath 'notepad.exe' -ArgumentList "`"$(Join-Path $script:ProxyDir 'proxy.log')`""
    })
[void](New-UIButton -Parent $pxRight -Text 'Полное удаление' -X 196 -Y 398 -W 170 -H 36 `
    -Back $script:Theme.Red -OnClick {
        $answer = [Windows.Forms.MessageBox]::Show(
            "Удалить задачи, правила брандмауэра и остановить процессы?`nФайлы останутся на месте.",
            'Удаление', 'YesNo', 'Warning')
        if ($answer -eq 'Yes') {
            Invoke-VisibleBat (Join-Path $script:ProxyDir 'uninstall-proxy.bat')
        }
    })

$script:PxFirewall = New-UILabel -Parent $pxRight -Text 'Брандмауэр: ...' -X 16 -Y 444 -W 368 -H 36 `
    -Size 9 -Color $script:Theme.Muted

# --------------------------------------------------------------------------
#  Zapret
# --------------------------------------------------------------------------

$zp = $script:Tabs['zapret']
$zpTable = New-Object System.Windows.Forms.TableLayoutPanel
$zpTable.Dock = [System.Windows.Forms.DockStyle]::Fill
$zpTable.ColumnCount = 2
$zpTable.RowCount = 1
$zpTable.Padding = New-Object System.Windows.Forms.Padding -ArgumentList @(10, 10, 10, 10)
[void]$zpTable.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle(
    [System.Windows.Forms.SizeType]::Percent, 38)))
[void]$zpTable.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle(
    [System.Windows.Forms.SizeType]::Percent, 62)))
[void]$zpTable.RowStyles.Add((New-Object System.Windows.Forms.RowStyle(
    [System.Windows.Forms.SizeType]::Percent, 100)))
$zp.Controls.Add($zpTable)

$zpLeft = New-UICard -Parent $zpTable -X 0 -Y 0 -W 380 -H 560 -Title 'СТРАТЕГИИ'
$zpLeft.Dock = [System.Windows.Forms.DockStyle]::Fill
$zpLeft.Margin = New-Object System.Windows.Forms.Padding -ArgumentList @(6, 0, 6, 0)
[void](New-UILabel -Parent $zpLeft -Text 'Поиск:' -X 16 -Y 44 -W 48 -H 20 `
    -Size 9 -Color $script:Theme.Muted)
$script:StrategyFilter = New-UITextBox -Parent $zpLeft -Text '' -X 64 -Y 40 -W 292 -H 26
$script:StrategyList = New-Object System.Windows.Forms.ListBox
$script:StrategyList.Location = New-Object System.Drawing.Point -ArgumentList @(16, 74)
$script:StrategyList.Size = New-Object System.Drawing.Size -ArgumentList @(340, 338)
$script:StrategyList.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor
    [System.Windows.Forms.AnchorStyles]::Left -bor
    [System.Windows.Forms.AnchorStyles]::Right -bor
    [System.Windows.Forms.AnchorStyles]::Bottom
$script:StrategyList.BackColor = Color $script:Theme.Surface2
$script:StrategyList.ForeColor = Color $script:Theme.Text
$script:StrategyList.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$script:StrategyList.Font = New-Object System.Drawing.Font -ArgumentList @('Segoe UI', 9.5)
$script:StrategyList.IntegralHeight = $false
$script:StrategyList.Add_SelectedIndexChanged({ Update-StrategyDetail })
$script:StrategyList.Add_DoubleClick({
    if ($script:StrategyList.SelectedItem) {
        Start-ZapretStrategy ([string]$script:StrategyList.SelectedItem)
    }
})
$zpLeft.Controls.Add($script:StrategyList)
$script:StrategyDetail = New-UILabel -Parent $zpLeft -Text 'Выберите стратегию' -X 16 -Y 422 -W 340 -H 150 `
    -Size 8.5 -Color $script:Theme.Muted
$script:StrategyFilter.Add_TextChanged({ Update-StrategyList })

# Контекстное меню списка стратегий (правый клик)
$script:StrategyMenu = New-Object System.Windows.Forms.ContextMenuStrip
$miRun = $script:StrategyMenu.Items.Add('Запустить')
$miSelect = $script:StrategyMenu.Items.Add('Сделать выбранной')
$miEdit = $script:StrategyMenu.Items.Add('Открыть .bat в блокноте')
$miFolder = $script:StrategyMenu.Items.Add('Показать в папке')
$script:StrategyList.ContextMenuStrip = $script:StrategyMenu
$script:StrategyList.Add_MouseDown({
    param($sender, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right) {
        $idx = $script:StrategyList.IndexFromPoint($e.X, $e.Y)
        if ($idx -ge 0) { $script:StrategyList.SelectedIndex = $idx }
    }
})
$miRun.Add_Click({
    if ($script:StrategyList.SelectedItem) {
        Start-ZapretStrategy ([string]$script:StrategyList.SelectedItem)
    }
})
$miSelect.Add_Click({
    if ($script:StrategyList.SelectedItem) {
        Set-SelectedStrategy ([string]$script:StrategyList.SelectedItem)
        Update-StrategyDetail
        Update-Status
    }
})
$miEdit.Add_Click({
    if (-not $script:StrategyList.SelectedItem) { return }
    $file = Join-Path $script:RootDir ([string]$script:StrategyList.SelectedItem)
    if (Test-Path -LiteralPath $file) {
        Start-Process -FilePath 'notepad.exe' -ArgumentList "`"$file`""
    }
})
$miFolder.Add_Click({
    if (-not $script:StrategyList.SelectedItem) { return }
    $file = Join-Path $script:RootDir ([string]$script:StrategyList.SelectedItem)
    if (Test-Path -LiteralPath $file) {
        Start-Process -FilePath 'explorer.exe' -ArgumentList "/select,`"$file`""
    }
})

function Update-StrategyDetail {
    if (-not $script:StrategyDetail) { return }
    if (-not $script:StrategyList.SelectedItem) {
        $text = if ($script:StrategyFilter -and $script:StrategyFilter.Text) {
            'Ничего не найдено.'
        } else {
            'Выберите стратегию.'
        }
        $script:StrategyDetail.Text = $text
        return
    }
    $info = Get-StrategyInfo ([string]$script:StrategyList.SelectedItem)
    $script:StrategyDetail.Text = $info.Text
}

function Update-StrategyList {
    $filter = ''
    if ($script:StrategyFilter) { $filter = $script:StrategyFilter.Text.Trim() }
    $current = ''
    if ($script:StrategyList.SelectedItem) { $current = [string]$script:StrategyList.SelectedItem }
    $items = @(Get-StrategyFiles |
        Where-Object { -not $filter -or $_.Name -like "*$filter*" } |
        ForEach-Object { $_.Name })
    $script:StrategyList.BeginUpdate()
    $script:StrategyList.Items.Clear()
    if ($items.Count -gt 0) {
        [void]$script:StrategyList.Items.AddRange([object[]]$items)
    }
    $script:StrategyList.EndUpdate()
    $idx = [Array]::IndexOf($items, $current)
    if ($idx -lt 0) { $idx = [Array]::IndexOf($items, (Get-SelectedStrategy)) }
    if ($idx -lt 0 -and $items.Count -gt 0) { $idx = 0 }
    if ($idx -ge 0) { $script:StrategyList.SelectedIndex = $idx }
    Update-StrategyDetail
}

$zpRight = New-UICard -Parent $zpTable -X 0 -Y 0 -W 600 -H 560 -Title 'УПРАВЛЕНИЕ'
$zpRight.Dock = [System.Windows.Forms.DockStyle]::Fill
$zpRight.Margin = New-Object System.Windows.Forms.Padding -ArgumentList @(6, 0, 6, 0)
$zpRight.AutoScroll = $true

$script:ZpCurrent = New-UILabel -Parent $zpRight -Text 'Текущая: ...' -X 16 -Y 40 -W 560 -H 24 `
    -Size 10 -Color $script:Theme.Cyan -Bold $true
[void](New-UIButton -Parent $zpRight -Text 'Запустить выбранную' -X 16 -Y 72 -W 180 -H 36 `
    -Back $script:Theme.Green -OnClick {
        if ($script:StrategyList.SelectedItem) {
            Start-ZapretStrategy ([string]$script:StrategyList.SelectedItem)
        }
    })
[void](New-UIButton -Parent $zpRight -Text 'Остановить' -X 206 -Y 72 -W 120 -H 36 `
    -Back $script:Theme.Red -OnClick { Stop-ZapretNow })
[void](New-UIButton -Parent $zpRight -Text 'Перезапустить' -X 336 -Y 72 -W 140 -H 36 `
    -Back $script:Theme.Blue -OnClick {
        if ($script:StrategyList.SelectedItem) {
            Start-ZapretStrategy ([string]$script:StrategyList.SelectedItem)
        }
    })
[void](New-UIButton -Parent $zpRight -Text 'Служба zapret (service.bat)' -X 16 -Y 116 -W 220 -H 34 `
    -Back $script:Theme.Surface3 -OnClick {
        Invoke-VisibleBat (Join-Path $script:RootDir 'service.bat')
    })
[void](New-UIButton -Parent $zpRight -Text 'Применить лучшую из теста' -X 246 -Y 116 -W 230 -H 34 `
    -Back $script:Theme.Yellow -Fore $script:Theme.Bg -OnClick { Apply-BestFromResult })

[void](New-UILabel -Parent $zpRight -Text 'ИГРОВОЙ ФИЛЬТР' -X 16 -Y 168 -W 300 -H 20 `
    -Size 8.5 -Color $script:Theme.Muted -Bold $true)
$script:GfEnabled = New-UICheckBox -Parent $zpRight -Text 'Включить игровой фильтр' -X 16 -Y 192 -W 250
$script:GfMode = New-UICombo -Parent $zpRight -Items @('TCP и UDP', 'TCP', 'UDP') -X 16 -Y 220 -W 180
[void](New-UILabel -Parent $zpRight -Text 'TCP порты:' -X 214 -Y 224 -W 80 -H 20 `
    -Size 9 -Color $script:Theme.Muted)
$script:GfTcp = New-UITextBox -Parent $zpRight -Text '1024-65535' -X 296 -Y 220 -W 140 -H 26
[void](New-UILabel -Parent $zpRight -Text 'UDP порты:' -X 214 -Y 254 -W 80 -H 20 `
    -Size 9 -Color $script:Theme.Muted)
$script:GfUdp = New-UITextBox -Parent $zpRight -Text '1024-65535' -X 296 -Y 250 -W 140 -H 26
[void](New-UIButton -Parent $zpRight -Text 'Сохранить игровой фильтр' -X 16 -Y 286 -W 220 -H 34 `
    -Back $script:Theme.Blue -OnClick {
        try {
            $mode = @('all', 'tcp', 'udp')[$script:GfMode.SelectedIndex]
            if (-not $script:GfEnabled.Checked) { $mode = 'disabled' }
            Write-GameFilter $mode $script:GfTcp.Text $script:GfUdp.Text
            [Windows.Forms.MessageBox]::Show(
                "Сохранено. Перезапустите zapret, чтобы применить изменения.",
                'Игровой фильтр', 'OK', 'Information') | Out-Null
        } catch {
            [Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Игровой фильтр',
                'OK', 'Error') | Out-Null
        }
    })

[void](New-UILabel -Parent $zpRight -Text 'IPSet' -X 16 -Y 336 -W 200 -H 20 `
    -Size 8.5 -Color $script:Theme.Muted -Bold $true)
$script:IpsetStatusLabel = New-UILabel -Parent $zpRight -Text 'Статус: ...' -X 16 -Y 360 -W 300 -H 22 `
    -Size 9.5 -Color $script:Theme.Text
$script:IpsetTip = New-Object System.Windows.Forms.ToolTip
$script:IpsetTip.AutoPopDelay = 12000
$ipsetAny = New-UIButton -Parent $zpRight -Text 'any' -X 16 -Y 390 -W 72 -H 32 `
    -Back $script:Theme.Surface3 -OnClick { try { Set-IpsetMode 'any'; Update-IpsetStatus } catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message, 'IPSet', 'OK', 'Error') | Out-Null } }
$ipsetNone = New-UIButton -Parent $zpRight -Text 'none' -X 94 -Y 390 -W 72 -H 32 `
    -Back $script:Theme.Surface3 -OnClick { try { Set-IpsetMode 'none'; Update-IpsetStatus } catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message, 'IPSet', 'OK', 'Error') | Out-Null } }
$ipsetLoaded = New-UIButton -Parent $zpRight -Text 'loaded' -X 172 -Y 390 -W 72 -H 32 `
    -Back $script:Theme.Surface3 -OnClick { try { Set-IpsetMode 'loaded'; Update-IpsetStatus } catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message, 'IPSet', 'OK', 'Error') | Out-Null } }
[void](New-UIButton -Parent $zpRight -Text 'Обновить ipset' -X 250 -Y 390 -W 128 -H 32 `
    -Back $script:Theme.Blue -OnClick { Update-IpsetList })
[void](New-UIButton -Parent $zpRight -Text 'Обновить hosts' -X 384 -Y 390 -W 128 -H 32 `
    -Back $script:Theme.Surface3 -OnClick { Update-HostsFile })
$script:IpsetTip.SetToolTip($ipsetAny,
    'any — пустой ipset: zapret обрабатывает трафик ко всем адресам.')
$script:IpsetTip.SetToolTip($ipsetNone,
    'none — заглушка: фильтр по ipset фактически выключен.')
$script:IpsetTip.SetToolTip($ipsetLoaded,
    'loaded — восстановить сохранённый список из ipset-all.txt.backup.')

$script:AutoUpdateCheck = New-UICheckBox -Parent $zpRight `
    -Text 'Проверять обновления zapret при запуске' -X 16 -Y 440 -W 420
$script:AutoUpdateCheck.Add_Click({
    $file = Join-Path $script:UtilsDir 'check_updates.enabled'
    if ($script:AutoUpdateCheck.Checked) {
        Set-Content -LiteralPath $file -Value 'ENABLED' -Encoding ASCII
    } else {
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    }
})

function Load-GameFilterUI {
    $cfg = Read-GameFilter
    $script:GfEnabled.Checked = ($cfg.mode -ne 'disabled')
    switch ($cfg.mode) {
        'tcp' { $script:GfMode.SelectedIndex = 1 }
        'udp' { $script:GfMode.SelectedIndex = 2 }
        default { $script:GfMode.SelectedIndex = 0 }
    }
    $script:GfTcp.Text = $cfg.tcp
    $script:GfUdp.Text = $cfg.udp
    $script:AutoUpdateCheck.Checked = Test-Path -LiteralPath (Join-Path $script:UtilsDir 'check_updates.enabled')
}

function Update-IpsetStatus {
    $status = Get-IpsetStatus
    $file = Join-Path $script:ListsDir 'ipset-all.txt'
    $backup = "$file.backup"
    $count = 0
    $backupCount = 0
    if ($status -eq 'loaded') {
        try { $count = @([IO.File]::ReadAllLines($file) | Where-Object { $_.Trim() }).Count } catch { }
    }
    if (Test-Path -LiteralPath $backup) {
        try {
            $backupCount = @([IO.File]::ReadAllLines($backup) | Where-Object { $_.Trim() }).Count
        } catch { }
    }
    $text = switch ($status) {
        'any' { 'any — фильтр по ipset отключён (пустой список)' }
        'none' { 'none — заглушка 203.0.113.113/32' }
        default { "loaded — загружен список ipset ($count записей)" }
    }
    $tip = if ($backupCount -gt 0) {
        "Резервная копия: $backupCount записей. Кнопка «loaded» восстановит список."
    } else {
        'Резервной копии нет — нажмите «Обновить ipset».'
    }
    if ($script:IpsetStatusLabel) {
        $script:IpsetStatusLabel.Text = "Статус: $text"
        if ($script:IpsetTip) { $script:IpsetTip.SetToolTip($script:IpsetStatusLabel, $tip) }
    }
}

# --------------------------------------------------------------------------
#  Тесты
# --------------------------------------------------------------------------

$ts = $script:Tabs['tests']
$tsTop = New-Object System.Windows.Forms.FlowLayoutPanel
$tsTop.Dock = [System.Windows.Forms.DockStyle]::Top
$tsTop.Height = 164
$tsTop.Padding = New-Object System.Windows.Forms.Padding -ArgumentList @(14, 12, 14, 0)
$tsTop.WrapContents = $true
$ts.Controls.Add($tsTop)

[void](New-UIButton -Parent $tsTop -Text 'Стандартные тесты (все)' -X 0 -Y 0 -W 220 -H 40 `
    -Back $script:Theme.Green -OnClick { Start-TestRun 'standard' })
[void](New-UIButton -Parent $tsTop -Text 'DPI-тесты (все)' -X 0 -Y 0 -W 200 -H 40 `
    -Back $script:Theme.Blue -OnClick { Start-TestRun 'dpi' })
[void](New-UIButton -Parent $tsTop -Text 'Выбрать конфиги...' -X 0 -Y 0 -W 180 -H 40 `
    -Back $script:Theme.Surface3 -OnClick { Start-TestRun '' -Interactive })
[void](New-UIButton -Parent $tsTop -Text 'Открыть targets.txt' -X 0 -Y 0 -W 170 -H 40 `
    -Back $script:Theme.Surface3 -OnClick {
        Start-Process -FilePath 'notepad.exe' -ArgumentList "`"$(Join-Path $script:UtilsDir 'targets.txt')`""
    })
[void](New-UIButton -Parent $tsTop -Text 'Папка результатов' -X 0 -Y 0 -W 170 -H 40 `
    -Back $script:Theme.Surface3 -OnClick {
        if (-not (Test-Path -LiteralPath $script:ResultsDir)) {
            New-Item -ItemType Directory -Path $script:ResultsDir | Out-Null
        }
        Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$script:ResultsDir`""
    })
[void](New-UIButton -Parent $tsTop -Text 'Авто-подбор стратегии' -X 0 -Y 0 -W 210 -H 40 `
    -Back $script:Theme.Yellow -Fore $script:Theme.Bg -OnClick { Start-AutoSelect })
[void](New-UIButton -Parent $tsTop -Text 'Быстрый подбор (HTTP)' -X 0 -Y 0 -W 200 -H 40 `
    -Back $script:Theme.Yellow -Fore $script:Theme.Bg -OnClick { Start-AutoSelect -Fast })
[void](New-UIButton -Parent $tsTop -Text 'Применить лучшую' -X 0 -Y 0 -W 180 -H 40 `
    -Back $script:Theme.Surface3 -OnClick { Apply-BestFromResult })
[void](New-UIButton -Parent $tsTop -Text 'Остановить тесты' -X 0 -Y 0 -W 180 -H 40 `
    -Back $script:Theme.Red -OnClick { Stop-TestRun })

$tsResultCard = New-UICard -Parent $ts -X 14 -Y 150 -W 850 -H 400
$tsResultCard.Dock = [System.Windows.Forms.DockStyle]::Fill
$tsResultCard.Margin = New-Object System.Windows.Forms.Padding -ArgumentList @(14, 8, 14, 14)
$script:TestStatusLabel = New-UILabel -Parent $tsResultCard `
    -Text 'Готово. Тесты запускаются в отдельном окне PowerShell.' `
    -X 16 -Y 10 -W 620 -H 24 -Size 9.5 -Color $script:Theme.Muted
$script:TestRefresh = New-UIButton -Parent $tsResultCard -Text 'Обновить' `
    -X 690 -Y 8 -W 110 -H 28 -Back $script:Theme.Surface3 -OnClick { Update-LatestResult }
$script:TestRefresh.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor
    [System.Windows.Forms.AnchorStyles]::Right

$script:TestChart = New-Object System.Windows.Forms.Panel
$script:TestChart.Location = New-Object System.Drawing.Point -ArgumentList @(16, 44)
$script:TestChart.Size = New-Object System.Drawing.Size -ArgumentList @(800, 210)
$script:TestChart.BackColor = Color $script:Theme.Surface
$script:TestChart.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor
    [System.Windows.Forms.AnchorStyles]::Left -bor
    [System.Windows.Forms.AnchorStyles]::Right
$script:TestChart.Add_Paint({
    param($sender, $e)
    try { Draw-ResultsChart -sender $sender -e $e -data $script:TestChartData -maxItems 10 -compact $false } catch { }
})
$tsResultCard.Controls.Add($script:TestChart)

$script:TestResultBox = New-UITextBox -Parent $tsResultCard -Text '' -X 16 -Y 262 -W 800 -H 220 `
    -Multiline $true -ReadOnly $true
$script:TestResultBox.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor
    [System.Windows.Forms.AnchorStyles]::Left -bor
    [System.Windows.Forms.AnchorStyles]::Right -bor
    [System.Windows.Forms.AnchorStyles]::Bottom
$script:TestResultBox.Font = New-Object System.Drawing.Font -ArgumentList @('Consolas', 9)

$ts.Controls.SetChildIndex($tsResultCard, 0)
$ts.Controls.SetChildIndex($tsTop, 1)

function Update-LatestResult {
    $file = Get-LatestResultFile
    if (-not $file) {
        $script:TestResultBox.Text = 'Результатов пока нет. Запустите тесты.'
        $script:TestStatusLabel.Text = 'Готово. Тесты запускаются в отдельном окне PowerShell.'
        Update-TestCharts
        return
    }
    $script:TestResultBox.Text = (Get-Content -LiteralPath $file.FullName -Raw)
    $script:TestStatusLabel.Text = "Последний результат: $($file.Name) ($($file.LastWriteTime))"
    Update-TestCharts
}

# --------------------------------------------------------------------------
#  Журналы
# --------------------------------------------------------------------------

$lg = $script:Tabs['logs']
$lgTop = New-Object System.Windows.Forms.FlowLayoutPanel
$lgTop.Dock = [System.Windows.Forms.DockStyle]::Top
$lgTop.Height = 100
$lgTop.Padding = New-Object System.Windows.Forms.Padding -ArgumentList @(14, 10, 14, 0)
$lgTop.WrapContents = $true
$lg.Controls.Add($lgTop)

$script:LogCombo = New-UICombo -Parent $lgTop -Items @(
    'proxy.log', 'watchdog.log', 'setup.log', 'Последний результат тестов'
) -X 0 -Y 0 -W 300 -H 30
$script:LogCombo.SelectedIndex = 0
$script:LogCombo.Add_SelectedIndexChanged({ Update-LogView })
[void](New-UIButton -Parent $lgTop -Text 'Обновить' -X 0 -Y 0 -W 110 -H 30 `
    -Back $script:Theme.Blue -OnClick { Update-LogView })
[void](New-UIButton -Parent $lgTop -Text 'Открыть в блокноте' -X 0 -Y 0 -W 170 -H 30 `
    -Back $script:Theme.Surface3 -OnClick {
        $path = Get-SelectedLogPath
        if ($path -and (Test-Path -LiteralPath $path)) {
            Start-Process -FilePath 'notepad.exe' -ArgumentList "`"$path`""
        }
    })
$script:LogAuto = New-UICheckBox -Parent $lgTop -Text 'Автообновление' -X 0 -Y 4 -W 160 -Checked $true
[void](New-UILabel -Parent $lgTop -Text 'Фильтр:' -X 0 -Y 5 -W 54 -H 20 `
    -Size 9 -Color $script:Theme.Muted)
$script:LogFilter = New-UITextBox -Parent $lgTop -Text '' -X 0 -Y 0 -W 260 -H 28
$script:LogFilter.Add_TextChanged({ Update-LogView })
[void](New-UIButton -Parent $lgTop -Text 'Сохранить как...' -X 0 -Y 0 -W 150 -H 30 `
    -Back $script:Theme.Surface3 -OnClick {
        $path = Get-SelectedLogPath
        if (-not $path) { return }
        $dialog = New-Object System.Windows.Forms.SaveFileDialog
        $dialog.Filter = 'Текст (*.txt)|*.txt|Все файлы (*.*)|*.*'
        $dialog.FileName = Split-Path -Leaf $path
        if ($dialog.ShowDialog() -eq 'OK') {
            Set-Content -LiteralPath $dialog.FileName -Value $script:LogBox.Text -Encoding UTF8
        }
    })
[void](New-UIButton -Parent $lgTop -Text 'Папка журналов' -X 0 -Y 0 -W 150 -H 30 `
    -Back $script:Theme.Surface3 -OnClick {
        Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$script:ProxyDir`""
    })

$script:LogBox = New-UITextBox -Parent $lg -Text '' -X 14 -Y 62 -W 900 -H 400 `
    -Multiline $true -ReadOnly $true
$script:LogBox.Dock = [System.Windows.Forms.DockStyle]::Fill
$script:LogBox.Margin = New-Object System.Windows.Forms.Padding -ArgumentList @(14, 8, 14, 14)
$script:LogBox.Font = New-Object System.Drawing.Font -ArgumentList @('Consolas', 9)
$script:LogBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Both
$script:LogBox.WordWrap = $false

$lg.Controls.SetChildIndex($script:LogBox, 0)
$lg.Controls.SetChildIndex($lgTop, 1)

function Get-SelectedLogPath {
    switch ($script:LogCombo.SelectedIndex) {
        0 { return (Join-Path $script:ProxyDir 'proxy.log') }
        1 { return (Join-Path $script:ProxyDir 'watchdog.log') }
        2 { return (Join-Path $script:ProxyDir 'setup.log') }
        3 {
            $file = Get-LatestResultFile
            if ($file) { return $file.FullName }
            return ''
        }
    }
    return ''
}

function Update-LogView {
    if (-not $script:LogBox) { return }
    $path = Get-SelectedLogPath
    if (-not $path) {
        $script:LogBox.Text = 'Файл ещё не создан.'
        return
    }
    $atEnd = $script:LogBox.SelectionStart -ge ($script:LogBox.TextLength - 2)
    $raw = Get-LogTail $path 2000
    $filter = ''
    if ($script:LogFilter) { $filter = $script:LogFilter.Text.Trim() }
    if ($filter) {
        $matched = @($raw -split "`r?`n" | Where-Object { $_ -match [regex]::Escape($filter) })
        if ($matched.Count -gt 0) {
            $script:LogBox.Text = ($matched -join "`r`n") +
                "`r`n`r`n--- совпадений: $($matched.Count) ---"
        } else {
            $script:LogBox.Text = "Нет строк, содержащих: $filter"
        }
    } else {
        $script:LogBox.Text = $raw
    }
    if ($atEnd -and -not $filter) {
        $script:LogBox.SelectionStart = $script:LogBox.TextLength
        $script:LogBox.ScrollToCaret()
    }
}

# --------------------------------------------------------------------------
#  Обновления (отдельная вкладка)
# --------------------------------------------------------------------------

$upd = $script:Tabs['updates']

$updTop = New-Object System.Windows.Forms.FlowLayoutPanel
$updTop.Dock = [System.Windows.Forms.DockStyle]::Top
$updTop.Height = 66
$updTop.Padding = New-Object System.Windows.Forms.Padding -ArgumentList @(14, 12, 14, 0)
$updTop.WrapContents = $true
$upd.Controls.Add($updTop)

[void](New-UIButton -Parent $updTop -Text 'Проверить обновления' -X 0 -Y 0 -W 195 -H 40 `
    -Back $script:Theme.Accent -OnClick { Start-UpdatesTabCheckAsync })
[void](New-UIButton -Parent $updTop -Text 'Скачать и установить' -X 0 -Y 0 -W 195 -H 40 `
    -Back $script:Theme.Green -Fore $script:Theme.Bg -OnClick { Start-UpdatesTabInstall })
[void](New-UIButton -Parent $updTop -Text 'Страница релиза' -X 0 -Y 0 -W 155 -H 40 `
    -Back $script:Theme.Surface3 -OnClick {
        $obj = $script:LatestAppUpdate
        if ($obj -and $obj.url) { try { Start-Process ([string]$obj.url) } catch { } }
        else { try { Start-Process "https://github.com/$($script:UpdateRepo)/releases/latest" } catch { } }
    })
$script:UpdAutoCheck = New-UICheckBox -Parent $updTop -Text 'Проверять автоматически' `
    -X 0 -Y 4 -W 220 -Checked ([bool]$script:Settings.AutoCheckAppUpdates)
$script:UpdAutoCheck.Add_Click({
    $script:Settings.AutoCheckAppUpdates = [bool]$script:UpdAutoCheck.Checked
    if ($script:AutoAppUpdateCheck) { $script:AutoAppUpdateCheck.Checked = [bool]$script:UpdAutoCheck.Checked }
    Save-GuiSettings
})

$updInfo = New-UICard -Parent $upd -X 14 -Y 78 -W 860 -H 150 -Title 'СОСТОЯНИЕ ОБНОВЛЕНИЙ'
$updInfo.Dock = [System.Windows.Forms.DockStyle]::Top
$updInfo.Height = 150
$updInfo.Margin = New-Object System.Windows.Forms.Padding -ArgumentList @(14, 8, 14, 0)
$script:UpdCurrentLabel = New-UILabel -Parent $updInfo -Text ("Установлено: " + (Get-InstalledZapretControlVersion)) `
    -X 18 -Y 40 -W 520 -H 26 -Size 10 -Color $script:Theme.Text
$script:UpdLatestLabel = New-UILabel -Parent $updInfo -Text 'Актуальная версия: не проверялась' `
    -X 18 -Y 70 -W 520 -H 26 -Size 10 -Color $script:Theme.Text
$script:UpdStatusLabel = New-UILabel -Parent $updInfo -Text 'Нажмите «Проверить обновления», чтобы узнать актуальную версию.' `
    -X 18 -Y 102 -W 800 -H 30 -Size 11 -Color $script:Theme.Cyan -Bold $true

$updNotesCard = New-UICard -Parent $upd -X 14 -Y 240 -W 860 -H 340 -Title 'ЧТО НОВОГО / ИСТОРИЯ ВЫПУСКОВ'
$updNotesCard.Dock = [System.Windows.Forms.DockStyle]::Fill
$updNotesCard.Margin = New-Object System.Windows.Forms.Padding -ArgumentList @(14, 8, 14, 14)
$updNotesHost = New-Object System.Windows.Forms.Panel
$updNotesHost.Dock = [System.Windows.Forms.DockStyle]::Fill
$updNotesHost.Padding = New-Object System.Windows.Forms.Padding -ArgumentList @(14, 36, 14, 14)
$updNotesCard.Controls.Add($updNotesHost)
$script:UpdNotes = New-Object System.Windows.Forms.RichTextBox
$script:UpdNotes.Dock = [System.Windows.Forms.DockStyle]::Fill
$script:UpdNotes.BackColor = Color $script:Theme.Surface
$script:UpdNotes.ForeColor = Color $script:Theme.Text
$script:UpdNotes.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$script:UpdNotes.Font = New-Object System.Drawing.Font -ArgumentList @('Segoe UI', 9.5)
$script:UpdNotes.ReadOnly = $true
$script:UpdNotes.WordWrap = $true
$script:UpdNotes.Text = @(
    'Обновления ZAPRET CONTROL',
    '',
    'Источник: GitHub Releases (egftmixmkur/zapret-discord-youtube) и version.json.',
    'Проверка обновлений выполняется без дополнительной платы и без отдельного сервера.',
    '',
    'Нажмите «Проверить обновления», чтобы загрузить описание последнего релиза.'
) -join "`r`n"
$updNotesHost.Controls.Add($script:UpdNotes)
try { $updNotesCard.Controls[0].BringToFront() } catch { }

$upd.Controls.SetChildIndex($updNotesCard, 0)
$upd.Controls.SetChildIndex($updInfo, 1)
$upd.Controls.SetChildIndex($updTop, 2)

# --------------------------------------------------------------------------
#  Инструменты
# --------------------------------------------------------------------------

$tl = $script:Tabs['tools']
$tlTop = New-Object System.Windows.Forms.FlowLayoutPanel
$tlTop.Dock = [System.Windows.Forms.DockStyle]::Top
$tlTop.Height = 256
$tlTop.Padding = New-Object System.Windows.Forms.Padding -ArgumentList @(14, 12, 14, 0)
$tlTop.WrapContents = $true
$tl.Controls.Add($tlTop)

[void](New-UIButton -Parent $tlTop -Text 'Диагностика' -X 0 -Y 0 -W 150 -H 40 `
    -Back $script:Theme.Blue -OnClick { Run-Diagnostics })
[void](New-UIButton -Parent $tlTop -Text 'Починить DNS (DoH)' -X 0 -Y 0 -W 180 -H 40 `
    -Back $script:Theme.Surface3 -OnClick { Invoke-VisibleBat (Join-Path $script:ProxyDir 'fix-dns.bat') })
[void](New-UIButton -Parent $tlTop -Text 'Почистить hosts' -X 0 -Y 0 -W 160 -H 40 `
    -Back $script:Theme.Surface3 -OnClick {
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $script:ProxyDir 'fix-hosts.ps1') 2>&1
        [Windows.Forms.MessageBox]::Show(($out | Out-String), 'Hosts', 'OK', 'Information') | Out-Null
    })
[void](New-UIButton -Parent $tlTop -Text 'Кэш Discord' -X 0 -Y 0 -W 140 -H 40 `
    -Back $script:Theme.Surface3 -OnClick { Clear-DiscordCache })
[void](New-UIButton -Parent $tlTop -Text 'service.bat' -X 0 -Y 0 -W 130 -H 40 `
    -Back $script:Theme.Surface3 -OnClick { Invoke-VisibleBat (Join-Path $script:RootDir 'service.bat') })
[void](New-UIButton -Parent $tlTop -Text 'Папка zapret' -X 0 -Y 0 -W 140 -H 40 `
    -Back $script:Theme.Surface3 -OnClick {
        Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$script:RootDir`""
    })
[void](New-UIButton -Parent $tlTop -Text 'Очистить вывод' -X 0 -Y 0 -W 150 -H 40 `
    -Back $script:Theme.Surface3 -OnClick { $script:DiagBox.Clear() })
[void](New-UIButton -Parent $tlTop -Text 'Проверить соединение' -X 0 -Y 0 -W 190 -H 40 `
    -Back $script:Theme.Cyan -Fore $script:Theme.Bg -OnClick { Show-ConnectionTest })
[void](New-UIButton -Parent $tlTop -Text 'Правила брандмауэра' -X 0 -Y 0 -W 180 -H 40 `
    -Back $script:Theme.Surface3 -OnClick {
        [Windows.Forms.MessageBox]::Show(
            "Правила zapret LAN proxy: $(Get-FirewallSummary)",
            'Брандмауэр', 'OK', 'Information') | Out-Null
    })
[void](New-UIButton -Parent $tlTop -Text 'Создать правила' -X 0 -Y 0 -W 160 -H 40 `
    -Back $script:Theme.Green -OnClick { Add-FirewallRules })
[void](New-UIButton -Parent $tlTop -Text 'Удалить правила' -X 0 -Y 0 -W 160 -H 40 `
    -Back $script:Theme.Red -OnClick { Remove-FirewallRules })
[void](New-UIButton -Parent $tlTop -Text 'Экспорт отчёта' -X 0 -Y 0 -W 160 -H 40 `
    -Back $script:Theme.Blue -OnClick { Save-DiagReport })
[void](New-UIButton -Parent $tlTop -Text 'Копировать отчёт' -X 0 -Y 0 -W 170 -H 40 `
    -Back $script:Theme.Surface3 -OnClick { Copy-DiagReport })
[void](New-UIButton -Parent $tlTop -Text 'Папка proxy' -X 0 -Y 0 -W 140 -H 40 `
    -Back $script:Theme.Surface3 -OnClick {
        Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$script:ProxyDir`""
    })
[void](New-UIButton -Parent $tlTop -Text 'Обновления (открыть вкладку)' -X 0 -Y 0 -W 230 -H 40 `
    -Back $script:Theme.Accent -OnClick { Switch-Tab 'updates' })
[void](New-UIButton -Parent $tlTop -Text 'Обновления zapret (старое)' -X 0 -Y 0 -W 210 -H 40 `
    -Back $script:Theme.Surface3 -OnClick {
        $bat = Join-Path $script:RootDir 'service.bat'
        Start-Process -FilePath 'cmd.exe' -ArgumentList @('/k', "`"$bat`" check_updates")
    })
[void](New-UIButton -Parent $tlTop -Text 'Папка macOS' -X 0 -Y 0 -W 140 -H 40 `
    -Back $script:Theme.Surface3 -OnClick { Open-MacFolder })
[void](New-UIButton -Parent $tlTop -Text 'macOS: инструкция' -X 0 -Y 0 -W 170 -H 40 `
    -Back $script:Theme.Surface3 -OnClick { Open-MacReadme })
[void](New-UIButton -Parent $tlTop -Text 'macOS: релизы' -X 0 -Y 0 -W 150 -H 40 `
    -Back $script:Theme.Cyan -Fore $script:Theme.Bg -OnClick { Open-MacRelease })
[void](New-UIButton -Parent $tlTop -Text 'Списки (папка)' -X 0 -Y 0 -W 140 -H 40 `
    -Back $script:Theme.Surface3 -OnClick { Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$script:ListsDir`"" })
[void](New-UIButton -Parent $tlTop -Text 'Мои домены' -X 0 -Y 0 -W 130 -H 40 `
    -Back $script:Theme.Surface3 -OnClick { $f = Join-Path $script:ListsDir 'list-general-user.txt'; if (-not (Test-Path $f)) { New-Item -ItemType File -Path $f -Force | Out-Null }; Start-Process -FilePath 'notepad.exe' -ArgumentList "`"$f`"" })
[void](New-UIButton -Parent $tlTop -Text 'Исключения' -X 0 -Y 0 -W 130 -H 40 `
    -Back $script:Theme.Surface3 -OnClick { $f = Join-Path $script:ListsDir 'list-exclude-user.txt'; if (-not (Test-Path $f)) { New-Item -ItemType File -Path $f -Force | Out-Null }; Start-Process -FilePath 'notepad.exe' -ArgumentList "`"$f`"" })
[void](New-UIButton -Parent $tlTop -Text 'IP исключения' -X 0 -Y 0 -W 140 -H 40 `
    -Back $script:Theme.Surface3 -OnClick { $f = Join-Path $script:ListsDir 'ipset-exclude-user.txt'; if (-not (Test-Path $f)) { New-Item -ItemType File -Path $f -Force | Out-Null }; Start-Process -FilePath 'notepad.exe' -ArgumentList "`"$f`"" })
$script:MinTrayCheck = New-UICheckBox -Parent $tlTop -Text 'Сворачивать в трей' `
    -X 0 -Y 4 -W 190 -Checked ([bool]$script:Settings.MinimizeToTray)
$script:MinTrayCheck.Add_Click({
    $script:Settings.MinimizeToTray = [bool]$script:MinTrayCheck.Checked
    Save-GuiSettings
    if ($script:MinTrayCheck.Checked) {
        [Windows.Forms.MessageBox]::Show(
            'Теперь кнопка сворачивания и закрытие окна прячут приложение в трей.' +
            "`n`nВыход — через меню значка в трее.",
            'Трей', 'OK', 'Information') | Out-Null
    }
})
$script:AutoAppUpdateCheck = New-UICheckBox -Parent $tlTop -Text 'Проверять обновления ZAPRET CONTROL' `
    -X 0 -Y 4 -W 300 -Checked ([bool]$script:Settings.AutoCheckAppUpdates)
$script:AutoAppUpdateCheck.Add_Click({
    $script:Settings.AutoCheckAppUpdates = [bool]$script:AutoAppUpdateCheck.Checked
    if ($script:UpdAutoCheck) { $script:UpdAutoCheck.Checked = [bool]$script:AutoAppUpdateCheck.Checked }
    Save-GuiSettings
})
$script:HotkeyToggleCheck = New-UICheckBox -Parent $tlTop -Text 'Горячая клавиша Ctrl+Alt+Z — вкл/выкл обход' `
    -X 0 -Y 4 -W 340 -Checked ([bool]$script:Settings.HotkeyToggleZapret)
$script:HotkeyToggleCheck.Add_Click({
    $script:Settings.HotkeyToggleZapret = [bool]$script:HotkeyToggleCheck.Checked
    Save-GuiSettings
    try { Update-HotkeyRegistration } catch { }
})

$script:DiagBox = New-Object System.Windows.Forms.RichTextBox
$script:DiagBox.Dock = [System.Windows.Forms.DockStyle]::Fill
$script:DiagBox.Margin = New-Object System.Windows.Forms.Padding -ArgumentList @(14, 8, 14, 14)
$script:DiagBox.BackColor = Color $script:Theme.Surface
$script:DiagBox.ForeColor = Color $script:Theme.Text
$script:DiagBox.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$script:DiagBox.Font = New-Object System.Drawing.Font -ArgumentList @('Consolas', 9.5)
$script:DiagBox.ReadOnly = $true
$script:DiagBox.WordWrap = $false
$tl.Controls.Add($script:DiagBox)

$tl.Controls.SetChildIndex($script:DiagBox, 0)
$tl.Controls.SetChildIndex($tlTop, 1)

function Get-MacClientInfo {
    if (-not (Test-Path -LiteralPath $script:MacClientScript)) { return $null }
    $ver = $null
    try {
        foreach ($line in Get-Content -LiteralPath $script:MacClientScript -TotalCount 80 -ErrorAction Stop) {
            if ($line -match '^\s*APP_VERSION="([^"]+)"') { $ver = $matches[1]; break }
        }
    } catch { }
    [pscustomobject]@{
        Path    = $script:MacClientScript
        Dir     = $script:MacDir
        Version = $ver
    }
}

function Open-MacFolder {
    if (Test-Path -LiteralPath $script:MacDir) {
        Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$script:MacDir`""
    } else {
        [Windows.Forms.MessageBox]::Show('Папка macos не найдена.', 'macOS', 'OK', 'Warning') | Out-Null
    }
}

function Open-MacReadme {
    $readme = Join-Path $script:MacDir 'README.md'
    if (Test-Path -LiteralPath $readme) {
        Start-Process -FilePath 'notepad.exe' -ArgumentList "`"$readme`""
    } else {
        [Windows.Forms.MessageBox]::Show('Файл macos\README.md не найден.', 'macOS', 'OK', 'Warning') | Out-Null
    }
}

function Open-MacRelease {
    Start-Process 'https://github.com/egftmixmkur/zapret-discord-youtube/releases?q=macOS&expanded=true'
}

function Add-Diag([string]$text, [string]$color = '#e6edf3') {
    $script:DiagBox.SelectionStart = $script:DiagBox.TextLength
    $script:DiagBox.SelectionColor = Color $color
    $script:DiagBox.AppendText($text + "`r`n")
    $script:DiagBox.ScrollToCaret()
}

function Run-Diagnostics {
    $script:DiagBox.Clear()
    Add-Diag '=== ДИАГНОСТИКА ZAPRET CONTROL ===' $script:Theme.Cyan
    Add-Diag "Время: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Add-Diag "GUI: 1.12.12 (Windows), прокси: $($script:ProxyDir)"
    Add-Diag ''
    $ok = $script:Theme.Green
    $bad = $script:Theme.Red
    $warn = $script:Theme.Yellow

    if ($script:IsAdmin) { Add-Diag '[OK] Права администратора' $ok }
    else { Add-Diag '[X] Нет прав администратора' $bad }

    $py = (Get-Command pythonw.exe -ErrorAction SilentlyContinue).Source
    if (-not $py) { $py = (Get-Command python.exe -ErrorAction SilentlyContinue).Source }
    if ($py) { Add-Diag "[OK] Python: $py" $ok } else { Add-Diag '[X] Python не найден' $bad }

    foreach ($path in @($script:RootDir, $script:ProxyDir, $script:UtilsDir, $script:ListsDir, $script:BindDir)) {
        if (Test-Path -LiteralPath $path) { Add-Diag "[OK] Папка: $path" $ok }
        else { Add-Diag "[X] Нет папки: $path" $bad }
    }

    $strategies = Get-StrategyFiles
    if ($strategies.Count -gt 0) { Add-Diag "[OK] Стратегий найдено: $($strategies.Count)" $ok }
    else { Add-Diag '[X] Стратегии general*.bat не найдены' $bad }

    $mac = Get-MacClientInfo
    if ($mac) {
        $mv = if ($mac.Version) { $mac.Version } else { 'не определена' }
        Add-Diag "[OK] macOS-клиент: $mv ($($mac.Dir))" $ok
    } else {
        Add-Diag '[i] macOS-клиент не найден (папка macos)' $script:Theme.Muted
    }

    $winws = @(Get-Process -Name 'winws' -ErrorAction SilentlyContinue)
    if ($winws.Count -gt 0) { Add-Diag "[OK] winws.exe запущен (PID $($winws[0].Id))" $ok }
    else { Add-Diag '[!] winws.exe не запущен' $warn }

    $service = Get-Service -Name 'zapret' -ErrorAction SilentlyContinue
    if ($service) { Add-Diag "[!] Служба zapret: $($service.Status)" $warn }
    else { Add-Diag '[OK] Служба zapret не установлена (standalone режим)' $ok }

    $http = Get-PortOpen 8080
    $socks = Get-PortOpen 1080
    Add-Diag "$(if ($http) { '[OK]' } else { '[X]' }) HTTP-прокси :8080" $(if ($http) { $ok } else { $bad })
    Add-Diag "$(if ($socks) { '[OK]' } else { '[X]' }) SOCKS5 :1080" $(if ($socks) { $ok } else { $bad })

    $health = Get-ProxyHealth
    if ($health) {
        Add-Diag "[OK] /health: v$($health.version), uptime $($health.uptime) c" $ok
    } else {
        Add-Diag '[!] /health не отвечает (прокси старой версии или выключен)' $warn
    }

    $tasks = Get-TaskStatus
    foreach ($name in @('zapret-proxy', 'zapret-proxy-watchdog', 'zapret-max')) {
        $state = $tasks[$name]
        if ($state -eq 'missing') { Add-Diag "[!] Задача $name не найдена" $warn }
        else { Add-Diag "[OK] Задача $name : $state" $ok }
    }

    $bfe = Get-Service -Name 'BFE' -ErrorAction SilentlyContinue
    if ($bfe -and $bfe.Status -eq 'Running') { Add-Diag '[OK] Base Filtering Engine работает' $ok }
    else { Add-Diag '[X] Base Filtering Engine не работает' $bad }

    try {
        $tcp = (netsh interface tcp show global) -join ' '
        if ($tcp -match 'timestamps.*enabled') { Add-Diag '[OK] TCP timestamps включены' $ok }
        else { Add-Diag '[!] TCP timestamps выключены' $warn }
    } catch { Add-Diag '[!] Не удалось проверить TCP timestamps' $warn }

    $hosts = Join-Path $env:windir 'System32\drivers\etc\hosts'
    if (Test-Path -LiteralPath $hosts) {
        $hostsText = Get-Content -LiteralPath $hosts -Raw
        $yt = ([regex]::Matches($hostsText, '(?im)^\s*[^#].*(youtube\.com|youtu\.be)')).Count
        $dc = ([regex]::Matches($hostsText, '(?im)^\s*[^#].*discord')).Count
        if ($yt -gt 0) { Add-Diag "[!] В hosts есть записи YouTube: $yt" $warn }
        else { Add-Diag '[OK] В hosts нет записей YouTube' $ok }
        if ($dc -gt 0) { Add-Diag "[!] В hosts есть записи Discord: $dc" $warn }
        else { Add-Diag '[OK] В hosts нет записей Discord' $ok }
    }

    try {
        $rules = @(Get-NetFirewallRule -DisplayName 'zapret LAN proxy*' -ErrorAction Stop)
        if ($rules.Count -gt 0) { Add-Diag "[OK] Правил брандмауэра: $($rules.Count)" $ok }
        else { Add-Diag '[!] Правила брандмауэра не найдены' $warn }
    } catch { Add-Diag '[!] Не удалось проверить брандмауэр' $warn }

    try {
        $dns = Get-DnsClientServerAddress -AddressFamily IPv4 |
            Where-Object { $_.ServerAddresses.Count -gt 0 } |
            Select-Object -First 3
        foreach ($d in $dns) {
            Add-Diag "[i] DNS $($d.InterfaceAlias): $($d.ServerAddresses -join ', ')" $script:Theme.Muted
        }
    } catch { }

    $log = Join-Path $script:ProxyDir 'proxy.log'
    if (Test-Path -LiteralPath $log) {
        $errs = @(Get-Content -LiteralPath $log -Tail 200 | Where-Object { $_ -match 'ERROR|WARNING' })
        if ($errs.Count -gt 0) {
            Add-Diag "[!] В proxy.log предупреждений/ошибок за последние 200 строк: $($errs.Count)" $warn
            foreach ($line in ($errs | Select-Object -Last 3)) {
                Add-Diag "    $line" $script:Theme.Muted
            }
        } else {
            Add-Diag '[OK] proxy.log без ошибок в последних 200 строках' $ok
        }
    }

    $results = @(Get-ChildItem -LiteralPath $script:ResultsDir -Filter 'test_results_*.txt' -ErrorAction SilentlyContinue)
    Add-Diag "[i] Файлов результатов тестов: $($results.Count)" $script:Theme.Muted
    Add-Diag ''
    Add-Diag 'Готово.' $script:Theme.Cyan
}

# --------------------------------------------------------------------------
#  Обновление статуса
# --------------------------------------------------------------------------

function Update-Status {
    try {
    $proxyOk = Get-PortOpen 8080
    $socksOk = Get-PortOpen 1080
    $winws = @(Get-Process -Name 'winws' -ErrorAction SilentlyContinue)
    $service = Get-Service -Name 'zapret' -ErrorAction SilentlyContinue
    $tasks = Get-TaskStatus
    $strategy = Get-SelectedStrategy
    $lan = Get-LanIp
    $health = Get-ProxyHealth
    $lastTest = Get-LatestResultFile
    $winner = Get-BestFromResultFile $lastTest

    $proxyText = if ($proxyOk -and $socksOk) { 'РАБОТАЕТ' } elseif ($proxyOk -or $socksOk) { 'ЧАСТИЧНО' } else { 'ОСТАНОВЛЕН' }
    $proxyState = if ($proxyOk -and $socksOk) { 'ok' } elseif ($proxyOk -or $socksOk) { 'warn' } else { 'off' }
    Set-Pill $script:PillProxy "ПРОКСИ: $proxyText" $proxyState

    $zapretRunning = $winws.Count -gt 0
    if ($zapretRunning) {
        Set-Pill $script:PillZapret 'ZAPRET: OK' 'ok'
    } elseif ($service -and $service.Status -eq 'Running') {
        Set-Pill $script:PillZapret 'ZAPRET: СЛУЖБА' 'warn'
    } else {
        Set-Pill $script:PillZapret 'ZAPRET: OFF' 'off'
    }

    $taskCount = @($tasks.Values | Where-Object { $_ -ne 'missing' }).Count
    if ($taskCount -eq 3) { Set-Pill $script:PillTasks 'АВТОЗАПУСК: OK' 'ok' }
    elseif ($taskCount -gt 0) { Set-Pill $script:PillTasks "АВТОЗАПУСК: $taskCount/3" 'warn' }
    else { Set-Pill $script:PillTasks 'АВТОЗАПУСК: OFF' 'off' }

    Set-Pill $script:PillAdmin ($(if ($script:IsAdmin) { 'АДМИН: ДА' } else { 'АДМИН: НЕТ' })) `
        $(if ($script:IsAdmin) { 'ok' } else { 'off' })

    $script:OvValues['proxy'].Text = $proxyText
    $script:OvDetails['proxy'].Text = if ($proxyOk -and $socksOk) { "HTTP :8080 · SOCKS5 :1080`r`nLAN: $lan" } else { 'Нажмите «Запустить всё»' }
    $script:OvValues['zapret'].Text = if ($zapretRunning) { 'РАБОТАЕТ' } elseif ($service) { 'СЛУЖБА' } else { 'ОСТАНОВЛЕН' }
    $script:OvDetails['zapret'].Text = if ($zapretRunning) { "winws.exe PID $($winws[0].Id)" } elseif ($service) { "Служба: $($service.Status)" } else { 'DPI-обход выключен' }
    $script:OvValues['strategy'].Text = [IO.Path]::GetFileNameWithoutExtension($strategy)
    $script:OvDetails['strategy'].Text = if ($winner) {
        "Лучшая по тесту: $([IO.Path]::GetFileNameWithoutExtension($winner))"
    } else {
        'Используется для запуска и автозапуска'
    }
    $script:OvValues['tasks'].Text = "$taskCount / 3"
    $script:OvDetails['tasks'].Text = 'Прокси · вотчдог · zapret'

    if ($script:OvSummary) {
        $healthLine = if ($health) {
            "Прокси v$($health.version), uptime $($health.uptime) c, DoH: $(@($health.doh).Count)"
        } elseif ($proxyOk) {
            'Прокси отвечает, /health недоступен (старая версия?)'
        } else {
            'Прокси выключен'
        }
        $testLine = if ($lastTest) {
            "Последний тест: $($lastTest.LastWriteTime.ToString('dd.MM.yyyy HH:mm'))" +
                $(if ($winner) { " · лучшая: $winner" } else { '' })
        } else {
            'Тесты ещё не запускались'
        }
        $connLine = if ($script:LastConnSummary) {
            $script:LastConnSummary
        } else {
            'Проверка соединения: не выполнялась'
        }
        $script:OvSummary.Text = @(
            "Стратегия: $strategy",
            $healthLine,
            $testLine,
            $connLine
        ) -join "`r`n"
    }

    if ($script:PxLan) {
        $script:PxLan.Text = "LAN IP: $lan"
        $script:PxHttp.Text = "HTTP:     $lan`:8080"
        $script:PxSocks.Text = "SOCKS5:   $lan`:1080"
    }
    if ($script:PxTasks) {
        $script:PxTasks.Text = "Задачи: proxy=$($tasks['zapret-proxy']), watchdog=$($tasks['zapret-proxy-watchdog']), zapret=$($tasks['zapret-max'])"
    }
    if ($script:PxHealth) {
        if ($health) {
            $script:PxHealth.Text = "Health: v$($health.version), uptime $($health.uptime) c`r`nDoH: $(@($health.doh).Count) сервера"
        } else {
            $script:PxHealth.Text = 'Health: нет ответа (прокси v1.3 или выключен)'
        }
    }
    if ($script:PxFirewall) {
        $script:PxFirewall.Text = "Брандмауэр: $(Get-FirewallSummary)"
    }
    if ($script:ZpCurrent) {
        $script:ZpCurrent.Text = "Текущая стратегия: $strategy"
    }
    if ($script:StatusAdmin) {
        $script:StatusAdmin.Text = "Админ: $(if ($script:IsAdmin) { 'да' } else { 'нет' })"
        $script:StatusAdmin.ForeColor = Color $(if ($script:IsAdmin) { $script:Theme.Green } else { $script:Theme.Red })
    }
    try { Update-BypassUiState } catch { }
    if ($script:StatusPython) {
        $py = (Get-Command pythonw.exe -ErrorAction SilentlyContinue).Source
        if (-not $py) { $py = (Get-Command python.exe -ErrorAction SilentlyContinue).Source }
        $script:StatusPython.Text = if ($py) { "Python: $(Split-Path -Leaf $py)" } else { 'Python: не найден' }
    }
    if ($script:StatusTests) {
        if ($script:TestWasRunning) {
            $script:StatusTests.Text = 'Тесты: выполняются'
            $script:StatusTests.ForeColor = Color $script:Theme.Yellow
        } else {
            $script:StatusTests.Text = 'Тесты: нет'
            $script:StatusTests.ForeColor = Color $script:Theme.Muted
        }
    }
    } catch { }
}

# --------------------------------------------------------------------------
#  Адаптивная раскладка (якоря внутри Dock-панелей считаются от нулевого
#  размера, поэтому большие поля растягиваем вручную по Resize).
# --------------------------------------------------------------------------

$script:StrategyList.Anchor = [System.Windows.Forms.AnchorStyles]::None
$script:TestResultBox.Anchor = [System.Windows.Forms.AnchorStyles]::None
$script:TestRefresh.Anchor = [System.Windows.Forms.AnchorStyles]::None
$script:StatusPath.Anchor = [System.Windows.Forms.AnchorStyles]::None

function Update-ResponsiveLayout {
    try {
        $w = [Math]::Max(120, $zpLeft.ClientSize.Width - 32)
        $script:StrategyFilter.Location = New-Object System.Drawing.Point(64, 40)
        $script:StrategyFilter.Width = [Math]::Max(80, $w - 48)
        $detailTop = [Math]::Max(300, $zpLeft.ClientSize.Height - 150 - 12)
        $script:StrategyList.Location = New-Object System.Drawing.Point(16, 74)
        $script:StrategyList.Width = $w
        $script:StrategyList.Height = [Math]::Max(80, $detailTop - 74 - 8)
        $script:StrategyDetail.Location = New-Object System.Drawing.Point(16, $detailTop)
        $script:StrategyDetail.Width = $w
        $script:StrategyDetail.Height = [Math]::Max(60,
            $zpLeft.ClientSize.Height - $detailTop - 16)

        $w = [Math]::Max(160, $tsResultCard.ClientSize.Width - 32)
        $script:TestStatusLabel.Location = New-Object System.Drawing.Point(16, 10)
        $script:TestStatusLabel.Width = [Math]::Max(120, $w - 150)
        $script:TestRefresh.Location = New-Object System.Drawing.Point(
            [Math]::Max(120, $tsResultCard.ClientSize.Width - $script:TestRefresh.Width - 16), 8)
        $chartH = [Math]::Max(140, [Math]::Min(280, [int]($tsResultCard.ClientSize.Height * 0.42)))
        if ($script:TestChart) {
            $script:TestChart.Location = New-Object System.Drawing.Point(16, 44)
            $script:TestChart.Width = $w
            $script:TestChart.Height = $chartH
        }
        $boxY = 44 + $chartH + 8
        $script:TestResultBox.Location = New-Object System.Drawing.Point(16, $boxY)
        $script:TestResultBox.Width = $w
        $script:TestResultBox.Height = [Math]::Max(80,
            $tsResultCard.ClientSize.Height - $boxY - 16)

        $w = [Math]::Max(120, $pxLeft.ClientSize.Width - 32)
        $hintTop = [Math]::Max(340, $pxLeft.ClientSize.Height - 56 - 12)
        $script:PxHealth.Location = New-Object System.Drawing.Point(16, 198)
        $script:PxHealth.Width = $w
        $script:ConnBox.Location = New-Object System.Drawing.Point(16, 288)
        $script:ConnBox.Width = $w
        $script:ConnBox.Height = [Math]::Max(60, $hintTop - 288 - 8)
        $script:PxHint.Location = New-Object System.Drawing.Point(16, $hintTop)
        $script:PxHint.Width = $w
        $script:PxHint.Height = 56
        $w = [Math]::Max(120, $pxRight.ClientSize.Width - 32)
        $script:PxTasks.Location = New-Object System.Drawing.Point(16, 184)
        $script:PxTasks.Width = $w
        $script:PxFirewall.Location = New-Object System.Drawing.Point(16, 444)
        $script:PxFirewall.Width = $w

        $w = [Math]::Max(120, $zpRight.ClientSize.Width - 32)
        $script:ZpCurrent.Location = New-Object System.Drawing.Point(16, 40)
        $script:ZpCurrent.Width = $w

        $w = [Math]::Max(200, $ovInfo.ClientSize.Width - 32)
        $script:OvSummary.Location = New-Object System.Drawing.Point(16, 40)
        $script:OvSummary.Width = $w
        $splitY = 108
        $availH = [Math]::Max(80, $ovInfo.ClientSize.Height - $splitY - 14)
        if ($ovInfo.ClientSize.Width -ge 820) {
            $leftW = [Math]::Max(300, [int]($w * 0.46))
            $chartX = 16 + $leftW + 12
            $chartW = [Math]::Max(220, $ovInfo.ClientSize.Width - $chartX - 16)
            $script:OvInfoText.Location = New-Object System.Drawing.Point(16, $splitY)
            $script:OvInfoText.Width = $leftW
            $script:OvInfoText.Height = $availH
            if ($script:OverviewChart) {
                $script:OverviewChart.Location = New-Object System.Drawing.Point($chartX, $splitY)
                $script:OverviewChart.Size = New-Object System.Drawing.Size($chartW, $availH)
                $script:OverviewChart.Visible = $true
            }
        } else {
            $infoH = [Math]::Max(80, [int]($availH * 0.45))
            $chartY = $splitY + $infoH + 8
            $chartH = [Math]::Max(80, $ovInfo.ClientSize.Height - $chartY - 14)
            $script:OvInfoText.Location = New-Object System.Drawing.Point(16, $splitY)
            $script:OvInfoText.Width = $w
            $script:OvInfoText.Height = $infoH
            if ($script:OverviewChart) {
                $script:OverviewChart.Location = New-Object System.Drawing.Point(16, $chartY)
                $script:OverviewChart.Size = New-Object System.Drawing.Size($w, $chartH)
                $script:OverviewChart.Visible = $true
            }
        }

        foreach ($key in @($script:OvValues.Keys)) {
            $value = $script:OvValues[$key]
            $detail = $script:OvDetails[$key]
            $cw = [Math]::Max(80, $value.Parent.ClientSize.Width - 32)
            $value.Width = $cw
            $detail.Width = $cw
        }

        $script:StatusPath.Left = 526
        $script:StatusPath.Width = [Math]::Max(120,
            $statusBar.ClientSize.Width - 526 - 13)
    } catch { }
}

$zpLeft.Add_Resize({ Update-ResponsiveLayout })
$zpRight.Add_Resize({ Update-ResponsiveLayout })
$tsResultCard.Add_Resize({ Update-ResponsiveLayout; if ($script:TestChart) { $script:TestChart.Invalidate() } })
$pxLeft.Add_Resize({ Update-ResponsiveLayout })
$pxRight.Add_Resize({ Update-ResponsiveLayout })
$ovInfo.Add_Resize({ Update-ResponsiveLayout; if ($script:OverviewChart) { $script:OverviewChart.Invalidate() } })
$cardTable.Add_Resize({ Update-ResponsiveLayout })
$statusBar.Add_Resize({ Update-ResponsiveLayout })

# --------------------------------------------------------------------------
#  Инициализация
# --------------------------------------------------------------------------

# Порядок докинга на форме: Fill (0) докируется последним, затем
# нижняя/боковая/верхняя панели (больший индекс = докируется раньше).
$form.Controls.SetChildIndex($content, 0)
$form.Controls.SetChildIndex($statusBar, 1)
$form.Controls.SetChildIndex($sidebar, 2)
$form.Controls.SetChildIndex($header, 3)

Update-StrategyList

Load-GameFilterUI
Update-IpsetStatus
Update-LatestResult

# Тяжёлые проверки (задачи, брандмауэр, /health, LAN IP) выполняем уже
# после появления окна, иначе запуск выглядит как «ничего не происходит».
$script:BootTimer = New-Object System.Windows.Forms.Timer
$script:BootTimer.Interval = 150
$script:BootTimer.Add_Tick({
    $script:BootTimer.Stop()
    try { $script:BootTimer.Dispose() } catch { }
    try { Update-LogView } catch { }
    try { Update-Status } catch { }
})
$script:BootTimer.Start()

$script:StatusTimer = New-Object System.Windows.Forms.Timer
$script:StatusTimer.Interval = 5000
$script:StatusTimer.Add_Tick({ try { Update-Status } catch { } })
$script:StatusTimer.Start()

$script:ConnTimer = New-Object System.Windows.Forms.Timer
$script:ConnTimer.Interval = 400
$script:ConnTimer.Add_Tick({
    try {
        if (Test-Path -LiteralPath $script:ConnOut) {
            $text = Get-Content -LiteralPath $script:ConnOut -Raw
            if ($script:ConnBox) { $script:ConnBox.Text = $text }
            $summary = @($text -split "`r?`n" | Where-Object { $_ -match '^Итог:' }) |
                Select-Object -Last 1
            if (-not $summary) { $summary = 'Проверка завершена' }
            $script:LastConnSummary = $summary.Trim()
            $script:ConnRunning = $false
            $script:ConnTimer.Stop()
            Update-Status
        } elseif ($script:ConnProc -and $script:ConnProc.HasExited) {
            $script:ConnRunning = $false
            $script:ConnTimer.Stop()
            if ($script:ConnBox) {
                $script:ConnBox.Text = 'Проверка не удалась: скрипт завершился без результата.'
            }
        } elseif (((Get-Date) - $script:ConnStarted).TotalSeconds -gt 60) {
            $script:ConnRunning = $false
            $script:ConnTimer.Stop()
            if ($script:ConnBox) { $script:ConnBox.Text = 'Таймаут проверки соединения (60 с).' }
        }
    } catch { }
})

$script:TestTimer = New-Object System.Windows.Forms.Timer
$script:TestTimer.Interval = 5000
$script:TestTimer.Add_Tick({
    try {
        $running = Get-TestRunning
        if ($running) {
            $script:TestWasRunning = $true
            if ($script:TestStatusLabel) {
                $script:TestStatusLabel.Text = 'Тесты выполняются... Результат загрузится автоматически.'
            }
        } elseif ($script:TestWasRunning) {
            $script:TestWasRunning = $false
            if ($script:TestStatusLabel) {
                $script:TestStatusLabel.Text = 'Тесты завершены. Результат загружен.'
            }
            Update-LatestResult
        }
    } catch { }
})
$script:TestTimer.Start()

$script:LogTimer = New-Object System.Windows.Forms.Timer
$script:LogTimer.Interval = 3000
$script:LogTimer.Add_Tick({
    if ($script:Tabs['logs'].Visible -and $script:LogAuto.Checked) { Update-LogView }
})
$script:LogTimer.Start()


# --------------------------------------------------------------------------
#  Глобальная горячая клавиша: Ctrl+Alt+Z — вкл/выкл обход (zapret)
# --------------------------------------------------------------------------

$script:HotkeyRegistered = $false
try {
    if (-not ('ZapretHotkeyNative' -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class ZapretHotkeyNative {
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool UnregisterHotKey(IntPtr hWnd, int id);
}
"@ -ErrorAction Stop
    }
} catch { }
try {
    if (-not ('ZapretHotkeyFilter' -as [type])) {
        Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @"
using System;
using System.Windows.Forms;
public class ZapretHotkeyFilter : IMessageFilter {
    public const int WM_HOTKEY = 0x0312;
    public static event Action<int> HotkeyPressed;
    public bool PreFilterMessage(ref Message m) {
        if (m.Msg == WM_HOTKEY) {
            try { var h = HotkeyPressed; if (h != null) h(m.WParam.ToInt32()); } catch { }
            return true;
        }
        return false;
    }
}
"@ -ErrorAction Stop
    }
} catch { }
$script:HotkeyFilter = $null
try { $script:HotkeyFilter = New-Object ZapretHotkeyFilter } catch { }
try {
    [ZapretHotkeyFilter]::add_HotkeyPressed({
        param($id)
        try { if ($id -eq 1) { Toggle-ZapretBypass } } catch { }
    })
} catch { }

function Update-HotkeyRegistration {
    try {
        if ($script:HotkeyRegistered) {
            try { [ZapretHotkeyNative]::UnregisterHotKey($form.Handle, 1) | Out-Null } catch { }
            $script:HotkeyRegistered = $false
        }
        if ([bool]$script:Settings.HotkeyToggleZapret -and ('ZapretHotkeyNative' -as [type])) {
            # MOD_CONTROL(2) | MOD_ALT(1) = 3, VK_Z = 0x5A
            $ok = [ZapretHotkeyNative]::RegisterHotKey($form.Handle, 1, 3, 0x5A)
            $script:HotkeyRegistered = [bool]$ok
        }
    } catch { }
}

# --------------------------------------------------------------------------
#  Значок в трее и восстановление окна
# --------------------------------------------------------------------------

$script:ReallyExit = $false
$script:TrayIcon = New-Object System.Windows.Forms.NotifyIcon
try {
    if ($form.Icon) { $script:TrayIcon.Icon = $form.Icon }
    else { $script:TrayIcon.Icon = [System.Drawing.SystemIcons]::Application }
} catch {
    $script:TrayIcon.Icon = [System.Drawing.SystemIcons]::Application
}
$script:TrayIcon.Text = 'ZAPRET CONTROL'
$script:TrayIcon.Visible = $true

function Show-MainWindow {
    try {
        $form.ShowInTaskbar = $true
        $form.Show()
        if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) {
            $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
        }
        $form.Activate()
        $form.BringToFront()
    } catch { }
}

function Hide-ToTray {
    try {
        Save-GuiSettings
        $form.Hide()
        $form.ShowInTaskbar = $false
    } catch { }
}

$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$trayOpen = $trayMenu.Items.Add('Открыть окно')
$script:TrayToggleBypass = $trayMenu.Items.Add('Обход: ... (Ctrl+Alt+Z)')
$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
$trayStart = $trayMenu.Items.Add('Запустить всё')
$trayStop = $trayMenu.Items.Add('Остановить всё')
$trayRestart = $trayMenu.Items.Add('Перезапустить всё')
$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
$trayCheck = $trayMenu.Items.Add('Проверить соединение')
$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
$trayExit = $trayMenu.Items.Add('Выход')
$script:TrayIcon.ContextMenuStrip = $trayMenu

$trayOpen.Add_Click({ Show-MainWindow })
$script:TrayToggleBypass.Add_Click({ Toggle-ZapretBypass })
$trayStart.Add_Click({ Invoke-VisibleBat (Join-Path $script:ProxyDir 'start-all.bat') })
$trayStop.Add_Click({ Invoke-VisibleBat (Join-Path $script:ProxyDir 'stop-all.bat') })
$trayRestart.Add_Click({ Invoke-VisibleBat (Join-Path $script:ProxyDir 'restart-all.bat') })
$trayCheck.Add_Click({
    Show-MainWindow
    Switch-Tab 'proxy'
    Start-ConnectionTest
})
$trayExit.Add_Click({
    $script:ReallyExit = $true
    try { $script:TrayIcon.Visible = $false } catch { }
    $form.Close()
})
$script:TrayIcon.Add_DoubleClick({ Show-MainWindow })
$script:TrayIcon.Add_MouseClick({
    param($sender, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Show-MainWindow }
})

$form.Add_Resize({
    try {
        Update-ResponsiveLayout
        if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized -and
            $script:Settings.MinimizeToTray) {
            Hide-ToTray
        }
    } catch { }
})

$form.Add_Shown({
    Update-ResponsiveLayout
    $startTab = if ($script:Tabs.ContainsKey($script:Settings.Tab)) {
        $script:Settings.Tab
    } else {
        'overview'
    }
    Switch-Tab $startTab
    if ([bool]$script:Settings.AutoCheckAppUpdates) { Start-AppUpdateCheckAsync }
    try { if ($script:HotkeyFilter) { [System.Windows.Forms.Application]::AddMessageFilter($script:HotkeyFilter) } } catch { }
    try { Update-HotkeyRegistration } catch { }
    try { Update-BypassUiState } catch { }
    try {
        Add-Type -Namespace Native -Name DarkTitle -MemberDefinition @'
[DllImport("dwmapi.dll")]
public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);
'@ -ErrorAction Stop
        $value = 1
        [void][Native.DarkTitle]::DwmSetWindowAttribute($form.Handle, 20, [ref]$value, 4)
        [void][Native.DarkTitle]::DwmSetWindowAttribute($form.Handle, 19, [ref]$value, 4)
    } catch { }
})

$form.Add_FormClosing({
    param($sender, $e)
    if (-not $script:ReallyExit -and -not $UiTest -and
        $script:Settings.MinimizeToTray -and
        $e.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing) {
        $e.Cancel = $true
        Hide-ToTray
        return
    }
    try { if ($script:HotkeyRegistered) { [ZapretHotkeyNative]::UnregisterHotKey($form.Handle, 1) | Out-Null } } catch { }
    try { if ($script:HotkeyFilter) { [System.Windows.Forms.Application]::RemoveMessageFilter($script:HotkeyFilter) } } catch { }
    $script:StatusTimer.Stop()
    $script:LogTimer.Stop()
    if ($script:ConnTimer) { $script:ConnTimer.Stop() }
    if ($script:TestTimer) { $script:TestTimer.Stop() }
    Save-GuiSettings
    try {
        $script:TrayIcon.Visible = $false
        $script:TrayIcon.Dispose()
    } catch { }
})

if ($UiTest) {
    $form.Add_Shown({
        Start-Sleep -Milliseconds 400
        $report = New-Object System.Collections.Generic.List[string]
        [void]$report.Add("form client=$($form.ClientSize.Width)x$($form.ClientSize.Height)")
        $commonPairs = @(
            @('header', $header), @('sidebar', $sidebar),
            @('status', $statusBar), @('content', $content)
        )
        foreach ($pair in $commonPairs) {
            $c = $pair[1]
            [void]$report.Add(("{0}: x={1} y={2} w={3} h={4}" -f `
                $pair[0], $c.Left, $c.Top, $c.Width, $c.Height))
        }
        $tabPairs = @{
            overview = @(
                @('cards', $cardTable), @('quick', $quick), @('info', $ovInfo),
                @('card.proxy.value', $script:OvValues['proxy']),
                @('card.tasks.value', $script:OvValues['tasks']),
                @('summary', $script:OvSummary), @('infoText', $script:OvInfoText))
            proxy = @(
                @('left', $pxLeft), @('right', $pxRight),
                @('conn', $script:ConnBox), @('hint', $script:PxHint))
            zapret = @(
                @('left', $zpLeft), @('right', $zpRight),
                @('filter', $script:StrategyFilter), @('list', $script:StrategyList),
                @('detail', $script:StrategyDetail))
            tests = @(
                @('top', $tsTop), @('card', $tsResultCard),
                @('result', $script:TestResultBox))
            logs = @(
                @('top', $lgTop), @('box', $script:LogBox),
                @('filter', $script:LogFilter))
            tools = @(
                @('top', $tlTop), @('box', $script:DiagBox))
            updates = @(
                @('top', $updTop), @('info', $updInfo), @('notes', $updNotesCard),
                @('status', $script:UpdStatusLabel), @('notesBox', $script:UpdNotes))
        }
        $dumpTabs = {
            param([string]$prefix)
            $content.PerformLayout()
            foreach ($key in @('overview', 'proxy', 'zapret', 'tests', 'updates', 'logs', 'tools')) {
                Switch-Tab $key
                $panel = $script:Tabs[$key]
                $content.PerformLayout()
                $panel.PerformLayout()
                Update-ResponsiveLayout
                [System.Windows.Forms.Application]::DoEvents()
                Start-Sleep -Milliseconds 120
                [void]$report.Add("${prefix}tab $key size=$($panel.Width)x$($panel.Height)")
                foreach ($pair in $tabPairs[$key]) {
                    $c = $pair[1]
                    $flags = @()
                    if ($c.Right -gt $c.Parent.ClientSize.Width) { $flags += 'OVERFLOW-X' }
                    if ($c.Bottom -gt $c.Parent.ClientSize.Height) { $flags += 'OVERFLOW-Y' }
                    if ($c.Width -le 0 -or $c.Height -le 0) { $flags += 'ZERO' }
                    $suffix = if ($flags.Count) { '  <-- ' + ($flags -join ',') } else { '' }
                    [void]$report.Add(("  {0}.{1}: x={2} y={3} w={4} h={5} parent={6}x{7}{8}" -f `
                        $key, $pair[0], $c.Left, $c.Top, $c.Width, $c.Height,
                        $c.Parent.ClientSize.Width, $c.Parent.ClientSize.Height, $suffix))
                }
                $flowForTab = @{
                    overview = @('quick', $quick)
                    tests    = @('tests.top', $tsTop)
                    logs     = @('logs.top', $lgTop)
                    tools    = @('tools.top', $tlTop)
                }
                if ($flowForTab.ContainsKey($key)) {
                    $flowPair = $flowForTab[$key]
                    $flow = $flowPair[1]
                    $maxBottom = 0
                    foreach ($child in $flow.Controls) {
                        $maxBottom = [Math]::Max($maxBottom, $child.Bottom + $child.Margin.Bottom)
                    }
                    $flag = if ($maxBottom -gt $flow.ClientSize.Height) {
                        '  <-- FLOW-OVERFLOW'
                    } else {
                        ''
                    }
                    [void]$report.Add(("  flow {0}: height={1} contentBottom={2}{3}" -f `
                        $flowPair[0], $flow.ClientSize.Height, $maxBottom, $flag))
                }
            }
        }
        & $dumpTabs ''
        $form.Size = $form.MinimumSize
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 200
        [void]$report.Add("resized to minimum: client=$($form.ClientSize.Width)x$($form.ClientSize.Height)")
        & $dumpTabs 'min.'
        $report | Set-Content -LiteralPath (Join-Path $script:ProxyDir 'ui-test.txt') -Encoding UTF8
        $form.Close()
        [Environment]::Exit(0)
    })
}

$form.KeyPreview = $true
$form.Add_KeyDown({
    param($sender, $eventArgs)
    try {
        if ($eventArgs.KeyCode -eq [System.Windows.Forms.Keys]::F5) {
            Update-Status
            if ($script:Tabs['logs'].Visible) { Update-LogView }
            $eventArgs.Handled = $true
            return
        }
        if ($eventArgs.Control) {
            $map = @{
                'D1' = 'overview'; 'D2' = 'proxy'; 'D3' = 'zapret'
                'D4' = 'tests';    'D5' = 'logs';  'D6' = 'tools';
                'D7' = 'updates'
            }
            $key = [string]$eventArgs.KeyCode
            if ($map.ContainsKey($key)) {
                Switch-Tab $map[$key]
                $eventArgs.Handled = $true
            }
        }
    } catch { }
})

try {
    [void]$form.ShowDialog()
} catch {
    $message = '{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $_.Exception.ToString()
    try {
        Set-Content -LiteralPath (Join-Path $script:ProxyDir 'gui-startup-err.txt') `
            -Value $message -Encoding UTF8
    } catch { }
    try {
        [Windows.Forms.MessageBox]::Show(
            "Не удалось открыть окно ZAPRET CONTROL:`r`n$($_.Exception.Message)`r`n`r`n" +
            "Подробности: proxy\gui-startup-err.txt",
            'ZAPRET CONTROL', 'OK', 'Error') | Out-Null
    } catch { }
}

# ps2exe noConsole keeps the host alive after the form closes; force exit.
# (Также не пишем в output-поток: в noConsole-сборке это может блокировать.)
[Environment]::Exit(0)
