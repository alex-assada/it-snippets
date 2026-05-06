$pb = "$env:WINDIR\System32\spool\tools\PrintBrm.exe"
$tempPath = Join-Path $env:TEMP "PrinterRestore"
New-Item -ItemType Directory -Path $tempPath -Force | Out-Null
$url = Read-Host "Enter the Azure Blob URL for the .printerExport file"
$fileName = [System.IO.Path]::GetFileName(([System.Uri]$url).AbsolutePath)
$localFile = Join-Path $tempPath $fileName
Invoke-WebRequest -Uri $url -OutFile $localFile -UseBasicParsing
& $pb -R -F $localFile -O FORCE
