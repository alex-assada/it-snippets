#requires -Version 5.1
<#
.SYNOPSIS
    Temporarily loads Vim into the current PowerShell session.

.DESCRIPTION
    Downloads Vim, extracts it into a user-local cache, prepends Vim to the
    current process PATH, and leaves the current machine/user PATH untouched.

    Extraction uses tar.exe first because Expand-Archive is slow as hell.
    If tar.exe is unavailable or fails, it falls back to Expand-Archive.

    Designed to work with:

        iwr 'https://example/Enable-TemporaryVim.ps1' | iex

    This is intentional because PATH must be modified in the caller's current
    PowerShell process.

.NOTES
    Persistence:
        - Vim files are cached under LOCALAPPDATA.
        - PATH change is current PowerShell process only.
        - No registry writes.
        - No permanent user/machine PATH modification.

    Functions exposed:
        Enable-TemporaryVim
        Disable-TemporaryVim
        Get-TemporaryVim
        Clear-TemporaryVimCache
#>

Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Script state
# ---------------------------------------------------------------------------

if (-not (Get-Variable -Name TemporaryVimState -Scope Script -ErrorAction SilentlyContinue)) {
    $script:TemporaryVimState = $null
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Get-TemporaryVimDefaultCacheRoot {
    [CmdletBinding()]
    param()

    if ($env:LOCALAPPDATA) {
        return (Join-Path -Path $env:LOCALAPPDATA -ChildPath 'TempToolCache\vim')
    }

    return (Join-Path -Path $env:TEMP -ChildPath 'TempToolCache\vim')
}

function Get-TemporaryVimCacheKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $ZipUrl
    )

    $fileName = [System.IO.Path]::GetFileName(([uri] $ZipUrl).AbsolutePath)

    if (-not $fileName) {
        return 'vim-cache'
    }

    return ($fileName -replace '\.zip$', '')
}

function Find-TemporaryVimExe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Root
    )

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        return $null
    }

    $preferred = Get-ChildItem -LiteralPath $Root -Recurse -File -Filter 'vim.exe' -ErrorAction SilentlyContinue |
        Where-Object {
            $_.FullName -match '\\vim\\vim\d+\\vim\.exe$'
        } |
        Select-Object -First 1

    if ($preferred) {
        return $preferred
    }

    return Get-ChildItem -LiteralPath $Root -Recurse -File -Filter 'vim.exe' -ErrorAction SilentlyContinue |
        Select-Object -First 1
}

function Expand-TemporaryVimArchive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $ZipPath,

        [Parameter(Mandatory)]
        [string] $DestinationPath
    )

    $tar = Get-Command -Name 'tar.exe' -ErrorAction SilentlyContinue

    if ($tar) {
        Write-Host "Extracting Vim with tar.exe..."

        & $tar.Source -xf $ZipPath -C $DestinationPath

        if ($LASTEXITCODE -eq 0) {
            return
        }

        Write-Host "tar.exe failed with exit code $LASTEXITCODE. Falling back to Expand-Archive..."
    }
    else {
        Write-Host "tar.exe not found. Falling back to Expand-Archive..."
    }

    Write-Host "Extracting Vim with Expand-Archive..."

    Expand-Archive `
        -LiteralPath $ZipPath `
        -DestinationPath $DestinationPath `
        -Force
}

function Add-TemporaryVimToPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $VimDirectory
    )

    $pathParts = $env:PATH -split ';' | Where-Object { $_ }

    if ($pathParts -notcontains $VimDirectory) {
        $env:PATH = @($VimDirectory) + $pathParts -join ';'
    }
}

function Remove-TemporaryVimFromPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $VimDirectory
    )

    $env:PATH = (($env:PATH -split ';') |
        Where-Object {
            $_ -and ($_ -ne $VimDirectory)
        }) -join ';'
}

# ---------------------------------------------------------------------------
# Main function
# ---------------------------------------------------------------------------

function Enable-TemporaryVim {
    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]
        $ZipUrl = 'https://www.vim.org/downloads/gvim_9.2.0000_x64.zip',

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]
        $CacheRoot = (Get-TemporaryVimDefaultCacheRoot),

        [Parameter()]
        [ValidatePattern('^[a-fA-F0-9]{64}$')]
        [string]
        $ExpectedSha256,

        [Parameter()]
        [switch]
        $Force,

        [Parameter()]
        [switch]
        $NoCache,

        [Parameter()]
        [switch]
        $PassThru
    )

    $ErrorActionPreference = 'Stop'

    $oldProgressPreference = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'

    $cacheKey = Get-TemporaryVimCacheKey -ZipUrl $ZipUrl

    if ($NoCache) {
        $installRoot = Join-Path -Path $env:TEMP -ChildPath "temporary-vim-$PID"
    }
    else {
        $installRoot = Join-Path -Path $CacheRoot -ChildPath $cacheKey
    }

    $downloadRoot = Join-Path -Path $env:TEMP -ChildPath "temporary-vim-download-$PID"
    $zipPath      = Join-Path -Path $downloadRoot -ChildPath 'vim.zip'

    try {
        # -------------------------------------------------------------------
        # Already loaded in this session
        # -------------------------------------------------------------------

        if (
            -not $Force -and
            $null -ne $script:TemporaryVimState -and
            (Test-Path -LiteralPath $script:TemporaryVimState.VimExe -PathType Leaf)
        ) {
            Add-TemporaryVimToPath -VimDirectory $script:TemporaryVimState.VimDirectory

            Write-Host "Temporary Vim already loaded for this PowerShell session."
            Write-Host "vim.exe: $($script:TemporaryVimState.VimExe)"

            if ($PassThru) {
                return $script:TemporaryVimState
            }

            return
        }

        # -------------------------------------------------------------------
        # Use existing cache unless forced
        # -------------------------------------------------------------------

        if (-not $Force) {
            $cachedVimExe = Find-TemporaryVimExe -Root $installRoot

            if ($cachedVimExe) {
                $vimDirectory = $cachedVimExe.Directory.FullName

                Add-TemporaryVimToPath -VimDirectory $vimDirectory

                $script:TemporaryVimState = [pscustomobject]@{
                    Name         = 'Temporary Vim'
                    VimExe       = $cachedVimExe.FullName
                    VimDirectory = $vimDirectory
                    InstallRoot  = $installRoot
                    ZipUrl       = $ZipUrl
                    CacheEnabled = (-not $NoCache)
                    LoadedAt     = Get-Date
                    ProcessId    = $PID
                }

                Write-Host "Temporary Vim loaded from cache for this PowerShell session only."
                Write-Host "vim.exe: $($cachedVimExe.FullName)"
                Write-Host ""
                Write-Host "Try:"
                Write-Host "  vim"
                Write-Host ""

                if ($PassThru) {
                    return $script:TemporaryVimState
                }

                return
            }
        }

        # -------------------------------------------------------------------
        # Fresh install/extract
        # -------------------------------------------------------------------

        if ($Force -and (Test-Path -LiteralPath $installRoot)) {
            Remove-Item -LiteralPath $installRoot -Recurse -Force -ErrorAction SilentlyContinue
        }

        if (Test-Path -LiteralPath $downloadRoot) {
            Remove-Item -LiteralPath $downloadRoot -Recurse -Force -ErrorAction SilentlyContinue
        }

        New-Item -ItemType Directory -Path $installRoot -Force | Out-Null
        New-Item -ItemType Directory -Path $downloadRoot -Force | Out-Null

        Write-Host "Downloading Vim..."
        Write-Host "Source: $ZipUrl"

        Invoke-WebRequest `
            -Uri $ZipUrl `
            -OutFile $zipPath `
            -UseBasicParsing

        if (-not (Test-Path -LiteralPath $zipPath -PathType Leaf)) {
            throw "Download failed. ZIP file was not created: $zipPath"
        }

        if ($ExpectedSha256) {
            Write-Host "Verifying SHA256..."

            $actualSha256 = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToUpperInvariant()
            $expectedHash = $ExpectedSha256.ToUpperInvariant()

            if ($actualSha256 -ne $expectedHash) {
                throw "SHA256 mismatch. Expected '$expectedHash', got '$actualSha256'."
            }
        }

        Expand-TemporaryVimArchive `
            -ZipPath $zipPath `
            -DestinationPath $installRoot

        Remove-Item -LiteralPath $downloadRoot -Recurse -Force -ErrorAction SilentlyContinue

        $vimExe = Find-TemporaryVimExe -Root $installRoot

        if (-not $vimExe) {
            throw "vim.exe not found after extraction."
        }

        $vimDirectory = $vimExe.Directory.FullName

        Add-TemporaryVimToPath -VimDirectory $vimDirectory

        $script:TemporaryVimState = [pscustomobject]@{
            Name         = 'Temporary Vim'
            VimExe       = $vimExe.FullName
            VimDirectory = $vimDirectory
            InstallRoot  = $installRoot
            ZipUrl       = $ZipUrl
            CacheEnabled = (-not $NoCache)
            LoadedAt     = Get-Date
            ProcessId    = $PID
        }

        if ($NoCache) {
            Register-EngineEvent `
                -SourceIdentifier 'PowerShell.Exiting' `
                -MessageData $installRoot `
                -Action {
                    Remove-Item `
                        -LiteralPath $event.MessageData `
                        -Recurse `
                        -Force `
                        -ErrorAction SilentlyContinue
                } | Out-Null
        }

        Write-Host ""
        Write-Host "Temporary Vim loaded for this PowerShell session only."
        Write-Host "vim.exe: $($vimExe.FullName)"
        Write-Host ""

        if (-not $NoCache) {
            Write-Host "Cache: $installRoot"
        }
        else {
            Write-Host "Cache: disabled"
        }

        Write-Host ""
        Write-Host "Try:"
        Write-Host "  vim"
        Write-Host ""

        if ($PassThru) {
            return $script:TemporaryVimState
        }
    }
    catch {
        Remove-Item -LiteralPath $downloadRoot -Recurse -Force -ErrorAction SilentlyContinue

        if ($NoCache -or $Force) {
            Remove-Item -LiteralPath $installRoot -Recurse -Force -ErrorAction SilentlyContinue
        }

        throw
    }
    finally {
        $ProgressPreference = $oldProgressPreference
    }
}

# ---------------------------------------------------------------------------
# Disable current-session Vim
# ---------------------------------------------------------------------------

function Disable-TemporaryVim {
    [CmdletBinding()]
    param(
        [switch] $PassThru
    )

    if ($null -eq $script:TemporaryVimState) {
        Write-Host "Temporary Vim is not loaded."
        return
    }

    $oldState = $script:TemporaryVimState

    Remove-TemporaryVimFromPath -VimDirectory $oldState.VimDirectory

    if (-not $oldState.CacheEnabled) {
        Remove-Item -LiteralPath $oldState.InstallRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    $script:TemporaryVimState = $null

    Write-Host "Temporary Vim removed from this PowerShell session."

    if ($PassThru) {
        return $oldState
    }
}

# ---------------------------------------------------------------------------
# Inspect state
# ---------------------------------------------------------------------------

function Get-TemporaryVim {
    [CmdletBinding()]
    param()

    return $script:TemporaryVimState
}

# ---------------------------------------------------------------------------
# Clear cache
# ---------------------------------------------------------------------------

function Clear-TemporaryVimCache {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]
        $CacheRoot = (Get-TemporaryVimDefaultCacheRoot)
    )

    if (-not (Test-Path -LiteralPath $CacheRoot)) {
        Write-Host "Temporary Vim cache does not exist."
        return
    }

    if ($PSCmdlet.ShouldProcess($CacheRoot, 'Remove temporary Vim cache')) {
        Remove-Item -LiteralPath $CacheRoot -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "Temporary Vim cache removed: $CacheRoot"
    }
}

# ---------------------------------------------------------------------------
# Auto-run
# ---------------------------------------------------------------------------

Enable-TemporaryVim
