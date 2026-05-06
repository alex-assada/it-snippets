$search = Read-Host "Enter search term"

Get-Service | Where-Object {
    $_.DisplayName -match $search
}
