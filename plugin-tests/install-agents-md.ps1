# plugin-tests/install-agents-md.ps1 - AGENTS.md merge test for install.ps1
#
# The global opencode rules (opencode/AGENTS.md) reach every repository through
# <config dir>/AGENTS.md, so install.ps1 (Install-GlobalAgentsMd) splices them
# into the user's file as a managed block between marker comments. That merge is
# what makes `git vc` surface naturally in nahcnuj repos that carry no own docs.
#
# This test drives the REAL install.ps1 against temp destinations and asserts
# the merge contract:
#   - a fresh destination gets the managed block alone, exactly once per marker
#   - personal rules outside the block always survive
#   - re-running install replaces the block instead of stacking a second copy
#   - an unterminated block start is rewritten from that point
#   - personal rules after the end marker survive a managed-block update
#
# Usage:
#   pwsh -NoProfile -File plugin-tests/install-agents-md.ps1
# CI: .github/workflows/ci.yml (install-test)

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$Root = Resolve-Path (Join-Path $PSScriptRoot "..")
$Install = Join-Path $Root "install.ps1"
$BeginMarker = "<!-- conahcnuj:begin -->"
$EndMarker = "<!-- conahcnuj:end -->"

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw "assertion failed: $Message"
    }
}

function Assert-OneMarkedBlock {
    param([string]$Content, [string]$Stage)
    Assert-True ($Content -match "git vc") "${Stage}: merged AGENTS.md must tell agents to commit with git vc"
    Assert-True ($Content -match [regex]::Escape($BeginMarker)) "${Stage}: begin marker is missing"
    foreach ($marker in @($BeginMarker, $EndMarker)) {
        $hits = ([regex]::Matches($Content, [regex]::Escape($marker))).Count
        Assert-True ($hits -eq 1) "${Stage}: marker '$marker' appears $hits times (want 1)"
    }
    Assert-True ($Content.IndexOf($BeginMarker) -lt $Content.IndexOf($EndMarker)) "${Stage}: begin marker must precede end marker"
}

function Invoke-ConahcnujInstall {
    param([string]$Dest)
    # A private InstallPath keeps every deployment artifact inside the temp
    # destination, so running this test never touches a real home directory.
    & $Install -Destination $Dest -InstallPath (Join-Path $Dest "install-bin") | Out-Null
}

function Write-TextFile {
    param([string]$Path, [string]$Content)
    [IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding $false))
}

$TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("conahcnuj-agents-md-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $TempRoot | Out-Null

try {
    # 1. Fresh destination: the managed block is created, exactly once.
    $freshDest = Join-Path $TempRoot "fresh"
    New-Item -ItemType Directory -Force -Path $freshDest | Out-Null
    Invoke-ConahcnujInstall -Dest $freshDest
    $fresh = [System.IO.File]::ReadAllText((Join-Path $freshDest "AGENTS.md"))
    Assert-OneMarkedBlock -Content $fresh -Stage "fresh install"
    Assert-True (-not $fresh.Contains("keep-me")) "fresh install must not invent personal rules"

    # 2. Personal rules survive the merge and re-running install is idempotent.
    $seededDest = Join-Path $TempRoot "seeded"
    New-Item -ItemType Directory -Force -Path $seededDest | Out-Null
    $seededPath = Join-Path $seededDest "AGENTS.md"
    # Users may already keep personal global rules here: install must merge
    # the conahcnuj block, never overwrite the file.
    Write-TextFile $seededPath "# My personal rules`nkeep-me`n"
    Invoke-ConahcnujInstall -Dest $seededDest
    $once = [System.IO.File]::ReadAllText($seededPath)
    Assert-True ($once -match "keep-me") "install overwrote the user's global AGENTS.md"
    Assert-OneMarkedBlock -Content $once -Stage "merge into personal rules"
    Invoke-ConahcnujInstall -Dest $seededDest
    $twice = [System.IO.File]::ReadAllText($seededPath)
    Assert-True ($twice -match "keep-me") "re-install dropped the user's personal rules"
    Assert-OneMarkedBlock -Content $twice -Stage "re-install"
    Assert-True ($twice -ceq $once) "re-install is not idempotent (managed block was stacked or rewritten)"

    # 3. An unterminated block start is rewritten from that point.
    $brokenDest = Join-Path $TempRoot "unterminated"
    New-Item -ItemType Directory -Force -Path $brokenDest | Out-Null
    $brokenPath = Join-Path $brokenDest "AGENTS.md"
    Write-TextFile $brokenPath "# mine`n$BeginMarker`norphan tail`n"
    Invoke-ConahcnujInstall -Dest $brokenDest
    $fixed = [System.IO.File]::ReadAllText($brokenPath)
    Assert-True ($fixed.StartsWith("# mine`n")) "unterminated merge dropped the prefix before the marker"
    Assert-True (-not $fixed.Contains("orphan tail")) "unterminated tail must be rewritten, not kept"
    Assert-OneMarkedBlock -Content $fixed -Stage "unterminated block"

    # 4. Personal rules after the end marker survive a managed-block update.
    $updatedDest = Join-Path $TempRoot "updated"
    New-Item -ItemType Directory -Force -Path $updatedDest | Out-Null
    $updatedPath = Join-Path $updatedDest "AGENTS.md"
    Write-TextFile $updatedPath "# my header`n$BeginMarker`nstale managed text`n$EndMarker`n# my footer`n"
    Invoke-ConahcnujInstall -Dest $updatedDest
    $updated = [System.IO.File]::ReadAllText($updatedPath)
    Assert-True ($updated -match "# my footer") "rules after the end marker must survive a block update"
    Assert-True ($updated -match "# my header") "prefix before the block must survive a block update"
    Assert-True (-not $updated.Contains("stale managed text")) "stale managed block must be replaced"
    Assert-OneMarkedBlock -Content $updated -Stage "block update"

    Write-Host "AGENTS.md merge test passed"
} finally {
    Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
}