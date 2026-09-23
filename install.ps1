# install.ps1 - Deploy the GitHub App "conahcnuj" git-identity files into the
# opencode user-level config directory.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File install.ps1                # -> $HOME/.config/opencode
#   powershell -ExecutionPolicy Bypass -File install.ps1 -Destination C:\path\to\dir
#   powershell -ExecutionPolicy Bypass -File install.ps1 -InstallPath C:\path\to\bin
#
# Deploys two gh-app trees:
#   - <Destination>/gh-app/...          used by the opencode plugin (resolves
#                                       gh-app relative to its own plugins dir)
#   - <InstallPathParent>/gh-app/...    used by the conahcnuj driver binary
#                                       (resolves gh-app relative to itself)
# plus:
#   - <Destination>/plugins/gh-app-token.ts   opencode plugin
#   - <InstallPath>/conahcnuj                driver binary
#   - <InstallPathParent>/lib/*.sh           driver runtime libs
# If the config destination has no app.env yet, it is created from
# app.env.example. plugins/package.json, package-lock.json, tsconfig.json and
# node_modules are local typecheck tooling and are never deployed; gh-app/tests
# and other test code is never deployed either.

[CmdletBinding()]
param(
    [string]$Destination = "",
    [string]$InstallPath = ""
)

$ErrorActionPreference = "Stop"

if (-not $Destination) {
    $Destination = Join-Path (Join-Path $HOME ".config") "opencode"
}

if (-not $InstallPath) {
    $InstallPath = Join-Path $HOME ".local/bin"
}

$RepoRoot = $PSScriptRoot
$SrcGhApp = Join-Path $RepoRoot "gh-app"
$SrcPlugins = Join-Path $RepoRoot "plugins"
$SrcBin = Join-Path $RepoRoot "bin"
$SrcLib = Join-Path $RepoRoot "lib"

# The opencode plugin resolves gh-app next to its own plugins dir, so the
# config destination needs a full gh-app tree. The driver binary reads gh-app
# and lib relative to its own location, so those are mirrored beside it.
$DstGhAppConfig = Join-Path $Destination "gh-app"
$DstPlugins = Join-Path $Destination "plugins"
$DstBinDir = $InstallPath
$DstGhAppBin = Join-Path (Split-Path $InstallPath -Parent) "gh-app"
$DstLibBin = Join-Path (Split-Path $InstallPath -Parent) "lib"

Write-Host "Config destination: $Destination"
Write-Host "Binary path: $DstBinDir"

# Read a text file as UTF-8, stripping any leading BOM, and normalize line
# endings to LF (Git Bash rejects CRLF shebangs under Windows).
function Get-NormalizedText {
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Count -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $bytes = $bytes[3..($bytes.Count - 1)]
    }
    $content = [System.Text.Encoding]::UTF8.GetString($bytes)
    $content = $content -replace "`r`n", "`n"
    $content = $content -replace "`r", "`n"
    return $content
}

# Write text as UTF-8 without a BOM.
function Write-NormalizedText {
    param([string]$Path, [string]$Content)
    [IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding $false))
}

# Deploy one gh-app tree: all top-level scripts, app.env.example and app.env.
function Deploy-GhApp {
    param([string]$Dst)
    New-Item -ItemType Directory -Force -Path $Dst | Out-Null
    Get-ChildItem -Path $SrcGhApp -Filter "*.sh" -File | ForEach-Object {
        $content = Get-NormalizedText $_.FullName
        Write-NormalizedText (Join-Path $Dst $_.Name) $content
        Write-Host "  copied $($_.Name)"
    }

    # Test code is never deployed: tests run from the repo in CI.
    # Drop leftovers from earlier installs that shipped them.
    foreach ($legacy in @("mock-test.sh", "tests")) {
        $p = Join-Path $Dst $legacy
        if (Test-Path -LiteralPath $p) {
            Remove-Item -LiteralPath $p -Recurse -Force
            Write-Host "  removed legacy $legacy (test code is not deployed)"
        }
    }

    # app.env.example
    $Example = Join-Path $SrcGhApp "app.env.example"
    if (Test-Path -LiteralPath $Example) {
        Copy-Item -LiteralPath $Example -Destination (Join-Path $Dst "app.env.example") -Force
        Write-Host "  copied app.env.example"
    }

    # app.env: copy the real one if it ships with the repo source, otherwise
    # create from example (fresh clone / CI) unless one already exists at the
    # destination (keep existing local config).
    # Convert Windows paths to Unix paths for Git Bash compatibility.
    $SrcEnv = Join-Path $SrcGhApp "app.env"
    $DstEnv = Join-Path $Dst "app.env"
    if (Test-Path -LiteralPath $SrcEnv) {
        $content = Get-NormalizedText $SrcEnv
        $content = $content -replace '^PRIVATE_KEY_PATH=C:/', 'PRIVATE_KEY_PATH=/c/'
        $content = $content -replace '^PRIVATE_KEY_PATH=([A-Z]):/', 'PRIVATE_KEY_PATH=/$1/'
        Write-NormalizedText $DstEnv $content
        Write-Host "  copied app.env (with Unix path conversion)"
    } elseif (-not (Test-Path -LiteralPath $DstEnv)) {
        Copy-Item -LiteralPath $Example -Destination $DstEnv
        Write-Host "  created app.env from app.env.example (edit app.env values as needed)"
    }
}

# 1. gh-app for the opencode plugin (config destination).
Write-Host "Deploying gh-app to $DstGhAppConfig"
Deploy-GhApp $DstGhAppConfig

# 2. opencode plugin
New-Item -ItemType Directory -Force -Path $DstPlugins | Out-Null
$PluginName = "gh-app-token.ts"
Copy-Item -LiteralPath (Join-Path $SrcPlugins $PluginName) -Destination (Join-Path $DstPlugins $PluginName) -Force
Write-Host "  copied $PluginName"

# 3. driver runtime beside the binary (gh-app + lib).
Write-Host "Deploying gh-app to $DstGhAppBin"
Deploy-GhApp $DstGhAppBin
New-Item -ItemType Directory -Force -Path $DstLibBin | Out-Null
Get-ChildItem -Path $SrcLib -Filter "*.sh" -File | ForEach-Object {
    $content = Get-NormalizedText $_.FullName
    Write-NormalizedText (Join-Path $DstLibBin $_.Name) $content
    Write-Host "  copied lib/$($_.Name)"
}

# 4. conahcnuj binary
New-Item -ItemType Directory -Force -Path $DstBinDir | Out-Null
$BinName = "conahcnuj"
$SrcBinScript = Join-Path $SrcBin "conahcnuj.sh"
$content = Get-NormalizedText $SrcBinScript
Write-NormalizedText (Join-Path $DstBinDir $BinName) $content
Write-Host "  copied $BinName to $DstBinDir"

Write-Host ""
Write-Host "Done. Restart opencode to load the plugin (plugins/*.ts is auto-loaded)."
Write-Host "Add $DstBinDir to your PATH to use 'conahcnuj' command."