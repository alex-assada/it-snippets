<#
Remove-NinjaOrphans
Symptom : Ninja MSI install aborts at LaunchConditions (Return value 3):
          "An existing version of NinjaRMMAgent is already installed",
          or "installation prohibited by policy" (1625) with no real policy set.
Cause   : Incomplete agent removal. Orphaned service, folders, Installer\Products,
          Installer\UserData, Installer\UpgradeCodes and vendor/uninstall keys remain.
Fix     : Remove the above, then reinstall elevated (or as SYSTEM).
Notes   : Force-cleanup, not a substitute for the vendor uninstaller on a healthy agent.
          Destructive when confirmed. Run elevated. Non-interactive hosts = dry run only.
          No warranty. Test before use.
#>
$ErrorActionPreference = 'SilentlyContinue'
$roots   = 'C:\Program Files','C:\Program Files (x86)','C:\ProgramData'
$uninst  = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
$ud      = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products'
$targets = New-Object System.Collections.Generic.List[object]
$flags   = @()

function Add-Target($kind, $target) {
  if ($targets.Target -notcontains $target) { $targets.Add([pscustomobject]@{ Kind = $kind; Target = $target }) }
}
function Ask($q) {
  do { $a = Read-Host "$q (Y/N)" } until ($a -match '^[YyNn]')
  $a -match '^[Yy]'
}

# ---------- scan (no changes) ----------
foreach ($s in 'NinjaRMMAgent','nmsmanager') { if (Get-Service $s) { Add-Target 'service' $s } }
Get-Process NinjaRMM* | Select-Object -ExpandProperty Name -Unique | ForEach-Object { Add-Target 'process' $_ }
Get-ChildItem $roots -Directory -Filter 'NinjaRMM*' | ForEach-Object { Add-Target 'folder' $_.FullName }

$packed = @()
Get-ChildItem $ud | ForEach-Object {
  $p = Get-ItemProperty "$($_.PSPath)\InstallProperties"
  if ($p.DisplayName -eq 'NinjaRMMAgent') { $packed += $_.PSChildName }
}
Get-ChildItem 'HKLM:\SOFTWARE\Classes\Installer\Products' | ForEach-Object {
  $p = Get-ItemProperty $_.PSPath
  if ($p.ProductName -eq 'NinjaRMMAgent') { $packed += $_.PSChildName }
  elseif ($p.ProductName -like '*Ninja*') { $flags += "MSI product : $($p.ProductName)  [$($_.Name)]" }
}
foreach ($g in ($packed | Select-Object -Unique)) {
  foreach ($k in "$ud\$g","HKLM:\SOFTWARE\Classes\Installer\Products\$g","HKLM:\SOFTWARE\Classes\Installer\Features\$g") {
    if (Test-Path $k) { Add-Target 'key' $k }
  }
  Get-ChildItem 'HKLM:\SOFTWARE\Classes\Installer\UpgradeCodes' | Where-Object { $_.GetValueNames() -contains $g } | ForEach-Object { Add-Target 'key' "Registry::$($_.Name)" }
}

foreach ($k in $uninst) {
  Get-ChildItem $k | ForEach-Object {
    $p = Get-ItemProperty $_.PSPath
    if ($p.DisplayName -eq 'NinjaRMMAgent') { Add-Target 'key' "Registry::$($_.Name)" }
    elseif ($p.DisplayName -like '*Ninja*') { $flags += "uninstall entry : $($p.DisplayName)  [$($_.Name)]" }
  }
}
foreach ($k in 'HKLM:\SOFTWARE\NinjaRMM LLC','HKLM:\SOFTWARE\WOW6432Node\NinjaRMM LLC','HKLM:\SOFTWARE\WOW6432Node\WOW6432Node\NinjaRMM LLC','HKLM:\SYSTEM\CurrentControlSet\Services\NinjaRMMAgent','HKLM:\SYSTEM\CurrentControlSet\Services\nmsmanager') {
  if (Test-Path $k) { Add-Target 'key' $k }
}
foreach ($k in 'HKLM:\SOFTWARE\EXEMSI.COM\MSI Wrapper\Installed','HKLM:\SOFTWARE\WOW6432Node\EXEMSI.COM\MSI Wrapper\Installed') {
  Get-ChildItem $k | Where-Object Name -like '*NinjaRMMAgent*' | ForEach-Object { Add-Target 'key' "Registry::$($_.Name)" }
}

# ---------- flags: other Ninja-named items, never touched ----------
Get-Service *ninja* | Where-Object { 'NinjaRMMAgent','nmsmanager' -notcontains $_.Name } | ForEach-Object { $flags += "service : $($_.Name) ($($_.DisplayName))" }
Get-ChildItem $roots -Directory -Filter '*Ninja*' | Where-Object Name -notlike 'NinjaRMM*' | ForEach-Object { $flags += "folder : $($_.FullName)" }

# ---------- report ----------
"--- targets ($($targets.Count))"
if ($targets.Count -eq 0) { "nothing to remove" } else { $targets | ForEach-Object { "[TARGET] $($_.Kind) : $($_.Target)" } }
"--- flagged, NOT touched ($($flags.Count))"
if ($flags.Count -eq 0) { "none" } else { $flags | ForEach-Object { "[FLAG] $_" } }

if ($targets.Count -eq 0) { return }

# ---------- decide ----------
if (-not [Environment]::UserInteractive) { "Non-interactive host: dry run only, nothing changed."; return }
if (Ask 'Dry run only?') {
  if (-not (Ask 'Remove the targets listed above now?')) { "Dry run complete, nothing changed."; return }
}

# ---------- remove ----------
"--- removing"
foreach ($i in $targets) {
  switch ($i.Kind) {
    'service' { Stop-Service $i.Target -Force; sc.exe delete $i.Target | Out-Null }
    'process' { Stop-Process -Name $i.Target -Force }
    'folder'  { cmd.exe /c rd /s /q "`"$($i.Target)`"" }
    'key'     { Remove-Item -LiteralPath $i.Target -Recurse -Force }
  }
  $gone = switch ($i.Kind) {
    'service' { -not (Get-Service $i.Target) }
    'process' { -not (Get-Process -Name $i.Target) }
    default   { -not (Test-Path -LiteralPath $i.Target) }
  }
  if ($gone) { "[REMOVED] $($i.Kind) : $($i.Target)" } else { "[FAILED]  $($i.Kind) : $($i.Target)" }
}
"--- done. If a service shows FAILED it's likely pending deletion: reboot, then install."
