# Is-W11-Upgrade-Successful.ps1
# Determines current upgrade state by inspecting OS build first, Windows.old, then staging artifacts.

# --- OS state (authoritative signal) ---
$os      = Get-CimInstance Win32_OperatingSystem
$build   = [int]$os.BuildNumber
$caption = $os.Caption
$isW11   = $build -ge 22000

# --- Windows.old (post-upgrade trace) ---
$winOldPath    = "C:\Windows.old"
$winOld        = Get-Item $winOldPath -ErrorAction SilentlyContinue
$winOldAgeDays = if ($winOld) { [math]::Round(((Get-Date) - $winOld.CreationTime).TotalDays, 1) } else { $null }
$winOldRecent  = $winOld -and $winOldAgeDays -lt 30

# --- Active staging artifacts ---
$btPath   = "C:\`$WINDOWS.~BT"
$btExists = Test-Path $btPath
$actLog   = Join-Path $btPath "Sources\Panther\setupact.log"
$errLog   = Join-Path $btPath "Sources\Panther\setuperr.log"

# --- Active processes ---
$procNames = "Windows11InstallationAssistant","SetupHost","SetupPrep","setup","WindowsUpdateBox"
$p = Get-Process -Name $procNames -ErrorAction SilentlyContinue

# --- Pending reboot ---
$rebootKeys = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired",
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending"
)
$pendingReboot = $false
foreach ($k in $rebootKeys) { if (Test-Path $k) { $pendingReboot = $true; break } }

# --- Volatile progress key (only present during active upgrade) ---
$raw = (Get-ItemProperty -Path 'HKLM:\SYSTEM\Setup\MoSetup\Volatile' -Name SetupProgress -ErrorAction SilentlyContinue).SetupProgress
$hex = if ($null -ne $raw) { $raw.ToString('X') } else { $null }

# --- Fatal-only error filter for post-mortem analysis ---
# 0xC190xxxx is the Windows Setup fatal code family (driver issues, hard blocks, compat failures).
# Generic 0x800700xx codes are noise during active upgrade and not a reliable failure signal.
$fatalPattern = "0xC190[0-9a-fA-F]{4}|0x800F092[23]|0x80070070"
$fatalErrors  = $null
if (Test-Path $errLog) {
    $fatalErrors = Get-Content $errLog -Tail 300 -ErrorAction SilentlyContinue |
                   Where-Object { $_ -match $fatalPattern }
}

# --- Explicit rollback markers (only authoritative phrases) ---
$rollback = $null
if (Test-Path $actLog) {
    $rollback = Get-Content $actLog -Tail 500 -ErrorAction SilentlyContinue |
                Select-String "Rollback was successful|Started rollback|Rolling back the operation"
}

# --- Decision logic ---
$status = $null; $msg = $null; $color = $null

if ($isW11 -and $winOldRecent) {
    $status = "SUCCESS"
    $msg    = "On Windows 11 (build $build). Windows.old present (${winOldAgeDays}d old) -- upgrade completed successfully."
    $color  = "Green"
}
elseif ($isW11) {
    $status = "ALREADY_W11"
    $msg    = "On Windows 11 (build $build). No recent Windows.old -- already on W11 or upgrade trace was cleaned up."
    $color  = "Green"
}
elseif ($p) {
    # Active upgrade. Don't report errors here -- setuperr.log noise is expected during staging.
    $progress = if ($hex) { " -- Progress(hex): $hex" } else { "" }
    $status = "IN_PROGRESS"
    $msg    = "Upgrade in progress: $($p.ProcessName -join ', ').$progress Final verdict only after reboot."
    $color  = "Green"
}
elseif ($pendingReboot -and $btExists) {
    $status = "PENDING_REBOOT"
    $msg    = "Staging complete, no active process, reboot pending -- upgrade will continue after reboot."
    $color  = "Cyan"
}
elseif ($rollback) {
    $status = "ROLLBACK"
    $msg    = "Rollback markers found in setupact.log -- upgrade failed and reverted."
    $color  = "Red"
}
elseif ($winOldRecent) {
    $status = "ROLLED_BACK"
    $msg    = "Still on Windows 10 (build $build), Windows.old created ${winOldAgeDays}d ago -- upgrade was attempted and reverted."
    $color  = "Red"
}
elseif ($fatalErrors) {
    $codes = ($fatalErrors | Select-String -Pattern $fatalPattern -AllMatches | ForEach-Object { $_.Matches.Value } | Select-Object -Unique) -join ', '
    $status = "FAILED"
    $msg    = "Setup-fatal error codes in setuperr.log [$codes], no active process -- upgrade attempt failed."
    $color  = "Red"
}
elseif ($btExists) {
    $status = "STAGED_IDLE"
    $msg    = "Staging folder exists but no process running -- upgrade attempted but stalled or aborted."
    $color  = "Yellow"
}
else {
    $status = "NOT_ATTEMPTED"
    $msg    = "On Windows 10 (build $build), no upgrade artifacts found -- upgrade has not been attempted."
    $color  = "Gray"
}

Write-Host "`n[$status] $msg`n" -ForegroundColor $color

[PSCustomObject]@{
    Status         = $status
    Message        = $msg
    OSCaption      = $caption
    Build          = $build
    IsWindows11    = $isW11
    WindowsOldAge  = $winOldAgeDays
    StagingExists  = $btExists
    ProcessRunning = if ($p) { $p.ProcessName -join ',' } else { $null }
    PendingReboot  = $pendingReboot
    ProgressHex    = $hex
    HasFatalErrors = [bool]$fatalErrors
    HasRollback    = [bool]$rollback
}
