# Prompt for URL
$url = Read-Host "Paste the download URL"

# Default destination folder
$defaultPath = "C:\Users\Public\Downloads"

# Prompt for destination (accept empty input = default)
$dest = Read-Host "Destination file path (Press Enter for default: $defaultPath)"

if ([string]::IsNullOrWhiteSpace($dest)) {
    # Build a filename from the URL if user uses default
    $fileName = Split-Path $url -Leaf
    $dest = Join-Path $defaultPath $fileName
}

Write-Host "Downloading to: $dest" -ForegroundColor Cyan

# Perform download with browser User-Agent
Invoke-WebRequest `
    -Uri $url `
    -OutFile $dest `
    -Headers @{"User-Agent"="Mozilla/5.0"}

Write-Host "Download completed!" -ForegroundColor Green
