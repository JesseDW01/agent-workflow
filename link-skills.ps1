# Links all skills from this repository (.agents/skills/*) into the user-scope
# skill directories on Windows using Directory Junctions (no Admin required).
# Also syncs to remote Herdr Core machines (e.g., devs7) via `hc exec --on <host>`.
#
# Targets:
#   - ~/.agents/skills             (Universal Agent Skills / Herdr my-skills panel / Codex)
#   - ~/.kimi-code/skills          (Kimi Code CLI inside Herdr terminals)
#   - ~/.claude/skills             (Claude Code CLI inside Herdr terminals)
#   - ~/.gemini/config/skills.json (Antigravity global skill registry)
#
# Usage:
#   .\link-skills.ps1
#   .\link-skills.ps1 -RemoteHost devs7

param(
    [string]$RemoteHost,
    [string]$RemoteRepoPath = "D:\Git\agent-workflow",
    [string]$RepoUrl = "https://github.com/JesseDW01/agent-workflow.git"
)

$ErrorActionPreference = "Continue"
$RepoRoot = $PSScriptRoot
$SkillsSource = Join-Path $RepoRoot ".agents\skills"

if (-not (Test-Path $SkillsSource)) {
    throw "Skills source directory not found: $SkillsSource"
}

$KimiHome = if ($env:KIMI_CODE_HOME) { $env:KIMI_CODE_HOME } else { Join-Path $env:USERPROFILE ".kimi-code" }
$TargetDirs = @(
    (Join-Path $env:USERPROFILE ".agents\skills"),
    (Join-Path $KimiHome "skills"),
    (Join-Path $env:USERPROFILE ".claude\skills")
)

$SkillFolders = Get-ChildItem -Path $SkillsSource -Directory

foreach ($TargetRoot in $TargetDirs) {
    $ParentDir = Split-Path -Parent $TargetRoot
    # Repair any broken junctions on parent or target root before mkdir
    cmd /c "dir `"$ParentDir`" >nul 2>nul || (rmdir `"$ParentDir`" >nul 2>nul & mkdir `"$ParentDir`" >nul 2>nul)"
    cmd /c "dir `"$TargetRoot`" >nul 2>nul || (rmdir `"$TargetRoot`" >nul 2>nul & mkdir `"$TargetRoot`" >nul 2>nul)"
    [System.IO.Directory]::CreateDirectory($TargetRoot) | Out-Null

    foreach ($Skill in $SkillFolders) {
        $LinkPath = Join-Path $TargetRoot $Skill.Name
        $SourceDir = Join-Path $SkillsSource $Skill.Name
        # Remove existing junction or directory if present
        cmd /c "rmdir `"$LinkPath`" >nul 2>nul"
        if (Test-Path $LinkPath) {
            Remove-Item $LinkPath -Recurse -Force -ErrorAction SilentlyContinue
        }
        cmd /c "mklink /J `"$LinkPath`" `"$SourceDir`" >nul 2>nul"
        if (Test-Path (Join-Path $LinkPath "SKILL.md")) {
            Write-Host "[$env:COMPUTERNAME] Linked $($Skill.Name) -> $LinkPath"
        } else {
            Write-Warning "[$env:COMPUTERNAME] Could not verify link at $LinkPath"
        }
    }
}

# Register in Antigravity global skills.json (~/.gemini/config/skills.json)
$GeminiConfigDir = Join-Path $env:USERPROFILE ".gemini\config"
[System.IO.Directory]::CreateDirectory($GeminiConfigDir) | Out-Null
$GeminiSkillsJson = Join-Path $GeminiConfigDir "skills.json"
$NormalizedPath = $SkillsSource -replace '\\', '/'

$ConfigObj = @{
    entries = @(
        @{ path = $NormalizedPath }
    )
}
$ConfigObj | ConvertTo-Json -Depth 5 | Set-Content -Path $GeminiSkillsJson -Encoding UTF8
Write-Host "[$env:COMPUTERNAME] Registered $NormalizedPath in $GeminiSkillsJson"

if ($RemoteHost) {
    Write-Host "`nSyncing and linking skills on Herdr remote host '$RemoteHost' via hc..."
    $RemoteCmd = "(if not exist `"$RemoteRepoPath\.git`" (git clone $RepoUrl `"$RemoteRepoPath`") else (git -C `"$RemoteRepoPath`" pull --ff-only)) & powershell -NoProfile -ExecutionPolicy Bypass -File `"$RemoteRepoPath\link-skills.ps1`""
    hc exec --on $RemoteHost $RemoteCmd
}
