function Invoke-ServiceFzf {
    $filter = ""
    $selectedIndex = 0

    while ($true) {
        Clear-Host

        $services = Get-Service |
            Where-Object {
                $_.Name -like "*$filter*" -or $_.DisplayName -like "*$filter*"
            } |
            Sort-Object DisplayName |
            Select-Object -First 15

        Write-Host "Service search: " -NoNewline -ForegroundColor Cyan
        Write-Host $filter
        Write-Host ""
        Write-Host "Type to filter | Up/Down to select | Enter to choose | Esc to cancel"
        Write-Host ""

        if (-not $services) {
            Write-Host "No matches." -ForegroundColor Yellow
        }
        else {
            if ($selectedIndex -ge $services.Count) {
                $selectedIndex = $services.Count - 1
            }

            for ($i = 0; $i -lt $services.Count; $i++) {
                $svc = $services[$i]
                $line = "{0,-12} {1,-35} {2}" -f $svc.Status, $svc.Name, $svc.DisplayName

                if ($i -eq $selectedIndex) {
                    Write-Host "> $line" -ForegroundColor Black -BackgroundColor Gray
                }
                else {
                    Write-Host "  $line"
                }
            }
        }

        $key = [Console]::ReadKey($true)

        if ($key.Key -eq "Escape") {
            Clear-Host
            Write-Host "Cancelled." -ForegroundColor Yellow
            return
        }

        if ($key.Key -eq "Enter") {
            if ($services) {
                $service = $services[$selectedIndex]
                break
            }
        }

        if ($key.Key -eq "UpArrow") {
            if ($selectedIndex -gt 0) {
                $selectedIndex--
            }
        }
        elseif ($key.Key -eq "DownArrow") {
            if ($services -and $selectedIndex -lt ($services.Count - 1)) {
                $selectedIndex++
            }
        }
        elseif ($key.Key -eq "Backspace") {
            if ($filter.Length -gt 0) {
                $filter = $filter.Substring(0, $filter.Length - 1)
                $selectedIndex = 0
            }
        }
        elseif ($key.KeyChar -and -not [char]::IsControl($key.KeyChar)) {
            $filter += $key.KeyChar
            $selectedIndex = 0
        }
    }

    Clear-Host

    $service = Get-Service -Name $service.Name

    Write-Host "Selected service:" -ForegroundColor Cyan
    Write-Host "$($service.DisplayName) [$($service.Name)] - $($service.Status)"
    Write-Host ""

    $actions = @()

    if ($service.Status -eq "Running") {
        $actions += "Stop"
        $actions += "Restart"
    }

    if ($service.Status -eq "Stopped") {
        $actions += "Start"
    }

    $actions += "Cancel"

    $actionIndex = 0

    while ($true) {
        Clear-Host

        Write-Host "Selected service:" -ForegroundColor Cyan
        Write-Host "$($service.DisplayName) [$($service.Name)] - $($service.Status)"
        Write-Host ""
        Write-Host "Choose action | Up/Down to select | Enter to run | Esc to cancel"
        Write-Host ""

        for ($i = 0; $i -lt $actions.Count; $i++) {
            if ($i -eq $actionIndex) {
                Write-Host "> $($actions[$i])" -ForegroundColor Black -BackgroundColor Gray
            }
            else {
                Write-Host "  $($actions[$i])"
            }
        }

        $key = [Console]::ReadKey($true)

        if ($key.Key -eq "Escape") {
            Clear-Host
            Write-Host "Cancelled." -ForegroundColor Yellow
            return
        }

        if ($key.Key -eq "Enter") {
            $action = $actions[$actionIndex]
            break
        }

        if ($key.Key -eq "UpArrow") {
            if ($actionIndex -gt 0) {
                $actionIndex--
            }
        }
        elseif ($key.Key -eq "DownArrow") {
            if ($actionIndex -lt ($actions.Count - 1)) {
                $actionIndex++
            }
        }
    }

    Clear-Host

    if ($action -eq "Cancel") {
        Write-Host "Cancelled." -ForegroundColor Yellow
        return
    }

    Write-Host "$action service:" -ForegroundColor Cyan
    Write-Host "$($service.DisplayName) [$($service.Name)]"
    Write-Host ""

    try {
        switch ($action) {
            "Start" {
                Start-Service -Name $service.Name -ErrorAction Stop
                Write-Host "Start command sent for $($service.DisplayName)" -ForegroundColor Green
            }

            "Stop" {
                Stop-Service -Name $service.Name -ErrorAction Stop
                Write-Host "Stop command sent for $($service.DisplayName)" -ForegroundColor Red
            }

            "Restart" {
                Restart-Service -Name $service.Name -ErrorAction Stop
                Write-Host "Restart command sent for $($service.DisplayName)" -ForegroundColor Green
            }
        }

        Start-Sleep -Seconds 2

        $service = Get-Service -Name $service.Name

        Write-Host ""
        Write-Host "Final status:" -ForegroundColor Cyan
        Write-Host "$($service.DisplayName) [$($service.Name)] - $($service.Status)"

        if (
            ($action -eq "Start" -and $service.Status -eq "Running") -or
            ($action -eq "Stop" -and $service.Status -eq "Stopped") -or
            ($action -eq "Restart" -and $service.Status -eq "Running")
        ) {
            Write-Host "Success." -ForegroundColor Green
        }
        else {
            Write-Host "Command ran, but service is now '$($service.Status)'." -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host ""
        Write-Host "Failed to $action service." -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red
    }
}

Invoke-ServiceFzf
