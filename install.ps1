# install.ps1 - Deploy the GitHub App "conahcnuj" git-identity files into the
# opencode user-level config directory.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File install.ps1                # -> $HOME/.config/opencode
#   powershell -ExecutionPolicy Bypass -File install.ps1 -Destination C:\path\to\dir
#
# Copies gh-app/* (scripts + app.env.example) and plugins/gh-app-token.ts.
# If the destination has no app.env yet, it is created from app.env.example.

[CmdletBinding()]
param(
    [string]$Destination = ""
)

$ErrorActionPreference = "Stop"

if (-not $Destination) {
    $Destination = Join-Path (Join-Path $HOME ".config") "opencode"
}

$RepoRoot = $PSScriptRoot
$SrcGhApp = Join-Path $RepoRoot "gh-app"
$SrcPlugins = Join-Path $RepoRoot "plugins"

$DstGhApp = Join-Path $Destination "gh-app"
$DstPlugins = Join-Path $Destination "plugins"

Write-Host "Deploying to: $Destination"

# 1. gh-app scripts
New-Item -ItemType Directory -Force -Path $DstGhApp | Out-Null
Get-ChildItem -Path $SrcGhApp -Filter "*.sh" -File | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $DstGhApp $_.Name) -Force
    Write-Host "  copied $($_.Name)"
}

# app.env.example
$Example = Join-Path $SrcGhApp "app.env.example"
if (Test-Path -LiteralPath $Example) {
    Copy-Item -LiteralPath $Example -Destination (Join-Path $DstGhApp "app.env.example") -Force
    Write-Host "  copied app.env.example"
}

# app.env: copy the real one if it ships with the repo source, otherwise
# create from example (fresh clone / CI) unless one already exists at the
# destination (keep existing local config).
$SrcEnv = Join-Path $SrcGhApp "app.env"
$DstEnv = Join-Path $DstGhApp "app.env"
if (Test-Path -LiteralPath $SrcEnv) {
    Copy-Item -LiteralPath $SrcEnv -Destination $DstEnv -Force
    Write-Host "  copied app.env"
} elseif (-not (Test-Path -LiteralPath $DstEnv)) {
    Copy-Item -LiteralPath $Example -Destination $DstEnv
    Write-Host "  created app.env from app.env.example"
    # Collect real values in the same run when interactive, so that
    # ./install.ps1 alone leaves a working config (skipped in CI / pipes).
    if (-not $env:CI -and [Environment]::UserInteractive -and -not [Console]::IsInputRedirected) {
        Write-Host "  enter App settings (empty = keep template value):"
        $lines = Get-Content -LiteralPath $DstEnv
        $keys = @("APP_ID", "INSTALLATION_ID", "APP_SLUG", "PRIVATE_KEY_PATH", "BASH_EXE")
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $m = [regex]::Match($lines[$i], '^(?<k>[A-Z_]+)=(?<v>.*)$')
            if ($m.Success -and ($keys -contains $m.Groups["k"].Value)) {
                $cur = $m.Groups["v"].Value
                $ans = Read-Host "  $($m.Groups['k'].Value) [$cur]"
                if ($ans -ne "") { $lines[$i] = "$($m.Groups['k'].Value)=$ans" }
            }
        }
        Set-Content -LiteralPath $DstEnv -Value $lines
        Write-Host "  updated app.env"
    } else {
        Write-Host "  (edit app.env values as needed)"
    }
}

# 2. opencode plugin
New-Item -ItemType Directory -Force -Path $DstPlugins | Out-Null
$PluginName = "gh-app-token.ts"
Copy-Item -LiteralPath (Join-Path $SrcPlugins $PluginName) -Destination (Join-Path $DstPlugins $PluginName) -Force
Write-Host "  copied $PluginName"

Write-Host ""
Write-Host "Done. Restart opencode to load the plugin (plugins/*.ts is auto-loaded)."