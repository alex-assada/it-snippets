$defaultRoute = Get-NetRoute -DestinationPrefix "0.0.0.0/0" |
    Where-Object { $_.NextHop -ne "0.0.0.0" -and $_.RouteMetric -ne $null } |
    Sort-Object RouteMetric, InterfaceMetric |
    Select-Object -First 1

$defaultInterfaceIndex = $defaultRoute.InterfaceIndex

# Get currently connected Wi-Fi SSID
$wifiInfo = netsh wlan show interfaces 2>$null

$currentSsid = ($wifiInfo | Where-Object {
    $_ -match '^\s*SSID\s*:'
}) -replace '^\s*SSID\s*:\s*', ''

# Avoid grabbing BSSID
$currentSsid = $currentSsid | Select-Object -First 1

Get-NetAdapter | Sort-Object Status, Name | ForEach-Object {
    $adapter = $_

    $ipConfig = Get-NetIPConfiguration -InterfaceIndex $adapter.ifIndex -ErrorAction SilentlyContinue
    $ipv4 = ($ipConfig.IPv4Address.IPAddress -join ", ")
    $gateway = ($ipConfig.IPv4DefaultGateway.NextHop -join ", ")

    $isWifi = $adapter.InterfaceDescription -match 'Wi-Fi|Wireless|802\.11|WLAN' -or
              $adapter.Name -match 'Wi-Fi|Wireless|WLAN'

    $ssid = if ($isWifi -and $adapter.Status -eq "Up" -and $currentSsid) {
        $currentSsid
    } else {
        ""
    }

    $line = "{0,-8} {1,-25} {2,-12} {3,-15} {4,-20} {5,-20} {6}" -f `
        $adapter.ifIndex,
        $adapter.Name,
        $adapter.Status,
        $adapter.LinkSpeed,
        $ipv4,
        $gateway,
        $ssid

    if ($adapter.ifIndex -eq $defaultInterfaceIndex) {
        Write-Host $line -ForegroundColor Green
    } else {
        Write-Host $line
    }
}
