$OutRoot = "C:\Temp\BitLocker-Diag"
$ZipPath = "C:\Temp\BitLocker-Diag.zip"
$TranscriptPath = Join-Path $OutRoot "00-transcript.txt"

New-Item -ItemType Directory -Path $OutRoot -Force | Out-Null

if (Test-Path $ZipPath) {
    Remove-Item $ZipPath -Force
}

Start-Transcript -Path $TranscriptPath -Force | Out-Null

function Write-Section {
    param(
        [string]$Title,
        [string]$Path
    )

    "`r`n================================================================================" | Out-File $Path -Append -Encoding UTF8
    " $Title" | Out-File $Path -Append -Encoding UTF8
    "================================================================================`r`n" | Out-File $Path -Append -Encoding UTF8
}

function Run-Cmd {
    param(
        [string]$Title,
        [scriptblock]$Command,
        [string]$FileName
    )

    $Path = Join-Path $OutRoot $FileName
    Write-Section -Title $Title -Path $Path

    try {
        & $Command 2>&1 | Out-File $Path -Append -Encoding UTF8 -Width 500
    }
    catch {
        "ERROR: $($_.Exception.Message)" | Out-File $Path -Append -Encoding UTF8
    }
}

$Now = Get-Date
$Start30 = $Now.AddDays(-30)
$Start14 = $Now.AddDays(-14)
$Start7  = $Now.AddDays(-7)

Run-Cmd "Basic system info" {
    hostname
    whoami /all
    Get-Date
    Get-CimInstance Win32_OperatingSystem | Format-List *
    Get-CimInstance Win32_ComputerSystem | Format-List *
    Get-CimInstance Win32_ComputerSystemProduct | Format-List *
    Get-CimInstance Win32_BIOS | Format-List *
} "01-system-info.txt"

Run-Cmd "BitLocker current state" {
    Get-BitLockerVolume | Format-List *
    manage-bde -status
    manage-bde -status C:
    manage-bde -protectors -get C:
} "02-bitlocker-current-state.txt"

Run-Cmd "TPM and Secure Boot state" {
    Get-Tpm | Format-List *
    Confirm-SecureBootUEFI
} "03-tpm-secureboot.txt"

Run-Cmd "BCD boot configuration" {
    bcdedit /enum all
} "04-bcdedit-all.txt"

Run-Cmd "Filtered BCD boot flags" {
    bcdedit /enum all | findstr /i "identifier description device path osdevice recoveryenabled testsigning nointegritychecks debug bootmenupolicy hypervisorlaunchtype bootstatuspolicy nx pae"
} "05-bcdedit-filtered.txt"

Run-Cmd "BitLocker FVE policy registry" {
    reg query HKLM\SOFTWARE\Policies\Microsoft\FVE /s
} "06-reg-fve-policy.txt"

Run-Cmd "MDM PolicyManager BitLocker current device" {
    reg query HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\BitLocker /s
} "07-reg-policymanager-current-bitlocker.txt"

Run-Cmd "MDM PolicyManager Providers BitLocker" {
    reg query HKLM\SOFTWARE\Microsoft\PolicyManager\Providers /s | findstr /i "BitLocker RequireDeviceEncryption EncryptionMethod SystemDrives FixedDrives RecoveryPassword ConfigureRecovery AllowWarning AllowStandard"
} "08-reg-policymanager-providers-bitlocker-filtered.txt"

Run-Cmd "MDM enrollments summary" {
    reg query HKLM\SOFTWARE\Microsoft\Enrollments /s | findstr /i "UPN ProviderID EnrollmentType DiscoveryServiceFullURL Tenant AADTenantID MDM"
    reg query HKLM\SOFTWARE\Microsoft\Enrollments\Status /s
    reg query HKLM\SOFTWARE\Microsoft\Provisioning\OMADM\Accounts /s
} "09-mdm-enrollment-summary.txt"

Run-Cmd "dsregcmd status" {
    dsregcmd /status
} "10-dsregcmd-status.txt"

Run-Cmd "BitLocker scheduled tasks" {
    Get-ScheduledTask -TaskPath "\Microsoft\Windows\BitLocker\" | Format-List *
    Get-ScheduledTaskInfo -TaskPath "\Microsoft\Windows\BitLocker\" -TaskName "BitLocker MDM policy Refresh"
    Get-ScheduledTaskInfo -TaskPath "\Microsoft\Windows\BitLocker\" -TaskName "BitLocker Encrypt All Drives"
} "11-bitlocker-scheduled-tasks.txt"

Run-Cmd "EnterpriseMgmt scheduled tasks" {
    Get-ScheduledTask -TaskPath "\Microsoft\Windows\EnterpriseMgmt\" -ErrorAction SilentlyContinue | Format-List *
    Get-ScheduledTask -TaskPath "\Microsoft\Windows\EnterpriseMgmt\" -ErrorAction SilentlyContinue |
        ForEach-Object {
            "`r`n===== $($_.TaskPath)$($_.TaskName) ====="
            Get-ScheduledTaskInfo -TaskPath $_.TaskPath -TaskName $_.TaskName
        }
} "12-enterprisemgmt-scheduled-tasks.txt"

Run-Cmd "Task Scheduler Operational events related to BitLocker / MDM / firmware / update" {
    Get-WinEvent -FilterHashtable @{
        LogName   = "Microsoft-Windows-TaskScheduler/Operational"
        StartTime = $Start30
    } -ErrorAction SilentlyContinue |
    Where-Object {
        $_.Message -match "BitLocker|EnterpriseMgmt|MDM|DeviceEnroller|Schedule created by enrollment|Firmware|BIOS|UEFI|Update"
    } |
    Select-Object TimeCreated, Id, ProviderName, LevelDisplayName, Message |
    Format-List
} "13-events-taskscheduler-filtered.txt"

Run-Cmd "BitLocker event logs all available" {
    Get-WinEvent -ListLog *BitLocker* | Format-Table -AutoSize

    Get-WinEvent -ListLog *BitLocker* |
    ForEach-Object {
        "`r`n===== $($_.LogName) ====="
        Get-WinEvent -LogName $_.LogName -MaxEvents 500 -ErrorAction SilentlyContinue |
        Select-Object TimeCreated, Id, ProviderName, LevelDisplayName, Message |
        Format-List
    }
} "14-events-bitlocker-all.txt"

Run-Cmd "BitLocker events filtered recovery/protector/rotation/suspend" {
    Get-WinEvent -LogName "Microsoft-Windows-BitLocker/BitLocker Management" -MaxEvents 1000 -ErrorAction SilentlyContinue |
    Where-Object {
        $_.Message -match "recovery|protector|TPM|PCR|Secure Boot|suspend|resume|rotation|backup|escrow|AAD|Azure|Entra|numerical|password|pin|startup"
    } |
    Select-Object TimeCreated, Id, ProviderName, LevelDisplayName, Message |
    Format-List
} "15-events-bitlocker-filtered.txt"

Run-Cmd "System events last 30 days TPM SecureBoot Firmware BIOS Boot BitLocker Update" {
    Get-WinEvent -FilterHashtable @{
        LogName   = "System"
        StartTime = $Start30
    } -ErrorAction SilentlyContinue |
    Where-Object {
        $_.ProviderName -match "TPM|BitLocker|Kernel-Boot|WindowsUpdateClient|Servicing|UserPnp|DeviceSetupManager|Kernel-PnP" -or
        $_.Message -match "TPM|BitLocker|Secure Boot|SecureBoot|firmware|BIOS|UEFI|boot|recovery|PCR|BitLocker Drive Encryption|System Firmware|Capsule|Lenovo"
    } |
    Select-Object TimeCreated, Id, ProviderName, LevelDisplayName, Message |
    Format-List
} "16-events-system-filtered-30days.txt"

Run-Cmd "Setup log events last 30 days" {
    Get-WinEvent -FilterHashtable @{
        LogName   = "Setup"
        StartTime = $Start30
    } -ErrorAction SilentlyContinue |
    Select-Object TimeCreated, Id, ProviderName, LevelDisplayName, Message |
    Format-List
} "17-events-setup-30days.txt"

Run-Cmd "Windows Update events last 30 days" {
    Get-WinEvent -FilterHashtable @{
        LogName      = "System"
        ProviderName = "Microsoft-Windows-WindowsUpdateClient"
        StartTime    = $Start30
    } -ErrorAction SilentlyContinue |
    Select-Object TimeCreated, Id, ProviderName, LevelDisplayName, Message |
    Format-List
} "18-events-windowsupdate-30days.txt"

Run-Cmd "PowerShell operational BitLocker commands" {
    Get-WinEvent -LogName "Microsoft-Windows-PowerShell/Operational" -MaxEvents 5000 -ErrorAction SilentlyContinue |
    Where-Object {
        $_.Message -match "BitLocker|manage-bde|Enable-BitLocker|Disable-BitLocker|Suspend-BitLocker|Resume-BitLocker|Add-BitLockerKeyProtector|Remove-BitLockerKeyProtector|Backup-BitLockerKeyProtector"
    } |
    Select-Object TimeCreated, Id, ProviderName, LevelDisplayName, Message |
    Format-List
} "19-events-powershell-bitlocker.txt"

Run-Cmd "Recent hotfixes" {
    Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 100 | Format-Table -AutoSize
} "20-hotfixes.txt"

Run-Cmd "Firmware and driver PnP inventory" {
    Get-CimInstance Win32_PnPSignedDriver |
    Where-Object {
        $_.DeviceName -match "firmware|BIOS|TPM|Trusted|Security|System Firmware|UEFI|Lenovo|Intel" -or
        $_.DriverProviderName -match "Lenovo|Intel|Microsoft"
    } |
    Select-Object DeviceName, DriverVersion, DriverDate, DriverProviderName, InfName, Manufacturer |
    Sort-Object DeviceName |
    Format-Table -AutoSize
} "21-firmware-driver-inventory.txt"

Run-Cmd "Services likely related to management/security/update" {
    Get-CimInstance Win32_Service |
    Where-Object {
        $_.Name -match "Intune|dmwappush|DmEnrollment|Sense|Defender|Ninja|CyberCNS|Covalence|Lenovo|Vantage|SystemUpdate|TPM|BDESVC|CcmExec|ManageEngine|Tanium|BigFix|Ivanti|Automox|Datto|Kaseya|Action1" -or
        $_.DisplayName -match "Intune|Device Management|Defender|Ninja|CyberCNS|Covalence|Lenovo|Vantage|System Update|TPM|BitLocker|Configuration Manager|ManageEngine|Tanium|BigFix|Ivanti|Automox|Datto|Kaseya|Action1"
    } |
    Select-Object Name, DisplayName, State, StartMode, PathName |
    Format-List
} "22-services-management-security.txt"

Run-Cmd "Relevant scheduled tasks inventory" {
    Get-ScheduledTask |
    Where-Object {
        $_.TaskName -match "BitLocker|EnterpriseMgmt|MDM|Device|Enrollment|Firmware|BIOS|Lenovo|Vantage|SystemUpdate|Ninja|CyberCNS|Covalence|Update" -or
        $_.TaskPath -match "BitLocker|EnterpriseMgmt|MDM|Device|Enrollment|Firmware|BIOS|Lenovo|Vantage|SystemUpdate|Ninja|CyberCNS|Covalence|Update"
    } |
    ForEach-Object {
        "`r`n===== $($_.TaskPath)$($_.TaskName) ====="
        $_ | Format-List *
        "`r`n--- Info ---"
        Get-ScheduledTaskInfo -TaskPath $_.TaskPath -TaskName $_.TaskName -ErrorAction SilentlyContinue | Format-List *
        "`r`n--- Actions ---"
        $_.Actions | Format-List *
        "`r`n--- Triggers ---"
        $_.Triggers | Format-List *
    }
} "23-scheduled-tasks-relevant.txt"

Run-Cmd "ReAgentC Windows Recovery Environment" {
    reagentc /info
} "24-reagentc.txt"

Run-Cmd "Recovery key escrow local evidence" {
    Get-WinEvent -LogName "Microsoft-Windows-BitLocker/BitLocker Management" -MaxEvents 1000 -ErrorAction SilentlyContinue |
    Where-Object {
        $_.Message -match "backup|escrow|AAD|Azure|Entra|recovery password|recovery key|protector"
    } |
    Select-Object TimeCreated, Id, ProviderName, LevelDisplayName, Message |
    Format-List
} "25-recovery-key-escrow-events.txt"

Run-Cmd "MDMDiagnosticsTool report" {
    $MdmOut = Join-Path $OutRoot "MDMDiag"
    New-Item -ItemType Directory -Path $MdmOut -Force | Out-Null

    if (Get-Command MDMDiagnosticstool.exe -ErrorAction SilentlyContinue) {
        MDMDiagnosticstool.exe -area DeviceEnrollment;DeviceProvisioning;Policy;BitLocker -cab (Join-Path $MdmOut "MDMDiag.cab")
        Get-ChildItem $MdmOut -Recurse | Select-Object FullName, Length, LastWriteTime | Format-Table -AutoSize
    } else {
        "MDMDiagnosticstool.exe not found"
    }
} "26-mdmdiagnosticstool.txt"

Run-Cmd "Ninja/CyberCNS/Covalence path inventory only" {
    Get-CimInstance Win32_Service |
    Where-Object {
        $_.Name -match "Ninja|CyberCNS|Covalence" -or
        $_.DisplayName -match "Ninja|CyberCNS|Covalence"
    } |
    Select-Object Name, DisplayName, State, StartMode, PathName |
    Format-List

    $paths = @(
        "C:\ProgramData\NinjaRMMAgent",
        "C:\Program Files\NinjaRMMAgent",
        "C:\Program Files (x86)\NinjaRMMAgent",
        "C:\ProgramData\NinjaOne",
        "C:\Program Files\NinjaOne",
        "C:\Program Files (x86)\NinjaOne",
        "C:\ProgramData\CyberCNS",
        "C:\Program Files\CyberCNS",
        "C:\Program Files (x86)\CyberCNS",
        "C:\ProgramData\Covalence",
        "C:\Program Files\Covalence",
        "C:\Program Files (x86)\Covalence"
    )

    foreach ($p in $paths) {
        if (Test-Path $p) {
            "`r`n===== $p ====="
            Get-ChildItem $p -Recurse -ErrorAction SilentlyContinue |
            Select-Object FullName, Length, LastWriteTime |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 200 |
            Format-Table -AutoSize
        }
    }
} "27-rmm-agent-inventory.txt"

Run-Cmd "Search management agent files for BitLocker strings" {
    $paths = @(
        "C:\ProgramData\NinjaRMMAgent",
        "C:\Program Files\NinjaRMMAgent",
        "C:\Program Files (x86)\NinjaRMMAgent",
        "C:\ProgramData\NinjaOne",
        "C:\Program Files\NinjaOne",
        "C:\Program Files (x86)\NinjaOne",
        "C:\ProgramData\CyberCNS",
        "C:\Program Files\CyberCNS",
        "C:\Program Files (x86)\CyberCNS",
        "C:\ProgramData\Covalence",
        "C:\Program Files\Covalence",
        "C:\Program Files (x86)\Covalence"
    )

    foreach ($p in $paths) {
        if (Test-Path $p) {
            "`r`n===== Searching $p ====="
            Get-ChildItem $p -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Length -lt 20MB } |
            ForEach-Object {
                try {
                    Select-String -Path $_.FullName `
                        -Pattern "BitLocker","manage-bde","Enable-BitLocker","Suspend-BitLocker","Resume-BitLocker","Add-BitLockerKeyProtector","RecoveryPassword","recovery key","encryption" `
                        -ErrorAction Stop
                } catch {}
            }
        }
    }
} "28-rmm-agent-bitlocker-string-search.txt"

Run-Cmd "BitLocker summary parsed" {
    $bl = Get-BitLockerVolume -MountPoint C:
    [PSCustomObject]@{
        ComputerName         = $env:COMPUTERNAME
        Time                 = Get-Date
        MountPoint           = $bl.MountPoint
        VolumeStatus         = $bl.VolumeStatus
        ProtectionStatus     = $bl.ProtectionStatus
        EncryptionPercentage = $bl.EncryptionPercentage
        EncryptionMethod     = $bl.EncryptionMethod
        LockStatus           = $bl.LockStatus
        KeyProtectorTypes    = ($bl.KeyProtector | ForEach-Object { $_.KeyProtectorType }) -join ", "
        KeyProtectorIds      = ($bl.KeyProtector | ForEach-Object { $_.KeyProtectorId }) -join ", "
    } | Format-List
} "99-summary.txt"

Stop-Transcript | Out-Null

Compress-Archive -Path "$OutRoot\*" -DestinationPath $ZipPath -Force

Write-Host ""
Write-Host "Done." -ForegroundColor Green
Write-Host "Folder: $OutRoot"
Write-Host "Zip:    $ZipPath"
