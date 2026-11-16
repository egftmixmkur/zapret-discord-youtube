param(
    [int]$HttpPort = 8080,
    [int]$SocksPort = 1080,
    [string]$OutFile = '',
    [switch]$NoDirect
)

# Проверка LAN-прокси и zapret без прав администратора.
# Проверяет оба порта, рукопожатие SOCKS5, /health, доступ к YouTube и
# Discord через прокси, а также (по умолчанию) прямое подключение для
# сравнения. Результат пишется в -OutFile атомарно (tmp + move).

$ErrorActionPreference = 'Continue'
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch { }

$script:Lines = New-Object System.Collections.Generic.List[string]

function Add-Line([string]$text) {
    [void]$script:Lines.Add($text)
}

function Test-TcpPort([int]$port) {
    foreach ($addr in @('127.0.0.1', '::1')) {
        $client = $null
        try {
            $client = New-Object System.Net.Sockets.TcpClient
            $iar = $client.BeginConnect($addr, $port, $null, $null)
            if ($iar.AsyncWaitHandle.WaitOne(500) -and $client.Connected) {
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

function Test-Socks5([int]$port) {
    $client = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect('127.0.0.1', $port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne(1200)) { return $false }
        $client.EndConnect($iar)
        $stream = $client.GetStream()
        $stream.ReadTimeout = 2000
        $stream.WriteTimeout = 2000
        $request = [byte[]](0x05, 0x01, 0x00)   # SOCKS5, one method: no auth
        $stream.Write($request, 0, $request.Length)
        $response = New-Object byte[] 2
        $read = $stream.Read($response, 0, 2)
        return ($read -eq 2 -and $response[0] -eq 0x05)
    } catch {
        return $false
    } finally {
        if ($client) { $client.Close() }
    }
}

function Test-Url([string]$url, [switch]$ViaProxy, [int]$Port = 8080) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $params = @{
            Uri             = $url
            TimeoutSec      = 15
            UseBasicParsing = $true
            ErrorAction     = 'Stop'
        }
        if ($ViaProxy) { $params['Proxy'] = "http://127.0.0.1:$Port" }
        $response = Invoke-WebRequest @params
        $watch.Stop()
        return [pscustomobject]@{
            Ok    = $true
            Ms    = [int]$watch.ElapsedMilliseconds
            Code  = [int]$response.StatusCode
            Error = ''
        }
    } catch {
        $watch.Stop()
        $code = 0
        try {
            if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
                $code = [int]$_.Exception.Response.StatusCode
            }
        } catch { }
        return [pscustomobject]@{
            Ok    = $false
            Ms    = [int]$watch.ElapsedMilliseconds
            Code  = $code
            Error = $_.Exception.Message
        }
    }
}

Add-Line '=== ПРОВЕРКА СОЕДИНЕНИЯ ZAPRET ==='
Add-Line ("Время: " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Add-Line ''

$httpOk = Test-TcpPort $HttpPort
$socksOk = Test-TcpPort $SocksPort
$socksHandshake = if ($socksOk) { Test-Socks5 $SocksPort } else { $false }

Add-Line ("{0} HTTP-прокси 127.0.0.1:{1}" -f $(if ($httpOk) { '[OK]' } else { '[X] ' }), $HttpPort)
Add-Line ("{0} SOCKS5 127.0.0.1:{1}{2}" -f `
    $(if ($socksOk) { '[OK]' } else { '[X] ' }), $SocksPort, `
    $(if ($socksHandshake) { ' (рукопожатие OK)' } elseif ($socksOk) { ' (порт открыт, рукопожатие не удалось)' } else { '' }))

$health = $null
if ($httpOk) {
    try {
        $health = Invoke-RestMethod -Uri "http://127.0.0.1:$HttpPort/health" `
            -TimeoutSec 4 -UseBasicParsing -ErrorAction Stop
    } catch { }
}
if ($health) {
    Add-Line ("[OK] /health: v{0}, uptime {1} c" -f $health.version, $health.uptime)
    if ($health.doh) {
        Add-Line ("     DoH: {0} сервера" -f @($health.doh).Count)
    }
} else {
    Add-Line '[!]  /health не отвечает (прокси старой версии или выключен)'
}
Add-Line ''

$targets = @(
    @{ Name = 'YouTube'; Url = 'https://www.youtube.com/generate_204' },
    @{ Name = 'Discord'; Url = 'https://discord.com/api/v9/gateway' }
)

$proxyOkCount = 0
foreach ($target in $targets) {
    $result = Test-Url -Url $target.Url -ViaProxy -Port $HttpPort
    if ($result.Ok) {
        $proxyOkCount++
        Add-Line ("[OK] {0} через прокси: {1} мс (HTTP {2})" -f `
            $target.Name, $result.Ms, $result.Code)
    } else {
        Add-Line ("[X]  {0} через прокси: ошибка за {1} мс — {2}" -f `
            $target.Name, $result.Ms, $result.Error)
    }
}

if (-not $NoDirect) {
    Add-Line ''
    $direct = Test-Url -Url $targets[0].Url
    if ($direct.Ok) {
        Add-Line ("[i]  Прямое подключение (без прокси): {0} мс (HTTP {1})" -f `
            $direct.Ms, $direct.Code)
    } else {
        Add-Line ("[i]  Прямое подключение недоступно: {0}" -f $direct.Error)
    }
}

Add-Line ''
if ($httpOk -and $socksOk -and $proxyOkCount -gt 0) {
    Add-Line ("Итог: прокси работает, проверок через прокси успешно: {0}/{1}." -f `
        $proxyOkCount, $targets.Count)
    $exitCode = 0
} elseif ($httpOk -or $socksOk) {
    Add-Line ("Итог: прокси отвечает частично, проверок успешно: {0}/{1}." -f `
        $proxyOkCount, $targets.Count)
    $exitCode = 1
} else {
    Add-Line 'Итог: прокси не запущен (порты закрыты). Нажмите «Запустить всё».'
    $exitCode = 2
}

$text = ($script:Lines -join "`r`n") + "`r`n"
if ($OutFile) {
    try {
        $tmp = "$OutFile.tmp"
        [IO.File]::WriteAllText($tmp, $text, (New-Object System.Text.UTF8Encoding($true)))
        Move-Item -LiteralPath $tmp -Destination $OutFile -Force
    } catch { }
} else {
    $text
}

exit $exitCode
