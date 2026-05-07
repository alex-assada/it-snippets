#requires -Version 5.1
<#
.SYNOPSIS
    Temporarily loads Vim or Neovim into the current PowerShell session.

.DESCRIPTION
    Downloads the chosen editor, extracts it into a user-local cache, prepends
    its bin directory to the current process PATH, and leaves the machine/user
    PATH untouched.

    Extraction uses tar.exe first because Expand-Archive is slow as hell.
    If tar.exe is unavailable or fails, it falls back to Expand-Archive.

    Designed to work with:

        iwr 'https://example/Enable-TemporaryEditor.ps1' | iex

    PATH must be modified in the caller's current PowerShell process, hence
    the dot-source-style auto-run at the bottom.

.NOTES
    Persistence:
        - Files are cached under LOCALAPPDATA per tool.
        - PATH change is current PowerShell process only.
        - No registry writes.
        - No permanent user/machine PATH modification.

    Functions exposed:
        Enable-TemporaryEditor   -Tool vim|neovim
        Disable-TemporaryEditor  [-Tool vim|neovim|all]
        Get-TemporaryEditor      [-Tool vim|neovim]
        Clear-TemporaryEditorCache [-Tool vim|neovim|all]

    Non-interactive selection (skips the prompt):
        $env:TEMP_EDITOR_TOOL = 'neovim'; iwr '...' | iex
        $global:TempEditorTool = 'vim';  iwr '...' | iex
#>

Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Editor profiles
# ---------------------------------------------------------------------------

# Notes on default URLs:
#   Vim:    pinned to a vim-win32-installer GitHub release. Bump as needed.
#           vim.org URLs like gvim_9.X.0000_x64.zip are unreliable.
#   Neovim: 'stable' tag auto-tracks the current stable release. Predictable
#           filename, unpredictable SHA across time. Pin a version (e.g.
#           v0.12.2) instead if you need reproducibility.

$script:EditorProfiles = @{
    'vim' = [pscustomobject]@{
        Key            = 'vim'
        DisplayName    = 'Vim'
        DefaultZipUrl  = 'https://github.com/vim/vim-win32-installer/releases/download/v9.1.0825/gvim_9.1.0825_x64.zip'
        ExeName        = 'vim.exe'
        # Inside the zip: vim/vim91/vim.exe (or vim92/, etc.)
        BinPathPattern = '\\vim\\vim\d+\\vim\.exe$'
    }
    'neovim' = [pscustomobject]@{
        Key            = 'neovim'
        DisplayName    = 'Neovim'
        DefaultZipUrl  = 'https://github.com/neovim/neovim/releases/download/stable/nvim-win64.zip'
        ExeName        = 'nvim.exe'
        # Inside the zip: nvim-win64/bin/nvim.exe
        BinPathPattern = '\\nvim-win64\\bin\\nvim\.exe$'
    }
}

# ---------------------------------------------------------------------------
# Script state (per-tool hashtable so vim and neovim can coexist)
# ---------------------------------------------------------------------------

if (-not (Get-Variable -Name TemporaryEditorState -Scope Script -ErrorAction SilentlyContinue)) {
    $script:TemporaryEditorState = @{}
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Resolve-TemporaryEditorProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Tool
    )

    $key = $Tool.Trim().ToLowerInvariant()

    switch ($key) {
        'nvim'   { $key = 'neovim' }
        'gvim'   { $key = 'vim' }
        'v'      { $key = 'vim' }
        'n'      { $key = 'neovim' }
    }

    if (-not $script:EditorProfiles.ContainsKey($key)) {
        $valid = ($script:EditorProfiles.Keys | Sort-Object) -join ', '
        throw "Unknown editor '$Tool'. Valid: $valid"
    }

    return $script:EditorProfiles[$key]
}

function Get-TemporaryEditorDefaultCacheRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $ToolKey
    )

    if ($env:LOCALAPPDATA) {
        return (Join-Path -Path $env:LOCALAPPDATA -ChildPath "TempToolCache\$ToolKey")
    }

    return (Join-Path -Path $env:TEMP -ChildPath "TempToolCache\$ToolKey")
}

function Get-TemporaryEditorCacheKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $ZipUrl
    )

    $fileName = [System.IO.Path]::GetFileName(([uri] $ZipUrl).AbsolutePath)

    if (-not $fileName) {
        return 'editor-cache'
    }

    return ($fileName -replace '\.zip$', '')
}

function Find-TemporaryEditorExe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Root,

        [Parameter(Mandatory)]
        [pscustomobject] $EditorProfile
    )

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        return $null
    }

    $preferred = Get-ChildItem -LiteralPath $Root -Recurse -File -Filter $EditorProfile.ExeName -ErrorAction SilentlyContinue |
        Where-Object {
            $_.FullName -match $EditorProfile.BinPathPattern
        } |
        Select-Object -First 1

    if ($preferred) {
        return $preferred
    }

    return Get-ChildItem -LiteralPath $Root -Recurse -File -Filter $EditorProfile.ExeName -ErrorAction SilentlyContinue |
        Select-Object -First 1
}

function Expand-TemporaryEditorArchive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $ZipPath,

        [Parameter(Mandatory)]
        [string] $DestinationPath
    )

    $tar = Get-Command -Name 'tar.exe' -ErrorAction SilentlyContinue

    if ($tar) {
        Write-Host "Extracting with tar.exe..."

        & $tar.Source -xf $ZipPath -C $DestinationPath

        if ($LASTEXITCODE -eq 0) {
            return
        }

        Write-Host "tar.exe failed with exit code $LASTEXITCODE. Falling back to Expand-Archive..."
    }
    else {
        Write-Host "tar.exe not found. Falling back to Expand-Archive..."
    }

    Write-Host "Extracting with Expand-Archive..."

    Expand-Archive `
        -LiteralPath $ZipPath `
        -DestinationPath $DestinationPath `
        -Force
}

function Add-TemporaryEditorToPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $BinDirectory
    )

    $pathParts = $env:PATH -split ';' | Where-Object { $_ }

    if ($pathParts -notcontains $BinDirectory) {
        $env:PATH = (@($BinDirectory) + $pathParts) -join ';'
    }
}

function Remove-TemporaryEditorFromPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $BinDirectory
    )

    $env:PATH = (($env:PATH -split ';') |
        Where-Object {
            $_ -and ($_ -ne $BinDirectory)
        }) -join ';'
}

# ---------------------------------------------------------------------------
# Main function
# ---------------------------------------------------------------------------

function Enable-TemporaryEditor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateSet('vim', 'neovim', 'nvim', 'gvim', 'v', 'n')]
        [string] $Tool,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $ZipUrl,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $CacheRoot,

        [Parameter()]
        [ValidatePattern('^[a-fA-F0-9]{64}$')]
        [string] $ExpectedSha256,

        [Parameter()]
        [switch] $Force,

        [Parameter()]
        [switch] $NoCache,

        [Parameter()]
        [switch] $PassThru
    )

    $ErrorActionPreference = 'Stop'

    $oldProgressPreference = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'

    $editorProfile = Resolve-TemporaryEditorProfile -Tool $Tool

    if (-not $ZipUrl) {
        $ZipUrl = $editorProfile.DefaultZipUrl
    }

    if (-not $CacheRoot) {
        $CacheRoot = Get-TemporaryEditorDefaultCacheRoot -ToolKey $editorProfile.Key
    }

    $cacheKey = Get-TemporaryEditorCacheKey -ZipUrl $ZipUrl

    if ($NoCache) {
        $installRoot = Join-Path -Path $env:TEMP -ChildPath "temp-editor-$($editorProfile.Key)-$PID"
    }
    else {
        $installRoot = Join-Path -Path $CacheRoot -ChildPath $cacheKey
    }

    $downloadRoot = Join-Path -Path $env:TEMP -ChildPath "temp-editor-download-$($editorProfile.Key)-$PID"
    $zipPath      = Join-Path -Path $downloadRoot -ChildPath 'editor.zip'

    try {
        # -------------------------------------------------------------------
        # Already loaded in this session
        # -------------------------------------------------------------------

        $existing = $null
        if ($script:TemporaryEditorState.ContainsKey($editorProfile.Key)) {
            $existing = $script:TemporaryEditorState[$editorProfile.Key]
        }

        if (
            -not $Force -and
            $null -ne $existing -and
            (Test-Path -LiteralPath $existing.ExePath -PathType Leaf)
        ) {
            Add-TemporaryEditorToPath -BinDirectory $existing.BinDirectory

            Write-Host "$($editorProfile.DisplayName) already loaded for this session."
            Write-Host "Path: $($existing.ExePath)"

            if ($PassThru) { return $existing }
            return
        }

        # -------------------------------------------------------------------
        # Use existing cache unless forced
        # -------------------------------------------------------------------

        if (-not $Force) {
            $cachedExe = Find-TemporaryEditorExe -Root $installRoot -EditorProfile $editorProfile

            if ($cachedExe) {
                $binDirectory = $cachedExe.Directory.FullName
                Add-TemporaryEditorToPath -BinDirectory $binDirectory

                $state = [pscustomobject]@{
                    Tool         = $editorProfile.Key
                    DisplayName  = $editorProfile.DisplayName
                    ExePath      = $cachedExe.FullName
                    BinDirectory = $binDirectory
                    InstallRoot  = $installRoot
                    ZipUrl       = $ZipUrl
                    CacheEnabled = (-not $NoCache)
                    LoadedAt     = Get-Date
                    ProcessId    = $PID
                }
                $script:TemporaryEditorState[$editorProfile.Key] = $state

                Write-Host "$($editorProfile.DisplayName) loaded from cache for this session."
                Write-Host "Path: $($cachedExe.FullName)"
                Write-Host ""
                Write-Host "Try:"
                Write-Host "  $($editorProfile.ExeName -replace '\.exe$','')"
                Write-Host ""

                if ($PassThru) { return $state }
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

        Write-Host "Downloading $($editorProfile.DisplayName)..."
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

        Expand-TemporaryEditorArchive `
            -ZipPath $zipPath `
            -DestinationPath $installRoot

        Remove-Item -LiteralPath $downloadRoot -Recurse -Force -ErrorAction SilentlyContinue

        $exe = Find-TemporaryEditorExe -Root $installRoot -EditorProfile $editorProfile

        if (-not $exe) {
            throw "$($editorProfile.ExeName) not found after extraction under $installRoot."
        }

        $binDirectory = $exe.Directory.FullName
        Add-TemporaryEditorToPath -BinDirectory $binDirectory

        $state = [pscustomobject]@{
            Tool         = $editorProfile.Key
            DisplayName  = $editorProfile.DisplayName
            ExePath      = $exe.FullName
            BinDirectory = $binDirectory
            InstallRoot  = $installRoot
            ZipUrl       = $ZipUrl
            CacheEnabled = (-not $NoCache)
            LoadedAt     = Get-Date
            ProcessId    = $PID
        }
        $script:TemporaryEditorState[$editorProfile.Key] = $state

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
        Write-Host "$($editorProfile.DisplayName) loaded for this session."
        Write-Host "Path: $($exe.FullName)"
        Write-Host ""

        if (-not $NoCache) {
            Write-Host "Cache: $installRoot"
        }
        else {
            Write-Host "Cache: disabled"
        }

        Write-Host ""
        Write-Host "Try:"
        Write-Host "  $($editorProfile.ExeName -replace '\.exe$','')"
        Write-Host ""

        if ($PassThru) { return $state }
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
# Disable
# ---------------------------------------------------------------------------

function Disable-TemporaryEditor {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [ValidateSet('vim', 'neovim', 'nvim', 'gvim', 'v', 'n', 'all')]
        [string] $Tool = 'all',

        [switch] $PassThru
    )

    $keys = if ($Tool -eq 'all') {
        @($script:TemporaryEditorState.Keys)
    }
    else {
        @((Resolve-TemporaryEditorProfile -Tool $Tool).Key)
    }

    if (-not $keys -or $keys.Count -eq 0) {
        Write-Host "No temporary editor loaded."
        return
    }

    $removed = @()

    foreach ($k in $keys) {
        if (-not $script:TemporaryEditorState.ContainsKey($k)) {
            continue
        }

        $state = $script:TemporaryEditorState[$k]

        Remove-TemporaryEditorFromPath -BinDirectory $state.BinDirectory

        if (-not $state.CacheEnabled) {
            Remove-Item -LiteralPath $state.InstallRoot -Recurse -Force -ErrorAction SilentlyContinue
        }

        $script:TemporaryEditorState.Remove($k)

        Write-Host "$($state.DisplayName) removed from this session."
        $removed += $state
    }

    if ($PassThru) { return $removed }
}

# ---------------------------------------------------------------------------
# Inspect state
# ---------------------------------------------------------------------------

function Get-TemporaryEditor {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [ValidateSet('vim', 'neovim', 'nvim', 'gvim', 'v', 'n')]
        [string] $Tool
    )

    if ($Tool) {
        $key = (Resolve-TemporaryEditorProfile -Tool $Tool).Key

        if ($script:TemporaryEditorState.ContainsKey($key)) {
            return $script:TemporaryEditorState[$key]
        }

        return $null
    }

    return $script:TemporaryEditorState.Values
}

# ---------------------------------------------------------------------------
# Clear cache
# ---------------------------------------------------------------------------

function Clear-TemporaryEditorCache {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Position = 0)]
        [ValidateSet('vim', 'neovim', 'nvim', 'gvim', 'v', 'n', 'all')]
        [string] $Tool = 'all',

        [Parameter()]
        [string] $CacheRoot
    )

    $keys = if ($Tool -eq 'all') {
        @($script:EditorProfiles.Keys)
    }
    else {
        @((Resolve-TemporaryEditorProfile -Tool $Tool).Key)
    }

    foreach ($k in $keys) {
        $root = if ($CacheRoot) {
            $CacheRoot
        }
        else {
            Get-TemporaryEditorDefaultCacheRoot -ToolKey $k
        }

        if (-not (Test-Path -LiteralPath $root)) {
            Write-Host "$k cache does not exist."
            continue
        }

        if ($PSCmdlet.ShouldProcess($root, "Remove $k cache")) {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "$k cache removed: $root"
        }
    }
}

# ---------------------------------------------------------------------------
# Auto-run with editor selection prompt
# ---------------------------------------------------------------------------

function Read-TemporaryEditorChoice {
    [CmdletBinding()]
    param()

    # Non-interactive overrides
    if ($env:TEMP_EDITOR_TOOL) {
        return $env:TEMP_EDITOR_TOOL
    }

    $globalVar = Get-Variable -Name 'TempEditorTool' -Scope Global -ErrorAction SilentlyContinue
    if ($globalVar -and $globalVar.Value) {
        return [string] $globalVar.Value
    }

    Write-Host ""
    Write-Host "Which editor do you want to load?"
    Write-Host "  [V] Vim"
    Write-Host "  [N] Neovim	(default)"
    Write-Host ""

    while ($true) {
        $answer = Read-Host "Choice (V/N)"

        if ([string]::IsNullOrWhiteSpace($answer)) {
            return 'neovim'
        }

        $a = $answer.Trim().ToLowerInvariant()

        if ('v','vim','gvim'    -contains $a) { return 'vim' }
        if ('n','nvim','neovim' -contains $a) { return 'neovim' }

        Write-Host "Invalid choice. Type V or N (or press Enter for Vim)."
    }
}

$choice = Read-TemporaryEditorChoice
Enable-TemporaryEditor -Tool $choice
