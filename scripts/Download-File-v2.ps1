# ============================================================
# Download-File.ps1 - interactive download helper
# Works on PowerShell 5.1 and 7. Run from ISE or paste into a console.
# ============================================================

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'   # 30-50x faster IWR on large files

# --- Input ---
$Url = Read-Host 'Download URL'
if ([string]::IsNullOrWhiteSpace($Url)) { Write-Host 'No URL. Aborting.' -ForegroundColor Red; return }

try {
    $uri = [uri]$Url
    if ($uri.Scheme -notin 'http','https') { throw 'Only http/https.' }
} catch { Write-Host "Invalid URL: $($_.Exception.Message)" -ForegroundColor Red; return }

# Filename from URL path - strips ?query and #fragment
$urlFile = [System.IO.Path]::GetFileName($uri.LocalPath)
if ([string]::IsNullOrWhiteSpace($urlFile)) { $urlFile = 'download.bin' }

$default = Join-Path 'C:\Users\Public\Downloads' $urlFile
$entered = Read-Host "Save to (Enter = $default)"
$Dest    = if ([string]::IsNullOrWhiteSpace($entered)) { $default } else { $entered }

# If a folder was given, append the URL filename
if ((Test-Path -LiteralPath $Dest -PathType Container) -or $Dest -match '[\\/]$') {
    $Dest = Join-Path $Dest $urlFile
}

# --- Pre-checks (fail fast) ---
$destDir = [System.IO.Path]::GetDirectoryName($Dest)   # version-agnostic, no Split-Path param-set trap
if ($destDir -and -not (Test-Path -LiteralPath $destDir)) {
    New-Item -ItemType Directory -Path $destDir -Force | Out-Null
}

if (Test-Path -LiteralPath $Dest) {
    $f = Get-Item -LiteralPath $Dest
    $ans = Read-Host "Exists: $([math]::Round($f.Length/1MB,2)) MB, $($f.LastWriteTime). Overwrite? [y/N]"
    if ($ans -notmatch '^(y|yes)$') { Write-Host 'Aborted.' -ForegroundColor Yellow; return }
    Remove-Item -LiteralPath $Dest -Force
}

Write-Host "Source : $Url"  -ForegroundColor Cyan
Write-Host "Target : $Dest" -ForegroundColor Cyan

# --- Download (curl.exe preferred, IWR fallback) ---
$curl = (Get-Command curl.exe -ErrorAction SilentlyContinue).Path
$ua   = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36'
$sw   = [Diagnostics.Stopwatch]::StartNew()
$ok   = $false

if ($curl) {
    Write-Host 'Using : curl.exe' -ForegroundColor DarkGray
    & $curl -L --fail --retry 3 --retry-delay 2 --connect-timeout 15 -A $ua --create-dirs -o $Dest $Url
    if ($LASTEXITCODE -eq 0) { $ok = $true }
    else { Write-Host "curl failed (exit $LASTEXITCODE), trying Invoke-WebRequest..." -ForegroundColor Yellow }
}

if (-not $ok) {
    Write-Host 'Using : Invoke-WebRequest' -ForegroundColor DarkGray
    try {
        Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing -MaximumRedirection 5 `
            -Headers @{ 'User-Agent' = $ua } -ErrorAction Stop
        $ok = $true
    } catch {
        Write-Host "FAILED: $($_.Exception.Message)" -ForegroundColor Red
        if (Test-Path -LiteralPath $Dest) { Remove-Item -LiteralPath $Dest -Force -ErrorAction SilentlyContinue }
        return
    }
}
$sw.Stop()

if (-not (Test-Path -LiteralPath $Dest)) { Write-Host 'FAILED: no file written.' -ForegroundColor Red; return }

# --- Result ---
$mb   = [math]::Round((Get-Item -LiteralPath $Dest).Length / 1MB, 2)
$secs = [math]::Round($sw.Elapsed.TotalSeconds, 1)
$rate = if ($sw.Elapsed.TotalSeconds -gt 0) { [math]::Round($mb / $sw.Elapsed.TotalSeconds, 2) } else { 0 }
Write-Host "Done   : $mb MB in ${secs}s ($rate MB/s)" -ForegroundColor Green

# --- Optional hash check ---
$Hash = (Read-Host 'Verify SHA256 (Enter to skip)').Trim()
if ($Hash) {
    $actual = (Get-FileHash -LiteralPath $Dest -Algorithm SHA256).Hash
    if ($actual -ieq $Hash) { Write-Host "SHA256 OK: $actual" -ForegroundColor Green }
    else {
        Write-Host 'SHA256 MISMATCH - file is suspect' -ForegroundColor Red
        Write-Host " Expected: $Hash"
        Write-Host " Actual  : $actual"
    }
}
