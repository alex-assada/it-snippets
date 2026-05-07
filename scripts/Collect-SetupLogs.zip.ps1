# Get-W11UpgradeDiagnostic.ps1
# Comprehensive Windows 10/11 upgrade failure diagnostic with prioritized findings.

#--- Setup ---
$OutRoot = "$env:SystemDrive\TempSetupDiag"
$OutFile = Join-Path $OutRoot "UpgradeDiag_SUMMARY.txt"
if (!(Test-Path $OutRoot)) { New-Item -ItemType Directory -Path $OutRoot -Force | Out-Null }

# Elevation check
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "ERROR: Must run as Administrator. Several checks (pnputil, reagentc, TPM, CBS.log) require elevation." -ForegroundColor Red
    return
}

#--- Output buffers and findings ---
$out      = [System.Collections.Generic.List[string]]::new()
$findings = [System.Collections.Generic.List[pscustomobject]]::new()

function Add-Section { param([string]$Title) $out.Add(""); $out.Add(("=" * 80)); $out.Add($Title); $out.Add(("=" * 80)) }
function Add-Line    { param([string]$Text="") $out.Add($Text) }
function Add-Finding { param([string]$Severity,[string]$Category,[string]$Detail) $findings.Add([pscustomobject]@{Severity=$Severity;Category=$Category;Detail=$Detail}) }

#--- Setup-fatal codes (only codes that actually mean upgrade failure) ---
$fatalCodes = @{
    '0xC1900101' = 'Driver compatibility block (most common rollback cause)'
    '0xC1900200' = 'System requirements not met'
    '0xC1900202' = 'System requirements not met (variant)'
    '0xC1900204' = 'Migration choice not available'
    '0xC1900208' = 'Compatibility hard block (apps or hardware)'
    '0x800F0922' = 'CBS / .NET / driver install failure'
    '0x800F0923' = 'Driver compatibility block'
    '0x80070070' = 'Insufficient disk space'
    '0xC1800118' = 'WSUS-related update download failure'
}
$fatalRegex = ($fatalCodes.Keys | ForEach-Object { [regex]::Escape($_) }) -join '|'

#=== 1. OS & Hardware State ===
Add-Section "1. OS & HARDWARE STATE"
$os    = Get-CimInstance Win32_OperatingSystem
$cs    = Get-CimInstance Win32_ComputerSystem
$cpu   = Get-CimInstance Win32_Processor | Select-Object -First 1
$build = [int]$os.BuildNumber
$isW11 = $build -ge 22000

Add-Line "OS Caption:       $($os.Caption)"
Add-Line "OS Version:       $($os.Version) (Build $build)"
Add-Line "Architecture:     $($os.OSArchitecture)"
Add-Line "Already on W11:   $isW11"
Add-Line "Manufacturer:     $($cs.Manufacturer)"
Add-Line "Model:            $($cs.Model)"
Add-Line "RAM (GB):         $([math]::Round($cs.TotalPhysicalMemory/1GB,1))"
Add-Line "CPU:              $($cpu.Name)"

# TPM
try {
    $tpm = Get-Tpm -ErrorAction Stop
    $tpmSpec = (Get-CimInstance -Namespace 'root/cimv2/security/microsofttpm' -ClassName Win32_Tpm -ErrorAction SilentlyContinue).SpecVersion
    Add-Line "TPM Present:      $($tpm.TpmPresent)"
    Add-Line "TPM Ready:        $($tpm.TpmReady)"
    Add-Line "TPM Spec:         $tpmSpec"
    if (-not $tpm.TpmPresent)              { Add-Finding "HIGH" "TPM" "TPM not present" }
    elseif (-not $tpm.TpmReady)            { Add-Finding "HIGH" "TPM" "TPM present but not ready" }
    if ($tpmSpec -and $tpmSpec -notmatch '2\.0') { Add-Finding "HIGH" "TPM" "TPM spec is $tpmSpec, W11 requires 2.0" }
} catch { Add-Line "TPM:              query failed: $($_.Exception.Message)" }

# Secure Boot / Firmware
try {
    $sb = Confirm-SecureBootUEFI -ErrorAction Stop
    Add-Line "Secure Boot:      $sb"
    if (-not $sb) { Add-Finding "HIGH" "SecureBoot" "Secure Boot is disabled" }
} catch {
    Add-Line "Secure Boot:      not in UEFI mode or query failed"
    Add-Finding "HIGH" "SecureBoot" "Not in UEFI mode (legacy BIOS) - W11 requires UEFI + Secure Boot"
}

# Disk
$cFree = [math]::Round((Get-PSDrive C).Free/1GB,1)
Add-Line "C: Free Space:    $cFree GB"
if ($cFree -lt 20) { Add-Finding "HIGH" "DiskSpace" "Only $cFree GB free on C: - upgrade typically needs 20+" }

# Locale
$installLang = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\Language' -Name InstallLanguage -ErrorAction SilentlyContinue).InstallLanguage
$defaultLang = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\Language' -Name Default -ErrorAction SilentlyContinue).Default
Add-Line "Install LCID:     $installLang"
Add-Line "Default LCID:     $defaultLang"
if ($installLang -and $defaultLang -and $installLang -ne $defaultLang) {
    Add-Finding "MEDIUM" "Locale" "Install LCID ($installLang) differs from Default LCID ($defaultLang) - can cause Dynamic Update language mismatch"
}

#=== 2. WU/WSUS Policy ===
Add-Section "2. WINDOWS UPDATE / WSUS POLICY"
$wuPol = "HKLM:\Software\Policies\Microsoft\Windows\WindowsUpdate"
$wuAU  = "$wuPol\AU"
if (Test-Path $wuPol) {
    Add-Line "Policy key found: $wuPol"
    $wuPolProps = Get-ItemProperty $wuPol -ErrorAction SilentlyContinue
    $relevantKeys = 'WUServer','WUStatusServer','UseWUServer','DoNotConnectToWindowsUpdateInternetLocations','DisableDualScan','DeferFeatureUpdates','DeferFeatureUpdatesPeriodInDays','TargetReleaseVersion','TargetReleaseVersionInfo','ProductVersion'
    foreach ($k in $relevantKeys) {
        if ($null -ne $wuPolProps.$k) { Add-Line ("  {0,-50} = {1}" -f $k, $wuPolProps.$k) }
    }
    if ($wuPolProps.UseWUServer -eq 1)      { Add-Finding "HIGH" "WSUS" "UseWUServer=1 - WSUS in use, may block Dynamic Update content" }
    if ($wuPolProps.DisableDualScan -eq 1)  { Add-Finding "HIGH" "WSUS" "DisableDualScan=1 - prevents fallback to Microsoft Update" }
    if ($wuPolProps.TargetReleaseVersion -eq 1 -and $wuPolProps.TargetReleaseVersionInfo) {
        Add-Finding "HIGH" "WSUS" "TargetReleaseVersion pinned to '$($wuPolProps.TargetReleaseVersionInfo)' - may block W11 if pinned to W10"
    }
} else {
    Add-Line "No WindowsUpdate policy key. (Default: direct to MS Update)"
}
if (Test-Path $wuAU) {
    Add-Line ""
    Add-Line "AU policy key found: $wuAU"
    Get-ItemProperty $wuAU -ErrorAction SilentlyContinue | Format-List | Out-String -Stream | ForEach-Object { Add-Line "  $_" }
}

#=== 3. SetupDiag ===
Add-Section "3. SETUPDIAG ANALYSIS"
$setupDiagExe = Join-Path $OutRoot "SetupDiag.exe"
$setupDiagOut = Join-Path $OutRoot "SetupDiagResults.log"

if (-not (Test-Path $setupDiagExe)) {
    try { Invoke-WebRequest "https://go.microsoft.com/fwlink/?linkid=870142" -OutFile $setupDiagExe -UseBasicParsing -ErrorAction Stop }
    catch { Add-Line "Failed to download SetupDiag: $($_.Exception.Message)" }
}

if (Test-Path $setupDiagExe) {
    Start-Process $setupDiagExe -ArgumentList "/Output:$setupDiagOut" -Wait -NoNewWindow -ErrorAction SilentlyContinue
    if (Test-Path $setupDiagOut) {
        $sdContent = Get-Content $setupDiagOut -Raw
        $rule        = if ($sdContent -match 'Matching SetupDiag rule found:\s*(.+)') { $Matches[1].Trim() }
        $profileName = if ($sdContent -match 'ProfileName:\s*(.+)')                   { $Matches[1].Trim() }
        $desc        = if ($sdContent -match 'Description:\s*(.+)')                   { $Matches[1].Trim() }
        $remediation = if ($sdContent -match 'Remediation:\s*(.+)')                   { $Matches[1].Trim() }
        $failureData = if ($sdContent -match 'FailureData:\s*(.+)')                   { $Matches[1].Trim() }

        if ($rule) {
            Add-Line "Failure Rule:     $rule"
            Add-Finding "HIGH" "SetupDiag" "Failure rule: $rule"
        }
        if ($profileName) { Add-Line "Profile:          $profileName" }
        if ($desc)        { Add-Line "Description:      $desc" }
        if ($remediation) { Add-Line "Remediation:      $remediation" }
        if ($failureData) { Add-Line "Failure Data:     $failureData" }
        if (-not $rule) {
            Add-Line "SetupDiag did not identify a matching rule. First 100 lines of output:"
            Add-Line ""
            Get-Content $setupDiagOut -TotalCount 100 | ForEach-Object { Add-Line $_ }
        }
    } else {
        Add-Line "SetupDiag ran but produced no output file."
    }
} else {
    Add-Line "SetupDiag.exe not available."
}

#=== 4. Panther logs ===
Add-Section "4. PANTHER LOGS (setupact + setuperr)"
$btPath          = "C:\`$WINDOWS.~BT"
$pantherRoot     = Join-Path $btPath "Sources\Panther"
$pantherSetupErr = Join-Path $pantherRoot "setuperr.log"
$pantherSetupAct = Join-Path $pantherRoot "setupact.log"

if (Test-Path $pantherRoot) {
    if (Test-Path $pantherSetupErr) {
        $errLines = Get-Content $pantherSetupErr -Tail 300 -ErrorAction SilentlyContinue
        $fatalHits = $errLines | Select-String -Pattern $fatalRegex
        Add-Line "setuperr.log size:   $((Get-Item $pantherSetupErr).Length) bytes"
        Add-Line "Fatal-code hits:     $($fatalHits.Count)"
        if ($fatalHits) {
            $uniqueCodes = $fatalHits | ForEach-Object { ([regex]::Match($_.Line, $fatalRegex)).Value } | Sort-Object -Unique
            Add-Line ""
            Add-Line "Unique fatal codes found:"
            foreach ($code in $uniqueCodes) {
                $explanation = $fatalCodes[$code]
                Add-Line "  $code  --  $explanation"
                Add-Finding "HIGH" "FatalCode" "$code in setuperr.log: $explanation"
            }
            Add-Line ""
            Add-Line "--- Last 30 lines containing fatal codes ---"
            $fatalHits | Select-Object -Last 30 | ForEach-Object { Add-Line $_.Line }
        } else {
            Add-Line "No setup-fatal codes (only generic 0x80070003-class noise, if any) - this is normal for healthy upgrade or pre-staging state"
        }
        Add-Line ""
        Add-Line "--- setuperr.log last 50 lines (raw) ---"
        $errLines | Select-Object -Last 50 | ForEach-Object { Add-Line $_ }
    } else {
        Add-Line "setuperr.log not found."
    }

    if (Test-Path $pantherSetupAct) {
        Add-Line ""
        Add-Line "--- setupact.log last 80 lines (raw) ---"
        Get-Content $pantherSetupAct -Tail 80 -ErrorAction SilentlyContinue | ForEach-Object { Add-Line $_ }
    } else {
        Add-Line "setupact.log not found."
    }
} else {
    Add-Line "Panther folder not found at: $pantherRoot"
    Add-Line "(Either upgrade was never staged, or staging artifacts were cleaned up)"
}

#=== 5. CompatData XML ===
Add-Section "5. COMPATIBILITY DATA (CompatData_*.xml)"
if (Test-Path $pantherRoot) {
    $compatFiles = Get-ChildItem $pantherRoot -Filter "CompatData_*.xml" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
    if ($compatFiles) {
        $latest = $compatFiles | Select-Object -First 1
        Add-Line "Latest CompatData file: $($latest.Name) ($([math]::Round($latest.Length/1KB,1)) KB)"
        try {
            [xml]$compat = Get-Content $latest.FullName -Raw
            $hardBlocks = @($compat.SelectNodes("//*[@BlockingType='Hard']"))
            $softBlocks = @($compat.SelectNodes("//*[@BlockingType='Soft']"))
            Add-Line "Hard blocks: $($hardBlocks.Count)"
            Add-Line "Soft blocks: $($softBlocks.Count)"
            if ($hardBlocks.Count -gt 0) {
                Add-Line ""
                Add-Line "--- Hard blocks ---"
                foreach ($hb in $hardBlocks) {
                    $snippet = $hb.OuterXml.Substring(0,[Math]::Min(250,$hb.OuterXml.Length))
                    Add-Line "$($hb.LocalName): $snippet"
                    Add-Finding "HIGH" "CompatBlock" "Hard block in CompatData: $($hb.LocalName)"
                }
            }
            if ($softBlocks.Count -gt 0) {
                Add-Line ""
                Add-Line "--- Soft blocks (first 10) ---"
                $softBlocks | Select-Object -First 10 | ForEach-Object {
                    $snippet = $_.OuterXml.Substring(0,[Math]::Min(200,$_.OuterXml.Length))
                    Add-Line "$($_.LocalName): $snippet"
                }
            }
        } catch { Add-Line "Failed to parse CompatData XML: $($_.Exception.Message)" }
    } else {
        Add-Line "No CompatData_*.xml files found in Panther."
    }
} else {
    Add-Line "Panther folder absent - skipping compat analysis."
}

#=== 6. MOUPG logs ===
Add-Section "6. MOUPG LOGS"
$moupgRoot = Join-Path $pantherRoot "MOUPG"
if (Test-Path $moupgRoot) {
    $moupgLogs = Get-ChildItem $moupgRoot -Filter "*.log" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 3
    foreach ($log in $moupgLogs) {
        Add-Line ""
        Add-Line "--- $($log.Name) (fatal-matching lines, last 30) ---"
        $hits = Select-String -Path $log.FullName -Pattern $fatalRegex -ErrorAction SilentlyContinue | Select-Object -Last 30
        if ($hits) { $hits | ForEach-Object { Add-Line $_.Line } } else { Add-Line "(no fatal codes)" }
    }
} else {
    Add-Line "No MOUPG folder found."
}

#=== 7. Rollback logs ===
Add-Section "7. ROLLBACK LOGS"
$rollbackPath = Join-Path $btPath "Sources\Rollback"
if (Test-Path $rollbackPath) {
    Add-Line "Rollback folder exists: $rollbackPath"
    Add-Finding "HIGH" "Rollback" "Rollback folder present - upgrade entered rollback phase"
    foreach ($f in @("setupact.log","setuperr.log")) {
        $path = Join-Path $rollbackPath $f
        if (Test-Path $path) {
            Add-Line ""
            Add-Line "--- Rollback\$f (last 40 lines) ---"
            Get-Content $path -Tail 40 -ErrorAction SilentlyContinue | ForEach-Object { Add-Line $_ }
            $rbHits = Get-Content $path -Tail 200 -ErrorAction SilentlyContinue | Select-String -Pattern $fatalRegex
            if ($rbHits) {
                Add-Line ""
                Add-Line "--- fatal codes in Rollback\$f ---"
                $rbHits | Select-Object -Last 20 | ForEach-Object { Add-Line $_.Line }
            }
        }
    }
} else {
    Add-Line "No Rollback folder - upgrade did not enter rollback phase"
}

#=== 8. Driver references in setup logs ===
Add-Section "8. THIRD-PARTY DRIVER REFERENCES"
foreach ($lp in @($pantherSetupAct, (Join-Path $rollbackPath 'setupact.log'))) {
    if ($lp -and (Test-Path $lp)) {
        Add-Line ""
        Add-Line "--- .sys references in $lp (last 30) ---"
        $sysHits = Select-String -Path $lp -Pattern '\.sys' -ErrorAction SilentlyContinue | Select-Object -Last 30 -ExpandProperty Line
        if ($sysHits) { $sysHits | ForEach-Object { Add-Line $_ } } else { Add-Line "(no .sys references)" }
    }
}

#=== 9. Non-Microsoft drivers ===
Add-Section "9. NON-MICROSOFT DRIVERS (pnputil)"
try {
    $driverOut = & pnputil /enum-drivers 2>&1
    $blocks = ($driverOut -join "`n") -split '(?=Published Name:)'
    $thirdParty = foreach ($b in $blocks) {
        if ($b -match 'Provider Name\s*:\s*(.+)') {
            $provider = $Matches[1].Trim()
            if ($provider -and $provider -notmatch '^Microsoft$') {
                $name = if ($b -match 'Published Name\s*:\s*(.+)')   { $Matches[1].Trim() }
                $ofn  = if ($b -match 'Original Name\s*:\s*(.+)')    { $Matches[1].Trim() }
                $cls  = if ($b -match 'Class(?:ification| Name)?\s*:\s*(.+)') { $Matches[1].Trim() }
                $ver  = if ($b -match 'Driver Version\s*:\s*(.+)')   { $Matches[1].Trim() }
                [pscustomobject]@{ Provider=$provider; Class=$cls; Version=$ver; OEMInf=$name; Original=$ofn }
            }
        }
    }
    Add-Line "Total non-Microsoft drivers: $($thirdParty.Count)"
    Add-Line ""
    $thirdParty | Sort-Object Provider, Class | Format-Table Provider, Class, Version, Original -AutoSize | Out-String -Width 4096 | ForEach-Object { Add-Line $_ }
} catch { Add-Line "pnputil failed: $($_.Exception.Message)" }

#=== 10. Recovery + Disk ===
Add-Section "10. RECOVERY ENVIRONMENT & DISK"
Add-Line "--- reagentc /info ---"
$reInfo = & reagentc /info 2>&1
$reInfo | ForEach-Object { Add-Line $_ }
if (($reInfo -join "`n") -match 'Windows RE status\s*:\s*Disabled') {
    Add-Finding "MEDIUM" "RecoveryEnv" "Windows RE is disabled - some upgrade paths require it active"
}
Add-Line ""
Add-Line "--- Volumes ---"
try {
    Get-Volume | Where-Object DriveLetter | Select-Object DriveLetter, FileSystemLabel, FileSystem,
        @{n='SizeGB';e={[math]::Round($_.Size/1GB,1)}},
        @{n='FreeGB';e={[math]::Round($_.SizeRemaining/1GB,1)}} |
        Format-Table -AutoSize | Out-String -Width 4096 | ForEach-Object { Add-Line $_ }
} catch { Add-Line "Get-Volume failed: $($_.Exception.Message)" }

#=== 11. CBS errors (recent only) ===
Add-Section "11. CBS.LOG ERRORS (RECENT)"
$cbs = "$env:WinDir\Logs\CBS\CBS.log"
if (Test-Path $cbs) {
    $cbsSizeMB = [math]::Round((Get-Item $cbs).Length / 1MB, 1)
    Add-Line "CBS.log size: $cbsSizeMB MB"
    $tailLines = if ($cbsSizeMB -gt 50) { 5000 } else { 20000 }
    Add-Line "Reading last $tailLines lines..."
    $cbsTail = Get-Content $cbs -Tail $tailLines -ErrorAction SilentlyContinue
    $cbsErrors = $cbsTail | Select-String -Pattern 'error|failed|0x[0-9a-fA-F]{8}' | Select-Object -Last 50
    if ($cbsErrors) {
        Add-Line "Recent error/failure lines: $($cbsErrors.Count)"
        $cbsErrors | ForEach-Object { Add-Line $_.Line }
        $cbsCorruption = $cbsTail | Select-String -Pattern 'cannot repair|cannot fix|corruption' | Select-Object -First 5
        if ($cbsCorruption) { Add-Finding "HIGH" "CBS" "Component store corruption indicators in CBS.log - run DISM /RestoreHealth before retry" }
    } else {
        Add-Line "No recent errors in CBS.log tail."
    }
} else {
    Add-Line "CBS.log not found."
}

#=== 12. Bugchecks ===
Add-Section "12. RECENT BUGCHECKS"
try {
    $bcs = Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-WER-SystemErrorReporting'} -MaxEvents 5 -ErrorAction Stop
    if ($bcs) {
        foreach ($bc in $bcs) {
            Add-Line "$($bc.TimeCreated)  ID=$($bc.Id)"
            Add-Line "  $($bc.Message -replace '\r?\n',' ')"
            Add-Line ""
        }
        Add-Finding "MEDIUM" "Bugcheck" "$($bcs.Count) recent bugcheck event(s) - hardware/driver instability may be relevant"
    } else {
        Add-Line "No recent bugcheck events."
    }
} catch { Add-Line "No bugchecks found or query failed: $($_.Exception.Message)" }

#=== Synthesize verdict ===
$summary = [System.Collections.Generic.List[string]]::new()
$summary.Add("=" * 80)
$summary.Add("WINDOWS 11 UPGRADE DIAGNOSTIC REPORT")
$summary.Add("Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
$summary.Add("Machine:   $env:COMPUTERNAME")
$summary.Add("=" * 80)
$summary.Add("")
$summary.Add("EXECUTIVE SUMMARY")
$summary.Add("-" * 80)

$highFindings = @($findings | Where-Object Severity -eq 'HIGH')
$medFindings  = @($findings | Where-Object Severity -eq 'MEDIUM')

if ($isW11) {
    $summary.Add("Status:           ON WINDOWS 11 (build $build) - upgrade succeeded.")
} elseif ($highFindings.Count -gt 0) {
    $summary.Add("Status:           UPGRADE BLOCKED ($($highFindings.Count) high-severity findings)")
    $summary.Add("")
    $summary.Add("Top issues:")
    foreach ($f in $highFindings) { $summary.Add("  [$($f.Category)] $($f.Detail)") }
} else {
    $summary.Add("Status:           NO HIGH-SEVERITY ISSUES IDENTIFIED")
    $summary.Add("                  Manual review of details below required.")
}

if ($medFindings.Count -gt 0) {
    $summary.Add("")
    $summary.Add("Medium-severity findings:")
    foreach ($f in $medFindings) { $summary.Add("  [$($f.Category)] $($f.Detail)") }
}
$summary.Add("")

# Write final file
$summary + $out | Out-File -FilePath $OutFile -Encoding UTF8

# Console summary
Write-Host ""
Write-Host ("=" * 80) -ForegroundColor Cyan
Write-Host "WINDOWS 11 UPGRADE DIAGNOSTIC - $env:COMPUTERNAME" -ForegroundColor Cyan
Write-Host ("=" * 80) -ForegroundColor Cyan
if ($isW11) {
    Write-Host "Status: ON WINDOWS 11 (build $build)" -ForegroundColor Green
} elseif ($highFindings.Count -gt 0) {
    Write-Host "Status: BLOCKED - $($highFindings.Count) high-severity finding(s)" -ForegroundColor Red
    foreach ($f in $highFindings) { Write-Host "  [$($f.Category)] $($f.Detail)" -ForegroundColor Red }
    if ($medFindings.Count -gt 0) {
        Write-Host ""
        Write-Host "Medium-severity:" -ForegroundColor Yellow
        foreach ($f in $medFindings) { Write-Host "  [$($f.Category)] $($f.Detail)" -ForegroundColor Yellow }
    }
} else {
    Write-Host "Status: No clear blockers identified - review report" -ForegroundColor Yellow
}
Write-Host ""
Write-Host "Full report: $OutFile" -ForegroundColor Cyan
Write-Host ""

# Return structured object
[PSCustomObject]@{
    Computer    = $env:COMPUTERNAME
    Build       = $build
    IsWindows11 = $isW11
    Findings    = $findings
    ReportFile  = $OutFile
}
