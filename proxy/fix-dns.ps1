$ErrorActionPreference = 'Continue'
# Switch this PC to DNS-over-HTTPS (Google + Cloudflare) via Windows native DoH.
# Reason: the provider hijacks ALL plain UDP/53 DNS (even queries addressed to
# 8.8.8.8 are answered with fake NXDOMAIN for blocked sites like youtube).
# DoH travels over TCP 443 through zapret and cannot be hijacked.
#
# IMPORTANT: 8.8.8.8 / 1.1.1.1 etc. are BUILT-IN DoH server entries with
# AutoUpgrade=False (plain UDP). Add-DnsClientDohServerAddress silently fails
# for already-registered addresses, so we Remove-then-Add with AutoUpgrade=$true
# (netsh fallback). Idempotent; progress is logged to setup.log.

$log = Join-Path $PSScriptRoot 'setup.log'
function Log($m) {
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') fix-dns: $m" |
        Out-File -FilePath $log -Append -Encoding UTF8
}

# ---- 1. force AutoUpgrade on the DoH server entries ----
$servers = @(
    @{ ip = '8.8.8.8';              tpl = 'https://dns.google/dns-query' },
    @{ ip = '1.1.1.1';              tpl = 'https://cloudflare-dns.com/dns-query' },
    @{ ip = '2001:4860:4860::8888'; tpl = 'https://dns.google/dns-query' },
    @{ ip = '2606:4700:4700::1111'; tpl = 'https://cloudflare-dns.com/dns-query' }
)
foreach ($s in $servers) {
    Remove-DnsClientDohServerAddress -ServerAddress $s.ip -ErrorAction SilentlyContinue
    $err = ''
    try {
        Add-DnsClientDohServerAddress -ServerAddress $s.ip -DohTemplate $s.tpl `
            -AutoUpgrade $true -AllowFallbackToUdp $false -ErrorAction Stop | Out-Null
    } catch { $err = $_.Exception.Message }
    $st = Get-DnsClientDohServerAddress -ServerAddress $s.ip -ErrorAction SilentlyContinue
    $au = if ($st) { [bool]$st.AutoUpgrade } else { $false }
    if (-not $au) {
        # PowerShell cmdlet refused - netsh fallback (updates entry in place)
        netsh dns add server address=$($s.ip) dohtemplate=$($s.tpl) autoupgrade=yes allowfallbacktoudp=no |
            Out-Null
        $st = Get-DnsClientDohServerAddress -ServerAddress $s.ip -ErrorAction SilentlyContinue
        $au = if ($st) { [bool]$st.AutoUpgrade } else { $false }
    }
    Log "doh server $($s.ip): autoupgrade=$au $($err)"
    if (-not $au) { Log "WARNING: could not enable DoH for $($s.ip)" }
}

# ---- 2. pick the active adapter ----
$if = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.HardwareInterface } |
    Select-Object -First 1
if (-not $if) { $if = Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1 }
if (-not $if) {
    Log 'no active network adapter - DNS was not changed'
    Write-Output '[!] No active network adapter - DNS was not changed'
    exit 1
}
$alias = $if.Name
Log "adapter: $alias (ifIndex $($if.ifIndex))"

# ---- 3. static IPv4 DNS = DoH servers (replaces router 192.168.1.x) ----
Set-DnsClientServerAddress -InterfaceAlias $alias -ServerAddresses '8.8.8.8','1.1.1.1'
Log "IPv4 DNS set to 8.8.8.8, 1.1.1.1 (DoH)"

# ---- 4. IPv6: replace router RA DNS (fe80::1 answers fake NXDOMAIN) ----
netsh interface ipv6 set dnsservers name="$alias" source=static address=none | Out-Null
Start-Sleep -Milliseconds 300
$v6 = (Get-DnsClientServerAddress -InterfaceAlias $alias -AddressFamily IPv6).ServerAddresses
if ($v6 -contains 'fe80::1' -or -not $v6) {
    Set-DnsClientServerAddress -InterfaceAlias $alias `
        -ServerAddresses '2001:4860:4860::8888','2606:4700:4700::1111'
    Log 'IPv6 DNS forced to Google/Cloudflare DoH addresses'
} else {
    Log "IPv6 DNS left as: $($v6 -join ',')"
}

# ---- 5. flush caches (remove cached fake NXDOMAIN) ----
Clear-DnsClientCache
ipconfig /flushdns | Out-Null
Log 'DNS caches flushed'

# ---- 6. verify through the real system resolver path ----
Start-Sleep -Seconds 2
foreach ($name in 'www.youtube.com','discord.com') {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $ips = [System.Net.Dns]::GetHostAddresses($name) |
            ForEach-Object { $_.IPAddressToString }
        Log "RESOLVE $name -> $($ips -join ',') [$($sw.ElapsedMilliseconds) ms]"
        Write-Output "[OK] $name -> $($ips -join ',')"
    } catch {
        Log "RESOLVE $name FAILED [$($sw.ElapsedMilliseconds) ms]"
        Write-Output "[!] $name did NOT resolve - see setup.log"
    }
}
