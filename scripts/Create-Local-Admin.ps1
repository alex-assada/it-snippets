# =====================================================================
# Create or reset a local admin account (language-independent)
# =====================================================================

$Username = Read-Host "Enter username"
$SecurePassword = Read-Host "Enter password for $Username" -AsSecureString

# --- Resolve the local Administrators group by well-known SID ---
try {
    $adminSid   = [System.Security.Principal.SecurityIdentifier]"S-1-5-32-544"
    $adminGroup = (Get-LocalGroup -SID $adminSid).Name
    Write-Host "Resolved admin group: '$adminGroup'"
} catch {
    Write-Error "Could not resolve the local Administrators group by SID: $($_.Exception.Message)"
    exit 1
}

# --- Create or reset the account ---
try {
    $user = Get-LocalUser -Name $Username -ErrorAction SilentlyContinue
    if (-not $user) {
        New-LocalUser -Name $Username `
                      -Password $SecurePassword `
                      -PasswordNeverExpires `
                      -AccountNeverExpires `
                      -Description "Local admin account" | Out-Null
        Write-Host "User '$Username' created."
    } else {
        Set-LocalUser -Name $Username -Password $SecurePassword
        Enable-LocalUser -Name $Username -ErrorAction SilentlyContinue
        Set-LocalUser -Name $Username -PasswordNeverExpires $true
        Write-Host "User '$Username' existed — password reset and re-enabled."
    }
}
catch {
    Write-Error "Failed to create or update user: $($_.Exception.Message)"
    exit 1
}

# --- Add the user to Administrators ---
try {
    Add-LocalGroupMember -SID $adminSid -Member $Username -ErrorAction Stop
    Write-Host "Added '$Username' to '$adminGroup'."
} catch {
    if ($_.Exception.Message -match "already a member|déjà membre") {
        Write-Host "'$Username' is already a member of '$adminGroup'."
    } else {
        Write-Error "Could not add '$Username' to '$adminGroup': $($_.Exception.Message)"
        exit 1
    }
}

Write-Host ""
Write-Host "------------------------------"
Write-Host "Local admin '$Username' is ready for use."
Write-Host "------------------------------"
