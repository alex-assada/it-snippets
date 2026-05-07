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

# --- Log analysis (only when staging exists) ---
$realErrors = $null
if (Test-Path $errLog) {
    $realErrors = Get-Content $errLog -Tail 200 -ErrorAction SilentlyContinue |
                  Where-Object { $_ -match "0x0*[1-9a-fA-F]" }
}
$rollback = $null
if (Test-Path $actLog) {
    $rollback = Get-Content $actLog -Tail 500 -ErrorAction SilentlyContinue |
                Select-String "Setup encountered an error|Rollback initiated|operation failed.*rolling back"
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
    $progress = if ($hex) { " -- Progress(hex): $hex" } else { "" }
    if ($realErrors) {
        $status = "IN_PROGRESS_WITH_ERRORS"
        $msg    = "Upgrade running ($($p.ProcessName -join ', ')) but setuperr.log shows non-zero codes -- monitor closely.$progress"
        $color  = "Yellow"
    } else {
        $status = "IN_PROGRESS"
        $msg    = "Upgrade in progress: $($p.ProcessName -join ', ').$progress"
        $color  = "Green"
    }
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
elseif ($realErrors) {
    $status = "FAILED"
    $msg    = "Non-zero error codes in setuperr.log, no active process -- upgrade attempt failed."
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
    Status          = $status
    Message         = $msg
    OSCaption       = $caption
    Build           = $build
    IsWindows11     = $isW11
    WindowsOldAge   = $winOldAgeDays
    StagingExists   = $btExists
    ProcessRunning  = if ($p) { $p.ProcessName -join ',' } else { $null }
    PendingReboot   = $pendingReboot
    ProgressHex     = $hex
    HasRealErrors   = [bool]$realErrors
    HasRollback     = [bool]$rollback
}
