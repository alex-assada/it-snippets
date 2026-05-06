$ErrorActionPreference = 'Stop'

# ---- Config -------------------------------------------------
$zipUrl  = 'https://www.vim.org/downloads/gvim_9.2.0000_x64.zip'
$workDir = Join-Path $env:TEMP "vim-$PID"
$zipPath = Join-Path $workDir 'vim.zip'
# ------------------------------------------------------------

New-Item -ItemType Directory -Path $workDir | Out-Null

Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath
Expand-Archive -Path $zipPath -DestinationPath $workDir

$vimExe = Get-ChildItem -Recurse $workDir -Filter vim.exe |
          Select-Object -First 1

if (-not $vimExe) {
    throw "vim.exe not found after extraction"
}

# Prepend vim to PATH (process scope only)
$env:PATH = "$($vimExe.Directory.FullName);$env:PATH"

Write-Host "vim available for this PowerShell session only"
Write-Host "Path: $($vimExe.FullName)"

# ---- Cleanup on exit ---------------------------------------
Register-EngineEvent PowerShell.Exiting -Action {
    # Kill vim instances started from this session
    Get-Process vim -ErrorAction SilentlyContinue | Stop-Process -Force

    # Remove extracted files
    Remove-Item -Recurse -Force $using:workDir
}
# ------------------------------------------------------------

