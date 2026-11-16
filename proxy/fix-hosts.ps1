$ErrorActionPreference = 'SilentlyContinue'
# Remove broken hosts entries: old "ZapretGUI" mapped Discord domains to
# 23.227.38.74 (a Shopify IP that cannot serve Discord TLS certificates),
# which breaks Discord web/desktop on this PC. Real Discord IPs resolve
# fine via provider DNS, and zapret handles DPI. Idempotent.
# Backup is saved once as hosts.zapret-backup.

$hosts = Join-Path $env:windir 'System32\drivers\etc\hosts'
$pattern = '^\s*23\.227\.38\.74\s+(discord\.com|gateway\.discord\.gg|updates\.discord\.com|cdn\.discordapp\.com|cdn\.prod\.website-files\.com|status\.discord\.com)\s*$'

$lines = Get-Content -LiteralPath $hosts
if (-not $lines) { exit 0 }

$bad = @($lines | Where-Object { $_ -match $pattern })
if ($bad.Count -eq 0) { exit 0 }

$backup = "$hosts.zapret-backup"
if (-not (Test-Path $backup)) {
    Copy-Item -LiteralPath $hosts -Destination $backup -Force
}

($lines | Where-Object { $_ -notmatch $pattern }) |
    Set-Content -LiteralPath $hosts -Encoding Ascii

Write-Output "[OK] removed $($bad.Count) broken hosts entries (backup: hosts.zapret-backup)"
