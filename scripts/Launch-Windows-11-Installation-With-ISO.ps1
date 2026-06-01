$isos = Get-ChildItem -Path "C:\Users\Public\Downloads" -Filter *.iso -File

for ($i = 0; $i -lt $isos.Count; $i++) {
    Write-Host "$($i+1)) $($isos[$i].Name)"
}
$choice = Read-Host "Which ISO?"
$selectedIso = $isos[[int]$choice - 1]

$mount = Mount-DiskImage -ImagePath $selectedIso.FullName -PassThru
$driveLetter = ($mount | Get-Volume).DriveLetter

Set-Location "${driveLetter}:\"
.\setup.exe /auto upgrade /quiet /eula accept /dynamicupdate enable /compat ignorewarning /noreboot
