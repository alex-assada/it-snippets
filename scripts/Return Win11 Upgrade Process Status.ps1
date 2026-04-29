Get-Process Win11Upgrade, Windows10UpgraderApp, SetupHost -ErrorAction SilentlyContinue |
  Select ProcessName, Id, CPU, @{n='MemMB';e={[math]::Round($_.WorkingSet64/1MB,1)}}
