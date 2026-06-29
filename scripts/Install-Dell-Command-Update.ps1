$url = Read-Host "Paste the Azure Blob URL for the DCU installer"
$exe = "C:\Temp\dcu.exe"
$log = "C:\Temp\DCU_install.log"

New-Item -ItemType Directory -Path "C:\Temp" -Force | Out-Null
Invoke-WebRequest -Uri $url -OutFile $exe -UseBasicParsing

$args = '/s /v"/qn /l*v ' + $log + '"'
Start-Process -FilePath $exe -ArgumentList $args -Wait

Test-Path "C:\Program Files\Dell\CommandUpdate\dcu-cli.exe"
