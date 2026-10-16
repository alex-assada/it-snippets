# Elevated ISE or Ninja remote shell (SYSTEM). Interactive - not for unattended Ninja runs.
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw "Run elevated" }

$pkg = Get-AppxPackage -AllUsers Microsoft.DesktopAppInstaller | Sort-Object { [version]$_.Version } | Select-Object -Last 1
if (-not $pkg) { throw "App Installer (winget) not provisioned on this machine" }
$winget = Join-Path $pkg.InstallLocation 'winget.exe'
if (-not (Test-Path $winget)) { throw "winget.exe not found in $($pkg.InstallLocation)" }
"winget $($pkg.Version): $winget"

:main while ($true) {

    # 1. search + Id (validated against winget)
    $id = $null
    while (-not $id) {
        $q = Read-Host "Search"
        if (-not $q) { continue }
        & $winget search $q --source winget --accept-source-agreements
        $in = Read-Host "Id to install (B = new search)"
        if (-not $in -or $in -eq 'B') { continue }
        & $winget show --id $in --exact --source winget --accept-source-agreements *> $null
        if ($LASTEXITCODE -ne 0) { "'$in' is not a valid winget Id, copy it from the Id column"; continue }
        $id = $in
    }

    # 2. scope + user
    $scope = $null; $user = $null; $prof = $null; $userWinget = $null
    :scopeloop while ($true) {
        $in = Read-Host "[A]ll users / [U]ser (B = back to search)"
        if ($in -eq 'B') { continue main }
        if ($in -eq 'A') { $scope = 'A'; break scopeloop }
        if ($in -ne 'U') { "Enter A, U or B"; continue scopeloop }

        $sessions = @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" | ForEach-Object {
            $o = Invoke-CimMethod -InputObject $_ -MethodName GetOwner
            $s = Invoke-CimMethod -InputObject $_ -MethodName GetOwnerSid
            if ($o.User) { [pscustomobject]@{ User = "$($o.Domain)\$($o.User)"; Sid = $s.Sid } }
        } | Sort-Object User -Unique)

        if (-not $sessions) { "No interactive sessions found, pick All users or go back"; continue scopeloop }
        "Logged-on users:"; $sessions.User

        while (-not $user) {
            $in = Read-Host "Username as listed (B = back to A/U)"
            if ($in -eq 'B') { continue scopeloop }
            $sel = $sessions | Where-Object User -eq $in
            if (-not $sel) { "Not in the list, copy it exactly"; continue }

            $prof = (Get-CimInstance Win32_UserProfile -Filter "SID='$($sel.Sid)'").LocalPath
            $userWinget = Join-Path $prof 'AppData\Local\Microsoft\WindowsApps\winget.exe'
            if (-not (Test-Path $userWinget)) { "winget alias missing for $in (App Installer not registered in that profile)"; continue }
            $user = $sel
        }
        $scope = 'U'; break scopeloop
    }

    # 3. confirm
    $target = if ($scope -eq 'U') { $user.User } else { 'ALL users' }
    $ok = Read-Host "Install $id for $target? [y/n]"
    if ($ok -ne 'y') { continue main }
    break
}

$code = $null

if ($scope -eq 'A') {
    & $winget install --id $id --exact --source winget --scope machine --silent --accept-package-agreements --accept-source-agreements --disable-interactivity
    $code = $LASTEXITCODE
}
else {
    # Hidden PowerShell wrapper: no console window on the user's desktop, exit code propagates
    $tn  = "WingetInstall_" + [guid]::NewGuid().ToString('N').Substring(0,8)
    $cmd = "& '$($userWinget.Replace("'","''"))' install --id $id --exact --source winget --scope user --silent --accept-package-agreements --accept-source-agreements --disable-interactivity; exit `$LASTEXITCODE"
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))

    $act  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand $enc"
    $prin = New-ScheduledTaskPrincipal -UserId $user.User -LogonType Interactive -RunLevel Limited
    $set  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

    try {
        Register-ScheduledTask -TaskName $tn -Action $act -Principal $prin -Settings $set -Force -ErrorAction Stop | Out-Null
        Start-ScheduledTask -TaskName $tn -ErrorAction Stop
        "Running as $($user.User) (task $tn)..."

        # 267009 = running, 267011 = not run yet -> wait past both, never trust the first 'Ready'
        $deadline = (Get-Date).AddMinutes(30)
        do {
            Start-Sleep 3
            $state = (Get-ScheduledTask -TaskName $tn).State
            $code  = (Get-ScheduledTaskInfo -TaskName $tn).LastTaskResult
        } while (($state -ne 'Ready' -or $code -in 267009, 267011) -and (Get-Date) -lt $deadline)

        if ((Get-Date) -ge $deadline) { Stop-ScheduledTask -TaskName $tn; "TIMEOUT after 30 min, task stopped" }
    }
    catch { "ERROR: $_"; $code = -1 }
    finally { Unregister-ScheduledTask -TaskName $tn -Confirm:$false -ErrorAction SilentlyContinue }

    # winget's own log from the user's profile (the task output itself isn't captured)
    $diag = Join-Path $prof 'AppData\Local\Packages\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\LocalState\DiagOutputDir'
    $log  = Get-ChildItem $diag -Filter '*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1
    if ($log) { "--- $($log.FullName) (last 20 lines)"; Get-Content $log.FullName -Tail 20 }
}

# Machine branch returns Int32, task branch UInt32 - hex makes them comparable
$hex = '{0:X8}' -f $code
$codes = @{
    '00000000' = 'OK: installed'
    '8A15002B' = 'OK: already installed, no applicable upgrade'
    '8A150061' = 'OK: already installed'
    '8A150010' = 'FAIL: no installer for this scope/arch - try the other scope'
    'C0000135' = 'FAIL: DLL not found - VC++ 2015-2022 x64 runtime missing'
    '00041301' = 'FAIL: still running at timeout'
}
$msg = if ($codes[$hex]) { $codes[$hex] } else { "unknown - run: winget error 0x$hex" }
"Result: $code (0x$hex) - $msg"
