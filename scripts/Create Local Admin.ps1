# =====================================================================
# Create or reset a bilingual local admin account
# Compatible with English and French Windows systems
# =====================================================================

# --- Prompt for username (FIXED: must be plain string) ---
$Username = Read-Host "Enter username"

# --- Prompt for password (secure input) ---
$SecurePassword = Read-Host "Enter password for $Username" -AsSecureString

# --- Create or reset the account ---
try {
    $user = Get-LocalUser -Name $Username -ErrorAction SilentlyContinue
    if (-not $user) {
        New-LocalUser -Name $Username -Password $SecurePassword -AccountNeverExpires -Description "Local admin account"
        Write-Host "User '$Username' created successfully."
    } else {
        Set-LocalUser -Name $Username -Password $SecurePassword
        Enable-LocalUser -Name $Username -ErrorAction SilentlyContinue
        Write-Host "User '$Username' existed — password reset and re-enabled."
    }

    # Ensure password never expires
    Set-LocalUser -Name $Username -PasswordNeverExpires $true
}
catch {
    Write-Error "Failed to create or update user: $($_.Exception.Message)"
    exit 1
}

# --- Detect system language ---
try {
    $systemLanguage = (Get-WinSystemLocale).Name.ToLower()
    if ($systemLanguage -like "*fr*") {
        $adminGroup = "Administrateurs"
        Write-Host "French environment detected."
    } elseif ($systemLanguage -like "*en*") {
        $adminGroup = "Administrators"
        Write-Host "English environment detected."
    } else {
        Write-Host "Unsupported system language. Defaulting to both EN and FR admin groups."
        $adminGroup = $null
    }
} catch {
    Write-Warning "Could not detect system language, will try both EN/FR groups."
    $adminGroup = $null
}

# --- Add the user to the local Administrators group (robust bilingual logic) ---
function Add-ToAdminGroups {
    param([string]$UserName)

    $groups = @("Administrators", "Administrateurs")
    if ($adminGroup) { $groups = @($adminGroup) }

    foreach ($grp in $groups) {
        try {
            Add-LocalGroupMember -Group $grp -Member $UserName -ErrorAction Stop
            Write-Host "Added '$UserName' to group '$grp'."
        } catch {
            if ($_.Exception.Message -notmatch "exists") {
                Write-Warning "Could not add '$UserName' to group '$grp': $($_.Exception.Message)"
            } else {
                Write-Host "'$UserName' is already a member of '$grp'."
            }
        }
    }
}

Add-ToAdminGroups -UserName $Username

Write-Host ""
Write-Host "------------------------------"
Write-Host "Local admin '$Username' is ready for use."
Write-Host "------------------------------"
