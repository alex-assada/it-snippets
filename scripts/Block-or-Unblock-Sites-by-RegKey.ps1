if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Run as administrator." -ForegroundColor Red
    return
}

$keys = [ordered]@{
    Chrome  = 'HKLM:\SOFTWARE\Policies\Google\Chrome\URLBlocklist'
    Edge    = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge\URLBlocklist'
    Firefox = 'HKLM:\SOFTWARE\Policies\Mozilla\Firefox\WebsiteFilter\Block'
}
$fxParent = 'HKLM:\SOFTWARE\Policies\Mozilla\Firefox\WebsiteFilter'

# Chrome-style "example.com" or "example.com/path" -> Firefox match pattern
function ToFx($u) {
    if ($u -match '/') { "*://*.$u*" } else { "*://*.$u/*" }
}
# Firefox match pattern -> Chrome-style (patterns not in our format are shown as-is)
function FromFx($v) {
    if ($v -notmatch '^\*://\*\.') { return $v }
    $s = $v -replace '^\*://\*\.', ''
    if ($s.EndsWith('/*')) { $s.Substring(0, $s.Length - 2) } else { $s.TrimEnd('*') }
}
function GetEntries($b) {
    $p = $keys[$b]
    if (!(Test-Path $p)) { return @() }
    (Get-ItemProperty $p).PSObject.Properties | Where-Object { $_.Name -match '^\d+$' } | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; Raw = $_.Value; Url = $(if ($b -eq 'Firefox') { FromFx $_.Value } else { $_.Value }) }
    }
}

do {
    $list = @{}
    foreach ($b in $keys.Keys) {
        foreach ($e in (GetEntries $b)) {
            if (-not $list.ContainsKey($e.Url)) { $list[$e.Url] = @() }
            $list[$e.Url] += $b
        }
    }
    $sorted = @($list.Keys | Sort-Object)

    Write-Host ""
    Write-Host "=== Current blocklist ===" -ForegroundColor Cyan
    if ($sorted.Count -eq 0) { Write-Host "(empty)" }
    for ($i = 0; $i -lt $sorted.Count; $i++) {
        $where = ($list[$sorted[$i]] | Sort-Object) -join ', '
        $line = "{0,3}. {1}  [{2}]" -f ($i + 1), $sorted[$i], $where
        if ($list[$sorted[$i]].Count -lt $keys.Count) { Write-Host "$line  <-- not in all browsers" -ForegroundColor Yellow }
        else { Write-Host $line }
    }
    Write-Host ""

    $choice = (Read-Host "[A]dd, [R]emove, [Q]uit").Trim().ToUpper()

    if ($choice -eq 'A') {
        $in = Read-Host "URLs to add (comma separated, e.g. deepseek.com, example.com/path)"
        $bin = (Read-Host "Browsers: [C]hrome, [E]dge, [F]irefox, comma separated (default: all)").Trim().ToUpper()
        $targets = if (!$bin) { @($keys.Keys) } else {
            @($keys.Keys | Where-Object { $l = $_.Substring(0,1); ($bin -split '[,\s]+') | Where-Object { $_ -and ($_ -eq $l -or $_ -eq $_.ToString() -and $l -eq $_.Substring(0,1)) } })
        }
        if ($targets.Count -eq 0) { Write-Host "No valid browser selected." -ForegroundColor Yellow; continue }

        foreach ($u in ($in -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
            foreach ($b in $targets) {
                $p = $keys[$b]
                if (!(Test-Path $p)) { New-Item -Path $p -Force | Out-Null }
                $existing = GetEntries $b
                if ($existing.Url -contains $u) { Write-Host "$b : $u already present"; continue }
                $val = if ($b -eq 'Firefox') { ToFx $u } else { $u }
                $next = if ($existing) { ($existing.Name | ForEach-Object { [int]$_ } | Measure-Object -Maximum).Maximum + 1 } else { 1 }
                New-ItemProperty -Path $p -Name $next -Value $val -PropertyType String -Force | Out-Null
                Write-Host "$b : added $u as #$next" -ForegroundColor Green
            }
        }
    }
    elseif ($choice -eq 'R') {
        if ($sorted.Count -eq 0) { Write-Host "Nothing to remove."; continue }
        $in = Read-Host "Numbers to remove (comma separated)"
        foreach ($n in ($in -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
            if ($n -notmatch '^\d+$' -or [int]$n -lt 1 -or [int]$n -gt $sorted.Count) { Write-Host "Skipping '$n' (invalid)" -ForegroundColor Yellow; continue }
            $u = $sorted[[int]$n - 1]
            foreach ($b in $keys.Keys) {
                $p = $keys[$b]
                foreach ($h in (GetEntries $b | Where-Object { $_.Url -eq $u })) {
                    Remove-ItemProperty -Path $p -Name $h.Name
                    Write-Host "$b : removed $u (#$($h.Name))" -ForegroundColor Green
                }
                # Drop empty keys so the policy disappears from the browser's policy page
                if ((Test-Path $p) -and !(GetEntries $b)) {
                    Remove-Item $p -Force
                    if ($b -eq 'Firefox' -and (Test-Path $fxParent) -and !(Get-ChildItem $fxParent) -and !((Get-Item $fxParent).Property)) { Remove-Item $fxParent -Force }
                    Write-Host "$b : list empty, key removed"
                }
            }
        }
    }
    elseif ($choice -ne 'Q') { Write-Host "Invalid choice." -ForegroundColor Yellow }

} while ($choice -ne 'Q')
