# Is-W11-Upgrade-Successful.ps1
# Determines current upgrade state by inspecting OS build, BCD, Windows.old, and staging artifacts.

# --- OS state (authoritative) ---
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

# --- BCD: Windows 11 install entry pointing at staged image ---
# This is the AUTHORITATIVE signal that an install is queued and waiting for reboot.
$bcdW11Pending = $false
try {
    $bcdOut = (& bcdedit /enum osloader 2>&1) -join "`n"
    if ($bcdOut -match '\$WINDOWS\.~BT\\NewOS') { $bcdW11Pending = $true }
} catch { }

# --- setupact.log: Finalize success marker (downlevel phase completed cleanly) ---
$finalizeSuccess = $false
if (Test-Path $actLog) {
    $finalizeSuccess = [bool](Get-Content $actLog -Tail 200 -ErrorAction SilentlyContinue |
                              Select-String "Finalize: Reporting result value: \[0x0\]")
}

# --- Volatile progress key ---
$raw = (Get-ItemProperty -Path 'HKLM:\SYSTEM\Setup\MoSetup\Volatile' -Name SetupProgress -ErrorAction SilentlyContinue).SetupProgress
$hex = if ($null -ne $raw) { $raw.ToString('X') } else { $null }

# --- Fatal-only error filter ---
$fatalPattern = "0xC190[0-9a-fA-F]{4}|0x800F092[23]|0x80070070"
$fatalErrors  = $null
if (Test-Path $errLog) {
    $fatalErrors = Get-Content $errLog -Tail 300 -ErrorAction SilentlyContinue |
                   Where-Object { $_ -match $fatalPattern }
}

# --- Explicit rollback markers ---
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
    $msg    = "On Windows 11 (build $build). No recent Windows.old -- already on W11 or upgrade trace cleaned up."
    $color  = "Green"
}
elseif ($p) {
    $progress = if ($hex) { " -- Progress(hex): $hex" } else { "" }
    $status = "IN_PROGRESS"
    $msg    = "Upgrade in progress: $($p.ProcessName -join ', ').$progress Final verdict only after reboot."
    $color  = "Green"
}
elseif ($bcdW11Pending -or $finalizeSuccess) {
    # Install is queued in BCD or downlevel completed cleanly -- reboot will trigger install
    $signals = @()
    if ($bcdW11Pending)    { $signals += "BCD W11 entry" }
    if ($finalizeSuccess)  { $signals += "Finalize 0x0 marker" }
    $status = "PENDING_REBOOT_INSTALL"
    $msg    = "Downlevel phase complete, install queued (signals: $($signals -join ', ')) -- reboot to enter W11 install phase."
    $color  = "Cyan"
}
elseif ($rollback) {
    $status = "ROLLBACK"
    $msg    = "Rollback markers in setupact.log -- upgrade failed and reverted."
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
    $msg    = "Setup-fatal codes in setuperr.log [$codes], no active process -- upgrade attempt failed."
    $color  = "Red"
}
elseif ($btExists) {
    $status = "STAGED_IDLE"
    $msg    = "Staging folder exists but no success marker, no BCD entry, no active process -- stalled or aborted."
    $color  = "Yellow"
}
else {
    $status = "NOT_ATTEMPTED"
    $msg    = "On Windows 10 (build $build), no upgrade artifacts found -- upgrade has not been attempted."
    $color  = "Gray"
}

Write-Host "`n[$status] $msg`n" -ForegroundColor $color

[PSCustomObject]@{
    Status              = $status
    Message             = $msg
    OSCaption           = $caption
    Build               = $build
    IsWindows11         = $isW11
    WindowsOldAge       = $winOldAgeDays
    StagingExists       = $btExists
    BCD_W11_Pending     = $bcdW11Pending
    FinalizeSuccess     = $finalizeSuccess
    ProcessRunning      = if ($p) { $p.ProcessName -join ',' } else { $null }
    ProgressHex         = $hex
    HasFatalErrors      = [bool]$fatalErrors
    HasRollback         = [bool]$rollback
}
