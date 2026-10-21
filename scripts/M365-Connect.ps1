#Requires -Version 5.1
<#
.SYNOPSIS
    M365 Connect - terminal launcher for Microsoft cloud PowerShell modules.

.DESCRIPTION
    Shows which modules are installed, whether they can run in this console
    (PowerShell 5.1 vs 7, .NET Framework, dependencies, execution policy),
    and connects / installs / updates them from one menu.

    Console only: powershell.exe, pwsh or Windows Terminal. Not the ISE.
    Sessions you open stay live in the console after you quit the menu (Q).

.NOTES
    Run:   .\M365Connect.ps1
    PnP:   set $env:PNP_CLIENTID to prefill your Entra app ID.
#>

# ---------------------------------------------------------------- host checks
if ($Host.Name -eq 'Windows PowerShell ISE Host') {
    Write-Warning 'The ISE has no real console (arrow keys / ReadKey). Run this from powershell.exe, pwsh or Windows Terminal.'
    return
}
try { $null = [Console]::KeyAvailable } catch {
    Write-Warning 'Input is redirected - this tool needs an interactive console.'
    return
}

# ---------------------------------------------------------------- glyphs (built at runtime so file encoding never matters)
$script:G = @{
    DH   = [string][char]0x2550; DV = [string][char]0x2551
    TL   = [string][char]0x2554; TR = [string][char]0x2557
    BL   = [string][char]0x255A; BR = [string][char]0x255D
    SH   = [string][char]0x2500
    Dot  = [string][char]0x25CF
    Ptr  = [string][char]0x25BA
    Arr  = [string][char]0x2192
    UpDn = [string][char]0x2191 + [string][char]0x2193
    Ell  = [string][char]0x2026
}

# ---------------------------------------------------------------- session state
$script:SelfPath    = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
$script:Docs        = [Environment]::GetFolderPath('MyDocuments')
$script:Tenant      = ''
$script:GraphScopes = 'User.Read.All, Group.Read.All, Directory.Read.All'
$script:SpoUrl      = ''
$script:PnpUrl      = ''
$script:PnpClientId = $env:PNP_CLIENTID
$script:Conn        = @{}
$script:Updates     = @{}
$script:Avail       = @{}
$script:Sys         = @{}
$script:Msg         = ''
$script:MsgColor    = 'DarkGray'
$script:Sel         = 0
$script:LL          = 0
$script:Lines       = 0
$script:PrevLines   = 0
$script:W           = 100
$script:Top         = 0
$script:LastW       = 0
$script:LastH       = 0
$script:Scrolled    = $false

# ---------------------------------------------------------------- service catalog
$script:Services = @(
    @{
        Key = 'EXO'; Name = 'Exchange Online'
        Module = 'ExchangeOnlineManagement'; Install = 'ExchangeOnlineManagement'
        MinPS = '5.1'; WinPSOnly = $false; Deps = @()
        Notes = 'Connect-ExchangeOnline. Target tenant is passed as -DelegatedOrganization (GDAP / partner access).'
        Hint  = 'Sign-in window misbehaving: Connect-ExchangeOnline -DisableWAM. Assembly/method errors = MSAL conflict, connect in a fresh console.'
        Connect = {
            $p = @{ ShowBanner = $false }
            if ($script:Tenant) { $p.DelegatedOrganization = $script:Tenant }
            Connect-ExchangeOnline @p
        }
        Test = {
            Get-ConnectionInformation | Where-Object { $_.State -eq 'Connected' -and $_.ConnectionUri -notmatch 'compliance' } |
                Select-Object -First 1 | ForEach-Object {
                    if ($_.DelegatedOrganization) { "$($_.UserPrincipalName) > $($_.DelegatedOrganization)" } else { [string]$_.UserPrincipalName }
                }
        }
        Disconnect = { Disconnect-ExchangeOnline -Confirm:$false }
    },
    @{
        Key = 'IPPS'; Name = 'Security & Compliance'
        Module = 'ExchangeOnlineManagement'; Install = 'ExchangeOnlineManagement'
        MinPS = '5.1'; WinPSOnly = $false; Deps = @()
        Notes = 'Connect-IPPSSession (Purview / Security & Compliance). Same module as Exchange Online - disconnect drops both.'
        Hint  = 'Assembly/method errors = MSAL conflict, connect in a fresh console.'
        Connect = {
            $p = @{}
            if ($script:Tenant) { $p.DelegatedOrganization = $script:Tenant }
            Connect-IPPSSession @p
        }
        Test = {
            Get-ConnectionInformation | Where-Object { $_.State -eq 'Connected' -and $_.ConnectionUri -match 'compliance' } |
                Select-Object -First 1 | ForEach-Object { [string]$_.UserPrincipalName }
        }
        Disconnect = { Disconnect-ExchangeOnline -Confirm:$false }
    },
    @{
        Key = 'GRAPH'; Name = 'Microsoft Graph'
        Module = 'Microsoft.Graph.Authentication'; Install = 'Microsoft.Graph'
        MinPS = '5.1'; WinPSOnly = $false; Deps = @()
        Notes = 'Connect-MgGraph with delegated scopes. Install pulls the full Microsoft.Graph SDK (large, several minutes).'
        Hint  = 'Consent prompt = scope not granted yet. AADSTS errors: check the Entra sign-in log for your account.'
        Connect = {
            $sc = Read-Default '  Scopes (comma-separated)' $script:GraphScopes
            $script:GraphScopes = $sc
            $p = @{ Scopes = @($sc -split '\s*,\s*' | Where-Object { $_ }); NoWelcome = $true }
            if ($script:Tenant) { $p.TenantId = $script:Tenant }
            Connect-MgGraph @p
        }
        Test = { $c = Get-MgContext; if ($c) { "$($c.Account)  [$(@($c.Scopes).Count) scopes]" } }
        Disconnect = { Disconnect-MgGraph | Out-Null }
    },
    @{
        Key = 'ENTRA'; Name = 'Microsoft Entra'
        Module = 'Microsoft.Entra'; Install = 'Microsoft.Entra'
        MinPS = '5.1'; WinPSOnly = $false; Deps = @('Microsoft.Graph.Authentication')
        Notes = 'Microsoft.Entra module (Graph-based replacement for AzureAD). Shares the Graph session.'
        Hint  = 'Consent prompt = scope not granted yet. Assembly errors: Graph SDK version mismatch, update both.'
        Connect = {
            $sc = Read-Default '  Scopes (comma-separated)' $script:GraphScopes
            $script:GraphScopes = $sc
            $p = @{ Scopes = @($sc -split '\s*,\s*' | Where-Object { $_ }) }
            if ($script:Tenant) { $p.TenantId = $script:Tenant }
            Connect-Entra @p
        }
        Test = { $c = Get-EntraContext; if ($c) { "$($c.Account)  [$(@($c.Scopes).Count) scopes]" } }
        Disconnect = { Disconnect-MgGraph | Out-Null }
    },
    @{
        Key = 'AZ'; Name = 'Azure (Az)'
        Module = 'Az.Accounts'; Install = 'Az'
        MinPS = '5.1'; WinPSOnly = $false; Deps = @()
        Notes = 'Connect-AzAccount. Install pulls the full Az rollup (large). Microsoft recommends PowerShell 7.2+ for Az.'
        Hint  = 'Subscription picker hangs: Update-AzConfig -LoginExperienceV2 Off. Assembly errors: MSAL conflict, fresh console.'
        Connect = {
            $p = @{}
            if ($script:Tenant) { $p.Tenant = $script:Tenant }
            Connect-AzAccount @p
        }
        Test = { $c = Get-AzContext; if ($c) { "$($c.Account.Id) | $($c.Subscription.Name)" } }
        Disconnect = { Disconnect-AzAccount | Out-Null }
    },
    @{
        Key = 'TEAMS'; Name = 'Microsoft Teams'
        Module = 'MicrosoftTeams'; Install = 'MicrosoftTeams'
        MinPS = '5.1'; WinPSOnly = $false; Deps = @()
        Notes = 'Connect-MicrosoftTeams. Target tenant is passed as -TenantId.'
        Hint  = 'Assembly/method errors = MSAL conflict, connect in a fresh console.'
        Connect = {
            $p = @{}
            if ($script:Tenant) { $p.TenantId = $script:Tenant }
            $r = Connect-MicrosoftTeams @p
            $r | Format-List Account, Tenant, TenantId | Out-Host
            if ($r.Account) { $script:Conn['TEAMS'] = [string]$r.Account }
        }
        Test = $null
        Disconnect = { Disconnect-MicrosoftTeams | Out-Null }
    },
    @{
        Key = 'SPO'; Name = 'SharePoint Online'
        Module = 'Microsoft.Online.SharePoint.PowerShell'; Install = 'Microsoft.Online.SharePoint.PowerShell'
        MinPS = '5.1'; WinPSOnly = $true; Deps = @()
        Notes = 'Connect-SPOService. Admin URL is prefilled from the target tenant when it is a *.onmicrosoft.com domain.'
        Hint  = 'In PowerShell 7 this runs through the compatibility layer - if it fails, run the tool in Windows PowerShell 5.1.'
        Connect = {
            $def = $script:SpoUrl
            if (-not $def -and $script:Tenant -match '^([^.]+)\.onmicrosoft\.com$') { $def = "https://$($Matches[1])-admin.sharepoint.com" }
            $url = Read-Default '  Admin URL (https://<tenant>-admin.sharepoint.com)' $def
            if (-not $url) { throw 'Admin URL is required.' }
            $script:SpoUrl = $url
            Connect-SPOService -Url $url
            $script:Conn['SPO'] = $url
        }
        Test = $null
        Disconnect = { Disconnect-SPOService }
    },
    @{
        Key = 'PNP'; Name = 'PnP PowerShell'
        Module = 'PnP.PowerShell'; Install = 'PnP.PowerShell'
        MinPS = '7.4'; WinPSOnly = $false; Deps = @()
        Notes = 'Connect-PnPOnline -Interactive. Needs your own Entra app since Sept 2024 (Register-PnPEntraIDAppForInteractiveLogin). $env:PNP_CLIENTID prefills it.'
        Hint  = 'AADSTS700016 = wrong client ID or the app is not in this tenant.'
        Connect = {
            $def = $script:PnpUrl
            if (-not $def -and $script:Tenant -match '^([^.]+)\.onmicrosoft\.com$') { $def = "https://$($Matches[1]).sharepoint.com" }
            $url = Read-Default '  Site URL' $def
            if (-not $url) { throw 'Site URL is required.' }
            $cid = Read-Default '  Entra app (client) ID' $script:PnpClientId
            if (-not $cid) { throw 'Client ID is required. Create one with Register-PnPEntraIDAppForInteractiveLogin.' }
            $script:PnpUrl = $url; $script:PnpClientId = $cid
            $p = @{ Url = $url; Interactive = $true; ClientId = $cid }
            if ($script:Tenant) { $p.Tenant = $script:Tenant }
            Connect-PnPOnline @p
        }
        Test = { (Get-PnPConnection).Url }
        Disconnect = { Disconnect-PnPOnline }
    }
)

# ---------------------------------------------------------------- environment / module discovery
function Get-SysState {
    $v = $PSVersionTable.PSVersion
    $script:PSV = [version]('{0}.{1}' -f $v.Major, $v.Minor)

    $isPS7 = $v.Major -ge 7
    $pwPath = $null
    $pw = Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pw) { $pwPath = $pw.Source }
    elseif (Test-Path "$env:ProgramFiles\PowerShell\7\pwsh.exe") { $pwPath = "$env:ProgramFiles\PowerShell\7\pwsh.exe" }
    $pwVer = $null
    if ($pwPath) {
        $vi = (Get-Item $pwPath).VersionInfo
        $pwVer = New-Object Version $vi.FileMajorPart, $vi.FileMinorPart, $vi.FileBuildPart
    }

    $rel = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -Name Release -ErrorAction SilentlyContinue).Release
    $netLabel = 'not found'
    if ($rel -ge 533320)     { $netLabel = '4.8.1' }
    elseif ($rel -ge 528040) { $netLabel = '4.8' }
    elseif ($rel -ge 461808) { $netLabel = '4.7.2' }
    elseif ($rel)            { $netLabel = 'older than 4.7.2' }

    $nuget = $true
    if (-not $isPS7) {
        $nuget = [bool](Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue |
            Where-Object { $_.Version -ge [version]'2.8.5.201' })
    }

    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $script:Sys = @{
        IsPS7    = $isPS7
        Edition  = $PSVersionTable.PSEdition
        PwshPath = $pwPath
        PwshVer  = $pwVer
        Net472   = [bool]($rel -ge 461808)
        NetLabel = $netLabel
        ExecPol  = [string](Get-ExecutionPolicy)
        IsAdmin  = (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        NuGet    = $nuget
    }
}

function Update-ModuleCache {
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($s in $script:Services) {
        $names.Add($s.Module); $names.Add($s.Install)
        foreach ($d in $s.Deps) { $names.Add($d) }
    }
    foreach ($x in 'MSOnline', 'AzureAD', 'PowerShellGet') { $names.Add($x) }

    $script:Avail = @{}
    foreach ($m in (Get-Module -ListAvailable -Name ($names | Select-Object -Unique) -ErrorAction SilentlyContinue)) {
        if (-not $script:Avail.ContainsKey($m.Name)) { $script:Avail[$m.Name] = @() }
        $script:Avail[$m.Name] += $m
    }

    # PS7 does not scan the Windows PowerShell user module folder - look there for 5.1-only modules
    if ($script:Sys.IsPS7 -and $script:Docs) {
        $roots = @((Join-Path $script:Docs 'WindowsPowerShell\Modules'), (Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules'))
        foreach ($s in ($script:Services | Where-Object { $_.WinPSOnly })) {
            if ($script:Avail.ContainsKey($s.Module)) { continue }
            foreach ($r in $roots) {
                $dir = Join-Path $r $s.Module
                if (-not (Test-Path $dir)) { continue }
                foreach ($vd in (Get-ChildItem $dir -Directory -ErrorAction SilentlyContinue)) {
                    $ver = $null
                    if ([version]::TryParse($vd.Name, [ref]$ver)) {
                        if (-not $script:Avail.ContainsKey($s.Module)) { $script:Avail[$s.Module] = @() }
                        $script:Avail[$s.Module] += [pscustomobject]@{ Name = $s.Module; Version = $ver; ModuleBase = $vd.FullName }
                    }
                }
            }
        }
    }
}

function Get-Newest([string]$Name) {
    if ($script:Avail.ContainsKey($Name)) {
        $script:Avail[$Name] | Sort-Object Version -Descending | Select-Object -First 1
    }
}

function Get-MsalVersion {
    [AppDomain]::CurrentDomain.GetAssemblies() |
        Where-Object { $_.GetName().Name -eq 'Microsoft.Identity.Client' } |
        ForEach-Object { $_.GetName().Version } |
        Sort-Object -Descending | Select-Object -First 1
}

function Get-EnvWarnings {
    $w = New-Object System.Collections.Generic.List[string]
    $sys = $script:Sys
    if ($sys.ExecPol -in 'Restricted', 'AllSigned') {
        $w.Add("Execution policy $($sys.ExecPol): module imports will fail. Fix: Set-ExecutionPolicy RemoteSigned -Scope CurrentUser")
    }
    if (-not $sys.IsPS7) {
        if (-not $sys.Net472) { $w.Add(".NET Framework $($sys.NetLabel): every module here needs 4.7.2+ on Windows PowerShell") }
        $pg = Get-Newest 'PowerShellGet'
        if (-not $pg -or $pg.Version -lt [version]'2.0') {
            $pgv = if ($pg) { [string]$pg.Version } else { 'missing' }
            $w.Add("PowerShellGet $pgv (5.1 inbox version): installs are flaky. Fix: Install-Module PowerShellGet -Scope CurrentUser -Force, restart console")
        }
        if (-not $sys.NuGet) { $w.Add('NuGet provider missing: installed automatically on first install') }
        if (-not $sys.PwshPath) { $w.Add('PowerShell 7 not installed (needed for PnP.PowerShell). Press P for the install command') }
    }
    if ((Get-Newest 'MSOnline') -or (Get-Newest 'AzureAD')) {
        $w.Add('MSOnline / AzureAD module installed: both retired. Use Microsoft Graph / Microsoft.Entra')
    }
    $w
}

function Get-SvcState($s) {
    $mod    = Get-Newest $s.Module
    $issues = New-Object System.Collections.Generic.List[string]
    $warn   = New-Object System.Collections.Generic.List[string]
    $fix    = New-Object System.Collections.Generic.List[string]
    $state  = 'READY'
    $min    = [version]$s.MinPS
    $sys    = $script:Sys

    if ($script:PSV -lt $min) {
        $state = "NEEDS PS $($s.MinPS)"
        $issues.Add("Needs PowerShell $($s.MinPS)+ - this console is $($script:PSV)")
        if ($sys.IsPS7) { $fix.Add('Upgrade PowerShell 7: winget upgrade --id Microsoft.PowerShell') }
        elseif ($sys.PwshVer -and $sys.PwshVer -ge $min) { $fix.Add("Press P to relaunch this tool in pwsh $($sys.PwshVer)") }
        elseif ($sys.PwshVer) { $fix.Add("Installed pwsh $($sys.PwshVer) is too old: winget upgrade --id Microsoft.PowerShell") }
        else { $fix.Add('PowerShell 7 is not installed - press P for the install command') }
    }

    if (-not $sys.IsPS7 -and -not $sys.Net472 -and $min -lt [version]'7.0') {
        $issues.Add(".NET Framework 4.7.2+ required on Windows PowerShell (found: $($sys.NetLabel))")
        if ($state -eq 'READY') { $state = 'NEEDS .NET' }
    }

    if (-not $mod) {
        $issues.Add("$($s.Module) is not installed")
        if ($state -eq 'READY') { $state = 'NOT INSTALLED'; $fix.Add("Press I to install $($s.Install) (CurrentUser scope)") }
        $other = ''
        if ($script:Docs) { $other = if ($sys.IsPS7) { Join-Path $script:Docs "WindowsPowerShell\Modules\$($s.Module)" } else { Join-Path $script:Docs "PowerShell\Modules\$($s.Module)" } }
        if ($other -and (Test-Path $other)) { $warn.Add("Installed for the other PowerShell edition only ($other). CurrentUser installs are per edition.") }
    }

    foreach ($d in $s.Deps) {
        if (-not (Get-Newest $d)) {
            $issues.Add("Dependency $d is not installed")
            if ($state -eq 'READY') { $state = 'MISSING DEP'; $fix.Add("Press I to install $d") }
        }
    }

    if ($s.WinPSOnly -and $sys.IsPS7) {
        $warn.Add('Windows PowerShell module: loads through the PS7 compatibility layer. Native 5.1 is more reliable.')
    }
    if ($mod -and $s.Install -ne $s.Module -and -not (Get-Newest $s.Install)) {
        $warn.Add("Only $($s.Module) is installed, not the full $($s.Install) rollup - cmdlets beyond connect may be missing.")
    }

    $conn = $null
    if ($state -eq 'READY' -and (Get-Module -Name $s.Module)) {
        if ($s.Test) { try { $conn = @(& $s.Test 2>$null)[0] } catch { $conn = $null } }
        elseif ($script:Conn.ContainsKey($s.Key)) { $conn = $script:Conn[$s.Key] }
    }
    if ($conn) { $state = 'CONNECTED' }

    $target = if (Get-Newest $s.Install) { $s.Install } else { $s.Module }
    $upd = $script:Updates[$target]
    if ($upd) { $fix.Add("Update available: $upd - press U") }
    if ($state -eq 'READY') { $fix.Insert(0, 'Press Enter to connect') }

    $versions = 0
    if ($mod) { $versions = @($script:Avail[$s.Module] | ForEach-Object { [string]$_.Version } | Sort-Object -Unique).Count }

    [pscustomobject]@{
        State    = $state
        Version  = if ($mod) { [string]$mod.Version } else { '' }
        Versions = $versions
        Path     = if ($mod) { $mod.ModuleBase } else { '' }
        Issues   = $issues
        Warn     = $warn
        Fix      = $fix
        Conn     = $conn
        Update   = $upd
    }
}

function Get-StateColor([string]$State) {
    switch -Wildcard ($State) {
        'CONNECTED'     { 'Green'; break }
        'READY'         { 'Cyan'; break }
        'NOT INSTALLED' { 'DarkYellow'; break }
        'NEEDS PS*'     { 'Magenta'; break }
        default         { 'Red' }
    }
}

function Get-ReqText($s) {
    $t = "PowerShell $($s.MinPS)+"
    if ([version]$s.MinPS -lt [version]'7.0') { $t += '  |  .NET Framework 4.7.2+ on 5.1' }
    if ($s.WinPSOnly) { $t += '  |  Windows PowerShell module' }
    if ($s.Deps.Count) { $t += "  |  needs $($s.Deps -join ', ')" }
    $t
}

# ---------------------------------------------------------------- drawing helpers
function Write-Seg {
    param([string]$Text, [string]$Fg = 'Gray', [string]$Bg = '')
    $room = $script:W - $script:LL
    if ($room -le 0 -or -not $Text) { return }
    if ($Text.Length -gt $room) { $Text = $Text.Substring(0, $room) }
    if ($Bg) {
        if ($Fg -eq 'DarkGray') { $Fg = 'Gray' }
        Write-Host $Text -NoNewline -ForegroundColor $Fg -BackgroundColor $Bg
    }
    else { Write-Host $Text -NoNewline -ForegroundColor $Fg }
    $script:LL += $Text.Length
}

function Write-Eol {
    param([string]$Bg = '')
    $pad = $script:W - $script:LL
    if ($pad -gt 0) {
        if ($Bg) { Write-Host (' ' * $pad) -NoNewline -BackgroundColor $Bg } else { Write-Host (' ' * $pad) -NoNewline }
    }
    Write-Host ''
    $script:LL = 0
    $script:Lines++
}

function Get-WrapLines([string]$Text, [string]$Indent) {
    $max = [Math]::Max(10, $script:W - $Indent.Length)
    $line = ''
    foreach ($word in ($Text -split ' ')) {
        if ($line -and ($line.Length + $word.Length + 1) -gt $max) {
            $Indent + $line
            $line = $word
        }
        elseif ($line) { $line = "$line $word" }
        else { $line = $word }
    }
    if ($line) { $Indent + $line }
}

function Write-Wrapped([string]$Text, [string]$Indent, [string]$Color) {
    foreach ($l in @(Get-WrapLines $Text $Indent)) { Write-Seg $l $Color; Write-Eol }
}

function Fit([string]$Text, [int]$Width) {
    if ($Text.Length -le $Width - 1) { return $Text.PadRight($Width) }
    return ($Text.Substring(0, $Width - 2) + $script:G.Ell + ' ')
}

function Write-Key([string]$Key, [string]$Label) {
    Write-Seg " [$Key]" Cyan
    Write-Seg " $Label " DarkGray
}

function Write-Rule { Write-Seg ('  ' + ($script:G.SH * ($script:W - 4))) DarkGray; Write-Eol }

function Reset-Screen {
    Clear-Host
    $script:Top = [Console]::WindowTop
    $script:PrevLines = 0
    $script:LastW = [Console]::WindowWidth
    $script:LastH = [Console]::WindowHeight
}

# ---------------------------------------------------------------- main screen
function Update-States {
    $script:States = @(foreach ($s in $script:Services) { Get-SvcState $s })
    $script:Warns  = @(Get-EnvWarnings)
}

function Write-Row([int]$i) {
    $s = $script:Services[$i]; $st = $script:States[$i]
    $isSel = $i -eq $script:Sel
    $bg = if ($isSel) { 'DarkBlue' } else { '' }
    $ptr = if ($isSel) { " $($G.Ptr)$($i + 1) " } else { "  $($i + 1) " }
    Write-Seg $ptr Cyan $bg
    Write-Seg (Fit $s.Name 26) $(if ($isSel) { 'White' } else { 'Gray' }) $bg
    Write-Seg (Fit $s.Module 40) DarkGray $bg
    Write-Seg (Fit $(if ($st.Version) { $st.Version } else { '-' }) 11) Gray $bg
    Write-Seg "$($G.Dot) $($st.State)" (Get-StateColor $st.State) $bg
    if ($st.Update) { Write-Seg "  $($G.Arr) $($st.Update)" Yellow $bg }
    if ($st.Conn)   { Write-Seg "  $($st.Conn)" DarkGray $bg }
    Write-Eol $bg
}

function Write-Details {
    $script:Lines = $script:DetTop; $script:LL = 0
    $s = $script:Services[$script:Sel]; $st = $script:States[$script:Sel]
    Write-Seg "  $($s.Name)" White; Write-Seg "   $($s.Module)" DarkGray
    if ($st.Versions -gt 1) { Write-Seg "   ($($st.Versions) versions side by side)" DarkYellow }
    Write-Eol
    $fixed = 2
    Write-Seg '  Requires  ' DarkGray; Write-Seg (Get-ReqText $s) Gray; Write-Eol
    if ($st.Path) { Write-Seg '  Path      ' DarkGray; Write-Seg $st.Path Gray; Write-Eol; $fixed++ }
    if ($st.Conn) { Write-Seg '  Session   ' DarkGray; Write-Seg ([string]$st.Conn) Green; Write-Eol; $fixed++ }

    # free-text lines, trimmed so the whole frame always fits the window (scrolling breaks absolute positioning)
    $info = New-Object System.Collections.Generic.List[object]
    foreach ($x in $st.Issues) { foreach ($l in @(Get-WrapLines "x $x" '  ')) { $info.Add(@($l, 'Red')) } }
    foreach ($x in $st.Warn)   { foreach ($l in @(Get-WrapLines "! $x" '  ')) { $info.Add(@($l, 'Yellow')) } }
    foreach ($x in $st.Fix)    { foreach ($l in @(Get-WrapLines "$($G.Arr) $x" '  ')) { $info.Add(@($l, 'Cyan')) } }
    foreach ($l in @(Get-WrapLines $s.Notes '  ')) { $info.Add(@($l, 'DarkGray')) }

    # frame = DetTop + fixed + info + rule(1) + keys(2) + msg(1); keep one spare row at the bottom
    $budget = [Math]::Max(0, [Console]::WindowHeight - 1 - $script:DetTop - $fixed - 4)
    if ($info.Count -gt $budget) {
        $keep = [Math]::Max(0, $budget - 1)
        $shown = @($info | Select-Object -First $keep)
        if ($budget -ge 1) { $shown += , @("  $($G.Ell)", 'DarkGray') }
    }
    else { $shown = $info.ToArray() }
    foreach ($it in $shown) { Write-Seg $it[0] $it[1]; Write-Eol }
    Write-Rule

    Write-Key $G.UpDn 'select'; Write-Key 'Enter' 'connect'; Write-Key 'I' 'install'; Write-Key 'U' 'update'; Write-Key 'C' 'check updates'; Write-Eol
    Write-Key 'S' 'type commands'; Write-Key 'T' 'tenant'; Write-Key 'P' 'PowerShell 7'; Write-Key 'X' 'disconnect all'; Write-Key 'R' 'rescan'; Write-Key 'Q' 'quit to prompt'; Write-Eol
    if ($script:Msg) { Write-Seg "  $($script:Msg)" $script:MsgColor }
    Write-Eol

    # wipe leftovers from a previous, longer frame
    $endRow = [Math]::Max($script:Lines, $script:PrevLines)
    for ($j = $script:Lines; $j -lt $script:PrevLines; $j++) { Write-Host (' ' * $script:W) }
    $script:PrevLines = $script:Lines
    # if the console scrolled anyway, the cached row offsets are stale - flag a full redraw
    $script:Scrolled = ([Console]::WindowTop -ne $script:Top) -or ([Console]::CursorTop -ne ($script:Top + $endRow))
}

function Show-Menu {
    if ([Console]::WindowWidth -ne $script:LastW -or [Console]::WindowHeight -ne $script:LastH -or $script:PrevLines -ge [Console]::WindowHeight) { Reset-Screen }
    $script:W = [Math]::Max(40, [Math]::Min([Console]::WindowWidth - 1, 130))
    $W = $script:W
    $sys = $script:Sys

    [Console]::SetCursorPosition(0, $script:Top)
    $script:Lines = 0; $script:LL = 0

    # title box
    Write-Seg ($G.TL + ($G.DH * ($W - 2)) + $G.TR) DarkCyan; Write-Eol
    $left = '  M365 CONNECT'; $sub = '   Microsoft cloud module launcher'
    $right = "PowerShell $($script:PSV) $($sys.Edition)  "
    $pad = $W - 2 - $left.Length - $sub.Length - $right.Length
    if ($pad -lt 1) { $sub = ''; $pad = [Math]::Max(1, $W - 2 - $left.Length - $right.Length) }
    Write-Seg $G.DV DarkCyan; Write-Seg $left White; Write-Seg $sub DarkGray
    Write-Seg (' ' * $pad); Write-Seg $right Cyan; Write-Seg $G.DV DarkCyan; Write-Eol
    Write-Seg ($G.BL + ($G.DH * ($W - 2)) + $G.BR) DarkCyan; Write-Eol

    # environment
    $pwshTxt = if ($sys.PwshVer) { '{0}.{1}.{2}' -f $sys.PwshVer.Major, $sys.PwshVer.Minor, $sys.PwshVer.Build } else { 'not installed' }
    Write-Seg '  Admin ' DarkGray;        Write-Seg $(if ($sys.IsAdmin) { 'yes' } else { 'no' }) Gray
    Write-Seg '   Exec policy ' DarkGray; Write-Seg $sys.ExecPol $(if ($sys.ExecPol -in 'Restricted', 'AllSigned') { 'Red' } else { 'Gray' })
    Write-Seg '   .NET Fx ' DarkGray;     Write-Seg $sys.NetLabel $(if ($sys.Net472 -or $sys.IsPS7) { 'Gray' } else { 'Red' })
    Write-Seg '   pwsh ' DarkGray;        Write-Seg $pwshTxt $(if ($sys.PwshVer) { 'Gray' } else { 'Yellow' })
    Write-Eol
    $msal = Get-MsalVersion
    Write-Seg '  Tenant ' DarkGray
    Write-Seg $(if ($script:Tenant) { $script:Tenant } else { 'home tenant' }) $(if ($script:Tenant) { 'Yellow' } else { 'Gray' })
    Write-Seg '   MSAL loaded ' DarkGray; Write-Seg $(if ($msal) { [string]$msal } else { 'none' }) Gray
    Write-Eol
    foreach ($x in $script:Warns) { Write-Wrapped "! $x" '  ' Yellow }

    # service table
    Write-Eol
    Write-Seg ('    ' + (Fit 'SERVICE' 26) + (Fit 'MODULE' 40) + (Fit 'VERSION' 11) + 'STATUS') DarkGray; Write-Eol
    Write-Rule
    $script:RowTop = $script:Lines
    for ($i = 0; $i -lt $script:Services.Count; $i++) { Write-Row $i }
    Write-Rule
    $script:DetTop = $script:Lines
    Write-Details
}

# arrow-key navigation: repaint only the two changed rows + the details panel
function Show-Nav([int]$Old) {
    if ([Console]::WindowWidth -ne $script:LastW -or [Console]::WindowHeight -ne $script:LastH) { Show-Menu; return }
    if ($Old -ne $script:Sel) {
        foreach ($i in @($Old, $script:Sel)) {
            [Console]::SetCursorPosition(0, $script:Top + $script:RowTop + $i)
            $script:LL = 0
            Write-Row $i
        }
    }
    [Console]::SetCursorPosition(0, $script:Top + $script:DetTop)
    Write-Details
    if ($script:Scrolled) { Reset-Screen; Show-Menu }
}

# ---------------------------------------------------------------- action plumbing
function Invoke-Screen {
    param([string]$Title, [scriptblock]$Body, [string]$Hint, [switch]$NoPause)
    [Console]::CursorVisible = $true
    Clear-Host
    Write-Host ''
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host ('  ' + ($script:G.SH * [Math]::Max(10, $Title.Length))) -ForegroundColor DarkCyan
    Write-Host ''
    $ErrorActionPreference = 'Stop'
    $success = $true
    try { & $Body | Out-Host }
    catch {
        $success = $false
        Write-Host ''
        Write-Host "  FAILED: $($_.Exception.Message)" -ForegroundColor Red
        if ($Hint) { Write-Host "  Hint: $Hint" -ForegroundColor Yellow }
    }
    if (-not $NoPause -or -not $success) {
        Write-Host ''
        Write-Host '  Press any key to return to the menu...' -ForegroundColor DarkGray
        [void][Console]::ReadKey($true)
    }
    [Console]::CursorVisible = $false
    Reset-Screen
    return $success
}

function Read-Default([string]$Prompt, [string]$Default) {
    $suffix = if ($Default) { " [$Default]" } else { '' }
    $v = Read-Host "$Prompt$suffix"
    if ([string]::IsNullOrWhiteSpace($v)) { return $Default }
    return $v.Trim()
}

function Set-Msg([string]$Text, [string]$Color = 'DarkGray') { $script:Msg = $Text; $script:MsgColor = $Color }

function Initialize-Gallery {
    if ($script:Sys.IsPS7) { return }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    if (-not $script:Sys.NuGet) {
        Write-Host '  Installing NuGet package provider (CurrentUser)...' -ForegroundColor DarkGray
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force | Out-Null
        $script:Sys.NuGet = $true
    }
}

function Get-InstallParams([string]$Name) {
    $p = @{ Name = $Name; Scope = 'CurrentUser'; Force = $true; Repository = 'PSGallery' }
    if ((Get-Command Install-Module).Parameters.ContainsKey('AllowClobber')) { $p.AllowClobber = $true }
    $p
}

function Invoke-WinPS([string]$Command) {
    # Runs a command in Windows PowerShell 5.1 (for modules that must live in the 5.1 module path)
    $wrapped = '$ErrorActionPreference = ''Stop''; [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072; ' + $Command
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($wrapped))
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand $enc
    if ($LASTEXITCODE -ne 0) { throw "Windows PowerShell exited with code $LASTEXITCODE." }
}

# ---------------------------------------------------------------- actions
function Connect-Svc($s) {
    $st = Get-SvcState $s
    if ($st.State -ne 'READY' -and $st.State -ne 'CONNECTED') {
        Set-Msg "$($s.Name): $($st.Issues[0])" Red
        return
    }
    $ok = Invoke-Screen "Connect $($G.Arr) $($s.Name)" -Hint $s.Hint -Body {
        if ($st.State -eq 'CONNECTED') { Write-Host "  Already connected ($($st.Conn)) - reconnecting." -ForegroundColor DarkGray }
        if ($script:Tenant) { Write-Host "  Target tenant : $($script:Tenant)" -ForegroundColor DarkGray }
        $msal = Get-MsalVersion
        if ($msal -and -not (Get-Module -Name $s.Module)) {
            Write-Host "  ! MSAL $msal is already loaded by another module. If this fails with an assembly/method error, use a fresh console." -ForegroundColor Yellow
        }
        Write-Host "  Importing $($s.Module)..." -ForegroundColor DarkGray
        # -Global: cmdlets must outlive this script's scope so they work at the prompt after quitting
        if ($s.WinPSOnly -and $script:Sys.IsPS7) { Import-Module -Name $s.Module -UseWindowsPowerShell -Global -WarningAction SilentlyContinue }
        else { Import-Module -Name $s.Module -Global }
        Write-Host '  Signing in - a browser or account picker may open...' -ForegroundColor DarkGray
        Write-Host ''
        $script:Conn.Remove($s.Key)
        & $s.Connect
        if (-not $script:Conn.ContainsKey($s.Key)) { $script:Conn[$s.Key] = 'connected (this console)' }
        Write-Host ''
        Write-Host "  Connected to $($s.Name)." -ForegroundColor Green
    }
    if ($ok) { Set-Msg "Connected to $($s.Name)." Green } else { Set-Msg "Connect to $($s.Name) failed." Red }
}

function Install-Svc($s) {
    if ($script:PSV -lt [version]$s.MinPS) { Set-Msg "$($s.Name) needs PowerShell $($s.MinPS)+ - press P." Magenta; return }
    $names = @(@($s.Install) + @($s.Deps | Where-Object { -not (Get-Newest $_) }) | Select-Object -Unique)
    $viaWinPS = $s.WinPSOnly -and $script:Sys.IsPS7
    $ok = Invoke-Screen "Install $($G.Arr) $($s.Name)" -Body {
        if (-not $viaWinPS) { Initialize-Gallery }
        foreach ($name in $names) {
            Write-Host "  Installing $name (CurrentUser scope)..." -ForegroundColor DarkGray
            if ($viaWinPS) {
                Write-Host '  (through Windows PowerShell, so both 5.1 and the PS7 compatibility layer see it)' -ForegroundColor DarkGray
                Invoke-WinPS ("if (-not (Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue)) { Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force | Out-Null }; " +
                    "Install-Module -Name '$name' -Scope CurrentUser -Force -AllowClobber -Repository PSGallery")
            }
            else {
                $p = Get-InstallParams $name
                Install-Module @p
            }
        }
        Write-Host ''
        Write-Host '  Installed.' -ForegroundColor Green
        if (-not $viaWinPS) {
            $ed = if ($script:Sys.IsPS7) { 'PowerShell 7' } else { 'Windows PowerShell 5.1' }
            Write-Host "  CurrentUser installs are per edition - this one is for $ed only." -ForegroundColor DarkGray
        }
    }
    Update-ModuleCache
    if ($ok) { Set-Msg "$($s.Install) installed." Green } else { Set-Msg "Install of $($s.Install) failed." Red }
}

function Update-Svc($s) {
    $target = if (Get-Newest $s.Install) { $s.Install } else { $s.Module }
    if (-not (Get-Newest $target)) { Set-Msg "$($s.Name) is not installed - press I." Yellow; return }
    $viaWinPS = $s.WinPSOnly -and $script:Sys.IsPS7
    $loaded = [bool](Get-Module -Name $s.Module)
    $ok = Invoke-Screen "Update $($G.Arr) $target" -Body {
        if ($viaWinPS) {
            Invoke-WinPS "try { Update-Module -Name '$target' -Force } catch { Install-Module -Name '$target' -Scope CurrentUser -Force -AllowClobber -Repository PSGallery }"
        }
        else {
            Initialize-Gallery
            try { Update-Module -Name $target -Force }
            catch {
                Write-Host "  Update-Module failed: $($_.Exception.Message)" -ForegroundColor Yellow
                Write-Host '  Falling back to Install-Module -Force (CurrentUser, side by side)...' -ForegroundColor DarkGray
                $p = Get-InstallParams $target
                Install-Module @p
            }
        }
        Write-Host ''
        Write-Host '  Updated. Older versions stay side by side.' -ForegroundColor Green
        if ($loaded) { Write-Host '  The old version is loaded in this console - open a new one to use the update.' -ForegroundColor Yellow }
    }
    Update-ModuleCache
    if ($ok) { $script:Updates.Remove($target); Set-Msg "$target updated." Green } else { Set-Msg "Update of $target failed." Red }
}

function Find-SvcUpdates {
    $null = Invoke-Screen 'Check for updates (PSGallery)' -Body {
        if (-not $script:Sys.IsPS7) { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 }
        $seen = @{}
        foreach ($s in $script:Services) {
            $target = if (Get-Newest $s.Install) { $s.Install } else { $s.Module }
            if ($seen.ContainsKey($target)) { continue }
            $seen[$target] = $true
            $local = Get-Newest $target
            Write-Host ('  {0,-42}' -f $target) -NoNewline
            if (-not $local) { Write-Host 'not installed' -ForegroundColor DarkGray; continue }
            try {
                $g = Find-Module -Name $target -Repository PSGallery -ErrorAction Stop
                if ([version]$g.Version -gt [version]$local.Version) {
                    $script:Updates[$target] = [string]$g.Version
                    Write-Host "$($local.Version) $($script:G.Arr) $($g.Version)" -ForegroundColor Yellow
                }
                else {
                    $script:Updates.Remove($target)
                    Write-Host "$($local.Version) up to date" -ForegroundColor Green
                }
            }
            catch { Write-Host "lookup failed: $($_.Exception.Message)" -ForegroundColor Red }
        }
    }
    $n = $script:Updates.Count
    if ($n) { Set-Msg "$n update(s) available - select the service and press U." Yellow } else { Set-Msg 'Everything installed is up to date.' Green }
}

function Set-TargetTenant {
    $null = Invoke-Screen 'Target tenant' -NoPause -Body {
        Write-Host '  Passed as -DelegatedOrganization (EXO / IPPS) and -TenantId / -Tenant (Graph, Entra, Az, Teams, PnP).' -ForegroundColor DarkGray
        Write-Host '  Domain (contoso.onmicrosoft.com) or tenant ID. Blank keeps current, "-" resets to your home tenant.' -ForegroundColor DarkGray
        Write-Host ''
        $cur = if ($script:Tenant) { $script:Tenant } else { 'home tenant' }
        $v = Read-Host "  Tenant [$cur]"
        if ($v -eq '-') { $script:Tenant = '' }
        elseif ($v) { $script:Tenant = $v.Trim() }
    }
    $t = if ($script:Tenant) { $script:Tenant } else { 'home tenant' }
    Set-Msg "Target tenant: $t. Existing sessions keep their tenant - X to disconnect first." Yellow
}

function Start-Pwsh {
    if ($script:Sys.IsPS7) { Set-Msg "Already running PowerShell $($script:PSV)."; return }
    if ($script:Sys.PwshPath) {
        if (-not $script:SelfPath) { Set-Msg 'Cannot find this script on disk to relaunch it.' Red; return }
        Start-Process -FilePath $script:Sys.PwshPath -ArgumentList @('-NoExit', '-ExecutionPolicy', 'Bypass', '-File', "`"$($script:SelfPath)`"")
        Set-Msg "Opened this tool in a new PowerShell $($script:Sys.PwshVer) window." Green
        return
    }
    $null = Invoke-Screen 'PowerShell 7 is not installed' -Body {
        Write-Host '  Install with winget (machine-wide, UAC prompt):'
        Write-Host ''
        Write-Host '    winget install --id Microsoft.PowerShell --source winget' -ForegroundColor White
        Write-Host ''
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            $a = Read-Host '  Run it now? (y/N)'
            if ($a -match '^[yY]') {
                Start-Process winget -ArgumentList 'install --id Microsoft.PowerShell --source winget --accept-package-agreements --accept-source-agreements' -Wait -NoNewWindow
                Get-SysState
                if ($script:Sys.PwshPath) { Write-Host '  Installed. Press P again to relaunch in pwsh.' -ForegroundColor Green }
            }
        }
        else { Write-Host '  winget not found - get the MSI from https://github.com/PowerShell/PowerShell/releases' -ForegroundColor Yellow }
    }
}

function Enter-Shell {
    [Console]::CursorVisible = $true
    Clear-Host
    Write-Host ''
    Write-Host '  Command prompt - your live sessions are available here.' -ForegroundColor Cyan
    Write-Host '  Type exit to go back to the menu.' -ForegroundColor DarkGray
    Write-Host ''
    $Host.EnterNestedPrompt()
    [Console]::CursorVisible = $false
    Reset-Screen
}

function Disconnect-All {
    $null = Invoke-Screen 'Disconnect all sessions' -Body {
        $done = @{}
        foreach ($s in $script:Services) {
            if (-not $s.Disconnect -or -not (Get-Module -Name $s.Module)) { continue }
            $id = $s.Disconnect.ToString()
            if ($done.ContainsKey($id)) { continue }
            $done[$id] = $true
            Write-Host ('  {0,-26}' -f $s.Name) -NoNewline
            try { & $s.Disconnect 2>$null | Out-Null; Write-Host 'disconnected' -ForegroundColor Green }
            catch { Write-Host 'nothing to disconnect' -ForegroundColor DarkGray }
        }
        if (-not $done.Count) { Write-Host '  No service modules are loaded in this console.' -ForegroundColor DarkGray }
        $script:Conn.Clear()
    }
    Set-Msg 'Sessions disconnected.' Green
}

# ---------------------------------------------------------------- main loop
Write-Host 'Scanning environment and modules...' -ForegroundColor DarkGray
Get-SysState
Update-ModuleCache

$count = $script:Services.Count
$run = $true
$dirty = $true
$redraw = $true
try {
    [Console]::CursorVisible = $false
    Reset-Screen
    while ($run) {
        if ($dirty)  { Update-States; $dirty = $false }
        if ($redraw) { Show-Menu; $redraw = $false }
        $k = [Console]::ReadKey($true)
        $svc = $script:Services[$script:Sel]
        $old = $script:Sel
        $script:Msg = ''
        $nav = $false
        $ch = [string]$k.KeyChar
        if ($ch -match '^[1-9]$' -and [int]$ch -le $count) { $script:Sel = [int]$ch - 1; $nav = $true }
        else {
            switch ($k.Key) {
                'UpArrow'   { $script:Sel = ($script:Sel - 1 + $count) % $count; $nav = $true }
                'DownArrow' { $script:Sel = ($script:Sel + 1) % $count; $nav = $true }
                'Home'      { $script:Sel = 0; $nav = $true }
                'End'       { $script:Sel = $count - 1; $nav = $true }
                'Enter'     { Connect-Svc $svc; $dirty = $true; $redraw = $true }
                'I'         { Install-Svc $svc; $dirty = $true; $redraw = $true }
                'U'         { Update-Svc $svc; $dirty = $true; $redraw = $true }
                'C'         { Find-SvcUpdates; $dirty = $true; $redraw = $true }
                'S'         { Enter-Shell; $dirty = $true; $redraw = $true }
                'T'         { Set-TargetTenant; $dirty = $true; $redraw = $true }
                'P'         { Start-Pwsh; $dirty = $true; $redraw = $true }
                'X'         { Disconnect-All; $dirty = $true; $redraw = $true }
                'R'         { Set-Msg 'Rescanning...'; Show-Menu; Get-SysState; Update-ModuleCache; Set-Msg 'Rescanned.' Green; $dirty = $true; $redraw = $true }
                'Q'         { $run = $false }
                'Escape'    { $run = $false }
                default     { $nav = $true }
            }
        }
        if ($run -and $nav) { Show-Nav $old }
    }
}
finally {
    [Console]::CursorVisible = $true
}

Clear-Host
$live = @(foreach ($s in $script:Services) {
    $st = Get-SvcState $s
    if ($st.State -eq 'CONNECTED') { "  $($script:G.Dot) $($s.Name)  $($st.Conn)" }
})
if ($live.Count) {
    Write-Host 'Live sessions in this console:' -ForegroundColor Cyan
    $live | ForEach-Object { Write-Host $_ -ForegroundColor Green }
    Write-Host 'You are back at the prompt - type your commands now.' -ForegroundColor Cyan
}
else { Write-Host 'No live sessions.' -ForegroundColor DarkGray }
