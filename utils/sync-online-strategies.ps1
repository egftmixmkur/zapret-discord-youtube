param(
    [string]$Source = 'Flowseal',
    [string]$TargetDir = '',
    [switch]$Remove,
    [switch]$ListOnly
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$root = if ($TargetDir) { $TargetDir } else { Split-Path -Parent $PSScriptRoot }
if (-not (Test-Path -LiteralPath $root)) { throw "Target dir not found: $root" }

$sources = @{
    'Flowseal' = @{
        Label = 'Flowseal'
        Api   = 'https://api.github.com/repos/Flowseal/zapret-discord-youtube/contents?ref=main'
        RawBase = $null
    }
    'bol-van' = @{
        Label = 'bol-van'
        Api   = 'https://api.github.com/repos/bol-van/zapret-discord-youtube/contents?ref=master'
        RawBase = $null
    }
}

if (-not $sources.ContainsKey($Source)) {
    $Source = 'Flowseal'
}
$cfg = $sources[$Source]
$marker = "(Net $($cfg.Label))"

# Remove previously imported strategies for this source
$existing = @(Get-ChildItem -LiteralPath $root -Filter 'general*.bat' -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like "*$marker*" })
if ($Remove) {
    $removed = 0
    foreach ($f in $existing) {
        try { Remove-Item -LiteralPath $f.FullName -Force; $removed++ } catch { }
    }
    Write-Output "REMOVED=$removed"
    exit 0
}

$headers = @{ 'User-Agent' = 'ZapretControl-StrategySync/1.1'; 'Accept' = 'application/vnd.github+json' }
try {
    $items = Invoke-RestMethod -Uri $cfg.Api -Headers $headers -TimeoutSec 25 -UseBasicParsing -ErrorAction Stop
} catch {
    $msg = $_.Exception.Message
    throw "Failed to fetch strategy list from $($cfg.Label): $msg"
}
if ($items -isnot [System.Array]) { $items = @($items) }
$bats = @($items | Where-Object { $_.type -eq 'file' -and $_.name -like 'general*.bat' -and $_.download_url })
if ($bats.Count -eq 0) {
    throw "No general*.bat strategies found from $($cfg.Label). The source may be unavailable or rate-limited."
}

if ($ListOnly) {
    $bats | ForEach-Object { $_.name }
    exit 0
}

# Clean previous imports from this source to avoid stale renamed leftovers
foreach ($f in $existing) { try { Remove-Item -LiteralPath $f.FullName -Force } catch { } }

$downloaded = 0
$failed = 0
$names = New-Object System.Collections.Generic.List[string]
foreach ($b in $bats) {
    $name = [string]$b.name
    $url = [string]$b.download_url
    if (-not $url) { $failed++; continue }
    $base = [IO.Path]::GetFileNameWithoutExtension($name)
    if ($base -ieq 'general') {
        $outName = "general $marker.bat"
    } else {
        $rest = $base.Substring(7).Trim() # after 'general'
        if ($rest) { $outName = "general $marker $rest.bat" } else { $outName = "general $marker.bat" }
    }
    $outPath = Join-Path $root $outName
    try {
        $tmp = "$outPath.tmp"
        Invoke-WebRequest -Uri $url -OutFile $tmp -Headers @{ 'User-Agent' = 'ZapretControl-StrategySync/1.1' } -TimeoutSec 30 -UseBasicParsing -ErrorAction Stop
        $content = Get-Content -LiteralPath $tmp -Raw -ErrorAction SilentlyContinue
        # basic sanity: strategy .bat should reference winws and contain desync/filters
        if ($content -and ($content -match 'winws\.exe' -or $content -match '--dpi-desync' -or $content -match 'wf-tcp')) {
            Move-Item -LiteralPath $tmp -Destination $outPath -Force
            $downloaded++
            $names.Add($outName)
        } else {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            $failed++
        }
    } catch {
        try { Remove-Item -LiteralPath "$outPath.tmp" -Force -ErrorAction SilentlyContinue } catch { }
        $failed++
    }
}

$result = [ordered]@{
    source = $Source
    downloaded = $downloaded
    failed = $failed
    total = $bats.Count
    files = $names
}
$result | ConvertTo-Json -Depth 5
