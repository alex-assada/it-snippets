$systemDisk = Get-Partition | Where-Object { $_.IsBoot -eq $true } | Get-Disk
$systemDisk | Select-Object Number, FriendlyName, PartitionStyle
