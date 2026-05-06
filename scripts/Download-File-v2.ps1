# ============================================================
# Download helper v2 - iex-compatible, paste-safe
# Usage (file):    .\dl.ps1
# Usage (remote):  iwr "https://raw.githubusercontent.com/<user>/<repo>/main/dl.ps1" | iex
# ============================================================

# TLS 1.2 - required for many endpoints when running under PS 5.1
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Kill the IWR progress bar - 30-50x faster on large files
$ProgressPreference = 'SilentlyContinue'

# --- Inputs ---
$url = Read-Host "Paste the download URL"
if ([string]::IsNullOrWhiteSpace($url)) {
    Write-Host "No URL provided. Aborting." -ForegroundColor Red; return
}

try {
    $uri = [uri]$url
    if ($uri.Scheme -notin 'http','https') { throw "Only http/https supported." }
} catch {
    Write-Host "Invalid URL: $($_.Exception.Message)" -ForegroundColor Red; return
}

$defaultDir = "C:\Users\Public\Downloads"
$dest = Read-Host "Destination file or folder (Enter = $defaultDir)"

# Filename derived from URL path - strips ?query and #fragment automatically
$urlFile = [System.IO.Path]::GetFileName($uri.LocalPath)

# Resolve $dest. No top-level elseif so console paste line-by-line works.
if ([string]::IsNullOrWhiteSpace($dest)) { $dest = $defaultDir }

$looksLikeFolder = (Test-Path $dest -PathType Container) -or $dest.EndsWith('\') -or $dest.EndsWith('/')
if ($looksLikeFolder) {
    if (-not $urlFile) { $urlFile = Read-Host "Cannot infer filename from URL. Enter filename" }
    $dest = Join-Path $dest $urlFile
}

$expectedHash = (Read-Host "Expected SHA256 (Enter to skip)").Trim()

# Ensure target folder exists
$destDir = Split-Path $dest -Parent
if ($destDir -and -not (Test-Path $destDir)) {
    New-Item -ItemType Directory -Path $destDir -Force | Out-Null
}

# Overwrite check
if (Test-Path $dest) {
    $f = Get-Item $dest
    $ans = Read-Host "Exists: $([math]::Round($f.Length/1MB,2)) MB, $($f.LastWriteTime). Overwrite? [y/N]"
    if ($ans -notmatch '^(y|yes)$') { Write-Host "Aborted." -ForegroundColor Yellow; return }
}

Write-Host "Source : $url"  -ForegroundColor Cyan
Write-Host "Target : $dest" -ForegroundColor Cyan

# --- Download ---
# Prefer curl.exe: better TLS fingerprint, less Cloudflare/WAF friction, real retry logic.
# Fall back to Invoke-WebRequest only if curl.exe isn't on PATH.
$curl = (Get-Command curl.exe -ErrorAction SilentlyContinue).Path
$ua   = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36'

$sw = [Diagnostics.Stopwatch]::StartNew()
$downloadOk = $false

if ($curl) {
    Write-Host "Using : curl.exe" -ForegroundColor DarkGray
    # -L follow redirects, --fail return non-zero on HTTP errors, --retry on transient errors,
    # -A user-agent, -o output, --create-dirs safety
    & $curl -L --fail --retry 3 --retry-delay 2 --connect-timeout 15 `
            -A $ua `
            -H 'Accept: */*' `
            -H 'Accept-Language: en-US,en;q=0.9' `
            --create-dirs `
            -o $dest $url
    if ($LASTEXITCODE -eq 0) {
        $downloadOk = $true
    } else {
        Write-Host "curl failed (exit $LASTEXITCODE). Falling back to Invoke-WebRequest..." -ForegroundColor Yellow
        if (Test-Path $dest) { try { Remove-Item $dest -Force } catch {} }
    }
}

if (-not $downloadOk) {
    Write-Host "Using : Invoke-WebRequest" -ForegroundColor DarkGray
    try {
        Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing -MaximumRedirection 5 `
            -Headers @{
                'User-Agent'       = $ua
                'Accept'           = '*/*'
                'Accept-Language'  = 'en-US,en;q=0.9'
            } -ErrorAction Stop
        $downloadOk = $true
    } catch {
        Write-Host "FAILED: $($_.Exception.Message)" -ForegroundColor Red
        if (Test-Path $dest) { try { Remove-Item $dest -Force } catch {} }
        return
    }
}
$sw.Stop()

if (-not (Test-Path $dest)) {
    Write-Host "FAILED: no file written." -ForegroundColor Red; return
}

$size   = (Get-Item $dest).Length
$sizeMB = [math]::Round($size / 1MB, 2)
$secs   = [math]::Round($sw.Elapsed.TotalSeconds, 1)
$rate   = if ($sw.Elapsed.TotalSeconds -gt 0) { [math]::Round($sizeMB / $sw.Elapsed.TotalSeconds, 2) } else { 0 }
Write-Host "Done   : $sizeMB MB in ${secs}s ($rate MB/s)" -ForegroundColor Green

# --- Optional hash verification ---
if ($expectedHash) {
    $actual = (Get-FileHash -Path $dest -Algorithm SHA256).Hash
    if ($actual -ieq $expectedHash) {
        Write-Host "SHA256 OK: $actual" -ForegroundColor Green
    } else {
        Write-Host "SHA256 MISMATCH - file is suspect" -ForegroundColor Red
        Write-Host " Expected: $expectedHash"
        Write-Host " Actual  : $actual"
    }
}
