# Detect-and-fix stuck CBS package state breaking Win11 search/Start input.
# Run elevated. Targets ONLY the StateChange flag fault, nothing else.

$ErrorActionPreference = 'Stop'

$pkgListPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModel\StateChange\PackageList"
$backupDir   = "C:\ProgramData\CBSFix"
$logFile     = "$backupDir\CBSFix.log"
$flagValue   = 524288   # 0x80000 = package marked in-transition / not clean

function Write-Log {
    param([string]$msg)
    $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    Write-Output $line
    if (-not (Test-Path $backupDir)) { New-Item -Path $backupDir -ItemType Directory -Force | Out-Null }
    Add-Content -Path $logFile -Value $line
}

# --- elevation guard ---
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Log "ABORT: not elevated. HKLM write requires admin."
    return
}

Write-Log "=== CBS state check start on $env:COMPUTERNAME ==="

# --- detection ---
$cbsKeys = Get-ChildItem $pkgListPath -ErrorAction SilentlyContinue |
           Where-Object { $_.PSChildName -like "MicrosoftWindows.Client.CBS_*" }

if (-not $cbsKeys) {
    Write-Log "No Client.CBS keys found under PackageList. Nothing to evaluate. Exiting."
    return
}

$flagged = @()
foreach ($k in $cbsKeys) {
    $status = (Get-ItemProperty -Path $k.PSPath -Name PackageStatus -ErrorAction SilentlyContinue).PackageStatus
    Write-Log ("Found: {0}  PackageStatus={1}" -f $k.PSChildName, $status)
    if ($status -eq $flagValue) { $flagged += $k }
}

if ($flagged.Count -eq 0) {
    Write-Log "No CBS package flagged $flagValue. State is clean. No action taken."
    Write-Log "=== end ==="
    return
}

Write-Log ("DETECTED: {0} CBS package(s) flagged $flagValue. Remediating." -f $flagged.Count)

# --- backup + remediation ---
$cleared = 0
foreach ($k in $flagged) {
    $name      = $k.PSChildName
    $regPath   = "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModel\StateChange\PackageList\$name"
    $backupFile = "$backupDir\$($name)_$(Get-Date -Format 'yyyyMMdd_HHmmss').reg"

    try {
        & reg.exe export $regPath $backupFile /y | Out-Null
        Write-Log "Backed up $name -> $backupFile"
    } catch {
        Write-Log "WARN: backup failed for $name : $($_.Exception.Message). Skipping this key (no clear without backup)."
        continue
    }

    try {
        Remove-ItemProperty -Path $k.PSPath -Name PackageStatus -ErrorAction Stop
        Write-Log "Cleared PackageStatus on $name"
        $cleared++
    } catch {
        Write-Log "ERROR: failed to clear PackageStatus on $name : $($_.Exception.Message)"
    }
}

if ($cleared -gt 0) {
    Write-Log "Cleared $cleared key(s). Restarting Explorer to force shell re-evaluation."
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Write-Log "Explorer restarted. Test search input now."
} else {
    Write-Log "No keys cleared (all backups failed?). Manual review needed."
}

Write-Log "=== end ==="
