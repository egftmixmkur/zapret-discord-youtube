$ErrorActionPreference = 'SilentlyContinue'
# Locale-independent LAN IP detection (default-route interface first)
$ip = $null
try {
    $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop |
        Sort-Object RouteMetric | Select-Object -First 1
    $ip = (Get-NetIPAddress -InterfaceIndex $route.InterfaceIndex -AddressFamily IPv4 |
        Select-Object -First 1).IPAddress
} catch {}
if (-not $ip) {
    $ip = Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object { $_.IPAddress -notlike '169.254*' -and $_.IPAddress -ne '127.0.0.1' } |
        Select-Object -First 1 -ExpandProperty IPAddress
}
if (-not $ip) { $ip = 'UNKNOWN' }
Write-Output $ip
