# ==============================================
# 🧠 Windows 10/11 Upgrade Diagnostic - Full Edition (v3)
# - Collects: SetupDiag, Panther, Rollback, MOUPG, WU policies, languages, drivers, CBS, RE, disks
# - Output:  C:\TempSetupDiag\UpgradeDiag_SUMMARY.txt
# ==============================================

$OutRoot = "$env:SystemDrive\TempSetupDiag"
$OutFile = Join-Path $OutRoot "UpgradeDiag_SUMMARY.txt"

if (!(Test-Path $OutRoot)) {
    New-Item -ItemType Directory -Path $OutRoot | Out-Null
}

# Small helper for logging
function Write-Log {
    param([string]$Text)
    Add-Content -Path $OutFile -Value $Text -Encoding UTF8
}

"========== WINDOWS UPGRADE SMART SUMMARY ==========" | Out-File $OutFile -Encoding UTF8
"Date: $(Get-Date)  |  Machine: $env:COMPUTERNAME`n" | Add-Content -Encoding UTF8 -Path $OutFile

# ==================================================
# 0️⃣ System & Language Basics
# ==================================================
Write-Log "===== [SYSTEM & LANGUAGE] =====`n"

$os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
if ($os) {
    Write-Log ("OS: {0} (Version {1}, Build {2})" -f $os.Caption, $os.Version, $os.BuildNumber)
}

# InstallLanguage (true base ISO language)
try {
    $installLang = (Get-ItemProperty 'HKLM:\SYSTEM\ControlSet001\Control\Nls\Language' -Name InstallLanguage -ErrorAction SilentlyContinue).InstallLanguage
} catch {
    $installLang = $null
}
if ($installLang) {
    Write-Log "InstallLanguage (LCID): $installLang"

    # Minimal LCID → ISO language mapping
    $langMap = @{
        "0409" = "English (en-US)"
        "0809" = "English (en-GB / International)"
        "0C09" = "English (Australia)"
        "1009" = "English (Canada)"
        "040C" = "French (France)"
        "0C0C" = "French (Canada)"
        "0407" = "German"
        "0C07" = "German (Austria)"
        "040A" = "Spanish (Spain)"
        "080A" = "Spanish (Mexico)"
        "0410" = "Italian"
        "0413" = "Dutch"
        "0415" = "Polish"
        "0419" = "Russian"
        "0422" = "Ukrainian"
        "041D" = "Swedish"
        "0412" = "Korean"
        "0411" = "Japanese"
        "0804" = "Chinese (Simplified)"
        "0C04" = "Chinese (Traditional)"
        "0404" = "Chinese (Traditional - Taiwan)"
    }

    if ($langMap.ContainsKey($installLang)) {
        Write-Log ("→ Base ISO language (according to LCID): {0}" -f $langMap[$installLang])
    } else {
        Write-Log "→ Base ISO language: Unknown (LCID not in local map)"
    }
} else {
    Write-Log "InstallLanguage: not readable."
}

Write-Log ""

# DISM intl info (short)
Write-Log "===== [DISM /ONLINE /GET-INTL (SHORT)] =====`n"
try {
    $intl = dism /online /get-intl 2>&1
    $intl | Select-String -Pattern "Default system UI language|System locale|Installed language" | ForEach-Object {
        Write-Log $_.ToString()
    }
} catch {
    Write-Log "DISM /Get-Intl failed: $($_.Exception.Message)"
}
Write-Log ""

# ==================================================
# 1️⃣ Windows Update / WSUS Policies
# ==================================================
Write-Log "===== [WINDOWS UPDATE POLICY / WSUS] =====`n"

$wuPolPath = "HKLM:\Software\Policies\Microsoft\Windows\WindowsUpdate"
$wuAuPath  = "HKLM:\Software\Policies\Microsoft\Windows\WindowsUpdate\AU"

if (Test-Path $wuPolPath) {
    Write-Log "WindowsUpdate policy key present: $wuPolPath"
    Get-ItemProperty -Path $wuPolPath -ErrorAction SilentlyContinue | Format-List | Out-String | Write-Log
} else {
    Write-Log "No HKLM WindowsUpdate policy key detected."
}

if (Test-Path $wuAuPath) {
    Write-Log "`nAU subkey present: $wuAuPath"
    Get-ItemProperty -Path $wuAuPath -ErrorAction SilentlyContinue | Format-List | Out-String | Write-Log
}

Write-Log "`n(If WUServer / UseWUServer / DoNotConnectToWindowsUpdateInternetLocations / DisableDualScan are set, they can block Dynamic Update.)`n"

# ==================================================
# 2️⃣ SetupDiag (Microsoft official)
# ==================================================
Write-Log "===== [SETUPDIAG SUMMARY] =====`n"

$setupDiagUrl = "https://go.microsoft.com/fwlink/?linkid=870142"
$setupDiagExe = Join-Path $OutRoot "SetupDiag.exe"

try {
    if (!(Test-Path $setupDiagExe)) {
        Invoke-WebRequest -Uri $setupDiagUrl -OutFile $setupDiagExe -UseBasicParsing -ErrorAction SilentlyContinue
    }
    if (Test-Path $setupDiagExe) {
        $setupDiagOut = Join-Path $OutRoot "SetupDiagResults.log"
        Start-Process -FilePath $setupDiagExe -ArgumentList "/Output:$setupDiagOut" -Wait -NoNewWindow -ErrorAction SilentlyContinue

        if (Test-Path $setupDiagOut) {
            $lines = Get-Content $setupDiagOut -ErrorAction SilentlyContinue
            # Keep key lines only to stay readable
            $keyLines = $lines | Select-String -Pattern "Error|Failure|Result:|LogEntry|Phase|Code|0xC|0x800" -SimpleMatch
            if ($keyLines) {
                foreach ($l in $keyLines) { Write-Log $l.ToString() }
            } else {
                Write-Log "SetupDiagResults.log found but no obvious Error/Failure lines matched filter."
            }
        } else {
            Write-Log "❌ SetupDiagResults.log not found."
        }
    } else {
        Write-Log "❌ SetupDiag.exe could not be downloaded."
    }
} catch {
    Write-Log "SetupDiag execution failed: $($_.Exception.Message)"
}

Write-Log ""

# ==================================================
# 3️⃣ Panther Logs (main setup engine)
# ==================================================
Write-Log "===== [PANTHER LOGS - setupact/setuperr] =====`n"

$pantherRoot = "C:\`$WINDOWS.~BT\Sources\Panther"

if (Test-Path $pantherRoot) {
    $pantherSetupAct = Join-Path $pantherRoot "setupact.log"
    $pantherSetupErr = Join-Path $pantherRoot "setuperr.log"

    if (Test-Path $pantherSetupErr) {
        Write-Log "--- setuperr.log (last 80 lines) ---"
        (Get-Content $pantherSetupErr -Tail 80 -ErrorAction SilentlyContinue) | ForEach-Object { Write-Log $_ }
        Write-Log ""

        Write-Log "--- setuperr.log (last 50 error-like lines) ---"
        (Select-String -Path $pantherSetupErr -Pattern "error|fail|0x|MOUPG|SP|" -SimpleMatch -ErrorAction SilentlyContinue |
            Select-Object -Last 50) | ForEach-Object { Write-Log $_.ToString() }
        Write-Log ""
    } else {
        Write-Log "No Panther setuperr.log file."
    }

    if (Test-Path $pantherSetupAct) {
        Write-Log "--- setupact.log (last 80 lines) ---"
        (Get-Content $pantherSetupAct -Tail 80 -ErrorAction SilentlyContinue) | ForEach-Object { Write-Log $_ }
        Write-Log ""
    } else {
        Write-Log "No Panther setupact.log file."
    }

    # Compat logs (language / driver / appraisals)
    $compatFiles = Get-ChildItem $pantherRoot -Filter "compat*.xml" -ErrorAction SilentlyContinue
    if ($compatFiles) {
        Write-Log "--- compat XMLs present ---"
        foreach ($cf in $compatFiles) {
            Write-Log $cf.FullName
        }
        Write-Log ""
    }
} else {
    Write-Log "Panther folder not found: $pantherRoot`n"
}

# ==================================================
# 4️⃣ MOUPG (Modern Upgrade Platform)
# ==================================================
Write-Log "===== [MOUPG LOGS] =====`n"

$moupgRoot = Join-Path $pantherRoot "MOUPG"
if (Test-Path $moupgRoot) {
    Write-Log "MOUPG folder: $moupgRoot"
    $moupgLogs = Get-ChildItem $moupgRoot -Filter "*.log" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 5
    foreach ($log in $moupgLogs) {
        Write-Log "`n--- $($log.Name) (last 40 lines with errors) ---"
        try {
            (Select-String -Path $log.FullName -Pattern "error|fail|0x|rollback|C1900" -SimpleMatch -ErrorAction SilentlyContinue |
                Select-Object -Last 40) | ForEach-Object { Write-Log $_.ToString() }
        } catch {
            Write-Log "Could not read $($log.FullName): $($_.Exception.Message)"
        }
    }
} else {
    Write-Log "No MOUPG folder found."
}

Write-Log ""

# ==================================================
# 5️⃣ Rollback Logs
# ==================================================
Write-Log "===== [ROLLBACK LOGS] =====`n"

$rollbackPath = "C:\`$WINDOWS.~BT\Sources\Rollback"
foreach ($f in @("setupact.log","setuperr.log")) {
    $path = Join-Path $rollbackPath $f
    if (Test-Path $path) {
        Write-Log "`n--- $f (last 40 lines) ---"
        (Get-Content $path -Tail 40 -ErrorAction SilentlyContinue) | ForEach-Object { Write-Log $_ }

        Write-Log "`n--- $f (last 30 error-like lines) ---"
        (Select-String -Path $path -Pattern "error|fail|crash|C1900|rollback|0x" -SimpleMatch -ErrorAction SilentlyContinue |
            Select-Object -Last 30) | ForEach-Object { Write-Log $_.ToString() }
    }
}

Write-Log ""

# ==================================================
# 6️⃣ .SYS Driver References in Setup Logs
# ==================================================
Write-Log "===== [.SYS REFERENCES IN LOGS] =====`n"

$sysSearchFiles = @(
    "C:\`$WINDOWS.~BT\Sources\Rollback\setupact.log",
    "C:\`$WINDOWS.~BT\Sources\Panther\setupact.log"
)

foreach ($sf in $sysSearchFiles) {
    if (Test-Path $sf) {
        Write-Log "`n--- .sys references in $sf ---"
        try {
            $sysLines = cmd /c "findstr /i `.sys` \"$sf\"" 2>&1 | Out-String -Width 4096
            Write-Log $sysLines
        } catch {
            Write-Log "findstr failed on ${sf}: $($_.Exception.Message)"
        }
    }
}

Write-Log ""

# ==================================================
# 7️⃣ Last BugCheck (EventID 1001)
# ==================================================
Write-Log "===== [LAST BUGCHECK (EVENTID 1001)] =====`n"
try {
    $bugchk = cmd /c 'wevtutil qe System /q:"*[System[(EventID=1001)]]" /f:text /c:5' 2>&1 | Out-String -Width 4096
    Write-Log $bugchk
} catch {
    Write-Log "wevtutil query for EventID 1001 failed: $($_.Exception.Message)"
}
Write-Log ""

# ==================================================
# 8️⃣ Non-Microsoft Drivers (pnputil)
# ==================================================
Write-Log "===== [NON-MICROSOFT DRIVERS (pnputil)] =====`n"
try {
    $drivers = cmd /c 'pnputil /enum-drivers' 2>&1
    # Filter out Microsoft and keep key lines
    $driversFiltered = $drivers |
        Select-String -Pattern "Published Name|Driver Package Provider|Class Name|Driver Version" -SimpleMatch |
        Where-Object { $_ -notmatch "Microsoft" }
    ($driversFiltered | Out-String -Width 4096) | Write-Log
} catch {
    Write-Log "pnputil failed: $($_.Exception.Message)"
}
Write-Log ""

# ==================================================
# 9️⃣ Recovery / Disk Info
# ==================================================
Write-Log "===== [SYSTEM INFO / RE / DISK] =====`n"

try {
    Write-Log "--- reagentc /info ---"
    (reagentc /info 2>&1 | Out-String -Width 4096) | Write-Log
} catch {
    Write-Log "reagentc /info failed: $($_.Exception.Message)"
}

Write-Log "`n--- Disk summary (Get-Volume) ---`n"
try {
    (Get-Volume | Select DriveLetter, SizeRemaining, Size, FileSystem | Format-Table | Out-String -Width 4096) | Write-Log
} catch {
    Write-Log "Get-Volume failed: $($_.Exception.Message)"
}
Write-Log ""

# ==================================================
# 🔟 CBS.log Errors (short)
# ==================================================
Write-Log "===== [CBS.LOG ERRORS (TOP 40)] =====`n"
$cbs = "C:\Windows\Logs\CBS\CBS.log"
if (Test-Path $cbs) {
    try {
        (Select-String -Path $cbs -Pattern "error|failed|0x" -SimpleMatch -ErrorAction SilentlyContinue |
            Select-Object -First 40 |
            ForEach-Object { $_.ToString() }) | Write-Log
    } catch {
        Write-Log "CBS parsing failed: $($_.Exception.Message)"
    }
} else {
    Write-Log "CBS.log not found."
}

Write-Log "`n===== END OF SUMMARY ====="

Write-Host "`n✅ Rapport généré : $OutFile" -ForegroundColor Green
Write-Host "Joins ce fichier pour analyse détaillée." -ForegroundColor Cyan

