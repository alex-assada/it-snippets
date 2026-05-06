# ============================================================
# Download helper v3 - parameterized, iex-compatible, paste-safe
#
# Interactive (file):
#   .\dl.ps1
#
# Interactive (remote one-liner):
#   iwr "https://raw.githubusercontent.com/<user>/<repo>/main/dl.ps1" -useb | iex
#
# Parameterized (file):
#   .\dl.ps1 -Url "https://example.com/file.exe"
#   .\dl.ps1 -Url "https://example.com/file.exe" -Dest "C:\Tools" -Force
#   .\dl.ps1 -Url "https://example.com/file.exe" -Hash "ABC123..." -NonInteractive
#
# Parameterized (remote - scriptblock pattern, since `iwr | iex` cannot pass args):
#   & ([scriptblock]::Create((iwr "https://raw.git.../dl.ps1" -useb).Content)) -Url "..." -Force
#
# Parameters:
#   -Url <string>       URL to download
#   -Dest <string>      Destination file OR folder. If folder, URL filename is appended.
#                       Default: C:\Users\Public\Downloads\<filename-from-url>
#   -Hash <string>      Expected SHA256 to verify against
#   -NoHash             Skip the SHA256 prompt entirely (no verification)
#   -Force              Overwrite existing file without confirmation
#   -NonInteractive     No prompts at all. Implies -NoHash and -Force. Requires -Url.
# ============================================================

param(
    [string]$Url,
    [string]$Dest,
    [string]$Hash,
    [switch]$NoHash,
    [switch]$Force,
    [switch]$NonInteractive
)

# TLS 1.2 - required for many endpoints when running under PS 5.1
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Kill the IWR progress bar - 30-50x faster on large files
$ProgressPreference = 'SilentlyContinue'

# -NonInteractive is a superset switch
if ($NonInteractive) { $NoHash = $true; $Force = $true }

# --- URL ---
if (-not $Url) {
    if ($NonInteractive) {
        Write-Host "FATAL: -Url is required when -NonInteractive is set." -ForegroundColor Red; return
    }
    $Url = Read-Host "Paste the download URL"
}
if ([string]::IsNullOrWhiteSpace($Url)) {
    Write-Host "No URL provided. Aborting." -ForegroundColor Red; return
}

try {
    $uri = [uri]$Url
    if ($uri.Scheme -notin 'http','https') { throw "Only http/https supported." }
} catch {
    Write-Host "Invalid URL: $($_.Exception.Message)" -ForegroundColor Red; return
}

# Filename derived from URL path - strips ?query and #fragment automatically
$urlFile = [System.IO.Path]::GetFileName($uri.LocalPath)
if (-not $urlFile) { $urlFile = 'download.bin' }   # fallback if URL has no path filename

# --- Destination ---
$defaultDir  = "C:\Users\Public\Downloads"
$defaultPath = Join-Path $defaultDir $urlFile

if (-not $Dest) {
    if ($NonInteractive) {
        $Dest = $defaultPath
    } else {
        $entered = Read-Host "Destination file or folder (Enter = $defaultPath)"
        $Dest = if ([string]::IsNullOrWhiteSpace($entered)) { $defaultPath } else { $entered }
    }
}

# If $Dest looks like a folder (exists as folder, or ends with slash), append URL filename
$looksLikeFolder = (Test-Path -LiteralPath $Dest -PathType Container) -or
                   $Dest.EndsWith('\') -or $Dest.EndsWith('/')
if ($looksLikeFolder) {
    $Dest = Join-Path $Dest $urlFile
}

# --- Hash ---
if (-not $NoHash -and -not $Hash) {
    $Hash = (Read-Host "Expected SHA256 (Enter to skip)").Trim()
}

# --- Pre-flight ---
$destDir = Split-Path -LiteralPath $Dest -Parent
if ($destDir -and -not (Test-Path -LiteralPath $destDir)) {
    New-Item -ItemType Directory -Path $destDir -Force | Out-Null
}

if (Test-Path -LiteralPath $Dest) {
    if (-not $Force) {
        $f   = Get-Item -LiteralPath $Dest
        $ans = Read-Host "Exists: $([math]::Round($f.Length/1MB,2)) MB, $($f.LastWriteTime). Overwrite? [y/N]"
        if ($ans -notmatch '^(y|yes)$') { Write-Host "Aborted." -ForegroundColor Yellow; return }
    }
}

Write-Host "Source : $Url"  -ForegroundColor Cyan
Write-Host "Target : $Dest" -ForegroundColor Cyan

# --- Download ---
# Prefer curl.exe: better TLS fingerprint, less Cloudflare/WAF friction, real retry logic.
# Fall back to Invoke-WebRequest only if curl.exe isn't on PATH.
$curl = (Get-Command curl.exe -ErrorAction SilentlyContinue).Path
$ua   = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36'

$sw = [Diagnostics.Stopwatch]::StartNew()
$downloadOk = $false

if ($curl) {
    Write-Host "Using : curl.exe" -ForegroundColor DarkGray
    & $curl -L --fail --retry 3 --retry-delay 2 --connect-timeout 15 `
            -A $ua `
            -H 'Accept: */*' `
            -H 'Accept-Language: en-US,en;q=0.9' `
            --create-dirs `
            -o $Dest $Url
    if ($LASTEXITCODE -eq 0) {
        $downloadOk = $true
    } else {
        Write-Host "curl failed (exit $LASTEXITCODE). Falling back to Invoke-WebRequest..." -ForegroundColor Yellow
        if (Test-Path -LiteralPath $Dest) { try { Remove-Item -LiteralPath $Dest -Force } catch {} }
    }
}

if (-not $downloadOk) {
    Write-Host "Using : Invoke-WebRequest" -ForegroundColor DarkGray
    try {
        Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing -MaximumRedirection 5 `
            -Headers @{
                'User-Agent'      = $ua
                'Accept'          = '*/*'
                'Accept-Language' = 'en-US,en;q=0.9'
            } -ErrorAction Stop
        $downloadOk = $true
    } catch {
        Write-Host "FAILED: $($_.Exception.Message)" -ForegroundColor Red
        if (Test-Path -LiteralPath $Dest) { try { Remove-Item -LiteralPath $Dest -Force } catch {} }
        return
    }
}
$sw.Stop()

if (-not (Test-Path -LiteralPath $Dest)) {
    Write-Host "FAILED: no file written." -ForegroundColor Red; return
}

$size   = (Get-Item -LiteralPath $Dest).Length
$sizeMB = [math]::Round($size / 1MB, 2)
$secs   = [math]::Round($sw.Elapsed.TotalSeconds, 1)
$rate   = if ($sw.Elapsed.TotalSeconds -gt 0) { [math]::Round($sizeMB / $sw.Elapsed.TotalSeconds, 2) } else { 0 }
Write-Host "Done   : $sizeMB MB in ${secs}s ($rate MB/s)" -ForegroundColor Green

# --- Optional hash verification ---
if ($Hash) {
    $actual = (Get-FileHash -LiteralPath $Dest -Algorithm SHA256).Hash
    if ($actual -ieq $Hash) {
        Write-Host "SHA256 OK: $actual" -ForegroundColor Green
    } else {
        Write-Host "SHA256 MISMATCH - file is suspect" -ForegroundColor Red
        Write-Host " Expected: $Hash"
        Write-Host " Actual  : $actual"
    }
}
